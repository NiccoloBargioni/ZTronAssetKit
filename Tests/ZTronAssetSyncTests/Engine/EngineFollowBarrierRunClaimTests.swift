import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A run's claim that a visit re-routed onto a job whose verdict waits (Stage 3 close-out cycle 21, ruling S3-R26 item 12's
/// answer 5, candidate 1; `critic-defer-bucket.md`'s T-RUN). Each runs in both orders (`LaneDropVisit`) and expects the
/// visit-first answers in both.
extension EngineFollowBarrierTests {
    // MARK: Item 12's answer 5, candidate 1: a run's claim orphaned at a verdict replayed with the barrier down

    /// `critic-defer-bucket.md`'s T-RUN shape (R1, A3): a forced sync's run has its last claim, zz-a, on O (content o),
    /// held downloading; T (zz-t, content t) downloads for a prefetch waiter. v3's follow is then owed, and T's attempt
    /// gets a 404: its verdict waits. v4 maps zz-a to content t: the follow's visit of O re-routes the run's claim onto T
    /// (`reroute`), its join behind T's waiting verdict, and the drain's one batch holds both events. While T's verdict
    /// replays the barrier reads down, and the run check it makes (`checkRunSettled`) finds the claim on a job that does
    /// not hold the run's interest (the orphan pass). A run starts only once a free-space read's sweep has ended an owed
    /// follow (`sweepSpaceParked`), so the run's own first claims never wait behind an earlier verdict; this shape moves
    /// a claim instead. Visited first, T's 404 answered zz-t and ended T before v4, whose visit of O made a new job of
    /// content t for zz-a, which fetched it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a run's claim re-routed behind a waiting verdict is not orphaned when that verdict replays, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierKeepsARunsClaimAtTheVerdictItWaitsBehind(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_021_801
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 20)
        let tBytes = EngineFixture.bytes(seed + 4, count: 16)
        let aOnO = EngineFixture.entry("zz-a", oBytes)
        let aOnT = EngineFixture.entry("zz-a", tBytes)
        let zt = EngineHarness.onDemand("zz-t", tBytes)
        let o = aOnO.transferID
        let t = zt.transferID
        try #require(aOnT.transferID == t && t != o, "setup: v4 maps zz-a to T's content")
        await s.harness.source.script(o, [.hold, .stage(oBytes)])
        await s.harness.source.script(t, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(tBytes)])
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [aOnO, zt] + Self.laterFillers(seed + 3_000), etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in e.state.jobs[o]?.state == .downloading && e.state.run?.outstanding[o] == [aOnO.identifier] }
        }
        let wt = Task { await engine.awaitAsset(zt.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[t]?.state == .downloading }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [aOnO, zt] + Self.laterFillers(seed + 6_000), tag: "v3-run-orphan-\(seed)", s, visit: visit)
        await s.harness.source.release(t, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            visit == .sweepFollowsFirst ? e.state.jobs[t]?.attemptEnd?.deferredAfter != nil : e.state.jobs[t] == nil
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [aOnT, zt] + Self.laterFillers(seed + 9_000), tag: "v4-run-orphan-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.state.run?.outstanding[t]?.contains(aOnO.identifier) != true }) {
                try #require(turns < 8, "setup: O's visit re-routes the run's claim on zz-a onto T within 8 follow turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            let queue = await engine.readForTests { e in
                (e.followOwed, e.state.eventsAfterFollow.map { event -> String in
                    switch event {
                    case .attemptFailed(let transfer, _, _):
                        return transfer == t ? "T" : "other verdict"
                    case .join(let join):
                        return join.asset == aOnO.identifier ? "a" : "other join"
                    default:
                        return "other"
                    }
                })
            }
            try #require(queue.1 == ["T", "a"], "setup: the queue holds T's verdict and the run's join behind it, nothing else: \(queue)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        let outcome = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: sync) }
        let tResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wt) }
        #expect(tResult == .failure(.notFound), "zz-t gets T's 404: \(tResult)")
        let report: SyncReport? = switch outcome {
        case .completeWithFailures(let report), .complete(let report):
            report
        default:
            nil
        }
        #expect(report?.fetched == 1 && report?.failures.isEmpty == true, "the run fetches zz-a with T's content (visit-first): \(outcome)")
        await Self.finishHeld(s)
    }
}
