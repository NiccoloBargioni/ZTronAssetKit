import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetTestSupport

/// Editing a `DiskImage` between lifetimes (seeding, OS purges, corruption): the edit lands path by path on the exact
/// inode graph the disk carries, so every path the edit did not touch keeps what only a crash or a power loss can
/// reveal (store-1 S1-01, R-CLN-7).
@Suite("Test support: DiskImage edits")
struct TestSupportDiskImageEditTests {
    private static let work = "/fake-volume/work"

    /// One kind of hand edit a test makes to a disk between two lifetimes.
    enum Edit: String, CaseIterable, Sendable {
        case addFile
        case addFileInNewDirectories
        case removeFile
        case rewriteFile
        case removeDirectory
        case fileBecomesDirectory
        case addDurableFile
        case addDurableDirectory
        case addFileDurably
        case removeDurableFile
        case rewriteDurableFile
        case addLink
        case addLinkDurably
        case addDurableLink
        case retargetLink
        case removeDurableLink
        case addAttributes
        case removeAttributes
        case rewriteOneOfTwoNames
        case purge

        func apply(to image: inout DiskImage) {
            let work = TestSupportDiskImageEditTests.work
            switch self {
            case .addFile:
                image.files[work + "/n.bin"] = [4]
            case .addFileInNewDirectories:
                image.files[work + "/new/deep/n.bin"] = [4]
            case .removeFile:
                image.files.removeValue(forKey: work + "/f.bin")
            case .rewriteFile:
                image.files[work + "/f.bin"] = [9, 9]
            case .removeDirectory:
                image.directories.remove(work + "/empty")
            case .fileBecomesDirectory:
                image.files.removeValue(forKey: work + "/f.bin")
                image.directories.insert(work + "/f.bin")
            case .addDurableFile:
                image.durableFiles[work + "/ghost.bin"] = [6]
            case .addDurableDirectory:
                image.durableDirectories.insert(work + "/ghost-dir")
            case .addFileDurably:
                image.files[work + "/seeded.bin"] = [5]
                image.durableFiles[work + "/seeded.bin"] = [5]
            case .removeDurableFile:
                image.durableFiles.removeValue(forKey: work + "/f.bin")
            case .rewriteDurableFile:
                image.durableFiles[work + "/f.bin"] = [8]
            case .addLink:
                image.symbolicLinks[work + "/new.link"] = "f.bin"
            case .addLinkDurably:
                image.symbolicLinks[work + "/seeded.link"] = "f.bin"
                image.durableSymbolicLinks[work + "/seeded.link"] = "f.bin"
            case .addDurableLink:
                image.durableSymbolicLinks[work + "/ghost.link"] = "f.bin"
            case .retargetLink:
                image.symbolicLinks[work + "/l.link"] = "elsewhere"
            case .removeDurableLink:
                image.durableSymbolicLinks.removeValue(forKey: work + "/l.link")
            case .addAttributes:
                image.attributes[work + "/f.bin"] = .storeDefault
            case .removeAttributes:
                image.attributes.removeValue(forKey: work)
            case .rewriteOneOfTwoNames:
                image.files["/fake-volume/s/f"] = [3]
            case .purge:
                image.purge(work + "/")
            }
        }
    }

    /// A fully durable disk with a file, an empty directory, a link, attributes and one file under two names (a
    /// power loss after a rename between two independently synced directories).
    @available(macOS 15.0, iOS 18.0, *)
    private static func base() throws -> DiskImage {
        let fileSystem = FakeFSFixture.make()
        let source = FakeFSFixture.url("/fake-volume/s")
        let destination = FakeFSFixture.url("/fake-volume/t")
        for directory in [source, destination, FakeFSFixture.url(Self.work), FakeFSFixture.url(Self.work + "/empty")] {
            try fileSystem.createDirectory(at: directory)
        }
        try fileSystem.write(Data([1]), to: FakeFSFixture.url(Self.work + "/f.bin"), mode: .truncate)
        try fileSystem.createSymbolicLink(at: FakeFSFixture.url(Self.work + "/l.link"), destination: "f.bin")
        try fileSystem.applyStoreAttributes(.storeDefault, at: FakeFSFixture.url(Self.work))
        try fileSystem.write(Data([2, 2]), to: source.appendingPathComponent("f"), mode: .truncate)
        var image = fileSystem.survivingDisk()
        image.makeDurable()
        let renaming = FakeFFSLifetime.next(image)
        try renaming.rename(from: source.appendingPathComponent("f"), to: destination.appendingPathComponent("f"), mode: .exclusive)
        try renaming.synchronizeDirectory(at: destination, level: .barrier)
        return FakeFSFixture.powerLoss(renaming.survivingDisk())
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a fake started on an edited disk shows exactly the edited disk", arguments: Edit.allCases)
    func editedDiskLoadsAsEdited(edit: Edit) throws {
        let base = try Self.base()
        #expect(base.files["/fake-volume/s/f"] == [2, 2] && base.files["/fake-volume/t/f"] == [2, 2])
        var edited = base
        edit.apply(to: &edited)
        #expect(edited != base)
        #expect(FakeFFSLifetime.next(edited).survivingDisk() == Self.withImpliedDirectories(edited))
    }

    /// `image` with the parent directories its files imply listed too (a file's missing parents are created).
    private static func withImpliedDirectories(_ image: DiskImage) -> DiskImage {
        var implied = image
        for path in image.files.keys {
            var components = path.split(separator: "/").map(String.init)
            components.removeLast()
            while !components.isEmpty {
                implied.directories.insert("/" + components.joined(separator: "/"))
                components.removeLast()
            }
        }
        return implied
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: rewriting a file's content in a disk image keeps the file's identity and its synced bytes")
    func rewriteKeepsIdentity() throws {
        let fileSystem = FakeFSFixture.make()
        let directory = FakeFSFixture.url(Self.work)
        let file = directory.appendingPathComponent("f.bin")
        try fileSystem.createDirectory(at: directory)
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.volume, level: .barrier)
        try fileSystem.write(Data([0]), to: directory.appendingPathComponent("scratch.tmp"), mode: .truncate)
        try fileSystem.removeItem(at: directory.appendingPathComponent("scratch.tmp"))
        try fileSystem.write(Data([1]), to: file, mode: .truncate)
        try fileSystem.synchronizeFile(at: file, level: .barrier)
        try fileSystem.synchronizeDirectory(at: directory, level: .barrier)
        let identity = try #require(try fileSystem.itemInfo(at: file)?.identity)

        var corrupted = fileSystem.survivingDisk()
        corrupted.files[Self.work + "/f.bin"] = [9]
        let next = FakeFFSLifetime.next(corrupted)
        #expect(FakeFSFixture.content(next, Self.work + "/f.bin") == [9])
        #expect(try next.itemInfo(at: file)?.identity == identity)
        #expect(FakeFSFixture.powerLoss(next.survivingDisk()).files[Self.work + "/f.bin"] == [1])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a purge removes a path from both namespaces, while an edit of files alone is undone by a power loss")
    func purgeIsDurable() throws {
        let fileSystem = FakeFSFixture.make()
        let caches = FakeFSFixture.url("/fake-volume/Library/Caches")
        let directory = caches.appendingPathComponent("c")
        let file = directory.appendingPathComponent("x.bin")
        try fileSystem.createDirectory(at: directory)
        try fileSystem.write(Data([5, 5]), to: file, mode: .truncate)
        try fileSystem.synchronizeFile(at: file, level: .barrier)
        try fileSystem.synchronizeDirectory(at: directory, level: .barrier)
        try fileSystem.synchronizeDirectory(at: caches, level: .barrier)

        var volatile = fileSystem.survivingDisk()
        volatile.files.removeValue(forKey: file.path)
        let edited = FakeFFSLifetime.next(volatile)
        #expect(try edited.itemInfo(at: file) == nil)
        #expect(FakeFSFixture.powerLoss(edited.survivingDisk()).files[file.path] == [5, 5])

        var purged = fileSystem.survivingDisk()
        purged.purge(directory.path)
        #expect(!purged.paths.contains { $0.hasPrefix(directory.path) })
        let afterPurge = FakeFFSLifetime.next(purged)
        #expect(try afterPurge.itemInfo(at: directory) == nil)
        let afterPowerLoss = FakeFSFixture.powerLoss(afterPurge.survivingDisk())
        #expect(afterPowerLoss.files[file.path] == nil)
        #expect(!afterPowerLoss.directories.contains(directory.path))
        #expect(afterPowerLoss.directories.contains(caches.path))
    }
}
