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
///
/// The snapshot is the client's, installed by `AssetClient.start()` (ADR-037): until the installed client has started,
/// the lookups answer `nil` and `false` even for assets stored in an earlier launch, where the prior art read the disk
/// from launch on. Start the client at launch, before carousel content is created (MIGRATION.md, step 3). On a launch
/// during legacy migration (the first launch after adoption, and any later launch that resumes a migration an earlier
/// launch did not finish) that is not enough for the prior art's own files: legacy migration adopts them in batches that
/// start only after `start()` has returned, and a file answers once the snapshot holding its adoption is installed, at
/// the end of its batch, or at once when a resolve adopted it on demand (`CDNAssetResolver.resolveViaNetwork`, no
/// download). Until then a lookup misses it, so `BasicVideoPage`, which has no network step, finds a prior-art video only
/// once it is adopted (K-15).
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
    /// one, migrates the prior art's files found in `baseDirectory` (its legacy root) and keeps its own root beside it,
    /// in the same parent directory (`<parent>/ZTronAssetKit/v1`, `StorageLocation.custom`): on the same volume, so
    /// migration renames instead of copying, and in the durability class the app chose by picking that parent. Never
    /// inside it: the module refuses to migrate a legacy root that contains the store (R-STO-11), and the prior art's
    /// directory need not exist on a fresh install, where its parent (`Caches`, `Documents`) does.
    ///
    /// One client per resolved base directory (R-STO-9; the second client's `start()` throws
    /// `storageUnavailable(.locked)`), counting every client of the process: two directories with one parent map to one
    /// root, and a directory in Caches or Application Support maps to the root of a client at `StorageLocation.caches` or
    /// `.applicationSupport`, such as the process install point's. And one legacy root per process: a store whose
    /// directory is the prior art's default (`<Caches>/CDNAssets`) migrates the tree that an installed process client
    /// with the default `LegacyMigrationPolicy()` migrates too, so do not run both over one prior-art directory. A
    /// parent that does not exist makes `start()` throw `storageUnavailable`, and a `baseDirectory` named
    /// `ZTronAssetKit` is the store's own directory, whose migration the module refuses. `computeChecksum` is ignored:
    /// the client verifies SHA-256 checksums itself (R-INT-*).
    @available(*, deprecated, message: "Bind the store to a client: CDNLocalStore(client:), or CDNLocalStore.shared after CDNProviderFactory.install(_:)")
    public convenience init(
        baseDirectory: URL? = nil,
        computeChecksum: @escaping @Sendable (URL) throws -> String = CDNLocalStore.sha256Hex
    ) {
        guard let baseDirectory else {
            self.init(installPoint: .process)
            return
        }
        let configuration = CDNConfiguration(
            location: .custom(baseDirectory.deletingLastPathComponent()),
            legacy: LegacyMigrationPolicy(root: baseDirectory)
        )
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
    ///
    /// Unlike the prior art, the path stays inside the legacy root whatever the entry says (a manifest is untrusted
    /// input, R-MAN-2, R-SEC-2): a directory component that is empty, `.` or `..`, or that contains `/`, is dropped, and
    /// in the file name every `/` becomes `_` (a name that would be `.` or `..` becomes `_`).
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
        let directory = directories.filter(CDNLocalStore.isConfinedComponent).reduce(root) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let fileName = CDNLocalStore.confinedFileName("\(asset.resolvedFileName).\(asset.fileExtension)")
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Whether `component` names one directory below its parent: not empty, not `.` or `..`, no `/`.
    static func isConfinedComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
    }

    /// `name` as one entry of its directory: every `/` becomes `_`, and a name that would be `.` or `..` is `_`.
    static func confinedFileName(_ name: String) -> String {
        let flattened = name.replacingOccurrences(of: "/", with: "_")
        return CDNLocalStore.isConfinedComponent(flattened) ? flattened : "_"
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
    /// `nil` until the installed client has started (`AssetClient.start()` installs the first snapshot, ADR-037), even
    /// for an asset stored in an earlier launch, and, on a launch during legacy migration, for a prior-art file until
    /// legacy migration or a resolve adopted it, after `start()` has returned (K-15).
    ///
    /// The URL names stored content (a content-addressed blob), not the prior art's pretty path, whose bytes the prior art
    /// replaced in place: after a content change, a prune or an eviction, the old file is removed
    /// `StoragePolicy.deletionGrace` after the new snapshot (ADR-017). A consumer that reads the path later, such as
    /// `BasicVideoPage`'s player, looks it up again when a read fails, or holds a lease (`AssetClient.withAsset`) while it
    /// reads (K-11).
    @MainActor
    public func existingLocalURL(identifier: String, candidateExtensions: [String]) -> URL? {
        self.client?.lookup(AssetID(identifier), extensions: candidateExtensions)?.url
    }

    /// Whether `asset` is stored at the content it describes: present in the client's snapshot with its extension and,
    /// when `checksum` is a SHA-256 (64 hex characters), stored under that digest (a blob's name is the SHA-256 of its
    /// bytes, I-1). The answer is relative to the asset given, as the prior art's comparison was: the client's own view
    /// of staleness (`AssetLocation.isStale`, relative to its applied manifest) is not consulted. A checksum that is not
    /// a SHA-256 cannot be compared, so such an asset is trusted on presence (R-MAN-5), where the prior art compared it
    /// with its own hash of the file and never matched. `false` until the installed client has started (ADR-037) and,
    /// on a launch during legacy migration, for a prior-art file until its adoption is installed (K-15).
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
    /// no network: the prior art's availability guarantee. One snapshot read per asset on the main actor. On a launch
    /// during legacy migration it also lists the prior-art files whose adoption is not installed yet (K-15).
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
