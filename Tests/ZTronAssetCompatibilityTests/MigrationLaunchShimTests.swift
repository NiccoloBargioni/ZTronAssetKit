import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// R-CAR-6 on the first launch after adoption (K-15): the prior art's files are adopted by legacy migration
/// (R-STO-11, phase 2) in engine-owned batches that start only after `start()` has returned, so the shims see that
/// window. Both tests set the launch up as MIGRATION.md step 3 does: the store in Application Support and the prior
/// art's tree in `<Caches>/CDNAssets`, the default legacy root, with an origin that serves the same catalog and every
/// asset's bytes, so only adoption avoids a transfer.
@Suite("Compatibility shims: the first launch after adoption")
struct MigrationLaunchShimTests {
    /// The prior art's directory, the default legacy root (`LegacyMigrationPolicy()`) on the fake volume.
    static let legacyRoot = URL(fileURLWithPath: "/fake-volume/Library/Caches/CDNAssets", isDirectory: true)

    /// One first launch after adoption: `count` prior-art videos of `size` bytes, a client configured as MIGRATION.md
    /// step 3 does (with the harness's tuning) and installed into a local point, and a store bound to that point.
    /// Nothing is started.
    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    static func adoptionLaunch(count: Int, size: Int) async throws -> AdoptionLaunch {
        let assets = (0..<count).map { index -> (CDNAsset, Data) in
            let bytes = CompatFixture.bytes(UInt64(5_000 + index), count: size)
            return (CompatFixture.asset("bo7.ri.easter.egg.video\(index)", bytes, ext: "mp4"), bytes)
        }
        let fakes = CompatHarness.make()
        try PriorArtTree.seed(assets, under: MigrationLaunchShimTests.legacyRoot, on: fakes.fileSystem)
        var configuration = CDNConfiguration()
        configuration.clientConfiguration.tuning = CompatHarness.tuning
        let point = CDNInstallPoint()
        let client = CDNProviderFactory.install(configuration, into: point, environment: fakes.environment)
        await fakes.serve(assets)
        return AdoptionLaunch(fakes: fakes, client: client, store: CDNLocalStore(installPoint: point), assets: assets)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: on the first launch after adoption the lookups miss a prior-art file until legacy migration adopted it, after start() returned, and a resolve adopts it without a download", .timeLimit(.minutes(1)))
    func lookupsDuringLegacyMigration() async throws {
        let launch = try await MigrationLaunchShimTests.adoptionLaunch(count: 320, size: 256)

        try await launch.client.start()
        // The main-actor turn in which `start()` returned: what a carousel page created right after it sees
        // (`BasicVideoPage.init?` reads `existingLocalURL` and has no network step).
        let visible = launch.visibleCount()
        let held = launch.assets.filter { launch.store.hasAsset($0.0) }.count
        let missing = launch.store.missingOrStaleAssets(against: launch.assets.map(\.0)).count
        // `resolveViaNetwork` adopts a pending prior-art file on demand (store-2 S2-09) and answers a migrated one.
        let resolver = CDNAssetResolver(client: launch.client)
        var resolved = 0
        for (asset, _) in launch.assets {
            if await resolver.resolveViaNetwork(identifier: asset.identifier, candidateExtensions: ["mp4"]) != nil {
                resolved += 1
            }
        }
        let visibleAfterResolves = launch.visibleCount()
        let starts = await launch.fakes.source.starts.count
        let legacyLeft = try launch.legacyFilesLeft()

        #expect(visible < launch.assets.count, "start() returns before legacy migration adopted every prior-art file (K-15)")
        #expect(held == visible, "hasAsset agrees with existingLocalURL")
        #expect(missing == launch.assets.count - visible, "missingOrStaleAssets lists every file not adopted yet")
        #expect(resolved == launch.assets.count)
        #expect(visibleAfterResolves == launch.assets.count)
        #expect(starts == 0, "adopted, never downloaded (R-STO-11)")
        #expect(legacyLeft == 0, "moved out of the prior art's tree")
        await launch.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a coordinator's syncIfNeeded right after start on the first launch after adoption completes and downloads none of the prior art's files (CCR-K1)", .timeLimit(.minutes(1)))
    func launchSyncDuringLegacyMigration() async throws {
        let launch = try await MigrationLaunchShimTests.adoptionLaunch(count: 150, size: 65_536)
        let coordinator = CDNSyncCoordinator(client: launch.client, cdn: ScriptedCDNProvider(manifest: .success(launch.assets.map(\.0))))

        // MIGRATION.md steps 3 and 4 in one launch task: start, then the prior art's launch sync.
        try await launch.client.start()
        await coordinator.syncIfNeeded()
        let progress = coordinator.progress
        let downloaded = await launch.fakes.source.starts.count
        // Every file the sync did not download is adopted, on demand where migration has not reached it yet.
        for (asset, _) in launch.assets {
            _ = try await launch.client.resolve(CompatFixture.id(asset))
        }
        let stored = launch.assets.filter { launch.store.hasAsset($0.0) }.count
        let legacyLeft = try launch.legacyFilesLeft()

        #expect(progress == .complete)
        #expect(stored == launch.assets.count)
        #expect(legacyLeft == 0, "every prior-art file left the prior art's tree")
        // CCR-K1 (WP-F's engine, k.md K-15): `sync` starts an explicit run at once while migration still adopts, and its
        // bulk jobs never adopt on demand, so they download every prior-art file phase 2 has not reached. The wrapper
        // goes with the engine fix; intermittent because the count is a race (6 to 41 of 150 in 15 of 15 runs on a quiet
        // host, none in 10 runs on a loaded one).
        withKnownIssue("CCR-K1: an explicit sync during legacy migration downloads the prior-art files not adopted yet", isIntermittent: true) {
            #expect(downloaded == 0, "R-STO-11: moved, not downloaded again; \(downloaded) of \(launch.assets.count) prior-art files were")
        }
        await launch.client.shutdown()
    }
}

/// A first launch after adoption (`MigrationLaunchShimTests.adoptionLaunch(count:size:)`).
@available(macOS 15.0, iOS 18.0, *)
struct AdoptionLaunch {
    let fakes: CompatHarness
    let client: AssetClient
    let store: CDNLocalStore
    let assets: [(CDNAsset, Data)]

    /// The prior-art files `existingLocalURL` answers now.
    @MainActor
    func visibleCount() -> Int {
        self.assets.filter { self.store.existingLocalURL(identifier: $0.0.identifier, candidateExtensions: ["mp4"]) != nil }.count
    }

    /// The prior-art files still in the prior art's tree.
    func legacyFilesLeft() throws -> Int {
        try self.assets.filter {
            try self.fakes.fileSystem.itemInfo(at: PriorArtTree.fileURL(of: $0.0, under: MigrationLaunchShimTests.legacyRoot)) != nil
        }.count
    }
}
