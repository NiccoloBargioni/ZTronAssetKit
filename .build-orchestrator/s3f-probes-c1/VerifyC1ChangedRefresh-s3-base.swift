import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probe (s3f close-out verification, cycle 1, correctness lens): C2 of a forced sync whose manifest changes the
/// content of some members of a waiting 10,000-member prefetch group (the S3-PERF-02 shape with content changes instead
/// of one added entry). Production dispatch executors, release build, heartbeat measurement of `SyncBench.longestWait`.
@Suite("VerifyC1Correct changed refresh")
struct VerifyC1ChangedRefresh {
    @available(macOS 15.0, iOS 18.0, *)
    static func changedRefreshWait(members count: Int, changedPercent: Int) async throws -> Double {
        let bench = try await SyncBench.dispatchBench(members: count)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        let v2 = bench.entries.enumerated().map { index, entry in
            index % 100 < changedPercent
                ? SyncBench.entry(entry.identifier.rawValue, GeneratedPayload.bytes(seed: 0x77_000 + UInt64(index), offset: 0, length: bench.size), policy: .onDemand)
                : entry
        }
        await bench.source.scriptManifest([.fetched(SyncBench.manifestData(v2), etag: ETag(rawValue: "\"v2\""))])
        let wait = try await SyncBench.longestWait(on: engine) {
            guard await engine.sync(.force).isComplete else {
                throw SyncBenchError.incomplete("the refresh did not complete")
            }
        }
        let violations = await engine.invariantViolations()
        await engine.shutdown()
        if !violations.isEmpty {
            throw SyncBenchError.incomplete("invariants: \(violations.prefix(3))")
        }
        return wait
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-V9: a refresh that changes 1 %, 10 % or 100 % of a waiting 10,000-member prefetch group's content holds the engine's actor at most 10 ms", .timeLimit(.minutes(10)))
    func changedRefresh() async throws {
        _ = try await VerifyC1ChangedRefresh.changedRefreshWait(members: 1_000, changedPercent: 10)
        var lines: [String] = []
        var best: [Int: Double] = [:]
        for percent in [1, 10, 100] {
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await VerifyC1ChangedRefresh.changedRefreshWait(members: 10_000, changedPercent: percent))
            }
            best[percent] = runs.min() ?? .infinity
            lines.append("\(percent)% changed: runs \(runs) ms")
        }
        print("PROBE-V9 longest actor wait at 10,000 members: \(lines)")
        for (percent, value) in best.sorted(by: { $0.key < $1.key }) {
            #expect(value <= 10.0, "PROBE-V9 FAIL: \(percent)% changed, best of three \(value) ms > C2's 10 ms")
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
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
            metadataExecutor: DispatchBlockingExecutor(label: "bench.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "bench.bulk"),
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
