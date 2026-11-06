import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The lane a 429 reads between two drain turns (Stage 3 close-out cycle 16; the cycle-15 requirements verifier's
/// PROBE-C15R-LANE-WALK, ruling S3-R19 item 2). Once the follow has ended no visit is owed, so `followedLane` counts no
/// interest a visit would move: a job the follow passed keeps its moved ids until the next follow, as a visit-first
/// engine's job kept them. While a verdict still waits the walk over the other jobs runs (it counts the ids the drain
/// moves after a verdict), and an owed visit's ids are not among them. The test runs in both orders (`LaneDropVisit`)
/// with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// A 429 that arrives between two drain turns, with another job's verdict still waiting, is decided on the lane of
    /// the interests its job holds, not on an interest a passed job keeps until the next follow (PROBE-C15R-LANE-WALK):
    /// C (100 kB: zz-a and zz-b, user waiters A and B) publishes when v3 moves zz-b to N (16 B), the content of zz-p,
    /// whose prefetch waiter P's job J downloads; Z (zz-z, a user waiter) downloads too. v3's visit passes C (its
    /// publication began before the apply), so zz-b stays on C until the next follow. C's verification read fails (EIO):
    /// transient, retried. Behind the barrier a conditions element then waits and ends the drain's first batch, and Z's
    /// 404 waits after it, so the drain's second turn (held) still owes Z's verdict. J then gets a 429 with `Retry-After`
    /// 60 s (above the user lane's 30 s cap, below the prefetch lane's 3,600 s). Visited first, J's lane was its own (B's
    /// interest was on C), and the 429 throttled the origin for 60 s.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 between two drain turns reads no interest a passed job keeps until the next follow (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429BetweenDrainTurnsOnItsJobsOwnInterests(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_616_602
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let zBytes = EngineFixture.bytes(seed + 7, count: 20)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let z = EngineHarness.onDemand("zz-z", zBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID && p.transferID == bMoved.transferID, "setup: zz-a and zz-b share C; zz-p and v3's zz-b share N")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, p, z] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes), .hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .hold, .stage(nBytes)])
        await s.harness.source.script(z.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        let zWaiter = Task { await engine.awaitAsset(z.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading && $0.state.jobs[z.transferID]?.state == .downloading }
        }
        // C publishes, held at its first store unit, before v3's apply: v3's visit passes it.
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved, p, z] + Self.laterFillers(seed + 6_000)
        try await Self.applyHeld(v3, tag: "v3-drain-lane-\(seed)", s, visit: visit)
        // C's verification read fails (EIO): transient, retried (behind the barrier its verdict waits).
        releaser.cancel()
        await releaser.value
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { e in
                if case .failed = e.state.jobs[a.transferID]?.state {
                    return true
                }
                return false
            }
        }
        // A conditions element (no change): behind the barrier it waits and ends the drain's first batch.
        await s.harness.conditions.send(.unrestricted)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.contains { event in
                    if case .conditions = event {
                        return true
                    }
                    return false
                }
            }
        }
        // Z's 404 arrives after it: behind the barrier its verdict waits for the drain's second turn.
        await s.harness.source.release(z.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[z.transferID] != nil }
            await engine.readForTests { e in
                e.holdDrainFollowUps()
                e.releaseFollowFollowUps()
            }
            await engine.awaitCondition { !$0.followOwed && $0.state.drainFollowUpWaiting }
        } else {
            await engine.awaitCondition { $0.state.jobs[z.transferID] == nil }
        }
        let between = await engine.readForTests { e in
            (
                owed: e.followOwed, barrier: e.followBarrier, events: e.state.eventsAfterFollow.count, zWaits: e.state.verdictsAfterFollow[z.transferID] != nil,
                cHoldsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, cAlive: e.state.jobs[a.transferID]?.interests.count == 2
            )
        }
        try #require(between.cHoldsB && between.cAlive, "setup: C, retried, still holds zz-b and both users: \(between)")
        if visit == .sweepFollowsFirst {
            try #require(!between.owed && between.barrier && between.events == 1 && between.zWaits, "setup: no follow owed, Z's verdict still waits: \(between)")
        }
        // J's 429 (Retry-After 60 s) arrives now.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let throttle = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        #expect(throttle != nil, "J's 429 throttles the origin on J's own (prefetch) lane: B's interest is on C until the next follow (visit-first): \(String(describing: throttle))")
        await engine.readForTests { $0.releaseDrainFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let zResult = await zWaiter.value
        #expect(zResult == .failure(.notFound), "Z gets its 404: \(zResult)")
        await Self.finishHeld(s)
        _ = await aWaiter.value
        _ = await bWaiter.value
        _ = await pWaiter.value
    }
}
