import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// `PROBE-RR21-HEAL-T21` (Stage 3 close-out cycle 21, ruling S3-R26 item 12's answer 6.1; `integrate-rr21.md`'s
/// residual risks): an owed re-route of a heal's system interest whose id the owing instant's copy dropped ends the
/// interest at the replay and forgets the asset's heal (T21), as a commit that re-routes at once forgets it at the
/// commit. A heal scheduled again before the site, between the owing instant and the replay, or after the replay is
/// compared with the commit that re-routes at once (`followIDsPerTurn` 512), in both orders.
extension EngineFollowBarrierTests {
    /// When the probe schedules zz-a1's second heal.
    enum HealPoint: String, Sendable, CaseIterable {
        /// Before O's commit, the site.
        case beforeSite
        /// After O's commit owes the re-routes, before their replay (at once: right after the commit).
        case between
        /// After the replay.
        case afterReplay
    }

    /// O's content holds zz-o (K's) and zz-a1…zz-a3 (W1…W3's), and a heal's system interest in zz-a1; K0 drops the three
    /// ids while O publishes, and O's commit, at `idsPerTurn`, owes their re-routes (4) or makes them at once (512):
    /// each ends its interest (T21), the heal's included, which forgets the heal. A second heal of zz-a1 is scheduled
    /// at `point`, due 600 s later; K1 lists the ids again, on W's content, after the replay. Returns whether the heal
    /// fetched zz-a1 at its time, with W1…W3's answers.
    @available(macOS 15.0, iOS 18.0, *)
    func healAfterT21(_ visit: LaneDropVisit, idsPerTurn: Int, at point: HealPoint, seed: UInt64) async throws -> (healed: Bool, w: [Result<AssetLocation, AssetError>]) {
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3)
        let engine = c.engine
        let o = c.transfer
        let a1 = c.ids[0]
        await engine.readForTests { $0.state.followIDsPerTurn = idsPerTurn }
        await engine.readForTests { $0.scheduleHeal(a1, at: $0.environment.time.monotonicNow()) }
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[o]?.interests.values.contains { $0.kind == .system } == true }
        }
        let wBytes = EngineFixture.bytes(seed + 9, count: 20)
        let onW = Self.movedOnto(wBytes, c)
        let w = onW[0].transferID
        await c.s.harness.source.script(w, [.hold, .stage(wBytes)])
        let schedule: @Sendable (isolated SyncEngine) -> Void = { e in e.scheduleHeal(a1, at: e.environment.time.monotonicNow().adding(seconds: 600)) }
        let (units, releaser) = try await Self.holdPublications(of: [o], c.s, bulk: c.bulk)
        var held = HeldUnits(bulk: c.bulk, kept: units, releaser: releaser)
        if point == .beforeSite {
            await engine.readForTests(schedule)
        }
        try await Self.applyHeld(c.manifest([], round: 1), tag: "k0-heal-\(seed)", c.s, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        await engine.awaitCondition { $0.state.jobs[o] == nil }
        let batches = await engine.readForTests { e in Self.owedBatches(e).map(\.items.count) }
        try #require(batches == (idsPerTurn == 512 ? [] : [4]), "setup: O's commit owes the four re-routes at 4, none at 512: \(batches)")
        if point == .between {
            await engine.readForTests(schedule)
        }
        let turns = await Self.releaseOwedTurns(c)
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        if point == .afterReplay {
            await engine.readForTests(schedule)
        }
        // K1 has no job to visit (O's was the last), so its follow ends in its own turn in either order.
        let k1 = try ValidatedManifest(entries: c.manifest(onW, round: 2), digest: ContentHash.sha256(of: Data("k1-heal-\(seed)".utf8)))
        let applied = await engine.applyAndFollow(k1, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "setup: K1 is applied: \(applied)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.heap.deadline(for: .heal(a1)) == nil }
        }
        let healed = await engine.readForTests { e in e.state.jobs[w]?.interests.values.contains { $0.kind == .system } == true }
        if healed {
            await c.s.harness.source.release(w, with: .progress(received: 0, expected: nil))
        }
        await held.stop()
        let answers = await Self.owedAnswers(c)
        #expect(Self.sizes([answers.k]) == [16], "K gets O's bytes: \(answers.k)")
        await Self.finishHeld(c.s)
        return (healed, answers.w)
    }

    /// `PROBE-RR21-HEAL-T21`: a heal scheduled before the site is forgotten by the T21 re-route, owed or made at once; one
    /// scheduled after the replay fetches zz-a1 in both. One scheduled between the owing instant and the replay lands
    /// after the at-once commit's answer and before the owed replay's: the replay forgets it, the at-once engine keeps
    /// it. That is the timing class of ruling S3-R26 item 12's answer 6.1 (the event between the two engines' answers),
    /// recorded with this probe; before both answers or after both, the outcomes are equal.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a heal of an id whose owed re-route ends its interest is forgotten as the commit's own re-route forgets it, unless it lands between the two answers (F-28, T21)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, HealPoint.allCases)
    func healOfAnOwedT21SystemInterest(_ visit: LaneDropVisit, _ point: HealPoint) async throws {
        let seeds: [HealPoint: UInt64] = [.beforeSite: 2_027_461, .between: 2_027_471, .afterReplay: 2_027_481]
        let seed = try #require(seeds[point])
        let owed = try await self.healAfterT21(visit, idsPerTurn: Self.owedIDsPerTurn, at: point, seed: seed)
        let atOnce = try await self.healAfterT21(visit, idsPerTurn: 512, at: point, seed: seed)
        #expect(owed.w.allSatisfy { $0 == .failure(.notFound) } && atOnce.w.allSatisfy { $0 == .failure(.notFound) }, "W1…W3 get .notFound, owed or at once (T21): \(owed.w), \(atOnce.w)")
        switch point {
        case .beforeSite:
            #expect(!owed.healed && !atOnce.healed, "the T21 re-route forgets a heal scheduled before the site, owed or at once: owed \(owed.healed), at once \(atOnce.healed)")
        case .between:
            #expect(!owed.healed && atOnce.healed, "between the two answers: the owed replay forgets the heal, the at-once engine had forgotten the first one only (timing, answer 6.1): owed \(owed.healed), at once \(atOnce.healed)")
        case .afterReplay:
            #expect(owed.healed && atOnce.healed, "a heal scheduled after the replay fetches zz-a1, owed or at once: owed \(owed.healed), at once \(atOnce.healed)")
        }
    }
}
