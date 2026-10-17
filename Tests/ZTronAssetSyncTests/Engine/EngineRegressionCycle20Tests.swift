import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 20 of the level-4 close-out (`docs/adr-drafts/f.md`, F-40): the two members of the
/// stale-gate family the cycle-19 verifiers found. (A) A half-open breaker whose probe is silent past its watchdog admits
/// the next transfer, while the jobs it parked wait for the alarm's turn at the watchdog; a run whose last working claim
/// ended in between settled blocked by that breaker. (B) A probe that ends without a verdict leaves `halfOpen(probe: nil)`
/// and nothing re-admitted the jobs the breaker parked: the run settled blocked, and its pending run, its gate open,
/// started one run and one manifest request per parked missing asset without the clock moving. Every wait is a
/// condition, a held seam or a join that ends on cancellation; the clock moves only while the alarm's turn is held or
/// from an engine with nothing due (L4-R17).
@Suite("Engine regressions, close-out cycle 20")
struct EngineRegressionCycle20Tests {
    /// The test's own failure for a held attempt: a 400 the run records as failed, never retried within the run.
    static let rejected = TransferError.rejected(.unexpectedStatus(400))

    /// The 404 a missing object answers.
    static let missing = TransferError.permanentMissing(httpStatus: 404)

    /// The ambiguous 403 that opens the authentication breaker at once under `authDistinctAssets: 1`.
    static let forbidden = TransferError.authentication(.forbiddenAmbiguous(EngineFailurePathTests.evidence(.asset, xml: true, bytes: 120)))

    /// The breaker state of the harness's origin.
    @available(macOS 15.0, iOS 18.0, *)
    static func breaker(_ engine: SyncEngine, _ origin: String) async -> CircuitBreaker.State? {
        await engine.readForTests { $0.state.breakers[origin]?.state }
    }

    // MARK: (A) A silent probe's watchdog (R-SYN-6; L4-C19-00, L4-C19-07)

    /// After the cooldown a prefetch member becomes the half-open probe and stays silent; the run's claim `parked` is
    /// rejected behind it until the probe's watchdog. At the watchdog the gate admits `parked` as the next probe
    /// (`CircuitBreaker.admit`), while only the `.breaker` deadline's alarm turn re-queued it. A run whose last working
    /// claim ended between the watchdog and that turn settled `.blocked(.circuitOpen)`: its claim's job was retired, and
    /// the alarm's turn started a second run whose manifest fetch was the probe (PROBE-C19R-WATCHDOG and
    /// PROBE-C19C-HALFWATCH; 192 to 198 of 200 without a seam at `d5191e2`). The alarm's turn is held here, so the order is
    /// fixed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose last working claim ends after a half-open probe's watchdog but before the alarm's turn neither settles blocked by the breaker nor starts a second run", .timeLimit(.minutes(1)))
    func silentProbesWatchdogKeepsTheRun() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 3, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<4).map { index in
            let bytes = EngineFixture.bytes(9_301 + UInt64(index))
            return (EngineFixture.entry("watchdog-\(index)", bytes), bytes)
        }
        let memberBytes = EngineFixture.bytes(9_311)
        let member = EngineHarness.onDemand("watchdog-member", memberBytes)
        await harness.serveManifest(catalog.map(\.0) + [member])
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        // No attempt is scripted yet: three wait in flight, the fourth claim waits in the queue for a slot.
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 3 && engine.state.jobs.values.contains { $0.state == .queued }
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
        try #require(roles.0.count == 3, "setup: three attempts are in flight")
        let working = roles.0[0]
        let failing = roles.0[1]
        let other = roles.0[2]
        let parked = try #require(roles.1, "setup: one claim waits for a slot")
        let runID = try #require(roles.2, "setup: the launch run is in place")
        let token = try #require(roles.3, "setup: the launch run is in place")
        let parkedBytes = try #require(catalog.first { $0.0.transferID == parked }?.1)
        // The prefetch member queues behind the run's claims (every slot is taken).
        _ = try await engine.registerGroup([member.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[member.transferID]?.state == .queued }
        // The 403 opens the breaker: the freed slot's dispatch parks the member and the queued claim behind it.
        await harness.source.script(failing, [.fail(Self.forbidden)])
        await engine.awaitCondition { engine in
            engine.state.jobs[member.transferID]?.state.isCircuitParked == true && engine.state.jobs[parked]?.state.isCircuitParked == true
        }
        guard case .open(_, let cooldownEnd, _)? = await Self.breaker(engine, origin) else {
            Issue.record("setup: the 403 opened the breaker")
            await engine.shutdown()
            return
        }
        // The cooldown's turn re-queues both: the member (prefetch ranks ahead of the run's lane) probes and stays silent;
        // the claim waits for a slot.
        harness.time.advance(to: cooldownEnd)
        await engine.awaitCondition { engine in
            engine.state.jobs[member.transferID]?.active != nil && engine.state.jobs[parked]?.state == .queued
        }
        // `other` is rejected: its slot's dispatch parks the claim behind the silent probe until its watchdog.
        await harness.source.script(other, [.fail(Self.rejected)])
        await engine.awaitCondition { $0.state.jobs[parked]?.state.isCircuitParked == true }
        guard case .halfOpen(_, _, member.transferID?, let watchdog?)? = await Self.breaker(engine, origin) else {
            Issue.record("setup: the member is the half-open probe: \(String(describing: await Self.breaker(engine, origin)))")
            await engine.shutdown()
            return
        }
        let requests = await harness.source.manifestRequests.count
        await engine.holdAlarmTurns()
        harness.time.advance(to: watchdog)
        await engine.awaitCondition { $0.alarmTurnHeld }
        // The watchdog has passed: the gate admits the parked claim as the next probe, and the alarm's turn waits.
        await harness.source.script(working, [.fail(Self.rejected)])
        await engine.awaitCondition { $0.state.run?.outstanding[working] == nil }
        let between = await engine.readForTests { engine in
            (engine.state.run?.id, engine.state.run?.settlement, engine.state.jobs[parked]?.interests[token] != nil, engine.state.lastRunID)
        }
        #expect(between.0 == runID, "the launch run is still the run in place: \(String(describing: between.0))")
        #expect(between.1 == nil, "the run does not settle blocked by a breaker that admits its claim: \(String(describing: between.1))")
        #expect(between.2, "the parked claim keeps the run's interest")
        #expect(between.3 == roles.4, "no second run started: \(between.3)")
        await engine.releaseAlarmTurns()
        // The claim is the new probe (now, or after the alarm's turn): it stages, the breaker closes, and the run completes.
        await harness.source.script(parked, [.stage(parkedBytes)])
        let finished = await probe.next { EngineRegressionCycle19Tests.isFinish($0) }
        guard case .syncFinished(let id, .completeWithFailures(let report))? = finished else {
            // A run that settled blocked left its claim's job retired and a pending run behind, whose runs probe the
            // breaker with attempts this test does not script: nothing below is defined.
            Issue.record("the run completes with its parked claim fetched as the next probe: \(String(describing: finished))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        #expect(id == runID, "the launch run finished")
        #expect(report.fetched == 1, "the parked claim was fetched as the probe after the watchdog: \(report.fetched)")
        #expect(report.failedCount == 3, "the forbidden and the two rejected assets failed: \(report.failedCount)")
        // The silent member ends; its outcome no longer counts (it is not the probe any more).
        await harness.source.script(member.transferID, [.fail(Self.rejected)])
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let after = await engine.readForTests { ($0.state.lastRunID, $0.state.breakers[origin]?.state) }
        #expect(after.0 == roles.4, "no second run started: \(after.0 - roles.4)")
        #expect(after.1 == .closed, "the claim's success closed the breaker: \(String(describing: after.1))")
        let made = await harness.source.manifestRequests.count
        #expect(made == requests, "no manifest request was made: \(made - requests)")
        await probe.stop()
        await engine.shutdown()
    }

    // MARK: (B) A probe's exit without a verdict (R-SYN-5, R-SYN-14; L4-C19-08)

    /// After the cooldown the first re-queued claim probes and the run's other claims park behind it. Every object but one
    /// held claim answers 404, a neutral exit: the breaker returned to `halfOpen(probe: nil)` and nothing re-admitted the
    /// parked claims (only the probe's old watchdog deadline, up to a minute later, would have). When the held claim
    /// ended, the run settled `.blocked(.circuitOpen)`; its pending run's gate read open, so the next run started at once,
    /// its manifest fetch probed (a 304, neutral again), its first claim probed and 404'd, and so on: one run and one
    /// manifest request per parked missing asset, the clock never moving (PROBE-C19C-HALFNIL-NATURAL: 7 runs for 6 parked
    /// claims, 23 for 19). Each exit without a verdict now lets the next parked job probe, so one run fetches them all.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a half-open probe that ends without a verdict lets the next parked job probe, so the run neither settles blocked nor starts further runs without the clock moving", .timeLimit(.minutes(1)))
    func probeWithoutVerdictReadmitsParkedClaims() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<10).map { index in
            EngineFixture.entry("verdict-\(index)", EngineFixture.bytes(9_401 + UInt64(index)))
        }
        await harness.serveManifest(catalog)
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        // No attempt is scripted yet: four wait in flight, six claims wait in the queue.
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 4 && engine.state.jobs.values.filter { $0.state == .queued }.count == 6
        }
        let roles = await engine.readForTests { engine in
            (
                engine.state.jobs.filter { $0.value.active != nil }.keys.sorted(),
                engine.state.jobs.filter { $0.value.state == .queued }.keys.sorted(),
                engine.state.run?.id,
                engine.state.lastRunID
            )
        }
        try #require(roles.0.count == 4 && roles.1.count == 6, "setup: four in flight, six queued")
        let held = roles.0[0]
        let failing = roles.0[1]
        let runID = try #require(roles.2, "setup: the launch run is in place")
        // Every object but `held` and `failing` is missing: the queued claims answer 404 whenever they start.
        for transfer in roles.1 {
            await harness.source.script(transfer, [.fail(Self.missing)])
        }
        await harness.source.script(failing, [.fail(Self.forbidden)])
        await engine.awaitCondition { engine in roles.1.allSatisfy { engine.state.jobs[$0]?.state.isCircuitParked == true } }
        for transfer in roles.0[2...] {
            await harness.source.script(transfer, [.fail(Self.missing)])
        }
        await engine.awaitCondition { engine in engine.state.inFlight == [held] }
        guard case .open(_, let cooldownEnd, _)? = await Self.breaker(engine, origin) else {
            Issue.record("setup: the 403 opened the breaker")
            await engine.shutdown()
            return
        }
        let requests = await harness.source.manifestRequests.count
        // The cooldown's turn re-queues the six; the first probes and 404s. From here on the clock never moves.
        harness.time.advance(to: cooldownEnd)
        await engine.awaitCondition { engine in
            guard case .halfOpen(_, _, nil, _)? = engine.state.breakers[origin]?.state else {
                return false
            }
            return engine.state.inFlight == [held] && !engine.state.jobs.values.contains { $0.state == .queued } && engine.state.originOwed.isEmpty
        }
        let parkedAfterProbe = await engine.readForTests { engine in
            roles.1.filter { engine.state.jobs[$0]?.state.isCircuitParked == true }.count
        }
        #expect(parkedAfterProbe == 0, "every exit without a verdict let the next parked claim probe: \(parkedAfterProbe) still parked")
        // The run's last working claim ends.
        await harness.source.script(held, [.fail(Self.rejected)])
        let finished = await probe.next { EngineRegressionCycle19Tests.isFinish($0) }
        guard case .syncFinished(let id, .completeWithFailures(let report))? = finished else {
            Issue.record("the launch run completes with every claim answered: \(String(describing: finished))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        #expect(id == runID, "the launch run finished")
        #expect(report.failedCount == 10, "every asset failed (8 missing, 1 forbidden, 1 rejected): \(report.failedCount)")
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let after = await engine.readForTests { $0.state.lastRunID }
        #expect(after == roles.3, "no further run started: \(after - roles.3)")
        let made = await harness.source.manifestRequests.count
        #expect(made == requests, "no manifest request was made: \(made - requests)")
        await probe.stop()
        await engine.shutdown()
    }
}
