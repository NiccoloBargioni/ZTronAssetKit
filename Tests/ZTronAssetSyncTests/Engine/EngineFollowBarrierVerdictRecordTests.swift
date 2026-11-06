import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The invariant clauses that let `replayVerdict` check only its record (Stage 3 close-out cycle 22, ruling S3-R27 item
/// 6; d4 §2): while a failure verdict waits for a follow (`verdictsAfterFollow`), its job is present, failed and at the
/// record's epoch, so a state that breaks either half is reported. They are invariant clauses, not replay or deferral
/// branches, so the test runs swept first only (S3-R27 item 6).
extension EngineFollowBarrierTests {
    /// `barrierFailsA429BeyondTheCapsAsOnArrival`'s swept-first state: C (zz-c) downloads for U's user waiter and gets a
    /// 429 beyond the caps while the follow owes its visits, so its job fails and the verdict waits for the follow. Set
    /// `.queued`, the job is reported not failed; moved to another epoch, it is reported at another epoch; each edit
    /// leaves the other clause quiet.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a job whose failure verdict waits for a follow is reported when it is not failed or is at another epoch (F-28, S3-R27 item 6)", .timeLimit(.minutes(3)))
    func invariantsReportAWaitingVerdictsJobOutOfStateOrEpoch() async throws {
        let seed: UInt64 = 2_029_301
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let cBytes = Data(repeating: 0xF1, count: 100_000)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let cT = c.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [c], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(cT, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(7_200))), .stage(cBytes)])
        let uWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[cT]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [c], tag: "v3-verdict-record-\(seed)", s, visit: .sweepFollowsFirst)
        await s.harness.source.release(cT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.verdictsAfterFollow[cT] != nil }
        let waiting = await engine.invariantViolations()
        try #require(waiting.isEmpty, "setup: C's verdict waits with its job failed at its epoch: \(waiting.prefix(3))")
        let unfailed = "1 jobs whose failure verdict waits for a follow are not failed"
        let elsewhere = "1 jobs whose failure verdict waits for a follow are at another epoch"
        let queued = await engine.violations { $0.jobs[cT]?.state = .queued }
        #expect(queued.contains(unfailed) && !queued.contains(elsewhere), "a waiting verdict's job set queued is reported as not failed, and only so: \(queued)")
        let bumped = await engine.violations { $0.jobs[cT]?.epoch += 1 }
        #expect(bumped.contains(elsewhere) && !bumped.contains(unfailed), "a waiting verdict's job at another epoch is reported as at another epoch, and only so: \(bumped)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        await Self.finishHeld(s)
    }
}
