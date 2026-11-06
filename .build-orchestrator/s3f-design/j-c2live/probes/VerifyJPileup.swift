import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport
@testable import ZTronAssetSync

/// Judge c2live (scratch, never committed): D3's drain probe made design-agnostic, the end-of-follow pile-up. 10,000
/// prefetch members wait `awaitingSpace`; an apply changes every member and its follow is held; a second 10,000-member
/// group registers while the follow is owed. The window releases the follow and runs until the follow, every deferred
/// event or decision and every pump follow-up is over (`jSettled`). D3 drains 512 deferred places per turn and pumps
/// nothing during the follow; D1 holds the pump's ledger-judged starts; D2 and the base admit as before.
@Suite("VerifyJPileup", .serialized)
struct VerifyJPileup {
    @Test("VERIFY-J-PILEUP: the follow's turns and the end-of-follow pile-up hold the actor at most C2's 10 ms per turn", .timeLimit(.minutes(5)))
    @available(macOS 15.0, iOS 18.0, *)
    func pileupTurns() async throws {
        _ = try await SyncBench.verifyJPileupWait(members: 1_000)
        var runs: [Double] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.verifyJPileupWait(members: 10_000))
        }
        print("VERIFY-J-PILEUP 10,000 members + 10,000 joined during the follow: runs \(runs) ms, best \(runs.min() ?? .infinity) ms")
        #expect((runs.min() ?? .infinity) <= 10.0, "\(runs)")
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    static func verifyJPileupWait(members count: Int) async throws -> Double {
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
        while !Task.isCancelled, !(await SyncBench.jJobCount(engine, atLeast: 2 * count)) {
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
            while !Task.isCancelled, !(await SyncBench.jSettled(engine)) {
                await Task.yield()
            }
        }
        print("VERIFY-J-PILEUP-LATENCY \(count) members: the owed follow (after the apply's turn) ended \(span) after its release; admissions waited that long")
        let stranded = await SyncBench.jQueued(engine)
        print("VERIFY-J-PILEUP \(count): jobs still queued after the window: \(stranded)")
        guard stranded == 0 else {
            throw SyncBenchError.incomplete("\(stranded) jobs are still queued after the follow and its pile-up settled")
        }
        await engine.shutdown()
        _ = await sync.value
        return wait
    }

    static func jJobCount(_ engine: isolated SyncEngine, atLeast count: Int) -> Bool {
        engine.state.jobs.count >= count
    }

    static func jQueued(_ engine: isolated SyncEngine) -> Int {
        engine.state.jobs.values.filter { $0.state == .queued }.count
    }
}
