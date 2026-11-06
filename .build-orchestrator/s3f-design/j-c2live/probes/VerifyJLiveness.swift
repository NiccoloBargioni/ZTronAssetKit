import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport
@testable import ZTronAssetSync

/// Judge c2live liveness attack (scratch, never committed). While a multi-turn follow is owed (its follow-ups held): a
/// second prefetch group registers, user waiters join parked members (moved and unmoved ids), a stream of free-space
/// reads asks for `.read` sweeps, the grace ends (a reclaim and its sweep), a later apply restarts the follow's visits
/// (`followApplied` again), and more reads arrive. Then either the follow is released and everything must settle within
/// a wall-clock bound with clean invariants and no member left `awaitingSpace`, or the engine shuts down while all of it
/// is owed and every waiter, the sync and shutdown must return.
@Suite("VerifyJLiveness", .serialized)
struct VerifyJLiveness {
    @Test("LIVE-J-STREAM: a stream of events during an owed follow settles once the follow is released", .timeLimit(.minutes(5)))
    @available(macOS 15.0, iOS 18.0, *)
    func streamSettles() async throws {
        for _ in 0..<2 {
            let summary = try await SyncBench.jStream(members: 4_000, shutdownWhileOwed: false)
            print("LIVE-J-STREAM release: \(summary)")
        }
    }

    @Test("LIVE-J-SHUTDOWN: shutdown while the follow, its deferred events and sweeps are owed answers everything", .timeLimit(.minutes(5)))
    @available(macOS 15.0, iOS 18.0, *)
    func shutdownEnds() async throws {
        for _ in 0..<2 {
            let summary = try await SyncBench.jStream(members: 4_000, shutdownWhileOwed: true)
            print("LIVE-J-SHUTDOWN: \(summary)")
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    static func jStream(members count: Int, shutdownWhileOwed: Bool) async throws -> String {
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
        let old = members(0x21_000)
        guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        let changedNew = members(0x55_000)
        let v3 = (0..<count).map { $0 % 2 == 0 ? changedNew[$0] : old[$0] }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + extras), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast-2")
        _ = try await engine.readFreeSpace()
        guard case .success = await engine.registerGroup(extras.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the second prefetch group was refused")
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for index in stride(from: 0, to: count, by: 25) {
            let id = old[index].identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(60)
        for _ in 0..<5 {
            await engine.refreshFreeSpace()
        }
        time.advance(by: 61)
        while !(await SyncBench.jReclaimRead(engine)) {
            guard clock.now < deadline else {
                throw SyncBenchError.incomplete("the reclaim's store work did not end")
            }
            await Task.yield()
        }
        let owedBefore = await SyncBench.jOwed(engine)
        await SyncBench.jRefollow(engine)
        for _ in 0..<3 {
            await engine.refreshFreeSpace()
        }
        if shutdownWhileOwed {
            let owed = await SyncBench.jOwed(engine)
            await engine.shutdown()
            var answered = 0
            for waiter in waiters {
                _ = await waiter.value
                answered += 1
            }
            _ = await sync.value
            let left = await SyncBench.jLeft(engine)
            guard left.waiters == 0 else {
                throw SyncBenchError.incomplete("\(left.waiters) waiters left after shutdown")
            }
            return "owed before the refollow \(owedBefore), at shutdown \(owed); answered \(answered) of \(waiters.count) waiters; left \(left)"
        }
        let released = clock.now
        await engine.releaseFollowFollowUps()
        while !(await SyncBench.jSettled(engine)) {
            guard clock.now < deadline else {
                let owed = await SyncBench.jOwed(engine)
                throw SyncBenchError.incomplete("not settled 60 s after the release: \(owed)")
            }
            await Task.yield()
        }
        let settled = clock.now - released
        let violations = await engine.invariantViolations()
        let awaiting = await SyncBench.awaitingSpace(engine)
        let queued = await SyncBench.jQueued(engine)
        let owedAfter = await SyncBench.jOwed(engine)
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        #expect(awaiting == 0, "\(awaiting) members still wait awaitingSpace")
        await engine.shutdown()
        for waiter in waiters {
            _ = await waiter.value
        }
        _ = await sync.value
        return "owed before the refollow \(owedBefore); settled \(settled) after the release; after: \(owedAfter); awaitingSpace \(awaiting); queued \(queued); violations \(violations.count)"
    }

    static func jRefollow(_ engine: isolated SyncEngine) {
        engine.followApplied(from: engine.state.applied)
    }

    static func jOwed(_ engine: isolated SyncEngine) -> String {
        "followOwed \(engine.followOwed) next \(engine.state.followNext)/\(engine.state.followOrder.count) scans \(engine.state.followScans.count) sweepFollowUp \(engine.state.spaceSweepFollowUp != nil) pumpWaits \(engine.state.pumpWaitsForFollow) spaceParked \(engine.state.spaceParked.count) jobs \(engine.state.jobs.count)"
    }

    static func jLeft(_ engine: isolated SyncEngine) -> (waiters: Int, jobs: Int) {
        (engine.state.waiters.count, engine.state.jobs.count)
    }
}
