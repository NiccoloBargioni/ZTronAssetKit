import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The primitives WP-C builds on (ARCHITECTURE §1.1 `StoreInternals.swift`).
@Suite("Core: primitives for WP-C")
struct StoreInternalsTests {
    @Test("R-STO-3: adoptVerifiedFile moves a verified file into blobs for every record expecting it and installs no snapshot", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func adoptVerifiedFile() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(180, count: 2_500)
        let digest = ContentHash.sha256(of: bytes)
        let png = CoreFixture.entry("legacy.png", bytes, checksum: false)
        let jpg = CoreFixture.entry("legacy.jpg", bytes, ext: "jpg", checksum: false)
        let other = CoreFixture.entry("other", CoreFixture.bytes(181), checksum: false)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([png, jpg, other]), etag: nil, eviction: nil)
        // Legacy phase 1 records the planned hash as each record's adoption key (WP-C's write, simulated here).
        await harness.store.testExpect(digest, for: ["legacy.png", "legacy.jpg"])
        let legacy = URL(fileURLWithPath: "/fake-volume/Library/Caches/CDNAssets/a.png")
        try harness.fileSystem.createDirectory(at: legacy.deletingLastPathComponent())
        try harness.fileSystem.write(bytes, to: legacy, mode: .truncate)
        let installs = await harness.sink.offeredKeys.count
        let locations = try await harness.store.adoptVerifiedFile(at: legacy, digest: digest, byteCount: Int64(bytes.count), for: ["legacy.png", "legacy.jpg", "other", "ghost"])
        #expect(Set(locations.keys) == ["legacy.png", "legacy.jpg"])
        #expect(locations["legacy.png"]?.integrity == .unverified)
        #expect(harness.content(harness.layout.blobURL(CoreFixture.key(bytes))) == bytes)
        #expect(harness.content(harness.layout.blobURL(CoreFixture.key(bytes, ext: "jpg"))) == bytes)
        #expect(!harness.exists(legacy), "moved, not copied")
        #expect(await harness.sink.offeredKeys.count == installs, "the caller decides the snapshot urgency")
        #expect(try await harness.store.adoptVerifiedFile(at: legacy, digest: digest, byteCount: 1, for: ["other"]).isEmpty)
        await harness.store.publishSnapshot(urgency: .userInitiated)
        #expect(await harness.sink.installed.location(for: "legacy.jpg", extensions: ["JPG"]) != nil)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-STO-4: ensureOpen, requireCommitted and publishSnapshot follow the phase, the durability and the install rate", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func phaseCommitAndSnapshotPrimitives() async throws {
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(installInterval: 0.1))
        await #expect(throws: StoreError.notOpen) {
            try await harness.store.ensureOpen()
        }
        _ = try await harness.store.open()
        try await harness.store.ensureOpen()
        await harness.store.markDirty(.lazy)
        #expect(await harness.store.nextDeadline() == nil, "a lazy mutation keeps no deadline")
        try await harness.store.requireCommitted(.durable)
        let commits = await harness.state.core.commits
        #expect(commits.durableSerial == commits.mutationSerial)
        let durableCommits = await harness.store.metrics().commits
        try await harness.store.requireCommitted(.ordered)
        #expect(await harness.store.metrics().commits == durableCommits, "already covered: no commit")
        let installs = await harness.sink.offeredKeys.count
        await harness.store.publishSnapshot(urgency: .bulk)
        #expect(await harness.sink.offeredKeys.count == installs, "inside the window: a trailing install")
        #expect(await harness.store.nextDeadline() == harness.time.monotonicNow().adding(seconds: 0.1))
        await harness.store.publishSnapshot(urgency: .userInitiated)
        #expect(await harness.sink.offeredKeys.count == installs + 1)
        await harness.store.close()
        await #expect(throws: StoreError.closed) {
            try await harness.store.ensureOpen()
        }
        await #expect(throws: StoreError.closed) {
            try await harness.store.requireCommitted(.ordered)
        }
    }

    @Test("R-CLN-1: setResidency dooms the last reference with the given reason, persists it, and refuses an unreferencable present key", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func setResidency() async throws {
        let harness = CoreHarness.make()
        let a = CoreFixture.bytes(182)
        let b = CoreFixture.bytes(183)
        let entries = [CoreFixture.entry("a", a), CoreFixture.entry("b", b), CoreFixture.entry("c", a)]
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
        try await harness.publish(a, [entries[0]], sequence: 1)
        try await harness.publish(b, [entries[1]], sequence: 2)
        let keyA = CoreFixture.key(a)
        let keyB = CoreFixture.key(b)
        await harness.store.setResidency(.absent(.purged), of: "a", dooming: .purged)
        await harness.store.setResidency(.quarantined(until: harness.time.now()), of: "b", dooming: .corrupt)
        try await harness.store.flush(.ordered)
        let onDisk = try IndexCodec.decode([UInt8](try #require(harness.content(harness.layout.indexURL(.current))))).get()
        #expect(onDisk.doomed == [keyA: .purged, keyB: .corrupt])
        // A purged or corrupt key cannot be referenced in place, and an unknown record is ignored.
        await harness.store.setResidency(.present(blob: keyA, byteSize: 300, integrity: .verified), of: "c", dooming: .unreferenced)
        #expect(try await harness.store.planningView().records["c"]?.residency == .absent(.neverFetched))
        await harness.store.setResidency(.absent(.evicted), of: "ghost", dooming: .unreferenced)
        // A verified publication replaces a purged name (ADR-018) and a corrupt one.
        try await harness.publish(a, [entries[2]], sequence: 3)
        try await harness.publish(b, [entries[1]], sequence: 4)
        let table = await harness.state.core.blobTable
        #expect(table[keyA] == .live(references: 1) && table[keyB] == .live(references: 1))
        #expect(harness.mutations.filter { $0.kind == .rename && $0.destination == harness.layout.blobURL(keyA) }.count == 2)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}

extension AssetStore {
    /// Records `hash` as the adoption key of `ids` the way WP-C's legacy phase 1 does (test seam).
    func testExpect(_ hash: ContentHash, for ids: [AssetID]) {
        for id in ids {
            self.state.core.records[id]?.expectedBlob = hash
        }
        self.markDirty(.soon)
    }
}
