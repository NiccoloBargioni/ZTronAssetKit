import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 14 of the level-4 close-out (`docs/adr-drafts/f.md`, F-34).
@Suite("Engine regressions, close-out cycle 14")
struct EngineRegressionCycle14Tests {
    // MARK: A gate the clock opened while the alarm's turn runs the store's due work (R-SYN-2; cycle-13 verifier)

    /// The alarm clears `state.alarm` before it fires what is due, and a due store deadline suspends its turn in
    /// `store.runDueWork()`. A clock move in that window opens a pending run's throttle or breaker gate; the run starts
    /// once the turn resumes (it re-arms at the gate's due deadline, and that alarm starts the run), yet the invariant
    /// check made in the window, with no alarm armed, reported "the pending run's throttle gate is open but no run
    /// started" (the cycle-13 verifier's PROBE-ALARMSTOREWORK; seeds 155605 and 155545 of the model test with a store
    /// whose due work takes 50 ms). The store's commit unit is held, so the window is entered deterministically; the
    /// check runs in the turn that opens the gate; then the store is released and the alarm starts the run.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: the invariant check accepts a pending run whose gate the clock opened while the alarm's turn runs the store's due work", .timeLimit(.minutes(1)), arguments: EngineRegressionCycle13Tests.TimedGate.allCases)
    func clockOpenedGateDuringStoreWork(gate: EngineRegressionCycle13Tests.TimedGate) async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(metadata: metadata, commitInterval: 2)
        let viewedBytes = EngineFixture.bytes(4_242)
        let viewed = EngineHarness.onDemand("viewed", viewedBytes)
        let catalog = EngineSyncTests.catalog(1) + [(viewed, viewedBytes)]
        await harness.serve(catalog)
        let manifest = FakeManifestResponse.fetched(EngineFixture.manifestData(catalog.map(\.0)), etag: EngineFixture.etag("v1"))
        let engine = harness.engine
        let time = harness.time
        try await harness.start()
        // The launch run downloads the catalog through its commit windows.
        _ = try await harness.syncDriven()
        // A publication outside any run: the store's commit window opens on the manual clock, after `now`.
        let located = await engine.awaitAsset(viewed.identifier, lane: .userInitiated)
        #expect(try located.get().id == viewed.identifier)
        let pendingGate: PendingRunGate
        let deadline: DeadlineReason
        switch gate {
        case .throttle:
            await harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(20))), manifest])
            pendingGate = .throttle
            deadline = .pendingRun
        case .breaker:
            let evidence = EngineFailurePathTests.evidence(.manifest, xml: false, bytes: 0)
            await harness.source.scriptManifest([.fail(.authentication(.forbiddenAmbiguous(evidence))), manifest])
            pendingGate = .breaker
            deadline = .breaker(harness.source.originID)
        }
        let blocked = await engine.sync(.force)
        guard case .blocked = blocked else {
            Issue.record("setup: the run was not blocked: \(blocked)")
            await engine.shutdown()
            return
        }
        // The blocked run has ended; its pending run waits for the deadline that opens its gate, and the store's
        // commit deadline comes first.
        await engine.awaitCondition { engine in
            engine.state.run == nil && engine.state.pendingRun?.gate == pendingGate && engine.state.heap.deadline(for: deadline) != nil
                && engine.state.heap.deadline(for: .store) != nil
        }
        let (storeDeadline, gateDeadline) = await engine.readForTests { engine in
            (engine.state.heap.deadline(for: .store), engine.state.heap.deadline(for: deadline))
        }
        let storeAt = try #require(storeDeadline)
        let gateAt = try #require(gateDeadline)
        try #require(storeAt < gateAt, "setup: the store's deadline \(storeAt) comes before the gate's \(gateAt)")
        // The store's commit unit is held: the alarm's turn fires the store deadline and suspends in its due work.
        await metadata.setHolding(true)
        time.advance(to: storeAt)
        try await metadata.requireHeldUnits(atLeast: 1)
        let window = await engine.readForTests { engine in
            engine.state.alarm == nil && engine.state.storeWorkRuns == 1 && engine.state.run == nil && engine.state.pendingRun?.gate == pendingGate
        }
        try #require(window, "setup: the alarm's turn waits in the store's due work, with no alarm armed and the run pending")
        let violations = await engine.readForTests { engine -> [String] in
            // The clock reaches the gate's deadline in this turn: nothing has run since the move.
            time.advance(to: gateAt)
            #expect(engine.pendingRunGate(engine.state.pendingRun ?? PendingRun(gate: pendingGate, trigger: .explicit)) == .open, "setup: the gate is open")
            return engine.invariantViolations()
        }
        #expect(violations.isEmpty, "\(gate): \(violations)")
        // The store's work ends, the turn re-arms at the gate's due deadline, and that alarm starts the pending run. The
        // wait also ends if the alarm's task ends with the alarm still armed, so a broken alarm is named below instead
        // of waiting out the time limit.
        await metadata.setHolding(false)
        await engine.awaitCondition { engine in
            engine.state.pendingRun == nil || engine.state.alarm.map { engine.state.tasks[$0.task] == nil } == true
        }
        #expect(await engine.readForTests { $0.state.pendingRun == nil }, "the alarm started the pending run")
        let after = await engine.invariantViolations()
        #expect(after.isEmpty, "\(after)")
        await engine.shutdown()
    }

    // MARK: Only an alarm that will fire the gate's deadline excuses an open gate (R-SYN-2; cycle-13 verifier)

    /// The exemption above trusted `state.alarm != nil`: an alarm whose owned task had ended without firing (or one
    /// armed later than the gate's deadline, which a `rearm` that never moves the alarm earlier leaves) excused the open
    /// gate for ever, so the model test could not name either defect. In the turn that moves the clock to the gate's
    /// deadline, the engine's alarm is replaced by each of those two, the invariants are checked, and the engine's own
    /// alarm is put back before the turn ends: behind an alarm whose task is gone and behind an alarm later than the
    /// gate's deadline, the throttle gate is reported stranded and the heap's earliest deadline unfired (an invariant of
    /// its own, checked whatever the deadline, so the model test names either defect at its next check); only the live
    /// alarm at the heap's earliest deadline excuses the gate.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: an open pending-run gate is excused only by a live alarm armed at or before its deadline", .timeLimit(.minutes(1)))
    func onlyALiveTimelyAlarmExcusesAnOpenGate() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(1)
        await harness.scriptTransfers(catalog)
        let manifest = FakeManifestResponse.fetched(EngineFixture.manifestData(catalog.map(\.0)), etag: EngineFixture.etag("v1"))
        await harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(20))), manifest])
        let engine = harness.engine
        let time = harness.time
        try await harness.start()
        await engine.awaitCondition { engine in
            engine.state.run == nil && engine.state.pendingRun?.gate == .throttle && engine.state.heap.deadline(for: .pendingRun) != nil
                && engine.state.alarm != nil
        }
        let checks = await engine.readForTests { engine -> (dead: [String], late: [String], live: [String])? in
            guard let at = engine.state.heap.deadline(for: .pendingRun), let alarm = engine.state.alarm else {
                return nil
            }
            time.advance(to: at)
            let unused = (engine.state.tasks.keys.max() ?? 0) + 1
            engine.state.alarm = Alarm(token: alarm.token, task: unused, deadline: alarm.deadline)
            let dead = engine.invariantViolations()
            engine.state.alarm = Alarm(token: alarm.token, task: alarm.task, deadline: at.adding(seconds: 1))
            let late = engine.invariantViolations()
            engine.state.alarm = alarm
            return (dead, late, engine.invariantViolations())
        }
        let found = try #require(checks, "setup: the throttle's deadline and the alarm")
        let stranded = "the pending run's throttle gate is open but no run started"
        // Each defect is named twice: the gate is stranded, and the heap's earliest deadline has no alarm to fire it.
        #expect(found.dead.count == 2 && found.dead.contains(stranded), "an alarm whose task ended: \(found.dead)")
        #expect(found.dead.contains { $0.hasPrefix("no live alarm will fire the earliest deadline") }, "an alarm whose task ended: \(found.dead)")
        #expect(found.late.count == 2 && found.late.contains(stranded), "an alarm after the gate's deadline: \(found.late)")
        #expect(found.late.contains { $0.hasPrefix("the alarm is armed after the earliest deadline") }, "an alarm after the gate's deadline: \(found.late)")
        #expect(found.live.isEmpty, "the engine's own alarm: \(found.live)")
        // The engine's alarm, put back, starts the pending run. The wait also ends if the alarm's task ends with the
        // alarm still armed, so a broken alarm is named below instead of waiting out the time limit.
        await engine.awaitCondition { engine in
            engine.state.pendingRun == nil || engine.state.alarm.map { engine.state.tasks[$0.task] == nil } == true
        }
        #expect(await engine.readForTests { $0.state.pendingRun == nil }, "the alarm started the pending run")
        let after = await engine.invariantViolations()
        #expect(after.isEmpty, "\(after)")
        await engine.shutdown()
    }

    // MARK: Owned-task priorities (R-SYN-3, sync-1 S1-17; cycle-13 verifier)

    /// sync-1 S1-17 promises that drivers are spawned at their lane's priority. Since close-out cycle 13 every harness
    /// engine raises its owned tasks to the default priority (`EngineHarness.ownedTaskPriorityFloor`), so no engine test
    /// observes the production mapping any more. This pins the table `spawn` reads and the floor's rule: with no floor
    /// (production) every kind keeps its own priority; the harnesses' floor raises a lower one to it and never lowers
    /// a higher one.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: owned tasks are spawned at their lane's task priority, and the test harnesses' floor only raises it")
    func ownedTaskPriorities() {
        // (kind, its own priority, its priority under the harnesses' floor)
        let table: [(OwnedTaskKind, TaskPriority, TaskPriority)] = [
            (.driver(.userInitiated), .userInitiated, .userInitiated),
            (.start, .userInitiated, .userInitiated),
            (.driver(.prefetch), .medium, .medium),
            (.entry, .medium, .medium),
            (.manifest, .medium, .medium),
            (.driver(.bulk), .utility, .medium),
            (.run, .utility, .medium),
            (.alarm, .utility, .medium),
            (.watcher, .utility, .medium),
            (.pressure, .utility, .medium),
        ]
        #expect(EngineHarness.ownedTaskPriorityFloor == .medium)
        for (kind, own, floored) in table {
            #expect(kind.priority == own, "\(kind)")
            #expect(kind.priority(floor: nil) == own, "\(kind) in production")
            #expect(kind.priority(floor: EngineHarness.ownedTaskPriorityFloor) == floored, "\(kind) under the harnesses' floor")
            #expect(kind.priority(floor: .background) == own, "\(kind) under a floor below every kind")
        }
    }
}
