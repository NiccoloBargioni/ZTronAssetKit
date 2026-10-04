/// The untrusted-input limits of R-MAN-2 and R-MAN-3. Every number is a parameter so fuzz and boundary tests
/// can probe it; the defaults are the SPEC's.
public struct ManifestLimits: Sendable, Hashable {
    /// Maximum number of entries (R-MAN-2: 100,000). Also bounds the index and the event subjects (H-9).
    public var maxEntries: Int
    /// Maximum payload size in bytes (R-MAN-2: 32 MiB). Enforced while streaming by the transport too.
    public var maxPayloadBytes: Int64
    /// Maximum identifier length in UTF-8 bytes (R-MAN-2: 256).
    public var maxIdentifierBytes: Int
    /// Maximum `remotePath` length in UTF-8 bytes (R-MAN-2: 1,024).
    public var maxRemotePathBytes: Int
    /// Upper bound of `byteSize` (R-MAN-2 `maxAssetBytes`); also the transfer cap (R-NET-7).
    public var maxAssetBytes: Int64
    /// Maximum JSON nesting depth before the payload is rejected as undecodable (R-MAN-3 fuzz).
    public var maxNestingDepth: Int
    /// Maximum length of one tag in UTF-8 bytes.
    public var maxTagBytes: Int
    /// Maximum number of tags per entry.
    public var maxTagsPerEntry: Int

    /// The SPEC defaults: 100,000 entries, 32 MiB, 256-byte identifiers, 1,024-byte paths, 4 GiB assets,
    /// nesting 64, tags ≤ 64 × 128 bytes.
    public init(
        maxEntries: Int = 100_000,
        maxPayloadBytes: Int64 = 32 * 1_024 * 1_024,
        maxIdentifierBytes: Int = 256,
        maxRemotePathBytes: Int = 1_024,
        maxAssetBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
        maxNestingDepth: Int = 64,
        maxTagBytes: Int = 128,
        maxTagsPerEntry: Int = 64
    ) {
        self.maxEntries = maxEntries
        self.maxPayloadBytes = maxPayloadBytes
        self.maxIdentifierBytes = maxIdentifierBytes
        self.maxRemotePathBytes = maxRemotePathBytes
        self.maxAssetBytes = maxAssetBytes
        self.maxNestingDepth = maxNestingDepth
        self.maxTagBytes = maxTagBytes
        self.maxTagsPerEntry = maxTagsPerEntry
    }
}

/// How `ManifestDecoder` treats an input.
public struct ManifestDecodingOptions: Sendable, Hashable {
    /// What to do with a repeated identifier.
    public enum DuplicatePolicy: Sendable, Hashable {
        /// Reject the whole manifest with `ManifestError.duplicateIdentifier` (remote manifests, R-MAN-2).
        case reject
        /// Keep the first occurrence and quarantine the rest (the legacy `manifest.json` during migration,
        /// store design §7, so an old install with RECON D-13 data still migrates).
        case keepFirst
    }

    /// The limits to enforce.
    public var limits: ManifestLimits
    /// Duplicate handling.
    public var duplicates: DuplicatePolicy
    /// The highest envelope `schemaVersion` this build interprets.
    public var maxSchemaVersion: Int

    /// Remote-manifest defaults: SPEC limits, duplicates rejected, schema version 1.
    public init(limits: ManifestLimits = ManifestLimits(), duplicates: DuplicatePolicy = .reject, maxSchemaVersion: Int = 1) {
        self.limits = limits
        self.duplicates = duplicates
        self.maxSchemaVersion = maxSchemaVersion
    }
}
