import CryptoKit
import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

@Suite("Core: publication and integrity")
struct StorePublishTests {
    @Test("R-STO-3: a blob never appears at its final path before size check, hash verification and barrier", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func publicationOrder() async throws {
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(hashChunkBytes: 128))
        let bytes = CoreFixture.bytes(5, count: 1_000)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry)
        let start = harness.fileSystem.operations.count
        let locations = try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        let ops = Array(harness.fileSystem.operations[start...])
        let blob = harness.layout.blobURL(CoreFixture.key(bytes))
        let verifying = harness.layout.stagingURL(staged.name.with(kind: .verifying))
        let firstAtBlob = try #require(ops.firstIndex { $0.url == blob || $0.destination == blob })
        let claim = try #require(ops.firstIndex { $0.kind == .rename && $0.destination == verifying })
        let reads = ops.indices.filter { ops[$0].kind == .read && ops[$0].url == verifying }
        let barrier = try #require(ops.firstIndex { $0.kind == .synchronizeFile && $0.url == verifying })
        #expect(ops[firstAtBlob].kind == .rename && ops[firstAtBlob].url == verifying)
        #expect(claim < (reads.first ?? -1) && (reads.last ?? .max) < barrier && barrier < firstAtBlob)
        #expect(reads.count == 8, "1,000 bytes in 128-byte units: 7 full reads and one short")
        #expect(locations[entry.identifier]?.url == blob)
        #expect(harness.content(blob) == bytes)
        // Failures never reach the final path.
        let wrong = CoreFixture.entry("b", CoreFixture.bytes(6, count: 1_000))
        _ = try await harness.store.apply(CoreFixture.manifest([entry, wrong]), etag: nil, eviction: nil)
        let bad = try await harness.stage(CoreFixture.bytes(7, count: 1_000), for: wrong, sequence: 2)
        let before = harness.fileSystem.operations.count
        await #expect(throws: StoreError.self) {
            try await harness.store.publish(bad, binding: [wrong.identifier], expecting: wrong.contentIdentity, urgency: .bulk)
        }
        let wrongBlob = harness.layout.blobURL(CoreFixture.key(CoreFixture.bytes(7, count: 1_000)))
        #expect(!harness.fileSystem.operations[before...].contains { $0.url.path.hasPrefix(harness.layout.blobsDirectory.path) || $0.destination == wrongBlob })
    }

    @Test("R-STO-3: bytes appended to a staged file after publication begins are never published", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func appendAfterClaimIsNeverPublished() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(bulk: bulk)
        let bytes = CoreFixture.bytes(8, count: 500)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry)
        await bulk.setHolding(true)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        // A late producer appends to the name it knows: it creates a new partial, never the claimed bytes.
        let sink = try await harness.store.makeStagingSink()
        _ = try sink.appendPartial(Data("late bytes".utf8), to: staged.name)
        await bulk.setHolding(false)
        let locations = try await publishing.value
        let url = try #require(locations[entry.identifier]?.url)
        #expect(harness.content(url) == bytes)
        #expect(harness.content(harness.layout.stagingURL(staged.name)) == Data("late bytes".utf8))
    }

    @Test("R-INT-1: streaming SHA-256 equals CryptoKit one-shot for 0, 1, 1 MiB−1, 1 MiB, 1 MiB+1 and 5 MiB", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func streamingHashMatchesOneShot() async throws {
        let bulk = CountingExecutor()
        let harness = CoreHarness.make(bulk: bulk)
        _ = try await harness.store.open()
        let mebibyte = 1 << 20
        for (index, size) in [0, 1, mebibyte - 1, mebibyte, mebibyte + 1, 5 * mebibyte].enumerated() {
            let bytes = GeneratedPayload.bytes(seed: UInt64(100 + index), offset: 0, length: size)
            let url = harness.layout.stagingDirectory.appendingPathComponent("hash-\(index).bin")
            try harness.fileSystem.write(bytes, to: url, mode: .truncate)
            let unitsBefore = await bulk.units
            let result = try await harness.store.hashFile(at: url)
            let units = await bulk.units - unitsBefore
            #expect(result.digest == ContentHash(digest: SHA256.hash(data: bytes)), "size \(size)")
            #expect(result.byteCount == Int64(size))
            #expect(units == size / mebibyte + 1, "size \(size): one unit per started MiB plus the short read")
        }
        await #expect(throws: StoreError.fileSystem(.notFound)) {
            try await harness.store.hashFile(at: harness.layout.stagingDirectory.appendingPathComponent("absent.bin"))
        }
    }

    @Test("R-INT-1: cancelling a hash stops at the next unit boundary and leaves the staged file in place", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func cancelledHashKeepsTheStagedFile() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(hashChunkBytes: 100), bulk: bulk)
        let bytes = CoreFixture.bytes(9, count: 1_000)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry)
        let completedBefore = await bulk.completedUnits.count
        await bulk.setHolding(true)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        publishing.cancel()
        await bulk.setHolding(false)
        await #expect(throws: StoreError.cancelled) {
            try await publishing.value
        }
        #expect(await bulk.completedUnits.count == completedBefore + 1, "no unit after the cancellation")
        #expect(harness.content(harness.layout.stagingURL(staged.name)) == bytes)
        #expect(!harness.exists(harness.layout.stagingURL(staged.name.with(kind: .verifying))))
        // The same staged file publishes afterwards.
        let locations = try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        #expect(locations[entry.identifier] != nil)
    }

    /// Review round 3, "publish cancellation hand-back": the hand-back renames `.verifying` back to `.part`
    /// exclusively; when a producer recreated `.part` meanwhile (an `O_CREAT` append), the rename fails and the claimed
    /// full-size file must not stay stranded in staging as `.verifying` until staging GC.
    @Test("R-INT-1: a cancelled hash whose claim cannot be handed back discards the claimed file and keeps the producer's new .part", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func cancelledHashHandBackFails() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(hashChunkBytes: 100), bulk: bulk)
        let bytes = CoreFixture.bytes(10, count: 1_000)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry, sidecar: true)
        let part = harness.layout.stagingURL(staged.name)
        let verifying = harness.layout.stagingURL(staged.name.with(kind: .verifying))
        await bulk.setHolding(true)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        #expect(harness.exists(verifying) && !harness.exists(part), "the claim renamed .part to .verifying")
        let tail = Data([1, 2, 3])
        try harness.fileSystem.write(tail, to: part, mode: .append)
        publishing.cancel()
        await bulk.setHolding(false)
        await #expect(throws: StoreError.cancelled) {
            try await publishing.value
        }
        #expect(!harness.exists(verifying), "the claimed file is discarded, not stranded in staging")
        #expect(!harness.exists(harness.layout.stagingURL(staged.name.with(kind: .sidecar))), "its sidecar describes the discarded bytes")
        #expect(harness.content(part) == tail, "the producer's new .part is left alone")
        #expect(await harness.state.core.blobTable.isEmpty)
        #expect(await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == nil)
    }

    @Test("R-INT-2: a checksum mismatch deletes the staged bytes, throws integrity, counts a metric and publishes nothing", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func checksumMismatch() async throws {
        let harness = CoreHarness.make()
        let claimed = CoreFixture.bytes(30)
        let delivered = CoreFixture.bytes(31)
        let entry = CoreFixture.entry("a", claimed)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let installsBefore = await harness.sink.offeredKeys.count
        let staged = try await harness.stage(delivered, for: entry, sidecar: true)
        await #expect(throws: StoreError.integrity(.checksumMismatch(expected: ContentHash.sha256(of: claimed), actual: ContentHash.sha256(of: delivered)))) {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        }
        for kind in [StagingFileName.Kind.partial, .verifying, .sidecar] {
            #expect(!harness.exists(harness.layout.stagingURL(staged.name.with(kind: kind))), "\(kind) left behind")
        }
        #expect(await harness.store.metrics().integrityFailures == 1)
        #expect(await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == nil)
        #expect(await harness.sink.offeredKeys.count == installsBefore)
        #expect(!harness.exists(harness.layout.blobURL(CoreFixture.key(delivered))))
        #expect(StoreError.integrity(.checksumMismatch(expected: ContentHash.sha256(of: claimed), actual: ContentHash.sha256(of: delivered))).assetError == .integrityFailure)
    }

    @Test("R-INT-2: a staged file larger than maxAssetBytes is rejected as oversize before hashing", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func oversizeBeforeHashing() async throws {
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(limits: ManifestLimits(maxAssetBytes: 100)))
        let bytes = CoreFixture.bytes(32, count: 300)
        let entry = CoreFixture.entry("a", bytes, size: false)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry)
        await #expect(throws: StoreError.integrity(.oversize(limit: 100, actual: 300))) {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        let verifying = harness.layout.stagingURL(staged.name.with(kind: .verifying))
        #expect(!harness.fileSystem.operations.contains { $0.kind == .read && $0.url == verifying }, "nothing was hashed")
        #expect(!harness.exists(verifying))
        #expect(await harness.store.metrics().integrityFailures == 1)
    }

    @Test("R-INT-2: a size mismatch is rejected before hashing and the staged bytes are deleted", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func sizeMismatchBeforeHashing() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(33, count: 300)
        var entry = CoreFixture.entry("a", bytes)
        entry.byteSize = 299
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let installsBefore = await harness.sink.offeredKeys.count
        let staged = try await harness.stage(bytes, for: entry, sidecar: true)
        await #expect(throws: StoreError.integrity(.sizeMismatch(expected: 299, actual: 300))) {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        #expect(!harness.fileSystem.operations.contains { $0.kind == .read && $0.url.lastPathComponent.hasSuffix(".verifying") }, "nothing was hashed")
        // R-INT-2: the staged bytes (the claimed file and its sidecar) are deleted, as for a checksum mismatch.
        for kind in [StagingFileName.Kind.partial, .verifying, .sidecar] {
            #expect(!harness.exists(harness.layout.stagingURL(staged.name.with(kind: kind))), "\(kind) left behind")
        }
        #expect(await harness.store.metrics().integrityFailures == 1)
        #expect(!harness.exists(harness.layout.blobURL(CoreFixture.key(bytes))))
        #expect(await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == nil)
        #expect(await harness.sink.offeredKeys.count == installsBefore)
    }

    @Test("R-INT-5: unverified entries are rejected when allowUnverifiedAssets is false and flagged unverified otherwise", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func unverifiedEntries() async throws {
        let bytes = CoreFixture.bytes(40)
        let entry = CoreFixture.entry("legacy", bytes, checksum: false)
        var strict = StoragePolicy()
        strict.allowUnverifiedAssets = false
        let rejecting = CoreHarness.make(configuration: CoreFixture.configuration(policy: strict))
        _ = try await rejecting.store.open()
        _ = try await rejecting.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await rejecting.stage(bytes, for: entry)
        await #expect(throws: StoreError.unverifiedRejected(entry.identifier)) {
            try await rejecting.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        #expect(!rejecting.exists(rejecting.layout.stagingURL(staged.name)))
        #expect(StoreError.unverifiedRejected(entry.identifier).assetError == .integrityFailure)

        let admitting = CoreHarness.make()
        _ = try await admitting.store.open()
        _ = try await admitting.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let location = try #require(try await admitting.publish(bytes, [entry])[entry.identifier])
        #expect(location.integrity == .unverified && !location.isStale)
        #expect(await admitting.store.availability(of: .all).unverified == 1)
        #expect(await admitting.sink.installed.location(for: entry.identifier, extensions: [])?.integrity == .unverified)
        // A checksum-less publish is committed before it returns (store-1 S1-05).
        let committed = await admitting.state.core
        #expect(committed.commits.committedSerial == committed.commits.mutationSerial)
    }

    @Test("R-INT-6: the recorded blob hash is the digest of the written bytes, not the manifest claim", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func recordedHashIsOurDigest() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(41)
        let unverified = CoreFixture.entry("unverified", bytes, checksum: false)
        let verified = CoreFixture.entry("verified", CoreFixture.bytes(42))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([unverified, verified]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [unverified])
        let record = try #require(try await harness.store.planningView().records[unverified.identifier])
        #expect(record.referencedBlob?.hash == ContentHash.sha256(of: bytes))
        #expect(record.expectedBlob == ContentHash.sha256(of: bytes))
        // A manifest claim that disagrees with the bytes is never recorded: the publication fails.
        let lie = try await harness.stage(CoreFixture.bytes(43), for: verified, sequence: 2)
        await #expect(throws: StoreError.self) {
            try await harness.store.publish(lie, binding: [verified.identifier], expecting: verified.contentIdentity, urgency: .bulk)
        }
        #expect(try await harness.store.planningView().records[verified.identifier]?.referencedBlob == nil)
    }

    @Test("R-SEC-2: manifest text never becomes a path component of the store", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func manifestTextNeverBecomesAPath() async throws {
        let seed: UInt64 = 0x5EC2
        var generator = SplitMix64(seed: seed)
        let hostile = ["..", "../..", "/", "a/b", ".", "%2e%2e", "~", "\u{0}", "名前", "x\\y", String(repeating: "z", count: 300), "..%2f", " "]
        func text() -> String {
            (0..<3).map { _ in hostile[Int(generator.next() % UInt64(hostile.count))] }.joined()
        }
        let harness = CoreHarness.make()
        _ = try await harness.store.open()
        var entries: [ManifestEntry] = []
        var payloads: [AssetID: Data] = [:]
        for index in 0..<24 {
            let bytes = CoreFixture.bytes(500 + UInt64(index), count: 64)
            let ext = ["PNG", "jpg", "Heic", "mp3"][index % 4]
            var entry = ManifestEntry(
                identifier: AssetID("\(index)\(text())"),
                fileExtension: ext,
                remotePath: text(),
                localPathComponents: [text(), text()],
                localFileName: text(),
                byteSize: 64,
                checksum: index % 3 == 0 ? nil : ContentHash.sha256(of: bytes),
                tags: [text()]
            )
            if index % 5 == 0 {
                entry.fileExtension = "../x"
            }
            entries.append(entry)
            payloads[entry.identifier] = bytes
        }
        _ = try await harness.store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
        for (index, entry) in entries.enumerated() {
            let staged = try await harness.stage(payloads[entry.identifier]!, for: entry, sequence: UInt32(index + 1))
            _ = try? await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        _ = await harness.store.runDueWork()
        let root = harness.layout.root
        // Nothing reaches outside the root but the fixed container and base (as in the R-STO-1 test of `open`):
        // a hostile name that steered a path elsewhere fails here, before the per-component check below.
        let fixedOutside: Set<String> = [harness.layout.container.path, CoreFixture.base.path]
        let mutationsOutside: Set<String> = [
            "createDirectory \(harness.layout.container.path)",
            "synchronizeDirectory \(harness.layout.container.path)",
            "synchronizeDirectory \(CoreFixture.base.path)",
        ]
        for record in harness.fileSystem.operations {
            for url in [record.url] + (record.destination.map { [$0] } ?? []) {
                let path = url.standardizedFileURL.path
                guard !(path + "/").hasPrefix(root.path + "/") else {
                    continue
                }
                if record.kind.isMutation {
                    #expect(mutationsOutside.contains("\(record.kind.rawValue) \(path)"), "seed \(seed): \(record.kind) outside the root: \(path)")
                } else {
                    #expect(fixedOutside.contains(path), "seed \(seed): \(record.kind) outside the root: \(path)")
                }
            }
        }
        for record in harness.fileSystem.operations {
            for url in [record.url] + (record.destination.map { [$0] } ?? []) where url.path.hasPrefix(root.path + "/") {
                let components = url.pathComponents.dropFirst(root.pathComponents.count)
                for component in components {
                    let allowed =
                        ["store.lock", "index.bin", "index.prev", "index.tmp", "blobs", "staging"].contains(component)
                        || OpenUnits.isFanOutName(component) || StoreLayout.parseBlobName(component) != nil
                        || StagingFileName(parsing: component) != nil
                    #expect(allowed, "seed \(seed): \(component) in \(url.path)")
                }
            }
        }
        // Valid entries were published under content names; an invalid extension never was.
        let present = try await harness.store.planningView().records.values.filter { $0.referencedBlob != nil }
        #expect(present.count == entries.filter { AssetFileExtension($0.fileExtension) != nil }.count)
    }

    @Test("R-CLN-1: identical bytes published for two identifiers share one blob, and a second publication is a dedupe", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func dedupeSharesOneBlob() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(50)
        let first = CoreFixture.entry("first", bytes)
        let second = CoreFixture.entry("second", bytes)
        let other = CoreFixture.entry("other", bytes, ext: "JPG")
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([first, second, other]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [first])
        let staged = try await harness.stage(bytes, for: second, sequence: 2)
        let locations = try await harness.store.publish(staged, binding: [second.identifier, other.identifier], expecting: second.contentIdentity, urgency: .bulk)
        let key = CoreFixture.key(bytes)
        let jpg = CoreFixture.key(bytes, ext: "jpg")
        #expect(locations[second.identifier]?.url == harness.layout.blobURL(key))
        #expect(locations[other.identifier]?.url == harness.layout.blobURL(jpg))
        #expect(harness.content(harness.layout.blobURL(jpg)) == bytes)
        let table = await harness.state.core.blobTable
        #expect(table[key] == .live(references: 2) && table[jpg] == .live(references: 1))
        #expect(!harness.exists(harness.layout.stagingURL(staged.name.with(kind: .verifying))))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-INT-2: a publication for a changed, unknown or failed entry is refused before any file operation", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func refusedPublications() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(60)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry)
        let before = harness.fileSystem.operations.count
        await #expect(throws: StoreError.superseded(entry.identifier)) {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: .checksum(ContentHash.sha256(of: Data())), urgency: .bulk)
        }
        await #expect(throws: StoreError.unknownAsset("ghost")) {
            try await harness.store.publish(staged, binding: ["ghost"], expecting: entry.contentIdentity, urgency: .bulk)
        }
        await harness.store.setResidency(.failed(.notFound), of: entry.identifier, dooming: .unreferenced)
        await #expect(throws: StoreError.assetFailed(entry.identifier, .notFound)) {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        #expect(harness.fileSystem.operations[before...].allSatisfy { !$0.kind.isMutation })
        #expect(try await harness.store.publish(staged, binding: [], expecting: entry.contentIdentity, urgency: .bulk).isEmpty)
    }
}
