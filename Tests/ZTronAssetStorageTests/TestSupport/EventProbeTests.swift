import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetTestSupport

/// Waiting for engine events without sleeping (sync.md §16): `EventProbe` consumes a stream in one owned task.
@Suite("Test support: EventProbe")
struct EventProbeTests {
    static func isStarted(_ event: AssetEvent) -> Bool {
        if case .clientStarted = event {
            return true
        }
        return false
    }

    static func isShutDown(_ event: AssetEvent) -> Bool {
        event == .clientShutDown
    }

    @Test("Test support: next returns events already received, each at most once and earliest first", .timeLimit(.minutes(1)))
    func nextReturnsReceivedEvents() async {
        let (stream, continuation) = AsyncStream.makeStream(of: AssetEvent.self)
        let probe = EventProbe(stream: stream)
        continuation.yield(.clientStarted(generation: 1))
        continuation.yield(.snapshotChanged(generation: 2))
        continuation.yield(.clientStarted(generation: 3))
        continuation.finish()
        #expect(await probe.next(where: { $0 == .snapshotChanged(generation: 2) }) == .snapshotChanged(generation: 2))
        #expect(await probe.next(where: Self.isStarted) == .clientStarted(generation: 1))
        #expect(await probe.next(where: Self.isStarted) == .clientStarted(generation: 3))
        #expect(await probe.next(where: Self.isStarted) == nil)
        #expect(await probe.received == [.clientStarted(generation: 1), .snapshotChanged(generation: 2), .clientStarted(generation: 3)])
    }

    @Test("Test support: a waiting next is resumed by the first matching event that arrives", .timeLimit(.minutes(1)))
    func waitingNextIsResumed() async {
        let (stream, continuation) = AsyncStream.makeStream(of: AssetEvent.self)
        let probe = EventProbe(stream: stream)
        let waiting = Task { await probe.next(where: Self.isShutDown) }
        await probe.waitForWaiters(atLeast: 1)
        continuation.yield(.snapshotChanged(generation: 1))
        continuation.yield(.clientShutDown)
        #expect(await waiting.value == .clientShutDown)
        #expect(await probe.next(where: { _ in true }) == .snapshotChanged(generation: 1))
    }

    @Test("Test support: a waiting next returns nil when the stream finishes without a match", .timeLimit(.minutes(1)))
    func finishedStreamAnswersNil() async {
        let (stream, continuation) = AsyncStream.makeStream(of: AssetEvent.self)
        let probe = EventProbe(stream: stream)
        let waiting = Task { await probe.next(where: Self.isShutDown) }
        await probe.waitForWaiters(atLeast: 1)
        continuation.finish()
        #expect(await waiting.value == nil)
    }

    @Test("Test support: stop ends consumption, terminates the stream and answers waiting calls with nil", .timeLimit(.minutes(1)))
    func stopTerminatesTheStream() async {
        let (stream, continuation) = AsyncStream.makeStream(of: AssetEvent.self)
        let (terminated, terminations) = AsyncStream.makeStream(of: Void.self)
        continuation.onTermination = { _ in
            terminations.yield()
            terminations.finish()
        }
        let probe = EventProbe(stream: stream)
        let waiting = Task { await probe.next(where: Self.isShutDown) }
        await probe.waitForWaiters(atLeast: 1)
        await probe.stop()
        #expect(await waiting.value == nil)
        var sawTermination = false
        for await _ in terminated {
            sawTermination = true
        }
        #expect(sawTermination)
        #expect(await probe.next(where: Self.isShutDown) == nil)
    }

    @Test("Test support: a cancelled next returns nil and leaves later events to the next caller", .timeLimit(.minutes(1)))
    func cancelledNextReturnsNil() async {
        let (stream, continuation) = AsyncStream.makeStream(of: AssetEvent.self)
        let probe = EventProbe(stream: stream)
        let waiting = Task { await probe.next(where: Self.isShutDown) }
        await probe.waitForWaiters(atLeast: 1)
        waiting.cancel()
        #expect(await waiting.value == nil)
        continuation.yield(.clientShutDown)
        #expect(await probe.next(where: Self.isShutDown) == .clientShutDown)
        let cancelledEarly = Task { await probe.next(where: { _ in false }) }
        cancelledEarly.cancel()
        #expect(await cancelledEarly.value == nil)
    }
}
