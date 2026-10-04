import Foundation
import Testing
import ZTronAssetKit

@Suite("Compatibility shims")
struct CompatibilityShimTests {
    @Test("R-CAR-6: CDNAsset keeps the prior-art initialiser, wire format and resolvedFileName")
    func cdnAssetWireFormat() throws {
        let json = Data(
            """
            [{"identifier":"bo7.ri.easter.egg.vehytherion.temple.icon","fileExtension":"heic",
              "remotePath":"media/0123456789abcdef/icon.heic","localPathComponents":["Black Ops 7","Rex Infernus"],
              "byteSize":1234,"checksum":"\(String(repeating: "ab", count: 32))","unknownField":true},
             {"identifier":"waw.ndu.title.card","fileExtension":"png","remotePath":"media/x/card.png",
              "localPathComponents":[],"localFileName":"title"}]
            """.utf8
        )
        let assets = try JSONDecoder().decode([CDNAsset].self, from: json)
        #expect(assets.count == 2)
        #expect(assets[0].resolvedFileName == "icon")
        #expect(assets[1].resolvedFileName == "title")
        #expect(assets[0].byteSize == 1234)
        let defaults = CDNAsset(identifier: "a.b", fileExtension: "png", remotePath: "p")
        #expect(defaults.localPathComponents.isEmpty && defaults.localFileName == nil && defaults.checksum == nil)
        let reencoded = try JSONDecoder().decode([CDNAsset].self, from: JSONEncoder().encode(assets))
        #expect(reencoded == assets)
    }

    @Test("R-CAR-6: a CDNAsset converts to a ManifestEntry and back without loss")
    func cdnAssetRoundTrip() {
        let asset = CDNAsset(
            identifier: "bo6.tm.control.room.icon",
            fileExtension: "jpg",
            remotePath: "media/abc/icon.jpg",
            localPathComponents: ["Black Ops 6"],
            localFileName: "icon",
            byteSize: 42,
            checksum: String(repeating: "0f", count: 32)
        )
        let entry = asset.manifestEntry
        #expect(entry.checksum?.hex == asset.checksum)
        #expect(entry.contentIdentity == .checksum(entry.checksum!))
        #expect(CDNAsset(entry: entry) == asset)
        let opaque = CDNAsset(identifier: "x", fileExtension: "png", remotePath: "media/x.png", checksum: "etag-123")
        #expect(opaque.manifestEntry.checksum == nil)
        #expect(opaque.manifestEntry.contentIdentity == .unverified(remotePath: "media/x.png"))
    }

    @Test("R-CAR-6: sync outcomes and refresh policies map to the prior-art cases")
    func progressAndPolicyMapping() {
        #expect(CDNSyncProgress(outcome: .notDue(lastSyncedAt: nil)) == .upToDate)
        #expect(CDNSyncProgress(outcome: .failed(.offline)) == .failed(reason: String(describing: SyncOutcome.failed(.offline))))
        let progress = SyncProgress(fraction: 0.5, completedCount: 2, totalCount: 4, bytesReceived: 10, bytesExpected: 20)
        #expect(CDNSyncProgress(progress: progress) == .syncing(fraction: 0.5, completedCount: 2, totalCount: 4))
        #expect(CDNRefreshPolicy.oncePerAppVersion.refreshPolicy == .oncePerAppVersion)
        #expect(CDNRefreshPolicy.everyLaunch.refreshPolicy == .everyLaunch)
        #expect(CDNRefreshPolicy.atMostEvery(60).refreshPolicy == .atMostEvery(60))
    }
}
