import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// The outcome of the gates for one queued job.
enum DispatchGate: Equatable {
    /// Start it.
    case start(probe: Bool)
    /// Park it with this reason.
    case block(BlockReason)
    /// Leave it queued (conditions unknown; a cancelled attempt of the same transfer still drains).
    case wait
}

extension SyncEngine {
    // MARK: Slots (sync.md §7.3)

    /// Transfers counted as running: downloading and not paused for preemption.
    var runningCount: Int {
        self.state.jobs.values.reduce(0) { count, job in
            job.state == .downloading && job.active?.preempting != true ? count + 1 : count
        }
    }

    /// Running user-initiated transfers.
    private var runningUser: Int {
        self.state.jobs.values.reduce(0) { count, job in
            job.state == .downloading && job.active?.preempting != true && job.lane == .userInitiated ? count + 1 : count
        }
    }

    /// Jobs of non-user lanes in downloading ∪ verifying ∪ committing (the pipeline cap gates only those, S2-10).
    private var nonUserPipeline: Int {
        self.state.jobs.values.reduce(0) { count, job in
            guard job.lane < .userInitiated else {
                return count
            }
            switch job.state {
            case .downloading, .verifying, .committing:
                return count + 1
            default:
                return count
            }
        }
    }

    /// The slots user-initiated work may take: every slot, or `interactiveConcurrencyAtCritical` at `.critical`.
    private var userCap: Int {
        if self.state.conditions?.power.thermal == .critical {
            return max(1, self.configuration.power.interactiveConcurrencyAtCritical)
        }
        return self.tuning.maxConcurrentTransfers
    }

    // MARK: Pump (synchronous, no await)

    /// Dispatches queued work into free slots: user singles, then user batches, then (when no user job waits)
    /// prefetch and bulk in aging order; preempts a lower-lane transfer for a waiting user job (T16) and loops after
    /// marking it (sync-1 S1-16). Materialises run fetches first (S1-15).
    func pump() {
        guard self.isRunning, self.state.remote != nil else {
            return
        }
        self.materializeRun()
        self.materializeEnsures()
        let maximum = self.tuning.maxConcurrentTransfers
        var guardCount = 0
        while guardCount < 10_000 {
            guardCount += 1
            var started = false
            for kind in [LaneQueues.Kind.userSingle, .userBatch] {
                while maximum - self.runningCount > 0, self.runningUser < self.userCap {
                    guard let transfer = self.popDispatchable(kind) else {
                        break
                    }
                    started = self.dispatch(transfer) || started
                }
            }
            if self.hasQueuedUser {
                if self.preemptForUser() {
                    continue
                }
                break
            }
            let nonUserCap = maximum - min(max(self.tuning.reservedInteractiveSlots, 0), maximum - 1)
            let pipelineCap = self.tuning.pipelineDepth * maximum
            while maximum - self.runningCount > 0, self.runningCount - self.runningUser < nonUserCap, self.nonUserPipeline < pipelineCap {
                guard let transfer = self.nextNonUser() else {
                    break
                }
                started = self.dispatch(transfer) || started
                self.materializeRun()
            }
            if !started {
                break
            }
        }
        self.checkRunSettled()
        self.scheduleEnsureRefill()
        self.notifyObservers()
    }

    // MARK: ensureAvailable materialisation (S1-15, C2)

    /// The members a group materialises at most at a time (the run's bound: the pipeline plus `runLookahead`).
    private var materializationLimit: Int {
        max(1, self.tuning.pipelineDepth * self.tuning.maxConcurrentTransfers + self.tuning.runLookahead)
    }

    /// Turns `ensureAvailable` groups' planned fetches into members and jobs while fewer than the limit are pending. A
    /// fetch follows its asset's current entry (T22) and is dropped when the asset left the manifest (T21).
    func materializeEnsures() {
        let limit = self.materializationLimit
        for token in self.state.groups.keys.sorted() {
            guard var group = self.state.groups[token], group.kind == .ensure, group.cursor < group.fetches.count, group.pending.count < limit else {
                continue
            }
            var added: [(id: AssetID, entry: ManifestEntry)] = []
            while group.cursor < group.fetches.count, group.pending.count < limit {
                let id = group.fetches[group.cursor].id
                group.cursor += 1
                guard let entry = self.state.applied.entry(for: id) else {
                    continue
                }
                group.pending[id] = entry.transferID
                added.append((id, entry))
            }
            if group.cursor >= group.fetches.count {
                group.fetches = []
                group.cursor = 0
            }
            // Every remaining fetch may have left the manifest: then nothing is left to wait for.
            let completion = group.isSettled ? group.continuation : nil
            if completion != nil {
                group.continuation = nil
            }
            self.state.groups[token] = group
            for member in added {
                self.addInterest(token, asset: member.id, entry: member.entry, lane: .userInitiated, kind: .ensure)
            }
            completion?.resume(returning: true)
        }
    }

    /// Schedules one later `pump()` when an `ensureAvailable` group has fetches left and room for them (members that
    /// failed fast inside this pump freed it): each batch is materialised in its own actor turn, never in a loop here.
    private func scheduleEnsureRefill() {
        guard !self.state.ensureRefillScheduled else {
            return
        }
        let limit = self.materializationLimit
        guard self.state.groups.values.contains(where: { $0.kind == .ensure && $0.cursor < $0.fetches.count && $0.pending.count < limit }) else {
            return
        }
        self.state.ensureRefillScheduled = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; `pump` re-reads every group.
            await engine.refillEnsures()
        }
        if spawned == nil {
            self.state.ensureRefillScheduled = false
        }
    }

    /// The scheduled refill.
    private func refillEnsures() {
        self.state.ensureRefillScheduled = false
        self.pump()
    }

    /// Whether a valid user-initiated entry waits.
    private var hasQueuedUser: Bool {
        for kind in [LaneQueues.Kind.userSingle, .userBatch] {
            let ready: (LaneQueues.Entry) -> Bool = { entry in
                self.isValid(entry) && self.state.draining[entry.transfer] == nil && !self.state.heldForManifest.contains(entry.transfer)
            }
            if self.state.queues.first(kind, isValid: ready) != nil {
                return true
            }
        }
        return false
    }

    /// The next prefetch or bulk job: bulk first once its head waited `bulkAging` (sync.md §7.4).
    private func nextNonUser() -> TransferID? {
        let now = self.environment.time.monotonicNow()
        let agedBulk = self.state.queues.first(.bulk, isValid: { self.isValid($0) }).map { $0.queuedAt.adding(seconds: self.tuning.bulkAging) <= now } ?? false
        let order: [LaneQueues.Kind] = agedBulk ? [.bulk, .prefetch] : [.prefetch, .bulk]
        for kind in order {
            if let transfer = self.popDispatchable(kind) {
                return transfer
            }
        }
        return nil
    }

    /// Pops the first valid entry of `kind` whose gates do not say "wait"; a lane whose gate waits is left as is.
    private func popDispatchable(_ kind: LaneQueues.Kind) -> TransferID? {
        // The queues are taken out of the state while the closures read it (no overlapping access).
        var queues = self.state.queues
        self.state.queues = LaneQueues()
        let entry = queues.pop(kind, isValid: { self.isValid($0) }) { candidate in
            self.state.draining[candidate.transfer] == nil && self.gate(candidate.transfer) != .wait
        }
        self.state.queues = queues
        return entry?.transfer
    }

    /// Starts `transfer` or parks it; `true` when a transfer started.
    private func dispatch(_ transfer: TransferID) -> Bool {
        switch self.gate(transfer) {
        case .wait:
            self.enqueue(transfer, front: true)
            return false
        case .block(let reason):
            self.park(transfer, reason: reason)
            if case .policy = reason {
                self.parkLane(of: transfer, reason: reason)
            } else if case .offline = reason {
                self.parkLane(of: transfer, reason: reason)
            }
            return false
        case .start(let probe):
            self.start(transfer, probe: probe)
            return true
        }
    }

    /// Parks every other queued job of the same lane with the same lane-wide reason (so a run can settle blocked).
    private func parkLane(of transfer: TransferID, reason: BlockReason) {
        guard let lane = self.state.jobs[transfer]?.lane else {
            return
        }
        for other in self.state.jobs.keys.sorted() where other != transfer {
            guard let job = self.state.jobs[other], job.state == .queued, job.lane == lane, self.gate(other) == .block(reason) else {
                continue
            }
            self.park(other, reason: reason)
        }
    }

    /// Moves a job to `blocked(reason)` and applies the fail-fast policy (T4).
    func park(_ transfer: TransferID, reason: BlockReason) {
        guard self.transition(transfer, to: .blocked(reason)) else {
            return
        }
        if case .throttled(let until) = reason, let origin = self.state.remote?.originID {
            self.state.heap.schedule(.throttle(origin), at: until)
            self.rearm()
        }
        if case .circuitOpen = reason {
            self.scheduleBreakerDeadline()
        }
        self.failFast(transfer, reason: reason)
        self.notifyObservers()
    }

    /// The gates of one queued job: lane admission, the Apple-tier access gate (E-17), the origin throttle, the
    /// breaker and the headroom ledger (sync.md §7.3, §12.1).
    func gate(_ transfer: TransferID) -> DispatchGate {
        guard let job = self.state.jobs[transfer], let remote = self.state.remote, !self.state.heldForManifest.contains(transfer) else {
            return .wait
        }
        let lane = job.lane
        if self.state.conditions == nil, lane != .userInitiated || remote.capabilities.tier == .appleHosted {
            return .wait
        }
        if case .block(let reason) = self.laneVerdict(lane) {
            return .block(reason)
        }
        if remote.capabilities.tier == .appleHosted, let reason = self.appleAccessBlock(self.access(for: lane)) {
            return .block(reason)
        }
        let now = self.environment.time.monotonicNow()
        if let until = self.state.throttles[remote.originID], until > now {
            return .block(.throttled(until: until))
        }
        if let breaker = self.state.breakers[remote.originID] {
            var probe = breaker
            switch probe.admit(transfer, at: now) {
            case .allow:
                break
            case .probe:
                // The admission is applied by `start`; here only the verdict counts.
                if job.adopt == nil, let reason = self.spaceBlock(job) {
                    return .block(reason)
                }
                return .start(probe: true)
            case .reject(let cause, _):
                return .block(.circuitOpen(cause))
            }
        }
        if job.adopt == nil, let reason = self.spaceBlock(job) {
            return .block(reason)
        }
        return .start(probe: false)
    }

    /// The lane verdict under the current conditions and policies.
    func laneVerdict(_ lane: AssetPriority) -> LaneAdmission.Verdict {
        LaneAdmission.evaluate(
            lane: lane,
            conditions: self.state.conditions,
            network: self.configuration.network,
            power: self.configuration.power,
            pausedForThermal: self.state.pausedForThermal
        )
    }

    /// The OS-enforced permissions of a lane (R-SYN-7, R-NET-9).
    func access(for lane: AssetPriority) -> NetworkAccess {
        let network = self.configuration.network
        switch lane {
        case .userInitiated where network.userInitiatedOverridesPolicy:
            return .unrestricted
        case .userInitiated, .prefetch:
            return NetworkAccess(allowsCellular: network.prefetchOnExpensive, allowsExpensive: network.prefetchOnExpensive, allowsConstrained: network.prefetchOnConstrained)
        case .bulk:
            return NetworkAccess(allowsCellular: network.bulkOnExpensive, allowsExpensive: network.bulkOnExpensive, allowsConstrained: network.bulkOnConstrained)
        }
    }

    /// The Apple tier cannot honour `NetworkAccess` (E-17): the engine starts its transfers and update checks only when
    /// its own conditions satisfy them; `nil` when they do.
    func appleAccessBlock(_ access: NetworkAccess) -> BlockReason? {
        guard let conditions = self.state.conditions, conditions.network.satisfied else {
            return .offline
        }
        if conditions.network.expensive, !access.allowsExpensive || !access.allowsCellular {
            return .policy(.expensiveNetwork)
        }
        if conditions.network.constrained, !access.allowsConstrained {
            return .policy(.constrainedNetwork)
        }
        return nil
    }

    /// The headroom ledger (S2-09, S2-29): a fetch of known size starts only if the volume minus the reserve, the
    /// bytes in flight and the bytes committed since the last read still holds it; unknown sizes always fit. The size is
    /// the entry's, or the larger figure an earlier ENOSPC reported (the transport's `required`), so a job parked for
    /// lack of space is re-admitted only when that much is free (T17).
    func spaceBlock(_ job: Job) -> BlockReason? {
        var size = job.entry.byteSize ?? 0
        if case .insufficientSpace(let required, _)? = job.lastError {
            size = max(size, required)
        }
        guard size > 0, let space = self.state.freeSpace else {
            return nil
        }
        let volume = job.lane == .userInitiated ? space.volumeImportant : space.volumeOpportunistic
        var inFlight: Int64 = 0
        for other in self.state.jobs.values where other.transfer != job.transfer {
            switch other.state {
            case .downloading, .verifying, .committing:
                inFlight = PlanBuilder.adding(inFlight, max(0, other.entry.byteSize ?? 0))
            default:
                continue
            }
        }
        let headroom = volume.subtractingClamped(max(0, space.reserveBytes)).subtractingClamped(inFlight).subtractingClamped(self.state.committedSinceRead)
        guard size > headroom else {
            return nil
        }
        return space.pendingReclaim > 0 ? .awaitingSpace : .insufficientSpace
    }

    // MARK: Preemption (T16, H-4)

    /// Pauses the lowest-lane, least-advanced, newest running transfer for a waiting user job (never the breaker's
    /// probe); `true` when a victim was marked (its slot is free at once).
    private func preemptForUser() -> Bool {
        guard self.tuning.preemptLowerLanes, self.tuning.maxConcurrentTransfers - self.runningCount <= 0 else {
            return false
        }
        let victims = self.state.jobs.values.filter { job in
            guard job.state == .downloading, job.lane < .userInitiated, let active = job.active else {
                return false
            }
            return !active.preempting && !active.probe
        }
        guard let victim = victims.min(by: { lhs, rhs in
            let left = (lhs.lane.rawValue, lhs.active?.bytesReceived ?? 0, UInt64.max - (lhs.active?.startSequence ?? 0))
            let right = (rhs.lane.rawValue, rhs.active?.bytesReceived ?? 0, UInt64.max - (rhs.active?.startSequence ?? 0))
            return left < right
        }) else {
            return false
        }
        self.state.jobs[victim.transfer]?.active?.preempting = true
        self.state.metrics.preemptions += 1
        self.stop(victim.transfer, .pause)
        return true
    }

    /// Pauses a running transfer whose (demoted) lane the policy now refuses (sync-1 S1-07, §11.3).
    func pauseIfRefused(_ transfer: TransferID) {
        guard let job = self.state.jobs[transfer], job.state == .downloading, job.lane < .userInitiated, let active = job.active, !active.preempting else {
            return
        }
        guard case .block(.policy(let block)) = self.laneVerdict(job.lane) else {
            return
        }
        self.state.jobs[transfer]?.active?.policyPause = block
        self.stop(transfer, .pause)
    }

    /// Applies a control to a running attempt now, or when its handle arrives.
    func stop(_ transfer: TransferID, _ control: PendingStop) {
        guard let active = self.state.jobs[transfer]?.active else {
            return
        }
        if let handle = active.handle {
            switch control {
            case .pause:
                handle.pause()
            case .cancel:
                handle.cancel()
            }
        } else {
            self.state.jobs[transfer]?.active?.pendingStop = control
        }
    }

    /// Changes a running attempt's priority now (synchronously, before any later start, sync-1 S1-06), or when its
    /// handle arrives.
    func setPriority(_ transfer: TransferID, _ lane: AssetPriority) {
        guard let active = self.state.jobs[transfer]?.active else {
            return
        }
        if let handle = active.handle {
            handle.setPriority(lane)
        } else {
            self.state.jobs[transfer]?.active?.pendingPriority = lane
        }
    }

    // MARK: Start (T3)

    /// Starts an attempt: `queued → downloading`, the request built from the job, the driver spawned.
    private func start(_ transfer: TransferID, probe: Bool) {
        guard var job = self.state.jobs[transfer], let remote = self.state.remote else {
            return
        }
        if probe, var breaker = self.state.breakers[remote.originID] {
            let before = breaker.publicState
            _ = breaker.admit(transfer, at: self.environment.time.monotonicNow())
            self.state.breakers[remote.originID] = breaker
            // Publishes `circuitChanged(.halfOpen)` when this probe opened the half-open state, and schedules its
            // watchdog.
            self.breakerChanged(remote.originID, from: before)
            self.scheduleBreakerDeadline()
        }
        guard self.transition(transfer, to: .downloading) else {
            return
        }
        job = self.state.jobs[transfer] ?? job
        self.state.lastEpoch += 1
        job.epoch = self.state.lastEpoch
        let attempt = self.nextAttempt()
        let lane = job.lane
        let checksummed = job.entry.checksum != nil
        let request = TransferRequest(
            id: transfer,
            attempt: attempt,
            purpose: .asset,
            remotePath: job.entry.remotePath,
            expectedBytes: job.entry.byteSize,
            maxBytes: self.configuration.limits.maxAssetBytes,
            priority: lane,
            access: self.access(for: lane),
            route: lane == .bulk && remote.capabilities.supportsBackground && !self.state.backgroundDisabled ? .backgroundEligible : .foreground,
            resume: checksummed && remote.capabilities.supportsResume ? job.resume : nil
        )
        let epoch = job.epoch
        let adopt = job.adopt
        job.adopt = nil
        self.state.lastStart += 1
        guard let driver = self.spawn(.driver(lane), { engine in
            if let adopt {
                // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
                await engine.publishDrained(transfer, epoch: epoch, file: adopt)
            } else {
                // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
                await engine.drive(transfer, epoch: epoch, request: request)
            }
        }) else {
            return
        }
        job.active = ActiveAttempt(attempt: attempt, request: request, driver: driver, startSequence: self.state.lastStart, probe: probe)
        // A publication of a file an earlier attempt staged has no stream: nothing is left to drain if its job is
        // retired before its driver runs (`publish` then discards the file).
        job.active?.terminalReceived = adopt != nil
        self.state.jobs[transfer] = job
        if adopt == nil {
            self.state.metrics.transferRequests += 1
            if job.interests.values.contains(where: { $0.kind == .waiter }) {
                self.state.metrics.resolveTransfers += 1
            }
        }
        self.notifyObservers()
    }

    // MARK: Driver (RE-S12, RE-S13)

    /// Test seam: suspends until the running attempt of `transfer` holds its handle, so a test can order a control
    /// after the start without racing the driver's hop (returns at once when no attempt runs); ends on the caller's
    /// cancellation.
    func waitForHandle(_ transfer: TransferID) async {
        // REENTRANCY: f-8 (proposed) — nothing: a terminal test wait.
        await self.awaitCondition { engine in
            engine.state.jobs[transfer]?.state != .downloading || engine.state.jobs[transfer]?.active?.handle != nil
        }
    }

    /// Test seam: suspends until `transfer` has no job any more; ends on the caller's cancellation.
    func waitForJobEnd(_ transfer: TransferID) async {
        // REENTRANCY: f-8 (proposed) — nothing: a terminal test wait.
        await self.awaitCondition { engine in
            engine.state.jobs[transfer] == nil
        }
    }

    /// Test seam: suspends until every running attempt holds its handle; ends on the caller's cancellation.
    func waitForAllHandles() async {
        // REENTRANCY: f-8 (proposed) — nothing: a terminal test wait.
        await self.awaitCondition { engine in
            engine.state.jobs.values.allSatisfy { $0.state != .downloading || $0.active?.handle != nil }
        }
    }

    /// One attempt: start the transfer, consume its updates, apply the terminal element.
    func drive(_ transfer: TransferID, epoch: UInt64, request: TransferRequest) async {
        guard let remote = self.state.remote else {
            return
        }
        // REENTRANCY: RE-S12 — the lifecycle and the job epoch: an attempt nobody wants any more is cancelled at
        // once (its stream is still drained, so a completion racing the cancel is not lost, ARCHITECTURE §7.6).
        let handle = await remote.transfer(request)
        let current = self.isRunning && self.state.jobs[transfer]?.epoch == epoch && self.state.jobs[transfer]?.active?.attempt == request.attempt
        if current {
            self.state.jobs[transfer]?.active?.handle = handle
            self.notifyObservers()
            if let pending = self.state.jobs[transfer]?.active?.pendingPriority, pending != request.priority {
                handle.setPriority(pending)
            }
            switch self.state.jobs[transfer]?.active?.pendingStop {
            case .pause?:
                handle.pause()
            case .cancel?:
                handle.cancel()
            case nil:
                if let lane = self.state.jobs[transfer]?.lane, lane != request.priority, self.state.jobs[transfer]?.active?.pendingPriority == nil {
                    handle.setPriority(lane)
                }
            }
        } else {
            handle.cancel()
            if !self.isRunning {
                return
            }
        }
        var terminal: TransferUpdate?
        // REENTRANCY: RE-S13 — the job epoch per element; progress updates counters, a terminal element is applied
        // below after the loop.
        for await update in handle.updates {
            if case .progress(let received, let expected) = update {
                self.onProgress(transfer, epoch: epoch, received: received, expected: expected)
                continue
            }
            terminal = update
            break
        }
        guard !Task.isCancelled, self.isRunning else {
            return
        }
        // A stream that ends without a terminal element fails the job (sync-1 S1-11).
        let update = terminal ?? .failed(.transient(.incompleteCallbackSequence, retryAfter: nil))
        // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
        await self.finishAttempt(transfer, epoch: epoch, request: request, update: update)
    }

    /// Records transfer progress: counters, run bytes, and a rate-limited `transferProgress` for non-bulk lanes.
    private func onProgress(_ transfer: TransferID, epoch: UInt64, received: Int64, expected: Int64?) {
        guard var job = self.state.jobs[transfer], job.epoch == epoch, var active = job.active else {
            return
        }
        active.bytesReceived = received
        job.active = active
        self.state.jobs[transfer] = job
        if job.lane > .bulk, let asset = job.assets.min() {
            self.offerProgress(.transferProgress(asset, TransferProgress(received: received, expected: expected)))
        }
        self.offerRunProgress()
    }

    /// Applies an attempt's terminal element (T5, T6, T7).
    func finishAttempt(_ transfer: TransferID, epoch: UInt64, request: TransferRequest, update: TransferUpdate) async {
        if self.state.draining[transfer]?.attempt == request.attempt {
            self.state.draining[transfer] = nil
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.drained(transfer, request: request, update: update)
            return
        }
        guard let job = self.state.jobs[transfer], job.epoch == epoch, job.active?.attempt == request.attempt else {
            if case .staged(let file) = update {
                // REENTRANCY: f-3 (proposed) — nothing: the copy belongs to an attempt nobody wants any more.
                await self.state.staging?.discard(file.name)
            }
            return
        }
        // The stream is over: from here on, retiring the job (during an await below) leaves nothing to drain.
        self.state.jobs[transfer]?.active?.terminalReceived = true
        defer {
            if let previous = request.resume?.previous {
                // A resumed attempt took the earlier partial over by an exclusive rename; the earlier attempt's sidecar
                // is garbage whatever the outcome (the next resume point is read from this attempt's own names).
                self.discardLater(previous)
            }
        }
        switch update {
        case .staged(let file):
            let downloaded = PlanBuilder.adding(self.state.metrics.bytesDownloaded, file.byteCount)
            self.state.metrics.bytesDownloaded = downloaded
            self.noteRunBytes(transfer, file.byteCount)
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.publish(transfer, epoch: epoch, file: file, cancelledAttempt: false)
        case .paused:
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.paused(transfer, epoch: epoch, request: request)
        case .failed(let error):
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.failed(transfer, epoch: epoch, request: request, error: error)
        case .progress:
            return
        }
    }

    /// Removes a staging file and its sidecar in an owned task (idempotent; never blocks the caller's turn).
    func discardLater(_ name: StagingFileName) {
        guard let staging = self.state.staging else {
            return
        }
        self.spawn(.entry) { _ in
            // REENTRANCY: f-3 (proposed) — nothing: an idempotent removal that completes regardless of cancellation.
            await staging.discard(name)
        }
    }

    /// The terminal element of an attempt the engine cancelled. A staged file is kept for the next attempt of a job of
    /// the same transfer that still wants the content and is not running or publishing (queued, parked or waiting for a
    /// retry: a completion that raced the cancel is not wasted); otherwise it is discarded.
    private func drained(_ transfer: TransferID, request: TransferRequest, update: TransferUpdate) async {
        defer {
            self.pump()
        }
        guard case .staged(let file) = update else {
            return
        }
        let idle: Bool
        switch self.state.jobs[transfer]?.state {
        case .queued?, .blocked?, .failed(.at)?, .failed(.whenOnline)?, .failed(.nextRun)?:
            idle = true
        case .downloading?, .verifying?, .committing?, .failed(.untilEntryChanges)?, nil:
            idle = false
        }
        guard idle, let job = self.state.jobs[transfer], !job.interests.isEmpty, job.adopt == nil else {
            // REENTRANCY: f-3 (proposed) — nothing: an idempotent removal of a copy nobody wants.
            await self.state.staging?.discard(file.name)
            return
        }
        self.state.jobs[transfer]?.adopt = file
    }

    /// Publishes a file staged by an attempt the engine cancelled, for a job that wants the content again.
    func publishDrained(_ transfer: TransferID, epoch: UInt64, file: StagedFile) async {
        // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
        await self.publish(transfer, epoch: epoch, file: file, cancelledAttempt: true)
    }

    // MARK: Publication (RE-S14, T5, T8, T10, T11)

    /// `downloading → verifying`, publish, then `committing →` present: every interest present **now** receives the
    /// locations (RE-S14).
    func publish(_ transfer: TransferID, epoch: UInt64, file: StagedFile, cancelledAttempt: Bool) async {
        guard var job = self.state.jobs[transfer], job.epoch == epoch else {
            // The job was retired (or replaced) before this publication began: nobody else will publish the file. The
            // transfer ended without a verdict (a half-open probe's exit, §7.7) unless a new job of it runs.
            if self.state.jobs[transfer] == nil {
                self.recordBreaker(.abandoned(transfer))
            }
            // REENTRANCY: f-3 (proposed) — nothing: an idempotent removal of a copy nobody wants.
            await self.state.staging?.discard(file.name)
            return
        }
        guard self.transition(transfer, to: .verifying) else {
            return
        }
        job = self.state.jobs[transfer] ?? job
        job.active = nil
        self.state.jobs[transfer] = job
        self.pump()
        let ids = job.assets.sorted()
        let identity = job.identity
        let lane = job.lane
        let locations: [AssetID: AssetLocation]
        do {
            // REENTRANCY: RE-S14 — the lifecycle and the epoch; `.superseded` re-routes the interests; the result goes
            // to the interests present now.
            locations = try await self.store.publish(file, binding: ids, expecting: identity, urgency: lane)
        } catch {
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.publicationFailed(transfer, epoch: epoch, file: file, error: error, cancelledAttempt: cancelledAttempt)
            return
        }
        guard self.isRunning else {
            return
        }
        self.recordBreaker(.objectSuccess(transfer))
        guard let current = self.state.jobs[transfer], current.epoch == epoch else {
            return
        }
        self.transition(transfer, to: .committing)
        let committed = PlanBuilder.adding(self.state.committedSinceRead, file.byteCount)
        self.state.committedSinceRead = committed
        self.committed(transfer, binding: ids, locations: locations)
        // REENTRANCY: RE-S40 — the lifecycle; the heap's store entry is replaced by the newest deadline.
        await self.refreshStoreDeadlineAfterPublish()
    }

    /// Delivers a commit to every interest. Interests in assets the store did not bind first follow their content, so a
    /// waiter is never answered `.notFound` for an asset that still exists and the run keeps its claim until that content
    /// commits: an asset whose content changed while the job published moves to its new job (T22); one the engine's
    /// copy still maps to this content moves to a fresh job of it once this one is gone, because it joined after the
    /// publication's binding was captured (the next publication binds it; the store deduplicates the bytes, ADR-020),
    /// or because the store refused it while holding a newer manifest than the copy (held until the copy catches up).
    private func committed(_ transfer: TransferID, binding ids: [AssetID], locations: [AssetID: AssetLocation]) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let captured = Set(ids)
        var deferred: [(token: InterestToken, interest: JobInterest, asset: AssetID)] = []
        var refused = false
        for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) {
            let unbound = interest.assets.filter { locations[$0] == nil }
            guard !unbound.isEmpty else {
                continue
            }
            let bound = interest.assets.subtracting(unbound)
            if bound.isEmpty {
                self.state.jobs[transfer]?.interests[token] = nil
            } else {
                self.state.jobs[transfer]?.interests[token]?.assets = bound
            }
            for asset in unbound.sorted() {
                guard self.state.applied.entry(for: asset)?.transferID == transfer else {
                    self.reroute(token, interest: interest, asset: asset, from: transfer)
                    continue
                }
                refused = refused || captured.contains(asset)
                deferred.append((token, interest, asset))
            }
        }
        self.resolveAll(transfer, with: .committed(locations)) {
            if refused {
                self.holdForManifest(transfer)
            }
            for item in deferred {
                self.reroute(item.token, interest: item.interest, asset: item.asset, from: transfer)
            }
        }
        self.pump()
        self.reconcileIdle()
    }

    /// Moves `token`'s interest in `asset` from the job of `old` to the job of the asset's current entry (T22), or ends
    /// it when the asset left the manifest (T21): a waiter gets `.notFound`, a group drops the member, a heal is
    /// forgotten. The run's claim leaves `old` either way, so the run never waits for a job that will not report to it.
    func reroute(_ token: InterestToken, interest: JobInterest, asset: AssetID, from old: TransferID) {
        if interest.kind == .run {
            self.releaseRunClaim(token, asset: asset, from: old)
        }
        guard let entry = self.state.applied.entry(for: asset) else {
            switch interest.kind {
            case .waiter:
                self.state.waiters.removeValue(forKey: token)?.continuation.resume(returning: .failure(.notFound))
            case .prefetch, .ensure:
                self.dropGroupMember(token, asset: asset, from: old)
            case .system:
                self.state.heals[asset] = nil
            case .run:
                break
            }
            return
        }
        switch interest.kind {
        case .waiter:
            guard var waiter = self.state.waiters[token] else {
                return
            }
            waiter.transfer = entry.transferID
            self.state.waiters[token] = waiter
        case .prefetch, .ensure:
            guard self.state.groups[token] != nil else {
                return
            }
            self.state.groups[token]?.pending[asset] = entry.transferID
        case .run:
            guard self.state.run?.token == token else {
                return
            }
            self.state.run?.outstanding[entry.transferID, default: []].insert(asset)
        case .system:
            break
        }
        self.addInterest(token, asset: asset, entry: entry, lane: interest.lane, kind: interest.kind)
    }

    /// A publication failed (ARCHITECTURE §7.6 store rows).
    private func publicationFailed(_ transfer: TransferID, epoch: UInt64, file: StagedFile, error: StoreError, cancelledAttempt: Bool) async {
        guard self.isRunning, let job = self.state.jobs[transfer], job.epoch == epoch else {
            if self.isRunning, self.state.jobs[transfer] == nil {
                self.recordBreaker(.abandoned(transfer))
            }
            return
        }
        // The origin served the bytes; the store's verdict is no breaker input, but it ends a half-open probe without
        // one (§7.7: any other exit returns to `halfOpen(probe: nil)`).
        self.recordBreaker(SyncEngine.publicationBreakerOutcome(error, transfer: transfer))
        switch error {
        case .superseded:
            // The ids no longer want this content (T22/T11): their interests follow their current entries.
            self.transition(transfer, to: .queued)
            self.supersede(transfer)
        case .integrity:
            // The store counts publication integrity failures itself (`StoreMetrics.integrityFailures`).
            self.state.metrics.failures[.integrity] += 1
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.integrityFailed(transfer, epoch: epoch, ids: job.assets.sorted(), identity: job.identity)
        case .fileSystem(.notFound) where cancelledAttempt:
            // ENOENT for an attempt the engine cancelled is that cancellation (ARCHITECTURE §7.6, D-13): a fresh
            // attempt, no failure, no backoff.
            if self.transition(transfer, to: .queued) {
                self.state.jobs[transfer]?.resume = nil
                self.enqueue(transfer)
            }
            self.pump()
        case .fileSystem(.noSpace), .insufficientSpace:
            self.transition(transfer, to: .failed(.nextRun))
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.spaceFailed(transfer, epoch: epoch, required: file.byteCount)
        case .fileSystem(let failure):
            self.transition(transfer, to: .failed(.nextRun))
            self.retryLater(transfer, error: .transient(.localIO(posixCode: FileSystemErrorMapping.posixCode(of: failure)), retryAfter: nil))
        case .unknownAsset, .notPresent:
            self.transition(transfer, to: .failed(.untilEntryChanges))
            self.resolveAll(transfer, with: .failed(.notFound))
        case .assetFailed, .unverifiedRejected:
            self.transition(transfer, to: .failed(.untilEntryChanges))
            self.resolveAll(transfer, with: .failed(error.assetError))
        case .cancelled, .closed, .notOpen:
            return
        case .locked, .purgeRaced, .storageUnavailable:
            self.transition(transfer, to: .failed(.nextRun))
            self.state.metrics.failures[.storage] += 1
            self.record(job.assets.min(), .storage, "publication failed: \(error)")
            self.resolveAll(transfer, with: .failed(error.assetError))
        }
        self.reconcileIdle()
    }

    /// Re-routes every interest of a job whose content its ids no longer want, and removes the job. An asset the
    /// engine's copy of the manifest still maps to this content was superseded by a manifest the store holds and the
    /// copy does not show yet: it waits on a fresh, held job of the content until the copy catches up (F-20), never
    /// `.notFound` while the asset is listed.
    func supersede(_ transfer: TransferID) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        self.state.jobs[transfer]?.interests.removeAll()
        self.removeJob(transfer)
        if job.interests.values.contains(where: { interest in interest.assets.contains { self.state.applied.entry(for: $0)?.transferID == transfer } }) {
            self.holdForManifest(transfer)
        }
        for token in job.interests.keys.sorted() {
            guard let interest = job.interests[token] else {
                continue
            }
            for asset in interest.assets.sorted() {
                self.reroute(token, interest: interest, asset: asset, from: transfer)
            }
        }
        self.checkRunSettled()
        self.pump()
    }

    /// The breaker input of a publication failure: none counts, but every one ends the transfer (ARCHITECTURE §7.7).
    static func publicationBreakerOutcome(_ error: StoreError, transfer: TransferID) -> CircuitBreaker.Outcome {
        switch error {
        case .superseded, .cancelled, .closed, .notOpen:
            return .abandoned(transfer)
        default:
            return .neutral(transfer)
        }
    }
}
