import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The slots a place given behind the follow barrier is stamped against (Stage 3 close-out cycle 15: the cycle-14
/// correctness verifier's PROBE-C14C-STAMP-AHEAD; ruling S3-R16 item 1(a)). A place is refused on its stamp's throttle
/// only where a visit-first engine's pump tried it: a slot was free for its lane after the places given before it that
/// such a pump started. Each test runs in both orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// What `placesAhead` observed: the answers of K1 (requested before the throttle), K2 and, with three slots, K3
    /// (requested under it).
    struct PlacesAheadOutcome {
        /// K1's answer.
        let k1: Result<AssetLocation, AssetError>
        /// K2's answer.
        let k2: Result<AssetLocation, AssetError>
        /// K3's answer, with three slots.
        let k3: Result<AssetLocation, AssetError>?
    }

    /// The shared scenario of the tests below. `slots` transfer slots; C (1 MB, held) downloads for user A and holds one.
    /// While v3's follow is owed, a user requests zz-k1 (K1, held when it runs); then an unknown id's manifest fetch gets a
    /// 429 with Retry-After 3 s, which frees no transfer slot; then a user requests zz-k2 (K2) and, with three slots,
    /// zz-k3 (K3). The clock passes the throttle's end, C completes, and the barrier ends. Visited first, K1 started at
    /// once and took a slot; with two slots no slot was left for K2, which waited and started on the live gates; with
    /// three, the pump tried K2 and K3 under the throttle, refused both and answered their users.
    @available(macOS 15.0, iOS 18.0, *)
    func placesAhead(_ visit: LaneDropVisit, slots: Int, seed: UInt64) async throws -> PlacesAheadOutcome {
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(maxConcurrentTransfers: slots))
        let engine = s.engine
        let cBytes = Data(repeating: 0xD3, count: 1_000_000)
        let k1Bytes = EngineFixture.bytes(seed + 4, count: 16)
        let k2Bytes = EngineFixture.bytes(seed + 5, count: 20)
        let k3Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k1 = EngineHarness.onDemand("zz-k1", k1Bytes)
        let k2 = EngineHarness.onDemand("zz-k2", k2Bytes)
        let k3 = EngineHarness.onDemand("zz-k3", k3Bytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, k1, k2, k3], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(k1.transferID, [.hold, .stage(k1Bytes)])
        await s.harness.source.script(k2.transferID, [.stage(k2Bytes)])
        await s.harness.source.script(k3.transferID, [.stage(k3Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(seed + 200) + [a, k1, k2, k3], s, visit: visit)
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
        var k3Waiter: Task<Result<AssetLocation, AssetError>, Never>?
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, k2) }
        } else if slots == 2 {
            await engine.awaitCondition { $0.state.jobs[k2.transferID]?.state == .queued }
        } else {
            // Visited first, the pump tried K2 under the throttle and answered its user at once.
            _ = await k2Waiter.value
        }
        if slots > 2 {
            let waiter = Task { await engine.awaitAsset(k3.identifier, lane: .userInitiated) }
            k3Waiter = waiter
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { FollowBarrier.joinWaits($0, k3) }
            } else {
                _ = await waiter.value
            }
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
        var k3Result: Result<AssetLocation, AssetError>?
        if let k3Waiter {
            k3Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: k3Waiter) }
        }
        let k1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: k1Waiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(cBytes.count), "A is served by C: \(aResult)")
        await FollowBarrier.finish(s, sync: sync)
        return PlacesAheadOutcome(k1: k1Result, k2: k2Result, k3: k3Result)
    }

    /// A place given behind the barrier under a throttle, after a place given before the throttle took the last slot, is
    /// not refused on its stamp's throttle: with two slots, visited first, K1 took the slot C left, so the pump never
    /// tried K2, which waited for a slot and started on the live gates once C completed and the throttle had ended. Both
    /// places stamped "slot free", K2 was refused on its stamp's throttle at the barrier-end pump and its caller answered
    /// `serverUnavailable(3)` (PROBE-C14C-STAMP-AHEAD).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a place behind an owed follow waits for the slot an earlier place took, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierWaitsForTheSlotAnEarlierPlaceTook(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.placesAhead(visit, slots: 2, seed: 1_320_102)
        #expect((try? outcome.k1.get())?.byteSize == 16, "K1 is served (visit-first): \(outcome.k1)")
        #expect((try? outcome.k2.get())?.byteSize == 20, "K2 waited for the slot K1 took and is served once the throttle ended (visit-first): \(outcome.k2)")
    }
}
