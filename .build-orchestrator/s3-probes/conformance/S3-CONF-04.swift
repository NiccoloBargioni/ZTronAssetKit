// Target: Tests/ZTronAssetSyncTests/Engine/ (whole engine probe file; test (a) passes on s3-base and fails under S3-CONF-04.mutant.diff; test (b) FAILS on s3-base)
import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Stage 3 conformance probes (lens "conformance"): behaviour no existing test reaches, each killing a mutant that
/// survives the requirement's existing tests.
@Suite("S3 conformance probes: engine")
struct S3ConformanceEngineProbeTests {
    /// S3-CONF-02: the Apple tier's update check on an expensive network under a policy that forbids bulk on it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: an Apple-tier catalog update check is refused on an expensive network the bulk policy forbids", .timeLimit(.minutes(1)))
    func appleUpdateCheckRefusedOnExpensive() async throws {
        let source = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineConditionsTests.appleSource)
        let cellular = DeviceConditions(
            network: NetworkConditions(satisfied: true, expensive: true, constrained: false),
            power: PowerConditions(lowPowerMode: false, thermal: .nominal)
        )
        let noBulkOnCellular = NetworkPolicy(bulkOnExpensive: false, prefetchOnExpensive: false, userInitiatedOverridesPolicy: false)
        let harness = EngineHarness.make(source: source, conditions: cellular, network: noBulkOnCellular)
        let entry = EngineHarness.onDemand("pack-asset", EngineFixture.bytes(4_201))
        await harness.serveManifest([entry])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let request = try #require(await source.manifestRequests.last)
        #expect(request.allowsUpdateCheck == false, "the bulk lane may not use an expensive network: no catalog update check")
        await harness.conditions.send(.unrestricted)
        _ = await harness.engine.sync(.force)
        #expect(await source.manifestRequests.last?.allowsUpdateCheck == true)
        await harness.engine.shutdown()
    }

    /// S3-CONF-03: a run whose plan holds back a record failed at the integrity cap reports it as an integrity failure.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run over an asset failed at the integrity cap ends completeWithFailures with an integrity failure for it", .timeLimit(.minutes(1)))
    func runReportsAssetFailedAtIntegrityCap() async throws {
        let harness = EngineHarness.make()
        let good = EngineFixture.bytes(4_302)
        let entry = EngineHarness.onDemand("corrupt", good)
        let wrong = EngineFixture.bytes(4_303)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, Array(repeating: FakeTransferStep.stage(wrong), count: 6))
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        for _ in 0..<harness.configuration.storage.maxIntegrityAttempts + 2 {
            _ = await engine.awaitAsset("corrupt", lane: .userInitiated)
            await engine.awaitCondition { $0.state.jobs[entry.transferID] == nil }
            harness.time.advance(by: 700)
            await EngineFailurePathTests.settleDue(engine, time: harness.time)
        }
        guard case .failed(.integrity)? = try await harness.view().records["corrupt"]?.residency else {
            Issue.record("setup: expected the record failed until its entry changes")
            await engine.shutdown()
            return
        }
        let outcome = await engine.sync(.force)
        guard case .completeWithFailures(let report) = outcome else {
            Issue.record("a run over a failed asset ended \(outcome), not completeWithFailures")
            await engine.shutdown()
            return
        }
        #expect(report.failures.first { $0.id == "corrupt" }?.failureClass == .integrity)
        #expect(report.failures.first { $0.id == "corrupt" }?.error == .integrityFailure)
        await engine.shutdown()
    }

    /// S3-CONF-05: ensureAvailable over an incomplete scope while the auth breaker is open answers authRejected, the
    /// UI-mappable error a rejected key needs (R-CAR-7, R-NET-6), not serverUnavailable.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-7: ensureAvailable while the auth breaker is open throws authRejected for a scope with missing assets", .timeLimit(.minutes(1)))
    func ensureAvailableUnderAuthBreaker() async throws {
        let harness = EngineHarness.make()
        let entry = EngineHarness.onDemand("x", EngineFixture.bytes(4_501))
        await harness.serveManifest([entry])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        await harness.source.scriptManifest([.fail(.authentication(.forbiddenAmbiguous(EngineFailurePathTests.evidence(.manifest, xml: false, bytes: 0))))])
        guard case .blocked(.circuitOpen(.authentication), _) = await harness.engine.sync(.force) else {
            Issue.record("setup: expected the auth breaker open")
            await harness.engine.shutdown()
            return
        }
        let result = await harness.engine.ensureAvailable(scope: .identifiers(["x"]))
        #expect(result == .failure(.authRejected(.confirmed)), "\(result)")
        #expect(await harness.source.starts.isEmpty)
        await harness.engine.shutdown()
    }

    static let hot = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: false, constrained: false),
        power: PowerConditions(lowPowerMode: false, thermal: .critical)
    )

    /// Three held on-demand assets on an idle engine (the launch run done) at a critical thermal state.
    @available(macOS 15.0, iOS 18.0, *)
    static func hotHarness() async throws -> (EngineHarness, [ManifestEntry]) {
        let harness = EngineHarness.make(conditions: S3ConformanceEngineProbeTests.hot, tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        let assets = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(4_400 + index))
            return (EngineHarness.onDemand("hot\(index)", bytes), bytes)
        }
        await harness.serveManifest(assets.map(\.0))
        for (entry, bytes) in assets {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        try await harness.start()
        _ = await harness.engine.sync(.force)
        return (harness, assets.map(\.0))
    }

    /// S3-CONF-04 (a): with the conditions known, user-initiated work at `.critical` runs at most
    /// `interactiveConcurrencyAtCritical` transfers (ADR-036). Kills the mutant that ignores the cap.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: at a critical thermal state user-initiated transfers are capped at interactiveConcurrencyAtCritical once the conditions are known", .timeLimit(.minutes(1)))
    func criticalThermalCapsUserWork() async throws {
        let (harness, entries) = try await S3ConformanceEngineProbeTests.hotHarness()
        let engine = harness.engine
        let first = Task { await engine.awaitAsset(entries[0].identifier, lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.awaitCondition { $0.state.conditions != nil }
        let others = entries.dropFirst().map { entry in
            Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        }
        await engine.waitUntil { $0.running + ($0.queued[.userInitiated] ?? 0) == 3 }
        await engine.waitForAllHandles()
        let state = await engine.introspect()
        #expect(state.running == harness.configuration.power.interactiveConcurrencyAtCritical, "running: \(state.running)")
        #expect(await harness.source.starts.count == 1)
        first.cancel()
        for waiter in others {
            waiter.cancel()
        }
        await engine.shutdown()
    }

    /// S3-CONF-04 (b): the first burst of user-initiated work after the engine went idle (which drops the conditions,
    /// R-SYN-14) is dispatched before the watcher's first element and is never trimmed once `.critical` arrives. The
    /// gated source holds the watcher's observation until the burst is dispatched, so the window is deterministic.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: user-initiated work started while the conditions are unknown is held to interactiveConcurrencyAtCritical once a critical thermal state arrives", .timeLimit(.minutes(1)))
    func criticalThermalCapsBurstAfterIdle() async throws {
        let base = FakeDeviceConditionsSource(initial: S3ConformanceEngineProbeTests.hot)
        let gated = GatedConditionsSource(base: base)
        let harness = S3ConformanceEngineProbeTests.harness(conditions: gated, inner: base)
        let assets = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(4_400 + index))
            return (EngineHarness.onDemand("hot\(index)", bytes), bytes)
        }
        await harness.serveManifest(assets.map(\.0))
        for (entry, bytes) in assets {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        await engine.waitUntil { !$0.watcherActive }
        await gated.close()
        let waiters = assets.map { asset in
            Task { await engine.awaitAsset(asset.0.identifier, lane: .userInitiated) }
        }
        await engine.waitUntil { $0.running + ($0.queued[.userInitiated] ?? 0) == 3 }
        await engine.waitForAllHandles()
        await gated.open()
        await engine.awaitCondition { $0.state.conditions?.power.thermal == .critical }
        await engine.waitForAllHandles()
        let state = await engine.introspect()
        #expect(state.running <= harness.configuration.power.interactiveConcurrencyAtCritical, "running at .critical: \(state.running)")
        for waiter in waiters {
            waiter.cancel()
        }
        await engine.shutdown()
    }

    /// `EngineHarness.make` with the engine observing `conditions` (the harness keeps `inner` for its helpers).
    @available(macOS 15.0, iOS 18.0, *)
    static func harness(conditions: any DeviceConditionsSource, inner: FakeDeviceConditionsSource) -> EngineHarness {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: 64 << 30, opportunisticCapacity: 64 << 30))
        let sink = ScriptedSnapshotSink()
        let pressure = FakeMemoryPressureSource()
        let tap = RecordingLogTap()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x5EED),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(version: "1.0+1"),
            legacyDefaults: FakeLegacyDefaults(),
            memoryPressure: pressure,
            logTap: tap
        )
        let storage = StoragePolicy()
        let storeConfiguration = StoreConfiguration(
            location: .applicationSupport,
            policy: storage,
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: storeConfiguration, environment: StoreEnvironment(environment: environment, snapshotSink: sink))
        let configuration = EngineConfiguration(
            tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0),
            storage: storage,
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
            sink: sink,
            source: source,
            conditions: inner,
            pressure: pressure,
            tap: tap,
            store: store,
            engine: engine,
            configuration: configuration
        )
    }
}

/// A conditions source whose observations wait while it is closed (the watcher's first element is held back).
actor GatedConditionsSource: DeviceConditionsSource {
    private let base: FakeDeviceConditionsSource
    private var closed = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(base: FakeDeviceConditionsSource) {
        self.base = base
    }

    func close() {
        self.closed = true
    }

    func open() {
        self.closed = false
        let waiting = self.waiting
        self.waiting = []
        for continuation in waiting {
            continuation.resume()
        }
    }

    func conditions() async -> AsyncStream<DeviceConditions> {
        if self.closed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.waiting.append(continuation)
            }
        }
        return await self.base.conditions()
    }
}
