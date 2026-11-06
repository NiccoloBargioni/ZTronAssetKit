import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Cycle-9 reqs-lens probes (verifier scratch; not for commit). Each runs in both orders; the expectations are the
/// visit-first outcome.
extension EngineSyncTests {
    /// PROBE-C9R-JOIN-RESOLVE: the draft's open residual "A join while a `.resolve` verdict waits". C (1 MB, content X)
    /// downloads for A (zz-a, user) and B0 (zz-b, user); zz-a and zz-b share X. v3 moves zz-a to a 16-byte content Y and
    /// keeps zz-b on X. C's attempt is then refused by policy (`.rejected`, final for the run: `resolveAll`). A new user
    /// waiter B then asks for zz-b. Visit-first, the failure answered B0 and removed C, so B's request creates a new job
    /// for X, whose next attempt stages X: B is served. Behind the barrier, C's verdict waits, B joins C (left failed),
    /// and the drain's `resolveAll` answers B with the failure.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9R-JOIN-RESOLVE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC9RJoinResolve(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 990_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xB1, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share X")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(730_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.rejected(.unexpectedStatus(418))), .stage(xBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let b0Waiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { ($0.state.jobs[a.transferID]?.interests.count ?? 0) == 2 }
        let yBytes = EngineFixture.bytes(990_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", yBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(yBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(830_000) + [aMoved, b], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        }
        // C's attempt is refused (final for the run) in both orders.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: b0Waiter) }
        }
        // A new user waiter for zz-b (content X) arrives after the failure.
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID]?.joined == true }
            let state = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(state.owed, "setup: the follow still owes C's visit when B joins: \(state)")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let b0Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: b0Waiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C9R-JOIN-RESOLVE \(visit): b0=\(b0Result) a=\(aResult) b=\(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A is served from its 16-byte new content: \(aResult)")
        if case .failure(.serverUnavailable) = b0Result {
        } else {
            Issue.record("B0, held by C at the refusal, gets the refusal's answer: \(b0Result)")
        }
        #expect((try? bResult.get())?.byteSize == Int64(xBytes.count), "B, asking after the refusal, gets a new job for X and is served (visit-first): \(bResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C9R-OFFLINE-FAILFAST: the draft's open residual "the offline and throttle exits". C (1 MB, content X)
    /// downloads for A (zz-a, user) and B0 (zz-b, user). v3 moves zz-a to a 16-byte content Y. C's attempt then fails
    /// offline while the path reads satisfied (no edge since it started): `.failed(.whenOnline)` with its fail-fast.
    /// Visit-first, A's interest left C for Y's job before the failure, Y stages: A is served. Behind the barrier the
    /// fail-fast answers A `.offline` before the owed visit moves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9R-OFFLINE-FAILFAST", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC9ROfflineFailFast(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 991_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xB2, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share X")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(731_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.offline(.noConnection)), .stage(xBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let b0Waiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { ($0.state.jobs[a.transferID]?.interests.count ?? 0) == 2 }
        let yBytes = EngineFixture.bytes(991_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", yBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(yBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(831_000) + [aMoved, b], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        } else {
            // Visit-first, A's interest moved to Y's job, which stages at once.
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        }
        // C's attempt fails offline in both orders.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let b0Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: b0Waiter) }
        print("PROBE-C9R-OFFLINE-FAILFAST \(visit): a=\(aResult) b0=\(b0Result)")
        #expect((try? aResult.get())?.byteSize == 16, "A, moved to Y by the owed visit, is served from Y (visit-first): \(aResult)")
        if case .failure(.offline) = b0Result {
        } else {
            Issue.record("B0, still held by C, gets the offline answer: \(b0Result)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }
    /// PROBE-C9R-THROTTLE-FAILFAST: the draft's open residual "the offline and throttle exits". C (1 MB, content X)
    /// downloads for A (zz-a, user) and B0 (zz-b, user). v3 moves zz-a to a 16-byte content Y. C's attempt then fails
    /// offline while the path reads satisfied (no edge since it started): `.failed(.whenOnline)` with its fail-fast.
    /// Visit-first, A's interest left C for Y's job before the failure, Y stages: A is served. Behind the barrier the
    /// fail-fast answers A `.offline` before the owed visit moves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9R-THROTTLE-FAILFAST", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC9RThrottleFailFast(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 992_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xB3, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share X")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(732_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(600))), .stage(xBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let b0Waiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { ($0.state.jobs[a.transferID]?.interests.count ?? 0) == 2 }
        let yBytes = EngineFixture.bytes(992_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", yBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(yBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(832_000) + [aMoved, b], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        } else {
            // Visit-first, A's interest moved to Y's job, which stages at once.
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        }
        // C's attempt fails offline in both orders.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let b0Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: b0Waiter) }
        print("PROBE-C9R-THROTTLE-FAILFAST \(visit): a=\(aResult) b0=\(b0Result)")
        #expect((try? aResult.get())?.byteSize == 16, "A, moved to Y by the owed visit, is served from Y (visit-first): \(aResult)")
        if case .failure(.serverUnavailable) = b0Result {
        } else {
            Issue.record("B0, still held by C, gets the throttle's fail-fast answer: \(b0Result)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }
}
