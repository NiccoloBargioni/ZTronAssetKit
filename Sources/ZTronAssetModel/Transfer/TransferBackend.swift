import Foundation

/// Which `URLSession` a backend drives.
public enum TransferBackendKind: String, Sendable, Hashable {
    /// The one long-lived foreground session (R-NET-2): data tasks appending into staging (ADR-019).
    case foreground
    /// The opt-in discretionary background session (R-NET-3, ADR-026): download tasks.
    case background
}

/// One job for a `TransferBackend`. It carries **no secret**: the backend attaches the key per request after the
/// security policy allowed the origin (R-NET-4).
public struct TransferJob: Sendable, Hashable {
    /// The content identity.
    public var id: TransferID
    /// The attempt (staging names, ADR-013).
    public var attempt: TransferAttempt
    /// The absolute URL, already built from `baseURL` and a validated `remotePath` (transport-1 TR1-10).
    public var url: URL
    /// Manifest or asset.
    public var purpose: TransferPurpose
    /// Sent as `If-None-Match` (manifest fetches only).
    public var ifNoneMatch: ETag?
    /// The manifest's decoded size; writing more aborts early (R-NET-7, TR1-8).
    public var expectedBytes: Int64?
    /// The hard cap.
    public var maxBytes: Int64
    /// The lane (R-NET-10).
    public var priority: AssetPriority
    /// OS-enforced permissions.
    public var access: NetworkAccess
    /// Continue an earlier partial with `Range` + `If-Range`.
    public var resume: ResumePoint?

    /// Creates a job.
    public init(
        id: TransferID,
        attempt: TransferAttempt,
        url: URL,
        purpose: TransferPurpose,
        ifNoneMatch: ETag? = nil,
        expectedBytes: Int64?,
        maxBytes: Int64,
        priority: AssetPriority,
        access: NetworkAccess = .unrestricted,
        resume: ResumePoint? = nil
    ) {
        self.id = id
        self.attempt = attempt
        self.url = url
        self.purpose = purpose
        self.ifNoneMatch = ifNoneMatch
        self.expectedBytes = expectedBytes
        self.maxBytes = maxBytes
        self.priority = priority
        self.access = access
        self.resume = resume
    }

    /// The partial file this job writes.
    public var partialName: StagingFileName {
        StagingFileName(transfer: self.id, attempt: self.attempt, kind: .partial)
    }
}

/// Opaque URLSession resume data of a **background** download task (ADR-019: foreground transfers never produce it).
///
/// It embeds the archived request including its headers, so it redacts itself everywhere a value can be printed
/// (R-SEC-1) and never leaves the transport and `staging/`.
public struct ResumeData: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The archive; readable inside the package only.
    package let bytes: Data

    /// Wraps an archive (package only: apps never build resume data).
    package init(bytes: Data) {
        self.bytes = bytes
    }

    /// `ResumeData(<n> bytes, redacted)`.
    public var description: String {
        "ResumeData(\(self.bytes.count) bytes, redacted)"
    }

    /// `ResumeData(<n> bytes, redacted)`.
    public var debugDescription: String {
        self.description
    }

    /// A mirror with no children, so `dump` and reflection never reach the archive.
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// A transfer as a backend sees it (re-attachment, R-NET-10 observation in tests).
public struct LiveTransfer: Sendable, Hashable {
    /// The staging file it writes.
    public var name: StagingFileName
    /// Which session runs it.
    public var backend: TransferBackendKind
    /// Running versus suspended.
    public var isRunning: Bool
    /// Bytes received so far.
    public var bytesReceived: Int64
    /// `URLSessionTask.priority` as set (0.75 / 0.5 / 0.25, ARCHITECTURE §7.5).
    public var priority: Float

    /// Creates a description.
    public init(name: StagingFileName, backend: TransferBackendKind, isRunning: Bool, bytesReceived: Int64, priority: Float) {
        self.name = name
        self.backend = backend
        self.isRunning = isRunning
        self.bytesReceived = bytesReceived
        self.priority = priority
    }
}

/// The URLSession side of the HTTP source (R-NET-1, R-NET-2): `HTTPRemoteSource` composes one foreground backend
/// and, when enabled, one background backend; tests inject `FakeTransferBackend`.
public protocol TransferBackend: Sendable {
    /// Which session it drives.
    var kind: TransferBackendKind { get }
    /// Starts one job. Foreground: one data task streaming into `staging/`. Background: attach-or-create.
    func start(_ job: TransferJob) async -> any TransferHandle
    /// Transfers the session still runs (background re-attachment, tests).
    func liveTransfers() async -> [LiveTransfer]
    /// Cancels by staging name; `keepingPartial` keeps the partial and its sidecar.
    func cancel(_ name: StagingFileName, keepingPartial: Bool) async
    /// Shutdown: `invalidateAndCancel()`, returning only after the delegate's last callback (transport-2 T2-04).
    func invalidate() async
}
