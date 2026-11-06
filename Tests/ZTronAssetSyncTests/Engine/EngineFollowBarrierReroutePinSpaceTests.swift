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

        var description: String {
            "X at the drain's end \(self.xAtDrain); after the read \(self.afterRead); X started \(self.xStarts) times, W \(self.wStarts); \(self.layer.map { "\($0)" } ?? "no outcome")"
        }
    }

    /// `pinEnd`'s shape with X's publication failing ENOSPC, at an interactive cap of one attempt: zz-x (V2's) is X's
    /// content, which downloads, then publishes, held at its first store unit, while O does; K0 maps zz-a1…zz-a3 to X's
    /// content, O's commit owes their re-routes, and K1 maps them to W's content while X still publishes (K1's layer pins
    /// X). X's placement then fails ENOSPC; the free-space read that follows is held on the store's metadata executor
    /// while the follow's and the drain's turns run, then released. Visited first, O's commit re-routed W1…W3 onto X
    /// publishing, K1's visit passed X (RR-14), and the ENOSPC's verdict, at the cap, answered V2 and W1…W3 with the space
    /// figures: X started once, W never. A fresh attempt of X, or one of W, gets a 404.
    @available(macOS 15.0, iOS 18.0, *)
    static func pinSpaceRead(_ visit: LaneDropVisit, seed: UInt64) async throws -> PinSpaceRun {
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
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes), .fail(.permanentMissing(httpStatus: 404))])
        await c.s.harness.source.script(wT, [.fail(.permanentMissing(httpStatus: 404))])
        let v2 = await Self.downloadingWaiter(x, c)
        var held = try await Self.oweThroughK0(c, k0: [x] + onX, publishing: [xT], visit: visit)
        try await Self.applyBehindBatch(c.manifest([x] + onW, round: 2), tag: "k1-pin-space-\(seed)", c)
        #expect(await Self.pins(xT, c) == [true], "setup: K1's layer pins X, which publishes")
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
        let outcome = await Self.finishOwed(c, held: held, others: [v2])
        run.layer = LayerOutcome(k: outcome.k, w: outcome.w, others: outcome.others, violations: turns.violations + outcome.violations)
        run.xStarts = await Self.starts(xT, c)
        run.wStarts = await Self.starts(wT, c)
        await Self.finishHeld(c.s)
        return run
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
}
