import Foundation
import ZTronAssetModel

@testable import ZTronAssetStorage

/// The content of the committed v1 golden index fixture (`Tests/Fixtures/index/v1/golden.bin`, R-STO-12): every
/// residency, absence and failure reason, every optional field present and absent, a detached record, two
/// identifiers that differ only in Unicode normalisation, fractional dates, an envelope manifest and DOOMED keys of
/// all three reasons.
enum GoldenIndex {
    /// Where the fixture lives.
    static func directory(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/index/v1", isDirectory: true)
    }

    static func hash(_ seed: UInt8) -> ContentHash {
        ContentHash(bytes: (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &* 31 &+ $0 &* 7) })!
    }

    static func date(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    static func key(_ seed: UInt8, _ ext: String) -> BlobKey {
        BlobKey(hash: GoldenIndex.hash(seed), ext: AssetFileExtension(ext)!)
    }

    static var content: IndexContent {
        let entries: [ManifestEntry] = [
            ManifestEntry(
                identifier: "bo7.ri.map", fileExtension: "PNG", remotePath: "media/0102/map.png", localPathComponents: ["bo7", "ri"],
                localFileName: "map", byteSize: 1_234, checksum: GoldenIndex.hash(1), tags: ["ri", "map"], policy: .essential
            ),
            ManifestEntry(identifier: "bo7.ri.icon", fileExtension: "heic", remotePath: "media/icon.heic", byteSize: 99, checksum: GoldenIndex.hash(2)),
            ManifestEntry(identifier: "legacy.wav", fileExtension: "wav", remotePath: "legacy/a.wav", localPathComponents: ["x"], localFileName: "a"),
            ManifestEntry(identifier: "stale.png", fileExtension: "png", remotePath: "media/stale.png", byteSize: 10, checksum: GoldenIndex.hash(4), policy: .onDemand),
            ManifestEntry(identifier: "heal.jpg", fileExtension: "jpg", remotePath: "media/heal.jpg", checksum: GoldenIndex.hash(5)),
            ManifestEntry(identifier: "quarantined.mp3", fileExtension: "mp3", remotePath: "media/q.mp3", byteSize: 5, checksum: GoldenIndex.hash(6)),
            ManifestEntry(identifier: "failed.mp4", fileExtension: "mp4", remotePath: "media/f.mp4"),
            ManifestEntry(identifier: "evicted.heic", fileExtension: "heic", remotePath: "media/e.heic", checksum: GoldenIndex.hash(8), tags: [""]),
            ManifestEntry(identifier: "purged.svg", fileExtension: "svg", remotePath: "media/p.svg", checksum: GoldenIndex.hash(9)),
            ManifestEntry(identifier: "healing.png", fileExtension: "png", remotePath: "media/h.png", checksum: GoldenIndex.hash(10)),
            ManifestEntry(identifier: AssetID("caf\u{E9}"), fileExtension: "png", remotePath: "media/cafe1.png", checksum: GoldenIndex.hash(11)),
            ManifestEntry(identifier: AssetID("cafe\u{301}"), fileExtension: "png", remotePath: "media/cafe2.png", checksum: GoldenIndex.hash(12)),
        ]
        var records: [AssetID: AssetRecord] = [:]
        func add(_ index: Int, _ residency: Residency, expected: ContentHash?, integrity: IntegrityHistory = .clean, pinned: Bool = false, stored: Date? = nil, verified: Date? = nil, revision: UInt64 = 0) {
            let entry = entries[index]
            records[entry.identifier] = AssetRecord(
                entry: entry,
                residency: residency,
                expectedBlob: expected,
                lastAccess: GoldenIndex.date(700_000_000.125 + Double(index)),
                storedAt: stored,
                verifiedAt: verified,
                pinned: pinned,
                integrity: integrity,
                revision: revision
            )
        }
        add(0, .present(blob: GoldenIndex.key(1, "png"), byteSize: 1_234, integrity: .verified), expected: GoldenIndex.hash(1), pinned: true, stored: GoldenIndex.date(1.5), verified: GoldenIndex.date(2.25), revision: 3)
        add(1, .absent(.neverFetched), expected: GoldenIndex.hash(2))
        add(2, .present(blob: GoldenIndex.key(3, "wav"), byteSize: 77, integrity: .unverified), expected: GoldenIndex.hash(3), stored: GoldenIndex.date(-3.5))
        add(3, .present(blob: GoldenIndex.key(40, "png"), byteSize: 10, integrity: .verified), expected: GoldenIndex.hash(4), revision: 2)
        add(4, .needsHeal(lastBlob: GoldenIndex.key(5, "jpg")), expected: GoldenIndex.hash(5))
        add(
            5, .quarantined(until: GoldenIndex.date(800_000_000.5)), expected: GoldenIndex.hash(6),
            integrity: IntegrityHistory(attempts: 1, failedIdentity: .checksum(GoldenIndex.hash(6)), nextEligibleAt: GoldenIndex.date(800_000_000.5))
        )
        add(6, .failed(.notFound), expected: nil, integrity: IntegrityHistory(attempts: 3, failedIdentity: .unverified(remotePath: "media/f.mp4")))
        add(7, .absent(.evicted), expected: GoldenIndex.hash(8))
        add(8, .absent(.purged), expected: GoldenIndex.hash(9))
        add(9, .absent(.healing), expected: GoldenIndex.hash(10))
        add(10, .needsHeal(lastBlob: GoldenIndex.key(70, "png")), expected: GoldenIndex.hash(11))
        add(11, .failed(.integrity), expected: GoldenIndex.hash(12))
        let detached = ManifestEntry(identifier: "detached.bin", fileExtension: "bin", remotePath: "media/d.bin", byteSize: 4)
        records[detached.identifier] = AssetRecord(
            entry: detached,
            residency: .failed(.unreadable),
            expectedBlob: GoldenIndex.hash(20),
            lastAccess: GoldenIndex.date(0)
        )
        let manifest = try! ValidatedManifest(
            entries: entries,
            quarantinedCount: 3,
            shape: .envelope(schemaVersion: 2),
            digest: GoldenIndex.hash(30)
        )
        return IndexContent(
            storeID: StoreIdentifier(high: 0x0123_4567_89AB_CDEF, low: 0xFEDC_BA98_7654_3210),
            generation: 7,
            launchEpoch: 6,
            writtenAtMillis: 1_700_000_000_123,
            degraded: false,
            appliedManifest: manifest,
            etag: ETag(rawValue: "\"abc\""),
            records: records,
            stamp: SyncStamp(appVersion: "2.1+40", completedAt: GoldenIndex.date(750_000_000.75), manifestETag: ETag(rawValue: "W/\"x\""), manifestDigest: GoldenIndex.hash(31)),
            syncDue: true,
            lastCleanupAt: GoldenIndex.date(760_000_000),
            legacyPhase: .inProgress,
            legacyStamp: "1.9+30",
            doomed: [GoldenIndex.key(50, "png"): .unreferenced, GoldenIndex.key(51, "jpg"): .purged, GoldenIndex.key(52, "wav"): .corrupt]
        )
    }
}
