import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 10, correctness lens). Never committed.
///
/// Each runs in both orders (`LaneDropVisit`): `.followVisitedFirst` lets the held follow end before the event under
/// test; `.sweepFollowsFirst` delivers the event while the follow still owes the visit of the job the event concerns.
/// Every expectation is the visit-first outcome (S3-R11 item 3).
@Suite("VerifyC10CorrectProbes", .serialized)
struct VerifyC10CorrectProbes {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// PROBE-C10-THROTTLE-EXTENDED: C (1 MB) is the content of zz-a and zz-b, one user waiter each (A, B); N (16 B,
    /// zz-n, held) and D (1 MB, zz-d, held) run for user waiters. v3 moves zz-a onto N's content. C gets a 429 with
    /// Retry-After 60 s, then D a 429 with Retry-After 300 s. Visited first, C's park answers B with the 60 s wait C's
    /// 429 gave. With C's park deferred, the drain's fail-fast reads the origin's end (300 s, from D's later 429) at C's
    /// 429 instant.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C10-THROTTLE-EXTENDED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func throttleExtended(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 990_102)
        let engine = s.engine
        let cBytes = Data(repeating: 0xA5, count: 1_000_000)
        let dBytes = Data(repeating: 0xA6, count: 1_000_000)
        let nBytes = EngineFixture.bytes(990_104, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        let n = EngineHarness.onDemand("zz-n", nBytes)
        try #require(a.transferID == b.transferID)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(790_000) + [a, b, d, n], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(d.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(300))), .stage(dBytes)])
        await s.harness.source.script(n.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let wWaiter = Task { await engine.awaitAsset(n.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[n.transferID]?.state == .downloading }
        let dWaiter = Task { await engine.awaitAsset(d.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[d.transferID]?.state == .downloading }
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        try #require(aMoved.transferID == n.transferID)
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(890_000) + [aMoved, b, d, n], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: \(before)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        await s.harness.source.release(d.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[d.transferID]?.state != .downloading }
        let mid = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, d: e.state.jobs[d.transferID]?.state, waits: e.state.verdictsAfterFollow[a.transferID] != nil)
        }
        print("PROBE-C10-THROTTLE-EXTENDED \(visit) mid: \(mid)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier }
        let alarm = await engine.readForTests { e -> (deadline: Double?, origin: Double?) in
            guard let origin = e.state.remote?.originID else {
                return (nil, nil)
            }
            let now = e.environment.time.monotonicNow()
            return (e.state.heap.deadline(for: .throttle(origin))?.seconds(since: now), e.state.throttles[origin]?.seconds(since: now))
        }
        print("PROBE-C10-THROTTLE-EXTENDED \(visit) alarm: \(alarm)")
        await s.harness.source.release(n.transferID, with: .progress(received: 0, expected: nil))
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let dResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: dWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        print("PROBE-C10-THROTTLE-EXTENDED \(visit) results: a=\(aResult) b=\(bResult) d=\(dResult) w=\(wResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A served from N: \(aResult)")
        if case .failure(.serverUnavailable(let retryAfter?)) = bResult {
            #expect(abs(retryAfter - 60) < 1, "B, answered by C's park, gets the wait C's 429 gave (visit-first 60 s): \(bResult)")
        } else {
            Issue.record("B gets the throttle's answer: \(bResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C10-JOIN-RETIRE: C (1 MB) is the content of zz-a (M, a user waiter) and zz-b (P, a prefetch waiter); v3
    /// moves zz-a to a 16-byte content while the follow owes C's visit. C's attempt fails with a 500 (a retry), then a
    /// prefetch request J for zz-b arrives, then P withdraws. Visited first, C backs off (`failed(.at)`, one attempt
    /// counted), J joins it and keeps it after P leaves, and no second attempt starts before the backoff ends. With J's
    /// join waiting behind C's verdict, the visit that moves M leaves C without an interest, so C is retired; the drain
    /// creates a fresh job for J (no attempt counted, no backoff), which starts at once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C10-JOIN-RETIRE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func joinRetire(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 990_202)
        let engine = s.engine
        let cBytes = Data(repeating: 0xA7, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(791_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(cBytes)])
        let mWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.interests.count == 2 }
        }
        let nBytes = EngineFixture.bytes(990_204, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(891_000) + [aMoved, b], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: \(before)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let afterFailure = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID].map { ($0.state, $0.attempts, $0.lane, $0.interests.count) }, waits: e.state.verdictsAfterFollow[a.transferID] != nil)
        }
        print("PROBE-C10-JOIN-RETIRE \(visit) afterFailure: \(afterFailure)")
        let jWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.waiters.values.filter { $0.asset == b.identifier }.count == 2 }
        pWaiter.cancel()
        _ = await pWaiter.value
        // Cycle-11 wait adaptation (waits only): behind the barrier a withdrawn waiter's record stays, without its
        // continuation, until the drain applies the removal (`withdraw`, S3-R14 item 3).
        await engine.awaitCondition { $0.state.waiters.values.filter { $0.asset == b.identifier && $0.continuation != nil }.count == 1 }
        let mid = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID].map { ($0.state, $0.interests.count) }, joins: e.state.joinsAfterFollow.count, violations: e.invariantViolations())
        }
        print("PROBE-C10-JOIN-RETIRE \(visit) mid: \(mid)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        // No clock movement from here to the check: only the follow's turns, the drain and the pumps run.
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await engine.awaitCondition { e in e.state.jobs[a.transferID].map { $0.state != .queued } ?? true }
        let after = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID].map { ($0.state, $0.attempts, $0.epoch, $0.interests.count) }, violations: e.invariantViolations())
        }
        let cStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        print("PROBE-C10-JOIN-RETIRE \(visit) after: \(after) starts: \(cStarts)")
        if case .failed(.at)? = after.c?.0 {
        } else {
            Issue.record("C keeps its backoff with J's interest (visit-first failed(.at), 1 attempt): \(after), starts \(cStarts)")
        }
        #expect(after.c?.1 == 1, "the failed attempt stays counted (visit-first): \(after)")
        #expect(cStarts == 1, "no second attempt before the backoff ends (visit-first): \(cStarts)")
        let mResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: mWaiter) }
        let jResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: jWaiter) }
        print("PROBE-C10-JOIN-RETIRE \(visit) results: m=\(mResult) j=\(jResult)")
        #expect((try? mResult.get())?.byteSize == 16, "M served from its new content: \(mResult)")
        #expect((try? jResult.get())?.byteSize == Int64(cBytes.count), "J served by C: \(jResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C10-PAUSE-LANE (the draft's residual "a policy pause reads the job's pre-visit lane"): N (1 MB, zz-n) runs
    /// for a prefetch waiter; C (1 MB, zz-a) runs for a user waiter A. v3 moves zz-a onto N's content while the follow
    /// owes C's visit. Then the network turns constrained (Low Data Mode: prefetch refused, user work admitted). Visited
    /// first, A's interest raised N to the user lane, so N keeps running. Before the visit, N is prefetch-lane and is
    /// paused.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C10-PAUSE-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func pauseLane(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 990_302)
        let engine = s.engine
        let cBytes = Data(repeating: 0xA8, count: 1_000_000)
        let nBytes = Data(repeating: 0xA9, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let n = EngineHarness.onDemand("zz-n", nBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(792_000) + [a, n], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(n.transferID, [.hold, .stage(nBytes)])
        let nWaiter = Task { await engine.awaitAsset(n.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[n.transferID]?.state == .downloading }
        }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        try #require(aMoved.transferID == n.transferID)
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(892_000) + [aMoved, n], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, n: e.state.jobs[n.transferID]?.lane) }
            #expect(before.owed && before.c == .downloading && before.n == .prefetch, "setup: \(before)")
        }
        await s.harness.conditions.send(EngineRegressionCycle10Tests.constrained)
        await engine.awaitCondition { $0.state.conditions == EngineRegressionCycle10Tests.constrained }
        let decision = await engine.readForTests { e in
            (state: e.state.jobs[n.transferID]?.state, lane: e.state.jobs[n.transferID]?.lane, pause: e.state.jobs[n.transferID]?.active?.policyPause)
        }
        print("PROBE-C10-PAUSE-LANE \(visit) decision: \(decision)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let nStarts = await s.harness.source.starts.filter { $0.id == n.transferID }.count
        let held = await engine.readForTests { e in e.state.jobs[n.transferID]?.state == .downloading && e.state.jobs[n.transferID]?.active?.policyPause == nil }
        if nStarts == 1, held {
            await s.harness.source.release(n.transferID, with: .progress(received: 0, expected: nil))
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let nResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: nWaiter) }
        let starts = await s.harness.source.starts.filter { $0.id == n.transferID }.count
        print("PROBE-C10-PAUSE-LANE \(visit) results: a=\(aResult) n=\(nResult) starts=\(starts)")
        #expect(decision.pause == nil && decision.state == .downloading, "N, user-lane once the follow moved A onto it, keeps running under Low Data Mode (visit-first): \(decision)")
        #expect(starts == 1, "N's first attempt serves both (visit-first): \(starts)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C10-THROTTLE-LANE (the draft's residual "the throttle's delay without a Retry-After reads the job's
    /// pre-visit lane"): C (1 MB) is the content of zz-a (M, user) and zz-b (P, prefetch); v3 moves zz-a while the follow
    /// owes C's visit. C gets a 429 without Retry-After. Visited first, C is prefetch-lane, so the origin's throttle is
    /// the background policy's first backoff; before the visit it is the interactive policy's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C10-THROTTLE-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func throttleLane(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 990_402)
        let engine = s.engine
        let cBytes = Data(repeating: 0xAA, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(793_000) + [a, b], etag: "v2")
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
        let nBytes = EngineFixture.bytes(990_404, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(893_000) + [aMoved, b], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, lane: e.state.jobs[a.transferID]?.lane) }
            #expect(before.owed && before.c == .downloading && before.lane == .userInitiated, "setup: \(before)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let figures = await engine.readForTests { e -> (throttle: Double?, background: Double?, interactive: Double?) in
            guard let origin = e.state.remote?.originID else {
                return (nil, nil, nil)
            }
            let now = e.environment.time.monotonicNow()
            let key = StableHash.fnv1a64(origin)
            return (
                e.state.throttles[origin]?.seconds(since: now),
                Backoff.delay(attempt: 1, retryAfter: nil, policy: e.tuning.retry, seed: e.environment.random.seed, key: key),
                Backoff.delay(attempt: 1, retryAfter: nil, policy: e.tuning.interactiveRetry, seed: e.environment.random.seed, key: key)
            )
        }
        print("PROBE-C10-THROTTLE-LANE \(visit) figures: \(figures)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let mResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: mWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C10-THROTTLE-LANE \(visit) results: m=\(mResult) p=\(pResult)")
        if let throttle = figures.throttle, let background = figures.background {
            #expect(abs(throttle - background) < 0.000_001, "the origin's throttle is C's prefetch-lane backoff (visit-first): \(figures)")
        } else {
            Issue.record("no throttle figures: \(figures)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }
    /// PROBE-C10-DOUBLE-PLACE (the draft's residual "a follow visit that re-lanes a queued job whose place still waits
    /// gives it a place in the visit and again at the drain"): two transfer slots; H (zz-h, user, held) runs; under Low
    /// Data Mode P (zz-p) is parked by policy for a prefetch waiter; C (zz-a) runs for user waiter A; B (zz-b) is queued
    /// for user waiter W. v3 moves zz-a onto P's content and zz-b onto a new content X. Visited first, the visit of C
    /// re-lanes P to user work and queues it, then the visit of B creates X behind it: P starts before X. With the network
    /// turning unrestricted while the visits are owed, `readmit` re-queues P behind the barrier (its place waits); the
    /// visit then places P, then X, and the drain places P again, behind X.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C10-DOUBLE-PLACE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func doublePlace(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 990_502, tuning: SyncTuning(maxConcurrentTransfers: 2))
        let engine = s.engine
        let pBytes = Data(repeating: 0xB1, count: 100_000)
        let hBytes = Data(repeating: 0xB2, count: 100_000)
        let caBytes = Data(repeating: 0xB3, count: 100_000)
        let cbBytes = Data(repeating: 0xB4, count: 100_000)
        let xBytes = Data(repeating: 0xB5, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", caBytes)
        let b = EngineHarness.onDemand("zz-b", cbBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(794_000) + [a, b, h, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(a.transferID, [.hold])
        await s.harness.source.script(b.transferID, [.hold])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        await s.harness.conditions.send(EngineRegressionCycle10Tests.constrained)
        await engine.awaitCondition { $0.state.conditions == EngineRegressionCycle10Tests.constrained }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { if case .blocked(.policy)? = $0.state.jobs[p.transferID]?.state { return true } else { return false } }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let wWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state == .queued }
        let aMoved = EngineHarness.onDemand("zz-a", pBytes)
        let bMoved = EngineHarness.onDemand("zz-b", xBytes)
        try #require(aMoved.transferID == p.transferID)
        await s.harness.source.script(bMoved.transferID, [.stage(xBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(894_000) + [aMoved, bMoved, h, p], s, visit: visit)
        let before = await engine.readForTests { e in (owed: e.followOwed, p: e.state.jobs[p.transferID]?.state, c: e.state.jobs[a.transferID]?.state, b: e.state.jobs[b.transferID]?.state) }
        print("PROBE-C10-DOUBLE-PLACE \(visit) before: \(before)")
        await s.harness.conditions.send(DeviceConditions.unrestricted)
        await engine.awaitCondition { $0.state.conditions == DeviceConditions.unrestricted }
        let mid = await engine.readForTests { e in (p: e.state.jobs[p.transferID]?.state, places: e.state.eventsAfterFollow.count) }
        print("PROBE-C10-DOUBLE-PLACE \(visit) mid: \(mid)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let starts = await s.harness.source.starts.map(\.id)
        let pIndex = starts.firstIndex(of: p.transferID)
        let xIndex = starts.firstIndex(of: bMoved.transferID)
        print("PROBE-C10-DOUBLE-PLACE \(visit) results: a=\(aResult) w=\(wResult) p=\(pResult) pIndex=\(String(describing: pIndex)) xIndex=\(String(describing: xIndex))")
        #expect(pIndex != nil && xIndex != nil && pIndex! < xIndex!, "P, queued by the visit of C before X, starts first (visit-first): p=\(String(describing: pIndex)) x=\(String(describing: xIndex))")
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        await FollowBarrier.finish(s, sync: sync)
    }
    /// PROBE-C10-EDGE-ORDER (the draft's residual "the `.edge` events are appended before the deferred re-admissions of
    /// the same edge, whatever their ranks"): one transfer slot. F (zz-f, a prefetch member) failed offline earlier and
    /// waits for an edge (`failed(.whenOnline)`); C (zz-a, zz-b) runs for a prefetch member of zz-b, with a user waiter A
    /// of zz-a; v3 moves zz-a. C fails offline (no edge during its attempt), then the path drops and returns. Visited
    /// first, the edge re-admits F and C in the pump's order (same lane, F's earlier ticket): F's retry starts before C's.
    /// With C's verdict waiting, the edge's `.edge(C)` is appended before `readmit`'s place for F, so C's retry starts
    /// first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C10-EDGE-ORDER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func edgeOrder(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 990_602, tuning: SyncTuning(maxConcurrentTransfers: 1))
        let engine = s.engine
        let cBytes = Data(repeating: 0xC7, count: 100_000)
        let fBytes = Data(repeating: 0xC8, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let f = EngineHarness.onDemand("zz-f", fBytes)
        try #require(a.transferID == b.transferID)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(795_000) + [a, b, f], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(f.transferID, [.hold, .fail(.offline(.noConnection)), .stage(fBytes)])
        await s.harness.source.script(a.transferID, [.hold, .fail(.offline(.noConnection)), .stage(cBytes)])
        let fGroup = try await engine.registerGroup([f.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[f.transferID]?.state == .downloading }
        }
        let cGroup = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        await s.harness.source.release(f.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[f.transferID]?.state == .failed(.whenOnline) && $0.state.jobs[a.transferID]?.state == .downloading }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let tickets = await engine.readForTests { e in (f: e.state.jobs[f.transferID]?.ticket, c: e.state.jobs[a.transferID]?.ticket, serial: e.state.jobs[a.transferID]?.active?.edgeSerial == e.state.networkEdgeSerial) }
        print("PROBE-C10-EDGE-ORDER \(visit) tickets: \(tickets)")
        let nBytes = EngineFixture.bytes(990_604, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(895_000) + [aMoved, b, f], s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        for conditions in [EngineRegressionCycle10Tests.offline, DeviceConditions.unrestricted] {
            await s.harness.conditions.send(conditions)
            await engine.awaitCondition { $0.state.conditions == conditions }
        }
        let mid = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, f: e.state.jobs[f.transferID]?.state, events: e.state.eventsAfterFollow.count) }
        print("PROBE-C10-EDGE-ORDER \(visit) mid: \(mid)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil && $0.state.jobs[f.transferID] == nil }
        }
        let starts = await s.harness.source.starts.map(\.id)
        let fSecond = starts.indices.filter { starts[$0] == f.transferID }.dropFirst().first
        let cSecond = starts.indices.filter { starts[$0] == a.transferID }.dropFirst().first
        print("PROBE-C10-EDGE-ORDER \(visit) startList: \(starts.map { $0 == f.transferID ? "F" : $0 == a.transferID ? "C" : $0 == aMoved.transferID ? "N" : "o" })")
        print("PROBE-C10-EDGE-ORDER \(visit) results: a=\(aResult) fSecond=\(String(describing: fSecond)) cSecond=\(String(describing: cSecond)) starts=\(starts.count)")
        #expect(fSecond != nil && cSecond != nil && fSecond! < cSecond!, "F, re-admitted by the edge ahead of C (same lane, earlier ticket), retries first (visit-first): f=\(String(describing: fSecond)) c=\(String(describing: cSecond))")
        await engine.releaseGroup(fGroup)
        await engine.releaseGroup(cGroup)
        await FollowBarrier.finish(s, sync: sync)
    }
}

