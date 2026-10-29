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
                    self.notifyObservers()
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
        // A breaker that admits only a probe gives it to this run's manifest fetch in this turn, before any later turn can
        // dispatch a job (F-42); its `circuitChanged` follows `syncStarted`. The run is in place first: the reservation
        // notifies the condition observers, which must not see a probe held for a run that does not exist yet (L4-R24(1);
        // Stage 3, S3-B-064).
        let held = self.reserveManifestProbe()
        // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
        guard self.spawn(.run, { engine in await engine.performRun(token) }) != nil else {
            self.state.run = nil
            if held != nil {
                self.releaseManifestProbe()
            }
            return
        }
        // A run that starts while the launch run waits for legacy migration takes its place (orchestrator ruling L5K-R1):
        // it applies the same manifest, and its jobs adopt the prior-art files migration has not reached yet
        // (`storedLocation(of:lane:)`), so the migration loop starts no second run when it ends, whether this run is still
        // active then or not, and no flag is left behind.
        self.state.migration.launchRunWaiting = false
        self.broadcast(.syncStarted(run.id, trigger))
        if let before = held, let origin = self.state.remote?.originID {
            self.breakerChanged(origin, from: before)
        }
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
        if let error = self.missingSourceError {
            return .failed(error)
        }
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
            if let cause = self.openBreakerCause() {
                // The fetch tripped the origin's breaker (a key-rejected 403 opens it at once): the run is blocked by
                // it and the half-open probe is the next run's manifest fetch (ARCHITECTURE §7.6, §7.7).
                self.setPendingRun(.breaker, trigger: .breakerClosed)
                return .blocked(.circuitOpen(cause), self.report(manifestFresh: false))
            }
            let assetError = error.assetError(now: self.environment.time.now())
            if case .offline = error {
                self.setOfflinePendingRun()
            }
            return .failed(assetError)
        case .invalid:
            return .failed(.serverUnavailable(retryAfter: nil))
        case .circuitOpen(let cause):
            self.setPendingRun(.breaker, trigger: .breakerClosed)
            return .blocked(.circuitOpen(cause), self.report(manifestFresh: false))
        case .throttled(let until):
            // The outcome's end was read in the fetch's turn; a transfer's 429 may have extended the origin's throttle
            // before this task resumed. The run reports the end the pending run waits for, the origin's (F-36, F-38).
            self.setPendingRun(.throttle, trigger: .explicit)
            return .blocked(.throttled(until: self.throttleEnd(after: until)), self.report(manifestFresh: false))
        case .cancelled:
            return .failed(.cancelled)
        case .shutDown:
            return .failed(.shutDown)
        }
        let space: FreeSpace
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S06 — the lifecycle and the run token; the read became the ledger's base in the turn it
            // returned (L4-R7), and parked jobs are re-evaluated against it there.
            space = try await self.readFreeSpace()
            if self.isRunning {
                self.reconsiderSpaceBlocked()
            }
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
        // REENTRANCY: RE-S09 — the run token below; the callee has followed a committed apply (T21, T22) whether or not
        // this run is still current (a purge may have ended it meanwhile).
        switch await self.applyAndFollow(target, etag: etag, eviction: eviction) {
        case .success(let committed):
            report = committed
        case .failure(let error):
            return .failed(error.assetError)
        }
        guard self.stillCurrent(token) else {
            if self.isRunning {
                // REENTRANCY: RE-S40 — the lifecycle; the heap's store entry is replaced (apply committed).
                await self.refreshStoreDeadline()
            }
            return .failed(self.isShuttingDown ? .shutDown : .cancelled)
        }
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
        self.releaseSystemReattachments(keeping: Set(plan.fetches.map(\.transfer)))
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
            // The settling turn read the throttle's end; this task resumes in a later turn, and a transfer's 429 handled
            // in between extends the origin's throttle (which moves the pending run with it, `throttleExtended`). The run
            // reports the end a fresh request gets, the origin's (close-out cycle 19, F-39).
            return .blocked(self.currentReason(reason), self.report(manifestFresh: run.manifestFresh))
        case .finished:
            let summary = self.report(manifestFresh: run.manifestFresh)
            guard run.failures.isEmpty, !run.overBudget else {
                return .completeWithFailures(summary)
            }
            guard run.manifestFresh else {
                // The manifest fetch passed its deadline: the run completed over the applied manifest, but nothing
                // says it is current, so the sync stays due (no stamp; F-15) and the next due check fetches it again.
                return .complete(summary)
            }
            if let launch = self.state.launch, let digest = run.stampDigest {
                let stamp = SyncStamp(appVersion: launch.appVersion, completedAt: self.environment.time.now(), manifestETag: run.stampETag, manifestDigest: digest)
                do {
                    // REENTRANCY: RE-S11 — the lifecycle; `.purgeRaced` leaves the sync due.
                    try await self.store.markSynced(stamp, ifPurgeEpoch: view.purgeEpoch)
                    self.state.lastStamp = stamp
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

    /// The cause of the origin's breaker while it is open and its gate rejects at `now` (`originGate`): a manifest fetch
    /// that tripped it ends the run blocked by it; one whose cooldown had already ended by its answer does not, as the
    /// gate admits the next run's probe (F-40).
    func openBreakerCause() -> BreakerCause? {
        guard let origin = self.state.remote?.originID, case .open(let cause, _, _)? = self.state.breakers[origin]?.state,
              !self.originGateNow().admitsBreakerParked else {
            return nil
        }
        return cause
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
                self.deliverRunSettlement(settled, to: continuation)
            } else if self.state.run?.token != token || !self.isRunning {
                continuation.resume(returning: self.isShuttingDown ? .shutDown : .cancelled)
            } else {
                self.state.runCompletions[token] = continuation
                self.checkRunSettled()
                // The registration is a mutation the test seams' conditions read (a run waiting for its settlement).
                self.notifyObservers()
            }
        }
    }

    /// The engine's side of a committed `apply` (a run's or `ensureAvailable`'s): the applied copy, pruned jobs (T21),
    /// changed identities (T22), removal events and the generation. `serial` is the ledger's forget serial when the
    /// apply began: its reuses are remembered only when nothing was forgotten during it. The removals announced are the
    /// store's prunes and every id the engine's copy listed that `manifest` does not (`prunesUnreported`), so what the
    /// engine announces never depends on which manifest the store diffed against (L4-R7, L4-R10).
    func applied(_ manifest: ValidatedManifest, etag: ETag?, report: ApplyReport, since serial: UInt64) {
        let unreported = self.prunesUnreported(by: report, in: manifest)
        let previous = self.state.applied
        self.adoptApplied(manifest, etag: etag)
        self.state.generation = max(self.state.generation, report.generation)
        // What the apply bound and unbound (L4-R5): a reused id is present at its new entry's content, so an interest
        // that follows it there is answered from the store. Relocations are not bindings (an absent record is relocated
        // too), and they leave the content, so no job moves for them.
        let trusted = self.state.ledgerForgets == serial
        self.forgetBound(report.contentChanged)
        if trusted {
            for id in report.reused {
                if let transfer = manifest.entry(for: id)?.transferID {
                    self.state.boundContent[id] = transfer
                }
            }
        }
        self.forgetBound(report.evicted)
        self.forgetBound(report.pruned)
        self.forgetBound(unreported)
        for id in report.pruned {
            self.broadcast(.assetRemoved(id, .pruned))
        }
        for id in unreported {
            self.broadcast(.assetRemoved(id, .pruned))
        }
        self.broadcast(.snapshotChanged(generation: self.state.generation))
        self.followApplied(from: previous)
    }

    /// The ids the engine's copy lists and `manifest` does not that the store's report leaves out, in the copy's order;
    /// read before the copy moves. The store diffs against its own manifest, which an `apply` that threw past its
    /// in-memory writes has already advanced (ADR-050): a later `apply` of that manifest, or of any manifest that also
    /// drops those ids, reports no prune for them, and the catch-up the failure owes then finds the copy equal to the
    /// store, so they would never be announced (review of close-out cycle 3, PROBE-C3-7). An id is announced when it
    /// leaves the copy, here or in `followStoreView`, so it is announced once: the engine follows its applies in the
    /// store's commit order (`takeApplyTurn`), so a report is never followed after a newer one (PROBE-C4-4), and a view
    /// is followed only when no `apply` was in flight during its read. Empty when the store diffed against the
    /// copy (its prunes are then exactly these ids). One pass over the copy with O(1) lookups (about 6 to 8 ms for
    /// 100,000 ids, measured in an optimised build), the pass a catch-up makes, and nothing when the copy is `manifest`.
    private func prunesUnreported(by report: ApplyReport, in manifest: ValidatedManifest) -> [AssetID] {
        let copy = self.state.applied
        guard copy.digest != manifest.digest || copy.count != manifest.count else {
            return []
        }
        var reported: Set<AssetID>?
        var unreported: [AssetID] = []
        for entry in copy.entries where !manifest.contains(entry.identifier) {
            if reported == nil {
                reported = Set(report.pruned)
            }
            if reported?.contains(entry.identifier) == false {
                unreported.append(entry.identifier)
            }
        }
        return unreported
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

    /// Releases the system interests launch re-attachment created for transfers the run does not plan (sync.md §7.1).
    /// A re-attached transfer the run plans keeps its interest until the run's own joins it (materialisation is bounded
    /// by the pipeline, S1-15): releasing it first would retire the job, cancel the live OS task and start the same
    /// transfer again (R-NET-3: joined once, never duplicated). Only the jobs a system interest joined are visited
    /// (`systemHeld`), in transfer order, not the whole table (C2; Stage 3, S3-PERF-02); one left with no system interest
    /// leaves the index.
    private func releaseSystemReattachments(keeping planned: Set<TransferID>) {
        for transfer in self.state.systemHeld.sorted() {
            guard let job = self.state.jobs[transfer] else {
                self.state.systemHeld.remove(transfer)
                continue
            }
            if !planned.contains(transfer) {
                for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) where interest.kind == .system {
                    let healing = interest.assets.contains { self.state.heals[$0] != nil }
                    if !healing {
                        self.removeInterest(token, from: transfer)
                    }
                }
            }
            if self.state.jobs[transfer]?.interests.values.contains(where: { $0.kind == .system }) != true {
                self.state.systemHeld.remove(transfer)
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
            if self.isBound(fetch.id, to: fetch.transfer) {
                // Another interest committed it (or an apply bound it) after the run's planning view: nothing to fetch
                // (F-19, L4-R5).
                self.countRunFetched(run.token)
                continue
            }
            if self.state.run?.outstanding[fetch.transfer] == nil {
                outstanding += 1
            }
            self.state.run?.outstanding[fetch.transfer, default: []].insert(fetch.id)
            self.addInterest(run.token, asset: fetch.id, entry: fetch.entry, lane: .bulk, kind: .run)
        }
    }

    /// Drops the run's claim on `asset` in `transfer` (the asset follows other content now, or left the manifest): a
    /// claim left on a job that will never report to the run would keep the run from settling.
    func releaseRunClaim(_ token: InterestToken, asset: AssetID, from transfer: TransferID) {
        guard var run = self.state.run, run.token == token, var claimed = run.outstanding[transfer] else {
            return
        }
        claimed.remove(asset)
        run.outstanding[transfer] = claimed.isEmpty ? nil : claimed
        self.state.run = run
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
        self.checkRunSettled(spaceSwept: false)
    }

    /// `checkRunSettled()`; `spaceSwept` once this check has re-checked the space-parked jobs against the ledger.
    private func checkRunSettled(spaceSwept: Bool) {
        // While a follow owes visits a claim may still move (T21/T22): the follow's last turn checks again.
        guard let run = self.state.run, run.transferring, run.settlement == nil, !self.followOwed else {
            return
        }
        self.materializeRun()
        guard var current = self.state.run else {
            return
        }
        // One read of the job table: a closure over `self.state` would copy the whole engine state per claim.
        let jobs = self.state.jobs
        let owed = OwedRequeues(
            origin: self.state.originOwed,
            edge: self.state.edgeOwed,
            lanes: self.state.readmissionsOwed.contains(.conditions) ? Set(AssetPriority.allCases.filter { self.laneAdmitsAfterConditions($0) }) : []
        )
        let spaceSweepOwed = self.state.spaceSweepFollowUp != nil
        // Most calls find a claimed job still working for the run: then nothing can settle and nothing else is needed
        // (a claim on a job that lost the run's interest is found by the pass below once no claimed job works; each
        // lookup copies a job in debug and sanitizer builds, so the common answer takes one, L4-R8). A parked claim that a
        // re-admission turn still owes a re-queue counts as working: its gate has opened, and only the bound on one
        // turn's re-queues (`readmissionsPerTurn`) left it to the follow-up turn, whose pump checks again. Settling now
        // would report a gate that is open, retire the claim's job and start the pending run at once (close-out cycle 16,
        // F-36). A claim parked `insufficientSpace` counts as working the same way while a follow-up space sweep is owed:
        // every sweep re-checks such a job against the latest read, so the claim's verdict waits for that sweep, which a
        // read's bound on re-queues may have left it to, and the follow-up checks the run again (close-out cycle 17,
        // F-37). Every claim with the run's interest passes here, so this is the one check before the passes below.
        // A claim parked `insufficientSpace` that the ledger admits now (a job in flight ended without committing, which
        // re-checks nothing until the next free-space read, F-28) is noted: settling would report a lack of space the
        // ledger denies (close-out cycle 18, F-38). A claim parked by an origin gate that admits at `now`, as the next
        // dispatch reads it (`originGate`: a throttle or a cooldown the clock ended, a probe silent past its watchdog, a
        // probe that ended without a verdict), is re-admitted in this turn and counts as working: settling would report
        // a gate that admits, retire the claim's job and start the pending run at once. Earlier cycles waited here for
        // the alarm's turn of each such end (F-39); the re-admission makes the check independent of any turn having
        // run, for every gate and transition at once (close-out cycle 20, L4-R20, F-40).
        let gate = self.originGateNow()
        var admittedBySpace = false
        for (transfer, _) in current.outstanding {
            guard let job = jobs[transfer], job.interests[current.token] != nil else {
                continue
            }
            switch job.state {
            case .blocked(.awaitingSpace):
                return
            case .blocked(let reason) where gate.admits(reason) == true:
                // Parked by an origin gate that admits at `now` (`originGate`): the clock or an outcome opened it and its
                // re-admission has not run. It runs now (unless a follow-up turn already owes the claim its re-queue), so
                // this check never depends on the alarm's turn (F-40).
                if !owed.contains(transfer, job) {
                    self.readmitOpenedOriginGates(gate)
                }
                return
            case .blocked(.insufficientSpace) where spaceSweepOwed:
                return
            case .blocked(.insufficientSpace) where !spaceSwept && self.spaceBlock(job) == nil:
                admittedBySpace = true
                continue
            case .blocked, .failed(.whenOnline):
                if owed.contains(transfer, job) {
                    return
                }
                continue
            default:
                return
            }
        }
        if admittedBySpace {
            // No claim works and the ledger admits a claim parked for space: the jobs parked `insufficientSpace` are
            // re-checked as a free-space read re-checks them (the pump's order, the room left by those admitted ahead), so
            // the claim is re-queued unless jobs ranked ahead of it take the room. The check then runs once more without
            // this step: a re-queued claim works, and one still parked settles the run as before. The sweep re-queues at
            // most `readmissionsPerTurn` jobs and parks none; it runs only when the run would otherwise settle.
            self.sweepSpaceParked(.read)
            self.checkRunSettled(spaceSwept: true)
            return
        }
        let orphaned = current.outstanding.keys.filter { jobs[$0]?.interests[current.token] == nil }
        if !orphaned.isEmpty {
            // A claim on a job that no longer holds the run's interest can never be answered (every path that moves or
            // ends one releases it; this keeps a missed one from stranding the run): its assets count as failed, so
            // the run still settles and the sync stays due.
            for transfer in orphaned.sorted() {
                for asset in (current.outstanding.removeValue(forKey: transfer) ?? []).sorted() {
                    current.failures[asset] = AssetFailure(id: asset, error: .cancelled, failureClass: SyncEngine.failureClass(of: .cancelled))
                }
            }
            self.state.run = current
        }
        if current.cursor >= current.fetches.count, current.outstanding.isEmpty {
            self.settleRun(.finished)
            return
        }
        guard !current.outstanding.isEmpty else {
            return
        }
        // Most calls find a job still working: that answer needs no order, so the claims are sorted (for the reason
        // reported) only once every one of them is parked.
        for transfer in current.outstanding.keys {
            switch jobs[transfer]?.state {
            case .blocked(.awaitingSpace)?:
                return
            case .blocked?, .failed(.whenOnline)?, nil:
                continue
            default:
                return
            }
        }
        var reasons: [BlockReason] = []
        for transfer in current.outstanding.keys.sorted() {
            guard let job = jobs[transfer] else {
                continue
            }
            switch job.state {
            case .blocked(.awaitingSpace):
                return
            case .blocked(let reason):
                // A claim keeps the throttle end it was parked with; the run reports the origin's, which a later 429
                // may have extended, as the pending run and the throttle's deadline do (F-36).
                reasons.append(self.currentReason(reason))
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
        case .offline:
            self.setOfflinePendingRun()
        case .policy:
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
        if let completion = self.state.runCompletions.removeValue(forKey: run.token) {
            self.deliverRunSettlement(settlement, to: completion)
        }
        self.notifyObservers()
    }

    /// Resumes the run task's wait with `settlement`, unless the test seam holds it (`holdRunSettlementDelivery()`).
    private func deliverRunSettlement(_ settlement: RunSettlement, to continuation: CheckedContinuation<RunSettlement, Never>) {
        guard self.state.runSettlementsHeld else {
            continuation.resume(returning: settlement)
            return
        }
        self.state.heldRunSettlements.append(HeldRunSettlement(settlement: settlement, continuation: continuation))
        self.notifyObservers()
    }

    /// Test seam: the settlements runs reach from now on wait for `releaseRunSettlementDelivery()` before they reach the
    /// run's task (close-out cycle 19), so a test can let other engine work run between a run's settling turn and its
    /// answer, an order production leaves to the scheduler.
    func holdRunSettlementDelivery() {
        self.state.runSettlementsHeld = true
    }

    /// Test seam: delivers every held settlement to its run task and disarms the hold; shutdown calls it too, and then the
    /// run task is told the engine is shutting down, as shutdown tells a run task that is still waiting.
    func releaseRunSettlementDelivery() {
        self.state.runSettlementsHeld = false
        let held = self.state.heldRunSettlements
        self.state.heldRunSettlements.removeAll()
        for delivery in held {
            delivery.continuation.resume(returning: self.isShuttingDown ? .shutDown : delivery.settlement)
        }
    }

    /// Test seam: whether a run's settlement waits for `releaseRunSettlementDelivery()`.
    var runSettlementHeld: Bool {
        !self.state.heldRunSettlements.isEmpty
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
        // The jobs the run's interest still holds outside `outstanding` (a follow routed it there): those its joins
        // reached and it has not left, not a walk of the whole table (C2; Stage 3, S3-PERF-02).
        for transfer in (self.state.run?.held ?? []).sorted() where self.state.jobs[transfer]?.interests[run.token] != nil {
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
        switch outcome {
        case .failed(.offline), .blocked(.offline, _):
            break
        default:
            // A run that got past the network ends a streak of offline runs (F-16).
            self.state.offlineRunsWithoutEdge = 0
        }
        if self.isRunning, run.fetched > 0 || (run.applyReport?.reused.isEmpty == false), self.state.remote?.capabilities.keepsSourceCopies == true {
            self.spawn(.entry) { engine in
                // REENTRANCY: RE-S34 — the lifecycle; the report is the store's durable capture.
                await engine.releaseSourceCopies()
            }
        }
        if case .failed(.shutDown) = outcome {
            return
        }
        self.reconsiderPendingRun()
        self.pump()
        self.reconcileIdle()
    }

    // MARK: Pending runs (sync-2 S2-03, S2-25)

    /// The pending run after an offline failure (R-SYN-13). The first run since the last satisfied-path edge that ends
    /// offline is retried after the debounce (once conditions admit bulk work): a path monitor often reports satisfied
    /// a moment before connections work, or its first element was not in yet. When the retried run ends offline too
    /// while the conditions read the path satisfied (a VPN, captive or roaming path the transport cannot use), the
    /// pending run waits for a satisfied-path edge, so no timer requests the manifest once per `pendingRunDebounce` for
    /// ever (F-16).
    func setOfflinePendingRun() {
        self.state.offlineRunsWithoutEdge += 1
        let contradicted = self.state.conditions?.network.satisfied == true && self.state.offlineRunsWithoutEdge > 1
        self.setPendingRun(.conditions, trigger: .conditionsChanged, awaitsNetworkEdge: contradicted)
    }

    /// Remembers a run to start when `gate` opens; `awaitsNetworkEdge` (conditions gate only) waits for a
    /// satisfied-path edge first.
    func setPendingRun(_ gate: PendingRunGate, trigger: SyncTrigger, awaitsNetworkEdge: Bool = false) {
        guard self.isRunning else {
            return
        }
        self.state.pendingRun = PendingRun(gate: gate, trigger: trigger, awaitsNetworkEdge: gate == .conditions && awaitsNetworkEdge)
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
        if self.laneVerdict(.bulk) == .admit, !pending.awaitsNetworkEdge {
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

    /// Where a pending run's gate stands (sync-2 S2-03, S2-25).
    enum PendingRunGateState: Equatable {
        /// The gate is open: the run may start now.
        case open
        /// A deadline, the conditions watcher, a probe in flight or a pump still owed will open it (or decide it).
        case armed
        /// Closed with nothing to open it.
        case unarmed
    }

    /// The state of `pending`'s gate now.
    func pendingRunGate(_ pending: PendingRun) -> PendingRunGateState {
        let now = self.environment.time.monotonicNow()
        let origin = self.state.remote?.originID
        switch pending.gate {
        case .conditions:
            guard self.laneVerdict(.bulk) == .admit, !pending.awaitsNetworkEdge else {
                return self.state.watcher == nil ? .unarmed : .armed
            }
            if self.state.heap.deadline(for: .pendingRun) != nil {
                return .armed
            }
            // Admitted with its debounce already fired, or never scheduled.
            return pending.scheduled ? .open : .unarmed
        case .breaker:
            // The breaker's gate as the next dispatch reads it (`originGate`, F-40): open when it is closed, when its
            // cooldown has ended, or when it is half-open without a probe or with one silent past its watchdog.
            guard let origin else {
                return .open
            }
            let gate = self.originGate(at: now)
            if gate.admitsBreakerParked {
                // A breaker that admits only a probe has one probe to give, and the jobs just re-admitted for it (a
                // cooldown's end, a watchdog, a probe's exit without a verdict) are dispatched by a pump still owed. A run
                // started before that pump lost the probe to the first of them before its manifest step, ended blocked
                // and left a new pending run: one run per probe while the clock did not move (close-out cycle 21, F-41).
                // The pending run waits for that pump, which reconsiders it once it has dispatched (`pump()`); a closed
                // breaker admits every transfer, so nothing waits then. Since close-out cycle 22 a run that starts holds the
                // probe for its manifest fetch from its start turn (`reserveManifestProbe`, F-42), so it can no longer lose
                // it; this wait keeps the order F-41 chose, the re-admitted jobs probing first.
                if gate.breaker == .probe, self.dispatchOwed {
                    return .armed
                }
                return .open
            }
            if self.state.heap.deadline(for: .breaker(origin)) != nil || self.state.breakers[origin]?.probe != nil {
                // The cooldown's end or the probe's watchdog is in the heap, or the probe's outcome reconsiders it.
                return .armed
            }
            return .unarmed
        case .throttle:
            guard origin != nil, self.originGate(at: now).throttledUntil != nil else {
                return .open
            }
            return self.state.heap.deadline(for: .pendingRun) == nil ? .unarmed : .armed
        }
    }

    /// Whether a later turn owes a pump that may dispatch queued or re-admitted jobs: a pump follow-up, a re-admission
    /// follow-up (it pumps after its re-queues), re-queues still owed to an origin's jobs, an `ensureAvailable` refill, or
    /// a queue whose head waits for an owed follow (each follow turn pumps; `pumpWaitsForFollow`). Each of those turns
    /// ends in `pump()`, which reconsiders a pending run that waits for the breaker (F-41).
    var dispatchOwed: Bool {
        self.state.pumpFollowUpScheduled || self.state.readmissionFollowUpScheduled || self.state.ensureRefillScheduled
            || !self.state.originOwed.isEmpty || self.state.pumpWaitsForFollow
    }

    /// Starts the pending run when its gate is already open, and arms whatever opens a closed one.
    ///
    /// A gate can open while a settled run's task has not finished it yet (the alarm and that task race for the
    /// actor): `fulfilPendingRun` then finds the run in place and returns, so the run's finish asks again. A breaker
    /// whose probe ended without a verdict (`halfOpen(probe: nil)`) admits the pending run's own probe.
    func reconsiderPendingRun() {
        guard self.isRunning, self.state.run == nil, let pending = self.state.pendingRun else {
            return
        }
        switch self.pendingRunGate(pending) {
        case .open:
            self.fulfilPendingRun()
        case .armed:
            return
        case .unarmed:
            switch pending.gate {
            case .conditions:
                self.considerPendingRun()
                self.ensureWatcher()
            case .breaker:
                self.scheduleBreakerDeadline()
            case .throttle:
                if let origin = self.state.remote?.originID, let until = self.state.throttles[origin] {
                    self.state.heap.schedule(.pendingRun, at: until)
                    self.state.pendingRun?.scheduled = true
                    self.rearm()
                }
            }
        }
    }

    /// Starts the pending run now; only `reconsiderPendingRun` calls it, once the gate reads open at `now` (F-40).
    private func fulfilPendingRun() {
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
    /// nothing remaining yet is not finished (RE-S29). When the loop ends, the launch run that waited for it starts,
    /// unless a run took its place meanwhile (`startRun` cleared the flag, so no run can be active here with the flag
    /// set) or the engine no longer runs; the flag is cleared either way.
    ///
    /// After every call, returned or thrown, the store's deadline is re-read into the heap (RE-S40, orchestrator ruling
    /// L5K-R16): a batch publishes its adoptions at bulk urgency, which inside the install window leaves the trailing
    /// install to the engine's alarm (ARCHITECTURE §5), and since L5K-R1's parked-run decision no launch run's apply need
    /// follow migration to install them; a call that threw may have published first (phase 3's commit throws after the
    /// batch's publication). The re-read is O(1) while the alarm already wakes within about two install intervals (F-12).
    private func migrateLoop() async {
        defer {
            self.state.migration.running = false
            let launchRunWaiting = self.state.migration.launchRunWaiting
            self.state.migration.launchRunWaiting = false
            if launchRunWaiting, self.isRunning {
                self.startRun(trigger: .launch, mode: .force)
            }
        }
        while self.isRunning, !Task.isCancelled {
            let progress: LegacyMigrationProgress
            self.state.migration.batchCalls += 1
            do {
                // REENTRANCY: RE-S29 — the lifecycle; calls again while not finished and the engine runs.
                progress = try await self.store.migrateLegacy(maxFiles: 64)
            } catch {
                self.state.migration.deferred = true
                if self.isRunning {
                    // REENTRANCY: RE-S40 — the lifecycle (inside); the heap's store entry is replaced by the newest deadline.
                    await self.refreshStoreDeadlineAfterPublish()
                }
                return
            }
            guard self.isRunning else {
                return
            }
            // REENTRANCY: RE-S40 — the lifecycle, re-checked below; the heap's store entry is replaced by the newest
            // deadline, so the trailing install of this batch's publication runs on the alarm (L5K-R16).
            await self.refreshStoreDeadlineAfterPublish()
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
