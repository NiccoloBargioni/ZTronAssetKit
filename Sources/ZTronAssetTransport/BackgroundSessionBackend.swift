import Foundation
import ZTronAssetModel

/// The live background session (R-NET-3): one of the two coverage-excluded, device-only files (SPEC §4.1,
/// ≤ 250 lines). It makes **no decision**: it creates the session (`background(withIdentifier:)`,
/// `isDiscretionary`, `sessionSendsLaunchEvents`, no cache, no cookies, empty `httpAdditionalHeaders`, the shared
/// `SessionDelegate` in `.background` mode), forwards `getAllTasks`, starts tagged download tasks, and returns the
/// resume data of a cancellation to the coordinator (transport-2 T2-05). WP-D.
public final class LiveBackgroundSessionDriver: BackgroundSessionDriver {
    /// The session identifier.
    public let identifier: BackgroundSessionIdentifier
    /// The shared delegate (`.background` mode).
    public let delegate: SessionDelegate
    /// `URLSessionConfiguration.isDiscretionary`.
    public let discretionary: Bool

    /// Stores the configuration; the session is created by `activate()`.
    public init(identifier: BackgroundSessionIdentifier, delegate: SessionDelegate, discretionary: Bool) {
        self.identifier = identifier
        self.delegate = delegate
        self.discretionary = discretionary
    }

    /// Holds the session once created.
    private let holder = BackgroundSessionHolder()

    /// Creates the background session (once) and returns `delegate.sessionEvents`.
    public func activate() async -> AsyncStream<SessionEvent> {
        _ = await self.holder.session(self.makeSession)
        return self.delegate.sessionEvents
    }

    /// `getAllTasks`, each task's tag decoded (`nil` for a foreign one).
    public func snapshot() async -> [BackgroundTaskSnapshot] {
        guard let session = await self.holder.existing else {
            return []
        }
        return await session.allTasks.map { task in
            BackgroundTaskSnapshot(
                taskIdentifier: task.taskIdentifier,
                name: BackgroundTaskTag(decoding: task.taskDescription)?.name,
                isRunning: task.state == .running,
                bytesReceived: task.countOfBytesReceived
            )
        }
    }

    /// A tagged download task.
    public func startDownload(_ request: URLRequest, name: StagingFileName, priority: Float, expectedBytes: Int64?) async {
        let session = await self.holder.session(self.makeSession)
        let task = session.downloadTask(with: request)
        task.taskDescription = BackgroundTaskTag(name: name, expectedBytes: expectedBytes).encoded
        task.priority = priority
        if let expectedBytes {
            task.countOfBytesClientExpectsToReceive = expectedBytes
        }
        task.resume()
    }

    /// `cancel()` or `cancelByProducingResumeData()`.
    public func cancel(taskIdentifier: Int, producingResumeData: Bool) async -> ResumeData? {
        guard let task = await self.task(taskIdentifier) else {
            return nil
        }
        guard producingResumeData, let download = task as? URLSessionDownloadTask else {
            task.cancel()
            return nil
        }
        return await download.cancelByProducingResumeData().map { ResumeData(bytes: $0) }
    }

    /// `URLSessionTask.priority`.
    public func setPriority(taskIdentifier: Int, _ priority: Float) async {
        if let task = await self.task(taskIdentifier) {
            task.priority = priority
        }
    }

    /// `finishTasksAndInvalidate()`.
    public func invalidate() async {
        await self.holder.existing?.finishTasksAndInvalidate()
    }

    private func task(_ identifier: Int) async -> URLSessionTask? {
        await self.holder.existing?.allTasks.first { $0.taskIdentifier == identifier }
    }

    /// The configuration of transport.md §10.4: no cache, cookies or credentials, no `httpAdditionalHeaders`
    /// (R-NET-4), launch events on, the shared delegate in `.background` mode.
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: self.identifier.rawValue)
        configuration.isDiscretionary = self.discretionary
        configuration.sessionSendsLaunchEvents = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: self.delegate, delegateQueue: nil)
    }
}

/// Creates the background session at most once (a second session with one identifier is an error).
private actor BackgroundSessionHolder {
    private var session: URLSession?

    var existing: URLSession? {
        self.session
    }

    func session(_ make: @Sendable () -> URLSession) -> URLSession {
        if let session = self.session {
            return session
        }
        let made = make()
        self.session = made
        return made
    }
}
