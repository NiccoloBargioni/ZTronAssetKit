import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

// The prior art's deprecated API, reached through protocols. Swift Testing rejects a deprecated `@Test` function and
// `verify.sh` builds with warnings as errors, so a direct call would not build; a call through a protocol requirement
// that the deprecated member satisfies is the same call without the warning. Each conformance is also a compile-time
// proof that the prior-art signature still exists.

/// `CDNLocalStore`'s deprecated members.
protocol PriorArtLocalStore: AnyObject {
    init(baseDirectory: URL?, computeChecksum: @escaping @Sendable (URL) throws -> String)
    static func sha256Hex(of fileURL: URL) throws -> String
    static func mechanicalPathComponents(for identifier: String) -> [String]
    @MainActor func cacheManifest(_ assets: [CDNAsset])
    @MainActor func cachedAsset(forIdentifier identifier: String) -> CDNAsset?
    @MainActor func localURL(for asset: CDNAsset) -> URL
    func store(temporaryURL: URL, for asset: CDNAsset) throws
    @MainActor func reconcile(newManifest: [CDNAsset]) -> CDNReconciliationSummary
}

extension CDNLocalStore: PriorArtLocalStore {}

/// `CDNAssetResolver`'s deprecated initialiser.
protocol PriorArtResolver {
    init(cdn: any CDNProviding, localStore: CDNLocalStore)
}

extension CDNAssetResolver: PriorArtResolver {}

/// `CDNSyncCoordinator`'s deprecated initialiser: a compile-time proof only, since calling it would construct
/// `UserDefaults`, which tests must not touch (its behaviour is `init(sharingClientOf:cdn:)`'s, tested below).
protocol PriorArtCoordinator {
    @MainActor init(
        cdn: any CDNProviding,
        localStore: CDNLocalStore,
        defaults: UserDefaults,
        appVersionProvider: @escaping @Sendable () -> String
    )
}

extension CDNSyncCoordinator: PriorArtCoordinator {}

/// The prior-art call sites, through the protocols.
enum PriorArt {
    static func localStore<Store: PriorArtLocalStore>(
        _ type: Store.Type,
        baseDirectory: URL?,
        computeChecksum: @escaping @Sendable (URL) throws -> String = { _ in "" }
    ) -> Store {
        Store(baseDirectory: baseDirectory, computeChecksum: computeChecksum)
    }

    static func sha256Hex<Store: PriorArtLocalStore>(_ type: Store.Type, of url: URL) throws -> String {
        try Store.sha256Hex(of: url)
    }

    static func mechanicalPathComponents<Store: PriorArtLocalStore>(_ type: Store.Type, for identifier: String) -> [String] {
        Store.mechanicalPathComponents(for: identifier)
    }

    static func resolver<Resolver: PriorArtResolver>(_ type: Resolver.Type, cdn: any CDNProviding, localStore: CDNLocalStore) -> Resolver {
        Resolver(cdn: cdn, localStore: localStore)
    }
}

/// R-CAR-6: the prior art's deprecated API keeps compiling and keeps its observable results where the client allows
/// (RECON §5: the legacy path layout; `resolvedFileName`; the shared store behind the resolver and the coordinator).
@Suite("Compatibility shims: deprecated prior-art API")
struct LegacyAPIShimTests {
    @MainActor
    @Test("R-CAR-6: the prior-art local store initialiser keeps the prior art's layout for an asset the client does not hold")
    func legacyStoreKeepsThePriorArtLayout() throws {
        let base = URL(fileURLWithPath: "/legacy/CDNAssets", isDirectory: true)
        let store = PriorArt.localStore(CDNLocalStore.self, baseDirectory: base)
        let pretty = CDNAsset(
            identifier: "bo7.ri.easter.egg.vehytherion.temple.icon",
            fileExtension: "heic",
            remotePath: "media/0123/icon.heic",
            localPathComponents: ["Black Ops 7", "Rex Infernus", "Vehytherion Temple"]
        )
        let mechanical = CDNAsset(identifier: "waw.ndu.title.card", fileExtension: "png", remotePath: "media/x/card.png", localFileName: "title")

        #expect(store.client == nil, "no client until a prior-art provider needs one")
        #expect(store.installPoint !== CDNInstallPoint.process)
        #expect(store.installPoint.configuration.clientConfiguration.location == .custom(base))
        #expect(store.installPoint.configuration.clientConfiguration.legacy.root == base)
        #expect(
            (store as any PriorArtLocalStore).localURL(for: pretty).path
                == "/legacy/CDNAssets/Black Ops 7/Rex Infernus/Vehytherion Temple/icon.heic"
        )
        #expect((store as any PriorArtLocalStore).localURL(for: mechanical).path == "/legacy/CDNAssets/waw/ndu/title/title.png")

        let defaultStore = PriorArt.localStore(CDNLocalStore.self, baseDirectory: nil)
        #expect(defaultStore.installPoint === CDNInstallPoint.process, "a second default store shares the process point")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: localURL is the stored blob for an asset the client holds", .timeLimit(.minutes(1)))
    func localURLIsTheStoredBlob() async throws {
        let iconBytes = CompatFixture.bytes(70)
        let icon = CompatFixture.asset("bo6.tm.icon", iconBytes)
        let harness = CompatHarness.make()
        await harness.serve([(icon, iconBytes)])
        try await harness.settleLaunch()
        let store: any PriorArtLocalStore = CDNLocalStore(client: harness.client)

        #expect(store.localURL(for: icon) == harness.client.lookup(CompatFixture.id(icon))?.url)
        await harness.client.shutdown()
    }

    @Test("R-CAR-6: mechanicalPathComponents and sha256Hex keep the prior art's results")
    func pathAndChecksumHelpers() throws {
        let directory = try CompatFixture.directory("sha256Hex")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let bytes = CompatFixture.bytes(71, count: 4_096)
        let file = directory.appendingPathComponent("payload.bin")
        try bytes.write(to: file)

        #expect(PriorArt.mechanicalPathComponents(CDNLocalStore.self, for: "bo7.ri.easter.egg.icon") == ["bo7", "ri", "easter", "egg", "icon"])
        #expect(PriorArt.mechanicalPathComponents(CDNLocalStore.self, for: "plain") == ["plain"])
        #expect(try PriorArt.sha256Hex(CDNLocalStore.self, of: file) == ContentHash.sha256(of: bytes).hex)
        #expect(throws: (any Error).self) {
            try PriorArt.sha256Hex(CDNLocalStore.self, of: directory.appendingPathComponent("missing.bin"))
        }
    }

    @MainActor
    @Test("R-CAR-6: cacheManifest keeps the first entry of a duplicated identifier instead of trapping, and cachedAsset reads it back")
    func cacheManifestKeepsTheFirstEntry() {
        let store: any PriorArtLocalStore = CDNLocalStore(installPoint: CDNInstallPoint())
        let icon = CDNAsset(identifier: "bo7.ri.icon", fileExtension: "png", remotePath: "media/a/icon.png")
        let duplicate = CDNAsset(identifier: "bo7.ri.icon", fileExtension: "heic", remotePath: "media/b/icon.heic")
        let card = CDNAsset(identifier: "bo7.ri.card", fileExtension: "png", remotePath: "media/c/card.png")

        #expect(store.cachedAsset(forIdentifier: icon.identifier) == nil)
        store.cacheManifest([icon, duplicate, card])
        #expect(store.cachedAsset(forIdentifier: icon.identifier) == icon, "D-13: a duplicate no longer crashes the app")
        #expect(store.cachedAsset(forIdentifier: card.identifier) == card)
        store.cacheManifest([card])
        #expect(store.cachedAsset(forIdentifier: icon.identifier) == nil, "a new manifest replaces the cached one")
    }

    @MainActor
    @Test("R-CAR-6: reconcile records the manifest and reports nothing moved, because the client reconciles inside sync")
    func reconcileRecordsOnly() {
        let store: any PriorArtLocalStore = CDNLocalStore(installPoint: CDNInstallPoint())
        let icon = CDNAsset(identifier: "bo7.ri.icon", fileExtension: "png", remotePath: "media/a/icon.png")

        let summary = store.reconcile(newManifest: [icon])

        #expect(summary == CDNReconciliationSummary())
        #expect(store.cachedAsset(forIdentifier: icon.identifier) == icon)
    }

    @Test("R-CAR-6: store(temporaryURL:for:) throws storeIsOwnedByTheClient and leaves the file where it is")
    func storeRefusesExternalFiles() throws {
        let directory = try CompatFixture.directory("store-refusal")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("download.tmp")
        try CompatFixture.bytes(72).write(to: file)
        let store: any PriorArtLocalStore = CDNLocalStore(installPoint: CDNInstallPoint())
        let asset = CDNAsset(identifier: "bo7.ri.icon", fileExtension: "png", remotePath: "media/a/icon.png")

        #expect(throws: CDNShimError.storeIsOwnedByTheClient) {
            try store.store(temporaryURL: file, for: asset)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: prior-art resolvers and coordinators on one store share the one client its install point builds from the first provider", .timeLimit(.minutes(1)))
    func legacyInitialisersShareOneClient() async throws {
        let iconBytes = CompatFixture.bytes(73)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.icon", iconBytes)
        let fakes = CompatHarness.make()
        await fakes.serve([(icon, iconBytes)])
        let base = try #require(URL(string: "https://d111111abcdef8.cloudfront.net/"))
        let point = CDNInstallPoint(configuration: CDNConfiguration(clientConfiguration: fakes.configuration), environment: fakes.environment)
        let store = CDNLocalStore(installPoint: point)
        let provider = StaticManifestCDNProvider(baseURL: base)

        let resolver = PriorArt.resolver(CDNAssetResolver.self, cdn: provider, localStore: store)
        let other = PriorArt.resolver(CDNAssetResolver.self, cdn: ScriptedCDNProvider(manifest: .success([])), localStore: store)
        #expect(point.client == nil, "nothing is built before the first use")
        let built = resolver.client.identity
        let installed = try #require(point.client)
        // The launch run settles before the resolve, so the resolve does not race it for the scripted manifest.
        try await installed.start()
        _ = await installed.sync(.ifDue)
        let url = await resolver.resolveViaNetwork(identifier: icon.identifier, candidateExtensions: ["png"])
        let coordinator = CDNSyncCoordinator(sharingClientOf: store, cdn: ScriptedCDNProvider(manifest: .success([icon])))

        #expect(built == installed.identity, "the first use built and installed the client")
        #expect(installed.configuration.remote.http?.baseURL == base, "the first provider's tier")
        #expect(url == installed.lookup(CompatFixture.id(icon))?.url, "resolved through the client the point built")
        #expect(url != nil)
        #expect(other.client.identity == installed.identity)
        #expect(coordinator.client.identity == installed.identity)
        #expect(try await coordinator.verifyFullyAvailable().isEmpty)
        await installed.shutdown()
    }
}
