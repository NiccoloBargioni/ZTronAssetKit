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
    /// Builds every request; the only holder of the key on this path (R-NET-4).
    let requests: RequestFactory
    /// Where the `transfer` signpost intervals go (R-OBS-1).
    let log: LogRoute
    /// Orders task creation against invalidation: a task created on an invalidated session raises an Objective-C
    /// exception, so `start` and `invalidate` meet on one actor.
    let gate = SessionGate()

    /// Creates the backend and its session (about 0.05 ms, transport.md E-12). Requests carry no key and intervals
    /// go nowhere; `HTTPRemoteSource` uses `init(delegate:maxConnectionsPerHost:requestTimeout:appKey:log:)`.
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
        self.requests = RequestFactory(policy: delegate.policy, appKey: nil, timeout: requestTimeout)
        self.log = .tapOnly(nil)
    }

    /// Creates the backend with the key its request factory attaches (to origins the delegate's policy allows) and
    /// the route its `transfer` intervals go to (ADR-047).
    package init(delegate: SessionDelegate, maxConnectionsPerHost: Int, requestTimeout: TimeInterval, appKey: AppKey?, log: LogRoute) {
        self.delegate = delegate
        self.session = URLSession(
            configuration: ForegroundTransferBackend.makeConfiguration(
                maxConnectionsPerHost: maxConnectionsPerHost,
                requestTimeout: requestTimeout
            ),
            delegate: delegate,
            delegateQueue: nil
        )
        self.requests = RequestFactory(policy: delegate.policy, appKey: appKey, timeout: requestTimeout)
        self.log = log
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

    /// Starts one data task for `job`: the request from the factory (the key only for allowed origins), the lane's
    /// priority, the job's mailbox, and a `transfer` interval that ends with the stream. Terminating the stream
    /// before its terminal element cancels the task (`TransferHandle`). A refused origin or an invalidated session
    /// yields a handle that is already terminal.
    public func start(_ job: TransferJob) async -> any TransferHandle {
        let request: URLRequest
        switch self.requests.makeRequest(for: job) {
        case .request(let built):
            request = built
        case .refused(let violation):
            return ImmediateTransferHandle(id: job.id, attempt: job.attempt, terminal: .failed(.rejected(violation)))
        }
        let session = self.session
        let log = self.log
        let (updates, continuation) = AsyncStream.makeStream(of: TransferUpdate.self, bufferingPolicy: .bufferingNewest(4))
        // The task gets its mailbox, priority and interval inside the gate, so no task ever exists without its
        // mailbox: an invalidation right after the gate still finds the mailbox and ends the stream.
        let made = await self.gate.makeTask {
            let task = session.dataTask(with: request)
            task.priority = job.priority.urlSessionTaskPriority
            if let expected = job.expectedBytes {
                task.countOfBytesClientExpectsToReceive = max(expected - (job.resume?.offset ?? 0), 0)
            }
            let purpose = job.purpose == .manifest ? "manifest" : "asset"
            let interval = log.interval(.transfer, category: .transport, "attempt \(job.attempt) \(purpose)")
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    // Nobody will read this transfer's outcome: append nothing more (a pause in progress keeps its mark).
                    TaskMarker.requestIfUnmarked(.discard, on: task)
                    task.cancel()
                }
                interval.end()
            }
            task.delegate = TaskMailbox(continuation: continuation, job: job)
            return task
        }
        guard let task = made else {
            continuation.finish()
            return ImmediateTransferHandle(id: job.id, attempt: job.attempt, terminal: .failed(.cancelled(.byClient)))
        }
        task.resume()
        return DataTransferHandle(job: job, updates: updates, task: task, staging: self.delegate.staging)
    }

    /// The session's running and suspended data tasks, read from the tasks themselves (their mailboxes). A task the
    /// client discarded is not live although its cancellation may not have reached the task yet: a handle's
    /// `cancel()` marks it synchronously and cancels it only after its partial was discarded.
    public func liveTransfers() async -> [LiveTransfer] {
        let tasks = await self.session.allTasks
        return tasks.compactMap { task in
            guard let job = (task.delegate as? TaskMailbox)?.job, task.state == .running || task.state == .suspended,
                TaskMarker(decoding: task.taskDescription) != .discard
            else {
                return nil
            }
            return LiveTransfer(
                name: job.partialName,
                backend: .foreground,
                isRunning: task.state == .running,
                bytesReceived: (job.resume?.offset ?? 0) + task.countOfBytesReceived,
                priority: task.priority
            )
        }
    }

    /// Cancels the task writing `name`. Keeping the partial is a pause (the sidecar is written by the delegate);
    /// otherwise the task is marked so the delegate appends nothing more, and the partial and its sidecar are
    /// discarded here (staging GC collects anything a callback still in flight leaves behind, R-CLN-3).
    public func cancel(_ name: StagingFileName, keepingPartial: Bool) async {
        let tasks = await self.session.allTasks
        var found = false
        for task in tasks where (task.delegate as? TaskMailbox)?.job.partialName == name {
            found = true
            if keepingPartial {
                TaskMarker.requestIfUnmarked(.pause, on: task)
            } else {
                TaskMarker.requestDiscard(on: task)
            }
            task.cancel()
        }
        if found && !keepingPartial {
            await self.delegate.staging.discard(name)
        }
    }

    /// `invalidateAndCancel()` and waits for `didBecomeInvalidWithError`, i.e. for `.invalidated` on
    /// `delegate.sessionEvents` (transport-2 T2-04).
    public func invalidate() async {
        await self.gate.invalidate(self.session, events: self.delegate.sessionEvents)
    }
}

/// Serialises task creation and invalidation of one foreground session, and lets any number of callers wait for
/// the session's last callback (`.invalidated`).
///
/// The session stream is single-consumer, so one unstructured task reads it; callers wait on continuations. That
/// task is not a caller's child, so a cancelled shutdown cannot end the read early (cancelling a reader terminates
/// an `AsyncStream` for good).
actor SessionGate {
    private var invalidating = false
    private var invalidated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `make` unless invalidation began; `nil` afterwards.
    func makeTask(_ make: @Sendable () -> URLSessionDataTask) -> URLSessionDataTask? {
        guard !self.invalidating else {
            return nil
        }
        return make()
    }

    /// Invalidates `session` once and returns after its delegate reported `.invalidated` on `events`.
    func invalidate(_ session: URLSession, events: AsyncStream<SessionEvent>) async {
        if self.invalidated {
            return
        }
        if !self.invalidating {
            self.invalidating = true
            session.invalidateAndCancel()
            Task {
                // REENTRANCY: D-1 (proposed) — the read of the session stream; afterwards `finish()` re-reads only
                // `waiters`, draining exactly the callers registered by then.
                for await event in events where event == .invalidated {
                    break
                }
                self.finish()
            }
        }
        // REENTRANCY: D-1 (proposed) — a terminal wait resumed by `finish()`, registered in the same actor turn as
        // the `invalidated` check above, so `finish()` cannot run in between.
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    private func finish() {
        self.invalidated = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
