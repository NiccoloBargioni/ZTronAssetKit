// Target: Tests/ZTronAssetStorageTests/Core/ (passes on s3-base; fails under S3-CONF-06.mutant.diff)
import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// S3-CONF-06: a checksum change to bytes another asset already holds is adopted without a download, and the old
/// blob the record leaves is pruned (R-CLN-1, R-SYN-8): the release in `adoptKnownBlob` no test reached.
@Suite("S3 conformance probe: content change onto a live blob")
struct S3ConformanceDedupeOnChangeTests {
    @Test("R-CLN-1: a content change onto bytes another asset holds adopts them and prunes the old blob after grace", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func contentChangeOntoLiveBlob() async throws {
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
        // Adopted from the live blob: present, not stale, serving y, with nothing downloaded.
        let location = try #require(await harness.store.location(for: "a", extensions: [], recordingAccess: false))
        #expect(!location.isStale && harness.content(location.url) == y)
        await harness.settleDeletions()
        try await harness.store.flush(.durable)
        let oldBlob = harness.layout.blobURL(CoreFixture.key(x))
        #expect(!harness.exists(oldBlob), "the blob no record references any more is never reaped")
        let oldState = await harness.state.core.blobTable[CoreFixture.key(x)]
        #expect(oldState == nil, "the old blob is still \(String(describing: oldState))")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
        await harness.store.close()
    }
}
