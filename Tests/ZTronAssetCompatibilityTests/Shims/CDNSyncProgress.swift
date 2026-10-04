import Foundation
import ZTronAssetKit

/// R-CAR-6 shim (ADR-033): the prior art's sync progress (`CDNSyncProgress.swift`), mapped from the module's events
/// as sync.md §10.6 specifies.
public enum CDNSyncProgress: Sendable, Equatable {
    /// Nothing has happened yet this launch.
    case idle
    /// The refresh policy said the catalog is already synced; no network activity.
    case upToDate
    /// A sync is in progress.
    case syncing(fraction: Double, completedCount: Int, totalCount: Int)
    /// Every advertised asset is present.
    case complete
    /// The sync did not finish; the next launch retries.
    case failed(reason: String)

    /// The prior-art case for a run's progress event.
    public init(progress: SyncProgress) {
        self = .syncing(fraction: progress.fraction, completedCount: progress.completedCount, totalCount: progress.totalCount)
    }

    /// The prior-art case for a run's outcome: `notDue` is `upToDate`, `complete` is `complete`, and every partial
    /// or failed outcome is `failed(reason)` with the outcome's description.
    public init(outcome: SyncOutcome) {
        switch outcome {
        case .notDue:
            self = .upToDate
        case .complete:
            self = .complete
        case .completeWithFailures, .blocked, .failed:
            self = .failed(reason: String(describing: outcome))
        }
    }
}

/// R-CAR-6 shim (ADR-033): the refresh policy the SPEC names for the prior art's coordinator, mapped one-to-one.
public enum CDNRefreshPolicy: Sendable, Hashable {
    /// Once per app version (the default).
    case oncePerAppVersion
    /// At every launch.
    case everyLaunch
    /// At most every `interval` seconds.
    case atMostEvery(TimeInterval)

    /// The module's policy.
    public var refreshPolicy: RefreshPolicy {
        switch self {
        case .oncePerAppVersion:
            return .oncePerAppVersion
        case .everyLaunch:
            return .everyLaunch
        case .atMostEvery(let interval):
            return .atMostEvery(interval)
        }
    }
}

/// R-CAR-6 shim (ADR-033): the prior art's provider protocol, kept so custom providers still compile. Adapters over
/// `AssetClient` (`CDNLocalStore`, `CDNAssetResolver.installed`, `CDNSyncCoordinator`, `NetworkAvailabilityMonitor`,
/// `CDNProviderFactory`/`CDNConfiguration`) are WP-G's, in this target.
public protocol CDNProviding: Sendable {
    /// Everything the CDN currently advertises.
    func fetchManifest() async throws -> [CDNAsset]
    /// Downloads one asset to a temporary location, reporting progress in `0...1`.
    func downloadAsset(_ asset: CDNAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}
