import Foundation

/// The wire shape a manifest arrived in (R-MAN-1).
public enum ManifestWireShape: Sendable, Hashable {
    /// The prior art's bare JSON array of assets.
    case bareArray
    /// `{ "schemaVersion": Int, "assets": [...] }`.
    case envelope(schemaVersion: Int)
}

/// A manifest whose structure passed R-MAN-2: entries in publisher order with unique identifiers, plus the
/// diagnostics of the quarantined entries. This is the only manifest type the store, planner and engine accept.
public struct ValidatedManifest: Sendable, Hashable {
    /// The accepted entries in manifest order (the planner's stable order, ARCHITECTURE §7.3).
    public let entries: [ManifestEntry]
    /// Diagnostics of the entries that failed a per-entry rule, in payload order: for a decoded manifest the first
    /// `ManifestLimits.maxQuarantineDiagnostics` (256 by default), fewer only when keeping them would take the
    /// decoded manifest over R-MAN-3's allocation bound (a payload of a few hundred bytes of invalid elements).
    /// `quarantinedCount` counts them all.
    public let quarantined: [QuarantinedEntry]
    /// How many entries were quarantined, diagnosed or not (at least `quarantined.count`).
    public let quarantinedCount: Int
    /// The shape the payload had.
    public let shape: ManifestWireShape
    /// SHA-256 of the payload bytes as received (or of a canonical encoding for in-memory manifests). The applied
    /// manifest's digest is persisted in the index; equal digests mean "nothing to reconcile".
    public let digest: ContentHash
    /// The identifier index: empty up to `linearLookupLimit` entries, which are found by a linear scan instead (a
    /// manifest of one minimal entry, 82 bytes, would otherwise need 128 more bytes than R-MAN-3's bound allows).
    private let positions: [AssetID: Int]

    /// Up to this many entries, lookups scan `entries` instead of an index: at most eight comparisons.
    static let linearLookupLimit = 8

    /// Builds a manifest, rejecting duplicate identifiers (R-MAN-2, RECON D-13: never trap on duplicates).
    /// `quarantinedCount` defaults to the diagnostics' count and is never less than it.
    public init(
        entries: [ManifestEntry],
        quarantined: [QuarantinedEntry] = [],
        quarantinedCount: Int? = nil,
        shape: ManifestWireShape = .bareArray,
        digest: ContentHash
    ) throws(ManifestError) {
        var positions: [AssetID: Int] = [:]
        if entries.count > ValidatedManifest.linearLookupLimit {
            positions.reserveCapacity(entries.count)
            for (index, entry) in entries.enumerated() {
                if positions[entry.identifier] != nil {
                    throw .duplicateIdentifier(entry.identifier)
                }
                positions[entry.identifier] = index
            }
        } else {
            for (index, entry) in entries.enumerated() where entries[..<index].contains(where: { $0.identifier == entry.identifier }) {
                throw .duplicateIdentifier(entry.identifier)
            }
        }
        self.entries = entries
        self.quarantined = quarantined
        self.quarantinedCount = max(quarantinedCount ?? quarantined.count, quarantined.count)
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
        guard let index = self.position(of: id) else {
            return nil
        }
        return self.entries[index]
    }

    /// The manifest position of `id`, in O(1).
    public func position(of id: AssetID) -> Int? {
        if self.entries.count <= ValidatedManifest.linearLookupLimit {
            return self.entries.firstIndex { $0.identifier == id }
        }
        return self.positions[id]
    }

    /// Whether `id` is an accepted entry.
    public func contains(_ id: AssetID) -> Bool {
        self.position(of: id) != nil
    }

    /// Wraps a decoder result whose identifiers the decoder already indexed (and so proved unique), so a 100,000-entry
    /// manifest is hashed once, not twice (R-MAN-3, P-3). `positions` is empty up to `linearLookupLimit` entries.
    init(
        decoded entries: [ManifestEntry],
        positions: [AssetID: Int],
        quarantined: [QuarantinedEntry],
        quarantinedCount: Int,
        shape: ManifestWireShape,
        digest: ContentHash
    ) {
        self.entries = entries
        self.quarantined = quarantined
        self.quarantinedCount = quarantinedCount
        self.shape = shape
        self.digest = digest
        self.positions = positions
    }

    private init(unchecked entries: [ManifestEntry], digest: ContentHash) {
        self.entries = entries
        self.quarantined = []
        self.quarantinedCount = 0
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
    /// The most bytes the decoder reads, whatever `ManifestLimits.maxPayloadBytes` says: its survey addresses the
    /// payload with 32-bit offsets (`SurveyedIdentifiers`).
    static let maxReadableBytes = Int64(UInt32.max) - 1

    /// Decodes either wire shape and validates every entry.
    ///
    /// The payload size is checked before a byte is read (`payloadTooLarge`). A survey pass then validates every byte,
    /// finds repeated identifiers and counts what the result will hold, materialising nothing; a payload whose decoded
    /// form could need more heap than R-MAN-3 allows (`ManifestFootprint.limit`, an upper bound of what the allocator
    /// counts) is rejected as `decodedSizeExceeded` before anything is built. Otherwise a build pass with exactly
    /// reserved buffers produces the manifest, keeping the quarantine diagnostics the bound has room for
    /// (`ManifestParser`, ADR draft A-1, A-8). The digest is the SHA-256 of `data` as received.
    ///
    /// Which error a payload with several problems reports (ADR draft A-4.3, A-4.9): `payloadTooLarge` first; then
    /// anything that makes the document not JSON or nest too deep, wherever it is; for an envelope, a missing,
    /// repeated or unsupported version, then a v1 shape violation; then the first error inside the assets in payload
    /// order (an element past `maxEntries`, or under `.reject` the second occurrence of an identifier); and only then
    /// `decodedSizeExceeded`.
    public static func decode(_ data: Data, options: ManifestDecodingOptions = ManifestDecodingOptions()) throws(ManifestError)
        -> ValidatedManifest
    {
        let payloadLimit = min(options.limits.maxPayloadBytes, ManifestDecoder.maxReadableBytes)
        guard Int64(data.count) <= payloadLimit else {
            throw .payloadTooLarge(bytes: Int64(data.count), limit: payloadLimit)
        }
        let parsed: Result<ManifestParser.Output, ManifestError> = data.withUnsafeBytes { bytes in
            do throws(ManifestError) {
                let counts = try ManifestParser.survey(bytes, options: options)
                let limit = ManifestFootprint.limit(payloadBytes: bytes.count)
                guard counts.estimatedBytes <= limit else {
                    throw .decodedSizeExceeded(bytes: Int64(counts.estimatedBytes), limit: Int64(limit))
                }
                let diagnostics = ManifestFootprint.diagnosticCapacity(
                    quarantinedCount: counts.quarantinedCount, maxDiagnostics: options.limits.maxQuarantineDiagnostics,
                    room: limit - counts.estimatedBytes
                )
                let plan = ManifestBuildPlan(survey: counts, diagnosticCapacity: diagnostics.count, diagnosticStringBytes: diagnostics.stringBytes)
                var build = ManifestParser(bytes: bytes, options: options, plan: plan)
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
            quarantinedCount: output.quarantinedCount,
            shape: output.shape,
            digest: ContentHash.sha256(of: data)
        )
    }

    /// The per-entry rules of R-MAN-2 for one entry: every violation, or an empty array when the entry is valid.
    ///
    /// Reported in field order (identifier, fileExtension, remotePath, localPathComponents, byteSize, tags); the
    /// decoder quarantines an entry with the first, under any limits (a negative `maxTagsPerEntry` reads as zero). A `ManifestEntry` value cannot hold a malformed checksum or
    /// policy, so those violations arise only while decoding.
    public static func violations(of entry: ManifestEntry, limits: ManifestLimits) -> [ManifestEntryViolation] {
        ManifestRules.violations(of: entry, limits: limits)
    }
}
