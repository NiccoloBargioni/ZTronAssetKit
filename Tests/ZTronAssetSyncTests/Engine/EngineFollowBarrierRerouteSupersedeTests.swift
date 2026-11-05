import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The superseded exit's re-routes, bounded (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md` R5,
/// site 3): a publication the store refuses because no id wants its content any more (`.superseded`) re-routes every
/// interest of its job (`supersede`). An exit whose pairs (an interest's ids, over its interests) pass `inboundIDsNow`
/// owes them as one batch, which the drain makes at its place, at most a drain turn's ids a turn and each id with all
/// its tokens; one whose pairs fit makes them in its own turn. Each test runs in both orders (`LaneDropVisit`) at
/// `followIDsPerTurn = 4` (`inboundIDsNow` 2, a drain turn's ids 4), with the drain's and the follow's turns held and
/// released one at a time and the invariants read after each, and expects the answers an exit that re-routes at once
/// gives.
extension EngineFollowBarrierTests {
    // MARK: rr21-T2: the drain makes a superseded exit's re-routes at most a drain turn's ids a turn

    /// `commitReroute`'s shape with no kept id: v4 maps all ten ids of X's content to W's while X's publication waits at
    /// the store, so no record wants X's bytes and the store refuses the publication. Its ten pairs pass `inboundIDsNow`
    /// (2): the exit's turn re-routes nothing and owes one batch of the ten ids, which the drain makes 4, 4 and 2 a turn,
    /// each turn at least one; the waiters get the answers of the same exit at `followIDsPerTurn = 512`, which re-routes
    /// at once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded publication's re-routes that do not fit its turn are owed as one batch and made at most a drain turn's ids a turn (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededPublicationOwesItsReroutesAndTheDrainMakesThemBounded(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_028_101, kept: 0, moved: 10, idsPerTurn: 4)
        #expect(run.commitMade == [0] && run.owedAfterCommit == [10] && run.batchesAfterCommit == [1], "the exit's turn re-routes nothing and owes the ten ids as one batch: \(run)")
        #expect(run.made == [4, 4, 2], "the drain makes the batch 4, 4 and 2 ids a turn: \(run)")
        #expect(run.turns.allSatisfy { $0.made <= 4 } && run.turns.filter { !$0.owedBefore }.allSatisfy { $0.made >= 1 }, "no turn makes more than a drain turn's ids, and each drain turn makes one at least: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        let atOnce = try await self.commitReroute(visit, seed: 2_028_101, kept: 0, moved: 10, idsPerTurn: 512)
        #expect(atOnce.commitMade == [10] && atOnce.batchesAfterCommit == [0], "setup: at 512 the exit re-routes at once: \(atOnce)")
        #expect(run.served == atOnce.served && run.served == Self.commitRerouteServed(kept: 0, moved: 10), "the answers equal the at-once exit's: \(run.served) \(atOnce.served)")
    }

    // MARK: rr21-T2-two, rr21-T2-edge: the exit's fit charge

    /// rr21-T2-two: two ids, each with a user waiter and one prefetch group's member: two ids, but four pairs, which pass
    /// `inboundIDsNow` (2), so the exit owes the four re-routes, and the drain makes both ids with both their tokens in
    /// one turn.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded publication counts its pairs, not its ids, against its turn's ids (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededPublicationCountsItsPairsAgainstItsTurn(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_028_111, kept: 0, moved: 2, idsPerTurn: 4, wanters: .waitersAndGroup)
        #expect(run.commitMade == [0] && run.owedAfterCommit == [2] && run.batchesAfterCommit == [1], "the exit's four pairs pass its turn's two, so it owes them: \(run)")
        #expect(run.made == [2] && !run.split, "the drain makes both ids, each with both its tokens, in one turn: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(kept: 0, moved: 2) && run.groupDone, "every waiter gets W's bytes and the group waits for no member: \(run)")
    }

    /// rr21-T2-edge: two ids with a user waiter each: two pairs are `inboundIDsNow`, so the exit re-routes both in its own
    /// turn and owes nothing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded publication whose pairs fit its turn's ids re-routes at once and owes nothing (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededPublicationReroutesAtOnceWhenItFits(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_028_121, kept: 0, moved: 2, idsPerTurn: 4)
        #expect(run.commitMade == [2] && run.batchesAfterCommit == [0], "the exit re-routes its two pairs at once: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(kept: 0, moved: 2), "\(run.served)")
    }

    // MARK: rr21-T2-captured: the F-20 hold at site 3

    /// rr21-T2-captured: `capturedRefused`'s shape, where the store's v4 also maps zz-o to a content of its own (17 bytes):
    /// no record wants O's bytes, so the store refuses O's publication, while the engine's copy (v3) still maps every id
    /// to O's content. The exit holds O's content for the manifest (`holdForManifest`) after it removes the job and
    /// before it re-routes K and W1…W<count>: at once with one moved id (2 pairs fit `inboundIDsNow`), owed with three.
    /// Once the follow and the drain are over, the re-routes wait on a fresh job of O's content that is not dispatched;
    /// then the engine follows v4, and K gets its own content's bytes and the moved ids Y's. Visited first, the same,
    /// the fresh job made in the exit's turn.
    @available(macOS 15.0, iOS 18.0, *)
    func supersededRefused(_ visit: LaneDropVisit, moved count: Int, seed: UInt64) async throws -> CapturedRefusedOutcome {
        let c = try await Self.stageOwedCommit(seed: seed, moved: count)
        let engine = c.engine
        let o = c.transfer
        let yBytes = EngineFixture.bytes(seed + 4, count: 20)
        let ownBytes = EngineFixture.bytes(seed + 7, count: 17)
        let onY = c.ids.map { EngineHarness.onDemand($0.rawValue, yBytes) }
        let own = EngineHarness.onDemand("zz-o", ownBytes)
        await c.s.harness.source.script(onY[0].transferID, [.stage(yBytes)])
        await c.s.harness.source.script(own.transferID, [.stage(ownBytes)])
        try await Self.applyHeld(c.manifest(c.moved, round: 1), tag: "v3-superseded-refused-\(seed)", c.s, visit: visit)
        let (units, releaser) = try await Self.holdPublications(of: [o], c.s, bulk: c.bulk)
        let v4 = try ValidatedManifest(entries: c.manifest(onY, round: 2, o: own), digest: ContentHash.sha256(of: Data("v4-superseded-refused-\(seed)".utf8)))
        await engine.holdNextApplyFollow()
        let applying = Task { await engine.applyAndFollow(v4, etag: nil, eviction: nil) }
        await engine.awaitCondition { $0.applyFollowHeld && $0.state.appliesInFlight == 1 }
        await engine.readForTests { $0.holdDrainFollowUps() }
        await c.bulk.release(units[0])
        // The exit holds O's content in its own turn, on both paths.
        await engine.awaitCondition { $0.state.heldForManifest.contains(o) }
        var outcome = CapturedRefusedOutcome()
        outcome.batches = await engine.readForTests { Self.owedBatches($0).count }
        let turns = await Self.releaseOwedTurns(c)
        outcome.violations = turns.violations
        let fresh = await engine.readForTests { e in (e.state.heldForManifest.contains(o), e.state.jobs[o]?.state) }
        outcome.held = fresh.0
        outcome.state = fresh.1
        outcome.starts = await Self.starts(o, c)
        releaser.cancel()
        await releaser.value
        await c.bulk.setHolding(false)
        await engine.readForTests { $0.releaseApplyFollow() }
        let applied = await applying.value
        #expect((try? applied.get()) != nil, "setup: v4 is applied: \(applied)")
        let answers = await Self.owedAnswers(c)
        outcome.k = Self.sizes([answers.k])[0]
        outcome.w = Self.sizes(answers.w)
        await Self.finishHeld(c.s)
        return outcome
    }

    /// rr21-T2-captured on the fit path: K and one refused id are re-routed in the exit's turn onto a fresh job of O's
    /// content held for the manifest.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded exit that re-routes at once the ids the copy still maps to its content holds the fresh job until the copy catches up (F-20)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededExitHoldsTheFreshJobOnTheFitPath(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.supersededRefused(visit, moved: 1, seed: 2_028_131)
        #expect(outcome.batches == 0, "setup: two pairs fit the exit's turn: \(outcome)")
        #expect(outcome.held && outcome.state == .queued && outcome.starts == 1, "K and the refused id wait on a fresh job of O's content, held for the manifest, not downloaded again: \(outcome)")
        #expect(outcome.k == 17 && outcome.w == [20], "K follows v4 to its own content's bytes, the refused id to Y's: \(outcome)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    /// rr21-T2-captured on the owing path: K and three refused ids are owed (four pairs pass `inboundIDsNow`), after the
    /// exit removed the job and held O's content for the manifest, so the drain's re-routes wait on a fresh job that is
    /// not dispatched.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded exit that owes the re-routes of the ids the copy still maps to its content holds the fresh job until the copy catches up (F-20)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededExitHoldsTheFreshJobOnTheOwingPath(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.supersededRefused(visit, moved: 3, seed: 2_028_141)
        #expect(outcome.batches == 1, "setup: four pairs pass the exit's turn, so it owes one batch: \(outcome)")
        #expect(outcome.held && outcome.state == .queued && outcome.starts == 1, "K and the refused ids wait on a fresh job of O's content, held for the manifest, not downloaded again: \(outcome)")
        #expect(outcome.k == 17 && outcome.w == [20, 20, 20], "K follows v4 to its own content's bytes, the refused ids to Y's: \(outcome)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }
}
