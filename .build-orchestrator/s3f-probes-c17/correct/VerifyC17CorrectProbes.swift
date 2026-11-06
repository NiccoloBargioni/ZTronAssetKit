import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 17, correctness lens). Never committed.
///
/// Part 1 re-runs, unchanged except for their display names, the scenarios the cycle-16 verifiers reported blocking
/// (PROBE-C16C-VERDICT-MAPPED-BACK, -RR11-RETRY-LANE, -THROTTLE-FAILFAST-LANE, -INTERMEDIATE-HOP, -INTERMEDIATE-HOP-SERVED,
/// PROBE-C16R-RR11-RETRY-AFTER). Part 2 is this verifier's own variant of a fixed class (an offline exit's fail-fast).
/// Part 3 hunts what cycle 17's mechanism (`bringInbound`, `takeOffMovedBefore`, `verdictAnswers` through the replays'
/// functions) may still miss. Each runs in both orders and expects the visit-first outcome.
@Suite("VerifyC17Correct", .serialized)
struct VerifyC17Correct {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias T = EngineFollowBarrierTests

    // MARK: Part 1: the cycle-16 blocking scenarios, unchanged

    /// PROBE-C16C-VERDICT-MAPPED-BACK (correct-1).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-REPRO-VERDICT-MAPPED-BACK", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func verdictMappedBack(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_616_902
        let (s, _) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        try await T.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-back-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
            }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        }
        let at404 = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, reroute: e.state.jobs[a.transferID]?.rerouteOnPass?.sorted(), end: e.state.jobs[a.transferID]?.attemptEnd, n: e.state.jobs[bMoved.transferID]?.state)
        }
        print("C17-REPRO-VERDICT-MAPPED-BACK \(visit) after the 404: \(at404)")
        try await T.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-back-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let cStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        print("C17-REPRO-VERDICT-MAPPED-BACK \(visit) a=\(aResult) b=\(bResult) cStarts=\(cStarts)")
        #expect(aResult == .failure(.notFound), "A gets C's 404 (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "C17-REPRO-VERDICT-MAPPED-BACK: B is served by a fresh job of C's content (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16C-RR11-RETRY-LANE (correct-2).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-REPRO-RR11-RETRY-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func rr11RetryLane(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_617_002
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: T.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(p.transferID == bMoved.transferID && b.transferID != p.transferID, "setup: zz-p and v4's zz-b share N")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, p] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 503), retryAfter: .seconds(120))), .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(nBytes)])
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        try await T.applyHeld([s.q] + fillers + [b, p] + later, tag: "v3-rr11-\(seed)", s, visit: visit)
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[b.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID] == nil }
        }
        try await T.applyHeld([s.q] + fillers + [bMoved, p] + later, tag: "v4-rr11-\(seed)", s, visit: visit)
        let lane = await engine.readForTests { e in (followed: e.state.jobs[p.transferID].map { e.followedLane($0) }, own: e.state.jobs[p.transferID]?.lane, owed: e.followOwed, barrier: e.followBarrier) }
        print("C17-REPRO-RR11-RETRY-LANE \(visit) N's lane before its 429: \(lane)")
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let throttle = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("C17-REPRO-RR11-RETRY-LANE \(visit) throttle=\(String(describing: throttle)) b=\(bResult) p=\(pResult)")
        #expect((try? bResult.get()) == nil, "B gets C's 503 answer (visit-first): \(bResult)")
        #expect(throttle != nil, "C17-REPRO-RR11-RETRY-LANE: N's 429 throttles the origin on N's own (prefetch) lane (visit-first): \(String(describing: throttle))")
        #expect((try? pResult.get())?.byteSize == 16, "C17-REPRO-RR11-RETRY-LANE: P is served by N's retry after the throttle (visit-first): \(pResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16C-THROTTLE-FAILFAST-LANE (correct-3).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-REPRO-THROTTLE-FAILFAST-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func throttleFailFastLane(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_617_102
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: T.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(p.transferID == bMoved.transferID && b.transferID != p.transferID, "setup: zz-p and v4's zz-b share N")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, p] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(10))), .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(nBytes)])
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        try await T.applyHeld([s.q] + fillers + [b, p] + later, tag: "v3-ff-\(seed)", s, visit: visit)
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[b.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        }
        try await T.applyHeld([s.q] + fillers + [bMoved, p] + later, tag: "v4-ff-\(seed)", s, visit: visit)
        let before = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let after = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("C17-REPRO-THROTTLE-FAILFAST-LANE \(visit) before=\(String(describing: before)) after=\(String(describing: after)) b=\(bResult) p=\(pResult)")
        #expect((try? bResult.get()) == nil, "B gets the throttle's fail-fast answer (visit-first): \(bResult)")
        #expect(after != before, "C17-REPRO-THROTTLE-FAILFAST-LANE: N's 429 extends the origin's throttle on N's own lane (visit-first)")
        #expect((try? pResult.get())?.byteSize == 16, "C17-REPRO-THROTTLE-FAILFAST-LANE: P is served by N's retry (visit-first): \(pResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16C-INTERMEDIATE-HOP (correct-4).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-REPRO-INTERMEDIATE-HOP", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func intermediateHop(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_617_202
        let (s, _) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let mBytes = EngineFixture.bytes(seed + 7, count: 48)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bToN = EngineHarness.onDemand("zz-b", nBytes)
        let bToM = EngineHarness.onDemand("zz-b", mBytes)
        try #require(p.transferID == bToN.transferID && b.transferID != p.transferID && bToM.transferID != p.transferID && bToM.transferID != b.transferID, "setup: three contents")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, p] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(nBytes)])
        await s.harness.source.script(bToM.transferID, [.stage(mBytes)])
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        try await T.applyHeld([s.q] + fillers + [bToN, p] + later, tag: "v3-hop-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[b.transferID] == nil && $0.state.jobs[p.transferID]?.interests.count == 2 }
        }
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        }
        try await T.applyHeld([s.q] + fillers + [bToM, p] + later, tag: "v4-hop-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let mStarts = await s.harness.source.starts.filter { $0.id == bToM.transferID }.count
        print("C17-REPRO-INTERMEDIATE-HOP \(visit) b=\(bResult) p=\(pResult) mStarts=\(mStarts)")
        #expect(pResult == .failure(.notFound), "P gets N's 404 (visit-first): \(pResult)")
        #expect(bResult == .failure(.notFound), "C17-REPRO-INTERMEDIATE-HOP: B was on N at its 404 (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16C-INTERMEDIATE-HOP-SERVED (correct-4).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-REPRO-INTERMEDIATE-HOP-SERVED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func intermediateHopServed(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_617_302
        let (s, _) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let mBytes = EngineFixture.bytes(seed + 7, count: 48)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bToN = EngineHarness.onDemand("zz-b", nBytes)
        let bToM = EngineHarness.onDemand("zz-b", mBytes)
        try #require(p.transferID == bToN.transferID && b.transferID != p.transferID && bToM.transferID != p.transferID && bToM.transferID != b.transferID, "setup: three contents")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, p] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .stage(nBytes)])
        await s.harness.source.script(bToM.transferID, [.stage(mBytes)])
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        try await T.applyHeld([s.q] + fillers + [bToN, p] + later, tag: "v3-served-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[b.transferID] == nil && $0.state.jobs[p.transferID]?.interests.count == 2 }
        }
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        try await T.applyHeld([s.q] + fillers + [bToM, p] + later, tag: "v4-served-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let mStarts = await s.harness.source.starts.filter { $0.id == bToM.transferID }.count
        print("C17-REPRO-INTERMEDIATE-HOP-SERVED \(visit) b=\(bResult) p=\(pResult) mStarts=\(mStarts)")
        #expect((try? pResult.get())?.byteSize == 16, "P is served N (visit-first): \(pResult)")
        #expect((try? bResult.get())?.byteSize == 16, "C17-REPRO-INTERMEDIATE-HOP-SERVED: B was on N at its publication and is served N's content (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16R-RR11-RETRY-AFTER (reqs-2).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-REPRO-RR11-RETRY-AFTER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func rr11RetryAfter(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_616_802
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: T.shortInteractiveRetry))
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let jBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", oBytes)
        let b = EngineHarness.onDemand("zz-b", oBytes)
        let p = EngineHarness.onDemand("zz-p", jBytes)
        let bMoved = EngineHarness.onDemand("zz-b", jBytes)
        try #require(a.transferID == b.transferID && p.transferID == bMoved.transferID, "setup")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, p] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 503), retryAfter: .seconds(120)))])
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(jBytes)])
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
        try await T.applyHeld([s.q] + fillers + [a, b, p] + T.laterFillers(seed + 6_000), tag: "v3-rr11-\(seed)", s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { e in
                guard let job = e.state.jobs[a.transferID] else {
                    return true
                }
                switch job.state {
                case .failed(.at), .failed(.nextRun), .blocked:
                    return true
                case .queued, .downloading, .verifying, .committing, .failed:
                    return false
                }
            }
        }
        try await T.applyHeld([s.q] + fillers + [a, bMoved, p] + T.laterFillers(seed + 9_000), tag: "v4-rr11-\(seed)", s, visit: visit)
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let throttled = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        await T.finishHeld(s)
        let trace = "\(visit): throttled \(throttled); A \(aResult); B \(bResult); P \(pResult)"
        print("C17-REPRO-RR11-RETRY-AFTER \(trace)")
        #expect(throttled, "C17-REPRO-RR11-RETRY-AFTER: J's 429 throttles the origin (visit-first): \(trace)")
        #expect((try? pResult.get())?.byteSize == Int64(jBytes.count), "C17-REPRO-RR11-RETRY-AFTER: P is served J after the throttle (visit-first): \(trace)")
        #expect((try? bResult.get()) == nil, "C17-REPRO-RR11-RETRY-AFTER: B is answered by O's verdict (visit-first): \(trace)")
    }

    // MARK: Part 2: this verifier's own variant of a fixed class

    /// PROBE-C17C-OFFLINE-FAILFAST-LANE (correct-3's unprobed offline case, on correct-2's scenario): C's attempt ends
    /// offline with no edge passed while a follow is owed (sweep-first: its verdict waits). Visit-first: `failFast(.offline)`
    /// answers B (a user waiter) at the failure, v4's move of zz-b onto N moves nobody, and N's 429 (Retry-After 60 s,
    /// beyond the interactive cap of 30 s) is decided on N's own prefetch lane: the origin throttled, P served after it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17C-OFFLINE-FAILFAST-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func offlineFailFastLane(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_717_202
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: T.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(p.transferID == bMoved.transferID && b.transferID != p.transferID, "setup: zz-p and v4's zz-b share N")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, p] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .fail(.offline(.noConnection)), .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(nBytes)])
        // P (prefetch) first: its dispatch waits for the first conditions reading, so C's attempt starts after that edge
        // and its offline failure is not retried at once (`edgePassed` false: a fail-fast, not a re-queue).
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[p.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let edge = await engine.readForTests { e in (serial: e.state.networkEdgeSerial, c: e.state.jobs[b.transferID]?.active?.edgeSerial) }
        print("PROBE-C17C-OFFLINE-FAILFAST-LANE \(visit) edge before the offline failure \(edge)")
        try await T.applyHeld([s.q] + fillers + [b, p] + later, tag: "v3-off-\(seed)", s, visit: visit)
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[b.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        }
        let atC = await engine.readForTests { e in (c: e.state.jobs[b.transferID].map { "\($0.state)" } ?? "nil", interests: e.state.jobs[b.transferID]?.interests.count ?? 0) }
        try await T.applyHeld([s.q] + fillers + [bMoved, p] + later, tag: "v4-off-\(seed)", s, visit: visit)
        let lane = await engine.readForTests { e in (followed: e.state.jobs[p.transferID].map { e.followedLane($0) }, own: e.state.jobs[p.transferID]?.lane) }
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let throttle = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C17C-OFFLINE-FAILFAST-LANE \(visit) at C's exit \(atC); N's lane \(lane); throttle=\(String(describing: throttle)) b=\(bResult) p=\(pResult)")
        #expect(bResult == .failure(.offline), "B gets the offline fail-fast (visit-first): \(bResult)")
        #expect(throttle != nil, "PROBE-C17C-OFFLINE-FAILFAST-LANE: N's 429 throttles the origin on N's own lane (visit-first)")
        #expect((try? pResult.get())?.byteSize == 16, "PROBE-C17C-OFFLINE-FAILFAST-LANE: P is served by N's retry (visit-first): \(pResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    // MARK: Part 3: new hunts

    /// PROBE-C17C-INBOUND-SUPERSEDED. T (100 kB, zz-a; user waiter A) and H (50 kB, zz-x; user waiter W) download. v3 moves
    /// zz-a to a new content Z and zz-x onto T's content; zz-a's entry comes before zz-x's, so a follow visits T before H.
    /// Visit-first: v3's visit of T finds every id of T moved and supersedes it (T's attempt abandoned), then H's visit
    /// moves W to T's content, where no job is left: a fresh job, whose download (T's next scripted step) serves W; A is
    /// served by Z. Behind the barrier T's held attempt then ends in a 404 (in visit-first that attempt no longer exists).
    /// Suspected sweep-first: `bringInbound` at the 404's deferral moves W onto T's failed job, so T's own visit later
    /// finds an id that stays (zz-x) and no longer supersedes it, and the drain's 404 answers W `notFound`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17C-INBOUND-SUPERSEDED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func inboundSuperseded(_ visit: LaneDropVisit) async throws {
        let (w, a, trace) = try await self.inboundScenario(visit, seed: 1_717_002, holderFirst: false)
        print("PROBE-C17C-INBOUND-SUPERSEDED \(visit) \(trace)")
        #expect((try? a.get())?.byteSize == 48, "A is served by Z (visit-first): \(a) \(trace)")
        #expect((try? w.get())?.byteSize == 100_000, "PROBE-C17C-INBOUND-SUPERSEDED: v3's visit superseded T before H's visit moved W to T's content, so a fresh job of T's content serves W (visit-first): \(w) \(trace)")
    }

    /// PROBE-C17C-INBOUND-SUPERSEDED-CONTROL. As above, with zz-x's entry before zz-a's: a follow visits H first, so W
    /// joins T's running attempt, T's visit moves only zz-a, and T's 404 answers W in both orders.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17C-INBOUND-SUPERSEDED-CONTROL", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func inboundSupersededControl(_ visit: LaneDropVisit) async throws {
        let (w, a, trace) = try await self.inboundScenario(visit, seed: 1_717_012, holderFirst: true)
        print("PROBE-C17C-INBOUND-SUPERSEDED-CONTROL \(visit) \(trace)")
        #expect((try? a.get())?.byteSize == 48, "A is served by Z (visit-first): \(a) \(trace)")
        #expect(w == .failure(.notFound), "W was on T at its 404 (visit-first): \(w) \(trace)")
    }

    /// PROBE-C17C-INBOUND-SUPERSEDED-CONSISTENT. As PROBE-C17C-INBOUND-SUPERSEDED, with a server that answers every
    /// request for T's content 404 (the visit-first engine's fresh job of T's content is asked again and gets the same 404).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17C-INBOUND-SUPERSEDED-CONSISTENT", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func inboundSupersededConsistent(_ visit: LaneDropVisit) async throws {
        let (w, a, trace) = try await self.inboundScenario(visit, seed: 1_717_022, holderFirst: false, consistent: true)
        print("PROBE-C17C-INBOUND-SUPERSEDED-CONSISTENT \(visit) \(trace)")
        #expect((try? a.get())?.byteSize == 48, "A is served by Z (visit-first): \(a) \(trace)")
        #expect(w == .failure(.notFound), "W gets T's content's 404 in both orders when the server answers alike: \(w) \(trace)")
    }

    @available(macOS 15.0, iOS 18.0, *)
    func inboundScenario(_ visit: LaneDropVisit, seed: UInt64, holderFirst: Bool, consistent: Bool = false) async throws -> (w: Result<AssetLocation, AssetError>, a: Result<AssetLocation, AssetError>, trace: String) {
        let (s, _) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 5, count: 50_000)
        let zBytes = EngineFixture.bytes(seed + 7, count: 48)
        let a = EngineHarness.onDemand("zz-a", tBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let aToZ = EngineHarness.onDemand("zz-a", zBytes)
        let xToT = EngineHarness.onDemand("zz-x", tBytes)
        try #require(xToT.transferID == a.transferID && x.transferID != a.transferID && aToZ.transferID != a.transferID && aToZ.transferID != x.transferID, "setup: three contents, v3's zz-x on T's")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        let v2Scenario = holderFirst ? [x, a] : [a, x]
        let v3Scenario = holderFirst ? [xToT, aToZ] : [aToZ, xToT]
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + v2Scenario + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, consistent ? [.hold, .fail(.permanentMissing(httpStatus: 404))] : [.hold, .stage(tBytes)])
        await s.harness.source.script(x.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(aToZ.transferID, [.stage(zBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let wWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .downloading }
        }
        try await T.applyHeld([s.q] + fillers + v3Scenario + later, tag: "v3-inbound-\(seed)", s, visit: visit)
        let atV3 = await engine.readForTests { e in
            (owed: e.followOwed, t: e.state.jobs[a.transferID].map { "\($0.state) e\($0.epoch) \($0.assets.sorted())" } ?? "nil", h: e.state.jobs[x.transferID].map { "\($0.state)" } ?? "nil")
        }
        // T's held attempt ends in a 404 (a terminal release: on a visit-first engine v3 abandoned that attempt when it
        // superseded T, and the release finds no held attempt of T).
        if consistent {
            // Every attempt of T's content gets the 404 (the scripted step after the hold).
            await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        } else {
            await s.harness.source.release(a.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
        }
        var atEnd = "-"
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            atEnd = await engine.readForTests { e in
                "owed \(e.followOwed) T \(e.state.jobs[a.transferID].map { "\($0.state) \($0.assets.sorted()) interests \($0.interests.count) end \(String(describing: $0.attemptEnd))" } ?? "nil") H \(e.state.jobs[x.transferID].map { "\($0.state)" } ?? "nil")"
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        let tStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
        return (wResult, aResult, "after v3 \(atV3); at the 404 \(atEnd); tStarts \(tStarts)")
    }

    /// PROBE-C17C-RR14-PUBLICATION-HOP (the fixer's RR-14, "an answer difference (S3-R16 1(a)) by analysis. Not probed").
    /// P (100 kB, zz-p; user waiter Q) publishes, its hash held; its staged bytes do not match the entry, so the
    /// publication ends in an integrity failure. H (50 kB, zz-x; user waiter W) downloads. v3 moves zz-x onto P's content,
    /// v4 moves it on to a third content Z (48 B), both while P's publication runs. Visit-first: v3's visit moves W onto
    /// the publishing P, v4's visit passes P, and P's integrity failure answers W (`integrityFailure`). Suspected
    /// sweep-first: `bringInbound` at the failure's deferral reads v4's copy (zz-x on Z, not P), so W stays on H, whose
    /// owed visit moves it to Z, which serves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17C-RR14-PUBLICATION-HOP", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func rr14PublicationHop(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_717_302
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let pBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrongBytes = EngineFixture.bytes(seed + 4, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 5, count: 50_000)
        let zBytes = EngineFixture.bytes(seed + 7, count: 48)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xToP = EngineHarness.onDemand("zz-x", pBytes)
        let xToZ = EngineHarness.onDemand("zz-x", zBytes)
        try #require(xToP.transferID == p.transferID && x.transferID != p.transferID && xToZ.transferID != p.transferID && xToZ.transferID != x.transferID, "setup: three contents, v3's zz-x on P's")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [p, x] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(p.transferID, [.hold, .stage(wrongBytes)])
        await s.harness.source.script(x.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(xToZ.transferID, [.stage(zBytes)])
        let qWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[p.transferID]?.state == .downloading }
        }
        let wWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .downloading }
        }
        let releaser = try await T.holdPublication(of: p.transferID, s, bulk: bulk)
        try await T.applyHeld([s.q] + fillers + [p, xToP] + later, tag: "v3-rr14-\(seed)", s, visit: visit)
        let atV3 = await engine.readForTests { e in
            (owed: e.followOwed, p: e.state.jobs[p.transferID].map { "\($0.state) \($0.assets.sorted()) i\($0.interests.count)" } ?? "nil", h: e.state.jobs[x.transferID].map { "\($0.state)" } ?? "nil")
        }
        try await T.applyHeld([s.q] + fillers + [p, xToZ] + later, tag: "v4-rr14-\(seed)", s, visit: visit)
        let atV4 = await engine.readForTests { e in
            (owed: e.followOwed, p: e.state.jobs[p.transferID].map { "\($0.state) \($0.assets.sorted()) i\($0.interests.count)" } ?? "nil", h: e.state.jobs[x.transferID].map { "\($0.state)" } ?? "nil")
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        var atFailure = "-"
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil }
            atFailure = await engine.readForTests { e in
                "owed \(e.followOwed) P \(e.state.jobs[p.transferID].map { "\($0.state) \($0.assets.sorted()) i\($0.interests.count)" } ?? "nil") H \(e.state.jobs[x.transferID].map { "\($0.state) i\($0.interests.count)" } ?? "nil")"
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await engine.awaitCondition { $0.state.jobs[p.transferID] == nil }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        let qResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: qWaiter) }
        let zStarts = await s.harness.source.starts.filter { $0.id == xToZ.transferID }.count
        print("PROBE-C17C-RR14-PUBLICATION-HOP \(visit) after v3 \(atV3); after v4 \(atV4); at the failure \(atFailure); w=\(wResult) q=\(qResult) zStarts=\(zStarts)")
        #expect(qResult == .failure(.integrityFailure), "Q gets P's integrity failure: \(qResult)")
        #expect(wResult == .failure(.integrityFailure), "PROBE-C17C-RR14-PUBLICATION-HOP: v3's visit joined W to P's publication and v4's visit passed it, so P's integrity failure answers W (visit-first): \(wResult); zStarts \(zStarts)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C17C-RETRY-AFTER-DATE. C (zz-b; user waiter B; interactive cap of `Retry-After` 30 s) downloads. v3 changes
    /// fillers only, so behind the barrier a follow is owed. C's attempt ends in a 503 whose `Retry-After` is an HTTP date
    /// 31 s ahead of the clock. The clock then moves on 5 s, with the follow (sweep-first) still owed.
    /// Visit-first: `retryLater` at the 503 reads 31 s, above the cap: `Backoff.delay` is `nil`, every interest is
    /// answered (B `serverUnavailable`). Suspected sweep-first: the drain's `retryLater` reads the date against the clock
    /// at the drain (26 s, within the cap), backs off, and C's retry serves B: an answer the visit-first engine never gave
    /// (`EventAfterFollow`'s doc: a `Retry-After` is captured at its arrival).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17C-RETRY-AFTER-DATE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func retryAfterDate(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_717_102
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: T.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .stage(cBytes)])
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        try await T.applyHeld([s.q] + fillers + [b] + later, tag: "v3-date-\(seed)", s, visit: visit)
        let date = s.time.now().addingTimeInterval(31)
        await s.harness.source.release(b.transferID, with: .failed(.transient(.serverError(httpStatus: 503), retryAfter: .date(date))))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[b.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        }
        let atExit = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[b.transferID].map { "\($0.state)" } ?? "nil") }
        // The clock moves on while the barrier holds (sweep-first); the same step in both orders.
        s.time.advance(by: 5)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let afterDrain = await engine.readForTests { e in e.state.jobs[b.transferID].map { "\($0.state) attempts \($0.attempts)" } ?? "nil" }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let cStarts = await s.harness.source.starts.filter { $0.id == b.transferID }.count
        print("PROBE-C17C-RETRY-AFTER-DATE \(visit) at C's exit \(atExit); after the drain \(afterDrain); b=\(bResult) cStarts=\(cStarts)")
        if case .failure(.serverUnavailable) = bResult {
        } else {
            Issue.record("PROBE-C17C-RETRY-AFTER-DATE: the 503's Retry-After (31 s at its arrival) is above the cap, so B is answered serverUnavailable (visit-first): \(bResult); after the drain \(afterDrain); cStarts \(cStarts)")
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }
}

/// Concurrent copies of the tests whose flakiness was found (reqs-1) or that cycle 17 added (S3-R16 1(d)).
@Suite("VerifyC17Stress")
struct VerifyC17Stress {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-STRESS-RETRY-END", .timeLimit(.minutes(3)), arguments: 0..<24)
    func retryEnd(_ copy: Int) async throws {
        try await EngineFollowBarrierTests().barrierRetriesAFailedPublicationWithNothingOfItsEnd()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-STRESS-UNLISTED", .timeLimit(.minutes(3)), arguments: 0..<6, LaneDropVisit.allCases)
    func unlisted(_ copy: Int, _ visit: LaneDropVisit) async throws {
        try await EngineFollowBarrierTests().barrierLeavesAnAdmittedUnlistedIDToTheVerdictThatWaits(visit)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-STRESS-HOP", .timeLimit(.minutes(3)), arguments: 0..<2, LaneDropVisit.allCases)
    func hop(_ copy: Int, _ visit: LaneDropVisit) async throws {
        for ending in EngineFollowBarrierTests.HopEnding.allCases {
            try await EngineFollowBarrierTests().barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent(visit, ending)
        }
        for when in EngineFollowBarrierTests.MappedBackVisit.allCases {
            try await EngineFollowBarrierTests().barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits(visit, when)
        }
        try await EngineFollowBarrierTests().barrierJoinsAnIDMappedBackAfterTheSpaceVerdictThatWaits(visit)
        try await EngineFollowBarrierTests().barrierLeavesAPassedPublicationsInterestToItsOutcome(visit)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("C17-STRESS-MOVED-BEFORE-AND-LANE", .timeLimit(.minutes(3)), arguments: 0..<2, LaneDropVisit.allCases)
    func movedBefore(_ copy: Int, _ visit: LaneDropVisit) async throws {
        try await EngineFollowBarrierTests().barrierAnswersAnIDMovedBackDuringAPublicationWithItsOutcome(visit)
        try await EngineFollowBarrierTests().barrierDecidesA429OnAnInterestTheDrainTakesOffBeforeAVerdict(visit)
        for ending in [EngineFollowBarrierTests.VerdictLaneEnding.retryAfterBeyondCap, .throttleFailFast, .offline, .insufficientSpace] {
            try await EngineFollowBarrierTests().barrierDecidesA429OnTheLaneAWaitingVerdictLeaves(visit, ending)
        }
    }
}
