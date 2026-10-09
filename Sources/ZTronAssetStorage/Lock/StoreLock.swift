import Foundation
import ZTronAssetModel

/// The single-writer lock and the root-identity check (R-STO-9, store-1 S1-08).
///
/// The lock file's `(st_dev, st_ino)` is recorded at acquisition; before every commit the unit compares it with the
/// file now at `store.lock`, so a root that was deleted, moved or replaced while the store ran is detected before a
/// generation is written into the wrong tree.
enum StoreLock {
    /// Takes the advisory lock: another holder (another client, process or extension) is `.locked`, at once and
    /// without queueing (store.md §4.7).
    static func acquire(fileSystem: any FileSystem, layout: StoreLayout) -> Result<FileLockToken, StoreError> {
        do throws(FileSystemError) {
            return .success(try fileSystem.acquireExclusiveLock(at: layout.lockURL))
        } catch .wouldBlock {
            return .failure(.locked)
        } catch {
            return .failure(.fileSystem(error))
        }
    }

    /// `.storageUnavailable(.rootVanished)` unless the lock file still has the identity the token recorded.
    static func verifyRoot(fileSystem: any FileSystem, layout: StoreLayout, token: FileLockToken) -> Result<Void, StoreError> {
        do throws(FileSystemError) {
            guard let info = try fileSystem.itemInfo(at: layout.lockURL), info.identity == token.identity else {
                return .failure(.storageUnavailable(.rootVanished))
            }
            return .success(())
        } catch {
            return .failure(.fileSystem(error))
        }
    }
}
