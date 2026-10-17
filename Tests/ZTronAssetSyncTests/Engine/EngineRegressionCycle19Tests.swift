import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 19 of the level-4 close-out (`docs/adr-drafts/f.md`, F-39): a run that settled blocked by an
/// origin gate the clock had already opened while the alarm's turn that re-queues its claim had not run, and the throttle
/// end a run that settled on its claims reports, and its pending run waits for, when a 429 extends the throttle after the
/// run settled. Every wait is a condition, a held seam or a join that ends on cancellation, and every clock move is made
/// while the alarm's turn is held or from a quiet engine (`EngineRegressionCycle15Tests.quiet`) (L4-R17).
@Suite("Engine regressions, close-out cycle 19")
struct EngineRegressionCycle19Tests {
    /// Whether `event` is a `syncFinished`.
    static func isFinish(_ event: AssetEvent) -> Bool {
        if case .syncFinished = event {
            return true
        }
        return false
    }

    /// The test's own failure for a held attempt: a 400 the run records as failed, never retried within the run.
    static let rejected = TransferError.rejected(.unexpectedStatus(400))

    // MARK: A run waits for the alarm's turn at an origin gate's end (R-SYN-5, R-SYN-6; cycle-18 correctness verifier)

    /// At the throttle's end the alarm's turn clears the throttle and re-queues the jobs it parked. That turn waits for
    /// the alarm's wake-up and for its place in the actor's queue, while the throttle's gate is already open
    /// (`gate` blocks only while the end is in the future). A run whose last working claim ended in that window settled
    /// `.blocked(.throttled(until:))` with an end already past: its parked claim's job was retired, the pending run was
    /// armed at that end, and the alarm's turn started a second run and a second manifest request (the cycle-18
    /// correctness verifier's PROBE-C18C-ALARMLAG, which reached the order 198 times in 200 without a seam). The alarm's
    /// turn is held here (`holdAlarmTurns()`), so the order is fixed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose last working claim ends after the throttle's end but before the alarm's turn waits for the alarm instead of settling blocked by the ended throttle", .timeLimit(.minutes(1)))
    func runWaitsForTheAlarmAtTheThrottlesEnd() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        let heldBytes = EngineFixture.bytes(9_101)
        let parkedBytes = EngineFixture.bytes(9_102)
        let held = EngineFixture.entry("held", heldBytes)
        let parked = EngineFixture.entry("parked", parkedBytes)
        await harness.serveManifest([held, parked])
        // `held` waits in flight until the test ends it; a later attempt (a second run's) is rejected at once.
        await harness.source.script(held.transferID, [.hold, .fail(Self.rejected)])
        await harness.source.script(parked.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(30))), .stage(parkedBytes)])
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        await engine.awaitCondition { $0.state.jobs[parked.transferID]?.state.isThrottleParked == true && $0.state.jobs[held.transferID]?.active != nil }
        let setup = await engine.readForTests { engine in
            (engine.state.throttles[origin], engine.state.run?.id, engine.state.run?.token, engine.state.lastRunID)
        }
        let end = try #require(setup.0, "setup: the 429 throttles the origin")
        let runID = try #require(setup.1, "setup: the launch run is in place")
        let token = try #require(setup.2, "setup: the launch run is in place")
        let requests = await harness.source.manifestRequests.count
        await engine.holdAlarmTurns()
        harness.time.advance(to: end)
        await engine.awaitCondition { $0.alarmTurnHeld }
        // The throttle has ended; the alarm's turn that clears it and re-queues the parked claim waits.
        await harness.source.release(held.transferID, with: .failed(Self.rejected))
        await engine.awaitCondition { $0.state.run?.outstanding[held.transferID] == nil }
        let between = await engine.readForTests { engine in
            (engine.state.run?.id, engine.state.run?.settlement, engine.state.jobs[parked.transferID]?.interests[token] != nil, engine.state.lastRunID)
        }
        #expect(between.0 == runID, "the launch run is still the run in place: \(String(describing: between.0))")
        #expect(between.1 == nil, "the run waits for the alarm's turn instead of settling: \(String(describing: between.1))")
        #expect(between.2, "the parked claim keeps the run's interest")
        #expect(between.3 == setup.3, "no second run started: \(between.3)")
        await engine.releaseAlarmTurns()
        let finished = await probe.next { Self.isFinish($0) }
        guard case .syncFinished(let id, .completeWithFailures(let report))? = finished else {
            // A run that settled blocked left its claim's job retired and a pending run behind: nothing below is defined.
            Issue.record("the run completes once the alarm's turn re-queued its parked claim: \(String(describing: finished))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        #expect(id == runID, "the launch run finished")
        #expect(report.failedCount == 1, "only the rejected asset failed: \(report.failedCount)")
        #expect(report.fetched == 1, "the parked claim was fetched after the alarm's turn: \(report.fetched)")
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let after = await engine.readForTests { $0.state.lastRunID }
        #expect(after == setup.3, "no second run started: \(after - setup.3)")
        let made = await harness.source.manifestRequests.count
        #expect(made == requests, "no manifest request was made: \(made - requests)")
        await probe.stop()
        await engine.shutdown()
    }

    /// The breaker's twin of the test above. Its cooldown's end re-admits the jobs it parked in the alarm's turn of the
    /// `.breaker` deadline (`unblockOrigin(.circuitOpen)`); before that turn the gate admits a probe already
    /// (`CircuitBreaker.admit` half-opens lazily). A run whose last working claim ended in that window settled
    /// `.blocked(.circuitOpen)`: its parked claim's job was retired and the pending run, its breaker gate already open,
    /// started a second run whose manifest fetch was the probe (found in this cycle while checking the verifier's
    /// suggestion; held seam as above).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose last working claim ends after the breaker's cooldown but before the alarm's turn waits for the alarm instead of settling blocked by the open breaker", .timeLimit(.minutes(1)))
    func runWaitsForTheAlarmAtTheCooldownsEnd() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<3).map { index in
            let bytes = EngineFixture.bytes(9_201 + UInt64(index))
            return (EngineFixture.entry("breaker-\(index)", bytes), bytes)
        }
        await harness.serveManifest(catalog.map(\.0))
        let engine = harness.engine
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        // No attempt is scripted yet: two wait in flight, the third waits in the queue for a slot.
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 2 && engine.state.jobs.values.contains { $0.state == .queued }
        }
        let roles = await engine.readForTests { engine in
            (
                engine.state.jobs.filter { $0.value.active != nil }.keys.sorted(),
                engine.state.jobs.first { $0.value.state == .queued }?.key,
                engine.state.run?.id,
                engine.state.run?.token,
                engine.state.lastRunID
            )
        }
        try #require(roles.0.count == 2, "setup: two attempts are in flight")
        let held = roles.0[0]
        let failing = roles.0[1]
        let parked = try #require(roles.1, "setup: one claim waits for a slot")
        let runID = try #require(roles.2, "setup: the launch run is in place")
        let token = try #require(roles.3, "setup: the launch run is in place")
        let parkedBytes = try #require(catalog.first { $0.0.transferID == parked }?.1)
        // The parked claim stages once it is re-queued; a later attempt of the other two (a second run's) is rejected.
        await harness.source.script(parked, [.stage(parkedBytes)])
        await harness.source.script(held, [.hold, .fail(Self.rejected)])
        let evidence = EngineFailurePathTests.evidence(.asset, xml: true, bytes: 120)
        await harness.source.script(failing, [.fail(.authentication(.forbiddenAmbiguous(evidence))), .fail(Self.rejected)])
        await engine.awaitCondition { $0.state.jobs[parked]?.state.isCircuitParked == true }
        let cooldown = await engine.readForTests { engine -> MonotonicInstant? in
            guard let breaker = engine.state.breakers[harness.source.originID], case .open(_, let until, _) = breaker.state else {
                return nil
            }
            return until
        }
        let end = try #require(cooldown, "setup: the 403 opened the breaker")
        let requests = await harness.source.manifestRequests.count
        await engine.holdAlarmTurns()
        harness.time.advance(to: end)
        await engine.awaitCondition { $0.alarmTurnHeld }
        // The cooldown has ended; the alarm's turn that re-queues the parked claim waits.
        await harness.source.release(held, with: .failed(Self.rejected))
        await engine.awaitCondition { $0.state.run?.outstanding[held] == nil }
        let between = await engine.readForTests { engine in
            (engine.state.run?.id, engine.state.run?.settlement, engine.state.jobs[parked]?.interests[token] != nil, engine.state.lastRunID)
        }
        #expect(between.0 == runID, "the launch run is still the run in place: \(String(describing: between.0))")
        #expect(between.1 == nil, "the run waits for the alarm's turn instead of settling: \(String(describing: between.1))")
        #expect(between.2, "the parked claim keeps the run's interest")
        #expect(between.3 == roles.4, "no second run started: \(between.3)")
        await engine.releaseAlarmTurns()
        let finished = await probe.next { Self.isFinish($0) }
        guard case .syncFinished(let id, .completeWithFailures(let report))? = finished else {
            // A run that settled blocked left its claim's job retired and a pending run behind, whose runs probe the
            // breaker with attempts this test does not script: nothing below is defined.
            Issue.record("the run completes once the alarm's turn re-queued its parked claim: \(String(describing: finished))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        #expect(id == runID, "the launch run finished")
        #expect(report.failedCount == 2, "the rejected and the forbidden assets failed: \(report.failedCount)")
        #expect(report.fetched == 1, "the parked claim was fetched as the probe after the alarm's turn: \(report.fetched)")
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let after = await engine.readForTests { $0.state.lastRunID }
        #expect(after == roles.4, "no second run started: \(after - roles.4)")
        let made = await harness.source.manifestRequests.count
        #expect(made == requests, "no manifest request was made: \(made - requests)")
        await probe.stop()
        await engine.shutdown()
    }

    // MARK: A run settled on throttled claims reports, and waits for, the origin's end (R-SYN-5, R-SYN-6; cycle-18 verifier)

    /// A launch run whose two claims and a prefetch transfer (no claim of the run) wait in flight: one claim's 429
    /// throttles the origin for 30 s and parks it, and the other claim is then rejected, so the run settles
    /// `.blocked(.throttled(until:))` on the parked claim with its pending run at the throttle's end. The prefetch
    /// transfer's 429, which the caller sends, extends the throttle.
    @available(macOS 15.0, iOS 18.0, *)
    struct SettledOnThrottle {
        let harness: EngineHarness
        let probe: EventProbe
        /// The prefetch transfer held in flight; its 429 extends the throttle.
        let extender: TransferID
        /// The throttle's end the claim's 429 set.
        let firstEnd: MonotonicInstant
        /// The launch run's number.
        let lastRunID: UInt64
        /// The manifest requests made before the run settled.
        let requests: Int
        /// The prefetch group's token.
        let group: InterestToken
    }

    /// Builds `SettledOnThrottle`; with `holdSettlement` the settlement waits for `releaseRunSettlementDelivery()`
    /// (the run has settled once `runSettlementHeld`), otherwise the run has answered when this returns, with the
    /// outcome in `answered`.
    @available(macOS 15.0, iOS 18.0, *)
    static func settledOnThrottle(holdSettlement: Bool) async throws -> (SettledOnThrottle, answered: AssetEvent?) {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        let heldBytes = EngineFixture.bytes(9_301)
        let parkedBytes = EngineFixture.bytes(9_302)
        let extenderBytes = EngineFixture.bytes(9_303)
        let held = EngineFixture.entry("held", heldBytes)
        let parked = EngineFixture.entry("parked", parkedBytes)
        let extender = EngineHarness.onDemand("extender", extenderBytes)
        await harness.serveManifest([held, parked, extender])
        // Each first attempt waits in flight; a later attempt (a second run's) ends at once.
        await harness.source.script(held.transferID, [.hold, .fail(Self.rejected)])
        await harness.source.script(parked.transferID, [.hold, .stage(parkedBytes)])
        await harness.source.script(extender.transferID, [.hold, .stage(extenderBytes)])
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        await engine.awaitCondition { $0.state.jobs[held.transferID]?.active != nil && $0.state.jobs[parked.transferID]?.active != nil }
        let group = try await engine.registerGroup([extender.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[extender.transferID]?.active != nil }
        await harness.source.release(parked.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(30))))
        await engine.awaitCondition { $0.state.jobs[parked.transferID]?.state.isThrottleParked == true }
        let setup = await engine.readForTests { engine in (engine.state.throttles[origin], engine.state.lastRunID) }
        let firstEnd = try #require(setup.0, "setup: the claim's 429 throttles the origin")
        let requests = await harness.source.manifestRequests.count
        if holdSettlement {
            await engine.holdRunSettlementDelivery()
        }
        // The run's other claim ends while the throttle is in force: the run settles on the parked claim.
        await harness.source.release(held.transferID, with: .failed(Self.rejected))
        let answered: AssetEvent?
        if holdSettlement {
            await engine.awaitCondition { $0.runSettlementHeld }
            answered = nil
        } else {
            answered = await probe.next { Self.isFinish($0) }
        }
        let settled = SettledOnThrottle(harness: harness, probe: probe, extender: extender.transferID, firstEnd: firstEnd, lastRunID: setup.1, requests: requests, group: group)
        return (settled, answered)
    }

    /// Lets the prefetch transfer's 429 extend the origin's throttle to 60 s; returns the extended end.
    @available(macOS 15.0, iOS 18.0, *)
    static func extend(_ settled: SettledOnThrottle) async throws -> MonotonicInstant {
        let engine = settled.harness.engine
        let origin = settled.harness.source.originID
        let firstEnd = settled.firstEnd
        await settled.harness.source.release(settled.extender, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        await engine.awaitCondition { ($0.state.throttles[origin] ?? .zero) > firstEnd }
        let extended = await engine.readForTests { $0.state.throttles[origin] }
        return try #require(extended, "setup: the origin stays throttled")
    }

    /// Moves the clock from a quiet engine to the throttle's first end and requires that no run started and no manifest
    /// request was made: the throttle is still in force there.
    @available(macOS 15.0, iOS 18.0, *)
    static func requireNoRunAtFirstEnd(_ settled: SettledOnThrottle) async {
        let engine = settled.harness.engine
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        settled.harness.time.advance(to: settled.firstEnd)
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let after = await engine.readForTests { $0.state.lastRunID }
        #expect(after == settled.lastRunID, "no run started at the throttle's first end: \(after - settled.lastRunID)")
        let made = await settled.harness.source.manifestRequests.count
        #expect(made == settled.requests, "no manifest request was made: \(made - settled.requests)")
    }

    /// A run that settles on claims a throttle parked answers in its own task's later turn (`awaitRunSettlement`, at
    /// `.utility`), and a transfer's 429 handled before that turn extends the origin's throttle. The run reported the end
    /// its settling turn read, and its pending run stayed at that end: the caller and `syncFinished` were told to retry
    /// 30 s before the throttle ended, and at that end the pending run started a run the throttle refused at its manifest
    /// step (the cycle-18 correctness verifier's PROBE-C18C-CLAIMEND-N, 572 to 599 of 600 without a seam, and
    /// -CLAIMEND-CONSEQ). The settlement is held from the run's task here (`holdRunSettlementDelivery()`), so the order is
    /// fixed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a run that settled on claims a throttle parked reports the origin's end when a 429 extends the throttle before the run answers", .timeLimit(.minutes(1)))
    func settledRunReportsExtendedEnd() async throws {
        let (settled, _) = try await Self.settledOnThrottle(holdSettlement: true)
        let engine = settled.harness.engine
        let origin = settled.harness.source.originID
        let extended = try await Self.extend(settled)
        await engine.releaseRunSettlementDelivery()
        let finished = await settled.probe.next { Self.isFinish($0) }
        let after = await engine.readForTests { engine in
            (engine.state.throttles[origin], engine.state.heap.deadline(for: .pendingRun), engine.state.pendingRun?.gate)
        }
        #expect(after.0 == extended, "nothing moved the throttle after the prefetch transfer's 429")
        if case .syncFinished(_, .blocked(.throttled(let until), _))? = finished {
            #expect(until == extended, "the run reports the origin's throttle end \(extended), not \(until)")
        } else {
            Issue.record("the run is blocked by the throttle: \(String(describing: finished))")
        }
        #expect(after.1 == extended, "the pending run waits for the origin's end: \(String(describing: after.1)), the end \(extended)")
        #expect(after.2 == .throttle, "the pending run waits for the throttle: \(String(describing: after.2))")
        await Self.requireNoRunAtFirstEnd(settled)
        await engine.releaseGroup(settled.group)
        await settled.probe.stop()
        await engine.shutdown()
    }

    /// A throttle-gated pending run was scheduled once, at the end the run settled with: a 429 that extended the throttle
    /// after the run answered left it there, and at that end it started a run the throttle refused at its manifest step,
    /// which published a spurious `syncFinished(.blocked)` and re-armed (the cycle-18 correctness verifier's observation;
    /// its PROBE-C18C-RUNEND-N reached the state on the manifest path in 303 and 452 of 600). The pending run now follows
    /// the throttle's end whenever a 429 moves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a throttle-gated pending run waits for the origin's end when a 429 extends the throttle after the run answered", .timeLimit(.minutes(1)))
    func pendingRunFollowsExtendedThrottle() async throws {
        let (settled, answered) = try await Self.settledOnThrottle(holdSettlement: false)
        let engine = settled.harness.engine
        let origin = settled.harness.source.originID
        if case .syncFinished(_, .blocked(.throttled(let until), _))? = answered {
            #expect(until == settled.firstEnd, "the run reports the throttle's end when it answered")
        } else {
            Issue.record("setup: the run is blocked by the throttle: \(String(describing: answered))")
        }
        let extended = try await Self.extend(settled)
        let after = await engine.readForTests { engine in
            (engine.state.throttles[origin], engine.state.heap.deadline(for: .pendingRun), engine.state.pendingRun?.gate)
        }
        #expect(after.0 == extended, "nothing moved the throttle after the prefetch transfer's 429")
        #expect(after.1 == extended, "the pending run waits for the origin's extended end: \(String(describing: after.1)), the end \(extended)")
        #expect(after.2 == .throttle, "the pending run waits for the throttle: \(String(describing: after.2))")
        await Self.requireNoRunAtFirstEnd(settled)
        await engine.releaseGroup(settled.group)
        await settled.probe.stop()
        await engine.shutdown()
    }
}
