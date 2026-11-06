import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A purge's withdrawal from one job (Stage 3 close-out cycle 22, ruling S3-R27 item 12.3, e2-A1.4): the job's purged
/// interests leave it in ascending token order, its lane read before each removal, and the job is settled as one removal
/// at a time settled it. A job a claim keeps holds the lane before its last removal (`Job.heldLane`; e2 review must-fix
/// 6); a job the purge empties was re-laned by its earlier removals when they lowered its lane, before the last one
/// retired it or a claim kept it; a job left with interests is re-laned once, to the lane they leave it. Each case runs
/// on a transfer the fake source holds, so a priority change and a cancellation reach its control log.
@Suite("Engine purge withdrawal")
struct EnginePurgeWithdrawalTests {
    /// The groups registered on x's job, in token order, with the lane each registered at, and the claim of a group whose
    /// join is held, when `claimed`; the job in flight with every group's interest.
    @available(macOS 15.0, iOS 18.0, *)
    struct Setup {
        let harness: EngineHarness
        let job: TransferID
        let groups: [InterestToken]
        let claimant: InterestToken?
    }

    /// x's content in flight, with one group per `lanes` element registered on `members` in that order (so their
    /// tokens ascend), each one's interest holding its members, and, when `claimed`, a third group's pending claim on x,
    /// its join held (`recordGroup`).
    @available(macOS 15.0, iOS 18.0, *)
    static func setUp(seed: UInt64, members: [[AssetID]], lanes: [AssetPriority], claimed: Bool) async throws -> Setup {
        let bytes = EngineFixture.bytes(seed)
        let ids = Set(members.joined()).sorted()
        let entries = ids.map { EngineHarness.onDemand($0.rawValue, bytes) }
        let job = try #require(entries.first?.transferID)
        try #require(entries.allSatisfy { $0.transferID == job }, "setup: every id shares x's content")
        let harness = try await EngineGroupClaimTests.started(entries)
        let engine = harness.engine
        var groups: [InterestToken] = []
        for (ids, lane) in zip(members, lanes) {
            groups.append(try await engine.registerGroup(ids, lane: lane).get())
        }
        try #require(groups == groups.sorted(), "setup: the groups' tokens ascend in registration order")
        let joined = Dictionary(uniqueKeysWithValues: zip(groups, members.map { Set($0) }))
        await engine.awaitCondition { engine in
            EngineGroupClaimTests.inFlight(job, engine) && joined.allSatisfy { engine.state.jobs[job]?.interests[$0.key]?.assets == $0.value }
        }
        let claimant = claimed ? await engine.inOneTurn { $0.recordGroup(["x"], lane: .prefetch).token } : nil
        return Setup(harness: harness, job: job, groups: groups, claimant: claimant)
    }

    /// Purges `scope`, and returns the job's controls the purge made (those after the setup's), whether a claim keeps the
    /// job, its lane and held lane, and the engine's invariants.
    @available(macOS 15.0, iOS 18.0, *)
    static func purge(_ ids: [AssetID], _ s: Setup) async -> (controls: [TransferControl], held: Bool, lane: AssetPriority?, heldLane: AssetPriority?, violations: [String]) {
        let engine = s.harness.engine
        let before = await EngineGroupClaimTests.controls(of: s.job, s.harness).count
        let purged = await s.harness.withClock { await engine.purge(.scope(.identifiers(Set(ids)))) }
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        let controls = Array(await EngineGroupClaimTests.controls(of: s.job, s.harness).dropFirst(before))
        let job = s.job
        let state = await engine.readForTests { engine in
            (held: engine.state.claimHeld.values.contains(job), lane: engine.state.jobs[job]?.lane, heldLane: engine.state.jobs[job]?.heldLane, violations: engine.invariantViolations())
        }
        return (controls, state.held, state.lane, state.heldLane, state.violations)
    }

    /// Releases every group and shuts the engine down.
    @available(macOS 15.0, iOS 18.0, *)
    static func finish(_ s: Setup) async {
        let engine = s.harness.engine
        for token in s.groups + [s.claimant].compactMap({ $0 }) {
            await engine.releaseGroup(token)
        }
        await engine.waitForJobEnd(s.job)
        await engine.shutdown()
    }

    /// The ruling's case (e2 review must-fix 6, "must add" 2): t1's interest is `.bulk`, t2's `.prefetch`, both on x and
    /// both purged, and a claim keeps the job. Removed in ascending token order, t1 leaves the job at `.prefetch`, so the
    /// lane before the last removal, which the claim-held job keeps, is `.prefetch`; removed t2 first, it would be
    /// `.bulk`. Nothing re-lanes the job, so the purge makes no control.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge removes a job's interests in ascending token order, so the job a claim keeps holds the lane before the last removal (S3-R27 item 12.3, e2-A1.4)", .timeLimit(.minutes(1)))
    func purgeRemovesInAscendingTokenOrder() async throws {
        let s = try await Self.setUp(seed: 2_031_101, members: [["x"], ["x"]], lanes: [.bulk, .prefetch], claimed: true)
        let after = await Self.purge(["x"], s)
        #expect(after.held, "the claim keeps the job the purge emptied")
        #expect(after.heldLane == .prefetch && after.lane == .prefetch, "the job holds t2's lane, the lane before the last removal: \(String(describing: after.heldLane))")
        #expect(after.controls.isEmpty, "no removal changed the job's lane: \(after.controls)")
        #expect(after.violations.isEmpty, "\(after.violations)")
        await Self.finish(s)
    }

    /// t1's interest is `.prefetch`, t2's `.bulk`, both on x and both purged. Removed one at a time, t1's removal left the
    /// job t2 and re-laned it to `.bulk`, a priority change of its running transfer; t2's removal then emptied it, and a
    /// claim kept it at `.bulk`, or, with no claim, it was retired and its transfer cancelled. The purge's single settle
    /// keeps that re-lane (e2-A1.4).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge that empties a job whose earlier removals lowered its lane re-lanes it before the last removal, kept by a claim or retired (S3-R27 item 12.3, e2-A1.4)", .timeLimit(.minutes(1)), arguments: [true, false])
    func purgeThatEmptiesAJobKeepsItsEarlierRelane(claimed: Bool) async throws {
        let s = try await Self.setUp(seed: 2_031_111, members: [["x"], ["x"]], lanes: [.prefetch, .bulk], claimed: claimed)
        let after = await Self.purge(["x"], s)
        if claimed {
            #expect(after.held && after.heldLane == .bulk, "the claim keeps the job at the lane before the last removal: \(String(describing: after.heldLane))")
            #expect(after.controls == [.setPriority(.bulk)], "the first removal's re-lane reached the transport: \(after.controls)")
        } else {
            #expect(!after.held && after.lane == nil, "the emptied job is retired")
            #expect(after.controls == [.setPriority(.bulk), .cancel], "the first removal's re-lane, then the retirement's cancellation: \(after.controls)")
        }
        #expect(after.violations.isEmpty, "\(after.violations)")
        await Self.finish(s)
    }

    /// T-A-SCOPE (e2 §3; ruling S3-R27 item 12.3's kill of e2-A1.5's fast path taken always, and of
    /// `Job.withdrawPurged`'s partial arm): x and y share one content, which a prefetch group of both holds with one
    /// interest; a `.scope` purge of x withdraws x only. The interest keeps y, and y stays pending; with the fast path
    /// taken for a scope, the interest would go whole, both members with it, and the job would be retired.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a scope purge of one of two ids that share a content withdraws that id only, so the group keeps the other member and its interest (S3-R27 item 12.3, e2-A1.5's T-A-SCOPE)", .timeLimit(.minutes(1)))
    func scopePurgeWithdrawsOnlyItsIDs() async throws {
        let s = try await Self.setUp(seed: 2_031_131, members: [["x", "y"]], lanes: [.prefetch], claimed: false)
        let after = await Self.purge(["x"], s)
        let group = s.groups[0]
        let job = s.job
        let kept = await s.harness.engine.readForTests { engine in
            (assets: engine.state.jobs[job]?.interests[group]?.assets, pending: engine.state.groups[group]?.pending)
        }
        #expect(kept.assets == ["y"], "the group's interest keeps y: \(String(describing: kept.assets))")
        #expect(kept.pending == ["y": job], "y stays pending, x is dropped: \(String(describing: kept.pending))")
        #expect(after.lane == .prefetch && after.controls.isEmpty, "the job keeps its lane and its transfer: \(after.controls)")
        #expect(after.violations.isEmpty, "\(after.violations)")
        await Self.finish(s)
    }

    /// e2-A2.5: x and y, each its own content, wait for their retries, each held by a prefetch group of its own. A
    /// `.scope` purge of x retires x's job, and the walk's one pass takes its `.retry` deadline out, leaving y's; the
    /// release of y's group then retires y's job outside a purge, and `removeJob` takes y's deadline out itself. With the
    /// pass dropped x's deadline would stay; with `removeJob` deferring outside a walk, or the walk's set left behind it,
    /// y's would.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge takes the retry deadlines of the jobs it retires out of the heap in one pass, and a removal after it takes its own (S3-R27 item 12.3, e2-A2.5)", .timeLimit(.minutes(1)))
    func purgeTakesItsRetiredJobsRetryDeadlinesOut() async throws {
        let entries = [EngineHarness.onDemand("x", EngineFixture.bytes(2_031_141)), EngineHarness.onDemand("y", EngineFixture.bytes(2_031_142))]
        let transfers = entries.map(\.transferID)
        try #require(transfers[0] != transfers[1], "setup: x and y have contents of their own")
        let harness = try await EngineGroupClaimTests.started(entries)
        let engine = harness.engine
        for transfer in transfers {
            await harness.source.script(transfer, [.fail(.transient(.timedOut, retryAfter: nil)), .hold])
        }
        let x = try await engine.registerGroup(["x"], lane: .prefetch).get()
        let y = try await engine.registerGroup(["y"], lane: .prefetch).get()
        await engine.awaitCondition { engine in
            transfers.allSatisfy { EngineRegressionTests.retryScheduled(engine, $0) }
        }
        // No clock is driven: a driver would advance the time to y's retry, which would start y's job again, and to a
        // deadline of x's left on the heap, which would fire and leave it.
        let purged = await engine.purge(.scope(.identifiers(["x"])))
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        let afterPurge = await engine.readForTests { engine in
            (
                gone: engine.state.jobs[transfers[0]] == nil,
                x: EngineRegressionTests.retryScheduled(engine, transfers[0]),
                y: EngineRegressionTests.retryScheduled(engine, transfers[1]),
                violations: engine.invariantViolations()
            )
        }
        #expect(afterPurge.gone && !afterPurge.x, "the purge retired x's job and took its retry deadline out: \(afterPurge)")
        #expect(afterPurge.y, "y's job still waits for its retry")
        #expect(afterPurge.violations.isEmpty, "\(afterPurge.violations)")
        await engine.releaseGroup(y)
        await engine.awaitCondition { $0.state.jobs[transfers[1]] == nil }
        let afterRelease = await engine.readForTests { EngineRegressionTests.retryScheduled($0, transfers[1]) }
        #expect(!afterRelease, "the release retired y's job, which took its retry deadline out")
        await engine.releaseGroup(x)
        await engine.shutdown()
    }

    /// t1's interest is `.prefetch` and t2's `.bulk`, both on x, and t3's `.bulk`, on y, which shares x's content; the
    /// purge selects x only. Removed one at a time, t1's removal re-laned the job to `.bulk` and t2's changed nothing:
    /// one priority change. The single settle re-lanes the job once, from its lane before the first removal (e2-A1.4).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge that leaves a job interests re-lanes it once, to the lane they leave it (S3-R27 item 12.3, e2-A1.4)", .timeLimit(.minutes(1)))
    func purgeThatLeavesInterestsRelanesOnce() async throws {
        let s = try await Self.setUp(seed: 2_031_121, members: [["x"], ["x"], ["y"]], lanes: [.prefetch, .bulk, .bulk], claimed: false)
        let after = await Self.purge(["x"], s)
        #expect(after.lane == .bulk && !after.held, "t3 keeps the job, at its lane: \(String(describing: after.lane))")
        #expect(after.controls == [.setPriority(.bulk)], "one priority change: \(after.controls)")
        #expect(after.violations.isEmpty, "\(after.violations)")
        await Self.finish(s)
    }

    /// What a purge never withdraws, joined or waiting for the follow (S3-R27 item 12.3): the lane and kind conditions
    /// e2-A1.4 moved into `Job.withdrawPurged` and e2-A1.2 into `withdrawPurgedJoins`' predicate. W downloads for a user
    /// waiter while v3's follow is owed; a user-lane group registers zz-u and a prefetch waiter asks for zz-p, then
    /// `purge(.scope([zz-u, zz-p]))` arrives. Followed first, both joined jobs, and the purge leaves each job its
    /// interest; behind the barrier both joins wait, the purge withdraws neither, and the drain joins them, as visited
    /// first. Without the lane condition the group's interest or join would be withdrawn, and its member dropped; without
    /// the kind condition, the waiter's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge keeps a user-lane group's and a prefetch waiter's interests, joined or waiting for the follow (S3-R27 item 12.3, F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func purgeKeepsUserLaneAndWaiterInterests(_ visit: LaneDropVisit) async throws {
        typealias FollowBarrier = EngineSyncTests.FollowBarrier
        let (s, _) = try await FollowBarrier.setUp(seed: 2_031_161)
        let engine = s.engine
        let uBytes = EngineFixture.bytes(2_031_163, count: 100_000)
        let pBytes = EngineFixture.bytes(2_031_164, count: 100_000)
        let wBytes = EngineFixture.bytes(2_031_165, count: 100_000)
        let u = EngineHarness.onDemand("zz-u", uBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let w = EngineHarness.onDemand("zz-w", wBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(2_031_200) + [p, u, w], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        for (entry, bytes) in [(u, uBytes), (p, pBytes), (w, wBytes)] {
            await s.harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[w.transferID]?.state == .downloading }
        }
        try await EngineFollowBarrierTests.applyHeld([s.q] + FollowBarrier.fillers(2_031_300) + [p, u, w], tag: "v3-purge-keeps", s, visit: visit)
        let group = try await engine.registerGroup([u.identifier], lane: .userInitiated).get()
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, u) && FollowBarrier.joinWaits($0, p) }
        } else {
            await engine.awaitCondition { engine in
                engine.state.jobs[u.transferID]?.interests[group] != nil && engine.state.jobs[p.transferID]?.interests.values.contains { $0.kind == .waiter } == true
            }
        }
        let purged = await engine.purge(.scope(.identifiers([u.identifier, p.identifier])))
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { engine in
            (
                group: engine.state.groups[group]?.pending[u.identifier] == u.transferID && engine.state.jobs[u.transferID]?.interests[group] != nil,
                waiter: engine.state.jobs[p.transferID]?.interests.values.contains { $0.kind == .waiter && $0.lane == .prefetch } == true
            )
        }
        #expect(after.group, "the group still waits for zz-u, whose job holds its interest: \(after)")
        #expect(after.waiter, "zz-p's job holds the prefetch waiter's interest: \(after)")
        await engine.releaseGroup(group)
        await EngineFollowBarrierTests.finishHeld(s)
        _ = await pWaiter.value
        _ = await wWaiter.value
    }
}
