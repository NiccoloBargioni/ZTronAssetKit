import CryptoKit
import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

extension ZTronAssetKitBenchmarks {
    /// P-2, P-5, P-6 and P-13 (WP-B), release configuration, live file system in directories inside this repository
    /// (`.build-tests/`, git-ignored). Every threshold comes from `QualityBudgets`.
    ///
    /// **Statistics (ADR draft B-9).** Durations are judged on their p95, never their maximum: the store design
    /// measured single-sample tails 2–3× the p95 on this Mac (store.md §11 R1), which are scheduler noise on a shared
    /// machine and would make a max-based budget flaky (Q-5); a regression moves the p95. P-5's budget applies to the
    /// ordered commit a bulk sync performs (≤ 4/s); durable commits (flush, close, adoption report) are judged on
    /// their median, because their tail is the device-wide cache flush of `F_FULLFSYNC`, shared with every other
    /// process's I/O. Throughput (P-6) takes the best of five runs of each variant after a warm-up: interference only
    /// ever slows a run down. Memory (P-6) is the peak resident delta sampled inside every read, while the chunk is
    /// alive. P-13's batch budget is applied to the p95 of the deletion-unit durations; the maximum is printed beside
    /// it, so a single slow outlier stays visible (ADR draft B-9). C2 has no budget key: its test reports the longest
    /// hold of the store's actor seen by a probe, best of five runs, against the rule's own 10 ms.
    @Suite("StorageBenchmarks")
    struct StorageBenchmarks {
        @Test("P-2: cold index load of 10,000 records off the main thread is under budget", .timeLimit(.minutes(1)))
        @available(macOS 15.0, *)
        func indexLoad() async throws {
            let budget = try #require(try QualityBudgets().value("P-2", "index_load_ms"))
            let directory = try StorageBench.directory("p2")
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let layout = StoreLayout(base: directory)
            try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
            let content = StorageBench.content(records: 10_000)
            let encoded = try #require(IndexCodec.encode(content))
            try encoded.write(to: layout.indexURL(.current))
            let fileSystem = LiveFileSystem()
            let metadata = DispatchBlockingExecutor(label: "bench.p2.metadata")
            let bulk = DispatchBlockingExecutor(label: "bench.p2.bulk")
            var timings: [Double] = []
            for run in 0..<28 {
                // The store's own load path (`open()` calls the same function): a stat unit, ≤ 1 MiB read units,
                // then decoding and the load rule on the bulk executor.
                let started = ContinuousClock.now
                let outcome = await IndexLoader.load(layout: layout, fileSystem: fileSystem, metadata: metadata, bulk: bulk)
                let elapsed = StorageBench.milliseconds(ContinuousClock.now - started)
                #expect(outcome.content?.records.count == 10_000)
                if run >= 3 {
                    timings.append(elapsed)
                }
            }
            let p95 = StorageBench.percentile(timings, 0.95)
            print("P-2 index load, \(encoded.count) bytes, 10,000 records: p50 \(StorageBench.percentile(timings, 0.5)) ms, p95 \(p95) ms, max \(timings.max() ?? 0) ms, budget \(budget) ms")
            #expect(p95 <= budget)
        }

        @Test("P-5: index commit of 10,000 records is under budget and a bulk sync commits at most 4 per second", .timeLimit(.minutes(1)))
        @available(macOS 15.0, *)
        func indexCommit() async throws {
            let budgets = try QualityBudgets()
            let commitBudget = try #require(budgets.value("P-5", "index_commit_ms"))
            let rateBudget = try #require(budgets.value("P-5", "commits_per_s_max"))
            let directory = try StorageBench.directory("p5")
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let layout = StoreLayout(base: directory)
            let fileSystem = LiveFileSystem()
            try FileManager.default.createDirectory(at: layout.blobsDirectory, withIntermediateDirectories: true)
            let fanOuts = (0..<16).map { String(format: "%02x", $0 * 16) }
            for fanOut in fanOuts {
                try FileManager.default.createDirectory(at: layout.blobsDirectory.appendingPathComponent(fanOut), withIntermediateDirectories: true)
            }
            let lock = try fileSystem.acquireExclusiveLock(at: layout.lockURL)
            defer {
                fileSystem.releaseLock(lock)
            }
            var content = StorageBench.content(records: 10_000)
            let metadata = DispatchBlockingExecutor(label: "bench.p5.metadata")
            var report: [String] = []
            for (durability, runs) in [(CommitDurability.ordered, 35), (.durable, 20)] {
                var timings: [Double] = []
                for run in 0..<runs {
                    content.generation += 1
                    let input = IndexCommitInput(
                        layout: layout,
                        content: content,
                        dirtyFanOuts: fanOuts,
                        blobsDirectoryDirty: true,
                        durability: durability,
                        lock: lock
                    )
                    let started = ContinuousClock.now
                    let result = await metadata.run {
                        IndexCommitUnit.run(input, fileSystem: fileSystem)
                    }
                    let elapsed = StorageBench.milliseconds(ContinuousClock.now - started)
                    #expect((try? result.get()) != nil)
                    if run >= 3 {
                        timings.append(elapsed)
                    }
                }
                let p95 = StorageBench.percentile(timings, 0.95)
                let p50 = StorageBench.percentile(timings, 0.5)
                report.append("\(durability) p50 \(p50) ms, p95 \(p95) ms, max \(timings.max() ?? 0) ms")
                if durability == .ordered {
                    #expect(p95 <= commitBudget, "ordered commit p95 \(p95) ms")
                } else {
                    #expect(p50 <= commitBudget, "durable commit p50 \(p50) ms")
                }
            }
            // The rate: a simulated ten-second bulk sync on the manual clock, the engine's alarm served at every
            // deadline, commits counted per sliding second.
            let commitTimes = try await StorageBench.bulkSyncCommitTimes(publications: 1_000, every: 0.01)
            var worst = 0
            for (index, time) in commitTimes.enumerated() {
                worst = max(worst, commitTimes[index...].prefix { $0 < time + 1 }.count)
            }
            print("P-5 commit of 10,000 records, 16 dirty fan-outs: \(report.joined(separator: "; ")); budget \(commitBudget) ms. Bulk sync: \(commitTimes.count) commits in 10 s, at most \(worst) in any second, budget \(rateBudget)")
            #expect(Double(worst) <= rateBudget)
            #expect(commitTimes.count >= 30, "the coalesced commits keep up with the sync")
        }

        @Test("P-6: streaming SHA-256 of 256 MiB meets the throughput floor, the one-shot ratio and the memory cap", .timeLimit(.minutes(1)))
        @available(macOS 15.0, *)
        func streamingHash() async throws {
            let budgets = try QualityBudgets()
            let floor = try #require(budgets.value("P-6", "hash_mb_per_s_min"))
            let ratioFloor = try #require(budgets.value("P-6", "vs_oneshot_min_ratio"))
            let memoryCap = try #require(budgets.value("P-6", "memory_delta_mib_max"))
            let directory = try StorageBench.directory("p6")
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let size = 256 << 20
            let file = directory.appendingPathComponent("payload.bin")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            for offset in stride(from: 0, to: size, by: 1 << 20) {
                try handle.write(contentsOf: GeneratedPayload.bytes(seed: 6, offset: Int64(offset), length: 1 << 20))
            }
            try handle.close()

            // The resident size is sampled inside every read unit, while the chunk just read is still alive, so a
            // buffer allocated and freed within a unit is seen; the baseline is taken before the warm-up, so the
            // first chunk buffer counts too.
            let sampler = MemoryProbe.PeakSampler()
            let store = StorageBench.liveStore(
                directory: directory,
                bulk: DispatchBlockingExecutor(label: "bench.p6.bulk"),
                fileSystem: ReadSamplingFileSystem(sampler: sampler)
            )
            _ = try await store.open()
            sampler.start()
            _ = try await store.hashFile(at: file)
            var rates: [Double] = []
            var digest: ContentHash?
            for _ in 0..<5 {
                let started = ContinuousClock.now
                let result = try await store.hashFile(at: file)
                let seconds = StorageBench.milliseconds(ContinuousClock.now - started) / 1_000
                #expect(result.byteCount == Int64(size))
                digest = result.digest
                rates.append(Double(size) / 1_000_000 / seconds)
            }
            await store.close()
            let streaming = rates.max() ?? 0
            // The one-shot reference allocates the whole file, so it runs last.
            let whole = try Data(contentsOf: file)
            var oneShotRates: [Double] = []
            var oneShot: ContentHash?
            for _ in 0..<5 {
                let started = ContinuousClock.now
                oneShot = ContentHash(digest: SHA256.hash(data: whole))
                oneShotRates.append(Double(size) / 1_000_000 / (StorageBench.milliseconds(ContinuousClock.now - started) / 1_000))
            }
            let reference = oneShotRates.max() ?? 0
            #expect(sampler.samples >= 6 * 256, "a sample per 1 MiB read")
            let peakMiB = MemoryProbe.mebibytes(sampler.peakDelta)
            print("P-6 streaming SHA-256 of 256 MiB: \(streaming) MB/s, one-shot \(reference) MB/s, ratio \(streaming / reference), peak resident delta \(peakMiB) MiB over \(sampler.samples) in-read samples; floors \(floor) MB/s, \(ratioFloor)x, cap \(memoryCap) MiB")
            #expect(digest == oneShot)
            #expect(streaming >= floor)
            #expect(streaming / reference >= ratioFloor)
            #expect(peakMiB <= memoryCap)
        }

        @Test("P-13: reclaiming 10,000 blobs finishes under budget in batches of bounded duration", .timeLimit(.minutes(1)))
        @available(macOS 15.0, *)
        func reclaim() async throws {
            let budgets = try QualityBudgets()
            let count = Int(try #require(budgets.value("P-13", "blobs")))
            let totalBudget = try #require(budgets.value("P-13", "gc_total_s_max"))
            let batchBudget = try #require(budgets.value("P-13", "batch_ms_max"))
            let directory = try StorageBench.directory("p13")
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let payloads = (0..<count).map { GeneratedPayload.bytes(seed: UInt64($0), offset: 0, length: 64) }
            let entries = payloads.enumerated().map { index, bytes in
                ManifestEntry(identifier: AssetID("blob.\(index)"), fileExtension: "png", remotePath: "media/\(index).png", byteSize: 64, checksum: ContentHash.sha256(of: bytes))
            }
            let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("p13".utf8)))
            let first = StorageBench.liveStore(directory: directory)
            _ = try await first.open()
            _ = try await first.apply(manifest, etag: nil, eviction: nil)
            await first.close()
            // The blobs as a previous launch left them; the next open adopts every one by hash.
            let layout = StoreLayout(base: directory)
            for (entry, bytes) in zip(entries, payloads) {
                let key = BlobKey(hash: entry.checksum!, ext: AssetFileExtension("png")!)
                try FileManager.default.createDirectory(at: layout.fanOutDirectory(for: key.hash), withIntermediateDirectories: true)
                try bytes.write(to: layout.blobURL(key))
            }
            let timer = TimingExecutor(DispatchBlockingExecutor(label: "bench.p13.metadata"))
            let store = StorageBench.liveStore(directory: directory, metadata: timer, time: LiveTimeSource())
            let report = try await store.open()
            #expect(report.missingBlobs == 0)
            #expect(try await store.planningView().records.values.allSatisfy { $0.referencedBlob != nil })
            _ = try await store.apply(ValidatedManifest.empty(), etag: nil, eviction: nil)
            timer.reset()
            let started = ContinuousClock.now
            let work = await store.runDueWork()
            let total = StorageBench.milliseconds(ContinuousClock.now - started) / 1_000
            let units = timer.durations
            await store.close()
            let p95 = StorageBench.percentile(units, 0.95)
            print("P-13 reclaim of \(work.reapedKeys) blobs: \(total) s in \(units.count) units, unit p50 \(StorageBench.percentile(units, 0.5)) ms, p95 \(p95) ms, max \(units.max() ?? 0) ms; budgets \(totalBudget) s, \(batchBudget) ms")
            #expect(work.reapedKeys == count && work.reapedBytes == Int64(64 * count))
            #expect(total <= totalBudget)
            #expect(p95 <= batchBudget)
            #expect(units.count >= count / StoreConfiguration().deletionBatchSize)
        }

        @Test("C2: open and apply of 10,000 assets never hold the store's actor for more than 10 ms at a stretch", .timeLimit(.minutes(1)))
        @available(macOS 15.0, *)
        func actorStretches() async throws {
            // CLAUDE.md C2: nothing blocks a cooperative-pool thread for more than ~10 ms at a stretch. No quality-gates
            // key exists for it, so the rule's own figure is the budget.
            let budget = 10.0
            let count = 10_000
            let directory = try StorageBench.directory("c2")
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let payloads = (0..<count).map { GeneratedPayload.bytes(seed: UInt64(50_000 + $0), offset: 0, length: 64) }
            let entries = payloads.enumerated().map { index, bytes in
                ManifestEntry(identifier: AssetID("c2.asset.\(index)"), fileExtension: "png", remotePath: "media/\(index).png", byteSize: 64, checksum: ContentHash.sha256(of: bytes))
            }
            let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("c2".utf8)))
            // The first apply of a 10,000-entry manifest, on five fresh roots.
            var applyHolds: [Double] = []
            for run in 0..<5 {
                let root = directory.appendingPathComponent("apply-\(run)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let store = StorageBench.liveStore(directory: root)
                _ = try await store.open()
                applyHolds.append(
                    try await ActorHoldProbe.longestHold(of: store) {
                        _ = try await store.apply(manifest, etag: nil, eviction: nil)
                    }
                )
                await store.close()
            }
            // A root holding 10,000 present records and their blobs (the first open adopts them by hash).
            let root = directory.appendingPathComponent("open", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let first = StorageBench.liveStore(directory: root)
            _ = try await first.open()
            _ = try await first.apply(manifest, etag: nil, eviction: nil)
            await first.close()
            let layout = StoreLayout(base: root)
            for (entry, bytes) in zip(entries, payloads) {
                let key = BlobKey(hash: entry.checksum!, ext: AssetFileExtension("png")!)
                try FileManager.default.createDirectory(at: layout.fanOutDirectory(for: key.hash), withIntermediateDirectories: true)
                try bytes.write(to: layout.blobURL(key))
            }
            var openHolds: [Double] = []
            var reapplyHolds: [Double] = []
            var pruneHolds: [Double] = []
            var readoptHolds: [Double] = []
            for _ in 0..<5 {
                let store = StorageBench.liveStore(directory: root)
                openHolds.append(
                    try await ActorHoldProbe.longestHold(of: store) {
                        _ = try await store.open()
                    }
                )
                #expect(try await store.planningView().records.values.allSatisfy { $0.referencedBlob != nil })
                reapplyHolds.append(
                    try await ActorHoldProbe.longestHold(of: store) {
                        _ = try await store.apply(manifest, etag: nil, eviction: nil)
                    }
                )
                // Every asset pruned, then adopted again by hash (its doomed blob is rescued): 10,000 releases, then
                // 10,000 adoptions, as in a rebuild after the index was lost (R-STO-4).
                pruneHolds.append(
                    try await ActorHoldProbe.longestHold(of: store) {
                        _ = try await store.apply(ValidatedManifest.empty(), etag: nil, eviction: nil)
                    }
                )
                readoptHolds.append(
                    try await ActorHoldProbe.longestHold(of: store) {
                        let report = try await store.apply(manifest, etag: nil, eviction: nil)
                        #expect(report.reused.count == count)
                    }
                )
                await store.close()
            }
            // Interference only lengthens a hold: each figure is the best of its five runs (ADR draft B-9).
            let figures = [
                ("first apply", applyHolds), ("open", openHolds), ("unchanged re-apply", reapplyHolds),
                ("prune of all", pruneHolds), ("re-adoption of all", readoptHolds),
            ]
            print("C2 longest actor hold at 10,000 assets: " + figures.map { "\($0.0) \($0.1.min() ?? 0) ms (max of runs \($0.1.max() ?? 0) ms)" }.joined(separator: ", ") + "; budget \(budget) ms")
            for (name, runs) in figures {
                #expect((runs.min() ?? .infinity) <= budget, "\(name): \(runs)")
            }
        }
    }
}

/// Helpers of the storage benchmarks.
@available(macOS 15.0, *)
enum StorageBench {
    /// A directory inside this repository (`.build-tests/`, git-ignored); the caller removes it.
    static func directory(_ name: String, filePath: String = #filePath) throws -> URL {
        let repository = URL(fileURLWithPath: filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".build-tests/bench-storage/\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A store over the live file system rooted in `directory` (custom location, legacy migration off, no grace).
    ///
    /// `time` is `ManualTimeSource` unless a benchmark measures behaviour that reads the clock inside a unit (P-13's
    /// time-bounded deletion units): then it is `LiveTimeSource`, which nothing here ever sleeps on (no coalescing
    /// interval, no install interval, no grace).
    static func liveStore(
        directory: URL,
        metadata: any BlockingExecutor = DispatchBlockingExecutor(label: "bench.metadata"),
        bulk: any BlockingExecutor = DispatchBlockingExecutor(label: "bench.bulk"),
        time: any TimeSource = ManualTimeSource(),
        fileSystem: any FileSystem = LiveFileSystem()
    ) -> AssetStore {
        var policy = StoragePolicy()
        policy.deletionGrace = 0
        let configuration = StoreConfiguration(
            location: .custom(directory),
            policy: policy,
            legacy: LegacyMigrationPolicy(enabled: false),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: metadata,
            bulkExecutor: bulk,
            time: time,
            random: SeededRandom(seed: 13),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        return AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
    }

    /// `count` realistic present records (store.md §2.3's measurement shape).
    static func content(records count: Int) -> IndexContent {
        var records: [AssetID: AssetRecord] = [:]
        var entries: [ManifestEntry] = []
        for index in 0..<count {
            let checksum = ContentHash.sha256(of: Data("asset-\(index)".utf8))
            let entry = ManifestEntry(
                identifier: AssetID("bo7.ri.easter.egg.asset.\(index)"),
                fileExtension: "png",
                remotePath: "media/\(checksum.hex.prefix(16))/asset.\(index).png",
                localPathComponents: ["bo7", "ri", "easter"],
                byteSize: Int64(100_000 + index),
                checksum: checksum,
                tags: ["ri", "map"]
            )
            entries.append(entry)
            records[entry.identifier] = AssetRecord(
                entry: entry,
                residency: .present(blob: BlobKey(hash: checksum, ext: AssetFileExtension("png")!), byteSize: Int64(100_000 + index), integrity: .verified),
                expectedBlob: checksum,
                lastAccess: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index)),
                storedAt: Date(timeIntervalSinceReferenceDate: 690_000_000)
            )
        }
        var content = IndexContent.empty(storeID: StoreIdentifier(high: 1, low: 2))
        content.records = records
        content.appliedManifest = (try? ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("bench".utf8)))) ?? .empty()
        content.generation = 1
        return content
    }

    /// The commit instants (seconds on the manual clock) of a simulated bulk sync: `publications` bulk publications
    /// `every` seconds apart, with the engine's alarm served whenever the store's deadline is due.
    static func bulkSyncCommitTimes(publications: Int, every interval: TimeInterval) async throws -> [Double] {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 5),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(legacy: LegacyMigrationPolicy(enabled: false)),
            environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
        )
        let payloads = (0..<publications).map { GeneratedPayload.bytes(seed: UInt64(10_000 + $0), offset: 0, length: 32) }
        let entries = payloads.enumerated().map { index, bytes in
            ManifestEntry(identifier: AssetID("sync.\(index)"), fileExtension: "bin", remotePath: "media/\(index).bin", byteSize: 32, checksum: ContentHash.sha256(of: bytes))
        }
        let origin = time.monotonicNow()
        let report = try await store.open()
        let applying = Task {
            try await store.apply(try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("sync".utf8))), etag: nil, eviction: nil)
        }
        await time.waitForSleepers(atLeast: 1)
        time.advance(by: 0.25)
        _ = try await applying.value
        var commits: [Double] = []
        let sink = try await store.makeStagingSink()
        for (index, (entry, bytes)) in zip(entries, payloads).enumerated() {
            time.advance(by: interval)
            let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: report.launchEpoch, sequence: UInt32(index + 1)), kind: .partial)
            try sink.createPartial(name)
            _ = try sink.appendPartial(bytes, to: name)
            _ = try await store.publish(
                StagedFile(name: name, byteCount: 32, resumed: false, httpStatus: 200, etag: nil),
                binding: [entry.identifier],
                expecting: entry.contentIdentity,
                urgency: .bulk
            )
            if let deadline = await store.nextDeadline(), deadline <= time.monotonicNow() {
                if await store.runDueWork().committed {
                    commits.append(time.monotonicNow().seconds(since: origin))
                }
            }
        }
        await store.close()
        return commits
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    /// The `fraction` percentile (nearest rank) of `values`.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// Records the execution time of every unit run on the wrapped executor (P-13: batches between suspension points).
@available(macOS 15.0, *)
final class TimingExecutor: BlockingExecutor {
    private let base: any BlockingExecutor
    private let recorded = Mutex<[Double]>([])

    init(_ base: any BlockingExecutor) {
        self.base = base
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await self.base.run {
            let started = ContinuousClock.now
            let value = work()
            let elapsed = StorageBench.milliseconds(ContinuousClock.now - started)
            self.recorded.withLock { $0.append(elapsed) }
            return value
        }
    }

    /// Unit durations in milliseconds since the last reset.
    var durations: [Double] {
        self.recorded.withLock { $0 }
    }

    func reset() {
        self.recorded.withLock { $0 = [] }
    }
}

/// The live file system, sampling the resident size inside every read while the bytes read are still alive (P-6:
/// the peak while hashing, transient chunk buffers included).
@available(macOS 15.0, *)
struct ReadSamplingFileSystem: FileSystem {
    let base = LiveFileSystem()
    let sampler: MemoryProbe.PeakSampler

    func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        let data = try self.base.read(from: url, offset: offset, maxLength: maxLength)
        self.sampler.sample()
        return data
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

/// Measures how long the store's actor is held at a stretch while a call runs (C2): a probe task calls a cheap
/// synchronous API of the store in a loop and records the longest wait. Units run on their executors, off the actor,
/// so the probe is served while one runs; it waits only while the actor executes a synchronous stretch.
@available(macOS 15.0, *)
enum ActorHoldProbe {
    /// Runs `call` and returns the longest probe wait, in milliseconds.
    static func longestHold(of store: AssetStore, _ call: () async throws -> Void) async throws -> Double {
        let done = Mutex(false)
        let probe = Task {
            var longest: Duration = .zero
            while !done.withLock({ $0 }) {
                let started = ContinuousClock.now
                _ = await store.metrics()
                longest = max(longest, ContinuousClock.now - started)
            }
            return longest
        }
        do {
            try await call()
        } catch {
            done.withLock { $0 = true }
            _ = await probe.value
            throw error
        }
        done.withLock { $0 = true }
        return StorageBench.milliseconds(await probe.value)
    }
}
