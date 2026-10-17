import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 21 of the level-4 close-out (`docs/adr-drafts/f.md`, F-41): a member of the stale-gate
/// family that cycle 20's re-admission introduced. A half-open probe's exit without a verdict re-admits the jobs the
/// breaker parked and, in the same turn, read the pending run's gate as open (no probe yet), so the pending run started;
/// the pump then made the next re-admitted job the probe before the run's manifest step, which the gate rejected, so the
/// run ended blocked with a new pending run, once per prefetch probe, while the clock never moved
/// (PROBE-C20C-PREFETCH-PROBES). Every wait is a condition, a held seam or a join that ends on cancellation; the clock
/// moves only from an engine with nothing due (L4-R17).
@Suite("Engine regressions, close-out cycle 21")
struct EngineRegressionCycle21Tests {
    /// Whether `event` finishes the run `id`.
    static func finishes(_ event: AssetEvent, _ id: SyncRunID) -> Bool {
        if case .syncFinished(id, _) = event {
            return true
        }
        return false
    }

    /// Moves `time` to `target` exactly. `ManualTimeSource.advance(to:)` goes through seconds as a `Double`, and
    /// `MonotonicInstant.adding(seconds:)` truncates, so it can stop 1 ns short of `target` (2,877 of 100,000 random gaps
    /// between 1 s and 300 s, the cycle-20 correctness verifier's count), where a deadline at `target` is not due yet and
    /// a gate that ends there still rejects. Each further step adds exactly 1 ns.
    @available(macOS 15.0, iOS 18.0, *)
    static func advance(_ time: ManualTimeSource, to target: MonotonicInstant) {
        time.advance(to: target)
        while time.monotonicNow() < target {
            time.advance(by: 1e-9)
        }
    }

    // MARK: Prefetch probes without a verdict start no run each (R-SYN-5, R-SYN-6; L4-C20 correctness, blocking)

    /// The launch run's 403 opens the breaker and parks its two queued claims and ten prefetch members; its held claim's
    /// 400 then ends it `.blocked(.circuitOpen)` (the breaker rejects until its cooldown's end), with a pending run that
    /// waits for the breaker. Every object answers 404 from here on, and the clock moves once, to the cooldown's end. Each
    /// member probes in turn and ends without a verdict. At `58287dc` each such exit re-admitted the parked members and
    /// started the pending run in the same turn; the next member probed before that run's manifest step, so the run ended
    /// blocked: 11 runs after the cooldown, the clock never moving. The pending run now waits for the pump that dispatches
    /// the re-admitted jobs, at the cooldown's end as after each exit, and starts once none is left to take the probe: one
    /// run follows the cooldown, its manifest request the only one, and it completes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: prefetch probes that each end without a verdict start no run per probe while the clock does not move", .timeLimit(.minutes(1)))
    func prefetchProbesStartNoRunEach() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<4).map { index in
            EngineFixture.entry("chain-\(index)", EngineFixture.bytes(9_501 + UInt64(index)))
        }
        let members = (0..<10).map { index in
            EngineHarness.onDemand("chain-member-\(index)", EngineFixture.bytes(9_521 + UInt64(index)))
        }
        await harness.serveManifest(catalog + members)
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        // No attempt is scripted yet: two claims wait in flight, two in the queue.
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 2 && engine.state.jobs.values.filter { $0.state == .queued }.count == 2
        }
        let roles = await engine.readForTests { engine in
            (
                engine.state.jobs.filter { $0.value.active != nil }.keys.sorted(),
                engine.state.jobs.filter { $0.value.state == .queued }.keys.sorted()
            )
        }
        try #require(roles.0.count == 2 && roles.1.count == 2, "setup: two claims in flight, two queued")
        let held = roles.0[0]
        let failing = roles.0[1]
        // The members queue behind the run's claims (every slot is taken).
        _ = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { engine in members.allSatisfy { engine.state.jobs[$0.transferID]?.state == .queued } }
        // The 403 opens the breaker: the freed slot's dispatch parks the queued claims and every member behind it.
        await harness.source.script(failing, [.fail(EngineRegressionCycle20Tests.forbidden)])
        let parked = roles.1 + members.map(\.transferID)
        await engine.awaitCondition { engine in parked.allSatisfy { engine.state.jobs[$0]?.state.isCircuitParked == true } }
        // Every object is missing from here on: whatever starts answers 404, as often as any run asks.
        for transfer in parked + [held, failing] {
            await harness.source.script(transfer, Array(repeating: .fail(EngineRegressionCycle20Tests.missing), count: 4))
        }
        // The held claim's 400 is the run's last working claim: the run settles blocked by the open breaker.
        await harness.source.script(held, [.fail(EngineRegressionCycle20Tests.rejected)])
        await engine.awaitCondition { $0.state.run == nil && $0.state.pendingRun != nil }
        let before = await engine.readForTests { engine in
            (engine.state.lastRunID, engine.state.breakers[origin]?.state, engine.state.pendingRun?.gate)
        }
        guard case .open(_, let cooldownEnd, _)? = before.1 else {
            Issue.record("setup: the launch run left the breaker open: \(String(describing: before.1))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        #expect(before.2 == .breaker, "setup: the pending run waits for the breaker: \(String(describing: before.2))")
        let requests = await harness.source.manifestRequests.count
        // The clock moves once, to the cooldown's end, and never again.
        Self.advance(harness.time, to: cooldownEnd)
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let after = await engine.readForTests { engine in
            (engine.state.lastRunID, members.filter { engine.state.jobs[$0.transferID]?.state.isCircuitParked == true }.count)
        }
        #expect(after.0 - before.0 == 1, "one run starts, once no member is left to probe, not one per probe (nor one the cooldown's first probe beats): \(after.0 - before.0) runs")
        #expect(after.1 == 0, "no member stays parked: \(after.1)")
        let made = await harness.source.manifestRequests.count
        #expect(made - requests <= 1, "at most one manifest request while the clock does not move: \(made - requests)")
        let lastID = SyncRunID(rawValue: after.0)
        let finished = await probe.next { Self.finishes($0, lastID) }
        guard case .syncFinished(_, .completeWithFailures)? = finished else {
            Issue.record("the last run completes with every missing asset failed: \(String(describing: finished))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        await probe.stop()
        await engine.shutdown()
    }

    // MARK: A pending run behind a silent probe starts at its watchdog (R-SYN-5; L4-C20 requirements, L4-C19-07)

    /// The run's claim parks behind a prefetch member that probes the half-open breaker and stays silent, and the run's
    /// last working claim ends before the probe's watchdog: the run settles `.blocked(.circuitOpen)` (the gate rejects
    /// then) and leaves a pending run that waits for the breaker. At the watchdog the gate admits the next transfer as the
    /// probe, so the alarm's turn starts that run, whose manifest fetch probes. A pending-run gate that read any half-open
    /// breaker with a probe as armed (mutant PEND, the reading before close-out cycle 20) left it waiting for a probe
    /// already abandoned, with no deadline left to wake it, until that probe's attempt ended.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a pending run that waits for a half-open breaker starts once its silent probe's watchdog passes", .timeLimit(.minutes(1)))
    func pendingRunStartsAtSilentProbesWatchdog() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 3, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<4).map { index in
            EngineFixture.entry("silent-\(index)", EngineFixture.bytes(9_601 + UInt64(index)))
        }
        let member = EngineHarness.onDemand("silent-member", EngineFixture.bytes(9_611))
        await harness.serveManifest(catalog + [member])
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        // No attempt is scripted yet: three wait in flight, the fourth claim waits in the queue for a slot.
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 3 && engine.state.jobs.values.contains { $0.state == .queued }
        }
        let roles = await engine.readForTests { engine in
            (engine.state.jobs.filter { $0.value.active != nil }.keys.sorted(), engine.state.jobs.first { $0.value.state == .queued }?.key)
        }
        try #require(roles.0.count == 3, "setup: three attempts are in flight")
        let working = roles.0[0]
        let failing = roles.0[1]
        let other = roles.0[2]
        let parked = try #require(roles.1, "setup: one claim waits for a slot")
        // The prefetch member queues behind the run's claims (every slot is taken).
        _ = try await engine.registerGroup([member.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[member.transferID]?.state == .queued }
        // The 403 opens the breaker: the freed slot's dispatch parks the member and the queued claim behind it.
        await harness.source.script(failing, [.fail(EngineRegressionCycle20Tests.forbidden)])
        await engine.awaitCondition { engine in
            engine.state.jobs[member.transferID]?.state.isCircuitParked == true && engine.state.jobs[parked]?.state.isCircuitParked == true
        }
        guard case .open(_, let cooldownEnd, _)? = await EngineRegressionCycle20Tests.breaker(engine, origin) else {
            Issue.record("setup: the 403 opened the breaker")
            await engine.shutdown()
            return
        }
        // The cooldown's turn re-queues both: the member (prefetch ranks ahead of the run's lane) probes and stays silent.
        Self.advance(harness.time, to: cooldownEnd)
        await engine.awaitCondition { engine in
            engine.state.jobs[member.transferID]?.active != nil && engine.state.jobs[parked]?.state == .queued
        }
        // `other` is rejected: its slot's dispatch parks the claim behind the silent probe.
        await harness.source.script(other, [.fail(EngineRegressionCycle20Tests.rejected)])
        await engine.awaitCondition { $0.state.jobs[parked]?.state.isCircuitParked == true }
        guard case .halfOpen(_, _, member.transferID?, let watchdog?)? = await EngineRegressionCycle20Tests.breaker(engine, origin) else {
            Issue.record("setup: the member is the half-open probe: \(String(describing: await EngineRegressionCycle20Tests.breaker(engine, origin)))")
            await engine.shutdown()
            return
        }
        // The run's last working claim ends before the watchdog: the run settles blocked by the breaker, which rejects.
        await harness.source.script(working, [.fail(EngineRegressionCycle20Tests.rejected)])
        await engine.awaitCondition { $0.state.run == nil && $0.state.pendingRun != nil }
        let before = await engine.readForTests { engine in
            (engine.state.lastRunID, engine.state.pendingRun?.gate)
        }
        try #require(before.1 == .breaker, "setup: the pending run waits for the breaker: \(String(describing: before.1))")
        let requests = await harness.source.manifestRequests.count
        // At the watchdog the alarm's turn either starts the pending run, or leaves nothing due and no breaker deadline.
        Self.advance(harness.time, to: watchdog)
        await engine.awaitCondition { engine in
            if engine.state.lastRunID > before.0 {
                return true
            }
            let now = engine.environment.time.monotonicNow()
            return engine.state.heap.deadline(for: .breaker(origin)) == nil && (engine.state.heap.first.map { $0.at > now } ?? true)
                && engine.state.storeWorkRuns == 0 && !engine.dispatchOwed
        }
        let started = await engine.readForTests { ($0.state.lastRunID, $0.state.run?.trigger, $0.state.pendingRun?.gate) }
        #expect(started.0 == before.0 + 1, "the pending run started at the watchdog: \(started.0 - before.0) runs, pending \(String(describing: started.2))")
        if started.0 == before.0 + 1 {
            #expect(started.1 == .breakerClosed, "the run started for the breaker's gate: \(String(describing: started.1))")
            // Its manifest fetch is the probe the watchdog admitted: answered, the run moves on.
            await engine.awaitCondition { $0.state.run?.manifestFresh == true || $0.state.run == nil }
            let made = await harness.source.manifestRequests.count
            #expect(made == requests + 1, "the run made its manifest request: \(made - requests)")
        }
        await engine.shutdown()
    }
}
