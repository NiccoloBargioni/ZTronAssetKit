import ZTronAssetModel

/// How a staged file failed verification (R-INT-2). The staged bytes are deleted and nothing is published.
package enum StoreIntegrityFailure: Sendable, Hashable {
    /// The staged size differs from the manifest's `byteSize`; detected before hashing.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The digest of the written bytes differs from the manifest's checksum.
    case checksumMismatch(expected: ContentHash, actual: ContentHash)
    /// More bytes than `StoreConfiguration.limits.maxAssetBytes`; detected before hashing.
    case oversize(limit: Int64, actual: Int64)
}

/// Why an entry is `failed` until its manifest entry's content identity changes (R-INT-3, R-CLN-8, R-NET-6).
/// Persisted in the index; `apply` clears it when the identity changes (ADR-032).
package enum FailureReason: Sendable, Hashable {
    /// Repeated integrity failures (`recordIntegrityFailure` after `maxIntegrityAttempts`).
    case integrity
    /// Repeatedly reported unreadable.
    case unreadable
    /// The origin reported it missing (404/410), recorded by `recordFailure(_:identity:reason:)` so no run or
    /// relaunch requests it again before the entry changes (R-NET-6, ARCHITECTURE §7.6).
    case notFound
}

/// The store's closed error type (ADR-004); mapped once to `AssetError` by `assetError` (R-CAR-7).
package enum StoreError: Error, Sendable, Hashable {
    /// Another opener holds the root's advisory lock (R-STO-9).
    case locked
    /// The store was closed; nothing is mutated afterwards (R-SYN-15, store-1 S1-09).
    case closed
    /// A synchronous API was called before `open()` finished (store-2 S2-07).
    case notOpen
    /// The caller's task was cancelled between units.
    case cancelled
    /// A file-system failure the store could not absorb.
    case fileSystem(FileSystemError)
    /// Not enough space even after permitted eviction (R-SYN-11).
    case insufficientSpace(required: Int64, available: Int64)
    /// Verification failed (R-INT-2).
    case integrity(StoreIntegrityFailure)
    /// A checksum-less entry while `allowUnverifiedAssets` is false (R-INT-5).
    case unverifiedRejected(AssetID)
    /// The id is not in the applied manifest.
    case unknownAsset(AssetID)
    /// The asset has no blob (lease, location).
    case notPresent(AssetID)
    /// The manifest entry changed during the publication; nothing was published (store-2 S2-15).
    case superseded(AssetID)
    /// The entry is failed until it changes (R-INT-3).
    case assetFailed(AssetID, FailureReason)
    /// A purge happened since the run began, so the stamp is not written (R-CLN-6).
    case purgeRaced
    /// The store cannot serve (see the reason).
    case storageUnavailable(StorageUnavailableReason)

    /// The UI-mappable error (R-CAR-7, ARCHITECTURE §7.6).
    package var assetError: AssetError {
        switch self {
        case .locked:
            return .storageUnavailable(.locked)
        case .closed:
            return .shutDown
        case .notOpen:
            return .storageUnavailable(.ioFailure)
        case .cancelled:
            return .cancelled
        case .fileSystem(let error):
            switch error {
            case .noSpace:
                return .insufficientSpace(required: 0, available: 0)
            case .permissionDenied:
                return .storageUnavailable(.protectedDataUnavailable)
            case .wouldBlock:
                return .storageUnavailable(.locked)
            default:
                return .storageUnavailable(.ioFailure)
            }
        case .insufficientSpace(let required, let available):
            return .insufficientSpace(required: required, available: available)
        case .integrity, .unverifiedRejected:
            return .integrityFailure
        case .unknownAsset, .notPresent:
            return .notFound
        case .superseded, .purgeRaced:
            return .serverUnavailable(retryAfter: nil)
        case .assetFailed(_, let reason):
            return reason == .notFound ? .notFound : .integrityFailure
        case .storageUnavailable(let reason):
            return .storageUnavailable(reason)
        }
    }
}
