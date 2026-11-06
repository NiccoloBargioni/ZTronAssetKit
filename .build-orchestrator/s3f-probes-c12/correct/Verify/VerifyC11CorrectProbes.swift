import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 11, correctness lens). Never committed.
///
/// Each runs in both orders (`LaneDropVisit`): `.followVisitedFirst` lets the held follow end before the inputs under
/// test; `.sweepFollowsFirst` delivers them while the follow still owes its visits (the barrier holds). Every
/// expectation is the visit-first outcome (S3-R11 item 3).
@Suite("VerifyC11CorrectProbes", .serialized)
struct VerifyC11CorrectProbes {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// PROBE-C11-JOIN-THROTTLE-EXT: T (1 MB, zz-t) runs for a prefetch waiter P; E (1 MB, zz-e) runs for a user waiter.
    /// Between v3's fetch and its apply, T gets a 429 with Retry-After 2 s (T throttle-parked, nobody answered). Then U's
    /// user request for zz-t arrives (at t1); 1.5 s later E gets a 429 with Retry-After 300 s (t2). Visit-first: U joins
    /// T at t1, its fail-fast wait is 2 s (within the user bound: no answer); at t2 the extension's fail-fast turn
    /// answers U with 300 s. Behind the barrier, U's join waits; the drain replays it at t1's instant but reads the
    /// origin's end that E's later 429 set, so U is answered with 301.5 s.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C11-JOIN-THROTTLE-EXT", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func joinThrottleExtended(_ visit: LaneDropVisit) async throws {
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
        let parked = await engine.readForTests { e -> Double? in
            guard let origin = e.state.remote?.originID else { return nil }
            return e.state.throttles[origin]?.seconds(since: e.environment.time.monotonicNow())
        }
        print("PROBE-C11-JOIN-THROTTLE-EXT \(visit) parked: throttle left \(String(describing: parked))")
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
        let joined = await engine.readForTests { e in (owed: e.followOwed, barrier: e.followBarrier, t: e.state.jobs[t.transferID]?.state, interests: e.state.jobs[t.transferID]?.interests.count) }
        print("PROBE-C11-JOIN-THROTTLE-EXT \(visit) joined: \(joined)")
        s.time.advance(by: 1.5)
        await s.harness.source.release(ex.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[ex.transferID]?.state != .downloading }
        await engine.awaitCondition { !$0.state.throttleAnswersScheduled }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled && !$0.state.throttleAnswersScheduled }
        let uResult = await EngineHarness.value(of: uWaiter)
        print("PROBE-C11-JOIN-THROTTLE-EXT \(visit) U: \(uResult)")
        if case .failure(.serverUnavailable(let retryAfter?)) = uResult {
            #expect(abs(retryAfter - 300) < 0.5, "U gets the extension's answer at E's 429 (visit-first 300 s): \(uResult)")
        } else {
            Issue.record("U gets the throttle's answer: \(uResult)")
        }
        let eResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: eWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C11-JOIN-THROTTLE-EXT \(visit) results: e=\(eResult) p=\(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C11-JOIN-THROTTLE-END: T (1 MB, zz-t) runs for a prefetch waiter P. Between v3's fetch and its apply, T gets
    /// a 429 with Retry-After 10 s (T throttle-parked, nobody answered). U's user request for zz-t arrives at t1; then 11 s
    /// pass, so the throttle ends. Visit-first: U joins T at t1 under a 10 s throttle, beyond the user bound, so U's
    /// fail-fast answers it `serverUnavailable(10)`. Behind the barrier, U's join waits; the throttle's end clears the
    /// origin's throttle on arrival (`endThrottle`), and the drain replays U's join at t1's instant against no throttle:
    /// the gate admits, T is re-admitted and U is served.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C11-JOIN-THROTTLE-END", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func joinThrottleEnd(_ visit: LaneDropVisit) async throws {
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
        let joined = await engine.readForTests { e in (t: e.state.jobs[t.transferID]?.state, interests: e.state.jobs[t.transferID]?.interests.count, waiters: e.state.waiters.count) }
        print("PROBE-C11-JOIN-THROTTLE-END \(visit) joined: \(joined)")
        s.time.advance(by: 11)
        await engine.awaitCondition { e in e.state.remote.map { e.state.throttles[$0.originID] == nil } ?? false }
        let mid = await engine.readForTests { e in (owed: e.followOwed, barrier: e.followBarrier, t: e.state.jobs[t.transferID]?.state, events: e.state.eventsAfterFollow.count) }
        print("PROBE-C11-JOIN-THROTTLE-END \(visit) after the throttle's end: \(mid)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        print("PROBE-C11-JOIN-THROTTLE-END \(visit) U: \(uResult)")
        if case .failure(.serverUnavailable(let retryAfter?)) = uResult {
            #expect(abs(retryAfter - 10) < 0.5, "U's fail-fast reads the 10 s throttle in force at its request (visit-first): \(uResult)")
        } else {
            Issue.record("U gets the throttle's fail-fast answer at its request (visit-first serverUnavailable(10)): \(uResult)")
        }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let starts = await s.harness.source.starts.filter { $0.id == t.transferID }.count
        print("PROBE-C11-JOIN-THROTTLE-END \(visit) results: p=\(pResult) tStarts=\(starts)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C11-MANIFEST-THROTTLE: C (1 MB) is the content of zz-a (M, a user waiter) and zz-b (P, a prefetch waiter);
    /// v3 moves zz-a while the follow owes C's visit. C gets a 429 without Retry-After; then a user asks for an id no
    /// manifest lists (zz-none), which needs a manifest fetch. Visit-first, the 429 throttled the origin on arrival for
    /// the backoff of C's followed lane, so the fetch is refused without a request and the caller gets the throttle's
    /// answer. Behind the barrier the backoff throttle waits for the drain (`replayThrottle`), so the origin is not
    /// throttled when the fetch's turn reads it: the fetch goes to the origin and the caller is answered `.notFound`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C11-MANIFEST-THROTTLE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func manifestThrottle(_ visit: LaneDropVisit) async throws {
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
        let mid = await engine.readForTests { e -> (barrier: Bool, throttle: Double?) in
            let origin = e.state.remote?.originID
            return (e.followBarrier, origin.flatMap { e.state.throttles[$0] }?.seconds(since: e.environment.time.monotonicNow()))
        }
        print("PROBE-C11-MANIFEST-THROTTLE \(visit) after 429: \(mid)")
        let requestsBefore = await s.harness.source.manifestRequests.count
        let unknown = await engine.awaitAsset("zz-none", lane: .userInitiated)
        let requestsAfter = await s.harness.source.manifestRequests.count
        print("PROBE-C11-MANIFEST-THROTTLE \(visit) unknown: \(unknown) manifestRequests \(requestsBefore) -> \(requestsAfter)")
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
        print("PROBE-C11-MANIFEST-THROTTLE \(visit) results: m=\(mResult) p=\(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C11-COMMIT-PLACE (the draft's open residual R-A): two slots. C (1 MB, content X) downloads for A's user
    /// waiter (zz-a) and B's (zz-b); H (100 kB) holds the other slot for a user waiter. v3 moves zz-a to N (16 bytes)
    /// while the follow owes C's visit. W's user request (zz-w) then arrives, and C's bytes complete. Visit-first: C's
    /// visit re-routed A to a new job N at the apply, queued ahead of W; C's commit freed a slot and N started before W.
    /// Behind the barrier: W's join waits; C commits while its visit is owed, the commit re-routes A (its join waits,
    /// arriving after W's), so the drain places W ahead of N and W takes the freed slot.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C11-COMMIT-PLACE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitPlace(_ visit: LaneDropVisit) async throws {
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
            print("PROBE-C11-COMMIT-PLACE \(visit) before: \(before)")
            #expect(before.owed && before.c == .downloading && before.interests == 2, "setup: C runs for A and B and its visit is owed: \(before)")
        }
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, w) }
        } else {
            await engine.awaitCondition { $0.state.jobs[w.transferID]?.state == .queued }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        // C12 verifier wait adaptation: since 2e22cf6 C's commit waits for C's owed visit (`.committed`), so B is answered
        // only after the follow's release; sweep-first waits for the deferred commit instead.
        if visit == .sweepFollowsFirst {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { e in e.state.eventsAfterFollow.contains { if case .committed = $0 { return true }; return false } }
            }
        } else {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        }
        let mid = await engine.readForTests { e in (owed: e.followOwed, barrier: e.followBarrier, c: e.state.jobs[a.transferID]?.state, n: e.state.jobs[aMoved.transferID]?.state, nTicket: e.state.jobs[aMoved.transferID]?.ticket, wTicket: e.state.jobs[w.transferID]?.ticket, events: e.state.eventsAfterFollow.count) }
        print("PROBE-C11-COMMIT-PLACE \(visit) after C's commit: \(mid)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { e in !e.followBarrier && !e.state.drainFollowUpScheduled && (e.state.jobs[aMoved.transferID]?.state != .queued || e.state.jobs[w.transferID]?.state != .queued) }
        let after = await engine.readForTests { e in (n: e.state.jobs[aMoved.transferID].map { ($0.state, $0.ticket) }, w: e.state.jobs[w.transferID].map { ($0.state, $0.ticket) }) }
        print("PROBE-C11-COMMIT-PLACE \(visit) after the drain: \(after)")
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        let starts = await s.harness.source.starts.map(\.id)
        let nIndex = starts.firstIndex(of: aMoved.transferID)
        let wIndex = starts.firstIndex(of: w.transferID)
        print("PROBE-C11-COMMIT-PLACE \(visit) results: a=\(aResult) w=\(wResult) nIndex=\(String(describing: nIndex)) wIndex=\(String(describing: wIndex))")
        #expect((try? aResult.get())?.byteSize == 16, "A is served from N: \(aResult)")
        #expect(nIndex != nil && wIndex != nil && nIndex! < wIndex!, "N, queued by C's visit at the apply, starts before W (visit-first): n=\(String(describing: nIndex)) w=\(String(describing: wIndex))")
        await FollowBarrier.finish(s, sync: sync)
    }
}
