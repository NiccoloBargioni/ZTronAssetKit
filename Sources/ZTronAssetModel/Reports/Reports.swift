import Foundation

/// What `availability(scope:)` and `ensureAvailable(scope:)` report (R-SYN-10). Computed without network or I/O.
public struct AvailabilityReport: Sendable, Hashable, Codable {
    /// The scope evaluated.
    public var scope: AssetScope
    /// Entries in scope.
    public var total: Int
    /// Present at their current content.
    public var present: Int
    /// Not on the device.
    public var missing: Int
    /// Present at superseded content (served until the new bytes commit).
    public var stale: Int
    /// Failed until their entry changes, or quarantined.
    public var failed: Int
    /// Present but checksum-less (R-INT-5).
    public var unverified: Int
    /// Known bytes of the missing entries.
    public var bytesMissing: Int64
    /// Whether a manifest fetch succeeded (or returned 304) for this report.
    public var manifestFresh: Bool
    /// The index generation the report was computed from.
    public var generation: UInt64

    /// Creates a report.
    public init(
        scope: AssetScope,
        total: Int,
        present: Int,
        missing: Int,
        stale: Int,
        failed: Int,
        unverified: Int,
        bytesMissing: Int64,
        manifestFresh: Bool,
        generation: UInt64
    ) {
        self.scope = scope
        self.total = total
        self.present = present
        self.missing = missing
        self.stale = stale
        self.failed = failed
        self.unverified = unverified
        self.bytesMissing = bytesMissing
        self.manifestFresh = manifestFresh
        self.generation = generation
    }

    /// Nothing in scope is missing, stale or failed: no mid-use download can happen (promise 1).
    public var isComplete: Bool {
        self.missing == 0 && self.stale == 0 && self.failed == 0
    }
}

/// Bytes on the device by residency state (R-CLN-9).
public struct ResidencyBytes: Sendable, Hashable, Codable {
    /// Present at current content.
    public var present: Int64
    /// Present at superseded content.
    public var stale: Int64
    /// Doomed and waiting for ack, grace or a lease before deletion.
    public var pendingDeletion: Int64

    /// Creates a breakdown.
    public init(present: Int64, stale: Int64, pendingDeletion: Int64) {
        self.present = present
        self.stale = stale
        self.pendingDeletion = pendingDeletion
    }
}

/// `storageReport()` (R-CLN-9).
public struct StorageReport: Sendable, Hashable, Codable {
    /// Blob bytes by lowercased file extension.
    public var bytesByKind: [String: Int64]
    /// Blob bytes by residency state.
    public var bytesByState: ResidencyBytes
    /// Bytes of pinned assets.
    public var pinnedBytes: Int64
    /// Bytes of `essential` assets.
    public var essentialBytes: Int64
    /// Bytes eviction could free now.
    public var evictableBytes: Int64
    /// Bytes under `staging/`.
    public var stagingBytes: Int64
    /// Unreferenced blob bytes awaiting orphan GC.
    public var orphanBytes: Int64
    /// Bytes the OS still holds on the device in the remote source's copies of content (H-7, transport-2 T2-13), from
    /// `RemoteSource.sourceCopyBytes()`: 0 for HTTP; for the Apple tier, the installed bytes of media packs holding
    /// adopted content (released or not), of packs released in this process (one that came back stays installed until
    /// a reclaim in a later catalog generation releases it), and of packs whose planned removal has not yet succeeded;
    /// a removed pack adds nothing (ADR-027 as amended by ADR-050, E-11). The source learns its adopted packs from
    /// `reclaimSourceCopies` and keeps them in memory, so a fresh source reports 0 until its first reclaim; the engine
    /// is to reclaim before its first `storageReport()` (ARCHITECTURE §11, R-CLN-9).
    public var sourceCopyBytes: Int64
    /// The resolved budget in bytes.
    public var budgetBytes: Int64
    /// Free space for important usage.
    public var freeBytesImportant: Int64
    /// Free space for opportunistic usage.
    public var freeBytesOpportunistic: Int64
    /// Checksum-less present assets (R-INT-5).
    public var unverifiedCount: Int
    /// When the last orphan GC, staging GC, quota eviction or purge that removed, doomed, evicted or purged something
    /// finished; a run that changed nothing does not set it.
    public var lastCleanupAt: Date?

    /// Creates a report.
    public init(
        bytesByKind: [String: Int64],
        bytesByState: ResidencyBytes,
        pinnedBytes: Int64,
        essentialBytes: Int64,
        evictableBytes: Int64,
        stagingBytes: Int64,
        orphanBytes: Int64,
        sourceCopyBytes: Int64,
        budgetBytes: Int64,
        freeBytesImportant: Int64,
        freeBytesOpportunistic: Int64,
        unverifiedCount: Int,
        lastCleanupAt: Date?
    ) {
        self.bytesByKind = bytesByKind
        self.bytesByState = bytesByState
        self.pinnedBytes = pinnedBytes
        self.essentialBytes = essentialBytes
        self.evictableBytes = evictableBytes
        self.stagingBytes = stagingBytes
        self.orphanBytes = orphanBytes
        self.sourceCopyBytes = sourceCopyBytes
        self.budgetBytes = budgetBytes
        self.freeBytesImportant = freeBytesImportant
        self.freeBytesOpportunistic = freeBytesOpportunistic
        self.unverifiedCount = unverifiedCount
        self.lastCleanupAt = lastCleanupAt
    }
}

/// What a user purge removes (R-CLN-6).
public enum PurgeRequest: Sendable, Hashable, Codable {
    /// Everything, pinned and essential included; the sync stamp is cleared.
    case all
    /// Everything eviction could remove now (not essential, pinned or leased).
    case evictable
    /// The entries in a scope, pinned and essential included.
    case scope(AssetScope)
}

/// The outcome of a purge (R-CLN-6).
public struct PurgeResult: Sendable, Hashable, Codable {
    /// Bytes deleted before the call returned.
    public var bytesFreed: Int64
    /// Bytes still leased; deleted when the last lease ends.
    public var bytesDeferred: Int64
    /// Assets that left the device.
    public var assetsRemoved: Int

    /// Creates a result.
    public init(bytesFreed: Int64, bytesDeferred: Int64, assetsRemoved: Int) {
        self.bytesFreed = bytesFreed
        self.bytesDeferred = bytesDeferred
        self.assetsRemoved = assetsRemoved
    }
}

/// The failure classes metrics and reports count (R-OBS-2), one per engine action of ARCHITECTURE §7.6.
public enum FailureClass: String, Sendable, Hashable, CaseIterable, Codable {
    /// No path, or the OS refused this network.
    case offline
    /// Timeouts, lost connections, DNS, TLS, unknown.
    case transient
    /// 5xx.
    case serverError
    /// 429 / `Retry-After`.
    case throttled
    /// 404 / 410.
    case notFound
    /// 401 / 403.
    case authentication
    /// Size or hash mismatch.
    case integrity
    /// ENOSPC.
    case insufficientSpace
    /// Our own policy refused the request or response.
    case rejected
    /// Store I/O.
    case storage
}

/// Counters per failure class (a struct, not a dictionary, so it encodes to stable JSON at the iOS 15 floor).
public struct FailureCounts: Sendable, Hashable, Codable {
    /// Offline.
    public var offline: Int
    /// Transient.
    public var transient: Int
    /// 5xx.
    public var serverError: Int
    /// 429.
    public var throttled: Int
    /// 404 / 410.
    public var notFound: Int
    /// 401 / 403.
    public var authentication: Int
    /// Size or hash.
    public var integrity: Int
    /// ENOSPC.
    public var insufficientSpace: Int
    /// Policy refusals.
    public var rejected: Int
    /// Store I/O.
    public var storage: Int

    /// All zero.
    public init() {
        self.offline = 0
        self.transient = 0
        self.serverError = 0
        self.throttled = 0
        self.notFound = 0
        self.authentication = 0
        self.integrity = 0
        self.insufficientSpace = 0
        self.rejected = 0
        self.storage = 0
    }

    /// The counter of one class.
    public subscript(failureClass: FailureClass) -> Int {
        get {
            switch failureClass {
            case .offline: return self.offline
            case .transient: return self.transient
            case .serverError: return self.serverError
            case .throttled: return self.throttled
            case .notFound: return self.notFound
            case .authentication: return self.authentication
            case .integrity: return self.integrity
            case .insufficientSpace: return self.insufficientSpace
            case .rejected: return self.rejected
            case .storage: return self.storage
            }
        }
        set {
            switch failureClass {
            case .offline: self.offline = newValue
            case .transient: self.transient = newValue
            case .serverError: self.serverError = newValue
            case .throttled: self.throttled = newValue
            case .notFound: self.notFound = newValue
            case .authentication: self.authentication = newValue
            case .integrity: self.integrity = newValue
            case .insufficientSpace: self.insufficientSpace = newValue
            case .rejected: self.rejected = newValue
            case .storage: self.storage = newValue
            }
        }
    }
}

/// The in-memory metrics of R-OBS-2, composed from engine, store and mirror counters.
public struct MetricsSnapshot: Sendable, Hashable, Codable {
    /// Bytes received for assets.
    public var bytesDownloaded: Int64
    /// Manifest requests sent.
    public var manifestRequests: Int
    /// Manifest requests answered 304.
    public var manifestNotModified: Int
    /// Asset requests sent.
    public var transferRequests: Int
    /// Retries by class.
    public var retries: FailureCounts
    /// Failures by class.
    public var failures: FailureCounts
    /// `lookup` hits on the main actor.
    public var lookupHits: Int
    /// `lookup` misses.
    public var lookupMisses: Int
    /// `resolve` answered from the store without a transfer.
    public var resolveHits: Int
    /// `resolve` joined an in-flight transfer.
    public var resolveJoins: Int
    /// `resolve` started a transfer.
    public var resolveTransfers: Int
    /// In-flight promotions (R-SYN-3).
    public var promotions: Int
    /// Preemptions.
    public var preemptions: Int
    /// Assets evicted.
    public var evictions: Int
    /// Bytes evicted.
    public var evictedBytes: Int64
    /// Bytes freed by GC.
    public var gcBytes: Int64
    /// Size or hash mismatches (R-INT-2).
    public var integrityFailures: Int
    /// Breaker trips.
    public var breakerTrips: Int
    /// Events replaced by a newer one in a subscriber queue.
    public var eventsCoalesced: Int
    /// Events delivered to subscribers.
    public var eventsDelivered: Int
    /// Rejected state-machine transitions; must stay 0 (R-SYN-2).
    public var illegalTransitions: Int

    /// All zero.
    public init() {
        self.bytesDownloaded = 0
        self.manifestRequests = 0
        self.manifestNotModified = 0
        self.transferRequests = 0
        self.retries = FailureCounts()
        self.failures = FailureCounts()
        self.lookupHits = 0
        self.lookupMisses = 0
        self.resolveHits = 0
        self.resolveJoins = 0
        self.resolveTransfers = 0
        self.promotions = 0
        self.preemptions = 0
        self.evictions = 0
        self.evictedBytes = 0
        self.gcBytes = 0
        self.integrityFailures = 0
        self.breakerTrips = 0
        self.eventsCoalesced = 0
        self.eventsDelivered = 0
        self.illegalTransitions = 0
    }
}

/// One entry of the engine's ring of recent errors (R-OBS-3), read by `diagnosticReport()`.
///
/// In the Model so the engine records it and the facade encodes it; it holds plain facts only, never a request, a
/// header, a URL with credentials or a key (R-SEC-1).
public struct DiagnosticError: Sendable, Hashable, Codable {
    /// When (wall clock).
    public var at: Date
    /// Which asset, if any.
    public var id: AssetID?
    /// The failure class.
    public var failureClass: FailureClass
    /// The internal error's description (plain facts only, never a request or header).
    public var detail: String

    /// Creates an entry.
    public init(at: Date, id: AssetID?, failureClass: FailureClass, detail: String) {
        self.at = at
        self.id = id
        self.failureClass = failureClass
        self.detail = detail
    }
}
