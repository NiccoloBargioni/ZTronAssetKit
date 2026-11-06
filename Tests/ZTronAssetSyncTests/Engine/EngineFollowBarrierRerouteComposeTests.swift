import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// An owing take-off's batch among the other events a drain places (Stage 3 close-out cycle 21, ruling S3-R26 items 1
/// and 2; `integrate-rr21.md` R8, T-COMPOSE): a verdict's bucket of joins (`joinsBehindVerdicts`) larger than the drain's
/// batch has room for, whose rest waits at the queue's head as the batch's overflow, and a visit after the verdict with
/// a rest (`followMoving`). Each test runs in both orders (`LaneDropVisit`) with the visit-first answers expected in both
/// (`takeOffSetUp`).
extension EngineFollowBarrierTests {
    // MARK: T-COMPOSE: the batch, the visit's rest, the bucket and its overflow

    /// O0 holds zz-c0k, 130 moved-before ids and two ids v4 maps to P, at 128 ids a turn; v4 also maps the 520 members of
    /// a prefetch group on H to O0's content, so swept first H's visit's 520 joins wait behind O0's timeout verdict, and
    /// zz-x, requested once v4 is applied, waits at the queue's tail. The drain's batch holds the verdict and the 511
    /// newest joins, the 9 oldest overflow at the queue's head. The verdict's take-off owes its 130 and spends the turn,
    /// so its visit's move of the two p-ids is the follow's rest, and the batch waits right behind it: the order is the
    /// verdict, the visit's rest, the batch, the bucket's joins newest first, their overflow, then zz-x's join. Visited
    /// first, O0 backed off at its timeout, v4's visit moved the 130 from N back onto it, the members from H onto it and
    /// the p-ids to P, and O0's retry served them all.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: an owing take-off's batch waits behind its verdict's visit, ahead of the verdict's joins, their overflow and later events (F-28, T-COMPOSE)", .timeLimit(.minutes(5)), arguments: LaneDropVisit.allCases)
    func drainPlacesAnOwingTakeOffsBatchAheadOfTheVerdictsBucket(_ visit: LaneDropVisit) async throws {
        let shape = TakeOffShape(ending: .timeout, moved: 130, after: 2, bucket: 520, idsPerTurn: 128)
        let t = try await self.takeOffSetUp(visit, seed: 2_028_351, shape: shape)
        let engine = t.engine
        try await self.takeOffApplyV4(t, visit)
        let x = t.x
        let xID = x.identifier
        let xWaiter = Task { await engine.awaitAsset(xID, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, x) }
            let turns = try await Self.takeOffTurns(t)
            let given = try #require(turns.firstIndex { $0.verdicts == 0 }, "the drain gives O0's verdict: \(turns)")
            try #require(given > 0, "setup: O0's verdict waits until a held turn: \(turns)")
            let atVerdict = turns[given]
            let joins = t.members.reversed().map { "join \($0.identifier)" }
            let tail = ["join \(xID)"]
            #expect(atVerdict.moving && atVerdict.onP == 0 && atVerdict.batches == 1 && atVerdict.owedIDs == 130, "the verdict's turn owes the 130 and leaves its visit's whole move as the follow's rest: \(atVerdict)")
            #expect(atVerdict.queue == ["reroutes"] + joins + tail, "the batch waits right behind the verdict's visit, ahead of the bucket's joins newest first, their overflow and zz-x's join: \(atVerdict.queue.prefix(3)) … \(atVerdict.queue.suffix(3)) (\(atVerdict.queue.count))")
            let made = Self.takeOffMade(turns)
            let first = try #require(made.indices.first { $0 >= given && made[$0] > 0 }, "the batch replays: \(made)")
            #expect(turns[first + 1].onP == 2, "the visit's rest moves the p-ids to P before the batch replays: \(made) \(turns)")
            let done = try #require(turns.firstIndex { $0.settled == 130 }, "the batch replays whole: \(made)")
            #expect(turns[done].queue == joins + tail, "the batch replays whole before the bucket's joins, their overflow and zz-x's join: \(turns[done].queue.prefix(3)) … (\(turns[done].queue.count))")
            #expect(made.allSatisfy { $0 <= 128 }, "no turn re-routes more than a drain turn's 128 ids: \(made)")
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns.first { !$0.violations.isEmpty }.map(\.description) ?? "")")
        }
        let xResult = await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        let outcome = try await self.takeOffFinish(t)
        #expect((try? xResult.get())?.byteSize == 22, "zz-x is served X's bytes: \(xResult)")
        #expect(outcome.moved == [Array(repeating: 16, count: 130)], "O0's retry serves the 130 (visit-first): \(outcome.moved.first?.filter { $0 != 16 } ?? [])")
        #expect(outcome.kept.map { (try? $0.get())?.byteSize } == [16], "O0's retry serves zz-c0k (visit-first): \(outcome.kept)")
        #expect(outcome.after == [20, 20], "P serves the p-ids (visit-first): \(outcome.after)")
        #expect(outcome.bucketPending == 0 && outcome.jobs == 0, "O0's retry serves the members, and no job is left (visit-first): \(outcome.bucketPending) \(outcome.jobs)")
    }
}
