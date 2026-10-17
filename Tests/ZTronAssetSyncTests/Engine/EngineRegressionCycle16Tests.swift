import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 16 of the level-4 close-out (`docs/adr-drafts/f.md`, F-36): a run that settled blocked by
/// a throttle that had ended because its parked claim was still owed a re-queue, and three readers of the end a parked
/// job kept after a later 429 extended the origin's throttle. Every clock move is made from a quiet engine
/// (`EngineRegressionCycle15Tests.quiet`), and every wait is a condition, a census or a held seam that ends on
/// cancellation (L4-R17).
@Suite("Engine regressions, close-out cycle 16")
struct EngineRegressionCycle16Tests {
    /// Whether `result` is the fail-fast answer of a user-initiated request to a throttled origin.
    static func failedFast(_ result: Result<AssetLocation, AssetError>) -> Bool {
        if case .failure(.serverUnavailable(retryAfter: let wait?)) = result {
            return wait > SyncTuning().interactiveRetry.interactiveMaxWait
        }
        return false
    }

    // MARK: A run waits for the claims a re-admission turn still owes a re-queue (R-SYN-5, R-SYN-6; cycle-15 verifier)

    /// At a throttle's end the alarm re-queues at most `readmissionsPerTurn` of the jobs it parked, in the pump's order
    /// (prefetch before bulk), and owes the rest to follow-up turns (`originOwed`). A run's bulk claim ranks last, so it
    /// stayed `blocked(throttled)` after the throttle had ended; when the run's last working claim finished before the
    /// follow-up, the run settled blocked by that throttle: its claim's job was retired, the pending run found its gate
    /// open and started a second run and a second manifest request without the clock moving (the cycle-15 correctness
    /// verifier's PROBE-OWEDSETTLE). The follow-up is held here (`holdReadmissionFollowUps()`), so the order is fixed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose parked claim a re-admission turn still owes a re-queue waits for it instead of settling blocked by the ended throttle", .timeLimit(.minutes(1)))
    func runWaitsForOwedClaims() async throws {
        let prefetchCount = SyncEngine.readmissionsPerTurn + 8
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        var entries: [ManifestEntry] = []
        for index in 0..<prefetchCount {
            let bytes = EngineFixture.bytes(UInt64(10_000 + index))
            let entry = EngineHarness.onDemand("p\(index)", bytes)
            entries.append(entry)
            // A member's transfer stages its bytes once the throttle lets it start.
            await harness.source.script(entry.transferID, [.stage(bytes)])
        }
        let bytes1 = EngineFixture.bytes(7_001)
        let bytes2 = EngineFixture.bytes(7_002)
        let first = EngineFixture.entry("r1", bytes1)
        let second = EngineFixture.entry("r2", bytes2)
        await harness.serveManifest(entries + [first, second])
        // The launch run plans both: the first is held in flight, the second answers 429 with a 30 s retry-after.
        await harness.source.script(first.transferID, [.hold, .stage(bytes1)])
        await harness.source.script(second.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(30))), .stage(bytes2)])
        let engine = harness.engine
        let time = harness.time
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        await engine.awaitCondition { $0.state.jobs[second.transferID]?.state.isThrottleParked == true && $0.state.jobs[first.transferID]?.active != nil }
        // A prefetch group arrives while the origin is throttled: the throttle parks every member.
        let token = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.throttleParked.count == prefetchCount + 1 && $0.state.laneParksOwed.isEmpty }
        await engine.holdReadmissionFollowUps()
        let launch = await engine.readForTests { ($0.state.run?.id, $0.state.lastRunID, $0.state.throttles[origin]) }
        let launchRun = try #require(launch.0, "setup: the launch run is in progress")
        let throttleEnd = try #require(launch.2, "setup: the 429 throttles the origin")
        let requestsBefore = await harness.source.manifestRequests.count
        // At the throttle's end the alarm re-queues the first `readmissionsPerTurn` (prefetch members) and owes the rest,
        // the run's parked claim among them, to a follow-up turn, which the hold keeps waiting.
        // The clock moves only once the engine has applied everything due: nothing at or before the clock in the heap,
        // no store work, and an alarm armed at or before the throttle's deadline (L4-R17).
        await engine.awaitCondition { engine in
            let now = engine.environment.time.monotonicNow()
            return engine.state.storeWorkRuns == 0 && (engine.state.heap.first.map { $0.at > now } ?? true)
                && engine.state.heap.deadline(for: .throttle(origin)) == throttleEnd
                && engine.state.alarm.map { $0.deadline <= throttleEnd && engine.state.tasks[$0.task] != nil } == true
        }
        time.advance(to: throttleEnd)
        await engine.awaitCondition { $0.state.throttles[origin] == nil && $0.state.readmissionFollowUpWaiting }
        let owed = await engine.readForTests { ($0.state.originOwed.contains(second.transferID), $0.state.jobs[second.transferID]?.state.isThrottleParked) }
        try #require(owed.0 && owed.1 == true, "setup: the run's parked claim is owed a re-queue by a follow-up turn")
        // The run's working claim finishes, and so does every re-queued member: only owed jobs are left.
        await harness.source.release(first.transferID, with: .progress(received: 1, expected: nil))
        await engine.awaitCondition { engine in
            engine.state.jobs[first.transferID] == nil && engine.state.inFlight.isEmpty && engine.state.storeWorkRuns == 0
                && engine.state.jobs.count == engine.state.throttleParked.count
        }
        let waiting = await engine.readForTests { engine in
            (engine.state.run?.id, engine.state.run?.settlement, engine.state.lastRunID, engine.state.jobs[second.transferID]?.state.isThrottleParked)
        }
        #expect(waiting.0 == launchRun, "the launch run is still the run in progress: \(String(describing: waiting.0))")
        #expect(waiting.1 == nil, "the run waits for its owed claim instead of settling: \(String(describing: waiting.1))")
        #expect(waiting.2 == launch.1, "no run started since the throttle's end: \(waiting.2) after \(launch.1)")
        #expect(waiting.3 == true, "the owed claim's job survives, still waiting for its re-queue")
        // The follow-up re-queues the owed jobs; the claim's transfer runs and the run completes.
        await engine.releaseReadmissionFollowUps()
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) && $0.state.jobs.isEmpty }
        let finished = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        let end = await engine.readForTests { ($0.state.lastRunID, $0.invariantViolations()) }
        let requests = await harness.source.manifestRequests.count
        if case .syncFinished(_, .complete(let report))? = finished {
            #expect(report.fetched == 2, "the run fetched both of its assets: \(report.fetched)")
        } else {
            Issue.record("the launch run completes once its owed claim ran: \(String(describing: finished))")
        }
        #expect(end.0 == launch.1, "no second run: \(end.0) after \(launch.1)")
        #expect(requests == requestsBefore, "no manifest request since the throttle's end: \(requests - requestsBefore)")
        #expect(end.1.isEmpty, "\(end.1)")
        await engine.releaseGroup(token)
        await probe.stop()
        await engine.shutdown()
    }

    // MARK: A joiner of a job a shorter throttle parked gets the origin's end (R-SYN-5; cycle-15 verifier)

    /// A parked job keeps the end it was parked with; a later 429 that extends the origin's throttle moves only the
    /// origin's end and its `.throttle` deadline, which alone re-admits the job. A user-initiated request that joined
    /// the job was checked against the job's old end (1 s, within `interactiveMaxWait`), so it was not failed fast and
    /// then waited 60 s for the origin's real end, while a fresh request and a joiner of the other job were told
    /// `.serverUnavailable(retryAfter: 60)` (PROBE-STALEJOIN, the transfer path).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user-initiated request that joins a job a shorter 429 parked fails fast against the origin's throttle a later transfer 429 extended", .timeLimit(.minutes(1)))
    func joinerOfStaleParkFailsFastTransfer() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4))
        let bytesA = EngineFixture.bytes(5_101)
        let bytesB = EngineFixture.bytes(5_102)
        let bytesC = EngineFixture.bytes(5_103)
        let a = EngineHarness.onDemand("a", bytesA)
        let b = EngineHarness.onDemand("b", bytesB)
        let c = EngineHarness.onDemand("c", bytesC)
        await harness.serveManifest([a, b, c])
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await harness.source.script(b.transferID, [.hold, .stage(bytesB)])
        await harness.source.script(a.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(1))), .stage(bytesA)])
        let callerB = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.active != nil }
        let callerA = Task { await engine.awaitAsset(a.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state.isThrottleParked == true }
        // B's 429 extends the origin's throttle to 60 s; A keeps the 1 s end it was parked with.
        await harness.source.release(b.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state.isThrottleParked == true }
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let parked = await engine.readForTests { engine -> (MonotonicInstant?, JobState?) in
            (engine.state.throttles[origin], engine.state.jobs[a.transferID]?.state)
        }
        let throttleEnd = try #require(parked.0, "setup: the origin is throttled")
        guard case .blocked(.throttled(let staleEnd))? = parked.1 else {
            Issue.record("setup: A is parked by the throttle: \(String(describing: parked.1))")
            await engine.shutdown()
            return
        }
        try #require(staleEnd < throttleEnd, "setup: A keeps an end before the origin's")
        // What a new job gets, and what a joiner of the job parked at the origin's end gets.
        let fresh = await joinCancelling(Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) })
        let joinB = await joinCancelling(Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) })
        #expect(Self.failedFast(fresh), "a fresh user request fails fast: \(fresh)")
        #expect(joinB == fresh, "a user join of B gets the fresh request's answer: \(joinB)")
        // A user-initiated request joins A: answered at once, or registered as A's interest.
        let user = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await untilFinishedOrCondition(user, engine) { $0.state.jobs[a.transferID]?.lane == .userInitiated }
        let waits = await engine.readForTests { engine in
            engine.state.jobs[a.transferID]?.interests.values.contains { $0.lane == .userInitiated } == true
        }
        #expect(!waits, "the user join of A is answered at once, not left waiting for the throttle's end \(throttleEnd)")
        if waits {
            await engine.shutdown()
        }
        let joinA = await joinCancelling(user)
        #expect(joinA == fresh, "the user join of A gets the fresh request's answer: \(joinA)")
        await engine.shutdown()
        _ = await joinCancelling(callerA)
        _ = await joinCancelling(callerB)
    }

    /// The same, with the extension made by a run's manifest 429 (the cycle-15 scenario reversed): the job is parked by
    /// a 1 s transfer 429 while the held manifest fetch then answers 429 with 60 s, so the origin's throttle and its
    /// deadline are at 60 s (F-35) while the job's reason still says 1 s (PROBE-STALEJOIN-M).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user-initiated request that joins a job a shorter 429 parked fails fast against the origin's throttle a later manifest 429 extended", .timeLimit(.minutes(1)))
    func joinerOfStaleParkFailsFastManifest() async throws {
        let fake = FakeRemoteSource()
        let held = HeldManifestSource(base: fake)
        let harness = EngineHarness.make(source: fake, remote: held)
        let bytes = EngineFixture.bytes(5_201)
        let onDemand = EngineHarness.onDemand("asset", bytes)
        await harness.serveManifest([onDemand])
        let engine = harness.engine
        let origin = fake.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await fake.scriptManifest([
            .fail(.transient(.throttled, retryAfter: .seconds(60))),
            .notModified,
        ])
        await held.holdNext()
        let run = Task { await engine.sync(.force) }
        await held.waitForHeldFetch()
        await fake.script(onDemand.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(1))), .stage(bytes)])
        let caller = Task { await engine.awaitAsset(onDemand.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[onDemand.transferID]?.state.isThrottleParked == true }
        await held.release()
        let outcome = await joinCancelling(run)
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let parked = await engine.readForTests { engine -> (MonotonicInstant?, JobState?, MonotonicInstant) in
            (engine.state.throttles[origin], engine.state.jobs[onDemand.transferID]?.state, engine.environment.time.monotonicNow())
        }
        let throttleEnd = try #require(parked.0, "setup: the origin is throttled")
        guard case .blocked(.throttled(let staleEnd))? = parked.1, case .blocked(.throttled(let reported), _) = outcome else {
            Issue.record("setup: the job is parked and the run blocked by the throttle: \(String(describing: parked.1)), \(outcome)")
            await engine.shutdown()
            return
        }
        try #require(staleEnd < throttleEnd && reported == throttleEnd, "setup: the job keeps an end before the origin's, which the run reports")
        let user = Task { await engine.awaitAsset(onDemand.identifier, lane: .userInitiated) }
        await untilFinishedOrCondition(user, engine) { $0.state.jobs[onDemand.transferID]?.lane == .userInitiated }
        let waits = await engine.readForTests { engine in
            engine.state.jobs[onDemand.transferID]?.interests.values.contains { $0.lane == .userInitiated } == true
        }
        #expect(!waits, "the user join is answered at once, not left waiting for the throttle's end \(throttleEnd)")
        if waits {
            await engine.shutdown()
        }
        let joined = await joinCancelling(user)
        #expect(joined == .failure(.serverUnavailable(retryAfter: throttleEnd.seconds(since: parked.2))), "the user join fails fast with the origin's wait: \(joined)")
        await engine.shutdown()
        _ = await joinCancelling(caller)
    }

    // MARK: A run blocked by its claims reports the origin's throttle end (R-SYN-5, R-SYN-6; cycle-15 verifier)

    /// A run that settles on its claims reported the first claim's parked end: a claim parked by a 1 s 429 kept that end
    /// after the other claim's 60 s 429 extended the origin's throttle, so the outcome told the caller the throttle ended
    /// 59 s before the throttle, its deadline and the pending run did (PROBE-STALEREPORT; the manifest path's own report
    /// was fixed in cycle 15).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run blocked by claims a shorter and a longer 429 parked reports the origin's throttle end", .timeLimit(.minutes(1)))
    func blockedRunReportsTheOriginsEnd() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        let bytesX = EngineFixture.bytes(8_001)
        let bytesY = EngineFixture.bytes(8_002)
        let x = EngineFixture.entry("x", bytesX)
        let y = EngineFixture.entry("y", bytesY)
        // The claim parked first, by the shorter 429, sorts first: its reason is the one the run reports.
        let (short, long, shortBytes, longBytes) = x.transferID < y.transferID ? (x, y, bytesX, bytesY) : (y, x, bytesY, bytesX)
        await harness.serveManifest([x, y])
        await harness.source.script(long.transferID, [.hold, .stage(longBytes)])
        await harness.source.script(short.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(1))), .stage(shortBytes)])
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        await engine.awaitCondition { $0.state.jobs[short.transferID]?.state.isThrottleParked == true && $0.state.jobs[long.transferID]?.active != nil }
        await harness.source.release(long.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        let finished = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let state = await engine.readForTests { engine in
            (engine.state.throttles[origin], engine.state.heap.deadline(for: .pendingRun), engine.state.heap.deadline(for: .throttle(origin)))
        }
        let throttleEnd = try #require(state.0, "setup: the origin is throttled")
        if case .syncFinished(_, .blocked(.throttled(let until), _))? = finished {
            #expect(until == throttleEnd, "the run reports the origin's throttle end \(throttleEnd), not \(until)")
        } else {
            Issue.record("the run is blocked by the throttle: \(String(describing: finished))")
        }
        #expect(state.1 == throttleEnd, "the pending run waits for the throttle's end")
        #expect(state.2 == throttleEnd, "the throttle's deadline is at its end")
        await probe.stop()
        await engine.shutdown()
    }

    // MARK: A user-initiated waiter fails fast when a later 429 extends the throttle (R-SYN-5; cycle-15 verifier)

    /// A user-initiated request waits for an origin throttle only while its end is within `interactiveMaxWait` (sync.md
    /// §7.6, `RetryPolicy.interactiveMaxWait`). One parked by a 1 s throttle waited, and a later 429 that extended the
    /// throttle to 60 s left it waiting 60 s, while a request made a moment later was told
    /// `.serverUnavailable(retryAfter: 60)` (PROBE-EXTEND). The extension now gives it that answer at once (F-36).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user-initiated request waiting for a short throttle fails fast once a later 429 extends the throttle beyond interactiveMaxWait", .timeLimit(.minutes(1)))
    func userWaiterFailsFastOnExtension() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4))
        let bytesA = EngineFixture.bytes(5_301)
        let bytesB = EngineFixture.bytes(5_302)
        let a = EngineHarness.onDemand("a", bytesA)
        let b = EngineHarness.onDemand("b", bytesB)
        await harness.serveManifest([a, b])
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await harness.source.script(b.transferID, [.hold, .stage(bytesB)])
        await harness.source.script(a.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(1))), .stage(bytesA)])
        let callerB = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.active != nil }
        let user = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await untilFinishedOrCondition(user, engine) { $0.state.jobs[a.transferID]?.state.isThrottleParked == true }
        let parked = await engine.readForTests { engine in
            engine.state.jobs[a.transferID]?.interests.values.contains { $0.lane == .userInitiated } == true
        }
        try #require(parked, "setup: the user request waits for the 1 s throttle, within interactiveMaxWait")
        await harness.source.release(b.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state.isThrottleParked == true }
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let after = await engine.readForTests { engine in
            (
                engine.state.jobs[a.transferID]?.interests.values.contains { $0.lane == .userInitiated } == true,
                engine.state.throttles[origin],
                engine.environment.time.monotonicNow(),
                engine.invariantViolations()
            )
        }
        let throttleEnd = try #require(after.1, "setup: the origin is throttled")
        #expect(!after.0, "the user request is answered once the throttle ends beyond interactiveMaxWait, not at \(throttleEnd)")
        #expect(after.3.isEmpty, "\(after.3)")
        if after.0 {
            await engine.shutdown()
        }
        let answered = await joinCancelling(user)
        #expect(answered == .failure(.serverUnavailable(retryAfter: throttleEnd.seconds(since: after.2))), "the user request fails fast with the origin's wait: \(answered)")
        await engine.shutdown()
        _ = await joinCancelling(callerB)
    }

    /// The same extension made by a run's manifest 429: a user-initiated request parked by a 1 s transfer 429 waits,
    /// and the held manifest fetch then answers 429 with 60 s, extending the origin's throttle (F-35 keeps the later
    /// end): the waiting request gets the fail-fast answer for the new end at once (F-36).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user-initiated request waiting for a short throttle fails fast once a manifest 429 extends the throttle beyond interactiveMaxWait", .timeLimit(.minutes(1)))
    func userWaiterFailsFastOnManifestExtension() async throws {
        let fake = FakeRemoteSource()
        let held = HeldManifestSource(base: fake)
        let harness = EngineHarness.make(source: fake, remote: held)
        let bytes = EngineFixture.bytes(5_401)
        let onDemand = EngineHarness.onDemand("asset", bytes)
        await harness.serveManifest([onDemand])
        let engine = harness.engine
        let origin = fake.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await fake.scriptManifest([
            .fail(.transient(.throttled, retryAfter: .seconds(60))),
            .notModified,
        ])
        await held.holdNext()
        let run = Task { await engine.sync(.force) }
        await held.waitForHeldFetch()
        await fake.script(onDemand.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(1))), .stage(bytes)])
        let user = Task { await engine.awaitAsset(onDemand.identifier, lane: .userInitiated) }
        await untilFinishedOrCondition(user, engine) { $0.state.jobs[onDemand.transferID]?.state.isThrottleParked == true }
        let parked = await engine.readForTests { engine in
            engine.state.jobs[onDemand.transferID]?.interests.values.contains { $0.lane == .userInitiated } == true
        }
        try #require(parked, "setup: the user request waits for the 1 s throttle, within interactiveMaxWait")
        await held.release()
        let outcome = await joinCancelling(run)
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let after = await engine.readForTests { engine in
            (
                engine.state.jobs[onDemand.transferID]?.interests.values.contains { $0.lane == .userInitiated } == true,
                engine.state.throttles[origin],
                engine.environment.time.monotonicNow(),
                engine.invariantViolations()
            )
        }
        let throttleEnd = try #require(after.1, "setup: the origin is throttled")
        if case .blocked(.throttled(let until), _) = outcome {
            #expect(until == throttleEnd, "the run reports the throttle's end")
        } else {
            Issue.record("the run is blocked by the throttle: \(outcome)")
        }
        #expect(!after.0, "the user request is answered once the throttle ends beyond interactiveMaxWait, not at \(throttleEnd)")
        #expect(after.3.isEmpty, "\(after.3)")
        if after.0 {
            await engine.shutdown()
        }
        let answered = await joinCancelling(user)
        #expect(answered == .failure(.serverUnavailable(retryAfter: throttleEnd.seconds(since: after.2))), "the user request fails fast with the origin's wait: \(answered)")
        await engine.shutdown()
    }

    /// The answers to an extension come in turns of their own, at most `parksPerPump` jobs a turn (each answer costs about
    /// what a park does, C2); a later turn takes the rest. More user-initiated waiters than one turn answers wait for a
    /// 1 s throttle when a 60 s 429 extends it: every one of them gets the fail-fast answer, none is left waiting.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: when a 429 extends the throttle under more user-initiated waiters than one turn answers, every waiter fails fast", .timeLimit(.minutes(1)))
    func everyUserWaiterFailsFastOnExtension() async throws {
        let count = SyncEngine.parksPerPump + 8
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4))
        let bytesA = EngineFixture.bytes(5_501)
        let bytesB = EngineFixture.bytes(5_502)
        let a = EngineHarness.onDemand("a", bytesA)
        let b = EngineHarness.onDemand("b", bytesB)
        let users = (0..<count).map { EngineHarness.onDemand("u\($0)", EngineFixture.bytes(UInt64(20_000 + $0))) }
        await harness.serveManifest([a, b] + users)
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await harness.source.script(b.transferID, [.hold, .stage(bytesB)])
        await harness.source.script(a.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(1))), .stage(bytesA)])
        let callerB = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.active != nil }
        let callerA = Task { await engine.awaitAsset(a.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state.isThrottleParked == true }
        // Every user request is parked by the 1 s throttle and waits: its end is within interactiveMaxWait.
        var waiting: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in users {
            waiting.append(Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) })
        }
        await engine.awaitCondition { engine in
            engine.state.throttleParked.count == count + 1 && engine.state.waiters.count == count + 2 && !engine.state.pumpFollowUpScheduled
        }
        await harness.source.release(b.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state.isThrottleParked == true }
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) && !$0.state.throttleAnswersScheduled }
        let after = await engine.readForTests { engine in
            (engine.state.waiters.count, engine.state.throttles[origin], engine.environment.time.monotonicNow(), engine.invariantViolations())
        }
        let throttleEnd = try #require(after.1, "setup: the origin is throttled")
        #expect(after.0 == 2, "only the two prefetch callers still wait: \(after.0 - 2) user requests were left waiting")
        #expect(after.3.isEmpty, "\(after.3)")
        if after.0 != 2 {
            await engine.shutdown()
        }
        let expected = Result<AssetLocation, AssetError>.failure(.serverUnavailable(retryAfter: throttleEnd.seconds(since: after.2)))
        var answers: [Result<AssetLocation, AssetError>] = []
        for task in waiting {
            answers.append(await joinCancelling(task))
        }
        #expect(answers.filter { $0 != expected }.isEmpty, "every user request fails fast with the origin's wait: \(answers.filter { $0 != expected }.count) did not")
        await engine.shutdown()
        _ = await joinCancelling(callerA)
        _ = await joinCancelling(callerB)
    }

    // MARK: Which parked claims a follow-up turn still owes a re-queue (R-SYN-6; F-36)

    /// The run's check (`OwedRequeues`) mirrors what the next re-admission turn takes: the jobs an event owed
    /// (`originOwed` for a closed breaker or an ended throttle, `edgeOwed` for a satisfied network edge) and, while a
    /// conditions pass is owed, the jobs a lane-wide gate parked in a lane the conditions now admit. The breaker, edge and
    /// conditions cases share the throttle case's mechanism (the test above); this pins each branch and the jobs that
    /// stay parked.
    @Test("R-SYN-6: a parked claim counts as owed a re-queue exactly when a follow-up re-admission turn will take it")
    func owedRequeuesMirrorTheFollowUp() {
        let entry = EngineFixture.entry("owed", EngineFixture.bytes(9_001))
        func job(_ state: JobState, lane: AssetPriority) -> Job {
            var job = Job(
                transfer: entry.transferID,
                entry: entry,
                identity: entry.contentIdentity,
                assets: [entry.identifier],
                state: state,
                epoch: 1,
                queuedAt: MonotonicInstant(nanoseconds: 0)
            )
            job.interests[InterestToken(rawValue: 1)] = JobInterest(lane: lane, kind: .run, assets: [entry.identifier])
            return job
        }
        let transfer = entry.transferID
        let throttled = job(.blocked(.throttled(until: MonotonicInstant(nanoseconds: 1))), lane: .bulk)
        let offline = job(.blocked(.offline), lane: .bulk)
        let whenOnline = job(.failed(.whenOnline), lane: .bulk)
        let none = OwedRequeues(origin: [], edge: [], lanes: [])
        // Owed by an event: the origin's (a closed breaker, an ended throttle) or a network edge's.
        #expect(OwedRequeues(origin: [transfer], edge: [], lanes: []).contains(transfer, throttled))
        #expect(OwedRequeues(origin: [], edge: [transfer], lanes: []).contains(transfer, whenOnline))
        #expect(!none.contains(transfer, throttled), "a throttle-parked claim no event owes waits for its gate")
        #expect(!none.contains(transfer, whenOnline), "a claim failed whenOnline no edge owes waits for one")
        // Owed by a conditions pass: lane-parked, in a lane the conditions admit, while the pass is owed.
        #expect(OwedRequeues(origin: [], edge: [], lanes: [.bulk]).contains(transfer, offline))
        #expect(!OwedRequeues(origin: [], edge: [], lanes: [.prefetch, .userInitiated]).contains(transfer, offline), "a lane the conditions still refuse")
        #expect(!none.contains(transfer, offline), "no conditions pass is owed")
        #expect(!OwedRequeues(origin: [], edge: [], lanes: [.bulk]).contains(transfer, throttled), "a conditions pass takes only lane-parked jobs")
    }
}
