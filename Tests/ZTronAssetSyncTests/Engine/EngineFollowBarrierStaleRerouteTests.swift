import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The ids a publication re-routes are re-routed by one visit only (Stage 3 close-out cycle 16; the cycle-15 verifiers'
/// PROBE-C15R-REROUTE-STALE and PROBE-C15C-STALE-REROUTE). `Job.rerouteOnPass` names the ids a visit-first engine had
/// moved before the publication began, which the owed visit that meets the job publishing re-routes at once (ruling
/// S3-R18 item 2). Kept after that visit, it re-routed again an id a later apply had moved back and away while the job
/// published, which a visit-first engine passed and answered with the publication's outcome. Each test runs in both
/// orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// When v4 maps zz-b back to C's content in `staleReroute`, behind the barrier.
    enum StaleRerouteV4: Sendable {
        /// After v3's follow ended: its visit of C re-routed B onto N, and v5's follow is a later one.
        case afterFollow
        /// While v3's follow still owes C's visit, which then finds nothing moved; v5's follow is a later one.
        case beforeVisit
        /// After v3's follow visited C and re-routed B onto N, while that follow is still owed; v5 is applied while it is
        /// owed too, so v5's visit of C belongs to the same follow as the visit that re-routed B.
        case afterVisitWhileOwed
    }

    /// Runs held follow-up turns of the follow until `done` holds; requires the follow to stay owed throughout.
    @available(macOS 15.0, iOS 18.0, *)
    static func runFollowTurns(_ engine: SyncEngine, until done: @escaping @Sendable (isolated SyncEngine) -> Bool, _ setup: String) async throws {
        for _ in 0..<12 {
            let now = await engine.readForTests { e in (done: done(e), owed: e.followOwed) }
            try #require(now.owed, "setup: the follow is still owed (\(setup))")
            if now.done {
                return
            }
            await Self.runOneFollowTurn(engine)
        }
        Issue.record("setup: \(setup) within twelve follow turns")
    }

    /// The shared scenario: C (100 kB, the content of zz-a and zz-b, a user waiter each) publishes bytes that fail their
    /// checksum. v3 moves zz-b to N (16 bytes, its download held); C's publication begins after v3's apply and is held at
    /// its first store unit, so behind the barrier it begins while v3's follow still owes C's visit (`rerouteOnPass` is
    /// `[zz-b]`). v4 maps zz-b back to C's content while C still publishes (`when`); where v3's visit re-routed B onto N,
    /// N's visit then supersedes N and B rejoins C. v5 moves zz-b to N2 (24 bytes) while the same publication still
    /// verifies: its follow passes C in both orders. Visited first, v3's visit moved B onto N while C downloaded, v4's
    /// superseded N and B rejoined C, and v5's passed C, publishing, so B was answered C's `integrityFailure`. Returns the
    /// answers of A and B, and of D with `pair`.
    ///
    /// With `pair`, zz-d (a user waiter D) shares C too and moves with zz-b, and a follow turn moves one id
    /// (`EngineState.followIDsPerTurn`): the visit that re-routes the two ids C's publication began without makes one per
    /// turn and spends the re-route at its last (`continueVisitRemainder`; Stage 3 close-out cycle 19). v3 and v4 then
    /// also list a tail of entries without jobs, changed at v4 behind the barrier, so v4's pass is still owed at N's
    /// visit, which the visit's rest puts a turn later.
    @available(macOS 15.0, iOS 18.0, *)
    func staleReroute(_ visit: LaneDropVisit, seed: UInt64, when: StaleRerouteV4, pair: Bool = false) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>, d: Result<AssetLocation, AssetError>?) {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let n2Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        let bMoved2 = EngineHarness.onDemand("zz-b", n2Bytes)
        let d = pair ? [EngineHarness.onDemand("zz-d", cBytes)] : []
        let dMoved = pair ? [EngineHarness.onDemand("zz-d", nBytes)] : []
        let dMoved2 = pair ? [EngineHarness.onDemand("zz-d", n2Bytes)] : []
        func tail(_ base: UInt64) -> [ManifestEntry] {
            guard pair else {
                return []
            }
            return (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "zzzz%05d", $0), EngineFixture.bytes(base + UInt64($0), count: 16)) }
        }
        let tail3 = tail(seed + 12_000)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + d + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        await s.harness.source.script(bMoved2.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        var dWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        if let id = d.first?.identifier {
            dWaiter = Task { await engine.awaitAsset(id, lane: .userInitiated) }
            await engine.readForTests { $0.state.followIDsPerTurn = 1 }
        }
        let interests = 2 + d.count
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == interests }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved] + dMoved + later + tail3, tag: "v3-stale-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            // Visited first, C's visit moved B onto N, whose download is held, at the apply.
            await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
        }
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            let atPublish = await engine.readForTests { e in (owed: e.followOwed, reroute: e.state.jobs[a.transferID]?.rerouteOnPass) }
            #expect(atPublish.owed && atPublish.reroute == Set([b.identifier] + d.map(\.identifier)), "setup: C's publication began while v3's follow owed C's visit: \(atPublish)")
        }
        let v4 = [s.q] + fillers + [a, b] + d + later + tail3
        var v5Visit = LaneDropVisit.followVisitedFirst
        switch when {
        case .beforeVisit:
            // v4 maps zz-b back while (behind the barrier) v3's follow still owes C's visit: that visit finds nothing moved.
            try await Self.applyHeld(v4, tag: "v4-stale-\(seed)", s, visit: visit)
            if visit == .sweepFollowsFirst {
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            }
        case .afterFollow:
            if visit == .sweepFollowsFirst {
                // v3's follow visits C, publishing, and re-routes zz-b onto N at once.
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            }
            await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
            // v4 maps zz-b back after v3's follow ended: N's visit supersedes N, and B rejoins C.
            try await Self.applyHeld(v4, tag: "v4-stale-\(seed)", s, visit: .followVisitedFirst)
        case .afterVisitWhileOwed:
            if visit == .sweepFollowsFirst {
                // v3's follow visits C, publishing, and re-routes zz-b onto N at once (queued: no admission is made while
                // the follow is owed); its later fillers keep it owed.
                try await Self.runFollowTurns(engine, until: { $0.state.jobs[bMoved.transferID] != nil }, "v3's visit re-routes B onto N")
                // v4 maps zz-b back while that follow is owed (its own later fillers keep it so); N's visit supersedes N,
                // and B rejoins C, before v5.
                try await Self.applyHeld([s.q] + fillers + [a, b] + d + Self.laterFillers(seed + 9_000) + tail(seed + 15_000), tag: "v4-stale-\(seed)", s, visit: visit)
                try await Self.runFollowTurns(engine, until: { $0.state.jobs[bMoved.transferID] == nil }, "v4's visit supersedes N")
                v5Visit = .sweepFollowsFirst
            } else {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
                try await Self.applyHeld(v4, tag: "v4-stale-\(seed)", s, visit: visit)
            }
        }
        let atV4 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), n: e.state.jobs[bMoved.transferID]?.state)
        }
        try #require(atV4.c == .verifying && atV4.cAssets == ([a, b] + d).map(\.identifier).sorted() && atV4.n == nil, "setup: B is on C, which still publishes, and N is gone: \(atV4)")
        // v5 moves zz-b to N2 while the same publication still verifies: its follow passes C in both orders.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved2] + dMoved2 + later + tail3, tag: "v5-stale-\(seed)", s, visit: v5Visit)
        if v5Visit == .sweepFollowsFirst {
            // v5's visit of C comes in the follow that re-routed B at v3's visit.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let atV5 = await engine.readForTests { e in e.state.jobs[a.transferID]?.state }
        try #require(atV5 == .verifying, "setup: the same publication still verifies at v5: \(String(describing: atV5))")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        var dResult: Result<AssetLocation, AssetError>?
        if let dWaiter {
            dResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: dWaiter) }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (aResult, bResult, dResult)
    }

    /// A later apply's follow that passes a publication leaves an id it moved to the publication's outcome, although an
    /// earlier visit of the same publication re-routed that id before an apply moved it back (`staleReroute`, v4 after
    /// v3's follow ended; PROBE-C15R-REROUTE-STALE): behind the barrier, the ids the first visit re-routed stayed in
    /// `rerouteOnPass`, and v5's visit re-routed zz-b onto N2, which served B.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a later apply's follow that passes a publication again leaves an id moved back and away to the publication (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierLeavesAnIdMovedBackAndAwayToThePublication(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult, _) = try await self.staleReroute(visit, seed: 1_515_002, when: .afterFollow)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: v5's follow passed C, publishing (visit-first): \(bResult)")
    }

    /// As above, with v4 applied while v3's follow still owes C's visit (PROBE-C15C-STALE-REROUTE): the follow's pass
    /// compares with the current copy, where v4 mapped zz-b back, so C's visit never comes; a visit-first engine's v3
    /// visit had re-routed B and its v4 visit found B back on C. The re-route belongs to v3's follow and is spent when
    /// that follow ends (`Job.rerouteFor`), so v5's later follow passes C.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a re-route is spent once the follow it belongs to ends without the visit (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierSpendsTheRerouteOfAVisitThatFindsNothingMoved(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult, _) = try await self.staleReroute(visit, seed: 1_515_902, when: .beforeVisit)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: v5's follow passed C, publishing (visit-first): \(bResult)")
    }

    /// As above, with v4 and v5 applied while the follow whose visit re-routed B is still owed: v5's visit of C belongs
    /// to the same follow, and passes C because that visit spent the re-route (`Job.rerouteOnPass` emptied).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a visit spends the re-route it used, for the later visits of the same follow (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierSpendsTheRerouteForTheSameFollowsLaterVisits(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult, _) = try await self.staleReroute(visit, seed: 1_616_502, when: .afterVisitWhileOwed)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: v5's visit passed C, publishing (visit-first): \(bResult)")
    }

    /// As above, with two ids moving together and a follow turn moving one (`staleReroute(_:seed:when:pair: true)`): the
    /// visit that re-routes them makes one per turn and spends the re-route at its last, so v5's visit of C, in the same
    /// follow, passes C, publishing, and D and B get C's integrity failure (Stage 3 close-out cycle 19).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a visit re-routing more ids than a turn moves spends the re-route at its last, for the same follow's later visits (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierSpendsTheRerouteOfAVisitMadeOverTurns(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult, dResult) = try await self.staleReroute(visit, seed: 1_919_502, when: .afterVisitWhileOwed, pair: true)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: v5's visit passed C, publishing (visit-first): \(bResult)")
        #expect(dResult == .failure(.integrityFailure), "D gets C's integrity failure too (visit-first): \(String(describing: dResult))")
    }
}
