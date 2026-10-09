import Foundation
import Testing
import ZTronAssetModel

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
}
