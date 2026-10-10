import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Quota eviction, the dry run, pins and the retention scope (R-CLN-4, R-CLN-5, R-SYN-11, R-CAR-5; store.md §6.4).
@Suite("Cleanup: quota eviction (R-CLN-4)")
struct EvictionTests {
    /// Seeds `assets` at the clock's current time, then touches `recent` one minute apart in order, then lets a further
    /// hour pass so nothing is inside the residency window.
    @available(macOS 15.0, iOS 18.0, *)
    static func seedWithAccesses(_ harness: CoreHarness, _ assets: [CleanupFixture.Asset], recent: [AssetID]) async throws {
        try await harness.seed(assets)
        for id in recent {
            harness.time.advance(by: 60)
            _ = await harness.store.location(for: id, extensions: [], recordingAccess: true)
        }
        harness.time.advance(by: 3_600)
    }

    @Test("R-CLN-4: eviction removes least-recently-used first, larger first on ties, down to 90 % of budget", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func lruLargerFirstDownToHysteresis() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(900)))
        let a = CleanupFixture.asset("a", seed: 30, count: 300)
        let b = CleanupFixture.asset("b", seed: 31, count: 200)
        let c = CleanupFixture.asset("c", seed: 32, count: 250)
        let d = CleanupFixture.asset("d", seed: 33, count: 150)
        let e = CleanupFixture.asset("e", seed: 34, count: 200)
        try await EvictionTests.seedWithAccesses(harness, [a, b, c, d, e], recent: [c.id, d.id, e.id])
        // 1,100 bytes against a budget of 900: the target is 810, so 290 bytes must go. `a` and `b` tie on last
        // access; the larger one (`a`, 300 bytes) goes first and is enough.
        let result = try await harness.store.evictIfNeeded()
        #expect(await harness.record(a.id)?.residency == .absent(.evicted))
        for kept in [b, c, d, e] {
            #expect(await harness.isPresent(kept.id, at: kept.key), "\(kept.id.rawValue) is kept")
        }
        let space = try await harness.store.freeSpace()
        #expect(space.usedBytes == 800 && space.usedBytes <= 810)
        #expect(result.bytesFreed == 300 && result.filesRemoved == 1)
        let metrics = await harness.store.metrics()
        #expect(metrics.evictions == 1 && metrics.evictedBytes == 300)
        #expect(await harness.store.location(for: a.id, extensions: [], recordingAccess: false) == nil)
        await harness.settleDeletions()
        #expect(!harness.hasBlob(a.key), "the reaper deletes the evicted blob after acknowledgement and grace")
    }

    @Test("R-CLN-4: eviction releases the actor between chunks and re-validates every later candidate: one accessed or leased meanwhile is kept", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func chunkYieldRevalidates() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(100)), metadata: metadata)
        let assets = (0..<6).map { CleanupFixture.asset("y\($0)", seed: 790 + UInt64($0), count: 100) }
        // Least recently used first: y0 … y5.
        try await EvictionTests.seedWithAccesses(harness, assets, recent: assets.map(\.id))
        await harness.store.testSetEvictionChunk(2)
        await metadata.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        // The space measurement runs, then the first chunk (y0, y1) is marked and eviction yields in a metadata unit.
        try await CorePoll.until("eviction yields after its first chunk") {
            if await harness.record(assets[1].id)?.residency == .absent(.evicted) {
                return await !metadata.heldUnits.isEmpty
            }
            if let unit = await metadata.heldUnits.first {
                await metadata.release(unit)
            }
            return false
        }
        #expect(await harness.isPresent(assets[2].id, at: assets[2].key), "nothing after the chunk is marked yet")
        // Meanwhile the app reads y2 and holds y3 open.
        #expect(await harness.store.location(for: assets[2].id, extensions: [], recordingAccess: true) != nil)
        let lease = try await harness.store.acquireLease(assets[3].id)
        await metadata.setHolding(false)
        let result = try await eviction.value
        #expect(result.filesRemoved == 4 && result.bytesFreed == 400, "y0, y1, y4 and y5; the target needed all six")
        for index in [0, 1, 4, 5] {
            #expect(await harness.record(assets[index].id)?.residency == .absent(.evicted), "y\(index) is evicted")
        }
        #expect(await harness.isPresent(assets[2].id, at: assets[2].key), "accessed since the selection")
        #expect(await harness.isPresent(assets[3].id, at: assets[3].key), "leased since the selection")
        _ = await harness.store.releaseLease(lease)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Review of the L3 close-out cycle 5 (C2): a chunk counted blobs, so where several ids share each blob a chunk of
    /// 1,000 changed up to 10,000 records in one turn (16 ms at 10,000 records with ten ids per blob). A chunk now ends at
    /// the first blob boundary at or after `chunk` records: with a chunk of two records and two ids per blob, the first
    /// yield comes after one blob.
    @Test("R-CLN-4: eviction releases the actor after a chunk's worth of records, cut at blob boundaries, however many ids share a blob", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func chunkCountsRecords() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)), metadata: metadata)
        let blobs = (0..<3).map { CoreFixture.bytes(800 + UInt64($0), count: 100) }
        let pairs = blobs.enumerated().map { index, bytes in
            ["a", "b"].map { CleanupFixture.Asset(entry: CoreFixture.entry("s\(index)\($0)", bytes), bytes: bytes) }
        }
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(pairs.flatMap { $0.map(\.entry) }), etag: nil, eviction: nil)
        for (index, pair) in pairs.enumerated() {
            try await harness.publish(blobs[index], pair.map(\.entry), sequence: UInt32(index + 1))
        }
        // Least recently used first: s0, s1, s2.
        for asset in pairs.flatMap({ $0 }) {
            harness.time.advance(by: 60)
            _ = await harness.store.location(for: asset.id, extensions: [], recordingAccess: true)
        }
        harness.time.advance(by: 3_600)
        await harness.store.testSetEvictionChunk(2)
        await metadata.setHolding(true)
        let eviction = Task {
            try await harness.store.evictIfNeeded()
        }
        try await CorePoll.until("eviction yields after its first chunk") {
            if await harness.record(pairs[0][1].id)?.residency == .absent(.evicted) {
                return await !metadata.heldUnits.isEmpty
            }
            if let unit = await metadata.heldUnits.first {
                await metadata.release(unit)
            }
            return false
        }
        let firstChunk = await pairs.flatMap { $0 }.asyncFilter { await harness.record($0.id)?.residency == .absent(.evicted) }
        #expect(firstChunk.map(\.id) == pairs[0].map(\.id), "the first chunk is the first blob's two records")
        await metadata.setHolding(false)
        let result = try await eviction.value
        #expect(result == CleanupResult(bytesFreed: 300, filesRemoved: 3))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// How a test reaches eviction: the maintenance run, or the engine's dry run applied by `apply`.
    enum Route: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case maintenance
        case dryRunThenApply

        var testDescription: String {
            self.rawValue
        }
    }

    @Test(
        "R-CLN-4: eviction goes down to the hysteresis target, not just under the budget, least recently used first even when smaller",
        .timeLimit(.minutes(1)),
        arguments: Route.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func downToHysteresisTargetLeastRecentFirst(route: Route) async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(1_000)))
        let oldest = CleanupFixture.asset("oldest", seed: 70, count: 150)
        let older = CleanupFixture.asset("older", seed: 71, count: 200)
        let big = CleanupFixture.asset("big", seed: 72, count: 400)
        let bigger = CleanupFixture.asset("bigger", seed: 73, count: 350)
        let assets = [oldest, older, big, bigger]
        try await EvictionTests.seedWithAccesses(harness, assets, recent: assets.map(\.id))
        // 1,100 bytes against a budget of 1,000: evicting `oldest` alone would end under the budget (950), but the
        // target is 90 % of it (900), so `older` goes too. Both are smaller than the two recent ones.
        let space = try await harness.store.freeSpace()
        #expect(space.usedBytes == 1_100)
        let needed = EvictionOrder.bytesToFree(usedBytes: space.usedBytes, availableBytes: space.volumeImportant, pendingReclaim: space.pendingReclaim, policy: harness.configuration.policy)
        #expect(needed == 200, "down to 900, not to 1,000")
        switch route {
        case .maintenance:
            let result = try await harness.store.evictIfNeeded()
            #expect(result.bytesFreed == 350 && result.filesRemoved == 2)
        case .dryRunThenApply:
            let plan = try #require(await harness.store.evictionPlan(toFree: needed, protecting: []))
            #expect(plan.victims.map(\.id) == [oldest.id, older.id] && plan.bytes == 350)
            let report = try await harness.store.apply(CoreFixture.manifest(assets.map(\.entry)), etag: nil, eviction: plan)
            #expect(report.evicted == [oldest.id, older.id])
        }
        for evicted in [oldest, older] {
            #expect(await harness.record(evicted.id)?.residency == .absent(.evicted), "\(evicted.id.rawValue) is evicted")
        }
        for kept in [big, bigger] {
            #expect(await harness.isPresent(kept.id, at: kept.key), "\(kept.id.rawValue) is kept")
        }
        #expect(try await harness.store.freeSpace().usedBytes == 750)
    }

    @Test(
        "R-CLN-5: eviction never takes an asset accessed within the deletion grace, even with no minimum residency",
        .timeLimit(.minutes(1)),
        arguments: Route.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func deletionGraceProtectsRecentAccess(route: Route) async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0), minimumResidency: 0, deletionGrace: 10))
        let recent = CleanupFixture.asset("recent", seed: 80)
        let stale = CleanupFixture.asset("stale", seed: 81)
        try await harness.seed([recent, stale])
        harness.time.advance(by: 3_600)
        _ = await harness.store.location(for: stale.id, extensions: [], recordingAccess: true)
        harness.time.advance(by: 6)
        _ = await harness.store.location(for: recent.id, extensions: [], recordingAccess: true)
        // Now `stale` was read 11 s ago (outside the 10 s grace) and `recent` 5 s ago (inside it).
        harness.time.advance(by: 5)
        #expect(await harness.store.evictionPlan(toFree: Int64(stale.bytes.count) + 1, protecting: []) == nil, "recent cannot be planned")
        switch route {
        case .maintenance:
            let result = try await harness.store.evictIfNeeded()
            #expect(result.filesRemoved == 1 && result.bytesFreed == Int64(stale.bytes.count))
        case .dryRunThenApply:
            let plan = try #require(await harness.store.evictionPlan(toFree: 1, protecting: []))
            #expect(plan.victims.map(\.id) == [stale.id])
            let report = try await harness.store.apply(CoreFixture.manifest([recent.entry, stale.entry]), etag: nil, eviction: plan)
            #expect(report.evicted == [stale.id])
        }
        #expect(await harness.record(stale.id)?.residency == .absent(.evicted))
        #expect(await harness.isPresent(recent.id, at: recent.key), "accessed within the grace window")
    }

    /// Review round 1 (C-3): a publication of the same bytes under another id takes a provisional reference on the
    /// live blob before its placement unit; evicting every record meanwhile leaves the blob live, so nothing was removed.
    @Test("R-CLN-4: eviction reports no removed file when an in-flight publication of the same bytes keeps the blob", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictionDuringReusingPublication() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0), hysteresisTarget: 1), metadata: metadata)
        let a = CleanupFixture.asset("a", seed: 95)
        // `c` names the same bytes without a checksum, so no adoption binds it: only its publication does.
        let c = CoreFixture.entry("c", a.bytes, checksum: false)
        try await harness.seed([a])
        _ = try await harness.store.apply(CoreFixture.manifest([a.entry, c]), etag: nil, eviction: nil)
        harness.time.advance(by: 3_600)
        let staged = try await harness.stage(a.bytes, for: c, sequence: 9)
        await metadata.setHolding(true)
        let publish = Task {
            try await harness.store.publish(staged, binding: [c.identifier], expecting: c.contentIdentity, urgency: .bulk)
        }
        // Run the publication's units until it holds a provisional reference on `a`'s blob; its placement unit then waits.
        try await CorePoll.until("c's publication reuses a's blob") {
            if case .live(let references)? = await harness.store.state.core.blobTable[a.key], references == 2 {
                return true
            }
            if let unit = await metadata.heldUnits.first {
                await metadata.release(unit)
            }
            return false
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let placement = try #require(await metadata.heldUnits.first)
        let releaser = Task {
            while !Task.isCancelled {
                for unit in await metadata.heldUnits where unit != placement {
                    await metadata.release(unit)
                }
                await Task.yield()
            }
        }
        let result = try await harness.store.evictIfNeeded()
        releaser.cancel()
        #expect(await harness.record(a.id)?.residency == .absent(.evicted))
        #expect(result.filesRemoved == 0 && result.bytesFreed == 0, "the blob stays: c's publication holds it")
        await metadata.setHolding(false)
        _ = try await publish.value
        #expect(await harness.isPresent(c.identifier, at: a.key) && harness.hasBlob(a.key))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-4: essential, pinned, leased and recently accessed assets are never evicted", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func protectedAssetsStay() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0), minimumResidency: 600))
        let essential = CleanupFixture.asset("essential", seed: 40, policy: .essential)
        let pinned = CleanupFixture.asset("pinned", seed: 41)
        let leased = CleanupFixture.asset("leased", seed: 42)
        let recent = CleanupFixture.asset("recent", seed: 43)
        let plain = CleanupFixture.asset("plain", seed: 44)
        try await harness.seed([essential, pinned, leased, recent, plain])
        try await harness.store.setPinned([pinned.id], pinned: true)
        _ = try await harness.store.acquireLease(leased.id)
        harness.time.advance(by: 3_600)
        _ = await harness.store.location(for: recent.id, extensions: [], recordingAccess: true)
        harness.time.advance(by: 599)
        _ = try await harness.store.evictIfNeeded()
        #expect(await harness.record(plain.id)?.residency == .absent(.evicted))
        for kept in [essential, pinned, leased, recent] {
            #expect(await harness.isPresent(kept.id, at: kept.key), "\(kept.id.rawValue) is protected")
        }
    }

    @Test("R-CLN-4: evicting twice within the grace window frees no more than evicting once", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictingTwiceFreesNoMore() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(500), hysteresisTarget: 1))
        let assets = (0..<4).map { CleanupFixture.asset("x\($0)", seed: 50 + UInt64($0), count: 200) }
        try await EvictionTests.seedWithAccesses(harness, assets, recent: assets.map(\.id))
        let first = try await harness.store.evictIfNeeded()
        let second = try await harness.store.evictIfNeeded()
        #expect(first.bytesFreed == 400 && second.bytesFreed == 0, "the doomed bytes count as reclaimed while they wait for grace")
        let evicted = await assets.asyncFilter { await harness.record($0.id)?.residency == .absent(.evicted) }
        #expect(evicted.map(\.id) == [assets[0].id, assets[1].id])
    }

    /// The two budget shapes in which the doomed bytes, not the usage, decide a second run (store-2 S2-06).
    enum ReclaimBudget: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// No byte budget: free space plus pending reclaim falls 15,000 bytes short of the reserve.
        case reserve
        /// Half of usage plus free space plus pending reclaim: 25,000 bytes over 40,000 used.
        case fractionOfFreeSpace

        var testDescription: String {
            self.rawValue
        }

        /// The policy for a volume with `free` bytes free when the first run measures.
        func policy(free: Int64) -> StoragePolicy {
            switch self {
            case .reserve:
                return CleanupFixture.policy(reserveFreeBytes: free + 15_000, hysteresisTarget: 1)
            case .fractionOfFreeSpace:
                return CleanupFixture.policy(budget: .fractionOfFreeSpace(0.5), hysteresisTarget: 1)
            }
        }
    }

    /// Review round 3 (the S2-06 regression): with a byte budget, usage alone decides the second run, so only a budget
    /// that reads free space can tell whether the doomed bytes are counted. Four 10,000-byte assets; the first run must free
    /// 15,000 bytes and evicts the two least recently used (20,000). The doomed bytes stay on disk until the reaper runs,
    /// so free space has not grown: counted as pending reclaim they cover the reserve (`.reserve`) and keep the resolved
    /// budget at 25,000 (`.fractionOfFreeSpace`), so the second run evicts nothing. Without them it would evict again
    /// (mutant `effective = max(0, available)` in `EvictionOrder.bytesToFree`: two more, and one more).
    @Test(
        "R-CLN-4: pending reclaim decides a second eviction within the grace window, against a reserve and a fractional budget (store-2 S2-06)",
        .timeLimit(.minutes(1)),
        arguments: ReclaimBudget.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func pendingReclaimDecidesSecondRun(budget: ReclaimBudget) async throws {
        let assets = (0..<4).map { CleanupFixture.asset("r\($0)", seed: 90 + UInt64($0), count: 10_000) }
        // The same deterministic sequence on a large volume measures what this lifetime writes before the first run.
        let probe = CoreHarness.cleanup()
        try await EvictionTests.seedWithAccesses(probe, assets, recent: assets.map(\.id))
        let written = probe.fileSystem.configuration.importantCapacity - (try await probe.store.freeSpace().volumeImportant)
        // `.fractionOfFreeSpace` needs 10,000 bytes free at the first run (0.5 × (40,000 + 10,000) = 25,000).
        let capacity = budget == .fractionOfFreeSpace ? 10_000 + written : probe.fileSystem.configuration.importantCapacity
        let free = capacity - written
        let harness = CoreHarness.cleanup(policy: budget.policy(free: free), importantCapacity: capacity)
        try await EvictionTests.seedWithAccesses(harness, assets, recent: assets.map(\.id))
        let before = try await harness.store.freeSpace()
        #expect(before.volumeImportant == free && before.usedBytes == 40_000 && before.pendingReclaim == 0)
        let first = try await harness.store.evictIfNeeded()
        #expect(first.bytesFreed == 20_000 && first.filesRemoved == 2)
        let between = try await harness.store.freeSpace()
        #expect(between.usedBytes == 20_000 && between.pendingReclaim == 20_000, "the doomed bytes wait for the grace")
        #expect(between.volumeImportant <= free, "nothing was unlinked yet")
        let second = try await harness.store.evictIfNeeded()
        #expect(second == CleanupResult(), "the pending reclaim covers what the first run freed")
        let evicted = await assets.asyncFilter { await harness.record($0.id)?.residency == .absent(.evicted) }
        #expect(evicted.map(\.id) == [assets[0].id, assets[1].id])
    }

    /// What reaches the evicted asset's record while its doomed blob is still on disk.
    enum AfterEviction: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// `apply` of the same manifest (a sync that changed nothing).
        case apply
        /// `admit` of the entry, relocated.
        case admit
        /// A relaunch: launch adoption binds it again (crash recovery, ADR-018).
        case relaunch

        var testDescription: String {
            self.rawValue
        }
    }

    /// Review round 3 (OI-1, orchestrator ruling R3): `apply` adopted `absent(.evicted)` records and rescued their
    /// doomed blobs, so any sync within the deletion grace undid the eviction and maintenance could thrash. Evicted
    /// records are adopted only by the launch adoption now.
    @Test(
        "R-CLN-4: an apply or admit within the deletion grace never adopts an evicted asset again; only a relaunch does",
        .timeLimit(.minutes(1)),
        arguments: AfterEviction.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func evictionNotUndoneByApply(_ after: AfterEviction) async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)))
        let a = CleanupFixture.asset("a", seed: 96)
        try await harness.seed([a])
        harness.time.advance(by: 3_600)
        #expect(try await harness.store.evictIfNeeded().filesRemoved == 1)
        #expect(await harness.record(a.id)?.residency == .absent(.evicted) && harness.hasBlob(a.key))
        switch after {
        case .apply:
            let report = try await harness.store.apply(CoreFixture.manifest([a.entry]), etag: nil, eviction: nil)
            #expect(report.reused.isEmpty)
        case .admit:
            var moved = a.entry
            moved.localPathComponents = ["moved"]
            try await harness.store.admit(moved)
        case .relaunch:
            await harness.store.close()
            let reopened = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), policy: CleanupFixture.policy(budget: .bytes(0)), time: harness.time)
            _ = try await reopened.store.open()
            #expect(await reopened.isPresent(a.id, at: a.key), "launch adoption binds the evicted record to its blob (ADR-018)")
            #expect(await CoreInvariants.violations(of: reopened).isEmpty)
            return
        }
        #expect(await harness.record(a.id)?.residency == .absent(.evicted), "the eviction stands")
        guard case .doomed(let doom)? = await harness.state.core.blobTable[a.key] else {
            Issue.record("the evicted blob was rescued")
            return
        }
        #expect(doom.reason == .unreferenced)
        await harness.settleDeletions()
        let used = try await harness.store.freeSpace().usedBytes
        #expect(!harness.hasBlob(a.key) && used == 0)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-4: entries outside the retention scope are evicted first, whatever their last access", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func outsideScopeFirst() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(500), hysteresisTarget: 1))
        let old = CleanupFixture.asset("old", seed: 60, count: 200, tags: ["kept"])
        let newer = CleanupFixture.asset("newer", seed: 61, count: 200)
        let newest = CleanupFixture.asset("newest", seed: 62, count: 200, tags: ["kept"])
        try await EvictionTests.seedWithAccesses(harness, [old, newer, newest], recent: [newer.id, newest.id])
        await harness.store.setRetentionScope(.tags(["kept"]))
        _ = try await harness.store.evictIfNeeded()
        #expect(await harness.record(newer.id)?.residency == .absent(.evicted), "the entry outside the scope goes first")
        #expect(await harness.isPresent(old.id, at: old.key), "an older entry inside the scope stays")
    }

    @Test("R-CLN-4: a blob shared by two assets is evicted only together with both", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func sharedBlobEvictedTogether() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(250), hysteresisTarget: 1))
        let bytes = CoreFixture.bytes(70, count: 200)
        let first = CleanupFixture.Asset(entry: CoreFixture.entry("first", bytes), bytes: bytes)
        let second = CleanupFixture.Asset(entry: CoreFixture.entry("second", bytes), bytes: bytes)
        let other = CleanupFixture.asset("other", seed: 71, count: 100)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([first.entry, second.entry, other.entry]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [first.entry, second.entry], sequence: 1)
        try await harness.publish(other.bytes, [other.entry], sequence: 2)
        harness.time.advance(by: 60)
        _ = await harness.store.location(for: other.id, extensions: [], recordingAccess: true)
        harness.time.advance(by: 3_600)
        let plan = try #require(await harness.store.evictionPlan(toFree: 1, protecting: []))
        #expect(plan.victims.map(\.id) == [first.id, second.id] && plan.bytes == 200, "both records of the shared blob, counted once")
        let result = try await harness.store.evictIfNeeded()
        #expect(result.bytesFreed == 200)
        #expect(await harness.record(first.id)?.residency == .absent(.evicted))
        #expect(await harness.record(second.id)?.residency == .absent(.evicted))
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[first.key], .unreferenced))
    }

    @Test("R-SYN-11: the eviction dry run follows the eviction order, never names a protected id and is nil when unreachable", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func dryRun() async throws {
        let harness = CoreHarness.cleanup()
        #expect(await harness.store.evictionPlan(toFree: 1, protecting: []) == nil, "nothing to plan before open")
        let a = CleanupFixture.asset("a", seed: 80, count: 100)
        let b = CleanupFixture.asset("b", seed: 81, count: 200)
        let c = CleanupFixture.asset("c", seed: 82, count: 300)
        try await EvictionTests.seedWithAccesses(harness, [a, b, c], recent: [b.id, c.id])
        let before = await harness.state
        let plan = try #require(await harness.store.evictionPlan(toFree: 250, protecting: [b.id]))
        #expect(plan.victims.map(\.id) == [a.id, c.id] && plan.bytes == 400)
        let victim = try #require(plan.victims.first)
        #expect(victim == EvictionVictim(id: a.id, blob: a.key, byteSize: 100, lastAccess: try #require(before.core.records[a.id]).lastAccess))
        #expect(await harness.store.evictionPlan(toFree: 0, protecting: []) == EvictionPlan(victims: [], bytes: 0))
        #expect(await harness.store.evictionPlan(toFree: 601, protecting: []) == nil, "more than everything evictable")
        let after = await harness.state
        #expect(after.core.records == before.core.records && after.core.blobTable == before.core.blobTable, "a dry run mutates nothing")
    }

    @Test("R-SYN-11: apply evicts the plan's victims that are still evictable and skips one accessed since the plan", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func applyRevalidatesVictims() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 90, count: 100)
        let b = CleanupFixture.asset("b", seed: 91, count: 100)
        let n = CleanupFixture.asset("n", seed: 92, count: 100)
        try await EvictionTests.seedWithAccesses(harness, [a, b], recent: [])
        let plan = try #require(await harness.store.evictionPlan(toFree: 200, protecting: []))
        #expect(plan.victims.map(\.id) == [a.id, b.id])
        // `b` is read after the plan was made: the plan no longer applies to it.
        harness.time.advance(by: 1)
        _ = await harness.store.location(for: b.id, extensions: [], recordingAccess: true)
        let report = try await harness.store.apply(CoreFixture.manifest([a.entry, b.entry, n.entry]), etag: nil, eviction: plan)
        #expect(report.evicted == [a.id] && report.added == [n.id])
        #expect(await harness.record(a.id)?.residency == .absent(.evicted))
        #expect(await harness.isPresent(b.id, at: b.key))
        #expect(await harness.store.metrics().evictions == 1)
    }

    /// `apply`'s hook reads a plan as runs of victims naming one blob (the dry run lists a blob's records together, ADR
    /// draft C-22 cycle 6); a plan that names a blob in two places is grouped by key, so the shared blob still leaves
    /// with both its records, and the report keeps the plan's order.
    @Test("R-SYN-11: apply evicts a shared blob whose records its plan lists apart, and reports the evicted ids in plan order", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func applyPlanNamingBlobApart() async throws {
        let harness = CoreHarness.cleanup()
        let bytes = CoreFixture.bytes(73, count: 200)
        let first = CleanupFixture.Asset(entry: CoreFixture.entry("first", bytes), bytes: bytes)
        let second = CleanupFixture.Asset(entry: CoreFixture.entry("second", bytes), bytes: bytes)
        let other = CleanupFixture.asset("other", seed: 74, count: 100)
        _ = try await harness.store.open()
        let manifest = CoreFixture.manifest([first.entry, second.entry, other.entry])
        _ = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        try await harness.publish(bytes, [first.entry, second.entry], sequence: 1)
        try await harness.publish(other.bytes, [other.entry], sequence: 2)
        harness.time.advance(by: 3_600)
        let dryRun = try #require(await harness.store.evictionPlan(toFree: 300, protecting: []))
        let victims = Dictionary(uniqueKeysWithValues: dryRun.victims.map { ($0.id, $0) })
        let apart = try [first.id, other.id, second.id].map { try #require(victims[$0]) }
        let report = try await harness.store.apply(manifest, etag: nil, eviction: EvictionPlan(victims: apart, bytes: 300))
        #expect(report.evicted == [first.id, other.id, second.id])
        for id in [first.id, second.id, other.id] {
            #expect(await harness.record(id)?.residency == .absent(.evicted), "\(id.rawValue) is evicted")
        }
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[first.key], .unreferenced))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-4: pins persist across a reopen and keep an asset out of eviction until it is unpinned", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func pinsPersist() async throws {
        let policy = CleanupFixture.policy(budget: .bytes(0))
        let first = CoreHarness.cleanup(policy: policy)
        let a = CleanupFixture.asset("a", seed: 95)
        try await first.seed([a])
        try await first.store.setPinned([a.id, "unknown"], pinned: true)
        await first.store.close()
        let second = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), policy: policy, time: first.time)
        _ = try await second.store.open()
        #expect(await second.record(a.id)?.pinned == true)
        first.time.advance(by: 3_600)
        _ = try await second.store.evictIfNeeded()
        #expect(await second.isPresent(a.id, at: a.key))
        try await second.store.setPinned([a.id], pinned: false)
        _ = try await second.store.evictIfNeeded()
        #expect(await second.record(a.id)?.residency == .absent(.evicted))
    }

    @Test("R-CAR-5: setting the retention scope deletes and fetches nothing, works before open and shapes the adoption report", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func retentionScopeIsInert() async throws {
        let harness = CoreHarness.cleanup()
        await harness.store.setRetentionScope(.prefix("keep."))
        #expect(await harness.state.eviction.retentionScope == .prefix("keep."))
        let kept = CleanupFixture.asset("keep.a", seed: 96)
        let other = CleanupFixture.asset("other.b", seed: 97)
        try await harness.seed([kept, other])
        let mutations = harness.fileSystem.mutationCount
        await harness.store.setRetentionScope(.prefix("keep."))
        #expect(harness.fileSystem.mutationCount == mutations)
        #expect(await harness.isPresent(other.id, at: other.key))
        let report = try await harness.store.adoptionReport()
        #expect(report.excludedRemotePaths == [other.entry.remotePath])
    }

    @Test("R-SYN-11: eviction frees space while every index commit fails with ENOSPC", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictionUnderEnospc() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(250), hysteresisTarget: 1))
        let a = CleanupFixture.asset("a", seed: 100, count: 200)
        let b = CleanupFixture.asset("b", seed: 101, count: 200)
        let c = CleanupFixture.asset("c", seed: 102, count: 200)
        try await EvictionTests.seedWithAccesses(harness, [a, b, c], recent: [b.id, c.id])
        // `a` is pruned in a committed generation; then every index write runs out of space.
        _ = try await harness.store.apply(CoreFixture.manifest([b.entry, c.entry]), etag: nil, eviction: nil)
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        await #expect(throws: StoreError.fileSystem(.noSpace)) {
            _ = try await harness.store.evictIfNeeded()
        }
        #expect(await harness.record(b.id)?.residency == .absent(.evicted), "the eviction stays in memory, dirty")
        await harness.settleDeletions()
        #expect(!harness.hasBlob(a.key), "a doom already committed frees its bytes without a new commit")
        #expect(harness.hasBlob(b.key), "an eviction no generation holds yet deletes nothing")
        #expect(await harness.store.deletionBlocker(b.key) == .commit)
    }

    @Test("R-OBS-1: quota eviction runs inside exactly one eviction interval", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func evictionInterval() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)))
        try await EvictionTests.seedWithAccesses(harness, [CleanupFixture.asset("a", seed: 105)], recent: [])
        _ = try await harness.store.evictIfNeeded()
        let events = harness.tap.lines.compactMap(LogIntervalEvent.init(line:)).filter { $0.name == .eviction }
        #expect(events.map(\.phase) == [.began, .ended])
        #expect(events.allSatisfy { $0.category == .store })
    }
}

extension Array where Element: Sendable {
    /// The elements for which `predicate` holds, in order.
    func asyncFilter(_ predicate: (Element) async -> Bool) async -> [Element] {
        var kept: [Element] = []
        for element in self where await predicate(element) {
            kept.append(element)
        }
        return kept
    }
}
