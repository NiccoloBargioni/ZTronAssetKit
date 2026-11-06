import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probe (s3f close-out verification, cycle 5, correctness lens). Never committed.
///
/// PROBE-C5-LANEDROP: one 5 MB content C listed by two ids: A (a user waiter) and B (a prefetch group), so its job J is
/// user-lane. K (3 MB, a user waiter) waits behind it. Both are parked `awaitingSpace`: 2 MB of important room, 4 MB of a
/// pruned blob pending, and an opportunistic volume 6 MB smaller than the important one (0 room for prefetch work). A
/// forced sync moves A to a 16-byte content while 2,100 changed fillers sort before it, so the bounded follow owes J's
/// visit (held). The reclaim frees 4 MB: 6 MB of important room, still 0 opportunistic.
///
/// The right outcome is the one the sweep gives when the follow has already visited J (`visitFirst`): J is prefetch-lane
/// (only B wants C), does not fit the opportunistic room and is parked; K fits the 6 MB and is fetched: K's waiter gets
/// success. During the owed follow (`!visitFirst`) the sweep computes J's verdict on its pre-follow user lane (fits), then
/// follows J (`followBeforeActing`: A leaves, J keeps B and becomes prefetch) and re-queues it with its 5 MB counted
/// `ahead`; K is then judged against 6 - 5 = 1 MB and parked `insufficientSpace`, and its fail-fast answers K's waiter
/// with `insufficientSpace(required: 3 MB, available: 1 MB)` although 6 MB are free and J never takes them.
@Suite("VerifyC5CorrectSyncProbes", .serialized)
struct VerifyC5CorrectSyncProbes {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C5-LANEDROP: a space sweep's re-queue after a partial follow does not take room from the next waiter", .timeLimit(.minutes(1)), arguments: [true, false])
    func laneDrop(_ visitFirst: Bool) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 26_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x78, count: 4_000_000)
        let qBytes = EngineFixture.bytes(889_002, count: 300)
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
        let cBytes = Data(repeating: 0x63, count: 5_000_000)
        let kBytes = Data(repeating: 0x6B, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        #expect(a.transferID == b.transferID, "setup: A and B share one content")
        await harness.serveManifest([q] + fillers(720_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let group = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { engine in
            engine.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) && engine.state.jobs[a.transferID]?.assets.count == 2
        }
        let replacementBytes = EngineFixture.bytes(889_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(820_000) + [replacement, b, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visitFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await EngineRegressionCycle6Tests.driving([time], fence: engine) {
                await engine.awaitCondition { !$0.followOwed }
            }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                jLane: engine.state.jobs[a.transferID]?.lane,
                jIDs: engine.state.jobs[a.transferID]?.assets.count,
                jState: engine.state.jobs[a.transferID]?.state,
                kState: engine.state.jobs[k.transferID]?.state
            )
        }
        // The same room in both variants (a visited follow already committed A's 16 bytes): just under 2 MB.
        try await EngineSyncTests.leaveRoom(1_999_000, harness: harness, fileSystem: fileSystem)
        let free = try await harness.store.freeSpace()
        // The grace ends: the alarm reaps x's 4 MB and runs its `.reclaimed` sweep.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let afterSweep = await engine.readForTests { engine in
            (
                jLane: engine.state.jobs[a.transferID]?.lane,
                jState: engine.state.jobs[a.transferID]?.state,
                kState: engine.state.jobs[k.transferID]?.state,
                space: engine.state.freeSpace.map { "important \($0.volumeImportant - $0.reserveBytes), opportunistic \($0.volumeOpportunistic - $0.reserveBytes), pending \($0.pendingReclaim)" }
            )
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-C5-LANEDROP visitFirst=\(visitFirst): before the reclaim \(before); room before (important above reserve) \(free.volumeImportant - free.reserveBytes), opportunistic \(free.volumeOpportunistic - free.reserveBytes), pending \(free.pendingReclaim); after the sweep \(afterSweep); K's waiter \(kResult); A's waiter \(aResult)")
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "visitFirst=\(visitFirst): K's waiter is answered from its 3 MB with 6 MB free: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter gets its new 16-byte content: \(aResult)")
        await engine.releaseGroup(group)
        await engine.shutdown()
        _ = await sync.value
    }
}
