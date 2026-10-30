import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A conditions source that holds every observation from the `holdFrom`-th call on until `release()`, all of them at
/// once: two watchers, the replaced one and its successor, wait in `conditions()` together (S1-09's watcher half).
@available(macOS 15.0, iOS 18.0, *)
actor HoldingConditionsSource: DeviceConditionsSource {
    private let base: FakeDeviceConditionsSource
    private let holdFrom: Int
    private var calls = 0
    private var released = false
    private var gates: [CheckedContinuation<Void, Never>] = []
    /// The observations waiting for `release()`.
    var waiting: Int {
        self.gates.count
    }

    init(base: FakeDeviceConditionsSource, holdFrom: Int) {
        self.base = base
        self.holdFrom = holdFrom
    }

    func conditions() async -> AsyncStream<DeviceConditions> {
        self.calls += 1
        if self.calls >= self.holdFrom, !self.released {
            // REENTRANCY: test gate — nothing: resumed once by `release()`.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.gates.append(continuation)
            }
        }
        // REENTRANCY: test gate — nothing: the base's observation is returned as is.
        return await self.base.conditions()
    }

    /// Lets every held observation (and every later one) through.
    func release() {
        self.released = true
        let gates = self.gates
        self.gates.removeAll()
        for gate in gates {
            gate.resume()
        }
    }
}

/// The sync-1 regression tests ARCHITECTURE §12.3 lists without a test of their own (Stage 3, S3-B-070): S1-09's
/// replaced-alarm and replaced-watcher halves, and an engine-side check of R-SYN-15's join-before-close order.
extension EngineRegressionTests {
    /// The heap's alarm and whether its task is registered.
    @available(macOS 15.0, iOS 18.0, *)
    static func alarm(_ engine: SyncEngine) async -> (token: UInt64, task: UInt64, deadline: MonotonicInstant, live: Bool)? {
        await engine.readForTests { engine in
            engine.state.alarm.map { ($0.token, $0.task, $0.deadline, engine.state.tasks[$0.task] != nil) }
        }
    }

    /// Moves `time` to `instant` exactly (`advance(to:)` goes through a `Double` and can stop 1 ns short, F-41).
    @available(macOS 15.0, iOS 18.0, *)
    static func land(_ time: ManualTimeSource, on instant: MonotonicInstant) {
        time.advance(to: instant)
        while time.monotonicNow() < instant {
            time.advance(by: 1e-9)
        }
    }

    /// An alarm replaced while its turn waits after its sleep (the alarm-turn hold) resumes with a stale token and ends
    /// without touching its successor: the successor stays the registered alarm, its task alive, armed at the earlier
    /// deadline, and fires every due deadline when its turn runs; the engine then owns no alarm (sync-1 S1-09: owned tasks
    /// keyed by unique spawn ids, the alarm body unregisters only itself, RE-S16). The deadlines are retries of transfers
    /// with no job: firing them re-validates and drops them.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: an alarm replaced while its turn waits never unregisters its successor, which fires every due deadline", .timeLimit(.minutes(1)))
    func replacedAlarmKeepsItsSuccessor() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(8_401)
        try await EngineSingleFlightTests.applied([EngineHarness.onDemand("alarm-idle", bytes)], harness: harness)
        let engine = harness.engine
        let start = harness.time.monotonicNow()
        let later = EngineHarness.onDemand("ghost-later", EngineFixture.bytes(8_402)).transferID
        let earlier = EngineHarness.onDemand("ghost-earlier", EngineFixture.bytes(8_403)).transferID
        await engine.readForTests { engine in
            engine.state.heap.schedule(.retry(later, epoch: 0), at: start.adding(seconds: 10))
            engine.rearm()
        }
        let first = try #require(await Self.alarm(engine), "an alarm is armed for the deadline")
        await engine.holdAlarmTurns()
        Self.land(harness.time, on: first.deadline)
        await engine.awaitCondition { $0.alarmTurnHeld }
        // An earlier deadline replaces the alarm whose turn waits: that turn resumes and finds its token stale.
        await engine.readForTests { engine in
            engine.state.heap.schedule(.retry(earlier, epoch: 0), at: start.adding(seconds: 5))
            engine.rearm()
        }
        await engine.awaitCondition { $0.state.tasks[first.task] == nil }
        let successor = try #require(await Self.alarm(engine), "the successor is still the registered alarm")
        #expect(successor.token != first.token && successor.task != first.task, "a new alarm replaced the first")
        #expect(successor.live, "the successor's task is still registered")
        #expect(successor.deadline < first.deadline, "armed at the earlier deadline")
        #expect(await engine.readForTests { $0.state.heap.count } == 2, "the replaced alarm fired nothing")
        await engine.releaseAlarmTurns()
        await engine.awaitCondition { $0.state.heap.count == 0 && $0.state.alarm == nil && $0.state.tasks.isEmpty }
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// A conditions watcher cancelled at an idle teardown while its observation still waits in `conditions()` resumes
    /// after a successor watcher started for new work, finds its token stale and ends without unregistering the
    /// successor or observing: the successor stays the registered watcher, its task alive, and is the source's only
    /// observer (sync-1 S1-09: keyed owned tasks, RE-S17). The work then ends and the successor stops observing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-14: a watcher replaced while its observation is still being set up never unregisters its successor and never observes", .timeLimit(.minutes(1)))
    func replacedWatcherKeepsItsSuccessor() async throws {
        let bytes = EngineFixture.bytes(8_501)
        let entry = EngineHarness.onDemand("watched", bytes)
        let harness = EngineHarness.make(conditionsWrapper: { HoldingConditionsSource(base: $0, holdFrom: 2) })
        let base = harness.conditions
        let holding = try #require(await harness.engine.readForTests { $0.environment.conditions as? HoldingConditionsSource })
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        await engine.awaitCondition { $0.state.jobs.isEmpty && $0.state.watcher == nil }
        // Work: the first watcher after the idle teardown waits in `conditions()`.
        let cancelled = Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.watcher != nil }
        let first = try #require(await engine.readForTests { $0.state.watcher.map { ($0.token, $0.task) } })
        while !Task.isCancelled, await holding.waiting < 1 {
            await Task.yield()
        }
        // The work ends: the watcher is cancelled and unregistered while its observation still waits.
        cancelled.cancel()
        #expect(await cancelled.value == .failure(.cancelled))
        await engine.awaitCondition { $0.state.watcher == nil && $0.state.jobs.isEmpty }
        #expect(await engine.readForTests { $0.state.tasks[first.1] != nil }, "the cancelled watcher's task still waits in conditions()")
        // New work: a successor watcher starts and waits too.
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        let waiter = Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.watcher != nil }
        let second = try #require(await engine.readForTests { $0.state.watcher.map { ($0.token, $0.task) } })
        #expect(second.0 != first.0 && second.1 != first.1, "a new watcher replaced the first")
        while !Task.isCancelled, await holding.waiting < 2 {
            await Task.yield()
        }
        await holding.release()
        // The replaced watcher ends; the successor observes.
        await engine.awaitCondition { $0.state.tasks[first.1] == nil && $0.state.conditions != nil }
        let after = await engine.readForTests { engine in
            (token: engine.state.watcher?.token, live: engine.state.watcher.map { engine.state.tasks[$0.task] != nil } ?? false)
        }
        #expect(after.token == second.0, "the successor is still the registered watcher")
        #expect(after.live, "its task is still registered")
        await base.waitForObservers(equalTo: 1)
        #expect(await base.activeObservers == 1, "only the successor observes")
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        #expect((try? await EngineHarness.value(of: waiter).get()) != nil, "the successor's work completes")
        await engine.awaitCondition { $0.state.watcher == nil && $0.state.jobs.isEmpty }
        await base.waitForObservers(equalTo: 0)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// Shutdown joins every owned task before it begins closing the store (R-SYN-15, ADR-039; sync-1 S1-04/S1-09): a
    /// condition observer, called at every notification, records whether any owned task is still registered when the
    /// engine marks the close (`closingStore`). A publication held at its first store unit while a run is in progress
    /// keeps owned tasks alive until the join; closing first (or not joining) closes the store under them. `close()`
    /// drains in-flight work, so the store's own record cannot tell the orders apart afterwards (`f.md`, the level-4
    /// verifier's mutants M5 and M6); the store is read while the shutdown joins the held task instead, and must still
    /// be open, which a close moved alone before the joins fails (the close-out cycle-2 requirements lens).
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 29.3 to 31.2 s beside a second TSan process at a
    /// load of 20 to 35 (52 % of 60 s) and 13.2 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown joins every owned task before it begins closing the store", .timeLimit(.minutes(3)))
    func shutdownJoinsBeforeClosing() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let catalog = EngineSyncTests.catalog(2)
        await harness.serve(catalog)
        try await harness.start()
        let engine = harness.engine
        _ = try #require(try await harness.syncDriven().completeReport)
        let addedBytes = EngineFixture.bytes(8_601)
        let added = EngineFixture.entry("closing", addedBytes)
        await harness.serveManifest(catalog.map(\.0) + [added], etag: "v2")
        await harness.source.script(added.transferID, [.hold, .stage(addedBytes)])
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.jobs[added.transferID]?.state == .downloading }
        await engine.waitForHandle(added.transferID)
        await bulk.holdNext()
        await harness.source.release(added.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        let seen = Mutex<(marks: Int, tasksAtMark: [Int])>((0, []))
        let (registered, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            await engine.awaitCondition { engine in
                signal.yield()
                if engine.state.closingStore {
                    seen.withLock { record in
                        record.marks += 1
                        record.tasksAtMark.append(engine.state.tasks.count)
                    }
                }
                return false
            }
        }
        var registration = registered.makeAsyncIterator()
        _ = await registration.next()
        let shutdown = Task { await engine.shutdown() }
        await engine.waitUntil { $0.lifecycle == .shuttingDown }
        // From the store's side: once the shutdown has left the engine's actor (this read runs after its first
        // suspension), it is joining the owned task whose publication the bulk unit holds, so the store is still open; a
        // close begun before the joins would already refuse this read.
        await engine.readForTests { _ in }
        let openWhileJoining = (try? await harness.store.planningView()) != nil
        await bulk.release()
        await EngineHarness.value(of: shutdown)
        await EngineHarness.value(of: observer)
        signal.finish()
        _ = await EngineHarness.value(of: run)
        let record = seen.withLock { $0 }
        #expect(record.marks >= 1, "the observer saw the close begin")
        #expect(record.tasksAtMark.allSatisfy { $0 == 0 }, "no owned task was registered when the close began: \(record.tasksAtMark)")
        #expect(openWhileJoining, "the store was still open while the shutdown joined the task its unit held")
        #expect(await engine.introspect().ownedTasks == 0)
    }
}
