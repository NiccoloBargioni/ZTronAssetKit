// Target: Tests/ZTronAssetKitTests/ (FAILS on s3-base)
import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync
import ZTronAssetTestSupport

/// S3-CONF-07: the prior art's network step (`CDNAssetResolver.resolveViaNetwork`, ZTronCarouselCore
/// `CDNAssetResolver.swift:46`) refuses an asset whose extension is not a candidate *before* downloading it; the
/// fallback chain's `fetch` resolves first and checks the extension afterwards (R-CAR-2 "identical observable
/// behaviour").
@Suite("S3 conformance probe: fallback chain network step")
struct S3ConformanceFallbackProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: fetch of an asset whose extension is not a candidate fails with notFound and downloads nothing", .timeLimit(.minutes(1)))
    func nonCandidateIsNeverDownloaded() async throws {
        let bytes = KitFixture.bytes(4_701)
        let entry = KitFixture.entry("clip", bytes, policy: .onDemand, ext: "mp4")
        let harness = KitHarness.make()
        await harness.serveManifest([entry])
        try await harness.startAndSettle()
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let chain = AssetFallbackChain(client: harness.client, bundle: FakeBundleLookup([:]))
        await #expect(throws: AssetError.notFound) {
            try await harness.withClock { () throws(AssetError) -> URL in
                try await chain.fetch("clip", kind: .image)
            }
        }
        let started = await harness.source.starts.filter { $0.id == entry.transferID }
        #expect(started.isEmpty, "an .mp4 was downloaded at \(started.map(\.priority)) for an image request")
        await harness.client.shutdown()
    }
}
