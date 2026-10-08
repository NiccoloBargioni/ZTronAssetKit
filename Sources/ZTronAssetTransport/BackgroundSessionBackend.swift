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

    /// Whether the session exists yet: building the source creates none (ADR-028), activation does.
    package var hasSession: Bool {
        get async {
            await self.holder.existing != nil
        }
    }

    /// Creates the background session (once, never after `invalidate()`) and returns `delegate.sessionEvents`.
    public func activate() async -> AsyncStream<SessionEvent> {
        await self.holder.withSession(self.makeSession) { _ in }
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

    /// A tagged download task, created inside the holder so it never meets an invalidated session: from the resume
    /// data when the coordinator passed some, else from `request`.
    public func startDownload(_ request: URLRequest, name: StagingFileName, priority: Float, expectedBytes: Int64?, resumeData: ResumeData?) async {
        let tag = BackgroundTaskTag(name: name, expectedBytes: expectedBytes)
        await self.holder.withSession(self.makeSession) { session in
            let task = resumeData.map { session.downloadTask(withResumeData: $0.bytes) } ?? session.downloadTask(with: request)
            tag.label(task, priority: priority)
            task.resume()
        }
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

    /// `finishTasksAndInvalidate()`; later starts create nothing.
    public func invalidate() async {
        await self.holder.invalidate()
    }

    private func task(_ identifier: Int) async -> URLSessionTask? {
        await self.holder.existing?.allTasks.first { $0.taskIdentifier == identifier }
    }

    /// The session of `BackgroundSessionConfiguration` (transport.md §10.4) with the shared delegate in
    /// `.background` mode.
    private func makeSession() -> URLSession {
        let configuration = BackgroundSessionConfiguration.make(identifier: self.identifier, discretionary: self.discretionary)
        return URLSession(configuration: configuration, delegate: self.delegate, delegateQueue: nil)
    }
}

/// Creates the background session at most once (a second session with one identifier is an error), and orders task
/// creation against invalidation: creating a task on an invalidated session raises an Objective-C exception.
private actor BackgroundSessionHolder {
    private var session: URLSession?
    private var invalidated = false

    var existing: URLSession? {
        self.session
    }

    /// Runs `body` with the session (created first when needed) unless the session was invalidated.
    func withSession(_ make: @Sendable () -> URLSession, _ body: @Sendable (URLSession) -> Void) {
        guard !self.invalidated else {
            return
        }
        let session = self.session ?? make()
        self.session = session
        body(session)
    }

    /// Releases the session without cancelling the OS's tasks and refuses every later `withSession`.
    func invalidate() {
        self.invalidated = true
        self.session?.finishTasksAndInvalidate()
    }
}
