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

    /// How a blob is doomed outside eviction and purge while quota eviction computes its candidates.
    enum Release: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// `reportUnreadable(_:)`: the blob is quarantined, doomed `corrupt` (deep verification shares the path).
        case quarantine
        /// `recordFailure(_:identity:reason:)` with `.notFound` for a stale record (the entry's content changed and the
        /// new content is gone from the server): the record becomes `failed`, its old blob doomed `unreferenced`. A record
        /// present at the failed content is left unchanged (L4-R16), so the case uses the stale one.
        case failure
        /// `recordIntegrityFailure(_:identity:)` up to `maxIntegrityAttempts` (three): the record serves its bytes during
        /// the backoff, then becomes `failed(.integrity)`, its blob doomed `unreferenced`.
        case integrityFailures

        var testDescription: String {
            self.rawValue
        }
    }

    /// Review of the L3 close-out cycle 6 (probe ZP6-overlap-quarantine; orchestrator ruling R7 at cycle 7): a quarantine
    /// dooms the most recently used asset's blob while the run computes its candidates. Those bytes left `usedBytes` as
    /// surely as an eviction's, so they count toward the need: counted, the run evicts what a measurement after the
    /// quarantine asks for; not counted, it evicts one asset too many, to be downloaded again. A recorded failure, and the
    /// last of a record's integrity failures, doom the blob the same way.
    @Test(
        "R-CLN-4: bytes a quarantine or a recorded failure dooms while quota eviction computes its candidates count toward its need",
        .timeLimit(.minutes(1)),
        arguments: Release.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func releaseWhileCandidatesRun(release: Release) async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        let last = EvictionOverlapTests.assets[9]
        // For a recorded failure, o9's entry changes first (o9 keeps serving its old bytes, stale): a failure for content
        // the record is present at changes nothing (L4-R16); the old blob's 100 bytes still count as used.
        let changed = CleanupFixture.asset("o9", seed: 1_399, count: 100)
        if release == .failure {
            let entries = EvictionOverlapTests.assets.dropLast().map(\.entry) + [changed.entry]
            _ = try await harness.store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
            #expect(await harness.record(last.id)?.isStale == true, "setup: o9 is stale")
        }
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        // The run measured 550 bytes to free and waits in its candidates unit.
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        // Meanwhile the most recently used asset, o9, is found unreadable, or gone from the server: its blob is doomed.
        _ = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            switch release {
            case .quarantine:
                try await harness.store.reportUnreadable(last.id)
            case .failure:
                try await harness.store.recordFailure([last.id], identity: changed.entry.contentIdentity, reason: .notFound)
            case .integrityFailures:
                for _ in 0..<harness.configuration.policy.maxIntegrityAttempts {
                    try await harness.store.recordIntegrityFailure([last.id], identity: last.entry.contentIdentity)
                }
            }
        }
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[last.key], release == .quarantine ? .corrupt : .unreferenced))
        await bulk.setHolding(false)
        let result = try await maintenance.value
        #expect(result == CleanupResult(bytesFreed: 500, filesRemoved: 5), "450 of the 550 bytes it measured were still needed")
        let evicted = await EvictionOverlapTests.evicted(harness)
        #expect(evicted == Array(0..<5), "what a run measured after the release evicts")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
