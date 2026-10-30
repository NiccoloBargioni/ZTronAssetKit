import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The order a space sweep judges parked jobs in while a follow is owed (R-SYN-11, F-28: re-admissions follow the pump's
/// order). A follow changes ranks two ways: the followed job loses the moved user interest and may drop to prefetch, and
/// the parked job of the moved id's new content gains it and may rise to user. A sweep that sorted its candidates before
/// the follows it performs judged each job at its old place: prefetch work was admitted, and counted ahead, before user
/// work the pump serves first, and a user job's fail-fast answered its waiter with a shortage although the room existed
/// for it (the close-out cycle-7 correctness lens, PROBE-C7-RANK-ADMIT, -PARK and -PROMOTE). When the follow visited
/// first, the same sweep served the user work. At `s3-base` the follow moved every job in the apply's turn, so neither
/// window existed.
extension EngineSyncTests {
    /// The room and sizes of one lowered-rank scenario (`sweepJudgesALoweredJobAtItsNewPlace`).
    struct LoweredRank: Sendable {
        /// The important volume's capacity above the reserve.
        let importantExtra: Int64
        /// The opportunistic volume's capacity above the reserve.
        let opportunisticExtra: Int64
        /// The important room left above the reserve while the jobs park (the opportunistic one follows the capacities).
        let leave: Int64
        /// The important room left just before the reclaim, when it differs from `leave`.
        let leaveAgain: Int64?
        /// K's size.
        let kSize: Int
    }

    /// A space sweep that follows a job judges it at the place the follow leaves it in the pump's order, not at the user
    /// place it held before: C (5 MB) is wanted by A (a user waiter) and B (a prefetch waiter), so its job is user-lane
    /// and, with the earlier ticket, ranked before K (3 MB, a user waiter). Both wait `awaitingSpace` for 4 MB of a
    /// pruned blob. A forced sync moves A to a 16-byte content while 2,100 changed entries sort before it, so the bounded
    /// follow owes C's visit (its turns held). Equal volume readings and 2 MB of room: the reclaim leaves just under 6 MB.
    /// Followed first, C's job is prefetch-lane and judged after K: K fits, and C (5 MB against the 3 MB left) is parked.
    /// Sorted before its follow, C fitted as user work, was followed to prefetch, still fitted, and was re-queued and
    /// counted ahead of K, whose waiter was answered `insufficientSpace(required: 3000000, available: 999000)` (the
    /// close-out cycle-7 correctness lens, PROBE-C7-RANK-ADMIT; it fails the same way on the cycle-6 code).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a space sweep judges a job its follow lowers to prefetch at its prefetch place, so the user job behind it is admitted first (F-28)", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func spaceSweepAdmitsUserWorkBeforeAJobItsFollowLowers(_ visit: LaneDropVisit) async throws {
        try await Self.sweepJudgesALoweredJobAtItsNewPlace(
            visit,
            LoweredRank(importantExtra: 32_000_000, opportunisticExtra: 32_000_000, leave: 2_000_000, leaveAgain: 1_999_000, kSize: 3_000_000)
        )
    }

    /// The park branch's form of `spaceSweepAdmitsUserWorkBeforeAJobItsFollowLowers`: C does not fit as user work, so the
    /// sweep reached its park branch, followed it there (A left: prefetch) and re-queued it on the opportunistic room,
    /// which the readings leave 4 MB larger (the two are not ordered). The reclaim leaves 4 MB of important room and 8 MB
    /// of opportunistic room. Followed first, C is judged after K: K (3.9 MB) fits, and C (5 MB against the 4.1 MB left)
    /// is parked and its prefetch waiter answered `insufficientSpace(required: 5000000, available: 4099987)`. Sorted
    /// before its follow, C was re-queued and counted ahead of K, whose user waiter was answered
    /// `insufficientSpace(required: 3900000, available: 0)` (the close-out cycle-7 correctness lens, PROBE-C7-RANK-PARK:
    /// the cycle-7 park-branch re-queue traded PROBE-C6-LANEGAIN's contradictory figures for a shortage answered to user
    /// work).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a space sweep's park branch judges a job its follow lowers to prefetch at its prefetch place, so the user job behind it is admitted first (F-28)", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func spaceSweepParkBranchAdmitsUserWorkBeforeAJobItsFollowLowers(_ visit: LaneDropVisit) async throws {
        try await Self.sweepJudgesALoweredJobAtItsNewPlace(
            visit,
            LoweredRank(importantExtra: 26_000_000, opportunisticExtra: 30_000_000, leave: 0, leaveAgain: nil, kSize: 3_900_000)
        )
    }

    /// The scenario of the two lowered-rank tests: the setup, both waiters' answers and the invariants.
    @available(macOS 15.0, iOS 18.0, *)
    static func sweepJudgesALoweredJobAtItsNewPlace(_ visit: LaneDropVisit, _ scenario: LoweredRank) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + scenario.importantExtra, opportunisticCapacity: reserve + scenario.opportunisticExtra)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        // Megabytes of one repeated byte: generated payloads of this size took seconds of the sanitizer run (S3-R4).
        let xBytes = Data(repeating: 0x71, count: 4_000_000)
        let qBytes = EngineFixture.bytes(977_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // Changed on-demand entries without jobs that sort before A: the follow's first pass formats
        // `followFormatsPerTurn` of them and stops before A's entry.
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x72, count: 5_000_000)
        let kBytes = Data(repeating: 0x73, count: scenario.kSize)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        // v2 prunes x (its 4 MB wait for the 60 s grace) and lists C under A and B, and K.
        await harness.serveManifest([q] + fillers(740_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(scenario.leave, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.assets.count == 2 }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) }
        // v3 moves A to a 16-byte content; B and K keep theirs.
        let replacementBytes = EngineFixture.bytes(977_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(840_000) + [replacement, b, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            // The follow's turns are owned tasks, not timers: the clock stays before the grace's end.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c: engine.state.jobs[a.transferID].map { (state: $0.state, rank: engine.queueRank($0), ticket: $0.ticket) },
                k: engine.state.jobs[k.transferID].map { (state: $0.state, rank: engine.queueRank($0), ticket: $0.ticket) }
            )
        }
        let c = try #require(before.c, "setup: C's job waits")
        let kJob = try #require(before.k, "setup: K's job waits")
        #expect(c.state == .blocked(.awaitingSpace) && kJob.state == .blocked(.awaitingSpace), "setup: \(before)")
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && c.rank > kJob.rank, "setup: the follow moved A, and C's prefetch job ranks after K's: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && c.rank == kJob.rank && c.ticket < kJob.ticket, "setup: C's job still holds A and ranks before K's: \(before)")
        }
        if let again = scenario.leaveAgain {
            // Just under the room in both cases: a follow that visited first may already have committed A's 16 bytes.
            try await Self.leaveRoom(again, harness: harness, fileSystem: fileSystem)
        }
        // The grace ends: the alarm reaps x's 4 MB and runs its `.reclaimed` sweep.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) }
        }
        // K's job is gone either way once its waiter is answered (fetched, or failed fast): the waiters' answers decide.
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K's user waiter is answered from its content: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        if case .failure(.insufficientSpace(let required, let available)) = bResult {
            #expect(required == Int64(cBytes.count) && available < required, "B's figures are C's 5 MB against the room K leaves: \(bResult)")
        } else {
            Issue.record("B's prefetch waiter is answered insufficientSpace: C's 5 MB do not fit beside K: \(bResult)")
        }
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }

    /// The mirror case: a space sweep that follows a job judges the parked job of the moved id's new content at the user
    /// place the moved interest gives it, not at its prefetch place. Parked `awaitingSpace` for 4 MB of a pruned blob with
    /// 2 MB of room: C (5 MB, wanted only by A's user waiter), R (3.5 MB, a prefetch waiter) and P (3 MB, a prefetch
    /// waiter), in that ticket order. A forced sync moves A onto P's content while 2,100 changed entries sort before it,
    /// so the bounded follow owes C's visit (its turns held). The reclaim leaves 6 MB. Followed first, C is superseded,
    /// A's interest makes P user-lane, P is judged first and fits, and R (3.5 MB against the 3 MB left) is parked. Sorted
    /// before the follow, P was judged at its prefetch place after R, R took the room, and A's user waiter was answered
    /// `insufficientSpace(required: 3000000, available: 2500000)` (the close-out cycle-7 correctness lens,
    /// PROBE-C7-RANK-PROMOTE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a space sweep judges the parked job its follow raises to user work at its user place, before prefetch work (F-28)", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func spaceSweepJudgesAJobItsFollowRaisesAtItsUserPlace(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x74, count: 4_000_000)
        let qBytes = EngineFixture.bytes(978_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x75, count: 5_000_000)
        let rBytes = Data(repeating: 0x76, count: 3_500_000)
        let pBytes = Data(repeating: 0x77, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        // v2 prunes x (its 4 MB wait for the 60 s grace) and lists C, P and R.
        await harness.serveManifest([q] + fillers(760_000) + [a, p, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(r.transferID, [.stage(rBytes)])
        await harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state == .blocked(.awaitingSpace) }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.awaitingSpace) }
        // v3 moves A onto P's content; P and R keep theirs.
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(860_000) + [moved, p, r], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            // The follow's turns are owned tasks, not timers: the clock stays before the grace's end.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c: engine.state.jobs[a.transferID]?.state,
                r: engine.state.jobs[r.transferID].map { (state: $0.state, rank: engine.queueRank($0), ticket: $0.ticket) },
                p: engine.state.jobs[p.transferID].map { (state: $0.state, rank: engine.queueRank($0), ticket: $0.ticket) }
            )
        }
        let rJob = try #require(before.r, "setup: R's job waits")
        let pJob = try #require(before.p, "setup: P's job waits")
        #expect(rJob.state == .blocked(.awaitingSpace) && pJob.state == .blocked(.awaitingSpace) && rJob.ticket < pJob.ticket, "setup: \(before)")
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.c == nil && pJob.rank < rJob.rank, "setup: the follow superseded C and A's interest raised P: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.c == .blocked(.awaitingSpace) && pJob.rank == rJob.rank, "setup: C's job still holds A, and P ranks as prefetch work: \(before)")
        }
        // The grace ends: the alarm reaps x's 4 MB (6 MB of room) and runs its `.reclaimed` sweep.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[r.transferID]?.state != .blocked(.awaitingSpace) }
        }
        // P's job is gone either way once its waiters are answered (fetched, or failed fast): the waiters' answers decide.
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "A's user waiter, moved onto P, is answered from P's 3 MB: \(aResult)")
        #expect((try? pResult.get())?.byteSize == Int64(pBytes.count), "P's prefetch waiter is answered from its content: \(pResult)")
        if case .failure(.insufficientSpace(let required, let available)) = rResult {
            #expect(required == Int64(rBytes.count) && available < required, "R's figures are its 3.5 MB against the room P leaves: \(rResult)")
        } else {
            Issue.record("R's prefetch waiter is answered insufficientSpace: its 3.5 MB do not fit beside P: \(rResult)")
        }
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }

    /// A space sweep counts the bytes of a followed job it re-queues ahead of the jobs it judges after it, as it does for
    /// any re-queued job. The setup of `spaceSweepRequeuesAFollowedJobItsNewLaneFits` (C, 5 MB, wanted by A's user waiter
    /// and B's prefetch waiter; no room for user work, 6 MB for prefetch work, 4 MB pending reclaim; A moved to a 16-byte
    /// content while the bounded follow owes C's visit) plus D (7 MB, a prefetch waiter) parked `awaitingSpace` behind C.
    /// After the reclaim prefetch work has 10 MB: C fits its prefetch lane and is re-queued; counted ahead, it leaves D
    /// 5 MB, so D is parked `insufficientSpace` in the sweep's own turn and its fail-fast answers D's waiter with D's 7 MB
    /// against that room. A re-queue that did not count C ahead re-queued D too, over-admitting the room until the gate
    /// parked it again (the close-out cycle-7 requirements lens, PROBE-C7R-GAIN-AHEAD, mutant `gainNoAhead`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a space sweep counts a followed job it re-queues ahead of the next parked job, which is parked in the sweep's turn when the room left does not hold it (F-22)", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func spaceSweepCountsAFollowedJobAheadOfTheNextOne(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 26_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x79, count: 4_000_000)
        let qBytes = EngineFixture.bytes(893_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x65, count: 5_000_000)
        let dBytes = Data(repeating: 0x66, count: 7_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        // v2 prunes x (its 4 MB wait for the 60 s grace) and lists C under A and B, and D.
        await harness.serveManifest([q] + fillers(730_000) + [a, b, d], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        // No room for user work, 6 MB for prefetch work.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(d.transferID, [.stage(dBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.assets.count == 2 }
        let dWaiter = Task { await engine.awaitAsset(d.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[d.transferID]?.state == .blocked(.awaitingSpace) }
        // v3 moves A to a 16-byte content; B and D keep theirs.
        let replacementBytes = EngineFixture.bytes(893_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(830_000) + [replacement, b, d], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            // The follow's turns are owned tasks, not timers: the clock stays before the grace's end.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c: engine.state.jobs[a.transferID].map { (state: $0.state, ticket: $0.ticket) },
                d: engine.state.jobs[d.transferID].map { (state: $0.state, ticket: $0.ticket) }
            )
        }
        let c = try #require(before.c, "setup: C's job waits")
        let dJob = try #require(before.d, "setup: D's job waits")
        #expect(c.state == .blocked(.awaitingSpace) && dJob.state == .blocked(.awaitingSpace) && c.ticket < dJob.ticket, "setup: \(before)")
        #expect(before.owed == (visit == .sweepFollowsFirst), "setup: \(before)")
        // The grace ends: the alarm reaps x's 4 MB (4 MB of room for user work, 10 MB for prefetch work) and runs its
        // `.reclaimed` sweep. D's job is read in the first turn whose condition check sees C leave its wait: the sweep's.
        let watch = SweepTurnWatch()
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { engine in
                guard engine.state.jobs[a.transferID]?.state != .blocked(.awaitingSpace) else {
                    return false
                }
                watch.record(engine.state.jobs[d.transferID]?.state)
                return true
            }
        }
        #expect(watch.state == nil || watch.state == .blocked(.insufficientSpace), "in the sweep's turn D (7 MB) is judged behind C's 5 MB of the 10 MB of prefetch room and parked (its fail-fast ends the job), never re-queued: \(String(describing: watch.state))")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let dResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: dWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B's prefetch waiter is answered from C's 5 MB: \(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        if case .failure(.insufficientSpace(let required, let available)) = dResult {
            #expect(required == Int64(dBytes.count) && available < required, "D's figures are its 7 MB against the room C leaves: \(dResult)")
        } else {
            Issue.record("D's prefetch waiter is answered insufficientSpace: its 7 MB do not fit beside C: \(dResult)")
        }
        #expect(!(await harness.source.starts.map(\.id)).contains(d.transferID), "D's content never started without room")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }
}
