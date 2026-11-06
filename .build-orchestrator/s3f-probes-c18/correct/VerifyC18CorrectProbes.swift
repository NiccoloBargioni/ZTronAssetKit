import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 18, correctness lens). Never committed.
///
/// Part 1 re-runs the cycle-17 blocking scenarios (RR-14 in both verifiers' shapes, the Retry-After date) as this
/// verifier's own copies. Part 2 hunts cycle 18's mechanism: the owed moves (`inboundMoves`) read by `followedLane`, and
/// the publication that waits for them (`awaitInboundMoves`) across a later apply. Each runs in both orders and expects
/// the visit-first outcome.
@Suite("VerifyC18Correct", .serialized)
struct VerifyC18Correct {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias T = EngineFollowBarrierTests

    // MARK: Part 1: the cycle-17 blocking scenarios

    /// PROBE-C17C-RR14-PUBLICATION-HOP (seed 1_717_302, 100 kB publisher) and PROBE-C17R-RR14-PUBLICATION-HOP's shape
    /// (seed 1_717_002, 16 B publisher). P (zz-p; user waiter Q) publishes bytes that fail their checksum, held at its
    /// first store unit; H (zz-x; user waiter W) downloads. v3 moves zz-x onto P's content, v4 on to Z (48 B), both
    /// while P publishes. Visit-first: W gets P's integrity failure.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C18-REPRO-RR14-PUBLICATION-HOP", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [false, true])
    func rr14PublicationHop(_ visit: LaneDropVisit, _ small: Bool) async throws {
        let seed: UInt64 = small ? 1_717_002 : 1_717_302
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let pBytes = EngineFixture.bytes(seed + 3, count: small ? 16 : 100_000)
        let wrongBytes = EngineFixture.bytes(seed + 4, count: small ? 16 : 100_000)
        let hBytes = EngineFixture.bytes(seed + 5, count: small ? 100_000 : 50_000)
        let zBytes = EngineFixture.bytes(seed + 7, count: 48)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xToP = EngineHarness.onDemand("zz-x", pBytes)
        let xToZ = EngineHarness.onDemand("zz-x", zBytes)
        try #require(xToP.transferID == p.transferID && x.transferID != p.transferID && xToZ.transferID != p.transferID && xToZ.transferID != x.transferID && wrongBytes != pBytes, "setup: three contents, v3's zz-x on P's")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [p, x] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(p.transferID, [.hold, .stage(wrongBytes)])
        await s.harness.source.script(x.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(xToZ.transferID, [.stage(zBytes)])
        let qWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[p.transferID]?.state == .downloading }
        }
        let wWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .downloading }
        }
        let releaser = try await T.holdPublication(of: p.transferID, s, bulk: bulk)
        try await T.applyHeld([s.q] + fillers + [p, xToP] + later, tag: "v3-c18rr14-\(seed)", s, visit: visit)
        try await T.applyHeld([s.q] + fillers + [p, xToZ] + later, tag: "v4-c18rr14-\(seed)", s, visit: visit)
        let atV4 = await engine.readForTests { e in
            (owed: e.followOwed, moves: e.state.inboundMoves.count - e.state.inboundNext, p: e.state.jobs[p.transferID].map { "\($0.state) \($0.assets.sorted()) i\($0.interests.count)" } ?? "nil")
        }
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
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        let qResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: qWaiter) }
        let zStarts = await s.harness.source.starts.filter { $0.id == xToZ.transferID }.count
        print("C18-REPRO-RR14-PUBLICATION-HOP seed \(seed) \(visit) after v4 \(atV4); w=\(wResult) q=\(qResult) zStarts=\(zStarts)")
        #expect(qResult == .failure(.integrityFailure), "Q gets P's integrity failure: \(qResult)")
        #expect(wResult == .failure(.integrityFailure), "C18-REPRO-RR14 (seed \(seed)): v3's visit joined W to P's publication and v4's visit passed it (visit-first): \(wResult); zStarts \(zStarts)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C17C-RETRY-AFTER-DATE (seed 1_717_102), unchanged: a 503 whose Retry-After date is 31 s ahead at its arrival
    /// (interactive cap 30 s), the clock moved 5 s while the follow is owed. Visit-first: B `serverUnavailable`, C once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("C18-REPRO-RETRY-AFTER-DATE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func retryAfterDate(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_717_102
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: T.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .stage(cBytes)])
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        try await T.applyHeld([s.q] + fillers + [b] + later, tag: "v3-c18date-\(seed)", s, visit: visit)
        let date = s.time.now().addingTimeInterval(31)
        await s.harness.source.release(b.transferID, with: .failed(.transient(.serverError(httpStatus: 503), retryAfter: .date(date))))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[b.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        }
        s.time.advance(by: 5)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let cStarts = await s.harness.source.starts.filter { $0.id == b.transferID }.count
        print("C18-REPRO-RETRY-AFTER-DATE \(visit) b=\(bResult) cStarts=\(cStarts)")
        if case .failure(.serverUnavailable) = bResult {
        } else {
            Issue.record("C18-REPRO-RETRY-AFTER-DATE: the Retry-After (31 s at its arrival) is above the cap: B serverUnavailable (visit-first): \(bResult); cStarts \(cStarts)")
        }
        #expect(cStarts == 1, "C starts once (visit-first): \(cStarts)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    // MARK: Part 2: cycle 18's owed moves

    /// PROBE-C18C-PENDING-LANE. `followedLane` counts an id an owed move carries only on the move's target
    /// (`inboundPendingIDs`, cycle 18), "whatever a later copy maps it to". That holds for a publishing target (the later
    /// apply's visit passes it), not for a target whose exit verdict waits: the drain moves the ids a later apply moved
    /// from the job that verdict leaves (`followAfterVerdict`), as a visit-first engine's visit at that apply moved them.
    ///
    /// O (100 kB; zz-a, user waiter A) and J (16 B; zz-p, prefetch waiter P) download; 72 prefetch holders (zz-g…, own
    /// 16 B contents) and then H (50 kB; zz-b, user waiter B) are created. K (zz-k) publishes, held at its first store
    /// unit, so an apply's walk finds a publication in flight. v3 maps zz-b and every zz-g to O's content. O's attempt
    /// times out (first attempt, below every cap: a retry that keeps every interest). v4 maps zz-b on to J's content.
    /// Then J gets a 429 with `Retry-After` 60 s (above the user lane's 30 s cap, below the prefetch lane's).
    ///
    /// Visit-first: v3's visit moved B onto O; O's timeout backed off and kept B; v4's visit moved B onto J; J's 429 is
    /// user work beyond the cap: J fails, P and B `serverUnavailable(60)`, the origin not throttled by it.
    /// Behind the barrier: O's attempt end makes the first 64 moves; the moves of 8 holders and of H stay owed through v4
    /// (whose turn K's walk takes, `applyWalked`), so at J's 429 B's id is pending onto O and `here` says not J's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C18C-PENDING-LANE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [true, false])
    func pendingLane(_ visit: LaneDropVisit, _ publication: Bool) async throws {
        try await self.pendingLaneCase(visit, publication, notFound: false)
    }

    /// PROBE-C18C-PENDING-404: as PROBE-C18C-PENDING-LANE, with J's attempt ending in a 404. Visit-first, v4's visit
    /// moved B onto J before J's attempt ended, so J's 404 answers P and B `notFound`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C18C-PENDING-404", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [true, false])
    func pendingNotFound(_ visit: LaneDropVisit, _ publication: Bool) async throws {
        try await self.pendingLaneCase(visit, publication, notFound: true)
    }

    @available(macOS 15.0, iOS 18.0, *)
    func pendingLaneCase(_ visit: LaneDropVisit, _ publication: Bool, notFound: Bool) async throws {
        let label = notFound ? "PROBE-C18C-PENDING-404" : "PROBE-C18C-PENDING-LANE"
        let seed: UInt64 = 1_818_902
        let tuning = SyncTuning(maxConcurrentTransfers: 12, reservedInteractiveSlots: 4, interactiveRetry: T.shortInteractiveRetry)
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 4, count: 50_000)
        let jBytes = EngineFixture.bytes(seed + 5, count: 16)
        let kBytes = EngineFixture.bytes(seed + 6, count: 32)
        let a = EngineHarness.onDemand("zz-a", oBytes)
        let b = EngineHarness.onDemand("zz-b", hBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        let p = EngineHarness.onDemand("zz-p", jBytes)
        let bToO = EngineHarness.onDemand("zz-b", oBytes)
        let bToJ = EngineHarness.onDemand("zz-b", jBytes)
        try #require(bToO.transferID == a.transferID && bToJ.transferID == p.transferID && b.transferID != a.transferID && b.transferID != p.transferID, "setup: zz-b on H, then O, then J")
        // With K's publication held, v4's walk takes its turn (`applyWalked`), so 72 holders ahead leave H's move owed;
        // without it, 330 ahead leave 11 owed after O's end (64) and v4's own turn (256).
        let aheadCount = publication ? T.publicationHopAhead : 330
        let aheadNames = (0..<aheadCount).map { String(format: "zz-g%04d", $0) }
        let aheadOwn = aheadNames.enumerated().map { EngineHarness.onDemand($0.element, EngineFixture.bytes(seed + 10_000 + UInt64($0.offset), count: 16)) }
        let aheadOnO = aheadNames.map { EngineHarness.onDemand($0, oBytes) }
        let fillers = FollowBarrier.fillers(seed + 200)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, k, p] + aheadOwn + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let timeout = TransferError.transient(.timedOut, retryAfter: nil)
        await s.harness.source.script(a.transferID, [.hold, .fail(timeout), .stage(oBytes)])
        let jFailure: TransferError = notFound ? .permanentMissing(httpStatus: 404) : .transient(.throttled, retryAfter: .seconds(60))
        await s.harness.source.script(p.transferID, [.hold, .fail(jFailure), .stage(jBytes)])
        await s.harness.source.script(k.transferID, [.hold, .stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        var kWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        var releaser: Task<Void, Never>?
        if publication {
            kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .downloading }
            }
            // K's publication begins, held at its first store unit (an apply's units run).
            releaser = try await T.holdPublication(of: k.transferID, s, bulk: bulk)
        }
        // The holders ahead are created before H, so their moves come first.
        var aheadWaiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for holder in aheadOwn {
            let id = holder.identifier
            aheadWaiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        let aheadTransfers = aheadOwn.map(\.transferID)
        await engine.awaitCondition { e in aheadTransfers.allSatisfy { e.state.jobs[$0]?.interests.isEmpty == false } }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.interests.isEmpty == false }
        let epochs = await engine.readForTests { e in (h: e.state.jobs[b.transferID]?.epoch ?? 0, aheadMax: aheadTransfers.compactMap { e.state.jobs[$0]?.epoch }.max() ?? 0) }
        try #require(epochs.h > epochs.aheadMax, "setup: H is created after the holders ahead: \(epochs)")
        // v3 maps zz-b and every zz-g to O's content.
        try await T.applyHeld([s.q] + fillers + [a, bToO, k, p] + aheadOnO + T.laterFillers(seed + 6_000), tag: "v3-pending-\(seed)", s, visit: visit)
        // O's first attempt times out: a retry below every cap.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            let owedH = await engine.readForTests { e in e.inboundOwed && e.state.inboundMoves[e.state.inboundNext...].contains { $0.holder == b.transferID } }
            try #require(owedH, "setup: H's move onto O is still owed after O's attempt end")
        } else {
            await engine.awaitCondition { e in
                guard let job = e.state.jobs[a.transferID] else {
                    return true
                }
                switch job.state {
                case .failed(.at), .blocked:
                    return true
                default:
                    return false
                }
            }
        }
        // v4 maps zz-b on to J's content.
        try await T.applyHeld([s.q] + fillers + [a, bToJ, k, p] + aheadOnO + T.laterFillers(seed + 9_000), tag: "v4-pending-\(seed)", s, visit: visit)
        let atV4 = await engine.readForTests { e -> String in
            let owedH = e.inboundOwed && e.state.inboundMoves[e.state.inboundNext...].contains { $0.holder == b.transferID }
            let lane = e.state.jobs[p.transferID].map { "\(e.followedLane($0))" } ?? "nil"
            return "owed \(e.followOwed) movesOwed \(e.state.inboundMoves.count - e.state.inboundNext) hMoveOwed \(owedH) J.followedLane \(lane) J.lane \(e.state.jobs[p.transferID].map { "\($0.lane)" } ?? "nil")"
        }
        let before = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        // J's 429 (Retry-After 60 s).
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let after = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if let releaser {
            releaser.cancel()
            await releaser.value
            await bulk.setHolding(false)
        }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        if let kWaiter {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        }
        let jStarts = await s.harness.source.starts.filter { $0.id == p.transferID }.count
        print("\(label) \(visit) publication \(publication) ahead \(aheadCount) at v4 \(atV4); throttle before \(String(describing: before)) after \(String(describing: after)); p=\(pResult) b=\(bResult) a=\(aResult) jStarts=\(jStarts)")
        if notFound {
            #expect(pResult == .failure(.notFound), "PROBE-C18C-PENDING-404: P is answered by J's 404 (visit-first): \(pResult); at v4 \(atV4); jStarts \(jStarts)")
            #expect(bResult == .failure(.notFound), "PROBE-C18C-PENDING-404: v4's visit moved B onto J before its 404, which answers it (visit-first): \(bResult); at v4 \(atV4); jStarts \(jStarts)")
        } else {
            if case .failure(.serverUnavailable) = pResult {
            } else {
                Issue.record("PROBE-C18C-PENDING-LANE: visit-first, v4's visit moved B onto J, so J's 429 is user work beyond the 30 s cap and P is answered serverUnavailable(60): \(pResult); at v4 \(atV4); jStarts \(jStarts)")
            }
            #expect(after == before, "PROBE-C18C-PENDING-LANE: visit-first, J's 429 is beyond the user lane's cap and throttles nothing: before \(String(describing: before)) after \(String(describing: after))")
            if case .failure(.serverUnavailable) = bResult {
            } else {
                Issue.record("PROBE-C18C-PENDING-LANE: B is answered serverUnavailable (visit-first): \(bResult)")
            }
        }
        #expect((try? aResult.get())?.byteSize == 100_000, "\(label): O's retry serves A (visit-first): \(aResult)")
        for waiter in aheadWaiters {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C18C-PUBLICATION-WAIT-APPLY. A publication that waits for owed moves (`awaitInboundMoves`, cycle 18) binds
    /// its ids only after them, so an apply that lands during the wait decides which ids the store binds. O (16 B; zz-o,
    /// user waiter U) downloads; 72 prefetch holders (zz-g…, own 16 B contents) wait. v3 maps every zz-g to O's content.
    /// O's bytes arrive. Then v4 maps zz-o to Z (48 B) and keeps every zz-g on O.
    ///
    /// Visit-first: v3's visits moved the holders onto O; O's publication began at its attempt's end with nothing owed,
    /// bound zz-o and the holders' ids and committed before v4: U is served O's 16 bytes.
    /// Behind the barrier: O's attempt end makes 64 moves and its publication waits for the other 8; v4 is applied
    /// meanwhile, so the binding the store checks after the wait meets v4's zz-o on Z.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C18C-PUBLICATION-WAIT-APPLY", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func publicationWaitApply(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_818_952
        let tuning = SyncTuning(maxConcurrentTransfers: 12, reservedInteractiveSlots: 4)
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 16)
        let zBytes = EngineFixture.bytes(seed + 7, count: 48)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let oToZ = EngineHarness.onDemand("zz-o", zBytes)
        try #require(o.transferID != oToZ.transferID, "setup: two contents")
        let aheadNames = (0..<T.publicationHopAhead).map { String(format: "zz-g%04d", $0) }
        let aheadOwn = aheadNames.enumerated().map { EngineHarness.onDemand($0.element, EngineFixture.bytes(seed + 10_000 + UInt64($0.offset), count: 16)) }
        let aheadOnO = aheadNames.map { EngineHarness.onDemand($0, oBytes) }
        let fillers = FollowBarrier.fillers(seed + 200)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [o] + aheadOwn + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(o.transferID, [.hold, .stage(oBytes)])
        await s.harness.source.script(oToZ.transferID, [.stage(zBytes)])
        let uWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        var aheadWaiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for holder in aheadOwn {
            let id = holder.identifier
            aheadWaiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        let aheadTransfers = aheadOwn.map(\.transferID)
        await engine.awaitCondition { e in aheadTransfers.allSatisfy { e.state.jobs[$0]?.interests.isEmpty == false } }
        // v3 maps every zz-g to O's content.
        try await T.applyHeld([s.q] + fillers + [o] + aheadOnO + T.laterFillers(seed + 6_000), tag: "v3-pubwait-\(seed)", s, visit: visit)
        // O's bytes arrive.
        await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
        var atBytes = "-"
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.inboundWaits[o.transferID] != nil || $0.state.jobs[o.transferID] == nil }
            atBytes = await engine.readForTests { e in "waits \(e.state.inboundWaits[o.transferID] != nil) movesOwed \(e.state.inboundMoves.count - e.state.inboundNext) O \(e.state.jobs[o.transferID].map { "\($0.state) ids \($0.assets.count)" } ?? "nil")" }
        } else {
            await engine.awaitCondition { $0.state.jobs[o.transferID] == nil }
        }
        // v4 maps zz-o to Z and keeps every zz-g on O.
        try await T.applyHeld([s.q] + fillers + [oToZ] + aheadOnO + T.laterFillers(seed + 9_000), tag: "v4-pubwait-\(seed)", s, visit: visit)
        let atV4 = await engine.readForTests { e in "waits \(e.state.inboundWaits[o.transferID] != nil) O \(e.state.jobs[o.transferID].map { "\($0.state) ids \($0.assets.count)" } ?? "nil")" }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        var aheadSizes: [Int] = []
        for waiter in aheadWaiters {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            aheadSizes.append(Int((try? result.get())?.byteSize ?? -1))
        }
        let zStarts = await s.harness.source.starts.filter { $0.id == oToZ.transferID }.count
        print("PROBE-C18C-PUBLICATION-WAIT-APPLY \(visit) at O's bytes \(atBytes); at v4 \(atV4); u=\(uResult) zStarts=\(zStarts) ahead sizes \(Set(aheadSizes))")
        #expect((try? uResult.get())?.byteSize == 16, "PROBE-C18C-PUBLICATION-WAIT-APPLY: visit-first, O's publication bound zz-o before v4, so U is served O's 16 bytes: \(uResult); at O's bytes \(atBytes); at v4 \(atV4); zStarts \(zStarts)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }

    /// PROBE-C18C-PUBLICATION-WAIT-APPLY-HELD (visit-first only): the same events, with O's publication held at its first
    /// store unit while v4 is applied, so a visit-first engine's apply also lands before the store binds zz-o. Prints U's
    /// answer: whether visit-first's own answer depends on when v4 lands relative to the bind.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C18C-PUBLICATION-WAIT-APPLY-HELD", .timeLimit(.minutes(3)))
    func publicationWaitApplyHeld() async throws {
        let visit = LaneDropVisit.followVisitedFirst
        let seed: UInt64 = 1_818_952
        let tuning = SyncTuning(maxConcurrentTransfers: 12, reservedInteractiveSlots: 4)
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 16)
        let zBytes = EngineFixture.bytes(seed + 7, count: 48)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let oToZ = EngineHarness.onDemand("zz-o", zBytes)
        let aheadNames = (0..<T.publicationHopAhead).map { String(format: "zz-g%04d", $0) }
        let aheadOwn = aheadNames.enumerated().map { EngineHarness.onDemand($0.element, EngineFixture.bytes(seed + 10_000 + UInt64($0.offset), count: 16)) }
        let aheadOnO = aheadNames.map { EngineHarness.onDemand($0, oBytes) }
        let fillers = FollowBarrier.fillers(seed + 200)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [o] + aheadOwn + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(o.transferID, [.hold, .stage(oBytes)])
        await s.harness.source.script(oToZ.transferID, [.stage(zBytes)])
        let uWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        var aheadWaiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for holder in aheadOwn {
            let id = holder.identifier
            aheadWaiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        let aheadTransfers = aheadOwn.map(\.transferID)
        await engine.awaitCondition { e in aheadTransfers.allSatisfy { e.state.jobs[$0]?.interests.isEmpty == false } }
        try await T.applyHeld([s.q] + fillers + [o] + aheadOnO + T.laterFillers(seed + 6_000), tag: "v3-pubheld-\(seed)", s, visit: visit)
        // O's bytes arrive; its publication is held at its first store unit.
        let releaser = try await T.holdPublication(of: o.transferID, s, bulk: bulk)
        try await T.applyHeld([s.q] + fillers + [oToZ] + aheadOnO + T.laterFillers(seed + 9_000), tag: "v4-pubheld-\(seed)", s, visit: visit)
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        var aheadSizes: [Int] = []
        for waiter in aheadWaiters {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            aheadSizes.append(Int((try? result.get())?.byteSize ?? -1))
        }
        let zStarts = await s.harness.source.starts.filter { $0.id == oToZ.transferID }.count
        print("PROBE-C18C-PUBLICATION-WAIT-APPLY-HELD \(visit) u=\(uResult) zStarts=\(zStarts) ahead sizes \(Set(aheadSizes))")
        #expect(uResult.map(\.byteSize) == .success(48) || uResult.map(\.byteSize) == .success(16), "PROBE-C18C-PUBLICATION-WAIT-APPLY-HELD: U is served: \(uResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
    }
}
