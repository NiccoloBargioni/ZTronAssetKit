#if canImport(BackgroundAssets)
import BackgroundAssets
import Foundation
import Synchronization
import System
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
        LivePackFileReader(path: path, pack: pack)
    }

    /// `ensureLocalAvailability(of:)` plus `statusUpdates` progress.
    public func ensureAvailable(_ pack: PackID, progress: AsyncStream<PackProgress>.Continuation?) async throws(PackError) {
        let manager = AssetPackManager.shared
        let watcher = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: pack.rawValue) {
                if case .downloading(_, let live) = update {
                    progress?.yield(PackProgress(snapshotOf: live))
                }
            }
        }
        defer {
            watcher.cancel()
        }
        do {
            try await manager.ensureLocalAvailability(of: try await manager.assetPack(withID: pack.rawValue))
        } catch {
            throw Self.packError(error)
        }
    }

    /// `checkForUpdates()`.
    public func checkForUpdates() async throws(PackError) -> PackUpdateCheck {
        do {
            let result = try await AssetPackManager.shared.checkForUpdates()
            return PackUpdateCheck(
                updating: Set(result.updatingIDs.compactMap(PackID.init(rawValue:))),
                removed: Set(result.removedIDs.compactMap(PackID.init(rawValue:)))
            )
        } catch {
            throw Self.packError(error)
        }
    }

    /// `remove(assetPackWithID:)`.
    public func remove(_ pack: PackID) async throws(PackError) {
        do {
            try await AssetPackManager.shared.remove(assetPackWithID: pack.rawValue)
        } catch {
            throw Self.packError(error)
        }
    }

    /// The installed pack's size, when the SDK reports it: `AssetPack.downloadSize` of a downloaded pack (the 26.0
    /// surface has no installed size; UNVERIFIED approximation, DEVICE-TEST-PLAN).
    public func installedBytes(of pack: PackID) async -> Int64? {
        let manager = AssetPackManager.shared
        guard let status = try? await manager.status(ofAssetPackWithID: pack.rawValue), status.contains(.downloaded),
            let assetPack = try? await manager.assetPack(withID: pack.rawValue)
        else {
            return nil
        }
        return Int64(assetPack.downloadSize)
    }

    /// `ManagedBackgroundAssetsError` names the two documented failures; anything else keeps its domain and code.
    static func packError(_ error: any Error) -> PackError {
        switch error as? ManagedBackgroundAssetsError {
        case .assetPackNotFound:
            return .packNotFound
        case .fileNotFound:
            return .fileNotFound
        default:
            let bridged = error as NSError
            return .system(domain: bridged.domain, code: bridged.code)
        }
    }
}

/// Opens the pack file on the first read, inside the store's bulk executor, and reads it in bounded chunks.
@available(iOS 26.0, macOS 26.0, *)
final class LivePackFileReader: PackFileReader {
    private let path: String
    private let pack: PackID
    private let handle: Mutex<FileHandle?>

    init(path: String, pack: PackID) {
        self.path = path
        self.pack = pack
        self.handle = Mutex(nil)
    }

    func nextChunk(maxBytes: Int) throws(StagingError) -> Data? {
        try self.handle.withLock { (handle: inout FileHandle?) throws(StagingError) -> Data? in
            if handle == nil {
                do {
                    let descriptor = try AssetPackManager.shared.descriptor(
                        for: FilePath(self.path), searchingInAssetPackWithID: self.pack.rawValue)
                    handle = FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: true)
                } catch {
                    throw .source(PackErrorMapping.sourceFailure(LiveAssetPackBackend.packError(error)))
                }
            }
            do {
                let chunk = try handle?.read(upToCount: maxBytes)
                return chunk?.isEmpty == false ? chunk : nil
            } catch {
                throw .source(.readFailed)
            }
        }
    }
}
#endif
