import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// What an owed batch's replay reads that the site's own idle pass could drop (Stage 3 close-out cycle 21, ruling S3-R26
/// item 12's answer 6.5; `integrate-rr21.md`'s RR21-PRESENT-PRUNE and T-WATCH): the bindings of the owed pairs' ids
/// (`pruneBoundContent`'s `eventsAfterFollow` guard) and the conditions the watcher keeps (`hasWork`'s
/// `eventsAfterFollow` disjunct). O's commit, `stageOwedCommit`'s, removes the last job and owes the re-routes; each
/// test expects the visit-first answers in both orders.
extension EngineFollowBarrierTests {
    /// What keeps a fresh job of the present content from serving its waiters: a refused job, had the replay made one,
    /// would answer them otherwise.
    enum PresentGate: String, Sendable, CaseIterable {
        /// zz-e's 403 opened the breaker before K0 (`authDistinctAssets` 1).
        case breakerOpen
        /// The path went offline while O published.
        case offline
        /// 1,000 bytes of room above the reserve, for a content of 4,000.
        case insufficientSpace
    }

    // MARK: RR21-PRESENT-PRUNE: the owed pairs' bindings outlive the site's idle pass

    /// RR21-PRESENT-PRUNE at site 1 (rr21-B24): zz-d's content D (4,000 bytes) is present; K0 maps zz-a1…zz-a6 onto it,
    /// so the apply binds them to D's blob (`ApplyReport.reused`, `EngineRuns.swift`'s `applied`), and O's commit, which
    /// removes the last job, owes W1…W6's re-routes. Visited first, the commit re-routed them at once to D's content,
    /// present, and the store served them, `gate` notwithstanding: no job of D's content. Owed, the bindings must outlive
    /// the commit's own idle pass (`reconcileIdle`), which drops every binding no job holds once nothing waits for the
    /// follow; the replay answers the ids from the store, each drain turn at most its 4 ids.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: owed re-routes onto a present content are answered from the store at the replay, as the commit answered them at once (F-28, RR21-PRESENT-PRUNE)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PresentGate.allCases)
    func owedReroutesOntoAPresentContentAreServedFromTheStore(_ visit: LaneDropVisit, _ gate: PresentGate) async throws {
        let seeds: [PresentGate: UInt64] = [.breakerOpen: 2_027_901, .offline: 2_027_911, .insufficientSpace: 2_027_921]
        let seed = try #require(seeds[gate])
        let moved = 6
        let dBytes = EngineFixture.bytes(seed + 5, count: 4_000)
        let eBytes = EngineFixture.bytes(seed + 6, count: 16)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        let e = EngineHarness.onDemand("zz-e", eBytes)
        let tuning = SyncTuning(breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let c = try await Self.stageOwedCommit(seed: seed, moved: moved, extra: [d, e], tuning: tuning)
        let engine = c.engine
        let o = c.transfer
        let dT = d.transferID
        await c.s.harness.source.script(dT, [.stage(dBytes)])
        let dID = d.identifier
        let present = await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await engine.awaitAsset(dID, lane: .userInitiated) }
        try #require((try? present.get())?.byteSize == 4_000, "setup: zz-d is present: \(present)")
        await engine.awaitCondition { $0.state.jobs[dT] == nil }
        let onD = Self.movedOnto(dBytes, c)
        try #require(onD.allSatisfy { $0.transferID == dT }, "setup: K0 maps the moved ids onto D's content")
        if gate == .breakerOpen {
            let origin = c.s.harness.source.originID
            await c.s.harness.source.script(e.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
            let eID = e.identifier
            let eResult = await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await engine.awaitAsset(eID, lane: .userInitiated) }
            #expect((try? eResult.get()) == nil, "setup: zz-e's 403 fails it: \(eResult)")
            let opened = await engine.readForTests { e in
                if case .open? = e.state.breakers[origin]?.state {
                    return true
                }
                return false
            }
            try #require(opened, "setup: zz-e's 403 opened the breaker")
        }
        let (units, releaser) = try await Self.holdPublications(of: [o], c.s, bulk: c.bulk)
        var held = HeldUnits(bulk: c.bulk, kept: units, releaser: releaser)
        if gate == .offline {
            await c.s.harness.conditions.send(EngineRegressionCycle10Tests.offline)
            await engine.awaitCondition { $0.state.conditions == EngineRegressionCycle10Tests.offline }
        }
        try await Self.applyHeld(c.manifest([d, e] + onD, round: 1), tag: "k0-present-\(seed)", c.s, visit: visit)
        let ids = onD.map(\.identifier)
        let bound = await engine.readForTests { e in ids.allSatisfy { e.state.boundContent[$0] == dT } }
        try #require(bound, "setup: K0 binds the moved ids to D's content, whose blob the store holds")
        if gate == .insufficientSpace {
            try await Self.leaveRoom(1_000, harness: c.s.harness, fileSystem: c.s.fileSystem)
        }
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        await engine.awaitCondition { $0.state.jobs[o] == nil }
        let owing = await engine.readForTests { e in
            (items: Self.owedBatches(e).map(\.items.count), jobs: e.state.jobs.count, kept: ids.allSatisfy { e.state.boundContent[$0] == dT }, created: e.state.jobsCreated)
        }
        try #require(owing.items == [moved] && owing.jobs == 0, "setup: O's commit removes the last job and owes the \(moved) re-routes as one batch: \(owing)")
        #expect(owing.kept, "the owed pairs' bindings outlive the commit's idle pass")
        let tokens = await engine.readForTests { e in Set(Self.owedBatches(e).flatMap { $0.items.elements.map(\.token) }) }
        var made: [Int] = []
        var servedFromStore = true
        var dJob = false
        var violations: [String] = []
        var left = tokens
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            _ = await Self.runOneHeldTurn(engine)
            let now = await engine.readForTests { e in
                (owed: Set(Self.owedBatches(e).flatMap { $0.items.elements.map(\.token) }), waiters: e.state.waiters.filter { tokens.contains($0.key) }.mapValues(\.fromStore), dJob: e.state.jobs[dT] != nil)
            }
            let turn = left.subtracting(now.owed)
            if !turn.isEmpty {
                made.append(turn.count)
            }
            servedFromStore = servedFromStore && turn.allSatisfy { now.waiters[$0] ?? true }
            dJob = dJob || now.dJob
            left = now.owed
            violations += await engine.invariantViolations()
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        let created = await engine.readForTests { $0.state.jobsCreated }
        try #require(created == owing.created && !dJob, "no job of D's content: \(owing.created) -> \(created) jobs created, D's job seen \(dJob)")
        #expect(servedFromStore && made.allSatisfy({ $0 <= Self.owedIDsPerTurn }) && made.reduce(0, +) == moved, "each drain turn answers at most its 4 ids, each from the store: \(made), from the store \(servedFromStore)")
        await held.stop()
        let answers = await Self.owedAnswers(c)
        #expect(Self.sizes([answers.k]) == [16] && Self.sizes(answers.w) == Array(repeating: 4_000, count: moved), "K gets O's bytes, W1…W6 D's from the store (visit-first): K \(answers.k), W \(Self.sizes(answers.w))")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: T-WATCH: the watcher stays while a batch waits

    /// T-WATCH (rr21-B25): user requests follow the prefetch lane's network rules (`userInitiatedOverridesPolicy` false,
    /// `prefetchOnExpensive` false); the path turns expensive while O publishes, and O's commit, which removes the last
    /// job, owes W1…W3's re-routes to X's content. Visited first, the commit re-routed them at once: X was parked on the
    /// policy with the conditions known, and nothing was requested until the path was cheap again. Owed, the engine has
    /// work while the batch waits (`hasWork`): the watcher keeps the conditions through the site's idle pass, so the
    /// replay's X parks on the policy too, where an unknown path admits user work optimistically.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-14: the conditions watcher stays while owed re-routes wait, so their replay parks on the policy as the commit's re-routes did (F-28, T-WATCH)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func watcherKeepsTheConditionsWhileReroutesAreOwed(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_931
        let strict = NetworkPolicy(prefetchOnExpensive: false, userInitiatedOverridesPolicy: false)
        let expensive = DeviceConditions(network: NetworkConditions(satisfied: true, expensive: true, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal))
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, network: strict)
        let engine = c.engine
        let o = c.transfer
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let onX = Self.movedOnto(xBytes, c)
        let x = onX[0].transferID
        await c.s.harness.source.script(x, [.stage(xBytes)])
        let (units, releaser) = try await Self.holdPublications(of: [o], c.s, bulk: c.bulk)
        var held = HeldUnits(bulk: c.bulk, kept: units, releaser: releaser)
        await c.s.harness.conditions.send(expensive)
        await engine.awaitCondition { $0.state.conditions == expensive }
        try await Self.applyHeld(c.manifest(onX, round: 1), tag: "k0-watch-\(seed)", c.s, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        await engine.awaitCondition { $0.state.jobs[o] == nil }
        let site = await engine.readForTests { e in (items: Self.owedBatches(e).map(\.items.count), jobs: e.state.jobs.count, watching: e.state.watcher != nil, conditions: e.state.conditions) }
        try #require(site.items == [3] && site.jobs == 0, "setup: O's commit removes the last job and owes the three re-routes: \(site.items), \(site.jobs) jobs")
        #expect(site.watching && site.conditions == expensive, "the watcher keeps the conditions after the site's turn: watching \(site.watching), \(String(describing: site.conditions))")
        var violations: [String] = []
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            _ = await Self.runOneHeldTurn(engine)
            violations += await engine.invariantViolations()
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        let parked = await engine.readForTests { e in (state: e.state.jobs[x]?.state, interests: e.state.jobs[x]?.interests.count) }
        let xStarts = await Self.starts(x, c)
        #expect(parked.state == .blocked(.policy(.expensiveNetwork)) && parked.interests == 3, "X is parked on the policy with W1…W3 unanswered on it (visit-first): \(parked)")
        #expect(xStarts == 0, "no transport start on the expensive path: \(xStarts)")
        await c.s.harness.conditions.send(.unrestricted)
        await held.stop()
        let answers = await Self.owedAnswers(c)
        #expect(Self.sizes([answers.k]) == [16] && Self.sizes(answers.w) == [18, 18, 18], "K gets O's bytes, W1…W3 X's once the path is cheap: K \(answers.k), W \(Self.sizes(answers.w))")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await Self.finishHeld(c.s)
    }
}
