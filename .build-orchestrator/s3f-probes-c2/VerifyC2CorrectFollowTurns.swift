import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probe (s3f close-out verification, cycle 2, correctness lens). Never committed. Release, -enable-testing.
@Suite("VerifyC2Correct follow turns")
struct VerifyC2CorrectFollowTurns {
    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// One follow turn: adopts `manifest` as the copy and runs `followApplied(from:)`, timed.
    static func applyTurn(_ engine: isolated SyncEngine, _ manifest: ValidatedManifest) -> (ms: Double, unfollowed: Int, owedVisits: Int, scans: Int) {
        let previous = engine.state.applied
        let clock = ContinuousClock()
        let start = clock.now
        engine.adoptApplied(manifest, etag: nil)
        engine.followApplied(from: previous)
        let elapsed = clock.now - start
        return (ms(elapsed), engine.state.unfollowed.count, engine.state.followOrder.count - engine.state.followNext, engine.state.followScans.count)
    }

    /// Runs one held follow-up turn, timed, and holds the next.
    static func stepTurn(_ engine: isolated SyncEngine) -> (ms: Double, owedVisits: Int, scans: Int) {
        let clock = ContinuousClock()
        let start = clock.now
        engine.releaseFollowFollowUps()
        let elapsed = clock.now - start
        engine.holdFollowFollowUps()
        return (ms(elapsed), engine.state.followOrder.count - engine.state.followNext, engine.state.followScans.count)
    }

    static func hold(_ engine: isolated SyncEngine) {
        engine.holdFollowFollowUps()
    }

    static func waiting(_ engine: isolated SyncEngine) -> Bool {
        engine.state.followFollowUpWaiting || !engine.followOwed
    }

    static func violations(_ engine: isolated SyncEngine) -> [String] {
        engine.invariantViolations()
    }

    static func owed(_ engine: isolated SyncEngine) -> Bool {
        engine.followOwed
    }

    /// PROBE-W2: the turn of a second apply that lands while the first apply's follow still owes most of its visits: the
    /// restart sorts all of `unfollowed` (up to the whole job table) besides its own bounded pass and visits.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-W2: an apply landing while a 10,000-job follow is owed holds the actor at most 10 ms", .timeLimit(.minutes(10)))
    func restartTurn() async throws {
        var lines: [String] = []
        var worst: [Double] = []
        for round in 0..<3 {
            let count = 10_000
            let bench = try await SyncBench.dispatchBench(members: count)
            let engine = bench.engine
            guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
            while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
                await Task.yield()
            }
            await engine.waitForAllHandles()
            func changed(_ salt: UInt64) -> [ManifestEntry] {
                bench.entries.enumerated().map { index, entry in
                    SyncBench.entry(entry.identifier.rawValue, GeneratedPayload.bytes(seed: salt + UInt64(index), offset: 0, length: bench.size), policy: .onDemand)
                }
            }
            let v2 = try ValidatedManifest(entries: changed(0x91_000 + UInt64(round) * 0x10_000), digest: ContentHash.sha256(of: Data("v2-\(round)".utf8)))
            let v3 = try ValidatedManifest(entries: changed(0x191_000 + UInt64(round) * 0x10_000), digest: ContentHash.sha256(of: Data("v3-\(round)".utf8)))
            await VerifyC2CorrectFollowTurns.hold(engine)
            let first = await VerifyC2CorrectFollowTurns.applyTurn(engine, v2)
            var steps: [Double] = []
            // Step until the passes are done (the visits lag): `unfollowed` then holds most of the table.
            while true {
                while !(await VerifyC2CorrectFollowTurns.waiting(engine)) {
                    await Task.yield()
                }
                let step = await VerifyC2CorrectFollowTurns.stepTurn(engine)
                steps.append(step.ms)
                if step.scans == 0 || steps.count > 64 {
                    break
                }
            }
            while !(await VerifyC2CorrectFollowTurns.waiting(engine)) {
                await Task.yield()
            }
            let restart = await VerifyC2CorrectFollowTurns.applyTurn(engine, v3)
            // Drain the rest of the follow, timing every turn.
            var rest: [Double] = []
            while await VerifyC2CorrectFollowTurns.owed(engine) {
                while !(await VerifyC2CorrectFollowTurns.waiting(engine)) {
                    await Task.yield()
                }
                if !(await VerifyC2CorrectFollowTurns.owed(engine)) {
                    break
                }
                rest.append(await VerifyC2CorrectFollowTurns.stepTurn(engine).ms)
            }
            let violations = await VerifyC2CorrectFollowTurns.violations(engine)
            await engine.shutdown()
            let maxStep = steps.max() ?? 0
            let maxRest = rest.max() ?? 0
            worst.append(max(first.ms, maxStep, restart.ms, maxRest))
            lines.append("round \(round): first \(first.ms) ms (unfollowed \(first.unfollowed), owed \(first.owedVisits)); pass steps \(steps.count) max \(maxStep) ms; restart \(restart.ms) ms (unfollowed \(restart.unfollowed), owed \(restart.owedVisits), scans \(restart.scans)); rest \(rest.count) turns max \(maxRest) ms; violations \(violations.prefix(2))")
        }
        print("PROBE-W2 follow turns at 10,000: \(lines)")
        #expect((worst.min() ?? .infinity) <= 10.0, "PROBE-W2 FAIL: worst turn per round \(worst) ms")
    }

    /// Pushes the place of one parked job until the order rebuilds itself from the parked set, timing each call.
    static func rebuildCost(_ engine: isolated SyncEngine) -> (max: Double, calls: Int, parked: Int, entriesAfter: Int) {
        guard let transfer = engine.state.circuitParked.first, let job = engine.state.jobs[transfer] else {
            return (0, 0, 0, 0)
        }
        let clock = ContinuousClock()
        var longest = 0.0
        var calls = 0
        let parked = engine.state.circuitParked.count
        while calls < 3 * parked + 200 {
            let before = engine.state.circuitOrder.count
            let start = clock.now
            engine.noteCircuitParked(job)
            let elapsed = ms(clock.now - start)
            calls += 1
            longest = max(longest, elapsed)
            if engine.state.circuitOrder.count < before {
                break
            }
        }
        return (longest, calls, parked, engine.state.circuitOrder.count)
    }

    static func parkedCount(_ engine: isolated SyncEngine) -> Int {
        engine.state.circuitParked.count
    }

    /// PROBE-W3: the parked order's rebuild (`noteCircuitParked`) at 10,000 parked jobs, in one call.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-W3: the breaker's parked order rebuilds itself at 10,000 parked jobs within C2", .timeLimit(.minutes(10)))
    func rebuildTurn() async throws {
        var lines: [String] = []
        var costs: [Double] = []
        for _ in 0..<3 {
            let count = 10_000
            let bench = try await SyncBench.scaleBench(members: count, room: nil)
            let engine = bench.engine
            guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
            while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
                await Task.yield()
            }
            var failed = 0
            while !Task.isCancelled, await SyncBench.cooldownEnd(engine) == nil {
                guard failed < count else {
                    throw SyncBenchError.incomplete("the breaker did not open")
                }
                await engine.awaitCondition { engine in
                    !SyncBench.running(engine).isEmpty || SyncBench.cooldownEnd(engine) != nil
                }
                await engine.waitForAllHandles()
                let running = await SyncBench.running(engine)
                failed += running.count
                for transfer in running {
                    await bench.source.script(transfer, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil))])
                }
                while !Task.isCancelled, !(await SyncBench.attemptsEnded(engine, running)) {
                    await Task.yield()
                }
            }
            while !Task.isCancelled, !(await SyncBench.originSettled(engine, probing: false)) {
                await Task.yield()
            }
            let result = await VerifyC2CorrectFollowTurns.rebuildCost(engine)
            costs.append(result.max)
            lines.append("parked \(result.parked): longest noteCircuitParked \(result.max) ms over \(result.calls) calls, entries after \(result.entriesAfter)")
            await engine.shutdown()
        }
        print("PROBE-W3 parked-order rebuild at 10,000: \(lines)")
        #expect((costs.min() ?? .infinity) <= 10.0, "PROBE-W3 FAIL: \(costs)")
    }
}
