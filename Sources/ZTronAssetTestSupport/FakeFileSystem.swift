import CryptoKit
import Foundation
import Synchronization
import ZTronAssetModel

/// Every operation of the `FileSystem` seam, for logs, faults and crash enumeration (R-STO-5, R-STO-6).
public enum FSOpKind: String, Sendable, Hashable, CaseIterable {
    /// Query.
    case standardDirectory
    /// Query.
    case itemInfo
    /// Query.
    case contentsOfDirectory
    /// Query.
    case read
    /// Query.
    case availableCapacity
    /// Query.
    case storeAttributes
    /// Mutation (crash boundary).
    case createDirectory
    /// Mutation (crash boundary).
    case write
    /// Mutation (crash boundary).
    case synchronizeFile
    /// Mutation (crash boundary).
    case synchronizeDirectory
    /// Mutation (crash boundary).
    case rename
    /// Mutation (crash boundary).
    case removeItem
    /// Mutation (crash boundary).
    case applyStoreAttributes
    /// Mutation (crash boundary).
    case acquireExclusiveLock
    /// Not a boundary: process death releases locks anyway.
    case releaseLock

    /// Whether the operation is a crash boundary.
    public var isMutation: Bool {
        switch self {
        case .createDirectory, .write, .synchronizeFile, .synchronizeDirectory, .rename, .removeItem,
            .applyStoreAttributes, .acquireExclusiveLock:
            return true
        case .standardDirectory, .itemInfo, .contentsOfDirectory, .read, .availableCapacity, .storeAttributes,
            .releaseLock:
            return false
        }
    }
}

/// One recorded call: the op log feeds the `OrderingAuditor` (I-3) and R-STO-7's main-thread proof.
public struct FSOpRecord: Sendable, Hashable {
    /// Position in the log.
    public var index: Int
    /// The operation.
    public var kind: FSOpKind
    /// The primary URL.
    public var url: URL
    /// The rename destination, when any.
    public var destination: URL?
    /// Whether the call ran on the main thread (R-STO-7, P-8).
    public var isMainThread: Bool
    /// The injected or modelled failure, when any.
    public var failure: FileSystemError?

    /// Creates a record.
    public init(index: Int, kind: FSOpKind, url: URL, destination: URL?, isMainThread: Bool, failure: FileSystemError?) {
        self.index = index
        self.kind = kind
        self.url = url
        self.destination = destination
        self.isMainThread = isMainThread
        self.failure = failure
    }
}

/// What survives a crash (store.md §3.4, store-1 S1-01).
public enum CrashMode: String, Sendable, Hashable, CaseIterable {
    /// Every applied mutation persists, **as volatile state**: the surviving disk keeps the current/durable split,
    /// so a later power loss in the next lifetime can still revert it (store-1 S1-01).
    case processKill
    /// As `processKill`, and a crashing `write` lands half its bytes.
    case processKillTornWrite
    /// Each directory reverts to its last synced listing; each file's data to its last synced content.
    case powerLossDropUnsynced
    /// The namespace persists as applied; file data reverts to its last synced content.
    case powerLossKeepMetadata
}

/// When a fault rule fires.
public enum Occurrence: Sendable, Hashable {
    /// On the n-th matching call (1-based).
    case nth(Int)
    /// On every matching call.
    case every
    /// Once the matching file has received this many bytes (a short write).
    case afterBytes(Int64)
}

/// Which URLs a fault rule matches.
public struct URLMatcher: Sendable, Hashable {
    /// The last path component must have this suffix (for example `".tmp"`, `".part"`).
    public var lastComponentSuffix: String?
    /// The path must contain this text (for example `"/blobs/"`).
    public var pathContains: String?

    /// Creates a matcher; `nil` fields match anything.
    public init(lastComponentSuffix: String? = nil, pathContains: String? = nil) {
        self.lastComponentSuffix = lastComponentSuffix
        self.pathContains = pathContains
    }

    /// Whether `url` matches.
    public func matches(_ url: URL) -> Bool {
        if let suffix = self.lastComponentSuffix, !url.lastPathComponent.hasSuffix(suffix) {
            return false
        }
        if let text = self.pathContains, !url.path.contains(text) {
            return false
        }
        return true
    }
}

/// One injected fault (R-STO-6): ENOSPC, EIO, EACCES, rename failure, partial write.
public struct FaultRule: Sendable, Hashable {
    /// The operation.
    public var operation: FSOpKind
    /// Which URLs.
    public var matching: URLMatcher
    /// When.
    public var occurrence: Occurrence
    /// The error thrown.
    public var error: FileSystemError
    /// For `write`: how many bytes land before the error (`nil`: none). The error decides where the write fails. An
    /// error `write(2)` itself returns (`.noSpace`, `.io`, `.other` with EFBIG, EINTR, EDQUOT or EAGAIN) fails after
    /// `open(2)` succeeded: the file exists afterwards, a `.truncate` write has emptied it, and these bytes (or what
    /// an `.afterBytes` threshold lets through) have landed. Any other error (`.permissionDenied`, `.notFound`,
    /// `.other(EISDIR)`, …) fails `open(2)` itself and changes nothing, whatever this says.
    public var partialBytes: Int?

    /// Creates a rule.
    public init(operation: FSOpKind, matching: URLMatcher = URLMatcher(), occurrence: Occurrence, error: FileSystemError, partialBytes: Int? = nil) {
        self.operation = operation
        self.matching = matching
        self.occurrence = occurrence
        self.error = error
        self.partialBytes = partialBytes
    }
}

/// A frozen disk: what survives a crash, and what seeds the next lifetime's fake. Equality and `digest` let
/// R-SYN-11 tests prove "byte-identical, zero side effects".
///
/// The four package fields are the observable state and are authoritative: a test may read them, or edit them to
/// seed a disk, corrupt a file or simulate an OS purge between launches (a file whose parent directory is not
/// listed gets its parents implicitly). `files` and `directories` are the current namespace; `durableFiles` and
/// `durableDirectories` are what a power loss that drops un-synced state would leave (names reached through synced
/// listings, with each file's synced bytes). A disk taken from a `FakeFileSystem` also carries the exact inode
/// graph behind those views (which name and which synced bytes belong to the same file across renames, and the
/// synced listing of a directory only current names reach), so a process kill followed by a power loss in the next
/// lifetime is modelled exactly (store-1 S1-01).
///
/// An edit is applied to that graph path by path when the next fake loads the disk: a removed name is unlinked, a
/// file whose content changed is rewritten in place (same identity, same synced bytes), new items are new, and
/// every path the edit did not touch keeps its exact state. Only an edit the graph cannot take that way (new content
/// for one of a file's two names) rebuilds the disk from the fields, "same path, same file". The two namespaces are
/// edited separately: removing a path from `files` alone is a **volatile** removal that a later power loss undoes,
/// because `durableFiles` still names it. An OS purge between launches is durable, so it removes the path from both
/// namespaces: use `purge(_:)`. Equality compares the observable state only (namespaces, contents, symbolic links
/// and attributes), never inode numbers.
public struct DiskImage: Sendable, Hashable {
    /// Regular files by path, current content.
    package var files: [String: [UInt8]]
    /// Directories by path.
    package var directories: Set<String>
    /// Durable (synced) content, kept across a process kill (store-1 S1-01).
    package var durableFiles: [String: [UInt8]]
    /// Durable directory listings.
    package var durableDirectories: Set<String>
    /// Current symbolic links (path → target), seeded through `FakeFileSystem.createSymbolicLink`.
    var symbolicLinks: [String: String]
    /// Durable symbolic links.
    var durableSymbolicLinks: [String: String]
    /// Attributes applied to current items, by path (R-STO-8).
    var attributes: [String: StoreAttributes]
    /// The exact inode graph the views were taken from, when the disk came from a fake.
    var graph: FSGraph?

    /// An empty disk.
    public init() {
        self.files = [:]
        self.directories = []
        self.durableFiles = [:]
        self.durableDirectories = []
        self.symbolicLinks = [:]
        self.durableSymbolicLinks = [:]
        self.attributes = [:]
        self.graph = nil
    }

    /// The disk a graph shows, carrying the graph.
    init(graph: FSGraph) {
        let views = graph.views()
        self.files = views.files
        self.directories = views.directories
        self.durableFiles = views.durableFiles
        self.durableDirectories = views.durableDirectories
        self.symbolicLinks = views.symbolicLinks
        self.durableSymbolicLinks = views.durableSymbolicLinks
        self.attributes = views.attributes
        self.graph = graph
    }

    /// The observable state, as stored.
    var views: DiskViews {
        DiskViews(
            files: self.files,
            directories: self.directories,
            symbolicLinks: self.symbolicLinks,
            durableFiles: self.durableFiles,
            durableDirectories: self.durableDirectories,
            durableSymbolicLinks: self.durableSymbolicLinks,
            attributes: self.attributes
        )
    }

    /// Every file and directory path of the current namespace, sorted. Symbolic links are not listed (`digest()`
    /// covers them; a test that seeds one reads it through the fake).
    public var paths: [String] {
        (Array(self.files.keys) + Array(self.directories)).sorted()
    }

    /// SHA-256 over sorted paths and contents of the current namespace (files, directories and symbolic links;
    /// durability and attributes are not content): equal digests mean byte-identical trees.
    public func digest() -> ContentHash {
        var hasher = SHA256()
        let paths = Set(self.files.keys).union(self.directories).union(self.symbolicLinks.keys).sorted()
        for path in paths {
            let tag: UInt8
            var payload: [UInt8] = []
            if let bytes = self.files[path] {
                tag = UInt8(ascii: "f")
                payload = bytes
            } else if let target = self.symbolicLinks[path] {
                tag = UInt8(ascii: "l")
                payload = Array(target.utf8)
            } else {
                tag = UInt8(ascii: "d")
            }
            var record: [UInt8] = [tag]
            record.append(contentsOf: path.utf8)
            record.append(0)
            var length = UInt64(payload.count)
            for _ in 0..<8 {
                record.append(UInt8(truncatingIfNeeded: length))
                length >>= 8
            }
            hasher.update(data: record)
            hasher.update(data: payload)
        }
        return ContentHash(digest: hasher.finalize())
    }

    /// Marks every current item durable, as if every file and every directory had been synced: a seeded disk
    /// (a legacy tree, a pre-existing store) then survives a power loss in its first lifetime. Keeps the inode
    /// graph and modification times when the disk came from a fake (an edit is applied first; items it creates are
    /// modified at the latest time the graph records).
    public mutating func makeDurable() {
        guard let carried = self.graph else {
            self.durableFiles = self.files
            self.durableDirectories = self.directories
            self.durableSymbolicLinks = self.symbolicLinks
            return
        }
        let latest = carried.nodes.values.map(\.modifiedAt).max() ?? Date(timeIntervalSince1970: 0)
        var graph = FSGraph.load(self, now: latest)
        for (id, node) in graph.nodes {
            var synced = node
            synced.durableEntries = node.entries
            synced.durableData = node.data
            graph.nodes[id] = synced
        }
        graph.collectGarbage()
        self = DiskImage(graph: graph)
    }

    /// Removes `path` and everything below it from both namespaces, with their attributes: what the OS does when it
    /// purges a cache between launches (R-CLN-7). Unlike a removal from `files` alone, a later power loss does not
    /// bring a purged item back. `"/"` purges everything.
    public mutating func purge(_ path: String) {
        let purged = FSGraph.path(FSGraph.components(of: path))
        let prefix = purged == "/" ? "/" : purged + "/"
        let isPurged = { (candidate: String) -> Bool in candidate == purged || candidate.hasPrefix(prefix) }
        self.files = self.files.filter { !isPurged($0.key) }
        self.directories = self.directories.filter { !isPurged($0) }
        self.symbolicLinks = self.symbolicLinks.filter { !isPurged($0.key) }
        self.durableFiles = self.durableFiles.filter { !isPurged($0.key) }
        self.durableDirectories = self.durableDirectories.filter { !isPurged($0) }
        self.durableSymbolicLinks = self.durableSymbolicLinks.filter { !isPurged($0.key) }
        self.attributes = self.attributes.filter { !isPurged($0.key) }
    }

    /// Equal observable state: namespaces, contents, durable views, symbolic links and attributes.
    public static func == (lhs: DiskImage, rhs: DiskImage) -> Bool {
        lhs.views == rhs.views
    }

    /// Hashes the observable state.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.views)
    }
}

/// Crash and capacity configuration of a `FakeFileSystem` lifetime.
public struct FakeFileSystemConfiguration: Sendable, Hashable {
    /// The index of the mutation that never happens (`nil`: no crash).
    public var crashBefore: Int?
    /// What survives.
    public var crashMode: CrashMode
    /// Free space reported for important usage.
    public var importantCapacity: Int64
    /// Free space reported for opportunistic usage.
    public var opportunisticCapacity: Int64
    /// The directory `standardDirectory` resolves under (a virtual path; nothing is written to the real disk).
    public var volumeRoot: URL

    /// Creates a configuration.
    public init(
        crashBefore: Int? = nil,
        crashMode: CrashMode = .processKill,
        importantCapacity: Int64 = 64 << 30,
        opportunisticCapacity: Int64 = 64 << 30,
        volumeRoot: URL = URL(fileURLWithPath: "/fake-volume", isDirectory: true)
    ) {
        self.crashBefore = crashBefore
        self.crashMode = crashMode
        self.importantCapacity = importantCapacity
        self.opportunisticCapacity = opportunisticCapacity
        self.volumeRoot = volumeRoot
    }
}

/// The in-memory file system with the crash and fault model of store.md §3.4 (R-STO-5, R-STO-6, R-STO-7,
/// R-STO-8; WP-H).
///
/// Every call runs under one `Mutex` in program order, so with `InlineBlockingExecutor` a scenario's op sequence is
/// identical on every run, and "crash before mutation k" is reproducible from k (store-2 S2-08). Directories are
/// modelled independently (pessimistic). After a crash every call throws `.io` and `survivingDisk()` yields the
/// post-crash disk. Gated for `Mutex` (ADR-014): tests annotate each `@Test` with `@available(macOS 15.0, *)`.
///
/// Model, precisely (store.md §3.4 as amended by store-1 S1-01): an inode table where each file has current and
/// synced bytes and each directory a current and a synced listing. `synchronizeFile` makes a file's bytes durable
/// (a directory's listing, when given a directory), `synchronizeDirectory` a directory's listing; `.barrier` and
/// `.full` both mark the synced item durable at the call (a barrier that loses everything after it equals a crash
/// before it, which the enumeration covers). A new file starts with empty synced bytes, a new directory with an
/// empty synced listing. Mutations are numbered from 0 in call order, failed ones included; `crashBefore: k` makes
/// mutation k (and everything after it) never happen. Free space is the configured capacity minus the net bytes the
/// lifetime added, and a write that does not fit lands what fits and throws `.noSpace`. `mtime` comes from the
/// injected `TimeSource`; listings come in descending name order (deterministic, and never the ascending order a
/// caller might wrongly rely on: the seam promises no order, so callers sort). Everything is held in memory, file
/// bytes and the op log included, so no memory budget (P-6, P-7) is measured over this fake.
@available(macOS 15.0, iOS 18.0, *)
public final class FakeFileSystem: FileSystem {
    private let state: Mutex<FakeFileSystemState>
    /// The lifetime's configuration.
    public let configuration: FakeFileSystemConfiguration
    /// Supplies `mtime` (no real clock).
    public let time: any TimeSource

    /// Starts a lifetime on `disk`.
    public init(disk: DiskImage = DiskImage(), time: any TimeSource, configuration: FakeFileSystemConfiguration = FakeFileSystemConfiguration()) {
        var graph = FSGraph.load(disk, now: time.now())
        graph.ensureStandardDirectories(volumeRoot: configuration.volumeRoot, now: time.now())
        self.state = Mutex(FakeFileSystemState(graph: graph, baselineUsage: graph.currentUsage()))
        self.time = time
        self.configuration = configuration
    }

    /// The op log so far.
    public var operations: [FSOpRecord] {
        self.state.withLock { $0.log }
    }

    /// Mutations performed so far (the crash-point count of a clean run).
    public var mutationCount: Int {
        self.state.withLock { $0.mutations }
    }

    /// Whether the configured crash happened.
    public var crashed: Bool {
        self.state.withLock { $0.crashImage != nil }
    }

    /// The disk after the crash (or now), per `configuration.crashMode`; seeds the next lifetime.
    public func survivingDisk() -> DiskImage {
        self.state.withLock { state in
            if let image = state.crashImage {
                return image
            }
            return DiskImage(graph: state.graph.surviving(self.configuration.crashMode))
        }
    }

    /// Adds a fault rule.
    public func addFault(_ rule: FaultRule) {
        self.state.withLock { $0.faults.append(FaultCursor(rule: rule)) }
    }

    /// Calls made on the main thread (R-STO-7, P-8).
    public var mainThreadCalls: Int {
        self.state.withLock { state in
            state.log.reduce(0) { $0 + ($1.isMainThread ? 1 : 0) }
        }
    }

    /// Attributes applied, by path (R-STO-8).
    public var appliedAttributes: [String: StoreAttributes] {
        self.state.withLock { $0.graph.views().attributes }
    }

    /// Seeds a symbolic link at `url` pointing to `destination` (verbatim, relative or absolute), as if it had
    /// been on the volume all along: a test fixture for R-SEC-2 and the conformance contract, **not** part of the
    /// seam (no op is logged, no crash boundary is consumed). The link is created durable; its parent must exist.
    public func createSymbolicLink(at url: URL, destination: String) throws(FileSystemError) {
        let now = self.time.now()
        try self.state.withLock { state throws(FileSystemError) -> Void in
            let location = try state.graph.locate(try FSGraph.components(of: url), followFinal: false)
            guard let parent = location.parent, !location.name.isEmpty else {
                throw .other(errno: EINVAL)
            }
            guard location.node == nil else {
                throw .alreadyExists
            }
            let link = state.graph.allocate(FSNode(kind: .symbolicLink, target: destination, modifiedAt: now))
            state.graph.link(link, as: location.name, in: parent)
            state.graph.nodes[parent]?.durableEntries[location.name] = link
        }
    }

    // MARK: FileSystem — queries

    /// Resolves under `configuration.volumeRoot`.
    public func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL {
        let url = FSGraph.standardURL(directory, volumeRoot: self.configuration.volumeRoot)
        return try self.perform(.standardDirectory, url) { (_: inout FakeFileSystemState) throws(FileSystemError) -> URL in
            url
        }
    }

    /// Modelled `lstat`.
    public func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo? {
        try self.perform(.itemInfo, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> FileItemInfo? in
            let location: FSLocation
            do throws(FileSystemError) {
                location = try state.graph.locate(try FSGraph.components(of: url), followFinal: false)
            } catch .notFound {
                return nil
            }
            guard let id = location.node, let node = state.graph.nodes[id] else {
                return nil
            }
            return FakeFileSystem.info(name: location.name.isEmpty ? "/" : location.name, id: id, node: node)
        }
    }

    /// Modelled listing, in **descending** name order: deterministic (crash enumeration repeats), yet never the
    /// ascending order a caller might silently rely on, since the live order is arbitrary and the seam promises none.
    public func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo] {
        try self.perform(.contentsOfDirectory, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> [FileItemInfo] in
            let directory = try state.existing(url, followFinal: true)
            guard let node = state.graph.nodes[directory], node.kind == .directory else {
                throw .other(errno: ENOTDIR)
            }
            return node.entries.keys.sorted(by: >).compactMap { name in
                guard let child = node.entries[name], let item = state.graph.nodes[child] else {
                    return nil
                }
                return FakeFileSystem.info(name: name, id: child, node: item)
            }
        }
    }

    /// Modelled read.
    public func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        try self.perform(.read, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Data in
            guard offset >= 0, maxLength >= 0, maxLength <= FakeFileSystem.maxReadLength else {
                throw .other(errno: EINVAL)
            }
            let id = try state.existing(url, followFinal: true)
            guard let node = state.graph.nodes[id], node.kind == .file else {
                throw .other(errno: EISDIR)
            }
            guard offset < Int64(node.data.count) else {
                return Data()
            }
            let start = Int(offset)
            let end = min(node.data.count, start + maxLength)
            return Data(node.data[start..<end])
        }
    }

    /// Scripted capacity.
    public func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        try self.perform(.availableCapacity, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Int64 in
            _ = try state.existing(url, followFinal: true)
            return max(0, self.available(purpose, in: state))
        }
    }

    /// Recorded attributes.
    public func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        try self.perform(.storeAttributes, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> StoreAttributes in
            let id = try state.existing(url, followFinal: true)
            return state.graph.nodes[id]?.attributes ?? StoreAttributes(excludedFromBackup: false, protection: nil)
        }
    }

    // MARK: FileSystem — mutations

    /// Modelled mkdir (crash boundary).
    public func createDirectory(at url: URL) throws(FileSystemError) {
        let now = self.time.now()
        try self.perform(.createDirectory, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Void in
            let location = try state.graph.locate(try FSGraph.components(of: url), followFinal: false)
            guard location.node == nil, let parent = location.parent else {
                return  // EEXIST counts as success (`mkdir`), whatever kind of item is there.
            }
            let directory = state.graph.allocate(FSNode(kind: .directory, modifiedAt: now))
            state.graph.link(directory, as: location.name, in: parent)
        }
    }

    /// Modelled write (crash boundary; torn and short writes).
    public func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        let now = self.time.now()
        let bytes = [UInt8](data)
        try self.perform(.write, url, offered: bytes.count, torn: { state in
            try? self.apply(write: bytes.prefix(bytes.count / 2), to: url, mode: mode, now: now, in: &state)
        }, partial: { state, landed in
            try? self.apply(write: bytes.prefix(landed), to: url, mode: mode, now: now, in: &state)
        }) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Void in
            try self.apply(write: bytes[...], to: url, mode: mode, now: now, in: &state)
        }
    }

    /// Marks file data durable (crash boundary).
    public func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.perform(.synchronizeFile, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Void in
            let id = try state.existing(url, followFinal: true)
            state.graph.makeDurable(id)
        }
    }

    /// Marks a directory listing durable (crash boundary).
    public func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.perform(.synchronizeDirectory, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Void in
            let id = try state.existing(url, followFinal: true)
            guard state.graph.nodes[id]?.kind == .directory else {
                throw .other(errno: ENOTDIR)
            }
            state.graph.makeDurable(id)
        }
    }

    /// Modelled rename (crash boundary).
    public func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        try self.perform(.rename, source, destination: destination) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Void in
            try state.rename(from: source, to: destination, mode: mode)
        }
    }

    /// Modelled unlink (crash boundary).
    public func removeItem(at url: URL) throws(FileSystemError) {
        try self.perform(.removeItem, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Void in
            let location: FSLocation
            do throws(FileSystemError) {
                location = try state.graph.locate(try FSGraph.components(of: url), followFinal: false)
            } catch .notFound {
                return  // ENOENT counts as success: sweeps are idempotent (R-CLN-12).
            }
            guard let id = location.node else {
                return
            }
            guard let parent = location.parent, let node = state.graph.nodes[id] else {
                throw .permissionDenied  // the volume root
            }
            if node.kind == .directory, !node.entries.isEmpty {
                throw .notEmpty
            }
            state.usage -= state.graph.unlink(location.name, in: parent)
        }
    }

    /// Records attributes (crash boundary).
    public func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        try self.perform(.applyStoreAttributes, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> Void in
            let id = try state.existing(url, followFinal: true)
            state.graph.nodes[id]?.attributes = attributes
        }
    }

    /// Modelled `O_EXLOCK`: `.wouldBlock` while any other holder exists (crash boundary).
    public func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        let now = self.time.now()
        return try self.perform(.acquireExclusiveLock, url) { (state: inout FakeFileSystemState) throws(FileSystemError) -> FileLockToken in
            let location = try state.graph.locate(try FSGraph.components(of: url), followFinal: true)
            let id: UInt64
            if let existing = location.node {
                guard state.graph.nodes[existing]?.kind == .file else {
                    throw .other(errno: EISDIR)
                }
                id = existing
            } else {
                guard let parent = location.parent else {
                    throw .other(errno: EISDIR)
                }
                id = state.graph.allocate(FSNode(kind: .file, modifiedAt: now))
                state.graph.link(id, as: location.name, in: parent)
            }
            guard state.locks[id] == nil else {
                throw .wouldBlock
            }
            state.nextLockHandle += 1
            state.locks[id] = state.nextLockHandle
            state.lockURLs[state.nextLockHandle] = url
            return FileLockToken(identity: FileIdentity(device: FSGraph.device, inode: id), handle: state.nextLockHandle)
        }
    }

    /// Releases a modelled lock; logged against the lock file's URL (or `/` for a token this lifetime never issued).
    public func releaseLock(_ token: FileLockToken) {
        let isMain = Thread.isMainThread
        self.state.withLock { state in
            let url = state.lockURLs[token.handle] ?? URL(fileURLWithPath: "/", isDirectory: true)
            state.log.append(FSOpRecord(index: state.log.count, kind: .releaseLock, url: url, destination: nil, isMainThread: isMain, failure: nil))
            if state.crashImage == nil, state.locks[token.identity.inode] == token.handle {
                state.locks.removeValue(forKey: token.identity.inode)
            }
        }
    }

    // MARK: Internals

    /// The largest read the seam allows (store.md §3.2: `maxLength ≤ 1 MiB` is a precondition).
    static let maxReadLength = 1 << 20

    /// The metadata a listing or `itemInfo` reports for an inode.
    private static func info(name: String, id: UInt64, node: FSNode) -> FileItemInfo {
        let size: Int64
        switch node.kind {
        case .file:
            size = Int64(node.data.count)
        case .symbolicLink:
            size = Int64(node.target.utf8.count)
        case .directory, .other:
            size = 0
        }
        return FileItemInfo(
            name: name,
            kind: node.kind,
            byteSize: size,
            modifiedAt: node.modifiedAt,
            identity: FileIdentity(device: FSGraph.device, inode: id)
        )
    }

    /// Free space for `purpose`: the configured figure minus the bytes this lifetime added (may be negative).
    private func available(_ purpose: CapacityPurpose, in state: FakeFileSystemState) -> Int64 {
        let configured: Int64
        switch purpose {
        case .important:
            configured = self.configuration.importantCapacity
        case .opportunistic:
            configured = self.configuration.opportunisticCapacity
        }
        return configured - (state.usage - state.baselineUsage)
    }

    /// Applies one write, creating the file when absent; a write that does not fit lands what fits and throws.
    private func apply(
        write bytes: ArraySlice<UInt8>,
        to url: URL,
        mode: WriteMode,
        now: Date,
        in state: inout FakeFileSystemState
    ) throws(FileSystemError) {
        let location = try state.graph.locate(try FSGraph.components(of: url), followFinal: true)
        let id: UInt64
        if let existing = location.node {
            id = existing
        } else {
            guard let parent = location.parent else {
                throw .other(errno: EISDIR)
            }
            id = state.graph.allocate(FSNode(kind: .file, modifiedAt: now))
            state.graph.link(id, as: location.name, in: parent)
        }
        // Read the kind and the size without binding the node: a second reference to its bytes would make the append
        // below copy the whole file (copy-on-write), so k appends would cost O(k·n) instead of O(bytes appended).
        guard state.graph.nodes[id]?.kind == .file else {
            throw .other(errno: EISDIR)
        }
        let previous = Int64(state.graph.nodes[id]?.data.count ?? 0)
        let target = mode == .truncate ? Int64(bytes.count) : previous + Int64(bytes.count)
        let room = self.available(.important, in: state) + previous
        let fits = target <= room
        let landed = fits ? bytes : bytes.prefix(Int(max(0, mode == .truncate ? room : room - previous)))
        if mode == .truncate {
            state.graph.nodes[id]?.data = Array(landed)
        } else {
            state.graph.nodes[id]?.data.append(contentsOf: landed)
        }
        state.graph.nodes[id]?.modifiedAt = now
        state.usage += Int64(state.graph.nodes[id]?.data.count ?? 0) - previous
        state.recordLanded(Int64(landed.count), at: url)
        guard fits else {
            throw .noSpace
        }
    }

    /// Whether an injected write error is one `write(2)` returns after `open(2)` succeeded (ENOSPC, EIO, EFBIG, EINTR,
    /// EDQUOT, EAGAIN), so the open's side effects and the rule's landed bytes apply. Every other error (EACCES/EPERM,
    /// ENOENT, EISDIR, ENOTDIR, …) is one `open(2)` returns, which leaves the file system untouched (store.md §3.4:
    /// EACCES before the first unlock mutates nothing).
    static func failsAfterOpen(_ error: FileSystemError) -> Bool {
        switch error {
        case .noSpace, .io:
            return true
        case .other(let code):
            return [EFBIG, EINTR, EDQUOT, EAGAIN].contains(code)
        case .permissionDenied, .notFound, .alreadyExists, .crossDevice, .wouldBlock, .notEmpty, .notSupported:
            return false
        }
    }

    /// Runs one call: records it, enforces the crash point and the fault rules, then performs `body`.
    private func perform<T: Sendable>(
        _ kind: FSOpKind,
        _ url: URL,
        destination: URL? = nil,
        offered: Int = 0,
        torn: (inout FakeFileSystemState) -> Void = { _ in },
        partial: (inout FakeFileSystemState, Int) -> Void = { _, _ in },
        _ body: (inout FakeFileSystemState) throws(FileSystemError) -> T
    ) throws(FileSystemError) -> T {
        let isMain = Thread.isMainThread
        let outcome: Result<T, FileSystemError> = self.state.withLock { state in
            let result: Result<T, FileSystemError>
            do throws(FileSystemError) {
                result = .success(try self.execute(kind, url, offered: offered, torn: torn, partial: partial, body, in: &state))
            } catch {
                result = .failure(error)
            }
            let failure: FileSystemError?
            if case .failure(let error) = result {
                failure = error
            } else {
                failure = nil
            }
            state.log.append(
                FSOpRecord(index: state.log.count, kind: kind, url: url, destination: destination, isMainThread: isMain, failure: failure)
            )
            return result
        }
        return try outcome.get()
    }

    /// The crash point, then the faults, then the operation itself.
    private func execute<T: Sendable>(
        _ kind: FSOpKind,
        _ url: URL,
        offered: Int,
        torn: (inout FakeFileSystemState) -> Void,
        partial: (inout FakeFileSystemState, Int) -> Void,
        _ body: (inout FakeFileSystemState) throws(FileSystemError) -> T,
        in state: inout FakeFileSystemState
    ) throws(FileSystemError) -> T {
        guard state.crashImage == nil else {
            throw .io
        }
        if kind.isMutation {
            if self.configuration.crashBefore == state.mutations {
                if self.configuration.crashMode == .processKillTornWrite {
                    torn(&state)
                }
                // Lock state needs no clearing: it dies with this lifetime, whose every later call throws `.io`
                // (`releaseLock` included), and the next lifetime starts with no holder.
                state.crashImage = DiskImage(graph: state.graph.surviving(self.configuration.crashMode))
                throw .io
            }
            state.mutations += 1
        }
        if let fired = state.fireFault(kind, url, offered: offered) {
            if kind == .write, FakeFileSystem.failsAfterOpen(fired.error) {
                partial(&state, fired.landed ?? 0)  // write(2) failed after open(2): created, and truncated for .truncate
            }
            throw fired.error  // any other error failed open(2) itself: nothing changed
        }
        return try body(&state)
    }
}

/// Everything a `FakeFileSystem` lifetime mutates, under its one lock.
struct FakeFileSystemState: Sendable {
    /// The volume.
    var graph: FSGraph
    /// Bytes the current namespace holds at lifetime start (free space is measured against it).
    var baselineUsage: Int64
    /// Bytes the current namespace holds now.
    var usage: Int64
    /// Every call, in order.
    var log: [FSOpRecord] = []
    /// Mutation calls made so far (the next one's crash-point index).
    var mutations = 0
    /// The surviving disk, once the configured crash happened.
    var crashImage: DiskImage?
    /// Installed fault rules with their counters.
    var faults: [FaultCursor] = []
    /// Held locks: lock-file inode → handle.
    var locks: [UInt64: Int64] = [:]
    /// The last handle issued.
    var nextLockHandle: Int64 = 0
    /// The URL each handle was acquired at, so a release is logged against its lock file.
    var lockURLs: [Int64: URL] = [:]

    /// A fresh lifetime on `graph`.
    init(graph: FSGraph, baselineUsage: Int64) {
        self.graph = graph
        self.baselineUsage = baselineUsage
        self.usage = baselineUsage
    }

    /// The inode at an existing path; `.notFound` when absent.
    func existing(_ url: URL, followFinal: Bool) throws(FileSystemError) -> UInt64 {
        let location = try self.graph.locate(try FSGraph.components(of: url), followFinal: followFinal)
        guard let id = location.node else {
            throw .notFound
        }
        return id
    }

    /// `rename(2)` / `renamex_np(RENAME_EXCL)` in the current namespace (no directory sync implied).
    mutating func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        let from = try self.graph.locate(try FSGraph.components(of: source), followFinal: false)
        guard let moving = from.node else {
            throw .notFound
        }
        let to = try self.graph.locate(try FSGraph.components(of: destination), followFinal: false)
        guard let fromParent = from.parent, let toParent = to.parent else {
            throw .other(errno: EINVAL)  // renaming the volume root, or onto it
        }
        guard let movingNode = self.graph.nodes[moving] else {
            throw .notFound
        }
        if fromParent == toParent, from.name == to.name {
            return
        }
        if let replaced = to.node {
            guard mode == .replacing else {
                throw .alreadyExists
            }
            if replaced == moving {
                return  // two names of one file: rename(2) does nothing
            }
            let replacedNode = self.graph.nodes[replaced]
            switch (movingNode.kind == .directory, replacedNode?.kind == .directory) {
            case (true, true):
                guard replacedNode?.entries.isEmpty ?? true else {
                    throw .notEmpty
                }
            case (true, false):
                throw .other(errno: ENOTDIR)
            case (false, true):
                throw .other(errno: EISDIR)
            case (false, false):
                break
            }
        }
        if movingNode.kind == .directory, self.graph.contains(moving, toParent) {
            throw .other(errno: EINVAL)
        }
        if to.node != nil {
            self.usage -= self.graph.unlink(to.name, in: toParent)
        }
        self.graph.nodes[fromParent]?.entries.removeValue(forKey: from.name)
        self.graph.nodes[toParent]?.entries[to.name] = moving
    }

    /// Bytes that landed on `url` count towards every `afterBytes` rule that matches it.
    mutating func recordLanded(_ bytes: Int64, at url: URL) {
        let path = url.standardizedFileURL.path
        for index in self.faults.indices {
            guard self.faults[index].rule.operation == .write, self.faults[index].rule.matching.matches(url),
                case .afterBytes = self.faults[index].rule.occurrence
            else {
                continue
            }
            self.faults[index].received[path, default: 0] += bytes
        }
    }

    /// Counts the call against every matching rule and returns the first rule that fires, with the bytes a
    /// write lands before failing (`partialBytes`, or what fits under an `afterBytes` threshold).
    mutating func fireFault(_ kind: FSOpKind, _ url: URL, offered: Int) -> (error: FileSystemError, landed: Int?)? {
        var fired: (error: FileSystemError, landed: Int?)?
        let path = url.standardizedFileURL.path
        for index in self.faults.indices {
            let rule = self.faults[index].rule
            guard rule.operation == kind, rule.matching.matches(url) else {
                continue
            }
            self.faults[index].matches += 1
            let fires: Bool
            var landed = rule.partialBytes.map { max(0, min($0, offered)) }
            switch rule.occurrence {
            case .nth(let n):
                fires = self.faults[index].matches == n
            case .every:
                fires = true
            case .afterBytes(let threshold):
                let received = self.faults[index].received[path, default: 0]
                fires = kind == .write && received + Int64(offered) > threshold
                landed = Int(max(0, min(Int64(offered), threshold - received)))
            }
            if fires, fired == nil {
                fired = (rule.error, landed)
            }
        }
        return fired
    }
}

/// A fault rule and how often it matched.
struct FaultCursor: Sendable {
    /// The rule.
    var rule: FaultRule
    /// Matching calls so far.
    var matches = 0
    /// Bytes landed per path, for `afterBytes`.
    var received: [String: Int64] = [:]
}

extension FSGraph {
    /// The volume's root and its `Library/Application Support` and `Library/Caches` always exist and are durable
    /// (the OS created them long ago), so `standardDirectory` resolves to an existing directory.
    mutating func ensureStandardDirectories(volumeRoot: URL, now: Date) {
        for directory in [StandardDirectory.applicationSupport, .caches] {
            let url = FSGraph.standardURL(directory, volumeRoot: volumeRoot)
            let components = FSGraph.components(of: url.standardizedFileURL.path)
            _ = self.ensureDirectory(components, now: now)
            _ = self.ensureDurableDirectory(components, now: now)
        }
        self.recountLinks()
    }

    /// The URL a standard directory resolves to on the fake volume.
    static func standardURL(_ directory: StandardDirectory, volumeRoot: URL) -> URL {
        let library = volumeRoot.appendingPathComponent("Library", isDirectory: true)
        switch directory {
        case .applicationSupport:
            return library.appendingPathComponent("Application Support", isDirectory: true)
        case .caches:
            return library.appendingPathComponent("Caches", isDirectory: true)
        }
    }

    /// Makes an inode durable: a file's bytes, or a directory's listing.
    mutating func makeDurable(_ id: UInt64) {
        guard let node = self.nodes[id] else {
            return
        }
        switch node.kind {
        case .file:
            self.nodes[id]?.durableData = node.data
        case .directory:
            self.nodes[id]?.durableEntries = node.entries
        case .symbolicLink, .other:
            break
        }
    }
}

/// Fixtures the shared conformance contract needs and the seam cannot create: a symbolic link and a short write.
/// Ungated, so `FileSystemConformance` reaches the gated fake with a cast and no `#available` (R-APL-5).
protocol FileSystemFixtureSeeding: Sendable {
    /// Creates a symbolic link to `destination`.
    func seedSymbolicLink(at url: URL, destination: String) throws(FileSystemError)
    /// Makes the next write to `url` land `bytes` bytes, then fail with `error`.
    func seedShortWrite(at url: URL, landing bytes: Int, error: FileSystemError)
}

@available(macOS 15.0, iOS 18.0, *)
extension FakeFileSystem: FileSystemFixtureSeeding {
    /// `createSymbolicLink(at:destination:)`.
    func seedSymbolicLink(at url: URL, destination: String) throws(FileSystemError) {
        try self.createSymbolicLink(at: url, destination: destination)
    }

    /// A `.nth(1)` write rule for exactly `url` with `partialBytes`.
    func seedShortWrite(at url: URL, landing bytes: Int, error: FileSystemError) {
        let matcher = URLMatcher(lastComponentSuffix: url.lastPathComponent, pathContains: url.standardizedFileURL.path)
        self.addFault(FaultRule(operation: .write, matching: matcher, occurrence: .nth(1), error: error, partialBytes: bytes))
    }
}
