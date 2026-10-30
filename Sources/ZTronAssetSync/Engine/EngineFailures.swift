import Foundation
import ZTronAssetModel
import ZTronAssetStorage

extension SyncEngine {
    // MARK: Pause (T7)

    /// A paused attempt: a preempted one resumes first in its lane, a policy pause parks it while its lane is still
    /// refused; the next attempt continues from the attempt's sidecar when there is one (the transport's resumable flag
    /// is not trusted, D-13). A policy pause is decided on the lane verdict when the pause arrives, not when it was
    /// asked for: conditions that admit the lane again may have been applied meanwhile (a Low Data Mode flap), and their
    /// re-admission could not see the job, which still downloaded, so a park on the old reason would wait for a later
    /// conditions element that may never come (T17; review of close-out cycle 9, PROBE-C9C-1a).
    func paused(_ transfer: TransferID, epoch: UInt64, request: TransferRequest) async {
        guard let job = self.state.jobs[transfer], let active = job.active else {
            return
        }
        self.recordBreaker(.abandoned(transfer))
        let policyPause = active.policyPause
        // REENTRANCY: f-2 (proposed) — the lifecycle and the epoch below; the resume point is kept only for this job;
        // a policy pause re-reads the lane's block under the conditions now.
        let resume = await self.resumePoint(after: request)
        guard self.isRunning, var current = self.state.jobs[transfer], current.epoch == epoch else {
            return
        }
        current.resume = resume
        current.active = nil
        self.state.jobs[transfer] = current
        if policyPause != nil, current.lane < .userInitiated, let block = self.laneWideBlock(current.lane) {
            self.park(transfer, reason: block)
        } else if self.transition(transfer, to: .queued) {
            self.enqueue(transfer, front: true)
        }
        self.pump()
        self.reconcileIdle()
    }

    /// The point the next attempt continues from: the attempt's sidecar, when the content is checksummed and the
    /// source can resume (the engine looks for a sidecar rather than trusting a flag, ARCHITECTURE §7.6, D-13). A
    /// partial without one is discarded whatever the transport's resumable flag said: no attempt can continue it (the
    /// live transport leaves one after a dropped connection on a response without a validator), and staging GC would
    /// otherwise find it only at the next launch or maintenance window.
    func resumePoint(after request: TransferRequest) async -> ResumePoint? {
        guard let staging = self.state.staging else {
            return nil
        }
        let name = request.partialName
        let canResume = request.id.kind == .content && (self.state.remote?.capabilities.supportsResume ?? false)
        if canResume {
            // REENTRANCY: f-2 (proposed) — the caller re-validates the lifecycle and the epoch.
            if let sidecar = await staging.readSidecar(for: name) {
                return ResumePoint(previous: name, offset: sidecar.receivedBytes, validator: sidecar.validator)
            }
        }
        // REENTRANCY: f-3 (proposed) — nothing: an idempotent removal of a partial nobody can continue.
        await staging.discard(name)
        return nil
    }

    // MARK: Failure (T6, ARCHITECTURE §7.6)

    /// Maps a transfer failure to the engine action of ARCHITECTURE §7.6.
    func failed(_ transfer: TransferID, epoch: UInt64, request: TransferRequest, error: TransferError) async {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let wall = self.environment.time.now()
        self.recordBreaker(SyncEngine.breakerOutcome(error, transfer: transfer, asset: job.assets.min()))
        if let failureClass = error.failureClass {
            self.state.metrics.failures[failureClass] += 1
            self.record(job.assets.min(), failureClass, String(describing: error))
        }
        switch error {
        case .cancelled(.byClient):
            // Not a failure (T7/T13): a cancel the engine did not ask for re-queues the job.
            self.requeue(transfer, discarding: request)
        case .cancelled(.bySystem):
            self.retryLater(transfer, error: .transient(.unknown(urlErrorCode: 0), retryAfter: nil))
        case .offline:
            // The edge that re-queues jobs failed offline (T19) may have been applied while this attempt still ran
            // (URLSession's error lags the path monitor): its job was not failed then, so with the path satisfied now no
            // further edge need come. Such a failure is retried at once; otherwise it waits for the next edge (R-SYN-13;
            // review of close-out cycle 9, PROBE-C9C-3).
            let edgePassed = job.active.map { $0.edgeSerial != self.state.networkEdgeSerial } ?? false
            self.state.jobs[transfer]?.active = nil
            self.state.jobs[transfer]?.transientFailure = true
            if edgePassed, self.state.conditions?.network.satisfied == true {
                self.requeue(transfer, discarding: request)
            } else if self.transition(transfer, to: .failed(.whenOnline)) {
                self.failFast(transfer, reason: .offline)
            }
        case .transient(.resumeRejected, _):
            // Discard the partial and sidecar, then an immediate fresh attempt without backoff (R-NET-8).
            self.state.jobs[transfer]?.resume = nil
            // REENTRANCY: f-3 (proposed) — the epoch, re-read by `requeue`; removals are idempotent.
            await self.state.staging?.discard(request.partialName)
            if let previous = request.resume?.previous {
                // REENTRANCY: f-3 (proposed) — as above.
                await self.state.staging?.discard(previous)
            }
            guard self.isRunning, self.state.jobs[transfer]?.epoch == epoch else {
                return
            }
            self.state.jobs[transfer]?.resume = nil
            self.requeue(transfer, discarding: nil)
        case .transient(.backgroundSessionUnavailable, _):
            self.state.backgroundDisabled = true
            self.requeue(transfer, discarding: nil)
        case .transient(.throttled, let retryAfter):
            self.throttled(transfer, retryAfter: retryAfter, wall: wall)
        case .transient(let cause, let retryAfter):
            // REENTRANCY: f-2 (proposed) — the lifecycle and the epoch, re-checked right below.
            let resume = await self.resumePoint(after: request)
            guard self.isRunning, self.state.jobs[transfer]?.epoch == epoch else {
                return
            }
            self.state.jobs[transfer]?.resume = resume
            self.retryLater(transfer, error: error)
            if cause == .sourceVersionSkew {
                self.requestManifestCheck()
            }
            _ = retryAfter
        case .permanentMissing:
            self.transition(transfer, to: .failed(.untilEntryChanges))
            // A 404 for content never fails an asset the store holds at that content (R-NET-6, L4-R5): an id the store
            // serves at its current content (a location that is not stale) while the engine's copy maps it to this
            // content is answered from the store and left out of the recorded failure.
            // REENTRANCY: f-10 (proposed) — the lifecycle and the job epoch, re-checked after the reads; the interests
            // answered from the store are those the job holds then.
            let ids = await self.sparePresent(of: transfer, epoch: epoch, assets: job.assets)
            // The failure is persisted for the job's absent ids even when the job ended meanwhile, or shutdown began
            // during the reads (ADR-032: no run and no relaunch requests the content again before its entry changes; the
            // store refuses the write once it closed).
            if !ids.isEmpty {
                do {
                    // REENTRANCY: RE-S35 — the job's next state was decided before the await; the store re-checks the
                    // identity itself; a binding of these ids learned meanwhile is forgotten below.
                    try await self.store.recordFailure(ids, identity: job.identity, reason: .notFound)
                } catch {
                    // After shutdown began the store refuses, or the commit is cancelled: nothing is left to report to.
                    if self.isRunning {
                        self.record(ids.first, .storage, "recording a 404 failed: \(error)")
                    }
                }
                // An id bound during the await is left present: the store's guard skips a record bound to a live blob
                // at this identity (L4-R16). The binding is forgotten so that the next resolve reads the store. This
                // job's waiters for such an id are still answered `notFound` below (the residual of F-22 and F-31).
                self.forgetBound(ids)
            }
            guard self.isRunning, self.state.jobs[transfer]?.epoch == epoch else {
                if self.isRunning {
                    self.pump()
                    self.reconcileIdle()
                    if !ids.isEmpty {
                        // `recordFailure` dooms a failed stale record's blob and publishes at bulk urgency: its trailing
                        // install runs on the alarm whatever became of the job (orchestrator ruling L5K-R16).
                        // REENTRANCY: RE-S40 — the lifecycle (inside); the store entry of the heap is replaced.
                        await self.refreshStoreDeadline()
                    }
                }
                return
            }
            self.resolveAll(transfer, with: .failed(.notFound))
            // REENTRANCY: RE-S40 — the lifecycle; the store entry of the heap is replaced.
            await self.refreshStoreDeadline()
        case .authentication:
            self.transition(transfer, to: .failed(.nextRun))
            let confirmed: Bool
            if let origin = self.state.remote?.originID, case .open(.authentication, _, _)? = self.state.breakers[origin]?.state {
                confirmed = true
            } else {
                confirmed = false
            }
            self.resolveAll(transfer, with: .failed(.authRejected(confirmed ? .confirmed : .ambiguous)))
        case .integrity:
            self.state.metrics.integrityFailures += 1
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.integrityFailed(transfer, epoch: epoch, ids: job.assets.sorted(), identity: job.identity)
        case .insufficientSpace(let required):
            // Undecided until the free space is read: parked, retried or awaiting the reaper (`spaceFailed`).
            self.transition(transfer, to: .failed(.nextRun))
            // The bytes written before ENOSPC stay in the attempt's partial and occupy the space that is short: kept
            // for resume when a sidecar makes them resumable, otherwise discarded now (R-CLN-3, L4-R6).
            // REENTRANCY: f-2 (proposed) — the lifecycle and the epoch, re-checked right below.
            let resume = await self.resumePoint(after: request)
            guard self.isRunning, self.state.jobs[transfer]?.epoch == epoch else {
                return
            }
            self.state.jobs[transfer]?.resume = resume
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.spaceFailed(transfer, epoch: epoch, required: required ?? job.entry.byteSize ?? 0)
        case .rejected:
            self.transition(transfer, to: .failed(.nextRun))
            self.resolveAll(transfer, with: .failed(.serverUnavailable(retryAfter: nil)))
        }
        self.pump()
        self.reconcileIdle()
    }

    /// The breaker input of a transfer failure (ARCHITECTURE §7.6 "Breaker input").
    static func breakerOutcome(_ error: TransferError, transfer: TransferID, asset: AssetID?) -> CircuitBreaker.Outcome {
        switch error {
        case .transient(.serverError, _):
            return .failure(transfer, .serverErrors, distinctAsset: nil)
        case .authentication(.forbiddenAmbiguous):
            return .failure(transfer, .authentication, distinctAsset: asset ?? AssetID(transfer.rawValue))
        case .cancelled:
            return .abandoned(transfer)
        default:
            return .neutral(transfer)
        }
    }

    /// A fresh attempt now: `downloading → queued`, no backoff, the attempt counter unchanged.
    private func requeue(_ transfer: TransferID, discarding request: TransferRequest?) {
        self.state.jobs[transfer]?.active = nil
        if self.transition(transfer, to: .queued) {
            self.enqueue(transfer)
        }
    }

    /// Backoff with full jitter (R-SYN-5): interests whose lane's attempt cap is reached receive the error (or
    /// `answer`, the engine's own figures), the rest wait for `failed(.at)` (the alarm re-queues, T18) or a satisfied
    /// edge (T19). The interactive policy applies while the job's lane is user-initiated (sync.md §8.2).
    func retryLater(_ transfer: TransferID, error: TransferError, answer: AssetError? = nil) {
        let wall = self.environment.time.now()
        let assetError = answer ?? error.assetError(now: wall)
        guard let remaining = self.countFailedAttempt(transfer, error: error, assetError: assetError) else {
            return
        }
        let attempts = remaining.attempts
        let policy = remaining.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry
        let retryAfter: TimeInterval?
        if case .transient(_, let hint?) = error {
            retryAfter = hint.seconds(from: wall)
        } else {
            retryAfter = nil
        }
        guard let delay = Backoff.delay(
            attempt: attempts,
            retryAfter: retryAfter,
            policy: policy,
            seed: self.environment.random.seed,
            key: StableHash.fnv1a64(transfer.rawValue)
        ) else {
            self.transition(transfer, to: .failed(.nextRun))
            self.resolveAll(transfer, with: .failed(assetError))
            return
        }
        let at = self.environment.time.monotonicNow().adding(seconds: delay)
        if self.transition(transfer, to: .failed(.at(at))) {
            self.state.heap.schedule(.retry(transfer, epoch: remaining.epoch), at: at)
            self.rearm()
        }
        self.notifyObservers()
        self.checkRunSettled()
    }

    /// Counts a failed attempt toward the retry caps (R-SYN-5): the interests whose lane's cap the count reaches receive
    /// `assetError` (the interactive policy for user-initiated ones, sync.md §8.2); when none is left the job ends
    /// `failed(.nextRun)` and the run is checked for settling. Returns the job while interests remain. Shared by
    /// `retryLater` and by an ENOSPC that parks `awaitingSpace` (L4-R4), so a wait for the store's reclaim joins the
    /// same budget as a backoff.
    private func countFailedAttempt(_ transfer: TransferID, error: TransferError, assetError: AssetError) -> Job? {
        // The ids an owed follow moved leave first (`followBeforeActing`): the attempt, and an answer at the cap, are not
        // theirs.
        guard !self.followBeforeActing(transfer), var job = self.state.jobs[transfer] else {
            return nil
        }
        let claimOnly = job.interests.isEmpty
        job.attempts += 1
        job.active = nil
        job.transientFailure = true
        job.lastError = assetError
        self.state.jobs[transfer] = job
        if let failureClass = error.failureClass {
            self.state.metrics.retries[failureClass] += 1
        }
        let attempts = job.attempts
        for token in job.interests.keys.sorted() {
            guard let interest = self.state.jobs[transfer]?.interests[token] else {
                continue
            }
            let policy = interest.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry
            if attempts >= max(1, policy.maxAttemptsPerRun) {
                self.deliver(.failed(assetError), to: token, interest: interest, transfer: transfer)
                self.state.jobs[transfer]?.interests[token] = nil
            }
        }
        guard let remaining = self.state.jobs[transfer], !remaining.interests.isEmpty || (claimOnly && self.claimRetries(remaining, attempts: attempts)) else {
            if self.state.jobs[transfer] != nil {
                self.transition(transfer, to: .failed(.nextRun))
                self.publishTerminal(job: job, outcome: .failed(assetError))
                self.removeJob(transfer)
            }
            self.checkRunSettled()
            return nil
        }
        return remaining
    }

    /// Whether a job only a pending claim keeps, with no interest when its attempt failed, still has attempts left under
    /// the retry policy of the lane it held (`Job.heldLane`): the claim stands for the released interest until the
    /// successor's join adds one, so its failures count as that interest's would. Without this the job ended on its first
    /// failed attempt with an `assetFailed` nobody asked for, and the join started the transfer afresh (L5-R16; Stage 3,
    /// S3-B-081).
    private func claimRetries(_ job: Job, attempts: Int) -> Bool {
        guard let lane = job.heldLane, self.state.claims[ClaimKey(job: job)] != nil else {
            return false
        }
        let policy = lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry
        return attempts < max(1, policy.maxAttemptsPerRun)
    }

    /// A 429 (ARCHITECTURE §7.6): an origin-wide throttle until the clamped deadline (a `Retry-After` above
    /// `maxRetryAfter` defers to the next run); the job parks `throttled`.
    private func throttled(_ transfer: TransferID, retryAfter: RetryAfter?, wall: Date) {
        guard let job = self.state.jobs[transfer], let origin = self.state.remote?.originID else {
            return
        }
        let policy = job.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry
        let seconds = retryAfter?.seconds(from: wall)
        guard let delay = Backoff.delay(attempt: job.attempts + 1, retryAfter: seconds, policy: policy, seed: self.environment.random.seed, key: StableHash.fnv1a64(origin)) else {
            self.transition(transfer, to: .failed(.nextRun))
            self.resolveAll(transfer, with: .failed(.serverUnavailable(retryAfter: seconds)))
            return
        }
        let until = self.environment.time.monotonicNow().adding(seconds: max(delay, seconds ?? 0))
        let previous = self.state.throttles[origin]
        let end = max(previous ?? .zero, until)
        self.state.throttles[origin] = end
        self.state.metrics.retries[.throttled] += 1
        self.state.jobs[transfer]?.active = nil
        self.throttleExtended(from: previous)
        self.park(transfer, reason: .throttled(until: end))
    }

    /// A 429 moved the origin's throttle end later than `previous`, the end in force before it. A pending run that waits for
    /// the throttle moves to the new end: it was scheduled at the end in force when it was set, and at that end it would
    /// start a run the throttle refuses at its manifest step (close-out cycle 19, F-39). A user-initiated request waits for
    /// a throttle only while its end is within `interactiveMaxWait` (sync.md §8.2, `RetryPolicy`), so the user-initiated
    /// waiters of the jobs the throttle had already parked get the fail-fast answer for the new end, the one a request made
    /// now gets (close-out cycle 16, F-36); every other interest keeps waiting for the end. The answers come in a later
    /// turn of their own (`answerThrottledUsers()`), so the 429's turn stays O(1).
    func throttleExtended(from previous: MonotonicInstant?) {
        guard let origin = self.state.remote?.originID, let end = self.state.throttles[origin], end > (previous ?? .zero) else {
            return
        }
        if self.state.pendingRun?.gate == .throttle {
            self.state.heap.schedule(.pendingRun, at: end)
            self.state.pendingRun?.scheduled = true
            self.rearm()
        }
        guard !self.state.throttleParked.isEmpty else {
            return
        }
        self.scheduleThrottleAnswers()
    }

    /// Schedules one later turn for `answerThrottledUsers()`.
    private func scheduleThrottleAnswers() {
        guard !self.state.throttleAnswersScheduled else {
            return
        }
        self.state.throttleAnswersScheduled = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the turn re-reads the throttle, the
            // clock and the throttle's index.
            await engine.answerThrottledUsers()
        }
        if spawned == nil {
            self.state.throttleAnswersScheduled = false
        }
    }

    /// The scheduled turn: while the origin's throttle ends beyond `interactiveMaxWait`, the user-initiated `resolve`
    /// and `ensureAvailable` interests of the jobs it parked get the fail-fast answer (`failFast`, which reads the
    /// origin's end), at most `parksPerPump` jobs per turn, each answer costing about what a park does (C2); a later turn
    /// takes the rest. Every interest it answers leaves its job, so each turn makes progress. One pass over the
    /// throttle's index (`throttleParked`), never every job. A pump follows: an `ensureAvailable` group whose members
    /// failed fast materialises its next ones, which the gate parks and answers the same way.
    private func answerThrottledUsers() {
        self.state.throttleAnswersScheduled = false
        guard self.isRunning, let origin = self.state.remote?.originID, let end = self.state.throttles[origin] else {
            return
        }
        guard end.seconds(since: self.environment.time.monotonicNow()) > self.tuning.interactiveRetry.interactiveMaxWait else {
            // Every user-initiated interest still waits within its bound.
            return
        }
        // One read of the job table (a closure over `self.state` would copy the whole engine state per job).
        let jobs = self.state.jobs
        var users: [(ticket: UInt64, transfer: TransferID)] = []
        for transfer in self.state.throttleParked {
            guard let job = jobs[transfer] else {
                continue
            }
            let answered = job.interests.values.contains { interest in
                interest.lane == .userInitiated && (interest.kind == .waiter || interest.kind == .ensure)
            }
            if answered {
                users.append((job.ticket, transfer))
            }
        }
        guard !users.isEmpty else {
            return
        }
        // In queue order (the tickets), a deterministic order whose comparisons are integers: sorting 10,000 transfer
        // identifiers, 66-character strings, took most of a turn's budget.
        users.sort { ($0.ticket, $0.transfer) < ($1.ticket, $1.transfer) }
        for user in users.prefix(Self.parksPerPump) {
            guard case .blocked(let reason)? = self.state.jobs[user.transfer]?.state else {
                continue
            }
            self.failFast(user.transfer, reason: reason)
        }
        if users.count > Self.parksPerPump {
            self.scheduleThrottleAnswers()
        }
        self.pump()
        self.rearm()
        self.notifyObservers()
    }

    /// Integrity bookkeeping in the store (R-INT-3, ADR-032): the failure is persisted with its backoff, every interest
    /// receives `.integrityFailure`, and the persisted quarantine decides the next attempt (every lane honours it).
    func integrityFailed(_ transfer: TransferID, epoch: UInt64, ids: [AssetID], identity: ContentIdentity) async {
        self.transition(transfer, to: .failed(.untilEntryChanges))
        // A failed transfer never fails a present record (L4-R5, R-INT-3), as for a 404: the ids the store serves at
        // their current content while the engine's copy maps them to this content are answered from the store and left
        // out of the bookkeeping, which would otherwise count the failure against a valid copy (and, at the cap, drop it).
        // REENTRANCY: f-10 (proposed) — the lifecycle and the job epoch, re-checked after the reads; the interests
        // answered from the store are those the job holds then.
        let absent = await self.sparePresent(of: transfer, epoch: epoch, assets: Set(ids))
        if !absent.isEmpty {
            do {
                // REENTRANCY: RE-S35 — the job's next state was decided before the await; the store leaves records whose
                // identity changed alone.
                try await self.store.recordIntegrityFailure(absent, identity: identity)
            } catch {
                if self.isRunning {
                    self.record(absent.first, .storage, "recording an integrity failure failed: \(error)")
                }
            }
            // A binding learned during the await may have ended with it (a failure at the cap), thrown or not (ADR-050).
            self.forgetBound(absent)
        }
        guard self.isRunning, self.state.jobs[transfer]?.epoch == epoch else {
            if self.isRunning {
                // Every interest may have been answered from the store: the job's pipeline place is free.
                self.pump()
                if !absent.isEmpty {
                    // `recordIntegrityFailure` dooms a blob at the cap and publishes at bulk urgency: its trailing install
                    // runs on the alarm whatever became of the job (orchestrator ruling L5K-R16).
                    // REENTRANCY: RE-S40 — the lifecycle (inside); the store entry of the heap is replaced.
                    await self.refreshStoreDeadline()
                }
            }
            return
        }
        self.resolveAll(transfer, with: .failed(.integrityFailure))
        // REENTRANCY: RE-S40 — the lifecycle; the store entry of the heap is replaced.
        await self.refreshStoreDeadline()
    }

    /// Before a failure of `transfer`'s content is recorded (a 404, an integrity failure), reads which of `assets` the
    /// store serves at their current content while the engine's copy maps them to this content (one O(1) location read
    /// per id, never a planning view, C2), answers those from the store when the job is still `epoch`'s, and returns the
    /// others, sorted: the ids the failure is recorded for (L4-R5: a failed transfer never fails a present record). The
    /// bindings read are recorded unless a binding was forgotten during the reads; the returned ids are forgotten (the
    /// store's bookkeeping may unbind them).
    func sparePresent(of transfer: TransferID, epoch: UInt64, assets: Set<AssetID>) async -> [AssetID] {
        let serial = self.state.ledgerForgets
        var present: Set<AssetID> = []
        for id in assets.sorted() where self.state.applied.entry(for: id)?.transferID == transfer {
            // REENTRANCY: f-10 (proposed) — the lifecycle and the job epoch, re-checked after the reads.
            if let location = await self.store.location(for: id, extensions: [], recordingAccess: false), !location.isStale {
                present.insert(id)
            }
        }
        let absent = assets.subtracting(present).sorted()
        guard self.isRunning else {
            return absent
        }
        self.bind(present, to: transfer, since: serial)
        if let current = self.state.jobs[transfer], current.epoch == epoch {
            self.answerPresentMembers(of: transfer, present)
            if self.state.jobs[transfer]?.interests.isEmpty == true {
                // Every interest was in a present id: nobody is left to answer (the absent ids are still recorded).
                self.removeJob(transfer)
            }
        }
        self.forgetBound(absent)
        return absent
    }

    /// ENOSPC (ARCHITECTURE §7.6), decided on a fresh free-space read: `awaitingSpace` when the store has pending
    /// reclaim (the reaper wakes it; the attempt counts toward the retry caps, L4-R4); a retry with backoff when the
    /// volume holds what the job needs after all (the ENOSPC was transient: parking it would fail every joiner with stale
    /// figures and leave the job parked for ever); else `insufficientSpace` with the bytes the attempt needs and the job's
    /// room above the reserve (F-22), re-evaluated at every later read (T17).
    func spaceFailed(_ transfer: TransferID, epoch: UInt64, required: Int64) async {
        self.state.jobs[transfer]?.active = nil
        // REENTRANCY: f-4 (proposed) — the lifecycle and the epoch below; the figures are a fresh snapshot; the ids an
        // owed follow moved (an apply may have landed during the read) leave the job before its park answers them.
        await self.refreshFreeSpace()
        guard self.isRunning, self.state.jobs[transfer]?.epoch == epoch, !self.followBeforeActing(transfer), self.state.jobs[transfer] != nil else {
            return
        }
        if self.defersToFollow {
            // The verdict reads the room, the bytes in flight and the job's lane, which the owed visits change: it waits
            // for the follow's end (F-28). The read above is adopted already (S3-R11 R1).
            self.state.eventsAfterFollow.append(.spaceFailure(transfer, epoch: epoch, required: required))
            return
        }
        self.decideSpaceFailure(transfer, required: required)
    }

    /// `spaceFailed`'s verdict on the latest read: retry, `awaitingSpace` or `insufficientSpace` with its figures.
    func decideSpaceFailure(_ transfer: TransferID, required: Int64) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let space = self.state.freeSpace
        let reclaiming = (space?.pendingReclaim ?? 0) > 0
        // The bytes the attempt needed and the job's room above the reserve (the planner's convention, §7.10).
        let figures = AssetError.insufficientSpace(required: required, available: space.map { self.headroom(for: job, in: $0) } ?? 0)
        self.state.jobs[transfer]?.lastError = figures
        guard case .failed = job.state else {
            // A user request re-queued it meanwhile (T20): the gate's ledger decides with the figures just read.
            return
        }
        if !reclaiming, let measured = self.state.jobs[transfer], self.spaceBlock(measured) == nil {
            self.retryLater(transfer, error: .insufficientSpace(requiredBytes: required), answer: figures)
            return
        }
        if reclaiming {
            // The wait for the reclaim stands where the backoff would, but the attempt joins the retry budget all the
            // same (L4-R4): when nothing reclaims on time, the settlement's fresh read re-queues a job the volume holds
            // at once, so a volume that keeps answering ENOSPC while it reads roomy would otherwise start the transfer
            // again without end (review of close-out cycle 6). Interests at their cap get the figures; none left ends it.
            guard self.countFailedAttempt(transfer, error: .insufficientSpace(requiredBytes: required), assetError: figures) != nil else {
                return
            }
        }
        guard self.transition(transfer, to: .queued) else {
            return
        }
        self.park(transfer, reason: reclaiming ? .awaitingSpace : .insufficientSpace)
        self.checkRunSettled()
    }

    /// Reads the store's free space into the headroom ledger (S2-09: committed bytes stay until the next read).
    func refreshFreeSpace() async {
        do {
            // REENTRANCY: f-4 (proposed) — the lifecycle; the read is adopted in the turn it returns (`readFreeSpace`).
            _ = try await self.readFreeSpace()
        } catch {
            return
        }
        if self.isRunning {
            self.reconsiderSpaceBlocked()
        }
    }

    /// One free-space read, adopted as the headroom ledger's base in the turn it returns (L4-R7, S2-09): the bytes
    /// committed since the read began stay in the ledger, because the read may have measured the volume before they
    /// landed (counting them twice only understates headroom; dropping them would overstate it).
    func readFreeSpace() async throws(StoreError) -> FreeSpace {
        let mark = self.state.committedTotal
        // REENTRANCY: f-4 (proposed) — the lifecycle (the callers re-check it); the ledger's base is replaced whole by
        // this read, keeping only the commits counted since `mark`.
        let space = try await self.store.freeSpace()
        self.state.freeSpace = space
        self.state.committedSinceRead = max(0, self.state.committedTotal &- mark)
        return space
    }

    // MARK: Breaker bookkeeping (ARCHITECTURE §7.7)

    /// Records an outcome on the origin's breaker; a state change emits `circuitChanged`, counts a trip, re-arms
    /// the alarm and settles waiting runs.
    func recordBreaker(_ outcome: CircuitBreaker.Outcome) {
        guard let origin = self.state.remote?.originID else {
            return
        }
        var breaker = self.state.breakers[origin] ?? CircuitBreaker(policy: self.tuning.breaker)
        let before = breaker.publicState
        let probing = breaker.probe != nil
        breaker.record(outcome, at: self.environment.time.monotonicNow(), seed: self.environment.random.seed)
        self.state.breakers[origin] = breaker
        self.breakerChanged(origin, from: before)
        if probing, breaker.probe == nil, case .halfOpen = breaker.state {
            self.probeEndedWithoutVerdict()
        }
        self.reconsiderPendingRun()
    }

    /// The half-open probe ended without a verdict (404, 400, an integrity failure, offline, a different cause, or
    /// abandoned: cancelled, paused, superseded): the breaker is `halfOpen(probe: nil)` and admits the next transfer as
    /// its probe. The public state did not change, so `breakerChanged` did nothing; the jobs the breaker parked behind the
    /// probe are re-admitted here, in the turn the gate opened, and the old probe's watchdog deadline is dropped. Without
    /// this nothing re-admitted them before that watchdog (up to `probeWatchdog` later): a run whose claims they were
    /// settled blocked by a gate that admits, and its pending run started one run and one manifest request per parked
    /// missing asset without the clock moving (close-out cycle 20, L4-R20, F-40). The first job the pump dispatches
    /// probes, and the others park again behind it, as at a cooldown's end.
    ///
    /// A pump is owed whether or not anything was parked (close-out cycle 22, F-42): jobs that wait in the queue for a slot
    /// are not parked, and the exit's own caller frees a slot and pumps after this hook returns, so a pending run that read
    /// no pump owed (`dispatchOwed`) in `recordBreaker`'s reconsideration started, and that caller's pump gave the freed slot
    /// to the next queued job (one blocked run per queued member, PROBE-C21C-QUEUED-PROBES). With the follow-up owed the
    /// pending run waits for the pumps that dispatch those jobs, and starts once none can start (F-41); the run then holds
    /// the probe for its manifest fetch from its start turn (`reserveManifestProbe`).
    private func probeEndedWithoutVerdict() {
        self.scheduleBreakerDeadline()
        self.schedulePumpFollowUp()
        guard !self.state.circuitParked.isEmpty else {
            return
        }
        self.unblockOrigin(.circuitOpen)
    }

    /// Emits and schedules after a breaker change.
    func breakerChanged(_ origin: String, from before: CircuitState) {
        guard let breaker = self.state.breakers[origin] else {
            return
        }
        let after = breaker.publicState
        guard after != before else {
            return
        }
        if case .open = after {
            if case .open = before {} else {
                self.state.metrics.breakerTrips += 1
            }
        }
        self.broadcast(.circuitChanged(originID: origin, after))
        self.scheduleBreakerDeadline()
        if case .closed = after {
            self.unblockOrigin(.circuitOpen)
            self.reconsiderPendingRun()
        }
    }

    /// Puts the breaker's next deadline (cooldown end, probe watchdog) in the heap.
    func scheduleBreakerDeadline() {
        guard let origin = self.state.remote?.originID else {
            return
        }
        if let at = self.state.breakers[origin]?.nextDeadline() {
            self.state.heap.schedule(.breaker(origin), at: at)
        } else {
            self.state.heap.remove(.breaker(origin))
        }
        self.rearm()
    }
}
