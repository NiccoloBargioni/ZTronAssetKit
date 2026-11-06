import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
// D1 ADAPTATION (design probe): the first wait after the reclaim also ends once the alarm's store work is over and its read adopted, so a
// sweep the design leaves to the follow's end does not hang the wait while the follow's turns are held; the original releases below then end the follow.
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Close-out cycle 8, requirements lens: PROBE-C8R-INFLIGHT-PROMOTE. The setup of
/// `spaceSweepJudgesAJobItsFollowRaisesAtItsUserPlace` (PROMOTE), except that the holder of A's moved interest, C, is not
/// parked for space but downloading (held by the source), so the sweep's pre-phase (`followSweptHolders`, which follows
/// only the space-parked candidates) does not follow it. C (5 MB) is wanted by A (a user waiter) and B (a prefetch waiter,
/// same content), so the follow keeps it running as prefetch work. R (3.5 MB, prefetch) and P (3 MB, prefetch) wait
/// `awaitingSpace` behind C's in-flight bytes, R with the earlier ticket. v3 moves A onto P's content while the bounded
/// follow owes C's visit. The reclaim leaves 6 MB beside C's in-flight 5 MB. Followed first, P is user work, judged first,
/// fits, and R is parked. Sweep first, P is judged at its prefetch place after R.
@Suite("VerifyC8ReqsProbes")
struct VerifyC8ReqsProbes {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C8R-INFLIGHT-PROMOTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func inflightPromote(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x74, count: 4_000_000)
        let qBytes = EngineFixture.bytes(978_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x75, count: 5_000_000)
        let rBytes = Data(repeating: 0x76, count: 3_500_000)
        let pBytes = Data(repeating: 0x77, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        await harness.serveManifest([q] + fillers(760_000) + [a, b, p, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        // 7 MB of room: C (5 MB) starts; R and P wait for x's 4 MB behind C's in-flight bytes.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(7_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await harness.source.script(r.transferID, [.stage(rBytes)])
        await harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state == .blocked(.awaitingSpace) }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.awaitingSpace) }
        // v3 moves A onto P's content; B keeps C's, P and R keep theirs.
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(860_000) + [moved, b, p, r], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c: engine.state.jobs[a.transferID].map { (state: $0.state, lane: $0.lane, holdsA: $0.assets.contains(a.identifier)) },
                r: engine.state.jobs[r.transferID].map { (state: $0.state, rank: engine.queueRank($0), ticket: $0.ticket) },
                p: engine.state.jobs[p.transferID].map { (state: $0.state, rank: engine.queueRank($0), ticket: $0.ticket) }
            )
        }
        print("PROBE-C8R-INFLIGHT-PROMOTE \(visit) before: \(before)")
        let rJob = try #require(before.r, "setup: R's job waits")
        let pJob = try #require(before.p, "setup: P's job waits")
        let cJob = try #require(before.c, "setup: C's job runs")
        #expect(cJob.state == .downloading, "setup: C downloads: \(before)")
        #expect(rJob.state == .blocked(.awaitingSpace) && pJob.state == .blocked(.awaitingSpace) && rJob.ticket < pJob.ticket, "setup: \(before)")
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && !cJob.holdsA && pJob.rank < rJob.rank, "setup: the follow moved A off C and raised P: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && cJob.holdsA && pJob.rank == rJob.rank, "setup: C still holds A, and P ranks as prefetch work: \(before)")
        }
        // The grace ends: the alarm reaps x's 4 MB (6 MB of room beside C's 5 MB in flight) and runs its sweep.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[r.transferID]?.state != .blocked(.awaitingSpace) || ($0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) }
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        print("PROBE-C8R-INFLIGHT-PROMOTE \(visit) A: \(aResult) | B: \(bResult) | P: \(pResult) | R: \(rResult)")
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "A's user waiter, moved onto P, is answered from P's 3 MB: \(aResult)")
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B's waiter is answered from C's 5 MB: \(bResult)")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }
}
