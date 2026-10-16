import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// Everything `SyncEngine` mutates, in one value owned by the actor (ARCHITECTURE §7). Engine memory scales with
/// outstanding work, never with catalog size: jobs exist only for transfers in flight or materialised by a run within
/// the pipeline plus `runLookahead` (sync-1 S1-15).
struct EngineState {
    // MARK: Lifecycle

    /// The lifecycle every entry point checks first.
    var lifecycle: EngineLifecycle = .created
    /// What `start()` learned.
    var launch: LaunchFacts?
    /// The remote source, built in `start()`.
    var remote: (any RemoteSource)?
    /// Why the remote source could not be built, when it could not.
    var remoteError: AssetError?
    /// The store's staging sink (discards of partials, sidecar reads).
    var staging: (any StagingSink)?
    /// The last token handed out; tokens are never reused (sync-1 S1-05).
    var lastToken: UInt64 = 0
    /// The last transfer-attempt sequence of this process (ADR-013).
    var lastAttempt: UInt32 = 0

    // MARK: Owned tasks (ADR-039)

    /// Every engine-owned task by unique spawn id (sync-1 S1-09).
    var tasks: [UInt64: Task<Void, Never>] = [:]
    /// The last spawn id.
    var lastTaskKey: UInt64 = 0
    /// The start task, while it runs.
    var startTask: UInt64?

    // MARK: Jobs, interests and continuations (H-3)

    /// One job per transfer (ADR-020).
    var jobs: [TransferID: Job] = [:]
    /// Attempts the engine cancelled whose driver still drains the stream to its terminal element.
    var draining: [TransferID: DrainingAttempt] = [:]
    /// Transfers whose interests wait for the engine's manifest copy to catch up with the store: the store superseded a
    /// publication the copy still names (a store `apply` whose await has not returned, or one the engine never saw).
    /// Their jobs stay queued and are not dispatched while `manifestCatchUps > 0` (F-20).
    var heldForManifest: Set<TransferID> = []
    /// Store `apply` calls in flight plus store re-reads under way; the last to end releases `heldForManifest`.
    var manifestCatchUps = 0
    /// A store `apply` threw: it may have written its manifest, prunes and evictions in memory first (ADR-050: the
    /// in-memory state stays authoritative), so once no `apply` is in flight the engine re-reads the store and follows
    /// it (`catchUpWithStore`, L4-R10).
    var catchUpAfterFailedApply = false
    /// Store `apply` calls in flight (a subset of `manifestCatchUps`): sent to the store and not yet followed, so at most
    /// one (`applyTurnHeld`). A store view read while one is may show its in-memory writes before the engine follows
    /// them, or miss them: it is not followed (`followStoreView`).
    var appliesInFlight = 0
    /// One engine `apply` at a time holds the turn, from before it reaches the store until the engine has followed it
    /// (`takeApplyTurn`, `passApplyTurn`): the engine follows its applies in the order the store commits them, so an
    /// older report can never be followed after a newer one (review of close-out cycle 4, PROBE-C4-4).
    var applyTurnHeld = false
    /// Applies waiting for the turn, by ticket (the lowest goes next); each counts in `manifestCatchUps` meanwhile.
    var applyQueue: [UInt64: CheckedContinuation<Void, Never>] = [:]
    /// The last ticket handed out.
    var lastApplyTicket: UInt64 = 0
    /// Test seam (close-out cycle 5): the follow-up of the next `apply` to return from the store waits until a test
    /// releases it (`holdNextApplyFollow()`, `releaseApplyFollow()`), so the test decides what the engine does in
    /// between. No production path arms it.
    var applyFollowHold: ApplyFollowHold = .idle
    /// Bumped whenever the engine's copy of the applied manifest changes (`adoptApplied`). A store view read before a
    /// change the engine made meanwhile may be older than the copy: it is not followed (close-out cycle 3, F-23).
    var copySerial: UInt64 = 0
    /// Ids the engine saw bound to content, by the transfer of that content: a commit's locations, an apply's reuses, a
    /// store read. No interest creates or joins a job for an id bound to its entry's content (ARCHITECTURE §7.1: only
    /// outstanding work has a job; L4-R5); such an interest is answered from the store. An entry goes when the engine
    /// learns the binding ended (prune, eviction, content change, purge, maintenance, quarantine, a recorded failure) or
    /// may have: a store mutation that threw may have unbound ids in memory first (ADR-050), so the whole ledger goes
    /// then. It keeps only what a plan, a read in flight or a job could still consult (`pruneBoundContent`).
    var boundContent: [AssetID: TransferID] = [:]
    /// Bumped whenever the engine forgets a binding (or drops the ledger). A binding learned from a store read or a
    /// mutation's result is recorded only when no binding was forgotten while that call was in flight: the read may
    /// predate what ended the binding (close-out cycle 3, F-23).
    var ledgerForgets: UInt64 = 0
    /// Store reads in flight whose answer registers an interest afterwards (`resolve`, a prefetch join, a point
    /// admission, `ensureAvailable` until its group exists): while one is, a binding the engine learns meanwhile is kept.
    var presenceReaders = 0
    /// The last job epoch handed out.
    var lastEpoch: UInt64 = 0
    /// Jobs created (T1) since the engine was made. The binding ledger exists to keep this from growing for an id the
    /// store holds present (L4-R5): the pre-transfer read (`answeredFromStore`) keeps such a job from downloading, so
    /// only this count shows a job the ledger should have avoided (review of close-out cycle 3, mutant M-NOLEDGER).
    var jobsCreated: UInt64 = 0
    /// `resolve` waiters.
    var waiters: [InterestToken: Waiter] = [:]
    /// `resolve` waiters of identifiers the applied manifest does not list (point admission, sync.md §6.5).
    var unknownWaiters: [InterestToken: UnknownWaiter] = [:]
    /// Prefetch handles and `ensureAvailable` groups.
    var groups: [InterestToken: Group] = [:]
    /// A later turn's `pump()` is scheduled to materialise `ensureAvailable` fetches (a batch that failed fast inside a
    /// pump left room nobody else would fill).
    var ensureRefillScheduled = false
    /// A `pump()` stopped after `SyncEngine.parksPerPump` parks and owes a later turn the rest (C2).
    var pumpFollowUpScheduled = false
    /// Callers joined to `start()`.
    var startJoiners: [InterestToken: CheckedContinuation<Result<OpenReport, AssetError>, Never>] = [:]
    /// Callers joined to `shutdown()`.
    var shutdownJoiners: [InterestToken: CheckedContinuation<Void, Never>] = [:]
    /// Callers joined to the active run.
    var syncJoiners: [InterestToken: CheckedContinuation<SyncOutcome, Never>] = [:]
    /// Callers joined to engine-owned entry tasks (purge, maintenance, pins, …).
    var entryJoins: [InterestToken: CheckedContinuation<EntryResult, Never>] = [:]
    /// The owned task behind each entry join, so a caller's cancellation can stop work nobody else shares.
    var entryTasks: [InterestToken: UInt64] = [:]
    /// `waitUntil` callers.
    var observers: [UInt64: Observer] = [:]
    /// The last `waitUntil` id.
    var lastObserver: UInt64 = 0
    /// Test seams: waits on engine-internal conditions, re-evaluated after every mutation like `waitUntil`.
    var conditionObservers: [UInt64: ConditionObserver] = [:]
    /// Owned tasks waiting for the first conditions element (Apple-tier gating, E-17).
    var conditionWaiters: [InterestToken: CheckedContinuation<Void, Never>] = [:]

    // MARK: Lanes (R-SYN-3)

    /// The lane queues with lazy deletion.
    var queues = LaneQueues()
    /// The last ticket handed out.
    var lastTicket: UInt64 = 0
    /// The last dispatch sequence (preemption order: newest first among equals).
    var lastStart: UInt64 = 0
    /// Whether background routing is off for the process (`backgroundSessionUnavailable`, ARCHITECTURE §7.6).
    var backgroundDisabled = false

    // MARK: Runs (R-SYN-6…11)

    /// The active run.
    var run: RunState?
    /// The last run id.
    var lastRunID: UInt64 = 0
    /// Waiting run task continuations (RE-S10).
    var runCompletions: [InterestToken: CheckedContinuation<RunSettlement, Never>] = [:]
    /// A run to start when its gate opens (sync-2 S2-03, S1-14).
    var pendingRun: PendingRun?
    /// Whether a run completed in this process (`.everyLaunch`).
    var syncedThisLaunch = false
    /// The engine's purge epoch: bumped before any await of a purge (R-CLN-6, RE-S24).
    var purgeEpoch: UInt64 = 0
    /// Runs in a row that ended offline, with no satisfied-path edge in between (R-SYN-13): the first is retried after
    /// the debounce, a later one that ended while the path read satisfied waits for an edge.
    var offlineRunsWithoutEdge = 0
    /// Satisfied-path edges applied so far: an attempt records the count when it starts, so an offline failure that
    /// arrives after an edge (URLSession's error lags the path monitor) knows the edge that re-queues it has passed.
    var networkEdgeSerial: UInt64 = 0

    // MARK: Manifest (R-NET-5, sync.md §6.5)

    /// The manifest the store applied last (engine-side copy, refreshed on every apply and admission).
    var applied: ValidatedManifest = .empty()
    /// The entity tag sent as `If-None-Match`.
    var appliedETag: ETag?
    /// The newest manifest seen, fetched or applied, with its fetch sequence (sync-1 S1-13).
    var newest: (manifest: ValidatedManifest, sequence: UInt64)?
    /// The single-flight manifest fetch.
    var manifestFetch: ManifestFetch?
    /// The last fetch sequence.
    var lastFetch: UInt64 = 0
    /// Recent `.notFound` answers for unknown identifiers (LRU, sync-2 S2-22).
    var negativeCache = NegativeCache()

    // MARK: Time (ADR-022)

    /// Every deadline.
    var heap = DeadlineHeap()
    /// The single alarm.
    var alarm: Alarm?
    /// The last alarm token.
    var lastAlarm: UInt64 = 0
    /// The store's next deadline as last read.
    var storeDeadline: MonotonicInstant?
    /// How many alarm runs have their `store.runDueWork()`, and what follows it (a free-space read after reaped bytes),
    /// under way: the store deadline is cleared meanwhile, yet that work may still reap. A count, not a flag: a deadline
    /// armed during one run's await starts a second alarm, and the first to end must not mark the other's work over
    /// (review of close-out cycle 5).
    var storeWorkRuns = 0
    /// A re-read of the store's next deadline is under way for a job parked `awaitingSpace` while none was armed
    /// (`ensureSpaceWake`).
    var spaceDeadlineReread = false
    /// A fresh free-space read is under way that decides the jobs parked `awaitingSpace` while nothing will run the
    /// store's due work (`settleUnwakeableSpaceWaits`).
    var spaceSettleRead = false

    /// Whether some alarm run's store work is under way (`storeWorkRuns`).
    var storeWorkInFlight: Bool {
        self.storeWorkRuns > 0
    }

    // MARK: Conditions (R-SYN-7, R-SYN-13)

    /// The current conditions; `nil` until the watcher's first element (and after it stops).
    var conditions: DeviceConditions?
    /// The watcher, while work exists.
    var watcher: Watcher?
    /// The last watcher token.
    var lastWatcher: UInt64 = 0
    /// Thermal hysteresis (sync-2 S2-25).
    var pausedForThermal = false

    // MARK: Origins (R-SYN-5)

    /// One breaker per origin.
    var breakers: [String: CircuitBreaker] = [:]
    /// Origin-wide `Retry-After` throttles.
    var throttles: [String: MonotonicInstant] = [:]

    // MARK: Space (R-SYN-11, sync-2 S2-09)

    /// The last free-space read.
    var freeSpace: FreeSpace?
    /// Bytes committed since that read (they stay in the headroom ledger until the next read).
    var committedSinceRead: Int64 = 0
    /// Bytes committed in this process, saturating: a read keeps the commits counted since it began (`readFreeSpace`).
    var committedTotal: Int64 = 0
    /// The jobs in downloading ∪ verifying ∪ committing and their bytes, kept by `transition` (the only mutator of
    /// `Job.state`; a job is created queued), `removeJob` and shutdown, and checked against the job table by
    /// `invariantViolations()`: the headroom ledger and the slot counts read them instead of every job (C2).
    var inFlight: Set<TransferID> = []
    /// The bytes of `inFlight`.
    var inFlightBytes = InFlightBytes()
    /// The jobs parked for lack of space (`blocked(insufficientSpace)` or `blocked(awaitingSpace)`), kept and checked as
    /// `inFlight` is: a free-space read re-checks these, not every job.
    var spaceParked: Set<TransferID> = []
    /// A space sweep stopped after `SyncEngine.parksPerPump` parks or re-admissions and owes a later turn the rest, in
    /// this mode (C2).
    var spaceSweepFollowUp: SpaceSweep?
    /// The jobs a space sweep re-queued, by the ticket it queued them with: while one still waits in the queue with that
    /// ticket, every later sweep counts its bytes ahead of the jobs it re-checks, so the sweeps of one read that the
    /// bound splits over several turns, and the next read's, admit only what the room holds together (C2, T17).
    var spaceAdmitted: [TransferID: UInt64] = [:]
    /// The jobs parked by a lane-wide gate (`blocked(offline)`, `blocked(policy)`), kept and checked as `spaceParked`
    /// is: a conditions element re-checks these, not every job (C2).
    var laneParked: Set<TransferID> = []
    /// The jobs parked by their origin's breaker (`blocked(circuitOpen)`), kept and checked as `spaceParked` is: a
    /// closed breaker or a cooldown's end takes these as its owed re-queues in O(1), not a pass over every job (C2).
    var circuitParked: Set<TransferID> = []
    /// The jobs parked by their origin's throttle (`blocked(throttled)`), kept and checked as `circuitParked` is.
    var throttleParked: Set<TransferID> = []
    /// The failed jobs (any disposition), kept and checked as `spaceParked` is: a satisfied network edge re-queues
    /// those of them failed `whenOnline` or transiently (T19), not a pass over every job (C2).
    var failedJobs: Set<TransferID> = []
    /// The failed jobs a satisfied network edge owes a re-queue that its turn left to a later one (C2); a job that
    /// leaves `failed` meanwhile leaves the set.
    var edgeOwed: Set<TransferID> = []
    /// The jobs parked by their origin that a closed breaker, a cooldown's end or an ended throttle owes a re-queue
    /// that its turn left to a later one (C2); a job that leaves `circuitParked` and `throttleParked` meanwhile leaves the
    /// set.
    var originOwed: Set<TransferID> = []
    /// The re-admission passes a turn left unfinished after `SyncEngine.readmissionsPerTurn` re-queues (C2).
    var readmissionsOwed: Readmissions = []
    /// A later turn is scheduled for `readmissionsOwed`.
    var readmissionFollowUpScheduled = false
    /// Lanes whose queued jobs a lane-wide block (offline, a policy) parks, left unfinished by a pump turn's bound and
    /// continued by every later pump (C2): the reason each lane's jobs are parked with.
    var laneParksOwed: [AssetPriority: BlockReason] = [:]
    /// Released groups whose interests are still being removed: at most `SyncEngine.releasesPerTurn` members per actor
    /// turn (C2). Their jobs never start while only such interests want them.
    var releasing: [InterestToken: Release] = [:]
    /// A later turn is scheduled to continue `releasing`.
    var releaseFollowUpScheduled = false

    // MARK: Events (R-SYN-12)

    /// Subscriber queues.
    var subscribers: [UInt64: SubscriberQueue] = [:]
    /// The last subscriber key.
    var lastSubscriber: UInt64 = 0
    /// The last event sequence.
    var lastEventSequence: UInt64 = 0
    /// Progress rate limiting at the source.
    var progress = ProgressGate()
    /// The last index generation the engine learned (events, replay).
    var generation: UInt64 = 0
    /// The index generation and stamp the store last reported (its open report, a view, a stamp the engine wrote):
    /// what `diagnostics()` reports while the store cannot answer (R-OBS-3, L4-R9).
    var lastIndexGeneration: UInt64 = 0
    /// See `lastIndexGeneration`; `nil` until the store reported one, and after a purge cleared it.
    var lastStamp: SyncStamp?

    // MARK: Leases, pins, scope, memory pressure, migration

    /// The retention scope in force (ADR-027) and its sequence (RE-S33).
    var retentionScope: AssetScope = .all
    /// The last retention-scope sequence pushed.
    var retentionSequence: UInt64 = 0
    /// The memory-pressure observer (R-CLN-11).
    var pressure = PressureObserver()
    /// Legacy migration (ADR-029, ruling R9).
    var migration = MigrationProgress()
    /// Resume points found at launch, by transfer (ADR-028).
    var launchResumes: [TransferID: ResumePoint] = [:]
    /// Assets whose re-download is scheduled after a quarantine (R-CLN-8).
    var heals: [AssetID: MonotonicInstant] = [:]

    // MARK: Observability (R-OBS-2, R-OBS-3)

    /// Engine counters.
    var metrics = MetricsSnapshot()
    /// The last errors, oldest first.
    var recentErrors: [DiagnosticError] = []
    /// Fields `SyncTuning.clamped()` changed.
    var clampedFields: [String] = []
}

/// What `start()` learned.
struct LaunchFacts {
    /// The store's open report.
    var report: OpenReport
    /// The app version.
    var appVersion: String
}

/// Why a job exists for one caller: a `resolve` waiter, a group (prefetch handle, `ensureAvailable`), a run, or a
/// system interest (launch re-attachment, healing after a quarantine).
enum InterestKind: Sendable, Hashable {
    /// One `resolve` call.
    case waiter
    /// A prefetch handle.
    case prefetch
    /// An `ensureAvailable` call (user-initiated batch).
    case ensure
    /// A bulk run.
    case run
    /// Healing or launch re-attachment; the first run claims or releases re-attachments.
    case system
}

/// One interest in one job: its lane and the assets of the job's content it wants.
struct JobInterest {
    /// The lane it asks for.
    var lane: AssetPriority
    /// What kind of reason it is.
    var kind: InterestKind
    /// The assets (of this job's content) it wants.
    var assets: Set<AssetID>
}

/// How a running attempt must be stopped once its handle arrives (the driver gets the handle after an await).
enum PendingStop: Sendable, Hashable {
    /// Pause (preemption or policy).
    case pause
    /// Cancel.
    case cancel
}

/// The running attempt of a job.
struct ActiveAttempt {
    /// The attempt.
    let attempt: TransferAttempt
    /// The request it was started with.
    let request: TransferRequest
    /// The driver's owned-task key.
    let driver: UInt64
    /// The handle, once `remote.transfer` returned (RE-S12).
    var handle: (any TransferHandle)?
    /// Dispatch order.
    let startSequence: UInt64
    /// Bytes received so far.
    var bytesReceived: Int64 = 0
    /// Paused for a waiting user-initiated job (its slot is free, T16).
    var preempting = false
    /// Paused because the lane's policy refuses it now (§11.3).
    var policyPause: PolicyBlock?
    /// The half-open breaker's single probe (never a preemption victim, ADR-031).
    var probe = false
    /// `EngineState.networkEdgeSerial` when the attempt started: an offline failure after a later edge is retried at
    /// once instead of waiting for an edge that already passed (R-SYN-13).
    var edgeSerial: UInt64 = 0
    /// A control the handle did not exist for yet.
    var pendingStop: PendingStop?
    /// A priority change the handle did not exist for yet.
    var pendingPriority: AssetPriority?
    /// Whether the driver consumed the attempt's terminal element (or the attempt has no stream: the publication of a
    /// file an earlier attempt staged). Such an attempt is over: retiring its job leaves nothing to drain.
    var terminalReceived = false
}

/// A cancelled attempt whose driver still drains its stream: no new attempt of the transfer starts until the terminal
/// element arrives (a completion racing the cancel is published instead, `drained`).
struct DrainingAttempt: Hashable {
    /// The attempt.
    let attempt: TransferAttempt
    /// Its driver's owned-task key (the invariant check: a drain without a running driver is never cleared).
    let driver: UInt64
}

/// One transfer's outstanding work (ARCHITECTURE §7.1).
struct Job {
    /// The content.
    let transfer: TransferID
    /// A representative entry (remote path, size, extension). Never replaced: the headroom ledger uncounts a job with
    /// the size it counted it with (`InFlightBytes`).
    let entry: ManifestEntry
    /// The content identity every bound id must still have (the store's publish guard).
    var identity: ContentIdentity
    /// Every asset bound at publication.
    var assets: Set<AssetID>
    /// The in-flight state.
    var state: JobState
    /// Bumped on every (re)start, supersede and abandon; a stale continuation is dropped (ARCHITECTURE §10).
    var epoch: UInt64
    /// Interests by token.
    var interests: [InterestToken: JobInterest] = [:]
    /// The lane-queue ticket (lazy deletion).
    var ticket: UInt64 = 0
    /// When it was queued (bulk aging).
    var queuedAt: MonotonicInstant
    /// Failed attempts counted toward the retry caps.
    var attempts = 0
    /// Where the next attempt continues from.
    var resume: ResumePoint?
    /// The running attempt.
    var active: ActiveAttempt?
    /// A file staged by an attempt the engine cancelled, to publish instead of transferring again.
    var adopt: StagedFile?
    /// Whether the last failure was transient (re-queued early on a satisfied edge, T19).
    var transientFailure = false
    /// The error interests will receive if the job ends now.
    var lastError: AssetError?

    /// The maximum over its interests (ADR-020).
    var lane: AssetPriority {
        self.interests.values.map(\.lane).max() ?? .bulk
    }

    /// Whether a user-initiated interest is a single request (served before batches, sync.md §7.2).
    var isSingleUser: Bool {
        self.interests.values.contains { $0.lane == .userInitiated && $0.kind != .ensure }
    }
}

/// A `resolve` caller.
struct Waiter {
    /// The asset.
    let asset: AssetID
    /// The job it is an interest of.
    var transfer: TransferID
    /// Its continuation.
    let continuation: CheckedContinuation<Result<AssetLocation, AssetError>, Never>
    /// Answered by a store read in an owned task instead of a job: the engine knows the asset is bound to `transfer`'s
    /// content (L4-R5). Such a waiter holds no interest; a read that finds nothing puts it on the job path.
    var fromStore = false
}

/// A `resolve` caller of an identifier the applied manifest does not list.
struct UnknownWaiter {
    /// The asset.
    let asset: AssetID
    /// Its lane.
    let lane: AssetPriority
    /// Its continuation.
    let continuation: CheckedContinuation<Result<AssetLocation, AssetError>, Never>
}

/// A group interest: a prefetch handle or an `ensureAvailable` call.
struct Group {
    /// The interest kind (`.prefetch` or `.ensure`).
    let kind: InterestKind
    /// Its lane.
    let lane: AssetPriority
    /// Members still pending, by asset.
    var pending: [AssetID: TransferID] = [:]
    /// Every member in the order it joined: a release removes their interests in this order over several turns (C2),
    /// with no sort.
    var joined: [AssetID] = []
    /// `ensureAvailable`'s planned fetches; those from `cursor` on are not members yet (S1-15: only the pipeline plus
    /// `runLookahead` become jobs at a time, as for a run).
    var fetches: [PlannedFetch] = []
    /// The next fetch to materialise.
    var cursor = 0
    /// `ensureAvailable`'s completion (RE-S20).
    var continuation: CheckedContinuation<Bool, Never>?
    /// The first `insufficientSpace` a member of an `ensureAvailable` group was failed with: the ensure answers it when
    /// its scope is still incomplete, so a shortage met at dispatch is typed as one met by the plan (R-SYN-11).
    var spaceFailure: AssetError?

    /// Whether the group waits for nothing more: no pending member and no fetch left to materialise.
    var isSettled: Bool {
        self.pending.isEmpty && self.cursor >= self.fetches.count
    }
}

/// A released group whose interests are still being removed (`SyncEngine.continueReleases`).
struct Release {
    /// The members whose interests are left to remove, in the order they joined.
    var members: ArraySlice<AssetID>
    /// Each member's transfer when the group was released.
    let pending: [AssetID: TransferID]
}

/// A `waitUntil` caller.
struct Observer {
    /// The predicate.
    let predicate: @Sendable (EngineIntrospection) -> Bool
    /// Its continuation.
    let continuation: CheckedContinuation<Void, Never>
}

/// A test seam's wait on an engine-internal condition.
struct ConditionObserver {
    /// The condition, evaluated on the actor.
    let condition: @Sendable (isolated SyncEngine) -> Bool
    /// Its continuation.
    let continuation: CheckedContinuation<Void, Never>
}

/// What an engine-owned entry task hands its caller.
enum EntryResult: Sendable {
    /// A command with no value.
    case done(Result<Void, AssetError>)
    /// `purge`.
    case purge(Result<PurgeResult, AssetError>)
    /// `performMaintenance`.
    case maintenance(Result<MaintenanceReport, AssetError>)
    /// `ensureAvailable`.
    case availability(Result<AvailabilityReport, AssetError>)
}

/// How a run's wait ended (RE-S10): the outcome is computed from the run ledger at resume time.
enum RunSettlement: Sendable, Hashable {
    /// Every planned fetch reached a terminal outcome.
    case finished
    /// Every remaining job is blocked.
    case blocked(BlockReason)
    /// A purge ended it.
    case cancelled
    /// Shutdown ended it.
    case shutDown
}

/// When a pending run starts.
enum PendingRunGate: Sendable, Hashable {
    /// When conditions admit bulk work again (debounced, sync-2 S2-25).
    case conditions
    /// When the breaker of the origin closes or half-opens.
    case breaker
    /// When the origin throttle ends.
    case throttle
}

/// A run to start when its gate opens.
struct PendingRun {
    /// What opens it.
    var gate: PendingRunGate
    /// The trigger the run will carry.
    var trigger: SyncTrigger
    /// Whether its debounce or throttle deadline is in the heap.
    var scheduled = false
    /// A repeated offline failure while the conditions read satisfied (the path says online, the transport says
    /// offline): the gate opens only on a satisfied-path edge (R-SYN-13), never on the debounce alone, so no timer
    /// polls the origin.
    var awaitsNetworkEdge = false
}

/// The run in progress (sync.md §12.5).
struct RunState {
    /// Its id.
    let id: SyncRunID
    /// Its interest token.
    let token: InterestToken
    /// What started it.
    let trigger: SyncTrigger
    /// Its mode.
    let mode: SyncMode
    /// Wall-clock start.
    let startedAt: Date
    /// The engine purge epoch at start.
    let purgeEpoch: UInt64
    /// Whether it is past planning and transferring.
    var transferring = false
    /// The admitted fetches in plan order.
    var fetches: [PlannedFetch] = []
    /// The next fetch to materialise.
    var cursor = 0
    /// Materialised jobs it holds an interest in, with the assets it wants from each.
    var outstanding: [TransferID: Set<AssetID>] = [:]
    /// What it planned.
    var planned = PlanTotals()
    /// What `apply` did.
    var applyReport: ApplyReport?
    /// Whether the manifest fetch succeeded (or returned 304).
    var manifestFresh = false
    /// Assets committed by its jobs.
    var fetched = 0
    /// Failures, by asset.
    var failures: [AssetID: AssetFailure] = [:]
    /// Bytes received by its transfers.
    var bytes: Int64 = 0
    /// Whether the plan skipped entries for lack of space (ADR-025: such a run never ends complete).
    var overBudget = false
    /// The manifest, ETag and digest it applies (for the stamp).
    var stampETag: ETag?
    /// The applied manifest's digest after `apply`.
    var stampDigest: ContentHash?
    /// The settlement, once decided.
    var settlement: RunSettlement?
}

/// The single-flight manifest fetch (RE-S04, RE-S19).
struct ManifestFetch {
    /// Its sequence.
    let sequence: UInt64
    /// Its owned task.
    var task: UInt64?
    /// Waiting runs and `ensureAvailable` calls.
    var waiters: [InterestToken: CheckedContinuation<ManifestOutcome, Never>] = [:]
}

/// What a manifest fetch produced.
enum ManifestOutcome: Sendable {
    /// A new, validated manifest.
    case fetched(ValidatedManifest, etag: ETag?, sequence: UInt64)
    /// 304: the applied manifest is current.
    case notModified(sequence: UInt64)
    /// The transport failed.
    case failed(TransferError)
    /// The bytes did not decode or validate.
    case invalid(ManifestError)
    /// The breaker refused the request.
    case circuitOpen(BreakerCause)
    /// The origin is throttled until the instant.
    case throttled(MonotonicInstant)
    /// `manifestFetchDeadline` passed first (transport-2 T2-14): use the applied manifest.
    case timedOut
    /// The caller withdrew.
    case cancelled
    /// Shutdown began.
    case shutDown
}

/// The single alarm (ADR-022).
struct Alarm {
    /// Its token: a replaced alarm finds its token stale (RE-S16).
    let token: UInt64
    /// Its owned task.
    let task: UInt64
    /// The deadline it sleeps until.
    let deadline: MonotonicInstant
}

/// The conditions watcher.
struct Watcher {
    /// Its token (RE-S17).
    let token: UInt64
    /// Its owned task.
    let task: UInt64
}

/// The memory-pressure observer (R-CLN-11, ADR-044).
struct PressureObserver {
    /// The newest epoch applied.
    var epoch: UInt64 = 0
    /// The handler of the newest epoch; `nil` stops the observer.
    var handler: (@Sendable (MemoryPressureLevel) async -> Void)?
    /// The observer task.
    var task: UInt64?
    /// Its token.
    var token: UInt64 = 0
}

/// Legacy migration bookkeeping (ruling R9).
struct MigrationProgress {
    /// Whether migration still has work.
    var pending = false
    /// Whether the loop runs.
    var running = false
    /// Whether it backed off to the next maintenance window.
    var deferred = false
    /// Whether the launch run waits for it.
    var launchRunWaiting = false
}

/// The negative cache of unknown identifiers (LRU-bounded).
struct NegativeCache {
    /// Expiry by asset.
    private(set) var expiry: [AssetID: MonotonicInstant] = [:]
    /// Insertion order, oldest first.
    private var order: [AssetID] = []

    /// Whether `id` is cached at `now`.
    func contains(_ id: AssetID, at now: MonotonicInstant) -> Bool {
        guard let until = self.expiry[id] else {
            return false
        }
        return now < until
    }

    /// Caches `id` until `until`, evicting the oldest beyond `capacity`.
    mutating func insert(_ id: AssetID, until: MonotonicInstant, capacity: Int) {
        if self.expiry.updateValue(until, forKey: id) != nil {
            self.order.removeAll { $0 == id }
        }
        self.order.append(id)
        while self.order.count > max(1, capacity) {
            self.expiry[self.order.removeFirst()] = nil
        }
    }

    /// Forgets `id` (a manifest listed it).
    mutating func remove(_ id: AssetID) {
        if self.expiry.removeValue(forKey: id) != nil {
            self.order.removeAll { $0 == id }
        }
    }
}

/// The apply follow-up test seam (`SyncEngine.holdNextApplyFollow()`): a test holds the engine's side of one committed
/// `apply` to order it against other engine work, which no production path can do.
enum ApplyFollowHold {
    /// Nothing armed (always, outside tests).
    case idle
    /// The next `apply` to return from the store waits before the engine follows it.
    case armed
    /// That follow-up waits for `releaseApplyFollow()` or for shutdown.
    case holding(CheckedContinuation<Void, Never>)
}
