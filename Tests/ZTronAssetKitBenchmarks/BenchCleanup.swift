import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

extension ZTronAssetKitBenchmarks {
    /// C2 for WP-C's operations (CLAUDE.md C2; orchestrator ruling R4 at the L3 close-out), release configuration.
    ///
    /// WP-B's probe pattern (`ActorHoldProbe`: the longest wait of a task that calls a cheap synchronous API of the store
    /// in a loop, best of five runs) around every WP-C operation at the scale of WP-B's own C2 test (10,000 assets), on
    /// the fake file system with dispatch executors, so every unit runs off the actor and the probe waits only while the
    /// actor runs a synchronous stretch. No quality-gates key exists for C2, so the rule's own 10 ms is the budget.
    /// ARCHITECTURE §1.2 lists no benchmark file for WP-C; this one is new and nested in the parent suite, as its doc asks
    /// of every work package (ADR draft C-22, for the orchestrator).
    @Suite("CleanupBenchmarks")
    struct CleanupBenchmarks {
        /// The rule's figure (CLAUDE.md C2).
        static let budget = 10.0

        @Test(
            "C2: WP-C's report, verification, orphan GC, quarantine, eviction and purges never hold the store's actor for more than 10 ms at 10,000 assets",
            .timeLimit(.minutes(5))
        )
        @available(macOS 15.0, iOS 18.0, *)
        func actorStretches() async throws {
            var holds: [String: [Double]] = [:]
            for run in 0..<5 {
                for (name, hold) in try await CleanupBench.operationHolds(count: 10_000, seed: UInt64(70_000 + run * 10_000)) {
                    holds[name, default: []].append(hold)
                }
            }
            // Interference only lengthens a hold: each figure is the best of its five runs (ADR draft B-9).
            let figures = CleanupBench.operations.map { ($0, holds[$0] ?? []) }
            print("C2 longest actor hold at 10,000 assets (WP-C): " + figures.map { "\($0.0) \($0.1.min() ?? 0) ms (max of runs \($0.1.max() ?? 0) ms)" }.joined(separator: ", ") + "; budget \(CleanupBenchmarks.budget) ms")
            for (name, runs) in figures {
                #expect(runs.count == 5, "\(name) ran in every run")
                #expect((runs.min() ?? .infinity) <= CleanupBenchmarks.budget, "\(name): \(runs)")
            }
        }
    }
}

/// Helpers of WP-C's C2 benchmarks.
@available(macOS 15.0, iOS 18.0, *)
enum CleanupBench {
    /// The measured operations: the first five in this order on one store, each purge on a store of its own.
    static let operations = [
        "storage report", "deep verification of every blob", "orphan GC of 100 orphans", "quarantine of one blob",
        "quota eviction of half", "purge(.evictable) of all", "purge(.all) of all",
    ]

    /// A store over a fresh fake volume holding `count` present 64-byte assets (adopted by hash at the launch, as in
    /// WP-B's C2 test), with dispatch executors; a byte budget of half the usage, no residency window, no grace.
    static func store(count: Int, seed: UInt64) async throws -> (store: AssetStore, fileSystem: FakeFileSystem, time: ManualTimeSource, entries: [ManifestEntry]) {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let base = URL(fileURLWithPath: "/bench/cleanup", isDirectory: true)
        try fileSystem.createDirectory(at: base.deletingLastPathComponent())
        try fileSystem.createDirectory(at: base)
        let payloads = (0..<count).map { GeneratedPayload.bytes(seed: seed + UInt64($0), offset: 0, length: 64) }
        let entries = payloads.enumerated().map { index, bytes in
            ManifestEntry(identifier: AssetID("c2c.asset.\(index)"), fileExtension: "png", remotePath: "media/\(index).png", byteSize: 64, checksum: ContentHash.sha256(of: bytes))
        }
        let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("c2c-\(seed)".utf8)))
        let first = CleanupBench.makeStore(base: base, fileSystem: fileSystem, time: time, count: count)
        _ = try await first.open()
        _ = try await first.apply(manifest, etag: nil, eviction: nil)
        await first.close()
        let layout = StoreLayout(base: base)
        for (entry, bytes) in zip(entries, payloads) {
            let key = BlobKey(hash: try #require(entry.checksum), ext: try #require(AssetFileExtension("png")))
            let fanOut = layout.fanOutDirectory(for: key.hash)
            if try fileSystem.itemInfo(at: fanOut) == nil {
                try fileSystem.createDirectory(at: fanOut)
            }
            try fileSystem.write(bytes, to: layout.blobURL(key), mode: .truncate)
        }
        let store = CleanupBench.makeStore(base: base, fileSystem: fileSystem, time: time, count: count)
        _ = try await store.open()
        return (store, fileSystem, time, entries)
    }

    /// The store of `store(count:seed:)`.
    static func makeStore(base: URL, fileSystem: FakeFileSystem, time: ManualTimeSource, count: Int) -> AssetStore {
        var policy = StoragePolicy()
        policy.budget = .bytes(Int64(count) * 64 / 2)
        policy.reserveFreeBytes = 0
        policy.minimumResidency = 0
        policy.deletionGrace = 0
        policy.orphanGrace = 60
        let configuration = StoreConfiguration(
            location: .custom(base),
            policy: policy,
            legacy: LegacyMigrationPolicy(enabled: false),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: DispatchBlockingExecutor(label: "bench.cleanup.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "bench.cleanup.bulk"),
            time: time,
            random: SeededRandom(seed: 17),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        return AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
    }

    /// Runs every operation once on a fresh store of `count` assets and returns the longest actor hold of each.
    static func operationHolds(count: Int, seed: UInt64) async throws -> [(String, Double)] {
        let (store, fileSystem, time, entries) = try await CleanupBench.store(count: count, seed: seed)
        let base = URL(fileURLWithPath: "/bench/cleanup", isDirectory: true)
        let layout = StoreLayout(base: base)
        // Orphans older than the grace: blobs nobody knows.
        for index in 0..<100 {
            let bytes = GeneratedPayload.bytes(seed: seed + 5_000_000 + UInt64(index), offset: 0, length: 48)
            let key = BlobKey(hash: ContentHash.sha256(of: bytes), ext: try #require(AssetFileExtension("png")))
            let fanOut = layout.fanOutDirectory(for: key.hash)
            if try fileSystem.itemInfo(at: fanOut) == nil {
                try fileSystem.createDirectory(at: fanOut)
            }
            try fileSystem.write(bytes, to: layout.blobURL(key), mode: .truncate)
        }
        time.advance(by: 120)
        let far = time.monotonicNow().adding(seconds: 3_600)
        var holds: [(String, Double)] = []
        holds.append((CleanupBench.operations[0], try await ActorHoldProbe.longestHold(of: store) {
            let report = await store.storageReport()
            #expect(report.bytesByState.present == Int64(count) * 64)
        }))
        holds.append((CleanupBench.operations[1], try await ActorHoldProbe.longestHold(of: store) {
            let report = try await store.verifyIntegrity(byteBudget: .max, until: far)
            #expect(report.bytesVerified == Int64(count) * 64 && report.corrupt.isEmpty)
        }))
        holds.append((CleanupBench.operations[2], try await ActorHoldProbe.longestHold(of: store) {
            let result = try await store.collectGarbage(until: far)
            #expect(result.filesRemoved == 100)
        }))
        holds.append((CleanupBench.operations[3], try await ActorHoldProbe.longestHold(of: store) {
            try await store.reportUnreadable(entries[0].identifier)
        }))
        holds.append((CleanupBench.operations[4], try await ActorHoldProbe.longestHold(of: store) {
            let result = try await store.evictIfNeeded()
            #expect(result.filesRemoved >= count / 2 - 1)
        }))
        await store.close()
        for (index, request) in [(5, PurgeRequest.evictable), (6, .all)] {
            let full = try await CleanupBench.store(count: count, seed: seed + UInt64(index) * 1_000_000).store
            holds.append((CleanupBench.operations[index], try await ActorHoldProbe.longestHold(of: full) {
                let result = try await full.purge(request)
                #expect(result.assetsRemoved == count)
            }))
            await full.close()
        }
        return holds
    }
}
