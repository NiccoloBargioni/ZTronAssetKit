import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The follow barrier's answers for a job whose retried attempt meets a follow (Stage 3 close-out cycle 15, ruling S3-R18
/// item 2). `Job.rerouteOnPass` is a property of one attempt's publication: it is set when the publication begins and
/// cleared when the next attempt starts. Each test runs in both orders (`LaneDropVisit`) with the visit-first outcome
/// expected in both.
extension EngineFollowBarrierTests {
    /// A later apply's follow passes again an id an earlier follow passed, when the job's retried publication still
    /// carries it: C (100 kB, the content of zz-a, zz-b and zz-c, a user waiter each) publishes when v3 moves zz-b to N
    /// (16 bytes), so v3's follow passes C with zz-b. C's verification read then fails (EIO), which the interactive
    /// policy retries; the retry downloads bytes that fail their checksum and publishes, and v4, applied while that
    /// second publication verifies, moves zz-c to N2 (24 bytes). Visited first, both follows passed C, publishing, so all
    /// three users were answered `integrityFailure`. The ids a publication re-routes on a pass are only those a
    /// visit-first engine's visit had moved before it began, at an owed follow's apply: none while no follow is owed, as
    /// when the retry's publication began. Counted then, zz-b, which v3's follow passed, was re-routed at v4's visit and
    /// served N.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a later apply's follow passes again the id an earlier follow passed when a retried publication carries it (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPassesAgainTheIdARetriedPublicationCarries(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_320_902
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let n2Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        let cMoved = EngineHarness.onDemand("zz-c", n2Bytes)
        try #require(a.transferID == b.transferID && a.transferID == c.transferID, "setup: zz-a, zz-b and zz-c share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, c] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        await s.harness.source.script(cMoved.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        let cWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 3 }
        // C's first publication begins before v3's apply: v3's follow passes C with zz-b in both orders.
        var releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, c] + later, tag: "v3-retried-pass-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let passed = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID))
        }
        #expect(passed.c == .verifying && passed.holdsB && passed.unfollowed, "setup: v3's follow passed C, publishing, with zz-b: \(passed)")
        releaser.cancel()
        await releaser.value
        // The held unit is the first chunk of C's hash: its read of the claimed staging file fails, and C is retried.
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await bulk.setHolding(false)
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
        }
        let retried = await engine.readForTests { e in
            (owed: e.followOwed, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID))
        }
        #expect(!retried.owed && retried.holdsB && retried.unfollowed, "setup: C's retry downloads with zz-b, which v3's follow passed, while no follow is owed: \(retried)")
        // C's retry publishes; v4 moves zz-c while that publication, begun while no follow was owed, verifies.
        releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, cMoved] + later, tag: "v4-retried-pass-\(seed)", s, visit: .followVisitedFirst)
        let passedAgain = await engine.readForTests { e in
            (
                c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true,
                holdsC: e.state.jobs[a.transferID]?.assets.contains(c.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID)
            )
        }
        #expect(passedAgain.c == .verifying && passedAgain.holdsB && passedAgain.holdsC && passedAgain.unfollowed, "v4's follow passed C's second publication with zz-b and zz-c (visit-first): \(passedAgain)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let cResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: cWaiter) }
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: both follows passed C, publishing (visit-first): \(bResult)")
        #expect(cResult == .failure(.integrityFailure), "zz-c's user gets C's integrity failure: v4's follow passed C, publishing (visit-first): \(cResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    /// A retry's download that fails during an owed follow before the follow's visit is visited as a download, whatever
    /// an earlier attempt's publication did: C (100 kB, the content of zz-a and zz-b, a user waiter each) publishes while
    /// no follow is owed; its verification read fails (EIO), and C is retried. While the retry downloads, v3 moves zz-b
    /// to N (16 bytes); then the retry gets a 404. Visited first, v3's visit moved B onto N while C downloaded, so B was
    /// served N and A answered `notFound`. Behind the barrier the 404 arrives before the follow's turn that finds C, and
    /// its verdict waits: the visit must meet C as a failed download, not as a passed publication, which it would were
    /// the first publication's `Job.rerouteOnPass` kept across the retry's start (`VerdictAfterFollow.published`); B
    /// would then share C's 404.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a retry's 404 during an owed follow before its visit answers a moved id with its new content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierVisitsARetryThatFailsBeforeItsVisitAsADownload(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_321_102
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        let published = await engine.readForTests { e in (owed: e.followOwed, ids: e.state.jobs[a.transferID]?.rerouteOnPass) }
        #expect(!published.owed && published.ids == [], "setup: C's first publication began while no follow was owed: \(published)")
        releaser.cancel()
        await releaser.value
        // The held unit is the first chunk of C's hash: its read of the claimed staging file fails, and C is retried.
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await bulk.setHolding(false)
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved] + Self.laterFillers(seed + 6_000), tag: "v3-retry-404-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            // Visited first, C's visit moved B onto N at the apply; N is served before C's 404 arrives.
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID] == nil }
            }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            let unvisited = await engine.readForTests { e in
                (
                    owed: e.followOwed, found: e.state.followOrder.contains(a.transferID), holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true,
                    published: e.state.verdictsAfterFollow[a.transferID]?.published
                )
            }
            #expect(unvisited.owed && !unvisited.found && unvisited.holdsB, "setup: C's 404 arrived before the follow's turn that finds C: \(unvisited)")
            #expect(unvisited.published == false, "the waiting verdict is a download's, not a publication's: \(unvisited)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect(aResult == .failure(.notFound), "A gets C's 404 (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N, the content v3 maps zz-b to (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }
}
