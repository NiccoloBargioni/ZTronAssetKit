import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The replay branches and the world-view reads that stay behind the follow barrier after Stage 3 close-out cycle 13,
/// each reached by a test that a mutant dropping it fails (G4; ruling S3-R16 item 1(e)): a 429 whose `Retry-After` the
/// caps refuse (`ThrottleDecision.exhausted`), an offline exit after an edge (`AttemptVerdict.offline(requeue: true)`),
/// a conditions element replayed under its own conditions (`withReading`), and a join answered on the breaker of its
/// arrival (`breakerRecorded`). Each runs in both orders (`LaneDropVisit`) and expects the visit-first outcome; the
/// mutants and their failing lines are in `docs/adr-drafts/s3f.md`, cycle 13.
extension EngineFollowBarrierTests {
    /// Applies `v3` through the engine's apply path with the follow's follow-up turns held (no run: a run's manifest
    /// step would read the conditions or the breaker these tests change), and in `.followVisitedFirst` lets the follow
    /// end.
    @available(macOS 15.0, iOS 18.0, *)
    static func applyHeld(_ v3: [ManifestEntry], tag: String, _ s: FollowBarrier.Setup, visit: LaneDropVisit) async throws {
        let engine = s.engine
        let manifest = try ValidatedManifest(entries: v3, digest: ContentHash.sha256(of: Data(tag.utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        let applied = await engine.applyAndFollow(manifest, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "setup: v3 is applied: \(applied)")
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        } else {
            let owed = await engine.readForTests { $0.followOwed }
            #expect(owed, "setup: the follow owes its visits")
        }
    }

    /// Checks the invariants and shuts the engine down (no run to wait for).
    @available(macOS 15.0, iOS 18.0, *)
    static func finishHeld(_ s: FollowBarrier.Setup) async {
        let violations = await s.engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await s.engine.shutdown()
    }

    // MARK: A 429 beyond the caps (`ThrottleDecision.exhausted`)

    /// A 429 whose `Retry-After` exceeds `maxRetryAfter`, arriving while the follow owes its visits, fails its job with
    /// the throttle's answer and throttles nothing, as a visit-first engine's did (`Backoff.delay` defers to the next run;
    /// R-SYN-5): C (zz-c) downloads for U's user waiter and gets a 429 with `Retry-After` 7,200 s. Dropped on arrival (a
    /// park until the 429's instant) or at the replay, the job was parked and re-admitted at once, and its retry served U.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 beyond maxRetryAfter during an owed follow fails its job with the throttle's answer (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierFailsA429BeyondTheCapsAsOnArrival(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_306_002)
        let engine = s.engine
        let cBytes = Data(repeating: 0xF1, count: 100_000)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_306_100) + [c], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(c.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(7_200))), .stage(cBytes)])
        let uWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[c.transferID]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_306_200) + [c], tag: "v3-exhausted", s, visit: visit)
        await s.harness.source.release(c.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[c.transferID]?.state != .downloading }
        let throttle = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        #expect(throttle == nil, "a Retry-After beyond the caps throttles nothing (visit-first): \(String(describing: throttle))")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        if case .failure(.serverUnavailable(let retryAfter?)) = uResult {
            #expect(abs(retryAfter - 7_200) < 1, "U gets the 429's Retry-After (visit-first): \(uResult)")
        } else {
            Issue.record("U gets the throttle's answer (visit-first serverUnavailable(7200)): \(uResult)")
        }
        let state = await engine.readForTests { $0.state.jobs[c.transferID]?.state }
        let starts = await s.harness.source.starts.filter { $0.id == c.transferID }.count
        #expect(state == nil || state == .failed(.nextRun), "C waits for the next run (visit-first): \(String(describing: state))")
        #expect(starts == 1, "C is not tried again in this run (visit-first): \(starts) start(s)")
        await Self.finishHeld(s)
    }

    // MARK: An offline exit after an edge (`AttemptVerdict.offline(requeue: true)`)

    /// An attempt that fails offline after an edge passed while it ran is tried again at once, also when its exit waits
    /// for the follow (R-SYN-13, PROBE-C9C-3): R (zz-r) downloads for U's user waiter; the network drops and returns
    /// while the follow owes its visits; then R's attempt fails offline. Dropped at the replay, R waited for an edge that
    /// had passed (`failed(whenOnline)`) and U was answered `.offline`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: an offline failure after an edge during an owed follow is retried at once (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierRetriesAnOfflineFailureAfterAnEdge(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_307_002)
        let engine = s.engine
        let rBytes = Data(repeating: 0xF2, count: 100_000)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_307_100) + [r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(r.transferID, [.hold, .fail(.offline(.noConnection)), .stage(rBytes)])
        let uWaiter = Task { await engine.awaitAsset(r.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[r.transferID]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_307_200) + [r], tag: "v3-offline", s, visit: visit)
        // The network drops and returns while R runs: an edge passes during its attempt.
        await s.harness.conditions.send(EngineRegressionCycle10Tests.offline)
        await engine.awaitCondition { $0.state.conditions?.network.satisfied == false }
        await s.harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.conditions?.network.satisfied == true }
        await s.harness.source.release(r.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            // R's offline exit waits for the follow (`defersFailure`).
            await engine.awaitCondition { $0.state.verdictsAfterFollow[r.transferID] != nil }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        #expect((try? uResult.get())?.byteSize == Int64(rBytes.count), "R is tried again at once and serves U (visit-first): \(uResult)")
        let starts = await s.harness.source.starts.filter { $0.id == r.transferID }.count
        #expect(starts == 2, "R's second attempt follows its offline failure: \(starts) start(s)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    // MARK: A conditions element replayed under its own conditions (`withReading`)

    /// A conditions element that arrives while the follow owes its visits is applied, at the drain, under its own
    /// conditions, not the later element's (R-SYN-7, S3-R15 item 1): P (zz-p) downloads for a prefetch member; Low Data
    /// Mode arrives, then an unrestricted network, both while the follow owes its visits. Visited first, Low Data Mode
    /// paused P (the prefetch lane refuses a constrained network) and the unrestricted element resumed it. Replayed on
    /// the conditions the drain finds, the first element paused nothing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: a conditions element during an owed follow pauses on its own conditions, not a later element's (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPausesOnTheConditionsOfItsElement(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_308_002)
        let engine = s.engine
        let pBytes = Data(repeating: 0xF3, count: 100_000)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_308_100) + [p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(p.transferID, [.hold, .stage(pBytes)])
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[p.transferID]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_308_200) + [p], tag: "v3-conditions", s, visit: visit)
        await s.harness.conditions.send(EngineConditionsTests.lowData)
        await engine.awaitCondition { $0.state.conditions?.network.constrained == true }
        await s.harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.conditions?.network.constrained == false }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let pauses = await s.harness.source.controlLog.filter { $0.transfer == p.transferID && $0.control == .pause }.count
        #expect(pauses == 1, "Low Data Mode pauses P once, on its own conditions (visit-first): \(pauses) pause(s)")
        await engine.releaseGroup(group)
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID] == nil }
        }
        await Self.finishHeld(s)
    }

    // MARK: A publication's integrity failure (the cycle-12 R-A remainder; S3-R16 item 5, "probe first")

    /// A publication's integrity failure of a job that holds an id the owed visits move answers that id's user with the
    /// content the copy maps it to, as a visit-first engine's did: C (zz-a and zz-b) downloads for user waiters A and B;
    /// v3 moves zz-a to N (16 bytes) while the follow owes C's visit; then C's bytes fail their checksum. Visited first,
    /// the visit moved A onto N before C's bytes arrived: A was served N and B answered `integrityFailure`. Behind the
    /// barrier the failure's answers wait for the visit (`resolveAll`'s `.resolve` verdict, `defersFailure`), which moves
    /// A onto N first, so the answers are the same; nothing else of the publication waits (cycle 13 removed the commit
    /// deferral, which only ordered the answers).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an integrity failure during an owed follow answers a moved id with its new content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAnIntegrityFailureAfterTheVisit(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_310_002)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(1_310_003, count: 100_000)
        let wrong = EngineFixture.bytes(1_310_004, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_310_100) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.interests.count == 2 && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let nBytes = EngineFixture.bytes(1_310_005, count: 16)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_310_200) + [aMoved, b], tag: "v3-integrity", s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            // C's failure answers wait for its visit (`defersFailure`).
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? aResult.get())?.byteSize == 16, "A is served N, the content v3 maps zz-a to (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    // MARK: A group's claims at its registration (the cycle-12 residual R-F; S3-R16 item 5, "probe first")

    /// A group registered while a withdrawal waits for the follow gets its member, and the job ends where a visit-first
    /// engine's ended: U's user waiter is C's (zz-c's) only interest while the follow owes its visits; U withdraws, then a
    /// prefetch group registers zz-c. Visited first, the withdrawal retired C and stopped its transfer, and the group's
    /// join created C again: a second request. Behind the barrier the withdrawal waits (`.removal`) while the group's
    /// claim is taken at its registration (`recordGroup`); the cycle-12 suspicion R-F was that the claim keeps C through
    /// the drain. It does not: the drain applies the withdrawal (C retired, its transfer stopped) before the group's
    /// join, which creates C again, as visited first. U is answered `cancelled` at once in both orders.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-4: a group registered after a withdrawal during an owed follow gets its member (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierServesAGroupRegisteredAfterAWithdrawal(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_311_002)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(1_311_003, count: 100_000)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_311_100) + [c], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(c.transferID, [.hold, .stage(cBytes)])
        let uWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[c.transferID]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_311_200) + [c], tag: "v3-claims", s, visit: visit)
        uWaiter.cancel()
        let uResult = await uWaiter.value
        #expect(uResult == .failure(.cancelled), "U's caller is answered at once (R-SYN-4, R-SYN-10): \(uResult)")
        if visit == .followVisitedFirst {
            // Visited first, the withdrawal retired C: nothing else wanted it.
            await engine.awaitCondition { $0.state.jobs[c.transferID] == nil }
        }
        let group = try await engine.registerGroup([c.identifier], lane: .prefetch).get()
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, c) }
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        // The group's member joined and is no longer pending: its job ended.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.groups[group].map { $0.joined.contains(c.identifier) && $0.pending.isEmpty } == true && e.state.jobs[c.transferID] == nil
            }
        }
        let stored = await s.harness.store.location(for: c.identifier, extensions: [], recordingAccess: false)
        #expect(stored != nil, "the group's member is stored when C ends (visit-first)")
        let starts = await s.harness.source.starts.filter { $0.id == c.transferID }.count
        #expect(starts == 2, "the withdrawal stopped C and the group's join started it again (visit-first): \(starts) start(s)")
        await engine.releaseGroup(group)
        await Self.finishHeld(s)
    }

    // MARK: A join answered on the breaker of its arrival (`breakerRecorded`)

    /// A request for a job the breaker parked, made while the follow owes its visits and a half-open breaker's probe
    /// runs, gets the breaker's answer of its arrival (R-SYN-5, S3-R15 item 4): X's 403 opens the breaker; M and K, two
    /// prefetch members, park behind it; at the cooldown's end one of them is admitted as the probe and holds. While the
    /// follow owes its visits, U requests the other; then the probe's bytes commit and close the breaker. Visited first,
    /// U's join met the half-open breaker with its probe in flight and was answered `authRejected` at once. Read on the
    /// breaker the drain finds (closed), the replayed join re-admitted Q and U was served.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a request during an owed follow is answered on the breaker as it stood at the request (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAJoinOnTheBreakerAtItsRequest(_ visit: LaneDropVisit) async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let (s, _) = try await FollowBarrier.setUp(seed: 1_309_002, tuning: tuning)
        let engine = s.engine
        let origin = s.harness.source.originID
        let xBytes = Data(repeating: 0xF4, count: 100_000)
        let mBytes = Data(repeating: 0xF5, count: 100_000)
        let kBytes = Data(repeating: 0xF6, count: 100_000)
        let hBytes = Data(repeating: 0xF7, count: 100_000)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let m = EngineHarness.onDemand("zz-m", mBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let entries = [h, k, m, x]
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_309_100) + entries, etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(x.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        await s.harness.source.script(m.transferID, [.hold, .stage(mBytes)])
        await s.harness.source.script(k.transferID, [.hold, .stage(kBytes)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        // H (a prefetch member, held) brings the first conditions reading before the breaker opens: the clock is not
        // driven once the cooldown runs.
        let hGroup = try await engine.registerGroup([h.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        let xResult = await engine.awaitAsset(x.identifier, lane: .userInitiated)
        #expect((try? xResult.get()) == nil, "setup: X's 403 fails it: \(xResult)")
        let group = try await engine.registerGroup([m.identifier, k.identifier], lane: .prefetch).get()
        await engine.awaitCondition { e in
            e.state.jobs[m.transferID]?.state.isCircuitParked == true && e.state.jobs[k.transferID]?.state.isCircuitParked == true
        }
        let opened = await engine.readForTests { $0.state.breakers[origin]?.state }
        guard case .open(_, let cooldownEnd, _)? = opened else {
            Issue.record("setup: X's 403 opened the breaker: \(String(describing: opened))")
            await engine.shutdown()
            return
        }
        // The cooldown's end admits one parked member as the half-open breaker's probe; it holds.
        EngineRegressionCycle21Tests.advance(s.time, to: cooldownEnd)
        await engine.awaitCondition { $0.state.jobs[m.transferID]?.state == .downloading || $0.state.jobs[k.transferID]?.state == .downloading }
        let mProbes = await engine.readForTests { $0.state.jobs[m.transferID]?.state == .downloading }
        let probe = mProbes ? m : k
        let parked = mProbes ? k : m
        let halfOpen = await engine.readForTests { e -> Bool in
            if case .halfOpen(_, _, let running?, _)? = e.state.breakers[origin]?.state {
                return running == probe.transferID && e.state.jobs[parked.transferID]?.state.isCircuitParked == true
            }
            return false
        }
        #expect(halfOpen, "setup: the breaker is half-open with \(probe.identifier)'s probe in flight and \(parked.identifier) parked")
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_309_200) + entries, tag: "v3-breaker", s, visit: visit)
        let uWaiter = Task { await engine.awaitAsset(parked.identifier, lane: .userInitiated) }
        var answered: Result<AssetLocation, AssetError>?
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, parked) }
        } else {
            // Visited first, the join meets the half-open breaker and its probe: answered at once.
            answered = await uWaiter.value
        }
        // The probe's bytes commit: the breaker closes. The clock stays where it is (the probe's watchdog is later).
        await s.harness.source.release(probe.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in e.state.breakers[origin]?.state == .closed && e.state.jobs[probe.transferID] == nil }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        // The parked member is re-admitted once the breaker closed; let it complete either way.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[parked.transferID]?.state == .downloading }
        }
        await s.harness.source.release(parked.transferID, with: .progress(received: 0, expected: nil))
        let uResult: Result<AssetLocation, AssetError>
        if let answered {
            uResult = answered
        } else {
            uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        }
        if case .failure(.authRejected) = uResult {
        } else {
            Issue.record("U gets the half-open breaker's answer of its request (visit-first authRejected): \(uResult)")
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[parked.transferID] == nil }
        }
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h.transferID] == nil }
        }
        await engine.releaseGroup(group)
        await engine.releaseGroup(hGroup)
        await Self.finishHeld(s)
    }
}
