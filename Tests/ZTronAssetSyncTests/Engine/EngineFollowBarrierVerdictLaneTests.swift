import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The lane a 429 reads while another job's verdict waits with a later apply's moved id (Stage 3 close-out cycle 16,
/// ruling S3-R19 item 1): the drain moves that id from the job the verdict leaves (`followAfterVerdict`), so
/// `followedLane` counts its interest unless the verdict answers it (`verdictAnswers`). A visit-first engine gave the
/// verdict at its arrival, and the later apply's visit moved the id from the job the verdict left alive, or found it
/// answered. Each case runs in both orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// How O's attempt ends in `verdictLane`.
    enum VerdictLaneEnding: Sendable, CaseIterable {
        /// A timeout of O's first attempt: O backs off and keeps B, whom v4's visit moves onto J.
        case retry
        /// A 404: B is answered `notFound`.
        case notFound
        /// A 429 with `Retry-After` 7,200 s, beyond the user lane's cap: B is answered `serverUnavailable`.
        case throttleExhausted
        /// A timeout of O's second attempt, at the interactive policy's cap of two: B is answered.
        case retryAtCap

        /// Whether the verdict leaves B on O, so a visit-first engine's v4 visit moved B onto J.
        var keepsB: Bool {
            self == .retry
        }
    }

    /// The shared scenario: O (100 kB, the content of zz-a and zz-b, a user waiter each) and J (16 bytes, zz-p's
    /// content, a prefetch waiter) download. v3 changes only the fillers, so behind the barrier its follow is owed when
    /// O's attempt ends (`ending`) and the verdict waits. v4 then moves zz-b onto J's content while the follow is still
    /// owed, and J gets a 429 with `Retry-After` 60 s (above the user lane's 30 s cap, below the prefetch lane's): its
    /// backoff reads the lane the follow and the drain leave J. Visited first, O's verdict was given at its arrival and
    /// v4's visit moved B onto J unless the verdict had answered B; on the user lane the 429 is beyond the caps and
    /// throttles nothing, on the prefetch lane it throttles the origin. Returns whether the origin is throttled after J's
    /// 429.
    @available(macOS 15.0, iOS 18.0, *)
    func verdictLane(_ visit: LaneDropVisit, seed: UInt64, ending: VerdictLaneEnding) async throws -> Bool {
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let jBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", oBytes)
        let b = EngineHarness.onDemand("zz-b", oBytes)
        let p = EngineHarness.onDemand("zz-p", jBytes)
        let bMoved = EngineHarness.onDemand("zz-b", jBytes)
        try #require(a.transferID == b.transferID && p.transferID == bMoved.transferID, "setup: zz-a and zz-b share O; zz-p and v4's zz-b share J")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, p] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let timeout = TransferError.transient(.timedOut, retryAfter: nil)
        switch ending {
        case .retry:
            await s.harness.source.script(a.transferID, [.hold, .fail(timeout), .stage(oBytes)])
        case .notFound:
            await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        case .throttleExhausted:
            await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(7_200)))])
        case .retryAtCap:
            await s.harness.source.script(a.transferID, [.hold, .fail(timeout), .hold, .fail(timeout)])
        }
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
        if ending == .retryAtCap {
            // O's first attempt times out before any apply: one attempt counted, nobody answered, O retries.
            await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
            }
        }
        let fillers = FollowBarrier.fillers(seed + 200)
        try await Self.applyHeld([s.q] + fillers + [a, b, p] + Self.laterFillers(seed + 6_000), tag: "v3-lane-\(seed)", s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            // O's verdict waits for v3's follow.
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            // Visited first, O's verdict is given at its arrival: O ends or backs off before v4.
            await engine.awaitCondition { e in
                guard let job = e.state.jobs[a.transferID] else {
                    return true
                }
                switch job.state {
                case .failed(.at), .blocked:
                    return true
                case .queued, .downloading, .verifying, .committing, .failed:
                    return false
                }
            }
        }
        // v4 moves zz-b onto J's content while (behind the barrier) the follow is still owed.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, p] + Self.laterFillers(seed + 9_000), tag: "v4-lane-\(seed)", s, visit: visit)
        // J's 429 (Retry-After 60 s) arrives now.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let throttled = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        _ = await aWaiter.value
        _ = await bWaiter.value
        _ = await pWaiter.value
        return throttled
    }

    /// A 429 that arrives while another job's verdict waits with a later apply's moved id reads that id's interest on
    /// its lane when the verdict leaves the job alive, and not when the verdict answers it (`verdictLane`; ruling S3-R19
    /// item 1): visited first, v4's visit moved B onto J from O backing off (a user lane, the 429 throttles nothing), or
    /// found B answered by O's 404, 429 beyond the caps or timeout at the cap (a prefetch lane, the 429 throttles the
    /// origin).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 counts the interest a waiting verdict leaves to move after it, not one it answers (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, VerdictLaneEnding.allCases)
    func barrierDecidesA429OnTheLaneAWaitingVerdictLeaves(_ visit: LaneDropVisit, _ ending: VerdictLaneEnding) async throws {
        let throttled = try await self.verdictLane(visit, seed: 1_616_802, ending: ending)
        if ending.keepsB {
            #expect(!throttled, "J's 429 is beyond the user lane's cap: B moves onto J after O's retry (visit-first)")
        } else {
            #expect(throttled, "J's 429 throttles the origin on J's own prefetch lane: O's \(ending) answered B (visit-first)")
        }
    }
}
