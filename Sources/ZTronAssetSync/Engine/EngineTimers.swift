import Foundation
import ZTronAssetModel
import ZTronAssetStorage

extension SyncEngine {
    // MARK: The single alarm (ADR-022, R-SYN-14, H-8)

    /// Arms one alarm at the earliest deadline (or none when the heap is empty); a replaced alarm finds its token
    /// stale (RE-S16) and never unregisters its successor (keys are unique, sync-1 S1-09).
    func rearm() {
        guard self.isRunning || self.state.lifecycle == .starting else {
            return
        }
        let target = self.state.heap.first?.at
        if let alarm = self.state.alarm {
            guard alarm.deadline != target else {
                return
            }
            self.state.alarm = nil
            self.cancelTask(alarm.task)
        }
        guard let target else {
            self.notifyObservers()
            return
        }
        self.state.lastAlarm += 1
        let token = self.state.lastAlarm
        // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
        guard let task = self.spawn(.alarm, { engine in await engine.alarmLoop(token: token, deadline: target) }) else {
            return
        }
        self.state.alarm = Alarm(token: token, task: task, deadline: target)
        self.notifyObservers()
    }

    /// The alarm's body: sleep, then fire what is due.
    private func alarmLoop(token: UInt64, deadline: MonotonicInstant) async {
        do {
            // REENTRANCY: RE-S16 — the alarm token is current; due entries are recomputed from `monotonicNow()`, never
            // from the scheduled deadline.
            try await self.environment.time.sleep(until: deadline)
        } catch {
            return
        }
        guard self.isRunning, self.state.alarm?.token == token else {
            return
        }
        self.state.alarm = nil
        // REENTRANCY: RE-S16 — nothing here: `fireDue` recomputes due entries from `monotonicNow()`.
        await self.fireDue()
    }

    /// Drains due entries in `(deadline, seq)` order, re-validating each against epochs, then runs the store's due
    /// work if its deadline was among them, and re-arms.
    func fireDue() async {
        let now = self.environment.time.monotonicNow()
        let due = self.state.heap.popDue(at: now)
        var storeDue = false
        for deadline in due {
            switch deadline.reason {
            case .retry(let transfer, let epoch):
                guard let job = self.state.jobs[transfer], job.epoch == epoch, case .failed(.at) = job.state else {
                    continue
                }
                if self.transition(transfer, to: .queued) {
                    self.enqueue(transfer)
                }
            case .throttle(let origin):
                guard let until = self.state.throttles[origin], until <= now else {
                    continue
                }
                self.state.throttles[origin] = nil
                self.unblock { reason in
                    if case .throttled = reason {
                        return true
                    }
                    return false
                }
            case .breaker(let origin):
                guard self.state.breakers[origin] != nil else {
                    continue
                }
                self.unblock { reason in
                    if case .circuitOpen = reason {
                        return true
                    }
                    return false
                }
                if self.state.pendingRun?.gate == .breaker {
                    self.fulfilPendingRun()
                }
                self.scheduleBreakerDeadlineIfStillPending(origin, now: now)
            case .store:
                storeDue = true
            case .pendingRun:
                self.pendingRunDeadlineFired()
            case .progress(let slot):
                self.flushProgress(slot, now: now)
            case .heal(let asset):
                self.heal(asset)
            case .manifest(let sequence):
                self.manifestDeadlinePassed(sequence)
            }
        }
        if storeDue {
            self.state.storeDeadline = nil
            self.state.storeWorkInFlight = true
            defer {
                self.state.storeWorkInFlight = false
                // Waiting test seams re-evaluate their conditions once the store's work is over.
                self.notifyObservers()
            }
            // REENTRANCY: RE-S27 — the lifecycle; reaped bytes wake `awaitingSpace` jobs; re-armed from the store's
            // new `nextDeadline()`.
            let work = await self.store.runDueWork()
            guard self.isRunning else {
                return
            }
            self.setStoreDeadline(work.nextDeadline)
            if work.reapedBytes > 0 {
                // REENTRANCY: f-4 (proposed) — the lifecycle; the ledger's base is replaced by a fresh read.
                await self.refreshFreeSpace()
                guard self.isRunning else {
                    return
                }
                self.unblock { $0 == .awaitingSpace }
            }
        }
        self.pump()
        self.rearm()
        self.reconcileIdle()
    }

    /// The pending run's deadline (its debounce or throttle end) fired: the run starts unless conditions refuse bulk work
    /// now (the watcher re-arms it), or a run still in place makes `fulfilPendingRun` leave it to that run's finish
    /// (`reconsiderPendingRun`, F-3).
    func pendingRunDeadlineFired() {
        guard let pending = self.state.pendingRun else {
            return
        }
        if pending.gate == .conditions, self.laneVerdict(.bulk) != .admit {
            self.state.pendingRun?.scheduled = false
            return
        }
        self.fulfilPendingRun()
    }

    /// After a breaker deadline fired, keeps the next one (a watchdog of a new probe) in the heap.
    private func scheduleBreakerDeadlineIfStillPending(_ origin: String, now: MonotonicInstant) {
        if let at = self.state.breakers[origin]?.nextDeadline(), at > now {
            self.state.heap.schedule(.breaker(origin), at: at)
        }
    }

    /// Re-reads `store.nextDeadline()` into the heap (RE-S40).
    func refreshStoreDeadline() async {
        // REENTRANCY: RE-S40 — the lifecycle; a stale entry is replaced by the newest deadline.
        let deadline = await self.store.nextDeadline()
        guard self.isRunning else {
            return
        }
        self.setStoreDeadline(deadline)
    }

    /// After a publication (RE-S40): a publication only adds work due within the store's coalescing windows (a commit,
    /// a trailing install), so when the alarm already wakes for the store within about two install intervals, its
    /// `runDueWork()` report re-arms from the newest deadline and no read is needed. This keeps a bulk sync from asking
    /// `nextDeadline()`, which scans the blob table, once per asset (O(n²) over a sync, F-12).
    func refreshStoreDeadlineAfterPublish() async {
        let soon = self.environment.time.monotonicNow().adding(seconds: 2 * max(0.05, self.tuning.snapshotInstallInterval))
        if let scheduled = self.state.storeDeadline, scheduled <= soon, self.state.heap.deadline(for: .store) != nil {
            return
        }
        // REENTRANCY: RE-S40 — the lifecycle; a stale entry is replaced by the newest deadline.
        await self.refreshStoreDeadline()
    }

    /// Replaces the heap's store entry.
    func setStoreDeadline(_ deadline: MonotonicInstant?) {
        self.state.storeDeadline = deadline
        if let deadline {
            self.state.heap.schedule(.store, at: deadline)
        } else {
            self.state.heap.remove(.store)
        }
        self.rearm()
        self.reconcileIdle()
    }

    /// A manifest fetch outlived `manifestFetchDeadline`: runs waiting for it use the applied manifest (T2-14).
    private func manifestDeadlinePassed(_ sequence: UInt64) {
        guard var fetch = self.state.manifestFetch, fetch.sequence == sequence else {
            return
        }
        let waiting = fetch.waiters
        fetch.waiters.removeAll()
        self.state.manifestFetch = fetch
        for token in waiting.keys.sorted() {
            waiting[token]?.resume(returning: .timedOut)
        }
    }

    // MARK: Healing (R-CLN-8)

    /// Schedules the re-download of a quarantined asset at the end of its quarantine.
    func scheduleHeal(_ asset: AssetID, at: MonotonicInstant) {
        self.state.heals[asset] = at
        self.state.heap.schedule(.heal(asset), at: at)
        self.rearm()
    }

    /// The quarantine of `asset` ended: a system interest fetches it again.
    private func heal(_ asset: AssetID) {
        guard self.state.heals[asset] != nil, let entry = self.state.applied.entry(for: asset), !self.isBound(asset, to: entry.transferID) else {
            // Gone from the manifest, or present again (a resolve downloaded it meanwhile, L4-R5): nothing to heal.
            self.state.heals[asset] = nil
            return
        }
        self.addSystemInterest(entry: entry, lane: .prefetch)
    }
}
