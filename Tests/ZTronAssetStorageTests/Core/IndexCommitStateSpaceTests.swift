import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// What one index file holds when a case of the state-space test starts (close-out cycle 3, item 2; cycle 5).
///
/// One lineage throughout: `older` is generation 9, `committed` 10, `newer` 11 (an attempt that did not complete: its
/// data synced, its commit never reported). Every item of the initial disk is synced, except `newerUnsynced`. Pruned,
/// each because the store can never produce it:
/// - `newerUnsynced` (generation 11 complete in the current namespace, its data and name never synced: a kill between
///   steps 2 and 3, probe VP7) is enumerated for `index.tmp` only. `index.tmp` is the one file the protocol writes in
///   place; `index.bin` and `index.prev` only ever receive an `index.tmp` that was synced first (step 3, and the
///   promotion's own sync), so their data is never unsynced.
/// - Names not yet ordered by a root sync (a kill after a rename or a removal and before the next root sync) are not
///   seeded here: `IndexCommitUnorderedNamesTests` starts from every such kill survivor of the fault-free lifetimes of
///   the unforged disks. A power loss can undo what the load read there until a root sync orders it, and the first one
///   is `open()`'s barrier: the store counts nothing committed before it (ADR draft B-36), and once it succeeded every
///   index name is ordered (that suite checks it), which leaves a disk of this space up to its generation numbers and
///   the unsynced data of an `index.tmp` (read as torn, like an absent one). That suite therefore enumerates the
///   barrier's faults, a crash before it, and the lifetime after a failed barrier.
///
/// Rotten files come in two kinds, both enumerated for all three files:
/// - `badHeader`, `badBody`, `truncated`: a rotten copy of a generation no other file holds, above every valid one
///   (20 + the file's position), so its header (when it parses) names a generation of its own. A header below the valid
///   generations that names no valid file behaves as one above them except for `nextGeneration`; the higher one also
///   checks that the next launch epoch clears it (I-5).
/// - The `forged…` states (close-out cycle 5, review "a rotten header can name the committed generation"): a copy of a
///   valid generation (9, 10 or 11) whose header's generation field names another valid generation, the committed one
///   included, with the right size and a trailer that fails. The header has no checksum of its own (the SHA-256 trailer
///   covers header and body) and consecutive generations differ in bit 0, so one flipped bit makes a rotten `index.bin`
///   name `index.prev`'s generation. Every (source, named) pair over 9, 10 and 11: six states per file. The pruning of
///   cycle 3 ("a rotten header can never name the committed generation, files are only renamed") was false for bit rot.
/// Two valid files of one generation are impossible, but cost nothing, so they are enumerated anyway.
enum SeededIndex: String, CaseIterable, Sendable {
    case absent
    case older
    case committed
    case newer
    case newerUnsynced
    case badHeader
    case badBody
    case truncated
    case forged9As10
    case forged9As11
    case forged10As9
    case forged10As11
    case forged11As9
    case forged11As10

    /// The states `index.bin` and `index.prev` are enumerated over (see the pruning above).
    static let renamedInto: [SeededIndex] = SeededIndex.allCases.filter { $0 != .newerUnsynced }
    /// The states without a forged header: the space whose fault-free lifetimes `IndexCommitUnorderedNamesTests` starts
    /// from (its size is pinned; forged headers with unordered names are not enumerated, ADR draft B-33).
    static let unforged: [SeededIndex] = SeededIndex.allCases.filter { $0.forgery == nil }

    /// For a forged header: the valid generation the file is a copy of, and the generation its header names instead.
    var forgery: (source: UInt64, named: UInt64)? {
        switch self {
        case .forged9As10:
            return (9, 10)
        case .forged9As11:
            return (9, 11)
        case .forged10As9:
            return (10, 9)
        case .forged10As11:
            return (10, 11)
        case .forged11As9:
            return (11, 9)
        case .forged11As10:
            return (11, 10)
        case .absent, .older, .committed, .newer, .newerUnsynced, .badHeader, .badBody, .truncated:
            return nil
        }
    }

    /// The generation behind the file (its header's, when rotten), or `nil` when absent.
    func generation(at file: IndexFile) -> UInt64? {
        switch self {
        case .absent:
            return nil
        case .older:
            return 9
        case .committed:
            return 10
        case .newer, .newerUnsynced:
            return 11
        case .badHeader, .badBody, .truncated:
            return 20 + UInt64(IndexFile.allCases.firstIndex(of: file) ?? 0)
        case .forged9As10, .forged9As11, .forged10As9, .forged10As11, .forged11As9, .forged11As10:
            return self.forgery?.named
        }
    }
}

/// How full the volume is while one lifetime of the state-space test runs.
enum VolumeScript: String, CaseIterable, Sendable {
    /// Space for everything.
    case free
    /// The launch commit has space; then every write of `index.tmp` fails with ENOSPC (close()'s durable flush).
    case fullAtClose
    /// Every write of `index.tmp` fails with ENOSPC from the launch commit on (the launch on a full volume of probes 1
    /// and VP7).
    case fullFromLaunch

    /// Whether the volume is full for the commit at `index` (0: the launch commit, 1: the durable flush).
    func isFull(atCommit index: Int) -> Bool {
        switch self {
        case .free:
            return false
        case .fullAtClose:
            return index >= 1
        case .fullFromLaunch:
            return true
        }
    }
}

/// One initial disk: the states of the three index files. Each one enumerates every volume script and every event.
struct IndexSpaceSlice: Sendable, CustomTestStringConvertible {
    var bin: SeededIndex
    var previous: SeededIndex
    var temporary: SeededIndex

    var testDescription: String {
        "bin=\(self.bin) prev=\(self.previous) tmp=\(self.temporary)"
    }

    /// The state of `file`.
    func seeded(_ file: IndexFile) -> SeededIndex {
        switch file {
        case .current:
            return self.bin
        case .previous:
            return self.previous
        case .temporary:
            return self.temporary
        }
    }

}

/// The states of `index.bin` and `index.prev`: one test case, which enumerates every state of `index.tmp` in its space.
struct IndexSpaceRow: Sendable, CustomTestStringConvertible {
    var bin: SeededIndex
    var previous: SeededIndex
    /// The states of `index.tmp` the row enumerates.
    var temporaries: [SeededIndex]

    var testDescription: String {
        "bin=\(self.bin) prev=\(self.previous)"
    }

    /// The row's initial disks, one per state of `index.tmp`.
    var slices: [IndexSpaceSlice] {
        self.temporaries.map { IndexSpaceSlice(bin: self.bin, previous: self.previous, temporary: $0) }
    }

    /// Every row of the main enumeration: 13 × 13 (× 14 states of `index.tmp` each), forged headers included.
    static let all: [IndexSpaceRow] = IndexSpaceRow.rows(SeededIndex.allCases)

    /// The rows without forged headers, whose fault-free lifetimes `IndexCommitUnorderedNamesTests` starts from:
    /// 7 × 7 (× 8 states of `index.tmp` each).
    static let unforged: [IndexSpaceRow] = IndexSpaceRow.rows(SeededIndex.unforged)

    private static func rows(_ states: [SeededIndex]) -> [IndexSpaceRow] {
        let renamedInto = states.filter { $0 != .newerUnsynced }
        return renamedInto.flatMap { bin in
            renamedInto.map { IndexSpaceRow(bin: bin, previous: $0, temporaries: states) }
        }
    }
}

/// The exhaustive state space of the index commit unit and the load rule over `FakeFileSystem` (close-out cycle 3,
/// item 2; ARCHITECTURE §4.1, §4.2; ADR drafts B-28, B-33, B-34).
///
/// A case is one initial disk (every combination of `SeededIndex` for the three files) × one volume script × one event:
/// none; one injected fault at **every** file-system operation the lifetime performs, the load's included (EIO at every
/// operation; ENOSPC at every mutation, as no query returns it; and at every rename, a rename that took effect but
/// reported EIO); or a crash before every mutation in each of the four crash modes (kill, torn write, both power
/// losses). The lifetime is what `open()` and `close()` do to the index: the load (`IndexLoader`, `LaunchState.build`),
/// `open()`'s root barrier, the ordered launch commit and the durable flush, folded through `IndexCommitLedger` as
/// `AssetStore.commitNow` folds them. Each case ends in a kill (a run that did not crash ends with its process) or in its
/// crash; that survivor is reopened by a fault-free launch, and the disk the reopen leaves is loaded once more, as a kill
/// and as a power loss dropping unsynced state would leave it. Invariants:
/// - **I-a** the newest durable generation is never lost unless a newer valid one replaces it: whatever a kill or a power
///   loss leaves, and whatever the reopen leaves after it, holds a generation at least as new as the newest valid one
///   the same crash would have left before the case ran (the initial disk under that crash's view), and as every
///   generation the store counted committed (loaded, durably promoted or committed). An attempt whose commit failed is
///   not durable in this sense even when its synced `index.tmp` would survive a power loss: the next attempt rewrites
///   `index.tmp` in place (step 2, ADR-015), the store never counted it, and it held a prefix of the in-memory state the
///   next attempt writes.
/// - **I-b** the generation the store counts committed is a valid file on disk: after every commit attempt (as a kill
///   leaves it), and at the end of every run and of every reopen under each crash view. A crash inside a unit is held to
///   I-a against what the store counted committed before that unit: a promotion inside the unit may replace it.
/// - **I-c** a failed commit leaves `index.bin` present and valid whenever it was valid before.
/// - **I-e** (liveness) on a free volume, a fault before close()'s durable flush does not outlive its commit: the flush,
///   meeting no fault of its own, succeeds (probe VPC2-K: a promotion left pending by a lost rename blocked every commit).
/// - **I-d** a second launch reaches the same generation as the first or a newer one, with a later epoch (I-5): the
///   reopen's epoch exceeds every generation the case counted committed, its fault-free launch commit succeeds, and the
///   launch after it loads at least the reopen's generation with a larger epoch. A launch whose own launch commit failed
///   may see its epoch again (ADR draft B-5), so a case's epoch is not compared with the reopen's.
///
/// How the enumeration stays affordable without sampling (every case runs; only identical work is shared): the no-fault
/// run records the disk before every mutation, and a crash before mutation k leaves exactly that disk under the crash's
/// view, so only torn writes are run again (from the start of their commit); a run with a fault resumes from the no-fault
/// run's disk at the start of the commit the fault falls in (the run is deterministic up to the fault); the checks after
/// a commit and at the end of a run are computed once per `RunKey` (the effects of the run's mutations and its
/// bookkeeping: equal keys mean an identical volume and memory); and the reopen of a survivor, which after `open()`'s
/// root barrier depends only on its index files as a kill and as a power loss keeping metadata leave them, is computed
/// once per distinct pair.
@Suite("Core: index commit state space (R-STO-4, R-STO-5)", .serialized)
struct IndexCommitStateSpaceTests {
    /// The rows run one at a time (`.serialized`), each as eight child tasks at low priority that yield after every case:
    /// a row then takes about a second under TSan, so its time limit keeps a wide margin, and suites running beside this
    /// one keep the cooperative pool (every case of every suite starts its time limit when the run starts).
    @Test(
        "R-STO-4: every initial index state, with one fault at every operation, a kill or a power loss at every mutation, keeps I-a…I-e",
        .timeLimit(.minutes(1)),
        arguments: IndexSpaceRow.all
    )
    @available(macOS 15.0, *)
    func everyStateFaultAndCrash(row: IndexSpaceRow) async throws {
        var starts: [(IndexSpaceSlice, DiskImage, IndexSpace.Views)] = []
        for slice in row.slices {
            let initial = IndexSpace.disk(slice)
            let start = IndexSpace.views(initial)
            try IndexSpace.checkSeed(slice, start)
            starts.append((slice, initial, start))
        }
        let results = await withTaskGroup(of: IndexSpace.SliceResult.self) { group in
            for (slice, initial, start) in starts {
                group.addTask(priority: .low) {
                    await IndexSpace.enumerate(slice, initial: initial, start: start)
                }
            }
            var results: [IndexSpace.SliceResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        let violations = results.sorted { $0.slice < $1.slice }.flatMap(\.violations)
        let shown = violations.prefix(40).joined(separator: "\n")
        #expect(violations.isEmpty, "\(violations.count) violations from \(row.testDescription); the first ones:\n\(shown)")
        // The size of the space is asserted, not only printed: a refactor that dropped a disk, a volume script, an event or
        // a crash mode would otherwise still pass (close-out cycle 4).
        #expect(results.count == SeededIndex.allCases.count && Set(results.map(\.slice)) == Set(row.slices.map(\.testDescription)), "every initial disk of \(row.testDescription) ran")
        for result in results {
            let counts = result.counts
            #expect(counts.faultFree == VolumeScript.allCases.count, "\(result.slice): one fault-free lifetime per volume script")
            #expect(counts.faults == counts.expectedFaults && counts.expectedFaults > 0, "\(result.slice): \(counts.faults) faults for \(counts.expectedFaults) fault points")
            #expect(counts.crashes == counts.expectedCrashes && counts.expectedCrashes > 0, "\(result.slice): \(counts.crashes) crash cases for \(counts.expectedCrashes) crash points")
            #expect(counts.cases == counts.faultFree + counts.faults + counts.crashes, "\(result.slice): every case is counted once")
        }
        let cases = results.map(\.counts.cases).reduce(0, +)
        let faults = results.map(\.counts.faults).reduce(0, +)
        let crashes = results.map(\.counts.crashes).reduce(0, +)
        print("R-STO-4 index states \(row.testDescription) tmp=*: \(results.count) initial disks, \(cases) cases (\(faults) faults, \(crashes) crash points) enumerated")
    }
}

extension IndexCommitStateSpaceTests {
    @Test("R-STO-4: the state space holds every initial disk once: 13 states of index.bin and index.prev, 14 of index.tmp, 3 volume scripts")
    func spaceIsComplete() {
        let forged: [SeededIndex] = [.forged9As10, .forged9As11, .forged10As9, .forged10As11, .forged11As9, .forged11As10]
        #expect(SeededIndex.allCases == [.absent, .older, .committed, .newer, .newerUnsynced, .badHeader, .badBody, .truncated] + forged)
        #expect(SeededIndex.renamedInto == SeededIndex.allCases.filter { $0 != .newerUnsynced })
        #expect(SeededIndex.unforged == SeededIndex.allCases.filter { !forged.contains($0) })
        // Every ordered pair of distinct valid generations once: each file of every lineage generation, named as another.
        let pairs = forged.compactMap(\.forgery).map { "\($0.source)>\($0.named)" }
        let valid: [UInt64] = [9, 10, 11]
        let expectedPairs = valid.flatMap { source in valid.filter { $0 != source }.map { "\(source)>\($0)" } }
        #expect(Set(pairs) == Set(expectedPairs) && pairs.count == 6)
        #expect(VolumeScript.allCases == [.free, .fullAtClose, .fullFromLaunch])
        let slices = IndexSpaceRow.all.flatMap(\.slices)
        let expected = SeededIndex.renamedInto.flatMap { bin in
            SeededIndex.renamedInto.flatMap { previous in
                SeededIndex.allCases.map { "bin=\(bin) prev=\(previous) tmp=\($0)" }
            }
        }
        #expect(IndexSpaceRow.all.count == 169 && slices.count == 2_366 && Set(expected).count == 2_366)
        #expect(Set(slices.map(\.testDescription)) == Set(expected), "every combination of the three files once")
        let unforged = IndexSpaceRow.unforged.flatMap(\.slices)
        #expect(IndexSpaceRow.unforged.count == 49 && unforged.count == 392)
        #expect(unforged.allSatisfy { $0.bin.forgery == nil && $0.previous.forgery == nil && $0.temporary.forgery == nil })
    }
}

/// The kill survivors whose index names no root sync has ordered yet (close-out cycle 4, review "state-space enumeration:
/// pruning justification"; ADR drafts B-33, B-36). The initial disks are every distinct kill survivor of the fault-free
/// lifetimes of the row's disks (`IndexSpaceRow.unforged`: the main enumeration's disks without a forged header; the
/// suite's size is pinned, close-out cycle 5) on every volume script, whose three crash views differ
/// (a rename or a removal not yet ordered by a root sync, or data not yet synced). A power loss can undo what the load
/// read there until a root sync orders it, and the first one is `open()`'s barrier: the store counts nothing committed
/// before it (B-36), and once it succeeded every index name is ordered, which the fault-free case checks; the rest of
/// that lifetime starts from a disk of the seeded space (up to its generation numbers, and the unsynced data of an
/// `index.tmp`, which reads as torn like an absent one).
/// So each disk runs, on every volume script: no fault; EIO and ENOSPC at the root barrier, the lifetime then going on
/// with names a power loss can still undo (every commit attempt checked, the end checked under every crash view,
/// reopened, and I-e on a free volume); and once, a crash before the barrier in each mode. The invariants are those of
/// `IndexCommitStateSpaceTests`, with I-a's floor the newest valid generation the same crash leaves of the initial disk.
/// A one-off run of the full single-event enumeration (every fault at every operation, every crash at every mutation)
/// over these survivors and the main enumeration's unsynced disks (1,822 disks, 467,719 cases) found 564 violations
/// before B-36, all in lifetimes whose barrier failed, and none after it; this suite finds the same class (ADR draft B-36).
@Suite("Core: index commit state space from unordered names (R-STO-4, R-STO-5)", .serialized)
struct IndexCommitUnorderedNamesTests {
    @Test(
        "R-STO-5: every kill survivor with unordered index names, with a fault at open()'s root barrier or a crash before it, keeps I-a…I-e",
        .timeLimit(.minutes(1)),
        arguments: IndexSpaceRow.unforged
    )
    @available(macOS 15.0, *)
    func everyUnorderedSurvivor(row: IndexSpaceRow) async throws {
        let index = try #require(IndexSpaceRow.unforged.firstIndex { $0.testDescription == row.testDescription })
        let survivors = await UnorderedSurvivors.shared.survivors(at: index)
        let results = await withTaskGroup(of: IndexSpace.SliceResult.self) { group in
            for (index, survivor) in survivors.enumerated() {
                group.addTask(priority: .low) {
                    await IndexSpace.enumerateUnordered(survivor, label: "\(row.testDescription) survivor \(index) (\(survivor.origin))")
                }
            }
            var results: [IndexSpace.SliceResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        let violations = results.sorted { $0.slice < $1.slice }.flatMap(\.violations)
        let shown = violations.prefix(40).joined(separator: "\n")
        #expect(violations.isEmpty, "\(violations.count) violations from the unordered survivors of \(row.testDescription); the first ones:\n\(shown)")
        #expect(results.count == survivors.count, "every survivor ran")
        for result in results {
            let counts = result.counts
            #expect(counts.faultFree == VolumeScript.allCases.count, "\(result.slice): one fault-free lifetime per volume script")
            #expect(counts.faults == 2 * VolumeScript.allCases.count, "\(result.slice): EIO and ENOSPC at the barrier on every volume script")
            #expect(counts.crashes == 3, "\(result.slice): a crash before the barrier in each mode")
            #expect(counts.cases == counts.faultFree + counts.faults + counts.crashes)
        }
        let cases = results.map(\.counts.cases).reduce(0, +)
        print("R-STO-5 unordered names \(row.testDescription) tmp=*: \(survivors.count) kill survivors first met in this row, \(cases) cases enumerated")
    }

    @Test("R-STO-5: the unordered-name survivors are every distinct kill survivor of the fault-free lifetimes whose crash views differ", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func unorderedSurvivorsAreComplete() async {
        let rows = await UnorderedSurvivors.shared.all()
        let survivors = rows.flatMap { $0 }
        let keys = survivors.map { IndexSpace.ViewsKey(current: $0.start.current, dropped: $0.start.dropped, kept: $0.start.kept) }
        #expect(rows.count == IndexSpaceRow.unforged.count)
        #expect(Set(keys).count == survivors.count, "each survivor once")
        #expect(survivors.allSatisfy { $0.start.current != $0.start.dropped || $0.start.kept != $0.start.current }, "every crash view of a survivor is not the same")
        #expect(survivors.contains { $0.start.dropped != $0.start.kept }, "some survivor has a name a power loss undoes")
        print("R-STO-5 unordered names: \(survivors.count) distinct kill survivors")
    }
}

/// The kill survivors of `IndexCommitUnorderedNamesTests`, computed once for the whole suite and row by row: each row
/// enumerates the survivors first met in its own lifetimes, so a survivor that two rows' lifetimes both leave runs once,
/// and a row computes only its own lifetimes when the rows run in order (the first one does not pay for all 49). Rows
/// are appended in the order of `IndexSpaceRow.unforged`; read-only once appended, and the same on every run (the
/// lifetimes are deterministic).
@available(macOS 15.0, *)
actor UnorderedSurvivors {
    static let shared = UnorderedSurvivors()
    private var rows: [[IndexSpace.Survivor]] = []
    private var seen: Set<IndexSpace.ViewsKey> = []

    /// The survivors first met in the row at `index` of `IndexSpaceRow.unforged`, computing the rows before it first.
    func survivors(at index: Int) async -> [IndexSpace.Survivor] {
        while self.rows.count <= index {
            let next = self.rows.count
            var seen = self.seen
            // REENTRANCY: test support — the row is kept only if no other caller appended it meanwhile (the loop re-reads
            // the count); both computed the same row from the same `seen`.
            let survivors = await IndexSpace.unorderedSurvivors(of: IndexSpaceRow.unforged[next], excluding: &seen)
            if self.rows.count == next {
                self.rows.append(survivors)
                self.seen = seen
            }
        }
        return self.rows[index]
    }

    /// The survivors of every row, in the order of `IndexSpaceRow.unforged`.
    func all() async -> [[IndexSpace.Survivor]] {
        // REENTRANCY: test support — nothing is re-read: every row is appended once the call returns.
        _ = await self.survivors(at: IndexSpaceRow.unforged.count - 1)
        return self.rows
    }
}

/// The machinery of the state-space test.
@available(macOS 15.0, *)
enum IndexSpace {
    /// The fake volume's root and the store's base on it: shallow, so every path the fake resolves is short.
    static let volume = URL(fileURLWithPath: "/v", isDirectory: true)
    static let layout = StoreLayout(base: IndexSpace.volume)
    static let seed: UInt64 = 0x1D3
    static let storeID = StoreIdentifier.derived(fromSeed: IndexSpace.seed)
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Stands for the case's description in a memoised violation; replaced when the violation is reported.
    static let here = "‹case›"

    /// The index files of a disk view, by path.
    typealias Files = [String: [UInt8]]

    // MARK: Disks and views

    static func path(_ file: IndexFile) -> String {
        IndexSpace.layout.indexURL(file).path
    }

    /// A fake on `disk` (configured for a kill unless `mode` says otherwise).
    static func fake(_ disk: DiskImage, crashBefore: Int? = nil, mode: CrashMode = .processKill) -> FakeFileSystem {
        let configuration = FakeFileSystemConfiguration(crashBefore: crashBefore, crashMode: mode, volumeRoot: IndexSpace.volume)
        return FakeFileSystem(disk: disk, time: ManualTimeSource(), configuration: configuration)
    }

    /// The encoded generation `generation` of the lineage.
    static func encoded(_ generation: UInt64) -> [UInt8] {
        var content = IndexContent.empty(storeID: IndexSpace.storeID)
        content.generation = generation
        content.launchEpoch = generation
        return [UInt8](IndexCodec.encode(content) ?? Data())
    }

    /// The bytes `seeded` puts at `file`.
    static func bytes(_ seeded: SeededIndex, at file: IndexFile) -> [UInt8]? {
        if let forgery = seeded.forgery {
            return IndexSpace.forged(IndexSpace.encoded(forgery.source), naming: forgery.named)
        }
        guard let generation = seeded.generation(at: file) else {
            return nil
        }
        var bytes = IndexSpace.encoded(generation)
        switch seeded {
        case .badHeader:
            bytes[0] ^= 0xFF
        case .badBody:
            bytes[IndexHeader.length] ^= 0xFF
        case .truncated:
            bytes.removeLast(bytes.count / 2)
        case .absent, .older, .committed, .newer, .newerUnsynced, .forged9As10, .forged9As11, .forged10As9, .forged10As11, .forged11As9, .forged11As10:
            break
        }
        return bytes
    }

    /// `bytes` (a valid generation) with its header's generation field set to `generation` and everything else, the
    /// trailer included, unchanged: the size is still right and the header still parses, only the trailer fails (bit rot
    /// in the generation field; the header has no checksum of its own).
    static func forged(_ bytes: [UInt8], naming generation: UInt64) -> [UInt8] {
        guard var header = IndexHeader.parse(bytes) else {
            return bytes
        }
        header.generation = generation
        var forged = bytes
        forged.replaceSubrange(0..<IndexHeader.length, with: header.encoded())
        return forged
    }

    /// The initial disk of `slice`: the store's directories and the index files, all synced except an unsynced
    /// `index.tmp`; it carries the fake's inode graph, so every case starts from the identical volume.
    static func disk(_ slice: IndexSpaceSlice) -> DiskImage {
        var image = DiskImage()
        var directory = IndexSpace.layout.blobsDirectory
        while directory.path != "/" {
            image.directories.insert(directory.path)
            directory = directory.deletingLastPathComponent()
        }
        for file in IndexFile.allCases {
            if let bytes = IndexSpace.bytes(slice.seeded(file), at: file) {
                image.files[IndexSpace.path(file)] = bytes
            }
        }
        image.makeDurable()
        if slice.temporary == .newerUnsynced {
            image.durableFiles[IndexSpace.path(.temporary)] = nil
        }
        return IndexSpace.fake(image).survivingDisk()
    }

    /// The index files of a disk under each crash view.
    struct Views: Sendable {
        /// The current namespace: what a kill leaves.
        var current: Files
        /// Synced names with synced data: what a power loss dropping unsynced state leaves.
        var dropped: Files
        /// The namespace as applied with synced data: what a power loss keeping metadata leaves.
        var kept: Files

        /// The view a crash of `mode` leaves.
        func files(after mode: CrashMode) -> Files {
            switch mode {
            case .processKill, .processKillTornWrite:
                return self.current
            case .powerLossDropUnsynced:
                return self.dropped
            case .powerLossKeepMetadata:
                return self.kept
            }
        }
    }

    /// The disk a crash of `mode` leaves of `disk` (a disk taken from a fake configured for a kill).
    static func surviving(_ disk: DiskImage, _ mode: CrashMode) -> DiskImage {
        IndexSpace.fake(disk, mode: mode).survivingDisk()
    }

    /// The three views of `disk` (a disk taken from a fake configured for a kill, so `files` is its current namespace).
    static func views(_ disk: DiskImage) -> Views {
        Views(current: disk.files, dropped: disk.durableFiles, kept: IndexSpace.surviving(disk, .powerLossKeepMetadata).files)
    }

    /// The load rule over the index files of a view.
    static func choose(_ files: Files) -> IndexLoadOutcome {
        var reads: [IndexFile: IndexFileRead] = [:]
        for file in IndexFile.allCases {
            if let bytes = files[IndexSpace.path(file)] {
                reads[file] = IndexFileRead(size: Int64(bytes.count), bytes: bytes)
            }
        }
        return IndexLoadRule.choose(reads)
    }

    /// The index files of a view, for a failure message.
    static func describe(_ files: Files) -> String {
        IndexFile.allCases.map { file -> String in
            guard let bytes = files[IndexSpace.path(file)] else {
                return "\(file.rawValue) absent"
            }
            if let content = try? IndexCodec.decode(bytes).get() {
                return "\(file.rawValue) \(content.generation)"
            }
            return "\(file.rawValue) invalid (header \(IndexHeader.parse(bytes).map { String($0.generation) } ?? "none"))"
        }.joined(separator: ", ")
    }

    // MARK: Memo

    /// What the checks need of a view, computed once per distinct view.
    struct Summary {
        /// The newest valid generation the load rule chooses (0 when none).
        var newest: UInt64
        /// The next launch's epoch.
        var nextGeneration: UInt64
        /// The generations of the valid files.
        var generations: Set<UInt64>
        /// Whether `index.bin` is valid.
        var currentIsValid: Bool
    }

    /// A reopen's key: the survivor's index files as a kill and as a power loss keeping metadata leave them.
    struct ReopenKey: Hashable {
        var current: Files
        var kept: Files
    }

    /// What a fault-free launch on a free volume did to a survivor.
    struct Reopen {
        var launchCommitted: Bool
        var epoch: UInt64
        var loaded: UInt64
        var claimed: UInt64
        var end: Files
        var endDurable: Files
    }

    /// One mutation's effect on the volume. A failed mutation other than a write changes nothing on the fake (an injected
    /// error fails it before it acts), so it has no effect; a failed write has opened, created and truncated its file.
    struct Effect: Hashable {
        var kind: FSOpKind
        var path: String
        var destination: String?
        var failed: Bool
    }

    /// Everything a lifetime keeps in memory that a check or a later commit reads.
    struct Bookkeeping: Hashable {
        var committed: UInt64
        var pending: UInt64?
        var claimed: UInt64
        var epoch: UInt64
        var loaded: UInt64
        var storeID: StoreIdentifier
        var generation: UInt64
        var launchCommitted: Bool
        var flushCommitted: Bool
        var readOnly: Bool
    }

    /// What a run has done so far: the effects of its mutations from the initial disk, and its bookkeeping after the load
    /// and after each commit. The fake is deterministic, so two runs from one initial disk with equal keys left the same
    /// volume (every effect is a function of the volume before it, and the bytes a commit writes are a function of its
    /// bookkeeping) and the same bookkeeping: every later check gives the same answer, and is computed once.
    struct RunKey: Hashable {
        var effects: [Effect] = []
        var bookkeeping: [Bookkeeping] = []
    }

    /// The memoised result of the checks after one commit.
    struct Checkpoint {
        var violations: [String]
        var currentIsValid: Bool
    }

    /// The per-test-case caches and counters (no state is shared between test cases).
    struct Memo {
        var summaries: [Files: Summary] = [:]
        var reopens: [ReopenKey: Reopen] = [:]
        var checkpoints: [RunKey: Checkpoint] = [:]
        var ends: [RunKey: [String]] = [:]
        var counts = Counts()
    }

    /// What was enumerated, and what the fault-free runs say should have been: one fault-free case per volume script,
    /// EIO at every operation, ENOSPC at every mutation and a lost rename result at every rename, and a crash before
    /// every mutation in three modes plus a torn write before every write.
    struct Counts: Sendable {
        var cases = 0
        var faultFree = 0
        var faults = 0
        var crashes = 0
        var expectedFaults = 0
        var expectedCrashes = 0
    }

    static func summary(_ files: Files, _ memo: inout Memo) -> Summary {
        if let known = memo.summaries[files] {
            return known
        }
        let outcome = IndexSpace.choose(files)
        var generations: Set<UInt64> = []
        var currentIsValid = false
        for file in IndexFile.allCases {
            if let bytes = files[IndexSpace.path(file)], let content = try? IndexCodec.decode(bytes).get() {
                generations.insert(content.generation)
                currentIsValid = currentIsValid || file == .current
            }
        }
        let summary = Summary(
            newest: outcome.content?.generation ?? 0,
            nextGeneration: outcome.nextGeneration,
            generations: generations,
            currentIsValid: currentIsValid
        )
        memo.summaries[files] = summary
        return summary
    }

    /// The effects of the mutations among `operations`.
    static func effects(_ operations: ArraySlice<FSOpRecord>) -> [Effect] {
        operations.compactMap { operation -> Effect? in
            guard operation.kind.isMutation, operation.failure == nil || operation.kind == .write else {
                return nil
            }
            return Effect(kind: operation.kind, path: operation.url.path, destination: operation.destination?.path, failed: operation.failure != nil)
        }
    }

    // MARK: One lifetime

    /// The in-memory state of a lifetime between its phases.
    struct Progress {
        var ledger: IndexCommitLedger
        /// The newest generation the store counted committed: the loaded one (the surviving one when it loaded
        /// `index.tmp`), raised by durable promotions and successful commits.
        var claimed: UInt64
        var epoch: UInt64
        var loaded: UInt64
        var storeID: StoreIdentifier
        var generation: UInt64
        var launchCommitted = false
        /// Whether close()'s durable flush succeeded.
        var flushCommitted = false
        /// The load could not read an index file: `open()` commits nothing in this lifetime and `close()` flushes
        /// nothing (`LaunchState.unavailable`, ADR draft B-34).
        var readOnly = false

        var bookkeeping: Bookkeeping {
            Bookkeeping(
                committed: self.ledger.committedGeneration,
                pending: self.ledger.pendingPromotion,
                claimed: self.claimed,
                epoch: self.epoch,
                loaded: self.loaded,
                storeID: self.storeID,
                generation: self.generation,
                launchCommitted: self.launchCommitted,
                flushCommitted: self.flushCommitted,
                readOnly: self.readOnly
            )
        }
    }

    /// A lifetime in progress: its bookkeeping, its key, whether `index.bin` is valid now, and the violations found so far
    /// (described with `here`).
    struct Run {
        var progress: Progress
        var key: RunKey
        var currentIsValid: Bool
        var violations: [String] = []
    }

    /// The load, as `open()` does it, and `open()`'s root barrier before the launch commit (ADR-015; a failed barrier is
    /// tolerated, and the loaded generation then counts as committed only after a commit succeeded, ADR draft B-36).
    /// Before the barrier the store counts nothing committed (a `MutationRecorder` starts at 0); the caller tells the
    /// recorder what the store counts from the launch commit on.
    static func open(on fileSystem: any FileSystem, fake: FakeFileSystem) async -> Run {
        let inline = InlineBlockingExecutor()
        let layout = IndexSpace.layout
        let outcome = await IndexLoader.load(layout: layout, fileSystem: fileSystem, metadata: inline, bulk: inline)
        let launch = LaunchState.build(outcome: outcome, onDisk: [:], blobsRecreated: false, seed: IndexSpace.seed, now: IndexSpace.now, layout: layout)
        let rootOrdered = (try? fileSystem.synchronizeDirectory(at: layout.root, level: .barrier)) != nil
        let committed = launch.committedGeneration(rootOrdered: rootOrdered)
        let progress = Progress(
            ledger: IndexCommitLedger(committedGeneration: committed, pendingPromotion: launch.promotion),
            claimed: committed,
            epoch: launch.nextGeneration,
            loaded: outcome.content?.generation ?? 0,
            storeID: launch.storeID,
            generation: launch.nextGeneration,
            readOnly: launch.unavailable != nil
        )
        let key = RunKey(effects: IndexSpace.effects(fake.operations[...]), bookkeeping: [progress.bookkeeping])
        return Run(progress: progress, key: key, currentIsValid: false)
    }

    /// The commit at `index` (0: the ordered launch commit, 1: close()'s durable flush), folded as `commitNow` folds it;
    /// returns whether it succeeded. A read-only lifetime runs no commit, as `open()` and `close()` run none.
    static func commit(_ index: Int, _ progress: inout Progress, on fileSystem: any FileSystem) -> Bool {
        guard !progress.readOnly else {
            return false
        }
        var content = IndexContent.empty(storeID: progress.storeID)
        content.generation = progress.generation
        content.launchEpoch = progress.epoch
        let input = IndexCommitInput(
            layout: IndexSpace.layout,
            content: content,
            dirtyFanOuts: [],
            blobsDirectoryDirty: index == 0,
            durability: index == 0 ? .ordered : .durable,
            lock: nil,
            committedGeneration: progress.ledger.committedGeneration,
            promotion: progress.ledger.pendingPromotion
        )
        progress.generation += 1
        let result = IndexCommitUnit.run(input, fileSystem: fileSystem)
        progress.ledger = progress.ledger.recording(result, of: input)
        progress.claimed = max(progress.claimed, progress.ledger.committedGeneration)
        let succeeded = (try? result.result.get()) != nil
        if index == 0 {
            progress.launchCommitted = succeeded
        } else {
            progress.flushCommitted = succeeded
        }
        return succeeded
    }

    /// The no-fault run at the start of one commit, to resume a run with a fault or a torn write from.
    struct Phase {
        var disk: DiskImage
        var run: Run
        /// The commit that starts here.
        var commit: Int
        /// The length of the no-fault run's operation log here.
        var operations: Int
        /// The mutations the no-fault run performed before here.
        var mutations: Int
    }

    /// Runs the commits from `first` on, checking I-b and I-c after each (once per distinct key; the fake is configured
    /// for a kill, so its surviving disk is its current state). `phase` sees the run at the start of each commit.
    static func runCommits(
        from first: Int,
        _ run: inout Run,
        on fileSystem: any FileSystem,
        fake: FakeFileSystem,
        volume: VolumeScript,
        memo: inout Memo,
        phase: ((Int, Run) -> Void)? = nil
    ) {
        var full = false
        for index in first..<2 {
            phase?(index, run)
            if volume.isFull(atCommit: index), !full {
                fake.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
                full = true
            }
            let logged = fake.operations.count
            let succeeded = IndexSpace.commit(index, &run.progress, on: fileSystem)
            guard !run.progress.readOnly else {
                continue
            }
            run.key.effects += IndexSpace.effects(fake.operations[logged...])
            run.key.bookkeeping.append(run.progress.bookkeeping)
            let checkpoint: Checkpoint
            if let known = memo.checkpoints[run.key] {
                checkpoint = known
            } else {
                let files = fake.survivingDisk().files
                let after = IndexSpace.summary(files, &memo)
                var found: [String] = []
                let attempt = "\(IndexSpace.here), after the \(index == 0 ? "launch commit" : "durable flush") (\(succeeded ? "succeeded" : "failed"))"
                let committed = run.progress.ledger.committedGeneration
                if committed > 0, !after.generations.contains(committed) {
                    found.append("\(attempt): I-b, the committed generation \(committed) is not on disk (\(IndexSpace.describe(files)))")
                }
                if !succeeded, run.currentIsValid, !after.currentIsValid {
                    found.append("\(attempt): I-c, index.bin was valid before the failed commit and is \(files[IndexSpace.path(.current)] == nil ? "missing" : "invalid") after it")
                }
                checkpoint = Checkpoint(violations: found, currentIsValid: after.currentIsValid)
                memo.checkpoints[run.key] = checkpoint
            }
            run.violations += checkpoint.violations
            run.currentIsValid = checkpoint.currentIsValid
        }
    }

    // MARK: Checks

    /// The floor of I-a after a crash of `mode` (or at the end of a run, `mode` being a kill there): the newest valid
    /// generation of the initial disk under that view, and every generation the store counted committed.
    static func floor(_ start: Views, _ mode: CrashMode, claimed: UInt64, _ memo: inout Memo) -> UInt64 {
        max(claimed, IndexSpace.summary(start.files(after: mode), &memo).newest)
    }

    /// I-a, I-5 and, for a store that reported `claimed` (`checkCommitted`), I-b over one crash view of what a case left.
    static func checkSurvivor(_ files: Files, view: String, floor: UInt64, claimed: UInt64, checkCommitted: Bool = true, label: String, _ memo: inout Memo) -> [String] {
        var violations: [String] = []
        let summary = IndexSpace.summary(files, &memo)
        if summary.newest < floor {
            violations.append("\(label): I-a, \(view) leaves generation \(summary.newest) (\(IndexSpace.describe(files))), below \(floor)")
        }
        if checkCommitted, claimed > 0, !summary.generations.contains(claimed) {
            violations.append("\(label): I-b, the committed generation \(claimed) is not valid after \(view) (\(IndexSpace.describe(files)))")
        }
        if summary.nextGeneration <= claimed {
            violations.append("\(label): I-5, the next epoch \(summary.nextGeneration) after \(view) does not exceed the committed generation \(claimed)")
        }
        return violations
    }

    /// The reopen of a survivor (I-a, I-b, I-d): computed once per `key`; `disk` builds the survivor on a miss.
    static func checkReopen(_ key: ReopenKey, disk: () -> DiskImage, floor: UInt64, claimed: UInt64, label: String, _ memo: inout Memo) async -> [String] {
        let reopen: Reopen
        if let known = memo.reopens[key] {
            reopen = known
        } else {
            let fake = IndexSpace.fake(disk())
            var run = await IndexSpace.open(on: fake, fake: fake)
            _ = IndexSpace.commit(0, &run.progress, on: fake)
            let end = fake.survivingDisk()
            reopen = Reopen(
                launchCommitted: run.progress.launchCommitted,
                epoch: run.progress.epoch,
                loaded: run.progress.loaded,
                claimed: run.progress.claimed,
                end: end.files,
                endDurable: end.durableFiles
            )
            memo.reopens[key] = reopen
        }
        var violations: [String] = []
        let reopened = "\(label) → reopen"
        if !reopen.launchCommitted {
            violations.append("\(reopened): a fault-free launch commit on a free volume failed")
        }
        if reopen.epoch <= claimed {
            violations.append("\(reopened): I-5, launch epoch \(reopen.epoch) does not exceed the committed generation \(claimed)")
        }
        // A successful fault-free commit leaves every index file synced and named in a synced listing, so the view a power
        // loss keeping metadata leaves is the current one.
        for (view, files) in [("a kill", reopen.end), ("a power loss dropping unsynced state", reopen.endDurable)] {
            violations += IndexSpace.checkSurvivor(files, view: view, floor: max(floor, reopen.claimed), claimed: reopen.claimed, label: reopened, &memo)
            let second = IndexSpace.summary(files, &memo)
            if second.newest < reopen.loaded || second.nextGeneration <= reopen.epoch {
                violations.append("\(reopened) → \(view) → launch: I-d, generation \(second.newest) and epoch \(second.nextGeneration) after a launch that loaded \(reopen.loaded) with epoch \(reopen.epoch)")
            }
        }
        return violations
    }

    /// The checks at the end of a run that did not crash (the process ends, as a kill; or the power fails right after),
    /// and its reopen: once per distinct key.
    static func finish(_ run: Run, fake: FakeFileSystem, start: Views, memo: inout Memo) async -> [String] {
        if let known = memo.ends[run.key] {
            return run.violations + known
        }
        let end = fake.survivingDisk()
        let views = IndexSpace.views(end)
        let claimed = run.progress.claimed
        var found: [String] = []
        for (mode, view) in [(CrashMode.processKill, "a kill at the end"), (.powerLossDropUnsynced, "a power loss dropping unsynced state at the end"), (.powerLossKeepMetadata, "a power loss keeping metadata at the end")] {
            let floor = IndexSpace.floor(start, mode, claimed: claimed, &memo)
            found += IndexSpace.checkSurvivor(views.files(after: mode), view: view, floor: floor, claimed: claimed, label: IndexSpace.here, &memo)
        }
        let key = ReopenKey(current: views.current, kept: views.kept)
        found += await IndexSpace.checkReopen(key, disk: { end }, floor: IndexSpace.floor(start, .processKill, claimed: claimed, &memo), claimed: claimed, label: IndexSpace.here, &memo)
        memo.ends[run.key] = found
        return run.violations + found
    }

    /// `violations` described with `here`, described with `label` instead.
    static func labelled(_ violations: [String], _ label: String) -> [String] {
        violations.map { $0.replacingOccurrences(of: IndexSpace.here, with: label) }
    }

    // MARK: The enumeration of one initial disk and volume script

    /// What one initial disk's enumeration found.
    struct SliceResult: Sendable {
        var slice: String
        var violations: [String]
        var counts: Counts
    }

    /// Every volume script and every event for `slice`, yielding after each case.
    static func enumerate(_ slice: IndexSpaceSlice, initial: DiskImage, start: Views) async -> SliceResult {
        var memo = Memo()
        var violations: [String] = []
        for volume in VolumeScript.allCases {
            violations += await IndexSpace.enumerate(slice, initial: initial, start: start, volume: volume, memo: &memo)
        }
        return SliceResult(slice: slice.testDescription, violations: violations, counts: memo.counts)
    }

    /// Every event for `slice` on `volume`; returns the violations.
    static func enumerate(_ slice: IndexSpaceSlice, initial: DiskImage, start: Views, volume: VolumeScript, memo: inout Memo) async -> [String] {
        var violations: [String] = []
        let label = "\(slice.testDescription) volume=\(volume)"
        // No fault, recorded: the disk before every mutation, and at the start of every commit.
        let clean = IndexSpace.fake(initial)
        let recorder = MutationRecorder(clean)
        var run = await IndexSpace.open(on: recorder, fake: clean)
        run.currentIsValid = IndexSpace.summary(clean.survivingDisk().files, &memo).currentIsValid
        var phases: [Phase] = []
        IndexSpace.runCommits(from: 0, &run, on: recorder, fake: clean, volume: volume, memo: &memo) { index, run in
            recorder.setClaimed(run.progress.claimed)
            phases.append(Phase(disk: clean.survivingDisk(), run: run, commit: index, operations: clean.operations.count, mutations: clean.mutationCount))
        }
        violations += IndexSpace.labelled(await IndexSpace.finish(run, fake: clean, start: start, memo: &memo), "\(label) no fault")
        memo.counts.cases += 1
        memo.counts.faultFree += 1
        let operations = clean.operations
        let mutationCount = operations.filter(\.kind.isMutation).count
        memo.counts.expectedFaults += operations.count + mutationCount + operations.filter { $0.kind == .rename }.count
        memo.counts.expectedCrashes += 3 * mutationCount + operations.filter { $0.kind == .write }.count
        // One fault at every operation.
        for operation in operations {
            var events: [Event] = [.fault(operation, .io)]
            if operation.kind.isMutation {
                events.append(.fault(operation, .noSpace))
            }
            if operation.kind == .rename {
                events.append(.renameTookEffect(operation))
            }
            let phase = phases.last { $0.operations <= operation.index }
            for event in events {
                violations += await IndexSpace.runFault(event, from: phase, operations: operations, initial: initial, start: start, volume: volume, label: "\(label) \(event)", memo: &memo)
                memo.counts.cases += 1
                memo.counts.faults += 1
                await Task.yield()
            }
        }
        // A crash before every mutation, in every mode.
        let mutations = operations.filter(\.kind.isMutation)
        let snapshots = recorder.snapshots
        guard snapshots.count == mutations.count else {
            return violations + ["\(label): recorded \(snapshots.count) disks for \(mutations.count) mutations"]
        }
        for (point, snapshot) in snapshots.enumerated() {
            let phase = phases.last { $0.mutations <= point }
            violations += await IndexSpace.checkCrashes(at: point, snapshot, mutation: mutations[point], from: phase, start: start, volume: volume, label: label, memo: &memo)
            await Task.yield()
        }
        return violations
    }

    /// One case with an injected fault, resumed from `phase` (the start of the commit the fault falls in) when given.
    static func runFault(_ event: Event, from phase: Phase?, operations: [FSOpRecord], initial: DiskImage, start: Views, volume: VolumeScript, label: String, memo: inout Memo) async -> [String] {
        let fake = IndexSpace.fake(phase?.disk ?? initial)
        let offset = phase?.operations ?? 0
        let earlier = operations[offset...]
        let fileSystem: any FileSystem
        let fired: () -> Bool
        switch event {
        case .fault(let operation, let error):
            let matcher = URLMatcher(lastComponentSuffix: operation.url.lastPathComponent, pathContains: operation.url.path)
            let before = earlier.prefix { $0.index < operation.index }.filter { $0.kind == operation.kind && matcher.matches($0.url) }.count
            fake.addFault(FaultRule(operation: operation.kind, matching: matcher, occurrence: .nth(before + 1), error: error))
            fileSystem = fake
            fired = {
                let log = fake.operations
                let position = operation.index - offset
                return log.count > position && log[position].kind == operation.kind && log[position].url == operation.url && log[position].failure == error
            }
        case .renameTookEffect(let operation):
            let before = earlier.prefix { $0.index < operation.index }.filter { $0.kind == .rename }.count
            let wrapper = MisreportingFileSystem(fake, failing: before + 1)
            fileSystem = wrapper
            fired = { wrapper.fired }
        case .none, .crash:
            return ["\(label): not a fault"]
        }
        var run: Run
        if let phase {
            run = phase.run
            // The resumed run's own log starts empty; its key goes on from the no-fault run's key at the phase.
        } else {
            run = await IndexSpace.open(on: fileSystem, fake: fake)
            run.currentIsValid = IndexSpace.summary(fake.survivingDisk().files, &memo).currentIsValid
        }
        IndexSpace.runCommits(from: phase?.commit ?? 0, &run, on: fileSystem, fake: fake, volume: volume, memo: &memo)
        var violations = IndexSpace.labelled(await IndexSpace.finish(run, fake: fake, start: start, memo: &memo), label)
        if !fired() {
            violations.append("\(label): the fault never fired")
        }
        // I-e: on a free volume, a fault before close()'s flush does not outlive its commit: the flush, which meets no
        // fault of its own, succeeds (unless the load could not read the index, when nothing is committed at all).
        if volume == .free, (phase?.commit ?? 0) == 0, !run.progress.readOnly, !run.progress.flushCommitted {
            violations.append("\(label): I-e, close()'s durable flush failed after the fault, with none of its own")
        }
        return violations
    }

    /// The crashes before mutation `point`: the recorded disk under each power loss and as a kill, and a torn write run
    /// again (from the start of its commit) when the mutation is a write.
    static func checkCrashes(
        at point: Int,
        _ snapshot: MutationRecorder.Snapshot,
        mutation: FSOpRecord,
        from phase: Phase?,
        start: Views,
        volume: VolumeScript,
        label: String,
        memo: inout Memo
    ) async -> [String] {
        var violations: [String] = []
        let claimed = snapshot.claimed
        let keptDisk = IndexSpace.surviving(snapshot.disk, .powerLossKeepMetadata)
        var survivors: [(CrashMode, Files, ReopenKey, () -> DiskImage)] = [
            (.processKill, snapshot.disk.files, ReopenKey(current: snapshot.disk.files, kept: keptDisk.files), { snapshot.disk }),
            (.powerLossDropUnsynced, snapshot.disk.durableFiles, ReopenKey(current: snapshot.disk.durableFiles, kept: snapshot.disk.durableFiles), { IndexSpace.surviving(snapshot.disk, .powerLossDropUnsynced) }),
            (.powerLossKeepMetadata, keptDisk.files, ReopenKey(current: keptDisk.files, kept: keptDisk.files), { keptDisk }),
        ]
        if mutation.kind == .write {
            if let phase {
                let torn = IndexSpace.fake(phase.disk, crashBefore: point - phase.mutations, mode: .processKillTornWrite)
                var run = phase.run
                var scratch = Memo()
                IndexSpace.runCommits(from: phase.commit, &run, on: torn, fake: torn, volume: volume, memo: &scratch)
                if torn.crashed {
                    let disk = torn.survivingDisk()
                    let tornKept = IndexSpace.surviving(disk, .powerLossKeepMetadata)
                    survivors.append((.processKillTornWrite, disk.files, ReopenKey(current: disk.files, kept: tornKept.files), { disk }))
                } else {
                    violations.append("\(label) \(Event.crash(point, .processKillTornWrite)): the crash point was never reached")
                }
            } else {
                violations.append("\(label) \(Event.crash(point, .processKillTornWrite)): a write before the launch commit")
            }
        }
        for (mode, files, key, disk) in survivors {
            let caseLabel = "\(label) \(Event.crash(point, mode))"
            let floor = IndexSpace.floor(start, mode, claimed: claimed, &memo)
            // I-b is a property of a store that reports; a crash inside a unit is checked by I-a against what the store
            // counted committed before the unit (a promotion inside it may legitimately replace that generation).
            violations += IndexSpace.checkSurvivor(files, view: "the crash", floor: floor, claimed: claimed, checkCommitted: false, label: caseLabel, &memo)
            violations += await IndexSpace.checkReopen(key, disk: disk, floor: floor, claimed: claimed, label: caseLabel, &memo)
            memo.counts.cases += 1
            memo.counts.crashes += 1
        }
        return violations
    }

    /// The seeded disk is what `slice` describes.
    static func checkSeed(_ slice: IndexSpaceSlice, _ start: Views) throws {
        for file in IndexFile.allCases {
            let seeded = slice.seeded(file)
            let bytes = start.current[IndexSpace.path(file)]
            let valid = bytes.flatMap { try? IndexCodec.decode($0).get() }?.generation
            switch seeded {
            case .absent:
                try #require(bytes == nil, "\(slice.testDescription): \(file) is absent")
            case .older, .committed, .newer, .newerUnsynced:
                try #require(valid == seeded.generation(at: file), "\(slice.testDescription): \(file) is valid")
            case .badHeader:
                try #require(bytes != nil && valid == nil && IndexHeader.parse(bytes ?? []) == nil, "\(slice.testDescription): \(file) has a bad header")
            case .badBody, .truncated:
                let header = IndexHeader.parse(bytes ?? [])
                try #require(bytes != nil && valid == nil && header?.generation == seeded.generation(at: file), "\(slice.testDescription): \(file) is rotten behind a valid header")
            case .forged9As10, .forged9As11, .forged10As9, .forged10As11, .forged11As9, .forged11As10:
                // A copy of the source generation, the right size, a header that parses and names another generation,
                // and nothing else changed: only the trailer fails.
                let source = IndexSpace.encoded(seeded.forgery?.source ?? 0)
                let header = IndexHeader.parse(bytes ?? [])
                try #require(bytes != nil && valid == nil && header?.generation == seeded.forgery?.named, "\(slice.testDescription): \(file) names \(String(describing: seeded.forgery?.named))")
                try #require(bytes?.count == source.count && bytes?[IndexHeader.length...] == source[IndexHeader.length...], "\(slice.testDescription): \(file) is the source generation behind its header")
                try #require(header?.launchEpoch == seeded.forgery?.source && header?.bodyLength == IndexHeader.parse(source)?.bodyLength, "\(slice.testDescription): only the generation field differs")
            }
        }
        if slice.temporary == .newerUnsynced {
            let path = IndexSpace.path(.temporary)
            try #require(start.dropped[path] == nil, "\(slice.testDescription): an unsynced index.tmp has no durable name")
            try #require(start.kept[path].flatMap { try? IndexCodec.decode($0).get() } == nil, "\(slice.testDescription): an unsynced index.tmp has no synced data")
        } else {
            try #require(start.dropped == start.current && start.kept == start.current, "\(slice.testDescription): every seeded item is synced")
        }
    }

    /// One case's event.
    enum Event: CustomStringConvertible {
        case none
        case fault(FSOpRecord, FileSystemError)
        case renameTookEffect(FSOpRecord)
        case crash(Int, CrashMode)

        var description: String {
            switch self {
            case .none:
                return "no fault"
            case .fault(let operation, let error):
                return "\(error) at operation \(operation.index) (\(operation.kind) \(operation.url.lastPathComponent))"
            case .renameTookEffect(let operation):
                return "a rename that took effect but reported EIO at operation \(operation.index) (\(operation.url.lastPathComponent) → \(operation.destination?.lastPathComponent ?? "?"))"
            case .crash(let point, let mode):
                return "\(mode) before mutation \(point)"
            }
        }
    }
}

// MARK: Kill survivors with unordered names

@available(macOS 15.0, *)
extension IndexSpace {
    /// A kill survivor whose crash views differ, and where it came from.
    struct Survivor: Sendable {
        var disk: DiskImage
        var start: Views
        var origin: String
    }

    /// The crash views of a disk, as a key.
    struct ViewsKey: Hashable {
        var current: Files
        var dropped: Files
        var kept: Files
    }

    /// Every disk a kill leaves during the fault-free lifetimes of `row`'s disks on every volume script whose crash views
    /// differ, and that is not in `seen`, in the order they are first met (the disks the main enumeration starts from
    /// are left out); adds them to `seen`.
    static func unorderedSurvivors(of row: IndexSpaceRow, excluding seen: inout Set<ViewsKey>) async -> [Survivor] {
        var survivors: [Survivor] = []
        for slice in row.slices {
            let initial = IndexSpace.disk(slice)
            for volume in VolumeScript.allCases {
                var memo = Memo()
                let clean = IndexSpace.fake(initial)
                let recorder = MutationRecorder(clean)
                var run = await IndexSpace.open(on: recorder, fake: clean)
                IndexSpace.runCommits(from: 0, &run, on: recorder, fake: clean, volume: volume, memo: &memo) { _, run in
                    recorder.setClaimed(run.progress.claimed)
                }
                // Point 0 is the initial disk itself, before open()'s barrier.
                for (point, snapshot) in recorder.snapshots.enumerated() where point > 0 {
                    let views = IndexSpace.views(snapshot.disk)
                    let key = ViewsKey(current: views.current, dropped: views.dropped, kept: views.kept)
                    guard views.current != views.dropped || views.kept != views.current, seen.insert(key).inserted else {
                        continue
                    }
                    survivors.append(Survivor(disk: snapshot.disk, start: views, origin: "\(slice.testDescription) volume=\(volume) killed before mutation \(point)"))
                }
            }
        }
        return survivors
    }

    /// The cases of one survivor (see `IndexCommitUnorderedNamesTests`).
    static func enumerateUnordered(_ survivor: Survivor, label: String) async -> SliceResult {
        var memo = Memo()
        var violations: [String] = []
        let start = survivor.start
        let root = IndexSpace.layout.root
        for volume in VolumeScript.allCases {
            // No fault: the barrier orders every index name, so the rest of the lifetime starts from a disk of the seeded
            // space.
            let clean = IndexSpace.fake(survivor.disk)
            var run = await IndexSpace.open(on: clean, fake: clean)
            let ordered = IndexSpace.views(clean.survivingDisk())
            if ordered.dropped != ordered.kept {
                violations.append("\(label) volume=\(volume) no fault: open()'s root barrier left an index name unordered (\(IndexSpace.describe(ordered.dropped)) after a power loss, \(IndexSpace.describe(ordered.kept)) named)")
            }
            run.currentIsValid = IndexSpace.summary(clean.survivingDisk().files, &memo).currentIsValid
            IndexSpace.runCommits(from: 0, &run, on: clean, fake: clean, volume: volume, memo: &memo)
            violations += IndexSpace.labelled(await IndexSpace.finish(run, fake: clean, start: start, memo: &memo), "\(label) volume=\(volume) no fault")
            memo.counts.cases += 1
            memo.counts.faultFree += 1
            // The barrier fails: the names stay unordered until a commit's own root sync.
            for error in [FileSystemError.io, .noSpace] {
                let caseLabel = "\(label) volume=\(volume) \(error) at open()'s root barrier"
                let fake = IndexSpace.fake(survivor.disk)
                fake.addFault(FaultRule(operation: .synchronizeDirectory, matching: URLMatcher(lastComponentSuffix: root.lastPathComponent, pathContains: root.path), occurrence: .nth(1), error: error))
                var run = await IndexSpace.open(on: fake, fake: fake)
                if fake.operations.first(where: { $0.kind == .synchronizeDirectory && $0.url == root })?.failure != error {
                    violations.append("\(caseLabel): the fault never fired")
                }
                run.currentIsValid = IndexSpace.summary(fake.survivingDisk().files, &memo).currentIsValid
                IndexSpace.runCommits(from: 0, &run, on: fake, fake: fake, volume: volume, memo: &memo)
                violations += IndexSpace.labelled(await IndexSpace.finish(run, fake: fake, start: start, memo: &memo), caseLabel)
                if volume == .free, !run.progress.readOnly, !run.progress.flushCommitted {
                    violations.append("\(caseLabel): I-e, close()'s durable flush failed after the fault, with none of its own")
                }
                memo.counts.cases += 1
                memo.counts.faults += 1
                await Task.yield()
            }
        }
        // A crash before the barrier: the survivor as each crash leaves it, with nothing counted committed.
        let keptDisk = IndexSpace.surviving(survivor.disk, .powerLossKeepMetadata)
        let crashes: [(CrashMode, Files, ReopenKey, () -> DiskImage)] = [
            (.processKill, start.current, ReopenKey(current: start.current, kept: keptDisk.files), { survivor.disk }),
            (.powerLossDropUnsynced, start.dropped, ReopenKey(current: start.dropped, kept: start.dropped), { IndexSpace.surviving(survivor.disk, .powerLossDropUnsynced) }),
            (.powerLossKeepMetadata, start.kept, ReopenKey(current: start.kept, kept: start.kept), { keptDisk }),
        ]
        for (mode, files, key, disk) in crashes {
            let caseLabel = "\(label) \(Event.crash(0, mode))"
            let floor = IndexSpace.floor(start, mode, claimed: 0, &memo)
            violations += IndexSpace.checkSurvivor(files, view: "the crash", floor: floor, claimed: 0, checkCommitted: false, label: caseLabel, &memo)
            violations += await IndexSpace.checkReopen(key, disk: disk, floor: floor, claimed: 0, label: caseLabel, &memo)
            memo.counts.cases += 1
            memo.counts.crashes += 1
        }
        return SliceResult(slice: label, violations: violations, counts: memo.counts)
    }
}

/// A `FileSystem` over a `FakeFileSystem` that records, before every mutation, the disk a crash there would start from
/// (`survivingDisk()` of a fake configured for a kill keeps every applied mutation with its synced/unsynced split, so a
/// crash of any mode before mutation k leaves that disk under the mode's view) and the generation the store counted
/// committed at that moment.
@available(macOS 15.0, *)
final class MutationRecorder: FileSystem {
    /// The disk before one mutation.
    struct Snapshot: Sendable {
        var disk: DiskImage
        var claimed: UInt64
    }

    let base: FakeFileSystem
    private let state = Mutex<(snapshots: [Snapshot], claimed: UInt64)>(([], 0))

    init(_ base: FakeFileSystem) {
        self.base = base
    }

    /// The disk before every mutation so far, in order.
    var snapshots: [Snapshot] {
        self.state.withLock { $0.snapshots }
    }

    /// Records the generation the store counts committed from now on.
    func setClaimed(_ claimed: UInt64) {
        self.state.withLock { $0.claimed = claimed }
    }

    private func recordMutation() {
        let disk = self.base.survivingDisk()
        self.state.withLock { $0.snapshots.append(Snapshot(disk: disk, claimed: $0.claimed)) }
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
        try self.base.storeAttributes(at: url)
    }

    func createDirectory(at url: URL) throws(FileSystemError) {
        self.recordMutation()
        try self.base.createDirectory(at: url)
    }

    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        self.recordMutation()
        try self.base.write(data, to: url, mode: mode)
    }

    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        self.recordMutation()
        try self.base.synchronizeFile(at: url, level: level)
    }

    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        self.recordMutation()
        try self.base.synchronizeDirectory(at: url, level: level)
    }

    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        self.recordMutation()
        try self.base.rename(from: source, to: destination, mode: mode)
    }

    func removeItem(at url: URL) throws(FileSystemError) {
        self.recordMutation()
        try self.base.removeItem(at: url)
    }

    func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        self.recordMutation()
        try self.base.applyStoreAttributes(attributes, at: url)
    }

    func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        self.recordMutation()
        return try self.base.acquireExclusiveLock(at: url)
    }

    func releaseLock(_ token: FileLockToken) {
        self.base.releaseLock(token)
    }
}

/// A `FileSystem` over a `FakeFileSystem` that misreports: its `failing`-th rename (1-based, any URL) takes effect and
/// then reports EIO (the "rename failure" of the state-space test: a rename whose result was lost, as in probe
/// VPC2-K), and every read of a URL `shortReads` matches returns no bytes without an error (a file that ended early).
@available(macOS 15.0, *)
final class MisreportingFileSystem: FileSystem {
    let base: FakeFileSystem
    private let failing: Int
    private let shortReads: URLMatcher?
    private let renames = Mutex<Int>(0)

    init(_ base: FakeFileSystem, failing: Int, shortReads: URLMatcher? = nil) {
        self.base = base
        self.failing = failing
        self.shortReads = shortReads
    }

    /// Whether the failing rename ran.
    var fired: Bool {
        self.renames.withLock { $0 >= self.failing }
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
        let data = try self.base.read(from: url, offset: offset, maxLength: maxLength)
        return self.shortReads?.matches(url) == true ? Data() : data
    }

    func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        try self.base.availableCapacity(at: url, for: purpose)
    }

    func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        try self.base.storeAttributes(at: url)
    }

    func createDirectory(at url: URL) throws(FileSystemError) {
        try self.base.createDirectory(at: url)
    }

    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        try self.base.write(data, to: url, mode: mode)
    }

    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.base.synchronizeFile(at: url, level: level)
    }

    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.base.synchronizeDirectory(at: url, level: level)
    }

    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        let count = self.renames.withLock { count in
            count += 1
            return count
        }
        try self.base.rename(from: source, to: destination, mode: mode)
        if count == self.failing {
            throw .io
        }
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
