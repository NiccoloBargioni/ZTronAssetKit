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

/// The legacy planner (pure; store.md §7, R-SEC-2 / D-14 hardening).
enum LegacyPlanner {
    /// A path component may hold at most this many UTF-8 bytes (`NAME_MAX`).
    static let maxComponentBytes = 255

    /// Whether `component` can name one directory level or file: non-empty, not `.` or `..`, free of `/` and NUL, at
    /// most `maxComponentBytes` bytes. Anything else could leave the legacy root or address something the prior art
    /// never wrote.
    static func isValidComponent(_ component: String) -> Bool {
        let bytes = component.utf8
        guard !bytes.isEmpty, bytes.count <= LegacyPlanner.maxComponentBytes, component != ".", component != ".." else {
            return false
        }
        return !bytes.contains(UInt8(ascii: "/")) && !bytes.contains(0)
    }

    /// The prior art's path of `entry` below the legacy root, exactly as `CDNLocalStore.localURL(for:)` builds it:
    /// `localPathComponents` when non-empty, else the identifier's dot-separated segments without the last; then
    /// `resolvedFileName.fileExtension`. `nil` when any component is invalid (the entry is dropped, R-SEC-2).
    static func relativePath(of entry: ManifestEntry) -> [String]? {
        let directories = entry.localPathComponents.isEmpty
            ? Array(entry.identifier.rawValue.split(separator: ".").map(String.init).dropLast())
            : entry.localPathComponents
        let components = directories + ["\(entry.resolvedFileName).\(entry.fileExtension)"]
        return components.allSatisfy(LegacyPlanner.isValidComponent) ? components : nil
    }

    /// A `local-checksums.json` value as a digest: exactly 64 lowercase hex digits (the prior art's `sha256Hex`); any
    /// other value came from a custom `computeChecksum` and proves nothing.
    static func localDigest(_ value: String?) -> ContentHash? {
        guard let value, value.utf8.count == 64,
            value.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else {
            return nil
        }
        return ContentHash(hex: value)
    }

    /// The plan from the legacy manifest's `entries` (manifest order, duplicates already dropped), the prior art's
    /// `checksums` and the regular `files` a non-following listing found (paths relative to the root).
    ///
    /// Each entry's file must be listed (so no component is a symbolic link, S2-10). Its expected digest is the manifest
    /// checksum, or for a checksum-less entry the local checksum; an entry whose local checksum disagrees with its
    /// manifest checksum is dropped (the prior art recorded other bytes than the manifest names: the file is stale), and
    /// so is one with neither. Entries naming the same file share it when they expect the same digest; a later one
    /// expecting another digest is dropped.
    static func plan(entries: [ManifestEntry], checksums: [String: String], files: Set<[String]>) -> LegacyPlan {
        var planned: [LegacyFile] = []
        var byPath: [[String]: Int] = [:]
        var dropped = 0
        for entry in entries {
            guard let path = LegacyPlanner.relativePath(of: entry), files.contains(path) else {
                dropped += 1
                continue
            }
            let local = LegacyPlanner.localDigest(checksums[entry.identifier.rawValue])
            let digest: ContentHash
            if let checksum = entry.checksum {
                guard local == nil || local == checksum else {
                    dropped += 1
                    continue
                }
                digest = checksum
            } else if let local {
                digest = local
            } else {
                dropped += 1
                continue
            }
            if let index = byPath[path] {
                if planned[index].digest == digest {
                    planned[index].ids.append(entry.identifier)
                } else {
                    dropped += 1
                }
                continue
            }
            byPath[path] = planned.count
            planned.append(LegacyFile(components: path, ids: [entry.identifier], digest: digest, byteSize: entry.byteSize))
        }
        planned.sort { $0.components.lexicographicallyPrecedes($1.components) }
        return LegacyPlan(files: planned, dropped: dropped, legacyIDs: entries.map(\.identifier))
    }
}
