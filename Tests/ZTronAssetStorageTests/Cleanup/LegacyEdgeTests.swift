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

    /// The first stat of the root is the overlap check's (C-13), the second its kind's.
    @Test("R-STO-11: a legacy root that cannot be stat-ed is left, with its stamp, for a later launch", .timeLimit(.minutes(1)), arguments: [1, 2])
    @available(macOS 15.0, iOS 18.0, *)
    func unreadableRootDeferred(failingStat: Int) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        harness.fileSystem.addFault(FaultRule(operation: .itemInfo, matching: URLMatcher(lastComponentSuffix: "CDNAssets"), occurrence: .nth(failingStat), error: .io))
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
        let first = try #require(await harness.state.migration.queue.last, "the next file is the queue's last")
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

    @Test("R-STO-11: an adopt-on-demand cancelled while it hashes puts its file back at the head of the queue, and the next batch adopts it", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func cancelledAdoptNowRequeues() async throws {
        // 1.5 MiB: two hash units, so the cancellation is seen between them.
        let big = CoreFixture.bytes(780, count: 3 << 19)
        let small = CoreFixture.bytes(781)
        let entries = [CoreFixture.entry("big", big), CoreFixture.entry("small", small)]
        let files: [String: Data] = [
            "manifest.json": try LegacyFixture.manifestJSON(entries),
            LegacyFixture.relativePath(entries[0]): big,
            LegacyFixture.relativePath(entries[1]): small,
        ]
        let bulk = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: CleanupFixture.legacyPolicy, defaults: defaults, bulk: bulk)
        _ = try await harness.store.open()
        #expect(await harness.state.migration.queue.last?.ids == ["big"], "the next file")
        await bulk.setHolding(true)
        let onDemand = Task {
            try await harness.store.adoptLegacyNow("big")
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        #expect(await harness.state.migration.queue.map(\.ids) == [["small"]], "taken from the queue")
        onDemand.cancel()
        await bulk.setHolding(false)
        await #expect(throws: StoreError.cancelled) {
            try await onDemand.value
        }
        #expect(await harness.state.migration.queue.map(\.ids) == [["small"], ["big"]], "back at the head of the queue")
        #expect(try await harness.store.migrateLegacy(maxFiles: 0) == LegacyMigrationProgress(adopted: 0, remaining: 2, dropped: 0, finished: false))
        #expect(try await harness.store.migrateLegacy(maxFiles: 1) == LegacyMigrationProgress(adopted: 1, remaining: 1, dropped: 0, finished: false))
        #expect(await harness.isPresent("big", at: CoreFixture.key(big)))
        #expect(harness.content(CleanupFixture.legacyRoot.appendingPathComponent(LegacyFixture.relativePath(entries[1]))) == small)
    }

    @Test("R-STO-11: a relaunch in phase inProgress counts files adopted by an earlier lifetime neither adopted nor dropped", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func relaunchCountsEarlierAdoptions() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (first, defaults) = try LegacyFixture.harness(files: files)
        _ = try await first.store.open()
        #expect(try await first.store.migrateLegacy(maxFiles: 4) == LegacyMigrationProgress(adopted: 4, remaining: 9, dropped: 0, finished: false))
        try await first.store.flush(.durable)
        await first.store.close()
        let second = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: first.time)
        #expect(try await second.store.open().legacyMigrationPending)
        // The four files moved into blobs/ in the first lifetime are no longer in the tree: their records hold them.
        #expect(try await second.store.migrateLegacy(maxFiles: 0) == LegacyMigrationProgress(adopted: 0, remaining: 9, dropped: 0, finished: false))
        let progress = try await LegacyMigrationTests.migrateAll(second)
        #expect(progress == LegacyMigrationProgress(adopted: 9, remaining: 0, dropped: 0, finished: true))
        #expect(try await second.store.planningView().stamp?.appVersion == "1.4+77", "every entry was adopted, over two lifetimes")
    }

    /// A legacy `manifest.json` that is not a regular file. (A stat or a read that fails is a transient I/O error, which
    /// decides nothing: `transientFaultDecidesNothing`, review round 3; those two cases moved there, one to one.)
    enum UnreadableManifest: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case directory

        var testDescription: String {
            self.rawValue
        }
    }

    @Test(
        "R-STO-11: a legacy manifest that cannot be read whole degrades the launch like an undecodable one, adopts nothing and removes the key, keeping files it cannot attribute",
        .timeLimit(.minutes(1)),
        arguments: UnreadableManifest.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func unreadableManifest(_ manifest: UnreadableManifest) async throws {
        var files: [String: Data] = ["x/y.png": CoreFixture.bytes(730)]
        switch manifest {
        case .directory:
            files["manifest.json/inner.json"] = Data("[]".utf8)
        }
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        let report = try await harness.store.open()
        #expect(report.degraded && report.legacyMigrationPending)
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress.adopted == 0 && progress.finished)
        let view = try await harness.store.planningView()
        #expect(view.stamp == nil && view.syncDue && view.records.isEmpty)
        // Phase 4 removes only what the prior art wrote (C-15): a regular `manifest.json`, never a directory of that
        // name, and no file it cannot attribute to a legacy entry.
        let root = CleanupFixture.legacyRoot
        #expect(LegacyMigrationTests.exists(harness, root.appendingPathComponent("manifest.json")), "a directory of that name is not the prior art's file")
        #expect(harness.content(root.appendingPathComponent("x/y.png")) == files["x/y.png"])
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil)
    }

    /// A transient I/O error in one of phase 1's reads (review round 3, ZProbe-read and ZProbe-list).
    enum TransientFault: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The stat of `manifest.json` fails (EIO).
        case manifestStat
        /// The read of `manifest.json` fails (EIO; ZProbe-read).
        case manifestRead
        /// The read of `local-checksums.json` fails (EIO).
        case checksumsRead
        /// The listing of one directory of the tree fails (EIO; ZProbe-list).
        case listing

        var testDescription: String {
            self.rawValue
        }

        /// The fault, on its first matching operation after it is added.
        var rule: FaultRule {
            switch self {
            case .manifestStat:
                return FaultRule(operation: .itemInfo, matching: URLMatcher(lastComponentSuffix: "manifest.json"), occurrence: .nth(1), error: .io)
            case .manifestRead:
                return FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: "manifest.json"), occurrence: .nth(1), error: .io)
            case .checksumsRead:
                return FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: "local-checksums.json"), occurrence: .nth(1), error: .io)
            case .listing:
                return FaultRule(operation: .contentsOfDirectory, matching: URLMatcher(lastComponentSuffix: "Audio", pathContains: "Rex Infernus"), occurrence: .nth(1), error: .io)
            }
        }
    }

    /// Every file of the fixture is still where the prior art put it.
    @available(macOS 15.0, iOS 18.0, *)
    static func expectTreeUntouched(_ harness: CoreHarness, _ files: [String: Data], _ comment: Comment) {
        let kept = files.filter { harness.content(CleanupFixture.legacyRoot.appendingPathComponent($0.key)) == $0.value }
        #expect(kept.count == files.count, comment)
    }

    @Test(
        "R-STO-11: a transient I/O error while phase 1 reads the legacy metadata or lists the tree decides nothing, and the next launch moves every file",
        .timeLimit(.minutes(1)),
        arguments: TransientFault.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func transientFaultDecidesNothing(_ fault: TransientFault) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        harness.fileSystem.addFault(fault.rule)
        let report = try await harness.store.open()
        #expect(!report.legacyMigrationPending && !report.degraded)
        // Nothing was written: no record, no applied manifest, the phase and the prior art's stamp untouched.
        #expect(await harness.state.core.records.isEmpty)
        #expect(await harness.state.core.appliedManifest.entries.isEmpty)
        #expect(await harness.state.migration.phase == .notStarted)
        #expect(try await harness.store.migrateLegacy(maxFiles: 100) == LegacyMigrationProgress(adopted: 0, remaining: 0, dropped: 0, finished: true))
        LegacyEdgeTests.expectTreeUntouched(harness, files, "an I/O error is not an undecodable manifest or a missing file")
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == "1.4+77" && defaults.removedKeys.isEmpty)
        await harness.store.close()
        let next = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: harness.time)
        #expect(try await next.store.open().legacyMigrationPending)
        #expect(try await LegacyMigrationTests.migrateAll(next) == LegacyMigrationProgress(adopted: 13, remaining: 0, dropped: 0, finished: true))
        #expect(try await next.store.planningView().stamp?.appVersion == "1.4+77")
        #expect(!LegacyMigrationTests.exists(next, CleanupFixture.legacyRoot))
        #expect(await CoreInvariants.violations(of: next).isEmpty)
    }

    @Test(
        "R-STO-11: a transient I/O error in phase 1 of a relaunch in phase inProgress keeps the persisted plan and moves or removes nothing",
        .timeLimit(.minutes(1)),
        arguments: [TransientFault.manifestRead, .listing]
    )
    @available(macOS 15.0, iOS 18.0, *)
    func transientFaultOnRelaunchKeepsPlan(_ fault: TransientFault) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (first, defaults) = try LegacyFixture.harness(files: files)
        _ = try await first.store.open()
        #expect(try await first.store.migrateLegacy(maxFiles: 3).adopted == 3)
        await first.store.close()
        let adopted = files.filter { first.content(CleanupFixture.legacyRoot.appendingPathComponent($0.key)) == $0.value }
        let second = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: first.time)
        second.fileSystem.addFault(fault.rule)
        let residencies = await first.state.core.records.mapValues(\.residency)
        #expect(try await !second.store.open().legacyMigrationPending)
        #expect(await second.state.migration.phase == .inProgress, "the persisted phase stays for a later launch")
        #expect(await second.state.core.records.mapValues(\.residency) == residencies)
        #expect(try await second.store.migrateLegacy(maxFiles: 100).adopted == 0)
        LegacyEdgeTests.expectTreeUntouched(second, adopted, "phases 3 and 4 never ran on a view phase 1 could not read")
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == "1.4+77")
        await second.store.close()
        let third = CoreHarness.cleanup(disk: second.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: second.time)
        #expect(try await third.store.open().legacyMigrationPending)
        #expect(try await LegacyMigrationTests.migrateAll(third) == LegacyMigrationProgress(adopted: 10, remaining: 0, dropped: 0, finished: true))
        #expect(try await third.store.planningView().stamp?.appVersion == "1.4+77", "every entry was adopted, over two lifetimes")
        #expect(!LegacyMigrationTests.exists(third, CleanupFixture.legacyRoot))
    }

    @Test(
        "R-STO-11: phase 4 removes nothing after a failed read of the legacy manifest or a failed listing, and the next call removes the tree",
        .timeLimit(.minutes(1)),
        arguments: [TransientFault.manifestRead, .listing]
    )
    @available(macOS 15.0, iOS 18.0, *)
    func phaseFourTransientFault(_ fault: TransientFault) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        _ = try await harness.store.open()
        // Phase 2 neither reads `manifest.json` nor lists a directory, so the fault hits phase 4.
        harness.fileSystem.addFault(fault.rule)
        let progress = try await harness.store.migrateLegacy(maxFiles: 100)
        #expect(progress.adopted == 13 && !progress.finished)
        #expect(await harness.state.migration.phase == .done)
        let root = CleanupFixture.legacyRoot
        #expect(harness.content(root.appendingPathComponent("manifest.json")) == files["manifest.json"], "the manifest still attributes the files")
        #expect(harness.content(root.appendingPathComponent("local-checksums.json")) == files["local-checksums.json"], "nothing was removed")
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == "1.4+77", "the key goes after the tree")
        let finished = try await harness.store.migrateLegacy(maxFiles: 100)
        #expect(finished.finished)
        #expect(!LegacyMigrationTests.exists(harness, root))
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil)
        #expect(try await harness.store.planningView().stamp?.appVersion == "1.4+77")
    }

    /// How phase 4 is interrupted while it lists the legacy tree.
    enum PhaseFourStop: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The caller's task is cancelled.
        case cancelled
        /// The store closes.
        case closed

        var testDescription: String {
            self.rawValue
        }
    }

    /// Review round 3 (reentrancy of c-4): the listing re-checks the phase, and in phase 4 the caller's cancellation,
    /// after each unit, so neither a closed store nor a cancelled caller keeps submitting listings (up to `maxEntries`).
    @Test(
        "R-STO-11: phase 4 stops listing the legacy tree after the unit in flight once the caller cancels or the store closes",
        .timeLimit(.minutes(1)),
        arguments: PhaseFourStop.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func phaseFourStopsListing(_ stop: PhaseFourStop) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: CleanupFixture.legacyPolicy, defaults: defaults, metadata: metadata)
        _ = try await harness.store.open()
        let root = CleanupFixture.legacyRoot.standardizedFileURL.path
        // Phase 1 listed the tree inside open(): only the listings after it count.
        let count = {
            harness.fileSystem.operations.filter { $0.kind == .contentsOfDirectory && $0.url.standardizedFileURL.path.hasPrefix(root) }.count
        }
        let phaseOne = count()
        #expect(phaseOne == 14, "phase 1 listed the root and its 13 directories")
        let listings = {
            count() - phaseOne
        }
        await metadata.setHolding(true)
        let migration = Task {
            try await harness.store.migrateLegacy(maxFiles: 100)
        }
        // Phases 2 and 3 run unit by unit; phase 4 lists the root first (nothing before it lists the legacy tree).
        try await CorePoll.until("phase 4 listed the legacy root") {
            if listings() > 0 {
                return true
            }
            if let unit = await metadata.heldUnits.first {
                await metadata.release(unit)
            }
            return false
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let closing: Task<Void, Never>?
        switch stop {
        case .cancelled:
            migration.cancel()
            closing = nil
        case .closed:
            closing = Task {
                await harness.store.close()
            }
            try await CorePoll.until("close() began") {
                await harness.state.core.phase == .closing
            }
        }
        await metadata.setHolding(false)
        await metadata.releaseAll()
        await #expect(throws: stop == .cancelled ? StoreError.cancelled : StoreError.closed) {
            _ = try await migration.value
        }
        await closing?.value
        #expect(listings() == 2, "the root, then the unit that was in flight; no listing after it")
        LegacyEdgeTests.expectTreeUntouched(harness, files.filter { $0.key.hasSuffix(".json") }, "nothing was removed")
    }
}
