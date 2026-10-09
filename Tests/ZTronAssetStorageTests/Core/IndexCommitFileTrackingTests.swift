import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The commit unit carries which index name holds the committed generation (`IndexCommitInput.committedFile`, ADR draft
/// B-28 as amended in close-out cycle 5) instead of reading it from a header, and follows it through every rename it
/// makes, including the ones whose result is lost. The state-space enumeration checks the single-event cases after every
/// commit attempt; these need two events in one unit, or an outside deletion, which it does not enumerate. Each
/// asserts the invariant the unit's decisions rely on: the file it reports holds the committed generation, or it
/// reports none.
@Suite("Core: the committed index file through a commit unit's renames (R-STO-4)")
struct IndexCommitFileTrackingTests {
    static let layout = CoreFixture.layout

    /// A fake volume with the store's directories and `files` (index name → generation, or `nil` for a rotten copy of
    /// generation 5 whose trailer fails).
    @available(macOS 15.0, *)
    static func volume(_ files: [IndexFile: UInt64?]) throws -> FakeFileSystem {
        let fileSystem = FakeFileSystem(time: ManualTimeSource())
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for component in IndexCommitFileTrackingTests.layout.blobsDirectory.pathComponents.dropFirst() {
            path.appendPathComponent(component, isDirectory: true)
            try fileSystem.createDirectory(at: path)
        }
        for (file, generation) in files {
            var bytes = try IndexCommitFileTrackingTests.encoded(generation ?? 5)
            if generation == nil {
                bytes[bytes.count - 1] ^= 0xFF
            }
            try fileSystem.write(bytes, to: IndexCommitFileTrackingTests.layout.indexURL(file), mode: .truncate)
        }
        return fileSystem
    }

    static func encoded(_ generation: UInt64) throws -> Data {
        var content = IndexContent.empty(storeID: StoreIdentifier.derived(fromSeed: 7))
        content.generation = generation
        return try #require(IndexCodec.encode(content))
    }

    /// The generation `file` holds, validated in full.
    @available(macOS 15.0, *)
    static func generation(in file: IndexFile, _ fileSystem: FakeFileSystem) -> UInt64? {
        fileSystem.survivingDisk().files[IndexCommitFileTrackingTests.layout.indexURL(file).path].flatMap { try? IndexCodec.decode($0).get() }?.generation
    }

    /// The input of a commit of generation 6 over `committed` in `file`.
    static func input(committed: UInt64, in file: IndexFile?) throws -> IndexCommitInput {
        var input = IndexCommitInput(
            layout: IndexCommitFileTrackingTests.layout,
            content: IndexContent.empty(storeID: StoreIdentifier.derived(fromSeed: 7)),
            dirtyFanOuts: [],
            blobsDirectoryDirty: false,
            durability: .ordered,
            lock: nil
        )
        input.content.generation = 6
        input.committedGeneration = committed
        input.committedFile = file
        return input
    }

    /// Step 4 moves the committed generation 5 to `index.prev`; step 5 fails with EIO before it acts; the undo
    /// (`index.prev → index.bin`) takes effect but reports EIO. `index.prev` is gone, so the unit knows the undo happened
    /// and reports `index.bin`, which holds generation 5 again. Without that, it reported `index.prev`, which no longer
    /// exists, and the next commit's step 4 would have renamed its `index.tmp` straight over the committed file.
    @Test("R-STO-4: an undo of step 4 whose result was lost still moves the committed file back to index.bin")
    @available(macOS 15.0, *)
    func lostUndoResult() throws {
        let fake = try IndexCommitFileTrackingTests.volume([.current: 5, .previous: 4])
        fake.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        // Renames: 1 step 4, 2 step 5 (the injected EIO), 3 the undo, which takes effect and reports EIO.
        let fileSystem = MisreportingFileSystem(fake, failing: 3)
        let outcome = IndexCommitUnit.run(try IndexCommitFileTrackingTests.input(committed: 5, in: .current), fileSystem: fileSystem)
        #expect(throws: StoreError.fileSystem(.io)) {
            try outcome.result.get()
        }
        #expect(fileSystem.fired, "the undo's result was lost")
        #expect(fake.operations.filter { $0.kind == .rename }.count == 3)
        #expect(outcome.committedFile == .current)
        #expect(IndexCommitFileTrackingTests.generation(in: .current, fake) == 5, "index.bin holds the committed generation again")
        #expect(IndexCommitFileTrackingTests.generation(in: .previous, fake) == nil)
    }

    /// The load chose `index.prev` (generation 4; `index.bin` is rotten), then `index.prev` vanished (an outside deletion
    /// inside the private root). Step 4 now runs (nothing is at `index.prev`) and moves the rotten file there; step 5
    /// fails and the undo moves it back. The unit no longer claims a file for generation 4: whatever is at either name
    /// is the rotten file, and naming it would let a later ENOSPC fallback treat it as the committed generation.
    @Test("R-STO-4: a file renamed over the committed file's name is not taken for the committed generation")
    @available(macOS 15.0, *)
    func renamedOverTheCommittedName() throws {
        let fake = try IndexCommitFileTrackingTests.volume([.current: nil, .previous: 4])
        let loaded = StoreRecoveryTests.loadRule(fake.survivingDisk())
        #expect(loaded.chosen == .previous && loaded.survivingFile == .previous)
        try fake.removeItem(at: IndexCommitFileTrackingTests.layout.indexURL(.previous))
        fake.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        let outcome = IndexCommitUnit.run(try IndexCommitFileTrackingTests.input(committed: 4, in: .previous), fileSystem: fake)
        #expect(throws: StoreError.fileSystem(.io)) {
            try outcome.result.get()
        }
        #expect(fake.operations.filter { $0.kind == .rename }.map { $0.url.lastPathComponent } == ["index.bin", "index.tmp", "index.prev"])
        #expect(outcome.committedFile == nil, "no file holds generation 4 any more")
        #expect(IndexCommitFileTrackingTests.generation(in: .current, fake) == nil && IndexCommitFileTrackingTests.generation(in: .previous, fake) == nil)
    }

    /// The load validated `index.bin` (generation 5), then it vanished (an outside deletion inside the private root).
    /// Step 4 does not run (nothing is at `index.bin`), step 5 fails before it acts: the unit no longer claims
    /// `index.bin` for generation 5, which no file holds now, so a later ENOSPC fallback cannot take `index.bin` for it.
    @Test("R-STO-4: a committed index.bin that vanished is no longer taken for the committed generation")
    @available(macOS 15.0, *)
    func vanishedCommittedFile() throws {
        let fake = try IndexCommitFileTrackingTests.volume([.current: 5, .previous: 4])
        let loaded = StoreRecoveryTests.loadRule(fake.survivingDisk())
        #expect(loaded.chosen == .current && loaded.content?.generation == 5)
        try fake.removeItem(at: IndexCommitFileTrackingTests.layout.indexURL(.current))
        fake.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        let outcome = IndexCommitUnit.run(try IndexCommitFileTrackingTests.input(committed: 5, in: .current), fileSystem: fake)
        #expect(throws: StoreError.fileSystem(.io)) {
            try outcome.result.get()
        }
        #expect(fake.operations.filter { $0.kind == .rename }.map { $0.url.lastPathComponent } == ["index.tmp"], "no step 4: nothing was at index.bin")
        #expect(outcome.committedFile == nil, "no file holds generation 5 any more")
        #expect(IndexCommitFileTrackingTests.generation(in: .previous, fake) == 4, "index.prev is kept")
    }
}
