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
    /// Keys whose placement is in flight: a new key (not yet in `blobTable`), or a doomed `purged`/`corrupt` name
    /// being replaced (already `live`). Never collected, never deleted; every other binder of the key waits until it
    /// leaves the set (ADR-018, REENTRANCY R3; ADR draft B-18).
    var publishing: Set<BlobKey> = []
    /// Counters (R-OBS-2). WP-C increments `evictions`, `evictedBytes` and `gcBytes`.
    var metrics = StoreMetrics()

    // MARK: WP-B bookkeeping (not read or written by WP-C)

    /// The index lineage (store.md §2.3).
    var storeID = StoreIdentifier.zero
    /// The next generation to allocate: every commit **attempt** takes one at capture (I-5, store-1 S1-16).
    var nextGeneration: UInt64 = 1
    /// What `open()` returned, for a second call.
    var openReport: OpenReport?
    /// Callers suspended until `open()` finishes (REENTRANCY R1); each re-reads the phase.
    var openWaiters: [CheckedContinuation<Void, Never>] = []
    /// Further `open()` calls made while one runs. The running open hands each of them its own outcome (its report, or
    /// `nil` when it failed) instead of letting them re-read the phase: a `close()` that began between that open's end
    /// and their resumption would otherwise decide what they return (close-out cycle 4, ADR draft B-35).
    var openReportWaiters: [CheckedContinuation<OpenReport?, Never>] = []
    /// Commit scheduling (P-5, ARCHITECTURE §4.1).
    var commits = CommitBookkeeping()
    /// Snapshot versions, installs and acknowledgements (ADR-016, ADR-017).
    var snapshots = SnapshotBookkeeping()
    /// The snapshot entry of every present record, maintained per changed record (O(1) publication).
    var presentTable: [AssetID: SnapshotEntry] = [:]
    /// The size of every blob the table knows (live, doomed or being deleted): usage, pending reclaim, reaped bytes.
    var blobBytes: [BlobKey: Int64] = [:]
    /// The doom bookkeeping of each key whose deletion unit is in flight (`BlobState.deleting` carries none): a
    /// commit captured meanwhile still persists the reason in DOOMED, and a failed unlink restores it with backoff.
    var deletingDooms: [BlobKey: DoomInfo] = [:]
    /// The doom of each `purged` or `corrupt` key whose replacement placement is in flight (`acquireReference`'s
    /// `.replaced`; the table says `live` meanwhile): a commit captured before the replacement rename still persists
    /// it in DOOMED, so launch never adopts the doomed bytes still under the name (ADR draft B-24).
    var replacingDooms: [BlobKey: DoomInfo] = [:]
    /// Publishers waiting for an in-flight publication or deletion of the same key (REENTRANCY R3, R7).
    var keyWaiters: [BlobKey: [CheckedContinuation<Void, Never>]] = [:]
    /// Unreferenced, undoomed blobs listed at launch: adoptable by a later `apply` (degraded rebuild, store.md
    /// §2.6); each is stat-ed again before it is bound.
    var orphans: [BlobKey: Int64] = [:]
    /// Units and installs whose continuation has not resumed yet; `close()` drains them (store-1 S1-09).
    var unitsInFlight = 0
    /// `close()` waiting for `unitsInFlight` to reach zero.
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Later `close()` calls that arrived while the first one was draining or flushing: each returns only once the
    /// first one's durable commit and lock release are done (phase `closed`), so a caller may reopen the root right
    /// after (proposed REENTRANCY row b-9).
    var closeWaiters: [CheckedContinuation<Void, Never>] = []
    /// The root was replaced or vanished while running: no further commit (store-1 S1-08).
    var unavailable: StorageUnavailableReason?
    /// The staging sequence of the next extra-extension copy (`bindCopy`): allocated by the store, counting down
    /// from `UInt32.max` so it never meets the engine's start counter, and never shared by two copies.
    var nextCopySequence: UInt32 = .max
    /// Bumped whenever `apply` or `admit` replaces `appliedManifest`: a diff computed off the actor against an older
    /// manifest is discarded (`apply`, proposed REENTRANCY row b-6).
    var manifestRevision: UInt64 = 0
    /// Serialises `apply` and `admit`, which yield between chunks (C2, proposed REENTRANCY row b-7).
    var applyGate = ApplyGate()
}

/// The gate that lets one `apply` or `admit` run at a time, and the commit fence of `apply`'s writes.
struct ApplyGate: Sendable {
    /// An `apply` or `admit` holds the gate.
    var held = false
    /// Callers waiting for it; `close()` resumes them and they unwind with `.closed`.
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// The commit fence (ADR draft B-23): `apply` is writing its chunks, so the state is half applied (the new
    /// manifest and ETag are installed, records are not all added, changed or pruned yet). No commit captures it
    /// (`requireCommitted` waits, `runDueWork` skips its commit), `adoptionReport()` does not capture it, and
    /// `close()` waits before its durable commit. Raised before `apply`'s first write, lowered after its last.
    var writing = false
    /// Callers waiting for the fence to drop (proposed REENTRANCY row b-8).
    var writeWaiters: [CheckedContinuation<Void, Never>] = []
}

/// Commit scheduling (P-5): mutations are counted, commits cover a prefix of them, and at most one commit runs at
/// a time; `.soon` mutations are flushed within `commitMinimumInterval` through `nextDeadline()`/`runDueWork()`.
struct CommitBookkeeping: Sendable {
    /// Bumped by every `markDirty`.
    var mutationSerial: UInt64 = 0
    /// The serial of the newest `.soon` mutation.
    var soonSerial: UInt64 = 0
    /// Mutations up to this serial are in a committed generation.
    var committedSerial: UInt64 = 0
    /// Mutations up to this serial are in a durably committed generation.
    var durableSerial: UInt64 = 0
    /// Monotonic start of the latest commit attempt: the coalescing window opens `commitMinimumInterval` later.
    var lastAttemptAt: MonotonicInstant?
    /// A commit unit is running.
    var inFlight = false
    /// Commit attempts that failed in a row since the last success: the scheduled retry (`nextDeadline()`,
    /// `runDueWork()`) backs off exponentially, and only the first failure of a streak logs an error (ADR draft B-29).
    var consecutiveFailures = 0
    /// Callers waiting for the running commit to finish (REENTRANCY R5).
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// Fan-outs that received or adopted a blob since the last successful commit.
    var dirtyFanOuts: Set<String> = []
    /// `blobs/` must be barrier-synced by the next commit (after open, or when a fan-out was created).
    var blobsDirectoryDirty = false
    /// The generation of the `index.tmp` the launch loaded, until a commit unit renamed it to `index.bin` (ADR draft
    /// B-28): every commit attempt promotes it before it writes `index.tmp` again.
    var pendingPromotion: UInt64?
    /// The index name that holds `StoreCoreState.committedGeneration` (ADR draft B-28, close-out cycle 5): set from the
    /// load, which validated that file in full, and moved by every commit unit's renames (`IndexCommitLedger`); `nil`
    /// while nothing is committed. Step 4 and the ENOSPC fallback trust it, never a header that may have rotted.
    var committedFile: IndexFile?

    /// Whether a `.soon` mutation is not yet committed.
    var soonPending: Bool {
        self.soonSerial > self.committedSerial
    }

    /// Whether every mutation up to `serial` is committed at `durability`.
    func covers(_ serial: UInt64, _ durability: CommitDurability) -> Bool {
        switch durability {
        case .ordered:
            return self.committedSerial >= serial
        case .durable:
            return self.durableSerial >= serial
        }
    }
}

/// Snapshot publication and acknowledgement (ADR-016, ADR-017, ARCHITECTURE §5).
struct SnapshotBookkeeping: Sendable {
    /// The last version allocated (versions are allocated when a snapshot is built, store-2 S2-13).
    var version: UInt64 = 0
    /// The newest version of this epoch the sink acknowledged.
    var acknowledgedVersion: UInt64 = 0
    /// Awake-clock start of the newest install whose acknowledgement was of this epoch: a doomed key whose grace
    /// ended before it is proven unobserved by the main actor (the "fresh acknowledgement" of ADR-017).
    var lastAcknowledgedInstallStart: MonotonicInstant?
    /// Awake-clock start of the newest install, acknowledged or not.
    var lastInstallStart: MonotonicInstant?
    /// Monotonic time of the newest install (bulk and prefetch installs are rate-limited from it).
    var lastInstallAt: MonotonicInstant?
    /// A bulk or prefetch publication is not installed yet: the trailing install is a deadline.
    var installDue = false
}
