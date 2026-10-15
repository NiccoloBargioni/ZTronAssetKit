import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

extension ZTronAssetKitBenchmarks {
    /// P-4, P-7, P-11 and P-14 (WP-F), release configuration. Every threshold comes from `QualityBudgets`.
    ///
    /// P-4 is the median of 21 plans after 3 warm-ups at 10,000 and 20,000 entries. P-7 syncs a synthetic catalog
    /// streamed by `FakeTransferStep.stageGenerated` into real files in a directory inside this repository and samples
    /// the resident size (`MemoryProbe`) at every transfer start and after the run; it runs a quarter catalog first, so
    /// "does not grow with catalog size" compares the two deltas. P-11 times a sync of the real HTTP source against the
    /// loopback server with real latency at concurrency 1 and at the configured concurrency (benchmarks are exempt from
    /// the no-sleep rule, sync-2 S2-14). P-14 drives a sync to quiescence on `ManualTimeSource` and reads the engine's
    /// census plus the environment's.
    @Suite("SyncBenchmarks")
    struct SyncBenchmarks {
        @Test("P-4: planning 10,000 vs 10,000 entries with 10% churn stays within plan_ms and scales by at most doubling_ratio_max", .timeLimit(.minutes(1)))
        func planning() async throws {
            let budgets = try QualityBudgets()
            let planMs = try #require(budgets.value("P-4", "plan_ms"))
            let ratioMax = try #require(budgets.value("P-4", "doubling_ratio_max"))
            let small = SyncBench.medianPlanMilliseconds(entries: 10_000)
            let large = SyncBench.medianPlanMilliseconds(entries: 20_000)
            let ratio = large / max(small, 0.000_001)
            print("P-4 plan 10,000: \(small) ms (budget \(planMs)); 20,000: \(large) ms; ratio \(ratio) (max \(ratioMax))")
            #expect(small <= planMs)
            #expect(ratio <= ratioMax)
        }

        @Test("P-14: after quiescence the engine owns at most idle_timers_max timers and idle_tasks_max tasks", .timeLimit(.minutes(1)))
        @available(macOS 15.0, iOS 18.0, *)
        func idleCensus() async throws {
            let budgets = try QualityBudgets()
            let timersMax = Int(try #require(budgets.value("P-14", "idle_timers_max")))
            let tasksMax = Int(try #require(budgets.value("P-14", "idle_tasks_max")))
            let time = ManualTimeSource()
            let source = FakeRemoteSource()
            let conditions = FakeDeviceConditionsSource()
            let engine = SyncBench.fakeEngine(time: time, source: source, conditions: conditions)
            let entries = (0..<50).map { index -> (ManifestEntry, Data) in
                let bytes = GeneratedPayload.bytes(seed: 0x14_000 + UInt64(index), offset: 0, length: 512)
                return (SyncBench.entry("idle-\(index)", bytes), bytes)
            }
            await source.scriptManifest([.fetched(SyncBench.manifestData(entries.map(\.0)), etag: ETag(rawValue: "\"p14\""))])
            for (entry, bytes) in entries {
                await source.script(entry.transferID, [.stage(bytes)])
            }
            _ = try await engine.start().get()
            try await SyncBench.drive(engine: engine, time: time) { $0.groups == 0 }
            // Prune half of the catalog: doomed blobs keep the store's grace deadline in the engine's heap.
            await source.scriptManifest([.fetched(SyncBench.manifestData(entries.prefix(25).map(\.0)), etag: ETag(rawValue: "\"p14b\""))])
            let run = Task { await engine.sync(.force) }
            // The run cannot finish before the clock opens its commit window, so it is seen running first.
            await engine.waitUntil { $0.groups >= 1 }
            try await SyncBench.drive(engine: engine, time: time) { $0.groups == 0 }
            #expect(await run.value.isComplete)
            try await SyncBench.drive(engine: engine, time: time) { $0.isIdleSilent }
            try await conditions.requireObservers(equalTo: 0)
            let state = await engine.introspect()
            print("P-14 armed timers \(state.armedTimers) (max \(timersMax)), owned tasks \(state.ownedTasks) (max \(tasksMax)), sleepers \(time.pendingSleepers)")
            #expect(state.armedTimers <= timersMax)
            #expect(state.ownedTasks <= tasksMax)
            #expect(!state.watcherActive && state.scheduledDeadlines == 0)
            #expect(time.pendingSleepers == 0)
            #expect(await source.activeTransfers == 0)
            #expect(await conditions.activeObservers == 0)
            await engine.shutdown()
        }

        @Test("P-7: a 1 GiB synthetic bulk sync adds at most sync_memory_delta_mib_max MiB and does not grow with catalog size", .timeLimit(.minutes(1)))
        @available(macOS 15.0, iOS 18.0, *)
        func syncMemory() async throws {
            let budgets = try QualityBudgets()
            let deltaMax = try #require(budgets.value("P-7", "sync_memory_delta_mib_max"))
            let catalogGiB = try #require(budgets.value("P-7", "catalog_gib"))
            let full = Int64(catalogGiB * Double(1 << 30))
            let quarter = try await SyncBench.syncMemoryDelta(catalogBytes: full / 4)
            let whole = try await SyncBench.syncMemoryDelta(catalogBytes: full)
            print("P-7 resident delta: \(MemoryProbe.mebibytes(quarter)) MiB for \((full / 4) >> 20) MiB, \(MemoryProbe.mebibytes(whole)) MiB for \(full >> 20) MiB (max \(deltaMax))")
            #expect(MemoryProbe.mebibytes(whole) <= deltaMax)
            #expect(MemoryProbe.mebibytes(quarter) <= deltaMax)
            #expect(MemoryProbe.mebibytes(whole) <= MemoryProbe.mebibytes(quarter) + deltaMax / 4, "the delta does not grow with the catalog")
        }

        @Test("P-11: assets with server latency sync at least speedup_min times faster at the configured concurrency than at 1", .timeLimit(.minutes(1)))
        @available(macOS 15.0, iOS 18.0, *)
        func latencySpeedup() async throws {
            let budgets = try QualityBudgets()
            let assets = Int(try #require(budgets.value("P-11", "assets")))
            let latency = try #require(budgets.value("P-11", "server_latency_ms"))
            let concurrency = Int(try #require(budgets.value("P-11", "concurrency")))
            let speedupMin = try #require(budgets.value("P-11", "speedup_min"))
            let serial = try await SyncBench.timedLoopbackSync(assets: assets, latencyMs: latency, concurrency: 1)
            let parallel = try await SyncBench.timedLoopbackSync(assets: assets, latencyMs: latency, concurrency: concurrency)
            let speedup = serial / max(parallel, 0.000_001)
            print("P-11 \(assets) assets at \(latency) ms: concurrency 1 \(serial) s, \(concurrency) \(parallel) s, speedup \(speedup) (min \(speedupMin))")
            #expect(speedup >= speedupMin)
        }

        /// The announcement of a mass prune runs in one actor turn of the engine (`applied`): with a subscriber that
        /// never pulls, each `assetRemoved` takes a slot of its queue, so a queue copied per publication made that turn
        /// quadratic (about 0.16 s at 4,000 ids, C2). Medians of three, after a warm-up.
        @Test("R-SYN-12: announcing a 10,000-id prune to a stalled subscriber costs at most twice the same sync with nobody subscribed", .timeLimit(.minutes(1)))
        @available(macOS 15.0, iOS 18.0, *)
        func stalledPruneAnnouncement() async throws {
            _ = try await SyncBench.pruneSyncSeconds(count: 1_000, stalled: true)
            var quiet: [Double] = []
            var stalled: [Double] = []
            for _ in 0..<3 {
                quiet.append(try await SyncBench.pruneSyncSeconds(count: 10_000, stalled: false))
                stalled.append(try await SyncBench.pruneSyncSeconds(count: 10_000, stalled: true))
            }
            let unobserved = quiet.sorted()[1]
            let observed = stalled.sorted()[1]
            print("R-SYN-12 prune of 10,000 ids: nobody subscribed \(unobserved) s, one stalled subscriber \(observed) s, ratio \(observed / max(unobserved, 0.000_001)) (max 2, plus 5 ms)")
            #expect(observed <= 2 * unobserved + 0.005)
        }
    }
}

/// Helpers of `SyncBenchmarks` (namespaced so no other package's helpers can collide).
enum SyncBench {
    /// An entry for `bytes`.
    static func entry(_ id: String, _ bytes: Data, policy: AssetPolicy = .standard) -> ManifestEntry {
        ManifestEntry(
            identifier: AssetID(id),
            fileExtension: "bin",
            remotePath: "media/\(id).bin",
            localPathComponents: ["dir"],
            byteSize: Int64(bytes.count),
            checksum: ContentHash.sha256(of: bytes),
            policy: policy
        )
    }

    /// The bare-array wire bytes of `entries`.
    static func manifestData(_ entries: [ManifestEntry]) -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
    }

    /// A manifest of `entries` with a digest derived from them.
    static func manifest(_ entries: [ManifestEntry], tag: String) -> ValidatedManifest {
        (try? ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data(tag.utf8)))) ?? .empty()
    }

    // MARK: P-4

    /// The median of 21 plans (after 3 warm-ups) of `entries` entries against as many applied ones with 10 % churn:
    /// 2.5 % each added, removed, content-changed and metadata-changed (sync.md §4.5).
    static func medianPlanMilliseconds(entries count: Int) -> Double {
        var random = SplitMix64(seed: 0x4_0000 + UInt64(count))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var applied: [ManifestEntry] = []
        var records: [AssetID: AssetRecord] = [:]
        var live = Set<ContentHash>()
        records.reserveCapacity(count)
        for index in 0..<count {
            let hash = ContentHash.sha256(of: Data("p4-\(count)-\(index)".utf8))
            let entry = ManifestEntry(identifier: AssetID("asset.\(index)"), fileExtension: "png", remotePath: "media/\(index).png", localPathComponents: ["dir"], byteSize: 4_096, checksum: hash)
            applied.append(entry)
            let key = BlobKey(hash: hash, ext: AssetFileExtension("png")!)
            records[entry.identifier] = AssetRecord(entry: entry, residency: .present(blob: key, byteSize: 4_096, integrity: .verified), expectedBlob: hash, lastAccess: now)
            live.insert(hash)
        }
        var next: [ManifestEntry] = []
        next.reserveCapacity(count)
        for entry in applied {
            switch random.next() % 40 {
            case 0:
                continue
            case 1:
                var changed = entry
                changed.checksum = ContentHash.sha256(of: Data("p4-changed-\(entry.identifier.rawValue)".utf8))
                next.append(changed)
            case 2:
                var moved = entry
                moved.localPathComponents = ["moved"]
                next.append(moved)
            case 3:
                next.append(entry)
                let hash = ContentHash.sha256(of: Data("p4-added-\(entry.identifier.rawValue)".utf8))
                next.append(ManifestEntry(identifier: AssetID("added.\(entry.identifier.rawValue)"), fileExtension: "png", remotePath: "media/a-\(entry.identifier.rawValue).png", localPathComponents: ["dir"], byteSize: 4_096, checksum: hash))
            default:
                next.append(entry)
            }
        }
        let view = StorePlanningView(
            generation: 1,
            appliedManifest: SyncBench.manifest(applied, tag: "applied-\(count)"),
            records: records,
            liveBlobs: live,
            purgeEpoch: 0,
            stamp: nil,
            syncDue: false
        )
        let manifest = SyncBench.manifest(next, tag: "next-\(count)")
        let policy = PlanningPolicy(storage: StoragePolicy(), includeOnDemand: false, now: now)
        let space = FreeSpace(volumeImportant: 1 << 40, volumeOpportunistic: 1 << 40, usedBytes: 0, pendingReclaim: 0, budgetBytes: Int64.max, reserveBytes: 0)
        var samples: [Double] = []
        let clock = ContinuousClock()
        for round in 0..<24 {
            let started = clock.now
            let plan = SyncPlanner.plan(manifest: manifest, snapshot: view, scope: .all, policy: policy, freeSpace: space)
            let elapsed = clock.now - started
            precondition(!plan.fetches.isEmpty)
            if round >= 3 {
                samples.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
            }
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    // MARK: Engines

    /// An engine over a `FakeFileSystem` store and `FakeRemoteSource` on `time` (P-14).
    @available(macOS 15.0, iOS 18.0, *)
    static func fakeEngine(time: ManualTimeSource, source: FakeRemoteSource, conditions: FakeDeviceConditionsSource) -> SyncEngine {
        let environment = AssetEnvironment(
            fileSystem: FakeFileSystem(time: time),
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x14),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(legacy: LegacyMigrationPolicy(enabled: false)),
            environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
        )
        return SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
    }

    /// The wall time of a sync that prunes `count` on-demand entries (nothing is downloaded), with one subscriber that
    /// never pulls when `stalled`.
    @available(macOS 15.0, iOS 18.0, *)
    static func pruneSyncSeconds(count: Int, stalled: Bool) async throws -> Double {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let environment = AssetEnvironment(
            fileSystem: FakeFileSystem(time: time),
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x12),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        // No commit window: the timed sync needs no clock.
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let keep = SyncBench.entry("keep", GeneratedPayload.bytes(seed: 0x12_000, offset: 0, length: 16), policy: .onDemand)
        let doomed = (0..<count).map { index in
            SyncBench.entry("p\(index)", GeneratedPayload.bytes(seed: 0x12_001 + UInt64(index), offset: 0, length: 16), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData([keep] + doomed), etag: ETag(rawValue: "\"v1\""))])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the first sync did not complete")
        }
        let subscription = stalled ? try await engine.subscribe().get() : nil
        await source.scriptManifest([.fetched(SyncBench.manifestData([keep]), etag: ETag(rawValue: "\"v2\""))])
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await engine.sync(.force)
        let elapsed = clock.now - started
        guard case .complete(let report) = outcome, report.pruned == count else {
            throw SyncBenchError.incomplete("the timed sync: \(outcome)")
        }
        if subscription != nil, await engine.introspect().bufferedEvents < count {
            throw SyncBenchError.incomplete("the stalled subscriber did not hold one slot per pruned id")
        }
        await engine.shutdown()
        _ = subscription
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// An engine configuration with defaults and `tuning`.
    static func configuration(tuning: SyncTuning, remote: RemoteConfiguration = RemoteConfiguration()) -> EngineConfiguration {
        EngineConfiguration(
            tuning: tuning,
            storage: StoragePolicy(),
            network: NetworkPolicy(),
            power: PowerPolicy(),
            refresh: .oncePerAppVersion,
            remote: remote,
            limits: ManifestLimits()
        )
    }

    /// Drives `time` until `predicate` holds (the engine's alarm and store waits move only with the manual clock).
    @available(macOS 15.0, iOS 18.0, *)
    static func drive(engine: SyncEngine, time: ManualTimeSource, until predicate: @escaping @Sendable (EngineIntrospection) -> Bool) async throws {
        for _ in 0..<1_024 {
            let state = await engine.introspect()
            if predicate(state) {
                return
            }
            // Steps of at most 20 s: commit windows, installs and the 10 s deletion grace pass; the 30 s manifest
            // deadline of a fetch still at work never does.
            if let deadline = time.nextDeadline, deadline <= time.monotonicNow().adding(seconds: 20) {
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
        throw CancellationError()
    }

    /// A directory inside this repository (`.build-tests/`, git-ignored); the caller removes it.
    static func directory(_ name: String, filePath: String = #filePath) throws -> URL {
        let repository = URL(fileURLWithPath: filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".build-tests/bench-sync/\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: P-7

    /// Syncs a catalog of `catalogBytes` (4 MiB assets streamed in 256 KiB chunks) into real files and returns the peak
    /// resident delta above the resident size measured before the engine started.
    @available(macOS 15.0, iOS 18.0, *)
    static func syncMemoryDelta(catalogBytes: Int64) async throws -> UInt64 {
        let directory = try SyncBench.directory("p7")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let assetBytes: Int64 = 4 << 20
        let count = Int(max(1, catalogBytes / assetBytes))
        let entries = (0..<count).map { index -> ManifestEntry in
            let seed = 0x7_0000 + UInt64(index)
            return ManifestEntry(
                identifier: AssetID("p7.\(index)"),
                fileExtension: "bin",
                remotePath: "media/p7-\(index).bin",
                localPathComponents: ["dir"],
                byteSize: assetBytes,
                checksum: GeneratedPayload.sha256(seed: seed, byteCount: assetBytes)
            )
        }
        let sampler = MemoryProbe.PeakSampler()
        let fake = FakeRemoteSource()
        await fake.scriptManifest([.fetched(SyncBench.manifestData(entries), etag: ETag(rawValue: "\"p7\""))])
        for (index, entry) in entries.enumerated() {
            await fake.script(entry.transferID, [.stageGenerated(seed: 0x7_0000 + UInt64(index), byteCount: assetBytes)])
        }
        let source = SamplingSource(base: fake, sampler: sampler)
        let environment = AssetEnvironment(
            fileSystem: LiveFileSystem(),
            metadataExecutor: DispatchBlockingExecutor(label: "bench-sync.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "bench-sync.bulk"),
            time: LiveTimeSource(),
            random: SeededRandom(seed: 0x7),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(location: .custom(directory), legacy: LegacyMigrationPolicy(enabled: false)),
            environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
        )
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        sampler.start()
        _ = try await engine.start().get()
        let outcome = await engine.sync(.force)
        sampler.sample()
        guard outcome.isComplete else {
            await engine.shutdown()
            throw SyncBenchError.incomplete(String(describing: outcome))
        }
        await engine.waitUntil { $0.groups == 0 }
        sampler.sample()
        await engine.shutdown()
        return sampler.peakDelta
    }

    // MARK: P-11

    /// Seconds a sync of `assets` 1 KiB assets takes over the real HTTP source against the loopback server answering
    /// after `latencyMs`, at `concurrency`.
    @available(macOS 15.0, iOS 18.0, *)
    static func timedLoopbackSync(assets: Int, latencyMs: Double, concurrency: Int) async throws -> Double {
        let bodies = (0..<assets).map { GeneratedPayload.bytes(seed: 0x11_000 + UInt64($0), offset: 0, length: 1_024) }
        let entries = bodies.enumerated().map { index, body in SyncBench.entry("p11.\(index)", body) }
        let manifest = SyncBench.manifestData(entries)
        let latency = UInt64(latencyMs * 1_000_000)
        let server = LoopbackHTTPServer(delay: LiveLoopbackDelay()) { request in
            if request.target == "/manifest.json" {
                return LoopbackResponse(body: manifest)
            }
            let index = Int(request.target.dropFirst("/media/p11.".count).dropLast(".bin".count)) ?? 0
            return LoopbackResponse(body: bodies[min(max(index, 0), bodies.count - 1)], latencyNanoseconds: latency)
        }
        let port = try await server.start()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        let time = LiveTimeSource()
        let environment = AssetEnvironment(
            fileSystem: FakeFileSystem(time: time),
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x11),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: LoopbackBenchFactory(base: base, connections: max(concurrency, 1) + 1),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(legacy: LegacyMigrationPolicy(enabled: false)),
            environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
        )
        let tuning = SyncTuning(maxConcurrentTransfers: concurrency, reservedInteractiveSlots: 0)
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: tuning, remote: RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: base))))
        _ = try await engine.start().get()
        // `start()` launched the due run; its manifest fetch is part of the measured run either way.
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await engine.sync(.force)
        await engine.waitUntil { $0.groups == 0 }
        let elapsed = clock.now - started
        let report = await engine.availability(scope: .all)
        await engine.shutdown()
        await server.stop()
        guard (try? report.get())?.present == assets else {
            throw SyncBenchError.incomplete(String(describing: outcome))
        }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

/// Why a benchmark could not measure.
enum SyncBenchError: Error {
    /// The sync did not complete.
    case incomplete(String)
}

/// A source that samples the resident size at every transfer start, then forwards to `base` (P-7).
@available(macOS 15.0, iOS 18.0, *)
struct SamplingSource: RemoteSource, StagingAttachable {
    let base: FakeRemoteSource
    let sampler: MemoryProbe.PeakSampler

    var originID: String {
        self.base.originID
    }

    var capabilities: RemoteSourceCapabilities {
        self.base.capabilities
    }

    func attach(staging: any StagingSink) async {
        await self.base.attach(staging: staging)
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        try await self.base.fetchManifest(request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        self.sampler.sample()
        return await self.base.transfer(request)
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        await self.base.reattachedTransfers()
    }

    func cancelTransfer(_ name: StagingFileName) async {
        await self.base.cancelTransfer(name)
    }

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        await self.base.reclaimSourceCopies(report)
    }

    func sourceCopyBytes() async -> Int64 {
        await self.base.sourceCopyBytes()
    }

    func handleBackgroundEvents(identifier: String) async {
        await self.base.handleBackgroundEvents(identifier: identifier)
    }

    func invalidate() async {
        await self.base.invalidate()
    }
}

/// The real HTTP source over the store's staging sink against the loopback server (P-11).
struct LoopbackBenchFactory: RemoteSourceFactory {
    let base: URL
    let connections: Int

    func makeRemoteSource(configuration: RemoteConfiguration, staging: any StagingSink, log: LogRoute) async throws(AssetError) -> any RemoteSource {
        let policy = TransportSecurityPolicy.loopbackTesting(allowedHosts: ["127.0.0.1"])
        let delegate = SessionDelegate(mode: .foreground, staging: staging, policy: policy)
        let foreground = ForegroundTransferBackend(delegate: delegate, maxConnectionsPerHost: self.connections, requestTimeout: 30, appKey: nil, log: log)
        let http = HTTPSourceConfiguration(baseURL: self.base, appKey: nil, maxConnectionsPerHost: self.connections, requestTimeout: 30)
        return HTTPRemoteSource(configuration: http, staging: staging, policy: policy, foreground: foreground, background: nil, log: log)
    }
}

extension SyncOutcome {
    /// Whether the run completed.
    var isComplete: Bool {
        if case .complete = self {
            return true
        }
        return false
    }

}
