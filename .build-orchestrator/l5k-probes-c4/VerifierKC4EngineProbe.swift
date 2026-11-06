import Dispatch
import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

// Verifier probes, WP-K close-out cycle 4, correctness lens. Scratch copy only; never committed.

/// A sink that holds the first install whose snapshot satisfies `predicate` (once armed) and forwards everything to
/// `inner`, so `EngineHarness.sink` (the inner sink) still shows what the readers see.
actor VKC4EngineHoldingSink: SnapshotSink {
    let inner: ScriptedSnapshotSink
    private var predicate: (@Sendable (AssetSnapshot) -> Bool)?
    private var held: CheckedContinuation<Void, Never>?
    private(set) var heldOnce = false

    init(inner: ScriptedSnapshotSink) {
        self.inner = inner
    }

    func holdFirst(where predicate: @escaping @Sendable (AssetSnapshot) -> Bool) {
        self.predicate = predicate
    }

    var isHolding: Bool {
        self.held != nil
    }

    func release() {
        self.predicate = nil
        self.held?.resume()
        self.held = nil
    }

    func install(_ snapshot: AssetSnapshot) async -> InstallAck {
        if let predicate = self.predicate, predicate(snapshot) {
            self.predicate = nil
            self.heldOnce = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.held = continuation
            }
        }
        return await self.inner.install(snapshot)
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension EngineHarness {
    /// `EngineHarness.make`'s defaults with the store's sink replaced by `holding` (which forwards to `inner`).
    static func makeHolding(
        disk: DiskImage,
        time: ManualTimeSource,
        bulk: any BlockingExecutor,
        installInterval: TimeInterval,
        legacy: LegacyMigrationPolicy,
        holding: VKC4EngineHoldingSink,
        inner: ScriptedSnapshotSink
    ) -> EngineHarness {
        let fileSystem = FakeFileSystem(
            disk: disk,
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: 64 << 30, opportunisticCapacity: 64 << 30)
        )
        let source = FakeRemoteSource()
        let conditionsSource = FakeDeviceConditionsSource(initial: .unrestricted)
        let pressure = FakeMemoryPressureSource()
        let tap = RecordingLogTap()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: bulk,
            time: time,
            random: SeededRandom(seed: 0x5EED),
            conditions: conditionsSource,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(version: "1.0+1"),
            legacyDefaults: FakeLegacyDefaults(),
            memoryPressure: pressure,
            logTap: tap
        )
        let storeConfiguration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(),
            legacy: legacy,
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: installInterval
        )
        let store = AssetStore(configuration: storeConfiguration, environment: StoreEnvironment(environment: environment, snapshotSink: holding))
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
        let engine = SyncEngine(store: store, environment: environment, configuration: configuration)
        return EngineHarness(
            time: time,
            fileSystem: fileSystem,
            sink: inner,
            source: source,
            conditions: conditionsSource,
            pressure: pressure,
            tap: tap,
            store: store,
            engine: engine,
            configuration: configuration
        )
    }
}

@Suite("Verifier K-C4 engine probes", .serialized)
struct VerifierKC4EngineProbe {
    typealias T = EngineLegacyMigrationTransferTests

    /// P20-ENGINE: the engine's view of P20-STALE. A prefetch job's adoption holds the last claimed file; the batch adopts
    /// the others and publishes at `.bulk` with the install window open, so its install suspends on the sink (held
    /// here); the job's adoption ends meanwhile. The batch returns `remaining == 0 && !finished` and the migration loop
    /// backs off to the next maintenance window (RE-S29): migration stays pending, phases 3 and 4 never run this launch.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("P20-ENGINE: a migration deferred by the batch's stale `last`", .timeLimit(.minutes(1)))
    func p20Engine() async throws {
        let time = ManualTimeSource()
        let catalog = T.catalog(3, seed: 9_900)
        let bulk = SteppedBlockingExecutor(holding: true)
        let inner = ScriptedSnapshotSink()
        let sink = VKC4EngineHoldingSink(inner: inner)
        let harness = EngineHarness.makeHolding(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            bulk: bulk,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot),
            holding: sink,
            inner: inner
        )
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let pending = try await T.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "premise: \(pending.count)")
        let jobAsset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let batchIDs = pending.subtracting([jobAsset.identifier])
        let token = try await engine.registerGroup([jobAsset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        // The install window opens again before the batch publishes.
        time.advance(by: 1)
        let job = jobAsset.identifier
        await sink.holdFirst { snapshot in
            batchIDs.allSatisfy { snapshot.location(for: $0, extensions: []) != nil } && snapshot.location(for: job, extensions: []) == nil
        }
        while await !sink.isHolding {
            for unit in await bulk.heldUnits where !jobHash.contains(unit) {
                await bulk.release(unit)
            }
            try Task.checkCancellation()
            await Task.yield()
        }
        let claimedAtHold = await harness.store.state.migration.claimed.count
        // The job's adoption ends while the batch's install is held.
        for unit in jobHash {
            await bulk.release(unit)
        }
        try await T.release(bulk, keeping: [], on: engine) { engine in
            engine.state.jobs[jobAsset.transferID] == nil
        }
        let installDue = await harness.store.state.core.snapshots.installDue
        await sink.release()
        await bulk.setHolding(false)
        await engine.awaitCondition { !$0.state.migration.running }
        let flags = await engine.readForTests { ($0.state.migration.pending, $0.state.migration.deferred, $0.state.migration.batchCalls) }
        let storePhase = await harness.store.state.migration.phase
        let progress = await harness.store.state.migration.progress
        let rootExists = ((try? harness.fileSystem.itemInfo(at: EngineRunPathTests.legacyRoot)) ?? nil) != nil
        print("KC4-PROBE P20-ENGINE claimedAtHold=\(claimedAtHold) installDueBeforeRelease=\(installDue) pending=\(flags.0) deferred=\(flags.1) batchCalls=\(flags.2) storePhase=\(storePhase) progress=\(progress) legacyRootExists=\(rootExists)")
        #expect(claimedAtHold == 1, "premise: the job's file was the one claimed file when the batch published")
        #expect(installDue, "premise: the job's bulk adoption left an install due during the batch's install")
        #expect(!flags.0, "P20-ENGINE: the migration loop backed off with migration still pending (deferred=\(flags.1), store phase \(storePhase), \(progress))")
        await engine.releaseGroup(token)
        await engine.shutdown()
    }

    /// P21-COMMIT: the commit path (`publish` → `committed`), outside any migration. A prefetch job's publication is held at
    /// its hash; a user-initiated resolve joins and promotes the job; the publication was made at the lane read before the
    /// call (`.prefetch`, coalesced inside the window). Does the resolve return before the readers' snapshot holds it?
    @available(macOS 15.0, iOS 18.0, *)
    @Test("P21-COMMIT: a resolve that joins a prefetch job during its publication", .timeLimit(.minutes(1)))
    func p21Commit() async throws {
        let time = ManualTimeSource()
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(time: time, bulk: bulk, installInterval: 0.1)
        let bytes = EngineFixture.bytes(9_950)
        let page = EngineHarness.onDemand("page", bytes)
        await harness.serveManifest([page])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(page.transferID, [.hold, .stage(bytes)])
        let token = try await engine.registerGroup([page.identifier], lane: .prefetch).get()
        await engine.waitForHandle(page.transferID)
        await bulk.holdNext()
        await harness.source.release(page.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        let verifying = await engine.jobStateForTests(page.transferID) == .verifying
        let resolve = Task { await engine.awaitAsset(page.identifier, lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 1 }
        let lane = await engine.readForTests { $0.state.jobs[page.transferID]?.lane }
        await bulk.release()
        let result = await resolve.value
        let unseen = await T.unseen(harness, [page.identifier])
        let storeHasIt = await harness.store.location(for: page.identifier, extensions: [], recordingAccess: false) != nil
        print("KC4-PROBE P21-COMMIT verifying=\(verifying) laneAfterJoin=\(String(describing: lane)) result=\(result) storeHasIt=\(storeHasIt) unseenAtReturn=\(unseen.count)")
        #expect(verifying, "premise: the publication was held at its hash")
        #expect(lane == .userInitiated, "premise: the resolve promoted the job")
        #expect((try? result.get()) != nil, "the resolve answers the location")
        #expect(unseen.isEmpty, "P21-COMMIT: the user-initiated resolve returned before the readers' snapshot held the asset (L5K-R21's class)")
        await engine.releaseGroup(token)
        try await harness.drive { $0.isIdleSilent }
        #expect(await T.unseen(harness, [page.identifier]).isEmpty, "the trailing install brings it later")
        await engine.shutdown()
    }

    /// P21-ENSURE-MIG: `ensureAvailable`'s present members during migration. A prefetch job holds the last claimed file;
    /// the batch adopts the others and publishes at `.bulk` inside the window (the clock stands still after open's
    /// install), then returns (L5K-R20) and the next call waits. `ensureAvailable` (the origin answers "not modified")
    /// of a batch-adopted id plans it present and reports it present. Does the readers' snapshot hold it when it returns?
    /// Then a resolve of another batch-adopted id (the fast hit).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("P21-ENSURE-MIG: ensureAvailable of an asset a migration batch adopted in a coalesced snapshot", .timeLimit(.minutes(1)))
    func p21EnsureDuringMigration() async throws {
        let time = ManualTimeSource()
        let catalog = T.catalog(4, seed: 9_960)
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            bulk: bulk,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.scriptTransfers(catalog)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let pending = try await T.pending(harness, catalog)
        try #require(pending.count >= catalog.count - 1, "premise: \(pending.count)")
        let jobAsset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let token = try await engine.registerGroup([jobAsset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let callsBefore = await engine.readForTests { $0.state.migration.batchCalls }
        let waited = try await T.releaseUntilTheBatchWaits(harness, bulk: bulk, keeping: jobHash, callsBefore: callsBefore)
        let batchIDs = pending.subtracting([jobAsset.identifier]).sorted()
        try #require(batchIDs.count >= 2)
        let stored = try await T.pending(harness, catalog).isDisjoint(with: batchIDs)
        let unseenBefore = await T.unseen(harness, batchIDs).count
        let (result, task) = try await T.duringMigration(keeping: jobHash, bulk: bulk) {
            await engine.ensureAvailable(scope: .identifiers([batchIDs[0]]))
        }
        let report = try result.get()
        let unseenAfterEnsure = await T.unseen(harness, [batchIDs[0]])
        let (resolved, task2) = try await T.duringMigration(keeping: jobHash, bulk: bulk) {
            await engine.awaitAsset(batchIDs[1], lane: .userInitiated)
        }
        let unseenAfterResolve = await T.unseen(harness, [batchIDs[1]])
        print("KC4-PROBE P21-ENSURE-MIG waited=\(waited) stored=\(stored) unseenBefore=\(unseenBefore) ensure(present=\(report.present) missing=\(report.missing)) unseenAfterEnsure=\(unseenAfterEnsure.count) resolve=\((try? resolved.get()) != nil) unseenAfterResolve=\(unseenAfterResolve.count)")
        #expect(waited && stored && unseenBefore == batchIDs.count, "premise: the batch's adoptions are stored and in a coalesced snapshot only")
        #expect(report.present == 1 && report.missing == 0)
        #expect(unseenAfterEnsure.isEmpty, "P21-ENSURE-MIG: ensureAvailable (user-initiated) reported the asset present while the readers' snapshot lacked it (L5K-C3-00's symptom, via ensureAvailable's present members)")
        #expect(unseenAfterResolve.isEmpty, "P21-FASTHIT: the user-initiated resolve's fast hit returned while the readers' snapshot lacked the asset")
        for unit in jobHash {
            await bulk.release(unit)
        }
        await engine.releaseGroup(token)
        await T.finishMigration(harness, bulk: bulk)
        await task.value
        await task2.value
        await engine.shutdown()
    }
}
