import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 17, requirements lens). Never committed.
@Suite("VerifyC17ReqsProbes", .serialized)
struct VerifyC17ReqsProbes {
    typealias T = EngineFollowBarrierTests

    /// PROBE-C17R-RR14-PUBLICATION-HOP: the draft's RR-14 ("an interest moved onto a publishing job's content by one apply
    /// and on by the next, while the publication runs, skips that publication's failure"; an answer difference by the
    /// fixer's own analysis, not probed there). C (100 kB, zz-b; a user waiter B) downloads; N (16 B, zz-p; a user waiter
    /// P) downloads bytes that fail their checksum and publishes, held at its first store unit. v3 then moves zz-b onto
    /// N's content, and v4 moves it on to M (48 B), both while N's publication is held. N's publication then fails its
    /// integrity check.
    /// Visit-first: v3's visit superseded C and joined B to N's publication; v4's visit passed N (its publication began
    /// before the apply), so N's integrity failure answered P and B `integrityFailure`.
    /// Sweep-first: `bringInbound` ran at N's publication start, before v3; nothing brings B onto N afterwards, and the
    /// owed visit of C, comparing with v4's copy, moves B straight to M, which serves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17R-RR14-PUBLICATION-HOP", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func rr14PublicationHop(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_717_002
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let nWrong = EngineFixture.bytes(seed + 9, count: 16)
        let mBytes = EngineFixture.bytes(seed + 7, count: 48)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bToN = EngineHarness.onDemand("zz-b", nBytes)
        let bToM = EngineHarness.onDemand("zz-b", mBytes)
        try #require(p.transferID == bToN.transferID && b.transferID != p.transferID && bToM.transferID != p.transferID && bToM.transferID != b.transferID && nWrong != nBytes, "setup: three contents")
        let fillers = T.FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + T.FollowBarrier.fillers(seed + 100) + [b, p] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .stage(nWrong)])
        await s.harness.source.script(bToM.transferID, [.stage(mBytes)])
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        // N's (bad) bytes arrive and its publication begins, held at its first store unit, before either apply.
        let releaser = try await T.holdPublication(of: p.transferID, s, bulk: bulk)
        // v3 moves zz-b onto N's content.
        try await T.applyHeld([s.q] + fillers + [bToN, p] + later, tag: "v3-rr14-\(seed)", s, visit: visit)
        let afterV3 = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[b.transferID].map { "\($0.state)" } ?? "nil", n: e.state.jobs[p.transferID].map { "\($0.state)" } ?? "nil", nHoldsB: e.state.jobs[p.transferID]?.assets.contains(b.identifier) == true, nInterests: e.state.jobs[p.transferID]?.interests.count ?? 0)
        }
        print("PROBE-C17R-RR14 \(visit) after v3: \(afterV3)")
        if visit == .sweepFollowsFirst {
            try #require(afterV3.owed && afterV3.c == "downloading", "setup: v3's follow still owes C's visit: \(afterV3)")
        } else {
            try #require(afterV3.nHoldsB, "setup: visited first, v3's visit joined B to N's publication: \(afterV3)")
        }
        // v4 moves zz-b on to M while N's publication is still held.
        try await T.applyHeld([s.q] + fillers + [bToM, p] + later, tag: "v4-rr14-\(seed)", s, visit: visit)
        let afterV4 = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[b.transferID].map { "\($0.state)" } ?? "nil", n: e.state.jobs[p.transferID].map { "\($0.state)" } ?? "nil", nHoldsB: e.state.jobs[p.transferID]?.assets.contains(b.identifier) == true, nInterests: e.state.jobs[p.transferID]?.interests.count ?? 0)
        }
        print("PROBE-C17R-RR14 \(visit) after v4: \(afterV4)")
        // N's publication resumes and fails its integrity check.
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            // Behind the barrier N's exit verdict waits for the follow (`defersFailure`); then the follow may end.
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil || $0.state.jobs[p.transferID] == nil }
            }
            let atFailure = await engine.readForTests { e in
                (owed: e.followOwed, waits: e.state.verdictsAfterFollow[p.transferID] != nil, nHoldsB: e.state.jobs[p.transferID]?.assets.contains(b.identifier) == true, bOn: e.state.waiters.values.filter { $0.asset == b.identifier }.map(\.transfer))
            }
            print("PROBE-C17R-RR14 \(visit) at N's failure: \(atFailure)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let mStarts = await s.harness.source.starts.filter { $0.id == bToM.transferID }.count
        print("PROBE-C17R-RR14 \(visit) p=\(pResult) b=\(bResult) mStarts=\(mStarts)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
        #expect(pResult == .failure(.integrityFailure), "PROBE-C17R-RR14: P gets N's integrity failure (visit-first): \(pResult)")
        #expect(bResult == .failure(.integrityFailure), "PROBE-C17R-RR14: B was joined to N's publication at v3 and passed by v4's visit, so N's integrity failure answers it (visit-first): \(bResult); mStarts \(mStarts)")
    }

    /// PROBE-C17R-NARROWED-REROUTE: kills `rerouteOnPassKeepWhole`, which keeps `Job.rerouteOnPass` whole in
    /// `recordDeferredVerdict`'s second branch (cycle 17 narrows it to `movedBefore`, `5843c41`). The committed
    /// `publicationMappedBack` scenario (MovedBeforeTests) plus one apply: C (100 kB: zz-a and zz-b, a user waiter each)
    /// publishes bytes that fail their checksum; v3 moves zz-b to N (16 B, held); C's publication begins while v3's follow
    /// owes C's visit (`rerouteOnPass` [zz-b]); v4 maps zz-b back; the publication fails with no apply since, and behind
    /// the barrier its integrity verdict waits. Then v5 moves zz-b to N again, before the follow visits C.
    /// Visit-first: v4's visit joined B to C publishing, and C's integrity failure answered A and B; v5 moves nobody.
    /// Sweep-first: the narrowed set is empty, so the owed visit (v5's pass finds C) passes zz-b to the verdict, which
    /// answers B `integrityFailure`. Kept whole, the visit re-routes B to N before the verdict, and N serves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17R-NARROWED-REROUTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func narrowedReroute(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_717_102
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + T.FollowBarrier.fillers(seed + 100) + [a, b] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong), .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let fillers = T.FollowBarrier.fillers(seed + 200)
        let later = T.laterFillers(seed + 6_000)
        // v3 moves zz-b to N.
        try await T.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-narrow-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
        }
        let releaser = try await T.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            let atPublish = await engine.readForTests { e in (owed: e.followOwed, reroute: e.state.jobs[a.transferID]?.rerouteOnPass) }
            print("PROBE-C17R-NARROWED \(visit) at publish: \(atPublish)")
            try #require(atPublish.owed && atPublish.reroute == [b.identifier], "setup: C's publication began while v3's follow owed C's visit: \(atPublish)")
        }
        // v4 maps zz-b back while (behind the barrier) v3's follow still owes C's visit.
        try await T.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-narrow-\(seed)", s, visit: visit)
        // The publication fails its checksum.
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            let waiting = await engine.readForTests { e in (owed: e.followOwed, end: e.state.jobs[a.transferID]?.attemptEnd, reroute: e.state.jobs[a.transferID]?.rerouteOnPass) }
            print("PROBE-C17R-NARROWED \(visit) at the deferral: \(waiting)")
            try #require(waiting.owed && waiting.end?.deferredAfter != nil && waiting.end?.failedAfter == waiting.end?.deferredAfter, "setup: the verdict waits with no apply since the publication's end: \(waiting)")
        } else {
            _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        }
        // v5 moves zz-b to N again, before (behind the barrier) the follow visits C. Applied as `applyHeld` applies, without
        // its expectation that the follow is still owed after the apply's turn: v5's own turn may visit C and end it.
        let v5 = try ValidatedManifest(entries: [s.q] + fillers + [a, bMoved] + later, digest: ContentHash.sha256(of: Data("v5-narrow-\(seed)".utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        let appliedV5 = await engine.applyAndFollow(v5, etag: nil, eviction: nil)
        try #require((try? appliedV5.get()) != nil, "setup: v5 is applied: \(appliedV5)")
        let afterV5 = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID].map { "\($0.state)" } ?? "nil", n: e.state.jobs[bMoved.transferID].map { "\($0.state)" } ?? "nil") }
        print("PROBE-C17R-NARROWED \(visit) after v5's turn: \(afterV5)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        // If B waits on N's held download, let N serve it.
        let nDownloading = await engine.readForTests { $0.state.jobs[bMoved.transferID]?.state == .downloading }
        if nDownloading {
            await s.harness.source.release(bMoved.transferID, with: .progress(received: 0, expected: nil))
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C17R-NARROWED \(visit) a=\(aResult) b=\(bResult) nDownloadingAfterBarrier=\(nDownloading)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await T.finishHeld(s)
        #expect(aResult == .failure(.integrityFailure), "PROBE-C17R-NARROWED: A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "PROBE-C17R-NARROWED: B was back on C, publishing, at its integrity failure (visit-first): \(bResult)")
    }
}
