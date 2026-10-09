import Foundation
import ZTronAssetModel

/// Where the legacy root lies relative to the store (R-STO-11, I-2; ADR draft C-13, review round 2). The prior art's
/// `baseDirectory:` was the legacy root itself, so an app may hand the same directory to the store
/// (`StorageLocation.custom(X)` with `LegacyMigrationPolicy(root: X)`): migrating would rename legacy files inside the
/// store's own tree and phase 4 would remove it. A root that is the store's directory (`<base>/ZTronAssetKit`), one of
/// its ancestors, or inside it is never migrated.
enum LegacyPlacement {
    /// Whether one path lies at or below the other, compared by normalized components, after Unicode canonical
    /// composition and case folding, so a case-insensitive volume cannot hide an overlap; erring towards "overlaps" only
    /// skips a migration.
    static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = LegacyPlacement.components(lhs).map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        let right = LegacyPlacement.components(rhs).map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        let shorter = min(left.count, right.count)
        return Array(left.prefix(shorter)) == Array(right.prefix(shorter))
    }

    /// The components of an absolute file URL below `/`, with `.` dropped and `..` applied (never above `/`). Pure
    /// string work: `standardizedFileURL` may consult the file system.
    static func components(_ url: URL) -> [String] {
        var components: [String] = []
        for component in url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch component {
            case ".":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(component)
            }
        }
        return components
    }

    /// The identities of `url` and of each of its ancestors up to `/`, nearest first (`nil` where an item cannot be
    /// stat-ed). Intermediate symbolic links are followed by the stat, so two paths that name the same directory
    /// through a link have equal identities where their spelling differs.
    static func identities(_ url: URL, fileSystem: any FileSystem) -> [FileIdentity?] {
        let components = LegacyPlacement.components(url)
        return stride(from: components.count, through: 0, by: -1).map { depth in
            let path = "/" + components.prefix(depth).joined(separator: "/")
            return (try? fileSystem.itemInfo(at: URL(fileURLWithPath: path, isDirectory: true)))?.identity
        }
    }

    /// Whether the item at `root` is `container` or one of its ancestors, or `container` is `root` or one of its
    /// ancestors, by `(st_dev, st_ino)` (one unit of stats); `nil` when `root` itself could not be stat-ed (an I/O
    /// error decides nothing, as for the root's kind).
    static func itemsOverlap(_ root: URL, _ container: URL, fileSystem: any FileSystem) -> Bool? {
        let rootIdentity: FileIdentity?
        do throws(FileSystemError) {
            rootIdentity = try fileSystem.itemInfo(at: root)?.identity
        } catch {
            return nil
        }
        let parent = LegacyPlacement.components(root).dropLast()
        let ancestors = parent.isEmpty && LegacyPlacement.components(root).isEmpty
            ? []
            : LegacyPlacement.identities(URL(fileURLWithPath: "/" + parent.joined(separator: "/"), isDirectory: true), fileSystem: fileSystem)
        let rootChain = [rootIdentity] + ancestors
        let containerChain = LegacyPlacement.identities(container, fileSystem: fileSystem)
        if let rootIdentity, containerChain.contains(rootIdentity) {
            return true
        }
        if let container = containerChain.first ?? nil, rootChain.contains(container) {
            return true
        }
        return false
    }
}

extension AssetStore {
    /// Whether the legacy `root` overlaps the store's own directory, by path, then by identity in one metadata unit;
    /// `nil` when the root could not be stat-ed.
    func legacyRootOverlapsStore(_ root: URL, layout: StoreLayout) async -> Bool? {
        let container = layout.container
        if LegacyPlacement.pathsOverlap(root, container) {
            return true
        }
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R1, R11 — nothing: a snapshot of where the two directories are; the caller re-checks the phase.
        return await self.runUnit(on: self.environment.metadataExecutor) {
            LegacyPlacement.itemsOverlap(root, container, fileSystem: fileSystem)
        }
    }
}
