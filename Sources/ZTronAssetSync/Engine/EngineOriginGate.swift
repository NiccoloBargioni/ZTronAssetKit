import ZTronAssetModel

/// The origin's gates as they stand at one instant, for a job they parked: the one evaluation every decision about such
/// a job reads (close-out cycle 20, L4-R20, F-40).
///
/// Both gates change without an engine turn. The clock ends a throttle, ends a breaker's cooldown and passes a silent
/// probe's watchdog; an attempt's outcome leaves a half-open breaker without a probe. The alarm's turn that re-queues the
/// jobs a gate parked comes later (the alarm's wake-up and its place in the actor's queue), and a probe's exit without a
/// verdict has no deadline at all. Every stale-gate bug of the close-out (F-35, F-36, F-38, F-39, and cycle 20's two)
/// was a decision that read the gate as the engine had last processed it rather than as it stands. So a run's settling,
/// a pending run's start, a joiner's fail-fast answer, a promotion and a user's backoff skip all read this value, built
/// from the same pure functions the dispatch gate uses (`CircuitBreaker.admission(of:at:)`, the throttle's end against
/// `now`), and a decision that finds a job parked by a gate that admits re-admits it first (`readmitOpenedOriginGates`).
struct OriginGate: Equatable {
    /// The instant the gates were read at.
    let now: MonotonicInstant
    /// The throttle's end while it is in force at `now`.
    let throttledUntil: MonotonicInstant?
    /// Whether a throttle is still recorded whose end `now` has reached: its `.throttle` deadline's turn has not cleared it.
    let throttleEnded: Bool
    /// The breaker's verdict for a transfer that is not its probe (`nil` without a breaker): `.reject` while it is open
    /// before its cooldown's end, or half-open with a probe whose watchdog has not passed.
    let breaker: CircuitBreaker.Admission?

    /// Whether a job the throttle parked would pass the throttle now.
    var admitsThrottleParked: Bool {
        self.throttledUntil == nil
    }

    /// Whether a job the breaker parked would pass the breaker now (as an ordinary transfer or as the next probe).
    var admitsBreakerParked: Bool {
        if case .reject? = self.breaker {
            return false
        }
        return true
    }

    /// The end of a throttle recorded as `end` while it is in force at `now`: the throttle half of the reading, shared with
    /// the dispatch gate, which reads it per job without building the whole value (one dictionary read, C2).
    static func inForce(_ end: MonotonicInstant?, at now: MonotonicInstant) -> MonotonicInstant? {
        guard let end, end > now else {
            return nil
        }
        return end
    }

    /// Whether the gate behind `reason` admits now; `nil` for a reason that is not an origin gate.
    func admits(_ reason: BlockReason) -> Bool? {
        switch reason {
        case .throttled:
            return self.admitsThrottleParked
        case .circuitOpen:
            return self.admitsBreakerParked
        case .offline, .policy, .insufficientSpace, .awaitingSpace:
            return nil
        }
    }
}

extension SyncEngine {
    /// The origin's gates at `now` (`OriginGate`); without a remote source nothing is gated.
    func originGate(at now: MonotonicInstant) -> OriginGate {
        guard let origin = self.state.remote?.originID else {
            return OriginGate(now: now, throttledUntil: nil, throttleEnded: false, breaker: nil)
        }
        let end = self.state.throttles[origin]
        return OriginGate(
            now: now,
            throttledUntil: OriginGate.inForce(end, at: now),
            throttleEnded: end.map { $0 <= now } ?? false,
            breaker: self.state.breakers[origin]?.admission(of: nil, at: now)
        )
    }

    /// The origin's gates now.
    func originGateNow() -> OriginGate {
        self.originGate(at: self.environment.time.monotonicNow())
    }

    /// Performs, in this turn, the transitions `gate` shows the clock or an outcome has opened, as the alarm's `.throttle`
    /// and `.breaker` turns would: an ended throttle is cleared (its deadline dropped) and every job a throttle parked
    /// re-queued (also when no throttle is recorded any more, so no such job is left behind);
    /// every job a breaker that admits parked is re-queued (the first the pump dispatches probes, the others park again
    /// behind it). At most `readmissionsPerTurn` are re-queued and the rest owed (`unblockOrigin`); the pump follows. A
    /// decision that finds a job parked by a gate that admits calls this instead of waiting for the alarm's turn, so no
    /// decision depends on that turn having run (L4-R20, F-40). `true` when a job was re-queued or owed.
    @discardableResult
    func readmitOpenedOriginGates(_ gate: OriginGate) -> Bool {
        guard let origin = self.state.remote?.originID else {
            return false
        }
        var readmitted = false
        if gate.throttleEnded {
            self.endThrottle(origin)
            readmitted = true
        } else if gate.admitsThrottleParked, !self.state.throttleParked.isEmpty {
            self.unblockOrigin(.throttled)
            readmitted = true
        }
        if gate.admitsBreakerParked, !self.state.circuitParked.isEmpty {
            if gate.breaker == .probe {
                // One probe to give: the first parked job in the pump's order is re-admitted for it, unless one already
                // waits in the queue for it (S3-B-063); nothing else is owed then, so no pump is scheduled for nothing.
                if self.readmitForProbe() {
                    readmitted = true
                }
            } else {
                self.unblockOrigin(.circuitOpen)
                readmitted = true
            }
        }
        if readmitted {
            self.schedulePumpFollowUp()
        }
        return readmitted
    }

    /// Clears the origin's ended throttle and re-queues the jobs it parked: the `.throttle` deadline's work, shared by its
    /// alarm turn and `readmitOpenedOriginGates`.
    func endThrottle(_ origin: String) {
        self.state.throttles[origin] = nil
        if self.state.heap.deadline(for: .throttle(origin)) != nil {
            self.state.heap.remove(.throttle(origin))
            self.rearm()
        }
        self.unblockOrigin(.throttled)
    }
}
