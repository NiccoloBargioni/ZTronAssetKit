import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport
@testable import ZTronAssetSync

/// Design probe (s3f structural design D1 "defer"); never committed as is. VERIFY-C8-C2-MIXED and the committed
/// `reclaimDuringFollowTurns` with the measured window extended for D1: a reclaim while the follow is owed asks for a sweep
/// that waits for the follow's end, so the window holds the reclaim's turn, the follow's remaining turns (released inside
/// the window), the turn that takes the deferred sweep, and the pump turns that gate the jobs the follow created, until
/// no member waits `awaitingSpace`. `changeEvery` 20 is the cycle-8 mixed shape (about 244 holders owed), 1 the committed
/// benchmark's (every member changed). Also prints the wall time from the follow's release to the end of the deferred
/// decisions: the window in which a start the ledger judges waits (user waiters' latency, D1).
@Suite("VerifyDC2Probe", .serialized)
struct VerifyDC2Probe {
    @Test("VERIFY-D-C2: reclaim during an owed follow, follow released, deferred sweep, 10,000 members", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func deferredSweepTurns() async throws {
        _ = try await SyncBench.verifyDDeferredSweepWait(members: 1_000, handles: 1, changeEvery: 2)
        for changeEvery in [20, 1] {
            for handles in [1, 2] {
                var runs: [Double] = []
                var latencies: [Double] = []
                for _ in 0..<3 {
                    let (wait, latency) = try await SyncBench.verifyDDeferredSweepWait(members: 10_000, handles: handles, changeEvery: changeEvery)
                    runs.append(wait)
                    latencies.append(latency)
                }
                print("VERIFY-D-C2 10,000 members, changeEvery \(changeEvery), \(handles) handle(s): runs \(runs) ms, best \(runs.min() ?? .infinity) ms; follow+deferred wall \(latencies) ms")
                #expect((runs.min() ?? .infinity) <= 10.0, "changeEvery \(changeEvery), \(handles) handle(s): \(runs)")
            }
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    static func verifyDDeferredSweepWait(members count: Int, handles: Int, changeEvery: Int) async throws -> (Double, Double) {
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
        // A 60 s deletion grace and no residency: the pruned blob is reclaimed when the clock passes the grace.
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
        // v2 prunes x: its 2,000 bytes wait for the grace.
        await source.scriptManifest([.fetched(SyncBench.manifestData(members(0x21_000)), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        guard try await store.freeSpace().pendingReclaim == Int64(xBytes.count) else {
            throw SyncBenchError.incomplete("x's bytes do not wait for the reclaim")
        }
        await engine.refreshFreeSpace()
        let old = members(0x21_000)
        for _ in 0..<handles {
            // A second handle over the same ids (another prefetch window over the same catalog): two interests per job.
            guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        let changedOld = members(0x21_000)
        let changedNew = members(0x55_000)
        let v3 = (0..<count).map { $0 % changeEvery == 0 ? changedNew[$0] : changedOld[$0] }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        // The apply's index commit may have moved the room: 100 bytes again, with a second ballast.
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast-2")
        _ = try await engine.readFreeSpace()
        let (owedHolders, parked) = await SyncBench.verifyC8Holders(engine)
        print("VERIFY-D-C2 setup: followOwed holders \(owedHolders), space-parked \(parked), changeEvery \(changeEvery), handles \(handles)")
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = ContinuousClock()
        var latency = Duration.zero
        let wait = try await SyncBench.longestWait(on: engine) {
            time.advance(by: 61)
            while !Task.isCancelled, !(await SyncBench.verifyDReclaimRead(engine)) {
                await Task.yield()
            }
            let released = clock.now
            await engine.releaseFollowFollowUps()
            while !Task.isCancelled, !(await SyncBench.verifyDSettled(engine)) {
                await Task.yield()
            }
            latency = clock.now - released
        }
        let awaiting = await SyncBench.awaitingSpace(engine)
        await engine.shutdown()
        _ = await sync.value
        guard awaiting == 0 else {
            throw SyncBenchError.incomplete("\(awaiting) members still wait for space after the deferred sweeps")
        }
        let ms = Double(latency.components.seconds) * 1_000 + Double(latency.components.attoseconds) / 1e15
        return (wait, ms)
    }

    /// The alarm's store work is over and its read after the reclaim adopted.
    static func verifyDReclaimRead(_ engine: isolated SyncEngine) -> Bool {
        engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0
    }

    /// The follow, the decisions it deferred, the sweeps they owe and the pump's follow-ups are all over.
    static func verifyDSettled(_ engine: isolated SyncEngine) -> Bool {
        !engine.followOwed && !engine.spaceDecisionsOwed && !engine.state.spaceDecisionsTurnScheduled && engine.state.spaceSweepFollowUp == nil
            && !engine.state.pumpFollowUpScheduled && !engine.state.followFollowUpScheduled
    }

    /// The space-parked jobs holding a moved id, and the space-parked jobs.
    static func verifyC8Holders(_ engine: isolated SyncEngine) -> (Int, Int) {
        (engine.state.spaceParked.filter { engine.state.jobs[$0].map { engine.holdsMovedID($0) } ?? false }.count, engine.state.spaceParked.count)
    }
}
