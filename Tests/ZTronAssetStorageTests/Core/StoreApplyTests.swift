import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

@Suite("Core: manifest application and launch reconciliation")
struct StoreApplyTests {
    @Test("R-CLN-1: a directory change is an index edit with zero file operations on blobs", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func relocationIsAnIndexEdit() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(160)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let before = try #require(try await harness.publish(bytes, [entry])[entry.identifier])
        try await harness.store.flush(.ordered)
        var moved = entry
        moved.localPathComponents = ["elsewhere", "deeper"]
        moved.remotePath = "media/new/a.png"
        let start = harness.fileSystem.operations.count
        let report = try await harness.store.apply(CoreFixture.manifest([moved]), etag: nil, eviction: nil)
        #expect(report.relocated == [entry.identifier] && report.contentChanged.isEmpty && report.added.isEmpty)
        #expect(!harness.fileSystem.operations[start...].contains { $0.url.path.hasPrefix(harness.layout.blobsDirectory.path) })
        #expect(await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == before)
        #expect(try await harness.store.planningView().records[entry.identifier]?.revision == 1)
    }

    @Test("R-CLN-1: prune keeps a blob still referenced by another identifier", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func pruneKeepsSharedBlob() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(161)
        let a = CoreFixture.entry("a", bytes)
        let b = CoreFixture.entry("b", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, b]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a, b])
        let report = try await harness.store.apply(CoreFixture.manifest([b]), etag: nil, eviction: nil)
        #expect(report.pruned == [a.identifier])
        harness.time.advance(by: 3_600)
        _ = await harness.store.runDueWork()
        #expect(harness.content(harness.layout.blobURL(CoreFixture.key(bytes))) == bytes)
        #expect(await harness.state.core.blobTable[CoreFixture.key(bytes)] == .live(references: 1))
    }

    @Test("R-CLN-1: a key moving from a removed identifier to an added one is adopted before the prune, never doomed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func renamedIdentifierAdoptsTheBlob() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(162)
        let old = CoreFixture.entry("old.name", bytes)
        let new = CoreFixture.entry("new.name", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([old]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [old])
        let report = try await harness.store.apply(CoreFixture.manifest([new]), etag: nil, eviction: nil)
        #expect(report.added == [new.identifier] && report.pruned == [old.identifier] && report.reused == [new.identifier])
        let state = await harness.state.core
        #expect(state.blobTable[CoreFixture.key(bytes)] == .live(references: 1))
        #expect(state.presentTable[new.identifier] != nil && state.presentTable[old.identifier] == nil)
        harness.time.advance(by: 3_600)
        _ = await harness.store.runDueWork()
        #expect(harness.exists(harness.layout.blobURL(CoreFixture.key(bytes))))
        #expect(!harness.mutations.contains { $0.kind == .removeItem && $0.url.path.hasPrefix(harness.layout.blobsDirectory.path) })
    }

    @Test("R-SYN-8: a content change keeps serving the stale blob, ends failed and quarantined states and resets the integrity history", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func contentChanges() async throws {
        let harness = CoreHarness.make()
        let a = CoreFixture.bytes(163)
        let entries = [CoreFixture.entry("a", a), CoreFixture.entry("b", CoreFixture.bytes(164)), CoreFixture.entry("c", CoreFixture.bytes(165))]
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
        try await harness.publish(a, [entries[0]])
        await harness.store.setResidency(.failed(.integrity), of: "b", dooming: .unreferenced)
        await harness.store.setResidency(.quarantined(until: harness.time.now().addingTimeInterval(60)), of: "c", dooming: .unreferenced)
        await harness.store.testSetIntegrity("c", IntegrityHistory(attempts: 2, failedIdentity: entries[2].contentIdentity, nextEligibleAt: harness.time.now()))
        let changed = [CoreFixture.entry("a", CoreFixture.bytes(166)), CoreFixture.entry("b", CoreFixture.bytes(167)), CoreFixture.entry("c", CoreFixture.bytes(168))]
        let report = try await harness.store.apply(CoreFixture.manifest(changed), etag: ETag(rawValue: "\"2\""), eviction: nil)
        #expect(report.contentChanged == ["a", "b", "c"])
        let location = try #require(await harness.store.location(for: "a", extensions: [], recordingAccess: false))
        #expect(location.isStale && harness.content(location.url) == a)
        let records = try await harness.store.planningView().records
        #expect(records["b"]?.residency == .absent(.neverFetched) && records["c"]?.residency == .absent(.neverFetched))
        #expect(records["c"]?.integrity == .clean && records["a"]?.revision == 1)
        #expect(await harness.store.availability(of: .all).stale == 1)
    }

    @Test("R-STO-4: with no valid index the store rebuilds from blob names and the next manifest without re-downloading verified assets", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func rebuildFromBlobNames() async throws {
        let harness = CoreHarness.make()
        let a = CoreFixture.bytes(170)
        let b = CoreFixture.bytes(171)
        let entries = [CoreFixture.entry("a", a), CoreFixture.entry("b", b)]
        _ = try await harness.store.open()
        let manifest = CoreFixture.manifest(entries)
        _ = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        try await harness.publish(a, [entries[0]], sequence: 1)
        try await harness.publish(b, [entries[1]], sequence: 2)
        await harness.store.close()
        var disk = harness.fileSystem.survivingDisk()
        for file in IndexFile.allCases {
            disk.purge(harness.layout.indexURL(file).path)
        }
        let reopened = CoreHarness.make(disk: disk)
        let report = try await reopened.store.open()
        #expect(report.degraded && report.missingBlobs == 0)
        #expect(await reopened.state.core.orphans.count == 2)
        let applied = try await reopened.store.apply(manifest, etag: nil, eviction: nil)
        #expect(Set(applied.reused) == ["a", "b"] && Set(applied.added) == ["a", "b"])
        #expect(await reopened.state.core.degraded == false)
        for (entry, bytes) in zip(entries, [a, b]) {
            let location = try #require(await reopened.store.location(for: entry.identifier, extensions: [], recordingAccess: false))
            #expect(reopened.content(location.url) == bytes)
        }
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
    }

    @Test("R-SYN-8: applying the same manifest twice is a no-op the second time", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func applyIsIdempotent() async throws {
        let harness = CoreHarness.make()
        let manifest = CoreFixture.manifest([CoreFixture.entry("a", CoreFixture.bytes(172))])
        _ = try await harness.store.open()
        let first = try await harness.store.apply(manifest, etag: ETag(rawValue: "\"x\""), eviction: nil)
        let commits = await harness.store.metrics().commits
        let installs = await harness.sink.offeredKeys.count
        let second = try await harness.store.apply(manifest, etag: ETag(rawValue: "\"x\""), eviction: nil)
        #expect(second == ApplyReport(generation: first.generation))
        #expect(await harness.store.metrics().commits == commits)
        #expect(await harness.sink.offeredKeys.count == installs)
    }

    @Test("R-STO-2: markSynced refuses a stamp from before a purge and markSyncDue clears the stamp", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func stamps() async throws {
        let harness = CoreHarness.make()
        let manifest = CoreFixture.manifest([])
        _ = try await harness.store.open()
        let stamp = SyncStamp(appVersion: "1", completedAt: harness.time.now(), manifestETag: nil, manifestDigest: manifest.digest)
        await harness.store.testBumpPurgeEpoch()
        await #expect(throws: StoreError.purgeRaced) {
            try await harness.store.markSynced(stamp, ifPurgeEpoch: 0)
        }
        try await harness.store.markSynced(stamp, ifPurgeEpoch: 1)
        #expect(try await harness.store.planningView().stamp == stamp)
        try await harness.store.markSyncDue()
        let view = try await harness.store.planningView()
        #expect(view.stamp == nil && view.syncDue)
        await harness.store.close()
        let reopened = CoreHarness.make(disk: harness.fileSystem.survivingDisk())
        #expect(try await reopened.store.open().syncDue)
    }

    @Test("R-SEC-2: symbolic links and foreign names under blobs are removed at launch and never followed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func foreignNamesRemoved() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(173)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [entry])
        await harness.store.close()
        let next = CoreHarness.make(disk: harness.fileSystem.survivingDisk())
        let blobs = next.layout.blobsDirectory
        let key = CoreFixture.key(bytes)
        let outside = URL(fileURLWithPath: "/fake-volume/precious.bin")
        try next.fileSystem.write(Data([9, 9]), to: outside, mode: .truncate)
        let fanOut = next.layout.fanOutDirectory(for: key.hash)
        let foreign = [
            blobs.appendingPathComponent("notablob.txt"),
            fanOut.appendingPathComponent("UPPER.png"),
            blobs.appendingPathComponent("zz", isDirectory: true),
        ]
        try next.fileSystem.write(Data([1]), to: foreign[0], mode: .truncate)
        try next.fileSystem.write(Data([2]), to: foreign[1], mode: .truncate)
        try next.fileSystem.createDirectory(at: foreign[2])
        let wrongFanOut = blobs.appendingPathComponent(key.hash.fanOut == "00" ? "01" : "00", isDirectory: true)
        try next.fileSystem.createDirectory(at: wrongFanOut)
        try next.fileSystem.write(bytes, to: wrongFanOut.appendingPathComponent(key.fileName), mode: .truncate)
        let link = fanOut.appendingPathComponent(String(repeating: "f", count: 64) + ".png")
        try next.fileSystem.createSymbolicLink(at: link, destination: outside.path)
        _ = try await next.store.open()
        for url in foreign + [wrongFanOut.appendingPathComponent(key.fileName), link] {
            #expect(!next.exists(url), "\(url.path) survived")
        }
        #expect(next.content(outside) == Data([9, 9]), "the link's target is untouched")
        #expect(next.content(next.layout.blobURL(key)) == bytes)
        #expect(await CoreInvariants.violations(of: next).isEmpty)
    }
}

extension AssetStore {
    /// Writes a record's integrity history the way WP-C's `recordIntegrityFailure` will (test seam).
    func testSetIntegrity(_ id: AssetID, _ history: IntegrityHistory) {
        self.state.core.records[id]?.integrity = history
        self.markDirty(.soon)
    }

    /// Bumps the purge epoch the way WP-C's `purge` will (test seam).
    func testBumpPurgeEpoch() {
        self.state.core.purgeEpoch += 1
    }
}
