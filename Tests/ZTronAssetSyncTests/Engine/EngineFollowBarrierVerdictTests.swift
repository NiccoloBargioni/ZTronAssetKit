import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The follow barrier and what happens to a job whose attempt ended while a follow owed the visit of one of its ids
/// (R-SYN-11, R-SYN-3, F-28; Stage 3 close-out cycle 10, the cycle-9 verifiers' probes). Every exit of such an attempt
/// is decided on the followed state (S3-R11 amendment (c)); these tests pin the exits and the requests that meet the job
/// while its verdict waits. Each runs in both orders (`LaneDropVisit`), with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    // MARK: Joins while a verdict waits

    /// A user request made after a failure whose verdict waits for the follow is served by a new job, as it is when the
    /// follow visits first: C (1 MB) is the content of zz-a and zz-b, one user waiter each (A, B); v3 moves zz-a to a
    /// 16-byte content while the follow owes C's visit. C's attempt is refused (a 400: final for the run), then a second
    /// user request for zz-b (B2) arrives. Visited first, the refusal answers B and removes C; B2 creates a new job, whose
    /// attempt serves the bytes. With the verdict waiting, B2 joined the failed job and the drain answered it with the
    /// earlier attempt's failure (PROBE-C9-JOIN-RESOLVE, PROBE-C9R-JOIN-RESOLVE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a user request made after a failure whose verdict waits for the follow is served by a new job, as visit-first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierServesARequestMadeAfterAWaitingFinalFailure(_ visit: LaneDropVisit) async throws {
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
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        }
        // C's attempt is refused (final for the run) in both orders.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        }
        // A second user request for zz-b, after the refusal.
        let b2Waiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.waiters.values.filter { $0.asset == b.identifier }.count == 2 }
            let state = await engine.readForTests { e in (owed: e.followOwed, violations: e.invariantViolations()) }
            #expect(state.owed && state.violations.isEmpty, "setup: the follow still owes C's visit when B2 asks: \(state)")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let b2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: b2Waiter) }
        let starts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        #expect((try? aResult.get())?.byteSize == 16, "A is served from its new content: \(aResult)")
        #expect(bResult == .failure(.serverUnavailable(retryAfter: nil)), "B, waiting when the attempt was refused, gets the refusal: \(bResult)")
        #expect((try? b2Result.get())?.byteSize == Int64(cBytes.count), "B2, asking after the refusal, is served by a new attempt (visit-first): \(b2Result)")
        #expect(starts == 2, "C's content started twice: the refused attempt and B2's new job: \(starts)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A user request that skips a waiting retry's backoff takes its place in the queue when it arrives, after a request
    /// made before it: one transfer slot; C (1 MB) is the content of zz-a and zz-b, one user waiter each; v3 moves zz-a to
    /// N (16 bytes, held once started) while the follow owes C's visit. C's attempt fails transiently (a retry), then a user
    /// request for R (another content) arrives, then a second user request for zz-b (B2), which skips C's backoff (T20).
    /// Visited first, R is queued before B2's join re-queues C, so R starts before C's second attempt. With the verdict
    /// waiting, the drain re-queued C at the verdict's place, ahead of R (PROBE-C9-JOIN-RETRY-PLACE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a user request that joins a job whose retry waits for the follow re-queues it at the request's own place (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPlacesAJoinOfAWaitingRetryAtItsArrival(_ visit: LaneDropVisit) async throws {
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
            await engine.awaitCondition { $0.state.waiters.values.filter { $0.asset == b.identifier }.count == 2 }
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 && $0.state.jobs[a.transferID]?.state == .queued }
        }
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
        #expect(rIndex != nil && cSecond != nil && rIndex! < cSecond!, "R, requested before B2's join re-queued C, starts before C's second attempt (visit-first): r=\(String(describing: rIndex)) c2=\(String(describing: cSecond))")
        #expect((try? aResult.get())?.byteSize == 16, "A is served from N: \(aResult)")
        #expect((try? rResult.get())?.byteSize == Int64(rBytes.count), "R is served: \(rResult)")
        #expect((try? b2Result.get())?.byteSize == Int64(cBytes.count), "B2 is served by C's second attempt: \(b2Result)")
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B is served by C's second attempt: \(bResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// The follow's own visit of a job whose retry waits is no join: C (1 MB) is the content of zz-a and zz-b, one user
    /// waiter each; v3 moves zz-a while the follow owes C's visit; C's attempt fails with a 500 (a retry). Visited first,
    /// C backs off (`failed(.at)`) and no second attempt starts before the clock passes the backoff. The visit that moved
    /// A's interest off the failed job marked the verdict joined, and the drain re-queued C at once, skipping the backoff
    /// (T20) with nobody joining (PROBE-C9-SPURIOUS-JOIN).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: the follow's visit of a job whose retry waits for the follow keeps the retry's backoff (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierKeepsAWaitingRetrysBackoffThroughTheVisit(_ visit: LaneDropVisit) async throws {
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
        let after = await engine.readForTests { e in (state: e.state.jobs[a.transferID]?.state, interests: e.state.jobs[a.transferID]?.interests.count) }
        let cStarts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        if case .failed(.at)? = after.state {
        } else {
            Issue.record("C backs off after its 500 (visit-first), not re-queued at once: \(after), starts \(cStarts)")
        }
        #expect(cStarts == 1, "no second attempt before the backoff ends: \(cStarts)")
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A is served from its new content: \(aResult)")
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B is served by the retry: \(bResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: Places of a job re-created meanwhile

    /// A place that waited for the follow belongs to the job that asked for it, not to a later job of the same transfer:
    /// during the owed follow a prefetch request for zz-k (v3 maps it to X, the new content of zz-a) creates job X, whose
    /// place waits; the request is withdrawn, so X is removed. The follow then visits zz-a's holder C and creates X again
    /// for A's interest (queued at once: a visit's own place), then zz-z's holder D, creating Z. Visited first, X is
    /// created before Z, keeps its place and starts first. With the dead job's place replayed onto the new X, X was queued
    /// again behind Z (PROBE-C9-STALE-PLACE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a queue place that waited for the follow is not given to a later job of the same transfer (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesNoPlaceOfARemovedJobToItsSuccessor(_ visit: LaneDropVisit) async throws {
        try await Self.stalePlace(visit, withK: true)
    }

    /// The control of `barrierGivesNoPlaceOfARemovedJobToItsSuccessor`: the same scenario without zz-k's request starts X
    /// first in both orders (PROBE-C9-STALE-PLACE-CONTROL).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: without a removed job's waiting place, the follow's new contents start in the follow's order (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierStartsNewContentsInTheFollowsOrder(_ visit: LaneDropVisit) async throws {
        try await Self.stalePlace(visit, withK: false)
    }

    /// The scenario of the two stale-place tests.
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
            let mid = await engine.readForTests { e in (owed: e.followOwed, violations: e.invariantViolations()) }
            #expect(mid.owed && mid.violations.isEmpty, "setup: X was removed while the follow still owes C's visit: \(mid)")
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
        #expect(xIndex != nil && zIndex != nil && xIndex! < zIndex!, "X, created by the follow before Z, starts first (visit-first): x=\(String(describing: xIndex)) z=\(String(describing: zIndex))")
        #expect((try? aResult.get())?.byteSize == Int64(xBytes.count), "A is served from X: \(aResult)")
        #expect((try? zResult.get())?.byteSize == Int64(zBytes.count), "Z is served: \(zResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: Offline and throttle exits (R-SYN-11, ARCHITECTURE §7.6)

    /// An offline exit's fail-fast answers only the interests the job holds once the follow moved its ids: C (1 MB) is
    /// the content of zz-a and zz-b, one user waiter each, and of a prefetch member of zz-b; v3 moves zz-a to N (16 bytes)
    /// while the follow owes C's visit. C's attempt fails offline with no network edge during it, so it waits for the next
    /// edge (`failed(.whenOnline)`) and answers its waiters `.offline`. Visited first, A's interest is on N, which serves
    /// it; only B gets the offline answer. Decided before the visit, the fail-fast answered A too (PROBE-C9-OFFLINE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an attempt that fails offline during an owed follow answers only the interests the follow leaves it (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAnOfflineExitOnTheFollowedState(_ visit: LaneDropVisit) async throws {
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
        // C's attempt starts after the watcher's first reading (a prefetch member waits for one), so its offline failure
        // waits for the next edge (`failed(.whenOnline)`), not retried at once.
        let group = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 3 }
        let serial = await engine.readForTests { e in e.state.jobs[a.transferID]?.active?.edgeSerial == e.state.networkEdgeSerial }
        try #require(serial, "setup: no network edge since C's attempt started")
        let nBytes = EngineFixture.bytes(994_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(840_000) + [aMoved, b], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state) }
            #expect(before.owed && before.c == .downloading, "setup: C runs and its visit is owed: \(before)")
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A, moved to N, is served from N, not answered with C's offline failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.offline), "B gets C's offline failure: \(bResult)")
        let c = await engine.readForTests { e in e.state.jobs[a.transferID]?.state }
        #expect(c == .failed(.whenOnline), "C, still wanted by the prefetch member, waits for the next edge: \(String(describing: c))")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A 429's park answers only the interests the job holds once the follow moved its ids: C (1 MB) is the content of
    /// zz-a and zz-b, one user waiter each; v3 moves zz-a to N (16 bytes, held once started) while the follow owes C's
    /// visit. C's attempt gets a 429 with Retry-After 60 s (beyond the interactive 2 s wait). Visited first, A's interest
    /// is on N, and N serves it once the throttle ends; the park's fail-fast answers B only. Parked before the visit, the
    /// fail-fast answered A too (PROBE-C9-THROTTLE).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a 429 during an owed follow answers only the interests the follow leaves its job (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAThrottleParkOnTheFollowedState(_ visit: LaneDropVisit) async throws {
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
        await engine.readForTests { $0.releaseFollowFollowUps() }
        // N starts once the throttle ends (the clock is driven), unless A was answered before the visit moved it.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.jobs[aMoved.transferID]?.state == .downloading || !e.state.waiters.values.contains { $0.asset == a.identifier }
            }
        }
        await s.harness.source.release(aMoved.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A, moved to N, is served from N, not answered with C's throttle (visit-first): \(aResult)")
        if case .failure(.serverUnavailable(let retryAfter?)) = bResult {
            #expect(retryAfter > 2, "B's answer carries the throttle's wait: \(bResult)")
        } else {
            Issue.record("B gets the throttle's fail-fast answer: \(bResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A 429 answers no interest the owed visit moves onto content already present: Y (16 bytes, zz-y) is present in the
    /// store; C (1 MB) downloads for A (zz-a, user) and B (zz-b, user). v3 moves zz-a onto Y's content and keeps zz-b on
    /// C's. C's attempt then gets a 429 with Retry-After 600 s. Visited first, A was answered from Y before the 429. Behind
    /// the barrier the 429's fail-fast answered A `serverUnavailable` before the owed visit moved it to the present
    /// content (PROBE-C9R-THROTTLE-PRESENT; no admission is involved, so the barrier's admission wait plays no part).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a 429 during an owed follow does not answer an interest the follow moves onto present content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierLetsTheFollowAnswerAThrottledHoldersMovedInterest(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 993_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xB4, count: 1_000_000)
        let yBytes = EngineFixture.bytes(993_004, count: 16)
        let a = EngineHarness.onDemand("zz-a", xBytes)
        let b = EngineHarness.onDemand("zz-b", xBytes)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(733_000) + [a, b, y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        await s.harness.source.script(y.transferID, [.stage(yBytes)])
        let yResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await engine.awaitAsset(y.identifier, lane: .userInitiated) }
        try #require((try? yResult.get())?.byteSize == 16, "setup: Y is present: \(yResult)")
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(600))), .stage(xBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { ($0.state.jobs[a.transferID]?.interests.count ?? 0) == 2 }
        let aMoved = EngineHarness.onDemand("zz-a", yBytes)
        try #require(aMoved.transferID == y.transferID, "setup: zz-a's new content is Y's")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(833_000) + [aMoved, b, y], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, bound: e.isBound(aMoved.identifier, to: y.transferID)) }
            #expect(before.owed && before.c == .downloading && before.bound, "setup: C runs, its visit is owed and Y is present: \(before)")
        } else {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A, moved onto Y's present content by the owed visit, is answered from it (visit-first): \(aResult)")
        if case .failure(.serverUnavailable) = bResult {
        } else {
            Issue.record("B, still held by C, gets the throttle's answer: \(bResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }
}
