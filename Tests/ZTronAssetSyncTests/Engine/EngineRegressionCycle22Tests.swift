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
            /// The engine invariants that failed at any observation once a watched run's identifier was taken, its
            /// start turn included (L4-R24(1); Stage 3, S3-B-064).
            var violations: [String] = []
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

        /// What `Seen.violations` collected.
        var violations: [String] {
            self.seen.withLock { $0.violations }
        }

        func observe(_ engine: isolated SyncEngine) {
            let started = engine.state.lastRunID
            if started > self.seen.withLock({ $0.after }) {
                // An observer can run inside the start turn (any notification there); it must never see a half-started
                // run (L4-R24(1)): `invariantViolations()`'s rule that a probe held for a manifest fetch belongs to a
                // fetch in flight or to a run in place. The other rules describe turn boundaries, and an observer inside
                // a turn sees their transients (an alarm about to be re-armed, a job about to be queued), so only the
                // start turn's rule is asserted here.
                let halfStarted = engine.invariantViolations().filter { $0.hasPrefix("the breaker's probe is held for a manifest fetch") }
                if !halfStarted.isEmpty {
                    self.seen.withLock { $0.violations.append(contentsOf: halfStarted.map { "run \(started): \($0)" }) }
                }
            }
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
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 44.6 to 45.4 s beside a second TSan process at a
    /// load of 20 to 35 (76 % of 60 s) and 18.7 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 33.6 to 33.8 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: prefetch members that wait for a slot and each end without a verdict start no run per probe while the clock does not move", .timeLimit(.minutes(3)))
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
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 29.2 to 30.2 s beside a second TSan process at a
    /// load of 20 to 35 (50 % of 60 s) and 13.2 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a run that starts while the half-open breaker admits only a probe holds it for its manifest fetch from its start turn", .timeLimit(.minutes(3)))
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
        #expect(watch.violations.isEmpty, "no observer saw a half-started run (L4-R24(1)): \(watch.violations)")
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

    // MARK: A throttle that begins before the held probe's fetch is admitted lets the probe go (R-SYN-5, R-SYN-6; F-42)

    /// Two slots. The launch run's 403 opens the breaker; a prefetch member parks behind it and the run settles blocked with
    /// a pending run that waits for the breaker, while another member, started before the trip, stays in flight. The
    /// alarm's turns are held and the clock moves to the cooldown's end. The member in flight answers 429: its outcome's
    /// turn reads the pending run's gate open (the breaker admits only a probe, no pump is owed) and starts the run, which
    /// holds the probe for its manifest fetch; the 429 then throttles the origin in the same turn. The fetch finds the
    /// origin throttled and asks for nothing, so it lets the probe go: the parked member waits for the throttle, the gate
    /// that holds every transfer now, and no watchdog alarm stays armed for a fetch that never asked (mutant NORELEASE:
    /// the member stays parked behind a probe nobody holds and the breaker keeps a watchdog for it).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run's held manifest probe is let go when its fetch finds the origin throttled, so the jobs parked behind it wait for the throttle", .timeLimit(.minutes(1)))
    func heldProbeIsLetGoWhenTheFetchIsThrottled() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<3).map { index in
            EngineFixture.entry("let-go-\(index)", EngineFixture.bytes(9_761 + UInt64(index)))
        }
        let members = (0..<2).map { index in
            EngineHarness.onDemand("let-go-member-\(index)", EngineFixture.bytes(9_771 + UInt64(index)))
        }
        await harness.serveManifest(catalog + members)
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 2 && engine.state.jobs.values.filter { $0.state == .queued }.count == 1
        }
        let claims = await engine.readForTests { engine in engine.state.jobs.filter { $0.value.active != nil }.keys.sorted() }
        try #require(claims.count == 2, "setup: two claims are in flight")
        _ = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { engine in members.allSatisfy { engine.state.jobs[$0.transferID]?.state == .queued } }
        // The first claim's 404 frees a slot: a member (prefetch ranks ahead of the run's claims) starts before the trip.
        await harness.source.script(claims[0], [.fail(EngineRegressionCycle20Tests.missing)])
        await engine.awaitCondition { engine in members.contains { engine.state.jobs[$0.transferID]?.active != nil } }
        let roles = await engine.readForTests { engine in
            (members.first { engine.state.jobs[$0.transferID]?.active != nil }?.transferID, members.first { engine.state.jobs[$0.transferID]?.active == nil }?.transferID)
        }
        let flying = try #require(roles.0, "setup: one member is in flight")
        let parked = try #require(roles.1, "setup: the other member waits")
        // The second claim's 403 opens the breaker: the other member and the queued claim park, and the run settles blocked.
        await harness.source.script(claims[1], [.fail(EngineRegressionCycle20Tests.forbidden)])
        await engine.awaitCondition { $0.state.run == nil && $0.state.pendingRun != nil && $0.state.jobs[parked]?.state.isCircuitParked == true }
        let before = await engine.readForTests { engine in
            (engine.state.lastRunID, engine.state.breakers[origin]?.state, engine.state.pendingRun?.gate)
        }
        guard case .open(_, let cooldownEnd, _)? = before.1 else {
            Issue.record("setup: the 403 opened the breaker: \(String(describing: before.1))")
            await engine.shutdown()
            return
        }
        try #require(before.2 == .breaker, "setup: the pending run waits for the breaker: \(String(describing: before.2))")
        await engine.holdAlarmTurns()
        EngineRegressionCycle21Tests.advance(harness.time, to: cooldownEnd)
        // The member in flight, started before the trip, answers 429.
        await harness.source.script(flying, [.fail(.transient(.throttled, retryAfter: .seconds(30)))])
        await engine.awaitCondition { engine in
            engine.state.lastRunID > before.0 && engine.state.run == nil && engine.state.pendingRun?.gate == .throttle && !engine.dispatchOwed
                && engine.state.storeWorkRuns == 0 && engine.state.manifestFetch == nil
        }
        let after = await engine.readForTests { engine in
            (
                engine.state.lastRunID,
                engine.state.jobs[parked]?.state,
                engine.state.breakers[origin]?.state,
                engine.state.heap.deadline(for: .breaker(origin)),
                engine.state.throttles[origin]
            )
        }
        try #require(after.4 != nil, "setup: the 429 throttled the origin")
        #expect(after.0 == before.0 + 1, "one run started, for the breaker's gate, and settled blocked by the throttle: \(after.0 - before.0) runs")
        #expect(after.1?.isThrottleParked == true, "the parked member waits for the throttle, not for a probe nobody holds: \(String(describing: after.1))")
        if case .halfOpen(_, _, let probe, _)? = after.2 {
            #expect(probe == nil, "no transfer holds the probe: \(String(describing: probe))")
        } else {
            Issue.record("the breaker is half-open without a probe: \(String(describing: after.2))")
        }
        #expect(after.3 == nil, "no watchdog alarm is armed for a fetch that asked for nothing: \(String(describing: after.3))")
        await engine.releaseAlarmTurns()
        await engine.shutdown()
    }

    // MARK: A retry that falls due with the cooldown's end probes before the pending run starts (R-SYN-5; F-41, F-42)

    /// One slot. A prefetch member's attempt times out (a retry with backoff); the launch run's 403 then opens the breaker,
    /// its queued claim parks and the run settles blocked, retiring that claim, so the breaker has parked nothing. The clock
    /// moves once, past the member's retry and to the cooldown's end, so one alarm turn re-queues the member and handles the
    /// breaker's deadline. That turn owes a pump although nothing was parked: the pending run waits for it, the member
    /// probes (and answers 404), and the run starts after it, as F-41 orders (mutant NOBREAKERPUMP: the alarm's turn started
    /// the run with the member still queued).
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 40.1 to 41.2 s beside a second TSan process at a
    /// load of 20 to 35 (69 % of 60 s) and 16.9 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 30.7 to 30.8 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a retry that falls due in the alarm turn of the cooldown's end probes before the pending run starts", .timeLimit(.minutes(3)))
    func retryDueWithTheCooldownProbesFirst() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<3).map { index in
            EngineFixture.entry("retry-\(index)", EngineFixture.bytes(9_781 + UInt64(index)))
        }
        let member = EngineHarness.onDemand("retry-member", EngineFixture.bytes(9_791))
        await harness.serveManifest(catalog + [member])
        let engine = harness.engine
        let origin = harness.source.originID
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        await engine.awaitCondition { engine in
            engine.state.jobs.values.filter { $0.active != nil }.count == 1 && engine.state.jobs.values.filter { $0.state == .queued }.count == 2
        }
        let first = try #require(await engine.readForTests { engine in engine.state.jobs.first { $0.value.active != nil }?.key }, "setup: one claim is in flight")
        _ = try await engine.registerGroup([member.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[member.transferID]?.state == .queued }
        // The first claim's 404 frees the slot for the member (prefetch ranks ahead of the run's claims), which times out.
        await harness.source.script(member.transferID, [.fail(.transient(.timedOut, retryAfter: nil))] + Array(repeating: .fail(EngineRegressionCycle20Tests.missing), count: 2))
        await harness.source.script(first, [.fail(EngineRegressionCycle20Tests.missing)])
        await engine.awaitCondition { engine in
            if case .failed(.at)? = engine.state.jobs[member.transferID]?.state {
                return engine.state.jobs.values.contains { $0.active != nil }
            }
            return false
        }
        let second = try #require(await engine.readForTests { engine in engine.state.jobs.first { $0.value.active != nil }?.key }, "setup: the next claim is in flight")
        let third = try #require(
            await engine.readForTests { engine in engine.state.jobs.first { $0.value.state == .queued }?.key },
            "setup: the last claim waits for the slot"
        )
        for claim in [second, third] {
            await harness.source.script(claim, [.fail(EngineRegressionCycle20Tests.forbidden)] + Array(repeating: .fail(EngineRegressionCycle20Tests.missing), count: 2))
        }
        // The second claim's 403 opens the breaker; the last claim parks, and the run settles blocked and retires it.
        await engine.awaitCondition { $0.state.run == nil && $0.state.pendingRun != nil }
        let before = await engine.readForTests { engine in
            (engine.state.lastRunID, engine.state.breakers[origin]?.state, engine.state.jobs[member.transferID]?.state, engine.state.circuitParked.count)
        }
        guard case .open(_, let cooldownEnd, _)? = before.1, case .failed(.at(let retryAt))? = before.2 else {
            Issue.record("setup: the breaker is open and the member waits for its retry: \(String(describing: before.1)), \(String(describing: before.2))")
            await probe.stop()
            await engine.shutdown()
            return
        }
        try #require(retryAt < cooldownEnd && before.3 == 0, "setup: the retry falls due first and nothing is parked: \(retryAt), \(cooldownEnd), \(before.3)")
        let watch = RunStartWatch(origin: origin, watched: [member.transferID])
        let watcher = await RunStartWatch.install(watch, on: engine)
        watch.arm(after: before.0)
        // One move past the retry, to the cooldown's end: one alarm turn handles both deadlines.
        EngineRegressionCycle21Tests.advance(harness.time, to: cooldownEnd)
        await engine.awaitCondition { engine in
            Self.done(engine, member.transferID) && engine.state.lastRunID > before.0 && EngineRegressionCycle15Tests.quiet(engine) && !engine.dispatchOwed
        }
        let after = await engine.readForTests { $0.state.lastRunID }
        let start = watch.sightings.first
        #expect(after - before.0 == 1, "one run follows the cooldown: \(after - before.0) runs")
        #expect(start?.waiting == 0, "the member probed before the pending run started (F-41): \(String(describing: start?.waiting)) waiting")
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

    // MARK: A run that joins a manifest fetch admitted under a closed breaker holds no probe (R-SYN-5, ARCHITECTURE §7.7; F-42)

    /// The breaker is closed when a forced run's manifest fetch passes the gates; the fetch is then held at the source. A
    /// prefetch transfer's 403 opens the breaker, and the clock moves once, to the cooldown's end, where the held run's
    /// manifest deadline has also passed, so that run ends without its manifest. A second forced run starts while the
    /// breaker admits only a probe and joins the fetch still in flight. That fetch was admitted before the trip, so it is
    /// not the probe: the run holds none for it, and the fetch's answer, a 200, leaves the breaker as it was instead of
    /// closing it (a half-open breaker counts only its probe's outcome; ARCHITECTURE §7.7). Mutant NOADMITTED (the run holds
    /// the probe for any fetch in flight) let that pre-trip answer close the breaker.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a run that joins a manifest fetch admitted while the breaker was closed holds no probe for it, so that fetch's answer does not close the breaker", .timeLimit(.minutes(1)))
    func runJoiningAnAdmittedFetchHoldsNoProbe() async throws {
        let fake = FakeRemoteSource()
        let held = HeldManifestSource(base: fake)
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(source: fake, tuning: tuning, remote: held)
        let bytes = EngineFixture.bytes(9_801)
        let asset = EngineHarness.onDemand("joined", bytes)
        await harness.serveManifest([asset])
        let engine = harness.engine
        let origin = fake.originID
        try await harness.start()
        // The launch run applies the on-demand entry and downloads nothing.
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await fake.scriptManifest([.fetched(EngineFixture.manifestData([asset]), etag: EngineFixture.etag("v2"))])
        await held.holdNext()
        let firstRun = Task { await engine.sync(.force) }
        await held.waitForHeldFetch()
        let admitted = await engine.readForTests {
            ($0.state.manifestFetch?.admitted, $0.state.breakers[origin]?.state ?? .closed, $0.state.lastRunID, $0.state.manifestFetch?.sequence)
        }
        try #require(admitted.0 == true && admitted.1 == .closed, "setup: the fetch passed a closed breaker: \(String(describing: admitted.0)), \(admitted.1)")
        let sequence = try #require(admitted.3, "setup: the fetch is in flight")
        // A prefetch transfer's 403 opens the breaker while the fetch is held.
        await fake.script(asset.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        let caller = Task { await engine.awaitAsset(asset.identifier, lane: .prefetch) }
        _ = await joinCancelling(caller)
        guard case .open(_, let cooldownEnd, _)? = await EngineRegressionCycle20Tests.breaker(engine, origin) else {
            Issue.record("setup: the 403 opened the breaker")
            await held.release()
            await engine.shutdown()
            return
        }
        // At the cooldown's end the first run's manifest deadline (30 s) has passed too: it ends without its manifest.
        EngineRegressionCycle21Tests.advance(harness.time, to: cooldownEnd)
        _ = await joinCancelling(firstRun)
        // The second run's task joins the fetch in its first turn: it schedules the run's manifest deadline for the fetch and
        // registers as the fetch's waiter in that same turn. Nothing earlier is due, so that deadline becomes the alarm's
        // next target, and re-arming the alarm notifies the condition below.
        let earliest = await engine.readForTests { engine in (engine.state.heap.first?.at, engine.environment.time.monotonicNow()) }
        let joinDeadline = earliest.1.adding(seconds: tuning.manifestFetchDeadline)
        try #require(earliest.0.map { $0 > joinDeadline } ?? true, "setup: nothing is due before the joining run's manifest deadline: \(String(describing: earliest.0))")
        let secondRun = Task { await engine.sync(.force) }
        await engine.awaitCondition { engine in
            (engine.state.run.map { $0.id.rawValue > admitted.2 } ?? false) && engine.state.heap.deadline(for: .manifest(sequence)) != nil
        }
        let joined = await engine.readForTests {
            ($0.state.breakers[origin]?.state, $0.state.manifestFetch?.sequence, $0.state.manifestFetch?.waiters.isEmpty)
        }
        try #require(joined.1 == sequence && joined.2 == false, "setup: the second run waits for the held fetch: \(String(describing: joined.1)), \(String(describing: joined.2))")
        guard case .open? = joined.0 else {
            Issue.record("the run joining the pre-trip fetch holds no probe for it: \(String(describing: joined.0))")
            await held.release()
            _ = await joinCancelling(secondRun)
            await engine.shutdown()
            return
        }
        await held.release()
        let outcome = await joinCancelling(secondRun)
        if case .complete = outcome {} else {
            Issue.record("the joining run completes with the fetch's manifest: \(outcome)")
        }
        let final = await EngineRegressionCycle20Tests.breaker(engine, origin)
        if case .open? = final {} else {
            Issue.record("the pre-trip fetch's 200 does not close the breaker: \(String(describing: final))")
        }
        await engine.shutdown()
    }
}
