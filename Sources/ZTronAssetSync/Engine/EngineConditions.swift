import Foundation
import ZTronAssetModel

extension SyncEngine {
    // MARK: Work and idle silence (R-SYN-14, ARCHITECTURE §7.8)

    /// Whether anything needs the conditions: a job, a run, a pending run, a manifest fetch or an unknown-id waiter.
    var hasWork: Bool {
        !self.state.jobs.isEmpty || self.state.run != nil || self.state.pendingRun != nil || self.state.manifestFetch != nil
            || !self.state.unknownWaiters.isEmpty || !self.state.conditionWaiters.isEmpty || !self.state.eventsAfterFollow.isEmpty
    }

    /// Stops the watcher when no work is left (its stream ends, so the source stops observing) and keeps the alarm
    /// only for a non-empty heap (sync-1 S1-10).
    func reconcileIdle() {
        self.pruneBoundContent()
        if !self.hasWork, let watcher = self.state.watcher {
            self.state.watcher = nil
            self.state.conditions = nil
            self.cancelTask(watcher.task)
        }
        self.rearm()
        self.notifyObservers()
    }

    // MARK: Conditions watcher (RE-S17, RE-S18)

    /// Starts the watcher when work exists and none runs.
    func ensureWatcher(force: Bool = false) {
        guard self.state.watcher == nil, self.isRunning || self.state.lifecycle == .starting, force || self.hasWork else {
            return
        }
        self.state.lastWatcher += 1
        let token = self.state.lastWatcher
        // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
        guard let task = self.spawn(.watcher, { engine in await engine.watch(token: token) }) else {
            return
        }
        self.state.watcher = Watcher(token: token, task: task)
        self.notifyObservers()
    }

    /// The watcher's body: one observation for as long as work exists.
    private func watch(token: UInt64) async {
        // REENTRANCY: RE-S17 — the watcher token is current and work still exists; otherwise the stream is dropped,
        // which stops the observation.
        let stream = await self.environment.conditions.conditions()
        guard self.state.watcher?.token == token, !self.isShuttingDown else {
            return
        }
        // REENTRANCY: RE-S18 — the watcher token and the lifecycle per element; apply, then pump; exit when idle.
        for await conditions in stream {
            guard self.state.watcher?.token == token, !self.isShuttingDown else {
                return
            }
            self.apply(conditions)
            guard self.hasWork else {
                if self.state.watcher?.token == token {
                    self.state.watcher = nil
                    self.state.conditions = nil
                }
                self.notifyObservers()
                return
            }
        }
    }

    /// Applies one conditions element: thermal hysteresis, unblocking (T17), pausing refused running work (§11.3),
    /// re-queueing offline and transient failures on a satisfied edge (T19, R-SYN-13), pending runs, then `pump()`. The
    /// re-queues read the indexes of jobs parked by a lane-wide gate and of failed jobs, and at most
    /// `readmissionsPerTurn` happen in this turn (`readmit`; C2).
    ///
    /// Behind the follow barrier the element, its edge and the pending run's reading apply now (real-world inputs,
    /// S3-R14), and the decisions it takes about jobs wait (`EventAfterFollow.conditions`): the pauses read each running
    /// job's lane, the edge's re-queues read which jobs wait for an edge and in what order, the re-admissions read the
    /// lanes and places, all of which the visits and the verdicts before the element change. Decided now, a Low Data
    /// Mode element paused a transfer a visit raised to user work (PROBE-C10R-POLICY-PAUSE), a re-admission placed a job
    /// the visit placed again (PROBE-C10-DOUBLE-PLACE), and an edge re-queued a job whose verdict waited ahead of the jobs
    /// the edge owed first (the cycle-10 residual). The drain applies them under the element's own conditions.
    func apply(_ conditions: DeviceConditions) {
        let previous = self.state.conditions
        self.state.conditions = conditions
        let power = self.configuration.power
        if conditions.power.thermal >= power.pauseBackgroundAtThermal {
            self.state.pausedForThermal = true
        } else if conditions.power.thermal <= power.resumeBackgroundAtThermal {
            self.state.pausedForThermal = false
        }
        self.broadcast(.conditionsChanged(conditions))
        let waiting = self.state.conditionWaiters
        self.state.conditionWaiters.removeAll()
        for token in waiting.keys.sorted() {
            waiting[token]?.resume()
        }
        // A satisfied first reading (none since the watcher started: at launch, or after an idle teardown set the
        // conditions to `nil`) is an edge too. User work is dispatched before any reading exists, and an attempt that
        // failed offline then, or that fails offline after this reading, waits for the edge this reading is: counting
        // it re-queues such a job once (or `failed` retries it at once, `ActiveAttempt.edgeSerial`), where no further
        // edge may ever come on a steady network (R-SYN-13; Stage 3, S3-CONC-04). With nothing failed it re-queues
        // nothing; a pending run that waits for an edge keeps the watcher, so its first reading is never this one.
        let edge = conditions.network.satisfied && (previous.map { !$0.network.satisfied || $0.network != conditions.network } ?? true)
        if edge {
            // The edge an offline-failed pending run waits for (R-SYN-13): its debounce may start now.
            self.state.pendingRun?.awaitsNetworkEdge = false
            self.state.offlineRunsWithoutEdge = 0
            self.state.networkEdgeSerial += 1
        }
        if self.defersToFollow {
            self.deferToFollow(.conditions(edge: edge))
        } else {
            self.applyConditionsToJobs(edge: edge)
        }
        self.considerPendingRun()
        self.pump()
        self.rearm()
        self.notifyObservers()
    }

    /// A conditions element's decisions about jobs (`apply`): pauses the running transfers whose lane the conditions
    /// refuse (only a downloading job can be paused, `pauseIfRefused`: the jobs in flight, not every job, C2), owes a
    /// satisfied `edge`'s re-queue to every job failed `whenOnline` or transiently (T19), and re-admits.
    func applyConditionsToJobs(edge: Bool) {
        for transfer in self.state.inFlight.sorted() {
            self.pauseIfRefused(transfer)
        }
        var passes: Readmissions = [.conditions]
        if edge {
            for transfer in self.state.failedJobs {
                guard let job = self.state.jobs[transfer], job.state.owedOnEdge(transient: job.transientFailure) else {
                    continue
                }
                self.state.edgeOwed.insert(transfer)
            }
            passes.insert(.edge)
        }
        self.readmit(passes)
    }
}
