import Foundation
import ZTronAssetModel

/// One legacy file to adopt (R-STO-11): its path below the legacy root, the entries it holds and the digest they expect.
struct LegacyFile: Sendable, Hashable {
    /// Directory components and file name, relative to the legacy root.
    var components: [String]
    /// The legacy entries stored in this file, in manifest order.
    var ids: [AssetID]
    /// The digest the bytes must have.
    var digest: ContentHash
    /// The size the manifest states, when it does.
    var byteSize: Int64?
}

/// The phase-1 plan (store.md §7).
struct LegacyPlan: Sendable, Hashable {
    /// The files to adopt, in path order.
    var files: [LegacyFile]
    /// Entries dropped while planning.
    var dropped: Int
    /// Every entry of the legacy manifest, in manifest order.
    var legacyIDs: [AssetID]
}

/// The legacy planner (pure).
enum LegacyPlanner {
    /// The prior art's path of `entry`.
    static func relativePath(of entry: ManifestEntry) -> [String]? {
        fatalError("WP-C: LegacyPlanner.relativePath not implemented")
    }

    /// The plan.
    static func plan(entries: [ManifestEntry], checksums: [String: String], files: Set<[String]>) -> LegacyPlan {
        fatalError("WP-C: LegacyPlanner.plan not implemented")
    }
}
