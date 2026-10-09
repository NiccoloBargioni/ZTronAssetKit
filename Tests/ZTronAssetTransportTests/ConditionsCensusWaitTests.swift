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

    /// Runs `wait` (the seam that reports whether the count matched and signals its registration), cancels it once it
    /// is registered, and returns what it returned (`nil`: it never registered, or never returned, before this test
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

    @Test("Seams: a waitForObservations whose task is cancelled returns while no observation is active", .timeLimit(.minutes(1)))
    func observationWaitEndsOnCancellation() async {
        // No observation ever starts: `conditions()` is never called, so no path monitor is created either.
        let source = LiveDeviceConditionsSource(center: NotificationCenter())
        let ended: Void? = await Self.cancelledBeforeItStarts { await source.waitForObservations(equalTo: 1) }
        #expect(ended != nil, "the wait outlived its task's cancellation")
        #expect(await source.activeObservations == 0)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Seams: a waitForObservations cancelled while registered reports no match, and a later observation resumes only a new wait", .timeLimit(.minutes(1)))
    func observationWaitCancelledWhileRegistered() async {
        let path = ConditionsTests.ScriptedPath(NetworkConditions(satisfied: true, expensive: false, constrained: false))
        let source = LiveDeviceConditionsSource(center: NotificationCenter(), makePathObserver: { path })
        let met = await Self.cancelledWhileRegistered { registered in
            await source.waitForObservations(equalTo: 1, registered: registered)
        }
        #expect(met == false, "nil: the wait outlived its task's cancellation; true: it reported a count never reached")
        #expect(await source.activeObservations == 0)
        // A cancelled wait left registered would be resumed a second time by this observation's count (a
        // continuation-misuse trap).
        let stream = await source.conditions()
        #expect(await Self.outcome(of: Task { await source.waitForObservations(equalTo: 1, registered: {}) }) == true)
        #expect(await source.activeObservations == 1)
        withExtendedLifetime(stream) {}
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Seams: a waitForObservations for fewer observations, cancelled while registered, reports no match and leaves the observation running", .timeLimit(.minutes(1)))
    func shrinkingWaitCancelledWhileRegistered() async {
        let path = ConditionsTests.ScriptedPath(NetworkConditions(satisfied: true, expensive: false, constrained: false))
        let source = LiveDeviceConditionsSource(center: NotificationCenter(), makePathObserver: { path })
        let stream = await source.conditions()
        let met = await Self.cancelledWhileRegistered { registered in
            await source.waitForObservations(equalTo: 0, registered: registered)
        }
        #expect(met == false, "nil: the wait outlived its task's cancellation; true: it reported a count never reached")
        #expect(await source.activeObservations == 1)
        #expect(!path.isCancelled)
        withExtendedLifetime(stream) {}
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Seams: requireObservations throws CancellationError when cancelled first and returns once the count matches, cancelled or not", .timeLimit(.minutes(1)))
    func requireObservations() async {
        let path = ConditionsTests.ScriptedPath(NetworkConditions(satisfied: true, expensive: false, constrained: false))
        let source = LiveDeviceConditionsSource(center: NotificationCenter(), makePathObserver: { path })
        #expect(await Self.throwsWhenCancelledFirst { try await source.requireObservations(equalTo: 1) } == true)
        let stream = await source.conditions()
        #expect(await Self.returns { try await source.requireObservations(equalTo: 1) } == true)
        #expect(await Self.throwsWhenCancelledFirst { try await source.requireObservations(equalTo: 1) } == false, "a met count is met, cancelled or not")
        #expect(await source.activeObservations == 1)
        withExtendedLifetime(stream) {}
    }
}
