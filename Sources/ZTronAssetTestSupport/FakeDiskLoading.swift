import Foundation
import ZTronAssetModel

/// Loading a `DiskImage` into the inode graph a `FakeFileSystem` lifetime starts on (H-1).
///
/// A disk taken from a fake carries its exact graph. When a test edited the disk's views in between (seeding, an OS
/// purge, a corrupted file), the edit is applied to that graph path by path, so every path the edit did not touch
/// keeps the state the views cannot show: the synced listing of a directory only current names reach, a file under
/// two names, synced bytes behind a renamed name. Only an edit the graph cannot take path by path (for example new
/// content for one of a file's two names), or a disk built by hand, is rebuilt from the views alone.
extension FSGraph {
    /// The volume a lifetime starts on: the carried graph, with any edit of the views applied to it; otherwise one
    /// rebuilt from the views (`rebuild`). Items an edit or a rebuild creates are modified at `now`.
    static func load(_ image: DiskImage, now: Date) -> FSGraph {
        guard let graph = image.graph else {
            return FSGraph.rebuild(image, hints: nil, now: now)
        }
        let target = image.views
        let shown = graph.views()
        if shown == target {
            return graph
        }
        if let edited = graph.applying(target, over: shown, now: now) {
            return edited
        }
        return FSGraph.rebuild(image, hints: graph, now: now)
    }

    /// This graph with the difference between `shown` (its own views) and `target` applied: removed names are
    /// unlinked, a file whose content changed is rewritten in place (it keeps its identity and its synced bytes),
    /// new items are created (with their missing parents), changed synced bytes are set on the inode the durable
    /// path names, and attributes follow the edit. `nil` when the result does not show exactly `target`.
    func applying(_ target: DiskViews, over shown: DiskViews, now: Date) -> FSGraph? {
        var graph = self
        graph.removeCurrent(shown: shown, target: target)
        graph.addCurrent(shown: shown, target: target, now: now)
        graph.removeDurable(shown: shown, target: target)
        graph.addDurable(shown: shown, target: target, now: now)
        for path in Set(shown.attributes.keys).union(target.attributes.keys) where shown.attributes[path] != target.attributes[path] {
            if let id = graph.physicalNode(FSGraph.components(of: path), durable: false) {
                graph.nodes[id]?.attributes = target.attributes[path]
            }
        }
        graph.collectGarbage()
        graph.recountLinks()
        return graph.views() == target ? graph : nil
    }

    /// Unlinks the current names the edit removed (or gave another kind or link target). A directory the edit no
    /// longer lists stays when a path the edit keeps lies below it (parents are implied).
    private mutating func removeCurrent(shown: DiskViews, target: DiskViews) {
        let implied = FSGraph.ancestors(of: Set(target.files.keys).union(target.directories).union(target.symbolicLinks.keys))
        var removed = shown.files.keys.filter { target.files[$0] == nil }
        removed += shown.symbolicLinks.keys.filter { target.symbolicLinks[$0] != shown.symbolicLinks[$0] }
        removed += shown.directories.filter { !target.directories.contains($0) && !implied.contains($0) }
        for path in removed.sorted() {
            let components = FSGraph.components(of: path)
            if let name = components.last, let parent = self.physicalNode(Array(components.dropLast()), durable: false) {
                self.unlink(name, in: parent)
            }
        }
    }

    /// Creates the current items the edit added and rewrites, in place, the files whose content it changed.
    private mutating func addCurrent(shown: DiskViews, target: DiskViews, now: Date) {
        for path in target.directories.sorted() where !shown.directories.contains(path) {
            _ = self.ensureDirectory(FSGraph.components(of: path), now: now)
        }
        for path in target.files.keys.sorted() {
            let components = FSGraph.components(of: path)
            guard let bytes = target.files[path], shown.files[path] != bytes, let name = components.last else {
                continue
            }
            let parent = self.ensureDirectory(Array(components.dropLast()), now: now)
            if let existing = self.nodes[parent]?.entries[name] {
                guard self.nodes[existing]?.kind == .file else {
                    continue  // another kind is still there: the final check sends the edit to `rebuild`
                }
                self.nodes[existing]?.data = bytes
                self.nodes[existing]?.modifiedAt = now
            } else {
                self.link(self.allocate(FSNode(kind: .file, data: bytes, modifiedAt: now)), as: name, in: parent)
            }
        }
        for path in target.symbolicLinks.keys.sorted() {
            let components = FSGraph.components(of: path)
            guard let destination = target.symbolicLinks[path], shown.symbolicLinks[path] != destination, let name = components.last else {
                continue
            }
            let parent = self.ensureDirectory(Array(components.dropLast()), now: now)
            if self.nodes[parent]?.entries[name] == nil {
                self.link(self.allocate(FSNode(kind: .symbolicLink, target: destination, modifiedAt: now)), as: name, in: parent)
            }
        }
    }

    /// Drops the synced names the edit removed (or gave another link target) from their synced listings.
    private mutating func removeDurable(shown: DiskViews, target: DiskViews) {
        let implied = FSGraph.ancestors(
            of: Set(target.durableFiles.keys).union(target.durableDirectories).union(target.durableSymbolicLinks.keys)
        )
        var removed = shown.durableFiles.keys.filter { target.durableFiles[$0] == nil }
        removed += shown.durableSymbolicLinks.keys.filter { target.durableSymbolicLinks[$0] != shown.durableSymbolicLinks[$0] }
        removed += shown.durableDirectories.filter { !target.durableDirectories.contains($0) && !implied.contains($0) }
        for path in removed.sorted() {
            let components = FSGraph.components(of: path)
            if let name = components.last, let parent = self.physicalNode(Array(components.dropLast()), durable: true) {
                self.nodes[parent]?.durableEntries.removeValue(forKey: name)
            }
        }
    }

    /// Adds the synced names the edit added (the current item at the same place when it matches, else an item only a
    /// power loss brings back) and sets the synced bytes it changed.
    private mutating func addDurable(shown: DiskViews, target: DiskViews, now: Date) {
        for path in target.durableDirectories.sorted() where !shown.durableDirectories.contains(path) {
            _ = self.ensureDurableDirectory(FSGraph.components(of: path), now: now)
        }
        for path in target.durableFiles.keys.sorted() {
            let components = FSGraph.components(of: path)
            guard let bytes = target.durableFiles[path], shown.durableFiles[path] != bytes, let name = components.last else {
                continue
            }
            let parent = self.ensureDurableDirectory(Array(components.dropLast()), now: now)
            if let existing = self.nodes[parent]?.durableEntries[name] {
                self.nodes[existing]?.durableData = bytes
            } else if let current = self.nodes[parent]?.entries[name], self.nodes[current]?.kind == .file {
                self.nodes[current]?.durableData = bytes
                self.nodes[parent]?.durableEntries[name] = current
            } else {
                let ghost = self.allocate(FSNode(kind: .file, data: bytes, durableData: bytes, modifiedAt: now))
                self.nodes[parent]?.durableEntries[name] = ghost
            }
        }
        for path in target.durableSymbolicLinks.keys.sorted() {
            let components = FSGraph.components(of: path)
            guard let destination = target.durableSymbolicLinks[path], shown.durableSymbolicLinks[path] != destination,
                let name = components.last
            else {
                continue
            }
            let parent = self.ensureDurableDirectory(Array(components.dropLast()), now: now)
            if let current = self.nodes[parent]?.entries[name], self.nodes[current]?.kind == .symbolicLink,
                self.nodes[current]?.target == destination
            {
                self.nodes[parent]?.durableEntries[name] = current
            } else {
                let ghost = self.allocate(FSNode(kind: .symbolicLink, target: destination, modifiedAt: now))
                self.nodes[parent]?.durableEntries[name] = ghost
            }
        }
    }

    /// Every proper ancestor of `paths` below the root.
    private static func ancestors(of paths: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for path in paths {
            var components = Array(FSGraph.components(of: path).dropLast())
            while !components.isEmpty, result.insert(FSGraph.path(components)).inserted {
                components.removeLast()
            }
        }
        return result
    }

    /// Rebuilds a graph from a disk's views: a durable path that equals a current path is the same file (its synced
    /// bytes are `durableFiles[path]`); a current file without a durable path keeps the synced bytes and the
    /// modification time the old graph (`hints`) had at that path when its content is unchanged, and has none
    /// otherwise; every other durable path is a file only a power loss brings back.
    static func rebuild(_ image: DiskImage, hints: FSGraph?, now: Date) -> FSGraph {
        var graph = FSGraph(rootModifiedAt: now)
        for path in image.directories.sorted() {
            _ = graph.ensureDirectory(FSGraph.components(of: path), now: now)
        }
        for path in image.files.keys.sorted() {
            let components = FSGraph.components(of: path)
            guard let name = components.last, let bytes = image.files[path] else {
                continue
            }
            let parent = graph.ensureDirectory(Array(components.dropLast()), now: now)
            guard graph.nodes[parent]?.entries[name] == nil else {
                continue
            }
            var node = FSNode(kind: .file, data: bytes, modifiedAt: now)
            if let id = hints?.physicalNode(components, durable: false), let hint = hints?.nodes[id], hint.kind == .file, hint.data == bytes {
                node.durableData = hint.durableData
                node.modifiedAt = hint.modifiedAt
            }
            let file = graph.allocate(node)
            graph.link(file, as: name, in: parent)
        }
        for path in image.symbolicLinks.keys.sorted() {
            let components = FSGraph.components(of: path)
            guard let name = components.last, let target = image.symbolicLinks[path] else {
                continue
            }
            let parent = graph.ensureDirectory(Array(components.dropLast()), now: now)
            guard graph.nodes[parent]?.entries[name] == nil else {
                continue
            }
            let link = graph.allocate(FSNode(kind: .symbolicLink, target: target, modifiedAt: now))
            graph.link(link, as: name, in: parent)
        }
        for path in image.durableDirectories.sorted() {
            _ = graph.ensureDurableDirectory(FSGraph.components(of: path), now: now)
        }
        for path in image.durableFiles.keys.sorted() {
            let components = FSGraph.components(of: path)
            guard let name = components.last, let bytes = image.durableFiles[path] else {
                continue
            }
            let parent = graph.ensureDurableDirectory(Array(components.dropLast()), now: now)
            guard graph.nodes[parent]?.durableEntries[name] == nil else {
                continue
            }
            if let current = graph.nodes[parent]?.entries[name], graph.nodes[current]?.kind == .file {
                graph.nodes[current]?.durableData = bytes
                graph.nodes[parent]?.durableEntries[name] = current
            } else {
                let ghost = graph.allocate(FSNode(kind: .file, data: bytes, durableData: bytes, modifiedAt: now))
                graph.nodes[parent]?.durableEntries[name] = ghost
            }
        }
        for path in image.durableSymbolicLinks.keys.sorted() {
            let components = FSGraph.components(of: path)
            guard let name = components.last, let target = image.durableSymbolicLinks[path] else {
                continue
            }
            let parent = graph.ensureDurableDirectory(Array(components.dropLast()), now: now)
            guard graph.nodes[parent]?.durableEntries[name] == nil else {
                continue
            }
            if let current = graph.nodes[parent]?.entries[name], graph.nodes[current]?.kind == .symbolicLink,
                graph.nodes[current]?.target == target
            {
                graph.nodes[parent]?.durableEntries[name] = current
            } else {
                let ghost = graph.allocate(FSNode(kind: .symbolicLink, target: target, modifiedAt: now))
                graph.nodes[parent]?.durableEntries[name] = ghost
            }
        }
        for (path, attributes) in image.attributes {
            if let id = graph.physicalNode(FSGraph.components(of: path), durable: false) {
                graph.nodes[id]?.attributes = attributes
            }
        }
        graph.recountLinks()
        return graph
    }

    /// The inode at `components`, walking current (or synced) listings through directories only, never links.
    func physicalNode(_ components: [String], durable: Bool) -> UInt64? {
        var current = FSGraph.rootID
        for name in components {
            guard let directory = self.nodes[current], directory.kind == .directory,
                let child = (durable ? directory.durableEntries : directory.entries)[name]
            else {
                return nil
            }
            current = child
        }
        return current
    }

    /// Creates the current directories along `components` that are missing (no links followed).
    mutating func ensureDirectory(_ components: [String], now: Date) -> UInt64 {
        var current = FSGraph.rootID
        for name in components {
            if let child = self.nodes[current]?.entries[name], self.nodes[child]?.kind == .directory {
                current = child
                continue
            }
            let child = self.allocate(FSNode(kind: .directory, modifiedAt: now))
            self.nodes[current]?.entries[name] = child
            current = child
        }
        return current
    }

    /// Makes the durable directories along `components` exist: the current directory at the same path when there
    /// is one, else a directory only a power loss brings back.
    mutating func ensureDurableDirectory(_ components: [String], now: Date) -> UInt64 {
        var current = FSGraph.rootID
        for name in components {
            if let child = self.nodes[current]?.durableEntries[name], self.nodes[child]?.kind == .directory {
                current = child
                continue
            }
            let child: UInt64
            if let existing = self.nodes[current]?.entries[name], self.nodes[existing]?.kind == .directory {
                child = existing
            } else {
                child = self.allocate(FSNode(kind: .directory, modifiedAt: now))
            }
            self.nodes[current]?.durableEntries[name] = child
            current = child
        }
        return current
    }
}
