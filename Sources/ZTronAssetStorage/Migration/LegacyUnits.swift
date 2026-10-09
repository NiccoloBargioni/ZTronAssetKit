import Foundation
import ZTronAssetModel

/// What reading a legacy metadata file found.
enum LegacyRead: Sendable, Hashable {
    /// No such file.
    case absent
    /// Its bytes, read whole.
    case bytes(Data)
    /// Not a regular file, larger than the limit, or a read failed: treated as undecodable.
    case unusable
}

/// The blocking units of legacy migration (ADR-003): stats, ≤ 1 MiB reads, one listing per directory, bounded
/// removals, the `UserDefaults` stamp.
extension AssetStore {
    /// The legacy root: the configured one, or the prior art's `<Caches>/CDNAssets`; `nil` when it cannot be resolved.
    func resolveLegacyRoot() async -> URL? {
        if let root = self.configuration.legacy.root {
            return root
        }
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R1, R11 — nothing: a value computed from the volume, no store state read before it.
        let caches = await self.runUnit(on: self.environment.metadataExecutor) { () -> URL? in
            try? fileSystem.standardDirectory(.caches)
        }
        return caches?.appendingPathComponent("CDNAssets", isDirectory: true)
    }

    /// The kind of the item at `url` (never following a final link): `.success(nil)` when absent, `.failure` when the
    /// stat itself failed (an unreadable root is not a vanished one).
    func legacyItemKind(_ url: URL) async -> Result<FileItemKind?, FileSystemError> {
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R1, R11 — nothing: a snapshot of the item.
        return await self.runUnit(on: self.environment.metadataExecutor) { () -> Result<FileItemKind?, FileSystemError> in
            do throws(FileSystemError) {
                return .success(try fileSystem.itemInfo(at: url)?.kind)
            } catch {
                return .failure(error)
            }
        }
    }

    /// Reads a legacy metadata file whole, in ≤ 1 MiB units on the bulk executor, refusing more than `limit` bytes.
    func readLegacyFile(_ url: URL, limit: Int64) async -> LegacyRead {
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R1, R11 — nothing: the file belongs to the prior art, which no longer runs.
        let info = await self.runUnit(on: self.environment.metadataExecutor) { () -> Result<FileItemInfo?, FileSystemError> in
            do throws(FileSystemError) {
                return .success(try fileSystem.itemInfo(at: url))
            } catch {
                return .failure(error)
            }
        }
        guard case .success(let item) = info else {
            return .unusable
        }
        guard let item else {
            return .absent
        }
        guard item.kind == .file, item.byteSize <= limit else {
            return .unusable
        }
        var data = Data()
        while data.count < item.byteSize {
            let offset = Int64(data.count)
            let length = Int(min(Int64(1 << 20), item.byteSize - offset))
            // REENTRANCY: R1, R11 — nothing: the bytes accumulate in a local; the file is the prior art's.
            let chunk = await self.runUnit(on: self.environment.bulkExecutor) { () -> Data? in
                try? fileSystem.read(from: url, offset: offset, maxLength: length)
            }
            guard let chunk, !chunk.isEmpty else {
                return .unusable
            }
            data.append(chunk)
        }
        return .bytes(data)
    }

    /// Every regular file below `root`, as path components relative to it, from a **non-following** listing (one unit
    /// per directory, S2-10): a symbolic link is neither descended into nor listed, so no planned path passes through
    /// one. At most `maxDepth` directory levels and `limits.maxEntries` directories are visited.
    func listLegacyTree(_ root: URL, maxDepth: Int = 64) async -> Set<[String]> {
        let fileSystem = self.environment.fileSystem
        let maxDirectories = max(1, self.configuration.limits.maxEntries)
        var files: Set<[String]> = []
        var directories: [[String]] = [[]]
        var next = 0
        while next < directories.count, next < maxDirectories {
            let relative = directories[next]
            next += 1
            let url = relative.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            // REENTRANCY: R1, R11 — nothing: the listing only accumulates; the plan is computed once it is complete.
            let listing = await self.runUnit(on: self.environment.metadataExecutor) {
                CleanupUnits.list(url, fileSystem: fileSystem)
            }
            guard case .success(let items) = listing else {
                continue
            }
            for item in items {
                switch item.kind {
                case .directory where relative.count < maxDepth:
                    directories.append(relative + [item.name])
                case .file:
                    files.insert(relative + [item.name])
                case .directory, .symbolicLink, .other:
                    break
                }
            }
        }
        return files
    }

    /// The prior art's stamp (`UserDefaults`), read in a unit.
    func readLegacyStamp() async -> String? {
        let defaults = self.environment.legacyDefaults
        let key = self.configuration.legacy.defaultsKey
        // REENTRANCY: R1, R11 — nothing: a value read from the defaults.
        return await self.runUnit(on: self.environment.metadataExecutor) {
            defaults.string(forKey: key)
        }
    }

    /// Removes the prior art's stamp (`UserDefaults`) in a unit; only ever after a durable "done" commit, or when the
    /// legacy tree is gone so the stamp can never be migrated (store.md §7, D-6).
    func removeLegacyStamp() async {
        let defaults = self.environment.legacyDefaults
        let key = self.configuration.legacy.defaultsKey
        // REENTRANCY: c-4 (proposed) — nothing: removing a key that is already gone is a no-op.
        await self.runUnit(on: self.environment.metadataExecutor) {
            if defaults.string(forKey: key) != nil {
                defaults.removeValue(forKey: key)
            }
        }
    }

    /// Phase 4's tree removal: lists the tree without following links, removes every file and link (never a link's
    /// target), then the directories deepest first, then the root. Returns whether the root is gone.
    func removeLegacyTree(_ root: URL) async throws(StoreError) -> Bool {
        // REENTRANCY: c-4 (proposed) — nothing: a tree already gone needs no removal (and no mutation).
        if await self.legacyItemKind(root) == .success(nil) {
            return true
        }
        try self.checkLive()
        let fileSystem = self.environment.fileSystem
        var directories: [URL] = [root]
        var leaves: [URL] = []
        var next = 0
        while next < directories.count {
            let directory = directories[next]
            next += 1
            // REENTRANCY: c-4 (proposed) — nothing: after the durable "done" commit the tree is the migration's alone.
            let listing = await self.runUnit(on: self.environment.metadataExecutor) {
                CleanupUnits.list(directory, fileSystem: fileSystem)
            }
            try self.checkLive()
            guard case .success(let items) = listing else {
                continue
            }
            for item in items.sorted(by: { $0.name < $1.name }) {
                let url = directory.appendingPathComponent(item.name, isDirectory: item.kind == .directory)
                if item.kind == .directory {
                    directories.append(url)
                } else {
                    leaves.append(url)
                }
            }
        }
        // REENTRANCY: c-1 (proposed) — see `removeInUnits`.
        _ = try await self.removeInUnits(leaves.map { (url: $0, bytes: 0) })
        // REENTRANCY: c-1 (proposed) — as above, deepest directories first.
        _ = try await self.removeInUnits(directories.reversed().map { (url: $0, bytes: 0) })
        return await self.legacyItemKind(root) == .success(nil)
    }
}
