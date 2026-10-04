import Foundation
import ZTronAssetModel

/// The single writer of one store root (R-STO-*, R-INT-*, R-CLN-*; owned by WP-B and WP-C).
///
/// Contract rules every implementation keeps (ARCHITECTURE §4, §10):
/// - `init` performs no I/O (P-12). `open()` locks, loads, reconciles and publishes the first snapshot; every other
///   API that needs an open store fails with `.notOpen` before it (synchronous APIs) or awaits it (async APIs).
/// - The store owns **no task and no timer** (ADR-022). Deferred commits, the reaper and grace deadlines are
///   reported through `nextDeadline()` and executed by `runDueWork()`, which the engine's single alarm calls. That
///   keeps R-STO-5 op sequences deterministic (store-2 S2-08) and gives `blocked(.awaitingSpace)` a wake-up
///   (sync-2 S2-02).
/// - Every resumption after an `await` re-checks the phase and drops its mutation once `close()` began
///   (store-1 S1-09); `close()` drains in-flight units before its durable flush and unlock.
/// - A blob gains a reference only through one operation that awaits in-flight publications and deletions of the
///   same key (ADR-018, store-2 S2-01). DOOMED is derived from the blob table at commit capture (store-2 S2-04).
/// - Snapshot versions and commit generations are allocated synchronously at capture, before any await
///   (store-2 S2-13).
/// - Every collection becomes file operations in sorted order (store-2 S2-08).
package actor AssetStore {
    /// The configuration (immutable).
    package nonisolated let configuration: StoreConfiguration
    private let environment: StoreEnvironment

    /// Stores configuration and environment only; no I/O (P-12).
    package init(configuration: StoreConfiguration, environment: StoreEnvironment) {
        self.configuration = configuration
        self.environment = environment
    }

    // MARK: Lifecycle

    /// Lock, load, reconcile (store.md §2.6 as amended by ADR-028/029), commit if needed, publish the first
    /// snapshot. Legacy phase 1 runs here; phase 2 runs afterwards through `migrateLegacy(maxFiles:)`. Releases the
    /// lock on every throwing path (store-1 S1-08). Never fails because a post-load commit failed: it then serves
    /// the loaded state read-only (store-1 S1-07).
    package func open() async throws(StoreError) -> OpenReport {
        fatalError("WP-B: AssetStore.open not implemented")
    }

    /// Commits now (respecting the P-5 interval) at the given durability.
    package func flush(_ durability: CommitDurability) async throws(StoreError) {
        fatalError("WP-B: AssetStore.flush not implemented")
    }

    /// Drains in-flight units, flushes durably, releases the lock. Every later call throws `.closed`.
    package func close() async {
        fatalError("WP-B: AssetStore.close not implemented")
    }

    /// The transport's staging sink over this store's `FileSystem` and layout (available after `open()`).
    package func makeStagingSink() throws(StoreError) -> StoreStagingSink {
        fatalError("WP-B: AssetStore.makeStagingSink not implemented")
    }

    // MARK: Reads (no I/O)

    /// The planner's view (R-SYN-1): values only, O(1) copy-on-write.
    package func planningView() throws(StoreError) -> StorePlanningView {
        fatalError("WP-B: AssetStore.planningView not implemented")
    }

    /// The resolve fast path: reads current actor state, never a stale snapshot copy (store-2 S2-12).
    package func location(for id: AssetID, extensions: [String], recordingAccess: Bool) -> AssetLocation? {
        fatalError("WP-B: AssetStore.location not implemented")
    }

    /// Counts for `availability(scope:)` (R-SYN-10); `manifestFresh` is left false for the engine to set.
    package func availability(of scope: AssetScope) -> AvailabilityReport {
        fatalError("WP-B: AssetStore.availability not implemented")
    }

    /// One free-space read through `FileSystem`, plus usage, pending reclaim and the resolved budget (R-SYN-11).
    package func freeSpace() async throws(StoreError) -> FreeSpace {
        fatalError("WP-B: AssetStore.freeSpace not implemented")
    }

    // MARK: Manifest (reconcile-before-download, R-SYN-8, ADR-030)

    /// The eviction dry run (X-2): what evicting `bytes` would remove, never touching `protecting`; `nil` when the
    /// target is unreachable. Pure over current state; no mutation. Victims outside the retention scope come first
    /// (`setRetentionScope(_:)`, ADR-027), then the R-CLN-4 order.
    package func evictionPlan(toFree bytes: Int64, protecting: Set<AssetID>) -> EvictionPlan? {
        fatalError("WP-C: AssetStore.evictionPlan not implemented")
    }

    /// Applies a validated manifest in **one** committed generation: relocations (index edits), prunes (doom),
    /// content changes (stale), adoption by hash (before derefs, store-1 S1-05), and the optional eviction plan,
    /// re-validating each victim. Returns only after the commit (store.md D3).
    package func apply(
        _ manifest: ValidatedManifest,
        etag: ETag?,
        eviction: EvictionPlan?
    ) async throws(StoreError) -> ApplyReport {
        fatalError("WP-B: AssetStore.apply not implemented")
    }

    /// Point admission (sync.md §6.5): adds or updates one entry without reconciling anything else and without
    /// storing the fetched manifest's ETag (sync-2 S2-28).
    package func admit(_ entry: ManifestEntry) async throws(StoreError) {
        fatalError("WP-B: AssetStore.admit not implemented")
    }

    /// Writes the stamp unless a purge happened since `purgeEpoch` (R-CLN-6); `.purgeRaced` otherwise.
    package func markSynced(_ stamp: SyncStamp, ifPurgeEpoch purgeEpoch: UInt64) async throws(StoreError) {
        fatalError("WP-B: AssetStore.markSynced not implemented")
    }

    /// Clears the stamp and sets the persisted "sync due" flag.
    package func markSyncDue() async throws(StoreError) {
        fatalError("WP-B: AssetStore.markSyncDue not implemented")
    }

    /// The client's retention scope (R-CAR-5, ADR-027): what the app wants kept, e.g. the entries its paywall
    /// unlocks. Entries outside it are evicted before any entry inside it and are reported in
    /// `AdoptionReport.excludedRemotePaths`, so they never block an Apple pack release (transport-2 T2-13).
    /// In-memory and valid in any phase (it starts as `.all`); the engine sets it after `open()` and whenever the app
    /// changes it. Setting it deletes nothing and fetches nothing by itself.
    package func setRetentionScope(_ scope: AssetScope) {
        fatalError("WP-C: AssetStore.setRetentionScope not implemented")
    }

    /// What an Apple source may release (R-CLN-10, H-7, store-1 S1-10), built atomically: captures, synchronously
    /// and before any await, the applied manifest's remote paths, the remote paths of records present at their
    /// current content, and the applied entries outside the retention scope; then commits the generation holding
    /// that state **durably** (`CommitDurability.durable`; nothing to do when it already is) and returns only what
    /// it captured. A publish that lands while the commit runs is not in the report, so a pack is released only for
    /// adoptions that survive power loss (REENTRANCY R15). Throws when the durable commit fails, so nothing is
    /// released.
    package func adoptionReport() async throws(StoreError) -> AdoptionReport {
        fatalError("WP-B: AssetStore.adoptionReport not implemented")
    }

    // MARK: Staging and publication

    /// Lists `staging/` (launch reconciliation runs it **after** `reattachedTransfers()`, ADR-028).
    package func stagingInventory() async throws(StoreError) -> StagingInventory {
        fatalError("WP-B: AssetStore.stagingInventory not implemented")
    }

    /// Publishes a staged file for every id in `ids` whose current content identity is `identity`:
    /// claim (`.part` → `.verifying`, store-1 S1-12) → size check → streaming hash off the pool → remove the
    /// sidecar → barrier → exclusive rename into `blobs/` (R-STO-3). A changed identity is detected **before**
    /// hashing and after every await: `.superseded`, no URL returned (store-2 S2-15). The expectation always comes
    /// from the records, never from the caller's claim (R-INT-6).
    package func publish(
        _ staged: StagedFile,
        binding ids: [AssetID],
        expecting identity: ContentIdentity
    ) async throws(StoreError) -> [AssetID: AssetLocation] {
        fatalError("WP-B: AssetStore.publish not implemented")
    }

    /// Removes every staging file whose transfer is not in `claimed`, older than `stagingClaimGrace`
    /// (ADR-028, R-CLN-3).
    package func collectStaging(keeping claimed: Set<TransferID>) async throws(StoreError) -> CleanupResult {
        fatalError("WP-C: AssetStore.collectStaging not implemented")
    }

    // MARK: Access, leases, pins

    /// Merges main-actor access stamps (R-CLN-4); clamps future times to now (store-2 S2-19).
    package func recordAccesses(_ stamps: [AssetID: Date]) {
        fatalError("WP-C: AssetStore.recordAccesses not implemented")
    }

    /// Pins an asset's blob for the lease's lifetime (R-CAR-8); no await, so no window.
    package func acquireLease(_ id: AssetID) throws(StoreError) -> AssetLease {
        fatalError("WP-C: AssetStore.acquireLease not implemented")
    }

    /// Releases a lease; idempotent per token. Returns the store's new deadline so the engine can re-arm
    /// (a lease was the reaper's only blocker, store-2 S2-03).
    package func releaseLease(_ lease: AssetLease) -> MonotonicInstant? {
        fatalError("WP-C: AssetStore.releaseLease not implemented")
    }

    /// Persists pins.
    package func setPinned(_ ids: Set<AssetID>, pinned: Bool) async throws(StoreError) {
        fatalError("WP-C: AssetStore.setPinned not implemented")
    }

    // MARK: Cleanup (R-CLN-*; each idempotent and cancellation-safe)

    /// Quota eviction down to the hysteresis target, counting pending reclaim (store-2 S2-06); entries outside the
    /// retention scope first (ADR-027).
    package func evictIfNeeded() async throws(StoreError) -> CleanupResult {
        fatalError("WP-C: AssetStore.evictIfNeeded not implemented")
    }

    /// Orphan mark and sweep in bounded units until `deadline` (R-CLN-2, P-13).
    package func collectGarbage(until deadline: MonotonicInstant) async throws(StoreError) -> CleanupResult {
        fatalError("WP-C: AssetStore.collectGarbage not implemented")
    }

    /// A user purge (R-CLN-6). Clears the stamp in the same commit; bumps `purgeEpoch`. Returns after the
    /// selection is reaped, rescued or deferred by a lease; the grace wait runs in the caller's (engine-owned) task.
    package func purge(_ request: PurgeRequest) async throws(StoreError) -> PurgeResult {
        fatalError("WP-C: AssetStore.purge not implemented")
    }

    /// Quarantines the entry and dooms its blob as `.corrupt` (R-CLN-8, ADR-018).
    package func reportUnreadable(_ id: AssetID) async throws(StoreError) {
        fatalError("WP-C: AssetStore.reportUnreadable not implemented")
    }

    /// Deep verification from the oldest `verifiedAt`, within a byte budget and a deadline (R-INT-4).
    package func verifyIntegrity(byteBudget: Int64, until deadline: MonotonicInstant) async throws(StoreError)
        -> VerificationReport
    {
        fatalError("WP-C: AssetStore.verifyIntegrity not implemented")
    }

    /// Records an integrity failure for content that failed verification (R-INT-3), persisted.
    package func recordIntegrityFailure(_ ids: [AssetID], identity: ContentIdentity) async throws(StoreError) {
        fatalError("WP-C: AssetStore.recordIntegrityFailure not implemented")
    }

    /// `storageReport()` (R-CLN-9).
    package func storageReport() async -> StorageReport {
        fatalError("WP-C: AssetStore.storageReport not implemented")
    }

    /// The store's counters (R-OBS-2).
    package func metrics() -> StoreMetrics {
        fatalError("WP-B: AssetStore.metrics not implemented")
    }

    // MARK: Engine-driven scheduling (ADR-022)

    /// The earliest instant at which `runDueWork()` has something to do because of **time alone**; `nil` when
    /// nothing is time-blocked (lease- or ack-blocked keys never keep a deadline, store-1 S1-13).
    package func nextDeadline() -> MonotonicInstant? {
        fatalError("WP-B: AssetStore.nextDeadline not implemented")
    }

    /// Runs what is due: a coalesced commit, then reap batches whose ack, awake-clock grace, commit and lease
    /// conditions hold, after one fresh no-op install proved the main actor ran (ADR-017).
    package func runDueWork() async -> StoreWorkReport {
        fatalError("WP-B: AssetStore.runDueWork not implemented")
    }

    // MARK: Legacy migration phase 2 (ADR-029)

    /// Adopts up to `maxFiles` legacy files (hash, then rename), publishing snapshots as it goes; phases 3 and 4
    /// run when nothing remains.
    package func migrateLegacy(maxFiles: Int) async throws(StoreError) -> LegacyMigrationProgress {
        fatalError("WP-C: AssetStore.migrateLegacy not implemented")
    }

    /// Adopt-on-demand for a `resolve` or lease of a legacy id not yet adopted (store-2 S2-09).
    package func adoptLegacyNow(_ id: AssetID) async throws(StoreError) -> AssetLocation? {
        fatalError("WP-C: AssetStore.adoptLegacyNow not implemented")
    }
}
