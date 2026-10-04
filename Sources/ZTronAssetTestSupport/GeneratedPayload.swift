import CryptoKit
import Foundation
import ZTronAssetModel

/// Deterministic synthetic asset bytes for large catalogs (P-7, `FakeTransferStep.stageGenerated`; WP-H).
///
/// Byte `i` of the payload for `seed` is a pure function of `(seed, i)` (`KeyedRandom`, ADR-024), so a test computes
/// an entry's manifest checksum with `sha256(seed:byteCount:)` and the fake source writes the same bytes chunk by
/// chunk, and neither ever holds the whole payload: memory stays at one chunk whatever the catalog size.
public enum GeneratedPayload {
    /// The chunk the fake source generates and appends at a time (256 KiB): bounded memory for P-7.
    public static let chunkBytes = 256 * 1_024

    /// The key all payload draws use (`KeyedRandom` keys by what is drawn, ADR-024).
    private static let drawKey = StableHash.fnv1a64("GeneratedPayload")

    /// Bytes `[offset, offset + length)` of the payload for `seed`; empty for a non-positive `length` or a negative
    /// `offset`. Independent of how a payload is split into chunks.
    public static func bytes(seed: UInt64, offset: Int64, length: Int) -> Data {
        guard length > 0, offset >= 0 else {
            return Data()
        }
        var buffer: [UInt8] = []
        buffer.reserveCapacity(length)
        var position = offset
        let end = offset + Int64(length)
        while position < end {
            let word = KeyedRandom.next64(seed: seed, key: GeneratedPayload.drawKey, counter: UInt64(position >> 3))
            var lane = Int(position & 7)
            while lane < 8, position < end {
                buffer.append(UInt8(truncatingIfNeeded: word >> UInt64(lane * 8)))
                lane += 1
                position += 1
            }
        }
        return Data(buffer)
    }

    /// The SHA-256 of the whole payload of `byteCount` bytes, hashed in `chunkBytes` chunks (never the whole payload
    /// in memory): the manifest checksum of a generated entry.
    public static func sha256(seed: UInt64, byteCount: Int64) -> ContentHash {
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < byteCount {
            let length = Int(min(Int64(GeneratedPayload.chunkBytes), byteCount - offset))
            hasher.update(data: GeneratedPayload.bytes(seed: seed, offset: offset, length: length))
            offset += Int64(length)
        }
        return ContentHash(digest: hasher.finalize())
    }
}
