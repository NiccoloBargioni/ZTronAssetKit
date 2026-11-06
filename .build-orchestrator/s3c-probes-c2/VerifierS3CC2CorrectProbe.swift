import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Verifier probes (Stage 3 WP-C close-out, cycle 2, correctness lens). Not for commit.
///
/// Variations of the cycle-1 defect (a turn trusting the blob table's reference count): the holder that leaves is not
/// the last one, the id bound in its place is an ordinary id pinned in the same window (not an essential one), the
/// window is after the first or the second turn, and the two "count changes" controls (a holder leaves alone; a holder
/// leaves and an ordinary id is bound) that must let the evictable purge finish the blob.
@Suite("Verifier s3c c2 correctness probes", .serialized)
struct VerifierS3CC2CorrectProbe {
    /// `shared` without the holder at `leaving`, plus `w9` with the shared bytes (ordinary or essential), when `bind`.
    @available(macOS 15.0, iOS 18.0, *)
    static func manifest(_ shared: [CleanupFixture.Asset], leaving: Int, bind: Bool, essential: Bool = false) -> ValidatedManifest {
        var entries = shared.map(\.entry)
        entries.remove(at: leaving)
        if bind {
            var bound = CoreFixture.entry("w9", shared[0].bytes)
            if essential {
                bound.policy = .essential
            }
            entries.append(bound)
        }
        return CoreFixture.manifest(entries)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func ids(_ harness: CoreHarness, _ assets: [CleanupFixture.Asset], _ residency: Residency) async -> [String] {
        let records = await harness.state.core.records
        return assets.filter { records[$0.id]?.residency == residency }.map(\.id.rawValue)
    }

    actor Flag {
        var value = false
        func set() {
            self.value = true
        }
    }

    /// Lets a purge finish: whenever it waits for the grace (it doomed a blob), advance past the grace.
    @available(macOS 15.0, iOS 18.0, *)
    static func finish(_ harness: CoreHarness, _ purge: Task<PurgeResult, any Error>) async throws -> PurgeResult {
        let flag = Flag()
        let watcher = Task {
            _ = try? await purge.value
            await flag.set()
        }
        while !(await flag.value) {
            try Task.checkCancellation()
            if harness.time.pendingSleepers > 0 {
                harness.time.advance(by: harness.configuration.policy.deletionGrace)
            }
            await Task.yield()
        }
        _ = await watcher.value
        return try await purge.value
    }

    /// Q0. Before the evictable purge's first turn (bulk unit held, chunk 2): w1 (in the FIRST chunk) leaves and w9, an
    /// ordinary id, is bound and pinned. Count unchanged (6). The blob must be kept whole.
    @Test("probe Q0: evictable purge, first-chunk holder swapped for a pinned id before the first turn", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func q0() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(bulk: bulk)
        let shared = try await LargeBlobTests.seedShared(harness, count: 6, seed: 2_600)
        let key = shared[0].key
        await harness.store.testSetCleanupChunk(2)
        await bulk.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let held = Set(await bulk.heldUnits)
        let applied = try await CleanupSteps.run(bulk, keeping: held) {
            let applied = try await harness.store.apply(VerifierS3CC2CorrectProbe.manifest(shared, leaving: 1, bind: true), etag: nil, eviction: nil)
            try await harness.store.setPinned(["w9"], pinned: true)
            return applied
        }.value
        let references = await LargeBlobTests.references(harness, key)
        await bulk.setHolding(false)
        let result = try await VerifierS3CC2CorrectProbe.finish(harness, purge)
        let purged = await VerifierS3CC2CorrectProbe.ids(harness, shared, .absent(.purged))

        #expect(applied.pruned == ["w1"] && applied.reused == ["w9"], "premise: \(applied)")
        #expect(references == 6, "premise: count unchanged")
        #expect(await harness.record("w9")?.pinned == true, "premise: w9 pinned")
        #expect(purged.isEmpty, "blob kept whole; purged \(purged), \(result)")
        #expect(result.assetsRemoved == 0)
        #expect(await LargeBlobTests.references(harness, key) == 6)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Q1. Between the evictable purge's turns (chunk 2, six holders): w2 (the NEXT turn's first id) leaves and w9, an
    /// ordinary id, is bound and pinned. Count unchanged (4). The purge must stop with w0, w1 purged.
    @Test("probe Q1: evictable purge, next-chunk holder swapped for a pinned id between turns", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func q1() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 6, seed: 2_601)
        let key = shared[0].key
        await harness.store.testSetCleanupChunk(2)
        await metadata.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        let first = try await LargeBlobTests.atNextYield(metadata, "first chunk purged") {
            await LargeBlobTests.count(harness, shared, .absent(.purged)) > 0
        } observe: {
            await LargeBlobTests.count(harness, shared, .absent(.purged))
        }
        let held = Set(await metadata.heldUnits)
        let applied = try await CleanupSteps.run(metadata, keeping: held) {
            let applied = try await harness.store.apply(VerifierS3CC2CorrectProbe.manifest(shared, leaving: 2, bind: true), etag: nil, eviction: nil)
            try await harness.store.setPinned(["w9"], pinned: true)
            return applied
        }.value
        let references = await LargeBlobTests.references(harness, key)
        await metadata.setHolding(false)
        let result = try await VerifierS3CC2CorrectProbe.finish(harness, purge)
        let purged = await VerifierS3CC2CorrectProbe.ids(harness, shared, .absent(.purged))

        #expect(first == 2, "premise: one chunk before the swap")
        #expect(applied.pruned == ["w2"] && applied.reused == ["w9"], "premise: \(applied)")
        #expect(references == 4, "premise: count unchanged by the swap")
        #expect(purged == ["w0", "w1"], "stops at the swap; purged \(purged), \(result)")
        #expect(result == PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 2))
        for id in ["w3", "w4", "w5", "w9"] {
            #expect(await harness.isPresent(AssetID(rawValue: id), at: key), "\(id) keeps the blob")
        }
        #expect(await LargeBlobTests.references(harness, key) == 4)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Q2. Between quota eviction's turns (chunk 2, seven holders), after turn 1 or turn 2: w6 (the LAST victim) leaves
    /// and w9, an ordinary id, is bound and pinned. Count unchanged. Eviction must stop at the window.
    @Test("probe Q2: quota eviction, last victim swapped for a pinned id between turns", .timeLimit(.minutes(1)), arguments: [1, 2])
    @available(macOS 15.0, iOS 18.0, *)
    func q2(afterTurn: Int) async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)), metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 7, seed: 2_602)
        let key = shared[0].key
        await harness.store.testSetEvictionChunk(2)
        await metadata.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        var taken = try await LargeBlobTests.atNextYield(metadata, "turn 1") {
            await LargeBlobTests.count(harness, shared, .absent(.evicted)) > 0
        } observe: {
            await LargeBlobTests.count(harness, shared, .absent(.evicted))
        }
        if afterTurn == 2 {
            await metadata.release(try #require(await metadata.heldUnits.first))
            taken = try await LargeBlobTests.atNextYield(metadata, "turn 2") {
                await LargeBlobTests.count(harness, shared, .absent(.evicted)) > 2
            } observe: {
                await LargeBlobTests.count(harness, shared, .absent(.evicted))
            }
        }
        let held = Set(await metadata.heldUnits)
        let before = await LargeBlobTests.references(harness, key)
        let applied = try await CleanupSteps.run(metadata, keeping: held) {
            let applied = try await harness.store.apply(VerifierS3CC2CorrectProbe.manifest(shared, leaving: 6, bind: true), etag: nil, eviction: nil)
            try await harness.store.setPinned(["w9"], pinned: true)
            return applied
        }.value
        let after = await LargeBlobTests.references(harness, key)
        await metadata.setHolding(false)
        let result = try await eviction.value
        let evicted = await VerifierS3CC2CorrectProbe.ids(harness, shared, .absent(.evicted))

        #expect(taken == 2 * afterTurn, "premise: \(taken) evicted before the swap")
        #expect(applied.pruned == ["w6"] && applied.reused == ["w9"], "premise: \(applied)")
        #expect(before == after, "premise: count unchanged (\(String(describing: before)) -> \(String(describing: after)))")
        #expect(evicted.count == 2 * afterTurn, "after turn \(afterTurn): eviction stops at the window; evicted \(evicted), \(result)")
        #expect(result == CleanupResult(), "nothing released")
        #expect(await harness.isPresent("w9", at: key))
        #expect(await LargeBlobTests.references(harness, key) == 7 - 2 * afterTurn)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Q3. Control: between the evictable purge's turns, w3 leaves alone (count drops). The purge reads the holders again
    /// and finishes the blob: five records purged, the blob reaped.
    @Test("probe Q3: evictable purge, a holder leaves between turns, the rest still purged", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func q3() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 6, seed: 2_603)
        let key = shared[0].key
        await harness.store.testSetCleanupChunk(2)
        await metadata.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        _ = try await LargeBlobTests.atNextYield(metadata, "first chunk purged") {
            await LargeBlobTests.count(harness, shared, .absent(.purged)) > 0
        } observe: {
            await LargeBlobTests.count(harness, shared, .absent(.purged))
        }
        let held = Set(await metadata.heldUnits)
        let applied = try await CleanupSteps.run(metadata, keeping: held) {
            try await harness.store.apply(VerifierS3CC2CorrectProbe.manifest(shared, leaving: 3, bind: false), etag: nil, eviction: nil)
        }.value
        await metadata.setHolding(false)
        let result = try await VerifierS3CC2CorrectProbe.finish(harness, purge)
        let purged = await VerifierS3CC2CorrectProbe.ids(harness, shared, .absent(.purged))

        #expect(applied.pruned == ["w3"], "premise: \(applied)")
        #expect(purged == ["w0", "w1", "w2", "w4", "w5"], "purged \(purged), \(result)")
        #expect(result == PurgeResult(bytesFreed: 100, bytesDeferred: 0, assetsRemoved: 5))
        #expect(!harness.hasBlob(key))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Q4. Between the evictable purge's turns, w5 (the LAST holder) leaves and w9, an ordinary id, is bound (count
    /// unchanged). `.evictable` takes every current holder (`purgeChunk`'s rule): w9 is purged too and the blob is reaped.
    @Test("probe Q4: evictable purge, last holder swapped for an ordinary id between turns, every holder purged", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func q4() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 6, seed: 2_604)
        let key = shared[0].key
        await harness.store.testSetCleanupChunk(2)
        await metadata.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        _ = try await LargeBlobTests.atNextYield(metadata, "first chunk purged") {
            await LargeBlobTests.count(harness, shared, .absent(.purged)) > 0
        } observe: {
            await LargeBlobTests.count(harness, shared, .absent(.purged))
        }
        let held = Set(await metadata.heldUnits)
        let applied = try await CleanupSteps.run(metadata, keeping: held) {
            try await harness.store.apply(VerifierS3CC2CorrectProbe.manifest(shared, leaving: 5, bind: true), etag: nil, eviction: nil)
        }.value
        let references = await LargeBlobTests.references(harness, key)
        await metadata.setHolding(false)
        let result = try await VerifierS3CC2CorrectProbe.finish(harness, purge)
        let purged = await VerifierS3CC2CorrectProbe.ids(harness, shared, .absent(.purged))

        #expect(applied.pruned == ["w5"] && applied.reused == ["w9"], "premise: \(applied)")
        #expect(references == 4, "premise: count unchanged")
        #expect(purged == ["w0", "w1", "w2", "w3", "w4"], "purged \(purged), \(result)")
        #expect(await harness.record("w9")?.residency == .absent(.purged), "w9 purged with the other holders")
        #expect(result == PurgeResult(bytesFreed: 100, bytesDeferred: 0, assetsRemoved: 6))
        #expect(!harness.hasBlob(key))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
    /// Q5 (hunt: two operations across turns on one blob). Quota eviction takes w0, w1 and parks between its turns; an
    /// evictable purge then selects the blob, reads its holders again in its first turn (w0 and w1 left it) and takes
    /// w2, w3, parking between its turns; eviction resumes (its victims left are no longer the holders: it stops,
    /// releasing nothing), then the purge finishes the blob. Every record leaves exactly once, the blob is doomed and
    /// reaped once, and the bytes are released once (by the purge).
    @Test("probe Q5: quota eviction and an evictable purge interleaved across the turns of one blob", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func q5() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)), metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 6, seed: 2_605)
        let key = shared[0].key
        await harness.store.testSetEvictionChunk(2)
        await harness.store.testSetCleanupChunk(2)
        await metadata.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        let evictedFirst = try await LargeBlobTests.atNextYield(metadata, "eviction's first turn") {
            await LargeBlobTests.count(harness, shared, .absent(.evicted)) > 0
        } observe: {
            await LargeBlobTests.count(harness, shared, .absent(.evicted))
        }
        let evictionUnits = Set(await metadata.heldUnits)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        _ = try await CorePoll.releasing(metadata, .allExcept(evictionUnits), until: "the purge's first turn") {
            await LargeBlobTests.count(harness, shared, .absent(.purged)) > 0
        }
        try await metadata.requireHeldUnits(atLeast: evictionUnits.count + 1)
        let purgedFirst = await VerifierS3CC2CorrectProbe.ids(harness, shared, .absent(.purged))
        let releasedBefore = await harness.state.eviction.releasedBytes
        // Resume the eviction first (its unit is the older one), keep the purge parked.
        let purgeUnits = Set(await metadata.heldUnits).subtracting(evictionUnits)
        let evictionResult = try await CleanupSteps.run(metadata, keeping: purgeUnits) {
            try await eviction.value
        }.value
        let evictedAfter = await VerifierS3CC2CorrectProbe.ids(harness, shared, .absent(.evicted))
        await metadata.setHolding(false)
        let purgeResult = try await VerifierS3CC2CorrectProbe.finish(harness, purge)
        let purged = await VerifierS3CC2CorrectProbe.ids(harness, shared, .absent(.purged))
        let releasedAfter = await harness.state.eviction.releasedBytes

        #expect(evictedFirst == 2, "premise")
        #expect(purgedFirst == ["w2", "w3"], "premise: purge's first turn re-read the holders: \(purgedFirst)")
        #expect(evictedAfter == ["w0", "w1"], "eviction stops: \(evictedAfter), \(evictionResult)")
        #expect(evictionResult == CleanupResult(), "eviction released nothing: \(evictionResult)")
        #expect(purged == ["w2", "w3", "w4", "w5"], "purged \(purged)")
        #expect(purgeResult == PurgeResult(bytesFreed: 100, bytesDeferred: 0, assetsRemoved: 4), "\(purgeResult)")
        #expect(!harness.hasBlob(key))
        print("Q5 releasedBytes before \(releasedBefore) after \(releasedAfter); metrics evictions \(await harness.state.core.metrics.evictions)")
        #expect(await harness.state.core.metrics.evictions == 2)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}

