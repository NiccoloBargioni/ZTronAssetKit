import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
// D1 ADAPTATION (design probe): the first wait after the reclaim also ends once the alarm's store work is over and its read adopted, so a
// sweep the design leaves to the follow's end does not hang the wait while the follow's turns are held; the original releases below then end the follow.
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Close-out cycle 7, requirements lens: PROBE-C7R-GAIN-AHEAD. The setup of
/// `spaceSweepRequeuesAFollowedJobItsNewLaneFits` plus D (7 MB, a prefetch waiter) parked `awaitingSpace` behind C.
/// After the reclaim prefetch work has 10 MB: C (5 MB), re-queued by the park branch's re-judgement, must be counted
/// ahead, so D is judged against 5 MB and parked `insufficientSpace` in the sweep's own turn (its waiter answered at once, so
/// the job is gone). A re-queue that does not
/// count C ahead (mutant `gainNoAhead`) re-queues D too.
@Suite("VerifyC7ReqsProbes")
struct VerifyC7ReqsProbes {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C7R-GAIN-AHEAD", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func gainAhead(_ visit: LaneDropVisit) async throws {
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
        await harness.serveManifest([q] + fillers(730_000) + [a, b, d], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
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
        let replacementBytes = EngineFixture.bytes(893_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(830_000) + [replacement, b, d], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (owed: engine.followOwed, lane: engine.state.jobs[a.transferID]?.lane, c: engine.state.jobs[a.transferID]?.state, d: engine.state.jobs[d.transferID]?.state)
        }
        #expect(before.c == .blocked(.awaitingSpace) && before.d == .blocked(.awaitingSpace), "setup: \(before)")
        let watch = SweepTurnWatch()
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { engine in
                guard engine.state.jobs[a.transferID]?.state != .blocked(.awaitingSpace) else {
                    // D1 ADAPTATION: the reclaim's sweep left to the follow's end.
                    return engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0
                }
                watch.record(engine.state.jobs[d.transferID]?.state)
                return true
            }
        }
        // D1 ADAPTATION: when the sweep waited for the follow, the follow's turns are released here (an added step) and the
        // watch records D in the turn that sees C leave its wait, the deferred sweep's.
        if await engine.readForTests({ $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }) {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await EngineRegressionCycle6Tests.driving([time], fence: engine) {
                await engine.awaitCondition { engine in
                    guard engine.state.jobs[a.transferID]?.state != .blocked(.awaitingSpace) else {
                        return false
                    }
                    watch.record(engine.state.jobs[d.transferID]?.state)
                    return true
                }
            }
        }
        #expect(watch.state == nil || watch.state == .blocked(.insufficientSpace), "PROBE-GAIN-AHEAD: in the sweep's turn D (7 MB) is judged behind C's 5 MB of the 10 MB prefetch room and parked (its fail-fast ends the job), never re-queued: \(String(describing: watch.state))")
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let dResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: dWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "\(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "\(aResult)")
        print("PROBE-GAIN-AHEAD visit=\(visit) dResult=\(dResult) dStarted=\(await harness.source.starts.map(\.id).contains(d.transferID))")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }
}
