import BackgroundAssets
import Foundation
import System
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel

/// R-APL-2 / R-NET-6: Apple-tier failures in the closed taxonomy (APPLE-API-VERIFICATION §1.8).
@Suite("Apple tier: error mapping")
struct PackErrorMappingTests {
    @Test("R-APL-2: undocumented pack errors map to transient and never to integrity")
    func undocumentedErrorsAreTransient() {
        let seed: UInt64 = 0xA9_1E
        var random = SplitMix64(seed: seed)
        let domains = [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, "BAManagedErrorDomain", "com.apple.unknown"]
        for round in 0..<2_000 {
            let domain = domains[Int.random(in: 0..<domains.count, using: &random)]
            let code = Int.random(in: -4_000...4_000, using: &random)
            for error in [
                PackErrorMapping.transferError(PackError.system(domain: domain, code: code)),
                PackErrorMapping.transferError(SourceFailure.system(domain: domain, code: code)),
                PackErrorMapping.transferError(StagingError.source(.system(domain: domain, code: code)), expectedBytes: nil),
            ] {
                let failure = error.failureClass
                #expect(failure == .transient || failure == .offline, "seed \(seed) round \(round): \(domain) \(code) → \(error)")
            }
        }
    }

    @Test("R-APL-2: URL connectivity codes keep their meaning and other domains are unknown")
    func urlCodesKeepTheirMeaning() {
        let table: [(Int, TransferError)] = [
            (NSURLErrorNotConnectedToInternet, .offline(.noConnection)),
            (NSURLErrorInternationalRoamingOff, .offline(.roamingDisabled)),
            (NSURLErrorCallIsActive, .offline(.callActive)),
            (NSURLErrorDataNotAllowed, .offline(.cellularDenied)),
            (NSURLErrorTimedOut, .transient(.timedOut, retryAfter: nil)),
            (NSURLErrorNetworkConnectionLost, .transient(.connectionLost(resumable: false), retryAfter: nil)),
            (NSURLErrorCannotConnectToHost, .transient(.cannotConnect, retryAfter: nil)),
            (NSURLErrorCannotFindHost, .transient(.dnsFailure, retryAfter: nil)),
            (NSURLErrorDNSLookupFailed, .transient(.dnsFailure, retryAfter: nil)),
            (NSURLErrorBadServerResponse, .transient(.badServerResponse, retryAfter: nil)),
            (NSURLErrorCannotParseResponse, .transient(.badServerResponse, retryAfter: nil)),
            (NSURLErrorSecureConnectionFailed, .transient(.secureConnectionFailed(urlErrorCode: NSURLErrorSecureConnectionFailed), retryAfter: nil)),
            (NSURLErrorClientCertificateRequired, .transient(.secureConnectionFailed(urlErrorCode: NSURLErrorClientCertificateRequired), retryAfter: nil)),
            (NSURLErrorZeroByteResource, .transient(.unknown(urlErrorCode: NSURLErrorZeroByteResource), retryAfter: nil)),
        ]
        for (code, expected) in table {
            #expect(PackErrorMapping.systemError(domain: NSURLErrorDomain, code: code) == expected, "\(code)")
        }
        #expect(PackErrorMapping.systemError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) == .transient(.unknown(urlErrorCode: 0), retryAfter: nil))
    }

    @Test("R-APL-2: documented pack and staging failures map to their transfer errors")
    func documentedFailures() {
        #expect(PackErrorMapping.transferError(PackError.packNotFound) == .permanentMissing(httpStatus: 404))
        #expect(PackErrorMapping.transferError(PackError.fileNotFound) == .permanentMissing(httpStatus: 404))
        #expect(PackErrorMapping.transferError(PackError.tooLarge(limit: 9)) == .integrity(.oversize(announced: nil, limit: 9)))
        #expect(PackErrorMapping.transferError(PackError.readFailed) == .transient(.localIO(posixCode: EIO), retryAfter: nil))
        #expect(PackErrorMapping.transferError(SourceFailure.notFound) == .permanentMissing(httpStatus: 404))
        #expect(PackErrorMapping.transferError(SourceFailure.notInstalled) == .permanentMissing(httpStatus: 404))
        #expect(PackErrorMapping.transferError(SourceFailure.readFailed) == .transient(.localIO(posixCode: EIO), retryAfter: nil))
        #expect(PackErrorMapping.transferError(StagingError.insufficientSpace, expectedBytes: 7) == .insufficientSpace(requiredBytes: 7))
        #expect(PackErrorMapping.transferError(StagingError.io(posixCode: EACCES), expectedBytes: nil) == .transient(.localIO(posixCode: EACCES), retryAfter: nil))
        #expect(PackErrorMapping.transferError(StagingError.tooLarge(limit: 5), expectedBytes: 9) == .integrity(.oversize(announced: 9, limit: 5)))
        #expect(PackErrorMapping.transferError(StagingError.nameInUse, expectedBytes: nil) == .transient(.localIO(posixCode: EEXIST), retryAfter: nil))
        #expect(PackErrorMapping.transferError(StagingError.source(.notFound), expectedBytes: nil) == .permanentMissing(httpStatus: 404))
    }

    @Test("R-APL-2: a pack error met while opening a file is reported to the sink as a source failure")
    func sourceFailures() {
        #expect(PackErrorMapping.sourceFailure(.packNotFound) == .notInstalled)
        #expect(PackErrorMapping.sourceFailure(.fileNotFound) == .notFound)
        #expect(PackErrorMapping.sourceFailure(.system(domain: "d", code: 3)) == .system(domain: "d", code: 3))
        #expect(PackErrorMapping.sourceFailure(.readFailed) == .readFailed)
        #expect(PackErrorMapping.sourceFailure(.tooLarge(limit: 1)) == .readFailed)
    }

    @available(macOS 26.0, *)
    @Test("R-APL-2: BackgroundAssets errors become pack errors at the live boundary without touching the manager")
    func liveErrorBoundary() {
        #expect(LiveAssetPackBackend.packError(ManagedBackgroundAssetsError.assetPackNotFound(withID: "ZTronMedia")) == .packNotFound)
        #expect(LiveAssetPackBackend.packError(ManagedBackgroundAssetsError.fileNotFound(at: FilePath("a.png"))) == .fileNotFound)
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(LiveAssetPackBackend.packError(network) == .system(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
    }
}
