import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// An id the engine's copy does not list, held by a job whose exit verdict defers once the follow has ended (Stage 3
/// close-out cycle 17; the cycle-16 requirements verifier's `deferralFollowOwedDrop`, `reqs-4`). A waiter for an id the
/// copy does not list is admitted from the manifest its fetch returns (point admission, sync.md §6.5) and joins the job
/// of that entry's content; while an `apply` is in flight the engine does not adopt the store's view
/// (`followStoreView`), so its copy lists the id only once that apply is followed. With no follow owed, no visit moved
/// the id off the job before the verdict: `recordDeferredVerdict` records no moved id (`AttemptEnd.movedBefore`), and
/// the drain gives the verdict to every interest of the job, as a visit-first engine gave it at the attempt's end.
/// Counted as moved, the id was taken off the job before the verdict and re-routed after it to the copy, which does not
/// list it: `notFound` for an id a newer manifest lists (R-CAR-2). The test runs in both orders (`LaneDropVisit`) with
/// the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// X (100 kB, zz-x, a user waiter) downloads. v3 changes only the fillers, so behind the barrier its follow is
    /// owed. v4, which adds zz-u at X's content, is applied by the store and its follow-up held
    /// (`holdNextApplyFollow`). A user waiter U for zz-u, which the copy (v3) does not list, is admitted from the
    /// fetched v4 and its join waits; two conditions elements follow it. The follow ends: the drain's first batch joins
    /// zz-u to X and ends at the first element, and its second turn (held) still owes the second. X's attempt then
    /// fails with a 503 (transient), so its verdict waits for that turn. Visited first, the verdict was given at the
    /// 503's arrival: X backed off with both waiters, and its second attempt served them.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: an id admitted from a newer manifest stays on its job through a verdict that waits for the drain (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierLeavesAnAdmittedUnlistedIDToTheVerdictThatWaits(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_618_102
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let xBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let u = EngineHarness.onDemand("zz-u", xBytes)
        try #require(x.transferID == u.transferID, "setup: zz-x and zz-u share X")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(x.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 503), retryAfter: nil)), .stage(xBytes)])
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[x.transferID]?.state == .downloading }
        }
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + [x]
        try await Self.applyHeld(v3, tag: "v3-unlisted-\(seed)", s, visit: visit)
        // The store applies v4, which adds zz-u at X's content; the engine's side of that apply waits.
        let v4 = v3 + [u]
        let manifest = try ValidatedManifest(entries: v4, digest: ContentHash.sha256(of: Data("v4-unlisted-\(seed)".utf8)))
        await engine.holdNextApplyFollow()
        let applying = Task { await engine.applyAndFollow(manifest, etag: nil, eviction: nil) }
        await engine.awaitCondition { $0.applyFollowHeld && $0.state.appliesInFlight == 1 }
        // U's fetch returns v4: zz-u is admitted from it, and the copy stays at v3 while that apply is in flight.
        await s.harness.serveManifest(v4, etag: "v4")
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, u) }
        } else {
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.assets.contains(u.identifier) == true }
        }
        let unlisted = await engine.readForTests { $0.state.applied.entry(for: u.identifier) == nil }
        try #require(unlisted, "setup: the copy (v3) does not list zz-u while v4's follow-up is held")
        if visit == .sweepFollowsFirst {
            // Two conditions elements (no change) wait behind U's join; the first ends the drain's first batch.
            await s.harness.conditions.send(.unrestricted)
            await s.harness.conditions.send(.unrestricted)
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.filter { event in
                    if case .conditions = event {
                        return true
                    }
                    return false
                }.count == 2
            }
            await engine.readForTests { e in
                e.holdDrainFollowUps()
                e.releaseFollowFollowUps()
            }
            await engine.awaitCondition { !$0.followOwed && $0.state.drainFollowUpWaiting }
            let between = await engine.readForTests { e in
                (
                    owed: e.followOwed, events: e.state.eventsAfterFollow.count, xHoldsU: e.state.jobs[x.transferID]?.assets.contains(u.identifier) == true,
                    listed: e.state.applied.entry(for: u.identifier) != nil, downloading: e.state.jobs[x.transferID]?.state == .downloading
                )
            }
            try #require(
                !between.owed && between.events == 1 && between.xHoldsU && !between.listed && between.downloading,
                "setup: no follow owed, one conditions element still waits, and X, downloading, holds zz-u, which the copy does not list: \(between)"
            )
        }
        // X's 503 (transient): behind the barrier its verdict waits for the drain's second turn.
        await s.harness.source.release(x.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[x.transferID] != nil }
            await engine.readForTests { $0.releaseDrainFollowUps() }
        }
        await engine.awaitCondition { e in
            !e.followBarrier && !e.state.drainFollowUpScheduled && e.state.verdictsAfterFollow[x.transferID] == nil && e.state.jobs[x.transferID]?.state != .downloading
        }
        let afterVerdict = await engine.readForTests { e in
            (xHoldsU: e.state.jobs[x.transferID]?.assets.contains(u.identifier) == true, uWaits: e.state.waiters.values.contains { $0.asset == u.identifier })
        }
        #expect(afterVerdict.xHoldsU && afterVerdict.uWaits, "X's retry keeps U, as the verdict given at the 503's arrival kept it: \(afterVerdict)")
        await engine.releaseApplyFollow()
        let applied = await applying.value
        #expect((try? applied.get()) != nil, "setup: v4 is applied: \(applied)")
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await uWaiter.value }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await xWaiter.value }
        #expect((try? uResult.get())?.byteSize == Int64(xBytes.count), "U, admitted from v4, is served by X's second attempt, as visited first: \(uResult)")
        #expect((try? xResult.get())?.byteSize == Int64(xBytes.count), "X's own waiter is served: \(xResult)")
        await Self.finishHeld(s)
    }
}

// MARK: d4 §3.8: an unlisted join waiting at a 429 (r8)

/// d4 §3.8, with its review's M1 (Stage 3 close-out cycle 23, ruling S3-R28 item 4; S3-R27 item 5): `followedLane`
/// skips a waiting join whose id the engine's copy does not map to the job only when the join has a chain
/// (`reaches(_:)`); an unlisted join, admitted from a newer manifest with no chain, reaches the job through its own entry.
extension EngineFollowBarrierTests {
    /// X (zz-x, 20 bytes) downloads for P, a prefetch waiter. v3 changes only the fillers, so behind the barrier its
    /// follow is owed; v4, which adds zz-u at X's content, is applied by the store and its follow-up held. U, a user
    /// request for zz-u, which the copy (v3) does not list, is admitted from the fetched v4: swept first its join waits
    /// unlisted, with no chain (an unlisted join waits only behind the barrier, so the state is swept first only:
    /// S3-R26 answer 1's citation); visited first it joins X at once. X then gets a 429 with Retry-After 60 s, above the
    /// user lane's 30 s cap, while U's join waits. Visited first, U was on X: X was user work, the 429 throttled nothing,
    /// X failed and P and U were answered `serverUnavailable`, X started once. Skipped, U's join would leave X prefetch
    /// work: the origin throttled at the arrival, and X's retry serving P.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an unlisted join waiting for the drain counts toward a 429's lane through its own entry (F-28, R-CAR-2, d4 §3.8)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func waitingUnlistedJoinCountsTowardA429sLane(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_028_321
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let xBytes = EngineFixture.bytes(seed + 3, count: 20)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let u = EngineHarness.onDemand("zz-u", xBytes)
        let xT = x.transferID
        try #require(xT == u.transferID, "setup: zz-x and zz-u share X")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(xT, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(xBytes), .stage(xBytes)])
        let pWaiter = Task { await engine.awaitAsset(x.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[xT]?.state == .downloading && $0.state.jobs[xT]?.interests.isEmpty == false }
        }
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + [x]
        try await Self.applyHeld(v3, tag: "v3-unlisted-429-\(seed)", s, visit: visit)
        let v4 = v3 + [u]
        let manifest = try ValidatedManifest(entries: v4, digest: ContentHash.sha256(of: Data("v4-unlisted-429-\(seed)".utf8)))
        await engine.holdNextApplyFollow()
        let applying = Task { await engine.applyAndFollow(manifest, etag: nil, eviction: nil) }
        await engine.awaitCondition { $0.applyFollowHeld && $0.state.appliesInFlight == 1 }
        await s.harness.serveManifest(v4, etag: "v4")
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, u) }
            let join = await engine.readForTests { e in
                e.state.eventsAfterFollow.compactMap { event -> (listed: Bool, chained: Bool)? in
                    if case .join(let join) = event, join.asset == u.identifier {
                        return (join.listed, join.chain != nil)
                    }
                    return nil
                }
            }
            try #require(join.count == 1 && !join[0].listed && !join[0].chained, "setup: U's join waits unlisted, with no chain: \(join)")
        } else {
            await engine.awaitCondition { $0.state.jobs[xT]?.assets.contains(u.identifier) == true }
        }
        let unlisted = await engine.readForTests { $0.state.applied.entry(for: u.identifier) == nil }
        try #require(unlisted, "setup: the copy (v3) does not list zz-u while v4's follow-up is held")
        // X's 429 while U's join waits (swept first), before the follow's turns are released.
        await s.harness.source.release(xT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[xT]?.state != .downloading }
        let throttled = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { e in !e.followBarrier && !e.state.drainFollowUpScheduled && e.state.verdictsAfterFollow[xT] == nil }
        await engine.releaseApplyFollow()
        let applied = await applying.value
        #expect((try? applied.get()) != nil, "setup: v4 is applied: \(applied)")
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await uWaiter.value }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await pWaiter.value }
        let starts = await s.harness.source.starts.filter { $0.id == xT }.count
        #expect(!throttled, "U's waiting join reaches X through its own entry: X is user work, and the 429 beyond the user lane's cap throttles nothing (visit-first)")
        for (name, answer) in [("U", uResult), ("P", pResult)] {
            if case .failure(.serverUnavailable) = answer {
            } else {
                Issue.record("\(name) is answered serverUnavailable at the 429's verdict (visit-first): \(answer)")
            }
        }
        #expect(starts == 1, "X starts once (visit-first): \(starts)")
        await Self.finishHeld(s)
    }
}
