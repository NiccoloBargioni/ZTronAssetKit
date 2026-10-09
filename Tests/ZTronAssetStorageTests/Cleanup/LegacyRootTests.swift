import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Where the legacy root lies relative to the store, and what phase 4 may remove (R-STO-11, R-SEC-2, I-2; ADR draft
/// C-13, C-15, review round 2). The prior art's `baseDirectory:` was the legacy root itself and its docs suggest a
/// `Documents`-rooted one, so the root may be the store's own directory or hold files the prior art never wrote.
@Suite("Cleanup: legacy root placement and phase 4's removal set (R-STO-11, R-SEC-2)")
struct LegacyRootTests {
    /// Where the legacy root lies relative to the store's own `ZTronAssetKit` directory.
    enum Overlap: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The app keeps the prior art's directory as the store's base (`.custom(X)` with `root: X`).
        case sameDirectory
        /// The legacy root is an ancestor of the store's base.
        case ancestor
        /// The legacy root lies inside the store's own directory.
        case insideStore
        /// The store's base, named through a symbolic link to one of its ancestors (paths differ, items do not).
        case throughLink
        /// The store's base lies inside the legacy root, reached through a symbolic link to the root itself (`/A → R`,
        /// base `/A/app`): the link sits exactly at a level the identity chain compares, where a stat that does not follow
        /// a final link sees the link's own inode (review round 3).
        case linkToRoot
        /// The store's base lies inside the legacy root, reached through a symbolic link to a directory below the root
        /// (`/A → R/x`, base `/A/app`): no level of either path resolves to the other's directory itself (review of the L3
        /// close-out).
        case linkIntoRoot
        /// The legacy root lies inside the store's own directory, named through a symbolic link to a directory of the
        /// store (`/A → <container>/sub`, root `/A/CDNAssets`; review of the L3 close-out).
        case rootThroughLinkIntoStore

        var testDescription: String {
            self.rawValue
        }

        /// The store's base, the legacy root as configured, where the root's files physically are, and the link to create
        /// first (path, destination; the destination directory is created first), if any.
        var placement: (base: URL, root: URL, physicalRoot: URL, link: (String, String)?) {
            let legacy = CleanupFixture.legacyRoot
            switch self {
            case .sameDirectory:
                return (legacy, legacy, legacy, nil)
            case .ancestor:
                return (legacy.appendingPathComponent("app", isDirectory: true), legacy, legacy, nil)
            case .insideStore:
                let root = CoreFixture.layout.container.appendingPathComponent("CDNAssets", isDirectory: true)
                return (CoreFixture.base, root, root, nil)
            case .throughLink:
                let alias = URL(fileURLWithPath: "/fake-volume/alias", isDirectory: true)
                return (alias.appendingPathComponent("CDNAssets", isDirectory: true), legacy, legacy, (alias.path, legacy.deletingLastPathComponent().path))
            case .linkToRoot:
                let alias = URL(fileURLWithPath: "/fake-volume/alias-root", isDirectory: true)
                return (alias.appendingPathComponent("app", isDirectory: true), legacy, legacy, (alias.path, legacy.path))
            case .linkIntoRoot:
                let alias = URL(fileURLWithPath: "/fake-volume/alias-child", isDirectory: true)
                return (alias.appendingPathComponent("app", isDirectory: true), legacy, legacy, (alias.path, legacy.appendingPathComponent("x").path))
            case .rootThroughLinkIntoStore:
                let alias = URL(fileURLWithPath: "/fake-volume/alias-in-store", isDirectory: true)
                let physical = CoreFixture.layout.container.appendingPathComponent("sub/CDNAssets", isDirectory: true)
                return (CoreFixture.base, alias.appendingPathComponent("CDNAssets", isDirectory: true), physical, (alias.path, physical.deletingLastPathComponent().path))
            }
        }

        /// The store sits at the default location (`.applicationSupport`), not at a custom base.
        var defaultLocation: Bool {
            self == .insideStore || self == .rootThroughLinkIntoStore
        }
    }

    @Test(
        "R-STO-11: a legacy root that is, contains or lies inside the store's directory is never migrated, and the store survives",
        .timeLimit(.minutes(1)),
        arguments: Overlap.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func overlappingRootSkipped(_ overlap: Overlap) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let placement = overlap.placement
        let fileSystem = FakeFileSystem(disk: try LegacyFixture.disk(files, root: placement.physicalRoot), time: ManualTimeSource())
        if let (path, destination) = placement.link {
            try LegacyFixture.makeDirectories(URL(fileURLWithPath: destination, isDirectory: true), on: fileSystem)
            try fileSystem.createSymbolicLink(at: URL(fileURLWithPath: path), destination: destination)
        }
        // Through the link where there is one (its target's directories are created).
        try LegacyFixture.makeDirectories(placement.base, on: fileSystem)
        var disk = fileSystem.survivingDisk()
        disk.makeDurable()
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let location: StorageLocation = overlap.defaultLocation ? .applicationSupport : .custom(placement.base)
        let legacy = LegacyMigrationPolicy(enabled: true, root: placement.root)
        let harness = CoreHarness.cleanup(disk: disk, location: location, legacy: legacy, defaults: defaults)
        let layout = StoreLayout(base: placement.base)
        let report = try await harness.store.open()
        #expect(!report.legacyMigrationPending && !report.degraded)
        #expect(try await harness.store.migrateLegacy(maxFiles: 100) == LegacyMigrationProgress(adopted: 0, remaining: 0, dropped: 0, finished: true))
        // Nothing was written: no record, no applied manifest, the phase and the prior art's stamp untouched.
        #expect(await harness.state.core.records.isEmpty)
        #expect(await harness.state.core.appliedManifest.entries.isEmpty)
        #expect(await harness.state.migration.phase == .notStarted)
        #expect(defaults.string(forKey: CleanupFixture.legacyKey) == "1.4+77" && defaults.removedKeys.isEmpty)
        for (relative, bytes) in files {
            #expect(harness.content(placement.root.appendingPathComponent(relative)) == bytes, "\(relative) is untouched")
        }
        // The store keeps working, in this lifetime and the next (I-2: a present record's blob exists).
        let asset = CleanupFixture.asset("kept", seed: 760)
        _ = try await harness.store.apply(CoreFixture.manifest([asset.entry]), etag: nil, eviction: nil)
        try await harness.publish(asset.bytes, [asset.entry])
        try await harness.store.flush(.durable)
        #expect(harness.content(layout.blobURL(asset.key)) == asset.bytes)
        await harness.store.close()
        let next = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), location: location, legacy: legacy, defaults: defaults, time: harness.time)
        #expect(try await !next.store.open().legacyMigrationPending)
        #expect(await next.isPresent(asset.id, at: asset.key))
        #expect(next.content(layout.blobURL(asset.key)) == asset.bytes)
    }

    /// What a stat of a directory above the legacy root fails with (review of the L3 close-out, ZProbe-perm).
    enum AncestorFault: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// EPERM: a sandbox refusing metadata of a directory it does not grant says nothing about an overlap.
        case permissionDenied
        /// EIO: nothing can be decided from the stat.
        case io

        var testDescription: String {
            self.rawValue
        }
    }

    @Test(
        "R-STO-11: a refused stat of a directory above the legacy root is no overlap and migration runs; an I/O error decides nothing and says so",
        .timeLimit(.minutes(1)),
        arguments: AncestorFault.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func ancestorStatFault(_ fault: AncestorFault) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        let error: FileSystemError = fault == .io ? .io : .permissionDenied
        harness.fileSystem.addFault(FaultRule(operation: .itemInfo, matching: URLMatcher(lastComponentSuffix: "Caches"), occurrence: .every, error: error))
        let report = try await harness.store.open()
        let undecided = harness.tap.lines.contains { $0.level == .error && $0.message.contains("could not tell whether the legacy root overlaps") }
        switch fault {
        case .permissionDenied:
            #expect(report.legacyMigrationPending && !undecided)
            #expect(await harness.state.migration.phase == .inProgress)
            #expect(try await LegacyMigrationTests.migrateAll(harness) == LegacyMigrationProgress(adopted: 13, remaining: 0, dropped: 0, finished: true))
            #expect(await CoreInvariants.violations(of: harness).isEmpty)
        case .io:
            #expect(!report.legacyMigrationPending && undecided, "decided nothing, and logged it")
            #expect(await harness.state.migration.phase == .notStarted)
            LegacyEdgeTests.expectTreeUntouched(harness, files, "nothing moves")
            #expect(defaults.string(forKey: CleanupFixture.legacyKey) == "1.4+77")
        }
    }

    @Test(
        "R-STO-11: phase 4 removes only what the prior art wrote, never recursively: other files in the legacy root survive",
        .timeLimit(.minutes(1))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func phaseFourRemovesOnlyLegacyFiles() async throws {
        var files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let root = CleanupFixture.legacyRoot
        let shared = try #require(entries.first.map { LegacyFixture.relativePath($0) })
        let sharedDirectory = String(shared[..<(shared.lastIndex(of: "/") ?? shared.startIndex)])
        // A user's file at the root (the prior art's docs suggest a Documents-rooted directory), one beside a legacy
        // file, and one in a directory of its own.
        let foreign = ["notes.txt", "\(sharedDirectory)/user.doc", "Inbox/letter.pdf"]
        for (index, path) in foreign.enumerated() {
            files[path] = CoreFixture.bytes(770 + UInt64(index), count: 40)
        }
        let (harness, defaults) = try LegacyFixture.harness(files: files)
        _ = try await harness.store.open()
        let progress = try await LegacyMigrationTests.migrateAll(harness)
        #expect(progress == LegacyMigrationProgress(adopted: 13, remaining: 0, dropped: 0, finished: true))
        for path in foreign {
            #expect(harness.content(root.appendingPathComponent(path)) == files[path], "\(path) survives phase 4")
        }
        // Every file the prior art wrote is gone (adopted, or removed), and so is every directory it left empty.
        for path in ["manifest.json", "local-checksums.json"] + entries.map(LegacyFixture.relativePath) {
            #expect(!harness.exists(root.appendingPathComponent(path)), "\(path) is removed")
        }
        var legacyDirectories: Set<String> = []
        for entry in entries {
            let components = LegacyFixture.relativePath(entry).split(separator: "/").dropLast()
            for depth in stride(from: 1, through: components.count, by: 1) {
                legacyDirectories.insert(components.prefix(depth).joined(separator: "/"))
            }
        }
        #expect(legacyDirectories.contains(sharedDirectory))
        for directory in legacyDirectories {
            let holdsForeign = foreign.contains { $0.hasPrefix(directory + "/") }
            #expect(harness.exists(root.appendingPathComponent(directory)) == holdsForeign, "\(directory): kept only for a file that is not the prior art's")
        }
        #expect(harness.exists(root) && defaults.string(forKey: CleanupFixture.legacyKey) == nil)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
        // Nothing is pending at the next launch: the prior art's files are gone, the user's are not ours.
        await harness.store.close()
        let next = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: harness.time)
        #expect(try await !next.store.open().legacyMigrationPending)
        #expect(next.content(root.appendingPathComponent("notes.txt")) == files["notes.txt"])
    }
}
