import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The commit's refusal and its trims with the bound re-routes (Stage 3 close-out cycle 21, ruling S3-R26 items 1 and
/// 4; `integrate-rr21.md` R4, C1 and the branches rr21-B3 and rr21-B4; `design2-commit-window.md` N3's T-R1 and T-R2;
/// the cycle-20 requirements verifier's reqs #7): an id the publication's binding captured and the store refused holds
/// the fresh job of the content until the copy catches up (F-20), on the fit path and on the owing path; an id moved
/// away or added after the capture holds nothing; a token with one bound id and one unbound id keeps the bound one.
/// Each runs in both orders (`LaneDropVisit`) and expects the visit-first answers in both.
extension EngineFollowBarrierTests {
    /// What `capturedRefused` read: whether O's content had a fresh job held for the manifest once the follow and the
    /// drain were over, its state, O's starts then, the batches after the commit, and the answers.
    struct CapturedRefusedOutcome: CustomStringConvertible {
        var held = false
        var state: JobState?
        var starts = 0
        var batches = -1
        var k: Int64 = -1
        var w: [Int64] = []
        var violations: [String] = []

        var description: String {
            "held \(self.held), fresh job \(String(describing: self.state)), O's starts \(self.starts), batches \(self.batches); K \(self.k), W \(self.w); violations \(self.violations.prefix(3))"
        }
    }

    /// rr21-T3-captured: zz-o and zz-a1…zz-a<count> share O's content, each with a user waiter. v3 changes only the
    /// fillers (swept first, its follow stays owed); O's publication begins, held at its first store unit, so its binding
    /// captures every id; then the store applies v4, which maps the moved ids to Y's content (20 bytes), while the engine's
    /// side of that apply waits (`holdNextApplyFollow`). O commits: the store binds zz-o alone, and the engine's copy (v3)
    /// still maps the others to O's content, so the commit refuses (C1) and holds O's content for the manifest
    /// (`holdForManifest`) before it re-routes them: at once with one id (1 + 1 fit `inboundIDsNow`), owed with three. Once
    /// the follow and the drain are over, the re-routes wait on a fresh job of O's content that is not dispatched; then
    /// the engine follows v4 and the moved ids get Y's bytes. Visited first, the same, the fresh job made in the commit's
    /// turn.
    @available(macOS 15.0, iOS 18.0, *)
    func capturedRefused(_ visit: LaneDropVisit, moved count: Int, seed: UInt64) async throws -> CapturedRefusedOutcome {
        let c = try await Self.stageOwedCommit(seed: seed, moved: count)
        let engine = c.engine
        let o = c.transfer
        let yBytes = EngineFixture.bytes(seed + 4, count: 20)
        let onY = c.ids.map { EngineHarness.onDemand($0.rawValue, yBytes) }
        await c.s.harness.source.script(onY[0].transferID, [.stage(yBytes)])
        try await Self.applyHeld(c.manifest(c.moved, round: 1), tag: "v3-captured-\(seed)", c.s, visit: visit)
        let (units, releaser) = try await Self.holdPublications(of: [o], c.s, bulk: c.bulk)
        let v4 = try ValidatedManifest(entries: c.manifest(onY, round: 2), digest: ContentHash.sha256(of: Data("v4-captured-\(seed)".utf8)))
        await engine.holdNextApplyFollow()
        let applying = Task { await engine.applyAndFollow(v4, etag: nil, eviction: nil) }
        await engine.awaitCondition { $0.applyFollowHeld && $0.state.appliesInFlight == 1 }
        await engine.readForTests { $0.holdDrainFollowUps() }
        await c.bulk.release(units[0])
        var outcome = CapturedRefusedOutcome()
        outcome.k = Self.sizes([await EngineHarness.value(of: c.k)])[0]
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
        outcome.w = Self.sizes(await Self.owedAnswers(c).w)
        await Self.finishHeld(c.s)
        return outcome
    }

    /// rr21-T3-captured on the fit path (rr21-B3): one refused id is re-routed in the commit's turn onto a fresh job of
    /// O's content held for the manifest.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit that re-routes at once an id its binding captured and the store refused holds the fresh job until the copy catches up (F-20, C1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitHoldsTheFreshJobOfARefusedIDOnTheFitPath(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.capturedRefused(visit, moved: 1, seed: 2_027_201)
        #expect(outcome.batches == 0, "setup: 1 + 1 fit the commit's turn: \(outcome)")
        #expect(outcome.held && outcome.state == .queued && outcome.starts == 1, "the refused id waits on a fresh job of O's content, held for the manifest, not downloaded again: \(outcome)")
        #expect(outcome.k == 16 && outcome.w == [20], "K gets O's bytes, and the refused id follows v4 to Y's: \(outcome)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    /// rr21-T3-captured on the owing path (rr21-B3, rr21-B4): three refused ids are owed (1 + 3 pass `inboundIDsNow`),
    /// and the commit's closure holds O's content for the manifest before it owes them, so the drain's re-routes wait on
    /// a fresh job that is not dispatched.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit that owes the re-routes of ids its binding captured and the store refused holds the fresh job until the copy catches up (F-20, C1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitHoldsTheFreshJobOfRefusedIDsOnTheOwingPath(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.capturedRefused(visit, moved: 3, seed: 2_027_211)
        #expect(outcome.batches == 1, "setup: 1 + 3 pass the commit's turn, so it owes one batch: \(outcome)")
        #expect(outcome.held && outcome.state == .queued && outcome.starts == 1, "the refused ids wait on a fresh job of O's content, held for the manifest, not downloaded again: \(outcome)")
        #expect(outcome.k == 16 && outcome.w == [20, 20, 20], "K gets O's bytes, and the refused ids follow v4 to Y's: \(outcome)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    // MARK: T-R1: an id moved away holds nothing

    /// T-R1 (`design2-commit-window.md` N3): v4 maps zz-a1…zz-a3 to W's content (20 bytes) while O's publication waits at
    /// the store. The commit owes their re-routes, and holds nothing for the manifest: the copy maps them away, which no
    /// newer manifest of the store explains (R4's moved-away predicate).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit holds nothing for the manifest for the ids an apply moved away (F-20, C1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitHoldsNothingForIDsMovedAway(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_221
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3)
        let engine = c.engine
        let wBytes = EngineFixture.bytes(seed + 9, count: 20)
        let onW = c.ids.map { EngineHarness.onDemand($0.rawValue, wBytes) }
        await c.s.harness.source.script(onW[0].transferID, [.stage(wBytes)])
        let (units, releaser) = try await Self.holdPublications(of: [c.transfer], c.s, bulk: c.bulk)
        try await Self.applyHeld(c.manifest(onW, round: 1), tag: "v4-moved-away-\(seed)", c.s, visit: visit)
        let batches = await Self.commitOwing(c, unit: units[0])
        let held = await engine.readForTests { $0.state.heldForManifest }
        #expect(batches.count == 1 && batches.first?.items.count == 3, "setup: the commit owes the three re-routes: \(batches.map(\.items.count))")
        #expect(held.isEmpty, "nothing is held for the manifest: \(held)")
        releaser.cancel()
        await releaser.value
        await c.bulk.setHolding(false)
        let turns = await Self.releaseOwedTurns(c)
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        let answers = await Self.owedAnswers(c)
        #expect(Self.sizes([answers.k]) == [16] && Self.sizes(answers.w) == [20, 20, 20], "K gets O's bytes, W1…W3 W's: \(Self.sizes([answers.k] + answers.w))")
        await Self.finishHeld(c.s)
    }

    /// T-R1's delisted sibling (Stage 3 close-out cycle 22, ruling S3-R27 item 5; d4 §3.4 with its review's M4): v4 maps
    /// zz-a1 and zz-a2 to W's content and omits zz-a3, and before O's commit a further apply, v5 (the same ids, other
    /// fillers), is held in flight after the store applied it (`holdNextApplyFollow`). The commit owes the three
    /// re-routes and holds nothing for the manifest: the copy no longer lists zz-a3, so it is moved, not refused. A hold
    /// would wait for v5's follow, since a catch-up is in flight, so the set is read before v5 is released, in both
    /// orders. The answers: W1 and W2 W's bytes, W3 `.notFound` (T21), K O's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit holds nothing for the manifest for an id an apply delisted, while another apply is in flight (F-20, C1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitHoldsNothingForADelistedIDWhileAnApplyIsInFlight(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_029_401
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3)
        let engine = c.engine
        let wBytes = EngineFixture.bytes(seed + 9, count: 20)
        let onW = Array(c.ids.map { EngineHarness.onDemand($0.rawValue, wBytes) }.prefix(2))
        await c.s.harness.source.script(onW[0].transferID, [.stage(wBytes)])
        let (units, releaser) = try await Self.holdPublications(of: [c.transfer], c.s, bulk: c.bulk)
        try await Self.applyHeld(c.manifest(onW, round: 1), tag: "v4-delisted-\(seed)", c.s, visit: visit)
        let v5 = try ValidatedManifest(entries: c.manifest(onW, round: 2), digest: ContentHash.sha256(of: Data("v5-delisted-\(seed)".utf8)))
        await engine.holdNextApplyFollow()
        let applying = Task { await engine.applyAndFollow(v5, etag: nil, eviction: nil) }
        await engine.awaitCondition { $0.applyFollowHeld && $0.state.appliesInFlight == 1 }
        let batches = await Self.commitOwing(c, unit: units[0])
        let held = await engine.readForTests { $0.state.heldForManifest }
        #expect(batches.count == 1 && batches.first?.items.count == 3, "setup: the commit owes the three re-routes: \(batches.map(\.items.count))")
        #expect(held.isEmpty, "nothing is held for the manifest (visit-first): \(held)")
        releaser.cancel()
        await releaser.value
        await c.bulk.setHolding(false)
        await engine.readForTests { $0.releaseApplyFollow() }
        let applied = await applying.value
        #expect((try? applied.get()) != nil, "setup: v5 is applied: \(applied)")
        let turns = await Self.releaseOwedTurns(c)
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        let answers = await Self.owedAnswers(c)
        #expect(Self.sizes([answers.k] + answers.w.prefix(2)) == [16, 20, 20] && answers.w.last == .failure(.notFound), "K gets O's bytes, W1 and W2 W's, W3 notFound (visit-first): K \(answers.k), W \(answers.w)")
        await Self.finishHeld(c.s)
    }

    // MARK: T-R2: an id its job took after the capture holds nothing

    /// T-R2 (`design2-commit-window.md` N3): zz-n shares O's content, unwanted while O's publication begins (held at its
    /// first store unit), so the binding does not capture it; then a user waiter N asks for zz-n and joins O's job, and v3
    /// changes only the fillers (swept first, its follow stays owed). O commits: the store binds zz-o alone, and zz-n,
    /// which the copy still maps to O's content, is re-routed at once (1 + 1 fit `inboundIDsNow`) onto a fresh job of O's
    /// content that starts at once: the binding never named it, so nothing explains the store's refusal by a newer
    /// manifest (C1's `captured.contains`). Swept first, the re-route's join waits for the drain, which makes the job.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit holds nothing for the manifest for an id its job took after the binding was captured (F-20, C1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitHoldsNothingForAnIDTheBindingDidNotCapture(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_231
        let n = EngineHarness.onDemand("zz-n", Self.owedOBytes(seed))
        let c = try await Self.stageOwedCommit(seed: seed, moved: 0, extra: [n])
        let engine = c.engine
        let o = c.transfer
        await c.s.harness.source.script(o, [.hold, .stage(Self.owedOBytes(seed)), .stage(Self.owedOBytes(seed))])
        let (units, releaser) = try await Self.holdPublications(of: [o], c.s, bulk: c.bulk)
        let nID = n.identifier
        let nWaiter = Task { await engine.awaitAsset(nID, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[o]?.assets.contains(nID) == true }
        try await Self.applyHeld(c.manifest([n], round: 1), tag: "v3-uncaptured-\(seed)", c.s, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await c.bulk.release(units[0])
        let k = await EngineHarness.value(of: c.k)
        let afterCommit = await engine.readForTests { e in (e.state.heldForManifest, Self.owedBatches(e).count) }
        #expect(afterCommit.0.isEmpty && afterCommit.1 == 0, "the commit holds nothing for the manifest and owes nothing: \(afterCommit)")
        let turns = await Self.releaseOwedTurns(c)
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[o]?.state == .downloading || $0.state.jobs[o] == nil }
        }
        let fresh = await engine.readForTests { e in (e.state.jobs[o]?.state, e.state.jobs[o]?.assets) }
        #expect(fresh.0 == .downloading && fresh.1 == [nID], "zz-n's fresh job of O's content starts at once: \(fresh)")
        releaser.cancel()
        await releaser.value
        await c.bulk.setHolding(false)
        await c.s.harness.source.release(o, with: .progress(received: 0, expected: nil))
        let nResult = await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await EngineHarness.value(of: nWaiter) }
        #expect(Self.sizes([k, nResult]) == [16, 16], "K and N get O's bytes: \(Self.sizes([k, nResult]))")
        await Self.finishHeld(c.s)
    }

    // MARK: reqs #7: a token with one bound id and one unbound id

    /// The cycle-20 requirements verifier's reqs #7 (`integrate-c21.md` interaction 8): one prefetch group wants zz-o and
    /// zz-a1, and v4 maps zz-a1 to W's content (20 bytes, held). The commit binds zz-o: the group's interest keeps zz-o,
    /// which the commit answers, and gives up zz-a1 alone (`subtractAssets`), which it re-routes at once (1 + 1 fit
    /// `inboundIDsNow`) onto W's job. The group then waits for zz-a1 alone, on W, until W commits.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit keeps a token's bound id and re-routes its unbound one (reqs #7, C1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitKeepsATokensBoundIDAndReroutesItsUnboundOne(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_241
        let c = try await Self.stageOwedCommit(seed: seed, moved: 1, wanters: .group)
        let engine = c.engine
        let group = try #require(c.group)
        let wBytes = EngineFixture.bytes(seed + 9, count: 20)
        let onW = EngineHarness.onDemand(c.ids[0].rawValue, wBytes)
        let w = onW.transferID
        await c.s.harness.source.script(w, [.hold, .stage(wBytes)])
        let (units, releaser) = try await Self.holdPublications(of: [c.transfer], c.s, bulk: c.bulk)
        try await Self.applyHeld(c.manifest([onW], round: 1), tag: "v4-one-token-\(seed)", c.s, visit: visit)
        let batches = await Self.commitOwing(c, unit: units[0])
        #expect(batches.isEmpty, "setup: 1 + 1 fit the commit's turn: \(batches.map(\.items.count))")
        let turns = await Self.releaseOwedTurns(c)
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        let afterCommit = await engine.readForTests { e in (e.state.groups[group]?.pending, e.state.jobs[w]?.interests[group]?.assets) }
        #expect(afterCommit.0 == [c.ids[0]: w] && afterCommit.1 == [c.ids[0]], "the group's zz-o is answered, and its zz-a1 alone waits on W: \(afterCommit)")
        releaser.cancel()
        await releaser.value
        await c.bulk.setHolding(false)
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[w]?.state == .downloading }
        }
        await c.s.harness.source.release(w, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.groups[group]?.pending.isEmpty ?? true }
        }
        let k = await EngineHarness.value(of: c.k)
        #expect(Self.sizes([k]) == [16], "K gets O's bytes: \(k)")
        let stored = await c.s.harness.store.location(for: c.ids[0], extensions: [], recordingAccess: false)
        #expect(stored?.byteSize == 20, "the group's zz-a1 is stored from W's content: \(String(describing: stored))")
        await engine.releaseGroup(group)
        await Self.finishHeld(c.s)
    }
}
