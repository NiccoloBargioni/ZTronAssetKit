import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A handle whose update stream ends at once without a terminal element (a transport that drops its callbacks).
struct EndedStreamHandle: TransferHandle {
    let id: TransferID
    let attempt: TransferAttempt
    let updates: AsyncStream<TransferUpdate>

    init(id: TransferID, attempt: TransferAttempt) {
        self.id = id
        self.attempt = attempt
        let (stream, continuation) = AsyncStream.makeStream(of: TransferUpdate.self)
        continuation.finish()
        self.updates = stream
    }

    func setPriority(_ priority: AssetPriority) {}

    func pause() {}

    func cancel() {}
}

/// `FakeRemoteSource` whose first attempt of `truncated` returns `EndedStreamHandle` (sync-1 S1-11). An actor: no lock
/// (C1).
@available(macOS 15.0, iOS 18.0, *)
actor TruncatingSource: RemoteSource, StagingAttachable {
    let base: FakeRemoteSource
    let truncated: TransferID
    private var truncations = 1

    nonisolated var originID: String {
        self.base.originID
    }

    nonisolated var capabilities: RemoteSourceCapabilities {
        self.base.capabilities
    }

    init(base: FakeRemoteSource, truncated: TransferID) {
        self.base = base
        self.truncated = truncated
    }

    func attach(staging: any StagingSink) async {
        await self.base.attach(staging: staging)
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        try await self.base.fetchManifest(request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        if request.id == self.truncated, self.truncations > 0 {
            self.truncations -= 1
            return EndedStreamHandle(id: request.id, attempt: request.attempt)
        }
        return await self.base.transfer(request)
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        await self.base.reattachedTransfers()
    }

    func cancelTransfer(_ name: StagingFileName) async {
        await self.base.cancelTransfer(name)
    }

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        await self.base.reclaimSourceCopies(report)
    }

    func sourceCopyBytes() async -> Int64 {
        await self.base.sourceCopyBytes()
    }

    func handleBackgroundEvents(identifier: String) async {
        await self.base.handleBackgroundEvents(identifier: identifier)
    }

    func invalidate() async {
        await self.base.invalidate()
    }
}

extension EngineRegressionTests {
    /// A transfer whose stream ends without a terminal element fails its attempt (`transient(.incompleteCallbackSequence)`,
    /// recorded once) instead of leaving the job downloading for ever: the job backs off, and its retry delivers the
    /// asset to the waiter (sync-1 S1-11, ARCHITECTURE §12.3; Stage 3, S3-B-068).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a transfer stream that ends without a terminal element fails the job instead of stranding it", .timeLimit(.minutes(1)))
    func streamWithoutTerminalFailsTheJob() async throws {
        let bytes = EngineFixture.bytes(6_901)
        let entry = EngineHarness.onDemand("dropped", bytes)
        let base = FakeRemoteSource()
        let truncating = TruncatingSource(base: base, truncated: entry.transferID)
        let harness = EngineHarness.make(source: base, remote: truncating)
        await harness.serveManifest([entry])
        await base.script(entry.transferID, [.stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let waiter = Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        // The backoff's full jitter may make the retry due at once, so the failed state is not awaited: the failure is
        // read from the engine's record of it, and the retry from the waiter's answer.
        let answer = await harness.withClock {
            await waiter.value
        }
        #expect((try? answer.get()) != nil, "the retry delivered the asset: \(answer)")
        let recorded = await engine.readForTests { engine in
            engine.state.recentErrors.filter { $0.id == entry.identifier && $0.detail.contains("incompleteCallbackSequence") }.count
        }
        #expect(recorded == 1, "the ended stream failed its attempt once, as an incomplete callback sequence: \(recorded)")
        #expect(await base.starts.count == 1, "the retry reached the transport; the ended attempt never did")
        await engine.shutdown()
    }

    /// A bulk job a policy blocks (Low Data Mode; a bulk-lane handle keeps it) is promoted by a user resolve and starts
    /// at once (user-initiated work may use the constrained network); when the user waiter leaves, the job is demoted to
    /// bulk and its running transfer is paused again, parked by the same policy (sync-1 S1-07, ARCHITECTURE §12.3;
    /// Stage 3, S3-B-068).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: a user resolve of a policy-blocked bulk asset starts at once and its demotion pauses it again", .timeLimit(.minutes(1)))
    func userResolveOfPolicyBlockedBulk() async throws {
        let harness = EngineHarness.make(conditions: EngineConditionsTests.lowData)
        let bytes = EngineFixture.bytes(6_911)
        let entry = EngineFixture.entry("bulk", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        try await harness.start()
        let engine = harness.engine
        _ = await engine.sync(.force)
        // A bulk-lane handle keeps the job; the policy blocks it.
        let handle = try await engine.registerGroup([entry.identifier], lane: .bulk).get()
        await engine.awaitCondition { engine in
            if case .blocked(.policy)? = engine.state.jobs[entry.transferID]?.state {
                return true
            }
            return false
        }
        #expect(await harness.source.starts.isEmpty, "setup: the policy blocks the bulk job")
        let waiter = Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForAllHandles()
        #expect(await harness.source.starts.count == 1, "the user resolve started the blocked asset at once")
        waiter.cancel()
        _ = await waiter.value
        await engine.awaitCondition { engine in
            if case .blocked(.policy)? = engine.state.jobs[entry.transferID]?.state {
                return true
            }
            return false
        }
        let paused = await harness.source.controlLog.filter { $0.transfer == entry.transferID && $0.control == .pause }
        #expect(paused.count == 1, "the demotion paused the running transfer: \(paused)")
        await engine.releaseGroup(handle)
        await engine.shutdown()
    }
}
