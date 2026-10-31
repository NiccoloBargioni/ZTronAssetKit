import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A verdict that arrived before an apply leaves the job to that verdict (Stage 3 close-out cycle 16, ruling S3-R19 item
/// 1; the cycle-15 verifiers' PROBE-C15R-VERDICT-LATER-APPLY and PROBE-C15C-VERDICT-ACROSS-APPLY). A visit-first engine
/// gave an attempt's exit verdict when it arrived, and a later apply's visit met the job as the verdict left it: nobody
/// left after an answer, a job backing off whose moved ids it moved then. Behind the barrier the verdict waits for the
/// drain, so the later apply's owed visit must pass the job (its ids moved since the verdict wait for it), and the drain
/// moves them once the verdict has left the job alive. Each test runs in both orders (`LaneDropVisit`) with the
/// visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// How C's attempt ends in `verdictBeforeApply`.
    enum VerdictBeforeApply: Sendable {
        /// A 404: every interest is answered `notFound`.
        case notFound
        /// An ENOSPC for 20 MB with 500 kB of room for C's 1 MB: C parks `insufficientSpace` and its users are answered.
        case noSpace
        /// A timeout of C's second attempt, at the interactive policy's cap of two: every user is answered.
        case retryAtCap
        /// A timeout of C's first attempt: C backs off, its users still waiting, and its retry gets a 404.
        case retry
        /// An ENOSPC for 200 kB with room for it: C backs off (`decideSpaceFailure`), its users still waiting, and its
        /// retry gets a 404.
        case spaceRetry

        /// Whether the attempt ends in an ENOSPC, whose free-space read runs a space sweep.
        var isSpace: Bool {
            self == .noSpace || self == .spaceRetry
        }
    }

    /// Whether `event` is an ENOSPC's waiting verdict.
    static func isSpaceFailure(_ event: EventAfterFollow) -> Bool {
        if case .spaceFailure = event {
            return true
        }
        return false
    }

    /// The shared scenario: C (100 kB, 1 MB for `.noSpace`; the content of zz-a and zz-b, a user waiter each) downloads.
    /// v3 changes only the fillers, so behind the barrier its follow is owed when C's attempt ends (`ending`) and the
    /// verdict waits for it. v4 then moves zz-b to N (16 bytes) while v3's follow is still owed, and the follow's visit of
    /// C, which v4's pass finds, comes after both. Visited first, C's verdict was given at its arrival, before v4 existed,
    /// and v4's visit met C as the verdict left it. Interactive retries are short (`shortInteractiveRetry`). Returns the
    /// answers of A and B.
    @available(macOS 15.0, iOS 18.0, *)
    func verdictBeforeApply(_ visit: LaneDropVisit, seed: UInt64, ending: VerdictBeforeApply) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>) {
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: ending == .noSpace ? 1_000_000 : 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let timeout = TransferError.transient(.timedOut, retryAfter: nil)
        switch ending {
        case .notFound:
            await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        case .noSpace:
            await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        case .retryAtCap:
            await s.harness.source.script(a.transferID, [.hold, .fail(timeout), .hold, .fail(timeout)])
        case .retry:
            await s.harness.source.script(a.transferID, [.hold, .fail(timeout), .fail(.permanentMissing(httpStatus: 404))])
        case .spaceRetry:
            await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        }
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        if ending == .retryAtCap {
            // C's first attempt times out before any apply: one attempt counted, nobody answered, C retries.
            await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
            }
        }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, b] + later, tag: "v3-verdict-\(seed)", s, visit: visit)
        if ending.isSpace {
            if visit == .sweepFollowsFirst {
                // The ENOSPC's free-space read runs one follow turn (`advanceFollowForSpaceSweep`); the space sweep's own
                // follow-up turns, which would run the rest of the follow and its drain before v4, are held.
                await engine.readForTests { $0.holdSpaceSweepFollowUps() }
            }
            if ending == .noSpace {
                try await Self.leaveRoom(500_000, harness: s.harness, fileSystem: s.fileSystem)
            }
            let required: Int64 = ending == .noSpace ? 20_000_000 : 200_000
            await s.harness.source.release(a.transferID, with: .failed(.insufficientSpace(requiredBytes: required)))
        } else {
            await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        }
        if visit == .sweepFollowsFirst {
            // C's verdict waits for v3's follow.
            await engine.awaitCondition { e in
                e.state.verdictsAfterFollow[a.transferID] != nil || e.state.eventsAfterFollow.contains(where: Self.isSpaceFailure)
            }
        } else {
            // Visited first, C's verdict is given at its arrival: C ends, parks or backs off before v4.
            await engine.awaitCondition { e in
                guard let job = e.state.jobs[a.transferID] else {
                    return true
                }
                switch job.state {
                case .failed(.at), .blocked:
                    return true
                case .queued, .downloading, .verifying, .committing, .failed:
                    return false
                }
            }
        }
        // v4 moves zz-b while (behind the barrier) v3's follow still owes its visits; its own later fillers keep the
        // follow owed after the apply's turn whatever turns the ENOSPC's free-space read ran.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved] + Self.laterFillers(seed + 9_000), tag: "v4-verdict-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseSpaceSweepFollowUps()
            }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (aResult, bResult)
    }

    /// A 404 that arrived before a later apply answers the ids that apply moved, as a visit-first engine's 404 answered
    /// them before the apply existed (`verdictBeforeApply`, `.notFound`; PROBE-C15R-VERDICT-LATER-APPLY,
    /// PROBE-C15C-VERDICT-ACROSS-APPLY): behind the barrier v4's owed visit met C failed with a download's verdict waiting
    /// and moved B onto N, which served B.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a 404 that waits for an owed follow answers an id a later apply moved, as at its arrival (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAnIdALaterApplyMovedWithAWaiting404(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.verdictBeforeApply(visit, seed: 1_515_302, ending: .notFound)
        #expect(aResult == .failure(.notFound), "A gets C's 404 (visit-first): \(aResult)")
        #expect(bResult == .failure(.notFound), "B gets C's 404, answered before v4 existed (visit-first): \(bResult)")
    }

    /// An ENOSPC whose verdict parks the job answers the ids a later apply moved, as a visit-first engine's verdict
    /// answered them before the apply existed (`verdictBeforeApply`, `.noSpace`): the verdict waits as `.spaceFailure`,
    /// and behind the barrier v4's owed visit moved B onto N, which served B.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an ENOSPC verdict that waits for an owed follow answers an id a later apply moved, as at its arrival (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAnIdALaterApplyMovedWithAWaitingSpaceVerdict(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.verdictBeforeApply(visit, seed: 1_616_002, ending: .noSpace)
        guard case .failure(.insufficientSpace) = aResult else {
            Issue.record("A gets C's insufficientSpace (visit-first): \(aResult)")
            return
        }
        guard case .failure(.insufficientSpace) = bResult else {
            Issue.record("B gets C's insufficientSpace, answered before v4 existed (visit-first): \(bResult)")
            return
        }
    }

    /// A retry at the cap that arrived before a later apply answers the ids that apply moved, as a visit-first engine's
    /// verdict answered them before the apply existed (`verdictBeforeApply`, `.retryAtCap`): behind the barrier v4's owed
    /// visit met C failed with a download's verdict waiting and moved B onto N, which served B.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a retry at the cap that waits for an owed follow answers an id a later apply moved, as at its arrival (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAnIdALaterApplyMovedWithAWaitingRetryAtTheCap(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.verdictBeforeApply(visit, seed: 1_616_102, ending: .retryAtCap)
        #expect(aResult == .failure(.serverUnavailable(retryAfter: nil)), "A gets C's timeout at the cap (visit-first): \(aResult)")
        #expect(bResult == .failure(.serverUnavailable(retryAfter: nil)), "B gets C's timeout at the cap, answered before v4 existed (visit-first): \(bResult)")
    }

    /// A retry that arrived before a later apply leaves the job alive, and the ids that apply moved move from it once the
    /// verdict is given, as a visit-first engine's visit at that apply moved them from the job backing off
    /// (`verdictBeforeApply`, `.retry`; `followAfterVerdict`): behind the barrier v4's owed visit passed C to its waiting
    /// verdict, and the drain moved B onto N after it. N served B, and C's retry got a 404, which answered A alone; left on
    /// C, B would have ridden that retry and been answered its 404.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a retry that waits for an owed follow moves a later apply's id once it is given (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierMovesALaterApplysIdFromAJobItsWaitingRetryLeft(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.verdictBeforeApply(visit, seed: 1_616_202, ending: .retry)
        #expect(aResult == .failure(.notFound), "A gets the 404 of C's retry (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N: v4's visit moved it from C backing off (visit-first): \(bResult)")
    }

    /// As above, with an ENOSPC the volume has room for (`verdictBeforeApply`, `.spaceRetry`): its verdict waits as
    /// `.spaceFailure` and backs C off when the drain gives it (`decideSpaceFailure`), and the drain then moves B onto N.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an ENOSPC retry that waits for an owed follow moves a later apply's id once it is given (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierMovesALaterApplysIdFromAJobItsWaitingSpaceRetryLeft(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.verdictBeforeApply(visit, seed: 1_616_902, ending: .spaceRetry)
        #expect(aResult == .failure(.notFound), "A gets the 404 of C's retry (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N: v4's visit moved it from C backing off (visit-first): \(bResult)")
    }

    /// A job whose attempt failed before its owed visit, every id of which an apply had moved before the failure, is
    /// superseded by that visit, as a visit-first engine's visit at the apply superseded it while it downloaded (the
    /// visit re-routes them all, `Job.rerouteOnPass` from `recordDeferredVerdict`): C (100 kB, zz-a and zz-b, a user
    /// waiter each) downloads; v3 moves both ids to N (16 bytes) while, behind the barrier, its follow owes C's visit, and
    /// C's attempt first ends in a cancel the engine did not ask for (`.cancelled(.byClient)`: a fresh attempt at once,
    /// `AttemptVerdict.requeue`, which waits). Both users are served N, and C's content is never asked for again: no
    /// attempt runs for a job nobody holds.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: an owed visit supersedes a failed job whose every id an apply moved before its failure (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierSupersedesAFailedJobEveryIdOfWhichMovedBeforeItsFailure(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_616_702
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID && aMoved.transferID == bMoved.transferID, "setup: zz-a and zz-b share C, then N")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.cancelled(.byClient)), .stage(cBytes)])
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [aMoved, bMoved] + Self.laterFillers(seed + 6_000), tag: "v3-supersede-\(seed)", s, visit: visit)
        // C's attempt ends in a cancel the engine did not ask for: behind the barrier, before C's owed visit.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            let waiting = await engine.readForTests { e in (owed: e.followOwed, reroute: e.state.jobs[a.transferID]?.rerouteOnPass) }
            #expect(waiting.owed && waiting.reroute == [a.identifier, b.identifier], "setup: C's verdict waits with both ids moved before it: \(waiting)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A is served N (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N (visit-first): \(bResult)")
        // A fresh attempt of C, had it run for nobody, starts C's content again.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { !$0.followBarrier && $0.state.jobs[a.transferID] == nil }
        }
        let starts = await s.harness.source.starts.filter { $0.id == a.transferID }.count
        #expect(starts == 1, "C's content is asked for once: C was superseded, not re-queued (visit-first): \(starts)")
        await Self.finishHeld(s)
    }
}
