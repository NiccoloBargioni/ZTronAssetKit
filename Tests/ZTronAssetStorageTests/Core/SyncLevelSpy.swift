import Foundation
import Synchronization
import ZTronAssetModel
import ZTronAssetTestSupport

/// A `FileSystem` that forwards to a `FakeFileSystem` and records the level of every sync, which the fake's op log
/// does not carry (ADR-049: ordered and durable commits are told apart through the store's own commit API).
@available(macOS 15.0, iOS 18.0, *)
final class SyncLevelSpy: FileSystem {
    /// One recorded sync.
    struct Sync: Sendable, Hashable {
        var directory: Bool
        var path: String
        var level: SyncLevel
    }

    let base: FakeFileSystem
    private let recorded = Mutex<[Sync]>([])
    private let attributesOverride = Mutex<StoreAttributes?>(nil)

    init(_ base: FakeFileSystem) {
        self.base = base
    }

    /// Every sync so far, in order.
    var syncs: [Sync] {
        self.recorded.withLock { $0 }
    }

    func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL {
        try self.base.standardDirectory(directory)
    }

    func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo? {
        try self.base.itemInfo(at: url)
    }

    func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo] {
        try self.base.contentsOfDirectory(at: url)
    }

    func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        try self.base.read(from: url, offset: offset, maxLength: maxLength)
    }

    func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        try self.base.availableCapacity(at: url, for: purpose)
    }

    func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        if let reported = self.attributesOverride.withLock({ $0 }) {
            return reported
        }
        return try self.base.storeAttributes(at: url)
    }

    /// Makes `storeAttributes` report `attributes` for every item (a restore that dropped them).
    func reportAttributes(_ attributes: StoreAttributes?) {
        self.attributesOverride.withLock { $0 = attributes }
    }

    func createDirectory(at url: URL) throws(FileSystemError) {
        try self.base.createDirectory(at: url)
    }

    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        try self.base.write(data, to: url, mode: mode)
    }

    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        self.recorded.withLock { $0.append(Sync(directory: false, path: url.path, level: level)) }
        try self.base.synchronizeFile(at: url, level: level)
    }

    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        self.recorded.withLock { $0.append(Sync(directory: true, path: url.path, level: level)) }
        try self.base.synchronizeDirectory(at: url, level: level)
    }

    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        try self.base.rename(from: source, to: destination, mode: mode)
    }

    func removeItem(at url: URL) throws(FileSystemError) {
        try self.base.removeItem(at: url)
    }

    func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        try self.base.applyStoreAttributes(attributes, at: url)
    }

    func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        try self.base.acquireExclusiveLock(at: url)
    }

    func releaseLock(_ token: FileLockToken) {
        self.base.releaseLock(token)
    }
}
