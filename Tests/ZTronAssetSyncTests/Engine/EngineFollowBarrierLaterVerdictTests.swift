import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The visit after a verdict joins onto a job whose own verdict waits later in the queue (Stage 3 close-out cycle 21,
/// ruling S3-R26 item 12's answer 5, candidate 4; `integrate-c21.md`'s residual risks). Each runs in both orders
/// (`LaneDropVisit`) and expects the visit-first answers in both.
extension EngineFollowBarrierTests {
    // MARK: Item 12's answer 5, candidate 4: the visit after a verdict joins onto a job whose verdict waits later

    /// When J2's 404 arrives relative to the apply that maps the ids to J2's content (`barrierJoinsTheVisitAfterAVerdictAsVisitedFirst`).
    enum AfterVerdictShape: String, Sendable, CaseIterable {
        /// J2's 404 waits from v3's follow, as J1's verdict does; v4 then maps zz-m to J2's content (candidate 4).
        case sameFollow
        /// v4 maps zz-m to J2's content, then J2's 404 arrives while v4's follow is owed: it defers under v4's copy.
        case afterTheApply
        /// J2's 404 arrives while v4's follow is owed, and v5 then maps zz-m to J2's content.
        case beforeTheApply
        /// `afterTheApply` with ten ids on J1 and four ids a turn: the rest of the drain's visit joins most of them.
        case afterTheApplyRest
        /// `beforeTheApply` with ten ids on J1 and four ids a turn.
        case beforeTheApplyRest

        /// Whether the ids join J2 before its 404 on a visit-first engine, which then answers them `.notFound`.
        var joinsBeforeTheVerdict: Bool {
            self == .afterTheApply || self == .afterTheApplyRest
        }

        /// Whether J1 holds ten ids, moved four a turn.
        var rest: Bool {
            self == .afterTheApplyRest || self == .beforeTheApplyRest
        }

        var seed: UInt64 {
            switch self {
            case .sameFollow:
                2_021_701
            case .afterTheApply:
                2_021_711
            case .beforeTheApply:
                2_021_721
            case .afterTheApplyRest:
                2_021_731
            case .beforeTheApplyRest:
                2_021_741
            }
        }
    }

    /// J1 (the zz-m ids' content) and J2 (zz-n's) download for prefetch waiters while v3's follow is owed; J1's attempt
    /// times out, its verdict waiting, and J2's gets a 404. A later apply maps the zz-m ids to J2's content. Swept first,
    /// the drain gives J1's verdict, and its visit (`followAfterVerdict`) moves the ids onto J2, whose verdict waits later
    /// in the queue. Visited first, each verdict was given at its arrival, and the apply's visit of J1 met J2 as it was
    /// then: with `sameFollow` and `beforeTheApply`, J2's 404 had answered zz-n and ended J2 before the apply, whose visit
    /// made a new job of J2's content for the ids, which fetched them; with `afterTheApply`, the visit joined them to J2
    /// downloading, and J2's 404 answered them too. Until close-out cycle 21 the drain's visit joined them to J2 at once
    /// (`EngineJobs.swift:117` deferred only a follow's visit's joins), so J2's 404 answered them in every shape.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the visit after a verdict joins its moved ids behind a verdict that waits later, or at once, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, AfterVerdictShape.allCases)
    func barrierJoinsTheVisitAfterAVerdictAsVisitedFirst(_ visit: LaneDropVisit, _ shape: AfterVerdictShape) async throws {
        let seed = shape.seed
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let j1Bytes = EngineFixture.bytes(seed + 3, count: 16)
        let j2Bytes = EngineFixture.bytes(seed + 4, count: 20)
        let names = shape.rest ? (0..<10).map { String(format: "zz-m%02d", $0) } : ["zz-m"]
        let onJ1 = names.map { EngineHarness.onDemand($0, j1Bytes) }
        let onJ2 = names.map { EngineHarness.onDemand($0, j2Bytes) }
        let n = EngineHarness.onDemand("zz-n", j2Bytes)
        let j1 = onJ1[0].transferID
        let j2 = n.transferID
        try #require(onJ2.allSatisfy { $0.transferID == j2 } && j1 != j2, "setup: the later apply maps the zz-m ids to J2's content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onJ1 + [n] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(j1, [.hold, .fail(.transient(.timedOut, retryAfter: nil)), .hold])
        await s.harness.source.script(j2, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(j2Bytes)])
        let wm = onJ1.map { entry in Task { await engine.awaitAsset(entry.identifier, lane: .prefetch) } }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[j1]?.state == .downloading && $0.state.jobs[j1]?.interests.count == names.count }
        }
        let wn = Task { await engine.awaitAsset(n.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[j2]?.state == .downloading }
        if shape.rest {
            await engine.readForTests { $0.state.followIDsPerTurn = 4 }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onJ1 + [n] + Self.laterFillers(seed + 6_000), tag: "v3-after-verdict-\(seed)", s, visit: visit)
        await s.harness.source.release(j1, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            if visit == .sweepFollowsFirst {
                return e.state.jobs[j1]?.attemptEnd?.deferredAfter != nil
            }
            if case .failed = e.state.jobs[j1]?.state { return true }
            return false
        }
        let moving = [s.q] + FollowBarrier.fillers(seed + 300) + onJ2 + [n] + Self.laterFillers(seed + 9_000)
        switch shape {
        case .sameFollow:
            try await self.failJ2(j2, s, visit: visit)
            try await Self.applyHeld(moving, tag: "v4-after-verdict-\(seed)", s, visit: visit)
        case .afterTheApply, .afterTheApplyRest:
            try await Self.applyHeld(moving, tag: "v4-after-verdict-\(seed)", s, visit: visit)
            try await self.failJ2(j2, s, visit: visit)
        case .beforeTheApply, .beforeTheApplyRest:
            try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + onJ1 + [n] + Self.laterFillers(seed + 9_000), tag: "v4-after-verdict-\(seed)", s, visit: visit)
            try await self.failJ2(j2, s, visit: visit)
            try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 400) + onJ2 + [n] + Self.laterFillers(seed + 12_000), tag: "v5-after-verdict-\(seed)", s, visit: visit)
        }
        if visit == .sweepFollowsFirst {
            let waiting = await engine.readForTests { e in
                (
                    order: e.state.eventsAfterFollow.compactMap { event -> TransferID? in
                        if case .attemptFailed(let transfer, _, _) = event { return transfer }
                        return nil
                    },
                    onJ1: e.state.jobs[j1]?.assets.count ?? 0
                )
            }
            try #require(waiting.order == [j1, j2] && waiting.onJ1 == names.count, "setup: J1's verdict waits ahead of J2's, with the zz-m ids on J1: \(waiting)")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let nResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wn) }
        #expect(nResult == .failure(.notFound), "zz-n gets J2's 404: \(nResult)")
        for (entry, waiter) in zip(onJ1, wm) {
            let mResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            if shape.joinsBeforeTheVerdict {
                #expect(mResult == .failure(.notFound), "\(entry.identifier), joined to J2 before its 404 (visit-first), gets it: \(mResult)")
            } else {
                #expect((try? mResult.get())?.byteSize == Int64(j2Bytes.count), "\(entry.identifier), moved after J2's 404 (visit-first), is fetched by a new job of J2's content: \(mResult)")
            }
        }
        await Self.finishHeld(s)
    }

    /// Releases J2's held attempt into its 404 and waits for its verdict: deferred swept first, given visited first.
    @available(macOS 15.0, iOS 18.0, *)
    private func failJ2(_ j2: TransferID, _ s: FollowBarrier.Setup, visit: LaneDropVisit) async throws {
        await s.harness.source.release(j2, with: .progress(received: 0, expected: nil))
        await s.engine.awaitCondition { e in
            visit == .sweepFollowsFirst ? e.state.jobs[j2]?.attemptEnd?.deferredAfter != nil : e.state.jobs[j2] == nil
        }
    }
}
