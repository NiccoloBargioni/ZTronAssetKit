import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The follow barrier under the narrowed bar (Stage 3 close-out cycle 13, the owner's ruling S3-R16): whatever order the
/// follow's visits and an event take, a caller gets the visit-first answer and every MUST holds. Above all R-SYN-5: no
/// request goes to an origin whose throttle or open breaker is live, and a 429 throttles its origin when it arrives.
/// Each test runs in both orders (`LaneDropVisit`), as the other barrier tests do.
extension EngineFollowBarrierTests {
    // MARK: Admission reads the live origin gates (S3-R16 items 1(b) and 3; the cycle-12 residual R-I)

    /// A place the follow's visit gives behind the barrier is admitted on the live throttle, not on the throttle of the
    /// apply it belongs to: one slot. C (1 MB) downloads for user waiters A (zz-a) and B (zz-b) and holds the slot. v3
    /// moves zz-a to N (16 bytes) while the follow owes C's visit; then C gets a 429 with Retry-After 60 s. Visited
    /// first, N waited at the apply behind C's slot, the 429 throttled the origin and freed the slot, and the pump
    /// refused N on the live throttle: A was answered `serverUnavailable(60)` and N never started. Admitted on the view
    /// of the apply (no throttle then), N's request went to the throttled origin and A was served 16 bytes (the cycle-12
    /// verifiers' PROBE-C12-PLACE-SLOT).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a place an owed follow's visit gives is admitted on the live throttle, not the apply's (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAdmitsAVisitsPlaceOnTheLiveThrottle(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_304_002, tuning: SyncTuning(maxConcurrentTransfers: 1))
        let engine = s.engine
        let cBytes = Data(repeating: 0xC7, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_304_100) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let nBytes = EngineFixture.bytes(1_304_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_304_200) + [aMoved, b], s, visit: visit)
        let afterApply = await engine.readForTests { e in
            (owed: e.followOwed, n: e.state.jobs[aMoved.transferID]?.state, c: e.state.jobs[a.transferID]?.state)
        }
        if visit == .followVisitedFirst {
            #expect(afterApply.n == .queued && afterApply.c == .downloading, "setup: N waits for the slot C holds: \(afterApply)")
        } else {
            #expect(afterApply.owed && afterApply.n == nil && afterApply.c == .downloading, "setup: C's visit is owed: \(afterApply)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        // The clock has not moved since the 429: the origin is still throttled.
        let atEnd = await engine.readForTests { e in
            (throttled: e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil, n: e.state.jobs[aMoved.transferID]?.state)
        }
        let nStarted = await s.harness.source.starts.contains { $0.id == aMoved.transferID }
        #expect(atEnd.throttled, "the origin is throttled when the barrier ends: \(atEnd)")
        #expect(!nStarted, "no request goes to the throttled origin for N (visit-first: N parks on the live throttle): \(atEnd)")
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        if case .failure(.serverUnavailable(let retryAfter?)) = aResult {
            #expect(abs(retryAfter - 60) < 1, "A gets the 60 s throttle's answer (visit-first): \(aResult)")
        } else {
            Issue.record("A, moved to N while the slot was C's, is answered with the throttle (visit-first serverUnavailable(60)): \(aResult)")
        }
        if case .failure(.serverUnavailable) = bResult {
        } else {
            Issue.record("B gets the throttle's answer: \(bResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: A 429 throttles its origin on arrival (S3-R16 item 1(b); the cycle-12 residual R-H)

    /// A 429 throttles its origin when it arrives also when the owed visits move every id its job holds now: D (content
    /// Z) downloads for user waiter WA (zz-a) and C (content X) for user waiter WB (zz-b). v3 maps zz-a to X and zz-b to
    /// Y (16 bytes) while the follow owes D's visit, then C's. C gets a 429 without Retry-After, and a user then asks for
    /// zz-none, which no manifest lists. Visited first, D's visit re-routed WA onto C, so C kept zz-a on the user lane
    /// and its 429 throttled the origin for the interactive backoff: the fetch for zz-none was refused without a request
    /// and its caller answered `serverUnavailable`. Behind the barrier no interest of C kept an id the copy maps to C
    /// (`followedLane` counts only C's own), the 429 left the origin unthrottled until the drain (`.undecided`), and the
    /// fetch went to the throttled origin (the cycle-12 verifiers' PROBE-C12-UNDECIDED-LANE). The throttle's length is
    /// not asserted: which lane's backoff applies is a recorded residual risk (S3-R16 item 2).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow throttles the origin on arrival when the visits move every id of its job (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierThrottlesOnArrivalWhenTheVisitsMoveEveryID(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_305_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xE1, count: 1_000_000)
        let zBytes = Data(repeating: 0xE2, count: 1_000_000)
        let yBytes = EngineFixture.bytes(1_305_004, count: 16)
        let a = EngineHarness.onDemand("zz-a", zBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_305_100) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: nil)), .stage(xBytes)])
        await s.harness.source.script(a.transferID, [.hold, .stage(zBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let aMoved = EngineHarness.onDemand("zz-a", xBytes)
        let bMoved = EngineHarness.onDemand("zz-b", yBytes)
        try #require(aMoved.transferID == b.transferID, "setup: v3's zz-a names C's content")
        await s.harness.source.script(bMoved.transferID, [.stage(yBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_305_200) + [aMoved, bMoved], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { $0.followOwed }
            #expect(owed, "setup: the follow owes D's and C's visits")
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttle = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        #expect(throttle != nil, "C's 429 throttles the origin on arrival (visit-first)")
        let requestsBefore = await s.harness.source.manifestRequests.count
        let unknown = await engine.awaitAsset("zz-none", lane: .userInitiated)
        let requestsAfter = await s.harness.source.manifestRequests.count
        #expect(requestsAfter == requestsBefore, "the throttled origin gets no manifest request (visit-first): \(requestsBefore) -> \(requestsAfter)")
        if case .failure(.serverUnavailable) = unknown {
        } else {
            Issue.record("the caller gets the throttle's answer (visit-first): \(unknown)")
        }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(xBytes.count), "WA is served by C's retry: \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "WB is served from Y: \(bResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
