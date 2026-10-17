import Foundation

/// Plan totals (R-SYN-1): the counts and bytes a run planned.
public struct PlanTotals: Sendable, Hashable, Codable {
    /// Planned fetches.
    public var fetchCount: Int
    /// Planned fetches whose size the manifest does not announce.
    public var fetchUnknownSizeCount: Int
    /// Metadata-only changes (zero bytes, R-SYN-8).
    public var relocationCount: Int
    /// Content already present as a blob (dedupe, renamed id).
    public var reuseCount: Int
    /// Entries gone from the manifest.
    public var pruneCount: Int
    /// Entries skipped (scope, policy, quarantine).
    public var skippedCount: Int
    /// Entries already present at their content.
    public var unchangedCount: Int
    /// Known bytes of the planned fetches (unknown sizes are not estimated, sync-2 S2-08).
    public var fetchBytes: Int64
    /// Bytes the prunes will free.
    public var pruneBytes: Int64

    /// Creates totals; everything zero by default.
    public init(
        fetchCount: Int = 0,
        fetchUnknownSizeCount: Int = 0,
        relocationCount: Int = 0,
        reuseCount: Int = 0,
        pruneCount: Int = 0,
        skippedCount: Int = 0,
        unchangedCount: Int = 0,
        fetchBytes: Int64 = 0,
        pruneBytes: Int64 = 0
    ) {
        self.fetchCount = fetchCount
        self.fetchUnknownSizeCount = fetchUnknownSizeCount
        self.relocationCount = relocationCount
        self.reuseCount = reuseCount
        self.pruneCount = pruneCount
        self.skippedCount = skippedCount
        self.unchangedCount = unchangedCount
        self.fetchBytes = fetchBytes
        self.pruneBytes = pruneBytes
    }
}

/// One asset that failed in a run (R-SYN-6).
public struct AssetFailure: Sendable, Hashable, Codable {
    /// The asset.
    public var id: AssetID
    /// What its waiters saw.
    public var error: AssetError
    /// The metrics class.
    public var failureClass: FailureClass

    /// Creates a failure record.
    public init(id: AssetID, error: AssetError, failureClass: FailureClass) {
        self.id = id
        self.error = error
        self.failureClass = failureClass
    }
}

/// The partial-success report of a run (R-SYN-6).
public struct SyncReport: Sendable, Hashable, Codable {
    /// The run.
    public var runID: SyncRunID
    /// What started it.
    public var trigger: SyncTrigger
    /// Wall-clock start.
    public var startedAt: Date
    /// Wall-clock end.
    public var finishedAt: Date
    /// Whether the manifest fetch succeeded (or returned 304). A `.complete` run with `false` (its fetch passed
    /// `manifestFetchDeadline`, so it ran over the applied manifest) writes no sync stamp, and the sync stays due
    /// (ARCHITECTURE §7.10).
    public var manifestFresh: Bool
    /// What was planned.
    public var planned: PlanTotals
    /// Assets fetched and committed.
    public var fetched: Int
    /// Assets bound to existing blobs.
    public var reused: Int
    /// Metadata-only changes applied.
    public var relocated: Int
    /// Entries pruned.
    public var pruned: Int
    /// Assets evicted to make room.
    public var evicted: Int
    /// Assets that failed (exact).
    public var failedCount: Int
    /// Bytes received.
    public var bytesDownloaded: Int64
    /// Failures sorted by id; the first 1,000 (H-9 bound).
    public var failures: [AssetFailure]

    /// Creates a report.
    public init(
        runID: SyncRunID,
        trigger: SyncTrigger,
        startedAt: Date,
        finishedAt: Date,
        manifestFresh: Bool,
        planned: PlanTotals,
        fetched: Int,
        reused: Int,
        relocated: Int,
        pruned: Int,
        evicted: Int,
        failedCount: Int,
        bytesDownloaded: Int64,
        failures: [AssetFailure]
    ) {
        self.runID = runID
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.manifestFresh = manifestFresh
        self.planned = planned
        self.fetched = fetched
        self.reused = reused
        self.relocated = relocated
        self.pruned = pruned
        self.evicted = evicted
        self.failedCount = failedCount
        self.bytesDownloaded = bytesDownloaded
        self.failures = failures
    }
}

/// How a run ended (R-SYN-6). Only a `.complete` run with a fresh manifest (`SyncReport.manifestFresh`) writes the
/// sync stamp (prior-art parity, R-SYN-9); one whose manifest fetch passed its deadline leaves the sync due
/// (ARCHITECTURE §7.10).
public enum SyncOutcome: Sendable, Hashable {
    /// `.ifDue` and the refresh policy said no.
    case notDue(lastSyncedAt: Date?)
    /// Every planned asset is present.
    case complete(SyncReport)
    /// At least one asset failed; the stamp is not written.
    case completeWithFailures(SyncReport)
    /// Every remaining job is blocked; a pending run starts when the gate opens (sync-2 S2-03).
    case blocked(BlockReason, SyncReport)
    /// Nothing could start (manifest unusable, insufficient space, shut down, cancelled, storage unavailable).
    case failed(AssetError)
}
