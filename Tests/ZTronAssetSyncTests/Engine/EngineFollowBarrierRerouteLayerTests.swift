import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The layers of an owed batch of re-routes (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md` R10,
/// R11 and the branches rr21-B16 to rr21-B20): each apply between the owing instant and the replay records the copy it
/// replaces and the jobs then at an attempt's end (`layerOwedReroutes`), and the replay follows each id through them as
/// a visit-first engine's visits moved the interest its commit had re-routed at once (`rerouteListing`). The commit is
/// `stageOwedCommit`'s: K0 (swept or visited first, as `LaneDropVisit` says) maps zz-a1…zz-a3 off O's content, O's
/// publication commits zz-o for K and owes W1…W3's re-routes under K0's copy; the later applies land with their follows
/// held in both orders, so the batch waits for the drain behind them. Each test expects the visit-first answers in
/// both orders.
extension EngineFollowBarrierTests {
    /// What a layer test read once the follow and the drain were over: K's answer, W1…W3's, the other waiters', and the
    /// invariant violations read after each released turn.
    struct LayerOutcome: CustomStringConvertible {
        let k: Result<AssetLocation, AssetError>
        let w: [Result<AssetLocation, AssetError>]
        let others: [Result<AssetLocation, AssetError>]
        let violations: [String]

        var description: String {
            "K \(EngineFollowBarrierTests.sizes([self.k])), W \(self.w), others \(self.others); violations \(self.violations.prefix(3))"
        }
    }

    /// zz-a1…zz-a<n> on `bytes`' content, as the test's applies map them.
    @available(macOS 15.0, iOS 18.0, *)
    static func movedOnto(_ bytes: Data, _ c: OwedCommit, checksum: Bool = true) -> [ManifestEntry] {
        c.ids.map { EngineFixture.entry($0.rawValue, bytes, policy: .onDemand, checksum: checksum) }
    }

    /// Holds the publications of O and of `publishing` at their first store units, applies K0 (swept or visited first),
    /// and commits O with the drain's turns held; requires one batch of `items` re-routes. Returns the units still held:
    /// `publishing`'s.
    @available(macOS 15.0, iOS 18.0, *)
    static func oweThroughK0(_ c: OwedCommit, k0: [ManifestEntry], publishing: [TransferID] = [], items: Int? = nil, visit: LaneDropVisit) async throws -> HeldUnits {
        let engine = c.engine
        let transfer = c.transfer
        let (units, releaser) = try await Self.holdPublications(of: [transfer] + publishing, c.s, bulk: c.bulk)
        var held = HeldUnits(bulk: c.bulk, kept: units, releaser: releaser)
        try await Self.applyHeld(c.manifest(k0, round: 1), tag: "k0-layers-\(c.seed)", c.s, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        await engine.awaitCondition { $0.state.jobs[transfer] == nil }
        let batches = await engine.readForTests { e in Self.owedBatches(e) }
        let expected = items ?? c.moved.count
        try #require(batches.count == 1 && batches.first?.items.count == expected, "setup: O's commit owes its \(expected) re-routes as one batch: \(batches.map(\.items.count))")
        return held
    }

    /// Releases the held turns one at a time (`releaseOwedTurns`), then the downloads of `releasing` held at the source,
    /// had they started, and the held store units, and reads every answer.
    @available(macOS 15.0, iOS 18.0, *)
    static func finishOwed(_ c: OwedCommit, held: HeldUnits, others: [Task<Result<AssetLocation, AssetError>, Never>] = [], releasing: [TransferID] = []) async -> LayerOutcome {
        let turns = await Self.releaseOwedTurns(c)
        for transfer in releasing {
            await c.s.harness.source.release(transfer, with: .progress(received: 0, expected: nil))
        }
        await held.stop()
        let answers = await Self.owedAnswers(c)
        var rest: [Result<AssetLocation, AssetError>] = []
        for other in others {
            rest.append(await EngineRegressionCycle6Tests.driving([c.s.time], fence: c.engine) { await EngineHarness.value(of: other) })
        }
        return LayerOutcome(k: answers.k, w: answers.w, others: rest, violations: turns.violations)
    }

    /// A waiter on `lane` for `entry`'s id, once its job downloads.
    @available(macOS 15.0, iOS 18.0, *)
    static func downloadingWaiter(_ entry: ManifestEntry, _ c: OwedCommit, lane: AssetPriority = .userInitiated) async -> Task<Result<AssetLocation, AssetError>, Never> {
        let engine = c.engine
        let id = entry.identifier
        let transfer = entry.transferID
        let waiter = Task { await engine.awaitAsset(id, lane: lane) }
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[transfer]?.state == .downloading && $0.state.jobs[transfer]?.interests.isEmpty == false }
        }
        return waiter
    }

    // MARK: rr21-T4: T21 at the owing instant

    /// rr21-T4 (rr21-B16): K0 drops zz-a1…zz-a3, wanted by W1…W3, a prefetch group and (zz-a1) a heal's system interest,
    /// while O publishes; O's commit owes their re-routes under K0's copy, which does not list them; K1 lists them again
    /// on W's content before the replay. Visited first, the commit's re-routes ended the interests (T21): the waiters got
    /// `.notFound`, the group dropped the members and the heal was forgotten. The replay follows the owing instant's copy
    /// (`rerouteListing`'s `return batch.copy`), not K1's: W's content is never requested. Visited first, K1's follow has
    /// no job to visit and replays the batch at its end, after K1's layer; swept first, the batch waits for the turns.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route of an id the owing instant's copy dropped ends its interest though a later apply lists it again (F-28, T21)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedRerouteOfADroppedIDEndsItsInterest(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_401
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, wanters: .waitersAndGroup)
        let engine = c.engine
        let o = c.transfer
        let a1 = c.ids[0]
        let group = try #require(c.group)
        await engine.readForTests { $0.scheduleHeal(a1, at: $0.environment.time.monotonicNow()) }
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[o]?.interests.values.contains { $0.kind == .system } == true }
        }
        let wBytes = EngineFixture.bytes(seed + 9, count: 20)
        let onW = Self.movedOnto(wBytes, c)
        let w = onW[0].transferID
        await c.s.harness.source.script(w, [.stage(wBytes)])
        // Three waiters, three members of the group and the heal, on three ids.
        let held = try await Self.oweThroughK0(c, k0: [], items: 7, visit: visit)
        try await Self.applyBehindBatch(c.manifest(onW, round: 2), tag: "k1-relisted-\(seed)", c, waits: visit == .sweepFollowsFirst)
        let turns = await Self.releaseOwedTurns(c)
        let after = await engine.readForTests { e in (heal: e.state.heals[a1], pending: e.state.groups[group]?.pending.keys.sorted() ?? []) }
        #expect(after.heal == nil, "the heal of zz-a1 is forgotten (visit-first): \(String(describing: after.heal))")
        #expect(after.pending.allSatisfy { !c.ids.contains($0) }, "the group dropped zz-a1…zz-a3 (visit-first): \(after.pending)")
        await held.stop()
        let answers = await Self.owedAnswers(c)
        #expect(Self.sizes([answers.k]) == [16], "K gets O's bytes: \(answers.k)")
        #expect(answers.w.allSatisfy { $0 == .failure(.notFound) }, "W1…W3 get .notFound (visit-first): \(answers.w)")
        #expect(await Self.starts(w, c) == 0, "W's content is never requested")
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T5 and RR21-HOP at site 1: a pin while the job publishes

    /// How P's publication ends in `publishingPin`.
    enum PinnedEnd: Sendable {
        /// P's bytes fail their check (`.integrity`). P publishes, held at its first store unit, from before K0.
        case integrity
        /// The store refuses P's publication (`.storageUnavailable(.rootVanished)`): the arm `publicationFailed` shares
        /// with `.locked`, which the store throws only at open (`StoreLock.swift:16`). P's publication begins after O's
        /// commit and waits for the owed re-routes (`inboundBlocks`); the store's root stops verifying before it resumes
        /// (`AssetStore.verifyRootNow`), so the store refuses it at its start (`checkWritable`). A checksum-less P, which
        /// the store commits before it returns (`AssetStore+Publish.swift:158-163`), holds only its own id (a legacy
        /// transfer, `ManifestEntry.transferID`), so no moved id could re-route onto it.
        case storageUnavailable
    }

    /// rr21-T5 and RR21-HOP at site 1 (rr21-B17, rr21-B20's publishing term): zz-p (Q's) is P's content, which downloads;
    /// K0 maps zz-a1…zz-a3 to it, O's commit owes their re-routes, and K1 maps them to Z's content while P publishes (see
    /// `PinnedEnd`). P's publication then fails. Visited first, the commit re-routed W1…W3 onto P, K1's visit passed P
    /// publishing (RR-14) and P's end answered them. The replay pins the ids to P (K1's layer holds P among its ends), so
    /// W1…W3 get P's failure and Z is never requested. With `joining` (RR21-HOP's join variant, `integrate-rr21.md` R18),
    /// v2 and K0 also list zz-j on P's content, which J requests once O's commit owes its batch: J's join waits behind the
    /// batch in both orders, and K1 maps zz-j to Z's content too. Visited first, J joined P at once, K1's visit passed P
    /// and P's end answered J. Returns Q's answer (and J's) with the outcome, and Z's starts.
    @available(macOS 15.0, iOS 18.0, *)
    func publishingPin(_ visit: LaneDropVisit, seed: UInt64, end: PinnedEnd, joining: Bool = false) async throws -> (outcome: LayerOutcome, zStarts: Int) {
        let pBytes = EngineFixture.bytes(seed + 5, count: 18)
        let zBytes = EngineFixture.bytes(seed + 6, count: 20)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let joined = joining ? [EngineHarness.onDemand("zz-j", pBytes)] : []
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [p] + joined)
        let engine = c.engine
        let pT = p.transferID
        let onP = Self.movedOnto(pBytes, c)
        let onZ = Self.movedOnto(zBytes, c)
        let z = onZ[0].transferID
        var staged = pBytes
        if end == .integrity {
            staged[0] ^= 0xFF
        }
        await c.s.harness.source.script(pT, [.hold, .stage(staged)])
        await c.s.harness.source.script(z, [.stage(zBytes)])
        let q = await Self.downloadingWaiter(p, c)
        var held: HeldUnits
        switch end {
        case .integrity:
            held = try await Self.oweThroughK0(c, k0: [p] + onP + joined, publishing: [pT], visit: visit)
        case .storageUnavailable:
            held = try await Self.oweThroughK0(c, k0: [p] + onP + joined, visit: visit)
            await c.s.harness.source.release(pT, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[pT]?.state == .verifying && $0.state.inboundWaits[pT] != nil }
        }
        var others = [q]
        for entry in joined {
            let id = entry.identifier
            others.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            await engine.awaitCondition { FollowBarrier.joinWaits($0, entry) }
        }
        let movedJoins = joined.map { EngineHarness.onDemand($0.identifier.rawValue, zBytes) }
        try await Self.applyBehindBatch(c.manifest([p] + onZ + movedJoins, round: 2), tag: "k1-hop-\(seed)", c)
        #expect(await Self.pins(pT, c) == [true], "setup: K1's layer pins P, which publishes")
        switch end {
        case .integrity:
            await held.release(held.kept[0])
            await engine.awaitCondition { $0.state.verdictsAfterFollow[pT] != nil }
        case .storageUnavailable:
            let lock = try #require(c.s.fileSystem.operations.last { $0.kind == .acquireExclusiveLock }?.url)
            try c.s.fileSystem.removeItem(at: lock)
            let reason = await c.s.harness.store.verifyRootNow()
            try #require(reason == .rootVanished, "setup: the store's root no longer verifies: \(String(describing: reason))")
        }
        let outcome = await Self.finishOwed(c, held: held, others: others)
        let zStarts = await Self.starts(z, c)
        await Self.finishHeld(c.s)
        return (outcome, zStarts)
    }

    /// rr21-T5 and RR21-HOP's integrity variant at site 1.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route pinned to a job a later apply passed publishing gets that publication's integrity failure (F-28, RR-14)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedReroutePinnedToAPublishingJobGetsItsIntegrityFailure(_ visit: LaneDropVisit) async throws {
        let (outcome, zStarts) = try await self.publishingPin(visit, seed: 2_027_411, end: .integrity)
        #expect(outcome.others == [.failure(.integrityFailure)], "Q gets P's integrity failure: \(outcome)")
        #expect(outcome.w.allSatisfy { $0 == .failure(.integrityFailure) }, "W1…W3, passed on P by K1's visit (visit-first), get P's failure: \(outcome)")
        #expect(Self.sizes([outcome.k]) == [16] && zStarts == 0, "K gets O's bytes, and Z is never requested: \(outcome), Z's starts \(zStarts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    /// RR21-HOP's storage variant at site 1: the arm `.locked` shares (`publicationFailed`), reached through a store whose
    /// root stopped verifying while P's publication waited for the owed re-routes (`PinnedEnd.storageUnavailable`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route pinned to a job a later apply passed publishing gets that publication's storage failure (F-28, RR-14)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedReroutePinnedToAPublishingJobGetsItsStorageFailure(_ visit: LaneDropVisit) async throws {
        let (outcome, zStarts) = try await self.publishingPin(visit, seed: 2_027_416, end: .storageUnavailable)
        #expect(outcome.others == [.failure(.storageUnavailable(.rootVanished))], "Q gets P's storage failure: \(outcome)")
        #expect(outcome.w.allSatisfy { $0 == .failure(.storageUnavailable(.rootVanished)) }, "W1…W3, passed on P by K1's visit (visit-first), get P's failure: \(outcome)")
        #expect(Self.sizes([outcome.k]) == [16] && zStarts == 0, "K gets O's bytes, and Z is never requested: \(outcome), Z's starts \(zStarts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    // MARK: rr21-T6: a pin while the job's verdict waits behind the batch

    /// rr21-T6 (rr21-B20's verdict term): zz-x (V's) is X's content, which downloads; K0 maps zz-a1…zz-a3 to it, O's
    /// commit owes their re-routes, and X's 404 arrives, its verdict deferred behind the batch; then K1 maps the ids to
    /// W's content. Visited first, the commit re-routed W1…W3 onto X downloading and X's 404 answered them at once,
    /// before K1. The replay pins the ids to X (K1's layer holds X's waiting verdict among its ends), and X's verdict
    /// answers them `.notFound`; W is never requested.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route pinned to a job whose verdict waits behind it gets that verdict though a later apply moved its id (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedReroutePinnedToAWaitingVerdictGetsIt(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_421
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let wBytes = EngineFixture.bytes(seed + 6, count: 20)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x])
        let engine = c.engine
        let xT = x.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        let w = onW[0].transferID
        await c.s.harness.source.script(xT, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await c.s.harness.source.script(w, [.stage(wBytes)])
        let v = await Self.downloadingWaiter(x, c)
        let held = try await Self.oweThroughK0(c, k0: [x] + onX, visit: visit)
        await c.s.harness.source.release(xT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.verdictsAfterFollow[xT] != nil }
        try await Self.applyBehindBatch(c.manifest([x] + onW, round: 2), tag: "k1-verdict-pin-\(seed)", c)
        #expect(await Self.pins(xT, c) == [true], "setup: K1's layer pins X, whose verdict waits behind the batch")
        let outcome = await Self.finishOwed(c, held: held, others: [v])
        #expect(outcome.others == [.failure(.notFound)] && outcome.w.allSatisfy { $0 == .failure(.notFound) }, "V and W1…W3 get X's 404 (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.k]) == [16], "K gets O's bytes: \(outcome)")
        #expect(await Self.starts(w, c) == 0, "W is never requested")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T7: a verdict queued before the batch pins nothing

    /// rr21-T7 (rr21-B20's "behind the batch"): zz-x (V's) is X's content, which downloads; K0 maps zz-a1…zz-a3 to it,
    /// and X's 404 arrives before O's commit, so swept first its verdict waits ahead of the batch (visited first it is
    /// given at once: no follow is owed and nothing waits). K1 maps the ids to W's content, K2 drops them and K3 lists
    /// them on W's again, W's download held at the source. Visited first, the commit re-routed W1…W3 to X's content after
    /// X's verdict, K1's visit moved them to W's and K2's ended them (T21) before W's bytes arrived. Swept first, a verdict
    /// ahead of the batch has replayed when the batch does, so it pins nothing: the replay follows the layers to K2's copy
    /// and answers `.notFound`, and W is never requested. Visited first, K1's follow has no job to visit and replays the
    /// batch at its end: W is requested, and K2's visit ends the interests on W's held job. The state, a verdict waiting
    /// ahead of a batch, arises only swept first (ruling S3-R26 item 12's answer 1: the `#require` on `ahead`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a verdict that waited ahead of an owed batch pins none of its re-routes (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func verdictAheadOfAnOwedBatchPinsNothing(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_431
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let wBytes = EngineFixture.bytes(seed + 6, count: 20)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x])
        let engine = c.engine
        let xT = x.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        let w = onW[0].transferID
        await c.s.harness.source.script(xT, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await c.s.harness.source.script(w, [.hold, .stage(wBytes)])
        let v = await Self.downloadingWaiter(x, c)
        let (units, releaser) = try await Self.holdPublications(of: [c.transfer], c.s, bulk: c.bulk)
        var held = HeldUnits(bulk: c.bulk, kept: units, releaser: releaser)
        try await Self.applyHeld(c.manifest([x] + onX, round: 1), tag: "k0-ahead-\(seed)", c.s, visit: visit)
        await c.s.harness.source.release(xT, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[xT] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[xT] == nil }
        }
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        let o = c.transfer
        await engine.awaitCondition { $0.state.jobs[o] == nil }
        let batches = await engine.readForTests { e in Self.owedBatches(e) }
        try #require(batches.count == 1 && batches.first?.items.count == 3, "setup: O's commit owes W1…W3's re-routes: \(batches.map(\.items.count))")
        let ahead = await engine.readForTests { e in
            let events = e.state.eventsAfterFollow
            let verdict = events.firstIndex { $0.verdictKey?.transfer == xT }
            let batch = events.firstIndex { event in
                if case .reroutes = event {
                    return true
                }
                return false
            }
            return verdict.flatMap { v in batch.map { v < $0 } } ?? false
        }
        try #require(ahead == (visit == .sweepFollowsFirst), "setup: swept first, X's verdict waits ahead of the batch; visited first it was given")
        let swept = visit == .sweepFollowsFirst
        try await Self.applyBehindBatch(c.manifest([x] + onW, round: 2), tag: "k1-ahead-\(seed)", c, waits: swept)
        if !swept {
            // K1's follow, with no job to visit, replayed the batch at its end; each follow then ends before the next apply,
            // as visited first (`applyHeld`), and the drain's follow-up the owing scheduled finds nothing left.
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseDrainFollowUps()
            }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        for (round, entries) in [(UInt64(3), [x]), (4, [x] + onW)] {
            let tag = "k\(round - 1)-ahead-\(seed)"
            if swept {
                try await Self.applyBehindBatch(c.manifest(entries, round: round), tag: tag, c)
            } else {
                try await Self.applyHeld(c.manifest(entries, round: round), tag: tag, c.s, visit: visit)
            }
        }
        #expect(await Self.pins(xT, c) == (swept ? [false, false, false] : []), "no layer pins X")
        let outcome = await Self.finishOwed(c, held: held, others: [v], releasing: [w])
        #expect(outcome.others == [.failure(.notFound)], "V gets X's 404: \(outcome)")
        #expect(outcome.w.allSatisfy { $0 == .failure(.notFound) }, "W1…W3 are ended by K2's drop (visit-first): \(outcome)")
        let wStarts = await Self.starts(w, c)
        #expect(Self.sizes([outcome.k]) == [16], "K gets O's bytes: \(outcome)")
        #expect(wStarts == (swept ? 0 : 1), "swept first W is never requested; visited first K2's drop ends its one request: \(wStarts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T8: a pin whose job committed follows the copy now

    /// rr21-T8 (rr21-B17's left pin): zz-x (V's) is X's content; X publishes, held at its first store unit, while O does;
    /// K0 maps zz-a1…zz-a3 to X's content, O's commit owes their re-routes, K1 maps them to W's content while X still
    /// publishes, and X then commits, before the replay. Visited first, the commit re-routed W1…W3 onto X publishing, K1's
    /// visit passed X, and X's commit, which bound zz-x alone, re-routed them under K1's copy to W's job. The replay finds
    /// X's job gone (`waitingTarget` is `nil`) and follows the copy now: one new job, W's, and none of X's content.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route pinned to a job that committed before the replay follows the copy then (F-28, T22)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedReroutePinnedToACommittedJobFollowsTheCopy(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_441
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let wBytes = EngineFixture.bytes(seed + 6, count: 20)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x])
        let engine = c.engine
        let xT = x.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        let w = onW[0].transferID
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes), .stage(xBytes)])
        await c.s.harness.source.script(w, [.hold, .stage(wBytes)])
        let v = await Self.downloadingWaiter(x, c)
        var held = try await Self.oweThroughK0(c, k0: [x] + onX, publishing: [xT], visit: visit)
        try await Self.applyBehindBatch(c.manifest([x] + onW, round: 2), tag: "k1-left-pin-\(seed)", c)
        #expect(await Self.pins(xT, c) == [true], "setup: K1's layer pins X, which publishes")
        await held.release(held.kept[0])
        await engine.awaitCondition { $0.state.jobs[xT] == nil }
        let created = await engine.readForTests { $0.state.jobsCreated }
        let turns = await Self.releaseOwedTurns(c)
        let after = await engine.readForTests { e in (created: e.state.jobsCreated, w: e.state.jobs[w]?.assets.sorted() ?? [], x: e.state.jobs[xT] != nil) }
        #expect(after.created == created + 1 && after.w == c.ids && !after.x, "the replay makes one job, W's, with the three ids, and none of X's content: \(after), \(created) before")
        await c.s.harness.source.release(w, with: .progress(received: 0, expected: nil))
        await held.stop()
        let answers = await Self.owedAnswers(c)
        let vResult = await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await EngineHarness.value(of: v) }
        #expect(Self.sizes([answers.k, vResult]) == [16, 18] && Self.sizes(answers.w) == [20, 20, 20], "K gets O's bytes, V X's, W1…W3 W's (visit-first): \(answers), V \(vResult)")
        #expect(await Self.starts(xT, c) == 1, "X's content is requested once")
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T9: a double hop

    /// rr21-T9 (rr21-B19): zz-y (V's) is Y's content, which downloads; K0 maps zz-a1…zz-a3 to X's content (no job), O's
    /// commit owes their re-routes, K1 maps them to Y's content, Y's publication begins (and waits: a re-route is owed),
    /// and K2 maps them to W's content while Y publishes; Y's bytes then fail their check. Visited first, the commit
    /// re-routed W1…W3 to X's content, K1's visit moved them to Y's job, which then published them, K2's visit passed Y
    /// (RR-14) and Y's end answered them. The replay follows K1's layer to Y and K2's layer pins it there.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route follows each later apply's move and is pinned where a later one passed the job publishing (F-28, RR-14)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedRerouteFollowsTwoHopsToAPublishingJob(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_451
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let yBytes = EngineFixture.bytes(seed + 6, count: 22)
        let wBytes = EngineFixture.bytes(seed + 7, count: 20)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [y])
        let engine = c.engine
        let yT = y.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onY = Self.movedOnto(yBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        let w = onW[0].transferID
        var corrupt = yBytes
        corrupt[0] ^= 0xFF
        await c.s.harness.source.script(onX[0].transferID, [.hold])
        await c.s.harness.source.script(yT, [.hold, .stage(corrupt)])
        await c.s.harness.source.script(w, [.stage(wBytes)])
        let v = await Self.downloadingWaiter(y, c)
        let held = try await Self.oweThroughK0(c, k0: [y] + onX, visit: visit)
        try await Self.applyBehindBatch(c.manifest([y] + onY, round: 2), tag: "k1-hop-\(seed)", c)
        await c.s.harness.source.release(yT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[yT]?.state == .verifying && $0.state.inboundWaits[yT] != nil }
        try await Self.applyBehindBatch(c.manifest([y] + onW, round: 3), tag: "k2-hop-\(seed)", c)
        #expect(await Self.pins(yT, c) == [false, true], "setup: K2's layer pins Y, which publishes")
        let outcome = await Self.finishOwed(c, held: held, others: [v])
        #expect(outcome.others == [.failure(.integrityFailure)] && outcome.w.allSatisfy { $0 == .failure(.integrityFailure) }, "V and W1…W3 get Y's integrity failure (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.k]) == [16], "K gets O's bytes: \(outcome)")
        let starts = [await Self.starts(w, c), await Self.starts(onX[0].transferID, c)]
        #expect(starts == [0, 0], "neither W nor X is requested: \(starts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T10: a later apply's drop ends the interest

    /// rr21-T10 (rr21-B18): K0 maps zz-a1…zz-a3 to X's content (no job), O's commit owes their re-routes, K1 drops them and
    /// K2 lists them on W's content. Visited first, K1's visit ended W1…W3's interests (T21). The replay stops at K1's
    /// layer, whose copy does not list them, and answers `.notFound`: swept first after K2, at the released turns; visited
    /// first at K1's follow's end, which has no job to visit (the chain then ends at K1's copy, the engine's).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route whose id a later apply dropped ends its interest though a still later apply lists it again (F-28, T21)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedRerouteEndsAtALaterDrop(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_461
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let wBytes = EngineFixture.bytes(seed + 6, count: 20)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3)
        let onX = Self.movedOnto(xBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        let x = onX[0].transferID
        let w = onW[0].transferID
        await c.s.harness.source.script(x, [.hold])
        await c.s.harness.source.script(w, [.stage(wBytes)])
        let held = try await Self.oweThroughK0(c, k0: onX, visit: visit)
        try await Self.applyBehindBatch(c.manifest([], round: 2), tag: "k1-drop-\(seed)", c, waits: visit == .sweepFollowsFirst)
        try await Self.applyBehindBatch(c.manifest(onW, round: 3), tag: "k2-relist-\(seed)", c, waits: visit == .sweepFollowsFirst)
        let outcome = await Self.finishOwed(c, held: held)
        #expect(outcome.w.allSatisfy { $0 == .failure(.notFound) }, "W1…W3 are ended by K1's drop (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.k]) == [16], "K gets O's bytes: \(outcome)")
        let starts = [await Self.starts(w, c), await Self.starts(x, c)]
        #expect(starts == [0, 0], "neither W nor X is requested: \(starts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T11: a verdict deferred before the last layer's apply pins nothing at the next

    /// rr21-T11 (rr21-B20's `deferredAfter > previous.applies`): zz-y (V's) is Y's content, which downloads; K0 maps
    /// zz-a1…zz-a3 to X's content (no job), O's commit owes their re-routes, Y's 404 arrives, its verdict deferred behind
    /// the batch, K1 maps the ids to Y's content and K2 to W's. Visited first, Y's 404 was given before K1, so K1's visit
    /// moved W1…W3 to a fresh job of Y's content, and K2's moved them on to W's. Y's verdict met K1's apply first: K2's
    /// layer does not pin the ids to Y, and W1…W3 get W's bytes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a verdict deferred before an apply that moved the owed ids onto its job does not pin them at the next apply (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func verdictBeforeTheMoveOntoItsJobPinsNothingAtTheNextApply(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_471
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let yBytes = EngineFixture.bytes(seed + 6, count: 22)
        let wBytes = EngineFixture.bytes(seed + 7, count: 20)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [y])
        let engine = c.engine
        let yT = y.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onY = Self.movedOnto(yBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        await c.s.harness.source.script(onX[0].transferID, [.hold])
        await c.s.harness.source.script(yT, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await c.s.harness.source.script(onW[0].transferID, [.stage(wBytes)])
        let v = await Self.downloadingWaiter(y, c)
        let held = try await Self.oweThroughK0(c, k0: [y] + onX, visit: visit)
        await c.s.harness.source.release(yT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.verdictsAfterFollow[yT] != nil }
        try await Self.applyBehindBatch(c.manifest([y] + onY, round: 2), tag: "k1-onto-verdict-\(seed)", c)
        try await Self.applyBehindBatch(c.manifest([y] + onW, round: 3), tag: "k2-off-verdict-\(seed)", c)
        #expect(await Self.pins(yT, c) == [true, false], "setup: K1's layer holds Y's waiting verdict, K2's does not")
        let outcome = await Self.finishOwed(c, held: held, others: [v])
        #expect(outcome.others == [.failure(.notFound)], "V gets Y's 404: \(outcome)")
        #expect(Self.sizes([outcome.k]) == [16] && Self.sizes(outcome.w) == [20, 20, 20], "K gets O's bytes, W1…W3 W's (visit-first): \(outcome)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }
}
