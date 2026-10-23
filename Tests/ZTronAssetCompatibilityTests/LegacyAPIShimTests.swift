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

/// The prior art's tree on a `FakeFileSystem` (RECON §5): `manifest.json` (the bare array), `local-checksums.json`
/// (identifier to lowercase-hex SHA-256) and each asset's file at its pretty path. Gated for the Mutex-backed fake.
@available(macOS 15.0, iOS 18.0, *)
enum PriorArtTree {
    /// Creates `directory` and every missing ancestor (the fake's `createDirectory` creates one level).
    static func makeDirectories(_ directory: URL, on fileSystem: FakeFileSystem) throws {
        var missing: [URL] = []
        var current = directory
        while current.path != "/", try fileSystem.itemInfo(at: current) == nil {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        for url in missing.reversed() {
            try fileSystem.createDirectory(at: url)
        }
    }

    /// Where the prior art kept `asset` under `root`: `localPathComponents` (or the identifier's segments minus the
    /// last), then `<resolvedFileName>.<fileExtension>`.
    static func fileURL(of asset: CDNAsset, under root: URL) -> URL {
        let directories = asset.localPathComponents.isEmpty
            ? Array(asset.identifier.split(separator: ".").map(String.init).dropLast())
            : asset.localPathComponents
        return directories.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent("\(asset.resolvedFileName).\(asset.fileExtension)", isDirectory: false)
    }

    /// Writes the prior art's tree for `assets` under `root`.
    static func seed(_ assets: [(CDNAsset, Data)], under root: URL, on fileSystem: FakeFileSystem) throws {
        try PriorArtTree.makeDirectories(root, on: fileSystem)
        try fileSystem.write(CompatFixture.manifestData(assets.map(\.0)), to: root.appendingPathComponent("manifest.json"), mode: .truncate)
        var checksums: [String: String] = [:]
        for (asset, bytes) in assets {
            let file = PriorArtTree.fileURL(of: asset, under: root)
            try PriorArtTree.makeDirectories(file.deletingLastPathComponent(), on: fileSystem)
            try fileSystem.write(bytes, to: file, mode: .truncate)
            checksums[asset.identifier] = asset.checksum
        }
        try fileSystem.write(try JSONEncoder().encode(checksums), to: root.appendingPathComponent("local-checksums.json"), mode: .truncate)
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
        #expect(
            store.installPoint.configuration.clientConfiguration.location == .custom(base.deletingLastPathComponent()),
            "the store's root lies beside the prior art's directory, never inside it (R-STO-11 refuses a nested root)"
        )
        #expect(store.installPoint.configuration.clientConfiguration.legacy.root == base)
        #expect(
            (store as any PriorArtLocalStore).localURL(for: pretty).path
                == "/legacy/CDNAssets/Black Ops 7/Rex Infernus/Vehytherion Temple/icon.heic"
        )
        #expect((store as any PriorArtLocalStore).localURL(for: mechanical).path == "/legacy/CDNAssets/waw/ndu/title/title.png")

        let defaultStore = PriorArt.localStore(CDNLocalStore.self, baseDirectory: nil)
        #expect(defaultStore.installPoint === CDNInstallPoint.process, "a second default store shares the process point")
    }

    @MainActor
    @Test("R-CAR-6: localURL keeps a crafted entry's path inside the legacy root")
    func localURLStaysInsideTheLegacyRoot() {
        let base = URL(fileURLWithPath: "/legacy/CDNAssets", isDirectory: true)
        let store: any PriorArtLocalStore = PriorArt.localStore(CDNLocalStore.self, baseDirectory: base)
        // A manifest is untrusted input (R-MAN-2): directory components that would leave the root or name no directory
        // are dropped, and a `/` in the file name cannot reach another directory.
        let crafted = CDNAsset(
            identifier: "bo7.ri.icon",
            fileExtension: "png",
            remotePath: "media/a/icon.png",
            localPathComponents: ["..", "", ".", "Black Ops 7", "a/../../b"],
            localFileName: "../../etc/passwd"
        )
        let unnamed = CDNAsset(identifier: "bo7/ri.card", fileExtension: "", remotePath: "media/b/card", localFileName: "")

        #expect(store.localURL(for: crafted).path == "/legacy/CDNAssets/Black Ops 7/.._.._etc_passwd.png")
        #expect(store.localURL(for: unnamed).path == "/legacy/CDNAssets/_", "a file name of `.` names an entry, not the root")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: the prior-art local store initialiser's client adopts the prior art's files found in its directory and downloads nothing", .timeLimit(.minutes(1)))
    func legacyStoreAdoptsThePriorArtFiles() async throws {
        let parent = URL(fileURLWithPath: "/fake-volume/Library/Caches", isDirectory: true)
        let directory = parent.appendingPathComponent("CDNAssets", isDirectory: true)
        let iconBytes = CompatFixture.bytes(75)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.icon", iconBytes)
        let fakes = CompatHarness.make()
        try PriorArtTree.seed([(icon, iconBytes)], under: directory, on: fakes.fileSystem)
        let legacyFile = PriorArtTree.fileURL(of: icon, under: directory)
        let tap = RecordingLogTap()
        var environment = fakes.environment
        environment.logTap = tap
        // The deprecated initialiser's configuration, with the harness's tuning (the self-advancing clock needs it).
        var configuration = PriorArt.localStore(CDNLocalStore.self, baseDirectory: directory).installPoint.configuration
        configuration.clientConfiguration.tuning = CompatHarness.tuning
        let client = CDNProviderFactory.makeClient(configuration, environment: environment)
        // The origin serves the same catalog and the asset's bytes, so only adoption avoids a download.
        await fakes.serve([(icon, iconBytes)])

        try await client.start()
        // Deterministic whether or not migration reached the file yet: a resolve adopts a pending legacy file on demand
        // (store-2 S2-09), and nothing else starts a run while migration is pending (the launch run waits for it).
        let resolved = try await client.resolve(CompatFixture.id(icon))

        let store = CDNLocalStore(client: client)
        #expect(resolved.path.hasPrefix(parent.path + "/ZTronAssetKit/v1/"), "the store lives beside the prior art's directory: \(resolved.path)")
        #expect(store.existingLocalURL(identifier: icon.identifier, candidateExtensions: ["png"]) == resolved)
        #expect(store.hasAsset(icon))
        #expect(await fakes.source.starts.isEmpty, "adopted, not downloaded again")
        #expect(try fakes.fileSystem.itemInfo(at: legacyFile) == nil, "adopted by a same-volume rename out of the prior art's tree")
        #expect(!tap.lines.contains { $0.message.contains("overlaps the store") }, "migration was not refused")
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: the prior-art local store initialiser's client starts on a fresh install, before its directory exists", .timeLimit(.minutes(1)))
    func legacyStoreStartsOnAFreshInstall() async throws {
        let parent = URL(fileURLWithPath: "/fake-volume/Documents", isDirectory: true)
        let directory = parent.appendingPathComponent("CDNAssets", isDirectory: true)
        let fakes = CompatHarness.make()
        try PriorArtTree.makeDirectories(parent, on: fakes.fileSystem)
        var configuration = PriorArt.localStore(CDNLocalStore.self, baseDirectory: directory).installPoint.configuration
        configuration.clientConfiguration.tuning = CompatHarness.tuning
        let client = CDNProviderFactory.makeClient(configuration, environment: fakes.environment)
        await fakes.serveManifest([])

        var failure: AssetError?
        do throws(AssetError) {
            try await client.start()
        } catch {
            failure = error
        }

        #expect(failure == nil, "the prior art created its directory; the client needs only its parent")
        #expect(try fakes.fileSystem.itemInfo(at: parent.appendingPathComponent("ZTronAssetKit/v1", isDirectory: true)) != nil)
        #expect(try fakes.fileSystem.itemInfo(at: directory) == nil, "nothing is created in the prior art's place")
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: two prior-art stores in one parent directory share one root, which admits one client (R-STO-9)", .timeLimit(.minutes(1)))
    func legacyStoresInOneParentShareOneRoot() async throws {
        let parent = URL(fileURLWithPath: "/fake-volume/Library/Caches", isDirectory: true)
        let first = PriorArt.localStore(CDNLocalStore.self, baseDirectory: parent.appendingPathComponent("CDNAssets", isDirectory: true))
        let second = PriorArt.localStore(CDNLocalStore.self, baseDirectory: parent.appendingPathComponent("Posters", isDirectory: true))
        #expect(first.installPoint !== second.installPoint)
        #expect(first.installPoint.configuration.clientConfiguration.location == second.installPoint.configuration.clientConfiguration.location)
        let fakes = CompatHarness.make()
        try PriorArtTree.makeDirectories(parent, on: fakes.fileSystem)
        let clients = [first, second].map { store -> AssetClient in
            var configuration = store.installPoint.configuration
            configuration.clientConfiguration.tuning = CompatHarness.tuning
            return CDNProviderFactory.makeClient(configuration, environment: fakes.environment)
        }
        await fakes.serveManifest([])

        try await clients[0].start()
        var failure: AssetError?
        do throws(AssetError) {
            try await clients[1].start()
        } catch {
            failure = error
        }

        #expect(failure == .storageUnavailable(.locked), "one store per parent directory")
        for client in clients {
            await client.shutdown()
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a prior-art store whose directory lies in Caches shares its root with a client at StorageLocation.caches, which admits one client (R-STO-9)", .timeLimit(.minutes(1)))
    func legacyStoreInCachesSharesTheCachesRoot() async throws {
        // The fake volume's standard Caches directory, which `StorageLocation.caches` resolves to.
        let caches = URL(fileURLWithPath: "/fake-volume/Library/Caches", isDirectory: true)
        let store = PriorArt.localStore(CDNLocalStore.self, baseDirectory: caches.appendingPathComponent("CDNAssets", isDirectory: true))
        // An installed process client configured with `location: .caches`, and the prior-art store's own client.
        let configurations = [CDNConfiguration(location: .caches), store.installPoint.configuration]
        let fakes = CompatHarness.make()
        let clients = configurations.map { configuration -> AssetClient in
            var tuned = configuration
            tuned.clientConfiguration.tuning = CompatHarness.tuning
            return CDNProviderFactory.makeClient(tuned, environment: fakes.environment)
        }
        await fakes.serveManifest([])

        try await clients[0].start()
        var failure: AssetError?
        do throws(AssetError) {
            try await clients[1].start()
        } catch {
            failure = error
        }

        #expect(failure == .storageUnavailable(.locked), "one client per resolved base directory: `.custom(<Caches>)` is `.caches`")
        for client in clients {
            await client.shutdown()
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: localURL is the stored blob for an asset the client holds, and the prior art's default path for one it does not", .timeLimit(.minutes(1)))
    func localURLIsTheStoredBlob() async throws {
        let iconBytes = CompatFixture.bytes(70)
        let icon = CompatFixture.asset("bo6.tm.icon", iconBytes)
        let absent = CompatFixture.asset("bo6.tm.poster", CompatFixture.bytes(74), directories: ["Black Ops 6", "The Tomb"])
        let harness = CompatHarness.make()
        await harness.serve([(icon, iconBytes)])
        try await harness.settleLaunch()
        let store: any PriorArtLocalStore = CDNLocalStore(client: harness.client)

        #expect(store.localURL(for: icon) == harness.client.lookup(CompatFixture.id(icon))?.url)
        // The harness's client names no legacy root, so the prior art's default, `<Caches>/CDNAssets`, applies (a path
        // computation only: nothing is created there).
        let legacy = store.localURL(for: absent)
        #expect(legacy.path.hasSuffix("/Caches/CDNAssets/Black Ops 6/The Tomb/poster.png"))
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
