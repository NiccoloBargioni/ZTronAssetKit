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
    /// For `write`: how many bytes land before the error.
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
public struct DiskImage: Sendable, Hashable {
    /// Regular files by path, current content.
    package var files: [String: [UInt8]]
    /// Directories by path.
    package var directories: Set<String>
    /// Durable (synced) content, kept across a process kill (store-1 S1-01).
    package var durableFiles: [String: [UInt8]]
    /// Durable directory listings.
    package var durableDirectories: Set<String>

    /// An empty disk.
    public init() {
        self.files = [:]
        self.directories = []
        self.durableFiles = [:]
        self.durableDirectories = []
    }

    /// Every path, sorted.
    public var paths: [String] {
        (Array(self.files.keys) + Array(self.directories)).sorted()
    }

    /// SHA-256 over sorted paths and contents.
    public func digest() -> ContentHash {
        fatalError("WP-H: DiskImage.digest not implemented")
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
@available(macOS 15.0, iOS 18.0, *)
public final class FakeFileSystem: FileSystem {
    private let state: Mutex<DiskImage>
    /// The lifetime's configuration.
    public let configuration: FakeFileSystemConfiguration
    /// Supplies `mtime` (no real clock).
    public let time: any TimeSource

    /// Starts a lifetime on `disk`.
    public init(disk: DiskImage = DiskImage(), time: any TimeSource, configuration: FakeFileSystemConfiguration = FakeFileSystemConfiguration()) {
        self.state = Mutex(disk)
        self.time = time
        self.configuration = configuration
    }

    /// The op log so far.
    public var operations: [FSOpRecord] {
        fatalError("WP-H: FakeFileSystem.operations not implemented")
    }

    /// Mutations performed so far (the crash-point count of a clean run).
    public var mutationCount: Int {
        fatalError("WP-H: FakeFileSystem.mutationCount not implemented")
    }

    /// Whether the configured crash happened.
    public var crashed: Bool {
        fatalError("WP-H: FakeFileSystem.crashed not implemented")
    }

    /// The disk after the crash (or now), per `configuration.crashMode`; seeds the next lifetime.
    public func survivingDisk() -> DiskImage {
        fatalError("WP-H: FakeFileSystem.survivingDisk not implemented")
    }

    /// Adds a fault rule.
    public func addFault(_ rule: FaultRule) {
        fatalError("WP-H: FakeFileSystem.addFault not implemented")
    }

    /// Calls made on the main thread (R-STO-7, P-8).
    public var mainThreadCalls: Int {
        fatalError("WP-H: FakeFileSystem.mainThreadCalls not implemented")
    }

    /// Attributes applied, by path (R-STO-8).
    public var appliedAttributes: [String: StoreAttributes] {
        fatalError("WP-H: FakeFileSystem.appliedAttributes not implemented")
    }

    /// Resolves under `configuration.volumeRoot`.
    public func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL {
        fatalError("WP-H: FakeFileSystem.standardDirectory not implemented")
    }

    /// Modelled `lstat`.
    public func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo? {
        fatalError("WP-H: FakeFileSystem.itemInfo not implemented")
    }

    /// Modelled listing.
    public func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo] {
        fatalError("WP-H: FakeFileSystem.contentsOfDirectory not implemented")
    }

    /// Modelled read.
    public func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        fatalError("WP-H: FakeFileSystem.read not implemented")
    }

    /// Scripted capacity.
    public func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        fatalError("WP-H: FakeFileSystem.availableCapacity not implemented")
    }

    /// Recorded attributes.
    public func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        fatalError("WP-H: FakeFileSystem.storeAttributes not implemented")
    }

    /// Modelled mkdir (crash boundary).
    public func createDirectory(at url: URL) throws(FileSystemError) {
        fatalError("WP-H: FakeFileSystem.createDirectory not implemented")
    }

    /// Modelled write (crash boundary; torn and short writes).
    public func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        fatalError("WP-H: FakeFileSystem.write not implemented")
    }

    /// Marks file data durable (crash boundary).
    public func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        fatalError("WP-H: FakeFileSystem.synchronizeFile not implemented")
    }

    /// Marks a directory listing durable (crash boundary).
    public func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        fatalError("WP-H: FakeFileSystem.synchronizeDirectory not implemented")
    }

    /// Modelled rename (crash boundary).
    public func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        fatalError("WP-H: FakeFileSystem.rename not implemented")
    }

    /// Modelled unlink (crash boundary).
    public func removeItem(at url: URL) throws(FileSystemError) {
        fatalError("WP-H: FakeFileSystem.removeItem not implemented")
    }

    /// Records attributes (crash boundary).
    public func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        fatalError("WP-H: FakeFileSystem.applyStoreAttributes not implemented")
    }

    /// Modelled `O_EXLOCK`: `.wouldBlock` while any other holder exists (crash boundary).
    public func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        fatalError("WP-H: FakeFileSystem.acquireExclusiveLock not implemented")
    }

    /// Releases a modelled lock.
    public func releaseLock(_ token: FileLockToken) {
        fatalError("WP-H: FakeFileSystem.releaseLock not implemented")
    }
}
