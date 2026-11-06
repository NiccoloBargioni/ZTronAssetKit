import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 13, correctness lens). Never committed.
///
/// Each runs in both orders (`LaneDropVisit`); every expectation is the visit-first outcome. Under S3-R16 only a
/// different answer, a broken MUST or invariant, a hang or a flake is blocking.
@Suite("VerifyC13CorrectProbesRerun", .serialized)
struct VerifyC13CorrectProbes {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// PROBE-C13-PURGE-JOIN (removal 7 of cycle 13): a prefetch group registered while the follow is owed has its join
    /// for zz-m waiting (`joinsAfterFollow`; `groups[token].pending[zz-m]` already set by `joinMember`). A purge of zz-m
    /// then arrives. Visit-first: the join had made M's job with the group's interest, the purge's `withdrawPurged`
    /// dropped the group member and the interest, M was retired, and zz-m is not fetched again. Behind the barrier the
    /// purge applies at once and finds no job holding the group's interest; the drain then replays the join
    /// (`stillWants` is true: the group still lists zz-m as pending) and zz-m is downloaded again after the purge.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C13-PURGE-JOIN", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func purgeMissesWaitingJoin(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_313_502)
        let engine = s.engine
        let mBytes = EngineFixture.bytes(1_313_504, count: 100_000)
        let wBytes = EngineFixture.bytes(1_313_505, count: 100_000)
        let m = EngineHarness.onDemand("zz-m", mBytes)
        let w = EngineHarness.onDemand("zz-w", wBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_313_600) + [m, w], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(m.transferID, [.hold, .stage(mBytes)])
        await s.harness.source.script(w.transferID, [.hold, .stage(wBytes)])
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[w.transferID]?.state == .downloading }
        }
        try await EngineFollowBarrierTests.applyHeld([s.q] + FollowBarrier.fillers(1_313_700) + [m, w], tag: "v3-purge", s, visit: visit)
        let token = try await engine.registerGroup([m.identifier], lane: .prefetch).get()
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, m) }
        } else {
            await engine.awaitCondition { $0.state.jobs[m.transferID]?.interests[token] != nil && $0.state.jobs[m.transferID]?.state == .downloading }
        }
        let beforePurge = await engine.readForTests { e in
            (owed: e.followBarrier, pending: e.state.groups[token]?.pending[m.identifier] != nil, job: e.state.jobs[m.transferID]?.state)
        }
        print("PROBE-C13-PURGE-JOIN \(visit) before purge: \(beforePurge)")
        let purged = await engine.purge(.scope(.identifiers([m.identifier])))
        print("PROBE-C13-PURGE-JOIN \(visit) purge: \(purged)")
        let startsBefore = await s.harness.source.starts.filter { $0.id == m.transferID }.count
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { e in
            (pending: e.state.groups[token]?.pending[m.identifier] != nil, job: e.state.jobs[m.transferID]?.state, interest: e.state.jobs[m.transferID]?.interests[token] != nil)
        }
        let startsAfter = await s.harness.source.starts.filter { $0.id == m.transferID }.count
        print("PROBE-C13-PURGE-JOIN \(visit) after drain: \(after) starts \(startsBefore) -> \(startsAfter)")
        #expect(!after.pending && after.job == nil, "PROBE-C13-PURGE-JOIN: the purge withdrew the group's member (visit-first: no job, the group no longer waits for zz-m): \(after)")
        #expect(startsAfter == startsBefore, "PROBE-C13-PURGE-JOIN: no request for the purged zz-m after the purge (visit-first): \(startsBefore) -> \(startsAfter)")
        if after.job != nil {
            await engine.awaitCondition { $0.state.jobs[m.transferID]?.state == .downloading }
            await s.harness.source.release(m.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[m.transferID] == nil }
            }
        }
        let present = await s.harness.store.location(for: m.identifier, extensions: [], recordingAccess: false) != nil
        print("PROBE-C13-PURGE-JOIN \(visit) zz-m present after purge and drain: \(present)")
        #expect(!present, "PROBE-C13-PURGE-JOIN: zz-m stays purged (visit-first)")
        await engine.releaseGroup(token)
        await s.harness.source.release(w.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        let violations = await engine.invariantViolations()
        print("PROBE-C13-PURGE-JOIN \(visit) violations: \(violations.prefix(3))")
        await engine.shutdown()
    }

    /// PROBE-C13-STAMP-NO-SLOT (the mirror of R-I): one slot. C (1 MB, held) downloads for user waiter A and holds the
    /// slot. While the follow is owed, an unknown id's manifest fetch gets a 429 with Retry-After 3 s, so the origin is
    /// throttled while C runs. A user then asks for zz-k (16 B, listed, no job). Visit-first: K is created and waits in
    /// the queue behind C's slot (the pump gates nothing while no slot is free). The clock passes the throttle's end, then
    /// C completes: the pump starts K on the live gates and K's caller is served. Behind the barrier the join is replayed
    /// under its arrival's view (throttle in force) and gets a place stamp; the barrier-end pump refuses K on the stamp's
    /// view although no slot was free at that instant, and K's user is answered serverUnavailable at the stamp's instant.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C13-STAMP-NO-SLOT", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func stampRefusesWithoutSlot(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_313_002, tuning: SyncTuning(maxConcurrentTransfers: 1))
        let engine = s.engine
        let cBytes = Data(repeating: 0xD1, count: 1_000_000)
        let kBytes = EngineFixture.bytes(1_313_004, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_313_100) + [a, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_313_200) + [a, k], s, visit: visit)
        await s.harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(3)))])
        let none = await engine.awaitAsset("zz-none", lane: .userInitiated)
        let throttled = await engine.readForTests { e in
            (barrier: e.followBarrier, left: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[a.transferID]?.state)
        }
        print("PROBE-C13-STAMP-NO-SLOT \(visit) after the manifest 429: none=\(none) \(throttled)")
        try #require(throttled.left != nil && throttled.c == .downloading, "setup: the origin is throttled while C holds the slot: \(throttled)")
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, k) }
        } else {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .queued }
        }
        s.time.advance(by: 4)
        await engine.awaitCondition { e in e.state.remote.flatMap { e.state.throttles[$0.originID] }.map { $0 <= e.environment.time.monotonicNow() } ?? true }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let kStarts = await s.harness.source.starts.filter { $0.id == k.transferID }.count
        print("PROBE-C13-STAMP-NO-SLOT \(visit) k=\(kResult) a=\(aResult) kStarts=\(kStarts)")
        #expect((try? aResult.get())?.byteSize == Int64(cBytes.count), "A is served by C: \(aResult)")
        #expect((try? kResult.get())?.byteSize == 16, "PROBE-C13-STAMP-NO-SLOT: K's caller is served (visit-first: K waited behind C's slot and started on the live gates after the throttle ended): \(kResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C13-EXHAUST-LANE (RR-1 with an answer): the PROBE-C12R-FOLLOWED-LANE scenario with an interactive policy
    /// whose `maxRetryAfter` (30 s) is below the background one (3,600 s). C (1 MB, zz-b) runs for P, a prefetch waiter;
    /// Y (zz-u) runs for U, a user waiter; v3 moves zz-u onto C's content. C gets a 429 with Retry-After 60 s.
    /// Visit-first, C is user work at the 429: the interactive policy defers to the next run (`Backoff.delay` is nil),
    /// C fails `.nextRun` and every interest, P's included, is answered serverUnavailable(60); the origin is not
    /// throttled. Behind the barrier `followedLane(C)` is prefetch: the background policy throttles the origin for 60 s
    /// (`.until`), the replay parks C, and P keeps waiting and is served by C's retry once the throttle ends.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C13-EXHAUST-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func exhaustionFollowsTheWrongLane(_ visit: LaneDropVisit) async throws {
        let interactive = RetryPolicy(baseDelay: 0.25, maxDelay: 2, maxAttemptsPerRun: 2, maxRetryAfter: 30, interactiveMaxWait: 2)
        let (s, _) = try await FollowBarrier.setUp(seed: 1_313_302, tuning: SyncTuning(interactiveRetry: interactive))
        let engine = s.engine
        let cBytes = Data(repeating: 0xD7, count: 1_000_000)
        let yBytes = Data(repeating: 0xD8, count: 1_000_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let u = EngineHarness.onDemand("zz-u", yBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_313_400) + [b, u], etag: "v2")
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
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_313_450) + [b, uMoved], s, visit: visit)
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let atArrival = await engine.readForTests { e in
            (throttle: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[b.transferID]?.state)
        }
        print("PROBE-C13-EXHAUST-LANE \(visit) right after the 429: \(atArrival)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let afterDrain = await engine.readForTests { e in
            (throttle: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[b.transferID]?.state)
        }
        print("PROBE-C13-EXHAUST-LANE \(visit) after the drain: \(afterDrain)")
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C13-EXHAUST-LANE \(visit) u=\(uResult) p=\(pResult)")
        #expect(atArrival.throttle == nil, "PROBE-C13-EXHAUST-LANE: the 429 beyond the user lane's cap leaves the origin unthrottled (visit-first .exhausted): \(atArrival)")
        if case .failure(.serverUnavailable) = pResult {
        } else {
            Issue.record("PROBE-C13-EXHAUST-LANE: P is answered serverUnavailable with C's deferral to the next run (visit-first): \(pResult)")
        }
        if case .failure(.serverUnavailable) = uResult {
        } else {
            Issue.record("U is answered serverUnavailable (visit-first): \(uResult)")
        }
        let violations = await engine.invariantViolations()
        print("PROBE-C13-EXHAUST-LANE \(visit) violations: \(violations.prefix(3))")
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }
}
