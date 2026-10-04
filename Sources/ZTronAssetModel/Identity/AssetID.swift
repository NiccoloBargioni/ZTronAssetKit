import Foundation

/// Identifies one asset of the catalog: the manifest's `identifier`, carried verbatim.
///
/// Identifiers are untrusted manifest text (R-MAN-2). This type does not validate: validation lives in the
/// manifest decoder so that a bad entry is quarantined with a diagnostic instead of trapping. An identifier is
/// never used as a path component (R-SEC-2, ARCHITECTURE §3).
///
/// Equality, hashing and ordering all work on the UTF-8 bytes, not on Unicode canonical equivalence. Two
/// identifiers that only differ in normalisation are therefore *different* assets, exactly as they are different
/// keys on the CDN, and sorted output is byte-identical on every platform and in every process (the fixture
/// expectations are sorted the same way).
public struct AssetID: RawRepresentable, Hashable, Comparable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    /// The identifier exactly as published in the manifest.
    public let rawValue: String

    /// Wraps a raw identifier without validating it.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Wraps a raw identifier without validating it.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an identifier from a string literal (tests and static configuration).
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// Decodes the identifier from a single JSON string, as the manifest wire format carries it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    /// Encodes the identifier as a single JSON string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// The raw identifier, so log lines and test output read naturally. Logs hash it (R-OBS-1).
    public var description: String {
        self.rawValue
    }

    /// Byte-wise equality, consistent with `<` and `hash(into:)`.
    public static func == (lhs: AssetID, rhs: AssetID) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    /// Hashes the UTF-8 bytes, so equal identifiers hash equally under byte-wise equality.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.rawValue.utf8.count)
        for byte in self.rawValue.utf8 {
            hasher.combine(byte)
        }
    }

    /// Orders by UTF-8 bytes, the order every report and fixture uses.
    public static func < (lhs: AssetID, rhs: AssetID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }
}
