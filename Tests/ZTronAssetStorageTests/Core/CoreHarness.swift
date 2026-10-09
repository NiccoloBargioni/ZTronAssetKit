import CryptoKit
import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// WP-B's test machinery (namespaced `Core*` so no other package's helpers can collide).
enum CoreFixture {
    /// The fake volume's Application Support directory, the default base.
    static let base = URL(fileURLWithPath: "/fake-volume/Library/Application Support", isDirectory: true)
    /// The layout every default-located test store uses.
    static let layout = StoreLayout(base: CoreFixture.base)

    /// A test configuration: legacy migration off (WP-C's hook stays a stub), no eviction, no coalescing delays
    /// unless a test asks for them.
    static func configuration(
        location: StorageLocation = .applicationSupport,
        policy: StoragePolicy = StoragePolicy(),
        limits: ManifestLimits = ManifestLimits(),
        commitInterval: TimeInterval = 0,
        installInterval: TimeInterval = 0,
        deletionBatchSize: Int = 64,
        hashChunkBytes: Int = 1 << 20
    ) -> StoreConfiguration {
        StoreConfiguration(
            location: location,
            policy: policy,
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: limits,
            commitMinimumInterval: commitInterval,
            snapshotInstallInterval: installInterval,
            deletionBatchSize: deletionBatchSize,
            hashChunkBytes: hashChunkBytes
        )
    }

    /// Deterministic payload bytes.
    static func bytes(_ seed: UInt64, count: Int = 300) -> Data {
        GeneratedPayload.bytes(seed: seed, offset: 0, length: count)
    }

    /// A manifest entry for `bytes`; checksum-less when `checksum` is false.
    static func entry(_ id: String, _ bytes: Data, ext: String = "png", checksum: Bool = true, size: Bool = true, tags: [String] = []) -> ManifestEntry {
        ManifestEntry(
            identifier: AssetID(id),
            fileExtension: ext,
            remotePath: "media/\(id).\(ext)",
            localPathComponents: ["dir"],
            byteSize: size ? Int64(bytes.count) : nil,
            checksum: checksum ? ContentHash.sha256(of: bytes) : nil,
            tags: tags
        )
    }

    /// A validated manifest of `entries` (digest derived from the identifiers, so equal lists are equal manifests).
    static func manifest(_ entries: [ManifestEntry], etagSeed: String = "") -> ValidatedManifest {
        let digest = ContentHash.sha256(of: Data((entries.map(\.identifier.rawValue).joined(separator: ",") + etagSeed).utf8))
        // Test entries never repeat an identifier.
        return (try? ValidatedManifest(entries: entries, digest: digest)) ?? .empty()
    }

    /// The SHA-256 of `bytes` as a blob key.
    static func key(_ bytes: Data, ext: String = "png") -> BlobKey {
        BlobKey(hash: ContentHash.sha256(of: bytes), ext: AssetFileExtension(ext) ?? AssetFileExtension("bin")!)
    }

    /// The path of a blob under the default layout.
    static func blobPath(_ key: BlobKey) -> String {
        CoreFixture.layout.blobURL(key).path
    }

    /// A directory inside this repository for live file-system tests (never the system temporary directory,
    /// ARCHITECTURE §14); git-ignored through `.build*`. The caller removes it.
    static func liveDirectory(_ name: String, filePath: String = #filePath) throws -> URL {
        let repository = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = repository
            .appendingPathComponent(".build-tests", isDirectory: true)
            .appendingPathComponent("storage-core", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// A store over a `FakeFileSystem`, a manual clock and a scripted sink, plus helpers to stage and publish
/// (WP-B tests; `@available(macOS 15.0, iOS 18.0, *)` per test, ADR-014).
@available(macOS 15.0, iOS 18.0, *)
struct CoreHarness {
    let fileSystem: FakeFileSystem
    let time: ManualTimeSource
    let sink: ScriptedSnapshotSink
    let tap: RecordingLogTap
    let store: AssetStore
    let configuration: StoreConfiguration
    let metadata: any BlockingExecutor

    /// A store on `disk` (crash and fault settings for the fake), not opened yet.
    static func make(
        disk: DiskImage = DiskImage(),
        configuration: StoreConfiguration = CoreFixture.configuration(),
        crashBefore: Int? = nil,
        mode: CrashMode = .processKill,
        time: ManualTimeSource = ManualTimeSource(),
        metadata: (any BlockingExecutor)? = nil,
        bulk: (any BlockingExecutor)? = nil,
        sink: ScriptedSnapshotSink = ScriptedSnapshotSink(),
        importantCapacity: Int64 = 64 << 30,
        seed: UInt64 = 0x5EED
    ) -> CoreHarness {
        let fileSystem = FakeFileSystem(
            disk: disk,
            time: time,
            configuration: FakeFileSystemConfiguration(crashBefore: crashBefore, crashMode: mode, importantCapacity: importantCapacity)
        )
        return CoreHarness.make(
            fileSystem: fileSystem,
            configuration: configuration,
            time: time,
            metadata: metadata,
            bulk: bulk,
            sink: sink,
            seed: seed
        )
    }

    /// A store over any file system.
    static func make(
        fileSystem: FakeFileSystem,
        configuration: StoreConfiguration,
        time: ManualTimeSource,
        metadata: (any BlockingExecutor)? = nil,
        bulk: (any BlockingExecutor)? = nil,
        sink: ScriptedSnapshotSink = ScriptedSnapshotSink(),
        seed: UInt64 = 0x5EED
    ) -> CoreHarness {
        let tap = RecordingLogTap()
        let metadataExecutor = metadata ?? InlineBlockingExecutor()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: metadataExecutor,
            bulkExecutor: bulk ?? InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: seed),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults(),
            logTap: tap
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: sink))
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

    /// A store environment over any file system (spies), with inline executors unless given.
    static func environment(
        fileSystem: any FileSystem,
        time: any TimeSource,
        sink: any SnapshotSink = ScriptedSnapshotSink(),
        metadata: any BlockingExecutor = InlineBlockingExecutor(),
        bulk: any BlockingExecutor = InlineBlockingExecutor()
    ) -> StoreEnvironment {
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: metadata,
            bulkExecutor: bulk,
            time: time,
            random: SeededRandom(seed: 0x5EED),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        return StoreEnvironment(environment: environment, snapshotSink: sink)
    }

    /// The default layout.
    var layout: StoreLayout {
        CoreFixture.layout
    }

    /// Writes `bytes` into staging as a complete `.part` through the store's own sink (two chunks) and describes it.
    func stage(_ bytes: Data, for entry: ManifestEntry, sequence: UInt32 = 1, epoch: UInt64? = nil, sidecar: Bool = false) async throws -> StagedFile {
        let sink = try await self.store.makeStagingSink()
        let launchEpoch: UInt64
        if let epoch {
            launchEpoch = epoch
        } else {
            launchEpoch = await self.store.state.core.launchEpoch
        }
        let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: launchEpoch, sequence: sequence), kind: .partial)
        try sink.createPartial(name)
        let half = bytes.count / 2
        _ = try sink.appendPartial(bytes.prefix(half), to: name)
        let size = try sink.appendPartial(bytes.suffix(from: half), to: name)
        if sidecar {
            sink.writeSidecar(ResumeSidecar(name: name, validator: .strongETag(ETag(rawValue: "\"v1\"")!), receivedBytes: size, expectedBytes: size))
        }
        return StagedFile(name: name, byteCount: size, resumed: false, httpStatus: 200, etag: nil)
    }

    /// Stages and publishes `bytes` for `entries` (one transfer binding every id).
    @discardableResult
    func publish(_ bytes: Data, _ entries: [ManifestEntry], urgency: AssetPriority = .bulk, sequence: UInt32 = 1) async throws -> [AssetID: AssetLocation] {
        let staged = try await self.stage(bytes, for: entries[0], sequence: sequence)
        return try await self.store.publish(staged, binding: entries.map(\.identifier), expecting: entries[0].contentIdentity, urgency: urgency)
    }

    /// The store's state (actor-isolated read).
    var state: StoreState {
        get async {
            await self.store.state
        }
    }

    /// A file's content on the fake, or `nil`.
    func content(_ url: URL) -> Data? {
        try? self.fileSystem.read(from: url, offset: 0, maxLength: 1 << 20)
    }

    /// Whether the fake has an item at `url`.
    func exists(_ url: URL) -> Bool {
        ((try? self.fileSystem.itemInfo(at: url)) ?? nil) != nil
    }

    /// Mutation records (crash boundaries) of the op log, in order.
    var mutations: [FSOpRecord] {
        self.fileSystem.operations.filter { $0.kind.isMutation }
    }
}

/// Checks I-1, I-2 and I-4 over a reopened store and its disk (store.md §9.1 `InvariantChecker`); the crash tests add
/// I-3 (`blobRemovals`) and I-5 (the generations that returned).
@available(macOS 15.0, iOS 18.0, *)
enum CoreInvariants {
    /// The unlinks of well-named blobs in `operations`, as I-3 violations: in a scenario that prunes nothing and lets
    /// no grace pass, any such unlink removes a blob a reader may hold.
    static func blobRemovals(_ operations: [FSOpRecord], layout: StoreLayout) -> [String] {
        let prefix = layout.blobsDirectory.path + "/"
        return operations.filter { operation in
            operation.kind == .removeItem && operation.url.path.hasPrefix(prefix) && StoreLayout.parseBlobName(operation.url.lastPathComponent) != nil
        }.map { "I-3: \($0.url.lastPathComponent) was unlinked" }
    }

    /// The violated invariants, as readable lines; empty when I-1, I-2 and I-4 hold.
    static func violations(of harness: CoreHarness, allowNeedsHeal: Bool = false) async -> [String] {
        var found: [String] = []
        let disk = harness.fileSystem.survivingDisk()
        let blobsPrefix = harness.layout.blobsDirectory.path + "/"
        // I-1: every file under blobs/ is complete and named by the SHA-256 of its bytes.
        for (path, bytes) in disk.files where path.hasPrefix(blobsPrefix) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard let key = StoreLayout.parseBlobName(name) else {
                found.append("I-1: foreign name \(path)")
                continue
            }
            if ContentHash.sha256(of: Data(bytes)) != key.hash {
                found.append("I-1: \(path) holds \(bytes.count) bytes that do not hash to its name")
            }
        }
        let state = await harness.state
        // I-2: every present record has its blob with the recorded size.
        for (id, record) in state.core.records {
            switch record.residency {
            case .present(let blob, let size, _):
                let path = harness.layout.blobURL(blob).path
                if disk.files[path]?.count != Int(size) {
                    found.append("I-2: \(id.rawValue) references \(blob.fileName), which is missing or the wrong size")
                }
            case .needsHeal where !allowNeedsHeal:
                found.append("I-2: \(id.rawValue) needs healing although no blob was removed externally")
            default:
                break
            }
        }
        // I-4: no snapshot entry and no record points into staging.
        for entry in state.core.presentTable.values where !entry.location.url.path.hasPrefix(blobsPrefix) {
            found.append("I-4: \(entry.location.url.path) is not a blob")
        }
        // DOOMED ∩ referenced = ∅ (store-2 S2-04).
        for (key, blobState) in state.core.blobTable {
            if case .doomed = blobState, state.core.records.values.contains(where: { $0.referencedBlob == key }) {
                found.append("S2-04: \(key.fileName) is doomed and referenced")
            }
        }
        // The incremental snapshot table equals a rebuild.
        if state.core.presentTable != SnapshotTable.build(records: state.core.records, layout: harness.layout) {
            found.append("snapshot table drifted from the records")
        }
        return found
    }
}

/// Wraps an executor and records the duration of every unit (P-13 batches, unit-shape assertions).
final class CountingExecutor: BlockingExecutor {
    private let base: any BlockingExecutor
    private let counter = UnitCounter()

    /// Wraps `base`.
    init(_ base: any BlockingExecutor = InlineBlockingExecutor()) {
        self.base = base
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await self.counter.increment()
        return await self.base.run(work)
    }

    /// Units submitted so far.
    var units: Int {
        get async {
            await self.counter.value
        }
    }
}

/// The counter behind `CountingExecutor`.
actor UnitCounter {
    private(set) var value = 0

    func increment() {
        self.value += 1
    }
}

/// Polling without sleeping (SPEC 7.2) that never outlives its test.
@available(macOS 15.0, iOS 18.0, *)
enum CorePoll {
    /// Evaluates `condition` until it holds, yielding in between. A test whose time limit ran out is cancelled: the poll
    /// then records an issue naming what it waited for and throws `CancellationError`, so the test ends within its limit
    /// and the run goes on (close-out cycle 5: with a fix reverted, a test kept polling at full speed after its limit,
    /// and the test process never exited). `condition` may do work of its own between checks (a flush, say).
    static func until(
        _ waitingFor: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async throws -> Bool
    ) async throws {
        while true {
            if try await condition() {
                return
            }
            if Task.isCancelled {
                Issue.record("Cancelled while waiting for \(waitingFor())", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}
