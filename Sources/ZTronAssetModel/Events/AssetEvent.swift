/// Identifies one sync run (events, reports, the R-CAR-6 progress shim).
public struct SyncRunID: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// A per-client counter, strictly increasing.
    public let rawValue: UInt64

    /// Creates an identifier.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Orders by counter.
    public static func < (lhs: SyncRunID, rhs: SyncRunID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// `run-<n>`.
    public var description: String {
        "run-\(self.rawValue)"
    }
}

/// What started a run.
public enum SyncTrigger: Sendable, Hashable, Codable {
    /// `start()` found a sync due (R-SYN-9).
    case launch
    /// The app called `sync(.ifDue)` or `sync(.force)`.
    case explicit
    /// The network or power policy admitted work again (R-SYN-13, R-SYN-7).
    case conditionsChanged
    /// A half-open breaker's probe succeeded.
    case breakerClosed
    /// A purge made a sync due (R-CLN-6).
    case afterPurge
}

/// Aggregate progress of a run (R-SYN-12), coalesced newest-wins and rate-limited to ≤ 10 Hz.
///
/// `completedCount` never decreases within a run, matching the prior art's "progress never moves backwards"
/// (`CDNSyncCoordinator.swift:154-164`); a trailing emission follows a quiet period (sync-2 S2-24).
public struct SyncProgress: Sendable, Hashable, Codable {
    /// `completedCount / totalCount`, refined by in-flight bytes; in `0...1`.
    public var fraction: Double
    /// Planned fetches finished (any terminal outcome).
    public var completedCount: Int
    /// Planned fetches.
    public var totalCount: Int
    /// Bytes received in this run.
    public var bytesReceived: Int64
    /// Bytes the plan expects (known sizes only).
    public var bytesExpected: Int64

    /// Creates progress.
    public init(fraction: Double, completedCount: Int, totalCount: Int, bytesReceived: Int64, bytesExpected: Int64) {
        self.fraction = fraction
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
    }
}

/// Progress of one user-initiated or prefetch transfer (bulk transfers publish only `SyncProgress`).
public struct TransferProgress: Sendable, Hashable, Codable {
    /// Bytes received.
    public var received: Int64
    /// The expected size, when known.
    public var expected: Int64?

    /// Creates progress.
    public init(received: Int64, expected: Int64?) {
        self.received = received
        self.expected = expected
    }
}

/// Why an asset left the device.
public enum RemovalReason: Sendable, Hashable, Codable {
    /// Removed from the manifest (R-CLN-1).
    case pruned
    /// Quota eviction (R-CLN-4).
    case evicted
    /// A user purge (R-CLN-6).
    case purged
    /// Reported unreadable or failed verification (R-CLN-8).
    case quarantined
    /// The OS purged it between launches (R-CLN-7).
    case vanished
}

/// The outcome of `performMaintenance(timeBudget:)` (R-SYN-16).
public struct MaintenanceReport: Sendable, Hashable, Codable {
    /// Bytes freed by orphan and staging GC.
    public var gcBytes: Int64
    /// Bytes freed by eviction.
    public var evictedBytes: Int64
    /// Bytes re-hashed by deep verification (R-INT-4).
    public var verifiedBytes: Int64
    /// Corrupt blobs found and quarantined.
    public var corruptFound: Int
    /// Whether the budget ran out before every step finished (the next call resumes).
    public var budgetExhausted: Bool

    /// Creates a report.
    public init(gcBytes: Int64, evictedBytes: Int64, verifiedBytes: Int64, corruptFound: Int, budgetExhausted: Bool) {
        self.gcBytes = gcBytes
        self.evictedBytes = evictedBytes
        self.verifiedBytes = verifiedBytes
        self.corruptFound = corruptFound
        self.budgetExhausted = budgetExhausted
    }
}

/// Everything subscribers of `AssetClient.events` see (R-SYN-12, H-9; ADR-023).
///
/// Two classes. *Progress* events are coalesced newest-wins per key and rate-limited at the source.
/// *Terminal* events are never dropped: the latest terminal event of every subject is delivered, in publication
/// order. Per-asset terminal events of **bulk** work are folded into `syncProgress`/`syncFinished` instead of being
/// broadcast one by one (sync-2 S2-17), so a 10,000-asset sync cannot flood the UI. `clientShutDown` is always last.
/// The two client lifecycle events have a subject each and never coalesce with each other, so a `clientShutDown`
/// never replaces an unread `clientStarted` (ADR-054). Across the facade's reopen after a replaced root, a stream
/// receives each replacement's `clientStarted(generation:)` (values may repeat) and never a retired engine's
/// `clientShutDown` (ARCHITECTURE §8).
public enum AssetEvent: Sendable, Hashable {
    /// Progress class (key `.snapshot`): a new snapshot was installed on the main actor.
    case snapshotChanged(generation: UInt64)
    /// Progress class (key `.conditions`): network or power state changed.
    case conditionsChanged(DeviceConditions)
    /// Progress class (key `.run`).
    case syncProgress(SyncRunID, SyncProgress)
    /// Progress class (key `.transfer(id)`): user-initiated and prefetch lanes only.
    case transferProgress(AssetID, TransferProgress)
    /// Terminal (subject `.client`): `start()` finished and the first snapshot is installed.
    case clientStarted(generation: UInt64)
    /// Terminal (subject `.runStarted`).
    case syncStarted(SyncRunID, SyncTrigger)
    /// Terminal (subject `.runFinished`).
    indirect case syncFinished(SyncRunID, SyncOutcome)
    /// Terminal (subject `.asset(id)`): non-bulk work committed it.
    case assetAvailable(AssetID, generation: UInt64)
    /// Terminal (subject `.asset(id)`): non-bulk work failed for it.
    case assetFailed(AssetID, AssetError, RetryDisposition)
    /// Terminal (subject `.asset(id)`): it left the device.
    case assetRemoved(AssetID, RemovalReason)
    /// Terminal (subject `.breaker`).
    case circuitChanged(originID: String, CircuitState)
    /// Terminal (subject `.maintenance`).
    indirect case maintenanceFinished(MaintenanceReport)
    /// Terminal (subject `.clientEnd`, apart from `clientStarted`'s, so it never replaces an unread `clientStarted`;
    /// ADR-054): always the last event of every stream (R-SYN-15).
    case clientShutDown
}
