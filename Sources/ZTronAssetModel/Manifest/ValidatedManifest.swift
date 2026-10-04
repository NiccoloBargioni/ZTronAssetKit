import Foundation

/// The wire shape a manifest arrived in (R-MAN-1).
public enum ManifestWireShape: Sendable, Hashable {
    /// The prior art's bare JSON array of assets.
    case bareArray
    /// `{ "schemaVersion": Int, "assets": [...] }`.
    case envelope(schemaVersion: Int)
}

/// A manifest whose structure passed R-MAN-2: entries in publisher order with unique identifiers, plus the
/// diagnostics of every quarantined entry. This is the only manifest type the store, planner and engine accept.
public struct ValidatedManifest: Sendable, Hashable {
    /// The accepted entries in manifest order (the planner's stable order, ARCHITECTURE §7.3).
    public let entries: [ManifestEntry]
    /// The entries that failed a per-entry rule, with diagnostics.
    public let quarantined: [QuarantinedEntry]
    /// The shape the payload had.
    public let shape: ManifestWireShape
    /// SHA-256 of the payload bytes as received (or of a canonical encoding for in-memory manifests). The applied
    /// manifest's digest is persisted in the index; equal digests mean "nothing to reconcile".
    public let digest: ContentHash
    private let positions: [AssetID: Int]

    /// Builds a manifest, rejecting duplicate identifiers (R-MAN-2, RECON D-13: never trap on duplicates).
    public init(
        entries: [ManifestEntry],
        quarantined: [QuarantinedEntry] = [],
        shape: ManifestWireShape = .bareArray,
        digest: ContentHash
    ) throws(ManifestError) {
        var positions: [AssetID: Int] = [:]
        positions.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if positions[entry.identifier] != nil {
                throw .duplicateIdentifier(entry.identifier)
            }
            positions[entry.identifier] = index
        }
        self.entries = entries
        self.quarantined = quarantined
        self.shape = shape
        self.digest = digest
        self.positions = positions
    }

    /// An empty manifest (fresh install, or after a rebuild with no valid index).
    public static func empty(digest: ContentHash = ContentHash(w0: 0, w1: 0, w2: 0, w3: 0)) -> ValidatedManifest {
        // An empty entry list cannot contain duplicates, so the throwing initialiser cannot fail here.
        ValidatedManifest(unchecked: [], digest: digest)
    }

    /// The number of accepted entries.
    public var count: Int {
        self.entries.count
    }

    /// The entry for `id`, in O(1).
    public func entry(for id: AssetID) -> ManifestEntry? {
        guard let index = self.positions[id] else {
            return nil
        }
        return self.entries[index]
    }

    /// The manifest position of `id`, in O(1).
    public func position(of id: AssetID) -> Int? {
        self.positions[id]
    }

    /// Whether `id` is an accepted entry.
    public func contains(_ id: AssetID) -> Bool {
        self.positions[id] != nil
    }

    /// Wraps a decoder result whose identifiers the decoder already indexed (and so proved unique), so a 100,000-entry
    /// manifest is hashed once, not twice (R-MAN-3, P-3).
    init(decoded entries: [ManifestEntry], positions: [AssetID: Int], quarantined: [QuarantinedEntry], shape: ManifestWireShape, digest: ContentHash) {
        self.entries = entries
        self.quarantined = quarantined
        self.shape = shape
        self.digest = digest
        self.positions = positions
    }

    private init(unchecked entries: [ManifestEntry], digest: ContentHash) {
        self.entries = entries
        self.quarantined = []
        self.shape = .bareArray
        self.digest = digest
        self.positions = [:]
    }
}

/// Decodes and validates untrusted manifest bytes (R-MAN-1, R-MAN-2, R-MAN-3). Owned by WP-A.
///
/// Contract: never traps and never hangs on any input; rejects structural violations with a typed error;
/// quarantines per-entry violations with a diagnostic; ignores unknown fields in both wire shapes; time ≤ 1 s and
/// allocation ≤ 4× payload for 32 MiB (R-MAN-3), ≤ `P-3` for the 3.3 MB reference catalog. Callers run it on the
/// blocking-I/O executor, never on the main thread or for long on the cooperative pool (C2, ADR-003).
public enum ManifestDecoder {
    /// Decodes either wire shape and validates every entry.
    ///
    /// The payload size is checked before a byte is read. A survey pass then validates every byte and counts what
    /// the result will hold, materialising nothing; a payload whose decoded form could need more than four times
    /// its size (`ManifestFootprint.limit`) is rejected as `payloadTooLarge` with the estimated bytes and the limit,
    /// before anything is built (R-MAN-3). Otherwise a build pass with exactly reserved buffers produces
    /// the manifest (`ManifestParser`, ADR draft A-1, A-8). The digest is the SHA-256 of `data` as received.
    public static func decode(_ data: Data, options: ManifestDecodingOptions = ManifestDecodingOptions()) throws(ManifestError)
        -> ValidatedManifest
    {
        guard Int64(data.count) <= options.limits.maxPayloadBytes else {
            throw .payloadTooLarge(bytes: Int64(data.count), limit: options.limits.maxPayloadBytes)
        }
        let parsed: Result<ManifestParser.Output, ManifestError> = data.withUnsafeBytes { bytes in
            do throws(ManifestError) {
                let counts = try ManifestParser.survey(bytes, options: options)
                let limit = ManifestFootprint.limit(payloadBytes: bytes.count)
                guard counts.estimatedBytes <= limit else {
                    throw .payloadTooLarge(bytes: Int64(counts.estimatedBytes), limit: Int64(limit))
                }
                var build = ManifestParser(bytes: bytes, options: options, reserving: counts)
                return .success(try build.parse())
            } catch {
                return .failure(error)
            }
        }
        let output = try parsed.get()
        return ValidatedManifest(
            decoded: output.entries,
            positions: output.positions,
            quarantined: output.quarantined,
            shape: output.shape,
            digest: ContentHash.sha256(of: data)
        )
    }

    /// The per-entry rules of R-MAN-2 for one entry: every violation, or an empty array when the entry is valid.
    ///
    /// Reported in field order (identifier, fileExtension, remotePath, localPathComponents, byteSize, tags); the
    /// decoder quarantines an entry with the first. A `ManifestEntry` value cannot hold a malformed checksum or
    /// policy, so those violations arise only while decoding.
    public static func violations(of entry: ManifestEntry, limits: ManifestLimits) -> [ManifestEntryViolation] {
        ManifestRules.violations(of: entry, limits: limits)
    }
}
