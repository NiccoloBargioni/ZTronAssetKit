/// A complete download sitting in `staging/`, size-checked against `byteSize` but **not** hash-verified (R-NET-7).
///
/// The store claims it by renaming it to `.verifying` before hashing, so no late producer can change the bytes it
/// verifies (store-1 S1-12, transport-2 T2-02).
public struct StagedFile: Sendable, Hashable {
    /// The staging file (kind `.partial`).
    public var name: StagingFileName
    /// On-disk (decoded) bytes.
    public var byteCount: Int64
    /// Whether some bytes came from an earlier attempt (R-NET-8): informative only, the hash always runs.
    public var resumed: Bool
    /// The final HTTP status; `nil` on the Apple tier.
    public var httpStatus: Int?
    /// The response's entity tag, when one was sent.
    public var etag: ETag?

    /// Creates a staged-file description.
    public init(name: StagingFileName, byteCount: Int64, resumed: Bool, httpStatus: Int?, etag: ETag?) {
        self.name = name
        self.byteCount = byteCount
        self.resumed = resumed
        self.httpStatus = httpStatus
        self.etag = etag
    }
}

/// The element of a transfer's update stream. Exactly one terminal element (`staged`, `paused`, `failed`) ends
/// every stream, and nothing is yielded after it (H-9: newest-wins buffering can only drop progress).
public enum TransferUpdate: Sendable, Hashable {
    /// Bytes received so far (rate-limited at the source).
    case progress(received: Int64, expected: Int64?)
    /// Terminal: complete bytes in the staging file.
    case staged(StagedFile)
    /// Terminal, after `pause()`: `resumable` when the source kept something the next attempt of the same content can
    /// continue, which only checksummed content ever has (transport-1 TR1-3). Foreground HTTP: the partial holds bytes
    /// from a 200 or 206 that carried a strong `ETag` or a `Last-Modified`, and a resume sidecar with that validator
    /// was written (best effort; a missing sidecar only costs the resume; ADR-050, D-5). Background HTTP: the OS
    /// returned resume data, kept in memory only (never in staging), at most `maxTasks` entries with the oldest
    /// dropped, and handed once to the next start of that content (ADR-019 as amended by ADR-050, D-14.2); a
    /// relaunch loses it. The Apple tier never keeps anything (`false`).
    case paused(resumable: Bool)
    /// Terminal: the closed failure taxonomy (R-NET-6).
    case failed(TransferError)

    /// Whether this element ends the stream.
    public var isTerminal: Bool {
        if case .progress = self {
            return false
        }
        return true
    }
}

/// A control operation on a running transfer, as recorded by fakes and logs (R-SYN-3 promotion, R-SYN-4 cancel).
public enum TransferControl: Sendable, Hashable {
    /// Change the lane (R-NET-10): takes effect immediately, the transfer is not restarted.
    case setPriority(AssetPriority)
    /// Stop, keeping what a later attempt of the same content can continue, if anything (foreground HTTP: the partial
    /// and its sidecar; background HTTP: the OS's resume data, in memory; see `TransferUpdate.paused(resumable:)`)
    /// → terminal `.paused(resumable:)`.
    case pause
    /// Stop, discarding the partial → terminal `.failed(.cancelled(.byClient))`.
    case cancel
}

/// A running transfer (ADR-021).
///
/// Every control is **synchronous and nonisolated**, so the engine can promote, pause or cancel from its
/// synchronous, actor-isolated `join`/`pump` code without a suspension (sync.md §3.3) and without a per-transfer
/// control stream that could coalesce a `pause` away (sync-1 S1-06). Controls after the terminal element are
/// no-ops. Terminating the `updates` stream (its consumer cancelled or dropped) cancels the transfer.
public protocol TransferHandle: Sendable {
    /// The content being transferred.
    var id: TransferID { get }
    /// The attempt this handle drives (its staging names, ADR-013).
    var attempt: TransferAttempt { get }
    /// Single consumer; progress may coalesce, the terminal element is never dropped.
    var updates: AsyncStream<TransferUpdate> { get }
    /// Changes the lane in place (R-NET-10).
    func setPriority(_ priority: AssetPriority)
    /// Stops, keeping what a later attempt can continue, if anything (`TransferUpdate.paused(resumable:)`; preemption,
    /// policy pause).
    func pause()
    /// Stops and discards the partial.
    func cancel()
}
