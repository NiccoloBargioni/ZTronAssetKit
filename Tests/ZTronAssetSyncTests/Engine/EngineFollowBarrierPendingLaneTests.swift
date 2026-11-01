import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The lane a 429 is decided on while an owed move (`EngineState.inboundMoves`) still carries a user interest onto a job
/// whose attempt has ended (Stage 3 close-out cycle 19; the cycle-18 correctness verifier's PROBE-C18C-PENDING-LANE): a
/// visit-first engine's visit had moved the interest onto that job before its attempt ended, and a later apply's visit
/// moved it on to the content the later copy maps it to, unless the job's verdict answered it first. Each case runs in
/// both orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// What leaves H's move owed when v4 is applied in `pendingLane`.
    enum PendingLaneShape: Sendable, CaseIterable {
        /// K's publication is held at its first store unit, so v4's apply walks for it and its follow's first turn waits
        /// for the follow-up the walk schedules (`EngineState.applyWalked`): `publicationHopAhead` holders ahead suffice.
        case publicationHeld
        /// No publication: O's attempt's end makes `inboundMovesNow` moves and v4's own follow turn `followsPerTurn`, so
        /// 330 holders ahead leave H's move owed after both.
        case owedTurn
    }

    /// How O's first attempt ends in `pendingLane`.
    enum PendingLaneEnding: Sendable {
        /// A timeout: a retry below every cap, which keeps every interest, so the drain moves B on to J after it.
        case timeout
        /// A 404, which answers every interest on O, B's included: nothing is left for the drain to move on to J.
        case notFound
    }

    /// The answers `pendingLane` reads: P's (J's prefetch waiter), B's (H's user waiter, whose id converges on O and
    /// then moves on to J), A's (O's user waiter), whether J's 429 throttled the origin, and J's starts.
    struct PendingLaneOutcome {
        /// P's answer.
        let p: Result<AssetLocation, AssetError>
        /// B's answer.
        let b: Result<AssetLocation, AssetError>
        /// A's answer.
        let a: Result<AssetLocation, AssetError>
        /// Whether the origin's throttle end moved at J's 429.
        let throttled: Bool
        /// The starts of J's transfer.
        let jStarts: Int
    }

    /// O (zz-a, 100 kB, user waiter A) and J (zz-p, 16 B, prefetch waiter P) download; holders ahead (zz-g…, 16 B each, a
    /// prefetch waiter each) and then H (zz-b, 50 kB, user waiter B), created last, wait. v3 maps zz-b and every holder's
    /// id to O's content; O's first attempt times out (a retry below every cap, which keeps every interest); v4 maps zz-b
    /// on to J's content; then J gets a 429 whose `Retry-After` (60 s) is above the user lane's cap (30 s) and below the
    /// prefetch lane's. Sweep-first, O's attempt's end owes H's move onto O, and it is still owed at J's 429.
    ///
    /// Visit-first: v3's visit moved B onto O, O's retry kept it, and v4's visit moved it on to J, so J's 429 is user work
    /// beyond its cap: J fails, P and B are answered `serverUnavailable`, the origin is not throttled, and O's retry
    /// serves A.
    ///
    /// With `ending` `.notFound`, O's 404 answered A, B and every holder ahead before v4 (visit-first), so J's 429 is
    /// prefetch work below its cap: it throttles the origin, and J's retry serves P.
    @available(macOS 15.0, iOS 18.0, *)
    func pendingLane(_ visit: LaneDropVisit, _ shape: PendingLaneShape, ending: PendingLaneEnding = .timeout) async throws -> PendingLaneOutcome {
        let seed: UInt64 = 1_919_002
        let tuning = SyncTuning(maxConcurrentTransfers: 12, reservedInteractiveSlots: 4, interactiveRetry: Self.shortInteractiveRetry)
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: tuning)
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
        try #require(bToO.transferID == a.transferID && bToJ.transferID == p.transferID && b.transferID != a.transferID && b.transferID != p.transferID, "setup: zz-b on H, then on O, then on J")
        let aheadCount = shape == .publicationHeld ? Self.publicationHopAhead : SyncEngine.inboundMovesNow + SyncEngine.followsPerTurn + 10
        let aheadNames = (0..<aheadCount).map { String(format: "zz-g%04d", $0) }
        let aheadOwn = aheadNames.enumerated().map { EngineHarness.onDemand($0.element, EngineFixture.bytes(seed + 10_000 + UInt64($0.offset), count: 16)) }
        let aheadOnO = aheadNames.map { EngineHarness.onDemand($0, oBytes) }
        let fillers = FollowBarrier.fillers(seed + 200)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, k, p] + aheadOwn + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        switch ending {
        case .timeout:
            await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.timedOut, retryAfter: nil)), .stage(oBytes)])
        case .notFound:
            await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        }
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(jBytes)])
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
        if shape == .publicationHeld {
            kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .downloading }
            }
            // K's publication begins, held at its first store unit, so every apply below walks for it.
            releaser = try await Self.holdPublication(of: k.transferID, s, bulk: bulk)
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
        let epochs = await engine.readForTests { e in (h: e.state.jobs[b.transferID]?.epoch ?? 0, ahead: aheadTransfers.compactMap { e.state.jobs[$0]?.epoch }.max() ?? 0) }
        try #require(epochs.h > epochs.ahead, "setup: H is created after the holders ahead: \(epochs)")
        // v3 maps zz-b and every holder's id to O's content.
        try await Self.applyHeld([s.q] + fillers + [a, bToO, k, p] + aheadOnO + Self.laterFillers(seed + 6_000), tag: "v3-pending-\(seed)", s, visit: visit)
        // O's first attempt times out (a retry below every cap) or gets its 404.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            let owed = await engine.readForTests { e in e.inboundOwed && e.state.inboundMoves[e.state.inboundNext...].contains { $0.holder == b.transferID } }
            try #require(owed, "setup: O's attempt's end owes H's move onto O")
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
        try await Self.applyHeld([s.q] + fillers + [a, bToJ, k, p] + aheadOnO + Self.laterFillers(seed + 9_000), tag: "v4-pending-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in e.inboundOwed && e.state.inboundMoves[e.state.inboundNext...].contains { $0.holder == b.transferID } }
            try #require(owed, "setup: H's move onto O is still owed after v4's apply")
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
        for waiter in aheadWaiters {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
        }
        let jStarts = await s.harness.source.starts.filter { $0.id == p.transferID }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return PendingLaneOutcome(p: pResult, b: bResult, a: aResult, throttled: after != before, jStarts: jStarts)
    }

    /// A 429 that arrives while H's move onto O is still owed is decided on the lane a visit-first engine's J had: v3's
    /// visit moved B onto O, and v4's visit, after O's verdict, moved it on to J. Counted only on O, as the cycle-18
    /// `followedLane` counted every id an owed move carries whatever a later copy maps it to, J's 429 was prefetch work:
    /// it throttled the origin for 61 s, J's retry served P, and O's retry met the throttle, so A was answered
    /// `serverUnavailable(60)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 counts a user interest an owed move brings onto a job whose verdict waits, on the content a later apply moves it to (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PendingLaneShape.allCases)
    func barrierDecidesA429OnTheLaneAnOwedMoveLeavesAfterALaterApply(_ visit: LaneDropVisit, _ shape: PendingLaneShape) async throws {
        let outcome = try await self.pendingLane(visit, shape)
        if case .failure(.serverUnavailable) = outcome.p {
        } else {
            Issue.record("J's 429 is user work beyond its cap: P is answered serverUnavailable (visit-first): \(outcome.p); jStarts \(outcome.jStarts)")
        }
        if case .failure(.serverUnavailable) = outcome.b {
        } else {
            Issue.record("B, on J since v4's visit, is answered serverUnavailable (visit-first): \(outcome.b)")
        }
        #expect(!outcome.throttled, "a 429 beyond the user lane's cap throttles nothing (visit-first)")
        #expect(outcome.jStarts == 1, "J starts once (visit-first): \(outcome.jStarts)")
        #expect((try? outcome.a.get())?.byteSize == 100_000, "O's retry serves A (visit-first): \(outcome.a)")
    }

    /// The same with O's 404 (`pendingLane(_:_:ending: .notFound)`): while H's move onto O is owed, B's interest counts by
    /// O's rule, whose waiting 404 answers it, not by H's, whose owed visit would move it: a visit-first engine's O
    /// answered B before v4, so J's 429 was prefetch work, throttled the origin, and J's retry served P.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 leaves out a user interest an owed move brings onto a job whose waiting verdict answers it (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PendingLaneShape.allCases)
    func barrierDecidesA429WithoutAnInterestTheOwedMovesVerdictAnswers(_ visit: LaneDropVisit, _ shape: PendingLaneShape) async throws {
        let outcome = try await self.pendingLane(visit, shape, ending: .notFound)
        #expect((try? outcome.p.get())?.byteSize == 16, "J's 429 is prefetch work below its cap: J's retry serves P (visit-first): \(outcome.p); jStarts \(outcome.jStarts)")
        #expect(outcome.b == .failure(.notFound), "O's 404 answers B, moved onto O by v3's visit (visit-first): \(outcome.b)")
        #expect(outcome.throttled, "a 429 of prefetch work below its cap throttles the origin (visit-first)")
        #expect(outcome.jStarts == 2, "J's retry starts it again (visit-first): \(outcome.jStarts)")
        #expect(outcome.a == .failure(.notFound), "O's 404 answers A: \(outcome.a)")
    }
}
