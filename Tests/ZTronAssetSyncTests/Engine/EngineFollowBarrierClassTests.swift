import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The follow barrier's class closed by inventory (R-SYN-11, R-SYN-3, R-SYN-7, F-28; Stage 3 close-out cycle 11, ruling
/// S3-R14 and the cycle-10 verifiers' probes): every input that arrives while a follow is owed is decided as a visit-first
/// engine decides it, on the state the follow's visits leave. Each test runs in both orders (`LaneDropVisit`), with the
/// visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    // MARK: Policy pauses (R-SYN-7)

    /// Low Data Mode that arrives while the follow owes a visit pauses no transfer the visit raises to user work: C (1 MB,
    /// content X) downloads for a prefetch member P (zz-p); D (content W) downloads for A's user waiter (zz-a). v3 moves
    /// zz-a onto X while the follow owes D's visit; then Low Data Mode arrives. Visited first, D's visit moved A's user
    /// interest onto C, which Low Data Mode does not pause, and C's one attempt serves A. Behind the barrier, C was paused
    /// on its pre-visit prefetch lane and started again (PROBE-C10R-POLICY-PAUSE, PROBE-C10-PAUSE-LANE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: Low Data Mode during an owed follow pauses no transfer the follow raises to user work (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPausesOnTheFollowedLane(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_102)
        let engine = s.engine
        let xBytes = Data(repeating: 0xE1, count: 1_000_000)
        let wBytes = Data(repeating: 0xE2, count: 1_000_000)
        let p = EngineHarness.onDemand("zz-p", xBytes)
        let a = EngineHarness.onDemand("zz-a", wBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(710_000) + [a, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(p.transferID, [.hold, .stage(xBytes)])
        await s.harness.source.script(a.transferID, [.hold, .stage(wBytes)])
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[p.transferID]?.state == .downloading }
        }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let aMoved = EngineHarness.onDemand("zz-a", xBytes)
        try #require(aMoved.transferID == p.transferID, "setup: zz-a's new content is X")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(810_000) + [aMoved, p], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, lane: e.state.jobs[p.transferID]?.lane, c: e.state.jobs[p.transferID]?.state) }
            #expect(before.owed && before.lane == .prefetch && before.c == .downloading, "setup: C runs on the prefetch lane and D's visit is owed: \(before)")
        }
        await s.harness.conditions.send(EngineConditionsTests.lowData)
        await engine.awaitCondition { $0.state.conditions?.network.constrained == true }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let pauses = await s.harness.source.controlLog.filter { $0.transfer == p.transferID && $0.control == .pause }.count
        #expect(pauses == 0, "C, raised to the user lane by the owed visit, is not paused by Low Data Mode (visit-first): \(pauses) pause(s)")
        await s.harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.conditions?.network.constrained == false }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let held = await engine.readForTests { e in e.state.jobs[p.transferID]?.state == .downloading && e.state.jobs[p.transferID]?.active?.policyPause == nil }
        if held {
            await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(xBytes.count), "A is served from X: \(aResult)")
        let starts = await s.harness.source.starts.filter { $0.id == p.transferID }.count
        #expect(starts == 1, "C's one attempt, never paused, serves A (visit-first): \(starts) start(s)")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A pause that ends while the follow owes a visit is decided on the lane the visits leave: under Low Data Mode N
    /// (content X) downloads for U1's user waiter (b-n1) and a prefetch member (zz-n2), H holds the other of two slots and
    /// W's user request waits in the queue. v3 moves b-n1 away, moves zz-k (K, U2's user waiter, queued) onto X, and changes
    /// 300 prefetch members' contents, so the follow visits N in its first turn and K in its second. N's visit lowers it to
    /// the prefetch lane, which Low Data Mode refuses, so its attempt pauses. Visited first, K's visit raised N to user work
    /// again before the pause ended, so N resumed first in the user queue, ahead of W. With the pause decided between the
    /// two turns, N parked on its policy and K's visit re-queued it behind W.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: a pause that ends during an owed follow resumes on the lane the follow leaves (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesAPauseOnTheFollowedLane(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_112, tuning: SyncTuning(maxConcurrentTransfers: 2, preemptLowerLanes: false))
        let engine = s.engine
        let xBytes = Data(repeating: 0xE3, count: 1_000_000)
        let hBytes = Data(repeating: 0xE4, count: 100_000)
        let kBytes = Data(repeating: 0xE5, count: 100_000)
        let wBytes = Data(repeating: 0xE6, count: 100_000)
        let u1Bytes = EngineFixture.bytes(998_114, count: 16)
        let n1 = EngineHarness.onDemand("b-n1", xBytes)
        let n2 = EngineHarness.onDemand("zz-n2", xBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        let w = EngineHarness.onDemand("zz-w", wBytes)
        let members = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(998_120 + UInt64($0), count: 16)) }
        try #require(n1.transferID == n2.transferID, "setup: b-n1 and zz-n2 share N")
        await s.harness.serveManifest([s.q, n1, n2] + members + [h, k, w], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(n1.transferID, [.hold, .stage(xBytes)])
        await s.harness.source.script(w.transferID, [.stage(wBytes)])
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        await s.harness.conditions.send(EngineRegressionCycle10Tests.constrained)
        await engine.awaitCondition { $0.state.conditions == EngineRegressionCycle10Tests.constrained }
        let u1Waiter = Task { await engine.awaitAsset(n1.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[n1.transferID]?.state == .downloading }
        let group = try await engine.registerGroup([n2.identifier] + members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { e in e.state.jobs[n1.transferID]?.interests.count == 2 && members.allSatisfy { e.state.jobs[$0.transferID] != nil } }
        let u2Waiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .queued }
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[w.transferID]?.state == .queued }
        let n1Moved = EngineHarness.onDemand("b-n1", u1Bytes)
        let kMoved = EngineHarness.onDemand("zz-k", xBytes)
        try #require(kMoved.transferID == n1.transferID, "setup: zz-k's new content is X")
        let membersMoved = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(998_500 + UInt64($0), count: 16)) }
        await s.harness.source.script(n1Moved.transferID, [.stage(u1Bytes)])
        await engine.readForTests { $0.holdAttemptTerminals() }
        let sync = await FollowBarrier.apply([s.q, n1Moved, n2] + membersMoved + [h, kMoved, w], s, visit: visit)
        await engine.awaitCondition { $0.heldAttemptTerminalCount == 1 }
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, lane: e.state.jobs[n1.transferID]?.lane, pause: e.state.jobs[n1.transferID]?.active?.policyPause, k: e.state.jobs[k.transferID]?.state) }
            #expect(before.owed && before.lane == .prefetch && before.pause != nil && before.k == .queued, "setup: N's visit lowered it and asked for a policy pause; K's visit is owed: \(before)")
            await engine.readForTests { $0.releaseAttemptTerminals() }
            await engine.awaitCondition { $0.state.jobs[n1.transferID]?.state != .downloading }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await engine.readForTests { $0.releaseAttemptTerminals() }
        }
        await engine.awaitCondition { e in !e.followBarrier && !e.state.drainFollowUpScheduled && e.state.jobs[w.transferID]?.state != .queued }
        let starts = await s.harness.source.starts.map(\.id)
        let nSecond = starts.indices.filter { starts[$0] == n1.transferID }.dropFirst().first
        let wFirst = starts.firstIndex(of: w.transferID)
        #expect(nSecond != nil && (wFirst == nil || nSecond! < wFirst!), "N, user work again once K's visit moved U2 onto it, resumes first in its queue, ahead of W (visit-first): n=\(String(describing: nSecond)) w=\(String(describing: wFirst))")
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        let u2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: u2Waiter) }
        let u1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: u1Waiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        #expect((try? u2Result.get())?.byteSize == Int64(xBytes.count), "U2 is served from X: \(u2Result)")
        #expect((try? u1Result.get())?.byteSize == 16, "U1 is served from its new content: \(u1Result)")
        #expect((try? wResult.get())?.byteSize == Int64(wBytes.count), "W is served: \(wResult)")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: The origin's throttle

    /// A 429 whose park waits for the follow answers with the wait its own 429 gave, and leaves the origin's alarm at the
    /// origin's end: C (1 MB) is the content of zz-a and zz-b, one user waiter each (A, B); N (16 bytes, held) and D (1 MB,
    /// held) run for user waiters. v3 moves zz-a onto N's content while the follow owes C's visit. C gets a 429 with
    /// Retry-After 60 s, then D one with Retry-After 300 s, and 10 s pass before the follow ends. Visited first, C's park
    /// answered B with 60 s and the throttle's alarm moved to D's end. With C's park waiting, the drain answered B with
    /// the origin's later end and moved the alarm back to C's (PROBE-C10-THROTTLE-EXTENDED); answered at the drain's
    /// instant, B's wait would be 10 s short.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a throttle park decided after the follow answers with its own 429's wait and keeps the origin's alarm (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAThrottleParkWithItsOwnWait(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_202)
        let engine = s.engine
        let cBytes = Data(repeating: 0xE7, count: 1_000_000)
        let dBytes = Data(repeating: 0xE8, count: 1_000_000)
        let nBytes = EngineFixture.bytes(998_204, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        let n = EngineHarness.onDemand("zz-n", nBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(720_000) + [a, b, d, n], etag: "v2")
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
        try #require(aMoved.transferID == n.transferID, "setup: zz-a's new content is N's")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(820_000) + [aMoved, b, d, n], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        await s.harness.source.release(d.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[d.transferID]?.state != .downloading }
        s.time.advance(by: 10)
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let alarm = await engine.readForTests { e -> (deadline: MonotonicInstant?, end: MonotonicInstant?) in
            guard let origin = e.state.remote?.originID else {
                return (nil, nil)
            }
            return (e.state.heap.deadline(for: .throttle(origin)), e.state.throttles[origin])
        }
        if let deadline = alarm.deadline, let end = alarm.end {
            #expect(deadline >= end, "the throttle's alarm is never before the origin's end (D's 300 s): \(alarm)")
        } else {
            Issue.record("the origin is throttled with an alarm: \(alarm)")
        }
        await s.harness.source.release(n.transferID, with: .progress(received: 0, expected: nil))
        let bResult = await EngineHarness.value(of: bWaiter)
        if case .failure(.serverUnavailable(let retryAfter?)) = bResult {
            #expect(abs(retryAfter - 60) < 0.5, "B, answered by C's park, gets the wait C's 429 gave at its instant (visit-first 60 s): \(bResult)")
        } else {
            Issue.record("B gets the throttle's answer: \(bResult)")
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let dResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: dWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A is served from N: \(aResult)")
        #expect((try? wResult.get())?.byteSize == 16, "W is served from N: \(wResult)")
        if case .failure(.serverUnavailable) = dResult {
        } else {
            Issue.record("D's waiter gets its throttle's answer: \(dResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A 429 without Retry-After that arrives while the follow owes a visit throttles the origin for the backoff of the
    /// lane the visit leaves its job: C (1 MB) is the content of zz-a (M, a user waiter) and zz-b (P, a prefetch waiter);
    /// v3 moves zz-a while the follow owes C's visit. C gets a 429 without Retry-After. Visited first, C is prefetch work,
    /// so the throttle is the background policy's first backoff; decided before the visit, it was the interactive
    /// policy's (PROBE-C10-THROTTLE-LANE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow throttles the origin for the backoff of the lane the follow leaves (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierThrottlesForTheFollowedLane(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_302)
        let engine = s.engine
        let cBytes = Data(repeating: 0xE9, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: M and P share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(730_000) + [a, b], etag: "v2")
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
        let nBytes = EngineFixture.bytes(998_304, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(830_000) + [aMoved, b], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, lane: e.state.jobs[a.transferID]?.lane) }
            #expect(before.owed && before.c == .downloading && before.lane == .userInitiated, "setup: C runs on the user lane and its visit is owed: \(before)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        // Read right after the 429, before the follow's end: the 429 throttles the origin when it arrives, as visit-first
        // (Stage 3 close-out cycle 12, S3-R15 item 2; the cycle-11 verifiers' THROTTLE-LANE read after the 429).
        let atArrival = await engine.readForTests { e -> Double? in
            e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow())
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let figures = await engine.readForTests { e -> (throttle: Double?, background: Double?, interactive: Double?) in
            guard let origin = e.state.remote?.originID else {
                return (nil, nil, nil)
            }
            let key = StableHash.fnv1a64(origin)
            return (
                e.state.throttles[origin]?.seconds(since: e.environment.time.monotonicNow()),
                Backoff.delay(attempt: 1, retryAfter: nil, policy: e.tuning.retry, seed: e.environment.random.seed, key: key),
                Backoff.delay(attempt: 1, retryAfter: nil, policy: e.tuning.interactiveRetry, seed: e.environment.random.seed, key: key)
            )
        }
        if let throttle = figures.throttle, let background = figures.background {
            #expect(abs(throttle - background) < 0.000_001, "the origin's throttle is the backoff of C's prefetch lane (visit-first): \(figures)")
        } else {
            Issue.record("the origin is throttled: \(figures)")
        }
        if let throttle = atArrival, let background = figures.background {
            #expect(abs(throttle - background) < 0.000_001, "right after the 429 the origin is throttled for the backoff of C's prefetch lane (visit-first): \(throttle) against \(figures)")
        } else {
            Issue.record("the origin is throttled right after the 429 (visit-first): \(String(describing: atArrival)) against \(figures)")
        }
        let mResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: mWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect((try? mResult.get())?.byteSize == 16, "M is served from its new content: \(mResult)")
        #expect((try? pResult.get())?.byteSize == Int64(cBytes.count), "P is served by C's retry: \(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// The fail-fast turn a throttle's extension owes the throttle-parked jobs' users waits for the follow: Y (16 bytes,
    /// zz-y) is present; T (1 MB) runs for U (zz-u) and K (zz-k), user waiters both; E (1 MB) runs for a user waiter. v3
    /// moves zz-u onto Y. Between the manifest's fetch and its apply, T gets a 429 with Retry-After 1 s (within the user
    /// wait: nobody is answered); then, while the follow owes T's visit, E gets one with Retry-After 300 s. Visited first,
    /// U was answered from Y and the extension's fail-fast answered K alone. Behind the barrier the extension's turn
    /// answered U too, with the throttle (the cycle-10 residual `answerThrottledUsers`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a throttle's extension during an owed follow answers only the users the follow leaves throttled (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAThrottleExtensionOnTheFollowedState(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_402)
        let engine = s.engine
        let tBytes = Data(repeating: 0xEA, count: 1_000_000)
        let eBytes = Data(repeating: 0xEB, count: 1_000_000)
        let yBytes = EngineFixture.bytes(998_404, count: 16)
        let u = EngineHarness.onDemand("zz-u", tBytes)
        let k = EngineHarness.onDemand("zz-k", tBytes)
        let ex = EngineHarness.onDemand("zz-e", eBytes)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        try #require(u.transferID == k.transferID, "setup: U and K share T")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(740_000) + [ex, k, u, y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        await s.harness.source.script(y.transferID, [.stage(yBytes)])
        let yResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await engine.awaitAsset(y.identifier, lane: .userInitiated) }
        try #require((try? yResult.get())?.byteSize == 16, "setup: Y is present: \(yResult)")
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(u.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(1))), .stage(tBytes)])
        await s.harness.source.script(ex.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(300))), .stage(eBytes)])
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[u.transferID]?.interests.count == 2 }
        let eWaiter = Task { await engine.awaitAsset(ex.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[ex.transferID]?.state == .downloading }
        let uMoved = EngineHarness.onDemand("zz-u", yBytes)
        try #require(uMoved.transferID == y.transferID, "setup: zz-u's new content is Y's")
        await engine.readForTests { e in
            e.holdFollowFollowUps()
            e.holdManifestOutcomeDelivery()
        }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(840_000) + [ex, k, uMoved, y], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.manifestOutcomeHeld }
        await s.harness.source.release(u.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[u.transferID]?.state.isThrottleParked == true }
        await engine.readForTests { $0.releaseManifestOutcomeDelivery() }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
            _ = await EngineHarness.value(of: uWaiter)
        } else {
            let before = await engine.readForTests { e in (owed: e.followOwed, bound: e.isBound(uMoved.identifier, to: y.transferID), t: e.state.jobs[u.transferID]?.interests.count) }
            #expect(before.owed && before.bound && before.t == 2, "setup: T holds U and K, its visit is owed and Y is present: \(before)")
        }
        await s.harness.source.release(ex.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[ex.transferID]?.state != .downloading }
        await engine.awaitCondition { !$0.state.throttleAnswersScheduled }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled && !$0.state.throttleAnswersScheduled }
        let uResult = await EngineHarness.value(of: uWaiter)
        let kResult = await EngineHarness.value(of: kWaiter)
        #expect((try? uResult.get())?.byteSize == 16, "U, moved onto Y's present content by the owed visit, is answered from it (visit-first): \(uResult)")
        if case .failure(.serverUnavailable(let retryAfter?)) = kResult {
            #expect(retryAfter > 2, "K, still T's, gets the extended throttle's answer: \(kResult)")
        } else {
            Issue.record("K gets the extension's fail-fast answer: \(kResult)")
        }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: eWaiter) }
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: Withdrawals and joins

    /// A withdrawal made while the follow owes a visit is applied after the answers it would have followed: C (1 MB) is the
    /// content of zz-a (M, a user waiter) and zz-b (P, a prefetch waiter); v3 moves zz-a to a 16-byte content while the
    /// follow owes C's visit. C's attempt fails with a 500 (a retry), then a prefetch request J for zz-b arrives, then P
    /// withdraws. Visited first, C backed off (`failed(.at)`, one attempt counted), J joined it and kept it after P left,
    /// and no second attempt started before the backoff ended. With J's join waiting behind C's verdict and P's withdrawal
    /// applied at once, the visit that moved M left C without an interest: C was retired, and the drain created a fresh
    /// job for J that started at once (PROBE-C10-JOIN-RETIRE). P's caller is answered at once in both orders (R-SYN-4,
    /// R-SYN-10), and no transfer runs for nobody once the follow's events are applied (R-CAR-4).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a withdrawal during an owed follow is answered at once and applied after the verdict it followed (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAppliesAWithdrawalAfterTheVerdictItFollowed(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_502)
        let engine = s.engine
        let cBytes = Data(repeating: 0xEC, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: M and P share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(750_000) + [a, b], etag: "v2")
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
        let nBytes = EngineFixture.bytes(998_504, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(850_000) + [aMoved, b], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let jWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.waiters.values.filter { $0.asset == b.identifier }.count == 2 }
        pWaiter.cancel()
        let pResult = await pWaiter.value
        #expect(pResult == .failure(.cancelled), "P's caller is answered at once (R-SYN-4, R-SYN-10): \(pResult)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        // No clock movement from here to the check: only the follow's turns, the drain and the pumps run.
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await engine.awaitCondition { e in e.state.jobs[a.transferID].map { $0.state != .queued } ?? true }
        let after = await engine.readForTests { e in
            (
                c: e.state.jobs[a.transferID].map { ($0.state, $0.attempts, $0.interests.count) },
                forNobody: e.state.jobs.values.filter { $0.state == .downloading && $0.interests.isEmpty }.map(\.transfer)
            )
        }
        let cStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        if case .failed(.at)? = after.c?.0 {
        } else {
            Issue.record("C keeps its backoff with J's interest (visit-first failed(.at)): \(after)")
        }
        #expect(after.c?.1 == 1 && after.c?.2 == 1, "the failed attempt stays counted and J alone holds C (visit-first): \(after)")
        #expect(cStarts == 1, "no second attempt before the backoff ends (visit-first): \(cStarts)")
        #expect(after.forNobody.isEmpty, "no transfer runs for nobody (R-CAR-4): \(after.forNobody)")
        let mResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: mWaiter) }
        let jResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: jWaiter) }
        #expect((try? mResult.get())?.byteSize == 16, "M is served from its new content: \(mResult)")
        #expect((try? jResult.get())?.byteSize == Int64(cBytes.count), "J is served by C's retry: \(jResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A request that arrives while the follow owes a visit joins the job the visit creates, at the place the visit gave
    /// it: one slot, which H's held user transfer takes; J (zz-j) and X (zz-x) are queued prefetch requests. v3 moves zz-j
    /// onto the content of zz-r and zz-x onto a new content Z, and the follow owes both visits; then a prefetch request R
    /// for zz-r arrives. Visited first, J's visit created zz-r's job K, X's visit created Z's after it, and R joined K: K
    /// starts before Z. Behind the barrier R created K, whose place waited for the drain, behind Z's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a request during an owed follow joins the job the follow creates, at the follow's place (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierJoinsARequestToTheJobTheFollowCreates(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_602, tuning: SyncTuning(maxConcurrentTransfers: 1))
        let engine = s.engine
        let hBytes = Data(repeating: 0xED, count: 100_000)
        let jBytes = Data(repeating: 0xEE, count: 100_000)
        let xBytes = Data(repeating: 0xEF, count: 100_000)
        let rBytes = Data(repeating: 0xF0, count: 100_000)
        let zBytes = Data(repeating: 0xF1, count: 100_000)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let j = EngineHarness.onDemand("zz-j", jBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(760_000) + [h, j, r, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        let mWaiter = Task { await engine.awaitAsset(j.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[j.transferID]?.state == .queued }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .queued }
        let jMoved = EngineHarness.onDemand("zz-j", rBytes)
        let xMoved = EngineHarness.onDemand("zz-x", zBytes)
        try #require(jMoved.transferID == r.transferID, "setup: zz-j's new content is zz-r's")
        await s.harness.source.script(r.transferID, [.stage(rBytes)])
        await s.harness.source.script(xMoved.transferID, [.stage(zBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(860_000) + [h, jMoved, r, xMoved], s, visit: visit)
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.waiters.values.contains { $0.asset == r.identifier } }
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, j: e.state.jobs[j.transferID]?.state, x: e.state.jobs[x.transferID]?.state) }
            #expect(before.owed && before.j == .queued && before.x == .queued, "setup: J's and X's visits are owed: \(before)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        let mResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: mWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        let starts = await s.harness.source.starts.map(\.id)
        let kIndex = starts.firstIndex(of: r.transferID)
        let zIndex = starts.firstIndex(of: xMoved.transferID)
        #expect(kIndex != nil && zIndex != nil && kIndex! < zIndex!, "K, created by J's visit before Z, starts first (visit-first): k=\(String(describing: kIndex)) z=\(String(describing: zIndex))")
        #expect((try? rResult.get())?.byteSize == Int64(rBytes.count), "R is served from K: \(rResult)")
        #expect((try? mResult.get())?.byteSize == Int64(rBytes.count), "J's waiter is served from K: \(mResult)")
        #expect((try? xResult.get())?.byteSize == Int64(zBytes.count), "X's waiter is served from Z: \(xResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: Re-admissions

    /// A network edge's re-admissions that arrive while the follow owes a visit are placed as the edge places them
    /// visit-first: two transfer slots; H (user, held) runs; under Low Data Mode P (zz-p) is parked by policy for a
    /// prefetch waiter; C (zz-a) runs for user waiter A; B (zz-b) is queued for user waiter W. v3 moves zz-a onto P's
    /// content and zz-b onto a new content X. Visited first, C's visit raised P to user work and queued it, then B's
    /// visit created X behind it, and the network's turning unrestricted re-admitted nothing: P starts before X. Behind
    /// the barrier the re-admission queued P (its place waiting), the visit placed P and X, and the drain placed P again,
    /// behind X (PROBE-C10-DOUBLE-PLACE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a re-admission during an owed follow leaves the place the follow's visit gives (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPlacesAReadmissionAsTheFollowLeavesIt(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_702, tuning: SyncTuning(maxConcurrentTransfers: 2))
        let engine = s.engine
        let pBytes = Data(repeating: 0xF2, count: 100_000)
        let hBytes = Data(repeating: 0xF3, count: 100_000)
        let caBytes = Data(repeating: 0xF4, count: 100_000)
        let cbBytes = Data(repeating: 0xF5, count: 100_000)
        let xBytes = Data(repeating: 0xF6, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", caBytes)
        let b = EngineHarness.onDemand("zz-b", cbBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(770_000) + [a, b, h, p], etag: "v2")
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
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state.isLaneParked == true }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let wWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state == .queued }
        let aMoved = EngineHarness.onDemand("zz-a", pBytes)
        let bMoved = EngineHarness.onDemand("zz-b", xBytes)
        try #require(aMoved.transferID == p.transferID, "setup: zz-a's new content is P's")
        await s.harness.source.script(bMoved.transferID, [.stage(xBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(870_000) + [aMoved, bMoved, h, p], s, visit: visit)
        await s.harness.conditions.send(DeviceConditions.unrestricted)
        await engine.awaitCondition { $0.state.conditions == DeviceConditions.unrestricted }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let starts = await s.harness.source.starts.map(\.id)
        let pIndex = starts.firstIndex(of: p.transferID)
        let xIndex = starts.firstIndex(of: bMoved.transferID)
        #expect(pIndex != nil && xIndex != nil && pIndex! < xIndex!, "P, queued by C's visit before X, starts first (visit-first): p=\(String(describing: pIndex)) x=\(String(describing: xIndex))")
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "A is served from P: \(aResult)")
        #expect((try? wResult.get())?.byteSize == Int64(xBytes.count), "W is served from X: \(wResult)")
        #expect((try? pResult.get())?.byteSize == Int64(pBytes.count), "P's waiter is served: \(pResult)")
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A network edge that arrives while the follow owes a visit re-admits the jobs it owes in its own order, whatever
    /// verdict waits: one slot, no preemption. F (zz-f, a prefetch member) failed offline and waits for an edge; C (zz-a,
    /// zz-b) runs for a prefetch member of zz-b and A's user waiter of zz-a, and its ticket is F's successor. v3 moves zz-a
    /// while the follow owes C's visit; C fails offline, then the network drops and returns. Visited first, the edge
    /// re-admitted F, then C (same lane, F's earlier ticket): F's retry starts before C's. Behind the barrier the edge's
    /// event for C, whose verdict waited, came before the re-admission's place for F, so C's retry started first (the
    /// cycle-10 residual "`.edge` events before the same edge's re-admissions").
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: an edge during an owed follow re-admits in its own order whatever verdict waits (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierReadmitsAnEdgeInItsOwnOrder(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_802, tuning: SyncTuning(maxConcurrentTransfers: 1, preemptLowerLanes: false))
        let engine = s.engine
        let cBytes = Data(repeating: 0xF7, count: 100_000)
        let fBytes = Data(repeating: 0xF8, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let f = EngineHarness.onDemand("zz-f", fBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(780_000) + [a, b, f], etag: "v2")
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
        let nBytes = EngineFixture.bytes(998_804, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(880_000) + [aMoved, b, f], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, f: e.state.jobs[f.transferID]?.ticket, ticket: e.state.jobs[a.transferID]?.ticket) }
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        for conditions in [EngineRegressionCycle10Tests.offline, DeviceConditions.unrestricted] {
            await s.harness.conditions.send(conditions)
            await engine.awaitCondition { $0.state.conditions == conditions }
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil && $0.state.jobs[f.transferID] == nil }
        }
        let starts = await s.harness.source.starts.map(\.id)
        let fSecond = starts.indices.filter { starts[$0] == f.transferID }.dropFirst().first
        let cSecond = starts.indices.filter { starts[$0] == a.transferID }.dropFirst().first
        #expect(fSecond != nil && cSecond != nil && fSecond! < cSecond!, "F, re-admitted by the edge ahead of C (same lane, earlier ticket), retries first (visit-first): f=\(String(describing: fSecond)) c=\(String(describing: cSecond))")
        #expect((try? aResult.get())?.byteSize == 16, "A is served from its new content: \(aResult)")
        await engine.releaseGroup(fGroup)
        await engine.releaseGroup(cGroup)
        await FollowBarrier.finish(s, sync: sync)
    }
}
