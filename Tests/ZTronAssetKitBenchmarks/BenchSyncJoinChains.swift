import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// The C2 pins of the waiting joins' chains (Stage 3 close-out cycle 21, rr21-C4; `integrate-rr21.md` R18, ruling S3-R26
/// item 9): an apply while listed joins wait for the follow appends a layer to each join's chain (`layerOwedReroutes`,
/// O(events) an apply, the layer itself shared by the joins of one stretch of the queue), a lane decision walks every
/// waiting join through its chain (`followedLane`, O(joins x layers) a call), and the drain replays each join through its
/// chain (`replayJoin` through `joinListing`, O(layers) a join). Each figure is printed with the host's load averages
/// (S3-R23).
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// C2 of two applies while 10,000 listed joins wait for an owed follow, of a lane decision over them, and of the
    /// follow's end and their drain through the two layers (`SyncBench.joinChains`): the heartbeat over the applies and
    /// over the drain, and `followedLane` timed alone inside the actor (the median of 21 calls), the best of three of
    /// each against C2, after a warm-up. The layer pass alone (the median of 5) and `followedLane` before the applies,
    /// every chain empty, are printed beside them: R18's share of the apply's turn and of the lane's walk.
    @Test("R-SYN-11: two applies while 10,000 listed joins wait for the follow, a lane decision over them, and their drain through two layers hold the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func joinChainTurns() async throws {
        _ = try await SyncBench.joinChains(members: 1_000)
        var runs: [JoinChainRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.joinChains(members: 10_000))
        }
        for run in runs {
            #expect(run.chained == 10_000 && run.layers == [2], "setup: every join waited listed and took a layer at each apply: \(run)")
            #expect(run.lane != nil, "setup: the lane's job existed: \(run)")
            #expect(run.joined == 10_000 && run.leftovers == 0, "setup: the drain joined every waiting join and left nothing behind the barrier: \(run)")
            #expect(run.violations.isEmpty, "setup: \(run.violations.prefix(3))")
        }
        let applies = runs.map(\.applies)
        let passes = runs.map(\.pass)
        let lanes = runs.compactMap(\.lane)
        let empty = runs.compactMap(\.laneEmpty)
        let drains = runs.map(\.drain)
        print("R-SYN-11 joinChainTurns at 10,000: the applies' heartbeat \(applies) ms, best \(applies.min() ?? .infinity) ms; the layer pass alone \(passes) ms; followedLane \(lanes) ms, best \(lanes.min() ?? .infinity) ms (every chain empty \(empty) ms); the drain's heartbeat \(drains) ms, best \(drains.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect((applies.min() ?? .infinity) <= Self.c2Budget, "the applies: \(applies)")
        #expect((lanes.min() ?? .infinity) <= Self.c2Budget, "followedLane: \(lanes)")
        #expect((drains.min() ?? .infinity) <= Self.c2Budget, "the drain: \(drains)")
    }
}

/// One run of `SyncBench.joinChains`.
struct JoinChainRun: CustomStringConvertible {
    /// The heartbeat's longest wait, in milliseconds, over the two applies while the joins wait.
    var applies = 0.0
    /// `layerOwedReroutes` alone over the waiting joins, inside the actor: the median of 5 calls.
    var pass = 0.0
    /// `followedLane` on a member's job while the joins wait, inside the actor: the median of 21 calls.
    var lane: Double?
    /// The same before the applies, every chain empty.
    var laneEmpty: Double?
    /// The heartbeat's longest wait from the follow's release to the drain's end.
    var drain = 0.0
    /// The joins that waited with a chain after the applies, and the lengths of their chains.
    var chained = 0
    var layers: Set<Int> = []
    /// The second window's members whose job holds its interest after the drain.
    var joined = 0
    /// What the follow barrier still held after the drain (`SyncBench.barrierLeftovers`).
    var leftovers = 0
    var violations: [String] = []
    var load = ""

    var description: String {
        "applies \(self.applies) ms, pass \(self.pass) ms, lane \(self.lane.map { "\($0)" } ?? "-") ms (empty \(self.laneEmpty.map { "\($0)" } ?? "-") ms), drain \(self.drain) ms; chained \(self.chained) with layers \(self.layers.sorted()), joined \(self.joined), leftovers \(self.leftovers), \(self.violations.count) violations; load \(self.load)"
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// `followDrainWait`'s shape with two applies while the joins wait: a prefetch group of `count` on-demand members
    /// waits `awaitingSpace` (a pruned blob's grace), v3 gives every member a new content with the follow's follow-ups
    /// held after its first turn, and a second prefetch window of `count` other members, listed by every copy, registers
    /// meanwhile, so each of its joins waits listed, with an empty chain (`addInterest`). v4 and v5, v3 with an id nobody
    /// wants changed each time, are applied while they wait, each appending a layer to every chain; the follow stays owed
    /// (its follow-ups are still held). `followedLane` on the last member's old job (which no follow turn visits before
    /// the release) is timed inside the actor before the applies and after them, the layer pass after them, and the
    /// follow is then released and drained.
    static func joinChains(members count: Int) async throws -> JoinChainRun {
        var run = JoinChainRun()
        let loadBefore = SyncBench.loadAverages()
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
            random: SeededRandom(seed: 0x12),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        // A 60 s deletion grace and no residency, as `followDrainWait`: the pruned blob keeps the members
        // `awaitingSpace`, and the clock never passes the grace here.
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
            SyncBench.entry(String(format: "t%05d", index), GeneratedPayload.bytes(seed: 0x78_000 + UInt64(index), offset: 0, length: 400), policy: .onDemand)
        }
        let old = members(0x22_000)
        // v2 prunes x: its 2,000 bytes wait for the grace.
        await source.scriptManifest([.fetched(SyncBench.manifestData(old + extras), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        let v3 = members(0x56_000) + extras
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        // The second window registers while the follow is owed: each member's join waits, listed by v3.
        guard case .success(let token) = await engine.registerGroup(extras.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the second prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.eventsWaiting(engine, atLeast: count)) {
            await Task.yield()
        }
        await SyncBench.raiseOwnedTaskPriority(engine)
        run.laneEmpty = await SyncBench.followedLaneMedian(engine, old.last?.transferID, calls: 21)
        run.applies = try await SyncBench.longestWait(on: engine) {
            for round in 4...5 {
                let filler = SyncBench.entry("zf", Data(repeating: UInt8(round), count: 16), policy: .onDemand)
                let manifest = try ValidatedManifest(entries: v3 + [filler], digest: ContentHash.sha256(of: Data("v\(round)-while-joins-wait".utf8)))
                let applied = await engine.applyAndFollow(manifest, etag: nil, eviction: nil)
                guard case .success = applied else {
                    throw SyncBenchError.incomplete("setup: v\(round) was not applied: \(applied)")
                }
            }
        }
        let chains = await SyncBench.joinChainsWaiting(engine)
        run.chained = chains.chained
        run.layers = chains.layers
        run.violations += await engine.invariantViolations()
        run.pass = await SyncBench.layerPassMedian(engine, calls: 5)
        run.lane = await SyncBench.followedLaneMedian(engine, old.last?.transferID, calls: 21)
        run.drain = try await SyncBench.longestWait(on: engine) {
            _ = await SyncBench.releaseHeldFollow(engine)
            while !Task.isCancelled, !(await SyncBench.followDrained(engine)) {
                await Task.yield()
            }
        }
        run.joined = await SyncBench.joinedJobs(engine, extras, token)
        run.leftovers = await SyncBench.barrierLeftovers(engine)
        run.violations += await engine.invariantViolations()
        await engine.shutdown()
        _ = await sync.value
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// The listed joins that wait with a chain, and the distinct lengths of their chains.
    static func joinChainsWaiting(_ engine: isolated SyncEngine) -> (chained: Int, layers: Set<Int>) {
        var chained = 0
        var layers: Set<Int> = []
        for event in engine.state.eventsAfterFollow {
            if case .join(let join) = event, let chain = join.chain {
                chained += 1
                layers.insert(chain.layers.count)
            }
        }
        return (chained, layers)
    }

    /// Times `layerOwedReroutes` alone, inside the actor, `calls` times, taking the layer each call appended off every
    /// chain again, untimed, so each chain keeps one layer per adopted copy (no batch waits here): the median, in
    /// milliseconds. Each call meets the events as an apply does, no other reference holding them.
    static func layerPassMedian(_ engine: isolated SyncEngine, calls: Int) -> Double {
        let clock = ContinuousClock()
        var spans: [Double] = []
        for _ in 0..<calls {
            let start = clock.now
            engine.layerOwedReroutes()
            spans.append(SyncBench.milliseconds(clock.now - start))
            for index in engine.state.eventsAfterFollow.indices {
                if case .join(var join) = engine.state.eventsAfterFollow[index], join.chain != nil {
                    join.chain?.layers.removeLast()
                    engine.state.eventsAfterFollow[index] = .join(join)
                }
            }
        }
        return spans.sorted()[calls / 2]
    }

    /// The `entries` whose content's job holds `token`'s interest.
    static func joinedJobs(_ engine: isolated SyncEngine, _ entries: [ManifestEntry], _ token: InterestToken) -> Int {
        entries.count { engine.state.jobs[$0.transferID]?.interests[token] != nil }
    }
}
