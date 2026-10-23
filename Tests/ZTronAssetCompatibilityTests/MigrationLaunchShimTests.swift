import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// R-CAR-6 on a launch on which legacy migration is still adopting the prior art's files: the first one after adoption,
/// and any later launch that resumes a migration an earlier launch did not finish (K-15, orchestrator ruling L5K-R4).
/// The prior art's files are adopted by legacy migration (R-STO-11, phase 2) in engine-owned batches that start only after
/// `start()` has returned, so the shims see that window; since the engine's L5K-R1 fix no job of any kind downloads a
/// file migration can still adopt (CCR-K1). Every test sets the launch up as MIGRATION.md step 3 does: the store in
/// Application Support and the prior art's tree in `<Caches>/CDNAssets`, the default legacy root, with an origin that
/// serves the same catalog and every asset's bytes, so only adoption avoids a transfer.
@Suite("Compatibility shims: launches during legacy migration")
struct MigrationLaunchShimTests {
    /// The prior art's directory, the default legacy root (`LegacyMigrationPolicy()`) on the fake volume.
    static let legacyRoot = URL(fileURLWithPath: "/fake-volume/Library/Caches/CDNAssets", isDirectory: true)

    /// MIGRATION.md step 3's configuration, with the harness's tuning.
    @available(macOS 15.0, iOS 18.0, *)
    static var configuration: CDNConfiguration {
        var configuration = CDNConfiguration()
        configuration.clientConfiguration.tuning = CompatHarness.tuning
        return configuration
    }

    /// One launch over a volume holding the prior art's tree: `count` prior-art videos of `size` bytes, a client
    /// configured as MIGRATION.md step 3 does (with the harness's tuning) and installed into a local point, and a store
    /// bound to that point. `bulk` is the store's bulk executor (inline unless the test holds the migration). Nothing is
    /// started.
    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    static func adoptionLaunch(count: Int, size: Int, bulk: any BlockingExecutor = InlineBlockingExecutor()) async throws -> AdoptionLaunch {
        let assets = (0..<count).map { index -> (CDNAsset, Data) in
            let bytes = CompatFixture.bytes(UInt64(5_000 + index), count: size)
            return (CompatFixture.asset("bo7.ri.easter.egg.video\(index)", bytes, ext: "mp4"), bytes)
        }
        let fakes = CompatHarness.make(bulk: bulk)
        try PriorArtTree.seed(assets, under: MigrationLaunchShimTests.legacyRoot, on: fakes.fileSystem)
        let point = CDNInstallPoint()
        let client = CDNProviderFactory.install(MigrationLaunchShimTests.configuration, into: point, environment: fakes.environment)
        await fakes.serve(assets)
        return AdoptionLaunch(fakes: fakes, client: client, store: CDNLocalStore(installPoint: point), assets: assets)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: on a launch during legacy migration the lookups miss a prior-art file until it is adopted after start() returned: a resolve adopts it without a download, and every file answers once migration has ended", .timeLimit(.minutes(1)))
    func lookupsDuringLegacyMigration() async throws {
        // The migration is held at a unit of its first file (L5K-R2: the window is a held state, not a race), so until the
        // test lets it go on only the resolves adopt, and each of them installs its snapshot before it returns.
        let bulk = SteppedBlockingExecutor(holding: true)
        let launch = try await MigrationLaunchShimTests.adoptionLaunch(count: 40, size: 256, bulk: bulk)
        let migration = try await CompatHarness.startHoldingMigration(launch.client, bulk: bulk)
        // What a carousel page created after `start()` returned sees (`BasicVideoPage.init?` reads `existingLocalURL` and has
        // no network step): no migration batch has ended, so no prior-art file answers yet.
        let visible = launch.visibleCount()
        let held = launch.assets.filter { launch.store.hasAsset($0.0) }.count
        let missing = launch.store.missingOrStaleAssets(against: launch.assets.map(\.0)).count
        // Subscribed while the migration is held, so the launch run it holds back cannot start before the subscription.
        let probe = EventProbe(stream: try await launch.client.subscribe())

        // `resolveViaNetwork` adopts a pending prior-art file on demand (store-2 S2-09) and answers an adopted one.
        let releaser = CompatHarness.releaser(bulk, keeping: migration)
        let resolver = CDNAssetResolver(client: launch.client)
        var resolved = 0
        for (asset, _) in launch.assets {
            if await resolver.resolveViaNetwork(identifier: asset.identifier, candidateExtensions: ["mp4"]) != nil {
                resolved += 1
            }
        }
        releaser.cancel()
        await releaser.value
        let starts = await launch.fakes.source.starts.count
        let legacyLeft = try launch.legacyFilesLeft()
        let stillHeld = Set(await bulk.heldUnits).isSuperset(of: migration)

        // The migration goes on and ends. No run started in this launch, so the launch run it held back starts when its
        // loop ends (L5K-R1), after every batch's snapshot was installed: a batch installs its snapshot at its end.
        await bulk.setHolding(false)
        let launchRun = await probe.next { event in
            if case .syncStarted(_, .launch) = event {
                return true
            }
            return false
        }
        let visibleAtTheEnd = launch.visibleCount()
        let heldAtTheEnd = launch.assets.filter { launch.store.hasAsset($0.0) }.count
        let missingAtTheEnd = launch.store.missingOrStaleAssets(against: launch.assets.map(\.0)).count

        #expect(visible == 0, "start() returns before legacy migration adopted any prior-art file (K-15)")
        #expect(held == visible, "hasAsset agrees with existingLocalURL")
        #expect(missing == launch.assets.count - visible, "missingOrStaleAssets lists every file not adopted yet")
        #expect(resolved == launch.assets.count)
        #expect(starts == 0, "adopted, never downloaded (R-STO-11)")
        #expect(legacyLeft == 0, "each file left the prior art's tree before its resolve returned")
        #expect(stillHeld, "the resolves adopted the files while the migration was held")
        #expect(launchRun != nil, "the migration ended and the launch run it held back started")
        #expect(visibleAtTheEnd == launch.assets.count)
        #expect(heldAtTheEnd == visibleAtTheEnd, "hasAsset agrees with existingLocalURL")
        #expect(missingAtTheEnd == 0)
        await probe.stop()
        await launch.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a coordinator's syncIfNeeded right after start on the first launch after adoption completes and downloads none of the prior art's files (CCR-K1)", .timeLimit(.minutes(1)))
    func launchSyncDuringLegacyMigration() async throws {
        let launch = try await MigrationLaunchShimTests.adoptionLaunch(count: 150, size: 65_536)
        let coordinator = CDNSyncCoordinator(client: launch.client, cdn: ScriptedCDNProvider(manifest: .success(launch.assets.map(\.0))))

        // MIGRATION.md steps 3 and 4 in one launch task: start, then the prior art's launch sync, while migration adopts.
        try await launch.client.start()
        await coordinator.syncIfNeeded()
        let progress = coordinator.progress
        let downloaded = await launch.fakes.starts(after: 0)
        let legacyLeft = try launch.legacyFilesLeft()
        let availability = try await launch.client.availability(scope: .all)

        #expect(progress == .complete)
        #expect(downloaded.isEmpty, "R-STO-11: moved, not downloaded again; \(downloaded.count) of \(launch.assets.count) prior-art files were (CCR-K1)")
        // Every file the run planned was adopted before its job ended (the engine's pre-transfer read, L5K-R1), and every file
        // it did not plan was present, so adopted, when it planned; an adoption moves the file before its record is present.
        #expect(legacyLeft == 0, "every prior-art file left the prior art's tree by the time the sync returned")
        // The store's state, which the sync's completion orders. The lookups' snapshot shows a migration batch's adoptions
        // only once that batch ends (K-15), and no public event marks the end of migration here (K-13).
        #expect(availability.present == launch.assets.count && availability.missing == 0, "every prior-art asset is stored: \(availability)")
        await launch.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a coordinator's syncIfNeeded right after start on a later launch that resumes an unfinished legacy migration completes and downloads none of the prior art's files (L5K-V3-06)", .timeLimit(.minutes(1)))
    func launchSyncDuringResumedMigration() async throws {
        // Launch 1: MIGRATION.md steps 3 and 4 in the launch task, and the app is terminated during them
        // (ProbeResumedMigration's shape). Every bulk unit is held from the start on, so the sync's run waits on units the
        // test never releases while launch 1 runs.
        let bulk = SteppedBlockingExecutor(holding: true)
        let first = try await MigrationLaunchShimTests.adoptionLaunch(count: 150, size: 4_096, bulk: bulk)
        _ = try await CompatHarness.startHoldingMigration(first.client, bulk: bulk)
        let probe = EventProbe(stream: try await first.client.subscribe())
        let interrupted = CDNSyncCoordinator(client: first.client, cdn: ScriptedCDNProvider(manifest: .success(first.assets.map(\.0))))
        let syncing = Task { @MainActor in
            await interrupted.syncIfNeeded()
        }
        let started = await probe.next { event in
            if case .syncStarted(_, .explicit) = event {
                return true
            }
            return false
        }
        // The sync's joiner is registered in the turn its run starts, and shutdown answers it in the turn in which it cancels
        // the migration and the run: once the call returns, each of them can finish only the file its held unit belongs to
        // (at most one for the migration and one per running job), and the rest stay for a resumed migration.
        let stopping = Task {
            await first.client.shutdown()
        }
        await withTaskCancellationHandler {
            await syncing.value
        } onCancel: {
            syncing.cancel()
        }
        await probe.stop()
        await bulk.setHolding(false)
        await stopping.value
        let interruptedProgress = interrupted.progress
        let launchOneStarts = await first.fakes.source.starts.count
        let leftForLaunchTwo = try first.legacyFilesLeft()

        // Launch 2 on the same volume and origin, with inline executors: start, then the coordinator's sync right away.
        let environment = CompatHarness.environment(
            time: first.fakes.clock,
            fileSystem: first.fakes.fileSystem,
            source: first.fakes.source,
            conditions: first.fakes.conditions,
            appVersion: "1.0+1"
        )
        let client = CDNProviderFactory.install(MigrationLaunchShimTests.configuration, into: CDNInstallPoint(), environment: environment)
        let coordinator = CDNSyncCoordinator(client: client, cdn: ScriptedCDNProvider(manifest: .success(first.assets.map(\.0))))
        await first.fakes.serveManifest(first.assets.map(\.0))
        try await client.start()
        await coordinator.syncIfNeeded()
        let progress = coordinator.progress
        let downloaded = await first.fakes.starts(after: launchOneStarts)
        let legacyLeft = try first.legacyFilesLeft()
        let availability = try await client.availability(scope: .all)

        #expect(started != nil, "launch 1's sync started while migration ran")
        #expect(interruptedProgress == .failed(reason: String(describing: SyncOutcome.failed(.shutDown))), "launch 1's sync ended with the shutdown")
        #expect(launchOneStarts == 0, "launch 1 downloaded nothing either")
        #expect(leftForLaunchTwo > 0, "launch 1 left prior-art files to a resumed migration: \(leftForLaunchTwo) of \(first.assets.count)")
        #expect(progress == .complete)
        #expect(downloaded.isEmpty, "R-STO-11 on the resumed launch: \(downloaded.count) of the \(leftForLaunchTwo) files left were downloaded")
        #expect(legacyLeft == 0, "every prior-art file left the prior art's tree by the time the sync returned")
        #expect(availability.present == first.assets.count && availability.missing == 0, "every prior-art asset is stored: \(availability)")
        await client.shutdown()
    }
}

/// A launch over the prior art's tree (`MigrationLaunchShimTests.adoptionLaunch(count:size:bulk:)`).
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
