import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The eviction order's single pass over the records (`EvictionOrder.Ranking`, ADR draft C-22 cycle 6): a blob is a
/// candidate only when every record holding it is evictable, whichever of them the pass meets first, it lists every
/// holder, and equal access times and sizes fall back to the blob key, extension included (R-CLN-4, R-SYN-1, C-1).
@Suite("Cleanup: the eviction order (R-CLN-4, R-SYN-1)")
struct EvictionOrderTests {
    @Test("R-CLN-4: a blob several records share is a candidate only when all of them are evictable, whichever the order of the records", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func sharedBlobNeedsEveryHolderEvictable() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)))
        // Sixteen blobs of three records each. In the first eight one record is pinned, a different one in each, so the
        // pass meets the pinned record first in some and after an evictable one in others (records are a dictionary).
        let blobs = (0..<16).map { CoreFixture.bytes(1_500 + UInt64($0), count: 100) }
        let groups = blobs.enumerated().map { index, bytes in
            (0..<3).map { CoreFixture.entry("g\(index).\($0)", bytes) }
        }
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(groups.flatMap { $0 }), etag: nil, eviction: nil)
        for (index, group) in groups.enumerated() {
            try await harness.publish(blobs[index], group, sequence: UInt32(index + 1))
        }
        let pinned = Set((0..<8).map { groups[$0][$0 % 3].identifier })
        try await harness.store.setPinned(pinned, pinned: true)
        harness.time.advance(by: 3_600)
        let evictable = groups[8...].flatMap { $0 }
        let plan = try #require(await harness.store.evictionPlan(toFree: 8 * 100, protecting: []))
        #expect(Set(plan.victims.map(\.id)) == Set(evictable.map(\.identifier)), "every record of the eight evictable blobs, nothing else")
        #expect(plan.victims.count == 24 && plan.bytes == 800)
        for index in 8..<16 {
            let named = plan.victims.filter { $0.blob == CoreFixture.key(blobs[index]) }
            #expect(named.map(\.id) == groups[index].map(\.identifier), "a blob's victims, in identifier order")
        }
        #expect(await harness.store.evictionPlan(toFree: 8 * 100 + 1, protecting: []) == nil, "no pinned blob is ever planned")
        let result = try await harness.store.evictIfNeeded()
        #expect(result == CleanupResult(bytesFreed: 800, filesRemoved: 8))
        for group in groups[..<8] {
            for entry in group {
                #expect(await harness.record(entry.identifier)?.referencedBlob != nil, "\(entry.identifier.rawValue) keeps its blob")
            }
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-SYN-1: blobs tied on access and size are evicted in key order, the extension deciding between the same bytes", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func tieFallsBackToTheKeyAndItsExtension() async throws {
        let harness = CoreHarness.cleanup()
        let bytes = CoreFixture.bytes(1_600, count: 100)
        let png = CoreFixture.entry("same.png", bytes, ext: "png")
        let jpg = CoreFixture.entry("same.jpg", bytes, ext: "jpg")
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([png, jpg]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [png], sequence: 1)
        try await harness.publish(bytes, [jpg], sequence: 2)
        harness.time.advance(by: 3_600)
        let records = await harness.state.core.records
        #expect(records[png.identifier]?.lastAccess == records[jpg.identifier]?.lastAccess, "the two tie on access")
        let plan = try #require(await harness.store.evictionPlan(toFree: 200, protecting: []))
        // Same hash, so `BlobKey` orders them by extension: "jpg" < "png".
        #expect(plan.victims.map(\.id) == [jpg.identifier, png.identifier])
        #expect(plan.victims.map(\.blob) == [CoreFixture.key(bytes, ext: "jpg"), CoreFixture.key(bytes, ext: "png")])
    }
}
