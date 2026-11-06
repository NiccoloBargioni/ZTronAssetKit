import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// Scratch release probe (s3f close-out verification, cycle 20, correctness lens). Never committed.
///
/// PROBE-C21C-C20SHAPE-SUPERSEDE-C2: `SyncBench.concentration(.publication)`'s shape (10,000 members converge on O's content
/// during an owed follow, O's publication held at its first store unit), then, as `timeCommit(.movedAway)` does, v4 maps
/// every member to D (one job, held) while the publication waits at the store, but v4 also gives O's own id a content of
/// its own (E), so no id wants O's content any more: the store refuses the publication (`.superseded`), and the
/// engine's `publicationFailed` re-routes every interest of O's job in one turn (`supersede`). The heartbeat's longest
/// wait from the publication's release until O's job is gone, best of three. The draft's C2 inventory row "`supersede`
/// of a superseded publication | O(N) re-routes in one turn | no figure".
@Suite("VerifyC21CorrectSupersede", .serialized)
struct VerifyC21CorrectSupersede {
    struct Run: CustomStringConvertible {
        var window: Double = 0
        var gone = false
        var onD = 0
        var onE = 0
        var oAnswer = ""
        var turns: [Double] = []

        var description: String {
            "supersede window \(self.window) ms (O gone \(self.gone)); D holds \(self.onD), E holds \(self.onE); o's waiter \(self.oAnswer); follow turns longest \(self.turns.max() ?? 0) ms"
        }
    }

    static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        return n == 3 ? String(format: "{ %.2f %.2f %.2f }", loads[0], loads[1], loads[2]) : "?"
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func run(members count: Int) async throws -> Run {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: bulk,
            time: time,
            random: SeededRandom(seed: 0x12),
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
        let oBytes = Data(repeating: 0x6F, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let old = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x21_000 + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(old + [o]), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        await source.script(o.transferID, [.hold, .stage(oBytes)])
        let waiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.othersAwaitingSpace(engine, count: count, besides: o.transferID)) {
            await Task.yield()
        }
        let v3 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), oBytes, policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + [o]), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        await SyncBench.raiseOwnedTaskPriority(engine)
        var run = Run()
        await bulk.setHolding(true)
        await source.release(o.transferID, with: .progress(received: 0, expected: nil))
        while !Task.isCancelled, !(await SyncBench.leftDownloading(engine, o.transferID)) {
            await Task.yield()
        }
        while !Task.isCancelled, await SyncBench.concentrating(engine, o.transferID, count: count + 1) {
            if let turn = await SyncBench.releaseOneHeldTurn(engine) {
                run.turns.append(turn)
            } else {
                await Task.yield()
            }
        }
        await bulk.waitForHeldUnits(atLeast: 1)
        await engine.releaseFollowFollowUps()
        while !Task.isCancelled, await SyncBench.barrierUp(engine) {
            await Task.yield()
        }
        guard let unit = await bulk.heldUnits.first else {
            throw SyncBenchError.incomplete("O's publication is not held at the store")
        }
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: 2)
                for other in await bulk.heldUnits where other != unit {
                    await bulk.release(other)
                }
            }
        }
        let dBytes = Data(repeating: 0x64, count: 16)
        let eBytes = Data(repeating: 0x65, count: 17)
        let v4 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), dBytes, policy: .onDemand)
        }
        let d = v4[0]
        let oMoved = SyncBench.entry("o", eBytes, policy: .onDemand)
        await source.script(d.transferID, [.hold])
        await source.script(oMoved.transferID, [.hold])
        await source.scriptManifest([.fetched(SyncBench.manifestData(v4 + [oMoved]), etag: ETag(rawValue: "\"v4s\""))])
        _ = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.appliedAndFollowed(engine, etag: "\"v4s\"")) {
            await Task.yield()
        }
        releaser.cancel()
        _ = await releaser.value
        run.window = try await SyncBench.longestWait(on: engine) {
            await bulk.setHolding(false)
            await bulk.releaseAll()
            while !Task.isCancelled, await SyncBench.jobExists(engine, o.transferID) {
                await bulk.releaseAll()
                await Task.yield()
            }
        }
        run.gone = !(await SyncBench.jobExists(engine, o.transferID))
        run.onD = await SyncBench.inbound(engine, d.transferID).ids
        run.onE = await SyncBench.inbound(engine, oMoved.transferID).ids
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = await sync.value
        run.oAnswer = "\(await waiter.value)"
        return run
    }

    @Test("PROBE-C21C-C20SHAPE-SUPERSEDE-C2", .timeLimit(.minutes(40)))
    @available(macOS 15.0, iOS 18.0, *)
    func supersededPublication() async throws {
        let warm = try await Self.run(members: 1_000)
        print("PROBE-C21C-C20SHAPE-SUPERSEDE-C2 warm-up 1,000: \(warm)")
        var runs: [Run] = []
        for index in 0..<3 {
            let run = try await Self.run(members: 10_000)
            print("PROBE-C21C-C20SHAPE-SUPERSEDE-C2 10,000 run \(index): \(run); load \(Self.load())")
            runs.append(run)
        }
        let windows = runs.map(\.window)
        print("PROBE-C21C-C20SHAPE-SUPERSEDE-C2 10,000 members: supersede windows \(windows) ms, best \(windows.min() ?? -1) ms; runs \(runs)")
        for run in runs {
            #expect(run.gone && run.onD == 10_000 && run.onE == 1, "setup: O's publication was superseded and every interest re-routed: \(run)")
        }
        #expect((windows.min() ?? .infinity) <= ZTronAssetKitBenchmarks.SyncBenchmarks.c2Budget, "PROBE-C21C-C20SHAPE-SUPERSEDE-C2: the superseded publication's turn at most C2's 10 ms: \(windows)")
    }
}
