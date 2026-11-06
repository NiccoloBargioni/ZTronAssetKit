import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// e1-P1 (Stage 3 close-out cycle 22, ruling S3-R27 item 12.2; e1 §3's first UNCONFIRMED sibling): the drain's replay of
/// an owed re-route pinned to a job whose publication failed ENOSPC, while that failure's free-space read runs. The
/// publication's end is recorded before the read (`recordPublicationEnd`) and its verdict defers only after it
/// (`spaceFailed`); `relane`'s guard covers the follow's own visit inside that window. A visit-first engine's commit had
/// re-routed the ids onto the job publishing, so the ENOSPC's verdict answered them; a user join the replay makes must
/// not re-queue the job (T20) and skip that verdict.
extension EngineFollowBarrierTests {
    /// What `pinSpaceRead` read: X's job once the drain was over (the free-space read still held), X's and W's jobs once
    /// the read returned and the verdict could end X, X's starts, W's, and the outcome.
    struct PinSpaceRun: CustomStringConvertible {
        var xAtDrain = ""
        var afterRead = ""
        var xStarts = 0
        var wStarts = 0
        var layer: LayerOutcome?

        var v2: Result<AssetLocation, AssetError> {
            self.layer?.others.first ?? .failure(.shutDown)
        }

        /// V3's answer, when `pinSpaceRead` made its request.
        var v3: Result<AssetLocation, AssetError> {
            self.layer.flatMap { $0.others.count > 1 ? $0.others[1] : nil } ?? .failure(.shutDown)
        }

        var description: String {
            "X at the drain's end \(self.xAtDrain); after the read \(self.afterRead); X started \(self.xStarts) times, W \(self.wStarts); \(self.layer.map { "\($0)" } ?? "no outcome")"
        }
    }

    /// A later user request for zz-x (V3's), which waits behind the barrier as a join of its own: made while X publishes,
    /// as the last decision instant minted before X's placement ends (`beforeEnd`, the bound `AttemptEnd.stamped` keeps),
    /// or while X's free-space read is held (`inRead`), when a visit-first engine's request met X failed with its verdict
    /// to come and re-queued it (T20), so that verdict was skipped and X's fresh attempt, which serves its bytes, answered.
    enum PinSpaceJoin: CaseIterable, Sendable {
        case beforeEnd
        case inRead
    }

    /// `pinEnd`'s shape with X's publication failing ENOSPC, at an interactive cap of one attempt: zz-x (V2's) is X's
    /// content, which downloads, then publishes, held at its first store unit, while O does; K0 maps zz-a1…zz-a3 to X's
    /// content, O's commit owes their re-routes, and K1 maps them to W's content while X still publishes (K1's layer pins
    /// X). X's placement then fails ENOSPC; the free-space read that follows is held on the store's metadata executor
    /// while the follow's and the drain's turns run, then released. Visited first, O's commit re-routed W1…W3 onto X
    /// publishing, K1's visit passed X (RR-14), and the ENOSPC's verdict, at the cap, answered V2 and W1…W3 with the space
    /// figures: X started once, W never. A fresh attempt of X, or any attempt of W, gets a 404, unless V3's request comes
    /// inside the read (`join`), when X's fresh attempt serves its bytes.
    @available(macOS 15.0, iOS 18.0, *)
    static func pinSpaceRead(_ visit: LaneDropVisit, seed: UInt64, join: PinSpaceJoin? = nil) async throws -> PinSpaceRun {
        var run = PinSpaceRun()
        var interactive = RetryPolicy.interactive
        interactive.maxAttemptsPerRun = 1
        let metadata = SteppedBlockingExecutor(holding: false)
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let wBytes = EngineFixture.bytes(seed + 6, count: 20)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x], tuning: SyncTuning(interactiveRetry: interactive), metadata: metadata)
        let engine = c.engine
        let xT = x.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        let wT = onW[0].transferID
        try #require(wT != xT && wT != c.transfer, "setup: K1 maps the ids to a content of their own")
        // Each attempt a mutant can add gets a 404 too, so that it fails on the start counts asserted, not on a time limit
        // (S3-R27 item 12.2's serving rule; S3-R28 item 4: under `metInItsAttempt` false, W started twice and its second
        // attempt, unscripted, waited for the 180 s limit).
        let missing = FakeTransferStep.fail(.permanentMissing(httpStatus: 404))
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes), join == .inRead ? .stage(xBytes) : missing, missing])
        await c.s.harness.source.script(wT, [missing, missing, missing])
        let v2 = await Self.downloadingWaiter(x, c)
        var held = try await Self.oweThroughK0(c, k0: [x] + onX, publishing: [xT], visit: visit)
        try await Self.applyBehindBatch(c.manifest([x] + onW, round: 2), tag: "k1-pin-space-\(seed)", c)
        #expect(await Self.pins(xT, c) == [true], "setup: K1's layer pins X, which publishes")
        var v3: Task<Result<AssetLocation, AssetError>, Never>?
        var v3Serial: UInt64?
        if join == .beforeEnd {
            v3 = try await Self.deferredJoin(x, c)
            v3Serial = await engine.readForTests { $0.state.eventStamps.last?.serial }
        }
        // X's placement rename fails ENOSPC. The store's metadata units are held from here and released as they come
        // until X's attempt has failed with its end recorded: the unit held then is the free-space read that follows.
        c.s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .noSpace))
        await metadata.setHolding(true)
        await held.release(held.kept[0])
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
        if let v3Serial {
            let stamped = await engine.readForTests { $0.state.jobs[xT]?.attemptEnd?.stamped }
            try #require(stamped == v3Serial, "setup: V3's join is the last decision instant minted before X's end: \(String(describing: stamped)), V3 \(v3Serial)")
        }
        if join == .inRead {
            v3 = try await Self.deferredJoin(x, c)
        }
        let turns = await Self.releaseOwedTurns(c)
        run.xAtDrain = await engine.readForTests { e in e.state.jobs[xT].map { "\($0.state) holding \($0.assets.sorted().map(\.rawValue))" } ?? "gone" }
        others.cancel()
        await others.value
        await metadata.setHolding(false)
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[xT].map { $0.state != .failed(.nextRun) } ?? true }
        }
        run.afterRead = await engine.readForTests { e in
            "X \(e.state.jobs[xT].map { "\($0.state) holding \($0.assets.sorted().map(\.rawValue))" } ?? "gone"), W \(e.state.jobs[wT].map { "\($0.state) holding \($0.assets.sorted().map(\.rawValue))" } ?? "gone")"
        }
        let outcome = await Self.finishOwed(c, held: held, others: [v2] + (v3.map { [$0] } ?? []))
        run.layer = LayerOutcome(k: outcome.k, w: outcome.w, others: outcome.others, violations: turns.violations + outcome.violations)
        run.xStarts = await Self.starts(xT, c)
        run.wStarts = await Self.starts(wT, c)
        await Self.finishHeld(c.s)
        return run
    }

    /// A user request for `entry`'s id made behind the barrier, once its join waits for the follow.
    @available(macOS 15.0, iOS 18.0, *)
    static func deferredJoin(_ entry: ManifestEntry, _ c: OwedCommit) async throws -> Task<Result<AssetLocation, AssetError>, Never> {
        let engine = c.engine
        let id = entry.identifier
        let transfer = entry.transferID
        let waiting = await engine.readForTests { e in e.state.joinsAfterFollow.values.filter { $0[id] == transfer }.count }
        let waiter = Task { await engine.awaitAsset(id, lane: .userInitiated) }
        await engine.awaitCondition { e in e.state.joinsAfterFollow.values.filter { $0[id] == transfer }.count > waiting }
        return waiter
    }

    /// e1-P1: the drain's replay inside X's free-space read joins W1…W3 onto X, failed with its end recorded and its
    /// verdict to come. Visited first, the verdict answered them with the space figures, as it answered V2.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an owed re-route replayed onto a job inside its publication's ENOSPC free-space read gets that ENOSPC's verdict at the attempt cap (F-28, T20, e1-P1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedReroutePinnedToAJobInItsSpaceReadGetsItsVerdict(_ visit: LaneDropVisit) async throws {
        let run = try await Self.pinSpaceRead(visit, seed: 2_028_961)
        let layer = try #require(run.layer)
        #expect(Self.isNoSpace(run.v2) && layer.w.allSatisfy { $0 == run.v2 }, "V2 and W1…W3 get the ENOSPC's space figures (visit-first): \(run)")
        #expect(Self.sizes([layer.k]) == [16] && run.xStarts == 1 && run.wStarts == 0, "K gets O's bytes, X starts once and W never (visit-first): \(run)")
        #expect(layer.violations.isEmpty, "\(layer.violations.prefix(3))")
    }

    /// e1-P1's bound: V3's request, the last decision instant minted before X's placement ends, waits behind the barrier
    /// and is replayed inside X's free-space read. A visit-first engine's request joined X publishing, so the ENOSPC's
    /// verdict answered it with the space figures, as it answered V2 and W1…W3.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user request that arrived just before a publication's ENOSPC, replayed inside its free-space read, gets that ENOSPC's verdict at the attempt cap (F-28, T20, e1-P1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict(_ visit: LaneDropVisit) async throws {
        let run = try await Self.pinSpaceRead(visit, seed: 2_028_971, join: .beforeEnd)
        let layer = try #require(run.layer)
        #expect(Self.isNoSpace(run.v2) && run.v3 == run.v2 && layer.w.allSatisfy { $0 == run.v2 }, "V2, V3 and W1…W3 get the ENOSPC's space figures (visit-first): \(run)")
        #expect(Self.sizes([layer.k]) == [16] && run.xStarts == 1 && run.wStarts == 0, "K gets O's bytes, X starts once and W never (visit-first): \(run)")
        #expect(layer.violations.isEmpty, "\(layer.violations.prefix(3))")
    }

    /// e1-P1's other side: V3's request, made while X's free-space read is held, waits behind the barrier and is replayed
    /// inside the read, after W1…W3's re-routes. A visit-first engine's request met X failed with its verdict to come and
    /// re-queued it (T20): the ENOSPC's verdict was skipped, and X's fresh attempt served V2 and V3 its bytes; its commit
    /// bound zz-x only, so W1…W3, which K1 maps to W's content, followed it there and got W's 404.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user request that arrived inside a publication's ENOSPC free-space read skips that ENOSPC's verdict when replayed there (F-28, T20, e1-P1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func userJoinFromInsideAnENOSPCsReadSkipsItsVerdict(_ visit: LaneDropVisit) async throws {
        let run = try await Self.pinSpaceRead(visit, seed: 2_028_981, join: .inRead)
        let layer = try #require(run.layer)
        #expect(Self.sizes([run.v2, run.v3]) == [18, 18], "V2 and V3 get X's fresh attempt's bytes (visit-first): \(run)")
        #expect(layer.w.allSatisfy { $0 == .failure(.notFound) } && run.xStarts == 2 && run.wStarts == 1, "W1…W3 follow K1's copy to W after X's commit and get its 404; X starts twice, W once (visit-first): \(run)")
        #expect(Self.sizes([layer.k]) == [16], "K gets O's bytes: \(run)")
        #expect(layer.violations.isEmpty, "\(layer.violations.prefix(3))")
    }
}
