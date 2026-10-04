import CryptoKit
import Foundation

/// A SHA-256 digest held as four big-endian 64-bit words.
///
/// Content identity of an asset (R-MAN-5) and the name of its blob (`blobs/<aa>/<hex>.<ext>`, R-STO-1). Four
/// words instead of `Data` keep it allocation-free, cheap to hash in a 10,000-entry dictionary (P-1, P-2) and
/// comparable without any pointer API. Hex text exists only at the edges: the manifest, file names, reports.
public struct ContentHash: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Bytes 0–7 of the digest, big-endian.
    public let w0: UInt64
    /// Bytes 8–15 of the digest, big-endian.
    public let w1: UInt64
    /// Bytes 16–23 of the digest, big-endian.
    public let w2: UInt64
    /// Bytes 24–31 of the digest, big-endian.
    public let w3: UInt64

    /// Creates a hash from its four words (index decoding).
    public init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    /// Creates a hash from exactly 32 bytes; `nil` for any other length.
    public init?<Bytes: Collection>(bytes: Bytes) where Bytes.Element == UInt8 {
        guard bytes.count == 32 else {
            return nil
        }
        var words: [UInt64] = [0, 0, 0, 0]
        for (offset, byte) in bytes.enumerated() {
            words[offset / 8] = (words[offset / 8] << 8) | UInt64(byte)
        }
        self.init(w0: words[0], w1: words[1], w2: words[2], w3: words[3])
    }

    /// Parses exactly 64 hexadecimal characters (either case); `nil` for anything else (R-MAN-2).
    public init?<Text: StringProtocol>(hex: Text) {
        let utf8 = Array(hex.utf8)
        guard utf8.count == 64 else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = 0
        while index < 64 {
            guard let high = ContentHash.nibble(utf8[index]), let low = ContentHash.nibble(utf8[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes: bytes)
    }

    /// Wraps a CryptoKit digest (streaming hash result, R-INT-1).
    public init(digest: SHA256.Digest) {
        var words: [UInt64] = [0, 0, 0, 0]
        for (offset, byte) in digest.enumerated() {
            words[offset / 8] = (words[offset / 8] << 8) | UInt64(byte)
        }
        self.init(w0: words[0], w1: words[1], w2: words[2], w3: words[3])
    }

    /// One-shot SHA-256 of in-memory bytes. Only for small values (manifest digests, tests); files are
    /// hashed by streaming in ≤ 1 MiB units off the cooperative pool (ADR-003, R-INT-1).
    public static func sha256(of data: Data) -> ContentHash {
        ContentHash(digest: SHA256.hash(data: data))
    }

    /// The 32 digest bytes in order.
    public var bytes: [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(32)
        for word in [self.w0, self.w1, self.w2, self.w3] {
            for shift in stride(from: 56, through: 0, by: -8) {
                result.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return result
    }

    /// 64 lowercase hexadecimal characters: the blob file name stem.
    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var scalars: [UInt8] = []
        scalars.reserveCapacity(64)
        for byte in self.bytes {
            scalars.append(digits[Int(byte >> 4)])
            scalars.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: scalars, as: UTF8.self)
    }

    /// The first two hex characters: the blob fan-out directory (`blobs/<aa>/`).
    public var fanOut: String {
        String(self.hex.prefix(2))
    }

    /// The lowercase hex form.
    public var description: String {
        self.hex
    }

    /// Lexicographic order of the digest bytes (a stable tie-breaker for eviction, R-CLN-4).
    public static func < (lhs: ContentHash, rhs: ContentHash) -> Bool {
        (lhs.w0, lhs.w1, lhs.w2, lhs.w3) < (rhs.w0, rhs.w1, rhs.w2, rhs.w3)
    }

    /// Decodes from a 64-character hex string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let hash = ContentHash(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "checksum is not 64 hexadecimal characters"
            )
        }
        self = hash
    }

    /// Encodes as a 64-character lowercase hex string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.hex)
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return character - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}
