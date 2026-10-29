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

    /// S3-CONF-06 (Stage 3): when an apply changes an asset's checksum to bytes another asset already holds,
    /// `adoptKnownBlob` binds the record to that live blob, and its release of the record's previous blob is the only
    /// thing that ever schedules that blob for pruning; no test reached it before.
    @Test(
        "R-CLN-1: a content change onto bytes another asset holds adopts them without a download and prunes the old blob after grace",
        .timeLimit(.minutes(1))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func contentChangeOntoLiveBlob() async throws {
        let harness = CoreHarness.make()
        let x = CoreFixture.bytes(4_601, count: 400)
        let y = CoreFixture.bytes(4_602, count: 380)
        let v1 = [CoreFixture.entry("a", x), CoreFixture.entry("z", y)]
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(v1, etagSeed: "v1"), etag: nil, eviction: nil)
        try await harness.publish(x, [v1[0]], sequence: 1)
        try await harness.publish(y, [v1[1]], sequence: 2)
        try await harness.store.flush(.durable)
        let oldKey = CoreFixture.key(x)
        let sharedKey = CoreFixture.key(y)
        let v2 = [CoreFixture.entry("a", y), CoreFixture.entry("z", y)]
        _ = try await harness.store.apply(CoreFixture.manifest(v2, etagSeed: "v2"), etag: nil, eviction: nil)
        // Adopted from the live blob: present, not stale, serving y, with nothing downloaded.
        let location = try #require(await harness.store.location(for: "a", extensions: [], recordingAccess: false))
        #expect(!location.isStale && location.url == harness.layout.blobURL(sharedKey) && harness.content(location.url) == y)
        #expect(await harness.state.core.blobTable[sharedKey] == .live(references: 2))
        // The old blob is released to the reaper: doomed `unreferenced`, still on disk until the grace passed (I-3).
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[oldKey], .unreferenced), "a's old blob was never released")
        #expect(harness.exists(harness.layout.blobURL(oldKey)), "no blob is unlinked before the grace")
        await harness.reapAfterGrace()
        try await harness.store.flush(.durable)
        #expect(!harness.exists(harness.layout.blobURL(oldKey)), "the blob no record references any more is never reaped")
        let oldState = await harness.state.core.blobTable[oldKey]
        #expect(oldState == nil, "the old blob is still \(String(describing: oldState))")
        #expect(harness.content(harness.layout.blobURL(sharedKey)) == y)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
        await harness.store.close()
    }

    /// OI-14 (Stage 3 S3B-9): bytes another release doomed while a maintenance eviction awaited count toward its need
    /// (`EvictionState.releasedBytes`, C-2); `apply`'s prune dooms through WP-B's own release path, which counted
    /// nothing, so a run overlapping a pruning `apply` freed up to the pruned bytes more than needed. WP-C's overlap
    /// fixture: ten 100-byte assets against a budget of 500, a run alone evicts six (`o0` … `o5`).
    @Test("R-CLN-4: bytes a pruning apply dooms while quota eviction computes its candidates count toward its need", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func pruneWhileEvictionCandidatesRun() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        // The run measured 550 bytes to free and waits in its candidates unit.
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        // A sync meanwhile drops the two most recently used assets from the manifest: their 200 bytes leave usedBytes.
        let kept = Array(EvictionOverlapTests.assets.prefix(8))
        let report = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(kept.map(\.entry), etagSeed: "pruned"), etag: nil, eviction: nil)
        }.value
        #expect(report.pruned.sorted() == EvictionOverlapTests.assets.suffix(2).map(\.id).sorted())
        await bulk.setHolding(false)
        let result = try await maintenance.value
        #expect(result == CleanupResult(bytesFreed: 400, filesRemoved: 4), "350 of the 550 bytes it measured were still needed")
        let evicted = await EvictionOverlapTests.evicted(harness)
        #expect(evicted == Array(0..<4), "the prune's 200 bytes and four evictions free what one run alone frees")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Stage 3 S3B-9, close-out cycle 2: a release `apply` counts toward an overlapping eviction's need must stay
    /// released. Swapping the contents of `o8` and `o9` makes both adoption candidates: `o8` adopts `o9`'s blob and
    /// releases its own (doomed, counted), then `o9` adopts that very blob back (rescued) and releases the other one
    /// (still referenced). Nothing left `usedBytes`, so the run must free what it measured, as it does alone afterwards.
    @Test("R-CLN-4: a content swap between present assets while quota eviction computes its candidates releases nothing, so the run still frees what it measured", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func swapWhileEvictionCandidatesRun() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        let before = try await harness.store.freeSpace()
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        // The run measured 550 bytes to free and waits in its candidates unit.
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        var entries = EvictionOverlapTests.assets.map(\.entry)
        (entries[8].checksum, entries[9].checksum) = (entries[9].checksum, entries[8].checksum)
        let swapped = entries
        let report = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(swapped, etagSeed: "swapped"), etag: nil, eviction: nil)
        }.value
        #expect(report.reused.sorted() == [EvictionOverlapTests.assets[8].id, EvictionOverlapTests.assets[9].id].sorted())
        #expect(try await harness.store.freeSpace().usedBytes == before.usedBytes, "the swap leaves usedBytes unchanged")
        await bulk.setHolding(false)
        let result = try await maintenance.value
        #expect(result == CleanupResult(bytesFreed: 600, filesRemoved: 6), "nothing left usedBytes: the 550 bytes it measured were all still needed")
        #expect(await EvictionOverlapTests.evicted(harness) == Array(0..<6))
        #expect(try await harness.store.freeSpace().usedBytes <= 450, "down to the hysteresis target (90 % of 500)")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Stage 3 S3B-9, close-out cycle 2: `adoptKnownBlob`'s release of a record's previous blob counts as the prune's
    /// does. `o9`'s content moves onto `o8`'s bytes: `o9` adopts them and its old blob is doomed, 100 bytes that left
    /// `usedBytes` while the run awaited, so five evictions are enough, as for a run alone after the change.
    @Test("R-CLN-4: the old bytes an apply releases when an asset's content moves onto another asset's bytes count toward an overlapping eviction's need", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func contentChangeOntoLiveBlobWhileEvictionCandidatesRun() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        var entries = EvictionOverlapTests.assets.map(\.entry)
        entries[9].checksum = entries[8].checksum
        let moved = entries
        let report = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(moved, etagSeed: "moved"), etag: nil, eviction: nil)
        }.value
        #expect(report.reused == [EvictionOverlapTests.assets[9].id], "o9 adopts o8's bytes")
        await bulk.setHolding(false)
        let result = try await maintenance.value
        #expect(result == CleanupResult(bytesFreed: 500, filesRemoved: 5), "o9's old 100 bytes count: 450 of the 550 bytes it measured were still needed")
        #expect(await EvictionOverlapTests.evicted(harness) == Array(0..<5))
        #expect(try await harness.store.freeSpace().usedBytes == 400)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Stage 3 S3B-9, close-out cycle 2: the same holds across `apply` calls. One sync prunes `o9` (its 100 bytes
    /// counted as released), the next lists it again and adopts its blob back from its doom before the eviction resumes:
    /// the bytes are in `usedBytes` again, so they no longer count toward the need.
    @Test("R-CLN-4: bytes one apply released and a later apply adopts back while quota eviction computes its candidates no longer count toward its need", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func pruneThenReadoptWhileEvictionCandidatesRun() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        let all = EvictionOverlapTests.assets.map(\.entry)
        let pruned = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(Array(all.prefix(9)), etagSeed: "pruned"), etag: nil, eviction: nil)
        }.value
        #expect(pruned.pruned == [EvictionOverlapTests.assets[9].id])
        let readopted = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(all, etagSeed: "listed again"), etag: nil, eviction: nil)
        }.value
        #expect(readopted.reused == [EvictionOverlapTests.assets[9].id], "o9 adopts its doomed blob back")
        await bulk.setHolding(false)
        let result = try await maintenance.value
        #expect(result == CleanupResult(bytesFreed: 600, filesRemoved: 6), "the pruned bytes came back: the 550 bytes it measured were all still needed")
        #expect(await EvictionOverlapTests.evicted(harness) == Array(0..<6))
        #expect(try await harness.store.freeSpace().usedBytes <= 450)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Stage 3 S3B-9, close-out cycle 2: a record the applied manifest does not list (detached, as a legacy migration
    /// can leave one) is replaced when a manifest adds its id, and its blob is released like a pruned record's: the
    /// bytes count toward an overlapping eviction's need when they leave `usedBytes`, and not at all when the same
    /// `apply` adopts them back for the new record.
    @Test("R-CLN-4: an apply that replaces a detached record counts its released bytes toward an overlapping eviction's need unless it adopts them back", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func detachedRecordReplacementCounts() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(175, count: 90)
        let size = Int64(bytes.count)
        let key = CoreFixture.key(bytes)
        let a = CoreFixture.entry("a", bytes)
        let b = CoreFixture.entry("b", CoreFixture.bytes(176))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, b]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a])
        await harness.store.close()
        // Detach `a`: the committed index's applied manifest no longer lists it; its record and blob stay.
        var disk = harness.fileSystem.survivingDisk()
        let binPath = harness.layout.indexURL(.current).path
        var content = try IndexCodec.decode(try #require(disk.files[binPath])).get()
        content.appliedManifest = CoreFixture.manifest([b])
        let encoded = [UInt8](try #require(IndexCodec.encode(content)))
        disk.files[binPath] = encoded
        disk.durableFiles[binPath] = encoded
        let other = CoreFixture.entry("a", CoreFixture.bytes(177, count: 90))
        for (label, listed, counted) in [("new bytes", other, size), ("the same bytes", a, Int64(0))] {
            let reopened = CoreHarness.make(disk: disk)
            _ = try await reopened.store.open()
            #expect(await reopened.state.core.records[a.identifier]?.referencedBlob == key, "\(label): the detached record holds its blob")
            let start = await reopened.state.eviction.releasedBytes
            let report = try await reopened.store.apply(CoreFixture.manifest([listed, b]), etag: nil, eviction: nil)
            #expect(report.added == [a.identifier], "\(label)")
            #expect(await reopened.state.eviction.releasedBytes - start == counted, "\(label): the released bytes count only if they stay released")
            if counted > 0 {
                #expect(await reopened.state.core.countedReleases == [key: size], "\(label)")
                guard case .doomed? = await reopened.state.core.blobTable[key] else {
                    Issue.record("\(label): the replaced record's blob is doomed")
                    continue
                }
            } else {
                #expect(report.reused == [a.identifier], "\(label): the new record adopts the blob back")
                #expect(await reopened.state.core.blobTable[key] == .live(references: 1), "\(label)")
                #expect(await reopened.state.core.countedReleases.isEmpty, "\(label)")
            }
            #expect(await CoreInvariants.violations(of: reopened).isEmpty, "\(label)")
            await reopened.store.close()
        }
    }

    /// Stage 3 S3B-9, close-out cycle 2: the count of an `apply`'s release lasts exactly as long as its bytes stay
    /// released, whoever rescues them. A publication that dedupes onto the doomed blob takes the count back with its
    /// provisional reference, counts it again when it binds nothing (the key is doomed afresh), and drops it when it
    /// binds; the reaper's unlink ends the bookkeeping and keeps the count (the bytes are gone for good).
    @Test("R-CLN-4: a publication that rescues bytes an apply counted as released takes the count back, and counts them again when it binds nothing", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func publicationRescueTakesTheCountBack() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(173, count: 120)
        let size = Int64(bytes.count)
        let key = CoreFixture.key(bytes)
        let a = CoreFixture.entry("a", bytes)
        let b = CoreFixture.entry("b", CoreFixture.bytes(174))
        // A checksum-less entry binds whatever verified bytes its publication brings (R-INT-6), so a download of the
        // same bytes dedupes onto `a`'s doomed blob instead of being adopted by `apply`.
        let c = CoreFixture.entry("c", bytes, checksum: false)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, b, c]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a])
        let start = await harness.state.eviction.releasedBytes
        _ = try await harness.store.apply(CoreFixture.manifest([b, c]), etag: nil, eviction: nil)
        #expect(await harness.state.eviction.releasedBytes == start + size, "the prune's doom counts")
        #expect(await harness.state.core.countedReleases == [key: size])

        let acquisition = try await harness.store.acquireReference(key)
        guard case .rescued = acquisition else {
            Issue.record("expected a rescue of the doomed key, got \(acquisition)")
            return
        }
        #expect(await harness.state.eviction.releasedBytes == start, "the provisional reference brings the bytes back")
        #expect(await harness.state.core.countedReleases.isEmpty)
        #expect(await harness.state.core.provisionallyRescued == [key: size])
        await harness.store.abandonAcquisition(key, acquisition)
        guard case .doomed(let doom)? = await harness.state.core.blobTable[key] else {
            Issue.record("an abandoned rescue dooms the key again")
            return
        }
        #expect(doom.reason == .unreferenced)
        #expect(await harness.state.eviction.releasedBytes == start + size, "doomed afresh: the bytes count again")
        #expect(await harness.state.core.countedReleases == [key: size])
        #expect(await harness.state.core.provisionallyRescued.isEmpty)

        let bound = try await harness.publish(bytes, [c], sequence: 2)
        #expect(bound[c.identifier] != nil)
        #expect(await harness.state.core.blobTable[key] == .live(references: 1))
        #expect(await harness.state.eviction.releasedBytes == start, "bound: the bytes stay in usedBytes")
        #expect(await harness.state.core.countedReleases.isEmpty)
        #expect(await harness.state.core.provisionallyRescued.isEmpty)

        _ = try await harness.store.apply(CoreFixture.manifest([b]), etag: nil, eviction: nil)
        #expect(await harness.state.core.countedReleases == [key: size])
        await harness.reapAfterGrace()
        #expect(!harness.exists(harness.layout.blobURL(key)), "the reaper unlinked the blob")
        #expect(await harness.state.core.blobTable[key] == nil)
        #expect(await harness.state.core.countedReleases.isEmpty, "the unlink ends the bookkeeping")
        #expect(await harness.state.eviction.releasedBytes == start + size, "and keeps the count: the bytes are gone")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
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
        try await harness.store.recordIntegrityFailure(["c"], identity: entries[2].contentIdentity)
        try await harness.store.recordIntegrityFailure(["c"], identity: entries[2].contentIdentity)
        #expect(try await harness.store.planningView().records["c"]?.integrity.attempts == 2)
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
        // A purge that selects nothing still bumps the purge epoch (WP-C's `purge`).
        _ = try await harness.store.purge(.scope(.identifiers([])))
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
