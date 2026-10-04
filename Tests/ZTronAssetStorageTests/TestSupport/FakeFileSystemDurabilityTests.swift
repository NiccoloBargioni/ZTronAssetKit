import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// The durability model the store's crash proofs rest on (store.md §3.4 as amended by store-1 S1-01): names and
/// data are durable separately, directories independently, and a process kill keeps the un-synced split.
@Suite("Test support: FakeFileSystem durability")
struct TestSupportFakeFileSystemDurabilityTests {
    private static let work = "/fake-volume/work"

    /// A fake with `/fake-volume/work` created and its entry synced into the (durable) volume root.
    @available(macOS 15.0, *)
    private static func prepared() throws -> FakeFileSystem {
        let fileSystem = FakeFSFixture.make()
        try fileSystem.createDirectory(at: FakeFSFixture.url(Self.work))
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.volume, level: .barrier)
        return fileSystem
    }

    @available(macOS 15.0, *)
    @Test("Test support: a process kill keeps every applied mutation and the un-synced split into the next lifetime")
    func processKillKeepsVolatileState() throws {
        let first = try Self.prepared()
        try first.write(Data([1, 2, 3]), to: FakeFSFixture.url(Self.work + "/f.bin"), mode: .truncate)
        let killed = first.survivingDisk()
        #expect(killed.files[Self.work + "/f.bin"] == [1, 2, 3])
        #expect(killed.durableFiles[Self.work + "/f.bin"] == nil)

        let second = FakeFFSLifetime.next(killed)
        #expect(FakeFSFixture.content(second, Self.work + "/f.bin") == [1, 2, 3])
        let afterPowerLoss = FakeFSFixture.powerLoss(second.survivingDisk())
        #expect(afterPowerLoss.files[Self.work + "/f.bin"] == nil)
        #expect(afterPowerLoss.directories.contains(Self.work))
    }

    @available(macOS 15.0, *)
    @Test("Test support: a power loss that drops un-synced state reverts each listing and each file to its last sync")
    func dropUnsyncedRevertsToLastSync() throws {
        let fileSystem = try Self.prepared()
        let file = FakeFSFixture.url(Self.work + "/f.bin")
        try fileSystem.write(Data([1]), to: file, mode: .truncate)
        try fileSystem.synchronizeFile(at: file, level: .barrier)
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.url(Self.work), level: .barrier)
        try fileSystem.write(Data([2]), to: file, mode: .append)
        try fileSystem.write(Data([9]), to: FakeFSFixture.url(Self.work + "/late.bin"), mode: .truncate)

        let disk = FakeFSFixture.powerLoss(fileSystem.survivingDisk())
        #expect(disk.files[Self.work + "/f.bin"] == [1])
        #expect(disk.files[Self.work + "/late.bin"] == nil)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a file whose name was synced but whose data never was is empty after a power loss")
    func syncedNameWithoutDataIsEmpty() throws {
        let fileSystem = try Self.prepared()
        try fileSystem.write(Data([1, 2]), to: FakeFSFixture.url(Self.work + "/f.bin"), mode: .truncate)
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.url(Self.work), level: .barrier)

        let disk = FakeFSFixture.powerLoss(fileSystem.survivingDisk())
        #expect(disk.files[Self.work + "/f.bin"] == [])
    }

    @available(macOS 15.0, *)
    @Test("Test support: a power loss that keeps metadata keeps every name but reverts data, so an unsynced renamed file is empty")
    func keepMetadataRevertsDataOnly() throws {
        let fileSystem = try Self.prepared()
        let staged = FakeFSFixture.url(Self.work + "/a.part")
        let synced = FakeFSFixture.url(Self.work + "/b.part")
        try fileSystem.write(Data([1, 2, 3]), to: staged, mode: .truncate)
        try fileSystem.write(Data([4, 5]), to: synced, mode: .truncate)
        try fileSystem.synchronizeFile(at: synced, level: .barrier)
        try fileSystem.rename(from: staged, to: FakeFSFixture.url(Self.work + "/a.blob"), mode: .exclusive)
        try fileSystem.rename(from: synced, to: FakeFSFixture.url(Self.work + "/b.blob"), mode: .exclusive)

        let disk = FakeFSFixture.powerLoss(fileSystem.survivingDisk(), .powerLossKeepMetadata)
        #expect(disk.files[Self.work + "/a.blob"] == [])
        #expect(disk.files[Self.work + "/b.blob"] == [4, 5])
        #expect(disk.files[Self.work + "/a.part"] == nil)
        #expect(disk.durableFiles == disk.files)
    }

    @available(macOS 15.0, *)
    @Test(
        "Test support: directories are durable independently, so a rename between two survives in neither, one or both",
        arguments: [(false, false), (true, false), (false, true), (true, true)]
    )
    func renameAcrossDirectories(syncSource: Bool, syncDestination: Bool) throws {
        let fileSystem = try Self.prepared()
        let source = FakeFSFixture.url(Self.work + "/s")
        let destination = FakeFSFixture.url(Self.work + "/t")
        try fileSystem.createDirectory(at: source)
        try fileSystem.createDirectory(at: destination)
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.url(Self.work), level: .barrier)
        try fileSystem.write(Data([7]), to: source.appendingPathComponent("f"), mode: .truncate)
        try fileSystem.synchronizeFile(at: source.appendingPathComponent("f"), level: .barrier)
        try fileSystem.synchronizeDirectory(at: source, level: .barrier)
        try fileSystem.rename(from: source.appendingPathComponent("f"), to: destination.appendingPathComponent("f"), mode: .exclusive)
        if syncSource {
            try fileSystem.synchronizeDirectory(at: source, level: .barrier)
        }
        if syncDestination {
            try fileSystem.synchronizeDirectory(at: destination, level: .barrier)
        }

        let disk = FakeFSFixture.powerLoss(fileSystem.survivingDisk())
        #expect((disk.files[Self.work + "/s/f"] == [7]) == !syncSource)
        #expect((disk.files[Self.work + "/t/f"] == [7]) == syncDestination)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a barrier and a full sync both make the synced item durable at the call", arguments: [SyncLevel.barrier, .full])
    func bothLevelsAreDurable(level: SyncLevel) throws {
        let fileSystem = try Self.prepared()
        let file = FakeFSFixture.url(Self.work + "/f.bin")
        try fileSystem.write(Data([3, 3]), to: file, mode: .truncate)
        try fileSystem.synchronizeFile(at: file, level: level)
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.url(Self.work), level: level)

        let disk = FakeFSFixture.powerLoss(fileSystem.survivingDisk())
        #expect(disk.files[Self.work + "/f.bin"] == [3, 3])
    }

    @available(macOS 15.0, *)
    @Test("Test support: data synced in a killed lifetime stays durable when the next lifetime syncs the directory naming it")
    func killThenPowerLossFollowsTheInode() throws {
        // store-1 S1-01 timeline (a): publish without a fan-out sync, kill, adopt and sync in the next lifetime.
        let first = try Self.prepared()
        let blobs = FakeFSFixture.url(Self.work + "/blobs")
        let fanOut = blobs.appendingPathComponent("aa")
        let staged = FakeFSFixture.url(Self.work + "/x.part")
        try first.createDirectory(at: blobs)
        try first.synchronizeDirectory(at: FakeFSFixture.url(Self.work), level: .barrier)
        try first.write(Data([1, 2, 3, 4]), to: staged, mode: .truncate)
        try first.synchronizeFile(at: staged, level: .barrier)
        try first.createDirectory(at: fanOut)
        try first.rename(from: staged, to: fanOut.appendingPathComponent("h.png"), mode: .exclusive)
        let killed = first.survivingDisk()

        let onlyFanOut = FakeFFSLifetime.next(killed)
        try onlyFanOut.synchronizeDirectory(at: fanOut, level: .barrier)
        #expect(FakeFSFixture.powerLoss(onlyFanOut.survivingDisk()).files[Self.work + "/blobs/aa/h.png"] == nil)

        let both = FakeFFSLifetime.next(killed)
        try both.synchronizeDirectory(at: fanOut, level: .barrier)
        try both.synchronizeDirectory(at: blobs, level: .barrier)
        #expect(FakeFSFixture.powerLoss(both.survivingDisk()).files[Self.work + "/blobs/aa/h.png"] == [1, 2, 3, 4])
    }

    /// Lifetime 1 of the store-1 S1-01 shapes below: `work/blobs` is durable; a fan-out `aa` is created and never
    /// synced into `blobs`, while `aa/h.bin` is written, synced and synced into `aa`'s own listing.
    @available(macOS 15.0, *)
    private static func syncedIntoUnsyncedFanOut() throws -> FakeFileSystem {
        let fileSystem = try Self.prepared()
        let blobs = FakeFSFixture.url(Self.work + "/blobs")
        let fanOut = blobs.appendingPathComponent("aa")
        try fileSystem.createDirectory(at: blobs)
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.url(Self.work), level: .barrier)
        try fileSystem.createDirectory(at: fanOut)
        try fileSystem.write(Data([1, 2, 3]), to: fanOut.appendingPathComponent("h.bin"), mode: .truncate)
        try fileSystem.synchronizeFile(at: fanOut.appendingPathComponent("h.bin"), level: .barrier)
        try fileSystem.synchronizeDirectory(at: fanOut, level: .barrier)
        return fileSystem
    }

    @available(macOS 15.0, *)
    @Test("Test support: an unlink a process kill kept un-synced is undone by a power loss after the next lifetime syncs the parent")
    func killKeepsSyncedListingOfAnUnsyncedDirectory() throws {
        let blobs = FakeFSFixture.url(Self.work + "/blobs")
        let path = Self.work + "/blobs/aa/h.bin"
        let killed = try Self.syncedIntoUnsyncedFanOut()
        try killed.removeItem(at: FakeFSFixture.url(path))
        let next = FakeFFSLifetime.next(killed.survivingDisk())
        try next.synchronizeDirectory(at: blobs, level: .barrier)

        let alive = try Self.syncedIntoUnsyncedFanOut()
        try alive.removeItem(at: FakeFSFixture.url(path))
        try alive.synchronizeDirectory(at: blobs, level: .barrier)

        #expect(FakeFSFixture.powerLoss(alive.survivingDisk()).files[path] == [1, 2, 3])
        #expect(FakeFSFixture.powerLoss(next.survivingDisk()).files[path] == [1, 2, 3])
    }

    @available(macOS 15.0, *)
    @Test("Test support: editing one path of a killed disk keeps the durable state of every path the edit did not touch")
    func editedKilledDiskKeepsHiddenDurableState() throws {
        let blobs = FakeFSFixture.url(Self.work + "/blobs")
        let path = Self.work + "/blobs/aa/h.bin"
        var edited = try Self.syncedIntoUnsyncedFanOut().survivingDisk()
        edited.files["/fake-volume/Library/Caches/other.bin"] = [7]
        let next = FakeFFSLifetime.next(edited)
        #expect(FakeFSFixture.content(next, "/fake-volume/Library/Caches/other.bin") == [7])
        try next.synchronizeDirectory(at: blobs, level: .barrier)

        let afterPowerLoss = FakeFSFixture.powerLoss(next.survivingDisk())
        #expect(afterPowerLoss.files[path] == [1, 2, 3])
        #expect(afterPowerLoss.files["/fake-volume/Library/Caches/other.bin"] == nil)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a replacing rename keeps the replaced file durable under its name until the directory is synced")
    func replacedFileStaysDurableUntilDirectorySync() throws {
        let fileSystem = try Self.prepared()
        let bin = FakeFSFixture.url(Self.work + "/index.bin")
        let tmp = FakeFSFixture.url(Self.work + "/index.tmp")
        try fileSystem.write(Data([1]), to: bin, mode: .truncate)
        try fileSystem.synchronizeFile(at: bin, level: .full)
        try fileSystem.synchronizeDirectory(at: FakeFSFixture.url(Self.work), level: .full)
        try fileSystem.write(Data([2]), to: tmp, mode: .truncate)
        try fileSystem.synchronizeFile(at: tmp, level: .barrier)
        try fileSystem.rename(from: tmp, to: bin, mode: .replacing)

        let killed = fileSystem.survivingDisk()
        #expect(killed.files[Self.work + "/index.bin"] == [2])
        #expect(killed.durableFiles[Self.work + "/index.bin"] == [1])
        let next = FakeFFSLifetime.next(killed)
        try next.synchronizeFile(at: bin, level: .full)  // syncs the new inode's data only
        #expect(FakeFSFixture.powerLoss(next.survivingDisk()).files[Self.work + "/index.bin"] == [1])
    }
}
