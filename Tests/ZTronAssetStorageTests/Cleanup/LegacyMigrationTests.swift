import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Legacy migration (R-STO-11, R-SEC-2, H-10; ADR-029, store.md §7) over the prior art's own output
/// (`Tests/Fixtures/legacy-v0`).
@Suite("Cleanup: legacy migration (R-STO-11, H-10)")
struct LegacyMigrationTests {
    /// Runs `migrateLegacy` until it reports finished (at most `rounds` calls).
    @available(macOS 15.0, iOS 18.0, *)
    static func migrateAll(_ harness: CoreHarness, batch: Int = 100, rounds: Int = 50) async throws -> LegacyMigrationProgress {
        var progress = LegacyMigrationProgress(adopted: 0, remaining: 0, dropped: 0, finished: false)
        for _ in 0..<rounds where !progress.finished {
            progress = try await harness.store.migrateLegacy(maxFiles: batch)
        }
        return progress
    }

    /// Whether anything exists at `url` on the fake.
    @available(macOS 15.0, iOS 18.0, *)
    static func exists(_ harness: CoreHarness, _ url: URL) -> Bool {
        ((try? harness.fileSystem.itemInfo(at: url)) ?? nil) != nil
    }

    @Test("R-STO-11: legacy files whose checksum verifies are moved into blobs, not re-downloaded", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func adoptsVerifiedFiles() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        let report = try await harness.store.open()
        #expect(report.legacyMigrationPending && report.stamp == nil)
        // Phase 1 planned only: the legacy manifest is the applied one (no ETag), every entry is an absent record that
        // expects its blob, and nothing moved yet.
        let planned = try await harness.store.planningView()
        #expect(planned.appliedManifest.entries == entries)
        #expect(await harness.state.core.etag == nil)
        for entry in entries {
            let record = try #require(planned.records[entry.identifier])
            #expect(record.residency == .absent(.neverFetched) && record.expectedBlob == entry.checksum)
            #expect(harness.content(CleanupFixture.legacyRoot.appendingPathComponent(LegacyFixture.relativePath(entry))) != nil)
        }
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress == LegacyMigrationProgress(adopted: 13, remaining: 0, dropped: 0, finished: true))
        for entry in entries {
            let location = try #require(await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false))
            let bytes = try #require(files[LegacyFixture.relativePath(entry)])
            #expect(location.url.path.hasPrefix(harness.layout.blobsDirectory.path) && harness.content(location.url) == bytes)
            #expect(location.integrity == .verified)
        }
        #expect(await harness.store.availability(of: .all).present == entries.count)
        // Moved, not copied: every adopted blob arrived by a rename from the legacy tree, and nothing wrote blob bytes.
        let operations = harness.fileSystem.operations
        let moved = operations.filter { $0.kind == .rename && $0.url.path.hasPrefix(CleanupFixture.legacyRoot.path) && $0.destination?.path.hasPrefix(harness.layout.blobsDirectory.path) == true }
        #expect(moved.count == 12, "13 files, two of them the same bytes (the second one deduplicated)")
        #expect(!operations.contains { $0.kind == .write && $0.url.path.hasPrefix(harness.layout.blobsDirectory.path) })
        // Phase 3 migrated the stamp; phase 4 removed the tree and then the key.
        let view = try await harness.store.planningView()
        #expect(view.stamp?.appVersion == "1.4+77" && !view.syncDue)
        #expect(!LegacyMigrationTests.exists(harness, CleanupFixture.legacyRoot))
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil && defaults.removedKeys == [CleanupFixture.legacyKey])
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
        // A relaunch has nothing left to migrate.
        await harness.store.close()
        let reopened = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: harness.time)
        let second = try await reopened.store.open()
        #expect(!second.legacyMigrationPending && second.stamp?.appVersion == "1.4+77")
        #expect(try await reopened.store.migrateLegacy(maxFiles: 10).finished)
    }

    @Test("R-STO-11: a legacy file whose bytes do not verify is dropped and the stamp is not migrated", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func corruptFileDropped() async throws {
        var files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let victim = try #require(entries.first { $0.identifier == "bo7.ri.cinematic.intro" })
        let path = LegacyFixture.relativePath(victim)
        let original = try #require(files[path])
        files[path] = Data(original.reversed())
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        _ = try await harness.store.open()
        let progress = try await LegacyMigrationTests.migrateAll(harness, batch: 4)
        #expect(progress == LegacyMigrationProgress(adopted: 12, remaining: 0, dropped: 1, finished: true))
        #expect(await harness.record(victim.identifier)?.residency == .absent(.neverFetched), "re-downloaded by the next run")
        let view = try await harness.store.planningView()
        #expect(view.stamp == nil && view.syncDue, "the stamp migrates only when every entry was adopted")
        #expect(!LegacyMigrationTests.exists(harness, CleanupFixture.legacyRoot), "the dropped file goes with the tree")
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil)
    }

    @Test("R-STO-11: a vanished legacy directory drops the UserDefaults stamp without claiming synced", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func vanishedDirectoryDropsStamp() async throws {
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(legacy: CleanupFixture.legacyPolicy, defaults: defaults)
        let report = try await harness.store.open()
        #expect(!report.legacyMigrationPending && report.stamp == nil)
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil)
        #expect(await harness.state.migration.phase == .notStarted)
        #expect(await harness.state.core.records.isEmpty)
        #expect(try await harness.store.migrateLegacy(maxFiles: 10) == LegacyMigrationProgress(adopted: 0, remaining: 0, dropped: 0, finished: true))
    }

    @Test("R-STO-11: lookups hit adopted legacy files while migration is still running, and no snapshot precedes reconciliation", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func lookupsDuringMigration() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let (harness, _) = try LegacyFixture.harness(files: files)
        _ = try await harness.store.open()
        // The only install of open() is its last step, after reconciliation and phase 1: it lists nothing yet.
        #expect(await harness.sink.offeredKeys.count == 1)
        #expect(await harness.sink.installed.entries.isEmpty)
        let first = try await harness.store.migrateLegacy(maxFiles: 1)
        #expect(first.adopted == 1 && first.remaining == entries.count - 1 && !first.finished)
        let installed = await harness.sink.installed.entries
        #expect(installed.count == 1, "the batch published its adoption")
        let adopted = try #require(installed.keys.first)
        #expect(await harness.store.location(for: adopted, extensions: [], recordingAccess: false) != nil)
        // Adopt-on-demand for a resolve of an id the batches have not reached yet.
        let pending = try #require(entries.map(\.identifier).first { $0 != adopted && installed[$0] == nil })
        let entry = try #require(entries.first { $0.identifier == pending })
        let location = try #require(try await harness.store.adoptLegacyNow(pending))
        #expect(harness.content(location.url) == files[LegacyFixture.relativePath(entry)])
        #expect(await harness.sink.installed.entries[pending] != nil, "adopt-on-demand installs at once")
        #expect(try await harness.store.adoptLegacyNow(pending) == location, "an adopted id is read from its record")
        #expect(try await harness.store.adoptLegacyNow("not.legacy") == nil)
        let rest = try await LegacyMigrationTests.migrateAll(harness)
        #expect(rest == LegacyMigrationProgress(adopted: entries.count, remaining: 0, dropped: 0, finished: true), "an on-demand adoption counts once")
        #expect(await harness.store.availability(of: .all).present == entries.count)
    }

    @Test("R-SEC-2: a legacy entry whose directory component is a symbolic link is dropped and nothing outside the legacy root moves", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func symlinkedDirectoryDropped() async throws {
        let inside = CleanupFixture.asset("inside.a", seed: 700)
        let outside = CleanupFixture.asset("outside.b", seed: 701)
        var insideEntry = inside.entry
        insideEntry.localPathComponents = ["Real"]
        insideEntry.localFileName = "a"
        var outsideEntry = outside.entry
        outsideEntry.localPathComponents = ["Link"]
        outsideEntry.localFileName = "b"
        let elsewhere = URL(fileURLWithPath: "/fake-volume/Elsewhere", isDirectory: true)
        let files: [String: Data] = [
            "manifest.json": try LegacyFixture.manifestJSON([insideEntry, outsideEntry]),
            "local-checksums.json": try LegacyFixture.checksumsJSON([:]),
            "Real/a.png": inside.bytes,
        ]
        // A directory outside the legacy root holding the bytes the second entry expects, reached through a link.
        let outsideDisk = try LegacyFixture.disk(["b.png": outside.bytes], root: elsewhere)
        let disk = try LegacyFixture.disk(files, base: outsideDisk, links: [("Link", elsewhere.path)])
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1+1"])
        let harness = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: defaults)
        _ = try await harness.store.open()
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress.adopted == 1 && progress.dropped == 1 && progress.finished)
        #expect(await harness.isPresent(inside.id, at: inside.key))
        #expect(await harness.record(outside.id)?.residency == .absent(.neverFetched))
        #expect(harness.content(elsewhere.appendingPathComponent("b.png")) == outside.bytes, "the file behind the link is untouched")
        let outsideTouched = harness.fileSystem.operations.filter { $0.kind.isMutation && ($0.url.path.hasPrefix(elsewhere.path) || $0.destination?.path.hasPrefix(elsewhere.path) == true) }
        #expect(outsideTouched.isEmpty)
        #expect(!LegacyMigrationTests.exists(harness, CleanupFixture.legacyRoot), "the link itself was removed with the tree")
        #expect(try await harness.store.planningView().stamp == nil)
    }

    @Test("R-STO-11: a checksum-less legacy entry is adopted under the prior art's local checksum and flagged unverified", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func localChecksumAdoption() async throws {
        let bytes = CoreFixture.bytes(710, count: 333)
        var entry = CoreFixture.entry("legacy.plain", bytes, checksum: false)
        entry.localPathComponents = []
        let files: [String: Data] = [
            "manifest.json": try LegacyFixture.manifestJSON([entry]),
            "local-checksums.json": try LegacyFixture.checksumsJSON([entry.identifier.rawValue: ContentHash.sha256(of: bytes).hex]),
            "legacy/plain.png": bytes,
        ]
        let (harness, _) = try LegacyFixture.harness(files: files)
        _ = try await harness.store.open()
        #expect(try await LegacyMigrationTests.migrateAll(harness).adopted == 1)
        let location = try #require(await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false))
        #expect(location.integrity == .unverified && harness.content(location.url) == bytes)
        #expect(try await harness.store.planningView().stamp?.appVersion == "1.4+77")
    }

    /// What the engine applied while migration ran.
    enum AppliedDuringMigration: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The legacy manifest's own bytes (the server's payload has not changed).
        case sameManifest
        /// A newer manifest: every legacy entry and one more (review round 3, ZProbe-stamp).
        case newerManifest

        var testDescription: String {
            self.rawValue
        }
    }

    /// Review round 3 (ZProbe-stamp): phase 3 checked only that every legacy id is present, then stamped the applied
    /// manifest's digest as synced. A manifest the engine applied during migration whose new entries were never fetched
    /// was then claimed synced, so `isSyncDue`, `.atMostEvery` or "unchanged since the last sync" could skip them.
    @Test(
        "R-STO-11: the legacy stamp migrates only over the legacy manifest itself, never over a newer one applied during migration",
        .timeLimit(.minutes(1)),
        arguments: AppliedDuringMigration.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func stampOnlyOverLegacyManifest(_ applied: AppliedDuringMigration) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let (harness, _) = try LegacyFixture.harness(files: files)
        _ = try await harness.store.open()
        let legacyDigest = try await harness.store.planningView().appliedManifest.digest
        let extra = CleanupFixture.asset("extra.asset", seed: 740)
        let manifest: ValidatedManifest
        switch applied {
        case .sameManifest:
            manifest = try ManifestDecoder.decode(try #require(files["manifest.json"]))
            #expect(manifest.digest == legacyDigest)
        case .newerManifest:
            manifest = try ValidatedManifest(entries: entries + [extra.entry], digest: ContentHash.sha256(of: Data("newer".utf8)))
        }
        _ = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress == LegacyMigrationProgress(adopted: 13, remaining: 0, dropped: 0, finished: true))
        let view = try await harness.store.planningView()
        switch applied {
        case .sameManifest:
            #expect(view.stamp?.appVersion == "1.4+77" && view.stamp?.manifestDigest == legacyDigest && !view.syncDue)
        case .newerManifest:
            #expect(view.stamp == nil, "the newer manifest was never synced: \(String(describing: view.stamp))")
            #expect(view.syncDue)
            #expect(view.records[extra.id]?.residency == .absent(.neverFetched))
        }
    }

    @Test("R-STO-11: an undecodable legacy manifest degrades the launch, adopts nothing, removes the prior art's metadata and the key, and keeps files it cannot attribute", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func undecodableManifest() async throws {
        let files: [String: Data] = ["manifest.json": Data("{ not json".utf8), "x/y.png": CoreFixture.bytes(720)]
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        let report = try await harness.store.open()
        #expect(report.degraded && report.legacyMigrationPending)
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress.adopted == 0 && progress.finished)
        let view = try await harness.store.planningView()
        #expect(view.stamp == nil && view.syncDue && view.records.isEmpty)
        // Without a manifest no file can be attributed to the prior art, so phase 4 removes only its metadata (C-15).
        let root = CleanupFixture.legacyRoot
        #expect(!LegacyMigrationTests.exists(harness, root.appendingPathComponent("manifest.json")))
        #expect(harness.content(root.appendingPathComponent("x/y.png")) == files["x/y.png"])
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil)
    }

    @Test("R-STO-11: phase 1 never overrides newer state: an applied manifest stays and indexed records are kept", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func phaseOneKeepsNewerState() async throws {
        // A store that already applied a manifest, then a legacy tree appears (an earlier launch with migration off).
        let first = CoreHarness.cleanup()
        let current = CleanupFixture.asset("bo7.menu.background", seed: 730)
        _ = try await first.store.open()
        _ = try await first.store.apply(CoreFixture.manifest([current.entry]), etag: ETag(rawValue: "\"e1\""), eviction: nil)
        await first.store.close()
        let legacyFiles = try LegacyFixture.fixtureFiles()
        let disk = try LegacyFixture.disk(legacyFiles, base: first.fileSystem.survivingDisk())
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: first.time)
        _ = try await harness.store.open()
        let view = try await harness.store.planningView()
        #expect(view.appliedManifest.entries == [current.entry], "the newer applied manifest is kept")
        #expect(await harness.state.core.etag == ETag(rawValue: "\"e1\""))
        #expect(Set(view.records.keys) == [current.id], "records are inserted only for ids the applied manifest lists and the index lacks")
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress.adopted == 0 && progress.finished, "the legacy file of that id has other bytes than the applied entry expects")
        #expect(try await harness.store.planningView().syncDue)
    }

    @Test("R-STO-11: no legacy file moves before a generation holding the phase-1 plan is committed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func planCommittedBeforeMoves() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (harness, _) = try LegacyFixture.harness(files: files)
        // Every index write of open() runs out of space: phase 1's commit and the launch commit both fail.
        for occurrence in 1...4 {
            harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(occurrence), error: .noSpace))
        }
        _ = try await harness.store.open()
        #expect(LegacyGateTests.landedCommits(harness.fileSystem.operations[...]).isEmpty, "open() could not commit the plan")
        #expect(try await LegacyMigrationTests.migrateAll(harness).finished)
        let operations = harness.fileSystem.operations
        let firstMove = try #require(operations.firstIndex { $0.kind == .rename && $0.url.path.hasPrefix(CleanupFixture.legacyRoot.path) })
        let commitsBefore = operations[..<firstMove].filter {
            $0.kind == .rename && $0.url.lastPathComponent == "index.tmp" && $0.destination?.lastPathComponent == "index.bin" && $0.failure == nil
        }
        #expect(!commitsBefore.isEmpty, "a commit holding the plan landed before the first legacy file moved")
    }

    /// What happens to the first legacy entry while phase 3's check has the actor released.
    enum CheckInterruption: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// It is quarantined: no longer present, so the stamp must not migrate.
        case quarantine
        /// It is pinned: a counted mutation that leaves it present, so the stamp still migrates.
        case pin

        var testDescription: String {
            self.rawValue
        }
    }

    @Test(
        "R-STO-11: phase 3 checks the legacy entries with the actor released between chunks and migrates the stamp only over a pass no mutation interrupted",
        .timeLimit(.minutes(1)),
        arguments: CheckInterruption.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func phaseThreeCheckRevalidates(_ interruption: CheckInterruption) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let metadata = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: CleanupFixture.legacyPolicy, defaults: defaults, metadata: metadata)
        #expect(try await harness.store.open().legacyMigrationPending)
        // Every file adopted on demand: the queue is empty and phase 3 has not run.
        for entry in entries {
            _ = try await harness.store.adoptLegacyNow(entry.identifier)
        }
        try await harness.store.flush(.durable)
        let migration = await harness.state.migration
        #expect(migration.phase == .inProgress && migration.queue.isEmpty && migration.claimed.isEmpty)
        await harness.store.testSetLegacyCheckChunk(2)
        await metadata.setHolding(true)
        let finishing = Task {
            try await harness.store.migrateLegacy(maxFiles: 10)
        }
        // The first chunk (the first two entries) was read; the release after it is held.
        try await metadata.requireHeldUnits(atLeast: 1)
        let parked = try #require(await metadata.heldUnits.first)
        let first = try #require(entries.first?.identifier)
        switch interruption {
        case .quarantine:
            _ = try await CleanupSteps.run(metadata, keeping: [parked]) {
                try await harness.store.reportUnreadable(first)
            }
        case .pin:
            _ = try await CleanupSteps.run(metadata, keeping: [parked]) {
                try await harness.store.setPinned([first], pinned: true)
            }
        }
        await metadata.setHolding(false)
        await metadata.releaseAll()
        #expect(try await finishing.value.finished)
        let view = try await harness.store.planningView()
        #expect(await harness.state.migration.phase == .done)
        switch interruption {
        case .quarantine:
            #expect(view.stamp == nil && view.syncDue, "an entry quarantined during the check is not claimed synced")
        case .pin:
            #expect(view.stamp?.appVersion == "1.4+77", "the interrupted pass started again and found every entry present")
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
