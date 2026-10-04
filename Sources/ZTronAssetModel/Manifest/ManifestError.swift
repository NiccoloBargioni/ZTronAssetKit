/// Why a whole manifest was rejected (R-MAN-2 structural violations). Nothing of a rejected manifest is applied.
public enum ManifestError: Error, Sendable, Hashable {
    /// The payload has more bytes than `ManifestLimits.maxPayloadBytes`: `bytes` is the payload's size and `limit`
    /// the limit. Checked before a byte is read.
    case payloadTooLarge(bytes: Int64, limit: Int64)
    /// The payload is within its size limit, but its decoded form could need more memory than R-MAN-3 allows (four
    /// times the payload): `bytes` is the decoder's estimate of the heap the decoded manifest would take, an upper
    /// bound, and `limit` the most the estimate may reach for this payload (ADR draft A-8). Reported before anything
    /// is built; only a manifest dense with short heap strings or many minimal entries reaches it.
    case decodedSizeExceeded(bytes: Int64, limit: Int64)
    /// More entries than `ManifestLimits.maxEntries`.
    case tooManyEntries(count: Int, limit: Int)
    /// The bytes are not a manifest in either wire shape.
    case undecodable(ManifestUndecodableReason)
    /// An envelope declares a `schemaVersion` this build cannot interpret.
    case unsupportedSchemaVersion(Int)
    /// Two entries share an identifier (the prior art trapped on this, RECON D-13).
    case duplicateIdentifier(AssetID)
}

/// The class of an undecodable payload (fixture reason classes, `Tests/Fixtures/manifests/README.md` §5).
public enum ManifestUndecodableReason: Sendable, Hashable {
    /// Not JSON in any encoding.
    case notJSON
    /// Nesting deeper than `ManifestLimits.maxNestingDepth`.
    case nestingTooDeep
    /// JSON, but neither a bare array nor an envelope with an `assets` array.
    case unexpectedShape
}

/// Why one entry was quarantined (R-MAN-2 per-entry violations). The rest of the manifest is applied.
public enum ManifestEntryViolation: Sendable, Hashable {
    /// A field is missing or has the wrong JSON type.
    case malformedField(String)
    /// `identifier` is empty.
    case identifierEmpty
    /// `identifier` is longer than `ManifestLimits.maxIdentifierBytes` UTF-8 bytes.
    case identifierTooLong(bytes: Int)
    /// `identifier` contains a control character.
    case identifierControlCharacter
    /// `fileExtension` does not match `[A-Za-z0-9]{1,8}`.
    case fileExtensionInvalid
    /// `checksum` is present but not 64 hexadecimal characters.
    case checksumInvalid
    /// `byteSize` is negative or above `maxAssetBytes`.
    case byteSizeOutOfRange(Int64)
    /// `remotePath` breaks one of the path rules.
    case remotePathInvalid(RemotePathViolation)
    /// A `tags` element is empty or longer than `ManifestLimits.maxTagBytes`.
    case tagInvalid
}

/// The `remotePath` rules of R-MAN-2.
public enum RemotePathViolation: Sendable, Hashable {
    /// Empty path.
    case empty
    /// Longer than `ManifestLimits.maxRemotePathBytes`.
    case tooLong(bytes: Int)
    /// Starts with `/`.
    case absolute
    /// Contains a `..` segment.
    case parentSegment
    /// Carries a URL scheme.
    case scheme
    /// Carries an authority (`//host`).
    case authority
    /// Contains a control character.
    case controlCharacter
    /// Contains `?` or `#`: a query or fragment, which the transport rejects on every fetch (TR1-10), so the entry is
    /// quarantined with this diagnostic instead.
    case queryOrFragment
}

/// A quarantined entry and its diagnostic (never crashes, never applied).
public struct QuarantinedEntry: Sendable, Hashable {
    /// The entry's position in the payload.
    public var index: Int
    /// The identifier, when one could be read.
    public var identifier: AssetID?
    /// Why it was quarantined.
    public var violation: ManifestEntryViolation

    /// Creates a diagnostic.
    public init(index: Int, identifier: AssetID?, violation: ManifestEntryViolation) {
        self.index = index
        self.identifier = identifier
        self.violation = violation
    }
}
