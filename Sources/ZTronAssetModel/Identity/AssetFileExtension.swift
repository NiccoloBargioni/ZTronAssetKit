/// A validated, lowercased file extension: `[a-z0-9]{1,8}` after lowercasing (R-MAN-2, R-SEC-2).
///
/// The manifest's `fileExtension` is checked against `[A-Za-z0-9]{1,8}` by the decoder; this type is what the
/// store puts in blob names, so it re-validates before any URL is built and normalises the case (blob names are
/// case-sensitive on some volumes, lookups are case-insensitive).
public struct AssetFileExtension: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The lowercased extension, without a dot.
    public let rawValue: String

    /// Validates and lowercases `raw`; `nil` unless it is 1–8 ASCII letters or digits.
    public init?(_ raw: String) {
        let utf8 = Array(raw.utf8)
        guard (1...8).contains(utf8.count) else {
            return nil
        }
        var lowered: [UInt8] = []
        lowered.reserveCapacity(utf8.count)
        for byte in utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                lowered.append(byte)
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                lowered.append(byte + 32)
            default:
                return nil
            }
        }
        self.rawValue = String(decoding: lowered, as: UTF8.self)
    }

    /// The lowercased extension.
    public var description: String {
        self.rawValue
    }

    /// Alphabetical order (deterministic iteration).
    public static func < (lhs: AssetFileExtension, rhs: AssetFileExtension) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
