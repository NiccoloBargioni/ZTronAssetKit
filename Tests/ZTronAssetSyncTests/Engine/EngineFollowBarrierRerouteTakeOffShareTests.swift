import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The take-off before a waiting verdict among the drain turn's other work and reads (Stage 3 close-out cycle 21, ruling
/// S3-R26 items 1 and 12's answer 6.5; `integrate-rr21.md`'s T-shared, RR21-PRESENT-PRUNE at site 2 and
/// PROBE-RR21-RESERVE-REJOIN). Each test runs in both orders (`LaneDropVisit`) with the visit-first answers expected in
/// both (`takeOffSetUp`); swept first the follow's and the drain's turns run one at a time and each is read.
extension EngineFollowBarrierTests {
    // MARK: T-shared: a verdict's visit and the owed batch behind it share the drain turn's ids

    /// O0 holds zz-c0k and three ids zz-c0p00…p02 that v4 maps to P once its timeout's verdict waits; Y (zz-yk and
    /// zz-y00…y02) publishes, held, while v4 maps zz-y00…y02 to W's content, and its commit then owes their re-routes as
    /// one batch behind O0's verdict (site 1). Swept first, the drain gives the verdict and the batch in one drain batch:
    /// the visit after the verdict moves the three p-ids, which leaves the turn one of its four ids, so the batch makes
    /// one re-route in that turn and its other two in the next (`EngineState.drainIDsLeft`). Visited first, O0 backed off
    /// at its timeout and v4's visit moved the p-ids to P at once; Y's commit owed the batch, which the drain made.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a verdict's visit and an owed batch behind it in one drain batch share the drain turn's ids (C2, F-28, T-shared)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func verdictsVisitAndTheOwedBatchBehindItShareTheDrainTurnsIDs(_ visit: LaneDropVisit) async throws {
        let shape = TakeOffShape(ending: .timeout, moved: 0, after: 3, commit: 3)
        let t = try await self.takeOffSetUp(visit, seed: 2_028_361, shape: shape)
        var held = try await self.takeOffHoldY(t)
        try await self.takeOffApplyV4(t, visit)
        try await self.takeOffCommitY(t, &held)
        if visit == .sweepFollowsFirst {
            let ids = t.ids
            let owing = await t.engine.readForTests { e in Self.takeOffTurn(e, .follow, ids) }
            try #require(owing.queue == ["verdict", "reroutes"] && owing.owedIDs == 3, "setup: Y's commit owes zz-y00…y02's re-routes as one batch behind O0's verdict: \(owing)")
            let turns = try await Self.takeOffTurns(t)
            let given = try #require(turns.firstIndex { $0.verdicts == 0 }, "the drain gives O0's verdict: \(turns)")
            try #require(given > 0, "setup: O0's verdict waits until a held turn: \(turns)")
            // A turn's re-routes are read from the batch (`owedIDs`): W's job may publish between two readings.
            let visited = zip(turns.dropFirst(), turns).map { $0.onP - $1.onP }
            let rerouted = zip(turns, turns.dropFirst()).map { $0.owedIDs - $1.owedIDs }
            #expect(visited[given - 1] == 3 && rerouted[given - 1] == 1 && turns[given].owedIDs == 2 && turns[given].yOnW == 1, "the verdict's turn moves the visit's three p-ids and makes one of the batch's re-routes, onto W, its four ids: visits \(visited), re-routes \(rerouted), \(turns)")
            #expect(zip(visited, rerouted).allSatisfy { $0 + $1 <= Self.takeOffIDsPerTurn }, "no turn moves and re-routes more than a drain turn's \(Self.takeOffIDsPerTurn) ids: visits \(visited), re-routes \(rerouted)")
            #expect(rerouted.filter { $0 > 0 } == [1, 2], "the batch makes its other two in the next drain turn: \(rerouted) \(turns)")
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns.first { !$0.violations.isEmpty }.map(\.description) ?? "")")
        }
        await held.stop()
        let outcome = try await self.takeOffFinish(t)
        #expect(outcome.after == [20, 20, 20], "P serves the p-ids (visit-first): \(outcome.after)")
        #expect(outcome.y == [14, 26, 26, 26], "Y serves zz-yk and W the moved zz-y… (visit-first): \(outcome.y)")
        #expect(outcome.kept.map { (try? $0.get())?.byteSize } == [16], "O0's retry serves zz-c0k (visit-first): \(outcome.kept)")
        #expect(outcome.jobs == 0, "no job is left once every caller is answered: \(outcome.jobs)")
    }

    // MARK: RR21-PRESENT-PRUNE at site 2: the owed take-off's bindings outlive the drain turn's idle pass

    /// RR21-PRESENT-PRUNE at site 2 (rr21-B24; `critic-rr21-answers.md:103`, refutation 3): zz-d's content D (4,000 bytes)
    /// is present. O0 holds zz-c0k, six moved-before ids and zz-c0p00, its 404's verdict waiting; v4 maps the six back to
    /// O0's content and zz-c0p00 to P, and v5 maps the six onto D, so its apply binds them to D's blob. Swept first,
    /// zz-c0p00 makes v4's follow visit O0 (no pass finds O0 by the six: v2's and v4's copies agree on them), and that
    /// visit passes zz-c0p00 to the verdict and spends O0's re-routed set (`takeOffFollowUntilVisited`), so v5's visit
    /// passes O0 and leaves the six to the verdict; `gate` closes after v5. The drain's 404 ends O0, answering zz-c0k and
    /// zz-c0p00, and its take-off re-routes the six under v5, onto D, and owes them (four a turn): no job holds them, so
    /// the idle pass after the drain turn (`reconcileIdle`) would drop their bindings were nothing waiting for the follow,
    /// and the batch's replay answers them from the store. Visited first, the 404 at its arrival answered zz-c0k and
    /// zz-c0p00, and v3's visit moved the six onto N, v4's onto a fresh job of O0's content (held) and v5's on to D's
    /// content, present, where the store served them before `gate` closed. No job is made after v5 in either order, so
    /// none of D's content, which `gate` would keep from serving them.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a waiting verdict's owed take-off onto a present content is answered from the store at the replay, as the visits answered it (F-28, RR21-PRESENT-PRUNE, site 2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PresentGate.allCases)
    func owedTakeOffOntoAPresentContentIsServedFromTheStore(_ visit: LaneDropVisit, _ gate: PresentGate) async throws {
        let seeds: [PresentGate: UInt64] = [.breakerOpen: 2_028_371, .offline: 2_028_381, .insufficientSpace: 2_028_391]
        let shape = TakeOffShape(ending: .notFound, moved: 6, after: 1, present: gate)
        let t = try await self.takeOffSetUp(visit, seed: try #require(seeds[gate]), shape: shape)
        let engine = t.engine
        let ids = t.ids
        try await self.takeOffApplyV4(t, visit)
        if visit == .sweepFollowsFirst {
            try await Self.takeOffFollowUntilVisited(t)
        }
        try await Self.applyHeld(t.v5, tag: "v5-take-off-\(t.seed)", t.s, visit: visit)
        if visit == .sweepFollowsFirst {
            let bound = await engine.readForTests { e in ids.moved.allSatisfy { e.state.boundContent[$0] == ids.d && e.state.jobs[ids.contents[0]]?.assets.contains($0) == true } }
            try #require(bound, "setup: v5 binds O0's moved ids, still on O0, to D's content, whose blob the store holds")
        }
        switch gate {
        case .breakerOpen:
            try await self.takeOffOpenBreaker(t)
        case .offline:
            await t.s.harness.conditions.send(EngineRegressionCycle10Tests.offline)
            if visit == .sweepFollowsFirst {
                // Visited first the engine is idle by now, its watcher gone (`reconcileIdle`), so no reading arrives.
                await engine.awaitCondition { $0.state.conditions == EngineRegressionCycle10Tests.offline }
            }
        case .insufficientSpace:
            try await Self.leaveRoom(1_000, harness: t.s.harness, fileSystem: t.s.fileSystem)
        }
        let created = await engine.readForTests { $0.state.jobsCreated }
        if visit == .sweepFollowsFirst {
            let turns = try await Self.takeOffTurns(t)
            let given = try #require(turns.firstIndex { $0.verdicts == 0 }, "the drain gives O0's verdict: \(turns)")
            try #require(given > 0, "setup: O0's verdict waits until a held turn: \(turns)")
            #expect(turns[given].o0Interests == 0 && turns[given].batches == 1 && turns[given].owedIDs == 6 && turns[given].boundOnD == 6, "the verdict's turn ends O0 and owes the six, whose bindings outlive the idle pass after it: \(turns[given])")
            let tail = Array(turns.suffix(from: given))
            let made = zip(tail, tail.dropFirst()).map { $0.owedIDs - $1.owedIDs }
            #expect(made.filter { $0 > 0 } == [4, 2], "the batch answers four ids a turn, then two: \(made) \(turns)")
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns.first { !$0.violations.isEmpty }.map(\.description) ?? "")")
            // A job of D's content, refused by `gate`, would keep its waiters: the answers are not awaited then.
            let createdNow = await engine.readForTests { $0.state.jobsCreated }
            try #require(createdNow == created && !turns.contains { $0.dJob }, "no job of D's content: \(created) -> \(createdNow) jobs created, \(turns)")
        }
        let outcome = try await self.takeOffFinish(t)
        let createdAfter = await engine.readForTests { $0.state.jobsCreated }
        #expect(createdAfter == created, "no job is made after v5, so none of D's content: \(created) -> \(createdAfter)")
        #expect(outcome.moved == [Array(repeating: 4_000, count: 6)], "the store serves the six D's bytes, \(gate) notwithstanding (visit-first): \(outcome.moved)")
        #expect(outcome.kept == [.failure(.notFound)] && outcome.after == [-1], "O0's 404 answers zz-c0k and zz-c0p00, which v4 maps to P, as its verdict at its arrival answered them (visit-first): \(outcome.kept) \(outcome.after)")
        if let caller = t.eCaller {
            let answer = await EngineHarness.value(of: caller)
            #expect((try? answer.get()) == nil, "zz-e's 403 fails it: \(answer)")
        }
        #expect(outcome.jobs == 0, "no job is left once every caller is answered: \(outcome.jobs)")
    }

    // MARK: PROBE-RR21-RESERVE-REJOIN: the reservation's edge, with the job's retry state

    /// PROBE-RR21-RESERVE-REJOIN's cases: O0's moved-before ids are a drain turn's four (the reservation's edge) or one
    /// more, and O0's retry serves or, capped, times out too.
    enum ReserveRejoin: String, Sendable, CaseIterable {
        case atTheEdge
        case atTheEdgeCapped
        case pastTheEdge
        case pastTheEdgeCapped

        /// O0's moved-before ids.
        var moved: Int {
            switch self {
            case .atTheEdge, .atTheEdgeCapped:
                return EngineFollowBarrierTests.takeOffIDsPerTurn
            case .pastTheEdge, .pastTheEdgeCapped:
                return EngineFollowBarrierTests.takeOffIDsPerTurn + 1
            }
        }

        /// Whether O0's retry times out too (`TakeOffShape.capped`).
        var capped: Bool {
            self == .atTheEdgeCapped || self == .pastTheEdgeCapped
        }
    }

    /// PROBE-RR21-RESERVE-REJOIN (`integrate-rr21.md`'s probes; the order class of the reservation, recorded with its
    /// results): O0 holds zz-c0k and four or five moved-before ids, at four a turn, and times out; capped, its retry
    /// times out too, at the interactive cap. Swept first, the verdict's turn takes the four off and re-routes them at
    /// once, charged to the turn, all its ids (the reservation's edge), or takes the five off and owes them; either way
    /// they rejoin O0, backed off with its retry state, as v4's visit rejoined them visited first, so O0's retry serves
    /// them all or, capped, answers them all with its own failure.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: moved-back ids taken off at the reservation's edge rejoin their job with its retry state, as visited first (F-28, PROBE-RR21-RESERVE-REJOIN)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, ReserveRejoin.allCases)
    func takeOffAtTheReservationsEdgeRejoinsItsJobWithItsRetryState(_ visit: LaneDropVisit, _ edge: ReserveRejoin) async throws {
        let moved = edge.moved
        let capped = edge.capped
        let shape = TakeOffShape(ending: .timeout, moved: moved, capped: capped)
        let t = try await self.takeOffSetUp(visit, seed: 2_028_401 + UInt64(moved) * 10 + (capped ? 1 : 0), shape: shape)
        try await self.takeOffApplyV4(t, visit)
        if visit == .sweepFollowsFirst {
            let turns = try await Self.takeOffTurns(t)
            let made = Self.takeOffMade(turns)
            let given = try #require(turns.firstIndex { $0.verdicts == 0 }, "the drain gives O0's verdict: \(turns)")
            try #require(given > 0, "setup: O0's verdict waits until a held turn: \(turns)")
            if moved == Self.takeOffIDsPerTurn {
                #expect(made[given - 1] == moved && turns[given].batches == 0, "at the edge the take-off fits the turn's ids and is made in the verdict's turn: \(made) \(turns)")
            } else {
                #expect(made[given - 1] == 0 && turns[given].batches == 1 && turns[given].owedIDs == moved, "past the edge the take-off is owed: \(made) \(turns)")
            }
            #expect(made.allSatisfy { $0 <= Self.takeOffIDsPerTurn }, "no turn re-routes more than a drain turn's ids: \(made) \(turns)")
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns.first { !$0.violations.isEmpty }.map(\.description) ?? "")")
        }
        let outcome = try await self.takeOffFinish(t)
        if capped {
            let failure = try #require(outcome.kept.first.flatMap { result -> AssetError? in
                if case .failure(let error) = result {
                    return error
                }
                return nil
            }, "O0's capped retry fails zz-c0k (visit-first): \(outcome.kept)")
            #expect(outcome.moved == [Array(repeating: -1, count: moved)], "the moved ids, back on O0, get its failure \(failure) too (visit-first): \(outcome.moved)")
        } else {
            #expect(outcome.kept.map { (try? $0.get())?.byteSize } == [16] && outcome.moved == [Array(repeating: 16, count: moved)], "O0's retry serves zz-c0k and the moved ids (visit-first): \(outcome.kept) \(outcome.moved)")
        }
        #expect(outcome.jobs == 0, "no job is left once every caller is answered: \(outcome.jobs)")
    }
}
