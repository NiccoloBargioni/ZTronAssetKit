import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The lane a 429 that arrives during an owed follow is decided on (`SyncEngine.followedLane`; Stage 3 close-out cycle
/// 15, the cycle-14 requirements verifier's G4 finding on its branches; ruling S3-R16 items 1(a) and 1(e)). Each test
/// runs in both orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// A 429 during an owed follow on a job none of whose interests count any more is decided on the job's own lane: C
    /// (1 MB, zz-c) downloads for U, a user waiter, alone; while v3's follow is owed, U withdraws; then C gets a 429 with
    /// Retry-After 60 s (above the user lane's 30 s cap). Visited first, the withdrawal retired C and abandoned its
    /// transfer, so no 429 arrived and nothing was throttled, and a later user request for zz-d was served. Decided on
    /// the bulk policy (the held lane of a job no interest keeps, cycle 14), the 429 throttled the origin for 60 s, and
    /// that request was answered `serverUnavailable`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow on a job whose interests all withdraw throttles as its own lane's (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429OnTheOwnLaneOfAJobNothingKeeps(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_320_402, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xEC, count: 1_000_000)
        let dBytes = EngineFixture.bytes(1_320_404, count: 16)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_320_500) + [c, d], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(c.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(d.transferID, [.stage(dBytes)])
        let uWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[c.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_320_600) + [c, d], s, visit: visit)
        uWaiter.cancel()
        let uResult = await uWaiter.value
        #expect(uResult == .failure(.cancelled), "U's caller is answered at once (R-SYN-4): \(uResult)")
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.contains { event in
                    if case .removal = event { return true }
                    return false
                }
            }
            // The withdrawal waits, so C still downloads and its 429 arrives.
            await s.harness.source.release(c.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[c.transferID]?.state != .downloading }
        } else {
            await engine.awaitCondition { $0.state.jobs[c.transferID] == nil }
        }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let dResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await engine.awaitAsset(d.identifier, lane: .userInitiated) }
        #expect(throttleAtArrival == nil, "no 429 throttles the origin: visited first, C's transfer was abandoned at the withdrawal; decided on C's user lane, the 429 is `.exhausted`: \(String(describing: throttleAtArrival))")
        #expect((try? dResult.get())?.byteSize == 16, "a later user request is served, no throttle in force (visit-first): \(dResult)")
        let cLeft = await engine.readForTests { $0.state.jobs[c.transferID] == nil }
        #expect(cLeft, "C is retired: nobody wants it (visit-first)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A 429 during an owed follow on a job no interest keeps is decided on the job's own lane while a purged heal's join
    /// of its content waits: C (1 MB, zz-c) downloads for U, a user waiter, alone; while v3's follow is owed, U
    /// withdraws, zz-c's heal comes due (a system interest at the prefetch lane), and `purge(.scope([zz-c]))` arrives;
    /// then C gets a 429 with Retry-After 60 s (above the user lane's 30 s cap). Visited first, the withdrawal retired C,
    /// the heal's join created a job for zz-c that the purge retired, and no 429 arrived. Behind the barrier the heal's
    /// join waits, withdrawn by the purge (`JoinAfterFollow.withdrawn`, `withdrawPurgedJoins`). Counted, it decided C's
    /// 429 on the prefetch lane's policy, which throttled the origin for 60 s and answered a later user request for zz-d
    /// `serverUnavailable`. C's second scripted hold is the heal's attempt, visited first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow is decided without a purged heal's waiting join (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429WithoutAPurgedHealsJoin(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_321_302
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xED, count: 1_000_000)
        let dBytes = EngineFixture.bytes(seed + 2, count: 16)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [c, d], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(c.transferID, [.hold, .hold])
        await s.harness.source.script(d.transferID, [.stage(dBytes)])
        let uWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[c.transferID]?.state == .downloading }
        }
        // No run: a purge cancels the run a sweep-first follow keeps unsettled.
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [c, d], tag: "v3-purged-heal-\(seed)", s, visit: visit)
        uWaiter.cancel()
        let uResult = await uWaiter.value
        #expect(uResult == .failure(.cancelled), "U's caller is answered at once (R-SYN-4): \(uResult)")
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.contains { event in
                    if case .removal = event { return true }
                    return false
                }
            }
        } else {
            await engine.awaitCondition { $0.state.jobs[c.transferID] == nil }
        }
        await engine.readForTests { $0.scheduleHeal(c.identifier, at: $0.environment.time.monotonicNow()) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { FollowBarrier.joinWaits($0, c) }
            } else {
                await engine.awaitCondition { $0.state.jobs[c.transferID]?.interests.values.contains { $0.kind == .system } == true }
            }
        }
        let purged = await engine.purge(.scope(.identifiers([c.identifier])))
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        if visit == .sweepFollowsFirst {
            let withdrawnJoin = await engine.readForTests { e in
                e.state.eventsAfterFollow.contains { event in
                    if case .join(let join) = event { return join.asset == c.identifier && join.withdrawn }
                    return false
                }
            }
            #expect(withdrawnJoin, "setup: the heal's join waits for the follow, withdrawn by the purge")
            // The withdrawal and the heal's join wait, so C still downloads and its 429 arrives.
            await s.harness.source.release(c.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
            await engine.awaitCondition { $0.state.jobs[c.transferID]?.state != .downloading }
        } else {
            await engine.awaitCondition { $0.state.jobs[c.transferID] == nil }
        }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let dResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await engine.awaitAsset(d.identifier, lane: .userInitiated) }
        #expect(throttleAtArrival == nil, "no 429 throttles the origin: visited first, no 429 arrived; decided on C's user lane, the 429 is `.exhausted`: \(String(describing: throttleAtArrival))")
        #expect((try? dResult.get())?.byteSize == 16, "a later user request is served, no throttle in force (visit-first): \(dResult)")
        let after = await engine.readForTests { e in (job: e.state.jobs[c.transferID] == nil, heal: e.state.heals[c.identifier]) }
        #expect(after.job && after.heal == nil, "no job and no heal for the purged zz-c (visit-first): \(after)")
        await Self.finishHeld(s)
    }

    /// A 429 on prefetch work during an owed follow is decided on the prefetch lane when the interest another job's visit
    /// moves onto it is withdrawn while the follow is owed: C (1 MB, zz-b) downloads for P, a prefetch waiter; Y (zz-u)
    /// downloads for U, a user waiter; v3 moves zz-u onto C's content; U withdraws; then C gets a 429 with Retry-After 60
    /// s (above the user lane's 30 s cap, below the background lane's). Visited first, Y's visit moved U onto C at the
    /// apply and U's withdrawal took it off again, so C was prefetch work at the 429: the origin was throttled for 60 s and
    /// C's retry served P. Behind the barrier U's interest is still Y's and its removal waits (`EventAfterFollow.removal`);
    /// counted by the jobs walk of `followedLane`, it made C user work: `.exhausted`, nothing throttled, and P answered
    /// `serverUnavailable`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow is decided without a moved interest whose withdrawal waits (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429WithoutAMovedInterestWithdrawn(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_321_502
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xEE, count: 1_000_000)
        let yBytes = Data(repeating: 0xEF, count: 1_000_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let u = EngineHarness.onDemand("zz-u", yBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, u], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(yBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        }
        let uMoved = EngineHarness.onDemand("zz-u", cBytes)
        try #require(uMoved.transferID == b.transferID, "setup: v3's zz-u is C's content")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(seed + 200) + [b, uMoved], s, visit: visit)
        uWaiter.cancel()
        let uResult = await uWaiter.value
        #expect(uResult == .failure(.cancelled), "U's caller is answered at once (R-SYN-4): \(uResult)")
        if visit == .sweepFollowsFirst {
            let waiting = await engine.readForTests { e in
                (
                    removal: e.state.eventsAfterFollow.contains { event in
                        if case .removal = event { return true }
                        return false
                    },
                    onY: e.state.jobs[u.transferID]?.interests.values.contains { $0.lane == .userInitiated } == true
                )
            }
            #expect(waiting.removal && waiting.onY, "setup: U's interest is still Y's and its removal waits: \(waiting)")
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.lane == .prefetch }
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect(throttleAtArrival != nil, "the 429 throttles the origin for prefetch work (visit-first): \(String(describing: throttleAtArrival))")
        #expect((try? pResult.get())?.byteSize == Int64(cBytes.count), "P is served by C's retry once the throttle ends (visit-first): \(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A 429 during an owed follow is decided on the lane a waiting join gives the content a later apply moved its id
    /// to: C (1 MB, zz-b) downloads for P, a prefetch waiter. While v3's follow is owed, U requests zz-u (Y's content);
    /// then v4, applied while v3's follow still owes its visits, moves zz-u onto C's content; then C gets a 429 with
    /// Retry-After 60 s (above the user lane's 30 s cap). Visited first, U's request created Y, and v4's visit superseded
    /// Y and moved U onto C, so C was user work at the 429: nothing was throttled, C failed, and P and U were answered
    /// `serverUnavailable`. Behind the barrier U's join waits with Y's entry, and the drain re-routes it to the content
    /// the copy lists (`replayJoin`). Read at the join's own entry, the joins walk of `followedLane` did not count it:
    /// C was prefetch work, the origin was throttled for 60 s and C's retry served P.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow counts a waiting join a later apply moved onto its content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429OnTheLaneAJoinALaterApplyMovedGives(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_321_702
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xE6, count: 1_000_000)
        let yBytes = EngineFixture.bytes(seed + 2, count: 100_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let u = EngineHarness.onDemand("zz-u", yBytes)
        let uMoved = EngineHarness.onDemand("zz-u", cBytes)
        try #require(uMoved.transferID == b.transferID, "setup: v4's zz-u is C's content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, u] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(yBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        // The fillers after the `zz-` ids keep v3's follow owed through v4's apply (sweep-first).
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [b, u] + later, tag: "v3-later-join-\(seed)", s, visit: visit)
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { FollowBarrier.joinWaits($0, u) }
            } else {
                await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
            }
        }
        // v4 while v3's follow still owes its visits (sweep-first): U's waiting join keeps Y's entry.
        try await Self.applyHeld([s.q] + fillers + [b, uMoved] + later, tag: "v4-later-join-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let waiting = await engine.readForTests { e in (join: FollowBarrier.joinWaits(e, u), y: e.state.jobs[u.transferID] == nil) }
            #expect(waiting.join && waiting.y, "setup: U's join waits with Y's entry, and no job holds zz-u: \(waiting)")
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.lane == .userInitiated }
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect(throttleAtArrival == nil, "the 429 beyond the user lane's cap throttles nothing (visit-first `.exhausted`): \(String(describing: throttleAtArrival))")
        Self.expectServerUnavailable(pResult, "P is answered serverUnavailable with C's deferral to the next run (visit-first)")
        Self.expectServerUnavailable(uResult, "U is answered serverUnavailable with C's deferral to the next run (visit-first)")
        await Self.finishHeld(s)
    }

    /// A request that waits for the follow when C's 429 arrives (`throttledPrefetch`): one the joins walk of
    /// `followedLane` must not count.
    enum WaitingRequest: CaseIterable, Sendable {
        /// A user's request for other content (zz-o).
        case otherContent
        /// A user-lane group's join of zz-b, released before the 429.
        case releasedGroup
        /// A user's request for zz-b, withdrawn before the 429.
        case withdrawnWaiter
    }

    /// A 429 on prefetch work during an owed follow is decided on the prefetch lane whatever user request waits for the
    /// follow without joining it at the drain: one slot, no preemption; C (1 MB, zz-b) downloads for P, a prefetch
    /// waiter. While v3's follow is owed, `request` arrives; then C gets a 429 with Retry-After 60 s (above the user
    /// lane's 30 s cap, below the background lane's). Visited first, the request joined other content, or joined C and
    /// left it, so C stayed prefetch work: the 429 throttled the origin for 60 s and C's retry served P. Counted as one of
    /// C's interests, the request made C user work: `.exhausted`, nothing throttled, and P answered `serverUnavailable`.
    /// O (zz-o) is queued behind C's slot, visited first, and created by its join at the drain otherwise: both orders
    /// park it on the throttle and answer its user `serverUnavailable`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow is decided without a waiting request that does not join its job (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, WaitingRequest.allCases)
    func barrierDecidesA429WithoutAWaitingRequestThatDoesNotJoinIt(_ visit: LaneDropVisit, _ request: WaitingRequest) async throws {
        let seed: UInt64 = 1_320_702 + UInt64(WaitingRequest.allCases.firstIndex(of: request) ?? 0) * 100
        let tuning = SyncTuning(maxConcurrentTransfers: 1, preemptLowerLanes: false, interactiveRetry: Self.shortInteractiveRetry)
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: tuning)
        let engine = s.engine
        let cBytes = Data(repeating: 0xE7, count: 1_000_000)
        let oBytes = EngineFixture.bytes(seed + 4, count: 16)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, o], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(o.transferID, [.stage(oBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(seed + 200) + [b, o], s, visit: visit)
        var oWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        switch request {
        case .otherContent:
            let waiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
            oWaiter = waiter
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { FollowBarrier.joinWaits($0, o) }
            } else {
                await engine.awaitCondition { $0.state.jobs[o.transferID]?.state == .queued }
            }
        case .releasedGroup:
            let token = try await engine.registerGroup([b.identifier], lane: .userInitiated).get()
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { FollowBarrier.joinWaits($0, b) }
            } else {
                await engine.awaitCondition { $0.state.jobs[b.transferID]?.interests[token]?.lane == .userInitiated }
            }
            await engine.releaseGroup(token)
        case .withdrawnWaiter:
            let waiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { FollowBarrier.joinWaits($0, b) }
            } else {
                await engine.awaitCondition { $0.state.jobs[b.transferID]?.lane == .userInitiated }
            }
            waiter.cancel()
            let withdrawn = await waiter.value
            #expect(withdrawn == .failure(.cancelled), "the withdrawn user is answered at once (R-SYN-4): \(withdrawn)")
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        if let oWaiter {
            let oResult = await oWaiter.value
            Self.expectServerUnavailable(oResult, "O's user, parked on the throttle C's 429 set, is answered serverUnavailable (visit-first)")
        }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect(throttleAtArrival != nil, "the 429 throttles the origin for prefetch work (visit-first): \(String(describing: throttleAtArrival))")
        #expect((try? pResult.get())?.byteSize == Int64(cBytes.count), "P is served by C's retry once the throttle ends (visit-first): \(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
