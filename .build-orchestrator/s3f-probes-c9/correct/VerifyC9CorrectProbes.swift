import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 9, correctness lens). Never committed.
///
/// Each runs in both orders (`LaneDropVisit`): `.followVisitedFirst` lets the held follow end before the event under
/// test; `.sweepFollowsFirst` delivers the event while the follow still owes the visit of the job the event concerns.
/// Every expectation is the visit-first outcome (S3-R11: every decision that differs, other than by a real-world ledger
/// input, is blocking).
@Suite("VerifyC9CorrectProbes")
struct VerifyC9CorrectProbes {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    /// PROBE-C9-JOIN-RESOLVE (the draft's own open residual "A join while a `.resolve` verdict waits"): C (1 MB) is the
    /// content of zz-a and zz-b, one user waiter each; v3 moves zz-a to a 16-byte content while the follow owes C's
    /// visit. C's attempt is rejected (400: a final failure, `resolveAll`), then a second user request for zz-b (B2)
    /// arrives. Visited first, the failure answers B and removes C; B2 creates a new job, whose attempt serves the bytes.
    /// With the verdict deferred, B2 joins the failed job and the drain answers it with the earlier attempt's failure.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9-JOIN-RESOLVE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func joinResolve(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 993_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0xC1, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(730_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.rejected(.unexpectedStatus(400))), .stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let nBytes = EngineFixture.bytes(993_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(830_000) + [aMoved, b], s, visit: visit)
        let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, n: e.state.jobs[aMoved.transferID]?.state) }
        print("PROBE-C9-JOIN-RESOLVE \(visit) before: \(before)")
        // C's attempt is rejected (final).
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let afterFailure = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID].map { ($0.state, $0.epoch, $0.interests.count) }, verdictWaits: e.state.verdictsAfterFollow[a.transferID] != nil)
        }
        print("PROBE-C9-JOIN-RESOLVE \(visit) afterFailure: \(afterFailure)")
        // A second user request for zz-b, after the failure.
        let b2Waiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { ($0.state.jobs[a.transferID]?.interests.count ?? 0) >= 3 }
            let joined = await engine.readForTests { e in (c: e.state.jobs[a.transferID].map { ($0.state, $0.interests.count) }, joined: e.state.verdictsAfterFollow[a.transferID]?.joined) }
            print("PROBE-C9-JOIN-RESOLVE \(visit) joined: \(joined)")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let b2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: b2Waiter) }
        let starts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        print("PROBE-C9-JOIN-RESOLVE \(visit) aResult: \(aResult) bResult: \(bResult) b2Result: \(b2Result) cStarts: \(starts)")
        #expect((try? aResult.get())?.byteSize == 16, "A is served from its new content: \(aResult)")
        #expect(bResult == .failure(.serverUnavailable(retryAfter: nil)), "B, waiting when the attempt was rejected, gets the failure: \(bResult)")
        #expect((try? b2Result.get())?.byteSize == Int64(cBytes.count), "PROBE-C9-JOIN-RESOLVE: B2, requested after the failure, is served by a new attempt (visit-first): \(b2Result)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C9-OFFLINE (the draft's residual "the offline and throttle exits"): C (1 MB) is the content of zz-a and
    /// zz-b, one user waiter each; v3 moves zz-a to a 16-byte content N while the follow owes C's visit. C's attempt
    /// fails offline (`.noConnection`) with no network edge during the attempt (the path monitor still reads
    /// satisfied). Visited first, A's interest is on N, which is started and serves A; the offline failure answers only
    /// B. Before the visit, the failure's fail-fast (`failed(.whenOnline)`, `failFast(.offline)`) answers A too.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9-OFFLINE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func offline(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 994_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0xC2, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(740_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.offline(.noConnection)), .stage(cBytes)])
        // C's attempt starts after the watcher's first reading (a prefetch member waits for one), so its offline
        // failure waits for the next edge (`failed(.whenOnline)`), not retried at once.
        let group = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 3 }
        let serial = await engine.readForTests { e in (e.state.jobs[a.transferID]?.active?.edgeSerial, e.state.networkEdgeSerial) }
        print("PROBE-C9-OFFLINE \(visit) edge serials (attempt, engine): \(serial)")
        let nBytes = EngineFixture.bytes(994_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(840_000) + [aMoved, b], s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let afterFailure = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID].map { ($0.state, $0.interests.count) }, satisfied: e.state.conditions?.network.satisfied)
        }
        print("PROBE-C9-OFFLINE \(visit) afterFailure: \(afterFailure)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C9-OFFLINE \(visit) aResult: \(aResult) bResult: \(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "PROBE-C9-OFFLINE: A, moved to N, is served from N, not answered with C's offline failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.offline), "B gets C's offline failure: \(bResult)")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C9-JOIN-RETRY-PLACE (the second half of the draft's residual: "a retry verdict with a user joiner has the
    /// same placement gap"): one transfer slot. C (1 MB) is the content of zz-a and zz-b, one user waiter each; v3 moves
    /// zz-a to N (16 bytes, held once started) while the follow owes C's visit. C's attempt fails transiently (a retry
    /// verdict), then a user request for R (zz-r, another content) arrives, then a second user request for zz-b (B2), which
    /// skips C's backoff (T20). Visited first, R is queued before B2's join re-queues C, so R starts before C's second
    /// attempt. With the verdict deferred, the drain re-queues C at the verdict's place, ahead of R's later place.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9-JOIN-RETRY-PLACE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func joinRetryPlace(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 995_002, tuning: SyncTuning(maxConcurrentTransfers: 1))
        let engine = s.engine
        let cBytes = Data(repeating: 0xC3, count: 1_000_000)
        let rBytes = Data(repeating: 0xC4, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(750_000) + [a, b, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(cBytes)])
        await s.harness.source.script(r.transferID, [.stage(rBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let nBytes = EngineFixture.bytes(995_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.hold, .stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(850_000) + [aMoved, b, r], s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[r.transferID] != nil }
        let b2Waiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID]?.joined == true }
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 && $0.state.jobs[a.transferID]?.state == .queued }
        }
        let mid = await engine.readForTests { e in (c: e.state.jobs[a.transferID].map { ($0.state, $0.interests.count) }, r: e.state.jobs[r.transferID]?.state, n: e.state.jobs[aMoved.transferID]?.state) }
        print("PROBE-C9-JOIN-RETRY-PLACE \(visit) mid: \(mid)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[aMoved.transferID]?.state == .downloading && !$0.followBarrier }
        }
        await s.harness.source.release(aMoved.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        let b2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: b2Waiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let starts = await s.harness.source.starts.map(\.id)
        let rIndex = starts.firstIndex(of: r.transferID)
        let cSecond = starts.indices.filter { starts[$0] == a.transferID }.dropFirst().first
        print("PROBE-C9-JOIN-RETRY-PLACE \(visit) starts r=\(String(describing: rIndex)) c2=\(String(describing: cSecond)) n=\(String(describing: starts.firstIndex(of: aMoved.transferID))) a=\(aResult) b=\(bResult) b2=\(b2Result) r=\(rResult)")
        #expect(rIndex != nil && cSecond != nil && rIndex! < cSecond!, "PROBE-C9-JOIN-RETRY-PLACE: R, requested before B2's join re-queued C, starts before C's second attempt (visit-first): r=\(String(describing: rIndex)) c2=\(String(describing: cSecond))")
        #expect((try? b2Result.get())?.byteSize == Int64(cBytes.count), "B2 is served: \(b2Result)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C9-THROTTLE (the draft's residual "a 429's throttle park and its fail-fast answers"): C (1 MB) is the content
    /// of zz-a and zz-b, one user waiter each; v3 moves zz-a to N (16 bytes, held once started) while the follow owes C's
    /// visit. C's attempt gets a 429 with Retry-After 60 s (above the interactive 2 s wait). Visited first, A's interest is
    /// on N, already started, and N serves it; the throttle's fail-fast answers B only. Before the visit, the park's
    /// fail-fast answers A as well.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9-THROTTLE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func throttle(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 996_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0xC5, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(760_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let nBytes = EngineFixture.bytes(996_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.hold, .stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(860_000) + [aMoved, b], s, visit: visit)
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[aMoved.transferID]?.state == .downloading }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let afterFailure = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID].map { ($0.state, $0.interests.count) }) }
        print("PROBE-C9-THROTTLE \(visit) afterFailure: \(afterFailure)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        if visit == .sweepFollowsFirst {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { !$0.followBarrier }
            }
        }
        await s.harness.source.release(aMoved.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C9-THROTTLE \(visit) aResult: \(aResult) bResult: \(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "PROBE-C9-THROTTLE: A, moved to N, is served from N, not answered with C's throttle (visit-first): \(aResult)")
        if case .failure(.serverUnavailable) = bResult {
        } else {
            Issue.record("B gets the throttle's answer: \(bResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C9-STALE-PLACE: `.enqueue` events carry no epoch. During the owed follow a prefetch request for zz-k (v3 maps
    /// it to X, the new content of zz-a) creates job X, whose place waits (e1); the request is withdrawn, so X is removed.
    /// The follow then visits zz-a's holder C and creates X again for A's interest (queued at once: a visit's own place),
    /// then zz-z's holder D, creating Z. The drain replays e1 on the new X: it is queued again, behind Z. Visited first,
    /// X is created before Z, keeps its place (a prefetch join does not re-queue it) and starts first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9-STALE-PLACE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func stalePlace(_ visit: LaneDropVisit) async throws {
        try await Self.stalePlace(visit, withK: true)
    }

    /// The control: the same scenario without zz-k's request (no stale event) starts X first in both orders.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9-STALE-PLACE-CONTROL", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func stalePlaceControl(_ visit: LaneDropVisit) async throws {
        try await Self.stalePlace(visit, withK: false)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func stalePlace(_ visit: LaneDropVisit, withK: Bool) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 997_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0xD1, count: 100_000)
        let dBytes = Data(repeating: 0xD2, count: 100_000)
        let xBytes = Data(repeating: 0xD3, count: 100_000)
        let zBytes = Data(repeating: 0xD4, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let z = EngineHarness.onDemand("zz-z", dBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(770_000) + [a, z], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold])
        await s.harness.source.script(z.transferID, [.hold])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .prefetch) }
        let zWaiter = Task { await engine.awaitAsset(z.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[z.transferID]?.state == .downloading }
        }
        let aNew = EngineHarness.onDemand("zz-a", xBytes)
        let zNew = EngineHarness.onDemand("zz-z", zBytes)
        let k = EngineHarness.onDemand("zz-k", xBytes)
        try #require(k.transferID == aNew.transferID, "setup: zz-k names A's new content X")
        await s.harness.source.script(aNew.transferID, [.stage(xBytes)])
        await s.harness.source.script(zNew.transferID, [.stage(zBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(870_000) + [aNew, zNew, k], s, visit: visit)
        let kWaiter = Task { withK ? await engine.awaitAsset(k.identifier, lane: .prefetch) : .failure(.cancelled) }
        if visit == .sweepFollowsFirst, withK {
            await engine.awaitCondition { $0.state.placesAfterFollow[aNew.transferID] == 1 }
            kWaiter.cancel()
            await engine.awaitCondition { $0.state.jobs[aNew.transferID] == nil }
            let mid = await engine.readForTests { e in (owed: e.followOwed, places: e.state.placesAfterFollow[aNew.transferID], events: e.state.eventsAfterFollow.count) }
            print("PROBE-C9-STALE-PLACE \(visit) mid: \(mid)")
        } else {
            kWaiter.cancel()
        }
        _ = await kWaiter.value
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let zResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: zWaiter) }
        let starts = await s.harness.source.starts.map(\.id)
        let xIndex = starts.firstIndex(of: aNew.transferID)
        let zIndex = starts.firstIndex(of: zNew.transferID)
        print("PROBE-C9-STALE-PLACE withK=\(withK) \(visit) starts x=\(String(describing: xIndex)) z=\(String(describing: zIndex)) a=\((try? aResult.get())?.byteSize as Any) z=\((try? zResult.get())?.byteSize as Any)")
        #expect(xIndex != nil && zIndex != nil && xIndex! < zIndex!, "PROBE-C9-STALE-PLACE: X, created by the follow before Z, starts first (visit-first): x=\(String(describing: xIndex)) z=\(String(describing: zIndex))")
        #expect((try? aResult.get())?.byteSize == Int64(xBytes.count), "A is served from X: \(aResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// PROBE-C9-SPURIOUS-JOIN: the follow's own visit of a job whose retry verdict waits marks the verdict `joined`
    /// (`removeInterest` → `relane` → `verdictsAfterFollow[...]?.joined = true`) although nobody joined, so the drain
    /// re-runs `relane` after `retryLater` and a remaining user interest skips the backoff (T20). C (1 MB) is the content
    /// of zz-a and zz-b, one user waiter each; v3 moves zz-a while the follow owes C's visit; C's attempt fails with a 500.
    /// Visited first, C backs off (`failed(.at)`) and no second attempt starts before the clock passes the backoff.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C9-SPURIOUS-JOIN", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func spuriousJoin(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0xE1, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(780_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let nBytes = EngineFixture.bytes(998_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(880_000) + [aMoved, b], s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        // No clock movement: only the follow's turns, the drain and the pumps run.
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled && $0.state.jobs[a.transferID]?.state != .failed(.nextRun) }
        let aResult = await EngineHarness.value(of: aWaiter)
        let after = await engine.readForTests { e in (state: e.state.jobs[a.transferID]?.state, attempts: e.state.jobs[a.transferID]?.attempts, interests: e.state.jobs[a.transferID]?.interests.count) }
        let cStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        print("PROBE-C9-SPURIOUS-JOIN \(visit) after (clock unmoved): \(after) cStarts=\(cStarts) a=\((try? aResult.get())?.byteSize as Any)")
        if case .failed(.at)? = after.state {
        } else {
            Issue.record("PROBE-C9-SPURIOUS-JOIN: C backs off after its 500 (visit-first), not re-queued at once: \(after), starts \(cStarts)")
        }
        #expect(cStarts == 1, "PROBE-C9-SPURIOUS-JOIN: no second attempt before the backoff ends: \(cStarts)")
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B is served by the retry: \(bResult)")
        await FollowBarrier.finish(s, sync: sync)
    }
}
