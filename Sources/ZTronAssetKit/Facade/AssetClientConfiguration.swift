@_exported import ZTronAssetModel

/// Everything an `AssetClient` is configured with (SPEC §4.5). Values only; validated and clamped by `init` of
/// the client (pure, P-12), clamps reported in `diagnosticReport()`.
public struct AssetClientConfiguration: Sendable, Hashable {
    /// The remote tiers and the kill switch (R-APL-5).
    public var remote: RemoteConfiguration
    /// Where the store root lives (R-STO-10, ADR-001).
    public var location: StorageLocation
    /// Budget, grace windows, integrity backoff (ADR-035).
    public var storage: StoragePolicy
    /// The prior-art layout to migrate (R-STO-11).
    public var legacy: LegacyMigrationPolicy
    /// Which lanes may use which networks (ADR-036).
    public var network: NetworkPolicy
    /// Low Power Mode and thermal behaviour (ADR-036).
    public var power: PowerPolicy
    /// When a launch sync is due (R-SYN-9).
    public var refresh: RefreshPolicy
    /// Concurrency, retries, breaker, rate limits (R-SYN-3, R-SYN-5, R-SYN-12).
    public var tuning: SyncTuning
    /// Manifest limits (R-MAN-2).
    public var limits: ManifestLimits
    /// The prefetch window radius (R-CAR-3; default 2).
    public var prefetchRadius: Int
    /// What the app wants kept (R-CAR-5, ADR-027; default `.all`): the scope of every bulk run; entries outside it
    /// are evicted first and never block an Apple pack release. `AssetClient.setRetentionScope(_:)` replaces it at
    /// run time (paywall changes); the app passes the current value here at launch.
    public var retentionScope: AssetScope

    /// Creates a configuration with the documented defaults.
    public init(
        remote: RemoteConfiguration,
        location: StorageLocation = .applicationSupport,
        storage: StoragePolicy = StoragePolicy(),
        legacy: LegacyMigrationPolicy = LegacyMigrationPolicy(),
        network: NetworkPolicy = NetworkPolicy(),
        power: PowerPolicy = PowerPolicy(),
        refresh: RefreshPolicy = .oncePerAppVersion,
        tuning: SyncTuning = SyncTuning(),
        limits: ManifestLimits = ManifestLimits(),
        prefetchRadius: Int = 2,
        retentionScope: AssetScope = .all
    ) {
        self.remote = remote
        self.location = location
        self.storage = storage
        self.legacy = legacy
        self.network = network
        self.power = power
        self.refresh = refresh
        self.tuning = tuning
        self.limits = limits
        self.prefetchRadius = prefetchRadius
        self.retentionScope = retentionScope
    }
}
