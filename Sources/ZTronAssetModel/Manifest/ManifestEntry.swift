import Foundation

/// The optional `policy` extension field (R-MAN-6). Absent means `standard`, which reproduces the prior art.
public enum AssetPolicy: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Never evicted; fetched first by bulk sync (planner rank 0).
    case essential
    /// Fetched by bulk sync; evictable least-recently-used (the default).
    case standard
    /// Fetched only on demand or by an `.identifiers` scope; the first eviction candidates.
    case onDemand

    /// Planner rank: essential before standard before on-demand (fetch order, ARCHITECTURE §7.3).
    public var rank: Int {
        switch self {
        case .essential:
            return 0
        case .standard:
            return 1
        case .onDemand:
            return 2
        }
    }

    /// Orders by rank.
    public static func < (lhs: AssetPolicy, rhs: AssetPolicy) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// What makes two versions of an entry "the same content" (R-MAN-5).
public enum ContentIdentity: Sendable, Hashable {
    /// The manifest's SHA-256: the strong identity, verified on every download (R-INT-2).
    case checksum(ContentHash)
    /// No checksum (legacy, R-MAN-5): existence-only trust; content changes **only** when `remotePath` changes
    /// (ADR-034). A `byteSize`-only change is metadata, exactly like `TransferID.legacy`, which ignores the size
    /// too, so the diff and the single-flight key agree. Admitted only when `allowUnverifiedAssets` is true
    /// (R-INT-5).
    case unverified(remotePath: String)
}

/// One validated asset of a manifest: the seven legacy fields plus the R-MAN-6 extension fields.
///
/// Instances reaching the store, planner or engine have passed `ManifestDecoder` validation (R-MAN-2); the
/// memberwise initialiser does not validate, so tests can build entries directly. `localPathComponents` and
/// `localFileName` are kept only for prior-art compatibility (legacy migration and the shims); the store never
/// turns them into paths (R-SEC-2, ARCHITECTURE §3).
public struct ManifestEntry: Sendable, Hashable, Codable {
    /// The asset's identifier.
    public var identifier: AssetID
    /// The file extension as published (`[A-Za-z0-9]{1,8}`); lookups compare it case-insensitively.
    public var fileExtension: String
    /// Relative path on the origin (AWS: `media/<sha256[:16]>/<name>.<ext>`; Apple: `<packID>/<path>`).
    public var remotePath: String
    /// The prior art's directory components (metadata only; required on the legacy wire format).
    public var localPathComponents: [String]
    /// The prior art's file name override (metadata only).
    public var localFileName: String?
    /// The decoded size in bytes, when published (compared with the staged size, R-NET-7).
    public var byteSize: Int64?
    /// The SHA-256 of the bytes, when published (R-MAN-5).
    public var checksum: ContentHash?
    /// Free-form tags for scoping (R-MAN-6, R-CAR-5); absent means `[]`.
    public var tags: [String]
    /// Retention and fetch policy (R-MAN-6); absent means `.standard`.
    public var policy: AssetPolicy

    /// Creates an entry without validation.
    public init(
        identifier: AssetID,
        fileExtension: String,
        remotePath: String,
        localPathComponents: [String] = [],
        localFileName: String? = nil,
        byteSize: Int64? = nil,
        checksum: ContentHash? = nil,
        tags: [String] = [],
        policy: AssetPolicy = .standard
    ) {
        self.identifier = identifier
        self.fileExtension = fileExtension
        self.remotePath = remotePath
        self.localPathComponents = localPathComponents
        self.localFileName = localFileName
        self.byteSize = byteSize
        self.checksum = checksum
        self.tags = tags
        self.policy = policy
    }

    /// The prior art's file name: `localFileName`, else the last dot-segment of the identifier
    /// (`CDNAsset.swift:66-72`, RECON §5). Used only by legacy migration and the shims.
    public var resolvedFileName: String {
        if let name = self.localFileName {
            return name
        }
        if let last = self.identifier.rawValue.split(separator: ".", omittingEmptySubsequences: false).last {
            return String(last)
        }
        return self.identifier.rawValue
    }

    /// The content identity used by the diff and the planner (R-MAN-4, R-MAN-5).
    public var contentIdentity: ContentIdentity {
        if let checksum = self.checksum {
            return .checksum(checksum)
        }
        return .unverified(remotePath: self.remotePath)
    }

    /// The transfer that fetches this entry's content (single-flight key, ADR-020).
    public var transferID: TransferID {
        if let checksum = self.checksum {
            return .content(checksum)
        }
        return .legacy(identifier: self.identifier, remotePath: self.remotePath)
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, fileExtension, remotePath, localPathComponents, localFileName, byteSize, checksum
        case tags, policy
    }

    /// Strict decoding of one well-typed entry (round trips and tests). The *lenient* path that quarantines a
    /// malformed entry instead of failing the whole manifest is `ManifestDecoder` (R-MAN-2).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.identifier = try container.decode(AssetID.self, forKey: .identifier)
        self.fileExtension = try container.decode(String.self, forKey: .fileExtension)
        self.remotePath = try container.decode(String.self, forKey: .remotePath)
        self.localPathComponents = try container.decode([String].self, forKey: .localPathComponents)
        self.localFileName = try container.decodeIfPresent(String.self, forKey: .localFileName)
        self.byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        self.checksum = try container.decodeIfPresent(ContentHash.self, forKey: .checksum)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.policy = try container.decodeIfPresent(AssetPolicy.self, forKey: .policy) ?? .standard
    }

    /// Encodes the wire shape: absent optionals are omitted, empty tags and the default policy are omitted, so a
    /// legacy entry re-encodes with exactly the seven legacy keys (R-MAN-1).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.identifier, forKey: .identifier)
        try container.encode(self.fileExtension, forKey: .fileExtension)
        try container.encode(self.remotePath, forKey: .remotePath)
        try container.encode(self.localPathComponents, forKey: .localPathComponents)
        try container.encodeIfPresent(self.localFileName, forKey: .localFileName)
        try container.encodeIfPresent(self.byteSize, forKey: .byteSize)
        try container.encodeIfPresent(self.checksum, forKey: .checksum)
        if !self.tags.isEmpty {
            try container.encode(self.tags, forKey: .tags)
        }
        if self.policy != .standard {
            try container.encode(self.policy, forKey: .policy)
        }
    }
}
