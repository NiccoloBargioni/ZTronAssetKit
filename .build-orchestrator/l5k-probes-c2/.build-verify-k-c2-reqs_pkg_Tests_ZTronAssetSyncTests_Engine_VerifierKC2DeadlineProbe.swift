import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage
@testable import ZTronAssetSync

/// Verifier probe (WP-K close-out cycle 2, requirements lens; scratch copy only, never committed). After a bulk sync whose
/// jobs adopt prior-art files at `.bulk` urgency (L5K-R14), is the store's trailing install armed on the engine's alarm
/// (ARCHITECTURE §5: "A publication inside the window marks a trailing install due: nextDeadline() reports lastInstall +
/// interval, the engine's alarm calls runDueWork()"), so the adopted files reach the readers within the install window?
@Suite("Verifier K-C2 trailing-install probe", .serialized)
struct VerifierKC2DeadlineProbe {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: the trailing install of a sync's bulk adoptions is armed and runs once the window passes", .timeLimit(.minutes(1)))
    func trailingInstallAfterBulkAdoptions() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(100, seed: 8_100)
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            bulk: bulk,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        let beforeSync = await harness.sink.offeredKeys.count
        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        let report = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        let syncInstalls = await harness.sink.offeredKeys.count - beforeSync
        let visibleAfterSync = await VerifierKC2DeadlineProbe.visible(harness, pending)
        let storeNext = await harness.store.nextDeadline()
        let engineView = await engine.readForTests { engine in
            (heap: engine.state.heap.deadline(for: .store), stored: engine.state.storeDeadline)
        }
        let now = time.monotonicNow()
        let sleepers = time.pendingSleepers
        let nextSleeper = time.nextDeadline
        print("KC2-DEADLINE fetched=\(report.fetched) pending=\(pending.count) syncInstalls=\(syncInstalls) visibleAfterSync=\(visibleAfterSync) now=\(now) storeNextDeadline=\(String(describing: storeNext)) engineHeapStore=\(String(describing: engineView.heap)) engineStoreDeadline=\(String(describing: engineView.stored)) clockSleepers=\(sleepers) clockNextDeadline=\(String(describing: nextSleeper))")
        // Move the clock past every install window, then give the engine up to 3 s of wall time to install.
        time.advance(by: 1.0)
        var visibleLater = visibleAfterSync
        var waitedMs = 0
        while visibleLater < pending.count && waitedMs < 3_000 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waitedMs += 50
            visibleLater = await VerifierKC2DeadlineProbe.visible(harness, pending)
        }
        let installsLater = await harness.sink.offeredKeys.count - beforeSync - syncInstalls
        print("KC2-DEADLINE afterAdvance visible=\(visibleLater) of \(pending.count) extraInstalls=\(installsLater) waitedMs=\(waitedMs)")
        #expect(visibleLater == pending.count, "the bulk adoptions reach the readers once the install window passed")
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        // (B) Once migration has finished (phases 3 and 4), do the adoptions reach the readers?
        let afterMigration = await VerifierKC2DeadlineProbe.visible(harness, pending)
        let storeNextB = await harness.store.nextDeadline()
        let engineViewB = await engine.readForTests { engine in (heap: engine.state.heap.deadline(for: .store), stored: engine.state.storeDeadline) }
        print("KC2-DEADLINE B afterMigrationFinished visible=\(afterMigration) of \(pending.count) now=\(time.monotonicNow()) storeNextDeadline=\(String(describing: storeNextB)) engineHeapStore=\(String(describing: engineViewB.heap)) clockSleepers=\(time.pendingSleepers)")
        time.advance(by: 1.0)
        var visibleB = afterMigration
        var waitedB = 0
        while visibleB < pending.count && waitedB < 3_000 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waitedB += 50
            visibleB = await VerifierKC2DeadlineProbe.visible(harness, pending)
        }
        print("KC2-DEADLINE B afterAdvance visible=\(visibleB) of \(pending.count) waitedMs=\(waitedB)")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe C: a sync right after start beside a migration that is not held, then migration ends: do the readers see every prior-art file?", .timeLimit(.minutes(1)))
    func trailingInstallBesideRunningMigration() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(150, seed: 9_100, size: 16_384)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        let engine = harness.engine
        let ids = Set(catalog.map(\.0.identifier))
        try #require(try await harness.start().legacyMigrationPending)
        let outcome = await engine.sync(.force)
        let afterSync = await VerifierKC2DeadlineProbe.visible(harness, ids)
        await engine.awaitCondition { !$0.state.migration.pending && !$0.state.migration.running }
        let afterMigration = await VerifierKC2DeadlineProbe.visible(harness, ids)
        let storeNext = await harness.store.nextDeadline()
        let engineView = await engine.readForTests { engine in (heap: engine.state.heap.deadline(for: .store), stored: engine.state.storeDeadline) }
        let starts = await harness.source.starts.count
        print("KC2-DEADLINE C outcome=\(outcome) starts=\(starts) visibleAfterSync=\(afterSync) visibleAfterMigration=\(afterMigration) of \(ids.count) now=\(time.monotonicNow()) storeNextDeadline=\(String(describing: storeNext)) engineHeapStore=\(String(describing: engineView.heap)) clockSleepers=\(time.pendingSleepers)")
        time.advance(by: 1.0)
        var visible = afterMigration
        var waited = 0
        while visible < ids.count && waited < 3_000 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 50
            visible = await VerifierKC2DeadlineProbe.visible(harness, ids)
        }
        print("KC2-DEADLINE C afterAdvance visible=\(visible) of \(ids.count) waitedMs=\(waited)")
        #expect(visible == ids.count)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe I: on-demand prior-art files that migration adopts after a sync took the launch run's place: do they reach the readers?", .timeLimit(.minutes(1)))
    func migrationAdoptionsAfterTheSync() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(60, seed: 9_500)
        let pages = (0..<40).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(9_700 + UInt64(index))
            return (EngineFixture.entry("page\(index)", bytes, policy: .onDemand), bytes)
        }
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog + pages, time: time),
            time: time,
            bulk: bulk,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.serveManifest((catalog + pages).map(\.0))
        await harness.scriptTransfers(catalog + pages)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        _ = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        let pageIDs = Set(pages.map(\.0.identifier))
        let bulkIDs = Set(catalog.map(\.0.identifier))
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        let storedPages = try await EngineLegacyMigrationTransferTests.allPresent(harness, pages)
        let visiblePages = await VerifierKC2DeadlineProbe.visible(harness, pageIDs)
        let visibleBulk = await VerifierKC2DeadlineProbe.visible(harness, bulkIDs)
        let storeNext = await harness.store.nextDeadline()
        let heap = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        let launchRuns = await engine.readForTests { $0.state.migration.launchRunWaiting }
        print("KC2-DEADLINE I afterMigration storedPages=\(storedPages) visiblePages=\(visiblePages)/40 visibleBulk=\(visibleBulk)/60 now=\(time.monotonicNow()) storeNextDeadline=\(String(describing: storeNext)) engineHeapStore=\(String(describing: heap)) clockSleepers=\(time.pendingSleepers) launchRunWaiting=\(launchRuns)")
        time.advance(by: 1.0)
        var visible = visiblePages
        var waited = 0
        while visible < pageIDs.count && waited < 3_000 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 50
            visible = await VerifierKC2DeadlineProbe.visible(harness, pageIDs)
        }
        print("KC2-DEADLINE I afterAdvance visiblePages=\(visible)/40 waitedMs=\(waited) starts=\(await harness.source.starts.count)")
        #expect(visible == pageIDs.count)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe J: migration's own adoptions in a later install window, after the sync's trailing install ran: do they reach the readers?", .timeLimit(.minutes(1)))
    func migrationAdoptionsInALaterWindow() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(60, seed: 9_900)
        let pages = (0..<40).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(10_100 + UInt64(index))
            return (EngineFixture.entry("page\(index)", bytes, policy: .onDemand), bytes)
        }
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog + pages, time: time),
            time: time,
            bulk: bulk,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.serveManifest((catalog + pages).map(\.0))
        await harness.scriptTransfers(catalog + pages)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        _ = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        let pageIDs = Set(pages.map(\.0.identifier))
        let bulkIDs = Set(catalog.map(\.0.identifier))
        // Let any armed trailing install of the sync run first (a later install window for migration's batches).
        time.advance(by: 0.5)
        var waited = 0
        var visibleBulk = await VerifierKC2DeadlineProbe.visible(harness, bulkIDs)
        while visibleBulk < bulkIDs.count && waited < 1_000 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 50
            visibleBulk = await VerifierKC2DeadlineProbe.visible(harness, bulkIDs)
        }
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        let visiblePages = await VerifierKC2DeadlineProbe.visible(harness, pageIDs)
        let storeNext = await harness.store.nextDeadline()
        let heap = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        print("KC2-DEADLINE J afterMigration visibleBulk=\(visibleBulk)/60 visiblePages=\(visiblePages)/40 now=\(time.monotonicNow()) storeNextDeadline=\(String(describing: storeNext)) engineHeapStore=\(String(describing: heap)) clockSleepers=\(time.pendingSleepers)")
        time.advance(by: 1.0)
        var visible = visiblePages
        waited = 0
        while visible < pageIDs.count && waited < 3_000 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 50
            visible = await VerifierKC2DeadlineProbe.visible(harness, pageIDs)
        }
        print("KC2-DEADLINE J afterAdvance visiblePages=\(visible)/40 waitedMs=\(waited)")
        #expect(visible == pageIDs.count)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func visible(_ harness: EngineHarness, _ ids: Set<AssetID>) async -> Int {
        let installed = await harness.sink.installed
        return ids.filter { installed.location(for: $0, extensions: []) != nil }.count
    }
}
