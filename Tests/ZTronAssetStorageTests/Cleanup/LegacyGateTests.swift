import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The commit gates of legacy migration and the safety of its tree removal (R-STO-11, R-STO-5, R-SEC-2; ADR drafts
/// C-13…C-15, store.md §7): no legacy file moves before a generation holding the phase-1 plan is committed, by any path;
/// nothing is removed before a generation holding "done" is committed durably, on any call; and phase 4 never reaches
/// through a symbolic link.
@Suite("Cleanup: legacy migration's commit gates and tree removal (R-STO-11, R-SEC-2)")
struct LegacyGateTests {
    /// The operations of `operations` that moved a file out of the legacy tree.
    static func firstLegacyMove(_ operations: [FSOpRecord]) -> Int? {
        operations.firstIndex { $0.kind == .rename && $0.url.path.hasPrefix(CleanupFixture.legacyRoot.path) }
    }

    /// The commits of `operations` that landed (`index.tmp` renamed over `index.bin` without a failure).
    static func landedCommits(_ operations: ArraySlice<FSOpRecord>) -> [FSOpRecord] {
        operations.filter {
            $0.kind == .rename && $0.url.lastPathComponent == "index.tmp" && $0.destination?.lastPathComponent == "index.bin" && $0.failure == nil
        }
    }

    @Test("R-STO-11: an adopt-on-demand moves no legacy file before a generation holding the phase-1 plan is committed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func adoptNowWaitsForThePlanCommit() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let (harness, _) = try LegacyFixture.harness(files: files)
        // Every index write of open() runs out of space: phase 1's commit and the launch commit both fail.
        for occurrence in 1...4 {
            harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(occurrence), error: .noSpace))
        }
        _ = try await harness.store.open()
        #expect(LegacyGateTests.landedCommits(harness.fileSystem.operations[...]).isEmpty, "open() committed nothing")
        let entry = try #require(entries.first)
        let location = try #require(try await harness.store.adoptLegacyNow(entry.identifier))
        #expect(harness.content(location.url) == files[LegacyFixture.relativePath(entry)])
        let operations = harness.fileSystem.operations
        let firstMove = try #require(LegacyGateTests.firstLegacyMove(operations))
        #expect(!LegacyGateTests.landedCommits(operations[..<firstMove]).isEmpty, "a commit holding the plan landed before the first legacy file moved")
    }

    @Test("R-STO-11: a relaunch in phase inProgress whose barrier and launch commit failed commits before moving a legacy file", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func relaunchWaitsForACountedPlan() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (first, defaults) = try LegacyFixture.harness(files: files)
        _ = try await first.store.open()
        await first.store.close()
        let second = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: first.time)
        // The relaunch counts nothing committed: its root barrier and its launch commit both fail.
        second.fileSystem.addFault(FaultRule(operation: .synchronizeDirectory, matching: URLMatcher(lastComponentSuffix: "v1"), occurrence: .nth(1), error: .io))
        second.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .noSpace))
        #expect(try await second.store.open().legacyMigrationPending)
        let atOpen = second.fileSystem.operations
        #expect(atOpen.first { $0.kind == .synchronizeDirectory && $0.url == second.layout.root }?.failure == .io, "the barrier failed")
        #expect(atOpen.first { $0.kind == .write && $0.url.lastPathComponent == "index.tmp" }?.failure == .noSpace, "the launch commit failed")
        #expect(try await LegacyMigrationTests.migrateAll(second).finished)
        let operations = second.fileSystem.operations
        let firstMove = try #require(LegacyGateTests.firstLegacyMove(operations))
        #expect(!LegacyGateTests.landedCommits(operations[atOpen.count..<firstMove]).isEmpty, "this lifetime committed the plan before the first legacy file moved")
        #expect(await CoreInvariants.violations(of: second).isEmpty)
    }

    @Test("R-STO-11: no call removes the legacy tree or the key before a generation holding \"done\" is durably committed, and a relaunch still migrates the stamp", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func removalWaitsForTheDoneCommit() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        _ = try await harness.store.open()
        // From now on no index write lands: phase 3's durable commit fails, on the first call and on every retry.
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        for attempt in 1...2 {
            await #expect(throws: StoreError.self, "attempt \(attempt)") {
                _ = try await harness.store.migrateLegacy(maxFiles: 100)
            }
            #expect(LegacyMigrationTests.exists(harness, CleanupFixture.legacyRoot.appendingPathComponent("manifest.json")), "attempt \(attempt): the tree stays")
            #expect(defaults.string(forKey: CleanupFixture.legacyKey) == "1.4+77", "attempt \(attempt): the key stays")
        }
        // The process dies; the relaunch finds phase inProgress, adopts the moved files and still migrates the stamp.
        let relaunched = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: harness.time)
        #expect(try await relaunched.store.open().legacyMigrationPending)
        #expect(try await LegacyMigrationTests.migrateAll(relaunched).finished)
        let view = try await relaunched.store.planningView()
        #expect(view.stamp?.appVersion == "1.4+77" && !view.syncDue, "the stamp migrated: every entry was adopted")
        for entry in entries {
            #expect(await relaunched.store.location(for: entry.identifier, extensions: [], recordingAccess: false) != nil, "\(entry.identifier.rawValue) is present")
        }
        #expect(!LegacyMigrationTests.exists(relaunched, CleanupFixture.legacyRoot) && defaults.string(forKey: CleanupFixture.legacyKey) == nil)
        #expect(await CoreInvariants.violations(of: relaunched).isEmpty)
    }

    @Test("R-SEC-2: phase 4 removes a symbolic link that replaced the legacy root, never what it points to", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func linkedRootRemovedNotFollowed() async throws {
        let asset = CleanupFixture.asset("legacy.one", seed: 760)
        var entry = asset.entry
        entry.localPathComponents = ["D"]
        entry.localFileName = "one"
        let keep = URL(fileURLWithPath: "/fake-volume/Documents/Keep", isDirectory: true)
        let kept: [String: Data] = ["keep.txt": CoreFixture.bytes(761), "D/one.png": CoreFixture.bytes(762)]
        let files: [String: Data] = ["manifest.json": try LegacyFixture.manifestJSON([entry]), "D/one.png": asset.bytes]
        let disk = try LegacyFixture.disk(files, base: try LegacyFixture.disk(kept, root: keep))
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1+1"])
        let harness = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: defaults)
        #expect(try await harness.store.open().legacyMigrationPending)
        // Between phase 1 and phase 2 something replaces the legacy root by a link to a directory the app keeps.
        let root = CleanupFixture.legacyRoot
        for url in [root.appendingPathComponent("D/one.png"), root.appendingPathComponent("manifest.json"), root.appendingPathComponent("D", isDirectory: true), root] {
            try harness.fileSystem.removeItem(at: url)
        }
        try harness.fileSystem.createSymbolicLink(at: root, destination: keep.path)
        let linkedAt = harness.fileSystem.operations.count
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress.finished && progress.adopted == 0)
        for (relative, bytes) in kept {
            #expect(harness.content(keep.appendingPathComponent(relative)) == bytes, "\(relative) behind the link is untouched")
        }
        let through = harness.fileSystem.operations[linkedAt...].filter { $0.kind.isMutation && ($0.url.path.hasPrefix(root.path + "/") || $0.url.path.hasPrefix(keep.path)) }
        #expect(through.isEmpty, "nothing below the link or under its target was mutated: \(through.map(\.url.path))")
        #expect(!LegacyMigrationTests.exists(harness, root), "the link itself is gone")
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil)
    }
}
