import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// Scratch probe (s3f cycle-14 requirements verifier; never committed): the cost of one `followedLane` call, the walk
/// cycle 14 added to `throttled` behind the barrier, with a 10,000-member prefetch group whose every member v3 changed
/// while the follow is owed (no interest raises the lane, so both walks run to the end).
extension ZTronAssetKitBenchmarks {
    @Suite("VerifyC14ReqsC2")
    struct VerifyC14ReqsC2 {
        @Test("PROBE-C14R-LANE-C2", .timeLimit(.minutes(5)))
        @available(macOS 15.0, iOS 18.0, *)
        func laneWalk() async throws {
            for count in [1_000, 10_000] {
                let r = try await SyncBench.c14rFollowedLaneCost(members: count)
                print("PROBE-C14R-LANE-C2 members=\(count) \(r)")
            }
        }
    }
}

extension SyncBench {
    @available(macOS 15.0, iOS 18.0, *)
    static func c14rFollowedLaneCost(members count: Int) async throws -> String {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity))
        let environment = AssetEnvironment(
            fileSystem: fileSystem, metadataExecutor: InlineBlockingExecutor(), bulkExecutor: InlineBlockingExecutor(), time: time,
            random: SeededRandom(seed: 0x11), conditions: conditions, remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(), legacyDefaults: FakeLegacyDefaults()
        )
        let configuration = StoreConfiguration(location: .applicationSupport, policy: StoragePolicy(minimumResidency: 0, deletionGrace: 60), legacy: LegacyMigrationPolicy(enabled: false), limits: ManifestLimits(), commitMinimumInterval: 0, snapshotInstallInterval: 0)
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else { throw SyncBenchError.incomplete("setup sync") }
        let members = { (seed: UInt64) in
            (0..<count).map { index in
                SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: 400), policy: .onDemand)
            }
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(members(0x21_000)), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else { throw SyncBenchError.incomplete("v2 sync") }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        let old = members(0x21_000)
        guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else { throw SyncBenchError.incomplete("group") }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(members(0x55_000)), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        var samples: [Double] = []
        var info = ""
        for _ in 0..<5 {
            let r = await SyncBench.c14rLaneOnce(engine)
            samples.append(r.ms)
            info = r.info
        }
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = await sync.value
        return "followedLane ms=\(samples.map { String(format: "%.3f", $0) }) \(info)"
    }

    static func c14rLaneOnce(_ engine: isolated SyncEngine) -> (ms: Double, info: String) {
        guard let job = engine.state.jobs.values.first else {
            return (0, "no job")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let lane = engine.followedLane(job)
        let d = start.duration(to: clock.now)
        let ms = Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
        return (ms, "lane=\(String(describing: lane)) owed=\(engine.followOwed) barrier=\(engine.followBarrier) jobs=\(engine.state.jobs.count) events=\(engine.state.eventsAfterFollow.count)")
    }
}
