import Foundation
import ZTronAssetModel

/// Which session a `SessionDelegate` serves.
public enum SessionMode: Sendable, Hashable {
    /// The foreground session: data tasks, per-task mailboxes (ADR-019).
    case foreground
    /// The background session: download tasks, routing through `taskDescription` and a session stream.
    case background
}

/// The one delegate of a session (R-NET-2): `Sendable` **without** `@unchecked` because it holds only `let`s of
/// `Sendable` types (transport.md §4.2, TC-1). Per-transfer routing goes through the task's own mailbox
/// (`URLSessionTask.delegate`, iOS 15+), which implements no method, so URLSession forwards every callback here.
/// Data callbacks append synchronously into staging on the delegate queue (C2, ADR-019); redirects are decided by
/// `RedirectPolicy` (R-NET-4).
///
/// **WP-D owns every body of this file**, including the members implemented in Stage 1 (ARCHITECTURE §6.1): it adds
/// the delegate methods (data, redirect, completion, download completion in `.background` mode, invalidation) in
/// this file or in extensions under `Session/`.
///
/// Session-level events have no task mailbox to go to: a background session's download tasks are routed through
/// `taskDescription` and must survive relaunch (H-6), and `didBecomeInvalidWithError` concerns the whole session
/// (transport-2 T2-04). They go to `sessionEvents`, one stream per delegate created in `init` (a `Sendable`
/// `AsyncStream` and its continuation, so no lock and no escape): `.finished` and `.backgroundEventsFinished` in
/// `.background` mode (consumed by `LiveBackgroundSessionDriver.activate()`), `.invalidated` in both modes (awaited
/// by `ForegroundTransferBackend.invalidate()`). Tests call the delegate methods directly, with unresumed tasks and
/// files inside this repository, and read this stream (ARCHITECTURE §14).
public final class SessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    /// Foreground or background behaviour.
    public let mode: SessionMode
    /// Where bytes go (R-STO-1).
    public let staging: any StagingSink
    /// Redirect and key policy.
    public let policy: TransportSecurityPolicy
    /// Session-level events in delivery order (single consumer, unbounded: a background session's events are
    /// bounded by `BackgroundTransferOptions.maxTasks`, transport-2 T2-17).
    package let sessionEvents: AsyncStream<SessionEvent>
    /// The producer side of `sessionEvents`, yielded to by the delegate methods on the delegate queue.
    let sessionEventSink: AsyncStream<SessionEvent>.Continuation

    /// Creates a delegate (one per session) and its session-event stream.
    public init(mode: SessionMode, staging: any StagingSink, policy: TransportSecurityPolicy) {
        self.mode = mode
        self.staging = staging
        self.policy = policy
        let (events, sink) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        self.sessionEvents = events
        self.sessionEventSink = sink
    }
}

/// A task's mailbox: deliberately implements no delegate method (so callbacks reach `SessionDelegate`) and only
/// carries the transfer's update continuation (transport.md §4.2).
public final class TaskMailbox: NSObject, URLSessionTaskDelegate, Sendable {
    /// Where the delegate yields this task's updates.
    public let continuation: AsyncStream<TransferUpdate>.Continuation
    /// The job, for the size guard and the staging name.
    public let job: TransferJob

    /// Creates a mailbox.
    public init(continuation: AsyncStream<TransferUpdate>.Continuation, job: TransferJob) {
        self.continuation = continuation
        self.job = job
    }
}

/// The foreground backend (R-NET-2, ADR-019): one long-lived, ephemeral, cache-less session whose data tasks
/// stream into staging. Constructed in `AssetClient.start()`, never in `init` (P-12, sync-2 S2-18). URLSession
/// retains its delegate until invalidated, so `invalidate()` (shutdown) and `deinit` both invalidate
/// (transport-2 T2-19). WP-D owns every body, the Stage 1 ones included.
public final class ForegroundTransferBackend: TransferBackend {
    /// `.foreground`.
    public let kind: TransferBackendKind = .foreground
    /// The session's delegate.
    public let delegate: SessionDelegate
    /// The one foreground session.
    public let session: URLSession

    /// Creates the backend and its session (about 0.05 ms, transport.md E-12).
    public init(delegate: SessionDelegate, maxConnectionsPerHost: Int, requestTimeout: TimeInterval) {
        self.delegate = delegate
        self.session = URLSession(
            configuration: ForegroundTransferBackend.makeConfiguration(
                maxConnectionsPerHost: maxConnectionsPerHost,
                requestTimeout: requestTimeout
            ),
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        self.session.invalidateAndCancel()
    }

    /// The foreground configuration of transport.md §4.1: ephemeral, no cache, no cookies, no credentials, no
    /// `httpAdditionalHeaders` (the key is only ever a per-request header, R-NET-4), connections clamped to 1…8,
    /// fail fast instead of waiting for connectivity, TLS ≥ 1.2.
    public static func makeConfiguration(maxConnectionsPerHost: Int, requestTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = min(max(maxConnectionsPerHost, 1), 8)
        configuration.httpShouldUsePipelining = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = [:]
        return configuration
    }

    /// Starts one data task for `job`.
    public func start(_ job: TransferJob) async -> any TransferHandle {
        fatalError("WP-D: ForegroundTransferBackend.start not implemented")
    }

    /// Live data tasks.
    public func liveTransfers() async -> [LiveTransfer] {
        fatalError("WP-D: ForegroundTransferBackend.liveTransfers not implemented")
    }

    /// Cancels by staging name.
    public func cancel(_ name: StagingFileName, keepingPartial: Bool) async {
        fatalError("WP-D: ForegroundTransferBackend.cancel not implemented")
    }

    /// `invalidateAndCancel()` and waits for `didBecomeInvalidWithError`, i.e. for `.invalidated` on
    /// `delegate.sessionEvents` (transport-2 T2-04).
    public func invalidate() async {
        fatalError("WP-D: ForegroundTransferBackend.invalidate not implemented")
    }
}
