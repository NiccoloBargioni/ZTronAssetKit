import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The ids a visit-first engine's visits had moved off a job before its exit verdict arrived (`AttemptEnd.movedBefore`,
/// Stage 3 close-out cycle 17): which ids they are when the attempt ended in its publication with no apply since
/// (`recordDeferredVerdict`), and the lane a 429 reads while the drain still owes their take-off (`followedLane`). Each
/// test runs in both orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// C (100 kB: zz-a and zz-b, a user waiter each) publishes bytes that fail their checksum; a later attempt of C's
    /// content would stage the right ones. v3 moves zz-b to N (16 B, held); C's publication begins after v3's apply and is
    /// held at its first store unit, so behind the barrier it begins while v3's follow owes C's visit (`rerouteOnPass` is
    /// `[zz-b]`). v4 maps zz-b back to C's content while that follow is still owed, and the publication then fails its
    /// checksum while it is owed too: the integrity verdict waits, with no apply since the publication's end. Visited
    /// first, v3's visit moved B onto N while C downloaded, v4's superseded N and joined B to C, publishing, and C's
    /// integrity failure answered A and B. Returns their answers.
    @available(macOS 15.0, iOS 18.0, *)
    func publicationMappedBack(_ visit: LaneDropVisit, seed: UInt64) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>) {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong), .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        // v3 moves zz-b to N.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-pub-back-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            // Visited first, C's visit moved B onto N, whose download is held, at the apply.
            await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
        }
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            let atPublish = await engine.readForTests { e in (owed: e.followOwed, reroute: e.state.jobs[a.transferID]?.rerouteOnPass) }
            try #require(atPublish.owed && atPublish.reroute == [b.identifier], "setup: C's publication began while v3's follow owed C's visit: \(atPublish)")
        }
        // v4 maps zz-b back while (behind the barrier) v3's follow still owes C's visit.
        try await Self.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-pub-back-\(seed)", s, visit: visit)
        let atV4 = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), n: e.state.jobs[bMoved.transferID]?.state)
        }
        try #require(atV4.owed == (visit == .sweepFollowsFirst) && atV4.c == .verifying && atV4.cAssets == [a.identifier, b.identifier] && atV4.n == nil, "setup: C still publishes with both ids, N is gone: \(atV4)")
        // The publication fails its checksum while (behind the barrier) the follow is still owed.
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            let waiting = await engine.readForTests { e in (owed: e.followOwed, end: e.state.jobs[a.transferID]?.attemptEnd) }
            try #require(waiting.owed && waiting.end?.deferredAfter != nil && waiting.end?.failedAfter == waiting.end?.deferredAfter, "setup: the verdict waits with no apply since the publication's end: \(waiting)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (aResult, bResult)
    }

    /// The ids moved off a publication before it began and moved back by an apply while it published, before its visit,
    /// are not among those the drain takes off before its verdict when it ends with no apply since (`publicationMappedBack`;
    /// `recordDeferredVerdict` keeps the publication's set less the ids the copy maps back to the job): visited first,
    /// v4's visit joined B to C, publishing, and C's integrity failure answered it. Taken off and re-routed after the
    /// verdict, B was served by a fresh attempt of C's content.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an id an apply moves back while a publication runs gets the publication's outcome when its verdict waits (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAnIDMovedBackDuringAPublicationWithItsOutcome(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.publicationMappedBack(visit, seed: 1_617_902)
        #expect(outcome.a == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(outcome.a)")
        #expect(outcome.b == .failure(.integrityFailure), "B was back on C, publishing, at its integrity failure (visit-first): \(outcome.b)")
    }

    /// What `takeOffLane` reads: the origin's throttle after J's 429, and the answers of A, B and P.
    struct TakeOffLaneOutcome {
        /// The origin's throttle end after J's 429.
        let after: MonotonicInstant?
        /// A's answer.
        let a: Result<AssetLocation, AssetError>
        /// B's answer.
        let b: Result<AssetLocation, AssetError>
        /// P's answer.
        let p: Result<AssetLocation, AssetError>
    }

    /// O (100 kB: zz-a and zz-b, a user waiter each) and J (16 B: zz-p, a prefetch waiter P) download. v3 moves zz-b to N
    /// (24 B); a conditions element then arrives, which behind the barrier waits and ends the drain's first batch, and O
    /// gets a 404 while v3's follow is owed: its verdict waits, with zz-b among the ids a visit-first engine's visits had
    /// moved off O before it (`AttemptEnd.movedBefore`). v4 maps zz-b back to O's content, and the follow ends with the
    /// drain's second turn (O's verdict) held. v5 then moves zz-b onto J's content, and J gets a 429 with `Retry-After`
    /// 60 s (above the user lane's 30 s cap, below the prefetch lane's) while v5's follow is owed: that follow's visit
    /// passes O (the re-route belonged to v3's follow, which ended), so zz-b stays on O until the drain takes it off before
    /// the verdict and re-routes it onto J after it. Visited first, v3's visit moved B onto N, O's 404 answered A and
    /// removed O, v4's visit moved B to a fresh job of O's content and v5's onto J, so J's 429 was user work: beyond the
    /// user lane's cap, it throttled nothing and failed J, answering P and B `serverUnavailable`.
    @available(macOS 15.0, iOS 18.0, *)
    func takeOffLane(_ visit: LaneDropVisit, seed: UInt64) async throws -> TakeOffLaneOutcome {
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let jBytes = EngineFixture.bytes(seed + 5, count: 16)
        let nBytes = EngineFixture.bytes(seed + 7, count: 24)
        let a = EngineHarness.onDemand("zz-a", oBytes)
        let b = EngineHarness.onDemand("zz-b", oBytes)
        let p = EngineHarness.onDemand("zz-p", jBytes)
        let bToN = EngineHarness.onDemand("zz-b", nBytes)
        let bToJ = EngineHarness.onDemand("zz-b", jBytes)
        try #require(a.transferID == b.transferID && p.transferID == bToJ.transferID && bToN.transferID != a.transferID && bToN.transferID != p.transferID, "setup: zz-a and zz-b share O; zz-p and v5's zz-b share J; N is a third content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, p] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .hold, .stage(oBytes)])
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(jBytes)])
        await s.harness.source.script(bToN.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        // v3 moves zz-b to N.
        try await Self.applyHeld([s.q] + fillers + [a, bToN, p] + later, tag: "v3-takeoff-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[bToN.transferID]?.state == .downloading }
        }
        // A conditions element (no change): behind the barrier it waits and ends the drain's first batch.
        await s.harness.conditions.send(.unrestricted)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.contains { event in
                    if case .conditions = event {
                        return true
                    }
                    return false
                }
            }
        }
        // O's 404.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            let moved = await engine.readForTests { $0.state.jobs[a.transferID]?.attemptEnd?.movedBefore }
            try #require(moved == [b.identifier], "setup: O's verdict waits with zz-b moved off it before the verdict: \(String(describing: moved))")
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        }
        // v4 maps zz-b back to O's content.
        try await Self.applyHeld([s.q] + fillers + [a, b, p] + later, tag: "v4-takeoff-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            // The follow ends; the drain's first turn applies the conditions element, and its second (O's verdict) is held.
            await engine.readForTests { e in
                e.holdDrainFollowUps()
                e.releaseFollowFollowUps()
            }
            await engine.awaitCondition { !$0.followOwed && $0.state.drainFollowUpWaiting }
        } else {
            // Visited first, N's visit moved B to a fresh job of O's content, whose download is held.
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[bToN.transferID] == nil }
        }
        // v5 moves zz-b onto J's content; its own later fillers keep its follow owed after the apply's turn.
        try await Self.applyHeld([s.q] + fillers + [a, bToJ, p] + Self.laterFillers(seed + 9_000), tag: "v5-takeoff-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let atV5 = await engine.readForTests { e in
                (
                    owed: e.followOwed, waits: e.state.verdictsAfterFollow[a.transferID] != nil,
                    holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true,
                    visit: e.state.jobs[a.transferID].flatMap { e.rerouteOnVisit($0) }
                )
            }
            try #require(atV5.owed && atV5.waits && atV5.holdsB && atV5.visit == [], "setup: v5's follow is owed and passes O, which keeps zz-b until the drain takes it off: \(atV5)")
        } else {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.interests.count == 2 }
        }
        // J's 429 (Retry-After 60 s) arrives now.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let after = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { e in
                e.releaseDrainFollowUps()
                e.releaseFollowFollowUps()
            }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return TakeOffLaneOutcome(after: after, a: aResult, b: bResult, p: pResult)
    }

    /// A 429 that arrives while the drain still owes the take-off of an id a later apply moved onto its content counts
    /// that id's interest on its lane, though the owed visit passes the id's job (`takeOffLane`; `followedLane` reads
    /// `AttemptEnd.movedBefore`, Stage 3 close-out cycle 17): visited first, B was on J at the 429, which was user work
    /// beyond the user lane's cap, so it throttled nothing and answered P and B `serverUnavailable`. Read as an interest
    /// O's 404 answers, J's 429 throttled the origin on P's prefetch lane and J's retry served P and B.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 counts the interest the drain takes off a waiting verdict's job and re-routes onto it (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429OnAnInterestTheDrainTakesOffBeforeAVerdict(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.takeOffLane(visit, seed: 1_618_002)
        #expect(outcome.after == nil, "J's 429 is beyond the user lane's cap: B's interest makes it user work, which throttles nothing (visit-first): \(String(describing: outcome.after))")
        #expect(outcome.a == .failure(.notFound), "A gets O's 404 (visit-first): \(outcome.a)")
        Self.expectServerUnavailable(outcome.b, "B was on J at its 429 beyond the user lane's cap (visit-first)")
        Self.expectServerUnavailable(outcome.p, "P is answered J's 429 beyond the user lane's cap, B being on J (visit-first)")
    }
}
