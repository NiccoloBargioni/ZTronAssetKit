import Foundation
import Synchronization
import ZTronAssetModel

/// In-memory `UserDefaults` for migration tests: real defaults are never touched (owner directive). Gated for
/// `Mutex` (ADR-014).
@available(macOS 15.0, iOS 18.0, *)
public final class FakeLegacyDefaults: LegacyDefaults {
    private let values: Mutex<[String: String]>
    private let removed: Mutex<[String]>

    /// Starts with `values`.
    public init(values: [String: String] = [:]) {
        self.values = Mutex(values)
        self.removed = Mutex([])
    }

    /// The stored string.
    public func string(forKey key: String) -> String? {
        self.values.withLock { $0[key] }
    }

    /// Removes the key and records the removal.
    public func removeValue(forKey key: String) {
        self.values.withLock { _ = $0.removeValue(forKey: key) }
        self.removed.withLock { $0.append(key) }
    }

    /// Keys removed, in order.
    public var removedKeys: [String] {
        self.removed.withLock { $0 }
    }
}

/// Records every rendered log line (R-OBS-1, R-SEC-1 canary tests). Gated for `Mutex` (ADR-014).
@available(macOS 15.0, iOS 18.0, *)
public final class RecordingLogTap: LogTap {
    private let recorded: Mutex<[LogLine]>

    /// Starts empty.
    public init() {
        self.recorded = Mutex([])
    }

    /// Appends a line.
    public func record(_ line: LogLine) {
        self.recorded.withLock { $0.append(line) }
    }

    /// Lines so far.
    public var lines: [LogLine] {
        self.recorded.withLock { $0 }
    }
}

/// A transfer handle driven by the test (R-SYN-3, R-SYN-4, R-NET-10 tests): every control is recorded in call
/// order under a lock, so the order of `setPriority` relative to other starts is observable (sync-1 S1-06).
/// `cancel()` and `pause()` end the stream with their terminal element; `deliver` yields what the test scripts.
/// Gated for `Mutex` (ADR-014).
@available(macOS 15.0, iOS 18.0, *)
public final class FakeTransferHandle: TransferHandle {
    /// The content.
    public let id: TransferID
    /// The attempt.
    public let attempt: TransferAttempt
    /// The update stream.
    public let updates: AsyncStream<TransferUpdate>
    private let continuation: AsyncStream<TransferUpdate>.Continuation
    private let log: Mutex<[TransferControl]>

    /// Creates a handle.
    public init(id: TransferID, attempt: TransferAttempt) {
        self.id = id
        self.attempt = attempt
        let (stream, continuation) = AsyncStream.makeStream(of: TransferUpdate.self, bufferingPolicy: .bufferingNewest(8))
        self.updates = stream
        self.continuation = continuation
        self.log = Mutex([])
    }

    /// Records the priority change.
    public func setPriority(_ priority: AssetPriority) {
        self.log.withLock { $0.append(.setPriority(priority)) }
    }

    /// Records the pause and ends the stream with `.paused(resumable: true)`.
    public func pause() {
        self.log.withLock { $0.append(.pause) }
        self.continuation.yield(.paused(resumable: true))
        self.continuation.finish()
    }

    /// Records the cancellation and ends the stream with `.failed(.cancelled(.byClient))`.
    public func cancel() {
        self.log.withLock { $0.append(.cancel) }
        self.continuation.yield(.failed(.cancelled(.byClient)))
        self.continuation.finish()
    }

    /// Yields a scripted update; a terminal one ends the stream.
    public func deliver(_ update: TransferUpdate) {
        self.continuation.yield(update)
        if update.isTerminal {
            self.continuation.finish()
        }
    }

    /// Controls received, in order.
    public var controls: [TransferControl] {
        self.log.withLock { $0 }
    }
}

/// A source that writes through the store's staging sink once the engine has one (WP-H, WP-F, P-7).
///
/// The store's sink exists only after `AssetStore.open()`, which runs inside `SyncEngine.start()`; the only place
/// that sees it is `RemoteSourceFactory.makeRemoteSource(configuration:staging:)`. A fake source is built by the
/// test before that, so `FakeRemoteSourceFactory` hands the sink over through this protocol before returning the
/// source. Deliberately **not** availability-gated, so the factory's cast needs no `#available` and the package
/// keeps its single `#available` (R-APL-5).
public protocol StagingAttachable: Sendable {
    /// Receives the store's staging sink; a later call (a restarted client) replaces it.
    func attach(staging: any StagingSink) async
}

/// One scripted step of a fake transfer.
public enum FakeTransferStep: Sendable, Hashable {
    /// Report progress.
    case progress(Int64)
    /// Write these bytes through the attached staging sink (`createPartial`, then `appendPartial`) under the
    /// request's `partialName`, then report `.staged(StagedFile)` with their count; a sink error fails the
    /// transfer the way the transport would (`StagingError.insufficientSpace` → `.insufficientSpace`, otherwise
    /// `.transient(.localIO)`). Without an attached sink (`StagingAttachable`) the step fails with
    /// `.transient(.localIO)`, so a test that forgot the factory fails visibly instead of hanging.
    case stage(Data)
    /// Fail.
    case fail(TransferError)
    /// Wait until the test calls `release(_:with:)`.
    case hold
}

/// One scripted manifest response.
public enum FakeManifestResponse: Sendable, Hashable {
    /// 200 with bytes and an optional tag.
    case fetched(Data, etag: ETag?)
    /// 304.
    case notModified
    /// A failure.
    case fail(TransferError)
}

/// One recorded control, with the transfer it targeted.
public struct FakeControlRecord: Sendable, Hashable {
    /// The transfer.
    public var transfer: TransferID
    /// The control.
    public var control: TransferControl

    /// Creates a record.
    public init(transfer: TransferID, control: TransferControl) {
        self.transfer = transfer
        self.control = control
    }
}

/// The engine's network, scripted (R-NET-1; WP-H): starts, priority changes, pauses and cancellations are
/// recorded; `activeTransfers` is the census R-SYN-15 and P-14 assert on. Gated for `Mutex` (its handles).
///
/// Built by the test, handed to the engine by `FakeRemoteSourceFactory`, which attaches the open store's staging
/// sink first (`StagingAttachable`), so `.stage(Data)` writes real staging files the store then publishes.
@available(macOS 15.0, iOS 18.0, *)
public actor FakeRemoteSource: RemoteSource, StagingAttachable {
    /// The breaker key.
    public nonisolated let originID: String
    /// The capabilities reported.
    public nonisolated let capabilities: RemoteSourceCapabilities
    private var staging: (any StagingSink)?
    private var heldSourceCopyBytes: Int64 = 0

    /// Creates a source.
    public init(
        originID: String = "https://fake.example:443",
        capabilities: RemoteSourceCapabilities = RemoteSourceCapabilities(
            tier: .aws,
            supportsPriority: true,
            supportsResume: true,
            supportsBackground: false,
            keepsSourceCopies: false
        )
    ) {
        self.originID = originID
        self.capabilities = capabilities
    }

    /// Receives the store's staging sink (`FakeRemoteSourceFactory` calls it before returning this source).
    public func attach(staging: any StagingSink) {
        self.staging = staging
    }

    /// The sink `.stage(Data)` writes through; `nil` until attached.
    public var attachedStaging: (any StagingSink)? {
        self.staging
    }

    /// Sets what `sourceCopyBytes()` reports (an Apple-tier stand-in for R-CLN-9 and H-7 tests).
    public func setSourceCopyBytes(_ bytes: Int64) {
        self.heldSourceCopyBytes = bytes
    }

    /// Scripts the next attempts of `id`.
    public func script(_ id: TransferID, _ steps: [FakeTransferStep]) {
        fatalError("WP-H: FakeRemoteSource.script not implemented")
    }

    /// Scripts the next manifest responses.
    public func scriptManifest(_ responses: [FakeManifestResponse]) {
        fatalError("WP-H: FakeRemoteSource.scriptManifest not implemented")
    }

    /// Ends a `.hold` step with `update`.
    public func release(_ id: TransferID, with update: TransferUpdate) {
        fatalError("WP-H: FakeRemoteSource.release not implemented")
    }

    /// Requests started, in order.
    public var starts: [TransferRequest] {
        fatalError("WP-H: FakeRemoteSource.starts not implemented")
    }

    /// Controls received, in order across transfers.
    public var controlLog: [FakeControlRecord] {
        fatalError("WP-H: FakeRemoteSource.controlLog not implemented")
    }

    /// Transfers not yet terminal.
    public var activeTransfers: Int {
        fatalError("WP-H: FakeRemoteSource.activeTransfers not implemented")
    }

    /// Scripted manifest response.
    public func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        fatalError("WP-H: FakeRemoteSource.fetchManifest not implemented")
    }

    /// Scripted transfer.
    public func transfer(_ request: TransferRequest) async -> any TransferHandle {
        fatalError("WP-H: FakeRemoteSource.transfer not implemented")
    }

    /// Scripted re-attached transfers.
    public func reattachedTransfers() async -> [ReattachedTransfer] {
        fatalError("WP-H: FakeRemoteSource.reattachedTransfers not implemented")
    }

    /// Records the cancellation.
    public func cancelTransfer(_ name: StagingFileName) async {
        fatalError("WP-H: FakeRemoteSource.cancelTransfer not implemented")
    }

    /// Records the report.
    public func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        fatalError("WP-H: FakeRemoteSource.reclaimSourceCopies not implemented")
    }

    /// What `setSourceCopyBytes(_:)` set; 0 by default.
    public func sourceCopyBytes() async -> Int64 {
        self.heldSourceCopyBytes
    }

    /// Records the call.
    public func handleBackgroundEvents(identifier: String) async {
        fatalError("WP-H: FakeRemoteSource.handleBackgroundEvents not implemented")
    }

    /// Ends every transfer.
    public func invalidate() async {
        fatalError("WP-H: FakeRemoteSource.invalidate not implemented")
    }
}

/// A scripted `TransferBackend` for `HTTPRemoteSource` tests without URLSession (WP-H). Gated for `Mutex`.
@available(macOS 15.0, iOS 18.0, *)
public actor FakeTransferBackend: TransferBackend {
    /// The kind it pretends to be.
    public nonisolated let kind: TransferBackendKind

    /// Creates a backend.
    public init(kind: TransferBackendKind = .foreground) {
        self.kind = kind
    }

    /// Jobs started, in order.
    public var jobs: [TransferJob] {
        fatalError("WP-H: FakeTransferBackend.jobs not implemented")
    }

    /// Returns a scripted handle.
    public func start(_ job: TransferJob) async -> any TransferHandle {
        fatalError("WP-H: FakeTransferBackend.start not implemented")
    }

    /// Scripted live transfers.
    public func liveTransfers() async -> [LiveTransfer] {
        fatalError("WP-H: FakeTransferBackend.liveTransfers not implemented")
    }

    /// Records the cancellation.
    public func cancel(_ name: StagingFileName, keepingPartial: Bool) async {
        fatalError("WP-H: FakeTransferBackend.cancel not implemented")
    }

    /// Records the invalidation.
    public func invalidate() async {
        fatalError("WP-H: FakeTransferBackend.invalidate not implemented")
    }
}

/// An in-memory `StagingSink` for transport tests that do not need the store (WP-H). Gated for `Mutex`.
@available(macOS 15.0, iOS 18.0, *)
public final class FakeStagingSink: StagingSink {
    private let files: Mutex<[StagingFileName: Data]>

    /// Starts empty.
    public init() {
        self.files = Mutex([:])
    }

    /// Staged files by name.
    public var contents: [StagingFileName: Data] {
        self.files.withLock { $0 }
    }

    /// Creates or truncates.
    public func createPartial(_ name: StagingFileName) throws(StagingError) {
        self.files.withLock { $0[name] = Data() }
    }

    /// Appends.
    public func appendPartial(_ data: Data, to name: StagingFileName) throws(StagingError) -> Int64 {
        self.files.withLock { files in
            files[name, default: Data()].append(data)
            return Int64(files[name, default: Data()].count)
        }
    }

    /// Exclusive move.
    public func continuePartial(from previous: StagingFileName, as next: StagingFileName) throws(StagingError) -> Int64 {
        fatalError("WP-H: FakeStagingSink.continuePartial not implemented")
    }

    /// Adopts a file by reading it (tests only).
    public func adoptDownload(at location: URL, as name: StagingFileName) throws(StagingError) -> Int64 {
        fatalError("WP-H: FakeStagingSink.adoptDownload not implemented")
    }

    /// Records a sidecar.
    public func writeSidecar(_ sidecar: ResumeSidecar) {
        fatalError("WP-H: FakeStagingSink.writeSidecar not implemented")
    }

    /// Reads a sidecar.
    public func readSidecar(for name: StagingFileName) async -> ResumeSidecar? {
        fatalError("WP-H: FakeStagingSink.readSidecar not implemented")
    }

    /// Reads a staged file.
    public func readStaged(_ name: StagingFileName, maxBytes: Int64) async throws(StagingError) -> Data {
        fatalError("WP-H: FakeStagingSink.readStaged not implemented")
    }

    /// Removes a file.
    public func discard(_ name: StagingFileName) async {
        self.files.withLock { _ = $0.removeValue(forKey: name) }
    }

    /// Drains a chunk source.
    public func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError) -> Int64 {
        fatalError("WP-H: FakeStagingSink.writeStaged not implemented")
    }
}

/// Subscribes to an event stream and lets a test wait for a matching event without sleeping (WP-H).
public actor EventProbe {
    /// Starts consuming `stream` in one task owned by the probe; `stop()` ends it.
    public init(stream: AsyncStream<AssetEvent>) {
        _ = stream
    }

    /// Every event received so far.
    public var received: [AssetEvent] {
        fatalError("WP-H: EventProbe.received not implemented")
    }

    /// Suspends until an event matching `predicate` arrives (or returns one already received).
    public func next(where predicate: @escaping @Sendable (AssetEvent) -> Bool) async -> AssetEvent? {
        fatalError("WP-H: EventProbe.next not implemented")
    }

    /// Stops consuming.
    public func stop() {
        fatalError("WP-H: EventProbe.stop not implemented")
    }
}
