import Foundation
import ZTronAssetModel
import ZTronAssetStorage

extension SyncEngine {
    // MARK: sync (R-SYN-6, R-SYN-9)

    /// Single-flight run: a second caller joins the active run and receives its outcome; `.ifDue` asks the refresh
    /// policy first.
    func performSync(_ mode: SyncMode) async -> SyncOutcome {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failed(error)
        }
        if self.state.run == nil, mode == .ifDue {
            let view: StorePlanningView
            do {
                // REENTRANCY: RE-S38 — the lifecycle; the answer is the store's snapshot.
                view = try await self.store.planningView()
            } catch {
                return .failed(error.assetError)
            }
            guard self.isRunning else {
                return .failed(.shutDown)
            }
            let due = RefreshDecision.isSyncDue(
                policy: self.configuration.refresh,
                stamp: view.stamp,
                syncDueFlag: view.syncDue,
                appVersion: self.state.launch?.appVersion ?? "",
                now: self.environment.time.now(),
                syncedThisLaunch: self.state.syncedThisLaunch
            )
            if !due, self.state.run == nil {
                return .notDue(lastSyncedAt: view.stamp?.completedAt)
            }
        }
        if self.state.run == nil {
            self.startRun(trigger: .explicit, mode: mode)
        }
        guard self.state.run != nil else {
            return .failed(.shutDown)
        }
        let token = self.nextToken()
        // REENTRANCY: RE-S25 — nothing: the body registers synchronously; the outcome arrives by value.
        return await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<SyncOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failed(.cancelled))
                } else if self.state.run == nil {
                    continuation.resume(returning: .failed(self.isShuttingDown ? .shutDown : .cancelled))
                } else {
                    self.state.syncJoiners[token] = continuation
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop only withdraws this joiner; the run continues for the others.
                await self.withdrawSyncJoiner(token)
            }
        }
    }

    private func withdrawSyncJoiner(_ token: InterestToken) {
        self.state.syncJoiners.removeValue(forKey: token)?.resume(returning: .failed(.cancelled))
    }

    /// Starts a run in an owned task (at most one).
    func startRun(trigger: SyncTrigger, mode: SyncMode) {
        guard self.isRunning, self.state.run == nil else {
            return
        }
        self.state.pendingRun = nil
        self.state.heap.remove(.pendingRun)
        self.state.lastRunID += 1
        let token = self.nextToken()
        let run = RunState(
            id: SyncRunID(rawValue: self.state.lastRunID),
            token: token,
            trigger: trigger,
            mode: mode,
            startedAt: self.environment.time.now(),
            purgeEpoch: self.state.purgeEpoch
        )
        self.state.run = run
        // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
        guard self.spawn(.run, { engine in await engine.performRun(token) }) != nil else {
            self.state.run = nil
            return
        }
        self.broadcast(.syncStarted(run.id, trigger))
        self.ensureWatcher()
        self.notifyObservers()
    }

    /// The run task (sync.md §12.5; RE-S04…RE-S11).
    private func performRun(_ token: InterestToken) async {
        // REENTRANCY: RE-S10 — the run token: the outcome is delivered only while this run is still the active one.
        let outcome = await self.runSteps(token)
        guard let run = self.state.run, run.token == token else {
            return
        }
        self.finishRun(run, outcome: outcome)
    }

    /// The steps up to the outcome.
    private func runSteps(_ token: InterestToken) async -> SyncOutcome {
        // REENTRANCY: RE-S04 — the lifecycle and the run token, re-checked by `stillCurrent`.
        let fetched = await self.fetchManifest(token, deadline: true)
        guard self.stillCurrent(token) else {
            return .failed(self.isShuttingDown ? .shutDown : .cancelled)
        }
        var manifest: ValidatedManifest?
        var etag = self.state.appliedETag
        switch fetched {
        case .fetched(let newer, let tag, _):
            manifest = newer
            etag = tag
            self.state.run?.manifestFresh = true
        case .notModified:
            self.state.run?.manifestFresh = true
        case .timedOut:
            break
        case .failed(let error):
            let assetError = error.assetError(now: self.environment.time.now())
            if case .offline = error {
                self.setPendingRun(.conditions, trigger: .conditionsChanged)
            }
            return .failed(assetError)
        case .invalid:
            return .failed(.serverUnavailable(retryAfter: nil))
        case .circuitOpen(let cause):
            self.setPendingRun(.breaker, trigger: .breakerClosed)
            return .blocked(.circuitOpen(cause), self.report(manifestFresh: false))
        case .throttled(let until):
            self.setPendingRun(.throttle, trigger: .explicit)
            return .blocked(.throttled(until: until), self.report(manifestFresh: false))
        case .cancelled:
            return .failed(.cancelled)
        case .shutDown:
            return .failed(.shutDown)
        }
        let space: FreeSpace
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S06 — the lifecycle and the run token.
            space = try await self.store.freeSpace()
            guard self.stillCurrent(token) else {
                return .failed(self.isShuttingDown ? .shutDown : .cancelled)
            }
            // REENTRANCY: RE-S37 — the lifecycle and the run token; the view is a snapshot `apply` re-validates.
            view = try await self.store.planningView()
        } catch {
            return .failed(error.assetError)
        }
        guard self.stillCurrent(token) else {
            return .failed(self.isShuttingDown ? .shutDown : .cancelled)
        }
        self.state.freeSpace = space
        self.state.committedSinceRead = 0
        let target = manifest ?? view.appliedManifest
        let scope = self.state.retentionScope
        let policy = PlanningPolicy(storage: self.configuration.storage, includeOnDemand: scope.isExplicit, now: self.environment.time.now())
        let number = self.state.lastRunID
        let interval = self.log.interval(.plan, category: .sync, "run \(number)")
        // REENTRANCY: RE-S07 — the lifecycle and the run token; the store may have advanced (apply diffs anyway).
        var plan = await SyncEngine.planOffActor(self.planner, manifest: target, view: view, scope: scope, policy: policy, space: space)
        interval.end()
        guard self.stillCurrent(token) else {
            return .failed(self.isShuttingDown ? .shutDown : .cancelled)
        }
        var eviction: EvictionPlan?
        if case .needsEviction(let bytes) = plan.space {
            // REENTRANCY: RE-S37 — the lifecycle and the run token; the dry run is a snapshot `apply` re-validates.
            eviction = await self.store.evictionPlan(toFree: bytes, protecting: Set(plan.fetches.map(\.id)))
            guard self.stillCurrent(token) else {
                return .failed(self.isShuttingDown ? .shutDown : .cancelled)
            }
            if eviction == nil {
                var fallback = policy
                fallback.evictionPermitted = false
                // REENTRANCY: RE-S07 — as above.
                plan = await SyncEngine.planOffActor(self.planner, manifest: target, view: view, scope: scope, policy: fallback, space: space)
                guard self.stillCurrent(token) else {
                    return .failed(self.isShuttingDown ? .shutDown : .cancelled)
                }
            }
        }
        if case .insufficient(let required, let available) = plan.space {
            // Decided on pure data before any mutation (R-SYN-11): nothing was written.
            return .failed(.insufficientSpace(required: required, available: available))
        }
        let report: ApplyReport
        do {
            // REENTRANCY: RE-S09 — jobs of pruned ids end (T21), jobs whose identity changed follow (T22); no
            // generation guard (sync-1 S1-12).
            report = try await self.store.apply(target, etag: etag, eviction: eviction)
        } catch {
            return .failed(error.assetError)
        }
        guard self.stillCurrent(token) else {
            return .failed(self.isShuttingDown ? .shutDown : .cancelled)
        }
        self.applied(target, etag: etag, report: report)
        self.state.run?.applyReport = report
        self.state.run?.planned = plan.totals
        self.state.run?.fetches = plan.fetches
        self.state.run?.stampETag = etag
        self.state.run?.stampDigest = target.digest
        if case .partial = plan.space {
            self.state.run?.overBudget = true
        }
        self.recordSkippedFailures(plan, view: view)
        self.state.run?.transferring = true
        self.releaseSystemReattachments()
        // REENTRANCY: RE-S40 — the lifecycle; the heap's store entry is replaced (apply committed).
        await self.refreshStoreDeadline()
        guard self.stillCurrent(token) else {
            return .failed(self.isShuttingDown ? .shutDown : .cancelled)
        }
        self.pump()
        // REENTRANCY: RE-S10 — the outcome is computed from the run ledger at resume time.
        let settlement = await self.awaitRunSettlement(token)
        guard let run = self.state.run, run.token == token else {
            return .failed(self.isShuttingDown ? .shutDown : .cancelled)
        }
        switch settlement {
        case .shutDown:
            return .failed(.shutDown)
        case .cancelled:
            return .failed(.cancelled)
        case .blocked(let reason):
            return .blocked(reason, self.report(manifestFresh: run.manifestFresh))
        case .finished:
            let summary = self.report(manifestFresh: run.manifestFresh)
            guard run.failures.isEmpty, !run.overBudget else {
                return .completeWithFailures(summary)
            }
            if let launch = self.state.launch, let digest = run.stampDigest {
                let stamp = SyncStamp(appVersion: launch.appVersion, completedAt: self.environment.time.now(), manifestETag: run.stampETag, manifestDigest: digest)
                do {
                    // REENTRANCY: RE-S11 — the lifecycle; `.purgeRaced` leaves the sync due.
                    try await self.store.markSynced(stamp, ifPurgeEpoch: view.purgeEpoch)
                } catch .purgeRaced {
                    return .failed(.cancelled)
                } catch {
                    return .completeWithFailures(summary)
                }
                guard self.isRunning else {
                    return .failed(.shutDown)
                }
            }
            self.state.syncedThisLaunch = true
            return .complete(summary)
        }
    }

    /// Runs the planner off the actor (C2, RE-S07): a nonisolated, concurrent function.
    @concurrent
    nonisolated static func planOffActor(
        _ planner: any SyncPlanning,
        manifest: ValidatedManifest,
        view: StorePlanningView,
        scope: AssetScope,
        policy: PlanningPolicy,
        space: FreeSpace
    ) async -> SyncPlan {
        planner.plan(manifest: manifest, snapshot: view, scope: scope, policy: policy, freeSpace: space)
    }

    /// Whether the run with `token` is still the active run of a running engine and no purge ended it (a run that
    /// settled by itself, finished or blocked, is still current: its task computes the outcome).
    private func stillCurrent(_ token: InterestToken) -> Bool {
        guard self.isRunning, let run = self.state.run, run.token == token else {
            return false
        }
        switch run.settlement {
        case .cancelled?, .shutDown?:
            return false
        case .finished?, .blocked?, nil:
            return true
        }
    }

    /// Waits for the run's settlement (a token-keyed continuation, settled at once when it already is, S1-02).
    private func awaitRunSettlement(_ token: InterestToken) async -> RunSettlement {
        // REENTRANCY: RE-S10 — nothing: the body checks and registers synchronously.
        await withCheckedContinuation { (continuation: CheckedContinuation<RunSettlement, Never>) in
            if let settled = self.state.run?.settlement {
                continuation.resume(returning: settled)
            } else if self.state.run?.token != token || !self.isRunning {
                continuation.resume(returning: self.isShuttingDown ? .shutDown : .cancelled)
            } else {
                self.state.runCompletions[token] = continuation
                self.checkRunSettled()
            }
        }
    }

    /// The engine's side of a committed `apply`: the applied copy, pruned jobs (T21), changed identities (T22),
    /// removal events and the generation.
    private func applied(_ manifest: ValidatedManifest, etag: ETag?, report: ApplyReport) {
        self.adoptApplied(manifest, etag: etag)
        self.state.generation = max(self.state.generation, report.generation)
        for id in report.pruned {
            self.broadcast(.assetRemoved(id, .pruned))
        }
        self.broadcast(.snapshotChanged(generation: self.state.generation))
        for transfer in self.state.jobs.keys.sorted() {
            guard let job = self.state.jobs[transfer] else {
                continue
            }
            switch job.state {
            case .verifying, .committing:
                continue
            default:
                break
            }
            let moved = job.assets.filter { self.state.applied.entry(for: $0)?.transferID != transfer }
            guard !moved.isEmpty else {
                continue
            }
            if moved.count == job.assets.count {
                if job.state == .downloading {
                    self.stop(transfer, .cancel)
                    if let attempt = job.active?.attempt {
                        self.state.draining[transfer] = attempt
                    }
                }
                self.supersede(transfer)
            } else {
                self.state.jobs[transfer]?.assets.subtract(moved)
                for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) {
                    for asset in interest.assets where moved.contains(asset) {
                        self.state.jobs[transfer]?.interests[token]?.assets.remove(asset)
                        self.reroute(token, interest: interest, asset: asset)
                    }
                    if self.state.jobs[transfer]?.interests[token]?.assets.isEmpty == true {
                        self.removeInterest(token, from: transfer)
                    }
                }
            }
        }
    }

    /// Skipped entries whose records failed until their entry changes count as the run's failures (a run with them
    /// never ends `.complete`, so the sync stays due).
    private func recordSkippedFailures(_ plan: SyncPlan, view: StorePlanningView) {
        for skip in plan.skipped {
            let error: AssetError
            let failureClass: FailureClass
            switch skip.reason {
            case .failedUntilEntryChanges:
                if case .failed(.notFound)? = view.records[skip.id]?.residency {
                    error = .notFound
                    failureClass = .notFound
                } else {
                    error = .integrityFailure
                    failureClass = .integrity
                }
            case .integrityQuarantined:
                error = .integrityFailure
                failureClass = .integrity
            case .outOfScope, .onDemandPolicy, .unverifiedDisallowed, .overBudget:
                continue
            }
            self.state.run?.failures[skip.id] = AssetFailure(id: skip.id, error: error, failureClass: failureClass)
        }
    }

    /// Releases the system interests launch re-attachment created: the run now holds its own (sync.md §7.1).
    private func releaseSystemReattachments() {
        for transfer in self.state.jobs.keys.sorted() {
            guard let job = self.state.jobs[transfer] else {
                continue
            }
            for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) where interest.kind == .system {
                let healing = interest.assets.contains { self.state.heals[$0] != nil }
                if !healing {
                    self.removeInterest(token, from: transfer)
                }
            }
        }
    }

    // MARK: Materialisation and settling (S1-15, RE-S10)

    /// Turns planned fetches into jobs while fewer than the pipeline plus `runLookahead` of the run's jobs exist.
    func materializeRun() {
        guard let run = self.state.run, run.transferring, run.settlement == nil else {
            return
        }
        let limit = self.tuning.pipelineDepth * self.tuning.maxConcurrentTransfers + self.tuning.runLookahead
        var cursor = run.cursor
        var outstanding = run.outstanding.count
        while cursor < run.fetches.count, outstanding < max(1, limit) {
            let fetch = run.fetches[cursor]
            cursor += 1
            self.state.run?.cursor = cursor
            if self.state.run?.outstanding[fetch.transfer] == nil {
                outstanding += 1
            }
            self.state.run?.outstanding[fetch.transfer, default: []].insert(fetch.id)
            self.addInterest(run.token, asset: fetch.id, entry: fetch.entry, lane: .bulk, kind: .run)
        }
    }

    /// Records a job's outcome for the run.
    func recordRunOutcome(_ outcome: InterestOutcome, transfer: TransferID, assets: Set<AssetID>) {
        guard var run = self.state.run else {
            return
        }
        run.outstanding[transfer] = nil
        switch outcome {
        case .committed(let locations):
            run.fetched += assets.filter { locations[$0] != nil }.count
            for asset in assets.sorted() where locations[asset] == nil {
                run.failures[asset] = AssetFailure(id: asset, error: .notFound, failureClass: .notFound)
            }
        case .failed(let error):
            let failureClass = SyncEngine.failureClass(of: error)
            for asset in assets.sorted() {
                run.failures[asset] = AssetFailure(id: asset, error: error, failureClass: failureClass)
            }
        }
        self.state.run = run
        self.offerRunProgress()
    }

    /// The metrics class of an engine error.
    static func failureClass(of error: AssetError) -> FailureClass {
        switch error {
        case .offline:
            return .offline
        case .authRejected:
            return .authentication
        case .notFound:
            return .notFound
        case .insufficientSpace:
            return .insufficientSpace
        case .integrityFailure:
            return .integrity
        case .serverUnavailable:
            return .serverError
        case .cancelled, .shutDown:
            return .transient
        case .storageUnavailable:
            return .storage
        }
    }

    /// Adds received bytes to the run that wants `transfer`.
    func noteRunBytes(_ transfer: TransferID, _ bytes: Int64) {
        guard self.state.run?.outstanding[transfer] != nil else {
            return
        }
        let total = PlanBuilder.adding(self.state.run?.bytes ?? 0, bytes)
        self.state.run?.bytes = total
    }

    /// Settles the run when every planned fetch ended, or when every remaining job is blocked (sync.md §12.5); a
    /// blocked run drops its interests and leaves a pending run for its gate.
    func checkRunSettled() {
        guard let run = self.state.run, run.transferring, run.settlement == nil else {
            return
        }
        self.materializeRun()
        guard let current = self.state.run else {
            return
        }
        if current.cursor >= current.fetches.count, current.outstanding.isEmpty {
            self.settleRun(.finished)
            return
        }
        guard !current.outstanding.isEmpty else {
            return
        }
        var reasons: [BlockReason] = []
        for transfer in current.outstanding.keys.sorted() {
            guard let job = self.state.jobs[transfer] else {
                continue
            }
            switch job.state {
            case .blocked(.awaitingSpace):
                return
            case .blocked(let reason):
                reasons.append(reason)
            case .failed(.whenOnline):
                reasons.append(.offline)
            default:
                return
            }
        }
        guard let first = reasons.first else {
            return
        }
        let reason = reasons.contains(.offline) ? .offline : first
        for transfer in current.outstanding.keys.sorted() {
            self.removeInterest(current.token, from: transfer)
        }
        switch reason {
        case .offline, .policy:
            self.setPendingRun(.conditions, trigger: .conditionsChanged)
        case .circuitOpen:
            self.setPendingRun(.breaker, trigger: .breakerClosed)
        case .throttled:
            self.setPendingRun(.throttle, trigger: .explicit)
        case .awaitingSpace, .insufficientSpace:
            break
        }
        self.settleRun(.blocked(reason))
    }

    /// Records the settlement and resumes the run's wait.
    func settleRun(_ settlement: RunSettlement) {
        guard var run = self.state.run, run.settlement == nil else {
            return
        }
        run.settlement = settlement
        self.state.run = run
        self.state.runCompletions.removeValue(forKey: run.token)?.resume(returning: settlement)
        self.notifyObservers()
    }

    /// The run's report as of now.
    private func report(manifestFresh: Bool) -> SyncReport {
        let run = self.state.run
        let failures = (run?.failures.values.map { $0 } ?? []).sorted { $0.id < $1.id }
        return SyncReport(
            runID: run?.id ?? SyncRunID(rawValue: 0),
            trigger: run?.trigger ?? .explicit,
            startedAt: run?.startedAt ?? self.environment.time.now(),
            finishedAt: self.environment.time.now(),
            manifestFresh: manifestFresh,
            planned: run?.planned ?? PlanTotals(),
            fetched: run?.fetched ?? 0,
            reused: run?.applyReport?.reused.count ?? 0,
            relocated: run?.applyReport?.relocated.count ?? 0,
            pruned: run?.applyReport?.pruned.count ?? 0,
            evicted: run?.applyReport?.evicted.count ?? 0,
            failedCount: failures.count,
            bytesDownloaded: run?.bytes ?? 0,
            failures: Array(failures.prefix(1_000))
        )
    }

    /// Ends the run: joiners resumed, `syncFinished` published, pack release after adoption, pending work started.
    private func finishRun(_ run: RunState, outcome: SyncOutcome) {
        if let completion = self.state.runCompletions.removeValue(forKey: run.token) {
            completion.resume(returning: .cancelled)
        }
        for transfer in run.outstanding.keys.sorted() {
            self.removeInterest(run.token, from: transfer)
        }
        for transfer in self.state.jobs.keys.sorted() where self.state.jobs[transfer]?.interests[run.token] != nil {
            self.removeInterest(run.token, from: transfer)
        }
        self.state.run = nil
        self.retireProgress(.run)
        let joiners = self.state.syncJoiners
        self.state.syncJoiners.removeAll()
        for token in joiners.keys.sorted() {
            joiners[token]?.resume(returning: outcome)
        }
        self.broadcast(.syncFinished(run.id, outcome))
        if self.isRunning, run.fetched > 0 || (run.applyReport?.reused.isEmpty == false), self.state.remote?.capabilities.keepsSourceCopies == true {
            self.spawn(.entry) { engine in
                // REENTRANCY: RE-S34 — the lifecycle; the report is the store's durable capture.
                await engine.releaseSourceCopies()
            }
        }
        if case .failed(.shutDown) = outcome {
            return
        }
        self.pump()
        self.reconcileIdle()
    }

    // MARK: Pending runs (sync-2 S2-03, S2-25)

    /// Remembers a run to start when `gate` opens.
    func setPendingRun(_ gate: PendingRunGate, trigger: SyncTrigger) {
        guard self.isRunning else {
            return
        }
        self.state.pendingRun = PendingRun(gate: gate, trigger: trigger)
        switch gate {
        case .throttle:
            if let origin = self.state.remote?.originID, let until = self.state.throttles[origin] {
                self.state.heap.schedule(.pendingRun, at: until)
                self.state.pendingRun?.scheduled = true
                self.rearm()
            }
        case .breaker:
            self.scheduleBreakerDeadline()
        case .conditions:
            self.considerPendingRun()
        }
        self.ensureWatcher()
        self.notifyObservers()
    }

    /// Schedules a conditions-gated pending run once bulk work is admitted (debounced).
    func considerPendingRun() {
        guard let pending = self.state.pendingRun, pending.gate == .conditions else {
            return
        }
        if self.laneVerdict(.bulk) == .admit {
            if !pending.scheduled {
                let at = self.environment.time.monotonicNow().adding(seconds: max(0, self.tuning.pendingRunDebounce))
                self.state.heap.schedule(.pendingRun, at: at)
                self.state.pendingRun?.scheduled = true
                self.rearm()
            }
        } else if pending.scheduled {
            self.state.heap.remove(.pendingRun)
            self.state.pendingRun?.scheduled = false
            self.rearm()
        }
    }

    /// Starts the pending run now.
    func fulfilPendingRun() {
        guard let pending = self.state.pendingRun, self.state.run == nil else {
            return
        }
        self.state.pendingRun = nil
        self.state.heap.remove(.pendingRun)
        self.startRun(trigger: pending.trigger, mode: .force)
    }

    // MARK: Source copies (R-CLN-10, RE-S34)

    /// Reports the durable adoption to a source that keeps copies, so it can release packs (ADR-027).
    func releaseSourceCopies() async {
        guard let remote = self.state.remote, remote.capabilities.keepsSourceCopies else {
            return
        }
        do {
            // REENTRANCY: RE-S34 — the lifecycle; the report is captured before the store's durable commit.
            let report = try await self.store.adoptionReport()
            guard !self.isShuttingDown else {
                return
            }
            // REENTRANCY: RE-S34 — a release that races an eviction of a reported entry costs only a re-download.
            let reclaim = await remote.reclaimSourceCopies(report)
            if !reclaim.failed.isEmpty {
                self.record(nil, .transient, "\(reclaim.failed.count) source copies could not be released")
            }
        } catch {
            self.record(nil, .storage, "adoption report failed: \(error)")
        }
    }

    // MARK: Legacy migration (ADR-029, ruling R9)

    /// Starts the migration loop in an owned task.
    func startMigration() {
        guard self.state.migration.pending, !self.state.migration.running else {
            return
        }
        self.state.migration.running = true
        self.state.migration.deferred = false
        self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            await engine.migrateLoop()
        }
    }

    /// Calls `migrateLegacy` again while not finished; backs off to the next maintenance window when a call leaves
    /// nothing remaining yet is not finished (RE-S29).
    private func migrateLoop() async {
        defer {
            self.state.migration.running = false
            if self.state.migration.launchRunWaiting, self.isRunning {
                self.state.migration.launchRunWaiting = false
                self.startRun(trigger: .launch, mode: .force)
            }
        }
        while self.isRunning, !Task.isCancelled {
            let progress: LegacyMigrationProgress
            do {
                // REENTRANCY: RE-S29 — the lifecycle; calls again while not finished and the engine runs.
                progress = try await self.store.migrateLegacy(maxFiles: 64)
            } catch {
                self.state.migration.deferred = true
                return
            }
            guard self.isRunning else {
                return
            }
            if progress.finished {
                self.state.migration.pending = false
                return
            }
            if progress.remaining == 0 {
                self.state.migration.deferred = true
                return
            }
        }
    }
}
