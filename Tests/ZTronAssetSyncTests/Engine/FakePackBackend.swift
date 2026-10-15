import Foundation
import Synchronization
import ZTronAssetAppleHosted
import ZTronAssetModel

/// The test double of `PackBackend` for the engine's end-to-end Apple-tier test (R-APL-3; orchestrator ruling L4-R1).
///
/// A subset of WP-E's `Tests/ZTronAssetAppleHostedTests/FakePackBackend.swift` (ADR-040: the fake lives in a test
/// target, because `PackBackend` is declared in `ZTronAssetAppleHosted`, which `ZTronAssetTestSupport` cannot see; WP-E's
/// file and `ZTronAssetTestSupport` stay untouched). Kept: installed and remote packs as dictionaries of files, installs
/// on `ensureAvailable`, an update check that finds nothing, removal, installed bytes, the ordered call log and waiting
/// for a call without sleeping. Left out: scripted failures and holds, which the engine's test does not need.
/// Gated for `Mutex` (ADR-014).
@available(macOS 15.0, iOS 18.0, *)
final class FakePackBackend: PackBackend {
    /// One call on the seam (or on a reader it made).
    enum Call: Sendable, Hashable {
        case reader(PackID, String)
        case open(PackID, String)
        case ensure(PackID)
        case checkForUpdates
        case remove(PackID)
        case installedBytes(PackID)
    }

    private struct CallWaiter {
        let call: Call
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var installed: [PackID: [String: Data]] = [:]
        var remote: [PackID: [String: Data]] = [:]
        var calls: [Call] = []
        var callWaiters: [CallWaiter] = []
    }

    private let state: Mutex<State>

    /// Starts with `installed` packs readable at once and `remote` packs that `ensureAvailable` installs.
    init(installed: [PackID: [String: Data]] = [:], remote: [PackID: [String: Data]] = [:]) {
        var state = State()
        state.installed = installed
        state.remote = remote
        self.state = Mutex(state)
    }

    /// Every call so far, in order.
    var calls: [Call] {
        self.state.withLock { $0.calls }
    }

    /// The packs installed now.
    var installedPacks: Set<PackID> {
        self.state.withLock { Set($0.installed.keys) }
    }

    /// Returns once `call` was recorded at least `count` times. Every test that waits for a call makes the engine
    /// perform it (the wait has no cancellation path of its own; the test's time limit bounds it).
    func waitFor(_ call: Call, count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = self.state.withLock { state -> Bool in
                guard state.calls.filter({ $0 == call }).count < count else {
                    return true
                }
                state.callWaiters.append(CallWaiter(call: call, count: count, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    // MARK: PackBackend

    func reader(for path: String, in pack: PackID) -> any PackFileReader {
        self.record(.reader(pack, path))
        return FakePackFileReader(backend: self, pack: pack, path: path)
    }

    func ensureAvailable(_ pack: PackID, progress: AsyncStream<PackProgress>.Continuation?) async throws(PackError) {
        self.record(.ensure(pack))
        let installed = self.state.withLock { state -> Bool in
            if state.installed[pack] != nil {
                return true
            }
            guard let files = state.remote[pack] else {
                return false
            }
            state.installed[pack] = files
            return true
        }
        guard installed else {
            throw .packNotFound
        }
    }

    func checkForUpdates() async throws(PackError) -> PackUpdateCheck {
        self.record(.checkForUpdates)
        return PackUpdateCheck(updating: [], removed: [])
    }

    /// Removes the pack, then records the call (so a test that waited for it sees the pack gone).
    func remove(_ pack: PackID) async throws(PackError) {
        let removed = self.state.withLock { $0.installed.removeValue(forKey: pack) != nil }
        self.record(.remove(pack))
        guard removed else {
            throw .packNotFound
        }
    }

    func installedBytes(of pack: PackID) async -> Int64? {
        self.record(.installedBytes(pack))
        return self.state.withLock { state -> Int64? in
            state.installed[pack].map { files in files.values.reduce(0) { $0 + Int64($1.count) } }
        }
    }

    // MARK: Internals

    /// The bytes of an installed file, recording the open; the reader's lazy open calls it on its first read.
    func open(_ pack: PackID, _ path: String) throws(StagingError) -> Data {
        self.record(.open(pack, path))
        let lookup = self.state.withLock { state -> Result<Data, StagingError> in
            guard let files = state.installed[pack] else {
                return .failure(.source(.notInstalled))
            }
            guard let data = files[path] else {
                return .failure(.source(.notFound))
            }
            return .success(data)
        }
        return try lookup.get()
    }

    private func record(_ call: Call) {
        let ready = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.calls.append(call)
            var ready: [CheckedContinuation<Void, Never>] = []
            var waiting: [CallWaiter] = []
            for waiter in state.callWaiters {
                if state.calls.filter({ $0 == waiter.call }).count >= waiter.count {
                    ready.append(waiter.continuation)
                } else {
                    waiting.append(waiter)
                }
            }
            state.callWaiters = waiting
            return ready
        }
        for continuation in ready {
            continuation.resume()
        }
    }
}

/// A lazy reader over one fake pack file: nothing is looked up until the first `nextChunk`.
@available(macOS 15.0, iOS 18.0, *)
final class FakePackFileReader: PackFileReader {
    private let backend: FakePackBackend
    private let pack: PackID
    private let path: String
    private let cursor: Mutex<(data: Data, offset: Int)?>

    init(backend: FakePackBackend, pack: PackID, path: String) {
        self.backend = backend
        self.pack = pack
        self.path = path
        self.cursor = Mutex(nil)
    }

    func nextChunk(maxBytes: Int) throws(StagingError) -> Data? {
        if self.cursor.withLock({ $0 == nil }) {
            let data = try self.backend.open(self.pack, self.path)
            self.cursor.withLock { $0 = (data, 0) }
        }
        return self.cursor.withLock { cursor -> Data? in
            guard let current = cursor, current.offset < current.data.count else {
                return nil
            }
            let end = min(current.data.count, current.offset + maxBytes)
            cursor = (current.data, end)
            return current.data.subdata(in: current.offset..<end)
        }
    }
}
