import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Probes of `replayJoin`'s join gap (Stage 3 close-out cycle 21, ruling S3-R26 item 12's answer 6.4; `integrate-rr21.md`
/// ruling 4): a waiting join whose job a later apply passed publishing. Each runs in both orders (`LaneDropVisit`) and
/// expects the visit-first answers in both.
extension EngineFollowBarrierTests {
    // MARK: PROBE-RR21-JOIN-GAP: a waiting join whose job a later apply passed publishing

    /// W's join for zz-a waits for the follow while X (the content of zz-a and zz-d) downloads for V, which wants zz-d;
    /// X then publishes (held at its first store unit), v4 maps zz-a to Y's content and keeps zz-d on X's, and X's
    /// publication ends: it commits, or, X's bytes corrupt, fails its integrity check. Visited first, W joined X at once
    /// and v4's visit passed X publishing, so X's publication's end answered W. Swept first, the drain replays W's join
    /// after v4, and `replayJoin` re-routes it under the copy then (`EngineFollow.swift:704-707`; `integrate-rr21.md`
    /// ruling 4). Returns V's and W's answers.
    @available(macOS 15.0, iOS 18.0, *)
    func joinGap(_ visit: LaneDropVisit, corrupt: Bool, lane: AssetPriority) async throws -> (v: Result<AssetLocation, AssetError>, w: Result<AssetLocation, AssetError>) {
        let seed: UInt64 = corrupt ? 2_021_611 : 2_021_601
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let xBytes = EngineFixture.bytes(seed + 3, count: 16)
        var staged = xBytes
        if corrupt {
            staged[0] ^= 0xFF
        }
        let yBytes = EngineFixture.bytes(seed + 4, count: 20)
        let aOnX = EngineHarness.onDemand("zz-a", xBytes)
        let aOnY = EngineHarness.onDemand("zz-a", yBytes)
        let d = EngineHarness.onDemand("zz-d", xBytes)
        let x = aOnX.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [aOnX, d] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(x, [.hold, .stage(staged), .stage(staged), .stage(staged)])
        await s.harness.source.script(aOnY.transferID, [.stage(yBytes)])
        let v = Task { await engine.awaitAsset(d.identifier, lane: lane) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[x]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [aOnX, d] + Self.laterFillers(seed + 6_000), tag: "v3-join-gap-\(seed)", s, visit: visit)
        let w = Task { await engine.awaitAsset(aOnX.identifier, lane: lane) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, aOnX) }
        } else {
            await engine.awaitCondition { $0.state.jobs[x]?.interests.count == 2 }
        }
        let releaser = try await Self.holdPublication(of: x, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [aOnY, d] + Self.laterFillers(seed + 9_000), tag: "v4-join-gap-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let waiting = await engine.readForTests { e in e.followOwed && FollowBarrier.joinWaits(e, aOnX) && e.state.jobs[x]?.state == .verifying }
            try #require(waiting, "setup: W's join still waits, X publishes, and the follow owes v4's visits")
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await engine.awaitCondition { e in e.state.jobs[x] == nil || e.state.jobs[x]?.attemptEnd != nil }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let vResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: v) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: w) }
        await Self.finishHeld(s)
        return (vResult, wResult)
    }

    /// The join gap with X's publication committing, V and W user waiters: X's commit re-routes the interest it passed
    /// in zz-a, which the copy maps elsewhere, under the copy then (`committed`), as `replayJoin` re-routes W's waiting
    /// join; both orders give W Y's bytes, and V X's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a request's waiting join, whose publishing job a later apply passed, follows the copy as the commit re-routes the job's interests (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierReroutesAWaitingJoinAsACommitReroutesItsPassedInterests(_ visit: LaneDropVisit) async throws {
        let (v, w) = try await self.joinGap(visit, corrupt: false, lane: .userInitiated)
        #expect((try? v.get())?.byteSize == 16, "V gets X's bytes for zz-d: \(v)")
        #expect((try? w.get())?.byteSize == 20, "W, passed on X by v4's visit (visit-first), is re-routed to Y at X's commit: \(w)")
    }
}
