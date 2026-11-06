import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Stage 3 stability probes (lens "stability"; S3-STAB-02): the check-then-act poll of S3-STAB-01 in other Storage tests.
///
/// Each test below holds a store operation on a `SteppedBlockingExecutor` and polls "condition reached? otherwise release
/// the oldest held unit". The condition and `heldUnits` are two separate reads (a synchronous read of the fake volume, or
/// a hop to the store actor, then a hop to the executor actor). A round whose condition read happens before the unit
/// released by the previous round ran, and whose `heldUnits` read happens after that unit ran and the store submitted
/// its next unit, releases that next unit: the operation goes one unit past the point the test meant to stop it at.
/// Each probe replays that schedule deterministically (it waits where the poll races) and then runs the original
/// test's code and oracle unchanged; the oracle fails. `PurgeTests.untilPurgeReturnsOrWaits` already reads `heldUnits`
/// before its condition, which closes the window.
@Suite("S3 stability probes: check-then-act polls (R-CLN-2, R-CLN-4, R-CLN-12)")
struct S3StabilityPollProbes {
    /// The poll's rounds up to the one whose release makes `reached` hold, each followed by a wait for the next held unit
    /// (so the released unit has run); then the losing round, which read `reached` before that unit ran and `heldUnits`
    /// after the store submitted its next unit, releases that next unit. Returns the unit the losing round released.
    @available(macOS 15.0, iOS 18.0, *)
    static func losingRound(_ executor: SteppedBlockingExecutor, until reached: () async -> Bool) async throws -> Int {
        try await executor.requireHeldUnits(atLeast: 1)
        var staleRead = await reached()
        while !(await reached()) {
            staleRead = await reached()
            let unit = try #require(await executor.heldUnits.first)
            await executor.release(unit)
            try await executor.requireHeldUnits(atLeast: 1)
        }
        #expect(!staleRead, "the losing round's condition read predates the last released unit's run")
        let next = try #require(await executor.heldUnits.first)
        await executor.release(next)
        return next
    }

    /// Replays `EvictionTests.chunkYieldRevalidates` (EvictionTests.swift:50-86) under the losing schedule of its poll
    /// (`:64-72`): the poll releases the no-op unit eviction yields in after its first chunk, so the second chunk (y2, y3)
    /// is evicted before the test reads y2 and leases y3.
    @Test("R-CLN-4: (S3-STAB-02) chunkYieldRevalidates' poll stops eviction at its first chunk's yield whatever the schedule", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictionChunkYieldReplay() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(100)), metadata: metadata)
        let assets = (0..<6).map { CleanupFixture.asset("y\($0)", seed: 790 + UInt64($0), count: 100) }
        try await EvictionTests.seedWithAccesses(harness, assets, recent: assets.map(\.id))
        await harness.store.testSetEvictionChunk(2)
        await metadata.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        _ = try await S3StabilityPollProbes.losingRound(metadata) {
            await harness.record(assets[1].id)?.residency == .absent(.evicted)
        }
        // The poll's next round: y1 is evicted and a unit is held, so it returns. The original test's oracle follows.
        try await metadata.requireHeldUnits(atLeast: 1)
        #expect(await harness.isPresent(assets[2].id, at: assets[2].key), "nothing after the chunk is marked yet")
        await metadata.setHolding(false)
        _ = try? await eviction.value
    }

    /// Replays `IdempotencyTests.cancelledCollection(operation: .stagingGC)` (IdempotencyTests.swift:104-170) under the
    /// losing schedule of its poll (`:140-148`): the poll releases the second removal unit, the third is submitted before
    /// the test cancels, and the cancelled collection has removed every file.
    @Test("R-CLN-12: (S3-STAB-02) cancelledCollection's poll leaves a staged file for the next run whatever the schedule", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func cancelledStagingCollectionReplay() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(deletionBatchSize: 1, metadata: metadata)
        _ = try await harness.store.open()
        var garbage: [URL] = []
        for index in 0..<3 {
            let name = try await GarbageCollectionTests.stage(harness, CleanupFixture.asset("s\(index)", seed: 610 + UInt64(index)).entry, bytes: 50, sequence: UInt32(index + 1))
            garbage.append(harness.layout.stagingURL(name))
        }
        harness.time.advance(by: 2 * 3_600)
        await metadata.setHolding(true)
        let task = Task { () throws -> CleanupResult in
            try await harness.store.collectStaging(keeping: [])
        }
        _ = try await S3StabilityPollProbes.losingRound(metadata) {
            garbage.contains { !harness.exists($0) }
        }
        // The released unit removes the second file and the collection submits its third removal before the test cancels.
        try await metadata.requireHeldUnits(atLeast: 1)
        task.cancel()
        await metadata.setHolding(false)
        let outcome = await task.result
        let remaining = garbage.filter { harness.exists($0) }
        #expect(throws: StoreError.cancelled) {
            try outcome.get()
        }
        #expect(remaining.count < garbage.count && !remaining.isEmpty, "the unit that ran stays done, the rest is left")
    }

    /// Replays `GarbageCollectionTests.sweepChunksReleaseActor` (GarbageCollectionTests.swift:568-620) under the losing
    /// schedule of its first poll (`:588-596`): the poll releases the unit the sweep yields in after its first chunk, so
    /// the second chunk is doomed before the test reads the table.
    @Test("R-CLN-2: (S3-STAB-02) sweepChunksReleaseActor's poll stops the sweep after its first chunk whatever the schedule", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func sweepChunkReplay() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        let planted = try (0..<3).map { try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(490 + UInt64($0), count: 100)) }.sorted()
        harness.time.advance(by: 3_601)
        await harness.store.testSetCleanupChunk(1)
        let listings = 1 + Set(planted.map(\.hash.fanOut)).count
        let mark = harness.fileSystem.operations.count
        await metadata.setHolding(true)
        let run = Task {
            try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        }
        _ = try await S3StabilityPollProbes.losingRound(metadata) {
            harness.fileSystem.operations.dropFirst(mark).filter { $0.kind == .contentsOfDirectory }.count == listings
        }
        // The original test's second poll and its oracle.
        try await CorePoll.until("the sweep released the actor, or dooming every orphan in one turn") {
            let doomedLast = await harness.state.core.blobTable[planted[2]] != nil
            return !(await metadata.heldUnits.isEmpty) || doomedLast
        }
        let held = Set(await metadata.heldUnits)
        let table = await harness.state.core.blobTable
        #expect(!held.isEmpty && table[planted[0]] != nil && table[planted[1]] == nil && table[planted[2]] == nil, "one chunk doomed, then the actor is free")
        await metadata.setHolding(false)
        _ = try? await run.value
    }
}
