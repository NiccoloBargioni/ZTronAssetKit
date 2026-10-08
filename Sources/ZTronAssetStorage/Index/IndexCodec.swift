import CryptoKit
import Foundation
import ZTronAssetModel

/// The fixed 64-byte header of an index file (schema 1; ADR-012 amended, ADR draft B-3).
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 8 | magic `ZTAKIDX\0` |
/// | 8 | 2 | `schemaVersion` |
/// | 10 | 2 | `sectionCount` |
/// | 12 | 4 | flags (bit 0 `degraded`) |
/// | 16 | 8 | `generation` |
/// | 24 | 8 | `bodyLength` (≤ 64 MiB) |
/// | 32 | 8 | `writtenAtMillis` |
/// | 40 | 8 | launch epoch |
/// | 48 | 16 | `storeID` |
struct IndexHeader: Sendable, Hashable {
    /// The schema that wrote the file.
    var schemaVersion: UInt16
    /// Sections in the body.
    var sectionCount: UInt16
    /// Header flags.
    var flags: UInt32
    /// The generation.
    var generation: UInt64
    /// Body bytes between the header and the trailer.
    var bodyLength: UInt64
    /// Diagnostics.
    var writtenAtMillis: Int64
    /// The writer's launch epoch.
    var launchEpoch: UInt64
    /// The store lineage.
    var storeID: StoreIdentifier

    /// Header size in bytes.
    static let length = 64
    /// Trailer size in bytes (SHA-256).
    static let trailerLength = 32
    /// `ZTAKIDX\0`.
    static let magic: [UInt8] = [0x5A, 0x54, 0x41, 0x4B, 0x49, 0x44, 0x58, 0x00]
    /// The body bound, checked before any arithmetic on it (store-1 S1-04).
    static let maxBodyLength: UInt64 = 64 << 20
    /// Generations and epochs at or above this make a header malformed, so `1 + max` can never overflow.
    static let generationCeiling: UInt64 = 1 << 62
    /// The largest file the load rule reads in full.
    static let maxFileLength = Int64(IndexHeader.length) + Int64(IndexHeader.maxBodyLength) + Int64(IndexHeader.trailerLength)

    /// Parses the first 64 bytes; `nil` when they are missing, the magic is wrong, or a generation or epoch is at
    /// or above 2⁶² (such a header does not count as parsed for `nextGeneration`).
    static func parse(_ bytes: [UInt8]) -> IndexHeader? {
        guard bytes.count >= IndexHeader.length, Array(bytes[0..<8]) == IndexHeader.magic else {
            return nil
        }
        var reader = IndexByteReader(bytes, start: 8, end: IndexHeader.length)
        do throws(IndexDecodeError) {
            let header = IndexHeader(
                schemaVersion: try reader.u16(),
                sectionCount: try reader.u16(),
                flags: try reader.u32(),
                generation: try reader.u64(),
                bodyLength: try reader.u64(),
                writtenAtMillis: Int64(bitPattern: try reader.u64()),
                launchEpoch: try reader.u64(),
                storeID: StoreIdentifier(high: try reader.u64(), low: try reader.u64())
            )
            guard header.generation < IndexHeader.generationCeiling, header.launchEpoch < IndexHeader.generationCeiling else {
                return nil
            }
            return header
        } catch {
            return nil
        }
    }

    /// The 64 encoded bytes.
    func encoded() -> [UInt8] {
        var writer = IndexByteWriter(capacity: IndexHeader.length)
        writer.append(IndexHeader.magic)
        writer.u16(self.schemaVersion)
        writer.u16(self.sectionCount)
        writer.u32(self.flags)
        writer.u64(self.generation)
        writer.u64(self.bodyLength)
        writer.u64(UInt64(bitPattern: self.writtenAtMillis))
        writer.u64(self.launchEpoch)
        writer.u64(self.storeID.high)
        writer.u64(self.storeID.low)
        return writer.bytes
    }
}

/// Encodes and decodes one index generation (store.md §2.3 as amended by ADR-012; the exact v1 byte layout is ADR
/// draft B-3). Pure: the commit unit encodes off the actor, the load rule decodes off the actor.
///
/// Body: sections `(tag u8, length varint, payload)` in increasing tag order — STAMPS `0x01`, STRINGS `0x02`,
/// RECORDS `0x03`, DOOMED `0x04`; an unknown tag below `0x80` is malformed, one at or above is skipped. Strings are
/// interned by their UTF-8 bytes, so identifiers that differ only in Unicode normalisation stay distinct.
enum IndexCodec {
    /// The header flag of degraded mode.
    static let degradedFlag: UInt32 = 1
    static let stampsTag: UInt8 = 0x01
    static let stringsTag: UInt8 = 0x02
    static let recordsTag: UInt8 = 0x03
    static let doomedTag: UInt8 = 0x04

    // MARK: Encoding

    /// The complete file for `content`: header, body, SHA-256 trailer. `nil` only when the body would exceed
    /// 64 MiB (far above the 100,000-entry manifest limit).
    static func encode(_ content: IndexContent) -> Data? {
        var strings = StringTable()
        let stamps = IndexCodec.encodeStamps(content, strings: &strings)
        let records = IndexCodec.encodeRecords(content, strings: &strings)
        let doomed = IndexCodec.encodeDoomed(content.doomed, strings: &strings)
        var body = IndexByteWriter(capacity: stamps.count + records.count + doomed.count + strings.byteEstimate + 32)
        IndexCodec.appendSection(IndexCodec.stampsTag, stamps, to: &body)
        IndexCodec.appendSection(IndexCodec.stringsTag, strings.encoded(), to: &body)
        IndexCodec.appendSection(IndexCodec.recordsTag, records, to: &body)
        IndexCodec.appendSection(IndexCodec.doomedTag, doomed, to: &body)
        guard UInt64(body.bytes.count) <= IndexHeader.maxBodyLength else {
            return nil
        }
        let header = IndexHeader(
            schemaVersion: StoreLayout.indexSchemaVersion,
            sectionCount: 4,
            flags: content.degraded ? IndexCodec.degradedFlag : 0,
            generation: content.generation,
            bodyLength: UInt64(body.bytes.count),
            writtenAtMillis: content.writtenAtMillis,
            launchEpoch: content.launchEpoch,
            storeID: content.storeID
        )
        var file = header.encoded()
        file.reserveCapacity(file.count + body.bytes.count + IndexHeader.trailerLength)
        file.append(contentsOf: body.bytes)
        file.append(contentsOf: SHA256.hash(data: file))
        return Data(file)
    }

    private static func appendSection(_ tag: UInt8, _ payload: [UInt8], to body: inout IndexByteWriter) {
        body.u8(tag)
        body.count(payload.count)
        body.append(payload)
    }

    private static func encodeStamps(_ content: IndexContent, strings: inout StringTable) -> [UInt8] {
        var presence: UInt64 = 0
        if content.stamp != nil {
            presence |= 1 << 0
        }
        if content.stamp?.manifestETag != nil {
            presence |= 1 << 1
        }
        if content.etag != nil {
            presence |= 1 << 2
        }
        if content.syncDue {
            presence |= 1 << 3
        }
        if content.lastCleanupAt != nil {
            presence |= 1 << 4
        }
        if content.legacyStamp != nil {
            presence |= 1 << 5
        }
        if case .envelope = content.appliedManifest.shape {
            presence |= 1 << 6
        }
        var writer = IndexByteWriter()
        writer.varint(presence)
        if let stamp = content.stamp {
            writer.count(strings.reference(stamp.appVersion))
            writer.date(stamp.completedAt)
            writer.hash(stamp.manifestDigest)
            if let tag = stamp.manifestETag {
                writer.count(strings.reference(tag.rawValue))
            }
        }
        if let etag = content.etag {
            writer.count(strings.reference(etag.rawValue))
        }
        if let cleanup = content.lastCleanupAt {
            writer.date(cleanup)
        }
        if let legacyStamp = content.legacyStamp {
            writer.count(strings.reference(legacyStamp))
        }
        writer.u8(content.legacyPhase.rawValue)
        writer.hash(content.appliedManifest.digest)
        if case .envelope(let schemaVersion) = content.appliedManifest.shape {
            writer.zigzag(Int64(schemaVersion))
        }
        writer.count(content.appliedManifest.quarantinedCount)
        return writer.bytes
    }

    private static func encodeRecords(_ content: IndexContent, strings: inout StringTable) -> [UInt8] {
        var writer = IndexByteWriter(capacity: content.records.count * 96)
        var ordered: [(record: AssetRecord, detached: Bool)] = []
        ordered.reserveCapacity(max(content.records.count, content.appliedManifest.count))
        for entry in content.appliedManifest.entries {
            // An applied entry without a record is, semantically, never fetched (the codec canonicalises it).
            let record =
                content.records[entry.identifier]
                ?? AssetRecord(entry: entry, residency: .absent(.neverFetched), expectedBlob: entry.checksum, lastAccess: Date(timeIntervalSinceReferenceDate: 0))
            ordered.append((record, false))
        }
        for id in content.records.keys.sorted() where !content.appliedManifest.contains(id) {
            if let record = content.records[id] {
                ordered.append((record, true))
            }
        }
        writer.count(ordered.count)
        for (record, detached) in ordered {
            IndexCodec.encodeRecord(record, detached: detached, strings: &strings, into: &writer)
        }
        return writer.bytes
    }

    private static func encodeRecord(_ record: AssetRecord, detached: Bool, strings: inout StringTable, into writer: inout IndexByteWriter) {
        let entry = record.entry
        let blobHash: ContentHash?
        switch record.residency {
        case .present(let blob, _, _), .needsHeal(let blob):
            blobHash = blob.hash
        default:
            blobHash = nil
        }
        var flags: UInt64 = 0
        if entry.localFileName != nil {
            flags |= 1 << 0
        }
        if entry.checksum != nil {
            flags |= 1 << 1
        }
        if entry.byteSize != nil {
            flags |= 1 << 2
        }
        if record.pinned {
            flags |= 1 << 3
        }
        if let expected = record.expectedBlob {
            flags |= 1 << 4
            if expected == entry.checksum {
                flags |= 1 << 5
            }
            if expected == blobHash {
                flags |= 1 << 11
            }
        }
        if record.storedAt != nil {
            flags |= 1 << 6
        }
        if record.verifiedAt != nil {
            flags |= 1 << 7
        }
        if record.integrity.failedIdentity != nil {
            flags |= 1 << 8
        }
        if record.integrity.nextEligibleAt != nil {
            flags |= 1 << 9
        }
        if detached {
            flags |= 1 << 10
        }
        writer.varint(flags)
        writer.count(strings.reference(entry.identifier.rawValue))
        writer.count(strings.reference(entry.fileExtension))
        writer.count(strings.reference(entry.remotePath))
        writer.count(entry.localPathComponents.count)
        for component in entry.localPathComponents {
            writer.count(strings.reference(component))
        }
        if let name = entry.localFileName {
            writer.count(strings.reference(name))
        }
        if let size = entry.byteSize {
            writer.zigzag(size)
        }
        if let checksum = entry.checksum {
            writer.hash(checksum)
        }
        writer.count(entry.tags.count)
        for tag in entry.tags {
            writer.count(strings.reference(tag))
        }
        writer.u8(IndexCodec.policyCode(entry.policy))
        let omitBlobHash = flags & (1 << 11) != 0
        switch record.residency {
        case .absent(let reason):
            writer.u8(0)
            writer.u8(IndexCodec.absenceCode(reason))
        case .present(let blob, let byteSize, let integrity):
            writer.u8(1)
            if !omitBlobHash {
                writer.hash(blob.hash)
            }
            writer.count(strings.reference(blob.ext.rawValue))
            writer.zigzag(byteSize)
            writer.u8(integrity == .verified ? 0 : 1)
        case .needsHeal(let blob):
            writer.u8(2)
            if !omitBlobHash {
                writer.hash(blob.hash)
            }
            writer.count(strings.reference(blob.ext.rawValue))
        case .quarantined(let until):
            writer.u8(3)
            writer.date(until)
        case .failed(let reason):
            writer.u8(4)
            writer.u8(IndexCodec.failureCode(reason))
        }
        if let expected = record.expectedBlob, expected != entry.checksum {
            writer.hash(expected)
        }
        writer.date(record.lastAccess)
        if let storedAt = record.storedAt {
            writer.date(storedAt)
        }
        if let verifiedAt = record.verifiedAt {
            writer.date(verifiedAt)
        }
        writer.u8(record.integrity.attempts)
        switch record.integrity.failedIdentity {
        case .checksum(let hash):
            writer.u8(0)
            writer.hash(hash)
        case .unverified(let remotePath):
            writer.u8(1)
            writer.count(strings.reference(remotePath))
        case nil:
            break
        }
        if let next = record.integrity.nextEligibleAt {
            writer.date(next)
        }
        writer.varint(record.revision)
    }

    private static func encodeDoomed(_ doomed: [BlobKey: DoomReason], strings: inout StringTable) -> [UInt8] {
        var writer = IndexByteWriter(capacity: doomed.count * 36)
        writer.count(doomed.count)
        for key in doomed.keys.sorted() {
            writer.hash(key.hash)
            writer.count(strings.reference(key.ext.rawValue))
            writer.u8(IndexCodec.doomCode(doomed[key] ?? .unreferenced))
        }
        return writer.bytes
    }

    // MARK: Decoding

    /// Validates and decodes a complete file: size, magic, schema, trailer, then the body. Never traps.
    static func decode(_ bytes: [UInt8]) -> Result<IndexContent, IndexDecodeError> {
        guard bytes.count >= IndexHeader.length else {
            return .failure(.torn)
        }
        guard Array(bytes[0..<8]) == IndexHeader.magic else {
            return .failure(.badMagic)
        }
        guard let header = IndexHeader.parse(bytes) else {
            return .failure(.malformed)
        }
        if header.schemaVersion > StoreLayout.indexSchemaVersion {
            return .failure(.newerSchema(header.schemaVersion))
        }
        guard header.schemaVersion == StoreLayout.indexSchemaVersion else {
            return .failure(.malformed)
        }
        guard header.bodyLength <= IndexHeader.maxBodyLength else {
            return .failure(.limitExceeded)
        }
        let expected = IndexHeader.length + Int(header.bodyLength) + IndexHeader.trailerLength
        guard bytes.count == expected else {
            return .failure(.torn)
        }
        let signed = IndexHeader.length + Int(header.bodyLength)
        let digest = Array(SHA256.hash(data: bytes[0..<signed]))
        guard digest.elementsEqual(bytes[signed..<expected]) else {
            return .failure(.trailerMismatch)
        }
        do throws(IndexDecodeError) {
            return .success(try IndexCodec.decodeBody(bytes, header: header))
        } catch {
            return .failure(error)
        }
    }

    private static func decodeBody(_ bytes: [UInt8], header: IndexHeader) throws(IndexDecodeError) -> IndexContent {
        var reader = IndexByteReader(bytes, start: IndexHeader.length, end: IndexHeader.length + Int(header.bodyLength))
        var sections: [UInt8: (start: Int, end: Int)] = [:]
        var lastTag: Int = -1
        var count = 0
        while !reader.isAtEnd {
            let tag = try reader.u8()
            guard Int(tag) > lastTag else {
                throw .malformed
            }
            lastTag = Int(tag)
            let length = try reader.count(minimumBytesEach: 1)
            let start = reader.offset
            _ = try reader.take(length)
            count += 1
            if tag < 0x80 {
                guard (IndexCodec.stampsTag...IndexCodec.doomedTag).contains(tag) else {
                    throw .malformed
                }
                sections[tag] = (start, start + length)
            }
        }
        guard count == Int(header.sectionCount), let stampsRange = sections[IndexCodec.stampsTag],
            let stringsRange = sections[IndexCodec.stringsTag], let recordsRange = sections[IndexCodec.recordsTag],
            let doomedRange = sections[IndexCodec.doomedTag]
        else {
            throw .malformed
        }
        var stringsReader = IndexByteReader(bytes, start: stringsRange.start, end: stringsRange.end)
        let strings = try IndexCodec.decodeStrings(&stringsReader)
        var content = IndexContent.empty(storeID: header.storeID)
        content.generation = header.generation
        content.launchEpoch = header.launchEpoch
        content.writtenAtMillis = header.writtenAtMillis
        content.degraded = header.flags & IndexCodec.degradedFlag != 0
        var stampsReader = IndexByteReader(bytes, start: stampsRange.start, end: stampsRange.end)
        let manifestMeta = try IndexCodec.decodeStamps(&stampsReader, strings: strings, into: &content)
        var recordsReader = IndexByteReader(bytes, start: recordsRange.start, end: recordsRange.end)
        let entries = try IndexCodec.decodeRecords(&recordsReader, strings: strings, into: &content)
        do {
            content.appliedManifest = try ValidatedManifest(
                entries: entries,
                quarantined: [],
                quarantinedCount: manifestMeta.quarantinedCount,
                shape: manifestMeta.shape,
                digest: manifestMeta.digest
            )
        } catch {
            throw .malformed
        }
        var doomedReader = IndexByteReader(bytes, start: doomedRange.start, end: doomedRange.end)
        content.doomed = try IndexCodec.decodeDoomed(&doomedReader, strings: strings)
        return content
    }

    private static func decodeStrings(_ reader: inout IndexByteReader) throws(IndexDecodeError) -> [String] {
        let count = try reader.count(minimumBytesEach: 1)
        var strings: [String] = []
        strings.reserveCapacity(count)
        for _ in 0..<count {
            let length = try reader.count(minimumBytesEach: 1)
            let slice = try reader.take(length)
            guard let text = String(bytes: slice, encoding: .utf8) else {
                throw .malformed
            }
            strings.append(text)
        }
        guard reader.isAtEnd else {
            throw .malformed
        }
        return strings
    }

    private struct ManifestMeta {
        var digest: ContentHash
        var shape: ManifestWireShape
        var quarantinedCount: Int
    }

    private static func decodeStamps(_ reader: inout IndexByteReader, strings: [String], into content: inout IndexContent) throws(IndexDecodeError)
        -> ManifestMeta
    {
        let presence = try reader.varint()
        guard presence < (1 << 7) else {
            throw .malformed
        }
        if presence & (1 << 0) != 0 {
            let appVersion = try IndexCodec.string(&reader, strings)
            let completedAt = try reader.date()
            let digest = try reader.hash()
            var tag: ETag?
            if presence & (1 << 1) != 0 {
                tag = try IndexCodec.etag(&reader, strings)
            }
            content.stamp = SyncStamp(appVersion: appVersion, completedAt: completedAt, manifestETag: tag, manifestDigest: digest)
        } else if presence & (1 << 1) != 0 {
            throw .malformed
        }
        if presence & (1 << 2) != 0 {
            content.etag = try IndexCodec.etag(&reader, strings)
        }
        content.syncDue = presence & (1 << 3) != 0
        if presence & (1 << 4) != 0 {
            content.lastCleanupAt = try reader.date()
        }
        if presence & (1 << 5) != 0 {
            content.legacyStamp = try IndexCodec.string(&reader, strings)
        }
        guard let phase = LegacyMigrationPhase(rawValue: try reader.u8()) else {
            throw .malformed
        }
        content.legacyPhase = phase
        let digest = try reader.hash()
        var shape = ManifestWireShape.bareArray
        if presence & (1 << 6) != 0 {
            let version = try reader.zigzag()
            guard let schemaVersion = Int(exactly: version) else {
                throw .malformed
            }
            shape = .envelope(schemaVersion: schemaVersion)
        }
        let quarantined = try reader.varint()
        guard quarantined <= UInt64(Int.max), reader.isAtEnd else {
            throw .malformed
        }
        return ManifestMeta(digest: digest, shape: shape, quarantinedCount: Int(quarantined))
    }

    private static func decodeRecords(_ reader: inout IndexByteReader, strings: [String], into content: inout IndexContent) throws(IndexDecodeError)
        -> [ManifestEntry]
    {
        // A record needs at least 16 bytes (flags, three references, two counts, policy, residency, an 8-byte
        // access time, attempts, revision), which bounds the count by the section's size.
        let count = try reader.count(minimumBytesEach: 16)
        var entries: [ManifestEntry] = []
        entries.reserveCapacity(count)
        var records: [AssetID: AssetRecord] = [:]
        records.reserveCapacity(count)
        var detachedSeen = false
        for _ in 0..<count {
            let (record, detached) = try IndexCodec.decodeRecord(&reader, strings: strings)
            guard records.updateValue(record, forKey: record.entry.identifier) == nil else {
                throw .malformed
            }
            if detached {
                detachedSeen = true
            } else {
                // Detached records follow every applied one.
                guard !detachedSeen else {
                    throw .malformed
                }
                entries.append(record.entry)
            }
        }
        guard reader.isAtEnd else {
            throw .malformed
        }
        content.records = records
        return entries
    }

    private static func decodeRecord(_ reader: inout IndexByteReader, strings: [String]) throws(IndexDecodeError)
        -> (record: AssetRecord, detached: Bool)
    {
        let flags = try reader.varint()
        guard flags < (1 << 12) else {
            throw .malformed
        }
        let id = AssetID(try IndexCodec.string(&reader, strings))
        let fileExtension = try IndexCodec.string(&reader, strings)
        let remotePath = try IndexCodec.string(&reader, strings)
        let componentCount = try reader.count(minimumBytesEach: 1)
        var components: [String] = []
        components.reserveCapacity(componentCount)
        for _ in 0..<componentCount {
            components.append(try IndexCodec.string(&reader, strings))
        }
        let fileName = flags & (1 << 0) != 0 ? try IndexCodec.string(&reader, strings) : nil
        let byteSize = flags & (1 << 2) != 0 ? try reader.zigzag() : nil
        let checksum = flags & (1 << 1) != 0 ? try reader.hash() : nil
        let tagCount = try reader.count(minimumBytesEach: 1)
        var tags: [String] = []
        tags.reserveCapacity(tagCount)
        for _ in 0..<tagCount {
            tags.append(try IndexCodec.string(&reader, strings))
        }
        let policy = try IndexCodec.policy(try reader.u8())
        let entry = ManifestEntry(
            identifier: id,
            fileExtension: fileExtension,
            remotePath: remotePath,
            localPathComponents: components,
            localFileName: fileName,
            byteSize: byteSize,
            checksum: checksum,
            tags: tags,
            policy: policy
        )
        let hasExpected = flags & (1 << 4) != 0
        let expectedIsChecksum = flags & (1 << 5) != 0
        let blobIsExpected = flags & (1 << 11) != 0
        guard hasExpected || (!expectedIsChecksum && !blobIsExpected), !expectedIsChecksum || checksum != nil else {
            throw .malformed
        }
        // The residency's blob hash may be "the expected blob", which is only known after the residency; it is
        // resolved once the expectation is read.
        let residencyTag = try reader.u8()
        var pendingBlob: (hash: ContentHash?, ext: AssetFileExtension)?
        var residency: Residency
        switch residencyTag {
        case 0:
            residency = .absent(try IndexCodec.absence(try reader.u8()))
        case 1:
            let hash = blobIsExpected ? nil : try reader.hash()
            let ext = try IndexCodec.blobExtension(&reader, strings)
            let size = try reader.zigzag()
            let integrity = try reader.u8()
            guard size >= 0, integrity <= 1 else {
                throw .malformed
            }
            pendingBlob = (hash, ext)
            residency = .present(
                blob: BlobKey(hash: hash ?? ContentHash(w0: 0, w1: 0, w2: 0, w3: 0), ext: ext),
                byteSize: size,
                integrity: integrity == 0 ? .verified : .unverified
            )
        case 2:
            let hash = blobIsExpected ? nil : try reader.hash()
            let ext = try IndexCodec.blobExtension(&reader, strings)
            pendingBlob = (hash, ext)
            residency = .needsHeal(lastBlob: BlobKey(hash: hash ?? ContentHash(w0: 0, w1: 0, w2: 0, w3: 0), ext: ext))
        case 3:
            residency = .quarantined(until: try reader.date())
        case 4:
            residency = .failed(try IndexCodec.failure(try reader.u8()))
        default:
            throw .malformed
        }
        guard pendingBlob != nil || !blobIsExpected else {
            throw .malformed
        }
        var expected: ContentHash?
        if hasExpected {
            expected = expectedIsChecksum ? checksum : try reader.hash()
        }
        if let pending = pendingBlob, pending.hash == nil, let expected {
            // The flag said the blob is the expected one; rebuild the residency with it.
            switch residency {
            case .present(_, let size, let integrity):
                residency = .present(blob: BlobKey(hash: expected, ext: pending.ext), byteSize: size, integrity: integrity)
            case .needsHeal:
                residency = .needsHeal(lastBlob: BlobKey(hash: expected, ext: pending.ext))
            default:
                break
            }
        }
        // A blob hash written out in full must not equal the expectation (the encoder would have omitted it), so
        // every file has exactly one encoding and re-encodes byte-identically (R-STO-12).
        if let pending = pendingBlob, let hash = pending.hash, hash == expected {
            throw .malformed
        }
        if hasExpected, !expectedIsChecksum, expected == checksum {
            throw .malformed
        }
        let lastAccess = try reader.date()
        let storedAt = flags & (1 << 6) != 0 ? try reader.date() : nil
        let verifiedAt = flags & (1 << 7) != 0 ? try reader.date() : nil
        let attempts = try reader.u8()
        var failedIdentity: ContentIdentity?
        if flags & (1 << 8) != 0 {
            switch try reader.u8() {
            case 0:
                failedIdentity = .checksum(try reader.hash())
            case 1:
                failedIdentity = .unverified(remotePath: try IndexCodec.string(&reader, strings))
            default:
                throw .malformed
            }
        }
        let nextEligibleAt = flags & (1 << 9) != 0 ? try reader.date() : nil
        let revision = try reader.varint()
        let record = AssetRecord(
            entry: entry,
            residency: residency,
            expectedBlob: expected,
            lastAccess: lastAccess,
            storedAt: storedAt,
            verifiedAt: verifiedAt,
            pinned: flags & (1 << 3) != 0,
            integrity: IntegrityHistory(attempts: attempts, failedIdentity: failedIdentity, nextEligibleAt: nextEligibleAt),
            revision: revision
        )
        return (record, flags & (1 << 10) != 0)
    }

    private static func decodeDoomed(_ reader: inout IndexByteReader, strings: [String]) throws(IndexDecodeError) -> [BlobKey: DoomReason] {
        let count = try reader.count(minimumBytesEach: 34)
        var doomed: [BlobKey: DoomReason] = [:]
        doomed.reserveCapacity(count)
        var previous: BlobKey?
        for _ in 0..<count {
            let hash = try reader.hash()
            let key = BlobKey(hash: hash, ext: try IndexCodec.blobExtension(&reader, strings))
            // Sorted and unique, as the encoder writes them: one encoding per state.
            if let previous, !(previous < key) {
                throw .malformed
            }
            previous = key
            doomed[key] = try IndexCodec.doom(try reader.u8())
        }
        guard reader.isAtEnd else {
            throw .malformed
        }
        return doomed
    }

    // MARK: Field helpers

    private static func string(_ reader: inout IndexByteReader, _ strings: [String]) throws(IndexDecodeError) -> String {
        let index = try reader.varint()
        guard index < UInt64(strings.count) else {
            throw .malformed
        }
        return strings[Int(index)]
    }

    private static func etag(_ reader: inout IndexByteReader, _ strings: [String]) throws(IndexDecodeError) -> ETag {
        guard let tag = ETag(rawValue: try IndexCodec.string(&reader, strings)) else {
            throw .malformed
        }
        return tag
    }

    private static func blobExtension(_ reader: inout IndexByteReader, _ strings: [String]) throws(IndexDecodeError) -> AssetFileExtension {
        let raw = try IndexCodec.string(&reader, strings)
        guard let ext = AssetFileExtension(raw), ext.rawValue == raw else {
            throw .malformed
        }
        return ext
    }

    static func policyCode(_ policy: AssetPolicy) -> UInt8 {
        switch policy {
        case .standard:
            return 0
        case .essential:
            return 1
        case .onDemand:
            return 2
        }
    }

    private static func policy(_ code: UInt8) throws(IndexDecodeError) -> AssetPolicy {
        switch code {
        case 0:
            return .standard
        case 1:
            return .essential
        case 2:
            return .onDemand
        default:
            throw .malformed
        }
    }

    static func absenceCode(_ reason: AbsenceReason) -> UInt8 {
        switch reason {
        case .neverFetched:
            return 0
        case .evicted:
            return 1
        case .purged:
            return 2
        case .healing:
            return 3
        }
    }

    private static func absence(_ code: UInt8) throws(IndexDecodeError) -> AbsenceReason {
        switch code {
        case 0:
            return .neverFetched
        case 1:
            return .evicted
        case 2:
            return .purged
        case 3:
            return .healing
        default:
            throw .malformed
        }
    }

    static func failureCode(_ reason: FailureReason) -> UInt8 {
        switch reason {
        case .integrity:
            return 0
        case .unreadable:
            return 1
        case .notFound:
            return 2
        }
    }

    private static func failure(_ code: UInt8) throws(IndexDecodeError) -> FailureReason {
        switch code {
        case 0:
            return .integrity
        case 1:
            return .unreadable
        case 2:
            return .notFound
        default:
            throw .malformed
        }
    }

    static func doomCode(_ reason: DoomReason) -> UInt8 {
        switch reason {
        case .unreferenced:
            return 0
        case .purged:
            return 1
        case .corrupt:
            return 2
        }
    }

    private static func doom(_ code: UInt8) throws(IndexDecodeError) -> DoomReason {
        switch code {
        case 0:
            return .unreferenced
        case 1:
            return .purged
        case 2:
            return .corrupt
        default:
            throw .malformed
        }
    }
}

/// The STRINGS table under construction: interned by UTF-8 bytes in order of first use (deterministic output).
private struct StringTable {
    private var indices: [[UInt8]: Int] = [:]
    private var ordered: [[UInt8]] = []
    /// Encoded size estimate for buffer reservation.
    private(set) var byteEstimate = 0

    /// The index of `text`, interning it on first use.
    mutating func reference(_ text: String) -> Int {
        let bytes = Array(text.utf8)
        if let index = self.indices[bytes] {
            return index
        }
        let index = self.ordered.count
        self.indices[bytes] = index
        self.ordered.append(bytes)
        self.byteEstimate += bytes.count + 2
        return index
    }

    /// The section payload.
    func encoded() -> [UInt8] {
        var writer = IndexByteWriter(capacity: self.byteEstimate + 4)
        writer.count(self.ordered.count)
        for bytes in self.ordered {
            writer.count(bytes.count)
            writer.append(bytes)
        }
        return writer.bytes
    }
}
