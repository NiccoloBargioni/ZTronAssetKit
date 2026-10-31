import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Where an id's interest is when an attempt ends while a follow is owed and a later apply moves the id again (Stage 3
/// close-out cycle 17; the cycle-16 correctness verifier's PROBE-C16C-VERDICT-MAPPED-BACK, PROBE-C16C-INTERMEDIATE-HOP and
/// PROBE-C16C-INTERMEDIATE-HOP-SERVED). A visit-first engine's visits moved the interest at each apply, so the attempt's
/// outcome met it where the applies before the attempt's end had put it, and an apply after the end met the job the
/// outcome left. Behind the barrier the visits come later and compare with the copy as it stands then: an interest moved
/// back to the content whose verdict waits was answered by that verdict, and one moved on past a content whose attempt
/// ended skipped that content's outcome. Each test runs in both orders (`LaneDropVisit`) with the visit-first outcome
/// expected in both.
extension EngineFollowBarrierTests {
    /// When `mappedBack`'s C is visited for v3, behind the barrier.
    enum MappedBackVisit: Sendable, CaseIterable {
        /// After C's 404 (PROBE-C16C-VERDICT-MAPPED-BACK): the verdict's set holds zz-b, which v4 maps back to C's
        /// content before the visit.
        case afterVerdict
        /// Before C's 404, while v3's follow is still owed: the visit moved B onto N, and v4's visit of N moves B back.
        case beforeVerdict
    }

    /// C (100 kB: zz-a and zz-b, a user waiter each) downloads; v3 moves zz-b to N (16 B, held). C gets a 404 while v3's
    /// follow is owed, so behind the barrier its verdict waits; C is visited for v3 after the 404 or before it (`when`).
    /// v4 then maps zz-b back to C's content. Visited first, v3's visit moved B onto N while C downloaded, C's 404
    /// answered A alone and removed C, and v4's visit superseded N and moved B to a fresh job of C's content, whose
    /// download (C's next scripted step) served B. Returns the answers of A and B.
    @available(macOS 15.0, iOS 18.0, *)
    func mappedBack(_ visit: LaneDropVisit, seed: UInt64, when: MappedBackVisit) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>) {
        let (s, _) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        // v3 moves zz-b to N.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-back-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst, when == .beforeVerdict {
            try await Self.runFollowTurns(engine, until: { $0.state.jobs[a.transferID]?.assets.contains(b.identifier) == false }, "v3's visit moves B onto N while the follow is still owed")
        }
        // C's 404.
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            let holds = await engine.readForTests { $0.state.jobs[a.transferID]?.assets.contains(b.identifier) == true }
            try #require(holds == (when == .afterVerdict), "setup: C holds zz-b at its 404 only when its visit comes after it")
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        }
        // v4 maps zz-b back to C's content. Once v3's visits ran (`.beforeVerdict`), v4's follow ends in its apply's own
        // turn, so its visit of N comes before C's verdict in both orders.
        try await Self.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-back-\(seed)", s, visit: when == .beforeVerdict ? .followVisitedFirst : visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (aResult, bResult)
    }

    /// An id a later apply maps back to the content whose verdict waits joins that content after the verdict, not before
    /// it (`mappedBack`; PROBE-C16C-VERDICT-MAPPED-BACK, `takeOffMovedBefore`, and the join a visit makes onto a job whose
    /// verdict waits, `addInterest`): visited first, the 404 answered A alone, and B, moved back by v4 after it, was
    /// served by a fresh job of C's content.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: an id an apply maps back to a content whose verdict waits joins it after the verdict (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, MappedBackVisit.allCases)
    func barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits(_ visit: LaneDropVisit, _ when: MappedBackVisit) async throws {
        let outcome = try await self.mappedBack(visit, seed: 1_616_902, when: when)
        #expect(outcome.a == .failure(.notFound), "A gets C's 404 (visit-first): \(outcome.a)")
        #expect((try? outcome.b.get())?.byteSize == 100_000, "B was on N at C's 404, and v4 moved it back to a fresh job of C's content, which serves it (visit-first): \(outcome.b)")
    }

    /// How N's attempt ends in `intermediateHop`.
    enum HopEnding: Sendable, CaseIterable {
        /// A 404 whose verdict waits for v3's follow (PROBE-C16C-INTERMEDIATE-HOP).
        case notFound
        /// Its download completes and N publishes (PROBE-C16C-INTERMEDIATE-HOP-SERVED).
        case published
    }

    /// C (100 kB, zz-b; a user waiter B) and N (16 B, zz-p; a user waiter P) download. v3 moves zz-b onto N's content;
    /// N's attempt ends (`ending`) while v3's follow is owed; v4 then moves zz-b on to M (48 B) before the follow visits
    /// C. Visited first, v3's visit superseded C and moved B onto N while N downloaded, so N's attempt's outcome was B's:
    /// its 404 answered P and B `notFound`, its publication served both N's 16 bytes; v4 moved nobody. Returns the answers
    /// of B and P.
    @available(macOS 15.0, iOS 18.0, *)
    func intermediateHop(_ visit: LaneDropVisit, seed: UInt64, ending: HopEnding) async throws -> (b: Result<AssetLocation, AssetError>, p: Result<AssetLocation, AssetError>) {
        let (s, _) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let mBytes = EngineFixture.bytes(seed + 7, count: 48)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bToN = EngineHarness.onDemand("zz-b", nBytes)
        let bToM = EngineHarness.onDemand("zz-b", mBytes)
        try #require(p.transferID == bToN.transferID && b.transferID != p.transferID && bToM.transferID != p.transferID && bToM.transferID != b.transferID, "setup: three contents")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, p] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .stage(cBytes)])
        switch ending {
        case .notFound:
            await s.harness.source.script(p.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(nBytes)])
        case .published:
            await s.harness.source.script(p.transferID, [.hold, .stage(nBytes)])
        }
        await s.harness.source.script(bToM.transferID, [.stage(mBytes)])
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        // v3 moves zz-b onto N's content.
        try await Self.applyHeld([s.q] + fillers + [bToN, p] + later, tag: "v3-hop-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            await engine.awaitCondition { $0.state.jobs[b.transferID] == nil && $0.state.jobs[p.transferID]?.interests.count == 2 }
        }
        if visit == .sweepFollowsFirst {
            let holds = await engine.readForTests { $0.followOwed && $0.state.jobs[b.transferID]?.assets.contains(b.identifier) == true }
            try #require(holds, "setup: v3's follow still owes C's visit when N's attempt ends")
        }
        // N's attempt ends.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        let pResult: Result<AssetLocation, AssetError>?
        switch ending {
        case .notFound:
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil }
            } else {
                await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
            }
            pResult = nil
        case .published:
            pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        }
        // v4 moves zz-b on to M.
        try await Self.applyHeld([s.q] + fillers + [bToM, p] + later, tag: "v4-hop-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pAnswer: Result<AssetLocation, AssetError>
        if let pResult {
            pAnswer = pResult
        } else {
            pAnswer = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (bResult, pAnswer)
    }

    /// An interest an apply moved onto a content whose attempt then ended while the follow was owed gets that attempt's
    /// outcome, though a later apply moved its id on before the follow visited its old job (`intermediateHop`;
    /// PROBE-C16C-INTERMEDIATE-HOP and -SERVED, `bringInbound`): visited first, B was on N when N's attempt ended.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: an interest an apply moved onto a content gets the outcome of the attempt that ends there, though a later apply moves it on (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, HopEnding.allCases)
    func barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent(_ visit: LaneDropVisit, _ ending: HopEnding) async throws {
        let outcome = try await self.intermediateHop(visit, seed: ending == .notFound ? 1_617_202 : 1_617_302, ending: ending)
        switch ending {
        case .notFound:
            #expect(outcome.p == .failure(.notFound), "P gets N's 404 (visit-first): \(outcome.p)")
            #expect(outcome.b == .failure(.notFound), "B was on N at its 404 (visit-first): \(outcome.b)")
        case .published:
            #expect((try? outcome.p.get())?.byteSize == 16, "P is served N (visit-first): \(outcome.p)")
            #expect((try? outcome.b.get())?.byteSize == 16, "B was on N when it published, and is served N's content (visit-first): \(outcome.b)")
        }
    }
}
