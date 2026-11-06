import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineSyncTests {
    /// PROBE-C9R-THROTTLE-PRESENT: the throttle exit isolated from the barrier's admission wait. Y (16 bytes, zz-y) is
    /// present in the store. C (1 MB, X) downloads for A (zz-a, user) and B0 (zz-b, user). v3 moves zz-a onto Y's content
    /// (present: the visit answers A from the store, no dispatch needed) and keeps zz-b on X. C's attempt then gets a 429
    /// with Retry-After 600 s (beyond the interactive wait). Visit-first, A was answered from Y before the 429. Behind the
    /// barrier the 429's park fail-fasts A with `serverUnavailable` before the owed visit moves it to present content.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9R-THROTTLE-PRESENT", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC9RThrottlePresent(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 993_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xB4, count: 1_000_000)
        let yBytes = EngineFixture.bytes(993_004, count: 16)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share X")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(733_000) + [a, b, y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        await s.harness.source.script(y.transferID, [.stage(yBytes)])
        let yResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await engine.awaitAsset(y.identifier, lane: .userInitiated) }
        try #require((try? yResult.get())?.byteSize == 16, "setup: Y is present: \(yResult)")
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(600))), .stage(xBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let b0Waiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { ($0.state.jobs[a.transferID]?.interests.count ?? 0) == 2 }
        let aMoved = EngineHarness.onDemand("zz-a", yBytes)
        try #require(aMoved.transferID == y.transferID, "setup: zz-a's new content is Y's")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(833_000) + [aMoved, b, y], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, bound: e.isBound(aMoved.identifier, to: y.transferID)) }
            print("PROBE-C9R-THROTTLE-PRESENT before: \(before)")
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        } else {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let b0Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: b0Waiter) }
        print("PROBE-C9R-THROTTLE-PRESENT \(visit): a=\(aResult) b0=\(b0Result)")
        #expect((try? aResult.get())?.byteSize == 16, "A, moved onto Y's present content by the owed visit, is answered from it (visit-first): \(aResult)")
        if case .failure(.serverUnavailable) = b0Result {
        } else {
            Issue.record("B0, still held by C, gets the throttle's fail-fast answer: \(b0Result)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }
}
