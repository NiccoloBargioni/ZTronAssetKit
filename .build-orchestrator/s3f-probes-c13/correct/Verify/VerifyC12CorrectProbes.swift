import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 12, correctness lens). Never committed.
///
/// Each runs in both orders (`LaneDropVisit`): `.followVisitedFirst` lets the held follow end before the inputs under
/// test; `.sweepFollowsFirst` delivers them while the follow still owes its visits (the barrier holds). Every
/// expectation is the visit-first outcome (S3-R11 item 3).
@Suite("VerifyC12CorrectProbes", .serialized)
struct VerifyC12CorrectProbes {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// PROBE-C12-PLACE-SLOT (residual R-I, "a place stamp assumes a slot was free at the stamp's instant"): one slot.
    /// C (1 MB) downloads for user waiters A (zz-a) and B (zz-b) and holds the only slot. v3 moves zz-a to N (16 B)
    /// while the follow owes C's visit. Then C gets a 429 with Retry-After 60 s.
    /// Visit-first: the visit queues N at the apply, but the slot is C's, so N waits; C's 429 throttles the origin and
    /// frees the slot; the pump refuses N on the live throttle, parks it, and A is answered `serverUnavailable(~60)`.
    /// No request goes to the throttled origin.
    /// Behind the barrier: the follow's visit queues N under the apply's stamp (no throttle in its view); the
    /// barrier-end pump admits N on that view although the live origin is throttled: N starts (a request to a throttled
    /// origin) and A is served 16 bytes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C12-PLACE-SLOT", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func placeSlot(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_204_002, tuning: SyncTuning(maxConcurrentTransfers: 1))
        let engine = s.engine
        let cBytes = Data(repeating: 0xC7, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_204_100) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let nBytes = EngineFixture.bytes(1_204_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_204_200) + [aMoved, b], s, visit: visit)
        let afterApply = await engine.readForTests { e in
            (owed: e.followOwed, n: e.state.jobs[aMoved.transferID]?.state, c: e.state.jobs[a.transferID]?.state, inFlight: e.state.inFlight.count)
        }
        print("PROBE-C12-PLACE-SLOT \(visit) afterApply: \(afterApply)")
        if visit == .followVisitedFirst {
            #expect(afterApply.n == .queued && afterApply.c == .downloading, "setup: N waits for the slot C holds: \(afterApply)")
        } else {
            #expect(afterApply.owed && afterApply.n == nil && afterApply.c == .downloading, "setup: C's visit is owed: \(afterApply)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let throttledAfter429 = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil }
        print("PROBE-C12-PLACE-SLOT \(visit) throttled after the 429: \(throttledAfter429)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        // The clock has not moved since the 429: the origin is still throttled.
        let stateAtEnd = await engine.readForTests { e in
            (throttled: e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil, n: e.state.jobs[aMoved.transferID]?.state,
             c: e.state.jobs[a.transferID]?.state)
        }
        let starts = await s.harness.source.starts.map(\.id)
        let nStarted = starts.contains(aMoved.transferID)
        print("PROBE-C12-PLACE-SLOT \(visit) at the barrier's end: \(stateAtEnd) nStarted=\(nStarted) starts=\(starts.count)")
        #expect(stateAtEnd.throttled, "the origin is throttled when the barrier ends: \(stateAtEnd)")
        #expect(!nStarted, "no request goes to the throttled origin for N (visit-first: N parks on the live throttle): \(stateAtEnd)")
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C12-PLACE-SLOT \(visit) A=\(aResult) B=\(bResult)")
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

    /// PROBE-C12-UNDECIDED-LANE (residual R-H, "followedLane omits interests another owed visit moves onto this
    /// content"): D (content Z) downloads for user waiter WA (zz-a); C (content X) downloads for user waiter WB (zz-b).
    /// v3 moves zz-a to X (C's content) and zz-b to Y (16 B) while the follow owes D's then C's visit. Then C gets a 429
    /// without Retry-After, and a user asks for an id no manifest lists (zz-none).
    /// Visit-first: D's visit re-routes WA onto C; C's visit re-routes WB to Y; C keeps zz-a (user lane). C's 429
    /// throttles the origin for the interactive backoff, so the fetch for zz-none is refused without a request.
    /// Behind the barrier: at the 429, no interest of C keeps an id the copy maps to C (`followedLane` is nil), so the
    /// decision is `.undecided` and the origin is not throttled until the drain: the fetch goes to the origin.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C12-UNDECIDED-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func undecidedLane(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_205_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xE1, count: 1_000_000)
        let zBytes = Data(repeating: 0xE2, count: 1_000_000)
        let yBytes = EngineFixture.bytes(1_205_004, count: 16)
        let a = EngineHarness.onDemand("zz-a", zBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_205_100) + [a, b], etag: "v2")
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
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_205_200) + [aMoved, bMoved], s, visit: visit)
        let afterApply = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[b.transferID]?.state, cAssets: e.state.jobs[b.transferID]?.assets.sorted(), d: e.state.jobs[a.transferID]?.state)
        }
        print("PROBE-C12-UNDECIDED-LANE \(visit) afterApply: \(afterApply)")
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let after429 = await engine.readForTests { e in
            (owed: e.followOwed, throttle: e.state.remote.flatMap { e.state.throttles[$0.originID] }, c: e.state.jobs[b.transferID]?.state)
        }
        print("PROBE-C12-UNDECIDED-LANE \(visit) after the 429: \(after429)")
        #expect(after429.throttle != nil, "C's 429 throttles the origin on arrival (visit-first): \(after429)")
        let requestsBefore = await s.harness.source.manifestRequests.count
        let unknown = await engine.awaitAsset("zz-none", lane: .userInitiated)
        let requestsAfter = await s.harness.source.manifestRequests.count
        print("PROBE-C12-UNDECIDED-LANE \(visit) zz-none: \(unknown) requests \(requestsBefore) -> \(requestsAfter)")
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
        print("PROBE-C12-UNDECIDED-LANE \(visit) WA=\(aResult) WB=\(bResult)")
        #expect((try? aResult.get())?.byteSize == Int64(xBytes.count), "WA is served by C's retry: \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "WB is served from Y: \(bResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
