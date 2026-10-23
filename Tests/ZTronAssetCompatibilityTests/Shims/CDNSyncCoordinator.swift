import Combine
import Foundation
import ZTronAssetKit

/// R-CAR-6 shim of the prior art's bulk-sync coordinator (`CDNSyncCoordinator.swift`, read-only): a main-actor
/// `ObservableObject` publishing `CDNSyncProgress`, as an adapter over `AssetClient.sync` and the client's events.
///
/// Combine stays in this test target (R-CAR-9: bridges live in ZTronCarouselCore). The client does what the prior art's
/// loop did, without its defects (D-2, D-8, D-15): it fetches the manifest, reconciles before downloading (a directory
/// change moves nothing and downloads nothing, a removed entry is deleted, R-SYN-8), downloads what is missing as
/// independent jobs, and writes the once-per-version stamp only after a complete run, inside its own index, never in
/// `UserDefaults` (D-6, R-SYN-9). The coordinator maps the run's events and outcome onto the prior art's progress cases
/// (sync.md §10.6): `syncProgress` is `.syncing`, `notDue` is `.upToDate`, `complete` is `.complete`, every other
/// outcome is `.failed(reason:)` with the outcome's description.
@MainActor
public final class CDNSyncCoordinator: ObservableObject {
    /// The prior art's published progress.
    @Published public private(set) var progress: CDNSyncProgress = .idle
    /// What the last run reconciled (relocations and prunes), `nil` before a run reported one (new in the shims: the
    /// prior art returned it from `CDNLocalStore.reconcile(newManifest:)` and discarded it).
    public private(set) var lastReconciliation: CDNReconciliationSummary?

    /// The client this coordinator drives.
    nonisolated public let client: AssetClient
    /// The manifest source of `verifyFullyAvailable()`: the client applies manifests internally and hands no entries out.
    private let cdn: any CDNProviding
    /// The client's lookups, for `verifyFullyAvailable()`.
    private let localStore: CDNLocalStore

    /// A coordinator over `client`; `cdn` answers `verifyFullyAvailable()`'s manifest fetch.
    public init(client: AssetClient, cdn: any CDNProviding) {
        self.client = client
        self.cdn = cdn
        self.localStore = CDNLocalStore(client: client)
    }

    /// The prior art's version string, `"<CFBundleShortVersionString>+<CFBundleVersion>"` (`"0"` for a missing key).
    /// `nonisolated` because it is the default value of a `@Sendable` parameter (SPEC Appendix A, 1). The client reads
    /// the app version through its environment (`LiveAppVersionSource`, the same format), so the shims use this only
    /// for the prior-art initialiser's default.
    nonisolated public static func defaultAppVersion() -> String {
        // WP-K skeleton: no version is read yet.
        ""
    }

    /// The launch sync: `AssetClient.sync(.ifDue)`, safe on every launch. `.upToDate` without network when the refresh
    /// policy says no; otherwise `.syncing` while the run (the client's launch run, if one is active, or a new one)
    /// transfers, then `.complete` or `.failed(reason:)`. A failed or partial run leaves the sync due, so the next launch
    /// retries and downloads only what is still missing.
    public func syncIfNeeded() async {
        // WP-K skeleton: nothing is synced yet.
    }

    /// Fetches a fresh manifest from `cdn` and returns every asset in it that is not stored at its content
    /// (`CDNLocalStore.missingOrStaleAssets`), downloading nothing. Throws only when the manifest fetch throws.
    public func verifyFullyAvailable() async throws -> [CDNAsset] {
        // WP-K skeleton: nothing is fetched yet.
        []
    }

    /// A repair pass regardless of the refresh policy: `AssetClient.sync(.force)`, publishing progress as
    /// `syncIfNeeded()` does. Unlike the prior art, a complete repair also writes the sync stamp, which is true and
    /// harmless (sync.md §12.3: the prior art skipped it only because its flag meant "once per version").
    public func verifyAndRepair() async {
        // WP-K skeleton: nothing is repaired yet.
    }
}
