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
}
