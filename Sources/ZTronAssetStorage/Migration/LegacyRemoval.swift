import Foundation
import ZTronAssetModel

/// What phase 4 removes (pure; run in a bulk unit; ADR draft C-15, review round 2): only items the prior art could
/// have written, found by a non-following listing, never a recursive removal.
struct LegacyRemoval: Sendable, Hashable {
    /// The prior art's manifest cache, removed last.
    static let manifestName = "manifest.json"
    /// The prior art's checksum cache.
    static let checksumsName = "local-checksums.json"
    /// Both metadata files.
    static let metadataNames: Set<String> = [LegacyRemoval.manifestName, LegacyRemoval.checksumsName]

    /// Files and links to unlink first, in path order: each legacy entry's file, `local-checksums.json`, and any symbolic
    /// link where the prior art had a file or a directory (unlinking a link never touches its target).
    var leaves: [[String]]
    /// Directories on the entries' paths, deepest first; one that still holds anything else stays (ENOTEMPTY).
    var directories: [[String]]
    /// Whether a regular `manifest.json` (or a link of that name) is to be removed, after everything else.
    var removesManifest: Bool

    /// The removal set for `tree` given the legacy manifest as read now: an unreadable or undecodable one attributes no
    /// entry, so only the metadata files go and every other file stays (it cannot be told from the user's own).
    static func plan(manifest: LegacyRead, tree: LegacyTree, limits: ManifestLimits) -> LegacyRemoval {
        let decoded = LegacyDecoding.decode(manifest: manifest, checksums: .absent, limits: limits, files: [])
        let paths = decoded.plan.paths
        var ancestors: Set<[String]> = []
        for path in paths {
            for depth in stride(from: 1, to: path.count, by: 1) {
                ancestors.insert(Array(path.prefix(depth)))
            }
        }
        let checksums = [LegacyRemoval.checksumsName]
        var leaves = tree.files.filter { paths.contains($0) || $0 == checksums }
        leaves.formUnion(tree.links.filter { paths.contains($0) || ancestors.contains($0) || $0 == checksums })
        let manifest = [LegacyRemoval.manifestName]
        let directories = tree.directories.filter { ancestors.contains($0) }
        return LegacyRemoval(
            leaves: leaves.sorted { $0.lexicographicallyPrecedes($1) },
            directories: directories.sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.lexicographicallyPrecedes(rhs)
            },
            removesManifest: tree.files.contains(manifest) || tree.links.contains(manifest)
        )
    }
}
