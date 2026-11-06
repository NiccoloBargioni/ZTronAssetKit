import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// e1-P3 (Stage 3 close-out cycle 22, ruling S3-R27 item 12.2; e1 §3's third UNCONFIRMED sibling, `analyse-g4-reach.md`
/// (b)): a park at the same epoch while the barrier holds would leave the job an ENOENT re-queued `.blocked` when the
/// owed move or the pinned replay reads it, and the move's `.queued` arm (`waitingTarget(_:)`) depends on it. Only the
/// pump parks a queued job, and no pump runs behind the barrier; this is Shape A's side of the probe, with a network
/// edge between the re-queue and the move (rr21-T8b's side is `owedReroutePinnedToARequeuedJobKeepsThePin`'s `edge`).
extension EngineFollowBarrierTests {
    /// Shape A (`barrierMakesAMoveOntoAJobItsDrainedPublicationReQueued`) with the network dropping and returning once T's
    /// drained publication fails ENOENT. Swept first, the two elements arrive between T's re-queue and the follow turn
    /// that makes the owed move H → T [zz-x]: the elements apply at once, and their decisions about jobs wait for the
    /// drain, which comes after the follow's turns, so the move reads T as the re-queue left it. Visited first nothing is
    /// owed onto T, and the drop pauses T's fresh attempt if it still downloads. Visit-first answers: T's fresh attempt
    /// serves A and X. T's state at the move and its starts are recorded, not asserted.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a network edge between a drained publication's ENOENT re-queue and the owed move onto its job leaves the visit-first answers (F-28, e1-P3)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func edgeBetweenAnENOENTRequeueAndTheOwedMoveKeepsTheVisitFirstAnswers(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_029_101
        let tBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let t = try await self.drainedRequeueSetUp(visit, seed: seed, tLater: [.stage(tBytes), .stage(tBytes)])
        let engine = t.engine
        let h = t.x.transferID
        let tID = t.a.transferID
        await Self.failDrainedPublication(t)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.jobs[tID]?.state == .queued }
        }
        for conditions in [EngineRegressionCycle10Tests.offline, DeviceConditions.unrestricted] {
            await t.s.harness.conditions.send(conditions)
            await engine.awaitCondition { $0.state.conditions == conditions }
        }
        let atMove = await engine.readForTests { e in
            "T \(e.state.jobs[tID].map { "\($0.state) at epoch \($0.epoch)" } ?? "gone"), move owed \(Self.owedMove(e, from: h, onto: tID) != nil), \(e.state.eventsAfterFollow.count) events waiting"
        }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.followFollowUpWaiting }
            await Self.runOneFollowTurn(engine)
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: t.aWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: t.xWaiter) }
        let tStarts = await t.s.harness.source.starts.filter { $0.id == tID }.count
        #expect(aResult.map(\.byteSize) == .success(100_000), "T's fresh attempt serves A (visit-first): \(aResult); at the move \(atMove); T started \(tStarts) times")
        #expect(xResult.map(\.byteSize) == .success(100_000), "T's fresh attempt serves X (visit-first): \(xResult); at the move \(atMove); T started \(tStarts) times")
        await Self.finishHeld(t.s)
    }
}
