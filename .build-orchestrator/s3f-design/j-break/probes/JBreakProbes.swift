import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Judge (break lens) probes for the s3f sweep/follow designs D1 "defer", D2 "budget", D3 "root". Scratch; never committed.
///
/// Each probe runs in both orders (`LaneDropVisit`): `.followVisitedFirst` lets the held follow end before the event under
/// test; `.sweepFollowsFirst` delivers the event while the follow still owes the visit that changes what the event's
/// decision reads. The reference is the visit-first answer.
///
/// - PROBE-J-FAIL-REROUTE: a transient failure of a moved id's holder C arrives while the follow owes the visit that
///   abandons another download D. `countFailedAttempt` brings C's visit forward (`followBeforeActing`), out of the follow's
///   order: C's waiter is re-routed onto P (parked `insufficientSpace`) and re-checked beside D's doomed bytes.
/// - PROBE-J-FAIL-TICKET: the same out-of-order visit creates the new content N2 of the failing holder before N1, whose
///   holder the follow visits first, so N2 takes the room visit-first gives N1 (FOLLOW-ORDER through a failure).
/// - PROBE-J-ENOSPC-DROPPED: an ENOSPC of a job whose only id the apply dropped (`holdsMovedID` does not count dropped
///   ids, so `followBeforeActing` does nothing): its verdict parks it and fail-fasts the waiter with insufficientSpace
///   where visit-first answers `.notFound`.
/// - PROBE-J-SHUTDOWN-DEFERRED: a user request, a join to a job parked `insufficientSpace` and a free-space read made
///   while the follow is owed, then shutdown: every waiter is answered `.shutDown` and shutdown returns.
@Suite("JBreakProbes", .serialized)
struct JBreakProbes {
    // MARK: FAIL-REROUTE

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-J-FAIL-REROUTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func failReroute(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await DesignD3Probes.setup(seed: 961_002)
        let engine = s.engine
        let dBytes = Data(repeating: 0x91, count: 4_000_000)
        let cBytes = Data(repeating: 0x92, count: 2_000_000)
        let pBytes = Data(repeating: 0x93, count: 3_500_000)
        // zz-a's job D (4 MB) is abandoned by its visit; zz-b's job C (2 MB) moves onto P's content.
        let a = EngineHarness.onDemand("zz-a", dBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + DesignD3Probes.fillers(710_000) + [a, b, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 7 MB of room: D (4 MB) and C (2 MB) run; P (3.5 MB) is parked `insufficientSpace` beside them (1 MB).
        _ = try await EngineRegressionCycle6Tests.leaveRoom(7_000_000, harness: s.harness, fileSystem: s.fileSystem)
        #expect(try await s.harness.store.freeSpace().pendingReclaim == 0, "setup: nothing waits for a reclaim")
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(dBytes)])
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state == .downloading }
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.insufficientSpace) }
        let aNewBytes = EngineFixture.bytes(961_004, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", aNewBytes)
        let bMoved = EngineHarness.onDemand("zz-b", pBytes)
        try #require(bMoved.transferID == p.transferID, "setup: B's new content is P's")
        await s.harness.source.script(aMoved.transferID, [.stage(aNewBytes)])
        // v3: zz-a (D) before zz-b (C) in the replaced copy's order, so the follow abandons D before it re-routes B onto P.
        let sync = await DesignD3Probes.apply([s.q] + DesignD3Probes.fillers(810_000) + [aMoved, bMoved, p], s, visit: visit)
        let before = await engine.readForTests { e in
            (owed: e.followOwed, d: e.state.jobs[a.transferID]?.state, c: e.state.jobs[b.transferID]?.state, p: e.state.jobs[p.transferID]?.state)
        }
        print("PROBE-J-FAIL-REROUTE \(visit) before: \(before)")
        if visit == .sweepFollowsFirst {
            #expect(before.owed && before.d == .downloading && before.c == .downloading, "setup: D and C still run and their visits are owed: \(before)")
            // C's attempt fails (transient): `countFailedAttempt` brings C's visit forward.
            await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        }
        let decided = await engine.readForTests { e in
            (owed: e.followOwed, d: e.state.jobs[a.transferID]?.state, c: e.state.jobs[b.transferID]?.state, p: e.state.jobs[p.transferID]?.state, violations: e.invariantViolations())
        }
        print("PROBE-J-FAIL-REROUTE \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-J-FAIL-REROUTE \(visit) B: \(bResult) | A: \(aResult)")
        #expect((try? bResult.get())?.byteSize == Int64(pBytes.count), "B's user waiter, moved onto P, is answered from P's 3.5 MB (visit-first): \(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        await engine.releaseGroup(group)
        await DesignD3Probes.finish(s, sync: sync)
    }

    // MARK: FAIL-TICKET

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-J-FAIL-TICKET", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func failTicket(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await DesignD3Probes.setup(seed: 962_002)
        let engine = s.engine
        let c1Bytes = Data(repeating: 0xA1, count: 5_000_000)
        let c2Bytes = Data(repeating: 0xA2, count: 5_000_000)
        let a1 = EngineHarness.onDemand("zz-a1", c1Bytes)
        let a2 = EngineHarness.onDemand("zz-a2", c2Bytes)
        await s.harness.serveManifest([s.q] + DesignD3Probes.fillers(720_000) + [a1, a2], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 11 MB of room: C1 and C2 (5 MB each) run. After both leave, N1 or N2 (6 MB each) fits, not both.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(11_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(a1.transferID, [.hold, .stage(c1Bytes)])
        await s.harness.source.script(a2.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(c2Bytes)])
        let a1Waiter = Task { await engine.awaitAsset(a1.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a1.transferID]?.state == .downloading }
        let a2Waiter = Task { await engine.awaitAsset(a2.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a2.transferID]?.state == .downloading }
        let n1Bytes = Data(repeating: 0xA3, count: 6_000_000)
        let n2Bytes = Data(repeating: 0xA4, count: 6_000_000)
        let n1 = EngineHarness.onDemand("zz-a1", n1Bytes)
        let n2 = EngineHarness.onDemand("zz-a2", n2Bytes)
        await s.harness.source.script(n1.transferID, [.stage(n1Bytes)])
        await s.harness.source.script(n2.transferID, [.stage(n2Bytes)])
        // v3 moves both: the follow visits C1 (zz-a1) before C2 (zz-a2), so visit-first N1 is created and served first.
        let sync = await DesignD3Probes.apply([s.q] + DesignD3Probes.fillers(820_000) + [n1, n2], s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in (e.followOwed, e.state.jobs[a2.transferID]?.state) }
            #expect(owed.0 && owed.1 == .downloading, "setup: C2 runs and its visit is owed: \(owed)")
            // C2's attempt fails: its visit is brought forward, before C1's.
            await s.harness.source.release(a2.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[a2.transferID]?.state != .downloading }
        }
        let decided = await engine.readForTests { e in
            (owed: e.followOwed, n1: e.state.jobs[n1.transferID].map { ($0.state, $0.ticket) }, n2: e.state.jobs[n2.transferID].map { ($0.state, $0.ticket) })
        }
        print("PROBE-J-FAIL-TICKET \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let a1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: a1Waiter) }
        let a2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: a2Waiter) }
        print("PROBE-J-FAIL-TICKET \(visit) A1: \(a1Result) | A2: \(a2Result)")
        #expect((try? a1Result.get())?.byteSize == Int64(n1Bytes.count), "A1 is served from N1, created first by the follow (visit-first): \(a1Result)")
        if case .failure(.insufficientSpace) = a2Result {
        } else {
            Issue.record("A2 gets insufficientSpace: N2 does not fit beside N1 (visit-first): \(a2Result)")
        }
        await DesignD3Probes.finish(s, sync: sync)
    }

    // MARK: ENOSPC-DROPPED

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-J-ENOSPC-DROPPED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func enospcDropped(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await DesignD3Probes.setup(seed: 963_002)
        let engine = s.engine
        let eBytes = Data(repeating: 0xB1, count: 1_500_000)
        let e = EngineHarness.onDemand("zz-e", eBytes)
        await s.harness.serveManifest([s.q] + DesignD3Probes.fillers(730_000) + [e], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(6_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(e.transferID, [.hold, .fail(.insufficientSpace(requiredBytes: Int64(eBytes.count))), .stage(eBytes)])
        let uWaiter = Task { await engine.awaitAsset(e.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[e.transferID]?.state == .downloading }
        // v3 drops zz-e: visit-first, the follow supersedes E (abandons it) and U gets `.notFound`.
        let sync = await DesignD3Probes.apply([s.q] + DesignD3Probes.fillers(830_000), s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e2 in (e2.followOwed, e2.state.jobs[e.transferID]?.state) }
            #expect(owed.0 && owed.1 == .downloading, "setup: E runs and its visit is owed: \(owed)")
            // The volume shrinks to 1 MB above the reserve, then E fails ENOSPC: its verdict parks it for lack of space.
            try await EngineSyncTests.leaveRoom(1_000_000, harness: s.harness, fileSystem: s.fileSystem)
            await s.harness.source.release(e.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[e.transferID]?.state != .downloading }
        }
        let decided = await engine.readForTests { e2 in (owed: e2.followOwed, e: e2.state.jobs[e.transferID]?.state, error: e2.state.jobs[e.transferID]?.lastError) }
        print("PROBE-J-ENOSPC-DROPPED \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        print("PROBE-J-ENOSPC-DROPPED \(visit) U: \(uResult)")
        #expect(uResult == .failure(.notFound), "U's dropped id is answered notFound (visit-first), not a shortage: \(uResult)")
        await DesignD3Probes.finish(s, sync: sync)
    }

    // MARK: SHUTDOWN-DEFERRED

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-J-SHUTDOWN-DEFERRED", .timeLimit(.minutes(3)))
    func shutdownDeferred() async throws {
        let (s, _) = try await DesignD3Probes.setup(seed: 964_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0xC1, count: 5_000_000)
        let pBytes = Data(repeating: 0xC2, count: 3_000_000)
        let kBytes = Data(repeating: 0xC3, count: 1_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await s.harness.serveManifest([s.q] + DesignD3Probes.fillers(740_000) + [a, k, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(7_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.insufficientSpace) }
        let newBytes = EngineFixture.bytes(964_004, count: 16)
        let moved = EngineHarness.onDemand("zz-a", newBytes)
        await s.harness.source.script(moved.transferID, [.stage(newBytes)])
        let sync = await DesignD3Probes.apply([s.q] + DesignD3Probes.fillers(840_000) + [moved, k, p], s, visit: .sweepFollowsFirst)
        let created = await engine.readForTests { $0.state.jobsCreated }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobsCreated > created }
        let joined = await engine.readForTests { $0.state.jobs[p.transferID]?.interests.count ?? 0 }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await engine.awaitCondition { e in (e.state.jobs[p.transferID]?.interests.count ?? 0) > joined || e.state.jobs[p.transferID]?.state != .blocked(.insufficientSpace) }
        let between = await engine.readForTests { e in
            (owed: e.followOwed, k: e.state.jobs[k.transferID]?.state, p: e.state.jobs[p.transferID]?.state, waiters: e.state.waiters.count, violations: e.invariantViolations())
        }
        print("PROBE-J-SHUTDOWN-DEFERRED between: \(between)")
        #expect(between.owed, "setup: the follow is still owed when shutdown starts: \(between)")
        #expect(between.violations.isEmpty, "the committed invariants hold while the request and the join wait for the follow: \(between.violations)")
        await engine.shutdown()
        let kResult = await EngineHarness.value(of: kWaiter)
        let pResult = await EngineHarness.value(of: pWaiter)
        let aResult = await EngineHarness.value(of: aWaiter)
        let outcome = await EngineHarness.value(of: sync)
        let after = await engine.readForTests { e in (waiters: e.state.waiters.count, events: e.state.jobs.count) }
        print("PROBE-J-SHUTDOWN-DEFERRED K: \(kResult) | P: \(pResult) | A: \(aResult) | sync: \(outcome) | after: \(after)")
        #expect(kResult == .failure(.shutDown) || (try? kResult.get())?.byteSize == Int64(kBytes.count), "K: \(kResult)")
        #expect(pResult == .failure(.shutDown) || pResult == .failure(.insufficientSpace(required: Int64(pBytes.count), available: 2_000_000)), "P: \(pResult)")
        #expect(aResult == .failure(.shutDown), "A: \(aResult)")
        #expect(after.waiters == 0, "no waiter left: \(after)")
        _ = group
    }
    // MARK: UNRELATED-FREE (boundary: a ledger change no design defers)

    /// X (2 MB, not moved) fails transiently while the follow owes the visit that re-routes A onto P (5.5 MB, parked
    /// `insufficientSpace`). Visit-first, A's re-check reads X's bytes in flight (5 MB < 5.5 MB) and A is answered
    /// insufficientSpace; failure-first, X's bytes already left and P fits. No design defers the release of a failed
    /// transfer's bytes, so every design gives the two orders different answers: this marks the criterion's boundary.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-J-UNRELATED-FREE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func unrelatedFree(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await DesignD3Probes.setup(seed: 965_002)
        let engine = s.engine
        let xBytes = Data(repeating: 0xD1, count: 2_000_000)
        let cBytes = Data(repeating: 0xD2, count: 2_000_000)
        let pBytes = Data(repeating: 0xD3, count: 5_500_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + DesignD3Probes.fillers(750_000) + [a, p, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // 7 MB of room: C (2 MB) and X (2 MB) run; P (5.5 MB) is parked `insufficientSpace` beside them (3 MB).
        _ = try await EngineRegressionCycle6Tests.leaveRoom(7_000_000, harness: s.harness, fileSystem: s.fileSystem)
        await engine.refreshFreeSpace()
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(x.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .hold, .stage(xBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .downloading }
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.insufficientSpace) }
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        let sync = await DesignD3Probes.apply([s.q] + DesignD3Probes.fillers(850_000) + [moved, p, x], s, visit: visit)
        // X's attempt fails: its 2 MB leave the ledger (visit-first: after the follow re-checked A; else before).
        await s.harness.source.release(x.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.state != .downloading }
        let decided = await engine.readForTests { e in (owed: e.followOwed, p: e.state.jobs[p.transferID]?.state, x: e.state.jobs[x.transferID]?.state) }
        print("PROBE-J-UNRELATED-FREE \(visit) decided: \(decided)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-J-UNRELATED-FREE \(visit) A: \(aResult)")
        if case .failure(.insufficientSpace) = aResult {
        } else {
            Issue.record("A gets the visit-first answer (insufficientSpace, X still in flight at its re-check): \(aResult)")
        }
        xWaiter.cancel()
        await engine.releaseGroup(group)
        await DesignD3Probes.finish(s, sync: sync)
    }
    // MARK: HELD-RETICKET (D1: the pump's hold re-tickets a job that holds no moved id)

    /// K (3 MB, user) waits queued for the one slot from before the apply; A's job C behind it. v3 moves A to N (3 MB).
    /// The follow's second turn visits C and creates N (a later ticket than K), and its pass is still owed. Event-first, the
    /// slot frees while the follow is owed: D1's pump holds K at its queue's head (`waitsForFollow`, `requeueAtHead`),
    /// which gives K a fresh ticket, later than N's; both then park `awaitingSpace`, and the reclaim's sweep, which orders
    /// by ticket, serves N before K. Visit-first, the slot frees after the follow: K keeps its ticket and is served first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-J-HELD-RETICKET", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func heldReticket(_ visit: LaneDropVisit) async throws {
        let xBytes = Data(repeating: 0xE1, count: 4_000_000)
        let (s, xEntry) = try await DesignD3Probes.setup(seed: 966_102, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0), pruned: xBytes)
        _ = try #require(xEntry)
        let engine = s.engine
        let slBytes = EngineFixture.bytes(966_110, count: 16)
        let cBytes = Data(repeating: 0xE2, count: 5_000_000)
        let kBytes = Data(repeating: 0xE3, count: 3_000_000)
        let nBytes = Data(repeating: 0xE4, count: 3_000_000)
        let sl = EngineHarness.onDemand("zz-s", slBytes)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        // Changed entries after the zz- ids: the follow's second turn finds C, then formats up to its bound and stops.
        let tail = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "zzz%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        // v2 prunes x: its 4 MB wait for the grace.
        await s.harness.serveManifest([s.q] + DesignD3Probes.fillers(701_000) + [sl, a, k] + tail(711_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: s.harness, fileSystem: s.fileSystem)
        #expect(try await s.harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await s.harness.source.script(sl.transferID, [.hold, .stage(slBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        await s.harness.source.script(a.transferID, [.stage(cBytes)])
        let slWaiter = Task { await engine.awaitAsset(sl.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[sl.transferID]?.state == .downloading }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .queued }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        let n = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(n.transferID, [.stage(nBytes)])
        let sync = await DesignD3Probes.apply([s.q] + DesignD3Probes.fillers(801_000) + [sl, n, k] + tail(811_000), s, visit: .sweepFollowsFirst)
        // The follow's second turn: C's visit creates N; the pass is still owed after it.
        await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.holdFollowFollowUps()
        }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        let mid = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, n: e.state.jobs[n.transferID].map { ($0.state, $0.ticket) }, k: e.state.jobs[k.transferID].map { ($0.state, $0.ticket) }) }
        print("PROBE-J-HELD-RETICKET \(visit) mid: \(mid)")
        #expect(mid.owed && mid.c == nil && mid.n != nil, "setup: N exists and the follow is still owed: \(mid)")
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        // The slot frees (visit-first: after the follow; else while it is owed).
        await s.harness.source.release(sl.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineHarness.value(of: slWaiter)
        await engine.awaitCondition { $0.state.jobs[sl.transferID] == nil && $0.state.draining.isEmpty }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { e in
            !e.followOwed && e.state.jobs[n.transferID]?.state == .blocked(.awaitingSpace) && e.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace)
        }
        let tickets = await engine.readForTests { e in (n: e.state.jobs[n.transferID]?.ticket, k: e.state.jobs[k.transferID]?.ticket) }
        print("PROBE-J-HELD-RETICKET \(visit) tickets: \(tickets)")
        // 1 MB plus x's 4 MB after the reclaim: one of K and N.
        try await EngineSyncTests.leaveRoom(1_000_000, harness: s.harness, fileSystem: s.fileSystem)
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-J-HELD-RETICKET \(visit) K: \(kResult) | A: \(aResult)")
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K, queued before N was created, is served first (visit-first): \(kResult)")
        if case .failure(.insufficientSpace) = aResult {
        } else {
            Issue.record("A (N's waiter) gets the shortage (visit-first): \(aResult)")
        }
        await DesignD3Probes.finish(s, sync: sync)
    }
}
