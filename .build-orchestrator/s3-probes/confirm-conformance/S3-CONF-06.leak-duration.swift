// Confirmer's probe (S3-CONF-06 severity): how long the old blob survives when adoptKnownBlob skips the release.
import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

@Suite("S3 confirm: S3-CONF-06 leak duration")
struct S3ConfirmLeakDurationTests {
    @Test("S3 confirm: the old blob after a content change onto a live blob, in the lifetime and after a relaunch", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func leakDuration() async throws {
        let harness = CoreHarness.make()
        let x = CoreFixture.bytes(4_601, count: 400)
        let y = CoreFixture.bytes(4_602, count: 380)
        let v1 = [CoreFixture.entry("a", x), CoreFixture.entry("z", y)]
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(v1, etagSeed: "v1"), etag: nil, eviction: nil)
        try await harness.publish(x, [v1[0]], sequence: 1)
        try await harness.publish(y, [v1[1]], sequence: 2)
        try await harness.store.flush(.durable)
        let v2 = [CoreFixture.entry("a", y), CoreFixture.entry("z", y)]
        _ = try await harness.store.apply(CoreFixture.manifest(v2, etagSeed: "v2"), etag: nil, eviction: nil)
        let oldKey = CoreFixture.key(x)
        let oldBlob = harness.layout.blobURL(oldKey)
        await harness.settleDeletions()
        harness.time.advance(by: harness.configuration.policy.orphanGrace + 1)
        _ = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        await harness.settleDeletions()
        let inLifetime = harness.exists(oldBlob)
        print("S3-CONFIRM-06 in lifetime after reap and orphan GC: old blob on disk = \(inLifetime), table = \(String(describing: await harness.state.core.blobTable[oldKey]))")
        try await harness.store.flush(.durable)
        await harness.store.close()
        let reopened = CoreHarness.make(disk: harness.fileSystem.survivingDisk(), time: harness.time)
        _ = try await reopened.store.open()
        let afterOpen = await reopened.state.core.blobTable[oldKey]
        let orphan = await reopened.state.core.orphans[oldKey]
        print("S3-CONFIRM-06 after relaunch: table = \(String(describing: afterOpen)), orphan = \(String(describing: orphan))")
        reopened.time.advance(by: reopened.configuration.policy.orphanGrace + 1)
        _ = try await reopened.store.collectGarbage(until: reopened.time.monotonicNow().adding(seconds: 60))
        await reopened.settleDeletions()
        let afterGC = reopened.exists(reopened.layout.blobURL(oldKey))
        print("S3-CONFIRM-06 after relaunch and orphan GC: old blob on disk = \(afterGC)")
        #expect(!afterGC)
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
        await reopened.store.close()
    }
}
