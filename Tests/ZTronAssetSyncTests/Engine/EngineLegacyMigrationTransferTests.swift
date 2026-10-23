import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Orchestrator ruling L5K-R1 (CCR-K1, R-STO-11): while legacy migration is pending or running, no transfer starts for
/// an asset whose prior-art file can still be adopted, whatever created its job: an explicit run, a prefetch join,
/// `ensureAvailable`, or any of them on a later launch that resumes an interrupted migration. Before any bytes, the
/// pre-transfer store read (`answeredFromStore`, row f-11) adopts the file instead (`adoptLegacyNow`, row k-4) and the job
/// is answered from the store as for a present asset (L4-R5). The parked launch run is settled too: a run that starts
/// while the launch run waits for migration takes its place.
///
/// Every test holds the migration at a bulk unit (`SteppedBlockingExecutor`) while the operation runs, so the operation
/// provably overlaps migration, and releases every other bulk unit as it arrives; the origin serves every prior-art
/// asset's bytes, so only an adoption avoids a transfer. Each wait is a condition or census wait that ends on
/// cancellation (ARCHITECTURE §14, sync test rule 2).
@Suite("Engine: transfers during legacy migration (L5K-R1)")
struct EngineLegacyMigrationTransferTests {
    /// `count` prior-art entries (standard policy) with their bytes.
    static func catalog(_ count: Int, seed: UInt64) -> [(ManifestEntry, Data)] {
        (0..<count).map { index in
            let bytes = EngineFixture.bytes(seed + UInt64(index))
            return (EngineFixture.entry("legacy\(index)", bytes), bytes)
        }
    }

    /// A launch over `disk` with legacy migration enabled at the prior art's root and a bulk executor that holds every
    /// unit; the origin's manifest lists `served` and `unscripted`, and it serves the bytes of every entry of `served`
    /// (the test scripts the others). Nothing is started.
    @available(macOS 15.0, iOS 18.0, *)
    static func launch(
        disk: DiskImage,
        time: ManualTimeSource,
        served: [(ManifestEntry, Data)],
        unscripted: [ManifestEntry] = []
    ) async -> (harness: EngineHarness, bulk: SteppedBlockingExecutor) {
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(disk: disk, time: time, bulk: bulk, legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot))
        await harness.serveManifest(served.map(\.0) + unscripted)
        await harness.scriptTransfers(served)
        return (harness, bulk)
    }

    /// Starts the engine (its owned tasks at the harness's priority floor), releasing open's bulk units until it runs,
    /// and returns the report with the units the migration holds from then on: its first file's, or a later one's when a
    /// release of open's last units met the first. Requires a pending migration, so the census wait below cannot wait
    /// for a unit nothing submits.
    @available(macOS 15.0, iOS 18.0, *)
    static func startHoldingMigration(_ harness: EngineHarness, bulk: SteppedBlockingExecutor) async throws -> (report: OpenReport, migration: Set<Int>) {
        let engine = harness.engine
        await engine.setOwnedTaskPriorityFloor(EngineHarness.ownedTaskPriorityFloor)
        let starting = Task { await engine.start() }
        while !EngineOutcomeTests.isUp(await engine.introspect().lifecycle) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await engine.waitUntil { EngineOutcomeTests.isUp($0.lifecycle) }
                }
                group.addTask {
                    await bulk.waitForHeldUnits(atLeast: 1)
                }
                _ = await group.next()
                group.cancelAll()
            }
            for unit in await bulk.heldUnits {
                await bulk.release(unit)
            }
            // Both waits above end on cancellation; the loop must too (a test past its time limit ends, never spins).
            try Task.checkCancellation()
        }
        let report = try await starting.value.get()
        try #require(report.legacyMigrationPending, "the launch has a legacy migration to hold")
        try await bulk.requireHeldUnits(atLeast: 1)
        return (report, Set(await bulk.heldUnits))
    }

    /// Runs `operation` while `bulk` keeps the units in `kept` (the migration's) held, releasing every other unit as it
    /// arrives, and returns the operation's result. When the operation is done its task submits one more unit, which
    /// wakes the loop (the pattern of `EngineOutcomeTests.resolveDuringMigration`); that unit, and so the returned task,
    /// ends once the test stops holding. Every wait ends on cancellation.
    @available(macOS 15.0, iOS 18.0, *)
    static func duringMigration<T: Sendable>(
        keeping kept: Set<Int>,
        bulk: SteppedBlockingExecutor,
        _ operation: @escaping @Sendable () async -> T
    ) async throws -> (value: T, task: Task<Void, Never>) {
        let result = Mutex<T?>(nil)
        let task = Task {
            let value = await operation()
            result.withLock { $0 = value }
            _ = await bulk.run { 0 }
        }
        while true {
            if let value = result.withLock({ $0 }) {
                return (value, task)
            }
            try await bulk.requireHeldUnits(atLeast: kept.count + 1)
            for unit in await bulk.heldUnits where !kept.contains(unit) {
                await bulk.release(unit)
            }
        }
    }

    /// Releases every unit of `bulk` outside `kept` as it arrives until `condition` holds on the engine (re-evaluated
    /// after every engine mutation). Both waits end on cancellation, so a test past its time limit ends instead of
    /// hanging.
    @available(macOS 15.0, iOS 18.0, *)
    static func release(
        _ bulk: SteppedBlockingExecutor,
        keeping kept: Set<Int>,
        on engine: SyncEngine,
        until condition: @escaping @Sendable (isolated SyncEngine) -> Bool
    ) async throws {
        while !(await engine.readForTests(condition)) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await engine.awaitCondition(condition)
                }
                group.addTask {
                    await bulk.waitForHeldUnits(atLeast: kept.count + 1)
                }
                _ = await group.next()
                group.cancelAll()
            }
            for unit in await bulk.heldUnits where !kept.contains(unit) {
                await bulk.release(unit)
            }
            try Task.checkCancellation()
        }
    }

    /// The prior-art ids the store does not hold present yet: what migration may still adopt.
    @available(macOS 15.0, iOS 18.0, *)
    static func pending(_ harness: EngineHarness, _ catalog: [(ManifestEntry, Data)]) async throws -> Set<AssetID> {
        let view = try await harness.view()
        return Set(catalog.map(\.0.identifier).filter { view.records[$0]?.referencedBlob == nil })
    }

    /// Whether every prior-art id is present in the store.
    @available(macOS 15.0, iOS 18.0, *)
    static func allPresent(_ harness: EngineHarness, _ catalog: [(ManifestEntry, Data)]) async throws -> Bool {
        let view = try await harness.view()
        return catalog.allSatisfy { view.records[$0.0.identifier]?.referencedBlob != nil && view.records[$0.0.identifier]?.isStale == false }
    }

    /// Lets the migration go on and returns once it has finished (phases 3 and 4 included); every wait ends on
    /// cancellation or shutdown.
    @available(macOS 15.0, iOS 18.0, *)
    static func finishMigration(_ harness: EngineHarness, bulk: SteppedBlockingExecutor) async {
        await bulk.setHolding(false)
        await harness.engine.awaitCondition { !$0.state.migration.pending && !$0.state.migration.running }
    }

    // MARK: Every path that creates a job adopts instead of downloading

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: an explicit sync during legacy migration adopts every prior-art file still pending and downloads none (CCR-K1)", .timeLimit(.minutes(1)))
    func explicitSyncDuringMigration() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(6, seed: 7_100)
        let (harness, bulk) = await EngineLegacyMigrationTransferTests.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "the sync starts while migration still has the prior art's files to adopt")

        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }

        let report = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        #expect(report.trigger == .explicit)
        #expect(report.fetched == pending.count, "each pending file counts as fetched, answered from the store")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        #expect(try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog))
        #expect(Set(await bulk.heldUnits).isSuperset(of: migration), "the migration was held at its file throughout the sync")
        #expect(await engine.readForTests { $0.state.migration.running })
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        #expect(try harness.fileSystem.itemInfo(at: EngineRunPathTests.legacyRoot) == nil, "phase 4 removed the prior art's tree")
        #expect(await harness.source.starts.isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: a prefetch group joined during legacy migration adopts the prior-art files instead of downloading them (CCR-K1)", .timeLimit(.minutes(1)))
    func prefetchJoinDuringMigration() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(6, seed: 7_200)
        let (harness, bulk) = await EngineLegacyMigrationTransferTests.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "the group joins while migration still has the prior art's files to adopt")

        // The applied manifest is the prior art's (phase 1), so the join needs no run: it reads the store and creates a
        // job for each member that is not present.
        let token = try await engine.registerGroup(catalog.map(\.0.identifier), lane: .prefetch).get()
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration, on: engine) { engine in
            guard let group = engine.state.groups[token] else {
                return false
            }
            return group.claimCursor == group.members.count && group.pending.isEmpty && engine.state.jobs.isEmpty
        }

        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        #expect(try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog))
        #expect(Set(await bulk.heldUnits).isSuperset(of: migration), "the migration was held at its file throughout the join")
        await engine.releaseGroup(token)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        #expect(try harness.fileSystem.itemInfo(at: EngineRunPathTests.legacyRoot) == nil, "phase 4 removed the prior art's tree")
        #expect(await harness.source.starts.isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: ensureAvailable during legacy migration adopts the prior-art files instead of downloading them (CCR-K1)", .timeLimit(.minutes(1)))
    func ensureAvailableDuringMigration() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(6, seed: 7_300)
        let (harness, bulk) = await EngineLegacyMigrationTransferTests.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "ensureAvailable runs while migration still has the prior art's files to adopt")

        let (result, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.ensureAvailable(scope: .all)
        }

        let report = try result.get()
        #expect(report.present == catalog.count && report.missing == 0, "every asset is available: \(report)")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        #expect(try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog))
        #expect(Set(await bulk.heldUnits).isSuperset(of: migration), "the migration was held at its file throughout the call")
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        #expect(try harness.fileSystem.itemInfo(at: EngineRunPathTests.legacyRoot) == nil, "phase 4 removed the prior art's tree")
        #expect(await harness.source.starts.isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: a later launch that resumes an interrupted legacy migration adopts, never downloads, the prior-art files an explicit sync asks for (L5K-V3-06)", .timeLimit(.minutes(1)))
    func resumedMigrationSync() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(8, seed: 7_400)
        // Launch 1: migration starts and a resolve adopts one prior-art file on demand; then the app is terminated
        // during migration. Shutdown cancels the migration task before the test releases its held unit, so that unit's
        // file is the last one the migration can finish (the hash loop checks cancellation at the next file's first
        // unit), the other files stay queued, and the store closes durably with phase 2 unfinished.
        let first = await EngineLegacyMigrationTransferTests.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
        let firstEngine = first.harness.engine
        let (_, firstMigration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(first.harness, bulk: first.bulk)
        let (resolved, resolveTask) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: firstMigration, bulk: first.bulk) {
            await firstEngine.awaitAsset("legacy0", lane: .userInitiated)
        }
        _ = try resolved.get()
        let stopping = Task { await firstEngine.shutdown() }
        await firstEngine.waitUntil { $0.lifecycle != .running }
        await first.bulk.setHolding(false)
        await stopping.value
        await resolveTask.value
        #expect(await first.harness.source.starts.isEmpty)

        // Launch 2 over what survived: open finds the persisted phase in progress, rebuilds the plan and reports the
        // migration pending again (StoreMigration's open hook), and the engine resumes it.
        let second = await EngineLegacyMigrationTransferTests.launch(disk: first.harness.fileSystem.survivingDisk(), time: time, served: catalog)
        let engine = second.harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(second.harness, bulk: second.bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(second.harness, catalog)
        // At most three files are adopted before the sync: legacy0, the file whose unit launch 1 released during its
        // shutdown, and the one whose unit the start loop above may release (`startHoldingMigration`).
        try #require(!pending.contains("legacy0"), "launch 1's on-demand adoption survived")
        try #require(pending.count >= catalog.count - 3, "launch 2 resumes a migration with the prior art's files still to adopt")

        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: second.bulk) {
            await engine.sync(.force)
        }

        let report = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        #expect(report.fetched == pending.count, "each pending file counts as fetched, answered from the store")
        #expect(await second.harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again, on the resumed launch too")
        #expect(try await EngineLegacyMigrationTransferTests.allPresent(second.harness, catalog))
        #expect(Set(await second.bulk.heldUnits).isSuperset(of: migration), "the resumed migration was held throughout the sync")
        await EngineLegacyMigrationTransferTests.finishMigration(second.harness, bulk: second.bulk)
        await task.value
        #expect(try second.harness.fileSystem.itemInfo(at: EngineRunPathTests.legacyRoot) == nil, "phase 4 removed the prior art's tree")
        await engine.shutdown()
    }

    // MARK: The parked launch run (EngineRuns.swift, the migration loop's `defer`)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: a run that starts while the launch run waits for legacy migration takes its place, so no launch run follows once migration ends", .timeLimit(.minutes(1)))
    func explicitRunTakesTheParkedLaunchRunsPlace() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(4, seed: 7_500)
        let (harness, bulk) = await EngineLegacyMigrationTransferTests.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        #expect(await engine.readForTests { $0.state.migration.launchRunWaiting }, "a sync was due at launch, so the launch run waits for migration")
        #expect(await engine.readForTests { $0.state.lastRunID } == 0, "no run started at launch")

        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.ifDue)
        }
        #expect(outcome.completeReport?.trigger == .explicit, "the sync was due and ran: \(outcome)")
        #expect(!(await engine.readForTests { $0.state.migration.launchRunWaiting }), "the explicit run took the launch run's place")

        // Migration ends after that run: nothing starts, and no flag or waiter is left.
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        let left = await engine.readForTests { engine in
            (runs: engine.state.lastRunID, active: engine.state.run != nil, waiting: engine.state.migration.launchRunWaiting, joiners: engine.state.syncJoiners.count)
        }
        #expect(left.runs == 1, "one run in this launch: the explicit one")
        #expect(!left.active && !left.waiting && left.joiners == 0)
        #expect(await harness.source.manifestRequests.count == 1, "one manifest request in this launch")
        #expect(await harness.source.starts.isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: when legacy migration ends while the run that took the launch run's place is active, no launch run follows it and no flag is left", .timeLimit(.minutes(1)))
    func migrationEndsWhileThatRunIsActive() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(4, seed: 7_600)
        // One more asset the prior art never had keeps the run active: its transfer holds until the test releases it.
        let extraBytes = EngineFixture.bytes(7_699)
        let extra = EngineFixture.entry("fresh", extraBytes)
        let (harness, bulk) = await EngineLegacyMigrationTransferTests.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog, unscripted: [extra])
        await harness.source.script(extra.transferID, [.hold, .stage(extraBytes)])
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)

        let sync = Task { await engine.sync(.force) }
        let held = extra.transferID
        let legacyCount = pending.count
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration, on: engine) { engine in
            guard let run = engine.state.run, run.transferring, run.cursor == run.fetches.count else {
                return false
            }
            return run.fetched == legacyCount && run.outstanding.keys.sorted() == [held] && engine.state.jobs[held]?.active?.handle != nil
        }
        #expect(!(await engine.readForTests { $0.state.migration.launchRunWaiting }), "the explicit run took the launch run's place")

        // Migration ends while that run waits for the held transfer.
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        let during = await engine.readForTests { engine in
            (runs: engine.state.lastRunID, trigger: engine.state.run?.trigger, waiting: engine.state.migration.launchRunWaiting)
        }
        #expect(during.runs == 1 && during.trigger == .explicit && !during.waiting, "the same run goes on, and nothing waits to follow it")

        await harness.source.release(held, with: .progress(received: 0, expected: nil))
        let outcome = await sync.value
        #expect(outcome.completeReport?.trigger == .explicit, "the run completes: \(outcome)")
        let left = await engine.readForTests { engine in
            (runs: engine.state.lastRunID, active: engine.state.run != nil, waiting: engine.state.migration.launchRunWaiting, joiners: engine.state.syncJoiners.count)
        }
        #expect(left.runs == 1, "no launch run followed the explicit one")
        #expect(!left.active && !left.waiting && left.joiners == 0)
        #expect(await harness.source.manifestRequests.count == 1)
        #expect(await harness.source.starts.map(\.id) == [held], "only the asset the prior art never had was downloaded")
        #expect(try harness.fileSystem.itemInfo(at: EngineRunPathTests.legacyRoot) == nil, "phase 4 removed the prior art's tree")
        await engine.shutdown()
    }
}
