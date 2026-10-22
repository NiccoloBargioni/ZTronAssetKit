import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// What an interest receives when its job ends for it.
enum InterestOutcome {
    /// The content committed: the bound locations by asset.
    case committed([AssetID: AssetLocation])
    /// The job failed for this interest.
    case failed(AssetError)
}

extension SyncEngine {
    // MARK: Transitions (R-SYN-2)

    /// The only mutator of `Job.state`: an illegal transition is counted (`illegalTransitions`) and logged, never
    /// applied (every engine test asserts the counter is 0; ARCHITECTURE §7.1, sync-2 S2-26).
    @discardableResult
    func transition(_ transfer: TransferID, to next: JobState) -> Bool {
        guard var job = self.state.jobs[transfer] else {
            return false
        }
        guard job.state.allows(next) else {
            self.state.metrics.illegalTransitions += 1
            let from = String(describing: job.state.kind)
            let to = String(describing: next.kind)
            self.log.log(.sync, .fault, "illegal transition \(from) → \(to)")
            return false
        }
        let before = job.ledgerBytes
        let previous = job.state
        job.state = next
        self.reindex(transfer, from: previous, to: next)
        let after = job.ledgerBytes
        if let before {
            self.state.inFlightBytes.remove(before)
        }
        if let after {
            self.state.inFlightBytes.add(after)
            self.state.inFlight.insert(transfer)
        } else if before != nil {
            self.state.inFlight.remove(transfer)
        }
        if next.kind != .downloading {
            // Only a downloading job has a running attempt (the invariant the model test checks).
            job.active = nil
        }
        self.state.jobs[transfer] = job
        return true
    }

    /// Keeps the indexes of parked and failed jobs (`spaceParked`, `laneParked`, `circuitParked`, `throttleParked`,
    /// `failedJobs`, and the owed re-queues `edgeOwed` and `originOwed`, which a job leaves when it leaves `failed` or
    /// its origin's park) in step with one transition; `invariantViolations()` checks them against the job table.
    private func reindex(_ transfer: TransferID, from previous: JobState, to next: JobState) {
        if next.isSpaceParked {
            self.state.spaceParked.insert(transfer)
        } else if previous.isSpaceParked {
            self.state.spaceParked.remove(transfer)
        }
        if next.isLaneParked {
            self.state.laneParked.insert(transfer)
        } else if previous.isLaneParked {
            self.state.laneParked.remove(transfer)
        }
        if next.isCircuitParked {
            self.state.circuitParked.insert(transfer)
        } else if previous.isCircuitParked {
            self.state.circuitParked.remove(transfer)
        }
        if next.isThrottleParked {
            self.state.throttleParked.insert(transfer)
        } else if previous.isThrottleParked {
            self.state.throttleParked.remove(transfer)
        }
        if previous.isOriginParked, !next.isOriginParked {
            self.state.originOwed.remove(transfer)
        }
        if next.kind == .failed {
            self.state.failedJobs.insert(transfer)
        } else if previous.kind == .failed {
            self.state.failedJobs.remove(transfer)
            self.state.edgeOwed.remove(transfer)
        }
    }

    // MARK: Interests (H-3, ADR-020)

    /// Adds (or widens) interest `token` in the job of `entry`'s content for `asset`, creating the job (T1) or joining
    /// and promoting it (T15, T20). Promotion is issued synchronously, before any start of this actor turn
    /// (sync-1 S1-06).
    func addInterest(_ token: InterestToken, asset: AssetID, entry: ManifestEntry, lane: AssetPriority, kind: InterestKind) {
        let transfer = entry.transferID
        let now = self.environment.time.monotonicNow()
        if self.state.jobs[transfer] == nil {
            self.state.lastEpoch += 1
            self.state.jobsCreated += 1
            var job = Job(
                transfer: transfer,
                entry: entry,
                identity: entry.contentIdentity,
                assets: [asset],
                state: .queued,
                epoch: self.state.lastEpoch,
                queuedAt: now
            )
            job.resume = self.state.launchResumes.removeValue(forKey: transfer)
            job.interests[token] = JobInterest(lane: lane, kind: kind, assets: [asset])
            self.state.jobs[transfer] = job
            self.enqueue(transfer)
            self.ensureWatcher()
            self.notifyObservers()
            return
        }
        guard var job = self.state.jobs[transfer] else {
            return
        }
        let before = job.lane
        // A queued job only released groups want may wait in no queue (a scan set its entry aside, `setsAside`).
        let wasReleasedOnly = job.state == .queued && self.isReleasedOnly(job)
        let ticket = job.ticket
        job.assets.insert(asset)
        if var interest = job.interests[token] {
            interest.assets.insert(asset)
            interest.lane = max(interest.lane, lane)
            job.interests[token] = interest
        } else {
            job.interests[token] = JobInterest(lane: lane, kind: kind, assets: [asset])
        }
        self.state.jobs[transfer] = job
        self.relane(transfer, from: before)
        self.failFastJoiner(token, of: transfer)
        if wasReleasedOnly, let joined = self.state.jobs[transfer], joined.state == .queued, joined.ticket == ticket {
            // Now that this interest wants it, it is queued again (a join at the job's own lane does not re-queue it
            // above): at the place it waited, so jobs re-joined in one turn keep their order and pass no earlier work;
            // an entry left in a queue or aside is stale.
            self.reinstate(transfer)
        }
        self.notifyObservers()
    }

    /// A new interest in a job that stays parked gets the answer a new job would get when it parks (the fail-fast
    /// policy runs only when a job parks, so a joiner would otherwise wait for a gate that may never open). A job parked
    /// for lack of space is re-checked first against the latest free-space read: a new job would start if it fits.
    private func failFastJoiner(_ token: InterestToken, of transfer: TransferID) {
        if case .blocked(.insufficientSpace)? = self.state.jobs[transfer]?.state, let job = self.state.jobs[transfer], self.spaceBlock(job) == nil {
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
            }
            return
        }
        if case .blocked(let reason)? = self.state.jobs[transfer]?.state {
            // A job parked by an origin gate that admits at `now` (its re-admission has not run) is re-admitted, now or
            // by an owed follow-up, rather than answered with a block that no longer holds (F-40).
            let gate = self.originGateNow()
            if gate.admits(reason) == true {
                self.readmitOpenedOriginGates(gate)
                return
            }
        }
        switch self.state.jobs[transfer]?.state {
        case .blocked(let reason)?:
            self.failFast(transfer, reason: reason, only: token)
        case .failed(.whenOnline)?:
            self.failFast(transfer, reason: .offline, only: token)
        default:
            break
        }
    }

    /// A system interest (launch re-attachment, healing): released when the job ends or the first run claims it.
    func addSystemInterest(entry: ManifestEntry, lane: AssetPriority) {
        let token = self.nextToken()
        self.addInterest(token, asset: entry.identifier, entry: entry, lane: lane, kind: .system)
    }

    /// Re-evaluates a job after its lane changed: promotion re-queues or re-prioritises it, demotion re-runs
    /// admission (sync-1 S1-07), and a user request skips a backoff (T20).
    func relane(_ transfer: TransferID, from before: AssetPriority) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let after = job.lane
        let isUser = after == .userInitiated
        switch job.state {
        case .queued:
            if after != before || isUser {
                self.enqueue(transfer)
            }
        case .downloading:
            guard after != before else {
                return
            }
            if after > before {
                self.state.metrics.promotions += 1
            }
            self.setPriority(transfer, after)
            if after < before {
                self.pauseIfRefused(transfer)
            }
        case .failed(let disposition):
            if isUser, disposition != .untilEntryChanges, self.originAdmitsUser() {
                if self.transition(transfer, to: .queued) {
                    self.state.heap.remove(.retry(transfer, epoch: job.epoch))
                    self.enqueue(transfer)
                }
            }
        case .blocked(let reason):
            if after > before, self.blockCleared(reason, lane: after, job: job) {
                if self.transition(transfer, to: .queued) {
                    self.enqueue(transfer)
                }
            }
        case .verifying, .committing:
            break
        }
    }

    /// Whether the origin's breaker and throttle let a user-initiated request skip a backoff (T20).
    private func originAdmitsUser() -> Bool {
        guard self.state.remote != nil else {
            return false
        }
        // The origin's gates as the next dispatch reads them (F-40): no throttle in force, and a breaker that would
        // admit the request (closed, or open to a probe).
        let gate = self.originGateNow()
        return gate.admitsThrottleParked && gate.admitsBreakerParked
    }

    /// Removes interest `token` from `transfer` (all its assets) and retires the job when nobody is left: no interest
    /// and no pending claim of a registered group whose join has not reached the content yet (orchestrator ruling L5-R1,
    /// CCR-G2). Every release, waiter withdrawal and caller cancellation removes interests here, so none of them retires
    /// a job such a registration named; the job keeps its state, its place and its lane (`Job.heldLane`) until that join
    /// adds its interest (a promotion or a demotion of a running transfer reaches the transport as a priority change)
    /// or the claim ends (`dropClaim` retires it then). The engine's other exits do not pass here and are unchanged
    /// (L5-R1): a content left the manifest or changed (`followApplied`, `supersede`), became present (the pre-transfer
    /// read retires its job directly), failed or was held back (`EngineFailures`), or committed (`resolveAll`).
    func removeInterest(_ token: InterestToken, from transfer: TransferID) {
        guard var job = self.state.jobs[transfer], job.interests[token] != nil else {
            return
        }
        let before = job.lane
        job.interests[token] = nil
        if job.interests.isEmpty {
            job.heldLane = before
        }
        self.state.jobs[transfer] = job
        if job.interests.isEmpty {
            let key = ClaimKey(job: job)
            if self.state.claims[key] != nil {
                // Kept for the claim: its last end retires the job (`dropClaim`).
                self.state.claimHeld[key] = transfer
            } else {
                self.retire(transfer)
            }
        } else {
            self.relane(transfer, from: before)
        }
        self.notifyObservers()
    }

    /// The one synchronous removal funnel (ARCHITECTURE §7.1): a job with no interest that is not verifying or
    /// committing is removed and its transfer cancelled; out of verifying/committing it is removed when that ends.
    func retire(_ transfer: TransferID) {
        guard let job = self.state.jobs[transfer], job.interests.isEmpty else {
            return
        }
        switch job.state {
        case .verifying, .committing:
            return
        case .downloading:
            if let active = job.active {
                self.abandon(transfer, active)
            }
            // Whether or not its stream already ended, the transfer leaves without a verdict (§7.7).
            self.recordBreaker(.abandoned(transfer))
        case .queued, .failed, .blocked:
            break
        }
        self.removeJob(transfer)
    }

    /// Cancels a running attempt nobody wants any more and, while its terminal element is still outstanding, records it
    /// as draining so no new attempt of the transfer starts before its stream ended (`finishAttempt` clears it). An
    /// attempt whose terminal element was consumed (its driver awaits a sidecar read or a discard) or that has no stream
    /// is over: recording it would leave a drain nothing clears, and every later job of the transfer would stay queued.
    /// `true` when the attempt was still running.
    @discardableResult
    func abandon(_ transfer: TransferID, _ active: ActiveAttempt) -> Bool {
        guard !active.terminalReceived else {
            return false
        }
        self.state.draining[transfer] = DrainingAttempt(attempt: active.attempt, driver: active.driver)
        if let handle = active.handle {
            handle.cancel()
        } else {
            // The driver cancels the handle as soon as `remote.transfer` returns it (RE-S12).
        }
        return true
    }

    /// Drops a job and every deadline, progress key and kept staged file it owns (sync-1 S1-10, ADR-023).
    func removeJob(_ transfer: TransferID) {
        guard let job = self.state.jobs.removeValue(forKey: transfer) else {
            return
        }
        if let bytes = job.ledgerBytes {
            self.state.inFlightBytes.remove(bytes)
            self.state.inFlight.remove(transfer)
        }
        self.state.spaceParked.remove(transfer)
        self.state.laneParked.remove(transfer)
        self.state.circuitParked.remove(transfer)
        self.state.throttleParked.remove(transfer)
        self.state.failedJobs.remove(transfer)
        self.state.edgeOwed.remove(transfer)
        self.state.originOwed.remove(transfer)
        self.state.spaceAdmitted[transfer] = nil
        if let adopt = job.adopt {
            // A drained copy nobody will publish now.
            self.discardLater(adopt.name)
        }
        self.state.heap.remove(.retry(transfer, epoch: job.epoch))
        for asset in job.assets {
            self.retireProgress(.transfer(asset))
        }
        self.compactQueuesIfStale()
        self.notifyObservers()
    }

    // MARK: Lane queues

    /// The queue a job waits in.
    func queueKind(_ job: Job) -> LaneQueues.Kind {
        switch job.lane {
        case .userInitiated:
            return job.isSingleUser ? .userSingle : .userBatch
        case .prefetch:
            return .prefetch
        case .bulk:
            return .bulk
        }
    }

    /// Puts a queued job (back) into its lane's queue with a fresh ticket.
    func enqueue(_ transfer: TransferID, front: Bool = false) {
        guard var job = self.state.jobs[transfer], job.state == .queued else {
            return
        }
        self.state.lastTicket += 1
        job.ticket = self.state.lastTicket
        if !front {
            job.queuedAt = self.environment.time.monotonicNow()
        }
        self.state.jobs[transfer] = job
        let kind = self.queueKind(job)
        let entry = LaneQueues.Entry(ticket: job.ticket, transfer: transfer, queuedAt: job.queuedAt)
        let place = self.state.queues.push(entry, to: kind, front: front)
        self.state.jobs[transfer]?.queuePlace = place
        self.compactQueuesIfStale()
    }

    /// Queues a job again at the place its entry had (`Job.queuePlace`), with a fresh ticket: its old entry, set aside by
    /// a scan or still in place, goes stale. For a job only released groups wanted that an interest at its own lane
    /// wants again (`addInterest`): pushed to the front, the jobs re-joined in one turn were dispatched in reverse order
    /// and ahead of work queued before them (review of close-out cycle 10, PROBE-C10R-3; R-SYN-3).
    func reinstate(_ transfer: TransferID) {
        guard var job = self.state.jobs[transfer], job.state == .queued else {
            return
        }
        self.state.lastTicket += 1
        job.ticket = self.state.lastTicket
        self.state.jobs[transfer] = job
        let entry = LaneQueues.Entry(ticket: job.ticket, transfer: transfer, queuedAt: job.queuedAt, place: job.queuePlace)
        self.state.queues.reinstate(entry, to: self.queueKind(job))
        self.compactQueuesIfStale()
    }

    /// Keeps the lane queues within twice their live entries (sync.md §7.2): once stored entries outnumber twice the
    /// jobs, one pass drops the stale ones. Checked where entries are added (`enqueue`) and where jobs leave
    /// (`removeJob`): a release of queued members left their entries stored until the next enqueue (close-out cycle 11).
    /// The threshold halves the stored entries at each pass, so a release of 10,000 queued members compacts a few
    /// times, not once per member (C2).
    func compactQueuesIfStale() {
        guard self.state.queues.storedCount > 2 * self.state.jobs.count + 16 else {
            return
        }
        // The queues are taken out of the state while the closure reads it (no overlapping access).
        var queues = self.state.queues
        self.state.queues = LaneQueues()
        queues.compact { self.isValid($0) }
        self.state.queues = queues
    }

    /// Whether a queue entry still stands for a queued job.
    func isValid(_ entry: LaneQueues.Entry) -> Bool {
        guard let job = self.state.jobs[entry.transfer] else {
            return false
        }
        return job.ticket == entry.ticket && job.state == .queued
    }

    // MARK: Resolution (S1-02)

    /// Ends interest `token` of `transfer` with `outcome`: a waiter is resumed (through `removeValue`, so at most once),
    /// a group member settles, a run records the outcome; the interest is removed and the job retired when empty.
    func resolve(_ token: InterestToken, of transfer: TransferID, with outcome: InterestOutcome) {
        guard let job = self.state.jobs[transfer], let interest = job.interests[token] else {
            return
        }
        self.deliver(outcome, to: token, interest: interest, transfer: transfer)
        self.removeInterest(token, from: transfer)
    }

    /// Delivers `outcome` to the owner of `token` without touching the job.
    func deliver(_ outcome: InterestOutcome, to token: InterestToken, interest: JobInterest, transfer: TransferID) {
        switch interest.kind {
        case .waiter:
            guard let waiter = self.state.waiters.removeValue(forKey: token) else {
                return
            }
            switch outcome {
            case .committed(let locations):
                if let location = locations[waiter.asset] {
                    waiter.continuation.resume(returning: .success(location))
                } else {
                    waiter.continuation.resume(returning: .failure(.notFound))
                }
            case .failed(let error):
                waiter.continuation.resume(returning: .failure(error))
            }
        case .prefetch, .ensure:
            guard var group = self.state.groups[token] else {
                return
            }
            for asset in interest.assets where group.pending[asset] == transfer {
                group.pending[asset] = nil
            }
            if interest.kind == .ensure, group.spaceFailure == nil, case .failed(let error) = outcome, case .insufficientSpace = error {
                group.spaceFailure = error
            }
            self.state.groups[token] = group
            if interest.kind == .ensure, group.isSettled {
                self.state.groups[token]?.continuation = nil
                group.continuation?.resume(returning: true)
            }
        case .run:
            self.recordRunOutcome(outcome, transfer: transfer, assets: interest.assets)
        case .system:
            // A heal ends with its job, committed or failed (a heal still scheduled for later is kept).
            let now = self.environment.time.monotonicNow()
            for asset in interest.assets {
                if case .committed = outcome {
                    self.state.heals[asset] = nil
                } else if let due = self.state.heals[asset], due <= now {
                    self.state.heals[asset] = nil
                }
            }
        }
    }

    /// Drops `asset` from group `token` while it still waits for `transfer` (the asset left the manifest, T21); an
    /// `ensureAvailable` group whose last member went completes.
    func dropGroupMember(_ token: InterestToken, asset: AssetID, from transfer: TransferID) {
        guard var group = self.state.groups[token], group.pending[asset] == transfer else {
            return
        }
        group.pending[asset] = nil
        self.state.groups[token] = group
        if group.kind == .ensure, group.isSettled, let continuation = group.continuation {
            self.state.groups[token]?.continuation = nil
            continuation.resume(returning: true)
        }
    }

    /// Resolves every interest of `transfer` with `outcome`, in token order, and removes the job; `follow` runs once
    /// the job is gone and before the run is checked for settling (interests that move to a fresh job of the transfer).
    func resolveAll(_ transfer: TransferID, with outcome: InterestOutcome, then follow: () -> Void = {}) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        for token in job.interests.keys.sorted() {
            if let interest = self.state.jobs[transfer]?.interests[token] {
                self.deliver(outcome, to: token, interest: interest, transfer: transfer)
            }
        }
        self.state.jobs[transfer]?.interests.removeAll()
        self.removeJob(transfer)
        self.publishTerminal(job: job, outcome: outcome)
        follow()
        self.checkRunSettled()
    }

    /// The non-bulk per-asset terminal events (bulk outcomes fold into run progress, ADR-023).
    func publishTerminal(job: Job, outcome: InterestOutcome) {
        guard job.lane > .bulk else {
            return
        }
        for asset in job.assets.sorted() {
            switch outcome {
            case .committed(let locations):
                if locations[asset] != nil {
                    self.broadcast(.assetAvailable(asset, generation: self.state.generation))
                }
            case .failed(let error):
                self.broadcast(.assetFailed(asset, error, .nextRun))
            }
        }
    }

    /// The fail-fast policy when a job is parked (ARCHITECTURE §7.6/§7.7): which interests get an answer now; `only`
    /// restricts it to one interest (a joiner of a parked job).
    func failFast(_ transfer: TransferID, reason: BlockReason, only: InterestToken? = nil) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let now = self.environment.time.monotonicNow()
        for token in job.interests.keys.sorted() where only == nil || only == token {
            guard let interest = self.state.jobs[transfer]?.interests[token], interest.kind == .waiter || interest.kind == .ensure else {
                continue
            }
            let error: AssetError?
            switch reason {
            case .offline:
                error = .offline
            case .circuitOpen(let cause):
                error = cause == .authentication ? .authRejected(.confirmed) : .serverUnavailable(retryAfter: nil)
            case .throttled(let until):
                // The origin's end, not the job's: a later 429 may have extended the throttle after it parked (F-36).
                let wait = self.throttleEnd(after: until).seconds(since: now)
                let limit = interest.lane == .userInitiated ? self.tuning.interactiveRetry.interactiveMaxWait : .infinity
                error = wait > limit ? .serverUnavailable(retryAfter: wait) : nil
            case .insufficientSpace:
                if case .insufficientSpace? = job.lastError {
                    error = job.lastError
                } else {
                    error = .insufficientSpace(required: job.entry.byteSize ?? 0, available: self.state.freeSpace.map { self.headroom(for: job, in: $0) } ?? 0)
                }
            case .policy, .awaitingSpace:
                error = nil
            }
            if let error {
                self.resolve(token, of: transfer, with: .failed(error))
            }
        }
    }

    /// The end of the throttle a job parked with `until` waits for. A parked job keeps the end it was parked with, while
    /// a later 429 extends the origin's throttle and moves only the origin's `.throttle` deadline, which alone re-admits
    /// the job (F-35): the origin's end when it is later, else `until`. Every reader of a parked job's end, the fail-fast
    /// answer, a run's blocked outcome (in the run task's answering turn, close-out cycle 19) and whether the block
    /// cleared, reads it here, so each tells the caller the end a fresh request would get (close-out cycle 16, F-36).
    func throttleEnd(after until: MonotonicInstant) -> MonotonicInstant {
        guard let origin = self.state.remote?.originID, let end = self.state.throttles[origin] else {
            return until
        }
        return max(end, until)
    }

    /// The answer to a request the origin's throttle refuses, which a refusal ending at `until` produced: the time left
    /// until the origin's end, read now. A manifest outcome carries the end its fetch's turn read, and its waiters answer
    /// after awaits in which a transfer's 429 may extend the throttle (close-out cycle 18, F-38).
    func throttledError(after until: MonotonicInstant) -> AssetError {
        .serverUnavailable(retryAfter: self.throttleEnd(after: until).seconds(since: self.environment.time.monotonicNow()))
    }

    /// `reason` with a throttle's end read through `throttleEnd(after:)`.
    func currentReason(_ reason: BlockReason) -> BlockReason {
        if case .throttled(let until) = reason {
            return .throttled(until: self.throttleEnd(after: until))
        }
        return reason
    }

    /// Whether a blocked reason no longer applies to `job` at `lane`: lack of space is re-checked against the latest
    /// free-space read (T17); `awaitingSpace` waits for the reaper.
    func blockCleared(_ reason: BlockReason, lane: AssetPriority, job: Job) -> Bool {
        switch reason {
        case .offline, .policy:
            return self.laneVerdict(lane) == .admit
        case .throttled, .circuitOpen:
            // The origin's gates as the next dispatch reads them (F-40).
            return self.originGateNow().admits(reason) ?? true
        case .insufficientSpace:
            // `job` already holds the interest that changed its lane, so the ledger reads the lane's volume.
            return self.spaceBlock(job) == nil
        case .awaitingSpace:
            return false
        }
    }

    /// Re-queues the jobs parked `insufficientSpace` that the latest free-space read admits (T17; `sweepSpaceParked`).
    func reconsiderSpaceBlocked() {
        self.sweepSpaceParked(.read)
    }

    /// Re-checks the jobs parked for lack of space against the latest free-space read (T17), in the order the pump serves
    /// them (user singles, user batches, prefetch, bulk; by queue ticket within a lane). Each is admitted against the room
    /// the read leaves after the jobs re-admitted ahead of it, which the gate counts in flight once they start: those of
    /// this sweep and those earlier sweeps re-queued that still wait in the queue (`spaceAdmitted`). Re-queuing every job
    /// that fits on its own only for the gate to park all but the first again took 16 ms in one turn at 10,000 parked
    /// members (review of close-out cycle 7, C2), and the jobs it re-queued while every slot was taken waited in the queue
    /// for room the earlier ones had used. An admitted job is re-queued; an `insufficientSpace` one that is not stays
    /// parked until a later read; an `awaitingSpace` one that is not is treated as `sweep` says. Its figures, when it is
    /// parked `insufficientSpace`, are the bytes it needs against that room (F-22's convention). At most `parksPerPump`
    /// jobs are parked and at most `readmissionsPerTurn` re-queued per turn; the rest are left to a follow-up sweep (one
    /// turn that re-admitted 10,000 members when the volume gained room took about 15 ms: review of close-out cycle 8,
    /// C2). A read stops re-checking once the room left cannot admit even the smallest job parked `insufficientSpace`.
    func sweepSpaceParked(_ sweep: SpaceSweep) {
        var ahead = self.spaceAdmittedAhead()
        var candidates: [(rank: Int, ticket: UInt64, transfer: TransferID)] = []
        var smallest = Int64.max
        for transfer in self.state.spaceParked {
            guard let job = self.state.jobs[transfer], case .blocked(let reason) = job.state, sweep != .read || reason == .insufficientSpace else {
                continue
            }
            smallest = min(smallest, self.spaceSize(of: job))
            candidates.append((self.queueRank(job), job.ticket, transfer))
        }
        // A read re-checks only jobs parked `insufficientSpace`, and leaves untouched each it does not admit: once the
        // room left cannot hold the smallest of them, nothing more changes.
        let room = sweep == .read ? self.state.freeSpace.map { self.largestRoom(in: $0) } : nil
        if let room, smallest > room.subtractingClamped(ahead) {
            return
        }
        candidates.sort { ($0.rank, $0.ticket) < ($1.rank, $1.ticket) }
        var requeues = 0
        var parks = 0
        var waiting = false
        for candidate in candidates {
            if let room, smallest > room.subtractingClamped(ahead) {
                break
            }
            let transfer = candidate.transfer
            guard let job = self.state.jobs[transfer], case .blocked(let reason) = job.state else {
                continue
            }
            guard let verdict = self.spaceBlock(job, ahead: ahead) else {
                guard requeues < Self.readmissionsPerTurn else {
                    self.scheduleSpaceSweepFollowUp(sweep)
                    break
                }
                if self.transition(transfer, to: .queued) {
                    self.enqueue(transfer)
                    ahead = PlanBuilder.adding(ahead, max(0, job.entry.byteSize ?? 0))
                    self.state.spaceAdmitted[transfer] = self.state.jobs[transfer]?.ticket
                    requeues += 1
                }
                continue
            }
            guard reason == .awaitingSpace else {
                continue
            }
            if verdict == .awaitingSpace, sweep == .reclaimed || self.spaceWakeExpected {
                waiting = true
                continue
            }
            guard parks < Self.parksPerPump else {
                self.scheduleSpaceSweepFollowUp(sweep)
                break
            }
            if let space = self.state.freeSpace {
                // The room is computed before the write: the right side of an optional-chained assignment runs inside
                // the write's access to `state` (an exclusivity conflict, review of close-out cycle 6).
                let available = max(0, self.headroom(for: job, in: space).subtractingClamped(ahead))
                if case .insufficientSpace(let required, _)? = job.lastError {
                    // An earlier ENOSPC's figures: the bytes it needed, against the room this read leaves the job.
                    self.state.jobs[transfer]?.lastError = .insufficientSpace(required: required, available: available)
                } else if ahead > 0 {
                    // The fail-fast answer would report the room without the jobs admitted ahead of this one.
                    self.state.jobs[transfer]?.lastError = .insufficientSpace(required: job.entry.byteSize ?? 0, available: available)
                }
            }
            self.park(transfer, reason: .insufficientSpace)
            parks += 1
        }
        if waiting {
            // Re-parking would have asked for a wake (`park`); the jobs left waiting ask for it here.
            self.ensureSpaceWake()
        }
        if parks > 0 {
            self.checkRunSettled()
        }
        if requeues > 0 {
            self.pump()
        }
    }

    /// The bytes of the jobs earlier sweeps re-queued that still wait in the queue with the ticket a sweep gave them;
    /// the others (started, parked again, re-queued by another path, removed) leave `spaceAdmitted`.
    private func spaceAdmittedAhead() -> Int64 {
        guard !self.state.spaceAdmitted.isEmpty else {
            return 0
        }
        var ahead: Int64 = 0
        var kept: [TransferID: UInt64] = [:]
        for (transfer, ticket) in self.state.spaceAdmitted {
            guard let job = self.state.jobs[transfer], job.state == .queued, job.ticket == ticket else {
                continue
            }
            kept[transfer] = ticket
            ahead = PlanBuilder.adding(ahead, max(0, job.entry.byteSize ?? 0))
        }
        self.state.spaceAdmitted = kept
        return ahead
    }

    /// The bytes the headroom ledger needs free for `job` (`spaceBlock`): its entry's size, or the larger figure an
    /// earlier ENOSPC reported.
    private func spaceSize(of job: Job) -> Int64 {
        var size = job.entry.byteSize ?? 0
        if case .insufficientSpace(let required, _)? = job.lastError {
            size = max(size, required)
        }
        return size
    }

    /// The largest room the ledger gives a job that is not in flight on either volume (`headroom(for:in:)` for the
    /// larger volume): a job that needs more fits on neither.
    private func largestRoom(in space: FreeSpace) -> Int64 {
        let volume = max(space.volumeImportant, space.volumeOpportunistic)
        return max(0, volume.subtractingClamped(max(0, space.reserveBytes)).subtractingClamped(self.state.inFlightBytes.clamped).subtractingClamped(self.state.committedSinceRead))
    }

    /// The order the pump serves a job's queue in.
    func queueRank(_ job: Job) -> Int {
        switch self.queueKind(job) {
        case .userSingle:
            return 0
        case .userBatch:
            return 1
        case .prefetch:
            return 2
        case .bulk:
            return 3
        }
    }

    /// Schedules one later sweep for the jobs a sweep left after `parksPerPump` parks (C2).
    private func scheduleSpaceSweepFollowUp(_ sweep: SpaceSweep) {
        let owed = self.state.spaceSweepFollowUp
        self.state.spaceSweepFollowUp = sweep.merged(with: owed)
        guard owed == nil else {
            return
        }
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the sweep re-reads every parked job.
            await engine.spaceSweepFollowUp()
        }
        if spawned == nil {
            self.state.spaceSweepFollowUp = nil
        }
    }

    /// Test seam: the next space sweep follow-ups keep their sweep owed until `releaseSpaceSweepFollowUps()`.
    func holdSpaceSweepFollowUps() {
        self.state.spaceSweepFollowUpsHeld = true
    }

    /// Test seam: lets a held follow-up sweep run in this turn, or disarms a hold nothing reached.
    func releaseSpaceSweepFollowUps() {
        self.state.spaceSweepFollowUpsHeld = false
        guard self.state.spaceSweepFollowUpWaiting else {
            return
        }
        self.state.spaceSweepFollowUpWaiting = false
        self.spaceSweepFollowUp()
    }

    /// The scheduled follow-up sweep, then the run's settling check: while the sweep was owed, a run's claim parked
    /// `insufficientSpace` counted as working (`checkRunSettled`), and a sweep that neither parks nor re-queues checks
    /// nothing itself (close-out cycle 17, F-37).
    private func spaceSweepFollowUp() {
        if self.state.spaceSweepFollowUpsHeld {
            // Test seam: the sweep stays owed (`spaceSweepFollowUp`) until the release runs it; a sweep owed meanwhile
            // merges into it without a second task (`scheduleSpaceSweepFollowUp`).
            self.state.spaceSweepFollowUpWaiting = true
            self.notifyObservers()
            return
        }
        guard let sweep = self.state.spaceSweepFollowUp else {
            return
        }
        self.state.spaceSweepFollowUp = nil
        guard self.isRunning else {
            return
        }
        self.sweepSpaceParked(sweep)
        self.checkRunSettled()
    }

    // MARK: Diagnostics

    /// Appends to the ring of recent errors (R-OBS-3): values only, never a URL, header or key (R-SEC-1).
    func record(_ id: AssetID?, _ failureClass: FailureClass, _ detail: String) {
        self.state.recentErrors.append(DiagnosticError(at: self.environment.time.now(), id: id, failureClass: failureClass, detail: detail))
        let overflow = self.state.recentErrors.count - EngineDiagnostics.recentErrorCapacity
        if overflow > 0 {
            self.state.recentErrors.removeFirst(overflow)
        }
        // The line carries the class and the hashed identifier only: error descriptions can name identifiers, so the
        // detail stays in the diagnostics ring (R-OBS-1, R-SEC-1).
        let label = String(describing: failureClass)
        let hashedID = id.map(AssetLog.hashed) ?? "-"
        self.log.log(.sync, .error, "failure \(label) \(hashedID)")
    }

    /// Takes the manifest the store applied as the engine's copy. The newest manifest seen stays the newest one fetched
    /// (sequence > 0) once there is one: an applied manifest never comes from a later fetch (a point admission, an
    /// `ensureAvailable` apply or a store re-read lands while a run holds a fetched, unapplied manifest), so replacing it
    /// would drop ids only that fetch lists from the S1-13 checks.
    func adoptApplied(_ manifest: ValidatedManifest, etag: ETag?) {
        self.state.copySerial &+= 1
        self.state.applied = manifest
        self.state.appliedETag = etag
        if (self.state.newest?.sequence ?? 0) == 0 {
            self.state.newest = (manifest, 0)
        }
        // Members registered while the copy did not list them are claimed once it does (L5-R1).
        self.claimNewlyListed()
    }
}
