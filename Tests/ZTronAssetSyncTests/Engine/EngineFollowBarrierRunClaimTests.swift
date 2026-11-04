import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A run's claim that a visit re-routed onto a job whose verdict waits (Stage 3 close-out cycle 21, ruling S3-R26 item 12's
/// answer 5, candidates 1 and 2; `critic-defer-bucket.md`'s T-RUN and residual risks). Each runs in both orders
/// (`LaneDropVisit`) and expects the visit-first answers in both.
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
                }, e.state.joinsBehindVerdicts.map { key, behind in
                    (key.transfer == t ? "T" : "other verdict", behind.map { $0.join.asset == aOnO.identifier ? "a" : "other join" })
                })
            }
            // The run's join waits in T's bucket (`EngineState.joinsBehindVerdicts`; ruling S3-R26 item 2), which the
            // drain's batch places right behind T's verdict.
            let behind = queue.2.first
            try #require(queue.1 == ["T"] && queue.2.count == 1 && behind?.0 == "T" && behind?.1 == ["a"], "setup: the queue holds T's verdict and the run's join waits behind it, nothing else: \(queue)")
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

    // MARK: Item 12's answer 5, candidate 2: a run's claim a visit re-routed onto a job whose verdict waits

    /// A forced sync's run fetches zz-t1 (content t, job T) and zz-o2 (content o, job O), both held downloading. v3's
    /// follow is then owed, and T's attempt gets a 404: its verdict waits. v4 maps zz-o2 to content t: the follow's
    /// visit of O re-routes the run's claim on zz-o2 onto T (`reroute`), its join behind T's waiting verdict. The drain
    /// gives T's verdict, which answers the run for T. Until close-out cycle 21 that emptied all of T's claims
    /// (`recordRunOutcome`'s `outstanding[T] = nil`), so the join behind it found no claim (`stillWants`;
    /// `critic-defer-bucket.md`'s residual risks) and zz-o2 was neither fetched nor failed. Visited first, T's 404 failed
    /// zz-t1 and ended T before v4, whose visit of O made a new job of content t for zz-o2, which fetched it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a run's claim that a visit re-routed behind a waiting verdict is fetched after it, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierKeepsARunsClaimReroutedBehindAVerdict(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_021_901
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 16)
        let oBytes = EngineFixture.bytes(seed + 4, count: 20)
        let t1 = EngineFixture.entry("zz-t1", tBytes)
        let o2 = EngineFixture.entry("zz-o2", oBytes)
        let o2OnT = EngineFixture.entry("zz-o2", tBytes)
        let t = t1.transferID
        let o = o2.transferID
        try #require(o2OnT.transferID == t && t != o, "setup: v4 maps zz-o2 to T's content")
        await s.harness.source.script(t, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(tBytes)])
        await s.harness.source.script(o, [.hold, .stage(oBytes)])
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [t1, o2] + Self.laterFillers(seed + 3_000), etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.jobs[t]?.state == .downloading && e.state.jobs[o]?.state == .downloading && e.state.run?.outstanding.count == 2
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [t1, o2] + Self.laterFillers(seed + 6_000), tag: "v3-run-reroute-\(seed)", s, visit: visit)
        await s.harness.source.release(t, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            visit == .sweepFollowsFirst ? e.state.jobs[t]?.attemptEnd?.deferredAfter != nil : e.state.jobs[t] == nil
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [t1, o2OnT] + Self.laterFillers(seed + 9_000), tag: "v4-run-reroute-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.state.run?.outstanding[t]?.contains(o2.identifier) != true }) {
                try #require(turns < 8, "setup: O's visit re-routes the run's claim on zz-o2 onto T within 8 follow turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            let waiting = await engine.readForTests { e in (e.state.jobs[t]?.attemptEnd?.deferredAfter != nil, e.state.jobs[t]?.assets.contains(o2.identifier) == true) }
            try #require(waiting.0 && !waiting.1, "setup: T's verdict waits, and the claim's join waits behind it: \(waiting)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        let outcome = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: sync) }
        let report: SyncReport? = switch outcome {
        case .completeWithFailures(let report), .complete(let report):
            report
        default:
            nil
        }
        #expect(report?.fetched == 1, "the run fetches zz-o2 with T's content (visit-first): \(outcome)")
        #expect(report?.failures.map(\.id) == [t1.identifier] && report?.failures.first?.error == .notFound, "the run fails zz-t1 with T's 404: \(outcome)")
        await Self.finishHeld(s)
    }

    // MARK: A run's claim the drain takes off a verdict's job before the verdict and re-routes after it

    /// A forced sync's run claims zz-a and zz-b, both of content j (job J), held downloading. v3 maps zz-a to content k
    /// while the follow is owed, and J's attempt then gets a 404: its verdict waits, with zz-a among the ids a
    /// visit-first engine's visit had moved off J before it (`AttemptEnd.movedBefore`). v4 maps zz-a back to content j.
    /// The drain takes zz-a off J before the verdict and re-routes it after (`takeOffMovedBefore`,
    /// `rerouteMovedBefore`), and the verdict's run check falls between the two, with the barrier read down (found
    /// while fixing candidate 2, whose `recordRunOutcome` change keeps zz-a's claim on J through the verdict). Visited
    /// first, v3's visit moved the claim to K, J's 404 failed zz-b, and v4's visit moved the claim back to a new job of
    /// content j, which fetched it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a run's claim the drain takes off a waiting verdict's job is fetched after the verdict, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierKeepsARunsClaimTakenOffBeforeAVerdict(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_022_601
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let jBytes = EngineFixture.bytes(seed + 3, count: 16)
        let kBytes = EngineFixture.bytes(seed + 4, count: 20)
        let a = EngineFixture.entry("zz-a", jBytes)
        let b = EngineFixture.entry("zz-b", jBytes)
        let aOnK = EngineFixture.entry("zz-a", kBytes)
        let j = a.transferID
        let k = aOnK.transferID
        try #require(b.transferID == j && k != j, "setup: zz-a and zz-b share content j, and v3 maps zz-a to content k")
        await s.harness.source.script(j, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(jBytes)])
        await s.harness.source.script(k, [.hold, .stage(kBytes)])
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in e.state.jobs[j]?.state == .downloading && e.state.run?.outstanding[j] == [a.identifier, b.identifier] }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [aOnK, b] + Self.laterFillers(seed + 6_000), tag: "v3-run-moved-before-\(seed)", s, visit: visit)
        await s.harness.source.release(j, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            visit == .sweepFollowsFirst ? e.state.jobs[j]?.attemptEnd?.deferredAfter != nil : e.state.jobs[j] == nil
        }
        if visit == .sweepFollowsFirst {
            let movedBefore = await engine.readForTests { $0.state.jobs[j]?.attemptEnd?.movedBefore }
            try #require(movedBefore == [a.identifier], "setup: J's verdict waits, zz-a moved off J before it (visit-first): \(String(describing: movedBefore))")
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [a, b] + Self.laterFillers(seed + 9_000), tag: "v4-run-moved-before-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        let outcome = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: sync) }
        let report: SyncReport? = switch outcome {
        case .completeWithFailures(let report), .complete(let report):
            report
        default:
            nil
        }
        #expect(report?.fetched == 1, "the run fetches zz-a with content j's next attempt (visit-first): \(outcome)")
        #expect(report?.failures.map(\.id) == [b.identifier] && report?.failures.first?.error == .notFound, "the run fails zz-b with J's 404: \(outcome)")
        await Self.finishHeld(s)
    }
}
