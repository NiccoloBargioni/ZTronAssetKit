import Foundation
import ZTronAssetModel

/// What reading a legacy metadata file found.
enum LegacyRead: Sendable, Hashable {
    /// No such file.
    case absent
    /// Its bytes, read whole.
    case bytes(Data)
    /// Not a regular file, or larger than the limit: treated as undecodable.
    case unusable
    /// Its stat or one of its reads failed, or it changed size while it was read: an I/O error says nothing about the
    /// file, so nothing is decided from it (review round 3, ZProbe-read; as for a root that cannot be stat-ed, C-13).
    case failed
}

/// What a non-following listing of the legacy tree found, as paths relative to its root (S2-10).
struct LegacyTree: Sendable, Hashable {
    /// Regular files.
    var files: Set<[String]> = []
    /// Directories below the root (never one reached through a symbolic link).
    var directories: Set<[String]> = []
    /// Symbolic links (never followed) and other items that are neither files nor directories.
    var links: Set<[String]> = []
    /// A directory could not be listed: the tree is incomplete, so nothing is decided from it (review round 3,
    /// ZProbe-list: its files would count as missing in phase 1, and phase 4 would leave them unattributable).
    var failed = false
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

    /// Reads a legacy metadata file whole, in ≤ 1 MiB units on the bulk executor, refusing more than `limit` bytes. The
    /// phase is re-checked after every unit, so a store that closes meanwhile submits no further read (review round 3).
    func readLegacyFile(_ url: URL, limit: Int64) async throws(StoreError) -> LegacyRead {
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R1, R11, c-4 (proposed) — the phase (`checkLive` below); the file belongs to the prior art, which no
        // longer runs.
        let info = await self.runUnit(on: self.environment.metadataExecutor) { () -> Result<FileItemInfo?, FileSystemError> in
            do throws(FileSystemError) {
                return .success(try fileSystem.itemInfo(at: url))
            } catch {
                return .failure(error)
            }
        }
        try self.checkLive()
        guard case .success(let item) = info else {
            return .failed
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
            // REENTRANCY: R1, R11, c-4 (proposed) — the phase (`checkLive` below); the bytes accumulate in a local.
            let chunk = await self.runUnit(on: self.environment.bulkExecutor) { () -> Data? in
                try? fileSystem.read(from: url, offset: offset, maxLength: length)
            }
            try self.checkLive()
            guard let chunk, !chunk.isEmpty else {
                // A failed read, or a file that shrank while it was read.
                return .failed
            }
            data.append(chunk)
        }
        return .bytes(data)
    }

    /// Every item below `root`, as path components relative to it, from a **non-following** listing (one unit per
    /// directory, S2-10): a symbolic link is neither descended into nor followed, so no planned path passes through one.
    /// At most `maxDepth` directory levels and `limits.maxEntries` directories are visited. A listing that fails stops
    /// the walk and marks the tree `failed`. The phase is re-checked after every unit, and with `cancellable` (phase 4,
    /// which runs in the caller's task) the caller's cancellation too, so neither a closed store nor a cancelled caller
    /// submits further listings (review round 3).
    func listLegacyTree(_ root: URL, cancellable: Bool = false, maxDepth: Int = 64) async throws(StoreError) -> LegacyTree {
        let fileSystem = self.environment.fileSystem
        let maxDirectories = max(1, self.configuration.limits.maxEntries)
        var tree = LegacyTree()
        var directories: [[String]] = [[]]
        var next = 0
        while next < directories.count, next < maxDirectories {
            let relative = directories[next]
            next += 1
            let url = relative.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            // REENTRANCY: R1, R11, c-4 (proposed) — the phase, and in phase 4 the caller's cancellation, below; the listing
            // only accumulates, and the plan is computed once it is complete.
            let listing = await self.runUnit(on: self.environment.metadataExecutor) {
                CleanupUnits.list(url, fileSystem: fileSystem)
            }
            try self.checkLive()
            if cancellable, Task.isCancelled {
                throw .cancelled
            }
            guard case .success(let items) = listing else {
                tree.failed = true
                return tree
            }
            for item in items {
                let path = relative + [item.name]
                switch item.kind {
                case .directory:
                    tree.directories.insert(path)
                    if relative.count < maxDepth {
                        directories.append(path)
                    }
                case .file:
                    tree.files.insert(path)
                case .symbolicLink, .other:
                    tree.links.insert(path)
                }
            }
        }
        return tree
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

    /// Phase 4's removal (ADR draft C-15, review round 2): only what the prior art wrote, never a recursive removal,
    /// since its root may be a directory the app shares (its docs suggest a `Documents`-rooted one). Anything but a
    /// directory at the root (a symbolic link that replaced it) is removed itself and never listed, since a listing
    /// follows a final link (R-SEC-2); a root that cannot be stat-ed is left for the next call. Otherwise, from a
    /// non-following listing: each legacy entry's file and `local-checksums.json`, then the directories on the entries'
    /// paths deepest first (one still holding anything else stays), then `manifest.json` (last, so a call that stopped
    /// part way can still attribute the files next time), then the root if it is empty. Returns whether everything the
    /// prior art wrote is gone.
    func removeLegacyTree(_ root: URL) async throws(StoreError) -> Bool {
        // REENTRANCY: c-4 (proposed) — nothing: a snapshot of the root's kind, never following a final link.
        let kind = await self.legacyItemKind(root)
        try self.checkLive()
        guard case .success(let rootKind) = kind else {
            return false
        }
        guard let rootKind else {
            return true
        }
        guard rootKind == .directory else {
            // REENTRANCY: c-1 (proposed) — see `removeInUnits`; unlinking a link removes the link only.
            try await self.removeAllInUnits([(url: root, bytes: 0)])
            // REENTRANCY: c-4 (proposed) — nothing: a snapshot of the root.
            return await self.legacyItemKind(root) == .success(nil)
        }
        let manifestURL = root.appendingPathComponent(LegacyRemoval.manifestName, isDirectory: false)
        // REENTRANCY: c-4 (proposed) — the phase (inside); after the durable "done" commit the tree is the migration's
        // alone.
        let manifest = try await self.readLegacyFile(manifestURL, limit: self.configuration.limits.maxPayloadBytes)
        if Task.isCancelled {
            throw .cancelled
        }
        // Nothing is removed on a view the earlier phases never saw: a manifest that could not be read attributes no
        // file, and a listing that failed hides some (review round 3); the next call tries again.
        guard manifest != .failed else {
            return false
        }
        // REENTRANCY: c-4 (proposed) — the phase and the caller's cancellation (inside, after each unit).
        var listed = try await self.listLegacyTree(root, cancellable: true)
        guard !listed.failed else {
            return false
        }
        // A file phase 2 kept after failing to read or move it is never removed: nothing verified it (ZProbe-hash).
        listed.files.subtract(self.state.migration.kept)
        let tree = listed
        let limits = self.configuration.limits
        // REENTRANCY: c-4 (proposed) — the phase; the removal set is computed off the actor (C2).
        let removal = await self.runUnit(on: self.environment.bulkExecutor) {
            LegacyRemoval.plan(manifest: manifest, tree: tree, limits: limits)
        }
        try self.checkLive()
        let url = { (path: [String]) in
            path.dropLast().reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
                .appendingPathComponent(path.last ?? "", isDirectory: false)
        }
        // REENTRANCY: c-1 (proposed) — see `removeInUnits`.
        let leaves = try await self.removeInUnits(removal.leaves.map { (url: url($0), bytes: 0) })
        if leaves.cancelled {
            throw .cancelled
        }
        guard leaves.removed.count == removal.leaves.count else {
            return false
        }
        // REENTRANCY: c-1 (proposed) — as above; a directory that still holds anything fails with ENOTEMPTY and stays.
        try await self.removeAllInUnits(removal.directories.map { (url: url($0), bytes: 0) })
        if removal.removesManifest {
            // REENTRANCY: c-1 (proposed) — as above.
            let removed = try await self.removeInUnits([(url: manifestURL, bytes: 0)])
            if removed.cancelled {
                throw .cancelled
            }
            guard removed.removed.count == 1 else {
                return false
            }
        }
        // REENTRANCY: c-1 (proposed) — as above; a root that still holds anything stays.
        try await self.removeAllInUnits([(url: root, bytes: 0)])
        return true
    }

    /// Whether a relaunch in phase `done` still has phase-4 work: the root holds one of the prior art's metadata files
    /// (`manifest.json` goes last), or nothing at all (a removal that stopped before the root), or cannot be listed.
    func legacyRemovalPending(_ root: URL) async -> Bool {
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R1 — nothing: a snapshot of the root's names.
        let listing = await self.runUnit(on: self.environment.metadataExecutor) {
            CleanupUnits.list(root, fileSystem: fileSystem)
        }
        guard case .success(let items) = listing else {
            return true
        }
        return items.isEmpty || items.contains { $0.kind != .directory && LegacyRemoval.metadataNames.contains($0.name) }
    }
}
