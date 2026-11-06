import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Verifier probes, WP-K close-out cycle 2, correctness lens (engine level). Scratch copy only; never committed.
@Suite("Verifier K-C2 engine probes", .serialized)
struct VerifierKC2EngineProbe {
    /// The ids of `catalog` the readers' installed snapshot shows.
    @available(macOS 15.0, iOS 18.0, *)
    static func visible(_ harness: EngineHarness, _ ids: [AssetID]) async -> [AssetID] {
        let installed = await harness.sink.installed
        return ids.filter { installed.location(for: $0, extensions: []) != nil }
    }

    /// PR14a: a bulk sync during legacy migration whose jobs adopt the prior-art files (bulk urgency since L5K-R14).
    /// After the sync returned and migration ended, the clock is moved far beyond the install interval and the engine is
    /// driven until it is idle-silent: does a trailing install ever show the adopted assets to the readers?
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PR14a: the readers see the assets a bulk sync adopted once the install window has passed", .timeLimit(.minutes(1)))
    func trailingInstallAfterBulkAdoptions() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(20, seed: 9_100)
        let ids = catalog.map(\.0.identifier)
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
        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        let report = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        let starts = await harness.source.starts.count
        let visibleAfterSync = await VerifierKC2EngineProbe.visible(harness, ids)
        let armedAfterSync = await engine.readForTests { ($0.state.storeDeadline, $0.state.heap.deadline(for: .store)) }
        let storeNextAfterSync = await harness.store.nextDeadline()
        let installDueAfterSync = await harness.store.state.core.snapshots.installDue
        print("KC2-PROBE PR14a afterSync fetched=\(report.fetched) pending=\(pending.count) starts=\(starts) visible=\(visibleAfterSync.count)/\(ids.count) engineStoreDeadline=\(String(describing: armedAfterSync.0)) heapStore=\(String(describing: armedAfterSync.1)) storeNextDeadline=\(String(describing: storeNextAfterSync)) installDue=\(installDueAfterSync) now=\(time.monotonicNow())")

        // Migration goes on and ends (its held file was adopted by the sync's job already, so its batch adopts nothing).
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        // Far beyond the install interval and the commit window; then everything due runs until the engine is silent.
        time.advance(by: 10)
        try await harness.drive(advances: 256) { $0.isIdleSilent }
        let visibleAtEnd = await VerifierKC2EngineProbe.visible(harness, ids)
        let present = try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog)
        let armedAtEnd = await engine.readForTests { ($0.state.storeDeadline, $0.state.heap.deadline(for: .store)) }
        let storeNextAtEnd = await harness.store.nextDeadline()
        let installDueAtEnd = await harness.store.state.core.snapshots.installDue
        let silent = await engine.introspect().isIdleSilent
        print("KC2-PROBE PR14a atEnd visible=\(visibleAtEnd.count)/\(ids.count) storePresent=\(present) engineStoreDeadline=\(String(describing: armedAtEnd.0)) heapStore=\(String(describing: armedAtEnd.1)) storeNextDeadline=\(String(describing: storeNextAtEnd)) installDue=\(installDueAtEnd) idleSilent=\(silent) now=\(time.monotonicNow())")
        #expect(present, "the store holds every asset")
        #expect(visibleAtEnd.count == ids.count, "a trailing install shows every adopted asset to the readers (ARCHITECTURE §5); \(visibleAtEnd.count) of \(ids.count) visible, the store's due install is never run")
        await engine.shutdown()
    }

    /// PR14b: the store's production windows (commit 0.25 s, install 0.1 s). A user opens a prior-art page during
    /// migration (a user-initiated resolve adopts its file and installs at once), and the page prefetches its neighbours at
    /// the default prefetch lane right away (their jobs adopt at bulk urgency, inside the install window). Migration then
    /// ends, the clock moves 10 s and the engine is driven until it is idle-silent: do the readers ever see the neighbours?
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PR14b: the readers see the neighbours a prefetch adopted right after a page's resolve", .timeLimit(.minutes(1)))
    func trailingInstallAfterPrefetchAdoptions() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(12, seed: 9_300)
        let ids = catalog.map(\.0.identifier)
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            bulk: bulk,
            commitInterval: 0.25,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog).sorted()
        let page = try #require(pending.first)
        let neighbours = Array(pending.dropFirst())
        // The page: a user-initiated resolve adopts its prior-art file and installs at once.
        let (resolved, resolveTask) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.awaitAsset(page, lane: .userInitiated)
        }
        _ = try resolved.get()
        let pageVisible = await VerifierKC2EngineProbe.visible(harness, [page]).count == 1
        // Its neighbours, prefetched at the default lane in the same instant.
        let token = try await engine.registerGroup(neighbours, lane: .prefetch).get()
        try await EngineLegacyMigrationTransferTests.release(bulk, keeping: migration, on: engine) { engine in
            guard let group = engine.state.groups[token] else {
                return false
            }
            return group.claimCursor == group.members.count && group.pending.isEmpty && engine.state.jobs.isEmpty
        }
        let starts = await harness.source.starts.count
        let afterPrefetch = await VerifierKC2EngineProbe.visible(harness, neighbours)
        let armed = await engine.readForTests { ($0.state.storeDeadline, $0.state.heap.deadline(for: .store)) }
        let storeNext = await harness.store.nextDeadline()
        print("KC2-PROBE PR14b afterPrefetch pageVisible=\(pageVisible) neighboursVisible=\(afterPrefetch.count)/\(neighbours.count) starts=\(starts) engineStoreDeadline=\(String(describing: armed.0)) heapStore=\(String(describing: armed.1)) storeNextDeadline=\(String(describing: storeNext)) now=\(time.monotonicNow())")
        await engine.releaseGroup(token)
        // The clock moves far beyond both windows while the migration is still held; whatever the engine armed runs.
        time.advance(by: 10)
        for _ in 0..<500 {
            await Task.yield()
        }
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        let afterAdvance = await VerifierKC2EngineProbe.visible(harness, neighbours)
        print("KC2-PROBE PR14b after10s neighboursVisible=\(afterAdvance.count)/\(neighbours.count) now=\(time.monotonicNow())")
        // Migration goes on and ends (its durable commit waits for the commit window: the clock is driven), then the engine
        // is driven until it is idle-silent.
        try await harness.withClock {
            await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        }
        await resolveTask.value
        time.advance(by: 10)
        try await harness.drive(advances: 256) { $0.isIdleSilent }
        let atEnd = await VerifierKC2EngineProbe.visible(harness, neighbours)
        let present = try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog)
        let armedAtEnd = await engine.readForTests { ($0.state.storeDeadline, $0.state.heap.deadline(for: .store)) }
        let storeNextAtEnd = await harness.store.nextDeadline()
        let installDue = await harness.store.state.core.snapshots.installDue
        print("KC2-PROBE PR14b atEnd neighboursVisible=\(atEnd.count)/\(neighbours.count) storePresent=\(present) engineStoreDeadline=\(String(describing: armedAtEnd.0)) heapStore=\(String(describing: armedAtEnd.1)) storeNextDeadline=\(String(describing: storeNextAtEnd)) installDue=\(installDue) now=\(time.monotonicNow()) starts=\(await harness.source.starts.count)")
        #expect(present, "the store holds every asset")
        #expect(atEnd.count == neighbours.count, "\(atEnd.count) of \(neighbours.count) adopted neighbours visible 10 s after the install window")
        await engine.shutdown()
    }

    /// PR14c: a migration batch's own bulk publication after the alarm's last trailing install. An explicit sync during a
    /// held migration adopts the standard prior-art entries; the clock passes the install window and the engine runs its
    /// due work; then the migration goes on: its batch adopts the on-demand prior-art files (no sync plans them) and
    /// publishes at bulk urgency, inside the window of that last install. Since L5K-R1's option (a) no launch run follows
    /// the end of migration. Do the readers ever see the on-demand files?
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PR14c: the readers see the files a migration batch adopted after the sync", .timeLimit(.minutes(1)))
    func trailingInstallAfterBatchAdoptions() async throws {
        let time = ManualTimeSource()
        let standard = EngineLegacyMigrationTransferTests.catalog(6, seed: 9_700)
        let onDemand = (0..<6).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(9_800 + UInt64(index))
            return (EngineFixture.entry("od\(index)", bytes, policy: .onDemand), bytes)
        }
        let catalog = standard + onDemand
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
        let (outcome, task) = try await EngineLegacyMigrationTransferTests.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        _ = try #require(outcome.completeReport, "the sync completes: \(outcome)")
        // The clock passes the install window; whatever the engine armed runs.
        time.advance(by: 10)
        for _ in 0..<500 {
            await Task.yield()
        }
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        let standardVisible = await VerifierKC2EngineProbe.visible(harness, standard.map(\.0.identifier))
        let installsBefore = await harness.sink.offeredKeys.count
        // The migration goes on and ends; its batch adopts the on-demand files.
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        await task.value
        time.advance(by: 10)
        try await harness.drive(advances: 256) { $0.isIdleSilent }
        let odVisible = await VerifierKC2EngineProbe.visible(harness, onDemand.map(\.0.identifier))
        let present = try await EngineLegacyMigrationTransferTests.allPresent(harness, catalog)
        let installDue = await harness.store.state.core.snapshots.installDue
        let installsAfter = await harness.sink.offeredKeys.count
        print("KC2-PROBE PR14c standardVisibleAfterSync+10s=\(standardVisible.count)/\(standard.count) onDemandVisibleAtEnd=\(odVisible.count)/\(onDemand.count) storePresent=\(present) installDue=\(installDue) installsDuringMigrationEnd=\(installsAfter - installsBefore) storeNext=\(String(describing: await harness.store.nextDeadline())) now=\(time.monotonicNow())")
        #expect(present)
        #expect(odVisible.count == onDemand.count, "\(odVisible.count) of \(onDemand.count) files the batch adopted are visible")
        await engine.shutdown()
    }

    /// PK2b (cycle 1's public-API shape at engine level): ensureAvailable right after start over a migration that runs at
    /// its own pace on inline executors, 150 prior-art files of 64 KiB, `launches` launches.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PK2b-c2: ensureAvailable right after start downloads no prior-art file", .timeLimit(.minutes(5)))
    func ensureAvailableRightAfterStart() async throws {
        let launches = Int(ProcessInfo.processInfo.environment["KC2_LAUNCHES"] ?? "") ?? 20
        var downloadedLaunches = 0
        var downloadedFiles = 0
        var joins = 0
        for launch in 0..<launches {
            let time = ManualTimeSource()
            let catalog = EngineLegacyMigrationTransferTests.catalog(150, seed: 12_000 + UInt64(launch) * 1_000, size: 65_536)
            let harness = EngineHarness.make(
                disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
                time: time,
                legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
            )
            await harness.serveManifest(catalog.map(\.0))
            await harness.scriptTransfers(catalog)
            let opened = try await harness.start()
            try #require(opened.legacyMigrationPending)
            let report = try await harness.engine.ensureAvailable(scope: .all).get()
            let starts = await harness.source.starts
            if !starts.isEmpty {
                downloadedLaunches += 1
                downloadedFiles += starts.count
                print("KC2-PROBE PK2b launch=\(launch) downloaded=\(starts.count) report=\(report)")
            }
            joins += harness.tap.lines.filter { $0.message.contains("the same legacy file") }.count
            #expect(report.present == catalog.count && report.missing == 0, "launch \(launch): \(report)")
            await harness.engine.shutdown()
        }
        print("KC2-PROBE PK2b launches=\(launches) launchesWithDownloads=\(downloadedLaunches) files=\(downloadedFiles) joins=\(joins)")
        #expect(downloadedLaunches == 0, "\(downloadedLaunches) of \(launches) launches downloaded \(downloadedFiles) prior-art files")
    }

    /// PK1-c2 (L5K-V3-05, CCR-K1): an explicit sync right after start over a migration that runs at its own pace.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PK1-c2: an explicit sync right after start downloads no prior-art file", .timeLimit(.minutes(5)))
    func explicitSyncRightAfterStart() async throws {
        let launches = Int(ProcessInfo.processInfo.environment["KC2_LAUNCHES"] ?? "") ?? 20
        var downloadedLaunches = 0
        var downloadedFiles = 0
        var outcomes: [String: Int] = [:]
        for launch in 0..<launches {
            let time = ManualTimeSource()
            let catalog = EngineLegacyMigrationTransferTests.catalog(150, seed: 32_000 + UInt64(launch) * 1_000, size: 65_536)
            let harness = EngineHarness.make(
                disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
                time: time,
                legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
            )
            await harness.serveManifest(catalog.map(\.0))
            await harness.scriptTransfers(catalog)
            try #require(try await harness.start().legacyMigrationPending)
            let outcome = await harness.engine.sync(.force)
            outcomes[outcome.completeReport != nil ? "complete" : "\(outcome)", default: 0] += 1
            let starts = await harness.source.starts
            if !starts.isEmpty {
                downloadedLaunches += 1
                downloadedFiles += starts.count
                print("KC2-PROBE PK1 launch=\(launch) downloaded=\(starts.count)")
            }
            await harness.engine.shutdown()
        }
        print("KC2-PROBE PK1 launches=\(launches) launchesWithDownloads=\(downloadedLaunches) files=\(downloadedFiles) outcomes=\(outcomes)")
        #expect(downloadedLaunches == 0, "\(downloadedLaunches) of \(launches) launches downloaded \(downloadedFiles) prior-art files")
    }

    /// PK8u: a user-initiated prefetch group joined right after start over a migration that runs at its own pace.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PK8u-c2: a user-initiated prefetch right after start downloads no prior-art file", .timeLimit(.minutes(5)))
    func userPrefetchRightAfterStart() async throws {
        let launches = Int(ProcessInfo.processInfo.environment["KC2_LAUNCHES"] ?? "") ?? 20
        var downloadedLaunches = 0
        var downloadedFiles = 0
        for launch in 0..<launches {
            let time = ManualTimeSource()
            let catalog = EngineLegacyMigrationTransferTests.catalog(150, seed: 22_000 + UInt64(launch) * 1_000, size: 65_536)
            let harness = EngineHarness.make(
                disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
                time: time,
                legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
            )
            await harness.serveManifest(catalog.map(\.0))
            await harness.scriptTransfers(catalog)
            let engine = harness.engine
            try #require(try await harness.start().legacyMigrationPending)
            let token = try await engine.registerGroup(catalog.map(\.0.identifier), lane: .userInitiated).get()
            await engine.awaitCondition { engine in
                guard let group = engine.state.groups[token] else {
                    return false
                }
                return group.claimCursor == group.members.count && group.pending.isEmpty && engine.state.jobs.isEmpty
            }
            let starts = await harness.source.starts
            if !starts.isEmpty {
                downloadedLaunches += 1
                downloadedFiles += starts.count
                print("KC2-PROBE PK8u launch=\(launch) downloaded=\(starts.count)")
            }
            await engine.releaseGroup(token)
            await engine.shutdown()
        }
        print("KC2-PROBE PK8u launches=\(launches) launchesWithDownloads=\(downloadedLaunches) files=\(downloadedFiles)")
        #expect(downloadedLaunches == 0, "\(downloadedLaunches) of \(launches) launches downloaded \(downloadedFiles) prior-art files")
    }

    /// PSPIN: the migration loop while the queue is empty and the only claimed file is one a job's adopt-on-demand took
    /// from the queue and is still processing. `migrateLegacy` returns at once with `remaining == 1, finished == false`, and
    /// the loop calls it again (RE-S29 backs off only on `remaining == 0`). Measured: the process CPU time and the number of
    /// returns the store reports while the job's hash unit is held for `holdMillis` of wall time.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PSPIN: the migration loop does not spin while a job's adoption holds the last claimed file", .timeLimit(.minutes(1)))
    func migrationLoopWhileAJobHoldsTheLastFile() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(4, seed: 9_500)
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            bulk: bulk,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let claimed = await harness.store.state.migration.claimed
        let queue = await harness.store.state.migration.queue
        let batchFile = try #require(claimed.first, "the batch holds a file")
        let other = try #require(queue.first, "a file is still queued")
        let otherID = try #require(other.ids.first)
        print("KC2-PROBE PSPIN batch=\(batchFile.ids) queued=\(queue.map(\.ids)) migrationUnits=\(migration.sorted())")
        // A user-initiated job for the queued file: its pre-transfer read takes it from the queue and hashes it (held).
        let token = try await engine.registerGroup([otherID], lane: .userInitiated).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let claimedNow = await harness.store.state.migration.claimed
        let onDemand = await harness.store.state.migration.onDemand.keys.count
        print("KC2-PROBE PSPIN jobHashUnits=\(jobHash.sorted()) claimed=\(claimedNow.map(\.ids)) onDemandMarks=\(onDemand)")
        // The batch's file goes on (every bulk unit but the job's hash is released as it arrives): the batch adopts it, the
        // queue is empty, and only the job's file is claimed.
        while true {
            let state = await harness.store.state.migration
            if state.queue.isEmpty, state.claimed == [other] {
                break
            }
            for unit in await bulk.heldUnits where !jobHash.contains(unit) {
                await bulk.release(unit)
            }
            await Task.yield()
            try Task.checkCancellation()
        }
        let heldNow = Set(await bulk.heldUnits)
        print("KC2-PROBE PSPIN batchFileAdopted heldUnits=\(heldNow.sorted()) jobHashStillHeld=\(heldNow.isSuperset(of: jobHash))")
        // Hold the job's hash for a fixed wall time and measure.
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let holdMillis = 300
        let cpuBefore = cpu()
        let wallBefore = DispatchTime.now().uptimeNanoseconds
        // Count how often the store answers `remaining > 0, finished == false` with nothing in the queue meanwhile: a
        // probe-side sample of the progress the loop gets (the store's own state, read between the loop's calls).
        var samples = 0
        var spinning = 0
        while DispatchTime.now().uptimeNanoseconds - wallBefore < UInt64(holdMillis) * 1_000_000 {
            let state = await harness.store.state.migration
            samples += 1
            if state.queue.isEmpty, state.claimed.count == 1, state.onDemand[other.components] != nil, await engine.readForTests({ $0.state.migration.running }) {
                spinning += 1
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallBefore) / 1_000_000_000
        let cpuUsed = cpu() - cpuBefore
        let load = ProcessInfo.processInfo.environment["KC2_LOAD"] ?? "?"
        print("KC2-PROBE PSPIN holdWall=\(String(format: "%.3f", wall))s cpuUsed=\(String(format: "%.3f", cpuUsed))s ratio=\(String(format: "%.2f", cpuUsed / wall)) samples=\(samples) loopRunningWithOnlyTheJobsFileClaimed=\(spinning) load=\(load)")
        // Let the job's hash go on.
        await bulk.setHolding(false)
        await engine.awaitCondition { !$0.state.migration.pending && !$0.state.migration.running }
        await engine.releaseGroup(token)
        #expect(cpuUsed / wall < 0.5, "the engine and the store burned \(cpuUsed) s of CPU in \(wall) s of wall time while only waiting for one job's hash")
        await engine.shutdown()
    }
}
