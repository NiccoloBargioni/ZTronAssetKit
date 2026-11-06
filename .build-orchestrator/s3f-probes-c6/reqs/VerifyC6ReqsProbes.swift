import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probe (s3f close-out verification, cycle 6, requirements lens). Never committed. A copy of
/// `spaceSweepJudgesAFollowedJobOnItsNewLane` up to K's and A's answers, plus two probes on the lane-dropped job itself.
@Suite("VerifyC6ReqsProbes", .serialized)
struct VerifyC6ReqsProbes {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C6R-LANEDROP-PARK: the lane-dropped job is parked insufficientSpace and a later read re-admits it", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func laneDropPark(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 26_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        // Megabytes of one repeated byte: generated payloads of this size took seconds of the sanitizer run (S3-R4).
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
        // Changed on-demand entries without jobs that sort before A: the follow's first pass formats
        // `followFormatsPerTurn` of them and stops before A's entry.
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x63, count: 5_000_000)
        let kBytes = Data(repeating: 0x6B, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        // v2 prunes x (its 4 MB wait for the 60 s grace) and lists C under A and B, and K.
        await harness.serveManifest([q] + fillers(720_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        // 2 MB of room for user work: neither C's 5 MB nor K's 3 MB fit before the reclaim.
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
        // v3 moves A to a 16-byte content; B and K keep theirs.
        let replacementBytes = EngineFixture.bytes(889_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(820_000) + [replacement, b, k], etag: "v3")
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
                lane: engine.state.jobs[a.transferID]?.lane,
                ids: engine.state.jobs[a.transferID]?.assets.count,
                shared: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state
            )
        }
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.lane == .prefetch && before.ids == 1, "setup: the follow moved A and left B on C's job: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.lane == .userInitiated && before.ids == 2, "setup: C's job still holds A, whose visit the follow owes: \(before)")
        }
        #expect(before.shared == .blocked(.awaitingSpace) && before.k == .blocked(.awaitingSpace), "setup: \(before)")
        // Just under 2 MB in both cases: a follow that visited first may already have committed A's 16 bytes.
        try await EngineSyncTests.leaveRoom(1_999_000, harness: harness, fileSystem: fileSystem)
        // The grace ends: the alarm reaps x's 4 MB (6 MB of room for user work, none for prefetch work) and runs its
        // `.reclaimed` sweep.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let afterSweep = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                shared: engine.state.jobs[a.transferID]?.state,
                violations: engine.invariantViolations()
            )
        }
        #expect(afterSweep.owed == (visit == .sweepFollowsFirst), "the sweep ran while the follow owed C's visit only when the follow had not visited first: \(afterSweep)")
        #expect(afterSweep.lane == .prefetch && afterSweep.shared != .queued, "C's job, left with B's prefetch interest, waits for room prefetch work has not: \(afterSweep)")
        #expect(afterSweep.violations.isEmpty, "\(afterSweep.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K's waiter is answered from its 3 MB, with 6 MB of room for user work: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        #expect(!(await harness.source.starts.map(\.id)).contains(a.transferID), "C's content, wanted by prefetch work only, never started without room")
        // PROBE: the job a follow lowered is parked `insufficientSpace` (re-checked at every read), not left `awaitingSpace`
        // with nothing pending and no wake.
        #expect(afterSweep.shared == .blocked(.insufficientSpace), "PROBE-PARK: C's job after the sweep: \(afterSweep)")
        // PROBE: room for prefetch work appears; one free-space read re-admits C's job (B's interest still wants it).
        try fileSystem.write(Data(), to: EngineHarness.base.appendingPathComponent("ballast"), mode: .truncate)
        try fileSystem.write(Data(), to: EngineHarness.base.appendingPathComponent("ballast-2"), mode: .truncate)
        await engine.refreshFreeSpace()
        let later = await engine.readForTests { engine in (state: engine.state.jobs[a.transferID]?.state, lane: engine.state.jobs[a.transferID]?.lane, free: engine.state.freeSpace) }
        #expect(later.state != .blocked(.insufficientSpace) && later.state != .blocked(.awaitingSpace), "PROBE-READMIT: a read with room re-admits C's job: \(later)")
        await engine.releaseGroup(group)
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }
}
