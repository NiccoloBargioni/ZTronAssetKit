import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Quota eviction overlapping another release of bytes to the reaper (R-CLN-4, store.md §6.4; review of the L3 close-out
/// cycle 5): a run measures how much it must free once, then awaits its candidates unit and its yields between chunks.
/// Bytes another eviction, `apply`'s eviction plan or a purge doomed meanwhile left `usedBytes` as surely as its own, so
/// they count toward its need; otherwise every overlapping run chases its stale figure and the store ends far below the
/// hysteresis target, every extra asset to be downloaded again.
///
/// Ten 100-byte assets, least recently used first `o0` … `o9`, against a budget of 500 bytes: the target is 450, so a run
/// alone must free 550 and evicts six (`o0` … `o5`, 600 bytes).
@Suite("Cleanup: overlapping quota evictions (R-CLN-4)")
struct EvictionOverlapTests {
    /// The ten assets.
    static let assets = (0..<10).map { CleanupFixture.asset("o\($0)", seed: 1_300 + UInt64($0), count: 100) }

    /// A seeded store whose eviction would free 550 bytes, with the given executors.
    @available(macOS 15.0, iOS 18.0, *)
    static func harness(metadata: SteppedBlockingExecutor? = nil, bulk: SteppedBlockingExecutor? = nil) async throws -> CoreHarness {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(500)), metadata: metadata, bulk: bulk)
        try await EvictionTests.seedWithAccesses(harness, EvictionOverlapTests.assets, recent: EvictionOverlapTests.assets.map(\.id))
        return harness
    }

    /// The indices of the evicted assets, in order.
    @available(macOS 15.0, iOS 18.0, *)
    static func evicted(_ harness: CoreHarness) async -> [Int] {
        await Array(EvictionOverlapTests.assets.indices).asyncFilter {
            await harness.record(EvictionOverlapTests.assets[$0].id)?.residency == .absent(.evicted)
        }
    }

    @Test("R-CLN-4: two quota evictions measured together free what one frees: bytes the other doomed meanwhile count toward the need", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func twoMaintenanceRuns() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        await bulk.setHolding(true)
        let first = Task {
            try await harness.store.evictIfNeeded()
        }
        // The first run measured 550 bytes to free and waits in its candidates unit.
        try await bulk.requireHeldUnits(atLeast: 1)
        let second = Task {
            try await harness.store.evictIfNeeded()
        }
        // The second measured before the first marked anything: 550 bytes too.
        try await bulk.requireHeldUnits(atLeast: 2)
        let held = await bulk.heldUnits
        await bulk.release(held[0])
        let firstResult = try await first.value
        await bulk.setHolding(false)
        let secondResult = try await second.value
        #expect(firstResult == CleanupResult(bytesFreed: 600, filesRemoved: 6))
        #expect(secondResult == CleanupResult(), "the first run's 600 bytes cover the 550 the second measured")
        let evicted = await EvictionOverlapTests.evicted(harness)
        #expect(evicted == Array(0..<6), "what one run alone evicts")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-4: a quota eviction measured before apply evicted its plan frees only what is still needed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func applyPlanWhileCandidatesRun() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        // A sync makes room for 200 bytes meanwhile: the engine's dry run, then `apply` with the plan.
        let plan = try #require(await harness.store.evictionPlan(toFree: 200, protecting: []))
        #expect(plan.victims.map(\.id) == [EvictionOverlapTests.assets[0].id, EvictionOverlapTests.assets[1].id])
        let manifest = CoreFixture.manifest(EvictionOverlapTests.assets.map(\.entry))
        let report = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(manifest, etag: nil, eviction: plan)
        }.value
        #expect(report.evicted == plan.victims.map(\.id))
        await bulk.setHolding(false)
        let result = try await maintenance.value
        #expect(result == CleanupResult(bytesFreed: 400, filesRemoved: 4), "350 of the 550 bytes it measured were still needed")
        let evicted = await EvictionOverlapTests.evicted(harness)
        #expect(evicted == Array(0..<6), "what one run alone evicts")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-4: bytes apply's eviction plan dooms while quota eviction releases the actor between chunks count toward its need", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func applyPlanAtChunkYield() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(metadata: metadata)
        await harness.store.testSetEvictionChunk(2)
        await metadata.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        // The space measurement runs, then the first chunk (o0, o1) is marked and eviction yields in a metadata unit.
        try await CorePoll.until("eviction yields after its first chunk") {
            if await harness.record(EvictionOverlapTests.assets[1].id)?.residency == .absent(.evicted) {
                return await !metadata.heldUnits.isEmpty
            }
            if let unit = await metadata.heldUnits.first {
                await metadata.release(unit)
            }
            return false
        }
        let yield = try #require(await metadata.heldUnits.first)
        let plan = try #require(await harness.store.evictionPlan(toFree: 200, protecting: []))
        #expect(plan.victims.map(\.id) == [EvictionOverlapTests.assets[2].id, EvictionOverlapTests.assets[3].id])
        let manifest = CoreFixture.manifest(EvictionOverlapTests.assets.map(\.entry))
        let report = try await CleanupSteps.run(metadata, keeping: [yield]) {
            try await harness.store.apply(manifest, etag: nil, eviction: plan)
        }.value
        #expect(report.evicted == plan.victims.map(\.id))
        await metadata.setHolding(false)
        let result = try await maintenance.value
        // Its own 200 and apply's 200 leave 150 bytes: o4 and o5.
        #expect(result == CleanupResult(bytesFreed: 400, filesRemoved: 4))
        let evicted = await EvictionOverlapTests.evicted(harness)
        #expect(evicted == Array(0..<6), "what one run alone evicts")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-4: bytes a purge dooms while quota eviction computes its candidates count toward its need", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeWhileCandidatesRun() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        let purged = [EvictionOverlapTests.assets[0].id, EvictionOverlapTests.assets[1].id]
        let purge = Task {
            try await harness.store.purge(.scope(.identifiers(Set(purged))))
        }
        // The purge's selection unit runs; its chunk dooms o0 and o1, then it waits for the grace.
        try await CorePoll.until("the purge doomed its selection") {
            for unit in await bulk.heldUnits where unit != candidates {
                await bulk.release(unit)
            }
            return await harness.record(purged[1])?.residency == .absent(.purged)
        }
        await bulk.setHolding(false)
        let result = try await maintenance.value
        #expect(result == CleanupResult(bytesFreed: 400, filesRemoved: 4), "350 of the 550 bytes it measured were still needed")
        let evicted = await EvictionOverlapTests.evicted(harness)
        #expect(evicted == Array(2..<6))
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        #expect(try await purge.value.assetsRemoved == 2)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
