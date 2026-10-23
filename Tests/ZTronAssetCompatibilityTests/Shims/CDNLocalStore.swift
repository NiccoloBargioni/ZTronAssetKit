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
    /// The manifests handed to `cacheManifest` and `reconcile`, for `cachedAsset(forIdentifier:)`.
    private let memory: ManifestMemory

    /// A store over `client`.
    public convenience init(client: AssetClient) {
        self.init(installPoint: CDNInstallPoint(client: client))
    }

    /// A store over whatever client `installPoint` holds.
    public init(installPoint: CDNInstallPoint) {
        self.installPoint = installPoint
        self.memory = ManifestMemory()
    }

    /// The prior art's initialiser. Without `baseDirectory` the store is `shared`'s view of the process install point
    /// (two clients may not open one root, R-STO-9, so a second default store must not build a second client). With
    /// one, the store gets an install point of its own whose client, built from the first prior-art provider that needs
    /// one, keeps its root in `baseDirectory` and migrates the prior art's files found there. `computeChecksum` is
    /// ignored: the client verifies SHA-256 checksums itself (R-INT-*).
    @available(*, deprecated, message: "Bind the store to a client: CDNLocalStore(client:), or CDNLocalStore.shared after CDNProviderFactory.install(_:)")
    public convenience init(
        baseDirectory: URL? = nil,
        computeChecksum: @escaping @Sendable (URL) throws -> String = CDNLocalStore.sha256Hex
    ) {
        guard let baseDirectory else {
            self.init(installPoint: .process)
            return
        }
        let configuration = CDNConfiguration(location: .custom(baseDirectory), legacy: LegacyMigrationPolicy(root: baseDirectory))
        self.init(installPoint: CDNInstallPoint(configuration: configuration))
    }

    /// The prior art's checksum: lowercase-hex SHA-256 of a whole file, read on the calling thread (never call it on
    /// the main thread, C2). The client never needs it: a stored blob's name is its SHA-256.
    @available(*, deprecated, message: "The AssetClient hashes and verifies what it stores; a blob's file name is its SHA-256")
    public static func sha256Hex(of fileURL: URL) throws -> String {
        ContentHash.sha256(of: try Data(contentsOf: fileURL, options: .mappedIfSafe)).hex
    }

    /// The prior art's fallback directories: one per dot-separated segment of `identifier`.
    @available(*, deprecated, message: "The AssetClient stores content-addressed blobs; no path is derived from an identifier (R-SEC-2)")
    public static func mechanicalPathComponents(for identifier: String) -> [String] {
        CDNLocalStore.segments(of: identifier)
    }

    /// The dot-separated segments of `identifier` (the prior art's mechanical path rule).
    static func segments(of identifier: String) -> [String] {
        identifier.split(separator: ".").map(String.init)
    }

    /// Records `assets` as this store's cached manifest, for `cachedAsset(forIdentifier:)` (a duplicate identifier keeps
    /// its first entry instead of trapping, D-13). Nothing reaches the client: it applies the manifests it fetches.
    @available(*, deprecated, message: "The AssetClient fetches and applies manifests itself")
    @MainActor
    public func cacheManifest(_ assets: [CDNAsset]) {
        self.memory.entries = Dictionary(assets.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The entry for `identifier` in the manifest last handed to `cacheManifest` or `reconcile` on this store in this
    /// process. The client's applied manifest is internal to its store and is not readable through the shims.
    @available(*, deprecated, message: "The AssetClient applies manifests internally; look assets up with existingLocalURL or AssetClient.lookup")
    @MainActor
    public func cachedAsset(forIdentifier identifier: String) -> CDNAsset? {
        self.memory.entries[identifier]
    }

    /// The stored blob for `asset` (its extension), else where the prior art would have put it: `localPathComponents`
    /// (or the identifier's segments minus the last) and `resolvedFileName` under the legacy root, where the client never
    /// writes, so for an asset the client does not hold the URL names no file, as an absent asset's did before.
    @available(*, deprecated, message: "Use existingLocalURL(identifier:candidateExtensions:) or AssetClient.lookup; paths are content-addressed now")
    @MainActor
    public func localURL(for asset: CDNAsset) -> URL {
        if let location = self.client?.lookup(AssetID(asset.identifier), extensions: [asset.fileExtension]) {
            return location.url
        }
        let directories = asset.localPathComponents.isEmpty
            ? Array(CDNLocalStore.segments(of: asset.identifier).dropLast())
            : asset.localPathComponents
        let root = self.installPoint.configuration.clientConfiguration.legacy.root ?? CDNLocalStore.defaultLegacyRoot()
        let directory = directories.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        return directory.appendingPathComponent("\(asset.resolvedFileName).\(asset.fileExtension)", isDirectory: false)
    }

    /// The prior art's default root, `<Caches>/CDNAssets` (a path computation, no I/O; what
    /// `LegacyMigrationPolicy.root == nil` means).
    static func defaultLegacyRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("CDNAssets", isDirectory: true)
    }

    /// Refused: the client places only bytes it fetched and verified itself. Throws `CDNShimError.storeIsOwnedByTheClient`
    /// and leaves `temporaryURL` in place, as a failed move did in the prior art.
    @available(*, deprecated, message: "The AssetClient downloads, verifies and stores assets; use AssetClient.resolve(_:priority:)")
    public func store(temporaryURL: URL, for asset: CDNAsset) throws {
        throw CDNShimError.storeIsOwnedByTheClient
    }

    /// Records `newManifest` as `cacheManifest` does and reports nothing moved: the client reconciles inside its own sync,
    /// before any download, and `CDNSyncCoordinator.lastReconciliation` reports what that run moved and pruned.
    @available(*, deprecated, message: "The AssetClient reconciles inside sync; see CDNSyncCoordinator.lastReconciliation")
    @MainActor
    @discardableResult
    public func reconcile(newManifest: [CDNAsset]) -> CDNReconciliationSummary {
        self.cacheManifest(newManifest)
        return CDNReconciliationSummary()
    }

    /// The client this store adapts, once one is installed.
    @MainActor
    public var client: AssetClient? {
        self.installPoint.client
    }

    /// The local file for `identifier` in one of `candidateExtensions` (any extension when empty): the client's
    /// snapshot, no file-system call and no network (RECON §5: offline). Unlike the prior art, the extension filter also
    /// applies to an asset the manifest knows (ADR-037, as `AssetFallbackChain.locate`), so an image page is never handed
    /// a video. A stale asset (new content announced, not yet stored) still answers with its old bytes, as before.
    @MainActor
    public func existingLocalURL(identifier: String, candidateExtensions: [String]) -> URL? {
        self.client?.lookup(AssetID(identifier), extensions: candidateExtensions)?.url
    }

    /// Whether `asset` is stored at the content it describes: present in the client's snapshot with its extension, not
    /// stale, and, when `checksum` is a SHA-256 (64 hex characters), stored under that digest (a blob's name is the
    /// SHA-256 of its bytes, I-1). A checksum that is not a SHA-256 cannot be compared, so such an asset is trusted on
    /// presence (R-MAN-5), where the prior art compared it with its own hash of the file and never matched.
    @MainActor
    public func hasAsset(_ asset: CDNAsset) -> Bool {
        guard let location = self.client?.lookup(AssetID(asset.identifier), extensions: [asset.fileExtension]) else {
            return false
        }
        guard let expected = asset.checksum.flatMap({ ContentHash(hex: $0) }) else {
            return true
        }
        return CDNLocalStore.storedDigest(of: location) == expected
    }

    /// The SHA-256 of a stored blob's bytes, read from its name (`…/blobs/<aa>/<sha256>.<ext>`, I-1): no I/O.
    static func storedDigest(of location: AssetLocation) -> ContentHash? {
        ContentHash(hex: location.url.deletingPathExtension().lastPathComponent)
    }

    /// Every asset of `manifest` that is not stored at the content it describes (`hasAsset`), in manifest order, with
    /// no network: the prior art's availability guarantee. One snapshot read per asset on the main actor.
    @MainActor
    public func missingOrStaleAssets(against manifest: [CDNAsset]) -> [CDNAsset] {
        manifest.filter { !self.hasAsset($0) }
    }

    /// Whether every asset of `manifest` is stored at its content.
    @MainActor
    public func isFullyAvailable(against manifest: [CDNAsset]) -> Bool {
        manifest.allSatisfy { self.hasAsset($0) }
    }
}

/// The manifest entries a store was handed (`cacheManifest`, `reconcile`), main-actor isolated per store.
@MainActor
final class ManifestMemory {
    /// The entries by identifier.
    var entries: [String: CDNAsset] = [:]

    nonisolated init() {}
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
        self.init(migratedCount: report.relocated, prunedCount: report.pruned)
    }
}
