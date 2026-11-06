import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// e1-P2 (Stage 3 close-out cycle 22, ruling S3-R27 item 12.2; e1 §3's second UNCONFIRMED sibling): the drain's visit
/// after a verdict (`followAfterVerdict`) moves an id onto a job whose publication failed ENOSPC, while that failure's
/// free-space read runs. The publication's end is recorded before the read (`recordPublicationEnd`) and its verdict
/// defers only after it (`spaceFailed`). The visit after a verdict stands for visits at the applies since that verdict
/// deferred: one before the end met the job publishing on a visit-first engine, so a user join it makes must not
/// re-queue the job (T20) and skip the ENOSPC's verdict; one since the end met it failed, and re-queues it.
extension EngineFollowBarrierTests {
    /// When the apply that maps zz-y to X's content comes (`afterVerdictSpaceRead`).
    enum AfterVerdictSpaceApply: CaseIterable, Sendable {
        /// K comes while X publishes, before its placement ends: visited first, K's visit joined zz-y to X publishing.
        case beforeEnd
        /// K comes while X's free-space read is held: visited first, K's visit met X failed with its verdict to come and
        /// re-queued it (T20), so X's fresh attempt, which serves its bytes, answered.
        case inRead
    }

    /// What `afterVerdictSpaceRead` read: X's job once the follow and the drain were over (the free-space read still
    /// held), the answers of X's and Y's user waiters, and X's starts.
    struct AfterVerdictSpaceRun: CustomStringConvertible {
        var xAtDrain = ""
        var vx: Result<AssetLocation, AssetError> = .failure(.shutDown)
        var vy: Result<AssetLocation, AssetError> = .failure(.shutDown)
        var xStarts = 0
        var yStarts = 0

        var description: String {
            "X at the drain's end \(self.xAtDrain); Vx \(self.vx), Vy \(self.vy); X started \(self.xStarts) times, Y \(self.yStarts)"
        }
    }

    /// X (zz-x, 18 bytes) downloads for Vx and Y (zz-y, 20 bytes) for Vy, both user waiters, at an interactive cap of one
    /// attempt; X's publication is held at its first store unit. v3 makes the follow owe its visits (swept first), and
    /// Y's attempt then ends in a cancel the engine did not ask for: a fresh attempt at once (`.requeue`, which answers
    /// nobody and counts nothing), which waits for the follow swept first. K maps zz-y to X's content (`apply`). X's
    /// placement rename fails ENOSPC, and the free-space read that follows is held on the store's metadata executor while
    /// the follow's and the drain's turns run, swept first: K's visit passes Y, whose verdict waits, and the drain gives
    /// Y's verdict and its visit after it moves zz-y onto X. Visited first, the verdict was given at the cancel, and K's
    /// visit moved zz-y off Y's fresh attempt onto X. X's fresh attempt gets a 404, or, with K inside the read, serves
    /// its bytes.
    @available(macOS 15.0, iOS 18.0, *)
    static func afterVerdictSpaceRead(_ visit: LaneDropVisit, _ apply: AfterVerdictSpaceApply, seed: UInt64) async throws -> AfterVerdictSpaceRun {
        var run = AfterVerdictSpaceRun()
        var interactive = RetryPolicy.interactive
        interactive.maxAttemptsPerRun = 1
        let metadata = SteppedBlockingExecutor(holding: false)
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: interactive), metadata: metadata)
        let engine = s.engine
        let xBytes = EngineFixture.bytes(seed + 3, count: 18)
        let yBytes = EngineFixture.bytes(seed + 4, count: 20)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        let yOnX = EngineHarness.onDemand("zz-y", xBytes)
        try #require(yOnX.transferID == x.transferID && y.transferID != x.transferID, "setup: K maps zz-y from Y's content to X's")
        let xT = x.transferID
        let yT = y.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [x, y] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(xT, [.hold, .stage(xBytes), apply == .inRead ? .stage(xBytes) : .fail(.permanentMissing(httpStatus: 404))])
        await s.harness.source.script(yT, [.hold, .fail(.cancelled(.byClient)), .hold])
        let vx = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[xT]?.state == .downloading }
        }
        let vy = Task { await engine.awaitAsset(y.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[yT]?.state == .downloading }
        }
        let releaser = try await Self.holdPublication(of: xT, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [x, y] + Self.laterFillers(seed + 6_000), tag: "v3-after-verdict-space-\(seed)", s, visit: visit)
        let yStart = await engine.readForTests { $0.state.jobs[yT]?.active?.startSequence }
        await s.harness.source.release(yT, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                if visit == .sweepFollowsFirst {
                    return e.state.jobs[yT]?.attemptEnd?.deferredAfter != nil
                }
                return e.state.jobs[yT]?.active.map { $0.startSequence != yStart } ?? false
            }
        }
        let k = [s.q] + FollowBarrier.fillers(seed + 300) + [x, yOnX] + Self.laterFillers(seed + 9_000)
        if apply == .beforeEnd {
            try await Self.applyHeld(k, tag: "k-after-verdict-space-\(seed)", s, visit: visit)
            let setup = await engine.readForTests { e in (x: e.state.jobs[xT]?.assets.sorted(), y: e.state.jobs[yT]?.assets.sorted(), state: e.state.jobs[xT]?.state) }
            if visit == .sweepFollowsFirst {
                try #require(setup.y == [y.identifier] && setup.x == [x.identifier] && setup.state == .verifying, "setup: Y's verdict waits with zz-y on it, and X publishes: \(setup)")
            } else {
                try #require(setup.x == [x.identifier, y.identifier] && setup.state == .verifying, "setup: K's visit joined zz-y to X publishing: \(setup)")
            }
        }
        // X's placement rename fails ENOSPC. The store's metadata units are held from here and released as they come
        // until X's attempt has failed with its end recorded: the unit held then is the free-space read that follows.
        s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .noSpace))
        await metadata.setHolding(true)
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        var read: Int?
        while read == nil {
            try await metadata.requireHeldUnits(atLeast: 1)
            let failed = await engine.readForTests { e -> Bool in
                if case .failed = e.state.jobs[xT]?.state {
                    return e.state.jobs[xT]?.attemptEnd != nil
                }
                return false
            }
            if failed {
                read = await metadata.heldUnits.first
            } else {
                await metadata.releaseAll()
            }
        }
        let readUnit = try #require(read, "setup: X's free-space read is held at the store")
        let others = Self.releasing(except: [readUnit], metadata)
        if apply == .inRead {
            try await Self.applyHeld(k, tag: "k-after-verdict-space-\(seed)", s, visit: visit)
        }
        if visit == .sweepFollowsFirst {
            let waiting = await engine.readForTests { e in
                e.state.eventsAfterFollow.contains { event in
                    if case .attemptFailed(let transfer, _, _) = event {
                        return transfer == yT
                    }
                    return false
                }
            }
            try #require(waiting, "setup: Y's verdict waits for the follow")
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        run.xAtDrain = await engine.readForTests { e in e.state.jobs[xT].map { "\($0.state) holding \($0.assets.sorted().map(\.rawValue))" } ?? "gone" }
        others.cancel()
        await others.value
        await metadata.setHolding(false)
        run.vx = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: vx) }
        run.vy = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: vy) }
        run.xStarts = await s.harness.source.starts.filter { $0.id == xT }.count
        run.yStarts = await s.harness.source.starts.filter { $0.id == yT }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return run
    }

    /// e1-P2: K maps zz-y to X's content while X publishes. Swept first, the drain's visit after Y's verdict joins zz-y to
    /// X inside the free-space read; visited first, K's visit joined it to X publishing, and the ENOSPC's verdict, at the
    /// cap, answered Vx and Vy with the space figures. X starts once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an id the drain's visit after a verdict moves onto a job inside its publication's ENOSPC free-space read gets that ENOSPC's verdict at the attempt cap (F-28, T20, e1-P2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func afterVerdictVisitInsideAnENOSPCsReadGetsItsVerdict(_ visit: LaneDropVisit) async throws {
        let run = try await Self.afterVerdictSpaceRead(visit, .beforeEnd, seed: 2_029_001)
        #expect(Self.isNoSpace(run.vx) && run.vy == run.vx, "Vx and Vy get the ENOSPC's space figures (visit-first): \(run)")
        #expect(run.xStarts == 1, "X is not requested past the interactive cap (visit-first): \(run)")
    }

    /// e1-P2's other side: K comes inside X's free-space read. Swept first, the drain's visit after Y's verdict, for an
    /// apply made since X's end, joins zz-y to X; visited first, K's visit met X failed with its verdict to come and
    /// re-queued it (T20): the ENOSPC's verdict was skipped, and X's fresh attempt served Vx and Vy its 18 bytes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an id the drain's visit after a verdict moves onto a job for an apply inside its publication's ENOSPC free-space read skips that ENOSPC's verdict (F-28, T20, e1-P2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func afterVerdictVisitForAnApplyInsideAnENOSPCsReadSkipsItsVerdict(_ visit: LaneDropVisit) async throws {
        let run = try await Self.afterVerdictSpaceRead(visit, .inRead, seed: 2_029_011)
        #expect(Self.sizes([run.vx, run.vy]) == [18, 18], "Vx and Vy get X's fresh attempt's bytes (visit-first): \(run)")
        #expect(run.xStarts == 2, "X starts twice (visit-first): \(run)")
    }
}
