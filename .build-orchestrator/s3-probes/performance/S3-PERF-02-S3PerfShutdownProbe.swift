import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// S3-PERF probe: C2 at SPEC §6's reference scale when the engine shuts down under a 10,000-member prefetch group
    /// (three run, the others wait in the queue) and 10,000 user-initiated `resolve` callers waiting on its members.
    /// `performShutdown` cancels every job's handle over the sorted job table, then `resumeEverything` resumes every
    /// waiter over sorted keys, cancels again over the sorted job table and drops the table, all in one actor turn.
    /// Medians of three against P-9, the best of three against C2, after a warm-up; the 1,000 figure gives the ratio.
    @Test("C2: shutting down an engine under a 10,000-member prefetch group and 10,000 waiting resolves holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
    @available(macOS 15.0, iOS 18.0, *)
    func shutdownTurns() async throws {
        let budgets = try QualityBudgets()
        let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
        let small = try await S3ShutdownProbe.shutdownWait(members: 1_000)
        var runs: [Double] = []
        for _ in 0..<3 {
            runs.append(try await S3ShutdownProbe.shutdownWait(members: 10_000))
        }
        let median = runs.sorted()[1]
        let groupOnly = try await S3ShutdownProbe.shutdownWait(members: 10_000, waiters: false)
        print("C2 shutdown under 10,000 prefetch members and 10,000 waiting resolves: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs); at 1,000: \(small) ms, ratio \(median / max(small, 0.001)); the 10,000-member group without waiters: \(groupOnly) ms")
        #expect(median <= gapMax)
        #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
    }
}

/// Helpers of the S3-PERF shutdown probe.
enum S3ShutdownProbe {
    /// The heartbeat's longest wait while `engine.shutdown()` runs over a `count`-member prefetch group whose members
    /// also each have one waiting user-initiated `resolve` caller.
    @available(macOS 15.0, iOS 18.0, *)
    static func shutdownWait(members count: Int, waiters: Bool = true) async throws -> Double {
        let bench = try await S3ShutdownProbe.dispatchBench(members: count)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        callers.reserveCapacity(count)
        for entry in bench.entries where waiters {
            callers.append(Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) })
        }
        let expected = waiters ? count : 0
        await engine.awaitCondition { $0.state.waiters.count == expected }
        await engine.waitForAllHandles()
        let wait = try await SyncBench.longestWait(on: engine) {
            await engine.shutdown()
        }
        for caller in callers {
            guard case .failure(.shutDown) = await caller.value else {
                throw SyncBenchError.incomplete("a waiting resolve was not answered shutDown")
            }
        }
        return wait
    }
}

extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// S3-PERF probe: C2 at SPEC §6's reference scale when a sync run applies a new manifest (one entry added) while a
    /// 10,000-member prefetch group waits in the queue: `followApplied`, `releaseSystemReattachments` and `finishRun`
    /// each walk the whole job table in sorted order inside one turn. Medians of three against P-9, the best of three
    /// against C2, after a warm-up.
    @Test("C2: a sync run that applies a new manifest under a 10,000-member prefetch group holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
    @available(macOS 15.0, iOS 18.0, *)
    func refreshUnderGroupTurns() async throws {
        let budgets = try QualityBudgets()
        let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
        _ = try await S3ShutdownProbe.refreshWait(members: 1_000)
        var runs: [Double] = []
        for _ in 0..<3 {
            runs.append(try await S3ShutdownProbe.refreshWait(members: 10_000))
        }
        let median = runs.sorted()[1]
        print("C2 refresh under a 10,000-member prefetch group: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
        #expect(median <= gapMax)
        #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
    }
}

extension S3ShutdownProbe {
    /// Diagnostic: one `followApplied()` turn on an engine whose jobs already follow its copy (nothing moves), and the
    /// sort of the job table's keys it starts with, in milliseconds.
    static func followAppliedMilliseconds(_ engine: isolated SyncEngine) -> (follow: Double, sort: Double) {
        let clock = ContinuousClock()
        var start = clock.now
        let keys = engine.state.jobs.keys.sorted()
        let sort = clock.now - start
        start = clock.now
        engine.followApplied()
        let follow = clock.now - start
        withExtendedLifetime(keys) {}
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }
        return (ms(follow), ms(sort))
    }

    /// The heartbeat's longest wait while a forced sync applies a manifest with one more entry under a `count`-member
    /// prefetch group that waits in the queue.
    @available(macOS 15.0, iOS 18.0, *)
    static func refreshWait(members count: Int) async throws -> Double {
        let bench = try await S3ShutdownProbe.dispatchBench(members: count)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        let parts = await S3ShutdownProbe.followAppliedMilliseconds(engine)
        print("S3-PERF diagnostic at \(count) jobs: followApplied() alone \(parts.follow) ms (of which sorting the job table's keys \(parts.sort) ms)")
        let extra = SyncBench.entry("extra", GeneratedPayload.bytes(seed: 0xE1, offset: 0, length: 400), policy: .onDemand)
        await bench.source.scriptManifest([.fetched(SyncBench.manifestData(bench.entries + [extra]), etag: ETag(rawValue: "\"v2\""))])
        let wait = try await SyncBench.longestWait(on: engine) {
            guard await engine.sync(.force).isComplete else {
                throw SyncBenchError.incomplete("the refresh did not complete")
            }
        }
        await engine.shutdown()
        return wait
    }
}

extension S3ShutdownProbe {
    /// `SyncBench.scaleBench(members:room: nil)` with production's executors: the engine's manifest decode and the
    /// store's units run on dedicated dispatch queues, off the actors (`InlineBlockingExecutor` would run them on the
    /// calling actor and charge them to the turn).
    @available(macOS 15.0, iOS 18.0, *)
    static func dispatchBench(members count: Int) async throws -> ScaleBench {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: DispatchBlockingExecutor(label: "s3perf.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "s3perf.bulk"),
            time: time,
            random: SeededRandom(seed: 0x11),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
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
        let size = 400
        let entries = (0..<count).map { index in
            SyncBench.entry("s\(index)", GeneratedPayload.bytes(seed: 0x11_000 + UInt64(index), offset: 0, length: size), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(entries), etag: ETag(rawValue: "\"v1\""))])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        return ScaleBench(engine: engine, source: source, conditions: conditions, entries: entries, size: size, fileSystem: fileSystem, ballast: nil, time: time)
    }
}
