import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// `storageReport()` (R-CLN-9).
@Suite("Cleanup: storage report (R-CLN-9)")
struct StorageReportTests {
    @Test("R-CLN-9: storageReport sums bytes by kind and state with pinned, evictable, staging, orphan and free space", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func storageReport() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(10_000)))
        let plain = CleanupFixture.asset("plain", seed: 500, count: 300)
        let pinned = CleanupFixture.asset("pinned", seed: 501, count: 200, ext: "wav")
        let essential = CleanupFixture.asset("essential", seed: 502, count: 100, ext: "heic", policy: .essential)
        let stale = CleanupFixture.asset("stale", seed: 503, count: 150)
        let pruned = CleanupFixture.asset("pruned", seed: 504, count: 120)
        let unverifiedBytes = CoreFixture.bytes(505, count: 80)
        let unverified = CleanupFixture.Asset(entry: CoreFixture.entry("unverified", unverifiedBytes, checksum: false), bytes: unverifiedBytes)
        let all = [plain, pinned, essential, stale, pruned, unverified]
        try await harness.seed(all)
        try await harness.store.setPinned([pinned.id], pinned: true)
        // `stale` changes content (its old bytes are still served); `pruned` leaves the manifest (doomed, waiting).
        let newStale = CleanupFixture.asset("stale", seed: 506, count: 150)
        _ = try await harness.store.apply(CoreFixture.manifest([plain, pinned, essential, newStale, unverified].map(\.entry)), etag: nil, eviction: nil)
        _ = try await harness.stage(CoreFixture.bytes(507, count: 123), for: CleanupFixture.asset("staged", seed: 507).entry, sequence: 9)
        let gone = try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(508, count: 40))
        harness.time.advance(by: 3_601)
        let orphan = try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(509, count: 77))
        let swept = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(swept.filesRemoved == 1 && !harness.hasBlob(gone) && harness.hasBlob(orphan))
        let report = await harness.store.storageReport()
        #expect(report.bytesByKind == ["png": 300 + 150 + 80, "wav": 200, "heic": 100])
        #expect(report.bytesByState == ResidencyBytes(present: 300 + 200 + 100 + 80, stale: 150, pendingDeletion: 120))
        #expect(report.pinnedBytes == 200 && report.essentialBytes == 100)
        #expect(report.evictableBytes == 300 + 150 + 80)
        #expect(report.stagingBytes == 123)
        #expect(report.orphanBytes == 77)
        #expect(report.sourceCopyBytes == 0, "the engine adds the remote source's copies")
        #expect(report.budgetBytes == 10_000)
        #expect(report.freeBytesImportant == (try harness.fileSystem.availableCapacity(at: harness.layout.root, for: .important)))
        #expect(report.freeBytesOpportunistic == (try harness.fileSystem.availableCapacity(at: harness.layout.root, for: .opportunistic)))
        #expect(report.unverifiedCount == 1)
        #expect(report.lastCleanupAt == harness.time.now())
        let evictable = try #require(await harness.store.evictionPlan(toFree: 1, protecting: []))
        #expect(evictable.bytes <= report.evictableBytes)
    }

    @Test("R-CLN-9: storageReport before open reports an empty store and no free space", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func reportBeforeOpen() async throws {
        let harness = CoreHarness.cleanup()
        let report = await harness.store.storageReport()
        #expect(report.bytesByKind.isEmpty && report.bytesByState == ResidencyBytes(present: 0, stale: 0, pendingDeletion: 0))
        #expect(report.freeBytesImportant == 0 && report.stagingBytes == 0 && report.lastCleanupAt == nil)
        #expect(harness.fileSystem.operations.isEmpty, "a report never opens the store")
    }
}
