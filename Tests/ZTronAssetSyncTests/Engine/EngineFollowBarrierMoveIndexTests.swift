import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// What a follow's moves leave on their holder (Stage 3 close-out cycle 21, ruling S3-R26 items 3 and 7;
/// `integrate-c21.md` item B, test B-T4): a bounded move takes the moved ids no interest holds off the holder at its
/// first turn, as a move that fits the turn takes them (`move`'s subtraction). Each runs in both orders
/// (`LaneDropVisit`), with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    // MARK: B-T4: a bounded move's unheld ids

    /// W (a prefetch waiter) wants zz-w, and G (a prefetch group) zz-o1 … zz-o6, all on H's 16 bytes: one job,
    /// downloading (held). G is released while H downloads: its interest leaves H, whose ids keep the six (`dropInterest`
    /// leaves `Job.assets` alone). v3 maps the six to O's content; H's visit moves six ids at four a turn
    /// (`followIDsPerTurn`), so it takes the bounded path (`startMove`), whose items are the interests in the moved ids:
    /// none. A move that fits takes every moved id off the holder; the bounded one must too, or H keeps, after its visit,
    /// ids the copy maps elsewhere (the invariant on visited jobs).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a bounded move takes the moved ids no interest holds off the holder, as a move that fits the turn does (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierTakesABoundedMovesUnheldIDsOffTheHolder(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_021_401
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = 4 }
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let oBytes = EngineFixture.bytes(seed + 3, count: 24)
        let w = EngineHarness.onDemand("zz-w", hBytes)
        let names = (1...6).map { "zz-o\($0)" }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let onO = names.map { EngineHarness.onDemand($0, oBytes) }
        let holder = w.transferID
        try #require(onH.allSatisfy { $0.transferID == holder } && onO.allSatisfy { $0.transferID != holder }, "setup: the six share H's content, and v3 maps them elsewhere")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [w] + onH + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(holder, [.hold, .stage(hBytes)])
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[holder]?.state == .downloading }
        }
        let g = try await engine.registerGroup(onH.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[holder]?.interests[g]?.assets.count == names.count }
        await engine.releaseGroup(g)
        let before = await engine.readForTests { e in (assets: e.state.jobs[holder]?.assets.count, interests: e.state.jobs[holder]?.interests.count, state: e.state.jobs[holder]?.state) }
        try #require(before.assets == 7 && before.interests == 1 && before.state == .downloading, "setup: G's interest left H, which keeps its seven ids and downloads: \(before)")
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [w] + onO + Self.laterFillers(seed + 6_000), tag: "v3-unheld-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns < 8, "the follow ends within 8 turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { e in e.state.jobs[holder]?.assets }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "H's visit left none of the moved ids on it: \(violations.prefix(3))")
        #expect(after == [w.identifier], "H holds zz-w alone once its visit moved the six ids, as a move that fits the turn leaves it: \(after?.sorted() ?? [])")
        await s.harness.source.release(holder, with: .progress(received: 0, expected: nil))
        let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        #expect((try? result.get())?.byteSize == 16, "W gets H's bytes: \(result)")
        await Self.finishHeld(s)
    }
}
