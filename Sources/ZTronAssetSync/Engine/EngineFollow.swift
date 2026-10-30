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
    /// released (it may be one the follow moves).
    func followApplied(from previous: ValidatedManifest) {
        let owed = self.state.followOrder[self.state.followNext...]
        let owedSet = Set(owed)
        let others = self.state.unfollowed.subtracting(owedSet).subtracting(self.state.followCarried).sorted()
        let changed = previous.digest != self.state.applied.digest || previous.count != self.state.applied.count
        if self.state.followScans.isEmpty {
            self.state.followOrder = Array(owed) + others
            if !self.state.jobs.isEmpty, changed {
                self.state.followScans.append(FollowScan(manifest: previous))
            }
        } else {
            self.state.followOrder = Array(owed)
            self.state.followCarried.formUnion(others)
            // A pass over an unchanged copy compares every entry and finds nothing; it is queued only to carry `others`.
            if changed || !others.isEmpty {
                self.state.followScans.append(FollowScan(manifest: changed ? previous : self.state.applied, carried: others))
            }
        }
        self.state.followNext = 0
        self.continueFollow()
    }

    /// Whether a follow still owes a pass or visits to follow-up turns.
    var followOwed: Bool {
        !self.state.followScans.isEmpty || self.state.followNext < self.state.followOrder.count
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

    /// Continues the follow's owed passes, then visits its next `followsPerTurn` jobs; schedules a follow-up turn for the
    /// rest, or ends the follow: the jobs held for a manifest catch-up that no catch-up holds any more are released, and
    /// the run is checked.
    private func continueFollow() {
        self.continueFollowScans()
        var visited = 0
        var moved = false
        while visited < Self.followsPerTurn, self.state.followNext < self.state.followOrder.count {
            let transfer = self.state.followOrder[self.state.followNext]
            self.state.followNext += 1
            // A job owed a visit stays in `unfollowed` until it; one that left it was removed meanwhile (`removeJob`).
            guard self.state.unfollowed.remove(transfer) != nil else {
                continue
            }
            visited += 1
            if self.visit(transfer) {
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
        if self.state.manifestCatchUps == 0, !self.state.heldForManifest.isEmpty {
            // `manifestCaughtUp` left them held while this follow was owed.
            self.state.heldForManifest.removeAll()
            moved = true
        }
        self.checkRunSettled()
        if moved || self.state.pumpWaitsForFollow {
            self.pump()
        }
        self.drainEventsAfterFollow()
    }

    /// The events one drain turn applies at most (`drainEventsAfterFollow`): an event costs about what a re-queue or a park
    /// costs, so a turn stays near 1 ms (C2) whatever arrived during the follow (a 10,000-member group's joins). An event
    /// that is itself a bounded pass (`EventAfterFollow.endsDrainBatch`: a conditions element's pass, a re-admission, a
    /// release or purge, a throttle's fail-fast turn) ends its batch, so a turn holds at most one of them.
    static let eventsAfterFollowPerTurn = 512

    /// Applies the events that waited for the follow (F-28) as a visit-first engine meets them: after the follow's
    /// own last turn and its pump, in arrival order, on the state every visit left, at most `eventsAfterFollowPerTurn`
    /// per turn; the barrier holds (`followBarrier`) until the last is applied, and no pump runs during a batch or
    /// between two (`pump`: a slot freed between two batches went to work queued before the user work a later batch
    /// queues, the cycle-9 amendment (d)); after the last, the run is checked and the queues pumped. Each event
    /// re-validates what it names (the job, its epoch, the interest): a job that ended or moved meanwhile is skipped. A
    /// sweep owed meanwhile is a follow-up turn already (`sweepSpaceParked`).
    func drainEventsAfterFollow() {
        guard !self.followOwed, !self.state.eventsAfterFollow.isEmpty else {
            return
        }
        var count = 0
        for event in self.state.eventsAfterFollow.prefix(Self.eventsAfterFollowPerTurn) {
            count += 1
            if event.endsDrainBatch {
                break
            }
        }
        let batch = Array(zip(self.state.eventsAfterFollow.prefix(count), self.state.eventsArrivedAt.prefix(count)))
        self.state.eventsAfterFollow.removeFirst(count)
        self.state.eventsArrivedAt.removeFirst(min(count, self.state.eventsArrivedAt.count))
        self.state.drainingAfterFollow = true
        for (event, arrived) in batch {
            self.state.replayInstant = arrived
            self.replay(event)
        }
        self.state.replayInstant = nil
        self.state.drainingAfterFollow = false
        guard self.state.eventsAfterFollow.isEmpty else {
            self.scheduleDrainFollowUp()
            return
        }
        self.state.throttlesReplayed = [:]
        self.checkRunSettled()
        self.pump()
    }

    /// Defers `event` to the follow's end (`eventsAfterFollow`), with the instant it arrived.
    func deferToFollow(_ event: EventAfterFollow) {
        self.state.eventsAfterFollow.append(event)
        self.state.eventsArrivedAt.append(self.environment.time.monotonicNow())
    }

    /// The instant a decision is taken at: the arrival of the event the drain applies (`replayInstant`), or now. A
    /// visit-first engine took the decision when the event arrived, so a place's request time, a backoff's start and a
    /// fail-fast answer's wait count from then.
    func decisionNow() -> MonotonicInstant {
        self.state.replayInstant ?? self.environment.time.monotonicNow()
    }

    /// Applies one event that waited for the follow (`drainEventsAfterFollow`).
    private func replay(_ event: EventAfterFollow) {
        switch event {
        case .spaceFailure(let transfer, let epoch, let required):
            guard self.followedForVerdict(transfer, epoch: epoch) else {
                return
            }
            self.decideSpaceFailure(transfer, required: required)
        case .attemptFailed(let transfer, let epoch, let verdict):
            self.replayVerdict(transfer, epoch: epoch, verdict)
        case .enqueue(let transfer, let epoch, let front):
            self.notePlaceTaken(transfer)
            // A place belongs to the job that asked for it: one removed meanwhile, and re-created by the follow's
            // visit, has its own place (PROBE-C9-STALE-PLACE).
            guard self.state.jobs[transfer]?.epoch == epoch else {
                return
            }
            self.enqueue(transfer, front: front, askedBefore: true)
        case .join(let join):
            self.replayJoin(join)
        case .endClaim(let token, let member):
            self.endClaim(token, member: member)
        case .endClaims(let token):
            self.endClaims(of: token)
        case .removal(let token, let transfer):
            self.replayRemoval(token, from: transfer)
        case .release(let token, let entry):
            if entry {
                self.releaseEntryGroup(token)
            } else {
                self.performReleaseGroup(token)
            }
        case .continueReleases:
            self.resumeReleases()
        case .purge(let request):
            self.withdrawPurged(request)
        case .conditions(let conditions, let edge):
            self.withConditions(conditions) {
                self.applyConditionsToJobs(edge: edge)
            }
        case .readmit(let passes, let conditions):
            self.withConditions(conditions) {
                self.readmit(passes)
            }
        case .unblock(let kind):
            self.unblockOrigin(kind)
        case .retryDue(let transfer, let epoch):
            self.retryDue(transfer, epoch: epoch)
        case .throttleAnswers:
            self.answerThrottledUsersNow()
        }
    }

    /// Runs `body` with the lane-wide conditions an event captured when it arrived (`ConditionsSnapshot`): the lane
    /// verdicts it reads are those a visit-first engine read at that event, whatever arrived after it. Synchronous: no
    /// other turn sees the swap.
    private func withConditions(_ snapshot: ConditionsSnapshot, _ body: () -> Void) {
        let conditions = self.state.conditions
        let thermal = self.state.pausedForThermal
        self.state.conditions = snapshot.conditions
        self.state.pausedForThermal = snapshot.pausedForThermal
        body()
        self.state.conditions = conditions
        self.state.pausedForThermal = thermal
    }

    /// The lane-wide conditions now (`withConditions`).
    var conditionsSnapshot: ConditionsSnapshot {
        ConditionsSnapshot(conditions: self.state.conditions, pausedForThermal: self.state.pausedForThermal)
    }

    /// Schedules one later turn for the events a drain turn left (C2).
    private func scheduleDrainFollowUp() {
        guard !self.state.drainFollowUpScheduled else {
            return
        }
        self.state.drainFollowUpScheduled = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S45 (proposed) — the drain's follow-up hops onto the actor and re-reads the waiting events
            // and each job, epoch and interest they name (`drainEventsAfterFollow` re-validates every one); a follow
            // begun meanwhile holds them again until its own end drains them.
            await engine.drainFollowUp()
        }
        if spawned == nil {
            // Shutting down: nothing is admitted any more.
            self.state.drainFollowUpScheduled = false
            self.state.eventsAfterFollow = []
            self.state.eventsArrivedAt = []
            self.state.placesAfterFollow = [:]
            self.state.verdictsAfterFollow = [:]
            self.state.joinsAfterFollow = [:]
            self.state.throttlesReplayed = [:]
        }
    }

    /// The scheduled continuation of `drainEventsAfterFollow`.
    private func drainFollowUp() {
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
        return self.holdsIDListedElsewhere(job)
    }

    /// Whether `job` holds an id the engine's copy lists at another transfer (`holdsMovedID` without its follow).
    private func holdsIDListedElsewhere(_ job: Job) -> Bool {
        job.assets.contains { asset in
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
    func defersFailure(_ transfer: TransferID, _ verdict: AttemptVerdict) -> Bool {
        guard self.defersToFollow, let job = self.state.jobs[transfer] else {
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
        self.deferToFollow(.attemptFailed(transfer, epoch: job.epoch, verdict: verdict))
        self.notifyObservers()
        return true
    }

    /// Gives a deferred exit verdict (`defersFailure`) to the ids its job holds after the follow, unless the job ended
    /// or was superseded meanwhile: the exit the attempt's end would have taken once the follow had visited first, on
    /// the lane, interests and ranks the visits left. The verdict stays recorded while the drain's own visit of the job
    /// runs (`followedForVerdict`), so that visit's re-lane is the follow's, as it would have been while the attempt
    /// still ran (`relane`). Every input that met the job meanwhile waits behind this event, at its own arrival, and
    /// meets the job as the verdict leaves it (PROBE-C9-JOIN-RESOLVE, PROBE-C9-JOIN-RETRY-PLACE, PROBE-C10-JOIN-RETIRE).
    private func replayVerdict(_ transfer: TransferID, epoch: UInt64, _ verdict: AttemptVerdict) {
        guard self.state.verdictsAfterFollow[transfer]?.epoch == epoch else {
            return
        }
        let followed = self.followedForVerdict(transfer, epoch: epoch)
        self.state.verdictsAfterFollow[transfer] = nil
        guard followed, case .failed? = self.state.jobs[transfer]?.state else {
            return
        }
        switch verdict {
        case .resolve(let answer):
            self.resolveAll(transfer, with: .failed(answer))
        case .retry(let error, let answer):
            self.retryLater(transfer, error: error, answer: answer)
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

    /// A 429's park decided after the follow (`EngineFailures.throttled`): the backoff of the lane the visits left
    /// (R-SYN-5, PROBE-C10-THROTTLE-LANE) from the 429's instant, or its `Retry-After` when longer, which already
    /// throttled the origin when it arrived (a real-world input, S3-R14). The origin's throttle keeps the later end. The
    /// park's fail-fast answers read the wait at the 429's instant against the end a visit-first engine had decided
    /// then: the throttle in force when the 429 arrived and the ends the earlier replayed 429s gave, not a later 429's
    /// (PROBE-C10-THROTTLE-EXTENDED; `throttlesReplayed`). The origin's alarm stays at the origin's end (`park`).
    private func replayThrottle(_ transfer: TransferID, _ facts: ThrottleFacts) {
        guard let job = self.state.jobs[transfer], let origin = self.state.remote?.originID else {
            return
        }
        let policy = job.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry
        guard let delay = Backoff.delay(attempt: job.attempts + 1, retryAfter: facts.retryAfter, policy: policy, seed: self.environment.random.seed, key: StableHash.fnv1a64(origin)) else {
            self.transition(transfer, to: .failed(.nextRun))
            self.resolveAll(transfer, with: .failed(.serverUnavailable(retryAfter: facts.retryAfter)))
            return
        }
        let until = facts.at.adding(seconds: max(delay, facts.retryAfter ?? 0))
        let previous = self.state.throttles[origin]
        self.state.throttles[origin] = max(previous ?? .zero, until)
        self.state.metrics.retries[.throttled] += 1
        self.throttleExtended(from: previous)
        let replayed = self.state.throttlesReplayed[origin]
        let end = max(facts.decided ?? .zero, replayed ?? .zero, until)
        self.state.throttlesReplayed[origin] = max(replayed ?? .zero, until)
        if self.transition(transfer, to: .queued) {
            self.park(transfer, reason: .throttled(until: end), answeredAt: facts.at, answerEnd: end)
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

    /// Whether the owner of a waiting join still waits for its asset in the join's transfer.
    private func stillWants(_ join: JoinAfterFollow) -> Bool {
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

    /// Moves the ids a deferred verdict's job still holds for content the copy lists elsewhere before the drain gives
    /// the verdict, and returns whether the job is still `epoch`'s: one the visit superseded has nobody left to answer.
    /// The follow's visits moved them already, unless the follow passed the job while it verified or committed (it is
    /// visited again only by the next follow) or the job was joined for a replaced entry after the follow's pass; the
    /// cycles before brought that visit forward to the failure. The drain's last batch pumps for any job it creates.
    private func followedForVerdict(_ transfer: TransferID, epoch: UInt64) -> Bool {
        guard let job = self.state.jobs[transfer], job.epoch == epoch else {
            return false
        }
        if self.holdsIDListedElsewhere(job) {
            _ = self.visit(transfer)
        }
        return self.state.jobs[transfer]?.epoch == epoch
    }

    /// Records that a place in a queue (`EventAfterFollow.enqueue`) waits for the drain.
    func notePlaceWaits(_ transfer: TransferID) {
        self.state.placesAfterFollow[transfer, default: 0] += 1
    }

    /// Records that the drain gives a waiting place (`notePlaceWaits`).
    private func notePlaceTaken(_ transfer: TransferID) {
        guard let count = self.state.placesAfterFollow[transfer] else {
            return
        }
        self.state.placesAfterFollow[transfer] = count > 1 ? count - 1 : nil
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

    /// `follow(_:)` with the joins it makes marked as the follow's own (`EngineState.inFollowVisit`).
    private func visit(_ transfer: TransferID) -> Bool {
        self.state.inFollowVisit = true
        defer {
            self.state.inFollowVisit = false
        }
        return self.follow(transfer)
    }

    /// Moves one job to the copy (see `followApplied(from:)`); `true` when it moved. A job verifying or committing is
    /// not moved (its commit binds only the ids the copy still maps to it); it stays in `unfollowed` for the next
    /// follow. The caller checks the run and pumps once per turn, not once per job.
    private func follow(_ transfer: TransferID) -> Bool {
        guard let job = self.state.jobs[transfer] else {
            return false
        }
        let moved = job.assets.filter { self.state.applied.entry(for: $0)?.transferID != transfer }
        switch job.state {
        case .verifying, .committing:
            if !moved.isEmpty {
                self.state.unfollowed.insert(transfer)
            }
            return false
        default:
            break
        }
        guard !moved.isEmpty else {
            return false
        }
        if moved.count == job.assets.count {
            if job.state == .downloading {
                if let active = job.active {
                    self.abandon(transfer, active)
                }
                // The transfer ends without a verdict: a half-open probe returns to `halfOpen(probe: nil)` (§7.7).
                self.recordBreaker(.abandoned(transfer))
            }
            self.supersede(transfer, settling: false)
        } else {
            self.state.jobs[transfer]?.assets.subtract(moved)
            for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) {
                for asset in interest.assets.sorted() where moved.contains(asset) {
                    self.state.jobs[transfer]?.interests[token]?.assets.remove(asset)
                    self.reroute(token, interest: interest, asset: asset, from: transfer)
                }
                if self.state.jobs[transfer]?.interests[token]?.assets.isEmpty == true {
                    self.removeInterest(token, from: transfer)
                }
            }
        }
        return true
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

    /// Schedules one later turn for the visits a follow turn left after `followsPerTurn`. When none can be spawned
    /// (shutting down), the follow ends here: the jobs it still owed stay in `unfollowed` for the next follow.
    private func scheduleFollowFollowUp() {
        guard !self.state.followFollowUpScheduled else {
            return
        }
        self.state.followFollowUpScheduled = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S44 (proposed) — the follow-up hops onto the actor and re-reads everything it uses: the
            // owed passes and the visit cursor (a newer apply's follow may have extended or restarted them), the copy as
            // it stands then (each pass compares with it), whether each job is still owed a visit (in `unfollowed`, which
            // `removeJob` leaves) and still exists, and its state and ids, so a job that moved, started, ended or was
            // re-joined meanwhile is followed as it is now.
            await engine.followFollowUp()
        }
        if spawned == nil {
            // The jobs found so far stay in `unfollowed`; the owed passes are dropped: shutting down, nothing follows.
            self.state.followFollowUpScheduled = false
            self.state.followOrder = []
            self.state.followNext = 0
            self.state.followScans = []
            self.state.followCarried = []
            self.state.pumpWaitsForFollow = false
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
    /// A queued job's place in its lane's queue (`enqueue`), taken after the places of the jobs the follow queues, at
    /// the front when `front` (a pause's resume, a gate's wait), with the time the place was asked for; `epoch` is the
    /// job's when it asked, and a later job of the transfer does not take it.
    case enqueue(TransferID, epoch: UInt64, front: Bool)
    /// A request's join (`addInterest`), other than the follow's own.
    case join(JoinAfterFollow)
    /// The end of a prefetch member's pending claim that the group's join reached (`joinMember`), after its join.
    case endClaim(InterestToken, member: AssetID)
    /// The end of every claim a group's join that gave up still held (`endClaims(of:)`).
    case endClaims(InterestToken)
    /// An interest's removal by a withdrawal, a run's end or a release of re-attachments (`removeInterest`), other
    /// than the follow's own and an answer's (`resolve`); `TransferID` is the job that held it then.
    case removal(InterestToken, TransferID)
    /// A group's release (`performReleaseGroup`), or an `ensureAvailable` group's withdrawal when `entry`
    /// (`releaseEntryGroup`); the caller was answered when it arrived.
    case release(InterestToken, entry: Bool)
    /// A release's follow-up turn (`continueReleases`).
    case continueReleases
    /// A purge's withdrawals of non-user interests (`withdrawPurged`).
    case purge(PurgeRequest)
    /// A conditions element's decisions about jobs (`applyConditionsToJobs`): the pauses of refused running work, the
    /// re-queues a satisfied edge owes and the conditions' re-admissions, read under the element's own conditions; the
    /// element itself, its edge serial and the pending run's reading applied when it arrived.
    case conditions(ConditionsSnapshot, edge: Bool)
    /// A re-admission turn (`readmit`) under the conditions of its arrival.
    case readmit(Readmissions, ConditionsSnapshot)
    /// The re-admission of the jobs an origin gate parked, once the gate opened (`unblockOrigin`).
    case unblock(OriginBlock)
    /// A failed job's backoff ended (the alarm's `.retry`, `retryDue`).
    case retryDue(TransferID, epoch: UInt64)
    /// A throttle's fail-fast turn for the users of the jobs it parked (`answerThrottledUsers`).
    case throttleAnswers

    /// Whether the event is itself a bounded pass (a re-admission, a release turn, a purge's pass, a throttle's
    /// fail-fast turn): the drain's batch ends after it (`drainEventsAfterFollow`, C2).
    var endsDrainBatch: Bool {
        switch self {
        case .release, .continueReleases, .purge, .conditions, .readmit, .unblock, .throttleAnswers:
            return true
        case .spaceFailure, .attemptFailed, .enqueue, .join, .endClaim, .endClaims, .removal, .retryDue:
            return false
        }
    }
}

/// An exit verdict that waits for the follow (`EventAfterFollow.attemptFailed`).
enum AttemptVerdict: Sendable, Equatable {
    /// Every interest is answered with the failure (`resolveAll`).
    case resolve(AssetError)
    /// The attempt counts toward the retry caps and the job backs off (`retryLater`), `answer` being the engine's own
    /// figures when it has them.
    case retry(TransferError, answer: AssetError?)
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
    /// The 429's instant.
    let at: MonotonicInstant
    /// The origin's throttle end in force just before the 429 arrived.
    let decided: MonotonicInstant?
}

/// The lane-wide conditions an event read when it arrived (`SyncEngine.withConditions`).
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
}
