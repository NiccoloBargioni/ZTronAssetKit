import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

@Suite("TMP throttle probe")
struct TmpThrottleProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("TMP: R-SYN-5 a later transfer 429 with a shorter Retry-After never shortens the origin's throttle", .timeLimit(.minutes(1)))
    func shorterTransfer429DoesNotShorten() async throws {
        let harness = EngineHarness.make()
        let pBytes = EngineFixture.bytes(1_401)
        let qBytes = EngineFixture.bytes(1_402)
        let p = EngineHarness.onDemand("p", pBytes)
        let q = EngineHarness.onDemand("q", qBytes)
        await harness.serveManifest([p, q])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(p.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(pBytes)])
        await harness.source.script(q.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(10))), .stage(qBytes)])
        let throttledAt = harness.time.monotonicNow()
        let group = try await engine.registerGroup(["p", "q"], lane: .prefetch).get()
        await engine.waitUntil { ($0.jobsByState[.blocked] ?? 0) == 2 }
        let origin = harness.source.originID
        await engine.awaitCondition { $0.state.heap.deadline(for: .throttle(origin)) != nil }
        try await harness.time.requireSleepers(atLeast: 1)
        #expect(harness.time.nextDeadline == throttledAt.adding(seconds: 60), "the 10 s 429 left the 60 s throttle in place")
        harness.time.advance(by: 10)
        #expect(await harness.source.starts.count == 2, "nothing restarts before the throttle's end")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}
