import Foundation

/// A conditional manifest fetch (R-NET-5, transport.md §6).
public struct ManifestRequest: Sendable, Hashable {
    /// The stored entity tag; sent as `If-None-Match` when present.
    public var ifNoneMatch: ETag?
    /// The streaming cap (R-MAN-2: 32 MiB), enforced while bytes arrive, never after.
    public var maxBytes: Int64
    /// OS-enforced network permissions.
    public var access: NetworkAccess
    /// Apple tier: also schedule a best-effort `checkForUpdates()`, never awaited before the installed catalog is
    /// read (R-APL-4, transport-2 T2-14).
    public var allowsUpdateCheck: Bool
    /// The attempt naming the manifest's staging file (`m-manifest.<attempt>.part`, ADR-013).
    public var attempt: TransferAttempt

    /// Creates a request.
    public init(
        ifNoneMatch: ETag?,
        maxBytes: Int64,
        access: NetworkAccess = .unrestricted,
        allowsUpdateCheck: Bool = true,
        attempt: TransferAttempt
    ) {
        self.ifNoneMatch = ifNoneMatch
        self.maxBytes = maxBytes
        self.access = access
        self.allowsUpdateCheck = allowsUpdateCheck
        self.attempt = attempt
    }
}

/// Where manifest bytes came from.
public enum ManifestOrigin: Sendable, Hashable {
    /// The HTTP origin.
    case network
    /// The installed essential pack (Apple tier); `updateChecked` is false when the update check failed or was
    /// skipped (offline fallback, R-APL-4).
    case installedPack(updateChecked: Bool)
}

/// Undecoded manifest bytes plus their provenance. Decoding and validation are the Model's (R-MAN-2/3).
public struct ManifestPayload: Sendable, Hashable {
    /// At most `ManifestRequest.maxBytes` bytes.
    public var bytes: Data
    /// The HTTP entity tag, or the Apple tier's `"sha256:<hex>"` pseudo-tag.
    public var etag: ETag?
    /// Where the bytes came from.
    public var origin: ManifestOrigin
    /// Apple tier: pack ids the update check reported removed (feeds prune).
    public var removedSources: Set<String>

    /// Creates a payload.
    public init(bytes: Data, etag: ETag?, origin: ManifestOrigin, removedSources: Set<String> = []) {
        self.bytes = bytes
        self.etag = etag
        self.origin = origin
        self.removedSources = removedSources
    }
}

/// The outcome of a conditional manifest fetch.
public enum ManifestFetchResult: Sendable, Hashable {
    /// 304 (or an unchanged catalog digest). `removedSources` still reports Apple-tier removals, which an unchanged
    /// catalog can coexist with (transport-2 T2-20).
    case notModified(removedSources: Set<String>)
    /// New bytes.
    case fetched(ManifestPayload)
}
