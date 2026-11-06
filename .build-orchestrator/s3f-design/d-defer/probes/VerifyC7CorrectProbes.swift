import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

// D1 ADAPTATION (design probe): the first wait after the reclaim also ends once the alarm's store work is over and its read adopted, so a
// sweep the design leaves to the follow's end does not hang the wait while the follow's turns are held; the original releases below then end the follow.
@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 7, correctness lens). Never committed.
///
/// PROBE-C7-RANK: `sweepSpaceParked` sorts its candidates by `queueRank` read BEFORE the owed follow (`candidates` is
/// built and sorted once). A job whose user lane comes only from a moved id is judged first as user work; its follow
/// lowers it to prefetch; it still fits (the first branch, or the cycle-7 park-branch re-queue), so it is re-queued and
/// its bytes are counted `ahead` of the user jobs ranked after it, which the pump would serve before it. The next user
/// job K is then judged against the room minus the prefetch job's bytes, parked `insufficientSpace`, and its fail-fast
/// answers K's user waiter with a shortage while the prefetch job takes the room. When the follow visited first the
/// same sweep serves K first (rank 0) and the prefetch job does not fit.
@Suite("VerifyC7CorrectProbes", .serialized)
struct VerifyC7CorrectProbes {
    /// First branch (pre-follow verdict admits; equal volume readings).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C7-RANK-ADMIT: a followed job lowered to prefetch is not admitted ahead of a user job", .timeLimit(.minutes(3)), arguments: [true, false])
    func rankAdmit(_ visitFirst: Bool) async throws {
        try await Self.run(visitFirst: visitFirst, importantExtra: 32_000_000, opportunisticExtra: 32_000_000, leave: 2_000_000, leaveAgain: 1_999_000, kSize: 3_000_000, tag: "admit")
    }

    /// The cycle-7 park-branch re-queue (pre-follow verdict refuses on the important volume; the opportunistic one has
    /// 4 MB more room).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C7-RANK-PARK: a parked-branch job re-queued on its new lane is not admitted ahead of a user job", .timeLimit(.minutes(3)), arguments: [true, false])
    func rankPark(_ visitFirst: Bool) async throws {
        try await Self.run(visitFirst: visitFirst, importantExtra: 26_000_000, opportunisticExtra: 30_000_000, leave: 0, leaveAgain: nil, kSize: 3_900_000, tag: "park")
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func run(visitFirst: Bool, importantExtra: Int64, opportunisticExtra: Int64, leave: Int64, leaveAgain: Int64?, kSize: Int, tag: String) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + importantExtra, opportunisticCapacity: reserve + opportunisticExtra)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
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
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x72, count: 5_000_000)
        let kBytes = Data(repeating: 0x73, count: kSize)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        await harness.serveManifest([q] + fillers(740_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(leave, harness: harness, fileSystem: fileSystem)
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
        let replacementBytes = EngineFixture.bytes(977_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(840_000) + [replacement, b, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visitFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                cLane: engine.state.jobs[a.transferID]?.lane,
                cRank: engine.state.jobs[a.transferID].map { engine.queueRank($0) },
                cTicket: engine.state.jobs[a.transferID]?.ticket,
                kRank: engine.state.jobs[k.transferID].map { engine.queueRank($0) },
                kTicket: engine.state.jobs[k.transferID]?.ticket,
                c: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state
            )
        }
        print("PROBE-C7-RANK-\(tag) visitFirst=\(visitFirst) before: \(before)")
        #expect(before.c == .blocked(.awaitingSpace) && before.k == .blocked(.awaitingSpace), "setup: \(before)")
        if let leaveAgain {
            try await EngineSyncTests.leaveRoom(leaveAgain, harness: harness, fileSystem: fileSystem)
        }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) || ($0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) }
        }
        let afterSweep = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                cLane: engine.state.jobs[a.transferID]?.lane,
                c: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state,
                kError: engine.state.jobs[k.transferID]?.lastError,
                space: engine.state.freeSpace,
                violations: engine.invariantViolations()
            )
        }
        print("PROBE-C7-RANK-\(tag) visitFirst=\(visitFirst) afterSweep: \(afterSweep)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-C7-RANK-\(tag) visitFirst=\(visitFirst) kResult: \(kResult) bResult: \(bResult) aResult: \(aResult)")
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "PROBE-C7-RANK-\(tag): K's user waiter is served before C's prefetch-only job takes the room: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        #expect(afterSweep.violations.isEmpty, "\(afterSweep.violations.prefix(3))")
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }

    /// PROBE-C7-RANK-PROMOTE: the mirror case. The follow of the job judged first (C, wanted only by A's user waiter)
    /// moves A onto P's content, whose parked job (prefetch, ranked after R) becomes user-lane. Its place in the sorted
    /// candidates is still the prefetch one, so R (prefetch, earlier ticket) takes the room first and P is parked: A's
    /// user waiter is answered `insufficientSpace`. Followed first, P is user-lane at the sort, judged before R and fits.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C7-RANK-PROMOTE: a parked job a sweep's follow raised to user work is judged before prefetch work", .timeLimit(.minutes(3)), arguments: [true, false])
    func rankPromote(_ visitFirst: Bool) async throws {
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
        if visitFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c: engine.state.jobs[a.transferID].map { ($0.state, engine.queueRank($0), $0.ticket) },
                r: engine.state.jobs[r.transferID].map { ($0.state, engine.queueRank($0), $0.ticket) },
                p: engine.state.jobs[p.transferID].map { ($0.state, engine.queueRank($0), $0.ticket, $0.lane) }
            )
        }
        print("PROBE-C7-RANK-PROMOTE visitFirst=\(visitFirst) before: \(before)")
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[r.transferID]?.state != .blocked(.awaitingSpace) || ($0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) }
        }
        let afterSweep = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                r: engine.state.jobs[r.transferID]?.state,
                p: engine.state.jobs[p.transferID].map { ($0.state, $0.lane) },
                space: engine.state.freeSpace,
                violations: engine.invariantViolations()
            )
        }
        print("PROBE-C7-RANK-PROMOTE visitFirst=\(visitFirst) afterSweep: \(afterSweep)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C7-RANK-PROMOTE visitFirst=\(visitFirst) aResult: \(aResult) rResult: \(rResult) pResult: \(pResult)")
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "PROBE-C7-RANK-PROMOTE: A's user waiter, moved onto P, is served before R's prefetch job takes the room: \(aResult)")
        #expect(afterSweep.violations.isEmpty, "\(afterSweep.violations.prefix(3))")
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }
}
