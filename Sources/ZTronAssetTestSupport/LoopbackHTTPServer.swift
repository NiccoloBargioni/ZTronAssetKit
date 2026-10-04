import Foundation
import Network
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
///
/// Behaviour (transport.md §12, ARCHITECTURE §6.7): requests are parsed in arrival order (a `Content-Length` request
/// body is consumed), numbered globally, per target and by 1-based connection, and answered by the handler on the
/// actor. A request whose `Content-Length` is not a digit string of at most 64 MiB is answered `400` and its
/// connection closed; it never reaches the handler or `requests`. Responses carry `Content-Length` (unless
/// `omitContentLength`, which closes the connection after the body, or the script sets one: a scripted
/// `Content-Length` in any case is sent as scripted), `Connection`, and, for `.gzip`, `Content-Encoding: gzip` over
/// a `Gzip` body; header names merge case-insensitively, the server's own replacing scripted ones. With
/// `rangeETag`, a 200 becomes a 206 for `Range: bytes=a-` or `bytes=a-b` when `If-Range` is absent or equals the tag
/// (416 when the start is past the end); any other `If-Range` gets the whole body. `.closeAfter(n)` sends n body
/// bytes and a FIN (the deterministic "connection lost"; never RST, transport.md E-16); `.stallAfter(n)` sends n
/// bytes and holds the connection until `stop()`. Latency goes through the injected `LoopbackDelay`, which never
/// sleeps by default.
public actor LoopbackHTTPServer {
    private let delay: any LoopbackDelay
    private let handler: LoopbackHandler
    private let queue = DispatchQueue(label: "com.ztron.assetkit.tests.loopback-server")
    private var listener: NWListener?
    private var port: UInt16?
    private var connections: [Int: NWConnection] = [:]
    private var accepted = 0
    private var sequence = 0
    private var perTarget: [String: Int] = [:]
    private var log: [LoopbackRequest] = []
    private var stopped = false
    private var starting: Task<UInt16, any Error>?

    /// The largest request body the server buffers (a larger `Content-Length` is answered with 400).
    static let maxRequestBodyBytes = 64 << 20

    /// Creates a server (not listening yet).
    public init(delay: any LoopbackDelay = NoLoopbackDelay(), handler: @escaping LoopbackHandler) {
        self.delay = delay
        self.handler = handler
    }

    deinit {
        self.listener?.cancel()
        for connection in self.connections.values {
            connection.cancel()
        }
    }

    /// Starts listening; returns the port. Idempotent: a call while running returns the port, and calls made while
    /// the listener is coming up wait for that one listener. Throws once `stop()` ran (also when it ran meanwhile).
    public func start() async throws -> UInt16 {
        guard !self.stopped else {
            throw LoopbackServerError.stopped
        }
        if let port = self.port {
            return port
        }
        let starting: Task<UInt16, any Error>
        if let inFlight = self.starting {
            starting = inFlight
        } else {
            let listener = try self.makeListener()
            self.listener = listener
            let queue = self.queue
            starting = Task {
                // REENTRANCY: h-8 (proposed) — nothing: the bridge touches no actor state.
                try await LoopbackHTTPServer.ready(listener, on: queue)
            }
            self.starting = starting
        }
        do {
            // REENTRANCY: h-6 (proposed) — `stopped` is re-read: a `stop()` while the listener came up cancelled it,
            // so every waiting start fails instead of reporting a dead port. Concurrent starts await this one task,
            // so there is only ever one listener (no identity to re-check).
            let port = try await starting.value
            guard !self.stopped else {
                throw LoopbackServerError.stopped
            }
            self.port = port
            return port
        } catch {
            if self.starting == starting {
                self.starting = nil
                self.listener?.cancel()
                self.listener = nil
            }
            throw error
        }
    }

    /// A listener on 127.0.0.1, any port, loopback only, whose connections are accepted on the actor.
    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                // REENTRANCY: h-5 (proposed) — nothing: this task is not the actor; `accept` re-reads `stopped` on
                // the actor and cancels a connection that arrives after `stop()`.
                await self?.accept(connection)
            }
        }
        return listener
    }

    /// Stops the listener and every connection (stalled ones included).
    public func stop() {
        self.stopped = true
        self.listener?.cancel()
        self.listener = nil
        for connection in self.connections.values {
            connection.cancel()
        }
        self.connections.removeAll()
    }

    /// Connections accepted so far (P-10).
    public var acceptedConnections: Int {
        self.accepted
    }

    /// Requests received so far.
    public var requests: [LoopbackRequest] {
        self.log
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard !self.stopped else {
            connection.cancel()
            return
        }
        self.accepted += 1
        let number = self.accepted
        self.connections[number] = connection
        connection.start(queue: self.queue)
        Task {
            // REENTRANCY: h-5 (proposed) — nothing: `serve` re-reads `stopped` after each of its own awaits.
            await self.serve(connection, number: number)
        }
    }

    /// One connection's loop: parse every complete request in the buffer, answer it, then read more. A receive that
    /// reports the end of the client's stream (with or without bytes) is the last one: no receive completes after
    /// it, so the requests still buffered are answered and the connection is closed.
    private func serve(_ connection: NWConnection, number: Int) async {
        var buffer = Data()
        var clientFinished = false
        while !self.stopped {
            parsing: while true {
                switch self.takeRequest(from: &buffer, connection: number) {
                case .incomplete:
                    break parsing
                case .malformed:
                    // REENTRANCY: h-7 (proposed) — nothing: the connection is closed right after, whatever happened.
                    await LoopbackHTTPServer.send(LoopbackHTTPServer.badRequest, on: connection, final: true)
                    self.close(connection, number: number)
                    return
                case .request(let request):
                    self.log.append(request)
                    // REENTRANCY: h-7 (proposed) — `stopped` is re-read: after `stop()` the connection was cancelled
                    // and the loop ends; the log entry was appended before the await, so it is never lost.
                    let keepOpen = await self.respond(to: request, on: connection, number: number)
                    guard keepOpen, !self.stopped else {
                        return
                    }
                }
            }
            if clientFinished {
                self.close(connection, number: number)
                return
            }
            // REENTRANCY: h-7 (proposed) — `stopped` is re-read by the loop condition; a failed or finished receive
            // closes this connection only (its entry is removed by number, never another connection's).
            let (data, complete, failed) = await LoopbackHTTPServer.receive(connection)
            if let data {
                buffer.append(data)
            }
            if failed {
                self.close(connection, number: number)
                return
            }
            clientFinished = complete
        }
    }

    /// Answers one request; returns whether the connection stays open for the next one.
    private func respond(to request: LoopbackRequest, on connection: NWConnection, number: Int) async -> Bool {
        let response = self.handler(request)
        if response.latencyNanoseconds > 0 {
            // REENTRANCY: h-7 (proposed) — `stopped` is re-read below: a response is not sent after `stop()`.
            await self.delay.wait(nanoseconds: response.latencyNanoseconds)
            guard !self.stopped else {
                return false
            }
        }
        let (head, body) = LoopbackHTTPServer.render(response, for: request)
        switch response.ending {
        case .complete:
            let closes = response.omitContentLength || request.header("connection")?.lowercased() == "close"
            // REENTRANCY: h-7 (proposed) — nothing but `stopped` (read by the caller): the bytes are queued in order.
            await LoopbackHTTPServer.send(head + body, on: connection, final: closes)
            if closes {
                self.close(connection, number: number)
                return false
            }
            return true
        case .closeAfter(let count):
            // REENTRANCY: h-7 (proposed) — nothing: the connection is closed right after, whatever happened meanwhile.
            await LoopbackHTTPServer.send(head + body.prefix(max(0, count)), on: connection, final: true)
            self.close(connection, number: number)
            return false
        case .stallAfter(let count):
            // REENTRANCY: h-7 (proposed) — nothing: the connection stays in the table until `stop()` cancels it.
            await LoopbackHTTPServer.send(head + body.prefix(max(0, count)), on: connection, final: false)
            return false
        }
    }

    private func close(_ connection: NWConnection, number: Int) {
        connection.cancel()
        self.connections.removeValue(forKey: number)
    }

    // MARK: Parsing and rendering

    /// What the front of a connection's buffer holds.
    private enum Parsed {
        /// Not a whole request yet.
        case incomplete
        /// A request the server refuses to buffer: its `Content-Length` is not `1*DIGIT` within
        /// `maxRequestBodyBytes` (a negative or oversized length must never index the buffer).
        case malformed
        /// A whole request, removed from the buffer.
        case request(LoopbackRequest)
    }

    /// Removes and returns the first complete request (head plus `Content-Length` body).
    private func takeRequest(from buffer: inout Data, connection: Int) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var bodyLength = 0
        if let declared = headers["content-length"] {
            guard !declared.isEmpty, declared.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
                let length = Int(declared), length <= LoopbackHTTPServer.maxRequestBodyBytes
            else {
                return .malformed
            }
            bodyLength = length
        }
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= bodyLength else {
            return .incomplete
        }
        buffer = Data(buffer[buffer.index(end.upperBound, offsetBy: bodyLength)...])
        let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
        self.sequence += 1
        self.perTarget[target, default: 0] += 1
        return .request(
            LoopbackRequest(
                connection: connection,
                sequence: self.sequence,
                pathSequence: self.perTarget[target, default: 1],
                method: requestLine.first.map(String.init) ?? "",
                target: target,
                headers: headers
            )
        )
    }

    /// The answer to a request the server refuses to parse; the connection is closed after it.
    private static let badRequest = Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)

    /// The response head and the body to send (encoded, and sliced for a range). Header names merge
    /// case-insensitively: a scripted `Content-Length` (in any case) is sent as scripted, so a test can announce a
    /// length other than the body's; every other header the server sets replaces a scripted one of the same name.
    private static func render(_ response: LoopbackResponse, for request: LoopbackRequest) -> (Data, Data) {
        var status = response.status
        var body = response.encoding == .gzip ? Gzip.compress(response.body) : response.body
        var headers = response.headers
        let set = { (headers: inout [String: String], name: String, value: String) in
            for key in headers.keys where key.lowercased() == name.lowercased() {
                headers.removeValue(forKey: key)
            }
            headers[name] = value
        }
        if response.encoding == .gzip {
            set(&headers, "Content-Encoding", "gzip")
        }
        if let tag = response.rangeETag {
            set(&headers, "ETag", tag)
            set(&headers, "Accept-Ranges", "bytes")
            let ifRange = request.header("if-range")
            if status == 200, ifRange == nil || ifRange == tag, let range = request.header("range").flatMap(LoopbackHTTPServer.byteRange) {
                let total = body.count
                if range.start < total {
                    let last = min(range.end ?? (total - 1), total - 1)
                    body = body.subdata(in: range.start..<(last + 1))
                    status = 206
                    set(&headers, "Content-Range", "bytes \(range.start)-\(last)/\(total)")
                } else {
                    body = Data()
                    status = 416
                    set(&headers, "Content-Range", "bytes */\(total)")
                }
            }
        }
        if !response.omitContentLength, !headers.keys.contains(where: { $0.lowercased() == "content-length" }) {
            set(&headers, "Content-Length", String(body.count))
        }
        let closes = response.omitContentLength || request.header("connection")?.lowercased() == "close"
        set(&headers, "Connection", closes ? "close" : "keep-alive")
        var head = "HTTP/1.1 \(status) \(LoopbackHTTPServer.reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return (Data(head.utf8), body)
    }

    /// `bytes=a-` or `bytes=a-b`; `nil` for any other unit or form (the header is then ignored).
    private static func byteRange(_ header: String) -> (start: Int, end: Int?)? {
        guard header.hasPrefix("bytes=") else {
            return nil
        }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start >= 0 else {
            return nil
        }
        guard !parts[1].isEmpty else {
            return (start, nil)
        }
        guard let end = Int(parts[1]), end >= start else {
            return nil
        }
        return (start, end)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 410: return "Gone"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    // MARK: Network bridging

    /// Waits for the listener to become ready and returns its port; fails when it fails, waits or is cancelled.
    private static func ready(_ listener: NWListener, on queue: DispatchQueue) async throws -> UInt16 {
        // REENTRANCY: h-8 (proposed) — nothing: a nonisolated bridge that touches no actor state; resumed exactly once
        // by the first terminal listener state, after which the handler is removed.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    continuation.resume(throwing: LoopbackServerError.listener("\(error)"))
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: LoopbackServerError.stopped)
                case .setup:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// One receive: the bytes, whether the peer finished, whether it failed.
    private static func receive(_ connection: NWConnection) async -> (Data?, Bool, Bool) {
        // REENTRANCY: h-8 (proposed) — nothing: a nonisolated bridge; Network calls the completion exactly once.
        await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, Bool, Bool), Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete, error != nil))
            }
        }
    }

    /// Sends bytes as one complete message; `final` ends the stream with a FIN after them. (An incomplete default
    /// message would hold back every later send on another context, the final one included.)
    private static func send(_ data: Data, on connection: NWConnection, final: Bool) async {
        // REENTRANCY: h-8 (proposed) — nothing: a nonisolated bridge; Network calls the completion exactly once.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: data,
                contentContext: final ? .finalMessage : .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
    }
}

/// Why `LoopbackHTTPServer.start()` failed.
enum LoopbackServerError: Error, Sendable, Hashable {
    /// The listener failed or could not get a path.
    case listener(String)
    /// `stop()` ran before the listener was ready, or the server was stopped already.
    case stopped
}

/// RFC 1952 gzip framing around raw DEFLATE, plus CRC-32 (the gzip scenario of SPEC §7.3).
public enum Gzip {
    /// Compresses `data`.
    public static func compress(_ data: Data) -> Data {
        let deflated: Data
        if data.isEmpty {
            deflated = Data([0x03, 0x00])  // the canonical empty final block
        } else {
            deflated = (try? (data as NSData).compressed(using: .zlib) as Data) ?? Gzip.storedDeflate(data)
        }
        return Gzip.frame(deflated, original: data)
    }

    /// The CRC-32 of `data`.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = Gzip.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The member around raw DEFLATE bytes: header (no name, no mtime: nothing clock-dependent), payload, CRC-32
    /// and size, little-endian.
    static func frame(_ deflated: Data, original: Data) -> Data {
        var framed = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        framed.append(deflated)
        Gzip.appendLittleEndian(&framed, Gzip.crc32(original))
        Gzip.appendLittleEndian(&framed, UInt32(truncatingIfNeeded: original.count))
        return framed
    }

    /// RFC 1951 stored blocks: a valid DEFLATE stream that needs no compressor (the fallback if the system's fails).
    static func storedDeflate(_ data: Data) -> Data {
        var out = Data()
        var offset = data.startIndex
        repeat {
            let length = min(65_535, data.endIndex - offset)
            let last = offset + length == data.endIndex
            out.append(last ? 0x01 : 0x00)
            out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)])
            out.append(data[offset..<(offset + length)])
            offset += length
        } while offset < data.endIndex
        return out
    }

    private static func appendLittleEndian(_ out: inout Data, _ value: UInt32) {
        out.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}
