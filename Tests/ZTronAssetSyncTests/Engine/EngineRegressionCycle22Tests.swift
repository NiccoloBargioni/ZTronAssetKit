import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 22 of the level-4 close-out (`docs/adr-drafts/f.md`, F-42): the stale-gate family's member
/// that cycle 21's fix left open, and the rule that closes the half-open probe's contention as a class. A probe that ended
/// without a verdict owed a pump only when the breaker had parked jobs; jobs that waited in the queue for a slot were not
/// parked, so the pending run's gate read open in the probe's exit turn and the run started, and the exit's own pump then
/// gave the freed slot, and the probe, to the next queued job before the run's manifest step: one blocked run per queued
/// member while the clock never moved (PROBE-C21C-QUEUED-PROBES, PROBE-C21C-DEFAULT-TUNING). Every wait is a condition, a
/// census or a join that ends on cancellation; the clock moves only from an engine with nothing due (L4-R17).
@Suite("Engine regressions, close-out cycle 22")
struct EngineRegressionCycle22Tests {
    /// What a condition observer saw in the turn each run after `after` started: the observer is evaluated in every turn
    /// that notifies, so its first sighting of a run is that run's start turn, before any later turn could change the
    /// breaker (the same technique as the gate model's `Recorder`).
    @available(macOS 15.0, iOS 18.0, *)
    final class RunStartWatch: Sendable {
        struct Sighting: Sendable {
            let run: UInt64
            let trigger: SyncTrigger
            /// The breaker's verdict for any transfer that is not its probe (a job), read in the run's start turn.
            let admission: CircuitBreaker.Admission?
            let breaker: CircuitBreaker.State?
            /// The watched jobs still queued or parked by the breaker then.
            let waiting: Int
        }

        struct Seen: Sendable {
            var registered = false
            var after: UInt64 = .max
            var sightings: [Sighting] = []
        }

        let origin: String
        let watched: [TransferID]
        let seen = Mutex(Seen())

        init(origin: String, watched: [TransferID]) {
            self.origin = origin
            self.watched = watched
        }

        /// `true` the first time only.
        func markRegistered() -> Bool {
            self.seen.withLock { seen in
                defer { seen.registered = true }
                return !seen.registered
            }
        }

        var registered: Bool {
            self.seen.withLock { $0.registered }
        }

        /// Watches the runs whose identifier is above `id` from now on.
        func arm(after id: UInt64) {
            self.seen.withLock { $0.after = id }
        }

        var sightings: [Sighting] {
            self.seen.withLock { $0.sightings }
        }

        func observe(_ engine: isolated SyncEngine) {
            guard let run = engine.state.run else {
                return
            }
            let now = engine.environment.time.monotonicNow()
            let breaker = engine.state.breakers[self.origin]
            let waiting = self.watched.filter { transfer in
                guard let state = engine.state.jobs[transfer]?.state else {
                    return false
                }
                return state == .queued || state.isCircuitParked
            }.count
            self.seen.withLock { seen in
                guard run.id.rawValue > seen.after, !seen.sightings.contains(where: { $0.run == run.id.rawValue }) else {
                    return
                }
                seen.sightings.append(
                    Sighting(
                        run: run.id.rawValue,
                        trigger: run.trigger,
                        admission: breaker?.admission(of: nil, at: now),
                        breaker: breaker?.state,
                        waiting: waiting
                    )
                )
            }
        }

        /// Registers `watch` as a condition observer of `engine` and returns once it is registered.
        static func install(_ watch: RunStartWatch, on engine: SyncEngine) async -> Task<Void, Never> {
            let task = Task {
                await engine.awaitCondition { engine in
                    if watch.markRegistered() {
                        // Wakes the wait below in the turn that registered this observer.
                        engine.notifyObservers()
                    }
                    watch.observe(engine)
                    return false
                }
            }
            await engine.awaitCondition { _ in watch.registered }
            return task
        }
    }

    /// Whether the watched job has finished: no job any more, or a failed one.
    @available(macOS 15.0, iOS 18.0, *)
    static func done(_ engine: isolated SyncEngine, _ transfer: TransferID) -> Bool {
        guard let job = engine.state.jobs[transfer] else {
            return true
        }
        if case .failed = job.state {
            return true
        }
        return false
    }

    // MARK: Members waiting for a slot whose probes end without a verdict start no run each (R-SYN-5, R-SYN-6; L4-C21, blocking)

    /// Two slots, one of them reserved for user-initiated work (the default tuning), so the run's claims and the prefetch
    /// members share one slot. The in-flight claim's 403 opens the breaker; the freed slot's dispatch parks the ten members,
    /// and the launch run settles blocked (retiring its queued claim) with a pending run that waits for the breaker. Every member
    /// answers 400 from here on, and the clock moves once, to the cooldown's end. The cooldown's turn re-queues them and the
    /// first probes; the others wait in the queue for the slot, not parked. At `5501c8c` each probe's exit owed a pump only
    /// when the breaker had parked jobs, so the pending run's gate read open in the exit's turn and the run started; that
    /// turn's own pump then gave the freed slot to the next member, which probed before the run's manifest step, and the run
    /// settled blocked: 10 runs after the cooldown, the clock never moving. Now every exit without a verdict owes a pump, the
    /// pending run starts once no member is left to take the probe (F-41), and a run that starts holds the probe for its
    /// manifest fetch from its start turn (F-42).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: prefetch members that wait for a slot and each end without a verdict start no run per probe while the clock does not move", .timeLimit(.minutes(1)))
    func slotWaitingMembersStartNoRunEach() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 2, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<2).map { index in
            EngineFixture.entry("slot-\(index)", EngineFixture.bytes(9_701 + UInt64(index)))
        }
        let members = (0..<10).map { index in
            EngineHarness.onDemand("slot-member-\(index)", EngineFixture.bytes(9_721 + UInt64(index)))
        }
        await harness.serveManifest(catalog + members)
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        // No attempt is scripted yet: one claim waits in flight in the one slot the run may use, the other in the queue.
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 1 && engine.state.jobs.values.filter { $0.state == .queued }.count == 1
        }
        let roles = await engine.readForTests { engine in
            (engine.state.jobs.first { $0.value.active != nil }?.key, engine.state.jobs.first { $0.value.state == .queued }?.key)
        }
        let failing = try #require(roles.0, "setup: one claim is in flight")
        let queued = try #require(roles.1, "setup: one claim waits for the slot")
        // The members queue behind the run's claims (the slot is taken).
        _ = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { engine in members.allSatisfy { engine.state.jobs[$0.transferID]?.state == .queued } }
        // From here on every member answers 400 and the claims 404, as often as anything asks.
        for member in members {
            await harness.source.script(member.transferID, Array(repeating: .fail(EngineRegressionCycle20Tests.rejected), count: 3))
        }
        await harness.source.script(queued, Array(repeating: .fail(EngineRegressionCycle20Tests.missing), count: 3))
        // The 403 opens the breaker: the freed slot's dispatch parks every member behind it, and the launch run, with no
        // working claim left, settles blocked by the breaker.
        await harness.source.script(failing, [.fail(EngineRegressionCycle20Tests.forbidden)] + Array(repeating: .fail(EngineRegressionCycle20Tests.missing), count: 3))
        await engine.awaitCondition { $0.state.run == nil && $0.state.pendingRun != nil }
        let parked = await engine.readForTests { engine in
            members.filter { engine.state.jobs[$0.transferID]?.state.isCircuitParked == true }.count
        }
        #expect(parked == members.count, "setup: every member is parked by the breaker: \(parked)")
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
        let watch = RunStartWatch(origin: origin, watched: members.map(\.transferID) + [queued])
        let watcher = await RunStartWatch.install(watch, on: engine)
        watch.arm(after: before.0)
        let requests = await harness.source.manifestRequests.count
        // The clock moves once, to the cooldown's end, and never again.
        EngineRegressionCycle21Tests.advance(harness.time, to: cooldownEnd)
        await engine.awaitCondition { engine in
            members.allSatisfy { Self.done(engine, $0.transferID) } && EngineRegressionCycle15Tests.quiet(engine) && !engine.dispatchOwed
        }
        let after = await engine.readForTests { $0.state.lastRunID }
        let sightings = watch.sightings
        #expect(after - before.0 == 1, "one run follows the cooldown, not one per member's probe: \(after - before.0) runs")
        #expect(
            sightings.first?.waiting == 0,
            "the run starts once no member or claim is left to take the probe (F-41): \(String(describing: sightings.first?.waiting)) waiting"
        )
        let made = await harness.source.manifestRequests.count
        #expect(made - requests <= 1, "at most one manifest request while the clock does not move: \(made - requests)")
        let lastID = SyncRunID(rawValue: after)
        let finished = await probe.next { EngineRegressionCycle21Tests.finishes($0, lastID) }
        if case .syncFinished(_, .completeWithFailures)? = finished {} else {
            Issue.record("the run completes with the missing claim failed, not blocked: \(String(describing: finished))")
        }
        watcher.cancel()
        await watcher.value
        await probe.stop()
        await engine.shutdown()
    }

    // MARK: A run holds the half-open probe for its manifest fetch from the turn it starts (R-SYN-5, ARCHITECTURE §7.7; F-42)

    /// One slot. The launch run's claim answers 403 and opens the breaker; the run settles blocked by it, with a pending run
    /// that waits for the breaker, and retires its other claim's job, so nothing is parked. At the cooldown's end the
    /// breaker admits the next transfer as its probe and, with nothing to dispatch, the alarm's turn starts the pending run.
    /// ARCHITECTURE §7.6/§7.7: the half-open probe is that run's manifest fetch. The fetch is admitted only in a later turn
    /// (the run task's, then the fetch task's), so a job dispatched in between (a slot freed by an unrelated attempt, a
    /// pause's re-dispatch, a join's batch, a retry, a probe's exit) took the probe first and the run settled blocked by the
    /// manifest's rejection: the window behind cycles 20 to 22's runaway runs. The run now holds the probe for its manifest
    /// fetch from its start turn, so in that turn the breaker already rejects every other transfer.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a run that starts while the half-open breaker admits only a probe holds it for its manifest fetch from its start turn", .timeLimit(.minutes(1)))
    func runHoldsTheProbeFromItsStartTurn() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<2).map { index in
            EngineFixture.entry("held-\(index)", EngineFixture.bytes(9_741 + UInt64(index)))
        }
        await harness.serveManifest(catalog)
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 1 && engine.state.jobs.values.filter { $0.state == .queued }.count == 1
        }
        let roles = await engine.readForTests { engine in
            (engine.state.jobs.first { $0.value.active != nil }?.key, engine.state.jobs.first { $0.value.state == .queued }?.key)
        }
        let failing = try #require(roles.0, "setup: one claim is in flight")
        let queued = try #require(roles.1, "setup: one claim waits for the slot")
        // Every later attempt of either claim answers 404.
        await harness.source.script(queued, Array(repeating: .fail(EngineRegressionCycle20Tests.missing), count: 3))
        await harness.source.script(failing, [.fail(EngineRegressionCycle20Tests.forbidden)] + Array(repeating: .fail(EngineRegressionCycle20Tests.missing), count: 3))
        await engine.awaitCondition { $0.state.run == nil && $0.state.pendingRun != nil }
        let before = await engine.readForTests { engine in
            (engine.state.lastRunID, engine.state.breakers[origin]?.state, engine.state.pendingRun?.gate, engine.state.circuitParked.count)
        }
        guard case .open(_, let cooldownEnd, _)? = before.1 else {
            Issue.record("setup: the launch run left the breaker open: \(String(describing: before.1))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        #expect(before.2 == .breaker && before.3 == 0, "setup: a pending run waits for the breaker and nothing is parked: \(String(describing: before.2)), \(before.3)")
        let watch = RunStartWatch(origin: origin, watched: [queued])
        let watcher = await RunStartWatch.install(watch, on: engine)
        watch.arm(after: before.0)
        let requests = await harness.source.manifestRequests.count
        EngineRegressionCycle21Tests.advance(harness.time, to: cooldownEnd)
        await engine.awaitCondition { engine in
            Self.done(engine, failing) && Self.done(engine, queued) && EngineRegressionCycle15Tests.quiet(engine) && !engine.dispatchOwed
        }
        let after = await engine.readForTests { $0.state.lastRunID }
        #expect(after - before.0 == 1, "one run follows the cooldown: \(after - before.0) runs")
        let start = watch.sightings.first
        #expect(start?.trigger == .breakerClosed, "the pending run started for the breaker's gate: \(String(describing: start?.trigger))")
        guard case .reject? = start?.admission else {
            Issue.record("in the run's start turn the breaker rejects every transfer but the run's manifest fetch: \(String(describing: start?.admission)), \(String(describing: start?.breaker))")
            watcher.cancel()
            await watcher.value
            await probe.stop()
            await engine.shutdown()
            return
        }
        guard case .halfOpen(_, _, .manifest?, _?)? = start?.breaker else {
            Issue.record("the probe the run holds is its manifest fetch, with a watchdog: \(String(describing: start?.breaker))")
            watcher.cancel()
            await watcher.value
            await probe.stop()
            await engine.shutdown()
            return
        }
        let made = await harness.source.manifestRequests.count
        #expect(made - requests == 1, "the run made its one manifest request: \(made - requests)")
        let lastID = SyncRunID(rawValue: after)
        let finished = await probe.next { EngineRegressionCycle21Tests.finishes($0, lastID) }
        if case .syncFinished(_, .completeWithFailures)? = finished {} else {
            Issue.record("the run completes with the missing claims failed, not blocked: \(String(describing: finished))")
        }
        watcher.cancel()
        await watcher.value
        await probe.stop()
        await engine.shutdown()
    }
}
