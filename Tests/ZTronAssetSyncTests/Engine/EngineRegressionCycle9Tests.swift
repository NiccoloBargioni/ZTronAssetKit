import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 8 found in WP-F (cycle 9 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-29).
@Suite("Engine regressions, close-out cycle 9")
struct EngineRegressionCycle9Tests {
    // MARK: The cycle-6 clock driver outlived `driving` (L4-R8; PROBE-C8C-5)

    /// PROBE-C8C-5: `EngineRegressionCycle6Tests.driving` cancelled its clock driver without awaiting it, and the
    /// driver's wait for a sleeper returns on cancellation, so the driver could compute the earliest deadline and advance
    /// the clocks once more after `driving` returned: to a sleeper registered after it returned. In
    /// `R-SYN-10: ensureAvailable whose member waits for space fetches it as soon as a purge reclaimed the bytes, not at
    /// the store's next deadline` that sleeper was a purge's grace, which then reaped before the test's setup was done (a
    /// failed setup expectation, then a wait that never ended: the cycle-8 sanitizer run's time-limit overrun). Each round
    /// drives nothing while the driver waits, registers a sleeper 60 s ahead, waits until it is registered and gives a
    /// stale driver turns to act; the clock must not move. The verifier counted 7 and 6 stale advances in 2,000 rounds.
    @Test("R-SYN-11: the clock driver of the space tests has stopped when driving returns, so it never advances a clock to a sleeper registered afterwards (2,000 rounds)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func drivingStopsBeforeReturning() async {
        var stale = 0
        var unseen = 0
        for _ in 0..<2_000 {
            let clock = ManualTimeSource()
            let start = clock.monotonicNow()
            // The operation yields so the driver reaches its wait for a sleeper before `driving` cancels it.
            let value = await EngineRegressionCycle6Tests.driving([clock]) {
                for _ in 0..<4 {
                    await Task.yield()
                }
                return 0
            }
            let sleeper = Task {
                try? await clock.sleep(until: start.adding(seconds: 60))
            }
            // The registration is awaited by yielding (never a wall-clock wait): a stale driver may wake the sleeper
            // before it is seen, and then the clock has moved.
            var turns = 0
            while clock.pendingSleepers == 0, clock.monotonicNow() == start, turns < 10_000 {
                await Task.yield()
                turns += 1
            }
            for _ in 0..<8 {
                await Task.yield()
            }
            if clock.monotonicNow() != start || value != 0 {
                stale += 1
            } else if clock.pendingSleepers == 0 {
                unseen += 1
            }
            sleeper.cancel()
            await sleeper.value
        }
        #expect(stale == 0, "the clock moved after driving returned in \(stale) of 2,000 rounds")
        #expect(unseen == 0, "the sleeper never registered in \(unseen) rounds")
    }

    // MARK: Bounded actor turns at scale (C2; review of close-out cycle 8)

    /// Every job's state.
    @available(macOS 15.0, iOS 18.0, *)
    static func states(_ engine: SyncEngine) async -> [JobState] {
        await EngineRegressionCycle8Tests.states(engine)
    }

    /// The jobs a sweep re-queued count against the room until they start, also for a later sweep: a sweep that the
    /// re-admission bound splits over turns, or the next read's, would otherwise admit again the room the waiting ones
    /// were admitted for (and the gate would park the surplus once a slot frees). Two 300-byte members run on a volume
    /// with room for two; eleven more are parked for space (the third non-user slot is free, so the pump gates each).
    /// The volume gains room for four: the read re-queues four, the free slot starts one, and three wait in the queue,
    /// every slot taken. A second read of the same volume re-queues none.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: a later free-space read counts the jobs an earlier one re-admitted that still wait for a slot, so together they never exceed the room",
        .timeLimit(.minutes(1))
    )
    func laterReadCountsWaitingAdmissions() async throws {
        let count = 13
        let (harness, fileSystem, entries) = try await EngineRegressionCycle8Tests.started(count: count, seed: 10_921)
        let engine = harness.engine
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(600, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.inFlight.count == 2 && $0.state.spaceParked.count == count - 2 }
        let ballastBytes = try #require(try fileSystem.itemInfo(at: ballast)?.byteSize)
        try fileSystem.write(Data(repeating: 1, count: Int(ballastBytes) - 1_200), to: ballast, mode: .truncate)
        await engine.refreshFreeSpace()
        let first = await Self.states(engine)
        #expect(first.filter { $0 == .downloading }.count == 3, "the free slot starts one of the four re-admitted")
        #expect(first.filter { $0 == .queued }.count == 3, "the other three wait for a slot")
        await engine.refreshFreeSpace()
        let second = await Self.states(engine)
        #expect(second.filter { $0 == .queued }.count == 3, "the second read re-queues none: the three waiting take the room")
        #expect(second.filter { $0 == .blocked(.insufficientSpace) }.count == count - 6, "the others stay parked")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
