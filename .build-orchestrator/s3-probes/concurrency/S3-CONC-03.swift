import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Stage 3 concurrency probes (S3-CONC-03): a stalled subscriber's queue across two runs (R-SYN-12, H-9, ADR-023).
@Suite("S3 concurrency probes: engine events")
struct S3EngineEventProbeTests {
    /// The queue's own contract (`SubscriberQueue`): "delivery order is the publication order of each slot's latest
    /// occurrence". A progress slot replaced in place keeps the position of its first, undelivered occurrence, so run 2's
    /// progress, published after run 2's `syncStarted`, is delivered before it (and before run 1's end).
    @Test("R-SYN-12: a lagging subscriber receives a run's syncStarted before that run's syncProgress")
    func queueDeliversStartBeforeProgress() {
        var queue = SubscriberQueue()
        let run1 = SyncRunID(rawValue: 1)
        let run2 = SyncRunID(rawValue: 2)
        let half = SyncProgress(fraction: 0.5, completedCount: 1, totalCount: 2, bytesReceived: 1, bytesExpected: 2)
        _ = queue.publish(.syncStarted(run1, .explicit), sequence: 1)
        _ = queue.publish(.syncProgress(run1, half), sequence: 2)
        _ = queue.publish(.syncFinished(run1, .failed(.cancelled)), sequence: 3)
        _ = queue.publish(.syncStarted(run2, .explicit), sequence: 4)
        _ = queue.publish(.syncProgress(run2, half), sequence: 5)
        var delivered: [AssetEvent] = []
        while let event = queue.take() {
            delivered.append(event)
        }
        let started = delivered.firstIndex(of: .syncStarted(run2, .explicit))
        let progress = delivered.firstIndex(of: .syncProgress(run2, half))
        #expect(started != nil && progress != nil && started! < progress!, "run 2's progress precedes its start: \(delivered)")
    }

    /// The same through the engine: a subscriber that reads nothing while two runs with fetches complete, then reads
    /// its backlog.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a subscriber stalled across two runs receives the second run's syncStarted before its syncProgress", .timeLimit(.minutes(1)))
    func engineDeliversStartBeforeProgress() async throws {
        let harness = EngineHarness.make()
        let first = EngineSyncTests.catalog(2, prefix: "a", seed: 1)
        await harness.serve(first)
        let engine = harness.engine
        let stalled = try await engine.subscribe().get()
        let launch = try await harness.startAndAwaitLaunchRun()
        #expect(launch.completeReport?.fetched == 2, "run 1: \(launch)")
        let second = EngineSyncTests.catalog(2, prefix: "b", seed: 50)
        await harness.serve(first + second, etag: "v2")
        let outcome = await engine.sync(.force)
        let run2 = try #require(outcome.completeReport, "run 2: \(outcome)")
        #expect(run2.fetched == 2)
        await engine.shutdown()
        var events: [AssetEvent] = []
        for await event in stalled {
            events.append(event)
        }
        let started = events.firstIndex { event in
            if case .syncStarted(let id, _) = event {
                return id == run2.runID
            }
            return false
        }
        let progress = events.firstIndex { event in
            if case .syncProgress(let id, _) = event {
                return id == run2.runID
            }
            return false
        }
        #expect(started != nil && progress != nil, "both delivered: \(events)")
        if let started, let progress {
            #expect(started < progress, "run \(run2.runID.rawValue)'s syncProgress at \(progress) precedes its syncStarted at \(started): \(events.map { String(describing: EventSlot($0)) })")
        }
    }
}

/// A conditions source whose observations from the `holdFrom`-th on wait until the test releases them, so a test can
/// order an engine's first conditions reading after a transfer's terminal (S3-CONC-04).
@available(macOS 15.0, iOS 18.0, *)
actor GatedConditionsSource: DeviceConditionsSource {
    private let base: FakeDeviceConditionsSource
    private let holdFrom: Int
    private var calls = 0
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?
    nonisolated let held: AsyncStream<Void>
    private let heldSignal: AsyncStream<Void>.Continuation

    init(base: FakeDeviceConditionsSource, holdFrom: Int) {
        self.base = base
        self.holdFrom = holdFrom
        (self.held, self.heldSignal) = AsyncStream.makeStream(of: Void.self)
    }

    func conditions() async -> AsyncStream<DeviceConditions> {
        self.calls += 1
        if self.calls >= self.holdFrom, !self.released {
            // REENTRANCY: probe — nothing: a test gate resumed once by `release()`.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.gate = continuation
                self.heldSignal.yield(())
            }
        }
        // REENTRANCY: probe — nothing: the base's observation is returned as is.
        return await self.base.conditions()
    }

    func release() {
        self.released = true
        self.gate?.resume()
        self.gate = nil
    }
}

/// S3-CONC-04 (R-SYN-13): the engine's first conditions reading after an idle period is never an edge, while a
/// user-initiated job is dispatched before any reading exists.
@Suite("S3 concurrency probes: offline retry")
struct S3OfflineRetryProbeTests {
    /// An idle engine has no watcher and no conditions. A prefetch member's job waits for the first reading (non-user lanes
    /// need one); a user waiter joins and promotes it, and user work is dispatched without a reading. The attempt fails
    /// offline before the watcher's first reading arrives: the job becomes `failed(.whenOnline)`, the waiter is answered
    /// `.offline`, and the prefetch group keeps the job. The first reading then reports a satisfied path, but a first reading
    /// is never an edge (`previous == nil`), so nothing re-queues the asset: it waits for a second edge that a steady network
    /// never sends, although the path is satisfied (R-SYN-13: retried when the path becomes satisfied, without polling).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: an asset that failed offline before the engine's first conditions reading is retried once that reading shows a satisfied path", .timeLimit(.minutes(1)))
    func offlineBeforeFirstReadingIsRetried() async throws {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: 64 << 30, opportunisticCapacity: 64 << 30)
        )
        let source = FakeRemoteSource()
        let base = FakeDeviceConditionsSource(initial: .unrestricted)
        // The launch's observation passes; the one after the engine went idle waits for the test.
        let gated = GatedConditionsSource(base: base, holdFrom: 2)
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x5EED),
            conditions: gated,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(version: "1.0+1"),
            legacyDefaults: FakeLegacyDefaults(),
            memoryPressure: FakeMemoryPressureSource(),
            logTap: RecordingLogTap()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(
                location: .applicationSupport,
                policy: StoragePolicy(),
                legacy: LegacyMigrationPolicy(enabled: false),
                limits: ManifestLimits(),
                commitMinimumInterval: 0,
                snapshotInstallInterval: 0
            ),
            environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
        )
        let engine = SyncEngine(
            store: store,
            environment: environment,
            configuration: EngineConfiguration(
                tuning: SyncTuning(),
                storage: StoragePolicy(),
                network: NetworkPolicy(),
                power: PowerPolicy(),
                refresh: .oncePerAppVersion,
                remote: RemoteConfiguration(),
                limits: ManifestLimits(),
                retentionScope: .all
            )
        )
        let bytes = EngineFixture.bytes(4_242)
        let entry = EngineHarness.onDemand("late", bytes)
        await source.scriptManifest([.fetched(EngineFixture.manifestData([entry]), etag: EngineFixture.etag("v1"))])
        _ = try await engine.start().get()
        let applied = await engine.sync(.force)
        #expect(applied.completeReport != nil, "the on-demand catalog applies: \(applied)")
        // Idle: no job, no watcher, no reading.
        await engine.waitUntil { $0.jobsByState.isEmpty && !$0.watcherActive }
        #expect(await engine.readForTests { $0.state.conditions == nil })
        // The first attempt fails offline; a retry would stage the bytes.
        await source.script(entry.transferID, [.fail(.offline(.noConnection)), .stage(bytes)])
        let group = try await engine.registerGroup([entry.identifier], lane: .prefetch).get()
        for await _ in gated.held {
            break
        }
        await engine.waitUntil { $0.jobsByState[.queued] == 1 }
        let answer = await engine.awaitAsset(entry.identifier, lane: .userInitiated)
        #expect(answer == .failure(.offline), "the waiter is answered by the offline failure: \(answer)")
        let failed = await engine.readForTests { $0.state.jobs[entry.transferID]?.state }
        #expect(failed == .failed(.whenOnline), "the group keeps the job, failed offline: \(String(describing: failed))")
        // The first reading arrives: the path is satisfied.
        await gated.release()
        await engine.awaitCondition { $0.state.conditions != nil }
        let after = await engine.readForTests { $0.state.jobs[entry.transferID]?.state }
        #expect(after != .failed(.whenOnline), "the path is satisfied, yet the asset waits for another edge: \(String(describing: after))")
        let starts = await source.starts.count
        #expect(starts == 2 || after == .queued || after == .downloading, "a retry was started or queued: starts \(starts), state \(String(describing: after))")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}
