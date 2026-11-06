import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A conditions source whose observations from the `holdFrom`-th on wait until the test releases them, so a test can
/// order an engine's first conditions reading after a transfer's terminal (Stage 3, S3-CONC-04). An actor: its one wait
/// is resumed by `release()` and by nothing else.
@available(macOS 15.0, iOS 18.0, *)
actor GatedConditionsSource: DeviceConditionsSource {
    private let base: FakeDeviceConditionsSource
    private let holdFrom: Int
    private var calls = 0
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?
    /// Yields once when an observation starts waiting for `release()`.
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
            // REENTRANCY: test gate — nothing: resumed once by `release()`.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.gate = continuation
                self.heldSignal.yield(())
            }
        }
        // REENTRANCY: test gate — nothing: the base's observation is returned as is.
        return await self.base.conditions()
    }

    /// Lets the held observation (and every later one) through.
    func release() {
        self.released = true
        self.gate?.resume()
        self.gate = nil
    }
}

/// An engine whose conditions observation after its first idle period waits for the test (S3-CONC-04).
@available(macOS 15.0, iOS 18.0, *)
struct FirstReadingRig {
    let engine: SyncEngine
    let source: FakeRemoteSource
    let base: FakeDeviceConditionsSource
    let gated: GatedConditionsSource
    let entry: ManifestEntry
    let bytes: Data

    /// Starts an engine over one on-demand entry, applies it and waits until the engine is idle: no job, no watcher,
    /// no conditions reading. The next observation (the watcher's after the idle teardown) is held.
    static func make() async throws -> FirstReadingRig {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: 64 << 30, opportunisticCapacity: 64 << 30)
        )
        let source = FakeRemoteSource()
        let base = FakeDeviceConditionsSource(initial: .unrestricted)
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
        await engine.waitUntil { $0.jobsByState.isEmpty && !$0.watcherActive }
        return FirstReadingRig(engine: engine, source: source, base: base, gated: gated, entry: entry, bytes: bytes)
    }

    /// Returns once the watcher's observation waits for `gated.release()`.
    func awaitHeldObservation() async {
        for await _ in self.gated.held {
            break
        }
    }
}

extension EngineConditionsTests {
    static let unsatisfied = DeviceConditions(
        network: NetworkConditions(satisfied: false, expensive: false, constrained: false),
        power: DeviceConditions.unrestricted.power
    )

    /// An idle engine has no watcher and no conditions (`reconcileIdle`). A prefetch member's job waits for the first
    /// reading (non-user lanes need one); a user waiter joins and promotes it, and user work is dispatched without a
    /// reading. The attempt fails offline before the watcher's first reading arrives: the job becomes
    /// `failed(.whenOnline)`, the waiter is answered `.offline`, and the prefetch group keeps the job. The first reading
    /// then reports a satisfied path: it counts as the edge the failure waits for, so the asset is retried without a
    /// further network change (R-SYN-13; Stage 3, S3-CONC-04).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: an asset that failed offline before the engine's first conditions reading is retried once that reading shows a satisfied path", .timeLimit(.minutes(1)))
    func offlineBeforeFirstReadingIsRetried() async throws {
        let rig = try await FirstReadingRig.make()
        let engine = rig.engine
        let id = rig.entry.transferID
        #expect(await engine.readForTests { $0.state.conditions == nil }, "idle: no reading")
        await rig.source.script(id, [.fail(.offline(.noConnection)), .stage(rig.bytes)])
        let group = try await engine.registerGroup([rig.entry.identifier], lane: .prefetch).get()
        await rig.awaitHeldObservation()
        await engine.waitUntil { $0.jobsByState[.queued] == 1 }
        let answer = await engine.awaitAsset(rig.entry.identifier, lane: .userInitiated)
        #expect(answer == .failure(.offline), "the waiter is answered by the offline failure: \(answer)")
        let failed = await engine.readForTests { $0.state.jobs[id]?.state }
        #expect(failed == .failed(.whenOnline), "the group keeps the job, failed offline: \(String(describing: failed))")
        await rig.gated.release()
        await engine.awaitCondition { $0.state.conditions != nil }
        // The retry needs no further reading: it is queued in the reading's turn, or already started or done.
        let after = await engine.readForTests { $0.state.jobs[id]?.state }
        try #require(after != .failed(.whenOnline), "the path is satisfied, yet the asset waits for another edge: \(String(describing: after))")
        await engine.waitUntil { $0.jobsByState.isEmpty }
        #expect(await rig.source.starts.count == 2, "the first satisfied reading retried the asset once")
        let present = await engine.awaitAsset(rig.entry.identifier, lane: .userInitiated)
        #expect((try? present.get()) != nil, "the retry committed the asset: \(present)")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// The other order of the same window: the user attempt starts while no reading exists, the watcher's first reading
    /// (satisfied) is applied while it runs, and only then does URLSession's offline error arrive. The first reading was
    /// an edge applied after the attempt started (`ActiveAttempt.edgeSerial`), so the failure is retried at once and the
    /// waiter is answered by the retry, not `.offline` (R-SYN-13, PROBE-C9C-3's rule; Stage 3, S3-CONC-04).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: an offline failure that arrives after the engine's first conditions reading showed a satisfied path is retried at once", .timeLimit(.minutes(1)))
    func offlineAfterFirstReadingIsRetried() async throws {
        let rig = try await FirstReadingRig.make()
        let engine = rig.engine
        let id = rig.entry.transferID
        await rig.source.script(id, [.hold, .stage(rig.bytes)])
        let waiter = Task { await engine.awaitAsset(rig.entry.identifier, lane: .userInitiated) }
        await rig.awaitHeldObservation()
        await engine.waitUntil { $0.jobsByState[.downloading] == 1 }
        #expect(await engine.readForTests { $0.state.conditions == nil }, "the user attempt started without a reading")
        await rig.gated.release()
        await engine.awaitCondition { $0.state.conditions?.network.satisfied == true }
        await rig.source.release(id, with: .failed(.offline(.noConnection)))
        let answer = await waiter.value
        #expect((try? answer.get()) != nil, "the waiter is answered by the retry: \(answer)")
        #expect(await rig.source.starts.count == 2, "one retry, started at once")
        await engine.shutdown()
    }

    /// Control for the first-reading rule: when the first reading after the failure reports an unsatisfied path, it is
    /// not an edge and nothing is retried; the satisfied reading that follows is the edge that retries the asset once
    /// (R-SYN-13; Stage 3, the confirmer's control of S3-CONC-04).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: an unsatisfied first conditions reading retries nothing and the satisfied reading after it retries the asset once", .timeLimit(.minutes(1)))
    func unsatisfiedFirstReadingWaitsForEdge() async throws {
        let rig = try await FirstReadingRig.make()
        let engine = rig.engine
        let id = rig.entry.transferID
        await rig.source.script(id, [.fail(.offline(.noConnection)), .stage(rig.bytes)])
        let group = try await engine.registerGroup([rig.entry.identifier], lane: .prefetch).get()
        await rig.awaitHeldObservation()
        await engine.waitUntil { $0.jobsByState[.queued] == 1 }
        let answer = await engine.awaitAsset(rig.entry.identifier, lane: .userInitiated)
        #expect(answer == .failure(.offline), "\(answer)")
        await rig.base.send(EngineConditionsTests.unsatisfied)
        await rig.gated.release()
        await engine.awaitCondition { $0.state.conditions != nil }
        #expect(await engine.readForTests { $0.state.jobs[id]?.state } == .failed(.whenOnline), "an unsatisfied path retries nothing")
        #expect(await rig.source.starts.count == 1)
        await rig.base.send(.unrestricted)
        await engine.waitUntil { $0.jobsByState.isEmpty }
        #expect(await rig.source.starts.count == 2, "the unsatisfied-to-satisfied edge retried the asset once")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}
