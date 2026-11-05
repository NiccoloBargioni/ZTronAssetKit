import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The invariants of the owed re-routes (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md` R17,
/// the branch rr21-B31): each new clause of `followBarrierViolations`, broken alone through the test seam
/// (`violations(after:)`) on an engine whose commit owes one batch, reports its exact message.
extension EngineFollowBarrierTests {
    /// O's commit owes the re-routes of zz-a1…zz-a3 (a user waiter and the group's member each) to W's content (20 bytes,
    /// held), visited first; X (zz-x, 24 bytes, a user waiter V) downloads, held, beside the batch. Each edit breaks one
    /// clause, and the violations are exactly that clause's, with the older clauses an edit also breaks.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the invariants report an owed re-route out of place, owed twice, uncounted or without its copies (F-28, C2)", .timeLimit(.minutes(3)))
    func invariantsReportOwedReroutesOutOfPlace() async throws {
        let seed: UInt64 = 2_027_301
        let xBytes = EngineFixture.bytes(seed + 5, count: 24)
        let xEntry = EngineHarness.onDemand("zz-x", xBytes)
        let x = xEntry.transferID
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [xEntry], wanters: .waitersAndGroup)
        let engine = c.engine
        let o = c.transfer
        let group = try #require(c.group)
        let wBytes = EngineFixture.bytes(seed + 9, count: 20)
        let onW = c.ids.map { EngineHarness.onDemand($0.rawValue, wBytes) }
        let w = onW[0].transferID
        await c.s.harness.source.script(w, [.hold, .stage(wBytes)])
        await c.s.harness.source.script(x, [.hold, .stage(xBytes)])
        let xID = xEntry.identifier
        let v = Task { await engine.awaitAsset(xID, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x]?.state == .downloading }
        }
        let (units, releaser) = try await Self.holdPublications(of: [o], c.s, bulk: c.bulk)
        try await Self.applyHeld(c.manifest(onW + [xEntry], round: 1), tag: "v4-invariants-\(seed)", c.s, visit: .followVisitedFirst)
        let batches = await Self.commitOwing(c, unit: units[0])
        try #require(batches.count == 1 && batches[0].items.count == 6, "setup: the commit owes six re-routes in one batch: \(batches.map(\.items.count))")
        let clean = await engine.invariantViolations()
        try #require(clean.isEmpty, "setup: \(clean.prefix(3))")
        let a1 = c.ids[0]
        let waiterToken = try #require(await engine.readForTests { e in e.state.waiters.first { $0.value.asset == a1 && !$0.value.fromStore }?.key })
        let vToken = try #require(await engine.readForTests { e in e.state.waiters.first { $0.value.asset == xID }?.key })
        let t = waiterToken.rawValue
        let g = group.rawValue

        let waiterAway = await engine.violations { $0.waiters[waiterToken]?.transfer = w }
        #expect(waiterAway == ["waiter \(t) has no interest in \(w)", "waiter \(t) owed a re-route of \(a1) from \(o) waits for \(a1) in \(w)"], "a waiter owed a re-route that waits elsewhere: \(waiterAway)")

        let groupAway = await engine.violations { $0.groups[group]?.pending[a1] = w }
        #expect(groupAway == ["group \(g) member \(a1) without an interest", "group \(g) member \(a1) owed a re-route from \(o) is pending at \(String(describing: Optional(w)))"], "a group's member owed a re-route that is pending elsewhere: \(groupAway)")

        let held = await engine.violations { state in
            let item = RerouteItem(asset: xID, token: vToken, lane: .userInitiated, kind: .waiter)
            state.eventsAfterFollow.append(.reroutes(RerouteBatch(from: x, copy: state.applied, serial: state.copySerial, items: MinHeap([item]), layers: [])))
            state.eventStamps.append(state.eventStamps[state.eventStamps.count - 1])
            state.reroutesWaiting += 1
        }
        #expect(held == ["interest \(vToken.rawValue) in \(xID) owed a re-route from \(x) is still held there"], "an owed re-route whose job still holds it: \(held)")

        let joining = await engine.violations { $0.joinsAfterFollow[waiterToken] = [a1: w] }
        #expect(joining == ["interest \(t) in \(a1) owed a re-route from \(o) also waits to join \(w)", "1 interests' joins wait for the follow, 0 with their event"], "an owed re-route whose interest also waits to join: \(joining)")

        let twice = await engine.violations { state in
            guard case .reroutes(var batch) = state.eventsAfterFollow[0], let first = batch.items.first else {
                return
            }
            batch.items = MinHeap(batch.items.elements + [first])
            state.eventsAfterFollow[0] = .reroutes(batch)
        }
        let first = try #require(batches[0].items.first)
        #expect(twice == ["interest \(first.token.rawValue) in \(first.asset) is owed 2 re-routes"], "a pair owed twice: \(twice)")

        let uncounted = await engine.violations { $0.reroutesWaiting += 1 }
        #expect(uncounted == ["2 re-route batches counted, 1 waiting"], "a batch counted that waits nowhere: \(uncounted)")

        let layered = await engine.violations { state in
            guard case .reroutes(var batch) = state.eventsAfterFollow[0] else {
                return
            }
            batch.layers.append(RerouteLayer(outgoing: batch.copy, applies: 0, ends: [:]))
            state.eventsAfterFollow[0] = .reroutes(batch)
        }
        #expect(layered == ["a re-route batch from \(o) holds 1 copies for 0 adopted since it was owed"], "a batch with a copy no apply adopted: \(layered)")

        releaser.cancel()
        await releaser.value
        await c.bulk.setHolding(false)
        let turns = await Self.releaseOwedTurns(c)
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await engine.releaseGroup(group)
        await Self.finishHeld(c.s)
        _ = await v.value
    }
}
