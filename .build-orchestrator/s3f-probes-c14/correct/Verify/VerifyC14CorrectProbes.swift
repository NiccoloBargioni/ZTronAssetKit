import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 14, correctness lens). Never committed.
///
/// Each runs in both orders (`LaneDropVisit`); every expectation is the visit-first outcome.
@Suite("VerifyC14CorrectProbes", .serialized)
struct VerifyC14CorrectProbes {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// `EngineFollowBarrierTests.setUpHeldPublications` with a tuning.
    @available(macOS 15.0, iOS 18.0, *)
    static func setUpHeld(seed: UInt64, tuning: SyncTuning) async throws -> (FollowBarrier.Setup, SteppedBlockingExecutor) {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, tuning: tuning, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), bulk: bulk, fileSystem: fileSystem)
        let qBytes = EngineFixture.bytes(seed, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await harness.engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        return (FollowBarrier.Setup(time: time, fileSystem: fileSystem, harness: harness, q: q), bulk)
    }

    /// PROBE-C13R-STAMP-BREAKER re-run against cycle 14, with 2 slots (the cycle-13 reqs probe) and 3 slots (a slot is free
    /// at the apply, so N's place is stamped with the half-open view).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C14C-STAMP-BREAKER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [2, 3])
    func stampBreaker(_ visit: LaneDropVisit, _ slots: Int) async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: slots, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let (s, _) = try await FollowBarrier.setUp(seed: 1_499_002, tuning: tuning)
        let engine = s.engine
        let origin = s.harness.source.originID
        let xBytes = Data(repeating: 0xB4, count: 100_000)
        let mBytes = Data(repeating: 0xB5, count: 100_000)
        let kBytes = Data(repeating: 0xB6, count: 100_000)
        let hBytes = Data(repeating: 0xB7, count: 100_000)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let m = EngineHarness.onDemand("zz-m", mBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_499_100) + [h, k, m, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(x.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        await s.harness.source.script(m.transferID, [.hold, .stage(mBytes)])
        await s.harness.source.script(k.transferID, [.hold, .stage(kBytes)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        let hGroup = try await engine.registerGroup([h.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        let xResult = await engine.awaitAsset(x.identifier, lane: .userInitiated)
        #expect((try? xResult.get()) == nil, "setup: X's 403 fails it: \(xResult)")
        let group = try await engine.registerGroup([m.identifier, k.identifier], lane: .prefetch).get()
        await engine.awaitCondition { e in
            e.state.jobs[m.transferID]?.state.isCircuitParked == true && e.state.jobs[k.transferID]?.state.isCircuitParked == true
        }
        let opened = await engine.readForTests { $0.state.breakers[origin]?.state }
        guard case .open(_, let cooldownEnd, _)? = opened else {
            Issue.record("setup: X's 403 opened the breaker: \(String(describing: opened))")
            await engine.shutdown()
            return
        }
        EngineRegressionCycle21Tests.advance(s.time, to: cooldownEnd)
        await engine.awaitCondition { $0.state.jobs[m.transferID]?.state == .downloading || $0.state.jobs[k.transferID]?.state == .downloading }
        let mProbes = await engine.readForTests { $0.state.jobs[m.transferID]?.state == .downloading }
        let probe = mProbes ? m : k
        let parkedName = mProbes ? "zz-k" : "zz-m"
        let nBytes = EngineFixture.bytes(1_499_004, count: 16)
        let nEntry = EngineHarness.onDemand(parkedName, nBytes)
        await s.harness.source.script(nEntry.transferID, [.hold, .stage(nBytes)])
        let v3: [ManifestEntry] = [h, mProbes ? nEntry : k, mProbes ? m : nEntry, x]
        try await EngineFollowBarrierTests.applyHeld([s.q] + FollowBarrier.fillers(1_499_200) + v3, tag: "v3-c14c-stamp-breaker-\(slots)", s, visit: visit)
        let stamped = await engine.readForTests { e in (n: e.state.jobs[nEntry.transferID]?.state, stamped: e.state.placeStamps[nEntry.transferID] != nil) }
        print("PROBE-C14C-STAMP-BREAKER \(visit) slots=\(slots) afterApply=\(stamped)")
        await s.harness.source.release(probe.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in e.state.breakers[origin]?.state == .closed && e.state.jobs[probe.transferID] == nil }
        let beforeEnd = await engine.readForTests { e in (n: e.state.jobs[nEntry.transferID]?.state, stamped: e.state.placeStamps[nEntry.transferID] != nil) }
        print("PROBE-C14C-STAMP-BREAKER \(visit) slots=\(slots) breakerClosed=\(beforeEnd)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await engine.awaitCondition { e in
            let state = e.state.jobs[nEntry.transferID]?.state
            return state != nil && state != .queued
        }
        let snap = await engine.readForTests { e in
            (n: e.state.jobs[nEntry.transferID]?.state, breaker: e.state.breakers[origin]?.state, alarm: e.state.heap.deadline(for: .breaker(origin)) != nil)
        }
        print("PROBE-C14C-STAMP-BREAKER \(visit) slots=\(slots) atEnd=\(snap)")
        let midViolations = await engine.invariantViolations()
        #expect(midViolations.isEmpty, "PROBE-C14C-STAMP-BREAKER: invariants at the barrier's end: \(midViolations.prefix(3))")
        if snap.n != .downloading {
            EngineRegressionCycle21Tests.advance(s.time, to: s.time.monotonicNow().adding(seconds: 3_600))
            for _ in 0..<20 {
                await engine.readForTests { _ in }
                await Task.yield()
            }
            let later = await engine.readForTests { e in (n: e.state.jobs[nEntry.transferID]?.state, pending: e.state.groups[group]?.pending.count) }
            print("PROBE-C14C-STAMP-BREAKER \(visit) slots=\(slots) afterAnHour=\(later)")
        }
        #expect(snap.n == .downloading, "PROBE-C14C-STAMP-BREAKER: N runs once the breaker closed (visit-first): \(snap)")
        if snap.n == .downloading {
            await s.harness.source.release(nEntry.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[nEntry.transferID] == nil }
            }
            let served = await engine.readForTests { e in e.state.groups[group]?.pending.isEmpty }
            #expect(served == true, "PROBE-C14C-STAMP-BREAKER: the group's members are served: \(String(describing: served))")
        }
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h.transferID] == nil }
        }
        await engine.releaseGroup(group)
        await engine.releaseGroup(hGroup)
        await EngineFollowBarrierTests.finishHeld(s)
    }

    /// PROBE-C14C-MARK-TWO-APPLIES: one publication passed by two applies' follows. C (100 kB, the content of zz-a, zz-b,
    /// zz-c, a user waiter each) begins to publish after v3's apply (which moves zz-b to N); v4, applied while that same
    /// publication still verifies, moves zz-c to N2. C's bytes then fail their checksum.
    /// Visit-first: v3's visit moved B onto N while C downloaded (B served N); v4's follow passed C, publishing, so zz-c
    /// stayed on C and its user got C's `integrityFailure`, as A did.
    /// Behind v3's barrier, v3's pass marks C `publishedAfterApply`; v4's pass keeps the mark; at the failure
    /// `followPassedPublication` moves every id the copy lists elsewhere, zz-c included.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C14C-MARK-TWO-APPLIES", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func markTwoApplies(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_414_002
        let (s, bulk) = try await EngineFollowBarrierTests.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let n2Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        let cMoved = EngineHarness.onDemand("zz-c", n2Bytes)
        try #require(a.transferID == b.transferID && a.transferID == c.transferID, "setup: zz-a, zz-b, zz-c share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, c] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        await s.harness.source.script(cMoved.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        let cWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 3 }
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved, c] + EngineFollowBarrierTests.laterFillers(seed + 6_000)
        try await EngineFollowBarrierTests.applyHeld(v3, tag: "v3-c14c-two-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID] == nil }
            }
        }
        let releaser = try await EngineFollowBarrierTests.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            await EngineFollowBarrierTests.runOneFollowTurn(engine)
            let passed = await engine.readForTests { e in
                (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, mark: e.state.jobs[a.transferID]?.passedPublishing)
            }
            print("PROBE-C14C-MARK-TWO-APPLIES \(visit) after v3's pass: \(passed)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        // v4 while the same publication still verifies: its follow passes C in both orders.
        let v4 = [s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved, cMoved] + EngineFollowBarrierTests.laterFillers(seed + 6_000)
        try await EngineFollowBarrierTests.applyHeld(v4, tag: "v4-c14c-two-\(seed)", s, visit: .followVisitedFirst)
        let atV4 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, mark: e.state.jobs[a.transferID]?.passedPublishing, assets: e.state.jobs[a.transferID]?.assets.sorted())
        }
        print("PROBE-C14C-MARK-TWO-APPLIES \(visit) after v4's follow: \(atV4)")
        try #require(atV4.c == .verifying, "setup: the same publication still verifies at v4: \(atV4)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let cResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: cWaiter) }
        print("PROBE-C14C-MARK-TWO-APPLIES \(visit) a=\(aResult) b=\(bResult) c=\(cResult)")
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N (visit-first): \(bResult)")
        #expect(cResult == .failure(.integrityFailure), "PROBE-C14C-MARK-TWO-APPLIES: zz-c's user gets C's integrity failure: v4's follow passed C, publishing, in both orders (visit-first): \(cResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineFollowBarrierTests.finishHeld(s)
    }

    /// PROBE-C14C-PASSED-LANE (RR-1's remainder, cycle 14): a 429 while a job that publishes, but downloaded at the apply,
    /// holds the moved user interest. Interactive `maxRetryAfter` 30 s, background 3,600 s. C (1 MB, zz-b) runs for P, a
    /// prefetch waiter; Y (100 kB, zz-u) runs for U, a user waiter; v3 moves zz-u onto C's content. Visit-first, v3's
    /// visit superseded Y while it downloaded and moved U onto C, so C was user work: its 429 with Retry-After 60 s was
    /// `.exhausted` (no throttle), C failed `.nextRun`, P and U were answered `serverUnavailable(60)`. Behind the barrier Y
    /// verifies when C's 429 arrives; `followedLane(C)` skips publishing jobs, so C is prefetch work.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C14C-PASSED-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func passedLane(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_414_502
        let (s, bulk) = try await Self.setUpHeld(seed: seed, tuning: SyncTuning(interactiveRetry: EngineFollowBarrierTests.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xC1, count: 1_000_000)
        let yBytes = Data(repeating: 0xC2, count: 100_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let u = EngineHarness.onDemand("zz-u", yBytes)
        let y2 = EngineHarness.onDemand("zz-y", yBytes)
        let uMoved = EngineHarness.onDemand("zz-u", cBytes)
        try #require(y2.transferID == u.transferID, "setup: zz-u and zz-y share Y")
        try #require(uMoved.transferID == b.transferID, "setup: v3's zz-u is C's content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, u, y2] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(yBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        }
        let qWaiter = Task { await engine.awaitAsset(y2.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[u.transferID]?.interests.count == 2 }
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + [b, uMoved, y2] + EngineFollowBarrierTests.laterFillers(seed + 6_000)
        try await EngineFollowBarrierTests.applyHeld(v3, tag: "v3-c14c-lane-\(seed)", s, visit: visit)
        var releaser: Task<Void, Never>?
        if visit == .sweepFollowsFirst {
            let pre = await engine.readForTests { e in (store: e.state.storeWorkInFlight, y: e.state.jobs[u.transferID]?.state, c: e.state.jobs[b.transferID]?.state) }
            print("PROBE-C14C-PASSED-LANE \(visit) pre-hold: \(pre)")
            await engine.awaitCondition { !$0.state.storeWorkInFlight }
            await bulk.setHolding(true)
            await s.harness.source.release(u.transferID, with: .progress(received: 0, expected: nil))
            for _ in 0..<200 {
                let y = await engine.readForTests { e in e.state.jobs[u.transferID]?.state }
                if y != .downloading { break }
                await Task.yield()
            }
            let mid = await engine.readForTests { e in (y: e.state.jobs[u.transferID]?.state, store: e.state.storeWorkInFlight, owed: e.followOwed) }
            let held = await bulk.heldUnits.count
            print("PROBE-C14C-PASSED-LANE \(visit) after Y's release: \(mid) heldUnits=\(held)")
            await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .verifying }
            try await bulk.requireHeldUnits(atLeast: 1)
            let unit = try #require(await bulk.heldUnits.first)
            releaser = Task {
                while !Task.isCancelled {
                    await bulk.waitForHeldUnits(atLeast: 2)
                    for other in await bulk.heldUnits where other != unit {
                        await bulk.release(other)
                    }
                }
            }
        }
        let before = await engine.readForTests { e in
            (owed: e.followOwed, y: e.state.jobs[u.transferID]?.state, cLane: e.state.jobs[b.transferID]?.lane)
        }
        print("PROBE-C14C-PASSED-LANE \(visit) before the 429: \(before)")
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let atArrival = await engine.readForTests { e in
            (throttle: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[b.transferID]?.state)
        }
        print("PROBE-C14C-PASSED-LANE \(visit) right after the 429: \(atArrival)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let afterDrain = await engine.readForTests { e in
            (throttle: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[b.transferID]?.state, y: e.state.jobs[u.transferID]?.state, mark: e.state.jobs[u.transferID]?.passedPublishing)
        }
        print("PROBE-C14C-PASSED-LANE \(visit) after the drain: \(afterDrain)")
        releaser?.cancel()
        await releaser?.value
        await bulk.setHolding(false)
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let cStarts = await s.harness.source.starts.filter { $0.id == b.transferID }.count
        if visit == .followVisitedFirst {
            await s.harness.source.release(u.transferID, with: .progress(received: 0, expected: nil))
        }
        let qResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: qWaiter) }
        print("PROBE-C14C-PASSED-LANE \(visit) u=\(uResult) p=\(pResult) q=\(qResult) cStarts=\(cStarts)")
        #expect(atArrival.throttle == nil, "PROBE-C14C-PASSED-LANE: the 429 beyond the user lane's cap throttles nothing (visit-first .exhausted): \(atArrival)")
        if case .failure(.serverUnavailable) = pResult {
        } else {
            Issue.record("PROBE-C14C-PASSED-LANE: P is answered serverUnavailable with C's deferral to the next run (visit-first): \(pResult)")
        }
        if case .failure(.serverUnavailable) = uResult {
        } else {
            Issue.record("U is answered serverUnavailable (visit-first): \(uResult)")
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineFollowBarrierTests.finishHeld(s)
    }

    /// PROBE-C14C-STAMP-AHEAD (cycle 14's slot record, `4b3dcee`): two slots. C (1 MB, held) downloads for user A and
    /// holds one. While the follow is owed, user requests zz-k1 (K1, held when it runs); then an unknown id's manifest
    /// fetch gets a 429 with Retry-After 3 s (no transfer slot is freed by it); then user requests zz-k2 (K2).
    /// Visit-first: K1 started at once and took the free slot; the 429 throttled the origin; K2 was queued with no slot
    /// free, so the pump gated nothing; the clock passes the throttle's end, C completes, and K2 starts on the live gates
    /// and is served. Behind the barrier both places are stamped "slot free" (K1 had not started), and the barrier-end
    /// pump refuses K2 on its stamp's throttle although the throttle has ended.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C14C-STAMP-AHEAD", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func stampAhead(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_414_802, tuning: SyncTuning(maxConcurrentTransfers: 2))
        let engine = s.engine
        let cBytes = Data(repeating: 0xD3, count: 1_000_000)
        let k1Bytes = EngineFixture.bytes(1_414_804, count: 16)
        let k2Bytes = EngineFixture.bytes(1_414_805, count: 20)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k1 = EngineHarness.onDemand("zz-k1", k1Bytes)
        let k2 = EngineHarness.onDemand("zz-k2", k2Bytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_414_900) + [a, k1, k2], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(k1.transferID, [.hold, .stage(k1Bytes)])
        await s.harness.source.script(k2.transferID, [.stage(k2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_415_000) + [a, k1, k2], s, visit: visit)
        let k1Waiter = Task { await engine.awaitAsset(k1.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, k1) }
        } else {
            await engine.awaitCondition { $0.state.jobs[k1.transferID]?.state == .downloading }
        }
        await s.harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(3)))])
        let none = await engine.awaitAsset("zz-none", lane: .userInitiated)
        let throttled = await engine.readForTests { e in
            (barrier: e.followBarrier, left: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[a.transferID]?.state, k1: e.state.jobs[k1.transferID]?.state)
        }
        print("PROBE-C14C-STAMP-AHEAD \(visit) after the manifest 429: none=\(none) \(throttled)")
        try #require(throttled.left != nil, "setup: the origin is throttled: \(throttled)")
        let k2Waiter = Task { await engine.awaitAsset(k2.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, k2) }
        } else {
            await engine.awaitCondition { $0.state.jobs[k2.transferID]?.state == .queued }
        }
        s.time.advance(by: 4)
        await engine.awaitCondition { e in e.state.remote.flatMap { e.state.throttles[$0.originID] }.map { $0 <= e.environment.time.monotonicNow() } ?? true }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let atEnd = await engine.readForTests { e in (k1: e.state.jobs[k1.transferID]?.state, k2: e.state.jobs[k2.transferID]?.state) }
        print("PROBE-C14C-STAMP-AHEAD \(visit) at the barrier's end: \(atEnd)")
        await engine.awaitCondition { $0.state.jobs[k1.transferID]?.state == .downloading }
        await s.harness.source.release(k1.transferID, with: .progress(received: 0, expected: nil))
        let k2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: k2Waiter) }
        let k1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: k1Waiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let k2Starts = await s.harness.source.starts.filter { $0.id == k2.transferID }.count
        print("PROBE-C14C-STAMP-AHEAD \(visit) k2=\(k2Result) k1=\(k1Result) a=\(aResult) k2Starts=\(k2Starts)")
        #expect((try? k1Result.get())?.byteSize == 16, "K1 is served (visit-first): \(k1Result)")
        #expect((try? k2Result.get())?.byteSize == 20, "PROBE-C14C-STAMP-AHEAD: K2's caller is served (visit-first: K2 waited for a slot K1 had taken, and started on the live gates after the throttle ended): \(k2Result)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
