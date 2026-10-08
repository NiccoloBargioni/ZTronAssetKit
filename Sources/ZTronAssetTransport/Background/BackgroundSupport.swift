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
///
/// **Attach-or-create.** `start(job)` first hands out a buffered outcome for the same content (a download that
/// finished while nobody waited, from any attempt: the bytes are hashed at publication, transport.md §10.8), then
/// joins a live OS task for the same content, and only then creates a download. **Pause.** The driver is
/// decision-free (T2-05): a pause records the intent here, the driver returns the resume data, and the cancellation
/// the session reports becomes `paused(resumable:)` whichever of the two arrives first. **Buffer.** Unclaimed
/// successes are kept, oldest dropped first, up to `maxTasks` (their files stay in staging for launch
/// reconciliation); unclaimed failures are dropped.
package actor BackgroundTransferCoordinator: TransferBackend {
    /// `.background`.
    package nonisolated let kind: TransferBackendKind = .background
    /// The device-only driver (decision-free).
    package nonisolated let driver: any BackgroundSessionDriver
    private let staging: any StagingSink
    /// The task cap and redirect exposure (transport-2 T2-09, T2-17).
    package nonisolated let options: BackgroundTransferOptions
    private let requests: RequestFactory
    private let log: LogRoute

    private enum PauseState {
        case requested
        case cancellationArrived
        case dataReturned(ResumeData?)
    }

    private var events: AsyncStream<SessionEvent>?
    private var pump: Task<Void, Never>?
    private var waiters: [StagingFileName: AsyncStream<TransferUpdate>.Continuation] = [:]
    private var outcomes: [StagingFileName: StagedFile] = [:]
    private var outcomeOrder: [StagingFileName] = []
    private var live: Set<StagingFileName> = []
    private var priorities: [StagingFileName: Float] = [:]
    private var pauses: [StagingFileName: PauseState] = [:]
    private var resumeData: [StagingFileName: ResumeData] = [:]
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var unclaimedFinishes = 0
    private var disabled = false
    private var invalidated = false

    /// Creates a coordinator (no session until the first `start` or `activate`). Its requests carry no key and are
    /// not checked again: the source checked the policy before routing here.
    package init(driver: any BackgroundSessionDriver, staging: any StagingSink, options: BackgroundTransferOptions) {
        self.driver = driver
        self.staging = staging
        self.options = options
        self.requests = RequestFactory(policy: nil, appKey: nil, timeout: 60)
        self.log = .tapOnly(nil)
    }

    /// Creates a coordinator whose requests are checked against `policy` and carry `appKey` (pass one only when the
    /// owner accepted redirect exposure, ADR-026), with `requestTimeout` per request, and whose intervals go to `log`.
    package init(
        driver: any BackgroundSessionDriver,
        staging: any StagingSink,
        options: BackgroundTransferOptions,
        policy: TransportSecurityPolicy,
        appKey: AppKey?,
        requestTimeout: TimeInterval,
        log: LogRoute
    ) {
        self.driver = driver
        self.staging = staging
        self.options = options
        self.requests = RequestFactory(policy: policy, appKey: appKey, timeout: requestTimeout)
        self.log = log
    }

    // MARK: - TransferBackend

    /// Attach-or-create by content: a buffered outcome, else a live OS task, else a new tagged download.
    package func start(_ job: TransferJob) async -> any TransferHandle {
        guard !self.invalidated else {
            return ImmediateTransferHandle(id: job.id, attempt: job.attempt, terminal: .failed(.cancelled(.byClient)))
        }
        // REENTRANCY: D-2 (proposed) — activation; nothing is read between it and the listing below.
        await self.activate()
        // REENTRANCY: D-2 (proposed) — the listing; afterwards `invalidated`, the outcome buffer and the waiters are
        // read anew, so an event the pump processed during either await is seen.
        let snapshot = await self.driver.snapshot()
        guard !self.invalidated else {
            return ImmediateTransferHandle(id: job.id, attempt: job.attempt, terminal: .failed(.cancelled(.byClient)))
        }
        if let staged = self.takeOutcome(for: job.id) {
            return ImmediateTransferHandle(id: job.id, attempt: staged.name.attempt, terminal: .staged(staged))
        }
        if let name = snapshot.compactMap(\.name).filter({ $0.transfer == job.id }).max(by: { $0.attempt < $1.attempt }) {
            return self.attach(name, id: job.id)
        }
        let request: URLRequest
        switch self.requests.makeRequest(for: job) {
        case .request(let built):
            request = built
        case .refused(let violation):
            return ImmediateTransferHandle(id: job.id, attempt: job.attempt, terminal: .failed(.rejected(violation)))
        }
        let name = job.partialName
        let priority = job.priority.urlSessionTaskPriority
        // The waiter exists before the OS can finish the task, so no completion finds nobody.
        let handle = self.attach(name, id: job.id)
        self.priorities[name] = priority
        // REENTRANCY: D-3 (proposed) — nothing is read after the start: the waiter was registered before it, and a
        // completion that raced ahead was delivered to that waiter by the pump.
        await self.driver.startDownload(request, name: name, priority: priority, expectedBytes: job.expectedBytes)
        return handle
    }

    /// The OS's tasks as live transfers (named ones only).
    package func liveTransfers() async -> [LiveTransfer] {
        // REENTRANCY: D-4 (proposed) — activation; nothing is read before the listing.
        await self.activate()
        // REENTRANCY: D-4 (proposed) — `priorities` is read after the listing; a priority set meanwhile is reported.
        let snapshot = await self.driver.snapshot()
        return snapshot.compactMap { task in
            guard let name = task.name else {
                return nil
            }
            return LiveTransfer(
                name: name,
                backend: .background,
                isRunning: task.isRunning,
                bytesReceived: task.bytesReceived,
                priority: self.priorities[name] ?? AssetPriority.bulk.urlSessionTaskPriority
            )
        }
    }

    /// Cancels the OS task writing `name`; keeping the partial is a pause, which keeps the resume data. After
    /// invalidation the session is released and nothing is controlled any more.
    package func cancel(_ name: StagingFileName, keepingPartial: Bool) async {
        guard !self.invalidated else {
            return
        }
        // REENTRANCY: D-5 (proposed) — activation; nothing is read before the listing.
        await self.activate()
        // REENTRANCY: D-5 (proposed) — the task is looked up in this listing, taken after every earlier await; a task
        // that finished meanwhile is absent and nothing is cancelled.
        let snapshot = await self.driver.snapshot()
        guard let task = snapshot.first(where: { $0.name == name }) else {
            return
        }
        if keepingPartial {
            self.pauses[name] = .requested
        }
        // REENTRANCY: D-5 (proposed) — `pauses[name]` is re-read afterwards: the cancellation may have been reported
        // during the await (then the pause is delivered here), or not yet (then the pump delivers it).
        let data = await self.driver.cancel(taskIdentifier: task.taskIdentifier, producingResumeData: keepingPartial)
        guard keepingPartial else {
            return
        }
        if let data {
            self.resumeData[name] = data
        }
        switch self.pauses[name] {
        case .cancellationArrived:
            self.pauses[name] = nil
            self.finishWaiter(name, with: .paused(resumable: data != nil))
        case .requested:
            self.pauses[name] = .dataReturned(data)
        case .dataReturned, nil:
            break
        }
    }

    /// Releases the session without waiting for the OS's tasks (ADR-039): stops the pump, fails every waiting
    /// handle with `cancelled(.byClient)`, completes any events waiter, and refuses later starts.
    package func invalidate() async {
        guard !self.invalidated else {
            return
        }
        self.invalidated = true
        self.pump?.cancel()
        self.pump = nil
        // REENTRANCY: D-6 (proposed) — `invalidated` was set before the await, so no waiter can be added meanwhile;
        // the tables are drained after it.
        await self.driver.invalidate()
        for name in Array(self.waiters.keys) {
            self.finishWaiter(name, with: .failed(.cancelled(.byClient)))
        }
        self.resumeFinishWaiters()
    }

    // MARK: - Source-facing

    /// Whether a new background transfer may start: not disabled for the process (−995/−996/−997, transport.md
    /// §10.7), not invalidated, and fewer outstanding tasks than `maxTasks` (re-attached ones included, T2-17).
    package func admits() -> Bool {
        !self.disabled && !self.invalidated && self.live.count < max(self.options.maxTasks, 1)
    }

    /// Launch re-attachment (H-6): activates the session (so the OS delivers what finished while the app was dead),
    /// cancels foreign or undecodable tasks, and reports every live task plus every buffered staged outcome.
    package func reattached() async -> [ReattachedTransfer] {
        // REENTRANCY: D-7 (proposed) — activation; nothing is read before the listing.
        await self.activate()
        // REENTRANCY: D-7 (proposed) — the outcome buffer is read after the listing, so outcomes processed during
        // either await are reported.
        let snapshot = await self.driver.snapshot()
        var transfers: [ReattachedTransfer] = []
        for task in snapshot {
            guard let name = task.name else {
                // REENTRANCY: D-7 (proposed) — only the loop's own listing is used after this await.
                _ = await self.driver.cancel(taskIdentifier: task.taskIdentifier, producingResumeData: false)
                continue
            }
            self.live.insert(name)
            // Running or suspended in the OS: the Model's `isRunning` means "not yet completed into staging".
            transfers.append(ReattachedTransfer(name: name, isRunning: true, bytesReceived: task.bytesReceived))
        }
        for name in self.outcomeOrder {
            if let file = self.outcomes[name] {
                transfers.append(ReattachedTransfer(name: name, isRunning: false, bytesReceived: file.byteCount))
            }
        }
        self.ensurePump()
        return transfers.sorted { $0.name < $1.name }
    }

    /// Returns once the session reported `.backgroundEventsFinished`, i.e. after every event before it was
    /// delivered (R-NET-3, transport.md §10.6); at once after invalidation, or when such a report arrived before
    /// anybody waited.
    package func awaitBackgroundEvents() async {
        // REENTRANCY: D-8 (proposed) — `invalidated` and `unclaimedFinishes` are read after activation.
        await self.activate()
        if self.invalidated {
            return
        }
        if self.unclaimedFinishes > 0 {
            self.unclaimedFinishes -= 1
            return
        }
        // REENTRANCY: D-8 (proposed) — a terminal wait; resumed by the pump or by `invalidate()`, nothing re-read.
        await withCheckedContinuation { continuation in
            self.finishWaiters.append(continuation)
            self.ensurePump()
        }
    }

    /// The resume data a background pause kept for `name` (T2-05).
    package func keptResumeData(for name: StagingFileName) -> ResumeData? {
        self.resumeData[name]
    }

    /// Whether the pump task exists (T2-10: only while a background transfer is outstanding).
    package var isPumping: Bool {
        self.pump != nil
    }

    /// Sets the OS task's priority (R-NET-10).
    package func setPriority(_ priority: AssetPriority, of name: StagingFileName) async {
        let value = priority.urlSessionTaskPriority
        self.priorities[name] = value
        // REENTRANCY: D-9 (proposed) — the task is looked up in this listing, taken after `priorities` was written.
        let snapshot = await self.driver.snapshot()
        guard let task = snapshot.first(where: { $0.name == name }) else {
            return
        }
        // REENTRANCY: D-9 (proposed) — nothing is read after the last await.
        await self.driver.setPriority(taskIdentifier: task.taskIdentifier, value)
    }

    /// The consumer of `name`'s stream went away before its terminal element: cancel the OS task (`TransferHandle`).
    func consumerGone(_ name: StagingFileName) async {
        guard self.waiters.removeValue(forKey: name) != nil else {
            return
        }
        // REENTRANCY: D-5 (proposed) — the waiter was removed before the await; nothing is read after it.
        await self.cancel(name, keepingPartial: false)
    }

    // MARK: - Pump

    /// Creates the session once and keeps its event stream (ADR-028: creating it makes the OS deliver).
    private func activate() async {
        guard self.events == nil else {
            return
        }
        // REENTRANCY: D-10 (proposed) — `events` is re-read afterwards: a concurrent caller may have stored the
        // stream meanwhile; the driver returns one stream per session, so the first one stored is kept.
        let stream = await self.driver.activate()
        if self.events == nil {
            self.events = stream
        }
    }

    private var hasOutstanding: Bool {
        !self.waiters.isEmpty || !self.live.isEmpty || !self.finishWaiters.isEmpty
    }

    private func ensurePump() {
        guard self.pump == nil, !self.invalidated, let events = self.events, self.hasOutstanding else {
            return
        }
        // Detached: the pump is not actor code (no await of it runs on the actor); each event hops onto the actor
        // through `process`, which re-reads every table it touches.
        self.pump = Task.detached { [weak self] in
            for await event in events {
                guard let self, await self.process(event) else {
                    return
                }
            }
        }
    }

    /// Applies one session event; `false` (and the pump forgotten) once nothing is outstanding.
    private func process(_ event: SessionEvent) -> Bool {
        switch event {
        case .finished(let name, let update):
            self.live.remove(name)
            self.deliver(update, for: name)
        case .backgroundEventsFinished:
            if self.finishWaiters.isEmpty {
                self.unclaimedFinishes += 1
            } else {
                self.resumeFinishWaiters()
            }
        case .invalidated:
            for name in Array(self.waiters.keys) {
                self.finishWaiter(name, with: .failed(.cancelled(.byClient)))
            }
            self.resumeFinishWaiters()
        }
        guard self.hasOutstanding else {
            self.pump = nil
            return false
        }
        return true
    }

    private func deliver(_ update: TransferUpdate, for name: StagingFileName) {
        var update = update
        if case .failed(.cancelled) = update, let pause = self.pauses[name] {
            switch pause {
            case .requested, .cancellationArrived:
                self.pauses[name] = .cancellationArrived
                return
            case .dataReturned(let data):
                self.pauses[name] = nil
                update = .paused(resumable: data != nil)
            }
        } else {
            self.pauses[name] = nil
        }
        if case .failed(.transient(.backgroundSessionUnavailable, _)) = update {
            self.disabled = true
        }
        if !self.finishWaiter(name, with: update), case .staged(let file) = update {
            self.bufferOutcome(file)
        }
    }

    private func attach(_ name: StagingFileName, id: TransferID) -> any TransferHandle {
        let (updates, continuation) = AsyncStream.makeStream(of: TransferUpdate.self, bufferingPolicy: .bufferingNewest(4))
        if let previous = self.waiters.updateValue(continuation, forKey: name) {
            previous.yield(.failed(.cancelled(.byClient)))
            previous.finish()
        }
        self.live.insert(name)
        let interval = self.log.interval(.transfer, category: .transport, "background attempt \(name.attempt)")
        continuation.onTermination = { [weak self] termination in
            interval.end()
            guard case .cancelled = termination, let self else {
                return
            }
            Task {
                await self.consumerGone(name)
            }
        }
        self.ensurePump()
        return BackgroundTransferHandle(coordinator: self, name: name, id: id, updates: updates)
    }

    /// Ends `name`'s stream with `update`; `false` when nobody waits for it.
    @discardableResult
    private func finishWaiter(_ name: StagingFileName, with update: TransferUpdate) -> Bool {
        guard let continuation = self.waiters.removeValue(forKey: name) else {
            return false
        }
        continuation.yield(update)
        continuation.finish()
        return true
    }

    private func bufferOutcome(_ file: StagedFile) {
        if self.outcomes.updateValue(file, forKey: file.name) == nil {
            self.outcomeOrder.append(file.name)
        }
        while self.outcomeOrder.count > max(self.options.maxTasks, 1) {
            self.outcomes.removeValue(forKey: self.outcomeOrder.removeFirst())
        }
    }

    private func takeOutcome(for id: TransferID) -> StagedFile? {
        guard let index = self.outcomeOrder.firstIndex(where: { $0.transfer == id }) else {
            return nil
        }
        let name = self.outcomeOrder.remove(at: index)
        return self.outcomes.removeValue(forKey: name)
    }

    private func resumeFinishWaiters() {
        let waiters = self.finishWaiters
        self.finishWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// The handle of one background transfer: its controls hop to the coordinator (the driver is async), in one
/// short-lived task each; after the terminal element they find no task and change nothing.
final class BackgroundTransferHandle: TransferHandle {
    let id: TransferID
    let attempt: TransferAttempt
    let updates: AsyncStream<TransferUpdate>
    private let coordinator: BackgroundTransferCoordinator
    private let name: StagingFileName

    init(coordinator: BackgroundTransferCoordinator, name: StagingFileName, id: TransferID, updates: AsyncStream<TransferUpdate>) {
        self.coordinator = coordinator
        self.name = name
        self.id = id
        self.attempt = name.attempt
        self.updates = updates
    }

    /// Sets the OS task's priority.
    func setPriority(_ priority: AssetPriority) {
        Task { [coordinator, name] in
            await coordinator.setPriority(priority, of: name)
        }
    }

    /// Cancels producing resume data; the stream ends with `paused(resumable:)`.
    func pause() {
        Task { [coordinator, name] in
            await coordinator.cancel(name, keepingPartial: true)
        }
    }

    /// Cancels; the stream ends with `cancelled(.byClient)`.
    func cancel() {
        Task { [coordinator, name] in
            await coordinator.cancel(name, keepingPartial: false)
        }
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
