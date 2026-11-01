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
/// expected in both. The ENOSPC variants and the passed holder pin the same rules on the ENOSPC replay
/// (`spaceFailed`, `.spaceFailure`'s replay) and on a holder the owed visit passes (`rerouteOnVisit`).
extension EngineFollowBarrierTests {
    /// Changed on-demand entries that sort between `FollowBarrier.fillers` and the scenario's `zz-` ids: an ENOSPC's
    /// free-space read runs one follow turn (`advanceFollowForSpaceSweep`), which formats these and stops before the
    /// scenario's entries, so the follow still owes their visits when the verdict defers.
    @available(macOS 15.0, iOS 18.0, *)
    static func spaceReadFillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "g%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    /// Records an issue unless `result` is an `insufficientSpace` answer (its figures are not compared, S3-R16 1(a)).
    static func expectInsufficientSpace(_ result: Result<AssetLocation, AssetError>, _ comment: String) {
        if case .failure(.insufficientSpace) = result {
        } else {
            Issue.record("\(comment): \(result)")
        }
    }

    /// How C's attempt ends in `mappedBack`.
    enum MappedBackEnding: Sendable {
        /// A 404 (PROBE-C16C-VERDICT-MAPPED-BACK).
        case notFound
        /// An ENOSPC for 200 kB of C's second attempt, with 32 MB of room: the room is there after all, so the verdict
        /// retries, and the attempt reaches the user lane's cap of two (`shortInteractiveRetry`), which answers the
        /// interests C holds then (Stage 3 close-out cycle 17).
        case spaceAtCap
    }

    /// When `mappedBack`'s C is visited for v3, behind the barrier.
    enum MappedBackVisit: Sendable, CaseIterable {
        /// After C's 404 (PROBE-C16C-VERDICT-MAPPED-BACK): the verdict's set holds zz-b, which v4 maps back to C's
        /// content before the visit.
        case afterVerdict
        /// Before C's 404, while v3's follow is still owed: the visit moved B onto N, and v4's visit of N moves B back.
        case beforeVerdict
    }

    /// C (100 kB: zz-a and zz-b, a user waiter each) downloads; v3 moves zz-b to N (16 B, held). C's attempt ends
    /// (`ending`) while v3's follow is owed, so behind the barrier its verdict waits; C is visited for v3 after the end or
    /// before it (`when`; an ENOSPC's only after it). v4 then maps zz-b back to C's content. Visited first, v3's visit moved
    /// B onto N while C downloaded, C's verdict answered A alone and removed C, and v4's visit superseded N and moved B to
    /// a fresh job of C's content, whose download (C's next scripted step) served B. Returns the answers of A and B.
    @available(macOS 15.0, iOS 18.0, *)
    func mappedBack(_ visit: LaneDropVisit, seed: UInt64, when: MappedBackVisit, ending: MappedBackEnding = .notFound) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>) {
        try #require(ending == .notFound || when == .afterVerdict, "setup: an ENOSPC's free-space read runs a follow turn, which would end v3's follow once its visit of C ran")
        let space = ending == .spaceAtCap
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: space ? SyncTuning(interactiveRetry: Self.shortInteractiveRetry) : SyncTuning())
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        let fillers = FollowBarrier.fillers(seed + 200) + (space ? Self.spaceReadFillers(seed + 500) : [])
        let later = Self.laterFillers(seed + 6_000)
        let early = space ? Self.spaceReadFillers(seed + 400) : []
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + early + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        switch ending {
        case .notFound:
            await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(cBytes)])
        case .spaceAtCap:
            await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.timedOut, retryAfter: nil)), .hold, .stage(cBytes)])
        }
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        if space {
            // C's first attempt times out before any apply: one attempt counted, nobody answered, C retries.
            await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
            }
        }
        // v3 moves zz-b to N.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-back-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst, when == .beforeVerdict {
            try await Self.runFollowTurns(engine, until: { $0.state.jobs[a.transferID]?.assets.contains(b.identifier) == false }, "v3's visit moves B onto N while the follow is still owed")
        }
        // C's attempt ends.
        if space {
            if visit == .sweepFollowsFirst {
                // The ENOSPC's free-space read runs one follow turn (`spaceReadFillers`); the space sweep's own follow-up
                // turns, which would run the rest of the follow and its drain before v4, are held.
                await engine.readForTests { $0.holdSpaceSweepFollowUps() }
            }
            await s.harness.source.release(a.transferID, with: .failed(.insufficientSpace(requiredBytes: 200_000)))
        } else {
            await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in
                e.state.verdictsAfterFollow[a.transferID] != nil || e.state.eventsAfterFollow.contains(where: Self.isSpaceFailure)
            }
            let holds = await engine.readForTests { $0.state.jobs[a.transferID]?.assets.contains(b.identifier) == true }
            try #require(holds == (when == .afterVerdict), "setup: C holds zz-b at its attempt's end only when its visit comes after it")
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        }
        // v4 maps zz-b back to C's content. Once v3's visits ran (`.beforeVerdict`), v4's follow ends in its apply's own
        // turn, so its visit of N comes before C's verdict in both orders.
        try await Self.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-back-\(seed)", s, visit: when == .beforeVerdict ? .followVisitedFirst : visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseSpaceSweepFollowUps()
            }
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

    /// As above, with C's second attempt ending in an ENOSPC whose room is there after all (`mappedBack`, `.spaceAtCap`;
    /// the ENOSPC replay's own `takeOffMovedBefore`, Stage 3 close-out cycle 17): visited first, the retry's count at the
    /// user lane's cap answered A alone, and B, moved back by v4 after it, was served by a fresh job of C's content. Left
    /// on C through the verdict, B was answered with A.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: an id an apply maps back to a content whose ENOSPC verdict waits joins it after the verdict (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierJoinsAnIDMappedBackAfterTheSpaceVerdictThatWaits(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.mappedBack(visit, seed: 1_617_602, when: .afterVerdict, ending: .spaceAtCap)
        Self.expectInsufficientSpace(outcome.a, "A gets C's ENOSPC at the user lane's cap (visit-first)")
        #expect((try? outcome.b.get())?.byteSize == 100_000, "B was on N at C's ENOSPC, and v4 moved it back to a fresh job of C's content, which serves it (visit-first): \(outcome.b)")
    }

    /// How N's attempt ends in `intermediateHop`.
    enum HopEnding: Sendable, CaseIterable {
        /// A 404 whose verdict waits for v3's follow (PROBE-C16C-INTERMEDIATE-HOP).
        case notFound
        /// Its download completes and N publishes (PROBE-C16C-INTERMEDIATE-HOP-SERVED).
        case published
        /// An ENOSPC for 20 MB with 500 kB of room: N parks `insufficientSpace` and its fail-fast answers its user waiters
        /// (`spaceFailed`'s own `bringInbound`; Stage 3 close-out cycle 17).
        case insufficientSpace
    }

    /// C (100 kB, zz-b; a user waiter B) and N (16 B, zz-p; a user waiter P) download. v3 moves zz-b onto N's content;
    /// N's attempt ends (`ending`) while v3's follow is owed; v4 then moves zz-b on to M (48 B) before the follow visits
    /// C. Visited first, v3's visit superseded C and moved B onto N while N downloaded, so N's attempt's outcome was B's:
    /// its 404 answered P and B `notFound`, its publication served both N's 16 bytes, its park for lack of space answered
    /// both `insufficientSpace`; v4 moved nobody. Returns the answers of B and P.
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
        let space = ending == .insufficientSpace
        let fillers = FollowBarrier.fillers(seed + 200) + (space ? Self.spaceReadFillers(seed + 500) : [])
        let later = Self.laterFillers(seed + 6_000)
        let early = space ? Self.spaceReadFillers(seed + 400) : []
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + early + [b, p] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .stage(cBytes)])
        switch ending {
        case .notFound:
            await s.harness.source.script(p.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(nBytes)])
        case .published, .insufficientSpace:
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
        if space {
            if visit == .sweepFollowsFirst {
                // The ENOSPC's free-space read runs one follow turn, which does not reach C (`spaceReadFillers`); the space
                // sweep's own follow-up turns are held.
                await engine.readForTests { $0.holdSpaceSweepFollowUps() }
            }
            try await Self.leaveRoom(500_000, harness: s.harness, fileSystem: s.fileSystem)
            await s.harness.source.release(p.transferID, with: .failed(.insufficientSpace(requiredBytes: 20_000_000)))
        } else {
            await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        }
        let pResult: Result<AssetLocation, AssetError>?
        switch ending {
        case .notFound:
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil }
            } else {
                await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
            }
            pResult = nil
        case .insufficientSpace:
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { $0.state.eventsAfterFollow.contains(where: Self.isSpaceFailure) }
            } else {
                await engine.awaitCondition { e in
                    guard let job = e.state.jobs[p.transferID] else {
                        return true
                    }
                    if case .blocked = job.state {
                        return true
                    }
                    return false
                }
            }
            pResult = nil
        case .published:
            pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        }
        // v4 moves zz-b on to M.
        try await Self.applyHeld([s.q] + fillers + [bToM, p] + later, tag: "v4-hop-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseSpaceSweepFollowUps()
            }
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
    /// PROBE-C16C-INTERMEDIATE-HOP and -SERVED, `bringInbound`; cycle 17 adds the ENOSPC): visited first, B was on N when
    /// N's attempt ended.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: an interest an apply moved onto a content gets the outcome of the attempt that ends there, though a later apply moves it on (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, HopEnding.allCases)
    func barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent(_ visit: LaneDropVisit, _ ending: HopEnding) async throws {
        let seeds: [HopEnding: UInt64] = [.notFound: 1_617_202, .published: 1_617_302, .insufficientSpace: 1_617_702]
        let outcome = try await self.intermediateHop(visit, seed: try #require(seeds[ending]), ending: ending)
        switch ending {
        case .notFound:
            #expect(outcome.p == .failure(.notFound), "P gets N's 404 (visit-first): \(outcome.p)")
            #expect(outcome.b == .failure(.notFound), "B was on N at its 404 (visit-first): \(outcome.b)")
        case .published:
            #expect((try? outcome.p.get())?.byteSize == 16, "P is served N (visit-first): \(outcome.p)")
            #expect((try? outcome.b.get())?.byteSize == 16, "B was on N when it published, and is served N's content (visit-first): \(outcome.b)")
        case .insufficientSpace:
            Self.expectInsufficientSpace(outcome.p, "P gets N's park for lack of space (visit-first)")
            Self.expectInsufficientSpace(outcome.b, "B was on N at its ENOSPC (visit-first)")
        }
    }

    /// C (100 kB: zz-a and zz-b, a user waiter each) publishes, held at its first store unit, and N (16 B, zz-p; a user
    /// waiter P) downloads, when v3 moves zz-b onto N's content: v3's visit passes C, publishing, and re-routes nothing
    /// (its publication began before the apply). N then gets a 404 while (behind the barrier) v3's follow is owed. Visited
    /// first, B stayed on C's publication, N's 404 answered P alone, and C's commit, which binds only the ids the copy
    /// maps to it, served A and moved B to a fresh job of N's content, whose download (N's next scripted step) served it.
    /// Returns the answers of A, B and P.
    @available(macOS 15.0, iOS 18.0, *)
    func passedHolder(_ visit: LaneDropVisit, seed: UInt64) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>, p: Result<AssetLocation, AssetError>) {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", nBytes)
        let bToN = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID && p.transferID == bToN.transferID && b.transferID != p.transferID, "setup: zz-a and zz-b share C; zz-p and v3's zz-b share N")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, p] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(p.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        // C publishes, held at its first store unit, before v3's apply: v3's visit passes it.
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, bToN, p] + Self.laterFillers(seed + 6_000), tag: "v3-passed-\(seed)", s, visit: visit)
        let atApply = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true)
        }
        try #require(atApply.owed == (visit == .sweepFollowsFirst) && atApply.c == .verifying && atApply.holdsB, "setup: C still publishes with zz-b at N's 404: \(atApply)")
        // N's 404.
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        // C's publication commits.
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (aResult, bResult, pResult)
    }

    /// An interest that a job the owed visit passes holds is not brought onto the content an apply moved its id to when
    /// that content's attempt ends (`passedHolder`; `bringInbound` brings only the ids the holder's visit moves,
    /// `rerouteOnVisit`; Stage 3 close-out cycle 17): visited first, B stayed on C's publication, so N's 404 did not
    /// answer it, and C's commit moved it to a fresh job of N's content, which served it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: an interest a passed publication holds keeps that publication's outcome when the content its id moved to ends an attempt (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierLeavesAPassedPublicationsInterestToItsOutcome(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.passedHolder(visit, seed: 1_617_802)
        #expect(outcome.p == .failure(.notFound), "P gets N's 404 (visit-first): \(outcome.p)")
        #expect((try? outcome.a.get())?.byteSize == 100_000, "A is served C's publication (visit-first): \(outcome.a)")
        #expect((try? outcome.b.get())?.byteSize == 16, "B stayed on C's publication at N's 404 and is served N's content after C's commit (visit-first): \(outcome.b)")
    }
}
