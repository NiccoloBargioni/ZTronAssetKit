import ZTronAssetModel

/// An ENOSPC whose verdict (`spaceFailed`: retry, wait for the reaper, or park) waits for an owed follow to end.
struct DeferredSpaceFailure: Hashable {
    /// The job whose attempt failed.
    let transfer: TransferID
    /// The job's epoch when it failed: a later epoch is another job of the same content.
    let epoch: UInt64
    /// The bytes the attempt needed (the transport's `required`, else the entry's size).
    let required: Int64
}

/// Space decisions wait for an owed follow (R-SYN-11, F-28; Stage 3 close-out, design D1 "defer").
///
/// A follow changes what every space decision reads: a visit moves an id's interests to its new content (raising that
/// job's lane, its place in the pump's order and the volume it is judged on), lowers or supersedes the job the id left
/// (its in-flight bytes leave the ledger), and ends a dropped id's interests. A decision taken while the follow still
/// owes visits judged jobs at places, on volumes and against room the visits were about to change, and each cycle that
/// brought one visit forward to one decision site left another site reading the pre-visit state (close-out cycles 2 to 8:
/// PROBE-C7-RANK-*, PROBE-C8-DROPPED*, PROBE-C8R-INFLIGHT-PROMOTE). So while a follow is owed no decision that reads the
/// headroom ledger is taken at all: a space sweep, a join's or a promotion's re-check of a job parked `insufficientSpace`,
/// an ENOSPC's verdict and the pump's start or park of a job the ledger judges are each left to one turn after the
/// follow's last visit, which takes them as the follow left the jobs. Every decision then reads a state in which the
/// follow visited every moved and dropped id first, whichever of the two ran first.
extension SyncEngine {
    /// The jobs whose deferred re-check one turn takes at most before it leaves the rest to another turn (C2): a re-check
    /// is one ledger read and a re-queue or a fail-fast, about a park's cost.
    static let spaceRechecksPerTurn = 512

    /// Whether the follow left space decisions to take: a sweep, re-checks, or ENOSPC verdicts.
    var spaceDecisionsOwed: Bool {
        self.state.spaceSweepAfterFollow != nil || !self.state.spaceRechecksAfterFollow.isEmpty || !self.state.spaceFailuresAfterFollow.isEmpty
    }

    /// Whether a space decision must wait: a follow is owed, or the decisions it deferred have not been taken yet (they
    /// are taken in request order after its last visit, so a later request waits behind them).
    var spaceDecisionsWait: Bool {
        self.followOwed || self.spaceDecisionsOwed
    }

    /// Leaves `sweep` to the follow's end, merged with any sweep already left there.
    func deferSpaceSweep(_ sweep: SpaceSweep) {
        if self.state.spaceSweepAfterFollow == nil {
            // Its place among the re-checks: those asked for before it are taken before it.
            self.state.spaceSweepPosition = self.state.spaceRechecksAfterFollow.count
        }
        self.state.spaceSweepAfterFollow = sweep.merged(with: self.state.spaceSweepAfterFollow)
        self.scheduleSpaceDecisionsAfterFollow()
    }

    /// Leaves the re-check of a job parked `insufficientSpace` that a join or a promotion asked for to the follow's end:
    /// the waiters and ensures that joined it meanwhile are answered then, from the room the follow leaves.
    func deferSpaceRecheck(_ transfer: TransferID) {
        if self.state.spaceRecheckSet.insert(transfer).inserted {
            self.state.spaceRechecksAfterFollow.append(transfer)
        }
        self.scheduleSpaceDecisionsAfterFollow()
    }

    /// Leaves an ENOSPC's verdict to the follow's end; the job stays `failed` until then.
    func deferSpaceFailure(_ failure: DeferredSpaceFailure) {
        self.state.spaceFailuresAfterFollow.append(failure)
        self.scheduleSpaceDecisionsAfterFollow()
    }

    /// Whether the pump leaves `job` at the head of its queue for an owed follow: it holds an id the copy maps elsewhere
    /// or no longer lists (`awaitsFollow`), or space decisions wait and its gate would read the ledger (a known size, a
    /// free-space read, no adoption) to start or park it. A start takes room the follow may give to work it raises
    /// ahead of this job, and a park answers a shortage the follow may end. A gate that blocks for another reason
    /// (offline, a policy, the origin) parks the job as before: those verdicts read no room.
    func waitsForFollow(_ job: Job) -> Bool {
        if self.awaitsFollow(job) {
            return true
        }
        guard self.spaceDecisionsWait, job.adopt == nil, self.state.freeSpace != nil, self.spaceSize(of: job) > 0 else {
            return false
        }
        switch self.gate(job.transfer) {
        case .start, .block(.insufficientSpace), .block(.awaitingSpace):
            return true
        case .wait, .block:
            return false
        }
    }

    /// Schedules the turn that takes the deferred decisions once no follow is owed; the follow's last turn calls it again.
    func scheduleSpaceDecisionsAfterFollow() {
        guard !self.followOwed, self.spaceDecisionsOwed, !self.state.spaceDecisionsTurnScheduled else {
            return
        }
        self.state.spaceDecisionsTurnScheduled = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the turn re-reads whether a follow is
            // owed again (a later apply's), each deferred job's state and epoch, and the ledger as it stands then.
            await engine.takeSpaceDecisionsAfterFollow()
        }
        if spawned == nil {
            // Shutting down: nothing is decided any more.
            self.state.spaceDecisionsTurnScheduled = false
            self.dropDeferredSpaceDecisions()
        }
    }

    /// Forgets every deferred decision (shutdown).
    func dropDeferredSpaceDecisions() {
        self.state.spaceSweepAfterFollow = nil
        self.state.spaceRechecksAfterFollow = []
        self.state.spaceRecheckSet = []
        self.state.spaceFailuresAfterFollow = []
        self.state.spaceSweepPosition = 0
    }

    /// Takes the deferred decisions: the ENOSPC verdicts first (each job's own attempt, at most the transfers that were
    /// in flight), then the re-checks and the sweep in the order they were first asked for, at most
    /// `spaceRechecksPerTurn` re-checks or the sweep per turn (the sweep collects and orders every space-parked job: it
    /// shares its turn with nothing larger, C2); a re-check asked for after the sweep waits for it. Once
    /// nothing deferred is left, a pump turn serves the jobs left at their queues' heads. A follow owed again (a later
    /// apply landed) keeps them all for its own end.
    private func takeSpaceDecisionsAfterFollow() {
        self.state.spaceDecisionsTurnScheduled = false
        guard self.isRunning, !self.followOwed else {
            return
        }
        let failures = self.state.spaceFailuresAfterFollow
        self.state.spaceFailuresAfterFollow = []
        for failure in failures where self.state.jobs[failure.transfer]?.epoch == failure.epoch {
            self.decideSpaceFailure(failure.transfer, required: failure.required)
        }
        if let sweep = self.state.spaceSweepAfterFollow, self.state.spaceSweepPosition == 0 {
            self.state.spaceSweepAfterFollow = nil
            self.judgeSpaceSweep(sweep)
        } else {
            // The re-checks asked for before the sweep, or all of them when none is owed.
            let limit = self.state.spaceSweepAfterFollow == nil ? Self.spaceRechecksPerTurn : min(Self.spaceRechecksPerTurn, self.state.spaceSweepPosition)
            let taken = Array(self.state.spaceRechecksAfterFollow.prefix(limit))
            self.state.spaceRechecksAfterFollow.removeFirst(taken.count)
            if self.state.spaceSweepAfterFollow != nil {
                self.state.spaceSweepPosition -= taken.count
            }
            for transfer in taken {
                self.state.spaceRecheckSet.remove(transfer)
                self.recheckSpaceParked(transfer)
            }
        }
        self.scheduleSpaceDecisionsAfterFollow()
        self.checkRunSettled()
        if !self.spaceDecisionsWait {
            // The jobs the pump left at their queues' heads (`pumpWaitsForFollow`) are served in a turn of their own: this
            // one may have swept every space-parked job (C2).
            self.schedulePumpFollowUp()
        }
        self.settleUnwakeableSpaceWaits()
        self.rearm()
        self.reconcileIdle()
    }

    /// The re-check a join or a promotion of a job parked `insufficientSpace` asked for (`failFastJoiner`, `relane`): the
    /// job is re-queued when the ledger holds it, and otherwise its waiters and ensures, the interests that joined it
    /// while the re-check waited (a park answers every one it finds), get the answer a job parked now would give.
    private func recheckSpaceParked(_ transfer: TransferID) {
        guard let job = self.state.jobs[transfer], job.state == .blocked(.insufficientSpace) else {
            return
        }
        if self.spaceBlock(job) == nil {
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
            }
            return
        }
        self.failFast(transfer, reason: .insufficientSpace)
    }
}
