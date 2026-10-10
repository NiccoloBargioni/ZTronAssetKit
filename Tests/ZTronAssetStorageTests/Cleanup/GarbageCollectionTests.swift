import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Staging GC and orphan GC (R-CLN-2, R-CLN-3; ADR-028, store.md §6.2–§6.3).
@Suite("Cleanup: staging and orphan garbage collection (R-CLN-2, R-CLN-3)")
struct GarbageCollectionTests {
    /// Writes a complete `.part` (and optionally its sidecar) for `entry` through the store's own sink.
    @available(macOS 15.0, iOS 18.0, *)
    @discardableResult
    static func stage(_ harness: CoreHarness, _ entry: ManifestEntry, bytes: Int, sequence: UInt32, sidecar: Bool = false) async throws -> StagingFileName {
        let staged = try await harness.stage(CoreFixture.bytes(UInt64(sequence), count: bytes), for: entry, sequence: sequence, sidecar: sidecar)
        return staged.name
    }

    /// The names under `staging/`.
    @available(macOS 15.0, iOS 18.0, *)
    static func stagingNames(_ harness: CoreHarness) throws -> Set<String> {
        Set(try harness.fileSystem.contentsOfDirectory(at: harness.layout.stagingDirectory).map(\.name))
    }

    @Test("R-CLN-3: staging GC removes unowned partial files at launch and after sync", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func stagingGC() async throws {
        let first = CoreHarness.cleanup()
        let claimed = CleanupFixture.asset("claimed", seed: 400)
        let unowned = CleanupFixture.asset("unowned", seed: 401)
        _ = try await first.store.open()
        let kept = try await GarbageCollectionTests.stage(first, claimed.entry, bytes: 100, sequence: 1)
        let orphan = try await GarbageCollectionTests.stage(first, unowned.entry, bytes: 200, sequence: 2, sidecar: true)
        try first.fileSystem.write(Data(repeating: 7, count: 30), to: first.layout.stagingDirectory.appendingPathComponent("junk.download"), mode: .truncate)
        await first.store.close()
        first.time.advance(by: 2 * 3_600)
        // At launch: the reconciler claims `claimed` only.
        let harness = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), time: first.time)
        _ = try await harness.store.open()
        let names = try GarbageCollectionTests.stagingNames(harness)
        let sidecarSize = try #require(try harness.fileSystem.itemInfo(at: harness.layout.stagingURL(orphan.with(kind: .sidecar)))).byteSize
        let result = try await harness.store.collectStaging(keeping: [claimed.entry.transferID])
        #expect(try GarbageCollectionTests.stagingNames(harness) == [kept.rawValue])
        #expect(names.count == 4 && result.filesRemoved == 3)
        #expect(result.bytesFreed == 200 + sidecarSize + 30)
        #expect(await harness.state.cleanup.lastCleanupAt == harness.time.now())
        let events = harness.tap.lines.compactMap(LogIntervalEvent.init(line:)).filter { $0.name == .gc }
        #expect(events.map(\.phase) == [.began, .ended], "R-OBS-1: the staging sweep runs inside one gc interval")
        // After a sync the transfer is no longer claimed, and its file is old: collected.
        let after = try await harness.store.collectStaging(keeping: [])
        let left = try GarbageCollectionTests.stagingNames(harness)
        #expect(after.filesRemoved == 1 && left.isEmpty)
    }

    @Test("R-CLN-3: a staged file handed off by a relaunched background session survives launch staging GC", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func handOffSurvives() async throws {
        let first = CoreHarness.cleanup()
        let reattached = CleanupFixture.asset("reattached", seed: 410)
        let delivered = CleanupFixture.asset("delivered", seed: 411)
        _ = try await first.store.open()
        // A background download started long ago, reattached after the relaunch (claimed, old).
        let old = try await GarbageCollectionTests.stage(first, reattached.entry, bytes: 100, sequence: 1)
        await first.store.close()
        first.time.advance(by: 10 * 3_600)
        let harness = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), time: first.time)
        _ = try await harness.store.open()
        // The OS moved a finished download into staging just before reconciliation; nobody claims it yet.
        let handedOff = try await GarbageCollectionTests.stage(harness, delivered.entry, bytes: 120, sequence: 2)
        let result = try await harness.store.collectStaging(keeping: [reattached.entry.transferID])
        #expect(result.filesRemoved == 0)
        #expect(try GarbageCollectionTests.stagingNames(harness) == [old.rawValue, handedOff.rawValue])
        // Past the claim grace an unclaimed file is garbage, and past the maximum age even a claimed one is.
        harness.time.advance(by: 3_601)
        _ = try await harness.store.collectStaging(keeping: [reattached.entry.transferID])
        #expect(try GarbageCollectionTests.stagingNames(harness) == [old.rawValue])
        harness.time.advance(by: 72 * 3_600)
        _ = try await harness.store.collectStaging(keeping: [reattached.entry.transferID])
        #expect(try GarbageCollectionTests.stagingNames(harness).isEmpty)
    }

    /// Writes `bytes` under its blob name on the fake, as a leftover of an earlier lifetime would be.
    @available(macOS 15.0, iOS 18.0, *)
    static func plantBlob(_ fileSystem: FakeFileSystem, _ bytes: Data, ext: String = "png") throws -> BlobKey {
        let key = CoreFixture.key(bytes, ext: ext)
        let url = CoreFixture.layout.blobURL(key)
        var missing: [URL] = []
        var directory = url.deletingLastPathComponent()
        while try fileSystem.itemInfo(at: directory) == nil {
            missing.append(directory)
            directory = directory.deletingLastPathComponent()
        }
        for directory in missing.reversed() {
            try fileSystem.createDirectory(at: directory)
        }
        try fileSystem.write(bytes, to: url, mode: .truncate)
        return key
    }

    @Test("R-CLN-2: orphan GC removes unreferenced blobs older than the orphan grace", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func orphanGC() async throws {
        let harness = CoreHarness.cleanup()
        let live = CleanupFixture.asset("live", seed: 420)
        let expected = CleanupFixture.asset("expected", seed: 421)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([live.entry, expected.entry]), etag: nil, eviction: nil)
        try await harness.publish(live.bytes, [live.entry])
        let old = try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(422, count: 250))
        // A record expects this one: a later apply or launch adopts it instead of downloading.
        let adoptable = try GarbageCollectionTests.plantBlob(harness.fileSystem, expected.bytes)
        harness.time.advance(by: 3_601)
        let young = try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(423, count: 50))
        let result = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(result == CleanupResult(bytesFreed: 250, filesRemoved: 1, bytesDeferred: 0))
        let sweptAt = harness.time.now()
        // Doomed, not unlinked (CCR-1): the reaper removes it after the deletion grace, under the I-3 protocol.
        let doom = await harness.state.core.blobTable[old]
        #expect(harness.hasBlob(old) && doom.map { if case .doomed(let info) = $0 { info.reason == .unreferenced } else { false } } == true)
        #expect(try await harness.store.freeSpace().pendingReclaim == 250, "the doomed orphan counts as pending reclaim")
        let reaped = await harness.settleDeletions()
        #expect(reaped.reapedKeys == 1 && reaped.reapedBytes == 250)
        #expect(!harness.hasBlob(old) && harness.hasBlob(young) && harness.hasBlob(adoptable) && harness.hasBlob(live.key))
        #expect(await harness.store.metrics().gcBytes == 250)
        #expect(await harness.state.cleanup.lastCleanupAt == sweptAt, "the sweep stamps; the reaper's unlink does not")
        let events = harness.tap.lines.compactMap(LogIntervalEvent.init(line:)).filter { $0.name == .gc }
        #expect(events.map(\.phase) == [.began, .ended], "R-OBS-1: the sweep runs inside one gc interval")
        // The protected orphan is adopted by the next manifest application.
        await harness.store.close()
        let reopened = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), time: harness.time)
        _ = try await reopened.store.open()
        #expect(await reopened.isPresent(expected.id, at: adoptable))
    }

    /// Since the L3 close-out orphan GC dooms (CCR-1), so an unlink that fails is the reaper's: the key stays doomed with
    /// backoff (ARCHITECTURE §4.4) and the others are reaped; a later GC run sees it doomed, not as an orphan.
    @Test("R-CLN-2: an orphan whose unlink keeps failing stays doomed with backoff and does not stop the others from being collected", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func failingOrphanDoesNotStopSweep() async throws {
        let harness = CoreHarness.cleanup(deletionBatchSize: 1)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        let planted = try (0..<3).map { try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(450 + UInt64($0), count: 100)) }.sorted()
        // The first orphan in sweep order cannot be unlinked, ever (EIO).
        let stuck = harness.layout.blobURL(planted[0]).lastPathComponent
        harness.fileSystem.addFault(FaultRule(operation: .removeItem, matching: URLMatcher(lastComponentSuffix: stuck), occurrence: .every, error: .io))
        harness.time.advance(by: 3_601)
        let result = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(result == CleanupResult(bytesFreed: 300, filesRemoved: 3, bytesDeferred: 0))
        let reaped = await harness.settleDeletions()
        #expect(reaped.reapedKeys == 2 && reaped.reapedBytes == 200)
        #expect(harness.hasBlob(planted[0]) && !harness.hasBlob(planted[1]) && !harness.hasBlob(planted[2]))
        guard case .doomed(let doom)? = await harness.state.core.blobTable[planted[0]] else {
            Issue.record("the stuck orphan left the blob table")
            return
        }
        #expect(doom.failedUnlinks == 1 && doom.reason == .unreferenced)
        // Doomed, so neither an orphan in the report nor swept again; the reaper retries it after its backoff.
        #expect(await harness.store.storageReport().orphanBytes == 0)
        let again = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(again == CleanupResult() && harness.hasBlob(planted[0]))
        harness.time.advance(by: AssetStore.unlinkBackoff(afterFailures: 1))
        _ = await harness.store.runDueWork()
        let attempts = harness.fileSystem.operations.filter { $0.kind == .removeItem && $0.url.lastPathComponent == stuck }
        #expect(attempts.count == 2 && attempts.allSatisfy { $0.failure == .io })
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-2: orphan GC deletes nothing while the store is degraded or before its listing completed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func orphanGCSuspended() async throws {
        let fileSystem = FakeFileSystem(time: ManualTimeSource())
        let planted = try GarbageCollectionTests.plantBlob(fileSystem, CoreFixture.bytes(430))
        let time = ManualTimeSource()
        // No index but a blob: the launch is degraded, so orphans are protected until the next apply (S1-11).
        let degraded = CoreHarness.cleanup(disk: fileSystem.survivingDisk(), time: time)
        #expect(try await degraded.store.open().degraded)
        time.advance(by: 2 * 3_600)
        #expect(try await degraded.store.collectGarbage(until: time.monotonicNow().adding(seconds: 60)) == CleanupResult())
        #expect(degraded.hasBlob(planted))
        // A deadline that has already passed stops the listing before any sweep.
        _ = try await degraded.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        #expect(try await degraded.store.collectGarbage(until: time.monotonicNow()) == CleanupResult())
        #expect(degraded.hasBlob(planted))
        let swept = try await degraded.store.collectGarbage(until: time.monotonicNow().adding(seconds: 60))
        #expect(swept.filesRemoved == 1 && degraded.hasBlob(planted))
        await degraded.settleDeletions()
        #expect(!degraded.hasBlob(planted))
    }

    /// store-2 S2-01 timeline B: the first of two publications of one key is superseded while the second waits for it;
    /// at no point may an orphan sweep see the key as unknown. The entries are checksum-less, so no record expects the
    /// key and only the blob table and `publishing` protect it (REENTRANCY R10); an orphan older than the grace already
    /// has the name, so a sweep that misses either mark removes it.
    @Test("R-CLN-2: a superseded publication never leaves its key unprotected while another publication of the same key is in flight", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func supersededPublicationKeepsKeyProtected() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let bytes = CoreFixture.bytes(440)
        let a = CoreFixture.entry("a", bytes, checksum: false)
        let b = CoreFixture.entry("b", bytes, checksum: false)
        let key = CoreFixture.key(bytes)
        let deadline = harness.time.monotonicNow().adding(seconds: 3 * 3_600)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, b]), etag: nil, eviction: nil)
        let stagedA = try await harness.stage(bytes, for: a, sequence: 1)
        let stagedB = try await harness.stage(bytes, for: b, sequence: 2)
        #expect(try GarbageCollectionTests.plantBlob(harness.fileSystem, bytes) == key)
        harness.time.advance(by: 2 * 3_600)
        #expect(await harness.record("b")?.expectedKey == nil, "no record expects the key")
        await metadata.setHolding(true)
        let publishA = Task {
            try await harness.store.publish(stagedA, binding: [a.identifier], expecting: a.contentIdentity, urgency: .bulk)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        await metadata.releaseNext()
        // A's placement unit is held: the key is in `publishing` only.
        try await metadata.requireHeldUnits(atLeast: 1)
        let placementA = try #require(await metadata.heldUnits.first)
        let placing = await harness.state.core
        #expect(placing.publishing.contains(key) && placing.blobTable[key] == nil)
        // (1) A complete sweep (listing and any removal units released, A's placement still held) keeps the name.
        let first = try await CleanupSteps.run(metadata, keeping: [placementA]) {
            try await harness.store.collectGarbage(until: deadline)
        }
        #expect(first.released.count >= 2, "the sweep listed blobs/ and its fan-out")
        #expect(first.value.filesRemoved == 0 && harness.content(harness.layout.blobURL(key)) == bytes, "publishing protects the key")
        // B waits for A's placement.
        let publishB = Task {
            try await harness.store.publish(stagedB, binding: [b.identifier], expecting: b.contentIdentity, urgency: .bulk)
        }
        try await CorePoll.until("B waits for A's placement") {
            for unit in await metadata.heldUnits where unit != placementA {
                await metadata.release(unit)
            }
            return await harness.state.core.keyWaiters[key]?.isEmpty == false
        }
        // The manifest changes A's content while A's placement runs.
        let changed = CoreFixture.entry("a", CoreFixture.bytes(441))
        _ = try await CleanupSteps.run(metadata, keeping: [placementA]) {
            try await harness.store.apply(CoreFixture.manifest([changed, b]), etag: nil, eviction: nil)
        }
        #expect(await harness.record("a")?.entry.checksum == changed.checksum)
        // A's placement finishes: A is superseded, and B takes the key over and holds its own placement unit.
        await metadata.release(placementA)
        await #expect(throws: StoreError.superseded("a")) {
            try await publishA.value
        }
        try await CorePoll.until("B's placement is held") {
            await !metadata.heldUnits.isEmpty
        }
        let placementB = try #require(await metadata.heldUnits.first)
        let rebinding = await harness.state.core
        #expect(rebinding.publishing.contains(key) || rebinding.blobTable[key] != nil, "the key is marked while B's placement runs")
        // (2) A second complete sweep at that point keeps the name too.
        let second = try await CleanupSteps.run(metadata, keeping: [placementB]) {
            try await harness.store.collectGarbage(until: deadline)
        }
        #expect(second.value.filesRemoved == 0 && harness.content(harness.layout.blobURL(key)) == bytes)
        await metadata.setHolding(false)
        let locations = try await publishB.value
        #expect(locations[b.identifier]?.url == harness.layout.blobURL(key))
        await harness.settleDeletions()
        let present = await harness.isPresent(b.identifier, at: key)
        #expect(harness.content(harness.layout.blobURL(key)) == bytes && present)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-2: orphan GC whose listing fails or is cancelled part way removes nothing, and the next run collects", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func partialListingRemovesNothing() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        let key = try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(470, count: 90))
        harness.time.advance(by: 3_601)
        let deadline = harness.time.monotonicNow().adding(seconds: 600)
        // A fan-out directory that cannot be listed: the run reports the error and decides nothing.
        harness.fileSystem.addFault(FaultRule(operation: .contentsOfDirectory, matching: URLMatcher(lastComponentSuffix: key.hash.fanOut), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            _ = try await harness.store.collectGarbage(until: deadline)
        }
        #expect(harness.hasBlob(key))
        // Cancelled after the top-level listing: no fan-out is listed and nothing is removed.
        await metadata.setHolding(true)
        let cancelled = Task {
            try await harness.store.collectGarbage(until: deadline)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        cancelled.cancel()
        await metadata.setHolding(false)
        await #expect(throws: StoreError.cancelled) {
            _ = try await cancelled.value
        }
        #expect(harness.hasBlob(key))
        let collected = try await harness.store.collectGarbage(until: deadline)
        #expect(collected.filesRemoved == 1)
        await harness.settleDeletions()
        #expect(!harness.hasBlob(key))
    }

    /// Releases the held metadata units one at a time until `first` is gone, then cancels `task` while the next removal
    /// unit (the one for `second`) is held, and lets everything run.
    @available(macOS 15.0, iOS 18.0, *)
    static func cancelDuringSecondRemoval(_ metadata: SteppedBlockingExecutor, _ harness: CoreHarness, first: URL, second: URL, task: Task<CleanupResult, any Error>) async throws {
        try await CorePoll.until("the first removal unit ran") {
            if !harness.exists(first) {
                return true
            }
            if let unit = await metadata.heldUnits.first {
                await metadata.release(unit)
            }
            return false
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        #expect(harness.exists(second), "the second removal unit is held")
        task.cancel()
        await metadata.setHolding(false)
    }

    /// Since the L3 close-out orphan GC dooms in the one turn after its decision unit (CCR-1), so a caller cancelled at
    /// any of its suspension points, the decision included, gets `.cancelled` with nothing doomed, counted or stamped.
    @Test("R-CLN-12: a cancelled orphan GC dooms, counts and stamps nothing, and the next run collects every orphan", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func cancelledOrphanGCAccounts() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(bulk: bulk)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        let keys = try (0..<3).map { try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(460 + UInt64($0), count: 100)) }.sorted()
        harness.time.advance(by: 3_601)
        let stamped = await harness.state.cleanup.lastCleanupAt
        await bulk.setHolding(true)
        let collect = Task {
            try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 600))
        }
        // The listing is complete and the decision unit is held: cancel the caller there.
        try await bulk.requireHeldUnits(atLeast: 1)
        collect.cancel()
        await bulk.setHolding(false)
        await bulk.releaseAll()
        await #expect(throws: StoreError.cancelled) {
            _ = try await collect.value
        }
        let state = await harness.state
        #expect(keys.allSatisfy { state.core.blobTable[$0] == nil && harness.hasBlob($0) }, "nothing was doomed")
        #expect(state.core.metrics.gcBytes == 0 && state.cleanup.lastCleanupAt == stamped)
        let collected = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 600))
        #expect(collected == CleanupResult(bytesFreed: 300, filesRemoved: 3, bytesDeferred: 0))
        #expect(await harness.store.metrics().gcBytes == 300)
        #expect(await harness.store.storageReport().lastCleanupAt == harness.time.now())
        await harness.settleDeletions()
        #expect(keys.allSatisfy { !harness.hasBlob($0) })
    }

    @Test("R-CLN-12: a cancelled staging GC keeps what it removed and stamps the cleanup", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func cancelledStagingGCStamps() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(deletionBatchSize: 1, metadata: metadata)
        _ = try await harness.store.open()
        let urls = ["a.junk", "b.junk", "c.junk"].map { harness.layout.stagingDirectory.appendingPathComponent($0) }
        for url in urls {
            try harness.fileSystem.write(Data(repeating: 1, count: 10), to: url, mode: .truncate)
        }
        await metadata.setHolding(true)
        let collect = Task {
            try await harness.store.collectStaging(keeping: [])
        }
        try await GarbageCollectionTests.cancelDuringSecondRemoval(metadata, harness, first: urls[0], second: urls[1], task: collect)
        await #expect(throws: StoreError.cancelled) {
            _ = try await collect.value
        }
        #expect(!harness.exists(urls[0]) && !harness.exists(urls[1]) && harness.exists(urls[2]))
        #expect(await harness.store.storageReport().lastCleanupAt == harness.time.now())
    }

    /// Where the orphan a sweep took is when the running `apply` reaches its adoption.
    enum SweptOrphan: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Still on disk: `apply` may bind it only if the sweep left it rescuable.
        case stillOnDisk
        /// Unlinked by the reaper once the grace passed: `apply` must not bind it.
        case reaped

        var testDescription: String {
            self.rawValue
        }
    }

    /// Review round 1 (ZProbe4, CCR-2): `apply` confirms a launch orphan in one unit and binds it only after its plan
    /// unit and write chunks; an orphan sweep in between removed the file, and the record was then bound to a missing
    /// blob (I-2). Closed at the L3 close-out (orchestrator rulings R1 and R2): the sweep dooms the orphan and forgets it
    /// as a launch orphan in the same turn, so `apply` rescues it while it is on disk and never binds it once reaped.
    @Test(
        "R-CLN-2: orphan GC never sweeps a launch orphan that a running apply is about to adopt",
        .timeLimit(.minutes(1)),
        arguments: SweptOrphan.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func sweepRacingApplyAdoption(_ swept: SweptOrphan) async throws {
        let x = CleanupFixture.asset("x", seed: 450)
        let first = CoreHarness.cleanup()
        _ = try await first.store.open()
        _ = try await first.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        await first.store.close()
        // A blob nobody knows lands in blobs/ while the app is not running, older than the orphan grace at the relaunch.
        let key = try GarbageCollectionTests.plantBlob(first.fileSystem, x.bytes)
        first.time.advance(by: 3_601)
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), time: first.time, bulk: bulk)
        _ = try await harness.store.open()
        let recorded = await harness.record(x.id)
        #expect(harness.hasBlob(key) && recorded == nil)
        // A manifest naming `x` arrives: apply confirms the orphan, then its plan unit is held.
        await bulk.setHolding(true)
        let apply = Task {
            try await harness.store.apply(CoreFixture.manifest([x.entry]), etag: nil, eviction: nil)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let plan = try #require(await bulk.heldUnits.first)
        // A complete sweep runs meanwhile (any unit of its own is released; the plan unit stays held).
        let sweep = try await CleanupSteps.run(bulk, keeping: [plan]) {
            try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        }
        if swept == .reaped {
            _ = try await CleanupSteps.run(bulk, keeping: [plan]) {
                await harness.settleDeletions()
            }
            #expect(!harness.hasBlob(key), "the reaper unlinked the swept orphan before apply's adoption")
        }
        await bulk.setHolding(false)
        await bulk.releaseAll()
        _ = try await apply.value
        let present = await harness.isPresent(x.id, at: key)
        let violations = await CoreInvariants.violations(of: harness)
        #expect(present == harness.hasBlob(key) && violations.isEmpty, "I-2: \(violations)")
        switch swept {
        case .stillOnDisk:
            #expect(sweep.value.filesRemoved == 0 || present, "a swept orphan still on disk is rescued, never lost")
            await harness.settleDeletions()
            #expect(await harness.isPresent(x.id, at: key) && harness.content(harness.layout.blobURL(key)) == x.bytes)
        case .reaped:
            let residency = await harness.record(x.id)?.residency
            #expect(!present && residency == .absent(.neverFetched), "a reaped orphan is never bound")
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// How a key can be on an orphan listing yet gone from the disk and from the blob table by the turn that dooms the
    /// sweep (review of the L3 close-out, ZProbe-phantom): a doom made then has no file, and a later adoption or
    /// publication rescues it without I/O (I-2 takes a rescuable doom's file as complete).
    enum PhantomRace: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Doomed by `apply` before the run; the reaper unlinks it after the listing saw its file.
        case reapedDoom
        /// An unknown orphan an overlapping run dooms; the reaper unlinks it after this run's listing saw its file.
        case overlappingRun
        /// A launch orphan `apply` adopts and then drops, and the reaper unlinks, all after this run's listing saw it.
        case adoptedAndReaped

        var testDescription: String {
            self.rawValue
        }
    }

    /// The first asset, from `seed` on, whose blob lies in a fan-out directory `accepts` takes (the listing visits the
    /// fan-outs in name order, so a test can hold the unit after a given one).
    static func asset(_ id: String, from seed: UInt64, fanOut accepts: (String) -> Bool) -> CleanupFixture.Asset {
        var seed = seed
        while !accepts(CleanupFixture.asset(id, seed: seed).key.hash.fanOut) {
            seed += 1
        }
        return CleanupFixture.asset(id, seed: seed)
    }

    @Test(
        "R-CLN-2: orphan GC never dooms a key whose file the reaper removed after the listing saw it",
        .timeLimit(.minutes(1)),
        arguments: PhantomRace.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func noPhantomDoom(_ race: PhantomRace) async throws {
        let gone = GarbageCollectionTests.asset("gone", from: 470) { $0 < "f0" }
        let keep = GarbageCollectionTests.asset("keep", from: 480) { $0 > gone.key.hash.fanOut }
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness: CoreHarness
        switch race {
        case .reapedDoom:
            harness = CoreHarness.cleanup(metadata: metadata)
            try await harness.seed([gone, keep])
            // Doomed; the install of this apply starts its grace, and only a fresh acknowledgement is missing.
            _ = try await harness.store.apply(CoreFixture.manifest([keep.entry]), etag: nil, eviction: nil)
        case .overlappingRun:
            harness = CoreHarness.cleanup(metadata: metadata)
            try await harness.seed([keep])
            _ = try GarbageCollectionTests.plantBlob(harness.fileSystem, gone.bytes)
        case .adoptedAndReaped:
            let first = CoreHarness.cleanup()
            try await first.seed([keep])
            await first.store.close()
            _ = try GarbageCollectionTests.plantBlob(first.fileSystem, gone.bytes)
            harness = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), time: first.time, metadata: metadata)
            _ = try await harness.store.open()
        }
        harness.time.advance(by: 3_601)
        let deadline = harness.time.monotonicNow().adding(seconds: 60)
        // The run lists gone's fan-out (the launch's own listing is before `mark`); its next listing unit (keep's fan-out)
        // is held.
        let mark = harness.fileSystem.operations.count
        await metadata.setHolding(true)
        let run = Task {
            try await harness.store.collectGarbage(until: deadline)
        }
        let fanOut = gone.key.hash.fanOut
        try await CorePoll.until("the run listed gone's fan-out") {
            if harness.fileSystem.operations.dropFirst(mark).contains(where: { $0.kind == .contentsOfDirectory && $0.url.lastPathComponent == fanOut }) {
                return true
            }
            if let next = await metadata.heldUnits.first {
                await metadata.release(next)
            }
            return false
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let held = Set(await metadata.heldUnits)
        switch race {
        case .reapedDoom:
            break
        case .overlappingRun:
            let second = try await CleanupSteps.run(metadata, keeping: held) {
                try await harness.store.collectGarbage(until: deadline)
            }
            #expect(second.value == CleanupResult(), "a run while another one is in flight returns at once")
        case .adoptedAndReaped:
            _ = try await CleanupSteps.run(metadata, keeping: held) {
                try await harness.store.apply(CoreFixture.manifest([keep.entry, gone.entry]), etag: nil, eviction: nil)
            }
            #expect(await harness.isPresent(gone.id, at: gone.key), "apply adopted the launch orphan")
            _ = try await CleanupSteps.run(metadata, keeping: held) {
                try await harness.store.apply(CoreFixture.manifest([keep.entry]), etag: nil, eviction: nil)
            }
        }
        _ = try await CleanupSteps.run(metadata, keeping: held) {
            // gone's grace already ended before the run: the fresh acknowledgement alone lets the reaper unlink it, with
            // no time passing during the run.
            race == .reapedDoom ? await harness.store.runDueWork() : await harness.settleDeletions()
        }
        if race != .overlappingRun {
            #expect(!harness.hasBlob(gone.key), "the reaper unlinked gone's file after the listing saw it")
        }
        await metadata.setHolding(false)
        await metadata.releaseAll()
        let result = try await run.value
        let doomed = await harness.state.core.blobTable[gone.key] != nil
        #expect(!doomed || harness.hasBlob(gone.key), "no doom without its file")
        #expect(result.filesRemoved == (race == .overlappingRun ? 1 : 0))
        // A manifest naming gone again: a doom without its file would be rescued onto a missing blob.
        _ = try await harness.store.apply(CoreFixture.manifest([keep.entry, gone.entry]), etag: nil, eviction: nil)
        let violations = await CoreInvariants.violations(of: harness)
        #expect(violations.isEmpty, "I-2: \(violations)")
        #expect(await harness.isPresent(gone.id, at: gone.key) == harness.hasBlob(gone.key))
    }

    /// C2 (review of the L3 close-out: one turn dooming 10,000 swept orphans held the actor 9.7 ms, 107 ms at
    /// `maxEntries`): the sweep dooms in chunks of `CleanupState.chunk` keys and releases the actor in between, and every
    /// later chunk is decided again, the reap window included (REENTRANCY R10 amendment).
    @Test(
        "R-CLN-2: orphan GC dooms in chunks with the actor released in between, and a chunk after the reap window opened dooms nothing",
        .timeLimit(.minutes(1))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func sweepChunksReleaseActor() async throws {
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
        // Every listing unit runs; the first metadata unit after them is the release between the first two chunks.
        try await CorePoll.until("the listing completed") {
            if harness.fileSystem.operations.dropFirst(mark).filter({ $0.kind == .contentsOfDirectory }).count == listings {
                return true
            }
            if let next = await metadata.heldUnits.first {
                await metadata.release(next)
            }
            return false
        }
        try await CorePoll.until("the sweep released the actor, or dooming every orphan in one turn") {
            let doomedLast = await harness.state.core.blobTable[planted[2]] != nil
            return !(await metadata.heldUnits.isEmpty) || doomedLast
        }
        let held = Set(await metadata.heldUnits)
        let table = await harness.state.core.blobTable
        #expect(!held.isEmpty && table[planted[0]] != nil && table[planted[1]] == nil && table[planted[2]] == nil, "one chunk doomed, then the actor is free")
        // Meanwhile the deletion grace passes and an install is acknowledged: the first chunk's doom is reaped, and a key
        // the store learnt since the run began could have been too, so no later chunk dooms anything.
        _ = try await CleanupSteps.run(metadata, keeping: held) {
            await harness.settleDeletions()
        }
        await metadata.setHolding(false)
        await metadata.releaseAll()
        let result = try await run.value
        #expect(result == CleanupResult(bytesFreed: 100, filesRemoved: 1, bytesDeferred: 0))
        #expect(!harness.hasBlob(planted[0]) && harness.hasBlob(planted[1]) && harness.hasBlob(planted[2]))
        #expect(await harness.store.storageReport().orphanBytes == 200, "the rest are still orphans")
        let again = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(again == CleanupResult(bytesFreed: 200, filesRemoved: 2, bytesDeferred: 0), "the next run collects them")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
