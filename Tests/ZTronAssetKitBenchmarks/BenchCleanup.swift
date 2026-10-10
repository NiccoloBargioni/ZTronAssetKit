import Foundation
import Synchronization
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
        /// O(1) per item and chunked are asserted against the 10 ms at both scales (best of five chunks; `apply`'s eviction
        /// hook, every chunk of one plan, also its worst chunk at 10,000), the synchronous eviction dry run at 10,000 only;
        /// the ones that stay linear on the actor (the first copy of `records` while a
        /// snapshot is alive, the dry run at `maxEntries`, and WP-B's own stretches inside the operations, seen by the probe
        /// at 100,000) are recorded (ADR draft C-22).
        @Test("C2: WP-C's actor stretches at 10,000 and at 100,000 assets (maxEntries), thread CPU per stretch", .timeLimit(.minutes(10)))
        @available(macOS 15.0, iOS 18.0, *)
        func stretchesAtMaxEntries() async throws {
            for count in [10_000, 100_000] {
                let figures = try await CleanupBench.stretches(count: count, seed: UInt64(900_000 + count))
                    + CleanupBench.purgeStretches(count: count, seed: UInt64(950_000 + count))
                    + CleanupBench.applyEvictionStretch(count: count, seed: UInt64(970_000 + count))
                print("C2 thread CPU of WP-C's stretches at \(count) assets: " + figures.map { "\($0.name) \($0.best) ms (worst \($0.worst) ms)\($0.bounded ? "" : ", recorded")" }.joined(separator: ", "))
                for figure in figures where figure.bounded {
                    #expect(figure.best <= CleanupBenchmarks.budget, "\(count) assets, \(figure.name): \(figure.best) ms")
                    if figure.worstBounded {
                        #expect(figure.worst <= CleanupBenchmarks.budget, "\(count) assets, \(figure.name), worst: \(figure.worst) ms")
                    }
                }
                if count == 100_000 {
                    let holds = try await CleanupBench.operationHoldsAtScale(count: count, seed: UInt64(990_000))
                    print("C2 longest actor hold at \(count) assets (WP-C operations, one run, WP-B's stretches inside them included): " + holds.map { "\($0.0) \($0.1) ms" }.joined(separator: ", "))
                    #expect(holds.count == 9)
                }
            }
        }

        /// Legacy migration's actor holds (review of the L3 close-out cycle 2): `open()` with phase 1, the longest batch
        /// of phase 2 and the last call (its batch, phases 3 and 4) over a legacy tree of 10,000 and of `maxEntries`
        /// files; and, on a second store, the last calls while a task merges access stamps (`recordAccesses`, a counted
        /// mutation in every call) during phase 3's check (review of close-out cycle 3: its one-turn fallback then held
        /// the actor 35–40 ms at `maxEntries`). At 10,000 each is asserted against the 10 ms (best of three runs); at
        /// 100,000 they are recorded, with WP-B's stretches inside them (the launch commit and snapshot, the adoptions'
        /// bindings) included.
        @Test("C2: legacy migration's actor holds at 10,000 and at 100,000 legacy files", .timeLimit(.minutes(10)))
        @available(macOS 15.0, iOS 18.0, *)
        func legacyMigrationHolds() async throws {
            for (count, runs) in [(10_000, 3), (100_000, 1)] {
                var holds: [String: [Double]] = [:]
                for run in 0..<runs {
                    for stamping in [false, true] {
                        let seed = UInt64(1_200_000 + run * 200_000)
                        for (name, hold) in try await CleanupBench.legacyHolds(count: count, seed: seed, stamping: stamping) {
                            holds[name, default: []].append(hold)
                        }
                    }
                }
                let figures = CleanupBench.legacyOperations.map { ($0, holds[$0] ?? []) }
                print("C2 longest actor hold of legacy migration over \(count) files (best of \(runs)): " + figures.map { "\($0.0) \($0.1.min() ?? 0) ms (max of runs \($0.1.max() ?? 0) ms)" }.joined(separator: ", "))
                for (name, samples) in figures {
                    #expect(samples.count == runs, "\(name) ran in every run")
                    if count == 10_000 {
                        #expect((samples.min() ?? .infinity) <= CleanupBenchmarks.budget, "\(name): \(samples)")
                    }
                }
            }
        }

        /// Review of the L3 close-out cycle 5: eviction's chunks counted blobs, so where several ids share each blob a
        /// chunk of 1,000 changed up to ten times as many records in one turn (16.2–16.4 ms of thread CPU at 10,000 records
        /// with ten ids per blob). Quota eviction of the whole store, with five and with ten ids per blob, holds the actor
        /// at most 10 ms (WP-B's probe, best of three runs); a blob that 10,000 ids share leaves in one turn whatever the
        /// chunk (its holders go together, C-1), recorded as thread CPU.
        @Test("C2: quota eviction holds the actor at most 10 ms at 10,000 records when five or ten ids share each blob", .timeLimit(.minutes(5)))
        @available(macOS 15.0, iOS 18.0, *)
        func sharedBlobHolds() async throws {
            var holds: [String: [Double]] = [:]
            for run in 0..<3 {
                for (name, hold) in try await CleanupBench.sharedBlobHolds(count: 10_000, seed: UInt64(3_000_000 + run * 100_000)) {
                    holds[name, default: []].append(hold)
                }
            }
            let figures = CleanupBench.sharedBlobOperations.map { ($0, holds[$0] ?? []) }
            print("C2 with shared blobs at 10,000 records (best of 3): " + figures.map { "\($0.0) \($0.1.min() ?? 0) ms (max of runs \($0.1.max() ?? 0) ms)" }.joined(separator: ", "))
            for (name, runs) in figures where CleanupBench.boundedSharedBlobOperations.contains(name) {
                #expect(runs.count == 3, "\(name) ran in every run")
                #expect((runs.min() ?? .infinity) <= CleanupBenchmarks.budget, "\(name): \(runs)")
            }
        }

        /// Review of the L3 close-out cycle 4: a selection that a later `apply` outdates (an alias bound to a candidate's
        /// blob, or every id renamed) made each re-validated blob scan every record, so one turn scanned once per blob:
        /// an eviction chunk of 1,000 held the actor about 1.7 s at 10,000 assets, and `apply`'s eviction of a plan of
        /// half about 4.3 s. Each operation's longest hold after the outdating `apply` (WP-B's probe, best of three runs),
        /// asserted against the 10 ms; and the thread CPU of `apply`'s eviction hook over a plan of half, with and
        /// without the rename and after an alias was bound to half the plan's blobs, each the run's longest chunk since
        /// `apply` passes its plan in chunks (ruling R6 at the L3 close-out cycle 7), asserted too (best of three runs).
        @Test(
            "C2: quota eviction, apply's eviction plan and an evictable purge hold the actor at most 10 ms at 10,000 assets when ids were bound to their blobs after the selection",
            .timeLimit(.minutes(10))
        )
        @available(macOS 15.0, iOS 18.0, *)
        func holdsAfterBinding() async throws {
            var holds: [String: [Double]] = [:]
            for run in 0..<3 {
                for (name, hold) in try await CleanupBench.bindingHolds(count: 10_000, seed: UInt64(2_000_000 + run * 100_000)) {
                    holds[name, default: []].append(hold)
                }
            }
            let figures = CleanupBench.bindingOperations.map { ($0, holds[$0] ?? []) }
            print("C2 after ids were bound to the selected blobs at 10,000 assets (best of 3): " + figures.map { "\($0.0) \($0.1.min() ?? 0) ms (max of runs \($0.1.max() ?? 0) ms)" }.joined(separator: ", "))
            for (name, runs) in figures where CleanupBench.boundedBindingOperations.contains(name) {
                #expect(runs.count == 3, "\(name) ran in every run")
                #expect((runs.min() ?? .infinity) <= CleanupBenchmarks.budget, "\(name): \(runs)")
            }
        }

        /// Orchestrator ruling R6 at the L3 close-out cycle 7 (CCR-3): `apply` ran its eviction hook over the whole plan in
        /// one turn inside its write fence, about 1.4 µs per victim, so a plan of the whole store held the actor 14–16 ms at
        /// 10,000 records, 20 ms with two ids per blob, and a plan of half with two ids per blob 10.2–10.4 ms (the review
        /// of cycle 6). The longest hold of an `apply` carrying each plan shape the reviews measured, and of one that binds
        /// an alias to half the planned blobs as it evicts, is asserted against the 10 ms (WP-B's probe, best of three).
        @Test(
            "C2: apply holds the actor at most 10 ms at 10,000 records with an eviction plan of the whole store, of one or two ids per blob, and while it binds aliases",
            .timeLimit(.minutes(5))
        )
        @available(macOS 15.0, iOS 18.0, *)
        func applyEvictionHolds() async throws {
            var holds: [String: [Double]] = [:]
            for run in 0..<3 {
                for (name, hold) in try await CleanupBench.applyEvictionHolds(count: 10_000, seed: UInt64(4_000_000 + run * 100_000)) {
                    holds[name, default: []].append(hold)
                }
            }
            let figures = CleanupBench.applyEvictionOperations.map { ($0, holds[$0] ?? []) }
            print("C2 of apply with an eviction plan at 10,000 records (best of 3): " + figures.map { "\($0.0) \($0.1.min() ?? 0) ms (max of runs \($0.1.max() ?? 0) ms)" }.joined(separator: ", "))
            for (name, runs) in figures {
                #expect(runs.count == 3, "\(name) ran in every run")
                #expect((runs.min() ?? .infinity) <= CleanupBenchmarks.budget, "\(name): \(runs)")
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
        "storage report", "deep verification of every blob", "orphan GC of 100 orphans", "orphan GC of 10,000 orphans",
        "quarantine of one blob", "quota eviction of half", "purge(.evictable) of all", "purge(.all) of all",
    ]

    /// Writes `count` blobs nobody knows (48 bytes each, from `seed`) into `blobs/` under `base`.
    static func plantOrphans(_ count: Int, seed: UInt64, fileSystem: FakeFileSystem, base: URL) throws {
        let layout = StoreLayout(base: base)
        for index in 0..<count {
            let bytes = GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: 48)
            let key = BlobKey(hash: ContentHash.sha256(of: bytes), ext: try #require(AssetFileExtension("png")))
            let fanOut = layout.fanOutDirectory(for: key.hash)
            if try fileSystem.itemInfo(at: fanOut) == nil {
                try fileSystem.createDirectory(at: fanOut)
            }
            try fileSystem.write(bytes, to: layout.blobURL(key), mode: .truncate)
        }
    }

    /// A store over a fresh fake volume holding `count` present 64-byte assets (adopted by hash at the launch, as in
    /// WP-B's C2 test), with dispatch executors; a byte budget of half the usage, no residency window, no grace.
    static func store(
        count: Int,
        seed: UInt64,
        bulk: (any BlockingExecutor)? = nil,
        idsPerBlob: Int = 1,
        budget: StorageBudget? = nil
    ) async throws -> (store: AssetStore, fileSystem: FakeFileSystem, time: ManualTimeSource, entries: [ManifestEntry]) {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let base = URL(fileURLWithPath: "/bench/cleanup", isDirectory: true)
        try fileSystem.createDirectory(at: base.deletingLastPathComponent())
        try fileSystem.createDirectory(at: base)
        let payloads = (0..<count).map { GeneratedPayload.bytes(seed: seed + UInt64($0 / max(1, idsPerBlob)), offset: 0, length: 64) }
        let entries = payloads.enumerated().map { index, bytes in
            ManifestEntry(identifier: AssetID("c2c.asset.\(index)"), fileExtension: "png", remotePath: "media/\(index).png", byteSize: 64, checksum: ContentHash.sha256(of: bytes))
        }
        let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("c2c-\(seed)".utf8)))
        let first = CleanupBench.makeStore(base: base, fileSystem: fileSystem, time: time, count: count, budget: budget)
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
        let store = CleanupBench.makeStore(base: base, fileSystem: fileSystem, time: time, count: count, bulk: bulk, budget: budget)
        _ = try await store.open()
        return (store, fileSystem, time, entries)
    }

    /// The store of `store(count:seed:bulk:idsPerBlob:budget:)`; `bulk` replaces its dispatch bulk executor, `budget` the
    /// budget of half the usage of `count` distinct assets.
    static func makeStore(
        base: URL,
        fileSystem: FakeFileSystem,
        time: ManualTimeSource,
        count: Int,
        bulk: (any BlockingExecutor)? = nil,
        budget: StorageBudget? = nil
    ) -> AssetStore {
        var policy = StoragePolicy()
        policy.budget = budget ?? .bytes(Int64(count) * 64 / 2)
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
            bulkExecutor: bulk ?? DispatchBlockingExecutor(label: "bench.cleanup.bulk"),
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
        // Orphans older than the grace: blobs nobody knows.
        try CleanupBench.plantOrphans(100, seed: seed + 5_000_000, fileSystem: fileSystem, base: base)
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
        // As many orphans as assets (the review's probe of the sweep's doom turn, L3 close-out).
        try CleanupBench.plantOrphans(count, seed: seed + 6_000_000, fileSystem: fileSystem, base: base)
        time.advance(by: 120)
        let later = time.monotonicNow().adding(seconds: 3_600)
        holds.append((CleanupBench.operations[3], try await ActorHoldProbe.longestHold(of: store) {
            let result = try await store.collectGarbage(until: later)
            #expect(result.filesRemoved == count)
        }))
        holds.append((CleanupBench.operations[4], try await ActorHoldProbe.longestHold(of: store) {
            try await store.reportUnreadable(entries[0].identifier)
        }))
        holds.append((CleanupBench.operations[5], try await ActorHoldProbe.longestHold(of: store) {
            let result = try await store.evictIfNeeded()
            #expect(result.filesRemoved >= count / 2 - 1)
        }))
        await store.close()
        for (index, request) in [(6, PurgeRequest.evictable), (7, .all)] {
            let full = try await CleanupBench.store(count: count, seed: seed + UInt64(index) * 1_000_000).store
            holds.append((CleanupBench.operations[index], try await ActorHoldProbe.longestHold(of: full) {
                let result = try await full.purge(request)
                #expect(result.assetsRemoved == count)
            }))
            await full.close()
        }
        return holds
    }

    /// One stretch's thread CPU over five samples (or over every chunk of one operation).
    struct Stretch: Sendable {
        let name: String
        let best: Double
        let worst: Double
        /// Asserted against the C2 budget (WP-C made it O(1) per item, in chunks); otherwise recorded only.
        let bounded: Bool
        /// The worst sample is asserted too: every chunk of one operation is a turn that operation holds the actor for.
        var worstBounded = false
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
                var scan = HolderScan(blobs: slice.map(\.key))
                return slice.reduce(0) { $0 + store.holders(of: $1.key, known: [$1.id], scan: &scan).count }
            }.milliseconds)
        }
        record("holders of \(chunk) blobs", bounded: true, holders)
        // The same when none of the known ids accounts for its blob (ids bound after the selection): the chunk's one scan.
        var scanned: [Double] = []
        for sample in 0..<5 {
            let slice = Array(keys[(sample * chunk)..<min(count, (sample + 1) * chunk)])
            let found = await store.benchThreadCPU { store in
                var scan = HolderScan(blobs: slice.map(\.key))
                return slice.reduce(0) { $0 + store.holders(of: $1.key, known: [], scan: &scan).count }
            }
            #expect(found.value == slice.count, "the scan found every blob's holder")
            scanned.append(found.milliseconds)
        }
        record("holders of \(chunk) blobs by one scan of the records", bounded: false, scanned)
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
        // The engine's synchronous dry run, one actor turn by contract (OI-4; review of the L3 close-out cycle 5: 14.2 to
        // 15.3 ms at 10,000 assets): a plan of the whole store, and of everything but every other id, which it protects.
        // Asserted at 10,000 assets (ruling R4), recorded at `maxEntries`.
        let everyOther = Set(entries.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.identifier))
        for (name, protecting, toFree) in [
            ("eviction dry run of the whole store", Set<AssetID>(), Int64(count) * 64),
            ("eviction dry run protecting every other id", everyOther, Int64(count - everyOther.count) * 64),
        ] {
            var dryRuns: [Double] = []
            for _ in 0..<5 {
                let plan = await store.benchThreadCPU { store in
                    store.evictionPlan(toFree: toFree, protecting: protecting)
                }
                #expect(plan.value?.bytes == toFree && plan.value?.victims.allSatisfy { !protecting.contains($0.id) } == true, "\(name)")
                dryRuns.append(plan.milliseconds)
            }
            record(name, bounded: count <= 10_000, dryRuns)
        }
        var evictions: [Double] = []
        for sample in 0..<5 {
            let slice = Array(candidates.value[(sample * chunk)..<min(candidates.value.count, (sample + 1) * chunk)])
            evictions.append(await store.benchThreadCPU { store in
                var scan = HolderScan(blobs: slice.map(\.key))
                let rules = store.evictionRules()
                return slice.reduce(0) { $0 + (store.evict($1.victims[...], rules: rules, scan: &scan) == nil ? 0 : 1) }
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
                var reclaim: [PurgeSelection.Reclaim] = []
                return store.purgeChunk(slice, request: .all, reclaim: &reclaim)
            }.milliseconds)
        }
        record("purge chunk of \(chunk)", bounded: true, purges)
        // Orphan GC's doom chunk (review of the L3 close-out: one turn over 10,000 swept keys held the actor 9.7 ms).
        var dooms: [Double] = []
        for sample in 0..<5 {
            let orphans = Dictionary(uniqueKeysWithValues: (0..<chunk).map { index in
                let bytes = Data("c2c-orphan-\(count)-\(sample)-\(index)".utf8)
                return (BlobKey(hash: ContentHash.sha256(of: bytes), ext: AssetFileExtension("png")!), Int64(48))
            })
            dooms.append(await store.benchThreadCPU { store in
                store.doomOrphans(orphans).count
            }.milliseconds)
            // Out of the table again, so the later figures see the store as it was.
            _ = await store.benchThreadCPU { store in
                for key in orphans.keys {
                    store.state.core.blobTable[key] = nil
                    store.state.core.blobBytes[key] = nil
                }
            }
        }
        record("orphan GC doom chunk of \(chunk)", bounded: true, dooms)
        // Deep verification's due list (off the actor).
        let due = await store.benchThreadCPU { store in
            DeepVerification.due(records: store.state.core.records, blobTable: store.state.core.blobTable, publishing: store.state.core.publishing, done: [])
        }
        record("verification due list (off the actor)", bounded: false, [due.milliseconds])
        await store.close()
        return figures
    }

    /// On a fresh store of `count` assets: the holders of a blob read by a full scan (recorded), five `.evictable` purge
    /// chunks (bounded), then the stretches a full-store purge runs besides its chunks (review of the L3 close-out: its
    /// longest hold at 100,000 is ~10 ms above eviction's): every other record purged in one bench turn (not measured),
    /// the install and acknowledgement that start the grace, the reaper's queue (WP-B's, recorded) and one chunk of the
    /// purge's own reclaim pass (bounded).
    static func purgeStretches(count: Int, seed: UInt64) async throws -> [Stretch] {
        let (store, _, _, entries) = try await CleanupBench.store(count: count, seed: seed)
        var figures: [Stretch] = []
        func record(_ name: String, bounded: Bool, _ samples: [Double]) {
            figures.append(Stretch(name: name, best: samples.min() ?? .infinity, worst: samples.max() ?? .infinity, bounded: bounded))
        }
        let chunk = AssetStore.cleanupChunk
        // The holders of a blob when the known ids do not account for its references (a `reportUnreadable` of a blob
        // several records share, or an eviction candidate bound after the snapshot): one scan of the records.
        let live = BlobKey(hash: entries[0].checksum!, ext: AssetFileExtension("png")!)
        var scans: [Double] = []
        for _ in 0..<5 {
            let scan = await store.benchThreadCPU { store in
                var scan = HolderScan(blobs: [live])
                return store.holders(of: live, known: [], scan: &scan).count
            }
            #expect(scan.value == 1, "the scan found the blob's holder")
            scans.append(scan.milliseconds)
        }
        record("holders(of:known:) fallback scan", bounded: false, scans)
        // Purge(.evictable)'s chunk: every holder of each blob re-read (`holders(of:known:scan:)`) and re-validated.
        let evictable = await store.benchThreadCPU { store in
            PurgeSelection.select(.evictable, records: store.state.core.records, blobTable: store.state.core.blobTable, publishing: store.state.core.publishing, leases: store.state.cleanup.leases)
        }.value
        var evictablePurges: [Double] = []
        for sample in 0..<5 {
            let slice = evictable[(sample * chunk)..<min(evictable.count, (sample + 1) * chunk)]
            let purged = await store.benchThreadCPU { store in
                var reclaim: [PurgeSelection.Reclaim] = []
                return store.purgeChunk(slice, request: .evictable, reclaim: &reclaim)
            }
            #expect(purged.value == slice.count)
            evictablePurges.append(purged.milliseconds)
        }
        record("purge(.evictable) chunk of \(chunk)", bounded: true, evictablePurges)
        // The rest of a full-store purge (review of the L3 close-out: its longest hold at 100,000 was ~10 ms above
        // eviction's): every other record purged in one bench turn (not measured), then the stretches its awaits run.
        let all = await store.benchThreadCPU { store in
            PurgeSelection.select(.all, records: store.state.core.records, blobTable: store.state.core.blobTable, publishing: [], leases: [:])
        }.value
        let reclaim = await store.benchThreadCPU { store in
            var reclaim: [PurgeSelection.Reclaim] = []
            _ = store.purgeChunk(all[...], request: .all, reclaim: &reclaim)
            return reclaim
        }.value
        // WP-B: the acknowledgement of the install after the purge starts the grace of every doomed key in one turn.
        let graceStart = try await ActorHoldProbe.longestHold(of: store) {
            await store.publishSnapshot(urgency: .userInitiated)
        }
        record("WP-B: grace start over every doomed key (probe, wall clock)", bounded: false, [graceStart])
        try await store.requireCommitted(.ordered)
        await store.publishSnapshot(urgency: .userInitiated)
        var queues: [Double] = []
        var passes: [Double] = []
        var deletable = 0
        for sample in 0..<5 {
            // WP-B's `reap`: the queue of deletable keys, filtered and sorted in one turn.
            let queue = await store.benchThreadCPU { store in
                store.state.core.blobTable.keys.filter { store.deletionBlocker($0) == .none }.sorted().count
            }
            queues.append(queue.milliseconds)
            deletable = queue.value
            // `awaitReclaim`'s pass over one chunk of the selection.
            let slice = reclaim[(sample * chunk)..<min(reclaim.count, (sample + 1) * chunk)]
            passes.append(await store.benchThreadCPU { store in
                var pass = PurgeSelection.ReclaimPass()
                store.reclaimPass(slice, into: &pass)
                return pass.pending.count
            }.milliseconds)
        }
        #expect(deletable == count, "every purged blob is deletable")
        record("WP-B: the reaper's queue over every deletable key (filter and sort)", bounded: false, queues)
        record("purge's reclaim pass, chunk of \(chunk)", bounded: true, passes)
        await store.close()
        return figures
    }

    /// The thread CPU of each turn `apply` gives its eviction hook for `plan` (`ApplyEvictionChunks`, chunks of
    /// `AssetStore.evictionChunk` records at blob boundaries; ruling R6 at the L3 close-out cycle 7, CCR-3), in
    /// milliseconds, and how many ids the hook evicted.
    static func hookChunks(of plan: EvictionPlan, on store: AssetStore) async -> (evicted: Int, milliseconds: [Double]) {
        var evicted = 0
        var milliseconds: [Double] = []
        for chunk in ApplyEvictionChunks(cutting: plan, records: AssetStore.evictionChunk).chunks {
            let turn = await store.benchThreadCPU { store in
                store.applyEviction(chunk).count
            }
            evicted += turn.value
            milliseconds.append(turn.milliseconds)
        }
        return (evicted, milliseconds)
    }

    /// `apply`'s eviction hook over a plan of half the store and over a plan of the whole store, one chunk per turn as
    /// `apply` passes it (review of the L3 close-out cycles 4 to 6; ruling R6 at cycle 7): every chunk's turn, the best
    /// asserted at both scales and the worst at 10,000 (at `maxEntries` the first chunk can pay WP-B's copy of the present
    /// table after a publication, C-22 (b)); with WP-B's `setResidency` of each chunk's victims alone on a store of its
    /// own, the part of a chunk's turn that is not WP-C's.
    static func applyEvictionStretch(count: Int, seed: UInt64) async throws -> [Stretch] {
        var figures: [Stretch] = []
        for (index, share) in [(0, 2), (1, 1)] {
            let (store, _, _, _) = try await CleanupBench.store(count: count, seed: seed + UInt64(index) * 10_000)
            let plan = try #require(await store.evictionPlan(toFree: Int64(count) * 64 / Int64(share), protecting: []))
            let turns = await CleanupBench.hookChunks(of: plan, on: store)
            #expect(turns.evicted == plan.victims.count && turns.evicted == count / share)
            await store.close()
            figures.append(
                Stretch(
                    name: "apply's eviction hook over a plan of \(turns.evicted) blobs, each of its \(turns.milliseconds.count) chunks of \(AssetStore.evictionChunk) records",
                    best: turns.milliseconds.min() ?? .infinity,
                    worst: turns.milliseconds.max() ?? .infinity,
                    bounded: true,
                    worstBounded: count == 10_000
                )
            )
        }
        let (other, _, _, _) = try await CleanupBench.store(count: count, seed: seed + 20_000)
        let plan = try #require(await other.evictionPlan(toFree: Int64(count) * 64, protecting: []))
        var alone: [Double] = []
        for chunk in ApplyEvictionChunks(cutting: plan, records: AssetStore.evictionChunk).chunks {
            alone.append(await other.benchThreadCPU { store in
                for victim in chunk.victims {
                    store.setResidency(.absent(.evicted), of: victim.id, dooming: .unreferenced)
                }
                return chunk.victims.count
            }.milliseconds)
        }
        await other.close()
        figures.append(
            Stretch(
                name: "WP-B: setResidency of each chunk's \(AssetStore.evictionChunk) victims alone (\(alone.count) chunks)",
                best: alone.min() ?? .infinity,
                worst: alone.max() ?? .infinity,
                bounded: false
            )
        )
        return figures
    }

    /// The figures of `applyEvictionHolds(count:seed:)`, in order (ruling R6 at the L3 close-out cycle 7).
    static let applyEvictionOperations = [
        "apply with an eviction plan of every blob, one id per blob",
        "apply with an eviction plan of every blob, two ids per blob",
        "apply with an eviction plan of half the blobs, two ids per blob",
        "apply binding an alias to half the planned blobs, with an eviction plan of every blob",
    ]

    /// On fresh stores of `count` records: the longest hold of an `apply` of the store's own entries (under a new digest)
    /// carrying the engine's dry run of every blob, with one and with two ids per blob, and of half the blobs with two
    /// ids per blob; and of an `apply` that also lists an alias of half the planned blobs, so it binds them by hash
    /// before its eviction (those blobs stay, the hook scanning the records for their holders).
    static func applyEvictionHolds(count: Int, seed: UInt64) async throws -> [(String, Double)] {
        var holds: [(String, Double)] = []
        let shapes: [(idsPerBlob: Int, share: Int, aliases: Bool)] = [(1, 1, false), (2, 1, false), (2, 2, false), (1, 1, true)]
        for (index, shape) in shapes.enumerated() {
            let (store, _, _, entries) = try await CleanupBench.store(count: count, seed: seed + UInt64(index) * 10_000, idsPerBlob: shape.idsPerBlob)
            let blobs = count / shape.idsPerBlob
            let plan = try #require(await store.evictionPlan(toFree: Int64(blobs / shape.share) * 64, protecting: []))
            #expect(plan.victims.count == count / shape.share)
            let planned = Set(plan.victims.map(\.id))
            let aliased = shape.aliases ? Array(entries.filter { planned.contains($0.identifier) }.prefix(blobs / 2)) : []
            let manifest = try ValidatedManifest(
                entries: entries + CleanupBench.renamed(aliased, "alias"),
                digest: ContentHash.sha256(of: Data("c2c-apply-eviction-\(seed)-\(index)".utf8))
            )
            holds.append((CleanupBench.applyEvictionOperations[index], try await ActorHoldProbe.longestHold(of: store) {
                let report = try await store.apply(manifest, etag: nil, eviction: plan)
                #expect(report.evicted.count == plan.victims.count - aliased.count, "every planned id but the aliased blobs' is evicted")
            }))
            await store.close()
        }
        return holds
    }

    /// The figures of `sharedBlobHolds(count:seed:)`, in order.
    static let sharedBlobOperations = [
        "quota eviction of every blob with 5 ids per blob",
        "quota eviction of every blob with 10 ids per blob",
        "eviction of one blob 10,000 ids share (thread CPU)",
    ]

    /// The figures of `sharedBlobOperations` asserted against the C2 budget; the last is inherent and recorded.
    static let boundedSharedBlobOperations: Set<String> = [sharedBlobOperations[0], sharedBlobOperations[1]]

    /// On stores of `count` records where every 5, then every 10, consecutive ids share one 64-byte blob, with a budget
    /// of 0 bytes: the longest hold of quota eviction of every blob; then, on a store where all `count` ids share one
    /// blob, the thread CPU of that blob's eviction in one turn.
    static func sharedBlobHolds(count: Int, seed: UInt64) async throws -> [(String, Double)] {
        var holds: [(String, Double)] = []
        for (index, idsPerBlob) in [5, 10].enumerated() {
            let (store, _, _, _) = try await CleanupBench.store(count: count, seed: seed + UInt64(index) * 10_000, idsPerBlob: idsPerBlob, budget: .bytes(0))
            holds.append((CleanupBench.sharedBlobOperations[index], try await ActorHoldProbe.longestHold(of: store) {
                let result = try await store.evictIfNeeded()
                #expect(result.filesRemoved == count / idsPerBlob)
            }))
            await store.close()
        }
        let (one, _, _, _) = try await CleanupBench.store(count: count, seed: seed + 50_000, idsPerBlob: count, budget: .bytes(0))
        let candidates = await one.evictionCandidatesOffActor()
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1 && candidate.victims.count == count)
        let evicted = await one.benchThreadCPU { store in
            var scan = HolderScan(blobs: [candidate.key])
            return store.evict(candidate.victims[...], rules: store.evictionRules(), scan: &scan)
        }
        #expect(evicted.value == .doomed(bytes: 64))
        holds.append((CleanupBench.sharedBlobOperations[2], evicted.milliseconds))
        await one.close()
        return holds
    }

    /// Legacy migration's measured calls, in order.
    static let legacyOperations = [
        "open() with phase 1", "longest batch of 500", "last call with phases 3 and 4", "last calls while access stamps arrive",
    ]

    /// Migrates a legacy tree of `count` files (40 bytes each, 500 per directory, with the prior art's `manifest.json`)
    /// on a fresh fake volume with dispatch executors and returns the longest actor hold of each legacy operation; with
    /// `stamping`, only the last calls', made while a task merges an access stamp into one record after another (each a
    /// counted mutation, so phase 3's passes are interrupted), at most three of them, then one without it.
    static func legacyHolds(count: Int, seed: UInt64, stamping: Bool = false) async throws -> [(String, Double)] {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let volume = URL(fileURLWithPath: "/bench/legacy", isDirectory: true)
        let base = volume.appendingPathComponent("app", isDirectory: true)
        let root = volume.appendingPathComponent("CDNAssets", isDirectory: true)
        try fileSystem.createDirectory(at: volume.deletingLastPathComponent())
        for directory in [volume, base, root] {
            try fileSystem.createDirectory(at: directory)
        }
        struct LegacyEntry: Encodable {
            let identifier: String
            let fileExtension: String
            let remotePath: String
            let localPathComponents: [String]
            let localFileName: String?
            let byteSize: Int64?
            let checksum: String?
        }
        var legacyEntries: [LegacyEntry] = []
        for index in 0..<count {
            let bytes = GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: 40)
            let directory = "Dir\(index / 500)"
            let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
            if index % 500 == 0 {
                try fileSystem.createDirectory(at: directoryURL)
            }
            try fileSystem.write(bytes, to: directoryURL.appendingPathComponent("f\(index).png", isDirectory: false), mode: .truncate)
            legacyEntries.append(LegacyEntry(
                identifier: "legacy.bench.asset\(index)",
                fileExtension: "png",
                remotePath: "media/\(index).png",
                localPathComponents: [directory],
                localFileName: "f\(index)",
                byteSize: 40,
                checksum: ContentHash.sha256(of: bytes).hex
            ))
        }
        try fileSystem.write(try JSONEncoder().encode(legacyEntries), to: root.appendingPathComponent("manifest.json", isDirectory: false), mode: .truncate)
        let legacy = LegacyMigrationPolicy(enabled: true, root: root)
        var policy = StoragePolicy()
        policy.budget = .unlimited
        policy.deletionGrace = 0
        let configuration = StoreConfiguration(
            location: .custom(base),
            policy: policy,
            legacy: legacy,
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let defaults = FakeLegacyDefaults(values: [legacy.defaultsKey: "1.0"])
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: DispatchBlockingExecutor(label: "bench.legacy.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "bench.legacy.bulk"),
            time: time,
            random: SeededRandom(seed: 19),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: defaults
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        var holds: [(String, Double)] = []
        let opened = try await ActorHoldProbe.longestHold(of: store) {
            let report = try await store.open()
            #expect(report.legacyMigrationPending)
        }
        var longestBatch = 0.0
        var progress = LegacyMigrationProgress(adopted: 0, remaining: count, dropped: 0, finished: false)
        while progress.remaining > 500 {
            longestBatch = max(longestBatch, try await ActorHoldProbe.longestHold(of: store) {
                progress = try await store.migrateLegacy(maxFiles: 500)
            })
        }
        if stamping {
            let stop = Mutex(false)
            let stamper = Task {
                var calls = 0
                while !stop.withLock({ $0 }) {
                    time.advance(by: 0.001)
                    await store.recordAccesses([AssetID(rawValue: "legacy.bench.asset\(calls % count)"): time.now()])
                    calls += 1
                }
                return calls
            }
            var longest = 0.0
            var calls = 0
            while calls < 3, !progress.finished {
                longest = max(longest, try await ActorHoldProbe.longestHold(of: store) {
                    progress = try await store.migrateLegacy(maxFiles: 500)
                })
                calls += 1
            }
            stop.withLock { $0 = true }
            let stamps = await stamper.value
            print("C2 legacy migration over \(count) files with access stamps: \(calls) last calls, finished: \(progress.finished), \(stamps) stamps")
            holds.append((CleanupBench.legacyOperations[3], longest))
            if !progress.finished {
                progress = try await store.migrateLegacy(maxFiles: 500)
            }
        } else {
            holds.append((CleanupBench.legacyOperations[0], opened))
            holds.append((CleanupBench.legacyOperations[1], longestBatch))
            holds.append((CleanupBench.legacyOperations[2], try await ActorHoldProbe.longestHold(of: store) {
                progress = try await store.migrateLegacy(maxFiles: 500)
            }))
        }
        #expect(progress == LegacyMigrationProgress(adopted: count, remaining: 0, dropped: 0, finished: true))
        #expect(defaults.string(forKey: legacy.defaultsKey) == nil, "phase 4 removed the prior art's stamp")
        await store.close()
        return holds
    }

    /// The longest actor hold of each WP-C operation once on a store of `count` assets (WP-B's stretches inside them
    /// included): a report, one verification slice of 1,000 blobs, orphan GC of 100 orphans, a quarantine, eviction of
    /// half, then purge(.all) of the rest; then each purge on a full store of its own; then orphan GC of `count` orphans
    /// on a full store.
    static func operationHoldsAtScale(count: Int, seed: UInt64) async throws -> [(String, Double)] {
        let (store, fileSystem, time, entries) = try await CleanupBench.store(count: count, seed: seed)
        try CleanupBench.plantOrphans(100, seed: seed + 5_000_000, fileSystem: fileSystem, base: URL(fileURLWithPath: "/bench/cleanup", isDirectory: true))
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
        // Each purge on a full store of its own (review of the L3 close-out measured these, not the half left above).
        for (index, request) in [(1, PurgeRequest.evictable), (2, .all)] {
            let full = try await CleanupBench.store(count: count, seed: seed + UInt64(index) * 1_000_000).store
            holds.append(("purge(\(request == .all ? ".all" : ".evictable")) of a full store", try await ActorHoldProbe.longestHold(of: full) {
                let result = try await full.purge(request)
                #expect(result.assetsRemoved == count)
            }))
            await full.close()
        }
        // Orphan GC of as many orphans as assets (an index lost on a full store; review of close-out cycle 4: the blob
        // table's growth rehash falls inside one doom chunk).
        let (orphaned, volume, clock, _) = try await CleanupBench.store(count: count, seed: seed + 3_000_000)
        try CleanupBench.plantOrphans(count, seed: seed + 7_000_000, fileSystem: volume, base: URL(fileURLWithPath: "/bench/cleanup", isDirectory: true))
        clock.advance(by: 120)
        let later = clock.monotonicNow().adding(seconds: 3_600)
        holds.append(("orphan GC of \(count) orphans", try await ActorHoldProbe.longestHold(of: orphaned) {
            let result = try await orphaned.collectGarbage(until: later)
            #expect(result.filesRemoved == count)
        }))
        await orphaned.close()
        return holds
    }

    /// The figures of `bindingHolds(count:seed:)`, in order.
    static let bindingOperations = [
        "quota eviction after an alias was bound to every candidate",
        "apply renaming every id with an eviction plan of half",
        "purge(.evictable) after an alias was bound to every selected blob",
        "apply's eviction hook over a plan of half, longest chunk (thread CPU)",
        "apply's eviction hook over a plan of half after a rename, longest chunk (thread CPU)",
        "purge(.evictable) chunk of 1,000 blobs after an alias was bound to each (thread CPU)",
        "apply's eviction hook over a plan of half after an alias was bound to half its blobs, longest chunk (thread CPU)",
    ]

    /// The figures of `bindingOperations` asserted against the C2 budget: every one since `apply` passes its plan in
    /// chunks (ruling R6 at the L3 close-out cycle 7).
    static let boundedBindingOperations = Set(bindingOperations)

    /// `entries` renamed with `prefix`, same bytes.
    static func renamed(_ entries: [ManifestEntry], _ prefix: String) -> [ManifestEntry] {
        entries.map { entry in
            ManifestEntry(identifier: AssetID(prefix + entry.identifier.rawValue), fileExtension: "png", remotePath: prefix + "/" + entry.remotePath, byteSize: 64, checksum: entry.checksum)
        }
    }

    /// Applies `manifest` to `store` while a unit of `bulk` stays held: every other unit of `bulk` is let through.
    static func apply(_ manifest: ValidatedManifest, to store: AssetStore, releasing bulk: SteppedBlockingExecutor, except held: Int) async throws {
        let done = Mutex(false)
        let applying = Task {
            defer {
                done.withLock { $0 = true }
            }
            _ = try await store.apply(manifest, etag: nil, eviction: nil)
        }
        while !done.withLock({ $0 }) {
            for unit in await bulk.heldUnits where unit != held {
                await bulk.release(unit)
            }
            await Task.yield()
        }
        try await applying.value
    }

    /// On fresh stores of `count` assets: the longest hold of quota eviction, and of `purge(.evictable)`, after an
    /// `apply` bound an alias to every blob while the operation's selection unit was held; of an `apply` that renames
    /// every id and carries an eviction plan of half made before it; and the thread CPU of `apply`'s eviction hook over
    /// such a plan, without and with the rename and after an alias was bound to half its blobs (the longest of the
    /// chunks `apply` passes it, one turn each).
    static func bindingHolds(count: Int, seed: UInt64) async throws -> [(String, Double)] {
        var holds: [(String, Double)] = []
        let digest = { (tag: String) in ContentHash.sha256(of: Data("c2c-binding-\(seed)-\(tag)".utf8)) }
        for (index, purging) in [false, true].enumerated() {
            let bulk = SteppedBlockingExecutor(holding: false)
            let (store, _, _, entries) = try await CleanupBench.store(count: count, seed: seed + UInt64(index) * 10_000, bulk: bulk)
            let aliased = try ValidatedManifest(entries: entries + CleanupBench.renamed(entries, "alias"), digest: digest("aliased-\(index)"))
            await bulk.setHolding(true)
            let operation = Task { () -> Int in
                if purging {
                    return try await store.purge(.evictable).assetsRemoved
                }
                return try await store.evictIfNeeded().filesRemoved
            }
            try await bulk.requireHeldUnits(atLeast: 1)
            let selection = try #require(await bulk.heldUnits.first)
            try await CleanupBench.apply(aliased, to: store, releasing: bulk, except: selection)
            holds.append((CleanupBench.bindingOperations[purging ? 2 : 0], try await ActorHoldProbe.longestHold(of: store) {
                await bulk.setHolding(false)
                let removed = try await operation.value
                // Eviction keeps a blob whose holders it did not select; an evictable purge takes every holder.
                #expect(removed == (purging ? 2 * count : 0))
            }))
            await store.close()
        }
        // `apply` renaming every id, with a plan of half made before it.
        let (store, _, _, entries) = try await CleanupBench.store(count: count, seed: seed + 20_000)
        let plan = try #require(await store.evictionPlan(toFree: Int64(count) * 64 / 2, protecting: []))
        let renamed = try ValidatedManifest(entries: CleanupBench.renamed(entries, "renamed"), digest: digest("renamed"))
        holds.append((CleanupBench.bindingOperations[1], try await ActorHoldProbe.longestHold(of: store) {
            let report = try await store.apply(renamed, etag: nil, eviction: plan)
            #expect(report.evicted.isEmpty, "every planned id was renamed")
        }))
        await store.close()
        // The hook alone, one chunk per turn as `apply` passes it: over the plan as made, then after a rename (applied
        // without the plan first); each figure is the run's longest chunk.
        let (plain, _, _, _) = try await CleanupBench.store(count: count, seed: seed + 30_000)
        let half = try #require(await plain.evictionPlan(toFree: Int64(count) * 64 / 2, protecting: []))
        let evicted = await CleanupBench.hookChunks(of: half, on: plain)
        #expect(evicted.evicted == half.victims.count)
        holds.append((CleanupBench.bindingOperations[3], evicted.milliseconds.max() ?? .infinity))
        await plain.close()
        let (moved, _, _, movedEntries) = try await CleanupBench.store(count: count, seed: seed + 40_000)
        let stale = try #require(await moved.evictionPlan(toFree: Int64(count) * 64 / 2, protecting: []))
        _ = try await moved.apply(try ValidatedManifest(entries: CleanupBench.renamed(movedEntries, "renamed"), digest: digest("moved")), etag: nil, eviction: nil)
        let none = await CleanupBench.hookChunks(of: stale, on: moved)
        #expect(none.evicted == 0)
        holds.append((CleanupBench.bindingOperations[4], none.milliseconds.max() ?? .infinity))
        // One chunk of an evictable purge whose selection predates the aliases: twice the records, and the chunk's scan.
        let selection = await moved.benchThreadCPU { store in
            PurgeSelection.select(.evictable, records: store.state.core.records, blobTable: store.state.core.blobTable, publishing: [], leases: [:])
        }.value
        _ = try await moved.apply(
            try ValidatedManifest(
                entries: CleanupBench.renamed(movedEntries, "renamed") + CleanupBench.renamed(movedEntries, "alias"),
                digest: digest("moved-aliased")
            ),
            etag: nil,
            eviction: nil
        )
        let chunk = await moved.benchThreadCPU { store in
            var reclaim: [PurgeSelection.Reclaim] = []
            return store.purgeChunk(selection.prefix(AssetStore.cleanupChunk), request: .evictable, reclaim: &reclaim)
        }
        #expect(chunk.value == 2 * AssetStore.cleanupChunk, "each selected blob lost its record and the alias bound since")
        holds.append((CleanupBench.bindingOperations[5], chunk.milliseconds))
        await moved.close()
        // The hook over a plan of half after an `apply` bound an alias to half of the planned blobs (review of close-out
        // cycle 5: the turn's one scan of the records is part of it): those blobs stay, the other half is evicted.
        let (aliased, _, _, aliasedEntries) = try await CleanupBench.store(count: count, seed: seed + 60_000)
        let planned = try #require(await aliased.evictionPlan(toFree: Int64(count) * 64 / 2, protecting: []))
        let plannedIDs = Set(planned.victims.map(\.id))
        let halfOfPlan = Array(aliasedEntries.filter { plannedIDs.contains($0.identifier) }.prefix(count / 4))
        _ = try await aliased.apply(
            try ValidatedManifest(entries: aliasedEntries + CleanupBench.renamed(halfOfPlan, "alias"), digest: digest("half-aliased")),
            etag: nil,
            eviction: nil
        )
        let partly = await CleanupBench.hookChunks(of: planned, on: aliased)
        #expect(partly.evicted == planned.victims.count - halfOfPlan.count, "the aliased blobs stay")
        holds.append((CleanupBench.bindingOperations[6], partly.milliseconds.max() ?? .infinity))
        await aliased.close()
        return holds
    }
}
