import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// Recording (R-STO-7 calling thread, R-STO-8 attributes), locks (R-STO-9), the namespace and disk images.
@Suite("Test support: FakeFileSystem recording and namespace")
struct TestSupportFakeFileSystemTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: every call records whether it ran on the main thread", .timeLimit(.minutes(1)))
    func recordsCallingThread() async throws {
        let fileSystem = FakeFSFixture.make()
        _ = try fileSystem.itemInfo(at: FakeFSFixture.volume)
        await MainActor.run {
            _ = try? fileSystem.contentsOfDirectory(at: FakeFSFixture.volume)
        }
        #expect(fileSystem.mainThreadCalls == 1)
        #expect(fileSystem.operations.map(\.isMainThread) == [false, true])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: applied attributes are recorded by path and read back in the next lifetime")
    func attributesAreRecorded() throws {
        let fileSystem = FakeFSFixture.make()
        let root = FakeFSFixture.url("/fake-volume/root")
        try fileSystem.createDirectory(at: root)
        #expect(try fileSystem.storeAttributes(at: root) == StoreAttributes(excludedFromBackup: false, protection: nil))
        try fileSystem.applyStoreAttributes(.storeDefault, at: root)
        #expect(fileSystem.appliedAttributes == ["/fake-volume/root": .storeDefault])
        #expect(try fileSystem.storeAttributes(at: root) == .storeDefault)

        let next = FakeFFSLifetime.next(fileSystem.survivingDisk())
        #expect(try next.storeAttributes(at: root) == .storeDefault)
        #expect(throws: FileSystemError.notFound) { try next.storeAttributes(at: root.appendingPathComponent("absent")) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a held lock blocks every other holder until released and its token names the lock file")
    func lockBlocksOtherHolders() throws {
        let fileSystem = FakeFSFixture.make()
        let lock = FakeFSFixture.url("/fake-volume/store.lock")
        let token = try fileSystem.acquireExclusiveLock(at: lock)
        #expect(try fileSystem.itemInfo(at: lock)?.identity == token.identity)
        #expect(throws: FileSystemError.wouldBlock) { try fileSystem.acquireExclusiveLock(at: lock) }
        fileSystem.releaseLock(token)
        let again = try fileSystem.acquireExclusiveLock(at: lock)
        fileSystem.releaseLock(token)  // a stale token releases nothing
        #expect(throws: FileSystemError.wouldBlock) { try fileSystem.acquireExclusiveLock(at: lock) }
        fileSystem.releaseLock(again)
        let releases = fileSystem.operations.filter { $0.kind == .releaseLock }
        #expect(releases.count == 3)
        #expect(releases.allSatisfy { $0.url.path == "/fake-volume/store.lock" })
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a replaced lock file has a new identity, which is how a replaced root is detected")
    func replacedLockFileChangesIdentity() throws {
        let fileSystem = FakeFSFixture.make()
        let lock = FakeFSFixture.url("/fake-volume/store.lock")
        let token = try fileSystem.acquireExclusiveLock(at: lock)
        try fileSystem.removeItem(at: lock)
        try fileSystem.write(Data(), to: lock, mode: .truncate)
        let identity = try #require(try fileSystem.itemInfo(at: lock)?.identity)
        #expect(identity != token.identity)
        #expect(throws: Never.self) { _ = try fileSystem.acquireExclusiveLock(at: lock) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: standard directories resolve to existing directories under the configured volume root")
    func standardDirectoriesExist() throws {
        let volume = URL(fileURLWithPath: "/other-volume", isDirectory: true)
        let fileSystem = FakeFileSystem(time: ManualTimeSource(), configuration: FakeFileSystemConfiguration(volumeRoot: volume))
        let support = try fileSystem.standardDirectory(.applicationSupport)
        let caches = try fileSystem.standardDirectory(.caches)
        #expect(support.path == "/other-volume/Library/Application Support")
        #expect(caches.path == "/other-volume/Library/Caches")
        #expect(try fileSystem.itemInfo(at: support)?.kind == .directory)
        #expect(try fileSystem.itemInfo(at: caches)?.kind == .directory)
        #expect(FakeFSFixture.powerLoss(fileSystem.survivingDisk()).directories.contains("/other-volume/Library/Caches"))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: listings come in descending name order, never the ascending order code might rely on, with sizes, kinds and modification times")
    func listingsAreInDescendingOrder() throws {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let directory = FakeFSFixture.url("/fake-volume/d")
        try fileSystem.createDirectory(at: directory)
        try fileSystem.write(Data([1, 2]), to: directory.appendingPathComponent("c.bin"), mode: .truncate)
        time.advance(by: 5)
        try fileSystem.write(Data([1]), to: directory.appendingPathComponent("a.bin"), mode: .truncate)
        try fileSystem.createDirectory(at: directory.appendingPathComponent("b"))
        let listing = try fileSystem.contentsOfDirectory(at: directory)
        #expect(listing.map(\.name) == ["c.bin", "b", "a.bin"])
        #expect(listing.map(\.kind) == [.file, .directory, .file])
        #expect(listing.map(\.byteSize) == [2, 0, 1])
        #expect(listing[0].modifiedAt == time.now().addingTimeInterval(-5))
        #expect(listing[2].modifiedAt == time.now())
        #expect(throws: FileSystemError.other(errno: ENOTDIR)) { try fileSystem.contentsOfDirectory(at: directory.appendingPathComponent("a.bin")) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: an intermediate symbolic link is followed, a final one only by reads and writes")
    func symbolicLinks() throws {
        let fileSystem = FakeFSFixture.make()
        let real = FakeFSFixture.url("/fake-volume/real")
        try fileSystem.createDirectory(at: real)
        try fileSystem.write(Data([4]), to: real.appendingPathComponent("x.bin"), mode: .truncate)
        try fileSystem.createSymbolicLink(at: FakeFSFixture.url("/fake-volume/alias"), destination: "/fake-volume/real")
        try fileSystem.createSymbolicLink(at: real.appendingPathComponent("l.bin"), destination: "x.bin")

        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/alias/x.bin") == [4])
        #expect(try fileSystem.itemInfo(at: FakeFSFixture.url("/fake-volume/alias"))?.kind == .symbolicLink)
        #expect(try fileSystem.itemInfo(at: FakeFSFixture.url("/fake-volume/alias"))?.byteSize == Int64("/fake-volume/real".utf8.count))
        try fileSystem.write(Data([5]), to: real.appendingPathComponent("l.bin"), mode: .append)
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/real/x.bin") == [4, 5])
        try fileSystem.rename(from: real.appendingPathComponent("l.bin"), to: real.appendingPathComponent("m.bin"), mode: .exclusive)
        #expect(try fileSystem.itemInfo(at: real.appendingPathComponent("m.bin"))?.kind == .symbolicLink)
        #expect(throws: FileSystemError.alreadyExists) {
            try fileSystem.createSymbolicLink(at: real.appendingPathComponent("m.bin"), destination: "x.bin")
        }
        let disk = fileSystem.survivingDisk()
        #expect(FakeFFSLifetime.next(disk).survivingDisk() == disk)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a relative link target resolves against the link's directory, with . and .. applied")
    func relativeLinkTargets() throws {
        let fileSystem = FakeFSFixture.make()
        let real = FakeFSFixture.url("/fake-volume/real")
        try fileSystem.createDirectory(at: real)
        try fileSystem.createDirectory(at: real.appendingPathComponent("sub"))
        try fileSystem.write(Data([6]), to: real.appendingPathComponent("x.bin"), mode: .truncate)
        try fileSystem.createSymbolicLink(at: real.appendingPathComponent("sub/up.bin"), destination: "./../x.bin")
        try fileSystem.createSymbolicLink(at: FakeFSFixture.url("/fake-volume/top"), destination: "../../fake-volume/real/sub")
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/real/sub/up.bin") == [6])
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/top/up.bin") == [6])
        #expect(throws: FileSystemError.other(errno: EINVAL)) { try fileSystem.createSymbolicLink(at: FakeFSFixture.url("/"), destination: "x") }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a file a power loss left under two names is one file: unlinking one name keeps the other")
    func powerLossHardLinks() throws {
        let fileSystem = FakeFSFixture.make(important: 1_000)
        let source = FakeFSFixture.url("/fake-volume/s")
        let destination = FakeFSFixture.url("/fake-volume/t")
        for directory in [source, destination] {
            try fileSystem.createDirectory(at: directory)
        }
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.volume, level: .barrier)
        try fileSystem.write(Data(repeating: 1, count: 100), to: source.appendingPathComponent("f"), mode: .truncate)
        try fileSystem.synchronizeFile(at: source.appendingPathComponent("f"), level: .barrier)
        try fileSystem.synchronizeDirectory(at: source, level: .barrier)
        try fileSystem.rename(from: source.appendingPathComponent("f"), to: destination.appendingPathComponent("f"), mode: .exclusive)
        try fileSystem.synchronizeDirectory(at: destination, level: .barrier)

        let next = FakeFileSystem(
            disk: FakeFSFixture.powerLoss(fileSystem.survivingDisk()),
            time: ManualTimeSource(),
            configuration: FakeFileSystemConfiguration(importantCapacity: 1_000)
        )
        try next.rename(from: source.appendingPathComponent("f"), to: destination.appendingPathComponent("f"), mode: .replacing)
        #expect(FakeFSFixture.content(next, "/fake-volume/s/f")?.count == 100)
        try next.removeItem(at: source.appendingPathComponent("f"))
        #expect(try next.availableCapacity(at: FakeFSFixture.volume, for: .important) == 1_000)
        #expect(FakeFSFixture.content(next, "/fake-volume/t/f")?.count == 100)
        try next.removeItem(at: destination.appendingPathComponent("f"))
        #expect(try next.availableCapacity(at: FakeFSFixture.volume, for: .important) == 1_100)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a hand-edited disk keeps its symbolic links and attributes")
    func editedDiskKeepsLinksAndAttributes() throws {
        let fileSystem = FakeFSFixture.make()
        let root = FakeFSFixture.url("/fake-volume/root")
        try fileSystem.createDirectory(at: root)
        try fileSystem.applyStoreAttributes(.storeDefault, at: root)
        try fileSystem.write(Data([1]), to: root.appendingPathComponent("a"), mode: .truncate)
        try fileSystem.createSymbolicLink(at: root.appendingPathComponent("durable-link"), destination: "a")
        try fileSystem.createSymbolicLink(at: FakeFSFixture.url("/fake-volume/ghost-link"), destination: "root")
        try fileSystem.createSymbolicLink(at: FakeFSFixture.url("/fake-volume/kept-link"), destination: "root")
        try fileSystem.removeItem(at: FakeFSFixture.url("/fake-volume/ghost-link"))
        var image = fileSystem.survivingDisk()
        image.files["/fake-volume/root/b"] = [2]

        let next = FakeFFSLifetime.next(image)
        #expect(try next.itemInfo(at: root.appendingPathComponent("durable-link"))?.kind == .symbolicLink)
        #expect(FakeFSFixture.content(next, "/fake-volume/root/durable-link") == [1])
        #expect(FakeFSFixture.content(next, "/fake-volume/root/b") == [2])
        #expect(try next.storeAttributes(at: root) == .storeDefault)
        #expect(try next.itemInfo(at: FakeFSFixture.url("/fake-volume/ghost-link")) == nil)
        #expect(FakeFSFixture.content(next, "/fake-volume/kept-link/a") == [1])
        let afterPowerLoss = FakeFSFixture.powerLoss(next.survivingDisk())
        #expect(FakeFFSLifetime.next(afterPowerLoss).survivingDisk() == afterPowerLoss)
        #expect(try FakeFFSLifetime.next(afterPowerLoss).itemInfo(at: FakeFSFixture.url("/fake-volume/ghost-link"))?.kind == .symbolicLink)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a cycle of symbolic links fails with ELOOP instead of looping")
    func linkLoopsFail() throws {
        let fileSystem = FakeFSFixture.make()
        try fileSystem.createSymbolicLink(at: FakeFSFixture.url("/fake-volume/a"), destination: "b")
        try fileSystem.createSymbolicLink(at: FakeFSFixture.url("/fake-volume/b"), destination: "a")
        #expect(throws: FileSystemError.other(errno: ELOOP)) { try fileSystem.read(from: FakeFSFixture.url("/fake-volume/a"), offset: 0, maxLength: 1) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: renames refuse to move a directory into itself or onto a non-empty directory")
    func directoryRenames() throws {
        let fileSystem = FakeFSFixture.make()
        let a = FakeFSFixture.url("/fake-volume/a")
        let b = FakeFSFixture.url("/fake-volume/b")
        try fileSystem.createDirectory(at: a)
        try fileSystem.createDirectory(at: b)
        try fileSystem.write(Data([1]), to: b.appendingPathComponent("f"), mode: .truncate)
        #expect(throws: FileSystemError.other(errno: EINVAL)) { try fileSystem.rename(from: a, to: a.appendingPathComponent("inner"), mode: .replacing) }
        try fileSystem.createDirectory(at: a.appendingPathComponent("x"))
        try fileSystem.createDirectory(at: a.appendingPathComponent("x/y"))
        #expect(throws: FileSystemError.other(errno: EINVAL)) { try fileSystem.rename(from: a, to: a.appendingPathComponent("x/y/z"), mode: .replacing) }
        #expect(throws: FileSystemError.other(errno: EINVAL)) { try fileSystem.rename(from: FakeFSFixture.url("/"), to: b, mode: .replacing) }
        #expect(throws: FileSystemError.notEmpty) { try fileSystem.rename(from: a, to: b, mode: .replacing) }
        #expect(throws: FileSystemError.other(errno: EISDIR)) { try fileSystem.rename(from: b.appendingPathComponent("f"), to: a, mode: .replacing) }
        #expect(throws: FileSystemError.other(errno: ENOTDIR)) { try fileSystem.rename(from: a, to: b.appendingPathComponent("f"), mode: .replacing) }
        try fileSystem.rename(from: b, to: FakeFSFixture.url("/fake-volume/c"), mode: .exclusive)
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/c/f") == [1])
        try fileSystem.rename(from: a, to: a, mode: .exclusive)
        #expect(try fileSystem.itemInfo(at: a)?.kind == .directory)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: misuse of the seam is reported as an error: oversized reads, relative URLs, directories as files")
    func misuseIsReported() throws {
        let fileSystem = FakeFSFixture.make()
        let file = FakeFSFixture.url("/fake-volume/f.bin")
        try fileSystem.write(Data([1]), to: file, mode: .truncate)
        #expect(throws: FileSystemError.other(errno: EINVAL)) { try fileSystem.read(from: file, offset: 0, maxLength: (1 << 20) + 1) }
        #expect(throws: FileSystemError.other(errno: EINVAL)) { try fileSystem.read(from: file, offset: -1, maxLength: 1) }
        #expect(throws: FileSystemError.other(errno: EINVAL)) { try fileSystem.itemInfo(at: URL(string: "https://example.com/f")!) }
        #expect(throws: FileSystemError.other(errno: EISDIR)) { try fileSystem.read(from: FakeFSFixture.volume, offset: 0, maxLength: 1) }
        #expect(throws: FileSystemError.other(errno: EISDIR)) { try fileSystem.write(Data([1]), to: FakeFSFixture.volume, mode: .append) }
        #expect(throws: FileSystemError.other(errno: ENOTDIR)) { try fileSystem.synchronizeDirectory(at: file, level: .barrier) }
        #expect(throws: FileSystemError.other(errno: ENOTDIR)) { try fileSystem.write(Data([1]), to: file.appendingPathComponent("x"), mode: .truncate) }
        #expect(throws: FileSystemError.permissionDenied) { try fileSystem.removeItem(at: FakeFSFixture.url("/")) }
        #expect(throws: FileSystemError.other(errno: EISDIR)) { try fileSystem.acquireExclusiveLock(at: FakeFSFixture.volume) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: disk digests are equal for equal trees and change with any path or byte")
    func digestsFollowContent() throws {
        let first = FakeFSFixture.make()
        let second = FakeFSFixture.make()
        for fileSystem in [first, second] {
            try fileSystem.createDirectory(at: FakeFSFixture.url("/fake-volume/d"))
            try fileSystem.write(Data([1, 2]), to: FakeFSFixture.url("/fake-volume/d/f"), mode: .truncate)
        }
        #expect(first.survivingDisk().digest() == second.survivingDisk().digest())
        #expect(first.survivingDisk() == second.survivingDisk())

        try second.write(Data([3]), to: FakeFSFixture.url("/fake-volume/d/f"), mode: .truncate)
        #expect(first.survivingDisk().digest() != second.survivingDisk().digest())
        try first.rename(from: FakeFSFixture.url("/fake-volume/d/f"), to: FakeFSFixture.url("/fake-volume/d/g"), mode: .exclusive)
        let renamed = first.survivingDisk()
        #expect(renamed.digest() != FakeFSFixture.make().survivingDisk().digest())
        #expect(renamed.paths.contains("/fake-volume/d/g"))
        try first.createSymbolicLink(at: FakeFSFixture.url("/fake-volume/d/l"), destination: "g")
        #expect(first.survivingDisk().digest() != renamed.digest())
        #expect(Set([renamed, renamed]).count == 1)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: makeDurable lets a seeded disk survive a power loss in its first lifetime")
    func makeDurableSeedsSurvive() throws {
        var seeded = DiskImage()
        seeded.files["/fake-volume/legacy/a/b.png"] = [1, 2]
        seeded.directories.insert("/fake-volume/legacy")
        #expect(FakeFSFixture.powerLoss(seeded).files["/fake-volume/legacy/a/b.png"] == nil)
        seeded.makeDurable()
        #expect(FakeFSFixture.powerLoss(seeded).files["/fake-volume/legacy/a/b.png"] == [1, 2])
        #expect(FakeFSFixture.powerLoss(seeded).directories.contains("/fake-volume/legacy/a"))

        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        try fileSystem.createDirectory(at: FakeFSFixture.url("/fake-volume/s"))
        try fileSystem.write(Data([7]), to: FakeFSFixture.url("/fake-volume/s/f"), mode: .truncate)
        time.advance(by: 100)
        var image = fileSystem.survivingDisk()
        image.makeDurable()
        let next = FakeFileSystem(disk: image, time: time)
        #expect(try next.itemInfo(at: FakeFSFixture.url("/fake-volume/s/f"))?.modifiedAt == time.now().addingTimeInterval(-100))
        #expect(FakeFSFixture.powerLoss(image).files["/fake-volume/s/f"] == [7])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a hand-edited disk loads with the edit and keeps the durability of every untouched file")
    func editedDiskKeepsUntouchedDurability() throws {
        let fileSystem = FakeFSFixture.make()
        let directory = FakeFSFixture.url("/fake-volume/blobs")
        try fileSystem.createDirectory(at: directory)
        for name in ["a", "b"] {
            let staged = FakeFSFixture.url("/fake-volume/\(name).part")
            try fileSystem.write(Data([1, 2, 3]), to: staged, mode: .truncate)
            try fileSystem.synchronizeFile(at: staged, level: .barrier)
            try fileSystem.rename(from: staged, to: directory.appendingPathComponent(name), mode: .exclusive)
        }
        var image = fileSystem.survivingDisk()
        image.files.removeValue(forKey: "/fake-volume/blobs/a")  // a current-namespace removal between launches

        let next = FakeFFSLifetime.next(image)
        #expect(try next.itemInfo(at: directory.appendingPathComponent("a")) == nil)
        let afterPowerLoss = FakeFSFixture.powerLoss(next.survivingDisk(), .powerLossKeepMetadata)
        #expect(afterPowerLoss.files["/fake-volume/blobs/b"] == [1, 2, 3])
        #expect(afterPowerLoss.files["/fake-volume/blobs/a"] == nil)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a seeded file whose parent directories are not listed gets them, and a seeded durable-only file returns on power loss")
    func seededImagesAreLenient() throws {
        var seeded = DiskImage()
        seeded.files["/fake-volume/x/y/z.bin"] = [8]
        seeded.durableFiles["/fake-volume/gone.bin"] = [9]
        seeded.durableDirectories.insert("/fake-volume/ghost")
        let fileSystem = FakeFFSLifetime.next(seeded)
        #expect(try fileSystem.itemInfo(at: FakeFSFixture.url("/fake-volume/x/y"))?.kind == .directory)
        #expect(FakeFSFixture.content(fileSystem, "/fake-volume/x/y/z.bin") == [8])
        #expect(try fileSystem.itemInfo(at: FakeFSFixture.url("/fake-volume/gone.bin")) == nil)
        let disk = FakeFSFixture.powerLoss(seeded)
        #expect(disk.files["/fake-volume/gone.bin"] == [9])
        #expect(disk.directories.contains("/fake-volume/ghost"))
        #expect(disk.files["/fake-volume/x/y/z.bin"] == nil)
    }
}
