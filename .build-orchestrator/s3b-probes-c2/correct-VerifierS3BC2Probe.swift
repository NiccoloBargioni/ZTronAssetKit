import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// VERIFIER SCRATCH ONLY (Stage 3 WP-B close-out cycle 2, correctness lens). Not for commit.
@Suite("VerifierS3BC2Probe")
struct VerifierS3BC2Probe {
    /// Cycle-1 blocking defect, own variant: a three-way rotation of content among present assets in one `apply` while
    /// quota eviction waits in its candidates unit. One adoption dooms a blob (counted) and a later one rescues it.
    @Test("PROBE rotation: R-CLN-4 three-way content rotation during eviction candidates frees what was measured", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func rotationWhileEvictionCandidatesRun() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        let before = try await harness.store.freeSpace()
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        let releasedBefore = await harness.state.eviction.releasedBytes
        var entries = EvictionOverlapTests.assets.map(\.entry)
        let (c7, c8, c9) = (entries[7].checksum, entries[8].checksum, entries[9].checksum)
        entries[7].checksum = c8
        entries[8].checksum = c9
        entries[9].checksum = c7
        let rotated = entries
        let report = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(rotated, etagSeed: "rotated"), etag: nil, eviction: nil)
        }.value
        let delta = await harness.state.eviction.releasedBytes - releasedBefore
        let usedMid = try await harness.store.freeSpace().usedBytes
        print("PROBE rotation: reused=\(report.reused.map(\.rawValue).sorted()) releasedBytes delta=\(delta) used=\(usedMid) (before \(before.usedBytes))")
        #expect(usedMid == before.usedBytes)
        #expect(delta == 0, "nothing left usedBytes")
        await bulk.setHolding(false)
        let result = try await maintenance.value
        let evicted = await EvictionOverlapTests.evicted(harness)
        let usedAfter = try await harness.store.freeSpace().usedBytes
        print("PROBE rotation: result=\(result) evicted=\(evicted) used after=\(usedAfter)")
        #expect(result == CleanupResult(bytesFreed: 600, filesRemoved: 6))
        #expect(usedAfter <= 450, "down to the hysteresis target")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// The take-back's second claim: an eviction that measured AFTER a counted doom frees the bytes again when a later
    /// apply rescues them while it awaits (the prune runs before the measurement).
    @Test("PROBE measure-after-doom: R-CLN-4 bytes pruned before the measurement and adopted back during candidates are freed again", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func pruneBeforeMeasureThenReadopt() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        let all = EvictionOverlapTests.assets.map(\.entry)
        _ = try await harness.store.apply(CoreFixture.manifest(Array(all.prefix(9)), etagSeed: "pruned"), etag: nil, eviction: nil)
        #expect(try await harness.store.freeSpace().usedBytes == 900)
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        let releasedBefore = await harness.state.eviction.releasedBytes
        let readopted = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(all, etagSeed: "listed again"), etag: nil, eviction: nil)
        }.value
        let delta = await harness.state.eviction.releasedBytes - releasedBefore
        print("PROBE measure-after-doom: reused=\(readopted.reused.map(\.rawValue)) releasedBytes delta=\(delta)")
        #expect(readopted.reused == [EvictionOverlapTests.assets[9].id])
        await bulk.setHolding(false)
        let result = try await maintenance.value
        let usedAfter = try await harness.store.freeSpace().usedBytes
        print("PROBE measure-after-doom: result=\(result) evicted=\(await EvictionOverlapTests.evicted(harness)) used after=\(usedAfter)")
        #expect(usedAfter <= 450, "down to the hysteresis target")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Residual hunt: two publications of one key that an apply's prune counted as released. The first rescues it
    /// (count taken back), the second reuses it; both bind nothing. The key ends doomed again (its bytes left usedBytes),
    /// so the count should be back.
    @Test("PROBE two-abandoned-publications: the count returns when the key is doomed again", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func twoAbandonedPublicationsRestoreTheCount() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(181, count: 120)
        let size = Int64(bytes.count)
        let key = CoreFixture.key(bytes)
        let a = CoreFixture.entry("a", bytes)
        let b = CoreFixture.entry("b", CoreFixture.bytes(182))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, b]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a])
        let start = await harness.state.eviction.releasedBytes
        _ = try await harness.store.apply(CoreFixture.manifest([b]), etag: nil, eviction: nil)
        #expect(await harness.state.eviction.releasedBytes == start + size)
        let first = try await harness.store.acquireReference(key)
        let second = try await harness.store.acquireReference(key)
        print("PROBE two-abandoned: first=\(first) second=\(second) released=\(await harness.state.eviction.releasedBytes - start)")
        await harness.store.abandonAcquisition(key, first)
        await harness.store.abandonAcquisition(key, second)
        let table = await harness.state.core.blobTable[key]
        let released = await harness.state.eviction.releasedBytes - start
        let used = try await harness.store.freeSpace().usedBytes
        print("PROBE two-abandoned: after both abandon: blob=\(String(describing: table)) released delta=\(released) used=\(used) counted=\(await harness.state.core.countedReleases)")
        guard case .doomed? = table else {
            Issue.record("the key is doomed again")
            return
        }
        #expect(released == size, "the bytes left usedBytes again, so the count should stand")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
        await harness.store.close()
    }
}
