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
        try await harness.drive { $0.scheduledDeadlines == 0 }
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, neighbours)
        let held = Set(await bulk.heldUnits).isSuperset(of: migration)

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
    @Test("R-STO-13: the prior-art files legacy migration's own batches adopt after a sync took the parked launch run's place reach the readers' snapshot once the install window has passed (L5K-R16, probes I and J)", .timeLimit(.minutes(1)))
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
        let waiting = await engine.readForTests { $0.state.migration.launchRunWaiting }
        // Probe J: the sync's own trailing install runs first, while the migration is still held.
        try await harness.drive { $0.scheduledDeadlines == 0 }
        let pagesBefore = await EngineLegacyMigrationTransferTests.unseen(harness, pageIDs)
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        // Migration's batches published the pages at bulk urgency inside the install window that trailing install opened;
        // the sync took the launch run's place, so no launch run's apply follows migration to install them.
        try await harness.drive { $0.isIdleSilent }
        let unseenPages = await EngineLegacyMigrationTransferTests.unseen(harness, pageIDs)
        let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, (standard + pages).map(\.0.identifier))
        let runs = await engine.readForTests { $0.state.lastRunID }
        let idle = await harness.idleViolations()

        #expect(!waiting, "the sync took the parked launch run's place (L5K-R1)")
        #expect(pagesBefore.count == pages.count, "premise: no page was adopted before migration went on")
        #expect(unseenPages.isEmpty, "R-STO-13: \(unseenPages.count) of \(pages.count) pages migration adopted never reached the readers' snapshot: \(unseenPages)")
        #expect(unseen.isEmpty, "every prior-art file is in the readers' snapshot: \(unseen)")
        #expect(runs == 1, "no launch run followed migration")
        #expect(idle.checked && idle.violations.isEmpty, "settled: \(idle.checked), \(idle.violations)")
        #expect(await harness.source.starts.isEmpty, "R-STO-11: moved, not downloaded again")
        await engine.shutdown()
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
