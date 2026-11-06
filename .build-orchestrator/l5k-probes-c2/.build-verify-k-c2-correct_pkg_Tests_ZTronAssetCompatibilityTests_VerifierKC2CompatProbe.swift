import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// Verifier probes, WP-K close-out cycle 2, correctness lens (public API, the shims). Scratch copy only; never committed.
@Suite("Verifier K-C2 compat probes", .serialized)
struct VerifierKC2CompatProbe {
    /// PK-R14b: a carousel page opened during legacy migration (its `resolveViaNetwork` adopts the page's file and installs
    /// at once), then its neighbours prefetched at the default lane right away (`AssetClient.prefetch`), with the
    /// production install interval. Their jobs adopt the neighbours' files at bulk urgency, inside the install window. The
    /// store then holds them; are they ever visible to `existingLocalURL`, even 10 s later?
    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("PK-R14b: neighbours prefetched right after a page's resolve during migration become visible to the lookups", .timeLimit(.minutes(1)))
    func neighboursPrefetchedDuringMigration() async throws {
        let count = 12
        let assets = (0..<count).map { index -> (CDNAsset, Data) in
            let bytes = CompatFixture.bytes(UInt64(8_000 + index), count: 4_096)
            return (CompatFixture.asset("bo7.ri.easter.egg.video\(index)", bytes, ext: "mp4"), bytes)
        }
        var tuning = CompatHarness.tuning
        tuning.snapshotInstallInterval = SyncTuning().snapshotInstallInterval
        let bulk = SteppedBlockingExecutor(holding: true)
        let fakes = CompatHarness.make(tuning: tuning, bulk: bulk)
        try PriorArtTree.seed(assets, under: MigrationLaunchShimTests.legacyRoot, on: fakes.fileSystem)
        var configuration = CDNConfiguration()
        configuration.clientConfiguration.tuning = tuning
        let point = CDNInstallPoint()
        let client = CDNProviderFactory.install(configuration, into: point, environment: fakes.environment)
        await fakes.serve(assets)
        let launch = AdoptionLaunch(fakes: fakes, client: client, store: CDNLocalStore(installPoint: point), assets: assets)
        let migration = try await CompatHarness.startHoldingMigration(launch.client, bulk: bulk)
        let releaser = CompatHarness.releaser(bulk, keeping: migration)
        let resolver = CDNAssetResolver(client: launch.client)
        // The page.
        let page = launch.assets[count - 1].0
        let pageURL = await resolver.resolveViaNetwork(identifier: page.identifier, candidateExtensions: ["mp4"])
        let pageVisible = launch.store.existingLocalURL(identifier: page.identifier, candidateExtensions: ["mp4"]) != nil
        // Its neighbours, prefetched at once at the default lane.
        let neighbours = launch.assets.prefix(count - 1).map { CompatFixture.id($0.0) }
        let handle = launch.client.prefetch(neighbours)
        try await handle.awaitRegistration()
        var rounds = 0
        var stored = try await launch.client.availability(scope: .identifiers(Set(neighbours)))
        while stored.present < neighbours.count, rounds < 5_000 {
            await Task.yield()
            stored = try await launch.client.availability(scope: .identifiers(Set(neighbours)))
            rounds += 1
        }
        let visibleAfterPrefetch = launch.assets.prefix(count - 1).filter { launch.store.existingLocalURL(identifier: $0.0.identifier, candidateExtensions: ["mp4"]) != nil }.count
        // 10 s later, with many round trips for whatever the client armed.
        launch.fakes.time.advance(by: 10)
        var later = 0
        for _ in 0..<500 {
            _ = try await launch.client.availability(scope: .all)
            await Task.yield()
            later = launch.assets.prefix(count - 1).filter { launch.store.existingLocalURL(identifier: $0.0.identifier, candidateExtensions: ["mp4"]) != nil }.count
            if later == count - 1 {
                break
            }
        }
        let downloaded = await launch.fakes.starts(after: 0)
        let lookups = neighbours.filter { launch.client.lookup($0) != nil }.count
        print("KC2-PROBE PK-R14b interval=\(tuning.snapshotInstallInterval) pageResolved=\(pageURL != nil) pageVisible=\(pageVisible) neighboursStored=\(stored.present)/\(neighbours.count) visibleAfterPrefetch=\(visibleAfterPrefetch) visibleAfter10s=\(later) clientLookups=\(lookups) downloaded=\(downloaded.count) rounds=\(rounds)")
        handle.cancel()
        releaser.cancel()
        await releaser.value
        #expect(downloaded.isEmpty)
        #expect(stored.present == neighbours.count, "the store holds every prefetched neighbour")
        #expect(later == neighbours.count, "existingLocalURL answers \(later) of \(neighbours.count) neighbours the prefetch adopted, 10 s after the install window")
        await bulk.setHolding(false)
        await launch.client.shutdown()
    }

    /// PK-R14: MIGRATION.md steps 3 and 4 (start, then the coordinator's launch sync while migration adopts) with the
    /// production install interval (`SyncTuning`'s default 0.1 s) instead of the harness's 0. MIGRATION.md §4 and K.md's
    /// L5K-R14 section say the files a sync adopts reach the lookups within that interval (the trailing install runs on the
    /// engine's alarm). After the sync, the migration is let go, the clock is moved 10 s, and the client is given many
    /// round trips: does `existingLocalURL` answer every adopted file?
    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("PK-R14: after the launch sync during migration, with the default install interval, the lookups find every adopted file", .timeLimit(.minutes(1)))
    func lookupsAfterLaunchSyncWithDefaultInterval() async throws {
        let count = 40
        let assets = (0..<count).map { index -> (CDNAsset, Data) in
            let bytes = CompatFixture.bytes(UInt64(7_000 + index), count: 4_096)
            return (CompatFixture.asset("bo7.ri.easter.egg.video\(index)", bytes, ext: "mp4"), bytes)
        }
        var tuning = CompatHarness.tuning
        tuning.snapshotInstallInterval = SyncTuning().snapshotInstallInterval
        let bulk = SteppedBlockingExecutor(holding: true)
        let fakes = CompatHarness.make(tuning: tuning, bulk: bulk)
        try PriorArtTree.seed(assets, under: MigrationLaunchShimTests.legacyRoot, on: fakes.fileSystem)
        var configuration = CDNConfiguration()
        configuration.clientConfiguration.tuning = tuning
        let point = CDNInstallPoint()
        let client = CDNProviderFactory.install(configuration, into: point, environment: fakes.environment)
        await fakes.serve(assets)
        let launch = AdoptionLaunch(fakes: fakes, client: client, store: CDNLocalStore(installPoint: point), assets: assets)
        let coordinator = CDNSyncCoordinator(client: launch.client, cdn: ScriptedCDNProvider(manifest: .success(launch.assets.map(\.0))))

        let migration = try await CompatHarness.startHoldingMigration(launch.client, bulk: bulk)
        let releaser = CompatHarness.releaser(bulk, keeping: migration)
        await coordinator.syncIfNeeded()
        let progress = coordinator.progress
        let downloaded = await launch.fakes.starts(after: 0)
        releaser.cancel()
        await releaser.value
        let visibleAfterSync = launch.visibleCount()
        let stored = try await launch.client.availability(scope: .all)

        // The migration goes on and ends; then the clock moves far beyond the install interval and the client gets many
        // round trips (each an engine and store hop, the main actor free in between).
        await bulk.setHolding(false)
        launch.fakes.time.advance(by: 10)
        var rounds = 0
        while launch.visibleCount() < count, rounds < 2_000 {
            _ = try await launch.client.availability(scope: .all)
            await Task.yield()
            rounds += 1
        }
        let visibleLater = launch.visibleCount()
        let lookups = launch.assets.filter { launch.client.lookup(CompatFixture.id($0.0)) != nil }.count
        print("KC2-PROBE PK-R14 interval=\(tuning.snapshotInstallInterval) progress=\(progress) downloaded=\(downloaded.count) stored=\(stored.present)/\(count) visibleAfterSync=\(visibleAfterSync) visibleAfter10s=\(visibleLater) clientLookups=\(lookups) rounds=\(rounds)")
        #expect(downloaded.isEmpty)
        #expect(stored.present == count, "the store holds every adopted file")
        #expect(visibleLater == count, "existingLocalURL answers \(visibleLater) of \(count) files the sync adopted, 10 s after the install window (MIGRATION.md §4: within snapshotInstallInterval)")
        await launch.client.shutdown()
    }
}
