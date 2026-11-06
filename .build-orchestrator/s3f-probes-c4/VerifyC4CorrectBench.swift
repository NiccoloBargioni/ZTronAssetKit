import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch C2 probe (s3f close-out verification, cycle 4, correctness lens). Never committed.
///
/// PROBE-C4-SWEEP-C2: 10,000 prefetch members parked `insufficientSpace` (scaleBench, 1,000 bytes of room); with
/// `changed`, a forced sync changes every member's content and the follow's follow-ups are held (the follow owes its
/// visits, as between two of its turns at 10,000); then the ballast goes, one free-space read is adopted, and single
/// `sweepSpaceParked(.read)` turns are timed directly on the actor. Without `changed` the same turns only re-queue
/// (`spaceReadmissionTurns`' work); with it each admitted candidate is first followed (`followBeforeActing`, c8f01ca).
@Suite("VerifyC4CorrectBench", .serialized)
struct VerifyC4CorrectBench {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C4-SWEEP-C2: one space sweep turn at 10,000 parked members, with and without an owed follow", .timeLimit(.minutes(5)), arguments: [false, true, false, true])
    func sweepTurns(_ changed: Bool) async throws {
        let count = 10_000
        let bench = try await SyncBench.scaleBench(members: count, room: 1_000)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneQueued(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        var sync: Task<Void, Never>?
        if changed {
            let v2 = bench.entries.enumerated().map { index, entry in
                SyncBench.entry(entry.identifier.rawValue, GeneratedPayload.bytes(seed: 0x99_000 + UInt64(index), offset: 0, length: bench.size), policy: .onDemand)
            }
            await bench.source.scriptManifest([.fetched(SyncBench.manifestData(v2), etag: ETag(rawValue: "\"v2\""))])
            await engine.holdFollowFollowUps()
            sync = Task { _ = await engine.sync(.force) }
            while !Task.isCancelled, !(await Self.followWaiting(engine)) {
                await Task.yield()
            }
        }
        let census = await Self.census(engine)
        try bench.removeBallast()
        _ = try await engine.readFreeSpace()
        var turns: [Turn] = []
        for _ in 0..<10 {
            turns.append(await Self.timedSweep(engine))
        }
        let ms = turns.map(\.ms)
        print("PROBE-C4-SWEEP-C2 changed=\(changed) before: \(census); turns ms \(ms.map { String(format: "%.2f", $0) }); min \(String(format: "%.2f", ms.min() ?? 0)) median \(String(format: "%.2f", ms.sorted()[ms.count / 2])); parked/jobs per turn \(turns.map { "\($0.parkedBefore)->\($0.parkedAfter)/\($0.jobs)" })")
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = await sync?.value
        #expect((ms.min() ?? .infinity) <= 10.0, "PROBE-C4-SWEEP-C2 changed=\(changed): best sweep turn \(ms.min() ?? 0) ms over C2's 10 ms")
    }

    struct Turn: Sendable {
        let ms: Double
        let parkedBefore: Int
        let parkedAfter: Int
        let jobs: Int
    }

    static func followWaiting(_ engine: isolated SyncEngine) -> Bool {
        engine.state.followFollowUpWaiting
    }

    static func census(_ engine: isolated SyncEngine) -> String {
        let parked = engine.state.spaceParked.count
        let moved = engine.state.spaceParked.filter { transfer in
            engine.state.jobs[transfer].map { engine.holdsMovedID($0) } ?? false
        }.count
        return "spaceParked \(parked), holding moved ids \(moved), jobs \(engine.state.jobs.count), followOwed \(engine.followOwed), unfollowed \(engine.state.unfollowed.count)"
    }

    static func timedSweep(_ engine: isolated SyncEngine) -> Turn {
        let before = engine.state.spaceParked.count
        let clock = ContinuousClock()
        let start = clock.now
        engine.sweepSpaceParked(.read)
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return Turn(ms: ms, parkedBefore: before, parkedAfter: engine.state.spaceParked.count, jobs: engine.state.jobs.count)
    }
}

/// PROBE-C4-SWEEP2-C2: the reclaim sweep's two acting branches in one turn. 10,000 prefetch members alternating 400 and
/// 3,000 bytes are parked `awaitingSpace` (100 bytes of room, a pruned 2,000-byte blob pending reclaim). With `changed`,
/// a forced sync changes every member's content and the follow's follow-ups are held. Then the reclaim: room 2,100 and
/// nothing pending, so the `.reclaimed` sweep re-queues the 400-byte members and parks the 3,000-byte ones
/// `insufficientSpace` (512 of each per turn); with an owed follow it first follows each (c8f01ca). `direct`: the post-reap
/// read is adopted (the figures a real read returns after the reaper freed the 2,000 bytes) and single sweep turns are
/// timed on the actor; otherwise the clock passes the grace and the alarm's own reap and sweep run under the heartbeat.
@Suite("VerifyC4CorrectBench2", .serialized)
struct VerifyC4CorrectBench2 {
    struct Mode: Sendable, CustomStringConvertible {
        let changed: Bool
        let direct: Bool
        var groups = 1
        var description: String { "changed=\(self.changed) direct=\(self.direct) groups=\(self.groups)" }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C4-SWEEP2-C2: one reclaim sweep turn that re-queues and parks at 10,000, with and without an owed follow", .timeLimit(.minutes(5)), arguments: [
        Mode(changed: false, direct: true), Mode(changed: true, direct: true), Mode(changed: false, direct: true), Mode(changed: true, direct: true),
        Mode(changed: false, direct: false), Mode(changed: true, direct: false), Mode(changed: false, direct: false), Mode(changed: true, direct: false),
        Mode(changed: false, direct: false), Mode(changed: true, direct: false),
        Mode(changed: false, direct: true, groups: 2), Mode(changed: true, direct: true, groups: 2),
        Mode(changed: false, direct: true, groups: 2), Mode(changed: true, direct: true, groups: 2),
        Mode(changed: false, direct: false, groups: 2), Mode(changed: true, direct: false, groups: 2),
        Mode(changed: false, direct: false, groups: 2), Mode(changed: true, direct: false, groups: 2),
        Mode(changed: false, direct: false, groups: 2), Mode(changed: true, direct: false, groups: 2),
    ])
    func reclaimSweep(_ mode: Mode) async throws {
        let count = 10_000
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity))
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
        var policy = StoragePolicy()
        policy.minimumResidency = 0
        policy.deletionGrace = 60
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: policy,
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
            throw SyncBenchError.incomplete("v1")
        }
        let size = { (index: Int) in index % 2 == 0 ? 400 : 3_000 }
        let members = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x21_000 + UInt64(index), offset: 0, length: size(index)), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(members), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("v2")
        }
        try await store.flush(.ordered)
        let ballast = URL(fileURLWithPath: "/fake-volume/Library/Application Support/ballast")
        try await Self.leaveRoom(100, store: store, fileSystem: fileSystem, file: ballast)
        let pending = try await store.freeSpace().pendingReclaim
        guard pending == Int64(xBytes.count) else {
            throw SyncBenchError.incomplete("pending reclaim \(pending)")
        }
        await engine.refreshFreeSpace()
        for _ in 0..<mode.groups {
            // A second group over the same ids (another prefetch window over the same catalog): two interests per job.
            guard case .success = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
        }
        while !Task.isCancelled, !(await Self.allAwaiting(engine, count: count)) {
            await Task.yield()
        }
        var sync: Task<Void, Never>?
        if mode.changed {
            let v3 = (0..<count).map { index in
                SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x55_000 + UInt64(index), offset: 0, length: size(index)), policy: .onDemand)
            }
            await source.scriptManifest([.fetched(SyncBench.manifestData(v3), etag: ETag(rawValue: "\"v3\""))])
            await engine.holdFollowFollowUps()
            sync = Task { _ = await engine.sync(.force) }
            while !Task.isCancelled, !(await VerifyC4CorrectBench.followWaiting(engine)) {
                await Task.yield()
            }
        }
        try await store.flush(.ordered)
        try await Self.leaveRoom(100, store: store, fileSystem: fileSystem, file: URL(fileURLWithPath: "/fake-volume/Library/Application Support/ballast-2"))
        _ = try await engine.readFreeSpace()
        let census = await VerifyC4CorrectBench.census(engine)
        if mode.direct {
            var turns: [String] = []
            var ms: [Double] = []
            for turn in 0..<4 {
                let result = await Self.timedReclaimSweep(engine, reclaimed: Int64(xBytes.count), adopt: turn == 0)
                ms.append(result.ms)
                turns.append(result.summary)
            }
            print("PROBE-C4-SWEEP2-C2 \(mode) before: \(census); turns ms \(ms.map { String(format: "%.2f", $0) }); \(turns)")
            #expect((ms.first ?? .infinity) <= 10.0, "PROBE-C4-SWEEP2-C2 \(mode): first reclaim sweep turn \(ms.first ?? 0) ms over C2's 10 ms")
        } else {
            let wait = try await SyncBench.longestWait(on: engine) {
                time.advance(by: 61)
                while !Task.isCancelled, !(await Self.noneAwaiting(engine)) {
                    await Task.yield()
                }
            }
            let after = await VerifyC4CorrectBench.census(engine)
            print("PROBE-C4-SWEEP2-C2 \(mode) before: \(census); heartbeat longest wait \(String(format: "%.2f", wait)) ms; after: \(after)")
            #expect(wait <= 10.0, "PROBE-C4-SWEEP2-C2 \(mode): heartbeat longest wait \(wait) ms over C2's 10 ms")
        }
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = await sync?.value
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func leaveRoom(_ room: Int64, store: AssetStore, fileSystem: FakeFileSystem, file: URL) async throws {
        let free = try await store.freeSpace()
        let excess = free.volumeOpportunistic - free.reserveBytes - room
        guard excess >= 0 else {
            throw SyncBenchError.incomplete("room above the reserve already below \(room): \(free)")
        }
        try fileSystem.write(Data(repeating: 1, count: Int(excess)), to: file, mode: .truncate)
    }

    static func allAwaiting(_ engine: isolated SyncEngine, count: Int) -> Bool {
        engine.state.jobs.count == count && engine.state.jobs.values.allSatisfy { $0.state == .blocked(.awaitingSpace) }
    }

    static func noneAwaiting(_ engine: isolated SyncEngine) -> Bool {
        !engine.state.spaceParked.contains { engine.state.jobs[$0]?.state == .blocked(.awaitingSpace) } && engine.state.spaceSweepFollowUp == nil
    }

    static func timedReclaimSweep(_ engine: isolated SyncEngine, reclaimed: Int64, adopt: Bool) -> (ms: Double, summary: String) {
        if adopt, let space = engine.state.freeSpace {
            // The read the alarm adopts after the reaper freed the pending bytes.
            engine.state.freeSpace = FreeSpace(
                volumeImportant: space.volumeImportant + reclaimed,
                volumeOpportunistic: space.volumeOpportunistic + reclaimed,
                usedBytes: space.usedBytes,
                pendingReclaim: 0,
                budgetBytes: space.budgetBytes,
                reserveBytes: space.reserveBytes
            )
        }
        let awaiting = engine.state.spaceParked.filter { engine.state.jobs[$0]?.state == .blocked(.awaitingSpace) }.count
        let jobs = engine.state.jobs.count
        let clock = ContinuousClock()
        let start = clock.now
        engine.sweepSpaceParked(.reclaimed)
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        let awaitingAfter = engine.state.spaceParked.filter { engine.state.jobs[$0]?.state == .blocked(.awaitingSpace) }.count
        let insufficient = engine.state.spaceParked.filter { engine.state.jobs[$0]?.state == .blocked(.insufficientSpace) }.count
        return (ms, "awaiting \(awaiting)->\(awaitingAfter), insufficient \(insufficient), jobs \(jobs)->\(engine.state.jobs.count)")
    }
}
