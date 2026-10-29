import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineIdleTests {
    /// A shutdown answers its waiters and frees its job table over turns of at most `shutdownStepsPerTurn` steps (C2;
    /// Stage 3, S3-PERF-01): with more waiters and jobs than one turn takes, every waiter is still answered `shutDown`
    /// exactly once, the group's join ends, the engine owns nothing afterwards, and the drain holds every continuation
    /// and job the state held (none is left behind for a later turn to miss). The settle's slices are recorded
    /// (`shutdownSlices`): none takes more than `shutdownStepsPerTurn` steps, and together they take every waiter and job,
    /// so the bound holds on any device, not only where the benchmark measures it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: a shutdown over more waiters and jobs than one turn takes answers every waiter shutDown and leaves the engine owning nothing", .timeLimit(.minutes(1)))
    func shutdownDrainsOverSeveralTurns() async throws {
        let count = SyncEngine.shutdownStepsPerTurn + 88
        let entries = (0..<count).map { EngineHarness.onDemand(String(format: "d%04d", $0), EngineFixture.bytes(UInt64(6_100 + $0), count: 32)) }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        try await EngineSingleFlightTests.applied(entries, harness: harness)
        let engine = harness.engine
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count }
        let callers = entries.map { entry in
            Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        }
        await engine.awaitCondition { $0.state.waiters.count == count }
        let drained = await engine.readForTests { engine -> (waiters: Int, jobs: Int, groups: Int, left: Int) in
            // The drain alone, on a copy of the tables it takes; the state is put back, so the shutdown below answers
            // them. The joiner tables the drain answers at once are empty here (no run, start or entry call waits).
            guard engine.state.syncJoiners.isEmpty, engine.state.runCompletions.isEmpty, engine.state.startJoiners.isEmpty,
                engine.state.entryJoins.isEmpty, engine.state.manifestFetch == nil, engine.state.conditionWaiters.isEmpty
            else {
                return (-1, -1, -1, -1)
            }
            let saved = engine.state
            let drain = engine.drainEverything(with: .shutDown)
            let left = engine.state.waiters.count + engine.state.jobs.count + engine.state.groups.count
            let counts = (drain.waiters.count, drain.jobs.count, drain.groups.count, left)
            engine.state = saved
            return counts
        }
        #expect(drained.waiters == count && drained.jobs == count && drained.groups == 1, "the drain takes every waiter, job and group: \(drained)")
        #expect(drained.left == 0, "nothing is left in the state for a later turn: \(drained.left)")
        await engine.shutdown()
        for caller in callers {
            let answer = await caller.value
            #expect(answer == .failure(.shutDown), "\(answer)")
        }
        let slices = await engine.readForTests { $0.state.shutdownSlices }
        #expect(slices.allSatisfy { $0 <= SyncEngine.shutdownStepsPerTurn }, "every turn of the settle takes at most shutdownStepsPerTurn steps: \(slices)")
        #expect(slices.reduce(0, +) == 2 * count, "the slices take every waiter and every job: \(slices)")
        #expect(slices.count >= 3, "\(2 * count) steps take at least three turns: \(slices)")
        let census = await engine.introspect()
        #expect(census.ownedTasks == 0 && census.waiters == 0 && census.interests == 0, "\(census)")
        #expect(await engine.readForTests { $0.state.jobs.isEmpty && $0.state.groups.isEmpty && $0.state.inFlight.isEmpty })
    }
}
