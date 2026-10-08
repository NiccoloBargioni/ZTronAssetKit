import Darwin
import Foundation
import ZTronAssetModel

/// The real file system: the **only** production type that touches `FileManager` or POSIX (R-STO-6; WP-B).
///
/// A struct with no stored state, so `Sendable` without escapes. Implementation notes fixed by the design
/// (store.md §3.3 as amended): `read` uses `FileHandle` inside `autoreleasepool`; syncs use
/// `fcntl(F_FULLFSYNC | F_BARRIERFSYNC)` and fall back to `fsync` only for ENOTSUP/EINVAL/ENOTTY, never for EIO
/// (store-1 S1-15); the lock is `open(O_EXLOCK | O_NONBLOCK | O_CLOEXEC)` and records the lock file's identity
/// (store-1 S1-08); the errno and Cocoa mappings are pure functions tested on macOS (`FileSystemErrorMapping`).
///
/// **Lock tokens.** A descriptor number is reused after `close`, so a token holding only the descriptor would let a
/// stale release unlock a lock taken since (the conformance suite's stale-token clause, ADR-049). Each acquisition
/// therefore draws a nonce, parks the lock descriptor's file offset on it (`lseek`, which writes nothing: the lock
/// file stays empty) and carries it in the token's handle next to the descriptor (`nonce << 32 | descriptor`);
/// `releaseLock` unlocks only a descriptor whose offset still equals the nonce. No pointer, no shared state.
public struct LiveFileSystem: FileSystem {
    /// Creates the live file system (stateless; no I/O).
    public init() {}

    /// `FileManager.url(for:in:appropriateFor:create:)` for the user domain.
    public func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL {
        let search: FileManager.SearchPathDirectory
        switch directory {
        case .applicationSupport:
            search = .applicationSupportDirectory
        case .caches:
            search = .cachesDirectory
        }
        do {
            return try FileManager.default.url(for: search, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            throw FileSystemErrorMapping.cocoa(error)
        }
    }

    /// `lstat`-equivalent resource values (`attributesOfItem` describes a symbolic link itself).
    public func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let mapped = FileSystemErrorMapping.cocoa(error)
            if mapped == .notFound {
                return nil
            }
            throw mapped
        }
        return LiveFileSystem.info(name: url.lastPathComponent, attributes: attributes)
    }

    /// One non-following directory listing (hidden names included).
    public func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
            var result: [FileItemInfo] = []
            result.reserveCapacity(items.count)
            for item in items {
                let values = try item.resourceValues(forKeys: Set(keys))
                let kind = LiveFileSystem.kind(
                    symbolicLink: values.isSymbolicLink ?? false,
                    directory: values.isDirectory ?? false,
                    regularFile: values.isRegularFile ?? false
                )
                let size = kind == .file ? Int64(values.fileSize ?? 0) : 0
                result.append(
                    FileItemInfo(name: item.lastPathComponent, kind: kind, byteSize: size, modifiedAt: values.contentModificationDate, identity: nil)
                )
            }
            return result
        } catch {
            throw FileSystemErrorMapping.cocoa(error)
        }
    }

    /// One bounded read (≤ 1 MiB) inside an autorelease pool, so a 256 MiB hash never accumulates buffers
    /// (store.md §10: 1,285 MiB without a pool).
    public func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        let length = min(max(0, maxLength), 1 << 20)
        let result: Result<Data, FileSystemError> = autoreleasepool {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer {
                    try? handle.close()
                }
                guard length > 0 else {
                    return .success(Data())
                }
                try handle.seek(toOffset: UInt64(max(0, offset)))
                return .success(try handle.read(upToCount: length) ?? Data())
            } catch {
                return .failure(FileSystemErrorMapping.cocoa(error))
            }
        }
        return try result.get()
    }

    /// `volumeAvailableCapacityFor{Important,Opportunistic}Usage`, falling back to the plain available capacity
    /// where the volume reports neither.
    public func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        let values: URLResourceValues
        do {
            values = try LiveFileSystem.uncached(url).resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey, .volumeAvailableCapacityKey,
            ])
        } catch {
            throw FileSystemErrorMapping.cocoa(error)
        }
        let specific: Int64?
        switch purpose {
        case .important:
            specific = values.volumeAvailableCapacityForImportantUsage
        case .opportunistic:
            specific = values.volumeAvailableCapacityForOpportunisticUsage
        }
        return max(0, specific ?? Int64(values.volumeAvailableCapacity ?? 0))
    }

    /// Backup exclusion and, on iOS, the protection class (`nil` on macOS, which has none).
    public func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        do {
            // `attributesOfItem` first: resource values of a missing item read as absent instead of failing.
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let protection = (attributes[.protectionKey] as? FileProtectionType).map(LiveFileSystem.protectionClass(of:))
            #else
                _ = try FileManager.default.attributesOfItem(atPath: url.path)
                let protection: ProtectionClass? = nil
            #endif
            let values = try LiveFileSystem.uncached(url).resourceValues(forKeys: [.isExcludedFromBackupKey])
            return StoreAttributes(excludedFromBackup: values.isExcludedFromBackup ?? false, protection: protection)
        } catch {
            throw FileSystemErrorMapping.cocoa(error)
        }
    }

    /// `mkdir(0o700)`; EEXIST is success when a directory is there.
    public func createDirectory(at url: URL) throws(FileSystemError) {
        if mkdir(url.path, 0o700) == 0 {
            return
        }
        let code = errno
        guard code == EEXIST else {
            throw FileSystemErrorMapping.posix(code)
        }
        guard try self.itemInfo(at: url)?.kind == .directory else {
            throw .alreadyExists
        }
    }

    /// `open(O_WRONLY|O_CREAT|O_CLOEXEC|O_TRUNC/O_APPEND)` + `FileHandle.write(contentsOf:)`; a short write throws
    /// after the bytes that landed.
    public func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | (mode == .truncate ? O_TRUNC : O_APPEND)
        let descriptor = open(url.path, flags, 0o600)
        guard descriptor >= 0 else {
            throw FileSystemErrorMapping.posix(errno)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            throw FileSystemErrorMapping.cocoa(error)
        }
    }

    /// `fcntl(F_BARRIERFSYNC | F_FULLFSYNC)` on the file.
    public func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try LiveFileSystem.synchronize(path: url.path, flags: O_RDONLY | O_CLOEXEC, level: level)
    }

    /// `fcntl(F_BARRIERFSYNC | F_FULLFSYNC)` on the directory.
    public func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try LiveFileSystem.synchronize(path: url.path, flags: O_RDONLY | O_CLOEXEC | O_DIRECTORY, level: level)
    }

    /// `rename` / `renamex_np(RENAME_EXCL)`.
    public func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        let result: Int32
        switch mode {
        case .replacing:
            result = Darwin.rename(source.path, destination.path)
        case .exclusive:
            result = renamex_np(source.path, destination.path, UInt32(RENAME_EXCL))
        }
        guard result == 0 else {
            throw FileSystemErrorMapping.posix(errno)
        }
    }

    /// `unlink`, else `rmdir` (macOS answers EPERM for a directory); ENOENT is success, a link is removed itself.
    public func removeItem(at url: URL) throws(FileSystemError) {
        let path = url.path
        if unlink(path) == 0 {
            return
        }
        var code = errno
        if code == ENOENT || code == ENOTDIR {
            return
        }
        if code == EPERM || code == EISDIR {
            if rmdir(path) == 0 {
                return
            }
            let directoryCode = errno
            if directoryCode == ENOENT {
                return
            }
            if directoryCode != ENOTDIR {
                code = directoryCode
            }
        }
        throw FileSystemErrorMapping.posix(code)
    }

    /// `isExcludedFromBackup` plus, on iOS, the protection class.
    public func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        guard try self.itemInfo(at: url) != nil else {
            throw .notFound
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = attributes.excludedFromBackup
        var target = url
        do {
            try target.setResourceValues(values)
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
                if let protection = attributes.protection {
                    try FileManager.default.setAttributes(
                        [.protectionKey: LiveFileSystem.fileProtection(for: protection)],
                        ofItemAtPath: url.path
                    )
                }
            #endif
        } catch {
            throw FileSystemErrorMapping.cocoa(error)
        }
    }

    /// `open(O_RDWR|O_CREAT|O_CLOEXEC|O_EXLOCK|O_NONBLOCK, 0o600)`; EWOULDBLOCK maps to `.wouldBlock`. The token
    /// carries the lock file's identity and the nonce parked in the descriptor's offset (see the type's doc).
    public func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else {
            throw FileSystemErrorMapping.posix(errno)
        }
        let nonce = LiveFileSystem.drawLockNonce()
        guard lseek(descriptor, off_t(nonce), SEEK_SET) == off_t(nonce) else {
            let code = errno
            _ = close(descriptor)
            throw FileSystemErrorMapping.posix(code)
        }
        let identity: FileIdentity
        do throws(FileSystemError) {
            identity = try LiveFileSystem.identity(of: url)
        } catch {
            _ = close(descriptor)
            throw error
        }
        return FileLockToken(identity: identity, handle: LiveFileSystem.lockHandle(descriptor: descriptor, nonce: nonce))
    }

    /// `flock(LOCK_UN)` then `close`, only while the descriptor still carries the token's nonce: releasing twice, or
    /// releasing a stale token whose descriptor number was reused, releases nothing.
    public func releaseLock(_ token: FileLockToken) {
        let (descriptor, nonce) = LiveFileSystem.lockParts(of: token.handle)
        guard descriptor >= 0, nonce > 0, lseek(descriptor, 0, SEEK_CUR) == off_t(nonce) else {
            return
        }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    // MARK: Helpers (pure where possible)

    /// A fresh `URL` for `url`: an `NSURL` caches resource values for its lifetime on a thread without a run loop,
    /// so the store's long-lived root URL would report stale free space and attributes.
    static func uncached(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
    }

    /// Packs a descriptor and its nonce into a token handle.
    static func lockHandle(descriptor: Int32, nonce: UInt32) -> Int64 {
        (Int64(nonce) << 32) | Int64(UInt32(bitPattern: descriptor))
    }

    /// Unpacks a token handle into its descriptor and nonce.
    static func lockParts(of handle: Int64) -> (descriptor: Int32, nonce: Int64) {
        (Int32(truncatingIfNeeded: handle & 0xFFFF_FFFF), handle >> 32)
    }

    /// A fresh nonce in `1...Int32.max`, so the parked offset is positive and fits every `off_t`.
    private static func drawLockNonce() -> UInt32 {
        var generator = SystemRandomNumberGenerator()
        return UInt32.random(in: 1...UInt32(Int32.max), using: &generator)
    }

    /// `(st_dev, st_ino)` of the item at `url`, without following a final link.
    private static func identity(of url: URL) throws(FileSystemError) -> FileIdentity {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return FileIdentity(
                device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            )
        } catch {
            throw FileSystemErrorMapping.cocoa(error)
        }
    }

    /// Opens `path`, syncs it at `level`, and falls back to `fsync` only where `fcntl` is unsupported.
    private static func synchronize(path: String, flags: Int32, level: SyncLevel) throws(FileSystemError) {
        let descriptor = open(path, flags)
        guard descriptor >= 0 else {
            throw FileSystemErrorMapping.posix(errno)
        }
        defer {
            _ = close(descriptor)
        }
        if fcntl(descriptor, level == .full ? F_FULLFSYNC : F_BARRIERFSYNC) == 0 {
            return
        }
        let code = errno
        guard FileSystemErrorMapping.syncFallsBackToFsync(errno: code) else {
            throw FileSystemErrorMapping.posix(code)
        }
        guard fsync(descriptor) == 0 else {
            throw FileSystemErrorMapping.posix(errno)
        }
    }

    /// Metadata from `attributesOfItem`.
    static func info(name: String, attributes: [FileAttributeKey: Any]) -> FileItemInfo {
        let type = attributes[.type] as? FileAttributeType
        let kind = LiveFileSystem.kind(
            symbolicLink: type == .typeSymbolicLink,
            directory: type == .typeDirectory,
            regularFile: type == .typeRegular
        )
        let size = kind == .file ? ((attributes[.size] as? NSNumber)?.int64Value ?? 0) : 0
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let identity = device.flatMap { device in inode.map { FileIdentity(device: device, inode: $0) } }
        return FileItemInfo(name: name, kind: kind, byteSize: size, modifiedAt: attributes[.modificationDate] as? Date, identity: identity)
    }

    /// The item kind; a link wins over what it points to (links are never followed, R-SEC-2).
    static func kind(symbolicLink: Bool, directory: Bool, regularFile: Bool) -> FileItemKind {
        if symbolicLink {
            return .symbolicLink
        }
        if directory {
            return .directory
        }
        return regularFile ? .file : .other
    }

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        /// The Foundation protection type of a protection class.
        private static func fileProtection(for protection: ProtectionClass) -> FileProtectionType {
            switch protection {
            case .completeUntilFirstUserAuthentication:
                return .completeUntilFirstUserAuthentication
            case .complete:
                return .complete
            case .none:
                return .none
            }
        }

        /// The protection class of a Foundation protection type (unknown types read as `.none`).
        private static func protectionClass(of type: FileProtectionType) -> ProtectionClass {
            switch type {
            case .completeUntilFirstUserAuthentication:
                return .completeUntilFirstUserAuthentication
            case .complete:
                return .complete
            default:
                return .none
            }
        }
    #endif
}
