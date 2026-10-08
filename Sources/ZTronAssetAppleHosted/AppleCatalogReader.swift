import Foundation
import ZTronAssetModel

/// Reads the catalog JSON from the installed essential pack (R-APL-4, transport.md §11.2).
///
/// The installed catalog is read first and no update check is awaited on the way (transport-2 T2-14), so an offline
/// launch falls back to the catalog on disk. Only when the catalog pack itself is not installed is it made available,
/// once, through the single-flight coordinator, whose wait ends when the engine's deadline cancels the fetch.
@available(iOS 26.0, macOS 26.0, *)
struct AppleCatalogReader: Sendable {
    /// The catalog's bytes and their SHA-256.
    struct Catalog: Sendable, Hashable {
        /// At most the request's cap.
        var bytes: Data
        /// The digest of `bytes`, computed while they were staged.
        var digest: ContentHash
    }

    /// Staging access.
    let copier: PackCopier
    /// Pack availability.
    let packs: PackAvailabilityCoordinator
    /// The `apple` log route.
    let log: LogRoute

    /// Reads `catalog` through `staging/<m-manifest.attempt.part>`.
    func read(_ catalog: PackLocation, request: ManifestRequest) async -> Result<Catalog, TransferError> {
        let name = StagingFileName(transfer: .manifest, attempt: request.attempt, kind: .partial)
        var outcome = await self.copier.copy(catalog, as: name, maxBytes: request.maxBytes)
        if case .sourceMissing = outcome {
            self.log.log(.apple, .info, "catalog pack \(catalog.pack) is not installed; making it available")
            switch await self.packs.ensure(catalog.pack, progress: nil) {
            case .available:
                outcome = await self.copier.copy(catalog, as: name, maxBytes: request.maxBytes)
            case .failed(let error):
                let reason = String(describing: error)
                self.log.log(.apple, .error, "catalog pack \(catalog.pack) unavailable: \(reason)")
                return .failure(PackErrorMapping.transferError(error))
            case .cancelled:
                return .failure(.cancelled(.byClient))
            }
        }
        switch outcome {
        case .copied(_, let digest):
            switch await self.copier.readAndDiscard(name, maxBytes: request.maxBytes) {
            case .success(let bytes):
                return .success(Catalog(bytes: bytes, digest: digest))
            case .failure(let error):
                return .failure(PackErrorMapping.transferError(error, expectedBytes: nil))
            case nil:
                return .failure(.cancelled(.byClient))
            }
        case .sourceMissing:
            self.log.log(.apple, .error, "catalog pack \(catalog.pack) holds no catalog at the configured path")
            return .failure(.permanentMissing(httpStatus: 404))
        case .failed(let error):
            return .failure(PackErrorMapping.transferError(error, expectedBytes: nil))
        case .stopped, .closed:
            return .failure(.cancelled(.byClient))
        }
    }
}
