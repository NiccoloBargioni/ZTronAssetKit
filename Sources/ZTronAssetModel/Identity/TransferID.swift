import CryptoKit
import Foundation

/// The identity of one *content* transfer, and the stem of its staging file names (ADR-013).
///
/// The engine single-flights per `TransferID`, not per `AssetID` (ADR-020): two manifest entries with the same
/// checksum share one download (transport-1 TR1-1). The alphabet is `[0-9a-z-]` and the length 1…96 bytes, so a
/// `TransferID` can never contain a path separator or a dot (R-SEC-2) and `StagingFileName` can split on dots.
public struct TransferID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// What a transfer identifies, read from its prefix.
    public enum Kind: Sendable, Hashable {
        /// `c-<64 hex>`: content with a manifest checksum.
        case content
        /// `l-<64 hex>`: a checksum-less (legacy, R-MAN-5) entry keyed by identifier and `remotePath`.
        case legacy
        /// `m-manifest`: the manifest document.
        case manifest
    }

    /// The validated identifier text.
    public let rawValue: String

    /// Validates `rawValue`: 1…96 bytes of `[0-9a-z-]` with a known prefix; `nil` otherwise.
    public init?(rawValue: String) {
        let utf8 = Array(rawValue.utf8)
        guard (1...96).contains(utf8.count) else {
            return nil
        }
        for byte in utf8 {
            let allowed =
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
            guard allowed else {
                return nil
            }
        }
        guard rawValue.hasPrefix("c-") || rawValue.hasPrefix("l-") || rawValue == "m-manifest" else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// The transfer of an entry with a checksum: `c-<hex>`. Equal content ⇒ equal transfer.
    public static func content(_ hash: ContentHash) -> TransferID {
        TransferID(validated: "c-" + hash.hex)
    }

    /// The transfer of a checksum-less entry: `l-` + SHA-256(identifier ‖ 0x00 ‖ remotePath). A legacy entry is
    /// re-fetched only when its `remotePath` changes (R-MAN-5), which changes this identity.
    public static func legacy(identifier: AssetID, remotePath: String) -> TransferID {
        var bytes = Array(identifier.rawValue.utf8)
        bytes.append(0)
        bytes.append(contentsOf: remotePath.utf8)
        return TransferID(validated: "l-" + ContentHash.sha256(of: Data(bytes)).hex)
    }

    /// The single manifest transfer (manifest fetches are single-flighted by the engine).
    public static let manifest = TransferID(validated: "m-manifest")

    /// The kind encoded in the prefix.
    public var kind: Kind {
        if self.rawValue.hasPrefix("c-") {
            return .content
        }
        if self.rawValue.hasPrefix("l-") {
            return .legacy
        }
        return .manifest
    }

    /// The identifier text.
    public var description: String {
        self.rawValue
    }

    /// Byte order of the identifier text (deterministic reconciliation output).
    public static func < (lhs: TransferID, rhs: TransferID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Decodes and validates a JSON string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = TransferID(rawValue: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid transfer identifier")
        }
        self = value
    }

    /// Encodes as a JSON string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    private init(validated: String) {
        self.rawValue = validated
    }
}

/// Which start of a transfer a staging file or OS task belongs to (ADR-013, transport-2 T2-06).
///
/// `epoch` is the store's launch epoch (the index generation allocated at `open()`, persisted and strictly
/// increasing across launches); `sequence` counts starts within the process. Ordering by `(epoch, sequence)` is
/// therefore meaningful across relaunches, and two starts can never share a name.
public struct TransferAttempt: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// The launch epoch of the process that started the attempt.
    public let epoch: UInt64
    /// The start counter within that process.
    public let sequence: UInt32

    /// Creates an attempt token.
    public init(epoch: UInt64, sequence: UInt32) {
        self.epoch = epoch
        self.sequence = sequence
    }

    /// Parses `"<epoch>-<sequence>"` (decimal, no sign, no leading `+`); `nil` otherwise.
    public init?(token: String) {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
            parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
            parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
            let epoch = UInt64(parts[0]),
            let sequence = UInt32(parts[1])
        else {
            return nil
        }
        self.init(epoch: epoch, sequence: sequence)
    }

    /// `"<epoch>-<sequence>"`, the middle component of a staging file name.
    public var token: String {
        "\(self.epoch)-\(self.sequence)"
    }

    /// The token form.
    public var description: String {
        self.token
    }

    /// Orders by epoch, then sequence.
    public static func < (lhs: TransferAttempt, rhs: TransferAttempt) -> Bool {
        (lhs.epoch, lhs.sequence) < (rhs.epoch, rhs.sequence)
    }
}
