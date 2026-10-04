import Foundation

/// How sure the module is that a 403 means "the app key was rejected" (R-NET-6, SPEC §2.3).
public enum AuthRejection: Sendable, Hashable, Codable {
    /// The auth breaker opened on key-rejected evidence (empty-body 403s on several assets or on the manifest).
    case confirmed
    /// One object returned 403: a rejected key *or* a missing object behind OAC. Never silently one of them.
    case ambiguous
}

/// Why the store cannot serve (R-CAR-7 `storageUnavailable`, with the cause the UI may want to show).
public enum StorageUnavailableReason: Sendable, Hashable, Codable {
    /// Another client, process or extension holds the root's advisory lock (R-STO-9).
    case locked
    /// File protection makes the root unreadable before first unlock (R-STO-8).
    case protectedDataUnavailable
    /// The root vanished or was replaced while running (store-1 S1-08).
    case rootVanished
    /// Index commits keep failing (for example a full disk); lookups still work from the last snapshot.
    case degradedReadOnly
    /// A file-system error the store cannot recover from by itself.
    case ioFailure
}

/// The closed, UI-mappable error of every public async API (R-CAR-7, ADR-004, R-ENV-6).
///
/// Internal layers keep richer closed types (`ManifestError`, `TransferError`, `StoreError`) and map once at the
/// boundary. Underlying causes are kept for `diagnosticReport()`, never in this value, so it cannot carry a URL,
/// a header or a key (R-SEC-1).
public enum AssetError: Error, Sendable, Hashable, Codable {
    /// No usable network path, or the OS refused this network for the request.
    case offline
    /// The origin refused the request (see `AuthRejection`).
    case authRejected(AuthRejection)
    /// The asset is not in the catalog, or the origin reported it missing (404/410).
    case notFound
    /// Not enough free space even after permitted eviction (R-SYN-11).
    case insufficientSpace(required: Int64, available: Int64)
    /// The bytes did not match the manifest's size or checksum (after backoff, R-INT-3).
    case integrityFailure
    /// 5xx, throttling, an open breaker, an unusable manifest or another transient server condition.
    case serverUnavailable(retryAfter: TimeInterval?)
    /// The caller's task was cancelled (only that caller's request is affected, H-3).
    case cancelled
    /// The store cannot be used (see the reason).
    case storageUnavailable(StorageUnavailableReason)
    /// The client was shut down; every API fails with this afterwards (R-SYN-15).
    case shutDown
}
