import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// Fault injection (R-STO-6: ENOSPC, EIO, EACCES, EXDEV, rename failure, partial write) and the capacity model.
@Suite("Test support: FakeFileSystem faults")
struct TestSupportFakeFileSystemFaultTests {
    private static let tmp = FakeFSFixture.url("/fake-volume/index.tmp")
    private static let bin = FakeFSFixture.url("/fake-volume/index.bin")

    @available(macOS 15.0, *)
    @Test("Test support: an nth rule fails only the n-th call that matches its operation and URL")
    func nthRuleFiresOnce() throws {
        let fileSystem = FakeFSFixture.make()
        fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: ".tmp"), occurrence: .nth(2), error: .noSpace))
        try fileSystem.write(Data([1]), to: Self.tmp, mode: .truncate)
        try fileSystem.write(Data([1]), to: Self.bin, mode: .truncate)
        #expect(throws: FileSystemError.noSpace) { try fileSystem.write(Data([2]), to: Self.tmp, mode: .truncate) }
        try fileSystem.write(Data([3]), to: Self.tmp, mode: .truncate)
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp") == [3])
        #expect(fileSystem.operations.compactMap(\.failure) == [.noSpace])
    }

    @available(macOS 15.0, *)
    @Test("Test support: a partial write lands its first bytes, then throws, and later writes succeed")
    func partialWriteLandsPrefix() throws {
        let fileSystem = FakeFSFixture.make()
        fileSystem.addFault(FaultRule(operation: .write, occurrence: .nth(1), error: .noSpace, partialBytes: 3))
        #expect(throws: FileSystemError.noSpace) { try fileSystem.write(Data([1, 2, 3, 4, 5]), to: Self.tmp, mode: .truncate) }
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp") == [1, 2, 3])
        try fileSystem.write(Data([6]), to: Self.tmp, mode: .append)
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp") == [1, 2, 3, 6])
    }

    @available(macOS 15.0, *)
    @Test("Test support: a write fault fails after the open: a truncating write keeps only what landed, an appending one creates the file")
    func faultedWriteHasOpenedTheFile() throws {
        let fileSystem = FakeFSFixture.make()
        let part = FakeFSFixture.url("/fake-volume/x.part")
        try fileSystem.write(Data([1, 2, 3, 4]), to: Self.tmp, mode: .truncate)
        fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: ".tmp"), occurrence: .nth(1), error: .io))
        fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: ".part"), occurrence: .nth(1), error: .noSpace))
        #expect(throws: FileSystemError.io) { try fileSystem.write(Data([5, 6]), to: Self.tmp, mode: .truncate) }
        #expect(throws: FileSystemError.noSpace) { try fileSystem.write(Data([7]), to: part, mode: .append) }
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp") == [])
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/x.part") == [])
    }

    /// store.md §3.4 / F19: before the first unlock `open(2)` fails with EACCES and nothing is mutated, so an
    /// open-time error must not create, truncate or partly write the file, whatever `partialBytes` says.
    @available(macOS 15.0, *)
    @Test(
        "Test support: a write fault with an open-time error (EACCES, ENOENT, EISDIR, ENOTDIR) fails before the open and changes nothing",
        arguments: [FileSystemError.permissionDenied, .notFound, .other(errno: EACCES), .other(errno: EISDIR), .other(errno: ENOTDIR)]
    )
    func openTimeWriteFaultChangesNothing(error: FileSystemError) throws {
        let fileSystem = FakeFSFixture.make(important: 1_000)
        let part = FakeFSFixture.url("/fake-volume/x.part")
        try fileSystem.write(Data([1, 2, 3, 4]), to: Self.tmp, mode: .truncate)
        let before = fileSystem.survivingDisk()
        fileSystem.addFault(FaultRule(operation: .write, occurrence: .every, error: error, partialBytes: 2))
        #expect(throws: error) { try fileSystem.write(Data([5, 6, 7]), to: Self.tmp, mode: .truncate) }
        #expect(throws: error) { try fileSystem.write(Data([8, 9, 10]), to: Self.tmp, mode: .append) }
        #expect(throws: error) { try fileSystem.write(Data([7, 7, 7]), to: part, mode: .append) }
        #expect(fileSystem.survivingDisk() == before)
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp") == [1, 2, 3, 4])
        #expect(try fileSystem.itemInfo(at: part) == nil)
        #expect(try fileSystem.availableCapacity(at: FakeFSFixture.volume, for: .important) == 996)
    }

    @available(macOS 15.0, *)
    @Test("Test support: an afterBytes rule truncates the write that crosses the threshold and fails every later write")
    func afterBytesIsAShortWrite() throws {
        let fileSystem = FakeFSFixture.make()
        let part = FakeFSFixture.url("/fake-volume/x.part")
        fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: ".part"), occurrence: .afterBytes(5), error: .io))
        try fileSystem.write(Data([1, 2, 3]), to: part, mode: .append)
        #expect(throws: FileSystemError.io) { try fileSystem.write(Data([4, 5, 6, 7]), to: part, mode: .append) }
        #expect(throws: FileSystemError.io) { try fileSystem.write(Data([8]), to: part, mode: .append) }
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/x.part") == [1, 2, 3, 4, 5])
        try fileSystem.write(Data([1, 2, 3, 4, 5, 6]), to: Self.tmp, mode: .truncate)
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp")?.count == 6)
    }

    @available(macOS 15.0, *)
    @Test(
        "Test support: an every rule throws its error on each matching call and leaves the item untouched",
        arguments: [FileSystemError.io, .crossDevice, .permissionDenied]
    )
    func everyRuleOnRename(error: FileSystemError) throws {
        let fileSystem = FakeFSFixture.make()
        try fileSystem.write(Data([1]), to: Self.tmp, mode: .truncate)
        fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(pathContains: "/fake-volume/"), occurrence: .every, error: error))
        for _ in 0..<2 {
            #expect(throws: error) { try fileSystem.rename(from: Self.tmp, to: Self.bin, mode: .replacing) }
        }
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp") == [1])
        #expect(try fileSystem.itemInfo(at: Self.bin) == nil)
        #expect(fileSystem.operations.filter { $0.kind == .rename }.map(\.failure) == [error, error])
    }

    @available(macOS 15.0, *)
    @Test("Test support: EACCES on createDirectory models protected data before the first unlock")
    func permissionDeniedOnCreate() {
        let fileSystem = FakeFSFixture.make()
        let root = FakeFSFixture.url("/fake-volume/Library/Application Support/ZTronAssetKit")
        fileSystem.addFault(FaultRule(operation: .createDirectory, matching: URLMatcher(lastComponentSuffix: "ZTronAssetKit"), occurrence: .every, error: .permissionDenied))
        #expect(throws: FileSystemError.permissionDenied) { try fileSystem.createDirectory(at: root) }
        #expect((try? fileSystem.itemInfo(at: root)) == .some(nil))
    }

    @available(macOS 15.0, *)
    @Test("Test support: faults apply to queries too, and a rule for another operation never fires")
    func faultsOnQueries() throws {
        let fileSystem = FakeFSFixture.make()
        try fileSystem.write(Data([5]), to: Self.tmp, mode: .truncate)
        fileSystem.addFault(FaultRule(operation: .read, occurrence: .nth(1), error: .io))
        fileSystem.addFault(FaultRule(operation: .removeItem, occurrence: .every, error: .io))
        fileSystem.addFault(FaultRule(operation: .itemInfo, matching: URLMatcher(pathContains: "/blobs/"), occurrence: .every, error: .io))
        #expect(throws: FileSystemError.io) { try fileSystem.read(from: Self.tmp, offset: 0, maxLength: 1) }
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp") == [5])
        #expect(try fileSystem.itemInfo(at: Self.tmp)?.byteSize == 1)
    }

    @available(macOS 15.0, *)
    @Test("Test support: free space falls with the bytes a lifetime writes and rises with the bytes it removes")
    func capacityFollowsUsage() throws {
        let fileSystem = FakeFSFixture.make(important: 1_000, opportunistic: 600)
        #expect(try fileSystem.availableCapacity(at: FakeFSFixture.volume, for: .important) == 1_000)
        try fileSystem.write(Data(count: 300), to: Self.tmp, mode: .truncate)
        #expect(try fileSystem.availableCapacity(at: FakeFSFixture.volume, for: .important) == 700)
        #expect(try fileSystem.availableCapacity(at: FakeFSFixture.volume, for: .opportunistic) == 300)
        try fileSystem.rename(from: Self.tmp, to: Self.bin, mode: .replacing)
        #expect(try fileSystem.availableCapacity(at: FakeFSFixture.volume, for: .important) == 700)
        try fileSystem.removeItem(at: Self.bin)
        #expect(try fileSystem.availableCapacity(at: FakeFSFixture.volume, for: .important) == 1_000)

        let next = FakeFSFixture.make(fileSystem.survivingDisk(), important: 50)
        #expect(try next.availableCapacity(at: FakeFSFixture.volume, for: .important) == 50)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a write that does not fit lands what fits and throws noSpace")
    func fullVolumeIsAShortWrite() throws {
        let fileSystem = FakeFSFixture.make(important: 10, opportunistic: 10)
        try fileSystem.write(Data(repeating: 1, count: 6), to: Self.tmp, mode: .append)
        #expect(throws: FileSystemError.noSpace) { try fileSystem.write(Data(repeating: 2, count: 6), to: Self.tmp, mode: .append) }
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/index.tmp") == [1, 1, 1, 1, 1, 1, 2, 2, 2, 2])
        #expect(try fileSystem.availableCapacity(at: FakeFSFixture.volume, for: .opportunistic) == 0)
        try fileSystem.write(Data([3]), to: Self.tmp, mode: .truncate)
        #expect(try fileSystem.availableCapacity(at: FakeFSFixture.volume, for: .important) == 9)
    }
}
