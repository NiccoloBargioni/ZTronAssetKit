import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// What kind of owned task a spawn is (task priority, sync-1 S1-17).
enum OwnedTaskKind: Sendable {
    /// `start()`.
    case start
    /// A transfer driver at a lane.
    case driver(AssetPriority)
    /// The alarm.
    case alarm
    /// The conditions watcher.
    case watcher
    /// A run.
    case run
    /// A manifest fetch.
    case manifest
    /// A store-touching entry point (ADR-039).
    case entry
    /// The memory-pressure observer.
    case pressure

    /// The task priority of the spawn.
    var priority: TaskPriority {
        switch self {
        case .driver(.userInitiated), .start:
            return .userInitiated
        case .driver(.prefetch), .entry, .manifest:
            return .medium
        case .driver(.bulk), .run, .alarm, .watcher, .pressure:
            return .utility
        }
    }

    /// The priority a spawn of this kind runs at under `floor` (`EngineState.ownedTaskPriorityFloor`, `nil` in
    /// production): the kind's own priority, raised to the floor when that is higher, never lowered by it.
    func priority(floor: TaskPriority?) -> TaskPriority {
        guard let floor else {
            return self.priority
        }
        return max(self.priority, floor)
    }
}

extension SyncEngine {
    // MARK: Owned tasks (ADR-039, sync-1 S1-09)

    /// Spawns an owned task keyed by a unique id; `nil` once shutdown began (nothing new spawns, RE-S21). The task
    /// unregisters itself when its body returns, even after cancellation.
    @discardableResult
    func spawn(_ kind: OwnedTaskKind, _ operation: @escaping @Sendable (SyncEngine) async -> Void) -> UInt64? {
        switch self.state.lifecycle {
        case .shuttingDown, .shutDown, .degraded:
            return nil
        case .created, .starting, .running:
            break
        }
        self.state.lastTaskKey += 1
        let key = self.state.lastTaskKey
        let task = Task(priority: kind.priority(floor: self.state.ownedTaskPriorityFloor)) {
            // REENTRANCY: RE-S21 — nothing: the task then removes only its own key (a successor has another key).
            await operation(self)
            self.taskEnded(key)
        }
        self.state.tasks[key] = task
        self.notifyObservers()
        return key
    }

    /// Removes a finished owned task.
    func taskEnded(_ key: UInt64) {
        self.state.tasks[key] = nil
        self.notifyObservers()
    }

    /// Cancels an owned task (it unregisters itself when it returns).
    func cancelTask(_ key: UInt64?) {
        guard let key else {
            return
        }
        self.state.tasks[key]?.cancel()
    }

    /// A fresh interest token; never reused (sync-1 S1-05).
    func nextToken() -> InterestToken {
        self.state.lastToken += 1
        return InterestToken(rawValue: self.state.lastToken)
    }

    /// A fresh transfer attempt of this launch (ADR-013).
    func nextAttempt() -> TransferAttempt {
        let (next, overflow) = self.state.lastAttempt.addingReportingOverflow(1)
        self.state.lastAttempt = overflow ? UInt32.max : next
        return TransferAttempt(epoch: self.state.launch?.report.launchEpoch ?? 0, sequence: self.state.lastAttempt)
    }

    /// Whether the engine serves.
    var isRunning: Bool {
        self.state.lifecycle == .running
    }

    /// Whether shutdown began.
    var isShuttingDown: Bool {
        switch self.state.lifecycle {
        case .shuttingDown, .shutDown:
            return true
        default:
            return false
        }
    }

    /// RE-S26: every entry point awaits `start`; `nil` when the engine serves, else the error to return.
    func ensureStarted() async -> AssetError? {
        switch self.state.lifecycle {
        case .running:
            return nil
        case .degraded(let reason):
            return .storageUnavailable(reason)
        case .shuttingDown, .shutDown:
            return .shutDown
        case .created, .starting:
            // REENTRANCY: RE-S26 — the lifecycle is re-read below: start may have degraded or shutdown begun.
            _ = await self.performStart()
            switch self.state.lifecycle {
            case .running:
                return nil
            case .degraded(let reason):
                return .storageUnavailable(reason)
            case .shuttingDown, .shutDown:
                return .shutDown
            case .created, .starting:
                // Start still runs, so the wait ended by this caller's own cancellation: `.shutDown` is reserved for
                // after shutdown (R-SYN-15).
                return .cancelled
            }
        }
    }

    // MARK: Start (ADR-028, ADR-029, ADR-039)

    /// Single-flight start in an owned task; the caller joins it, and its cancellation withdraws only its own token.
    func performStart() async -> Result<OpenReport, AssetError> {
        switch self.state.lifecycle {
        case .running:
            if let report = self.state.launch?.report {
                return .success(report)
            }
            return .failure(.shutDown)
        case .degraded(let reason):
            return .failure(.storageUnavailable(reason))
        case .shuttingDown, .shutDown:
            return .failure(.shutDown)
        case .created:
            self.state.lifecycle = .starting
            let task = self.spawn(.start) { engine in
                // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
                await engine.runStart()
            }
            self.state.startTask = task
            self.notifyObservers()
        case .starting:
            break
        }
        let token = self.nextToken()
        // REENTRANCY: RE-S25 — nothing: the body registers synchronously; the result arrives by value.
        return await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<OpenReport, AssetError>, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(.cancelled))
                } else if let settled = self.startSettlement() {
                    continuation.resume(returning: settled)
                } else {
                    self.state.startJoiners[token] = continuation
                    self.notifyObservers()
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop only withdraws this token.
                await self.withdrawStartJoiner(token)
            }
        }
    }

    /// The start result when it is already decided.
    private func startSettlement() -> Result<OpenReport, AssetError>? {
        switch self.state.lifecycle {
        case .running:
            return self.state.launch.map { .success($0.report) } ?? .failure(.shutDown)
        case .degraded(let reason):
            return .failure(.storageUnavailable(reason))
        case .shuttingDown, .shutDown:
            return .failure(.shutDown)
        case .created, .starting:
            return nil
        }
    }

    private func withdrawStartJoiner(_ token: InterestToken) {
        self.state.startJoiners.removeValue(forKey: token)?.resume(returning: .failure(.cancelled))
    }

    private func settleStart(_ result: Result<OpenReport, AssetError>) {
        let joiners = self.state.startJoiners
        self.state.startJoiners.removeAll()
        for token in joiners.keys.sorted() {
            joiners[token]?.resume(returning: result)
        }
        self.notifyObservers()
    }

    /// The start task: open, scope, version, source, launch reconciliation, staging GC, pack release, migration, due
    /// run (ADR-028 order).
    private func runStart() async {
        let report: OpenReport
        do {
            // REENTRANCY: RE-S01 — the lifecycle is re-checked below; shutdown closes the store after joining this
            // task, so nothing here closes it.
            report = try await self.store.open()
        } catch {
            guard !self.isShuttingDown else {
                self.settleStart(.failure(.shutDown))
                return
            }
            let reason = SyncEngine.unavailableReason(error)
            self.state.lifecycle = .degraded(reason)
            self.record(nil, .storage, "store open failed: \(error)")
            self.settleStart(.failure(.storageUnavailable(reason)))
            return
        }
        guard !self.isShuttingDown else {
            self.settleStart(.failure(.shutDown))
            return
        }
        self.state.generation = report.generation
        self.state.lastIndexGeneration = report.generation
        self.state.lastStamp = report.stamp
        self.state.retentionSequence += 1
        var pushed = self.state.retentionSequence
        // REENTRANCY: f-1 (proposed) — the lifecycle; the scope pushed is the one in force now; a scope set while
        // start still runs is pushed again before the engine is marked running (below).
        await self.store.setRetentionScope(self.state.retentionScope)
        // REENTRANCY: RE-S02 — the lifecycle.
        let version = await self.environment.appVersion.currentAppVersion()
        guard !self.isShuttingDown else {
            self.settleStart(.failure(.shutDown))
            return
        }
        self.state.launch = LaunchFacts(report: report, appVersion: version)
        let sink: StoreStagingSink
        do {
            // REENTRANCY: f-1 (proposed) — the lifecycle.
            sink = try await self.store.makeStagingSink()
        } catch {
            if !self.isShuttingDown {
                // No start task is left to settle later callers: the engine degrades, as for a failed open.
                let reason = SyncEngine.unavailableReason(error)
                self.state.lifecycle = .degraded(reason)
                self.record(nil, .storage, "staging unavailable: \(error)")
            }
            self.settleStart(.failure(self.isShuttingDown ? .shutDown : error.assetError))
            return
        }
        self.state.staging = sink
        do {
            // REENTRANCY: RE-S03 — the lifecycle: a source built after shutdown began is invalidated at once.
            let remote = try await self.environment.remoteSources.makeRemoteSource(
                configuration: self.configuration.remote,
                staging: sink,
                log: self.log
            )
            guard !self.isShuttingDown else {
                // REENTRANCY: RE-S03 — terminal: nothing is read afterwards.
                await remote.invalidate()
                self.settleStart(.failure(.shutDown))
                return
            }
            self.state.remote = remote
        } catch {
            self.state.remoteError = error
            self.record(nil, .rejected, "remote source unavailable: \(error)")
        }
        guard !self.isShuttingDown else {
            self.settleStart(.failure(.shutDown))
            return
        }
        // REENTRANCY: RE-S28 — the lifecycle; the reconciliation plan is computed after all three reads.
        let reconciledPublication = await self.reconcileLaunch(sink: sink)
        guard !self.isShuttingDown else {
            self.settleStart(.failure(.shutDown))
            return
        }
        // REENTRANCY: RE-S34 — the lifecycle; the report is the store's durable capture.
        await self.releaseSourceCopies()
        guard !self.isShuttingDown else {
            self.settleStart(.failure(.shutDown))
            return
        }
        while self.state.retentionSequence != pushed {
            // `setRetentionScope` during start only replaced the engine's copy (it pushes only while running): push
            // the newest scope, until none is set meanwhile; the engine is marked running in the turn of the last
            // check, after which every scope pushes itself.
            pushed = self.state.retentionSequence
            // REENTRANCY: f-1 (proposed) — the lifecycle; the sequence is compared again by the loop.
            await self.store.setRetentionScope(self.state.retentionScope)
            guard !self.isShuttingDown else {
                self.settleStart(.failure(.shutDown))
                return
            }
        }
        self.state.lifecycle = .running
        self.state.migration.pending = report.legacyMigrationPending
        self.broadcast(.clientStarted(generation: report.generation))
        if let snapshot = self.state.launch {
            self.settleStart(.success(snapshot.report))
        }
        if report.legacyMigrationPending {
            self.startMigration()
        }
        if RefreshDecision.isSyncDue(
            policy: self.configuration.refresh,
            stamp: report.stamp,
            syncDueFlag: report.syncDue,
            appVersion: version,
            now: self.environment.time.now(),
            syncedThisLaunch: false
        ) {
            if self.state.migration.running {
                self.state.migration.launchRunWaiting = true
            } else {
                self.startRun(trigger: .launch, mode: .force)
            }
        }
        self.pump()
        self.reconcileIdle()
        if reconciledPublication {
            // Launch reconciliation published a staged file at bulk urgency while the engine was starting, when no
            // re-read reaches the heap (`refreshStoreDeadline` applies only while running): its trailing install is
            // scheduled now, so the adopted asset reaches the readers' snapshot even when no launch run follows
            // (orchestrator ruling L5K-R16).
            // REENTRANCY: RE-S40 — the lifecycle (inside); the heap's store entry is replaced by the newest deadline.
            await self.refreshStoreDeadlineAfterPublish()
        }
    }

    /// The applied entries that are not present (absent or stale, never failed), by transfer: what launch
    /// reconciliation may attach, adopt or resume. Off the actor (C2), like the planner.
    @concurrent
    nonisolated static func wantedTransfers(_ view: StorePlanningView) async -> [TransferID: [ManifestEntry]] {
        var wanted: [TransferID: [ManifestEntry]] = [:]
        for entry in view.appliedManifest.entries {
            let record = view.records[entry.identifier]
            if record?.referencedBlob != nil, record?.isStale == false {
                continue
            }
            if case .failed? = record?.residency {
                continue
            }
            wanted[entry.transferID, default: []].append(entry)
        }
        return wanted
    }

    /// The `StorageUnavailableReason` of a failed open.
    static func unavailableReason(_ error: StoreError) -> StorageUnavailableReason {
        if case .storageUnavailable(let reason) = error.assetError {
            return reason
        }
        return .ioFailure
    }

    /// Launch reconciliation (ADR-028): re-attached transfers, then the staging inventory, then the plan against
    /// the applied entries that are not present; then staging GC keeping every claim. `true` when it asked the store to
    /// publish a staged file (at bulk urgency), whose trailing install the caller schedules once the engine runs.
    private func reconcileLaunch(sink: StoreStagingSink) async -> Bool {
        guard let remote = self.state.remote else {
            return false
        }
        // REENTRANCY: RE-S28 — the lifecycle; this is the first of the three reads the plan needs.
        let live = await remote.reattachedTransfers()
        guard !self.isShuttingDown else {
            return false
        }
        let inventory: StagingInventory
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S28 — the lifecycle; staging is listed after the source's transfers (ADR-028).
            inventory = try await self.store.stagingInventory()
            // REENTRANCY: RE-S37 — the lifecycle; the view is a snapshot.
            view = try await self.store.planningView()
        } catch {
            return false
        }
        guard !self.isShuttingDown else {
            return false
        }
        self.adoptApplied(view.appliedManifest, etag: view.stamp?.manifestETag)
        // REENTRANCY: RE-S28 — the lifecycle; the wanted set is computed off the actor from the view, a value (C2: one
        // pass over up to `maxEntries` entries).
        let wanted = await SyncEngine.wantedTransfers(view)
        guard !self.isShuttingDown else {
            return false
        }
        var published = false
        let actions = TransferReconciler.plan(live: live, staged: inventory, wanted: Set(wanted.keys))
        for action in actions {
            switch action {
            case .attach(let name):
                // The source joins its live task when the job starts this transfer again (no duplicate, H-6).
                for entry in wanted[name.transfer] ?? [] {
                    self.addSystemInterest(entry: entry, lane: .bulk)
                }
            case .cancel(let name):
                // REENTRANCY: RE-S41 — the plan's remaining steps run against the inventory captured before.
                await remote.cancelTransfer(name)
            case .discard(let name):
                // REENTRANCY: f-3 (proposed) — nothing: an idempotent removal; the plan's steps continue.
                await sink.discard(name)
            case .resume(let name):
                // REENTRANCY: f-2 (proposed) — the lifecycle; the resume point is kept only for a transfer still
                // wanted, and a sidecar that vanished means a fresh start.
                if let sidecar = await sink.readSidecar(for: name) {
                    self.state.launchResumes[name.transfer] = ResumePoint(previous: name, offset: sidecar.receivedBytes, validator: sidecar.validator)
                }
            case .adoptStaged(let name):
                guard let entries = wanted[name.transfer], let first = entries.first else {
                    continue
                }
                let size = inventory.items[name]?.byteSize ?? 0
                let file = StagedFile(name: name, byteCount: size, resumed: false, httpStatus: nil, etag: nil)
                published = true
                do {
                    // REENTRANCY: RE-S14 — the lifecycle; the result is bound to the ids the store still finds with
                    // this identity.
                    _ = try await self.store.publish(file, binding: entries.map(\.identifier).sorted(), expecting: first.contentIdentity, urgency: .bulk)
                } catch {
                    // REENTRANCY: f-3 (proposed) — nothing: the staged copy is of no use any more.
                    await sink.discard(name)
                }
            }
            guard !self.isShuttingDown else {
                return published
            }
        }
        var claims = Set(self.state.jobs.keys)
        claims.formUnion(self.state.launchResumes.keys)
        do {
            // REENTRANCY: RE-S39 — the lifecycle; the kept set was computed before the await and claims every
            // transfer still worked on (C-9).
            _ = try await self.store.collectStaging(keeping: claims)
        } catch {
            self.record(nil, .storage, "launch staging collection failed: \(error)")
        }
        return published
    }

    // MARK: Shutdown (R-SYN-15, ADR-039, ADR-042)

    /// Single-flight and idempotent: cancel and join every owned task, resume every continuation with `.shutDown`,
    /// invalidate the source, close the store, publish `clientShutDown` last.
    ///
    /// Whatever state it begins in, `created` included, it returns only once every owned task is cancelled and joined
    /// (orchestrator ruling L5-R2, R-SYN-15): `spawn` allows owned tasks in `created`, and three spawn sites are
    /// reachable there: the memory-pressure observer, a group's join, and the release follow-up (`continueReleases`,
    /// which continues in any state but shutdown). From `created` it still never opens the store and never
    /// logs: there is no source to invalidate and no store to close (`launch` and `startTask` are `nil`), and a joined
    /// group join's `ensureStarted()` refuses once `shuttingDown`, so it cannot start the engine.
    func performShutdown() async {
        switch self.state.lifecycle {
        case .shutDown:
            return
        case .shuttingDown:
            let token = self.nextToken()
            // REENTRANCY: RE-S25 — nothing: a joiner of the running shutdown; resumed when it ends.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if self.state.lifecycle == .shutDown {
                    continuation.resume()
                } else {
                    self.state.shutdownJoiners[token] = continuation
                }
            }
            return
        case .created, .starting, .running, .degraded:
            break
        }
        self.state.lifecycle = .shuttingDown
        self.notifyObservers()
        for key in self.state.tasks.keys.sorted() {
            self.state.tasks[key]?.cancel()
        }
        self.cancelRunningHandles()
        // REENTRANCY: RE-S43 (proposed) — the drain is answered and freed over bounded turns (C2); the lifecycle is
        // `shuttingDown`, so nothing new spawns or registers, and the join loop below drains again after each join.
        await self.settle(self.drainEverything(with: .shutDown), with: .shutDown)
        // Join every owned task: tasks that end during the loop remove themselves; the loop iterates a copy.
        while let key = self.state.tasks.keys.min(), let task = self.state.tasks[key] {
            // REENTRANCY: RE-S21 — the lifecycle is `shuttingDown`, so nothing new spawns; the table is re-read.
            await task.value
            self.state.tasks[key] = nil
            // REENTRANCY: RE-S43 (proposed) — as above; what the joined task left (none registers while shutting
            // down) is drained.
            await self.settle(self.drainEverything(with: .shutDown), with: .shutDown)
        }
        if let remote = self.state.remote {
            // REENTRANCY: RE-S22 — terminal: returns after the foreground delegate's last callback (T2-04).
            await remote.invalidate()
        }
        if self.state.launch != nil || self.state.startTask != nil {
            // REENTRANCY: RE-S22 — terminal: every owned task is joined, so no store call is in flight.
            await self.store.close()
        }
        self.finishShutdown()
    }

    /// Publishes `clientShutDown` last, ends the lifecycle and releases every observer and joiner.
    private func finishShutdown() {
        self.broadcast(.clientShutDown)
        self.state.lifecycle = .shutDown
        let joiners = self.state.shutdownJoiners
        self.state.shutdownJoiners.removeAll()
        for token in joiners.keys.sorted() {
            joiners[token]?.resume()
        }
        self.notifyObservers()
        let observers = self.state.observers
        self.state.observers.removeAll()
        for id in observers.keys.sorted() {
            observers[id]?.continuation.resume()
        }
        let conditions = self.state.conditionObservers
        self.state.conditionObservers.removeAll()
        for id in conditions.keys.sorted() {
            conditions[id]?.continuation.resume()
        }
    }
}
