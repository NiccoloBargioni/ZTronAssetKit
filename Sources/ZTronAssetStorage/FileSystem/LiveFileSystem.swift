import Foundation
import ZTronAssetModel

/// The real file system: the **only** production type that touches `FileManager` or POSIX (R-STO-6; WP-B).
///
/// A struct with no stored state, so `Sendable` without escapes. Implementation notes fixed by the design
/// (store.md §3.3 as amended): `read` uses `FileHandle` inside `autoreleasepool`; syncs use
/// `fcntl(F_FULLFSYNC | F_BARRIERFSYNC)` and fall back to `fsync` only for ENOTSUP/EINVAL/ENOTTY, never for EIO
/// (store-1 S1-15); the lock is `open(O_EXLOCK | O_NONBLOCK | O_CLOEXEC)` and records the lock file's identity
/// (store-1 S1-08); the errno and Cocoa mappings are pure functions tested on macOS.
public struct LiveFileSystem: FileSystem {
    /// Creates the live file system (stateless; no I/O).
    public init() {}

    /// `FileManager.url(for:in:appropriateFor:create:)` for the user domain.
    public func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL {
        fatalError("WP-B: LiveFileSystem.standardDirectory not implemented")
    }

    /// `lstat`-equivalent resource values.
    public func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo? {
        fatalError("WP-B: LiveFileSystem.itemInfo not implemented")
    }

    /// One non-following directory listing.
    public func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo] {
        fatalError("WP-B: LiveFileSystem.contentsOfDirectory not implemented")
    }

    /// One bounded read.
    public func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        fatalError("WP-B: LiveFileSystem.read not implemented")
    }

    /// `volumeAvailableCapacityFor{Important,Opportunistic}Usage`.
    public func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        fatalError("WP-B: LiveFileSystem.availableCapacity not implemented")
    }

    /// Backup exclusion and protection class.
    public func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        fatalError("WP-B: LiveFileSystem.storeAttributes not implemented")
    }

    /// `mkdir(0o700)`; EEXIST is success.
    public func createDirectory(at url: URL) throws(FileSystemError) {
        fatalError("WP-B: LiveFileSystem.createDirectory not implemented")
    }

    /// `open(O_WRONLY|O_CREAT|O_CLOEXEC|O_TRUNC/O_APPEND)` + `FileHandle.write(contentsOf:)`.
    public func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        fatalError("WP-B: LiveFileSystem.write not implemented")
    }

    /// `fcntl(F_BARRIERFSYNC | F_FULLFSYNC)` on the file.
    public func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        fatalError("WP-B: LiveFileSystem.synchronizeFile not implemented")
    }

    /// `fcntl(F_BARRIERFSYNC | F_FULLFSYNC)` on the directory.
    public func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        fatalError("WP-B: LiveFileSystem.synchronizeDirectory not implemented")
    }

    /// `rename` / `renamex_np(RENAME_EXCL)`.
    public func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        fatalError("WP-B: LiveFileSystem.rename not implemented")
    }

    /// `unlink`, else `rmdir`; ENOENT is success.
    public func removeItem(at url: URL) throws(FileSystemError) {
        fatalError("WP-B: LiveFileSystem.removeItem not implemented")
    }

    /// `isExcludedFromBackup` plus, on iOS, the protection class.
    public func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        fatalError("WP-B: LiveFileSystem.applyStoreAttributes not implemented")
    }

    /// `open(O_RDWR|O_CREAT|O_CLOEXEC|O_EXLOCK|O_NONBLOCK, 0o600)`; EWOULDBLOCK maps to `.wouldBlock`.
    public func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        fatalError("WP-B: LiveFileSystem.acquireExclusiveLock not implemented")
    }

    /// `flock(LOCK_UN)` then `close`.
    public func releaseLock(_ token: FileLockToken) {
        fatalError("WP-B: LiveFileSystem.releaseLock not implemented")
    }
}
