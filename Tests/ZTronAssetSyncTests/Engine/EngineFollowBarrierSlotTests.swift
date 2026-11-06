import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A place given behind the follow barrier is admitted on the live throttle, breaker and slots alone (Stage 3 close-out
/// cycle 15: the cycle-14 correctness verifier's PROBE-C14C-STAMP-AHEAD; ruling S3-R18 item 1). Each test runs in both
/// orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// A place given behind the barrier under a throttle, after a place given before the throttle took the last slot,
    /// waits for a slot and starts on the live gates: two slots; C (1 MB, held) downloads for user A and holds one. While
    /// v3's follow is owed, a user requests zz-k1 (K1, held when it runs); then an unknown id's manifest fetch gets a 429
    /// with Retry-After 3 s, which frees no transfer slot; then a user requests zz-k2 (K2). The clock passes the
    /// throttle's end, C completes, and the barrier ends. Visited first, K1 started at once and took the slot C left, so
    /// the pump never tried K2, which waited for a slot and started on the live gates once C completed and the throttle
    /// had ended. Both places stamped "slot free" (cycle 14), K2 was refused on its stamp's throttle at the barrier-end
    /// pump and its caller answered `serverUnavailable(3)` (PROBE-C14C-STAMP-AHEAD).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a place behind an owed follow waits for the slot an earlier place took, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierWaitsForTheSlotAnEarlierPlaceTook(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_320_102
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(maxConcurrentTransfers: 2))
        let engine = s.engine
        let cBytes = Data(repeating: 0xD3, count: 1_000_000)
        let k1Bytes = EngineFixture.bytes(seed + 4, count: 16)
        let k2Bytes = EngineFixture.bytes(seed + 5, count: 20)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k1 = EngineHarness.onDemand("zz-k1", k1Bytes)
        let k2 = EngineHarness.onDemand("zz-k2", k2Bytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, k1, k2], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(k1.transferID, [.hold, .stage(k1Bytes)])
        await s.harness.source.script(k2.transferID, [.stage(k2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(seed + 200) + [a, k1, k2], s, visit: visit)
        let k1Waiter = Task { await engine.awaitAsset(k1.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, k1) }
        } else {
            await engine.awaitCondition { $0.state.jobs[k1.transferID]?.state == .downloading }
        }
        await s.harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(3)))])
        _ = await engine.awaitAsset("zz-none", lane: .userInitiated)
        let throttled = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        try #require(throttled != nil, "setup: the manifest fetch's 429 throttles the origin")
        let k2Waiter = Task { await engine.awaitAsset(k2.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, k2) }
        } else {
            await engine.awaitCondition { $0.state.jobs[k2.transferID]?.state == .queued }
        }
        s.time.advance(by: 4)
        await engine.awaitCondition { e in e.state.remote.flatMap { e.state.throttles[$0.originID] }.map { $0 <= e.environment.time.monotonicNow() } ?? true }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await engine.awaitCondition { $0.state.jobs[k1.transferID]?.state == .downloading }
        await s.harness.source.release(k1.transferID, with: .progress(received: 0, expected: nil))
        let k2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: k2Waiter) }
        let k1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: k1Waiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(cBytes.count), "A is served by C: \(aResult)")
        #expect((try? k1Result.get())?.byteSize == 16, "K1 is served (visit-first): \(k1Result)")
        #expect((try? k2Result.get())?.byteSize == 20, "K2 waited for the slot K1 took and is served once the throttle ended (visit-first): \(k2Result)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
