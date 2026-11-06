import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A source whose handles the test drives: `cancel()` and `pause()` do not end the stream, so a completion can race
/// them as it does in the foreground transport (ARCHITECTURE §7.6, D-13). An actor: no lock (C1).
actor RacingSource: RemoteSource {
    /// A handle whose controls change nothing.
    struct Handle: TransferHandle {
        let id: TransferID
        let attempt: TransferAttempt
        let updates: AsyncStream<TransferUpdate>

        func setPriority(_ priority: AssetPriority) {}
        func pause() {}
        func cancel() {}
    }

    nonisolated let originID = "https://racing.example:443"
    nonisolated let capabilities = RemoteSourceCapabilities(tier: .aws, supportsPriority: true, supportsResume: true, supportsBackground: false, keepsSourceCopies: false)
    private(set) var requests: [TransferRequest] = []
    private var continuations: [AsyncStream<TransferUpdate>.Continuation] = []
    private var manifest: Data?

    init(manifest: Data) {
        self.manifest = manifest
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        guard let bytes = self.manifest else {
            return .notModified(removedSources: [])
        }
        self.manifest = nil
        return .fetched(ManifestPayload(bytes: bytes, etag: nil, origin: .network))
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        self.requests.append(request)
        let (stream, continuation) = AsyncStream.makeStream(of: TransferUpdate.self)
        self.continuations.append(continuation)
        return Handle(id: request.id, attempt: request.attempt, updates: stream)
    }

    /// Yields `update` on the `index`th handle; a terminal update ends its stream.
    func deliver(_ index: Int, _ update: TransferUpdate) {
        self.continuations[index].yield(update)
        if update.isTerminal {
            self.continuations[index].finish()
        }
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        []
    }

    func cancelTransfer(_ name: StagingFileName) async {}

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        ReclaimReport()
    }

    func sourceCopyBytes() async -> Int64 {
        0
    }

    func handleBackgroundEvents(identifier: String) async {}

    func invalidate() async {
        for continuation in self.continuations {
            continuation.finish()
        }
    }
}

/// Races between completion and cancellation (R-SYN-4, ARCHITECTURE §7.6).
@Suite("Engine races")
struct EngineRaceTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: publishing a transfer the engine cancelled treats ENOENT as that cancellation and never retries it", .timeLimit(.minutes(1)))
    func enoentAfterCancelIsTheCancellation() async throws {
        let bytes = EngineFixture.bytes(170)
        let entry = EngineHarness.onDemand("raced", bytes)
        let source = RacingSource(manifest: EngineFixture.manifestData([entry]))
        let harness = EngineHarness.make(remote: source)
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let first = Task { await engine.awaitAsset("raced", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(entry.transferID)
        first.cancel()
        #expect(await first.value == .failure(.cancelled))
        await engine.waitUntil { $0.jobsByState.isEmpty }
        // A new caller wants the content while the cancelled attempt still drains: it waits for that attempt.
        let second = Task { await engine.awaitAsset("raced", lane: .userInitiated) }
        await engine.waitUntil { $0.queued[.userInitiated] == 1 }
        #expect(await source.requests.count == 1)
        let cancelled = try #require(await source.requests.first)
        // The completion raced the cancel, whose discard already removed the bytes: publishing finds ENOENT.
        await source.deliver(0, .staged(StagedFile(name: cancelled.partialName, byteCount: Int64(bytes.count), resumed: false, httpStatus: 200, etag: nil)))
        // The drained file is published (no request), then a fresh attempt starts.
        await engine.awaitCondition { $0.state.metrics.transferRequests >= 2 }
        await engine.waitForHandle(entry.transferID)
        let requests = await source.requests
        #expect(requests.count == 2)
        let fresh = try #require(requests.last)
        #expect(fresh.resume == nil, "a fresh attempt")
        #expect(harness.time.pendingSleepers == 0, "no backoff")
        // No event waits for a follow, so the re-queue keeps no end for a pin (`EngineState.reroutePinCommits`; Stage 3
        // close-out cycle 22, ruling S3-R27 item 12.2's e1-R1): one kept would be reported with the barrier down.
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        let metrics = try await engine.metrics().get()
        #expect(metrics.failures == FailureCounts(), "ENOENT is the cancellation, not a failure")
        #expect(metrics.retries == FailureCounts())
        let sink = try await harness.store.makeStagingSink()
        try sink.createPartial(fresh.partialName)
        _ = try sink.appendPartial(bytes, to: fresh.partialName)
        await source.deliver(1, .staged(StagedFile(name: fresh.partialName, byteCount: Int64(bytes.count), resumed: false, httpStatus: 200, etag: nil)))
        #expect(try await second.value.get().id == "raced")
        #expect(await source.requests.count == 2, "never retried")
        await engine.shutdown()
    }
}
