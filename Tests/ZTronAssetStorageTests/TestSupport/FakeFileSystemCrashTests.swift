import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// Deterministic, enumerable crash points (R-STO-5's machinery): mutation k never happens, every later call fails,
/// and the same k and mode always leave the same disk.
@Suite("Test support: FakeFileSystem crash points")
struct FakeFileSystemCrashTests {
    private static let root = "/fake-volume/Library/Application Support/ZTronAssetKit"

    /// A store-shaped scenario: layout, lock, a published blob, an index commit and a staging cleanup. Every step is
    /// attempted whatever the previous one did, so a crash run issues the same calls as a clean run.
    @available(macOS 15.0, *)
    private static func scenario(_ fileSystem: FakeFileSystem) {
        let root = FakeFSFixture.url(Self.root)
        let blobs = root.appendingPathComponent("blobs")
        let staging = root.appendingPathComponent("staging")
        let part = staging.appendingPathComponent("c-1.1-1.part")
        let fanOut = blobs.appendingPathComponent("ab")
        let blob = fanOut.appendingPathComponent("ab12.png")
        _ = try? fileSystem.itemInfo(at: root)
        try? fileSystem.createDirectory(at: root)
        try? fileSystem.synchronizeDirectory(at: root.deletingLastPathComponent(), level: .barrier)
        _ = try? fileSystem.acquireExclusiveLock(at: root.appendingPathComponent("store.lock"))
        try? fileSystem.createDirectory(at: blobs)
        try? fileSystem.createDirectory(at: staging)
        try? fileSystem.write(Data(repeating: 1, count: 6), to: part, mode: .append)
        try? fileSystem.write(Data(repeating: 2, count: 4), to: part, mode: .append)
        _ = try? fileSystem.read(from: part, offset: 0, maxLength: 1 << 20)
        try? fileSystem.synchronizeFile(at: part, level: .barrier)
        try? fileSystem.createDirectory(at: fanOut)
        try? fileSystem.rename(from: part, to: blob, mode: .exclusive)
        try? fileSystem.synchronizeDirectory(at: fanOut, level: .barrier)
        try? fileSystem.synchronizeDirectory(at: blobs, level: .barrier)
        try? fileSystem.write(Data([9, 9, 9]), to: root.appendingPathComponent("index.tmp"), mode: .truncate)
        try? fileSystem.synchronizeFile(at: root.appendingPathComponent("index.tmp"), level: .full)
        try? fileSystem.rename(from: root.appendingPathComponent("index.bin"), to: root.appendingPathComponent("index.prev"), mode: .replacing)
        try? fileSystem.rename(from: root.appendingPathComponent("index.tmp"), to: root.appendingPathComponent("index.bin"), mode: .replacing)
        try? fileSystem.synchronizeDirectory(at: root, level: .barrier)
        try? fileSystem.removeItem(at: staging.appendingPathComponent("foreign.part"))
    }

    private struct Call: Hashable {
        var kind: FSOpKind
        var path: String
        var destination: String?
    }

    @available(macOS 15.0, *)
    private static func calls(_ fileSystem: FakeFileSystem) -> [Call] {
        fileSystem.operations.map { Call(kind: $0.kind, path: $0.url.path, destination: $0.destination?.path) }
    }

    @available(macOS 15.0, *)
    @Test("Test support: crash enumeration is deterministic: every crash point and mode repeats the clean run's prefix and its disk")
    func crashEnumerationIsDeterministic() {
        let clean = FakeFSFixture.make()
        Self.scenario(clean)
        let cleanCalls = Self.calls(clean)
        let mutations = clean.mutationCount
        #expect(mutations == cleanCalls.filter { $0.kind.isMutation }.count)
        #expect(!clean.crashed)

        for mode in CrashMode.allCases {
            for k in 0...mutations {
                let first = FakeFSFixture.make(crashBefore: k, mode: mode)
                let second = FakeFSFixture.make(crashBefore: k, mode: mode)
                Self.scenario(first)
                Self.scenario(second)
                #expect(Self.calls(first) == cleanCalls, "k=\(k) mode=\(mode)")
                #expect(first.crashed == (k < mutations), "k=\(k) mode=\(mode)")
                #expect(first.mutationCount == min(k, mutations), "k=\(k) mode=\(mode)")
                #expect(first.survivingDisk() == second.survivingDisk(), "k=\(k) mode=\(mode)")
                #expect(first.survivingDisk().digest() == second.survivingDisk().digest(), "k=\(k) mode=\(mode)")
                let crashIndex = first.operations.firstIndex { $0.failure == .io }
                if k < mutations, let crashIndex {
                    #expect(first.operations[crashIndex].kind.isMutation, "k=\(k) mode=\(mode)")
                    #expect(first.operations[crashIndex...].allSatisfy { $0.failure == .io || $0.kind == .releaseLock }, "k=\(k)")
                }
            }
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: the mutation a crash point names never happens and every later call throws EIO")
    func crashPointStopsTheLifetime() {
        let fileSystem = FakeFSFixture.make(crashBefore: 1)
        let a = FakeFSFixture.url("/fake-volume/a")
        let b = FakeFSFixture.url("/fake-volume/b")
        #expect(throws: Never.self) { try fileSystem.createDirectory(at: a) }
        #expect(throws: FileSystemError.io) { try fileSystem.createDirectory(at: b) }
        #expect(throws: FileSystemError.io) { try fileSystem.itemInfo(at: a) }
        #expect(throws: FileSystemError.io) { try fileSystem.write(Data([1]), to: a.appendingPathComponent("f"), mode: .truncate) }
        #expect(fileSystem.crashed)
        #expect(fileSystem.mutationCount == 1)
        let disk = fileSystem.survivingDisk()
        #expect(disk.directories.contains("/fake-volume/a"))
        #expect(!disk.directories.contains("/fake-volume/b"))
    }

    @available(macOS 15.0, *)
    @Test("Test support: queries are not crash points and failed mutations still consume their crash-point index")
    func mutationsAreNumberedInCallOrder() {
        let fileSystem = FakeFSFixture.make()
        _ = try? fileSystem.itemInfo(at: FakeFSFixture.volume)
        _ = try? fileSystem.contentsOfDirectory(at: FakeFSFixture.volume)
        try? fileSystem.rename(from: FakeFSFixture.url("/fake-volume/missing"), to: FakeFSFixture.url("/fake-volume/x"), mode: .replacing)
        try? fileSystem.createDirectory(at: FakeFSFixture.url("/fake-volume/d"))
        #expect(fileSystem.mutationCount == 2)
        let log = fileSystem.operations
        #expect(log.map(\.kind) == [.itemInfo, .contentsOfDirectory, .rename, .createDirectory])
        #expect(log.map(\.index) == [0, 1, 2, 3])
        #expect(log[2].failure == .notFound)
        #expect(log[2].destination?.path == "/fake-volume/x")
        #expect(log[3].failure == nil)

        let crashOnFailedRename = FakeFSFixture.make(crashBefore: 1)
        try? crashOnFailedRename.rename(from: FakeFSFixture.url("/fake-volume/missing"), to: FakeFSFixture.url("/fake-volume/x"), mode: .replacing)
        try? crashOnFailedRename.createDirectory(at: FakeFSFixture.url("/fake-volume/d"))
        #expect(crashOnFailedRename.crashed)
        #expect(!crashOnFailedRename.survivingDisk().directories.contains("/fake-volume/d"))
    }

    @available(macOS 15.0, *)
    @Test("Test support: a torn write lands half the crashing write's bytes, and a torn crash elsewhere equals a process kill")
    func tornWriteLandsHalf() throws {
        let file = FakeFSFixture.url("/fake-volume/index.tmp")
        let torn = FakeFSFixture.make(crashBefore: 1, mode: .processKillTornWrite)
        try torn.write(Data([1, 2]), to: file, mode: .truncate)
        #expect(throws: FileSystemError.io) { try torn.write(Data([3, 4, 5, 6, 7]), to: file, mode: .append) }
        #expect(torn.survivingDisk().files["/fake-volume/index.tmp"] == [1, 2, 3, 4])

        let tornElsewhere = FakeFSFixture.make(crashBefore: 1, mode: .processKillTornWrite)
        let killed = FakeFSFixture.make(crashBefore: 1, mode: .processKill)
        for fileSystem in [tornElsewhere, killed] {
            try fileSystem.write(Data([1, 2]), to: file, mode: .truncate)
            #expect(throws: FileSystemError.io) { try fileSystem.synchronizeFile(at: file, level: .barrier) }
        }
        #expect(tornElsewhere.survivingDisk() == killed.survivingDisk())
    }

    @available(macOS 15.0, *)
    @Test("Test support: a process kill releases every lock, so the next lifetime takes the lock again")
    func crashReleasesLocks() throws {
        let lock = FakeFSFixture.url("/fake-volume/store.lock")
        let first = FakeFSFixture.make(crashBefore: 1)
        _ = try first.acquireExclusiveLock(at: lock)
        #expect(throws: FileSystemError.io) { try first.createDirectory(at: FakeFSFixture.url("/fake-volume/d")) }
        let next = FakeFFSLifetime.next(first.survivingDisk())
        #expect(throws: Never.self) { _ = try next.acquireExclusiveLock(at: lock) }
    }
}
