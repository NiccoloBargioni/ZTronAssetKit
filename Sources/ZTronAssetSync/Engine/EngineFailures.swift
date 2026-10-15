import Foundation
import ZTronAssetModel
import ZTronAssetStorage

extension SyncEngine {
    // MARK: Pause (T7)

    /// A paused attempt: a preempted one resumes first in its lane, a policy pause parks it; the next attempt continues
    /// from the attempt's sidecar when there is one (the transport's resumable flag is not trusted, D-13).
    func paused(_ transfer: TransferID, epoch: UInt64, request: TransferRequest) async {
        guard let job = self.state.jobs[transfer], let active = job.active else {
            return
        }
        self.recordBreaker(.abandoned(transfer))
        let policyPause = active.policyPause
        // REENTRANCY: f-2 (proposed) — the lifecycle and the epoch below; the resume point is kept only for this job.
        let resume = await self.resumePoint(after: request)
        guard self.isRunning, var current = self.state.jobs[transfer], current.epoch == epoch else {
            return
        }
        current.resume = resume
        current.active = nil
        self.state.jobs[transfer] = current
        if let policyPause, current.lane < .userInitiated {
            self.park(transfer, reason: .policy(policyPause))
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
            self.state.jobs[transfer]?.active = nil
            self.state.jobs[transfer]?.transientFailure = true
            if self.transition(transfer, to: .failed(.whenOnline)) {
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
            // A 404 for content never fails an asset the store holds at that content (R-NET-6, L4-R5): the ids the
            // store shows present are answered from it and left out of the recorded failure.
            let view: StorePlanningView?
            do {
                // REENTRANCY: f-10 (proposed) — the lifecycle and the job epoch below; the present ids are read from
                // this snapshot, and the job's own ids are re-read after it.
                view = try await self.store.planningView()
            } catch {
                view = nil
            }
            guard self.isRunning, let current = self.state.jobs[transfer], current.epoch == epoch else {
                return
            }
            if let view {
                self.noteBound(from: view, ids: current.assets)
            }
            let present = current.assets.filter { self.isBound($0, to: transfer) }
            self.answerPresentMembers(of: transfer, present)
            if self.state.jobs[transfer]?.interests.isEmpty == true {
                // Every interest was in a present id: nobody is left to answer (the absent ids are still recorded).
                self.removeJob(transfer)
            }
            let ids = current.assets.subtracting(present).sorted()
            self.forgetBound(ids)
            if !ids.isEmpty {
                do {
                    // REENTRANCY: RE-S35 — the job's next state was decided before the await; the store re-checks the
                    // identity itself.
                    try await self.store.recordFailure(ids, identity: current.identity, reason: .notFound)
                } catch {
                    self.record(ids.first, .storage, "recording a 404 failed: \(error)")
                }
            }
            guard self.isRunning, self.state.jobs[transfer]?.epoch == epoch else {
                if self.isRunning {
                    self.pump()
                    self.reconcileIdle()
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
        guard var job = self.state.jobs[transfer] else {
            return
        }
        let wall = self.environment.time.now()
        let assetError = answer ?? error.assetError(now: wall)
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
        guard let remaining = self.state.jobs[transfer], !remaining.interests.isEmpty else {
            if self.state.jobs[transfer] != nil {
                self.transition(transfer, to: .failed(.nextRun))
                self.publishTerminal(job: job, outcome: .failed(assetError))
                self.removeJob(transfer)
            }
            self.checkRunSettled()
            return
        }
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
        self.state.throttles[origin] = max(self.state.throttles[origin] ?? .zero, until)
        self.state.metrics.retries[.throttled] += 1
        self.state.jobs[transfer]?.active = nil
        self.park(transfer, reason: .throttled(until: self.state.throttles[origin] ?? until))
    }

    /// Integrity bookkeeping in the store (R-INT-3, ADR-032): the failure is persisted with its backoff, every interest
    /// receives `.integrityFailure`, and the persisted quarantine decides the next attempt (every lane honours it).
    func integrityFailed(_ transfer: TransferID, epoch: UInt64, ids: [AssetID], identity: ContentIdentity) async {
        self.transition(transfer, to: .failed(.untilEntryChanges))
        // The store's bookkeeping may unbind them (a failure at the cap, L4-R5).
        self.forgetBound(ids)
        do {
            // REENTRANCY: RE-S35 — the job's next state was decided before the await; the store leaves records whose
            // identity changed alone.
            try await self.store.recordIntegrityFailure(ids, identity: identity)
        } catch {
            self.record(ids.first, .storage, "recording an integrity failure failed: \(error)")
        }
        guard self.isRunning, self.state.jobs[transfer]?.epoch == epoch else {
            return
        }
        self.resolveAll(transfer, with: .failed(.integrityFailure))
        // REENTRANCY: RE-S40 — the lifecycle; the store entry of the heap is replaced.
        await self.refreshStoreDeadline()
    }

    /// ENOSPC (ARCHITECTURE §7.6), decided on a fresh free-space read: `awaitingSpace` when the store has pending
    /// reclaim (the reaper wakes it); a retry with backoff when the volume holds what the job needs after all (the
    /// ENOSPC was transient: parking it would fail every joiner with stale figures and leave the job parked for ever);
    /// else `insufficientSpace` with the store's measured figures, re-evaluated at every later read (T17).
    func spaceFailed(_ transfer: TransferID, epoch: UInt64, required: Int64) async {
        self.state.jobs[transfer]?.active = nil
        // REENTRANCY: f-4 (proposed) — the lifecycle and the epoch below; the figures are a fresh snapshot.
        await self.refreshFreeSpace()
        guard self.isRunning, let job = self.state.jobs[transfer], job.epoch == epoch else {
            return
        }
        let space = self.state.freeSpace
        let reclaiming = (space?.pendingReclaim ?? 0) > 0
        let volume = job.lane == .userInitiated ? space?.volumeImportant : space?.volumeOpportunistic
        let figures = AssetError.insufficientSpace(required: required, available: max(0, volume ?? 0))
        self.state.jobs[transfer]?.lastError = figures
        guard case .failed = job.state else {
            // A user request re-queued it meanwhile (T20): the gate's ledger decides with the figures just read.
            return
        }
        if !reclaiming, let measured = self.state.jobs[transfer], self.spaceBlock(measured) == nil {
            self.retryLater(transfer, error: .insufficientSpace(requiredBytes: required), answer: figures)
            return
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
            // REENTRANCY: f-4 (proposed) — the lifecycle; the read replaces the ledger's base atomically.
            let space = try await self.store.freeSpace()
            self.state.freeSpace = space
            self.state.committedSinceRead = 0
        } catch {
            return
        }
        if self.isRunning {
            self.reconsiderSpaceBlocked()
        }
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
        breaker.record(outcome, at: self.environment.time.monotonicNow(), seed: self.environment.random.seed)
        self.state.breakers[origin] = breaker
        self.breakerChanged(origin, from: before)
        self.reconsiderPendingRun()
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
            self.unblock { reason in
                if case .circuitOpen = reason {
                    return true
                }
                return false
            }
            if self.state.pendingRun?.gate == .breaker {
                self.fulfilPendingRun()
            }
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

    /// Re-queues every blocked job whose reason `matches` (T17).
    func unblock(where matches: (BlockReason) -> Bool) {
        for transfer in self.state.jobs.keys.sorted() {
            guard case .blocked(let reason)? = self.state.jobs[transfer]?.state, matches(reason) else {
                continue
            }
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
            }
        }
    }
}
