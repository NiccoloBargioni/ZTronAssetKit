import Foundation

/// Kinds of directory entry the store distinguishes. Symbolic links are never followed (R-SEC-2).
public enum FileItemKind: Sendable, Hashable {
    /// A regular file.
    case file
    /// A directory.
    case directory
    /// A symbolic link (reported for the link itself; never resolved).
    case symbolicLink
    /// Anything else (FIFO, socket, device).
    case other
}

/// The `(st_dev, st_ino)` identity of an item: detects a replaced root or lock file (store-1 S1-08).
public struct FileIdentity: Sendable, Hashable {
    /// `st_dev`.
    public var device: UInt64
    /// `st_ino`.
    public var inode: UInt64

    /// Creates an identity.
    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Metadata of one existing item; directory listings return these too (without following links).
public struct FileItemInfo: Sendable, Hashable {
    /// The last path component.
    public var name: String
    /// What it is.
    public var kind: FileItemKind
    /// Size in bytes (0 for directories).
    public var byteSize: Int64
    /// Last modification time (orphan and staging grace, R-CLN-2/3), when available.
    public var modifiedAt: Date?
    /// Device and inode, when available.
    public var identity: FileIdentity?

    /// Creates item metadata.
    public init(name: String, kind: FileItemKind, byteSize: Int64, modifiedAt: Date?, identity: FileIdentity?) {
        self.name = name
        self.kind = kind
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.identity = identity
    }
}

/// How strongly a sync orders or persists earlier writes (ADR-015).
public enum SyncLevel: Sendable, Hashable {
    /// `F_BARRIERFSYNC`: data reaches the device and is ordered before every later write.
    case barrier
    /// `F_FULLFSYNC`: data and the device cache are flushed to stable storage.
    case full
}

/// How `write` treats existing content; both create the file when absent.
public enum WriteMode: Sendable, Hashable {
    /// Replace the content.
    case truncate
    /// Append to the content.
    case append
}

/// How `rename` treats an existing destination.
public enum RenameMode: Sendable, Hashable {
    /// `rename(2)`: atomically replaces the destination.
    case replacing
    /// `renamex_np(RENAME_EXCL)`: fails with `.alreadyExists` and touches neither name.
    case exclusive
}

/// Platform directories the store may be rooted in (ADR-001); resolved inside a unit, never at init (P-12).
public enum StandardDirectory: Sendable, Hashable {
    /// `Library/Application Support`.
    case applicationSupport
    /// `Library/Caches`.
    case caches
}

/// Which free-space figure a decision needs (sync-2 S2-23).
public enum CapacityPurpose: Sendable, Hashable {
    /// `volumeAvailableCapacityForImportantUsage`: user-initiated and essential work (counts purgeable space).
    case important
    /// `volumeAvailableCapacityForOpportunisticUsage`: bulk and prefetch work.
    case opportunistic
}

/// Data-protection classes the store can request (R-STO-8).
public enum ProtectionClass: Sendable, Hashable {
    /// Readable after the first unlock until reboot: background work after first unlock can proceed.
    case completeUntilFirstUserAuthentication
    /// Readable only while unlocked.
    case complete
    /// No protection.
    case none
}

/// Backup and protection state of an item (R-STO-8). `protection` is `nil` where the platform has none (macOS).
public struct StoreAttributes: Sendable, Hashable {
    /// `URLResourceValues.isExcludedFromBackup`.
    public var excludedFromBackup: Bool
    /// The data-protection class.
    public var protection: ProtectionClass?

    /// Creates attributes.
    public init(excludedFromBackup: Bool, protection: ProtectionClass?) {
        self.excludedFromBackup = excludedFromBackup
        self.protection = protection
    }

    /// What the store applies to its root, `blobs/` and `staging/` (ADR-001).
    public static let storeDefault = StoreAttributes(
        excludedFromBackup: true,
        protection: .completeUntilFirstUserAuthentication
    )
}

/// A held advisory lock (R-STO-9): an open file descriptor in `.live()`, plus the lock file's identity so a replaced
/// root is detected before every commit (store-1 S1-08).
public struct FileLockToken: Sendable, Hashable {
    /// The lock file's identity at acquisition.
    public let identity: FileIdentity
    /// The descriptor (live) or a fake handle (tests). Package-only: nobody outside can forge a token.
    package let handle: Int64

    /// Creates a token (conformers only).
    package init(identity: FileIdentity, handle: Int64) {
        self.identity = identity
        self.handle = handle
    }
}

/// The closed taxonomy of file-system failures; the live conformer maps errno and Cocoa errors here.
public enum FileSystemError: Error, Sendable, Hashable {
    /// ENOSPC.
    case noSpace
    /// EIO.
    case io
    /// EACCES / EPERM (also: protected data unavailable before first unlock).
    case permissionDenied
    /// ENOENT on an operation that needs the item.
    case notFound
    /// EEXIST on an exclusive rename.
    case alreadyExists
    /// EXDEV: the rename crosses volumes.
    case crossDevice
    /// EWOULDBLOCK: the lock is held (same process or another one).
    case wouldBlock
    /// ENOTEMPTY.
    case notEmpty
    /// ENOTSUP / EINVAL from a sync the volume cannot perform.
    case notSupported
    /// Anything else.
    case other(errno: Int32)
}

/// Every file-system effect of the module (R-STO-6).
///
/// Synchronous by design: each call is one bounded step and, for mutations, exactly one crash boundary, so the
/// R-STO-5 enumeration is deterministic (store.md §3.1). Production code calls it only inside a `BlockingExecutor`
/// unit (ADR-003), or from URLSession's delegate queue through `StagingSink`. The protocol lives in the Model so
/// the single `AssetEnvironment` can hold it (SPEC §4.2, ADR-038); the only conformer that touches `FileManager`
/// or POSIX is `ZTronAssetStorage.LiveFileSystem`.
///
/// Shared semantics, pinned by a conformance suite run against the live and the fake conformer: `removeItem` of
/// an absent item succeeds and never follows links; `createDirectory` creates one level and succeeds if it exists;
/// `read` returns empty `Data` at EOF and `maxLength ≤ 1 MiB`; an exclusive rename onto an existing name fails
/// with `.alreadyExists`; `acquireExclusiveLock` fails with `.wouldBlock` while any other holder exists, including
/// one in the same process.
public protocol FileSystem: Sendable {
    /// Resolves a platform directory (query).
    func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL
    /// Metadata without following a final symbolic link; `nil` when absent (query).
    func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo?
    /// One directory level, without following links (query).
    func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo]
    /// At most `maxLength` (≤ 1 MiB) bytes from `offset` (query).
    func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data
    /// Free space on the volume holding `url` (query, R-SYN-11, R-CLN-9).
    func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64
    /// Backup and protection state (query, R-STO-8).
    func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes
    /// Creates one directory level (mutation).
    func createDirectory(at url: URL) throws(FileSystemError)
    /// Writes or appends (mutation; a short write is reported as an error after the bytes that landed).
    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError)
    /// Orders or flushes a file's data (mutation).
    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError)
    /// Orders or flushes a directory's entries (mutation).
    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError)
    /// Renames within one volume (mutation).
    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError)
    /// Removes a file, a link (not its target) or an empty directory; absent is success (mutation).
    func removeItem(at url: URL) throws(FileSystemError)
    /// Applies backup exclusion and protection (mutation).
    func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError)
    /// Takes the advisory lock, creating the lock file when absent (mutation).
    func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken
    /// Releases a lock; idempotent (not a crash boundary: process death releases locks anyway).
    func releaseLock(_ token: FileLockToken)
}
