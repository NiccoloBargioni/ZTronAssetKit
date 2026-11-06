import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport
@testable import ZTronAssetSync

/// Design D3 C2 probe (scratch). While a follow is owed, a place in a queue is deferred (`eventsAfterFollow`), so a
/// 10,000-member prefetch group registered during an owed follow leaves 10,000 deferred enqueues; the follow's end
/// drains them `eventsAfterFollowPerTurn` per turn. The probe releases a held follow over 10,000 changed members while
/// those 10,000 events wait, and measures the longest actor wait until every follow turn and drain turn has run.
@Suite("VerifyD3DrainC2", .serialized)
struct VerifyD3DrainC2 {
    @Test("VERIFY-D3-DRAIN-C2: the follow's turns and the drain of 10,000 deferred places hold the actor at most C2's 10 ms per turn", .timeLimit(.minutes(5)))
    @available(macOS 15.0, iOS 18.0, *)
    func drainTurns() async throws {
        _ = try await SyncBench.verifyD3DrainWait(members: 1_000)
        var runs: [Double] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.verifyD3DrainWait(members: 10_000))
        }
        print("VERIFY-D3-DRAIN-C2 10,000 members + 10,000 deferred places: runs \(runs) ms, best \(runs.min() ?? .infinity) ms")
        #expect((runs.min() ?? .infinity) <= 10.0, "\(runs)")
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    static func verifyD3DrainWait(members count: Int) async throws -> Double {
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
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        let members = { (seed: UInt64) in
            (0..<count).map { index in
                SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
            }
        }
        let extras = (0..<count).map { index in
            SyncBench.entry(String(format: "t%05d", index), GeneratedPayload.bytes(seed: 0x77_000 + UInt64(index), offset: 0, length: 400), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(members(0x21_000) + extras), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        guard case .success = await engine.registerGroup(members(0x21_000).map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(members(0x55_000) + extras), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        // A second prefetch window registers 10,000 other members while the follow is owed: each new job's place waits.
        guard case .success = await engine.registerGroup(extras.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the second prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.d3Deferred(engine, atLeast: count)) {
            await Task.yield()
        }
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = ContinuousClock()
        var span = Duration.zero
        let wait = try await SyncBench.longestWait(on: engine) {
            let start = clock.now
            await engine.releaseFollowFollowUps()
            while !Task.isCancelled, await engine.followOwed {
                await Task.yield()
            }
            span = clock.now - start
            while !Task.isCancelled, !(await SyncBench.d3Drained(engine)) {
                await Task.yield()
            }
        }
        print("VERIFY-D3-LATENCY \(count) members: the owed follow (after the apply's turn) ended \(span) after its release; admissions waited that long")
        await engine.shutdown()
        _ = await sync.value
        return wait
    }

    static func d3Deferred(_ engine: isolated SyncEngine, atLeast count: Int) -> Bool {
        engine.state.eventsAfterFollow.count >= count
    }

    /// The follow ended, its events are applied and no pump is owed.
    static func d3Drained(_ engine: isolated SyncEngine) -> Bool {
        !engine.followOwed && engine.state.eventsAfterFollow.isEmpty && !engine.state.pumpFollowUpScheduled
    }
}
