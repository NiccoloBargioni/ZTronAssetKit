import Foundation
import Synchronization
import ZTronAssetModel

/// A stop requested through a handle's synchronous controls (ADR-021): the first request wins, and the driver turns
/// it into the stream's terminal element, so exactly one terminal element is ever yielded. The driver claims the
/// terminal element under the same lock (`claimTerminal()`), so a stop either lands before the claim and becomes the
/// terminal element or lands after it and is a no-op, never between the driver's check and its yield.
@available(iOS 26.0, macOS 26.0, *)
final class PackTransferStop: Sendable {
    /// What was asked.
    enum Kind: Sendable, Hashable {
        /// `pause()`: packs cannot resume, so the attempt ends `.paused(resumable: false)`.
        case pause
        /// `cancel()`, or the consumer dropped the stream.
        case cancel

        /// The terminal element this stop ends the stream with.
        var terminal: TransferUpdate {
            switch self {
            case .pause:
                return .paused(resumable: false)
            case .cancel:
                return .failed(.cancelled(.byClient))
            }
        }
    }

    /// The recorded stop and whether the terminal element was claimed, decided together.
    private struct State {
        var kind: Kind?
        var claimed = false
    }

    private let state: Mutex<State>

    /// No stop yet.
    init() {
        self.state = Mutex(State())
    }

    /// Records `kind` unless a stop was already requested or the terminal element was already claimed (a control
    /// after the terminal element is a no-op, ADR-021).
    func request(_ kind: Kind) {
        self.state.withLock { state in
            if state.kind == nil && !state.claimed {
                state.kind = kind
            }
        }
    }

    /// The first stop requested before the claim, if any (a copy checks it before every chunk).
    var requested: Kind? {
        self.state.withLock { $0.kind }
    }

    /// Claims the terminal element and returns the stop requested before the claim, as one decision: from now on
    /// `request(_:)` records nothing. The critical section neither awaits nor does I/O.
    func claimTerminal() -> Kind? {
        self.state.withLock { state in
            state.claimed = true
            return state.kind
        }
    }
}

/// A running Apple-tier transfer (ADR-021). Controls are synchronous: they record the stop and cancel the driver,
/// whose pack wait ends at once (`PackAvailabilityCoordinator`); a copy inside the store's sink stops at its next
/// chunk (`HashingChunkSource`), and one that had already finished is discarded. `setPriority` has no effect: the OS
/// schedules packs.
@available(iOS 26.0, macOS 26.0, *)
final class PackTransferHandle: TransferHandle {
    let id: TransferID
    let attempt: TransferAttempt
    let updates: AsyncStream<TransferUpdate>
    private let stop: PackTransferStop
    private let task: Task<Void, Never>

    /// Starts `driver` in its own task and returns its handle. Dropping the stream cancels the transfer.
    static func start(_ request: TransferRequest, parts: PackTransferDriver.Parts) -> PackTransferHandle {
        let (updates, continuation) = AsyncStream.makeStream(of: TransferUpdate.self)
        let stop = PackTransferStop()
        let driver = PackTransferDriver(request: request, parts: parts, updates: continuation, stop: stop)
        let task = Task {
            await driver.run()
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                stop.request(.cancel)
                task.cancel()
            }
        }
        return PackTransferHandle(id: request.id, attempt: request.attempt, updates: updates, stop: stop, task: task)
    }

    private init(
        id: TransferID,
        attempt: TransferAttempt,
        updates: AsyncStream<TransferUpdate>,
        stop: PackTransferStop,
        task: Task<Void, Never>
    ) {
        self.id = id
        self.attempt = attempt
        self.updates = updates
        self.stop = stop
        self.task = task
    }

    func setPriority(_ priority: AssetPriority) {}

    func pause() {
        self.stop.request(.pause)
        self.task.cancel()
    }

    func cancel() {
        self.stop.request(.cancel)
        self.task.cancel()
    }
}

/// One attempt to copy an asset out of its pack (transport.md §11.3 as amended by transport-2 T2-12 and T2-14).
///
/// 1. Copy the installed file into staging (no network). 2. If the pack or file is absent, make the pack available
/// through the single-flight coordinator, reporting the pack's progress scaled to this asset (R-APL-2), then copy
/// once more. 3. Compare the staged size and SHA-256 with the catalog (`expectedBytes`, and the checksum a content
/// `TransferID` encodes): a disagreement between the catalog and the pack is version skew, reported as
/// `transient(.sourceVersionSkew)` with one best-effort update check scheduled, never as integrity, so the engine
/// never quarantines content a pack update will fix (ADR-032). The store re-hashes the staged file anyway (R-INT-2).
@available(iOS 26.0, macOS 26.0, *)
struct PackTransferDriver: Sendable {
    /// What every driver of one source shares.
    struct Parts: Sendable {
        /// Staging access.
        let copier: PackCopier
        /// Pack availability.
        let packs: PackAvailabilityCoordinator
        /// Update checks.
        let state: AppleSourceState
        /// The `apple` log route.
        let log: LogRoute
    }

    let request: TransferRequest
    let parts: Parts
    let updates: AsyncStream<TransferUpdate>.Continuation
    let stop: PackTransferStop

    /// Runs the attempt inside the R-OBS-1 `transfer` interval and ends the stream with one terminal element.
    ///
    /// The interval ends before the terminal element is yielded, on every path: yielding resumes the consumer on
    /// another thread, so ending it afterwards would let the engine (or a test) see a finished transfer whose
    /// interval is still open.
    func run() async {
        let interval = self.parts.log.interval(.transfer, category: .apple, "attempt \(self.request.attempt.token)")
        let terminal = await self.conclude(await self.attempt())
        interval.end()
        await Self.deliver(terminal, to: self.updates, copier: self.parts.copier)
    }

    /// Turns a finished attempt into the terminal element; also the test seam for the window between a finished
    /// copy and that element (tests call it with an attempt they staged themselves).
    ///
    /// The element is claimed against the handle's controls in one decision (`PackTransferStop.claimTerminal()`):
    /// a pause or cancel recorded before the claim replaces the attempt's element, discarding a staged copy, and one
    /// arriving later is a no-op, as a control after the terminal element is (ADR-021); nothing between the claim and
    /// the yield is visible to the consumer. A pack this attempt downloaded on demand has its release forgotten only
    /// when a staged copy is delivered, so it is released once more after that asset is adopted (R-CLN-10); a skew,
    /// a failure or a stop re-arms nothing, so a pack lacking a catalog entry is never removed and downloaded again
    /// in a loop within one catalog generation (ADR-027).
    func conclude(_ attempt: AttemptResult) async -> TransferUpdate {
        var terminal = attempt.terminal
        if let stop = self.stop.claimTerminal() {
            if case .staged(let file) = terminal {
                await self.parts.copier.discard(file.name)
            }
            terminal = stop.terminal
        }
        if let pack = attempt.downloaded, case .staged = terminal {
            await self.parts.state.forgetRelease(pack)
        }
        return terminal
    }

    /// Ends the stream with `terminal`. A consumer can drop the stream after the terminal was claimed and before this
    /// yield (nothing suspends in between, but another thread can); a staged copy that therefore reaches nobody is
    /// discarded here, so no staging file outlives its transfer until the next launch's staging GC.
    static func deliver(
        _ terminal: TransferUpdate,
        to updates: AsyncStream<TransferUpdate>.Continuation,
        copier: PackCopier
    ) async {
        if case .terminated = updates.yield(terminal), case .staged(let file) = terminal {
            await copier.discard(file.name)
        }
        updates.finish()
    }

    /// What one attempt ended with, before the handle's controls are consulted.
    struct AttemptResult: Sendable, Hashable {
        /// The terminal element the attempt proposes.
        var terminal: TransferUpdate
        /// The pack this attempt made available on demand after finding it or the file absent, if any.
        var downloaded: PackID?
    }

    private func attempt() async -> AttemptResult {
        guard let location = PackLocation(remotePath: self.request.remotePath) else {
            self.parts.log.log(.apple, .error, "attempt \(self.request.attempt.token): remote path is not a pack location")
            return AttemptResult(terminal: .failed(.rejected(.invalidURL)))
        }
        var outcome = await self.parts.copier.copy(location, as: self.request.partialName, maxBytes: self.cap, stop: self.stop)
        guard case .sourceMissing = outcome else {
            return AttemptResult(terminal: await self.settle(outcome))
        }
        switch await self.ensure(location.pack) {
        case .available:
            break
        case .failed(let error):
            let reason = String(describing: error)
            self.parts.log.log(.apple, .error, "attempt \(self.request.attempt.token): pack \(location.pack) unavailable: \(reason)")
            return AttemptResult(terminal: .failed(PackErrorMapping.transferError(error)))
        case .cancelled:
            return AttemptResult(terminal: .failed(.cancelled(.byClient)))
        }
        outcome = await self.parts.copier.copy(location, as: self.request.partialName, maxBytes: self.cap, stop: self.stop)
        return AttemptResult(terminal: await self.settle(outcome), downloaded: location.pack)
    }

    /// The staged bytes are capped at the catalog size when it is known, so a pack file that grew is stopped early.
    private var cap: Int64 {
        guard let expected = self.request.expectedBytes, expected >= 0, expected <= self.request.maxBytes else {
            return self.request.maxBytes
        }
        return expected
    }

    /// The checksum a content transfer is named after (`c-<hex>`); `nil` for legacy, checksum-less entries.
    private var expectedChecksum: ContentHash? {
        guard self.request.id.kind == .content else {
            return nil
        }
        return ContentHash(hex: self.request.id.rawValue.dropFirst(2))
    }

    /// Turns a copy into the terminal element. A file still missing after the pack was made available is skew too.
    private func settle(_ outcome: PackCopier.Outcome) async -> TransferUpdate {
        switch outcome {
        case .copied(let bytes, let digest):
            if let expected = self.request.expectedBytes, expected != bytes {
                return await self.skew("pack file has \(bytes) bytes, the catalog says \(expected)", discarding: true)
            }
            if let checksum = self.expectedChecksum, checksum != digest {
                return await self.skew("pack file does not match the catalog checksum", discarding: true)
            }
            let file = StagedFile(name: self.request.partialName, byteCount: bytes, resumed: false, httpStatus: nil, etag: nil)
            return .staged(file)
        case .failed(.tooLarge) where self.request.expectedBytes == self.cap:
            return await self.skew("pack file is larger than the catalog says", discarding: false)
        case .failed(let error):
            let reason = String(describing: error)
            self.parts.log.log(.apple, .error, "attempt \(self.request.attempt.token): staging failed: \(reason)")
            return .failed(PackErrorMapping.transferError(error, expectedBytes: self.request.expectedBytes))
        case .sourceMissing:
            return await self.skew("the pack holds no file at the catalog's path", discarding: false)
        case .stopped, .closed:
            return .failed(.cancelled(.byClient))
        }
    }

    /// Catalog/pack version skew (T2-12, ADR-032): transient, with one best-effort update check.
    private func skew(_ reason: String, discarding: Bool) async -> TransferUpdate {
        if discarding {
            await self.parts.copier.discard(self.request.partialName)
        }
        self.parts.log.log(.apple, .error, "attempt \(self.request.attempt.token): \(reason); scheduling an update check")
        await self.parts.state.scheduleUpdateCheck(self.parts.copier.backend, log: self.parts.log)
        return .failed(.transient(.sourceVersionSkew, retryAfter: nil))
    }

    /// Waits for the pack, forwarding its progress as byte values of this asset while waiting (R-APL-2).
    private func ensure(_ pack: PackID) async -> PackAvailabilityCoordinator.Outcome {
        guard let expected = self.request.expectedBytes, expected > 0 else {
            return await self.parts.packs.ensure(pack, progress: nil)
        }
        let (stream, progress) = AsyncStream.makeStream(
            of: PackProgress.self,
            bufferingPolicy: .bufferingNewest(PackFlight.progressBuffer)
        )
        async let forwarded: Void = Self.forward(stream, expectedBytes: expected, to: self.updates)
        let outcome = await self.parts.packs.ensure(pack, progress: progress)
        progress.finish()
        await forwarded
        return outcome
    }

    private static func forward(
        _ stream: AsyncStream<PackProgress>,
        expectedBytes: Int64,
        to updates: AsyncStream<TransferUpdate>.Continuation
    ) async {
        var scaler = PackProgressScaler(expectedBytes: expectedBytes)
        for await progress in stream {
            if let received = scaler.received(for: progress) {
                updates.yield(.progress(received: received, expected: expectedBytes))
            }
        }
    }
}
