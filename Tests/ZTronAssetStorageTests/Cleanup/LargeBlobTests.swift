import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// A blob that more records share than a chunk holds (C2 at the reference scale; Stage 3 ruling S3C-2, S3-B-025): quota
/// eviction and purge take its records a chunk per actor turn instead of all in one, re-validating each chunk in its turn.
/// One blob that 10,000 ids share held the actor 15.4–16.6 ms in one turn (`BenchCleanup`'s shared-blob benchmark).
@Suite("Cleanup: a blob more records share than a chunk holds (C2, R-CLN-4, R-CLN-6)")
struct LargeBlobTests {
    /// One 100-byte blob that `count` records share, published and last accessed an hour ago.
    @available(macOS 15.0, iOS 18.0, *)
    static func seedShared(_ harness: CoreHarness, count: Int, seed: UInt64) async throws -> [CleanupFixture.Asset] {
        let bytes = CoreFixture.bytes(seed, count: 100)
        let shared = (0..<count).map { CleanupFixture.Asset(entry: CoreFixture.entry("w\($0)", bytes), bytes: bytes) }
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(shared.map(\.entry)), etag: nil, eviction: nil)
        try await harness.publish(bytes, shared.map(\.entry), urgency: .userInitiated, sequence: 1)
        try await harness.store.flush(.ordered)
        harness.time.advance(by: 3_600)
        return shared
    }

    /// How many of `assets` have `residency`.
    @available(macOS 15.0, iOS 18.0, *)
    static func count(_ harness: CoreHarness, _ assets: [CleanupFixture.Asset], _ residency: Residency) async -> Int {
        let records = await harness.state.core.records
        return assets.filter { records[$0.id]?.residency == residency }.count
    }

    /// The references the blob table counts for `key`, or `nil` when the blob is not live.
    @available(macOS 15.0, iOS 18.0, *)
    static func references(_ harness: CoreHarness, _ key: BlobKey) async -> Int? {
        guard case .live(let references)? = await harness.state.core.blobTable[key] else {
            return nil
        }
        return references
    }

    /// Lets units through until `ready` holds, then waits for the release of the actor that follows and reads `observe`.
    @available(macOS 15.0, iOS 18.0, *)
    static func atNextYield<T: Sendable>(
        _ metadata: SteppedBlockingExecutor,
        _ waitingFor: String,
        until ready: () async -> Bool,
        observe: () async -> T
    ) async throws -> T {
        try await CorePoll.releasing(metadata, until: waitingFor) {
            await ready()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        return await observe()
    }

    @Test("R-CLN-4: quota eviction takes a blob that more records share than a chunk holds one chunk of its records per actor turn", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictionSlicesTheBlob() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)), metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_500)
        let key = shared[0].key
        await harness.store.testSetEvictionChunk(2)
        await metadata.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        // Five records in chunks of two: two turns end with a release of the actor before the blob is gone.
        let first = try await LargeBlobTests.atNextYield(metadata, "the first chunk of the blob's records is evicted") {
            await LargeBlobTests.count(harness, shared, .absent(.evicted)) > 0
        } observe: {
            (await LargeBlobTests.count(harness, shared, .absent(.evicted)), await LargeBlobTests.references(harness, key))
        }
        await metadata.release(try #require(await metadata.heldUnits.first))
        let second = try await LargeBlobTests.atNextYield(metadata, "the second chunk of the blob's records is evicted") {
            await LargeBlobTests.count(harness, shared, .absent(.evicted)) > 2
        } observe: {
            (await LargeBlobTests.count(harness, shared, .absent(.evicted)), await LargeBlobTests.references(harness, key))
        }
        await metadata.setHolding(false)
        let result = try await eviction.value

        #expect(first == (2, 3), "one chunk of records per turn, the blob live with the rest: \(first)")
        #expect(second == (4, 1), "the next chunk in the next turn: \(second)")
        #expect(result == CleanupResult(bytesFreed: 100, filesRemoved: 1), "the blob is doomed once its last record left")
        #expect(await LargeBlobTests.count(harness, shared, .absent(.evicted)) == 5)
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[key], .unreferenced))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// What changes one of the blob's later records while the eviction is between two of its chunks.
    enum Change: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case accessed
        case leased
        case pinned

        var testDescription: String {
            self.rawValue
        }
    }

    /// Each chunk is re-validated in its turn (REENTRANCY R8): a later record that became unevictable stops the blob's
    /// eviction. The records already evicted stay so on the still-live blob, as when an in-flight publication keeps a blob
    /// (C-3's `stillReferenced`): nothing is freed, and the next run takes the rest once they are evictable again.
    @Test(
        "R-CLN-4: quota eviction stops taking a blob more records share than a chunk holds when a later record is accessed, leased or pinned between its chunks, and frees nothing",
        .timeLimit(.minutes(1)),
        arguments: Change.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func evictionStopsAtAChangedRecord(change: Change) async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)), metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_510)
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
        // Meanwhile w3, in the next chunk, changes.
        let changed = shared[3].id
        var lease: AssetLease?
        switch change {
        case .accessed:
            harness.time.advance(by: 1)
            #expect(await harness.store.location(for: changed, extensions: [], recordingAccess: true) != nil)
        case .leased:
            lease = try await harness.store.acquireLease(changed)
        case .pinned:
            let held = Set(await metadata.heldUnits)
            _ = try await CleanupSteps.run(metadata, keeping: held) {
                try await harness.store.setPinned([changed], pinned: true)
            }
        }
        await metadata.setHolding(false)
        let result = try await eviction.value
        if let lease {
            _ = await harness.store.releaseLease(lease)
        }

        #expect(first == 2, "premise: one chunk was evicted before the change: \(first)")
        #expect(result == CleanupResult(), "the blob stays live: nothing is released to the reaper")
        #expect(await LargeBlobTests.count(harness, shared, .absent(.evicted)) == 2, "the chunk evicted before the change stays evicted")
        for asset in shared.dropFirst(2) {
            #expect(await harness.isPresent(asset.id, at: key), "\(asset.id.rawValue) keeps the blob")
        }
        #expect(await LargeBlobTests.references(harness, key) == 3)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-6: a purge takes a blob that more records share than a chunk holds one chunk of its records per actor turn", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeSlicesTheBlob() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_520)
        let key = shared[0].key
        await harness.store.testSetCleanupChunk(2)
        await metadata.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.all)
        }
        let first = try await LargeBlobTests.atNextYield(metadata, "the first chunk of the blob's records is purged") {
            await LargeBlobTests.count(harness, shared, .absent(.purged)) > 0
        } observe: {
            (await LargeBlobTests.count(harness, shared, .absent(.purged)), await LargeBlobTests.references(harness, key))
        }
        await metadata.setHolding(false)
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        let result = try await purge.value

        #expect(first == (2, 3), "one chunk of records per turn, the blob live with the rest: \(first)")
        #expect(result == PurgeResult(bytesFreed: 100, bytesDeferred: 0, assetsRemoved: 5))
        #expect(!harness.hasBlob(key), "the blob is reaped once its last record was purged")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// The evictable selection re-validates the blob and the holders of each chunk in that chunk's turn: w3, pinned
    /// between the first two chunks, stops the blob at the second. The records purged before stay purged (each made a sync
    /// due, R-CLN-6); the rest keep the blob.
    @Test("R-CLN-6: an evictable purge of a blob more records share than a chunk holds stops at a holder pinned between its chunks, the rest keeping the blob", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictablePurgeStopsAtAPinnedHolder() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_530)
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
        _ = try await CleanupSteps.run(metadata, keeping: held) {
            try await harness.store.setPinned([shared[3].id], pinned: true)
        }
        await metadata.setHolding(false)
        let result = try await purge.value

        #expect(first == 2, "premise: one chunk was purged before the pin: \(first)")
        #expect(result == PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 2))
        for asset in shared.dropFirst(2) {
            #expect(await harness.isPresent(asset.id, at: key), "\(asset.id.rawValue) keeps the blob")
        }
        #expect(harness.hasBlob(key))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}

extension LargeBlobTests {
    /// The first turn checks every victim, as one turn did: a record that changed before the blob's first turn keeps the
    /// blob whole, so only a change between its turns can split it.
    @Test("R-CLN-4: quota eviction skips whole a blob more records share than a chunk holds when a later record was accessed before its first turn", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictionSkipsTheBlobChangedBeforeItsFirstTurn() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)), bulk: bulk)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_540)
        let key = shared[0].key
        await harness.store.testSetEvictionChunk(2)
        await bulk.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        // The candidates unit selected the blob and is held; w4, in the blob's last chunk, is read meanwhile.
        try await bulk.requireHeldUnits(atLeast: 1)
        harness.time.advance(by: 1)
        #expect(await harness.store.location(for: shared[4].id, extensions: [], recordingAccess: true) != nil)
        await bulk.setHolding(false)
        let result = try await eviction.value

        #expect(result == CleanupResult(), "nothing evicted, nothing released")
        #expect(await LargeBlobTests.count(harness, shared, .absent(.evicted)) == 0, "the blob is kept whole")
        #expect(await LargeBlobTests.references(harness, key) == 5)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}

extension LargeBlobTests {
    /// What changes the blob's holders while a turn of it is pending: an id bound to it (an alias `apply` adopts onto the
    /// live blob), or one of its later records leaving it (pruned by `apply`). Either makes the blob table's reference count
    /// differ from the records left, so the turn reads the holders again.
    enum HolderChange: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case bound
        case left

        var testDescription: String {
            self.rawValue
        }
    }

    /// The manifest after `change`: the shared records plus an alias of their bytes, or without w4.
    @available(macOS 15.0, iOS 18.0, *)
    static func manifest(after change: HolderChange, _ shared: [CleanupFixture.Asset]) -> ValidatedManifest {
        switch change {
        case .bound:
            return CoreFixture.manifest(shared.map(\.entry) + [CoreFixture.entry("w9", shared[0].bytes)])
        case .left:
            return CoreFixture.manifest(shared.dropLast().map(\.entry))
        }
    }

    /// The selection's holders are no longer exactly the records left: eviction may not take the blob (C-1), so it stops
    /// there, the chunk already taken staying evicted.
    @Test(
        "R-CLN-4: quota eviction stops taking a blob more records share than a chunk holds when an id is bound to it or a later record leaves it between its chunks",
        .timeLimit(.minutes(1)),
        arguments: HolderChange.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func evictionStopsWhenTheHoldersChange(change: HolderChange) async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)), metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_550)
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
            try await harness.store.apply(LargeBlobTests.manifest(after: change, shared), etag: nil, eviction: nil)
        }.value
        await metadata.setHolding(false)
        let result = try await eviction.value
        let kept = change == .bound ? Array(shared[2...4]) : Array(shared[2...3])

        #expect(first == 2, "premise: one chunk was evicted before the change: \(first)")
        #expect(change == .bound ? applied.reused == ["w9"] : applied.pruned == ["w4"], "premise: \(change): \(applied)")
        #expect(result == CleanupResult(), "the blob stays live: nothing is released to the reaper")
        #expect(await LargeBlobTests.count(harness, shared, .absent(.evicted)) == 2, "the chunk evicted before the change stays evicted")
        for asset in kept {
            #expect(await harness.isPresent(asset.id, at: key), "\(asset.id.rawValue) keeps the blob")
        }
        if change == .bound {
            #expect(await harness.isPresent("w9", at: key), "the id bound meanwhile keeps the blob")
        }
        #expect(await LargeBlobTests.references(harness, key) == (change == .bound ? 4 : 2), "the records left on the blob")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// An evictable purge takes every current holder (`purgeChunk`'s rule): an id bound between two chunks is read with the
    /// holders and purged too; a lease taken between them stops the blob, which a purge never takes while leased.
    @Test("R-CLN-6: an evictable purge of a blob more records share than a chunk holds also purges an id bound to it between its chunks", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictablePurgeTakesAHolderBoundBetweenChunks() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_560)
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
            try await harness.store.apply(LargeBlobTests.manifest(after: .bound, shared), etag: nil, eviction: nil)
        }.value
        await metadata.setHolding(false)
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        let result = try await purge.value

        #expect(first == 2, "premise: one chunk was purged before the alias was bound: \(first)")
        #expect(applied.reused == ["w9"], "premise: apply bound the alias to the live blob: \(applied)")
        #expect(result == PurgeResult(bytesFreed: 100, bytesDeferred: 0, assetsRemoved: 6), "every holder, the alias included")
        #expect(await harness.record("w9")?.residency == .absent(.purged))
        #expect(!harness.hasBlob(key), "the blob is reaped")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-6: an evictable purge of a blob more records share than a chunk holds stops at a lease taken between its chunks", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictablePurgeStopsAtALease() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let shared = try await LargeBlobTests.seedShared(harness, count: 5, seed: 1_570)
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
        let lease = try await harness.store.acquireLease(shared[4].id)
        await metadata.setHolding(false)
        let result = try await purge.value
        _ = await harness.store.releaseLease(lease)

        #expect(first == 2, "premise: one chunk was purged before the lease: \(first)")
        #expect(result == PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 2))
        for asset in shared.dropFirst(2) {
            #expect(await harness.isPresent(asset.id, at: key), "\(asset.id.rawValue) keeps the blob")
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
