import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The take-off before a waiting verdict, bounded (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md`
/// R6 and R7, site 2): the drain takes the moved-back ids off the verdict's job before the verdict, and decides once, in
/// the verdict's turn, whether their re-routes fit the ids the turn has left (`EngineState.drainIDsLeft`). Ones that fit
/// are made after the verdict and charged to the turn; ones that do not are owed as one batch, the turn's ids are spent,
/// and the batch waits at the queue's head right behind the verdict and its visit (`drainEventsAfterFollow`). Each test
/// runs in both orders (`LaneDropVisit`) with the visit-first answers expected in both (`takeOffSetUp`); swept first the
/// follow's and the drain's turns run one at a time and each is read.
extension EngineFollowBarrierTests {
    // MARK: rr21-T3: the bound and the order at site 2

    /// O0 holds zz-c0k (a user waiter, and a prefetch group with zz-c0m00) and ten moved-before ids zz-c0m00…m09, each with
    /// a user waiter; m05's waiter is cancelled once the verdict waits, so its removal waits behind it. Swept first, the
    /// verdict's turn takes the ten ids off, more than its four, so it owes their eleven re-routes as one batch and spends
    /// the turn: the batch waits right behind the verdict, ahead of the removal, and replays four ids a turn; the removal
    /// then removes m05's re-joined interest. The group's interest keeps zz-c0k through the take-off, which the verdict
    /// answers. Visited first, v3's visit moved the ten onto N, the verdict was given at its arrival, and v4's visit moved
    /// them from N to O0's content: a 404 answered zz-c0k and the group's zz-c0k, and a fresh job of the content served
    /// the ten; an ENOSPC with room backed O0 off, the ten joined it, and its retry served all.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a waiting verdict's take-off that does not fit the drain turn's ids owes its re-routes as one batch right behind the verdict, with the visit-first answers (C2, F-28, rr21-T3)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [TakeOffEnding.notFound, .spaceRetry])
    func drainOwesATakeOffThatDoesNotFitItsTurnRightBehindTheVerdict(_ visit: LaneDropVisit, _ ending: TakeOffEnding) async throws {
        let shape = TakeOffShape(ending: ending, moved: 10, partial: true, removal: 5)
        let t = try await self.takeOffSetUp(visit, seed: ending == .notFound ? 2_028_301 : 2_028_311, shape: shape)
        try await self.takeOffApplyV4(t, visit)
        if visit == .sweepFollowsFirst {
            let turns = try await Self.takeOffTurns(t)
            let made = Self.takeOffMade(turns)
            let given = try #require(turns.firstIndex { $0.verdicts == 0 }, "the drain gives O0's verdict: \(turns)")
            try #require(given > 0, "setup: O0's verdict waits until a held turn: \(turns)")
            let atVerdict = turns[given]
            #expect(atVerdict.batches == 1 && atVerdict.owedIDs == 10 && made[given - 1] == 0, "the verdict's turn takes the ten ids off and owes their re-routes as one batch, making none: \(made) \(turns)")
            #expect(atVerdict.queue == ["reroutes", "removal"], "the batch waits at the queue's head, right behind the verdict and ahead of the removal that waited behind it: \(atVerdict)")
            #expect(made.allSatisfy { $0 <= Self.takeOffIDsPerTurn }, "no turn re-routes more than a drain turn's \(Self.takeOffIDsPerTurn) ids: \(made) \(turns)")
            #expect(made.suffix(from: given).filter { $0 > 0 } == [4, 4, 2], "the batch replays four ids a turn: \(made) \(turns)")
            let rejoined = turns.firstIndex { $0.removalOnJob }
            #expect(rejoined.map { $0 > given } == true && turns.last?.removalOnJob == false, "the batch re-joins m05's cancelled waiter, and the removal behind it then removes its interest: \(turns)")
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns)")
        }
        let outcome = try await self.takeOffFinish(t)
        var expected = Array(repeating: Int64(16), count: 10)
        expected[5] = -2
        #expect(outcome.moved == [expected], "the ten are served O0's content, m05's caller answered `.cancelled` (visit-first): \(outcome.moved)")
        switch ending {
        case .notFound:
            #expect(outcome.kept == [.failure(.notFound)], "O0's 404 answers zz-c0k (visit-first): \(outcome.kept)")
        case .timeout, .spaceRetry:
            #expect(outcome.kept.map { (try? $0.get())?.byteSize } == [16], "O0's retry serves zz-c0k (visit-first): \(outcome.kept)")
        }
        #expect(outcome.groupPending.isEmpty, "the group's interest kept zz-c0k through the take-off, so the verdict decided it, and zz-c0m00 was served (visit-first): \(outcome.groupPending)")
        #expect(outcome.jobs == 0, "no job is left once every caller is answered: \(outcome.jobs)")
    }

    // MARK: rr21-T3-two: the take-off's reservation

    /// O0 and O1 each hold zz-c<c>k and three moved-before ids; their 404s wait, and the drain gives both in one batch.
    /// Swept first, O0's take-off fits the turn's four ids and is made at once, charged to the turn; O1's three do not fit
    /// the one id left, so they are owed and replay in the next drain turn: no turn makes six. Visited first, both 404s were
    /// given at their arrival and v4's visit moved the six from N to fresh jobs of their contents.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the take-offs of two verdicts in one drain batch share the turn's ids: the first is charged, the second owed (C2, F-28, rr21-T3-two)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func drainChargesAFittingTakeOffToItsTurnAndOwesTheNext(_ visit: LaneDropVisit) async throws {
        let shape = TakeOffShape(ending: .notFound, contents: 2, moved: 3)
        let t = try await self.takeOffSetUp(visit, seed: 2_028_321, shape: shape)
        try await self.takeOffApplyV4(t, visit)
        if visit == .sweepFollowsFirst {
            let turns = try await Self.takeOffTurns(t)
            let made = Self.takeOffMade(turns)
            let given = try #require(turns.firstIndex { $0.verdicts == 0 }, "the drain gives both verdicts: \(turns)")
            try #require(given > 0, "setup: the verdicts wait until a held turn: \(turns)")
            #expect(turns.allSatisfy { $0.verdicts == 2 || $0.verdicts == 0 }, "both verdicts are given in one drain batch: \(turns)")
            #expect(made[given - 1] == 3 && turns[given].batches == 1 && turns[given].owedIDs == 3, "O0's three are made at once and O1's three owed: \(made) \(turns)")
            #expect(made.allSatisfy { $0 <= Self.takeOffIDsPerTurn }, "no turn re-routes more than a drain turn's \(Self.takeOffIDsPerTurn) ids: \(made) \(turns)")
            #expect(made.filter { $0 > 0 } == [3, 3], "the owed three replay in the next drain turn: \(made) \(turns)")
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns)")
        }
        let outcome = try await self.takeOffFinish(t)
        #expect(outcome.moved == [[16, 16, 16], [16, 16, 16]], "the six are served their contents by fresh jobs (visit-first): \(outcome.moved)")
        #expect(outcome.kept == [.failure(.notFound), .failure(.notFound)], "each 404 answers its kept id (visit-first): \(outcome.kept)")
        #expect(outcome.jobs == 0, "no job is left once every caller is answered: \(outcome.jobs)")
    }

    // MARK: RR21-VERDICT-ZERO: an owing take-off spends the turn

    /// O0 holds zz-c0k, six moved-before ids, and six ids zz-c0p00…p05 that v4 maps to P once the timeout's verdict waits:
    /// the drain's visit after the verdict moves them (`followAfterVerdict`). Swept first, the take-off owes its six and
    /// spends the turn, so the visit after the verdict moves nothing in it and leaves its whole move as the follow's rest
    /// (`followMoving`): the follow's next turns move the six to P, and only then does the batch replay. Visited first,
    /// O0 backed off at its timeout, v4's visit moved the six from N back onto it and the p-ids to P, and O0's retry
    /// served zz-c0k and the six.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a take-off that owes its re-routes spends the verdict's turn, so the visit after the verdict moves its ids before the batch replays (C2, F-28, RR21-VERDICT-ZERO)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func drainSpendsTheVerdictsTurnOnATakeOffThatOwes(_ visit: LaneDropVisit) async throws {
        let shape = TakeOffShape(ending: .timeout, moved: 6, after: 6)
        let t = try await self.takeOffSetUp(visit, seed: 2_028_331, shape: shape)
        try await self.takeOffApplyV4(t, visit)
        if visit == .sweepFollowsFirst {
            let turns = try await Self.takeOffTurns(t)
            let made = Self.takeOffMade(turns)
            let given = try #require(turns.firstIndex { $0.verdicts == 0 }, "the drain gives O0's verdict: \(turns)")
            try #require(given > 0, "setup: O0's verdict waits until a held turn: \(turns)")
            let atVerdict = turns[given]
            #expect(atVerdict.moving && atVerdict.onP == 0 && made[given - 1] == 0 && atVerdict.batches == 1 && atVerdict.owedIDs == 6, "the verdict's turn owes the six, moves none of the visit's ids and leaves the visit's whole move as the follow's rest: \(made) \(turns)")
            let firstMade = try #require(made.indices.first { $0 >= given && made[$0] > 0 }, "the batch replays: \(made) \(turns)")
            #expect(turns[firstMade + 1].onP == 6 && !turns[firstMade + 1].moving, "the visit's rest moves the six to P, in the follow's next turns, before the batch replays: \(made) \(turns)")
            #expect(made.allSatisfy { $0 <= Self.takeOffIDsPerTurn }, "no turn re-routes more than a drain turn's \(Self.takeOffIDsPerTurn) ids: \(made) \(turns)")
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns)")
        }
        let outcome = try await self.takeOffFinish(t)
        #expect(outcome.moved == [Array(repeating: 16, count: 6)], "O0's retry serves the six (visit-first): \(outcome.moved)")
        #expect(outcome.kept.map { (try? $0.get())?.byteSize } == [16], "O0's retry serves zz-c0k (visit-first): \(outcome.kept)")
        #expect(outcome.after == Array(repeating: 20, count: 6), "P serves the p-ids (visit-first): \(outcome.after)")
        #expect(outcome.jobs == 0, "no job is left once every caller is answered: \(outcome.jobs)")
    }

    // MARK: RR21-HELDLANE: the lane a claim keeps once the take-off empties the job

    /// O0's only interests are 64 moved-before waiters, zz-c0m63's user-initiated and the rest bulk, registered in id
    /// order, and a recorded prefetch group's pending claim on its content keeps the job once they leave. Swept first, the
    /// take-off removes the wholly held interests in ascending token order, so the job keeps the lane of the last one
    /// removed, user-initiated (`Job.heldLane`, set at the last removal), as today's take-off did, and the timeout's
    /// claim-only retry reads it (`claimRetries`). The state arises swept first only: visited first, v3's visit moved
    /// every id O0 held and superseded it, and v4's visit moved the 64 from N to a fresh job of its content, which served
    /// them, as O0's retry serves them swept first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a take-off that empties a job a claim keeps leaves it the lane of its greatest token's interest, as the visit-first move does (F-28, RR21-HELDLANE)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func takeOffLeavesAClaimKeptJobTheLaneOfItsLastInterest(_ visit: LaneDropVisit) async throws {
        let lanes = Array(repeating: AssetPriority.bulk, count: 63) + [.userInitiated]
        let shape = TakeOffShape(ending: .timeout, moved: 64, keptWaiters: false, lanes: lanes)
        let t = try await self.takeOffSetUp(visit, seed: 2_028_341, shape: shape)
        try await self.takeOffApplyV4(t, visit)
        if visit == .sweepFollowsFirst {
            let turns = try await Self.takeOffTurns(t)
            let given = try #require(turns.firstIndex { $0.verdicts == 0 }, "the drain gives O0's verdict: \(turns)")
            try #require(given > 0, "setup: O0's verdict waits until a held turn: \(turns)")
            #expect(turns[given].heldLane == .userInitiated && turns[given].o0Interests == 0 && turns[given].owedIDs == 64, "the take-off leaves O0 to the claim with its greatest token's lane, user-initiated, and owes the 64: \(turns[given])")
            #expect(Self.takeOffMade(turns).allSatisfy { $0 <= Self.takeOffIDsPerTurn }, "no turn re-routes more than a drain turn's ids: \(turns)")
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns.first { !$0.violations.isEmpty }.map(\.description) ?? "")")
        }
        let outcome = try await self.takeOffFinish(t)
        #expect(outcome.moved == [Array(repeating: 16, count: 64)], "O0's retry serves the 64 (visit-first): \(outcome.moved)")
        #expect(outcome.jobs == 0, "no job is left once every caller is answered: \(outcome.jobs)")
    }
}
