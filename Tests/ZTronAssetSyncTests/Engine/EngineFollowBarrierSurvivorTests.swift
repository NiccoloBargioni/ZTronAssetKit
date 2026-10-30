import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The pump the follow barrier owes once it ends (R-SYN-2, F-28; Stage 3 close-out cycle 11, ruling S3-R14 item 5): the
/// surviving mutant `noFlagPump` (`continueFollow`'s pump on `pumpWaitsForFollow`), pinned in both orders (`LaneDropVisit`).
/// `noDispatchOwedFlag` has no committed test: its probe is recorded in the WP-F draft (cycle 11).
extension EngineFollowBarrierTests {
    // MARK: A slot freed behind the barrier (noFlagPump)

    /// A slot freed while the follow is owed is filled in the follow's last turn although that turn moved nothing: one
    /// slot; A (zz-a) downloads for a user waiter and B (zz-b) waits in the queue for another. v3 changes only the fillers,
    /// so no job moves. Behind the barrier, A's commit frees the slot and the pump it runs waits for the follow
    /// (`pumpWaitsForFollow`); the follow's last turn visits nothing and no event waits for it, so only its own pump on
    /// that flag starts B. Visited first, A's commit started B at once. Without that pump B waited in the queue with the
    /// slot free until an unrelated pump (the cycle-3 survivor `noFlagPump`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a slot freed during an owed follow is filled in the follow's last turn, which moved nothing (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierFillsAFreedSlotInTheFollowsLastTurn(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_502, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let aBytes = Data(repeating: 0xA1, count: 100_000)
        let bBytes = Data(repeating: 0xA2, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", aBytes)
        let b = EngineHarness.onDemand("zz-b", bBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(740_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(aBytes)])
        await s.harness.source.script(b.transferID, [.hold, .stage(bBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state == .queued }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(840_000) + [a, b], s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(aBytes.count), "A is served: \(aResult)")
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in
                (owed: e.followOwed, events: e.state.eventsAfterFollow.count, b: e.state.jobs[b.transferID]?.state, waits: e.state.pumpWaitsForFollow, free: e.state.jobs[a.transferID] == nil)
            }
            #expect(before.owed && before.events == 0 && before.b == .queued && before.waits && before.free, "setup: A's slot is free, B waits in the queue for the follow, and no event waits: \(before)")
        }
        // The follow's last turn (sweep-first) or nothing (visit-first), and B's state at its end.
        let atEnd = await engine.readForTests { e in
            e.releaseFollowFollowUps()
            return (owed: e.followOwed, b: e.state.jobs[b.transferID]?.state)
        }
        #expect(!atEnd.owed && atEnd.b == .downloading, "B has the freed slot once the follow ends, in its last turn (visit-first: at A's commit): \(atEnd)")
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(bBytes.count), "B is served: \(bResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
