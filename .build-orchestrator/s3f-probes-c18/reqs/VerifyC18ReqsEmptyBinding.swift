import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

// VERIFY-C18R-EMPTY-BINDING (cycle-18 reqs verifier probe, scratch only, never committed): `publicationHop`'s `.back`
// case, where H's job holds zz-x only. Behind the barrier H's publication waits for the move off its job
// (`inboundBlocks`), the move takes zz-x, H's only id, onto P's publication, and H's publication then binds nothing
// (`publish` passes `ids == []`; `AssetStore.performPublish` returns `[:]` before touching the staged file). Visited
// first, v3's visit superseded H while it downloaded. Reads, once every answer is in: the staging directory's files,
// whether H's job is left, and `committedTotal`.
extension EngineFollowBarrierTests {
    @available(macOS 15.0, iOS 18.0, *)
    func emptyBindingHop(_ visit: LaneDropVisit, _ shape: PublicationHopShape) async throws -> (w: Result<AssetLocation, AssetError>, staging: [String: Int64], committed: Int64, hJob: Bool, hBytes: Int) {
        let seed = shape.seed
        let tuning = SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 2)
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        let pBytes = EngineFixture.bytes(seed + 3, count: shape.sizes.publisher)
        let wrongBytes = EngineFixture.bytes(seed + 4, count: shape.sizes.publisher)
        let hBytes = EngineFixture.bytes(seed + 5, count: shape.sizes.holder)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xToP = EngineHarness.onDemand("zz-x", pBytes)
        let aheadNames = (0..<Self.publicationHopAhead).map { String(format: "zz-g%04d", $0) }
        let aheadOwn = aheadNames.enumerated().map { EngineHarness.onDemand($0.element, EngineFixture.bytes(seed + 10_000 + UInt64($0.offset), count: 16)) }
        let aheadOnP = aheadNames.map { EngineHarness.onDemand($0, pBytes) }
        let aheadTransfers = aheadOwn.map(\.transferID)
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [p, x] + aheadOwn + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(p.transferID, [.hold, .stage(wrongBytes)])
        await s.harness.source.script(x.transferID, [.hold, .stage(hBytes)])
        let qWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[p.transferID]?.state == .downloading }
        }
        var aheadWaiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for holder in aheadOwn {
            let id = holder.identifier
            aheadWaiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        await engine.awaitCondition { e in aheadTransfers.allSatisfy { e.state.jobs[$0]?.interests.isEmpty == false } }
        let wWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .downloading }
        }
        let hHolds = await engine.readForTests { $0.state.jobs[x.transferID]?.assets.count ?? -1 }
        try #require(hHolds == 1, "setup: H's job holds zz-x only: \(hHolds)")
        let releaser = try await Self.holdPublication(of: p.transferID, s, bulk: bulk)
        try await Self.applyHeld([s.q] + fillers + [p, xToP] + aheadOnP + later, tag: "v3-emptybinding-\(seed)", s, visit: visit)
        try await Self.applyHeld([s.q] + fillers + [p, x] + aheadOnP + later, tag: "v4-emptybinding-\(seed)", s, visit: visit)
        await s.harness.source.release(x.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.inboundWaits[x.transferID] != nil || $0.state.jobs[x.transferID] == nil }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil || $0.state.jobs[p.transferID] == nil }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await engine.awaitCondition { $0.state.jobs[p.transferID] == nil }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: qWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        for waiter in aheadWaiters {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled && !$0.state.storeWorkInFlight }
        let read = await engine.readForTests { e in (committed: e.state.committedTotal, hJob: e.state.jobs[x.transferID] != nil) }
        let directory = StoreLayout(base: EngineHarness.base).stagingDirectory
        var staging: [String: Int64] = [:]
        for item in (try? s.fileSystem.contentsOfDirectory(at: directory)) ?? [] {
            staging[item.name] = item.byteSize
        }
        await Self.finishHeld(s)
        return (wResult, staging, read.committed, read.hJob, hBytes.count)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("VERIFY-C18R-EMPTY-BINDING: a holder whose only id an owed move takes publishes no binding and leaves its staged bytes", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PublicationHopShape.allCases)
    func verifyC18ReqsEmptyBinding(_ visit: LaneDropVisit, _ shape: PublicationHopShape) async throws {
        let outcome = try await self.emptyBindingHop(visit, shape)
        print("VERIFY-C18R-EMPTY-BINDING \(visit) \(shape): W \(outcome.w); staging \(outcome.staging); committedTotal \(outcome.committed); H's bytes \(outcome.hBytes); H's job left \(outcome.hJob)")
        #expect(outcome.w == .failure(.integrityFailure), "W: \(outcome.w)")
        #expect(outcome.staging.isEmpty, "\(visit) \(shape): staging files left once every answer is in: \(outcome.staging)")
    }
}
