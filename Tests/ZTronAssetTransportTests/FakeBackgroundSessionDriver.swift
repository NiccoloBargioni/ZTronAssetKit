import Foundation
import ZTronAssetModel
import ZTronAssetTransport

/// The test double of the device-only background driver (ADR-040): it lives here because its protocol lives in
/// `ZTronAssetTransport`, which `ZTronAssetTestSupport` cannot see. It keeps "OS" tasks across coordinator instances
/// and delivers queued completions only when `activate()` is called, which is the order the real OS imposes
/// (transport-2 T2-03). WP-D implements it with the background coordinator.
///
/// Like the live driver, it returns the shared `SessionDelegate`'s `sessionEvents` and reports every OS event by
/// calling that delegate: a finished download through `stageDownload` (a file this test wrote inside the repository
/// is moved into staging), a failure through `urlSession(_:task:didCompleteWithError:)`, the end of a launch's
/// events through `urlSessionDidFinishEvents`. Its "OS tasks" are **unresumed** download tasks of an ephemeral
/// session, so they carry real `taskDescription` tags and never touch the network or the system temp directory
/// (ARCHITECTURE §14).
actor FakeBackgroundSessionDriver: BackgroundSessionDriver {
    nonisolated let identifier: BackgroundSessionIdentifier

    /// One call of `startDownload`.
    struct Start: Sendable, Hashable {
        var url: URL?
        var name: StagingFileName
        var priority: Float
        var expectedBytes: Int64?
        var keyHeader: String?
        var timeout: TimeInterval
        /// The resume data the coordinator continued from (`nil`: a fresh download).
        var resumeData: ResumeData?
    }

    private enum Delivery {
        case finished(URLSessionDownloadTask, status: Int, body: Data, finalURL: URL?, contentRangeStart: Int64?)
        case failed(URLSessionDownloadTask, NSError)
        case eventsFinished
    }

    private let session = URLSession(configuration: .ephemeral)
    private let fixtures: URL
    private let keyHeaderName: String
    private var delegate: SessionDelegate
    private var activated = false
    private var tasks: [Int: URLSessionDownloadTask] = [:]
    private var progress: [Int: Int64] = [:]
    private var queued: [Delivery] = []
    private var heldCancellations: [Delivery] = []
    private var fileCount = 0
    private var snapshotGate: CheckedContinuation<Void, Never>?
    private var holdSnapshot: SnapshotHold?
    private var cancelGate: CheckedContinuation<Void, Never>?
    private var holdCancel: CancelHold?
    private var priorityGate: CheckedContinuation<Void, Never>?
    private var holdPriority = false

    /// Where the next `snapshot` waits for `releaseSnapshot()`.
    enum SnapshotHold: Sendable {
        /// Before the tasks are listed: the listing reflects whatever happens while it waits.
        case beforeListing
        /// After the tasks were listed: the caller receives a listing that went stale while it waited.
        case afterListing
    }

    /// Where the next `cancel` waits for `releaseCancel()`.
    enum CancelHold: Sendable {
        /// Before anything happens: the task is still live meanwhile.
        case beforeCancelling
        /// After the cancellation was reported on the session stream, before the resume data is returned.
        case afterReporting
    }

    /// Signals the test awaits instead of polling: `"snapshot"`, `"cancel"` and `"priority held"` when a held call is
    /// waiting, `"priority"` after every `setPriority`, `"cancelled"` after every `cancel`.
    nonisolated let signals: AsyncStream<String>
    private let signal: AsyncStream<String>.Continuation

    /// Every `startDownload`, in order.
    private(set) var starts: [Start] = []
    /// Every `cancel` call: the task and whether resume data was asked for.
    private(set) var cancellations: [(taskIdentifier: Int, producingResumeData: Bool)] = []
    /// Every `setPriority` call, in the order the writes landed (a held write counts once released).
    private(set) var priorityChanges: [(taskIdentifier: Int, priority: Float)] = []
    /// What reached the driver, in order: each listing (when `snapshot()` lists the tasks) and each priority write
    /// as it lands. A handle's priority change lists the tasks first, so the FIFO test reads here that a change's
    /// listing came only after the previous change's write landed.
    private(set) var calls: [Call] = []

    /// One entry of `calls`.
    enum Call: Equatable, Sendable {
        /// `snapshot()` listed the tasks.
        case listing
        /// A `setPriority` write landed with this value.
        case priority(Float)
    }
    /// `activate()` calls.
    private(set) var activations = 0
    /// `invalidate()` calls.
    private(set) var invalidations = 0
    /// What `cancel(…, producingResumeData: true)` returns.
    private var resumeDataOnCancel: ResumeData?
    /// When `true`, a cancellation's session event is held until `deliverHeldCancellations()`, so the resume data
    /// returns first (the other order of transport-2 T2-05).
    private var holdCancellationEvents = false

    /// Scripts what a cancellation producing resume data returns, and whether its event waits for
    /// `deliverHeldCancellations()`.
    func setResumeData(_ data: ResumeData?, holdingCancellationEvents: Bool) {
        self.resumeDataOnCancel = data
        self.holdCancellationEvents = holdingCancellationEvents
    }

    init(identifier: BackgroundSessionIdentifier, delegate: SessionDelegate, fixtures: URL, keyHeaderName: String = "x-zombietron-app-key") {
        self.identifier = identifier
        self.delegate = delegate
        self.fixtures = fixtures
        self.keyHeaderName = keyHeaderName
        (self.signals, self.signal) = AsyncStream.makeStream(of: String.self)
    }

    deinit {
        self.session.invalidateAndCancel()
    }

    // MARK: - BackgroundSessionDriver

    func activate() async -> AsyncStream<SessionEvent> {
        self.activations += 1
        if !self.activated {
            self.activated = true
            let queued = self.queued
            self.queued = []
            for delivery in queued {
                self.deliver(delivery)
            }
        }
        return self.delegate.sessionEvents
    }

    func snapshot() async -> [BackgroundTaskSnapshot] {
        let hold = self.holdSnapshot
        self.holdSnapshot = nil
        if hold == .beforeListing {
            await self.waitForSnapshotRelease()
        }
        let listing = self.listing()
        self.calls.append(.listing)
        if hold == .afterListing {
            await self.waitForSnapshotRelease()
        }
        return listing
    }

    private func waitForSnapshotRelease() async {
        await withCheckedContinuation { continuation in
            self.snapshotGate = continuation
            self.signal.yield("snapshot")
        }
    }

    private func listing() -> [BackgroundTaskSnapshot] {
        self.tasks.keys.sorted().compactMap { identifier in
            guard let task = self.tasks[identifier] else {
                return nil
            }
            return BackgroundTaskSnapshot(
                taskIdentifier: identifier,
                name: BackgroundTaskTag(decoding: task.taskDescription)?.name,
                isRunning: true,
                bytesReceived: self.progress[identifier] ?? 0
            )
        }
    }

    func startDownload(_ request: URLRequest, name: StagingFileName, priority: Float, expectedBytes: Int64?, resumeData: ResumeData?) async {
        let task = self.session.downloadTask(with: request)
        // Labelled by the live driver's own call: a task continuing resume data says so in its tag (it outlives the
        // process), so the relaunch tests pin the mapping the device runs.
        BackgroundTaskTag.forStart(name: name, expectedBytes: expectedBytes, resumeData: resumeData).label(task, priority: priority)
        self.tasks[task.taskIdentifier] = task
        self.starts.append(Start(
            url: request.url,
            name: name,
            priority: priority,
            expectedBytes: expectedBytes,
            keyHeader: request.value(forHTTPHeaderField: self.keyHeaderName),
            timeout: request.timeoutInterval,
            resumeData: resumeData
        ))
    }

    func cancel(taskIdentifier: Int, producingResumeData: Bool) async -> ResumeData? {
        self.cancellations.append((taskIdentifier, producingResumeData))
        let hold = self.holdCancel
        self.holdCancel = nil
        if hold == .beforeCancelling {
            await self.waitForRelease()
        }
        defer { self.signal.yield("cancelled") }
        guard let task = self.tasks.removeValue(forKey: taskIdentifier) else {
            return nil
        }
        let delivery = Delivery.failed(task, NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        if self.holdCancellationEvents {
            self.heldCancellations.append(delivery)
        } else {
            self.deliverOrQueue(delivery)
        }
        if hold == .afterReporting {
            await self.waitForRelease()
        }
        return producingResumeData ? self.resumeDataOnCancel : nil
    }

    func setPriority(taskIdentifier: Int, _ priority: Float) async {
        if self.holdPriority {
            // The write is in flight past every check of its caller, as the live driver's own listing leaves it.
            self.holdPriority = false
            await withCheckedContinuation { continuation in
                self.priorityGate = continuation
                self.signal.yield("priority held")
            }
        }
        self.priorityChanges.append((taskIdentifier, priority))
        self.calls.append(.priority(priority))
        self.tasks[taskIdentifier]?.priority = priority
        self.signal.yield("priority")
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            self.cancelGate = continuation
            self.signal.yield("cancel")
        }
    }

    func invalidate() async {
        self.invalidations += 1
    }

    // MARK: - The test's "OS"

    /// Makes the next `snapshot()` wait for `releaseSnapshot()` at `hold` (after signalling `"snapshot"`).
    func holdNextSnapshot(_ hold: SnapshotHold = .beforeListing) {
        self.holdSnapshot = hold
    }

    /// Lets a held `snapshot()` continue.
    func releaseSnapshot() {
        self.snapshotGate?.resume()
        self.snapshotGate = nil
    }

    /// Makes the next `cancel` wait for `releaseCancel()` at `hold` (after signalling `"cancel"`).
    func holdNextCancel(_ hold: CancelHold) {
        self.holdCancel = hold
    }

    /// Lets a held `cancel` continue.
    func releaseCancel() {
        self.cancelGate?.resume()
        self.cancelGate = nil
    }

    /// Makes the next `setPriority` wait for `releasePriority()` before it writes (after signalling
    /// `"priority held"`).
    func holdNextPriority() {
        self.holdPriority = true
    }

    /// Lets a held `setPriority` write.
    func releasePriority() {
        self.priorityGate?.resume()
        self.priorityGate = nil
    }

    /// `didBecomeInvalidWithError`: the session is gone.
    func reportInvalidation() {
        self.delegate.urlSession(self.session, didBecomeInvalidWithError: nil)
    }

    /// A new process: the session must be activated again before anything is delivered; OS tasks survive.
    func relaunch(delegate: SessionDelegate) {
        self.delegate = delegate
        self.activated = false
    }

    /// An OS task left by an earlier launch (or a foreign one, with any description).
    @discardableResult
    func addTask(description: String?, url: URL, bytesReceived: Int64 = 0) -> Int {
        let task = self.session.downloadTask(with: url)
        task.taskDescription = description
        self.tasks[task.taskIdentifier] = task
        self.progress[task.taskIdentifier] = bytesReceived
        return task.taskIdentifier
    }

    /// The OS finished the task writing `name` with `status` and `body` (after redirects to `finalURL`, when given;
    /// a continued download answers 206 with a `Content-Range` starting at `contentRangeStart`, and its file holds
    /// the whole body): delivered now when the session is active, else at the next `activate()`.
    func complete(_ name: StagingFileName, status: Int = 200, body: Data, finalURL: URL? = nil, contentRangeStart: Int64? = nil) {
        guard let (identifier, task) = self.task(named: name) else {
            return
        }
        self.tasks.removeValue(forKey: identifier)
        self.deliverOrQueue(.finished(task, status: status, body: body, finalURL: finalURL, contentRangeStart: contentRangeStart))
    }

    /// The OS failed the task writing `name` with the URL error `code` (and `userInfo`).
    func fail(_ name: StagingFileName, code: Int, userInfo: [String: any Sendable] = [:]) {
        guard let (identifier, task) = self.task(named: name) else {
            return
        }
        self.tasks.removeValue(forKey: identifier)
        self.deliverOrQueue(.failed(task, NSError(domain: NSURLErrorDomain, code: code, userInfo: userInfo)))
    }

    /// `urlSessionDidFinishEvents`: every event of this launch was delivered.
    func finishEvents() {
        self.deliverOrQueue(.eventsFinished)
    }

    /// Delivers cancellation events held by `holdCancellationEvents`.
    func deliverHeldCancellations() {
        let held = self.heldCancellations
        self.heldCancellations = []
        for delivery in held {
            self.deliver(delivery)
        }
    }

    /// The live OS task names.
    var liveNames: [StagingFileName] {
        self.tasks.values.compactMap { BackgroundTaskTag(decoding: $0.taskDescription)?.name }.sorted()
    }

    private func task(named name: StagingFileName) -> (Int, URLSessionDownloadTask)? {
        self.tasks.first { BackgroundTaskTag(decoding: $0.value.taskDescription)?.name == name }.map { ($0.key, $0.value) }
    }

    private func deliverOrQueue(_ delivery: Delivery) {
        if self.activated {
            self.deliver(delivery)
        } else {
            self.queued.append(delivery)
        }
    }

    private func deliver(_ delivery: Delivery) {
        switch delivery {
        case .finished(let task, let status, let body, let finalURL, let contentRangeStart):
            guard let tag = BackgroundTaskTag(decoding: task.taskDescription) else {
                return
            }
            self.fileCount += 1
            let location = self.fixtures.appendingPathComponent("download-\(self.fileCount).tmp")
            try? body.write(to: location)
            let facts = ResponseFacts(
                status: status,
                bodyBytes: Int64(body.count),
                contentTypeIsXML: false,
                retryAfter: nil,
                etag: nil,
                contentRangeStart: contentRangeStart,
                keyPresented: false
            )
            let original = task.originalRequest?.url
            self.delegate.finishDownload(tag: tag, response: facts, originalURL: original, finalURL: finalURL ?? original, location: location)
            // The OS deletes its temporary file once the callback returned.
            try? FileManager.default.removeItem(at: location)
            self.delegate.urlSession(self.session, task: task, didCompleteWithError: nil)
        case .failed(let task, let error):
            self.delegate.urlSession(self.session, task: task, didCompleteWithError: error)
        case .eventsFinished:
            self.delegate.urlSessionDidFinishEvents(forBackgroundURLSession: self.session)
        }
    }
}
