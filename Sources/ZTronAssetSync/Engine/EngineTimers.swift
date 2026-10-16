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
            self.state.storeWorkRuns += 1
            defer {
                self.state.storeWorkRuns -= 1
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
        // The store's work is over: a job still waiting for space with no store deadline armed has no wake left, and is
        // decided on a fresh free-space read.
        self.settleUnwakeableSpaceWaits()
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

    /// Replaces the heap's store entry; a cleared one leaves jobs waiting for space without a wake (see
    /// `settleUnwakeableSpaceWaits`).
    func setStoreDeadline(_ deadline: MonotonicInstant?) {
        self.state.storeDeadline = deadline
        if let deadline {
            self.state.heap.schedule(.store, at: deadline)
        } else {
            self.state.heap.remove(.store)
        }
        self.rearm()
        self.reconcileIdle()
        self.settleUnwakeableSpaceWaits()
    }

    // MARK: Waiting for reclaimed space (ADR-022, S1-14; review of close-out cycle 4)

    /// Whether something will run the store's due work, the only wake of a job parked `awaitingSpace`, or decide that job
    /// on a fresh read: an armed store deadline, the alarm's store work under way, a re-read of the store's deadline in
    /// flight, or the settling read of `settleUnwakeableSpaceWaits` in flight.
    var spaceWakeExpected: Bool {
        self.state.storeDeadline != nil || self.state.storeWorkInFlight || self.state.spaceDeadlineReread || self.state.spaceSettleRead
    }

    /// A job was parked `awaitingSpace`: the bytes it waits for are reclaimed only by `runDueWork()`, which only the
    /// store deadline brings. When none is armed, the store's next deadline is read again (the engine's copy may predate
    /// work the store took on since); `settleUnwakeableSpaceWaits` then decides.
    func ensureSpaceWake() {
        guard self.isRunning, !self.spaceWakeExpected else {
            return
        }
        self.state.spaceDeadlineReread = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle.
            await engine.rereadStoreDeadlineForSpace()
        }
        if spawned == nil {
            self.state.spaceDeadlineReread = false
        }
    }

    /// The re-read `ensureSpaceWake` owes; jobs still without a wake afterwards are settled.
    private func rereadStoreDeadlineForSpace() async {
        // REENTRANCY: RE-S40 — the lifecycle; a stale entry is replaced by the newest deadline, and the parked jobs are
        // re-read below.
        await self.refreshStoreDeadline()
        self.state.spaceDeadlineReread = false
        self.settleUnwakeableSpaceWaits()
    }

    /// Jobs parked `awaitingSpace` while nothing will run the store's due work (no store deadline, no store work under
    /// way, no re-read in flight): the store counts the bytes they wait for as pending reclaim but schedules nothing that
    /// reclaims them on time alone (their blocker is an acknowledgement or a commit only its later work brings), so no
    /// alarm would ever wake them and their callers waited until they gave up. They are decided on a fresh free-space
    /// read (`settleSpaceWaitsOnFreshRead`), never on the engine's last one: the bytes they waited for may have been
    /// reclaimed meanwhile by work the engine does not follow byte by byte (a purge's reaper that ran before the alarm),
    /// or the volume may have gained room, and parking them on figures older than that answered a shortage that no longer
    /// existed (review of close-out cycle 5). Nothing is read while no job waits for space.
    func settleUnwakeableSpaceWaits() {
        guard self.isRunning, !self.spaceWakeExpected else {
            return
        }
        guard self.state.jobs.values.contains(where: { $0.state == .blocked(.awaitingSpace) }) else {
            return
        }
        self.state.spaceSettleRead = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle.
            await engine.settleSpaceWaitsOnFreshRead()
        }
        if spawned == nil {
            self.state.spaceSettleRead = false
        }
    }

    /// The read `settleUnwakeableSpaceWaits` owes, then each job still parked `awaitingSpace` is decided on it: one the
    /// volume holds now is re-queued; one that still lacks room stays parked when something armed meanwhile will run the
    /// store's due work, and is otherwise parked `insufficientSpace` with the figures of this read (ARCHITECTURE §7.6's
    /// row for a shortage without pending reclaim; F-22's convention): waiters and ensures get the typed figures at
    /// once, a run settles blocked and stays due, and the job is re-admitted at any later free-space read that holds it,
    /// a read after reaped bytes included. A read that fails leaves the last figures in place; they decide.
    private func settleSpaceWaitsOnFreshRead() async {
        // REENTRANCY: f-4 (proposed) — the lifecycle, then every job's state and the wakes armed meanwhile are re-read
        // below; the ledger's base is the read just adopted.
        await self.refreshFreeSpace()
        self.state.spaceSettleRead = false
        guard self.isRunning else {
            return
        }
        var requeued = false
        var settled = false
        for transfer in self.state.jobs.keys.sorted() {
            guard let job = self.state.jobs[transfer], job.state == .blocked(.awaitingSpace) else {
                continue
            }
            guard let block = self.spaceBlock(job) else {
                if self.transition(transfer, to: .queued) {
                    self.enqueue(transfer)
                    requeued = true
                }
                continue
            }
            if block == .awaitingSpace, self.spaceWakeExpected {
                continue
            }
            if case .insufficientSpace(let required, _)? = job.lastError, let space = self.state.freeSpace {
                // An earlier ENOSPC's figures: the bytes it needed, against the room this read leaves the job.
                self.state.jobs[transfer]?.lastError = .insufficientSpace(required: required, available: self.headroom(for: job, in: space))
            }
            self.park(transfer, reason: .insufficientSpace)
            settled = true
        }
        if settled {
            self.checkRunSettled()
        }
        if requeued {
            self.pump()
        }
    }

    /// A store call that may have reclaimed bytes outside the alarm's own work (a purge's reaper reaps every deletable
    /// blob, not only the purged ones): the jobs parked for lack of space are re-checked on a fresh read at once, as after
    /// the alarm's reaped bytes, rather than at the store's next deadline (`awaitingSpace`) or at the next read
    /// (`insufficientSpace`) (review of close-out cycle 5). Nothing is read while no job is parked for space.
    func spaceMayHaveBeenReclaimed() async {
        let parked = self.state.jobs.values.contains { job in
            job.state == .blocked(.awaitingSpace) || job.state == .blocked(.insufficientSpace)
        }
        guard parked else {
            return
        }
        // REENTRANCY: f-4 (proposed) — the lifecycle; the ledger's base is replaced by a fresh read, which re-admits the
        // `insufficientSpace` jobs it holds; the `awaitingSpace` ones are re-queued and gated on it below.
        await self.refreshFreeSpace()
        guard self.isRunning else {
            return
        }
        self.unblock { $0 == .awaitingSpace }
        self.pump()
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
