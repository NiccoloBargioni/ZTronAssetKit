import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetTestSupport

/// R-STO-6: the fake satisfies the shared conformance contract, and the contract catches a conformer that breaks
/// any one of its clauses (so passing it means something).
@Suite("Test support: FileSystem conformance")
struct TestSupportFileSystemConformanceTests {
    @available(macOS 15.0, *)
    @Test("R-STO-6: FakeFileSystem satisfies the shared FileSystem conformance contract")
    func fakeConforms() throws {
        let fileSystem = FakeFSFixture.make()
        let root = FakeFSFixture.url("/fake-volume/conformance")
        try fileSystem.createDirectory(at: root)
        let violations = FileSystemConformance.violations(of: fileSystem, in: root)
        #expect(violations.isEmpty, "\(violations.map(\.description))")
        #expect(fileSystem.operations.count > 60)
    }

    @available(macOS 15.0, *)
    @Test("R-STO-6: the conformance contract reports a conformer that breaks one of its clauses", arguments: BrokenFileSystemConformer.Defect.allCases)
    func brokenConformerIsReported(defect: BrokenFileSystemConformer.Defect) throws {
        let base = FakeFSFixture.make()
        let root = FakeFSFixture.url("/fake-volume/conformance")
        try base.createDirectory(at: root)
        let violations = FileSystemConformance.violations(of: BrokenFileSystemConformer(base: base, defect: defect), in: root)
        #expect(violations.contains { $0.clause == defect.clause }, "\(violations.map(\.description))")
        #expect(violations.allSatisfy { !$0.description.contains("fixture") })
    }
}

/// A `FakeFileSystem` with exactly one deliberate defect.
@available(macOS 15.0, *)
struct BrokenFileSystemConformer: FileSystem, FileSystemFixtureSeeding {
    enum Defect: String, CaseIterable, Sendable {
        case createFailsWhenPresent
        case appendTruncates
        case readIgnoresOffset
        case exclusiveRenameReplaces
        case removeAbsentThrows
        case itemInfoFollowsLinks
        case shortWriteHidden
        case lockIsReentrant
        case truncateReplacesFile
        case renameCopies
        case absentReportsMetadata
        case sizeIsWrong
        case listingLosesKinds
        case listingThrows
        case lockTokenIsForeign
        case lockFails
        case removeKeepsNonEmptyDirectoryButSucceeds
        case missingReadIsIO
        case attributesForgotten
        case attributesThrow
        case capacityNegative
        case capacityThrows
        case syncFails
        case itemInfoThrows
        case createMakesIntermediates
        case truncateAppends
        case writeCreatesParents
        case exclusiveMoveCopiesWithoutRemoving
        case replacingRenameRefuses
        case missingRenameSucceeds
        case removeLeavesFile
        case missingListingIsEmpty
        case removeFollowsLink
        case missingSyncSucceeds
        case releaseBreaksReacquire
        case staleReleaseUnlocks

        /// The clause the contract must report.
        var clause: String {
            switch self {
            case .createFailsWhenPresent:
                return "createDirectory creates one level and succeeds when the directory exists"
            case .appendTruncates:
                return "write(.append) creates an absent file and appends to an existing one"
            case .readIgnoresOffset:
                return "read returns at most maxLength bytes from offset and empty Data at or past the end"
            case .exclusiveRenameReplaces:
                return "rename(.exclusive) onto an existing name fails with alreadyExists and touches neither name"
            case .removeAbsentThrows:
                return "removeItem of an absent item succeeds, even below a missing directory"
            case .itemInfoFollowsLinks:
                return "itemInfo and listings report a symbolic link as a link and never follow it"
            case .shortWriteHidden:
                return "a short write reports its error after the bytes that landed"
            case .lockIsReentrant, .lockTokenIsForeign, .lockFails:
                return "acquireExclusiveLock creates the lock file and fails with wouldBlock while any holder exists"
            case .truncateReplacesFile:
                return "write(.truncate) onto an existing file keeps its identity"
            case .renameCopies:
                return "rename keeps the moved file's identity"
            case .absentReportsMetadata, .sizeIsWrong, .itemInfoThrows:
                return "itemInfo of an absent item is nil and of a file reports name, kind, size and modification time"
            case .listingLosesKinds, .listingThrows:
                return "contentsOfDirectory lists exactly one level with names, kinds and sizes"
            case .removeKeepsNonEmptyDirectoryButSucceeds:
                return "removeItem of a non-empty directory fails with notEmpty and keeps it"
            case .missingReadIsIO:
                return "read of a missing file fails with notFound"
            case .attributesForgotten, .attributesThrow:
                return "applyStoreAttributes round-trips backup exclusion"
            case .capacityNegative, .capacityThrows:
                return "availableCapacity reports a non-negative figure for both purposes"
            case .syncFails:
                return "synchronizeFile and synchronizeDirectory succeed at both levels on existing items"
            case .createMakesIntermediates:
                return "createDirectory below a missing parent fails with notFound"
            case .truncateAppends:
                return "write(.truncate) creates the file and replaces its content"
            case .writeCreatesParents:
                return "write into a missing directory fails with notFound"
            case .exclusiveMoveCopiesWithoutRemoving:
                return "rename(.exclusive) onto a free name moves the file"
            case .replacingRenameRefuses:
                return "rename(.replacing) replaces an existing destination and removes the source name"
            case .missingRenameSucceeds:
                return "rename of a missing source fails with notFound"
            case .removeLeavesFile:
                return "removeItem removes a file and an empty directory"
            case .missingListingIsEmpty:
                return "contentsOfDirectory of a missing directory fails with notFound"
            case .removeFollowsLink:
                return "removeItem of a symbolic link removes the link, not its target"
            case .missingSyncSucceeds:
                return "synchronizeFile of a missing file fails with notFound"
            case .releaseBreaksReacquire:
                return "releaseLock is idempotent and the lock can be taken again"
            case .staleReleaseUnlocks:
                return "releasing a stale token leaves a lock taken since then held"
            }
        }
    }

    let base: FakeFileSystem
    let defect: Defect
    /// For `staleReleaseUnlocks`: the latest real token per lock file, as a reused descriptor number would name it.
    let latestTokens = BrokenConformerTokens()

    func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL {
        try self.base.standardDirectory(directory)
    }

    func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo? {
        if self.defect == .itemInfoThrows, url.lastPathComponent == "file.bin" {
            throw .io
        }
        guard var info = try self.base.itemInfo(at: url) else {
            if self.defect == .absentReportsMetadata {
                return FileItemInfo(name: url.lastPathComponent, kind: .file, byteSize: 0, modifiedAt: nil, identity: nil)
            }
            return nil
        }
        if self.defect == .itemInfoFollowsLinks, info.kind == .symbolicLink {
            info.kind = .file
        }
        if self.defect == .sizeIsWrong, info.kind == .file {
            info.byteSize += 1
        }
        return info
    }

    func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo] {
        if self.defect == .listingThrows {
            throw .io
        }
        if self.defect == .missingListingIsEmpty, try self.base.itemInfo(at: url) == nil {
            return []
        }
        let items = try self.base.contentsOfDirectory(at: url)
        guard self.defect == .listingLosesKinds else {
            return items
        }
        return items.map { item in
            var item = item
            item.kind = .other
            return item
        }
    }

    func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        do throws(FileSystemError) {
            return try self.base.read(from: url, offset: self.defect == .readIgnoresOffset ? 0 : offset, maxLength: maxLength)
        } catch .notFound where self.defect == .missingReadIsIO {
            throw .io
        }
    }

    func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        switch self.defect {
        case .capacityNegative:
            return -1
        case .capacityThrows:
            throw .io
        default:
            return try self.base.availableCapacity(at: url, for: purpose)
        }
    }

    func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        switch self.defect {
        case .attributesForgotten:
            return StoreAttributes(excludedFromBackup: false, protection: nil)
        case .attributesThrow:
            throw .permissionDenied
        default:
            return try self.base.storeAttributes(at: url)
        }
    }

    func createDirectory(at url: URL) throws(FileSystemError) {
        if self.defect == .createFailsWhenPresent, try self.base.itemInfo(at: url) != nil {
            throw .alreadyExists
        }
        if self.defect == .createMakesIntermediates, try self.base.itemInfo(at: url.deletingLastPathComponent()) == nil {
            try self.createDirectory(at: url.deletingLastPathComponent())
        }
        try self.base.createDirectory(at: url)
    }

    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        if self.defect == .truncateReplacesFile, mode == .truncate {
            try self.base.removeItem(at: url)
        }
        if self.defect == .writeCreatesParents, try self.base.itemInfo(at: url.deletingLastPathComponent()) == nil {
            try self.base.createDirectory(at: url.deletingLastPathComponent())
        }
        var effective = mode
        if self.defect == .appendTruncates {
            effective = .truncate
        } else if self.defect == .truncateAppends {
            effective = .append
        }
        do throws(FileSystemError) {
            try self.base.write(data, to: url, mode: effective)
        } catch .noSpace where self.defect == .shortWriteHidden {
            return
        }
    }

    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        if self.defect == .syncFails, level == .full {
            throw .notSupported
        }
        if self.defect == .missingSyncSucceeds, try self.base.itemInfo(at: url) == nil {
            return
        }
        try self.base.synchronizeFile(at: url, level: level)
    }

    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.base.synchronizeDirectory(at: url, level: level)
    }

    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        if self.defect == .missingRenameSucceeds, try self.base.itemInfo(at: source) == nil {
            return
        }
        if self.defect == .replacingRenameRefuses, mode == .replacing, try self.base.itemInfo(at: destination) != nil {
            throw .alreadyExists
        }
        if self.defect == .exclusiveMoveCopiesWithoutRemoving, mode == .exclusive, try self.base.itemInfo(at: destination) == nil {
            try self.base.write(try self.base.read(from: source, offset: 0, maxLength: 1 << 20), to: destination, mode: .truncate)
            return
        }
        if self.defect == .renameCopies, try self.base.itemInfo(at: destination) == nil {
            let data = try self.base.read(from: source, offset: 0, maxLength: 1 << 20)
            try self.base.write(data, to: destination, mode: .truncate)
            try self.base.removeItem(at: source)
            return
        }
        try self.base.rename(from: source, to: destination, mode: self.defect == .exclusiveRenameReplaces ? .replacing : mode)
    }

    func removeItem(at url: URL) throws(FileSystemError) {
        if self.defect == .removeAbsentThrows, (try? self.base.itemInfo(at: url)) ?? nil == nil {
            throw .notFound
        }
        let kind = try self.base.itemInfo(at: url)?.kind
        if self.defect == .removeLeavesFile, kind == .file {
            return
        }
        if self.defect == .removeFollowsLink, kind == .symbolicLink, let target = self.base.survivingDisk().symbolicLinks[url.path] {
            try self.base.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(target))
            return
        }
        do throws(FileSystemError) {
            try self.base.removeItem(at: url)
        } catch .notEmpty where self.defect == .removeKeepsNonEmptyDirectoryButSucceeds {
            return
        }
    }

    func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        try self.base.applyStoreAttributes(attributes, at: url)
    }

    func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        if self.defect == .lockFails {
            throw .io
        }
        do throws(FileSystemError) {
            let token = try self.base.acquireExclusiveLock(at: url)
            if self.defect == .lockTokenIsForeign {
                return FileLockToken(identity: FileIdentity(device: 7, inode: 7), handle: token.handle)
            }
            if self.defect == .staleReleaseUnlocks {
                self.latestTokens.remember(token)
                return FileLockToken(identity: token.identity, handle: 3)  // the same descriptor number every time
            }
            return token
        } catch .wouldBlock where self.defect == .lockIsReentrant {
            return FileLockToken(identity: FileIdentity(device: 0, inode: 0), handle: -1)
        }
    }

    func releaseLock(_ token: FileLockToken) {
        switch self.defect {
        case .releaseBreaksReacquire:
            return
        case .staleReleaseUnlocks:
            if let latest = self.latestTokens.latest(for: token.identity) {
                self.base.releaseLock(latest)
            }
        default:
            self.base.releaseLock(token)
        }
    }

    func seedSymbolicLink(at url: URL, destination: String) throws(FileSystemError) {
        try self.base.seedSymbolicLink(at: url, destination: destination)
    }

    func seedShortWrite(at url: URL, landing bytes: Int, error: FileSystemError) {
        self.base.seedShortWrite(at: url, landing: bytes, error: error)
    }
}

/// The latest real lock token per lock file, so `staleReleaseUnlocks` releases whatever lock a reused descriptor
/// number names now.
@available(macOS 15.0, *)
final class BrokenConformerTokens: Sendable {
    private let tokens = Mutex<[FileIdentity: FileLockToken]>([:])

    func remember(_ token: FileLockToken) {
        self.tokens.withLock { $0[token.identity] = token }
    }

    func latest(for identity: FileIdentity) -> FileLockToken? {
        self.tokens.withLock { $0[identity] }
    }
}
