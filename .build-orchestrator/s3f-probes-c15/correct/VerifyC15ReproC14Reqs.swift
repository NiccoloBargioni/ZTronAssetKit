import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 14, requirements lens). Never committed. Each runs in both orders
/// (`LaneDropVisit`) and expects the visit-first outcome.
///
/// PROBE-C14R-PASSED-LANE (the draft's "RR-1, what is left", cycle 14: "Not probed"). C (1 MB, zz-b) runs for P, a
/// prefetch waiter; Y (100 kB, zz-u) runs for U, a user waiter. v3 moves zz-u onto C's content while the follow owes its
/// visits (Y keeps zz-y, W's user waiter, so it publishes). Y's download then completes and its publication is held (it began after the apply). C then gets a 429 with
/// Retry-After 60 s, above the user lane's 30 s cap. Visit-first, Y's visit at the apply (Y downloading) moved U onto C,
/// so C was user work at the 429: `.exhausted`, nothing throttled, P and U answered `serverUnavailable`. Behind the
/// barrier `followedLane(C)` skips Y (verifying): C is decided on the background policy.
/// `afterDrain`: the 429 arrives after the barrier's drain, while Y still publishes (no barrier, `followedLane` is the
/// job's lane).
extension EngineFollowBarrierTests {
    @available(macOS 15.0, iOS 18.0, *)
    func c15ReproPassedLaneProbe(_ visit: LaneDropVisit, seed: UInt64, afterDrain: Bool, cFailure: TransferError = .transient(.throttled, retryAfter: .seconds(60))) async throws {
        let is429: Bool = { if case .transient(.throttled, _) = cFailure { return true }; return false }()
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry), storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), bulk: bulk, fileSystem: fileSystem)
        let qBytes = EngineFixture.bytes(seed, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await harness.engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let s = FollowBarrier.Setup(time: time, fileSystem: fileSystem, harness: harness, q: q)
        let engine = s.engine
        let cBytes = Data(repeating: 0xC4, count: 1_000_000)
        let yBytes = Data(repeating: 0xC5, count: 100_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let u = EngineHarness.onDemand("zz-u", yBytes)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        let uMoved = EngineHarness.onDemand("zz-u", cBytes)
        try #require(uMoved.transferID == b.transferID, "setup: v3's zz-u is C's content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, u, y] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .fail(cFailure), .stage(cBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(yBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        }
        let wWaiter = Task { await engine.awaitAsset(y.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[u.transferID]?.interests.count == 2 }
        print("PROBE-C14R-PASSED-LANE \(visit) setup done")
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [b, uMoved, y] + Self.laterFillers(seed + 6_000), tag: "v3-passed-lane-\(seed)", s, visit: visit)
        var releaser: Task<Void, Never>?
        if visit == .sweepFollowsFirst {
            // Y downloaded at the apply; its publication begins while the follow is owed.
            releaser = try await Self.holdPublication(of: u.transferID, s, bulk: bulk)
            if afterDrain {
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            }
        }
        let before = await engine.readForTests { e in
            (barrier: e.followBarrier, y: e.state.jobs[u.transferID]?.state, yReroute: e.state.jobs[u.transferID].map { "\(String(describing: $0.rerouteOnPass))" },
             cInterests: e.state.jobs[b.transferID]?.interests.count, lane: e.state.jobs[b.transferID].map { e.followedLane($0) })
        }
        print("PROBE-C14R-PASSED-LANE \(visit) afterDrain=\(afterDrain) before the 429: \(before)")
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let atArrival = await engine.readForTests { e in
            (throttle: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[b.transferID]?.state)
        }
        print("PROBE-C14R-PASSED-LANE \(visit) afterDrain=\(afterDrain) right after the 429: \(atArrival)")
        if visit == .sweepFollowsFirst, !afterDrain {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        releaser?.cancel()
        await releaser?.value
        await bulk.setHolding(false)
        if visit == .followVisitedFirst {
            // Visited first, Y kept zz-y (W) and still downloads: let it finish.
            await s.harness.source.release(u.transferID, with: .progress(received: 0, expected: nil))
        }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        print("PROBE-C14R-PASSED-LANE \(visit) afterDrain=\(afterDrain) w=\(wResult)")
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let cStarts = await s.harness.source.starts.filter { $0.id == b.transferID }.count
        print("PROBE-C14R-PASSED-LANE \(visit) afterDrain=\(afterDrain) u=\(uResult) p=\(pResult) cStarts=\(cStarts)")
        guard is429 else {
            print("PROBE-C14R-PASSED-FAIL \(visit) afterDrain=\(afterDrain) u=\(uResult) p=\(pResult) cStarts=\(cStarts)")
            #expect((try? uResult.get()) == nil, "PROBE-C14R-PASSED-FAIL: U gets C's failure (visit-first: U rode C since the apply): \(uResult)")
            #expect((try? pResult.get()) == nil, "PROBE-C14R-PASSED-FAIL: P gets C's failure (visit-first): \(pResult)")
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            await Self.finishHeld(s)
            return
        }
        #expect(atArrival.throttle == nil, "PROBE-C14R-PASSED-LANE: the 429 beyond the user lane's cap throttles nothing (visit-first `.exhausted`): \(atArrival)")
        if case .failure(.serverUnavailable) = pResult {
        } else {
            Issue.record("PROBE-C14R-PASSED-LANE: P is answered serverUnavailable (visit-first): \(pResult)")
        }
        if case .failure(.serverUnavailable) = uResult {
        } else {
            Issue.record("PROBE-C14R-PASSED-LANE: U is answered serverUnavailable (visit-first): \(uResult)")
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C14R-PASSED-LANE-BARRIER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func c15Repro_probeC14RPassedLaneBarrier(_ visit: LaneDropVisit) async throws {
        try await self.c15ReproPassedLaneProbe(visit, seed: 1_414_002, afterDrain: false)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C14R-PASSED-LANE-AFTER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func c15Repro_probeC14RPassedLaneAfter(_ visit: LaneDropVisit) async throws {
        try await self.c15ReproPassedLaneProbe(visit, seed: 1_414_302, afterDrain: true)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C14R-PASSED-FAIL-BARRIER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func c15Repro_probeC14RPassedFailBarrier(_ visit: LaneDropVisit) async throws {
        try await self.c15ReproPassedLaneProbe(visit, seed: 1_414_602, afterDrain: false, cFailure: .permanentMissing(httpStatus: 404))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C14R-PASSED-FAIL-AFTER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func c15Repro_probeC14RPassedFailAfter(_ visit: LaneDropVisit) async throws {
        try await self.c15ReproPassedLaneProbe(visit, seed: 1_414_902, afterDrain: true, cFailure: .permanentMissing(httpStatus: 404))
    }
}
