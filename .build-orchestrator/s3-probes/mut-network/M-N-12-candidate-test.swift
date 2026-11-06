import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

@Suite("TMP promotion probe")
struct TmpPromotionProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("TMP: a queued bulk job promoted to prefetch starts before earlier-queued bulk jobs", .timeLimit(.minutes(1)))
    func queuedPrefetchPromotion() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let a = EngineFixture.entry("a", EngineFixture.bytes(31))
        let b = EngineFixture.entry("b", EngineFixture.bytes(32))
        let c = EngineFixture.entry("c", EngineFixture.bytes(33))
        await harness.serveManifest([a, b, c])
        await harness.source.script(a.transferID, [.hold, .stage(EngineFixture.bytes(31))])
        await harness.source.script(b.transferID, [.stage(EngineFixture.bytes(32))])
        await harness.source.script(c.transferID, [.stage(EngineFixture.bytes(33))])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(a.transferID)
        let waiter = Task { await engine.awaitAsset("c", lane: .prefetch) }
        await engine.waitUntil { $0.waiters == 1 }
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        _ = await waiter.value
        _ = await run.value
        let starts = await harness.source.starts.map(\.id)
        print("TMPPROBE prefetch starts:", starts.map(\.rawValue))
        #expect(starts.prefix(2).map { $0 } == [a.transferID, c.transferID], "c was promoted to prefetch and starts before b")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("TMP: a queued bulk job promoted to userInitiated starts before earlier-queued bulk jobs", .timeLimit(.minutes(1)))
    func queuedUserPromotion() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let a = EngineFixture.entry("a", EngineFixture.bytes(31))
        let b = EngineFixture.entry("b", EngineFixture.bytes(32))
        let c = EngineFixture.entry("c", EngineFixture.bytes(33))
        await harness.serveManifest([a, b, c])
        await harness.source.script(a.transferID, [.hold, .stage(EngineFixture.bytes(31))])
        await harness.source.script(b.transferID, [.stage(EngineFixture.bytes(32))])
        await harness.source.script(c.transferID, [.stage(EngineFixture.bytes(33))])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(a.transferID)
        let waiter = Task { await engine.awaitAsset("c", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 1 }
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        _ = await waiter.value
        _ = await run.value
        let starts = await harness.source.starts.map(\.id)
        print("TMPPROBE user starts:", starts.map(\.rawValue))
        #expect(starts.prefix(2).map { $0 } == [a.transferID, c.transferID], "c was promoted and starts before b")
        await engine.shutdown()
    }
}
