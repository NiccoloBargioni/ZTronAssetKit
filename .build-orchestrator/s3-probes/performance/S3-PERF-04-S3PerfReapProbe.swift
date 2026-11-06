import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

extension ZTronAssetKitBenchmarks.StorageBenchmarks {
    /// S3-PERF probe: the reaper's own actor work grows linearly with the doomed set (P-13). `reap` keeps its queue as an
    /// `ArraySlice` and puts every key a time-bounded unit did not attempt back with `queue.insert(_:at:)` near the
    /// front, which shifts the whole remaining queue once per key: with 64-key batches of which a 1 ms unit attempts
    /// about 20 (ADR draft B-10), each unit re-inserts about 44 keys, so the reclaim costs O(n²/20) element moves. Each
    /// unlink here takes 50 µs on the injected clock (a `ManualTimeSource` the volume advances; the unit reads only
    /// that clock), so every unit stops after 20 unlinks as on the reference volume, and the fake volume's own cost is
    /// linear. The ratio of a doubled reclaim against P-4's `doubling_ratio_max`.
    @Test("P-13: reclaiming a doubled set of blobs in time-bounded units costs the store at most doubling_ratio_max times as much", .timeLimit(.minutes(3)))
    @available(macOS 15.0, iOS 18.0, *)
    func reapScaling() async throws {
        let ratioMax = try #require(try QualityBudgets().value("P-4", "doubling_ratio_max"))
        _ = try await S3ReapProbe.reapSeconds(count: 1_000)
        var seconds: [Int: Double] = [:]
        for count in [10_000, 20_000, 40_000] {
            seconds[count] = try await S3ReapProbe.reapSeconds(count: count)
        }
        let ratio = try #require(seconds[40_000]) / max(try #require(seconds[20_000]), 1e-9)
        let control20k = try await S3ReapProbe.reapSeconds(count: 20_000, batchSize: 20)
        let control40k = try await S3ReapProbe.reapSeconds(count: 40_000, batchSize: 20)
        print("S3-PERF reap control with 20-key batches (every unit attempts its whole batch, nothing is re-inserted): 20,000 \(control20k) s, 40,000 \(control40k) s, ratio \(control40k / max(control20k, 1e-9))")
        print("S3-PERF reap scaling (wall seconds of runDueWork): \(seconds.sorted { $0.key < $1.key }); 40,000 / 20,000 = \(ratio) (max \(ratioMax))")
        #expect(ratio <= ratioMax, "reclaim of a doubled set: \(ratio)×")
    }
}

/// Helpers of the S3-PERF reaper probe.
enum S3ReapProbe {
    /// The wall seconds of the `runDueWork()` that reclaims `count` doomed 16-byte blobs, every unlink advancing the
    /// store's `ManualTimeSource` by 50 µs.
    @available(macOS 15.0, iOS 18.0, *)
    static func reapSeconds(count: Int, batchSize: Int = StoreConfiguration().deletionBatchSize) async throws -> Double {
        let time = ManualTimeSource()
        let fake = FakeFileSystem(time: time)
        let environment = AssetEnvironment(
            fileSystem: ClockedUnlinkFileSystem(base: fake, time: time, unlinkSeconds: 0.000_05),
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 9),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        var policy = StoragePolicy()
        policy.deletionGrace = 0
        var configuration = StoreConfiguration(
            policy: policy,
            legacy: LegacyMigrationPolicy(enabled: false),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        configuration.deletionBatchSize = batchSize
        let payloads = (0..<count).map { GeneratedPayload.bytes(seed: UInt64(90_000 + $0), offset: 0, length: 16) }
        let entries = payloads.enumerated().map { index, bytes in
            ManifestEntry(identifier: AssetID("reap.\(index)"), fileExtension: "png", remotePath: "media/\(index).png", byteSize: 16, checksum: ContentHash.sha256(of: bytes))
        }
        let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("reap".utf8)))
        let first = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        _ = try await first.open()
        _ = try await first.apply(manifest, etag: nil, eviction: nil)
        await first.close()
        // The blobs as a previous launch left them; the next open adopts every one by hash (the P-13 benchmark's shape).
        let layout = try StoreLayout(base: fake.standardDirectory(.applicationSupport))
        for (entry, bytes) in zip(entries, payloads) {
            let key = BlobKey(hash: entry.checksum!, ext: AssetFileExtension("png")!)
            try fake.createDirectory(at: layout.root)
            try fake.createDirectory(at: layout.blobsDirectory)
            try fake.createDirectory(at: layout.fanOutDirectory(for: key.hash))
            try fake.write(bytes, to: layout.blobURL(key), mode: .truncate)
        }
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let report = try await store.open()
        guard report.missingBlobs == 0 else {
            throw S3ReapProbeError.setup("\(report.missingBlobs) blobs were not adopted")
        }
        _ = try await store.apply(ValidatedManifest.empty(), etag: nil, eviction: nil)
        let clock = ContinuousClock()
        let start = clock.now
        let work = await store.runDueWork()
        let elapsed = clock.now - start
        await store.close()
        guard work.reapedKeys == count else {
            throw S3ReapProbeError.setup("reaped \(work.reapedKeys) of \(count)")
        }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

enum S3ReapProbeError: Error {
    case setup(String)
}

@available(macOS 15.0, iOS 18.0, *)
/// A fake volume whose blob unlinks each take `unlinkSeconds` on the injected `ManualTimeSource` (and no real time).
struct ClockedUnlinkFileSystem: FileSystem {
    let base: FakeFileSystem
    let time: ManualTimeSource
    let unlinkSeconds: TimeInterval

    func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        try self.base.read(from: url, offset: offset, maxLength: maxLength)
    }

    func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL {
        try self.base.standardDirectory(directory)
    }

    func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo? {
        try self.base.itemInfo(at: url)
    }

    func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo] {
        try self.base.contentsOfDirectory(at: url)
    }

    func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        try self.base.availableCapacity(at: url, for: purpose)
    }

    func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        try self.base.storeAttributes(at: url)
    }

    func createDirectory(at url: URL) throws(FileSystemError) {
        try self.base.createDirectory(at: url)
    }

    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        try self.base.write(data, to: url, mode: mode)
    }

    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.base.synchronizeFile(at: url, level: level)
    }

    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.base.synchronizeDirectory(at: url, level: level)
    }

    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        try self.base.rename(from: source, to: destination, mode: mode)
    }

    func removeItem(at url: URL) throws(FileSystemError) {
        try self.base.removeItem(at: url)
        if url.path.contains("/blobs/") {
            self.time.advance(by: self.unlinkSeconds)
        }
    }

    func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        try self.base.applyStoreAttributes(attributes, at: url)
    }

    func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        try self.base.acquireExclusiveLock(at: url)
    }

    func releaseLock(_ token: FileLockToken) {
        self.base.releaseLock(token)
    }
}
