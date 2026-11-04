import Foundation
import ZTronAssetModel

/// The follow after an apply (T21/T22), bounded per actor turn (C2; Stage 3, S3-PERF-02 and its cycle-2 residual).
extension SyncEngine {
    /// The jobs one follow turn visits at most before it leaves the rest to an owned follow-up turn. A visit that moves
    /// a job supersedes it, re-routes each interest and creates the job of the id's new content: about 10 to 12 µs in
    /// release, so a turn of 256 visits stays near 3 ms. In one turn, a sync whose manifest changed the content of every
    /// member of a waiting 10,000-member prefetch group held the actor 111 to 145 ms (`changedRefreshTurns`, the close-out
    /// cycle-1 verifier's PROBE-V9).
    static let followsPerTurn = 256

    /// The entries of a replaced copy one follow turn compares with the copy at most, and the transfers of changed
    /// entries it formats at most: a comparison is a lookup and a checksum comparison (about 0.1 µs), a formatted transfer
    /// and its job lookup about 0.75 µs in release. The whole pass over 10,000 changed entries took 7.5 to 15 ms in one
    /// turn, and the sort of 10,000 transfers 3.6 ms more; a copy of SPEC §6's 10,000 entries where nothing moved is
    /// still compared in one turn.
    static let followScansPerTurn = 16_384
    /// See `followScansPerTurn`.
    static let followFormatsPerTurn = 2_048

    /// Moves every job to the engine's copy of the applied manifest, which replaced `previous`: a job none of whose ids
    /// still want its content is superseded (its interests follow their entries, T22, or end, T21), one some of whose ids
    /// moved lets them go. A job that follows `previous` can only have moved for an id whose transfer differs between
    /// the two copies, and that id's job is the transfer `previous` named for it; every other job that may not follow
    /// the copy is in `unfollowed`. So the follow visits those jobs, not the whole table: at SPEC §6's 10,000, a sorted
    /// walk of every job after every apply held the actor 10 to 12 ms although nothing moved (C2; Stage 3,
    /// S3-PERF-02). One pass over `previous` with one lookup and a key comparison per id, and a transfer formatted only
    /// for an id that moved.
    ///
    /// The pass and the visits are bounded per turn (`followScansPerTurn`, `followFormatsPerTurn`, `followsPerTurn`); the
    /// rest is owed to owned follow-up turns (`followScans`, `followOrder`). The visits go in `unfollowed`'s transfer
    /// order, then in the order the pass finds the moved jobs (the replaced copy's entry order), each job once. A job
    /// waits in `unfollowed` from the pass's finding until its visit, which is what that set means (it may not follow
    /// the copy); a job the pass has not reached yet follows a copy whose pass is owed. A later apply's follow keeps the
    /// visits still owed in their order and appends the other jobs of `unfollowed`, sorted, then queues its pass behind
    /// the owed ones; every pass compares with the copy as it stands when it runs. Sorting the owed visits again visited
    /// them in another order than a follow that had visited first, so the new contents' jobs were created, and served,
    /// in that other order (Stage 3 close-out cycle 9, amendment (e) of S3-R11). While an older pass is still owed, the
    /// other jobs of `unfollowed` wait for it too (`FollowScan.carried`): a visit-first engine's older pass had ended at
    /// this apply and placed its finds first, and appending them now put them ahead of the older pass's later finds
    /// (cycle 11, S3-R14 item 2). While a follow is owed no admission is made and no space verdict given
    /// (`followBarrier`, F-28), no run settles (a claim may still move) and no job held for a manifest catch-up is
    /// released (it may be one the follow moves). Every job this apply's follow visits is visited under the apply's
    /// decision instant (`followStamps`, S3-R15 item 1), the instant a visit-first engine visited it at. The apply is
    /// counted (`appliesFollowed`) before any visit, so a visit tells it from the attempt ends and verdicts before it.
    func followApplied(from previous: ValidatedManifest) {
        self.state.appliesFollowed += 1
        let stamp = self.worldStamp()
        let owed = self.state.followOrder[self.state.followNext...]
        let owedSet = Set(owed)
        let others = self.state.unfollowed.subtracting(owedSet).subtracting(self.state.followCarried).sorted()
        let changed = previous.digest != self.state.applied.digest || previous.count != self.state.applied.count
        if self.state.followScans.isEmpty {
            self.state.followOrder = Array(owed) + others
            for transfer in others where self.state.followStamps[transfer] == nil {
                self.state.followStamps[transfer] = stamp
            }
            if !self.state.jobs.isEmpty, changed {
                self.state.followScans.append(FollowScan(manifest: previous, stamp: stamp))
            }
        } else {
            self.state.followOrder = Array(owed)
            self.state.followCarried.formUnion(others)
            // A pass over an unchanged copy compares every entry and finds nothing; it is queued only to carry `others`.
            if changed || !others.isEmpty {
                self.state.followScans.append(FollowScan(manifest: changed ? previous : self.state.applied, carried: others, stamp: stamp))
            }
        }
        self.state.followNext = 0
        if self.state.applyWalked {
            // The apply's walk for the publications in flight took this turn (`bringInboundOntoPublications`, C2): the
            // follow-up turn it scheduled is the follow's first.
            self.state.applyWalked = false
            return
        }
        self.continueFollow()
    }

    /// Whether a follow still owes a pass, moves (`inboundOwed`), the rest of a visit (`EngineState.followMoving`) or
    /// visits to follow-up turns.
    var followOwed: Bool {
        !self.state.followScans.isEmpty || self.state.followNext < self.state.followOrder.count || self.inboundOwed
            || self.state.followMoving != nil
    }

    /// Whether moves an attempt's end or an apply found (`bringInbound`) are still owed (`EngineState.inboundMoves`).
    var inboundOwed: Bool {
        self.state.inboundNext < self.state.inboundMoves.count
    }

    /// Whether admissions and space verdicts wait (the follow barrier, F-28; Stage 3 close-out cycle 9, S3-R11 design
    /// D3): a follow is owed, or the events that waited for the last one are not all applied yet (`eventsAfterFollow`,
    /// drained a bounded batch per turn). Every start, park, space verdict and failure verdict of a job that holds a
    /// moved id reads lanes, ranks, interests or bytes in flight that the owed visits change; decided before them, its
    /// answer depended on whether a visit ran first (the close-out cycles 2 to 8 each found a new member of that class).
    var followBarrier: Bool {
        self.followOwed || !self.state.eventsAfterFollow.isEmpty
    }

    /// Whether an event arriving now waits for the follow (`eventsAfterFollow`): behind the barrier, unless the follow's
    /// own visit makes it or the drain of the waiting events applies it.
    var defersToFollow: Bool {
        self.followBarrier && !self.state.inFollowVisit && !self.state.drainingAfterFollow
    }

    /// Continues the follow's owed passes, then its owed moves (`continueInbound`), then the rest of a visit too large for
    /// one turn (`continueVisitRemainder`), then visits its next jobs, at most `followsPerTurn` moves and visits together
    /// and `followIDsPerTurn` ids they move (`FollowBudget`); schedules a follow-up turn for the rest, or ends the follow:
    /// the jobs held for a manifest catch-up that no catch-up holds any more are released, and the run is checked. No job
    /// is visited while a move or a visit's rest is owed: the moves stand for visits a visit-first engine had made before
    /// any visit still owed (Stage 3 close-out cycle 18, ruling S3-R20 item 3), and a visit's rest for the visit it
    /// made at once (cycle 19, ruling S3-R22 item 1), so they take the turn's budget first.
    private func continueFollow() {
        self.continueFollowScans()
        var budget = FollowBudget(holders: Self.followsPerTurn, ids: self.state.followIDsPerTurn)
        var moved = self.continueInbound(&budget)
        if !self.inboundOwed, self.continueVisitRemainder(&budget) {
            moved = true
        }
        var skipped = 0
        // A visit's rest owed (`followMoving`) has spent the turn's ids, so no visit follows it in this turn.
        while !self.inboundOwed, budget.holders > 0, budget.ids > 0, skipped < Self.followSkipsPerTurn, self.state.followNext < self.state.followOrder.count {
            let transfer = self.state.followOrder[self.state.followNext]
            self.state.followNext += 1
            let stamp = self.state.followStamps.removeValue(forKey: transfer)
            // A job owed a visit stays in `unfollowed` until it; one that left it was removed meanwhile (`removeJob`).
            guard self.state.unfollowed.remove(transfer) != nil else {
                skipped += 1
                continue
            }
            budget.holders -= 1
            if self.visit(transfer, at: stamp ?? self.worldStamp(), budget: &budget) {
                moved = true
            }
        }
        if self.followOwed {
            // A pump that left a queue's head to this follow (`pumpWaitsForFollow`) looks again: its job may be followed now.
            if moved || self.state.pumpWaitsForFollow {
                self.pump()
            }
            self.scheduleFollowFollowUp()
            return
        }
        self.state.followOrder = []
        self.state.followNext = 0
        self.state.followsEnded += 1
        if self.state.manifestCatchUps == 0, !self.state.heldForManifest.isEmpty {
            // `manifestCaughtUp` left them held while this follow was owed.
            self.state.heldForManifest.removeAll()
            moved = true
        }
        self.checkRunSettled()
        if moved || self.state.pumpWaitsForFollow {
            self.pump()
        }
        // The drain's first batch runs in this turn, on the ids its visits left.
        self.drainEventsAfterFollow(ids: budget.ids)
        self.endWorldHistory()
    }

    /// The entries of the follow's order a turn passes at most whose job left `unfollowed` (removed meanwhile, as the
    /// holders an owed move supersedes are): each costs two lookups, and a turn that ends the follow also runs the drain,
    /// whose verdicts answer every interest of their jobs. At 10,000 holders converging on one content, about 9,500 such
    /// entries took about 2 ms in the turn whose drain then answered 10,001 ids in about 6 ms (C2; Stage 3 close-out
    /// cycle 18, `BenchSync.concentrationNotFoundTurns`). A pass is not a visit: `followsPerTurn` counts visits only.
    static let followSkipsPerTurn = 4_096

    /// The events one drain turn applies at most (`drainEventsAfterFollow`): an event costs about what a re-queue or a park
    /// costs, so a turn stays near 1 ms (C2) whatever arrived during the follow (a 10,000-member group's joins). An event
    /// that is itself a bounded pass (`EventAfterFollow.endsDrainBatch`: a conditions element's pass, a re-admission, a
    /// throttle's fail-fast turn) ends its batch, so a turn holds at most one of them.
    static let eventsAfterFollowPerTurn = 512

    /// Applies the events that waited for the follow (F-28) as a visit-first engine meets them: after the follow's
    /// own last turn and its pump, in arrival order, on the state every visit left, at most `eventsAfterFollowPerTurn`
    /// per turn; the barrier holds (`followBarrier`) until the last is applied, and no pump runs during a batch or
    /// between two (`pump`: a slot freed between two batches went to work queued before the user work a later batch
    /// queues, the cycle-9 amendment (d)); after the last, the run is checked and the queues pumped. Each event
    /// re-validates what it names (the job, its epoch, the interest): a job that ended or moved meanwhile is skipped. A
    /// sweep owed meanwhile is a follow-up turn already (`sweepSpaceParked`).
    ///
    /// The batch's visits after verdicts (`followAfterVerdict`) share `ids`, what the turn has left (a whole turn's when
    /// `nil`: a turn of its own), so a batch of verdicts moves no more ids in one turn than a follow turn moves (C2;
    /// Stage 3 close-out cycle 20, ruling S3-R25 item 1). Once they are spent the rest of the batch goes back to the
    /// head of `eventsAfterFollow`, in order, for the next drain turn, as it does after a visit that leaves a rest; the
    /// events wait in order either way, so no answer changes.
    ///
    /// A verdict's bucket (`EngineState.joinsBehindVerdicts`) joins its batch right behind the verdict, newest first, and
    /// the joins the batch has no room for wait at the head of `eventsAfterFollow` in that order: the batches, their
    /// boundaries, their order and the barrier inside each replay are those of a queue that held the joins right behind
    /// the verdict (Stage 3 close-out cycle 21, ruling S3-R26 item 2).
    func drainEventsAfterFollow(ids: Int? = nil) {
        guard !self.followOwed, !self.state.eventsAfterFollow.isEmpty else {
            return
        }
        // The waiting events in order, each verdict's bucket right behind it, newest first; the joins of a bucket the
        // batch has no room for wait at the queue's head for the next batch, in that order.
        var batch: [(EventAfterFollow, WorldStamp)] = []
        var overflow: [(EventAfterFollow, WorldStamp)] = []
        var consumed = 0
        while consumed < self.state.eventsAfterFollow.count, batch.count < Self.eventsAfterFollowPerTurn {
            let event = self.state.eventsAfterFollow[consumed]
            batch.append((event, self.state.eventStamps[consumed]))
            consumed += 1
            if let key = event.verdictKey, let behind = self.state.joinsBehindVerdicts.removeValue(forKey: key) {
                for entry in behind.reversed() {
                    if batch.count < Self.eventsAfterFollowPerTurn {
                        batch.append((.join(entry.join), entry.stamp))
                    } else {
                        overflow.append((.join(entry.join), entry.stamp))
                    }
                }
            }
            if event.endsDrainBatch {
                break
            }
        }
        self.state.eventsAfterFollow.replaceSubrange(0..<consumed, with: overflow.map(\.0))
        self.state.eventStamps.replaceSubrange(0..<consumed, with: overflow.map(\.1))
        self.state.drainingAfterFollow = true
        self.state.drainIDsLeft = ids ?? self.state.followIDsPerTurn
        for (offset, (event, stamp)) in batch.enumerated() {
            self.withReading(stamp) {
                self.replay(event)
            }
            // A visit after a verdict too large for the ids left (`followAfterVerdict`): a visit-first engine made it at
            // once, before the next event, so the events after it wait for its rest, in order (C2; cycle 19). With the
            // turn's ids spent and no rest, they wait for the next drain turn (cycle 20).
            if self.state.followMoving != nil || self.state.drainIDsLeft <= 0 {
                let rest = batch[(offset + 1)...]
                self.state.eventsAfterFollow.insert(contentsOf: rest.map(\.0), at: 0)
                self.state.eventStamps.insert(contentsOf: rest.map(\.1), at: 0)
                break
            }
        }
        self.state.drainingAfterFollow = false
        if self.state.followMoving != nil {
            self.scheduleFollowFollowUp()
            return
        }
        guard self.state.eventsAfterFollow.isEmpty else {
            self.scheduleDrainFollowUp()
            return
        }
        self.checkRunSettled()
        self.pump()
        self.endWorldHistory()
    }

    /// Defers `event` to the follow's end (`eventsAfterFollow`), with its decision instant (`worldStamp()`).
    func deferToFollow(_ event: EventAfterFollow) {
        self.state.eventsAfterFollow.append(event)
        self.state.eventStamps.append(self.worldStamp())
    }

    /// The instant a decision is taken at: the decision instant the engine reads under (`EngineState.reading`: the
    /// arrival of the event the drain applies, or the apply a follow's visit belongs to), or now. A visit-first engine
    /// took the decision then, so a place's request time, a backoff's start and a fail-fast answer's wait count from it.
    func decisionNow() -> MonotonicInstant {
        self.state.reading?.at ?? self.environment.time.monotonicNow()
    }

    // MARK: One view of the world per decision instant (Stage 3 close-out cycle 12, S3-R15 item 1)

    /// The decision instant now: the instant and the view of the non-ledger real-world inputs as they stand
    /// (`WorldView`), appended to `worldHistory` when it differs from the last view. Under a reading (a visit or a
    /// replay) it is that reading: nothing a visit or a replay decides is an input of its own.
    func worldStamp() -> WorldStamp {
        if let reading = self.state.reading {
            return reading
        }
        let origin = self.state.remote?.originID
        let view = WorldView(
            throttle: origin.flatMap { self.state.throttles[$0] },
            breaker: origin.flatMap { self.state.breakers[$0] },
            conditions: ConditionsSnapshot(conditions: self.state.conditions, pausedForThermal: self.state.pausedForThermal),
            edgeSerial: self.state.networkEdgeSerial
        )
        if self.state.worldHistory.last != view {
            self.state.worldHistory.append(view)
        }
        return WorldStamp(at: self.environment.time.monotonicNow(), view: self.state.worldHistory.count - 1)
    }

    /// Runs `body` under the decision instant `stamp` (`EngineState.reading`): `decisionNow()` is its instant, the
    /// origin's throttle and breaker are read from its view (`throttleRecorded()`, `breakerRecorded()`), and the
    /// lane-wide conditions are its view's for the body's duration (the cycle-11 `withConditions`, folded in). Every
    /// replayed event and every follow visit runs under one, so each reads the world as it stood at its visit-first
    /// instant, whatever arrived since. Synchronous: no other turn sees the swap; the inputs themselves are applied on
    /// arrival only, so nothing the body does writes the swapped conditions.
    func withReading<T>(_ stamp: WorldStamp, _ body: () -> T) -> T {
        let previous = self.state.reading
        let conditions = self.state.conditions
        let thermal = self.state.pausedForThermal
        let view = self.state.worldHistory[stamp.view]
        self.state.reading = stamp
        self.state.conditions = view.conditions.conditions
        self.state.pausedForThermal = view.conditions.pausedForThermal
        let result = body()
        self.state.reading = previous
        self.state.conditions = conditions
        self.state.pausedForThermal = thermal
        return result
    }

    /// The view the engine reads under, if any (`withReading`).
    var readingView: WorldView? {
        self.state.reading.map { self.state.worldHistory[$0.view] }
    }

    /// The origin's recorded throttle end at the decision instant: the reading's view, else the live end.
    func throttleRecorded() -> MonotonicInstant? {
        if let view = self.readingView {
            return view.throttle
        }
        return self.state.remote.flatMap { self.state.throttles[$0.originID] }
    }

    /// The origin's breaker at the decision instant: the reading's view, else the live breaker.
    func breakerRecorded() -> CircuitBreaker? {
        if let view = self.readingView {
            return view.breaker
        }
        return self.state.remote.flatMap { self.state.breakers[$0.originID] }
    }

    /// A throttle a decision under a reading found ended at its instant (`readmitOpenedOriginGates`): the reading's view
    /// shows it cleared from then on. The live throttle is cleared only when it has ended by the reading's instant too: a
    /// later 429 may have extended it since (`endThrottle`).
    func readingClearedThrottle() {
        self.changeReadingView { $0.throttle = nil }
    }

    /// Applies a change the decision under a reading makes to the origin's throttle or breaker (a visit's abandon, a
    /// throttle it found ended) to the reading's view as well, so the rest of that decision, and the places it gives,
    /// read the world as a visit-first engine's decision left it at that instant: a new view, so the events that share
    /// the old one keep it. Nothing without a reading.
    func changeReadingView(_ change: (inout WorldView) -> Void) {
        guard let stamp = self.state.reading else {
            return
        }
        var view = self.state.worldHistory[stamp.view]
        change(&view)
        guard view != self.state.worldHistory[stamp.view] else {
            return
        }
        self.state.worldHistory.append(view)
        self.state.reading = WorldStamp(at: stamp.at, view: self.state.worldHistory.count - 1)
    }

    /// Ends the world history once the barrier is down (`EngineState.worldHistory`): no decision reads an older view
    /// any more.
    func endWorldHistory() {
        guard !self.followBarrier, self.state.reading == nil else {
            return
        }
        self.state.worldHistory = []
        self.state.followStamps = [:]
    }

    /// Applies one event that waited for the follow (`drainEventsAfterFollow`).
    private func replay(_ event: EventAfterFollow) {
        switch event {
        case .spaceFailure(let transfer, let epoch, let required):
            // A job that ended or was superseded meanwhile has nobody left to answer; one the drain's earlier join created
            // for the same content is not the job that failed (PROBE-C15R-SPACE-EPOCH).
            guard let job = self.state.jobs[transfer], job.epoch == epoch else {
                return
            }
            let off = self.takeOffMovedBefore(job)
            let movesAfter = self.endDeferral(job)
            self.decideSpaceFailure(transfer, required: required)
            self.followAfterVerdict(transfer, movesAfter)
            self.rerouteMovedBefore(off, from: transfer)
        case .attemptFailed(let transfer, let epoch, let verdict):
            self.replayVerdict(transfer, epoch: epoch, verdict)
        case .join(let join):
            self.replayJoin(join)
        case .removal(let token, let transfer):
            self.replayRemoval(token, from: transfer)
        case .conditions(let edge):
            self.applyConditionsToJobs(edge: edge)
        case .readmit(let passes):
            self.readmit(passes)
        case .unblock(let kind):
            self.unblockOrigin(kind)
        case .retryDue(let transfer, let epoch):
            self.retryDue(transfer, epoch: epoch)
        case .throttleAnswers:
            self.answerThrottledUsersNow()
        case .spaceSweep(let sweep):
            self.judgeSpaceSweep(sweep)
        }
    }

    /// Schedules one later turn for the events a drain turn left (C2). Only a running engine drains, so the task is
    /// always spawned (`spawn` refuses one only while shutting down, shut down or degraded): every drain runs in a
    /// running turn (a follow's last turn, a drain follow-up past its lifecycle guard, `drainFollowUp`), the engine
    /// degrades only while starting, before any apply, and shutdown's first turn clears the waiting events with the
    /// follow's tables (`drainEverything`), after which a scheduled follow-up returns at once. The branch that cleared
    /// them when no task could be spawned, which no path reached, was removed under ruling S3-R26 item 6 (Stage 3
    /// close-out cycle 21), as its twin in `scheduleFollowFollowUp` was; `followBarrierViolations` checks the assumption.
    private func scheduleDrainFollowUp() {
        guard !self.state.drainFollowUpScheduled else {
            return
        }
        self.state.drainFollowUpScheduled = true
        self.spawn(.entry) { engine in
            // REENTRANCY: RE-S45 (proposed) — the drain's follow-up hops onto the actor and re-reads the waiting events
            // and each job, epoch and interest they name (`drainEventsAfterFollow` re-validates every one); a follow
            // begun meanwhile holds them again until its own end drains them.
            await engine.drainFollowUp()
        }
    }

    /// The scheduled continuation of `drainEventsAfterFollow`.
    private func drainFollowUp() {
        if self.state.drainFollowUpsHeld {
            // Test seam: the events stay waiting and the turn stays scheduled until the release runs it.
            self.state.drainFollowUpWaiting = true
            self.notifyObservers()
            return
        }
        self.state.drainFollowUpScheduled = false
        guard self.isRunning else {
            return
        }
        self.drainEventsAfterFollow()
        self.rearm()
        self.reconcileIdle()
        self.notifyObservers()
    }

    /// Whether `job` holds an id the engine's copy lists at another transfer while a follow is owed: the job an owed
    /// visit moves. An id the copy does not list is not counted: a waiter joined from the store's newer manifest
    /// (`EngineManifest.join`) holds one legitimately. One lookup in the copy and one key comparison per id of the job
    /// (`sameTransfer` against the job's own entry, whose transfer is the job's), no transfer formatted.
    func holdsMovedID(_ job: Job) -> Bool {
        guard self.followOwed else {
            return false
        }
        return job.assets.contains { asset in
            self.state.applied.entry(for: asset).map { !SyncEngine.sameTransfer($0, job.entry) } ?? false
        }
    }

    /// Defers the exit verdict of an attempt that ends while the barrier holds (`defersToFollow`; Stage 3 close-out
    /// cycle 9, amendment (c) of S3-R11, widened in cycle 11 by S3-R14): the attempt leaves flight now (`failed(.nextRun)`,
    /// its bytes no longer in the ledger, as any ended transfer's, S3-R11 R1) and nobody is answered; the follow's own
    /// visits move the ids in their order, and the drain gives `verdict` to the job they leave (`replayVerdict`).
    /// Every exit waits, whether or not the job holds a moved id: a visit may raise or lower any job, join it or move an
    /// interest onto it, so a verdict decided before the visits read a lane, a rank or interests the visits change (a
    /// policy pause parked on the pre-visit lane, a 429's backoff on the pre-visit lane's policy; the cycle-10 verifiers'
    /// PROBE-C10-PAUSE-LANE and PROBE-C10-THROTTLE-LANE). Bringing the visit forward to the failure (the cycles before)
    /// moved that job's ids ahead of earlier owed visits (PROBE-J-FAIL-REROUTE, PROBE-J-FAIL-TICKET). Returns `true` when
    /// the verdict waits. A job not in flight or failed is decided now: only an attempt's end is deferred.
    ///
    /// While the verdict waits, the job is inert as a visit-first engine's job is while its attempt still runs: the
    /// follow's own visit may move its ids or join it (its re-lane then does nothing, `relane`), and every other input
    /// that meets it (a join, a withdrawal, a conditions element, an edge) waits behind the verdict as an event of its own.
    /// The deferral is recorded on the job (`recordDeferredVerdict`): a visit for an apply after it leaves the job to the
    /// verdict, as a visit-first engine's visit met the job as the verdict left it (`rerouteOnVisit`, `followAfterVerdict`).
    func defersFailure(_ transfer: TransferID, _ verdict: AttemptVerdict) -> Bool {
        guard self.defersToFollow, let job = self.state.jobs[transfer], self.exitDefers(job) else {
            return false
        }
        switch job.state {
        case .failed:
            self.state.jobs[transfer]?.active = nil
        case .downloading, .verifying, .committing:
            guard self.transition(transfer, to: .failed(.nextRun)) else {
                return false
            }
        case .queued, .blocked:
            return false
        }
        self.state.verdictsAfterFollow[transfer] = VerdictAfterFollow(epoch: job.epoch)
        self.recordDeferredVerdict(transfer)
        self.deferToFollow(.attemptFailed(transfer, epoch: job.epoch, verdict: verdict))
        self.bringInbound(transfer)
        self.notifyObservers()
        return true
    }

    /// Whether an exit of `job` would wait for the follow (`defersFailure`): only an attempt's end, of a job in flight or
    /// failed, waits.
    func exitDefers(_ job: Job) -> Bool {
        switch job.state {
        case .failed, .downloading, .verifying, .committing:
            return true
        case .queued, .blocked:
            return false
        }
    }

    /// Records the end of `transfer`'s publication in a failure (`publicationFailed`), in the turn it ends and before the
    /// bookkeeping that awaits the store (an integrity failure's record, an ENOSPC's free-space read): a visit inside that
    /// bookkeeping, for an apply made while the job still published, passes the job as a visit-first engine's visit at that
    /// apply passed it, and one for an apply made since moves its moved ids, as that engine's visit met the job failed
    /// with no verdict yet (`rerouteOnVisit`; Stage 3 close-out cycle 16, PROBE-C15C-INTEGRITY-WINDOW,
    /// PROBE-C15C-ENOSPC-PASSED). A mark whose verdict is given at once, with no follow owed, is never read: any visit
    /// after it belongs to a later apply.
    func recordPublicationEnd(_ transfer: TransferID) {
        let end = AttemptEnd(failedAfter: self.state.appliesFollowed, deferredAfter: nil)
        self.state.jobs[transfer]?.attemptEnd = end
    }

    /// Records that `transfer`'s exit verdict defers to the follow (`defersFailure`, an ENOSPC's `.spaceFailure` in
    /// `spaceFailed`): the applies followed now, and the ids a visit-first engine had moved before the verdict arrived,
    /// which the owed visit that meets the job re-routes at once (`Job.rerouteOnPass`). While a follow is owed those
    /// are the ids the copy lists elsewhere or not at all, unless the attempt ended in its publication with no apply
    /// since, whose visits passed the job publishing and keep the publication's own set, less the ids an apply moved
    /// back to the job's content while it published: that engine's visit at that apply joined them to the job
    /// publishing, so the verdict answers them, and an apply that moves them away again after the verdict moves them
    /// from the job the verdict leaves (Stage 3 close-out cycle 17). With no follow owed there are none: every visit
    /// has run, so no id the job holds is one such a visit had moved, not even one the copy does not list, such as an
    /// id a waiter joined from a newer manifest while an apply was in flight (`EngineManifest.join`), which the verdict
    /// answers (cycle 17, `EngineFollowBarrierUnlistedTests`). A visit for an apply after this instant passes the job
    /// and leaves its other moved ids to the verdict, which the drain gives before it moves them (`followAfterVerdict`;
    /// cycle 16, ruling S3-R19 item 1). The set is kept unspent as `AttemptEnd.movedBefore`: the drain takes any of its
    /// ids still on the job off before the verdict (`takeOffMovedBefore`).
    func recordDeferredVerdict(_ transfer: TransferID) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let applies = self.state.appliesFollowed
        // Computed before the job is written: an optional-chained assignment holds the state across its right side.
        let away: Set<AssetID> = self.followOwed ? job.assets.filter { asset in self.state.applied.entry(for: asset).map { !SyncEngine.sameTransfer($0, job.entry) } ?? true } : []
        let movedBefore: Set<AssetID>
        if job.attemptEnd?.failedAfter != applies {
            movedBefore = away
            let follow = self.state.followsEnded
            self.state.jobs[transfer]?.rerouteFor = follow
        } else {
            movedBefore = job.rerouteOnPass?.intersection(away) ?? []
        }
        self.state.jobs[transfer]?.rerouteOnPass = movedBefore
        let end = AttemptEnd(failedAfter: job.attemptEnd?.failedAfter ?? applies, deferredAfter: applies, movedBefore: movedBefore)
        self.state.jobs[transfer]?.attemptEnd = end
    }

    /// Whether an apply was followed since `job`'s exit verdict deferred to the follow: once the drain gives the verdict,
    /// it moves the ids those applies moved from the job the verdict leaves (`followAfterVerdict`), which the owed visits
    /// passed to the verdict. Also read by `followedLane`.
    func movesAfterVerdict(_ job: Job) -> Bool {
        job.attemptEnd?.deferredAfter.map { self.state.appliesFollowed > $0 } ?? false
    }

    /// Ends the deferral of `job`'s exit verdict as the drain gives it, and returns whether the drain moves its ids after
    /// the verdict (`movesAfterVerdict`).
    private func endDeferral(_ job: Job) -> Bool {
        let moves = self.movesAfterVerdict(job)
        self.state.jobs[job.transfer]?.attemptEnd = nil
        return moves
    }

    /// Takes off `job`, as the drain gives its waiting exit verdict, the interests in the ids a visit-first engine's
    /// visits had moved off it before the verdict arrived (`AttemptEnd.movedBefore`) that are still on it, and returns
    /// them for `rerouteMovedBefore`, after the verdict: a later apply moved them back to the job's content before the
    /// follow visited it (the visit then finds nothing moved, and a pass that compares with the copy as it stands may not
    /// find the job at all), and that engine's visit at that apply met the job as the verdict left it (Stage 3 close-out
    /// cycle 17; the cycle-16 verifiers' PROBE-C16C-VERDICT-MAPPED-BACK: left on the job, the drain's 404 answered them
    /// too, where that engine's fresh job of the content served them). A job left with no interest is retired before the
    /// verdict, as that engine's visit retired it.
    private func takeOffMovedBefore(_ job: Job) -> [(token: InterestToken, interest: JobInterest, asset: AssetID)] {
        let held = job.assets.intersection(job.attemptEnd?.movedBefore ?? [])
        guard !held.isEmpty else {
            return []
        }
        var off: [(token: InterestToken, interest: JobInterest, asset: AssetID)] = []
        self.state.jobs[job.transfer]?.assets.subtract(held)
        for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) {
            if interest.kind == .run, !interest.assets.isDisjoint(with: held) {
                // The run's claim is on no job's interest until `rerouteMovedBefore` lands it: the run check waits.
                self.state.runClaimTakenOff = true
            }
            for asset in interest.assets.sorted() where held.contains(asset) {
                _ = self.state.jobs[job.transfer]?.removeAsset(asset, for: token)
                off.append((token, interest, asset))
            }
            if self.state.jobs[job.transfer]?.interests[token]?.assets.isEmpty == true {
                self.removeInterest(token, from: job.transfer)
            }
        }
        return off
    }

    /// Re-routes, after the verdict, the interests `takeOffMovedBefore` took off `transfer`'s job: each follows its id's
    /// entry in the copy (`reroute`), to the job the verdict left or a new job of the content, or another content. A
    /// run's claim among them is landed then, so the run check that waited for it may run again (`runClaimTakenOff`).
    private func rerouteMovedBefore(_ off: [(token: InterestToken, interest: JobInterest, asset: AssetID)], from transfer: TransferID) {
        for item in off {
            self.reroute(item.token, interest: item.interest, asset: item.asset, from: transfer)
        }
        self.state.runClaimTakenOff = false
    }

    /// The visit a visit-first engine made, after it gave the verdict, at each apply since: the job the verdict left
    /// moves the ids those applies moved, which the owed visits passed to the verdict (`moves`, from `endDeferral`). A job
    /// the verdict ended has nobody left to move (`follow` finds no job). No verdict creates a job in its own turn, so the
    /// job found is the verdict's: the cycle-16 epoch check was redundant (its drop-mutant survived) and was removed in
    /// Stage 3 close-out cycle 17 under ruling S3-R16 item 3. The job follows the copy afterwards, so the next follow owes
    /// it no visit. The visit moves at most the ids the drain's turn has left (`EngineState.drainIDsLeft`), and spends
    /// them: a visit of more leaves its rest to the follow's next turns (`followMoving`; cycle 19), and the batch's
    /// visits share one turn's ids (cycle 20, ruling S3-R25 item 1).
    private func followAfterVerdict(_ transfer: TransferID, _ moves: Bool) {
        guard moves else {
            return
        }
        self.state.unfollowed.remove(transfer)
        let made = self.follow(transfer, ids: self.state.drainIDsLeft, afterVerdict: true)
        self.state.drainIDsLeft -= made.spent
    }

    /// Gives a deferred exit verdict (`defersFailure`) to the ids its job holds after the follow, unless the job ended
    /// or was superseded meanwhile: the exit the attempt's end would have taken once the follow had visited first, on
    /// the lane, interests and ranks the visits left. Every input that met the job meanwhile waits behind this event, at
    /// its own arrival, and meets the job as the verdict leaves it (PROBE-C9-JOIN-RESOLVE, PROBE-C9-JOIN-RETRY-PLACE,
    /// PROBE-C10-JOIN-RETIRE). The ids a follow's visit passed, the job publishing, stay and are answered here, as a
    /// visit-first engine answered them with the publication's outcome; the drain visits no job before its verdict
    /// (Stage 3 close-out cycle 15, ruling S3-R18 item 2: the cycle-14 `followedForVerdict` visit served only the
    /// deferred move a passed publication owed, and the visit that passes it re-routes those ids now). After the verdict,
    /// the ids an apply moved since the verdict deferred move from the job it leaves (`followAfterVerdict`), as a
    /// visit-first engine's visit at that apply moved them (cycle 16, ruling S3-R19 item 1). The ids that engine's visits
    /// had moved off the job before the verdict arrived and that are still on it are not the verdict's: taken off before
    /// it and re-routed after it (`takeOffMovedBefore`, cycle 17).
    private func replayVerdict(_ transfer: TransferID, epoch: UInt64, _ verdict: AttemptVerdict) {
        guard self.state.verdictsAfterFollow[transfer]?.epoch == epoch else {
            return
        }
        self.state.verdictsAfterFollow[transfer] = nil
        guard let job = self.state.jobs[transfer], job.epoch == epoch, case .failed = job.state else {
            return
        }
        let off = self.takeOffMovedBefore(job)
        let movesAfter = self.endDeferral(job)
        self.giveVerdict(transfer, verdict)
        self.followAfterVerdict(transfer, movesAfter)
        self.rerouteMovedBefore(off, from: transfer)
    }

    /// `replayVerdict`'s verdict for a job still `failed` at its epoch.
    private func giveVerdict(_ transfer: TransferID, _ verdict: AttemptVerdict) {
        switch verdict {
        case .resolve(let answer):
            self.resolveAll(transfer, with: .failed(answer))
        case .retry(let error, let answer, let wall):
            self.retryLater(transfer, error: error, answer: answer, wall: wall)
        case .offline(let requeue):
            if requeue {
                // An edge passed while the attempt ran (`failed`'s offline exit): a fresh attempt, no answer.
                if self.transition(transfer, to: .queued) {
                    self.enqueue(transfer)
                }
            } else if self.transition(transfer, to: .failed(.whenOnline)) {
                self.failFast(transfer, reason: .offline)
            }
        case .throttle(let facts):
            self.replayThrottle(transfer, facts)
        case .pause(let policy, let blocks):
            // `paused`'s decision on the lane the visits left, with the lane-wide blocks of the pause's arrival.
            guard self.transition(transfer, to: .queued) else {
                return
            }
            if policy, let lane = self.state.jobs[transfer]?.lane, lane < .userInitiated, let block = blocks.first(where: { $0.lane == lane })?.reason {
                self.park(transfer, reason: block)
            } else {
                self.enqueue(transfer, front: true)
            }
        case .requeue:
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
            }
        }
    }

    /// A 429's park decided after the follow (`EngineFailures.throttled`). The 429 throttled the origin when it arrived,
    /// for the backoff of the lane the owed visits leave the job (S3-R15 item 2, `followedLane`, else the job's own lane;
    /// R-SYN-5, PROBE-C10-THROTTLE-LANE, PROBE-C12-UNDECIDED-LANE), or ended the job's attempts there
    /// (`ThrottleDecision.exhausted`); the replay only parks the job the visits left and answers its users. Its fail-fast
    /// answers read the wait under the event's reading (`drainEventsAfterFollow`): at the 429's instant (`decisionNow()`),
    /// against the origin's end in the event's view (`throttleEnd`), which counts this 429 and the earlier ones, not a
    /// later 429's (PROBE-C10-THROTTLE-EXTENDED). The cycle-12 copies of that instant and end passed to `park` gave the
    /// same values and are gone (Stage 3 close-out cycle 13, S3-R16 item 3). The origin's alarm stays at the live origin's
    /// end (`park`).
    private func replayThrottle(_ transfer: TransferID, _ facts: ThrottleFacts) {
        guard self.state.jobs[transfer] != nil else {
            return
        }
        let until: MonotonicInstant
        switch facts.decision {
        case .exhausted:
            self.transition(transfer, to: .failed(.nextRun))
            self.resolveAll(transfer, with: .failed(.serverUnavailable(retryAfter: facts.retryAfter)))
            return
        case .until(let end):
            until = end
        }
        let end = self.throttleEnd(after: until)
        if self.transition(transfer, to: .queued) {
            self.park(transfer, reason: .throttled(until: end))
        }
    }

    /// Joins an interest that waited for the follow (`addInterest`; `EventAfterFollow.join`) at its arrival place in the
    /// drain, after every event before it: to the job the visits and earlier events left, or to a new job of the content
    /// when none is left, which a visit-first engine's request would have joined or created (PROBE-C9-JOIN-RESOLVE,
    /// PROBE-C10-JOIN-RETIRE, the cycle-10 verifiers' request join). A request answered meanwhile (a waiter answered, a
    /// group released, a run ended) joins nothing; a withdrawn waiter's join is made, and its withdrawal removes it next,
    /// as a visit-first engine did both. An id a later apply moved meanwhile is re-routed as that apply's follow would
    /// have (`reroute`).
    private func replayJoin(_ join: JoinAfterFollow) {
        let transfer = join.entry.transferID
        guard self.state.joinsAfterFollow[join.token]?[join.asset] == transfer else {
            return
        }
        self.state.joinsAfterFollow[join.token]?[join.asset] = nil
        if self.state.joinsAfterFollow[join.token]?.isEmpty == true {
            self.state.joinsAfterFollow[join.token] = nil
        }
        guard self.stillWants(join) else {
            return
        }
        if join.listed, self.state.applied.entry(for: join.asset).map({ !SyncEngine.sameTransfer($0, join.entry) }) ?? true {
            self.reroute(join.token, interest: JobInterest(lane: join.lane, kind: join.kind, assets: [join.asset]), asset: join.asset, from: transfer)
            return
        }
        self.addInterest(join.token, asset: join.asset, entry: join.entry, lane: join.lane, kind: join.kind)
    }

    /// Whether the owner of a waiting join still waits for its asset in the join's transfer (`replayJoin`, and the lane a
    /// 429 is decided on, `followedLane`).
    func stillWants(_ join: JoinAfterFollow) -> Bool {
        let transfer = join.entry.transferID
        switch join.kind {
        case .waiter:
            guard let waiter = self.state.waiters[join.token] else {
                return false
            }
            return !waiter.fromStore && waiter.asset == join.asset && waiter.transfer == transfer
        case .prefetch, .ensure:
            return self.state.groups[join.token]?.pending[join.asset] == transfer
        case .run:
            return self.state.run?.token == join.token && self.state.run?.outstanding[transfer]?.contains(join.asset) == true
        case .system:
            return true
        }
    }

    /// Removes an interest whose withdrawal waited for the follow (`removeInterest`; `EventAfterFollow.removal`) at its
    /// arrival place in the drain: after the answers and joins before it, as a visit-first engine removed it (S3-R14 item
    /// 3). A withdrawn waiter's record followed the interest's re-routes (`Waiter.continuation` is `nil`); the removal
    /// takes it from the job the record names then. Any transfer cancellation the removal causes (`retire`) happens here.
    private func replayRemoval(_ token: InterestToken, from transfer: TransferID) {
        var target = transfer
        if let waiter = self.state.waiters[token], waiter.continuation == nil {
            self.state.waiters[token] = nil
            target = waiter.transfer
        }
        self.removeInterest(token, from: target)
    }

    /// Compares the owed passes' next entries with the copy, oldest pass first, within this turn's bounds: a job of an
    /// entry the copy no longer maps to the same transfer is owed a visit (it joins `unfollowed` and `followOrder` once).
    /// A pass that begins first places the jobs its apply carried (`FollowScan.carried`) that no older pass found
    /// meanwhile; a carried job an older pass finds is placed at that find, as the older pass placed it on a visit-first
    /// engine.
    private func continueFollowScans() {
        var compared = 0
        var formatted = 0
        let copy = self.state.applied
        while !self.state.followScans.isEmpty, compared < Self.followScansPerTurn, formatted < Self.followFormatsPerTurn {
            var scan = self.state.followScans.removeFirst()
            if scan.next == 0, !scan.carried.isEmpty {
                for transfer in scan.carried where self.state.followCarried.remove(transfer) != nil {
                    if self.state.jobs[transfer] != nil, self.state.unfollowed.contains(transfer) {
                        self.state.followOrder.append(transfer)
                        self.state.followStamps[transfer] = scan.stamp
                    }
                }
                scan.carried = []
            }
            let entries = scan.manifest.entries
            while scan.next < entries.count, compared < Self.followScansPerTurn, formatted < Self.followFormatsPerTurn {
                let entry = entries[scan.next]
                scan.next += 1
                compared += 1
                if let listed = copy.entry(for: entry.identifier), SyncEngine.sameTransfer(entry, listed) {
                    continue
                }
                formatted += 1
                let transfer = entry.transferID
                guard self.state.jobs[transfer] != nil else {
                    continue
                }
                if self.state.unfollowed.insert(transfer).inserted || self.state.followCarried.remove(transfer) != nil {
                    self.state.followOrder.append(transfer)
                    self.state.followStamps[transfer] = scan.stamp
                }
            }
            if scan.next < entries.count {
                self.state.followScans.insert(scan, at: 0)
            }
        }
    }

    /// The ids of the owed passes' entries not compared yet, with the transfers those entries name: a job that holds one
    /// of them for that transfer follows a copy whose pass is owed (`invariantViolations()`).
    func unscannedFollowEntries() -> [AssetID: Set<TransferID>] {
        var unscanned: [AssetID: Set<TransferID>] = [:]
        for scan in self.state.followScans {
            for entry in scan.manifest.entries[scan.next...] {
                unscanned[entry.identifier, default: []].insert(entry.transferID)
            }
        }
        return unscanned
    }

    /// `follow(_:ids:afterVerdict:)` with the joins it makes marked as the follow's own (`EngineState.inFollowVisit`),
    /// under the decision instant `stamp` of the apply it belongs to (`withReading`; S3-R15 item 1, the cycle-11 residual
    /// R-D), within the ids `budget` leaves; returns whether it moved.
    private func visit(_ transfer: TransferID, at stamp: WorldStamp, budget: inout FollowBudget) -> Bool {
        self.state.inFollowVisit = true
        defer {
            self.state.inFollowVisit = false
        }
        let ids = budget.ids
        let made = self.withReading(stamp) {
            self.follow(transfer, ids: ids, afterVerdict: false)
        }
        budget.ids -= made.spent
        return made.moved
    }

    /// Continues the rest of a visit too large for one turn (`EngineState.followMoving`) within `budget`, as the visit
    /// moved: under its decision instant, its joins the follow's own (`inFollowVisit`), and those of the drain's visit
    /// after a verdict made at once, as the drain made them, never behind a verdict that waits (`addInterest`). At its
    /// last id the visit ends: a passed job's re-route set is spent (`follow`), and the job's publication, which waited
    /// for it, binds (`inboundBlocks`). Returns whether an id moved.
    private func continueVisitRemainder(_ budget: inout FollowBudget) -> Bool {
        guard var rest = self.state.followMoving, budget.ids > 0 else {
            return false
        }
        self.state.inFollowVisit = true
        self.state.bringingInbound = rest.afterVerdict
        defer {
            self.state.inFollowVisit = false
            self.state.bringingInbound = false
        }
        let ids = budget.ids
        let made = self.withReading(rest.stamp) {
            self.continueMove(&rest.moves, of: rest.holder, listing: nil, budget: ids)
        }
        budget.ids -= made.spent
        guard rest.moves.isDone else {
            self.state.followMoving = rest
            return made.moved
        }
        self.state.followMoving = nil
        if rest.spends {
            self.state.jobs[rest.holder]?.rerouteOnPass = []
        }
        if !self.inboundBlocks(rest.holder) {
            self.state.inboundWaits.removeValue(forKey: rest.holder)?.resume()
        }
        return made.moved
    }

    /// What a follow's visit re-routes of `job`'s moved ids when it passes the job instead of moving it; `nil` when it
    /// moves every moved id. The visit passes the job as a visit-first engine's visit at the apply met it:
    /// - publishing: passed, its publication's set re-routed (`Job.rerouteOnPass`; ruling S3-R18 item 2);
    /// - failed with its exit verdict waiting: left to the verdict, the ids moved before the verdict arrived re-routed
    ///   (`recordDeferredVerdict`), since a later apply's visit met the job as the verdict left it, which the drain moves
    ///   then (`followAfterVerdict`; Stage 3 close-out cycle 16, ruling S3-R19 item 1, PROBE-C15R-VERDICT-LATER-APPLY);
    /// - failed in its publication's bookkeeping, before the verdict defers: passed as still publishing while no apply was
    ///   followed since the publication's end, else moved, as met failed (`recordPublicationEnd`;
    ///   PROBE-C15C-INTEGRITY-WINDOW);
    /// - otherwise (downloading, queued, parked, failed with its verdict given) moved.
    /// Also read by `followedLane`.
    func rerouteOnVisit(_ job: Job) -> Set<AssetID>? {
        // The set serves only the follow owed when it was recorded (`Job.rerouteFor`).
        let reroute = job.rerouteFor == self.state.followsEnded ? job.rerouteOnPass ?? [] : []
        switch job.state {
        case .verifying, .committing:
            return reroute
        case .failed:
            guard let end = job.attemptEnd else {
                return nil
            }
            if end.deferredAfter == nil, self.state.appliesFollowed != end.failedAfter {
                return nil
            }
            return reroute
        case .queued, .blocked, .downloading:
            return nil
        }
    }

    /// Moves one job to the copy (see `followApplied(from:)`); `true` when it moved. A job the visit passes
    /// (`rerouteOnVisit`: publishing, its exit verdict waiting, or failed in its publication's bookkeeping) keeps its
    /// bytes, its ledger entry and its publication (R-SYN-11): its commit binds only the ids the copy still maps to it, and
    /// the ids it does not bind follow their content then (`committed`). Of its moved ids, the visit re-routes at once
    /// those a visit-first engine had moved before the publication began or the verdict arrived (`Job.rerouteOnPass`):
    /// that engine visited the job at the apply, while it still downloaded (Stage 3 close-out cycle 15, ruling S3-R18
    /// item 2). The others, which an apply moved while the job already published or after its verdict, are passed, as that
    /// engine passed them or met the job as its verdict left it (S3-R18a item 1, S3-R19 item 1): they are answered with
    /// the publication's outcome or the verdict, and the job stays in `unfollowed` for the next follow. The visit spends
    /// the re-routed set, found moved or not: it is the visit a visit-first engine made at that apply, and a later apply's
    /// visit of the same publication passes what it meets (cycle 16, PROBE-C15R-REROUTE-STALE); a set whose follow ended
    /// without the visit is spent too (`Job.rerouteFor`, PROBE-C15C-STALE-REROUTE); of a job whose exit verdict waits,
    /// the drain takes the set's ids still on it off before the verdict all the same (`AttemptEnd.movedBefore`; cycle
    /// 17). A job that is not publishing and whose every id moves is superseded, as that engine's visit superseded it
    /// (`move`). The cycle-14 mark that
    /// deferred the move to the publication's failure moved, at a later apply, ids that apply had moved during the
    /// publication too (PROBE-C14C-MARK-TWO-APPLIES), and left a moved interest out of every decision that read the job's
    /// lane meanwhile (PROBE-C14R-PASSED-LANE, PROBE-C14R-PASSED-FAIL). The caller checks the run and pumps once per turn,
    /// not once per job.
    ///
    /// A visit moves at most `ids` ids now (`startMove`); one that moves more leaves the rest to the follow's next turns
    /// (`EngineState.followMoving`; Stage 3 close-out cycle 19, ruling S3-R22 item 1), and spends a passed job's set at
    /// its last. `afterVerdict`: the drain's visit (`followAfterVerdict`). Returns whether it moved, and the ids spent.
    private func follow(_ transfer: TransferID, ids budget: Int, afterVerdict: Bool) -> (moved: Bool, spent: Int) {
        guard let job = self.state.jobs[transfer] else {
            return (false, 0)
        }
        let reroute = self.rerouteOnVisit(job)
        var moved = job.assets.filter { asset in self.state.applied.entry(for: asset).map { !SyncEngine.sameTransfer($0, job.entry) } ?? true }
        if let reroute {
            let passed = moved.subtracting(reroute)
            if !passed.isEmpty {
                self.state.unfollowed.insert(transfer)
            }
            moved.subtract(passed)
        }
        let made = moved.isEmpty ? (moved: false, spent: 0, rest: nil) : self.startMove(moved, of: job, listing: nil, budget: budget)
        if let rest = made.rest {
            let stamp = self.state.reading ?? self.worldStamp()
            self.state.followMoving = VisitRemainder(holder: transfer, moves: rest, stamp: stamp, afterVerdict: afterVerdict, spends: reroute != nil)
        } else if reroute != nil {
            self.state.jobs[transfer]?.rerouteOnPass = []
        }
        return (made.moved, made.spent)
    }

    /// Moves `moved`, ids of `job` the engine's copy maps elsewhere, as a visit moves them (`follow`, `continueInbound`):
    /// a job that is not publishing and whose every id moves is superseded (a running attempt abandoned), as a
    /// visit-first engine's visit superseded it; otherwise each interest in a moved id is re-routed to the id's new
    /// content (`reroute`), and an interest left with no id is removed. `listing` is the copy the move is made under, the
    /// engine's copy when `nil` (an owed move found under the copy an apply has since replaced, `InboundMove.copy`).
    /// `true` when it moved an id.
    func move(_ moved: Set<AssetID>, of job: Job, listing: ValidatedManifest? = nil) -> Bool {
        let transfer = job.transfer
        if moved.count == job.assets.count, job.state != .verifying, job.state != .committing {
            if job.state == .downloading {
                if let active = job.active {
                    self.abandon(transfer, active)
                }
                // The transfer ends without a verdict: a half-open probe returns to `halfOpen(probe: nil)` (§7.7).
                self.recordBreaker(.abandoned(transfer))
            }
            self.supersede(transfer, settling: false, listing: listing)
            return true
        }
        self.state.jobs[transfer]?.assets.subtract(moved)
        for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) {
            for asset in interest.assets.sorted() where moved.contains(asset) {
                _ = self.state.jobs[transfer]?.removeAsset(asset, for: token)
                self.reroute(token, interest: interest, asset: asset, from: transfer, listing: listing)
            }
            if self.state.jobs[transfer]?.interests[token]?.assets.isEmpty == true {
                self.removeInterest(token, from: transfer)
            }
        }
        return !moved.isEmpty
    }

    /// Waits `join` behind the exit verdict that waits for `target` (its `.attemptFailed` or `.spaceFailure` at the job's
    /// epoch), under the decision instant now (the visit's), in the verdict's bucket (`EngineState.joinsBehindVerdicts`):
    /// the drain joins it to the job the verdict leaves, or to a new job of the content, as a visit-first engine's visit
    /// at the apply that moved it there joined it once the verdict had been given (`addInterest`; Stage 3 close-out cycle
    /// 17). Its place among the joins already waiting there is an order only (they all join the same content): the drain
    /// places the bucket right behind the verdict, newest first, where an insert right behind the verdict put each (the
    /// skip past them was removed under ruling S3-R16 item 3, its drop-mutant having survived). It costs two writes,
    /// whatever waits there already: the queue insert it replaces, and that insert's search for the verdict, grew with
    /// the joins behind it, and a follow that deferred 10,000 joins held the engine's actor about 37 ms a turn (Stage 3
    /// close-out cycle 21, ruling S3-R26 item 2; `deferBehindVerdictTurns`). Only a follow's visit calls it, outside a
    /// move it brings in, on a job whose verdict waits (`addInterest`'s guard: `AttemptEnd.deferredAfter` is set when the
    /// verdict defers and cleared when it replays), so the bucket always has its verdict (`invariantViolations()`).
    func deferBehindVerdict(_ join: JoinAfterFollow, of target: Job) {
        self.state.joinsAfterFollow[join.token, default: [:]][join.asset] = join.entry.transferID
        self.state.joinsBehindVerdicts[VerdictKey(transfer: target.transfer, epoch: target.epoch), default: []].append(JoinBehindVerdict(join: join, stamp: self.worldStamp()))
    }

    /// Brings onto `transfer`'s job, as its attempt ends while a follow is owed (its publication begins, `publish`, or
    /// its exit verdict defers, `defersFailure`, `spaceFailed`), the interests a visit-first engine's visits had already
    /// moved onto it: those in ids the engine's copy maps to its content that another job holds and whose owed visit
    /// would move them (`rerouteOnVisit`; Stage 3 close-out cycle 17, the cycle-16 verifiers' PROBE-C16C-INTERMEDIATE-HOP
    /// and PROBE-C16C-INTERMEDIATE-HOP-SERVED). The attempt's end is the last instant they are the job's own: its
    /// publication binds the ids it holds when it begins, and its verdict answers or keeps the interests it holds when it
    /// defers. Visited later, such an interest met a later apply's copy: when that apply moved its id on to a third
    /// content, the visit moved it there, and it skipped the outcome a visit-first engine gave it on this job. Only the
    /// ids the copy maps to this content move; each holder's visit moves the rest itself (a holder whose every id moves
    /// is superseded, as its visit would supersede it). When this job's own owed visit came before the holder's in follow
    /// order and moved every id the job held, a visit-first engine had superseded the job, and its visit gave the
    /// interest a fresh job of this content instead: the answers agree while the origin answers both requests for the
    /// content alike, and the requests differ by one (the cycle-17 verifiers' PROBE-C17C-INBOUND-SUPERSEDED; the WP-F
    /// draft's RR-16).
    ///
    /// The walk that finds them is one pass over the jobs' ids with one lookup in the copy each and no transfer formatted,
    /// and records one move per holder (C2; `BenchSync.inboundWalkTurns`, `BenchSync.concentrationNotFoundTurns`). The
    /// moves cost what the visits they stand for cost, so they are owed as the visits are (`EngineState.inboundMoves`),
    /// made `followsPerTurn` holders a turn before any visit, the first `inboundMovesNow` here (`continueInbound`): when
    /// thousands of ids converge on one content, the attempt-end turn made them all and held the actor about 400 ms at
    /// 10,000 (the cycle-17 verifiers' VERIFY-C17R-CONC-404; ruling S3-R20, cycle 18). While a move is owed, the follow
    /// is owed (`followOwed`), so every later event waits, as it waits for any owed visit, and a publication binds its
    /// ids only once no move onto or off its job is owed (`inboundBlocks`).
    func bringInbound(_ transfer: TransferID) {
        guard self.followOwed, let target = self.state.jobs[transfer].map({ InboundTarget(transfer: transfer, epoch: $0.epoch, entry: $0.entry) }) else {
            return
        }
        self.findInbound(onto: [target])
        self.makeInboundNow()
    }

    /// Brings onto each job whose publication runs, as an apply replaces the copy while a follow is owed, the interests a
    /// visit-first engine's visits had moved onto it under the outgoing copy (`bringInbound`'s rule, under the copy the
    /// apply replaces; the caller calls it before the copy changes): that engine's visit at the apply that mapped an id to
    /// the publishing content joined its interest to the publication, and the next apply's visit passed the job
    /// publishing, so the publication's outcome answered it. Visited after the next apply, the interest met that apply's
    /// copy and moved on with it (Stage 3 close-out cycle 18; the cycle-17 verifiers' PROBE-C17R-RR14-PUBLICATION-HOP and
    /// PROBE-C17C-RR14-PUBLICATION-HOP, the WP-F draft's RR-14). The jobs in flight are few (the transfer slots and the
    /// publications); the walk is `bringInbound`'s, once for all of them, only while a follow is owed and a publication
    /// runs, and it makes no move itself: the follow's turns make them. An apply whose turn walks leaves the follow's
    /// first turn to the follow-up turn the walk schedules (`EngineState.applyWalked`): with the walk, the apply's turn
    /// that also continued the owed passes and made 256 moves held the actor 9.4 to 9.6 ms at SPEC §6's 10,000
    /// (`BenchSync.publicationApplyTurns`, C2).
    func bringInboundOntoPublications() {
        guard self.followOwed else {
            return
        }
        var targets: [InboundTarget] = []
        for transfer in self.state.inFlight.sorted() {
            guard let job = self.state.jobs[transfer], job.state == .verifying || job.state == .committing else {
                continue
            }
            targets.append(InboundTarget(transfer: transfer, epoch: job.epoch, entry: job.entry))
        }
        guard !targets.isEmpty else {
            return
        }
        self.findInbound(onto: targets)
        self.state.applyWalked = true
        self.scheduleFollowFollowUp()
    }

    /// The walk of `bringInbound`: records, holder by holder, the ids each other job holds that the copy maps to one of
    /// `targets`' contents and that its owed visit would move (`rerouteOnVisit`), unless a move already owes them. The
    /// holders are taken in the order of their jobs' epochs (`Job.epoch`, the job's creation or its last attempt's start,
    /// which takes a new one), then of their targets' epochs: every id they give joins one job, so their order is an
    /// order only (the follow's order, which the cycle-17 fix first kept, was removed under ruling S3-R16 item 3, its
    /// drop-mutant having survived), and an epoch sorts without formatting a transfer. A target is named by its index
    /// while the walk runs, and each target's count of owed moves is written once, so a holder costs one set of its ids
    /// per target it gives to and one record each (C2: at 10,000 holders, a dictionary per holder and a count per holder
    /// and per id held the attempt-end turn about 15 ms).
    private func findInbound(onto targets: [InboundTarget]) {
        let copy = self.state.applied
        let pending = self.inboundPendingIDs()
        // A content is found by its checksum, or, with none, by its entry's id and path (`sameTransfer`).
        var byChecksum: [ContentHash: Int] = [:]
        var byIdentifier: [AssetID: Int] = [:]
        for (index, target) in targets.enumerated() {
            if let checksum = target.entry.checksum {
                byChecksum[checksum] = index
            } else {
                byIdentifier[target.entry.identifier] = index
            }
        }
        let found = self.foundInbound(targets, copy: copy, pending: pending, byChecksum: byChecksum, byIdentifier: byIdentifier)
        guard !found.isEmpty else {
            return
        }
        // Sorted by keys of plain integers, so the sort moves no id set and formats nothing (C2).
        var keys = found.indices.map { (order: found[$0].order, epoch: targets[found[$0].target].epoch, index: $0) }
        keys.sort { ($0.order, $0.epoch, $0.index) < ($1.order, $1.epoch, $1.index) }
        var onto = [Int](repeating: 0, count: targets.count)
        self.state.inboundMoves.reserveCapacity(self.state.inboundMoves.count + found.count)
        for key in keys {
            let item = found[key.index]
            let target = targets[item.target]
            self.state.inboundMoves.append(InboundMove(target: target.transfer, epoch: target.epoch, holder: item.holder, ids: item.ids, copy: copy))
            onto[item.target] += 1
        }
        for (index, count) in onto.enumerated() where count > 0 {
            self.state.inboundOnto[targets[index].transfer, default: 0] += count
        }
    }

    /// The walk itself (`findInbound`): for each job, the ids its owed visit would move that `copy` maps to one of
    /// `targets`' contents, by target, in the jobs' order of iteration.
    private func foundInbound(
        _ targets: [InboundTarget],
        copy: ValidatedManifest,
        pending: [AssetID: Int],
        byChecksum: [ContentHash: Int],
        byIdentifier: [AssetID: Int]
    ) -> [(order: UInt64, target: Int, holder: TransferID, ids: Set<AssetID>)] {
        var found: [(order: UInt64, target: Int, holder: TransferID, ids: Set<AssetID>)] = []
        for (holder, job) in self.state.jobs {
            let visit = self.rerouteOnVisit(job)
            // The ids for the first target found, and for any other (a holder rarely gives to two publications).
            var first: (target: Int, ids: Set<AssetID>)?
            var others: [(target: Int, ids: Set<AssetID>)] = []
            for asset in job.assets where visit?.contains(asset) ?? true {
                guard pending.isEmpty || pending[asset] == nil, let listed = copy.entry(for: asset) else {
                    continue
                }
                let index: Int?
                if let checksum = listed.checksum {
                    index = byChecksum[checksum]
                } else {
                    index = byIdentifier[asset].flatMap { SyncEngine.sameTransfer(listed, targets[$0].entry) ? $0 : nil }
                }
                guard let index, targets[index].transfer != holder else {
                    continue
                }
                if first == nil {
                    first = (index, [asset])
                } else if first?.target == index {
                    first?.ids.insert(asset)
                } else if let slot = others.firstIndex(where: { $0.target == index }) {
                    others[slot].ids.insert(asset)
                } else {
                    others.append((index, [asset]))
                }
            }
            if let first {
                found.append((job.epoch, first.target, holder, first.ids))
            }
            for other in others {
                found.append((job.epoch, other.target, holder, other.ids))
            }
        }
        return found
    }

    /// The ids of the owed moves, with the index of the move that carries each (`EngineState.inboundMoves`; of a move
    /// begun, the ids it has left, `InboundMove.progress`): a walk records none of them again (`findInbound`), and the
    /// lane a 429 is decided on counts each as an interest on the move's job would count (`followedLane`). Read from the
    /// owed moves when asked, one pass over them, so the walk that records thousands writes no entry per id (C2).
    func inboundPendingIDs() -> [AssetID: Int] {
        guard self.inboundOwed else {
            return [:]
        }
        var pending: [AssetID: Int] = [:]
        for index in self.state.inboundNext..<self.state.inboundMoves.count {
            if let progress = self.state.inboundMoves[index].progress {
                for item in progress.heap {
                    pending[item.asset] = index
                }
            } else {
                for asset in self.state.inboundMoves[index].ids {
                    pending[asset] = index
                }
            }
        }
        return pending
    }

    /// Whether a move onto or off `transfer`'s job is owed, or the rest of its visit (`EngineState.followMoving`): its
    /// publication binds the ids it holds once none is (`publish`), those a visit-first engine's visits had moved onto it
    /// included, and none they had moved off it. The moves off it are looked for among the owed moves, one pass, only
    /// while one is owed and a publication asks.
    func inboundBlocks(_ transfer: TransferID) -> Bool {
        if self.state.followMoving?.holder == transfer {
            return true
        }
        guard self.inboundOwed else {
            return false
        }
        return self.state.inboundOnto[transfer] != nil || self.state.inboundMoves[self.state.inboundNext...].contains { $0.holder == transfer }
    }

    /// The moves `bringInbound` makes in the attempt's end or the apply's turn; the follow's turns make the rest,
    /// `followsPerTurn` a turn (`continueFollow`). A few, so a convergence of a few ids is made at once, as the cycle-17
    /// walk made it, and the turn that also walks every job stays within C2 (`BenchSync.concentrationNotFoundTurns`).
    static let inboundMovesNow = 64

    /// Makes the first moves now, in the attempt's end or the apply's turn, and leaves the rest to the follow's turns: at
    /// most `inboundMovesNow` holders and `inboundIDsNow` ids.
    private func makeInboundNow() {
        guard self.inboundOwed else {
            return
        }
        var budget = FollowBudget(holders: Self.inboundMovesNow, ids: self.inboundIDsNow)
        _ = self.continueInbound(&budget)
        if self.inboundOwed {
            self.scheduleFollowFollowUp()
        }
    }

    /// Makes the owed moves (`EngineState.inboundMoves`), oldest first, within `budget`'s holders and ids; returns whether
    /// an id moved. A move that carries more ids than are left stays owed, its moves left in `InboundMove.progress`, and
    /// ends the turn's moves (`startMove`; Stage 3 close-out cycle 19, ruling S3-R22 item 1: one holder of 10,000 ids made
    /// the attempt-end turn re-route all of them); its holder counts once, at its first turn, and its target is re-read
    /// at every turn. Each move re-routes under the copy that found it (`InboundMove.copy`), as the visit
    /// it stands for re-routed under the copy of its instant, and its joins are made at once
    /// (`EngineState.bringingInbound`). A move found under a copy an apply has replaced since is made as any other: its
    /// job is at its attempt's end, so the newer copy's visit of it leaves it to its verdict or passes its publication
    /// (`rerouteOnVisit`), and a join that names an entry the newer copy does not list marks it for the next follow
    /// (`noteJoin`). A move whose job the epoch no longer names, or whose job is
    /// past its attempt's end (neither publishing nor failed with its end recorded, `Job.attemptEnd`), is dropped: the
    /// holder's own visit moves the ids under the copy as it stands, as a visit-first engine's interests on that job
    /// followed the copy when the job ended (a superseded publication re-routes its interests, a commit's unbound ids
    /// follow their content). No visit is made, so the moves read no decision instant: a join onto a job at its
    /// attempt's end reads none (the cycle-17 `withReading` of the holder's visit instant was removed under ruling
    /// S3-R16 item 3, its drop-mutant having survived).
    private func continueInbound(_ budget: inout FollowBudget) -> Bool {
        guard self.inboundOwed else {
            return false
        }
        var moved = false
        self.state.inFollowVisit = true
        self.state.bringingInbound = true
        defer {
            self.state.inFollowVisit = false
            self.state.bringingInbound = false
        }
        while budget.holders > 0, budget.ids > 0, self.state.inboundNext < self.state.inboundMoves.count {
            let move = self.state.inboundMoves[self.state.inboundNext]
            if move.progress == nil {
                budget.holders -= 1
            }
            var rest: MoveProgress?
            if self.waitingTarget(move) != nil, let holder = self.state.jobs[move.holder] {
                let made: (moved: Bool, spent: Int)
                if var progress = move.progress {
                    made = self.continueMove(&progress, of: move.holder, listing: move.copy, budget: budget.ids)
                    rest = progress.isDone ? nil : progress
                } else {
                    let ids = holder.assets.intersection(move.ids)
                    let started = ids.isEmpty ? (moved: false, spent: 0, rest: nil) : self.startMove(ids, of: holder, listing: move.copy, budget: budget.ids)
                    made = (started.moved, started.spent)
                    rest = started.rest
                }
                budget.ids -= made.spent
                moved = moved || made.moved
            }
            if let rest {
                self.state.inboundMoves[self.state.inboundNext].progress = rest
                break
            }
            self.state.inboundNext += 1
            self.inboundMade(move)
        }
        if !self.inboundOwed {
            self.state.inboundMoves = []
            self.state.inboundNext = 0
        }
        return moved
    }

    /// `move`'s job while it is still at the attempt's end the move was found for: the same epoch, publishing, or failed
    /// with its end recorded (its verdict waiting, or its publication's failure being booked, `recordPublicationEnd`);
    /// `nil` once it left it, which drops the move (`continueInbound`). Also read by `followedLane`.
    func waitingTarget(_ move: InboundMove) -> Job? {
        guard let job = self.state.jobs[move.target], job.epoch == move.epoch else {
            return nil
        }
        switch job.state {
        case .verifying, .committing:
            return job
        case .failed:
            return job.attemptEnd != nil ? job : nil
        case .queued, .blocked, .downloading:
            return nil
        }
    }

    /// Forgets a made or dropped move (already past `inboundNext`): one move fewer is owed onto its job, and a publication
    /// of either job that waited for its last owed move binds now (`awaitInboundMoves`).
    private func inboundMade(_ move: InboundMove) {
        let left = (self.state.inboundOnto[move.target] ?? 1) - 1
        self.state.inboundOnto[move.target] = left > 0 ? left : nil
        guard !self.state.inboundWaits.isEmpty else {
            return
        }
        for transfer in [move.target, move.holder] where self.state.inboundWaits[transfer] != nil && !self.inboundBlocks(transfer) {
            self.state.inboundWaits.removeValue(forKey: transfer)?.resume()
        }
    }

    /// Waits until no move is owed onto or off `transfer`'s job and no rest of its visit (`inboundBlocks`): its
    /// publication binds the ids it holds then. The caller found one owed in this turn (`publish`), so the wait registers
    /// at once; the last move or the visit's rest resumes it (`inboundMade`, `continueVisitRemainder`), and shutdown
    /// resumes every one (`releaseInboundWaits`), which also drops what was owed, so no wait registers after it. The
    /// cycle-18 early return and the re-check inside the continuation, which no path reached (the caller's check runs in
    /// the same turn), were removed under ruling S3-R19 item 3 (cycle 19).
    func awaitInboundMoves(_ transfer: TransferID) async {
        // REENTRANCY: RE-S48 (proposed) — nothing here: the body registers synchronously; the caller re-reads the
        // lifecycle after it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.state.inboundWaits[transfer] = continuation
            // A mutation: the test seams' conditions re-evaluate after it, as after any other (`awaitCondition`, L4-R17);
            // a publication whose attempt's end owed no move found nothing else to notify them.
            self.notifyObservers()
        }
    }

    /// Drops every owed move and the rest of a visit (`EngineState.followMoving`), and resumes every publication that
    /// waited for one (shutdown): nothing follows any more.
    func releaseInboundWaits() {
        self.state.followMoving = nil
        self.state.inboundMoves = []
        self.state.inboundNext = 0
        self.state.inboundOnto = [:]
        let waits = self.state.inboundWaits
        self.state.inboundWaits = [:]
        for transfer in waits.keys.sorted() {
            waits[transfer]?.resume()
        }
    }

    /// One follow turn run by a space sweep that found the follow barrier up (F-28, `sweepSpaceParked`): the follow takes
    /// priority over the sweep's verdicts, and the sweep's own follow-up turns keep the follow moving whether or not the
    /// follow's own follow-up has run (it finds nothing owed, or continues). Bounded as any follow turn (C2). The deadlines
    /// are re-read; the idle state too when this turn ended the follow, since the follow's own follow-up then finds
    /// nothing owed and returns before it would (`followFollowUp`).
    func advanceFollowForSpaceSweep() {
        guard self.followOwed else {
            self.drainEventsAfterFollow()
            return
        }
        self.continueFollow()
        if self.followOwed {
            self.rearm()
            self.notifyObservers()
        } else {
            self.reconcileIdle()
        }
    }

    /// Schedules one later turn for the visits a follow turn left after `followsPerTurn`. Only a running engine follows,
    /// so the task is always spawned (`spawn` refuses one only while shutting down or degraded): a follow starts only
    /// while the engine runs (an apply's end, a catch-up and an admission re-read the lifecycle before they follow), the
    /// engine degrades only while starting, before any apply, and shutdown's first turn drops the owed follow with the
    /// job table (`drainEverything`), after which a scheduled follow-up returns at once (`followFollowUp`). The branch
    /// that ended the follow when no task could be spawned, which no path reached, was removed under ruling S3-R25
    /// item 7 (Stage 3 close-out cycle 20); `followBarrierViolations` checks the assumption.
    private func scheduleFollowFollowUp() {
        guard !self.state.followFollowUpScheduled else {
            return
        }
        self.state.followFollowUpScheduled = true
        self.spawn(.entry) { engine in
            // REENTRANCY: RE-S44 (proposed) — the follow-up hops onto the actor and re-reads everything it uses: the
            // owed passes and the visit cursor (a newer apply's follow may have extended or restarted them), the copy as
            // it stands then (each pass compares with it), whether each job is still owed a visit (in `unfollowed`, which
            // `removeJob` leaves) and still exists, and its state and ids, so a job that moved, started, ended or was
            // re-joined meanwhile is followed as it is now.
            await engine.followFollowUp()
        }
    }

    /// The scheduled continuation of `continueFollow`; it continues in any state but shutdown, as a release does.
    private func followFollowUp() {
        if self.state.followFollowUpsHeld {
            // Test seam: the visits stay owed and the turn stays scheduled until the release runs it.
            self.state.followFollowUpWaiting = true
            self.notifyObservers()
            return
        }
        self.state.followFollowUpScheduled = false
        guard !self.isShuttingDown, self.followOwed else {
            return
        }
        self.continueFollow()
        self.rearm()
        self.reconcileIdle()
        self.notifyObservers()
    }

    /// Test seam: the next follow-up turns keep their visits owed until `releaseFollowFollowUps()`, so a test reads the
    /// engine between two follow turns, which no production path can order.
    func holdFollowFollowUps() {
        self.state.followFollowUpsHeld = true
    }

    /// Test seam: lets a held follow-up run in this turn, or disarms a hold nothing reached.
    func releaseFollowFollowUps() {
        self.state.followFollowUpsHeld = false
        guard self.state.followFollowUpWaiting else {
            return
        }
        self.state.followFollowUpWaiting = false
        self.followFollowUp()
    }

    /// Test seam: the drain's next follow-up turns keep their events waiting until `releaseDrainFollowUps()`, so a test
    /// meets the engine between two drain turns (no follow owed, the barrier up), which no production path can order
    /// (Stage 3 close-out cycle 16, PROBE-C15R-LANE-WALK).
    func holdDrainFollowUps() {
        self.state.drainFollowUpsHeld = true
    }

    /// Test seam: lets a held drain follow-up run in this turn, or disarms a hold nothing reached.
    func releaseDrainFollowUps() {
        self.state.drainFollowUpsHeld = false
        guard self.state.drainFollowUpWaiting else {
            return
        }
        self.state.drainFollowUpWaiting = false
        self.drainFollowUp()
    }
}

/// An event that waits for the follow's end (`EngineState.eventsAfterFollow`; F-28, S3-R11 design D3, S3-R14). Real-world
/// ledger inputs (a free-space read, the bytes an ended transfer frees) apply when they arrive (S3-R11 R1): none waits;
/// the other real-world facts an input carries (the path, the clock, a `Retry-After`) are captured at its arrival.
enum EventAfterFollow: Sendable {
    /// An ENOSPC whose verdict (`decideSpaceFailure`) waits; `epoch` is the job's at the failure.
    case spaceFailure(TransferID, epoch: UInt64, required: Int64)
    /// The exit verdict of an attempt that ended behind the barrier (`SyncEngine.defersFailure`); `epoch` is the job's
    /// at the exit.
    case attemptFailed(TransferID, epoch: UInt64, verdict: AttemptVerdict)
    /// A request's join (`addInterest`), other than the follow's own.
    case join(JoinAfterFollow)
    /// A waiter's withdrawal (`withdraw`); `TransferID` is the job that held its interest then. The other withdrawals
    /// (a claim's end, a group's release, a release's follow-up, a purge, a run's end) apply on arrival since Stage 3
    /// close-out cycle 13 (ruling S3-R16 item 3).
    case removal(InterestToken, TransferID)
    /// A conditions element's decisions about jobs (`applyConditionsToJobs`): the pauses of refused running work, the
    /// re-queues a satisfied edge owes and the conditions' re-admissions, read under the element's own conditions (its
    /// decision instant's view); the element itself, its edge serial and the pending run's reading applied when it
    /// arrived.
    case conditions(edge: Bool)
    /// A re-admission turn (`readmit`) under the conditions of its arrival.
    case readmit(Readmissions)
    /// The re-admission of the jobs an origin gate parked, once the gate opened (`unblockOrigin`).
    case unblock(OriginBlock)
    /// A failed job's backoff ended (the alarm's `.retry`, `retryDue`).
    case retryDue(TransferID, epoch: UInt64)
    /// A throttle's fail-fast turn for the users of the jobs it parked (`answerThrottledUsers`).
    case throttleAnswers
    /// A space sweep's verdicts (`judgeSpaceSweep`) at the sweep's arrival place (`sweepSpaceParked`; the cycle-12
    /// residual R-C, Stage 3 close-out cycle 13).
    case spaceSweep(SpaceSweep)

    /// Whether the event is itself a bounded pass (a re-admission, a conditions element's pass, a throttle's fail-fast
    /// turn, a space sweep): the drain's batch ends after it (`drainEventsAfterFollow`, C2).
    var endsDrainBatch: Bool {
        switch self {
        case .conditions, .readmit, .unblock, .throttleAnswers, .spaceSweep:
            return true
        case .spaceFailure, .attemptFailed, .join, .removal, .retryDue:
            return false
        }
    }

    /// The attempt whose exit verdict the event gives, if it gives one (`.attemptFailed`, `.spaceFailure`): the joins a
    /// follow's visit waits behind it (`EngineState.joinsBehindVerdicts`) join the drain's batch right behind it, and the
    /// purge and the invariants walk them at its place in the queue.
    var verdictKey: VerdictKey? {
        switch self {
        case .spaceFailure(let transfer, let epoch, _):
            return VerdictKey(transfer: transfer, epoch: epoch)
        case .attemptFailed(let transfer, let epoch, _):
            return VerdictKey(transfer: transfer, epoch: epoch)
        case .join, .removal, .conditions, .readmit, .unblock, .retryDue, .throttleAnswers, .spaceSweep:
            return nil
        }
    }
}

/// An exit verdict that waits for the follow (`EventAfterFollow.attemptFailed`).
enum AttemptVerdict: Sendable, Equatable {
    /// Every interest is answered with the failure (`resolveAll`).
    case resolve(AssetError)
    /// The attempt counts toward the retry caps and the job backs off (`retryLater`), `answer` being the engine's own
    /// figures when it has them, and `wall` the wall clock at the failure's arrival, which a `Retry-After` date is read
    /// against (Stage 3 close-out cycle 18, PROBE-C17C-RETRY-AFTER-DATE).
    case retry(TransferError, answer: AssetError?, wall: Date)
    /// The attempt failed offline: a fresh attempt when `requeue` (an edge passed while it ran and the path is
    /// satisfied), else a wait for the next edge with the offline fail-fast (`failed(.whenOnline)`). Both read when the
    /// failure arrived (R-SYN-13).
    case offline(requeue: Bool)
    /// A 429 (`EngineFailures.throttled`): the park and its fail-fast answers, from the facts of its arrival.
    case throttle(ThrottleFacts)
    /// The attempt paused (`paused`): a policy pause (`policy`) parks on its lane's lane-wide block when the lane the
    /// visits leave has one in `blocks` (the blocks when the pause arrived), any other resumes first in its queue.
    case pause(policy: Bool, blocks: [LaneBlock])
    /// A fresh attempt now, no backoff (`requeue`: a cancel the engine did not ask for, a rejected resume, a background
    /// session that cannot be used).
    case requeue
}

/// A verdict that waits for the follow as `SyncEngine.followedLane` reads it: an attempt's exit verdict
/// (`EventAfterFollow.attemptFailed`) or an ENOSPC's (`EventAfterFollow.spaceFailure`).
enum WaitingVerdict: Sendable, Equatable {
    /// An attempt's exit verdict.
    case attempt(AttemptVerdict)
    /// An ENOSPC's verdict (`SyncEngine.decideSpaceFailure`) for the bytes the attempt needed.
    case space(required: Int64)
}

/// What an ENOSPC's verdict decides on the latest free-space read (`SyncEngine.spaceVerdict`).
enum SpaceVerdict: Sendable, Equatable {
    /// The volume holds what the job needs after all: a retry with backoff (`retryLater`).
    case retry
    /// The store has pending reclaim: the attempt counts toward the caps and the job parks `awaitingSpace`.
    case awaitReclaim
    /// The job parks `insufficientSpace`, and its fail-fast answers its waiters and ensures.
    case insufficient
}

/// A lane's lane-wide block when a pause arrived (`AttemptVerdict.pause`).
struct LaneBlock: Sendable, Equatable {
    /// The lane.
    let lane: AssetPriority
    /// Its block.
    let reason: BlockReason
}

/// What a 429's verdict reads from its arrival (`AttemptVerdict.throttle`).
struct ThrottleFacts: Sendable, Equatable {
    /// The `Retry-After`, in seconds from the 429's instant, if any.
    let retryAfter: TimeInterval?
    /// What the 429 decided when it arrived (S3-R15 item 2).
    let decision: ThrottleDecision
}

/// The throttle a 429 that arrived behind the barrier decided on arrival (`EngineFailures.throttled`). Every 429
/// decides on arrival (R-SYN-5; ruling S3-R16 item 1(b)): the cycle-12 `undecided`, which left the origin unthrottled
/// until the drain when the visits moved every id of the job, is gone (PROBE-C12-UNDECIDED-LANE).
enum ThrottleDecision: Sendable, Equatable {
    /// The origin was throttled until this end for the job's backoff on the lane the owed visits leave it.
    case until(MonotonicInstant)
    /// The `Retry-After` exceeds that lane's `maxRetryAfter` (`Backoff.delay` defers to the next run): the job fails
    /// with the throttle's answer, and the origin is not throttled, as on a visit-first engine.
    case exhausted
}

/// The non-ledger real-world inputs as they stood at one decision instant while the follow barrier held (S3-R15 item
/// 1; `EngineState.worldHistory`): the origin's throttle end and breaker, the lane-wide conditions and the network
/// edge's serial. The ledger inputs (free-space reads, the bytes an ended transfer frees, S3-R11 R1) are not in it:
/// everyone reads them live.
struct WorldView: Sendable, Equatable {
    /// The origin's recorded throttle end.
    var throttle: MonotonicInstant?
    /// The origin's breaker.
    var breaker: CircuitBreaker?
    /// The lane-wide conditions.
    let conditions: ConditionsSnapshot
    /// `EngineState.networkEdgeSerial`.
    let edgeSerial: UInt64
}

/// A decision instant while the follow barrier holds: when, and the view of the world then (an index into
/// `EngineState.worldHistory`).
struct WorldStamp: Sendable, Equatable {
    /// The instant.
    let at: MonotonicInstant
    /// The view's index in `EngineState.worldHistory`.
    let view: Int
}

/// The lane-wide conditions an event read when it arrived (`WorldView.conditions`).
struct ConditionsSnapshot: Sendable, Equatable {
    /// The conditions element in force.
    let conditions: DeviceConditions?
    /// Whether the thermal state paused background work.
    let pausedForThermal: Bool
}

/// What the drain needs of a job whose exit verdict waits (`EngineState.verdictsAfterFollow`).
struct VerdictAfterFollow: Sendable, Equatable {
    /// The job's epoch at the exit.
    let epoch: UInt64
}

/// When a job's latest attempt ended in a failure and when its exit verdict deferred to the follow, in applies followed
/// (`EngineState.appliesFollowed`, `Job.attemptEnd`; Stage 3 close-out cycle 16, ruling S3-R19 item 1, which replaces
/// cycle 15's `VerdictAfterFollow.published` with this comparison). A follow's visit reads it to meet the job as a
/// visit-first engine's visit at its apply met it (`SyncEngine.rerouteOnVisit`): an apply before a publication's end met
/// the job publishing, one between that end and the verdict met it failed with no verdict yet, one after the verdict met
/// the job as the verdict left it.
struct AttemptEnd: Sendable, Equatable {
    /// The applies followed when the attempt's publication ended (`SyncEngine.recordPublicationEnd`), or, for any other
    /// attempt, when its verdict deferred.
    let failedAfter: UInt64
    /// The applies followed when its exit verdict deferred to the follow (`SyncEngine.recordDeferredVerdict`); `nil`
    /// until then.
    let deferredAfter: UInt64?
    /// The ids a visit-first engine's visits had moved off the job before its exit verdict arrived (the set recorded
    /// with the deferral, `Job.rerouteOnPass`), which no visit spends: the verdict is not theirs, so any of them still on
    /// the job when the drain gives it is taken off first and follows its entry after it (`takeOffMovedBefore`; Stage 3
    /// close-out cycle 17).
    var movedBefore: Set<AssetID> = []
}

/// A join that waits for the follow (`EventAfterFollow.join`): what `addInterest` was called with.
struct JoinAfterFollow: Sendable {
    /// The interest.
    let token: InterestToken
    /// The asset it joins for.
    let asset: AssetID
    /// The entry it joins for (`transferID` names the job).
    let entry: ManifestEntry
    /// Its lane.
    let lane: AssetPriority
    /// Its kind.
    let kind: InterestKind
    /// Whether the engine's copy listed `asset` at `entry`'s transfer when it joined (a waiter joined from the store's
    /// newer manifest may name another), so a later apply that moved it is followed at the drain.
    let listed: Bool
    /// Whether a purge withdrew it while it waited (`SyncEngine.withdrawPurgedJoins`): it is no longer in
    /// `EngineState.joinsAfterFollow`, and its replay joins nothing.
    var withdrawn = false
}

/// One attempt's exit verdict (`EventAfterFollow.verdictKey`): its job's transfer, and the job's epoch at the attempt's
/// end. The epoch tells two attempts of one content apart (`EngineState.lastEpoch` grows at every job creation and every
/// start), so the joins that wait behind one attempt's verdict (`EngineState.joinsBehindVerdicts`) never meet another's.
struct VerdictKey: Hashable, Sendable {
    /// The job's transfer.
    let transfer: TransferID
    /// The job's epoch at the attempt's end.
    let epoch: UInt64
}

/// A join a follow's visit waits behind a waiting exit verdict (`SyncEngine.deferBehindVerdict`), with its decision
/// instant: kept beside the queue, so a deferral costs the same whatever waits behind the verdict already, and placed
/// in the drain's batch right behind the verdict (`SyncEngine.drainEventsAfterFollow`). `join` is mutable so that a
/// purge withdraws it in place (`SyncEngine.withdrawPurgedJoins`).
struct JoinBehindVerdict: Sendable {
    /// The join.
    var join: JoinAfterFollow
    /// Its decision instant: the visit's (`SyncEngine.worldStamp()`).
    let stamp: WorldStamp
}
