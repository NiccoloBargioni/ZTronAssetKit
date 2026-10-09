import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetTestSupport

/// Every census wait of the test support ends when its caller is cancelled (L2 follow-up, `docs/adr-drafts/l2fu.md`
/// item 1).
///
/// A test past its `.timeLimit` is cancelled, and Swift Testing then waits for its body to return. A wait that only
/// the census can end (a unit parked, a sleeper registered, an observation started) kept a regression that never
/// reaches the census suspended for good, so the whole run hung instead of failing that test. Each test here awaits
/// the waiting task through `outcome(of:)`, which ends when this test is cancelled, so a wait that ignores
/// cancellation fails at the time limit and the process still exits.
@Suite("Test support: census waits end on cancellation")
struct TestSupportCancelledWaitTests {
    /// The value `task` returned, or `nil` once the calling test is cancelled first (its time limit). The task is
    /// awaited by a relay that is not cancelled with the test, through a stream whose iteration ends on cancellation.
    static func outcome<T: Sendable>(of task: Task<T, Never>) async -> T? {
        let (stream, continuation) = AsyncStream.makeStream(of: T.self, bufferingPolicy: .bufferingNewest(1))
        Task {
            continuation.yield(await task.value)
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    /// Runs `wait` in a task that is cancelled before the wait starts, and returns what it returned (`nil`: it was
    /// still suspended when this test was cancelled).
    static func cancelledBeforeItStarts<T: Sendable>(_ wait: @escaping @Sendable () async -> T) async -> T? {
        let gate = AsyncStream<Void>.makeStream()
        let waiter = Task { () -> T in
            for await _ in gate.stream {}
            return await wait()
        }
        waiter.cancel()
        gate.continuation.finish()
        return await Self.outcome(of: waiter)
    }

    /// Runs `wait` (a test seam that reports whether its census was met and signals its registration), cancels it once
    /// it is registered, and returns what it returned (`nil`: it never registered, or never returned, before this test
    /// was cancelled).
    static func cancelledWhileRegistered(
        _ wait: @escaping @Sendable (_ registered: @escaping @Sendable () -> Void) async -> Bool
    ) async -> Bool? {
        let (registrations, registered) = AsyncStream.makeStream(of: Void.self)
        let waiter = Task { await wait({ registered.yield() }) }
        var iterator = registrations.makeAsyncIterator()
        guard await iterator.next() != nil else {
            return nil
        }
        waiter.cancel()
        return await Self.outcome(of: waiter)
    }

    /// Whether `body` threw `CancellationError` (`true`), returned (`false`), or was still suspended when this test
    /// was cancelled (`nil`), run in a task cancelled before it starts.
    static func throwsWhenCancelledFirst(_ body: @escaping @Sendable () async throws -> Void) async -> Bool? {
        await Self.cancelledBeforeItStarts { () -> Bool in
            do {
                try await body()
                return false
            } catch {
                return error is CancellationError
            }
        }
    }

    /// Whether `body` returned without throwing, awaited from this (uncancelled) test.
    static func returns(_ body: @escaping @Sendable () async throws -> Void) async -> Bool? {
        await Self.outcome(of: Task { () -> Bool in
            do {
                try await body()
                return true
            } catch {
                return false
            }
        })
    }

    @Test("Test support: a waitForHeldUnits whose task is cancelled returns while no unit is held", .timeLimit(.minutes(1)))
    func heldUnitsWaitEndsOnCancellation() async {
        let executor = SteppedBlockingExecutor()
        let ended: Void? = await Self.cancelledBeforeItStarts { await executor.waitForHeldUnits(atLeast: 1) }
        #expect(ended != nil, "the wait outlived its task's cancellation")
        #expect(await executor.heldUnits.isEmpty)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a waitForSleepers whose task is cancelled returns while no sleeper is registered", .timeLimit(.minutes(1)))
    func sleepersWaitEndsOnCancellation() async {
        let time = ManualTimeSource()
        let ended: Void? = await Self.cancelledBeforeItStarts { await time.waitForSleepers(atLeast: 1) }
        #expect(ended != nil, "the wait outlived its task's cancellation")
        #expect(time.pendingSleepers == 0)
    }

    @Test("Test support: a FakeDeviceConditionsSource.waitForObservers whose task is cancelled returns with no observation", .timeLimit(.minutes(1)))
    func conditionsObserverWaitEndsOnCancellation() async {
        let source = FakeDeviceConditionsSource()
        let ended: Void? = await Self.cancelledBeforeItStarts { await source.waitForObservers(equalTo: 1) }
        #expect(ended != nil, "the wait outlived its task's cancellation")
        #expect(await source.activeObservers == 0)
    }

    @Test("Test support: a FakeMemoryPressureSource.waitForObservers whose task is cancelled returns with no observation", .timeLimit(.minutes(1)))
    func pressureObserverWaitEndsOnCancellation() async {
        let source = FakeMemoryPressureSource()
        let ended: Void? = await Self.cancelledBeforeItStarts { await source.waitForObservers(equalTo: 1) }
        #expect(ended != nil, "the wait outlived its task's cancellation")
        #expect(await source.activeObservers == 0)
    }

    @Test("Test support: a ScriptedSnapshotSink.waitForInstalls whose task is cancelled returns with nothing offered", .timeLimit(.minutes(1)))
    func installsWaitEndsOnCancellation() async {
        let sink = ScriptedSnapshotSink()
        let ended: Void? = await Self.cancelledBeforeItStarts { await sink.waitForInstalls(atLeast: 1) }
        #expect(ended != nil, "the wait outlived its task's cancellation")
        #expect(await sink.offeredKeys.isEmpty)
    }

    @Test("Test support: an EventProbe.waitForWaiters whose task is cancelled returns false", .timeLimit(.minutes(1)))
    func probeWaiterCensusEndsOnCancellation() async {
        let (stream, events) = AsyncStream.makeStream(of: AssetEvent.self)
        let probe = EventProbe(stream: stream)
        let ended = await Self.cancelledBeforeItStarts { await probe.waitForWaiters(atLeast: 1) }
        #expect(ended == false, "nil: the wait outlived its task's cancellation; true: it reported a waiter")
        await probe.stop()
        events.finish()
    }

    // MARK: Cancelled after the wait registered: reported unmet, removed, never resumed twice

    @Test("Test support: a waitForHeldUnits cancelled while registered reports no units, and a later unit resumes only a new wait", .timeLimit(.minutes(1)))
    func heldUnitsWaitCancelledWhileRegistered() async {
        let executor = SteppedBlockingExecutor()
        let met = await Self.cancelledWhileRegistered { registered in
            await executor.waitForHeldUnits(atLeast: 1, registered: registered)
        }
        #expect(met == false)
        #expect(await executor.heldUnits.isEmpty)
        // A cancelled wait left registered would be resumed a second time here (a continuation-misuse trap).
        let unit = Task { await executor.run { 7 } }
        #expect(await Self.outcome(of: Task { await executor.waitForHeldUnits(atLeast: 1, registered: {}) }) == true)
        #expect(await executor.heldUnits == [1])
        await executor.releaseAll()
        #expect(await Self.outcome(of: unit) == 7)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a waitForSleepers cancelled while registered reports no sleepers, and a later sleeper resumes only a new wait", .timeLimit(.minutes(1)))
    func sleepersWaitCancelledWhileRegistered() async {
        let time = ManualTimeSource()
        let met = await Self.cancelledWhileRegistered { registered in
            await time.waitForSleepers(atLeast: 1, registered: registered)
        }
        #expect(met == false)
        #expect(time.pendingSleepers == 0)
        let deadline = time.monotonicNow().adding(seconds: 1)
        let sleeper = Task { () -> Bool in
            do {
                try await time.sleep(until: deadline)
                return true
            } catch {
                return false
            }
        }
        #expect(await Self.outcome(of: Task { await time.waitForSleepers(atLeast: 1, registered: {}) }) == true)
        #expect(time.pendingSleepers == 1)
        time.advance(by: 1)
        #expect(await Self.outcome(of: sleeper) == true)
    }

    @Test("Test support: a FakeDeviceConditionsSource.waitForObservers cancelled while registered reports no match, and a later observation resumes only a new wait", .timeLimit(.minutes(1)))
    func conditionsObserverWaitCancelledWhileRegistered() async {
        let source = FakeDeviceConditionsSource()
        let met = await Self.cancelledWhileRegistered { registered in
            await source.waitForObservers(equalTo: 1, registered: registered)
        }
        #expect(met == false)
        #expect(await source.activeObservers == 0)
        let observation = await source.conditions()
        #expect(await Self.outcome(of: Task { await source.waitForObservers(equalTo: 1, registered: {}) }) == true)
        #expect(await source.activeObservers == 1)
        withExtendedLifetime(observation) {}
    }

    @Test("Test support: a FakeMemoryPressureSource.waitForObservers cancelled while registered reports no match, and a later observation resumes only a new wait", .timeLimit(.minutes(1)))
    func pressureObserverWaitCancelledWhileRegistered() async {
        let source = FakeMemoryPressureSource()
        let met = await Self.cancelledWhileRegistered { registered in
            await source.waitForObservers(equalTo: 1, registered: registered)
        }
        #expect(met == false)
        #expect(await source.activeObservers == 0)
        let observation = await source.pressureEvents()
        #expect(await Self.outcome(of: Task { await source.waitForObservers(equalTo: 1, registered: {}) }) == true)
        #expect(await source.activeObservers == 1)
        withExtendedLifetime(observation) {}
    }

    @Test("Test support: a ScriptedSnapshotSink.waitForInstalls cancelled while registered reports no install, and a later install resumes only a new wait", .timeLimit(.minutes(1)))
    func installsWaitCancelledWhileRegistered() async {
        let sink = ScriptedSnapshotSink()
        let met = await Self.cancelledWhileRegistered { registered in
            await sink.waitForInstalls(atLeast: 1, registered: registered)
        }
        #expect(met == false)
        #expect(await sink.offeredKeys.isEmpty)
        let snapshot = AssetSnapshot(key: SnapshotKey(epoch: 1, version: 1), indexGeneration: 1, entries: [:])
        _ = await sink.install(snapshot)
        #expect(await Self.outcome(of: Task { await sink.waitForInstalls(atLeast: 1, registered: {}) }) == true)
        #expect(await sink.offeredKeys == [snapshot.key])
    }

    @Test("Test support: an EventProbe.waitForWaiters cancelled while registered returns false, and a later next(where:) resumes only a new wait", .timeLimit(.minutes(1)))
    func probeWaiterCensusCancelledWhileRegistered() async {
        let (stream, events) = AsyncStream.makeStream(of: AssetEvent.self)
        let probe = EventProbe(stream: stream)
        let met = await Self.cancelledWhileRegistered { registered in
            await probe.waitForWaiters(atLeast: 1, registered: registered)
        }
        #expect(met == false)
        let next = Task { await probe.next { _ in true } }
        #expect(await Self.outcome(of: Task { await probe.waitForWaiters(atLeast: 1, registered: {}) }) == true)
        await probe.stop()
        #expect(await Self.outcome(of: next) == .some(nil), "stop() ends the pending next(where:) without an event")
        events.finish()
    }

    // MARK: The throwing forms: CancellationError when cancelled first, a normal return once the census is met

    @Test("Test support: requireHeldUnits throws CancellationError when cancelled first and returns once the units are held", .timeLimit(.minutes(1)))
    func requireHeldUnits() async {
        let executor = SteppedBlockingExecutor()
        #expect(await Self.throwsWhenCancelledFirst { try await executor.requireHeldUnits(atLeast: 1) } == true)
        let unit = Task { await executor.run { 7 } }
        #expect(await Self.returns { try await executor.requireHeldUnits(atLeast: 1) } == true)
        #expect(await Self.throwsWhenCancelledFirst { try await executor.requireHeldUnits(atLeast: 1) } == false, "a met census is met, cancelled or not")
        await executor.releaseAll()
        #expect(await Self.outcome(of: unit) == 7)
    }

    @available(macOS 15.0, *)
    @Test("Test support: requireSleepers throws CancellationError when cancelled first and returns once the sleepers are registered", .timeLimit(.minutes(1)))
    func requireSleepers() async {
        let time = ManualTimeSource()
        #expect(await Self.throwsWhenCancelledFirst { try await time.requireSleepers(atLeast: 1) } == true)
        let deadline = time.monotonicNow().adding(seconds: 1)
        let sleeper = Task { () -> Bool in
            do {
                try await time.sleep(until: deadline)
                return true
            } catch {
                return false
            }
        }
        #expect(await Self.returns { try await time.requireSleepers(atLeast: 1) } == true)
        #expect(time.pendingSleepers == 1)
        time.advance(by: 1)
        #expect(await Self.outcome(of: sleeper) == true)
    }

    @Test("Test support: requireObservers throws CancellationError when cancelled first and returns once the census matches", .timeLimit(.minutes(1)))
    func requireObservers() async {
        let conditions = FakeDeviceConditionsSource()
        let pressure = FakeMemoryPressureSource()
        #expect(await Self.throwsWhenCancelledFirst { try await conditions.requireObservers(equalTo: 1) } == true)
        #expect(await Self.throwsWhenCancelledFirst { try await pressure.requireObservers(equalTo: 1) } == true)
        let observations = (await conditions.conditions(), await pressure.pressureEvents())
        #expect(await Self.returns { try await conditions.requireObservers(equalTo: 1) } == true)
        #expect(await Self.returns { try await pressure.requireObservers(equalTo: 1) } == true)
        withExtendedLifetime(observations) {}
    }

    @Test("Test support: requireInstalls throws CancellationError when cancelled first and returns once enough installs were offered", .timeLimit(.minutes(1)))
    func requireInstalls() async {
        let sink = ScriptedSnapshotSink()
        #expect(await Self.throwsWhenCancelledFirst { try await sink.requireInstalls(atLeast: 1) } == true)
        let snapshot = AssetSnapshot(key: SnapshotKey(epoch: 1, version: 1), indexGeneration: 1, entries: [:])
        _ = await sink.install(snapshot)
        #expect(await Self.returns { try await sink.requireInstalls(atLeast: 1) } == true)
        #expect(await sink.offeredKeys == [snapshot.key])
    }
}
