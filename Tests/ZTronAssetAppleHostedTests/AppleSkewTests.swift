import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

/// R-APL-4 / transport-2 T2-12 / ADR-032: a catalog and its media packs can be at different versions.
@Suite("Apple tier: version skew")
struct AppleSkewTests {
    @available(macOS 26.0, *)
    @Test("R-APL-4: a catalog and pack version skew is transient and never quarantines the asset", .timeLimit(.minutes(1)))
    func checksumSkewIsTransient() async throws {
        let catalogVersion = PackAsset("ZTronMedia/images/a.heic", "pixels v2")
        let packVersion = PackAsset("ZTronMedia/images/a.heic", "pixels v1")
        let fixture = AppleTierFixture(installed: [Packs.media: [packVersion.path: packVersion.bytes]])
        let updates = await collect(await fixture.source.transfer(catalogVersion.request()))

        #expect(updates == [.failed(.transient(.sourceVersionSkew, retryAfter: nil))])
        #expect(updates.first.flatMap(Self.failureClass) == .transient, "transient: backed off and retried, never integrity")
        #expect(fixture.staging.contents.isEmpty, "the mismatching copy is discarded")
        await fixture.source.state.settleUpdateCheck()
        #expect(fixture.backend.calls.filter { $0 == .checkForUpdates }.count == 1, "one best-effort update check")

        fixture.backend.install(Packs.media, files: [catalogVersion.path: catalogVersion.bytes])
        let retried = await collect(await fixture.source.transfer(catalogVersion.request(sequence: 2)))
        #expect(retried.last.map(AppleTransferTests.isStaged) == true, "the pack update heals the asset: \(retried)")
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a pack file of another size than the catalog's is skew, stopped at the catalog size", .timeLimit(.minutes(1)))
    func sizeSkewIsTransient() async throws {
        let asset = PackAsset("ZTronMedia/images/a.heic", "0123456789")
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.media: [asset.path: Data("0123456789abcdef".utf8)]], staging: gated)
        let larger = await collect(await fixture.source.transfer(asset.request()))
        fixture.backend.install(Packs.media, files: [asset.path: Data("01234".utf8)])
        let smaller = await collect(await fixture.source.transfer(asset.request(sequence: 2)))

        #expect(larger == [.failed(.transient(.sourceVersionSkew, retryAfter: nil))])
        #expect(smaller == [.failed(.transient(.sourceVersionSkew, retryAfter: nil))])
        #expect(gated.writeLimits == [10, 10], "each copy is capped at the catalog's 10 bytes, not at the 1 MiB maxBytes")
        #expect(
            fixture.tap.lines.contains { $0.category == .apple && $0.message.contains("larger than the catalog says") },
            "the 16-byte file was stopped by the cap, not copied whole and compared afterwards"
        )
        #expect(gated.base.contents.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a file missing from its pack after the pack was made available is skew", .timeLimit(.minutes(1)))
    func missingFileAfterEnsureIsSkew() async throws {
        let asset = PackAsset("ZTronMedia/images/new.heic", "added in catalog v2")
        let fixture = AppleTierFixture(
            installed: [Packs.media: ["images/old.heic": Data("old".utf8)]],
            remote: [Packs.media: ["images/old.heic": Data("old".utf8)]]
        )
        let updates = await collect(await fixture.source.transfer(asset.request()))
        #expect(updates == [.failed(.transient(.sourceVersionSkew, retryAfter: nil))])
        #expect(fixture.backend.calls.filter { $0 == .ensure(Packs.media) }.count == 1)
        await fixture.source.state.settleUpdateCheck()
        #expect(fixture.backend.calls.contains(.checkForUpdates))
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: an asset larger than the transfer cap is oversize, not skew", .timeLimit(.minutes(1)))
    func overCapIsOversize() async throws {
        let asset = PackAsset("ZTronMedia/videos/huge.mp4", String(repeating: "x", count: 64))
        let fixture = AppleTierFixture(installed: [Packs.media: [asset.path: asset.bytes]])
        let updates = await collect(await fixture.source.transfer(asset.request(maxBytes: 16)))
        #expect(updates == [.failed(.integrity(.oversize(announced: 64, limit: 16)))])
        #expect(fixture.staging.contents.isEmpty)
        await fixture.source.invalidate()
    }

    static func failureClass(_ update: TransferUpdate) -> FailureClass? {
        guard case .failed(let error) = update else {
            return nil
        }
        return error.failureClass
    }
}
