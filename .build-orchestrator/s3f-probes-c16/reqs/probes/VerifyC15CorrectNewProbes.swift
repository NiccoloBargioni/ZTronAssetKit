import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 15, correctness lens). Never committed.
///
/// Each runs in both orders (`LaneDropVisit`); every expectation is the visit-first outcome (S3-R16 1(a)).
@Suite("VerifyC15CorrectNew", .serialized)
struct VerifyC15CorrectNew {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    static func isSpaceFailure(_ event: EventAfterFollow) -> Bool {
        if case .spaceFailure = event {
            return true
        }
        return false
    }

    /// PROBE-C15C-ENOSPC-PASSED: a publication begun before v3's apply fails with ENOSPC (the store's placement rename)
    /// while v3's follow still owes C's visit, before the follow's turn that finds C.
    /// Visit-first: v3's visit met C verifying and passed zz-b (B stays on C); the ENOSPC retries C (32 MB free); the
    /// retry's bytes fail their checksum, so A and B are answered `integrityFailure`.
    /// Behind the barrier the ENOSPC verdict waits as `.spaceFailure`, which records no `VerdictAfterFollow`, so
    /// `passesOnVisit` is false for the failed C and the visit moves zz-b onto N as for a download.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15C-ENOSPC-PASSED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func enospcPassed(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_002
        let (s, bulk) = try await EngineFollowBarrierTests.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes), .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let releaser = try await EngineFollowBarrierTests.holdPublication(of: a.transferID, s, bulk: bulk)
        try await EngineFollowBarrierTests.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved] + EngineFollowBarrierTests.laterFillers(seed + 6_000), tag: "v3-enospc-\(seed)", s, visit: visit)
        let atApply = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, reroute: e.state.jobs[a.transferID]?.rerouteOnPass)
        }
        print("PROBE-C15C-ENOSPC-PASSED \(visit) after the apply: \(atApply)")
        s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .noSpace))
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.eventsAfterFollow.contains(where: VerifyC15CorrectNew.isSpaceFailure) }
            let waiting = await engine.readForTests { e in
                (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, verdict: e.state.verdictsAfterFollow[a.transferID], cOwedVisit: e.state.followOrder[e.state.followNext...].contains(a.transferID), holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true)
            }
            print("PROBE-C15C-ENOSPC-PASSED \(visit) the ENOSPC waits: \(waiting)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let afterDrain = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, n: e.state.jobs[bMoved.transferID]?.state)
        }
        print("PROBE-C15C-ENOSPC-PASSED \(visit) after the drain: \(afterDrain)")
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let cStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        print("PROBE-C15C-ENOSPC-PASSED \(visit) a=\(aResult) b=\(bResult) cStarts=\(cStarts)")
        #expect(aResult == .failure(.integrityFailure), "A gets the retry's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "PROBE-C15C-ENOSPC-PASSED: B rode C's retry, as the follow passed C publishing at the apply (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineFollowBarrierTests.finishHeld(s)
    }

    /// PROBE-C15C-VERDICT-ACROSS-APPLY: C (zz-a, zz-b; users A and B) gets a 404 while v3's follow is owed (v3 changes
    /// only fillers); then v4 moves zz-b to N while the follow is still owed.
    /// Visit-first: the 404 answered A and B `notFound` at its arrival; v4 later found nobody on zz-b.
    /// Behind the barrier the 404's verdict waits; v4's visit meets C failed with a download's verdict and moves zz-b
    /// onto N before the drain answers A.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15C-VERDICT-ACROSS-APPLY", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func verdictAcrossApply(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_602
        let (s, _) = try await EngineFollowBarrierTests.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = EngineFollowBarrierTests.laterFillers(seed + 6_000)
        try await EngineFollowBarrierTests.applyHeld([s.q] + fillers + [a, b] + later, tag: "v3-across-\(seed)", s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        }
        let at404 = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, verdict: e.state.verdictsAfterFollow[a.transferID])
        }
        print("PROBE-C15C-VERDICT-ACROSS-APPLY \(visit) after the 404: \(at404)")
        try await EngineFollowBarrierTests.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v4-across-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C15C-VERDICT-ACROSS-APPLY \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.notFound), "A gets C's 404 (visit-first): \(aResult)")
        #expect(bResult == .failure(.notFound), "PROBE-C15C-VERDICT-ACROSS-APPLY: B gets C's 404, answered before v4 existed (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineFollowBarrierTests.finishHeld(s)
    }

    /// PROBE-C15C-STALE-REROUTE: `Job.rerouteOnPass` is never cleared by the visit that uses it. C (zz-a, zz-b; users A
    /// and B). v3 moves zz-b to N (held). C's publication begins (held) while v3's follow is owed, so behind the barrier
    /// `rerouteOnPass == [zz-b]`. v4, applied while v3's follow is still owed, maps zz-b back to C's content: the owed visit
    /// finds nothing moved. v5, after the barrier and while the same publication still verifies, moves zz-b to N2. C's
    /// bytes then fail their checksum.
    /// Visit-first: v3's visit moved B to N while C downloaded; C's publication began with no follow owed (empty set);
    /// v4's visit superseded N and B re-joined C, publishing; v5's follow passed C, so B got C's `integrityFailure`.
    /// Behind the barrier, v5's visit re-routes zz-b at once from the stale set, and B is served N2.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15C-STALE-REROUTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func staleReroute(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_902
        let (s, bulk) = try await EngineFollowBarrierTests.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let n2Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        let bMoved2 = EngineHarness.onDemand("zz-b", n2Bytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        await s.harness.source.script(bMoved2.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = EngineFollowBarrierTests.laterFillers(seed + 6_000)
        try await EngineFollowBarrierTests.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-stale-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
            }
        }
        let releaser = try await EngineFollowBarrierTests.holdPublication(of: a.transferID, s, bulk: bulk)
        let atPublish = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, reroute: e.state.jobs[a.transferID]?.rerouteOnPass, n: e.state.jobs[bMoved.transferID]?.state)
        }
        print("PROBE-C15C-STALE-REROUTE \(visit) C publishing: \(atPublish)")
        // v4 maps zz-b back to C's content.
        try await EngineFollowBarrierTests.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-stale-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let atV4 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, reroute: e.state.jobs[a.transferID]?.rerouteOnPass, n: e.state.jobs[bMoved.transferID]?.state, barrier: e.followBarrier)
        }
        print("PROBE-C15C-STALE-REROUTE \(visit) after v4: \(atV4)")
        // v5, applied while the same publication still verifies, moves zz-b to N2: its follow passes C in both orders.
        try await EngineFollowBarrierTests.applyHeld([s.q] + fillers + [a, bMoved2] + later, tag: "v5-stale-\(seed)", s, visit: .followVisitedFirst)
        let atV5 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID), n2: e.state.jobs[bMoved2.transferID]?.state)
        }
        print("PROBE-C15C-STALE-REROUTE \(visit) after v5: \(atV5)")
        try #require(atV5.c == .verifying, "setup: the same publication still verifies at v5: \(atV5)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C15C-STALE-REROUTE \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "PROBE-C15C-STALE-REROUTE: v5's follow passed C, publishing, with zz-b (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineFollowBarrierTests.finishHeld(s)
    }
}
