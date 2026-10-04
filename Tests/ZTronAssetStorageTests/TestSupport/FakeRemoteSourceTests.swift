import CryptoKit
import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetTestSupport

/// The scripted engine network (R-NET-1, H-4, H-6): steps through the attached staging sink, holds and releases,
/// attempts, the one ordered transport log, manifests, re-attachment and shutdown.
@Suite("Test support: FakeRemoteSource")
struct TestSupportFakeRemoteSourceTests {
    static let id = TransferID.content(ContentHash.sha256(of: Data([1, 2, 3, 4])))
    static let other = TransferID.content(ContentHash.sha256(of: Data([9])))

    static func request(_ id: TransferID = Self.id, _ sequence: UInt32 = 1, expected: Int64? = 4, resume: ResumePoint? = nil) -> TransferRequest {
        TransferRequest(
            id: id,
            attempt: TransferAttempt(epoch: 3, sequence: sequence),
            remotePath: "media/a.png",
            expectedBytes: expected,
            maxBytes: 1 << 20,
            priority: .bulk,
            resume: resume
        )
    }

    static func staged(_ request: TransferRequest, _ count: Int64, resumed: Bool = false) -> TransferUpdate {
        .staged(StagedFile(name: request.partialName, byteCount: count, resumed: resumed, httpStatus: 200, etag: nil))
    }

    static func updates(of handle: any TransferHandle) async -> [TransferUpdate] {
        var all: [TransferUpdate] = []
        for await update in handle.updates {
            all.append(update)
        }
        return all
    }

    @available(macOS 15.0, *)
    @Test("Test support: a staged step writes through the attached sink and reports the staged file", .timeLimit(.minutes(1)))
    func stageWritesThroughSink() async {
        let source = FakeRemoteSource()
        let sink = FakeStagingSink()
        await source.attach(staging: sink)
        await source.script(Self.id, [.progress(2), .stage(Data([1, 2, 3, 4]))])
        let request = Self.request()
        let handle = await source.transfer(request)
        #expect(await Self.updates(of: handle) == [.progress(received: 2, expected: 4), Self.staged(request, 4)])
        #expect(sink.contents[request.partialName] == Data([1, 2, 3, 4]))
        #expect(await source.activeTransfers == 0)
        #expect(await source.starts == [request])
    }

    @available(macOS 15.0, *)
    @Test("Test support: without an attached sink a staged step fails with localIO instead of hanging", .timeLimit(.minutes(1)))
    func stageWithoutSinkFails() async {
        let source = FakeRemoteSource()
        await source.script(Self.id, [.stage(Data([1]))])
        let handle = await source.transfer(Self.request())
        #expect(await Self.updates(of: handle) == [.failed(.transient(.localIO(posixCode: ENXIO), retryAfter: nil))])
    }

    @available(macOS 15.0, *)
    @Test("Test support: a sink ENOSPC fails the transfer with insufficientSpace and another sink error with localIO", .timeLimit(.minutes(1)))
    func sinkErrorsMapLikeTheTransport() async {
        let source = FakeRemoteSource()
        let sink = FakeStagingSink()
        await source.attach(staging: sink)
        sink.failNext(.appendPartial, with: .insufficientSpace)
        await source.script(Self.id, [.stage(Data([1, 2])), .stage(Data([1, 2]))])
        let first = await source.transfer(Self.request(Self.id, 1))
        #expect(await Self.updates(of: first) == [.failed(.insufficientSpace(requiredBytes: nil))])
        sink.failNext(.createPartial, with: .io(posixCode: EIO))
        let second = await source.transfer(Self.request(Self.id, 2))
        #expect(await Self.updates(of: second) == [.failed(.transient(.localIO(posixCode: EIO), retryAfter: nil))])
    }

    @available(macOS 15.0, *)
    @Test("Test support: a generated step streams the payload in bounded chunks that hash like GeneratedPayload.sha256", .timeLimit(.minutes(1)))
    func generatedPayloadStreamsInChunks() async {
        let source = FakeRemoteSource()
        let sink = FakeSourceChunkRecordingSink()
        await source.attach(staging: sink)
        let size = Int64(GeneratedPayload.chunkBytes * 2 + 100)
        await source.script(Self.id, [.stageGenerated(seed: 77, byteCount: size)])
        let request = Self.request(expected: size)
        let handle = await source.transfer(request)
        #expect(await Self.updates(of: handle) == [Self.staged(request, size)])
        #expect(sink.appendSizes == [GeneratedPayload.chunkBytes, GeneratedPayload.chunkBytes, 100])
        #expect(sink.digest == GeneratedPayload.sha256(seed: 77, byteCount: size))
    }

    @available(macOS 15.0, *)
    @Test("Test support: scripted steps are consumed across attempts, each attempt up to its terminal step", .timeLimit(.minutes(1)))
    func stepsSpanAttempts() async {
        let source = FakeRemoteSource()
        await source.attach(staging: FakeStagingSink())
        await source.script(Self.id, [.progress(1), .fail(.offline(.noConnection))])
        await source.script(Self.id, [.stage(Data([1, 2, 3, 4]))])
        let first = await source.transfer(Self.request(Self.id, 1))
        #expect(await Self.updates(of: first) == [.progress(received: 1, expected: 4), .failed(.offline(.noConnection))])
        let retry = Self.request(Self.id, 2)
        let second = await source.transfer(retry)
        #expect(await Self.updates(of: second) == [Self.staged(retry, 4)])
    }

    @available(macOS 15.0, *)
    @Test("Test support: a hold keeps the transfer active until release ends it", .timeLimit(.minutes(1)))
    func holdUntilRelease() async {
        let source = FakeRemoteSource()
        await source.script(Self.id, [.hold])
        let request = Self.request()
        let handle = await source.transfer(request)
        #expect(await source.activeTransfers == 1)
        await source.release(Self.id, with: Self.staged(request, 4))
        #expect(await Self.updates(of: handle) == [Self.staged(request, 4)])
        #expect(await source.activeTransfers == 0)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a release that arrives before the hold ends that hold at once", .timeLimit(.minutes(1)))
    func earlyReleaseIsKept() async {
        let source = FakeRemoteSource()
        await source.release(Self.id, with: .failed(.permanentMissing(httpStatus: 404)))
        await source.script(Self.id, [.hold])
        let handle = await source.transfer(Self.request())
        #expect(await Self.updates(of: handle) == [.failed(.permanentMissing(httpStatus: 404))])
        #expect(await source.activeTransfers == 0)
    }

    @available(macOS 15.0, *)
    @Test("Test support: early releases are delivered in order: progress continues the attempt, a terminal one ends it", .timeLimit(.minutes(1)))
    func earlyReleasesInOrder() async {
        let source = FakeRemoteSource()
        await source.attach(staging: FakeStagingSink())
        await source.release(Self.id, with: .progress(received: 1, expected: 4))
        await source.release(Self.id, with: .progress(received: 2, expected: 4))
        await source.script(Self.id, [.hold, .stage(Data([1, 2, 3, 4]))])
        let request = Self.request(Self.id, 1)
        let first = await source.transfer(request)
        #expect(await Self.updates(of: first) == [.progress(received: 1, expected: 4), Self.staged(request, 4)])
        let second = await source.transfer(Self.request(Self.id, 2))
        #expect(await source.activeTransfers == 1)
        await source.release(Self.id, with: .failed(.offline(.noConnection)))
        #expect(await Self.updates(of: second) == [.progress(received: 2, expected: 4), .failed(.offline(.noConnection))])

        await source.release(Self.other, with: .failed(.cancelled(.byClient)))
        let unscripted = await source.transfer(Self.request(Self.other, 3))
        #expect(await Self.updates(of: unscripted) == [.failed(.cancelled(.byClient))])
        #expect(await source.activeTransfers == 0)
    }

    @available(macOS 15.0, *)
    @Test(
        "Test support: every staging failure maps the way the transport maps it",
        .timeLimit(.minutes(1)),
        arguments: [
            (StagingError.tooLarge(limit: 1), TransferError.transient(.localIO(posixCode: EFBIG), retryAfter: nil)),
            (.source(.readFailed), .transient(.localIO(posixCode: EIO), retryAfter: nil)),
            (.nameInUse, .transient(.localIO(posixCode: EEXIST), retryAfter: nil)),
        ]
    )
    func stagingErrorMapping(error: StagingError, expected: TransferError) async {
        let source = FakeRemoteSource()
        let sink = FakeStagingSink()
        await source.attach(staging: sink)
        sink.failNext(.createPartial, with: error)
        await source.script(Self.id, [.stageGenerated(seed: 1, byteCount: 8)])
        let handle = await source.transfer(Self.request())
        #expect(await Self.updates(of: handle) == [.failed(expected)])
    }

    @available(macOS 15.0, *)
    @Test("Test support: an Apple-tier source reports pack manifests and staged files without an HTTP status", .timeLimit(.minutes(1)))
    func appleTierShapes() async throws {
        let capabilities = RemoteSourceCapabilities(tier: .appleHosted, supportsPriority: false, supportsResume: false, supportsBackground: false, keepsSourceCopies: true)
        let source = FakeRemoteSource(originID: "apple-hosted", capabilities: capabilities)
        await source.attach(staging: FakeStagingSink())
        await source.scriptManifest([.fetched(Data([1]), etag: nil)])
        let request = ManifestRequest(ifNoneMatch: nil, maxBytes: 64, attempt: TransferAttempt(epoch: 1, sequence: 1))
        #expect(try await source.fetchManifest(request) == .fetched(ManifestPayload(bytes: Data([1]), etag: nil, origin: .installedPack(updateChecked: true))))
        await source.script(Self.id, [.stage(Data())])
        let staged = Self.request(expected: 0)
        let handle = await source.transfer(staged)
        #expect(await Self.updates(of: handle) == [.staged(StagedFile(name: staged.partialName, byteCount: 0, resumed: false, httpStatus: nil, etag: nil))])
        #expect(source.originID == "apple-hosted" && source.capabilities == capabilities)
        #expect(await (source.attachedStaging as? FakeStagingSink) != nil)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a non-terminal release continues the held attempt with its remaining steps", .timeLimit(.minutes(1)))
    func progressReleaseContinues() async {
        let source = FakeRemoteSource()
        await source.attach(staging: FakeStagingSink())
        await source.script(Self.id, [.hold, .stage(Data([1, 2, 3, 4]))])
        let request = Self.request()
        let handle = await source.transfer(request)
        await source.release(Self.id, with: .progress(received: 1, expected: 4))
        #expect(await Self.updates(of: handle) == [.progress(received: 1, expected: 4), Self.staged(request, 4)])
    }

    @available(macOS 15.0, *)
    @Test("Test support: an unscripted transfer stays active until a script for it arrives", .timeLimit(.minutes(1)))
    func unscriptedWaitsForScript() async {
        let source = FakeRemoteSource()
        await source.attach(staging: FakeStagingSink())
        let request = Self.request()
        let handle = await source.transfer(request)
        #expect(await source.activeTransfers == 1)
        await source.script(Self.id, [.stage(Data([1, 2, 3, 4]))])
        #expect(await Self.updates(of: handle) == [Self.staged(request, 4)])
        #expect(await source.activeTransfers == 0)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a paused transfer is no longer active and a later release goes to the next attempt", .timeLimit(.minutes(1)))
    func pausedAttemptIsSkipped() async {
        let source = FakeRemoteSource()
        await source.script(Self.id, [.hold, .hold])
        let first = await source.transfer(Self.request(Self.id, 1))
        first.pause()
        #expect(await source.activeTransfers == 0)
        let retry = Self.request(Self.id, 2)
        let second = await source.transfer(retry)
        await source.release(Self.id, with: Self.staged(retry, 4))
        #expect(await Self.updates(of: first) == [.paused(resumable: true)])
        #expect(await Self.updates(of: second) == [Self.staged(retry, 4)])
    }

    @available(macOS 15.0, *)
    @Test("Test support: starts and controls share one ordered log, so a priority change before a later start is provable", .timeLimit(.minutes(1)))
    func oneOrderedTransportLog() async {
        let source = FakeRemoteSource()
        let bulk = Self.request(Self.id, 1)
        let next = Self.request(Self.other, 2)
        let promoted = await source.transfer(bulk)
        promoted.setPriority(.userInitiated)
        _ = await source.transfer(next)
        promoted.cancel()
        let promote = FakeControlRecord(transfer: Self.id, control: .setPriority(.userInitiated))
        let cancel = FakeControlRecord(transfer: Self.id, control: .cancel)
        #expect(source.transportLog.events == [.started(bulk), .controlled(promote), .started(next), .controlled(cancel)])
        #expect(await source.activeTransfers == 1)
    }

    @available(macOS 15.0, *)
    @Test("Test support: manifest responses are served in script order and an unscripted fetch answers notModified", .timeLimit(.minutes(1)))
    func manifestScript() async throws {
        let source = FakeRemoteSource()
        let tag = try #require(ETag(rawValue: "\"v1\""))
        await source.scriptManifest([.fetched(Data("{}".utf8), etag: tag), .notModified])
        await source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(30)))])
        let request = ManifestRequest(ifNoneMatch: tag, maxBytes: 1 << 20, attempt: TransferAttempt(epoch: 1, sequence: 1))
        #expect(try await source.fetchManifest(request) == .fetched(ManifestPayload(bytes: Data("{}".utf8), etag: tag, origin: .network)))
        #expect(try await source.fetchManifest(request) == .notModified(removedSources: []))
        await #expect(throws: TransferError.transient(.throttled, retryAfter: .seconds(30))) { try await source.fetchManifest(request) }
        #expect(try await source.fetchManifest(request) == .notModified(removedSources: []))
        #expect(await source.manifestRequests == [request, request, request, request])
    }

    @available(macOS 15.0, *)
    @Test("Test support: scripted re-attached transfers are returned by exactly one launch", .timeLimit(.minutes(1)))
    func reattachedOnce() async {
        let source = FakeRemoteSource()
        let live = ReattachedTransfer(name: Self.request().partialName, isRunning: true, bytesReceived: 10)
        #expect(await source.reattachedTransfers() == [])
        await source.scriptReattached([live])
        #expect(await source.reattachedTransfers() == [live])
        #expect(await source.reattachedTransfers() == [])
    }

    @available(macOS 15.0, *)
    @Test("Test support: invalidate ends every active transfer with a client cancellation and later transfers fail at once", .timeLimit(.minutes(1)))
    func invalidateEndsEverything() async {
        let source = FakeRemoteSource()
        await source.script(Self.id, [.hold])
        let held = await source.transfer(Self.request(Self.id, 1))
        let waiting = await source.transfer(Self.request(Self.other, 2))
        #expect(await source.activeTransfers == 2)
        await source.invalidate()
        #expect(await source.isInvalidated)
        #expect(await source.activeTransfers == 0)
        #expect(await Self.updates(of: held) == [.failed(.cancelled(.byClient))])
        #expect(await Self.updates(of: waiting) == [.failed(.cancelled(.byClient))])
        let late = Self.request(Self.id, 3)
        let after = await source.transfer(late)
        #expect(await Self.updates(of: after) == [.failed(.cancelled(.byClient))])
        #expect(await source.starts.last == late)
        #expect(await source.activeTransfers == 0)
    }

    /// An engine that pauses or cancels many parked attempts (window moves, R-CAR-3, R-SYN-4) without ever calling
    /// `script` or `release` must not leave them in the source: the next interaction drops them.
    @available(macOS 15.0, *)
    @Test("Test support: attempts the engine paused or cancelled are dropped at the next census read or transfer", .timeLimit(.minutes(1)))
    func stoppedAttemptsAreDropped() async {
        let source = FakeRemoteSource()
        await source.script(Self.other, [.hold])
        for sequence in UInt32(1)...20 {
            let handle = await source.transfer(Self.request(sequence == 1 ? Self.other : Self.id, sequence))
            if sequence.isMultiple(of: 2) {
                handle.pause()
            } else {
                handle.cancel()
            }
        }
        #expect(await source.activeTransfers == 0)
        #expect(await source.parkedAttempts == 0)
        for sequence in UInt32(21)...40 {
            await source.transfer(Self.request(Self.id, sequence)).cancel()
        }
        let live = await source.transfer(Self.request(Self.id, 41))
        #expect(await source.parkedAttempts == 1)
        #expect(await source.activeTransfers == 1)
        await source.release(Self.id, with: .failed(.cancelled(.byClient)))
        #expect(await Self.updates(of: live) == [.failed(.cancelled(.byClient))])
        #expect(await source.parkedAttempts == 0)
    }

    @available(macOS 15.0, *)
    @Test("Test support: cancellations of re-attached transfers, reclaim reports and background events are recorded", .timeLimit(.minutes(1)))
    func recordsSideCalls() async {
        let source = FakeRemoteSource()
        let name = Self.request().partialName
        let report = AdoptionReport(manifestRemotePaths: ["a"], adoptedRemotePaths: ["a"])
        await source.cancelTransfer(name)
        #expect(await source.reclaimSourceCopies(report) == ReclaimReport())
        await source.handleBackgroundEvents(identifier: "com.ztron.assetkit.background")
        await source.setSourceCopyBytes(42)
        #expect(await source.cancelledTransfers == [name])
        #expect(await source.reclaimReports == [report])
        #expect(await source.backgroundEventIdentifiers == ["com.ztron.assetkit.background"])
        #expect(await source.sourceCopyBytes() == 42)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a resumed request continues the earlier partial and appends only the bytes it lacks", .timeLimit(.minutes(1)))
    func resumeContinuesPartial() async throws {
        let source = FakeRemoteSource()
        let sink = FakeStagingSink()
        await source.attach(staging: sink)
        let earlier = Self.request(Self.id, 1).partialName
        try sink.createPartial(earlier)
        _ = try sink.appendPartial(Data([1, 2]), to: earlier)
        let validator = ResumeValidator.strongETag(try #require(ETag(rawValue: "\"e\"")))
        let resumed = Self.request(Self.id, 2, resume: ResumePoint(previous: earlier, offset: 2, validator: validator))
        await source.script(Self.id, [.stage(Data([1, 2, 3, 4])), .stage(Data([1, 2, 3, 4]))])
        let handle = await source.transfer(resumed)
        #expect(await Self.updates(of: handle) == [Self.staged(resumed, 4, resumed: true)])
        #expect(sink.contents == [resumed.partialName: Data([1, 2, 3, 4])])

        let missing = Self.request(Self.id, 3, resume: ResumePoint(previous: earlier, offset: 2, validator: validator))
        let failed = await source.transfer(missing)
        #expect(await Self.updates(of: failed) == [.failed(.transient(.localIO(posixCode: ENOENT), retryAfter: nil))])
    }
}

/// A staging sink that records the size of every append and hashes what it receives (never storing it).
@available(macOS 15.0, *)
final class FakeSourceChunkRecordingSink: StagingSink {
    private let state = Mutex<(sizes: [Int], hasher: SHA256, total: Int64)>(([], SHA256(), 0))

    var appendSizes: [Int] {
        self.state.withLock { $0.sizes }
    }

    var digest: ContentHash {
        self.state.withLock { ContentHash(digest: $0.hasher.finalize()) }
    }

    func createPartial(_ name: StagingFileName) throws(StagingError) {
        self.state.withLock { $0 = ([], SHA256(), 0) }
    }

    func appendPartial(_ data: Data, to name: StagingFileName) throws(StagingError) -> Int64 {
        self.state.withLock { state in
            state.sizes.append(data.count)
            state.hasher.update(data: data)
            state.total += Int64(data.count)
            return state.total
        }
    }

    func continuePartial(from previous: StagingFileName, as next: StagingFileName) throws(StagingError) -> Int64 {
        throw .nameInUse
    }

    func adoptDownload(at location: URL, as name: StagingFileName) throws(StagingError) -> Int64 {
        throw .nameInUse
    }

    func writeSidecar(_ sidecar: ResumeSidecar) {}

    func readSidecar(for name: StagingFileName) async -> ResumeSidecar? {
        nil
    }

    func readStaged(_ name: StagingFileName, maxBytes: Int64) async throws(StagingError) -> Data {
        throw .nameInUse
    }

    func discard(_ name: StagingFileName) async {}

    func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError) -> Int64 {
        throw .nameInUse
    }
}
