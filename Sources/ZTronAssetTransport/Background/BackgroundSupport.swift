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
/// **Size (R-NET-7).** The OS downloads a background task whole before a byte reaches us, so the cap cannot stop it
/// early: only a transfer whose `byteSize` is known and within the cap runs here, and the delegate stages exactly
/// that many bytes. **Attach-or-create.** `start(job)` first hands out a buffered outcome for the same content (a
/// download that finished while nobody waited, from any attempt: the bytes are hashed at publication, transport.md
/// §10.8), then joins the newest live OS task for the same content, and only then creates a download. A listed task
/// is joined only while no cancel or pause is ending it and its terminal was not processed yet (a listing goes stale
/// across its await). **Controls** belong to one attach: each handle carries a token, and its pause, cancel,
/// priority change or terminated stream acts only while that attach still holds the name, so a handle replaced by a
/// later attach never reaches the transfer that replaced it. **Pause.** The driver is decision-free (T2-05): a
/// pause records the intent here, the driver returns the resume data, and the cancellation the session reports
/// becomes `paused(resumable:)` whichever of the two arrives first. **Buffer.** Unclaimed successes are kept,
/// oldest dropped first, up to `maxTasks` (their files stay in staging for launch reconciliation); unclaimed
/// failures are dropped; re-attachment hands the kept successes over to launch reconciliation (ADR-028).
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

    /// One attached consumer of a name; `token` tells it apart from earlier and later attaches to that name.
    private struct Waiter {
        let token: UInt64
        let continuation: AsyncStream<TransferUpdate>.Continuation
    }

    private var events: AsyncStream<SessionEvent>?
    private var pump: Task<Void, Never>?
    private var waiters: [StagingFileName: Waiter] = [:]
    private var nextToken: UInt64 = 0
    /// Unclaimed successes, oldest dropped first past `maxTasks`.
    private var outcomes: BoundedNameTable<StagedFile>
    /// Names whose terminal event the pump processed: a listing taken before that still names the task.
    private var processed: BoundedNameTable<Bool>
    private var live: Set<StagingFileName> = []
    /// Names a cancel or pause is ending: counted from before its first await until the terminal is processed.
    private var cancelling: [StagingFileName: Int] = [:]
    private var priorities: [StagingFileName: Float] = [:]
    private var pauses: [StagingFileName: PauseState] = [:]
    /// The resume data of pauses (T2-05), oldest dropped first past `maxTasks`.
    private var resumeData: BoundedNameTable<ResumeData>
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
        self.outcomes = BoundedNameTable(capacity: options.maxTasks)
        self.processed = BoundedNameTable(capacity: Self.processedCapacity(options))
        self.resumeData = BoundedNameTable(capacity: options.maxTasks)
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
        self.outcomes = BoundedNameTable(capacity: options.maxTasks)
        self.processed = BoundedNameTable(capacity: Self.processedCapacity(options))
        self.resumeData = BoundedNameTable(capacity: options.maxTasks)
    }

    /// How many processed names are remembered: far more terminals than can be processed while one listing is
    /// awaited (a few per live task, and live tasks are capped by `maxTasks`). `maxTasks` is public configuration, so
    /// it is clamped before it is multiplied (`Int.max` must not trap, review round 3).
    private static func processedCapacity(_ options: BackgroundTransferOptions) -> Int {
        max(4 * min(max(options.maxTasks, 1), Int.max / 4), 64)
    }

    // MARK: - TransferBackend

    /// Attach-or-create by content: a buffered outcome, else a live OS task, else a new tagged download.
    package func start(_ job: TransferJob) async -> any TransferHandle {
        guard !self.invalidated else {
            return Self.refused(job, .cancelled(.byClient))
        }
        // R-NET-7: the source routes only bounded transfers here; anything else goes back to the foreground, whose
        // size guard aborts while streaming.
        guard let expected = job.expectedBytes, expected <= job.maxBytes else {
            return Self.refused(job, .transient(.backgroundSessionUnavailable(urlErrorCode: NSURLErrorUnknown), retryAfter: nil))
        }
        // REENTRANCY: D-2 (proposed) — activation; nothing is read between it and the listing below.
        await self.activate()
        // REENTRANCY: D-2 (proposed) — the listing; afterwards `invalidated`, the outcome buffer, the processed names,
        // the cancelling names and the waiters are read anew, so a terminal the pump processed meanwhile marks its
        // listed task as gone and a cancel begun meanwhile keeps its task from being joined.
        let snapshot = await self.driver.snapshot()
        guard !self.invalidated else {
            return Self.refused(job, .cancelled(.byClient))
        }
        if let name = self.outcomes.first(where: { $0.transfer == job.id }), let staged = self.outcomes.remove(name) {
            // Only bytes of the size this job expects: a checksum-less identity (identifier and path) survives a
            // manifest change of its size. Otherwise the outcome is dropped (its file is left to staging GC, R-CLN-3)
            // and a new download is created.
            if staged.byteCount == expected {
                return ImmediateTransferHandle(id: job.id, attempt: staged.name.attempt, terminal: .staged(staged))
            }
        }
        let joinable = snapshot.compactMap(\.name).filter { $0.transfer == job.id && self.isJoinable($0) }
        if let name = joinable.max(by: { $0.attempt < $1.attempt }) {
            return self.attach(name, id: job.id)
        }
        let name = job.partialName
        // This very attempt is still being created or ended: a second OS task under one name would hand one task's
        // terminal to the other's handle (a uniqueness bug, reported like a staging name clash).
        guard self.waiters[name] == nil, self.cancelling[name] == nil else {
            return Self.refused(job, .transient(.localIO(posixCode: EEXIST), retryAfter: nil))
        }
        let request: URLRequest
        switch self.requests.makeRequest(for: job) {
        case .request(let built):
            request = built
        case .refused(let violation):
            return Self.refused(job, .rejected(violation))
        }
        let priority = job.priority.urlSessionTaskPriority
        self.processed.remove(name)
        // The waiter exists before the OS can finish the task, so no completion finds nobody.
        let handle = self.attach(name, id: job.id)
        self.priorities[name] = priority
        // REENTRANCY: D-3 (proposed) — nothing is read after the start: the waiter was registered before it, and a
        // completion that raced ahead was delivered to that waiter by the pump.
        await self.driver.startDownload(request, name: name, priority: priority, expectedBytes: expected)
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

    /// Cancels the OS task writing `name`, whoever waits for it; keeping the partial is a pause, which keeps the
    /// resume data. After invalidation the session is released and nothing is controlled any more.
    package func cancel(_ name: StagingFileName, keepingPartial: Bool) async {
        // REENTRANCY: D-5 (proposed) — nothing is read after the await.
        await self.stop(name, keepingPartial: keepingPartial)
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
    /// cancels foreign or undecodable tasks, and reports every live task plus every buffered staged outcome. The
    /// reported outcomes are handed over: launch reconciliation adopts or collects their files (ADR-028), so none is
    /// handed to a later start.
    package func reattached() async -> [ReattachedTransfer] {
        // REENTRANCY: D-7 (proposed) — activation; nothing is read before the listing.
        await self.activate()
        // REENTRANCY: D-7 (proposed) — only the listing's foreign task identifiers are used until the last await;
        // the report is built from current state after it.
        let snapshot = await self.driver.snapshot()
        for task in snapshot where task.name == nil {
            // REENTRANCY: D-7 (proposed) — as above: nothing but this listing's identifiers is used meanwhile.
            _ = await self.driver.cancel(taskIdentifier: task.taskIdentifier, producingResumeData: false)
        }
        // After the last await: a listed task whose terminal the pump processed meanwhile is not live (its success,
        // if any, is in the buffer and reported once below).
        var transfers: [ReattachedTransfer] = []
        for task in snapshot {
            guard let name = task.name, self.isJoinable(name) else {
                continue
            }
            self.live.insert(name)
            // Running or suspended in the OS: the Model's `isRunning` means "not yet completed into staging".
            transfers.append(ReattachedTransfer(name: name, isRunning: true, bytesReceived: task.bytesReceived))
        }
        for outcome in self.outcomes.removeAll() {
            transfers.append(ReattachedTransfer(name: outcome.name, isRunning: false, bytesReceived: outcome.value.byteCount))
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

    /// The resume data a background pause kept for `name` (T2-05; the newest `maxTasks` pauses).
    package func keptResumeData(for name: StagingFileName) -> ResumeData? {
        self.resumeData[name]
    }

    /// Whether the pump task exists (T2-10: only while a background transfer is outstanding).
    package var isPumping: Bool {
        self.pump != nil
    }

    /// Sets the OS task's priority (R-NET-10). With a `token`, only while that attach still holds `name` (a
    /// handle's control).
    package func setPriority(_ priority: AssetPriority, of name: StagingFileName, token: UInt64? = nil) async {
        if let token, self.waiters[name]?.token != token {
            return
        }
        // REENTRANCY: D-9 (proposed) — the task is looked up in this listing, the name re-checked against the
        // processed terminals, and the attach token checked again, so a priority is recorded only for a task still
        // live and never by a handle a later attach replaced meanwhile.
        let snapshot = await self.driver.snapshot()
        if let token, self.waiters[name]?.token != token {
            return
        }
        guard !self.processed.contains(name), let task = snapshot.first(where: { $0.name == name }) else {
            return
        }
        let value = priority.urlSessionTaskPriority
        self.priorities[name] = value
        // REENTRANCY: D-9 (proposed) — nothing is read after the last await.
        await self.driver.setPriority(taskIdentifier: task.taskIdentifier, value)
    }

    /// A handle's pause or cancel: acts only while the handle's attach (`token`) still holds `name`, so a handle a
    /// later attach replaced, which already ended, never reaches the transfer that replaced it.
    package func control(_ name: StagingFileName, token: UInt64, keepingPartial: Bool) async {
        guard self.waiters[name]?.token == token else {
            return
        }
        // REENTRANCY: D-5 (proposed) — the token was checked before the await; nothing is read after it.
        await self.stop(name, keepingPartial: keepingPartial)
    }

    /// The consumer of attach `token`'s stream went away before its terminal element: cancel the OS task
    /// (`TransferHandle`), unless a later attach holds the name by now.
    package func consumerGone(_ name: StagingFileName, token: UInt64) async {
        guard self.waiters[name]?.token == token else {
            return
        }
        self.waiters.removeValue(forKey: name)
        // REENTRANCY: D-5 (proposed) — the waiter was removed before the await; nothing is read after it.
        await self.stop(name, keepingPartial: false)
    }

    // MARK: - Controls

    /// Cancels the OS task writing `name` (a pause keeps the resume data). `name` counts as cancelling from before
    /// the first await until its terminal is processed, or until the listing shows no such task, so no start joins
    /// a task this call is ending.
    private func stop(_ name: StagingFileName, keepingPartial: Bool) async {
        guard !self.invalidated, !self.processed.contains(name) else {
            return
        }
        self.cancelling[name, default: 0] += 1
        // REENTRANCY: D-5 (proposed) — activation; nothing is read before the listing.
        await self.activate()
        // REENTRANCY: D-5 (proposed) — the task is looked up in this listing, taken after every earlier await, and a
        // name whose terminal the pump processed meanwhile counts as gone although listed.
        let snapshot = await self.driver.snapshot()
        guard !self.processed.contains(name), let task = snapshot.first(where: { $0.name == name }) else {
            self.endCancelling(name)
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
            self.resumeData.set(data, for: name)
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

    private func endCancelling(_ name: StagingFileName) {
        if let count = self.cancelling[name], count > 1 {
            self.cancelling[name] = count - 1
        } else {
            self.cancelling[name] = nil
        }
    }

    /// Whether a listed task may be joined or reported live: its terminal was not processed (nor buffered) and no
    /// cancel or pause is ending it.
    private func isJoinable(_ name: StagingFileName) -> Bool {
        !self.processed.contains(name) && !self.outcomes.contains(name) && self.cancelling[name] == nil
    }

    private static func refused(_ job: TransferJob, _ failure: TransferError) -> any TransferHandle {
        ImmediateTransferHandle(id: job.id, attempt: job.attempt, terminal: .failed(failure))
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

    /// Whether the session stream still owes us something: a waiter whose terminal was not processed yet, a known
    /// live task, or an events waiter. A waiter whose cancellation the pump already absorbed for a pause waits for
    /// the pause's own call (which returns the resume data and ends it), not for the stream.
    private var hasOutstanding: Bool {
        self.waiters.keys.contains { !self.isAbsorbedPause($0) } || !self.live.isEmpty || !self.finishWaiters.isEmpty
    }

    private func isAbsorbedPause(_ name: StagingFileName) -> Bool {
        if case .cancellationArrived? = self.pauses[name] {
            return true
        }
        return false
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
            self.cancelling[name] = nil
            self.priorities[name] = nil
            self.processed.set(true, for: name)
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
            self.outcomes.set(file, for: file.name)
        }
    }

    private func attach(_ name: StagingFileName, id: TransferID) -> any TransferHandle {
        let (updates, continuation) = AsyncStream.makeStream(of: TransferUpdate.self, bufferingPolicy: .bufferingNewest(4))
        self.nextToken += 1
        let token = self.nextToken
        if let previous = self.waiters.updateValue(Waiter(token: token, continuation: continuation), forKey: name) {
            previous.continuation.yield(.failed(.cancelled(.byClient)))
            previous.continuation.finish()
        }
        self.live.insert(name)
        let interval = self.log.interval(.transfer, category: .transport, "background attempt \(name.attempt)")
        continuation.onTermination = { [weak self] termination in
            interval.end()
            guard case .cancelled = termination, let self else {
                return
            }
            Task {
                await self.consumerGone(name, token: token)
            }
        }
        self.ensurePump()
        return BackgroundTransferHandle(coordinator: self, name: name, token: token, id: id, updates: updates)
    }

    /// Ends `name`'s stream with `update`; `false` when nobody waits for it.
    @discardableResult
    private func finishWaiter(_ name: StagingFileName, with update: TransferUpdate) -> Bool {
        guard let waiter = self.waiters.removeValue(forKey: name) else {
            return false
        }
        waiter.continuation.yield(update)
        waiter.continuation.finish()
        return true
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
/// short-lived task each, and act only while this handle's attach still holds its name; after the terminal element
/// they find no task and change nothing.
package final class BackgroundTransferHandle: TransferHandle {
    /// The content being transferred.
    package let id: TransferID
    /// The attempt whose OS task this handle follows (an earlier attempt's when it joined a live task).
    package let attempt: TransferAttempt
    /// Progress, then exactly one terminal element.
    package let updates: AsyncStream<TransferUpdate>
    /// The staging name the OS task writes.
    package let name: StagingFileName
    /// Which attach of `name` this handle is (the coordinator's control check).
    package let token: UInt64
    private let coordinator: BackgroundTransferCoordinator

    init(coordinator: BackgroundTransferCoordinator, name: StagingFileName, token: UInt64, id: TransferID, updates: AsyncStream<TransferUpdate>) {
        self.coordinator = coordinator
        self.name = name
        self.token = token
        self.id = id
        self.attempt = name.attempt
        self.updates = updates
    }

    /// Sets the OS task's priority.
    package func setPriority(_ priority: AssetPriority) {
        Task { [coordinator, name, token] in
            await coordinator.setPriority(priority, of: name, token: token)
        }
    }

    /// Cancels producing resume data; the stream ends with `paused(resumable:)`.
    package func pause() {
        Task { [coordinator, name, token] in
            await coordinator.control(name, token: token, keepingPartial: true)
        }
    }

    /// Cancels; the stream ends with `cancelled(.byClient)`.
    package func cancel() {
        Task { [coordinator, name, token] in
            await coordinator.control(name, token: token, keepingPartial: false)
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
