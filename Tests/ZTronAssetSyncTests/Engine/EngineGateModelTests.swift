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
/// - I4: a step makes at most one manifest request (runs never repeat without the clock moving).
/// The gates are read by `Oracle`, written from ARCHITECTURE §7.6/§7.7 rather than from the engine's helpers. A failure
/// prints its seed and the walk so far. Every wait is a condition that ends on cancellation (L4-R17).
@Suite("Engine gate model, close-out cycle 20")
struct EngineGateModelTests {
    /// The walks' count and length.
    static let seeds: Range<UInt64> = 0..<160
    static let steps = 60

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
        let breakerRejects: Bool
        let description: String

        init(_ engine: isolated SyncEngine) {
            let now = engine.environment.time.monotonicNow()
            guard let origin = engine.state.remote?.originID else {
                self.throttleInForce = false
                self.breakerRejects = false
                self.description = "no origin"
                return
            }
            let throttle = engine.state.throttles[origin]
            self.throttleInForce = throttle.map { $0 > now } ?? false
            let breaker = engine.state.breakers[origin]?.state
            switch breaker {
            case .open(_, let until, _)?:
                self.breakerRejects = now < until
            case .halfOpen(_, _, _?, let watchdog?)?:
                self.breakerRejects = now < watchdog
            default:
                self.breakerRejects = false
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

    /// Checks I1 and I2 in the turns that settle and start runs: a condition observer the engine evaluates in every turn
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
            self.seen.withLock { seen in
                if seen.started.insert(id).inserted {
                    switch trigger {
                    case .breakerClosed where oracle.breakerRejects:
                        seen.violations.append("I2: run \(id) started for the breaker's gate while it rejects (\(oracle.description))")
                    case .explicit where oracle.throttleInForce:
                        seen.violations.append("I2: run \(id) started for the throttle's gate while it is in force (\(oracle.description))")
                    default:
                        break
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

    /// I3: the jobs parked by an origin gate that admits at `now`, read once the alarm has had its turn.
    static func staleParks(_ engine: isolated SyncEngine) -> [String] {
        let oracle = Oracle(engine)
        return engine.state.jobs.values.compactMap { job -> String? in
            guard case .blocked(let reason) = job.state, oracle.admits(reason) == true else {
                return nil
            }
            return "I3: \(job.transfer) stays parked \(reason) while that gate admits (\(oracle.description))"
        }
    }

    /// One walk; returns the first violation with the walk so far, or `nil`.
    @available(macOS 15.0, iOS 18.0, *)
    static func walk(seed: UInt64) async throws -> String? {
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
            reservedInteractiveSlots: 0,
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
        var log: [String] = ["seed \(seed), \(tuning.maxConcurrentTransfers) slots"]
        var holding = false
        var full = false
        var group: InterestToken?
        var answerNext = false
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
                        engine.environment.time.monotonicNow()
                    )
                }
                let (active, breaker, throttle, nextDeadline, now) = view
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
                    time.advance(to: target)
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
                        time.advance(to: target)
                    } else {
                        let seconds = Double(1 + random.next() % 70)
                        log.append("\(step): clock +\(seconds) s\(holding ? " (alarm held)" : "")")
                        time.advance(by: seconds)
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
}
