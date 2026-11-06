import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 12, requirements lens). Never committed.
///
/// Each runs in both orders (`LaneDropVisit`); every expectation is the visit-first outcome (S3-R11 item 3).
@Suite("VerifyC12ReqsProbes", .serialized)
struct VerifyC12ReqsProbes {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// PROBE-C12R-FOLLOWED-LANE (residual R-H, S3-R15 item 2): C (1 MB, zz-b) runs for P, a prefetch waiter; Y (1 MB,
    /// zz-u) runs for U, a user waiter. v3 moves zz-u onto C's content, so the follow owes Y's visit, which moves U's
    /// interest onto C (C's lane becomes the user lane). C then gets a 429 without Retry-After. Visited first, C was user
    /// work when the 429 arrived: the origin's throttle is the interactive policy's first backoff. `followedLane(C)` counts
    /// only C's own interests (P), so behind the barrier the throttle is the background policy's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C12R-FOLLOWED-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func followedLaneOmitsMovedInterest(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 999_702)
        let engine = s.engine
        let cBytes = Data(repeating: 0xC7, count: 1_000_000)
        let yBytes = Data(repeating: 0xC8, count: 1_000_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let u = EngineHarness.onDemand("zz-u", yBytes)
        try #require(b.transferID != u.transferID, "setup: C and Y differ")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(731_000) + [b, u], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: nil)), .stage(cBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(yBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        }
        let uMoved = EngineHarness.onDemand("zz-u", cBytes)
        try #require(uMoved.transferID == b.transferID, "setup: v3's zz-u is C's content")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(831_000) + [b, uMoved], s, visit: visit)
        let before = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[b.transferID]?.state, lane: e.state.jobs[b.transferID]?.lane, y: e.state.jobs[u.transferID]?.state)
        }
        print("PROBE-C12R-FOLLOWED-LANE \(visit) before the 429: \(before)")
        if visit == .sweepFollowsFirst {
            #expect(before.owed && before.c == .downloading && before.lane == .prefetch, "setup: C runs on the prefetch lane and Y's visit is owed: \(before)")
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let atArrival = await engine.readForTests { e -> Double? in
            e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow())
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let figures = await engine.readForTests { e -> (throttle: Double?, background: Double?, interactive: Double?, lane: AssetPriority?) in
            guard let origin = e.state.remote?.originID else {
                return (nil, nil, nil, nil)
            }
            let key = StableHash.fnv1a64(origin)
            return (
                e.state.throttles[origin]?.seconds(since: e.environment.time.monotonicNow()),
                Backoff.delay(attempt: 1, retryAfter: nil, policy: e.tuning.retry, seed: e.environment.random.seed, key: key),
                Backoff.delay(attempt: 1, retryAfter: nil, policy: e.tuning.interactiveRetry, seed: e.environment.random.seed, key: key),
                e.state.jobs[b.transferID]?.lane
            )
        }
        print("PROBE-C12R-FOLLOWED-LANE \(visit) atArrival=\(String(describing: atArrival)) after drain=\(figures)")
        if let throttle = atArrival, let interactive = figures.interactive {
            #expect(abs(throttle - interactive) < 0.000_001, "PROBE-C12R-FOLLOWED-LANE: right after the 429 the origin is throttled for the backoff of C's user lane (visit-first): \(throttle) against \(figures)")
        } else {
            Issue.record("the origin is throttled right after the 429: \(String(describing: atArrival)) against \(figures)")
        }
        if let throttle = figures.throttle, let interactive = figures.interactive {
            #expect(abs(throttle - interactive) < 0.000_001, "PROBE-C12R-FOLLOWED-LANE: after the drain the throttle is the user lane's backoff (visit-first): \(figures)")
        }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C12R-FOLLOWED-LANE \(visit) u=\(uResult) p=\(pResult)")
        #expect((try? uResult.get())?.byteSize == Int64(cBytes.count), "U is served from C's content: \(uResult)")
        #expect((try? pResult.get())?.byteSize == Int64(cBytes.count), "P is served by C's retry: \(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
