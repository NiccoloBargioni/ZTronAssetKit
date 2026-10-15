import Foundation
import ZTronAssetModel

extension SyncEngine {
    // MARK: Work and idle silence (R-SYN-14, ARCHITECTURE §7.8)

    /// Whether anything needs the conditions: a job, a run, a pending run, a manifest fetch or an unknown-id waiter.
    var hasWork: Bool {
        !self.state.jobs.isEmpty || self.state.run != nil || self.state.pendingRun != nil || self.state.manifestFetch != nil
            || !self.state.unknownWaiters.isEmpty || !self.state.conditionWaiters.isEmpty
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
    /// re-queueing offline and transient failures on a satisfied edge (T19, R-SYN-13), pending runs, then `pump()`.
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
        for transfer in self.state.jobs.keys.sorted() {
            guard let job = self.state.jobs[transfer], case .blocked(let reason) = job.state else {
                continue
            }
            switch reason {
            case .offline, .policy:
                if self.gateAdmitsAfterConditions(transfer) {
                    if self.transition(transfer, to: .queued) {
                        self.enqueue(transfer)
                    }
                }
            default:
                continue
            }
        }
        for transfer in self.state.jobs.keys.sorted() {
            self.pauseIfRefused(transfer)
        }
        let edge = conditions.network.satisfied && (previous.map { !$0.network.satisfied || $0.network != conditions.network } ?? false)
        if edge {
            // The edge an offline-failed pending run waits for (R-SYN-13): its debounce may start now.
            self.state.pendingRun?.awaitsNetworkEdge = false
            self.state.offlineRunsWithoutEdge = 0
            for transfer in self.state.jobs.keys.sorted() {
                guard let job = self.state.jobs[transfer] else {
                    continue
                }
                switch job.state {
                case .failed(.whenOnline):
                    break
                case .failed(.at) where job.transientFailure:
                    break
                default:
                    continue
                }
                self.state.heap.remove(.retry(transfer, epoch: job.epoch))
                if self.transition(transfer, to: .queued) {
                    self.enqueue(transfer)
                }
            }
        }
        self.considerPendingRun()
        self.pump()
        self.rearm()
        self.notifyObservers()
    }

    /// Whether a blocked job's lane gate admits it now (offline or policy blocks).
    private func gateAdmitsAfterConditions(_ transfer: TransferID) -> Bool {
        guard let job = self.state.jobs[transfer] else {
            return false
        }
        if self.laneVerdict(job.lane) != .admit {
            return false
        }
        if self.state.remote?.capabilities.tier == .appleHosted, self.appleAccessBlock(self.access(for: job.lane)) != nil {
            return false
        }
        return true
    }
}
