import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A visit's rest and the owed moves of a turn whose holders run out before its ids (Stage 3 close-out cycle 19; rulings
/// S3-R20 item 3 and S3-R22 item 1): the moves stand for visits a visit-first engine had made before the rest was moved,
/// so the rest waits while one is owed, though the turn's `followsPerTurn` holders, not its ids, ended the moves. H's
/// 270 members share one content, 330 holders created before H have one id each, their entries after the members', and
/// v3 maps every member and holder to O's content. Sweep-first, O's 404 arrives while H's visit owes its rest: the
/// attempt's end finds a move per holder and one of H's last members, in the holders' epoch order, so H's comes after
/// the 320 moves the end turn and the next turn make. Each case runs in both orders (`LaneDropVisit`) with the
/// visit-first answers expected in both.
extension EngineFollowBarrierTests {
    /// H's members: a visit of them moves `restOrderIDsPerTurn` and leaves the rest.
    static let restOrderMembers = 270

    /// The ids a follow turn moves here (`EngineState.followIDsPerTurn`): more than a turn's `followsPerTurn` holders of
    /// one id each, so the holders, not the ids, end the turn's moves.
    static let restOrderIDsPerTurn = 260

    /// The holders created before H: more than the end turn's `inboundMovesNow` and the next turn's `followsPerTurn`.
    static var restOrderHolders: Int {
        SyncEngine.inboundMovesNow + SyncEngine.followsPerTurn + 10
    }

    /// What `restOrder` reads: the answers of O's waiter, of each member's and of each holder's, O's starts, and, after
    /// each sweep-first turn while H's move is still owed, the members on H.
    struct RestOrderOutcome {
        /// O's waiter's answer.
        let o: Result<AssetLocation, AssetError>
        /// Each member's waiter's answer, in member order.
        let members: [Result<AssetLocation, AssetError>]
        /// Each holder's waiter's answer, in holder order.
        let holders: [Result<AssetLocation, AssetError>]
        /// The starts of O's transfer.
        let oStarts: Int
        /// The members on H when O's attempt ended (sweep-first).
        let leftAtEnd: Int?
        /// The members on H after each follow turn made while H's move was still owed after it (sweep-first).
        let leftWhileOwed: [Int]
    }

    /// O (zz-o, 24 B, a user waiter) downloads, held; the 330 holders (zz-u…, 16 B each, a prefetch waiter each) and
    /// then H's 270 members (zz-s…, sharing 16 B, a prefetch waiter each) wait. O's first request ends in a 404, and a
    /// second request for its content, which a visit-first engine never made, would get one too. Visited first, v3's
    /// visit moved every member and holder onto O, whose 404 answered them all, and O started once.
    @available(macOS 15.0, iOS 18.0, *)
    func restOrder(_ visit: LaneDropVisit, seed: UInt64) async throws -> RestOrderOutcome {
        let (s, _) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.restOrderIDsPerTurn }
        let oBytes = EngineFixture.bytes(seed + 3, count: 24)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let memberNames = (0..<Self.restOrderMembers).map { String(format: "zz-s%03d", $0) }
        let onH = memberNames.map { EngineHarness.onDemand($0, hBytes) }
        let membersOnO = memberNames.map { EngineHarness.onDemand($0, oBytes) }
        let holderNames = (0..<Self.restOrderHolders).map { String(format: "zz-u%04d", $0) }
        let holdersOwn = holderNames.enumerated().map { EngineHarness.onDemand($0.element, EngineFixture.bytes(seed + 10_000 + UInt64($0.offset), count: 16)) }
        let holdersOnO = holderNames.map { EngineHarness.onDemand($0, oBytes) }
        let holder = try #require(onH.first?.transferID)
        try #require(
            Set(onH.map(\.transferID)).count == 1 && (membersOnO + holdersOnO).allSatisfy { $0.transferID == o.transferID },
            "setup: the members share H, and v3 maps every member and holder to O's content"
        )
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [o] + onH + holdersOwn + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .fail(.permanentMissing(httpStatus: 404))])
        await s.harness.source.script(holder, [.hold, .stage(hBytes)])
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        // The holders are created before H, so the walk orders their moves first.
        var holderWaiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in holdersOwn {
            let id = entry.identifier
            holderWaiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        let holderTransfers = holdersOwn.map(\.transferID)
        await engine.awaitCondition { e in holderTransfers.allSatisfy { e.state.jobs[$0]?.interests.isEmpty == false } }
        var memberWaiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in onH {
            let id = entry.identifier
            memberWaiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        await engine.awaitCondition { $0.state.jobs[holder]?.interests.count == Self.restOrderMembers }
        let epochs = await engine.readForTests { e in (h: e.state.jobs[holder]?.epoch ?? 0, ahead: holderTransfers.compactMap { e.state.jobs[$0]?.epoch }.max() ?? 0) }
        try #require(epochs.h > epochs.ahead, "setup: H is created after the holders: \(epochs)")
        let memberIDs = onH.map(\.identifier)
        try await Self.applyHeld(
            [s.q] + FollowBarrier.fillers(seed + 200) + [o] + membersOnO + holdersOnO + Self.laterFillers(seed + 6_000),
            tag: "v3-rest-order-\(seed)",
            s,
            visit: visit
        )
        var leftAtEnd: Int?
        var leftWhileOwed: [Int] = []
        if visit == .sweepFollowsFirst {
            // H's visit moves a turn's ids and leaves its rest; the holders' visits, after it in the follow's order, wait.
            var turns = 0
            while await engine.readForTests({ $0.state.followMoving?.holder != holder }) {
                try #require(turns < 8, "setup: H's visit leaves its rest within 8 follow turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            let unvisited = await engine.readForTests { e in holderTransfers.filter { e.state.unfollowed.contains($0) }.count }
            try #require(unvisited == Self.restOrderHolders, "setup: no holder is visited while H's rest is owed: \(unvisited)")
            leftAtEnd = await Self.membersLeft(engine, on: holder, members: memberIDs)
            // O's 404 arrives: its verdict waits, and its attempt's end owes a move per holder, H's last.
            await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.verdictsAfterFollow[o.transferID] != nil }
            let owed = await engine.readForTests { e in e.state.inboundMoves[e.state.inboundNext...].map(\.holder) }
            try #require(owed.last == holder && owed.count > SyncEngine.followsPerTurn, "setup: O's attempt's end owes H's move after more than a turn's holders: \(owed.count), H's last: \(owed.last == holder)")
            while await engine.readForTests({ $0.followOwed }) {
                try #require(leftWhileOwed.count < 24, "the follow ends within 24 turns")
                await Self.runOneFollowTurn(engine)
                let hOwed = await engine.readForTests { e in e.inboundOwed && e.state.inboundMoves[e.state.inboundNext...].contains { $0.holder == holder } }
                guard hOwed else {
                    break
                }
                leftWhileOwed.append(await Self.membersLeft(engine, on: holder, members: memberIDs))
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        if visit == .followVisitedFirst {
            // O's 404 arrives once the follow ended.
            await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let oResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: oWaiter) }
        var members: [Result<AssetLocation, AssetError>] = []
        for waiter in memberWaiters {
            members.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        var holders: [Result<AssetLocation, AssetError>] = []
        for waiter in holderWaiters {
            holders.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        let oStarts = await s.harness.source.starts.filter { $0.id == o.transferID }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return RestOrderOutcome(o: oResult, members: members, holders: holders, oStarts: oStarts, leftAtEnd: leftAtEnd, leftWhileOwed: leftWhileOwed)
    }

    /// While a move is owed after a turn's holders ran out, H's rest waits: H's move, made with the last holders', brings
    /// its last members onto O at the attempt's end, as v3's visit on a visit-first engine had joined them to O before
    /// O's 404, so the 404 answers every member and holder and O starts once. Moved first as a visit, those members met
    /// O's waiting verdict, joined behind it (`addInterest`) and gave O's content a second request.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a visit's rest waits for the moves a turn's holders leave owed, so the 404 that ended the moves' job answers every member with one request (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierMakesTheOwedMovesBeforeAVisitsRest(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.restOrder(visit, seed: 1_919_602)
        #expect(outcome.o == .failure(.notFound), "O's waiter gets its 404: \(outcome.o)")
        let members = outcome.members.filter { $0 != .failure(.notFound) }
        #expect(members.isEmpty, "O's 404 answers every member, moved onto O by v3's visit (visit-first): \(members.count) do not, \(members.prefix(3))")
        let holders = outcome.holders.filter { $0 != .failure(.notFound) }
        #expect(holders.isEmpty, "O's 404 answers every holder (visit-first): \(holders.count) do not, \(holders.prefix(3))")
        #expect(outcome.oStarts == 1, "O's content is requested once (visit-first): \(outcome.oStarts)")
        guard visit == .sweepFollowsFirst else {
            return
        }
        let left = try #require(outcome.leftAtEnd)
        #expect(left > 0 && left < Self.restOrderMembers, "setup: H's rest owed members when O's attempt ended: \(left)")
        #expect(!outcome.leftWhileOwed.isEmpty && outcome.leftWhileOwed.allSatisfy { $0 == left }, "no member leaves H while its move is owed: the rest waits for it (\(left) on H): \(outcome.leftWhileOwed)")
    }
}
