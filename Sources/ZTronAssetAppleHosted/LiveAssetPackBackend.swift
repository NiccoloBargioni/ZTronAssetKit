#if canImport(BackgroundAssets)
import BackgroundAssets
import Foundation
import System
import ZTronAssetModel

/// The live pack backend over `AssetPackManager` (R-APL-1): one of the two coverage-excluded, device-only files
/// (SPEC §4.1, ≤ 250 lines; working ceiling 100 executable lines). It uses only the iOS 26.0 surface
/// (`assetPack(withID:)`, `ensureLocalAvailability`, `statusUpdates`, `descriptor(for:searchingInAssetPackWithID:)`,
/// `checkForUpdates()`, `remove(assetPackWithID:)`, `status(ofAssetPackWithID:)`), converts `Foundation.Progress` to
/// `PackProgress` at the boundary (D-12), reads through `FileHandle(fileDescriptor:closeOnDealloc:)` without pointers
/// (the tested `FileHandleChunkReader`), references `AssetPackManager.shared` only inside method bodies, and maps
/// errors to `PackError` (never integrity). Every decision lives in tested files. WP-E.
@available(iOS 26.0, macOS 26.0, *)
public struct LiveAssetPackBackend: PackBackend {
    /// Creates the backend; touches no pack API.
    public init() {}

    /// A lazy descriptor reader: `descriptor(for:searchingInAssetPackWithID:)` runs on its first read.
    public func reader(for path: String, in pack: PackID) -> any PackFileReader {
        FileHandleChunkReader {
            do {
                let manager = AssetPackManager.shared
                let descriptor = try manager.descriptor(for: FilePath(path), searchingInAssetPackWithID: pack.rawValue)
                return .success(FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: true))
            } catch {
                return .failure(Self.packError(error))
            }
        }
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
            return PackUpdateCheck(updatingIDs: result.updatingIDs, removedIDs: result.removedIDs)
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

#endif
