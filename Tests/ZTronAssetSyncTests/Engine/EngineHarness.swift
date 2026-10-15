import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync
import ZTronAssetTestSupport

/// Manifest and payload builders for engine tests (WP-F).
enum EngineFixture {
    /// Deterministic payload bytes.
    static func bytes(_ seed: UInt64, count: Int = 300) -> Data {
        GeneratedPayload.bytes(seed: seed, offset: 0, length: count)
    }

    /// An entry for `bytes`; checksum-less when `checksum` is false.
    static func entry(
        _ id: String,
        _ bytes: Data,
        policy: AssetPolicy = .standard,
        tags: [String] = [],
        checksum: Bool = true,
        size: Bool = true,
        ext: String = "png",
        directory: [String] = ["dir"]
    ) -> ManifestEntry {
        ManifestEntry(
            identifier: AssetID(id),
            fileExtension: ext,
            remotePath: "media/\(id).\(ext)",
            localPathComponents: directory,
            byteSize: size ? Int64(bytes.count) : nil,
            checksum: checksum ? ContentHash.sha256(of: bytes) : nil,
            tags: tags,
            policy: policy
        )
    }

    /// The wire bytes of a manifest (the prior art's bare array, R-MAN-1).
    static func manifestData(_ entries: [ManifestEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain value types cannot fail.
        return (try? encoder.encode(entries)) ?? Data("[]".utf8)
    }

    /// A strong ETag for `tag`.
    static func etag(_ tag: String) -> ETag? {
        ETag(rawValue: "\"\(tag)\"")
    }
}

/// An engine over a real `AssetStore` on `FakeFileSystem`, `ManualTimeSource`, `FakeRemoteSource` and the fake
/// conditions and memory-pressure sources (ARCHITECTURE §14). Gated for the Mutex-backed fakes (ADR-051).
@available(macOS 15.0, iOS 18.0, *)
struct EngineHarness {
    let time: ManualTimeSource
    let fileSystem: FakeFileSystem
    let sink: ScriptedSnapshotSink
    let source: FakeRemoteSource
    let conditions: FakeDeviceConditionsSource
    let pressure: FakeMemoryPressureSource
    let tap: RecordingLogTap
    let store: AssetStore
    let engine: SyncEngine
    let configuration: EngineConfiguration

    /// The store root's base on the fake volume.
    static let base = URL(fileURLWithPath: "/fake-volume/Library/Application Support", isDirectory: true)

    /// Builds a harness; nothing is started.
    static func make(
        disk: DiskImage = DiskImage(),
        time: ManualTimeSource = ManualTimeSource(),
        source: FakeRemoteSource = FakeRemoteSource(),
        conditions: DeviceConditions = .unrestricted,
        tuning: SyncTuning = SyncTuning(),
        storage: StoragePolicy = StoragePolicy(),
        network: NetworkPolicy = NetworkPolicy(),
        power: PowerPolicy = PowerPolicy(),
        refresh: RefreshPolicy = .oncePerAppVersion,
        retentionScope: AssetScope = .all,
        appVersion: String = "1.0+1",
        metadata: (any BlockingExecutor)? = nil,
        bulk: (any BlockingExecutor)? = nil,
        planner: (any SyncPlanning)? = nil,
        capacity: Int64 = 64 << 30,
        commitInterval: TimeInterval = 0,
        installInterval: TimeInterval = 0,
        seed: UInt64 = 0x5EED,
        fileSystem existing: FakeFileSystem? = nil,
        sink existingSink: ScriptedSnapshotSink? = nil,
        remote: (any RemoteSource)? = nil,
        factory: (any RemoteSourceFactory)? = nil
    ) -> EngineHarness {
        let fileSystem = existing ?? FakeFileSystem(
            disk: disk,
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let sink = existingSink ?? ScriptedSnapshotSink()
        let conditionsSource = FakeDeviceConditionsSource(initial: conditions)
        let pressure = FakeMemoryPressureSource()
        let tap = RecordingLogTap()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: metadata ?? InlineBlockingExecutor(),
            bulkExecutor: bulk ?? InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: seed),
            conditions: conditionsSource,
            remoteSources: factory ?? FakeRemoteSourceFactory(source: remote ?? source),
            appVersion: FakeAppVersionSource(version: appVersion),
            legacyDefaults: FakeLegacyDefaults(),
            memoryPressure: pressure,
            logTap: tap
        )
        let storeConfiguration = StoreConfiguration(
            location: .applicationSupport,
            policy: storage,
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: commitInterval,
            snapshotInstallInterval: installInterval
        )
        let store = AssetStore(configuration: storeConfiguration, environment: StoreEnvironment(environment: environment, snapshotSink: sink))
        let configuration = EngineConfiguration(
            tuning: tuning,
            storage: storage,
            network: network,
            power: power,
            refresh: refresh,
            remote: RemoteConfiguration(),
            limits: ManifestLimits(),
            retentionScope: retentionScope
        )
        let engine: SyncEngine
        if let planner {
            engine = SyncEngine(store: store, environment: environment, configuration: configuration, planner: planner)
        } else {
            engine = SyncEngine(store: store, environment: environment, configuration: configuration)
        }
        return EngineHarness(
            time: time,
            fileSystem: fileSystem,
            sink: sink,
            source: source,
            conditions: conditionsSource,
            pressure: pressure,
            tap: tap,
            store: store,
            engine: engine,
            configuration: configuration
        )
    }

    /// Scripts the next manifest fetch to return `entries` and every entry's transfer to stage its bytes.
    func serve(_ entries: [(ManifestEntry, Data)], etag: String = "v1") async {
        await self.source.scriptManifest([.fetched(EngineFixture.manifestData(entries.map(\.0)), etag: EngineFixture.etag(etag))])
        for (entry, bytes) in entries {
            await self.source.script(entry.transferID, [.stage(bytes)])
        }
    }

    /// Scripts every entry's transfer to stage its bytes.
    func scriptTransfers(_ entries: [(ManifestEntry, Data)]) async {
        for (entry, bytes) in entries {
            await self.source.script(entry.transferID, [.stage(bytes)])
        }
    }

    /// Applies `entries` through a run whose transfers are not scripted to succeed: on-demand entries stay absent.
    static func onDemand(_ id: String, _ bytes: Data) -> ManifestEntry {
        EngineFixture.entry(id, bytes, policy: .onDemand)
    }

    /// Scripts the next manifest fetch only.
    func serveManifest(_ entries: [ManifestEntry], etag: String = "v1") async {
        await self.source.scriptManifest([.fetched(EngineFixture.manifestData(entries), etag: EngineFixture.etag(etag))])
    }

    /// Starts the engine and requires success.
    @discardableResult
    func start() async throws -> OpenReport {
        try await self.engine.start().get()
    }

    /// The store's planning view.
    func view() async throws -> StorePlanningView {
        try await self.store.planningView()
    }

    /// Whether the engine owns nothing and the environment observes nothing (R-SYN-14's census).
    func isQuiet() async -> Bool {
        let state = await self.engine.introspect()
        let observers = await self.conditions.activeObservers
        let transfers = await self.source.activeTransfers
        return state.isIdleSilent && state.waiters == 0 && state.interests == 0 && self.time.pendingSleepers == 0 && observers == 0 && transfers == 0
    }

    /// Drives the manual clock until `predicate` holds. Each round advances the clock to the earliest sleeper (the
    /// engine's alarm, or a store wait in an engine-owned task) when it is at most `maxStep` away; otherwise it waits for
    /// whichever comes first: the predicate, any change of the engine's counters, or one more sleeper (the other waits
    /// end on their cancellation). A sleeper further away than `maxStep` is a timeout the test must not trigger (the
    /// manifest fetch deadline while the fetch still works). Never a wall-clock wait.
    func drive(rounds: Int = 1_024, maxStep: TimeInterval = .infinity, until predicate: @escaping @Sendable (EngineIntrospection) -> Bool) async throws {
        let engine = self.engine
        let time = self.time
        for _ in 0..<rounds {
            let state = await engine.introspect()
            if predicate(state) {
                return
            }
            if let deadline = time.nextDeadline, deadline <= time.monotonicNow().adding(seconds: maxStep) {
                time.advance(to: deadline)
                continue
            }
            let waiting = time.pendingSleepers
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await engine.waitUntil { $0 != state || predicate($0) }
                }
                group.addTask {
                    await time.waitForSleepers(atLeast: waiting + 1)
                }
                _ = await group.next()
                group.cancelAll()
            }
            try Task.checkCancellation()
        }
        throw EngineHarnessError.neverQuiesced(await engine.introspect())
    }

    /// Runs `operation` while a driver wakes every sleeper on the manual clock (a purge's grace wait, a commit window,
    /// a backoff), then stops the driver (its wait ends on cancellation).
    func withClock<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        let time = self.time
        let driver = Task {
            while !Task.isCancelled {
                await time.waitForSleepers(atLeast: 1)
                if let deadline = time.nextDeadline {
                    time.advance(to: deadline)
                }
            }
        }
        defer {
            driver.cancel()
        }
        return try await operation()
    }

    /// Drives the clock until the engine is idle-silent and the conditions source observes nothing.
    func settle(rounds: Int = 256) async throws {
        try await self.drive(rounds: rounds) { $0.isIdleSilent }
        try await self.conditions.requireObservers(equalTo: 0)
    }

    /// Runs `sync(.force)` while driving the clock (store commit windows and the alarm need time to pass).
    func syncDriven(_ mode: SyncMode = .force) async throws -> SyncOutcome {
        let engine = self.engine
        let run = Task { await engine.sync(mode) }
        await engine.waitUntil { $0.groups >= 1 || $0.lifecycle != .running }
        try await self.drive { $0.groups == 0 }
        return await run.value
    }
}

/// Harness failures.
enum EngineHarnessError: Error {
    /// The engine kept owning work.
    case neverQuiesced(EngineIntrospection)
}
