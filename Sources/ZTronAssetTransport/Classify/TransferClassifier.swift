import Foundation
import ZTronAssetModel

/// The plain facts a response contributes to classification: no `URLResponse`, `URLRequest` or `URLError` object is
/// ever kept, because those reach headers and therefore the app key (R-SEC-1, transport.md §5.4).
public struct ResponseFacts: Sendable, Hashable {
    /// The final HTTP status.
    public var status: Int
    /// The response body length received (the 403 evidence).
    public var bodyBytes: Int64
    /// `Content-Type` is XML (S3's `AccessDenied`).
    public var contentTypeIsXML: Bool
    /// The parsed `Retry-After`, if any.
    public var retryAfter: RetryAfter?
    /// The `ETag` header, if valid.
    public var etag: ETag?
    /// The `Content-Range` start of a 206, if any.
    public var contentRangeStart: Int64?
    /// Whether the final request carried the app key.
    public var keyPresented: Bool

    /// Creates facts.
    public init(
        status: Int,
        bodyBytes: Int64,
        contentTypeIsXML: Bool,
        retryAfter: RetryAfter?,
        etag: ETag?,
        contentRangeStart: Int64?,
        keyPresented: Bool
    ) {
        self.status = status
        self.bodyBytes = bodyBytes
        self.contentTypeIsXML = contentTypeIsXML
        self.retryAfter = retryAfter
        self.etag = etag
        self.contentRangeStart = contentRangeStart
        self.keyPresented = keyPresented
    }
}

/// The pure HTTP-status and URL-error classification of R-NET-6 (transport.md §3.4.1–3.4.2 as amended:
/// −1002 on a resumed request means unusable resume state → `resumeRejected` (transport-1 TR1-4), 401/−1012/−1013
/// → `authenticationChallenge` (TR1-11), a 403 after we withheld the key → `keyWithheldOnRedirect` (TR1-6)).
public enum TransferClassifier {
    /// Classifies a final status: `nil` for success statuses (200, a matching 206, a conditional 304).
    public static func classify(
        _ facts: ResponseFacts,
        purpose: TransferPurpose,
        sentConditional: Bool,
        resumed: Bool,
        keyWithheld: Bool
    ) -> TransferError? {
        let status = facts.status
        switch status {
        case 200:
            return nil
        case 206:
            // Partial content answers only a resumed request, and only with a `Content-Range` to append at; the
            // delegate compares its start with the partial's size (ARCHITECTURE §6.3).
            guard resumed else {
                return .rejected(.unexpectedStatus(status))
            }
            return facts.contentRangeStart == nil ? .transient(.resumeRejected, retryAfter: nil) : nil
        case 304:
            return sentConditional ? nil : .rejected(.unexpectedNotModified)
        case 300...399:
            // A redirect delivered as the final response was refused or had no usable `Location`; the delegate
            // recomputes the precise refusal when it can (transport.md §5.2).
            return .rejected(.redirectRefused(.invalidLocation))
        case 401:
            return .transient(.authenticationChallenge(httpStatus: status), retryAfter: nil)
        case 403:
            guard !keyWithheld else {
                return .rejected(.keyWithheldOnRedirect)
            }
            let evidence = ForbiddenEvidence(
                purpose: purpose,
                bodyBytes: facts.bodyBytes,
                contentTypeIsXML: facts.contentTypeIsXML,
                keyPresented: facts.keyPresented,
                resumed: resumed
            )
            return .authentication(.forbiddenAmbiguous(evidence))
        case 404, 410:
            return .permanentMissing(httpStatus: status)
        case 408:
            return .transient(.timedOut, retryAfter: facts.retryAfter)
        case 416:
            // Only a range we asked for can be unsatisfiable; restarting a fresh request on a 416 would loop.
            return resumed ? .transient(.resumeRejected, retryAfter: nil) : .rejected(.unexpectedStatus(status))
        case 429:
            return .transient(.throttled, retryAfter: facts.retryAfter)
        case 500...599:
            return .transient(.serverError(httpStatus: status), retryAfter: facts.retryAfter)
        default:
            return .rejected(.unexpectedStatus(status))
        }
    }

    /// Classifies a `URLError` code (with its network-unavailable reason and background cancel reason, when any).
    public static func classify(
        urlErrorCode: Int,
        networkUnavailableReason: Int?,
        backgroundCancelReason: Int?,
        resumed: Bool,
        underlyingPOSIXCode: Int32?
    ) -> TransferError {
        switch urlErrorCode {
        case -999:
            guard let backgroundCancelReason else {
                return .cancelled(.byClient)
            }
            return .cancelled(.bySystem(Self.systemReason(backgroundCancelReason)))
        case -1001:
            return .transient(.timedOut, retryAfter: nil)
        case -1005:
            // `resumable` is the delegate's to decide: only it knows whether a partial and a sidecar were kept.
            return .transient(.connectionLost(resumable: false), retryAfter: nil)
        case -1004:
            return .transient(.cannotConnect, retryAfter: nil)
        case -1003, -1006:
            return .transient(.dnsFailure, retryAfter: nil)
        case -1009:
            return .offline(Self.offlineReason(networkUnavailableReason))
        case -1018:
            return .offline(.roamingDisabled)
        case -1019:
            return .offline(.callActive)
        case -1020:
            return .offline(.cellularDenied)
        case -1007:
            return .rejected(.redirectRefused(.tooManyRedirects))
        case -1010:
            return .rejected(.redirectRefused(.invalidLocation))
        case -1022:
            return .rejected(.insecureScheme)
        case -1000:
            return .rejected(.invalidURL)
        case -1002:
            // On a resumed request −1002 means unusable resume state (transport-1 TR1-4), not a bad URL.
            return resumed ? .transient(.resumeRejected, retryAfter: nil) : .rejected(.invalidURL)
        case -1012, -1013:
            return .transient(.authenticationChallenge(httpStatus: 0), retryAfter: nil)
        case -1011, -1017:
            return .transient(.badServerResponse, retryAfter: nil)
        case -1014:
            return .integrity(.truncated(expected: nil, received: 0))
        case -1015, -1016, -3006, -3007:
            return .integrity(.undecodableContent(urlErrorCode: urlErrorCode))
        case -1206 ... -1200:
            return .transient(.secureConnectionFailed(urlErrorCode: urlErrorCode), retryAfter: nil)
        case -3005 ... -3000:
            if underlyingPOSIXCode == ENOSPC {
                return .insufficientSpace(requiredBytes: nil)
            }
            return .transient(.localIO(posixCode: underlyingPOSIXCode ?? 0), retryAfter: nil)
        case -997 ... -995:
            return .transient(.backgroundSessionUnavailable(urlErrorCode: urlErrorCode), retryAfter: nil)
        default:
            return .transient(.unknown(urlErrorCode: urlErrorCode), retryAfter: nil)
        }
    }

    /// A failure classified for a plain request, as it reads once the request turns out to have resumed: what
    /// `resumed: true` changes in both tables (a 206 without `Content-Range`, a 416, −1002) is `resumeRejected`.
    /// The background session classifies its tasks without knowing which ones the OS continued from resume data;
    /// the coordinator, which handed the data over, applies this (orchestrator ruling D-14.2). `rejected(.invalidURL)`
    /// also stands for −1000, which a task continuing resume data built from a validated URL cannot produce.
    static func asResumed(_ failure: TransferError) -> TransferError {
        switch failure {
        case .rejected(.invalidURL), .rejected(.unexpectedStatus(206)), .rejected(.unexpectedStatus(416)):
            return .transient(.resumeRejected, retryAfter: nil)
        default:
            return failure
        }
    }

    /// `URLError.NetworkUnavailableReason` raw values (NSURLError.h): cellular 0, expensive 1, constrained 2.
    private static func offlineReason(_ reason: Int?) -> OfflineReason {
        switch reason {
        case 0:
            return .cellularDenied
        case 1:
            return .expensiveDenied
        case 2:
            return .constrainedDenied
        default:
            return .noConnection
        }
    }

    /// `NSURLErrorBackgroundTaskCancelledReasonKey` raw values (NSURLError.h).
    private static func systemReason(_ reason: Int) -> SystemCancellationReason {
        switch reason {
        case 0:
            return .userForceQuitApplication
        case 1:
            return .backgroundUpdatesDisabled
        case 2:
            return .insufficientSystemResources
        default:
            return .unknown(reason)
        }
    }
}

/// `Retry-After` parsing (RFC 9110 §10.2.3): delta-seconds (≤ 10 digits) and all three HTTP-date formats,
/// hand-written (no `DateFormatter`, no locale, no `Regex` at the floor). Garbage, negatives and over-long values are
/// `nil` (absent), so the engine's own backoff applies.
public enum RetryAfterParser {
    /// Parses a header value.
    public static func parse(_ value: String) -> RetryAfter? {
        let bytes = Array(value.utf8.drop { $0 == 0x20 || $0 == 0x09 }.reversed().drop { $0 == 0x20 || $0 == 0x09 }.reversed())
        guard !bytes.isEmpty, bytes.count <= 64 else {
            return nil
        }
        if bytes.allSatisfy({ (0x30...0x39).contains($0) }) {
            guard bytes.count <= 10, let seconds = UInt32(String(decoding: bytes, as: UTF8.self)) else {
                return nil
            }
            return .seconds(seconds)
        }
        guard let seconds = HTTPDate.parse(bytes) else {
            return nil
        }
        return .date(Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
