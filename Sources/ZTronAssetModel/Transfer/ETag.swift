/// An HTTP entity tag stored verbatim (weak tags included), as the conditional manifest fetch needs it (R-NET-5).
///
/// Untrusted input: 1…256 bytes of printable ASCII (0x20…0x7E), else `nil`, so a hostile or broken origin cannot
/// grow the index or smuggle control characters into a header. A value that fails validation is simply not stored,
/// and the next manifest fetch is unconditional. The Apple tier uses `"sha256:<hex>"` of the catalog as a
/// pseudo-tag (transport.md §11.2).
public struct ETag: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The tag exactly as received, quotes and `W/` prefix included.
    public let rawValue: String

    /// The largest accepted tag in bytes.
    public static let maxBytes = 256

    /// Validates `rawValue`; `nil` when empty, longer than 256 bytes or containing a non-printable byte.
    public init?(rawValue: String) {
        let utf8 = rawValue.utf8
        guard (1...ETag.maxBytes).contains(utf8.count) else {
            return nil
        }
        for byte in utf8 {
            guard (0x20...0x7E).contains(byte) else {
                return nil
            }
        }
        self.rawValue = rawValue
    }

    /// Decodes and validates a JSON string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let tag = ETag(rawValue: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid entity tag")
        }
        self = tag
    }

    /// Encodes as a JSON string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// The tag as received.
    public var description: String {
        self.rawValue
    }
}
