import Foundation
import ZTronAssetModel

/// Pure translations between platform error codes and the closed `FileSystemError` taxonomy (R-STO-6,
/// store.md §3.3).
///
/// They live outside `LiveFileSystem` so that every branch is table-tested on macOS: EIO, ENOSPC, EXDEV or a
/// volume without `F_BARRIERFSYNC` cannot be produced on demand inside a test directory.
package enum FileSystemErrorMapping {
    /// The taxonomy entry of a POSIX `errno`.
    package static func posix(_ code: Int32) -> FileSystemError {
        switch code {
        case ENOSPC, EDQUOT:
            return .noSpace
        case EIO:
            return .io
        case EACCES, EPERM, EROFS:
            return .permissionDenied
        case ENOENT, ENOTDIR:
            return .notFound
        case EEXIST:
            return .alreadyExists
        case EXDEV:
            return .crossDevice
        case EWOULDBLOCK:
            return .wouldBlock
        case ENOTEMPTY:
            return .notEmpty
        case ENOTSUP:
            return .notSupported
        default:
            return .other(errno: code)
        }
    }

    /// The taxonomy entry of an error thrown by `FileManager`, `FileHandle` or `URL` resource APIs: a POSIX error
    /// (directly or as the underlying error) wins; otherwise the Cocoa file-error code decides; anything else is
    /// `.io`, because the caller can only retry or give up.
    package static func cocoa(_ error: any Error) -> FileSystemError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return FileSystemErrorMapping.posix(Int32(truncatingIfNeeded: nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return FileSystemErrorMapping.posix(Int32(truncatingIfNeeded: underlying.code))
        }
        guard nsError.domain == NSCocoaErrorDomain else {
            return .io
        }
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .notFound
        case NSFileWriteOutOfSpaceError:
            return .noSpace
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
            return .permissionDenied
        case NSFileWriteFileExistsError:
            return .alreadyExists
        default:
            return .io
        }
    }

    /// What a failed `fcntl(F_FULLFSYNC | F_BARRIERFSYNC)` means: volumes that cannot perform the command answer
    /// ENOTSUP, EINVAL or ENOTTY and fall back to `fsync`; every other errno (EIO above all) is a real failure that a
    /// fallback would mask (store-1 S1-15).
    package static func syncFallsBackToFsync(errno code: Int32) -> Bool {
        code == ENOTSUP || code == EINVAL || code == ENOTTY
    }

    /// The POSIX code a taxonomy entry stands for (staging errors carry it, `StagingError.io(posixCode:)`).
    package static func posixCode(of error: FileSystemError) -> Int32 {
        switch error {
        case .noSpace:
            return ENOSPC
        case .io:
            return EIO
        case .permissionDenied:
            return EACCES
        case .notFound:
            return ENOENT
        case .alreadyExists:
            return EEXIST
        case .crossDevice:
            return EXDEV
        case .wouldBlock:
            return EWOULDBLOCK
        case .notEmpty:
            return ENOTEMPTY
        case .notSupported:
            return ENOTSUP
        case .other(let code):
            return code
        }
    }

    /// The staging sink's error for a file-system failure: ENOSPC is `insufficientSpace` (the transport maps it to
    /// `TransferError.insufficientSpace`), an occupied name on an exclusive rename is `nameInUse` (a uniqueness bug,
    /// never data loss, ADR-013), everything else keeps its POSIX code.
    package static func stagingError(_ error: FileSystemError) -> StagingError {
        switch error {
        case .noSpace:
            return .insufficientSpace
        case .alreadyExists:
            return .nameInUse
        default:
            return .io(posixCode: FileSystemErrorMapping.posixCode(of: error))
        }
    }

    /// The store's error for a file-system failure (R-CAR-7 maps it once more, to `AssetError`).
    package static func storeError(_ error: FileSystemError) -> StoreError {
        .fileSystem(error)
    }
}
