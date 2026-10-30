import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The follow barrier (R-SYN-2, R-SYN-3, R-SYN-11, F-28; Stage 3 close-out cycle 9, orchestrator ruling S3-R11): a
/// decision taken while a bounded follow still owes visits must be the decision taken when the follow visits first.
/// Cycles 5 to 8 each found a new member of that class (a space sweep, a pump, a join's re-check, an ENOSPC verdict and a
/// failure's answer each read lanes, ranks, interests or bytes in flight that the owed visits change). The design panel
/// (`wf_8bbbb235-852`) and its two judges wrote the probes these tests come from: D3's own (PROBE-D3-*), D1's
/// (PROBE-D-*), D2's (PROBE-D2-*), the judges' (PROBE-J-*) and the cycle-8 verifiers' (PROBE-C8-*, PROBE-C8R-*).
///
/// Each test runs in both orders (`LaneDropVisit`): `.followVisitedFirst` lets the held follow end before the event under
/// test, `.sweepFollowsFirst` delivers the event while the follow still owes the visit that changes what its decision
/// reads. The expectations are the visit-first outcome, in both orders. Real-world ledger inputs (a read of the free
/// space, the bytes a transfer that ended frees) apply when they arrive (S3-R11 R1), so none of these scenarios lets such
/// an input differ between the two orders.
///
/// Hang guards (S3-R4): every test here shares the setup of `EngineSweepOrderTests` (2,100 changed entries before the
/// scenario's ids, two forced syncs over 32 MB volumes), which took 33.8 to 35.4 s under TSan beside a second TSan
/// process (59 % of 60 s), so each takes `.minutes(3)`; this cycle's own figures are in `docs/adr-drafts/s3f.md`.
extension EngineSyncTests {
    /// The shared setup of the follow-barrier tests.
    enum FollowBarrier {
        /// An engine on 32 MB volumes above the reserve, its clock and file system, after a first sync of `q`.
        @available(macOS 15.0, iOS 18.0, *)
        struct Setup {
            /// The engine's clock.
            let time: ManualTimeSource
            /// The volume.
            let fileSystem: FakeFileSystem
            /// The engine and its fakes.
            let harness: EngineHarness
            /// The engine.
            var engine: SyncEngine { self.harness.engine }
            /// The entry every manifest lists.
            let q: ManifestEntry
        }

        /// An engine that synced `[q]`, plus `x` when `pruned` is given (a later manifest without it prunes it, so its
        /// bytes wait for the 60 s deletion grace).
        @available(macOS 15.0, iOS 18.0, *)
        static func setUp(seed: UInt64, tuning: SyncTuning = SyncTuning(), pruned: Data? = nil) async throws -> (Setup, ManifestEntry?) {
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
                let entry = EngineFixture.entry("x", pruned)
                x = entry
                await harness.serveManifest([entry, q])
                await harness.scriptTransfers([(entry, pruned), (q, qBytes)])
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

        /// An engine on 32 MB volumes that synced `x` (`xSize` bytes) and `q`: a later manifest that omits `x` prunes it
        /// (its bytes wait for the grace), one that keeps it leaves nothing pending.
        @available(macOS 15.0, iOS 18.0, *)
        static func setUpWithX(xSize: Int, seed: UInt64, tuning: SyncTuning = SyncTuning()) async throws -> (setup: Setup, x: ManifestEntry) {
            let xBytes = Data(repeating: 0x81, count: xSize)
            let (setup, x) = try await Self.setUp(seed: seed, tuning: tuning, pruned: xBytes)
            return (setup, try #require(x))
        }

        /// Changed on-demand entries without jobs that sort before the scenario's `zz-` ids: the follow's first pass formats
        /// `followFormatsPerTurn` of them and stops before the scenario's entries, so the follow stays owed.
        @available(macOS 15.0, iOS 18.0, *)
        static func fillers(_ seed: UInt64) -> [ManifestEntry] {
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }

        /// Serves `v3`, holds the follow's follow-up turns and applies it; in `.followVisitedFirst` lets the follow end.
        @available(macOS 15.0, iOS 18.0, *)
        static func apply(_ v3: [ManifestEntry], _ setup: Setup, visit: LaneDropVisit) async -> Task<SyncOutcome, Never> {
            await setup.engine.readForTests { $0.holdFollowFollowUps() }
            await setup.harness.serveManifest(v3, etag: "v3")
            let engine = setup.engine
            let sync = Task { await engine.sync(.force) }
            await engine.awaitCondition { $0.state.followFollowUpWaiting }
            if visit == .followVisitedFirst {
                // The follow's turns are owned tasks, not timers: the clock stays where it is.
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followOwed }
            }
            return sync
        }

        /// Checks the invariants, lets the sync end and shuts the engine down.
        @available(macOS 15.0, iOS 18.0, *)
        static func finish(_ setup: Setup, sync: Task<SyncOutcome, Never>) async {
            let engine = setup.engine
            let violations = await engine.invariantViolations()
            #expect(violations.isEmpty, "\(violations.prefix(3))")
            let outcome = await EngineRegressionCycle6Tests.driving([setup.time], fence: engine) { await EngineHarness.value(of: sync) }
            #expect(outcome.completeReport != nil, "\(outcome)")
            await engine.shutdown()
        }
    }
}

/// The follow barrier's tests, one at a time (`.serialized`; Stage 3 close-out cycle 10, the cycle-9 reqs lens's issue 4):
/// each does two forced syncs over 2,100 changed entries and 32 MB volumes, 139 to 165 s per test under TSan when all of
/// them started with the rest of the Sync bundle, and the one-minute tests beside them timed out (43 of them at a rule-1
/// mean load of 40.45, S3-R12). Run one at a time, they leave the bundle's start to the others.
@Suite("Engine follow barrier (F-28)", .serialized)
struct EngineFollowBarrierTests {
    /// The shared setup of the follow-barrier tests.
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// `EngineSyncTests.leaveRoom`: the room above the reserve taken down to `room` with a second ballast file.
    @available(macOS 15.0, iOS 18.0, *)
    static func leaveRoom(_ room: Int64, harness: EngineHarness, fileSystem: FakeFileSystem) async throws {
        try await EngineSyncTests.leaveRoom(room, harness: harness, fileSystem: fileSystem)
    }

    // MARK: The pump (R-SYN-2)

    /// A user request made while the follow owes the visit that abandons a download is gated on the room that visit
    /// frees. D (4 MB) downloads for A's user waiter only, with 5 MB of room; v3 moves A to a 16-byte content while the
    /// bounded follow owes D's visit, and K (3 MB) is then requested for user work. Visited first, D is superseded (its
    /// bytes leave the ledger) and K fits. Gated beside D's doomed bytes, K was parked `insufficientSpace` and its waiter
    /// failed fast (PROBE-D-PUMP-FREED; the same scenario as PROBE-D3-PUMP-ABANDON and PROBE-D2-GATE-ABANDON, merged here).
    /// While K's place waits for the follow, the invariants hold (the cycle-9 amendment (b): a job whose place waits for
    /// the follow's end is queued there, not stranded).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a user request made while the follow owes the visit that abandons a download is gated on the room that visit frees (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGatesARequestOnTheRoomTheOwedVisitFrees(_ visit: LaneDropVisit) async throws {
        try await Self.barrierFreed(visit, joins: false)
    }

    /// A user waiter that joins a job parked `insufficientSpace` while the follow owes the visit that abandons the
    /// download holding the room is re-checked on the room that visit frees: K (3 MB) is a prefetch group's member, parked
    /// beside D's 4 MB in 5 MB of room. Visited first, D's bytes left and the join re-queues K; re-checked beside D's doomed
    /// bytes, the joiner was answered `insufficientSpace` (PROBE-D-JOIN-FREED; the same scenario as PROBE-D3-JOIN-ABANDON,
    /// merged here). A second joiner cancels while its answer waits for the follow: it gets `.cancelled` or K's content.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a user waiter joining a job parked for space while the follow owes the visit that frees the room is re-checked on the followed state (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierRechecksAJoinOnTheRoomTheOwedVisitFrees(_ visit: LaneDropVisit) async throws {
        try await Self.barrierFreed(visit, joins: true)
    }

    /// The scenario of the two freed-room tests: D (4 MB) downloads for A only, with 5 MB of room; v3 moves A to a
    /// 16-byte content while the follow owes D's visit; K is 3 MB, requested (or joined, when `joins`) for user work.
    @available(macOS 15.0, iOS 18.0, *)
    static func barrierFreed(_ visit: LaneDropVisit, joins: Bool) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 991_002)
        let engine = s.engine
        let dBytes = Data(repeating: 0x91, count: 4_000_000)
        let kBytes = Data(repeating: 0x92, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", dBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(780_000) + [a, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
        #expect(try await s.harness.store.freeSpace().pendingReclaim == 0, "setup: nothing waits for a reclaim")
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(dBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        var group: InterestToken?
        if joins {
            group = try await engine.registerGroup([k.identifier], lane: .prefetch).get()
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.insufficientSpace) }
        }
        let replacementBytes = EngineFixture.bytes(991_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await s.harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(880_000) + [replacement, k], s, visit: visit)
        let tokens = await engine.readForTests { $0.state.lastToken }
        let uWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.lastToken > tokens }
        var cancelled: Task<Result<AssetLocation, AssetError>, Never>?
        if joins {
            let joined = await engine.readForTests { $0.state.lastToken }
            let second = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
            // K may have committed already when the follow visited first: the second request is then answered from the
            // store without a join.
            await engine.awaitCondition { $0.state.lastToken > joined || $0.state.jobs[k.transferID] == nil }
            second.cancel()
            cancelled = second
        }
        let between = await engine.readForTests { engine in
            (owed: engine.followOwed, d: engine.state.jobs[a.transferID]?.state, k: engine.state.jobs[k.transferID]?.state, violations: engine.invariantViolations())
        }
        #expect(between.violations.isEmpty, "\(between.violations.prefix(3))")
        switch visit {
        case .followVisitedFirst:
            #expect(!between.owed && between.d == nil, "setup: the follow superseded D: \(between)")
        case .sweepFollowsFirst:
            #expect(between.owed && between.d == .downloading, "setup: D still downloads for A: \(between)")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? uResult.get())?.byteSize == Int64(kBytes.count), "the user request for K is served from the room the follow frees: \(uResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its new content: \(aResult)")
        if let cancelled {
            let second = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: cancelled) }
            #expect(second == .failure(.cancelled) || (try? second.get())?.byteSize == Int64(kBytes.count), "the cancelled joiner: \(second)")
        }
        if let group {
            await engine.releaseGroup(group)
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A slot freed while the follow owes the visit that raises a queued prefetch job to user work goes to that job, not to
    /// prefetch work queued before it. Two slots run user transfers; C (5 MB, A's user waiter), R (3.5 MB) and P (3 MB),
    /// both prefetch, are queued in that order; 6 MB of room hold P or R. v3 moves A onto P's content while the follow
    /// owes C's visit; then both slots free. Visited first, P is user work, starts first and R is parked. Pumped first,
    /// R (prefetch, ahead of P) started and P, parked beside it, failed A's user waiter fast (PROBE-D3-PUMP-PROMOTE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a slot freed during an owed follow goes to the queued job the follow raises to user work, not to prefetch work queued before it (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesAFreedSlotToTheJobTheOwedVisitPromotes(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 968_002, tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let engine = s.engine
        let sBytes = (0..<2).map { EngineFixture.bytes(968_010 + UInt64($0), count: 16) }
        let slots = (0..<2).map { EngineHarness.onDemand("zs\($0)", sBytes[$0]) }
        let cBytes = Data(repeating: 0x83, count: 5_000_000)
        let rBytes = Data(repeating: 0x84, count: 3_500_000)
        let pBytes = Data(repeating: 0x85, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(740_000) + slots + [a, p, r], etag: "v2")
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
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(840_000) + slots + [moved, p, r], s, visit: visit)
        // Both slots free (sweep-first: while the follow still owes C's visit).
        for (index, entry) in slots.enumerated() {
            await s.harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
            _ = await EngineHarness.value(of: slotWaiters[index])
        }
        await engine.awaitCondition { e in slots.allSatisfy { e.state.jobs[$0.transferID] == nil } && e.state.draining.isEmpty }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "A's user waiter, moved onto P, is answered from P's 3 MB: \(aResult)")
        #expect((try? pResult.get())?.byteSize == Int64(pBytes.count), "P's prefetch waiter is answered from its 3 MB: \(pResult)")
        if case .failure(.insufficientSpace(let required, let available)) = rResult {
            #expect(required == Int64(rBytes.count) && available < required, "R's figures: \(rResult)")
        } else {
            Issue.record("R (prefetch, after the user work) gets insufficientSpace: \(rResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// The one-slot form: D (a user download) holds the only slot; C (A's user waiter, 5 MB), R (3.5 MB) and P (3 MB),
    /// both prefetch, are queued for it with 4 MB of room and nothing pending reclaim. v3 moves A onto P's content while
    /// the follow owes C's visit; then D ends. Visited first, P is user work and takes the slot and the room, and R is
    /// parked. Pumped first, R started (C's head waited for the follow), and the promotion's preemption freed the slot
    /// but not R's bytes in flight, so P was parked and A's user waiter failed fast (PROBE-D2-PUMP-PROMOTE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: with one slot, the queued job an owed follow raises to user work takes the freed slot and the room before prefetch work (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesTheOnlySlotToTheJobTheOwedVisitPromotes(_ visit: LaneDropVisit) async throws {
        let (s, x) = try await FollowBarrier.setUpWithX(xSize: 1_000, seed: 979_202, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let cBytes = Data(repeating: 0x88, count: 5_000_000)
        let dBytes = EngineFixture.bytes(979_204, count: 16)
        let rBytes = Data(repeating: 0x89, count: 3_500_000)
        let pBytes = Data(repeating: 0x8A, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        await s.harness.serveManifest([x, s.q] + FollowBarrier.fillers(790_000) + [a, d, p, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(4_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(d.transferID, [.hold, .stage(dBytes)])
        await s.harness.source.script(a.transferID, [.stage(cBytes)])
        await s.harness.source.script(r.transferID, [.stage(rBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let dWaiter = Task { await engine.awaitAsset(d.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[d.transferID]?.state == .downloading }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state == .queued }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .queued }
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        let sync = await FollowBarrier.apply([x, s.q] + FollowBarrier.fillers(890_000) + [moved, d, p, r], s, visit: visit)
        // D ends: its slot frees (sweep-first: while the follow still owes C's visit).
        await s.harness.source.release(d.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: dWaiter) }
        await engine.awaitCondition { $0.state.jobs[d.transferID] == nil && $0.state.draining.isEmpty }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "A's user waiter, moved onto P, is answered from P's 3 MB: \(aResult)")
        #expect((try? pResult.get())?.byteSize == Int64(pBytes.count), "P's prefetch waiter is answered from its 3 MB: \(pResult)")
        if case .failure(.insufficientSpace(let required, let available)) = rResult {
            #expect(required == Int64(rBytes.count) && available < required, "R's figures: \(rResult)")
        } else {
            Issue.record("R's prefetch waiter is answered insufficientSpace: R does not fit beside P: \(rResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A slot freed while the follow owes the visit that creates a user waiter's new-content job goes to that job, not to
    /// prefetch work queued before it: four user holders occupy every slot, A (C, 4 MB) is queued behind them and J (3 MB,
    /// prefetch) behind A; 5 MB of room hold one of N and J. v3 moves A to N (3 MB) while the follow owes C's visit; then
    /// a slot frees. Visited first, N (user) is queued and served first and J is parked. Pumped first, J started while C
    /// waited for its visit, and N was parked beside it (PROBE-D-PUMP-PROMOTE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a slot freed during an owed follow goes to the new content's user job the follow creates, before prefetch work queued earlier (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesAFreedSlotToTheJobTheOwedVisitCreates(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 990_002)
        let engine = s.engine
        let holderBytes = (0..<4).map { EngineFixture.bytes(990_100 + UInt64($0), count: 16) }
        let holders = (0..<4).map { EngineHarness.onDemand("h\($0)", holderBytes[$0]) }
        let cBytes = Data(repeating: 0x81, count: 4_000_000)
        let jBytes = Data(repeating: 0x82, count: 3_000_000)
        let nBytes = Data(repeating: 0x83, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let j = EngineHarness.onDemand("zz-j", jBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(770_000) + holders + [a, j], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        for (entry, bytes) in zip(holders, holderBytes) {
            await s.harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        let holderWaiters = holders.map { entry in Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) } }
        await engine.awaitCondition { engine in holders.allSatisfy { engine.state.jobs[$0.transferID]?.state == .downloading } }
        await s.harness.source.script(a.transferID, [.stage(cBytes)])
        await s.harness.source.script(j.transferID, [.stage(jBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        let jWaiter = Task { await engine.awaitAsset(j.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[j.transferID]?.state == .queued }
        let n = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(n.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(870_000) + holders + [n, j], s, visit: visit)
        let before = await engine.readForTests { engine in
            (owed: engine.followOwed, c: engine.state.jobs[a.transferID]?.state, n: engine.state.jobs[n.transferID]?.state, j: engine.state.jobs[j.transferID]?.state)
        }
        #expect(before.j == .queued, "setup: J waits for a slot: \(before)")
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.c == nil && before.n == .queued, "setup: the follow superseded C and N waits for a slot: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.c == .queued && before.n == nil, "setup: C still holds A: \(before)")
        }
        // A slot frees: h0 commits, and any later event pumps.
        await s.harness.source.release(holders[0].transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: holderWaiters[0]) }
        await engine.readForTests { $0.pump() }
        let afterSlot = await engine.readForTests { engine in engine.invariantViolations() }
        #expect(afterSlot.isEmpty, "\(afterSlot.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followOwed }
        for holder in holders.dropFirst() {
            await s.harness.source.release(holder.transferID, with: .progress(received: 0, expected: nil))
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let jResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: jWaiter) }
        for waiter in holderWaiters.dropFirst() {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
        }
        #expect((try? aResult.get())?.byteSize == Int64(nBytes.count), "A's user waiter, moved onto N, is answered from N's 3 MB: \(aResult)")
        if case .failure(.insufficientSpace(let required, let available)) = jResult {
            #expect(required == Int64(jBytes.count) && available < required, "J's figures: \(jResult)")
        } else {
            Issue.record("J's prefetch waiter is answered insufficientSpace: N's user work took the room first: \(jResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A slot freed while the follow owes the visit that ends the head of the user queue goes to the user work behind
    /// that head, not to prefetch work: the only slot runs a transfer; Y (16 bytes) and Z (3 MB) wait in the user queue,
    /// X (3.5 MB) in the prefetch queue; 4 MB of room hold Z or X. v3 drops Y's id while the follow owes Y's visit; then
    /// the slot frees. Visited first, Y's job ends (`.notFound`), Z starts and X is parked. Pumped first, the user queue
    /// waited at Y's head, the slot went to X and Z was parked beside it (PROBE-D3-PUMP-STALLED-USER).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a slot freed during an owed follow goes to the user work queued behind a job the follow ends, not to prefetch work (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesAFreedSlotToTheUserWorkBehindAnEndedHead(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 967_002, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let slotBytes = EngineFixture.bytes(967_010, count: 16)
        let slot = EngineHarness.onDemand("zs0", slotBytes)
        let yBytes = EngineFixture.bytes(967_011, count: 16)
        let zBytes = Data(repeating: 0x86, count: 3_000_000)
        let xBytes = Data(repeating: 0x87, count: 3_500_000)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        let z = EngineHarness.onDemand("zz-z", zBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(730_000) + [slot, x, y, z], etag: "v2")
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
        // v3 drops Y's id: Y's job heads the user queue, Z behind it.
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(830_000) + [slot, x, z], s, visit: visit)
        await s.harness.source.release(slot.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineHarness.value(of: slotWaiter)
        await engine.awaitCondition { $0.state.jobs[slot.transferID] == nil && $0.state.draining.isEmpty }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let yResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: yWaiter) }
        let zResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: zWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        #expect(yResult == .failure(.notFound), "Y's dropped id is answered notFound: \(yResult)")
        #expect((try? zResult.get())?.byteSize == Int64(zBytes.count), "Z's user waiter is answered from its 3 MB: \(zResult)")
        if case .failure(.insufficientSpace) = xResult {
        } else {
            Issue.record("X (prefetch, served after the user work) gets insufficientSpace: \(xResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// No transfer starts between two turns of the drain that gives the places an owed follow deferred, so work queued in
    /// a later drain turn is not passed by work a pump started meanwhile (the cycle-9 amendment (d)): the only slot is
    /// free; while the follow is owed 512 prefetch requests and then a user request U are made, so 513 places wait and
    /// the drain's first turn gives the prefetch requests' 512 (`eventsAfterFollowPerTurn`). An event between the
    /// two drain turns pumps (here, the release's own turn pumps again). Pumped there, the slot went to the first member
    /// and U waited behind it; held until the drain's last batch, the pump serves U, user work, first (R-SYN-2). The
    /// follow barrier has no visit-first counterpart for the slot (a request made after the follow starts at once), so
    /// the test runs in one order.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: no transfer starts between two turns of the drain of an owed follow's deferred places, so a user request placed in a later turn is served first (F-28)", .timeLimit(.minutes(3)))
    func barrierAdmitsNothingBetweenDrainTurns() async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 960_502, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let count = SyncEngine.eventsAfterFollowPerTurn
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "zm%04d", $0), EngineFixture.bytes(960_600 + UInt64($0), count: 16)) }
        let uBytes = EngineFixture.bytes(960_510, count: 16)
        let u = EngineHarness.onDemand("zz-u", uBytes)
        let slotBytes = EngineFixture.bytes(960_511, count: 16)
        let slot = EngineHarness.onDemand("zs", slotBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(760_500) + members + [slot, u], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        for member in members {
            await s.harness.source.script(member.transferID, [.hold])
        }
        await s.harness.source.script(u.transferID, [.hold, .stage(uBytes)])
        await s.harness.source.script(slot.transferID, [.hold, .stage(slotBytes)])
        // A job exists at the apply (a follow with no job owes no pass): S holds the slot until the follow is owed.
        let slotWaiter = Task { await engine.awaitAsset(slot.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[slot.transferID]?.state == .downloading }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(860_500) + members + [slot, u], s, visit: .sweepFollowsFirst)
        await s.harness.source.release(slot.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: slotWaiter) }
        await engine.awaitCondition { $0.state.jobs[slot.transferID] == nil && $0.state.draining.isEmpty }
        let memberWaiters = members.map { member in Task { await engine.awaitAsset(member.identifier, lane: .prefetch) } }
        await engine.awaitCondition { $0.state.placesAfterFollow.count == count || !$0.followOwed }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.placesAfterFollow.count == count + 1 || !$0.followOwed }
        let deferred = await engine.readForTests { e in
            (owed: e.followOwed, places: e.state.placesAfterFollow.count, running: e.state.jobs.values.filter { $0.state == .downloading }.count)
        }
        #expect(deferred.owed && deferred.places == count + 1 && deferred.running == 0, "setup: the 513 places wait for the follow and nothing runs: \(deferred)")
        let starts = await s.harness.source.starts.count
        // The follow ends in the release's turn, the drain gives its first 512 places, and the turn pumps again.
        let between = await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.pump()
            return (
                owed: e.followOwed,
                waiting: e.state.eventsAfterFollow.count,
                running: e.state.jobs.values.filter { $0.state == .downloading }.map(\.transfer),
                violations: e.invariantViolations()
            )
        }
        #expect(!between.owed && between.waiting == 1, "setup: the follow ended and U's place waits for the drain's next turn: \(between.owed), \(between.waiting)")
        #expect(between.running.isEmpty, "no transfer starts between two drain turns: \(between.running)")
        #expect(between.violations.isEmpty, "\(between.violations.prefix(3))")
        await engine.awaitCondition { e in e.state.eventsAfterFollow.isEmpty && e.state.jobs.values.contains { $0.state == .downloading } }
        let after = await engine.readForTests { e in e.state.jobs.values.filter { $0.state == .downloading }.map(\.transfer) }
        let started = await s.harness.source.starts.dropFirst(starts).map(\.id)
        #expect(after == [u.transferID], "the drain's last batch pumps, and the slot goes to U, user work: \(after)")
        #expect(started.first == nil || started.first == u.transferID, "no member started before U: \(started.prefix(3))")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.shutdown()
        _ = await EngineHarness.value(of: uWaiter)
        for waiter in memberWaiters {
            _ = await EngineHarness.value(of: waiter)
        }
        _ = await EngineHarness.value(of: sync)
    }

    // MARK: Queue places (R-SYN-3)

    /// A user request made while the follow owes the visit that creates another user waiter's new-content job queues
    /// after that job: A (C, 5 MB) waits `awaitingSpace` for 4 MB of a pruned blob with 2 MB of room; v3 moves A to N
    /// (3 MB) while the follow owes C's visit, and K (3 MB) is requested for user work. Visited first, N's job exists
    /// before K's request and takes the earlier ticket: the reclaim (5 MB of room) serves N, and K gets the shortage.
    /// Requested first, K took the earlier ticket and the reclaim served K (PROBE-D3-TICKET).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a user request made during an owed follow queues after the new-content job the follow creates for an earlier waiter (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierQueuesARequestAfterTheJobTheOwedVisitCreates(_ visit: LaneDropVisit) async throws {
        let xBytes = Data(repeating: 0x8B, count: 4_000_000)
        let (s, xEntry) = try await FollowBarrier.setUp(seed: 964_002, pruned: xBytes)
        _ = try #require(xEntry)
        let engine = s.engine
        let cBytes = Data(repeating: 0x8C, count: 5_000_000)
        let nBytes = Data(repeating: 0x8D, count: 3_000_000)
        let kBytes = Data(repeating: 0x8E, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        // v2 prunes x: its 4 MB wait for the grace.
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(700_000) + [a, k], etag: "v2")
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
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(800_000) + [moved, k], s, visit: visit)
        // K's user request (sweep-first: while the follow owes A's visit, which creates A's new-content job N).
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID] != nil }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { e in
            !e.followOwed && e.state.jobs[moved.transferID]?.state == .blocked(.awaitingSpace) && e.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace)
        }
        // 1 MB plus x's 4 MB after the reclaim: one of N and K.
        try await Self.leaveRoom(1_000_000, harness: s.harness, fileSystem: s.fileSystem)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(nBytes.count), "A (waiting since before the apply) is served from N: \(aResult)")
        #expect((try? kResult.get()) == nil, "K (requested after the apply) gets the shortage: \(kResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A queued job that holds no moved id keeps its ticket while the follow is owed: K (3 MB, user) waits queued for the
    /// one slot from before the apply, A's job C (5 MB) behind it; v3 moves A to N (3 MB). The follow's second turn
    /// visits C and creates N (a later ticket than K), and its pass is still owed. The slot then frees (visit-first: after
    /// the follow). Both park `awaitingSpace`, and the reclaim's sweep, which orders by ticket, serves K before N
    /// (PROBE-J-HELD-RETICKET: D1's pump hold gave K a fresh ticket, later than N's).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a queued job that holds no moved id keeps its ticket through an owed follow (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierKeepsTheTicketOfAJobThatHoldsNoMovedID(_ visit: LaneDropVisit) async throws {
        let xBytes = Data(repeating: 0xE1, count: 4_000_000)
        let (s, xEntry) = try await FollowBarrier.setUp(seed: 966_102, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0), pruned: xBytes)
        _ = try #require(xEntry)
        let engine = s.engine
        let slBytes = EngineFixture.bytes(966_110, count: 16)
        let cBytes = Data(repeating: 0xE2, count: 5_000_000)
        let kBytes = Data(repeating: 0xE3, count: 3_000_000)
        let nBytes = Data(repeating: 0xE4, count: 3_000_000)
        let sl = EngineHarness.onDemand("zz-s", slBytes)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        // Changed entries after the zz- ids: the follow's second turn finds C, then formats up to its bound and stops.
        let tail = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "zzz%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        // v2 prunes x: its 4 MB wait for the grace.
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(701_000) + [sl, a, k] + tail(711_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: s.harness, fileSystem: s.fileSystem)
        #expect(try await s.harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await s.harness.source.script(sl.transferID, [.hold, .stage(slBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        await s.harness.source.script(a.transferID, [.stage(cBytes)])
        let slWaiter = Task { await engine.awaitAsset(sl.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[sl.transferID]?.state == .downloading }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .queued }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        let n = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(n.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(801_000) + [sl, n, k] + tail(811_000), s, visit: .sweepFollowsFirst)
        // The follow's second turn: C's visit creates N; the pass is still owed after it.
        await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.holdFollowFollowUps()
        }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        let mid = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, n: e.state.jobs[n.transferID].map { ($0.state, $0.ticket) }, k: e.state.jobs[k.transferID].map { ($0.state, $0.ticket) }) }
        #expect(mid.owed && mid.c == nil && mid.n != nil, "setup: N exists and the follow is still owed: \(mid)")
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        // The slot frees (visit-first: after the follow; else while it is owed).
        await s.harness.source.release(sl.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineHarness.value(of: slWaiter)
        await engine.awaitCondition { $0.state.jobs[sl.transferID] == nil && $0.state.draining.isEmpty }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { e in
            !e.followOwed && e.state.jobs[n.transferID]?.state == .blocked(.awaitingSpace) && e.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace)
        }
        // 1 MB plus x's 4 MB after the reclaim: one of K and N.
        try await Self.leaveRoom(1_000_000, harness: s.harness, fileSystem: s.fileSystem)
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K, queued before N was created, is served first (visit-first): \(kResult)")
        if case .failure(.insufficientSpace) = aResult {
        } else {
            Issue.record("A (N's waiter) gets the shortage (visit-first): \(aResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A transfer whose pause completes while a follow is owed resumes at its queue's front, as it does when the follow
    /// visits first (the cycle-9 amendment (a): a place that waits for the follow keeps `front`). One slot: P (prefetch)
    /// downloads, Q (prefetch) waits behind it. While the follow is owed (or after it, visit-first), P's attempt ends
    /// paused (the transport's `.paused`, delivered through `paused`). Visited first, P is queued at the front and starts
    /// again before Q. And a place taken while the follow is owed keeps the time it was requested at: a bulk request made
    /// before the clock moves 10 s is queued at that time, not at the follow's end, so bulk aging (`bulkAging`, 30 s)
    /// counts its whole wait (the clock stays short of it here, so the aged-bulk rule does not reorder the starts read).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a transfer whose pause completes during an owed follow resumes at its queue's front, and a deferred place keeps its request time (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierKeepsAPausedTransfersFrontPlace(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 963_502, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let pBytes = EngineFixture.bytes(963_510, count: 16)
        let qBytes = EngineFixture.bytes(963_511, count: 16)
        let bBytes = EngineFixture.bytes(963_512, count: 16)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let q = EngineHarness.onDemand("zz-q", qBytes)
        let b = EngineHarness.onDemand("zz-b", bBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(763_000) + [b, p, q], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // P's restart holds too: the test reads which transfer the freed slot went to, not a commit.
        await s.harness.source.script(p.transferID, [.hold, .hold, .stage(pBytes)])
        await s.harness.source.script(q.transferID, [.hold, .stage(qBytes)])
        await s.harness.source.script(b.transferID, [.hold, .stage(bBytes)])
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        // The source records a start when the attempt's driver reaches it, after the job is `downloading`.
        await engine.waitForHandle(p.transferID)
        let qWaiter = Task { await engine.awaitAsset(q.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[q.transferID]?.state == .queued }
        let attempt = try #require(await s.harness.source.starts.last { $0.id == p.transferID }, "setup: P's attempt started")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(863_000) + [b, p, q], s, visit: visit)
        let owedAtPause = await engine.readForTests { $0.followOwed }
        #expect(owedAtPause == (visit == .sweepFollowsFirst), "setup: the pause completes while the follow is owed only sweep-first")
        // P's attempt ends paused (as a preemption's pause does): `paused` queues it again at its queue's front, and
        // visit-first its own pump restarts it at once.
        let starts = await s.harness.source.starts.count
        let epoch = try #require(await engine.readForTests { $0.state.jobs[p.transferID]?.epoch })
        await engine.paused(p.transferID, epoch: epoch, request: attempt)
        // A bulk request made now, before the clock moves.
        let requestedAt = s.time.monotonicNow()
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .bulk) }
        await engine.awaitCondition { $0.state.jobs[b.transferID] != nil }
        s.time.advance(by: 10)
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { e in !e.followOwed && (e.state.jobs[p.transferID]?.state == .downloading || e.state.jobs[q.transferID]?.state == .downloading) }
        await engine.waitForAllHandles()
        let after = await engine.readForTests { e in
            (p: e.state.jobs[p.transferID]?.state, q: e.state.jobs[q.transferID]?.state, bQueuedAt: e.state.jobs[b.transferID]?.queuedAt, violations: e.invariantViolations())
        }
        let restarted = await s.harness.source.starts.dropFirst(starts).map(\.id)
        #expect(after.p == .downloading && after.q == .queued, "P, paused, resumes at its queue's front before Q: \(after)")
        #expect(restarted.first == p.transferID, "the next start is P's: \(restarted)")
        #expect(after.bQueuedAt == requestedAt, "the bulk request is queued at the time it was made, not when the follow ended: \(String(describing: after.bQueuedAt)) vs \(requestedAt)")
        #expect(after.violations.isEmpty, "\(after.violations.prefix(3))")
        await engine.shutdown()
        _ = await EngineHarness.value(of: pWaiter)
        _ = await EngineHarness.value(of: qWaiter)
        _ = await EngineHarness.value(of: bWaiter)
        _ = await EngineHarness.value(of: sync)
    }

    // MARK: Space verdicts (R-SYN-11)

    /// A reclaim's sweep judges a parked user job without the bytes in flight of a download the owed follow abandons: C
    /// (5 MB) downloads for A only with 7 MB of room; K (3 MB, user) waits `awaitingSpace` for 4 MB of a pruned blob. v3
    /// moves A to a 16-byte content while the follow owes C's visit; the room drops to 1 MB, and the reclaim leaves 5 MB.
    /// Visited first, C's bytes left and K fits. Judged beside C's bytes, K was parked and its waiter answered
    /// `insufficientSpace` (PROBE-D2-INFLIGHT-ABANDON).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a reclaim's sweep judges a parked user job without the bytes in flight of a download the owed follow abandons (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierSweepsWithoutTheBytesTheOwedVisitAbandons(_ visit: LaneDropVisit) async throws {
        try await Self.barrierAbandon(visit, reclaim: true)
    }

    /// A user request gated `awaitingSpace` while the follow owes the visit that abandons a download is decided by the
    /// reclaim's sweep on the followed state: C (5 MB) downloads for A only with 6 MB of room and 1,000 bytes pending
    /// reclaim; K (3 MB) is requested while the follow owes C's visit, and the grace then ends. Visited first, C's bytes
    /// left and K fits; decided beside them, K's waiter got a shortage (PROBE-D2-JOIN-ABANDON).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a user request parked awaiting space during an owed follow is decided by the reclaim's sweep on the followed state (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierSweepsARequestMadeDuringTheOwedFollow(_ visit: LaneDropVisit) async throws {
        try await Self.barrierAbandon(visit, reclaim: false)
    }

    /// The scenario of the two abandoned-download sweep tests (PROBE-D2-INFLIGHT-ABANDON and -JOIN-ABANDON): `reclaim`, K
    /// waits for the reclaim before the apply; otherwise K is requested while the follow is owed, with 1,000 bytes pending.
    @available(macOS 15.0, iOS 18.0, *)
    static func barrierAbandon(_ visit: LaneDropVisit, reclaim: Bool) async throws {
        let (s, _) = try await FollowBarrier.setUpWithX(xSize: reclaim ? 4_000_000 : 1_000, seed: 979_102)
        let engine = s.engine
        let cBytes = Data(repeating: 0x86, count: 5_000_000)
        let kBytes = Data(repeating: 0x87, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        // v2 prunes x: its bytes wait for the grace.
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(780_000) + [a, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 7 MB of room (4 MB pending) or 6 MB (1,000 bytes pending): C starts, K does not fit beside it.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(reclaim ? 7_000_000 : 6_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        var kWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        if reclaim {
            kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) }
        }
        // v3 moves A, C's only id, to a 16-byte content: the follow's visit abandons C's download.
        let nBytes = EngineFixture.bytes(979_104, count: 16)
        let n = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(n.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(880_000) + [n, k], s, visit: visit)
        let before = await engine.readForTests { engine in (owed: engine.followOwed, c: engine.state.jobs[a.transferID]?.state) }
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.c == nil, "setup: the follow abandoned C: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.c == .downloading, "setup: C still downloads, its visit owed: \(before)")
        }
        if reclaim {
            // 1 MB of room above the reserve before the reclaim: 5 MB after it, none beside C's 5 MB in flight.
            try await Self.leaveRoom(1_000_000, harness: s.harness, fileSystem: s.fileSystem)
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) || ($0.followOwed && $0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) }
            }
        } else {
            // K's request runs while the follow owes C's visit (its interest's token marks the request's turn).
            let tokenBefore = await engine.readForTests { $0.state.lastToken }
            kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
            await engine.awaitCondition { $0.state.lastToken > tokenBefore }
            // The grace ends while the follow is still owed; the reclaim's sweep decides K.
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { engine in
                    let state = engine.state.jobs[k.transferID]?.state
                    return (engine.state.freeSpace?.pendingReclaim == 0 && engine.state.spaceSweepFollowUp == nil && state != .blocked(.awaitingSpace) && state != .queued)
                        || (engine.followOwed && engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0)
                }
            }
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let waiter = try #require(kWaiter)
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K's user waiter is answered from its content: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// The new-content jobs an owed follow creates are created, and served, in the follow's order: C2 (earlier ticket)
    /// and C1, each 5 MB and wanted by one user waiter, wait `awaitingSpace` for 4 MB of a pruned blob with 2 MB of room;
    /// v3 moves A1 and A2 to new 3.5 MB contents, of which one fits after the reclaim. The follow's pass finds C1 first
    /// (entry order), so its visits create N1 before N2 and N1 is served. A sweep that followed the holders in its own
    /// order (rank, ticket) created N2 first and served it (PROBE-D2-FOLLOW-ORDER).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the new-content jobs an owed follow creates are created and served in the follow's order, whatever a sweep would judge first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierCreatesNewContentInTheFollowsOrder(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUpWithX(xSize: 4_000_000, seed: 979_002)
        let engine = s.engine
        let c1Bytes = Data(repeating: 0x82, count: 5_000_000)
        let c2Bytes = Data(repeating: 0x83, count: 5_000_000)
        let a1 = EngineHarness.onDemand("zz-a1", c1Bytes)
        let a2 = EngineHarness.onDemand("zz-a2", c2Bytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(770_000) + [a1, a2], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: s.harness, fileSystem: s.fileSystem)
        #expect(try await s.harness.store.freeSpace().pendingReclaim == 4_000_000, "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await s.harness.source.script(a1.transferID, [.stage(c1Bytes)])
        await s.harness.source.script(a2.transferID, [.stage(c2Bytes)])
        // A2's waiter first: C2's job takes the earlier ticket.
        let a2Waiter = Task { await engine.awaitAsset(a2.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a2.transferID]?.state == .blocked(.awaitingSpace) }
        let a1Waiter = Task { await engine.awaitAsset(a1.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a1.transferID]?.state == .blocked(.awaitingSpace) }
        let n1Bytes = Data(repeating: 0x84, count: 3_500_000)
        let n2Bytes = Data(repeating: 0x85, count: 3_500_000)
        let n1 = EngineHarness.onDemand("zz-a1", n1Bytes)
        let n2 = EngineHarness.onDemand("zz-a2", n2Bytes)
        await s.harness.source.script(n1.transferID, [.stage(n1Bytes)])
        await s.harness.source.script(n2.transferID, [.stage(n2Bytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(870_000) + [n1, n2], s, visit: visit)
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c1: engine.state.jobs[a1.transferID].map { (state: $0.state, ticket: $0.ticket) },
                c2: engine.state.jobs[a2.transferID].map { (state: $0.state, ticket: $0.ticket) },
                n1: engine.state.jobs[n1.transferID].map { (state: $0.state, ticket: $0.ticket) },
                n2: engine.state.jobs[n2.transferID].map { (state: $0.state, ticket: $0.ticket) }
            )
        }
        switch visit {
        case .followVisitedFirst:
            let n1Job = try #require(before.n1, "setup: the follow created N1's job")
            let n2Job = try #require(before.n2, "setup: the follow created N2's job")
            #expect(!before.owed && before.c1 == nil && before.c2 == nil && n1Job.ticket < n2Job.ticket, "setup: the follow visited C1 first: \(before)")
        case .sweepFollowsFirst:
            let c1Job = try #require(before.c1, "setup: C1's job waits")
            let c2Job = try #require(before.c2, "setup: C2's job waits")
            #expect(before.owed && before.n1 == nil && before.n2 == nil && c2Job.ticket < c1Job.ticket, "setup: C2 ranks before C1 in the sweep's order: \(before)")
        }
        // The grace ends: the alarm reaps x's 4 MB (6 MB of room) and runs its sweep.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { engine in
                engine.state.freeSpace?.pendingReclaim == 0 && engine.state.spaceSweepFollowUp == nil
                    && engine.state.jobs[a1.transferID] == nil && engine.state.jobs[a2.transferID] == nil
                    && engine.state.jobs[n1.transferID]?.state != .blocked(.awaitingSpace) && engine.state.jobs[n2.transferID]?.state != .blocked(.awaitingSpace)
                    || (engine.followOwed && engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0)
            }
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let a1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: a1Waiter) }
        let a2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: a2Waiter) }
        #expect((try? a1Result.get())?.byteSize == Int64(n1Bytes.count), "A1's waiter is answered from N1, whose job the follow created first: \(a1Result)")
        if case .failure(.insufficientSpace(let required, let available)) = a2Result {
            #expect(required == Int64(n2Bytes.count) && available < required, "A2's figures: \(a2Result)")
        } else {
            Issue.record("A2's waiter is answered insufficientSpace: N2 does not fit beside N1: \(a2Result)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A later apply's follow, begun while the follow still owes visits, keeps the owed visits in their order and appends
    /// the jobs it adds, sorted (the cycle-9 amendment (e)). 300 prefetch group members and two user holders, C1 (zz-a1)
    /// and C2 (zz-a2), wait for the one slot a user transfer holds; v3 changes every member's content and moves A1 and A2
    /// to new 3.5 MB contents, of which one fits the 6 MB of room. The follow's pass finds the members, then C1, then C2
    /// (entry order), and its first turn visits 256 of them. A second follow (`followApplied`, as a manifest catch-up's
    /// apply runs it) then restarts the visits. C2's transfer sorts before C1's. Visited first (the first follow ended
    /// before the second), C1's visit creates N1 before N2 and A1 is served; a restart that sorted the owed visits again
    /// visited C2 first and served A2 (SECOND-APPLY-REORDER).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a second follow begun while visits are owed keeps their order, so new contents are created and served as visit-first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierKeepsTheOwedVisitsOrderAcrossASecondFollow(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 962_502, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let slotBytes = EngineFixture.bytes(962_510, count: 16)
        let slot = EngineHarness.onDemand("zs", slotBytes)
        let a1 = EngineHarness.onDemand("zz-a1", EngineFixture.bytes(962_511, count: 16))
        // C2's transfer sorts before C1's, so a follow that sorts its owed visits visits C2 first.
        let a2 = try #require((0..<256).lazy.map { EngineHarness.onDemand("zz-a2", EngineFixture.bytes(962_600 + UInt64($0), count: 16)) }.first { $0.transferID < a1.transferID })
        let members = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(963_000 + UInt64($0), count: 16)) }
        let movedMembers = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(964_000 + UInt64($0), count: 16)) }
        await s.harness.serveManifest([s.q] + members + [slot, a1, a2], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 6 MB of room: N1 or N2 (3.5 MB each), not both.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(6_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(slot.transferID, [.hold, .stage(slotBytes)])
        for entry in members + movedMembers {
            await s.harness.source.script(entry.transferID, [.hold])
        }
        let slotWaiter = Task { await engine.awaitAsset(slot.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[slot.transferID]?.state == .downloading }
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { e in members.allSatisfy { e.state.jobs[$0.transferID]?.state == .queued } }
        let a1Waiter = Task { await engine.awaitAsset(a1.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a1.transferID]?.state == .queued }
        let a2Waiter = Task { await engine.awaitAsset(a2.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a2.transferID]?.state == .queued }
        let n1Bytes = Data(repeating: 0xA5, count: 3_500_000)
        let n2Bytes = Data(repeating: 0xA6, count: 3_500_000)
        let n1 = EngineHarness.onDemand("zz-a1", n1Bytes)
        let n2 = EngineHarness.onDemand("zz-a2", n2Bytes)
        await s.harness.source.script(n1.transferID, [.stage(n1Bytes)])
        await s.harness.source.script(n2.transferID, [.stage(n2Bytes)])
        let sync = await FollowBarrier.apply([s.q] + movedMembers + [slot, n1, n2], s, visit: visit)
        let before = await engine.readForTests { e in
            (owed: e.followOwed, c1: e.state.unfollowed.contains(a1.transferID), c2: e.state.unfollowed.contains(a2.transferID))
        }
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && !before.c1 && !before.c2, "setup: the follow visited C1 and C2: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.c1 && before.c2, "setup: the follow still owes C1's and C2's visits after its first turn: \(before)")
        }
        // A second follow restarts the visits from `unfollowed` while the first still owes them.
        let second = await engine.readForTests { e in
            e.followApplied(from: e.state.applied)
            return e.invariantViolations()
        }
        #expect(second.isEmpty, "\(second.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { e in !e.followOwed && e.state.jobs[n1.transferID] != nil && e.state.jobs[n2.transferID] != nil }
        let tickets = await engine.readForTests { e in (n1: e.state.jobs[n1.transferID]?.ticket, n2: e.state.jobs[n2.transferID]?.ticket) }
        #expect((tickets.n1 ?? .max) < (tickets.n2 ?? .max), "the follow created N1 before N2, as visit-first: \(tickets)")
        // The slot frees: the user queue's head starts, and the other new content does not fit beside it.
        await s.harness.source.release(slot.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineHarness.value(of: slotWaiter)
        let a1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: a1Waiter) }
        let a2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: a2Waiter) }
        #expect((try? a1Result.get())?.byteSize == Int64(n1Bytes.count), "A1 is served from N1, created first in the follow's order: \(a1Result)")
        if case .failure(.insufficientSpace(let required, let available)) = a2Result {
            #expect(required == Int64(n2Bytes.count) && available < required, "A2's figures: \(a2Result)")
        } else {
            Issue.record("A2 gets insufficientSpace: N2 does not fit beside N1 (visit-first): \(a2Result)")
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.releaseGroup(group)
        await engine.shutdown()
        _ = await EngineHarness.value(of: sync)
    }

    /// An ENOSPC during an owed follow is decided on the room the follow's visits leave: D (4 MB, wanted only by A's user
    /// waiter) downloads and E (1.5 MB, U's user waiter) downloads beside it in 6 MB of room. v3 moves A to a 16-byte
    /// content while the follow owes D's visit; the volume then shrinks to 5 MB and E's attempt fails ENOSPC. Visited
    /// first, D is superseded, E's room is 5 MB and the ENOSPC is retried: U is served. Decided first, E's room was 1 MB
    /// (D's 4 MB in flight) and E was parked `insufficientSpace`, U answered with that shortage (PROBE-D-ENOSPC).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an ENOSPC during an owed follow is decided on the room the follow's visits leave (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesAnENOSPCOnTheFollowedState(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 994_002)
        let engine = s.engine
        let dBytes = Data(repeating: 0x95, count: 4_000_000)
        let eBytes = Data(repeating: 0x96, count: 1_500_000)
        let a = EngineHarness.onDemand("zz-a", dBytes)
        let e = EngineHarness.onDemand("zz-e", eBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(790_000) + [a, e], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(6_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(dBytes)])
        await s.harness.source.script(e.transferID, [.hold, .fail(.insufficientSpace(requiredBytes: Int64(eBytes.count))), .stage(eBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let uWaiter = Task { await engine.awaitAsset(e.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[e.transferID]?.state == .downloading }
        let replacementBytes = EngineFixture.bytes(994_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await s.harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(890_000) + [replacement, e], s, visit: visit)
        // The volume shrinks to 5 MB above the reserve, then E's attempt fails ENOSPC.
        try await Self.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
        let shrunk = try await s.harness.store.freeSpace().volumeImportant
        await s.harness.source.release(e.transferID, with: .progress(received: 0, expected: nil))
        // The ENOSPC's own free-space read is adopted when it returns (its verdict, or its wait, is in the same turn). It
        // reads at most `shrunk`: visit-first, A's 16-byte replacement and the settled run may still commit to the volume
        // after it was measured (under TSan in the whole Sync bundle an exact match never came, cycle 9).
        await engine.awaitCondition { $0.state.jobs[e.transferID]?.state != .downloading && ($0.state.freeSpace?.volumeImportant ?? .max) <= shrunk }
        let between = await engine.readForTests { engine in engine.invariantViolations() }
        #expect(between.isEmpty, "\(between.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? uResult.get())?.byteSize == Int64(eBytes.count), "the ENOSPC is retried in the room the follow frees, and U is served: \(uResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A: \(aResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: Failures (R-SYN-11)

    /// A transient failure of a moved id's holder while the follow owes an earlier visit brings no visit forward: D
    /// (4 MB, zz-a) and C (2 MB, zz-b) download with 7 MB of room; P (3.5 MB) is a prefetch group's member parked
    /// `insufficientSpace` beside them. v3 moves A to a 16-byte content (D's visit abandons D) and B onto P's content, in
    /// that order. C's attempt then fails (transient). Visited first, D's bytes left before B's interest joined P, so P
    /// fits and B is served. With the failure first, `countFailedAttempt` followed C out of the follow's order: B's
    /// interest joined P beside D's doomed bytes and was answered with a shortage (PROBE-J-FAIL-REROUTE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a transient failure of a moved id's holder during an owed follow re-routes the moved interest in the follow's order (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierReroutesAFailedHoldersInterestInTheFollowsOrder(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 961_002)
        let engine = s.engine
        let dBytes = Data(repeating: 0x91, count: 4_000_000)
        let cBytes = Data(repeating: 0x92, count: 2_000_000)
        let pBytes = Data(repeating: 0x93, count: 3_500_000)
        // zz-a's job D (4 MB) is abandoned by its visit; zz-b's job C (2 MB) moves onto P's content.
        let a = EngineHarness.onDemand("zz-a", dBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(710_000) + [a, b, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 7 MB of room: D (4 MB) and C (2 MB) run; P (3.5 MB) is parked `insufficientSpace` beside them (1 MB).
        _ = try await EngineRegressionCycle6Tests.leaveRoom(7_000_000, harness: s.harness, fileSystem: s.fileSystem)
        #expect(try await s.harness.store.freeSpace().pendingReclaim == 0, "setup: nothing waits for a reclaim")
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(dBytes)])
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state == .downloading }
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.insufficientSpace) }
        let aNewBytes = EngineFixture.bytes(961_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", aNewBytes)
        let bMoved = EngineHarness.onDemand("zz-b", pBytes)
        try #require(bMoved.transferID == p.transferID, "setup: B's new content is P's")
        await s.harness.source.script(aMoved.transferID, [.stage(aNewBytes)])
        // v3: zz-a (D) before zz-b (C) in the replaced copy's order, so the follow abandons D before it re-routes B onto P.
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(810_000) + [aMoved, bMoved, p], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in
                (owed: e.followOwed, d: e.state.jobs[a.transferID]?.state, c: e.state.jobs[b.transferID]?.state)
            }
            #expect(before.owed && before.d == .downloading && before.c == .downloading, "setup: D and C still run and their visits are owed: \(before)")
            // C's attempt fails (transient) while the follow owes both visits.
            await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
            let between = await engine.readForTests { $0.invariantViolations() }
            #expect(between.isEmpty, "\(between.prefix(3))")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(pBytes.count), "B's user waiter, moved onto P, is answered from P's 3.5 MB (visit-first): \(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A failure brings no visit forward, so the new contents of two moved holders are created in the follow's order: C1
    /// (zz-a1) and C2 (zz-a2), 5 MB each, download for one user waiter each in 11 MB of room; v3 moves both to new 6 MB
    /// contents, of which one fits once both left. C2's attempt then fails (transient). Visited first, the follow visits
    /// C1 first, N1 is created and served first and A2 gets a shortage. With the failure first, C2's visit was brought
    /// forward and N2 took the room (PROBE-J-FAIL-TICKET).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a failure during an owed follow brings no visit forward: the new contents of two moved holders are created in the follow's order (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierCreatesAFailedHoldersNewContentInTheFollowsOrder(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 962_002)
        let engine = s.engine
        let c1Bytes = Data(repeating: 0xA1, count: 5_000_000)
        let c2Bytes = Data(repeating: 0xA2, count: 5_000_000)
        let a1 = EngineHarness.onDemand("zz-a1", c1Bytes)
        let a2 = EngineHarness.onDemand("zz-a2", c2Bytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(720_000) + [a1, a2], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 11 MB of room: C1 and C2 (5 MB each) run. After both leave, N1 or N2 (6 MB each) fits, not both.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(11_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(a1.transferID, [.hold, .stage(c1Bytes)])
        await s.harness.source.script(a2.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(c2Bytes)])
        let a1Waiter = Task { await engine.awaitAsset(a1.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a1.transferID]?.state == .downloading }
        let a2Waiter = Task { await engine.awaitAsset(a2.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a2.transferID]?.state == .downloading }
        let n1Bytes = Data(repeating: 0xA3, count: 6_000_000)
        let n2Bytes = Data(repeating: 0xA4, count: 6_000_000)
        let n1 = EngineHarness.onDemand("zz-a1", n1Bytes)
        let n2 = EngineHarness.onDemand("zz-a2", n2Bytes)
        await s.harness.source.script(n1.transferID, [.stage(n1Bytes)])
        await s.harness.source.script(n2.transferID, [.stage(n2Bytes)])
        // v3 moves both: the follow visits C1 (zz-a1) before C2 (zz-a2), so visit-first N1 is created and served first.
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(820_000) + [n1, n2], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in (owed: e.followOwed, c2: e.state.jobs[a2.transferID]?.state) }
            #expect(owed.owed && owed.c2 == .downloading, "setup: C2 runs and its visit is owed: \(owed)")
            // C2's attempt fails while its visit, and C1's, are owed.
            await s.harness.source.release(a2.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[a2.transferID]?.state != .downloading }
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let a1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: a1Waiter) }
        let a2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: a2Waiter) }
        #expect((try? a1Result.get())?.byteSize == Int64(n1Bytes.count), "A1 is served from N1, created first by the follow (visit-first): \(a1Result)")
        if case .failure(.insufficientSpace) = a2Result {
        } else {
            Issue.record("A2 gets insufficientSpace: N2 does not fit beside N1 (visit-first): \(a2Result)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: A second follow and shutdown

    /// A second follow begun while the first still owes its pass keeps the barrier: the setup of the cycle-8 DROPPED-LANE
    /// test (C, 5 MB, user through A, prefetch through B; K, 3 MB, user; 4 MB of important and 12 MB of opportunistic
    /// room after the reclaim; v3 drops A) in the sweep-first order, plus a second follow (`followApplied` from the copy,
    /// as a later apply restarts the follow's visits) between the reclaim and the follow's release. K and B are served, A
    /// gets `.notFound`, and nothing waits for a follow once everything settled (PROBE-D-REFOLLOW). The second follow has
    /// no visit-first counterpart, so the test runs in the sweep-first order only.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a second follow begun while the first still owes visits keeps the barrier, and every waiter gets the visit-first answer (F-28)", .timeLimit(.minutes(3)))
    func barrierHoldsAcrossASecondFollow() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 26_000_000, opportunisticCapacity: reserve + 34_000_000))
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x71, count: 4_000_000)
        let qBytes = EngineFixture.bytes(992_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let cBytes = Data(repeating: 0x72, count: 5_000_000)
        let kBytes = Data(repeating: 0x73, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await harness.serveManifest([q] + FollowBarrier.fillers(742_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.assets.count == 2 }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) }
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + FollowBarrier.fillers(842_000) + [b, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) || ($0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) }
        }
        // A second follow restarts the visits from `unfollowed` while the first may still owe its pass.
        let second = await engine.readForTests { engine in
            engine.followApplied(from: engine.state.applied)
            return engine.invariantViolations()
        }
        #expect(second.isEmpty, "\(second.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K: \(kResult)")
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B is served from the opportunistic room: \(bResult)")
        #expect(aResult == .failure(.notFound), "A: \(aResult)")
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        let settled = await engine.readForTests { engine in (owed: engine.followOwed, violations: engine.invariantViolations()) }
        #expect(!settled.owed && settled.violations.isEmpty, "\(settled)")
        await engine.shutdown()
    }

    /// Shutdown while requests, joins and sweeps wait for an owed follow answers every waiter and returns: the cycle-7
    /// RANK-ADMIT setup in the sweep-first order (the reclaim's sweep waits for the follow), plus a user waiter joined to a
    /// job parked for space (a prefetch group's E, 30 MB) whose answer waits too; then shutdown with the follow's turns
    /// still held (PROBE-D-SHUTDOWN). Shutdown has no visit-first counterpart, so the test runs in one order.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: shutdown while requests, joins and sweeps wait for an owed follow answers every waiter (F-28)", .timeLimit(.minutes(3)))
    func barrierAnswersEveryWaiterAtShutdown() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000))
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x71, count: 4_000_000)
        let qBytes = EngineFixture.bytes(993_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let cBytes = Data(repeating: 0x72, count: 5_000_000)
        let kBytes = Data(repeating: 0x73, count: 3_000_000)
        let eBytes = Data(repeating: 0x74, count: 30_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        let e = EngineHarness.onDemand("zz-e", eBytes)
        await harness.serveManifest([q] + FollowBarrier.fillers(743_000) + [a, e, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) }
        let group = try await engine.registerGroup([e.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[e.transferID]?.state.isSpaceParked == true }
        let replacement = EngineHarness.onDemand("zz-a", EngineFixture.bytes(993_004, count: 16))
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + FollowBarrier.fillers(843_000) + [replacement, e, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) || ($0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) }
        }
        let tokens = await engine.readForTests { $0.state.lastToken }
        let joiner = Task { await engine.awaitAsset(e.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.lastToken > tokens }
        await engine.shutdown()
        let kResult = await EngineHarness.value(of: kWaiter)
        let aResult = await EngineHarness.value(of: aWaiter)
        let jResult = await EngineHarness.value(of: joiner)
        _ = await EngineHarness.value(of: sync)
        #expect(kResult == .failure(.shutDown) || (try? kResult.get()) != nil, "K: \(kResult)")
        #expect(aResult == .failure(.shutDown), "A: \(aResult)")
        let joinerAnswered: Bool
        switch jResult {
        case .failure(.shutDown), .failure(.insufficientSpace):
            joinerAnswered = true
        default:
            joinerAnswered = false
        }
        #expect(joinerAnswered, "the joiner: \(jResult)")
        let after = await engine.readForTests { engine in (waiters: engine.state.waiters.count, jobs: engine.state.jobs.count) }
        #expect(after.waiters == 0, "\(after)")
        _ = group
    }
}
