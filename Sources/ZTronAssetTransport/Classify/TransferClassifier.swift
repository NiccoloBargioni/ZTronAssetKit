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
        fatalError("WP-D: TransferClassifier.classify(status) not implemented")
    }

    /// Classifies a `URLError` code (with its network-unavailable reason and background cancel reason, when any).
    public static func classify(
        urlErrorCode: Int,
        networkUnavailableReason: Int?,
        backgroundCancelReason: Int?,
        resumed: Bool,
        underlyingPOSIXCode: Int32?
    ) -> TransferError {
        fatalError("WP-D: TransferClassifier.classify(urlError) not implemented")
    }
}

/// `Retry-After` parsing (RFC 9110 §10.2.3): delta-seconds (≤ 10 digits) and all three HTTP-date formats,
/// hand-written (no `DateFormatter`, no locale, no `Regex` at the floor). Garbage, negatives and over-long values are
/// `nil` (absent), so the engine's own backoff applies.
public enum RetryAfterParser {
    /// Parses a header value.
    public static func parse(_ value: String) -> RetryAfter? {
        fatalError("WP-D: RetryAfterParser.parse not implemented")
    }
}
