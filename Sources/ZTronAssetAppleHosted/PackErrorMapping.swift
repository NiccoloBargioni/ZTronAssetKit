import Foundation
import ZTronAssetModel

/// Maps Apple-tier failures into the closed `TransferError` taxonomy (R-NET-6, transport.md §11.1).
///
/// The concrete error types `ensureLocalAvailability`, `checkForUpdates` and `remove` throw are UNVERIFIED
/// (APPLE-API-VERIFICATION §1.8), so an undocumented system error must never become `integrity`: that would make the
/// engine quarantine good content (transport-2 T2-12). An `NSURLErrorDomain` code reuses the connectivity rows of the
/// URLError table (transport.md §3.4.2), so an offline pack download is reported as offline; every other system
/// error is `transient(.unknown)`, which the engine backs off and retries. Pure, so every row is tested on the host.
enum PackErrorMapping {
    /// A `PackError` from the pack seam.
    static func transferError(_ error: PackError) -> TransferError {
        switch error {
        case .packNotFound, .fileNotFound:
            return .permanentMissing(httpStatus: 404)
        case .tooLarge(let limit):
            return .integrity(.oversize(announced: nil, limit: limit))
        case .readFailed:
            return .transient(.localIO(posixCode: EIO), retryAfter: nil)
        case .system(let domain, let code):
            return self.systemError(domain: domain, code: code)
        }
    }

    /// A failure of `StagingSink.writeStaged` / `readStaged` while copying out of a pack. `expectedBytes` is the
    /// catalog's size, reported with an oversize failure and as the space a full disk needs.
    static func transferError(_ error: StagingError, expectedBytes: Int64?) -> TransferError {
        switch error {
        case .insufficientSpace:
            return .insufficientSpace(requiredBytes: expectedBytes)
        case .io(let posixCode):
            return .transient(.localIO(posixCode: posixCode), retryAfter: nil)
        case .tooLarge(let limit):
            return .integrity(.oversize(announced: expectedBytes, limit: limit))
        case .source(let failure):
            return self.transferError(failure)
        case .nameInUse:
            return .transient(.localIO(posixCode: EEXIST), retryAfter: nil)
        }
    }

    /// A failure of the pack reader itself.
    static func transferError(_ failure: SourceFailure) -> TransferError {
        switch failure {
        case .notFound, .notInstalled:
            return .permanentMissing(httpStatus: 404)
        case .readFailed:
            return .transient(.localIO(posixCode: EIO), retryAfter: nil)
        case .system(let domain, let code):
            return self.systemError(domain: domain, code: code)
        }
    }

    /// A `PackError` met while opening a pack file, as the reader reports it to the sink: an absent pack and an
    /// absent file both make the source ask for the pack (transport.md §11.3); nothing becomes integrity.
    static func sourceFailure(_ error: PackError) -> SourceFailure {
        switch error {
        case .packNotFound:
            return .notInstalled
        case .fileNotFound:
            return .notFound
        case .system(let domain, let code):
            return .system(domain: domain, code: code)
        case .tooLarge, .readFailed:
            return .readFailed
        }
    }

    /// An undocumented system error: connectivity codes of `NSURLErrorDomain` keep their meaning, everything else is
    /// `transient(.unknown)`. A code of another domain is not a URL error code, so it is reported as 0 (the source
    /// logs the domain and code).
    static func systemError(domain: String, code: Int) -> TransferError {
        guard domain == NSURLErrorDomain else {
            return .transient(.unknown(urlErrorCode: 0), retryAfter: nil)
        }
        switch code {
        case NSURLErrorNotConnectedToInternet:
            return .offline(.noConnection)
        case NSURLErrorInternationalRoamingOff:
            return .offline(.roamingDisabled)
        case NSURLErrorCallIsActive:
            return .offline(.callActive)
        case NSURLErrorDataNotAllowed:
            return .offline(.cellularDenied)
        case NSURLErrorTimedOut:
            return .transient(.timedOut, retryAfter: nil)
        case NSURLErrorNetworkConnectionLost:
            return .transient(.connectionLost(resumable: false), retryAfter: nil)
        case NSURLErrorCannotConnectToHost:
            return .transient(.cannotConnect, retryAfter: nil)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .transient(.dnsFailure, retryAfter: nil)
        case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse:
            return .transient(.badServerResponse, retryAfter: nil)
        case NSURLErrorClientCertificateRequired...NSURLErrorSecureConnectionFailed:
            return .transient(.secureConnectionFailed(urlErrorCode: code), retryAfter: nil)
        default:
            return .transient(.unknown(urlErrorCode: code), retryAfter: nil)
        }
    }
}
