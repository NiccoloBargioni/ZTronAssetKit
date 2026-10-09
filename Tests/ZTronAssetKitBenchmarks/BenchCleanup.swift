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

        /// Ruling R4's second half: the thread CPU of each of WP-C's actor stretches, measured directly on the actor (as
        /// the round-3 review measured them), at 10,000 and at `ManifestLimits.maxEntries` assets. The stretches WP-C made
        /// O(1) per item and chunked are asserted against the 10 ms at both scales (best of five chunks); the ones that stay
        /// linear on the actor (the first copy of `records` while a snapshot is alive, and WP-B's own stretches inside the
        /// operations, seen by the probe at 100,000) are recorded (ADR draft C-22).
        @Test("C2: WP-C's actor stretches at 10,000 and at 100,000 assets (maxEntries), thread CPU per stretch", .timeLimit(.minutes(10)))
        @available(macOS 15.0, iOS 18.0, *)
        func stretchesAtMaxEntries() async throws {
            for count in [10_000, 100_000] {
                let figures = try await CleanupBench.stretches(count: count, seed: UInt64(900_000 + count))
                print("C2 thread CPU of WP-C's stretches at \(count) assets: " + figures.map { "\($0.name) \($0.best) ms (worst \($0.worst) ms)\($0.bounded ? "" : ", recorded")" }.joined(separator: ", "))
                for figure in figures where figure.bounded {
                    #expect(figure.best <= CleanupBenchmarks.budget, "\(count) assets, \(figure.name): \(figure.best) ms")
                }
                if count == 100_000 {
                    let holds = try await CleanupBench.operationHoldsAtScale(count: count, seed: UInt64(990_000))
                    print("C2 longest actor hold at \(count) assets (WP-C operations, one run, WP-B's stretches inside them included): " + holds.map { "\($0.0) \($0.1) ms" }.joined(separator: ", "))
                    #expect(holds.count == 6)
                }
            }
        }
    }
}

extension AssetStore {
    /// Runs `body` in one turn of the actor and returns its value and its thread CPU time in milliseconds (C2 figures).
    @available(macOS 15.0, iOS 18.0, *)
    func benchThreadCPU<T: Sendable>(_ body: @Sendable (isolated AssetStore) -> T) -> (value: T, milliseconds: Double) {
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let value = body(self)
        return (value, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1_000_000)
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

    /// One stretch's thread CPU over five samples.
    struct Stretch: Sendable {
        let name: String
        let best: Double
        let worst: Double
        /// Asserted against the C2 budget (WP-C made it O(1) per item, in chunks); otherwise recorded only.
        let bounded: Bool
    }

    /// The thread CPU of WP-C's actor stretches on a store of `count` assets: five samples each.
    static func stretches(count: Int, seed: UInt64) async throws -> [Stretch] {
        let (store, _, _, entries) = try await CleanupBench.store(count: count, seed: seed)
        var figures: [Stretch] = []
        func record(_ name: String, bounded: Bool, _ samples: [Double]) {
            figures.append(Stretch(name: name, best: samples.min() ?? .infinity, worst: samples.max() ?? .infinity, bounded: bounded))
        }
        let chunk = AssetStore.cleanupChunk
        // The first mutation of `records` (or of the blob table) while a unit still holds a snapshot of it copies it
        // (copy-on-write): it happens when the actor mutates before the executor released the unit's closure.
        var copies: [Double] = []
        var tableCopies: [Double] = []
        for _ in 0..<5 {
            copies.append(await store.benchThreadCPU { store in
                let snapshot = store.state.core.records
                return withExtendedLifetime(snapshot) {
                    store.state.core.records[entries[0].identifier]?.revision += 1
                    return snapshot.count
                }
            }.milliseconds)
            tableCopies.append(await store.benchThreadCPU { store in
                let snapshot = store.state.core.blobTable
                return withExtendedLifetime(snapshot) {
                    store.state.core.blobTable[BlobKey(hash: entries[0].checksum!, ext: AssetFileExtension("png")!)] = snapshot.first?.value
                    return snapshot.count
                }
            }.milliseconds)
        }
        record("first records copy under a live snapshot", bounded: false, copies)
        record("first blob-table copy under a live snapshot", bounded: false, tableCopies)
        // WP-B: an installed snapshot shares the present table, so the first record change after a publication copies it.
        var presentCopies: [Double] = []
        for _ in 0..<5 {
            presentCopies.append(await store.benchThreadCPU { store in
                let snapshot = store.state.core.presentTable
                return withExtendedLifetime(snapshot) {
                    store.state.core.presentTable[entries[0].identifier] = snapshot[entries[0].identifier]
                    return snapshot.count
                }
            }.milliseconds)
        }
        record("WP-B: first present-table copy after a publication", bounded: false, presentCopies)
        // WP-B's own linear stretches inside WP-C's operations: the reaper's deletable filter over the blob table (every
        // reap, purge's included) and `freeSpace()`'s sums (eviction and the report).
        var reapFilters: [Double] = []
        for _ in 0..<5 {
            reapFilters.append(await store.benchThreadCPU { store in
                store.state.core.blobTable.keys.filter { store.deletionBlocker($0) == .none }.count
            }.milliseconds)
        }
        record("WP-B: the reaper's deletable filter", bounded: false, reapFilters)
        var freeSpaces: [Double] = []
        for _ in 0..<5 {
            freeSpaces.append(try await ActorHoldProbe.longestHold(of: store) {
                _ = try await store.freeSpace()
            })
        }
        record("WP-B: freeSpace() (probe, wall clock)", bounded: false, freeSpaces)
        // Snapshot capture before a unit: O(1).
        var captures: [Double] = []
        for _ in 0..<5 {
            captures.append(await store.benchThreadCPU { store in
                (store.state.core.records.count, store.state.core.blobTable.count, store.state.core.publishing.count)
            }.milliseconds)
        }
        record("snapshot capture", bounded: true, captures)
        // Holders of one blob each, as eviction, quarantine and verification read them: 1,000 keys per sample.
        let keys = entries.map { (id: $0.identifier, key: BlobKey(hash: $0.checksum!, ext: AssetFileExtension("png")!)) }
        var holders: [Double] = []
        for sample in 0..<5 {
            let slice = Array(keys[(sample * chunk)..<min(count, (sample + 1) * chunk)])
            holders.append(await store.benchThreadCPU { store in
                slice.reduce(0) { $0 + store.holders(of: $1.key, known: [$1.id]).count }
            }.milliseconds)
        }
        record("holders of \(chunk) blobs", bounded: true, holders)
        // Quota eviction's chunk: `evict` of 1,000 candidates in one turn.
        let candidates = await store.benchThreadCPU { store in
            EvictionOrder.candidates(
                records: store.state.core.records,
                blobTable: store.state.core.blobTable,
                publishing: store.state.core.publishing,
                leases: store.state.cleanup.leases,
                rules: EvictionOrder.Rules(policy: store.configuration.policy, scope: .all, protecting: [], now: store.environment.time.now())
            )
        }
        record("eviction candidates (off the actor since round 2)", bounded: false, [candidates.milliseconds])
        var evictions: [Double] = []
        for sample in 0..<5 {
            let slice = Array(candidates.value[(sample * chunk)..<min(candidates.value.count, (sample + 1) * chunk)])
            evictions.append(await store.benchThreadCPU { store in
                slice.reduce(0) { $0 + (store.evict($1.victims) == nil ? 0 : 1) }
            }.milliseconds)
        }
        record("eviction chunk of \(chunk)", bounded: true, evictions)
        // Purge: the selection (off the actor), then one chunk of 1,000 records per turn.
        let selection = await store.benchThreadCPU { store in
            PurgeSelection.select(.all, records: store.state.core.records, blobTable: store.state.core.blobTable, publishing: store.state.core.publishing, leases: store.state.cleanup.leases)
        }
        record("purge selection (off the actor)", bounded: false, [selection.milliseconds])
        var purges: [Double] = []
        for sample in 0..<5 {
            let slice = selection.value[(sample * chunk)..<min(selection.value.count, (sample + 1) * chunk)]
            purges.append(await store.benchThreadCPU { store in
                var reclaim: [BlobKey: Int64] = [:]
                return store.purgeChunk(slice, request: .all, reclaim: &reclaim)
            }.milliseconds)
        }
        record("purge chunk of \(chunk)", bounded: true, purges)
        // Deep verification's due list (off the actor).
        let due = await store.benchThreadCPU { store in
            DeepVerification.due(records: store.state.core.records, blobTable: store.state.core.blobTable, publishing: store.state.core.publishing, done: [])
        }
        record("verification due list (off the actor)", bounded: false, [due.milliseconds])
        await store.close()
        return figures
    }

    /// The longest actor hold of each WP-C operation once on a store of `count` assets (WP-B's stretches inside them
    /// included): a report, one verification slice of 1,000 blobs, orphan GC of 100 orphans, a quarantine, eviction of
    /// half, then purge(.all) of the rest.
    static func operationHoldsAtScale(count: Int, seed: UInt64) async throws -> [(String, Double)] {
        let (store, fileSystem, time, entries) = try await CleanupBench.store(count: count, seed: seed)
        let layout = StoreLayout(base: URL(fileURLWithPath: "/bench/cleanup", isDirectory: true))
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
        holds.append(("storage report", try await ActorHoldProbe.longestHold(of: store) {
            _ = await store.storageReport()
        }))
        holds.append(("verification slice of 1,000 blobs", try await ActorHoldProbe.longestHold(of: store) {
            let report = try await store.verifyIntegrity(byteBudget: 1_000 * 64, until: far)
            #expect(report.bytesVerified == 1_000 * 64)
        }))
        holds.append(("orphan GC of 100 orphans", try await ActorHoldProbe.longestHold(of: store) {
            let result = try await store.collectGarbage(until: far)
            #expect(result.filesRemoved == 100)
        }))
        holds.append(("quarantine of one blob", try await ActorHoldProbe.longestHold(of: store) {
            try await store.reportUnreadable(entries[0].identifier)
        }))
        holds.append(("quota eviction of half", try await ActorHoldProbe.longestHold(of: store) {
            _ = try await store.evictIfNeeded()
        }))
        holds.append(("purge(.all) of the rest", try await ActorHoldProbe.longestHold(of: store) {
            _ = try await store.purge(.all)
        }))
        await store.close()
        return holds
    }
}
