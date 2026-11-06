import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Verifier probes (Stage 3 WP-C close-out, cycle 1, correctness lens). Not for commit.
///
/// The swap: one `apply` prunes w4 (a holder of the shared blob leaves it) and binds w9, an ESSENTIAL id with the same
/// bytes (a new holder), so the blob table's reference count is unchanged while the holders are not the selected ids.
@Suite("Verifier s3c c1 correctness probes", .serialized)
struct VerifierS3CC1CorrectProbe {
    @available(macOS 15.0, iOS 18.0, *)
    static func swapManifest(_ shared: [CleanupFixture.Asset]) -> ValidatedManifest {
        var essential = CoreFixture.entry("w9", shared[0].bytes)
        essential.policy = .essential
        return CoreFixture.manifest(shared.dropLast().map(\.entry) + [essential])
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func purgedIDs(_ harness: CoreHarness, _ shared: [CleanupFixture.Asset]) async -> [String] {
        let records = await harness.state.core.records
        return shared.filter { records[$0.id]?.residency == .absent(.purged) }.map(\.id.rawValue)
    }

    /// P1. The swap lands between the evictable purge's selection and its first turn. With the default chunk the blob is
    /// one `purgeChunk` group: its holders are read again, w9 is essential, and the blob is kept whole. With a chunk of 2
    /// it goes through `purgeAcrossTurns`, whose first turn is documented to check every holder "as purgeChunk does".
    @Test("probe P1: evictable purge, holders swapped before the first turn", .timeLimit(.minutes(1)), arguments: [1_000, 2])
    @available(macOS 15.0, iOS 18.0, *)
    func swapBeforeFirstTurn(chunk: Int) async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(bulk: bulk)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_560)
        let key = shared[0].key
        await harness.store.testSetCleanupChunk(chunk)
        await bulk.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let held = Set(await bulk.heldUnits)
        let applied = try await CleanupSteps.run(bulk, keeping: held) {
            try await harness.store.apply(VerifierS3CC1CorrectProbe.swapManifest(shared), etag: nil, eviction: nil)
        }.value
        let referencesAfterSwap = await LargeBlobTests.references(harness, key)
        await bulk.setHolding(false)
        let result = try await purge.value
        let purged = await VerifierS3CC1CorrectProbe.purgedIDs(harness, shared)

        #expect(applied.pruned == ["w4"] && applied.reused == ["w9"], "premise: the swap: \(applied)")
        #expect(referencesAfterSwap == 5, "premise: the reference count is unchanged by the swap")
        #expect(await harness.isPresent("w9", at: key), "premise: the essential id holds the blob")
        #expect(purged.isEmpty, "chunk \(chunk): an evictable purge keeps whole a blob an essential record holds; purged \(purged), \(result)")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// P2. The swap lands between two turns of an evictable purge (chunk 2). Documented: a later turn's holders are read
    /// again "when an id was bound to the blob or left it", and a holder that became unpurgeable stops the blob, "the rest
    /// keeping the blob".
    @Test("probe P2: evictable purge, holders swapped between turns", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func swapBetweenPurgeTurns() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_561)
        let key = shared[0].key
        await harness.store.testSetCleanupChunk(2)
        await metadata.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        let first = try await LargeBlobTests.atNextYield(metadata, "the first chunk of the blob's records is purged") {
            await LargeBlobTests.count(harness, shared, .absent(.purged)) > 0
        } observe: {
            await LargeBlobTests.count(harness, shared, .absent(.purged))
        }
        let held = Set(await metadata.heldUnits)
        let applied = try await CleanupSteps.run(metadata, keeping: held) {
            try await harness.store.apply(VerifierS3CC1CorrectProbe.swapManifest(shared), etag: nil, eviction: nil)
        }.value
        await metadata.setHolding(false)
        let result = try await purge.value
        let purged = await VerifierS3CC1CorrectProbe.purgedIDs(harness, shared)

        #expect(first == 2, "premise: one chunk purged before the swap")
        #expect(applied.pruned == ["w4"] && applied.reused == ["w9"], "premise: the swap: \(applied)")
        #expect(await harness.isPresent("w9", at: key), "premise: the essential id holds the blob")
        #expect(purged == ["w0", "w1"], "the purge stops at the changed holders, w2 and w3 keeping the blob; purged \(purged), \(result)")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// P3. The same swap between two turns of quota eviction (chunk 2). Documented (row s3c-1): each later turn checks
    /// that "exactly the victims not evicted yet hold it".
    @Test("probe P3: quota eviction, holders swapped between turns", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func swapBetweenEvictionTurns() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)), metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_562)
        let key = shared[0].key
        await harness.store.testSetEvictionChunk(2)
        await metadata.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        let first = try await LargeBlobTests.atNextYield(metadata, "the first chunk of the blob's records is evicted") {
            await LargeBlobTests.count(harness, shared, .absent(.evicted)) > 0
        } observe: {
            await LargeBlobTests.count(harness, shared, .absent(.evicted))
        }
        let held = Set(await metadata.heldUnits)
        let applied = try await CleanupSteps.run(metadata, keeping: held) {
            try await harness.store.apply(VerifierS3CC1CorrectProbe.swapManifest(shared), etag: nil, eviction: nil)
        }.value
        await metadata.setHolding(false)
        let result = try await eviction.value
        let evicted = await LargeBlobTests.count(harness, shared, .absent(.evicted))

        #expect(first == 2, "premise: one chunk evicted before the swap")
        #expect(applied.pruned == ["w4"] && applied.reused == ["w9"], "premise: the swap: \(applied)")
        #expect(await harness.isPresent("w9", at: key), "premise: the essential id holds the blob")
        #expect(evicted == 2, "eviction stops at the turn after the holders changed; evicted \(evicted), \(result)")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
