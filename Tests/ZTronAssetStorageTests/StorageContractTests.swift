import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

private let base = URL(fileURLWithPath: "/virtual/Library/Application Support", isDirectory: true)

private func key(_ seed: UInt8, _ ext: String = "png") -> BlobKey {
    BlobKey(hash: ContentHash.sha256(of: Data([seed])), ext: AssetFileExtension(ext)!)
}

private func location(_ id: AssetID, _ blob: BlobKey, layout: StoreLayout) -> AssetLocation {
    AssetLocation(id: id, url: layout.blobURL(blob), fileExtension: blob.ext, byteSize: 10, integrity: .verified, isStale: false)
}

@Suite("Storage contracts")
struct StorageContractTests {
    @Test("R-SEC-2: every store URL is built under the versioned root from validated names only")
    func layoutStaysUnderRoot() {
        let layout = StoreLayout(base: base)
        let root = layout.root.standardizedFileURL.path
        #expect(root == base.path + "/ZTronAssetKit/v1")
        let blob = key(1, "heic")
        let staging = StagingFileName(transfer: .content(blob.hash), attempt: TransferAttempt(epoch: 2, sequence: 9), kind: .partial)
        let urls = [
            layout.lockURL, layout.indexURL(.current), layout.indexURL(.previous), layout.indexURL(.temporary),
            layout.blobsDirectory, layout.stagingDirectory, layout.fanOutDirectory(for: blob.hash),
            layout.blobURL(blob), layout.stagingURL(staging),
        ]
        for url in urls {
            #expect(url.standardizedFileURL.path.hasPrefix(root + "/"))
        }
        #expect(layout.blobURL(blob).lastPathComponent == blob.hash.hex + ".heic")
        #expect(layout.blobURL(blob).deletingLastPathComponent().lastPathComponent == blob.hash.fanOut)
        #expect(layout.stagingURL(staging).lastPathComponent == staging.rawValue)
        #expect(layout.container.lastPathComponent == "ZTronAssetKit")
    }

    @Test("R-SEC-2: blob names parse only as 64 lowercase hex digits and a lowercase extension")
    func blobNameParsing() {
        let valid = key(3, "mp4")
        #expect(StoreLayout.parseBlobName(valid.fileName) == valid)
        let hex = valid.hash.hex
        for foreign in [
            hex.uppercased() + ".mp4", hex + ".MP4", hex + ".mp4.part", hex, hex + ".", hex + ".toolongext",
            String(hex.dropLast()) + ".mp4", "../" + hex + ".mp4", hex + ".mp-4",
        ] {
            #expect(StoreLayout.parseBlobName(foreign) == nil)
        }
    }

    @Test("R-STO-13: snapshot lookup returns present assets only and matches extensions case-insensitively")
    func snapshotLookup() {
        let layout = StoreLayout(base: base)
        let image = key(4, "heic")
        let entries: [AssetID: SnapshotEntry] = [
            "page.icon": SnapshotEntry(location: location("page.icon", image, layout: layout), essential: false)
        ]
        let snapshot = AssetSnapshot(key: SnapshotKey(epoch: 1, version: 1), indexGeneration: 3, entries: entries)

        #expect(snapshot.location(for: "page.icon", extensions: [])?.url == layout.blobURL(image))
        #expect(snapshot.location(for: "page.icon", extensions: ["png", "HEIC"])?.fileExtension.rawValue == "heic")
        #expect(snapshot.location(for: "page.icon", extensions: ["png", "jpg"]) == nil)
        #expect(snapshot.location(for: "missing", extensions: []) == nil)
        #expect(AssetSnapshot.empty.location(for: "page.icon", extensions: []) == nil)
    }

    @Test("R-STO-13: snapshot keys order by epoch before version across store instances")
    func snapshotKeyOrder() {
        let reopened = SnapshotKey(epoch: 8, version: 1)
        let previousInstance = SnapshotKey(epoch: 7, version: 500)
        #expect(previousInstance < reopened)
        #expect(SnapshotKey(epoch: 8, version: 2) > reopened)
        #expect(SnapshotKey.zero < SnapshotKey(epoch: 0, version: 1))
    }

    @Test("R-CAR-7: every StoreError maps to the documented AssetError")
    func storeErrorMapping() {
        let digest = ContentHash.sha256(of: Data([1]))
        let table: [(StoreError, AssetError)] = [
            (.locked, .storageUnavailable(.locked)),
            (.closed, .shutDown),
            (.notOpen, .storageUnavailable(.ioFailure)),
            (.cancelled, .cancelled),
            (.fileSystem(.noSpace), .insufficientSpace(required: 0, available: 0)),
            (.fileSystem(.permissionDenied), .storageUnavailable(.protectedDataUnavailable)),
            (.fileSystem(.wouldBlock), .storageUnavailable(.locked)),
            (.fileSystem(.io), .storageUnavailable(.ioFailure)),
            (.insufficientSpace(required: 10, available: 3), .insufficientSpace(required: 10, available: 3)),
            (.integrity(.checksumMismatch(expected: digest, actual: digest)), .integrityFailure),
            (.unverifiedRejected("a"), .integrityFailure),
            (.unknownAsset("a"), .notFound),
            (.notPresent("a"), .notFound),
            (.superseded("a"), .serverUnavailable(retryAfter: nil)),
            (.assetFailed("a", .integrity), .integrityFailure),
            (.assetFailed("a", .notFound), .notFound),
            (.purgeRaced, .serverUnavailable(retryAfter: nil)),
            (.storageUnavailable(.rootVanished), .storageUnavailable(.rootVanished)),
        ]
        for (error, expected) in table {
            #expect(error.assetError == expected)
        }
    }

    @Test("Test support: SteppedBlockingExecutor holds each unit until released and records submission and completion order", .timeLimit(.minutes(1)))
    func steppedExecutorOrdersUnits() async throws {
        let executor = SteppedBlockingExecutor()
        let first = Task { await executor.run { 1 } }
        try await executor.requireHeldUnits(atLeast: 1)
        let second = Task { await executor.run { 2 } }
        try await executor.requireHeldUnits(atLeast: 2)
        #expect(await executor.heldUnits == [1, 2])
        #expect(await executor.completedUnits.isEmpty)
        await executor.release(2)
        #expect(await second.value == 2)
        #expect(await executor.completedUnits == [2])
        #expect(await executor.releaseNext() == 1)
        #expect(await first.value == 1)
        #expect(await executor.releaseNext() == nil)
        await executor.setHolding(false)
        #expect(await executor.run { 3 } == 3)
        #expect(await executor.submittedUnits == [1, 2, 3])
        #expect(await executor.completedUnits == [2, 1, 3])
    }

    @Test("Test support: ScriptedSnapshotSink acknowledges newer keys, ignores or reports a scripted key, and returns recorded accesses", .timeLimit(.minutes(1)))
    func scriptedSinkAnswersAsTold() async {
        let sink = ScriptedSnapshotSink()
        let five = AssetSnapshot(key: SnapshotKey(epoch: 3, version: 5), indexGeneration: 9, entries: [:])
        let six = AssetSnapshot(key: SnapshotKey(epoch: 3, version: 6), indexGeneration: 10, entries: [:])
        let seen = Date(timeIntervalSince1970: 100)
        await sink.recordAccess("a", at: seen)
        await sink.recordAccess("a", at: Date(timeIntervalSince1970: 50))
        let first = await sink.install(five)
        #expect(first.installed == five.key)
        #expect(first.retired?.key == .zero)
        #expect(first.accesses == ["a": seen])
        #expect(await sink.install(five).accesses.isEmpty)
        await sink.setBehaviour(.ignore)
        #expect(await sink.install(six).installed == five.key)
        await sink.setBehaviour(.report(SnapshotKey(epoch: 2, version: 99)))
        #expect(await sink.install(six).installed == SnapshotKey(epoch: 2, version: 99))
        #expect(await sink.installed.key == five.key)
        await sink.setBehaviour(.acknowledge)
        let last = await sink.install(six)
        #expect(last.installed == six.key)
        #expect(last.retired?.key == five.key)
        await sink.waitForInstalls(atLeast: 5)
        #expect(await sink.offeredKeys == [five.key, five.key, six.key, six.key, six.key])
    }
}

