import Foundation
import Network
import Synchronization

/// A minimal raw HTTP/1.1 client over `NWConnection` (loopback only), so the server's tests see exactly the bytes
/// and the connection close it sends: no URLSession, no cache, nothing written anywhere. Gated for `Mutex`.
@available(macOS 15.0, *)
final class LoopbackRawClient: Sendable {
    /// One parsed response.
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    enum ClientError: Error {
        case notReady(String)
        case malformed
    }

    private let connection: NWConnection
    private let buffer = LoopbackRawClientBuffer()

    init(port: UInt16) {
        self.connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    /// Connects; throws when the connection fails or has to wait for a path.
    func open() async throws {
        let (states, continuation) = AsyncStream.makeStream(of: NWConnection.State.self)
        self.connection.stateUpdateHandler = { state in
            continuation.yield(state)
        }
        self.connection.start(queue: DispatchQueue(label: "com.ztron.assetkit.tests.loopback-client"))
        for await state in states {
            if Task.isCancelled {
                self.connection.cancel()
                throw CancellationError()
            }
            switch state {
            case .ready:
                return
            case .failed(let error), .waiting(let error):
                throw ClientError.notReady("\(error)")
            default:
                continue
            }
        }
    }

    /// Sends a raw request.
    func send(_ text: String) async throws {
        try await self.send(Data(text.utf8))
    }

    /// Sends raw bytes.
    func send(_ data: Data) async throws {
        let error: NWError? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.connection.send(content: data, completion: .contentProcessed { continuation.resume(returning: $0) })
            }
        } onCancel: {
            self.connection.cancel()
        }
        if let error {
            throw error
        }
    }

    /// Sends raw bytes and then the end of the client's stream (a FIN).
    func sendFinal(_ text: String) async throws {
        let error: NWError? = await withCheckedContinuation { continuation in
            self.connection.send(
                content: Data(text.utf8),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { continuation.resume(returning: $0) }
            )
        }
        if let error {
            throw error
        }
    }

    /// A GET with optional extra headers.
    func get(_ target: String, headers: [String: String] = [:]) async throws {
        var text = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        try await self.send(text + "\r\n")
    }

    /// Reads one response's head and exactly `count` body bytes (a stalled or truncated response).
    func response(bodyPrefix count: Int) async throws -> Response {
        while self.buffer.headEnd() == nil {
            guard try await self.receiveMore() else {
                throw ClientError.malformed
            }
        }
        let (status, headers) = try self.buffer.takeHead()
        while self.buffer.count < count {
            guard try await self.receiveMore() else {
                throw ClientError.malformed
            }
        }
        return Response(status: status, headers: headers, body: self.buffer.take(count))
    }

    /// Reads one response: the head, then `Content-Length` bytes, or everything until the server closes.
    func response() async throws -> Response {
        while self.buffer.headEnd() == nil {
            guard try await self.receiveMore() else {
                throw ClientError.malformed
            }
        }
        let (status, headers) = try self.buffer.takeHead()
        if let length = headers["content-length"].flatMap(Int.init) {
            while self.buffer.count < length {
                guard try await self.receiveMore() else {
                    break
                }
            }
            return Response(status: status, headers: headers, body: self.buffer.take(length))
        }
        while try await self.receiveMore() {}
        return Response(status: status, headers: headers, body: self.buffer.take(self.buffer.count))
    }

    /// Reads until the server ends the connection; returns what arrived and whether it ended with a FIN (no error).
    func untilClosed() async -> (data: Data, cleanClose: Bool) {
        do {
            while try await self.receiveMore() {}
            return (self.buffer.take(self.buffer.count), true)
        } catch {
            return (self.buffer.take(self.buffer.count), false)
        }
    }

    /// Closes the client side.
    func close() {
        self.connection.cancel()
    }

    /// One receive; `false` once the server closed the stream. No receive completes after the one that reported the
    /// end of the stream (even when it also carried bytes), so that end is remembered.
    private func receiveMore() async throws -> Bool {
        guard !self.buffer.peerClosed else {
            return false
        }
        // A cancelled test (its time limit) cancels the connection, which completes the pending receive.
        let (data, complete, error): (Data?, Bool, NWError?) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    continuation.resume(returning: (data, complete, error))
                }
            }
        } onCancel: {
            self.connection.cancel()
        }
        if let data {
            self.buffer.append(data)
        }
        if let error {
            throw error
        }
        if complete {
            self.buffer.markPeerClosed()
        }
        return !complete || !(data?.isEmpty ?? true)
    }
}

/// The client's receive buffer (one connection, one reader at a time).
@available(macOS 15.0, *)
private final class LoopbackRawClientBuffer: Sendable {
    private let data = Mutex(Data())
    private let closed = Mutex(false)

    var peerClosed: Bool {
        self.closed.withLock { $0 }
    }

    func markPeerClosed() {
        self.closed.withLock { $0 = true }
    }

    var count: Int {
        self.data.withLock { $0.count }
    }

    func append(_ more: Data) {
        self.data.withLock { $0.append(more) }
    }

    func headEnd() -> Range<Data.Index>? {
        self.data.withLock { $0.range(of: Data("\r\n\r\n".utf8)) }
    }

    func take(_ count: Int) -> Data {
        self.data.withLock { data in
            let taken = Data(data.prefix(count))
            data = Data(data.dropFirst(count))
            return taken
        }
    }

    func takeHead() throws -> (Int, [String: String]) {
        let head: String? = self.data.withLock { data in
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                return nil
            }
            let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
            data = Data(data[end.upperBound...])
            return head
        }
        guard let head else {
            throw LoopbackRawClient.ClientError.malformed
        }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else {
            throw LoopbackRawClient.ClientError.malformed
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers)
    }
}
