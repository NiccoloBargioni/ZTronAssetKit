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
    /// each turn at least one; the waiters get the answers, and W's job the interests (each its kind and lane), of the
    /// same exit at `followIDsPerTurn = 512`, which re-routes at once.
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
        #expect(run.onW == atOnce.onW && run.onW.count == 10, "the replay makes W's interests with the kinds and lanes the at-once exit gave them: \(run.onW) \(atOnce.onW)")
    }

    // MARK: rr21-T2-two, rr21-T2-edge: the exit's fit charge

    /// rr21-T2-two: two ids, each with a user waiter and one prefetch group's member: two ids, but four pairs, which pass
    /// `inboundIDsNow` (2), so the exit owes the four re-routes, and the drain makes both ids with both their tokens in
    /// one turn, the answers and W's interests (each its kind and lane) those of the same exit at `followIDsPerTurn =
    /// 512`, which re-routes at once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded publication counts its pairs, not its ids, against its turn's ids (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededPublicationCountsItsPairsAgainstItsTurn(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_028_111, kept: 0, moved: 2, idsPerTurn: 4, wanters: .waitersAndGroup)
        let atOnce = try await self.commitReroute(visit, seed: 2_028_111, kept: 0, moved: 2, idsPerTurn: 512, wanters: .waitersAndGroup)
        #expect(run.commitMade == [0] && run.owedAfterCommit == [2] && run.batchesAfterCommit == [1], "the exit's four pairs pass its turn's two, so it owes them: \(run)")
        #expect(run.made == [2] && !run.split, "the drain makes both ids, each with both its tokens, in one turn: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(kept: 0, moved: 2) && run.groupDone, "every waiter gets W's bytes and the group waits for no member: \(run)")
        #expect(atOnce.commitMade == [2] && atOnce.batchesAfterCommit == [0] && run.served == atOnce.served, "setup: at 512 the exit re-routes at once, with the same answers: \(atOnce)")
        #expect(run.onW == atOnce.onW && run.onW.count == 3, "the replay makes W's two waiters' and the group's interests with the kinds and lanes the at-once exit gave them: \(run.onW) \(atOnce.onW)")
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

    // MARK: The holes at site 3: RR21-HOP, RR21-WINDOW-GATE and RR21-PRESENT-PRUNE

    /// RR21-HOP's integrity variant at site 3 (`publishingPin`'s `superseded`): K0 maps zz-o onto P's content as well as
    /// zz-a1…zz-a3, so the store refuses O's publication, and its exit owes the four re-routes; K1 maps zz-a1…zz-a3 to
    /// Z's content while P publishes. Visited first, the exit re-routed K and W1…W3 onto P publishing, K1's visit passed
    /// P (RR-14) and P's integrity failure answered all four. The replay pins them to P (K1's layer holds P among its
    /// ends): they get P's failure, and Z is never requested.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded exit's owed re-route pinned to a job a later apply passed publishing gets that publication's integrity failure (F-28, RR-14)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededReroutePinnedToAPublishingJobGetsItsIntegrityFailure(_ visit: LaneDropVisit) async throws {
        let (outcome, zStarts) = try await self.publishingPin(visit, seed: 2_028_151, end: .integrity, superseded: true)
        #expect(outcome.others == [.failure(.integrityFailure)] && outcome.k == .failure(.integrityFailure), "Q and K get P's integrity failure: \(outcome)")
        #expect(outcome.w.count == 3 && outcome.w.allSatisfy { $0 == .failure(.integrityFailure) }, "W1…W3, passed on P by K1's visit (visit-first), get P's failure: \(outcome)")
        #expect(zStarts == 0, "Z is never requested: Z's starts \(zStarts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    /// RR21-HOP's storage variant at site 3: as the integrity variant, P's publication failing because the store's root
    /// stopped verifying while it waited for the owed re-routes (`PinnedEnd.storageUnavailable`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded exit's owed re-route pinned to a job a later apply passed publishing gets that publication's storage failure (F-28, RR-14)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededReroutePinnedToAPublishingJobGetsItsStorageFailure(_ visit: LaneDropVisit) async throws {
        let (outcome, zStarts) = try await self.publishingPin(visit, seed: 2_028_156, end: .storageUnavailable, superseded: true)
        let failed = Result<AssetLocation, AssetError>.failure(.storageUnavailable(.rootVanished))
        #expect(outcome.others == [failed] && outcome.k == failed, "Q and K get P's storage failure: \(outcome)")
        #expect(outcome.w.count == 3 && outcome.w.allSatisfy { $0 == failed }, "W1…W3, passed on P by K1's visit (visit-first), get P's failure: \(outcome)")
        #expect(zStarts == 0, "Z is never requested: Z's starts \(zStarts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    /// RR21-WINDOW-GATE at site 3 (`windowGate`'s `superseded`): the breaker opened before K0, which maps zz-o and
    /// zz-a1…zz-a3 onto P's content, downloading; the store refuses O's publication, its exit owes the four re-routes,
    /// and P's bytes arrive while they are owed. P's publication waits for the replay and binds all four: K, Q and W1…W3
    /// get P's bytes, and no fresh job of P's content is made.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a publication that begins while a superseded exit's re-routes are owed binds their ids though the gate closed before the exit (F-28, RR21-WINDOW-GATE)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func publicationDuringASupersededExitsWindowBindsTheOwedIDs(_ visit: LaneDropVisit) async throws {
        try await self.windowGate(visit, seed: 2_028_161, superseded: true)
    }

    /// RR21-PRESENT-PRUNE at site 3 (`presentPrune`'s `superseded`): K0 maps zz-o and zz-a1…zz-a6 onto D's content,
    /// present, which binds them to D's blob; the store refuses O's publication, and its exit, which removes the last
    /// job, owes the seven re-routes. The bindings outlive the exit's own idle pass, and the replay answers all seven
    /// from the store, `gate` notwithstanding.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded exit's owed re-routes onto a present content are answered from the store at the replay, as the exit answered them at once (F-28, RR21-PRESENT-PRUNE)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PresentGate.allCases)
    func supersededReroutesOntoAPresentContentAreServedFromTheStore(_ visit: LaneDropVisit, _ gate: PresentGate) async throws {
        let seeds: [PresentGate: UInt64] = [.breakerOpen: 2_028_171, .offline: 2_028_181, .insufficientSpace: 2_028_191]
        try await self.presentPrune(visit, gate, seed: try #require(seeds[gate]), superseded: true)
    }

    // MARK: PROBE-RR21-PIN-END after site 3 (rr21-C5)

    /// PROBE-RR21-PIN-END with K2 between X's commit and the replay, the batch owed by O's superseded exit (`pinEnd`'s
    /// `superseded`): visited first, the exit re-routed W1…W3 onto X publishing and K to its own content, K1's visit
    /// passed X, X's commit re-routed W1…W3 under K1's copy to W's job, and K2's visit passed W publishing, so W's
    /// failure answered them.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded exit's owed re-route whose pinned job committed before a later apply follows the copy at that commit (F-28, RR-14, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededRerouteWhosePinCommittedFollowsTheCopyAtThatCommit(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinEnd(visit, seed: 2_028_201, later: .whilePublishing, superseded: true)
        #expect(outcome.u == .failure(.integrityFailure) && outcome.w.count == 3 && outcome.w.allSatisfy { $0 == .failure(.integrityFailure) }, "U and W1…W3 get W's integrity failure (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v]) == [17, 18] && outcome.zStarts == 0, "K gets its own content's bytes, V X's, and Z is never requested: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }

    /// PROBE-RR21-PIN-END with K2 while W still downloads, the batch owed by O's superseded exit: visited first, X's
    /// commit had re-routed W1…W3 to W's job under K1's copy, and K2's visit moved them to Z's job.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded exit's owed re-route whose pinned job committed follows the applies after that commit from the copy then (F-28, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededRerouteWhosePinCommittedFollowsTheAppliesAfterThatCommit(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinEnd(visit, seed: 2_028_211, later: .whileDownloading, superseded: true)
        #expect(outcome.u == .failure(.integrityFailure) && Self.sizes(outcome.w) == [24, 24, 24], "U gets W's integrity failure, W1…W3 Z's bytes (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v]) == [17, 18] && outcome.zStarts == 1, "K gets its own content's bytes, V X's, and Z is requested once: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }

    /// PROBE-RR21-PIN-END's T21 shape, the batch owed by O's superseded exit: the copy at X's commit (K1's) does not list
    /// zz-a1…zz-a3, so, visited first, X's commit ended W1…W3's interests before K2 listed the ids again on Z's content.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a superseded exit's owed re-route whose pinned job committed under a copy that dropped its id ends its interest though a later apply lists it again (F-28, T21, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func supersededRerouteWhosePinCommittedEndsUnderTheCopyAtThatCommit(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinEndDropped(visit, seed: 2_028_221, superseded: true)
        #expect(outcome.w.count == 3 && outcome.w.allSatisfy { $0 == .failure(.notFound) }, "W1…W3 get .notFound (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v]) == [17, 18] && outcome.zStarts == 0, "K gets its own content's bytes, V X's, and Z is never requested: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }
}
