import Foundation
import Testing
import ZTronAssetModel

@testable import ZTronAssetStorage

@Suite("Core: file-system error mappings")
struct FileSystemMappingTests {
    @Test("R-STO-6: every errno and Cocoa error maps to the closed FileSystemError taxonomy")
    func errnoAndCocoaMapping() {
        let posix: [(Int32, FileSystemError)] = [
            (ENOSPC, .noSpace), (EDQUOT, .noSpace), (EIO, .io), (EACCES, .permissionDenied), (EPERM, .permissionDenied),
            (EROFS, .permissionDenied), (ENOENT, .notFound), (ENOTDIR, .notFound), (EEXIST, .alreadyExists),
            (EXDEV, .crossDevice), (EWOULDBLOCK, .wouldBlock), (ENOTEMPTY, .notEmpty), (ENOTSUP, .notSupported),
            (EINVAL, .other(errno: EINVAL)), (EBADF, .other(errno: EBADF)),
        ]
        for (code, expected) in posix {
            #expect(FileSystemErrorMapping.posix(code) == expected, "errno \(code)")
        }
        let cocoa: [(NSError, FileSystemError)] = [
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .noSpace),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), .notFound),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError), .notFound),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .noSpace),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), .permissionDenied),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), .permissionDenied),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError), .permissionDenied),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError), .alreadyExists),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError), .io),
            (
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))]
                ), .crossDevice
            ),
            (NSError(domain: "SomethingElse", code: 1), .io),
        ]
        for (error, expected) in cocoa {
            #expect(FileSystemErrorMapping.cocoa(error) == expected, "\(error.domain) \(error.code)")
        }
    }

    @Test("R-STO-6: an unsupported sync falls back to fsync, but EIO never does")
    func syncFallback() {
        #expect(FileSystemErrorMapping.syncFallsBackToFsync(errno: ENOTSUP))
        #expect(FileSystemErrorMapping.syncFallsBackToFsync(errno: EINVAL))
        #expect(FileSystemErrorMapping.syncFallsBackToFsync(errno: ENOTTY))
        #expect(!FileSystemErrorMapping.syncFallsBackToFsync(errno: EIO))
        #expect(!FileSystemErrorMapping.syncFallsBackToFsync(errno: ENOSPC))
    }

    @Test("R-STO-6: staging errors keep ENOSPC as insufficientSpace, EEXIST as nameInUse and the POSIX code of the rest")
    func stagingErrorMapping() {
        let all: [FileSystemError] = [
            .noSpace, .io, .permissionDenied, .notFound, .alreadyExists, .crossDevice, .wouldBlock, .notEmpty, .notSupported, .other(errno: 77),
        ]
        for error in all {
            #expect(FileSystemErrorMapping.posix(FileSystemErrorMapping.posixCode(of: error)) == error, "\(error) round-trips")
        }
        #expect(FileSystemErrorMapping.stagingError(.noSpace) == .insufficientSpace)
        #expect(FileSystemErrorMapping.stagingError(.alreadyExists) == .nameInUse)
        #expect(FileSystemErrorMapping.stagingError(.io) == .io(posixCode: EIO))
        #expect(FileSystemErrorMapping.stagingError(.crossDevice) == .io(posixCode: EXDEV))
        #expect(FileSystemErrorMapping.storeError(.io) == .fileSystem(.io))
    }

    @Test("R-STO-9: a lock token packs the descriptor and its nonce and unpacks them exactly")
    func lockHandlePacking() {
        for (descriptor, nonce) in [(Int32(3), UInt32(1)), (Int32(1_023), UInt32(Int32.max)), (Int32(0), UInt32(77))] {
            let parts = LiveFileSystem.lockParts(of: LiveFileSystem.lockHandle(descriptor: descriptor, nonce: nonce))
            #expect(parts.descriptor == descriptor)
            #expect(parts.nonce == Int64(nonce))
        }
    }

    @Test("R-STO-6: listing kinds report a link as a link whatever it points to")
    func itemKinds() {
        #expect(LiveFileSystem.kind(symbolicLink: true, directory: true, regularFile: false) == .symbolicLink)
        #expect(LiveFileSystem.kind(symbolicLink: false, directory: true, regularFile: false) == .directory)
        #expect(LiveFileSystem.kind(symbolicLink: false, directory: false, regularFile: true) == .file)
        #expect(LiveFileSystem.kind(symbolicLink: false, directory: false, regularFile: false) == .other)
        let info = LiveFileSystem.info(name: "x", attributes: [.type: FileAttributeType.typeDirectory, .size: NSNumber(value: 96)])
        #expect(info.kind == .directory && info.byteSize == 0 && info.identity == nil)
    }
}
