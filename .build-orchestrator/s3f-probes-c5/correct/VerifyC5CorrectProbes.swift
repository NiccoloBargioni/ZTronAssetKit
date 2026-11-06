import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 5, correctness lens). Never committed.
///
/// PROBE-C5-SWEEP-TURNS: `count` prefetch members alternating 400 and 3,000 bytes (`handles` prefetch handles over the
/// same ids) wait `awaitingSpace` for a pruned 2,000-byte blob with 100 bytes of room; a forced sync changes every
/// member's content and the follow's follow-ups are held after its first turn (the follow owes its visits). The space
/// sweep's follow-ups are held. The deletion grace ends: the alarm reaps the blob and runs its `.reclaimed` sweep (the
/// first turn, counted, not timed). Every later sweep turn is then run directly on the actor (`releaseSpaceSweepFollowUps`
/// re-arming the hold in the same turn), timed with `ContinuousClock`, and the jobs it followed are counted (jobs that
/// hold a moved id before minus after). Requirement: every sweep turn follows at most `followsPerTurn` jobs and takes at
/// most C2's 10 ms; at the end every member left `awaitingSpace` and holds its new content.
@Suite("VerifyC5CorrectProbes", .serialized)
struct VerifyC5CorrectProbes {
    struct Mode: Sendable, CustomStringConvertible {
        let count: Int
        let handles: Int
        var description: String { "count=\(self.count) handles=\(self.handles)" }
    }

    struct Turn: Sendable {
        let ms: Double
        let followed: Int
        let parkedAfter: Int
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C5-SWEEP-TURNS: every reclaim sweep turn during an owed follow follows at most followsPerTurn jobs within C2", .timeLimit(.minutes(5)), arguments: [
        Mode(count: 1_000, handles: 1),
        Mode(count: 10_000, handles: 1),
        Mode(count: 10_000, handles: 2),
        Mode(count: 10_000, handles: 3),
    ])
    func sweepTurns(_ mode: Mode) async throws {
        let count = mode.count
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
            random: SeededRandom(seed: 0xC5),
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
        #expect(await engine.sync(.force).isComplete)
        let members = { (seed: UInt64) in
            (0..<count).map { index in
                SyncBench.entry(String(format: "p%05d", index), GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
            }
        }
        let old = members(0xC5_000)
        await source.scriptManifest([.fetched(SyncBench.manifestData(old), etag: ETag(rawValue: "\"v2\""))])
        #expect(await engine.sync(.force).isComplete)
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        #expect(try await store.freeSpace().pendingReclaim == Int64(xBytes.count))
        await engine.refreshFreeSpace()
        for _ in 0..<mode.handles {
            guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("group refused")
            }
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        let new = members(0xC5_900)
        await source.scriptManifest([.fetched(SyncBench.manifestData(new), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast-2")
        _ = try await engine.readFreeSpace()
        await Self.holdSweeps(engine)
        let owedBefore = await Self.holdingMoved(engine)
        time.advance(by: 61)
        while !Task.isCancelled, !(await Self.firstSweepDone(engine)) {
            await Task.yield()
        }
        let owedAfterFirst = await Self.holdingMoved(engine)
        var turns: [Turn] = []
        while !Task.isCancelled, await Self.sweepOwed(engine) {
            turns.append(await Self.timedSweep(engine))
            while !Task.isCancelled, !(await Self.sweepSettled(engine)) {
                await Task.yield()
            }
        }
        let awaiting = await SyncBench.awaitingSpace(engine)
        let firstFollowed = owedBefore - owedAfterFirst
        let ms = turns.map(\.ms)
        print("PROBE-C5-SWEEP-TURNS \(mode): owed before \(owedBefore); first (alarm) turn followed \(firstFollowed); follow-up turns \(turns.count); followed per turn \(turns.map(\.followed)); ms \(ms.map { String(format: "%.2f", $0) }); max \(String(format: "%.2f", ms.max() ?? 0)) median \(String(format: "%.2f", ms.isEmpty ? 0 : ms.sorted()[ms.count / 2])); awaiting after \(awaiting)")
        await engine.releaseFollowFollowUps()
        let outcome = await sync.value
        let moved = await Self.notOnNewContent(engine, new)
        let violations = await Self.violations(engine)
        await engine.shutdown()
        #expect(outcome.isComplete, "\(outcome)")
        #expect(firstFollowed <= SyncEngine.followsPerTurn, "\(mode): the alarm's sweep turn followed \(firstFollowed) jobs")
        #expect(turns.allSatisfy { $0.followed <= SyncEngine.followsPerTurn }, "\(mode): a follow-up sweep turn followed \(turns.map(\.followed).max() ?? 0) jobs")
        #expect((ms.max() ?? 0) <= 10.0, "\(mode): the longest sweep turn took \(ms.max() ?? 0) ms")
        #expect(awaiting == 0, "\(mode): \(awaiting) members still wait for space")
        #expect(moved == 0, "\(mode): \(moved) members are not on their new content")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
    }

    static func holdSweeps(_ engine: isolated SyncEngine) {
        engine.holdSpaceSweepFollowUps()
    }

    static func holdingMoved(_ engine: isolated SyncEngine) -> Int {
        engine.state.jobs.values.filter { engine.holdsMovedID($0) }.count
    }

    /// The alarm's work is over, its read adopted the reclaim, and its sweep either finished or owes a (held) follow-up.
    static func firstSweepDone(_ engine: isolated SyncEngine) -> Bool {
        engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0
            && (engine.state.spaceSweepFollowUpWaiting || engine.state.spaceSweepFollowUp == nil)
    }

    static func sweepOwed(_ engine: isolated SyncEngine) -> Bool {
        engine.state.spaceSweepFollowUpWaiting && engine.state.spaceSweepFollowUp != nil
    }

    static func sweepSettled(_ engine: isolated SyncEngine) -> Bool {
        engine.state.spaceSweepFollowUpWaiting || engine.state.spaceSweepFollowUp == nil
    }

    /// One follow-up sweep turn run directly: the hold is lifted, the owed sweep runs in this turn (as its owned task's
    /// turn would), and the hold is re-armed before the turn ends so its own follow-up waits again.
    static func timedSweep(_ engine: isolated SyncEngine) -> Turn {
        let before = Self.holdingMoved(engine)
        let clock = ContinuousClock()
        let start = clock.now
        engine.releaseSpaceSweepFollowUps()
        let elapsed = clock.now - start
        engine.holdSpaceSweepFollowUps()
        let after = Self.holdingMoved(engine)
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return Turn(ms: ms, followed: before - after, parkedAfter: engine.state.spaceParked.count)
    }

    static func notOnNewContent(_ engine: isolated SyncEngine, _ new: [ManifestEntry]) -> Int {
        new.filter { entry in
            guard let job = engine.state.jobs[entry.transferID] else {
                // A member whose new content was answered (no job) is not counted as stuck on the old one.
                return engine.state.jobs.values.contains { $0.assets.contains(entry.identifier) }
            }
            return !job.assets.contains(entry.identifier)
        }.count
    }

    static func violations(_ engine: isolated SyncEngine) -> [String] {
        engine.invariantViolations().map { "\($0)" }
    }
}

/// PROBE-C5-SWEEP-MAX: one follow-up sweep turn at all three of its bounds at once (`followsPerTurn` follows,
/// `readmissionsPerTurn` re-queues, `parksPerPump` parks) over 10,000 members parked `awaitingSpace`. Groups, in ticket
/// order: P (256 changed 101-byte members: the alarm's sweep turn spends its follow budget on them), H (1,024 members in
/// a pattern of eight: one changed and three unchanged 101-byte members, one changed and three unchanged 61,000-byte
/// members), T (8,720 changed 101-byte members, which the follow's first held turn visits 256 of). 100 bytes of room and
/// a pruned 60,000-byte blob: after the reclaim the 101-byte members fit (384 x 101 bytes ahead), the 61,000-byte ones
/// are parked `insufficientSpace`. The second sweep turn (run directly, timed) re-queues 512 (128 followed), parks 512
/// (128 followed) and breaks at T.
extension VerifyC5CorrectProbes {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C5-SWEEP-MAX: a sweep turn at all three bounds during an owed follow stays within C2", .timeLimit(.minutes(5)), arguments: [1, 2])
    func sweepAtAllBounds(_ handles: Int) async throws {
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
            random: SeededRandom(seed: 0xC6),
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
        let xBytes = Data(repeating: 0x78, count: 60_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        #expect(await engine.sync(.force).isComplete)
        // (id, size, changed): every eight members, one changed and three unchanged 101-byte members, one changed and
        // three unchanged 61,000-byte members.
        var layout: [(group: Int, id: String, size: Int, changed: Bool)] = []
        for index in 0..<10_000 {
            let slot = index % 8
            layout.append((0, String(format: "q%05d", index), slot < 4 ? 101 : 61_000, slot == 0 || slot == 4))
        }
        func entries(_ version: UInt64) -> [ManifestEntry] {
            layout.enumerated().map { offset, member in
                let seed = (member.changed && version == 3 ? 0xC6_0000_0000 : 0xC5_0000_0000) + UInt64(offset)
                return SyncBench.entry(member.id, GeneratedPayload.bytes(seed: seed, offset: 0, length: member.size), policy: .onDemand)
            }
        }
        let v2 = entries(2)
        await source.scriptManifest([.fetched(SyncBench.manifestData(v2), etag: ETag(rawValue: "\"v2\""))])
        #expect(await engine.sync(.force).isComplete)
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        #expect(try await store.freeSpace().pendingReclaim == Int64(xBytes.count))
        await engine.refreshFreeSpace()
        for _ in 0..<handles {
            guard case .success = await engine.registerGroup(v2.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("group refused")
            }
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: layout.count)) {
            await Task.yield()
        }
        let v3 = entries(3)
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast-2")
        _ = try await engine.readFreeSpace()
        await Self.holdSweeps(engine)
        let owedBefore = await Self.holdingMoved(engine)
        let awaitingBefore = await SyncBench.awaitingSpace(engine)
        await SyncBench.raiseOwnedTaskPriority(engine)
        let alarmWait = try await SyncBench.longestWait(on: engine) {
            time.advance(by: 61)
            while !Task.isCancelled, !(await Self.firstSweepDone(engine)) {
                await Task.yield()
            }
        }
        let owedAfterFirst = await Self.holdingMoved(engine)
        let awaitingAfterFirst = await SyncBench.awaitingSpace(engine)
        var turns: [(ms: Double, followed: Int, left: Int, queued: Int)] = []
        while !Task.isCancelled, await Self.sweepOwed(engine), turns.count < 3 {
            let queuedBefore = await Self.queuedCount(engine)
            let awaiting = await SyncBench.awaitingSpace(engine)
            let turn = await Self.timedSweep(engine)
            let left = awaiting - (await SyncBench.awaitingSpace(engine))
            let queued = await Self.queuedCount(engine) - queuedBefore
            turns.append((turn.ms, turn.followed, left, queued))
            while !Task.isCancelled, !(await Self.sweepSettled(engine)) {
                await Task.yield()
            }
        }
        print("PROBE-C5-SWEEP-MAX handles=\(handles): owed \(owedBefore), awaiting \(awaitingBefore); alarm turn heartbeat \(String(format: "%.2f", alarmWait)) ms, followed \(owedBefore - owedAfterFirst), left awaiting \(awaitingBefore - awaitingAfterFirst); follow-up turns (ms, followed, left awaitingSpace, queued delta): \(turns.map { "(\(String(format: "%.2f", $0.ms)), \($0.followed), \($0.left), \($0.queued))" })")
        await engine.shutdown()
        _ = await sync.value
        #expect(turns.count >= 1)
        #expect(owedBefore - owedAfterFirst <= SyncEngine.followsPerTurn)
        #expect(alarmWait <= 10.0, "handles=\(handles): the alarm turn's heartbeat \(alarmWait) ms")
        #expect(turns.allSatisfy { $0.followed <= SyncEngine.followsPerTurn })
        #expect((turns.map(\.ms).max() ?? 0) <= 10.0, "handles=\(handles): \(turns.map(\.ms))")
    }

    static func queuedCount(_ engine: isolated SyncEngine) -> Int {
        engine.state.jobs.values.filter { $0.state == .queued }.count
    }
}

/// PROBE-C5-SWEEP-CPU: the same sweeps timed directly on the actor in wall time AND in the thread's CPU time (immune to
/// preemption on a loaded host). The reclaim is adopted synthetically (the read the alarm adopts after the reaper freed
/// the pending bytes) and `sweepSpaceParked(.reclaimed)` is called directly; then every follow-up sweep turn is run
/// directly (`releaseSpaceSweepFollowUps`, hold re-armed). Layouts: `alternating` (400 / 3,000 bytes, 2,000 reclaimed),
/// `pattern` (per eight: 1 changed + 3 unchanged 101-byte, 1 changed + 3 unchanged 61,000-byte; 60,000 reclaimed);
/// `changed` false is the same sweep with no follow owed (the baseline).
struct SweepCPUMode: Sendable, CustomStringConvertible {
    let pattern: Bool
    let changed: Bool
    let handles: Int
    var description: String { "\(self.pattern ? "pattern" : "alternating") changed=\(self.changed) handles=\(self.handles)" }
}

extension VerifyC5CorrectProbes {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C5-SWEEP-CPU: sweep turns at 10,000 in wall and CPU time, with and without an owed follow", .timeLimit(.minutes(5)), arguments: [
        SweepCPUMode(pattern: false, changed: false, handles: 1),
        SweepCPUMode(pattern: false, changed: true, handles: 1),
        SweepCPUMode(pattern: false, changed: true, handles: 2),
        SweepCPUMode(pattern: true, changed: false, handles: 1),
        SweepCPUMode(pattern: true, changed: true, handles: 1),
        SweepCPUMode(pattern: true, changed: true, handles: 2),
    ])
    func sweepCPU(_ mode: SweepCPUMode) async throws {
        let count = 10_000
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
            random: SeededRandom(seed: 0xC7),
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
        let reclaimed = mode.pattern ? 60_000 : 2_000
        let xBytes = Data(repeating: 0x78, count: reclaimed)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        #expect(await engine.sync(.force).isComplete)
        let layout: [(id: String, size: Int, changed: Bool)] = (0..<count).map { index in
            if mode.pattern {
                let slot = index % 8
                return (String(format: "c%05d", index), slot < 4 ? 101 : 61_000, slot == 0 || slot == 4)
            }
            return (String(format: "c%05d", index), index % 2 == 0 ? 400 : 3_000, true)
        }
        func entries(_ version: Int) -> [ManifestEntry] {
            layout.enumerated().map { offset, member in
                let seed: UInt64 = (member.changed && version == 3 ? 0xC7_0000_0000 : 0xC8_0000_0000) + UInt64(offset)
                return SyncBench.entry(member.id, GeneratedPayload.bytes(seed: seed, offset: 0, length: member.size), policy: .onDemand)
            }
        }
        let v2 = entries(2)
        await source.scriptManifest([.fetched(SyncBench.manifestData(v2), etag: ETag(rawValue: "\"v2\""))])
        #expect(await engine.sync(.force).isComplete)
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        #expect(try await store.freeSpace().pendingReclaim == Int64(reclaimed))
        await engine.refreshFreeSpace()
        for _ in 0..<mode.handles {
            guard case .success = await engine.registerGroup(v2.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("group refused")
            }
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        var sync: Task<SyncOutcome, Never>?
        if mode.changed {
            await source.scriptManifest([.fetched(SyncBench.manifestData(entries(3)), etag: ETag(rawValue: "\"v3\""))])
            await engine.holdFollowFollowUps()
            sync = Task { await engine.sync(.force) }
            while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
                await Task.yield()
            }
        }
        await Self.holdSweeps(engine)
        var turns: [(wall: Double, cpu: Double, followed: Int, left: Int)] = []
        turns.append(await Self.cpuTimedSweep(engine, adopt: Int64(reclaimed)))
        while !Task.isCancelled, !(await Self.sweepSettled(engine)) {
            await Task.yield()
        }
        while !Task.isCancelled, await Self.sweepOwed(engine), turns.count < 60 {
            turns.append(await Self.cpuTimedSweep(engine, adopt: nil))
            while !Task.isCancelled, !(await Self.sweepSettled(engine)) {
                await Task.yield()
            }
        }
        let cpu = turns.map(\.cpu)
        let wall = turns.map(\.wall)
        print("PROBE-C5-SWEEP-CPU \(mode): turns \(turns.count); cpu ms \(cpu.map { String(format: "%.2f", $0) }); cpu max \(String(format: "%.2f", cpu.max() ?? 0)) median \(String(format: "%.2f", cpu.sorted()[cpu.count / 2])); wall max \(String(format: "%.2f", wall.max() ?? 0)) median \(String(format: "%.2f", wall.sorted()[wall.count / 2])); followed \(turns.map(\.followed).prefix(4))... left awaiting \(turns.map(\.left).prefix(4))...")
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = await sync?.value
        #expect(turns.allSatisfy { $0.followed <= SyncEngine.followsPerTurn })
        #expect((cpu.max() ?? 0) <= 10.0, "\(mode): the longest sweep turn used \(cpu.max() ?? 0) ms of CPU")
    }

    static func cpuTimedSweep(_ engine: isolated SyncEngine, adopt reclaimed: Int64?) -> (wall: Double, cpu: Double, followed: Int, left: Int) {
        if let reclaimed, let space = engine.state.freeSpace {
            engine.state.freeSpace = FreeSpace(
                volumeImportant: space.volumeImportant + reclaimed,
                volumeOpportunistic: space.volumeOpportunistic + reclaimed,
                usedBytes: space.usedBytes,
                pendingReclaim: 0,
                budgetBytes: space.budgetBytes,
                reserveBytes: space.reserveBytes
            )
        }
        let before = Self.holdingMoved(engine)
        let awaiting = engine.state.spaceParked.filter { engine.state.jobs[$0]?.state == .blocked(.awaitingSpace) }.count
        let clock = ContinuousClock()
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let start = clock.now
        if reclaimed != nil {
            engine.sweepSpaceParked(.reclaimed)
        } else {
            engine.releaseSpaceSweepFollowUps()
        }
        let elapsed = clock.now - start
        let cpuEnd = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        engine.holdSpaceSweepFollowUps()
        let after = Self.holdingMoved(engine)
        let awaitingAfter = engine.state.spaceParked.filter { engine.state.jobs[$0]?.state == .blocked(.awaitingSpace) }.count
        let wall = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return (wall, Double(cpuEnd - cpuStart) / 1e6, before - after, awaiting - awaitingAfter)
    }
}
