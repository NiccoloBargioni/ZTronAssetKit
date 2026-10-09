import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The scripted eviction of R-STO-5 (SPEC §7.3 "crash at every boundary during eviction"): four assets over a budget
/// of two, quota eviction, the reap after acknowledgement and grace, a durable flush, close.
@available(macOS 15.0, iOS 18.0, *)
enum EvictionRun {
    static let assets = (0..<4).map { CleanupFixture.asset("e\($0)", seed: 900 + UInt64($0), count: 200) }
    static let policy = CleanupFixture.policy(budget: .bytes(500), hysteresisTarget: 1)
    static let manifest = CoreFixture.manifest(EvictionRun.assets.map(\.entry))

    /// The setup before the enumerated part: every asset published and durably committed.
    static func setUp(_ harness: CoreHarness) async throws {
        try await harness.seed(EvictionRun.assets)
        try await harness.store.flush(.durable)
        harness.time.advance(by: 3_600)
    }

    /// The enumerated part; returns the newest generation a commit that returned reached.
    static func evict(_ harness: CoreHarness) async -> UInt64 {
        var committed: UInt64 = 0
        do {
            _ = try await harness.store.evictIfNeeded()
            committed = await harness.state.core.committedGeneration
            await harness.settleDeletions()
            try await harness.store.flush(.durable)
            committed = await harness.state.core.committedGeneration
            await harness.store.close()
        } catch {
            // The crash: every call after it fails.
        }
        return committed
    }
}

/// Every enumeration gives its cooperative thread back once per case (`await Task.yield()`, ADR draft ios.md item 4).
@Suite("Cleanup: crash consistency of eviction, migration and reaping (R-STO-5)")
struct CleanupCrashTests {
    /// The I-5 checks of a reopened store against the disk it loaded.
    @available(macOS 15.0, iOS 18.0, *)
    static func checkGenerations(_ harness: CoreHarness, disk: DiskImage, committed: UInt64, report: OpenReport, label: String) async {
        let headers = IndexFile.allCases.compactMap { disk.files[harness.layout.indexURL($0).path].flatMap(IndexHeader.parse) }
        let loaded = await harness.state.core.committedGeneration
        #expect(loaded >= committed, "\(label): I-5, generation \(loaded) < committed \(committed)")
        #expect(headers.allSatisfy { report.launchEpoch > $0.generation }, "\(label): I-5, the epoch reuses a generation")
    }

    @Test("R-STO-5: crash at every boundary during eviction preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func crashDuringEviction(mode: CrashMode) async throws {
        let clean = CoreHarness.cleanup(policy: EvictionRun.policy)
        try await EvictionRun.setUp(clean)
        let start = clean.fileSystem.mutationCount
        _ = await EvictionRun.evict(clean)
        let total = clean.fileSystem.mutationCount
        let unlinked = Set(CoreInvariants.blobRemovals(clean.fileSystem.operations, layout: clean.layout))
        #expect(unlinked.count == 2 && total > start, "the clean run evicts and reaps two blobs")
        for point in start..<total {
            await Task.yield()
            let label = "\(mode) before mutation \(point)"
            let harness = CoreHarness.cleanup(policy: EvictionRun.policy, crashBefore: point, mode: mode)
            try await EvictionRun.setUp(harness)
            let committed = await EvictionRun.evict(harness)
            #expect(harness.fileSystem.crashed, "\(label): the crash happened")
            let disk = harness.fileSystem.survivingDisk()
            let reopened = CoreHarness.cleanup(disk: disk, policy: EvictionRun.policy, time: harness.time)
            let report = try await reopened.store.open()
            await CleanupCrashTests.checkGenerations(reopened, disk: disk, committed: committed, report: report, label: label)
            let violations = await CoreInvariants.violations(of: reopened)
            #expect(violations.isEmpty, "\(label): \(violations)")
            for asset in EvictionRun.assets {
                let residency = await reopened.record(asset.id)?.residency
                let present = await reopened.isPresent(asset.id, at: asset.key)
                #expect(present || residency == .absent(.evicted), "\(label): \(asset.id.rawValue) is \(String(describing: residency))")
            }
            // The run completes from any survivor: two assets stay, within the budget, every invariant intact.
            _ = try await reopened.store.evictIfNeeded()
            await reopened.settleDeletions()
            let space = try await reopened.store.freeSpace()
            #expect(space.usedBytes == 400, "\(label): converged to \(space.usedBytes) bytes")
            let after = await CoreInvariants.violations(of: reopened)
            #expect(after.isEmpty, "\(label) after convergence: \(after)")
            await reopened.store.close()
        }
    }

    @Test(
        "R-STO-5: crash at every boundary during legacy migration preserves I-1…I-5 and adopts every verified file",
        .timeLimit(.minutes(1)),
        arguments: CrashMode.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func crashDuringLegacyMigration(mode: CrashMode) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let disk = try LegacyFixture.disk(files)
        let (clean, _) = try LegacyFixture.harness(files: files)
        _ = try await clean.store.open()
        #expect(try await LegacyMigrationTests.migrateAll(clean, batch: 4).finished)
        await clean.store.close()
        let total = clean.fileSystem.mutationCount
        for point in 0..<total {
            await Task.yield()
            let label = "\(mode) before mutation \(point)"
            let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
            let crashed = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: defaults, crashBefore: point, mode: mode)
            var committed: UInt64 = 0
            do {
                _ = try await crashed.store.open()
                committed = await crashed.state.core.committedGeneration
                _ = try await LegacyMigrationTests.migrateAll(crashed, batch: 4)
                committed = await crashed.state.core.committedGeneration
                await crashed.store.close()
            } catch {
                // The crash.
            }
            #expect(crashed.fileSystem.crashed, "\(label): the crash happened")
            let survivor = crashed.fileSystem.survivingDisk()
            let reopened = CoreHarness.cleanup(disk: survivor, legacy: CleanupFixture.legacyPolicy, defaults: defaults, time: crashed.time)
            let report = try await reopened.store.open()
            await CleanupCrashTests.checkGenerations(reopened, disk: survivor, committed: committed, report: report, label: label)
            // I-2 allows needsHeal after reconciliation; nothing else may be broken.
            let violations = await CoreInvariants.violations(of: reopened, allowNeedsHeal: true)
            #expect(violations.isEmpty, "\(label): \(violations)")
            let progress = try await LegacyMigrationTests.migrateAll(reopened, batch: 4)
            #expect(progress.finished, "\(label): the migration finishes")
            for entry in entries {
                let location = await reopened.store.location(for: entry.identifier, extensions: [], recordingAccess: false)
                #expect(location.flatMap { reopened.content($0.url) } == files[LegacyFixture.relativePath(entry)], "\(label): \(entry.identifier.rawValue) was not adopted")
            }
            #expect(!LegacyMigrationTests.exists(reopened, CleanupFixture.legacyRoot), "\(label): the tree is gone")
            #expect(defaults.string(forKey: CleanupFixture.legacyKey) == nil, "\(label): the key is gone")
            #expect(try await reopened.store.planningView().stamp?.appVersion == "1.4+77", "\(label): every file verified, so the stamp migrated")
            let after = await CoreInvariants.violations(of: reopened)
            #expect(after.isEmpty, "\(label) after convergence: \(after)")
            await reopened.store.close()
        }
    }

    /// store-2 S2-04: a key reaped after a commit that still lists it in DOOMED, then published again before the lazy
    /// commit that drops it: the next launch must bind the new bytes, never delete them.
    @Test(
        "R-STO-5: a blob reaped and then republished before the lazy commit survives a crash and the next launch",
        .timeLimit(.minutes(1)),
        arguments: CrashMode.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func reapedThenRepublished(mode: CrashMode) async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(mode: mode, metadata: metadata)
        let a = CleanupFixture.asset("a", seed: 950)
        try await harness.seed([a])
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        _ = await harness.store.runDueWork()
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        await metadata.setHolding(true)
        // The reap's deletion unit is held: the key is `deleting`.
        let reap = Task {
            await harness.store.runDueWork()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        // The manifest adds `a` back meanwhile: it cannot adopt a key being deleted, and its commit (held too) still
        // persists the key in DOOMED.
        let apply = Task {
            try await harness.store.apply(CoreFixture.manifest([a.entry]), etag: nil, eviction: nil)
        }
        try await metadata.requireHeldUnits(atLeast: 2)
        #expect(await harness.record(a.id)?.residency == .absent(.neverFetched))
        await metadata.setHolding(false)
        _ = await reap.value
        _ = try await apply.value
        #expect(!harness.hasBlob(a.key), "reaped")
        let doomed = try IndexCodec.decode(try #require(harness.fileSystem.survivingDisk().files[harness.layout.indexURL(.current).path])).get().doomed
        #expect(doomed[a.key] == .unreferenced, "the committed generation still lists the reaped key in DOOMED")
        // The re-download lands; the crash comes before any commit drops the key from DOOMED.
        try await harness.publish(a.bytes, [a.entry], urgency: .bulk, sequence: 2)
        #expect(harness.content(harness.layout.blobURL(a.key)) == a.bytes)
        let survivor = harness.fileSystem.survivingDisk()
        let reopened = CoreHarness.cleanup(disk: survivor, time: harness.time)
        _ = try await reopened.store.open()
        let violations = await CoreInvariants.violations(of: reopened)
        #expect(violations.isEmpty, "\(mode): \(violations)")
        await reopened.settleDeletions()
        _ = try await reopened.store.collectGarbage(until: reopened.time.monotonicNow().adding(seconds: 60))
        switch mode {
        case .processKill, .processKillTornWrite:
            #expect(await reopened.isPresent(a.id, at: a.key), "\(mode): the next launch binds the republished bytes")
            #expect(reopened.content(reopened.layout.blobURL(a.key)) == a.bytes, "\(mode): and never deletes them")
        case .powerLossDropUnsynced, .powerLossKeepMetadata:
            // The new name may not have survived; whatever did is consistent.
            let present = await reopened.isPresent(a.id, at: a.key)
            #expect(!present || reopened.content(reopened.layout.blobURL(a.key)) == a.bytes, "\(mode)")
        }
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
    }

    /// store-2 S2-01 timeline C through the real `apply`: a manifest re-adds a key whose deletion unit is in flight.
    @Test("R-CLN-1: a manifest that re-adds a key being deleted waits for the deletion and re-downloads", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func readdDuringDeletion() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let a = CleanupFixture.asset("a", seed: 960)
        try await harness.seed([a])
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        _ = await harness.store.runDueWork()
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        await metadata.setHolding(true)
        let reap = Task {
            await harness.store.runDueWork()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let apply = Task {
            try await harness.store.apply(CoreFixture.manifest([a.entry]), etag: nil, eviction: nil)
        }
        try await metadata.requireHeldUnits(atLeast: 2)
        #expect(await harness.record(a.id)?.residency == .absent(.neverFetched), "a key being deleted is never adopted")
        // The re-download is staged and published: it claims its file, then waits for the deletion of the key.
        let staged = try await harness.stage(a.bytes, for: a.entry, sequence: 2)
        let publish = Task {
            try await harness.store.publish(staged, binding: [a.id], expecting: a.entry.contentIdentity, urgency: .userInitiated)
        }
        try await metadata.requireHeldUnits(atLeast: 3)
        await metadata.release(try #require(await metadata.heldUnits.last))
        try await CorePoll.until("the publication waits for the deletion") {
            await harness.state.core.keyWaiters[a.key]?.isEmpty == false
        }
        #expect(harness.hasBlob(a.key), "the deletion unit has not run yet")
        await metadata.setHolding(false)
        _ = await reap.value
        _ = try await apply.value
        let location = try #require(try await publish.value[a.id])
        #expect(location.url == harness.layout.blobURL(a.key) && harness.content(location.url) == a.bytes)
        let unlinks = CoreInvariants.blobRemovals(harness.fileSystem.operations, layout: harness.layout)
        let placements = harness.fileSystem.operations.filter { $0.kind == .rename && $0.destination == harness.layout.blobURL(a.key) }
        #expect(unlinks.count == 1 && placements.count == 2, "deleted once, then placed afresh")
        await harness.settleDeletions()
        #expect(await harness.isPresent(a.id, at: a.key) && harness.content(harness.layout.blobURL(a.key)) == a.bytes)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
