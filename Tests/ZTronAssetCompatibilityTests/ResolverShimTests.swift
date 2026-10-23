import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// R-CAR-6: `CDNAssetResolver` over a real client (RECON §5: a fetch-first resolver for unknown identifiers that never
/// reconciles; errors become `nil`) and its process-wide install point.
@Suite("Compatibility shims: resolver")
struct ResolverShimTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: resolveViaNetwork answers a stored asset with its local file and starts no transfer", .timeLimit(.minutes(1)))
    func storedAssetResolvesLocally() async throws {
        let iconBytes = CompatFixture.bytes(20)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.temple.icon", iconBytes)
        let harness = CompatHarness.make()
        await harness.serve([(icon, iconBytes)])
        try await harness.settleLaunch()
        let resolver = CDNAssetResolver(client: harness.client)
        let starts = await harness.source.starts.count

        let url = await resolver.resolveViaNetwork(identifier: icon.identifier, candidateExtensions: ["heic", "png"])

        let stored = await MainActor.run { harness.client.lookup(CompatFixture.id(icon))?.url }
        #expect(url != nil)
        #expect(url == stored)
        #expect(await harness.starts(after: starts).isEmpty)
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: resolveViaNetwork fetches the manifest first for an identifier it does not know and downloads only that asset", .timeLimit(.minutes(1)))
    func unknownIdentifierIsFetchedFirst() async throws {
        let iconBytes = CompatFixture.bytes(21)
        let cardBytes = CompatFixture.bytes(22)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.icon", iconBytes)
        let card = CompatFixture.asset("bo7.ri.easter.egg.card", cardBytes)
        let harness = CompatHarness.make()
        await harness.serve([(icon, iconBytes)])
        try await harness.settleLaunch()
        await harness.serveManifest([icon, card], etag: "v2")
        await harness.source.script(CompatFixture.transfer(card), [.stage(cardBytes)])
        let resolver = CDNAssetResolver(client: harness.client)
        let starts = await harness.source.starts.count
        let manifestRequests = await harness.source.manifestRequests.count

        let url = await resolver.resolveViaNetwork(identifier: card.identifier, candidateExtensions: ["png"])

        let stored = await MainActor.run { harness.client.lookup(CompatFixture.id(card)) }
        #expect(url != nil)
        #expect(url == stored?.url)
        #expect(stored?.byteSize == Int64(cardBytes.count))
        #expect(await harness.starts(after: starts) == [CompatFixture.transfer(card)])
        #expect(await harness.source.manifestRequests.count == manifestRequests + 1)
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: an on-demand resolve never prunes what the fresh manifest no longer lists", .timeLimit(.minutes(1)))
    func onDemandResolveNeverReconciles() async throws {
        let iconBytes = CompatFixture.bytes(23)
        let cardBytes = CompatFixture.bytes(24)
        let posterBytes = CompatFixture.bytes(25)
        let icon = CompatFixture.asset("bo6.tm.icon", iconBytes)
        let card = CompatFixture.asset("bo6.tm.card", cardBytes)
        let poster = CompatFixture.asset("bo6.tm.poster", posterBytes)
        let harness = CompatHarness.make()
        await harness.serve([(icon, iconBytes), (card, cardBytes)])
        try await harness.settleLaunch()
        await harness.serveManifest([icon, poster], etag: "v2")
        await harness.source.script(CompatFixture.transfer(poster), [.stage(posterBytes)])
        let resolver = CDNAssetResolver(client: harness.client)

        let url = await resolver.resolveViaNetwork(identifier: poster.identifier, candidateExtensions: ["png"])

        let (cardStored, iconStored) = await MainActor.run {
            (harness.client.lookup(CompatFixture.id(card)), harness.client.lookup(CompatFixture.id(icon)))
        }
        #expect(url != nil)
        #expect(cardStored != nil, "the prior art's resolver never reconciled: an unrelated asset is not deleted")
        #expect(iconStored != nil)
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: resolveViaNetwork answers nil for an identifier the catalog lacks, a failed download, a non-candidate extension and a shut-down client", .timeLimit(.minutes(1)))
    func failuresAnswerNil() async throws {
        let iconBytes = CompatFixture.bytes(26)
        let videoBytes = CompatFixture.bytes(27)
        let icon = CompatFixture.asset("bo7.ri.icon", iconBytes)
        let broken = CompatFixture.asset("bo7.ri.broken", CompatFixture.bytes(28))
        let video = CompatFixture.asset("bo7.ri.intro", videoBytes, ext: "mp4")
        let harness = CompatHarness.make()
        await harness.serve([(icon, iconBytes)])
        try await harness.settleLaunch()
        let catalog = CompatFixture.manifestData([icon, broken, video])
        await harness.source.scriptManifest(Array(repeating: .fetched(catalog, etag: CompatFixture.etag("v2")), count: 3))
        await harness.source.script(CompatFixture.transfer(broken), [.fail(.permanentMissing(httpStatus: 404))])
        await harness.source.script(CompatFixture.transfer(video), [.stage(videoBytes)])
        let resolver = CDNAssetResolver(client: harness.client)

        let lacking = await resolver.resolveViaNetwork(identifier: "bo7.ri.not.in.catalog", candidateExtensions: [])
        let failed = await resolver.resolveViaNetwork(identifier: broken.identifier, candidateExtensions: ["png"])
        let wrongExtension = await resolver.resolveViaNetwork(identifier: video.identifier, candidateExtensions: ["svg"])
        let anyExtension = await resolver.resolveViaNetwork(identifier: video.identifier, candidateExtensions: [])
        await harness.client.shutdown()
        let afterShutdown = await resolver.resolveViaNetwork(identifier: icon.identifier, candidateExtensions: ["png"])

        #expect(lacking == nil)
        #expect(failed == nil)
        #expect(wrongExtension == nil, "the prior art's candidate check")
        #expect(anyExtension?.pathExtension == "mp4", "no candidates: any extension")
        #expect(afterShutdown == nil)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: an install point's resolver is the first installed resolver's client, and nil before")
    func installPointResolver() {
        let harness = CompatHarness.make()
        let point = CDNInstallPoint()
        #expect(point.resolver == nil)
        let first = AssetClient(configuration: harness.configuration, environment: harness.environment)
        let second = AssetClient(configuration: harness.configuration, environment: harness.environment)

        let installed = point.installResolver(CDNAssetResolver(client: first)).client.identity
        let later = point.installResolver(CDNAssetResolver(client: second)).client.identity
        let current = point.resolver?.client.identity

        #expect(installed == first.identity)
        #expect(later == first.identity, "the first installation wins")
        #expect(current == first.identity)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: setting CDNAssetResolver.installed installs the value's client, a later value keeps the first client and nil changes nothing")
    func settingInstalled() {
        let harness = CompatHarness.make()
        let point = CDNInstallPoint()
        let first = AssetClient(configuration: harness.configuration, environment: harness.environment)
        let second = AssetClient(configuration: harness.configuration, environment: harness.environment)

        // The setter's body on a local point (the setter passes `.process`, which no test may fill, K-2): the prior
        // art's launch idiom `CDNAssetResolver.installed = CDNAssetResolver(…)`, then later assignments.
        CDNAssetResolver.setInstalled(nil, on: point)
        let afterNilOnEmpty = point.client?.identity
        CDNAssetResolver.setInstalled(CDNAssetResolver(client: first), on: point)
        let afterFirst = point.resolver?.client.identity
        CDNAssetResolver.setInstalled(CDNAssetResolver(client: second), on: point)
        let afterSecond = point.resolver?.client.identity
        CDNAssetResolver.setInstalled(nil, on: point)
        let afterNil = point.resolver?.client.identity

        #expect(afterNilOnEmpty == nil, "nil installs nothing")
        #expect(afterFirst == first.identity, "a value installs its client")
        #expect(afterSecond == first.identity, "the first installation wins")
        #expect(afterNil == first.identity, "nil uninstalls nothing")
    }
}
