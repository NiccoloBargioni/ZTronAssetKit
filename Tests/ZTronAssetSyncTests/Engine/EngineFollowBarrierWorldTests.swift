import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// One view of the world per decision instant (R-SYN-5, R-SYN-11, R-SYN-3, F-28; Stage 3 close-out cycle 12, ruling
/// S3-R15 and the cycle-11 verifiers' probes): while the follow barrier holds, a replayed decision reads the origin's
/// throttle, its breaker and the conditions as they stood at its event's arrival, a follow's visit as they stood at the
/// apply, and a 429 throttles its origin when it arrives. A publication outcome of a job that holds a moved id waits for
/// the follow's visit of it. Each test runs in both orders (`LaneDropVisit`), with the visit-first outcome expected in
/// both.
extension EngineFollowBarrierTests {
    // MARK: A 429 on arrival (S3-R15 item 2)

    /// A 429 without Retry-After that arrives while the follow owes a visit throttles the origin at once, so a manifest
    /// fetch made right after it is refused: C (1 MB) is the content of zz-a (M, a user waiter) and zz-b (P, a prefetch
    /// waiter); v3 moves zz-a while the follow owes C's visit. C gets a 429 without Retry-After; then a user asks for an id
    /// no manifest lists (zz-none), which needs a manifest fetch. Visited first, the 429 throttled the origin for the
    /// backoff of C's followed lane and the fetch was refused without a request. With the throttle waiting for the drain,
    /// the fetch went to the origin and the caller was answered `.notFound` (PROBE-C11-MANIFEST-THROTTLE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow throttles the origin when it arrives, so a manifest fetch after it is refused (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierThrottlesTheOriginWhenA429Arrives(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 991_302)
        let engine = s.engine
        let cBytes = Data(repeating: 0xB3, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: M and P share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(760_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: nil)), .stage(cBytes)])
        let mWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.interests.count == 2 }
        }
        let nBytes = EngineFixture.bytes(991_304, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(860_000) + [aMoved, b], s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { $0.followOwed }
            #expect(owed, "setup: C's 429 arrived while the follow owes its visit")
        }
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
        let mResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: mWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect((try? mResult.get())?.byteSize == 16, "M is served from its new content: \(mResult)")
        #expect((try? pResult.get())?.byteSize == Int64(cBytes.count), "P is served by C's retry: \(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: Replayed joins read the throttle of their arrival (S3-R15 item 1)

    /// A request's join that waits for the follow reads the throttle in force at the request, not a throttle's end that
    /// came after it: T (1 MB, zz-t) runs for a prefetch waiter P. Between v3's fetch and its apply, T gets a 429 with
    /// Retry-After 10 s (T throttle-parked, nobody answered). U's user request for zz-t arrives; then 11 s pass, so the
    /// throttle ends. Visited first, U joined T under the 10 s throttle, beyond the user bound, and was answered
    /// `serverUnavailable(10)`. Replayed after the throttle's end, the join found no throttle, T was re-admitted and U
    /// was served (PROBE-C11-JOIN-THROTTLE-END).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a request during an owed follow is answered on the throttle in force at the request, not one that ended after it (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAJoinOnTheThrottleAtItsRequest(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 991_202)
        let engine = s.engine
        let tBytes = Data(repeating: 0xB4, count: 1_000_000)
        let t = EngineHarness.onDemand("zz-t", tBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(755_000) + [t], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(t.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(10))), .stage(tBytes)])
        let pWaiter = Task { await engine.awaitAsset(t.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[t.transferID]?.state == .downloading }
        }
        await engine.readForTests { e in
            e.holdFollowFollowUps()
            e.holdManifestOutcomeDelivery()
        }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(855_000) + [t], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.manifestOutcomeHeld }
        await s.harness.source.release(t.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[t.transferID]?.state.isThrottleParked == true }
        await engine.readForTests { $0.releaseManifestOutcomeDelivery() }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let joinsBefore = await engine.readForTests { $0.state.metrics.resolveJoins }
        let uWaiter = Task { await engine.awaitAsset(t.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.metrics.resolveJoins > joinsBefore }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, t) }
        }
        s.time.advance(by: 11)
        await engine.awaitCondition { e in e.state.remote.map { e.state.throttles[$0.originID] == nil } ?? false }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        if case .failure(.serverUnavailable(let retryAfter?)) = uResult {
            #expect(abs(retryAfter - 10) < 0.5, "U's fail-fast reads the 10 s throttle in force at its request (visit-first): \(uResult)")
        } else {
            Issue.record("U gets the throttle's fail-fast answer at its request (visit-first serverUnavailable(10)): \(uResult)")
        }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect((try? pResult.get())?.byteSize == Int64(tBytes.count), "P is served by T's retry once the throttle ended: \(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A request's join that waits for the follow reads the throttle in force at the request, not a later 429's
    /// extension, which answers it in its own turn: T (1 MB, zz-t) runs for a prefetch waiter P; E (1 MB, zz-e) runs for
    /// a user waiter. Between v3's fetch and its apply, T gets a 429 with Retry-After 2 s (T throttle-parked, nobody
    /// answered). U's user request for zz-t arrives; 1.5 s later E gets a 429 with Retry-After 300 s. Visited first, U
    /// joined T under the 2 s throttle (within the user bound: no answer), and the extension's fail-fast turn answered U
    /// with 300 s. Replayed at the request's instant against the extended end, U's join was answered with 301.5 s
    /// (PROBE-C11-JOIN-THROTTLE-EXT).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a request during an owed follow is answered by a later throttle extension's turn, with its wait (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAJoinWithTheExtensionAfterIt(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 991_102)
        let engine = s.engine
        let tBytes = Data(repeating: 0xB1, count: 1_000_000)
        let eBytes = Data(repeating: 0xB2, count: 1_000_000)
        let t = EngineHarness.onDemand("zz-t", tBytes)
        let ex = EngineHarness.onDemand("zz-e", eBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(750_000) + [ex, t], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(t.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(2))), .stage(tBytes)])
        await s.harness.source.script(ex.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(300))), .stage(eBytes)])
        let pWaiter = Task { await engine.awaitAsset(t.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[t.transferID]?.state == .downloading }
        }
        let eWaiter = Task { await engine.awaitAsset(ex.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[ex.transferID]?.state == .downloading }
        await engine.readForTests { e in
            e.holdFollowFollowUps()
            e.holdManifestOutcomeDelivery()
        }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(850_000) + [ex, t], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.manifestOutcomeHeld }
        await s.harness.source.release(t.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[t.transferID]?.state.isThrottleParked == true }
        await engine.readForTests { $0.releaseManifestOutcomeDelivery() }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let uWaiter = Task { await engine.awaitAsset(t.identifier, lane: .userInitiated) }
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[t.transferID]?.interests.count == 2 }
        } else {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, t) }
        }
        s.time.advance(by: 1.5)
        await s.harness.source.release(ex.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[ex.transferID]?.state != .downloading }
        await engine.awaitCondition { !$0.state.throttleAnswersScheduled }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled && !$0.state.throttleAnswersScheduled }
        let uResult = await EngineHarness.value(of: uWaiter)
        if case .failure(.serverUnavailable(let retryAfter?)) = uResult {
            #expect(abs(retryAfter - 300) < 0.5, "U gets the extension's answer at E's 429 (visit-first 300 s): \(uResult)")
        } else {
            Issue.record("U gets the throttle's answer: \(uResult)")
        }
        let eResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: eWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        if case .failure(.serverUnavailable) = eResult {
        } else {
            Issue.record("E's waiter gets its throttle's answer: \(eResult)")
        }
        #expect((try? pResult.get())?.byteSize == Int64(tBytes.count), "P is served by T's retry: \(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: Refusals on the gates of the place's instant, admissions on the live gates (S3-R15 item 3, S3-R16 item 3)

    /// The new content a follow's visit queues starts only under the live throttle (R-SYN-5): C (1 MB) is the content of
    /// zz-a and zz-b, one user waiter each; v3 moves zz-a to N (16 bytes, held once started) while the follow owes C's
    /// visit. C's attempt gets a 429 with Retry-After 60 s. Visited first, the visit created N before the 429 and N
    /// started, so A is served from N and the throttle's fail-fast answers B only. Behind the barrier the visit comes
    /// after the 429: N's start would be a request to an origin whose throttle is live, which R-SYN-5 forbids, so N parks
    /// on the live throttle and A is answered `serverUnavailable` too (PROBE-C9-THROTTLE). Cycle 12 admitted N on the
    /// apply's view (`placeStamps`) and served A; ruling S3-R16 items 1(b) and 3 make admission read the live gates, and
    /// A's answer here is the one case in which the visit-first answer cannot be given without that request (recorded
    /// in the WP-F draft, cycle 13, with the old assertion).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: the new content an owed follow's visit queues starts only under the live throttle, not the apply's (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAdmitsTheFollowsNewContentAsAtTheApply(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 996_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0xC5, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(760_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let nBytes = EngineFixture.bytes(996_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.hold, .stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(860_000) + [aMoved, b], s, visit: visit)
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[aMoved.transferID]?.state == .downloading }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        if visit == .sweepFollowsFirst {
            let afterFailure = await engine.readForTests { e in (owed: e.followOwed, n: e.state.jobs[aMoved.transferID]?.state) }
            #expect(afterFailure.owed && afterFailure.n == nil, "setup: C's 429 arrived while the follow owes the visit that creates N: \(afterFailure)")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            // The clock has not moved since the 429: the origin is still throttled, and N must not start under it.
            let atEnd = await engine.readForTests { e in
                (throttled: e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil, n: e.state.jobs[aMoved.transferID]?.state)
            }
            let nStarted = await s.harness.source.starts.contains { $0.id == aMoved.transferID }
            #expect(atEnd.throttled && !nStarted, "no request goes to the throttled origin for N (R-SYN-5): \(atEnd)")
        }
        await s.harness.source.release(aMoved.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        if visit == .followVisitedFirst {
            #expect((try? aResult.get())?.byteSize == 16, "A, moved to N, is served from N, which started before the 429: \(aResult)")
        } else if case .failure(.serverUnavailable) = aResult {
        } else {
            Issue.record("A, moved to N after the 429, gets the live throttle's answer (R-SYN-5): \(aResult)")
        }
        if case .failure(.serverUnavailable) = bResult {
        } else {
            Issue.record("B gets the throttle's answer: \(bResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// The new content a follow's visit queues is gated on the live throttle: T (1 MB, zz-t) downloads for a prefetch
    /// member; D (1 MB, content W) downloads for U's user waiter and a prefetch member (zz-u). Between v3's fetch and its
    /// apply, T gets a 429 with Retry-After 10 s; v3 moves zz-u to N (16 bytes). Then 11 s pass, so the throttle ends.
    /// Visited first, D's visit created N at the apply under the 10 s throttle: N parked and U was answered
    /// `serverUnavailable(10)`; the throttle's alarm then re-admitted N for the member. Visited after the throttle's end,
    /// N's place is admitted on the live gates, which no throttle holds any more: N starts and U is served from it, the
    /// answer a live origin gate that changed during the barrier gives (ruling S3-R18 item 1, S3-R17 item 2; recorded as a
    /// residual risk). Cycles 12 to 14 refused N on its place's stamp, the throttle of the apply's view (the cycle-11
    /// residual R-D); the stamps are gone since Stage 3 close-out cycle 15 (PROBE-C14C-STAMP-AHEAD). No request goes to the
    /// origin while its throttle is live in either order (R-SYN-5).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: the new content an owed follow's visit queues is gated on the live throttle, the apply's when visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 999_102)
        let engine = s.engine
        let tBytes = Data(repeating: 0xD1, count: 1_000_000)
        let wBytes = Data(repeating: 0xD2, count: 1_000_000)
        let nBytes = EngineFixture.bytes(999_104, count: 16)
        let t = EngineHarness.onDemand("zz-t", tBytes)
        let u = EngineHarness.onDemand("zz-u", wBytes)
        let uMoved = EngineHarness.onDemand("zz-u", nBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(760_500) + [t, u], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(t.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(10))), .stage(tBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(wBytes)])
        await s.harness.source.script(uMoved.transferID, [.stage(nBytes)])
        let group = try await engine.registerGroup([t.identifier, u.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[t.transferID]?.state == .downloading }
        }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        await engine.readForTests { e in
            e.holdFollowFollowUps()
            e.holdManifestOutcomeDelivery()
        }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(860_500) + [t, uMoved], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.manifestOutcomeHeld }
        await s.harness.source.release(t.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[t.transferID]?.state.isThrottleParked == true }
        await engine.readForTests { $0.releaseManifestOutcomeDelivery() }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        } else {
            let before = await engine.readForTests { e in (owed: e.followOwed, d: e.state.jobs[u.transferID]?.state, n: e.state.jobs[uMoved.transferID]?.state) }
            #expect(before.owed && before.d == .downloading && before.n == nil, "setup: D downloads and its visit is owed: \(before)")
        }
        // The throttle ends (its alarm's turn).
        s.time.advance(by: 11)
        await engine.awaitCondition { e in e.state.remote.map { e.state.throttles[$0.originID] == nil } ?? false }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        if visit == .followVisitedFirst {
            if case .failure(.serverUnavailable(let retryAfter?)) = uResult {
                #expect(abs(retryAfter - 10) < 0.5, "U, moved to N under the 10 s throttle at the apply, gets its fail-fast answer (visit-first): \(uResult)")
            } else {
                Issue.record("U gets the throttle's fail-fast answer of the apply's instant (visit-first serverUnavailable(10)): \(uResult)")
            }
        } else {
            // S3-R18 item 1 (an exception like S3-R17 item 3): N's place is admitted on the live gates, and the throttle
            // ended during the barrier.
            #expect((try? uResult.get())?.byteSize == 16, "U is served N, admitted once the live throttle had ended: \(uResult)")
        }
        // N is served for the group's member: re-admitted by the throttle's alarm visited first, started at the
        // barrier-end pump otherwise.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[t.transferID] == nil && $0.state.jobs[uMoved.transferID] == nil }
        }
        let nStarted = await s.harness.source.starts.contains { $0.id == uMoved.transferID }
        #expect(nStarted, "N starts for the group's member zz-u once the apply's throttle ended")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A request's job that waits for the follow starts only while the breaker admits it (R-SYN-5): X (100 kB, zz-x)
    /// downloads for a user waiter, and one 403 opens the breaker. While the follow owes its visits, U requests zz-u, then
    /// X's 403 opens the breaker. Visited first, U's job started at the request and U was served. Behind the barrier U's
    /// job is placed by the drain, after the 403: its start would be a request to an origin whose breaker is open, which
    /// R-SYN-5 forbids, so it parks on the live breaker and U is answered `authRejected`. Cycle 12 admitted it on the
    /// breaker of U's arrival (`placeStamps`) and served U; ruling S3-R16 items 1(b) and 3 make admission read the live
    /// gates (recorded in the WP-F draft, cycle 13, with the old assertions).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a request during an owed follow starts only while the live breaker admits it (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAdmitsARequestOnTheBreakerAtItsArrival(_ visit: LaneDropVisit) async throws {
        let tuning = SyncTuning(breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let (s, _) = try await FollowBarrier.setUp(seed: 999_202, tuning: tuning)
        let engine = s.engine
        let origin = s.harness.source.originID
        let xBytes = Data(repeating: 0xD3, count: 100_000)
        let uBytes = Data(repeating: 0xD4, count: 100_000)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let u = EngineHarness.onDemand("zz-u", uBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(761_000) + [u, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(x.transferID, [.hold, .fail(EngineRegressionCycle20Tests.forbidden)])
        await s.harness.source.script(u.transferID, [.hold, .stage(uBytes)])
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[x.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(861_000) + [u, x], s, visit: visit)
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        } else {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, u) }
        }
        await s.harness.source.release(x.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            if case .open? = e.state.breakers[origin]?.state {
                return true
            }
            return false
        }
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { $0.followOwed }
            #expect(owed, "setup: X's 403 opened the breaker while the follow is owed")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uState = await engine.readForTests { $0.state.jobs[u.transferID]?.state }
        let uStarted = await s.harness.source.starts.contains { $0.id == u.transferID }
        if visit == .followVisitedFirst {
            #expect(uState == .downloading, "U's job, requested before the breaker opened, runs: \(String(describing: uState))")
        } else {
            #expect(!uStarted && uState != .downloading, "no request goes to the origin while its breaker is open (R-SYN-5): \(String(describing: uState))")
        }
        await s.harness.source.release(u.transferID, with: .progress(received: 0, expected: nil))
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        if visit == .followVisitedFirst {
            #expect((try? uResult.get())?.byteSize == Int64(uBytes.count), "U is served: \(uResult)")
        } else if case .failure(.authRejected) = uResult {
        } else {
            Issue.record("U, placed after the breaker opened, gets the open breaker's answer (R-SYN-5): \(uResult)")
        }
        #expect((try? xResult.get()) == nil, "X's 403 fails it: \(xResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: Publication outcomes (S3-R15 item 3, residual R-A)

    /// A commit that arrives while the follow owes the visit of its job's moved id leaves that id's re-route to the
    /// visit, at the follow's place: two slots. C (1 MB, content X) downloads for A's user waiter (zz-a) and B's (zz-b);
    /// H (100 kB) holds the other slot for a user waiter. v3 moves zz-a to N (16 bytes) while the follow owes C's visit.
    /// W's user request (zz-w) then arrives, and C's bytes complete. Visited first, C's visit re-routed A to a new job N
    /// at the apply, queued ahead of W; C's commit freed a slot and N started before W. Re-routed by the commit, A's join
    /// waited behind W's, so W took the freed slot (PROBE-C11-COMMIT-PLACE). Which of N and W starts first is a recorded
    /// order difference since Stage 3 close-out cycle 13 (ruling S3-R16 items 2 to 4, which removed the commit's
    /// deferral): the test asserts the answers and that both start.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a commit during an owed follow leaves its moved id's re-route to the follow's visit and place (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPlacesACommitsMovedIDAtTheFollowsPlace(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 991_402, tuning: SyncTuning(maxConcurrentTransfers: 2, preemptLowerLanes: false))
        let engine = s.engine
        let xBytes = Data(repeating: 0xB5, count: 1_000_000)
        let hBytes = Data(repeating: 0xB6, count: 100_000)
        let wBytes = Data(repeating: 0xB7, count: 100_000)
        let nBytes = EngineFixture.bytes(991_404, count: 16)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let w = EngineHarness.onDemand("zz-w", wBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(770_000) + [a, b, h, w], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(xBytes)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(w.transferID, [.stage(wBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[h.transferID]?.state == .downloading }
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(870_000) + [aMoved, b, h, w], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, interests: e.state.jobs[a.transferID]?.interests.count) }
            #expect(before.owed && before.c == .downloading && before.interests == 2, "setup: C runs for A and B and its visit is owed: \(before)")
        }
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, w) }
        } else {
            await engine.awaitCondition { $0.state.jobs[w.transferID]?.state == .queued }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        // C's publication's outcome has arrived: its job committed and left.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                let c = e.state.jobs[a.transferID]?.state
                return c != .downloading && c != .verifying
            }
        }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { e in !e.followBarrier && !e.state.drainFollowUpScheduled && (e.state.jobs[aMoved.transferID]?.state != .queued || e.state.jobs[w.transferID]?.state != .queued) }
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        let starts = await s.harness.source.starts.map(\.id)
        let nIndex = starts.firstIndex(of: aMoved.transferID)
        let wIndex = starts.firstIndex(of: w.transferID)
        #expect((try? aResult.get())?.byteSize == 16, "A is served from N: \(aResult)")
        #expect((try? bResult.get())?.byteSize == Int64(xBytes.count), "B is served from X: \(bResult)")
        #expect((try? wResult.get())?.byteSize == Int64(wBytes.count), "W is served: \(wResult)")
        #expect(nIndex != nil && wIndex != nil, "N, created for A's moved id, and W both start (their order is a recorded residual risk, S3-R16 item 2): n=\(String(describing: nIndex)) w=\(String(describing: wIndex))")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// The slot a commit frees while the follow owes the visit of its job's moved id goes to the job that visit
    /// creates: two slots. C (100 kB, content X) downloads for A's user waiter (zz-a) and B's (zz-b); H downloads for a
    /// third user waiter. v3 moves zz-a to N (16 bytes) while the follow owes C's visit. R (zz-r) is then requested for
    /// user work, and C completes. Visited first, C's visit re-routed A to N before R's request, so N took its queue
    /// place first and took the slot C's commit freed; R waited. Re-routed by the commit, A's join waited behind R's,
    /// and R took the slot (PROBE-C11R-COMMIT-REROUTE). Which of N and R takes the slot is a recorded order difference
    /// since Stage 3 close-out cycle 13 (ruling S3-R16 items 2 to 4, which removed the commit's deferral): the test
    /// asserts that one takes it while the other waits, then the answers.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: the slot a commit frees during an owed follow goes to the job the follow's visit of its moved id creates (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesACommitsSlotToTheFollowsReroute(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 997_202, tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let engine = s.engine
        let xBytes = Data(repeating: 0xC3, count: 100_000)
        let hBytes = Data(repeating: 0xC4, count: 100_000)
        let rBytes = Data(repeating: 0xC5, count: 100_000)
        let nBytes = EngineFixture.bytes(997_204, count: 16)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(742_000) + [a, b, h, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(a.transferID, [.hold, .stage(xBytes)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(r.transferID, [.hold, .stage(rBytes)])
        await s.harness.source.script(aMoved.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[h.transferID]?.state == .downloading }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(842_000) + [aMoved, b, h, r], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, n: e.state.jobs[aMoved.transferID]?.state) }
            #expect(before.owed && before.c == .downloading && before.n == nil, "setup: C runs and its visit is owed: \(before)")
        }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[r.transferID] != nil || FollowBarrier.joinWaits($0, r) }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        // C's publication's outcome has arrived: its job committed and left.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                let c = e.state.jobs[a.transferID]?.state
                return c != .downloading && c != .verifying
            }
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { e in (n: e.state.jobs[aMoved.transferID]?.state, r: e.state.jobs[r.transferID]?.state) }
        #expect((after.n == .downloading && after.r == .queued) || (after.r == .downloading && after.n == .queued), "one of N and R takes the slot C's commit frees and the other waits (which one is a recorded residual risk, S3-R16 item 2): \(after)")
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(xBytes.count), "B is served from X: \(bResult)")
        let first = after.n == .downloading ? aMoved.transferID : r.transferID
        let other = first == r.transferID ? aMoved.transferID : r.transferID
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await s.harness.source.release(first, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[other]?.state == .downloading }
        }
        await s.harness.source.release(other, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A is served from N: \(aResult)")
        #expect((try? rResult.get())?.byteSize == Int64(rBytes.count), "R is served: \(rResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
