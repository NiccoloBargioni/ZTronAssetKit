import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// `PROBE-RR21-JOIN-GAP`'s failure shape (Stage 3 close-out cycle 21, ruling S3-R26 item 12's answer 6.4): evidence at
/// step 1, run again at rr21-C4 in both orders, where it broke in `sweepFollowsFirst`; with it, the join gap's T21 shape
/// after a commit and RR21-HOP's join variant (`integrate-rr21.md` R18). Each expects the visit-first answers in both
/// orders.
extension EngineFollowBarrierTests {
    /// The join gap with X's publication failing its integrity check, W and V prefetch waiters.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a request's waiting join gets the failure of the publication it joined visited first, which a later apply passed (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAWaitingJoinWithAPassedPublicationsFailure(_ visit: LaneDropVisit) async throws {
        let (v, w) = try await self.joinGap(visit, corrupt: true, lane: .prefetch)
        #expect(v == .failure(.integrityFailure), "V gets X's integrity failure for zz-d: \(v)")
        #expect(w == .failure(.integrityFailure), "W, which joined X before v4 (visit-first), gets X's integrity failure: \(w)")
    }

    /// W's join for zz-a waits for the follow while X (the content of zz-a and zz-d) downloads for V, which wants zz-d;
    /// X then publishes (held at its first store unit), v4 drops zz-a and keeps zz-d on X's content, X commits, and v5
    /// lists zz-a again on Y's content, all before the replay. Visited first, W joined X at once, v4's visit passed X
    /// publishing, and X's commit ended W's interest under v4's copy (T21): W got `.notFound`, and v5 found no interest
    /// to move. Returns V's and W's answers, and Y's starts.
    @available(macOS 15.0, iOS 18.0, *)
    func joinGapDropped(_ visit: LaneDropVisit) async throws -> (v: Result<AssetLocation, AssetError>, w: Result<AssetLocation, AssetError>, yStarts: Int) {
        let seed: UInt64 = 2_021_621
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let xBytes = EngineFixture.bytes(seed + 3, count: 16)
        let yBytes = EngineFixture.bytes(seed + 4, count: 20)
        let aOnX = EngineHarness.onDemand("zz-a", xBytes)
        let aOnY = EngineHarness.onDemand("zz-a", yBytes)
        let d = EngineHarness.onDemand("zz-d", xBytes)
        let x = aOnX.transferID
        let y = aOnY.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [aOnX, d] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(x, [.hold, .stage(xBytes)])
        await s.harness.source.script(y, [.stage(yBytes)])
        let dID = d.identifier
        let v = Task { await engine.awaitAsset(dID, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[x]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [aOnX, d] + Self.laterFillers(seed + 6_000), tag: "v3-join-gap-dropped-\(seed)", s, visit: visit)
        let aID = aOnX.identifier
        let w = Task { await engine.awaitAsset(aID, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, aOnX) }
        } else {
            await engine.awaitCondition { $0.state.jobs[x]?.interests.count == 2 }
        }
        let releaser = try await Self.holdPublication(of: x, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [d] + Self.laterFillers(seed + 9_000), tag: "v4-join-gap-dropped-\(seed)", s, visit: visit)
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await engine.awaitCondition { $0.state.jobs[x] == nil }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 400) + [aOnY, d] + Self.laterFillers(seed + 12_000), tag: "v5-join-gap-dropped-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let waiting = await engine.readForTests { e in FollowBarrier.joinWaits(e, aOnX) }
            try #require(waiting, "setup: W's join still waits after X's commit and v5")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let vResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: v) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: w) }
        let yStarts = await s.harness.source.starts.filter { $0.id == y }.count
        await Self.finishHeld(s)
        return (vResult, wResult, yStarts)
    }

    /// The join gap's T21 shape: W's waiting join follows X's commit, which ended its interest under v4's copy.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a request's waiting join whose job a later apply passed publishing ends at that job's commit under a copy that dropped its id, though a later apply lists it again (F-28, T21)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierEndsAWaitingJoinAtItsPassedJobsCommitUnderACopyThatDroppedIt(_ visit: LaneDropVisit) async throws {
        let (v, w, yStarts) = try await self.joinGapDropped(visit)
        #expect((try? v.get())?.byteSize == 16, "V gets X's bytes for zz-d: \(v)")
        #expect(w == .failure(.notFound) && yStarts == 0, "W, passed on X by v4's visit (visit-first), gets .notFound at X's commit, and Y is never requested: \(w), Y's starts \(yStarts)")
    }

    /// The layer counts of the chains of the joins that wait in `eventsAfterFollow`, in queue order.
    static func waitingJoinChains(_ e: isolated SyncEngine) -> [Int] {
        e.state.eventsAfterFollow.compactMap { event in
            if case .join(let join) = event {
                return join.chain?.layers.count
            }
            return nil
        }
    }

    /// A waiting join's chain (`JoinChain`): J's join for zz-j, on P's content, waits behind O's owed batch with a chain
    /// and no layer, and K1 gives it one. A layer no apply adopted, injected through the test seam (`violations(after:)`),
    /// reports the clause's exact message; J's replay follows the chain to P's job, which serves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the invariants report a waiting join whose chain holds a copy no apply adopted (F-28, rr21-C4)", .timeLimit(.minutes(3)))
    func invariantsReportAWaitingJoinsChainWithoutItsCopies() async throws {
        let seed: UInt64 = 2_027_441
        let pBytes = EngineFixture.bytes(seed + 5, count: 18)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let j = EngineHarness.onDemand("zz-j", pBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [p, j])
        let engine = c.engine
        await c.s.harness.source.script(p.transferID, [.stage(pBytes)])
        let held = try await Self.oweThroughK0(c, k0: [p, j] + Self.movedOnto(pBytes, c), visit: .followVisitedFirst)
        let jID = j.identifier
        let joiner = Task { await engine.awaitAsset(jID, lane: .userInitiated) }
        await engine.awaitCondition { FollowBarrier.joinWaits($0, j) }
        let token = try #require(await engine.readForTests { e in e.state.waiters.first { $0.value.asset == jID }?.key })
        let deferred = await engine.readForTests { e in Self.waitingJoinChains(e) }
        #expect(deferred == [0], "J's join waits with a chain and no layer: \(deferred)")
        let layered = await engine.violations { state in
            for index in state.eventsAfterFollow.indices {
                guard case .join(var join) = state.eventsAfterFollow[index], var chain = join.chain else {
                    continue
                }
                chain.layers.append(RerouteLayer(outgoing: state.applied, applies: 0, ends: [:]))
                join.chain = chain
                state.eventsAfterFollow[index] = .join(join)
            }
        }
        #expect(layered == ["a waiting join of interest \(token.rawValue) in \(jID) holds 1 copies for 0 adopted since it deferred"], "a chain with a copy no apply adopted: \(layered)")
        // Nothing is in flight, so K1's follow ends in its turn and replays the batch at its end; J's join waits for the
        // drain's next turn, with the layer K1 gave its chain.
        try await Self.applyBehindBatch(c.manifest([p, j], round: 2), tag: "k1-chain-\(seed)", c, waits: false)
        let after = await engine.readForTests { e in Self.waitingJoinChains(e) }
        #expect(after == [1], "K1 gives J's chain its layer: \(after)")
        let clean = await engine.invariantViolations()
        #expect(clean.isEmpty, "\(clean.prefix(3))")
        let outcome = await Self.finishOwed(c, held: held, others: [joiner])
        #expect(Self.sizes(outcome.others) == [18] && outcome.violations.isEmpty, "J gets P's bytes: \(outcome)")
        await Self.finishHeld(c.s)
    }

    /// RR21-HOP's join variant, integrity (`publishingPin` with `joining`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a request's join waiting behind owed re-routes gets the integrity failure of the job a later apply passed publishing (F-28, RR-14, RR21-HOP)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func waitingJoinPinnedToAPublishingJobGetsItsIntegrityFailure(_ visit: LaneDropVisit) async throws {
        let (outcome, zStarts) = try await self.publishingPin(visit, seed: 2_027_431, end: .integrity, joining: true)
        #expect(outcome.others == [.failure(.integrityFailure), .failure(.integrityFailure)], "Q and J get P's integrity failure: \(outcome)")
        #expect(outcome.w.allSatisfy { $0 == .failure(.integrityFailure) }, "W1…W3 get P's failure: \(outcome)")
        #expect(Self.sizes([outcome.k]) == [16] && zStarts == 0, "K gets O's bytes, and Z is never requested: \(outcome), Z's starts \(zStarts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    /// RR21-HOP's join variant, storage (`PinnedEnd.storageUnavailable`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a request's join waiting behind owed re-routes gets the storage failure of the job a later apply passed publishing (F-28, RR-14, RR21-HOP)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func waitingJoinPinnedToAPublishingJobGetsItsStorageFailure(_ visit: LaneDropVisit) async throws {
        let (outcome, zStarts) = try await self.publishingPin(visit, seed: 2_027_436, end: .storageUnavailable, joining: true)
        let failure: Result<AssetLocation, AssetError> = .failure(.storageUnavailable(.rootVanished))
        #expect(outcome.others == [failure, failure], "Q and J get P's storage failure: \(outcome)")
        #expect(outcome.w.allSatisfy { $0 == failure }, "W1…W3 get P's failure: \(outcome)")
        #expect(Self.sizes([outcome.k]) == [16] && zStarts == 0, "K gets O's bytes, and Z is never requested: \(outcome), Z's starts \(zStarts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }
}
