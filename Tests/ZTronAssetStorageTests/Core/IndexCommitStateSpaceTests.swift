import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// What one index file holds when a case of the state-space test starts (close-out cycle 3, item 2).
///
/// One lineage throughout: `older` is generation 9, `committed` 10, `newer` 11 (an attempt that did not complete: its
/// data synced, its commit never reported). Every item of the initial disk is synced, except `newerUnsynced`. Pruned,
/// each because the store can never produce it:
/// - `newerUnsynced` (generation 11 complete in the current namespace, its data and name never synced: a kill between
///   steps 2 and 3, probe VP7) is enumerated for `index.tmp` only. `index.tmp` is the one file the protocol writes in
///   place; `index.bin` and `index.prev` only ever receive an `index.tmp` that was synced first (step 3, and the
///   promotion's own sync), so their data is never unsynced. Volatile names (renames not yet ordered by a root sync)
///   are not seeded either: every kill point of the enumeration leaves them, and every case's survivor is reopened.
/// - A rotten file (`badHeader`, `badBody`, `truncated`) is a rotten copy of a generation no other file holds, above
///   every valid one (20 + the file's position). Every attempt allocates a generation of its own and files are only
///   renamed afterwards, so two files never share a generation, and a rotten header can never name the committed one.
///   A rotten header below the valid generations behaves exactly as one above them except for `nextGeneration`: the
///   load rule and the unit only take maxima of generations and compare a header for equality with the committed one.
///   The higher one also checks that the next launch epoch clears it (I-5), so it covers both.
/// Two valid files of one generation are just as impossible, but cost nothing, so they are enumerated anyway.
enum SeededIndex: String, CaseIterable, Sendable {
    case absent
    case older
    case committed
    case newer
    case newerUnsynced
    case badHeader
    case badBody
    case truncated

    /// The states `index.bin` and `index.prev` are enumerated over (see the pruning above).
    static let renamedInto: [SeededIndex] = SeededIndex.allCases.filter { $0 != .newerUnsynced }

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

/// One initial disk: the states of the three index files. Each one is a test case that enumerates every volume script
/// and every event.
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

    /// Every initial disk: 7 × 7 × 8.
    static let all: [IndexSpaceSlice] = SeededIndex.renamedInto.flatMap { bin in
        SeededIndex.renamedInto.flatMap { previous in
            SeededIndex.allCases.map { IndexSpaceSlice(bin: bin, previous: previous, temporary: $0) }
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
/// - **I-d** a second launch reaches the same generation as the first or a newer one, with a later epoch (I-5): the
///   reopen's epoch exceeds every generation the case counted committed, its fault-free launch commit succeeds, and the
///   launch after it loads at least the reopen's generation with a larger epoch. A launch whose own launch commit failed
///   may see its epoch again (ADR draft B-5), so a case's epoch is not compared with the reopen's.
///
/// How the enumeration stays affordable without sampling: the no-fault run records the disk before every mutation, and
/// a crash before mutation k leaves exactly that disk under the crash's view, so only torn writes are run again; a run
/// with a fault resumes from the no-fault run's disk at the start of the commit the fault falls in (the run is
/// deterministic up to the fault); and the reopen of a survivor, which after `open()`'s root barrier depends only on its
/// index files as a kill and as a power loss keeping metadata leave them, is computed once per distinct pair.
@Suite("Core: index commit state space (R-STO-4, R-STO-5)")
struct IndexCommitStateSpaceTests {
    @Test(
        "R-STO-4: every initial index state, with one fault at every operation, a kill or a power loss at every mutation, keeps I-a…I-d",
        .timeLimit(.minutes(1)),
        arguments: IndexSpaceSlice.all
    )
    @available(macOS 15.0, *)
    func everyStateFaultAndCrash(slice: IndexSpaceSlice) async throws {
        var memo = IndexSpace.Memo()
        let initial = IndexSpace.disk(slice)
        let start = IndexSpace.views(initial)
        try IndexSpace.checkSeed(slice, start)
        var violations: [String] = []
        for volume in VolumeScript.allCases {
            violations += await IndexSpace.enumerate(slice, initial: initial, start: start, volume: volume, memo: &memo)
        }
        let shown = violations.prefix(40).joined(separator: "\n")
        #expect(violations.isEmpty, "\(violations.count) violations from \(slice.testDescription); the first ones:\n\(shown)")
        let counts = memo.counts
        print("R-STO-4 index state \(slice.testDescription): \(counts.cases) cases (\(counts.faults) faults, \(counts.crashes) crash points) and \(memo.reopens.count) distinct reopens enumerated")
    }
}

/// The machinery of the state-space test.
@available(macOS 15.0, *)
enum IndexSpace {
    static let layout = CoreFixture.layout
    static let seed: UInt64 = 0x1D3
    static let storeID = StoreIdentifier.derived(fromSeed: IndexSpace.seed)
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The index files of a disk view, by path.
    typealias Files = [String: [UInt8]]

    // MARK: Disks and views

    static func path(_ file: IndexFile) -> String {
        IndexSpace.layout.indexURL(file).path
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
        case .absent, .older, .committed, .newer, .newerUnsynced:
            break
        }
        return bytes
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
        return FakeFileSystem(disk: image, time: ManualTimeSource()).survivingDisk()
    }

    /// The index files of a disk under each crash view.
    struct Views {
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
        FakeFileSystem(disk: disk, time: ManualTimeSource(), configuration: FakeFileSystemConfiguration(crashMode: mode)).survivingDisk()
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

    /// The per-test-case caches and counters (no state is shared between test cases).
    struct Memo {
        var summaries: [Files: Summary] = [:]
        var reopens: [ReopenKey: Reopen] = [:]
        var counts = Counts()
    }

    /// What was enumerated.
    struct Counts {
        var cases = 0
        var faults = 0
        var crashes = 0
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
    }

    /// The load, as `open()` does it, and `open()`'s root barrier before the launch commit (ADR-015; a failed barrier is
    /// tolerated). `recorder` learns the loaded committed generation before the barrier.
    static func open(on fileSystem: any FileSystem, recorder: MutationRecorder? = nil) async -> Progress {
        let inline = InlineBlockingExecutor()
        let layout = IndexSpace.layout
        let outcome = await IndexLoader.load(layout: layout, fileSystem: fileSystem, metadata: inline, bulk: inline)
        let launch = LaunchState.build(outcome: outcome, onDisk: [:], blobsRecreated: false, seed: IndexSpace.seed, now: IndexSpace.now, layout: layout)
        recorder?.setClaimed(launch.committedGeneration)
        _ = try? fileSystem.synchronizeDirectory(at: layout.root, level: .barrier)
        return Progress(
            ledger: IndexCommitLedger(committedGeneration: launch.committedGeneration, pendingPromotion: launch.promotion),
            claimed: launch.committedGeneration,
            epoch: launch.nextGeneration,
            loaded: outcome.content?.generation ?? 0,
            storeID: launch.storeID,
            generation: launch.nextGeneration
        )
    }

    /// The commit at `index` (0: the ordered launch commit, 1: close()'s durable flush), folded as `commitNow` folds it;
    /// returns whether it succeeded.
    static func commit(_ index: Int, _ progress: inout Progress, on fileSystem: any FileSystem) -> Bool {
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
        }
        return succeeded
    }

    /// The disk at the start of one commit of the no-fault run, to resume a run with a fault from.
    struct Phase {
        var disk: DiskImage
        var progress: Progress
        /// The commit that starts here.
        var commit: Int
        /// The length of the no-fault run's operation log here.
        var operations: Int
    }

    /// Runs the commits from `first` on, checking I-b and I-c after each (the fake is configured for a kill, so its
    /// surviving disk is its current state); returns the disk the run ends with.
    static func runCommits(
        from first: Int,
        _ progress: inout Progress,
        before startDisk: DiskImage,
        on fileSystem: any FileSystem,
        fake: FakeFileSystem,
        volume: VolumeScript,
        label: String,
        memo: inout Memo,
        violations: inout [String],
        phases: ((Int, DiskImage, Progress) -> Void)? = nil
    ) -> DiskImage {
        var disk = startDisk
        var full = false
        for index in first..<2 {
            phases?(index, disk, progress)
            if volume.isFull(atCommit: index), !full {
                fake.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
                full = true
            }
            let wasValid = IndexSpace.summary(disk.files, &memo).currentIsValid
            let succeeded = IndexSpace.commit(index, &progress, on: fileSystem)
            disk = fake.survivingDisk()
            let after = IndexSpace.summary(disk.files, &memo)
            let attempt = "\(label), after the \(index == 0 ? "launch commit" : "durable flush") (\(succeeded ? "succeeded" : "failed"))"
            let committed = progress.ledger.committedGeneration
            if committed > 0, !after.generations.contains(committed) {
                violations.append("\(attempt): I-b, the committed generation \(committed) is not on disk (\(IndexSpace.describe(disk.files)))")
            }
            if !succeeded, wasValid, !after.currentIsValid {
                violations.append("\(attempt): I-c, index.bin was valid before the failed commit and is \(disk.files[IndexSpace.path(.current)] == nil ? "missing" : "invalid") after it")
            }
        }
        return disk
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
            let fake = FakeFileSystem(disk: disk(), time: ManualTimeSource())
            var progress = await IndexSpace.open(on: fake)
            _ = IndexSpace.commit(0, &progress, on: fake)
            let end = fake.survivingDisk()
            reopen = Reopen(
                launchCommitted: progress.launchCommitted,
                epoch: progress.epoch,
                loaded: progress.loaded,
                claimed: progress.claimed,
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

    /// The checks at the end of a run that did not crash: the process ends (a kill), or the power fails right after.
    static func checkEnd(_ end: DiskImage, start: Views, claimed: UInt64, label: String, _ memo: inout Memo) async -> [String] {
        let views = IndexSpace.views(end)
        var violations: [String] = []
        for (mode, view) in [(CrashMode.processKill, "a kill at the end"), (.powerLossDropUnsynced, "a power loss dropping unsynced state at the end"), (.powerLossKeepMetadata, "a power loss keeping metadata at the end")] {
            let floor = IndexSpace.floor(start, mode, claimed: claimed, &memo)
            violations += IndexSpace.checkSurvivor(views.files(after: mode), view: view, floor: floor, claimed: claimed, label: label, &memo)
        }
        let key = ReopenKey(current: views.current, kept: views.kept)
        violations += await IndexSpace.checkReopen(key, disk: { end }, floor: IndexSpace.floor(start, .processKill, claimed: claimed, &memo), claimed: claimed, label: label, &memo)
        return violations
    }

    // MARK: The enumeration of one initial disk and volume script

    /// Every event for `slice` on `volume`; returns the violations.
    static func enumerate(_ slice: IndexSpaceSlice, initial: DiskImage, start: Views, volume: VolumeScript, memo: inout Memo) async -> [String] {
        var violations: [String] = []
        let label = "\(slice.testDescription) volume=\(volume)"
        // No fault, recorded: the disk before every mutation, and at the start of every commit.
        let clean = FakeFileSystem(disk: initial, time: ManualTimeSource())
        let recorder = MutationRecorder(clean)
        var progress = await IndexSpace.open(on: recorder, recorder: recorder)
        var phases: [Phase] = []
        let end = IndexSpace.runCommits(
            from: 0,
            &progress,
            before: clean.survivingDisk(),
            on: recorder,
            fake: clean,
            volume: volume,
            label: "\(label) no fault",
            memo: &memo,
            violations: &violations,
            phases: { index, disk, progress in
                recorder.setClaimed(progress.claimed)
                phases.append(Phase(disk: disk, progress: progress, commit: index, operations: clean.operations.count))
            }
        )
        violations += await IndexSpace.checkEnd(end, start: start, claimed: progress.claimed, label: "\(label) no fault", &memo)
        memo.counts.cases += 1
        let operations = clean.operations
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
            }
        }
        // A crash before every mutation, in every mode.
        let mutations = operations.filter(\.kind.isMutation)
        let snapshots = recorder.snapshots
        guard snapshots.count == mutations.count else {
            return violations + ["\(label): recorded \(snapshots.count) disks for \(mutations.count) mutations"]
        }
        for (point, snapshot) in snapshots.enumerated() {
            violations += await IndexSpace.checkCrashes(at: point, snapshot, mutation: mutations[point], initial: initial, start: start, volume: volume, label: label, memo: &memo)
        }
        return violations
    }

    /// One case with an injected fault, resumed from `phase` (the start of the commit the fault falls in) when given.
    static func runFault(_ event: Event, from phase: Phase?, operations: [FSOpRecord], initial: DiskImage, start: Views, volume: VolumeScript, label: String, memo: inout Memo) async -> [String] {
        let fake = FakeFileSystem(disk: phase?.disk ?? initial, time: ManualTimeSource())
        let offset = phase?.operations ?? 0
        let earlier = operations[offset...]
        var violations: [String] = []
        let fileSystem: any FileSystem
        var fired: () -> Bool
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
            let wrapper = RenameReportingFailure(fake, failing: before + 1)
            fileSystem = wrapper
            fired = { wrapper.fired }
        case .none, .crash:
            return ["\(label): not a fault"]
        }
        var progress: Progress
        let startDisk: DiskImage
        if let phase {
            progress = phase.progress
            startDisk = phase.disk
        } else {
            progress = await IndexSpace.open(on: fileSystem)
            startDisk = fake.survivingDisk()
        }
        let end = IndexSpace.runCommits(
            from: phase?.commit ?? 0,
            &progress,
            before: startDisk,
            on: fileSystem,
            fake: fake,
            volume: volume,
            label: label,
            memo: &memo,
            violations: &violations
        )
        if !fired() {
            violations.append("\(label): the fault never fired")
        }
        violations += await IndexSpace.checkEnd(end, start: start, claimed: progress.claimed, label: label, &memo)
        return violations
    }

    /// The crashes before mutation `point`: the recorded disk under each power loss and as a kill, and a torn write run
    /// again when the mutation is a write.
    static func checkCrashes(
        at point: Int,
        _ snapshot: MutationRecorder.Snapshot,
        mutation: FSOpRecord,
        initial: DiskImage,
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
            let torn = FakeFileSystem(disk: initial, time: ManualTimeSource(), configuration: FakeFileSystemConfiguration(crashBefore: point, crashMode: .processKillTornWrite))
            var progress = await IndexSpace.open(on: torn)
            var tornViolations: [String] = []
            var unusedMemo = Memo()
            _ = IndexSpace.runCommits(from: 0, &progress, before: initial, on: torn, fake: torn, volume: volume, label: label, memo: &unusedMemo, violations: &tornViolations)
            if torn.crashed {
                let disk = torn.survivingDisk()
                let tornKept = IndexSpace.surviving(disk, .powerLossKeepMetadata)
                survivors.append((.processKillTornWrite, disk.files, ReopenKey(current: disk.files, kept: tornKept.files), { disk }))
            } else {
                violations.append("\(label) \(Event.crash(point, .processKillTornWrite)): the crash point was never reached")
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

/// A `FileSystem` over a `FakeFileSystem` whose `failing`-th rename (1-based, any URL) takes effect and then reports
/// EIO: the "rename failure" of the state-space test (a rename whose result was lost, as in probe VPC2-K).
@available(macOS 15.0, *)
final class RenameReportingFailure: FileSystem {
    let base: FakeFileSystem
    private let failing: Int
    private let renames = Mutex<Int>(0)

    init(_ base: FakeFileSystem, failing: Int) {
        self.base = base
        self.failing = failing
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
        try self.base.read(from: url, offset: offset, maxLength: maxLength)
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
