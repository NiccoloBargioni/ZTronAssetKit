import Foundation
import Testing
import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Builds the Apple tier's source over a `FakePackBackend` and the store's staging sink, as the facade's tier selection
/// does on iOS 26 (R-APL-5): the engine and the store are the real ones.
@available(macOS 26.0, iOS 26.0, *)
struct FakePackSourceFactory: RemoteSourceFactory {
    let backend: FakePackBackend

    func makeRemoteSource(configuration: RemoteConfiguration, staging: any StagingSink, log: LogRoute) async throws(AssetError) -> any RemoteSource {
        AppleHostedRemoteSource(configuration: AppleTierConfiguration(), backend: self.backend, staging: staging, log: log)
    }
}

/// The Apple tier end to end through the engine (R-APL-3, ADR-027; orchestrator ruling L4-R1): the pack's bytes are
/// adopted into the store, and the pack is released once the adoption is durable.
@Suite("Engine and the Apple tier")
struct EngineAppleTierTests {
    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-APL-3: an asset adopted from a FakePackBackend source is served from blobs/ after its pack is released", .timeLimit(.minutes(1)))
    func adoptedAssetServedFromBlobs() async throws {
        let catalogPack = try #require(PackID(rawValue: "ZTronCatalog"))
        let mediaPack = try #require(PackID(rawValue: "ZTronMedia"))
        let bytes = EngineFixture.bytes(4_801)
        let entry = ManifestEntry(
            identifier: "x",
            fileExtension: "png",
            remotePath: "ZTronMedia/x.png",
            localPathComponents: ["dir"],
            byteSize: Int64(bytes.count),
            checksum: ContentHash.sha256(of: bytes),
            tags: [],
            policy: .standard
        )
        // The catalog is installed with the app (the essential pack); the media pack is downloaded on demand.
        let backend = FakePackBackend(
            installed: [catalogPack: ["catalog.json": EngineFixture.manifestData([entry])]],
            remote: [mediaPack: ["x.png": bytes]]
        )
        let harness = EngineHarness.make(factory: FakePackSourceFactory(backend: backend))
        try await harness.start()
        let engine = harness.engine
        let report = try #require(await engine.sync(.force).completeReport)
        #expect(report.fetched == 1, "the run adopted x from its pack")
        // The run's finish reports the durable adoption, and the source releases the media pack (ADR-027).
        await backend.waitFor(.remove(mediaPack))
        #expect(!backend.installedPacks.contains(mediaPack), "the media pack is released")
        let location = try await engine.awaitAsset("x", lane: .userInitiated).get()
        let blobs = StoreLayout(base: EngineHarness.base).blobsDirectory.standardizedFileURL.path
        let served = location.url.standardizedFileURL.path
        #expect(served.hasPrefix(blobs + "/"), "served from the store's blobs/ directory: \(served)")
        #expect(!served.contains(mediaPack.rawValue), "never a pack location: \(served)")
        #expect(try harness.fileSystem.read(from: location.url, offset: 0, maxLength: bytes.count + 1) == bytes, "the blob holds the pack's bytes")
        #expect(backend.calls.filter { $0 == .ensure(mediaPack) }.count == 1, "the pack was downloaded once")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
