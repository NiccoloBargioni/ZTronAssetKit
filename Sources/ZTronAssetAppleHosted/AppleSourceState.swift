import ZTronAssetModel

/// The Apple source's mutable state, owned by one actor so `AppleHostedRemoteSource` stays an immutable `Sendable`
/// class (C1): staging admission and drain (shutdown, transport-2 T2-04), the source-owned update check and what it
/// found (T2-14, T2-20), and pack releases per catalog generation plus the adopted packs (H-7, ADR-027).
@available(iOS 26.0, macOS 26.0, *)
actor AppleSourceState {
    /// What finished update checks found, as one manifest fetch reports it.
    struct CheckReport: Sendable, Hashable {
        /// Update checks finished when the report was taken.
        var completedChecks: UInt64
        /// Pack ids those checks reported removed and no earlier manifest reported.
        var removed: Set<String>
        /// Whether the last finished check succeeded and no earlier manifest reported it.
        var updateChecked: Bool
    }

    /// The packs one `reclaimSourceCopies` call releases, and the release generation it planned in.
    struct ReleasePlan: Sendable, Hashable {
        /// The packs to remove, sorted.
        var packs: [PackID]
        /// The release generation current when planned (see `noteCatalog`).
        var generation: UInt64
    }

    /// Requested (as `.cancel`) by `close()`: a copy in flight stops at its next chunk (`HashingChunkSource`), so
    /// `invalidate()` waits for at most one more chunk of each copy instead of whole pack files.
    nonisolated let shutdown = PackTransferStop()

    private var closed = false
    private var stagingCalls = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainObservers: [CheckedContinuation<Void, Never>] = []

    private var checkTask: Task<Void, Never>?
    private var completedChecks: UInt64 = 0
    private var unreportedRemoved: Set<String> = []
    private var unreportedSuccess = false

    private var catalogETag: ETag?
    private var generation: UInt64 = 0
    private var released: Set<PackID> = []
    private var releasing: Set<PackID> = []
    /// Packs in `releasing` that a transfer of this source made available again while their release call ran: the
    /// call may have returned after the download, so its success must not mark the pack released (E-10(b)).
    private var forgottenWhileReleasing: Set<PackID> = []
    private var adoptedPacks: Set<PackID> = []

    /// Creates an open state.
    init() {}

    // MARK: Staging admission (RemoteSource.invalidate)

    /// Admits one staging call; `false` once `close()` ran, so nothing reaches staging after `invalidate()` began.
    func beginStaging() -> Bool {
        guard !self.closed else {
            return false
        }
        self.stagingCalls += 1
        return true
    }

    /// Ends an admitted staging call; the last one out releases `drain()`.
    func endStaging() {
        self.stagingCalls -= 1
        guard self.stagingCalls == 0 else {
            return
        }
        let waiters = self.drainWaiters
        self.drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        self.releaseDrainObservers()
    }

    /// Stops admitting staging calls and update checks and cancels the running check (it touches no staging).
    func close() {
        self.closed = true
        self.shutdown.request(.cancel)
        self.checkTask?.cancel()
        self.checkTask = nil
    }

    /// Returns once no admitted staging call is running.
    func drain() async {
        guard self.stagingCalls > 0 else {
            return
        }
        // REENTRANCY: e-1 (proposed) — nothing: a terminal wait registered synchronously in the continuation body
        // and resumed only by the `endStaging()` turn that reached zero; `close()` ran first, so no call is admitted
        // afterwards and nothing is read after the resumption.
        await withCheckedContinuation { continuation in
            self.drainWaiters.append(continuation)
            self.releaseDrainObservers()
        }
    }

    private func releaseDrainObservers() {
        let observers = self.drainObservers
        self.drainObservers.removeAll()
        for observer in observers {
            observer.resume()
        }
    }

    /// Test seam: returns once a `drain()` call is waiting, nothing is left to drain, or the calling task was
    /// cancelled (so a test's time limit ends a wait that a defect would make endless). `registered` runs on the actor
    /// once the wait is registered, so a test can cancel a wait it knows is pending.
    func waitForDrain(registered: (@Sendable () -> Void)? = nil) async {
        guard self.drainWaiters.isEmpty, self.stagingCalls > 0 else {
            return
        }
        // REENTRANCY: e-7 (proposed) — nothing: a terminal wait, registered synchronously and resumed by the
        // `drain()` turn that registered its own waiter, the `endStaging()` turn that reached zero, or cancellation.
        await withTaskCancellationHandler {
            // REENTRANCY: e-7 (proposed) — as above.
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.drainObservers.append(continuation)
                    registered?()
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: e-8 (proposed) — a hop onto the actor from a cancellation handler, which cannot touch
                // actor state synchronously; `releaseDrainObservers` re-reads the observer list, so an observer
                // already resumed and removed by another turn is never resumed twice.
                await self.releaseDrainObservers()
            }
        }
    }

    // MARK: Update checks (R-APL-4, transport-2 T2-14, T2-20)

    /// Starts one best-effort `checkForUpdates()` in a task the source owns, unless one is running or the source
    /// closed. Nobody awaits it: its findings are reported by the next manifest fetch.
    func scheduleUpdateCheck(_ backend: any PackBackend, log: LogRoute) {
        guard !self.closed, self.checkTask == nil else {
            return
        }
        self.checkTask = Task {
            let outcome: Result<PackUpdateCheck, PackError>
            do throws(PackError) {
                // REENTRANCY: e-2 (proposed) — the check runs off the actor; `finishCheck` then runs on it and
                // only appends to the findings and clears `checkTask`, so a close or another check meanwhile is
                // harmless (a second check is never started while this one is recorded as running).
                outcome = .success(try await backend.checkForUpdates())
            } catch {
                outcome = .failure(error)
            }
            self.finishCheck(outcome, log: log)
        }
    }

    /// Records a finished check.
    private func finishCheck(_ outcome: Result<PackUpdateCheck, PackError>, log: LogRoute) {
        self.checkTask = nil
        self.completedChecks += 1
        switch outcome {
        case .success(let check):
            self.unreportedRemoved.formUnion(check.removed.map(\.rawValue))
            self.unreportedSuccess = true
            log.log(.apple, .info, "update check: \(check.updating.count) packs updating, \(check.removed.count) removed")
        case .failure(let error):
            self.unreportedSuccess = false
            let reason = String(describing: error)
            log.log(.apple, .error, "update check failed: \(reason)")
        }
    }

    /// What finished checks found that no manifest reported yet.
    func checkReport() -> CheckReport {
        CheckReport(
            completedChecks: self.completedChecks,
            removed: self.unreportedRemoved,
            updateChecked: self.unreportedSuccess
        )
    }

    /// Forgets what `report` told the engine; a check that finished after the report keeps its own findings.
    func acknowledge(_ report: CheckReport) {
        self.unreportedRemoved.subtract(report.removed)
        if self.completedChecks == report.completedChecks {
            self.unreportedSuccess = false
        }
    }

    /// Test seam: waits for the check running now, if any; cancelling the caller cancels the check.
    func settleUpdateCheck() async {
        guard let task = self.checkTask else {
            return
        }
        // REENTRANCY: e-3 (proposed) — nothing: a terminal wait on the task; the caller re-reads the report.
        await withTaskCancellationHandler {
            // REENTRANCY: e-3 (proposed) — as above.
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Releases and source copies (R-CLN-9, R-CLN-10, H-7)

    /// Records the installed catalog's digest. A new digest starts a new release generation, in which a media pack
    /// may be released once more (ADR-027: at most once per pack per generation, so a pack that comes back is never
    /// released in a loop). The first digest of the process does not: releases made before it (an offline launch's
    /// maintenance) belong to the generation it opens, so they are neither repeated nor reported twice.
    func noteCatalog(_ etag: ETag?) {
        guard etag != self.catalogETag else {
            return
        }
        let first = self.catalogETag == nil
        self.catalogETag = etag
        if !first {
            self.generation += 1
            self.released.removeAll()
        }
    }

    /// Records which media packs hold adopted content and returns the settled packs not released in this generation,
    /// marked in flight so a concurrent call never plans them again. `survey` was computed off the actor (C2); this
    /// turn only filters it, so the bookkeeping is re-validated against the sets as they are now.
    func planRelease(_ survey: ReleaseSurvey) -> ReleasePlan {
        self.adoptedPacks = survey.adopted
        let packs = survey.settled.subtracting(self.released).subtracting(self.releasing).sorted()
        self.releasing.formUnion(packs)
        return ReleasePlan(packs: packs, generation: self.generation)
    }

    /// Ends one planned release; a success counts for the generation it was planned in only, and not at all when a
    /// transfer made the pack available again while the call ran (`forgetRelease`): the removal may have run before
    /// that download, so the pack may be installed again. If it ran after it, the next reclaim gets `packNotFound`,
    /// which counts as released.
    func finishRelease(_ pack: PackID, succeeded: Bool, generation: UInt64) {
        self.releasing.remove(pack)
        let forgotten = self.forgottenWhileReleasing.remove(pack) != nil
        if succeeded && generation == self.generation && !forgotten {
            self.released.insert(pack)
        }
    }

    /// Forgets that `pack` was released in this generation because a transfer of this source made it available
    /// again (an adopted blob was evicted or repaired and fetched once more): once its entries are adopted again it
    /// is released once more. Only the source's own demand does this, never the OS bringing a pack back on its own,
    /// so releases still never loop. A release call still running for `pack` is remembered as forgotten too.
    func forgetRelease(_ pack: PackID) {
        self.released.remove(pack)
        if self.releasing.contains(pack) {
            self.forgottenWhileReleasing.insert(pack)
        }
    }

    /// Media packs holding adopted content, sorted. Released packs stay listed: the OS reports no bytes for a removed
    /// pack, and a pack a transfer downloaded again holds bytes the device really keeps twice (R-CLN-9).
    func sourceCopyPacks() -> [PackID] {
        self.adoptedPacks.sorted()
    }
}
