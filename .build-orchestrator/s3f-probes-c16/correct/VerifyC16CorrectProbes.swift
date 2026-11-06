import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 16, correctness lens). Never committed.
///
/// Part 1 re-runs, adapted to cycle 16's names only, every scenario the cycle-15 verifiers reported blocking; every
/// expectation is the visit-first outcome. Part 2 hunts the classes cycle 16's mechanism (`appliesFollowed`,
/// `Job.attemptEnd`, `rerouteOnVisit`, `followAfterVerdict`, `verdictAnswers`) may still miss. Each runs in both orders.
@Suite("VerifyC16Correct", .serialized)
struct VerifyC16Correct {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias T = EngineFollowBarrierTests

    static func isSpaceFailure(_ event: EventAfterFollow) -> Bool {
        if case .spaceFailure = event {
            return true
        }
        return false
    }

    // MARK: Part 1: the cycle-15 blocking scenarios

    /// reqs-1, PROBE-C15R-REROUTE-STALE (seed 1_515_002).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C16-REPRO-REROUTE-STALE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func reproRerouteStale(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_002
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed)
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
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + T.laterFillers(seed + 3_000), etag: "v2")
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
        let later = T.laterFillers(seed + 6_000)
        try await T.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-stale-\(seed)", s, visit: visit)
        let releaser = try await T.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
        let atV3 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), reroute: e.state.jobs[a.transferID]?.rerouteOnPass?.sorted())
        }
        print("C16-REPRO-REROUTE-STALE \(visit) after v3: \(atV3)")
        try #require(atV3.c == .verifying && atV3.cAssets == [a.identifier], "setup: C publishes with zz-a only, B on N: \(atV3)")
        try await T.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-stale-\(seed)", s, visit: .followVisitedFirst)
        let atV4 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), reroute: e.state.jobs[a.transferID]?.rerouteOnPass?.sorted())
        }
        print("C16-REPRO-REROUTE-STALE \(visit) after v4: \(atV4)")
        try #require(atV4.c == .verifying && atV4.cAssets == [a.identifier, b.identifier], "setup: B rejoined C, which still publishes: \(atV4)")
        try await T.applyHeld([s.q] + fillers + [a, bMoved2] + later, tag: "v5-stale-\(seed)", s, visit: .followVisitedFirst)
        let atV5 = await engine.readForTests { e in (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), n2: e.state.jobs[bMoved2.transferID]?.state) }
        print("C16-REPRO-REROUTE-STALE \(visit) after v5: \(atV5)")
        try #require(atV5.c == .verifying, "setup: the same publication still verifies at v5: \(atV5)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("C16-REPRO-REROUTE-STALE \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "C16-REPRO-REROUTE-STALE: v5's follow passed C, publishing (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// reqs-2, PROBE-C15R-VERDICT-LATER-APPLY (seed 1_515_302).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C16-REPRO-VERDICT-LATER-APPLY", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func reproVerdictLaterApply(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_302
        let (s, _) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        try await T.applyHeld([s.q] + fillers + [a, b] + later, tag: "v3-verdict-\(seed)", s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let atFail = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, verdict: e.state.verdictsAfterFollow[a.transferID], end: e.state.jobs[a.transferID]?.attemptEnd)
        }
        print("C16-REPRO-VERDICT-LATER-APPLY \(visit) after the 404: \(atFail)")
        if visit == .sweepFollowsFirst {
            try #require(atFail.owed && atFail.verdict != nil, "setup: the 404's verdict waits for v3's follow: \(atFail)")
        }
        try await T.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v4-verdict-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("C16-REPRO-VERDICT-LATER-APPLY \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.notFound), "A gets C's 404 (visit-first): \(aResult)")
        #expect(bResult == .failure(.notFound), "C16-REPRO-VERDICT-LATER-APPLY: B gets C's 404, answered before v4 existed (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// correct-3, PROBE-C15C-VERDICT-ACROSS-APPLY (seed 1_515_602).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C16-REPRO-VERDICT-ACROSS-APPLY", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func reproVerdictAcrossApply(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_602
        let (s, _) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + T.laterFillers(seed + 3_000), etag: "v2")
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
        let later = T.laterFillers(seed + 6_000)
        try await T.applyHeld([s.q] + fillers + [a, b] + later, tag: "v3-across-\(seed)", s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        }
        try await T.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v4-across-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("C16-REPRO-VERDICT-ACROSS-APPLY \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.notFound), "A gets C's 404 (visit-first): \(aResult)")
        #expect(bResult == .failure(.notFound), "C16-REPRO-VERDICT-ACROSS-APPLY: B gets C's 404 (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// correct-4, PROBE-C15C-STALE-REROUTE (seed 1_515_902).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C16-REPRO-STALE-REROUTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func reproStaleReroute(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_902
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed)
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
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + T.laterFillers(seed + 3_000), etag: "v2")
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
        let later = T.laterFillers(seed + 6_000)
        try await T.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-stale-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
            }
        }
        let releaser = try await T.holdPublication(of: a.transferID, s, bulk: bulk)
        try await T.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-stale-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let atV4 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, reroute: e.state.jobs[a.transferID]?.rerouteOnPass, rerouteFor: e.state.jobs[a.transferID]?.rerouteFor, ended: e.state.followsEnded)
        }
        print("C16-REPRO-STALE-REROUTE \(visit) after v4: \(atV4)")
        try await T.applyHeld([s.q] + fillers + [a, bMoved2] + later, tag: "v5-stale-\(seed)", s, visit: .followVisitedFirst)
        let atV5 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID), n2: e.state.jobs[bMoved2.transferID]?.state)
        }
        print("C16-REPRO-STALE-REROUTE \(visit) after v5: \(atV5)")
        try #require(atV5.c == .verifying, "setup: the same publication still verifies at v5: \(atV5)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("C16-REPRO-STALE-REROUTE \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "C16-REPRO-STALE-REROUTE: v5's follow passed C, publishing, with zz-b (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// correct-1, PROBE-C15C-ENOSPC-PASSED (seed 1_515_002).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C16-REPRO-ENOSPC-PASSED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func reproEnospcPassed(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_002
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + T.laterFillers(seed + 3_000), etag: "v2")
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
        let releaser = try await T.holdPublication(of: a.transferID, s, bulk: bulk)
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved] + T.laterFillers(seed + 6_000), tag: "v3-enospc-\(seed)", s, visit: visit)
        s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .noSpace))
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.eventsAfterFollow.contains(where: VerifyC16Correct.isSpaceFailure) }
            let waiting = await engine.readForTests { e in
                (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, end: e.state.jobs[a.transferID]?.attemptEnd, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true)
            }
            print("C16-REPRO-ENOSPC-PASSED \(visit) the ENOSPC waits: \(waiting)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let cStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        print("C16-REPRO-ENOSPC-PASSED \(visit) a=\(aResult) b=\(bResult) cStarts=\(cStarts)")
        #expect(aResult == .failure(.integrityFailure), "A gets the retry's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "C16-REPRO-ENOSPC-PASSED: B rode C's retry (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// `setUpHeldPublications` with a stepped metadata executor too (the cycle-15 correctness verifier's).
    @available(macOS 15.0, iOS 18.0, *)
    static func setUpWindow(seed: UInt64, tuning: SyncTuning = SyncTuning()) async throws -> (FollowBarrier.Setup, SteppedBlockingExecutor, SteppedBlockingExecutor) {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let meta = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, tuning: tuning, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), metadata: meta, bulk: bulk, fileSystem: fileSystem)
        let qBytes = EngineFixture.bytes(seed, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await harness.engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        return (FollowBarrier.Setup(time: time, fileSystem: fileSystem, harness: harness, q: q), bulk, meta)
    }

    /// correct-2, PROBE-C15C-INTEGRITY-WINDOW (seed 1_516_302).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C16-REPRO-INTEGRITY-WINDOW", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func reproIntegrityWindow(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_516_302
        let (s, bulk, meta) = try await Self.setUpWindow(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let releaser = try await T.holdPublication(of: a.transferID, s, bulk: bulk)
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved] + T.laterFillers(seed + 6_000), tag: "v3-window-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await meta.setHolding(true)
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            var window = false
            for _ in 0..<400 {
                let now = await engine.readForTests { e -> (failed: Bool, verdict: Bool) in
                    let failed: Bool
                    if case .failed? = e.state.jobs[a.transferID]?.state { failed = true } else { failed = false }
                    return (failed, e.state.verdictsAfterFollow[a.transferID] != nil)
                }
                let held = await meta.heldUnits
                if now.verdict {
                    break
                }
                if now.failed, !held.isEmpty {
                    window = true
                    break
                }
                if held.isEmpty {
                    try await meta.requireHeldUnits(atLeast: 1)
                    continue
                }
                _ = await meta.releaseNext()
            }
            let inWindow = await engine.readForTests { e in
                (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, end: e.state.jobs[a.transferID]?.attemptEnd, applies: e.state.appliesFollowed, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true)
            }
            print("C16-REPRO-INTEGRITY-WINDOW \(visit) window=\(window) state=\(inWindow)")
            try #require(window, "setup: reached the window between C's failure and its deferred verdict")
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
            let visited = await engine.readForTests { e in
                (c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, n: e.state.jobs[bMoved.transferID]?.state, barrier: e.followBarrier)
            }
            print("C16-REPRO-INTEGRITY-WINDOW \(visit) after the follow: \(visited)")
            await meta.setHolding(false)
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("C16-REPRO-INTEGRITY-WINDOW \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "C16-REPRO-INTEGRITY-WINDOW: the follow passed C publishing at the apply (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// reqs-4/correct-6, PROBE-C15R-SPACE-EPOCH (seed 1_515_602): passes at HEAD; run against the dropped epoch check.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C16-REPRO-SPACE-EPOCH", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func reproSpaceEpoch(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_515_602)
        let engine = s.engine
        let cBytes = Data(repeating: 0xA7, count: 1_000_000)
        let xBytes = EngineFixture.bytes(1_515_603, count: 40)
        let nBytes = EngineFixture.bytes(1_515_604, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        let xMoved = EngineHarness.onDemand("zz-x", cBytes)
        try #require(xMoved.transferID == a.transferID, "setup: v3's zz-x is C's content")
        let members = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(1_515_700 + UInt64($0), count: 16)) }
        let movedMembers = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(1_516_100 + UInt64($0), count: 16)) }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_516_500) + members + [a, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        for entry in members + movedMembers {
            await s.harness.source.script(entry.transferID, [.hold])
        }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { current in members.allSatisfy { current.state.jobs[$0.transferID] != nil } }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_516_900) + movedMembers + [aMoved, xMoved], s, visit: visit)
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, xMoved) }
            try await T.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
            await s.harness.source.release(a.transferID, with: .failed(.insufficientSpace(requiredBytes: 20_000_000)))
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.contains(where: VerifyC16Correct.isSpaceFailure) || e.state.jobs[a.transferID]?.state != .downloading && !e.followBarrier
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        } else {
            try await T.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
        }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("C16-REPRO-SPACE-EPOCH \(visit) x=\(xResult) a=\(aResult)")
        #expect((try? xResult.get())?.byteSize == Int64(cBytes.count), "C16-REPRO-SPACE-EPOCH: zz-x's caller is served C's content by a new job (visit-first): \(xResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A is served N (visit-first): \(aResult)")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }

    /// reqs-3, PROBE-C15R-LANE-WALK (seed 1_516_202), on the committed drain seam.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C16-REPRO-LANE-WALK", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func reproLaneWalk(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_516_202
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: T.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID && p.transferID == bMoved.transferID, "setup")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, p] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes), .hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .hold, .stage(nBytes)])
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
        let releaser = try await T.holdPublication(of: a.transferID, s, bulk: bulk)
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        try await T.applyHeld([s.q] + fillers + [a, bMoved, p] + later, tag: "v3-walk-\(seed)", s, visit: visit)
        releaser.cancel()
        await releaser.value
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { e in
                if case .failed = e.state.jobs[a.transferID]?.state { return true }
                return false
            }
        }
        await s.harness.conditions.send(.unrestricted)
        await s.harness.conditions.send(.unrestricted)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.filter { event in
                    if case .conditions = event { return true }
                    return false
                }.count == 2
            }
            await engine.readForTests { e in
                e.holdDrainFollowUps()
                e.releaseFollowFollowUps()
            }
            await engine.awaitCondition { !$0.followOwed && $0.state.drainFollowUpWaiting }
        }
        let between = await engine.readForTests { e in
            (
                owed: e.followOwed, barrier: e.followBarrier, events: e.state.eventsAfterFollow.count, c: e.state.jobs[a.transferID]?.state,
                cHoldsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, cReroute: e.state.jobs[a.transferID].map { e.rerouteOnVisit($0) },
                jLane: e.state.jobs[p.transferID].map { e.followedLane($0) }, jOwn: e.state.jobs[p.transferID]?.lane
            )
        }
        print("C16-REPRO-LANE-WALK \(visit) between the drain turns: \(between)")
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        print("C16-REPRO-LANE-WALK \(visit) throttle at J's 429: \(String(describing: throttleAtArrival))")
        #expect(throttleAtArrival != nil, "C16-REPRO-LANE-WALK: J's 429 throttles the origin on J's own (prefetch) lane (visit-first): \(String(describing: throttleAtArrival))")
        await engine.readForTests { $0.releaseDrainFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
        _ = await aWaiter.value
        _ = await bWaiter.value
        _ = await pWaiter.value
    }

    // MARK: Part 2: new hunts

    /// PROBE-C16C-VERDICT-MAPPED-BACK. C (zz-a, zz-b; user waiters A and B) downloads. v3 moves zz-b to N (held). C gets
    /// a 404 while v3's follow is owed (sweep-first: the verdict waits, `rerouteOnPass == [zz-b]`, the ids moved before it).
    /// v4 maps zz-b back to C's content before the follow visits C.
    /// Visit-first: v3's visit moved B onto N while C downloaded; the 404 answered A alone (C removed); v4's visit
    /// superseded N and moved B back to C's content, a fresh job, whose download serves B (C's next script step).
    /// Sweep-first: the visit finds zz-b on C's content again (moved nothing), the set is spent, and the drain's 404
    /// answers A and B.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16C-VERDICT-MAPPED-BACK", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
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
        // v3 moves zz-b to N.
        try await T.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-back-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
            }
        }
        // C's 404.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        }
        let at404 = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, reroute: e.state.jobs[a.transferID]?.rerouteOnPass?.sorted(), end: e.state.jobs[a.transferID]?.attemptEnd, n: e.state.jobs[bMoved.transferID]?.state)
        }
        print("PROBE-C16C-VERDICT-MAPPED-BACK \(visit) after the 404: \(at404)")
        // v4 maps zz-b back to C's content.
        try await T.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-back-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let afterV4 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), n: e.state.jobs[bMoved.transferID]?.state, waiterB: e.state.waiters.values.filter { $0.asset == b.identifier }.map(\.transfer))
        }
        print("PROBE-C16C-VERDICT-MAPPED-BACK \(visit) after v4: \(afterV4)")
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let cStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        print("PROBE-C16C-VERDICT-MAPPED-BACK \(visit) a=\(aResult) b=\(bResult) cStarts=\(cStarts)")
        #expect(aResult == .failure(.notFound), "A gets C's 404 (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "PROBE-C16C-VERDICT-MAPPED-BACK: B was on N at the 404 and v4 moved it back to a fresh job of C's content, which serves it (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16C-RR11-RETRY-LANE (the draft's RR-11, "a retry whose Retry-After exceeds the lane's cap", unprobed there).
    /// Interactive retries are short (`shortInteractiveRetry`: Retry-After cap 30 s). C (zz-b) downloads for B, a user
    /// waiter; N (zz-p) for P, a prefetch waiter. v3 changes only fillers (a follow is owed). C gets a 503 with Retry-After
    /// 120 s. v4 moves zz-b onto N's content. N then gets a 429 with Retry-After 60 s.
    /// Visit-first: C's 503 found Retry-After above the user lane's cap and answered B `serverUnavailable(120)` (C ended);
    /// v4 moved nobody; N's 429 was decided on N's own (prefetch) lane: the origin throttled 60 s, N parked, retried after
    /// the throttle and served P.
    /// Sweep-first: `followedLane(N)` counts B's interest, which the drain would move onto N after C's waiting retry
    /// verdict (`verdictAnswers` reads only the attempt cap), so N's 429 is decided on the user lane: `.exhausted`, the
    /// origin unthrottled, and P answered `serverUnavailable(60)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16C-RR11-RETRY-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
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
        // v3: only fillers change; a follow is owed (sweep-first).
        try await T.applyHeld([s.q] + fillers + [b, p] + later, tag: "v3-rr11-\(seed)", s, visit: visit)
        // C's 503 with Retry-After 120 s.
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[b.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID] == nil }
        }
        let atRetry = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[b.transferID]?.state, end: e.state.jobs[b.transferID]?.attemptEnd, attempts: e.state.jobs[b.transferID]?.attempts)
        }
        print("PROBE-C16C-RR11-RETRY-LANE \(visit) after C's 503: \(atRetry)")
        // v4 moves zz-b onto N's content.
        try await T.applyHeld([s.q] + fillers + [bMoved, p] + later, tag: "v4-rr11-\(seed)", s, visit: visit)
        let lane = await engine.readForTests { e in (followed: e.state.jobs[p.transferID].map { e.followedLane($0) }, own: e.state.jobs[p.transferID]?.lane, owed: e.followOwed, barrier: e.followBarrier) }
        print("PROBE-C16C-RR11-RETRY-LANE \(visit) N's lane before its 429: \(lane)")
        // N's 429 with Retry-After 60 s.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let throttle = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        print("PROBE-C16C-RR11-RETRY-LANE \(visit) throttle at N's 429: \(String(describing: throttle))")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C16C-RR11-RETRY-LANE \(visit) b=\(bResult) p=\(pResult)")
        #expect((try? bResult.get()) == nil, "B gets C's 503 answer (visit-first): \(bResult)")
        #expect(throttle != nil, "PROBE-C16C-RR11-RETRY-LANE: N's 429 throttles the origin on N's own (prefetch) lane (visit-first): \(String(describing: throttle))")
        #expect((try? pResult.get())?.byteSize == 16, "PROBE-C16C-RR11-RETRY-LANE: P is served by N's retry after the throttle (visit-first): \(pResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16C-THROTTLE-FAILFAST-LANE (a fourth partial answer `verdictAnswers` counts as none: a 429 park's fail-fast,
    /// not in the draft's RR-11). As above, but C gets a 429 with Retry-After 10 s (within the user lane's 30 s cap, beyond
    /// `interactiveMaxWait`).
    /// Visit-first: C's 429 throttled the origin 10 s and parked C; the park answered B `serverUnavailable` (10 s > 2 s);
    /// v4 moved nobody; N's 429 was decided on N's own (prefetch) lane: throttled 60 s, N parked, retried, P served.
    /// Sweep-first: `verdictAnswers(.throttle(.until))` is false, so B counts as moving onto N after C's verdict: N's 429
    /// is decided on the user lane, `.exhausted`, and P is answered `serverUnavailable(60)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16C-THROTTLE-FAILFAST-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
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
        // C's 429 with Retry-After 10 s.
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[b.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        }
        let atC = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[b.transferID]?.state, interests: e.state.jobs[b.transferID]?.interests.count, throttle: e.state.remote.flatMap { e.state.throttles[$0.originID] })
        }
        print("PROBE-C16C-THROTTLE-FAILFAST-LANE \(visit) after C's 429: \(atC)")
        try await T.applyHeld([s.q] + fillers + [bMoved, p] + later, tag: "v4-ff-\(seed)", s, visit: visit)
        let lane = await engine.readForTests { e in (followed: e.state.jobs[p.transferID].map { e.followedLane($0) }, own: e.state.jobs[p.transferID]?.lane, owed: e.followOwed) }
        print("PROBE-C16C-THROTTLE-FAILFAST-LANE \(visit) N's lane before its 429: \(lane)")
        let before = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let after = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        print("PROBE-C16C-THROTTLE-FAILFAST-LANE \(visit) throttle before=\(String(describing: before)) after N's 429=\(String(describing: after))")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C16C-THROTTLE-FAILFAST-LANE \(visit) b=\(bResult) p=\(pResult)")
        #expect((try? bResult.get()) == nil, "B gets the throttle's fail-fast answer (visit-first): \(bResult)")
        #expect(after != before, "PROBE-C16C-THROTTLE-FAILFAST-LANE: N's 429 extends the origin's throttle on N's own lane (visit-first)")
        #expect((try? pResult.get())?.byteSize == 16, "PROBE-C16C-THROTTLE-FAILFAST-LANE: P is served by N's retry (visit-first): \(pResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16C-INTERMEDIATE-HOP. C (zz-b; user waiter B) and N (zz-p; user waiter P) download. v3 moves zz-b onto N's
    /// content. N gets a 404 while v3's follow is owed. v4 moves zz-b on to a third content M before the follow visits C.
    /// Visit-first: v3's visit superseded C and moved B onto N; N's 404 answered P and B `notFound`; v4 moved nobody.
    /// Sweep-first (suspected): every pass compares with the copy as it stands when it runs, so the visit moves B from C
    /// straight to M; N's waiting verdict answers P alone and M's download serves B.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16C-INTERMEDIATE-HOP", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
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
        // v3 moves zz-b onto N's content.
        try await T.applyHeld([s.q] + fillers + [bToN, p] + later, tag: "v3-hop-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[b.transferID] == nil && $0.state.jobs[p.transferID]?.interests.count == 2 }
        }
        let atV3 = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[b.transferID]?.state, nInterests: e.state.jobs[p.transferID]?.interests.count)
        }
        print("PROBE-C16C-INTERMEDIATE-HOP \(visit) after v3: \(atV3)")
        // N's 404.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        }
        // v4 moves zz-b on to M.
        try await T.applyHeld([s.q] + fillers + [bToM, p] + later, tag: "v4-hop-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let afterV4 = await engine.readForTests { e in
            (c: e.state.jobs[b.transferID]?.state, n: e.state.jobs[p.transferID]?.state, m: e.state.jobs[bToM.transferID]?.state)
        }
        print("PROBE-C16C-INTERMEDIATE-HOP \(visit) after v4: \(afterV4)")
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let mStarts = await s.harness.source.starts.filter { $0.id == bToM.transferID }.count
        print("PROBE-C16C-INTERMEDIATE-HOP \(visit) b=\(bResult) p=\(pResult) mStarts=\(mStarts)")
        #expect(pResult == .failure(.notFound), "P gets N's 404 (visit-first): \(pResult)")
        #expect(bResult == .failure(.notFound), "PROBE-C16C-INTERMEDIATE-HOP: B was on N at its 404 (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C16C-INTERMEDIATE-HOP-SERVED. As PROBE-C16C-INTERMEDIATE-HOP, but N's attempt completes between v3 and v4
    /// (no verdict waits). Visit-first: v3's visit moved B onto N, whose publication served B N's 16 bytes; v4 moved
    /// nobody. Sweep-first (suspected): B stays on C until the visit, which moves it straight to M, whose download serves
    /// B M's 48 bytes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16C-INTERMEDIATE-HOP-SERVED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
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
        // N's attempt completes.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let atN = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[b.transferID]?.state, n: e.state.jobs[p.transferID]?.state) }
        print("PROBE-C16C-INTERMEDIATE-HOP-SERVED \(visit) after N's publication: \(atN) p=\(pResult)")
        try await T.applyHeld([s.q] + fillers + [bToM, p] + later, tag: "v4-served-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let mStarts = await s.harness.source.starts.filter { $0.id == bToM.transferID }.count
        print("PROBE-C16C-INTERMEDIATE-HOP-SERVED \(visit) b=\(bResult) mStarts=\(mStarts)")
        #expect((try? pResult.get())?.byteSize == 16, "P is served N (visit-first): \(pResult)")
        #expect((try? bResult.get())?.byteSize == 16, "PROBE-C16C-INTERMEDIATE-HOP-SERVED: B was on N at its publication and is served N's content (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }
}
