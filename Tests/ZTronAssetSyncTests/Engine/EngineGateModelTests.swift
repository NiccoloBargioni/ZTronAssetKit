import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// L4-R20's randomized model test of the stale-gate family (`docs/adr-drafts/f.md`, F-40). Seeded walks interleave clock
/// moves (to a gate's end or by a random step), held alarm turns (`holdAlarmTurns()`), attempt outcomes of every kind
/// (success, a same-cause 403, a different-cause 503, 404 and 400 without a verdict, 429s with random retry-afters), a
/// prefetch group's registration and release (which abandons its members, a probe among them), and free-space changes.
/// After every step the engine is let settle (`settled`), and four invariants are checked:
/// - I1: no run settles blocked by an origin gate that admits at `now` (checked in the settling turn itself);
/// - I2: no pending run starts while the gate it waits on is closed at `now` (checked in the starting turn);
/// - I3: once the alarm has had its turn, no job stays parked by an origin gate that admits at `now`;
/// - I4: a step makes at most one manifest request, and at most `runsWithoutClockMove` runs start while the clock does not
///   move (runs never repeat without the clock moving; close-out cycle 21 added the second half);
/// - I5 (close-out cycle 21): once the alarm has had its turn, no pending run waits for the breaker or the throttle while
///   that gate admits at `now` and no run is in place;
/// - I6 (close-out cycle 22): in the turn a run starts, a breaker that admits only a probe already holds it for the run's
///   manifest fetch (ARCHITECTURE §7.6/§7.7: the half-open probe is the run's manifest fetch), so no job dispatched in a
///   later turn can take it before that fetch is admitted, unless the origin is throttled at `now` (the fetch then asks for
///   nothing) or the run joins a manifest fetch already admitted (which no gate can reject any more).
/// The walks run with no slot reserved for user-initiated work and, in a second test, with one (close-out cycle 22: a job
/// that waits in the queue for a slot is not parked, which the first set never produced).
/// Every clock move to an instant lands on it exactly (`EngineRegressionCycle21Tests.advance`), so a boundary step reaches
/// the gate's end rather than 1 ns before it.
/// The gates are read by `Oracle`, written from ARCHITECTURE §7.6/§7.7 rather than from the engine's helpers. A failure
/// prints its seed and the walk so far. Every wait is a condition that ends on cancellation (L4-R17).
@Suite("Engine gate model, close-out cycle 20")
struct EngineGateModelTests {
    /// The walks' count and length.
    static let seeds: Range<UInt64> = 0..<160
    static let steps = 60
    /// I4's bound on the runs that start while the clock does not move. A pending run that waits for the breaker starts
    /// only once the breaker closes, or once it admits only a probe and no job it parked or re-admitted can take that
    /// probe first (F-41), and a run that starts then holds the probe for its manifest fetch from its start turn (F-42),
    /// so no run loses its manifest probe; a second run can follow without the clock moving only when the first settles
    /// blocked on claims parked behind a job's probe (one that was not parked when the run started: it waited for a slot,
    /// or a step queued it) and that probe ends without a verdict. 1,000 walks reach 2 at most; the engine of `58287dc`, which started one run per probe that ended without a
    /// verdict, reaches 3 or 4 in 19 of them (seeds 24, 66 and 155 among the 160 here).
    static let runsWithoutClockMove: UInt64 = 2

    /// SplitMix64: the test's own deterministic generator (system randomness stays out of tests, C4).
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = self.state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// The origin's gates at `now`, as the requirements define them: a throttle is in force until its end; an open breaker
    /// rejects until its cooldown ends; a half-open breaker rejects every transfer but its probe only while that probe's
    /// watchdog has not passed, and admits the next transfer as the probe otherwise (no probe, or a silent one).
    struct Oracle: Sendable {
        let throttleInForce: Bool
        /// The breaker rejects a transfer that is not its probe (a job it parked).
        let breakerRejects: Bool
        /// The breaker rejects the manifest fetch: as `breakerRejects`, except that a probe that is the manifest fetch is the
        /// fetch's own (a run started for the breaker's gate holds it, I2).
        let breakerRejectsManifest: Bool
        /// The breaker admits only a probe, and nothing holds it: open past its cooldown, or half-open without a probe or with
        /// one silent past its watchdog (I6).
        let breakerOffersProbe: Bool
        let description: String

        init(_ engine: isolated SyncEngine) {
            let now = engine.environment.time.monotonicNow()
            guard let origin = engine.state.remote?.originID else {
                self.throttleInForce = false
                self.breakerRejects = false
                self.breakerRejectsManifest = false
                self.breakerOffersProbe = false
                self.description = "no origin"
                return
            }
            let throttle = engine.state.throttles[origin]
            self.throttleInForce = throttle.map { $0 > now } ?? false
            let breaker = engine.state.breakers[origin]?.state
            switch breaker {
            case .open(_, let until, _)?:
                self.breakerRejects = now < until
                self.breakerRejectsManifest = self.breakerRejects
                self.breakerOffersProbe = !self.breakerRejects
            case .halfOpen(_, _, let probe?, let watchdog?)?:
                self.breakerRejects = now < watchdog
                self.breakerRejectsManifest = self.breakerRejects && probe != .manifest
                self.breakerOffersProbe = !self.breakerRejects
            case .halfOpen?:
                self.breakerRejects = false
                self.breakerRejectsManifest = false
                self.breakerOffersProbe = true
            default:
                self.breakerRejects = false
                self.breakerRejectsManifest = false
                self.breakerOffersProbe = false
            }
            self.description = "now \(now), throttle \(String(describing: throttle)), breaker \(String(describing: breaker))"
        }

        /// Whether the gate behind `reason` admits at `now`; `nil` for a reason that is not an origin gate.
        func admits(_ reason: BlockReason) -> Bool? {
            switch reason {
            case .throttled:
                return !self.throttleInForce
            case .circuitOpen:
                return !self.breakerRejects
            default:
                return nil
            }
        }
    }

    /// Checks I1, I2 and I6 in the turns that settle and start runs: a condition observer the engine evaluates in every turn
    /// that notifies, never satisfied, so it sees each settlement and each start before anything else changes.
    @available(macOS 15.0, iOS 18.0, *)
    final class Recorder: Sendable {
        struct Seen: Sendable {
            var registered = false
            var started: Set<UInt64> = []
            var settled: Set<UInt64> = []
            var violations: [String] = []
        }

        let seen = Mutex(Seen())

        /// `true` the first time only.
        func markRegistered() -> Bool {
            self.seen.withLock { seen in
                defer { seen.registered = true }
                return !seen.registered
            }
        }

        var registered: Bool {
            self.seen.withLock { $0.registered }
        }

        /// Takes the violations recorded so far.
        func takeViolations() -> [String] {
            self.seen.withLock { seen in
                defer { seen.violations.removeAll() }
                return seen.violations
            }
        }

        func observe(_ engine: isolated SyncEngine) {
            guard let run = engine.state.run else {
                return
            }
            let oracle = Oracle(engine)
            let id = run.id.rawValue
            let trigger = run.trigger
            let settlement = run.settlement
            // A manifest fetch in flight that already passed the gates: the run joins it, and no gate can reject it (I6).
            let joinsFetch = engine.state.manifestFetch?.admitted == true
            self.seen.withLock { seen in
                if seen.started.insert(id).inserted {
                    switch trigger {
                    case .breakerClosed where oracle.breakerRejectsManifest:
                        seen.violations.append("I2: run \(id) started for the breaker's gate while it rejects (\(oracle.description))")
                    case .explicit where oracle.throttleInForce:
                        seen.violations.append("I2: run \(id) started for the throttle's gate while it is in force (\(oracle.description))")
                    default:
                        break
                    }
                    if oracle.breakerOffersProbe, !oracle.throttleInForce, !joinsFetch {
                        seen.violations.append("I6: run \(id) started while the breaker offers its probe to any transfer, not held for the run's manifest fetch (\(oracle.description))")
                    }
                }
                if let settlement, seen.settled.insert(id).inserted, case .blocked(let reason) = settlement, oracle.admits(reason) == true {
                    seen.violations.append("I1: run \(id) settled blocked(\(reason)) while that gate admits (\(oracle.description))")
                }
            }
        }
    }

    /// Whether the engine has finished reacting to the last step: no store work, nothing due unless the alarm's turn is held,
    /// no attempt between its outcome and the engine's handling of it (each in flight waits for the fake source), no
    /// owned task but the alarm, the watchers, those attempts' drivers and a run task waiting for its settlement.
    static func settled(_ engine: isolated SyncEngine) -> Bool {
        let now = engine.environment.time.monotonicNow()
        guard engine.state.storeWorkRuns == 0 else {
            return false
        }
        if let first = engine.state.heap.first, first.at <= now, !engine.alarmTurnHeld {
            return false
        }
        var allowed = Set([engine.state.alarm?.task, engine.state.watcher?.task, engine.state.pressure.task].compactMap { $0 })
        for job in engine.state.jobs.values {
            switch job.state {
            case .verifying, .committing:
                return false
            default:
                break
            }
            if let active = job.active {
                // Its driver waits for the fake source, which holds every attempt until the walk scripts it (a script
                // given before the attempt reaches the source applies when it does).
                guard job.state == .downloading else {
                    return false
                }
                allowed.insert(active.driver)
            }
        }
        let others = engine.state.tasks.keys.filter { !allowed.contains($0) }.count
        guard let run = engine.state.run else {
            return others == 0
        }
        return engine.state.runCompletions[run.token] != nil && others == 1
    }

    /// What `settled` waits for, for a walk the time limit stopped.
    static func dump(_ engine: isolated SyncEngine) -> String {
        let now = engine.environment.time.monotonicNow()
        let jobs = engine.state.jobs.values.sorted { $0.transfer < $1.transfer }.map { job in
            "\(job.transfer.rawValue.prefix(8)) \(job.state) active \(job.active.map { "\($0.driver) handle \($0.handle != nil)" } ?? "-")"
        }
        let allowed = [engine.state.alarm?.task, engine.state.watcher?.task, engine.state.pressure.task].compactMap { $0 }
        return "now \(now), heap first \(String(describing: engine.state.heap.first)), alarm \(String(describing: engine.state.alarm?.deadline)) held \(engine.alarmTurnHeld), "
            + "store work \(engine.state.storeWorkRuns), tasks \(engine.state.tasks.keys.sorted()) allowed \(allowed), run \(String(describing: engine.state.run?.id)) "
            + "waiting \(engine.state.run.map { engine.state.runCompletions[$0.token] != nil } ?? false) settlement \(String(describing: engine.state.run?.settlement)), jobs \(jobs)"
    }

    /// I3: the jobs parked by an origin gate that admits at `now`, read once the alarm has had its turn; and I5: with no run
    /// in place, a pending run that waits for the breaker or the throttle while that gate admits at `now`. I2 checks only
    /// that no run starts while its gate is closed; I5 checks that a pending run starts once its gate admits, read by the
    /// oracle rather than by the engine's own `pendingRunGate`, which `invariantViolations()` uses (close-out cycle 21:
    /// a gate reading that left a pending run waiting for a probe abandoned at its watchdog passed every other check).
    static func staleParks(_ engine: isolated SyncEngine) -> [String] {
        let oracle = Oracle(engine)
        var found = engine.state.jobs.values.compactMap { job -> String? in
            guard case .blocked(let reason) = job.state, oracle.admits(reason) == true else {
                return nil
            }
            return "I3: \(job.transfer) stays parked \(reason) while that gate admits (\(oracle.description))"
        }
        if engine.state.run == nil, let pending = engine.state.pendingRun {
            switch pending.gate {
            case .breaker where !oracle.breakerRejects:
                found.append("I5: the pending run waits on the breaker's gate while it admits (\(oracle.description))")
            case .throttle where !oracle.throttleInForce:
                found.append("I5: the pending run waits on the throttle's gate while it admits (\(oracle.description))")
            default:
                break
            }
        }
        return found
    }

    /// One walk; returns the first violation with the walk so far, or `nil`.
    @available(macOS 15.0, iOS 18.0, *)
    static func walk(seed: UInt64, reservedSlots: Int = 0) async throws -> String? {
        var random = SplitMix(state: seed &* 0x2545_F491_4F6C_DD1D &+ 1)
        let reserve = StoragePolicy().reserveFreeBytes
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 100_000, opportunisticCapacity: reserve + 100_000)
        )
        let tuning = SyncTuning(
            maxConcurrentTransfers: 2 + Int(seed % 2),
            reservedInteractiveSlots: reservedSlots,
            breaker: CircuitBreakerPolicy(authDistinctAssets: 1, authCooldownBase: 60, serverMinimumSamples: 1, serverCooldownBase: 30)
        )
        let harness = EngineHarness.make(time: time, tuning: tuning, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), seed: seed, fileSystem: fileSystem)
        let claims = (0..<5).map { index in
            let bytes = EngineFixture.bytes(20_000 + seed * 16 + UInt64(index))
            return (EngineFixture.entry("claim-\(index)", bytes), bytes)
        }
        let members = (0..<3).map { index in
            let bytes = EngineFixture.bytes(30_000 + seed * 16 + UInt64(index))
            return (EngineHarness.onDemand("member-\(index)", bytes), bytes)
        }
        var bytes: [TransferID: Data] = [:]
        for (entry, data) in claims + members {
            bytes[entry.transferID] = data
        }
        await harness.serveManifest((claims + members).map(\.0))
        let engine = harness.engine
        let origin = harness.source.originID
        let recorder = Recorder()
        let watcher = Task {
            await engine.awaitCondition { engine in
                if recorder.markRegistered() {
                    // Wakes the test's wait below in the turn that registered this observer.
                    engine.notifyObservers()
                }
                recorder.observe(engine)
                return false
            }
        }
        await engine.awaitCondition { _ in recorder.registered }
        let ballast = EngineHarness.base.appendingPathComponent("ballast")
        var log: [String] = ["seed \(seed), \(tuning.maxConcurrentTransfers) slots, \(tuning.reservedInteractiveSlots) reserved"]
        var holding = false
        var full = false
        var group: InterestToken?
        var answerNext = false
        // I4: the runs started since the clock last moved (`lastRunID` when it last moved).
        var runsAtClockMove: UInt64 = 0
        var violation: String?

        func finish() async {
            if holding {
                await engine.releaseAlarmTurns()
            }
            watcher.cancel()
            await watcher.value
            await engine.shutdown()
        }

        try await harness.start()
        if seed % 3 != 0 {
            // Two walks in three start with prefetch members: transfers outside the run, one of which may probe.
            log.append("0: register the prefetch group")
            group = try await engine.registerGroup(members.map(\.0.identifier), lane: .prefetch).get()
        }
        await engine.awaitCondition { Self.settled($0) }
        runsAtClockMove = await engine.readForTests { $0.state.lastRunID }
        for step in 0...Self.steps {
            let requestsBefore = await harness.source.manifestRequests.count
            if step > 0 {
                let view = await engine.readForTests { engine in
                    (
                        engine.state.jobs.values.compactMap { job -> (TransferID, TransferAttempt)? in
                            guard let active = job.active else {
                                return nil
                            }
                            return (job.transfer, active.attempt)
                        }.sorted { $0.0 < $1.0 },
                        engine.state.breakers[origin]?.state,
                        engine.state.throttles[origin],
                        engine.state.heap.first?.at,
                        engine.environment.time.monotonicNow(),
                        engine.state.lastRunID
                    )
                }
                let (active, breaker, throttle, nextDeadline, now, runsBefore) = view
                var probe: TransferID?
                if case .halfOpen(_, _, let current?, _)? = breaker {
                    probe = current
                }
                // The gates' ends still ahead: where a decision can read a gate the clock has just opened.
                var instants: [MonotonicInstant] = []
                if let throttle, throttle > now {
                    instants.append(throttle)
                }
                switch breaker {
                case .open(_, let until, _)? where until > now:
                    instants.append(until)
                case .halfOpen(_, _, _?, let watchdog?)? where watchdog > now:
                    instants.append(watchdog)
                default:
                    break
                }
                let others = active.filter { $0.0 != probe }
                var roll = Int(random.next() % 100)
                if answerNext, !others.isEmpty {
                    // The second half of a boundary step: an attempt other than a probe ends while the alarm's turn for
                    // the gate's end is held.
                    roll = 0
                }
                answerNext = false
                if (70..<85).contains(roll), !instants.isEmpty, !others.isEmpty {
                    // A boundary step: hold the alarm's turns, move the clock to a gate's end, and end an attempt next.
                    let target = instants[Int(random.next() % UInt64(instants.count))]
                    if !holding {
                        await engine.holdAlarmTurns()
                        holding = true
                    }
                    log.append("\(step): hold the alarm's turns and move the clock to the gate's end \(target)")
                    EngineRegressionCycle21Tests.advance(time, to: target)
                    runsAtClockMove = runsBefore
                    answerNext = true
                } else if !active.isEmpty, roll < 38 {
                    // An attempt other than the probe ends three times in four: a silent probe lets the clock pass its watchdog.
                    let pool = !others.isEmpty && (probe == nil || random.next() % 4 != 0) ? others : active
                    let (transfer, attempt) = pool[Int(random.next() % UInt64(pool.count))]
                    let outcomes: [(String, FakeTransferStep)] = [
                        ("success", .stage(bytes[transfer] ?? Data())),
                        ("403", .fail(EngineRegressionCycle20Tests.forbidden)),
                        ("503", .fail(.transient(.serverError(httpStatus: 503), retryAfter: nil))),
                        ("404", .fail(EngineRegressionCycle20Tests.missing)),
                        ("400", .fail(EngineRegressionCycle20Tests.rejected)),
                        ("429", .fail(.transient(.throttled, retryAfter: .seconds(UInt32(5 + random.next() % 86))))),
                    ]
                    let outcome = outcomes[Int(random.next() % UInt64(outcomes.count))]
                    log.append("\(step): \(transfer)\(transfer == probe ? " (probe)" : "") answers \(outcome.0)")
                    await harness.source.script(transfer, [outcome.1])
                    await engine.awaitCondition { $0.state.jobs[transfer]?.active?.attempt != attempt }
                } else if roll < 58 || (70..<85).contains(roll) {
                    if let nextDeadline, nextDeadline > now {
                        instants.append(nextDeadline)
                    }
                    if !instants.isEmpty, random.next() % 5 != 0 {
                        let target = instants[Int(random.next() % UInt64(instants.count))]
                        log.append("\(step): clock to \(target)\(holding ? " (alarm held)" : "")")
                        EngineRegressionCycle21Tests.advance(time, to: target)
                        runsAtClockMove = runsBefore
                    } else {
                        let seconds = Double(1 + random.next() % 70)
                        log.append("\(step): clock +\(seconds) s\(holding ? " (alarm held)" : "")")
                        time.advance(by: seconds)
                        runsAtClockMove = runsBefore
                    }
                } else if roll < 70 {
                    if holding {
                        log.append("\(step): release the alarm's turns")
                        await engine.releaseAlarmTurns()
                    } else {
                        log.append("\(step): hold the alarm's turns")
                        await engine.holdAlarmTurns()
                    }
                    holding.toggle()
                } else if roll < 93 {
                    if let token = group {
                        log.append("\(step): release the prefetch group")
                        await engine.releaseGroup(token)
                        group = nil
                    } else {
                        log.append("\(step): register the prefetch group")
                        group = try await engine.registerGroup(members.map(\.0.identifier), lane: .prefetch).get()
                    }
                } else {
                    try fileSystem.write(Data(), to: ballast, mode: .truncate)
                    if !full {
                        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
                    }
                    full.toggle()
                    log.append("\(step): the volume \(full ? "fills" : "has room again")")
                    await engine.refreshFreeSpace()
                }
                await engine.awaitCondition { Self.settled($0) }
            }
            if Task.isCancelled {
                // The time limit cancelled a wait for the engine to settle: say where it stopped.
                let dump = await engine.readForTests { Self.dump($0) }
                violation = "the engine never settled: \(dump)\n" + log.joined(separator: "\n")
                break
            }
            var found = recorder.takeViolations()
            let requests = await harness.source.manifestRequests.count
            if requests - requestsBefore > 1 {
                found.append("I4: one step made \(requests - requestsBefore) manifest requests")
            }
            let runs = await engine.readForTests { $0.state.lastRunID } - runsAtClockMove
            if runs > Self.runsWithoutClockMove {
                found.append("I4: \(runs) runs started while the clock did not move")
            }
            if !holding {
                found += await engine.readForTests { engine in Self.staleParks(engine) + engine.invariantViolations() }
            }
            if let first = found.first {
                violation = "\(first)\n" + log.joined(separator: "\n")
                break
            }
        }
        await finish()
        return violation
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: seeded walks over clock moves, held alarm turns, probe outcomes, 429s and space events never settle, start or park against a gate that admits at now, and never repeat runs without the clock moving", .timeLimit(.minutes(3)))
    func gateModel() async throws {
        // `GATE_MODEL_SEEDS=17,42` replays chosen walks (a failure prints its seed).
        let only = ProcessInfo.processInfo.environment["GATE_MODEL_SEEDS"].map { $0.split(separator: ",").compactMap { UInt64($0) } }
        for seed in only ?? Array(Self.seeds) {
            if let violation = try await Self.walk(seed: seed) {
                Issue.record("seed \(seed): \(violation)")
                return
            }
        }
    }

    /// The reserved-slot walks' seeds: the same 160, and seed 966, where the cycle-21 correctness verifier's walk with one
    /// reserved slot started three runs while the clock did not move (a job waiting for the slot took each probe exit's
    /// freed slot, and the probe, from the run the exit had started).
    static let reservedSeeds: [UInt64] = Array(Self.seeds) + [966]

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the seeded gate walks with one slot reserved for user-initiated work, so jobs wait in the queue for a slot without being parked, keep every invariant", .timeLimit(.minutes(3)))
    func gateModelWithReservedSlot() async throws {
        // `GATE_MODEL_RESERVED_SEEDS=966` replays chosen walks (a failure prints its seed).
        let only = ProcessInfo.processInfo.environment["GATE_MODEL_RESERVED_SEEDS"].map { $0.split(separator: ",").compactMap { UInt64($0) } }
        for seed in only ?? Self.reservedSeeds {
            if let violation = try await Self.walk(seed: seed, reservedSlots: 1) {
                Issue.record("seed \(seed), one reserved slot: \(violation)")
                return
            }
        }
    }
}
