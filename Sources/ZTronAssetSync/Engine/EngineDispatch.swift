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
        self.slotCounts.running
    }

    /// The slot figures of `pump()`, in one pass over the jobs (each figure used to be its own pass, evaluated in every
    /// loop condition; L4-R8 measured the passes as a third of a 10,000-asset sync's engine time under the sanitizer).
    struct SlotCounts {
        /// Downloading and not paused for preemption.
        var running = 0
        /// Running user-initiated transfers.
        var runningUser = 0
        /// Jobs of non-user lanes in downloading ∪ verifying ∪ committing (the pipeline cap gates only those, S2-10).
        var nonUserPipeline = 0

        /// Counts a transfer `pump()` just started in `lane` (a start moves one queued job to downloading and changes
        /// nothing else; a park or a fail-fast answer changes no running job, so the figures need no new pass then).
        mutating func started(in lane: AssetPriority) {
            self.running += 1
            if lane == .userInitiated {
                self.runningUser += 1
            } else {
                self.nonUserPipeline += 1
            }
        }
    }

    /// The slot figures now, from the jobs in flight only (every figure counts downloading, verifying or committing
    /// jobs): a pass over every job cost about 0.35 µs per job in release, about 4 ms per pump at 10,000 parked jobs (C2).
    var slotCounts: SlotCounts {
        var counts = SlotCounts()
        for transfer in self.state.inFlight {
            guard let job = self.state.jobs[transfer] else {
                continue
            }
            let lane = job.lane
            switch job.state {
            case .downloading:
                if job.active?.preempting != true {
                    counts.running += 1
                    if lane == .userInitiated {
                        counts.runningUser += 1
                    }
                }
                if lane < .userInitiated {
                    counts.nonUserPipeline += 1
                }
            case .verifying, .committing:
                if lane < .userInitiated {
                    counts.nonUserPipeline += 1
                }
            case .queued, .blocked, .failed:
                break
            }
        }
        return counts
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
        if self.followBarrier || self.state.drainingAfterFollow {
            // No admission behind the follow barrier (F-28): every start, park and fail-fast answer reads lanes, ranks,
            // interests and the bytes in flight, which the owed visits change (a visit lowers or supersedes the job it
            // moves, raises or creates the job of the moved id's new content, abandons a superseded download). Decided
            // now, a job is judged on a half-followed state, so its answer depended on whether a visit ran first (the
            // close-out cycles 2 to 8). Nor while the events that waited for the follow are drained, during a batch or
            // between two: the places a later batch gives come before work a pump would start meanwhile (the cycle-9
            // amendment (d)). The queues wait; each follow turn pumps again (`pumpWaitsForFollow`), and the drain's last
            // batch pumps on the state every visit and event left.
            self.state.pumpWaitsForFollow = true
            self.scheduleEnsureRefill()
            self.notifyObservers()
            return
        }
        self.state.pumpWaitsForFollow = false
        let maximum = self.tuning.maxConcurrentTransfers
        let userCap = self.userCap
        var guardCount = 0
        // Parks take no slot, so a backlog of jobs that all park (the first conditions after a large join, a re-queue
        // after a free-space read) would otherwise be gated in this one turn: past `parksPerPump`, the rest is left
        // to a later turn (C2). A lane-wide park a turn left unfinished goes first (`parkLane`).
        var parks = self.continueLaneParks(limit: Self.parksPerPump)
        rounds: while guardCount < 10_000 {
            guardCount += 1
            var started = false
            // One pass per round; a start in the round is counted in place (`SlotCounts.started(in:)`), and the next
            // round, which follows any start, reads the jobs again.
            var counts = self.slotCounts
            for kind in [LaneQueues.Kind.userSingle, .userBatch] {
                while maximum - counts.running > 0, counts.runningUser < userCap {
                    guard parks < Self.parksPerPump else {
                        self.schedulePumpFollowUp()
                        break rounds
                    }
                    guard let transfer = self.popDispatchable(kind) else {
                        break
                    }
                    switch self.dispatch(transfer, parkLimit: Self.parksPerPump - parks) {
                    case .started:
                        started = true
                        counts.started(in: self.state.jobs[transfer]?.lane ?? .userInitiated)
                    case .parked(let count):
                        parks += count
                    }
                }
            }
            if self.hasQueuedUser() {
                if self.preemptForUser() {
                    continue
                }
                break
            }
            let nonUserCap = maximum - min(max(self.tuning.reservedInteractiveSlots, 0), maximum - 1)
            let pipelineCap = self.tuning.pipelineDepth * maximum
            while maximum - counts.running > 0, counts.running - counts.runningUser < nonUserCap, counts.nonUserPipeline < pipelineCap {
                guard parks < Self.parksPerPump else {
                    self.schedulePumpFollowUp()
                    break rounds
                }
                guard let transfer = self.nextNonUser() else {
                    break
                }
                switch self.dispatch(transfer, parkLimit: Self.parksPerPump - parks) {
                case .started:
                    started = true
                    counts.started(in: self.state.jobs[transfer]?.lane ?? .bulk)
                case .parked(let count):
                    parks += count
                }
                self.materializeRun()
            }
            if !started {
                break
            }
        }
        if !self.state.laneParksOwed.isEmpty {
            // A lane-wide park stopped at the bound: a later turn continues it whether or not a slot frees.
            self.schedulePumpFollowUp()
        }
        self.ensureProbeCandidate()
        self.checkRunSettled()
        self.scheduleEnsureRefill()
        if self.state.pendingRun?.gate == .breaker {
            // The jobs re-admitted for a breaker that admits only a probe have had their dispatch: one of them is the
            // probe now (the gate rejects, and the probe's outcome reconsiders), or none could start and the pending run's
            // manifest fetch probes (F-4). Read after every follow-up this turn scheduled (`dispatchOwed`, F-41).
            self.reconsiderPendingRun()
        }
        self.notifyObservers()
    }

    /// The jobs one `pump()` turn parks at most before it leaves the rest to a later turn: a park costs about 2 µs in
    /// release (the transition, the fail-fast answers, the queue), so the turn stays near 1 ms whatever the backlog; at
    /// 10,000 parked prefetch members one turn took 20 ms (review of close-out cycle 7, C2).
    static let parksPerPump = 512

    /// Schedules one later `pump()` for the jobs a pump left queued after `parksPerPump` parks.
    func schedulePumpFollowUp() {
        guard !self.state.pumpFollowUpScheduled else {
            return
        }
        self.state.pumpFollowUpScheduled = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; `pump` re-reads every queue.
            await engine.pumpFollowUp()
        }
        if spawned == nil {
            self.state.pumpFollowUpScheduled = false
        }
    }

    /// The scheduled follow-up.
    private func pumpFollowUp() {
        self.state.pumpFollowUpScheduled = false
        self.pump()
    }

    // MARK: ensureAvailable materialisation (S1-15, C2)

    /// The members a group materialises at most at a time (the run's bound: the pipeline plus `runLookahead`); also the
    /// members a prefetch group joins per actor turn (`joinGroup`, C2).
    var materializationLimit: Int {
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
                // An asset that left the manifest is dropped (T21); one bound to its content since the plan (another
                // interest committed it, an apply reused a blob) is done (L4-R5).
                guard let entry = self.state.applied.entry(for: id), !self.isBound(id, to: entry.transferID) else {
                    continue
                }
                group.pending[id] = entry.transferID
                group.joined.append(id)
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

    /// Whether only released groups still want `job` (their interests leave over a few turns, `continueReleases`): it
    /// never starts meanwhile (R-CAR-4), and it is no user work to preempt for. A token still registered in `groups` is
    /// never released, even while the claims its join gave up wait in `releasing` (L5-R15), so a job such a group wants
    /// is never set aside (orchestrator ruling L5-R21, L5-C2-02).
    func isReleasedOnly(_ job: Job) -> Bool {
        !self.state.releasing.isEmpty
            && job.interests.keys.allSatisfy { self.state.releasing[$0] != nil && self.state.groups[$0] == nil }
    }

    /// Whether a queue entry stands for a job only released groups want (`isReleasedOnly`): a scan sets it aside
    /// (`LaneQueues.aside`), where it waits until its job is removed, wanted by another interest (`addInterest` queues it
    /// again), or no release is left (`continueReleases` restores it).
    func setsAside(_ entry: LaneQueues.Entry) -> Bool {
        guard !self.state.releasing.isEmpty, let job = self.state.jobs[entry.transfer] else {
            return false
        }
        return self.isReleasedOnly(job)
    }

    /// Whether a valid user-initiated entry waits that is not draining, held for a manifest catch-up or wanted only by
    /// released groups (those are set aside on the way, so each is stepped over once, C2). The pump reads it only behind
    /// no follow barrier (F-28), so no entry it finds waits for a follow's visit.
    private func hasQueuedUser() -> Bool {
        // The queues are taken out of the state while the closures read it (no overlapping access).
        var queues = self.state.queues
        self.state.queues = LaneQueues()
        var found = false
        for kind in [LaneQueues.Kind.userSingle, .userBatch] where !found {
            let ready = queues.peek(kind, isValid: { self.isValid($0) }, setAside: { self.setsAside($0) }) { entry in
                self.state.draining[entry.transfer] == nil && !self.state.heldForManifest.contains(entry.transfer)
            }
            found = ready != nil
        }
        self.state.queues = queues
        return found
    }

    /// The next prefetch or bulk job: bulk first once its head waited `bulkAging` (sync.md §7.4).
    private func nextNonUser() -> TransferID? {
        let now = self.environment.time.monotonicNow()
        // The queues are taken out of the state while the closure reads it (no overlapping access).
        var queues = self.state.queues
        self.state.queues = LaneQueues()
        let agedBulk = queues.first(.bulk, isValid: { self.isValid($0) }).map { $0.queuedAt.adding(seconds: self.tuning.bulkAging) <= now } ?? false
        self.state.queues = queues
        let order: [LaneQueues.Kind] = agedBulk ? [.bulk, .prefetch] : [.prefetch, .bulk]
        for kind in order {
            if let transfer = self.popDispatchable(kind) {
                return transfer
            }
        }
        return nil
    }

    /// Pops the first valid entry of `kind` whose gates do not say "wait"; a lane whose gate waits is left as is. Entries
    /// of jobs only released groups want are set aside on the way: a user-initiated handle's release left about 10,000
    /// of them in the user queue, and every pump of the release scanned them all twice (here and in `hasQueuedUser`),
    /// about 23 ms of back-to-back turns (review of close-out cycle 9, PROBE-C9C-2, C2).
    private func popDispatchable(_ kind: LaneQueues.Kind) -> TransferID? {
        // The queues are taken out of the state while the closures read it (no overlapping access).
        var queues = self.state.queues
        self.state.queues = LaneQueues()
        let entry = queues.pop(kind, isValid: { self.isValid($0) }, setAside: { self.setsAside($0) }) { candidate in
            self.state.draining[candidate.transfer] == nil && self.gate(candidate.transfer) != .wait
        }
        self.state.queues = queues
        return entry?.transfer
    }

    /// What `dispatch` did with a job.
    private enum Dispatched {
        /// A transfer started.
        case started
        /// The job, and with a lane-wide block other jobs of its lane, were parked or left to wait: the count, toward
        /// the pump's `parksPerPump`.
        case parked(Int)
    }

    /// Starts `transfer` or parks it; a lane-wide block also parks the lane's other queued jobs, at most `parkLimit`
    /// in all (`parkLane`). Reached only behind no follow barrier (`pump`, F-28): a job whose ids the copy maps
    /// elsewhere has been visited, so none of the replaced content of the close-out cycle-2 finding (PROBE-W1) is left
    /// to start.
    private func dispatch(_ transfer: TransferID, parkLimit: Int) -> Dispatched {
        switch self.gate(transfer) {
        case .wait:
            self.enqueue(transfer, front: true)
            return .parked(1)
        case .block(let reason):
            let lane = self.state.jobs[transfer]?.lane
            if let stamp = self.state.placeStamps[transfer] {
                // A place given behind the barrier is parked as at its decision instant (S3-R15 item 3): its fail-fast
                // answers read the wait then, against the throttle's end of that instant's view.
                let end: MonotonicInstant?
                if case .throttled(let until) = reason {
                    end = until
                } else {
                    end = nil
                }
                self.park(transfer, reason: reason, answeredAt: stamp.at, answerEnd: end)
            } else {
                self.park(transfer, reason: reason)
            }
            switch reason {
            case .offline, .policy:
                guard let lane else {
                    return .parked(1)
                }
                return .parked(1 + self.parkLane(lane, reason: reason, limit: parkLimit - 1))
            default:
                return .parked(1)
            }
        case .start(let probe):
            self.start(transfer, probe: probe)
            return .started
        }
    }

    /// Parks the queued jobs of `lane` whose gate gives the lane-wide `reason` (offline, a policy), so a run can settle
    /// blocked, in queue order and at most `limit` of them; returns how many it parked. When it stops at the limit the
    /// lane is owed the rest (`laneParksOwed`), which every later pump continues before it dispatches (a slot need not
    /// free for that): one turn that parked 10,000 queued prefetch members when the network dropped held the engine's
    /// actor about 15 ms (review of close-out cycle 8, C2). A run settles blocked only once none of its claims is queued
    /// (`checkRunSettled`), so it waits for the last of those turns.
    private func parkLane(_ lane: AssetPriority, reason: BlockReason, limit: Int) -> Int {
        var parked = 0
        for kind in self.queueKinds(of: lane) {
            // The queue is taken out of the state while the closure reads it (no overlapping access).
            var queues = self.state.queues
            self.state.queues = LaneQueues()
            queues.dropInvalidHead(kind) { self.isValid($0) }
            let pending = queues.pending(kind)
            self.state.queues = queues
            for entry in pending {
                guard self.isValid(entry), self.state.jobs[entry.transfer]?.lane == lane, self.gate(entry.transfer) == .block(reason) else {
                    continue
                }
                guard parked < limit else {
                    self.state.laneParksOwed[lane] = reason
                    return parked
                }
                self.park(entry.transfer, reason: reason)
                parked += 1
            }
        }
        self.state.laneParksOwed[lane] = nil
        return parked
    }

    /// Continues the lane-wide parks earlier turns left (`laneParksOwed`), at most `limit` parks in all; a lane whose
    /// block changed or cleared meanwhile is no longer owed (a dispatch parks it anew). Returns how many it parked.
    private func continueLaneParks(limit: Int) -> Int {
        var parked = 0
        for lane in self.state.laneParksOwed.keys.sorted() {
            guard let reason = self.state.laneParksOwed[lane] else {
                continue
            }
            guard self.laneWideBlock(lane) == reason else {
                self.state.laneParksOwed[lane] = nil
                continue
            }
            guard parked < limit else {
                break
            }
            parked += self.parkLane(lane, reason: reason, limit: limit - parked)
        }
        return parked
    }

    /// The queues a lane's jobs wait in.
    private func queueKinds(of lane: AssetPriority) -> [LaneQueues.Kind] {
        switch lane {
        case .userInitiated:
            return [.userSingle, .userBatch]
        case .prefetch:
            return [.prefetch]
        case .bulk:
            return [.bulk]
        }
    }

    /// The lane-wide block the gate gives a job of `lane` now, if any: the lane verdict, then, for the Apple tier, the
    /// engine's own conditions (E-17).
    func laneWideBlock(_ lane: AssetPriority) -> BlockReason? {
        if case .block(let reason) = self.laneVerdict(lane) {
            return reason
        }
        if self.state.remote?.capabilities.tier == .appleHosted, let reason = self.appleAccessBlock(self.access(for: lane)) {
            return reason
        }
        return nil
    }

    /// Moves a job to `blocked(reason)` and applies the fail-fast policy (T4), reading a throttle's wait at `answeredAt`
    /// against `answerEnd` when given (`failFast`). A throttle's park keeps the origin's alarm at the origin's end, never
    /// earlier: a park whose 429 waited for the follow carries its own, earlier end while a later 429 extended the
    /// origin's, and moving the alarm back to the park's end re-admitted the throttle's jobs before the origin's end
    /// (PROBE-C10-THROTTLE-EXTENDED).
    func park(_ transfer: TransferID, reason: BlockReason, answeredAt: MonotonicInstant? = nil, answerEnd: MonotonicInstant? = nil) {
        guard self.transition(transfer, to: .blocked(reason)) else {
            return
        }
        if case .throttled(let until) = reason, let origin = self.state.remote?.originID {
            // The live origin's end, whatever decision instant the park reads its answers at (S3-R15 item 1).
            self.state.heap.schedule(.throttle(origin), at: max(self.state.throttles[origin] ?? .zero, until))
            self.rearm()
        }
        if case .circuitOpen = reason {
            self.scheduleBreakerDeadline()
        }
        self.failFast(transfer, reason: reason, at: answeredAt, answerEnd: answerEnd)
        if reason == .awaitingSpace {
            // Only the store's due work wakes it: make sure something will run that work.
            self.ensureSpaceWake()
        }
        self.notifyObservers()
    }

    /// The gates of one queued job: lane admission, the Apple-tier access gate (E-17), the origin throttle, the
    /// breaker and the headroom ledger (sync.md §7.3, §12.1).
    func gate(_ transfer: TransferID) -> DispatchGate {
        guard let job = self.state.jobs[transfer], let remote = self.state.remote, !self.state.heldForManifest.contains(transfer) else {
            return .wait
        }
        if self.isReleasedOnly(job) {
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
        // A place a visit or a replay gave while the follow barrier held reads the origin's gates as they stood at its
        // decision instant (`placeStamps`; S3-R15 item 3, PROBE-C9-THROTTLE): a visit-first engine's pump read them at
        // that place. A later throttle or a breaker opened since stops no transfer that runs, so admitting on that view
        // is the visit-first admission, late by the barrier (R2's accepted latency). A probe's admission is the live
        // breaker's own (`start` records it), so a view that admits only a probe reads the live gates.
        if let stamp = self.state.placeStamps[transfer] {
            let view = self.state.worldHistory[stamp.view]
            if let until = OriginGate.inForce(view.throttle, at: stamp.at) {
                return .block(.throttled(until: until))
            }
            switch view.breaker?.admission(of: transfer, at: stamp.at) {
            case .reject(let cause, _)?:
                return .block(.circuitOpen(cause))
            case .allow?, nil:
                if job.adopt == nil, let reason = self.spaceBlock(job) {
                    return .block(reason)
                }
                return .start(probe: false)
            case .probe?:
                break
            }
        }
        // The origin's gates through the pure functions every other decision reads too (`OriginGate`, F-40), each read
        // once per job: this runs for every job a pump dispatches or parks.
        if let until = OriginGate.inForce(self.state.throttles[remote.originID], at: now) {
            return .block(.throttled(until: until))
        }
        if let breaker = self.state.breakers[remote.originID] {
            switch breaker.admission(of: transfer, at: now) {
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
    /// lack of space is re-admitted only when that much is free (T17). `ahead` is the bytes of the jobs a sweep
    /// re-admitted before this one, which the gate will count in flight once they start (`sweepSpaceParked`).
    func spaceBlock(_ job: Job, ahead: Int64 = 0) -> BlockReason? {
        var size = job.entry.byteSize ?? 0
        if case .insufficientSpace(let required, _)? = job.lastError {
            size = max(size, required)
        }
        guard size > 0, let space = self.state.freeSpace else {
            return nil
        }
        guard size > self.headroom(for: job, in: space).subtractingClamped(ahead) else {
            return nil
        }
        return space.pendingReclaim > 0 ? .awaitingSpace : .insufficientSpace
    }

    /// The ledger's room for `job`: its lane's volume above the reserve, less the bytes of the other jobs in flight and
    /// the bytes committed since the last read. It is also the `available` an `insufficientSpace` for the job reports,
    /// so `required` exceeds it whenever the job was parked for lack of space (ARCHITECTURE §7.6, §7.10). O(1): the
    /// bytes in flight are a running total (`InFlightBytes`), less the job's own when it is in flight itself.
    func headroom(for job: Job, in space: FreeSpace) -> Int64 {
        let volume = job.lane == .userInitiated ? space.volumeImportant : space.volumeOpportunistic
        let own = self.state.jobs[job.transfer]?.ledgerBytes ?? 0
        let inFlight = self.state.inFlightBytes.clamped(excluding: own)
        return max(0, volume.subtractingClamped(max(0, space.reserveBytes)).subtractingClamped(inFlight).subtractingClamped(self.state.committedSinceRead))
    }

    // MARK: Preemption (T16, H-4)

    /// Pauses the lowest-lane, least-advanced, newest running transfer for a waiting user job (never the breaker's
    /// probe); `true` when a victim was marked (its slot is free at once).
    private func preemptForUser() -> Bool {
        guard self.tuning.preemptLowerLanes, self.tuning.maxConcurrentTransfers - self.runningCount <= 0 else {
            return false
        }
        let victims = self.state.inFlight.compactMap { self.state.jobs[$0] }.filter { job in
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
        // A place given behind the barrier started, visit-first, under its decision instant's edge (S3-R15 item 1).
        job.active?.edgeSerial = self.state.placeStamps[transfer].map { self.state.worldHistory[$0.view].edgeSerial } ?? self.state.networkEdgeSerial
        // A publication of a file an earlier attempt staged has no stream: nothing is left to drain if its job is
        // retired before its driver runs (`publish` then discards the file).
        job.active?.terminalReceived = adopt != nil
        self.state.jobs[transfer] = job
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

    /// One attempt: ask the store whether it already holds the content (L4-R5), start the transfer, consume its
    /// updates, apply the terminal element.
    func drive(_ transfer: TransferID, epoch: UInt64, request: TransferRequest) async {
        guard let remote = self.state.remote else {
            return
        }
        // REENTRANCY: f-11 (proposed) — the callee re-validates the lifecycle, the job epoch and the attempt after its
        // reads; an attempt it did not end goes on below, which re-checks the lifecycle, the job epoch and the attempt
        // before `remote.transfer` (L5K-R25: no request for an attempt retired during the reads) and again after it.
        if await self.answeredFromStore(transfer, epoch: epoch, attempt: request.attempt) {
            return
        }
        // Shutdown (or a degradation) may have begun during the reads: an attempt of an engine that is not running is
        // cancelled without a drain below anyway, so no request is sent for it (close-out cycle 4, F-24).
        guard self.isRunning else {
            return
        }
        // Nor for an attempt retired during the reads (its last group released, say) or whose job's epoch or attempt moved
        // on: the request would be cancelled as soon as it was sent (orchestrator ruling L5K-R25; L5K-C4-08, L5K-C4-14).
        // With no request there is no stream to drain, so its draining record ends here, as a drained stream's does
        // (`finishAttempt`), and the transfer's next attempt may start.
        guard self.state.jobs[transfer]?.epoch == epoch, self.state.jobs[transfer]?.active?.attempt == request.attempt else {
            if self.state.draining[transfer]?.attempt == request.attempt {
                self.state.draining[transfer] = nil
            }
            self.pump()
            return
        }
        // Counted where the request is sent: an attempt answered from the store sent none.
        self.state.metrics.transferRequests += 1
        if self.state.jobs[transfer]?.interests.values.contains(where: { $0.kind == .waiter }) == true {
            self.state.metrics.resolveTransfers += 1
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
        if self.state.attemptTerminalsHeld {
            // REENTRANCY: RE-S47 (proposed) — the lifecycle, re-checked right below; `finishAttempt` re-validates the job
            // epoch and the attempt.
            await self.awaitAttemptTerminalRelease()
            guard self.isRunning else {
                return
            }
        }
        // A stream that ends without a terminal element fails the job (sync-1 S1-11).
        let update = terminal ?? .failed(.transient(.incompleteCallbackSequence, retryAfter: nil))
        // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
        await self.finishAttempt(transfer, epoch: epoch, request: request, update: update)
    }

    /// Test seam: the driver waits for `releaseAttemptTerminals()` or for shutdown; it registers synchronously, so a hold
    /// released before it registered lets it pass at once.
    private func awaitAttemptTerminalRelease() async {
        // REENTRANCY: RE-S47 (proposed) — nothing: the body registers synchronously; the caller re-validates the
        // lifecycle, and `finishAttempt` the job epoch and the attempt.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.state.attemptTerminalsHeld, self.isRunning {
                self.state.heldAttemptTerminals.append(continuation)
                self.notifyObservers()
            } else {
                continuation.resume()
            }
        }
    }

    /// Test seam: from now on, a driver that received its attempt's terminal element waits before it applies it, until
    /// `releaseAttemptTerminals()` (Stage 3 close-out cycle 11). A test uses it to let a follow's next turn run between a
    /// transfer's end and the engine's verdict on it, an order production leaves to the scheduler.
    func holdAttemptTerminals() {
        self.state.attemptTerminalsHeld = true
    }

    /// Test seam: disarms the hold and lets every held driver go on, in arrival order; shutdown calls it too.
    func releaseAttemptTerminals() {
        self.state.attemptTerminalsHeld = false
        let held = self.state.heldAttemptTerminals
        self.state.heldAttemptTerminals.removeAll()
        for continuation in held {
            continuation.resume()
        }
    }

    /// Test seam: how many drivers wait for `releaseAttemptTerminals()`.
    var heldAttemptTerminalCount: Int {
        self.state.heldAttemptTerminals.count
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
        // A rate-limited update publishes nothing, yet it is a mutation: the test seams' conditions re-evaluate after it
        // as after any other (`awaitCondition`, L4-R17). With no seam waiting this is one empty-table check.
        self.notifyObservers()
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
        if self.holdsMovedID(job) {
            // A visit-first engine visited this job while it downloaded (S3-R15 item 3, residual R-A).
            self.state.publishedOwingVisit.insert(transfer)
        } else {
            self.state.publishedOwingVisit.remove(transfer)
        }
        self.pump()
        let ids = job.assets.sorted()
        let identity = job.identity
        let lane = job.lane
        let serial = self.state.ledgerForgets
        let locations: [AssetID: AssetLocation]
        do {
            // REENTRANCY: RE-S14 — the lifecycle and the epoch; `.superseded` re-routes the interests; the result goes
            // to the interests present now.
            locations = try await self.store.publish(file, binding: ids, expecting: identity, urgency: lane)
        } catch {
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.publicationFailed(transfer, epoch: epoch, file: file, error: error, cancelledAttempt: cancelledAttempt)
            // A publication that threw may have published first, or doomed a key (the store re-validates the bindings
            // after its snapshot and throws `.superseded` when none is left; a placement that failed drops its provisional
            // reference): its trailing install runs on the alarm all the same (orchestrator ruling L5K-R16).
            // REENTRANCY: RE-S40 — the lifecycle (inside); the heap's store entry is replaced by the newest deadline.
            await self.refreshStoreDeadlineAfterPublish()
            return
        }
        guard self.isRunning else {
            return
        }
        self.recordBreaker(.objectSuccess(transfer))
        guard let current = self.state.jobs[transfer], current.epoch == epoch else {
            // The job ended while its content was published (its asset pruned, its content superseded): the publication's
            // trailing install is scheduled whatever became of the job (L5K-R16).
            // REENTRANCY: RE-S40 — the lifecycle (inside); the heap's store entry is replaced by the newest deadline.
            await self.refreshStoreDeadlineAfterPublish()
            return
        }
        self.transition(transfer, to: .committing)
        self.state.committedSinceRead = PlanBuilder.adding(self.state.committedSinceRead, file.byteCount)
        self.state.committedTotal = PlanBuilder.adding(self.state.committedTotal, file.byteCount)
        if !self.deferCommit(CommitAfterFollow(transfer: transfer, epoch: epoch, ids: ids, locations: locations, serial: serial)) {
            self.committed(transfer, binding: ids, locations: locations, since: serial)
        }
        // REENTRANCY: RE-S40 — the lifecycle; the heap's store entry is replaced by the newest deadline.
        await self.refreshStoreDeadlineAfterPublish()
    }

    /// Defers a commit until the follow's owed visit of its job (`EventAfterFollow.committed`; S3-R15 item 3, residual
    /// R-A, PROBE-C11-COMMIT-PLACE, PROBE-C11R-COMMIT-REROUTE): the job's publication began while it owed that visit
    /// (`publishedOwingVisit`) and it still holds an id the visit moves. A visit-first engine's visit re-routed those
    /// ids' interests while the job downloaded, at the follow's place, and the commit answered the rest; re-routed by the
    /// commit, their joins waited behind requests that arrived after the apply. The job stays `committing` (the ledger
    /// counted the bytes on arrival, S3-R11 R1) until the drain replays the commit after the follow's visit of it.
    /// `false` when the commit is not deferred.
    private func deferCommit(_ commit: CommitAfterFollow) -> Bool {
        guard self.defersToFollow, self.state.publishedOwingVisit.contains(commit.transfer), let job = self.state.jobs[commit.transfer],
              job.assets.contains(where: { self.state.applied.entry(for: $0)?.transferID != commit.transfer }) else {
            self.state.publishedOwingVisit.remove(commit.transfer)
            return false
        }
        self.deferToFollow(.committed(commit))
        self.notifyObservers()
        return true
    }

    /// Delivers a commit to every interest. Interests in assets the store did not bind first follow their content, so a
    /// waiter is never answered `.notFound` for an asset that still exists and the run keeps its claim until that content
    /// commits: an asset whose content changed while the job published moves to its new job (T22); one the engine's
    /// copy still maps to this content moves to a fresh job of it once this one is gone, because it joined after the
    /// publication's binding was captured (the next publication binds it; the store deduplicates the bytes, ADR-020),
    /// or because the store refused it while holding a newer manifest than the copy (held until the copy catches up).
    func committed(_ transfer: TransferID, binding ids: [AssetID], locations: [AssetID: AssetLocation], since serial: UInt64) {
        self.state.publishedOwingVisit.remove(transfer)
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let captured = Set(ids)
        // Remembered unless a binding was forgotten while the publication ran (an eviction the engine processed first).
        self.bind(locations.keys, to: transfer, since: serial)
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
    /// An asset the store holds at its current entry's content (an apply reused a blob for it) joins no job: it is
    /// answered from the store (L4-R5).
    func reroute(_ token: InterestToken, interest: JobInterest, asset: AssetID, from old: TransferID) {
        if interest.kind == .run {
            self.releaseRunClaim(token, asset: asset, from: old)
        }
        guard let entry = self.state.applied.entry(for: asset) else {
            switch interest.kind {
            case .waiter:
                self.state.waiters.removeValue(forKey: token)?.continuation?.resume(returning: .failure(.notFound))
            case .prefetch, .ensure:
                self.dropGroupMember(token, asset: asset, from: old)
            case .system:
                self.state.heals[asset] = nil
            case .run:
                break
            }
            return
        }
        if self.isBound(asset, to: entry.transferID) {
            self.answerPresent(token, kind: interest.kind, lane: interest.lane, asset: asset, at: entry.transferID, from: old)
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
        // The follow's visit of a job whose publication failed is an ordinary one (its exit waits as any other).
        self.state.publishedOwingVisit.remove(transfer)
        switch error {
        case .superseded:
            // The ids no longer want this content (T22/T11): their interests follow their current entries. Behind the
            // follow barrier this exit waits as any other (`AttemptVerdict.supersede`; S3-R15 item 3, residual R-A): the
            // re-routes are the interests the visits leave, at the drain's place.
            if self.defersFailure(transfer, .supersede) {
                break
            }
            self.transition(transfer, to: .queued)
            self.supersede(transfer)
        case .integrity:
            // The store counts publication integrity failures itself (`StoreMetrics.integrityFailures`).
            self.state.metrics.failures[.integrity] += 1
            // REENTRANCY: RE-S13 — nothing here: the callee re-validates the lifecycle and the job epoch after each of its awaits.
            await self.integrityFailed(transfer, epoch: epoch, ids: job.assets.sorted(), identity: job.identity)
        case .fileSystem(.notFound) where cancelledAttempt:
            // ENOENT for an attempt the engine cancelled is that cancellation (ARCHITECTURE §7.6, D-13): a fresh
            // attempt, no failure, no backoff. Behind the follow barrier the re-queue waits as any other exit
            // (`AttemptVerdict.requeue`; S3-R15 item 3, residual R-A): its place is the drain's, after the visits'.
            self.state.jobs[transfer]?.resume = nil
            if self.defersFailure(transfer, .requeue) {
                break
            }
            if self.transition(transfer, to: .queued) {
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
    /// `.notFound` while the asset is listed. A follow passes `settling: false` and checks the run and pumps once per
    /// turn instead (C2).
    func supersede(_ transfer: TransferID, settling: Bool = true) {
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
        guard settling else {
            return
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
