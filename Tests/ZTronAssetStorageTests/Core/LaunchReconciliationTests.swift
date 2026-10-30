import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

@Suite("Core: launch reconciliation")
struct LaunchReconciliationTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func record(_ id: String, _ residency: Residency, expected: ContentHash?, checksum: ContentHash? = nil, size: Int64? = nil) -> AssetRecord {
        AssetRecord(
            entry: ManifestEntry(identifier: AssetID(id), fileExtension: "png", remotePath: "media/\(id).png", byteSize: size, checksum: checksum),
            residency: residency,
            expectedBlob: expected,
            lastAccess: LaunchReconciliationTests.now
        )
    }

    static func key(_ seed: UInt8) -> BlobKey {
        BlobKey(hash: GoldenIndex.hash(seed), ext: AssetFileExtension("png")!)
    }

    @Test("R-STO-5: launch reconciliation repairs DOOMED against references and drops DOOMED keys no longer on disk")
    func doomedRepair() {
        var content = IndexContent.empty(storeID: .zero)
        content.generation = 9
        let live = LaunchReconciliationTests.key(1)
        let doomed = LaunchReconciliationTests.key(2)
        let gone = LaunchReconciliationTests.key(3)
        content.records = ["a": LaunchReconciliationTests.record("a", .present(blob: live, byteSize: 10, integrity: .verified), expected: live.hash)]
        content.doomed = [live: .unreferenced, doomed: .purged, gone: .corrupt]
        let result = LaunchReconciliation.reconcile(content: content, onDisk: [live: 10, doomed: 20], blobsRecreated: false, openGeneration: 10, now: LaunchReconciliationTests.now)
        #expect(result.doomedRepairs == 1)
        #expect(result.blobTable[live] == .live(references: 1))
        #expect(result.blobTable[doomed] == .doomed(DoomInfo(reason: .purged, sinceSnapshotVersion: 1, droppedInGeneration: 9)))
        #expect(result.blobTable[gone] == nil && result.orphans.isEmpty && !result.osPurgeDetected)
    }

    @Test("R-CLN-7: a wrong-sized blob makes its records needsHeal and is quarantined as corrupt, never adopted")
    func wrongSizedBlob() {
        var content = IndexContent.empty(storeID: .zero)
        let key = LaunchReconciliationTests.key(4)
        content.records = [
            "a": LaunchReconciliationTests.record("a", .present(blob: key, byteSize: 10, integrity: .verified), expected: key.hash),
            "b": LaunchReconciliationTests.record("b", .absent(.neverFetched), expected: key.hash),
        ]
        let result = LaunchReconciliation.reconcile(content: content, onDisk: [key: 7], blobsRecreated: false, openGeneration: 3, now: LaunchReconciliationTests.now)
        #expect(result.records["a"]?.residency == .needsHeal(lastBlob: key))
        #expect(result.records["b"]?.residency == .absent(.neverFetched))
        #expect(result.blobTable[key] == .doomed(DoomInfo(reason: .corrupt, sinceSnapshotVersion: 1, droppedInGeneration: 3)))
        #expect(result.missingBlobs == 1 && result.osPurgeDetected)
    }

    @Test("R-STO-5: launch adoption binds only records that accept it, rescues unreferenced dooms and releases a stale record's old blob")
    func adoption() {
        var content = IndexContent.empty(storeID: .zero)
        content.generation = 4
        let old = LaunchReconciliationTests.key(5)
        let new = LaunchReconciliationTests.key(6)
        let rescued = LaunchReconciliationTests.key(7)
        let purged = LaunchReconciliationTests.key(8)
        let orphan = LaunchReconciliationTests.key(9)
        content.records = [
            "stale": LaunchReconciliationTests.record("stale", .present(blob: old, byteSize: 5, integrity: .verified), expected: new.hash, checksum: new.hash),
            "rescue": LaunchReconciliationTests.record("rescue", .absent(.evicted), expected: rescued.hash, checksum: rescued.hash, size: 6),
            "wrongSize": LaunchReconciliationTests.record("wrongSize", .absent(.neverFetched), expected: rescued.hash, size: 99),
            "purgedRecord": LaunchReconciliationTests.record("purgedRecord", .absent(.purged), expected: new.hash),
            "failed": LaunchReconciliationTests.record("failed", .failed(.integrity), expected: new.hash),
            "fromPurged": LaunchReconciliationTests.record("fromPurged", .needsHeal(lastBlob: purged), expected: purged.hash),
        ]
        content.doomed = [rescued: .unreferenced, purged: .purged]
        let onDisk: [BlobKey: Int64] = [old: 5, new: 8, rescued: 6, purged: 3, orphan: 1]
        let result = LaunchReconciliation.reconcile(content: content, onDisk: onDisk, blobsRecreated: false, openGeneration: 5, now: LaunchReconciliationTests.now)
        #expect(result.records["stale"]?.residency == .present(blob: new, byteSize: 8, integrity: .verified))
        #expect(result.records["rescue"]?.residency == .present(blob: rescued, byteSize: 6, integrity: .verified))
        #expect(result.records["wrongSize"]?.residency == .absent(.neverFetched))
        #expect(result.records["purgedRecord"]?.residency == .absent(.purged))
        #expect(result.records["failed"]?.residency == .failed(.integrity))
        #expect(result.records["fromPurged"]?.residency == .needsHeal(lastBlob: purged), "a purged doom is never re-adopted")
        #expect(result.blobTable[old] == .doomed(DoomInfo(reason: .unreferenced, sinceSnapshotVersion: 1, droppedInGeneration: 5)))
        #expect(result.blobTable[new] == .live(references: 1) && result.blobTable[rescued] == .live(references: 1))
        #expect(result.orphans == [orphan: 1])
        #expect(result.adoptedFanOuts == [new.hash.fanOut, rescued.hash.fanOut])
    }

    @Test("R-CLN-7: an emptied or recreated blobs directory under present records is OS-purge evidence")
    func purgeEvidence() {
        var content = IndexContent.empty(storeID: .zero)
        let key = LaunchReconciliationTests.key(10)
        content.records = ["a": LaunchReconciliationTests.record("a", .present(blob: key, byteSize: 1, integrity: .verified), expected: key.hash)]
        let recreated = LaunchReconciliation.reconcile(content: content, onDisk: [key: 1], blobsRecreated: true, openGeneration: 1, now: LaunchReconciliationTests.now)
        #expect(recreated.osPurgeDetected && recreated.missingBlobs == 0)
        let fresh = LaunchReconciliation.reconcile(content: IndexContent.empty(storeID: .zero), onDisk: [:], blobsRecreated: true, openGeneration: 1, now: LaunchReconciliationTests.now)
        #expect(!fresh.osPurgeDetected)
    }

    /// store-1 S1-03's missing half (Stage 3 S3-CRAS-05): the end-to-end test of R-CLN-6 covers a purged record, which
    /// never accepts adoption, so the doom-reason guard of launch adoption (7c) was never reached for `purged`. Here a
    /// manifest re-adds the purged bytes under another id while the purge waits out its grace, and the process is
    /// killed before the reaper unlinks them: neither `apply` nor the next launch binds the new record to the purged
    /// name; the bytes are fetched again.
    @Test(
        "R-CLN-6: a purged doom is never rescued by launch adoption, even for another record that expects its bytes after a kill before the reap",
        .timeLimit(.minutes(1))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func purgedDoomNeverRescuedAtLaunch() async throws {
        let harness = CoreHarness.make()
        let xBytes = CoreFixture.bytes(4_701, count: 300)
        let yBytes = CoreFixture.bytes(4_702, count: 280)
        let x = CoreFixture.entry("x", xBytes)
        let y = CoreFixture.entry("y", yBytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([x, y]), etag: nil, eviction: nil)
        try await harness.publish(xBytes, [x], sequence: 1)
        try await harness.publish(yBytes, [y], sequence: 2)
        try await harness.store.flush(.durable)
        let key = CoreFixture.key(xBytes)
        // The purge dooms x's blob `purged` and waits out the deletion grace in its caller's task.
        let purge = Task {
            try await harness.store.purge(.scope(.identifiers(["x"])))
        }
        try await harness.time.requireSleepers(atLeast: 1)
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[key], .purged))
        // A manifest re-adds the purged bytes under z: `apply` does not adopt the purged doom either.
        let z = CoreFixture.entry("z", xBytes)
        _ = try await harness.store.apply(CoreFixture.manifest([x, y, z], etagSeed: "z"), etag: nil, eviction: nil)
        #expect(await harness.store.location(for: "z", extensions: [], recordingAccess: false) == nil)
        // The process is killed now, before the reaper unlinked the purged bytes.
        let killed = harness.fileSystem.survivingDisk()
        #expect(killed.files[CoreFixture.blobPath(key)] != nil, "the purged bytes are still on disk")
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        _ = try await purge.value
        await harness.store.close()
        // The next launch: the purged name is listed, z expects it and accepts adoption, and still nothing binds.
        let reopened = CoreHarness.make(disk: killed)
        _ = try await reopened.store.open()
        #expect(await reopened.state.core.records["z"]?.residency == .absent(.neverFetched), "a purged doom was rescued at launch")
        #expect(await reopened.store.location(for: "z", extensions: [], recordingAccess: false) == nil)
        #expect(StoreRecoveryTests.isDoomed(await reopened.state.core.blobTable[key], .purged))
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
        // The reaper removes the purged bytes; z is fetched again and served from its own verified publication.
        await reopened.reapAfterGrace()
        #expect(!reopened.exists(reopened.layout.blobURL(key)), "the purged bytes were reaped")
        try await reopened.publish(xBytes, [z], sequence: 3)
        let served = try #require(await reopened.store.location(for: "z", extensions: [], recordingAccess: false))
        #expect(reopened.content(served.url) == xBytes)
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
        await reopened.store.close()
    }
}
