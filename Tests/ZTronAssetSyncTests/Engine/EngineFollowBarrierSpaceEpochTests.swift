import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// An ENOSPC's waiting verdict belongs to the job that failed (Stage 3 close-out cycle 16; the cycle-15 verifiers'
/// PROBE-C15R-SPACE-EPOCH and PROBE-C15C-SPACE-EPOCH, ruling S3-R19 item 3): its replay checks the job's epoch, since the
/// drain's earlier join may have created a new job for the same content. The test runs in both orders (`LaneDropVisit`)
/// with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// An ENOSPC whose job the owed visit superseded gives no verdict to the job a waiting join then creates for the same
    /// content: C (1 MB) is zz-a's content; v3 moves zz-a to N (16 bytes) and maps zz-x onto C's content. While v3's
    /// follow is owed (300 prefetch members before zz-a keep C's visit owed past the ENOSPC read's own follow turn, and
    /// the space sweep's follow-up turns are held), a user asks for zz-x (the join waits), then C's attempt fails ENOSPC
    /// reporting 20 MB with 5 MB of room (the verdict waits). The follow's visit supersedes C, the drain's join creates a
    /// new job C' for C's content, and the `.spaceFailure` replay skips it. Visited first, C was superseded at the apply,
    /// and C' started for zz-x and served it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an ENOSPC's waiting verdict skips a new job the drain created for its content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesASpaceVerdictOnlyToTheJobThatFailed(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_602
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let cBytes = Data(repeating: 0xA7, count: 1_000_000)
        let xBytes = EngineFixture.bytes(seed + 1, count: 40)
        let nBytes = EngineFixture.bytes(seed + 2, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        let xMoved = EngineHarness.onDemand("zz-x", cBytes)
        try #require(xMoved.transferID == a.transferID, "setup: v3's zz-x is C's content")
        let members = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(seed + 98 + UInt64($0), count: 16)) }
        let movedMembers = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(seed + 498 + UInt64($0), count: 16)) }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 898) + members + [a, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        for entry in members + movedMembers {
            await s.harness.source.script(entry.transferID, [.hold])
        }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { current in members.allSatisfy { current.state.jobs[$0.transferID] != nil } }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(seed + 1_298) + movedMembers + [aMoved, xMoved], s, visit: visit)
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, xMoved) }
            // The ENOSPC's free-space read runs one follow turn (`advanceFollowForSpaceSweep`); the space sweep's own
            // follow-up turns, which would run the rest of the follow before the verdict waits, are held.
            await engine.readForTests { $0.holdSpaceSweepFollowUps() }
            try await Self.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
            await s.harness.source.release(a.transferID, with: .failed(.insufficientSpace(requiredBytes: 20_000_000)))
            await engine.awaitCondition { $0.state.eventsAfterFollow.contains(where: Self.isSpaceFailure) }
            let waits = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            try #require(waits.owed && waits.c != nil, "setup: C's ENOSPC verdict waits before C's owed visit: \(waits)")
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseSpaceSweepFollowUps()
            }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        } else {
            try await Self.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
        }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? xResult.get())?.byteSize == Int64(cBytes.count), "zz-x's caller is served C's content by a new job (visit-first): \(xResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A is served N (visit-first): \(aResult)")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }
}
