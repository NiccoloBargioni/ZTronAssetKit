import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The behaviour of the bounds close-out cycle 8 put on the engine's actor turns when many jobs park for lack of space
/// (C2, R-SYN-11; review of close-out cycle 7, PROBE-C7C-2; `docs/adr-drafts/f.md`, F-28). The turn lengths themselves
/// are measured by the release benchmark `R-SYN-11: parking a 10,000-member prefetch group for lack of space, and an
/// ENOSPC's free-space read over it, never hold the engine's actor longer than P-9's heartbeat_gap_ms_p99_max`; these
/// tests pin what the bounds must not change: every job still ends where the gate puts it, and nothing is re-queued only
/// to be parked again.
@Suite("Engine regressions, close-out cycle 8")
struct EngineRegressionCycle8Tests {
    // MARK: The space sweep (C2, T17)

    /// A free-space read re-admits the jobs parked for space that the room holds together, in queue order, and leaves the
    /// others parked as they were: re-queuing every job that fits on its own only for the gate to park all but the first
    /// again made each read cost a re-queue and a park per parked job (16 ms in one turn at 10,000; review of close-out
    /// cycle 7). With 1,000 bytes above the reserve and three parked 400-byte members, the first two start and the third
    /// keeps its place: it is never re-queued, so its queue ticket does not change.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: a free-space read re-admits the jobs parked for space that the room holds together and leaves the others parked untouched",
        .timeLimit(.minutes(1))
    )
    func sweepAdmitsWhatTheRoomHoldsTogether() async throws {
        let time = ManualTimeSource()
        let (harness, fileSystem) = EngineRegressionCycle6Tests.harness(time: time)
        let engine = harness.engine
        let entries = (1...3).map { index in
            EngineHarness.onDemand("p\(index)", EngineFixture.bytes(10_811 + UInt64(index), count: 400))
        }
        await harness.serveManifest(entries)
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(300, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.values.filter { $0.state == .blocked(.insufficientSpace) }.count == 3 }
        let third = entries[2].transferID
        let ticket = await engine.readForTests { $0.state.jobs[third]?.ticket }
        // Room for two of the three above the reserve, each of which fits on its own.
        let free = try await harness.store.freeSpace()
        let ballastBytes = try #require(try fileSystem.itemInfo(at: ballast)?.byteSize)
        try fileSystem.write(Data(repeating: 1, count: Int(ballastBytes - (1_000 - (free.volumeOpportunistic - free.reserveBytes)))), to: ballast, mode: .truncate)
        #expect(try await harness.store.freeSpace().volumeOpportunistic - free.reserveBytes == 1_000, "setup: 1,000 bytes above the reserve")
        await engine.refreshFreeSpace()
        await engine.waitForAllHandles()
        let started = await harness.source.starts.map(\.id)
        #expect(started == [entries[0].transferID, entries[1].transferID], "the two members ahead in the queue start: \(started)")
        let after = await engine.readForTests { ($0.state.jobs[third]?.state, $0.state.jobs[third]?.ticket) }
        #expect(after.0 == .blocked(.insufficientSpace), "the third stays parked")
        #expect(after.1 == ticket, "the third was never re-queued (its queue ticket is unchanged)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
