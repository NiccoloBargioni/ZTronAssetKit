import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// A companion of WP-B's `IndexCommitStateSpaceTests` (ADR draft B-33) for the index mutations WP-C adds: legacy phase 1
/// commits inside `open()`, **before** its root barrier (ADR drafts B-36 and C-13), a point of the lifetime the WP-B
/// enumeration does not reach. Over every unforged initial index disk (7 × 7 × 8 states of `index.bin`, `index.prev`
/// and `index.tmp`, `IndexSpaceRow.unforged`), with a legacy tree to plan, the lifetime `open()` then `close()` runs
/// with one event: none; EIO at every index-file or root operation up to and including the barrier (the load's stats
/// and reads, phase 1's promotion and commit, the barrier); ENOSPC at every `index.tmp` write in that window; or a crash
/// before every mutation in that window in each crash mode (a torn write only at writes). The events without a crash
/// also run on a volume that fills up after phase 1's first index write, so the launch commit and the flush fail too
/// (B-36's sequence); otherwise the rest of the lifetime runs fault-free: the WP-B enumeration covers those commits.
///
/// Invariants (B-33's, as ratified): **I-a** whatever a kill or a power loss leaves holds a generation at least as new
/// as the newest valid one the same crash view of the initial disk holds, and as every generation the store counted
/// committed; **I-b** when `open()` returns without a crash, a counted generation is held, validated in full, by the
/// file `committedFile` names (B-36's cycle-5 amendment).
@Suite("Cleanup: index state space with legacy phase 1 before the barrier (R-STO-5, B-36)")
struct LegacyPhaseOneStateSpaceTests {
    static let legacyRoot = URL(fileURLWithPath: "/v/CDNAssets", isDirectory: true)

    /// The initial disk of `slice` with a one-file legacy tree beside the store.
    @available(macOS 15.0, iOS 18.0, *)
    static func disk(_ slice: IndexSpaceSlice) throws -> DiskImage {
        let bytes = CoreFixture.bytes(990)
        var entry = CoreFixture.entry("legacy.one", bytes)
        entry.localPathComponents = ["D"]
        entry.localFileName = "one"
        let files: [String: Data] = ["manifest.json": try LegacyFixture.manifestJSON([entry]), "D/one.png": bytes]
        return try LegacyFixture.disk(files, root: LegacyPhaseOneStateSpaceTests.legacyRoot, base: IndexSpace.disk(slice))
    }

    /// What one lifetime left.
    struct Lifetime {
        var counted: UInt64 = 0
        var violations: [String] = []
        var survivor: DiskImage
        var operations: [FSOpRecord]
    }

    /// `open()` then `close()` on `disk`, with an optional crash and fault; checks I-b when `open()` returns.
    @available(macOS 15.0, iOS 18.0, *)
    static func lifetime(_ disk: DiskImage, crashBefore: Int? = nil, mode: CrashMode = .processKill, fault: FaultRule? = nil, fullAfterPhaseOne: Bool = false) async -> Lifetime {
        let fileSystem = IndexSpace.fake(disk, crashBefore: crashBefore, mode: mode)
        if let fault {
            fileSystem.addFault(fault)
        }
        if fullAfterPhaseOne {
            // The volume fills up after phase 1's first index write: every later write of index.tmp (phase 1's ENOSPC
            // retry, the launch commit, the durable flush) runs out of space (B-36's sequence).
            for occurrence in 2...8 {
                fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(occurrence), error: .noSpace))
            }
        }
        let configuration = StoreConfiguration(
            location: .custom(IndexSpace.volume),
            policy: CleanupFixture.policy(),
            legacy: LegacyMigrationPolicy(enabled: true, root: LegacyPhaseOneStateSpaceTests.legacyRoot),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let environment = CoreHarness.environment(fileSystem: fileSystem, time: ManualTimeSource())
        let store = AssetStore(configuration: configuration, environment: environment)
        var violations: [String] = []
        do {
            _ = try await store.open()
            let core = await store.state.core
            // I-b holds for a lifetime that is still running; a crashed one (open() tolerates a failed launch commit) is
            // held to I-a by the caller.
            if core.committedGeneration > 0, !fileSystem.crashed {
                let current = fileSystem.survivingDisk()
                let holding = core.commits.committedFile.flatMap { current.files[IndexSpace.path($0)] }
                let generation = holding.flatMap { try? IndexCodec.decode($0).get().generation }
                if generation != core.committedGeneration {
                    violations.append("I-b: generation \(core.committedGeneration) counted in \(String(describing: core.commits.committedFile)), which holds \(String(describing: generation))")
                }
            }
            await store.close()
        } catch {
            // The crash, or an open that failed on a fault: nothing more to run.
        }
        let counted = await store.state.core.committedGeneration
        return Lifetime(counted: counted, violations: violations, survivor: fileSystem.survivingDisk(), operations: fileSystem.operations)
    }

    /// The newest valid generation among the index files of `disk`.
    @available(macOS 15.0, iOS 18.0, *)
    static func newestValid(_ disk: DiskImage) -> UInt64 {
        IndexFile.allCases.compactMap { disk.files[IndexSpace.path($0)].flatMap { try? IndexCodec.decode($0).get().generation } }.max() ?? 0
    }

    /// The newest valid generation of `initial` under each crash view (computed once per initial disk).
    @available(macOS 15.0, iOS 18.0, *)
    static func floors(_ initial: DiskImage) -> [CrashMode: UInt64] {
        Dictionary(uniqueKeysWithValues: CrashMode.allCases.map { ($0, LegacyPhaseOneStateSpaceTests.newestValid(IndexSpace.surviving(initial, $0))) })
    }

    /// I-a for the survivor of a case: under `views` (the survivor's own view for a crash, every view for a kill), the
    /// load rule finds a generation at least as new as the initial disk's under that view (`floors`) and as `counted`.
    @available(macOS 15.0, iOS 18.0, *)
    static func checkSurvivor(_ survivor: DiskImage, floors: [CrashMode: UInt64], counted: UInt64, views: [CrashMode], label: String) -> [String] {
        var found: [String] = []
        for mode in views {
            let view = mode == .processKill || mode == .processKillTornWrite ? survivor : IndexSpace.surviving(survivor, mode)
            let files = Dictionary(uniqueKeysWithValues: IndexFile.allCases.compactMap { file in
                view.files[IndexSpace.path(file)].map { (file, IndexFileRead(size: Int64($0.count), bytes: $0)) }
            })
            let loaded = IndexLoadRule.choose(files).content?.generation ?? 0
            let floor = max(floors[mode] ?? 0, counted)
            if loaded < floor {
                found.append("\(label), \(mode) view: I-a, the next launch loads generation \(loaded) < \(floor)")
            }
        }
        return found
    }

    /// The events of the window up to and including `open()`'s barrier of the fault-free run.
    static func window(_ operations: [FSOpRecord], root: URL) -> (mutations: [FSOpRecord], faults: [FaultRule]) {
        let writes = operations.filter { $0.kind == .write && $0.url.lastPathComponent == "index.tmp" }
        guard writes.count >= 2 else {
            return ([], [])
        }
        let launchWrite = writes[1].index
        let barrier = operations.last { $0.index < launchWrite && $0.kind == .synchronizeDirectory && $0.url == root }?.index ?? launchWrite - 1
        let window = operations.filter { $0.index <= barrier }
        var faults: [FaultRule] = []
        for operation in window {
            let name = operation.url.lastPathComponent
            guard name.hasPrefix("index.") || operation.url == root else {
                continue
            }
            let occurrence = window.filter { $0.index <= operation.index && $0.kind == operation.kind && $0.url.lastPathComponent.hasSuffix(name) }.count
            let matcher = URLMatcher(lastComponentSuffix: name)
            faults.append(FaultRule(operation: operation.kind, matching: matcher, occurrence: .nth(occurrence), error: .io))
            if operation.kind == .write {
                faults.append(FaultRule(operation: operation.kind, matching: matcher, occurrence: .nth(occurrence), error: .noSpace))
            }
        }
        return (window.filter(\.kind.isMutation), faults)
    }

    /// What enumerating one initial disk found.
    struct SliceResult: Sendable {
        var slice: String
        var violations: [String] = []
        var faultRuns = 0
        var crashRuns = 0
        var crashViews = 0
        var expectedFaultRuns = 0
        var expectedCrashViews = 0
    }

    /// Every case of one initial disk; only identical work is shared. The fault-free lifetime is run once and serves as
    /// the "no event, free volume" case. A crash before mutation k leaves the same memory whatever its mode (the fake fails mutation k and every
    /// later call in every mode; only `survivingDisk()` differs), so one kill run per crash point gives the counted
    /// generation and the survivor, whose power-loss views are derived from it as B-33's `MutationRecorder` does
    /// (`IndexSpace.surviving`); a torn write differs from a kill only at a write, where it is run again.
    @available(macOS 15.0, iOS 18.0, *)
    static func enumerate(_ slice: IndexSpaceSlice) async throws -> SliceResult {
        var result = SliceResult(slice: slice.testDescription)
        let initial = try LegacyPhaseOneStateSpaceTests.disk(slice)
        let floors = LegacyPhaseOneStateSpaceTests.floors(initial)
        let root = IndexSpace.layout.root
        let clean = await LegacyPhaseOneStateSpaceTests.lifetime(initial)
        let (mutations, faults) = LegacyPhaseOneStateSpaceTests.window(clean.operations, root: root)
        guard !mutations.isEmpty, !faults.isEmpty else {
            result.violations.append("\(slice.testDescription): the window holds no phase-1 commit or barrier")
            return result
        }
        // No event and every fault, on a free volume and on one that fills up after phase 1's first index write (a
        // crash ends the lifetime inside the window, where the two volumes do not differ).
        // The full volume fails only the second and later `index.tmp` writes, so a free-volume run that never attempted a
        // second one is also the full-volume run (deterministic up to the first write that rule could fail): it is
        // checked under both labels and run once.
        let events: [FaultRule?] = [nil] + faults.map { $0 }
        result.expectedFaultRuns = 2 * events.count
        var free: [Lifetime] = []
        for full in [false, true] {
            for (index, fault) in events.enumerated() {
                await Task.yield()
                let run: Lifetime
                if !full {
                    run = fault == nil ? clean : await LegacyPhaseOneStateSpaceTests.lifetime(initial, fault: fault)
                    free.append(run)
                } else if free[index].operations.filter({ $0.kind == .write && $0.url.lastPathComponent == "index.tmp" }).count < 2 {
                    run = free[index]
                } else {
                    run = await LegacyPhaseOneStateSpaceTests.lifetime(initial, fault: fault, fullAfterPhaseOne: true)
                }
                result.faultRuns += 1
                let event = fault.map { "\($0.error) at \($0.operation) \($0.matching.lastComponentSuffix ?? "") #\($0.occurrence)" } ?? "no fault"
                let label = "\(slice.testDescription), \(event)\(full ? ", full after phase 1" : "")"
                result.violations += run.violations.map { "\(label): \($0)" }
                result.violations += LegacyPhaseOneStateSpaceTests.checkSurvivor(run.survivor, floors: floors, counted: run.counted, views: CrashMode.allCases, label: label)
            }
        }
        for (point, mutation) in mutations.enumerated() {
            let modes = CrashMode.allCases.filter { $0 != .processKillTornWrite || mutation.kind == .write }
            result.expectedCrashViews += modes.count
            await Task.yield()
            let kill = await LegacyPhaseOneStateSpaceTests.lifetime(initial, crashBefore: point, mode: .processKill)
            result.crashRuns += 1
            for mode in modes {
                let label = "\(slice.testDescription), \(mode) before mutation \(point)"
                let run: Lifetime
                if mode == .processKillTornWrite {
                    await Task.yield()
                    run = await LegacyPhaseOneStateSpaceTests.lifetime(initial, crashBefore: point, mode: mode)
                    result.crashRuns += 1
                } else {
                    run = kill
                }
                result.crashViews += 1
                result.violations += run.violations.map { "\(label): \($0)" }
                result.violations += LegacyPhaseOneStateSpaceTests.checkSurvivor(run.survivor, floors: floors, counted: run.counted, views: [mode], label: label)
            }
        }
        return result
    }

    /// The rows run one at a time (`.serialized`), each as eight child tasks at low priority that yield once per case
    /// (ios.md item 4): a row's time limit then measures only its own work (about a second of CPU), and the suites
    /// running beside this one keep the cooperative pool (round-1 review: with every row started at once, a loaded host
    /// ran 48 of 49 rows past their limit).
    @Test(
        "R-STO-5: legacy phase 1's commit before open()'s barrier keeps the newest durable generation and counts only what a file holds, for every initial index disk, fault and crash",
        .serialized,
        .timeLimit(.minutes(1)),
        arguments: IndexSpaceRow.unforged
    )
    @available(macOS 15.0, iOS 18.0, *)
    func everyStateFaultAndCrash(row: IndexSpaceRow) async throws {
        let results = try await withThrowingTaskGroup(of: SliceResult.self) { group in
            for slice in row.slices {
                group.addTask(priority: .low) {
                    try await LegacyPhaseOneStateSpaceTests.enumerate(slice)
                }
            }
            var results: [SliceResult] = []
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.slice < $1.slice }
        }
        let violations = results.flatMap(\.violations)
        #expect(violations.isEmpty, "\(violations.count) violations in \(row.testDescription), first: \(violations.prefix(5))")
        // The size of the space is asserted, not only printed: a refactor that dropped a disk, an event or a crash mode
        // would otherwise still pass.
        #expect(Set(results.map(\.slice)) == Set(row.slices.map(\.testDescription)) && results.count == row.slices.count, "every initial disk of \(row.testDescription) ran")
        for result in results {
            #expect(result.faultRuns == result.expectedFaultRuns && result.expectedFaultRuns > 2, "\(result.slice): \(result.faultRuns) of \(result.expectedFaultRuns) fault cases")
            #expect(result.crashViews == result.expectedCrashViews && result.expectedCrashViews > 3, "\(result.slice): \(result.crashViews) of \(result.expectedCrashViews) crash views")
        }
    }
}
