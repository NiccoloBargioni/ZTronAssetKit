import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// WP-C's test fixtures (namespaced `Cleanup*`): configurations with eviction, cleanup and legacy knobs, over WP-B's
/// `CoreHarness` (a store on `FakeFileSystem`, `ManualTimeSource`, `ScriptedSnapshotSink`, inline executors).
enum CleanupFixture {
    /// The legacy root every legacy test uses: the prior art's default, `<Caches>/CDNAssets`, on the fake volume.
    static let legacyRoot = URL(fileURLWithPath: "/fake-volume/Library/Caches/CDNAssets", isDirectory: true)
    /// The prior art's `UserDefaults` key.
    static let legacyKey = LegacyMigrationPolicy().defaultsKey

    /// A policy for cleanup tests: no minimum residency unless asked, the default 10 s grace.
    static func policy(
        budget: StorageBudget = .unlimited,
        reserveFreeBytes: Int64 = 0,
        hysteresisTarget: Double = 0.9,
        minimumResidency: TimeInterval = 0,
        deletionGrace: TimeInterval = 10,
        orphanGrace: TimeInterval = 3_600,
        stagingClaimGrace: TimeInterval = 3_600,
        stagingMaxAge: TimeInterval = 72 * 3_600,
        maxIntegrityAttempts: Int = 3
    ) -> StoragePolicy {
        StoragePolicy(
            budget: budget,
            reserveFreeBytes: reserveFreeBytes,
            hysteresisTarget: hysteresisTarget,
            minimumResidency: minimumResidency,
            deletionGrace: deletionGrace,
            orphanGrace: orphanGrace,
            stagingClaimGrace: stagingClaimGrace,
            stagingMaxAge: stagingMaxAge,
            maxIntegrityAttempts: maxIntegrityAttempts
        )
    }

    /// A store configuration with `policy`, legacy migration off unless `legacy` says otherwise, no coalescing delay.
    static func configuration(
        location: StorageLocation = .applicationSupport,
        policy: StoragePolicy = CleanupFixture.policy(),
        legacy: LegacyMigrationPolicy = LegacyMigrationPolicy(enabled: false),
        limits: ManifestLimits = ManifestLimits(),
        commitInterval: TimeInterval = 0,
        installInterval: TimeInterval = 0,
        deletionBatchSize: Int = 64
    ) -> StoreConfiguration {
        StoreConfiguration(
            location: location,
            policy: policy,
            legacy: legacy,
            limits: limits,
            commitMinimumInterval: commitInterval,
            snapshotInstallInterval: installInterval,
            deletionBatchSize: deletionBatchSize,
            hashChunkBytes: 1 << 20
        )
    }

    /// Legacy migration on, rooted at `legacyRoot`, reading the prior art's key.
    static let legacyPolicy = LegacyMigrationPolicy(enabled: true, root: CleanupFixture.legacyRoot)

    /// One asset of a seeded store: its entry and bytes.
    struct Asset: Sendable {
        let entry: ManifestEntry
        let bytes: Data

        var id: AssetID {
            self.entry.identifier
        }

        var key: BlobKey {
            CoreFixture.key(self.bytes, ext: self.entry.fileExtension)
        }
    }

    /// An asset named `id` of `count` deterministic bytes from `seed`.
    static func asset(_ id: String, seed: UInt64, count: Int = 300, ext: String = "png", tags: [String] = [], policy: AssetPolicy = .standard) -> Asset {
        let bytes = CoreFixture.bytes(seed, count: count)
        var entry = CoreFixture.entry(id, bytes, ext: ext, tags: tags)
        entry.policy = policy
        return Asset(entry: entry, bytes: bytes)
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension CoreHarness {
    /// A store over the fake with WP-C's cleanup configuration.
    static func cleanup(
        disk: DiskImage = DiskImage(),
        location: StorageLocation = .applicationSupport,
        policy: StoragePolicy = CleanupFixture.policy(),
        legacy: LegacyMigrationPolicy = LegacyMigrationPolicy(enabled: false),
        defaults: FakeLegacyDefaults = FakeLegacyDefaults(),
        importantCapacity: Int64 = 64 << 30,
        commitInterval: TimeInterval = 0,
        installInterval: TimeInterval = 0,
        deletionBatchSize: Int = 64,
        crashBefore: Int? = nil,
        mode: CrashMode = .processKill,
        time: ManualTimeSource = ManualTimeSource(),
        metadata: (any BlockingExecutor)? = nil,
        bulk: (any BlockingExecutor)? = nil,
        sink: ScriptedSnapshotSink = ScriptedSnapshotSink(),
        sinkOverride: (any SnapshotSink)? = nil
    ) -> CoreHarness {
        let fileSystem = FakeFileSystem(
            disk: disk,
            time: time,
            configuration: FakeFileSystemConfiguration(crashBefore: crashBefore, crashMode: mode, importantCapacity: importantCapacity)
        )
        let configuration = CleanupFixture.configuration(
            location: location,
            policy: policy,
            legacy: legacy,
            commitInterval: commitInterval,
            installInterval: installInterval,
            deletionBatchSize: deletionBatchSize
        )
        let tap = RecordingLogTap()
        let metadataExecutor = metadata ?? InlineBlockingExecutor()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: metadataExecutor,
            bulkExecutor: bulk ?? InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x5EED),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: defaults,
            logTap: tap
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: sinkOverride ?? sink))
        return CoreHarness(
            fileSystem: fileSystem,
            time: time,
            sink: sink,
            tap: tap,
            store: store,
            configuration: configuration,
            metadata: metadataExecutor
        )
    }

    /// Opens the store, applies `assets` as the manifest and publishes each one (one transfer per asset).
    func seed(_ assets: [CleanupFixture.Asset]) async throws {
        _ = try await self.store.open()
        _ = try await self.store.apply(CoreFixture.manifest(assets.map(\.entry)), etag: nil, eviction: nil)
        for (index, asset) in assets.enumerated() {
            try await self.publish(asset.bytes, [asset.entry], urgency: .userInitiated, sequence: UInt32(index + 1))
        }
        try await self.store.flush(.ordered)
    }

    /// Drives the deletion protocol to its end: the install that drops the doomed keys (acknowledged), the awake-clock
    /// grace, then the fresh install and the reap of `runDueWork()`.
    @discardableResult
    func settleDeletions() async -> StoreWorkReport {
        _ = await self.store.runDueWork()
        self.time.advance(by: self.configuration.policy.deletionGrace)
        return await self.store.runDueWork()
    }

    /// Whether the blob of `key` is on the fake.
    func hasBlob(_ key: BlobKey) -> Bool {
        self.exists(self.layout.blobURL(key))
    }

    /// The record of `id`.
    func record(_ id: AssetID) async -> AssetRecord? {
        await self.store.state.core.records[id]
    }

    /// Whether `id` is present at `key`.
    func isPresent(_ id: AssetID, at key: BlobKey) async -> Bool {
        await self.record(id)?.referencedBlob == key
    }
}

extension AssetStore {
    /// Test seam for `EvictionState.chunk` (ADR-050 rule 4(f): internal, in the test target only): lets a handful of
    /// blobs reach quota eviction's yield between chunks (REENTRANCY R8).
    func testSetEvictionChunk(_ chunk: Int) {
        self.state.eviction.chunk = chunk
    }
}

/// Drives one operation through a `SteppedBlockingExecutor` while other units stay held (REENTRANCY tests: the
/// operation's units are released one by one as they arrive, the held point under test is not).
@available(macOS 15.0, iOS 18.0, *)
enum CleanupSteps {
    /// Set once the driven operation returned or threw.
    actor Finished {
        private(set) var value = false

        func set() {
            self.value = true
        }
    }

    /// Runs `operation` to completion, releasing every unit held on `executor` except `kept`; returns its value and the
    /// units released for it, in order.
    static func run<T: Sendable>(
        _ executor: SteppedBlockingExecutor,
        keeping kept: Set<Int>,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> (value: T, released: [Int]) {
        let finished = Finished()
        let task = Task { () async throws -> T in
            do {
                let value = try await operation()
                await finished.set()
                return value
            } catch {
                await finished.set()
                throw error
            }
        }
        var released: [Int] = []
        try await CorePoll.until("the driven operation finished") {
            for unit in await executor.heldUnits where !kept.contains(unit) {
                await executor.release(unit)
                released.append(unit)
            }
            return await finished.value
        }
        return (try await task.value, released)
    }
}
