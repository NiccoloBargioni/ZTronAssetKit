import Foundation
import ZTronAssetModel

/// Builds every `URLRequest` the transport sends (R-NET-4, R-NET-5, R-NET-8): the **only** place the app key is
/// attached, and only after `TransportSecurityPolicy.check` allowed the request's origin (transport.md §5.3 rule 1).
///
/// A value of `Sendable` lets, so the foreground backend and the background coordinator can hold it without a lock.
/// The key is read through `AppKey`'s package-only `secret`; nothing here logs or stores a request.
struct RequestFactory: Sendable {
    /// Which origins may be contacted, and the key's header name; `nil` only for a background coordinator built
    /// without one, whose jobs the source already checked and which then attaches no key.
    let policy: TransportSecurityPolicy?
    /// The key, when the configuration has one.
    let appKey: AppKey?
    /// Applied to every request as well as the session: a request's own interval overrides the session's
    /// (transport.md §4.1, E-16).
    let timeout: TimeInterval

    /// The request for `job`, or the policy violation that forbids contacting its origin.
    func makeRequest(for job: TransferJob) -> Built {
        if let violation = self.policy?.check(Origin(url: job.url)) {
            return .refused(violation)
        }
        var request = URLRequest(url: job.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: self.timeout)
        request.httpMethod = "GET"
        request.allowsCellularAccess = job.access.allowsCellular
        request.allowsExpensiveNetworkAccess = job.access.allowsExpensive
        request.allowsConstrainedNetworkAccess = job.access.allowsConstrained
        request.httpShouldHandleCookies = false
        if let key = self.appKey, let policy = self.policy {
            request.setValue(key.secret, forHTTPHeaderField: policy.keyHeaderName)
        }
        if let tag = job.ifNoneMatch {
            request.setValue(tag.rawValue, forHTTPHeaderField: "If-None-Match")
        }
        if let resume = job.resume {
            // Our own partial continues with Range + If-Range (ADR-019); the validator came from our sidecar, the
            // key from the current configuration, so a resumed request never carries a stale key (TR1-5).
            request.setValue("bytes=\(resume.offset)-", forHTTPHeaderField: "Range")
            switch resume.validator {
            case .strongETag(let tag):
                request.setValue(tag.rawValue, forHTTPHeaderField: "If-Range")
            case .lastModified(let date):
                request.setValue(date, forHTTPHeaderField: "If-Range")
            }
        }
        return .request(request)
    }

    /// A built request, or why the origin may not be contacted.
    enum Built {
        /// Send this.
        case request(URLRequest)
        /// The policy refuses the origin.
        case refused(PolicyViolation)
    }
}

/// Joins `baseURL` and a manifest `remotePath` by path components only (transport-1 TR1-10).
///
/// The Model already rejected absolute paths, schemes, authorities, `..`, empty and `.` segments (also `%2E`), `\`,
/// control characters, `?` and `#` (R-MAN-2; the empty and `.` segments and `\` since Stage 3, S3AH-1); this is
/// defence in depth for paths that reach the transport by another route (the manifest path of the configuration).
/// Each component is appended with `appendingPathComponent`, which percent-encodes it, exactly
/// as the prior art built its URLs; empty components, `.` and `..` (also percent-encoded), `?`, `#` and `\` reject
/// the whole path.
enum RemoteURL {
    /// The absolute URL, or `nil` for a path that could name anything but a file under `base`.
    static func make(base: URL, path: String) -> URL? {
        var url = base
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            let text = String(component)
            let decoded = text.removingPercentEncoding ?? text
            guard !text.isEmpty, decoded != ".", decoded != "..",
                !text.contains("?"), !text.contains("#"), !text.contains("\\")
            else {
                return nil
            }
            url = url.appendingPathComponent(text, isDirectory: false)
        }
        return url
    }
}
