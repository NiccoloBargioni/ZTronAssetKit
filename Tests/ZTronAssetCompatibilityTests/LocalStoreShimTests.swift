import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// R-CAR-6: `CDNLocalStore`'s lookups over a real client (RECON §5: `existingLocalURL` is offline and tries the
/// candidate extensions; `hasAsset` is checksum-aware; `missingOrStaleAssets` is the availability guarantee).
@Suite("Compatibility shims: local store")
struct LocalStoreShimTests {
    /// A client whose launch run stored `assets`.
    @available(macOS 15.0, iOS 18.0, *)
    static func settled(_ assets: [(CDNAsset, Data)]) async throws -> CompatHarness {
        let harness = CompatHarness.make()
        await harness.serve(assets)
        try await harness.settleLaunch()
        return harness
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: existingLocalURL answers from the client's snapshot with no file-system call on the main thread and no network request", .timeLimit(.minutes(1)))
    func existingLocalURLIsOffline() async throws {
        let iconBytes = CompatFixture.bytes(1)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.temple.icon", iconBytes)
        let harness = try await LocalStoreShimTests.settled([(icon, iconBytes)])
        let store = CDNLocalStore(client: harness.client)
        let manifestRequests = await harness.source.manifestRequests.count
        let mainThreadCalls = harness.fileSystem.mainThreadCalls

        let found = store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["heic", "png", "jpg", "jpeg"])
        let unknown = store.existingLocalURL(identifier: "bo7.ri.easter.egg.unknown", candidateExtensions: ["png"])

        #expect(found != nil)
        #expect(found == harness.client.lookup(CompatFixture.id(icon))?.url)
        #expect(found?.pathExtension == "png")
        #expect(found?.deletingPathExtension().lastPathComponent == icon.checksum, "the content-addressed blob")
        #expect(unknown == nil)
        #expect(harness.fileSystem.mainThreadCalls == mainThreadCalls, "no file-system call on the main thread")
        #expect(await harness.source.manifestRequests.count == manifestRequests, "no manifest request")
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: existingLocalURL matches the candidate extensions case-insensitively and answers nil for an asset in none of them", .timeLimit(.minutes(1)))
    func existingLocalURLTriesTheCandidates() async throws {
        let cardBytes = CompatFixture.bytes(2)
        let card = CompatFixture.asset("waw.ndu.title.card", cardBytes, directories: [])
        let harness = try await LocalStoreShimTests.settled([(card, cardBytes)])
        let store = CDNLocalStore(client: harness.client)
        let stored = harness.client.lookup(CompatFixture.id(card))?.url

        #expect(stored != nil)
        #expect(store.existingLocalURL(identifier: card.identifier, candidateExtensions: ["HEIC", "PNG"]) == stored)
        #expect(store.existingLocalURL(identifier: card.identifier, candidateExtensions: []) == stored, "no candidates: any extension")
        #expect(
            store.existingLocalURL(identifier: card.identifier, candidateExtensions: ["heic", "jpg"]) == nil,
            "ADR-037: a manifest-known asset outside the candidates is not handed out"
        )
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: hasAsset is true for stored content and false for an absent asset, another extension or another checksum", .timeLimit(.minutes(1)))
    func hasAssetComparesChecksums() async throws {
        let iconBytes = CompatFixture.bytes(3)
        let icon = CompatFixture.asset("bo6.tm.control.room.icon", iconBytes)
        let harness = try await LocalStoreShimTests.settled([(icon, iconBytes)])
        let store = CDNLocalStore(client: harness.client)
        let republished = CDNAsset(
            identifier: icon.identifier,
            fileExtension: icon.fileExtension,
            remotePath: icon.remotePath,
            localPathComponents: icon.localPathComponents,
            byteSize: icon.byteSize,
            checksum: ContentHash.sha256(of: CompatFixture.bytes(4)).hex.uppercased()
        )
        let opaque = CDNAsset(identifier: icon.identifier, fileExtension: "png", remotePath: icon.remotePath, checksum: "\"etag-123\"")
        let unchecked = CDNAsset(identifier: icon.identifier, fileExtension: "png", remotePath: icon.remotePath)
        let otherExtension = CDNAsset(identifier: icon.identifier, fileExtension: "jpg", remotePath: icon.remotePath, checksum: icon.checksum)
        let absent = CompatFixture.asset("bo6.tm.control.room.map", CompatFixture.bytes(5))
        let uppercased = CDNAsset(identifier: icon.identifier, fileExtension: "png", remotePath: icon.remotePath, checksum: icon.checksum?.uppercased())

        #expect(store.hasAsset(icon))
        #expect(store.hasAsset(uppercased), "hex digits compare case-insensitively")
        #expect(!store.hasAsset(republished), "the CDN publishes other bytes under the same identifier")
        #expect(store.hasAsset(opaque), "an ETag-style checksum cannot be compared: trusted on presence (R-MAN-5)")
        #expect(store.hasAsset(unchecked))
        #expect(!store.hasAsset(otherExtension))
        #expect(!store.hasAsset(absent))
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: missingOrStaleAssets lists absent and republished assets in manifest order, and isFullyAvailable is true only without any", .timeLimit(.minutes(1)))
    func missingOrStaleAssetsIsTheAvailabilityGuarantee() async throws {
        let iconBytes = CompatFixture.bytes(6)
        let cardBytes = CompatFixture.bytes(7)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.icon", iconBytes)
        let card = CompatFixture.asset("bo7.ri.easter.egg.card", cardBytes)
        let harness = try await LocalStoreShimTests.settled([(icon, iconBytes), (card, cardBytes)])
        let store = CDNLocalStore(client: harness.client)
        let republishedCard = CompatFixture.asset(card.identifier, CompatFixture.bytes(8))
        let absent = CompatFixture.asset("bo7.ri.easter.egg.poster", CompatFixture.bytes(9))

        #expect(store.missingOrStaleAssets(against: [absent, icon, republishedCard]) == [absent, republishedCard])
        #expect(store.missingOrStaleAssets(against: [icon, card]).isEmpty)
        #expect(store.isFullyAvailable(against: [icon, card]))
        #expect(!store.isFullyAvailable(against: [icon, absent]))
        #expect(store.isFullyAvailable(against: []))
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: an asset whose new content failed to download keeps serving its old bytes while hasAsset reports the new content missing", .timeLimit(.minutes(1)))
    func staleAssetServesItsOldBytes() async throws {
        let oldBytes = CompatFixture.bytes(10)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.temple.icon", oldBytes)
        let harness = try await LocalStoreShimTests.settled([(icon, oldBytes)])
        let store = CDNLocalStore(client: harness.client)
        let republished = CompatFixture.asset(icon.identifier, CompatFixture.bytes(11))
        await harness.serveManifest([republished], etag: "v2")
        await harness.source.script(CompatFixture.transfer(republished), [.fail(.permanentMissing(httpStatus: 404))])

        let outcome = await harness.client.sync(.force)
        guard case .completeWithFailures = outcome else {
            Issue.record("setup: the re-download should fail: \(outcome)")
            return
        }
        let served = store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["png"])
        #expect(served?.deletingPathExtension().lastPathComponent == icon.checksum, "the old bytes, as in the prior art")
        #expect(harness.client.lookup(CompatFixture.id(icon))?.isStale == true)
        #expect(!store.hasAsset(republished))
        #expect(store.hasAsset(icon), "relative to the asset given, as the prior art's checksum comparison")
        #expect(store.missingOrStaleAssets(against: [republished]) == [republished])
        await harness.client.shutdown()
    }

    @MainActor
    @Test("R-CAR-6: CDNLocalStore.shared and CDNAssetResolver.installed follow the process install point, which no test fills")
    func sharedStoreFollowsTheProcessInstallPoint() {
        #expect(CDNLocalStore.shared.installPoint === CDNInstallPoint.process)
        #expect(CDNLocalStore.shared.client == nil)
        #expect(CDNLocalStore.shared.existingLocalURL(identifier: "bo7.ri.icon", candidateExtensions: []) == nil)
        #expect(!CDNLocalStore.shared.hasAsset(CDNAsset(identifier: "bo7.ri.icon", fileExtension: "png", remotePath: "media/icon.png")))
        #expect(CDNAssetResolver.installed == nil)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a store bound to an install point answers for the client installed there later", .timeLimit(.minutes(1)))
    func storeFollowsItsInstallPoint() async throws {
        let iconBytes = CompatFixture.bytes(12)
        let icon = CompatFixture.asset("bo4.ix.icon", iconBytes)
        let harness = try await LocalStoreShimTests.settled([(icon, iconBytes)])
        let point = CDNInstallPoint()
        let store = CDNLocalStore(installPoint: point)
        #expect(store.client == nil)
        #expect(store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["png"]) == nil, "before installation")

        point.install(harness.client)
        let bound = store.client?.identity
        #expect(bound == harness.client.identity)
        #expect(store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["png"]) == harness.client.lookup(CompatFixture.id(icon))?.url)
        #expect(store.hasAsset(icon))
        await harness.client.shutdown()
    }
}
