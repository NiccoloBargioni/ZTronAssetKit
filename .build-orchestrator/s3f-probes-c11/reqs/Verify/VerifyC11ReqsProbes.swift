import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Cycle-11 reqs-lens probes (verifier scratch; not for commit). Each runs in both orders; the expectations are the
/// visit-first outcome (S3-R11 item 3).
extension EngineSyncTests {
    /// `FollowBarrier.setUp` with a network policy: bulk (the run) admitted on a constrained network, prefetch not.
    @available(macOS 15.0, iOS 18.0, *)
    static func probeSetUp(seed: UInt64, network: NetworkPolicy) async throws -> FollowBarrier.Setup {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), network: network, fileSystem: fileSystem)
        let qBytes = EngineFixture.bytes(seed, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await harness.engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        return FollowBarrier.Setup(time: time, fileSystem: fileSystem, harness: harness, q: q)
    }

    /// PROBE-C11R-UNCONSTRAIN-DEMOTE (the draft's residual R-D, "a visit reads inputs that arrived after it was owed"):
    /// under Low Data Mode, C (1 MB, content X) downloads for A's user waiter (zz-a) and a prefetch member P (zz-p).
    /// v3 moves zz-a to a 16-byte content W while the follow owes C's visit. The network then becomes unrestricted.
    /// Visit-first: C's visit lowers it to the prefetch lane while Low Data Mode still holds, so `relane`'s demotion
    /// pause (`pauseIfRefused`) pauses it (1 pause), and the later unrestricted element re-admits it (2 starts). Behind
    /// the barrier the unrestricted conditions are already in `state.conditions` when the visit runs, so the demotion
    /// pause reads them and does not pause C (0 pauses, 1 start); the deferred conditions pass (snapshot unrestricted)
    /// pauses nothing either.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C11R-UNCONSTRAIN-DEMOTE", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func probeC11RUnconstrainDemote(_ visit: LaneDropVisit) async throws {
        let s = try await Self.probeSetUp(seed: 997_102, network: NetworkPolicy(bulkOnConstrained: true, prefetchOnConstrained: false))
        let engine = s.engine
        let xBytes = Data(repeating: 0xC1, count: 1_000_000)
        let wBytes = EngineFixture.bytes(997_104, count: 16)
        let p = EngineHarness.onDemand("zz-p", xBytes)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        try #require(a.transferID == p.transferID, "setup: zz-a and zz-p share X")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(741_000) + [a, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.conditions.send(EngineConditionsTests.lowData)
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions?.network.constrained == true }
        }
        await s.harness.source.script(p.transferID, [.hold, .stage(xBytes), .stage(xBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.interests.count == 2 }
        let aMoved = EngineHarness.onDemand("zz-a", wBytes)
        try #require(aMoved.transferID != p.transferID)
        await s.harness.source.script(aMoved.transferID, [.stage(wBytes)])
        // v3 is applied through the engine's apply path (`applyAndFollow`, as a run applies it): under Low Data Mode the
        // probe's run never reached its apply, so the apply is made directly (the fixer's R-E probe does the same).
        let v3Entries = [s.q] + FollowBarrier.fillers(841_000) + [aMoved, p]
        let v3 = try ValidatedManifest(entries: v3Entries, digest: ContentHash.sha256(of: Data("v3-unconstrain-demote".utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        let applied = await engine.applyAndFollow(v3, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "setup: v3 is applied: \(applied)")
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { e in (owed: e.followOwed, lane: e.state.jobs[p.transferID]?.lane, c: e.state.jobs[p.transferID]?.state) }
        print("PROBE-C11R-UNCONSTRAIN-DEMOTE \(visit) before: \(before)")
        let pausesBefore = await s.harness.source.controlLog.filter { $0.transfer == p.transferID && $0.control == .pause }.count
        print("PROBE-C11R-UNCONSTRAIN-DEMOTE \(visit) pausesAtBefore=\(pausesBefore)")
        if visit == .sweepFollowsFirst {
            #expect(before.owed && before.lane == .userInitiated && before.c == .downloading, "setup: C runs on the user lane and its visit is owed: \(before)")
        }
        await s.harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.conditions?.network.constrained == false }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { e in (lane: e.state.jobs[p.transferID]?.lane, c: e.state.jobs[p.transferID]?.state, policyPause: e.state.jobs[p.transferID]?.active?.policyPause) }
        let pauses = await s.harness.source.controlLog.filter { $0.transfer == p.transferID && $0.control == .pause }.count
        print("PROBE-C11R-UNCONSTRAIN-DEMOTE \(visit) after: \(after) pauses=\(pauses)")
        let wdbg = await engine.readForTests { e in "w=\(String(describing: e.state.jobs[aMoved.transferID].map { ($0.state, $0.lane, $0.interests.count) })) c=\(String(describing: e.state.jobs[p.transferID].map { ($0.state, $0.lane, $0.interests.count, $0.assets.sorted()) }))" }
        let starts0 = await s.harness.source.starts.map { $0.id == p.transferID ? "C" : ($0.id == aMoved.transferID ? "W" : "o") }
        print("PROBE-C11R-UNCONSTRAIN-DEMOTE \(visit) dbg: \(wdbg) starts=\(starts0)")
        #expect(pauses == 1, "PROBE-C11R-UNCONSTRAIN-DEMOTE: C's visit, lowering it under Low Data Mode, pauses it once (visit-first): \(pauses) pause(s)")
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A is served from W: \(aResult)")
        let hang = await engine.readForTests { e in "w=\(String(describing: e.state.jobs[aMoved.transferID].map { ($0.state, $0.lane, $0.interests.count, $0.epoch) })) owed=\(e.followOwed) barrier=\(e.followBarrier) events=\(e.state.eventsAfterFollow.count) held=\(e.state.jobs.values.filter { $0.state == .committing || $0.state == .verifying }.count) storeRuns=\(e.state.storeWorkRuns) storeInFlight=\(e.state.storeWorkInFlight) catchUps=\(e.state.manifestCatchUps)" }
        print("PROBE-C11R-UNCONSTRAIN-DEMOTE \(visit) hang: \(hang) store: \(await s.harness.store.debugCoreForProbe())")
        let held = await engine.readForTests { e in e.state.jobs[p.transferID]?.state == .downloading && e.state.jobs[p.transferID]?.active?.policyPause == nil }
        if held {
            await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID] == nil || $0.state.jobs[p.transferID]?.state == .committing || $0.state.jobs[p.transferID]?.state == .verifying }
        }
        let starts = await s.harness.source.starts.filter { $0.id == p.transferID }.count
        print("PROBE-C11R-UNCONSTRAIN-DEMOTE \(visit): pauses=\(pauses) starts=\(starts) a=\(aResult)")
        #expect(starts == 2, "PROBE-C11R-UNCONSTRAIN-DEMOTE: C, paused by its demotion, starts again once the network is unrestricted (visit-first): \(starts)")
        await engine.releaseGroup(group)
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.shutdown()
    }

    /// PROBE-C11R-COMMIT-REROUTE (the draft's residual R-A, "the publication and commit paths"): two slots. C (100 KB,
    /// content X) downloads for A's user waiter (zz-a) and B's (zz-b); H downloads for a third user waiter. v3 moves zz-a
    /// to a 16-byte content N while the follow owes C's visit. R (zz-r) is then requested for user work, and C completes.
    /// Visit-first: C's visit re-routed A to N before R's request, so N took its queue place first and takes the slot C's
    /// commit frees; R waits. Behind the barrier R's join waits, then C's commit re-routes A (its id is not bound) as a
    /// join that waits behind R's, so the drain places R first and R takes the slot.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C11R-COMMIT-REROUTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC11RCommitReroute(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 997_202, tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let engine = s.engine
        let xBytes = Data(repeating: 0xC3, count: 100_000)
        let hBytes = Data(repeating: 0xC4, count: 100_000)
        let rBytes = Data(repeating: 0xC5, count: 100_000)
        let nBytes = EngineFixture.bytes(997_204, count: 16)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        try #require(a.transferID == b.transferID)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(742_000) + [a, b, h, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(a.transferID, [.hold, .stage(xBytes)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(r.transferID, [.hold, .stage(rBytes)])
        await s.harness.source.script(aMoved.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[h.transferID]?.state == .downloading }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(842_000) + [aMoved, b, h, r], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, n: e.state.jobs[aMoved.transferID]?.state) }
            #expect(before.owed && before.c == .downloading && before.n == nil, "setup: C runs and its visit is owed: \(before)")
        }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[r.transferID] != nil || FollowBarrier.joinWaits($0, r) }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(xBytes.count), "B is served from X: \(bResult)")
        await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { e in (n: e.state.jobs[aMoved.transferID]?.state, r: e.state.jobs[r.transferID]?.state) }
        print("PROBE-C11R-COMMIT-REROUTE \(visit) after: \(after)")
        #expect(after.n == .downloading && after.r == .queued, "PROBE-C11R-COMMIT-REROUTE: N, created by C's visit before R's request, takes the slot C's commit frees (visit-first): \(after)")
        let first = after.n == .downloading ? aMoved.transferID : r.transferID
        let other = first == r.transferID ? aMoved.transferID : r.transferID
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await s.harness.source.release(first, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[other]?.state == .downloading }
        }
        await s.harness.source.release(other, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        let hResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        print("PROBE-C11R-COMMIT-REROUTE \(visit) results: a=\(aResult) r=\(rResult) h=\(hResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A is served from N: \(aResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}

