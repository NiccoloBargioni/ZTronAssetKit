import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// An ENOSPC of a publication whose free-space read runs a follow turn that joins an id onto the job (Stage 3 close-out
/// cycle 21, ruling S3-R26 item 5, probe (i); `analyse-g4-reach.md`'s Shape B, the T20 window): the publication's end
/// is recorded before the read (`recordPublicationEnd`), the verdict defers only after it (`spaceFailed`), and the
/// read's turn runs one follow turn behind the barrier (`advanceFollowForSpaceSweep`), whose join re-lanes the job. A
/// visit-first engine's visit had joined the id to the job publishing, whose re-lane re-queues nothing (`relane`), so
/// the ENOSPC's verdict stood: at an interactive cap of one attempt it answers every interest with the space figures
/// and ends the job. A transfer's ENOSPC opens the same window before its reads (the second test). Each test runs in
/// both orders and expects the visit-first answers in both; the last one is the window's other side, a visit for an
/// apply made after the end, and `EngineRunPathTests` holds the request outside any follow
/// (`userSkipsAFailedPublicationsBackoff`).
extension EngineFollowBarrierTests {
    /// Whether `result` is the ENOSPC verdict's answer, the space figures.
    static func isNoSpace(_ result: Result<AssetLocation, AssetError>) -> Bool {
        if case .failure(.insufficientSpace) = result {
            return true
        }
        return false
    }

    /// T (zz-a, 100 kB) downloads for A, a user waiter, and zz-x waits on H (16 bytes, held) for X, a user waiter; T's
    /// publication is held at its first store unit, and v3 maps zz-x to T's content. `walked`: v3b, which changes only the
    /// leading fillers, applies too, and swept first its walk under v3's copy owes the move H → T [zz-x]
    /// (`bringInboundOntoPublications`), which the follow's next turn makes; unwalked, that turn's pass reaches zz-x (the
    /// fillers take the apply's own turn) and H's visit moves it. Visited first, v3's visit moved zz-x onto T publishing.
    /// The interactive cap is one attempt; T's content serves its bytes on every request after the first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an ENOSPC whose free-space read runs the follow's join onto its job gives its verdict at the attempt cap, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [false, true])
    func barrierGivesAnENOSPCsVerdictAtTheCapAfterTheFollowsJoinInItsRead(_ visit: LaneDropVisit, _ walked: Bool) async throws {
        let seed: UInt64 = walked ? 2_028_711 : 2_028_701
        var interactive = RetryPolicy.interactive
        interactive.maxAttemptsPerRun = 1
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: interactive))
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let a = EngineHarness.onDemand("zz-a", tBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xOnT = EngineHarness.onDemand("zz-x", tBytes)
        try #require(xOnT.transferID == a.transferID && x.transferID != a.transferID, "setup: v3 maps zz-x from H to T")
        let tID = a.transferID
        let h = x.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, x] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(tID, [.hold, .stage(tBytes), .stage(tBytes)])
        await s.harness.source.script(h, [.hold, .stage(hBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[tID]?.state == .downloading }
        }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h]?.state == .downloading }
        }
        let releaser = try await Self.holdPublication(of: tID, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v3-space-read-\(seed)", s, visit: visit)
        if walked {
            try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v3b-space-read-\(seed)", s, visit: visit)
        }
        let move = await engine.readForTests { Self.owedMove($0, from: h, onto: tID)?.ids }
        if visit == .sweepFollowsFirst && walked {
            try #require(move == [x.identifier], "setup: v3b's walk under v3's copy owes H → T [zz-x]: \(String(describing: move))")
        } else {
            try #require(move == nil, "setup: no move is owed onto T (visited first v3's visit moved zz-x onto T publishing; unwalked, H waits for its visit): \(String(describing: move))")
        }
        // T's placement rename fails ENOSPC; swept first its free-space read runs one follow turn, and the space sweep's
        // own follow-up turns are held.
        s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .noSpace))
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.holdSpaceSweepFollowUps() }
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.eventsAfterFollow.contains(where: Self.isSpaceFailure) }
            let read = await engine.readForTests { e in
                (t: e.state.jobs[tID]?.assets.sorted(), h: e.state.jobs[h] != nil, owed: e.followOwed, state: e.state.jobs[tID]?.state)
            }
            try #require(read.t == [a.identifier, x.identifier] && !read.h && read.owed, "setup: the read's follow turn joined zz-x to T (H, its only id moved, is gone), and the verdict waits behind the owed follow: \(read)")
            let failed = read.state.map { state -> Bool in
                if case .failed = state {
                    return true
                }
                return false
            }
            #expect(failed == true, "the follow's join met T as its attempt left it, its verdict to come, and re-queued nothing (visit-first: the join met T publishing): \(String(describing: read.state))")
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseSpaceSweepFollowUps()
            }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        let tStarts = await s.harness.source.starts.filter { $0.id == tID }.count
        #expect(Self.isNoSpace(aResult), "the ENOSPC's verdict answers A at its cap with the space figures (visit-first): \(aResult)")
        #expect(xResult == aResult, "and X, which v3's visit joined to T publishing, with the same figures (visit-first): \(xResult)")
        #expect(tStarts == 1, "T's content is not requested past the interactive cap (R-SYN-5; visit-first): \(tStarts)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    /// A transfer's ENOSPC has the same window (`analyse-g4-reach.md` (c), UNCONFIRMED there): its exit sets the job
    /// `failed(.nextRun)` before its awaits, the resume point's and the free-space read's, and its verdict defers only
    /// after them (`spaceFailed`), and the read runs one follow turn behind the barrier. T (zz-a, 100 kB) downloads for
    /// A, a user waiter, and zz-x waits on H (16 bytes, held) for X, a user waiter; v3 maps zz-x to T's content while T
    /// downloads, and T's transfer then fails ENOSPC. Visited first, v3's visit joined zz-x to T downloading, whose re-lane
    /// re-queues nothing, and at an interactive cap of one attempt the verdict answered A and X with the space figures.
    /// Swept first, the read's turn moves zz-x off H onto T.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a transfer's ENOSPC whose free-space read runs the follow's join onto its job gives its verdict at the attempt cap, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGivesATransferENOSPCsVerdictAtTheCapAfterTheFollowsJoinInItsRead(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_028_901
        var interactive = RetryPolicy.interactive
        interactive.maxAttemptsPerRun = 1
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(interactiveRetry: interactive))
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let a = EngineHarness.onDemand("zz-a", tBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xOnT = EngineHarness.onDemand("zz-x", tBytes)
        try #require(xOnT.transferID == a.transferID && x.transferID != a.transferID, "setup: v3 maps zz-x from H to T")
        let tID = a.transferID
        let h = x.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, x] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(tID, [.hold, .fail(.insufficientSpace(requiredBytes: Int64(tBytes.count))), .stage(tBytes)])
        await s.harness.source.script(h, [.hold, .stage(hBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[tID]?.state == .downloading }
        }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v3-transfer-space-read-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in (h: e.state.jobs[h]?.assets.sorted(), t: e.state.jobs[tID]?.state) }
            try #require(owed.h == [x.identifier] && owed.t == .downloading, "setup: H's visit is owed while T downloads: \(owed)")
            await engine.readForTests { $0.holdSpaceSweepFollowUps() }
        }
        // T's transfer fails ENOSPC; swept first its free-space read runs one follow turn.
        await s.harness.source.release(tID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.eventsAfterFollow.contains(where: Self.isSpaceFailure) }
            let read = await engine.readForTests { e in
                (t: e.state.jobs[tID]?.assets.sorted(), h: e.state.jobs[h] != nil, owed: e.followOwed, state: e.state.jobs[tID]?.state)
            }
            try #require(read.t == [a.identifier, x.identifier] && !read.h && read.owed, "setup: the read's follow turn joined zz-x to T (H, its only id moved, is gone), and the verdict waits behind the owed follow: \(read)")
            #expect(read.state?.kind == .failed, "the follow's join met T as its transfer left it, its verdict to come, and re-queued nothing (visit-first: the join met T downloading): \(String(describing: read.state))")
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseSpaceSweepFollowUps()
            }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        let tStarts = await s.harness.source.starts.filter { $0.id == tID }.count
        #expect(Self.isNoSpace(aResult), "the ENOSPC's verdict answers A at its cap with the space figures (visit-first): \(aResult)")
        #expect(xResult == aResult, "and X, which v3's visit joined to T downloading, with the same figures (visit-first): \(xResult)")
        #expect(tStarts == 1, "T's content is not requested past the interactive cap (R-SYN-5; visit-first): \(tStarts)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    /// The other side of `relane`'s count of applies: a follow's visit for an apply made since a publication's failed end
    /// met the job failed with its verdict given on a visit-first engine too, so a user interest it moves onto the job
    /// skips the backoff (T20). T (zz-a, 100 kB) downloads for A, a user waiter, and its publication fails with an I/O
    /// error while no follow is owed: the verdict, a retry after a backoff, is given at once, and the end stays recorded
    /// until T starts again (`recordPublicationEnd`). zz-x waits on H (16 bytes, held) for X, a user waiter; v3 maps
    /// zz-x to T's content, and its follow's visit of H moves zz-x onto T, which is queued again before the clock moves.
    /// Left failed by any visit while the end is recorded, T served X only once its backoff ran out.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a follow's visit for an apply after a publication's failure joins a user interest that skips the backoff, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierSkipsTheBackoffForAVisitAfterAPublicationsEnd(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_028_801
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let a = EngineHarness.onDemand("zz-a", tBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xOnT = EngineHarness.onDemand("zz-x", tBytes)
        try #require(xOnT.transferID == a.transferID && x.transferID != a.transferID, "setup: v3 maps zz-x from H to T")
        let tID = a.transferID
        let h = x.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, x] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(tID, [.hold, .stage(tBytes), .stage(tBytes)])
        await s.harness.source.script(h, [.hold, .stage(hBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[tID]?.state == .downloading }
        }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h]?.state == .downloading }
        }
        await engine.awaitCondition { !$0.followOwed && !$0.state.drainFollowUpScheduled }
        // T's publication fails with an I/O error while no follow is owed; the clock stays where it is from here on.
        s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".part"), occurrence: .nth(1), error: .io))
        await s.harness.source.release(tID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            guard case .failed(.at(_))? = e.state.jobs[tID]?.state else {
                return false
            }
            return true
        }
        let end = await engine.readForTests { e in (end: e.state.jobs[tID]?.attemptEnd, applies: e.state.appliesFollowed, owed: e.followOwed) }
        try #require(end.end != nil && end.end?.deferredAfter == nil && end.end?.failedAfter == end.applies && !end.owed, "setup: T's end is recorded and its verdict, a backoff, given at once with no follow owed: \(end)")
        let before = s.time.now()
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v3-publication-end-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in (h: e.state.jobs[h]?.assets.sorted(), t: e.state.jobs[tID]?.state.kind) }
            try #require(owed.h == [x.identifier] && owed.t == .failed, "setup: H's visit is owed, and T waits for its backoff: \(owed)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        // Gone is served: the re-queued attempt can end before this read.
        let read = await engine.readForTests { e in (state: e.state.jobs[tID]?.state, h: e.state.jobs[h] != nil) }
        #expect(read.state.map { $0.kind != .failed } != false && !read.h, "v3's visit moved zz-x off H onto T, met failed with its verdict given, and re-queued T at once (T20; visit-first): \(read)")
        #expect(s.time.now() == before, "the clock did not move")
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        let tStarts = await s.harness.source.starts.filter { $0.id == tID }.count
        #expect((try? aResult.get())?.byteSize == Int64(tBytes.count), "A is served by T's second attempt: \(aResult)")
        #expect((try? xResult.get())?.byteSize == Int64(tBytes.count), "and X, which v3 moved onto T, too: \(xResult)")
        #expect(tStarts == 2, "T's content started twice: the failed publication's attempt and the re-queued one: \(tStarts)")
        await Self.finishHeld(s)
    }
}
