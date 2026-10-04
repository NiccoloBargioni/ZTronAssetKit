#if canImport(BackgroundAssets)
import BackgroundAssets
import ZTronAssetModel

/// The live pack backend over `AssetPackManager` (R-APL-1): one of the two coverage-excluded, device-only files
/// (SPEC §4.1, ≤ 250 lines). It uses only the iOS 26.0 surface (`assetPack(withID:)`, `ensureLocalAvailability`,
/// `statusUpdates`, `descriptor(for:searchingInAssetPackWithID:)`, `checkForUpdates()`,
/// `remove(assetPackWithID:)`), converts `Foundation.Progress` to `PackProgress` at the boundary (D-12), reads
/// through `FileHandle(fileDescriptor:closeOnDealloc:)` without pointers, references `AssetPackManager.shared` only
/// inside method bodies, and maps errors to `PackError` (never integrity). WP-E.
@available(iOS 26.0, macOS 26.0, *)
public struct LiveAssetPackBackend: PackBackend {
    /// Creates the backend; touches no pack API.
    public init() {}

    /// A lazy descriptor reader.
    public func reader(for path: String, in pack: PackID) -> any PackFileReader {
        fatalError("WP-E: LiveAssetPackBackend.reader not implemented")
    }

    /// `ensureLocalAvailability(of:)` plus `statusUpdates` progress.
    public func ensureAvailable(_ pack: PackID, progress: AsyncStream<PackProgress>.Continuation?) async throws(PackError) {
        fatalError("WP-E: LiveAssetPackBackend.ensureAvailable not implemented")
    }

    /// `checkForUpdates()`.
    public func checkForUpdates() async throws(PackError) -> PackUpdateCheck {
        fatalError("WP-E: LiveAssetPackBackend.checkForUpdates not implemented")
    }

    /// `remove(assetPackWithID:)`.
    public func remove(_ pack: PackID) async throws(PackError) {
        fatalError("WP-E: LiveAssetPackBackend.remove not implemented")
    }

    /// The installed pack's size, when the SDK reports it.
    public func installedBytes(of pack: PackID) async -> Int64? {
        fatalError("WP-E: LiveAssetPackBackend.installedBytes not implemented")
    }
}
#endif
