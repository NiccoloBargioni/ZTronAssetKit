import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The lane a 429 that arrives during an owed follow is decided on (`SyncEngine.followedLane`; Stage 3 close-out cycle
/// 15, the cycle-14 requirements verifier's G4 finding on its branches; ruling S3-R16 items 1(a) and 1(e)). Each test
/// runs in both orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// A 429 during an owed follow on a job none of whose interests count any more is decided on the job's own lane: C
    /// (1 MB, zz-c) downloads for U, a user waiter, alone; while v3's follow is owed, U withdraws; then C gets a 429 with
    /// Retry-After 60 s (above the user lane's 30 s cap). Visited first, the withdrawal retired C and abandoned its
    /// transfer, so no 429 arrived and nothing was throttled, and a later user request for zz-d was served. Decided on
    /// the bulk policy (the held lane of a job no interest keeps, cycle 14), the 429 throttled the origin for 60 s, and
    /// that request was answered `serverUnavailable`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow on a job whose interests all withdraw throttles as its own lane's (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429OnTheOwnLaneOfAJobNothingKeeps(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_320_402, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xEC, count: 1_000_000)
        let dBytes = EngineFixture.bytes(1_320_404, count: 16)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_320_500) + [c, d], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(c.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(d.transferID, [.stage(dBytes)])
        let uWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[c.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_320_600) + [c, d], s, visit: visit)
        uWaiter.cancel()
        let uResult = await uWaiter.value
        #expect(uResult == .failure(.cancelled), "U's caller is answered at once (R-SYN-4): \(uResult)")
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.contains { event in
                    if case .removal = event { return true }
                    return false
                }
            }
            // The withdrawal waits, so C still downloads and its 429 arrives.
            await s.harness.source.release(c.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[c.transferID]?.state != .downloading }
        } else {
            await engine.awaitCondition { $0.state.jobs[c.transferID] == nil }
        }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let dResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await engine.awaitAsset(d.identifier, lane: .userInitiated) }
        #expect(throttleAtArrival == nil, "no 429 throttles the origin: visited first, C's transfer was abandoned at the withdrawal; decided on C's user lane, the 429 is `.exhausted`: \(String(describing: throttleAtArrival))")
        #expect((try? dResult.get())?.byteSize == 16, "a later user request is served, no throttle in force (visit-first): \(dResult)")
        let cLeft = await engine.readForTests { $0.state.jobs[c.transferID] == nil }
        #expect(cLeft, "C is retired: nobody wants it (visit-first)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
