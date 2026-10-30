import Foundation
import Synchronization
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// L5-R13's seeded, randomized model of event-stream continuity across reopens (orchestrator ruling L5-R13, findings
/// L5-C1-00, L5-C1-03 and L5-C1-04; its oracle tightened by ruling L5-R19, finding L5-C2-00; `docs/adr-drafts/g.md`
/// G-2 and G-16, whose exemption table lists every tolerance of the checks below and the ruling that grants it), in the
/// shape of L4-R20's gate model.
///
/// A walk builds a client over the harness's fakes, starts it and, from its seed, interleaves consumer actions
/// (`subscribe()`; `events` and a first pull; pulls; dropping a stream; cancelling a consumer), reopens (a wiped root and
/// `purge(.all)`, parked or not at one of the lifecycle's seam points, with consumer actions and publishing calls while
/// parked), calls that publish terminal events on whichever engine serves them (`resolve` of a fresh on-demand asset, the
/// walk's *markers*; `performMaintenance`; `sync(.force)`) and, last, `shutdown()`, sometimes while a reopen is parked.
/// Every reopen that leaves a replacement installed is followed by a marker, before any consumer pulls again. The oracle
/// is a direct subscriber the walk registers on every engine before it can publish: generation 0 before `start()`, each
/// replacement at `LifecycleSeamPoint.replacementBuilt`, before it is installed. Every consumer still live at the
/// shutdown then drains its stream, and the walk checks:
/// - **I1 no loss.** A consumer receives every marker whose call began after its registration (or a later event of the
///   marker's subject: the engine's per-subject coalescing), and, from every generation installed after its follow turn
///   (the lifecycle turn that recorded it as a follower: within `subscribe()`, or an `events` stream's first pull, which
///   the walk waits for and stamps through the lifecycle's follower hook, also while a reopen is parked; L5-R21), that
///   generation's `clientStarted` whenever the oracle saw one (client lifecycle events are never coalesced with each
///   other, L5-R19) and every other terminal event the oracle saw, or a later one of the same subject, inside that
///   generation's own part of the stream: the parts are delimited by the received markers and the generations'
///   `clientStarted`, counted rather than looked up by value, because replacements announce equal values. Progress
///   events coalesce in place and are not checked. From the generation it registered with (Stage 3 ruling S3G-2,
///   L5-R22 (2)): that generation's `clientStarted` when the walk saw the registration land while the engine had not
///   started yet (the engine's lifecycle read in the turn that registered the stream), and the terminal event of every
///   `performMaintenance` and `sync(.force)` call that generation served after the registration (the calls are stamped
///   like the markers), or a later one of its subject, inside that generation's part.
/// - **I2 order.** The markers a consumer receives never go back a generation and none arrives twice; no
///   `clientShutDown` arrives before the real shutdown began (a retired engine's is never forwarded), at most one arrives,
///   and it is the last event; every consumer live at the shutdown ends with it; no more `clientStarted` events arrive
///   between two received markers than the generations between them published, the registration generation's own
///   counted in the first gap only when the walk could not tell its start from the registration (a `subscribe()` that
///   started that engine itself, or one made while a reopen was parked before its install).
/// - **I3 no leak.** At idle, after every stream ended: the lifecycle has no follower entry (a forwarder whose pump
///   started is removed only when that pump ends, so none also means no pump task is left), and no engine the walk saw has
///   a subscriber.
/// - **I4 bounded.** After every step, and after every action made while a reopen is parked, at most one event waits in
///   each forwarder (R-SYN-12).
/// Every wait is a condition that ends on cancellation (L5-R14). A violation prints its seed and the walk so far; a walk
/// cut short by the time limit prints the walk it stopped in. `EVENT_MODEL_SEEDS=3,17` replays chosen walks;
/// `EVENT_MODEL_SEED_COUNT=5000` runs seeds 0 to 4,999; `EVENT_MODEL_TRACE=<file>` appends every walk's actions to that
/// file as they happen (a test runner's buffered output can be lost when a run is stopped).
@Suite("Event continuity model, close-out cycle 2")
struct EventContinuityModelTests {
    /// The suite's walks (L5-R13: at least 500), spread over `cases` test cases that run in parallel, each under its
    /// own time limit (L4-R8).
    static let suiteSeeds: UInt64 = 500
    static let cases = 10

    /// SplitMix64: the walk's own deterministic generator (system randomness stays out of tests, C4).
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = self.state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        /// A value in `0..<bound`.
        mutating func below(_ bound: Int) -> Int {
            Int(self.next() % UInt64(bound))
        }
    }

    /// The seeds of case `index`: every seed `EVENT_MODEL_SEEDS` lists (all in case 0), or every seed below
    /// `EVENT_MODEL_SEED_COUNT` (default `suiteSeeds`) that is congruent to `index` modulo `cases`.
    static func seeds(forCase index: Int) -> [UInt64] {
        let environment = ProcessInfo.processInfo.environment
        if let listed = environment["EVENT_MODEL_SEEDS"] {
            return index == 0 ? listed.split(separator: ",").compactMap { UInt64($0) } : []
        }
        let count = environment["EVENT_MODEL_SEED_COUNT"].flatMap { UInt64($0) } ?? Self.suiteSeeds
        return Array(stride(from: UInt64(index), to: count, by: Self.cases))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-12: seeded walks over subscriptions, pulls, drops, cancellations, parked reopens, publishing calls and shutdown lose no event a stream is owed, keep each stream's generations in order, leak no follower or subscriber, and buffer at most one event per forwarder",
        .timeLimit(.minutes(2)),
        arguments: 0..<10
    )
    func eventContinuityModel(case index: Int) async throws {
        for seed in Self.seeds(forCase: index) {
            if let violation = await ModelWalk.run(seed: seed) {
                Issue.record("seed \(seed): \(violation)")
                return
            }
        }
    }
}

// MARK: - Shared state of a walk

/// The walk's action counter: the walk ticks it at each action, and consumers stamp every event they receive with it,
/// so a check can tell whether an event arrived before a reopen or the shutdown began.
@available(macOS 15.0, iOS 18.0, *)
final class ModelClock: Sendable {
    private let value = Mutex<Int>(0)

    /// Moves to the next action and returns it.
    @discardableResult
    func tick() -> Int {
        self.value.withLock { value in
            value += 1
            return value
        }
    }

    /// The action in progress.
    var now: Int {
        self.value.withLock { $0 }
    }
}

/// The events one stream delivered, each stamped with the walk's action in progress when it arrived. `wait(forCount:)`
/// is a condition wait that ends when the count is reached, when the stream ended or was abandoned, or on cancellation.
@available(macOS 15.0, iOS 18.0, *)
final class ModelRecord: Sendable {
    /// One delivered event.
    struct Entry: Sendable {
        let event: AssetEvent
        let at: Int
    }

    private struct State {
        var entries: [Entry] = []
        var closed = false
        var waiters: [UInt64: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
        var lastWaiter: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Records `event`.
    func append(_ event: AssetEvent, at: Int) {
        let ready = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.entries.append(Entry(event: event, at: at))
            return ModelRecord.takeReady(&state)
        }
        ready.forEach { $0.resume() }
    }

    /// The stream ended, or the walk stopped reading it: no wait for more events is useful.
    func close() {
        let ready = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.closed = true
            return ModelRecord.takeReady(&state)
        }
        ready.forEach { $0.resume() }
    }

    /// The events so far.
    var entries: [Entry] {
        self.state.withLock { $0.entries }
    }

    /// Suspends until `count` events arrived or the record closed, or until the caller is cancelled.
    func wait(forCount count: Int) async {
        let id = self.state.withLock { state -> UInt64 in
            state.lastWaiter += 1
            return state.lastWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = self.state.withLock { state -> Bool in
                    if state.entries.count >= count || state.closed || Task.isCancelled {
                        return true
                    }
                    state.waiters[id] = (count, continuation)
                    return false
                }
                if now {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    private static func takeReady(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        let ready = state.waiters.filter { state.closed || state.entries.count >= $0.value.count }
        for id in ready.keys {
            state.waiters[id] = nil
        }
        return ready.values.map(\.continuation)
    }
}

/// The lifecycle's follower counts, fed by its test hook: the follower entries now, and the followers ever recorded (one
/// per follow turn). Its waits are conditions that end on cancellation.
@available(macOS 15.0, iOS 18.0, *)
final class FollowerGauge: Sendable {
    private struct State {
        var count = 0
        var recorded: UInt64 = 0
        var waiters: [UInt64: (met: @Sendable (Int, UInt64) -> Bool, continuation: CheckedContinuation<Void, Never>)] = [:]
        var lastWaiter: UInt64 = 0
    }

    private let state = Mutex(State())

    /// The lifecycle reports its counts.
    func set(_ count: Int, recorded: UInt64) {
        let ready = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.count = count
            state.recorded = recorded
            let ready = state.waiters.filter { $0.value.met(count, recorded) }
            for id in ready.keys {
                state.waiters[id] = nil
            }
            return ready.values.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    /// The last count of follower entries reported.
    var count: Int {
        self.state.withLock { $0.count }
    }

    /// The followers recorded so far, as last reported.
    var recorded: UInt64 {
        self.state.withLock { $0.recorded }
    }

    /// Suspends until at most `target` followers are left, or until the caller is cancelled.
    func wait(atMost target: Int) async {
        await self.wait { count, _ in count <= target }
    }

    /// Suspends until at least `target` followers are recorded at once, or until the caller is cancelled.
    func wait(atLeast target: Int) async {
        await self.wait { count, _ in count >= target }
    }

    /// Suspends until at least `target` followers were ever recorded (that many follow turns ran), or until the caller is
    /// cancelled.
    func wait(recordedAtLeast target: UInt64) async {
        await self.wait { _, recorded in recorded >= target }
    }

    private func wait(until met: @escaping @Sendable (Int, UInt64) -> Bool) async {
        let id = self.state.withLock { state -> UInt64 in
            state.lastWaiter += 1
            return state.lastWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = self.state.withLock { state -> Bool in
                    if met(state.count, state.recorded) || Task.isCancelled {
                        return true
                    }
                    state.waiters[id] = (met, continuation)
                    return false
                }
                if now {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }
}

/// The walk so far, printed when a violation is reported or the time limit cuts the walk short.
@available(macOS 15.0, iOS 18.0, *)
final class ModelTrace: Sendable {
    private let lines = Mutex<[String]>([])

    /// Appends `line`.
    func note(_ line: String) {
        self.lines.withLock { $0.append(line) }
        ModelTrace.write(line)
    }

    /// `EVENT_MODEL_TRACE=<path>` appends every line to that file as the walk goes (replaying a seed: a test runner's
    /// output can be lost when a walk is stopped).
    static let traceFile: FileHandle? = ProcessInfo.processInfo.environment["EVENT_MODEL_TRACE"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    /// Appends `line` to the trace file, if one is set.
    static func write(_ line: String) {
        ModelTrace.traceFile?.write(Data("\(line)\n".utf8))
    }

    /// The walk, one action per line.
    var text: String {
        self.lines.withLock { $0.joined(separator: "\n  ") }
    }
}

/// A consumer of one client stream: its own task pulls on command, so a stream can stay unpulled while a reopen runs.
@available(macOS 15.0, iOS 18.0, *)
final class ModelConsumer: Sendable {
    /// How the stream was made.
    enum Kind: Sendable, CustomStringConvertible {
        case subscribed
        case events

        var description: String {
            self == .subscribed ? "subscribe()" : "events"
        }
    }

    /// What the consumer's task does next.
    enum Command: Sendable {
        /// Pull up to `count` events (each pull waits for an event).
        case pull(Int)
        /// Pull until the stream ends.
        case drain
        /// Stop reading and drop the stream without cancelling.
        case drop
    }

    let id: Int
    let kind: Kind
    let record: ModelRecord
    let task: Task<Void, Never>
    private let commands: AsyncStream<Command>.Continuation

    init(id: Int, kind: Kind, stream: AsyncStream<AssetEvent>, clock: ModelClock) {
        let record = ModelRecord()
        let (commandStream, commands) = AsyncStream.makeStream(of: Command.self)
        self.id = id
        self.kind = kind
        self.record = record
        self.commands = commands
        self.task = Task {
            var iterator = stream.makeAsyncIterator()
            var ended = false
            for await command in commandStream {
                switch command {
                case .pull(let count):
                    var pulled = 0
                    while pulled < count, !ended {
                        pulled += 1
                        if let event = await iterator.next() {
                            record.append(event, at: clock.now)
                        } else {
                            ended = true
                        }
                    }
                case .drain:
                    while !ended {
                        if let event = await iterator.next() {
                            record.append(event, at: clock.now)
                        } else {
                            ended = true
                        }
                    }
                case .drop:
                    record.close()
                    return
                }
                if ended {
                    record.close()
                }
            }
            record.close()
        }
    }

    /// Queues `command` for the consumer's task.
    func send(_ command: Command) {
        self.commands.yield(command)
    }

    /// No more commands: the task ends once the queued ones ran.
    func finish() {
        self.commands.finish()
    }
}

/// A direct subscriber of one engine, the walk's oracle for that generation.
@available(macOS 15.0, iOS 18.0, *)
final class ModelTap: Sendable {
    let generation: UInt64
    let engine: SyncEngine
    let record: ModelRecord
    let task: Task<Void, Never>

    init(generation: UInt64, engine: SyncEngine, stream: AsyncStream<AssetEvent>) {
        let record = ModelRecord()
        self.generation = generation
        self.engine = engine
        self.record = record
        self.task = Task {
            for await event in stream {
                record.append(event, at: 0)
            }
            record.close()
        }
    }
}

/// The oracle taps by generation.
@available(macOS 15.0, iOS 18.0, *)
final class ModelOracles: Sendable {
    private let taps = Mutex<[UInt64: ModelTap]>([:])

    /// Subscribes a tap to `core`'s engine: before `start()` for generation 0, at `replacementBuilt` for a replacement,
    /// so it sees everything the engine publishes.
    func attach(_ core: ClientCore) async {
        guard case .success(let stream) = await core.engine.subscribe() else {
            return
        }
        let tap = ModelTap(generation: core.generation, engine: core.engine, stream: stream)
        self.taps.withLock { $0[core.generation] = tap }
    }

    /// The tap of `generation`, if one is attached.
    func tap(_ generation: UInt64) -> ModelTap? {
        self.taps.withLock { $0[generation] }
    }

    /// Every tap, by generation.
    var all: [ModelTap] {
        self.taps.withLock { taps in
            taps.keys.sorted().compactMap { taps[$0] }
        }
    }
}

/// The seam points a walk parks reopens at.
enum ModelPark: Sendable, CustomStringConvertible {
    case willShutDown
    case built
    case observesPressure
    case registrationAnswered

    init?(_ point: LifecycleSeamPoint) {
        switch point {
        case .reopenWillShutDownEngine:
            self = .willShutDown
        case .replacementBuilt:
            self = .built
        case .replacementObservesPressure:
            self = .observesPressure
        case .registrationAnswered:
            self = .registrationAnswered
        case .pressureRecorded, .shutdownWillWaitForReopen:
            return nil
        }
    }

    /// Whether the replacement is not installed yet there: every call waits for the reopen.
    var beforeInstall: Bool {
        self == .willShutDown || self == .built
    }

    var description: String {
        switch self {
        case .willShutDown:
            return "reopenWillShutDownEngine"
        case .built:
            return "replacementBuilt"
        case .observesPressure:
            return "replacementObservesPressure"
        case .registrationAnswered:
            return "registrationAnswered"
        }
    }
}

/// Parks the next arrival at the armed point on a `SeamHold` (one park per arming), and tells the walk whether the
/// reopen parked there or finished first (`waitForPark()`, a condition wait that ends on cancellation).
@available(macOS 15.0, iOS 18.0, *)
actor ModelParking {
    private var armed: (park: ModelPark, hold: SeamHold)?
    /// Whether the last arming parked an arrival (`true`) or its reopen finished first (`false`); `nil` until known.
    private var outcome: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    /// Arms `park`; the hold parks the next arrival there.
    func arm(_ park: ModelPark) -> SeamHold {
        let hold = SeamHold()
        self.armed = (park, hold)
        self.outcome = nil
        return hold
    }

    /// The reopening call finished: an arming no arrival consumed is void.
    func callFinished() {
        self.armed = nil
        self.decide(false)
    }

    /// Whether the armed point parked the reopen (`false`: the call finished first, or the caller was cancelled).
    func waitForPark() async -> Bool {
        if let outcome = self.outcome {
            return outcome
        }
        // REENTRANCY: nothing is re-read — a terminal wait resumed once by `decide` (or the cancellation hop).
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if let outcome = self.outcome {
                    continuation.resume(returning: outcome)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    self.waiter = continuation
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: nothing — the hop resumes only a wait still pending.
                await self.cancelWait()
            }
        }
    }

    /// The lifecycle's seam arrived at `point`.
    func arrive(_ point: LifecycleSeamPoint) async {
        guard let armed = self.armed, ModelPark(point) == armed.park else {
            return
        }
        self.armed = nil
        self.decide(true)
        // REENTRANCY: nothing is re-read — a terminal wait on the hold, which the walk opens (an open that comes first
        // lets this arrival pass).
        await armed.hold.arrive()
    }

    private func decide(_ parked: Bool) {
        guard self.outcome == nil else {
            return
        }
        self.outcome = parked
        self.waiter?.resume(returning: parked)
        self.waiter = nil
    }

    private func cancelWait() {
        self.waiter?.resume(returning: false)
        self.waiter = nil
    }
}

extension SyncEngine {
    /// Suspends until the engine has no subscriber, also once it is shut down (its own waits answer at once then), or
    /// until the caller is cancelled (I3 of the L5-R13 model).
    func awaitNoSubscribers() async {
        guard !self.state.subscribers.isEmpty else {
            return
        }
        self.state.lastObserver += 1
        let id = self.state.lastObserver
        // REENTRANCY: nothing is re-read — a terminal test wait registered synchronously and resumed once, by the
        // mutation that removed the last subscriber or by the cancellation hop.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if self.state.subscribers.isEmpty || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.state.conditionObservers[id] = ConditionObserver(condition: { $0.state.subscribers.isEmpty }, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: nothing — the hop removes only this wait (a no-op once it was resumed).
                await self.cancelModelWait(id)
            }
        }
    }

    private func cancelModelWait(_ id: UInt64) {
        self.state.conditionObservers.removeValue(forKey: id)?.continuation.resume()
    }

    /// The lifecycle in the turn that registered the first subscriber after `key` (Stage 3 ruling S3G-2), or, when that
    /// registration came before this call, the lifecycle now; `nil` when the wait ended without one (the engine shut
    /// down, or the caller was cancelled).
    @available(macOS 15.0, iOS 18.0, *)
    func lifecycleAtRegistration(after key: UInt64) async -> EngineLifecycle? {
        let seen = ModelLifecycleProbe()
        // REENTRANCY: nothing is re-read — a terminal test wait; its condition records the lifecycle in the turn it holds.
        await self.awaitCondition { engine in
            guard engine.state.lastSubscriber > key else {
                return false
            }
            seen.note(engine.state.lifecycle)
            return true
        }
        return seen.value
    }
}

/// The first lifecycle an engine-turn condition saw (`SyncEngine.lifecycleAtRegistration(after:)`).
@available(macOS 15.0, iOS 18.0, *)
final class ModelLifecycleProbe: Sendable {
    private let seen = Mutex<EngineLifecycle?>(nil)

    /// Records `lifecycle` unless one was recorded already.
    func note(_ lifecycle: EngineLifecycle) {
        self.seen.withLock { $0 = $0 ?? lifecycle }
    }

    /// The recorded lifecycle.
    var value: EngineLifecycle? {
        self.seen.withLock { $0 }
    }
}

// MARK: - The walk

/// One seeded walk (not `Sendable`: it runs in its test case's task only; the tasks it starts capture its `Sendable`
/// parts).
@available(macOS 15.0, iOS 18.0, *)
private final class ModelWalk {
    static let catalogSize = 40
    static let steps = 10
    static let maxReopens = 3
    static let maxLive = 5

    /// One consumer as the walk sees it.
    struct Consumer {
        enum Status {
            case live
            case dropped
            case cancelled
        }

        let consumer: ModelConsumer
        /// The action after which its registration is known to have completed (`nil` until then).
        var registeredAt: Int?
        /// The action stamped right after its follow turn, the lifecycle turn that recorded it as a follower (`nil` until
        /// then): every generation installed after it was handed to it from its first event (orchestrator rulings L5-R13,
        /// L5-R19; L5-R21 stamps an `events` stream here rather than at its first event, L5-C2-04).
        var followedAt: Int?
        /// The generation serving when it registered: the engine its stream reads first (`nil` until known).
        var registeredWith: UInt64?
        /// Whether that engine's `clientStarted` came after the registration (owed), before it (never delivered), or
        /// either (the walk could not tell; Stage 3 ruling S3G-2, L5-R22 (2)).
        var startOrder = StartOrder.unknown
        var status = Status.live
    }

    /// The registration engine's start against the registration, as the walk observed it.
    enum StartOrder {
        /// The engine had broadcast its `clientStarted` before the action that registered the stream began.
        case before
        /// The engine had not started in the turn that registered the stream: its `clientStarted` is owed.
        case after
        /// Not observed.
        case unknown
    }

    /// A `performMaintenance` or `sync(.force)` call that the walk awaited (not one started while a reopen was parked
    /// before its install): the generation serving it, the oracle log's length for that generation when it began, and
    /// the terminal event its result names.
    struct Call {
        let label: String
        let startedAt: Int
        let generation: UInt64
        let logStart: Int
        let published: Published
    }

    /// The terminal event a call's result names: `maintenanceFinished` with the returned report, published in the turn
    /// that returned it; `syncFinished` with the returned outcome of a run (a run resumes its joiners in the turn that
    /// publishes it; `.failed` and `.notDue` can return without a run, so they name nothing).
    enum Published {
        case maintenance(MaintenanceReport)
        case sync(SyncOutcome)

        func matches(_ event: AssetEvent) -> Bool {
            switch (self, event) {
            case (.maintenance(let report), .maintenanceFinished(let published)):
                return report == published
            case (.sync(let outcome), .syncFinished(_, let published)):
                return outcome == published
            default:
                return false
            }
        }
    }

    /// What a consumer is owed by the generation it registered with, beyond the markers (Stage 3 ruling S3G-2).
    struct Registration {
        let generation: UInt64?
        let log: [AssetEvent]
        /// Its `clientStarted` is owed in the first gap.
        let owesStart: Bool
        /// Its `clientStarted` may arrive in the first gap (the walk could not tell).
        let mayStart: Bool
        /// The calls it served after the registration.
        let calls: [Call]

        static let none = Registration(generation: nil, log: [], owesStart: false, mayStart: false, calls: [])
    }

    /// A marker call and the action it began in.
    struct Marker {
        let id: AssetID
        let startedAt: Int
    }

    /// Work started while a reopen was parked before its install, settled once the reopen finished.
    enum Pending {
        case subscribe(Task<Result<AsyncStream<AssetEvent>, AssetError>, Never>)
        case call(Task<Void, Never>)
        case firstEvent(Int)
    }

    /// The walk's steps.
    enum Action {
        case subscribe
        case events
        case pull
        case drop
        case cancel
        case marker
        case maintenance
        case sync
        case reopen(ModelPark?)
    }

    let seed: UInt64
    var random: EventContinuityModelTests.SplitMix
    let harness: KitHarness
    let client: AssetClient
    let catalog: [(entry: ManifestEntry, bytes: Data)]
    let parkedEntry: ManifestEntry
    let clock = ModelClock()
    let oracles = ModelOracles()
    let gauge = FollowerGauge()
    let parking = ModelParking()
    let trace = ModelTrace()
    var consumers: [Consumer] = []
    var markers: [Marker] = []
    var nextMarker = 0
    var calls: [Call] = []
    /// The generation installed now: the one a registration or a call made now reaches.
    var serving: UInt64 = 0
    var pending: [Pending] = []
    /// The action stamped no later than each replacement's installation: its reopen's first action, or, for a reopen
    /// parked before its install, the action that releases it (L5-R21: generations are owed by installation).
    var installedAt: [UInt64: Int] = [:]
    /// The generations installed at some point.
    var installed: Set<UInt64> = [0]
    var shutdownAt: Int?
    var parked: ModelPark?
    var reopens = 0
    var prefetch: PrefetchHandle?
    var violations: [String] = []

    init(seed: UInt64) {
        self.seed = seed
        self.random = EventContinuityModelTests.SplitMix(state: seed &* 0xD1B5_4A32_D192_ED03 &+ 0x8CB9_2BA7_2F3D_8DD7)
        self.catalog = (0..<ModelWalk.catalogSize).map { index in
            let bytes = KitFixture.bytes(40_000 + UInt64(index), count: 64)
            return (KitFixture.entry("m\(index)", bytes, policy: .onDemand), bytes)
        }
        self.parkedEntry = KitFixture.entry("p", KitFixture.bytes(39_999, count: 64), policy: .onDemand)
        self.harness = KitHarness.make()
        self.client = self.harness.client
    }

    /// Runs the walk for `seed`; a violation, or `nil`.
    static func run(seed: UInt64) async -> String? {
        let walk = ModelWalk(seed: seed)
        let trace = walk.trace
        let violation = await withTaskCancellationHandler {
            await walk.execute()
        } onCancel: {
            let text = "EVENT MODEL seed \(seed): cancelled (time limit) in this walk:\n  \(trace.text)\n"
            ModelTrace.write(text)
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        await walk.cleanUp()
        return violation
    }

    /// After a walk that stopped early: shuts the client down and stops the walk's tasks (each a no-op after a whole
    /// walk, where everything already ended).
    private func cleanUp() async {
        await self.client.shutdown()
        for consumer in self.consumers {
            consumer.consumer.task.cancel()
            consumer.consumer.finish()
        }
        for tap in self.oracles.all {
            tap.task.cancel()
        }
        self.prefetch = nil
    }

    private func execute() async -> String? {
        do {
            try await self.setUp()
            for _ in 0..<ModelWalk.steps {
                try await self.step(self.chooseAction())
                if let violation = await self.bufferedViolation() {
                    return self.report(violation)
                }
            }
            try await self.shutDownPhase()
            await self.drainAndIdle()
        } catch {
            return self.report("the walk threw \(error)")
        }
        self.checkStreams()
        return self.violations.first.map { self.report($0) }
    }

    private func report(_ violation: String) -> String {
        "\(violation)\n  walk:\n  \(self.trace.text)"
    }

    private func note(_ line: String) {
        self.trace.note("t\(self.clock.now) \(line)")
    }

    private func violation(_ text: String) {
        self.violations.append(text)
        self.note("VIOLATION: \(text)")
    }

    // MARK: Setup

    private func setUp() async throws {
        let manifest = KitFixture.manifestData(self.catalog.map(\.entry) + [self.parkedEntry])
        await self.harness.source.scriptManifest((0..<64).map { .fetched(manifest, etag: KitFixture.etag("v\($0)")) })
        let gauge = self.gauge
        let oracles = self.oracles
        let parking = self.parking
        await self.client.lifecycle.setFollowerObserver { count, recorded in
            gauge.set(count, recorded: recorded)
        }
        let trace = self.trace
        await self.client.lifecycle.setSeam { point in
            trace.note("  seam \(ModelPark(point).map(String.init(describing:)) ?? "other")")
            if case .replacementBuilt(let core) = point {
                await oracles.attach(core)
                trace.note("  oracle attached to generation \(core.generation)")
            }
            await parking.arrive(point)
        }
        await oracles.attach(await self.client.lifecycle.current())
        try await self.harness.startAndSettle()
        if self.seed % 2 == 0 {
            let handle = self.client.prefetch([self.parkedEntry.identifier])
            try await handle.awaitRegistration()
            self.prefetch = handle
        }
        self.note("seed \(self.seed): started; prefetch group \(self.prefetch != nil)")
    }

    // MARK: Steps

    private var live: [Int] {
        self.consumers.indices.filter { self.consumers[$0].status == .live }
    }

    private func chooseAction() -> Action {
        var table: [(Action, Int)] = [(.subscribe, 3), (.events, 2), (.pull, 4), (.drop, 1), (.cancel, 1), (.marker, 3), (.maintenance, 1), (.sync, 1)]
        if self.reopens < ModelWalk.maxReopens {
            var parks: [ModelPark?] = [nil, .willShutDown, .built, .built, .observesPressure]
            if self.prefetch != nil {
                parks.append(.registrationAnswered)
            }
            table.append((.reopen(parks[self.random.below(parks.count)]), 3))
        }
        var pick = self.random.below(table.reduce(0) { $0 + $1.1 })
        for (action, weight) in table {
            if pick < weight {
                return action
            }
            pick -= weight
        }
        return .pull
    }

    private func step(_ action: Action) async throws {
        self.note("step \(action)")
        switch action {
        case .subscribe:
            await self.subscribe()
        case .events:
            await self.openEvents()
        case .pull:
            self.pull()
        case .drop:
            self.drop()
        case .cancel:
            self.cancel()
        case .marker:
            await self.publishMarker()
        case .maintenance:
            await self.maintain()
        case .sync:
            await self.forceSync()
        case .reopen(let park):
            try await self.reopen(parkingAt: park, thenShutDown: false)
        }
    }

    /// One action while a reopen is parked.
    private func innerAction() async {
        switch self.random.below(7) {
        case 0:
            await self.subscribe()
        case 1:
            await self.openEvents()
        case 2:
            self.pull()
        case 3:
            self.drop()
        case 4:
            self.cancel()
        case 5:
            await self.publishMarker()
        default:
            await self.maintain()
        }
    }

    private func addConsumer(
        _ kind: ModelConsumer.Kind,
        _ stream: AsyncStream<AssetEvent>,
        registered: Bool,
        startOrder: StartOrder = .unknown
    ) -> Int {
        let consumer = ModelConsumer(id: self.consumers.count, kind: kind, stream: stream, clock: self.clock)
        let registeredAt = registered ? self.clock.tick() : nil
        // A `subscribe()` stream follows in its call, before it returns (or, started while a reopen was parked before its
        // install, after that reopen, once the call settled): its registration stamp is its follow stamp too.
        var state = Consumer(consumer: consumer, registeredAt: registeredAt, followedAt: registeredAt)
        state.registeredWith = self.serving
        state.startOrder = startOrder
        self.consumers.append(state)
        self.note("consumer \(consumer.id) (\(kind)) added, registered \(registeredAt.map(String.init) ?? "later") with generation \(self.serving) (start \(startOrder))")
        return self.consumers.count - 1
    }

    /// The serving engine's lifecycle and the key of its newest subscriber, read in one engine turn.
    private func servingState() async -> (lifecycle: EngineLifecycle, lastSubscriber: UInt64)? {
        guard let tap = self.oracles.tap(self.serving) else {
            return nil
        }
        return await tap.engine.kitRead { ($0.state.lifecycle, $0.state.lastSubscriber) }
    }

    /// Whether `lifecycle` is before the turn that broadcasts `clientStarted` (that turn makes the engine `running`).
    private static func isUnstarted(_ lifecycle: EngineLifecycle) -> Bool {
        lifecycle == .created || lifecycle == .starting
    }

    private func subscribe() async {
        guard self.live.count < ModelWalk.maxLive else {
            return self.pull()
        }
        self.clock.tick()
        let harness = self.harness
        let client = self.client
        let call = { @Sendable () async -> Result<AsyncStream<AssetEvent>, AssetError> in
            do throws(AssetError) {
                return .success(try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
                    try await client.subscribe()
                })
            } catch {
                return .failure(error)
            }
        }
        if self.parked?.beforeInstall == true {
            self.pending.append(.subscribe(Task { await call() }))
            self.note("subscribe() started while parked at \(self.parked.map(String.init(describing:)) ?? "")")
            return
        }
        // An engine already started had broadcast its clientStarted before this call registered; an unstarted one is
        // started by the call itself (`subscribe()` awaits `start()`), which the walk does not see from outside.
        let before = await self.servingState()
        let order: StartOrder = before.map { ModelWalk.isUnstarted($0.lifecycle) ? .unknown : .before } ?? .unknown
        switch await call() {
        case .success(let stream):
            _ = self.addConsumer(.subscribed, stream, registered: true, startOrder: order)
        case .failure(let error):
            self.violation("subscribe() failed before the shutdown: \(error)")
        }
    }

    private func openEvents() async {
        guard self.live.count < ModelWalk.maxLive else {
            return self.pull()
        }
        self.clock.tick()
        let recorded = self.gauge.recorded
        let before = await self.servingState()
        let index = self.addConsumer(.events, self.client.events, registered: false)
        self.consumers[index].consumer.send(.pull(1))
        // Its first pull makes it a follower, in a lifecycle turn that also runs while a reopen is parked (the walk's
        // other follows have all happened): the walk waits for that turn and stamps it, so the generations installed after
        // it are owed from their first events, path 5 of G-16 included (L5-R21, L5-C2-04).
        await self.gauge.wait(recordedAtLeast: recorded + 1)
        self.consumers[index].followedAt = self.clock.tick()
        self.note("consumer \(index) followed")
        // The serving engine's clientStarted against the registration (S3G-2): broadcast already, or not yet in the turn
        // that registered this stream. An unstarted serving engine is an installed replacement whose reopen is parked
        // before its start finished. The registration lands at once, and the walk awaited every earlier action (and the
        // registration of every earlier stream that met the engine unstarted), so nothing else registers with that engine
        // meanwhile: the first subscriber after the one read before is this stream's.
        if let before {
            if !ModelWalk.isUnstarted(before.lifecycle) {
                self.consumers[index].startOrder = .before
            } else if let tap = self.oracles.tap(self.serving), let atRegistration = await tap.engine.lifecycleAtRegistration(after: before.lastSubscriber) {
                self.consumers[index].startOrder = ModelWalk.isUnstarted(atRegistration) ? .after : .unknown
                self.note("consumer \(index) registered with unstarted generation \(self.serving): \(atRegistration)")
            }
        }
        if self.parked != nil {
            // Its first event may need the parked reopen to finish.
            self.pending.append(.firstEvent(index))
            return
        }
        await self.consumers[index].consumer.record.wait(forCount: 1)
        self.consumers[index].registeredAt = self.clock.tick()
        self.note("consumer \(index) registered (first event)")
    }

    private func pull() {
        let live = self.live
        guard !live.isEmpty else {
            return
        }
        let index = live[self.random.below(live.count)]
        let count = 1 + self.random.below(3)
        self.clock.tick()
        self.consumers[index].consumer.send(.pull(count))
        self.note("consumer \(index) pulls \(count)")
    }

    private func drop() {
        let live = self.live
        guard !live.isEmpty else {
            return
        }
        let index = live[self.random.below(live.count)]
        self.clock.tick()
        self.consumers[index].status = .dropped
        self.consumers[index].consumer.send(.drop)
        self.consumers[index].consumer.record.close()
        self.note("consumer \(index) dropped")
    }

    private func cancel() {
        let live = self.live
        guard !live.isEmpty else {
            return
        }
        let index = live[self.random.below(live.count)]
        self.clock.tick()
        self.consumers[index].status = .cancelled
        self.consumers[index].consumer.task.cancel()
        self.consumers[index].consumer.record.close()
        self.note("consumer \(index) cancelled")
    }

    /// Runs `call`, or starts it in a task settled after the reopen when one is parked before its install (every call
    /// then waits for the reopen).
    private func invoke(_ label: String, _ call: @escaping @Sendable () async -> Void) async {
        if self.parked?.beforeInstall == true {
            self.pending.append(.call(Task { await call() }))
            self.note("\(label) started while parked")
        } else {
            await call()
            self.note(label)
        }
    }

    private func publishMarker() async {
        guard self.nextMarker < self.catalog.count else {
            return
        }
        let (entry, bytes) = self.catalog[self.nextMarker]
        self.nextMarker += 1
        await self.harness.source.script(entry.transferID, [.stage(bytes)])
        let startedAt = self.clock.tick()
        self.markers.append(Marker(id: entry.identifier, startedAt: startedAt))
        let harness = self.harness
        let client = self.client
        let id = entry.identifier
        await self.invoke("marker \(id)") {
            _ = try? await harness.withClock { () throws(AssetError) -> URL in
                try await client.resolve(id)
            }
        }
    }

    private func maintain() async {
        let startedAt = self.clock.tick()
        let harness = self.harness
        let client = self.client
        let call = { @Sendable () async -> MaintenanceReport? in
            try? await harness.withClock { () throws(AssetError) -> MaintenanceReport in
                try await client.performMaintenance(timeBudget: 1)
            }
        }
        guard self.parked?.beforeInstall != true else {
            await self.invoke("performMaintenance") {
                _ = await call()
            }
            return
        }
        let logStart = self.oracles.tap(self.serving)?.record.entries.count
        let report = await call()
        self.note("performMaintenance: \(report.map { _ in "a report" } ?? "failed")")
        if let report, let logStart {
            self.calls.append(Call(label: "performMaintenance", startedAt: startedAt, generation: self.serving, logStart: logStart, published: .maintenance(report)))
        }
    }

    private func forceSync() async {
        let startedAt = self.clock.tick()
        let harness = self.harness
        guard self.parked?.beforeInstall != true else {
            await self.invoke("sync(.force)") {
                _ = await harness.syncDriven(.force)
            }
            return
        }
        let logStart = self.oracles.tap(self.serving)?.record.entries.count
        let outcome = await harness.syncDriven(.force)
        self.note("sync(.force): \(outcome)")
        switch outcome {
        case .complete, .completeWithFailures, .blocked:
            if let logStart {
                self.calls.append(Call(label: "sync(.force)", startedAt: startedAt, generation: self.serving, logStart: logStart, published: .sync(outcome)))
            }
        case .failed, .notDue:
            break
        }
    }

    /// Wipes the root and lets `purge(.all)` reopen, parked at `park` (if any) with up to three actions while parked;
    /// with `thenShutDown` the client is shut down while the reopen is parked. A marker follows a reopen that installed
    /// a replacement, before any consumer pulls again.
    private func reopen(parkingAt park: ModelPark?, thenShutDown: Bool) async throws {
        guard self.parked == nil else {
            return
        }
        self.reopens += 1
        let began = self.clock.tick()
        let retiring = await self.client.lifecycle.current().generation
        self.installedAt[retiring + 1] = began
        // One operation of the fake volume (`KitHarness.vanishRoot()`): the walk does not wait for the engine to fall idle.
        try self.harness.vanishRoot()
        var hold: SeamHold?
        if let park {
            hold = await self.parking.arm(park)
        }
        self.note("reopen of generation \(retiring)\(park.map { " parked at \($0)" } ?? "")\(thenShutDown ? ", then shutdown" : "")")
        let harness = self.harness
        let client = self.client
        let parking = self.parking
        let purge = Task { () -> Result<PurgeResult, AssetError> in
            let result: Result<PurgeResult, AssetError>
            do throws(AssetError) {
                result = .success(try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                })
            } catch {
                result = .failure(error)
            }
            await parking.callFinished()
            return result
        }
        var shutdown: Task<Void, Never>?
        if park != nil, let hold, await self.parks() {
            self.parked = park
            if park?.beforeInstall == false {
                // Parked after the install: the replacement serves every registration and call made while parked.
                self.serving = retiring + 1
            }
            for _ in 0..<self.random.below(4) {
                await self.innerAction()
                // I4 after every action, the ones made while parked included.
                if let violation = await self.bufferedViolation() {
                    self.violation(violation)
                }
            }
            if thenShutDown {
                self.shutdownAt = self.clock.tick()
                shutdown = Task {
                    await client.shutdown()
                }
                self.note("shutdown started while parked")
            } else if park?.beforeInstall == true {
                // The replacement is installed only after the hold opens: followers recorded while parked are owed it.
                self.installedAt[retiring + 1] = self.clock.tick()
            }
            await hold.open()
            self.parked = nil
        }
        let result = await purge.value
        await shutdown?.value
        await self.settlePending()
        let now = await self.client.lifecycle.current().generation
        self.installed.insert(now)
        self.serving = now
        self.note("reopen finished: \(result), generation \(now)")
        if self.shutdownAt == nil {
            if case .failure(let error) = result {
                self.violation("the reopening purge failed before any shutdown: \(error)")
            }
            await self.publishMarker()
        }
    }

    /// Whether the reopen parked at the armed point (`false`: the purge finished without reaching it).
    private func parks() async -> Bool {
        await self.parking.waitForPark()
    }

    /// Settles the work started while a reopen was parked: subscriptions, calls, and `events` streams' first events.
    private func settlePending() async {
        let pending = self.pending
        self.pending = []
        for item in pending {
            switch item {
            case .subscribe(let task):
                switch await task.value {
                case .success(let stream):
                    _ = self.addConsumer(.subscribed, stream, registered: true)
                case .failure(let error):
                    if self.shutdownAt == nil || error != .shutDown {
                        self.violation("a subscribe() started while parked failed: \(error)")
                    }
                }
            case .call(let task):
                await task.value
            case .firstEvent(let index):
                guard self.consumers[index].status == .live else {
                    continue
                }
                await self.consumers[index].consumer.record.wait(forCount: 1)
                self.consumers[index].registeredAt = self.clock.tick()
                self.note("consumer \(index) registered (first event)")
            }
        }
    }

    // MARK: Shutdown and idle

    private func shutDownPhase() async throws {
        if self.random.below(3) == 0, self.reopens < ModelWalk.maxReopens {
            var parks: [ModelPark] = [.willShutDown, .built, .observesPressure]
            if self.prefetch != nil {
                parks.append(.registrationAnswered)
            }
            try await self.reopen(parkingAt: parks[self.random.below(parks.count)], thenShutDown: true)
        }
        if self.shutdownAt == nil {
            self.shutdownAt = self.clock.tick()
            self.note("shutdown")
            await self.client.shutdown()
        }
        self.installed.insert(await self.client.lifecycle.current().generation)
        // After the shutdown no stream registers: subscribe() throws and a new `events` stream yields only clientShutDown.
        do throws(AssetError) {
            _ = try await self.client.subscribe()
            self.violation("subscribe() after the shutdown returned a stream")
        } catch {
            if error != .shutDown {
                self.violation("subscribe() after the shutdown threw \(error)")
            }
        }
        var after: [AssetEvent] = []
        for await event in self.client.events {
            after.append(event)
        }
        if after != [.clientShutDown] {
            self.violation("an events stream made after the shutdown yielded \(after)")
        }
    }

    private func drainAndIdle() async {
        for consumer in self.consumers {
            if consumer.status == .live {
                consumer.consumer.send(.drain)
            }
            consumer.consumer.finish()
        }
        self.note("draining \(self.live.count) live consumers")
        for consumer in self.consumers {
            await consumer.consumer.task.value
        }
        for tap in self.oracles.all {
            // A replacement whose reopen the shutdown stopped before its installation was never started nor shut down.
            if await tap.engine.introspect().lifecycle != .shutDown {
                tap.task.cancel()
            }
            await tap.task.value
        }
        self.prefetch = nil
        self.note("idle wait: \(self.gauge.count) follower entries")
        await self.gauge.wait(atMost: 0)
        for tap in self.oracles.all {
            self.note("idle wait: generation \(tap.generation) subscribers \(await tap.engine.introspect().subscribers)")
            await tap.engine.awaitNoSubscribers()
        }
    }

    /// I4 after a step, and after each action made while a reopen is parked.
    private func bufferedViolation() async -> String? {
        for forwarder in await self.client.lifecycle.liveFollowers {
            let buffered = await forwarder.bufferedEvents
            if buffered > 1 {
                return "I4: a forwarder holds \(buffered) events"
            }
        }
        return nil
    }

    // MARK: Checks (I1, I2)

    private func markerID(_ event: AssetEvent) -> AssetID? {
        let id: AssetID
        switch event {
        case .assetAvailable(let subject, _), .assetFailed(let subject, _, _), .assetRemoved(let subject, _):
            id = subject
        default:
            return nil
        }
        return self.markers.contains { $0.id == id } ? id : nil
    }

    private func checkStreams() {
        let taps = self.oracles.all
        var logs: [UInt64: [AssetEvent]] = [:]
        var markerGeneration: [AssetID: UInt64] = [:]
        var markerFallback: [AssetID: UInt64] = [:]
        for tap in taps {
            let events = tap.record.entries.map(\.event)
            logs[tap.generation] = events
            for event in events {
                guard let id = self.markerID(event) else {
                    continue
                }
                if case .assetAvailable = event {
                    markerGeneration[id] = tap.generation
                } else if markerFallback[id] == nil {
                    markerFallback[id] = tap.generation
                }
            }
        }
        // A marker no generation made available is owed as the first generation's other event of its subject (its
        // failure), not skipped.
        for (id, generation) in markerFallback where markerGeneration[id] == nil {
            markerGeneration[id] = generation
        }
        for generation in self.installed.sorted() where logs[generation] == nil {
            self.violation("I1: the oracle holds no log of generation \(generation), which was installed")
        }
        let shutdownAt = self.shutdownAt ?? Int.max
        for state in self.consumers {
            let entries = state.consumer.record.entries
            let events = entries.map(\.event)
            let name = "consumer \(state.consumer.id) (\(state.consumer.kind), registered at \(state.registeredAt.map(String.init) ?? "never"), \(state.status))"
            // I2: markers never go back a generation, and none arrives twice.
            var newest: UInt64 = 0
            var seen: Set<AssetEvent> = []
            for event in events {
                guard let id = self.markerID(event), let generation = markerGeneration[id] else {
                    continue
                }
                if generation < newest {
                    self.violation("I2: \(name) received \(event) of generation \(generation) after one of generation \(newest)")
                }
                if !seen.insert(event).inserted {
                    self.violation("I2: \(name) received \(event) twice")
                }
                newest = max(newest, generation)
            }
            // I2: one clientShutDown at most, from the real shutdown, last.
            let ends = entries.indices.filter { entries[$0].event == .clientShutDown }
            if ends.count > 1 {
                self.violation("I2: \(name) received \(ends.count) clientShutDown events")
            }
            if let end = ends.first {
                if end != entries.count - 1 {
                    self.violation("I2: \(name) received events after clientShutDown: \(events[end...])")
                }
                if entries[end].at < shutdownAt {
                    self.violation("I2: \(name) received a clientShutDown at t\(entries[end].at), before the shutdown began at t\(shutdownAt)")
                }
            }
            guard state.status == .live else {
                continue
            }
            if events.last != .clientShutDown {
                self.violation("I2: \(name) was live at the shutdown and its stream did not end with clientShutDown: \(events.suffix(3))")
            }
            guard let registeredAt = state.registeredAt else {
                self.violation("I1: \(name) was live at the shutdown but its registration was never observed")
                continue
            }
            // I1: every marker whose call began after the registration.
            let received = Set(events.compactMap { self.markerID($0) })
            for marker in self.markers where marker.startedAt > registeredAt {
                guard let generation = markerGeneration[marker.id], !received.contains(marker.id) else {
                    continue
                }
                self.violation("I1: \(name) never received marker \(marker.id) (generation \(generation), call began at t\(marker.startedAt))")
            }
            // I1: every generation installed after the follow turn, from its first event (the hand-over).
            guard let followedAt = state.followedAt else {
                self.violation("I1: \(name) was live at the shutdown but its follow turn was never observed")
                continue
            }
            let owed = self.installed.sorted().compactMap { generation -> (generation: UInt64, log: [AssetEvent])? in
                guard let installedAt = self.installedAt[generation], installedAt > followedAt, let log = logs[generation] else {
                    return nil
                }
                return (generation, log)
            }
            let registration = self.registration(of: state, registeredAt: registeredAt, owed: owed.map(\.generation), logs: logs)
            self.checkGenerations(owed, events: events, markerGeneration: markerGeneration, name: name, registration: registration)
        }
    }

    /// What the generation `state` registered with owes it beyond the markers (Stage 3 ruling S3G-2, L5-R22 (2)): its
    /// `clientStarted` when that engine had not started in the turn that registered the stream (or may arrive, when the
    /// walk could not tell), and the terminal events of the calls it served after the registration. Nothing when that
    /// generation is also owed from its first event (handed over), which already covers all of it.
    private func registration(of state: Consumer, registeredAt: Int, owed: [UInt64], logs: [UInt64: [AssetEvent]]) -> Registration {
        guard let generation = state.registeredWith, !owed.contains(generation), let log = logs[generation] else {
            return .none
        }
        let announced = log.contains(where: ModelWalk.isClientStarted)
        return Registration(
            generation: generation,
            log: log,
            owesStart: announced && state.startOrder == .after,
            mayStart: announced && state.startOrder == .unknown,
            calls: self.calls.filter { $0.generation == generation && $0.startedAt > registeredAt }
        )
    }

    private static func isClientStarted(_ event: AssetEvent) -> Bool {
        if case .clientStarted = event {
            return true
        }
        return false
    }

    /// I1 for the generations a consumer was handed from their first events (`owed`, oldest first). The forwarder reads
    /// one engine stream to its end before the next, so each generation's events form one part of the consumer's stream,
    /// in generation order, and the markers the consumer received anchor those parts: between two received markers of
    /// generations `a` and `b` only the `clientStarted` of generations after `a`, up to `b`, can arrive.
    /// - Every owed generation whose oracle saw its `clientStarted` delivered it, in the gap between the received markers
    ///   that enclose it: client lifecycle events are never coalesced with each other (orchestrator ruling L5-R19). The
    ///   first gap may also hold the `clientStarted` of the engine the consumer registered with, which it was not handed;
    ///   any other `clientStarted` is one more than the generations the consumer read published (I2). Counted, not looked
    ///   up by value: replacements announce equal values (`clientStarted(generation: 1)`).
    /// - Each owed generation's part runs from its `clientStarted` to the next owed generation's `clientStarted` (or the
    ///   end); every other terminal event its oracle saw, or a later one of the same subject (H-9's per-subject coalescing,
    ///   L5-R19 (ii)), arrives inside that part, so an equal event of a neighbouring generation (a launch run's
    ///   `syncFinished`, a `maintenanceFinished` with the same report) never stands in for a lost one. Terminal events an
    ///   engine published before its `clientStarted` are looked for from the previous part's start on.
    private func checkGenerations(
        _ owed: [(generation: UInt64, log: [AssetEvent])],
        events: [AssetEvent],
        markerGeneration: [AssetID: UInt64],
        name: String,
        registration: Registration
    ) {
        var cuts: [(index: Int, generation: UInt64?)] = [(-1, nil)]
        for (index, event) in events.enumerated() {
            if let id = self.markerID(event), let generation = markerGeneration[id] {
                cuts.append((index, generation))
            }
        }
        cuts.append((events.count, nil))
        let started = owed.filter { $0.log.contains(where: ModelWalk.isClientStarted) }.map(\.generation)
        var startIndex: [UInt64: Int] = [:]
        for gap in 0..<(cuts.count - 1) {
            let low = cuts[gap]
            let high = cuts[gap + 1]
            let expected = started.filter { generation in
                (low.generation.map { generation > $0 } ?? true) && (high.generation.map { generation <= $0 } ?? true)
            }
            let found = ((low.index + 1)..<high.index).filter { ModelWalk.isClientStarted(events[$0]) }
            let place: String
            switch (low.generation, high.generation) {
            case (nil, let next?):
                place = "before its first marker (generation \(next))"
            case (let previous?, let next?):
                place = "between its markers of generations \(previous) and \(next)"
            case (let previous?, nil):
                place = "after its last marker (generation \(previous))"
            case (nil, nil):
                place = "with no marker"
            }
            // The first gap also holds the registration generation's own clientStarted when it is owed (S3G-2), and may hold
            // it when the walk could not tell its start from the registration; never otherwise.
            let required = expected.count + (gap == 0 && registration.owesStart ? 1 : 0)
            let spare = gap == 0 && registration.mayStart ? 1 : 0
            let own = gap == 0 && registration.owesStart ? ", and the registration generation \(registration.generation.map(String.init) ?? "") its own after the registration," : ""
            if found.count < required {
                self.violation("I1: \(name) lost a clientStarted: generations \(expected) each published one\(own) and \(found.count) arrived \(place): \(found.map { events[$0] })")
                continue
            }
            if found.count - required > spare {
                self.violation("I2: \(name) received \(found.count) clientStarted events \(place), where only generations \(expected) published one\(own): \(found.map { events[$0] })")
            }
            for (generation, index) in zip(expected, found.suffix(expected.count)) {
                startIndex[generation] = index
            }
        }
        for (position, item) in owed.enumerated() {
            let previousStart = owed[..<position].reversed().lazy.compactMap { startIndex[$0.generation] }.first ?? 0
            let lower: Int
            if let index = startIndex[item.generation] {
                lower = index
            } else if started.contains(item.generation) {
                // Its clientStarted was lost (reported above): its part cannot be delimited.
                continue
            } else {
                // Never started (a final generation the shutdown met before its start): it published only its shutdown's
                // clientShutDown, which I2 checks.
                lower = previousStart
            }
            let upper = owed[(position + 1)...].lazy.compactMap { startIndex[$0.generation] }.first ?? events.count
            let terminal = item.log.filter { !EventSlot($0).isProgress }
            let announced = terminal.firstIndex(where: ModelWalk.isClientStarted) ?? 0
            for (index, event) in terminal.enumerated() {
                switch event {
                case .clientStarted, .clientShutDown:
                    // clientStarted is counted above; a retired generation's clientShutDown is hidden (G-2) and the final
                    // one is I2's.
                    continue
                default:
                    let part = events[(index < announced ? previousStart : lower)..<upper]
                    let slot = EventSlot(event)
                    if !terminal[index...].contains(where: { EventSlot($0) == slot && part.contains($0) }) {
                        self.violation("I1: \(name) lost \(event) of generation \(item.generation), and no later event of its subject arrived in that generation's part of its stream")
                    }
                }
            }
        }
        // The registration generation's part runs from the start of the stream to the first owed generation's
        // clientStarted (S3G-2): each call it served after the registration published its terminal event there, or a
        // later one of the same subject. The oracle's first event at or after the call's start that the result names
        // stands for it: the call's own event is that one or a later equal one, so the check never asks for more.
        let upper = owed.lazy.compactMap { startIndex[$0.generation] }.first ?? events.count
        let part = events[..<upper]
        for call in registration.calls {
            guard let anchor = registration.log.indices.first(where: { $0 >= call.logStart && call.published.matches(registration.log[$0]) }) else {
                continue
            }
            let slot = EventSlot(registration.log[anchor])
            if !registration.log[anchor...].contains(where: { EventSlot($0) == slot && part.contains($0) }) {
                self.violation("I1: \(name) lost \(registration.log[anchor]) of its registration generation \(registration.generation.map(String.init) ?? ""), from \(call.label) begun at t\(call.startedAt) after its registration, and no later event of its subject arrived in that generation's part of its stream")
            }
        }
    }
}
