import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A later apply while a follow is owed (R-SYN-3, R-SYN-11, F-28; Stage 3 close-out cycle 11, ruling S3-R14 items 2 and
/// 4): the second apply goes through the engine's own apply path (`applyAndFollow`, the store's `apply` and the engine's
/// follow of it, as a run or `ensureAvailable` applies). Each test runs in both orders (`LaneDropVisit`), with the
/// visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// The engine's copy with `entry` in place of the entry of the same id, or appended, under a digest of its own.
    @available(macOS 15.0, iOS 18.0, *)
    static func appliedCopy(of engine: SyncEngine, replacing entry: ManifestEntry, tag: String) async throws -> ValidatedManifest {
        let entries = await engine.readForTests { $0.state.applied.entries }
        var replaced = entries.map { $0.identifier == entry.identifier ? entry : $0 }
        if !entries.contains(where: { $0.identifier == entry.identifier }) {
            replaced.append(entry)
        }
        return try ValidatedManifest(entries: replaced, digest: ContentHash.sha256(of: Data(tag.utf8)))
    }

    // MARK: A carried job behind an owed pass (S3-R14 item 2, amendment (e))

    /// A job a follow passed while it verified waits, at a later apply, for the older pass that is still owed: V (100 KB,
    /// the content of a-v and a-w, one user waiter each) verifies, its publication held at its first store unit, when v3
    /// moves a-v and zz-f (F, downloading for a user waiter). a-v sorts before the 2,100 changed fillers, zz-f after them,
    /// so the follow's first turn passes V (verifying, it stays unfollowed) and its pass stops before zz-f. V's
    /// publication then fails with an I/O error (a retry), and v4 (one more filler changed) is applied. Visited first, the
    /// older follow ended with F's visit, which created F′, and v4's follow visited V and created V′ after it. With the
    /// older pass owed, v4's follow put V ahead of that pass's remaining finds, so V′ was created, and started, before F′
    /// (the cycle-10 draft's analysis of amendment (e) with an incomplete old pass).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a later apply during an owed pass visits the jobs it carries after that pass's finds (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierCarriesUnfollowedJobsBehindAnOwedPass(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), bulk: bulk, fileSystem: fileSystem)
        let engine = harness.engine
        let qBytes = EngineFixture.bytes(998_402, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let s = FollowBarrier.Setup(time: time, fileSystem: fileSystem, harness: harness, q: q)
        let vBytes = Data(repeating: 0xB1, count: 100_000)
        let fBytes = Data(repeating: 0xB2, count: 100_000)
        let v3Bytes = Data(repeating: 0xB3, count: 100_000)
        let f3Bytes = Data(repeating: 0xB4, count: 100_000)
        let av = EngineHarness.onDemand("a-v", vBytes)
        let aw = EngineHarness.onDemand("a-w", vBytes)
        let f = EngineHarness.onDemand("zz-f", fBytes)
        try #require(av.transferID == aw.transferID, "setup: a-v and a-w share V")
        await harness.serveManifest([q, av, aw] + FollowBarrier.fillers(730_000) + [f], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await harness.source.script(av.transferID, [.hold, .stage(vBytes), .stage(vBytes)])
        await harness.source.script(f.transferID, [.hold, .stage(fBytes)])
        let uv = Task { await engine.awaitAsset(av.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[av.transferID]?.state == .downloading }
        }
        let uw = Task { await engine.awaitAsset(aw.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[av.transferID]?.interests.count == 2 }
        let uf = Task { await engine.awaitAsset(f.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[f.transferID]?.state == .downloading }
        // V's publication holds at its first store unit; every later unit (the applies) runs.
        try #require(await bulk.heldUnits.isEmpty, "setup: no store unit is held yet")
        await bulk.setHolding(true)
        await harness.source.release(av.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[av.transferID]?.state == .verifying }
        try await bulk.requireHeldUnits(atLeast: 1)
        let vUnit = try #require(await bulk.heldUnits.first)
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: 2)
                for unit in await bulk.heldUnits where unit != vUnit {
                    await bulk.release(unit)
                }
            }
        }
        let fMoved = EngineHarness.onDemand("zz-f", f3Bytes)
        let avMoved = EngineHarness.onDemand("a-v", v3Bytes)
        await harness.source.script(fMoved.transferID, [.hold, .stage(f3Bytes)])
        await harness.source.script(avMoved.transferID, [.hold, .stage(v3Bytes)])
        let sync = await FollowBarrier.apply([q, avMoved, aw] + FollowBarrier.fillers(830_000) + [fMoved], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in
                (owed: e.followOwed, v: e.state.jobs[av.transferID]?.state, passed: e.state.unfollowed.contains(av.transferID) && !e.state.followOrder[e.state.followNext...].contains(av.transferID), f: e.state.jobs[fMoved.transferID] == nil)
            }
            #expect(before.owed && before.v == .verifying && before.passed && before.f, "setup: the first turn passed V while it verified, and F's find is owed: \(before)")
        }
        releaser.cancel()
        await releaser.value
        // The held unit is the first chunk of V's hash: its read of the claimed staging file fails.
        harness.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await bulk.setHolding(false)
        await engine.awaitCondition { e in
            if case .failed? = e.state.jobs[av.transferID]?.state { return true }
            return false
        }
        // v4: one more filler changed, applied through the engine's apply path while the older pass may still be owed.
        let v4 = try await Self.appliedCopy(of: engine, replacing: EngineHarness.onDemand("f00000", EngineFixture.bytes(930_000, count: 16)), tag: "v4-carried")
        let applied = await engine.applyAndFollow(v4, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "v4 is applied: \(applied)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { e in
                !e.followBarrier && e.state.jobs[fMoved.transferID]?.state == .downloading && e.state.jobs[avMoved.transferID]?.state == .downloading
            }
        }
        let order = await engine.readForTests { e in (f: e.state.jobs[fMoved.transferID]?.active?.startSequence, v: e.state.jobs[avMoved.transferID]?.active?.startSequence) }
        #expect(order.f != nil && order.v != nil && order.f! < order.v!, "F′, created by the older pass's last find, starts before V′, created by the later follow's visit of V (visit-first): \(order)")
        await harness.source.release(fMoved.transferID, with: .progress(received: 0, expected: nil))
        await harness.source.release(avMoved.transferID, with: .progress(received: 0, expected: nil))
        let ufResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: uf) }
        let uvResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: uv) }
        let uwResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: uw) }
        #expect((try? ufResult.get())?.byteSize == Int64(f3Bytes.count), "F's waiter is served from F′: \(ufResult)")
        #expect((try? uvResult.get())?.byteSize == Int64(v3Bytes.count), "a-v's waiter is served from V′: \(uvResult)")
        #expect((try? uwResult.get())?.byteSize == Int64(vBytes.count), "a-w's waiter is served by V's retry: \(uwResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: A join re-routed by a later apply (S3-R14 item 4)

    /// A request that waited for the follow is re-routed at its replay when a later apply moved its id meanwhile: H
    /// (zz-h) downloads for a user waiter, so the follow has a job to visit; v3 changes the fillers, so the follow owes
    /// its pass; U then requests zz-m (content M, listed), and v4 moves zz-m onto M′. Visited first, U's request created
    /// M's job and v4's follow moved U onto M′. Behind the barrier, U's join waited, and its replay met a copy that names
    /// zz-m elsewhere: `replayJoin` re-routes it as v4's follow would have. Joined to the content it named at its
    /// arrival, U was answered with M, the content v4 replaced (the cycle-10 verifiers' issue: the branch had no hit).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a request during an owed follow is re-routed at its replay when a later apply moved its id (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierReroutesAJoinALaterApplyMoved(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_302)
        let engine = s.engine
        let hBytes = Data(repeating: 0xB5, count: 100_000)
        let mBytes = Data(repeating: 0xB6, count: 200_000)
        let m4Bytes = Data(repeating: 0xB7, count: 300_000)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let m = EngineHarness.onDemand("zz-m", mBytes)
        let mMoved = EngineHarness.onDemand("zz-m", m4Bytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(720_000) + [h, m], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(m.transferID, [.hold, .stage(mBytes)])
        await s.harness.source.script(mMoved.transferID, [.stage(m4Bytes)])
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(820_000) + [h, m], s, visit: visit)
        let uWaiter = Task { await engine.awaitAsset(m.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, m) }
        } else {
            await engine.awaitCondition { $0.state.jobs[m.transferID]?.state == .downloading }
        }
        let v4 = try await Self.appliedCopy(of: engine, replacing: mMoved, tag: "v4-reroute")
        let applied = await engine.applyAndFollow(v4, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "v4 is applied: \(applied)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        // A job of M left running for U (the content v4 replaced) is let through, so its answer shows instead of a hang.
        let held = await engine.readForTests { $0.state.jobs[m.transferID]?.state == .downloading }
        if held {
            await s.harness.source.release(m.transferID, with: .progress(received: 0, expected: nil))
        }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        #expect((try? uResult.get())?.byteSize == Int64(m4Bytes.count), "U is served from M′, the content v4 lists (visit-first): \(uResult)")
        #expect(!held, "no job of M runs once the follow and its events are done: nobody wants the content v4 replaced")
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        let hResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        #expect((try? hResult.get())?.byteSize == Int64(hBytes.count), "H is served: \(hResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
