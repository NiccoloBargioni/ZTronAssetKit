import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A publication's failure between its end and its deferred verdict (Stage 3 close-out cycle 16; the cycle-15
/// correctness verifier's PROBE-C15C-INTEGRITY-WINDOW and ruling S3-R19 item 1's "publication failure's await window"):
/// `integrityFailed` sets the job `failed` and awaits the store's bookkeeping before its verdict waits for the follow
/// (`resolveAll`, `defersFailure`). A visit-first engine's visit at an apply before that end met the job publishing and
/// passed it; one at an apply inside the window met it failed and moved its moved ids. The store's index commits run on
/// a stepped metadata executor here, so a test holds the window open. Each test runs in both orders (`LaneDropVisit`)
/// with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// `setUpHeldPublications` with a stepped metadata executor too, on which the store's index commits run (an integrity
    /// failure's record among them).
    @available(macOS 15.0, iOS 18.0, *)
    static func setUpHeldBookkeeping(seed: UInt64) async throws -> (setup: FollowBarrier.Setup, bulk: SteppedBlockingExecutor, meta: SteppedBlockingExecutor) {
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

    /// Steps the held metadata executor until `transfer`'s job is `failed` with a unit held and its users not answered:
    /// the window between its publication's failure and its verdict, which stays open while the executor holds.
    @available(macOS 15.0, iOS 18.0, *)
    static func holdFailureWindow(of transfer: TransferID, users: Int, _ engine: SyncEngine, meta: SteppedBlockingExecutor) async throws {
        for _ in 0..<400 {
            let now = await engine.readForTests { e -> (failed: Bool, waiting: Bool) in
                let failed: Bool
                if case .failed? = e.state.jobs[transfer]?.state {
                    failed = true
                } else {
                    failed = false
                }
                return (failed, e.state.jobs[transfer]?.interests.count == users && e.state.verdictsAfterFollow[transfer] == nil)
            }
            let held = await meta.heldUnits
            if now.failed {
                try #require(now.waiting && !held.isEmpty, "setup: the failure's bookkeeping is held before its verdict: \(now) held=\(held)")
                return
            }
            if held.isEmpty {
                try await meta.requireHeldUnits(atLeast: 1)
                continue
            }
            _ = await meta.releaseNext()
        }
        Issue.record("setup: the publication never failed while the metadata executor held")
    }

    /// The shared scenario: C (100 kB, the content of zz-a and zz-b, a user waiter each) publishes bytes that fail their
    /// checksum; its publication begins with no follow owed (`rerouteOnPass` is empty) and is held at its first store
    /// unit. v3 moves zz-b to N (16 bytes).
    /// - `applyInWindow == false`: v3 is applied while C verifies; behind the barrier its follow's visit of C runs inside
    ///   the window. Visited first, v3's visit passed C, publishing, and the failure answered both users
    ///   `integrityFailure` (PROBE-C15C-INTEGRITY-WINDOW).
    /// - `applyInWindow == true`: v3 goes to the store before C's bytes fail, and its engine side (the copy and the
    ///   follow) runs inside the window; behind the barrier the follow's visit of C comes after the verdict waits.
    ///   Visited first, v3's visit met C failed, its verdict not given yet, and moved B onto N, which served B.
    /// Returns the answers of A and B.
    @available(macOS 15.0, iOS 18.0, *)
    func failureWindow(_ visit: LaneDropVisit, seed: UInt64, applyInWindow: Bool) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>) {
        let (s, bulk, meta) = try await Self.setUpHeldBookkeeping(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
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
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved] + Self.laterFillers(seed + 6_000)
        if applyInWindow {
            // v3 reaches the store now; its engine side waits (`holdNextApplyFollow`) until C's failure has begun.
            let manifest = try ValidatedManifest(entries: v3, digest: ContentHash.sha256(of: Data("v3-window-apply-\(seed)".utf8)))
            await engine.readForTests { e in
                e.holdFollowFollowUps()
                e.holdNextApplyFollow()
            }
            let applying = Task { await engine.applyAndFollow(manifest, etag: nil, eviction: nil) }
            await engine.awaitCondition { $0.applyFollowHeld }
            await meta.setHolding(true)
            releaser.cancel()
            await releaser.value
            await bulk.setHolding(false)
            try await Self.holdFailureWindow(of: a.transferID, users: 2, engine, meta: meta)
            // v3's copy and follow inside the window.
            await engine.readForTests { $0.releaseApplyFollow() }
            let applied = await applying.value
            #expect((try? applied.get()) != nil, "setup: v3 is applied: \(applied)")
            if visit == .followVisitedFirst {
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followOwed }
            } else {
                let owed = await engine.readForTests { $0.followOwed }
                #expect(owed, "setup: v3's follow owes C's visit")
            }
            await meta.setHolding(false)
            if visit == .sweepFollowsFirst {
                // The failure's verdict waits behind v3's owed follow; the visit of C comes after it.
                await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
                await engine.readForTests { $0.releaseFollowFollowUps() }
            }
        } else {
            try await Self.applyHeld(v3, tag: "v3-window-\(seed)", s, visit: visit)
            if visit == .sweepFollowsFirst {
                await meta.setHolding(true)
            }
            releaser.cancel()
            await releaser.value
            await bulk.setHolding(false)
            if visit == .sweepFollowsFirst {
                try await Self.holdFailureWindow(of: a.transferID, users: 2, engine, meta: meta)
                // The follow's visit of C runs inside the window.
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followOwed }
                await meta.setHolding(false)
            }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (aResult, bResult)
    }

    /// An owed visit that meets a publication failed in its bookkeeping, for an apply made while the job still published,
    /// passes it as a visit-first engine's visit at that apply passed it (`failureWindow`, v3 before the failure;
    /// PROBE-C15C-INTEGRITY-WINDOW): met failed with no verdict waiting, C was visited as a download, and B was moved onto
    /// N and served.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an owed visit inside a publication failure's bookkeeping passes the job for an apply made while it published (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPassesAPublicationFailingInItsBookkeeping(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.failureWindow(visit, seed: 1_516_302, applyInWindow: false)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: the follow passed C, publishing at the apply (visit-first): \(bResult)")
    }

    /// An apply made inside a publication failure's bookkeeping moves the job's moved ids, as a visit-first engine's visit
    /// at that apply met the job failed (`failureWindow`, v3 inside the window): behind the barrier the visit came after
    /// the verdict waited and passed C as a publication's verdict, so B was answered C's failure.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an apply inside a publication failure's bookkeeping moves the job's moved ids, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierMovesTheIdsOfAnApplyInsideAPublicationFailure(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.failureWindow(visit, seed: 1_616_302, applyInWindow: true)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N: v3's visit met C failed, its verdict not given (visit-first): \(bResult)")
    }
}
