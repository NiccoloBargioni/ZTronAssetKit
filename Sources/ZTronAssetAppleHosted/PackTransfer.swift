import Foundation
import Synchronization
import ZTronAssetModel

/// A stop requested through a handle's synchronous controls (ADR-021): the first request wins, and the driver turns
/// it into the stream's terminal element, so exactly one terminal element is ever yielded.
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

    private let kind: Mutex<Kind?>

    /// No stop yet.
    init() {
        self.kind = Mutex(nil)
    }

    /// Records `kind` unless a stop was already requested.
    func request(_ kind: Kind) {
        self.kind.withLock { current in
            if current == nil {
                current = kind
            }
        }
    }

    /// The first stop requested, if any.
    var requested: Kind? {
        self.kind.withLock { $0 }
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
    func run() async {
        let interval = self.parts.log.interval(.transfer, category: .apple, "attempt \(self.request.attempt.token)")
        var terminal = await self.attempt()
        if let stop = self.stop.requested {
            if case .staged(let file) = terminal {
                await self.parts.copier.discard(file.name)
            }
            terminal = stop.terminal
        }
        await Self.deliver(terminal, to: self.updates, copier: self.parts.copier)
        interval.end()
    }

    /// Ends the stream with `terminal`. A consumer can drop the stream after the stop check above and before this
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

    private func attempt() async -> TransferUpdate {
        guard let location = PackLocation(remotePath: self.request.remotePath) else {
            self.parts.log.log(.apple, .error, "attempt \(self.request.attempt.token): remote path is not a pack location")
            return .failed(.rejected(.invalidURL))
        }
        var outcome = await self.parts.copier.copy(location, as: self.request.partialName, maxBytes: self.cap, stop: self.stop)
        if case .sourceMissing = outcome {
            switch await self.ensure(location.pack) {
            case .available:
                // A pack released earlier and downloaded again for this asset may be released once more (R-CLN-10).
                await self.parts.state.forgetRelease(location.pack)
            case .failed(let error):
                let reason = String(describing: error)
                self.parts.log.log(.apple, .error, "attempt \(self.request.attempt.token): pack \(location.pack) unavailable: \(reason)")
                return .failed(PackErrorMapping.transferError(error))
            case .cancelled:
                return .failed(.cancelled(.byClient))
            }
            outcome = await self.parts.copier.copy(location, as: self.request.partialName, maxBytes: self.cap, stop: self.stop)
        }
        return await self.settle(outcome)
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
