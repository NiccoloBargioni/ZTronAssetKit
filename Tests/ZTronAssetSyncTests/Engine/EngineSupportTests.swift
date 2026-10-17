import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync

/// The pure values the engine is built on: lane admission (R-SYN-7), the circuit breaker (R-SYN-5, ADR-031) and
/// launch reconciliation (R-NET-3, ADR-028).
@Suite("Engine support values")
struct EngineSupportTests {
    // MARK: Lane admission

    static func conditions(
        satisfied: Bool = true,
        expensive: Bool = false,
        constrained: Bool = false,
        lowPower: Bool = false,
        thermal: ThermalLevel = .nominal
    ) -> DeviceConditions {
        DeviceConditions(
            network: NetworkConditions(satisfied: satisfied, expensive: expensive, constrained: constrained),
            power: PowerConditions(lowPowerMode: lowPower, thermal: thermal)
        )
    }

    static func admit(_ lane: AssetPriority, _ conditions: DeviceConditions?, network: NetworkPolicy = NetworkPolicy(), power: PowerPolicy = PowerPolicy(), thermalPause: Bool = false) -> LaneAdmission.Verdict {
        LaneAdmission.evaluate(lane: lane, conditions: conditions, network: network, power: power, pausedForThermal: thermalPause)
    }

    @Test("R-SYN-7: an unsatisfied path blocks bulk and prefetch but admits user-initiated work")
    func offlineAdmission() {
        let offline = EngineSupportTests.conditions(satisfied: false)
        #expect(EngineSupportTests.admit(.userInitiated, offline) == .admit)
        #expect(EngineSupportTests.admit(.prefetch, offline) == .block(.offline))
        #expect(EngineSupportTests.admit(.bulk, offline) == .block(.offline))
        #expect(EngineSupportTests.admit(.bulk, nil) == .block(.offline))
        #expect(EngineSupportTests.admit(.userInitiated, nil) == .admit)
    }

    @Test("R-SYN-7: lane admission follows network and power policy for every lane")
    func policyAdmission() {
        let constrained = EngineSupportTests.conditions(constrained: true)
        let expensive = EngineSupportTests.conditions(expensive: true)
        let lowPower = EngineSupportTests.conditions(lowPower: true)
        // Defaults (ADR-036): bulk on expensive yes, constrained no; prefetch on expensive yes, constrained no.
        #expect(EngineSupportTests.admit(.bulk, constrained) == .block(.policy(.constrainedNetwork)))
        #expect(EngineSupportTests.admit(.prefetch, constrained) == .block(.policy(.constrainedNetwork)))
        #expect(EngineSupportTests.admit(.userInitiated, constrained) == .admit)
        #expect(EngineSupportTests.admit(.bulk, expensive) == .admit)
        let thrifty = NetworkPolicy(bulkOnExpensive: false, prefetchOnExpensive: false)
        #expect(EngineSupportTests.admit(.bulk, expensive, network: thrifty) == .block(.policy(.expensiveNetwork)))
        #expect(EngineSupportTests.admit(.prefetch, expensive, network: thrifty) == .block(.policy(.expensiveNetwork)))
        #expect(EngineSupportTests.admit(.userInitiated, expensive, network: thrifty) == .admit)
        let strictUser = NetworkPolicy(bulkOnExpensive: false, prefetchOnExpensive: false, userInitiatedOverridesPolicy: false)
        #expect(EngineSupportTests.admit(.userInitiated, expensive, network: strictUser) == .block(.policy(.expensiveNetwork)))
        // Low Power Mode pauses bulk but not prefetch (defaults) and never user-initiated work.
        #expect(EngineSupportTests.admit(.bulk, lowPower) == .block(.policy(.lowPowerMode)))
        #expect(EngineSupportTests.admit(.prefetch, lowPower) == .admit)
        #expect(EngineSupportTests.admit(.prefetch, lowPower, power: PowerPolicy(prefetchInLowPowerMode: false)) == .block(.policy(.lowPowerMode)))
        #expect(EngineSupportTests.admit(.userInitiated, lowPower, power: PowerPolicy(prefetchInLowPowerMode: false)) == .admit)
        // Thermal pause names the level; user-initiated work is never paused by it.
        let hot = EngineSupportTests.conditions(thermal: .serious)
        #expect(EngineSupportTests.admit(.bulk, hot, thermalPause: true) == .block(.policy(.thermal(.serious))))
        #expect(EngineSupportTests.admit(.prefetch, hot, thermalPause: true) == .block(.policy(.thermal(.serious))))
        #expect(EngineSupportTests.admit(.userInitiated, hot, thermalPause: true) == .admit)
        #expect(EngineSupportTests.admit(.bulk, hot) == .admit)
        #expect(EngineSupportTests.admit(.bulk, EngineSupportTests.conditions()) == .admit)
    }

    // MARK: Circuit breaker

    static let origin = MonotonicInstant(nanoseconds: 1_000_000_000)

    static func transfer(_ n: Int) -> TransferID {
        TransferID.content(ContentHash.sha256(of: Data("breaker-\(n)".utf8)))
    }

    static func ambiguous(_ n: Int) -> CircuitBreaker.Outcome {
        .failure(EngineSupportTests.transfer(n), .authentication, distinctAsset: AssetID("asset-\(n)"))
    }

    @Test("R-SYN-5: three ambiguous 403s on distinct assets open the auth breaker but one does not")
    func authBreakerOpensOnDistinctAssets() {
        var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
        let now = EngineSupportTests.origin
        breaker.record(EngineSupportTests.ambiguous(1), at: now, seed: 7)
        #expect(breaker.state == .closed)
        // The same asset twice is still one distinct asset.
        breaker.record(EngineSupportTests.ambiguous(1), at: now, seed: 7)
        breaker.record(EngineSupportTests.ambiguous(2), at: now, seed: 7)
        #expect(breaker.state == .closed)
        // An object success in between resets the suspicion.
        breaker.record(.objectSuccess(EngineSupportTests.transfer(9)), at: now, seed: 7)
        breaker.record(EngineSupportTests.ambiguous(3), at: now, seed: 7)
        breaker.record(EngineSupportTests.ambiguous(4), at: now, seed: 7)
        #expect(breaker.state == .closed)
        breaker.record(EngineSupportTests.ambiguous(5), at: now, seed: 7)
        guard case .open(.authentication, let until, 1) = breaker.state else {
            Issue.record("expected an open auth breaker, got \(breaker.state)")
            return
        }
        // Cooldown 300 s with jitter in [0.5c, c].
        #expect(until >= now.adding(seconds: 150) && until <= now.adding(seconds: 300))
        #expect(breaker.nextDeadline() == until)
        #expect(breaker.admit(EngineSupportTests.transfer(10), at: now) == .reject(.authentication, until: until))
    }

    @Test("R-SYN-5: a manifest 403 with a key-rejected hint opens the auth breaker at once")
    func manifestRejectionOpensAtOnce() {
        var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
        breaker.record(.failure(.manifest, .authentication, distinctAsset: nil), at: EngineSupportTests.origin, seed: 1)
        guard case .open(.authentication, _, 1) = breaker.state else {
            Issue.record("expected an open auth breaker, got \(breaker.state)")
            return
        }
    }

    @Test("R-SYN-5: sustained 5xx opens the breaker and a single half-open probe closes it")
    func serverBreakerCycle() {
        var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
        let now = EngineSupportTests.origin
        for n in 0..<4 {
            breaker.record(.failure(EngineSupportTests.transfer(n), .serverErrors, distinctAsset: nil), at: now, seed: 3)
        }
        #expect(breaker.state == .closed, "fewer than the minimum samples never open")
        breaker.record(.failure(EngineSupportTests.transfer(4), .serverErrors, distinctAsset: nil), at: now, seed: 3)
        #expect(breaker.state == .open(cause: .serverErrors, until: now.adding(seconds: 30), trips: 1))
        #expect(breaker.admit(EngineSupportTests.transfer(5), at: now.adding(seconds: 29)) == .reject(.serverErrors, until: now.adding(seconds: 30)))
        let later = now.adding(seconds: 30)
        #expect(breaker.admit(EngineSupportTests.transfer(6), at: later) == .probe)
        #expect(breaker.admit(EngineSupportTests.transfer(7), at: later) == .reject(.serverErrors, until: later.adding(seconds: 60)), "exactly one probe")
        #expect(breaker.nextDeadline() == later.adding(seconds: 60), "the probe watchdog")
        breaker.record(.objectSuccess(EngineSupportTests.transfer(6)), at: later, seed: 3)
        #expect(breaker.state == .closed)
        #expect(breaker.admit(EngineSupportTests.transfer(8), at: later) == .allow)
        #expect(breaker.nextDeadline() == nil)
    }

    @Test("R-SYN-5: a same-cause probe failure re-opens with a doubled cooldown")
    func probeFailureDoublesCooldown() {
        var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
        let now = EngineSupportTests.origin
        for n in 0..<5 {
            breaker.record(.failure(EngineSupportTests.transfer(n), .serverErrors, distinctAsset: nil), at: now, seed: 3)
        }
        let later = now.adding(seconds: 30)
        #expect(breaker.admit(EngineSupportTests.transfer(10), at: later) == .probe)
        breaker.record(.failure(EngineSupportTests.transfer(10), .serverErrors, distinctAsset: nil), at: later, seed: 3)
        #expect(breaker.state == .open(cause: .serverErrors, until: later.adding(seconds: 60), trips: 2))
        // Successes since closing reset the trips only after `objectSuccessesToReset`.
        let again = later.adding(seconds: 60)
        #expect(breaker.admit(EngineSupportTests.transfer(11), at: again) == .probe)
        breaker.record(.objectSuccess(EngineSupportTests.transfer(11)), at: again, seed: 3)
        #expect(breaker.state == .closed)
        for n in 20..<25 {
            breaker.record(.failure(EngineSupportTests.transfer(n), .serverErrors, distinctAsset: nil), at: again, seed: 3)
        }
        #expect(breaker.state == .open(cause: .serverErrors, until: again.adding(seconds: 120), trips: 3))
    }

    @Test("R-SYN-5: a half-open probe that fails offline re-arms the probe instead of wedging the breaker")
    func probeOtherExitRearms() {
        var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
        let now = EngineSupportTests.origin
        breaker.record(.failure(.manifest, .authentication, distinctAsset: nil), at: now, seed: 9)
        let later = now.adding(seconds: 3_600)
        #expect(breaker.admit(EngineSupportTests.transfer(1), at: later) == .probe)
        breaker.record(.neutral(EngineSupportTests.transfer(1)), at: later, seed: 9)
        #expect(breaker.state == .halfOpen(cause: .authentication, trips: 1, probe: nil, watchdog: nil))
        #expect(breaker.admit(EngineSupportTests.transfer(2), at: later) == .probe)
        breaker.record(.abandoned(EngineSupportTests.transfer(2)), at: later, seed: 9)
        #expect(breaker.admit(EngineSupportTests.transfer(3), at: later) == .probe)
        breaker.record(.failure(EngineSupportTests.transfer(3), .serverErrors, distinctAsset: nil), at: later, seed: 9)
        #expect(breaker.state == .halfOpen(cause: .authentication, trips: 1, probe: nil, watchdog: nil), "a different cause re-arms")
    }

    @Test("R-SYN-5: a silent probe is abandoned after the watchdog and the next transfer probes")
    func silentProbeWatchdog() {
        var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
        let now = EngineSupportTests.origin
        for n in 0..<5 {
            breaker.record(.failure(EngineSupportTests.transfer(n), .serverErrors, distinctAsset: nil), at: now, seed: 3)
        }
        let later = now.adding(seconds: 30)
        #expect(breaker.admit(EngineSupportTests.transfer(1), at: later) == .probe)
        #expect(breaker.admit(EngineSupportTests.transfer(1), at: later) == .probe, "the probe itself is admitted again")
        let silent = later.adding(seconds: 60)
        #expect(breaker.admit(EngineSupportTests.transfer(2), at: silent) == .probe)
        #expect(breaker.state == .halfOpen(cause: .serverErrors, trips: 1, probe: EngineSupportTests.transfer(2), watchdog: silent.adding(seconds: 60)))
    }

    @Test("R-SYN-5: the auth cooldown jitter is keyed by the seed and reproducible")
    func cooldownJitterIsKeyed() {
        func openUntil(seed: UInt64) -> MonotonicInstant? {
            var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
            breaker.record(.failure(.manifest, .authentication, distinctAsset: nil), at: EngineSupportTests.origin, seed: seed)
            return breaker.nextDeadline()
        }
        #expect(openUntil(seed: 1) == openUntil(seed: 1))
        let spread = Set((1...16).compactMap { openUntil(seed: $0) })
        #expect(spread.count > 1)
    }

    // MARK: Launch reconciliation

    static let wanted = TransferID.content(ContentHash.sha256(of: Data("wanted".utf8)))
    static let unwanted = TransferID.content(ContentHash.sha256(of: Data("unwanted".utf8)))

    static func name(_ transfer: TransferID, _ sequence: UInt32, _ kind: StagingFileName.Kind = .partial, epoch: UInt64 = 3) -> StagingFileName {
        StagingFileName(transfer: transfer, attempt: TransferAttempt(epoch: epoch, sequence: sequence), kind: kind)
    }

    static func inventory(_ names: [StagingFileName]) -> StagingInventory {
        var items: [StagingFileName: FileItemInfo] = [:]
        for name in names {
            items[name] = FileItemInfo(name: name.rawValue, kind: .file, byteSize: 10, modifiedAt: nil, identity: nil)
        }
        return StagingInventory(items: items, foreign: ["junk.tmp"])
    }

    @Test("R-NET-3: launch reconciliation attaches wanted live tasks, cancels unwanted ones and adopts completed files")
    func reconcileLiveTransfers() {
        let attach = EngineSupportTests.name(EngineSupportTests.wanted, 4)
        let older = EngineSupportTests.name(EngineSupportTests.wanted, 2)
        let cancel = EngineSupportTests.name(EngineSupportTests.unwanted, 5)
        let otherWanted = TransferID.content(ContentHash.sha256(of: Data("other".utf8)))
        let completed = EngineSupportTests.name(otherWanted, 6)
        let completedUnwanted = EngineSupportTests.name(EngineSupportTests.unwanted, 7)
        let live = [
            ReattachedTransfer(name: attach, isRunning: true, bytesReceived: 10),
            ReattachedTransfer(name: older, isRunning: true, bytesReceived: 5),
            ReattachedTransfer(name: cancel, isRunning: true, bytesReceived: 1),
            ReattachedTransfer(name: completed, isRunning: false, bytesReceived: 10),
            ReattachedTransfer(name: completedUnwanted, isRunning: false, bytesReceived: 10),
        ]
        let actions = TransferReconciler.plan(
            live: live,
            staged: EngineSupportTests.inventory([completed, completedUnwanted]),
            wanted: [EngineSupportTests.wanted, otherWanted]
        )
        #expect(Set(actions) == [.attach(attach), .cancel(older), .cancel(cancel), .adoptStaged(completed), .discard(completedUnwanted)])
        #expect(actions.count == 5)
    }

    @Test("R-NET-8: launch reconciliation resumes the newest partial with a sidecar and discards the rest")
    func reconcilePartials() {
        let newest = EngineSupportTests.name(EngineSupportTests.wanted, 9)
        let older = EngineSupportTests.name(EngineSupportTests.wanted, 3)
        let bare = EngineSupportTests.name(EngineSupportTests.wanted, 12)
        let staged = [
            newest, newest.with(kind: .sidecar),
            older, older.with(kind: .sidecar),
            bare,
            EngineSupportTests.name(EngineSupportTests.unwanted, 1),
            EngineSupportTests.name(EngineSupportTests.unwanted, 1, .sidecar),
            EngineSupportTests.name(EngineSupportTests.wanted, 13, .verifying),
            EngineSupportTests.name(EngineSupportTests.wanted, 14, .sidecarTemporary),
            EngineSupportTests.name(EngineSupportTests.wanted, 15, .partialTemporary),
        ]
        let actions = TransferReconciler.plan(live: [], staged: EngineSupportTests.inventory(staged), wanted: [EngineSupportTests.wanted])
        #expect(actions.contains(.resume(newest)))
        #expect(!actions.contains(.discard(newest.with(kind: .sidecar))), "the resumed partial keeps its sidecar")
        for discarded in staged where discarded != newest && discarded != newest.with(kind: .sidecar) {
            #expect(actions.contains(.discard(discarded)), "\(discarded) is discarded")
        }
        #expect(actions.count == staged.count - 1)
    }

    @Test("R-NET-3: a completed transfer makes the partials and sidecars of the same transfer garbage")
    func completedMakesPartialsGarbage() {
        let completed = EngineSupportTests.name(EngineSupportTests.wanted, 8)
        let partial = EngineSupportTests.name(EngineSupportTests.wanted, 5)
        let actions = TransferReconciler.plan(
            live: [ReattachedTransfer(name: completed, isRunning: false, bytesReceived: 10)],
            staged: EngineSupportTests.inventory([completed, partial, partial.with(kind: .sidecar)]),
            wanted: [EngineSupportTests.wanted]
        )
        #expect(Set(actions) == [.adoptStaged(completed), .discard(partial), .discard(partial.with(kind: .sidecar))])
    }

    @Test("R-SYN-1: launch reconciliation output is sorted and independent of input order")
    func reconcileIsDeterministic() {
        var random = SplitMix64(seed: 0xC0FFEE)
        let transfers = (0..<6).map { TransferID.content(ContentHash.sha256(of: Data("t\($0)".utf8))) }
        var live: [ReattachedTransfer] = []
        var staged: [StagingFileName] = []
        for (index, transfer) in transfers.enumerated() {
            live.append(ReattachedTransfer(name: EngineSupportTests.name(transfer, UInt32(index + 20)), isRunning: random.next() % 2 == 0, bytesReceived: 0))
            let partial = EngineSupportTests.name(transfer, UInt32(index + 1))
            staged.append(partial)
            if random.next() % 2 == 0 {
                staged.append(partial.with(kind: .sidecar))
            }
        }
        let wanted = Set(transfers.prefix(3))
        let first = TransferReconciler.plan(live: live, staged: EngineSupportTests.inventory(staged), wanted: wanted)
        let second = TransferReconciler.plan(live: live.reversed(), staged: EngineSupportTests.inventory(staged.reversed()), wanted: wanted)
        #expect(first == second)
        let names = first.map(EngineSupportTests.actionName)
        #expect(names == names.sorted())
    }

    static func actionName(_ action: ReconcileAction) -> StagingFileName {
        switch action {
        case .attach(let name), .cancel(let name), .adoptStaged(let name), .resume(let name), .discard(let name):
            return name
        }
    }
}
