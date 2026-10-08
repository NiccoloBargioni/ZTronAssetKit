import Foundation
import ZTronAssetModel

/// The single writer of one store root (R-STO-*, R-INT-*, R-CLN-*; WP-B and WP-C, ADR-046).
///
/// Contract rules every implementation keeps (ARCHITECTURE §4, §10):
/// - `init` performs no I/O (P-12). `open()` locks, loads, reconciles and publishes the first snapshot; every other
///   API that needs an open store fails with `.notOpen` before it (synchronous APIs) or awaits it (async APIs).
/// - The store owns **no task and no timer** (ADR-022). Deferred commits, trailing snapshot installs, the reaper and
///   grace deadlines are reported through `nextDeadline()` and executed by `runDueWork()`, which the engine's single
///   alarm calls. That keeps R-STO-5 op sequences deterministic (store-2 S2-08) and gives `blocked(.awaitingSpace)`
///   a wake-up (sync-2 S2-02).
/// - Every resumption after an `await` re-checks the phase and drops its mutation once `close()` began
///   (store-1 S1-09); `close()` drains in-flight units before its durable flush and unlock.
/// - A blob gains a reference only through one operation that awaits in-flight publications and deletions of the
///   same key (ADR-018, store-2 S2-01). DOOMED is derived from the blob table at commit capture (store-2 S2-04).
/// - Snapshot versions and commit generations are allocated synchronously at capture, before any await
///   (store-2 S2-13).
/// - Every collection becomes file operations in sorted order (store-2 S2-08).
///
/// **Ownership (ADR-046, ARCHITECTURE §1).** This file declares the actor, its two stored properties and WP-B's
/// API. WP-C's API lives in `extension AssetStore` files under `Integrity/`, `Cleanup/`, `Eviction/` and
/// `Migration/`; both packages reach the shared mutable state through `state` (`StoreState`: WP-B's `core`, WP-C's
/// `cleanup`, `eviction`, `integrity`, `migration`), and WP-C mutates WP-B's state only through the primitives in
/// `Store/StoreInternals.swift` and the direct writes `StoreCoreState` documents. WP-B's bodies call WP-C code only
/// through two opt-in hooks (`runLegacyPhaseOne()` when `configuration.legacy.enabled`, `applyEviction(_:)` when
/// `apply` receives a plan), so WP-B is implemented and tested before WP-C exists.
package actor AssetStore {
    /// The configuration (immutable).
    package nonisolated let configuration: StoreConfiguration
    /// The injected world (file system, executors, clocks, sink, log route); read by every WP's extension.
    let environment: StoreEnvironment
    /// All mutable state of the store, shared by WP-B's and WP-C's extension files (ADR-046). Mutated only on the
    /// actor; every table update after an `await` is read-modify-write (ADR-018).
    var state = StoreState()

    /// Stores configuration and environment only; no I/O (P-12).
    package init(configuration: StoreConfiguration, environment: StoreEnvironment) {
        self.configuration = configuration
        self.environment = environment
    }

    // MARK: Lifecycle (WP-B)

    /// Lock, load, reconcile (store.md §2.6 as amended by ADR-028/029), commit if needed, publish the first
    /// snapshot. Present records whose blob vanished become `needsHeal` and reset the stamp (R-CLN-7). Legacy
    /// phase 1 runs here through WP-C's `runLegacyPhaseOne()` hook, only when `configuration.legacy.enabled`;
    /// phase 2 runs afterwards through `migrateLegacy(maxFiles:)`. Releases the lock on every throwing path
    /// (store-1 S1-08). Never fails because a post-load commit failed: it then serves the loaded state read-only
    /// (store-1 S1-07).
    package func open() async throws(StoreError) -> OpenReport {
        // REENTRANCY: R1 — `performOpen` re-checks the phase after each of its units.
        try await self.performOpen()
    }

    /// Commits now (respecting the P-5 interval) at the given durability.
    package func flush(_ durability: CommitDurability) async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        // REENTRANCY: R5 — `requireCommittedInternal` re-reads coverage, the window and the phase after each await.
        try await self.requireCommittedInternal(durability)
    }

    /// Drains in-flight units, flushes durably, releases the lock. Every later call throws `.closed`.
    package func close() async {
        // REENTRANCY: R1, R5 — `performClose` re-reads the phase and the drain counter after each await.
        await self.performClose()
    }

    /// The transport's staging sink over this store's `FileSystem` and layout (available after `open()`).
    package func makeStagingSink() throws(StoreError) -> StoreStagingSink {
        try self.ensureOpenInternal()
        guard let layout = self.state.core.layout else {
            throw .notOpen
        }
        return StoreStagingSink(
            fileSystem: self.environment.fileSystem,
            layout: layout,
            bulkExecutor: self.environment.bulkExecutor,
            metadataExecutor: self.environment.metadataExecutor
        )
    }

    // MARK: Reads (no I/O; WP-B)

    /// The planner's view (R-SYN-1): values only, O(1) copy-on-write.
    package func planningView() throws(StoreError) -> StorePlanningView {
        try self.makePlanningView()
    }

    /// The resolve fast path: reads current actor state, never a stale snapshot copy (store-2 S2-12).
    package func location(for id: AssetID, extensions: [String], recordingAccess: Bool) -> AssetLocation? {
        self.currentLocation(for: id, extensions: extensions, recordingAccess: recordingAccess)
    }

    /// Counts for `availability(scope:)` (R-SYN-10); `manifestFresh` is left false for the engine to set.
    package func availability(of scope: AssetScope) -> AvailabilityReport {
        self.currentAvailability(of: scope)
    }

    /// One free-space read through `FileSystem`, plus usage, pending reclaim and the resolved budget (R-SYN-11).
    package func freeSpace() async throws(StoreError) -> FreeSpace {
        // REENTRANCY: R13 — `measureFreeSpace` re-checks the phase after its unit.
        try await self.measureFreeSpace()
    }

    // MARK: Manifest (reconcile-before-download, R-SYN-8, ADR-030; WP-B)

    /// Applies a validated manifest in **one** committed generation: relocations (index edits), prunes (doom),
    /// content changes (stale), adoption by hash (before derefs, store-1 S1-05), and the optional eviction plan
    /// through WP-C's `applyEviction(_:)` hook, which re-validates each victim. A record whose content identity
    /// changes leaves `failed` and `quarantined` and gets a clean `IntegrityHistory` ("until the manifest entry
    /// changes", R-INT-3, R-NET-6, ADR-032). Returns only after the commit (store.md D3).
    package func apply(
        _ manifest: ValidatedManifest,
        etag: ETag?,
        eviction: EvictionPlan?
    ) async throws(StoreError) -> ApplyReport {
        // REENTRANCY: R5, R6 — `performApply` mutates synchronously, then awaits the commit and the install.
        try await self.performApply(manifest, etag: etag, eviction: eviction)
    }

    /// Point admission (sync.md §6.5): adds or updates one entry without reconciling anything else and without
    /// storing the fetched manifest's ETag (sync-2 S2-28).
    package func admit(_ entry: ManifestEntry) async throws(StoreError) {
        // REENTRANCY: R5, R6 — `performAdmit` mutates synchronously, then awaits the commit and the install.
        try await self.performAdmit(entry)
    }

    /// Writes the stamp unless a purge happened since `purgeEpoch` (R-CLN-6); `.purgeRaced` otherwise.
    package func markSynced(_ stamp: SyncStamp, ifPurgeEpoch purgeEpoch: UInt64) async throws(StoreError) {
        // REENTRANCY: R5 — `performMarkSynced` compares the purge epoch before its only await.
        try await self.performMarkSynced(stamp, ifPurgeEpoch: purgeEpoch)
    }

    /// Clears the stamp and sets the persisted "sync due" flag.
    package func markSyncDue() async throws(StoreError) {
        // REENTRANCY: R5 — nothing but the phase after the commit.
        try await self.performMarkSyncDue()
    }

    /// What an Apple source may release (R-CLN-10, H-7, store-1 S1-10), built atomically: captures, synchronously
    /// and before any await, the applied manifest's remote paths, the remote paths of records present at their
    /// current content, and the applied entries outside the retention scope (`state.eviction.retentionScope`, set by
    /// WP-C's `setRetentionScope(_:)`); then commits the generation holding that state **durably**
    /// (`CommitDurability.durable`; nothing to do when it already is) and returns only what it captured. A publish
    /// that lands while the commit runs is not in the report, so a pack is released only for adoptions that survive
    /// power loss (REENTRANCY R15). Throws when the durable commit fails, so nothing is released.
    package func adoptionReport() async throws(StoreError) -> AdoptionReport {
        // REENTRANCY: R15 — the report is captured before the durable commit.
        try await self.performAdoptionReport()
    }

    // MARK: Staging and publication (WP-B)

    /// Lists `staging/` (launch reconciliation runs it **after** `reattachedTransfers()`, ADR-028).
    package func stagingInventory() async throws(StoreError) -> StagingInventory {
        // REENTRANCY: R14 — `listStaging` re-checks the phase after its unit.
        try await self.listStaging()
    }

    /// Publishes a staged file for every id in `ids` whose current content identity is `identity`:
    /// claim (`.part` → `.verifying`, store-1 S1-12) → size check against `byteSize` and
    /// `configuration.limits.maxAssetBytes` (`.oversize`) without hashing → streaming hash off the pool → remove
    /// the sidecar → barrier → exclusive rename into `blobs/` (R-STO-3, R-INT-1/2/6). A changed identity is detected
    /// **before** hashing and after every await: `.superseded`, no URL returned (store-2 S2-15). The expectation
    /// always comes from the records, never from the caller's claim (R-INT-6). On an integrity failure the staged
    /// bytes are deleted, `StoreMetrics.integrityFailures` counts it and `.integrity` is thrown; the engine records
    /// the R-INT-3 bookkeeping through `recordIntegrityFailure` (one path for transport and store failures,
    /// ADR-032).
    ///
    /// `urgency` is the lane of the work that produced the file (S2-12, ADR-016): `.userInitiated` installs the
    /// new snapshot before returning; `.prefetch` and `.bulk` install at most once per
    /// `configuration.snapshotInstallInterval`, the trailing install reported through `nextDeadline()` and run by
    /// `runDueWork()`. The returned locations are valid either way (they come from actor state, ADR-016).
    package func publish(
        _ staged: StagedFile,
        binding ids: [AssetID],
        expecting identity: ContentIdentity,
        urgency: AssetPriority
    ) async throws(StoreError) -> [AssetID: AssetLocation] {
        // REENTRANCY: R2, R3, R4, R5, R6 — `performPublish` re-validates identity and phase after every await.
        try await self.performPublish(staged, binding: ids, expecting: identity, urgency: urgency)
    }

    // MARK: Access (WP-B)

    /// Merges main-actor access stamps into the records' `lastAccess` (R-CLN-4 LRU input); clamps future times to
    /// now (store-2 S2-19). WP-B's, because every acknowledged install (REENTRANCY R6) delivers
    /// `InstallAck.accesses` here; WP-C's eviction only reads the result.
    package func recordAccesses(_ stamps: [AssetID: Date]) {
        self.recordAccessesInternal(stamps)
    }

    /// The store's counters (R-OBS-2).
    package func metrics() -> StoreMetrics {
        self.state.core.metrics
    }

    // MARK: Engine-driven scheduling (ADR-022; WP-B)

    /// The earliest instant at which `runDueWork()` has something to do because of **time alone**: a coalesced
    /// commit, a trailing snapshot install (`snapshotInstallInterval`), or a doomed key whose only remaining blocker
    /// is the awake-clock grace; `nil` when nothing is time-blocked (lease- or ack-blocked keys never keep a
    /// deadline, store-1 S1-13).
    package func nextDeadline() -> MonotonicInstant? {
        self.nextDeadlineInternal()
    }

    /// Runs what is due: a coalesced commit, the trailing snapshot install, then reap batches whose ack, awake-clock
    /// grace, commit and lease conditions hold (leases from `state.cleanup`), after one fresh no-op install proved
    /// the main actor ran (ADR-017).
    package func runDueWork() async -> StoreWorkReport {
        // REENTRANCY: R5, R6, R7, R12 — `performRunDueWork` re-checks the phase and recomputes deletable state after
        // each await.
        await self.performRunDueWork()
    }
}
