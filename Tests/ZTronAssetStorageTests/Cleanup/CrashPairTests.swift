import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Two-lifetime crash combinations (Stage 3 ruling S3C-8, S3-CRAS-04; adapted from the crash hunters'
/// `S3LegacyPairsProbe` and `S3PurgeAfterCrashProbe`): a kill at every boundary of legacy migration, then a power loss at
/// every boundary of the next lifetime, which migrates on (H-10, the S1-01 hazard: a lifetime building on a killed
/// process's unsynced namespace); and a crash at every boundary of a first sync that ends stamped, then an OS purge
/// between launches (R-CLN-7).
@Suite("Cleanup: a crash, then a power loss or an OS purge, before the next launch (R-STO-11, R-CLN-7)")
struct CrashPairTests {
    /// Each power-loss mode's kill points are cut into this many cases, every point in exactly one, so a case stays well
    /// inside its time limit under the Thread Sanitizer and on the simulator (ruling S3C-8: 187 s for the 48 cases of 24
    /// slices at load 20–45, without TSan).
    static let legacySlices = 64

    /// One lifetime of legacy migration: open, migrate every file, reap, durable flush, close; it stops at the crash.
    @available(macOS 15.0, iOS 18.0, *)
    static func legacyLifetime(_ harness: CoreHarness) async {
        do {
            _ = try await harness.store.open()
            _ = try await LegacyMigrationTests.migrateAll(harness, batch: 4)
            await harness.settleDeletions()
            try await harness.store.flush(.durable)
            await harness.store.close()
        } catch {
            // The crash: every call after it fails.
        }
    }

    /// The prior art's key as a lifetime left it, for the next one.
    @available(macOS 15.0, iOS 18.0, *)
    static func defaults(after previous: FakeLegacyDefaults) -> FakeLegacyDefaults {
        FakeLegacyDefaults(values: previous.string(forKey: CleanupFixture.legacyKey).map { [CleanupFixture.legacyKey: $0] } ?? [:])
    }

    @Test(
        "R-STO-11: a kill at every boundary of legacy migration, then a power loss at every boundary of the next lifetime, loses no verified legacy file",
        .serialized,
        .timeLimit(.minutes(1)),
        arguments: [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata], 0..<CrashPairTests.legacySlices
    )
    @available(macOS 15.0, iOS 18.0, *)
    func legacyKillThenPowerLoss(mode: CrashMode, slice: Int) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let disk = try LegacyFixture.disk(files)
        let clean = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"]))
        await CrashPairTests.legacyLifetime(clean)
        let total = clean.fileSystem.mutationCount
        #expect(total > slice, "premise: the migration mutates more than \(slice) times")
        var pairs = 0
        for point in stride(from: slice, to: total, by: CrashPairTests.legacySlices) {
            await Task.yield()
            try Task.checkCancellation()
            let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
            let first = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: defaults, crashBefore: point, mode: .processKill)
            await CrashPairTests.legacyLifetime(first)
            let killed = first.fileSystem.survivingDisk()
            // The next lifetime without a crash, to count its boundaries.
            let probe = CoreHarness.cleanup(disk: killed, legacy: CleanupFixture.legacyPolicy, defaults: CrashPairTests.defaults(after: defaults), time: first.time)
            await CrashPairTests.legacyLifetime(probe)
            let secondTotal = probe.fileSystem.mutationCount
            for secondPoint in 0...secondTotal {
                await Task.yield()
                try Task.checkCancellation()
                let label = "kill before \(point), \(mode) before \(secondPoint)"
                let secondDefaults = CrashPairTests.defaults(after: defaults)
                let second = CoreHarness.cleanup(
                    disk: killed,
                    legacy: CleanupFixture.legacyPolicy,
                    defaults: secondDefaults,
                    crashBefore: secondPoint < secondTotal ? secondPoint : nil,
                    mode: mode,
                    time: first.time
                )
                await CrashPairTests.legacyLifetime(second)
                let survivor = second.fileSystem.survivingDisk()
                // Every legacy file's verified bytes are still somewhere: in the legacy tree or as a blob.
                for entry in entries {
                    let bytes = try #require(files[LegacyFixture.relativePath(entry)])
                    let blobPath = CoreFixture.layout.blobURL(CoreFixture.key(bytes, ext: entry.fileExtension)).path
                    let legacyPath = CleanupFixture.legacyRoot.appendingPathComponent(LegacyFixture.relativePath(entry)).path
                    let kept = survivor.files[blobPath].map { Data($0) == bytes } == true || survivor.files[legacyPath].map { Data($0) == bytes } == true
                    #expect(kept, "\(label): \(entry.identifier.rawValue)'s verified bytes were lost")
                }
                let reopened = CoreHarness.cleanup(disk: survivor, legacy: CleanupFixture.legacyPolicy, defaults: secondDefaults, time: first.time)
                _ = try await reopened.store.open()
                let violations = await CoreInvariants.violations(of: reopened, allowNeedsHeal: true)
                #expect(violations.isEmpty, "\(label): \(violations)")
                let progress = try await LegacyMigrationTests.migrateAll(reopened, batch: 4)
                #expect(progress.finished, "\(label): the migration finishes: \(progress)")
                let after = await CoreInvariants.violations(of: reopened, allowNeedsHeal: true)
                #expect(after.isEmpty, "\(label), after the migration finished: \(after)")
                await reopened.store.close()
                pairs += 1
            }
        }
        #expect(pairs > 0, "premise: the slice holds at least one kill point")
        print("R-STO-11 legacy kill → \(mode), slice \(slice): \(pairs) pairs")
    }

    /// What an OS purge removes between two launches (SPEC 7.3: `blobs/`, the root, half the blobs; and staging).
    enum OSPurge: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case blobs, root, half, staging

        var testDescription: String {
            self.rawValue
        }
    }

    /// `FirstSync.run` (WP-B's first sync) ending with the engine's stamp before its durable flush; whether the stamp
    /// survives the crash `mode`: its commit returned (a kill keeps what was written), or for a power loss the durable
    /// flush after it returned.
    @available(macOS 15.0, iOS 18.0, *)
    static func syncThenStamp(_ harness: CoreHarness, mode: CrashMode) async -> Bool {
        var persisted = false
        do {
            let store = harness.store
            _ = try await store.open()
            _ = try await store.apply(FirstSync.manifest, etag: ETag(rawValue: "\"v1\""), eviction: nil)
            for (index, asset) in FirstSync.assets.enumerated() {
                let staged = try await harness.stage(asset.bytes, for: asset.entries[0], sequence: UInt32(index + 1), sidecar: asset.sidecar)
                _ = try await store.publish(staged, binding: asset.entries.map(\.identifier), expecting: asset.entries[0].contentIdentity, urgency: .bulk)
            }
            _ = await store.runDueWork()
            let stamp = SyncStamp(appVersion: "1.0", completedAt: harness.time.now(), manifestETag: ETag(rawValue: "\"v1\""), manifestDigest: FirstSync.manifest.digest)
            try await store.markSynced(stamp, ifPurgeEpoch: await store.state.core.purgeEpoch)
            persisted = mode == .processKill || mode == .processKillTornWrite
            try await store.flush(.durable)
            persisted = true
            await store.close()
        } catch {
            // The crash: every call after it fails.
        }
        return persisted
    }

    /// The hunters' probe could not fail its "no stale synced claim" check: `FirstSync` never stamps. Here the run ends
    /// stamped, so a crash after the stamp's commit leaves a persisted claim, and an OS purge that loses a blob must reset
    /// it (R-CLN-7).
    @Test(
        "R-CLN-7: a crash at every boundary of a stamped first sync, then an OS purge between launches, heals without a stale synced claim",
        .serialized,
        .timeLimit(.minutes(1)),
        arguments: [CrashMode.processKill, .powerLossDropUnsynced], OSPurge.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func osPurgeAfterCrash(mode: CrashMode, purge: OSPurge) async throws {
        let clean = CoreHarness.make()
        #expect(await CrashPairTests.syncThenStamp(clean, mode: mode), "premise: the run stamps")
        let total = clean.fileSystem.mutationCount
        var stampedThenLost = 0
        for point in 0..<total {
            await Task.yield()
            try Task.checkCancellation()
            let label = "\(mode) before \(point), purge \(purge)"
            let harness = CoreHarness.make(crashBefore: point, mode: mode)
            let stamped = await CrashPairTests.syncThenStamp(harness, mode: mode)
            var disk = harness.fileSystem.survivingDisk()
            let layout = CoreFixture.layout
            switch purge {
            case .blobs:
                disk.purge(layout.blobsDirectory.path)
            case .root:
                disk.purge(layout.root.path)
            case .half:
                let blobs = disk.files.keys.filter { $0.hasPrefix(layout.blobsDirectory.path + "/") }.sorted()
                for (index, path) in blobs.enumerated() where index % 2 == 0 {
                    disk.purge(path)
                }
            case .staging:
                disk.purge(layout.stagingDirectory.path)
            }
            let survivors = Set(disk.files.keys.filter { $0.hasPrefix(layout.blobsDirectory.path + "/") })
            let reopened = CoreHarness.make(disk: disk)
            let report: OpenReport
            do {
                report = try await reopened.store.open()
            } catch {
                Issue.record("\(label): open failed with \(error)")
                continue
            }
            let violations = await CoreInvariants.violations(of: reopened, allowNeedsHeal: true)
            #expect(violations.isEmpty, "\(label): \(violations)")
            let state = await reopened.state
            let healing = state.core.records.values.contains { record in
                if case .needsHeal = record.residency {
                    return true
                }
                return false
            }
            if healing {
                #expect(report.stamp == nil && report.syncDue, "\(label): a blob was lost, yet the store claims synced")
                if stamped {
                    stampedThenLost += 1
                }
            }
            // Converge: whatever survived is bound without a download.
            _ = try await reopened.store.apply(FirstSync.manifest, etag: nil, eviction: nil)
            for (index, asset) in FirstSync.assets.enumerated() {
                let key = CoreFixture.key(asset.bytes, ext: asset.entries[0].fileExtension)
                let missing = await asset.entries.asyncFilter { entry in
                    await reopened.record(entry.identifier)?.referencedBlob != CoreFixture.key(asset.bytes, ext: entry.fileExtension)
                }
                if survivors.contains(layout.blobURL(key).path), asset.entries.count == 1, asset.entries[0].checksum != nil {
                    #expect(missing.isEmpty, "\(label): \(asset.entries[0].identifier.rawValue)'s surviving blob was not bound")
                }
                guard !missing.isEmpty else {
                    continue
                }
                let staged = try await reopened.stage(asset.bytes, for: missing[0], sequence: UInt32(200 + index))
                _ = try await reopened.store.publish(staged, binding: missing.map(\.identifier), expecting: missing[0].contentIdentity, urgency: .bulk)
            }
            try await reopened.store.flush(.durable)
            for asset in FirstSync.assets {
                for entry in asset.entries {
                    let location = await reopened.store.location(for: entry.identifier, extensions: [], recordingAccess: false)
                    #expect(location.flatMap { reopened.content($0.url) } == asset.bytes, "\(label): \(entry.identifier.rawValue) did not converge")
                }
            }
            let after = await CoreInvariants.violations(of: reopened)
            #expect(after.isEmpty, "\(label), after convergence: \(after)")
            await reopened.store.close()
        }
        if mode == .processKill, purge == .blobs || purge == .half {
            #expect(stampedThenLost > 0, "premise: some kill left a persisted stamp over a blob the purge then removed")
        }
        print("R-CLN-7 \(mode), purge \(purge): \(total) crash points, \(stampedThenLost) stamped then lost a blob")
    }
}
