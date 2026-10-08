import CryptoKit
import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

@Suite("Core: index codec and load rule")
struct IndexCodecTests {
    @Test("R-STO-12: the v1 golden index fixture decodes and re-encodes byte-identically")
    func goldenFixture() throws {
        let directory = GoldenIndex.directory()
        let bytes = try Data(contentsOf: directory.appendingPathComponent("golden.bin"))
        let decoded = try IndexCodec.decode([UInt8](bytes)).get()
        #expect(decoded == GoldenIndex.content)
        #expect(IndexCodec.encode(decoded) == bytes)
        // The committed JSON description of the fixture's content agrees with what decodes.
        let description = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("golden.json"))) as? [String: Any]
        )
        #expect(description["schemaVersion"] as? Int == Int(StoreLayout.indexSchemaVersion))
        #expect(description["generation"] as? Int == Int(decoded.generation))
        #expect(description["launchEpoch"] as? Int == Int(decoded.launchEpoch))
        #expect(description["manifestOrder"] as? [String] == decoded.appliedManifest.entries.map(\.identifier.rawValue))
        #expect(description["detached"] as? [String] == ["detached.bin"])
        #expect(description["doomed"] as? [String: String] == Dictionary(uniqueKeysWithValues: decoded.doomed.map { ($0.key.fileName, "\($0.value)") }))
        #expect(description["records"] as? Int == decoded.records.count)
    }

    @Test("R-STO-12: every state the store persists survives an encode and decode unchanged")
    func roundTrip() throws {
        var content = GoldenIndex.content
        let encoded = try #require(IndexCodec.encode(content))
        #expect(try IndexCodec.decode([UInt8](encoded)).get() == content)
        content.degraded = true
        content.stamp = nil
        content.etag = nil
        content.lastCleanupAt = nil
        content.legacyStamp = nil
        content.syncDue = false
        content.doomed = [:]
        content.appliedManifest = CoreFixture.manifest([])
        content.records = [:]
        let empty = try #require(IndexCodec.encode(content))
        #expect(try IndexCodec.decode([UInt8](empty)).get() == content)
    }

    @Test("R-STO-12: a non-finite date is clamped when written, so every later generation stays loadable")
    func nonFiniteDatesAreClamped() throws {
        var content = GoldenIndex.content
        let id = try #require(content.records.keys.sorted().first)
        var record = try #require(content.records[id])
        record.residency = .quarantined(until: Date(timeIntervalSinceReferenceDate: .infinity))
        record.integrity = IntegrityHistory(attempts: 1, nextEligibleAt: Date(timeIntervalSinceReferenceDate: -.infinity))
        record.lastAccess = Date(timeIntervalSinceReferenceDate: .nan)
        content.records[id] = record
        let encoded = try #require(IndexCodec.encode(content))
        let decoded = try IndexCodec.decode([UInt8](encoded)).get()
        #expect(decoded.records[id]?.residency == .quarantined(until: .distantFuture))
        #expect(decoded.records[id]?.integrity.nextEligibleAt == .distantPast)
        #expect(decoded.records[id]?.lastAccess == .distantPast)
        #expect(IndexLoadRule.choose([.current: IndexFileRead(size: Int64(encoded.count), bytes: [UInt8](encoded))]).content == decoded)
        #expect(IndexCodec.encode(decoded) == encoded, "the clamped state re-encodes byte-identically")
    }

    @Test("R-STO-12: a header with a maximal generation or body length never traps")
    func maximalHeaderNeverTraps() throws {
        let valid = try #require(IndexCodec.encode(GoldenIndex.content))
        func patched(_ offset: Int, _ value: UInt64) -> [UInt8] {
            var bytes = [UInt8](valid)
            for index in 0..<8 {
                bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(8 * index))
            }
            return bytes
        }
        let maxGeneration = patched(16, .max)
        let maxBody = patched(24, .max)
        let maxEpoch = patched(40, .max)
        for bytes in [maxGeneration, maxBody, maxEpoch] {
            #expect(throws: IndexDecodeError.self) {
                try IndexCodec.decode(bytes).get()
            }
        }
        // A file that claims an enormous body is never read in full: the rule sees its header and size only.
        let outcome = IndexLoadRule.choose([
            .current: IndexFileRead(size: Int64(maxGeneration.count), bytes: maxGeneration),
            .temporary: IndexFileRead(size: IndexHeader.maxFileLength + 1, bytes: Array(maxBody.prefix(64))),
            .previous: IndexFileRead(size: Int64(maxEpoch.count), bytes: maxEpoch),
        ])
        #expect(outcome.content == nil)
        #expect(outcome.degraded)
        // Headers at or above 2^62 do not count; the body-length one does (generation 7).
        #expect(outcome.nextGeneration == 8)
    }

    @Test("R-STO-4: the load rule prefers the newest valid generation and ignores another store's files")
    func loadRuleChoice() throws {
        var older = GoldenIndex.content
        older.generation = 5
        var newer = GoldenIndex.content
        newer.generation = 9
        var foreign = GoldenIndex.content
        foreign.generation = 12
        foreign.storeID = StoreIdentifier(high: 1, low: 2)
        func read(_ content: IndexContent) throws -> IndexFileRead {
            let bytes = try #require(IndexCodec.encode(content))
            return IndexFileRead(size: Int64(bytes.count), bytes: [UInt8](bytes))
        }
        let chosen = IndexLoadRule.choose([.current: try read(older), .temporary: try read(newer)])
        #expect(chosen.content?.generation == 9 && chosen.chosen == .temporary && !chosen.degraded && chosen.nextGeneration == 10)
        // index.tmp is truncated by the launch commit: only index.bin's generation survives its failure.
        #expect(chosen.survivingGeneration == 5)
        #expect(IndexLoadRule.choose([.temporary: try read(newer)]).survivingGeneration == 0)
        #expect(IndexLoadRule.choose([.current: try read(newer), .previous: try read(older)]).survivingGeneration == 9)
        // The newest valid file names the lineage; an older file of another lineage is ignored.
        let lineage = IndexLoadRule.choose([.current: try read(newer), .previous: try read(GoldenIndex.content.with(storeID: StoreIdentifier(high: 9, low: 9)))])
        #expect(lineage.content?.generation == 9)
        let foreignNewest = IndexLoadRule.choose([.current: try read(newer), .temporary: try read(foreign)])
        #expect(foreignNewest.content?.storeID == foreign.storeID && foreignNewest.nextGeneration == 13)
        // Nothing at all is a fresh store, not a degraded one.
        let fresh = IndexLoadRule.choose([:])
        #expect(fresh.content == nil && !fresh.degraded && fresh.nextGeneration == 1 && !fresh.anyFileExisted)
    }

    @Test("R-STO-4: a newer schema, a corrupt index.bin or a degraded generation makes the load degraded")
    func degradedVerdicts() throws {
        let bytes = [UInt8](try #require(IndexCodec.encode(GoldenIndex.content)))
        var newer = bytes
        newer[8] = 2
        let newerOutcome = IndexLoadRule.choose([.current: IndexFileRead(size: Int64(newer.count), bytes: newer)])
        #expect(newerOutcome.degraded && newerOutcome.newerSchema && newerOutcome.nextGeneration == 8)
        let newerPrefix = IndexLoadRule.choose([.current: IndexFileRead(size: IndexHeader.maxFileLength * 2, bytes: Array(newer.prefix(64)))])
        #expect(newerPrefix.newerSchema)
        var corrupt = bytes
        corrupt[100] ^= 0xFF
        #expect(IndexCodec.decode(corrupt) == .failure(.trailerMismatch))
        let corruptOutcome = IndexLoadRule.choose([
            .current: IndexFileRead(size: Int64(corrupt.count), bytes: corrupt),
            .previous: IndexFileRead(size: Int64(bytes.count), bytes: bytes),
        ])
        #expect(corruptOutcome.degraded && corruptOutcome.content?.generation == 7 && corruptOutcome.chosen == .previous)
        var degradedContent = GoldenIndex.content
        degradedContent.degraded = true
        let flagged = [UInt8](try #require(IndexCodec.encode(degradedContent)))
        #expect(IndexLoadRule.choose([.current: IndexFileRead(size: Int64(flagged.count), bytes: flagged)]).degraded)
        #expect(IndexCodec.decode(Array(bytes.prefix(10))) == .failure(.torn))
        var badMagic = bytes
        badMagic[0] = 0
        #expect(IndexCodec.decode(badMagic) == .failure(.badMagic))
        #expect(IndexLoadRule.choose([.temporary: IndexFileRead(size: 200, bytes: Array(badMagic.prefix(64)))]).degraded)
        var schemaZero = bytes
        schemaZero[8] = 0
        #expect(IndexCodec.decode(schemaZero) == .failure(.malformed))
        #expect(IndexCodec.decode(bytes + [0]) == .failure(.torn))
    }

    @Test("R-STO-12: decoding seeded mutations of index bytes never traps, and whatever decodes re-encodes to the same state")
    func fuzzedDecodingNeverTraps() throws {
        let original = [UInt8](try #require(IndexCodec.encode(GoldenIndex.content)))
        let seed: UInt64 = 0xB0B_1DE5
        var generator = SplitMix64(seed: seed)
        var decodedCount = 0
        for round in 0..<3_000 {
            var bytes = original
            let edits = 1 + Int(generator.next() % 4)
            for _ in 0..<edits {
                let position = 64 + Int(generator.next() % UInt64(bytes.count - 96))
                switch generator.next() % 4 {
                case 0:
                    bytes[position] ^= UInt8(truncatingIfNeeded: generator.next() | 1)
                case 1:
                    bytes[position] = 0xFF
                case 2:
                    bytes[position] = 0x00
                default:
                    bytes[position] = UInt8(truncatingIfNeeded: generator.next())
                }
            }
            // Re-sign half the cases so the body decoder, not only the trailer check, sees the mutation.
            if round % 2 == 0 {
                let signed = bytes.count - 32
                bytes.replaceSubrange(signed..<bytes.count, with: Array(SHA256.hash(data: bytes[0..<signed])))
            }
            if case .success(let content) = IndexCodec.decode(bytes) {
                decodedCount += 1
                let again = try #require(IndexCodec.encode(content), "seed \(seed) round \(round)")
                #expect(try IndexCodec.decode([UInt8](again)).get() == content, "seed \(seed) round \(round)")
            }
        }
        print("R-STO-12 fuzz: seed \(seed), 3000 mutations, \(decodedCount) still decoded")
        #expect(decodedCount < 3_000)
    }

    @Test("R-STO-12: varints, zigzag values and bounds checks round-trip and reject overlong or overflowing input")
    func primitiveEncodings() throws {
        var writer = IndexByteWriter()
        let values: [UInt64] = [0, 1, 127, 128, 16_383, 16_384, UInt64(UInt32.max), .max]
        for value in values {
            writer.varint(value)
        }
        for value: Int64 in [0, -1, 1, .min, .max] {
            writer.zigzag(value)
        }
        writer.u16(0xBEEF)
        writer.u32(0xDEAD_BEEF)
        var reader = IndexByteReader(writer.bytes)
        for value in values {
            #expect(try reader.varint() == value)
        }
        for value: Int64 in [0, -1, 1, .min, .max] {
            #expect(try reader.zigzag() == value)
        }
        #expect(try reader.u16() == 0xBEEF)
        #expect(try reader.u32() == 0xDEAD_BEEF)
        #expect(reader.isAtEnd)
        var overlong = IndexByteReader([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02])
        #expect(throws: IndexDecodeError.malformed) {
            try overlong.varint()
        }
        var tooMany = IndexByteReader([0x05, 0x00])
        #expect(throws: IndexDecodeError.limitExceeded) {
            try tooMany.count(minimumBytesEach: 1)
        }
        var short = IndexByteReader([0x01])
        #expect(throws: IndexDecodeError.malformed) {
            try short.u64()
        }
        #expect(throws: IndexDecodeError.malformed) {
            try short.hash()
        }
        #expect(throws: IndexDecodeError.malformed) {
            try short.take(5)
        }
        var nonFinite = IndexByteReader(Array(repeating: 0xFF, count: 8))
        #expect(throws: IndexDecodeError.malformed) {
            try nonFinite.date()
        }
        #expect(IndexHeader.parse([UInt8](repeating: 0, count: 63)) == nil)
    }
}

extension IndexContent {
    /// The same content under another lineage.
    func with(storeID: StoreIdentifier) -> IndexContent {
        var copy = self
        copy.storeID = storeID
        return copy
    }
}
