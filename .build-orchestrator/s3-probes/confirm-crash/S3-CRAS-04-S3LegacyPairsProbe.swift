import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// S3 probe (lens crash, H-10): a kill at every boundary of legacy migration, then a second lifetime that migrates on
/// and loses power at every one of its boundaries (the shipped legacy enumeration crashes once per scenario only).
@Suite("S3 probe: legacy migration kill then power loss", .serialized)
struct S3LegacyPairsProbe {
    static let slices = 24

    @available(macOS 15.0, iOS 18.0, *)
    static func lifetime(_ harness: CoreHarness) async -> UInt64 {
        var committed: UInt64 = 0
        do {
            _ = try await harness.store.open()
            committed = await harness.state.core.committedGeneration
            _ = try await LegacyMigrationTests.migrateAll(harness, batch: 4)
            committed = await harness.state.core.committedGeneration
            await harness.settleDeletions()
            try await harness.store.flush(.durable)
            committed = await harness.state.core.committedGeneration
            await harness.store.close()
        } catch {
            // The crash.
        }
        return committed
    }

    @Test(
        "R-STO-11: a kill at every boundary of legacy migration, then a power loss at every boundary of the next lifetime, loses no verified legacy file",
        .timeLimit(.minutes(1)),
        arguments: [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata], 0..<S3LegacyPairsProbe.slices
    )
    @available(macOS 15.0, iOS 18.0, *)
    func killThenPowerLoss(mode: CrashMode, slice: Int) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let entries = try LegacyFixture.entries()
        let disk = try LegacyFixture.disk(files)
        let clean = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"]))
        _ = await S3LegacyPairsProbe.lifetime(clean)
        let total = clean.fileSystem.mutationCount
        var pairs = 0
        for point in stride(from: slice, to: total, by: S3LegacyPairsProbe.slices) {
            await Task.yield()
            let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
            let first = CoreHarness.cleanup(disk: disk, legacy: CleanupFixture.legacyPolicy, defaults: defaults, crashBefore: point, mode: .processKill)
            _ = await S3LegacyPairsProbe.lifetime(first)
            let killed = first.fileSystem.survivingDisk()
            let probeDefaults = FakeLegacyDefaults(values: defaults.string(forKey: CleanupFixture.legacyKey).map { [CleanupFixture.legacyKey: $0] } ?? [:])
            let probe = CoreHarness.cleanup(disk: killed, legacy: CleanupFixture.legacyPolicy, defaults: probeDefaults, time: first.time)
            _ = await S3LegacyPairsProbe.lifetime(probe)
            let secondTotal = probe.fileSystem.mutationCount
            for secondPoint in 0...secondTotal {
                await Task.yield()
                let label = "kill before \(point), \(mode) before \(secondPoint)"
                let secondDefaults = FakeLegacyDefaults(values: defaults.string(forKey: CleanupFixture.legacyKey).map { [CleanupFixture.legacyKey: $0] } ?? [:])
                let second = CoreHarness.cleanup(
                    disk: killed,
                    legacy: CleanupFixture.legacyPolicy,
                    defaults: secondDefaults,
                    crashBefore: secondPoint < secondTotal ? secondPoint : nil,
                    mode: mode,
                    time: first.time
                )
                _ = await S3LegacyPairsProbe.lifetime(second)
                let survivor = second.fileSystem.survivingDisk()
                // Every legacy file's bytes are still somewhere: in the legacy tree or as a blob.
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
                _ = try await LegacyMigrationTests.migrateAll(reopened, batch: 4)
                await reopened.store.close()
                pairs += 1
            }
        }
        print("S3 legacy pairs \(mode) slice \(slice): \(pairs)")
    }
}
