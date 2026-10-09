import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTransport

/// The observation census wait of `LiveDeviceConditionsSource` ends when its caller is cancelled (L2 close,
/// `docs/adr-drafts/l2close.md` item 1).
///
/// A test past its `.timeLimit` is cancelled, and Swift Testing then waits for its body to return. A wait that only
/// the census could end (an observation started or stopped) kept a regression that never reaches the count suspended
/// for good, so the whole run hung instead of failing that one test. Each test here awaits the waiting task through
/// `outcome(of:)`, which ends when this test is cancelled, so a wait that ignores cancellation fails at the time limit
/// and the process still exits.
@Suite("Live device conditions: the observation census wait ends on cancellation")
struct ConditionsCensusWaitTests {
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

    @Test("Seams: a waitForObservations whose task is cancelled returns while no observation is active", .timeLimit(.minutes(1)))
    func observationWaitEndsOnCancellation() async {
        // No observation ever starts: `conditions()` is never called, so no path monitor is created either.
        let source = LiveDeviceConditionsSource(center: NotificationCenter())
        let ended: Void? = await Self.cancelledBeforeItStarts { await source.waitForObservations(equalTo: 1) }
        #expect(ended != nil, "the wait outlived its task's cancellation")
        #expect(await source.activeObservations == 0)
    }
}
