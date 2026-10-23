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
    @Test("R-CAR-6: an asset whose new content is downloading keeps serving its old bytes while hasAsset reports the new content missing", .timeLimit(.minutes(1)))
    func staleAssetServesItsOldBytes() async throws {
        let oldBytes = CompatFixture.bytes(10)
        let newBytes = CompatFixture.bytes(11)
        let posterBytes = CompatFixture.bytes(13)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.temple.icon", oldBytes)
        let republished = CompatFixture.asset(icon.identifier, newBytes)
        let poster = CompatFixture.asset("bo7.ri.easter.egg.temple.poster", posterBytes)
        let harness = try await LocalStoreShimTests.settled([(icon, oldBytes)])
        let store = CDNLocalStore(client: harness.client)
        await harness.serveManifest([republished, poster], etag: "v2")
        await harness.source.script(CompatFixture.transfer(republished), [.hold, .stage(newBytes)])
        await harness.source.script(CompatFixture.transfer(poster), [.stage(posterBytes)])
        let probe = EventProbe(stream: try await harness.client.subscribe())
        let client = harness.client
        let syncing = Task {
            await client.sync(.force)
        }
        // The poster commits while the republished icon's transfer is held: the run is mid-flight from here on.
        _ = await probe.next { event in
            if case .syncProgress(_, let progress) = event {
                return progress.completedCount >= 1
            }
            return false
        }

        let served = store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["png"])
        #expect(served?.deletingPathExtension().lastPathComponent == icon.checksum, "the old bytes, as in the prior art")
        #expect(harness.client.lookup(CompatFixture.id(icon))?.isStale == true)
        #expect(!store.hasAsset(republished))
        #expect(store.hasAsset(icon), "relative to the asset given, as the prior art's checksum comparison")
        #expect(store.missingOrStaleAssets(against: [republished, poster]) == [republished])

        await harness.source.release(CompatFixture.transfer(republished), with: .progress(received: 0, expected: nil))
        let outcome = await syncing.value
        guard case .complete = outcome else {
            Issue.record("the run should complete once the transfer is released: \(outcome)")
            return
        }
        let replaced = store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["png"])
        #expect(replaced?.deletingPathExtension().lastPathComponent == republished.checksum)
        #expect(store.hasAsset(republished))
        #expect(!store.hasAsset(icon))
        await probe.stop()
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: an asset whose new content failed to download transiently keeps its old bytes until a later sync fetches the new ones", .timeLimit(.minutes(1)))
    func transientReplacementFailureKeepsTheOldBytes() async throws {
        let oldBytes = CompatFixture.bytes(14)
        let newBytes = CompatFixture.bytes(15)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.altar.icon", oldBytes)
        let republished = CompatFixture.asset(icon.identifier, newBytes)
        let harness = try await LocalStoreShimTests.settled([(icon, oldBytes)])
        let store = CDNLocalStore(client: harness.client)
        await harness.serveManifest([republished], etag: "v2")
        // A transient failure ends this run's attempts (the harness allows one per run); the next run retries (`.nextRun`).
        await harness.source.script(
            CompatFixture.transfer(republished),
            [.fail(.transient(.serverError(httpStatus: 503), retryAfter: nil)), .stage(newBytes)]
        )

        let failed = await harness.client.sync(.force)
        guard case .completeWithFailures = failed else {
            Issue.record("setup: the re-download should fail: \(failed)")
            return
        }
        let served = store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["png"])
        #expect(served?.deletingPathExtension().lastPathComponent == icon.checksum, "the old bytes, as in the prior art")
        #expect(store.missingOrStaleAssets(against: [republished]) == [republished])

        await harness.source.scriptManifest([.notModified])
        let repaired = await harness.client.sync(.force)
        guard case .complete = repaired else {
            Issue.record("the next sync should fetch the new content: \(repaired)")
            return
        }
        #expect(store.hasAsset(republished))
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: an asset whose new content the origin reports missing is no longer served and not requested again until its entry changes", .timeLimit(.minutes(1)))
    func missingReplacementIsNotServed() async throws {
        let oldBytes = CompatFixture.bytes(16)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.crypt.icon", oldBytes)
        let republished = CompatFixture.asset(icon.identifier, CompatFixture.bytes(17))
        let harness = try await LocalStoreShimTests.settled([(icon, oldBytes)])
        let store = CDNLocalStore(client: harness.client)
        await harness.serveManifest([republished], etag: "v2")
        await harness.source.script(CompatFixture.transfer(republished), [.fail(.permanentMissing(httpStatus: 404))])

        let failed = await harness.client.sync(.force)
        guard case .completeWithFailures = failed else {
            Issue.record("setup: the re-download should fail: \(failed)")
            return
        }
        // Deviation from the prior art, which kept serving the old file: a 404 for the new content fails the record
        // until the manifest entry changes (ADR-032; ADR-053, L4-R16).
        #expect(store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["png"]) == nil)
        #expect(store.missingOrStaleAssets(against: [republished]) == [republished])
        let starts = await harness.source.starts.count
        await harness.source.scriptManifest([.notModified])
        _ = await harness.client.sync(.force)
        #expect(await harness.starts(after: starts).isEmpty, "the prior art re-requested it on every sync (D-16)")
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
