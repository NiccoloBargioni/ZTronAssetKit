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

    /// Creates the background session and returns its event stream.
    public func activate() async -> AsyncStream<SessionEvent> {
        fatalError("WP-D: LiveBackgroundSessionDriver.activate not implemented")
    }

    /// `getAllTasks`.
    public func snapshot() async -> [BackgroundTaskSnapshot] {
        fatalError("WP-D: LiveBackgroundSessionDriver.snapshot not implemented")
    }

    /// A tagged download task.
    public func startDownload(_ request: URLRequest, name: StagingFileName, priority: Float, expectedBytes: Int64?) async {
        fatalError("WP-D: LiveBackgroundSessionDriver.startDownload not implemented")
    }

    /// `cancel()` or `cancelByProducingResumeData()`.
    public func cancel(taskIdentifier: Int, producingResumeData: Bool) async -> ResumeData? {
        fatalError("WP-D: LiveBackgroundSessionDriver.cancel not implemented")
    }

    /// `URLSessionTask.priority`.
    public func setPriority(taskIdentifier: Int, _ priority: Float) async {
        fatalError("WP-D: LiveBackgroundSessionDriver.setPriority not implemented")
    }

    /// `finishTasksAndInvalidate()`.
    public func invalidate() async {
        fatalError("WP-D: LiveBackgroundSessionDriver.invalidate not implemented")
    }
}
