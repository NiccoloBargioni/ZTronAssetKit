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
///
/// Cycle 17 adds the verdicts that answer B only in part, by a fail-fast or a `Retry-After` beyond the cap (the cycle-16
/// verifiers' PROBE-C16R-RR11-RETRY-AFTER and PROBE-C16C-THROTTLE-FAILFAST-LANE, and the offline and ENOSPC variants):
/// counted as answering nobody, B's interest made J's 429 user work, beyond the user lane's cap, so the origin was left
/// unthrottled (R-SYN-5) and P was answered `serverUnavailable` where a visit-first engine served it.
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
        /// A 503 with `Retry-After` 120 s, beyond the user lane's 30 s cap (`Backoff.delay` defers to the next run): B is
        /// answered `serverUnavailable` below the attempt cap (cycle 17, PROBE-C16R-RR11-RETRY-AFTER).
        case retryAfterBeyondCap
        /// A 429 with `Retry-After` 10 s, within the user lane's cap and beyond `interactiveMaxWait`: O parks throttled
        /// and the park's fail-fast answers B `serverUnavailable` (cycle 17, PROBE-C16C-THROTTLE-FAILFAST-LANE).
        case throttleFailFast
        /// As `throttleFailFast`, with 9 s passing before v4: J's 429 meets O's verdict waiting with 1 s of its throttle
        /// left, within `interactiveMaxWait`, so whether the fail-fast answers B is read at O's 429, as the drain gives the
        /// verdict under its arrival (`verdictAnswers`' stamp; Stage 3 close-out cycle 18, the drop-mutant vaStampDrop).
        case throttleFailFastLater
        /// An offline failure of O's second attempt, begun after the conditions' first element (no edge since): O waits
        /// for the next edge and the offline fail-fast answers B `offline` (cycle 17).
        case offline
        /// An ENOSPC for 20 MB with 500 kB of room for O's 1 MB: O parks `insufficientSpace` and its fail-fast answers B
        /// (cycle 17).
        case insufficientSpace

        /// Whether the verdict leaves B on O, so a visit-first engine's v4 visit moved B onto J.
        var keepsB: Bool {
            self == .retry
        }

        /// Whether O's attempt ends in an ENOSPC, whose free-space read runs a space sweep.
        var isSpace: Bool {
            self == .insufficientSpace
        }
    }

    /// What `verdictLane` reads: the origin's throttle end before and after J's 429, and the answers of B and P.
    struct VerdictLaneOutcome {
        /// The origin's throttle end before J's 429.
        let before: MonotonicInstant?
        /// The origin's throttle end after it.
        let after: MonotonicInstant?
        /// B's answer.
        let b: Result<AssetLocation, AssetError>
        /// P's answer.
        let p: Result<AssetLocation, AssetError>

        /// Whether the origin is throttled after J's 429.
        var throttled: Bool {
            self.after != nil
        }

        /// Whether J's 429 throttled the origin until an end of its own: on a lane whose cap its `Retry-After` is within.
        var throttledByJ: Bool {
            self.after != nil && self.after != self.before
        }
    }

    /// The shared scenario: O (100 kB, 1 MB for `.insufficientSpace`; the content of zz-a and zz-b, a user waiter each)
    /// and J (16 bytes, zz-p's content, a prefetch waiter) download. v3 changes only the fillers, so behind the barrier
    /// its follow is owed when O's attempt ends (`ending`) and the verdict waits. v4 then moves zz-b onto J's content while
    /// the follow is still owed, and J gets a 429 with `Retry-After` 60 s (above the user lane's 30 s cap, below the
    /// prefetch lane's): its backoff reads the lane the follow and the drain leave J. Visited first, O's verdict was given
    /// at its arrival and v4's visit moved B onto J unless the verdict had answered B; on the user lane the 429 is beyond
    /// the caps and throttles nothing, on the prefetch lane it throttles the origin and J's retry serves P.
    @available(macOS 15.0, iOS 18.0, *)
    func verdictLane(_ visit: LaneDropVisit, seed: UInt64, ending: VerdictLaneEnding) async throws -> VerdictLaneOutcome {
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: ending.isSpace ? 1_000_000 : 100_000)
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
        case .retryAfterBeyondCap:
            await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 503), retryAfter: .seconds(120))), .stage(oBytes)])
        case .throttleFailFast, .throttleFailFastLater:
            await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(10))), .stage(oBytes)])
        case .offline:
            await s.harness.source.script(a.transferID, [.hold, .fail(timeout), .hold, .fail(.offline(.noConnection)), .stage(oBytes)])
        case .insufficientSpace:
            await s.harness.source.script(a.transferID, [.hold, .stage(oBytes)])
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
        if ending == .retryAtCap || ending == .offline {
            // O's first attempt times out before any apply: one attempt counted, nobody answered, O retries. Its first
            // attempt began before the conditions' first element, whose edge would re-queue an offline exit at once.
            await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
            }
        }
        let fillers = FollowBarrier.fillers(seed + 200)
        try await Self.applyHeld([s.q] + fillers + [a, b, p] + Self.laterFillers(seed + 6_000), tag: "v3-lane-\(seed)", s, visit: visit)
        if ending.isSpace {
            if visit == .sweepFollowsFirst {
                // The ENOSPC's free-space read runs one follow turn (`advanceFollowForSpaceSweep`); the space sweep's own
                // follow-up turns, which would run the rest of the follow and its drain before v4, are held.
                await engine.readForTests { $0.holdSpaceSweepFollowUps() }
            }
            try await Self.leaveRoom(500_000, harness: s.harness, fileSystem: s.fileSystem)
            await s.harness.source.release(a.transferID, with: .failed(.insufficientSpace(requiredBytes: 20_000_000)))
        } else {
            await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        }
        if visit == .sweepFollowsFirst {
            // O's verdict waits for v3's follow.
            await engine.awaitCondition { e in
                e.state.verdictsAfterFollow[a.transferID] != nil || e.state.eventsAfterFollow.contains(where: Self.isSpaceFailure)
            }
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
        if ending == .throttleFailFastLater {
            // 9 of the throttle's 10 s pass before v4 and J's 429.
            s.time.advance(by: 9)
        }
        // v4 moves zz-b onto J's content while (behind the barrier) the follow is still owed.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, p] + Self.laterFillers(seed + 9_000), tag: "v4-lane-\(seed)", s, visit: visit)
        let before = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        // J's 429 (Retry-After 60 s) arrives now.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let after = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseSpaceSweepFollowUps()
            }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        _ = await aWaiter.value
        return VerdictLaneOutcome(before: before, after: after, b: bResult, p: pResult)
    }

    /// A 429 that arrives while another job's verdict waits with a later apply's moved id reads that id's interest on
    /// its lane when the verdict leaves the job alive, and not when the verdict answers it (`verdictLane`; ruling S3-R19
    /// item 1): visited first, v4's visit moved B onto J from O backing off (a user lane, the 429 throttles nothing and
    /// fails J, answering P), or found B answered by O's 404, 429 beyond the caps, timeout at the cap, `Retry-After`
    /// beyond the cap, throttle's fail-fast, offline fail-fast or ENOSPC fail-fast (a prefetch lane, the 429 throttles
    /// the origin until its own end and J's retry serves P). Cycle 17 adds four endings and the assertions on J's own
    /// throttle end and on the answers of B and P; cycle 18 the throttle's fail-fast read 9 s after it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 counts the interest a waiting verdict leaves to move after it, not one it answers (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, VerdictLaneEnding.allCases)
    func barrierDecidesA429OnTheLaneAWaitingVerdictLeaves(_ visit: LaneDropVisit, _ ending: VerdictLaneEnding) async throws {
        let outcome = try await self.verdictLane(visit, seed: 1_616_802, ending: ending)
        if ending.keepsB {
            #expect(!outcome.throttled, "J's 429 is beyond the user lane's cap: B moves onto J after O's retry (visit-first)")
        } else {
            #expect(outcome.throttled, "J's 429 throttles the origin on J's own prefetch lane: O's \(ending) answered B (visit-first)")
        }
        #expect(outcome.throttledByJ == !ending.keepsB, "J's 429 throttles the origin until its own end only on J's prefetch lane, O's \(ending) having answered B (visit-first): before \(String(describing: outcome.before)), after \(String(describing: outcome.after))")
        #expect((try? outcome.b.get()) == nil, "B is answered, by O's \(ending) or by J's 429 beyond the user lane's cap (visit-first): \(outcome.b)")
        if ending.keepsB {
            Self.expectServerUnavailable(outcome.p, "P is answered J's 429 beyond the user lane's cap, B having moved onto J (visit-first)")
        } else {
            #expect((try? outcome.p.get())?.byteSize == 16, "P is served J's retry after the throttle: O's \(ending) answered B (visit-first): \(outcome.p)")
        }
    }
}
