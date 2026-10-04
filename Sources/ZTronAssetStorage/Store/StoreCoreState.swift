import Foundation
import ZTronAssetModel

/// The store's lifecycle phase (store-1 S1-09, store-2 S2-07). WP-B.
enum StorePhase: Sendable, Hashable {
    /// `init` ran; nothing is open. Synchronous APIs throw `.notOpen`.
    case created
    /// `open()` is running. Synchronous APIs throw `.notOpen`; async APIs await `open()` (REENTRANCY R1).
    case opening
    /// Serving.
    case open
    /// `close()` began: no new mutation; in-flight units drain; every resumption drops its mutation.
    case closing
    /// Closed: every call throws `.closed`.
    case closed
}

/// Why and since when a blob is doomed (ADR-017, ADR-018, ARCHITECTURE §4.4). WP-B.
struct DoomInfo: Sendable, Hashable {
    /// Persisted with the key (DOOMED section); `purged` and `corrupt` are never re-adopted or rescued.
    var reason: DoomReason
    /// The first snapshot version built without the blob: an acknowledgement of this epoch at or after it starts
    /// the grace window.
    var sinceSnapshotVersion: UInt64
    /// The generation that dropped the key; it must be committed before the unlink. `0` when the key never reached
    /// a committed generation (a superseded publication, REENTRANCY R4).
    var droppedInGeneration: UInt64
    /// Acknowledgement instant plus `deletionGrace` on the **awake** clock (ADR-017); `nil` until acknowledged.
    var eligibleAt: MonotonicInstant?
    /// Failed unlink attempts (the key stays doomed with backoff).
    var failedUnlinks: Int

    /// Creates doom bookkeeping.
    init(
        reason: DoomReason,
        sinceSnapshotVersion: UInt64,
        droppedInGeneration: UInt64,
        eligibleAt: MonotonicInstant? = nil,
        failedUnlinks: Int = 0
    ) {
        self.reason = reason
        self.sinceSnapshotVersion = sinceSnapshotVersion
        self.droppedInGeneration = droppedInGeneration
        self.eligibleAt = eligibleAt
        self.failedUnlinks = failedUnlinks
    }
}

/// One blob in the blob table (ADR-018, store.md §4.5). WP-B.
enum BlobState: Sendable, Hashable {
    /// Referenced by `references` records (≥ 1).
    case live(references: Int)
    /// No record references it; deleted after the I-3 conditions hold (§4.4).
    case doomed(DoomInfo)
    /// A deletion unit holding it is in flight; publications of the key await it (REENTRANCY R3, R7).
    case deleting
}

/// WP-B's part of `StoreState` (ADR-046). The fields below are contract fields: WP-C reads them, and writes only the
/// ones its documentation names (ARCHITECTURE §1.1 rule 1, amended in contract-fix round 4 for legacy migration),
/// always followed by `markDirty(_:)` or a `requireCommitted(_:)`. WP-B adds its own bookkeeping (commit scheduling,
/// generation counters, snapshot versions and acknowledgements, dirty directories, waiting publishers) as further
/// fields in this file.
struct StoreCoreState: Sendable {
    /// The lifecycle (`ensureOpen()` reads it).
    var phase: StorePhase = .created
    /// The resolved layout; `nil` before `open()`.
    var layout: StoreLayout?
    /// The held advisory lock (R-STO-9); `nil` before `open()` and after `close()`.
    var lock: FileLockToken?
    /// The launch epoch allocated at `open()` (ADR-013, ADR-016).
    var launchEpoch: UInt64 = 0
    /// The newest committed generation.
    var committedGeneration: UInt64 = 0
    /// No valid index or a newer schema at load: orphan GC and DOOMED deletion are suspended (R-STO-4, S1-11).
    /// WP-C's garbage collection reads it; legacy phase 1 (WP-C) sets it when the prior art's `manifest.json` cannot
    /// be decoded, so the legacy files it moves stay protected orphans (store.md §7).
    var degraded = false
    /// The applied manifest (planner order; purge scopes and migration plans read it). Legacy phase 1 (WP-C)
    /// installs the decoded legacy manifest here, with `etag` left `nil`, only when it is still empty (a first launch
    /// after the upgrade), so newer state is never overridden (ADR-029; the H-10 test `R-STO-11: lookups hit adopted
    /// legacy files while migration is still running…` depends on it).
    var appliedManifest: ValidatedManifest = .empty()
    /// The applied manifest's entity tag.
    var etag: ETag?
    /// Records by id. WP-C writes `pinned` (`setPinned`), `integrity` (`recordIntegrityFailure`) and `verifiedAt`
    /// (`verifyIntegrity`) directly, then calls `markDirty(_:)`; residency changes go through
    /// `setResidency(_:of:dooming:)` or `adoptVerifiedFile(at:digest:byteCount:for:)`. One insertion is WP-C's:
    /// legacy phase 1 inserts a record for each legacy entry the applied manifest lists and the index has no record
    /// for, always as `absent(.neverFetched)` with `expectedBlob` set (the adoption key), never replacing a record.
    var records: [AssetID: AssetRecord] = [:]
    /// The sync stamp (R-STO-2); `purge` (WP-C) clears it in the purge's commit; legacy phase 3 (WP-C) sets it
    /// from the legacy stamp only when every legacy entry was adopted (ADR-029).
    var stamp: SyncStamp?
    /// The persisted "sync due" flag. Legacy phase 3 (WP-C) sets it, directly or through `markSyncDue()`, when not
    /// every legacy entry was adopted.
    var syncDue = false
    /// Bumped by every purge (WP-C) before any await; `markSynced` compares it (R-CLN-6, RE-S11).
    var purgeEpoch: UInt64 = 0
    /// Every blob the store knows: live, doomed or being deleted. WP-C reads it (GC mark set, storage report) and
    /// dooms through `setResidency(_:of:dooming:)`.
    var blobTable: [BlobKey: BlobState] = [:]
    /// Keys whose publication or adoption is between claim and commit: never collected, never deleted (ADR-018).
    var publishing: Set<BlobKey> = []
    /// Counters (R-OBS-2). WP-C increments `evictions`, `evictedBytes` and `gcBytes`.
    var metrics = StoreMetrics()
}
