import Foundation
import ZTronAssetModel

/// One inode of the fake volume (store.md §3.4): a file, a directory or a symbolic link.
///
/// Durability is modelled per item and per directory, independently (the pessimistic model the store design proves
/// itself against): a file's `durableData` is its content at the last `synchronizeFile`; a directory's
/// `durableEntries` is its listing at the last `synchronizeDirectory`. A name and the data behind it are therefore
/// durable separately, which is exactly what makes a renamed but never-synced file zero-length after a power loss.
struct FSNode: Sendable, Hashable {
    /// File, directory or symbolic link (`.other` is never created).
    var kind: FileItemKind
    /// A file's current bytes.
    var data: [UInt8] = []
    /// A file's bytes at its last data sync (empty when never synced).
    var durableData: [UInt8] = []
    /// A directory's current listing.
    var entries: [String: UInt64] = [:]
    /// A directory's listing at its last sync (empty when never synced).
    var durableEntries: [String: UInt64] = [:]
    /// A symbolic link's target, verbatim.
    var target: String = ""
    /// Last data modification (from the injected `TimeSource`).
    var modifiedAt: Date
    /// Backup and protection attributes applied to the item, if any.
    var attributes: StoreAttributes?
    /// Names in the *current* namespace that point at this inode (files and links; directories keep 1).
    var links: Int = 0
}

/// Where a path resolved to: the directory that holds the final name, the name, and the inode behind it.
struct FSLocation: Sendable, Hashable {
    /// The directory that holds `name`; `nil` only for the volume root itself.
    var parent: UInt64?
    /// The final component (empty for the root).
    var name: String
    /// The inode at `name`, when one exists.
    var node: UInt64?
}

/// The whole fake volume: an inode table rooted at `/` (id 1).
///
/// Every mutation is a plain value mutation, so a `FakeFileSystem` holds one of these inside its `Mutex` and a
/// `DiskImage` can carry an exact copy across a crash. Paths are absolute and resolved lexically after
/// `standardizedFileURL`; intermediate symbolic links are followed, final ones only where POSIX follows them.
struct FSGraph: Sendable, Hashable {
    /// The root directory's inode.
    static let rootID: UInt64 = 1
    /// The `st_dev` every item of the fake volume reports.
    static let device: UInt64 = 0x5A54_414B
    /// The longest chain of symbolic links a lookup follows (`ELOOP` past it).
    static let maxLinkExpansions = 32

    /// Every inode some mix of current and synced listings reaches from the root (see `collectGarbage`).
    var nodes: [UInt64: FSNode]
    /// The next inode number (never reused, so identities stay unique across lifetimes).
    var nextID: UInt64

    /// An empty volume whose root directory is durable.
    init(rootModifiedAt: Date) {
        self.nodes = [FSGraph.rootID: FSNode(kind: .directory, modifiedAt: rootModifiedAt, links: 1)]
        self.nextID = FSGraph.rootID + 1
    }

    // MARK: Paths

    /// The components of an absolute file URL, `.` and `..` removed lexically; `EINVAL` for anything else.
    static func components(of url: URL) throws(FileSystemError) -> [String] {
        guard url.isFileURL else {
            throw .other(errno: EINVAL)
        }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else {
            throw .other(errno: EINVAL)
        }
        return FSGraph.components(of: path)
    }

    /// The non-empty components of a path string (no `.`/`..` processing).
    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `"/" + components`.
    static func path(_ components: [String]) -> String {
        "/" + components.joined(separator: "/")
    }

    // MARK: Lookup

    /// Resolves `components` in the current namespace. Intermediate symbolic links are followed (as POSIX does);
    /// the final one only when `followFinal`. A missing intermediate is `.notFound`, a non-directory intermediate
    /// `ENOTDIR`, a link chain longer than `maxLinkExpansions` `ELOOP`. A missing final name is not an error: the
    /// location then has `node == nil`.
    func locate(_ components: [String], followFinal: Bool) throws(FileSystemError) -> FSLocation {
        var pending = components[...]
        var walked: [String] = []
        var current = FSGraph.rootID
        var expansions = 0
        while let name = pending.first {
            pending = pending.dropFirst()
            if name == "." {
                continue
            }
            if name == ".." {
                if !walked.isEmpty {
                    walked.removeLast()
                }
                current = try self.directory(at: walked)
                continue
            }
            guard self.nodes[current]?.kind == .directory else {
                throw .other(errno: ENOTDIR)
            }
            let isFinal = pending.isEmpty
            guard let child = self.nodes[current]?.entries[name], let node = self.nodes[child] else {
                if isFinal {
                    return FSLocation(parent: current, name: name, node: nil)
                }
                throw .notFound
            }
            if node.kind == .symbolicLink, !isFinal || followFinal {
                expansions += 1
                guard expansions <= FSGraph.maxLinkExpansions else {
                    throw .other(errno: ELOOP)
                }
                let target = FSGraph.components(of: node.target)
                let base = node.target.hasPrefix("/") ? [] : walked
                pending = (base + target)[...] + pending
                walked = []
                current = FSGraph.rootID
                continue
            }
            if isFinal {
                return FSLocation(parent: current, name: name, node: child)
            }
            walked.append(name)
            current = child
        }
        return FSLocation(parent: nil, name: "", node: current)
    }

    /// The directory at already-resolved components (no links on the way).
    private func directory(at components: [String]) throws(FileSystemError) -> UInt64 {
        var current = FSGraph.rootID
        for name in components {
            guard let child = self.nodes[current]?.entries[name], self.nodes[child]?.kind == .directory else {
                throw .notFound
            }
            current = child
        }
        return current
    }

    /// Whether `ancestor` is `node` or one of its directories' current descendants (rename into itself).
    func contains(_ ancestor: UInt64, _ node: UInt64) -> Bool {
        if ancestor == node {
            return true
        }
        var stack = [ancestor]
        var seen: Set<UInt64> = [ancestor]
        while let next = stack.popLast() {
            for child in (self.nodes[next]?.entries ?? [:]).values where seen.insert(child).inserted {
                if child == node {
                    return true
                }
                if self.nodes[child]?.kind == .directory {
                    stack.append(child)
                }
            }
        }
        return false
    }

    // MARK: Mutation helpers

    /// Allocates an inode.
    mutating func allocate(_ node: FSNode) -> UInt64 {
        let id = self.nextID
        self.nextID += 1
        self.nodes[id] = node
        return id
    }

    /// Links `child` as `name` in `directory`'s current listing.
    mutating func link(_ child: UInt64, as name: String, in directory: UInt64) {
        self.nodes[directory]?.entries[name] = child
        self.nodes[child]?.links += 1
    }

    /// Removes `name` from `directory`'s current listing; returns the bytes the volume no longer holds.
    @discardableResult
    mutating func unlink(_ name: String, in directory: UInt64) -> Int64 {
        guard let child = self.nodes[directory]?.entries.removeValue(forKey: name) else {
            return 0
        }
        self.nodes[child]?.links -= 1
        guard let node = self.nodes[child], node.links <= 0, node.kind == .file else {
            return 0
        }
        return Int64(node.data.count)
    }

    // MARK: Views

    /// Bytes held by files the current namespace reaches (each inode once).
    func currentUsage() -> Int64 {
        var total: Int64 = 0
        for id in self.reachableCurrent() {
            if let node = self.nodes[id], node.kind == .file {
                total += Int64(node.data.count)
            }
        }
        return total
    }

    /// Inodes reachable from the root through current listings.
    func reachableCurrent() -> Set<UInt64> {
        var seen: Set<UInt64> = [FSGraph.rootID]
        var stack = [FSGraph.rootID]
        while let next = stack.popLast() {
            guard let node = self.nodes[next], node.kind == .directory else {
                continue
            }
            for child in node.entries.values where seen.insert(child).inserted {
                stack.append(child)
            }
        }
        return seen
    }

    /// Recomputes every current link count from the current namespace (after a load or a power loss).
    mutating func recountLinks() {
        for id in self.nodes.keys {
            self.nodes[id]?.links = 0
        }
        self.nodes[FSGraph.rootID]?.links = 1
        for id in self.reachableCurrent() {
            for child in (self.nodes[id]?.entries ?? [:]).values {
                self.nodes[child]?.links += 1
            }
        }
    }

    /// Drops inodes no mix of current and synced listings reaches (a crash discards open-but-unlinked files).
    ///
    /// The walk follows both listings of every directory it reaches, not the two namespaces separately: a directory
    /// reachable only through current names (created and never synced into its parent) can still hold a synced
    /// listing, and a later lifetime that syncs the parent makes that listing what a power loss restores (store-1
    /// S1-01). Its synced-but-since-unlinked files must therefore survive a process kill.
    mutating func collectGarbage() {
        var keep: Set<UInt64> = [FSGraph.rootID]
        var stack = [FSGraph.rootID]
        while let next = stack.popLast() {
            guard let node = self.nodes[next], node.kind == .directory else {
                continue
            }
            for child in Array(node.entries.values) + Array(node.durableEntries.values) where keep.insert(child).inserted {
                stack.append(child)
            }
        }
        for id in Array(self.nodes.keys) where !keep.contains(id) {
            self.nodes.removeValue(forKey: id)
        }
    }

    /// The observable state: every path of the current and the durable namespace, with contents.
    func views() -> DiskViews {
        var views = DiskViews()
        self.walk(durable: false) { path, node in
            switch node.kind {
            case .file:
                views.files[path] = node.data
            case .directory:
                views.directories.insert(path)
            case .symbolicLink:
                views.symbolicLinks[path] = node.target
            case .other:
                break
            }
            if let attributes = node.attributes {
                views.attributes[path] = attributes
            }
        }
        self.walk(durable: true) { path, node in
            switch node.kind {
            case .file:
                views.durableFiles[path] = node.durableData
            case .directory:
                views.durableDirectories.insert(path)
            case .symbolicLink:
                views.durableSymbolicLinks[path] = node.target
            case .other:
                break
            }
        }
        return views
    }

    /// Visits every path below the root (not the root itself), in sorted order, never looping on a cycle.
    private func walk(durable: Bool, _ visit: (String, FSNode) -> Void) {
        var stack: [(path: [String], id: UInt64, ancestors: Set<UInt64>)] = [([], FSGraph.rootID, [FSGraph.rootID])]
        while let (path, id, ancestors) = stack.popLast() {
            guard let directory = self.nodes[id] else {
                continue
            }
            let listing = durable ? directory.durableEntries : directory.entries
            for name in listing.keys.sorted().reversed() {
                guard let child = listing[name], let node = self.nodes[child], !ancestors.contains(child) else {
                    continue
                }
                let childPath = path + [name]
                visit(FSGraph.path(childPath), node)
                if node.kind == .directory {
                    stack.append((childPath, child, ancestors.union([child])))
                }
            }
        }
    }

    // MARK: Crashes

    /// The disk a crash in `mode` leaves behind (store.md §3.4). A process kill keeps everything, including the
    /// current/durable split, so a power loss in the next lifetime can still revert un-synced state (store-1 S1-01);
    /// a power loss rebuilds the namespace from what was synced and leaves a fully durable disk.
    func surviving(_ mode: CrashMode) -> FSGraph {
        var graph = self
        switch mode {
        case .processKill, .processKillTornWrite:
            break
        case .powerLossDropUnsynced:
            for (id, node) in self.nodes {
                var reverted = node
                reverted.entries = node.durableEntries
                reverted.data = node.durableData
                graph.nodes[id] = reverted
            }
        case .powerLossKeepMetadata:
            for (id, node) in self.nodes {
                var reverted = node
                reverted.durableEntries = node.entries
                reverted.data = node.durableData
                graph.nodes[id] = reverted
            }
        }
        graph.collectGarbage()
        graph.recountLinks()
        return graph
    }
}

/// The observable state of a disk: what `DiskImage` stores in its fields and compares.
struct DiskViews: Sendable, Hashable {
    /// Current files.
    var files: [String: [UInt8]] = [:]
    /// Current directories.
    var directories: Set<String> = []
    /// Current symbolic links.
    var symbolicLinks: [String: String] = [:]
    /// Durable files with their durable bytes.
    var durableFiles: [String: [UInt8]] = [:]
    /// Durable directories.
    var durableDirectories: Set<String> = []
    /// Durable symbolic links.
    var durableSymbolicLinks: [String: String] = [:]
    /// Attributes of current items.
    var attributes: [String: StoreAttributes] = [:]
}
