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
    /// `count` prior-art entries (standard policy) of `size` bytes each, with their bytes.
    static func catalog(_ count: Int, seed: UInt64, size: Int = 300) -> [(ManifestEntry, Data)] {
        (0..<count).map { index in
            let bytes = EngineFixture.bytes(seed + UInt64(index), count: size)
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

    /// Drives the clock until the engine is idle-silent and checks orchestrator ruling L5K-R16's tripwire there
    /// (`EngineHarness.idleViolations()`): the engine is settled, and every deadline the store reports, a trailing
    /// install among them, is on its heap.
    @available(macOS 15.0, iOS 18.0, *)
    static func expectSettled(_ harness: EngineHarness, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await harness.drive { $0.isIdleSilent }
        let idle = await harness.idleViolations()
        #expect(idle.checked, "the tripwire read the store while the engine was settled", sourceLocation: sourceLocation)
        #expect(idle.violations.isEmpty, "\(idle.violations)", sourceLocation: sourceLocation)
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
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
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
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
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
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
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
        let waitingBeforeStop = await firstEngine.readForTests { $0.state.migration.launchRunWaiting }
        let stopping = Task { await firstEngine.shutdown() }
        await firstEngine.waitUntil { $0.lifecycle != .running }
        await first.bulk.setHolding(false)
        await stopping.value
        await resolveTask.value
        let waitingAfterStop = await firstEngine.readForTests { $0.state.migration.launchRunWaiting }
        #expect(await first.harness.source.starts.isEmpty)
        #expect(waitingBeforeStop, "a sync was due at launch 1, so its launch run waited for migration")
        #expect(!waitingAfterStop, "the migration loop's end clears the flag at shutdown too: no flag is left behind (L5K-C1-05)")

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
        try await EngineLegacyMigrationTransferTests.expectSettled(second.harness)
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
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
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
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    // MARK: One adoption per prior-art file beside a migration that runs at its own pace (L5K-R13)

    /// Launches each race test makes. The interleaving L5K-R13 closes (a job's pre-transfer adoption meets a migration
    /// batch's processing of the same prior-art file, the verifier's probes PK2b and PK8u) depends on scheduling, so each
    /// test repeats a launch rather than hold the migration: before the fix, 8 to 13 of 20 such launches downloaded files.
    static let raceLaunches = 20

    /// Prior-art files per race launch, and their size (PK2b's 150 files of 64 KiB, smaller for the sanitizer's pace).
    static let raceFiles = 120
    static let raceFileSize = 16_384

    /// The store's debug lines of a call that waited for another call's processing of the same prior-art file
    /// (`Migration/LegacyPhases.swift`, L5K-R13): the evidence that a launch reached the race.
    @available(macOS 15.0, iOS 18.0, *)
    static func raceJoins(_ harness: EngineHarness) -> Int {
        harness.tap.lines.filter { $0.message.contains("the same legacy file") }.count
    }

    /// One launch over a prior-art tree of `raceFiles` files with the harness's inline executors, so legacy migration
    /// runs at its own pace beside whatever the test starts right after `start()`; the origin serves every file's bytes,
    /// so only an adoption avoids a transfer.
    @available(macOS 15.0, iOS 18.0, *)
    static func raceLaunch(_ launch: Int, seed: UInt64) async throws -> (harness: EngineHarness, catalog: [(ManifestEntry, Data)]) {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(
            EngineLegacyMigrationTransferTests.raceFiles,
            seed: seed + UInt64(launch) * 1_000,
            size: EngineLegacyMigrationTransferTests.raceFileSize
        )
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        return (harness, catalog)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: ensureAvailable right after start, beside a legacy migration that runs at its own pace, downloads none of the prior-art files, launch after launch (L5K-R13)", .timeLimit(.minutes(1)))
    func ensureAvailableBesideARunningMigration() async throws {
        var joins = 0
        for launch in 0..<EngineLegacyMigrationTransferTests.raceLaunches {
            await Task.yield()
            let (harness, catalog) = try await EngineLegacyMigrationTransferTests.raceLaunch(launch, seed: 7_700)
            let opened = try await harness.start()
            try #require(opened.legacyMigrationPending, "launch \(launch) has a legacy migration")
            let report = try await harness.engine.ensureAvailable(scope: .all).get()
            let starts = await harness.source.starts
            #expect(starts.isEmpty, "launch \(launch): R-STO-11: \(starts.count) of \(catalog.count) prior-art files were downloaded (L5K-R13)")
            #expect(report.present == catalog.count && report.missing == 0, "launch \(launch): every asset is available: \(report)")
            joins += EngineLegacyMigrationTransferTests.raceJoins(harness)
            try await EngineLegacyMigrationTransferTests.expectSettled(harness)
            await harness.engine.shutdown()
        }
        #expect(joins > 0, "no launch reached the race the test exists for: no job's adoption met a migration batch's processing of the same file")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: a user-initiated prefetch group joined right after start, beside a legacy migration that runs at its own pace, downloads none of the prior-art files, launch after launch (L5K-R13)", .timeLimit(.minutes(1)))
    func userInitiatedPrefetchBesideARunningMigration() async throws {
        var joins = 0
        for launch in 0..<EngineLegacyMigrationTransferTests.raceLaunches {
            await Task.yield()
            let (harness, catalog) = try await EngineLegacyMigrationTransferTests.raceLaunch(launch, seed: 7_900)
            let engine = harness.engine
            try #require(try await harness.start().legacyMigrationPending, "launch \(launch) has a legacy migration")
            let token = try await engine.registerGroup(catalog.map(\.0.identifier), lane: .userInitiated).get()
            await engine.awaitCondition { engine in
                guard let group = engine.state.groups[token] else {
                    return false
                }
                return group.claimCursor == group.members.count && group.pending.isEmpty && engine.state.jobs.isEmpty
            }
            let starts = await harness.source.starts
            #expect(starts.isEmpty, "launch \(launch): R-STO-11: \(starts.count) of \(catalog.count) prior-art files were downloaded (L5K-R13)")
            #expect(try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog), "launch \(launch): every prior-art asset is stored")
            joins += EngineLegacyMigrationTransferTests.raceJoins(harness)
            await engine.releaseGroup(token)
            try await EngineLegacyMigrationTransferTests.expectSettled(harness)
            await engine.shutdown()
        }
        #expect(joins > 0, "no launch reached the race the test exists for: no job's adoption met a migration batch's processing of the same file")
    }

    // MARK: The same race, held so that it is reached in every run (L5K-R19, L5K-C2-04)

    /// A launch over two prior-art files with both store executors stepped: the bulk executor holds every unit (the
    /// migration batch is held at a file's hash unit once started: the first one's, or the second one's when the start's
    /// last release met the first, `heldFile`), the metadata executor lets units through until the test holds it. The
    /// origin answers every manifest request "not modified", so no request decodes a manifest on the bulk executor: the
    /// first bulk unit after the migration's is a job's. Nothing is started.
    @available(macOS 15.0, iOS 18.0, *)
    static func heldJoinLaunch(seed: UInt64, time: ManualTimeSource) async throws -> (harness: EngineHarness, bulk: SteppedBlockingExecutor, metadata: SteppedBlockingExecutor, catalog: [(ManifestEntry, Data)]) {
        let catalog = EngineLegacyMigrationTransferTests.catalog(2, seed: seed)
        let bulk = SteppedBlockingExecutor(holding: true)
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            metadata: metadata,
            bulk: bulk,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.scriptTransfers(catalog)
        return (harness, bulk, metadata, catalog)
    }

    /// The prior-art file whose hash unit the held migration batch waits at: the first one still pending, since a batch
    /// takes the files in path order.
    @available(macOS 15.0, iOS 18.0, *)
    static func heldFile(_ harness: EngineHarness, _ catalog: [(ManifestEntry, Data)]) async throws -> ManifestEntry {
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        return try #require(catalog.map(\.0).first { pending.contains($0.identifier) }, "the held batch has a file to adopt")
    }

    /// Drives the race L5K-R13 closes to the join, in an order no scheduling can change: the job's adoption of the one
    /// file `jobHash` names runs its hash, takes the adoption step and holds its placement unit; only then is the batch's
    /// hash of the same file released, so the batch, finding that adoption in flight, must wait for it (the store's debug
    /// line of a call that waited for another call's processing of the same legacy file). The placement stays held until
    /// that line exists: the wait below is for a condition the held placement guarantees, not for a number of rounds.
    /// Then everything is let go.
    @available(macOS 15.0, iOS 18.0, *)
    static func reachTheJoin(
        _ harness: EngineHarness,
        bulk: SteppedBlockingExecutor,
        metadata: SteppedBlockingExecutor,
        migration: Set<Int>,
        jobHash: Set<Int>
    ) async throws -> Int {
        await metadata.setHolding(true)
        for unit in jobHash {
            await bulk.release(unit)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        for unit in migration {
            await bulk.release(unit)
        }
        while EngineLegacyMigrationTransferTests.raceJoins(harness) == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        let joins = EngineLegacyMigrationTransferTests.raceJoins(harness)
        await metadata.setHolding(false)
        await bulk.setHolding(false)
        return joins
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: a user-initiated prefetch group's adoption of a prior-art file the held migration batch is hashing reaches the race in every run, and nothing is downloaded (L5K-R19, L5K-C2-04)", .timeLimit(.minutes(1)))
    func userInitiatedPrefetchReachesTheJoin() async throws {
        let time = ManualTimeSource()
        let (harness, bulk, metadata, catalog) = try await EngineLegacyMigrationTransferTests.heldJoinLaunch(seed: 9_300, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let asset = try await EngineLegacyMigrationTransferTests.heldFile(harness, catalog)
        // The job's adoption of the file the batch holds unhashed processes it at once (L5K-R13): its hash unit is held.
        let token = try await engine.registerGroup([asset.identifier], lane: .userInitiated).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let joins = try await EngineLegacyMigrationTransferTests.reachTheJoin(harness, bulk: bulk, metadata: metadata, migration: migration, jobHash: jobHash)
        await engine.awaitCondition { engine in
            guard let group = engine.state.groups[token] else {
                return false
            }
            return group.claimCursor == group.members.count && group.pending.isEmpty && engine.state.jobs.isEmpty
        }
        let starts = await harness.source.starts

        #expect(joins > 0, "the batch waited for the job's adoption of the same file")
        #expect(starts.isEmpty, "R-STO-11: \(starts.count) prior-art files were downloaded (L5K-R13)")
        await engine.releaseGroup(token)
        await engine.awaitCondition { !$0.state.migration.pending && !$0.state.migration.running }
        #expect(try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog))
        #expect(await harness.source.starts.isEmpty)
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: ensureAvailable's adoption of a prior-art file the held migration batch is hashing reaches the race in every run, and nothing is downloaded (L5K-R19, L5K-C2-04)", .timeLimit(.minutes(1)))
    func ensureAvailableReachesTheJoin() async throws {
        let time = ManualTimeSource()
        let (harness, bulk, metadata, catalog) = try await EngineLegacyMigrationTransferTests.heldJoinLaunch(seed: 9_400, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let asset = try await EngineLegacyMigrationTransferTests.heldFile(harness, catalog)
        // ensureAvailable's manifest request is answered "not modified" (nothing to decode), so its job's adoption of the
        // file the batch holds unhashed, which processes it at once (L5K-R13), submits the first bulk unit after the
        // migration's: the job's hash unit, held.
        let ensure = Task {
            await engine.ensureAvailable(scope: .identifiers([asset.identifier]))
        }
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let joins = try await EngineLegacyMigrationTransferTests.reachTheJoin(harness, bulk: bulk, metadata: metadata, migration: migration, jobHash: jobHash)
        let report = try await ensure.value.get()
        let starts = await harness.source.starts

        #expect(joins > 0, "the batch waited for the job's adoption of the same file")
        #expect(report.present == 1 && report.missing == 0, "the asset is available: \(report)")
        #expect(starts.isEmpty, "R-STO-11: \(starts.count) prior-art files were downloaded (L5K-R13)")
        await engine.awaitCondition { !$0.state.migration.pending && !$0.state.migration.running }
        #expect(try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog))
        #expect(await harness.source.starts.isEmpty)
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    // MARK: The install rate during migration (L5K-R14)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: during legacy migration a bulk sync whose jobs adopt 100 prior-art files installs only the snapshots the install-rate limiter allows (ARCHITECTURE §5), and a user-initiated job's adoption installs at once (L5K-R14)", .timeLimit(.minutes(1)))
    func adoptionsKeepTheInstallRate() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(100, seed: 8_100)
        // Four prior-art pages the bulk sync leaves alone (on demand), for the user-initiated lane afterwards.
        let pages = (0..<4).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(8_300 + UInt64(index))
            return (EngineFixture.entry("page\(index)", bytes, policy: .onDemand), bytes)
        }
        let bulk = SteppedBlockingExecutor(holding: true)
        // ARCHITECTURE §5's interval (0.1 s, ≤ 10 Hz); the clock never moves, so the limiter allows no second bulk install.
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
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "the sync's jobs have the prior art's files to adopt")

        let beforeSync = await harness.sink.offeredKeys.count
        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        let report = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        let syncInstalls = await harness.sink.offeredKeys.count - beforeSync

        #expect(report.fetched == pending.count, "the bulk jobs adopted every pending file")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        // The run's apply installs at once (ARCHITECTURE §5); each bulk-lane adoption publishes at bulk urgency, which
        // the limiter coalesces into the trailing install it schedules, so the 100 adoptions add no install of their own.
        #expect(syncInstalls <= 2, "\(syncInstalls) snapshot installs for a sync that adopted \(pending.count) files: one per adoption bypasses the limiter")

        // The install window is still closed (the clock never moved): a user-initiated job's adoption installs at once.
        let beforePages = await harness.sink.offeredKeys.count
        let token = try await engine.registerGroup(pages.map(\.0.identifier), lane: .userInitiated).get()
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration, on: engine) { engine in
            guard let group = engine.state.groups[token] else {
                return false
            }
            return group.claimCursor == group.members.count && group.pending.isEmpty && engine.state.jobs.isEmpty
        }
        let pageInstalls = await harness.sink.offeredKeys.count - beforePages
        let installed = await harness.sink.installed

        #expect(pageInstalls >= pages.count, "each user-initiated adoption installed its snapshot at once: \(pageInstalls) installs for \(pages.count) adoptions")
        #expect(pages.allSatisfy { installed.location(for: $0.0.identifier, extensions: []) != nil }, "the readers see every adopted page")
        #expect(await harness.source.starts.isEmpty)
        #expect(Set(await bulk.heldUnits).isSuperset(of: migration), "the migration was held throughout")
        await engine.releaseGroup(token)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    // MARK: A job promoted during its adoption (L5K-R18)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: a prefetch job promoted to the user-initiated lane while its pre-transfer adoption runs answers its user-initiated asker only once the readers' snapshot holds the asset (L5K-R18)", .timeLimit(.minutes(1)))
    func promotedAdoptionInstallsAtOnce() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(2, seed: 9_200)
        let asset = catalog[1].0
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        // A prefetch job adopts the prior-art file before any bytes, at bulk urgency (L5K-R14); its hash unit is held.
        let token = try await engine.registerGroup([asset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        // ensureAvailable joins that job while the adoption runs (its own bulk units, a manifest's decode, are let
        // through): the job is promoted to the user-initiated lane.
        let ensure = Task {
            await engine.ensureAvailable(scope: .identifiers([asset.identifier]))
        }
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration.union(jobHash), on: engine) { engine in
            engine.state.jobs[asset.transferID]?.lane == .userInitiated
        }
        // The adoption goes on; every unit but the migration's is let through until ensureAvailable returns.
        let (result, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await ensure.value
        }
        let report = try result.get()
        // Read before the clock moves: a bulk-urgency publication would reach the readers only at the trailing install.
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, [asset.identifier])

        #expect(report.present == 1 && report.missing == 0, "ensureAvailable reports the asset available: \(report)")
        #expect(unseen.isEmpty, "R-STO-13: ensureAvailable, a user-initiated asker, returned before the readers' snapshot held the asset its job adopted (ARCHITECTURE §5)")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        await engine.releaseGroup(token)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    // MARK: No hot loop around a store call (L5K-R17)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-14: while a job's adoption holds the last claimed prior-art file the migration loop waits for it, never calling migrateLegacy again at once (L5K-R17, L5K-R22, PSPIN)", .timeLimit(.minutes(1)))
    func migrationLoopWaitsForTheLastAdoption() async throws {
        let time = ManualTimeSource()
        // Three files: the batch holds the first pending one at its hash; a prefetch job adopts the last pending one,
        // which is still queued whichever file the batch holds (a batch takes the files in path order).
        let catalog = EngineLegacyMigrationTransferTests.catalog(3, seed: 9_100)
        let (harness, bulk) = await EngineLegacyMigrationTransferTests.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "premise: the held batch's file and every file after it are pending: \(pending.count)")
        let jobAsset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let token = try await engine.registerGroup([jobAsset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let callsBefore = await engine.readForTests { $0.state.migration.batchCalls }
        // The batch adopts the other pending files; the migration then waits for the job's adoption of the last claimed
        // file (the store's line of that wait). A loop that no longer waits calls again instead, and the count rises.
        let waited = try await EngineLegacyMigrationTransferTests.releaseUntilTheBatchWaits(harness, bulk: bulk, keeping: jobHash, callsBefore: callsBefore)
        // An observation window that releases every other unit and yields: a loop that returned at once would call again
        // in about every round (PSPIN-c3 saw 35 to 46 calls); the fixed loop makes none whatever its length, so the bound
        // below never depends on it.
        for _ in 0..<2_000 {
            for unit in await bulk.heldUnits where !jobHash.contains(unit) {
                await bulk.release(unit)
            }
            await Task.yield()
        }
        let callsWhileHeld = await engine.readForTests { $0.state.migration.batchCalls } - callsBefore
        for unit in jobHash {
            await bulk.release(unit)
        }
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        let calls = await engine.readForTests { $0.state.migration.batchCalls } - callsBefore

        #expect(waited, "premise: the migration waited for the job's adoption of the last claimed file (the store's line of that wait)")
        #expect(callsWhileHeld <= 1, "R-SYN-14: \(callsWhileHeld) migrateLegacy calls while the job's adoption held the last file: a hot loop (L5K-C2-01)")
        #expect(calls <= 2, "\(calls) calls to finish the migration once that adoption ended")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        #expect(try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog))
        await engine.releaseGroup(token)
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: shutdown while the migration waits for a job's adoption of the last claimed prior-art file returns, and leaves no migration flag behind (L5K-R17, L5K-R22, row k-7)", .timeLimit(.minutes(1)))
    func shutdownWhileTheMigrationWaits() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(4, seed: 9_750)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "premise: the held batch's file and every file after it are pending: \(pending.count)")
        let jobAsset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        _ = try await engine.registerGroup([jobAsset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let callsBefore = await engine.readForTests { $0.state.migration.batchCalls }
        let waited = try await EngineLegacyMigrationTransferTests.releaseUntilTheBatchWaits(harness, bulk: bulk, keeping: jobHash, callsBefore: callsBefore)
        // Shutdown cancels the job's driver, whose hash checks cancellation, and closes the store, which resumes the
        // migration's wait through that adoption (row k-7); the held units are let go once the engine stops.
        let stopping = Task {
            await engine.shutdown()
        }
        await engine.awaitCondition { !$0.isRunning }
        await bulk.setHolding(false)
        await stopping.value
        let flags = await engine.readForTests { ($0.state.migration.running, $0.state.migration.launchRunWaiting) }

        #expect(waited, "premise: the migration waited for the job's adoption of the last claimed file")
        #expect(!flags.0, "the migration loop ended")
        #expect(!flags.1, "no launch run is left waiting for it")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: nothing was downloaded")
    }

    // MARK: Every coalesced publication reaches the readers (L5K-R16)

    /// The ids of `ids` the readers' snapshot (the sink's installed snapshot, what `lookup` reads) does not hold.
    @available(macOS 15.0, iOS 18.0, *)
    static func unseen(_ harness: EngineHarness, _ ids: some Sequence<AssetID>) async -> [AssetID] {
        let installed = await harness.sink.installed
        return ids.filter { installed.location(for: $0, extensions: []) == nil }.sorted()
    }

    /// A launch over `catalog`'s prior-art tree with ARCHITECTURE §5's install interval (0.1 s): a bulk-lane adoption
    /// publishes at bulk urgency, and only the engine's alarm runs the trailing install it leaves due. `commitInterval`
    /// is the store's commit window (the production 0.25 s for PR14b's shape). Nothing is started.
    @available(macOS 15.0, iOS 18.0, *)
    static func rateLimitedLaunch(
        _ catalog: [(ManifestEntry, Data)],
        time: ManualTimeSource,
        commitInterval: TimeInterval = 0
    ) async throws -> (harness: EngineHarness, bulk: SteppedBlockingExecutor) {
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            bulk: bulk,
            commitInterval: commitInterval,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        return (harness, bulk)
    }

    /// Drives the clock until the engine holds no deadline on its heap and no alarm turn's store work is in flight, for
    /// a test whose migration is held (so the engine never becomes idle-silent). Heap emptiness alone is a weaker
    /// condition than the readers' check needs: the alarm takes the store's entry off the heap before its
    /// `runDueWork()`, which installs the trailing snapshot (L5K-R2 pattern (a)), and that work may arm the next store
    /// deadline. Every wait ends on cancellation.
    @available(macOS 15.0, iOS 18.0, *)
    static func runStoreWork(_ harness: EngineHarness) async throws {
        let engine = harness.engine
        while true {
            try await harness.drive { $0.scheduledDeadlines == 0 }
            await engine.awaitCondition { $0.state.storeWorkRuns == 0 }
            if await engine.readForTests({ $0.state.heap.count == 0 && $0.state.storeWorkRuns == 0 }) {
                return
            }
            try Task.checkCancellation()
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: the prior-art files a bulk sync's jobs adopt during legacy migration reach the readers' snapshot once the install window has passed, and the trailing installs stay within the install rate (L5K-R16, PR14a)", .timeLimit(.minutes(1)))
    func syncAdoptionsReachTheReaders() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(20, seed: 8_500)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "the sync's jobs have the prior art's files to adopt")

        let start = time.monotonicNow()
        let beforeSync = await harness.sink.offeredKeys.count
        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        let report = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        let syncInstalls = await harness.sink.offeredKeys.count - beforeSync
        let unseenAtTheSyncsEnd = await EngineLegacyMigrationTransferTests.unseen(harness, pending)
        // The clock passes the install window while the migration is still held, so no batch publishes and no launch run
        // applies: only the funnel's re-read of the store's deadline can have put the trailing install on the alarm.
        try await EngineLegacyMigrationTransferTests.runStoreWork(harness)
        let unseenWhileHeld = await EngineLegacyMigrationTransferTests.unseen(harness, pending)
        let held = Set(await bulk.heldUnits).isSuperset(of: migration)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        // The clock passes the install window: only the engine's alarm runs the trailing install the adoptions left due.
        try await harness.drive { $0.isIdleSilent }
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, catalog.map(\.0.identifier))
        let installs = await harness.sink.offeredKeys.count - beforeSync
        let elapsed = time.monotonicNow().seconds(since: start)
        let idle = await harness.idleViolations()

        #expect(report.fetched == pending.count, "the bulk jobs adopted every pending file")
        #expect(!unseenAtTheSyncsEnd.isEmpty, "premise: the adoptions published at bulk urgency inside the install window, so the trailing install was still due when the sync returned")
        #expect(held, "the migration was held until the readers were read")
        #expect(unseenWhileHeld.isEmpty, "R-STO-13: \(unseenWhileHeld.count) of \(pending.count) files the sync's jobs adopted stayed out of the readers' snapshot past the install window while the migration was held (L5K-C3-04)")
        #expect(syncInstalls <= 2, "\(syncInstalls) snapshot installs while the clock stood still: one per adoption bypasses the limiter")
        #expect(unseen.isEmpty, "R-STO-13: \(unseen.count) of \(catalog.count) adopted prior-art files never reached the readers' snapshot: \(unseen)")
        #expect(installs <= syncInstalls + Int((elapsed / 0.1).rounded(.up)) + 1, "the trailing installs stay within the limiter: \(installs) installs over \(elapsed) s")
        #expect(idle.checked, "the tripwire read the store while the engine was settled")
        #expect(idle.violations.isEmpty, "\(idle.violations)")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: during legacy migration a page a user resolves is in the readers' snapshot at once, and the neighbours a prefetch group's jobs adopt reach it once the install window has passed (L5K-R16, PR14b)", .timeLimit(.minutes(1)))
    func prefetchedNeighboursReachTheReaders() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(12, seed: 8_600)
        let page = catalog[11].0.identifier
        let neighbours = catalog[0..<11].map(\.0.identifier)
        // The store's production windows: commit 0.25 s, install 0.1 s.
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time, commitInterval: 0.25)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)

        let (resolved, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.awaitAsset(page, lane: .userInitiated)
        }
        _ = try resolved.get()
        let pageUnseen = await EngineLegacyMigrationTransferTests.unseen(harness, [page])
        let coalescedFrom = time.monotonicNow()
        let installsBefore = await harness.sink.offeredKeys.count
        let token = try await engine.registerGroup(neighbours, lane: .prefetch).get()
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration, on: engine) { engine in
            guard let group = engine.state.groups[token] else {
                return false
            }
            return group.claimCursor == group.members.count && group.pending.isEmpty && engine.state.jobs.isEmpty
        }
        let unseenAtTheJoinsEnd = await EngineLegacyMigrationTransferTests.unseen(harness, neighbours)
        // The clock passes the install window while the migration is still held, so no batch and no launch run installs
        // anything: only the engine's alarm can run the trailing install the neighbours' adoptions left due.
        try await EngineLegacyMigrationTransferTests.runStoreWork(harness)
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, neighbours)
        let installs = await harness.sink.offeredKeys.count - installsBefore
        let elapsed = time.monotonicNow().seconds(since: coalescedFrom)
        let held = Set(await bulk.heldUnits).isSuperset(of: migration)

        #expect(installs <= Int((elapsed / 0.1).rounded(.up)) + 1, "the prefetch lane's installs stay within the limiter: \(installs) installs over \(elapsed) s")
        #expect(pageUnseen.isEmpty, "a user-initiated resolve's adoption is in the readers' snapshot when it returns")
        #expect(!unseenAtTheJoinsEnd.isEmpty, "premise: the prefetch lane's adoptions published at bulk urgency inside the install window")
        #expect(unseen.isEmpty, "R-STO-13: \(unseen.count) of \(neighbours.count) prefetched neighbours never reached the readers' snapshot: \(unseen)")
        #expect(held, "the migration was held throughout")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        await engine.releaseGroup(token)
        // Phase 3's durable commit waits for the store's commit window, so the clock moves while migration ends.
        await harness.withClock {
            await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        }
        await task.value
        try await harness.drive { $0.isIdleSilent }
        let idle = await harness.idleViolations()
        #expect(idle.checked && idle.violations.isEmpty, "settled: \(idle.checked), \(idle.violations)")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: the prior-art files legacy migration's own batches adopt after a sync took the parked launch run's place reach the readers' snapshot once the install window has passed (L5K-R16, PR14c, probes I and J)", .timeLimit(.minutes(1)))
    func migrationAdoptionsReachTheReaders() async throws {
        let time = ManualTimeSource()
        let standard = EngineLegacyMigrationTransferTests.catalog(12, seed: 8_700)
        // On-demand pages the sync's run does not plan: only migration's batches adopt them.
        let pages = (0..<8).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(8_800 + UInt64(index))
            return (EngineFixture.entry("page\(index)", bytes, policy: .onDemand), bytes)
        }
        let pageIDs = pages.map(\.0.identifier)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(standard + pages, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)

        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        _ = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        let coalescedFrom = time.monotonicNow()
        let installsBefore = await harness.sink.offeredKeys.count
        let waiting = await engine.readForTests { $0.state.migration.launchRunWaiting }
        // Probe J: the sync's own trailing install runs first, while the migration is still held.
        try await EngineLegacyMigrationTransferTests.runStoreWork(harness)
        let pagesBefore = await EngineLegacyMigrationTransferTests.unseen(harness, pageIDs)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        // Migration's batches published the pages at bulk urgency inside the install window that trailing install opened;
        // the sync took the launch run's place, so no launch run's apply follows migration to install them.
        try await harness.drive { $0.isIdleSilent }
        let unseenPages = await EngineLegacyMigrationTransferTests.unseen(harness, pageIDs)
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, (standard + pages).map(\.0.identifier))
        let installs = await harness.sink.offeredKeys.count - installsBefore
        let elapsed = time.monotonicNow().seconds(since: coalescedFrom)
        let runs = await engine.readForTests { $0.state.lastRunID }
        let idle = await harness.idleViolations()
        #expect(installs <= Int((elapsed / 0.1).rounded(.up)) + 1, "the bulk installs stay within the limiter: \(installs) installs over \(elapsed) s")

        #expect(!waiting, "the sync took the parked launch run's place (L5K-R1)")
        #expect(pagesBefore.count == pages.count, "premise: no page was adopted before migration went on")
        #expect(unseenPages.isEmpty, "R-STO-13: \(unseenPages.count) of \(pages.count) pages migration adopted never reached the readers' snapshot: \(unseenPages)")
        #expect(unseen.isEmpty, "every prior-art file is in the readers' snapshot: \(unseen)")
        #expect(runs == 1, "no launch run followed migration")
        #expect(idle.checked && idle.violations.isEmpty, "settled: \(idle.checked), \(idle.violations)")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: a download launch reconciliation adopts from staging at bulk urgency reaches the readers' snapshot once the install window has passed, on a launch with no sync due (L5K-R16, enumeration)", .timeLimit(.minutes(1)))
    func reconciledAdoptionReachesTheReaders() async throws {
        // Another publication the enumeration found without a re-arm: launch reconciliation publishes a download the OS
        // completed while the app was dead at bulk urgency, while the engine is still starting; no launch run follows
        // (the sync is not due), so only the alarm can install it.
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(9_500)
        let entry = EngineHarness.onDemand("done", bytes)
        let first = try await EngineLaunchTests.firstLifetime([entry], time: time)
        let fileSystem = FakeFileSystem(disk: first.fileSystem.survivingDisk(), time: time)
        let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 4), kind: .partial)
        try fileSystem.write(bytes, to: StoreLayout(base: EngineHarness.base).stagingURL(name), mode: .truncate)
        let source = FakeRemoteSource(capabilities: EngineLaunchTests.background)
        await source.scriptReattached([ReattachedTransfer(name: name, isRunning: false, bytesReceived: Int64(bytes.count))])
        let second = EngineHarness.make(time: time, source: source, installInterval: 0.1, fileSystem: fileSystem)
        try await second.start()
        let runs = await second.engine.readForTests { $0.state.lastRunID }
        try await second.drive { $0.isIdleSilent }
        let unseen = await EngineLegacyMigrationTransferTests.unseen(second, [entry.identifier])
        let idle = await second.idleViolations()

        #expect(runs == 0, "premise: no launch run, whose apply would install the publication")
        #expect(try await second.view().records["done"]?.referencedBlob != nil, "adopted from staging")
        #expect(unseen.isEmpty, "R-STO-13: the adopted download never reached the readers' snapshot")
        #expect(idle.checked && idle.violations.isEmpty, "settled: \(idle.checked), \(idle.violations)")
        #expect(await source.starts.isEmpty, "adopted, not downloaded again")
        await second.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: an older answer of the store's deadline that the engine applies after a newer one never takes a trailing install off the heap (L5K-R16, crossed re-reads)", .timeLimit(.minutes(1)))
    func crossedDeadlineReadsKeepTheTrailingInstall() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(4, seed: 8_900)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        // A known store state, set up through the store itself: whatever the start left due is done (the migration may
        // have adopted its first file before the hold), then a user-initiated adoption installs at once, which closes the
        // install window, and its records are committed, so nothing is due.
        time.advance(by: 1)
        _ = await harness.store.runDueWork()
        let warm = catalog[2].0.identifier
        let (warmed, warmTask) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            (try? await harness.store.adoptLegacyNow(warm)) ?? nil
        }
        _ = await harness.store.runDueWork()
        try #require(warmed != nil, "premise: the user-initiated adoption bound its asset")
        try #require(await harness.store.nextDeadline() == nil, "premise: the store has nothing due before the reads")

        // Re-read A answers "nothing due" and waits before the engine applies that answer, as the answer of a task of
        // lower priority can wait behind other engine turns.
        await engine.holdNextStoreDeadlineRead()
        let older = Task {
            await engine.refreshStoreDeadline()
        }
        await engine.awaitCondition { $0.storeDeadlineReadHeld }
        // Meanwhile a bulk-urgency adoption inside the install window leaves the trailing install due, and re-read B
        // answers it and is applied first.
        let id = catalog[3].0.identifier
        let (adopted, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            (try? await harness.store.adoptLegacyNow(id, urgency: .bulk)) ?? nil
        }
        let due = try #require(await harness.store.nextDeadline(), "premise: the adoption left the trailing install due")
        // The alarm's turns wait until the older answer has been applied, so the heap shows what the two answers left.
        await engine.holdAlarmTurns()
        await engine.refreshStoreDeadline()
        let afterNewer = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        // Re-read A applies its older answer last.
        await engine.releaseStoreDeadlineRead()
        await older.value
        let afterOlder = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        await engine.releaseAlarmTurns()
        try await EngineLegacyMigrationTransferTests.runStoreWork(harness)
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, [id])

        #expect(adopted != nil, "the adoption bound the asset")
        #expect(afterNewer == due, "the newer answer scheduled the store's due work")
        #expect(afterOlder == due, "R-STO-13: the older answer took the store's due work, the trailing install among it, off the heap: \(String(describing: afterOlder))")
        #expect(unseen.isEmpty, "R-STO-13: the trailing install never ran, so the readers miss the adopted asset")
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await warmTask.value
        await task.value
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    // MARK: A store call returns right after a coalesced publication (L5K-R20)

    /// Whether the store logged that a migration call waits for an adopt-on-demand of the last claimed legacy files
    /// (row k-7).
    @available(macOS 15.0, iOS 18.0, *)
    static func batchWaitLogged(_ harness: EngineHarness) -> Bool {
        harness.tap.lines.contains { $0.message.contains("a migration batch waits for an adopt-on-demand") }
    }

    /// Releases every unit of `bulk` outside `kept` as it arrives until the store logs that a migration call waits for an
    /// adopt-on-demand of the last claimed legacy files, or until the migration loop made `calls` more calls than `before`
    /// (a loop that no longer waits calls again instead), and returns whether the line was logged. While `kept` holds that
    /// adoption the line is guaranteed, so this waits for a condition, not for a number of rounds; it ends on
    /// cancellation (orchestrator ruling L5K-R22).
    @available(macOS 15.0, iOS 18.0, *)
    static func releaseUntilTheBatchWaits(
        _ harness: EngineHarness,
        bulk: SteppedBlockingExecutor,
        keeping kept: Set<Int>,
        callsBefore before: Int,
        calls: Int = 2
    ) async throws -> Bool {
        let engine = harness.engine
        while !EngineLegacyMigrationTransferTests.batchWaitLogged(harness) {
            if await engine.readForTests({ $0.state.migration.batchCalls }) - before >= calls {
                return EngineLegacyMigrationTransferTests.batchWaitLogged(harness)
            }
            for unit in await bulk.heldUnits where !kept.contains(unit) {
                await bulk.release(unit)
            }
            try Task.checkCancellation()
            await Task.yield()
        }
        return true
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: the prior-art files a migration batch adopted reach the readers' snapshot within about two install intervals while the migration waits for an adopt-on-demand of the last claimed file (L5K-R20, KC3-WAITWINDOW)", .timeLimit(.minutes(1)))
    func batchAdoptionsReachTheReadersWhileTheMigrationWaits() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(4, seed: 9_600)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "premise: the held batch's file and every file after it are pending: \(pending.count)")
        // A prefetch job adopts the last pending file before any bytes; that file is still queued whichever file the batch
        // holds (a batch takes the files in path order). Its hash unit is held.
        let jobAsset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let token = try await engine.registerGroup([jobAsset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let batchIDs = pending.subtracting([jobAsset.identifier])
        let callsBefore = await engine.readForTests { $0.state.migration.batchCalls }
        // The batch adopts every other pending file and publishes them at bulk urgency inside the install window (the clock
        // stands still after open's install); the migration then waits for the job's adoption of the last claimed file.
        let waited = try await EngineLegacyMigrationTransferTests.releaseUntilTheBatchWaits(harness, bulk: bulk, keeping: jobHash, callsBefore: callsBefore)
        let stillPending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        let unseenAtTheWait = await EngineLegacyMigrationTransferTests.unseen(harness, batchIDs)
        let from = time.monotonicNow()
        // The clock passes the install window while the job's adoption still holds the last file: only the engine's alarm
        // can run the trailing install the batch's publication left due.
        try await EngineLegacyMigrationTransferTests.runStoreWork(harness)
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, batchIDs)
        let elapsed = time.monotonicNow().seconds(since: from)
        let held = Set(await bulk.heldUnits).isSuperset(of: jobHash)

        #expect(waited, "premise: the migration waited for the job's adoption of the last claimed file (L5K-R17)")
        #expect(stillPending.isDisjoint(with: batchIDs), "premise: the batch adopted its files before the wait")
        #expect(!unseenAtTheWait.isEmpty, "premise: the batch published at bulk urgency inside the install window")
        #expect(unseen.isEmpty, "R-STO-13: \(unseen.count) of \(batchIDs.count) files the batch adopted stayed out of the readers' snapshot past the install window while the migration waited (L5K-C3-01)")
        #expect(elapsed <= 2 * 0.1 + 1e-6, "within about two install intervals of the publication: \(elapsed) s")
        #expect(held, "the job's adoption held the last claimed file throughout")
        for unit in jobHash {
            await bulk.release(unit)
        }
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        await engine.releaseGroup(token)
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: the prior-art files the last migration batch adopted reach the readers' snapshot within about two install intervals while phases 3 and 4 still run (L5K-R20)", .timeLimit(.minutes(1)))
    func lastBatchAdoptionsReachTheReadersDuringPhasesThreeAndFour() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(3, seed: 9_650)
        let ids = catalog.map(\.0.identifier)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        _ = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        // Every bulk unit is let through until every prior-art file is in the store: the batch's hashes (its placements run
        // on the metadata executor). Phase 3 runs no bulk unit at this size, so the next held unit is phase 4's (its
        // removal): nothing else submits one now (no job, no run: the launch run waits for the migration).
        while true {
            if try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog) {
                break
            }
            try await bulk.requireHeldUnits(atLeast: 1)
            if try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog) {
                break
            }
            for unit in await bulk.heldUnits {
                await bulk.release(unit)
            }
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let phaseFour = Set(await bulk.heldUnits)
        let running = await engine.readForTests { $0.state.migration.running && $0.state.migration.pending }
        let from = time.monotonicNow()
        // The clock passes the install window while phase 4 is held: a trailing install the last batch's publication left
        // due could run only on the engine's alarm, which cannot know of it before the migration call returns.
        try await EngineLegacyMigrationTransferTests.runStoreWork(harness)
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, ids)
        let elapsed = time.monotonicNow().seconds(since: from)
        let held = Set(await bulk.heldUnits).isSuperset(of: phaseFour)

        #expect(running, "premise: the migration had not finished (phase 4 held)")
        #expect(unseen.isEmpty, "R-STO-13: \(unseen.count) of \(ids.count) files the last batch adopted stayed out of the readers' snapshot past the install window while phases 3 and 4 ran (L5K-C3-01)")
        #expect(elapsed <= 2 * 0.1 + 1e-6, "within about two install intervals of the publication: \(elapsed) s")
        #expect(held, "phase 4 stayed held throughout")
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    // MARK: User-initiated answers come after the install (L5K-R21)

    /// A launch over `entries`' prior-art tree with ARCHITECTURE §5's install interval (0.1 s), a bulk executor that holds
    /// every unit and `gate`'s planner. The origin answers every manifest request "not modified", so `ensureAvailable`
    /// plans against the applied (legacy) manifest and applies nothing, and it serves the bytes of `served`. Nothing is
    /// started.
    @available(macOS 15.0, iOS 18.0, *)
    static func gatedLaunch(
        _ entries: [(ManifestEntry, Data)],
        served: [(ManifestEntry, Data)],
        time: ManualTimeSource,
        gate: MigrationPlannerGate
    ) async throws -> (harness: EngineHarness, bulk: SteppedBlockingExecutor) {
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(entries, time: time),
            time: time,
            bulk: bulk,
            planner: MigrationGatedPlanner(gate: gate),
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.scriptTransfers(served)
        return (harness, bulk)
    }

    /// Releases every unit of `bulk` outside `kept` as it arrives until `gate`'s planner holds a plan. The gate's entry is
    /// guaranteed once the operation it holds runs, so this waits for a condition, not for a number of rounds; it ends
    /// on cancellation.
    @available(macOS 15.0, iOS 18.0, *)
    static func releaseUntilPlanned(_ bulk: SteppedBlockingExecutor, keeping kept: Set<Int>, gate: MigrationPlannerGate) async throws {
        while !gate.entered {
            for unit in await bulk.heldUnits where !kept.contains(unit) {
                await bulk.release(unit)
            }
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: ensureAvailable that joins a prefetch job while the job's pre-transfer read re-arms the store's deadline after a bulk adoption returns only once the readers' snapshot holds the asset (L5K-R21, PE5)", .timeLimit(.minutes(1)))
    func promotionDuringTheReArmInstallsBeforeTheAnswer() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(2, seed: 9_700)
        let asset = catalog[1].0
        let gate = MigrationPlannerGate()
        defer {
            gate.open()
        }
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.gatedLaunch(catalog, served: catalog, time: time, gate: gate)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        // A prefetch job adopts the asset's prior-art file before any bytes, at bulk urgency; its hash unit is held.
        let token = try await engine.registerGroup([asset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        // ensureAvailable reads its planning view while the asset is absent, and its plan is held there.
        gate.arm()
        let ensure = Task {
            await engine.ensureAvailable(scope: .identifiers([asset.identifier]))
        }
        try await EngineLegacyMigrationTransferTests.releaseUntilPlanned(bulk, keeping: migration.union(jobHash), gate: gate)
        let plannedAbsent = try await EngineLegacyMigrationTransferTests.pending(harness, catalog).contains(asset.identifier)
        // The job's adoption ends; its re-read of the store's deadline (RE-S40) is held once the store answered.
        await engine.holdNextStoreDeadlineRead()
        for unit in jobHash {
            await bulk.release(unit)
        }
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration, on: engine) { engine in
            engine.storeDeadlineReadHeld || engine.state.jobs[asset.transferID] == nil
        }
        let heldRead = await engine.readForTests { $0.storeDeadlineReadHeld }
        let laneAtTheHold = await engine.readForTests { $0.state.jobs[asset.transferID]?.lane }
        // ensureAvailable registers its group during that read: it joins the job, which becomes user-initiated.
        gate.open()
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration, on: engine) { engine in
            engine.state.jobs[asset.transferID]?.lane == .userInitiated || engine.state.jobs[asset.transferID] == nil
        }
        let promoted = await engine.readForTests { $0.state.jobs[asset.transferID]?.lane == .userInitiated }
        await engine.releaseStoreDeadlineRead()
        let (result, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await ensure.value
        }
        let report = try result.get()
        // Read before the clock moves: a bulk-urgency publication would reach the readers only at the trailing install.
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, [asset.identifier])

        #expect(plannedAbsent, "premise: ensureAvailable planned while the asset was absent")
        #expect(heldRead, "premise: the job's re-read of the store's deadline awaited the store")
        #expect(laneAtTheHold == .prefetch, "premise: the job was still a prefetch job when its read ended")
        #expect(promoted, "premise: ensureAvailable joined the job during that re-read")
        #expect(report.present == 1 && report.missing == 0, "ensureAvailable reports the asset available: \(report)")
        #expect(unseen.isEmpty, "R-STO-13: ensureAvailable, a user-initiated asker, returned before the readers' snapshot held the asset its job adopted (L5K-C3-00)")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        await engine.releaseGroup(token)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: a job of two ids promoted while its read of the second id runs answers its user-initiated asker of the first id, adopted at bulk urgency, only once the readers' snapshot holds it (L5K-R21)", .timeLimit(.minutes(1)))
    func promotionDuringALaterReadInstallsBeforeTheAnswer() async throws {
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(9_800)
        // A file the held batch takes first, then one content under two ids: `first`'s prior-art file holds that content,
        // `second`'s does not verify (other bytes under the same checksum), so its read answers nothing, and the job then
        // downloads the content for it.
        let other = EngineLegacyMigrationTransferTests.catalog(1, seed: 9_810)[0]
        let first = EngineFixture.entry("legacy1", bytes)
        let second = EngineFixture.entry("legacy2", bytes)
        let gate = MigrationPlannerGate()
        defer {
            gate.open()
        }
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.gatedLaunch(
            [other, (first, bytes), (second, EngineFixture.bytes(9_801))],
            served: [other, (first, bytes), (second, bytes)],
            time: time,
            gate: gate
        )
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pendingAtStart = try await harness.view().records[first.identifier]?.referencedBlob == nil
        try #require(first.transferID == second.transferID, "premise: one content, one job")
        // A prefetch job of both ids reads `first` first: its adoption's hash unit is held.
        let token = try await engine.registerGroup([first.identifier, second.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let firstHash = Set(await bulk.heldUnits).subtracting(migration)
        // ensureAvailable of `first` reads its planning view while `first` is absent, and its plan is held there.
        gate.arm()
        let ensure = Task {
            await engine.ensureAvailable(scope: .identifiers([first.identifier]))
        }
        try await EngineLegacyMigrationTransferTests.releaseUntilPlanned(bulk, keeping: migration.union(firstHash), gate: gate)
        // `first` is adopted at bulk urgency; the job's read of `second` then hashes its file, and that unit is held.
        for unit in firstHash {
            await bulk.release(unit)
        }
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let secondHash = Set(await bulk.heldUnits).subtracting(migration)
        let firstStored = try await harness.view().records[first.identifier]?.referencedBlob != nil
        // ensureAvailable registers its group meanwhile: it joins the job, which becomes user-initiated.
        gate.open()
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration.union(secondHash), on: engine) { engine in
            engine.state.jobs[first.transferID]?.lane == .userInitiated || engine.state.jobs[first.transferID] == nil
        }
        let promoted = await engine.readForTests { $0.state.jobs[first.transferID]?.lane == .userInitiated }
        // The read of `second` ends without a location; the job answers `first` from the store.
        let (result, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await ensure.value
        }
        let report = try result.get()
        // Read before the clock moves: a bulk-urgency adoption would reach the readers only at the trailing install.
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, [first.identifier])

        #expect(pendingAtStart, "premise: `first` was still to adopt after the start")
        #expect(firstStored, "premise: the job adopted `first` before its read of `second`")
        #expect(promoted, "premise: ensureAvailable joined the job during the read of `second`")
        #expect(report.present == 1 && report.missing == 0, "ensureAvailable reports `first` available: \(report)")
        #expect(unseen.isEmpty, "R-STO-13: ensureAvailable, a user-initiated asker, returned before the readers' snapshot held the id its job adopted at bulk urgency (L5K-R21)")
        await engine.releaseGroup(token)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        #expect(await harness.source.starts.count <= 1, "only the content `second`'s file did not hold is downloaded, once")
        await engine.shutdown()
    }
}

extension EngineLegacyMigrationTransferTests {
    // MARK: What a migration call returns after its publication (L5K-R23)

    /// A launch as `rateLimitedLaunch` builds it (ARCHITECTURE §5's install interval of 0.1 s, a bulk executor that holds
    /// every unit, the origin serving `catalog`), except that the store installs into `sink`, which holds the install a
    /// test asks it to and answers every install from `sink.inner`, the harness's sink (the readers' view). Nothing is
    /// started.
    @available(macOS 15.0, iOS 18.0, *)
    static func heldSinkLaunch(
        _ catalog: [(ManifestEntry, Data)],
        time: ManualTimeSource,
        sink: HeldInstallSink
    ) async throws -> (harness: EngineHarness, bulk: SteppedBlockingExecutor) {
        let bulk = SteppedBlockingExecutor(holding: true)
        let fileSystem = FakeFileSystem(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: 64 << 30, opportunisticCapacity: 64 << 30)
        )
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource(initial: .unrestricted)
        let pressure = FakeMemoryPressureSource()
        let tap = RecordingLogTap()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: bulk,
            time: time,
            random: SeededRandom(seed: 0x5EED),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(version: "1.0+1"),
            legacyDefaults: FakeLegacyDefaults(),
            memoryPressure: pressure,
            logTap: tap
        )
        let storeConfiguration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(),
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0.1
        )
        let store = AssetStore(configuration: storeConfiguration, environment: StoreEnvironment(environment: environment, snapshotSink: sink))
        let configuration = EngineConfiguration(
            tuning: SyncTuning(),
            storage: StoragePolicy(),
            network: NetworkPolicy(),
            power: PowerPolicy(),
            refresh: .oncePerAppVersion,
            remote: RemoteConfiguration(),
            limits: ManifestLimits(),
            retentionScope: .all
        )
        let harness = EngineHarness(
            time: time,
            fileSystem: fileSystem,
            sink: sink.inner,
            source: source,
            conditions: conditions,
            pressure: pressure,
            tap: tap,
            store: store,
            engine: SyncEngine(store: store, environment: environment, configuration: configuration),
            configuration: configuration
        )
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        return (harness, bulk)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: when a job's adoption of the last claimed prior-art file ends while the migration batch's install is held, the migration still finishes in that launch instead of backing off to the next maintenance window with every file adopted (L5K-R23, KC4-STALELAST)", .timeLimit(.minutes(1)))
    func lastAdoptionDuringTheBatchsInstallFinishesTheMigration() async throws {
        let time = ManualTimeSource()
        // Three files: the batch holds the first pending one at its hash; a prefetch job adopts the last pending one,
        // which is still queued whichever file the batch holds (a batch takes the files in path order).
        let catalog = EngineLegacyMigrationTransferTests.catalog(3, seed: 9_900)
        let sink = HeldInstallSink(inner: ScriptedSnapshotSink())
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.heldSinkLaunch(catalog, time: time, sink: sink)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "premise: the held batch's file and every file after it are pending: \(pending.count)")
        let asset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let batchIDs = pending.subtracting([asset.identifier])
        let token = try await engine.registerGroup([asset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        // The install window opens again before the batch publishes, so the batch's publication installs at once: the sink
        // holds that install (the one whose snapshot holds the batch's adoptions and not the job's).
        time.advance(by: 1)
        let jobID = asset.identifier
        await sink.holdFirst { snapshot in
            batchIDs.allSatisfy { snapshot.location(for: $0, extensions: []) != nil } && snapshot.location(for: jobID, extensions: []) == nil
        }
        while !(await sink.isHolding) {
            for unit in await bulk.heldUnits where !jobHash.contains(unit) {
                await bulk.release(unit)
            }
            try Task.checkCancellation()
            await Task.yield()
        }
        // The job's adoption ends while that install is held: it unclaims the last file, so nothing is left, and publishes
        // inside the window the batch's install has just closed; the job is answered from the store.
        for unit in jobHash {
            await bulk.release(unit)
        }
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: [], on: engine) { engine in
            engine.state.jobs[asset.transferID] == nil
        }
        let installDue = await harness.store.nextDeadline() != nil
        await sink.release()
        await bulk.setHolding(false)
        await engine.awaitCondition { !$0.state.migration.running }
        let flags = await engine.readForTests { ($0.state.migration.pending, $0.state.migration.deferred) }

        #expect(installDue, "premise: the job's bulk adoption left the trailing install due while the batch's install was held")
        #expect(!flags.0 && !flags.1, "the migration loop backed off to the next maintenance window with every file adopted: pending \(flags.0), deferred \(flags.1) (L5K-C4-00)")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        #expect(try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog))
        await engine.releaseGroup(token)
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        await engine.shutdown()
    }

    // MARK: Every id of a job is asked, and each bulk adoption scheduled, before the answer (L5K-R23)

    /// A launch as `rateLimitedLaunch` builds it over two prior-art files the held batch takes first (`legacy0`,
    /// `legacy1`: a batch takes the files in path order, so it never holds the job's files) and one content under two ids,
    /// `first` and `second` (a job reads its ids in that order), whose prior-art files both hold that content. Nothing is
    /// started.
    @available(macOS 15.0, iOS 18.0, *)
    static func twoIDLaunch(
        seed: UInt64,
        time: ManualTimeSource
    ) async throws -> (harness: EngineHarness, bulk: SteppedBlockingExecutor, first: ManifestEntry, second: ManifestEntry) {
        let bytes = EngineFixture.bytes(seed)
        let others = EngineLegacyMigrationTransferTests.catalog(2, seed: seed + 10)
        let first = EngineFixture.entry("legacy5", bytes)
        let second = EngineFixture.entry("legacy6", bytes)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(others + [(first, bytes), (second, bytes)], time: time)
        return (harness, bulk, first, second)
    }

    /// Whether the store holds neither of `ids` present yet.
    @available(macOS 15.0, iOS 18.0, *)
    static func nonePresent(_ harness: EngineHarness, _ ids: [AssetID]) async throws -> Bool {
        let view = try await harness.view()
        return ids.allSatisfy { view.records[$0]?.referencedBlob == nil }
    }

    /// Whether the store holds every one of `ids` present at its current content.
    @available(macOS 15.0, iOS 18.0, *)
    static func arePresent(_ harness: EngineHarness, _ ids: [AssetID]) async throws -> Bool {
        let view = try await harness.view()
        return ids.allSatisfy { view.records[$0]?.referencedBlob != nil && view.records[$0]?.isStale == false }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-13: a job of two ids schedules the trailing install of its first id's bulk-urgency adoption before it reads the second id, so the readers see the first id once the install window has passed while that read is still held (L5K-R23, KC4-MULTIID)", .timeLimit(.minutes(1)))
    func earlierAdoptionReachesTheReadersDuringALaterRead() async throws {
        let time = ManualTimeSource()
        let (harness, bulk, first, second) = try await EngineLegacyMigrationTransferTests.twoIDLaunch(seed: 9_980, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        try #require(first.transferID == second.transferID, "premise: one content, one job")
        let bothPending = try await EngineLegacyMigrationTransferTests.nonePresent(harness, [first.identifier, second.identifier])
        // A prefetch job of both ids reads `first` first: its adoption's hash unit is held, then let go, so `first` is
        // adopted at bulk urgency inside the install window (the clock stands still after open's install).
        let token = try await engine.registerGroup([first.identifier, second.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let firstHash = Set(await bulk.heldUnits).subtracting(migration)
        for unit in firstHash {
            await bulk.release(unit)
        }
        // The job's read of `second` then hashes that id's own prior-art file: that unit is held.
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let secondHash = Set(await bulk.heldUnits).subtracting(migration)
        let firstStored = try await EngineLegacyMigrationTransferTests.arePresent(harness, [first.identifier])
        let unseenAtTheRead = await EngineLegacyMigrationTransferTests.unseen(harness, [first.identifier])
        let scheduled = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        let storeDeadline = await harness.store.nextDeadline()
        // The read of `second` lasts past the install window.
        time.advance(by: 0.3)
        try await EngineLegacyMigrationTransferTests.runStoreWork(harness)
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, [first.identifier])
        let stillHeld = Set(await bulk.heldUnits).isSuperset(of: secondHash)

        #expect(bothPending, "premise: both ids were still to adopt after the start")
        #expect(firstStored && unseenAtTheRead == [first.identifier], "premise: `first` was adopted at bulk urgency, in a coalesced snapshot only, before the read of `second`")
        #expect(stillHeld, "premise: the read of `second` was still held when the readers were read")
        #expect(storeDeadline != nil, "premise: the store reports the trailing install's deadline")
        if let storeDeadline {
            #expect(scheduled.map { $0 <= storeDeadline } == true, "L5K-R16: the heap held no store deadline no later than the store's (\(String(describing: scheduled)) for \(storeDeadline)) while the job's read of `second` ran (L5K-C4-01)")
        }
        #expect(unseen.isEmpty, "R-STO-13: `first`, adopted at bulk urgency, stayed out of the readers' snapshot past the install window while the job's read of `second` ran (L5K-C4-01)")
        for unit in secondHash {
            await bulk.release(unit)
        }
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration, on: engine) { engine in
            engine.state.jobs[first.transferID] == nil
        }
        await engine.releaseGroup(token)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        try await EngineLegacyMigrationTransferTests.expectSettled(harness)
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        await engine.shutdown()
    }
}

/// A snapshot sink that, once armed, holds the first install whose snapshot satisfies a predicate (at the await of the
/// store's REENTRANCY R6) until the test releases it, and answers every install from `inner`, the harness's sink: a test
/// suspends one publication at its install while other calls run, and `inner.installed` stays the readers' view.
actor HeldInstallSink: SnapshotSink {
    /// The harness's sink: what the readers see.
    let inner: ScriptedSnapshotSink
    private var predicate: (@Sendable (AssetSnapshot) -> Bool)?
    private var held: CheckedContinuation<Void, Never>?

    init(inner: ScriptedSnapshotSink) {
        self.inner = inner
    }

    /// Whether an install is held now.
    var isHolding: Bool {
        self.held != nil
    }

    /// Holds the next install whose snapshot satisfies `predicate`.
    func holdFirst(where predicate: @escaping @Sendable (AssetSnapshot) -> Bool) {
        self.predicate = predicate
    }

    /// Releases the held install, if any, and holds no other.
    func release() {
        self.predicate = nil
        self.held?.resume()
        self.held = nil
    }

    func install(_ snapshot: AssetSnapshot) async -> InstallAck {
        if let predicate = self.predicate, predicate(snapshot) {
            self.predicate = nil
            // REENTRANCY: test sink — nothing: the install below answers from the inner sink's state at release.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.held = continuation
            }
        }
        // REENTRANCY: test sink — nothing is read afterwards.
        return await self.inner.install(snapshot)
    }
}

/// A planner whose next `plan` call, once armed, blocks its thread until the test opens the gate (the verifier's probe
/// PE5): a test holds `ensureAvailable` between its planning view and its group's registration. The plan is the
/// production planner's. A test opens the gate on every exit (`defer`), so no planning thread stays blocked; the hold
/// lasts a few actor hops of the test.
@available(macOS 15.0, iOS 18.0, *)
final class MigrationPlannerGate: Sendable {
    private struct State {
        var armed = false
        var entered = false
    }

    private let state = Mutex(State())
    private let semaphore = DispatchSemaphore(value: 0)

    /// Makes the next `plan` call block until `open()`.
    func arm() {
        self.state.withLock { $0.armed = true }
    }

    /// Whether the armed call reached the planner.
    var entered: Bool {
        self.state.withLock { $0.entered }
    }

    /// Lets the blocked call go on.
    func open() {
        self.semaphore.signal()
    }

    /// Called by the planner: blocks the armed call until `open()`.
    func pass() {
        let blocks = self.state.withLock { state -> Bool in
            guard state.armed else {
                return false
            }
            state.armed = false
            state.entered = true
            return true
        }
        if blocks {
            self.semaphore.wait()
        }
    }
}

/// The production planner behind a `MigrationPlannerGate`.
@available(macOS 15.0, iOS 18.0, *)
struct MigrationGatedPlanner: SyncPlanning {
    let gate: MigrationPlannerGate

    func plan(manifest: ValidatedManifest, snapshot: StorePlanningView, scope: AssetScope, policy: PlanningPolicy, freeSpace: FreeSpace) -> SyncPlan {
        self.gate.pass()
        return StandardSyncPlanner().plan(manifest: manifest, snapshot: snapshot, scope: scope, policy: policy, freeSpace: freeSpace)
    }
}

/// What L5K-R16's tripwire compares before and after it reads the store (`EngineHarness.idleViolations()`): whether the
/// engine was settled, its alarm and the store deadline on its heap. Equal marks mean that no alarm turn ran the store's
/// work while the store was read, so the store's answer describes the state the engine is settled in.
struct SettledMark: Sendable, Equatable {
    let settled: Bool
    let alarm: UInt64?
    let deadline: MonotonicInstant?
}

@available(macOS 15.0, iOS 18.0, *)
extension EngineHarness {
    /// The engine invariants with orchestrator ruling L5K-R16's tripwire folded in
    /// (`SyncEngine.invariantViolations(storeDeadlineDue:)`), read at idle: `checked` when the engine was settled
    /// (`storeDeadlineSettled`) before and after the store's `nextDeadline()` was read, with the same alarm and the same
    /// store deadline on its heap; then a deadline the store reports, a trailing install among them, must be on the
    /// engine's heap. Otherwise only the plain invariants are returned.
    func idleViolations() async -> (checked: Bool, violations: [String]) {
        let engine = self.engine
        let before = await engine.readForTests { engine in
            SettledMark(settled: engine.storeDeadlineSettled, alarm: engine.state.alarm?.token, deadline: engine.state.heap.deadline(for: .store))
        }
        let storeDeadline = await self.store.nextDeadline()
        return await engine.readForTests { engine in
            let after = SettledMark(settled: engine.storeDeadlineSettled, alarm: engine.state.alarm?.token, deadline: engine.state.heap.deadline(for: .store))
            guard before.settled, after == before else {
                return (false, engine.invariantViolations())
            }
            return (true, engine.invariantViolations(storeDeadlineDue: storeDeadline != nil))
        }
    }
}
