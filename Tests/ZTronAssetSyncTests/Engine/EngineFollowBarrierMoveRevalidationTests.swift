import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// What lands between the turns of a bounded move (Stage 3 close-out cycle 20, ruling S3-R25 item 8; the cycle-19
/// requirements verifier's reqs #5): `continueMove` reads each interest again as it takes it, so an interest that left
/// the holder meanwhile, or that no longer holds the id, is passed over (its two per-interest guards), and a superseded
/// holder an id rejoined meanwhile is re-laned at the move's end from the lane it had when the move began. Ten members
/// share H's content, each with a prefetch waiter, U (a user waiter) wants the first, and G (a prefetch group) all ten;
/// v3 maps them to O's content, and H's visit moves four a turn (`followIDsPerTurn`), so sweep-first a release, a purge
/// or an apply lands while the visit's rest is owed. A waiter's cancellation does not land there: behind the barrier its
/// interest's removal waits for the drain (`withdraw`). One transfer runs at a time, so the starts after O's are the
/// queue's order. Each case runs in both orders (`LaneDropVisit`), with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// The members sharing H's content.
    static let revalidationMembers = 10

    /// The ids a follow turn moves here: H's visit leaves six members for its later turns.
    static let revalidationIDsPerTurn = 4

    /// What lands after the first turn of H's visit (sweep-first), or after the follow (visit-first).
    enum MoveRevalidationShape: String, Sendable, CaseIterable {
        /// G is released: its interest leaves H and O at once (`performReleaseGroup`, `removeInterest`), so the rest's
        /// items of G's token find no interest on H.
        case groupReleased
        /// zz-s06 is purged: G's interest keeps its other ids (`withdrawPurged`, `subtractAssets`), so the rest's item
        /// (zz-s06, G) finds an interest without its id; G2's, whose only id it was, leaves H, so (zz-s06, G2) finds none.
        /// zz-s06's waiter keeps its interest (a purge withdraws no waiter's).
        case memberPurged
        /// v4 maps zz-s07 back to H's content: the rest re-routes its interests onto H, which keeps them (`reroute`), and
        /// H, superseded on the user lane U gave it, ends the move on the prefetch lane they ask for.
        case mappedBack
    }

    /// What `moveRevalidation` reads once the follow ended, before O's bytes arrive, and the answers after.
    struct MoveRevalidationOutcome {
        /// The ids of G's interest in O's job and in H's.
        let gOnO: Set<AssetID>?
        let gOnH: Set<AssetID>?
        /// The jobs holding an interest of G, and of G2.
        let gJobs: Int
        let g2Jobs: Int
        /// H's job: its ids, lane and state.
        let hAssets: Set<AssetID>?
        let hLane: AssetPriority?
        let hState: JobState?
        /// The ids on O's job.
        let oAssets: Set<AssetID>?
        /// The members left on H after each sweep-first turn once the shape landed.
        let left: [Int]
        /// The answers of O's waiter, U, P (zz-p, a prefetch waiter on a content of its own) and each member's waiter.
        let o: Result<AssetLocation, AssetError>
        let u: Result<AssetLocation, AssetError>
        let p: Result<AssetLocation, AssetError>
        let members: [Result<AssetLocation, AssetError>]
        /// The starts of O's, P's and H's transfers, in order.
        let starts: [String]
    }

    /// O (zz-o, 24 B, a user waiter) downloads, held, in the one slot; P (zz-p, 12 B) waits queued. The members (zz-s00…,
    /// sharing H's 16 B, a prefetch waiter each) wait queued on H, which U's waiter puts in the user lane, with G's
    /// interest in all ten and G2's in zz-s06. v3 maps every member to O's content. Visited first, v3's visit moved them
    /// all onto O and removed H, and the shape landed after it: the release and the purge on O, v4's visit by a fresh job
    /// of H's content for zz-s07, queued after P.
    @available(macOS 15.0, iOS 18.0, *)
    func moveRevalidation(_ visit: LaneDropVisit, shape: MoveRevalidationShape) async throws -> MoveRevalidationOutcome {
        let seed: UInt64 = 2_020_802
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.revalidationIDsPerTurn }
        let oBytes = EngineFixture.bytes(seed + 3, count: 24)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let pBytes = EngineFixture.bytes(seed + 5, count: 12)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let names = (0..<Self.revalidationMembers).map { String(format: "zz-s%02d", $0) }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let onO = names.map { EngineHarness.onDemand($0, oBytes) }
        let ids = onH.map(\.identifier)
        let holder = onH[0].transferID
        try #require(Set(onH.map(\.transferID)) == [holder] && onO.allSatisfy { $0.transferID == o.transferID }, "setup: the members share H, and v3 maps them to O's content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onH + [o, p] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(o.transferID, [.hold, .stage(oBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        await s.harness.source.script(holder, [.stage(hBytes)])
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .queued }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for id in ids {
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        await engine.awaitCondition { $0.state.jobs[holder]?.interests.count == Self.revalidationMembers }
        let uWaiter = Task { await engine.awaitAsset(ids[0], lane: .userInitiated) }
        let g = try await engine.registerGroup(ids, lane: .prefetch).get()
        let g2 = try await engine.registerGroup([ids[6]], lane: .prefetch).get()
        await engine.awaitCondition { e in
            e.state.jobs[holder]?.interests.count == Self.revalidationMembers + 3 && e.state.jobs[holder]?.interests[g]?.assets.count == Self.revalidationMembers
                && e.state.jobs[holder]?.interests[g2] != nil
        }
        let before = await engine.readForTests { e in (lane: e.state.jobs[holder]?.lane, state: e.state.jobs[holder]?.state, p: e.state.jobs[p.transferID]?.state) }
        try #require(before.lane == .userInitiated && before.state == .queued && before.p == .queued, "setup: H waits queued on U's lane, P queued: \(before)")
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + onO + [o, p] + Self.laterFillers(seed + 6_000)
        // v3 with zz-s07 back on H's content and its later fillers changed.
        var v4Members = onO
        v4Members[7] = onH[7]
        let v4 = [s.q] + FollowBarrier.fillers(seed + 200) + v4Members + [o, p] + Self.laterFillers(seed + 9_000)
        try await Self.applyHeld(v3, tag: "v3-revalidation-\(seed)", s, visit: visit)
        // The release, the purge or v4: sweep-first while H's visit owes its rest, visited first once the follow ended.
        func land() async throws {
            switch shape {
            case .groupReleased:
                await engine.releaseGroup(g)
            case .memberPurged:
                let purged = await engine.purge(.scope(.identifiers([ids[6]])))
                #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
            case .mappedBack:
                try await Self.applyHeld(v4, tag: "v4-revalidation-\(seed)", s, visit: visit)
            }
        }
        var left: [Int] = []
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.state.followMoving?.holder != holder }) {
                try #require(turns < 8, "setup: H's visit leaves its rest within 8 follow turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            let rest = await engine.readForTests { e in e.state.jobs[holder]?.assets ?? [] }
            try #require(rest.count == Self.revalidationMembers - Self.revalidationIDsPerTurn && rest.contains(ids[6]) && rest.contains(ids[7]), "setup: H's visit moved one turn's ids and owes the rest, zz-s06 and zz-s07 among them: \(rest.sorted())")
            try await land()
            while await engine.readForTests({ $0.followOwed }) {
                try #require(left.count < 16, "the follow ends within 16 turns: \(left)")
                await Self.runOneFollowTurn(engine)
                left.append(await Self.membersLeft(engine, on: holder, members: ids))
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            try await land()
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let state = await engine.readForTests { e in
            (
                gOnO: e.state.jobs[o.transferID]?.interests[g]?.assets,
                gOnH: e.state.jobs[holder]?.interests[g]?.assets,
                gJobs: e.state.jobs.values.filter { $0.interests[g] != nil }.count,
                g2Jobs: e.state.jobs.values.filter { $0.interests[g2] != nil }.count,
                hAssets: e.state.jobs[holder]?.assets,
                hLane: e.state.jobs[holder]?.lane,
                hState: e.state.jobs[holder]?.state,
                oAssets: e.state.jobs[o.transferID]?.assets
            )
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "once the follow ended: \(violations.prefix(3))")
        // O's bytes arrive: its slot frees, and the queued jobs start one at a time.
        await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
        let oResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: oWaiter) }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        var members: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            members.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        let names3 = [o.transferID: "O", p.transferID: "P", holder: "H"]
        let starts = await s.harness.source.starts.compactMap { names3[$0.id] }
        await Self.finishHeld(s)
        return MoveRevalidationOutcome(
            gOnO: state.gOnO,
            gOnH: state.gOnH,
            gJobs: state.gJobs,
            g2Jobs: state.g2Jobs,
            hAssets: state.hAssets,
            hLane: state.hLane,
            hState: state.hState,
            oAssets: state.oAssets,
            left: left,
            o: oResult,
            u: uResult,
            p: pResult,
            members: members,
            starts: starts
        )
    }

    /// An interest that leaves the holder between a bounded move's turns, or keeps it without the id, is passed over,
    /// and a holder an id rejoined is re-laned at the move's end: the outcome is the visit-first one in both orders. G's
    /// released interest is on no job; a purged member is on G's interest nowhere, and G2's only member on none; zz-s07,
    /// mapped back, waits on H in the prefetch lane and starts after P, which was queued first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: what a release, a purge or an apply changes between a bounded move's turns is read again, with the visit-first outcome (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, MoveRevalidationShape.allCases)
    func barrierRereadsWhatLandsBetweenABoundedMovesTurns(_ visit: LaneDropVisit, _ shape: MoveRevalidationShape) async throws {
        let outcome = try await self.moveRevalidation(visit, shape: shape)
        let ids = (0..<Self.revalidationMembers).map { AssetID(String(format: "zz-s%02d", $0)) }
        let all = Set(ids)
        let read = "left \(outcome.left), G on O \(outcome.gOnO?.count ?? -1), on H \(outcome.gOnH?.sorted() ?? []), H \(outcome.hAssets?.sorted() ?? []) \(String(describing: outcome.hLane)) \(String(describing: outcome.hState))"
        switch shape {
        case .groupReleased:
            #expect(outcome.gJobs == 0, "G's released interest is on no job (visit-first): \(outcome.gJobs) jobs; \(read)")
            #expect(outcome.g2Jobs == 1, "G2 keeps its interest in zz-s06 on O: \(outcome.g2Jobs) jobs; \(read)")
        case .memberPurged:
            #expect(outcome.gOnO == all.subtracting([ids[6]]) && outcome.gJobs == 1, "G's interest holds every member but the purged zz-s06, on O (visit-first): \(read)")
            #expect(outcome.g2Jobs == 0, "G2's interest, whose only member was purged, is on no job (visit-first): \(outcome.g2Jobs) jobs; \(read)")
        case .mappedBack:
            #expect(outcome.gOnO == all.subtracting([ids[7]]) && outcome.gOnH == [ids[7]], "G's interest in zz-s07 is on H, the others on O (visit-first): \(read)")
            #expect(outcome.g2Jobs == 1, "G2 keeps its interest in zz-s06 on O: \(outcome.g2Jobs) jobs; \(read)")
        }
        if shape == .mappedBack {
            #expect(outcome.hAssets == [ids[7]] && outcome.hLane == .prefetch && outcome.hState == .queued, "H holds zz-s07 alone, queued in the prefetch lane (visit-first: a fresh job of its content): \(read)")
            #expect(outcome.oAssets == all.subtracting([ids[7]]).union([AssetID("zz-o")]), "O holds zz-o and every other member: \(outcome.oAssets?.count ?? -1)")
            // H's lane at the move's end is the prefetch lane, so it waits behind P, queued before it: visited first, the
            // fresh job of H's content was queued at v4's visit. Left in the user queue U had put it in, H started first.
            #expect(outcome.starts == ["O", "P", "H"], "O, then P, then H (visit-first): \(outcome.starts); \(read)")
        } else {
            #expect(outcome.hAssets == nil, "H is removed once the move took its last interest (visit-first): \(read)")
            #expect(outcome.oAssets == all.union([AssetID("zz-o")]), "O holds zz-o and every member: \(outcome.oAssets?.count ?? -1)")
            #expect(outcome.starts == ["O", "P"], "O, then P; H never starts (visit-first): \(outcome.starts)")
        }
        #expect((try? outcome.o.get())?.byteSize == 24 && (try? outcome.u.get())?.byteSize == 24, "O's waiter and U get O's bytes: \(outcome.o), \(outcome.u)")
        #expect((try? outcome.p.get())?.byteSize == 12, "P's waiter gets its bytes: \(outcome.p)")
        let expected = ids.indices.map { shape == .mappedBack && $0 == 7 ? Int64(16) : 24 }
        let got = outcome.members.map { (try? $0.get())?.byteSize ?? -1 }
        #expect(got == expected, "each member's waiter gets its content (visit-first): \(got); \(read)")
        if visit == .sweepFollowsFirst {
            #expect(!outcome.left.isEmpty && outcome.left.last == (shape == .mappedBack ? 1 : 0), "the rest left H over the follow's later turns: \(outcome.left)")
        }
    }
}
