import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// Scratch C2 probe (s3f close-out verification, cycle 14, correctness lens). Never committed.
extension SyncEngine {
    /// Times `followedLane` for the member job of `asset` (inside the actor), `reps` times; returns the milliseconds and
    /// the state sizes it walked.
    func probeC14CFollowedLane(asset: AssetID, reps: Int) -> (ms: [Double], jobs: Int, events: Int, owed: Bool, lane: AssetPriority?) {
        guard let job = self.state.jobs.values.first(where: { $0.assets.contains(asset) }) else {
            return ([], self.state.jobs.count, self.state.eventsAfterFollow.count, self.followOwed, nil)
        }
        var out: [Double] = []
        var lane: AssetPriority?
        let clock = ContinuousClock()
        for _ in 0..<reps {
            let start = clock.now
            lane = self.followedLane(job)
            let d = clock.now - start
            out.append(Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15)
        }
        return (out, self.state.jobs.count, self.state.eventsAfterFollow.count, self.followOwed, lane)
    }
}

extension ZTronAssetKitBenchmarks {
    @Suite("VerifyC14CorrectC2Probe")
    struct VerifyC14CorrectC2Probe {
        /// C2 of `followedLane` (cycle 14, `2926422`): a 429 behind the barrier under a 10,000-member prefetch group whose
        /// every member v3 changed (10,000 jobs owed a visit) and a second 10,000-member window whose joins wait.
        @Test("PROBE-C14C-C2-FOLLOWED-LANE", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func followedLaneCost() async throws {
            let count = 10_000
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
                metadataExecutor: InlineBlockingExecutor(),
                bulkExecutor: InlineBlockingExecutor(),
                time: time,
                random: SeededRandom(seed: 0x11),
                conditions: conditions,
                remoteSources: FakeRemoteSourceFactory(source: source),
                appVersion: FakeAppVersionSource(),
                legacyDefaults: FakeLegacyDefaults()
            )
            let configuration = StoreConfiguration(
                location: .applicationSupport,
                policy: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
                legacy: LegacyMigrationPolicy(enabled: false),
                limits: ManifestLimits(),
                commitMinimumInterval: 0,
                snapshotInstallInterval: 0
            )
            let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
            let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
            let xBytes = Data(repeating: 0x78, count: 2_000)
            let x = SyncBench.entry("x", xBytes)
            await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
            await source.script(x.transferID, [.stage(xBytes)])
            _ = try await engine.start().get()
            let first = await engine.sync(.force)
            try #require(first.isComplete)
            let members = { (seed: UInt64) in
                (0..<count).map { index in
                    SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
                }
            }
            let extras = (0..<count).map { index in
                SyncBench.entry(String(format: "t%05d", index), GeneratedPayload.bytes(seed: 0x77_000 + UInt64(index), offset: 0, length: 400), policy: .onDemand)
            }
            let old = members(0x21_000)
            await source.scriptManifest([.fetched(SyncBench.manifestData(old + extras), etag: ETag(rawValue: "\"v2\""))])
            let second = await engine.sync(.force)
            try #require(second.isComplete)
            try await store.flush(.ordered)
            try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
            await engine.refreshFreeSpace()
            guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
                Issue.record("the prefetch group was refused")
                return
            }
            while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
                await Task.yield()
            }
            let renewed = members(0x55_000)
            await source.scriptManifest([.fetched(SyncBench.manifestData(renewed + extras), etag: ETag(rawValue: "\"v3\""))])
            await engine.holdFollowFollowUps()
            let sync = Task { await engine.sync(.force) }
            while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
                await Task.yield()
            }
            guard case .success = await engine.registerGroup(extras.map(\.identifier), lane: .prefetch) else {
                Issue.record("the second prefetch group was refused")
                return
            }
            while !Task.isCancelled, !(await SyncBench.eventsWaiting(engine, atLeast: count)) {
                await Task.yield()
            }
            // An old member whose job is owed a visit: its own interest moves, so both walks run to the end.
            let measured = await engine.probeC14CFollowedLane(asset: old[5_000].identifier, reps: 7)
            let best = measured.ms.min() ?? .infinity
            let median = measured.ms.sorted()[measured.ms.count / 2]
            print("PROBE-C14C-C2-FOLLOWED-LANE jobs=\(measured.jobs) events=\(measured.events) owed=\(measured.owed) lane=\(String(describing: measured.lane)) ms=\(measured.ms.map { String(format: "%.3f", $0) }) best=\(String(format: "%.3f", best)) median=\(String(format: "%.3f", median)) load=\(ProcessInfo.processInfo.systemUptime)")
            #expect(measured.jobs >= count && measured.events >= count && measured.owed, "setup: \(measured.jobs) jobs, \(measured.events) events, owed \(measured.owed)")
            #expect(best <= 10, "C2: followedLane at 10,000 jobs and 10,000 waiting joins: best \(best) ms")
            await engine.shutdown()
            _ = await sync.value
        }
    }
}
