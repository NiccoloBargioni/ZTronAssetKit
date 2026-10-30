import ZTronAssetModel

/// The re-admission passes that re-queue parked or failed jobs when what held them clears (T17, T19). Each reads an
/// index the transition funnel keeps (`laneParked`, `edgeOwed`, `originOwed`), never every job, and re-queues at most
/// `SyncEngine.readmissionsPerTurn` jobs per actor turn: one turn that re-queued 10,000 prefetch members when the network
/// returned held the engine's actor about 22 ms (review of close-out cycle 8, C2).
struct Readmissions: OptionSet, Hashable {
    let rawValue: UInt8

    /// Jobs parked `offline` or for a policy whose lane the current conditions admit (a conditions element). Collected
    /// again in every turn: the gate parks a re-queued job for its lane only when the conditions refuse that lane again.
    static let conditions = Readmissions(rawValue: 1 << 0)
    /// Jobs failed `whenOnline` or transiently when a satisfied network edge arrived (`edgeOwed`, R-SYN-13).
    static let edge = Readmissions(rawValue: 1 << 1)
    /// Jobs parked `circuitOpen` or `throttled` when the origin's breaker closed or its cooldown or throttle ended
    /// (`originOwed`). Owed by the event, never collected again: the gate parks all but a probe again at a cooldown's end,
    /// and collecting those would re-queue them in every turn while the probe runs.
    static let origin = Readmissions(rawValue: 1 << 2)
}

extension JobState {
    /// Whether a lane-wide gate parked the job (`laneParked`).
    var isLaneParked: Bool {
        switch self {
        case .blocked(.offline), .blocked(.policy):
            return true
        default:
            return false
        }
    }

    /// Whether the origin's breaker parked the job (`circuitParked`).
    var isCircuitParked: Bool {
        if case .blocked(.circuitOpen) = self {
            return true
        }
        return false
    }

    /// Whether the origin's throttle parked the job (`throttleParked`).
    var isThrottleParked: Bool {
        if case .blocked(.throttled) = self {
            return true
        }
        return false
    }

    /// Whether the job's origin parked it (its breaker or its throttle).
    var isOriginParked: Bool {
        self.isCircuitParked || self.isThrottleParked
    }

    /// Whether a satisfied network edge re-queues the job early (T19): failed `whenOnline`, or failed with a backoff
    /// after a transient failure (`transient` is the job's `transientFailure`).
    func owedOnEdge(transient: Bool) -> Bool {
        switch self {
        case .failed(.whenOnline):
            return true
        case .failed(.at):
            return transient
        default:
            return false
        }
    }
}

/// The re-queues re-admission turns still owe, read once by a caller that checks many jobs (`checkRunSettled`): a job
/// they cover waits for a follow-up turn because of the bound on one turn's re-queues, not for its gate, which has
/// opened. Mirrors what `readmit` takes in its next turn: the jobs an event owed (`originOwed`, `edgeOwed`, each a subset
/// of the jobs parked or failed the way it was owed, kept by the transition funnel) and, while a conditions pass is owed,
/// the jobs a lane-wide gate parked in a lane the conditions now admit. O(1) per job (C2).
struct OwedRequeues {
    /// `originOwed`.
    let origin: Set<TransferID>
    /// `edgeOwed`.
    let edge: Set<TransferID>
    /// The lanes the conditions admit while a conditions pass is owed; empty otherwise.
    let lanes: Set<AssetPriority>

    /// Whether a follow-up turn owes `job` (at `transfer`) a re-queue.
    func contains(_ transfer: TransferID, _ job: Job) -> Bool {
        if self.origin.contains(transfer) || self.edge.contains(transfer) {
            return true
        }
        return !self.lanes.isEmpty && job.state.isLaneParked && self.lanes.contains(job.lane)
    }
}

/// What parked a job at its origin (`SyncEngine.unblockOrigin`).
enum OriginBlock: Hashable {
    /// The breaker (`blocked(circuitOpen)`).
    case circuitOpen
    /// An origin-wide `Retry-After` (`blocked(throttled)`).
    case throttled
}

extension SyncEngine {
    /// The jobs one re-admission turn re-queues at most before it leaves the rest to a later turn: a re-queue costs
    /// about 1 µs in release (the transition and the queue), so with the candidates' collection and sort the turn stays
    /// a few milliseconds at SPEC §6's 10,000 (C2).
    static let readmissionsPerTurn = 512

    /// Re-queues the jobs `passes` cover, in the order the pump serves them (user singles, user batches, prefetch, bulk;
    /// by queue ticket within a lane), at most `readmissionsPerTurn`; the rest is owed to a follow-up turn, which takes
    /// the jobs parked by a lane-wide gate again from their index under the conditions then current, and the jobs an
    /// event owed from what is left of `edgeOwed` and `originOwed`. A job failed with a backoff loses its retry deadline
    /// when it is re-queued (T19). `true` when a job was re-queued.
    ///
    /// Behind the follow barrier the turn waits (`EventAfterFollow.readmit`, S3-R14 item 2): its ranks, lanes and places
    /// are those the visits and the verdicts before it leave, read under the conditions of its arrival.
    @discardableResult
    func readmit(_ passes: Readmissions) -> Bool {
        if self.defersToFollow {
            self.deferToFollow(.readmit(passes, self.conditionsSnapshot))
            self.notifyObservers()
            return false
        }
        var candidates: [(rank: Int, ticket: UInt64, transfer: TransferID)] = []
        if passes.contains(.conditions), !self.state.laneParked.isEmpty {
            // The gate of a lane-wide block reads only the lane: one verdict per lane, not per job, and no pass at all
            // while the conditions admit no lane (every element while offline).
            let admitted = Set(AssetPriority.allCases.filter { self.laneAdmitsAfterConditions($0) })
            if !admitted.isEmpty {
                for transfer in self.state.laneParked {
                    guard let job = self.state.jobs[transfer], job.state.isLaneParked, admitted.contains(job.lane) else {
                        continue
                    }
                    candidates.append((self.queueRank(job), job.ticket, transfer))
                }
            }
        }
        if passes.contains(.edge) {
            var stale: [TransferID] = []
            for transfer in self.state.edgeOwed {
                guard let job = self.state.jobs[transfer], job.state.owedOnEdge(transient: job.transientFailure) else {
                    stale.append(transfer)
                    continue
                }
                candidates.append((self.queueRank(job), job.ticket, transfer))
            }
            for transfer in stale {
                self.state.edgeOwed.remove(transfer)
            }
        }
        if passes.contains(.origin) {
            var stale: [TransferID] = []
            for transfer in self.state.originOwed {
                guard let job = self.state.jobs[transfer], job.state.isOriginParked else {
                    stale.append(transfer)
                    continue
                }
                candidates.append((self.queueRank(job), job.ticket, transfer))
            }
            for transfer in stale {
                self.state.originOwed.remove(transfer)
            }
        }
        candidates.sort { ($0.rank, $0.ticket) < ($1.rank, $1.ticket) }
        var requeued = false
        for candidate in candidates.prefix(Self.readmissionsPerTurn) {
            let transfer = candidate.transfer
            guard let job = self.state.jobs[transfer] else {
                continue
            }
            if case .failed = job.state {
                self.state.heap.remove(.retry(transfer, epoch: job.epoch))
            }
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
                requeued = true
            }
        }
        if candidates.count > Self.readmissionsPerTurn {
            self.scheduleReadmissionFollowUp(passes)
        } else {
            // Every job an event owed was re-queued or is no longer owed (it left the state it was owed in, or was
            // removed).
            if passes.contains(.edge) {
                self.state.edgeOwed.removeAll()
            }
            if passes.contains(.origin) {
                self.state.originOwed.removeAll()
            }
        }
        return requeued
    }

    /// Re-queues the jobs the origin parked for `kind` (its breaker closed, its cooldown or its throttle ended; T17):
    /// every one parked so now is owed the re-queue (`originOwed`, taken from the index without a pass over the jobs), at
    /// most `readmissionsPerTurn` per turn. A breaker that admits only a probe (a cooldown's end, a watchdog, a probe's
    /// exit without a verdict) re-admits only the first parked job in the pump's order (`readmitForProbe()`): the pump
    /// would park every other one again behind that probe (S3-B-063).
    ///
    /// Behind the follow barrier the gate's opening (the clock, the breaker's outcome) applies now and the re-admission
    /// waits (`EventAfterFollow.unblock`): the jobs it re-queues, and their places, are those the verdicts before it
    /// park, as on a visit-first engine.
    func unblockOrigin(_ kind: OriginBlock) {
        if self.defersToFollow {
            self.deferToFollow(.unblock(kind))
            self.notifyObservers()
            return
        }
        if kind == .circuitOpen, self.breakerAdmitsOnlyProbe() {
            // A cooldown's end, a silent probe's watchdog or a probe's exit without a verdict: one probe to give.
            self.readmitForProbe()
            return
        }
        let parked = kind == .circuitOpen ? self.state.circuitParked : self.state.throttleParked
        if self.state.originOwed.isEmpty {
            self.state.originOwed = parked
        } else {
            self.state.originOwed.formUnion(parked)
        }
        self.readmit(.origin)
    }

    /// Whether a job parked by a lane-wide gate (offline or a policy) would pass that gate now (the gate reads only its
    /// lane: the lane verdict and, for the Apple tier, the engine's own conditions, E-17).
    func laneAdmitsAfterConditions(_ lane: AssetPriority) -> Bool {
        if self.laneVerdict(lane) != .admit {
            return false
        }
        if self.state.remote?.capabilities.tier == .appleHosted, self.appleAccessBlock(self.access(for: lane)) != nil {
            return false
        }
        return true
    }

    /// Schedules one later turn for the re-admissions a turn left after `readmissionsPerTurn` re-queues.
    private func scheduleReadmissionFollowUp(_ passes: Readmissions) {
        self.state.readmissionsOwed.formUnion(passes)
        guard !self.state.readmissionFollowUpScheduled else {
            return
        }
        self.state.readmissionFollowUpScheduled = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; `readmit` re-reads every index.
            await engine.readmissionFollowUp()
        }
        if spawned == nil {
            self.state.readmissionFollowUpScheduled = false
            self.state.readmissionsOwed = []
        }
    }

    /// Test seam: the next re-admission follow-up turns keep their passes owed until `releaseReadmissionFollowUps()`.
    func holdReadmissionFollowUps() {
        self.state.readmissionFollowUpsHeld = true
    }

    /// Test seam: lets a held follow-up run in this turn, or disarms a hold nothing reached.
    func releaseReadmissionFollowUps() {
        self.state.readmissionFollowUpsHeld = false
        guard self.state.readmissionFollowUpWaiting else {
            return
        }
        self.state.readmissionFollowUpWaiting = false
        self.readmissionFollowUp()
    }

    /// The scheduled follow-up: the owed passes, then a pump for what they re-queued.
    private func readmissionFollowUp() {
        if self.state.readmissionFollowUpsHeld {
            // Test seam: the passes stay owed and the turn stays scheduled (`readmissionFollowUpScheduled`) until the
            // release runs it; a pass owed meanwhile joins `readmissionsOwed` without a second task.
            self.state.readmissionFollowUpWaiting = true
            self.notifyObservers()
            return
        }
        self.state.readmissionFollowUpScheduled = false
        let owed = self.state.readmissionsOwed
        self.state.readmissionsOwed = []
        guard self.isRunning, !owed.isEmpty else {
            return
        }
        self.readmit(owed)
        self.pump()
        self.rearm()
        self.notifyObservers()
    }
}

// MARK: Lazy re-admission for the breaker's probe (S3-B-063, L4-R22)

extension SyncEngine {
    /// Whether the origin's breaker admits a job it parked only as its probe at `now` (open past its cooldown, half-open
    /// without a probe or past a silent probe's watchdog; `CircuitBreaker.admission(of:at:)`).
    func breakerAdmitsOnlyProbe() -> Bool {
        guard let origin = self.state.remote?.originID, let breaker = self.state.breakers[origin] else {
            return false
        }
        return breaker.admission(of: nil, at: self.environment.time.monotonicNow()) == .probe
    }

    /// Re-queues the first job the breaker parked in the pump's order (`circuitOrder`) for the probe a breaker that admits
    /// only a probe gives, unless the job re-admitted for it earlier (`probeCandidate`) still waits in the queue and no
    /// parked job ranks before it; the pump dispatches it as the probe, or parks it for another gate (its lane, space),
    /// and its end re-admits the next one (`ensureProbeCandidate()`). Each event re-admits at most one job, in
    /// O(log parked) plus the stale entries it drops, so a chain of probes ending without a verdict is O(parked log
    /// parked) in total, not quadratic (S3-B-063). `true` when a job was re-queued.
    @discardableResult
    func readmitForProbe() -> Bool {
        var waitingRank: Int?
        if let candidate = self.state.probeCandidate, let job = self.state.jobs[candidate], job.state == .queued {
            waitingRank = self.queueRank(job)
        } else {
            self.state.probeCandidate = nil
        }
        while let head = self.state.circuitOrder.first {
            guard let job = self.state.jobs[head.transfer], job.state.isCircuitParked, job.ticket == head.ticket else {
                self.state.circuitOrder.removeFirst()
                continue
            }
            let rank = self.queueRank(job)
            guard rank == head.rank else {
                // Its rank fell since the entry was pushed (an interest left): it goes back at its place.
                self.state.circuitOrder.removeFirst()
                self.state.circuitOrder.insert(CircuitParkedOrder.Entry(rank: rank, ticket: job.ticket, transfer: head.transfer))
                continue
            }
            if let waitingRank, waitingRank <= rank {
                // The job waiting in the queue is served first and takes the probe.
                return false
            }
            self.state.circuitOrder.removeFirst()
            guard self.transition(head.transfer, to: .queued) else {
                continue
            }
            self.enqueue(head.transfer)
            self.state.probeCandidate = head.transfer
            return true
        }
        return false
    }

    /// After a pump: when the breaker admits only a probe that nothing took and nothing waits in the queue for, the job
    /// re-admitted for it was parked for another gate or ended, so the next parked job is re-admitted and a pump owed.
    func ensureProbeCandidate() {
        guard !self.state.circuitParked.isEmpty, self.breakerAdmitsOnlyProbe(), self.readmitForProbe() else {
            return
        }
        self.schedulePumpFollowUp()
    }

    /// Keeps `circuitOrder` in step with `job`, which the breaker parks (or which an interest joined while parked):
    /// pushes its place, and rebuilds the order from the parked set when stale entries outnumber live ones.
    func noteCircuitParked(_ job: Job) {
        self.state.circuitOrder.insert(CircuitParkedOrder.Entry(rank: self.queueRank(job), ticket: job.ticket, transfer: job.transfer))
        let parked = self.state.circuitParked.count
        guard self.state.circuitOrder.count > 2 * parked + 64 else {
            return
        }
        var entries: [CircuitParkedOrder.Entry] = []
        entries.reserveCapacity(parked)
        for transfer in self.state.circuitParked {
            let current = transfer == job.transfer ? job : self.state.jobs[transfer]
            if let current {
                entries.append(CircuitParkedOrder.Entry(rank: self.queueRank(current), ticket: current.ticket, transfer: transfer))
            }
        }
        self.state.circuitOrder.rebuild(entries)
    }
}
