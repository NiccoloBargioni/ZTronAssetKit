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
    /// ever slows a run down. Memory (P-6) is the peak resident delta sampled after every hash unit.
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
                let started = ContinuousClock.now
                let outcome = await StorageBench.load(layout.indexURL(.current), fileSystem: fileSystem, metadata: metadata, bulk: bulk)
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

            let sampler = MemoryProbe.PeakSampler()
            let store = StorageBench.liveStore(directory: directory, bulk: SamplingExecutor(DispatchBlockingExecutor(label: "bench.p6.bulk"), sampler: sampler))
            _ = try await store.open()
            _ = try await store.hashFile(at: file)
            var rates: [Double] = []
            var digest: ContentHash?
            var peak: UInt64 = 0
            for _ in 0..<5 {
                sampler.start()
                let started = ContinuousClock.now
                let result = try await store.hashFile(at: file)
                let seconds = StorageBench.milliseconds(ContinuousClock.now - started) / 1_000
                peak = max(peak, sampler.peakDelta)
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
            let peakMiB = MemoryProbe.mebibytes(peak)
            print("P-6 streaming SHA-256 of 256 MiB: \(streaming) MB/s, one-shot \(reference) MB/s, ratio \(streaming / reference), peak resident delta \(peakMiB) MiB; floors \(floor) MB/s, \(ratioFloor)x, cap \(memoryCap) MiB")
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
        time: any TimeSource = ManualTimeSource()
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
            fileSystem: LiveFileSystem(),
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

    /// The store's load path for one file: a stat unit, ≤ 1 MiB read units, then decoding on the bulk executor.
    static func load(_ url: URL, fileSystem: LiveFileSystem, metadata: any BlockingExecutor, bulk: any BlockingExecutor) async -> IndexLoadOutcome {
        let size = await metadata.run { (try? fileSystem.itemInfo(at: url))??.byteSize ?? 0 }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(size))
        while Int64(bytes.count) < size {
            let offset = Int64(bytes.count)
            guard let chunk = await metadata.run({ try? fileSystem.read(from: url, offset: offset, maxLength: 1 << 20) }), !chunk.isEmpty else {
                break
            }
            bytes.append(contentsOf: chunk)
        }
        let read = IndexFileRead(size: size, bytes: bytes)
        return await bulk.run {
            IndexLoadRule.choose([.current: read])
        }
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

/// Samples the resident size after every unit (P-6: the peak while hashing).
@available(macOS 15.0, *)
final class SamplingExecutor: BlockingExecutor {
    private let base: any BlockingExecutor
    private let sampler: MemoryProbe.PeakSampler

    init(_ base: any BlockingExecutor, sampler: MemoryProbe.PeakSampler) {
        self.base = base
        self.sampler = sampler
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await self.base.run {
            let value = work()
            self.sampler.sample()
            return value
        }
    }
}
