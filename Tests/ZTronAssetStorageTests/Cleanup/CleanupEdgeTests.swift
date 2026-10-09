import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Cleanup at its edges: failures of the file system, protected stores, vanished blobs and pathological policies.
@Suite("Cleanup: failures and edges (R-CLN-*, R-INT-*)")
struct CleanupEdgeTests {
    @Test("R-INT-4: deep verification quarantines a resident blob that vanished", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func vanishedBlobQuarantined() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 1_000)
        try await harness.seed([a])
        try harness.fileSystem.removeItem(at: harness.layout.blobURL(a.key))
        let report = try await harness.store.verifyIntegrity(byteBudget: 1 << 20, until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(report.corrupt == [a.id] && report.completedPass)
        if case .quarantined = await harness.record(a.id)?.residency {
        } else {
            Issue.record("the record of a vanished blob is quarantined")
        }
        #expect(await harness.store.location(for: a.id, extensions: [], recordingAccess: false) == nil)
    }

    @Test("R-CLN-6: a purge whose unlink fails returns without waiting out the unlink backoff, and the reaper retries later", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeWithFailingUnlink() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 1_010)
        try await harness.seed([a])
        harness.fileSystem.addFault(FaultRule(operation: .removeItem, matching: URLMatcher(lastComponentSuffix: a.key.fileName), occurrence: .nth(1), error: .io))
        let result = try await PurgeTests.purge(harness, .all)
        #expect(result == PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 1))
        #expect(harness.hasBlob(a.key) && harness.time.pendingSleepers == 0)
        harness.time.advance(by: 3_600)
        _ = await harness.store.runDueWork()
        #expect(!harness.hasBlob(a.key), "the reaper retries after its backoff")
    }

    @Test("R-CLN-4: when everything over budget is protected, eviction evicts nothing and writes nothing", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func everythingProtected() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)))
        let a = CleanupFixture.asset("a", seed: 1_020, policy: .essential)
        let b = CleanupFixture.asset("b", seed: 1_021)
        try await harness.seed([a, b])
        try await harness.store.setPinned([b.id], pinned: true)
        harness.time.advance(by: 3_600)
        let mutations = harness.fileSystem.mutationCount
        #expect(try await harness.store.evictIfNeeded() == CleanupResult())
        #expect(harness.fileSystem.mutationCount == mutations)
        #expect(await harness.store.evictionPlan(toFree: 1, protecting: []) == nil)
        #expect(await harness.state.cleanup.lastCleanupAt == nil)
    }

    @Test("R-CLN-4: an unlimited budget evicts least-recently-used blobs until free space plus pending reclaim meets the reserve", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func reserveDrivesEviction() async throws {
        let assets = (0..<4).map { CleanupFixture.asset("r\($0)", seed: 1_030 + UInt64($0), count: 1_000) }
        // A pilot run measures the free space the seed leaves; the real run's reserve is 1,500 bytes above it.
        let pilot = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .unlimited), importantCapacity: 100_000)
        try await EvictionTests.seedWithAccesses(pilot, assets, recent: assets.map(\.id))
        let free = try await pilot.store.freeSpace().volumeImportant
        let reserve = free + 1_500
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .unlimited, reserveFreeBytes: reserve), importantCapacity: 100_000)
        try await EvictionTests.seedWithAccesses(harness, assets, recent: assets.map(\.id))
        #expect(try await harness.store.freeSpace().volumeImportant == free)
        let result = try await harness.store.evictIfNeeded()
        let after = try await harness.store.freeSpace()
        #expect(result == CleanupResult(bytesFreed: 2_000, filesRemoved: 2, bytesDeferred: 0), "two blobs cover the 1,500-byte shortfall")
        #expect(after.volumeImportant + after.pendingReclaim >= reserve)
        let evicted = await assets.asyncFilter { await harness.record($0.id)?.residency == .absent(.evicted) }
        #expect(evicted.map(\.id) == [assets[0].id, assets[1].id], "least recently used first")
    }

    @Test("R-CLN-3: a staging directory that cannot be listed fails the collection and removes nothing", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func unlistableStaging() async throws {
        let harness = CoreHarness.cleanup()
        _ = try await harness.store.open()
        let name = try await GarbageCollectionTests.stage(harness, CleanupFixture.asset("s", seed: 1_040).entry, bytes: 40, sequence: 1)
        harness.time.advance(by: 2 * 3_600)
        harness.fileSystem.addFault(FaultRule(operation: .contentsOfDirectory, matching: URLMatcher(lastComponentSuffix: "staging"), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            _ = try await harness.store.collectStaging(keeping: [])
        }
        #expect(harness.exists(harness.layout.stagingURL(name)))
        harness.fileSystem.addFault(FaultRule(operation: .contentsOfDirectory, matching: URLMatcher(lastComponentSuffix: "blobs"), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            _ = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        }
    }

    @Test("R-INT-3: a non-finite integrity backoff quarantines until the distant future instead of trapping", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func nonFiniteBackoff() async throws {
        var policy = CleanupFixture.policy(maxIntegrityAttempts: 5)
        policy.integrityBackoffMultiplier = .greatestFiniteMagnitude
        let harness = CoreHarness.cleanup(policy: policy)
        let a = CleanupFixture.asset("a", seed: 1_050)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a.entry]), etag: nil, eviction: nil)
        try await harness.store.recordIntegrityFailure([a.id], identity: a.entry.contentIdentity)
        try await harness.store.recordIntegrityFailure([a.id], identity: a.entry.contentIdentity)
        #expect(await harness.record(a.id)?.residency == .quarantined(until: .distantFuture))
        #expect(await harness.record(a.id)?.integrity.nextEligibleAt == .distantFuture)
    }

    @Test("R-CLN-9: storageReport counts a leased blob that was doomed as pending deletion", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func leasedPendingDeletion() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 1_060, count: 120)
        let b = CleanupFixture.asset("b", seed: 1_061, count: 80)
        try await harness.seed([a, b])
        let lease = try await harness.store.acquireLease(a.id)
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        let report = await harness.store.storageReport()
        #expect(report.bytesByState.pendingDeletion == 200, "an unleased and a leased doomed blob")
        _ = await harness.store.releaseLease(lease)
        #expect(await harness.state.cleanup.leasedBytes.isEmpty)
    }
}
