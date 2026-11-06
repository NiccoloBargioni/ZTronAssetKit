import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// S3-SECU-01: `availability(of:)` sums the manifest's declared `byteSize` of missing entries with a plain `+=`
/// (`AssetStore+Reads.swift`), while every other figure derived from manifest sizes saturates (PlanBuilder.adding,
/// InFlightBytes, addingSaturating). Under `maxAssetBytes = Int64.max` ("unlimited", a configuration the transport
/// explicitly supports, ArithmeticSafetyTests) two entries a hostile manifest declares at 2^62 bytes each overflow
/// the sum and trap the process.
@Suite("S3 security probes: storage")
struct S3SecurityStorageProbeTests {
    @Test("R-MAN-3: availability never traps when the declared sizes of missing entries sum past Int64.max", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func availabilitySaturatesBytesMissing() async throws {
        let limits = ManifestLimits(maxAssetBytes: .max)
        let half = Int64(1) << 62
        let json = """
            [{"identifier":"a","fileExtension":"png","remotePath":"media/a.png","localPathComponents":[],"byteSize":\(half)},
             {"identifier":"b","fileExtension":"png","remotePath":"media/b.png","localPathComponents":[],"byteSize":\(half)}]
            """
        let manifest = try ManifestDecoder.decode(Data(json.utf8), options: ManifestDecodingOptions(limits: limits))
        #expect(manifest.entries.count == 2 && manifest.quarantinedCount == 0, "the decoder accepts both entries")
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(limits: limits))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        let report = await harness.store.availability(of: .all)
        #expect(report.missing == 2)
        #expect(report.bytesMissing == .max, "the sum saturates as every other manifest-size figure does")
    }
}
