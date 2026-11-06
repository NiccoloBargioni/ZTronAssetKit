import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Stage 3 mutation-probe tests for the group "storage" (SPEC 7.4, Q-8): each test below passes on the clean tree and
/// fails on the surviving mutant named in its comment. NOT part of the repository; written by the independent agent so
/// the orchestrator can adopt them.
@Suite("Mutation probes: storage survivors")
struct MutationProbeStorageTests {
    /// M-S-20: `OrphanCollection.decide` compared the age with 0 instead of `orphanGrace`.
    @Test("R-CLN-2: an orphan younger than the orphan grace is kept even when it is not brand new", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func orphanInsideGrace() async throws {
        let harness = CoreHarness.cleanup()
        _ = try await harness.store.open()
        let middle = try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(900, count: 60))
        harness.time.advance(by: 1_800)
        let early = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(early == CleanupResult(), "half the orphan grace has passed: nothing is doomed")
        #expect(harness.hasBlob(middle))
        #expect(await harness.state.core.blobTable[middle] == nil)
        harness.time.advance(by: 1_801)
        let late = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(late.bytesFreed == 60 && late.filesRemoved == 1, "past the grace it is doomed")
    }

    /// M-S-17: `EvictionOrder.Rules.allows` used `>` instead of `>=` at the residency window's edge.
    @Test("R-CLN-4: an asset last accessed exactly minimumResidency ago is evictable, one second less is not", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func residencyBoundary() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0), minimumResidency: 600))
        let asset = CleanupFixture.asset("edge", seed: 910)
        try await harness.seed([asset])
        harness.time.advance(by: 599)
        #expect(await harness.store.evictionPlan(toFree: 1, protecting: []) == nil, "599 s after the access: inside the window")
        harness.time.advance(by: 1)
        let plan = try #require(await harness.store.evictionPlan(toFree: 1, protecting: []))
        #expect(plan.victims.map(\.id) == [asset.id], "exactly 600 s after the access: the window is over")
        let result = try await harness.store.evictIfNeeded()
        #expect(result.filesRemoved == 1)
    }

    /// M-S-08: `EvictionOrder.Ranking` no longer excluded leased blobs (the dry run named and counted them).
    @Test("R-CLN-5: the eviction dry run neither names a leased asset nor counts its bytes", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func dryRunSkipsLeased() async throws {
        let harness = CoreHarness.cleanup()
        let leased = CleanupFixture.asset("leased", seed: 920, count: 300)
        let plain = CleanupFixture.asset("plain", seed: 921, count: 100)
        try await EvictionTests.seedWithAccesses(harness, [leased, plain], recent: [])
        _ = try await harness.store.acquireLease(leased.id)
        harness.time.advance(by: 3_600)
        let plan = try #require(await harness.store.evictionPlan(toFree: 1, protecting: []))
        #expect(plan.victims.map(\.id) == [plain.id] && plan.bytes == 100)
        #expect(await harness.store.evictionPlan(toFree: 101, protecting: []) == nil, "the leased 300 bytes are not reachable")
    }

    /// M-S-07: `AssetStore.evict` no longer re-checked the leases at apply time. The lease must land at the very
    /// instant of the record's last access (zero residency, frozen clock), or `acquireLease`'s access stamp would make
    /// the "accessed since the selection" guard refuse the victim first.
    @Test("R-CLN-5: apply skips a planned victim that was leased after the plan, without any access stamp to hide behind", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func applySkipsLeasedVictim() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(deletionGrace: 0))
        let asset = CleanupFixture.asset("held", seed: 930)
        _ = try await harness.store.open()
        let manifest = CoreFixture.manifest([asset.entry])
        _ = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        try await harness.publish(asset.bytes, [asset.entry], sequence: 1)
        let plan = try #require(await harness.store.evictionPlan(toFree: 1, protecting: []))
        #expect(plan.victims.map(\.id) == [asset.id])
        let lease = try await harness.store.acquireLease(asset.id)
        let report = try await harness.store.apply(manifest, etag: nil, eviction: plan)
        #expect(report.evicted.isEmpty, "a leased asset is never evicted")
        #expect(await harness.isPresent(asset.id, at: asset.key))
        _ = await harness.store.releaseLease(lease)
    }

    /// M-S-11: `StoreStagingSink.writeStaged` swallowed a `.noSpace` write failure and reported success.
    @Test("R-STO-6: an ENOSPC while staging a chunk source surfaces as insufficientSpace and leaves nothing behind", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func writeStagedNoSpace() async throws {
        let (harness, sink) = try await StagingSinkTests.sink()
        let name = StagingSinkTests.name(1)
        let temporary = harness.layout.stagingURL(name.with(kind: .partialTemporary))
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: ".parttmp"), occurrence: .nth(2), error: .noSpace))
        await #expect(throws: StagingError.insufficientSpace) {
            try await sink.writeStaged(name, from: ScriptedChunks(chunks: [Data([1, 2]), Data([3, 4])], failAt: nil), maxBytes: 100)
        }
        #expect(!harness.exists(temporary), "the temporary is removed")
        #expect(!harness.exists(harness.layout.stagingURL(name)), "nothing is published under the final name")
    }
}
