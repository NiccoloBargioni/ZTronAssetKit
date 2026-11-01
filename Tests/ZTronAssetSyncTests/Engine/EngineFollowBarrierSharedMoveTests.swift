import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// One visit, or one owed move, that carries more ids than a follow turn moves (Stage 3 close-out cycle 19, ruling
/// S3-R22 item 1; the cycle-18 verifiers' VERIFY-C18R-SHARED-CONVERGENCE, -SHARED-DIVERGENCE and -DIVERGENCE): members
/// of one prefetch group share one content, and an apply maps them all to another content, or each to one of its own.
/// The visit moves at most `followIDsPerTurn` ids a turn and the follow's next turns make the rest before any other
/// visit, and an attempt's end moves at most `inboundIDsNow` of an owed move's ids in its own turn (`startMove`,
/// `continueMove`). The bound is set small (`EngineState.followIDsPerTurn`, S3-R23 item 3), so ten members span turns.
/// Each case runs in both orders (`LaneDropVisit`) with the visit-first answers expected in both; sweep-first, the
/// follow's turns run one at a time and each turn's moved ids are counted.
extension EngineFollowBarrierTests {
    /// The members sharing one content.
    static let sharedMembers = 10

    /// The ids a follow turn moves in these tests: ten members take three visit turns.
    static let sharedIDsPerTurn = 4

    /// What `sharedMove` maps and when O's attempt ends.
    enum SharedMoveShape: Sendable, CaseIterable {
        /// v3 maps every member of H to O's content; O's bytes arrive once the follow ended.
        case convergence
        /// As `convergence`, but O's bytes arrive while H's visit still owes the members it has not moved (sweep-first):
        /// O's publication finds them (`bringInbound`) and waits until they are moved onto it, and the owed move that
        /// carries them takes H's last ids, so the visit's rest finds H gone.
        case convergenceEnds
        /// As `convergenceEnds`, then v4 (v3 with its later fillers changed) lands while that move still carries members
        /// (sweep-first): v4's walk finds O's publication (`bringInboundOntoPublications`) and records no move for the ids
        /// the owed move still carries (`findInbound`); visited first v4 lands once O's attempt ended.
        case convergenceApplies
        /// The members share O's content with zz-o, and v3 gives each a content of its own; O's bytes arrive once the
        /// follow ended.
        case divergence
        /// As `divergence`, but O's bytes arrive while O's visit still owes members it has not moved (sweep-first): O's
        /// publication waits for the visit's rest and binds zz-o alone.
        case divergencePublishes
        /// v3 maps every member of H to O's content; O's attempt ends in a 404 while H's visit is owed (sweep-first), so
        /// the attempt's end finds one move of all ten members, makes `inboundIDsNow` of them, and the follow's turns
        /// make the rest.
        case attemptEnd
        /// As `convergence`, with zz-t (a prefetch waiter) on a content of its own that v3 changes: the pass finds its job
        /// after H's, in the turn H's visit leaves its rest, and its visit waits until the rest is moved and the turn
        /// still has ids (a turn whose ids are spent visits no job).
        case convergenceBystander

        /// Whether the members leave one job for O's.
        var converges: Bool {
            self != .divergence && self != .divergencePublishes
        }
    }

    /// What `sharedMove` reads: the answers of O's waiter and of each member's, the ids each sweep-first turn moved off
    /// the members' job, and that job's starts and cancellations.
    struct SharedMoveOutcome {
        /// O's waiter's answer.
        let o: Result<AssetLocation, AssetError>
        /// Each member's waiter's answer, in member order.
        let members: [Result<AssetLocation, AssetError>]
        /// The members moved off their job by each turn (sweep-first; empty visited first): the follow's turns, and O's
        /// attempt's end turn where it moves some.
        let turns: [Int]
        /// The attempt's-end turn's share of `turns` (`.convergenceEnds`, `.attemptEnd`), if any.
        let endTurn: Int?
        /// The starts of the members' first job's transfer.
        let holderStarts: Int
        /// The cancellations the origin recorded for that transfer once the follow ended, before the shutdown.
        var holderCancels = 0
        /// The ids of each move off the members' job O's attempt's end owed (sweep-first `.attemptEnd`,
        /// `.convergenceEnds`), and the members on that job when it ended.
        var moveSizes: [Int] = []
        /// The members on their job when O's attempt ended (sweep-first `.attemptEnd`, `.convergenceEnds`).
        var leftAtEnd: Int?
        /// The ids of each move off the members' job owed once v4 landed (sweep-first `.convergenceApplies`).
        var movesAfterApply: [Int]?
        /// The members the owed moves name as carried (`inboundPendingIDs`) right after O's attempt's end turn
        /// (sweep-first `.attemptEnd`, `.convergenceEnds`, `.convergenceApplies`).
        var pendingAtEnd: Int?
        /// zz-t's waiter's answer (`.convergenceBystander`).
        var bystander: Result<AssetLocation, AssetError>?
    }

    /// The members still on the job they share before v3 (`H` converging, `O` diverging).
    @available(macOS 15.0, iOS 18.0, *)
    static func membersLeft(_ engine: SyncEngine, on transfer: TransferID, members: [AssetID]) async -> Int {
        await engine.readForTests { e in
            guard let job = e.state.jobs[transfer] else {
                return 0
            }
            return members.filter { job.assets.contains($0) }.count
        }
    }

    /// Ten members (zz-s00…, a prefetch waiter each) share one content, and O (zz-o, a user waiter) downloads, held.
    /// Converging, the members share H (16 bytes) and v3 maps them to O's content (24 bytes); diverging, they share O's
    /// content and v3 gives each one of its own (16 bytes). Visited first, v3's visit moved every member at the apply, and
    /// O's attempt ended after it.
    /// With `shutdown`, the engine shuts down once O's attempt ended: sweep-first while O's publication waits for the
    /// owed moves or the visit's rest, visited first right after O's release; the answers are read after it.
    @available(macOS 15.0, iOS 18.0, *)
    func sharedMove(_ visit: LaneDropVisit, seed: UInt64, shape: SharedMoveShape, shutdown: Bool = false) async throws -> SharedMoveOutcome {
        let count = Self.sharedMembers
        let (s, _) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.sharedIDsPerTurn }
        let oBytes = EngineFixture.bytes(seed + 3, count: 24)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let names = (0..<count).map { String(format: "zz-s%02d", $0) }
        let ownBytes = (0..<count).map { EngineFixture.bytes(seed + 10_000 + UInt64($0), count: 16) }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let onO = names.map { EngineHarness.onDemand($0, oBytes) }
        let own = names.enumerated().map { EngineHarness.onDemand($0.element, ownBytes[$0.offset]) }
        let tOld = EngineHarness.onDemand("zz-t", EngineFixture.bytes(seed + 5, count: 12))
        let tNewBytes = EngineFixture.bytes(seed + 6, count: 20)
        let tNew = EngineHarness.onDemand("zz-t", tNewBytes)
        let bystanderOn = shape == .convergenceBystander
        let before = (shape.converges ? onH : onO) + (bystanderOn ? [tOld] : [])
        let after = (shape.converges ? onO : own) + (bystanderOn ? [tNew] : [])
        let holder = try #require(before.first?.transferID)
        try #require(Set(before.prefix(count).map(\.transferID)).count == 1 && (holder == o.transferID) == !shape.converges, "setup: the members share one content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + before + [o] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        if shape == .attemptEnd {
            await s.harness.source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        } else {
            await s.harness.source.script(o.transferID, [.hold, .stage(oBytes)])
        }
        if bystanderOn {
            await s.harness.source.script(tNew.transferID, [.stage(tNewBytes)])
        }
        if shape.converges {
            await s.harness.source.script(holder, [.hold, .stage(hBytes)])
        } else {
            for (entry, bytes) in zip(own, ownBytes) {
                await s.harness.source.script(entry.transferID, [.stage(bytes)])
            }
        }
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for member in before.prefix(count) {
            let id = member.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        let interests = shape.converges ? count : count + 1
        await engine.awaitCondition { $0.state.jobs[holder]?.interests.count == interests }
        var tWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        if bystanderOn {
            tWaiter = Task { await engine.awaitAsset(tOld.identifier, lane: .prefetch) }
            await engine.awaitCondition { $0.state.jobs[tOld.transferID]?.interests.isEmpty == false }
        }
        let ids = before.prefix(count).map(\.identifier)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + after + [o] + Self.laterFillers(seed + 6_000), tag: "v3-shared-\(seed)", s, visit: visit)
        var turns: [Int] = []
        var endTurn: Int?
        var moveSizes: [Int] = []
        var leftAtEnd: Int?
        var movesAfterApply: [Int]?
        var pendingAtEnd: Int?
        // The members an owed move names as carried, for the ids it has left (`inboundPendingIDs`).
        let pendingOf: @Sendable (isolated SyncEngine) -> Int = { e in
            let pending = e.inboundPendingIDs()
            return ids.filter { pending[$0] != nil }.count
        }
        // v3 with its later fillers changed: no member's entry or O's changes.
        let v4 = [s.q] + FollowBarrier.fillers(seed + 200) + after + [o] + Self.laterFillers(seed + 9_000)
        // The moves off the members' job that O's attempt's end owes, by their ids.
        let owedOff: @Sendable (isolated SyncEngine) -> [Int] = { e in
            e.state.inboundMoves[e.state.inboundNext...].filter { $0.holder == holder }.map(\.ids.count)
        }
        if visit == .sweepFollowsFirst {
            // The follow's scans reach the members' entries in its first follow-up turn, which visits their job.
            var left = await Self.membersLeft(engine, on: holder, members: ids)
            try #require(left == count, "setup: no member moved before the follow's turns: \(left)")
            if shape == .attemptEnd {
                // O's 404 arrives before H's visit: its verdict waits, and its attempt's end makes the first moves.
                leftAtEnd = left
                await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
                await engine.awaitCondition { $0.state.verdictsAfterFollow[o.transferID] != nil }
                moveSizes = await engine.readForTests(owedOff)
                pendingAtEnd = await engine.readForTests(pendingOf)
                let now = await Self.membersLeft(engine, on: holder, members: ids)
                endTurn = left - now
                turns.append(left - now)
                left = now
            }
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns.count < 16, "the follow ends within 16 turns: \(turns)")
                await Self.runOneFollowTurn(engine)
                let now = await Self.membersLeft(engine, on: holder, members: ids)
                turns.append(left - now)
                left = now
                let resting = await engine.readForTests { $0.state.followMoving?.holder == holder }
                if resting, endTurn == nil, shape == .convergenceEnds || shape == .convergenceApplies || shape == .divergencePublishes {
                    // O's bytes arrive while the visit still owes members: O's publication waits.
                    leftAtEnd = left
                    await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
                    await engine.awaitCondition { $0.state.inboundWaits[o.transferID] != nil }
                    moveSizes = await engine.readForTests(owedOff)
                    pendingAtEnd = await engine.readForTests(pendingOf)
                    let ended = await Self.membersLeft(engine, on: holder, members: ids)
                    endTurn = left - ended
                    turns.append(left - ended)
                    left = ended
                    if shape == .convergenceApplies {
                        // v4 lands while the owed move still carries members and O's publication waits for it.
                        let carried = await engine.readForTests { e in
                            e.state.inboundMoves[e.state.inboundNext...].first { $0.holder == holder }?.progress?.heap.count ?? 0
                        }
                        try #require(carried > 0 && left > 0, "setup: the owed move still carries members when v4 lands: \(carried), \(left) on H")
                        try await Self.applyHeld(v4, tag: "v4-shared-\(seed)", s, visit: visit)
                        movesAfterApply = await engine.readForTests(owedOff)
                    }
                    if shutdown {
                        let violations = await engine.invariantViolations()
                        #expect(violations.isEmpty, "while O's publication waits: \(violations.prefix(3))")
                        // Shutdown resumes the waiting publication (`releaseInboundWaits`) and completes.
                        await engine.shutdown()
                        return try await Self.sharedAnswers(o: oWaiter, members: waiters, s, turns: turns, endTurn: endTurn, holder: holder)
                    }
                }
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
            let waits = await engine.readForTests { $0.state.inboundWaits.count }
            try #require(waits == 0, "no publication still waits once the follow ended: \(waits)")
        }
        if endTurn == nil {
            // O's attempt ends after the follow (visit-first in every shape).
            await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
            if shutdown {
                await engine.shutdown()
                return try await Self.sharedAnswers(o: oWaiter, members: waiters, s, turns: turns, endTurn: endTurn, holder: holder)
            }
            if shape == .convergenceApplies {
                try await Self.applyHeld(v4, tag: "v4-shared-\(seed)", s, visit: visit)
            }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let oResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: oWaiter) }
        var members: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            members.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        var tResult: Result<AssetLocation, AssetError>?
        if let tWaiter {
            tResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: tWaiter) }
        }
        let holderStarts = await s.harness.source.starts.filter { $0.id == holder }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let holderCancels = await s.harness.source.controlLog.filter { $0.transfer == holder && $0.control == .cancel }.count
        await Self.finishHeld(s)
        return SharedMoveOutcome(o: oResult, members: members, turns: turns, endTurn: endTurn, holderStarts: holderStarts, holderCancels: holderCancels, moveSizes: moveSizes, leftAtEnd: leftAtEnd, movesAfterApply: movesAfterApply, pendingAtEnd: pendingAtEnd, bystander: tResult)
    }

    /// The answers once the engine shut down (`sharedMove(_:seed:shape:shutdown:)`).
    @available(macOS 15.0, iOS 18.0, *)
    static func sharedAnswers(o: Task<Result<AssetLocation, AssetError>, Never>, members waiters: [Task<Result<AssetLocation, AssetError>, Never>], _ s: FollowBarrier.Setup, turns: [Int], endTurn: Int?, holder: TransferID) async throws -> SharedMoveOutcome {
        let oResult = await EngineHarness.value(of: o)
        var members: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            members.append(await EngineHarness.value(of: waiter))
        }
        let holderStarts = await s.harness.source.starts.filter { $0.id == holder }.count
        return SharedMoveOutcome(o: oResult, members: members, turns: turns, endTurn: endTurn, holderStarts: holderStarts)
    }

    /// A visit or an owed move of more ids than a turn moves makes them over the follow's turns, at most
    /// `followIDsPerTurn` a turn and `inboundIDsNow` in an attempt's end turn, and every member gets the visit-first
    /// answer: O's outcome converging, its own content's bytes diverging. An apply's walk while the owed move still
    /// carries members owes no second move of them (`.convergenceApplies`): each id an owed move carries is owed once,
    /// so the follow's turns do not walk it again and `inboundPendingIDs` names the one move that carries it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a visit or an owed move of more ids than a follow turn moves makes them over the follow's turns, at most followIDsPerTurn a turn, with the visit-first answers (C2, F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, SharedMoveShape.allCases)
    func barrierMovesASharedContentsIDsOverBoundedTurns(_ visit: LaneDropVisit, _ shape: SharedMoveShape) async throws {
        let outcome = try await self.sharedMove(visit, seed: 1_919_102, shape: shape)
        let expected: Result<Int64, AssetError>
        switch shape {
        case .attemptEnd:
            #expect(outcome.o == .failure(.notFound), "O's waiter gets its 404: \(outcome.o)")
            expected = .failure(.notFound)
        case .convergence, .convergenceEnds, .convergenceApplies, .convergenceBystander:
            #expect((try? outcome.o.get())?.byteSize == 24, "O's waiter is served: \(outcome.o)")
            expected = .success(24)
        case .divergence, .divergencePublishes:
            #expect((try? outcome.o.get())?.byteSize == 24, "O's waiter is served: \(outcome.o)")
            expected = .success(16)
        }
        let wrong = outcome.members.enumerated().filter { $0.element.map(\.byteSize) != expected }
        #expect(wrong.isEmpty, "every member gets \(expected) (visit-first); \(wrong.count) do not: \(wrong.prefix(3).map { "zz-s\($0.offset): \($0.element)" }); turns \(outcome.turns)")
        if shape.converges {
            #expect(outcome.holderStarts == 1, "the members' first job starts once, its attempt abandoned or ended by the move: \(outcome.holderStarts)")
            // The move that takes H's every id supersedes H: its running attempt is cancelled at the move's first turn,
            // as v3's visit on a visit-first engine cancelled it, not left running once its job is removed.
            #expect(outcome.holderCancels == 1, "the members' first job's attempt is cancelled once, when the move off it began: \(outcome.holderCancels)")
        }
        if shape == .convergenceBystander {
            // v3's visit moved zz-t to its new content (visit-first): its visit waited for H's rest, and no rest was lost.
            #expect((try? outcome.bystander?.get())?.byteSize == 20, "zz-t's waiter gets its new content: \(String(describing: outcome.bystander))")
        }
        guard visit == .sweepFollowsFirst else {
            return
        }
        #expect(outcome.turns.reduce(0, +) == Self.sharedMembers, "every member left its job over the turns: \(outcome.turns)")
        #expect(outcome.turns.allSatisfy { $0 <= Self.sharedIDsPerTurn }, "no turn moves more than followIDsPerTurn = \(Self.sharedIDsPerTurn) ids: \(outcome.turns)")
        #expect(outcome.turns.contains(Self.sharedIDsPerTurn), "a turn moves the bound's worth: \(outcome.turns)")
        if let end = outcome.endTurn, shape == .attemptEnd || shape == .convergenceEnds || shape == .convergenceApplies {
            let now = Self.sharedIDsPerTurn / 2
            #expect(end >= 1 && end <= now, "O's attempt's end moves at least one id and at most inboundIDsNow = \(now): \(end); turns \(outcome.turns)")
        }
        if shape == .divergencePublishes {
            #expect(outcome.endTurn == 0, "O's publication moves no member: it waits for the visit's rest: \(outcome.turns)")
        }
        if shape == .attemptEnd || shape == .convergenceEnds || shape == .convergenceApplies {
            #expect(outcome.moveSizes == [outcome.leftAtEnd ?? -1], "O's attempt's end owes one move off H carrying every member still on it (\(String(describing: outcome.leftAtEnd))), no id twice: \(outcome.moveSizes)")
        }
        if shape == .attemptEnd || shape == .convergenceEnds || shape == .convergenceApplies {
            let left = (outcome.leftAtEnd ?? 0) - (outcome.endTurn ?? 0)
            #expect(outcome.pendingAtEnd == left, "after O's attempt's end the owed move names as carried the members it has left, \(left): \(String(describing: outcome.pendingAtEnd))")
        }
        if shape == .convergenceApplies {
            #expect(outcome.movesAfterApply == outcome.moveSizes, "v4's walk records no move for the members the owed move still carries: \(String(describing: outcome.movesAfterApply)), owed before v4 \(outcome.moveSizes)")
        }
    }

    /// Shutdown while O's publication waits (sweep-first), for the owed move of H's last members onto O or for the rest
    /// of O's own visit, resumes the wait and completes, and every waiter is answered `shutDown`; visited first it shuts
    /// down right after O's release, and every waiter gets its content or `shutDown`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: shutdown while a publication waits for an owed move or a visit's rest completes and answers every waiter (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [SharedMoveShape.convergenceEnds, .divergencePublishes])
    func barrierShutsDownWhileAPublicationWaitsForOwedMoves(_ visit: LaneDropVisit, _ shape: SharedMoveShape) async throws {
        let outcome = try await self.sharedMove(visit, seed: 1_919_302, shape: shape, shutdown: true)
        let answers = [outcome.o] + outcome.members
        if visit == .sweepFollowsFirst {
            #expect(outcome.endTurn != nil, "setup: O's publication waited when the engine shut down: \(outcome.turns)")
            let wrong = answers.filter { $0 != .failure(.shutDown) }
            #expect(wrong.isEmpty, "the shutdown answers O's waiter and every member: \(wrong.prefix(3))")
        } else {
            let wrong = answers.filter { result in
                switch result {
                case .success, .failure(.shutDown):
                    return false
                case .failure:
                    return true
                }
            }
            #expect(wrong.isEmpty, "every waiter gets its content or the shutdown: \(wrong.prefix(3))")
        }
    }

    // MARK: The drain's visit after a verdict

    /// What `drainRemainder` reads: the answers of C's, N's and each member's waiter, and N's starts.
    struct DrainRemainderOutcome {
        /// C's waiter's answer.
        let c: Result<AssetLocation, AssetError>
        /// N's waiter's answer.
        let n: Result<AssetLocation, AssetError>
        /// Each member's waiter's answer, in member order.
        let members: [Result<AssetLocation, AssetError>]
        /// The starts of N's transfer.
        let nStarts: Int
        /// The members moved off C by each follow turn (sweep-first; empty visited first): the drain's visit in the
        /// follow's last turn, then the turns of its rest.
        let turns: [Int]
    }

    /// C (100 kB; zz-c, a user waiter, and ten members zz-s00…, a prefetch waiter each) and N (16 bytes; zz-n, a user
    /// waiter) download, held. v3 changes only the fillers, so behind the barrier its follow is owed when C's first
    /// attempt times out and C's verdict waits. v4 maps every member to N's content; its follow passes C, whose verdict
    /// waits, so the drain moves the members after it (`followAfterVerdict`), more than a turn moves. N's attempt then
    /// ends in a 404 whose verdict waits behind C's. Visited first, C backed off at its timeout, v4's visit moved every
    /// member onto N, and N's 404 answered N's waiter and every member; C's retry served zz-c. The drain's visit moves
    /// four members in its turn and the follow's turns the rest, and N's verdict waits for them; sweep-first, the follow's
    /// turns run one at a time and each turn's moved members are counted.
    @available(macOS 15.0, iOS 18.0, *)
    func drainRemainder(_ visit: LaneDropVisit, seed: UInt64) async throws -> DrainRemainderOutcome {
        let count = Self.sharedMembers
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.sharedIDsPerTurn }
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let n = EngineHarness.onDemand("zz-n", nBytes)
        let names = (0..<count).map { String(format: "zz-s%02d", $0) }
        let onC = names.map { EngineHarness.onDemand($0, cBytes) }
        let onN = names.map { EngineHarness.onDemand($0, nBytes) }
        try #require(onC.allSatisfy { $0.transferID == c.transferID } && onN.allSatisfy { $0.transferID == n.transferID }, "setup: the members share C, then N")
        let fillers = FollowBarrier.fillers(seed + 200)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [c] + onC + [n] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(c.transferID, [.hold, .fail(.transient(.timedOut, retryAfter: nil)), .stage(cBytes)])
        await s.harness.source.script(n.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(nBytes)])
        let cWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[c.transferID]?.state == .downloading }
        }
        let nWaiter = Task { await engine.awaitAsset(n.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[n.transferID]?.state == .downloading }
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for member in onC {
            let id = member.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        await engine.awaitCondition { $0.state.jobs[c.transferID]?.interests.count == count + 1 }
        try await Self.applyHeld([s.q] + fillers + [c] + onC + [n] + Self.laterFillers(seed + 6_000), tag: "v3-drain-rest-\(seed)", s, visit: visit)
        await s.harness.source.release(c.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[c.transferID] != nil }
        } else {
            await engine.awaitCondition { e in
                guard let job = e.state.jobs[c.transferID] else {
                    return false
                }
                if case .failed(.at) = job.state {
                    return true
                }
                return false
            }
        }
        try await Self.applyHeld([s.q] + fillers + [c] + onN + [n] + Self.laterFillers(seed + 9_000), tag: "v4-drain-rest-\(seed)", s, visit: visit)
        await s.harness.source.release(n.transferID, with: .progress(received: 0, expected: nil))
        var turns: [Int] = []
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[n.transferID] != nil }
            let left = await engine.readForTests { e in e.state.jobs[c.transferID]?.assets.count }
            try #require(left == count + 1, "setup: every member is still on C's job while both verdicts wait: \(String(describing: left))")
            // The follow's turns one at a time: its last turn's drain replays C's verdict and moves the members after it,
            // and the turns of the visit's rest follow (`drainEventsAfterFollow`).
            let ids = Set(onC.map(\.identifier))
            var before = count
            while await engine.readForTests({ $0.followOwed }) {
                await Self.runOneFollowTurn(engine)
                let now = await engine.readForTests { e in e.state.jobs[c.transferID]?.assets.intersection(ids).count ?? 0 }
                if now != before {
                    turns.append(before - now)
                }
                before = now
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await engine.awaitCondition { $0.state.jobs[n.transferID] == nil }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let cResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: cWaiter) }
        let nResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: nWaiter) }
        var members: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            members.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        let nStarts = await s.harness.source.starts.filter { $0.id == n.transferID }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return DrainRemainderOutcome(c: cResult, n: nResult, members: members, nStarts: nStarts, turns: turns)
    }

    /// The drain's visit after a verdict that moves more ids than a turn moves holds the events after it until its last
    /// id moved (`drainEventsAfterFollow`): N's 404, which arrived after v4, answers every member, as a visit-first
    /// engine's v4 visit had put them all on N before it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the drain's visit after a verdict that moves more ids than a turn moves makes them all before the next waiting event (C2, F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDrainsTheEventsAfterAVisitsRest(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.drainRemainder(visit, seed: 1_919_202)
        #expect((try? outcome.c.get())?.byteSize == 100_000, "C's retry serves zz-c: \(outcome.c)")
        #expect(outcome.n == .failure(.notFound), "N's waiter gets its 404: \(outcome.n)")
        let wrong = outcome.members.enumerated().filter { $0.element != .failure(.notFound) }
        #expect(wrong.isEmpty, "N's 404 answers every member (visit-first); \(wrong.count) do not: \(wrong.prefix(3).map { "zz-s\($0.offset): \($0.element)" })")
        #expect(outcome.nStarts == 1, "N starts once: no member reaches a later job of its content: \(outcome.nStarts)")
        guard visit == .sweepFollowsFirst else {
            return
        }
        // C2: the drain's visit moves at most a turn's ids (`followAfterVerdict`), and the follow's next turns the rest.
        let bound = Self.sharedIDsPerTurn
        #expect(outcome.turns.reduce(0, +) == Self.sharedMembers && outcome.turns.allSatisfy { $0 <= bound } && outcome.turns.count >= 3, "the members leave C at most \(bound) a turn, over the follow's turns: \(outcome.turns)")
    }
}
