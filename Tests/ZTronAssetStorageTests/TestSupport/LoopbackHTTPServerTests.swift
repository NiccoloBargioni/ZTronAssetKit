import Foundation
import Network
import Synchronization
import Testing
@testable import ZTronAssetTestSupport

/// The loopback server's behaviours (ADR-011, ARCHITECTURE §6.7): scripted responses, connection counting, ranges,
/// gzip, FIN truncation, stalls, close-delimited bodies and injected latency. One server per test, ephemeral port.
@Suite("Test support: LoopbackHTTPServer")
struct TestSupportLoopbackHTTPServerTests {
    /// Runs `body` against a started server and always stops it afterwards.
    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
    private static func connect(_ port: UInt16) async throws -> LoopbackRawClient {
        let client = LoopbackRawClient(port: port)
        try await client.open()
        return client
    }

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    /// A `Data` slice keeps its parent's indices: a range indexes the body relative to its start (a zero-based index
    /// into a slice whose `startIndex` is not 0 traps inside the server actor and ends the test process).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a range request against a body that is a Data slice gets the slice's bytes", .timeLimit(.minutes(1)))
    func rangeOverSlicedBody() async throws {
        let parent = Data((0..<20).map { UInt8($0) })
        let body = parent.dropFirst(10)
        #expect(body.startIndex == 10)
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: body, rangeETag: "\"v1\"")
        }) { _, port in
            let client = try await Self.connect(port)
            try await client.get("/r", headers: ["Range": "bytes=2-"])
            let tail = try await client.response()
            #expect(tail.status == 206 && tail.body == Data((12..<20).map { UInt8($0) }))
            #expect(tail.headers["content-range"] == "bytes 2-9/10")

            try await client.get("/r", headers: ["Range": "bytes=0-3"])
            let head = try await client.response()
            #expect(head.status == 206 && head.body == Data([10, 11, 12, 13]))
            #expect(head.headers["content-range"] == "bytes 0-3/10")

            try await client.get("/r")
            let whole = try await client.response()
            #expect(whole.status == 200 && whole.body == Data((10..<20).map { UInt8($0) }))
            client.close()
        }
    }

    /// The default delay is `NoLoopbackDelay`: a server built without one answers at once whatever latency is
    /// scripted, so a correctness test can never sleep by accident (a sleeping default would hit the time limit).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a server with the default delay answers a response scripted with an hour of latency at once", .timeLimit(.minutes(1)))
    func defaultDelayNeverSleeps() async throws {
        let hour: UInt64 = 3_600 * 1_000_000_000
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: Data([7]), latencyNanoseconds: hour)
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.get("/slow")
            let response = try await client.response()
            #expect(response.status == 200 && response.body == Data([7]))
            #expect(await server.requests.map(\.target) == ["/slow"])
            client.close()
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: scripted latency is awaited through the injected delay, and a response without latency awaits nothing", .timeLimit(.minutes(1)))
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @available(macOS 15.0, iOS 18.0, *)
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

    @Test("Test support: concurrent starts share one listener and report the same port", .timeLimit(.minutes(1)))
    func concurrentStartsShareOneListener() async throws {
        for round in 0..<5 {
            let server = LoopbackHTTPServer { _ in LoopbackResponse(status: 204) }
            async let first = server.start()
            async let second = server.start()
            let ports = try await [first, second]
            #expect(ports[0] == ports[1], "round \(round)")
            #expect(try await server.start() == ports[0], "round \(round)")
            await server.stop()
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "Test support: a request whose Content-Length is not a bounded digit string gets 400 and the connection is closed",
        .timeLimit(.minutes(1)),
        arguments: ["-1000", "abc", "+5", "99999999999999999999", "67108865"]
    )
    func malformedContentLengthIsRejected(length: String) async throws {
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: Data("handled".utf8))
        }) { server, port in
            let client = try await Self.connect(port)
            try await client.send("GET /a HTTP/1.1\r\nHost: x\r\nContent-Length: \(length)\r\n\r\n")
            let response = try await client.response()
            #expect(response.status == 400)
            #expect(response.headers["connection"] == "close")
            let (rest, cleanClose) = await client.untilClosed()
            #expect(rest.isEmpty && cleanClose)
            #expect(await server.requests.isEmpty)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a scripted Content-Length wins whatever its case, and the server's Connection header replaces a scripted one", .timeLimit(.minutes(1)))
    func scriptedHeadersMergeCaseInsensitively() async throws {
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, headers: ["content-length": "3", "CONNECTION": "keep-alive"], body: Data("abcdef".utf8))
        }) { _, port in
            let client = try await Self.connect(port)
            try await client.get("/announced", headers: ["Connection": "close"])
            let (raw, _) = await client.untilClosed()
            let split = try #require(raw.range(of: Data("\r\n\r\n".utf8)))
            let lines = String(decoding: raw[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").dropFirst()
            let lengths = lines.filter { $0.lowercased().hasPrefix("content-length:") }
            let connections = lines.filter { $0.lowercased().hasPrefix("connection:") }
            #expect(lengths == ["content-length: 3"])
            #expect(connections == ["Connection: close"])
        }
    }

    /// Whether `stop()` lands before, during or after the listener comes up is Network's choice, so the property is
    /// the invariant, over many races: each `start()` ends exactly once (no continuation misuse trap, no hang), with
    /// a port or with `.stopped`, and the stopped server never starts again. The stop is spread over the listener's
    /// start-up by a growing number of `Task.yield()`s (scheduling points, not sleeps), so both outcomes occur, but
    /// the test does not count them: their mix depends on the machine.
    @Test("Test support: start racing stop ends every start exactly once, with a port or stopped, and never hangs", .timeLimit(.minutes(1)))
    func startRacingStop() async throws {
        for round in 0..<400 {
            let server = LoopbackHTTPServer { _ in LoopbackResponse(status: 204) }
            let starts = (0..<2).map { _ in Task { try await server.start() } }
            let stopping = Task {
                for _ in 0..<round {
                    await Task.yield()
                }
                await server.stop()
            }
            await stopping.value
            for start in starts {
                switch await start.result {
                case .success(let port):
                    #expect(port > 0, "round \(round)")
                case .failure(let error):
                    #expect(error as? LoopbackServerError == .stopped, "round \(round): \(error)")
                }
            }
            await #expect(throws: LoopbackServerError.stopped, "round \(round)") { try await server.start() }
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a request head that grows past its cap without a blank line gets 431 and the connection is closed", .timeLimit(.minutes(1)))
    func oversizedHeadIsRejected() async throws {
        try await Self.withServer({ _ in
            LoopbackResponse(status: 200, body: Data("handled".utf8))
        }) { server, port in
            let client = try await Self.connect(port)
            let prefix = Data("GET /a HTTP/1.1\r\nX-Filler: ".utf8)
            // Exactly one byte past the cap, so the server has read everything when it refuses (no unread bytes, no RST).
            let filler = Data(repeating: UInt8(ascii: "a"), count: LoopbackHTTPServer.maxRequestHeadBytes + 1 - prefix.count)
            try await client.send(prefix + filler)
            let response = try await client.response()
            #expect(response.status == 431)
            #expect(response.headers["connection"] == "close")
            let (rest, cleanClose) = await client.untilClosed()
            #expect(rest.isEmpty && cleanClose)
            #expect(await server.requests.isEmpty)
        }
    }

    /// A caller cancelled while the listener comes up (a `.timeLimit`, a cancelled test task) must not stay suspended
    /// until Network reports a state. The listener's states are held, so only the cancellation can end that start;
    /// once they are released, the same listener serves a later start.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a start cancelled while the listener comes up throws CancellationError, and a later start gets the port", .timeLimit(.minutes(1)))
    func cancelledStartEnds() async throws {
        let server = LoopbackHTTPServer { _ in LoopbackResponse(status: 204) }
        await server.holdListenerStates()
        let start = Task { try await server.start() }
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        await server.releaseListenerStates()
        let port = try await server.start()
        #expect(await server.listenerGeneration == 1)
        let client = try await Self.connect(port)
        try await client.get("/after")
        #expect(try await client.response().status == 204)
        client.close()
        await server.stop()
    }

    /// Network can report `.failed` for a listener that was ready. `start()` must then not keep returning the dead
    /// port: the failed listener is dropped, and the next start makes a new one whose port serves.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a listener that fails after it was ready is replaced at the next start, whose port serves", .timeLimit(.minutes(1)))
    func failedAfterReadyIsReplaced() async throws {
        let server = LoopbackHTTPServer { _ in LoopbackResponse(status: 204) }
        _ = try await server.start()
        let generation = await server.listenerGeneration
        await server.listenerStateChanged(.failed(.posix(.ECONNABORTED)), generation: generation)
        let port = try await server.start()
        #expect(await server.listenerGeneration == generation + 1)
        let client = try await Self.connect(port)
        try await client.get("/after")
        #expect(try await client.response().status == 204)
        client.close()
        await server.stop()
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

    /// The configuration that keeps the server loopback-only, pinned: bound to 127.0.0.1 on the loopback interface,
    /// and without `acceptLocalOnly`, which the iOS Simulator enforces by resetting 127.0.0.1 connections (ios.md item 3).
    @Test("Test support: the listener is bound to 127.0.0.1 on the loopback interface and does not set acceptLocalOnly")
    func listenerIsLoopbackOnly() {
        let parameters = LoopbackHTTPServer.listenerParameters()
        #expect(parameters.requiredLocalEndpoint == NWEndpoint.hostPort(host: "127.0.0.1", port: .any))
        #expect(parameters.requiredInterfaceType == .loopback)
        #expect(parameters.acceptLocalOnly == false)
    }

    /// The bound address in behaviour: the same port on another local address (`::1`) has nothing listening, so the
    /// kernel refuses the connection, while 127.0.0.1 is served. A listener on every address would accept both.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: a connection to the server's port on ::1 is refused and never reaches the server", .timeLimit(.minutes(1)))
    func otherLocalAddressIsRefused() async throws {
        try await Self.withServer({ _ in LoopbackResponse(status: 204) }) { server, port in
            let stranger = LoopbackRawClient(host: "::1", port: port)
            let error = await #expect(throws: LoopbackRawClient.ClientError.self) {
                try await stranger.open()
            }
            stranger.close()
            if case .notReady(let reason) = error {
                #expect(reason.contains("Connection refused"), "\(reason)")
            } else {
                Issue.record("expected a refused connection, got \(String(describing: error))")
            }
            #expect(await server.acceptedConnections == 0)
            let client = try await Self.connect(port)
            try await client.get("/")
            #expect(try await client.response().status == 204)
            client.close()
            #expect(await server.acceptedConnections == 1, "only the 127.0.0.1 client reached the server")
        }
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
@available(macOS 15.0, iOS 18.0, *)
final class LoopbackRecordingDelay: LoopbackDelay {
    private let recorded = Mutex<[UInt64]>([])

    var waits: [UInt64] {
        self.recorded.withLock { $0 }
    }

    func wait(nanoseconds: UInt64) async {
        self.recorded.withLock { $0.append(nanoseconds) }
    }
}
