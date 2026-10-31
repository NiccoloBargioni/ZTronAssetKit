import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The ids a publication re-routes are re-routed by one visit only (Stage 3 close-out cycle 16; the cycle-15 verifiers'
/// PROBE-C15R-REROUTE-STALE and PROBE-C15C-STALE-REROUTE). `Job.rerouteOnPass` names the ids a visit-first engine had
/// moved before the publication began, which the owed visit that meets the job publishing re-routes at once (ruling
/// S3-R18 item 2). Kept after that visit, it re-routed again an id a later apply had moved back and away while the job
/// published, which a visit-first engine passed and answered with the publication's outcome. Each test runs in both
/// orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// The shared scenario: C (100 kB, the content of zz-a and zz-b, a user waiter each) publishes bytes that fail their
    /// checksum. v3 moves zz-b to N (16 bytes, its download held); C's publication begins after v3's apply and is held at
    /// its first store unit, so behind the barrier it begins while v3's follow still owes C's visit (`rerouteOnPass` is
    /// `[zz-b]`). v4 maps zz-b back to C's content while C still publishes: after v3's follow ended (its visit re-routed
    /// B onto N; N's visit then supersedes N and B rejoins C), or, with `v4WhileOwed`, while v3's follow still owes C's
    /// visit, which then finds nothing moved. v5 moves zz-b to N2 (24 bytes) while the same publication still verifies:
    /// its follow passes C in both orders. Visited first, v3's visit moved B onto N while C downloaded, v4's superseded N
    /// and B rejoined C, and v5's passed C, publishing, so B was answered C's `integrityFailure`. Returns the answers of
    /// A and B.
    @available(macOS 15.0, iOS 18.0, *)
    func staleReroute(_ visit: LaneDropVisit, seed: UInt64, v4WhileOwed: Bool) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>) {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let n2Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        let bMoved2 = EngineHarness.onDemand("zz-b", n2Bytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        await s.harness.source.script(bMoved2.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-stale-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            // Visited first, C's visit moved B onto N, whose download is held, at the apply.
            await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
        }
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            let atPublish = await engine.readForTests { e in (owed: e.followOwed, reroute: e.state.jobs[a.transferID]?.rerouteOnPass) }
            #expect(atPublish.owed && atPublish.reroute == [b.identifier], "setup: C's publication began while v3's follow owed C's visit: \(atPublish)")
        }
        let v4 = [s.q] + fillers + [a, b] + later
        if v4WhileOwed {
            // v4 maps zz-b back while (behind the barrier) v3's follow still owes C's visit: that visit finds nothing moved.
            try await Self.applyHeld(v4, tag: "v4-stale-\(seed)", s, visit: visit)
            if visit == .sweepFollowsFirst {
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            }
        } else {
            if visit == .sweepFollowsFirst {
                // v3's follow visits C, publishing, and re-routes zz-b onto N at once.
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            }
            await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
            // v4 maps zz-b back after v3's follow ended: N's visit supersedes N, and B rejoins C.
            try await Self.applyHeld(v4, tag: "v4-stale-\(seed)", s, visit: .followVisitedFirst)
        }
        let atV4 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), n: e.state.jobs[bMoved.transferID]?.state)
        }
        try #require(atV4.c == .verifying && atV4.cAssets == [a.identifier, b.identifier] && atV4.n == nil, "setup: B is on C, which still publishes, and N is gone: \(atV4)")
        // v5 moves zz-b to N2 while the same publication still verifies: its follow passes C in both orders.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved2] + later, tag: "v5-stale-\(seed)", s, visit: .followVisitedFirst)
        let atV5 = await engine.readForTests { e in e.state.jobs[a.transferID]?.state }
        try #require(atV5 == .verifying, "setup: the same publication still verifies at v5: \(String(describing: atV5))")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (aResult, bResult)
    }

    /// A later apply's follow that passes a publication leaves an id it moved to the publication's outcome, although an
    /// earlier visit of the same publication re-routed that id before an apply moved it back (`staleReroute`, v4 after
    /// v3's follow ended; PROBE-C15R-REROUTE-STALE): behind the barrier, the ids the first visit re-routed stayed in
    /// `rerouteOnPass`, and v5's visit re-routed zz-b onto N2, which served B.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a later apply's follow that passes a publication again leaves an id moved back and away to the publication (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierLeavesAnIdMovedBackAndAwayToThePublication(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.staleReroute(visit, seed: 1_515_002, v4WhileOwed: false)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: v5's follow passed C, publishing (visit-first): \(bResult)")
    }

    /// As above, with v4 applied while v3's follow still owes C's visit (PROBE-C15C-STALE-REROUTE): that visit finds
    /// nothing moved, as a visit-first engine's v4 found B back on C, and its re-route is spent all the same.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an owed visit that finds nothing moved spends the re-route of the publication it meets (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierSpendsTheRerouteOfAVisitThatFindsNothingMoved(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.staleReroute(visit, seed: 1_515_902, v4WhileOwed: true)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: v5's follow passed C, publishing (visit-first): \(bResult)")
    }
}
