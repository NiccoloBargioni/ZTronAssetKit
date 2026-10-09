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
        #expect(after.purgeEpoch == view.purgeEpoch + 1)
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
        await harness.settleDeletions()
        #expect(!harness.hasBlob(a.key))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
