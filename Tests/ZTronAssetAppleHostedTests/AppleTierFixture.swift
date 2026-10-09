import Foundation
import Synchronization
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

/// Pack ids of the SPEC §2.3 layout.
enum Packs {
    static let catalog = PackID(rawValue: "ZTronCatalog")!
    static let media = PackID(rawValue: "ZTronMedia")!
    static let extras = PackID(rawValue: "ZTronExtras")!
}

/// One asset as the catalog describes it and the pack holds it.
struct PackAsset: Sendable {
    let remotePath: String
    let bytes: Data

    init(_ remotePath: String, _ text: String) {
        self.remotePath = remotePath
        self.bytes = Data(text.utf8)
    }

    /// The path inside the pack.
    var path: String {
        String(self.remotePath.drop(while: { $0 != "/" }).dropFirst())
    }

    /// A content transfer of these bytes, as the engine would start it.
    func request(sequence: UInt32 = 1, expectedBytes: Int64? = nil, maxBytes: Int64 = 1 << 20) -> TransferRequest {
        TransferRequest(
            id: .content(ContentHash.sha256(of: self.bytes)),
            attempt: TransferAttempt(epoch: 1, sequence: sequence),
            remotePath: self.remotePath,
            expectedBytes: expectedBytes ?? Int64(self.bytes.count),
            maxBytes: maxBytes,
            priority: .userInitiated
        )
    }
}

/// A source over fakes: `FakePackBackend`, `FakeStagingSink` and a recording tap (ADR-047: nothing reaches the
/// unified log).
@available(macOS 26.0, iOS 26.0, *)
struct AppleTierFixture {
    let backend: FakePackBackend
    let staging: FakeStagingSink
    let tap: RecordingLogTap
    let source: AppleHostedRemoteSource

    init(
        installed: [PackID: [String: Data]] = [:],
        remote: [PackID: [String: Data]] = [:],
        configuration: AppleTierConfiguration = AppleTierConfiguration(),
        staging: (any StagingSink)? = nil
    ) {
        self.backend = FakePackBackend(installed: installed, remote: remote)
        self.staging = FakeStagingSink()
        self.tap = RecordingLogTap()
        self.source = AppleHostedRemoteSource(
            configuration: configuration,
            backend: self.backend,
            staging: staging ?? self.staging,
            log: .tapOnly(self.tap)
        )
    }

    /// A catalog document.
    static let catalogBytes = Data(#"{"version":1,"assets":[]}"#.utf8)

    /// The catalog pack holding `catalog.json`.
    static func catalogPack(_ bytes: Data = AppleTierFixture.catalogBytes) -> [String: Data] {
        ["catalog.json": bytes]
    }

    /// The pseudo-ETag of `bytes`.
    static func etag(of bytes: Data) -> ETag {
        ETag(rawValue: "\"sha256:\(ContentHash.sha256(of: bytes).hex)\"")!
    }

    /// A manifest request.
    static func manifestRequest(ifNoneMatch: ETag? = nil, allowsUpdateCheck: Bool = true, sequence: UInt32 = 1) -> ManifestRequest {
        ManifestRequest(
            ifNoneMatch: ifNoneMatch,
            maxBytes: 32 << 20,
            allowsUpdateCheck: allowsUpdateCheck,
            attempt: TransferAttempt(epoch: 1, sequence: sequence)
        )
    }
}

/// Drains a handle's stream.
func collect(_ handle: any TransferHandle) async -> [TransferUpdate] {
    var updates: [TransferUpdate] = []
    for await update in handle.updates {
        updates.append(update)
    }
    return updates
}

/// Drains a handle's stream like `collect`, and records the interval edges `tap` held when the terminal element
/// arrived (R-OBS-1): read at that moment, not after the stream finished, so a transfer that closes its interval
/// only after delivering its terminal update is caught.
@available(macOS 15.0, iOS 18.0, *)
func collectNotingIntervals(
    _ handle: any TransferHandle,
    tap: RecordingLogTap
) async -> (updates: [TransferUpdate], atTerminal: [LogIntervalEvent]) {
    var updates: [TransferUpdate] = []
    var atTerminal: [LogIntervalEvent] = []
    for await update in handle.updates {
        updates.append(update)
        if update.isTerminal {
            atTerminal = tap.lines.compactMap(LogIntervalEvent.init(line:))
        }
    }
    return (updates, atTerminal)
}

/// A staging sink whose `writeStaged` can be held before it pulls any chunk or after it wrote the whole file, so a
/// test can act while a copy is in flight; everything else goes to a `FakeStagingSink`.
@available(macOS 15.0, iOS 18.0, *)
final class GatedStagingSink: StagingSink {
    /// Where an armed gate holds a write.
    enum Gate: Sendable, Hashable {
        /// Before the sink pulls the first chunk from its source.
        case beforeWrite
        /// After the sink wrote every chunk, before `writeStaged` returns.
        case afterWrite
    }

    private struct State {
        var armed: Gate?
        var held: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var events: [String] = []
        var writeLimits: [Int64] = []
    }

    let base = FakeStagingSink()
    private let state = Mutex(State())

    /// Makes later `writeStaged` calls wait at `gate` for `open()`.
    func arm(_ gate: Gate = .beforeWrite) {
        self.state.withLock { $0.armed = gate }
    }

    /// Releases every held and later write.
    func open() {
        let held = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.armed = nil
            defer { state.held.removeAll() }
            return state.held
        }
        for continuation in held {
            continuation.resume()
        }
    }

    /// Returns once `count` writes are held, or the calling task was cancelled (which also opens the gate, so a
    /// test's time limit never leaves a write held).
    func waitForHeldWrites(_ count: Int) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = self.state.withLock { state -> Bool in
                    guard !Task.isCancelled, state.held.count < count else {
                        return true
                    }
                    state.arrivalWaiters.append((count, continuation))
                    return false
                }
                if ready {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiters = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
                defer { state.arrivalWaiters.removeAll() }
                return state.arrivalWaiters.map(\.continuation)
            }
            for waiter in waiters {
                waiter.resume()
            }
            self.open()
        }
    }

    /// Ordered notes: `write returned`, and whatever the test adds.
    var events: [String] {
        self.state.withLock { $0.events }
    }

    /// The `maxBytes` of every `writeStaged` call, in order.
    var writeLimits: [Int64] {
        self.state.withLock { $0.writeLimits }
    }

    /// Appends a note to `events`.
    func note(_ event: String) {
        self.state.withLock { $0.events.append(event) }
    }

    func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError) -> Int64 {
        defer {
            self.note("write returned")
        }
        self.state.withLock { $0.writeLimits.append(maxBytes) }
        await self.pass(.beforeWrite)
        let result: Result<Int64, StagingError>
        do {
            result = .success(try await self.base.writeStaged(name, from: source, maxBytes: maxBytes))
        } catch {
            result = .failure(error)
        }
        await self.pass(.afterWrite)
        return try result.get()
    }

    /// Holds the calling write when the gate is armed at `point`.
    private func pass(_ point: Gate) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = self.state.withLock { state -> [CheckedContinuation<Void, Never>]? in
                guard state.armed == point else {
                    return nil
                }
                state.held.append(continuation)
                let count = state.held.count
                let reached = state.arrivalWaiters.filter { $0.count <= count }.map(\.continuation)
                state.arrivalWaiters.removeAll { $0.count <= count }
                return reached
            }
            guard let ready else {
                continuation.resume()
                return
            }
            for waiter in ready {
                waiter.resume()
            }
        }
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
        self.note("discard")
        await self.base.discard(name)
    }
}
