import Foundation

/// The closed taxonomy every transport and the Apple tier map HTTP, URL and pack errors into (R-NET-6).
///
/// Values carry plain facts only (codes, sizes, flags): never a `URLRequest`, `URLResponse`, `URLError` or `NSError`,
/// because those can reach headers and therefore the app key (transport design §5.4, R-SEC-1). The engine maps
/// each case to an action (ARCHITECTURE §7.6) and the facade maps it to `AssetError`.
public enum TransferError: Error, Sendable, Hashable {
    /// No path, or the OS refused this network for the request.
    case offline(OfflineReason)
    /// Worth retrying with backoff; `retryAfter` is the server's hint as received.
    case transient(TransientCause, retryAfter: RetryAfter?)
    /// 404 or 410 (and the Apple tier's file/pack-not-found).
    case permanentMissing(httpStatus: Int)
    /// 403: a rejected key or a missing object (SPEC §2.3), reported with evidence, never as a verdict.
    case authentication(AuthenticationFailure)
    /// The bytes cannot be right (size, truncation, cap, undecodable content encoding).
    case integrity(TransferIntegrityFailure)
    /// ENOSPC while staging.
    case insufficientSpace(requiredBytes: Int64?)
    /// Our own policy refused the request or response; not retried within a run.
    case rejected(PolicyViolation)
    /// Cancelled by the client or the system; not a failure.
    case cancelled(CancellationCause)
}

/// Why a request was considered offline.
public enum OfflineReason: Sendable, Hashable {
    /// No satisfied path.
    case noConnection
    /// Cellular was not allowed for this request.
    case cellularDenied
    /// Expensive networks were not allowed for this request.
    case expensiveDenied
    /// Low Data Mode forbade this request.
    case constrainedDenied
    /// International roaming is off.
    case roamingDisabled
    /// A call is active on a network that cannot carry data at the same time.
    case callActive
}

/// The transient causes the engine distinguishes.
public enum TransientCause: Sendable, Hashable {
    /// Request timeout.
    case timedOut
    /// The connection dropped; `resumable` when a `.part` and a sidecar with a validator exist.
    case connectionLost(resumable: Bool)
    /// The host refused the connection.
    case cannotConnect
    /// Name resolution failed.
    case dnsFailure
    /// TLS failed (a captive portal heals on a path change).
    case secureConnectionFailed(urlErrorCode: Int)
    /// The server's response could not be parsed.
    case badServerResponse
    /// 5xx (feeds the 5xx breaker window).
    case serverError(httpStatus: Int)
    /// 429 (feeds the origin throttle).
    case throttled
    /// A resumed request could not be continued: a 416, a 206 without `Content-Range` or whose range does not start at
    /// the earlier partial's size, an earlier partial that vanished, or −1002 (ADR-050; D-3, D-4). Only a request
    /// that resumed gets it (a 206 or 416 to a fresh request is `rejected(.unexpectedStatus)`), so the immediate fresh
    /// attempt cannot loop. A changed validator is not a refusal: the 200 that answers it restarts the partial from
    /// zero. In the background only a task created from resume data for checksummed content reads these signals so
    /// (D-19.1, D-19.2). The engine's action: discard the partial and sidecar, then a fresh attempt without backoff
    /// (ARCHITECTURE §7.6).
    case resumeRejected
    /// The background session is unusable (−995/−996/−997): the coordinator disables background for the process, and
    /// the engine's action is a retry in the foreground (ARCHITECTURE §7.6). The HTTP source never surfaces it for a
    /// transfer the background cannot take (no size, a negative one, or one past the cap): `startIfAdmitted` declines
    /// it and it runs in the foreground. Only a direct `BackgroundTransferCoordinator.start` of such a job, which no
    /// production caller makes, answers it, with `NSURLErrorUnknown` (ADR-050, D-15).
    case backgroundSessionUnavailable(urlErrorCode: Int)
    /// A local file error other than ENOSPC while staging.
    case localIO(posixCode: Int32)
    /// Defensive: the stream ended without a terminal element.
    case incompleteCallbackSequence
    /// A 401 or an authentication challenge (−1012/−1013): our origin never sends these, so they come from a
    /// proxy or captive portal and heal on a path change (transport-1 TR1-11). Never opens the breaker.
    case authenticationChallenge(httpStatus: Int)
    /// Apple tier: the catalog and the media pack disagree while the pack is updating (transport-2 T2-12).
    case sourceVersionSkew
    /// Anything else.
    case unknown(urlErrorCode: Int)
}

/// A `Retry-After` value as received (RFC 9110 §10.2.3). The engine turns it into a deadline with its
/// `TimeSource` and clamps it; the transport never reads a clock.
public enum RetryAfter: Sendable, Hashable {
    /// Delta-seconds.
    case seconds(UInt32)
    /// An HTTP-date.
    case date(Date)
}

/// The 403 family (SPEC §2.3).
public enum AuthenticationFailure: Sendable, Hashable {
    /// A 403 with the evidence needed to weigh "key rejected" against "object missing".
    case forbiddenAmbiguous(ForbiddenEvidence)
}

/// What a 403 response looked like (transport-1 TR1-5/6/7).
public struct ForbiddenEvidence: Sendable, Hashable {
    /// Whether the request was for the manifest or an asset.
    public var purpose: TransferPurpose
    /// Body length: the CloudFront Function's rejection has an empty body.
    public var bodyBytes: Int64
    /// Whether the body was XML: S3's `AccessDenied` means the key passed the Function.
    public var contentTypeIsXML: Bool
    /// Whether the final request carried the app key (it is stripped on cross-origin redirects).
    public var keyPresented: Bool
    /// Whether the request resumed a partial download.
    public var resumed: Bool

    /// Creates evidence.
    public init(purpose: TransferPurpose, bodyBytes: Int64, contentTypeIsXML: Bool, keyPresented: Bool, resumed: Bool) {
        self.purpose = purpose
        self.bodyBytes = bodyBytes
        self.contentTypeIsXML = contentTypeIsXML
        self.keyPresented = keyPresented
        self.resumed = resumed
    }

    /// The hint, body first (transport-1 TR1-7): XML ⇒ object missing; empty ⇒ key rejected; otherwise the
    /// manifest breaks the tie towards key rejected; everything else is undetermined.
    public var hint: ForbiddenHint {
        if self.contentTypeIsXML {
            return .objectMissingLikely
        }
        if self.bodyBytes == 0 {
            return .keyRejectedLikely
        }
        return self.purpose == .manifest ? .keyRejectedLikely : .undetermined
    }
}

/// The transport's reading of a 403; the engine decides (breaker, sync design §8.3).
public enum ForbiddenHint: Sendable, Hashable {
    /// Probably the CloudFront Function rejected the key.
    case keyRejectedLikely
    /// Probably the object is missing behind OAC.
    case objectMissingLikely
    /// No evidence either way.
    case undetermined
}

/// Size and content failures detected by the transport (R-NET-7). The store's hash check is separate (R-INT-2).
public enum TransferIntegrityFailure: Sendable, Hashable {
    /// The staged size exceeds `byteSize`.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The staged size is below `byteSize`, or the resource was empty.
    case truncated(expected: Int64?, received: Int64)
    /// The announced or written size exceeds the cap; aborted early.
    case oversize(announced: Int64?, limit: Int64)
    /// A corrupt content encoding.
    case undecodableContent(urlErrorCode: Int)
}

/// Requests our own policy refused (R-NET-4, R-SEC-2 defence in depth).
public enum PolicyViolation: Sendable, Hashable {
    /// Plain HTTP outside the loopback test policy.
    case insecureScheme
    /// A host outside the allow-list.
    case hostNotAllowed
    /// A refused redirect.
    case redirectRefused(RedirectRefusal)
    /// A status the classifier does not expect (e.g. 400).
    case unexpectedStatus(Int)
    /// A 304 to an unconditional request.
    case unexpectedNotModified
    /// The URL could not be built from `baseURL` and `remotePath`.
    case invalidURL
    /// A keyed origin answered 403 after we withheld the key on a cross-origin redirect (transport-1 TR1-6).
    case keyWithheldOnRedirect
}

/// Why a redirect was refused.
public enum RedirectRefusal: Sendable, Hashable {
    /// To a non-HTTPS URL.
    case insecureScheme
    /// To a host outside the allow-list.
    case hostNotAllowed
    /// More than 5 hops.
    case tooManyRedirects
    /// An unusable `Location`.
    case invalidLocation
    /// Detected after the fact in a background session (the OS follows redirects there).
    case unenforceableInBackground
}

/// Who cancelled.
public enum CancellationCause: Sendable, Hashable {
    /// The engine or the consumer.
    case byClient
    /// The system (background session).
    case bySystem(SystemCancellationReason)
}

/// `NSURLErrorBackgroundTaskCancelledReasonKey` values.
public enum SystemCancellationReason: Sendable, Hashable {
    /// The user force-quit the app.
    case userForceQuitApplication
    /// Background App Refresh is off.
    case backgroundUpdatesDisabled
    /// The system ran out of resources.
    case insufficientSystemResources
    /// A value this build does not know.
    case unknown(Int)
}
