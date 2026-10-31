import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The follow barrier's answers for a job whose publication an owed follow's visit meets (Stage 3 close-out cycle 15:
/// the cycle-14 verifiers' PROBE-C14R-PASSED-LANE, PROBE-C14R-PASSED-FAIL, PROBE-C14C-PASSED-LANE and
/// PROBE-C14C-MARK-TWO-APPLIES; ruling S3-R16 item 1(a)). A visit-first engine visited every job at the apply: a
/// publication begun after the apply met a job that still downloaded, whose moved ids that visit had moved, and a
/// publication begun before it met a job the visit passed, whose moved ids its outcome answered. Each test runs in both
/// orders (`LaneDropVisit`) with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    /// What `passedLane` observed: the origin's throttle right after C's failure (seconds left), and the answers of U
    /// (zz-u's user), P (zz-b's prefetch waiter) and W (zz-y's waiter).
    struct PassedLaneOutcome {
        /// The seconds the origin's throttle had left right after C's failure, if any.
        let throttleAtArrival: TimeInterval?
        /// U's answer.
        let u: Result<AssetLocation, AssetError>
        /// P's answer.
        let p: Result<AssetLocation, AssetError>
        /// W's answer.
        let w: Result<AssetLocation, AssetError>
    }

    /// The shared scenario of the passed-lane tests. Interactive `maxRetryAfter` 30 s, background 3,600 s. C (1 MB, zz-b)
    /// downloads for P, a prefetch waiter; Y (100 kB, zz-u and zz-y) downloads for U, a user waiter of zz-u, and W, a
    /// waiter of zz-y at `wLane`. v3 moves zz-u onto C's content while the follow owes its visits (the fillers before
    /// the `zz-` ids keep the follow's first turn from finding Y). C then fails with `failure`. Y's publication is held
    /// before the apply when `yPublishingAtApply`, else after it (visited first, Y still downloads at the apply and its
    /// visit moves U onto C). `afterDrain`: C fails after the barrier's drain, else while the follow is owed.
    @available(macOS 15.0, iOS 18.0, *)
    func passedLane(_ visit: LaneDropVisit, seed: UInt64, failure: TransferError, afterDrain: Bool, yPublishingAtApply: Bool = false, wLane: AssetPriority = .userInitiated) async throws -> PassedLaneOutcome {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xC4, count: 1_000_000)
        let yBytes = Data(repeating: 0xC5, count: 100_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let u = EngineHarness.onDemand("zz-u", yBytes)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        let uMoved = EngineHarness.onDemand("zz-u", cBytes)
        try #require(y.transferID == u.transferID && uMoved.transferID == b.transferID, "setup: zz-u and zz-y share Y; v3's zz-u is C's content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, u, y] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(b.transferID, [.hold, .fail(failure), .stage(cBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(yBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        }
        let wWaiter = Task { await engine.awaitAsset(y.identifier, lane: wLane) }
        await engine.awaitCondition { $0.state.jobs[u.transferID]?.interests.count == 2 }
        var releaser: Task<Void, Never>?
        if yPublishingAtApply {
            releaser = try await Self.holdPublication(of: u.transferID, s, bulk: bulk)
        }
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + [b, uMoved, y] + Self.laterFillers(seed + 6_000)
        try await Self.applyHeld(v3, tag: "v3-passed-lane-\(seed)", s, visit: visit)
        if !yPublishingAtApply, visit == .sweepFollowsFirst {
            // Y downloaded at the apply; its publication begins while the follow is owed.
            releaser = try await Self.holdPublication(of: u.transferID, s, bulk: bulk)
        }
        if afterDrain, visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttle = await engine.readForTests { e in
            e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow())
        }
        if visit == .sweepFollowsFirst, !afterDrain {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        releaser?.cancel()
        await releaser?.value
        await bulk.setHolding(false)
        if visit == .followVisitedFirst, !yPublishingAtApply {
            // Visited first, Y kept zz-y and still downloads: let it finish.
            await s.harness.source.release(u.transferID, with: .progress(received: 0, expected: nil))
        }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        await Self.finishHeld(s)
        return PassedLaneOutcome(throttleAtArrival: throttle, u: uResult, p: pResult, w: wResult)
    }

    /// Records an issue unless `result` is `serverUnavailable`.
    static func expectServerUnavailable(_ result: Result<AssetLocation, AssetError>, _ comment: String) {
        if case .failure(.serverUnavailable) = result {
        } else {
            Issue.record("\(comment): \(result)")
        }
    }

    // MARK: A publication begun after the apply (PROBE-C14R-PASSED-LANE, PROBE-C14C-PASSED-LANE)

    /// A 429 during an owed follow is decided on the lane a visit-first engine's job had when the moved interest sits on
    /// a job whose publication began after the apply: Y's download completes after v3's apply, so its publication begins
    /// while the follow is owed, and C gets a 429 with Retry-After 60 s (above the user lane's 30 s cap). Visited first,
    /// Y's visit at the apply moved U onto C while Y downloaded, so C was user work: nothing was throttled, C failed,
    /// and U and P were answered `serverUnavailable(60)`. Read without the interests of a job that publishes, C was
    /// prefetch work: the origin was throttled for 60 s on arrival, and C's retry served U and P (the cycle-14 verifiers).
    /// `wLane`: Y's other waiter is a user's (the requirements verifier's probe) or a prefetch waiter's (the correctness
    /// verifier's); either way it is served by Y.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow counts the interest a publication begun after the apply had moved (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [AssetPriority.userInitiated, .prefetch])
    func barrierDecidesA429OnTheLaneAPublicationBegunAfterTheApplyGives(_ visit: LaneDropVisit, _ wLane: AssetPriority) async throws {
        let outcome = try await self.passedLane(visit, seed: wLane == .userInitiated ? 1_318_002 : 1_318_302, failure: .transient(.throttled, retryAfter: .seconds(60)), afterDrain: false, wLane: wLane)
        #expect(outcome.throttleAtArrival == nil, "the 429 beyond the user lane's cap throttles nothing (visit-first `.exhausted`): \(String(describing: outcome.throttleAtArrival))")
        Self.expectServerUnavailable(outcome.u, "U is answered serverUnavailable with C's deferral to the next run (visit-first)")
        Self.expectServerUnavailable(outcome.p, "P is answered serverUnavailable with C's deferral to the next run (visit-first)")
        #expect((try? outcome.w.get())?.byteSize == 100_000, "W is served by Y (visit-first): \(outcome.w)")
    }

    /// As above, with C's 429 after the barrier's drain while Y still publishes: visited first, U had moved onto C at the
    /// apply, so C was user work. Left on Y by the follow's visit, U was not one of C's interests and C was decided on the
    /// background policy (PROBE-C14R-PASSED-LANE-AFTER).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 after an owed follow's drain counts the interest a publication begun after the apply had moved (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429AfterTheDrainOnTheLaneAPublicationBegunAfterTheApplyGives(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.passedLane(visit, seed: 1_318_602, failure: .transient(.throttled, retryAfter: .seconds(60)), afterDrain: true)
        #expect(outcome.throttleAtArrival == nil, "the 429 beyond the user lane's cap throttles nothing (visit-first `.exhausted`): \(String(describing: outcome.throttleAtArrival))")
        Self.expectServerUnavailable(outcome.u, "U is answered serverUnavailable with C's deferral to the next run (visit-first)")
        Self.expectServerUnavailable(outcome.p, "P is answered serverUnavailable with C's deferral to the next run (visit-first)")
        #expect((try? outcome.w.get())?.byteSize == 100_000, "W is served by Y (visit-first): \(outcome.w)")
    }

    /// The moved user shares C's 404 when the moved interest sits on a job whose publication began after the apply, with
    /// C's 404 while the follow is owed: visited first, U rode C since the apply and was answered `notFound` with P.
    /// Left on Y, U was re-routed onto C's content after Y's commit, and a second request for content that had just
    /// answered 404 served U (PROBE-C14R-PASSED-FAIL-BARRIER).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a 404 during an owed follow answers the id a publication begun after the apply had moved (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersA404WithTheIdAPublicationBegunAfterTheApplyMoved(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.passedLane(visit, seed: 1_318_902, failure: .permanentMissing(httpStatus: 404), afterDrain: false)
        #expect(outcome.u == .failure(.notFound), "U shares C's 404 (visit-first): \(outcome.u)")
        #expect(outcome.p == .failure(.notFound), "P is answered C's 404 (visit-first): \(outcome.p)")
        #expect((try? outcome.w.get())?.byteSize == 100_000, "W is served by Y (visit-first): \(outcome.w)")
    }

    /// As above, with C's 404 after the barrier's drain (PROBE-C14R-PASSED-FAIL-AFTER).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a 404 after an owed follow's drain answers the id a publication begun after the apply had moved (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersA404AfterTheDrainWithTheIdAPublicationBegunAfterTheApplyMoved(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.passedLane(visit, seed: 1_319_202, failure: .permanentMissing(httpStatus: 404), afterDrain: true)
        #expect(outcome.u == .failure(.notFound), "U shares C's 404 (visit-first): \(outcome.u)")
        #expect(outcome.p == .failure(.notFound), "P is answered C's 404 (visit-first): \(outcome.p)")
        #expect((try? outcome.w.get())?.byteSize == 100_000, "W is served by Y (visit-first): \(outcome.w)")
    }

    // MARK: A later apply during the same publication (PROBE-C14C-MARK-TWO-APPLIES)

    /// A later apply's follow that passes a publication begun before that apply leaves its moved id to the publication's
    /// outcome, whatever an earlier apply's visit of the same publication did: C (100 kB, the content of zz-a, zz-b and
    /// zz-c, a user waiter each); v3 moves zz-b to N (16 bytes); C's publication begins after v3's apply and is held; v4,
    /// applied while the same publication still verifies, moves zz-c to N2 (24 bytes); C's bytes then fail their
    /// checksum. Visited first, v3's visit moved B onto N while C downloaded, and v4's follow passed C, publishing, so
    /// zz-c's user was answered `integrityFailure` with A. Behind v3's barrier, cycle 14's mark of v3's pass outlived v4's
    /// pass, and the failure moved zz-c onto N2 too, which served zz-c's user (the cycle-14 correctness verifier).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a later apply's follow that passes a publication leaves its moved id to the publication's failure (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersALaterApplysPassedIdWithThePublicationsFailure(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_319_502
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
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        await s.harness.source.script(cMoved.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        let cWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 3 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, c] + later, tag: "v3-two-applies-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            // Visited first, C's visit moved B onto N at the apply; N is served before C's bytes arrive.
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID] == nil }
            }
        }
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            await Self.runOneFollowTurn(engine)
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        // v4 while the same publication still verifies: its follow passes C in both orders.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, cMoved] + later, tag: "v4-two-applies-\(seed)", s, visit: .followVisitedFirst)
        let atV4 = await engine.readForTests { e in e.state.jobs[a.transferID]?.state }
        try #require(atV4 == .verifying, "setup: the same publication still verifies at v4: \(String(describing: atV4))")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let cResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: cWaiter) }
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N, the content v3 maps zz-b to (visit-first): \(bResult)")
        #expect(cResult == .failure(.integrityFailure), "zz-c's user gets C's integrity failure: v4's follow passed C, publishing, in both orders (visit-first): \(cResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    // MARK: A publication begun before the apply that fails before its visit

    /// A job whose publication began before the apply and failed before the follow's visit is passed by that visit, as a
    /// visit-first engine's follow passed it while it still verified: C verifies when v3 moves zz-b; its bytes fail while
    /// the follow is owed and before the follow's turn that finds C. Visited first, the follow passed C at the apply and
    /// the failure answered both users `integrityFailure`. Met failed, its verdict waiting, C was visited as any failed
    /// job, and B was moved onto N and served (found by the cycle-15 fixer beside PROBE-C14C-MARK-TWO-APPLIES).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a publication begun before an owed follow's apply that fails before its visit answers as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAPublicationFailedBeforeItsVisitAsPassed(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.passedPublication(visit, seed: 1_319_802, publishingAtApply: true, failBehindBarrier: true, failBeforeVisit: true)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: the follow passed C, publishing at the apply, in both orders (visit-first): \(bResult)")
    }
}
