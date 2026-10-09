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
        try fileSystem.createDirectory(at: url.deletingLastPathComponent())
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
    /// at no point may an orphan sweep see the key as unknown.
    @Test("R-CLN-2: a superseded publication never leaves its key unprotected while another publication of the same key is in flight", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func supersededPublicationKeepsKeyProtected() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let bytes = CoreFixture.bytes(440)
        let a = CoreFixture.entry("a", bytes)
        let b = CoreFixture.entry("b", bytes)
        let key = CoreFixture.key(bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, b]), etag: nil, eviction: nil)
        let stagedA = try await harness.stage(bytes, for: a, sequence: 1)
        let stagedB = try await harness.stage(bytes, for: b, sequence: 2)
        // The staged bytes are old, so the orphan grace would not protect the key by itself.
        harness.time.advance(by: 2 * 3_600)
        await metadata.setHolding(true)
        let publishA = Task {
            try await harness.store.publish(stagedA, binding: [a.identifier], expecting: a.contentIdentity, urgency: .bulk)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        await metadata.releaseNext()
        // A's placement unit is held: the key is in `publishing`, not in the blob table.
        try await metadata.requireHeldUnits(atLeast: 1)
        #expect(await harness.state.core.publishing.contains(key))
        let publishB = Task {
            try await harness.store.publish(stagedB, binding: [b.identifier], expecting: b.contentIdentity, urgency: .bulk)
        }
        try await metadata.requireHeldUnits(atLeast: 2)
        await metadata.release(try #require(await metadata.heldUnits.last))
        try await CorePoll.until("B waits for A's placement") {
            await harness.state.core.keyWaiters[key]?.isEmpty == false
        }
        // The manifest changes A's content while A's placement runs.
        let changed = CoreFixture.entry("a", CoreFixture.bytes(441))
        let apply = Task {
            try await harness.store.apply(CoreFixture.manifest([changed, b]), etag: nil, eviction: nil)
        }
        try await CorePoll.until("A's entry changed") {
            await harness.record("a")?.entry.checksum == changed.checksum
        }
        let collect = Task {
            try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 600))
        }
        await metadata.setHolding(false)
        await #expect(throws: StoreError.superseded("a")) {
            try await publishA.value
        }
        let locations = try await publishB.value
        _ = try await apply.value
        let collected = try await collect.value
        #expect(locations[b.identifier]?.url == harness.layout.blobURL(key))
        #expect(collected.filesRemoved == 0, "the key was never unknown to the sweep")
        #expect(harness.content(harness.layout.blobURL(key)) == bytes)
        await harness.settleDeletions()
        let present = await harness.isPresent(b.identifier, at: key)
        #expect(harness.content(harness.layout.blobURL(key)) == bytes && present)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}
