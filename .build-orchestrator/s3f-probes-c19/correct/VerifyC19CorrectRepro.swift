import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 19, correctness lens): the cycle-18 PROBE-C18C-PENDING-LANE and -404, unchanged, re-run against cycle 19. Never committed.
///
/// Part 1 re-runs the cycle-17 blocking scenarios (RR-14 in both verifiers' shapes, the Retry-After date) as this
/// verifier's own copies. Part 2 hunts cycle 18's mechanism: the owed moves (`inboundMoves`) read by `followedLane`, and
/// the publication that waits for them (`awaitInboundMoves`) across a later apply. Each runs in both orders and expects
/// the visit-first outcome.
@Suite("VerifyC19CorrectRepro", .serialized)
struct VerifyC19CorrectRepro {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias T = EngineFollowBarrierTests

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

}
