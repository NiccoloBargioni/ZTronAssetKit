import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// Values and builders shared by the transport suites.
enum TransportFixtures {
    /// A key whose value is searched for in every output (R-SEC-1).
    static let canaryKey = AppKey("CANARY-transport-7f3a9c")
    /// The canary's value, for header assertions.
    static let canaryValue = "CANARY-transport-7f3a9c"

    /// A checksummed content identity (resumable).
    static func contentID(_ seed: UInt8) -> TransferID {
        .content(ContentHash.sha256(of: Data([seed, 0x5a])))
    }

    /// A checksum-less identity (never resumed, transport-1 TR1-3).
    static let legacyID = TransferID.legacy(identifier: "legacy-asset", remotePath: "media/legacy.png")

    /// Attempt `sequence` of launch `epoch`.
    static func attempt(_ sequence: UInt32, epoch: UInt64 = 1) -> TransferAttempt {
        TransferAttempt(epoch: epoch, sequence: sequence)
    }

    /// Deterministic bytes.
    static func payload(_ count: Int, seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// A per-test directory inside this repository (never the system temp directory, owner directive).
    static func directory(_ name: String) throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-transport-fixtures", isDirectory: true)
            .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A job for direct backend tests.
    static func job(
        id: TransferID,
        attempt: TransferAttempt,
        url: URL,
        purpose: TransferPurpose = .asset,
        ifNoneMatch: ETag? = nil,
        expected: Int64?,
        maxBytes: Int64 = 1 << 30,
        priority: AssetPriority = .prefetch,
        resume: ResumePoint? = nil
    ) -> TransferJob {
        TransferJob(
            id: id,
            attempt: attempt,
            url: url,
            purpose: purpose,
            ifNoneMatch: ifNoneMatch,
            expectedBytes: expected,
            maxBytes: maxBytes,
            priority: priority,
            resume: resume
        )
    }
}

/// The first terminal element of a handle's stream, and the progress seen before it.
struct TransferRun: Sendable {
    var progress: [Int64] = []
    var terminal: TransferUpdate?
}

/// Consumes `handle.updates` to its end.
func run(_ handle: any TransferHandle) async -> TransferRun {
    var run = TransferRun()
    for await update in handle.updates {
        switch update {
        case .progress(let received, _):
            run.progress.append(received)
        default:
            run.terminal = update
        }
    }
    return run
}

/// A loopback server, a `FakeStagingSink` and an `HTTPRemoteSource` over the real foreground backend with the
/// package-only loopback policy (ADR-011). One rig per test: an ephemeral port, so tests run in parallel.
@available(macOS 15.0, iOS 18.0, *)
struct LoopbackRig {
    let server: LoopbackHTTPServer
    let port: UInt16
    let staging: FakeStagingSink
    let source: HTTPRemoteSource
    let foreground: ForegroundTransferBackend
    let tap: RecordingLogTap
    let base: URL

    static func make(
        appKey: AppKey? = TransportFixtures.canaryKey,
        allowedHosts: Set<String> = ["127.0.0.1"],
        maxConnections: Int = 6,
        manifestPath: String = "manifest.json",
        background: (any TransferBackend)? = nil,
        staging: FakeStagingSink = FakeStagingSink(),
        sink: (any StagingSink)? = nil,
        handler: @escaping LoopbackHandler
    ) async throws -> LoopbackRig {
        // The delegate and the source write through `sink` when one is given (a wrapper over `staging`).
        let sink = sink ?? staging
        let server = LoopbackHTTPServer(handler: handler)
        let port = try await server.start()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        let tap = RecordingLogTap()
        let log = LogRoute.tapOnly(tap)
        let policy = TransportSecurityPolicy.loopbackTesting(allowedHosts: allowedHosts)
        let delegate = SessionDelegate(mode: .foreground, staging: sink, policy: policy)
        // A short request timeout: a missed event fails long before the test's time limit (transport.md §12).
        let foreground = ForegroundTransferBackend(
            delegate: delegate,
            maxConnectionsPerHost: maxConnections,
            requestTimeout: 10,
            appKey: appKey,
            log: log
        )
        let configuration = HTTPSourceConfiguration(
            baseURL: base,
            manifestPath: manifestPath,
            appKey: appKey,
            maxConnectionsPerHost: maxConnections,
            requestTimeout: 10
        )
        let source = HTTPRemoteSource(
            configuration: configuration,
            staging: sink,
            policy: policy,
            foreground: foreground,
            background: background,
            log: log
        )
        return LoopbackRig(server: server, port: port, staging: staging, source: source, foreground: foreground, tap: tap, base: base)
    }

    /// An asset request for `path`.
    func request(
        _ id: TransferID,
        attempt: TransferAttempt = TransportFixtures.attempt(1),
        path: String,
        expected: Int64?,
        maxBytes: Int64 = 1 << 30,
        priority: AssetPriority = .prefetch,
        route: TransferRoute = .foreground,
        resume: ResumePoint? = nil
    ) -> TransferRequest {
        TransferRequest(
            id: id,
            attempt: attempt,
            remotePath: path,
            expectedBytes: expected,
            maxBytes: maxBytes,
            priority: priority,
            route: route,
            resume: resume
        )
    }

    /// Invalidates the source (waiting for the delegate's last callback) and stops the server.
    func stop() async {
        await self.source.invalidate()
        await self.server.stop()
    }

    /// The requests the server received for `target`.
    func requests(to target: String) async -> [LoopbackRequest] {
        await self.server.requests.filter { $0.target == target }
    }
}

/// The `transfer` interval edges a tap recorded (R-OBS-1): every began edge must have exactly one ended edge.
@available(macOS 15.0, iOS 18.0, *)
func transferIntervalEdges(_ tap: RecordingLogTap) -> (began: Int, ended: Int) {
    let events = tap.lines.compactMap(LogIntervalEvent.init(line:)).filter { $0.name == .transfer }
    return (events.filter { $0.phase == .began }.count, events.filter { $0.phase == .ended }.count)
}

/// A one-shot signal a loopback handler fires when a request arrives, awaited without polling.
struct Arrivals: Sendable {
    let stream: AsyncStream<String>
    let continuation: AsyncStream<String>.Continuation

    init() {
        (self.stream, self.continuation) = AsyncStream.makeStream(of: String.self)
    }

    /// Records the arrival of `target` (called from the handler).
    func signal(_ target: String) {
        self.continuation.yield(target)
    }

    /// Waits for the next arrival.
    func next() async -> String? {
        for await target in self.stream {
            return target
        }
        return nil
    }
}

/// Reads updates until the received byte count reaches `bytes` (a stalled transfer's known point), returning the
/// iterator so the caller can read the terminal afterwards.
func awaitProgress(
    _ iterator: inout AsyncStream<TransferUpdate>.AsyncIterator,
    reaching bytes: Int64
) async -> Bool {
    while let update = await iterator.next() {
        if case .progress(let received, _) = update, received >= bytes {
            return true
        }
        if update.isTerminal {
            return false
        }
    }
    return false
}

/// A staging sink whose `discard` waits for `release()`; everything else goes straight to `base`. It holds a
/// foreground handle's `cancel()` between its synchronous mark and the task's cancellation, so that window can be
/// observed deterministically.
@available(macOS 15.0, iOS 18.0, *)
final class HeldDiscardSink: StagingSink {
    let base: FakeStagingSink
    private let gate = DiscardGate()

    init(base: FakeStagingSink) {
        self.base = base
    }

    func createPartial(_ name: StagingFileName) throws(StagingError) {
        try self.base.createPartial(name)
    }

    func appendPartial(_ data: Data, to name: StagingFileName) throws(StagingError) -> Int64 {
        try self.base.appendPartial(data, to: name)
    }

    func continuePartial(from previous: StagingFileName, as next: StagingFileName) throws(StagingError) -> Int64 {
        try self.base.continuePartial(from: previous, as: next)
    }

    func adoptDownload(at location: URL, as name: StagingFileName) throws(StagingError) -> Int64 {
        try self.base.adoptDownload(at: location, as: name)
    }

    func writeSidecar(_ sidecar: ResumeSidecar) {
        self.base.writeSidecar(sidecar)
    }

    func readSidecar(for name: StagingFileName) async -> ResumeSidecar? {
        await self.base.readSidecar(for: name)
    }

    func readStaged(_ name: StagingFileName, maxBytes: Int64) async throws(StagingError) -> Data {
        try await self.base.readStaged(name, maxBytes: maxBytes)
    }

    func discard(_ name: StagingFileName) async {
        await self.gate.wait()
        await self.base.discard(name)
    }

    func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError) -> Int64 {
        try await self.base.writeStaged(name, from: source, maxBytes: maxBytes)
    }

    /// Lets every held and later `discard` proceed.
    func release() async {
        await self.gate.release()
    }
}

/// The gate behind `HeldDiscardSink`: closed until `release()`, open for good afterwards.
actor DiscardGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.open else {
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func release() {
        self.open = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
