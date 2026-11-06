import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probe (s3f close-out verification, cycle 15, requirements lens). Never committed. It needs the scratch drain
/// seam (`holdDrainFollowUps`, added to this scratch copy's sources only).
extension EngineFollowBarrierTests {
    /// PROBE-C15R-LANE-WALK (the surviving mutant `laneJobsWalkAlways`; S3-R19 item 2 exempts only a mutant that changes
    /// cost, not a decision, answer or state). Between two drain turns no follow is owed and the barrier is up, so a 429
    /// is decided on `followedLane`. C (100 kB: zz-a and zz-b, user waiters A and B) publishes when v3 moves zz-b to N
    /// (16 B), the content of zz-p, whose prefetch waiter P's job J downloads. The visit passes C (its publication began
    /// before the apply), so zz-b stays on C until the next follow (visit-first). C's verification read fails (EIO): a
    /// transient failure, retried. Two conditions elements arrive behind the barrier, so the drain takes two turns
    /// (`EventAfterFollow.endsDrainBatch`); the second turn is held. J then gets a 429 with Retry-After 60 s (above the user
    /// lane's 30 s cap, below the prefetch lane's 3,600 s). Visit-first, J's lane is its own (B's interest is on C): the
    /// 429 throttles the origin for 60 s.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15R-LANE-WALK", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func probeC15RLaneWalk(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_516_202
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID && p.transferID == bMoved.transferID, "setup: zz-a and zz-b share C; zz-p and v3's zz-b share N")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, p] + Self.laterFillers(seed + 3_000), etag: "v2")
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
        // C publishes, held at its first store unit, before v3's apply.
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, p] + later, tag: "v3-walk-\(seed)", s, visit: visit)
        // C's verification read fails (EIO): transient, retried (behind the barrier its verdict waits).
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
        // Two conditions elements (no change): behind the barrier each waits and ends a drain batch.
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
                cHoldsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, cPasses: e.state.jobs[a.transferID].map { e.passesOnVisit($0) },
                jLane: e.state.jobs[p.transferID].map { e.followedLane($0) }, jOwn: e.state.jobs[p.transferID]?.lane
            )
        }
        print("PROBE-C15R-LANE-WALK \(visit) between the drain turns: \(between)")
        try #require(between.cHoldsB && between.cPasses == false, "setup: C, retried, still holds zz-b and no longer publishes: \(between)")
        if visit == .sweepFollowsFirst {
            try #require(!between.owed && between.barrier && between.events == 1, "setup: no follow owed, one event still waits: \(between)")
        }
        // J's 429 (Retry-After 60 s) arrives now.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        print("PROBE-C15R-LANE-WALK \(visit) throttle at J's 429: \(String(describing: throttleAtArrival))")
        #expect(throttleAtArrival != nil, "PROBE-C15R-LANE-WALK: J's 429 throttles the origin on J's own (prefetch) lane; B's interest is on C until the next follow (visit-first): \(String(describing: throttleAtArrival))")
        await engine.readForTests { $0.releaseDrainFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        _ = await aWaiter.value
        _ = await bWaiter.value
        _ = await pWaiter.value
    }
}
