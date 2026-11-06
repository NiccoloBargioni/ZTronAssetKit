import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Ids converging on one content while a follow is owed, more of them than an attempt's end or an apply moves at once
/// (Stage 3 close-out cycle 18, ruling S3-R20 item 3): the walk records the moves (`bringInbound`,
/// `bringInboundOntoPublications`), an attempt's end makes the first `inboundMovesNow` at once, and the follow's turns
/// make the rest before any visit, while the job's end and every later event wait (`continueInbound`). A visit-first engine's v3 visits
/// had moved every holder's interest onto O before O's attempt ended. Each case runs in both orders (`LaneDropVisit`)
/// with the visit-first outcome expected in both; sweep-first, the follow's turns run one at a time until it ends.
extension EngineFollowBarrierTests {
    /// How O's attempt ends in `convergence`, and what comes after it.
    enum ConvergenceEnding: Sendable, CaseIterable {
        /// A 404: its verdict answers O's waiter and every holder.
        case notFound
        /// O's bytes: its publication binds every holder's id and serves them all (a second attempt would 404).
        case publication
        /// A 404, then v4 maps every holder's id to Z while moves are still owed: they are made under v3's copy, and
        /// the 404 answers every holder.
        case applyBetween
        /// O's publication runs (held at its first store unit) before v3; v4 maps the holders on to Z, so its apply finds
        /// the moves onto the publication, and the publication commits while they are still owed. Visited first, v3's
        /// visits joined the holders to the publication, which did not bind them, so at its commit they followed their
        /// content to Z (`committed`); an owed move onto the ended publication is dropped, and the holder's own visit
        /// moves it to Z.
        case publicationApply
    }

    /// The holders: more than `inboundMovesNow` and `followsPerTurn` together, so the moves span the follow's turns and
    /// one turn leaves moves owed.
    static let convergenceHolders = 400

    /// What `convergence` reads: the answers of O's waiter and of every holder's, and Z's starts.
    struct ConvergenceOutcome {
        /// O's waiter's answer.
        let o: Result<AssetLocation, AssetError>
        /// Each holder's waiter's answer, in holder order.
        let holders: [Result<AssetLocation, AssetError>]
        /// The starts of Z's transfer.
        let zStarts: Int
        /// The follow's turns run one at a time after O's ending (sweep-first; 0 visited first).
        let turns: Int
    }

    /// O (16 bytes, zz-o, a user waiter) downloads while 400 holders (zz-h0000…, 16 bytes each, a prefetch waiter each)
    /// wait or download. v3 maps every holder to O's content; then O's attempt ends (`ending`). Sweep-first, the follow
    /// owes every visit when O's attempt ends (the fillers keep its first turn on their entries), so the attempt's end
    /// finds 400 moves, makes the first `inboundMovesNow`, and the follow's turns make the rest.
    @available(macOS 15.0, iOS 18.0, *)
    func convergence(_ visit: LaneDropVisit, seed: UInt64, ending: ConvergenceEnding) async throws -> ConvergenceOutcome {
        let count = Self.convergenceHolders
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 16)
        let zBytes = EngineFixture.bytes(seed + 7, count: 48)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let names = (0..<count).map { String(format: "zz-h%04d", $0) }
        let own = names.enumerated().map { EngineHarness.onDemand($0.element, EngineFixture.bytes(seed + 10_000 + UInt64($0.offset), count: 16)) }
        let onO = names.map { EngineHarness.onDemand($0, oBytes) }
        let onZ = names.map { EngineHarness.onDemand($0, zBytes) }
        let zTransfer = try #require(onZ.first?.transferID)
        try #require(onO.allSatisfy { $0.transferID == o.transferID } && Set(own.map(\.transferID)).count == count && zTransfer != o.transferID, "setup: 400 contents, v3's on O's, v4's on Z's")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + own + [o] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        switch ending {
        case .notFound, .applyBetween:
            await s.harness.source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        case .publication, .publicationApply:
            await s.harness.source.script(o.transferID, [.hold, .stage(oBytes), .fail(.permanentMissing(httpStatus: 404))])
        }
        await s.harness.source.script(zTransfer, [.stage(zBytes)])
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for holder in own {
            let id = holder.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        let ownTransfers = own.map(\.transferID)
        await engine.awaitCondition { e in ownTransfers.allSatisfy { e.state.jobs[$0]?.interests.isEmpty == false } }
        var releaser: Task<Void, Never>?
        if ending == .publicationApply {
            // O's bytes arrive and its publication begins, held at its first store unit, before v3.
            releaser = try await Self.holdPublication(of: o.transferID, s, bulk: bulk)
        }
        // v3 maps every holder to O's content.
        try await Self.applyHeld([s.q] + fillers + onO + [o] + later, tag: "v3-conv-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in ownTransfers.filter { e.state.jobs[$0] != nil }.count }
            try #require(owed == count, "setup: v3's follow owes every holder's visit: \(owed) holders left")
        }
        switch ending {
        case .notFound, .applyBetween:
            await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { $0.state.verdictsAfterFollow[o.transferID] != nil }
            } else {
                await engine.awaitCondition { $0.state.jobs[o.transferID] == nil }
            }
        case .publication:
            await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
            if visit == .sweepFollowsFirst {
                // The publication waits for the moves onto O's job.
                await engine.awaitCondition { $0.state.inboundWaits[o.transferID] != nil }
            }
        case .publicationApply:
            break
        }
        if visit == .sweepFollowsFirst, ending != .publicationApply {
            let left = await engine.readForTests { e in (owed: e.inboundOwed, moves: e.state.inboundMoves.count - e.state.inboundNext) }
            try #require(left.owed && left.moves == count - SyncEngine.inboundMovesNow, "setup: O's attempt's end made \(SyncEngine.inboundMovesNow) moves and owes the rest: \(left)")
        }
        if ending == .applyBetween || ending == .publicationApply {
            // v4 maps every holder on to Z while the follow, and (sweep-first) the moves, are still owed.
            try await Self.applyHeld([s.q] + fillers + onZ + [o] + later, tag: "v4-conv-\(seed)", s, visit: visit)
        }
        if let releaser {
            if visit == .sweepFollowsFirst {
                let left = await engine.readForTests { e in e.state.inboundMoves.count - e.state.inboundNext }
                try #require(left == count, "setup: v4's apply found a move onto the publication for every holder, all owed: \(left)")
            }
            // The publication commits.
            releaser.cancel()
            await releaser.value
            await bulk.setHolding(false)
            await engine.awaitCondition { $0.state.jobs[o.transferID] == nil }
        }
        var turns = 0
        if visit == .sweepFollowsFirst {
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns < 32, "the follow ends within 32 turns once O's attempt has ended")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let oResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: oWaiter) }
        var holders: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            holders.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        let zStarts = await s.harness.source.starts.filter { $0.id == zTransfer }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return ConvergenceOutcome(o: oResult, holders: holders, zStarts: zStarts, turns: turns)
    }

    /// 400 ids converging on one content while a follow is owed get that content's outcome, the moves the attempt's end
    /// or the apply owes made over the follow's turns (`convergence`): visited first, v3's visits had moved every holder
    /// onto O before its attempt ended.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: ids converging on one content while a follow is owed get its outcome, the moves made over the follow's turns (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, ConvergenceEnding.allCases)
    func barrierMovesConvergingIDsOverTheFollowsTurns(_ visit: LaneDropVisit, _ ending: ConvergenceEnding) async throws {
        let outcome = try await self.convergence(visit, seed: 1_818_002, ending: ending)
        let expected: Result<Int64, AssetError>
        switch ending {
        case .notFound, .applyBetween:
            #expect(outcome.o == .failure(.notFound), "O's waiter gets its 404 (visit-first): \(outcome.o)")
            expected = .failure(.notFound)
        case .publication:
            #expect((try? outcome.o.get())?.byteSize == 16, "O's waiter is served (visit-first): \(outcome.o)")
            expected = .success(16)
        case .publicationApply:
            #expect((try? outcome.o.get())?.byteSize == 16, "O's waiter is served (visit-first): \(outcome.o)")
            expected = .success(48)
        }
        let wrong = outcome.holders.enumerated().filter { $0.element.map(\.byteSize) != expected }
        #expect(wrong.isEmpty, "every holder gets \(expected) (visit-first); \(wrong.count) do not, the first \(wrong.prefix(3).map { "zz-h\($0.offset): \($0.element)" }); \(outcome.turns) follow turns")
        if ending == .applyBetween {
            #expect(outcome.zStarts == 0, "no holder reaches Z: v3's visits had put them all on O, whose 404 answered them before v4 (visit-first)")
        }
    }
}
