import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetTestSupport

/// R-STO-6: the fake satisfies the shared conformance contract, and the contract catches a conformer that breaks
/// any one of its clauses (so passing it means something).
@Suite("Test support: FileSystem conformance")
struct FileSystemConformanceTests {
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
    @Test("R-STO-6: the conformance contract reports a conformer that breaks one of its clauses", arguments: BrokenConformer.Defect.allCases)
    func brokenConformerIsReported(defect: BrokenConformer.Defect) throws {
        let base = FakeFSFixture.make()
        let root = FakeFSFixture.url("/fake-volume/conformance")
        try base.createDirectory(at: root)
        let violations = FileSystemConformance.violations(of: BrokenConformer(base: base, defect: defect), in: root)
        #expect(violations.contains { $0.clause == defect.clause }, "\(violations.map(\.description))")
        #expect(violations.allSatisfy { !$0.description.contains("fixture") })
    }
}

/// A `FakeFileSystem` with exactly one deliberate defect.
@available(macOS 15.0, *)
struct BrokenConformer: FileSystem, FileSystemFixtureSeeding {
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
            }
        }
    }

    let base: FakeFileSystem
    let defect: Defect

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
        try self.base.createDirectory(at: url)
    }

    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        if self.defect == .truncateReplacesFile, mode == .truncate {
            try self.base.removeItem(at: url)
        }
        do throws(FileSystemError) {
            try self.base.write(data, to: url, mode: self.defect == .appendTruncates ? .truncate : mode)
        } catch .noSpace where self.defect == .shortWriteHidden {
            return
        }
    }

    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        if self.defect == .syncFails, level == .full {
            throw .notSupported
        }
        try self.base.synchronizeFile(at: url, level: level)
    }

    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.base.synchronizeDirectory(at: url, level: level)
    }

    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
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
            return token
        } catch .wouldBlock where self.defect == .lockIsReentrant {
            return FileLockToken(identity: FileIdentity(device: 0, inode: 0), handle: -1)
        }
    }

    func releaseLock(_ token: FileLockToken) {
        self.base.releaseLock(token)
    }

    func seedSymbolicLink(at url: URL, destination: String) throws(FileSystemError) {
        try self.base.seedSymbolicLink(at: url, destination: destination)
    }

    func seedShortWrite(at url: URL, landing bytes: Int, error: FileSystemError) {
        self.base.seedShortWrite(at: url, landing: bytes, error: error)
    }
}
