import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A purge's withdrawal from one job (Stage 3 close-out cycle 22, ruling S3-R27 item 12.3, e2-A1.4): the job's purged
/// interests leave it in ascending token order, its lane read before each removal, and the job is settled as one removal
/// at a time settled it. A job a claim keeps holds the lane before its last removal (`Job.heldLane`; e2 review must-fix
/// 6); a job the purge empties was re-laned by its earlier removals when they lowered its lane, before the last one
/// retired it or a claim kept it; a job left with interests is re-laned once, to the lane they leave it. Each case runs
/// on a transfer the fake source holds, so a priority change and a cancellation reach its control log.
@Suite("Engine purge withdrawal")
struct EnginePurgeWithdrawalTests {
    /// The groups registered on x's job, in token order, with the lane each registered at, and the claim of a group whose
    /// join is held, when `claimed`; the job in flight with every group's interest.
    @available(macOS 15.0, iOS 18.0, *)
    struct Setup {
        let harness: EngineHarness
        let job: TransferID
        let groups: [InterestToken]
        let claimant: InterestToken?
    }

    /// x's content in flight, with one group per `lanes` element registered on `members` in that order (so their
    /// tokens ascend), and, when `claimed`, a third group's pending claim on x, its join held (`recordGroup`).
    @available(macOS 15.0, iOS 18.0, *)
    static func setUp(seed: UInt64, members: [[AssetID]], lanes: [AssetPriority], claimed: Bool) async throws -> Setup {
        let bytes = EngineFixture.bytes(seed)
        let ids = Set(members.joined()).sorted()
        let entries = ids.map { EngineHarness.onDemand($0.rawValue, bytes) }
        let job = try #require(entries.first?.transferID)
        try #require(entries.allSatisfy { $0.transferID == job }, "setup: every id shares x's content")
        let harness = try await EngineGroupClaimTests.started(entries)
        let engine = harness.engine
        var groups: [InterestToken] = []
        for (ids, lane) in zip(members, lanes) {
            groups.append(try await engine.registerGroup(ids, lane: lane).get())
        }
        try #require(groups == groups.sorted(), "setup: the groups' tokens ascend in registration order")
        let all = groups
        await engine.awaitCondition { engine in
            EngineGroupClaimTests.inFlight(job, engine) && all.allSatisfy { engine.state.jobs[job]?.interests[$0] != nil }
        }
        let claimant = claimed ? await engine.inOneTurn { $0.recordGroup(["x"], lane: .prefetch).token } : nil
        return Setup(harness: harness, job: job, groups: groups, claimant: claimant)
    }

    /// Purges `scope`, and returns the job's controls the purge made (those after the setup's), whether a claim keeps the
    /// job, its lane and held lane, and the engine's invariants.
    @available(macOS 15.0, iOS 18.0, *)
    static func purge(_ ids: [AssetID], _ s: Setup) async -> (controls: [TransferControl], held: Bool, lane: AssetPriority?, heldLane: AssetPriority?, violations: [String]) {
        let engine = s.harness.engine
        let before = await EngineGroupClaimTests.controls(of: s.job, s.harness).count
        let purged = await s.harness.withClock { await engine.purge(.scope(.identifiers(Set(ids)))) }
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        let controls = Array(await EngineGroupClaimTests.controls(of: s.job, s.harness).dropFirst(before))
        let job = s.job
        let state = await engine.readForTests { engine in
            (held: engine.state.claimHeld.values.contains(job), lane: engine.state.jobs[job]?.lane, heldLane: engine.state.jobs[job]?.heldLane, violations: engine.invariantViolations())
        }
        return (controls, state.held, state.lane, state.heldLane, state.violations)
    }

    /// Releases every group and shuts the engine down.
    @available(macOS 15.0, iOS 18.0, *)
    static func finish(_ s: Setup) async {
        let engine = s.harness.engine
        for token in s.groups + [s.claimant].compactMap({ $0 }) {
            await engine.releaseGroup(token)
        }
        await engine.waitForJobEnd(s.job)
        await engine.shutdown()
    }

    /// The ruling's case (e2 review must-fix 6, "must add" 2): t1's interest is `.bulk`, t2's `.prefetch`, both on x and
    /// both purged, and a claim keeps the job. Removed in ascending token order, t1 leaves the job at `.prefetch`, so the
    /// lane before the last removal, which the claim-held job keeps, is `.prefetch`; removed t2 first, it would be
    /// `.bulk`. Nothing re-lanes the job, so the purge makes no control.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge removes a job's interests in ascending token order, so the job a claim keeps holds the lane before the last removal (S3-R27 item 12.3, e2-A1.4)", .timeLimit(.minutes(1)))
    func purgeRemovesInAscendingTokenOrder() async throws {
        let s = try await Self.setUp(seed: 2_031_101, members: [["x"], ["x"]], lanes: [.bulk, .prefetch], claimed: true)
        let after = await Self.purge(["x"], s)
        #expect(after.held, "the claim keeps the job the purge emptied")
        #expect(after.heldLane == .prefetch && after.lane == .prefetch, "the job holds t2's lane, the lane before the last removal: \(String(describing: after.heldLane))")
        #expect(after.controls.isEmpty, "no removal changed the job's lane: \(after.controls)")
        #expect(after.violations.isEmpty, "\(after.violations)")
        await Self.finish(s)
    }

    /// t1's interest is `.prefetch`, t2's `.bulk`, both on x and both purged. Removed one at a time, t1's removal left the
    /// job t2 and re-laned it to `.bulk`, a priority change of its running transfer; t2's removal then emptied it, and a
    /// claim kept it at `.bulk`, or, with no claim, it was retired and its transfer cancelled. The purge's single settle
    /// keeps that re-lane (e2-A1.4).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge that empties a job whose earlier removals lowered its lane re-lanes it before the last removal, kept by a claim or retired (S3-R27 item 12.3, e2-A1.4)", .timeLimit(.minutes(1)), arguments: [true, false])
    func purgeThatEmptiesAJobKeepsItsEarlierRelane(claimed: Bool) async throws {
        let s = try await Self.setUp(seed: 2_031_111, members: [["x"], ["x"]], lanes: [.prefetch, .bulk], claimed: claimed)
        let after = await Self.purge(["x"], s)
        if claimed {
            #expect(after.held && after.heldLane == .bulk, "the claim keeps the job at the lane before the last removal: \(String(describing: after.heldLane))")
            #expect(after.controls == [.setPriority(.bulk)], "the first removal's re-lane reached the transport: \(after.controls)")
        } else {
            #expect(!after.held && after.lane == nil, "the emptied job is retired")
            #expect(after.controls == [.setPriority(.bulk), .cancel], "the first removal's re-lane, then the retirement's cancellation: \(after.controls)")
        }
        #expect(after.violations.isEmpty, "\(after.violations)")
        await Self.finish(s)
    }

    /// t1's interest is `.prefetch` and t2's `.bulk`, both on x, and t3's `.bulk`, on y, which shares x's content; the
    /// purge selects x only. Removed one at a time, t1's removal re-laned the job to `.bulk` and t2's changed nothing:
    /// one priority change. The single settle re-lanes the job once, from its lane before the first removal (e2-A1.4).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge that leaves a job interests re-lanes it once, to the lane they leave it (S3-R27 item 12.3, e2-A1.4)", .timeLimit(.minutes(1)))
    func purgeThatLeavesInterestsRelanesOnce() async throws {
        let s = try await Self.setUp(seed: 2_031_121, members: [["x"], ["x"], ["y"]], lanes: [.prefetch, .bulk, .bulk], claimed: false)
        let after = await Self.purge(["x"], s)
        #expect(after.lane == .bulk && !after.held, "t3 keeps the job, at its lane: \(String(describing: after.lane))")
        #expect(after.controls == [.setPriority(.bulk)], "one priority change: \(after.controls)")
        #expect(after.violations.isEmpty, "\(after.violations)")
        await Self.finish(s)
    }
}
