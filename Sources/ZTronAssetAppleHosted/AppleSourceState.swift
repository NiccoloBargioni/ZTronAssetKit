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

    /// The packs one `reclaimSourceCopies` call releases, and the catalog generation it planned in.
    struct ReleasePlan: Sendable, Hashable {
        /// The packs to remove, sorted.
        var packs: [PackID]
        /// The catalog digest current when planned.
        var generation: ETag?
    }

    private var closed = false
    private var stagingCalls = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainObservers: [CheckedContinuation<Void, Never>] = []

    private var checkTask: Task<Void, Never>?
    private var completedChecks: UInt64 = 0
    private var unreportedRemoved: Set<String> = []
    private var unreportedSuccess = false

    private var catalogETag: ETag?
    private var released: Set<PackID> = []
    private var releasing: Set<PackID> = []
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

    /// Test seam: returns once a `drain()` call is waiting (or nothing is left to drain).
    func waitForDrain() async {
        guard self.drainWaiters.isEmpty, self.stagingCalls > 0 else {
            return
        }
        // REENTRANCY: e-7 (proposed) — nothing: a terminal wait, registered synchronously and resumed by the
        // `drain()` turn that registered its own waiter or by the `endStaging()` turn that reached zero.
        await withCheckedContinuation { self.drainObservers.append($0) }
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

    /// Test seam: waits for the check running now, if any.
    func settleUpdateCheck() async {
        guard let task = self.checkTask else {
            return
        }
        // REENTRANCY: e-3 (proposed) — nothing: a terminal wait on the task; the caller re-reads the report.
        await task.value
    }

    // MARK: Releases and source copies (R-CLN-9, R-CLN-10, H-7)

    /// Records the installed catalog's digest. A new digest starts a new catalog generation, in which a media pack
    /// may be released once more (ADR-027: at most once per pack per generation, so a pack that comes back is never
    /// released in a loop).
    func noteCatalog(_ etag: ETag?) {
        guard etag != self.catalogETag else {
            return
        }
        self.catalogETag = etag
        self.released.removeAll()
    }

    /// Records which media packs hold adopted content and returns the packs `PackReleasePlanner` releases now,
    /// marked in flight so a concurrent call never plans them again.
    func planRelease(_ report: AdoptionReport, catalogPack: PackID, retention: PackRetention) -> ReleasePlan {
        let entries = report.manifestRemotePaths.compactMap(PackLocation.init(remotePath:))
        let adopted = Set(report.adoptedRemotePaths.compactMap(PackLocation.init(remotePath:)))
        let excluded = Set(report.excludedRemotePaths.compactMap(PackLocation.init(remotePath:)))
        self.adoptedPacks = Set(adopted.map(\.pack)).subtracting([catalogPack])
        let packs = PackReleasePlanner.packsToRelease(
            catalogEntries: entries,
            adopted: adopted,
            excluded: excluded,
            catalogPack: catalogPack,
            retention: retention,
            alreadyReleased: self.released.union(self.releasing)
        )
        self.releasing.formUnion(packs)
        return ReleasePlan(packs: packs, generation: self.catalogETag)
    }

    /// Ends one planned release; a success counts for the generation it was planned in only.
    func finishRelease(_ pack: PackID, succeeded: Bool, generation: ETag?) {
        self.releasing.remove(pack)
        if succeeded && generation == self.catalogETag {
            self.released.insert(pack)
        }
    }

    /// Media packs holding adopted content that were not released in this catalog generation, sorted.
    func sourceCopyPacks() -> [PackID] {
        self.adoptedPacks.subtracting(self.released).sorted()
    }
}
