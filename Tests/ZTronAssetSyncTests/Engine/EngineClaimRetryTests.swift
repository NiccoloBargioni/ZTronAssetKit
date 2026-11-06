import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineGroupClaimTests {
    /// A job only a pending claim keeps (its handle was released after a successor registered and before the
    /// successor's join added its interest) fails its attempt with a transient error: the claim stands for the released
    /// interest, so the failure counts against the retry policy of the lane the job held. Under the default policy the
    /// job waits for its backoff instead of ending `failed(.nextRun)` with an `assetFailed` nobody asked for, and the
    /// successor's join then finds the same job, which retries once the backoff ends (L5-R16; Stage 3, S3-B-081).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-4: a job only a claim keeps backs off after a transient failure under its held lane's retry policy instead of failing at once", .timeLimit(.minutes(1)))
    func claimOnlyJobBacksOff() async throws {
        let bytes = EngineFixture.bytes(6_701)
        let entry = EngineHarness.onDemand("claimed", bytes)
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let predecessor = try await engine.registerGroup([entry.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[entry.transferID]?.active != nil }
        await engine.waitForAllHandles()
        let successor = await engine.inOneTurn { engine -> InterestToken in
            let successor = engine.recordGroup([entry.identifier], lane: .prefetch).token
            engine.performReleaseGroup(predecessor)
            return successor
        }
        let held = await engine.inOneTurn { engine in
            (engine.state.jobs[entry.transferID]?.interests.isEmpty == true, engine.state.claimHeld.values.contains(entry.transferID))
        }
        #expect(held.0 && held.1, "setup: only the successor's claim keeps the running job: \(held)")
        await harness.source.release(entry.transferID, with: .failed(.transient(.serverError(httpStatus: 503), retryAfter: nil)))
        await engine.awaitCondition { $0.state.jobs[entry.transferID]?.active == nil }
        let after = await engine.inOneTurn { engine in engine.state.jobs[entry.transferID]?.state }
        guard case .failed(.at)? = after else {
            Issue.record("the claim-only job backs off under the prefetch policy instead of ending: \(String(describing: after))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        // The successor's join finds the same job, which retries once the backoff ends.
        await engine.inOneTurn { engine in engine.spawnJoin(successor, members: [entry.identifier], lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[entry.transferID]?.interests[successor] != nil }
        await harness.withClock {
            await engine.waitUntil { $0.jobsByState.isEmpty }
        }
        #expect(await harness.source.starts.count == 2, "one retry of the same transfer")
        let failed = await probe.next { event in
            if case .assetFailed(let id, _, _) = event, id == entry.identifier {
                return true
            }
            if case .assetAvailable(let id, _) = event, id == entry.identifier {
                return true
            }
            return false
        }
        if case .assetFailed? = failed {
            Issue.record("no assetFailed precedes the retry's success: \(String(describing: failed))")
        }
        await probe.stop()
        await engine.releaseGroup(successor)
        await engine.shutdown()
    }
}
