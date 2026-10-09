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

/// One entry of a fake transport's ordered log: a transfer start or a control on one of its handles
/// (R-NET-10, H-4, sync-1 S1-06).
public enum FakeTransportEvent: Sendable, Hashable {
    /// `FakeRemoteSource.transfer(_:)` started this request.
    case started(TransferRequest)
    /// A handle received a control.
    case controlled(FakeControlRecord)
}

/// The single ordered log a `FakeRemoteSource` shares with every handle it creates (contract-fix round 4).
///
/// Starts are recorded on the source's actor, controls synchronously on the handles (`TransferHandle`'s controls
/// are synchronous, ADR-021), so two separate logs cannot say whether a promoted asset's `setPriority` came before
/// the next start. One lock over one array gives every start and every control a place in a single sequence:
/// the H-4 test `R-NET-10: a promoted asset's priority change reaches the transport before any other transfer
/// starts` reads it directly. Gated for `Mutex` (ADR-014).
@available(macOS 15.0, iOS 18.0, *)
public final class FakeTransportLog: Sendable {
    private let entries: Mutex<[FakeTransportEvent]>

    /// Starts empty.
    public init() {
        self.entries = Mutex([])
    }

    /// Appends one event; the lock defines the global order.
    public func record(_ event: FakeTransportEvent) {
        self.entries.withLock { $0.append(event) }
    }

    /// Every event so far, in the order recorded.
    public var events: [FakeTransportEvent] {
        self.entries.withLock { $0 }
    }
}

/// A transfer handle driven by the test (R-SYN-3, R-SYN-4, R-NET-10 tests): every control is recorded in call
/// order under a lock and, when the handle was made with a `FakeTransportLog`, also in that shared log, so the
/// order of `setPriority` relative to other starts is observable (sync-1 S1-06). `cancel()` and `pause()` end the
/// stream with their terminal element; `deliver` yields what the test scripts. Gated for `Mutex` (ADR-014).
///
/// As the Model's `TransferHandle` requires, terminating `updates` before its terminal element cancels the transfer:
/// when the consuming task is cancelled, or when the stream is dropped (the handle and every iterator released), the
/// handle records `.cancel` once, exactly as `cancel()` would, so `FakeRemoteSource` stops that attempt and drops it
/// from `activeTransfers`. The end of a stream that delivered its terminal element is not a cancellation. What the
/// test (or `FakeRemoteSource`) drives is the handle's channel, which never holds the stream: a source that parks an
/// attempt keeps only the channel, so releasing the handle really drops the stream.
@available(macOS 15.0, iOS 18.0, *)
public final class FakeTransferHandle: TransferHandle {
    /// The content.
    public let id: TransferID
    /// The attempt.
    public let attempt: TransferAttempt
    /// The update stream.
    public let updates: AsyncStream<TransferUpdate>
    /// The shared log every control is also recorded in; `nil` for a stand-alone handle.
    public let transportLog: FakeTransportLog?
    /// Where controls are recorded and updates yielded; `FakeRemoteSource` keeps this, never the handle.
    let channel: FakeTransferChannel

    /// Creates a handle; `FakeRemoteSource` passes its `transportLog`.
    public init(id: TransferID, attempt: TransferAttempt, transportLog: FakeTransportLog? = nil) {
        self.id = id
        self.attempt = attempt
        let (stream, continuation) = AsyncStream.makeStream(of: TransferUpdate.self, bufferingPolicy: .bufferingNewest(8))
        self.updates = stream
        self.transportLog = transportLog
        let channel = FakeTransferChannel(id: id, continuation: continuation, transportLog: transportLog)
        self.channel = channel
        // The handler holds the channel, not the handle: the channel holds no stream, and `AsyncStream` drops the
        // handler once it ran, so nothing is kept alive after the stream ended.
        continuation.onTermination = { termination in
            // `.finished` comes from the channel's `end(with:)`, which holds its lock while it finishes: never take
            // the lock for it.
            guard case .cancelled = termination else {
                return
            }
            channel.consumerTerminated()
        }
    }

    /// Records the priority change.
    public func setPriority(_ priority: AssetPriority) {
        self.channel.record(.setPriority(priority))
    }

    /// Sets what a later `pause()` reports as `.paused(resumable:)`: whether the transfer kept a partial plus a
    /// validator (the Model's meaning). `true` until set, so a stand-alone handle (`FakeTransferBackend`'s) stands
    /// for a transfer that kept both unless the test says otherwise; `FakeRemoteSource` sets it per attempt.
    public func setPauseResumable(_ resumable: Bool) {
        self.channel.setPauseResumable(resumable)
    }

    /// Records the pause and ends the stream with `.paused(resumable:)` (unless it already ended): `true` unless
    /// `setPauseResumable(false)` said no partial plus validator was kept.
    public func pause() {
        self.channel.pause()
    }

    /// Records the cancellation and ends the stream with `.failed(.cancelled(.byClient))` (unless it already ended).
    public func cancel() {
        self.channel.cancel()
    }

    /// Yields a scripted update; a terminal one ends the stream. Dropped once the stream ended.
    public func deliver(_ update: TransferUpdate) {
        self.channel.deliver(update)
    }

    /// Controls received, in order.
    public var controls: [TransferControl] {
        self.channel.controls
    }
}

/// The driving side of a `FakeTransferHandle`: its control log, its terminal decision and its continuation, without
/// the stream (so whoever keeps a channel never keeps the stream alive). Gated for `Mutex` (ADR-014).
@available(macOS 15.0, iOS 18.0, *)
final class FakeTransferChannel: Sendable {
    /// The transfer the controls are recorded for.
    let id: TransferID
    /// The shared log every control is also recorded in; `nil` for a stand-alone handle.
    let transportLog: FakeTransportLog?
    private let continuation: AsyncStream<TransferUpdate>.Continuation
    private let log: Mutex<[TransferControl]>
    /// Whether the stream ended (a terminal update was yielded, or the consumer terminated it): decided under this
    /// lock, so a scripted delivery racing a `cancel()` or `pause()` on another thread ends the stream with exactly
    /// one terminal element.
    private let terminated: Mutex<Bool>
    /// What `pause()` reports as `.paused(resumable:)`.
    private let pauseResumable: Mutex<Bool>

    /// Creates the channel of one handle.
    init(id: TransferID, continuation: AsyncStream<TransferUpdate>.Continuation, transportLog: FakeTransportLog?) {
        self.id = id
        self.continuation = continuation
        self.transportLog = transportLog
        self.log = Mutex([])
        self.terminated = Mutex(false)
        self.pauseResumable = Mutex(true)
    }

    /// Sets what `pause()` reports.
    func setPauseResumable(_ resumable: Bool) {
        self.pauseResumable.withLock { $0 = resumable }
    }

    /// Records the pause and ends the stream with `.paused(resumable:)`.
    func pause() {
        self.record(.pause)
        self.end(with: .paused(resumable: self.pauseResumable.withLock { $0 }))
    }

    /// Records the cancellation and ends the stream with `.failed(.cancelled(.byClient))`.
    func cancel() {
        self.record(.cancel)
        self.end(with: .failed(.cancelled(.byClient)))
    }

    /// The stream's consumer ended it before its terminal element (cancelled, or dropped with the handle): the
    /// transfer is cancelled, recorded once as a `.cancel` control. Nothing is yielded: the stream already ended.
    func consumerTerminated() {
        let first = self.terminated.withLock { ended -> Bool in
            defer { ended = true }
            return !ended
        }
        if first {
            self.record(.cancel)
        }
    }

    /// Yields a scripted update; a terminal one ends the stream. Dropped once the stream ended.
    func deliver(_ update: TransferUpdate) {
        guard !update.isTerminal else {
            self.end(with: update)
            return
        }
        self.terminated.withLock { ended in
            if !ended {
                self.continuation.yield(update)
            }
        }
    }

    /// Controls received, in order.
    var controls: [TransferControl] {
        self.log.withLock { $0 }
    }

    /// Whether the engine stopped the transfer: paused or cancelled it, or terminated its stream.
    var isStopped: Bool {
        self.controls.contains { $0 == .pause || $0 == .cancel }
    }

    /// Appends `control` to this channel's log and to the shared log.
    func record(_ control: TransferControl) {
        self.log.withLock { $0.append(control) }
        self.transportLog?.record(.controlled(FakeControlRecord(transfer: self.id, control: control)))
    }

    /// Yields `update` and finishes the stream, unless the stream already ended. Yielding and finishing under the
    /// lock is safe: the `onTermination` handler `finish()` runs ignores `.finished` and takes no lock for it.
    private func end(with update: TransferUpdate) {
        self.terminated.withLock { ended in
            guard !ended else {
                return
            }
            ended = true
            self.continuation.yield(update)
            self.continuation.finish()
        }
    }
}

/// A source that writes through the store's staging sink once the engine has one (WP-H, WP-F, P-7).
///
/// The store's sink exists only after `AssetStore.open()`, which runs inside `SyncEngine.start()`; the only place
/// that sees it is `RemoteSourceFactory.makeRemoteSource(configuration:staging:log:)`. A fake source is built by the
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
    /// Write these bytes (a `Data` slice stages its own bytes, whatever its `startIndex`) through the attached staging
    /// sink (`createPartial`, then `appendPartial`) under the request's `partialName`, then report
    /// `.staged(StagedFile)` with their count (`httpStatus` 206 for a resumed request on the AWS tier, else 200;
    /// `nil` on the Apple tier); a sink error fails the
    /// transfer the way the transport would (`StagingError.insufficientSpace` → `.insufficientSpace`, otherwise
    /// `.transient(.localIO)`). Without an attached sink (`StagingAttachable`) the step fails with
    /// `.transient(.localIO)`, so a test that forgot the factory fails visibly instead of hanging.
    case stage(Data)
    /// Write `byteCount` bytes of `GeneratedPayload` for `seed` through the attached staging sink in chunks of
    /// `GeneratedPayload.chunkBytes` (`createPartial`, then one `appendPartial` per chunk, each chunk generated just
    /// before it is written), then report `.staged(StagedFile)`; failures as for `.stage(Data)`. The payload is never
    /// held in memory as a whole, so P-7's catalog does not sit in RAM. The source's `transportLog` still grows by one
    /// `TransferRequest` per start (a few hundred bytes, whatever the payload size), so a P-7 run that compares
    /// catalog sizes either uses a fresh source per size or counts that growth as the fake's. The manifest checksum
    /// of such an entry is `GeneratedPayload.sha256(seed:byteCount:)`.
    case stageGenerated(seed: UInt64, byteCount: Int64)
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
/// recorded in one ordered `transportLog`; `activeTransfers` is the census R-SYN-15 and P-14 assert on. Gated for
/// `Mutex` (its handles).
///
/// Built by the test, handed to the engine by `FakeRemoteSourceFactory`, which attaches the open store's staging
/// sink first (`StagingAttachable`), so `.stage(Data)` writes real staging files the store then publishes.
///
/// Scripting, precisely: each transfer id has one queue of steps (`script(_:_:)` appends). An attempt consumes
/// steps from its id's queue, in order, until a terminal step (`.stage`, `.stageGenerated`, `.fail`) or a `.hold`;
/// the rest of the queue belongs to later attempts, so `[.fail(…), .stage(…)]` scripts a failed attempt and a
/// successful retry. Steps run synchronously inside `transfer(_:)` (staging writes included), so an attempt that is
/// not held has finished before its handle is returned and the outcome never depends on scheduling. An attempt that
/// reaches a `.hold`, or the end of its queue, stays active: `release(_:with:)` ends the oldest such attempt of the
/// id (a release with no held attempt is kept for the next hold of that id, so a test never races the engine), and
/// `script(_:_:)` wakes an attempt that ran out of steps (not one at an explicit `.hold`). A non-terminal release
/// lets the attempt continue with its queue. `pause()` or `cancel()` on a handle ends that attempt, and so does
/// terminating its `updates` stream (the consuming task cancelled, or the handle dropped: the source keeps only the
/// handle's channel); its remaining steps go to the next attempt. `pause()` reports `resumable: true` only for an
/// attempt that continues an earlier partial (`request.resume`). An unscripted manifest fetch answers 304 (the origin
/// has nothing new). `invalidate()` (the engine's shutdown) fails every active and later transfer until a restarted
/// client attaches again (`attach(staging:)`), so one source serves several client lifetimes, as the factory's
/// relaunch scenarios need.
///
/// Cost of synchronous staging: a whole attempt's writes run in one turn of this actor, on the cooperative pool. Over
/// a live sink (P-7's real files) keep each scripted asset to a few MiB (about 8 MiB is ~10 ms of writing, C2's
/// stretch); a larger catalog is many assets, not one large one. Over a `FakeFileSystem` the writes are numbered
/// mutations of that fake, so a crash-enumeration scenario must not run transfers concurrently with other store
/// work: the interleaving, and so the crash-point numbering, would then depend on scheduling.
@available(macOS 15.0, iOS 18.0, *)
public actor FakeRemoteSource: RemoteSource, StagingAttachable {
    /// The breaker key.
    public nonisolated let originID: String
    /// The capabilities reported.
    public nonisolated let capabilities: RemoteSourceCapabilities
    /// Starts and controls in one sequence (R-NET-10, H-4): `transfer(_:)` records `.started(request)` here and
    /// creates its handle with this log before returning it, so a control on any handle and every later start are
    /// totally ordered. `starts` and `controlLog` are projections of it.
    public nonisolated let transportLog = FakeTransportLog()
    private var staging: (any StagingSink)?
    private var heldSourceCopyBytes: Int64 = 0
    private var steps: [TransferID: [FakeTransferStep]] = [:]
    private var earlyReleases: [TransferID: [TransferUpdate]] = [:]
    private var waiting: [WaitingAttempt] = []
    private var manifestScript: [FakeManifestResponse] = []
    private var manifestLog: [ManifestRequest] = []
    private var reattachScript: [ReattachedTransfer] = []
    private var cancelled: [StagingFileName] = []
    private var reclaims: [AdoptionReport] = []
    private var backgroundEvents: [String] = []
    private var invalidated = false

    /// An attempt that is active but not running: at an explicit `.hold`, or out of scripted steps. It keeps the
    /// handle's channel, never the handle, so an engine that drops the handle drops its stream, which cancels the
    /// attempt (the Model's `TransferHandle`).
    private struct WaitingAttempt {
        let request: TransferRequest
        let channel: FakeTransferChannel
        let atHold: Bool
    }

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

    /// Receives the store's staging sink (`FakeRemoteSourceFactory` calls it before returning this source). An
    /// attach after `invalidate()` is a restarted client (`StagingAttachable`) taking the source over: it transfers
    /// again, through the new sink. `isInvalidated` and the starts recorded after the shutdown stay observable until
    /// that attach; scripted steps, manifests and re-attached transfers carry over to the new client.
    public func attach(staging: any StagingSink) {
        self.staging = staging
        self.invalidated = false
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
        self.steps[id, default: []].append(contentsOf: steps)
        self.dropStopped()
        while !(self.steps[id] ?? []).isEmpty,
            let index = self.waiting.firstIndex(where: { $0.request.id == id && !$0.atHold })
        {
            let attempt = self.waiting.remove(at: index)
            self.run(attempt.request, attempt.channel)
        }
    }

    /// Scripts the next manifest responses.
    public func scriptManifest(_ responses: [FakeManifestResponse]) {
        self.manifestScript.append(contentsOf: responses)
    }

    /// Scripts what `reattachedTransfers()` returns: the transfers an "earlier process" left live in the OS or
    /// completed into staging (H-6; R-NET-3 adoption from staging, R-CLN-3 survival through launch GC). A test puts
    /// the completed ones' files into staging itself (through the store's sink) before `start()`; each call
    /// replaces the script, and `reattachedTransfers()` returns it once, then `[]` (one launch, ADR-028).
    public func scriptReattached(_ transfers: [ReattachedTransfer]) {
        self.reattachScript = transfers
    }

    /// Ends a `.hold` step with `update`.
    public func release(_ id: TransferID, with update: TransferUpdate) {
        self.dropStopped()
        guard let index = self.waiting.firstIndex(where: { $0.request.id == id }) else {
            self.earlyReleases[id, default: []].append(update)
            return
        }
        let attempt = self.waiting.remove(at: index)
        attempt.channel.deliver(update)
        if !update.isTerminal {
            self.run(attempt.request, attempt.channel)
        }
    }

    /// Requests started, in order (the `.started` entries of `transportLog`).
    public var starts: [TransferRequest] {
        self.transportLog.events.compactMap { event in
            guard case .started(let request) = event else {
                return nil
            }
            return request
        }
    }

    /// Controls received, in order across transfers (the `.controlled` entries of `transportLog`).
    public var controlLog: [FakeControlRecord] {
        self.transportLog.events.compactMap { event in
            guard case .controlled(let record) = event else {
                return nil
            }
            return record
        }
    }

    /// Manifest requests received, in order.
    public var manifestRequests: [ManifestRequest] {
        self.manifestLog
    }

    /// Names passed to `cancelTransfer(_:)`, in order.
    public var cancelledTransfers: [StagingFileName] {
        self.cancelled
    }

    /// Reports passed to `reclaimSourceCopies(_:)`, in order.
    public var reclaimReports: [AdoptionReport] {
        self.reclaims
    }

    /// Identifiers passed to `handleBackgroundEvents(identifier:)`, in order.
    public var backgroundEventIdentifiers: [String] {
        self.backgroundEvents
    }

    /// Whether `invalidate()` ran since the last `attach(staging:)`.
    public var isInvalidated: Bool {
        self.invalidated
    }

    /// Transfers not yet terminal. Reading it drops the parked attempts the engine paused or cancelled (through the
    /// handle, or by terminating its stream).
    public var activeTransfers: Int {
        self.dropStopped()
        return self.waiting.count
    }

    /// Parked attempts the source still holds, dead ones included (the fake's own growth tests).
    var parkedAttempts: Int {
        self.waiting.count
    }

    /// Scripted manifest response.
    public func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        self.manifestLog.append(request)
        guard !self.manifestScript.isEmpty else {
            return .notModified(removedSources: [])
        }
        switch self.manifestScript.removeFirst() {
        case .fetched(let bytes, let etag):
            let origin: ManifestOrigin = self.capabilities.tier == .aws ? .network : .installedPack(updateChecked: true)
            return .fetched(ManifestPayload(bytes: bytes, etag: etag, origin: origin))
        case .notModified:
            return .notModified(removedSources: [])
        case .fail(let error):
            throw error
        }
    }

    /// Scripted transfer: records `.started(request)` in `transportLog`, then returns a `FakeTransferHandle` made
    /// with `transportLog`. Its `pause()` reports `.paused(resumable: true)` only for a request that continues an
    /// earlier partial (`request.resume`, which carries the validator): an attempt of this fake writes nothing before
    /// its terminal step, so a fresh attempt paused while parked kept no partial.
    public func transfer(_ request: TransferRequest) async -> any TransferHandle {
        self.dropStopped()
        self.transportLog.record(.started(request))
        let handle = FakeTransferHandle(id: request.id, attempt: request.attempt, transportLog: self.transportLog)
        handle.setPauseResumable(request.resume != nil)
        if self.invalidated {
            handle.deliver(.failed(.cancelled(.byClient)))
        } else {
            self.run(request, handle.channel)
        }
        return handle
    }

    /// What `scriptReattached(_:)` set, once; `[]` otherwise.
    public func reattachedTransfers() async -> [ReattachedTransfer] {
        defer { self.reattachScript = [] }
        return self.reattachScript
    }

    /// Records the cancellation.
    public func cancelTransfer(_ name: StagingFileName) async {
        self.cancelled.append(name)
    }

    /// Records the report.
    public func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        self.reclaims.append(report)
        return ReclaimReport()
    }

    /// What `setSourceCopyBytes(_:)` set; 0 by default.
    public func sourceCopyBytes() async -> Int64 {
        self.heldSourceCopyBytes
    }

    /// Records the call.
    public func handleBackgroundEvents(identifier: String) async {
        self.backgroundEvents.append(identifier)
    }

    /// Ends every transfer, and fails every later one at once until a restarted client attaches (`attach(staging:)`).
    public func invalidate() async {
        self.invalidated = true
        for attempt in self.waiting where !attempt.channel.isStopped {
            attempt.channel.deliver(.failed(.cancelled(.byClient)))
        }
        self.waiting.removeAll()
        self.earlyReleases.removeAll()
    }

    // MARK: Attempts

    /// Runs one attempt's steps until it ends, or parks it at a hold or at the end of its queue.
    private func run(_ request: TransferRequest, _ channel: FakeTransferChannel) {
        while !channel.isStopped {
            guard var queue = self.steps[request.id], !queue.isEmpty else {
                switch self.takeEarlyRelease(request, channel) {
                case .continued:
                    continue
                case .ended:
                    return
                case .none:
                    self.waiting.append(WaitingAttempt(request: request, channel: channel, atHold: false))
                    return
                }
            }
            let step = queue.removeFirst()
            self.steps[request.id] = queue.isEmpty ? nil : queue
            switch step {
            case .progress(let received):
                channel.deliver(.progress(received: received, expected: request.expectedBytes))
            case .stage(let data):
                // A `Data` slice keeps its parent's indices: offsets count from the slice's own `startIndex`.
                channel.deliver(self.stage(request, total: Int64(data.count), chunkBytes: max(1, data.count)) { offset, length in
                    let from = data.startIndex + Int(offset)
                    return data.subdata(in: from..<(from + length))
                })
                return
            case .stageGenerated(let seed, let byteCount):
                channel.deliver(self.stage(request, total: max(0, byteCount), chunkBytes: GeneratedPayload.chunkBytes) { offset, length in
                    GeneratedPayload.bytes(seed: seed, offset: offset, length: length)
                })
                return
            case .fail(let error):
                channel.deliver(.failed(error))
                return
            case .hold:
                switch self.takeEarlyRelease(request, channel) {
                case .continued:
                    continue
                case .ended:
                    return
                case .none:
                    self.waiting.append(WaitingAttempt(request: request, channel: channel, atHold: true))
                    return
                }
            }
        }
    }

    /// What a release kept for an attempt's id did to it.
    private enum EarlyRelease {
        /// None was kept: the attempt waits.
        case none
        /// A progress update was delivered: the attempt continues with its queue.
        case continued
        /// A terminal update was delivered: the attempt is over.
        case ended
    }

    /// Delivers the oldest release that arrived for `request.id` before any attempt of it waited.
    private func takeEarlyRelease(_ request: TransferRequest, _ channel: FakeTransferChannel) -> EarlyRelease {
        guard var queue = self.earlyReleases[request.id], !queue.isEmpty else {
            return .none
        }
        let update = queue.removeFirst()
        self.earlyReleases[request.id] = queue.isEmpty ? nil : queue
        channel.deliver(update)
        return update.isTerminal ? .ended : .continued
    }

    /// Writes `total` bytes through the attached sink (continuing `request.resume` when set) in chunks of at most
    /// `chunkBytes`, each produced just before it is written, and maps the outcome as the transport would.
    private func stage(_ request: TransferRequest, total: Int64, chunkBytes: Int, bytes: (Int64, Int) -> Data) -> TransferUpdate {
        guard let sink = self.staging else {
            return .failed(.transient(.localIO(posixCode: ENXIO), retryAfter: nil))
        }
        let name = request.partialName
        do throws(StagingError) {
            var size: Int64 = 0
            if let resume = request.resume {
                size = try sink.continuePartial(from: resume.previous, as: name)
            } else {
                try sink.createPartial(name)
            }
            var offset = min(size, total)
            while offset < total {
                let length = Int(min(Int64(chunkBytes), total - offset))
                size = try sink.appendPartial(bytes(offset, length), to: name)
                offset += Int64(length)
            }
            // The real transport's final status: 206 for a resumed range request, 200 for a whole body.
            let status: Int? = self.capabilities.tier == .aws ? (request.resume != nil ? 206 : 200) : nil
            return .staged(StagedFile(name: name, byteCount: size, resumed: request.resume != nil, httpStatus: status, etag: nil))
        } catch {
            return .failed(FakeRemoteSource.transferError(error))
        }
    }

    /// Drops parked attempts the engine paused or cancelled. Runs at every interaction that reads or adds parked
    /// attempts (`transfer`, `script`, `release`, `activeTransfers`), so an engine that stops many attempts and never
    /// scripts or releases does not keep them (each with its channel and request) for the source's lifetime.
    private func dropStopped() {
        self.waiting.removeAll { $0.channel.isStopped }
    }

    /// The transport's mapping of a staging failure (`StagingSink` doc): ENOSPC is `insufficientSpace`, anything else
    /// a local I/O failure.
    private static func transferError(_ error: StagingError) -> TransferError {
        switch error {
        case .insufficientSpace:
            return .insufficientSpace(requiredBytes: nil)
        case .io(let code):
            return .transient(.localIO(posixCode: code), retryAfter: nil)
        case .tooLarge:
            return .transient(.localIO(posixCode: EFBIG), retryAfter: nil)
        case .source:
            return .transient(.localIO(posixCode: EIO), retryAfter: nil)
        case .nameInUse:
            return .transient(.localIO(posixCode: EEXIST), retryAfter: nil)
        }
    }
}

/// A scripted `TransferBackend` for `HTTPRemoteSource` tests without URLSession (WP-H). Gated for `Mutex`.
///
/// Every `start` returns a fresh `FakeTransferHandle` (reachable through `handles`, in start order) that the test
/// drives with `deliver(_:)`; `liveTransfers()` reports what `scriptLiveTransfers(_:)` set, minus names cancelled
/// since; `invalidate()` fails every handle with `.cancelled(.byClient)`, as `invalidateAndCancel()` would.
@available(macOS 15.0, iOS 18.0, *)
public actor FakeTransferBackend: TransferBackend {
    /// The kind it pretends to be.
    public nonisolated let kind: TransferBackendKind
    private var started: [TransferJob] = []
    private var made: [FakeTransferHandle] = []
    private var live: [LiveTransfer] = []
    private var cancels: [FakeBackendCancellation] = []
    private var invalidateCount = 0

    /// Creates a backend.
    public init(kind: TransferBackendKind = .foreground) {
        self.kind = kind
    }

    /// Jobs started, in order.
    public var jobs: [TransferJob] {
        self.started
    }

    /// Handles returned by `start(_:)`, in order.
    public var handles: [FakeTransferHandle] {
        self.made
    }

    /// Scripts what `liveTransfers()` reports.
    public func scriptLiveTransfers(_ transfers: [LiveTransfer]) {
        self.live = transfers
    }

    /// Cancellations received, in order.
    public var cancellations: [FakeBackendCancellation] {
        self.cancels
    }

    /// How often `invalidate()` ran.
    public var invalidations: Int {
        self.invalidateCount
    }

    /// Returns a scripted handle.
    public func start(_ job: TransferJob) async -> any TransferHandle {
        self.started.append(job)
        let handle = FakeTransferHandle(id: job.id, attempt: job.attempt)
        self.made.append(handle)
        return handle
    }

    /// Scripted live transfers.
    public func liveTransfers() async -> [LiveTransfer] {
        self.live
    }

    /// Records the cancellation.
    public func cancel(_ name: StagingFileName, keepingPartial: Bool) async {
        self.cancels.append(FakeBackendCancellation(name: name, keepingPartial: keepingPartial))
        self.live.removeAll { $0.name == name }
    }

    /// Records the invalidation.
    public func invalidate() async {
        self.invalidateCount += 1
        for handle in self.made {
            handle.deliver(.failed(.cancelled(.byClient)))
        }
    }
}

/// One `FakeTransferBackend.cancel(_:keepingPartial:)` call.
public struct FakeBackendCancellation: Sendable, Hashable {
    /// The staging name.
    public var name: StagingFileName
    /// Whether the partial was to be kept.
    public var keepingPartial: Bool

    /// Creates a record.
    public init(name: StagingFileName, keepingPartial: Bool) {
        self.name = name
        self.keepingPartial = keepingPartial
    }
}

/// The `FakeStagingSink` operations a test can make fail once.
public enum FakeStagingOperation: Sendable, Hashable, CaseIterable {
    /// `createPartial`.
    case createPartial
    /// `appendPartial`.
    case appendPartial
    /// `continuePartial`.
    case continuePartial
    /// `adoptDownload`.
    case adoptDownload
    /// `readStaged`.
    case readStaged
    /// `writeStaged`.
    case writeStaged
}

/// An in-memory `StagingSink` for transport tests that do not need the store (WP-H). Gated for `Mutex`.
///
/// Semantics mirror the store's sink where transport behaviour depends on them: `continuePartial`, `adoptDownload`
/// and `writeStaged` never replace a name (`.nameInUse`), a missing source is `.io(posixCode: ENOENT)`,
/// `readStaged` and `writeStaged` refuse more than `maxBytes` (`.tooLarge`, nothing kept), and `discard` removes the
/// file and its sidecar. `failNext(_:with:)` injects one failure (ENOSPC on an append, for example).
@available(macOS 15.0, iOS 18.0, *)
public final class FakeStagingSink: StagingSink {
    private let files: Mutex<[StagingFileName: Data]>
    private let sidecarStore: Mutex<[StagingFileName: ResumeSidecar]>
    private let faults: Mutex<[FakeStagingOperation: [StagingError]]>

    /// Starts empty.
    public init() {
        self.files = Mutex([:])
        self.sidecarStore = Mutex([:])
        self.faults = Mutex([:])
    }

    /// Staged files by name.
    public var contents: [StagingFileName: Data] {
        self.files.withLock { $0 }
    }

    /// Sidecars by the partial they describe.
    public var sidecars: [StagingFileName: ResumeSidecar] {
        self.sidecarStore.withLock { $0 }
    }

    /// Makes the next call of `operation` throw `error`.
    public func failNext(_ operation: FakeStagingOperation, with error: StagingError) {
        self.faults.withLock { $0[operation, default: []].append(error) }
    }

    /// Creates or truncates.
    public func createPartial(_ name: StagingFileName) throws(StagingError) {
        try self.injected(.createPartial)
        self.files.withLock { $0[name] = Data() }
    }

    /// Appends.
    public func appendPartial(_ data: Data, to name: StagingFileName) throws(StagingError) -> Int64 {
        try self.injected(.appendPartial)
        return self.files.withLock { files in
            files[name, default: Data()].append(data)
            return Int64(files[name, default: Data()].count)
        }
    }

    /// Exclusive move.
    public func continuePartial(from previous: StagingFileName, as next: StagingFileName) throws(StagingError) -> Int64 {
        try self.injected(.continuePartial)
        return try self.files.withLock { files throws(StagingError) -> Int64 in
            guard files[next] == nil else {
                throw .nameInUse
            }
            guard let data = files.removeValue(forKey: previous) else {
                throw .io(posixCode: ENOENT)
            }
            files[next] = data
            return Int64(data.count)
        }
    }

    /// Adopts a file by reading it (tests only).
    public func adoptDownload(at location: URL, as name: StagingFileName) throws(StagingError) -> Int64 {
        try self.injected(.adoptDownload)
        guard self.files.withLock({ $0[name] == nil }) else {
            throw .nameInUse
        }
        guard let data = try? Data(contentsOf: location) else {
            throw .io(posixCode: ENOENT)
        }
        return try self.files.withLock { files throws(StagingError) -> Int64 in
            guard files[name] == nil else {
                throw .nameInUse
            }
            files[name] = data
            return Int64(data.count)
        }
    }

    /// Records a sidecar.
    public func writeSidecar(_ sidecar: ResumeSidecar) {
        self.sidecarStore.withLock { $0[sidecar.name] = sidecar }
    }

    /// Reads a sidecar.
    public func readSidecar(for name: StagingFileName) async -> ResumeSidecar? {
        self.sidecarStore.withLock { $0[name] }
    }

    /// Reads a staged file.
    public func readStaged(_ name: StagingFileName, maxBytes: Int64) async throws(StagingError) -> Data {
        try self.injected(.readStaged)
        guard let data = self.files.withLock({ $0[name] }) else {
            throw .io(posixCode: ENOENT)
        }
        guard Int64(data.count) <= maxBytes else {
            throw .tooLarge(limit: maxBytes)
        }
        return data
    }

    /// Removes a file.
    public func discard(_ name: StagingFileName) async {
        self.files.withLock { _ = $0.removeValue(forKey: name) }
        self.sidecarStore.withLock { _ = $0.removeValue(forKey: name) }
    }

    /// Drains a chunk source.
    public func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError) -> Int64 {
        try self.injected(.writeStaged)
        guard self.files.withLock({ $0[name] == nil }) else {
            throw .nameInUse
        }
        var data = Data()
        while let chunk = try source.nextChunk(maxBytes: 1 << 20) {
            data.append(chunk)
            guard Int64(data.count) <= maxBytes else {
                throw .tooLarge(limit: maxBytes)
            }
        }
        let written = data
        return try self.files.withLock { files throws(StagingError) -> Int64 in
            guard files[name] == nil else {
                throw .nameInUse
            }
            files[name] = written
            return Int64(written.count)
        }
    }

    /// Throws the failure injected for `operation`, once.
    private func injected(_ operation: FakeStagingOperation) throws(StagingError) {
        let failure = self.faults.withLock { faults -> StagingError? in
            guard var queue = faults[operation], !queue.isEmpty else {
                return nil
            }
            let first = queue.removeFirst()
            faults[operation] = queue.isEmpty ? nil : queue
            return first
        }
        if let failure {
            throw failure
        }
    }
}

/// Subscribes to an event stream and lets a test wait for a matching event without sleeping (WP-H).
///
/// One task, owned by the probe, consumes the stream in order. `next(where:)` returns the earliest received event
/// that matches and that no earlier call returned, or suspends until one arrives; it returns `nil` once the stream
/// finished (or `stop()` ran) without a match, and when the calling task is cancelled. Each event is returned by at
/// most one call. `stop()` cancels the consuming task, which terminates the stream's iteration (an engine
/// subscription is released on that cancellation).
public actor EventProbe: CensusWaiting {
    private var events: [AssetEvent] = []
    private var consumed: Set<Int> = []
    private var waiters: [Waiter] = []
    private var nextWaiter: UInt64 = 0
    private var finished = false
    /// Waits for a number of suspended `next(where:)` calls (`CensusWaiting`).
    var censusWaiters = CensusWaiters()
    private let stopSignal: AsyncStream<Void>.Continuation

    /// A suspended `next(where:)` call.
    private struct Waiter {
        let id: UInt64
        let predicate: @Sendable (AssetEvent) -> Bool
        let continuation: CheckedContinuation<AssetEvent?, Never>
    }

    /// Starts consuming `stream` in one task owned by the probe; `stop()` ends it.
    public init(stream: AsyncStream<AssetEvent>) {
        let (signal, stopSignal) = AsyncStream.makeStream(of: Void.self)
        self.stopSignal = stopSignal
        Task { [weak self] in
            // REENTRANCY: h-2 (proposed) — nothing: this task is not the actor; the group ends when the stream ends
            // or `stop()` signals, and `finish()` re-reads the waiter table on the actor.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await event in stream {
                        guard let self else {
                            return
                        }
                        // REENTRANCY: h-2 (proposed) — nothing: `receive` appends on the actor in stream order.
                        await self.receive(event)
                    }
                }
                group.addTask {
                    // REENTRANCY: h-2 (proposed) — nothing: waits only for `stop()` to finish the signal stream.
                    for await _ in signal {}
                }
                // REENTRANCY: h-2 (proposed) — nothing: whichever child ends first cancels the other.
                await group.next()
                group.cancelAll()
            }
            // REENTRANCY: h-2 (proposed) — nothing: `finish()` is idempotent.
            await self?.finish()
        }
    }

    /// A probe released without `stop()` still ends its consumer, so the subscription it holds is released.
    deinit {
        self.stopSignal.finish()
    }

    /// Every event received so far (kept for the probe's lifetime: `next` scans it, so a probe is meant for one
    /// test's events, not for an unbounded stream).
    public var received: [AssetEvent] {
        self.events
    }

    /// Suspends until an event matching `predicate` arrives (or returns one already received).
    public func next(where predicate: @escaping @Sendable (AssetEvent) -> Bool) async -> AssetEvent? {
        if let index = self.events.indices.first(where: { !self.consumed.contains($0) && predicate(self.events[$0]) }) {
            self.consumed.insert(index)
            return self.events[index]
        }
        guard !self.finished, !Task.isCancelled else {
            return nil
        }
        self.nextWaiter += 1
        let id = self.nextWaiter
        // REENTRANCY: h-1 (proposed) — nothing: a terminal wait. The waiter is registered synchronously in the
        // continuation body and resumed only by its removal from `waiters` (a matching event, finish, stop or this
        // task's cancellation); no state is read afterwards.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AssetEvent?, Never>) in
                self.waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
                self.notifyCountWaiters()
            }
        } onCancel: {
            Task {
                // REENTRANCY: h-3 (proposed) — nothing: this task is not the actor; `cancelWaiter` re-reads the
                // table and is a no-op for a waiter an event already resumed.
                await self.cancelWaiter(id)
            }
        }
    }

    /// Suspends until at least `count` calls of `next(where:)` are waiting (tests of the probe itself); `false`
    /// when the probe finished first (no call can wait any more) or the calling task was cancelled first (L2
    /// follow-up).
    @discardableResult
    func waitForWaiters(atLeast count: Int) async -> Bool {
        if self.waiters.count >= count {
            return true
        }
        guard !self.finished else {
            return false
        }
        // REENTRANCY: h-4 (proposed, as TS2) — nothing: a terminal wait (l2fu-1), resumed by the actor turn in which
        // `count` calls were waiting, by `finish()`, or by the caller's cancellation; no state is read afterwards.
        return await self.awaitCensus(target: count, met: { self.waiters.count >= $0 }, registered: nil)
    }

    /// `waitForWaiters(atLeast:)` that calls `registered` on the actor once the wait is registered (tests of the
    /// cancellation path).
    func waitForWaiters(atLeast count: Int, registered: @escaping @Sendable () -> Void) async -> Bool {
        if self.waiters.count >= count {
            return true
        }
        guard !self.finished else {
            return false
        }
        // REENTRANCY: h-4 (proposed, as TS2) — as `waitForWaiters(atLeast:)`.
        return await self.awaitCensus(target: count, met: { self.waiters.count >= $0 }, registered: registered)
    }

    /// Stops consuming.
    public func stop() {
        self.stopSignal.finish()
        self.finish()
    }

    private func receive(_ event: AssetEvent) {
        let index = self.events.count
        self.events.append(event)
        guard let position = self.waiters.firstIndex(where: { $0.predicate(event) }) else {
            return
        }
        let waiter = self.waiters.remove(at: position)
        self.consumed.insert(index)
        waiter.continuation.resume(returning: event)
    }

    private func finish() {
        self.finished = true
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: nil)
        }
        self.censusWaiters.resumeAll()
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let position = self.waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        self.waiters.remove(at: position).continuation.resume(returning: nil)
    }

    private func notifyCountWaiters() {
        let waiting = self.waiters.count
        self.censusWaiters.resume { $0 <= waiting }
    }
}
