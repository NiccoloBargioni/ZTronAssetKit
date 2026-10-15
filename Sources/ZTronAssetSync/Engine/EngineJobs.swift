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
        job.state = next
        if next.kind != .downloading {
            // Only a downloading job has a running attempt (the invariant the model test checks).
            job.active = nil
        }
        self.state.jobs[transfer] = job
        return true
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
        guard let origin = self.state.remote?.originID else {
            return false
        }
        if let until = self.state.throttles[origin], until > self.environment.time.monotonicNow() {
            return false
        }
        if case .open? = self.state.breakers[origin]?.state {
            return false
        }
        return true
    }

    /// Removes interest `token` from `transfer` (all its assets) and retires the job when nobody is left.
    func removeInterest(_ token: InterestToken, from transfer: TransferID) {
        guard var job = self.state.jobs[transfer], job.interests[token] != nil else {
            return
        }
        let before = job.lane
        job.interests[token] = nil
        self.state.jobs[transfer] = job
        if job.interests.isEmpty {
            self.retire(transfer)
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
        if let adopt = job.adopt {
            // A drained copy nobody will publish now.
            self.discardLater(adopt.name)
        }
        self.state.heap.remove(.retry(transfer, epoch: job.epoch))
        for asset in job.assets {
            self.retireProgress(.transfer(asset))
        }
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
        self.state.queues.push(entry, to: kind, front: front)
        if self.state.queues.storedCount > 2 * self.state.jobs.count + 16 {
            // Stale entries outnumber the jobs (sync.md §7.2): keep the queues within twice the live entries.
            var queues = self.state.queues
            self.state.queues = LaneQueues()
            queues.compact { self.isValid($0) }
            self.state.queues = queues
        }
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
                let wait = until.seconds(since: now)
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

    /// Whether a blocked reason no longer applies to `job` at `lane`: lack of space is re-checked against the latest
    /// free-space read (T17); `awaitingSpace` waits for the reaper.
    func blockCleared(_ reason: BlockReason, lane: AssetPriority, job: Job) -> Bool {
        switch reason {
        case .offline, .policy:
            return self.laneVerdict(lane) == .admit
        case .throttled(let until):
            return until <= self.environment.time.monotonicNow()
        case .circuitOpen:
            guard let origin = self.state.remote?.originID, let breaker = self.state.breakers[origin] else {
                return true
            }
            if case .open(_, let until, _) = breaker.state {
                return until <= self.environment.time.monotonicNow()
            }
            return true
        case .insufficientSpace:
            // `job` already holds the interest that changed its lane, so the ledger reads the lane's volume.
            return self.spaceBlock(job) == nil
        case .awaitingSpace:
            return false
        }
    }

    /// Re-queues every job parked for lack of space whose headroom the latest free-space read admits (T17).
    func reconsiderSpaceBlocked() {
        var cleared = false
        for transfer in self.state.jobs.keys.sorted() {
            guard let job = self.state.jobs[transfer], job.state == .blocked(.insufficientSpace), self.spaceBlock(job) == nil else {
                continue
            }
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
                cleared = true
            }
        }
        if cleared {
            self.pump()
        }
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
    }
}
