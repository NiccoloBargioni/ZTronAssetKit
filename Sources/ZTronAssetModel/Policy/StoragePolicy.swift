import Foundation

/// Where the store root lives (R-STO-10, ADR-001 NEEDS-HUMAN-REVIEW). The root is `<base>/ZTronAssetKit/v1/`.
public enum StorageLocation: Sendable, Hashable {
    /// `Application Support`, excluded from backup (the default: the OS never purges essential assets).
    case applicationSupport
    /// `Caches`: for catalogs that are fully regenerable; the OS may purge it (R-CLN-7 handles that).
    case caches
    /// An explicit base directory. App Group containers are unsupported unless the app closes the client when it
    /// is backgrounded (a held `flock` in a shared container risks 0xdead10cc, store design R6).
    case custom(URL)
}

/// The store's byte budget (R-CLN-4).
public enum StorageBudget: Sendable, Hashable, Codable {
    /// No budget; only `reserveFreeBytes` constrains.
    case unlimited
    /// An absolute number of bytes.
    case bytes(Int64)
    /// A fraction of (store usage + free space), re-resolved at every decision.
    case fractionOfFreeSpace(Double)

    /// The budget in bytes given current usage and free space. Pure.
    public func resolve(usedBytes: Int64, availableBytes: Int64) -> Int64 {
        switch self {
        case .unlimited:
            return Int64.max
        case .bytes(let bytes):
            return max(0, bytes)
        case .fractionOfFreeSpace(let fraction):
            guard fraction.isFinite, fraction > 0 else {
                return 0
            }
            let total = Double(max(0, usedBytes)) + Double(max(0, availableBytes))
            let budget = total * min(fraction, 1)
            return budget >= Double(Int64.max) ? Int64.max : Int64(budget)
        }
    }
}

/// Every number that governs storage lifecycle (R-CLN-4, R-CLN-5, R-INT-3, R-INT-5, H-2). Defaults: ADR-035
/// (NEEDS-HUMAN-REVIEW).
public struct StoragePolicy: Sendable, Hashable {
    /// The byte budget. Default: half of (usage + free space).
    public var budget: StorageBudget
    /// Free space the module never consumes; also the guard for index commits. Default 256 MiB.
    public var reserveFreeBytes: Int64
    /// Eviction stops at this fraction of the budget (hysteresis). Default 0.9.
    public var hysteresisTarget: Double
    /// An asset accessed more recently than this is never evicted. Default 24 h.
    public var minimumResidency: TimeInterval
    /// Every URL handed out stays readable at least this long after the acknowledged snapshot without it
    /// (H-2, I-3, ADR-017). Default 10 s.
    public var deletionGrace: TimeInterval
    /// An unreferenced blob younger than this is not collected (R-CLN-2). Default 1 h.
    public var orphanGrace: TimeInterval
    /// Unclaimed staging files younger than this survive launch GC, so a relaunched background session can hand
    /// over its files (store-2 S2-11, transport-2 T2-03). Default 1 h.
    public var stagingClaimGrace: TimeInterval
    /// Staging files older than this are collected even if claimed (R-CLN-3). Default 72 h.
    public var stagingMaxAge: TimeInterval
    /// Integrity failures before an entry is `failed` until its manifest entry changes (R-INT-3). Default 3.
    public var maxIntegrityAttempts: Int
    /// First integrity backoff (R-INT-3). Default 60 s.
    public var integrityBackoffBase: TimeInterval
    /// Multiplier between integrity backoffs. Default 10.
    public var integrityBackoffMultiplier: Double
    /// Admit checksum-less entries, flagged unverified everywhere (R-INT-5). Default `true` for compatibility.
    public var allowUnverifiedAssets: Bool
    /// When the in-scope catalog exceeds the budget: fetch the largest prefix in plan order that fits and skip the
    /// rest (ADR-025, sync-2 S2-07). When `false`, an over-budget plan fails with no side effects.
    public var admitLargestFittingPrefix: Bool

    /// The ADR-035 defaults.
    public init(
        budget: StorageBudget = .fractionOfFreeSpace(0.5),
        reserveFreeBytes: Int64 = 256 * 1_024 * 1_024,
        hysteresisTarget: Double = 0.9,
        minimumResidency: TimeInterval = 24 * 3_600,
        deletionGrace: TimeInterval = 10,
        orphanGrace: TimeInterval = 3_600,
        stagingClaimGrace: TimeInterval = 3_600,
        stagingMaxAge: TimeInterval = 72 * 3_600,
        maxIntegrityAttempts: Int = 3,
        integrityBackoffBase: TimeInterval = 60,
        integrityBackoffMultiplier: Double = 10,
        allowUnverifiedAssets: Bool = true,
        admitLargestFittingPrefix: Bool = true
    ) {
        self.budget = budget
        self.reserveFreeBytes = reserveFreeBytes
        self.hysteresisTarget = hysteresisTarget
        self.minimumResidency = minimumResidency
        self.deletionGrace = deletionGrace
        self.orphanGrace = orphanGrace
        self.stagingClaimGrace = stagingClaimGrace
        self.stagingMaxAge = stagingMaxAge
        self.maxIntegrityAttempts = maxIntegrityAttempts
        self.integrityBackoffBase = integrityBackoffBase
        self.integrityBackoffMultiplier = integrityBackoffMultiplier
        self.allowUnverifiedAssets = allowUnverifiedAssets
        self.admitLargestFittingPrefix = admitLargestFittingPrefix
    }

    /// The integrity backoff after `attempt` failures (1-based): `base × multiplier^(attempt−1)`, or `nil` once
    /// `maxIntegrityAttempts` is reached (the entry is then `failed` until it changes, R-INT-3). Pure.
    public func integrityBackoff(afterAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt < self.maxIntegrityAttempts else {
            return nil
        }
        return self.integrityBackoffBase * pow(self.integrityBackoffMultiplier, Double(attempt - 1))
    }
}

/// How the prior-art layout is found and migrated (R-STO-11, H-10). Defaults are the prior art's names
/// (RECON §5).
public struct LegacyMigrationPolicy: Sendable, Hashable {
    /// Whether to look for the prior-art layout at all.
    public var enabled: Bool
    /// The legacy root; `nil` means `<Caches>/CDNAssets` (the prior art's default).
    public var root: URL?
    /// The `UserDefaults` suite holding the legacy stamp; `nil` means `.standard`.
    public var defaultsSuiteName: String?
    /// The legacy stamp key.
    public var defaultsKey: String

    /// The prior art's defaults: enabled, `<Caches>/CDNAssets`, standard defaults,
    /// `ZTronCarouselCore.CDNSyncCoordinator.lastSyncedVersion`.
    public init(
        enabled: Bool = true,
        root: URL? = nil,
        defaultsSuiteName: String? = nil,
        defaultsKey: String = "ZTronCarouselCore.CDNSyncCoordinator.lastSyncedVersion"
    ) {
        self.enabled = enabled
        self.root = root
        self.defaultsSuiteName = defaultsSuiteName
        self.defaultsKey = defaultsKey
    }
}
