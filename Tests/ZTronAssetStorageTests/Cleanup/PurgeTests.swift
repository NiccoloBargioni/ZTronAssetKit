import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// User purge (R-CLN-6; store.md §6.5): selection, the stamp, the grace wait in the caller's task, deferral by leases.
@Suite("Cleanup: purge (R-CLN-6)")
struct PurgeTests {
    /// Runs `purge(request)` in a task and lets the deletion grace pass once it waits for it.
    @available(macOS 15.0, iOS 18.0, *)
    static func purge(_ harness: CoreHarness, _ request: PurgeRequest) async throws -> PurgeResult {
        let task = Task {
            try await harness.store.purge(request)
        }
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        return try await task.value
    }

    @Test("R-CLN-6: purge all returns bytes freed, leaves the store consistent and makes a sync due", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeAll() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 200, count: 300)
        let b = CleanupFixture.asset("b", seed: 201, count: 200, policy: .essential)
        try await harness.seed([a, b])
        try await harness.store.setPinned([a.id], pinned: true)
        let view = try await harness.store.planningView()
        let stamp = SyncStamp(appVersion: "1.0+1", completedAt: harness.time.now(), manifestETag: nil, manifestDigest: view.appliedManifest.digest)
        try await harness.store.markSynced(stamp, ifPurgeEpoch: view.purgeEpoch)
        let result = try await PurgeTests.purge(harness, .all)
        #expect(result == PurgeResult(bytesFreed: 500, bytesDeferred: 0, assetsRemoved: 2))
        #expect(!harness.hasBlob(a.key) && !harness.hasBlob(b.key))
        for id in [a.id, b.id] {
            #expect(await harness.record(id)?.residency == .absent(.purged))
        }
        let after = try await harness.store.planningView()
        #expect(after.stamp == nil && after.syncDue)
        // Bumped before the purge's first await and again in the turn of its last chunk (REENTRANCY c-5, review round 3).
        #expect(after.purgeEpoch == view.purgeEpoch + 2)
        await #expect(throws: StoreError.purgeRaced) {
            try await harness.store.markSynced(stamp, ifPurgeEpoch: view.purgeEpoch)
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
        #expect(await harness.state.cleanup.lastCleanupAt == harness.time.now())
        // The purge is durable: a reopen sees the purged records, the cleared stamp and the sync due.
        await harness.store.close()
        let reopened = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), time: harness.time)
        let report = try await reopened.store.open()
        #expect(report.stamp == nil && report.syncDue)
        #expect(await reopened.record(a.id)?.residency == .absent(.purged))
    }

    @Test("R-CLN-6: purging the evictable set keeps essential, pinned and leased assets", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeEvictable() async throws {
        let harness = CoreHarness.cleanup()
        let essential = CleanupFixture.asset("essential", seed: 210, policy: .essential)
        let pinned = CleanupFixture.asset("pinned", seed: 211)
        let leased = CleanupFixture.asset("leased", seed: 212)
        let plain = CleanupFixture.asset("plain", seed: 213, count: 400)
        try await harness.seed([essential, pinned, leased, plain])
        try await harness.store.setPinned([pinned.id], pinned: true)
        _ = try await harness.store.acquireLease(leased.id)
        let result = try await PurgeTests.purge(harness, .evictable)
        #expect(result == PurgeResult(bytesFreed: 400, bytesDeferred: 0, assetsRemoved: 1))
        #expect(await harness.record(plain.id)?.residency == .absent(.purged))
        for kept in [essential, pinned, leased] {
            #expect(await harness.isPresent(kept.id, at: kept.key))
        }
        #expect(try await harness.store.planningView().syncDue)
    }

    @Test("R-CLN-6: a scope purge removes pinned and essential entries in scope and defers leased bytes until release", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeScopeDefersLeases() async throws {
        let harness = CoreHarness.cleanup()
        let pinned = CleanupFixture.asset("bo7.pinned", seed: 220, count: 100)
        let leased = CleanupFixture.asset("bo7.leased", seed: 221, count: 150)
        let outside = CleanupFixture.asset("waw.other", seed: 222, count: 200)
        try await harness.seed([pinned, leased, outside])
        try await harness.store.setPinned([pinned.id], pinned: true)
        let lease = try await harness.store.acquireLease(leased.id)
        let result = try await PurgeTests.purge(harness, .scope(.prefix("bo7.")))
        #expect(result == PurgeResult(bytesFreed: 100, bytesDeferred: 150, assetsRemoved: 2))
        #expect(harness.hasBlob(leased.key) && !harness.hasBlob(pinned.key) && harness.hasBlob(outside.key))
        _ = await harness.store.releaseLease(lease)
        _ = await harness.store.runDueWork()
        #expect(!harness.hasBlob(leased.key), "the deferred blob goes once the lease ends")
    }

    /// Review round 3 (C2, orchestrator ruling R4): the selection is computed off the actor, so the purge awaits before
    /// it changes a record. The epoch and the stamp are written before that await, so a commit made meanwhile already
    /// says a sync is due, and the epoch is bumped again in the turn of the last chunk, so a sync that read it while the
    /// selection ran (and saw records the purge then removed) cannot stamp either.
    @Test("R-CLN-6: a purge clears the stamp before its selection runs off the actor, and a sync that read the epoch meanwhile cannot stamp", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func stampClearedBeforeSelection() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(bulk: bulk)
        let a = CleanupFixture.asset("a", seed: 235)
        let b = CleanupFixture.asset("b", seed: 236)
        try await harness.seed([a, b])
        let view = try await harness.store.planningView()
        let stamp = SyncStamp(appVersion: "1.0+1", completedAt: harness.time.now(), manifestETag: nil, manifestDigest: view.appliedManifest.digest)
        try await harness.store.markSynced(stamp, ifPurgeEpoch: view.purgeEpoch)
        await bulk.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.all)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let selection = try #require(await bulk.heldUnits.first)
        let during = try await harness.store.planningView()
        #expect(during.purgeEpoch == view.purgeEpoch + 1 && during.stamp == nil && during.syncDue)
        #expect(await harness.isPresent(a.id, at: a.key) && harness.hasBlob(a.key), "nothing is purged before the selection")
        // A commit made while the selection runs already says a sync is due.
        _ = try await CleanupSteps.run(bulk, keeping: [selection]) {
            try await harness.store.flush(.ordered)
        }
        let survivor = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), time: harness.time)
        let report = try await survivor.store.open()
        #expect(report.stamp == nil && report.syncDue)
        await survivor.store.close()
        await bulk.setHolding(false)
        await bulk.releaseAll()
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        #expect(try await purge.value.assetsRemoved == 2)
        await #expect(throws: StoreError.purgeRaced) {
            try await harness.store.markSynced(stamp, ifPurgeEpoch: during.purgeEpoch)
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-6: a purge releases the actor between chunks and re-validates every later record: one leased or re-bound meanwhile is kept", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func chunkYieldRevalidates() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let assets = (0..<4).map { CleanupFixture.asset("p\($0)", seed: 240 + UInt64($0)) }
        try await harness.seed(assets)
        await harness.store.testSetCleanupChunk(2)
        await metadata.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        // The first chunk (p0, p1) is purged, then the release between chunks is held.
        try await CorePoll.until("the first chunk is purged") {
            await harness.record(assets[1].id)?.residency == .absent(.purged)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        #expect(await harness.isPresent(assets[2].id, at: assets[2].key) && harness.hasBlob(assets[3].key))
        // Meanwhile p3's blob is leased: the purge keeps it, and purges p2.
        let lease = try await harness.store.acquireLease(assets[3].id)
        await metadata.setHolding(false)
        await metadata.releaseAll()
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        let result = try await purge.value
        #expect(result.assetsRemoved == 3)
        // The reclaim pass runs in chunks of the same size (two here): every chunk's freed bytes count.
        #expect(result.bytesFreed == assets.prefix(3).reduce(0) { $0 + Int64($1.bytes.count) } && result.bytesDeferred == 0)
        for asset in assets.prefix(3) {
            #expect(await harness.record(asset.id)?.residency == .absent(.purged), "\(asset.id.rawValue) is purged")
        }
        #expect(await harness.isPresent(assets[3].id, at: assets[3].key), "the leased one is re-validated and kept")
        _ = await harness.store.releaseLease(lease)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Review of the L3 close-out: chunks cut by record count let a blob's records straddle two chunks, so a holder
    /// pinned between them stayed while the other was purged, an outcome no sequential order of the purge and the pin
    /// gives. Chunks now end only at blob boundaries, and `.evictable` re-validates every current holder of a blob.
    @Test("R-CLN-6: a purge of the evictable set keeps a shared blob with all its records when one of them is pinned between chunks", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictablePurgeKeepsSharedBlobWhole() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let alone = CleanupFixture.asset("a", seed: 250)
        let p0 = CleanupFixture.asset("p0", seed: 251)
        let p1 = CleanupFixture.Asset(entry: CoreFixture.entry("p1", p0.bytes), bytes: p0.bytes)
        try await harness.seed([alone, p0, p1])
        #expect(p0.key == p1.key, "one blob, two records")
        await harness.store.testSetCleanupChunk(1)
        await metadata.setHolding(true)
        let purge = Task {
            try await harness.store.purge(.evictable)
        }
        // The first chunk (a) is purged, then the release between chunks is held.
        try await CorePoll.until("the first chunk is purged") {
            await harness.record(alone.id)?.residency == .absent(.purged)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let held = Set(await metadata.heldUnits)
        _ = try await CleanupSteps.run(metadata, keeping: held) {
            try await harness.store.setPinned([p1.id], pinned: true)
        }
        await metadata.setHolding(false)
        await metadata.releaseAll()
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        let result = try await purge.value
        #expect(result.assetsRemoved == 1)
        let kept = (await harness.isPresent(p0.id, at: p0.key), await harness.isPresent(p1.id, at: p1.key))
        #expect(kept == (true, true), "the pinned holder keeps its blob, with every record on it")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-6: every purge bumps the purge epoch before it awaits, so a run that began before it cannot write its stamp", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func emptyPurgeBumpsEpoch() async throws {
        let harness = CoreHarness.cleanup()
        try await harness.seed([CleanupFixture.asset("a", seed: 225)])
        let epoch = try await harness.store.planningView().purgeEpoch
        let result = try await harness.store.purge(.scope(.identifiers(["nothing"])))
        #expect(result == PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 0))
        #expect(try await harness.store.planningView().purgeEpoch == epoch + 1)
        let stamp = SyncStamp(appVersion: "1", completedAt: harness.time.now(), manifestETag: nil, manifestDigest: ContentHash.sha256(of: Data()))
        await #expect(throws: StoreError.purgeRaced) {
            try await harness.store.markSynced(stamp, ifPurgeEpoch: epoch)
        }
    }

    @Test("R-CLN-6: a purge is not undone by a power loss after the reaper ran", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeSurvivesPowerLoss() async throws {
        let harness = CoreHarness.cleanup(mode: .powerLossDropUnsynced)
        let a = CleanupFixture.asset("a", seed: 230)
        try await harness.seed([a])
        _ = try await PurgeTests.purge(harness, .all)
        #expect(!harness.hasBlob(a.key))
        // A power loss now: unsynced removals may come back, the purged records were committed.
        let survivor = harness.fileSystem.survivingDisk()
        let reopened = CoreHarness.cleanup(disk: survivor, time: harness.time)
        _ = try await reopened.store.open()
        _ = try await reopened.store.apply(CoreFixture.manifest([a.entry]), etag: nil, eviction: nil)
        #expect(await reopened.record(a.id)?.residency == .absent(.purged), "a resurrected blob is never bound to a purged record")
        #expect(await reopened.store.location(for: a.id, extensions: [], recordingAccess: false) == nil)
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
    }

    @Test("R-CLN-6: purge on a full volume returns bytes freed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeOnFullVolume() async throws {
        let first = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 235, count: 2_000)
        try await first.seed([a])
        await first.store.close()
        // The next lifetime has 64 bytes free, less than any index: every index write must make room through the ENOSPC
        // fallback (the previous generation's file goes first).
        let full = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), importantCapacity: 64, time: first.time)
        _ = try await full.store.open()
        let result = try await PurgeTests.purge(full, .all)
        #expect(result.bytesFreed == 2_000 && result.assetsRemoved == 1)
        #expect(!full.hasBlob(a.key))
        let refused = full.fileSystem.operations.filter { $0.kind == .write && $0.url.lastPathComponent == "index.tmp" && $0.failure == .noSpace }
        #expect(!refused.isEmpty, "the volume really was full")
    }

    /// Review of the L3 close-out, cycle 7 (probe ZP7-purge-deleting): two purges wait out the same grace; the first one
    /// to reap after it takes every deletable key, the other purge's too, and while that deletion unit runs the other
    /// purge found its blobs `deleting`, which set neither a wake nor the end of a grace, so it stopped and reported
    /// nothing freed or deferred although its bytes were being reclaimed. An in-flight unlink ends within one deletion
    /// unit, so a purge now waits for it (C-5 (5), cycle 8).
    @Test("R-CLN-6: a purge waits for a blob of its selection that another reaper run is deleting, and counts its bytes", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeWaitsForInFlightDeletion() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let first = (0..<2).map { CleanupFixture.asset("zda.\($0)", seed: 250 + UInt64($0), count: 100) }
        let second = (0..<2).map { CleanupFixture.asset("zdb.\($0)", seed: 252 + UInt64($0), count: 100) }
        let assets = first + second
        try await harness.seed(assets)
        let purgeA = Task {
            try await harness.store.purge(.scope(.prefix("zda.")))
        }
        let purgeB = Task {
            try await harness.store.purge(.scope(.prefix("zdb.")))
        }
        // Both are committed and wait for the same end of the grace.
        try await harness.time.requireSleepers(atLeast: 2)
        await metadata.setHolding(true)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        // Whichever reaps first takes all four keys; its deletion unit is held while the other purge passes over its own.
        try await CorePoll.until("every blob of both selections is being deleted") {
            for asset in assets {
                guard case .deleting? = await harness.state.core.blobTable[asset.key] else {
                    return false
                }
            }
            return true
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        await metadata.setHolding(false)
        await metadata.releaseAll()
        let resultA = try await purgeA.value
        let resultB = try await purgeB.value
        #expect(resultA == PurgeResult(bytesFreed: 200, bytesDeferred: 0, assetsRemoved: 2))
        #expect(resultB == PurgeResult(bytesFreed: 200, bytesDeferred: 0, assetsRemoved: 2))
        for asset in assets {
            #expect(!harness.hasBlob(asset.key), "\(asset.id.rawValue)'s blob is reaped")
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// The same with the engine's reaper (probe ZP7-purge): `runDueWork()` fires at the end of the grace the purge sleeps
    /// until, and its deletion unit holds the purge's blobs while the purge's pass, released between its chunks, reaches
    /// them. The purge reported nothing freed although every blob was reaped.
    @Test("R-CLN-6: a purge waits for its blobs while runDueWork's reaper deletes them, and counts their bytes", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeWaitsForEngineReaper() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let assets = (0..<2).map { CleanupFixture.asset("zr\($0)", seed: 254 + UInt64($0), count: 100) }
        try await harness.seed(assets)
        // One blob per chunk of the reclaim pass, so the purge releases the actor between its two blobs.
        await harness.store.testSetCleanupChunk(1)
        let finished = UnitCounter()
        let purge = Task {
            let result = try await harness.store.purge(.all)
            await finished.increment()
            return result
        }
        try await harness.time.requireSleepers(atLeast: 1)
        await metadata.setHolding(true)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        // The purge's pass classified zr0 (its grace is over) and is held between its chunks.
        try await metadata.requireHeldUnits(atLeast: 1)
        let purgeYield = await metadata.heldUnits[0]
        let work = Task {
            await harness.store.runDueWork()
        }
        // The engine installs the fresh snapshot and its reaper takes both keys; every unit but the purge's goes through
        // until then. The held units are read before the check: a key turns `deleting` before its unit is submitted.
        try await CorePoll.until("runDueWork's reaper is deleting both blobs") {
            let held = await metadata.heldUnits
            var deleting = true
            for asset in assets {
                if case .deleting? = await harness.state.core.blobTable[asset.key] {
                    continue
                }
                deleting = false
            }
            if deleting {
                return true
            }
            for sequence in held where sequence != purgeYield {
                await metadata.release(sequence)
            }
            return false
        }
        try await metadata.requireHeldUnits(atLeast: 2)
        let deletionUnit = try #require(await metadata.heldUnits.first { $0 != purgeYield })
        // The purge's pass goes on while the engine's deletion unit is held: it returns, or waits for that unit.
        await metadata.release(purgeYield)
        try await CorePoll.until("the purge returned or waits for the in-flight deletion") {
            let held = await metadata.heldUnits
            if await finished.value > 0 {
                return true
            }
            let waiters = await harness.state.core.keyWaiters
            if assets.contains(where: { waiters[$0.key] != nil }) {
                return true
            }
            for sequence in held where sequence != deletionUnit {
                await metadata.release(sequence)
            }
            return false
        }
        await metadata.setHolding(false)
        let report = await work.value
        let result = try await purge.value
        #expect(report.reapedKeys == 2, "the engine's reaper deleted both blobs")
        #expect(result == PurgeResult(bytesFreed: 200, bytesDeferred: 0, assetsRemoved: 2))
        for asset in assets {
            #expect(!harness.hasBlob(asset.key), "\(asset.id.rawValue)'s blob is reaped")
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-6: a purge cancelled during its grace wait still leaves the selection purged, and the reaper finishes it", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func cancelledPurge() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 240)
        try await harness.seed([a])
        let task = Task {
            try await harness.store.purge(.all)
        }
        try await harness.time.requireSleepers(atLeast: 1)
        task.cancel()
        await #expect(throws: StoreError.cancelled) {
            try await task.value
        }
        #expect(harness.time.pendingSleepers == 0)
        #expect(await harness.record(a.id)?.residency == .absent(.purged))
        // C-4: the purge was committed before the caller left, so it is a cleanup run even though the reaper frees the
        // bytes later.
        #expect(await harness.state.cleanup.lastCleanupAt == harness.time.now())
        await harness.settleDeletions()
        #expect(!harness.hasBlob(a.key))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
