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
    /// in that other order (Stage 3 close-out cycle 9, amendment (e) of S3-R11). While a follow is owed no admission is
    /// made and no space verdict given (`followBarrier`, F-28), no run settles (a claim may still move) and no job held
    /// for a manifest catch-up is released (it may be one the follow moves).
    func followApplied(from previous: ValidatedManifest) {
        let owed = self.state.followOrder[self.state.followNext...]
        let owedSet = Set(owed)
        self.state.followOrder = Array(owed) + self.state.unfollowed.subtracting(owedSet).sorted()
        self.state.followNext = 0
        if !self.state.jobs.isEmpty || !self.state.followScans.isEmpty, previous.digest != self.state.applied.digest || previous.count != self.state.applied.count {
            self.state.followScans.append(FollowScan(manifest: previous))
        }
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
    /// costs, so a turn stays near 1 ms (C2) whatever arrived during the follow (a 10,000-member group's joins).
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
        let count = min(Self.eventsAfterFollowPerTurn, self.state.eventsAfterFollow.count)
        let batch = self.state.eventsAfterFollow.prefix(count)
        self.state.eventsAfterFollow.removeFirst(count)
        self.state.drainingAfterFollow = true
        for event in batch {
            switch event {
            case .spaceFailure(let transfer, let epoch, let required):
                guard self.followedForVerdict(transfer, epoch: epoch) else {
                    continue
                }
                self.decideSpaceFailure(transfer, required: required)
            case .attemptFailed(let transfer, let epoch, let verdict):
                self.replayVerdict(transfer, epoch: epoch, verdict)
            case .spaceJoin(let token, let transfer):
                guard self.state.jobs[transfer]?.interests[token] != nil else {
                    continue
                }
                self.failFastJoiner(token, of: transfer)
            case .enqueue(let transfer, let epoch, let front):
                self.notePlaceTaken(transfer)
                // A place belongs to the job that asked for it: one removed meanwhile, and re-created by the follow's
                // visit, has its own place (PROBE-C9-STALE-PLACE).
                guard self.state.jobs[transfer]?.epoch == epoch else {
                    continue
                }
                self.enqueue(transfer, front: front, askedBefore: true)
            case .reinstate(let transfer, let epoch):
                self.notePlaceTaken(transfer)
                guard self.state.jobs[transfer]?.epoch == epoch else {
                    continue
                }
                self.reinstate(transfer)
            case .join(let join):
                self.replayJoin(join)
            case .relane(let transfer, let epoch, let before):
                guard self.state.jobs[transfer]?.epoch == epoch else {
                    continue
                }
                self.relane(transfer, from: before)
            }
        }
        self.state.drainingAfterFollow = false
        guard self.state.eventsAfterFollow.isEmpty else {
            self.scheduleDrainFollowUp()
            return
        }
        self.checkRunSettled()
        self.pump()
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
            self.state.placesAfterFollow = [:]
            self.state.verdictsAfterFollow = [:]
            self.state.joinsAfterVerdict = [:]
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

    /// Whether `job` holds an id the engine's copy lists at another transfer while a follow is owed: a failure of the
    /// job's content is not that id's (F-20: never `.notFound` while the asset is listed; PROBE-W4), so its verdict
    /// waits for the follow (`defersFailure`). An id the copy does
    /// not list is not counted: a waiter joined from the store's newer manifest (`EngineManifest.join`) holds one
    /// legitimately, and the follow would end its interest `.notFound`; a dropped id's interest gets the failure's own
    /// answer instead of the follow's `.notFound`, which no rule forbids. One lookup in the copy and one key comparison
    /// per id of the job (`sameTransfer` against the job's own entry, whose transfer is the job's), no transfer
    /// formatted (a formatted transfer costs about 0.75 µs in release).
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

    /// Defers the failure verdict of a job that holds a moved id while the barrier holds (`defersToFollow`; Stage 3
    /// close-out cycle 9, amendment (c) of S3-R11): the attempt leaves flight now (`failed(.nextRun)`, its bytes no
    /// longer in the ledger, as any ended transfer's, S3-R11 R1) and nobody is answered; the follow's own visit moves the
    /// ids in its order, and the drain gives `verdict` to the ids left (`replayVerdict`). Bringing the visit forward to
    /// the failure (the cycles before) moved that job's ids ahead of earlier owed visits: a moved interest joined its new
    /// content beside the bytes of a download an earlier visit abandons (PROBE-J-FAIL-REROUTE), or a new content's job was
    /// created, and served, before an earlier one (PROBE-J-FAIL-TICKET). Returns `true` when the verdict waits. A job not
    /// in flight or failed is decided now: only an attempt's end is deferred.
    ///
    /// Every exit of the attempt is deferred so, the offline exit's wait for the next edge with its fail-fast answers and
    /// a 429's park with its fail-fast answers too (Stage 3 close-out cycle 10, PROBE-C9-OFFLINE, PROBE-C9-THROTTLE,
    /// PROBE-C9R-THROTTLE-PRESENT): decided before the visit, they answered an interest the visit moves. While the
    /// verdict waits, the job is inert as a visit-first engine's job is after it: a join waits for the drain
    /// (`addInterest`), and so does a re-lane other than the follow's own (`relane`).
    func defersFailure(_ transfer: TransferID, _ verdict: AttemptVerdict) -> Bool {
        guard self.defersToFollow, let job = self.state.jobs[transfer], self.holdsMovedID(job) else {
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
        self.state.eventsAfterFollow.append(.attemptFailed(transfer, epoch: job.epoch, verdict: verdict))
        self.notifyObservers()
        return true
    }

    /// Gives a deferred failure verdict (`defersFailure`) to the ids its job holds after the follow, unless the job ended
    /// or was superseded meanwhile: the exit the attempt's end would have taken once the follow had visited first. The
    /// verdict stays recorded while the drain's own visit of the job runs (`followedForVerdict`), so that visit's re-lane
    /// is the follow's, as it would have been while the attempt still ran (`relane`). A join or a re-lane that met the job
    /// meanwhile waits behind this event, at its own arrival (`EventAfterFollow.join`, `.relane`), and meets the job as the verdict leaves it, as it met a visit-first engine's job after its verdict
    /// (PROBE-C9-JOIN-RESOLVE, PROBE-C9-JOIN-RETRY-PLACE).
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
        case .throttle(let until, let at):
            // The park the 429 gave, its fail-fast answers read at the 429's instant.
            if self.transition(transfer, to: .queued) {
                self.park(transfer, reason: .throttled(until: until), answeredAt: at)
            }
        }
    }

    /// Joins an interest that waited for a deferred verdict (`addInterest`; `EventAfterFollow.join`) at its arrival
    /// place in the drain, after the verdict: to the job the verdict left, or to a new job of the content when the verdict
    /// ended the job, which a visit-first engine's request would have created (PROBE-C9-JOIN-RESOLVE). A request withdrawn
    /// or answered meanwhile (a waiter cancelled, a group released, a run ended) joins nothing. An id a later apply moved
    /// meanwhile is re-routed as that apply's follow would have (`reroute`).
    private func replayJoin(_ join: JoinAfterVerdict) {
        let transfer = join.entry.transferID
        guard self.state.joinsAfterVerdict[join.token]?[join.asset] == transfer else {
            return
        }
        self.state.joinsAfterVerdict[join.token]?[join.asset] = nil
        if self.state.joinsAfterVerdict[join.token]?.isEmpty == true {
            self.state.joinsAfterVerdict[join.token] = nil
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
    private func stillWants(_ join: JoinAfterVerdict) -> Bool {
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

    /// Records that a place in a queue (`EventAfterFollow.enqueue`, `.reinstate`) waits for the drain.
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
    private func continueFollowScans() {
        var compared = 0
        var formatted = 0
        let copy = self.state.applied
        while !self.state.followScans.isEmpty, compared < Self.followScansPerTurn, formatted < Self.followFormatsPerTurn {
            var scan = self.state.followScans.removeFirst()
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
                if self.state.jobs[transfer] != nil, self.state.unfollowed.insert(transfer).inserted {
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

/// An event that waits for the follow's end (`EngineState.eventsAfterFollow`; F-28, S3-R11 design D3). Real-world
/// ledger inputs (a free-space read, the bytes an ended transfer frees) apply when they arrive (S3-R11 R1): none waits.
enum EventAfterFollow: Sendable {
    /// An ENOSPC whose verdict (`decideSpaceFailure`) waits; `epoch` is the job's at the failure.
    case spaceFailure(TransferID, epoch: UInt64, required: Int64)
    /// The failure verdict of a job that held a moved id (`SyncEngine.defersFailure`); `epoch` is the job's at the
    /// failure.
    case attemptFailed(TransferID, epoch: UInt64, verdict: AttemptVerdict)
    /// A join to a job parked `insufficientSpace`, whose re-check and fail-fast answer (`failFastJoiner`) wait.
    case spaceJoin(InterestToken, TransferID)
    /// A queued job's place in its lane's queue (`enqueue`), taken after the places of the jobs the follow queues, at
    /// the front when `front` (a pause's resume, a gate's wait), with the time the place was asked for; `epoch` is the
    /// job's when it asked, and a later job of the transfer does not take it.
    case enqueue(TransferID, epoch: UInt64, front: Bool)
    /// A queued job's return to the place its entry had (`reinstate`); `epoch` as for `enqueue`.
    case reinstate(TransferID, epoch: UInt64)
    /// A join to a job whose failure verdict waits (`addInterest`), made after the verdict's own event.
    case join(JoinAfterVerdict)
    /// A re-lane of a job whose failure verdict waits (`relane`), other than the follow's own; `before` is the job's lane
    /// before the change that asked for it.
    case relane(TransferID, epoch: UInt64, from: AssetPriority)
}

/// A failure verdict that waits for the follow (`EventAfterFollow.attemptFailed`).
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
    /// A 429 parked the job until `until` (the origin's throttle, set when the 429 arrived); the fail-fast answers are
    /// read at `at`, the 429's instant.
    case throttle(until: MonotonicInstant, at: MonotonicInstant)
}

/// What the drain needs of a job whose failure verdict waits (`EngineState.verdictsAfterFollow`).
struct VerdictAfterFollow: Sendable, Equatable {
    /// The job's epoch at the failure.
    let epoch: UInt64
}

/// A join that waits for a deferred failure verdict (`EventAfterFollow.join`): what `addInterest` was called with.
struct JoinAfterVerdict: Sendable {
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
