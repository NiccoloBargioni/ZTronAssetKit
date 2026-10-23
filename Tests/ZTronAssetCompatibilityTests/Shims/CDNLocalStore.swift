import Foundation
import ZTronAssetKit

/// R-CAR-6 shim of the prior art's local store (`CDNLocalStore.swift`, read-only) as an adapter over an `AssetClient`.
///
/// The prior art kept files under `Caches/CDNAssets/<pretty path>` next to a cached `manifest.json`, hashed on the
/// main thread and moved files during reconciliation (D-6, D-10, D-15…D-18). The client keeps content-addressed blobs
/// under its own root and answers lookups from a main-actor snapshot with no I/O (R-STO-7, R-STO-13), so the lookups
/// here (`existingLocalURL`, `hasAsset`, `missingOrStaleAssets`, `isFullyAvailable`) are `@MainActor` and read
/// `AssetClient.lookup` only: no file-system call, no network, no hashing. A store is bound to an install point:
/// `shared` follows the process-wide one, `init(client:)` binds one client.
public final class CDNLocalStore: Sendable {
    /// The prior art's shared store: it follows `CDNInstallPoint.process`, so it answers for the client the app
    /// installed (`CDNProviderFactory.install`, `CDNAssetResolver.installed`), and like an empty cache before that.
    public static let shared = CDNLocalStore(installPoint: .process)

    /// Where this store finds its client.
    public let installPoint: CDNInstallPoint

    /// A store over `client`.
    public convenience init(client: AssetClient) {
        self.init(installPoint: CDNInstallPoint(client: client))
    }

    /// A store over whatever client `installPoint` holds.
    public init(installPoint: CDNInstallPoint) {
        self.installPoint = installPoint
    }

    /// The client this store adapts, once one is installed.
    @MainActor
    public var client: AssetClient? {
        // WP-K skeleton: no client is read yet.
        nil
    }

    /// The local file for `identifier` in one of `candidateExtensions` (any extension when empty): the client's
    /// snapshot, no file-system call and no network (RECON §5: offline). Unlike the prior art, the extension filter also
    /// applies to an asset the manifest knows (ADR-037, as `AssetFallbackChain.locate`), so an image page is never handed
    /// a video. A stale asset (new content announced, not yet stored) still answers with its old bytes, as before.
    @MainActor
    public func existingLocalURL(identifier: String, candidateExtensions: [String]) -> URL? {
        // WP-K skeleton: nothing is looked up yet.
        nil
    }

    /// Whether `asset` is stored at the content it describes: present in the client's snapshot with its extension, not
    /// stale, and, when `checksum` is a SHA-256 (64 hex characters), stored under that digest (a blob's name is the
    /// SHA-256 of its bytes, I-1). A checksum that is not a SHA-256 cannot be compared, so such an asset is trusted on
    /// presence (R-MAN-5), where the prior art compared it with its own hash of the file and never matched.
    @MainActor
    public func hasAsset(_ asset: CDNAsset) -> Bool {
        // WP-K skeleton: nothing is looked up yet.
        false
    }

    /// Every asset of `manifest` that is not stored at the content it describes (`hasAsset`), in manifest order, with
    /// no network: the prior art's availability guarantee. One snapshot read per asset on the main actor.
    @MainActor
    public func missingOrStaleAssets(against manifest: [CDNAsset]) -> [CDNAsset] {
        // WP-K skeleton: nothing is compared yet.
        []
    }

    /// Whether every asset of `manifest` is stored at its content.
    @MainActor
    public func isFullyAvailable(against manifest: [CDNAsset]) -> Bool {
        // WP-K skeleton: nothing is compared yet.
        true
    }
}

/// What the prior art's `reconcile(newManifest:)` did, now what a client run did to stored assets: relocations
/// (`migratedCount`, metadata-only, no download) and prunes (`prunedCount`). The client reports per-asset failures in
/// `SyncReport.failures`, not as reconciliation failures, so the failure lists stay empty when built from a report.
public struct CDNReconciliationSummary: Sendable, Hashable {
    /// One file the prior art failed to move or delete.
    public struct Failure: Sendable, Hashable {
        /// The asset.
        public let identifier: String
        /// The error's description.
        public let reason: String

        /// Creates a failure.
        public init(identifier: String, reason: String) {
            self.identifier = identifier
            self.reason = reason
        }
    }

    /// Assets whose directory or file name changed, applied without a download.
    public let migratedCount: Int
    /// Relocations that failed.
    public let migrationFailures: [Failure]
    /// Assets removed because the manifest no longer lists them.
    public let prunedCount: Int
    /// Removals that failed.
    public let pruneFailures: [Failure]

    /// Creates a summary.
    public init(migratedCount: Int = 0, migrationFailures: [Failure] = [], prunedCount: Int = 0, pruneFailures: [Failure] = []) {
        self.migratedCount = migratedCount
        self.migrationFailures = migrationFailures
        self.prunedCount = prunedCount
        self.pruneFailures = pruneFailures
    }

    /// What a client run reconciled: `relocated` as migrated, `pruned` as pruned.
    public init(report: SyncReport) {
        // WP-K skeleton: the report is not read yet.
        self.init()
    }
}
