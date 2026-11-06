import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probe (s3f close-out verification, cycle 19, requirements lens). Never committed.
///
/// PROBE-C19R-LEGACY-TARGET: the draft's "Not reached by a test (cycle 19)" says no path leaves a checksum-less
/// content's id on another job while that content's job runs, so `findInbound`'s `byIdentifier` branches (a target and a
/// listed entry without a checksum) are unreached. Shape: T (zz-x's legacy entry, no checksum, 16 bytes) has a user
/// waiter A and publishes, held at its first store unit. v3 maps zz-x to C (checksummed, 100 kB) and is visited in full:
/// T's visit passes T, publishing, so A stays on T. B's request for zz-x then joins H (C's job), which downloads (held).
/// v3b changes only the leading fillers (sweep-first: the follow owes its scans when v4 lands, so v4's apply walks and
/// leaves its first follow turn to the held follow-up, and H stays unvisited). v4 maps zz-x back to T's legacy entry; v5
/// changes only the later fillers. Sweep-first, v5's walk under v4's copy finds H holding zz-x, which v4 maps to T's
/// checksum-less content: `byIdentifier` keys both (`EngineFollow.swift:1049`, `:1095`), and the walk records the move
/// H -> T [zz-x]. Visited first, v4's visit superseded H and joined B to T, publishing, so T's publication answers A and
/// B, and T's content starts once. `followUpsFirst` releases the owed follow-ups before or after T's publication resumes.
/// Each drop-mutant of the two lookups (`byIdentifierTargetDrop`, `byIdentifierLookupDrop`) fails the walk's expectation
/// 2/2 in both `followUpsFirst` cases; the answers agree under both mutants.
@Suite("VerifyC19ReqsLegacy", .serialized)
struct VerifyC19ReqsLegacy {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias T = EngineFollowBarrierTests

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C19R-LEGACY-TARGET", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [false, true])
    func legacyTarget(_ visit: LaneDropVisit, followUpsFirst: Bool) async throws {
        let seed: UInt64 = 1_919_902
        let tuning = SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 2)
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 16)
        let cBytes = EngineFixture.bytes(seed + 5, count: 100_000)
        let lx = EngineFixture.entry("zz-x", tBytes, policy: .onDemand, checksum: false)
        let xOnC = EngineHarness.onDemand("zz-x", cBytes)
        try #require(lx.checksum == nil && lx.transferID != xOnC.transferID, "setup: zz-x on a checksum-less content, then on C")
        let fillers = FollowBarrier.fillers(seed + 200)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [lx] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        print("PROBE-C19R-LEGACY-TARGET \(visit) step: v2 synced")
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // A second attempt of T's content gets the same bytes, so an extra request shows as a start, not a hang.
        await s.harness.source.script(lx.transferID, [.hold, .stage(tBytes), .stage(tBytes)])
        await s.harness.source.script(xOnC.transferID, [.hold, .stage(cBytes)])
        print("PROBE-C19R-LEGACY-TARGET \(visit) step: scripted")
        let aWaiter = Task { await engine.awaitAsset(lx.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[lx.transferID]?.state == .downloading }
        }
        print("PROBE-C19R-LEGACY-TARGET \(visit) step: T downloading")
        // T's publication begins, held at its first store unit.
        let releaser = try await T.holdPublication(of: lx.transferID, s, bulk: bulk)
        print("PROBE-C19R-LEGACY-TARGET \(visit) step: T publication held")
        // v3 maps zz-x to C and is visited in full: T's visit passes T, publishing; A stays on T.
        try await T.applyHeld([s.q] + fillers + [xOnC] + T.laterFillers(seed + 6_000), tag: "v3-legacy-\(seed)", s, visit: .followVisitedFirst)
        print("PROBE-C19R-LEGACY-TARGET \(visit) step: v3 applied")
        let bWaiter = Task { await engine.awaitAsset(xOnC.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[xOnC.transferID]?.state == .downloading }
        }
        let both = await engine.readForTests { e in
            (t: e.state.jobs[lx.transferID]?.assets, tState: e.state.jobs[lx.transferID]?.state, h: e.state.jobs[xOnC.transferID]?.assets, hState: e.state.jobs[xOnC.transferID]?.state)
        }
        print("PROBE-C19R-LEGACY-TARGET \(visit) after v3 and B's request: \(both)")
        try #require(both.t == [lx.identifier] && both.tState == .verifying && both.h == [lx.identifier], "setup: zz-x is on T, publishing, and on H, downloading: \(both)")
        // v4 maps zz-x back to T's checksum-less content; v5 changes only the later fillers, both while T publishes.
        let diag: @Sendable (String) async -> Void = { label in
            let text = await engine.readForTests { e in
                let jobs = e.state.jobs.map { "\($0.key == lx.transferID ? "T" : $0.key == xOnC.transferID ? "H" : "\($0.key)"): \($0.value.state) \($0.value.assets.sorted()) visit=\(String(describing: e.rerouteOnVisit($0.value)))" }.sorted()
                let unfollowedH = e.state.unfollowed.contains(xOnC.transferID)
                let unfollowedT = e.state.unfollowed.contains(lx.transferID)
                return "owed=\(e.followOwed) unfollowed=\(e.state.unfollowed.count) H-unfollowed=\(unfollowedH) T-unfollowed=\(unfollowedT) followNext=\(e.state.followNext)/\(e.state.followOrder.count) inFlight=\(e.state.inFlight.map { $0 == lx.transferID ? "T" : $0 == xOnC.transferID ? "H" : "other" }) moves=\(e.state.inboundMoves.count) next=\(e.state.inboundNext) jobs=\(jobs)"
            }
            print("PROBE-C19R-LEGACY-TARGET \(visit) \(label): \(text)")
        }
        // v3b changes only the leading fillers, so (sweep-first) the follow owes its scans when v4 lands: v4's apply walks
        // (T publishes) and leaves its follow's first turn to the held follow-up, so H stays unvisited for v5's walk.
        let fillersB = FollowBarrier.fillers(seed + 300)
        try await T.applyHeld([s.q] + fillersB + [xOnC] + T.laterFillers(seed + 6_000), tag: "v3b-legacy-\(seed)", s, visit: visit)
        await diag("after v3b")
        try await T.applyHeld([s.q] + fillersB + [lx] + T.laterFillers(seed + 9_000), tag: "v4-legacy-\(seed)", s, visit: visit)
        await diag("after v4")
        try await T.applyHeld([s.q] + fillersB + [lx] + T.laterFillers(seed + 12_000), tag: "v5-legacy-\(seed)", s, visit: visit)
        await diag("after v5")
        var owed: [String] = []
        if visit == .sweepFollowsFirst {
            owed = await engine.readForTests { e in
                e.state.inboundMoves[e.state.inboundNext...].map { "\($0.holder) -> \($0.target): \($0.ids.sorted())" }
            }
            let atWalk = await engine.readForTests { e in
                e.state.inboundMoves[e.state.inboundNext...].contains { $0.holder == xOnC.transferID && $0.target == lx.transferID && $0.ids == [lx.identifier] }
            }
            print("PROBE-C19R-LEGACY-TARGET \(visit) moves owed after v5's walk: \(owed)")
            #expect(atWalk, "v5's walk under v4's copy records H's zz-x onto T's checksum-less content (byIdentifier): \(owed)")
        }
        // T's publication resumes; the owed follow-ups are released before or after it.
        if followUpsFirst, visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if !followUpsFirst, visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let tStarts = await s.harness.source.starts.filter { $0.id == lx.transferID }.count
        let hStarts = await s.harness.source.starts.filter { $0.id == xOnC.transferID }.count
        print("PROBE-C19R-LEGACY-TARGET \(visit) followUpsFirst \(followUpsFirst): A \(aResult), B \(bResult), tStarts \(tStarts), hStarts \(hStarts)")
        #expect((try? aResult.get()) != nil, "T's publication answers A (visit-first): \(aResult)")
        #expect((try? bResult.get()) != nil && bResult == aResult, "v4's visit joined B to T, publishing: T's publication answers B (visit-first): \(bResult) vs \(aResult)")
        #expect(tStarts == 1, "T's content starts once (visit-first): \(tStarts)")
        await T.finishHeld(s)
    }
}
