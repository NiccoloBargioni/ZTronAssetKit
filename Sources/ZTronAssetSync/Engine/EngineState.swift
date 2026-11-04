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
    /// Test seam: a floor under every owned task's priority (`OwnedTaskKind.priority`); `nil` in production.
    /// The test harnesses raise it to the default priority before `start()`: at utility priority (a run, its bulk
    /// drivers, the alarm; sync-1 S1-17) a host saturated by default-QoS processes starves every actor hand-off, so a
    /// test's duration measured the host's load rather than the engine (close-out cycle 13, F-17).
    var ownedTaskPriorityFloor: TaskPriority?
    /// The start task, while it runs.
    var startTask: UInt64?
    /// Set when shutdown begins closing the store, after it joined every owned task (R-SYN-15, ADR-039): what a condition
    /// observer reads to check that order (Stage 3, S3-B-070).
    var closingStore = false
    /// Introspection: the steps each turn of a shutdown's `settle(_:with:)` took, in order (each at most
    /// `SyncEngine.shutdownStepsPerTurn`, C2; Stage 3, S3-PERF-01).
    var shutdownSlices: [Int] = []

    // MARK: Jobs, interests and continuations (H-3)

    /// One job per transfer (ADR-020).
    var jobs: [TransferID: Job] = [:]
    /// The jobs that may hold an id the engine's copy maps to another transfer, or does not list: one joined for an
    /// entry the copy did not name then (`addInterest`), one a follow skipped while it verified or committed, and every
    /// job when the copy changed without a follow (launch). Every other job follows the copy, so a follow visits these
    /// and the jobs of the ids the copy's change moved, not the whole table (`followApplied(from:)`; C2, Stage 3,
    /// S3-PERF-02). A stale member is harmless: the follow finds nothing to move.
    var unfollowed: Set<TransferID> = []
    /// The follow in progress, in visiting order: `followOrder[followNext...]` are the jobs it still owes a visit, each in
    /// `unfollowed` until visited; empty when no follow is owed (`SyncEngine.followsPerTurn`, C2).
    var followOrder: [TransferID] = []
    /// The replaced copies whose comparison with the copy a follow still owes, oldest first (`followScansPerTurn`).
    var followScans: [FollowScan] = []
    /// The next index of `followOrder` to visit.
    var followNext = 0
    /// The applies the engine's copy has been followed for (`SyncEngine.followApplied(from:)`), counted: an attempt's end
    /// and its deferred verdict record the count at their instant (`Job.attemptEnd`), so a later visit tells an apply a
    /// visit-first engine visited the job at before them from one after (Stage 3 close-out cycle 16, ruling S3-R19 item 1).
    var appliesFollowed: UInt64 = 0
    /// The follows that ended (`SyncEngine.continueFollow`), counted: a job's re-route set belongs to the follow owed when
    /// it was recorded (`Job.rerouteFor`) and is spent once that follow has ended (cycle 16, PROBE-C15C-STALE-REROUTE).
    var followsEnded: UInt64 = 0
    /// A later turn is scheduled to continue the follow.
    var followFollowUpScheduled = false
    /// Test seam: while set, the scheduled follow-up keeps its visits owed and stays scheduled instead of running
    /// (`holdFollowFollowUps()`, `releaseFollowFollowUps()`). No production path sets it.
    var followFollowUpsHeld = false
    /// Test seam: a follow-up turn reached the hold and waits for its release.
    var followFollowUpWaiting = false
    /// Test seam: while set, every attempt's start appends its admission here, in the order the engine admits them
    /// (`SyncEngine.start`). The fake transport records a request when the attempt's driver reaches it, after the
    /// driver's own store read (`answeredFromStore`), so attempts in flight together may reach it in either order: a
    /// test of the order of admissions reads it here (Stage 3 close-out cycle 20, ruling S3-R25 item 4). No production
    /// path sets it.
    var admissionsForTests: [AttemptAdmission]?
    /// Test seam: told when a commit's turn begins (`false`, once the store's publication returned) and when its
    /// delivery ends (`true`), so a benchmark times that one turn inside the actor, apart from the turns of the callers
    /// it resumes (Stage 3 close-out cycle 21, ruling S3-R26 item 4; `BenchSync.commitTurns`). No production path sets
    /// it.
    var commitTurnMarksForTests: (@Sendable (_ ended: Bool) -> Void)?
    /// A pump found the follow barrier up (`SyncEngine.followBarrier`, F-28) and admitted nothing: every follow turn
    /// pumps again, and the drain's last batch pumps once the barrier is down (Stage 3, close-out cycles 3 and 9).
    var pumpWaitsForFollow = false
    /// Set while the follow moves one job (`SyncEngine.follow`): a join it makes (a moved id's interest re-routed to its
    /// new content) is the follow's own, whose space verdict is given at once; any other join's verdict on a job parked
    /// `insufficientSpace`, and any other place in a queue, waits for the follow's end while one is owed
    /// (`eventsAfterFollow`, F-28).
    var inFollowVisit = false
    /// Set while an attempt's end brings onto its job the interests an owed visit moves there (`SyncEngine.bringInbound`):
    /// their joins are made at once, on the job as the attempt left it, never behind its verdict (`addInterest`).
    var bringingInbound = false
    /// The moves an attempt's end or an apply owes onto a job (`SyncEngine.bringInbound`), in the order they were found:
    /// `inboundMoves[inboundNext...]` are still owed. The follow makes them a bounded number per turn, before any visit
    /// (`SyncEngine.continueInbound`; Stage 3 close-out cycle 18, ruling S3-R20 item 3), so a follow is owed while one is.
    var inboundMoves: [InboundMove] = []
    /// The next index of `inboundMoves` to make. A move that carries more ids than a turn moves stays there, its moves
    /// left in `InboundMove.progress`, until its last turn (Stage 3 close-out cycle 19, ruling S3-R22 item 1).
    var inboundNext = 0
    /// The rest of a visit that moves more ids than a turn moves (`SyncEngine.followIDsPerTurn`): the follow is owed until
    /// its last id moved, its turns make it before any other visit, and its holder's publication waits for it (Stage 3
    /// close-out cycle 19, ruling S3-R22 item 1).
    var followMoving: VisitRemainder?
    /// The ids a follow turn moves at most, visits, owed moves and a visit's rest together, half of them in an attempt's
    /// end or an apply's turn (`SyncEngine.followIDsPerTurn`). A seam: a test sets it small to pin the bound (S3-R23
    /// item 3); no production path writes it.
    var followIDsPerTurn = SyncEngine.followIDsPerTurn
    /// The owed moves onto each job, counted once per walk: the job's publication binds its ids only once none is owed
    /// onto it or off it (`SyncEngine.inboundBlocks`). The moves off a job are found among the owed moves when its
    /// publication asks, so a walk that finds thousands of holders records no holder twice (C2).
    var inboundOnto: [TransferID: Int] = [:]
    /// The publications that wait for their job's owed moves (`SyncEngine.awaitInboundMoves`), resumed once none is owed,
    /// or by shutdown.
    var inboundWaits: [TransferID: CheckedContinuation<Void, Never>] = [:]
    /// Whether the apply of this turn walked the jobs for the publications in flight
    /// (`SyncEngine.bringInboundOntoPublications`): its follow's first turn is then the follow-up turn the walk
    /// scheduled, so the apply's turn holds the walk without the follow's first passes, moves and visits (C2). Set and
    /// cleared within the apply's turn (`SyncEngine.followApplied(from:)`).
    var applyWalked = false
    /// The inputs that arrived behind the follow barrier and are not real-world ledger inputs, in arrival order (F-28;
    /// Stage 3 close-out cycle 9, S3-R11 design D3, and cycle 11, S3-R14): every attempt's exit verdict, every request's
    /// join and withdrawal, a group's release and a purge's withdrawals, an ENOSPC's verdict, a conditions element's and
    /// a re-admission's decisions about jobs, a due retry and a throttle's fail-fast turn. The engine's handling of each
    /// waits, and is applied when the follow ends, after its own last turn and pump, as a visit-first engine met them
    /// (`SyncEngine.drainEventsAfterFollow`); the real-world facts each read (the path, the clock, a `Retry-After`) are
    /// captured when it arrives. They wait only while a follow is owed, a drain turn is scheduled or a drain is in
    /// progress (`invariantViolations()`).
    var eventsAfterFollow: [EventAfterFollow] = []
    /// The decision instant of each event of `eventsAfterFollow`, in step with it (`SyncEngine.deferToFollow`): its
    /// arrival and the view of the world then (`worldHistory`). The drain applies an event under it (`reading`), so a
    /// place keeps the time it was asked for (bulk aging reads it, the cycle-9 amendment (a)), a backoff and a fail-fast
    /// answer count from the event's arrival, and the throttle, the breaker and the conditions are read as they stood
    /// then (Stage 3 close-out cycle 12, S3-R15 item 1).
    var eventStamps: [WorldStamp] = []
    /// The views of the non-ledger real-world inputs (the origin's throttle and breaker, the conditions, the network
    /// edge) at the decision instants of the follow barrier, oldest first: one is appended when a deferred event or an
    /// apply reads a view that differs from the last (`SyncEngine.worldStamp()`), so it grows with the inputs' changes,
    /// not with the events. Empty while the barrier is down (`invariantViolations()`): after the drain's last batch the
    /// live state is what applying every input on arrival gave, and no decision reads an older view.
    var worldHistory: [WorldView] = []
    /// The decision instant the engine decides at now (`SyncEngine.decisionNow`, `SyncEngine.withReading`): the event
    /// the drain applies, or the apply a follow's visit belongs to; `nil` otherwise, when every read is live.
    var reading: WorldStamp?
    /// The decision instant of each job a follow's visit is owed to: the apply whose pass found it (or whose follow
    /// carried it), whose instant a visit-first engine visited it at (S3-R15 item 1). Set when the job joins
    /// `followOrder`, taken by its visit; cleared with `worldHistory`.
    var followStamps: [TransferID: WorldStamp] = [:]
    /// The jobs whose exit verdict waits in `eventsAfterFollow` (`.attemptFailed`, `SyncEngine.defersFailure`): each is
    /// `failed` until the drain gives the verdict, and a re-lane of it is the follow's own visit's (any other waits as the
    /// event that asks for it); `removeJob` forgets it.
    var verdictsAfterFollow: [TransferID: VerdictAfterFollow] = [:]
    /// The joins that wait in `eventsAfterFollow` (`.join`), by interest and asset, with the transfer each joins: the
    /// waiter, group member or run fetch they stand for holds no interest until the drain joins it
    /// (`invariantViolations()`).
    var joinsAfterFollow: [InterestToken: [AssetID: TransferID]] = [:]
    /// The jobs an older follow left in `unfollowed` that a later apply found owed no visit while an older pass was
    /// still owed: they join `followOrder` once the older passes end, where a visit-first engine, whose older passes had
    /// ended at that apply, placed them (`FollowScan.carried`; amendment (e) of S3-R11, cycle 11).
    var followCarried: Set<TransferID> = []
    /// Set while `drainEventsAfterFollow` applies a batch: the events it applies are not deferred again, and no pump runs.
    var drainingAfterFollow = false
    /// The ids the drain's visits after verdicts may still move in this turn (`SyncEngine.followAfterVerdict`), set
    /// at each batch to what the turn has left: one turn's ids cover the whole batch, the follow's last turn included
    /// (Stage 3 close-out cycle 20, ruling S3-R25 item 1; each visit had a whole turn's ids, so a batch of verdicts moved
    /// that many times more in one turn).
    var drainIDsLeft = 0
    /// A later turn is scheduled to continue the drain of `eventsAfterFollow`.
    var drainFollowUpScheduled = false
    /// Test seam: while set, the drain's scheduled follow-up keeps its events waiting and stays scheduled instead of
    /// running (`holdDrainFollowUps()`, `releaseDrainFollowUps()`). No production path sets it.
    var drainFollowUpsHeld = false
    /// Test seam: a drain follow-up turn reached the hold and waits for its release.
    var drainFollowUpWaiting = false
    /// The jobs a system interest (launch re-attachment, healing) was added to, so a run's release of re-attachments
    /// visits them, not the whole table (C2, Stage 3, S3-PERF-02). A member whose job lost its system interests is pruned
    /// by that visit; `removeJob` drops it.
    var systemHeld: Set<TransferID> = []
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
    /// Test seam (orchestrator ruling L5K-R16): the next re-read of the store's deadline (`refreshStoreDeadline()`) waits
    /// after the store answered and before the engine applies the answer, until a test releases it
    /// (`holdNextStoreDeadlineRead()`, `releaseStoreDeadlineRead()`), so the test can land a newer read first, an order
    /// the tasks' priorities can produce. No production path arms it.
    var storeDeadlineReadHold: StoreDeadlineReadHold = .idle
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
    /// Pending claims (orchestrator ruling L5-R1, CCR-G2): for each content, how many members of registered prefetch
    /// groups, and of released ones whose claims are still being dropped, named it in the engine's copy of the manifest
    /// when they were claimed and are not reached yet by their group's join. A job whose last interest leaves while its
    /// content is claimed stays (`removeInterest`): `registerGroup` answers before the group holds any interest, and a
    /// re-lane orders the old handle's release after the successor's registration only, so without the claim that
    /// release retired the job and the successor's join started its transfer again (R-CAR-3, sync-1 S1-05).
    var claims: [ClaimKey: Int] = [:]
    /// The jobs a pending claim alone keeps (no interest left), by the content claimed: when the content's last claim
    /// ends, `dropClaim` retires the job it finds here. An entry whose job gained an interest or left since is stale and
    /// harmless; the content's last claim drops it.
    var claimHeld: [ClaimKey: TransferID] = [:]
    /// The pending claims of registered groups' members the engine's copy did not list when they were claimed (a
    /// registration before `start()`, or ahead of a catch-up): `adoptApplied` claims their content once the copy lists
    /// them (`claimNewlyListed`).
    var unlistedClaims = 0
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
    /// Updates of `storeDeadline` so far (`setStoreDeadline`): an answer of the store's deadline requested at one count
    /// and applied at another may have crossed a newer answer (`applyStoreDeadline`, orchestrator ruling L5K-R16).
    var storeDeadlineUpdates: UInt64 = 0
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
    /// Test seam (close-out cycle 17): while set, the scheduled space sweep follow-up keeps its sweep owed
    /// (`spaceSweepFollowUp`) instead of running (`holdSpaceSweepFollowUps()`, `releaseSpaceSweepFollowUps()`), so a
    /// test decides what the engine does while a sweep is owed, an order no production path fixes. No production path
    /// sets it.
    var spaceSweepFollowUpsHeld = false
    /// Test seam: a follow-up sweep reached the hold and waits for its release.
    var spaceSweepFollowUpWaiting = false
    /// Test seam (close-out cycle 18): while set, a manifest fetch that ends keeps its outcome from the runs and
    /// `ensureAvailable` calls waiting for it (`heldManifestDeliveries`) until a test releases it
    /// (`holdManifestOutcomeDelivery()`, `releaseManifestOutcomeDelivery()`), so the test can let other engine work, such
    /// as a transfer's 429, run between a fetch's outcome and its waiters' answers, an order production leaves to the
    /// scheduler. No production path sets it.
    var manifestDeliveriesHeld = false
    /// Test seam: the outcomes the hold keeps, each with the waiters it is owed to.
    var heldManifestDeliveries: [HeldManifestDelivery] = []
    /// Test seam (close-out cycle 19): while set, an alarm whose sleep returned waits before it fires what is due
    /// (`heldAlarmTurns`) until a test releases it (`holdAlarmTurns()`, `releaseAlarmTurns()`), so the test can let other
    /// engine work, such as a transfer's terminal, run after a deadline's instant and before the alarm's turn, an order
    /// production leaves to the sleep's wake-up latency and the actor's queue. No production path sets it.
    var alarmTurnsHeld = false
    /// Test seam: the alarm turns the hold keeps, by alarm token; a replaced alarm's is resumed by `rearm`.
    var heldAlarmTurns: [UInt64: CheckedContinuation<Void, Never>] = [:]
    /// Test seam (Stage 3 close-out cycle 11): while set, an attempt's driver that received the terminal element waits
    /// before it applies it (`heldAttemptTerminals`) until a test releases it (`holdAttemptTerminals()`,
    /// `releaseAttemptTerminals()`), so the test can let other engine work, such as a follow's next turn, run between a
    /// transfer's end and the engine's verdict on it, an order production leaves to the driver's hop onto the actor. No
    /// production path sets it.
    var attemptTerminalsHeld = false
    /// Test seam: the drivers the hold keeps, in the order their terminal elements arrived.
    var heldAttemptTerminals: [CheckedContinuation<Void, Never>] = []
    /// Test seam (close-out cycle 19): while set, a run's settlement waits before it reaches the run's task
    /// (`heldRunSettlements`) until a test releases it (`holdRunSettlementDelivery()`, `releaseRunSettlementDelivery()`),
    /// so the test can let other engine work, such as a transfer's 429, run between a run's settling turn and its answer,
    /// an order production leaves to the scheduler. No production path sets it.
    var runSettlementsHeld = false
    /// Test seam: the settlements the hold keeps, each with the run task's wait it is owed to.
    var heldRunSettlements: [HeldRunSettlement] = []
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
    /// `circuitParked` in the pump's order (`CircuitParkedOrder`, lazy deletion): a breaker that admits only a probe
    /// re-admits its first job, not every parked job (S3-B-063).
    var circuitOrder = CircuitParkedOrder()
    /// The job last re-admitted for the probe a breaker that admits only a probe gives (`readmitForProbe()`): while it
    /// waits in the queue, the next dispatch takes the probe, so the other parked jobs stay parked.
    var probeCandidate: TransferID?
    /// Introspection: the jobs re-queued from `blocked(circuitOpen)` since start, the work the breaker's re-admissions did
    /// (a chain of probes ending without a verdict re-admits one parked job per exit, S3-B-063).
    var circuitReadmissions = 0
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
    /// Test seam (close-out cycle 16): while set, the scheduled re-admission follow-up keeps its passes owed and stays
    /// scheduled instead of running (`holdReadmissionFollowUps()`, `releaseReadmissionFollowUps()`), so a test decides
    /// what the engine does while jobs are owed a re-queue, which no production path can order. No production path sets
    /// it.
    var readmissionFollowUpsHeld = false
    /// Test seam: a follow-up turn reached the hold and waits for its release.
    var readmissionFollowUpWaiting = false
    /// A later turn is scheduled to answer the user-initiated waiters of the jobs a throttle parked, after a 429 extended
    /// the throttle beyond their bound (`SyncEngine.throttleExtended(from:)`, at most `parksPerPump` jobs a turn, C2).
    var throttleAnswersScheduled = false
    /// Lanes whose queued jobs a lane-wide block (offline, a policy) parks, left unfinished by a pump turn's bound and
    /// continued by every later pump (C2): the reason each lane's jobs are parked with.
    var laneParksOwed: [AssetPriority: BlockReason] = [:]
    /// Released groups whose interests are still being removed: at most `SyncEngine.releasesPerTurn` members per actor
    /// turn (C2). Their jobs never start while only such interests want them.
    var releasing: [InterestToken: Release] = [:]
    /// A later turn is scheduled to continue `releasing`.
    var releaseFollowUpScheduled = false
    /// Test seam: while set, the scheduled release follow-up stays scheduled instead of running (`holdReleaseFollowUps()`,
    /// `resumeReleaseFollowUps()`). No production path sets it.
    var releaseFollowUpsHeld = false
    /// Test seam: a release follow-up reached the hold and waits for its resumption.
    var releaseFollowUpWaiting = false

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

/// A replaced copy of the applied manifest whose comparison with the engine's copy a follow still owes, from `next` on
/// (`SyncEngine.followApplied(from:)`).
struct FollowScan {
    /// The replaced copy.
    let manifest: ValidatedManifest
    /// The index of its next entry to compare.
    var next = 0
    /// The jobs the apply that queued this pass found in `unfollowed` and owed no visit while older passes were owed:
    /// they join `followOrder`, sorted, when this pass begins (`SyncEngine.followCarried`).
    var carried: [TransferID] = []
    /// The decision instant of the apply that queued this pass: the jobs it finds or carries are visited under it
    /// (`EngineState.followStamps`).
    let stamp: WorldStamp
}

/// One owed move of `SyncEngine.bringInbound` (`EngineState.inboundMoves`): the ids `holder` holds that `copy` maps to
/// `target`'s content, which a visit-first engine's visits had already moved onto `target`'s job at its epoch `epoch`.
struct InboundMove {
    /// The job the ids move onto.
    let target: TransferID
    /// Its epoch when the move was found: a job the epoch no longer names gets none (`SyncEngine.continueInbound`).
    let epoch: UInt64
    /// The job that holds them.
    let holder: TransferID
    /// The ids.
    let ids: Set<AssetID>
    /// The copy that mapped them to `target`'s content: the moves re-route under it (`SyncEngine.reroute`).
    let copy: ValidatedManifest
    /// The moves left of a move that carries more ids than a turn moves, once its first turn made some
    /// (`SyncEngine.continueInbound`); `nil` before.
    var progress: MoveProgress?
}

/// A job `SyncEngine.findInbound` brings ids onto: its transfer, its epoch and its entry, read before the walk, so no copy
/// of the job is alive while its interests grow.
struct InboundTarget {
    /// The job's transfer.
    let transfer: TransferID
    /// Its epoch (`InboundMove.epoch`).
    let epoch: UInt64
    /// Its entry: an id the copy maps to the same transfer (`SyncEngine.sameTransfer`) moves onto it.
    let entry: ManifestEntry
}

/// One attempt's admission, as `EngineState.admissionsForTests` records it.
struct AttemptAdmission: Equatable, Sendable {
    /// The job's transfer.
    let transfer: TransferID
    /// The ticket of the queue entry it was admitted from (`Job.ticket`).
    let ticket: UInt64
    /// That entry's place in its lane queue (`Job.queuePlace`).
    let place: Int64
    /// The attempt.
    let attempt: TransferAttempt
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
    /// Interests by token. Changed only through `setInterest` and the other mutators below, which keep
    /// `interestCounts` with it.
    private(set) var interests: [InterestToken: JobInterest] = [:]
    /// How many of `interests` ask for each lane (`InterestCounts`), kept by every change to them, so the job's lane is
    /// read without a walk of its interests; the invariant check recounts them (`SyncEngine.invariantViolations`).
    var interestCounts = InterestCounts()
    /// The lane-queue ticket (lazy deletion).
    var ticket: UInt64 = 0
    /// Its entry's place in its lane queue (`LaneQueues.Entry.place`), where `reinstate` puts it back.
    var queuePlace: Int64 = 0
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
    /// The ids the next visit that passes the job re-routes at once (`SyncEngine.follow`, `SyncEngine.rerouteOnVisit`),
    /// `nil` from the start of an attempt (`start`) until its publication or its deferred verdict sets it. Set when the
    /// attempt reaches its publication (`publish`): the ids the engine's copy listed elsewhere then while a follow was owed,
    /// which a visit-first engine, visiting the job at that follow's apply while it still downloaded, had moved (Stage 3
    /// close-out cycle 15, ruling S3-R18 item 2); an id an apply moved while the job already published is not in it, since
    /// that engine passed it (S3-R18a item 1). Set again when the attempt's exit verdict defers to the follow
    /// (`recordDeferredVerdict`) unless the attempt ended in its publication with no apply since: the ids listed elsewhere
    /// then while a follow was owed, which that engine had moved before the verdict arrived. The set serves the visit
    /// the follow owed then makes, and only it: that visit empties it, found moved ids or not, and once that follow has
    /// ended without visiting the job (an apply moved its ids back first) it is spent all the same (`rerouteFor`). A
    /// later apply's visit meets ids an apply moved while the job published, which that engine passed; an id the set
    /// kept was re-routed again once an apply had moved it back and away (cycle 16; PROBE-C15R-REROUTE-STALE,
    /// PROBE-C15C-STALE-REROUTE).
    var rerouteOnPass: Set<AssetID>?
    /// The follows ended (`EngineState.followsEnded`) when `rerouteOnPass` was set: the set belongs to the follow owed
    /// then, and is spent once that follow has ended (`SyncEngine.rerouteOnVisit`).
    var rerouteFor: UInt64 = 0
    /// The applies followed when the latest attempt ended in a failure, and when its exit verdict deferred to the follow
    /// (`AttemptEnd`); `nil` from the start of an attempt (`start`) and once the drain gives the verdict.
    var attemptEnd: AttemptEnd?
    /// The error interests will receive if the job ends now.
    var lastError: AssetError?

    /// The lane its interests had when the last one left while a pending claim kept the job (L5-R1): until the
    /// claim's join adds an interest or the claim ends, the job keeps its place and its transfer's priority, as if the
    /// released interest were still there. Read only while the job has no interest.
    var heldLane: AssetPriority?

    /// A job of `transfer`'s content, for `entry`, with no interest.
    init(
        transfer: TransferID,
        entry: ManifestEntry,
        identity: ContentIdentity,
        assets: Set<AssetID>,
        state: JobState,
        epoch: UInt64,
        queuedAt: MonotonicInstant
    ) {
        self.transfer = transfer
        self.entry = entry
        self.identity = identity
        self.assets = assets
        self.state = state
        self.epoch = epoch
        self.queuedAt = queuedAt
    }

    /// The maximum over its interests (ADR-020); for a job only a pending claim keeps, the lane it had (`heldLane`).
    /// Read from `interestCounts`: each id a follow moves reads the lanes of the jobs it leaves and joins (`addInterest`,
    /// `relane`, `dropInterest`), and the walk of every interest it was made that O(interests) per id, so a bounded turn
    /// of 512 ids off a job of 10,000 user waiters held the actor 33 to 71 ms (Stage 3 close-out cycle 20, ruling S3-R25
    /// item 2; the cycle-19 correctness verifier's PROBE-C19C-USER-SHARED-C2, `BenchSync.userSharedApplyTurns`).
    var lane: AssetPriority {
        self.interestCounts.highest ?? self.heldLane ?? .bulk
    }

    /// Whether a user-initiated interest is a single request (served before batches, sync.md §7.2).
    var isSingleUser: Bool {
        self.interestCounts.singleUser > 0
    }

    /// Sets `token`'s interest, or removes it with `nil`, and keeps `interestCounts`: an insertion counts the new
    /// interest, a removal uncounts the old one, and a replacement moves its count from the old interest's lane and kind
    /// to the new one's (a token's interests keep the lane they registered with, `invariantViolations`, so today's
    /// replacements narrow an interest's ids and keep both).
    mutating func setInterest(_ interest: JobInterest?, for token: InterestToken) {
        switch (self.interests[token], interest) {
        case (nil, let added?):
            self.interestCounts.add(added)
        case (let removed?, nil):
            self.interestCounts.remove(removed)
        case (let old?, let new?):
            self.interestCounts.remove(old)
            self.interestCounts.add(new)
        case (nil, nil):
            break
        }
        self.interests[token] = interest
    }

    /// Adds `asset` to `token`'s interest, in place; nothing without one. Its lane and kind, and so the counts, stay.
    mutating func insertAsset(_ asset: AssetID, for token: InterestToken) {
        self.interests[token]?.assets.insert(asset)
    }

    /// Removes `asset` from `token`'s interest, in place; whether the interest held it. The interest stays, with its lane
    /// and kind, when it is left with no id: its caller removes it (`setInterest`).
    mutating func removeAsset(_ asset: AssetID, for token: InterestToken) -> Bool {
        self.interests[token]?.assets.remove(asset) != nil
    }

    /// Removes `assets` from `token`'s interest, in place, as `removeAsset` does each.
    mutating func subtractAssets(_ assets: Set<AssetID>, for token: InterestToken) {
        self.interests[token]?.assets.subtract(assets)
    }

    /// Replaces the ids of `token`'s interest, in place; nothing without one. Its lane and kind stay.
    mutating func setAssets(_ assets: Set<AssetID>, for token: InterestToken) {
        self.interests[token]?.assets = assets
    }

    /// Removes every interest, and their counts.
    mutating func removeAllInterests() {
        self.interests.removeAll()
        self.interestCounts = InterestCounts()
    }

    /// Keeps the interests `isIncluded` accepts, and recounts them (`SyncEngine.jobAtVerdict`'s copy of a job).
    mutating func keepInterests(where isIncluded: (InterestToken, JobInterest) -> Bool) {
        self.interests = self.interests.filter { isIncluded($0.key, $0.value) }
        self.interestCounts = InterestCounts(self.interests.values)
    }
}

/// How many of a job's interests ask for each lane, and how many of its user-initiated ones are single requests (no
/// `ensure` batch): the job's lane and its single-user rank (`Job.lane`, `Job.isSingleUser`) are read from them in O(1)
/// (Stage 3 close-out cycle 20, ruling S3-R25 item 2).
struct InterestCounts: Equatable {
    /// The bulk interests.
    var bulk = 0
    /// The prefetch interests.
    var prefetch = 0
    /// The user-initiated interests.
    var userInitiated = 0
    /// The user-initiated interests that are single requests, no `ensure` batch (`Job.isSingleUser`).
    var singleUser = 0

    /// No interest.
    init() {}

    /// The counts of `interests`, recounted.
    init<Interests: Sequence>(_ interests: Interests) where Interests.Element == JobInterest {
        for interest in interests {
            self.add(interest)
        }
    }

    /// The highest lane an interest asks for; `nil` with none.
    var highest: AssetPriority? {
        self.highest { _ in true }
    }

    /// The highest lane an interest `admits` accepts asks for; `nil` with none. `verdictAnswers` reads the lane a retry
    /// keeps (the lanes whose cap the attempt does not reach) here, where it walked the interests once for each it read.
    func highest(where admits: (AssetPriority) -> Bool) -> AssetPriority? {
        if self.userInitiated > 0, admits(.userInitiated) {
            return .userInitiated
        }
        if self.prefetch > 0, admits(.prefetch) {
            return .prefetch
        }
        if self.bulk > 0, admits(.bulk) {
            return .bulk
        }
        return nil
    }

    /// Counts `interest`.
    mutating func add(_ interest: JobInterest) {
        self.count(interest, by: 1)
    }

    /// Uncounts `interest`.
    mutating func remove(_ interest: JobInterest) {
        self.count(interest, by: -1)
    }

    /// Moves `interest`'s lane's count, and the single requests' for a user-initiated one, by `delta`.
    private mutating func count(_ interest: JobInterest, by delta: Int) {
        switch interest.lane {
        case .bulk:
            self.bulk += delta
        case .prefetch:
            self.prefetch += delta
        case .userInitiated:
            self.userInitiated += delta
            if interest.kind != .ensure {
                self.singleUser += delta
            }
        }
    }
}

/// A `resolve` caller.
struct Waiter {
    /// The asset.
    let asset: AssetID
    /// The job it is an interest of.
    var transfer: TransferID
    /// Its continuation; `nil` once the caller withdrew behind the follow barrier: the caller was answered `.cancelled`
    /// at once, and the record follows the interest's re-routes until the drain removes both (`SyncEngine.withdraw`).
    var continuation: CheckedContinuation<Result<AssetLocation, AssetError>, Never>?
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
    /// A prefetch group's members in the order its join reaches them (the array the join is given). Empty for
    /// `ensureAvailable` groups.
    var members: [AssetID] = []
    /// The content each of `members` named in the engine's copy when it was claimed (`nil`: not listed then); the
    /// members from `claimCursor` on hold a pending claim (`EngineState.claims`, L5-R1).
    var claimed: [ClaimKey?] = []
    /// The first member whose claim is still pending: the join ends the claims in member order.
    var claimCursor = 0
    /// How many pending claims name no content yet (`EngineState.unlistedClaims`).
    var unlistedClaims = 0
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

    /// Drops the members of `assets` that still wait for `transfer`, in place (a delivery of `transfer`'s outcome; a
    /// member that moved to other content meanwhile keeps waiting for it).
    mutating func clearPending(_ assets: Set<AssetID>, on transfer: TransferID) {
        for asset in assets where self.pending[asset] == transfer {
            self.pending[asset] = nil
        }
    }
}

/// A released group whose interests are still being removed (`SyncEngine.continueReleases`).
struct Release {
    /// The members whose interests are left to remove, in the order they joined.
    var members: ArraySlice<AssetID>
    /// Each member's transfer when the group was released.
    let pending: [AssetID: TransferID]
    /// The contents of the group's pending claims left to drop (L5-R1), before its members' interests; those naming no
    /// content were already uncounted at the release.
    var claims: ArraySlice<ClaimKey?> = []
}

/// The content a pending claim names (L5-R1): a checksummed entry's checksum, whose transfer is `TransferID.content` of
/// it, kept as its four words, because formatting that transfer's text for every member of a 10,000-id group held the
/// registering turn about 3 ms; a checksum-less (legacy, R-MAN-5) entry's transfer.
enum ClaimKey: Hashable, Sendable {
    /// `TransferID.content(hash)`.
    case content(ContentHash)
    /// A checksum-less entry's transfer.
    case legacy(TransferID)

    /// The content `entry` names.
    init(_ entry: ManifestEntry) {
        if let checksum = entry.checksum {
            self = .content(checksum)
        } else {
            self = .legacy(entry.transferID)
        }
    }

    /// The content `job` transfers: a job is keyed by its representative entry's transfer.
    init(job: Job) {
        if let checksum = job.entry.checksum {
            self = .content(checksum)
        } else {
            self = .legacy(job.transfer)
        }
    }
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
    /// Every job its interest was added to and has not left (`addInterest`, `removeInterest`, `removeJob`): the run's
    /// end removes its interest from these, not from a walk of the whole table (C2, Stage 3, S3-PERF-02). A follow can
    /// route the run's interest to a job outside `outstanding`.
    var held: Set<TransferID> = []
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
    /// Whether it passed the origin's gates (the throttle and the breaker): a run that joins it then holds no probe for
    /// it (`SyncEngine.reserveManifestProbe()`, close-out cycle 22, F-42).
    var admitted = false
    /// Waiting runs and `ensureAvailable` calls.
    var waiters: [InterestToken: CheckedContinuation<ManifestOutcome, Never>] = [:]
}

/// A manifest fetch's outcome that the test seam keeps from its waiters (`SyncEngine.holdManifestOutcomeDelivery()`):
/// only a test orders other engine work between a fetch's outcome and its waiters' answers this way.
struct HeldManifestDelivery {
    /// The outcome the fetch produced.
    let outcome: ManifestOutcome
    /// The runs and `ensureAvailable` calls it is owed to; a cancelled caller is withdrawn from here.
    var waiters: [InterestToken: CheckedContinuation<ManifestOutcome, Never>]
}

/// A run's settlement that the test seam keeps from the run's task (`SyncEngine.holdRunSettlementDelivery()`): only a
/// test orders other engine work between a run's settling turn and its answer this way.
struct HeldRunSettlement {
    /// The settlement the run reached.
    let settlement: RunSettlement
    /// The run task's wait it is owed to.
    let continuation: CheckedContinuation<RunSettlement, Never>
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
    /// Whether the launch run waits for it: set by `start()` when a sync is due while migration runs; cleared by the first
    /// run that starts meanwhile, which takes the launch run's place (orchestrator ruling L5K-R1), or when the loop ends,
    /// which then starts the launch run if the engine still runs.
    var launchRunWaiting = false
    /// Test seam: the `migrateLegacy` calls the loop has made in this lifetime, so a test bounds them while a job's
    /// adoption holds the last claimed prior-art file (orchestrator ruling L5K-R17: no hot loop around a store call).
    var batchCalls = 0
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

/// The store-deadline read test seam (`SyncEngine.holdNextStoreDeadlineRead()`): a test holds one re-read's answer
/// before the engine applies it, to order it after a newer read (L5K-R16), which no production path can do.
enum StoreDeadlineReadHold {
    /// Nothing armed (always, outside tests).
    case idle
    /// The next re-read waits once the store answered.
    case armed
    /// That re-read waits for `releaseStoreDeadlineRead()` or for shutdown.
    case holding(CheckedContinuation<Void, Never>)
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
