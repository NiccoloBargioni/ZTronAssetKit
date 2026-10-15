import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A source whose manifest fetches wait until the test releases them (the manifest deadline, transport-2 T2-14).
@available(macOS 15.0, iOS 18.0, *)
actor SlowManifestSource: RemoteSource, StagingAttachable {
    let base: FakeRemoteSource
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    nonisolated var originID: String {
        self.base.originID
    }

    nonisolated var capabilities: RemoteSourceCapabilities {
        self.base.capabilities
    }

    init(base: FakeRemoteSource) {
        self.base = base
    }

    func attach(staging: any StagingSink) async {
        await self.base.attach(staging: staging)
    }

    /// Lets every held and later fetch proceed.
    func release() {
        self.released = true
        let held = self.waiting
        self.waiting.removeAll()
        for continuation in held {
            continuation.resume()
        }
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        if !self.released {
            // REENTRANCY: test source — nothing: resumed once by `release()`.
            await withCheckedContinuation { self.waiting.append($0) }
        }
        return try await self.base.fetchManifest(request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        await self.base.transfer(request)
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
        self.release()
        await self.base.invalidate()
    }
}

/// Failure paths of ARCHITECTURE §7.6 and §7.7, reconcile-time job changes (T21, T22), the manifest deadline,
/// launch reconciliation and a store that cannot open.
@Suite("Engine failure paths")
struct EngineFailurePathTests {
    static func evidence(_ purpose: TransferPurpose, xml: Bool, bytes: Int64) -> ForbiddenEvidence {
        ForbiddenEvidence(purpose: purpose, bodyBytes: bytes, contentTypeIsXML: xml, keyPresented: true, resumed: false)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an ambiguous 403 is never retried with backoff and never quarantines the asset beyond the run", .timeLimit(.minutes(1)))
    func ambiguousForbidden() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(300)
        let entry = EngineFixture.entry("guarded", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.fail(.authentication(.forbiddenAmbiguous(EngineFailurePathTests.evidence(.asset, xml: true, bytes: 120)))), .stage(bytes)])
        try await harness.start()
        let first = await harness.engine.sync(.force)
        guard case .completeWithFailures(let report) = first else {
            Issue.record("expected completeWithFailures, got \(first)")
            return
        }
        #expect(report.failures.map(\.error) == [.authRejected(.ambiguous)])
        #expect(await harness.source.starts.count == 1, "never retried within the run")
        #expect(harness.time.pendingSleepers == 0, "no backoff")
        // The next run fetches it again: nothing was quarantined.
        _ = try #require(await harness.engine.sync(.force).completeReport)
        #expect(await harness.source.starts.count == 2)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a manifest 403 opens the breaker and resolve fails fast without a request", .timeLimit(.minutes(1)))
    func manifestForbiddenOpensBreaker() async throws {
        let harness = EngineHarness.make()
        let entry = EngineHarness.onDemand("x", EngineFixture.bytes(301))
        await harness.serveManifest([entry])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        await harness.source.scriptManifest([.fail(.authentication(.forbiddenAmbiguous(EngineFailurePathTests.evidence(.manifest, xml: false, bytes: 0))))])
        let stream = try await harness.engine.subscribe().get()
        let probe = EventProbe(stream: stream)
        let blocked = await harness.engine.sync(.force)
        guard case .blocked(.circuitOpen(.authentication), _) = blocked else {
            Issue.record("expected a run blocked by the auth breaker, got \(blocked)")
            return
        }
        #expect(await harness.engine.awaitAsset("x", lane: .userInitiated) == .failure(.authRejected(.confirmed)))
        #expect(await harness.source.starts.isEmpty, "no request while the breaker is open")
        #expect(try await harness.engine.metrics().get().breakerTrips == 1)
        // The cooldown passes: the pending run's manifest fetch is the probe, and its success closes the breaker.
        await harness.serveManifest([entry], etag: "v2")
        try await harness.drive { $0.groups == 0 && $0.scheduledDeadlines == 0 && $0.armedTimers == 0 }
        let closed = await probe.next { event in
            if case .circuitChanged(_, .closed) = event {
                return true
            }
            return false
        }
        #expect(closed != nil)
        await probe.stop()
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: visiting a corrupt asset repeatedly never downloads it more than maxIntegrityAttempts times", .timeLimit(.minutes(1)))
    func corruptAssetIsNotRedownloadedForever() async throws {
        let harness = EngineHarness.make()
        let good = EngineFixture.bytes(302)
        let entry = EngineHarness.onDemand("corrupt", good)
        let wrong = EngineFixture.bytes(303)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, Array(repeating: FakeTransferStep.stage(wrong), count: 6))
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        for visit in 0..<8 {
            #expect(await engine.awaitAsset("corrupt", lane: .userInitiated) == .failure(.integrityFailure), "visit \(visit)")
            harness.time.advance(by: 700)
        }
        #expect(await harness.source.starts.count == harness.configuration.storage.maxIntegrityAttempts)
        guard case .failed(.integrity)? = try await harness.view().records["corrupt"]?.residency else {
            Issue.record("expected failed until the entry changes")
            return
        }
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a fetch blocked on ENOSPC resumes after the store's reaper frees doomed blobs", .timeLimit(.minutes(1)))
    func enospcWaitsForTheReaper() async throws {
        let harness = EngineHarness.make()
        let oldBytes = EngineFixture.bytes(304, count: 2_000)
        let old = EngineFixture.entry("old", oldBytes)
        await harness.serve([(old, oldBytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let newBytes = EngineFixture.bytes(305, count: 2_000)
        let new = EngineFixture.entry("new", newBytes)
        await harness.serveManifest([new], etag: "v2")
        await harness.source.script(new.transferID, [.fail(.insufficientSpace(requiredBytes: 2_000)), .stage(newBytes)])
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.jobsByState[.blocked] == 1 }
        #expect(await harness.source.starts.count == 2, "parked awaiting space: the prune's doomed blob is pending reclaim")
        try await harness.drive { $0.groups == 0 }
        #expect(await run.value.completeReport?.fetched == 1)
        #expect(await harness.source.starts.count == 3)
        #expect(try await harness.view().records["new"]?.referencedBlob != nil)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a fetch failing with ENOSPC and nothing to reclaim fails its waiter with the store's figures", .timeLimit(.minutes(1)))
    func enospcWithoutReclaim() async throws {
        // The volume cannot hold the 9,000 bytes the ENOSPC asks for (on one that can, the failure is retried, F-20).
        let harness = EngineHarness.make(capacity: StoragePolicy().reserveFreeBytes + 4_096)
        let entry = EngineHarness.onDemand("big", EngineFixture.bytes(306))
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.fail(.insufficientSpace(requiredBytes: 9_000))])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let result = await harness.engine.awaitAsset("big", lane: .userInitiated)
        guard case .failure(.insufficientSpace(let required, let available)) = result else {
            Issue.record("expected insufficientSpace, got \(result)")
            return
        }
        #expect(required == 9_000)
        #expect(available > 0, "the store's measured free space")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: a policy rejection fails the asset for the run with serverUnavailable and is not retried", .timeLimit(.minutes(1)))
    func rejectedNotRetried() async throws {
        let harness = EngineHarness.make()
        let entry = EngineHarness.onDemand("odd", EngineFixture.bytes(307))
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.fail(.rejected(.unexpectedStatus(400)))])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        #expect(await harness.engine.awaitAsset("odd", lane: .userInitiated) == .failure(.serverUnavailable(retryAfter: nil)))
        #expect(await harness.source.starts.count == 1)
        #expect(try await harness.engine.metrics().get().failures.rejected == 1)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a background-session failure retries the transfer in the foreground", .timeLimit(.minutes(1)))
    func backgroundFallsBackToForeground() async throws {
        let source = FakeRemoteSource(capabilities: EngineLaunchTests.background)
        let harness = EngineHarness.make(source: source)
        let bytes = EngineFixture.bytes(308)
        let entry = EngineFixture.entry("bulk", bytes)
        await harness.serveManifest([entry])
        await source.script(entry.transferID, [.fail(.transient(.backgroundSessionUnavailable(urlErrorCode: -996), retryAfter: nil)), .stage(bytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let routes = await source.starts.map(\.route)
        #expect(routes == [.backgroundEligible, .foreground])
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: transient failures in backoff are retried early on a satisfied edge", .timeLimit(.minutes(1)))
    func transientRetriedOnEdge() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(309)
        let entry = EngineHarness.onDemand("flaky", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.fail(.transient(.timedOut, retryAfter: nil)), .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let group = try await engine.registerGroup(["flaky"], lane: .prefetch).get()
        await engine.waitUntil { $0.jobsByState[.failed] == 1 && $0.scheduledDeadlines >= 1 }
        await harness.conditions.send(EngineConditionsTests.offline)
        await harness.conditions.send(.unrestricted)
        await engine.waitUntil { $0.jobsByState.isEmpty }
        #expect(await harness.source.starts.count == 2, "retried on the edge, before the backoff ended")
        #expect(try await engine.metrics().get().retries.transient == 1)
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: an asset removed from the manifest while a user waits fails that waiter with notFound", .timeLimit(.minutes(1)))
    func prunedWhileWaiting() async throws {
        let harness = EngineHarness.make()
        let doomed = EngineHarness.onDemand("doomed", EngineFixture.bytes(310))
        let kept = EngineHarness.onDemand("kept", EngineFixture.bytes(311))
        await harness.serveManifest([doomed, kept])
        await harness.source.script(doomed.transferID, [.hold])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let waiter = Task { await engine.awaitAsset("doomed", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(doomed.transferID)
        await harness.serveManifest([kept], etag: "v2")
        _ = await engine.sync(.force)
        #expect(await waiter.value == .failure(.notFound))
        await engine.waitUntil { $0.jobsByState.isEmpty }
        #expect(await harness.source.controlLog.contains(FakeControlRecord(transfer: doomed.transferID, control: .cancel)))
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a waiter of an asset whose content changes follows it to the new content", .timeLimit(.minutes(1)))
    func contentChangeCarriesWaiter() async throws {
        let harness = EngineHarness.make()
        let before = EngineHarness.onDemand("moving", EngineFixture.bytes(312))
        let newBytes = EngineFixture.bytes(313, count: 777)
        let after = EngineHarness.onDemand("moving", newBytes)
        let sibling = EngineHarness.onDemand("sibling", EngineFixture.bytes(312))
        await harness.serveManifest([before, sibling])
        await harness.source.script(before.transferID, [.hold])
        await harness.source.script(after.transferID, [.stage(newBytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let waiter = Task { await engine.awaitAsset("moving", lane: .userInitiated) }
        let siblingWaiter = Task { await engine.awaitAsset("sibling", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 2 && $0.running == 1 }
        await harness.serveManifest([after, sibling], etag: "v2")
        _ = await engine.sync(.force)
        let location = try await waiter.value.get()
        #expect(location.byteSize == 777, "the waiter got the new content")
        #expect(await harness.source.starts.map(\.id).contains(after.transferID))
        siblingWaiter.cancel()
        _ = await siblingWaiter.value
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a manifest fetch past its deadline falls back to the applied manifest and leaves the sync due", .timeLimit(.minutes(1)))
    func manifestDeadlineFallsBack() async throws {
        let base = FakeRemoteSource()
        let slow = SlowManifestSource(base: base)
        let harness = EngineHarness.make(remote: slow)
        let bytes = EngineFixture.bytes(314)
        let entry = EngineFixture.entry("applied", bytes)
        await slow.release()
        await base.scriptManifest([.fetched(EngineFixture.manifestData([entry]), etag: EngineFixture.etag("v1"))])
        await base.script(entry.transferID, [.stage(bytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        // A second lifetime, of a new app version (a sync is due), whose fetches hang until released.
        await harness.engine.shutdown()
        let hanging = SlowManifestSource(base: FakeRemoteSource())
        let second = EngineHarness.make(disk: harness.fileSystem.survivingDisk(), time: harness.time, appVersion: "1.1+2", remote: hanging)
        try await second.start()
        let engine = second.engine
        #expect(try await engine.isSyncDue().get())
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.groups == 1 && $0.armedTimers == 1 }
        try await second.time.requireSleepers(atLeast: 1)
        second.time.advance(by: second.configuration.tuning.manifestFetchDeadline)
        let outcome = await run.value
        guard case .complete(let report) = outcome else {
            Issue.record("expected a complete run on the applied manifest, got \(outcome)")
            return
        }
        #expect(!report.manifestFresh)
        // The new version's manifest was never fetched: no stamp is written, so the sync stays due (F-15).
        #expect(try await engine.isSyncDue().get(), "a run that could not fetch the manifest leaves the sync due")
        await hanging.release()
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: launch reconciliation resumes a wanted partial with its sidecar and cancels an unwanted live task", .timeLimit(.minutes(1)))
    func launchResumesPartial() async throws {
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(315, count: 3_000)
        let entry = EngineHarness.onDemand("resumed", bytes)
        let first = try await EngineLaunchTests.firstLifetime([entry], time: time)
        let fileSystem = FakeFileSystem(disk: first.fileSystem.survivingDisk(), time: time)
        let layout = StoreLayout(base: EngineHarness.base)
        let partial = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 7), kind: .partial)
        try fileSystem.write(bytes.prefix(1_200), to: layout.stagingURL(partial), mode: .truncate)
        let validator = ResumeValidator.strongETag(try #require(EngineFixture.etag("v1")))
        let sidecar = ResumeSidecar(name: partial, validator: validator, receivedBytes: 1_200, expectedBytes: 3_000)
        try fileSystem.write(try JSONEncoder().encode(sidecar), to: layout.stagingURL(partial.with(kind: .sidecar)), mode: .truncate)
        let unwanted = StagingFileName(transfer: .content(ContentHash.sha256(of: Data("gone".utf8))), attempt: TransferAttempt(epoch: 1, sequence: 8), kind: .partial)
        let source = FakeRemoteSource()
        await source.scriptReattached([ReattachedTransfer(name: unwanted, isRunning: true, bytesReceived: 10)])
        await source.script(entry.transferID, [.stage(bytes)])
        let second = EngineHarness.make(time: time, source: source, fileSystem: fileSystem)
        try await second.start()
        #expect(await source.cancelledTransfers == [unwanted])
        let location = try await second.engine.awaitAsset("resumed", lane: .userInitiated).get()
        #expect(location.byteSize == 3_000)
        #expect(await source.starts.first?.resume == ResumePoint(previous: partial, offset: 1_200, validator: validator))
        await second.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-7: a store that cannot open degrades the engine and every API answers storageUnavailable", .timeLimit(.minutes(1)))
    func lockedStoreDegrades() async throws {
        let owner = EngineHarness.make()
        try await owner.start()
        let second = EngineHarness.make(time: owner.time, fileSystem: owner.fileSystem)
        let failure = AssetError.storageUnavailable(.locked)
        #expect(await second.engine.start() == .failure(failure))
        #expect(await second.engine.introspect().lifecycle == .degraded(.locked))
        #expect(await second.engine.awaitAsset("x", lane: .userInitiated) == .failure(failure))
        #expect(await second.engine.sync(.force) == .failed(failure))
        #expect(await second.engine.registerGroup(["x"], lane: .prefetch) == .failure(failure))
        #expect(await second.engine.availability(scope: .all) == .failure(failure))
        await second.engine.shutdown()
        #expect(await second.engine.introspect().lifecycle == .shutDown)
        await owner.engine.shutdown()
    }
}
