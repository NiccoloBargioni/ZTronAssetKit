import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// The scripted URLSession side for `HTTPRemoteSource` tests (WP-D).
@Suite("Test support: FakeTransferBackend")
struct TestSupportFakeTransferBackendTests {
    static func job(_ sequence: UInt32) -> TransferJob {
        TransferJob(
            id: .content(ContentHash.sha256(of: Data([UInt8(sequence)]))),
            attempt: TransferAttempt(epoch: 1, sequence: sequence),
            url: URL(string: "https://cdn.example.com/a.png")!,
            purpose: .asset,
            expectedBytes: 4,
            maxBytes: 64,
            priority: .prefetch
        )
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: start records the job and returns a handle the test drives", .timeLimit(.minutes(1)))
    func startReturnsDrivableHandle() async {
        let backend = FakeTransferBackend(kind: .background)
        let handle = await backend.start(Self.job(1))
        #expect(backend.kind == .background)
        #expect(await backend.jobs == [Self.job(1)])
        let handles = await backend.handles
        #expect(handles.count == 1)
        #expect(handles.first?.id == Self.job(1).id && handles.first?.attempt == Self.job(1).attempt)
        handles.first?.deliver(.failed(.offline(.noConnection)))
        var received: [TransferUpdate] = []
        for await update in handle.updates {
            received.append(update)
        }
        #expect(received == [.failed(.offline(.noConnection))])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: live transfers are scripted, cancellations are recorded and remove the cancelled name", .timeLimit(.minutes(1)))
    func liveTransfersAndCancellations() async {
        let backend = FakeTransferBackend()
        let first = LiveTransfer(name: Self.job(1).partialName, backend: .foreground, isRunning: true, bytesReceived: 1, priority: 0.25)
        let second = LiveTransfer(name: Self.job(2).partialName, backend: .foreground, isRunning: false, bytesReceived: 0, priority: 0.5)
        await backend.scriptLiveTransfers([first, second])
        #expect(await backend.liveTransfers() == [first, second])
        await backend.cancel(first.name, keepingPartial: true)
        #expect(await backend.liveTransfers() == [second])
        #expect(await backend.cancellations == [FakeBackendCancellation(name: first.name, keepingPartial: true)])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: invalidate fails every handle with a client cancellation and is counted", .timeLimit(.minutes(1)))
    func invalidateCancelsHandles() async {
        let backend = FakeTransferBackend()
        let handle = await backend.start(Self.job(1))
        await backend.invalidate()
        await backend.invalidate()
        #expect(await backend.invalidations == 2)
        var received: [TransferUpdate] = []
        for await update in handle.updates {
            received.append(update)
        }
        #expect(received == [.failed(.cancelled(.byClient))])
    }

    /// The Model's `TransferHandle`: terminating the updates stream (its consumer cancelled) cancels the transfer, so
    /// an `HTTPRemoteSource` test sees the cancellation a driver task's cancellation makes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: cancelling the task that consumes a handle's updates records a cancellation on the handle", .timeLimit(.minutes(1)))
    func cancelledConsumerCancelsHandle() async throws {
        let backend = FakeTransferBackend()
        _ = await backend.start(Self.job(1))
        let handle = try #require(await backend.handles.first)
        let consumer = Task {
            var received: [TransferUpdate] = []
            for await update in handle.updates {
                received.append(update)
            }
            return received
        }
        consumer.cancel()
        #expect(await consumer.value == [])
        #expect(handle.controls == [.cancel])
        handle.cancel()
        #expect(handle.controls == [.cancel, .cancel])
    }

    /// `.paused(resumable:)` says whether a partial plus a validator were kept: a stand-alone handle stands for a
    /// transfer that kept both until the test says otherwise.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a stand-alone handle pauses resumably unless the test says no partial was kept", .timeLimit(.minutes(1)))
    func standalonePauseOutcome() async {
        let kept = FakeTransferHandle(id: Self.job(1).id, attempt: Self.job(1).attempt)
        kept.pause()
        let lost = FakeTransferHandle(id: Self.job(2).id, attempt: Self.job(2).attempt)
        lost.setPauseResumable(false)
        lost.pause()
        var outcomes: [TransferUpdate] = []
        for await update in kept.updates {
            outcomes.append(update)
        }
        for await update in lost.updates {
            outcomes.append(update)
        }
        #expect(outcomes == [.paused(resumable: true), .paused(resumable: false)])
        #expect(kept.controls == [.pause] && lost.controls == [.pause])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a handle ends with exactly one terminal update when a scripted delivery races a cancel", .timeLimit(.minutes(1)))
    func racingTerminalsDeliverOne() async {
        let staged = TransferUpdate.staged(StagedFile(name: Self.job(1).partialName, byteCount: 4, resumed: false, httpStatus: 200, etag: nil))
        for round in 0..<2_000 {
            let handle = FakeTransferHandle(id: Self.job(1).id, attempt: Self.job(1).attempt)
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    handle.deliver(staged)
                } else {
                    handle.cancel()
                }
            }
            var terminals: [TransferUpdate] = []
            for await update in handle.updates where update.isTerminal {
                terminals.append(update)
            }
            #expect(terminals.count == 1, "round \(round): \(terminals)")
            #expect(handle.controls == [.cancel])
        }
    }
}
