import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A space sweep's place among the events that wait for an owed follow (the cycle-12 residual R-C; ruling S3-R16 item 5:
/// non-blocking unless a probe shows a different answer). Runs in both orders (`LaneDropVisit`) and expects the
/// visit-first answers.
extension EngineFollowBarrierTests {
    // MARK: The sweep's place (R-C)

    /// Changed entries without jobs, as `FollowBarrier.fillers`, but four follow turns' worth: each space sweep behind
    /// the barrier runs one follow turn (`advanceFollowForSpaceSweep`), and a reclaim brings more than one sweep, so with
    /// two turns' worth the follow ended inside the reclaim and the request below met no barrier.
    @available(macOS 15.0, iOS 18.0, *)
    static func sweepFillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn * 4 + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    /// A reclaim's sweep that re-admits a space-parked job while the follow owes its visits gives it the room before a
    /// request that arrives after the sweep: S (zz-s, 3 MB) waits `awaitingSpace` for a 4 MB pruned blob with 0.5 MB of
    /// room, for U's user waiter. While the follow owes its visits, the grace ends and the reclaim leaves 4.5 MB, room
    /// for S or for J (zz-j, 3 MB), not both; then V asks for J. Visited first, the reclaim's sweep re-admitted S at once:
    /// S took the room and was served, and J, judged beside S's bytes with nothing left to reclaim, answered V
    /// `insufficientSpace`. Behind the barrier the sweep judges only after the drain, so J, replayed in the drain, took
    /// the room first and U was answered `insufficientSpace` instead.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a reclaim's sweep during an owed follow gives the room to the job it re-admits before a later request (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesTheRoomToTheSweepsJobBeforeALaterRequest(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUpWithX(xSize: 4_000_000, seed: 1_312_002)
        let engine = s.engine
        let sBytes = Data(repeating: 0x91, count: 3_000_000)
        let jBytes = Data(repeating: 0x92, count: 3_000_000)
        let sEntry = EngineHarness.onDemand("zz-s", sBytes)
        let jEntry = EngineHarness.onDemand("zz-j", jBytes)
        // v2 prunes x: its 4 MB wait for the grace.
        await s.harness.serveManifest([s.q] + Self.sweepFillers(1_312_100) + [jEntry, sEntry], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(500_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(sEntry.transferID, [.stage(sBytes)])
        await s.harness.source.script(jEntry.transferID, [.stage(jBytes)])
        let uWaiter = Task { await engine.awaitAsset(sEntry.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[sEntry.transferID]?.state == .blocked(.awaitingSpace) }
        // The sweep's own follow-up turn is held: it judges only when released (the turn a request can precede).
        await engine.readForTests { $0.holdSpaceSweepFollowUps() }
        try await Self.applyHeld([s.q] + Self.sweepFillers(1_320_000) + [jEntry, sEntry], tag: "v3-sweep", s, visit: visit)
        // The grace ends: the reclaim frees x's 4 MB and its sweep runs.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.freeSpace?.pendingReclaim == 0 && e.state.storeWorkRuns == 0
                    && (e.state.jobs[sEntry.transferID]?.state != .blocked(.awaitingSpace) || e.state.spaceSweepFollowUpWaiting)
            }
        }
        if visit == .sweepFollowsFirst {
            let mid = await engine.readForTests { e in (owed: e.followOwed, s: e.state.jobs[sEntry.transferID]?.state) }
            #expect(mid.owed && mid.s == .blocked(.awaitingSpace), "setup: the sweep's judgement waits behind the owed follow: \(mid)")
        }
        // V asks for J after the sweep.
        let vWaiter = Task { await engine.awaitAsset(jEntry.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, jEntry) }
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        await engine.readForTests { $0.releaseSpaceSweepFollowUps() }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let vResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: vWaiter) }
        #expect((try? uResult.get())?.byteSize == Int64(sBytes.count), "S, re-admitted by the sweep before V's request, takes the room (visit-first): \(uResult)")
        if case .failure(.insufficientSpace) = vResult {
        } else {
            Issue.record("J, requested after the sweep gave S the room, is answered insufficientSpace (visit-first): \(vResult)")
        }
        await Self.finishHeld(s)
    }
}
