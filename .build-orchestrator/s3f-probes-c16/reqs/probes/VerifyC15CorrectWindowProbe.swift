import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probe (s3f close-out verification, cycle 15, correctness lens). Never committed.
@Suite("VerifyC15CorrectWindow", .serialized)
struct VerifyC15CorrectWindow {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// `setUpHeldPublications` with a stepped metadata executor too (the store's index commits run on it).
    @available(macOS 15.0, iOS 18.0, *)
    static func setUp(seed: UInt64) async throws -> (FollowBarrier.Setup, SteppedBlockingExecutor, SteppedBlockingExecutor) {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let meta = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), metadata: meta, bulk: bulk, fileSystem: fileSystem)
        let qBytes = EngineFixture.bytes(seed, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await harness.engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        return (FollowBarrier.Setup(time: time, fileSystem: fileSystem, harness: harness, q: q), bulk, meta)
    }

    /// PROBE-C15C-INTEGRITY-WINDOW: a publication begun before v3's apply fails its checksum while v3's follow owes C's
    /// visit. `integrityFailed` sets C `failed` and awaits the store (`recordIntegrityFailure`'s ordered index commit,
    /// held here on the metadata executor) before `resolveAll` defers its verdict. The follow turn inside that window meets
    /// C failed with no waiting verdict: `passesOnVisit` is false, and it moves zz-b onto N.
    /// Visit-first: the follow passed C at the apply and the failure answered A and B `integrityFailure`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15C-INTEGRITY-WINDOW", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func integrityWindow(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_516_302
        let (s, bulk, meta) = try await Self.setUp(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let releaser = try await EngineFollowBarrierTests.holdPublication(of: a.transferID, s, bulk: bulk)
        try await EngineFollowBarrierTests.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved] + EngineFollowBarrierTests.laterFillers(seed + 6_000), tag: "v3-window-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await meta.setHolding(true)
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            var window = false
            var steps = 0
            for _ in 0..<400 {
                steps += 1
                let now = await engine.readForTests { e -> (failed: Bool, verdict: Bool) in
                    let failed: Bool
                    if case .failed? = e.state.jobs[a.transferID]?.state { failed = true } else { failed = false }
                    return (failed, e.state.verdictsAfterFollow[a.transferID] != nil)
                }
                let held = await meta.heldUnits
                if now.verdict {
                    break
                }
                if now.failed, !held.isEmpty {
                    window = true
                    break
                }
                if held.isEmpty {
                    try await meta.requireHeldUnits(atLeast: 1)
                    continue
                }
                _ = await meta.releaseNext()
            }
            let inWindow = await engine.readForTests { e in
                (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, verdict: e.state.verdictsAfterFollow[a.transferID], holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true)
            }
            print("PROBE-C15C-INTEGRITY-WINDOW \(visit) window=\(window) steps=\(steps) state=\(inWindow)")
            try #require(window, "setup: reached the window between C's failure and its deferred verdict")
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
            let visited = await engine.readForTests { e in
                (c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, n: e.state.jobs[bMoved.transferID]?.state, barrier: e.followBarrier)
            }
            print("PROBE-C15C-INTEGRITY-WINDOW \(visit) after the follow: \(visited)")
            await meta.setHolding(false)
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C15C-INTEGRITY-WINDOW \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "PROBE-C15C-INTEGRITY-WINDOW: B gets C's integrity failure, the follow passed C publishing at the apply (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineFollowBarrierTests.finishHeld(s)
    }
}
