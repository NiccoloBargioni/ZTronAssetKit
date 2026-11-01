import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// An apply's walk for the publications in flight finds an id that a newer copy maps to a checksum-less content whose job
/// publishes (Stage 3 close-out cycle 20, ruling S3-R25 item 6; the cycle-19 requirements verifier's
/// PROBE-C19R-LEGACY-TARGET): `findInbound` keys a checksum-less target, and looks up a listed entry with no checksum,
/// by identifier (`byIdentifier`), where a checksummed one is keyed by content. The cycle-19 draft recorded both lookups
/// as unreached; this pins them. The case runs in both orders (`LaneDropVisit`), with the visit-first answers expected in
/// both, and with the owed follow-ups released before or after T's publication resumes.
extension EngineFollowBarrierTests {
    /// T (zz-x's legacy entry, no checksum, 16 bytes) has a user waiter A and publishes, held at its first store unit. v3
    /// maps zz-x to C (checksummed, 100 kB) and is visited in full: T's visit passes T, publishing, so A stays on T. B's
    /// request for zz-x then joins H (C's job), which downloads (held). v3b changes only the leading fillers, so
    /// sweep-first the follow owes its scans when v4 lands: v4's apply walks and leaves its follow's first turn to the
    /// held follow-up, and H stays unvisited. v4 maps zz-x back to T's legacy entry; v5 changes only the later fillers.
    /// Sweep-first, v5's walk under v4's copy finds H holding zz-x, which v4 maps to T's checksum-less content, and
    /// records the move H → T [zz-x]. Visited first, v4's visit superseded H and joined B to T, publishing, so T's
    /// publication answers A and B with its 16 bytes, and T's content starts once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: an apply's walk moves an id onto a publishing checksum-less content's job, with the visit-first answers (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [false, true])
    func barrierWalksOntoAChecksumLessPublication(_ visit: LaneDropVisit, followUpsFirst: Bool) async throws {
        let seed: UInt64 = 1_919_902
        let tuning = SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 2)
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 16)
        let cBytes = EngineFixture.bytes(seed + 5, count: 100_000)
        let lx = EngineFixture.entry("zz-x", tBytes, policy: .onDemand, checksum: false)
        let xOnC = EngineHarness.onDemand("zz-x", cBytes)
        try #require(lx.checksum == nil && lx.transferID != xOnC.transferID, "setup: zz-x on a checksum-less content, then on C")
        let fillers = FollowBarrier.fillers(seed + 200)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [lx] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // A second attempt of T's content gets the same bytes, so an extra request shows as a start, not a hang.
        await s.harness.source.script(lx.transferID, [.hold, .stage(tBytes), .stage(tBytes)])
        await s.harness.source.script(xOnC.transferID, [.hold, .stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(lx.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[lx.transferID]?.state == .downloading }
        }
        // T's publication begins, held at its first store unit.
        let releaser = try await Self.holdPublication(of: lx.transferID, s, bulk: bulk)
        try await Self.applyHeld([s.q] + fillers + [xOnC] + Self.laterFillers(seed + 6_000), tag: "v3-legacy-\(seed)", s, visit: .followVisitedFirst)
        let bWaiter = Task { await engine.awaitAsset(xOnC.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[xOnC.transferID]?.state == .downloading }
        }
        let both = await engine.readForTests { e in
            (t: e.state.jobs[lx.transferID]?.assets, tState: e.state.jobs[lx.transferID]?.state, h: e.state.jobs[xOnC.transferID]?.assets)
        }
        try #require(both.t == [lx.identifier] && both.tState == .verifying && both.h == [lx.identifier], "setup: zz-x is on T, publishing, and on H, downloading: \(both)")
        let fillersB = FollowBarrier.fillers(seed + 300)
        try await Self.applyHeld([s.q] + fillersB + [xOnC] + Self.laterFillers(seed + 6_000), tag: "v3b-legacy-\(seed)", s, visit: visit)
        try await Self.applyHeld([s.q] + fillersB + [lx] + Self.laterFillers(seed + 9_000), tag: "v4-legacy-\(seed)", s, visit: visit)
        try await Self.applyHeld([s.q] + fillersB + [lx] + Self.laterFillers(seed + 12_000), tag: "v5-legacy-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in
                e.state.inboundMoves[e.state.inboundNext...].map { "\($0.holder) -> \($0.target): \($0.ids.sorted())" }
            }
            let atWalk = await engine.readForTests { e in
                e.state.inboundMoves[e.state.inboundNext...].contains { $0.holder == xOnC.transferID && $0.target == lx.transferID && $0.ids == [lx.identifier] }
            }
            #expect(atWalk, "v5's walk under v4's copy records H's zz-x onto T's checksum-less content: \(owed)")
        }
        if followUpsFirst, visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if !followUpsFirst, visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let tStarts = await s.harness.source.starts.filter { $0.id == lx.transferID }.count
        #expect(aResult.map(\.byteSize) == .success(16), "T's publication answers A (visit-first): \(aResult)")
        #expect(bResult.map(\.byteSize) == .success(16) && bResult == aResult, "v4's visit joined B to T, publishing: T's publication answers B (visit-first): \(bResult) vs \(aResult)")
        #expect(tStarts == 1, "T's content starts once (visit-first): \(tStarts)")
        await Self.finishHeld(s)
    }
}
