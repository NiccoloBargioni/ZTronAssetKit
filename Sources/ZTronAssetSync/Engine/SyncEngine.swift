import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// The scheduler (R-SYN-*, H-3, H-4, H-5, H-8, H-9; WP-F).
///
/// Contract rules every implementation keeps (ARCHITECTURE §7, §10):
/// - One `Job` per **transfer** (content), with ref-counted interests per asset (ADR-020). A job is removed through
///   one synchronous funnel (sync-1 S1-01) once it has no interest, is not verifying or committing, and no pending
///   claim names its content (orchestrator ruling L5-R1: a claim lasts from `registerGroup` until the group's join
///   reaches the member, the group's release or the join's give-up drops it, at most `releasesPerTurn` a turn, or the
///   engine shuts down; ADR-054).
/// - Every continuation (waiters, groups, runs, `start`/`sync` joiners, `waitUntil`) is resumed exactly once: at
///   registration, before it enters its table, or in the turn that takes it out of its table (through `removeValue`, a
///   nil assignment, or with the whole table), except on two Stage 3 paths; and every table is settled at
///   registration, on each transition, on withdrawal, on purge and on shutdown (sync-1 S1-02). Those two can resume it
///   in a later turn: shutdown takes the waiters, the groups and the owed answers out whole (`drainEverything`) and
///   resumes them over bounded turns (`settle`); and a job of more than `answersPerTurn` interests owes its waiters'
///   and settled ensure groups' resumes to the answer follow-ups (`owedAnswers`), at most `answersPerTurn` a turn.
///   Behind the follow barrier a withdrawing caller on the job path is resumed at once, and its record, without its
///   continuation, is left in `waiters` for the follow's drain to remove with its interest (`replayRemoval`).
/// - Every store-touching entry point runs as an **engine-owned task** joined through the waiter pattern, so
///   shutdown cancels and joins it before `store.close()` (ADR-039, sync-1 S1-04, S1-08). Owned tasks are keyed by
///   a unique spawn id (sync-1 S1-09).
/// - One alarm serves every deadline, including the store's (`AssetStore.nextDeadline()`, ADR-022); the heap is
///   compacted eagerly and the watcher stops when the engine goes idle (sync-1 S1-10, R-SYN-14).
/// - Every `await` carries a `// REENTRANCY:` comment citing its ledger row (an RE-S, f-n or k-n row) and re-checks
///   the lifecycle and the job epoch after resumption (ARCHITECTURE §10).
/// - **After `shutdown()` began, every entry point fails with `AssetError.shutDown`** (R-SYN-15, ADR-042): every
///   query and command returns `.failure(.shutDown)`, `sync` returns `.failed(.shutDown)`, a group registration
///   fails and holds nothing, and a stream made afterwards yields `clientShutDown` and finishes. Only the releases
///   (`releaseGroup`, `releaseLease`) and `shutdown()` itself are idempotent no-ops then.
package actor SyncEngine {
    /// The store this engine drives (the single writer of its root).
    let store: AssetStore
    /// The injected world (ADR-038).
    let environment: AssetEnvironment
    /// The planner, run off the actor (RE-S07).
    let planner: any SyncPlanning
    /// The configuration (immutable).
    package nonisolated let configuration: EngineConfiguration
    /// `configuration.tuning` inside its valid ranges (`SyncTuning.clamped()`); the clamps are in diagnostics.
    let tuning: SyncTuning
    /// The engine's log route (`sync` category, ADR-047).
    let log: LogRoute
    /// Everything the engine mutates (ARCHITECTURE §7).
    var state = EngineState()

    /// Stores its collaborators with the production planner; no I/O, no task (P-12).
    package init(store: AssetStore, environment: AssetEnvironment, configuration: EngineConfiguration) {
        self.init(store: store, environment: environment, configuration: configuration, planner: StandardSyncPlanner())
    }

    /// Stores its collaborators with an injected planner (tests, sync-2 S2-26); no I/O, no task (P-12).
    package init(
        store: AssetStore,
        environment: AssetEnvironment,
        configuration: EngineConfiguration,
        planner: any SyncPlanning
    ) {
        self.store = store
        self.environment = environment
        self.configuration = configuration
        self.planner = planner
        let clamped = configuration.tuning.clamped()
        self.tuning = clamped.tuning
        self.log = environment.logRoute
        self.state.clampedFields = clamped.clampedFields
        self.state.retentionScope = configuration.retentionScope
    }

    // MARK: Lifecycle

    /// Single-flight start as an owned task: open the store, push the retention scope to it, build the remote
    /// source over the store's staging sink, reconcile launch staging (ADR-028), schedule legacy migration
    /// (ADR-029) and the due run. Returns when the client is ready, not when the sync finished. `.failure`:
    /// `.storageUnavailable` when the store cannot be opened, `.shutDown` after shutdown began.
    package func start() async -> Result<OpenReport, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performStart()
    }

    /// Cancels every owned task and running transfer, answers every continuation (`.shutDown`, except answers a
    /// resolution already owed, which keep their values) over bounded turns, joins every owned task, invalidates the
    /// remote source (foreground: after its last delegate callback; background: without waiting for the OS, ADR-028),
    /// closes the store, publishes `clientShutDown` last (R-SYN-15). Idempotent.
    package func shutdown() async {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performShutdown()
    }

    // MARK: Single-flight interests (R-SYN-4, R-CAR-4)

    /// Awaits one asset at `lane`: joins or creates its job, promotes it, point-admits an unknown id. The caller's
    /// cancellation withdraws only its own interest (H-3).
    package func awaitAsset(_ id: AssetID, lane: AssetPriority) async -> Result<AssetLocation, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performAwaitAsset(id, lane: lane)
    }

    /// Registers one group interest (a prefetch handle); `.failure(.shutDown)` after shutdown and
    /// `.failure(.storageUnavailable)` while degraded, holding nothing. The registering turn records a pending claim
    /// for every member (orchestrator ruling L5-R1), so no other group's release, waiter withdrawal or caller
    /// cancellation retires those members' jobs before this group's join reaches them.
    package func registerGroup(_ ids: [AssetID], lane: AssetPriority) -> Result<InterestToken, AssetError> {
        self.performRegisterGroup(ids, lane: lane)
    }

    /// Releases a group interest; unknown tokens are ignored (idempotent), also after shutdown. Tokens are never
    /// reused, so a second release of the same token is always a no-op (sync-1 S1-05).
    package func releaseGroup(_ token: InterestToken) {
        self.performReleaseGroup(token)
    }

    // MARK: Runs and availability (R-SYN-6…11)

    /// A run (single-flight: a second caller joins) over the retention scope (ADR-027). `.failed(.shutDown)` after
    /// shutdown.
    package func sync(_ mode: SyncMode) async -> SyncOutcome {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performSync(mode)
    }

    /// No network, no I/O (R-SYN-10).
    package func availability(scope: AssetScope) async -> Result<AvailabilityReport, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performAvailability(scope: scope)
    }

    /// Fetch-first, then fetch what is missing at user-initiated priority (R-SYN-10).
    package func ensureAvailable(scope: AssetScope) async -> Result<AvailabilityReport, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performEnsureAvailable(scope: scope)
    }

    /// Whether a launch sync is due now (R-SYN-9).
    package func isSyncDue() async -> Result<Bool, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performIsSyncDue()
    }

    /// The stamp's completion time (R-SYN-9).
    package func lastSyncedAt() async -> Result<Date?, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performLastSyncedAt()
    }

    /// Replaces the retention scope (R-CAR-5, ADR-027): the scope of the next bulk run, pushed to the store for
    /// eviction preference and pack-release exclusions. Deletes nothing, fetches nothing and starts no run.
    package func setRetentionScope(_ scope: AssetScope) async -> Result<Void, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performSetRetentionScope(scope)
    }

    // MARK: Leases, pins, cleanup, observability

    /// Acquires a lease, resolving first when the asset is absent (R-CAR-8).
    package func acquireLease(_ id: AssetID) async -> Result<AssetLease, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performAcquireLease(id)
    }

    /// Releases a lease and re-arms the alarm with the store's new deadline; a no-op after shutdown (`close()`
    /// ended every lease).
    package func releaseLease(_ lease: AssetLease) {
        self.performReleaseLease(lease)
    }

    /// Pins or unpins assets (R-CLN-4: pinned assets are never evicted; `purge(.all)` and `purge(.scope)` still
    /// remove them), through `AssetStore.setPinned` in an owned task (ADR-039).
    package func setPinned(_ ids: Set<AssetID>, pinned: Bool) async -> Result<Void, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performSetPinned(ids, pinned: pinned)
    }

    /// A user purge (R-CLN-6): bumps the purge epoch first, ends the active run with `failed(.cancelled)`.
    package func purge(_ request: PurgeRequest) async -> Result<PurgeResult, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performPurge(request)
    }

    /// GC, eviction and deep verification within a budget (R-SYN-16).
    package func performMaintenance(timeBudget: TimeInterval) async -> Result<MaintenanceReport, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.runMaintenance(timeBudget: timeBudget)
    }

    /// Quarantine and heal (R-CLN-8).
    package func reportUnreadable(_ id: AssetID) async -> Result<Void, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performReportUnreadable(id)
    }

    /// `storageReport()` (R-CLN-9): the store's report with `sourceCopyBytes` filled from
    /// `RemoteSource.sourceCopyBytes()` (H-7, transport-2 T2-13); 0 before the source exists.
    package func storageReport() async -> Result<StorageReport, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performStorageReport()
    }

    /// Engine and store counters (R-OBS-2); the facade adds the mirror's.
    package func metrics() async -> Result<MetricsSnapshot, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performMetrics()
    }

    /// Counters, the ring of recent errors (`EngineDiagnostics.recentErrorCapacity`) and the store's generation
    /// and stamp, for `diagnosticReport()` (R-OBS-3). It answers while the engine is degraded or its store cannot
    /// answer, with the last-known generation and stamp (L4-R9); after shutdown it fails `.shutDown`.
    package func diagnostics() async -> Result<EngineDiagnostics, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performDiagnostics()
    }

    /// R-CLN-11: starts (`handler` non-nil) or stops (`nil`) the engine-owned memory-pressure observer, which reads
    /// `AssetEnvironment.memoryPressure` and calls `handler` for each event. `epoch` orders calls the facade makes
    /// from unordered tasks: a call whose epoch is not greater than the last applied one is ignored. Without a
    /// `MemoryPressureSource` the request is recorded and nothing is owned. May be called from inside `handler`;
    /// the observer then ends after the handler returns. Shutdown stops it.
    package func observeMemoryPressure(
        epoch: UInt64,
        handler: (@Sendable (MemoryPressureLevel) async -> Void)?
    ) -> Result<Void, AssetError> {
        self.performObserveMemoryPressure(epoch: epoch, handler: handler)
    }

    /// The app forwarded background-session events for `identifier` (R-NET-3): make sure that session exists so
    /// the OS delivers them, and return after the preceding outcomes are staged (transport.md §10.6). After shutdown
    /// it returns `.failure(.shutDown)` at once, so the facade completes UIKit's handler without waiting.
    package func backgroundSessionEventsPending(identifier: String) async -> Result<Void, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performBackgroundEvents(identifier: identifier)
    }

    // MARK: Events (R-SYN-12, ADR-023)

    /// A pull-based stream that registers asynchronously, on its first pull. Made after shutdown, it yields
    /// `clientShutDown` and finishes (R-SYN-15); that is the facade's only use of it, once the client is shut down
    /// (its client streams register through `subscribe()`, G-16).
    package nonisolated func makeEventStream() -> AsyncStream<AssetEvent> {
        EventSubscription.stream(engine: self, registered: nil)
    }

    /// A stream that returns after registration and the initial replay; `.failure(.shutDown)` after shutdown. The
    /// facade registers every client stream, and hands every follower its replacement's stream at a reopen, through
    /// it (G-16: followership precedes registration); tests use it too.
    package func subscribe() async -> Result<AsyncStream<AssetEvent>, AssetError> {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performSubscribe()
    }

    // MARK: Introspection (R-SYN-14, P-14)

    /// The engine's counters.
    package func introspect() -> EngineIntrospection {
        self.currentIntrospection()
    }

    /// Suspends until `predicate` holds; re-evaluated after every mutation, never polled.
    package func waitUntil(_ predicate: @escaping @Sendable (EngineIntrospection) -> Bool) async {
        // REENTRANCY: RE-S26 — nothing here: the implementation re-validates the lifecycle after each of its awaits.
        await self.performWaitUntil(predicate)
    }
}
