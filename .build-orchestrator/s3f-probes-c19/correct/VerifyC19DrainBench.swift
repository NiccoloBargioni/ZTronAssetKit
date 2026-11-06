import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// Scratch release probe (s3f close-out verification, cycle 19, correctness lens). Never committed.
///
/// PROBE-C19C-DRAIN-C2: `slots` jobs, each shared by `perJob` prefetch members (one group), download; v3 changes only
/// fillers (the follow is owed, its follow-ups held); every attempt times out (a retry: the interests stay), so each
/// verdict waits; v4 gives every member a content of its own. The follow's held turns are then released one at a time
/// and each is timed inside the actor: the follow's last turn runs the drain's first batch, whose `slots` verdicts each
/// end in `followAfterVerdict`, a visit of `perJob` ids within a fresh `followIDsPerTurn` budget.
@Suite("VerifyC19DrainBench", .serialized)
struct VerifyC19DrainBench {
    struct DrainRun: CustomStringConvertible {
        var turns: [Double] = []
        var moved: [Int] = []
        var drainTurn: Double = -1
        var drainMoved = -1
        var waitingBefore = 0
        var heldBefore = 0
        var wait: Double = 0

        var description: String {
            "drain turn \(self.drainTurn) ms moving \(self.drainMoved) ids; verdicts waiting \(self.waitingBefore), ids held \(self.heldBefore); \(self.turns.count) turns, longest \(self.turns.max() ?? 0) ms; heartbeat \(self.wait) ms; moved per turn \(self.moved)"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func held(_ engine: isolated SyncEngine, _ jobs: [TransferID]) -> (ids: Int, waiting: Int, downloading: Int) {
        let ids = jobs.reduce(0) { $0 + (engine.state.jobs[$1]?.assets.count ?? 0) }
        let waiting = jobs.filter { engine.state.verdictsAfterFollow[$0] != nil }.count
        let downloading = jobs.filter { engine.state.jobs[$0]?.state == .downloading }.count
        return (ids, waiting, downloading)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func groupHeld(_ engine: isolated SyncEngine, _ jobs: [TransferID], perJob: Int) -> Bool {
        jobs.allSatisfy { engine.state.jobs[$0]?.state == .downloading && engine.state.jobs[$0]?.assets.count == perJob }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func apply(_ engine: isolated SyncEngine, _ entries: [ManifestEntry], tag: String) async throws -> Bool {
        let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data(tag.utf8)))
        engine.holdFollowFollowUps()
        let applied = await engine.applyAndFollow(manifest, etag: nil, eviction: nil)
        return (try? applied.get()) != nil
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func owed(_ engine: isolated SyncEngine) -> Bool {
        engine.followOwed
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func run(slots: Int, perJob: Int) async throws -> DrainRun {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (64 << 20)
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
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let tuning = SyncTuning(maxConcurrentTransfers: slots, reservedInteractiveSlots: 0)
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: tuning))
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        let contents: [Data] = (0..<slots).map { GeneratedPayload.bytes(seed: 0x77_000 + UInt64($0), offset: 0, length: 16) }
        var members: [ManifestEntry] = []
        var own: [ManifestEntry] = []
        for k in 0..<slots {
            for m in 0..<perJob {
                let name = String(format: "s%02d%05d", k, m)
                members.append(SyncBench.entry(name, contents[k], policy: .onDemand))
                own.append(SyncBench.entry(name, GeneratedPayload.bytes(seed: 0x88_000 + UInt64(k * 100_000 + m), offset: 0, length: 16), policy: .onDemand))
            }
        }
        let jobs = (0..<slots).map { members[$0 * perJob].transferID }
        let fillers = (0..<(SyncEngine.followFormatsPerTurn + 52)).map { SyncBench.entry(String(format: "f%05d", $0), GeneratedPayload.bytes(seed: 0x51_000 + UInt64($0), offset: 0, length: 16), policy: .onDemand) }
        let fillers3 = (0..<(SyncEngine.followFormatsPerTurn + 52)).map { SyncBench.entry(String(format: "f%05d", $0), GeneratedPayload.bytes(seed: 0x52_000 + UInt64($0), offset: 0, length: 16), policy: .onDemand) }
        let later = (0..<(SyncEngine.followFormatsPerTurn + 52)).map { SyncBench.entry(String(format: "zzz%05d", $0), GeneratedPayload.bytes(seed: 0x53_000 + UInt64($0), offset: 0, length: 16), policy: .onDemand) }
        let later3 = (0..<(SyncEngine.followFormatsPerTurn + 52)).map { SyncBench.entry(String(format: "zzz%05d", $0), GeneratedPayload.bytes(seed: 0x54_000 + UInt64($0), offset: 0, length: 16), policy: .onDemand) }
        let later4 = (0..<(SyncEngine.followFormatsPerTurn + 52)).map { SyncBench.entry(String(format: "zzz%05d", $0), GeneratedPayload.bytes(seed: 0x55_000 + UInt64($0), offset: 0, length: 16), policy: .onDemand) }
        await source.scriptManifest([.fetched(SyncBench.manifestData(fillers + members + later), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await store.flush(.ordered)
        let timeout = TransferError.transient(.timedOut, retryAfter: nil)
        for k in 0..<slots {
            await source.script(jobs[k], [.hold, .fail(timeout), .stage(contents[k])])
        }
        guard case .success = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        var spins = 0
        while !Task.isCancelled, !(await VerifyC19DrainBench.groupHeld(engine, jobs, perJob: perJob)) {
            spins += 1
            if spins > 2_000_000 {
                let state = await VerifyC19DrainBench.held(engine, jobs)
                throw SyncBenchError.incomplete("setup: the jobs never all downloaded: \(state)")
            }
            await Task.yield()
        }
        guard try await VerifyC19DrainBench.apply(engine, fillers3 + members + later3, tag: "v3-drain-\(slots)-\(perJob)"), await VerifyC19DrainBench.owed(engine) else {
            throw SyncBenchError.incomplete("setup: v3's follow is not owed")
        }
        for transfer in jobs {
            await source.release(transfer, with: .progress(received: 0, expected: nil))
        }
        spins = 0
        while !Task.isCancelled, (await VerifyC19DrainBench.held(engine, jobs)).waiting < slots {
            spins += 1
            if spins > 2_000_000 {
                let state = await VerifyC19DrainBench.held(engine, jobs)
                throw SyncBenchError.incomplete("setup: the verdicts never all waited: \(state)")
            }
            await Task.yield()
        }
        guard try await VerifyC19DrainBench.apply(engine, fillers3 + own + later4, tag: "v4-drain-\(slots)-\(perJob)") else {
            throw SyncBenchError.incomplete("setup: v4 was refused")
        }
        var run = DrainRun()
        let before = await VerifyC19DrainBench.held(engine, jobs)
        run.waitingBefore = before.waiting
        run.heldBefore = before.ids
        await SyncBench.raiseOwnedTaskPriority(engine)
        var turns: [Double] = []
        var moved: [Int] = []
        var heldNow = before.ids
        var waitingNow = before.waiting
        run.wait = try await SyncBench.longestWait(on: engine) {
            while !Task.isCancelled, !(await SyncBench.followDrained(engine)) {
                if let turn = await SyncBench.releaseOneHeldTurn(engine) {
                    turns.append(turn)
                    let now = await VerifyC19DrainBench.held(engine, jobs)
                    moved.append(heldNow - now.ids)
                    if waitingNow > 0, now.waiting == 0, run.drainTurn < 0 {
                        run.drainTurn = turn
                        run.drainMoved = heldNow - now.ids
                    }
                    heldNow = now.ids
                    waitingNow = now.waiting
                } else {
                    await Task.yield()
                }
            }
        }
        run.turns = turns
        run.moved = moved
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = later
        return run
    }

    @Test("PROBE-C19C-DRAIN-C2", .timeLimit(.minutes(10)), arguments: [4, 16])
    @available(macOS 15.0, iOS 18.0, *)
    func drainC2(_ slots: Int) async throws {
        let warm = try await VerifyC19DrainBench.run(slots: slots, perJob: 50)
        print("PROBE-C19C-DRAIN-C2 warm-up slots \(slots) perJob 50: \(warm)")
        var runs: [DrainRun] = []
        for _ in 0..<3 {
            runs.append(try await VerifyC19DrainBench.run(slots: slots, perJob: 500))
        }
        let drains = runs.map(\.drainTurn)
        print("PROBE-C19C-DRAIN-C2 slots \(slots) perJob 500 (\(slots * 500) ids): drain turns \(drains) ms, best \(drains.min() ?? -1); runs \(runs)")
        for run in runs {
            #expect(run.waitingBefore == slots && run.heldBefore == slots * 500, "setup: every verdict waits and every id is on its job: \(run)")
        }
        #expect((drains.min() ?? .infinity) <= 10.0, "PROBE-C19C-DRAIN-C2: the drain's turn holds the actor at most C2's 10 ms: \(drains)")
    }
}
