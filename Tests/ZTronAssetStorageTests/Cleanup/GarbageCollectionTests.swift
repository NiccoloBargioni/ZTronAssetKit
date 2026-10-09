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
        #expect(!harness.hasBlob(old) && harness.hasBlob(young) && harness.hasBlob(adoptable) && harness.hasBlob(live.key))
        #expect(await harness.store.metrics().gcBytes == 250)
        #expect(await harness.state.cleanup.lastCleanupAt == harness.time.now())
        let events = harness.tap.lines.compactMap(LogIntervalEvent.init(line:)).filter { $0.name == .gc }
        #expect(events.map(\.phase) == [.began, .ended], "R-OBS-1: the sweep runs inside one gc interval")
        // The protected orphan is adopted by the next manifest application.
        await harness.store.close()
        let reopened = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), time: harness.time)
        _ = try await reopened.store.open()
        #expect(await reopened.isPresent(expected.id, at: adoptable))
    }

    @Test("R-CLN-2: an orphan whose removal keeps failing does not stop orphan GC from collecting the others", .timeLimit(.minutes(1)))
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
        #expect(result == CleanupResult(bytesFreed: 200, filesRemoved: 2, bytesDeferred: 0))
        #expect(harness.hasBlob(planted[0]) && !harness.hasBlob(planted[1]) && !harness.hasBlob(planted[2]))
        // The stuck one is still an orphan: the report counts it and the next run tries it again.
        #expect(await harness.store.storageReport().orphanBytes == 100)
        let again = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        #expect(again == CleanupResult() && harness.hasBlob(planted[0]))
        let attempts = harness.fileSystem.operations.filter { $0.kind == .removeItem && $0.url.lastPathComponent == stuck }
        #expect(attempts.count == 2 && attempts.allSatisfy { $0.failure == .io })
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
        #expect(swept.filesRemoved == 1 && !degraded.hasBlob(planted))
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
        #expect(collected.filesRemoved == 1 && !harness.hasBlob(key))
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

    @Test("R-CLN-12: a cancelled orphan GC keeps what it removed, counts it and stamps the cleanup", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func cancelledOrphanGCAccounts() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(deletionBatchSize: 1, metadata: metadata)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        let keys = try (0..<3).map { try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(460 + UInt64($0), count: 100)) }.sorted()
        let urls = keys.map { harness.layout.blobURL($0) }
        harness.time.advance(by: 3_601)
        await metadata.setHolding(true)
        let collect = Task {
            try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 600))
        }
        try await GarbageCollectionTests.cancelDuringSecondRemoval(metadata, harness, first: urls[0], second: urls[1], task: collect)
        await #expect(throws: StoreError.cancelled) {
            _ = try await collect.value
        }
        #expect(!harness.exists(urls[0]) && !harness.exists(urls[1]) && harness.exists(urls[2]), "the held unit ran; no unit started after the cancellation")
        #expect(await harness.store.metrics().gcBytes == 200)
        #expect(await harness.store.storageReport().lastCleanupAt == harness.time.now())
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

    /// Review round 1 (ZProbe4): `apply` confirms a launch orphan in one unit and binds it only after its plan unit and
    /// write chunks; an orphan sweep in between removes the file, and the record is then bound to a missing blob (I-2).
    /// Closing it needs WP-B's `adoptKnownBlob` to re-read the orphan table (CCR-2 in docs/adr-drafts/c.md): until then
    /// this is a known issue, and the test fails as soon as the race is closed, so the wrapper is removed with the fix.
    @Test("R-CLN-2: orphan GC never sweeps a launch orphan that a running apply is about to adopt", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func sweepRacingApplyAdoption() async throws {
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
        let swept = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        await bulk.setHolding(false)
        _ = try await apply.value
        let present = await harness.isPresent(x.id, at: key)
        let violations = await CoreInvariants.violations(of: harness)
        withKnownIssue("CCR-2: apply binds a launch orphan the sweep removed meanwhile") {
            #expect(swept.filesRemoved == 0 || !present, "a swept orphan is never bound")
            #expect(present == harness.hasBlob(key) && violations.isEmpty, "I-2: \(violations)")
        }
    }
}
