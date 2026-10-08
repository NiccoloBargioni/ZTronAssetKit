import Foundation
import ZTronAssetModel

/// Copies one pack file into `staging/` through the store's sink (adopt-and-release, ADR-027, R-APL-3).
///
/// Every staging call of the source goes through here, admitted by `AppleSourceState`, so `invalidate()` can stop
/// new calls and wait for running ones (transport-2 T2-04). The pack reader is lazy and the sink pulls it on the
/// store's bulk executor, so neither opening nor reading a pack file blocks the cooperative pool (C2); the bytes are
/// hashed on the way (`HashingChunkSource`). Nothing here returns or stores a pack location: the store publishes the
/// staged copy into `blobs/` through the hash path, and the asset is served from there.
@available(iOS 26.0, macOS 26.0, *)
struct PackCopier: Sendable {
    /// How a copy ended.
    enum Outcome: Sendable, Hashable {
        /// The staging file holds `bytes` bytes whose SHA-256 is `digest`.
        case copied(bytes: Int64, digest: ContentHash)
        /// The pack is not installed or does not hold the file; the staging file was removed.
        case sourceMissing
        /// The sink failed; the staging file was removed unless the name belonged to someone else.
        case failed(StagingError)
        /// The source was invalidated; staging was not touched.
        case closed
    }

    /// The pack seam.
    let backend: any PackBackend
    /// The store's staging sink.
    let staging: any StagingSink
    /// Staging admission.
    let state: AppleSourceState

    /// Streams `location` into `staging/<name>`, refusing more than `maxBytes`.
    func copy(_ location: PackLocation, as name: StagingFileName, maxBytes: Int64) async -> Outcome {
        guard await self.state.beginStaging() else {
            return .closed
        }
        let reader = HashingChunkSource(self.backend.reader(for: location.path, in: location.pack))
        let outcome: Outcome
        do {
            let bytes = try await self.staging.writeStaged(name, from: reader, maxBytes: maxBytes)
            outcome = .copied(bytes: bytes, digest: reader.digest)
        } catch {
            switch error {
            case .source(.notFound), .source(.notInstalled):
                outcome = .sourceMissing
            default:
                outcome = .failed(error)
            }
            if error != .nameInUse {
                await self.staging.discard(name)
            }
        }
        await self.state.endStaging()
        return outcome
    }

    /// Reads a staged file back and removes it (the catalog path); `nil` once the source was invalidated.
    func readAndDiscard(_ name: StagingFileName, maxBytes: Int64) async -> Result<Data, StagingError>? {
        guard await self.state.beginStaging() else {
            return nil
        }
        let result: Result<Data, StagingError>
        do {
            result = .success(try await self.staging.readStaged(name, maxBytes: maxBytes))
        } catch {
            result = .failure(error)
        }
        await self.staging.discard(name)
        await self.state.endStaging()
        return result
    }

    /// Removes a staging file, unless the source was invalidated (staging GC then collects it, ADR-028).
    func discard(_ name: StagingFileName) async {
        guard await self.state.beginStaging() else {
            return
        }
        await self.staging.discard(name)
        await self.state.endStaging()
    }
}
