import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The holders of a re-validated blob after ids were bound to it since the selection (C2; review of the L3 close-out
/// cycle 4): eviction's chunks, `apply`'s eviction plan and an evictable purge's chunks re-read each blob's holders in
/// one actor turn, and when the ids the selection saw no longer account for the blob's references (an alias bound, every
/// id renamed) they need the records themselves. One scan of every record per blob made a chunk of 1,000 candidates hold
/// the actor about 1.7 s at 10,000 records; a turn now scans at most once, for every blob it re-validates.
@Suite("Cleanup: holders re-read after the selection (R-CLN-4, R-CLN-6)")
struct HolderScanTests {
    /// How the selection was taken before the ids were bound.
    enum Route: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// `evictIfNeeded()` with its candidates unit held while `apply` binds an alias to every candidate's blob; two
        /// chunks of four.
        case evictionChunks
        /// `evictionPlan(toFree:protecting:)`, then `apply` of a manifest adding an alias of every id with that plan:
        /// one turn.
        case applyEvictionAfterAliases
        /// `evictionPlan(toFree:protecting:)`, then `apply` of a manifest renaming every id with that plan: one turn, in
        /// which no planned record holds its blob any more, so nothing needs a scan.
        case applyEvictionAfterRename
        /// `purge(.evictable)` with its selection unit held while `apply` binds an alias to every selected blob; two
        /// chunks of four.
        case evictablePurgeChunks

        var testDescription: String {
            self.rawValue
        }
    }

    /// Eight assets of 100 bytes, none accessed within the last hour.
    static func assets() -> [CleanupFixture.Asset] {
        (0..<8).map { CleanupFixture.asset("h\($0)", seed: 1_610 + UInt64($0), count: 100) }
    }

    /// An entry under `prefix` + the asset's id with the asset's bytes (so the same blob).
    static func entry(_ prefix: String, _ asset: CleanupFixture.Asset) -> ManifestEntry {
        CoreFixture.entry(prefix + asset.id.rawValue, asset.bytes)
    }

    @Test(
        "R-CLN-4: eviction, apply's eviction plan and an evictable purge scan the records at most once per actor turn for ids bound to their blobs after the selection",
        .timeLimit(.minutes(1)),
        arguments: Route.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func oneScanPerTurn(route: Route) async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(100)), bulk: bulk)
        let assets = HolderScanTests.assets()
        try await EvictionTests.seedWithAccesses(harness, assets, recent: [])
        await harness.store.testSetEvictionChunk(4)
        await harness.store.testSetCleanupChunk(4)
        let aliased = CoreFixture.manifest(assets.map(\.entry) + assets.map { HolderScanTests.entry("alias-", $0) })
        let scansBefore = await harness.state.eviction.holderScans
        switch route {
        case .evictionChunks:
            await bulk.setHolding(true)
            let eviction = Task {
                try await harness.store.evictIfNeeded()
            }
            try await bulk.requireHeldUnits(atLeast: 1)
            let candidates = try #require(await bulk.heldUnits.first)
            _ = try await CleanupSteps.run(bulk, keeping: [candidates]) {
                try await harness.store.apply(aliased, etag: nil, eviction: nil)
            }
            await bulk.setHolding(false)
            let result = try await eviction.value
            #expect(result == CleanupResult(), "every candidate now has an alias the selection never saw, so nothing is evicted")
            let scans = await harness.state.eviction.holderScans - scansBefore
            #expect(scans == 2, "one scan for each of the two chunks of four, not one per candidate")
            for asset in assets {
                #expect(await harness.isPresent(asset.id, at: asset.key), "\(asset.id.rawValue) is kept")
                #expect(await harness.isPresent(AssetID("alias-" + asset.id.rawValue), at: asset.key), "its alias is kept")
            }
        case .applyEvictionAfterAliases:
            let plan = try #require(await harness.store.evictionPlan(toFree: 800, protecting: []))
            #expect(Set(plan.victims.map(\.id)) == Set(assets.map(\.id)))
            let report = try await harness.store.apply(aliased, etag: nil, eviction: plan)
            #expect(report.evicted.isEmpty, "every planned blob has an alias the plan never saw")
            let scans = await harness.state.eviction.holderScans - scansBefore
            #expect(scans == 1, "one scan for the whole plan, not one per planned blob")
            for asset in assets {
                #expect(await harness.isPresent(asset.id, at: asset.key), "\(asset.id.rawValue) is kept")
                #expect(await harness.isPresent(AssetID("alias-" + asset.id.rawValue), at: asset.key), "its alias is kept")
            }
        case .applyEvictionAfterRename:
            let plan = try #require(await harness.store.evictionPlan(toFree: 800, protecting: []))
            #expect(Set(plan.victims.map(\.id)) == Set(assets.map(\.id)))
            let renamed = CoreFixture.manifest(assets.map { HolderScanTests.entry("renamed-", $0) })
            let report = try await harness.store.apply(renamed, etag: nil, eviction: plan)
            #expect(report.evicted.isEmpty, "every planned id is gone; the renamed ids were never planned")
            let scans = await harness.state.eviction.holderScans - scansBefore
            #expect(scans == 0, "a planned record that left its blob fails re-validation before any scan")
            for asset in assets {
                #expect(await harness.isPresent(AssetID("renamed-" + asset.id.rawValue), at: asset.key), "the renamed \(asset.id.rawValue) is kept")
            }
        case .evictablePurgeChunks:
            await bulk.setHolding(true)
            let purge = Task {
                try await harness.store.purge(.evictable)
            }
            try await bulk.requireHeldUnits(atLeast: 1)
            let selection = try #require(await bulk.heldUnits.first)
            _ = try await CleanupSteps.run(bulk, keeping: [selection]) {
                try await harness.store.apply(aliased, etag: nil, eviction: nil)
            }
            await bulk.setHolding(false)
            try await harness.time.requireSleepers(atLeast: 1)
            harness.time.advance(by: harness.configuration.policy.deletionGrace)
            let result = try await purge.value
            #expect(result.assetsRemoved == 16, "every selected blob loses all its holders, the aliases bound since the selection included")
            let scans = await harness.state.eviction.holderScans - scansBefore
            #expect(scans == 2, "one scan for each of the two chunks of four blobs, not one per blob")
            for asset in assets {
                #expect(await harness.record(AssetID("alias-" + asset.id.rawValue))?.residency == .absent(.purged))
                #expect(!harness.hasBlob(asset.key), "\(asset.id.rawValue)'s blob is reaped")
            }
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// The scan is valid for one turn only: eviction drops it at each release of the actor between chunks, so an id bound
    /// meanwhile to a later chunk's blob is seen and keeps that blob (a scan kept across the release would evict the
    /// selected record and leave the blob to the new one).
    @Test(
        "R-CLN-4: an alias bound while eviction releases the actor between chunks keeps a later chunk's blob: each chunk scans the records afresh",
        .timeLimit(.minutes(1))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func scanDroppedAtEachRelease() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(100)), metadata: metadata, bulk: bulk)
        let assets = HolderScanTests.assets()
        // Least recently used first: h0 … h7; two chunks of four.
        try await EvictionTests.seedWithAccesses(harness, assets, recent: assets.map(\.id))
        await harness.store.testSetEvictionChunk(4)
        let entries = assets.map(\.entry)
        await bulk.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        // h0 gains an alias after the selection, so the first chunk needs a scan of the records.
        _ = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(entries + [HolderScanTests.entry("alias-", assets[0])]), etag: nil, eviction: nil)
        }
        await metadata.setHolding(true)
        await bulk.setHolding(false)
        try await CorePoll.until("eviction yields after its first chunk") {
            if await harness.record(assets[3].id)?.residency == .absent(.evicted) {
                return await !metadata.heldUnits.isEmpty
            }
            return false
        }
        // Meanwhile h5, in the second chunk, gains an alias too.
        let release = Set(await metadata.heldUnits)
        _ = try await CleanupSteps.run(metadata, keeping: release) {
            try await harness.store.apply(
                CoreFixture.manifest(entries + [HolderScanTests.entry("alias-", assets[0]), HolderScanTests.entry("alias-", assets[5])]),
                etag: nil,
                eviction: nil
            )
        }
        await metadata.setHolding(false)
        let result = try await eviction.value
        #expect(result.filesRemoved == 6 && result.bytesFreed == 600, "every blob but h0's and h5's")
        for index in [0, 5] {
            #expect(await harness.isPresent(assets[index].id, at: assets[index].key), "h\(index) keeps its blob")
            #expect(await harness.isPresent(AssetID("alias-h\(index)"), at: assets[index].key), "with its alias")
        }
        for index in [1, 2, 3, 4, 6, 7] {
            #expect(await harness.record(assets[index].id)?.residency == .absent(.evicted), "h\(index) is evicted")
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
