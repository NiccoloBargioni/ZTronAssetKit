import Foundation
import Synchronization
import Testing
@testable import ZTronAssetTestSupport

/// The loopback server's behaviours (ADR-011, ARCHITECTURE §6.7): scripted responses, connection counting, ranges,
/// gzip, FIN truncation, stalls, close-delimited bodies and injected latency. One server per test, ephemeral port.
@Suite("Test support: LoopbackHTTPServer")
struct TestSupportLoopbackHTTPServerTests {
    /// Runs `body` against a started server and always stops it afterwards.
    @available(macOS 15.0, *)
    private static func withServer(
        delay: any LoopbackDelay = NoLoopbackDelay(),
        _ handler: @escaping LoopbackHandler,
        _ body: (LoopbackHTTPServer, UInt16) async throws -> Void
    ) async throws {
        let server = LoopbackHTTPServer(delay: delay, handler: handler)
        let port = try await server.start()
        do {
            try await body(server, port)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @available(macOS 15.0, *)
    private static func connect(_ port: UInt16) async throws -> LoopbackRawClient {
        let client = LoopbackRawClient(port: port)
        try await client.open()
        return client
    }

    @available(macOS 15.0, *)
    @Test("Test support: a scripted response is served verbatim and the request is recorded with lowercased headers", .timeLimit(.minutes(1)))
    func servesScriptedResponse() async throws {
        try await Self.withServer({ request in
            LoopbackResponse(status: 302, headers: ["Location": "https://other.example/a.png", "X-Trace": request.target], body: Data("moved".utf8))
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.get("/media/a.png?x=1", headers: ["X-App-Key": "canary"])
            let response = try await client.response()
            #expect(response.status == 302)
            #expect(response.headers["location"] == "https://other.example/a.png")
            #expect(response.headers["x-trace"] == "/media/a.png?x=1")
            #expect(response.headers["content-length"] == "5")
            #expect(response.body == Data("moved".utf8))
            let request = try #require(await server.requests.first)
            #expect(request.method == "GET")
            #expect(request.target == "/media/a.png?x=1")
            #expect(request.header("X-APP-KEY") == "canary")
            #expect(request.headers["x-app-key"] == "canary")
            client.close()
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: keep-alive requests share one counted connection and a second client is a second connection", .timeLimit(.minutes(1)))
    func countsConnections() async throws {
        try await Self.withServer({ request in
            LoopbackResponse(status: request.pathSequence == 1 ? 503 : 200, body: Data([UInt8(request.sequence)]))
        }) { server, port in
            let first = try await Self.connect(port)
            try await first.get("/a")
            #expect(try await first.response().status == 503)
            try await first.get("/a")
            #expect(try await first.response().status == 200)
            let second = try await Self.connect(port)
            try await second.get("/b")
            #expect(try await second.response().body == Data([3]))
            #expect(await server.acceptedConnections == 2)
            let requests = await server.requests
            #expect(requests.map(\.connection) == [1, 1, 2])
            #expect(requests.map(\.sequence) == [1, 2, 3])
            #expect(requests.map(\.pathSequence) == [1, 2, 1])
            first.close()
            second.close()
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: closeAfter sends the head and the first body bytes, then a FIN", .timeLimit(.minutes(1)))
    func closeAfterIsAFin() async throws {
        let body = Data((0..<100).map { UInt8($0) })
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: body, ending: .closeAfter(bodyBytes: 10))
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.get("/big.bin")
            let (data, cleanClose) = await client.untilClosed()
            let split = try #require(data.range(of: Data("\r\n\r\n".utf8)))
            let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
            #expect(head.contains("Content-Length: 100"))
            #expect(data[split.upperBound...] == body.prefix(10))
            #expect(cleanClose)
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: stallAfter holds the connection mid-body until stop closes it", .timeLimit(.minutes(1)))
    func stallUntilStop() async throws {
        let body = Data(repeating: 7, count: 50)
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: body, ending: .stallAfter(bodyBytes: 20))
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.get("/stall.bin")
            let partial = try await client.response(bodyPrefix: 20)
            #expect(partial.headers["content-length"] == "50")
            #expect(partial.body == body.prefix(20))
            #expect(await server.requests.count == 1)
            await server.stop()
            await server.stop()
            let (rest, _) = await client.untilClosed()
            #expect(rest.isEmpty)
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: a matching If-Range yields 206 with the tail, a stale one the whole body, an unsatisfiable range 416", .timeLimit(.minutes(1)))
    func rangesAndIfRange() async throws {
        let body = Data((0..<10).map { UInt8($0) })
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: body, rangeETag: "\"v1\"")
        }) { _, port in
            let client = try await Self.connect(port)

            try await client.get("/r")
            let whole = try await client.response()
            #expect(whole.status == 200 && whole.body == body)
            #expect(whole.headers["etag"] == "\"v1\"" && whole.headers["accept-ranges"] == "bytes")

            try await client.get("/r", headers: ["Range": "bytes=4-", "If-Range": "\"v1\""])
            let tail = try await client.response()
            #expect(tail.status == 206 && tail.body == body.suffix(6))
            #expect(tail.headers["content-range"] == "bytes 4-9/10")

            try await client.get("/r", headers: ["Range": "bytes=2-5"])
            let middle = try await client.response()
            #expect(middle.status == 206 && middle.body == body[2...5])
            #expect(middle.headers["content-range"] == "bytes 2-5/10")

            try await client.get("/r", headers: ["Range": "bytes=4-", "If-Range": "\"v0\""])
            let stale = try await client.response()
            #expect(stale.status == 200 && stale.body == body)

            try await client.get("/r", headers: ["Range": "bytes=20-", "If-Range": "\"v1\""])
            let unsatisfiable = try await client.response()
            #expect(unsatisfiable.status == 416 && unsatisfiable.body.isEmpty)
            #expect(unsatisfiable.headers["content-range"] == "bytes */10")

            try await client.get("/r", headers: ["Range": "items=1-2"])
            #expect(try await client.response().status == 200)
            client.close()
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: a gzip response carries Content-Encoding and a body that inflates to the decoded bytes", .timeLimit(.minutes(1)))
    func gzipEncoding() async throws {
        let decoded = Data(String(repeating: "ZTronAssetKit ", count: 400).utf8)
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: decoded, encoding: .gzip)
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.get("/catalog.json")
            let response = try await client.response()
            #expect(response.headers["content-encoding"] == "gzip")
            #expect(response.body.count < decoded.count)
            #expect(response.headers["content-length"] == String(response.body.count))
            #expect(try Self.gunzip(response.body) == decoded)
            client.close()
        }
    }

    @Test("Test support: Gzip frames raw DEFLATE per RFC 1952 with the standard CRC-32")
    func gzipFraming() throws {
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(Gzip.crc32(Data()) == 0)
        let original = Data("hello, hello, hello".utf8)
        let framed = Gzip.compress(original)
        #expect(Array(framed.prefix(4)) == [0x1F, 0x8B, 0x08, 0x00])
        #expect(try Self.gunzip(framed) == original)
        #expect(try Self.gunzip(Gzip.compress(Data())) == Data())
    }

    @Test("Test support: Gzip's stored-block fallback is a valid DEFLATE stream for empty, small and multi-block inputs", arguments: [0, 5, 70_000])
    func storedBlocksInflate(size: Int) throws {
        let original = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let stored = Gzip.storedDeflate(original)
        #expect(stored.count == original.count + 5 * max(1, (original.count + 65_534) / 65_535))
        #expect(try Self.gunzip(Gzip.frame(stored, original: original)) == original)
    }

    @available(macOS 15.0, *)
    @Test("Test support: a close-delimited body has no Content-Length and ends with the connection", .timeLimit(.minutes(1)))
    func closeDelimitedBody() async throws {
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: Data("abcdef".utf8), omitContentLength: true)
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.get("/stream")
            let response = try await client.response()
            #expect(response.headers["content-length"] == nil)
            #expect(response.headers["connection"] == "close")
            #expect(response.body == Data("abcdef".utf8))
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: Connection close is honoured and a request body is consumed before the next request", .timeLimit(.minutes(1)))
    func connectionCloseAndRequestBodies() async throws {
        try await Self.withServer({ request in
            LoopbackResponse(status: 200, body: Data(request.method.utf8))
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.send("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc")
            #expect(try await client.response().body == Data("POST".utf8))
            try await client.get("/next", headers: ["Connection": "close"])
            let response = try await client.response()
            #expect(response.body == Data("GET".utf8))
            #expect(response.headers["connection"] == "close")
            let (rest, cleanClose) = await client.untilClosed()
            #expect(rest.isEmpty && cleanClose)
            #expect(await server.requests.map(\.target) == ["/upload", "/next"])
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: scripted latency is awaited through the injected delay and never sleeps by default", .timeLimit(.minutes(1)))
    func latencyGoesThroughTheDelay() async throws {
        let delay = LoopbackRecordingDelay()
        try await Self.withServer(delay: delay, { request in
            LoopbackResponse(status: 200, body: Data([1]), latencyNanoseconds: request.target == "/slow" ? 5_000_000 : 0)
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.get("/slow")
            #expect(try await client.response().status == 200)
            try await client.get("/fast")
            #expect(try await client.response().status == 200)
            #expect(delay.waits == [5_000_000])
                client.close()
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: a request body split across segments is awaited and a header line without a colon is skipped", .timeLimit(.minutes(1)))
    func splitRequestBody() async throws {
        try await Self.withServer({ request in
            LoopbackResponse(status: 200, body: Data((request.header("x-kind") ?? "none").utf8))
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.send("PUT /a HTTP/1.1\r\nNoColonHere\r\nX-Kind: split\r\nContent-Length: 4\r\n\r\nab")
            try await client.send("cd")
            #expect(try await client.response().body == Data("split".utf8))
            #expect(await server.requests.map(\.method) == ["PUT"])
            client.close()
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: a request followed by the client's FIN is answered before the server closes", .timeLimit(.minutes(1)))
    func clientFinishedIsAnswered() async throws {
        try await Self.withServer({ _ in
            LoopbackResponse(status: 204)
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.sendFinal("GET /last HTTP/1.1\r\nHost: x\r\n\r\n")
            let response = try await client.response()
            #expect(response.status == 204)
            let (rest, cleanClose) = await client.untilClosed()
            #expect(rest.isEmpty && cleanClose)
            #expect(await server.requests.map(\.target) == ["/last"])
        }
    }

    @available(macOS 15.0, *)
    @Test("Test support: malformed or reversed byte ranges are ignored and the whole body is sent", .timeLimit(.minutes(1)))
    func malformedRangesAreIgnored() async throws {
        let body = Data((0..<10).map { UInt8($0) })
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: body, rangeETag: "\"v1\"")
        }) { _, port in
            let client = try await Self.connect(port)
            for range in ["bytes=x-", "bytes=5-2", "bytes=-3", "bytes=1-y"] {
                try await client.get("/r", headers: ["Range": range])
                let response = try await client.response()
                #expect(response.status == 200 && response.body == body, "\(range)")
            }
            client.close()
        }
    }

    @Test("Test support: start is idempotent while running and a stopped server cannot start again", .timeLimit(.minutes(1)))
    func startAndStopLifecycle() async throws {
        let server = LoopbackHTTPServer { _ in LoopbackResponse(status: 200) }
        let port = try await server.start()
        #expect(try await server.start() == port)
        #expect(await server.acceptedConnections == 0)
        await server.stop()
        await #expect(throws: LoopbackServerError.stopped) { try await server.start() }
        let never = LoopbackHTTPServer { _ in LoopbackResponse(status: 200) }
        await never.stop()
        await #expect(throws: LoopbackServerError.stopped) { try await never.start() }
    }

    /// Inflates an RFC 1952 member: checks the header, the CRC-32 and the size trailer.
    static func gunzip(_ framed: Data) throws -> Data {
        let bytes = [UInt8](framed)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
            throw CocoaError(.coderReadCorrupt)
        }
        let deflated = Data(bytes[10..<(bytes.count - 8)])
        let inflated = deflated.isEmpty ? Data() : try (deflated as NSData).decompressed(using: .zlib) as Data
        let trailer = Array(bytes.suffix(8))
        let crc = trailer[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let size = trailer[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        guard crc == Gzip.crc32(inflated), size == UInt32(truncatingIfNeeded: inflated.count) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return inflated
    }
}

/// A delay that records what it was asked to wait and returns at once.
@available(macOS 15.0, *)
final class LoopbackRecordingDelay: LoopbackDelay {
    private let recorded = Mutex<[UInt64]>([])

    var waits: [UInt64] {
        self.recorded.withLock { $0 }
    }

    func wait(nanoseconds: UInt64) async {
        self.recorded.withLock { $0.append(nanoseconds) }
    }
}
