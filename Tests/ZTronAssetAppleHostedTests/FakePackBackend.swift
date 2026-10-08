import Foundation
import Synchronization
import ZTronAssetAppleHosted
import ZTronAssetModel

/// The test double of `PackBackend` (R-APL-1, ADR-040): it lives here because `PackBackend` is declared in
/// `ZTronAssetAppleHosted`, which `ZTronAssetTestSupport` (Model + Storage only) cannot see.
///
/// Packs are dictionaries of files. `installed` packs are readable at once; `remote` packs are what
/// `ensureAvailable` installs. Each `ensureAvailable` and `checkForUpdates` call takes the next scripted step (an
/// install with progress values, a failure, or a hold the test releases); every call is recorded in order, and a
/// test can wait for a call without sleeping. A held call that is cancelled records `ensureCancelled` and returns
/// a failure, like an OS await that honours cancellation. Gated for `Mutex` (ADR-014).
@available(macOS 15.0, iOS 18.0, *)
final class FakePackBackend: PackBackend {
    /// One call on the seam (or on a reader it made).
    enum Call: Sendable, Hashable {
        case reader(PackID, String)
        case open(PackID, String)
        case ensure(PackID)
        case ensureCancelled(PackID)
        case checkForUpdates
        case remove(PackID)
        case installedBytes(PackID)
    }

    /// What the next `ensureAvailable(pack)` does.
    enum EnsureStep: Sendable, Hashable {
        /// Yields `progress`, then installs the remote pack (`packNotFound` when there is none).
        case install(progress: [PackProgress])
        /// Yields `progress`, then throws.
        case fail(PackError, progress: [PackProgress])
        /// Suspends until `releaseEnsure(_:with:)` names the step to finish with.
        case hold
    }

    /// What the next `checkForUpdates()` does.
    enum CheckStep: Sendable, Hashable {
        /// Returns `check` (removing its removed packs from `installed`).
        case succeed(PackUpdateCheck)
        /// Throws.
        case fail(PackError)
        /// Suspends until `releaseCheck(with:)`.
        case hold
    }

    private enum Held {
        case ensure(PackID, CheckedContinuation<EnsureStep?, Never>)
        case check(CheckedContinuation<CheckStep?, Never>)
    }

    private struct CallWaiter {
        let call: Call
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var installed: [PackID: [String: Data]] = [:]
        var remote: [PackID: [String: Data]] = [:]
        var ensureSteps: [PackID: [EnsureStep]] = [:]
        var checkSteps: [CheckStep] = []
        var removeFailures: [PackID: PackError] = [:]
        var installedBytesOverride: [PackID: Int64] = [:]
        var calls: [Call] = []
        var held: [UInt64: Held] = [:]
        var nextHeld: UInt64 = 0
        var pendingEnsureReleases: [PackID: EnsureStep] = [:]
        var pendingCheckRelease: CheckStep?
        var callWaiters: [CallWaiter] = []
    }

    private let state: Mutex<State>

    /// Starts with no packs and default steps (install without progress; a check that finds nothing).
    init(installed: [PackID: [String: Data]] = [:], remote: [PackID: [String: Data]] = [:]) {
        var state = State()
        state.installed = installed
        state.remote = remote
        self.state = Mutex(state)
    }

    // MARK: Scripting

    /// Every call so far, in order.
    var calls: [Call] {
        self.state.withLock { $0.calls }
    }

    /// The packs installed now.
    var installedPacks: Set<PackID> {
        self.state.withLock { Set($0.installed.keys) }
    }

    /// Queues steps for `ensureAvailable(pack)`.
    func scriptEnsure(_ pack: PackID, _ steps: [EnsureStep]) {
        self.state.withLock { $0.ensureSteps[pack, default: []].append(contentsOf: steps) }
    }

    /// Queues steps for `checkForUpdates()`.
    func scriptCheck(_ steps: [CheckStep]) {
        self.state.withLock { $0.checkSteps.append(contentsOf: steps) }
    }

    /// Makes `remove(pack)` throw `error` (`nil`: succeed again).
    func failRemove(_ pack: PackID, with error: PackError?) {
        self.state.withLock { $0.removeFailures[pack] = error }
    }

    /// Reports `bytes` for `pack` instead of the sum of its files.
    func setInstalledBytes(_ pack: PackID, _ bytes: Int64) {
        self.state.withLock { $0.installedBytesOverride[pack] = bytes }
    }

    /// Installs (or replaces) `pack` as the OS would after an update or a re-download.
    func install(_ pack: PackID, files: [String: Data]) {
        self.state.withLock { $0.installed[pack] = files }
    }

    /// Finishes every held `ensureAvailable(pack)` with `step`; when none is held yet (the call has not reached
    /// its hold), the next hold of `pack` finishes with `step` at once, so a test never races the fake.
    func releaseEnsure(_ pack: PackID, with step: EnsureStep) {
        let continuations = self.state.withLock { state -> [CheckedContinuation<EnsureStep?, Never>] in
            var found: [CheckedContinuation<EnsureStep?, Never>] = []
            for (key, held) in state.held {
                if case .ensure(let heldPack, let continuation) = held, heldPack == pack {
                    found.append(continuation)
                    state.held[key] = nil
                }
            }
            if found.isEmpty {
                state.pendingEnsureReleases[pack] = step
            }
            return found
        }
        for continuation in continuations {
            continuation.resume(returning: step)
        }
    }

    /// Finishes every held `checkForUpdates()` with `step` (or the next one, like `releaseEnsure`).
    func releaseCheck(with step: CheckStep) {
        let continuations = self.state.withLock { state -> [CheckedContinuation<CheckStep?, Never>] in
            var found: [CheckedContinuation<CheckStep?, Never>] = []
            for (key, held) in state.held {
                if case .check(let continuation) = held {
                    found.append(continuation)
                    state.held[key] = nil
                }
            }
            if found.isEmpty {
                state.pendingCheckRelease = step
            }
            return found
        }
        for continuation in continuations {
            continuation.resume(returning: step)
        }
    }

    /// Returns once `call` was recorded at least `count` times.
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
        var step = self.state.withLock { state -> EnsureStep in
            guard var steps = state.ensureSteps[pack], !steps.isEmpty else {
                return .install(progress: [])
            }
            let first = steps.removeFirst()
            state.ensureSteps[pack] = steps
            return first
        }
        if case .hold = step {
            let pending = { (state: inout State) -> EnsureStep? in state.pendingEnsureReleases.removeValue(forKey: pack) }
            guard let released = await self.hold(pending: pending, { .ensure(pack, $0) }) else {
                self.record(.ensureCancelled(pack))
                throw .system(domain: "FakePackBackend", code: -999)
            }
            step = released
        }
        switch step {
        case .install(let values):
            for value in values {
                progress?.yield(value)
            }
            let installed = self.state.withLock { state -> Bool in
                guard let files = state.remote[pack] else {
                    return false
                }
                state.installed[pack] = files
                return true
            }
            guard installed else {
                throw .packNotFound
            }
        case .fail(let error, let values):
            for value in values {
                progress?.yield(value)
            }
            throw error
        case .hold:
            throw .system(domain: "FakePackBackend", code: -1)
        }
    }

    func checkForUpdates() async throws(PackError) -> PackUpdateCheck {
        self.record(.checkForUpdates)
        var step = self.state.withLock { state -> CheckStep in
            state.checkSteps.isEmpty ? .succeed(PackUpdateCheck(updating: [], removed: [])) : state.checkSteps.removeFirst()
        }
        if case .hold = step {
            let pending = { (state: inout State) -> CheckStep? in
                defer { state.pendingCheckRelease = nil }
                return state.pendingCheckRelease
            }
            guard let released = await self.hold(pending: pending, { .check($0) }) else {
                throw .system(domain: "FakePackBackend", code: -999)
            }
            step = released
        }
        switch step {
        case .succeed(let check):
            self.state.withLock { state in
                for pack in check.removed {
                    state.installed[pack] = nil
                }
            }
            return check
        case .fail(let error):
            throw error
        case .hold:
            throw .system(domain: "FakePackBackend", code: -1)
        }
    }

    func remove(_ pack: PackID) async throws(PackError) {
        self.record(.remove(pack))
        let failure = self.state.withLock { state -> PackError? in
            if let failure = state.removeFailures[pack] {
                return failure
            }
            return state.installed.removeValue(forKey: pack) == nil ? .packNotFound : nil
        }
        if let failure {
            throw failure
        }
    }

    func installedBytes(of pack: PackID) async -> Int64? {
        self.record(.installedBytes(pack))
        return self.state.withLock { state -> Int64? in
            guard let files = state.installed[pack] else {
                return nil
            }
            return state.installedBytesOverride[pack] ?? files.values.reduce(0) { $0 + Int64($1.count) }
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

    /// Suspends until released (the step) or cancelled (`nil`).
    private func hold<Step: Sendable>(
        pending: (inout State) -> Step?,
        _ make: (CheckedContinuation<Step?, Never>) -> Held
    ) async -> Step? {
        let key = self.state.withLock { state -> UInt64 in
            state.nextHeld += 1
            return state.nextHeld
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Step?, Never>) in
                let immediate = self.state.withLock { state -> Step?? in
                    guard !Task.isCancelled else {
                        return .some(nil)
                    }
                    if let released = pending(&state) {
                        return .some(released)
                    }
                    state.held[key] = make(continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            let held = self.state.withLock { $0.held.removeValue(forKey: key) }
            switch held {
            case .ensure(_, let continuation):
                continuation.resume(returning: nil)
            case .check(let continuation):
                continuation.resume(returning: nil)
            case nil:
                break
            }
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
