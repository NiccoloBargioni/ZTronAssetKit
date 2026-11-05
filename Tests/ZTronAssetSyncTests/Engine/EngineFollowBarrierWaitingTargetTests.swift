import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// `waitingTarget`'s `queued` arm (Stage 3 close-out cycle 21, ruling S3-R26 item 5; `analyse-g4-reach.md`'s Shape A, the
/// ENOENT window): a move owed onto a job whose drained publication failed ENOENT finds the job queued at the move's
/// epoch, re-queued as that cancellation (`publicationFailed`), and is dropped; the holder's own visit moves the id. The
/// window exists only in `sweepFollowsFirst`: visited first, the holder's visit moved the id onto the job while it
/// published, before the ENOENT, so nothing is owed onto it then. Each test runs in both orders and expects the
/// visit-first answers in both.
extension EngineFollowBarrierTests {
    /// Changed on-demand entries that sort between `FollowBarrier.fillers` and the scenario's `zz-` ids: with them a pass
    /// formats two turns' worth before it reaches the scenario's entries, so the follow turn after a walk makes the walk's
    /// owed moves with their holder still unvisited.
    @available(macOS 15.0, iOS 18.0, *)
    static func middleFillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "g%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    /// What `drainedRequeueSetUp` built: T's drained publication held at its first store unit, zz-x on H.
    @available(macOS 15.0, iOS 18.0, *)
    struct DrainedRequeue {
        let s: FollowBarrier.Setup
        let bulk: SteppedBlockingExecutor
        /// zz-a on T's content (100 kB), with A's user waiter.
        let a: ManifestEntry
        /// zz-x on H's content (16 bytes), with X's user waiter.
        let x: ManifestEntry
        /// zz-x on T's content, as v3 lists it.
        let xOnT: ManifestEntry
        let aWaiter: Task<Result<AssetLocation, AssetError>, Never>
        let xWaiter: Task<Result<AssetLocation, AssetError>, Never>
        /// Lets every store unit but the publication's run, until cancelled.
        let releaser: Task<Void, Never>
        let seed: UInt64

        var engine: SyncEngine {
            self.s.engine
        }
    }

    /// T (zz-a, 100 kB) downloads for W0, the attempt's staged terminal is held (`holdAttemptTerminals()`), and W0's
    /// cancellation retires T, whose attempt drains; A's request then waits on T's content, queued, and the drained file
    /// is adopted and published (`publishDrained`), held at its first store unit. zz-x waits on H (16 bytes, held). v3
    /// maps zz-x to T's content and v3b changes only the leading fillers: swept first v3b's walk, under v3's copy, records
    /// the move H → T [zz-x] (`bringInboundOntoPublications`); visited first v3's visit moved zz-x onto T, publishing.
    /// T's later attempts follow `tLater`.
    @available(macOS 15.0, iOS 18.0, *)
    func drainedRequeueSetUp(_ visit: LaneDropVisit, seed: UInt64, tLater: [FakeTransferStep]) async throws -> DrainedRequeue {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let a = EngineHarness.onDemand("zz-a", tBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xOnT = EngineHarness.onDemand("zz-x", tBytes)
        try #require(xOnT.transferID == a.transferID && x.transferID != a.transferID, "setup: v3 maps zz-x from H to T")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + Self.middleFillers(seed + 150) + [a, x] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(tBytes)] + tLater)
        await s.harness.source.script(x.transferID, [.hold, .stage(hBytes)])
        let w0 = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .downloading }
        }
        // T's first attempt stages its bytes, and its driver waits before it applies them.
        await engine.readForTests { $0.holdAttemptTerminals() }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.heldAttemptTerminalCount == 1 }
        // W0 withdraws: T is retired and its attempt drains.
        w0.cancel()
        let w0Result = await w0.value
        try #require(w0Result == .failure(.cancelled), "setup: W0 is answered its cancellation: \(w0Result)")
        await engine.awaitCondition { $0.state.jobs[a.transferID] == nil && $0.state.draining[a.transferID] != nil }
        // A wants T's content while the attempt drains: its job waits, queued.
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        // The drained file is adopted, and the next start publishes it, held at its first store unit.
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await bulk.setHolding(true)
        await engine.readForTests { $0.releaseAttemptTerminals() }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .verifying }
        try await bulk.requireHeldUnits(atLeast: 1)
        let unit = try #require(await bulk.heldUnits.first)
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: 2)
                for other in await bulk.heldUnits where other != unit {
                    await bulk.release(other)
                }
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + Self.middleFillers(seed + 250) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v3-drained-\(seed)", s, visit: visit)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + Self.middleFillers(seed + 250) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v3b-drained-\(seed)", s, visit: visit)
        return DrainedRequeue(s: s, bulk: bulk, a: a, x: x, xOnT: xOnT, aWaiter: aWaiter, xWaiter: xWaiter, releaser: releaser, seed: seed)
    }

    /// The owed move H → T [zz-x] the walk recorded, if any.
    static func owedMove(_ e: isolated SyncEngine, from holder: TransferID, onto target: TransferID) -> InboundMove? {
        e.state.inboundMoves[e.state.inboundNext...].first { $0.holder == holder && $0.target == target }
    }

    /// Fails T's drained publication with ENOENT at its placement rename and lets it resume.
    @available(macOS 15.0, iOS 18.0, *)
    static func failDrainedPublication(_ t: DrainedRequeue) async {
        t.s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .notFound))
        t.releaser.cancel()
        await t.releaser.value
        await t.bulk.setHolding(false)
    }

    // MARK: The queued arm (S3-R26 item 5, Shape A)

    /// Swept first, the move v3b's walk owes onto T finds T queued at the move's epoch once its drained publication fails
    /// ENOENT, and the follow turn that makes the owed moves drops it: zz-x stays on H, and nothing is owed onto T. The
    /// next turns' visit of H moves zz-x under the copy as it stands, onto T, queued, whose fresh attempt serves A and X
    /// T's bytes, as visited first, where v3's visit joined X to T publishing, and the ENOENT re-queued T with both. T's
    /// content starts twice in both orders (the drained attempt, then the fresh one). A move made onto the queued T (the
    /// arm folded into `return job`) moves zz-x onto T in that first turn.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed move onto a job its drained publication's ENOENT re-queued is dropped, and the holder's visit moves the id, with the visit-first answers (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDropsAMoveOntoAJobItsDrainedPublicationReQueued(_ visit: LaneDropVisit) async throws {
        let t = try await self.drainedRequeueSetUp(visit, seed: 2_028_601, tLater: [.stage(EngineFixture.bytes(2_028_601 + 3, count: 100_000))])
        let engine = t.engine
        let h = t.x.transferID
        let tID = t.a.transferID
        let move = await engine.readForTests { Self.owedMove($0, from: h, onto: tID).map { (ids: $0.ids, epoch: $0.epoch) } }
        if visit == .sweepFollowsFirst {
            try #require(move?.ids == [t.x.identifier], "setup: v3b's walk under v3's copy owes H → T [zz-x]: \(String(describing: move))")
        } else {
            try #require(move == nil, "setup: visited first, v3's visit moved zz-x onto T publishing: \(String(describing: move))")
        }
        await Self.failDrainedPublication(t)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.jobs[tID]?.state == .queued }
            let requeued = await engine.readForTests { e in
                (epoch: e.state.jobs[tID]?.epoch, owed: Self.owedMove(e, from: h, onto: tID) != nil, onto: e.state.inboundOnto[tID])
            }
            try #require(requeued.epoch == move?.epoch && requeued.owed && requeued.onto == 1, "setup: the ENOENT re-queued T at the move's epoch, and the move is still owed: \(requeued)")
            await Self.runOneFollowTurn(engine)
            let afterTurn = await engine.readForTests { e in
                (h: e.state.jobs[h]?.assets.sorted(), t: e.state.jobs[tID]?.assets.sorted(), onto: e.state.inboundOnto[tID], owed: e.inboundOwed)
            }
            #expect(afterTurn.h == [t.x.identifier] && afterTurn.t == [t.a.identifier], "the turn dropped the move: zz-x is still on H and not on T: \(afterTurn)")
            #expect(afterTurn.onto == nil && !afterTurn.owed, "nothing is owed onto T: \(afterTurn)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: t.aWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: t.xWaiter) }
        let tStarts = await t.s.harness.source.starts.filter { $0.id == tID }.count
        #expect(aResult.map(\.byteSize) == .success(100_000), "T's fresh attempt serves A (visit-first): \(aResult)")
        #expect(xResult.map(\.byteSize) == .success(100_000), "T's fresh attempt serves X (visit-first): \(xResult)")
        #expect(tStarts == 2, "T's content starts twice, the drained attempt and the fresh one (visit-first): \(tStarts)")
        await Self.finishHeld(t.s)
    }

}
