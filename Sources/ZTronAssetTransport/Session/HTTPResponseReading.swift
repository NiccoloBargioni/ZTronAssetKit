import Foundation
import ZTronAssetModel

/// Copies the few header values classification needs out of an `HTTPURLResponse` into plain values, so no
/// response or request object outlives the callback that saw it (R-SEC-1, transport.md §5.4).
enum HTTPResponseReading {
    /// The facts of `response`. `bodyBytes` is what the task received (the 403 evidence); `keyPresented` whether the
    /// final request carried the key.
    static func facts(of response: HTTPURLResponse, bodyBytes: Int64, keyPresented: Bool) -> ResponseFacts {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return ResponseFacts(
            status: response.statusCode,
            bodyBytes: max(bodyBytes, 0),
            contentTypeIsXML: contentType.contains("xml"),
            retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(RetryAfterParser.parse),
            etag: response.value(forHTTPHeaderField: "ETag").flatMap(ETag.init(rawValue:)),
            contentRangeStart: self.contentRangeStart(response.value(forHTTPHeaderField: "Content-Range")),
            keyPresented: keyPresented
        )
    }

    /// The first byte position of `Content-Range: bytes <first>-<last>/<length|*>`; `nil` when absent or malformed.
    static func contentRangeStart(_ value: String?) -> Int64? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes ") else {
            return nil
        }
        let range = trimmed.dropFirst("bytes ".count)
        guard let dash = range.firstIndex(of: "-") else {
            return nil
        }
        let first = range[range.startIndex..<dash]
        guard (1...19).contains(first.utf8.count), first.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        return Int64(first)
    }

    /// The decoded length the response announces for the whole resource: `nil` when unknown, and always under a
    /// `Content-Encoding` other than identity, where `Content-Length` counts encoded bytes (R-NET-7). For a 206 it
    /// is the resumed offset plus the announced remainder, saturated at `Int64.max`: both figures come from outside
    /// (the server's `Content-Length`, the sidecar's offset) and Swift traps on overflow, so a hostile length must
    /// read as "too large" and fail the size guard, never end the process (review round 3).
    static func announcedTotal(of response: HTTPURLResponse, offset: Int64) -> Int64? {
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespaces),
            !encoding.isEmpty, encoding.lowercased() != "identity"
        {
            return nil
        }
        let length = response.expectedContentLength
        guard length >= 0 else {
            return nil
        }
        return response.statusCode == 206 ? Saturating.add(offset, length) : length
    }

    /// The `If-Range` validator a later attempt may send (RFC 9110 §13.1.5): a strong `ETag`, else `Last-Modified`.
    /// A weak tag is never a valid `If-Range`.
    static func resumeValidator(of response: HTTPURLResponse) -> ResumeValidator? {
        if let tag = response.value(forHTTPHeaderField: "ETag").flatMap(ETag.init(rawValue:)), !tag.rawValue.hasPrefix("W/") {
            return .strongETag(tag)
        }
        if let date = response.value(forHTTPHeaderField: "Last-Modified"), ETag(rawValue: date) != nil {
            // Same bounds as an entity tag: 1…256 printable bytes, so a hostile header cannot grow the sidecar.
            return .lastModified(date)
        }
        return nil
    }

    /// Whether `request` carries the key header named by `policy`.
    static func carriesKey(_ request: URLRequest?, policy: TransportSecurityPolicy) -> Bool {
        request?.value(forHTTPHeaderField: policy.keyHeaderName) != nil
    }

    /// The `URLError` facts of a completion error: code, network-unavailable reason, background cancel reason and
    /// the underlying POSIX code of a file error. Nothing else of the error object is kept.
    static func errorFacts(_ error: any Error) -> (code: Int, unavailable: Int?, cancelReason: Int?, posix: Int32?) {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = underlying.flatMap { $0.domain == NSPOSIXErrorDomain ? Int32(truncatingIfNeeded: $0.code) : nil }
        return (
            error.code,
            error.userInfo[NSURLErrorNetworkUnavailableReasonKey] as? Int,
            error.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int,
            posix
        )
    }
}

/// The hop count of a redirect chain, stored on each followed request as in-process metadata
/// (`URLProtocol.setProperty`), never sent (transport.md §5.2): the stateless delegate reads it back from the
/// task's current request.
enum RedirectHop {
    private static let key = "com.ztron.assetkit.redirect-hop"

    /// The hops already followed to reach `request` (0 for the original request).
    static func count(of request: URLRequest?) -> Int {
        request.flatMap { URLProtocol.property(forKey: Self.key, in: $0) as? Int } ?? 0
    }

    /// `request` marked as hop `hop`, with the key header removed unless `keepKey`.
    static func prepare(_ request: URLRequest, hop: Int, keepKey: Bool, policy: TransportSecurityPolicy) -> URLRequest {
        var next = request
        if !keepKey {
            next.setValue(nil, forHTTPHeaderField: policy.keyHeaderName)
        }
        // `-[NSURLRequest mutableCopy]` returns an `NSMutableURLRequest` (NSURLRequest.h), the only type
        // `setProperty` accepts.
        let mutable = (next as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(hop, forKey: Self.key, in: mutable)
        return mutable as URLRequest
    }
}
