import Foundation
import ZTronAssetModel

/// Durability of an index commit (ADR-015).
package enum CommitDurability: Sendable, Hashable {
    /// `F_BARRIERFSYNC` on the temp file and the root: ordered before every later write (I-2, I-3, I-5). The
    /// coalesced default.
    case ordered
    /// `F_FULLFSYNC`: survives power loss. Required before an irrevocable step outside the ordering domain
    /// (legacy key removal, Apple pack release) and on `flush()`/`close()`.
    case durable
}

/// Store configuration (R-STO-10, ADR-001, ADR-035).
package struct StoreConfiguration: Sendable, Hashable {
    /// Where the root lives.
    package var location: StorageLocation
    /// Budget, grace windows, integrity backoff (ADR-035).
    package var policy: StoragePolicy
    /// The prior-art layout to migrate (R-STO-11).
    package var legacy: LegacyMigrationPolicy
    /// P-5: commits are coalesced to at most one per this interval (0.25 s ⇒ ≤ 4/s).
    package var commitMinimumInterval: TimeInterval
    /// P-13: unlinks per deletion unit.
    package var deletionBatchSize: Int
    /// R-INT-1: bytes per hash unit (≤ 1 MiB).
    package var hashChunkBytes: Int

    /// Creates a configuration with the store design's defaults.
    package init(
        location: StorageLocation = .applicationSupport,
        policy: StoragePolicy = StoragePolicy(),
        legacy: LegacyMigrationPolicy = LegacyMigrationPolicy(),
        commitMinimumInterval: TimeInterval = 0.25,
        deletionBatchSize: Int = 64,
        hashChunkBytes: Int = 1 << 20
    ) {
        self.location = location
        self.policy = policy
        self.legacy = legacy
        self.commitMinimumInterval = commitMinimumInterval
        self.deletionBatchSize = deletionBatchSize
        self.hashChunkBytes = hashChunkBytes
    }
}

/// What the store takes from `AssetEnvironment`, plus the snapshot sink the facade wires in.
package struct StoreEnvironment: Sendable {
    /// Every file-system effect (R-STO-6).
    package var fileSystem: any FileSystem
    /// Commits, renames, unlinks, listings.
    package var metadataExecutor: any BlockingExecutor
    /// Hash and copy reads.
    package var bulkExecutor: any BlockingExecutor
    /// Wall clock (persisted stamps), monotonic and awake clocks (grace, ADR-017).
    package var time: any TimeSource
    /// The store identity (`storeID`) derives from it.
    package var random: any RandomSource
    /// The legacy `UserDefaults` stamp.
    package var legacyDefaults: any LegacyDefaults
    /// The acknowledgement protocol (ADR-016).
    package var snapshotSink: any SnapshotSink
    /// Optional log tap.
    package var logTap: (any LogTap)?

    /// Takes the store's part of an environment.
    package init(environment: AssetEnvironment, snapshotSink: any SnapshotSink) {
        self.fileSystem = environment.fileSystem
        self.metadataExecutor = environment.metadataExecutor
        self.bulkExecutor = environment.bulkExecutor
        self.time = environment.time
        self.random = environment.random
        self.legacyDefaults = environment.legacyDefaults
        self.snapshotSink = snapshotSink
        self.logTap = environment.logTap
    }
}

/// What `open()` found and did (store.md §2.6 as amended by ADR-028/029).
package struct OpenReport: Sendable, Hashable {
    /// The launch epoch: the generation allocated at open; prefixes every attempt token (ADR-013).
    package var launchEpoch: UInt64
    /// The committed generation after launch reconciliation.
    package var generation: UInt64
    /// No valid index, or a newer schema: orphan and DOOMED deletion suspended (R-STO-4).
    package var degraded: Bool
    /// Present records whose blob vanished (R-CLN-7); non-zero resets the stamp.
    package var missingBlobs: Int
    /// Legacy files remain to be adopted by `migrateLegacy(maxFiles:)` (ADR-029).
    package var legacyMigrationPending: Bool
    /// The stamp after reconciliation.
    package var stamp: SyncStamp?
    /// Whether a sync is due regardless of the refresh policy.
    package var syncDue: Bool

    /// Creates a report.
    package init(
        launchEpoch: UInt64,
        generation: UInt64,
        degraded: Bool,
        missingBlobs: Int,
        legacyMigrationPending: Bool,
        stamp: SyncStamp?,
        syncDue: Bool
    ) {
        self.launchEpoch = launchEpoch
        self.generation = generation
        self.degraded = degraded
        self.missingBlobs = missingBlobs
        self.legacyMigrationPending = legacyMigrationPending
        self.stamp = stamp
        self.syncDue = syncDue
    }
}

/// What `apply(_:etag:eviction:)` did (R-SYN-8). The planner's `ReconcileStep` must equal it for the same inputs
/// (ADR-030).
package struct ApplyReport: Sendable, Hashable {
    /// The committed generation recording the manifest.
    package var generation: UInt64
    /// Ids added (absent until fetched or adopted).
    package var added: [AssetID]
    /// Ids whose content changed (stale until the new blob commits).
    package var contentChanged: [AssetID]
    /// Ids whose metadata changed: index edits, zero file operations.
    package var relocated: [AssetID]
    /// Ids bound to a blob already on disk (dedupe, renamed id, launch-window adoption).
    package var reused: [AssetID]
    /// Ids removed from the manifest; their blobs are doomed.
    package var pruned: [AssetID]
    /// Ids evicted by the accompanying eviction plan.
    package var evicted: [AssetID]

    /// Creates a report.
    package init(
        generation: UInt64,
        added: [AssetID] = [],
        contentChanged: [AssetID] = [],
        relocated: [AssetID] = [],
        reused: [AssetID] = [],
        pruned: [AssetID] = [],
        evicted: [AssetID] = []
    ) {
        self.generation = generation
        self.added = added
        self.contentChanged = contentChanged
        self.relocated = relocated
        self.reused = reused
        self.pruned = pruned
        self.evicted = evicted
    }
}

/// Free-space inputs of the planner (R-SYN-11).
package struct FreeSpace: Sendable, Hashable {
    /// Free space for important usage.
    package var volumeImportant: Int64
    /// Free space for opportunistic usage (bulk, prefetch).
    package var volumeOpportunistic: Int64
    /// Bytes of live blobs.
    package var usedBytes: Int64
    /// Doomed, unleased bytes that will be freed after ack and grace (store-2 S2-06).
    package var pendingReclaim: Int64
    /// The resolved budget.
    package var budgetBytes: Int64
    /// `StoragePolicy.reserveFreeBytes`.
    package var reserveBytes: Int64

    /// Creates free-space inputs.
    package init(
        volumeImportant: Int64,
        volumeOpportunistic: Int64,
        usedBytes: Int64,
        pendingReclaim: Int64,
        budgetBytes: Int64,
        reserveBytes: Int64
    ) {
        self.volumeImportant = volumeImportant
        self.volumeOpportunistic = volumeOpportunistic
        self.usedBytes = usedBytes
        self.pendingReclaim = pendingReclaim
        self.budgetBytes = budgetBytes
        self.reserveBytes = reserveBytes
    }
}

/// One asset eviction would remove.
package struct EvictionVictim: Sendable, Hashable {
    /// The asset.
    package var id: AssetID
    /// Its blob.
    package var blob: BlobKey
    /// Bytes freed once deleted.
    package var byteSize: Int64
    /// Its last access (LRU order).
    package var lastAccess: Date

    /// Creates a victim.
    package init(id: AssetID, blob: BlobKey, byteSize: Int64, lastAccess: Date) {
        self.id = id
        self.blob = blob
        self.byteSize = byteSize
        self.lastAccess = lastAccess
    }
}

/// The dry run of an eviction (R-CLN-4, R-SYN-11, X-2): computed without mutating anything, re-validated per
/// victim when applied.
package struct EvictionPlan: Sendable, Hashable {
    /// Victims in eviction order: outside the retention scope first (ADR-027), then LRU, larger first on ties,
    /// then hash; Apple-adopted assets after ordinary ones of the same class (ADR-027).
    package var victims: [EvictionVictim]
    /// Bytes the plan frees.
    package var bytes: Int64

    /// Creates a plan.
    package init(victims: [EvictionVictim], bytes: Int64) {
        self.victims = victims
        self.bytes = bytes
    }
}

/// The planner's read-only view of the index (R-SYN-1): values only, copy-on-write, O(1) to take.
package struct StorePlanningView: Sendable {
    /// The committed generation.
    package var generation: UInt64
    /// The applied manifest (entry order is the planner's stable order).
    package var appliedManifest: ValidatedManifest
    /// Records by id.
    package var records: [AssetID: AssetRecord]
    /// Hashes of live blobs (dedupe without I/O).
    package var liveBlobs: Set<ContentHash>
    /// Bumped by every purge (R-CLN-6, RE-S11).
    package var purgeEpoch: UInt64
    /// The stamp.
    package var stamp: SyncStamp?
    /// The persisted "sync due" flag.
    package var syncDue: Bool

    /// Creates a view.
    package init(
        generation: UInt64,
        appliedManifest: ValidatedManifest,
        records: [AssetID: AssetRecord],
        liveBlobs: Set<ContentHash>,
        purgeEpoch: UInt64,
        stamp: SyncStamp?,
        syncDue: Bool
    ) {
        self.generation = generation
        self.appliedManifest = appliedManifest
        self.records = records
        self.liveBlobs = liveBlobs
        self.purgeEpoch = purgeEpoch
        self.stamp = stamp
        self.syncDue = syncDue
    }
}

/// The staging directory as listed (launch reconciliation, ADR-028).
package struct StagingInventory: Sendable, Hashable {
    /// Our own names, with their metadata.
    package var items: [StagingFileName: FileItemInfo]
    /// Names that do not parse (garbage for staging GC).
    package var foreign: [String]

    /// Creates an inventory.
    package init(items: [StagingFileName: FileItemInfo], foreign: [String]) {
        self.items = items
        self.foreign = foreign
    }
}

/// The outcome of a cleanup step (R-CLN-*).
package struct CleanupResult: Sendable, Hashable {
    /// Bytes deleted.
    package var bytesFreed: Int64
    /// Files deleted.
    package var filesRemoved: Int
    /// Bytes selected but still leased.
    package var bytesDeferred: Int64

    /// Creates a result.
    package init(bytesFreed: Int64 = 0, filesRemoved: Int = 0, bytesDeferred: Int64 = 0) {
        self.bytesFreed = bytesFreed
        self.filesRemoved = filesRemoved
        self.bytesDeferred = bytesDeferred
    }
}

/// The outcome of a deep-verification slice (R-INT-4).
package struct VerificationReport: Sendable, Hashable {
    /// Bytes re-hashed.
    package var bytesVerified: Int64
    /// Assets whose blob did not match its name (quarantined, R-CLN-8).
    package var corrupt: [AssetID]
    /// Whether every present blob was verified (the cursor wrapped).
    package var completedPass: Bool

    /// Creates a report.
    package init(bytesVerified: Int64, corrupt: [AssetID], completedPass: Bool) {
        self.bytesVerified = bytesVerified
        self.corrupt = corrupt
        self.completedPass = completedPass
    }
}

/// What one `runDueWork()` call did (ADR-022: the engine's alarm drives every store deadline).
package struct StoreWorkReport: Sendable, Hashable {
    /// A coalesced commit ran.
    package var committed: Bool
    /// Blobs reaped.
    package var reapedKeys: Int
    /// Bytes reaped (wakes `blocked(.awaitingSpace)` jobs, sync-2 S2-02).
    package var reapedBytes: Int64
    /// The next deadline, or `nil` when the store needs no time-based wake-up.
    package var nextDeadline: MonotonicInstant?

    /// Creates a report.
    package init(committed: Bool, reapedKeys: Int, reapedBytes: Int64, nextDeadline: MonotonicInstant?) {
        self.committed = committed
        self.reapedKeys = reapedKeys
        self.reapedBytes = reapedBytes
        self.nextDeadline = nextDeadline
    }
}

/// Progress of legacy migration phase 2, which runs after `open()` (ADR-029).
package struct LegacyMigrationProgress: Sendable, Hashable {
    /// Files adopted so far.
    package var adopted: Int
    /// Files left.
    package var remaining: Int
    /// Files dropped (checksum mismatch, traversal, symlink).
    package var dropped: Int
    /// Phases 3 and 4 completed: the legacy tree and key are gone.
    package var finished: Bool

    /// Creates progress.
    package init(adopted: Int, remaining: Int, dropped: Int, finished: Bool) {
        self.adopted = adopted
        self.remaining = remaining
        self.dropped = dropped
        self.finished = finished
    }
}

/// The store's counters, folded into `MetricsSnapshot` by the facade (R-OBS-2).
package struct StoreMetrics: Sendable, Hashable {
    /// Successful index commits.
    package var commits: Int
    /// Failed commit attempts.
    package var commitFailures: Int
    /// Size or hash mismatches at publish.
    package var integrityFailures: Int
    /// Assets evicted.
    package var evictions: Int
    /// Bytes evicted.
    package var evictedBytes: Int64
    /// Bytes freed by GC.
    package var gcBytes: Int64
    /// Snapshot installs acknowledged.
    package var acknowledgedInstalls: Int
    /// DOOMED keys dropped at load because a present record referenced them (store-2 S2-04 repair).
    package var doomedRepairs: Int

    /// All zero.
    package init() {
        self.commits = 0
        self.commitFailures = 0
        self.integrityFailures = 0
        self.evictions = 0
        self.evictedBytes = 0
        self.gcBytes = 0
        self.acknowledgedInstalls = 0
        self.doomedRepairs = 0
    }
}
