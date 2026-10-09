import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Legacy migration at its edges (R-STO-11; ADR-029, ADR draft C-13…C-15): the default root, an unreadable or vanished
/// tree, a read-only lifetime, cancellation, and an adopt-on-demand racing a batch (REENTRANCY R18).
@Suite("Cleanup: legacy migration edges (R-STO-11)")
struct LegacyEdgeTests {
    @Test("R-STO-11: the default legacy root is the prior art's Caches/CDNAssets", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func defaultRoot() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: LegacyMigrationPolicy(enabled: true), defaults: defaults)
        #expect(try await harness.store.open().legacyMigrationPending)
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress.adopted == 13 && progress.finished)
        #expect(!LegacyMigrationTests.exists(harness, CleanupFixture.legacyRoot))
    }

    @Test("R-STO-11: a legacy root that cannot be stat-ed is left, with its stamp, for a later launch", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func unreadableRootDeferred() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        harness.fileSystem.addFault(FaultRule(operation: .itemInfo, matching: URLMatcher(lastComponentSuffix: "CDNAssets"), occurrence: .nth(1), error: .io))
        let report = try await harness.store.open()
        #expect(!report.legacyMigrationPending)
        #expect(await harness.state.migration.phase == .notStarted)
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == "1.4+77", "an I/O error is not a vanished tree")
        #expect(try await harness.store.migrateLegacy(maxFiles: 10).finished, "nothing was planned in this lifetime")
        await harness.store.close()
        let next = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: harness.time)
        #expect(try await next.store.open().legacyMigrationPending)
        #expect(try await LegacyMigrationTests.migrateAll(next).adopted == 13)
    }

    @Test("R-STO-11: a legacy tree that vanishes during migration still finishes phases 3 and 4 without migrating the stamp", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func vanishedDuringMigration() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (first, defaults) = try LegacyFixture.harness(files: files)
        _ = try await first.store.open()
        await first.store.close()
        // The OS purged Caches between launches.
        var disk = first.fileSystem.survivingDisk()
        for path in disk.paths where path.hasPrefix(CleanupFixture.legacyRoot.path) {
            disk.purge(path)
        }
        let second = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: first.time)
        #expect(try await second.store.open().legacyMigrationPending)
        let progress = try await second.store.migrateLegacy(maxFiles: 10)
        #expect(progress.finished && progress.adopted == 0)
        let view = try await second.store.planningView()
        #expect(view.stamp == nil && view.syncDue)
        #expect(await second.state.migration.phase == .done)
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil)
    }

    @Test("R-STO-11: a read-only lifetime leaves the legacy tree and its stamp for a later launch", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func readOnlyLifetimeDefers() async throws {
        let first = CoreHarness.cleanup()
        _ = try await first.store.open()
        await first.store.close()
        let files = try LegacyFixture.fixtureFiles()
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let disk = try LegacyFixture.disk(files, base: first.fileSystem.survivingDisk())
        let readOnly = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: first.time)
        readOnly.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: "index.bin"), occurrence: .nth(1), error: .io))
        let report = try await readOnly.store.open()
        #expect(report.degraded && !report.legacyMigrationPending)
        #expect(await readOnly.state.core.records.isEmpty && readOnly.content(CleanupFixture.legacyRoot.appendingPathComponent("manifest.json")) != nil)
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == "1.4+77")
        await #expect(throws: StoreError.storageUnavailable(.ioFailure)) {
            _ = try await readOnly.store.migrateLegacy(maxFiles: 1)
        }
    }

    @Test("R-STO-11: a cancelled migration batch keeps the file it had not adopted queued, and the next batch adopts it", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func cancelledBatch() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let bulk = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: CleanupFixture.legacyPolicy, defaults: defaults, bulk: bulk)
        _ = try await harness.store.open()
        await bulk.setHolding(true)
        let batch = Task {
            try await harness.store.migrateLegacy(maxFiles: 100)
        }
        // The first file's hash unit is held; the caller is cancelled meanwhile.
        try await bulk.requireHeldUnits(atLeast: 1)
        batch.cancel()
        await bulk.setHolding(false)
        let outcome = await batch.result
        #expect(throws: StoreError.cancelled) {
            try outcome.get()
        }
        // A batch of no files reports the progress without moving anything.
        let after = try await harness.store.migrateLegacy(maxFiles: 0)
        #expect(after.adopted == 1 && after.remaining == 12 && !after.finished, "the unit that ran completed; the rest stays queued")
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress == LegacyMigrationProgress(adopted: 13, remaining: 0, dropped: 0, finished: true))
    }

    @Test("R-STO-11: an adopt-on-demand racing a batch on the same file adopts it once and returns its location", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func adoptNowRacesBatch() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let bulk = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: CleanupFixture.legacyPolicy, defaults: defaults, bulk: bulk)
        _ = try await harness.store.open()
        let first = try #require(await harness.state.migration.queue.first)
        let id = try #require(first.ids.first)
        await bulk.setHolding(true)
        let batch = Task {
            try await harness.store.migrateLegacy(maxFiles: 1)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        #expect(await harness.state.migration.claimed == [first], "the batch holds the file")
        let onDemand = Task {
            try await harness.store.adoptLegacyNow(id)
        }
        try await bulk.requireHeldUnits(atLeast: 2)
        // The on-demand hash finishes first: it adopts the file the batch holds.
        await bulk.release(try #require(await bulk.heldUnits.last))
        let location = try #require(try await onDemand.value)
        await bulk.setHolding(false)
        let progress = try await batch.value
        #expect(location == (await harness.store.location(for: id, extensions: [], recordingAccess: false)))
        #expect(harness.content(location.url) == files[first.components.joined(separator: "/")])
        #expect(progress.adopted == 1 && progress.dropped == 0, "counted once, by the call that adopted it")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// A legacy `manifest.json` that cannot be read whole.
    enum UnreadableManifest: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case directory
        case statFails
        case readFails

        var testDescription: String {
            self.rawValue
        }
    }

    @Test(
        "R-STO-11: a legacy manifest that cannot be read whole degrades the launch like an undecodable one, adopts nothing and still removes the tree and the key",
        .timeLimit(.minutes(1)),
        arguments: UnreadableManifest.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func unreadableManifest(_ manifest: UnreadableManifest) async throws {
        var files: [String: Data] = ["x/y.png": CoreFixture.bytes(730)]
        switch manifest {
        case .directory:
            files["manifest.json/inner.json"] = Data("[]".utf8)
        case .statFails, .readFails:
            files["manifest.json"] = Data("[]".utf8)
        }
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        let matcher = URLMatcher(lastComponentSuffix: "manifest.json")
        switch manifest {
        case .directory:
            break
        case .statFails:
            harness.fileSystem.addFault(FaultRule(operation: .itemInfo, matching: matcher, occurrence: .nth(1), error: .io))
        case .readFails:
            harness.fileSystem.addFault(FaultRule(operation: .read, matching: matcher, occurrence: .nth(1), error: .io))
        }
        let report = try await harness.store.open()
        #expect(report.degraded && report.legacyMigrationPending)
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress.adopted == 0 && progress.finished)
        let view = try await harness.store.planningView()
        #expect(view.stamp == nil && view.syncDue && view.records.isEmpty)
        #expect(!LegacyMigrationTests.exists(harness, CleanupFixture.legacyRoot) && defaults.string(forKey: CleanupFixture.legacyKey) == nil)
    }
}
