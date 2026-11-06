import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Cycle-10 reqs-lens probes (verifier scratch; not for commit). Each runs in both orders; the expectations are the
/// visit-first outcome (S3-R11 item 3).
extension EngineSyncTests {
    /// PROBE-C10R-POLICY-PAUSE (the draft's cycle-10 residual "a policy pause reads the job's pre-visit lane"): C (1 MB,
    /// content X) downloads for a prefetch member P (zz-p); D (content W) downloads for A's user waiter (zz-a). v3 moves
    /// zz-a onto X while the follow owes D's visit. Low Data Mode then arrives. Visit-first, D's visit moved A's user
    /// interest onto C and raised C to the user lane, which Low Data Mode does not pause (`userInitiatedOverridesPolicy`):
    /// C's attempt runs on and serves A. Behind the barrier C is still on the prefetch lane when the conditions turn
    /// runs, so `pauseIfRefused` pauses it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C10R-POLICY-PAUSE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC10RPolicyPause(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 997_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xD1, count: 1_000_000)
        let wBytes = Data(repeating: 0xD2, count: 1_000_000)
        let p = EngineHarness.onDemand("zz-p", xBytes)
        let a = EngineHarness.onDemand("zz-a", wBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(740_000) + [a, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(p.transferID, [.hold, .stage(xBytes)])
        await s.harness.source.script(a.transferID, [.hold, .stage(wBytes)])
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let aMoved = EngineHarness.onDemand("zz-a", xBytes)
        try #require(aMoved.transferID == p.transferID, "setup: zz-a's new content is X")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(840_000) + [aMoved, p], s, visit: visit)
        let before = await engine.readForTests { e in (owed: e.followOwed, lane: e.state.jobs[p.transferID]?.lane, c: e.state.jobs[p.transferID]?.state) }
        if visit == .sweepFollowsFirst {
            #expect(before.owed && before.lane == .prefetch && before.c == .downloading, "setup: C runs on the prefetch lane and D's visit is owed: \(before)")
        } else {
            #expect(before.lane == .userInitiated && before.c == .downloading, "visit-first: C runs on the user lane: \(before)")
        }
        await s.harness.conditions.send(EngineConditionsTests.lowData)
        await engine.awaitCondition { $0.state.conditions?.network.constrained == true }
        let pauses = await s.harness.source.controlLog.filter { $0.transfer == p.transferID && $0.control == .pause }.count
        #expect(pauses == 0, "PROBE-C10R-POLICY-PAUSE: C, raised to the user lane by the owed visit, is not paused by Low Data Mode (visit-first): \(pauses) pause(s)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier }
        await s.harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.conditions?.network.constrained == false }
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(xBytes.count), "A is served from X: \(aResult)")
        let starts = await s.harness.source.starts.filter { $0.id == p.transferID }.count
        print("PROBE-C10R-POLICY-PAUSE \(visit): before=\(before) pauses=\(pauses) starts=\(starts) a=\(aResult)")
        #expect(starts == 1, "PROBE-C10R-POLICY-PAUSE: C started once, its attempt never paused (visit-first): \(starts)")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }
}
