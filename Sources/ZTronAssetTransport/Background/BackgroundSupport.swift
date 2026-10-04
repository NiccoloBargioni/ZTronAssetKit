import Foundation
import ZTronAssetModel

/// The background session identifier `com.ztron.assetkit.bg.<namespace>.v1` (R-NET-3, transport.md §10.3).
///
/// Never derived from a path (container paths change across reinstalls). `isOurs` is the AppDelegate hook's
/// ownership test, so an app can route other sessions' events elsewhere.
public struct BackgroundSessionIdentifier: Sendable, Hashable, CustomStringConvertible {
    /// The full identifier.
    public let rawValue: String

    /// The fixed prefix.
    public static let prefix = "com.ztron.assetkit.bg."
    /// The fixed suffix (layout version of the identifier).
    public static let suffix = ".v1"

    /// The identifier for `namespace`; `nil` unless it is 1…32 bytes of `[0-9a-z-]`.
    public init?(namespace: String) {
        let utf8 = Array(namespace.utf8)
        guard (1...32).contains(utf8.count) else {
            return nil
        }
        for byte in utf8 {
            let allowed =
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
            guard allowed else {
                return nil
            }
        }
        self.rawValue = BackgroundSessionIdentifier.prefix + namespace + BackgroundSessionIdentifier.suffix
    }

    /// Whether `identifier` is one of ours (any valid namespace).
    public static func isOurs(_ identifier: String) -> Bool {
        guard identifier.hasPrefix(BackgroundSessionIdentifier.prefix),
            identifier.hasSuffix(BackgroundSessionIdentifier.suffix)
        else {
            return false
        }
        let namespace = identifier.dropFirst(BackgroundSessionIdentifier.prefix.count)
            .dropLast(BackgroundSessionIdentifier.suffix.count)
        return BackgroundSessionIdentifier(namespace: String(namespace)) != nil
    }

    /// The full identifier.
    public var description: String {
        self.rawValue
    }
}

/// One task as `getAllTasks` reports it (H-6).
public struct BackgroundTaskSnapshot: Sendable, Hashable {
    /// `URLSessionTask.taskIdentifier`.
    public var taskIdentifier: Int
    /// The staging name decoded from `taskDescription`; `nil` for a foreign or undecodable tag (cancelled).
    public var name: StagingFileName?
    /// Running versus suspended.
    public var isRunning: Bool
    /// Bytes received.
    public var bytesReceived: Int64

    /// Creates a snapshot.
    public init(taskIdentifier: Int, name: StagingFileName?, isRunning: Bool, bytesReceived: Int64) {
        self.taskIdentifier = taskIdentifier
        self.name = name
        self.isRunning = isRunning
        self.bytesReceived = bytesReceived
    }
}

/// What a background session reports, classified by the shared `SessionDelegate` in `.background` mode.
public enum SessionEvent: Sendable, Hashable {
    /// A task ended: staged into `staging/<name>`, failed, or paused with resume data.
    case finished(name: StagingFileName, update: TransferUpdate)
    /// `urlSessionDidFinishEvents`: every preceding event of this launch was delivered.
    case backgroundEventsFinished
    /// The session became invalid.
    case invalidated
}

/// The device-only half of the background session (R-NET-3): **decision-free** so the excluded file stays thin
/// (≤ 250 lines) and every decision lives in tested code (transport-2 T2-05). The live conformer is
/// `LiveBackgroundSessionDriver` in `BackgroundSessionBackend.swift`; tests use `FakeBackgroundSessionDriver`
/// (Tests/ZTronAssetTransportTests, ADR-040).
public protocol BackgroundSessionDriver: Sendable {
    /// The session identifier.
    var identifier: BackgroundSessionIdentifier { get }
    /// Creates the session (once) and returns its event stream. Creating the session is what makes the OS deliver
    /// pending events, so `start()` calls it **before** listing staging (transport-2 T2-03, ADR-028).
    func activate() async -> AsyncStream<SessionEvent>
    /// `getAllTasks`.
    func snapshot() async -> [BackgroundTaskSnapshot]
    /// Creates and resumes a download task tagged with `name`.
    func startDownload(_ request: URLRequest, name: StagingFileName, priority: Float, expectedBytes: Int64?) async
    /// Cancels a task; returns the resume data when `producingResumeData` (the coordinator decides what to keep).
    func cancel(taskIdentifier: Int, producingResumeData: Bool) async -> ResumeData?
    /// Sets a task's priority.
    func setPriority(taskIdentifier: Int, _ priority: Float) async
    /// Releases the session without cancelling the OS's work (`finishTasksAndInvalidate`).
    func invalidate() async
}

/// The tested half of the background session (WP-D): attach-or-create by staging name, pause intent, fallback to
/// foreground, the task cap, and the completion-handler protocol with `BackgroundEventsRelay`. Owns one pump task
/// only while a background transfer is outstanding, so the engine can be idle-silent (transport-2 T2-10). The
/// production `HTTPRemoteSource` builds it over `LiveBackgroundSessionDriver` when background transfers are
/// enabled (`HTTPRemoteSource.makeBackgroundBackend`, ADR-026); tests build it over `FakeBackgroundSessionDriver`.
package actor BackgroundTransferCoordinator: TransferBackend {
    /// `.background`.
    package nonisolated let kind: TransferBackendKind = .background
    /// The device-only driver (decision-free).
    package nonisolated let driver: any BackgroundSessionDriver
    private let staging: any StagingSink
    /// The task cap and redirect exposure (transport-2 T2-09, T2-17).
    package nonisolated let options: BackgroundTransferOptions

    /// Creates a coordinator (no session until the first `start` or `activate`).
    package init(driver: any BackgroundSessionDriver, staging: any StagingSink, options: BackgroundTransferOptions) {
        self.driver = driver
        self.staging = staging
        self.options = options
    }

    /// Attach-or-create by staging name.
    package func start(_ job: TransferJob) async -> any TransferHandle {
        fatalError("WP-D: BackgroundTransferCoordinator.start not implemented")
    }

    /// `getAllTasks` as live transfers.
    package func liveTransfers() async -> [LiveTransfer] {
        fatalError("WP-D: BackgroundTransferCoordinator.liveTransfers not implemented")
    }

    /// Cancels by staging name.
    package func cancel(_ name: StagingFileName, keepingPartial: Bool) async {
        fatalError("WP-D: BackgroundTransferCoordinator.cancel not implemented")
    }

    /// Releases the session.
    package func invalidate() async {
        fatalError("WP-D: BackgroundTransferCoordinator.invalidate not implemented")
    }
}

/// Holds UIKit's background-events completion handler on the main actor (R-NET-3, transport.md §10.6).
///
/// `nonisolated init`, so the nonisolated `AssetClient.init` can create it (transport-2 T2-16). The handler is
/// UIKit's plain `() -> Void` and never leaves the main actor.
@MainActor
public final class BackgroundEventsRelay {
    private var handlers: [String: () -> Void] = [:]

    /// Creates an empty relay.
    nonisolated public init() {}

    /// Stores the handler for one of our identifiers; `false` (and nothing stored) for foreign identifiers.
    public func accept(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard BackgroundSessionIdentifier.isOurs(identifier) else {
            return false
        }
        self.handlers[identifier] = completionHandler
        return true
    }

    /// Whether a handler is waiting for `identifier` (the "hook not wired" check, transport.md §10.7).
    public func hasHandler(for identifier: String) -> Bool {
        self.handlers[identifier] != nil
    }

    /// Calls and forgets the handler, once.
    public func complete(identifier: String) {
        self.handlers.removeValue(forKey: identifier)?()
    }
}
