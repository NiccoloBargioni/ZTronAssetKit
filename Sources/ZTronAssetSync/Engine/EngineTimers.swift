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
            // Test seam: a replaced alarm held after its sleep ends now (it finds its token stale).
            self.state.heldAlarmTurns.removeValue(forKey: alarm.token)?.resume()
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
        if self.state.alarmTurnsHeld {
            // REENTRANCY: RE-S16 — the lifecycle and the alarm token, re-checked right below; due entries are recomputed
            // from `monotonicNow()`.
            await self.awaitAlarmTurnRelease(token)
        }
        guard self.isRunning, self.state.alarm?.token == token else {
            return
        }
        self.state.alarm = nil
        // REENTRANCY: RE-S16 — nothing here: `fireDue` recomputes due entries from `monotonicNow()`.
        await self.fireDue()
    }

    /// Test seam: the alarm turn of `token` waits for `releaseAlarmTurns()`, for shutdown, or for its alarm's replacement;
    /// it registers synchronously, so a hold released or an alarm replaced before it registered lets it pass at once.
    private func awaitAlarmTurnRelease(_ token: UInt64) async {
        // REENTRANCY: RE-S16 — nothing: the body registers synchronously; the caller re-validates the lifecycle and the
        // alarm token.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.state.alarmTurnsHeld, self.isRunning, self.state.alarm?.token == token {
                self.state.heldAlarmTurns[token] = continuation
                self.notifyObservers()
            } else {
                continuation.resume()
            }
        }
    }

    /// Test seam: from now on, an alarm whose sleep returns waits before it fires what is due, until
    /// `releaseAlarmTurns()` (close-out cycle 19). A test uses it to let other engine work run after a deadline's instant
    /// and before the alarm's turn, an order production leaves to the scheduler.
    func holdAlarmTurns() {
        self.state.alarmTurnsHeld = true
    }

    /// Test seam: disarms the hold and lets every held alarm turn go on in its own turn; shutdown calls it too.
    func releaseAlarmTurns() {
        self.state.alarmTurnsHeld = false
        let held = self.state.heldAlarmTurns
        self.state.heldAlarmTurns.removeAll()
        for token in held.keys.sorted() {
            held[token]?.resume()
        }
    }

    /// Test seam: whether an alarm turn waits for `releaseAlarmTurns()`.
    var alarmTurnHeld: Bool {
        !self.state.heldAlarmTurns.isEmpty
    }

    /// The due deadlines one alarm turn takes at most (C2): the rest stay due and the re-armed alarm fires again at once,
    /// so retries of a 10,000-member group falling due together are re-queued over several turns, as `readmit` bounds its
    /// re-queues (Stage 3, S3-B-077).
    static let dueDeadlinesPerTurn = 512

    /// Drains due entries in `(deadline, seq)` order, at most `dueDeadlinesPerTurn`, re-validating each against epochs,
    /// then runs the store's due work if its deadline was among them, and re-arms.
    func fireDue() async {
        let now = self.environment.time.monotonicNow()
        let due = self.state.heap.popDue(at: now, limit: Self.dueDeadlinesPerTurn)
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
                guard let until = self.state.throttles[origin] else {
                    continue
                }
                guard until <= now else {
                    // A deadline earlier than the throttle's end (a later 429 extended it): only this deadline re-admits
                    // the jobs the throttle parked, so it is kept at the end instead of dropped (close-out cycle 15, F-35).
                    self.state.heap.schedule(.throttle(origin), at: until)
                    continue
                }
                self.endThrottle(origin)
            case .breaker(let origin):
                guard self.state.breakers[origin] != nil else {
                    continue
                }
                // The jobs re-queued below, and those this turn's other deadlines re-queue (a retry), are dispatched by a
                // pump before a pending run that waits for the breaker decides (`dispatchOwed`): the first of them probes,
                // and the run waits for its outcome (F-41). This turn's own pump may follow an await on the store's work, so a
                // follow-up is owed explicitly, also with nothing parked (close-out cycle 22, F-42).
                self.schedulePumpFollowUp()
                self.unblockOrigin(.circuitOpen)
                // The pending run starts only through its gate's reading at `now` (F-40).
                self.reconsiderPendingRun()
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
            let since = self.state.storeDeadlineUpdates
            // REENTRANCY: RE-S27 — the lifecycle; reaped bytes wake `awaitingSpace` jobs; re-armed from the store's
            // new `nextDeadline()`, applied against a re-read that landed meanwhile (`applyStoreDeadline`, L5K-R16).
            let work = await self.store.runDueWork()
            guard self.isRunning else {
                return
            }
            self.applyStoreDeadline(work.nextDeadline, readSince: since)
            if work.reapedBytes > 0 {
                // REENTRANCY: f-4 (proposed) — the lifecycle; the ledger's base is replaced by a fresh read (a read that
                // fails leaves the last figures, which then decide), and every job parked for space is re-read below.
                _ = try? await self.readFreeSpace()
                guard self.isRunning else {
                    return
                }
                // Reaped bytes wake the `awaitingSpace` jobs, re-checked with the `insufficientSpace` ones in one sweep.
                self.sweepSpaceParked(.reclaimed)
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
    /// now (the watcher re-arms it), or a run still in place leaves it to that run's finish (`reconsiderPendingRun`, F-3).
    /// It starts through `reconsiderPendingRun`, which reads the gate at `now`, so no pending run starts while the gate it
    /// waits on is closed (F-40).
    func pendingRunDeadlineFired() {
        guard let pending = self.state.pendingRun else {
            return
        }
        if pending.gate == .conditions, self.laneVerdict(.bulk) != .admit {
            self.state.pendingRun?.scheduled = false
            return
        }
        self.reconsiderPendingRun()
    }

    /// After a breaker deadline fired, keeps the next one (a watchdog of a new probe) in the heap.
    private func scheduleBreakerDeadlineIfStillPending(_ origin: String, now: MonotonicInstant) {
        if let at = self.state.breakers[origin]?.nextDeadline(), at > now {
            self.state.heap.schedule(.breaker(origin), at: at)
        }
    }

    /// Re-reads `store.nextDeadline()` into the heap (RE-S40), against the updates that land while the read is in
    /// flight (`applyStoreDeadline`).
    func refreshStoreDeadline() async {
        let since = self.state.storeDeadlineUpdates
        // REENTRANCY: RE-S40 — the lifecycle; the answer is applied against the updates that landed meanwhile, so a stale
        // entry is replaced by the newest deadline and a newer one is never dropped.
        let deadline = await self.store.nextDeadline()
        if case .armed = self.state.storeDeadlineReadHold {
            // REENTRANCY: f-8 (proposed) — nothing: a test seam no production path arms, resumed once by
            // `releaseStoreDeadlineRead()` or by shutdown; the lifecycle is re-read below as without it.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.state.storeDeadlineReadHold = .holding(continuation)
                self.notifyObservers()
            }
        }
        guard self.isRunning else {
            return
        }
        self.applyStoreDeadline(deadline, readSince: since)
    }

    /// Applies an answer of the store's deadline (a re-read, the alarm's `runDueWork()` report, a lease release) that was
    /// requested when `storeDeadlineUpdates` was `since`. The store answers in its own order and the engine resumes the
    /// answers in its own (task priorities), so when another update landed while this one was in flight the two may have
    /// crossed: the earlier deadline is kept then, never the later one or none, and at worst the alarm wakes once early,
    /// its `runDueWork()` report re-arming from the newest deadline. With no update meanwhile the answer replaces the
    /// heap's store entry (orchestrator ruling L5K-R16).
    func applyStoreDeadline(_ deadline: MonotonicInstant?, readSince since: UInt64) {
        guard self.state.storeDeadlineUpdates != since, let landed = self.state.storeDeadline else {
            self.setStoreDeadline(deadline)
            return
        }
        self.setStoreDeadline(deadline.map { min($0, landed) } ?? landed)
    }

    /// Test seam: the next `refreshStoreDeadline()` waits once the store answered, until `releaseStoreDeadlineRead()`
    /// (orchestrator ruling L5K-R16): a test lands a newer read meanwhile.
    func holdNextStoreDeadlineRead() {
        self.state.storeDeadlineReadHold = .armed
    }

    /// Test seam: lets a held re-read apply its answer, or disarms a hold nothing reached; shutdown calls it too.
    func releaseStoreDeadlineRead() {
        let hold = self.state.storeDeadlineReadHold
        self.state.storeDeadlineReadHold = .idle
        if case .holding(let continuation) = hold {
            continuation.resume()
        }
    }

    /// Test seam: whether a re-read of the store's deadline waits for `releaseStoreDeadlineRead()`.
    var storeDeadlineReadHeld: Bool {
        if case .holding = self.state.storeDeadlineReadHold {
            return true
        }
        return false
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
    /// `settleUnwakeableSpaceWaits`). Every update is counted (`storeDeadlineUpdates`, `applyStoreDeadline`).
    func setStoreDeadline(_ deadline: MonotonicInstant?) {
        self.state.storeDeadlineUpdates &+= 1
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
    /// flight, the settling read of `settleUnwakeableSpaceWaits` in flight, or a space sweep's follow-up owed.
    var spaceWakeExpected: Bool {
        self.state.storeDeadline != nil || self.state.storeWorkInFlight || self.state.spaceDeadlineReread || self.state.spaceSettleRead
            || self.state.spaceSweepFollowUp != nil
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
        guard self.state.spaceParked.contains(where: { self.state.jobs[$0]?.state == .blocked(.awaitingSpace) }) else {
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

    /// The read `settleUnwakeableSpaceWaits` owes, then each job still parked `awaitingSpace` is decided on it
    /// (`sweepSpaceParked(.settle)`, with the `insufficientSpace` ones): one the volume holds now is re-queued; one that
    /// still lacks room stays parked when something armed meanwhile will run the store's due work, and is otherwise
    /// parked `insufficientSpace` with the figures of this read (ARCHITECTURE §7.6's row for a shortage without pending
    /// reclaim; F-22's convention): waiters and ensures get the typed figures at once, a run settles blocked and stays
    /// due, and the job is re-admitted at any later free-space read that holds it, a read after reaped bytes included. A
    /// read that fails leaves the last figures in place; they decide.
    private func settleSpaceWaitsOnFreshRead() async {
        // REENTRANCY: f-4 (proposed) — the lifecycle, then every parked job's state and the wakes armed meanwhile are
        // re-read by the sweep; the ledger's base is the read just adopted.
        _ = try? await self.readFreeSpace()
        self.state.spaceSettleRead = false
        guard self.isRunning else {
            return
        }
        self.sweepSpaceParked(.settle)
    }

    /// A store call that may have reclaimed bytes outside the alarm's own work (a purge's reaper reaps every deletable
    /// blob, not only the purged ones): the jobs parked for lack of space are re-checked on a fresh read at once, as after
    /// the alarm's reaped bytes, rather than at the store's next deadline (`awaitingSpace`) or at the next read
    /// (`insufficientSpace`) (review of close-out cycle 5). Nothing is read while no job is parked for space.
    func spaceMayHaveBeenReclaimed() async {
        guard !self.state.spaceParked.isEmpty else {
            return
        }
        // REENTRANCY: f-4 (proposed) — the lifecycle; the ledger's base is replaced by a fresh read (a read that fails
        // leaves the last figures, which then decide), and every job parked for space is re-read by the sweep.
        _ = try? await self.readFreeSpace()
        guard self.isRunning else {
            return
        }
        self.sweepSpaceParked(.reclaimed)
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
