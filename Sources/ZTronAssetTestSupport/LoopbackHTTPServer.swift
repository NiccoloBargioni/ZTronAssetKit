import Foundation
import ZTronAssetModel

/// One request the loopback server received (P-10 connection counts, key-stripping and Range assertions).
public struct LoopbackRequest: Sendable, Hashable {
    /// 1-based accept order of the connection.
    public let connection: Int
    /// Global request order.
    public let sequence: Int
    /// The n-th request for this target (scripts like "first drop, then 206").
    public let pathSequence: Int
    /// `GET`, …
    public let method: String
    /// The request target.
    public let target: String
    /// Headers with lowercased names.
    public let headers: [String: String]

    /// Creates a record.
    public init(connection: Int, sequence: Int, pathSequence: Int, method: String, target: String, headers: [String: String]) {
        self.connection = connection
        self.sequence = sequence
        self.pathSequence = pathSequence
        self.method = method
        self.target = target
        self.headers = headers
    }

    /// A header by case-insensitive name.
    public func header(_ name: String) -> String? {
        self.headers[name.lowercased()]
    }
}

/// How a response body ends (transport.md §12, ADR-T8).
public enum LoopbackEnding: Sendable, Hashable {
    /// The whole body.
    case complete
    /// FIN after this many body bytes: a deterministic "connection lost" (gating tests use this).
    case closeAfter(bodyBytes: Int)
    /// Hold the connection after this many bytes until `stop()`: a deterministic mid-flight state.
    case stallAfter(bodyBytes: Int)
}

/// The body encoding.
public enum LoopbackEncoding: Sendable, Hashable {
    /// No encoding.
    case identity
    /// RFC 1952 gzip.
    case gzip
}

/// A scripted response.
public struct LoopbackResponse: Sendable, Hashable {
    /// The status.
    public var status: Int
    /// Extra headers.
    public var headers: [String: String]
    /// The decoded body.
    public var body: Data
    /// The encoding.
    public var encoding: LoopbackEncoding
    /// How the body ends.
    public var ending: LoopbackEnding
    /// Artificial latency before the response (only honoured by `LiveLoopbackDelay`).
    public var latencyNanoseconds: UInt64
    /// When set: send `ETag` + `Accept-Ranges` and honour `Range` / `If-Range` with 206.
    public var rangeETag: String?
    /// A close-delimited body without `Content-Length`.
    public var omitContentLength: Bool

    /// Creates a response.
    public init(
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        encoding: LoopbackEncoding = .identity,
        ending: LoopbackEnding = .complete,
        latencyNanoseconds: UInt64 = 0,
        rangeETag: String? = nil,
        omitContentLength: Bool = false
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.encoding = encoding
        self.ending = ending
        self.latencyNanoseconds = latencyNanoseconds
        self.rangeETag = rangeETag
        self.omitContentLength = omitContentLength
    }
}

/// How the server waits for scripted latency.
public protocol LoopbackDelay: Sendable {
    /// Waits.
    func wait(nanoseconds: UInt64) async
}

/// Never waits: correctness tests never sleep (C4, Q-4).
public struct NoLoopbackDelay: LoopbackDelay {
    /// Creates the delay.
    public init() {}

    /// Returns at once.
    public func wait(nanoseconds: UInt64) async {}
}

/// Really waits: **only** the P-11 benchmark uses it, whose subject is wall time.
public struct LiveLoopbackDelay: LoopbackDelay {
    /// Creates the delay.
    public init() {}

    /// `Task.sleep(nanoseconds:)`.
    public func wait(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// The scripted handler.
public typealias LoopbackHandler = @Sendable (LoopbackRequest) -> LoopbackResponse

/// A plain HTTP/1.1 server on `127.0.0.1`, ephemeral port, loopback interface only (ADR-011; WP-H): an actor over
/// `NWListener`, keep-alive, one async loop per connection. Never used outside tests and benchmarks; the only
/// plaintext policy that reaches it is the package-only `TransportSecurityPolicy.loopbackTesting`.
public actor LoopbackHTTPServer {
    private let delay: any LoopbackDelay
    private let handler: LoopbackHandler

    /// Creates a server (not listening yet).
    public init(delay: any LoopbackDelay = NoLoopbackDelay(), handler: @escaping LoopbackHandler) {
        self.delay = delay
        self.handler = handler
    }

    /// Starts listening; returns the port.
    public func start() async throws -> UInt16 {
        fatalError("WP-H: LoopbackHTTPServer.start not implemented")
    }

    /// Stops the listener and every connection (stalled ones included).
    public func stop() {
        fatalError("WP-H: LoopbackHTTPServer.stop not implemented")
    }

    /// Connections accepted so far (P-10).
    public var acceptedConnections: Int {
        fatalError("WP-H: LoopbackHTTPServer.acceptedConnections not implemented")
    }

    /// Requests received so far.
    public var requests: [LoopbackRequest] {
        fatalError("WP-H: LoopbackHTTPServer.requests not implemented")
    }
}

/// RFC 1952 gzip framing around raw DEFLATE, plus CRC-32 (the gzip scenario of SPEC §7.3).
public enum Gzip {
    /// Compresses `data`.
    public static func compress(_ data: Data) -> Data {
        fatalError("WP-H: Gzip.compress not implemented")
    }

    /// The CRC-32 of `data`.
    public static func crc32(_ data: Data) -> UInt32 {
        fatalError("WP-H: Gzip.crc32 not implemented")
    }
}
