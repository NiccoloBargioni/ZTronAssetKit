import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The commit's re-routes, bounded (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md` R4, site 1): a
/// commit whose answers and re-routes together do not fit `inboundIDsNow` owes every re-route as one batch, which the
/// drain makes at its place in the queue, at most a drain turn's ids a turn and each id with all its tokens; one that
/// fits makes them in its own turn. Each test runs in both orders (`LaneDropVisit`) at `followIDsPerTurn = 4`
/// (`inboundIDsNow` 2, a drain turn's ids 4), with the drain's and the follow's turns held and released one at a time
/// and the invariants read after each, and expects the answers a commit that re-routes at once gives.
extension EngineFollowBarrierTests {
    /// Who wants the ids of `commitReroute`'s shape.
    enum CommitWanters: Sendable {
        /// A user waiter per id.
        case waiters
        /// A user waiter and one prefetch group's member per id.
        case waitersAndGroup
    }

    /// What `commitReroute` saw.
    struct CommitRerouteRun: CustomStringConvertible {
        /// Per commit, in order: the ids its own turn re-routed, at once or as joins waiting for the follow.
        var commitMade: [Int] = []
        /// Per commit: the distinct ids every batch owed after its turn.
        var owedAfterCommit: [Int] = []
        /// Per commit: the batches that waited after its turn.
        var batchesAfterCommit: [Int] = []
        /// Per commit: the events that waited after its turn.
        var eventsAfterCommit: [Int] = []
        /// The held turns released after the commits: their kind, whether the follow was owed before, and the distinct
        /// ids they re-routed.
        var turns: [(kind: HeldTurn, owedBefore: Bool, made: Int)] = []
        /// Whether a turn re-routed only some of an id's interests.
        var split = false
        /// The invariant violations read after each commit and after each held turn.
        var violations: [String] = []
        /// The bytes each id's waiter got, in id order (each content's kept ids, then its moved ones); -1 for a failure.
        var served: [Int64] = []
        /// Whether the prefetch group waited for no member at the end (`waitersAndGroup`).
        var groupDone = true
        /// W's job's interests once the follow and the drain are over, each its kind and lane, sorted: the interests the
        /// re-routes made there, the same whether they were made at once or owed.
        var onW: [String] = []

        /// The ids re-routed by the turns that re-routed any, in order.
        var made: [Int] {
            self.turns.map(\.made).filter { $0 > 0 }
        }

        var description: String {
            "commits made \(self.commitMade), owed \(self.owedAfterCommit), batches \(self.batchesAfterCommit), events \(self.eventsAfterCommit); turns \(self.turns.map { "\($0.kind.rawValue)\($0.owedBefore ? "(owed)" : ""):\($0.made)" }); split \(self.split); served \(self.served); group done \(self.groupDone); on W \(self.onW); violations \(self.violations.prefix(3))"
        }
    }

    /// The re-routes the engine made or owes for `members`, which move to `w`'s content: the ids `w`'s job holds or a
    /// join waits to bring there, the distinct ids every waiting batch owes, the batches, the events, whether some id
    /// owes fewer than `tokens` of its interests, and the invariant violations.
    static func rerouteShape(_ e: isolated SyncEngine, w: TransferID, members: Set<AssetID>, tokens: Int) -> (made: Int, owed: Int, batches: Int, events: Int, split: Bool, violations: [String]) {
        var made = e.state.jobs[w]?.assets.intersection(members) ?? []
        for joins in e.state.joinsAfterFollow.values {
            for (asset, transfer) in joins where transfer == w && members.contains(asset) {
                made.insert(asset)
            }
        }
        var owed: [AssetID: Int] = [:]
        var batches = 0
        for event in e.state.eventsAfterFollow {
            if case .reroutes(let batch) = event {
                batches += 1
                for item in batch.items.elements {
                    owed[item.asset, default: 0] += 1
                }
            }
        }
        let split = owed.values.contains { $0 != tokens }
        return (made.count, owed.count, batches, e.state.eventsAfterFollow.count, split, e.invariantViolations())
    }

    /// Holds the publications of `transfers` at their first store units, in order: releases each one's held download and
    /// waits for its unit; returns the units and a task that lets every other store unit run until it is cancelled.
    @available(macOS 15.0, iOS 18.0, *)
    static func holdPublications(of transfers: [TransferID], _ s: FollowBarrier.Setup, bulk: SteppedBlockingExecutor) async throws -> (units: [Int], releaser: Task<Void, Never>) {
        let engine = s.engine
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await bulk.setHolding(true)
        var units: [Int] = []
        for transfer in transfers {
            await s.harness.source.release(transfer, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[transfer]?.state == .verifying }
            try await bulk.requireHeldUnits(atLeast: units.count + 1)
            let held = await bulk.heldUnits
            let unit = try #require(held.first { !units.contains($0) }, "setup: \(transfer)'s publication is held at the store")
            units.append(unit)
        }
        let kept = units
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: kept.count + 1)
                for other in await bulk.heldUnits where !kept.contains(other) {
                    await bulk.release(other)
                }
            }
        }
        return (units, releaser)
    }

    /// `contents` contents X<c> (16 bytes each), each held by `kept` ids that keep it and `moved` ids that v4 maps to W's
    /// content (20 bytes, one job), each id with a user waiter (and, with `waitersAndGroup`, one prefetch group's member).
    /// Every X downloads, then publishes, held at its first store unit; v4 is applied (visited first, its follow ends;
    /// swept first, it stays owed, its turns held), and the drain's turns are held. Then each X's publication commits,
    /// in order: the store binds its kept ids, and the commit re-routes the moved ones to W. Then the follow's and the
    /// drain's held turns are released one at a time until nothing waits, and W's download runs.
    @available(macOS 15.0, iOS 18.0, *)
    func commitReroute(_ visit: LaneDropVisit, seed: UInt64, contents: Int = 1, kept: Int, moved: Int, idsPerTurn: Int, wanters: CommitWanters = .waiters) async throws -> CommitRerouteRun {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = idsPerTurn }
        let wBytes = EngineFixture.bytes(seed + 9, count: 20)
        let xBytes = (0..<contents).map { EngineFixture.bytes(seed + 3 + UInt64($0), count: 16) }
        let layout = (0..<contents).map { content in
            (
                keepers: (0..<kept).map { EngineHarness.onDemand(String(format: "zz-c%d-k%02d", content, $0), xBytes[content]) },
                movers: (0..<moved).map { EngineHarness.onDemand(String(format: "zz-c%d-m%02d", content, $0), xBytes[content]) }
            )
        }
        let all = layout.flatMap { $0.keepers + $0.movers }
        let movedIDs = Set(layout.flatMap { $0.movers.map(\.identifier) })
        let xs = layout.map { ($0.keepers + $0.movers)[0].transferID }
        let v4Entries = all.map { movedIDs.contains($0.identifier) ? EngineHarness.onDemand($0.identifier.rawValue, wBytes) : $0 }
        let w = EngineHarness.onDemand("zz-w", wBytes).transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + all + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        for (content, x) in xs.enumerated() {
            await s.harness.source.script(x, [.hold, .stage(xBytes[content])])
        }
        await s.harness.source.script(w, [.hold, .stage(wBytes)])
        let waiters = all.map { entry in
            let id = entry.identifier
            return Task { await engine.awaitAsset(id, lane: .userInitiated) }
        }
        var group: InterestToken?
        if wanters == .waitersAndGroup {
            group = try await engine.registerGroup(all.map(\.identifier), lane: .prefetch).get()
        }
        let interests = kept + moved + (group == nil ? 0 : 1)
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in xs.allSatisfy { e.state.jobs[$0]?.state == .downloading && e.state.jobs[$0]?.interests.count == interests } }
        }
        let (units, releaser) = try await Self.holdPublications(of: xs, s, bulk: bulk)
        let v4 = [s.q] + FollowBarrier.fillers(seed + 200) + v4Entries + Self.laterFillers(seed + 6_000)
        try await Self.applyHeld(v4, tag: "v4-commit-reroute-\(seed)", s, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        let tokens = group == nil ? 1 : 2
        var run = CommitRerouteRun()
        var madeBefore = 0
        for (index, x) in xs.enumerated() {
            await bulk.release(units[index])
            await engine.awaitCondition { $0.state.jobs[x] == nil }
            let shape = await engine.readForTests { e in Self.rerouteShape(e, w: w, members: movedIDs, tokens: tokens) }
            run.commitMade.append(shape.made - madeBefore)
            madeBefore = shape.made
            run.owedAfterCommit.append(shape.owed)
            run.batchesAfterCommit.append(shape.batches)
            run.eventsAfterCommit.append(shape.events)
            run.violations += shape.violations
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await bulk.releaseAll()
        while await engine.readForTests({ e in e.followOwed || !e.state.eventsAfterFollow.isEmpty }) {
            let before = await engine.readForTests { e in (e.followOwed, Self.rerouteShape(e, w: w, members: movedIDs, tokens: tokens).owed) }
            let kind = await Self.runOneHeldTurn(engine)
            let after = await engine.readForTests { e in Self.rerouteShape(e, w: w, members: movedIDs, tokens: tokens) }
            run.turns.append((kind, before.0, before.1 - after.owed))
            run.split = run.split || after.split
            run.violations += after.violations
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        let complete = await engine.readForTests { e in movedIDs.isEmpty || (e.state.jobs[w]?.assets.isSuperset(of: movedIDs) ?? false) }
        run.onW = await engine.readForTests { e in (e.state.jobs[w]?.interests.values.map { "\($0.kind)/\($0.lane)/\($0.assets.count)" } ?? []).sorted() }
        if complete, !movedIDs.isEmpty {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[w]?.state == .downloading }
            }
            await s.harness.source.release(w, with: .progress(received: 0, expected: nil))
        }
        if complete {
            for waiter in waiters {
                let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
                run.served.append((try? result.get())?.byteSize ?? -1)
            }
            if let group {
                run.groupDone = await engine.readForTests { $0.state.groups[group]?.pending.isEmpty ?? true }
            }
            await Self.finishHeld(s)
        } else {
            // A re-route was lost: shut down first, so every waiter is answered.
            await Self.finishHeld(s)
            for waiter in waiters {
                let result = await EngineHarness.value(of: waiter)
                run.served.append((try? result.get())?.byteSize ?? -1)
            }
        }
        return run
    }

    /// The bytes `commitReroute` expects each id's waiter to get: X's for a kept id, W's for a moved one.
    static func commitRerouteServed(contents: Int = 1, kept: Int, moved: Int) -> [Int64] {
        Array((0..<contents).map { _ in Array(repeating: Int64(16), count: kept) + Array(repeating: Int64(20), count: moved) }.joined())
    }

    // MARK: rr21-T1: the drain makes an owed commit's re-routes at most a drain turn's ids a turn

    /// One kept id and ten moved: the commit's answers and re-routes (1 + 10) do not fit `inboundIDsNow` (2), so its own
    /// turn re-routes nothing and owes one batch of the ten ids, which the drain makes 4, 4 and 2 a turn, each turn at
    /// least one; the waiters get the answers of the same commit at `followIDsPerTurn = 512`, which re-routes at once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit's re-routes that do not fit its turn are owed as one batch and made at most a drain turn's ids a turn (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitOwesItsReroutesAndTheDrainMakesThemBounded(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_027_101, kept: 1, moved: 10, idsPerTurn: 4)
        #expect(run.commitMade == [0] && run.owedAfterCommit == [10] && run.batchesAfterCommit == [1], "the commit's turn re-routes nothing and owes the ten ids as one batch: \(run)")
        #expect(run.made == [4, 4, 2], "the drain makes the batch 4, 4 and 2 ids a turn: \(run)")
        #expect(run.turns.allSatisfy { $0.made <= 4 } && run.turns.filter { !$0.owedBefore }.allSatisfy { $0.made >= 1 }, "no turn makes more than a drain turn's ids, and each drain turn makes one at least: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        let atOnce = try await self.commitReroute(visit, seed: 2_027_101, kept: 1, moved: 10, idsPerTurn: 512)
        #expect(atOnce.commitMade == [10] && atOnce.batchesAfterCommit == [0], "setup: at 512 the commit re-routes at once: \(atOnce)")
        #expect(run.served == atOnce.served && run.served == Self.commitRerouteServed(kept: 1, moved: 10), "the answers equal the at-once commit's: \(run.served) \(atOnce.served)")
    }

    /// One kept id and eight moved: the drain makes the batch 4 and 4 ids a turn, so its second turn spends the drain
    /// turn's ids exactly as the batch ends: the replay owes no rest then (rr21-B14), the batch is counted down in that
    /// turn, and no third turn runs.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed batch whose last ids spend a drain turn's exactly ends in that turn (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedBatchEndingAtTheTurnsLastIDEndsInThatTurn(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_027_161, kept: 1, moved: 8, idsPerTurn: 4)
        #expect(run.commitMade == [0] && run.owedAfterCommit == [8] && run.batchesAfterCommit == [1], "the commit owes the eight ids as one batch: \(run)")
        #expect(run.made == [4, 4] && run.turns.last?.made == 4, "the drain makes the batch in two whole turns, the last held turn its second: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(kept: 1, moved: 8), "every waiter gets its content's bytes: \(run.served)")
    }

    /// Two contents, each with one kept id and three moved: each commit's 1 + 3 do not fit, so each owes a batch of three
    /// ids while the drain is held, and the drain makes each batch in a turn of its own (a batch ends its drain turn).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: two commits that owe their re-routes while the drain is held each owe a batch, made a drain turn each (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func twoCommitsOweABatchEach(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_027_111, contents: 2, kept: 1, moved: 3, idsPerTurn: 4)
        #expect(run.commitMade == [0, 0] && run.owedAfterCommit == [3, 6] && run.batchesAfterCommit == [1, 2], "each commit's turn re-routes nothing and owes its three ids: \(run)")
        #expect(run.made == [3, 3] && run.turns.allSatisfy { $0.made <= 4 }, "the drain makes each batch in a turn of its own: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(contents: 2, kept: 1, moved: 3), "every waiter gets its content's bytes: \(run.served)")
    }

    // MARK: rr21-T1-fit, rr21-T1-edge, rr21-T1-zero: the commit's fit charge

    /// One kept id and two moved: 1 + 2 is one more than `inboundIDsNow`, so the commit owes the two re-routes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit whose answers and re-routes are one more than its turn's ids owes its re-routes (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitOwesWhenItsAnswersAndReroutesPassTheBound(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_027_121, kept: 1, moved: 2, idsPerTurn: 4)
        #expect(run.commitMade == [0] && run.owedAfterCommit == [2] && run.batchesAfterCommit == [1], "the commit counts its answer with its re-routes and owes both: \(run)")
        #expect(run.made == [2], "the drain makes them in one turn: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(kept: 1, moved: 2), "\(run.served)")
    }

    /// One kept id and one moved: 1 + 1 is `inboundIDsNow`, so the commit re-routes the moved id in its own turn and
    /// owes nothing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit whose answers and re-routes fit its turn's ids re-routes at once and owes nothing (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitReroutesAtOnceWhenItFits(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_027_131, kept: 1, moved: 1, idsPerTurn: 4)
        #expect(run.commitMade == [1] && run.batchesAfterCommit == [0], "the commit re-routes its one moved id at once: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(kept: 1, moved: 1), "\(run.served)")
    }

    /// Three kept ids and none moved: nothing is re-routed, so the commit owes nothing though its answers (3) pass
    /// `inboundIDsNow`, and no event waits after its turn.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit with nothing to re-route owes no batch, whatever it answers (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitWithNothingToRerouteOwesNothing(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_027_141, kept: 3, moved: 0, idsPerTurn: 4)
        #expect(run.batchesAfterCommit == [0] && run.eventsAfterCommit == [0], "no batch and no event wait after the commit: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(kept: 3, moved: 0), "\(run.served)")
    }

    // MARK: T-two-tokens: an id's tokens are re-routed in one turn

    /// One kept id and six moved, each with a user waiter and a prefetch group's member: the commit owes twelve
    /// re-routes over six ids, and the drain makes 4 ids then 2 a turn, both tokens of an id in the same turn.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the drain re-routes an owed id with all its tokens in one turn, counting ids, not interests (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func drainReroutesAnOwedIDWithAllItsTokensInOneTurn(_ visit: LaneDropVisit) async throws {
        let run = try await self.commitReroute(visit, seed: 2_027_151, kept: 1, moved: 6, idsPerTurn: 4, wanters: .waitersAndGroup)
        #expect(run.commitMade == [0] && run.owedAfterCommit == [6] && run.batchesAfterCommit == [1], "the commit owes its six ids' twelve re-routes: \(run)")
        #expect(run.made == [4, 2] && !run.split, "the drain makes 4 ids then 2, each with both tokens: \(run)")
        #expect(run.violations.isEmpty, "\(run.violations.prefix(3))")
        #expect(run.served == Self.commitRerouteServed(kept: 1, moved: 6) && run.groupDone, "every waiter and the group get their contents: \(run)")
    }
}
