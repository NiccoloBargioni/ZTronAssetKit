import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Design D3 ("root") probes for the s3f sweep/follow visit-order class. Scratch; never committed as is.
///
/// Every probe runs in both visit orders (`LaneDropVisit`): `.followVisitedFirst` releases the bounded follow's held turns
/// and waits for its end before the decision under test; `.sweepFollowsFirst` makes the decision while the follow still
/// owes the visit that changes what the decision reads. The criterion is the verifiers': the answers must not depend
/// on the order.
///
/// - PROBE-D3-PUMP-ABANDON: a user request made while the follow owes the visit that abandons a download holding the
///   room. The pump gates the request against the room with the doomed download's bytes still in flight.
/// - PROBE-D3-PUMP-PROMOTE: the pump (no space sweep involved) starts prefetch work R while the follow owes the visit that
///   moves a user waiter onto the queued prefetch job P, so P is gated after R as prefetch work.
/// - PROBE-D3-PUMP-STALLED-USER: a freed slot goes to prefetch work X while a user queue whose head waits for the follow
///   holds user work Z behind it (`hasQueuedUser` counts only the head), so X takes the room Z gets visit-first.
/// - PROBE-D3-JOIN-ABANDON: a user request joins a job parked `insufficientSpace` while the follow owes the visit that
///   abandons the download holding the room: the join's re-check (`relane`, `failFastJoiner`) answers a shortage.
/// - PROBE-D3-READ-PROMOTE: a free-space read (and its sweep) lands while the follow owes the visit that moves a user
///   waiter onto a job parked `insufficientSpace`; the visit's re-check then reads the new room.
/// - PROBE-D3-TICKET: a user request made while the follow owes the visit that creates another user waiter's new-content
///   job takes an earlier ticket than that job, so the reclaim's sweep serves the later request first.
@Suite("DesignD3Probes", .serialized)
struct DesignD3Probes {
    // MARK: Shared setup

    @available(macOS 15.0, iOS 18.0, *)
    struct Setup {
        let time: ManualTimeSource
        let fileSystem: FakeFileSystem
        let harness: EngineHarness
        var engine: SyncEngine { self.harness.engine }
        let q: ManifestEntry
    }

    /// An engine on 32 MB volumes (above the reserve) that synced `[q]` (plus `x` when `pruned`, which v2 prunes so its
    /// bytes wait for the 60 s grace).
    @available(macOS 15.0, iOS 18.0, *)
    static func setup(seed: UInt64, tuning: SyncTuning = SyncTuning(), pruned: Data? = nil) async throws -> (Setup, ManifestEntry?) {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, tuning: tuning, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let qBytes = EngineFixture.bytes(seed, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        var x: ManifestEntry?
        if let pruned {
            x = EngineFixture.entry("x", pruned)
            await harness.serveManifest([x!, q])
            await harness.scriptTransfers([(x!, pruned), (q, qBytes)])
        } else {
            await harness.serveManifest([q])
            await harness.scriptTransfers([(q, qBytes)])
        }
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await harness.engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        return (Setup(time: time, fileSystem: fileSystem, harness: harness, q: q), x)
    }

    /// Changed entries without jobs that sort before the `zz-` ids: the follow's first pass formats
    /// `followFormatsPerTurn` of them and stops before the probe's entries.
    @available(macOS 15.0, iOS 18.0, *)
    static func fillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    /// Serves `v3`, holds the follow's follow-ups, applies it, and in `.followVisitedFirst` lets the follow end.
    @available(macOS 15.0, iOS 18.0, *)
    static func apply(_ v3: [ManifestEntry], _ s: Setup, visit: LaneDropVisit) async -> Task<SyncOutcome, Never> {
        await s.engine.readForTests { $0.holdFollowFollowUps() }
        await s.harness.serveManifest(v3, etag: "v3")
        let engine = s.engine
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        return sync
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func finish(_ s: Setup, sync: Task<SyncOutcome, Never>) async {
        let engine = s.engine
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }

    // MARK: PUMP-ABANDON

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D3-PUMP-ABANDON", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func pumpAbandon(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await Self.setup(seed: 969_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0x81, count: 5_000_000)
        let kBytes = Data(repeating: 0x82, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await s.harness.serveManifest([s.q] + Self.fillers(750_000) + [a, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 6 MB of room: C (5 MB) starts and leaves 1 MB.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(6_000_000, harness: s.harness, fileSystem: s.fileSystem)
        #expect(try await s.harness.store.freeSpace().pendingReclaim == 0, "setup: nothing waits for a reclaim")
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let newBytes = EngineFixture.bytes(969_004, count: 16)
        let moved = EngineHarness.onDemand("zz-a", newBytes)
        await s.harness.source.script(moved.transferID, [.stage(newBytes)])
        // v3 moves A to 16 bytes: C's visit supersedes and abandons it (5 MB leave the ledger).
        let sync = await Self.apply([s.q] + Self.fillers(850_000) + [moved, k], s, visit: visit)
        let created = await engine.readForTests { $0.state.jobsCreated }
        let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
        print("PROBE-D3-PUMP-ABANDON \(visit) before: \(before)")
        if visit == .sweepFollowsFirst {
            #expect(before.owed && before.c == .downloading, "setup: C still downloads and its visit is owed: \(before)")
        }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { e in
            e.state.jobsCreated > created && ((e.state.jobs[k.transferID].map { $0.state != .queued } ?? true) || e.state.pumpWaitsForFollow)
        }
        let decided = await engine.readForTests { e in (owed: e.followOwed, k: e.state.jobs[k.transferID]?.state) }
        print("PROBE-D3-PUMP-ABANDON \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-D3-PUMP-ABANDON \(visit) K: \(kResult) | A: \(aResult)")
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K's user waiter is answered from its 3 MB: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        await Self.finish(s, sync: sync)
    }

    // MARK: PUMP-PROMOTE

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D3-PUMP-PROMOTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func pumpPromote(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await Self.setup(seed: 968_002, tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let engine = s.engine
        let sBytes = (0..<2).map { EngineFixture.bytes(968_010 + UInt64($0), count: 16) }
        let slots = (0..<2).map { EngineHarness.onDemand("zs\($0)", sBytes[$0]) }
        let cBytes = Data(repeating: 0x83, count: 5_000_000)
        let rBytes = Data(repeating: 0x84, count: 3_500_000)
        let pBytes = Data(repeating: 0x85, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + Self.fillers(740_000) + slots + [a, p, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 6 MB of room: P (3 MB) or R (3.5 MB), not both.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(6_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        for (entry, bytes) in zip(slots, sBytes) {
            await s.harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        await s.harness.source.script(r.transferID, [.stage(rBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let slotWaiters = slots.map { entry in Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) } }
        await engine.awaitCondition { e in slots.allSatisfy { e.state.jobs[$0.transferID]?.state == .downloading } }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state == .queued }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .queued }
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        let sync = await Self.apply([s.q] + Self.fillers(840_000) + slots + [moved, p, r], s, visit: visit)
        let before = await engine.readForTests { e in
            (owed: e.followOwed, p: e.state.jobs[p.transferID].map { (e.queueRank($0), $0.state) }, r: e.state.jobs[r.transferID].map { (e.queueRank($0), $0.state) })
        }
        print("PROBE-D3-PUMP-PROMOTE \(visit) before: \(before)")
        // Both slots free while (sweep-first) the follow still owes C's visit.
        for (index, entry) in slots.enumerated() {
            await s.harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
            _ = await EngineHarness.value(of: slotWaiters[index])
        }
        await engine.awaitCondition { e in slots.allSatisfy { e.state.jobs[$0.transferID] == nil } && e.state.draining.isEmpty }
        let decided = await engine.readForTests { e in
            (owed: e.followOwed, p: e.state.jobs[p.transferID]?.state, r: e.state.jobs[r.transferID]?.state)
        }
        print("PROBE-D3-PUMP-PROMOTE \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        print("PROBE-D3-PUMP-PROMOTE \(visit) A: \(aResult) | P: \(pResult) | R: \(rResult)")
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "A's user waiter, moved onto P, is answered from P's 3 MB: \(aResult)")
        #expect((try? pResult.get())?.byteSize == Int64(pBytes.count), "P's prefetch waiter is answered from its 3 MB: \(pResult)")
        if case .failure(.insufficientSpace(let required, let available)) = rResult {
            #expect(required == Int64(rBytes.count) && available < required, "R's figures: \(rResult)")
        } else {
            Issue.record("R (prefetch, after the user work) gets insufficientSpace: \(rResult)")
        }
        await Self.finish(s, sync: sync)
    }

    // MARK: PUMP-STALLED-USER

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D3-PUMP-STALLED-USER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func pumpStalledUser(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await Self.setup(seed: 967_002, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let slotBytes = EngineFixture.bytes(967_010, count: 16)
        let slot = EngineHarness.onDemand("zs0", slotBytes)
        let yBytes = EngineFixture.bytes(967_011, count: 16)
        let zBytes = Data(repeating: 0x86, count: 3_000_000)
        let xBytes = Data(repeating: 0x87, count: 3_500_000)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        let z = EngineHarness.onDemand("zz-z", zBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        await s.harness.serveManifest([s.q] + Self.fillers(730_000) + [slot, x, y, z], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 4 MB of room: Z (3 MB) or X (3.5 MB), not both.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(4_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(slot.transferID, [.hold, .stage(slotBytes)])
        await s.harness.source.script(z.transferID, [.stage(zBytes)])
        await s.harness.source.script(x.transferID, [.stage(xBytes)])
        let slotWaiter = Task { await engine.awaitAsset(slot.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[slot.transferID]?.state == .downloading }
        let yWaiter = Task { await engine.awaitAsset(y.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[y.transferID]?.state == .queued }
        let zWaiter = Task { await engine.awaitAsset(z.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[z.transferID]?.state == .queued }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .queued }
        // v3 drops Y's id: Y's job waits at the user queue's head for its visit, Z behind it.
        let sync = await Self.apply([s.q] + Self.fillers(830_000) + [slot, x, z], s, visit: visit)
        await s.harness.source.release(slot.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineHarness.value(of: slotWaiter)
        await engine.awaitCondition { $0.state.jobs[slot.transferID] == nil && $0.state.draining.isEmpty }
        let decided = await engine.readForTests { e in
            (owed: e.followOwed, y: e.state.jobs[y.transferID]?.state, z: e.state.jobs[z.transferID]?.state, x: e.state.jobs[x.transferID]?.state)
        }
        print("PROBE-D3-PUMP-STALLED-USER \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let yResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: yWaiter) }
        let zResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: zWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        print("PROBE-D3-PUMP-STALLED-USER \(visit) Y: \(yResult) | Z: \(zResult) | X: \(xResult)")
        #expect(yResult == .failure(.notFound), "Y's dropped id is answered notFound: \(yResult)")
        #expect((try? zResult.get())?.byteSize == Int64(zBytes.count), "Z's user waiter is answered from its 3 MB: \(zResult)")
        if case .failure(.insufficientSpace) = xResult {
        } else {
            Issue.record("X (prefetch, served after the user work) gets insufficientSpace: \(xResult)")
        }
        await Self.finish(s, sync: sync)
    }

    // MARK: JOIN-ABANDON

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D3-JOIN-ABANDON", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func joinAbandon(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await Self.setup(seed: 966_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0x88, count: 5_000_000)
        let pBytes = Data(repeating: 0x89, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + Self.fillers(720_000) + [a, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 7 MB of room: C (5 MB) starts; P (3 MB) is parked `insufficientSpace` beside it (2 MB).
        _ = try await EngineRegressionCycle6Tests.leaveRoom(7_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        // A prefetch group member keeps P parked without an answer.
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.insufficientSpace) }
        let newBytes = EngineFixture.bytes(966_004, count: 16)
        let moved = EngineHarness.onDemand("zz-a", newBytes)
        await s.harness.source.script(moved.transferID, [.stage(newBytes)])
        let sync = await Self.apply([s.q] + Self.fillers(820_000) + [moved, p], s, visit: visit)
        let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, p: e.state.jobs[p.transferID]?.state) }
        print("PROBE-D3-JOIN-ABANDON \(visit) before: \(before)")
        // A user request for P's id joins its parked job.
        let created = await engine.readForTests { $0.state.jobs[p.transferID]?.interests.count ?? 0 }
        let answered = Mutex(false)
        let pWaiter = Task {
            let result = await engine.awaitAsset(p.identifier, lane: .userInitiated)
            answered.withLock { $0 = true }
            return result
        }
        // Joined (and still waiting), answered at once, or re-queued.
        while !answered.withLock({ $0 }), !(await engine.readForTests { e in (e.state.jobs[p.transferID]?.interests.count ?? 0) > created || e.state.jobs[p.transferID]?.state != .blocked(.insufficientSpace) }) {
            await Task.yield()
        }
        let decided = await engine.readForTests { e in (owed: e.followOwed, p: e.state.jobs[p.transferID]?.state) }
        print("PROBE-D3-JOIN-ABANDON \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-D3-JOIN-ABANDON \(visit) P: \(pResult) | A: \(aResult)")
        #expect((try? pResult.get())?.byteSize == Int64(pBytes.count), "P's user waiter is answered from its 3 MB: \(pResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its new content: \(aResult)")
        await engine.releaseGroup(group)
        await Self.finish(s, sync: sync)
    }

    // MARK: READ-PROMOTE

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D3-READ-PROMOTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func readPromote(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await Self.setup(seed: 965_002)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(965_003, count: 16)
        let pBytes = Data(repeating: 0x8A, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + Self.fillers(710_000) + [a, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 2 MB of room: P (3 MB) is parked `insufficientSpace`.
        let free0 = try await s.harness.store.freeSpace()
        let ballastSize = free0.volumeImportant - free0.reserveBytes - 2_000_000
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.insufficientSpace) }
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        let sync = await Self.apply([s.q] + Self.fillers(810_000) + [moved, p], s, visit: visit)
        // A free-space read finds 6 MB (something else freed 4 MB).
        try s.fileSystem.write(Data(repeating: 1, count: Int(ballastSize - 4_000_000)), to: ballast, mode: .truncate)
        await engine.refreshFreeSpace()
        let decided = await engine.readForTests { e in (owed: e.followOwed, p: e.state.jobs[p.transferID]?.state, room: e.state.freeSpace.flatMap { space in e.state.jobs[p.transferID].map { j in e.headroom(for: j, in: space) } }) }
        print("PROBE-D3-READ-PROMOTE \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        print("PROBE-D3-READ-PROMOTE \(visit) A: \(aResult)")
        // Visit-first, A's visit moves it onto P before the read: P does not fit 2 MB and A is answered with the shortage.
        // The criterion: the same answer in both orders.
        if case .failure(.insufficientSpace(let required, let available)) = aResult {
            #expect(required == Int64(pBytes.count) && available < 2_100_000, "A's figures are the room before the read: \(aResult)")
        } else {
            Issue.record("A's visit precedes the read visit-first, so A gets the shortage of the room before it: \(aResult)")
        }
        await engine.releaseGroup(group)
        await Self.finish(s, sync: sync)
    }

    // MARK: TICKET

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D3-TICKET", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func ticket(_ visit: LaneDropVisit) async throws {
        let xBytes = Data(repeating: 0x8B, count: 4_000_000)
        let (s, xEntry) = try await Self.setup(seed: 964_002, pruned: xBytes)
        _ = try #require(xEntry)
        let engine = s.engine
        let cBytes = Data(repeating: 0x8C, count: 5_000_000)
        let nBytes = Data(repeating: 0x8D, count: 3_000_000)
        let kBytes = Data(repeating: 0x8E, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        // v2 prunes x: its 4 MB wait for the grace.
        await s.harness.serveManifest([s.q] + Self.fillers(700_000) + [a, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: s.harness, fileSystem: s.fileSystem)
        #expect(try await s.harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.stage(cBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let moved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(moved.transferID, [.stage(nBytes)])
        let sync = await Self.apply([s.q] + Self.fillers(800_000) + [moved, k], s, visit: visit)
        // K's user request (sweep-first: while the follow owes A's visit, which creates A's new-content job N).
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID] != nil }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { e in
            !e.followOwed && e.state.jobs[moved.transferID]?.state == .blocked(.awaitingSpace) && e.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace)
        }
        let tickets = await engine.readForTests { e in (n: e.state.jobs[moved.transferID]?.ticket, k: e.state.jobs[k.transferID]?.ticket) }
        print("PROBE-D3-TICKET \(visit) tickets: \(tickets)")
        // 1 MB plus x's 4 MB after the reclaim: one of N and K.
        try await EngineSyncTests.leaveRoom(1_000_000, harness: s.harness, fileSystem: s.fileSystem)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        print("PROBE-D3-TICKET \(visit) A: \(aResult) | K: \(kResult)")
        #expect((try? aResult.get())?.byteSize == Int64(nBytes.count), "A (waiting since before the apply) is served from N: \(aResult)")
        #expect((try? kResult.get()) == nil, "K (requested after the apply) gets the shortage: \(kResult)")
        await Self.finish(s, sync: sync)
    }
}
