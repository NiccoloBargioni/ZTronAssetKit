import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// What an interest receives when its job ends for it.
enum InterestOutcome {
    /// The content committed: the bound locations by asset, and the publication's binding in ascending order (the ids
    /// `publish` captured and sorted, of which the store binds a subset), so the terminal events walk the binding in
    /// its order with no sort (Stage 3 close-out cycle 21, step C3).
    case committed([AssetID: AssetLocation], ascending: [AssetID])
    /// The job failed for this interest.
    case failed(AssetError)
}

extension SyncEngine {
    // MARK: Transitions (R-SYN-2)

    /// The only mutator of `Job.state`: an illegal transition is counted (`illegalTransitions`) and logged, never
    /// applied (every engine test asserts the counter is 0; ARCHITECTURE §7.1, sync-2 S2-26).
    @discardableResult
    func transition(_ transfer: TransferID, to next: JobState) -> Bool {
        guard var job = self.state.jobs[transfer] else {
            return false
        }
        guard job.state.allows(next) else {
            self.state.metrics.illegalTransitions += 1
            let from = String(describing: job.state.kind)
            let to = String(describing: next.kind)
            self.log.log(.sync, .fault, "illegal transition \(from) → \(to)")
            return false
        }
        let before = job.ledgerBytes
        let previous = job.state
        job.state = next
        self.reindex(transfer, from: previous, to: next)
        if next.isCircuitParked, !previous.isCircuitParked {
            self.noteCircuitParked(job)
        } else if previous.isCircuitParked, next == .queued {
            self.state.circuitReadmissions += 1
        }
        let after = job.ledgerBytes
        if let before {
            self.state.inFlightBytes.remove(before)
        }
        if let after {
            self.state.inFlightBytes.add(after)
            self.state.inFlight.insert(transfer)
        } else if before != nil {
            self.state.inFlight.remove(transfer)
        }
        if next.kind != .downloading {
            // Only a downloading job has a running attempt (the invariant the model test checks).
            job.active = nil
        }
        self.state.jobs[transfer] = job
        return true
    }

    /// Keeps the indexes of parked and failed jobs (`spaceParked`, `laneParked`, `circuitParked`, `throttleParked`,
    /// `failedJobs`, and the owed re-queues `edgeOwed` and `originOwed`, which a job leaves when it leaves `failed` or
    /// its origin's park) in step with one transition; `invariantViolations()` checks them against the job table.
    private func reindex(_ transfer: TransferID, from previous: JobState, to next: JobState) {
        if next.isSpaceParked {
            self.state.spaceParked.insert(transfer)
        } else if previous.isSpaceParked {
            self.state.spaceParked.remove(transfer)
        }
        if next.isLaneParked {
            self.state.laneParked.insert(transfer)
        } else if previous.isLaneParked {
            self.state.laneParked.remove(transfer)
        }
        if next.isCircuitParked {
            self.state.circuitParked.insert(transfer)
        } else if previous.isCircuitParked {
            self.state.circuitParked.remove(transfer)
            if self.state.circuitParked.isEmpty {
                self.state.circuitOrder.removeAll()
            }
        }
        if next.isThrottleParked {
            self.state.throttleParked.insert(transfer)
        } else if previous.isThrottleParked {
            self.state.throttleParked.remove(transfer)
        }
        if previous.isOriginParked, !next.isOriginParked {
            self.state.originOwed.remove(transfer)
        }
        if next.kind == .failed {
            self.state.failedJobs.insert(transfer)
        } else if previous.kind == .failed {
            self.state.failedJobs.remove(transfer)
            self.state.edgeOwed.remove(transfer)
        }
    }

    // MARK: Interests (H-3, ADR-020)

    /// Whether a visit's join of `asset` (at `entry`'s content) onto a job whose exit verdict waits (`end`) waits behind
    /// that verdict (`deferBehindVerdict`). A follow's visit's always waits: every id the copy mapped to the content when
    /// the verdict deferred, and that an owed visit would move, was brought onto the job then (`bringInbound`), so this
    /// one was moved there by a later apply, whose visit on a visit-first engine met the job as the verdict left it
    /// (Stage 3 close-out cycle 17); a move brought in (`bringingInbound`) joins at once, on the job as the attempt left
    /// it. The drain's visit after an earlier verdict (`followAfterVerdict`) makes the moves of the applies since that
    /// verdict deferred, which the owed visits passed and `bringInbound` does not bring: its join waits unless the copy
    /// this verdict deferred under (`AttemptEnd.copy`) already mapped `asset` to the content, the apply that mapped it
    /// there having come before this verdict, so that engine's visit joined the job in its attempt and the verdict answers
    /// it (Stage 3 close-out cycle 21, ruling S3-R26 item 12's answer 5, candidate 4).
    private func joinWaitsForVerdict(_ asset: AssetID, entry: ManifestEntry, _ end: AttemptEnd) -> Bool {
        if self.state.visitingAfterVerdict {
            return !(end.copy?.entry(for: asset).map { SyncEngine.sameTransfer($0, entry) } ?? false)
        }
        return !self.state.bringingInbound
    }

    /// Adds (or widens) interest `token` in the job of `entry`'s content for `asset`, creating the job (T1) or joining
    /// and promoting it (T15, T20). Promotion is issued synchronously, before any start of this actor turn
    /// (sync-1 S1-06).
    ///
    /// Behind the follow barrier every join other than the follow's own waits (`EventAfterFollow.join`, F-28): a
    /// visit-first engine's join came after the visits, so it met the job a visit created, moved or raised, or the job
    /// a verdict left, or no job at all and created a new one, at the place a visit-first engine gave it. Joined at once,
    /// a request created a job whose place came after the jobs the visits created (the cycle-10 verifiers' request
    /// join), was answered with an earlier attempt's failure, or re-queued a job at the verdict's place (Stage 3
    /// close-out cycle 10, PROBE-C9-JOIN-RESOLVE, PROBE-C9-JOIN-RETRY-PLACE). The follow's own re-routed joins are visits,
    /// made at once; the drain's are the waiting ones, in arrival order.
    func addInterest(_ token: InterestToken, asset: AssetID, entry: ManifestEntry, lane: AssetPriority, kind: InterestKind) {
        let transfer = entry.transferID
        if self.defersToFollow {
            let listed = self.state.applied.entry(for: asset).map { SyncEngine.sameTransfer($0, entry) } ?? false
            self.state.joinsAfterFollow[token, default: [:]][asset] = transfer
            let chain = listed ? JoinChain(serial: self.state.copySerial, layers: []) : nil
            self.deferToFollow(.join(JoinAfterFollow(token: token, asset: asset, entry: entry, lane: lane, kind: kind, listed: listed, chain: chain)))
            self.notifyObservers()
            return
        }
        if self.state.inFollowVisit || self.state.visitingAfterVerdict, let waiting = self.state.jobs[transfer], let end = waiting.attemptEnd, end.deferredAfter != nil, self.joinWaitsForVerdict(asset, entry: entry, end) {
            // A visit that moves an interest onto a job whose exit verdict waits, for an apply after the verdict deferred:
            // a visit-first engine's visit at that apply met the job as the verdict left it (`joinWaitsForVerdict`).
            self.deferBehindVerdict(JoinAfterFollow(token: token, asset: asset, entry: entry, lane: lane, kind: kind, listed: true), of: waiting)
            self.notifyObservers()
            return
        }
        let now = self.decisionNow()
        self.noteJoin(transfer, asset: asset, entry: entry, token: token, kind: kind)
        let before: AssetPriority
        let wasReleasedOnly: Bool
        // The job is read in this scope only: the join below is made in the table, with no copy of the job alive, as a
        // copy's id sets would be copied whole by the insertion (a job that grows to 10,000 ids cost a follow turn of 256
        // joins up to 19 ms; Stage 3 close-out cycle 18, ruling S3-R21 item 1; `BenchSync.concentrationFollowTurns`).
        if let job = self.state.jobs[transfer] {
            before = job.lane
            // A queued job only released groups want may wait in no queue (a scan set its entry aside, `setsAside`).
            wasReleasedOnly = job.state == .queued && self.isReleasedOnly(job)
        } else {
            self.state.lastEpoch += 1
            self.state.jobsCreated += 1
            var job = Job(
                transfer: transfer,
                entry: entry,
                identity: entry.contentIdentity,
                assets: [asset],
                state: .queued,
                epoch: self.state.lastEpoch,
                queuedAt: now
            )
            job.resume = self.state.launchResumes.removeValue(forKey: transfer)
            job.setInterest(JobInterest(lane: lane, kind: kind, assets: [asset]), for: token)
            self.state.jobs[transfer] = job
            self.enqueue(transfer)
            self.ensureWatcher()
            self.notifyObservers()
            return
        }
        self.state.jobs[transfer]?.assets.insert(asset)
        if self.state.jobs[transfer]?.interests[token] != nil {
            // The interest keeps its lane: a token's interests carry the one lane it registered with, which every join
            // and re-route passes on (`invariantViolations()`). The cycle-18 in-place raise, which no path reached, was
            // removed under ruling S3-R19 item 3 (Stage 3 close-out cycle 19).
            self.state.jobs[transfer]?.insertAsset(asset, for: token)
        } else {
            self.state.jobs[transfer]?.setInterest(JobInterest(lane: lane, kind: kind, assets: [asset]), for: token)
        }
        if self.state.jobs[transfer]?.state.isCircuitParked == true, let job = self.state.jobs[transfer] {
            // The interest may raise the job's rank: its place in the breaker's order moves with it.
            self.noteCircuitParked(job)
        }
        if wasReleasedOnly {
            // Now that this interest wants it, it is queued again at the place it waited, in the queue its lane now
            // selects, whether the interest keeps its lane, changes it or comes from user work: jobs re-joined in one turn
            // keep their order and pass no work queued before them, and a promotion jumps the queue as R-SYN-3 says
            // (L4-R24(4); Stage 3, S3-B-065). An entry left in a queue or aside is stale. `relane`'s re-queue at the
            // back is for a job that waited in its queue all along.
            self.reinstate(transfer)
        } else {
            self.relane(transfer, from: before)
        }
        self.failFastJoiner(token, of: transfer)
        self.notifyObservers()
    }

    /// Keeps the indexes a join feeds (Stage 3, S3-PERF-02): a job joined for an entry the engine's copy does not name for
    /// `asset` may need moving at the next follow (`unfollowed`); a system interest's job is visited by a run's release
    /// of re-attachments (`systemHeld`); the active run's interest is removed at its end (`RunState.held`). One lookup in
    /// the copy and a comparison of the two entries' transfer keys, no transfer formatted. An owed move's join under the
    /// copy an apply has replaced since (`SyncEngine.continueInbound`) is compared with the engine's copy too: a job that
    /// holds an id the copy maps elsewhere is in `unfollowed` (`invariantViolations()`), whether or not the pass over the
    /// copy has reached the id.
    private func noteJoin(_ transfer: TransferID, asset: AssetID, entry: ManifestEntry, token: InterestToken, kind: InterestKind) {
        if let listed = self.state.applied.entry(for: asset), SyncEngine.sameTransfer(listed, entry) {
            // Follows the copy.
        } else {
            self.state.unfollowed.insert(transfer)
        }
        switch kind {
        case .system:
            self.state.systemHeld.insert(transfer)
        case .run:
            if self.state.run?.token == token {
                self.state.run?.held.insert(transfer)
            }
        default:
            break
        }
    }

    /// Whether two entries of the same id are fetched by the same transfer (`ManifestEntry.transferID`) without
    /// formatting either: the checksum's when both have one, else the remote path when neither has.
    static func sameTransfer(_ first: ManifestEntry, _ second: ManifestEntry) -> Bool {
        switch (first.checksum, second.checksum) {
        case (let one?, let other?):
            return one == other
        case (nil, nil):
            return first.identifier == second.identifier && first.remotePath == second.remotePath
        default:
            return false
        }
    }

    /// A new interest in a job that stays parked gets the answer a new job would get when it parks (the fail-fast
    /// policy runs only when a job parks, so a joiner would otherwise wait for a gate that may never open). A job parked
    /// for lack of space is re-checked first against the latest free-space read: a new job would start if it fits.
    func failFastJoiner(_ token: InterestToken, of transfer: TransferID) {
        if case .blocked(.insufficientSpace)? = self.state.jobs[transfer]?.state, let job = self.state.jobs[transfer], self.spaceBlock(job) == nil {
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
            }
            return
        }
        if case .blocked(let reason)? = self.state.jobs[transfer]?.state {
            // A job parked by an origin gate that admits at `now` (its re-admission has not run) is re-admitted, now or
            // by an owed follow-up, rather than answered with a block that no longer holds (F-40).
            let gate = self.originGateNow()
            if gate.admits(reason) == true {
                self.readmitOpenedOriginGates(gate)
                // A breaker that admits only a probe re-admits the first job in the pump's order (S3-B-063): a job that
                // stays parked behind it would be parked again once that job takes the probe, so its joiner gets that
                // park's answer now, as before the re-admission was lazy.
                guard case .circuitOpen = reason, gate.breaker == .probe, self.state.jobs[transfer]?.state.isCircuitParked == true else {
                    return
                }
            }
        }
        switch self.state.jobs[transfer]?.state {
        case .blocked(let reason)?:
            self.failFast(transfer, reason: reason, only: token)
        case .failed(.whenOnline)?:
            self.failFast(transfer, reason: .offline, only: token)
        default:
            break
        }
    }

    /// A system interest (launch re-attachment, healing): released when the job ends or the first run claims it.
    func addSystemInterest(entry: ManifestEntry, lane: AssetPriority) {
        let token = self.nextToken()
        self.addInterest(token, asset: entry.identifier, entry: entry, lane: lane, kind: .system)
    }

    /// Whether a re-lane of `job`, failed with its verdict not yet deferred, comes from an input that met the attempt
    /// still running on a visit-first engine (`relane`): a visit for an apply before the end, the follow's own or move
    /// (`inFollowVisit`) or the drain's after a verdict (`visitingAfterVerdict`; the applies followed then,
    /// `AttemptEnd.failedAfter` or `Job.transferSpaceEnd`), or, outside a visit, the drain's replay of an event that
    /// arrived before the publication's end (the replay's decision instant, `EngineState.reading`, against
    /// `AttemptEnd.stamped`; Stage 3 close-out cycle 22, ruling S3-R27 item 12.2's e1-P1). A visit's reading is the instant
    /// of the apply it belongs to, so it is dated by the applies, as before. The drain's visit after a verdict stands for
    /// visits at the applies since that verdict deferred, not for the verdict's arrival, so it is dated by the applies
    /// too: one before the end met the job publishing on a visit-first engine, one since met it failed (cycle 22, e1-P2).
    func metInItsAttempt(_ job: Job) -> Bool {
        if self.state.inFollowVisit || self.state.visitingAfterVerdict {
            return self.state.appliesFollowed == (job.attemptEnd?.failedAfter ?? job.transferSpaceEnd)
        }
        guard let reading = self.state.reading, let stamped = job.attemptEnd?.stamped else {
            return false
        }
        return reading.serial <= stamped
    }

    /// Re-evaluates a job after its lane changed: promotion re-queues or re-prioritises it, demotion re-runs
    /// admission (sync-1 S1-07), and a user request skips a backoff (T20), unless the job's attempt is still at its end
    /// for the follow: its verdict waiting, or being booked while the follow's own visit stands for one at an apply
    /// before the end (Stage 3 close-out cycle 21, ruling S3-R26 item 5, probe (i)) or the drain replays an event that
    /// arrived before it (`metInItsAttempt`; cycle 22, ruling S3-R27 item 12.2's e1-P1).
    func relane(_ transfer: TransferID, from before: AssetPriority) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let after = job.lane
        let isUser = after == .userInitiated
        switch job.state {
        case .queued:
            if after != before || isUser {
                self.enqueue(transfer)
            }
        case .downloading:
            guard after != before else {
                return
            }
            if after > before {
                self.state.metrics.promotions += 1
            }
            self.setPriority(transfer, after)
            if after < before {
                self.pauseIfRefused(transfer)
            }
        case .failed(let disposition):
            if job.attemptEnd?.deferredAfter != nil || self.metInItsAttempt(job) {
                // The attempt's verdict waits for the follow (`defersFailure`, or an ENOSPC's in `spaceFailed`;
                // `recordDeferredVerdict`). Only the follow's own visit, an attempt's end that brings a visit's interests
                // forward (`bringInbound`), or an event the drain applies before the verdict, re-lanes such a job: each
                // met a running attempt on a visit-first engine, whose re-lane only re-prioritised it, so nothing is done
                // (marking the job joined skipped the retry's backoff, PROBE-C9-SPURIOUS-JOIN; an ENOSPC's verdict was
                // skipped for the re-queue until Stage 3 close-out cycle 17). Every other re-lane comes from an input
                // that waits behind the verdict as an event of its own (a join, a withdrawal), so the cycle-10 `.relane`
                // event is gone (S3-R14 item 4).
                //
                // So does the follow's own visit or move (`inFollowVisit`) while the publication's end is recorded and its
                // verdict not yet deferred, with no apply followed since the end (`recordPublicationEnd`): an ENOSPC's
                // free-space read runs a follow turn behind the barrier (`advanceFollowForSpaceSweep`) before its verdict
                // defers (`spaceFailed`), and that turn's joins and removals stand for visits at applies before the end,
                // which met the job publishing on a visit-first engine. Re-queued for a user interest (T20), the job's
                // ENOSPC verdict was skipped (`decideSpaceFailure` returns for a queued job): the attempt went uncounted,
                // and at the cap the interests got a second request's answer where that engine's verdict gave them the
                // space figures (Stage 3 close-out cycle 21, ruling S3-R26 item 5, probe (i)). A transfer's ENOSPC has the
                // same window before its reads (`failed`), its end recorded as `Job.transferSpaceEnd`: that engine's visit
                // met the job downloading, whose re-lane re-queues nothing either. A visit for an apply made since the end
                // met the job failed, as that engine's did, and skips the backoff (T20).
                //
                // So does the drain's replay, in that window, of an event that arrived before the publication's end: the
                // read's turns may end the follow and run the drain, whose replay of a join, or of a batch of owed
                // re-routes pinned to the job (`waitingTarget(_:epoch:)`), stands for an input that met the job
                // publishing on a visit-first engine; re-queued, the job's ENOSPC verdict was skipped as above (Stage 3
                // close-out cycle 22, ruling S3-R27 item 12.2's e1-P1). An event that arrived inside the read met the job
                // failed, as that engine's input did, and skips the backoff (T20). A transfer's ENOSPC records no such
                // instant (`AttemptEnd.stamped`), so a replay inside its reads is not told apart (cycle 22's residual).
                // The drain's visit after a verdict (`followAfterVerdict`) moves the ids of the applies since that verdict
                // deferred, and is dated as the follow's visit is, by the applies followed since the end (cycle 22, e1-P2).
                return
            }
            if isUser, disposition != .untilEntryChanges, self.originAdmitsUser() {
                if self.transition(transfer, to: .queued) {
                    self.state.heap.remove(.retry(transfer, epoch: job.epoch))
                    self.enqueue(transfer)
                }
            }
        case .blocked(let reason):
            if after > before, self.blockCleared(reason, lane: after, job: job) {
                if self.transition(transfer, to: .queued) {
                    self.enqueue(transfer)
                }
            }
        case .verifying, .committing:
            break
        }
    }

    /// Whether the origin's breaker and throttle let a user-initiated request skip a backoff (T20).
    private func originAdmitsUser() -> Bool {
        guard self.state.remote != nil else {
            return false
        }
        // The origin's gates as the next dispatch reads them (F-40): no throttle in force, and a breaker that would
        // admit the request (closed, or open to a probe).
        let gate = self.originGateNow()
        return gate.admitsThrottleParked && gate.admitsBreakerParked
    }

    /// Removes interest `token` from `transfer` (all its assets) and retires the job when nobody is left: no interest
    /// and no pending claim on its content, from a registered group or a release still dropping claims (ruling L5-R1,
    /// CCR-G2). Every release, waiter withdrawal and caller cancellation removes interests here, so none of them retires
    /// a job such a registration named; the job keeps its state, its place and its lane (`Job.heldLane`) until that join
    /// adds its interest (a promotion or a demotion of a running transfer reaches the transport as a priority change)
    /// or the claim ends (`dropClaim` retires it then). The engine's other exits do not pass here and are unchanged
    /// (L5-R1): a content left the manifest or changed (`followApplied`, `supersede`), became present (the pre-transfer
    /// read retires its job directly), failed or was held back (`EngineFailures`), or committed (`resolveAll`).
    ///
    /// Behind the follow barrier a removal applies now, except a waiter's withdrawal, which waits behind the verdicts and
    /// joins that arrived before it (`withdraw`, `EventAfterFollow.removal`; PROBE-C10-JOIN-RETIRE). The deferral of the
    /// other removals here (a run's end, a release of re-attachments, a group's release; S3-R14 item 3) made only their
    /// order equal to a visit-first engine's (a transfer kept or stopped and started again) and was removed in Stage 3
    /// close-out cycle 13 under ruling S3-R16 item 3 (recorded in the WP-F draft as a residual risk).
    func removeInterest(_ token: InterestToken, from transfer: TransferID) {
        self.dropInterest(token, from: transfer)
    }

    /// `removeInterest`: an interest answered (`resolve`) is dropped here too. The job is changed in place, with no copy
    /// of it alive across the removal: a copy shares the storage of its interests, so the removal copied them whole, once
    /// for each interest a follow's move removes (O(interests) per id; Stage 3 close-out cycle 20, ruling S3-R25 item 2).
    private func dropInterest(_ token: InterestToken, from transfer: TransferID) {
        guard self.state.jobs[transfer]?.interests[token] != nil, let before = self.state.jobs[transfer]?.lane else {
            return
        }
        self.state.jobs[transfer]?.setInterest(nil, for: token)
        if self.state.run?.token == token {
            self.state.run?.held.remove(transfer)
        }
        self.settleRemoval(transfer, before: before, last: before)
    }

    /// Settles `transfer`'s job once interests left it (`dropInterest`, one; `SyncEngine.takeOffMovedBefore`, several,
    /// removed in one access, `Job.takeOff(_:)`): a job left with no interest keeps `last`, its lane before the last
    /// removal (`Job.heldLane`), while a claim on its content keeps it, and is retired otherwise; one left with interests
    /// is re-laned from `before`, its lane before the first removal.
    func settleRemoval(_ transfer: TransferID, before: AssetPriority, last: AssetPriority) {
        if self.state.jobs[transfer]?.interests.isEmpty == true, let key = self.state.jobs[transfer].map(ClaimKey.init(job:)) {
            self.state.jobs[transfer]?.heldLane = last
            if self.state.claims[key] != nil {
                // Kept for the claim: its last end retires the job (`dropClaim`).
                self.state.claimHeld[key] = transfer
            } else {
                self.retire(transfer)
            }
        } else {
            self.relane(transfer, from: before)
        }
        self.notifyObservers()
    }

    /// The one synchronous removal funnel (ARCHITECTURE §7.1): a job with no interest that is not verifying or
    /// committing is removed and its transfer cancelled; out of verifying/committing it is removed when that ends.
    func retire(_ transfer: TransferID) {
        guard let job = self.state.jobs[transfer], job.interests.isEmpty else {
            return
        }
        switch job.state {
        case .verifying, .committing:
            return
        case .downloading:
            if let active = job.active {
                self.abandon(transfer, active)
            }
            // Whether or not its stream already ended, the transfer leaves without a verdict (§7.7).
            self.recordBreaker(.abandoned(transfer))
        case .queued, .failed, .blocked:
            break
        }
        self.removeJob(transfer)
    }

    /// Cancels a running attempt nobody wants any more and, while its terminal element is still outstanding, records it
    /// as draining so no new attempt of the transfer starts before its stream ended (`finishAttempt` clears it). An
    /// attempt whose terminal element was consumed (its driver awaits a sidecar read or a discard) or that has no stream
    /// is over: recording it would leave a drain nothing clears, and every later job of the transfer would stay queued.
    /// `true` when the attempt was still running.
    @discardableResult
    func abandon(_ transfer: TransferID, _ active: ActiveAttempt) -> Bool {
        guard !active.terminalReceived else {
            return false
        }
        self.state.draining[transfer] = DrainingAttempt(attempt: active.attempt, driver: active.driver)
        if let handle = active.handle {
            handle.cancel()
        } else {
            // The driver cancels the handle as soon as `remote.transfer` returns it (RE-S12).
        }
        return true
    }

    /// Drops a job and every deadline, progress key and kept staged file it owns (sync-1 S1-10, ADR-023).
    func removeJob(_ transfer: TransferID) {
        guard let job = self.state.jobs.removeValue(forKey: transfer) else {
            return
        }
        if let bytes = job.ledgerBytes {
            self.state.inFlightBytes.remove(bytes)
            self.state.inFlight.remove(transfer)
        }
        self.state.spaceParked.remove(transfer)
        self.state.laneParked.remove(transfer)
        if self.state.circuitParked.remove(transfer) != nil, self.state.circuitParked.isEmpty {
            self.state.circuitOrder.removeAll()
        }
        if self.state.probeCandidate == transfer {
            // The job queued for the breaker's probe ended before it took it: a pump re-admits the next parked job.
            self.state.probeCandidate = nil
            if !self.state.circuitParked.isEmpty {
                self.schedulePumpFollowUp()
            }
        }
        self.state.throttleParked.remove(transfer)
        self.state.failedJobs.remove(transfer)
        self.state.edgeOwed.remove(transfer)
        self.state.originOwed.remove(transfer)
        self.state.unfollowed.remove(transfer)
        self.state.verdictsAfterFollow[transfer] = nil
        self.state.systemHeld.remove(transfer)
        self.state.run?.held.remove(transfer)
        self.state.spaceAdmitted[transfer] = nil
        if let adopt = job.adopt {
            // A drained copy nobody will publish now.
            self.discardLater(adopt.name)
        }
        self.state.heap.remove(.retry(transfer, epoch: job.epoch))
        // Only a key with a `lastEmitted` entry has anything to retire: a trailing emission, a scheduled flush and a
        // subscriber's live slot each imply one (the progress gate's clauses P1-P3, `invariantViolations`), and
        // progress is offered for one id of a job (`onProgress`), so the other ids skip a retire that does nothing
        // (step C4).
        for asset in job.assets where self.state.progress.lastEmitted[.transfer(asset)] != nil {
            self.retireProgress(.transfer(asset))
        }
        self.compactQueuesIfStale()
        self.notifyObservers()
    }

    // MARK: Lane queues

    /// The queue a job waits in.
    func queueKind(_ job: Job) -> LaneQueues.Kind {
        switch job.lane {
        case .userInitiated:
            return job.isSingleUser ? .userSingle : .userBatch
        case .prefetch:
            return .prefetch
        case .bulk:
            return .bulk
        }
    }

    /// Puts a queued job (back) into its lane's queue with a fresh ticket, asked for at `decisionNow()` (bulk aging reads
    /// it, the cycle-9 amendment (a)).
    ///
    /// Behind the follow barrier a place is given by a follow's visit or by the drain's replay of an event, each in the
    /// visit-first order (F-28), and by one path at once: a publication's ENOENT re-queue of an attempt the engine
    /// cancelled, whose place ahead of the visits' places is an order difference only (Stage 3 close-out cycle 13,
    /// ruling S3-R16 item 3). A follow's visit is every join, move and removal the follow makes, wherever its turn
    /// runs: its own turns, an attempt's end turn (`makeInboundNow`) and an ENOSPC's free-space read
    /// (`advanceFollowForSpaceSweep`). Their re-lanes give places too (`relane`: a lane change, a user request's
    /// backoff skip for a visit at an apply made since the job's attempt ended, T20, and a park a raise clears), and so
    /// does a joiner's re-check of a space park (`failFastJoiner`). None of these starts the job, so it keeps its
    /// attempt's epoch and an owed move found at that attempt's end still names it (`waitingTarget(_:)`; Stage 3
    /// close-out cycle 21, ruling S3-R26 item 5). Every other path that queues a job waits as an event of its own (a
    /// join, a verdict, a re-admission), so the cycle-9 `.enqueue` event is gone. The barrier-end pump admits every
    /// place on the live throttle, breaker, slots and space alone (`gate`; Stage 3 close-out cycle 15, ruling S3-R18
    /// item 1): the cycle-12 to cycle-14 place stamps, which refused a place on its decision instant's throttle, are
    /// gone.
    func enqueue(_ transfer: TransferID, front: Bool = false) {
        guard var job = self.state.jobs[transfer], job.state == .queued else {
            return
        }
        if !front {
            job.queuedAt = self.decisionNow()
        }
        self.state.lastTicket += 1
        job.ticket = self.state.lastTicket
        self.state.jobs[transfer] = job
        let kind = self.queueKind(job)
        let entry = LaneQueues.Entry(ticket: job.ticket, transfer: transfer, queuedAt: job.queuedAt)
        let place = self.state.queues.push(entry, to: kind, front: front)
        self.state.jobs[transfer]?.queuePlace = place
        self.compactQueuesIfStale()
    }

    /// Queues a job again at the place its entry had (`Job.queuePlace`), with a fresh ticket: its old entry, set aside by
    /// a scan or still in place, goes stale. For a job only released groups wanted that an interest at its own lane
    /// wants again (`addInterest`): pushed to the front, the jobs re-joined in one turn were dispatched in reverse order
    /// and ahead of work queued before them (review of close-out cycle 10, PROBE-C10R-3; R-SYN-3). Never behind the
    /// follow barrier: its only caller, `addInterest`, defers every join but the follow's own and the drain's (cycle 11),
    /// so the cycle-9 `.reinstate` event is gone.
    func reinstate(_ transfer: TransferID) {
        guard var job = self.state.jobs[transfer], job.state == .queued else {
            return
        }
        self.state.lastTicket += 1
        job.ticket = self.state.lastTicket
        self.state.jobs[transfer] = job
        let entry = LaneQueues.Entry(ticket: job.ticket, transfer: transfer, queuedAt: job.queuedAt, place: job.queuePlace)
        self.state.queues.reinstate(entry, to: self.queueKind(job))
        self.compactQueuesIfStale()
    }

    /// Keeps the lane queues within twice their live entries (sync.md §7.2): once stored entries outnumber twice the
    /// jobs, one pass drops the stale ones. Checked where entries are added (`enqueue`) and where jobs leave
    /// (`removeJob`): a release of queued members left their entries stored until the next enqueue (close-out cycle 11).
    /// The threshold halves the stored entries at each pass, so a release of 10,000 queued members compacts a few
    /// times, not once per member (C2).
    func compactQueuesIfStale() {
        guard self.state.queues.storedCount > 2 * self.state.jobs.count + 16 else {
            return
        }
        // The queues are taken out of the state while the closure reads it (no overlapping access).
        var queues = self.state.queues
        self.state.queues = LaneQueues()
        queues.compact { self.isValid($0) }
        self.state.queues = queues
    }

    /// Whether a queue entry still stands for a queued job.
    func isValid(_ entry: LaneQueues.Entry) -> Bool {
        guard let job = self.state.jobs[entry.transfer] else {
            return false
        }
        return job.ticket == entry.ticket && job.state == .queued
    }

    // MARK: Resolution (S1-02)

    /// Ends interest `token` of `transfer` with `outcome`: a waiter is resumed (through `removeValue`, so at most once),
    /// a group member settles, a run records the outcome; the interest is removed and the job retired when empty.
    func resolve(_ token: InterestToken, of transfer: TransferID, with outcome: InterestOutcome) {
        guard let job = self.state.jobs[transfer], let interest = job.interests[token] else {
            return
        }
        self.deliver(outcome, to: token, interest: interest, transfer: transfer)
        self.dropInterest(token, from: transfer)
    }

    /// Delivers `outcome` to the owner of `token` without touching the job. With `owing`, a waiter's or a settled
    /// ensure group's caller is not resumed here: the answer, computed and taken out of the state as without it, is
    /// owed to the answer follow-ups (`EngineState.owedAnswers`; `resolveAll`).
    func deliver(_ outcome: InterestOutcome, to token: InterestToken, interest: JobInterest, transfer: TransferID, owing: Bool = false) {
        switch interest.kind {
        case .waiter:
            guard let waiter = self.state.waiters.removeValue(forKey: token) else {
                return
            }
            let result: Result<AssetLocation, AssetError>
            switch outcome {
            case .committed(let locations, _):
                result = locations[waiter.asset].map { .success($0) } ?? .failure(.notFound)
            case .failed(let error):
                result = .failure(error)
            }
            guard let continuation = waiter.continuation else {
                return
            }
            if owing {
                self.state.owedAnswers.append(.waiter(token, continuation, result))
            } else {
                continuation.resume(returning: result)
            }
        case .prefetch, .ensure:
            // In place through the table: a copy taken out and written back would copy the group's `pending` on every
            // delivery, O(members) each (step C5).
            guard self.state.groups[token] != nil else {
                return
            }
            self.state.groups[token]?.clearPending(interest.assets, on: transfer)
            if interest.kind == .ensure, self.state.groups[token]?.spaceFailure == nil, case .failed(let error) = outcome, case .insufficientSpace = error {
                self.state.groups[token]?.spaceFailure = error
            }
            if interest.kind == .ensure, self.state.groups[token]?.isSettled == true, let continuation = self.state.groups[token]?.continuation {
                self.state.groups[token]?.continuation = nil
                if owing {
                    self.state.owedAnswers.append(.ensure(token, continuation))
                } else {
                    continuation.resume(returning: true)
                }
            }
        case .run:
            self.recordRunOutcome(outcome, transfer: transfer, assets: interest.assets)
        case .system:
            // A heal ends with its job, committed or failed (a heal still scheduled for later is kept).
            let now = self.decisionNow()
            for asset in interest.assets {
                if case .committed = outcome {
                    self.state.heals[asset] = nil
                } else if let due = self.state.heals[asset], due <= now {
                    self.state.heals[asset] = nil
                }
            }
        }
    }

    /// Drops `asset` from group `token` while it still waits for `transfer` (the asset left the manifest, T21); an
    /// `ensureAvailable` group whose last member went completes.
    /// In place through the table, as `deliver` changes a group: a copy written back would copy `pending` per dropped
    /// member (step C10).
    func dropGroupMember(_ token: InterestToken, asset: AssetID, from transfer: TransferID) {
        guard self.state.groups[token]?.pending[asset] == transfer else {
            return
        }
        self.state.groups[token]?.pending[asset] = nil
        guard let group = self.state.groups[token], group.kind == .ensure, group.isSettled, let continuation = group.continuation else {
            return
        }
        self.state.groups[token]?.continuation = nil
        continuation.resume(returning: true)
    }

    /// Resolves every interest of `transfer` with `outcome`, in the table's order, and removes the job; `follow` runs
    /// once the job is gone and before the run is checked for settling (interests that move to a fresh job of the
    /// transfer). A failure is not delivered to an id the copy moved while a follow is owed: behind the follow barrier
    /// the verdict waits for the follow, whose visit moves that id first (`defersFailure`, F-28), so its interest waits
    /// for its new content, never `.notFound` while it is listed (F-20; the close-out cycle-2 correctness lens,
    /// PROBE-W4).
    ///
    /// With `boundOnly`, a commit answers each interest only the ids it bound, and an interest it bound none of not at
    /// all, as it answers a job trimmed to them first (`committed`, which owes the other ids' re-routes and retires the
    /// job untrimmed); the terminal events read the lane of the interests it answered, as they read a trimmed job's.
    /// Counting an interest's unbound ids allocates nothing, and only a partly bound interest is copied.
    ///
    /// A job of more than `answersPerTurn` interests owes its waiters' and its settled ensure groups' resumes (`deliver`'s
    /// `owing`) to the answer follow-ups, `answersPerTurn` a turn (Stage 3 close-out cycle 21, ruling S3-R26 item 4's
    /// Phase 2, `integrate-c21.md` C12): every answer is still computed here, from this turn's state, and every waiter
    /// leaves `waiters` here, so each caller gets the value it got when every resume was made in this turn; only the
    /// moment it returns moves. 10,000 user waiters' resumes held a commit's turn 11.0 to 11.6 ms (C2). The other
    /// deliveries (prefetch groups, a run, heals) resume no caller and are made here.
    func resolveAll(_ transfer: TransferID, with outcome: InterestOutcome, boundOnly: Bool = false, then follow: () -> Void = {}) {
        if case .failed(let answer) = outcome, self.defersFailure(transfer, .resolve(answer)) {
            return
        }
        guard let job = self.state.jobs[transfer] else {
            return
        }
        // `deliver` never writes `state.jobs` (it writes waiters, groups, the run and heals; a resumed caller runs
        // after this turn), so the copy's interests are the job's at every delivery: no sort and no re-read (step C2).
        // The callers resume in the table's order, an accepted order (S3-R16 item 2; Stage 3 close-out cycle 21).
        var bound: [AssetID: AssetLocation]?
        if boundOnly, case .committed(let locations, _) = outcome {
            bound = locations
        }
        var answered = InterestCounts()
        let owing = job.interests.count > self.state.answersPerTurn
        for (token, interest) in job.interests {
            guard let bound else {
                self.deliver(outcome, to: token, interest: interest, transfer: transfer, owing: owing)
                continue
            }
            let unbound = interest.assets.reduce(0) { count, asset in bound[asset] == nil ? count + 1 : count }
            if unbound > 0, unbound == interest.assets.count {
                continue
            }
            let narrowed = unbound == 0 ? interest : JobInterest(lane: interest.lane, kind: interest.kind, assets: interest.assets.filter { bound[$0] != nil })
            answered.add(narrowed)
            self.deliver(outcome, to: token, interest: narrowed, transfer: transfer, owing: owing)
        }
        self.state.jobs[transfer]?.removeAllInterests()
        self.removeJob(transfer)
        self.publishTerminal(job: job, outcome: outcome, lane: bound == nil ? job.lane : job.lane(counting: answered))
        follow()
        self.checkRunSettled()
        // Scheduled on what is owed, not on `owing`: a job's prefetch groups and run owe no resume.
        if self.state.owedAnswers.count > self.state.owedAnswersHead {
            self.scheduleAnswerFollowUp()
        }
    }

    /// The interests a resolution answers in its own turn, and the owed answers an answer follow-up resumes, at most
    /// (`resolveAll`; `answersPerTurn` in `EngineState` is the seam): a resume costs about 1 µs in release
    /// (`shutdownStepsPerTurn`'s figure), so a turn of 512 stays well under a millisecond (C2).
    static let answersPerTurn = 512

    /// Schedules the answer follow-up for the owed answers, unless one is scheduled. Its task is the one the invariants
    /// expect while answers are owed and the engine runs (`answerViolations`): `spawn` refuses one only once shutdown
    /// began, whose drain resumes the owed answers (`drainEverything`).
    private func scheduleAnswerFollowUp() {
        guard self.state.answerFollowUp == nil else {
            return
        }
        self.state.answerFollowUp = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: it resumes answers stored in the resolution's turn, from the head the state
            // holds then; a shutdown meanwhile resumed them and emptied the table (`drainEverything`).
            await engine.answerFollowUp()
        }
    }

    /// The scheduled answer follow-up: resumes at most `answersPerTurn` owed answers, oldest first, empties the table
    /// once its last is resumed, and schedules itself again while answers remain.
    private func answerFollowUp() {
        if self.state.answerFollowUpsHeld {
            // Test seam: the answers stay owed and the follow-up stays scheduled until the release runs it.
            self.state.answerFollowUpWaiting = true
            self.notifyObservers()
            return
        }
        self.state.answerFollowUp = nil
        guard self.isRunning else {
            return
        }
        let end = min(self.state.owedAnswers.count, self.state.owedAnswersHead + self.state.answersPerTurn)
        for index in self.state.owedAnswersHead..<end {
            self.state.owedAnswers[index].resume()
        }
        self.state.owedAnswersHead = end
        if end == self.state.owedAnswers.count {
            self.state.owedAnswers.removeAll()
            self.state.owedAnswersHead = 0
        } else {
            self.scheduleAnswerFollowUp()
        }
        self.notifyObservers()
    }

    /// Test seam: the answer follow-ups keep their answers owed until `releaseAnswerFollowUps()`, so a test meets the
    /// engine between two of them.
    func holdAnswerFollowUps() {
        self.state.answerFollowUpsHeld = true
    }

    /// Test seam: lets a held answer follow-up run in this turn, or disarms a hold nothing reached.
    func releaseAnswerFollowUps() {
        self.state.answerFollowUpsHeld = false
        guard self.state.answerFollowUpWaiting else {
            return
        }
        self.state.answerFollowUpWaiting = false
        self.answerFollowUp()
    }

    /// The non-bulk per-asset terminal events (bulk outcomes fold into run progress, ADR-023), in ascending id order.
    /// A commit walks its binding, which `publish` sorted: the store binds only ids of it, so the bound ids of
    /// `job.assets` come in the order `job.assets.sorted()` gave them, with no sort (step C3). The subscriber keys are
    /// sorted once for every event (step C8). `lane` is the lane of the interests the outcome answers: the job's, unless
    /// a commit answered each interest only its bound ids (`resolveAll`'s `boundOnly`).
    func publishTerminal(job: Job, outcome: InterestOutcome, lane: AssetPriority) {
        guard lane > .bulk else {
            return
        }
        let keys = self.state.subscribers.keys.sorted()
        switch outcome {
        case .committed(let locations, let ascending):
            for asset in ascending where locations[asset] != nil && job.assets.contains(asset) {
                self.broadcast(.assetAvailable(asset, generation: self.state.generation), to: keys)
            }
        case .failed(let error):
            for asset in job.assets.sorted() {
                self.broadcast(.assetFailed(asset, error, .nextRun), to: keys)
            }
        }
    }

    /// The fail-fast policy when a job is parked (ARCHITECTURE §7.6/§7.7): which interests get an answer now; `only`
    /// restricts it to one interest (a joiner of a parked job). A throttle's wait is read at the decision instant
    /// (`decisionNow()`) against the end the origin's throttle had then (`throttleEnd(after:)`): a replayed 429's park
    /// reads both from its reading (`replayThrottle`).
    func failFast(_ transfer: TransferID, reason: BlockReason, only: InterestToken? = nil) {
        guard let job = self.state.jobs[transfer] else {
            return
        }
        let now = self.decisionNow()
        for token in job.interests.keys.sorted() where only == nil || only == token {
            guard let interest = self.state.jobs[transfer]?.interests[token], let error = self.failFastError(reason, for: interest, of: job, at: now) else {
                continue
            }
            self.resolve(token, of: transfer, with: .failed(error))
        }
    }

    /// The fail-fast answer `interest` of `job` gets when the job parks for `reason` at the decision instant `now`
    /// (`failFast`), or `nil` when it keeps waiting: only a waiter or an ensure is answered, a throttle only for a wait
    /// beyond the interest's lane's limit. Shared by `failFast` and `verdictAnswers`, which reads whom a waiting verdict's
    /// park answers (Stage 3 close-out cycle 17, PROBE-C16C-THROTTLE-FAILFAST-LANE).
    func failFastError(_ reason: BlockReason, for interest: JobInterest, of job: Job, at now: MonotonicInstant) -> AssetError? {
        guard interest.kind == .waiter || interest.kind == .ensure else {
            return nil
        }
        switch reason {
        case .offline:
            return .offline
        case .circuitOpen(let cause):
            return cause == .authentication ? .authRejected(.confirmed) : .serverUnavailable(retryAfter: nil)
        case .throttled(let until):
            // The origin's end, not the job's: a later 429 may have extended the throttle after it parked (F-36).
            let wait = self.throttleEnd(after: until).seconds(since: now)
            let limit = interest.lane == .userInitiated ? self.tuning.interactiveRetry.interactiveMaxWait : .infinity
            return wait > limit ? .serverUnavailable(retryAfter: wait) : nil
        case .insufficientSpace:
            if case .insufficientSpace? = job.lastError {
                return job.lastError
            }
            return .insufficientSpace(required: job.entry.byteSize ?? 0, available: self.state.freeSpace.map { self.headroom(for: job, in: $0) } ?? 0)
        case .policy, .awaitingSpace:
            return nil
        }
    }

    /// The end of the throttle a job parked with `until` waits for. A parked job keeps the end it was parked with, while
    /// a later 429 extends the origin's throttle and moves only the origin's `.throttle` deadline, which alone re-admits
    /// the job (F-35): the origin's end when it is later, else `until`. Every reader of a parked job's end, the fail-fast
    /// answer, a run's blocked outcome (in the run task's answering turn, close-out cycle 19) and whether the block
    /// cleared, reads it here, so each tells the caller the end a fresh request would get (close-out cycle 16, F-36).
    ///
    /// While the barrier holds, a visit or a replay reads the origin's end as it stood at its decision instant
    /// (`throttleRecorded`, S3-R15 item 1): a later 429's extension answers in its own turn (PROBE-C11-JOIN-THROTTLE-EXT).
    func throttleEnd(after until: MonotonicInstant) -> MonotonicInstant {
        guard let end = self.throttleRecorded() else {
            return until
        }
        return max(end, until)
    }

    /// The answer to a request the origin's throttle refuses, which a refusal ending at `until` produced: the time left
    /// until the origin's end, read now. A manifest outcome carries the end its fetch's turn read, and its waiters answer
    /// after awaits in which a transfer's 429 may extend the throttle (close-out cycle 18, F-38).
    func throttledError(after until: MonotonicInstant) -> AssetError {
        .serverUnavailable(retryAfter: self.throttleEnd(after: until).seconds(since: self.environment.time.monotonicNow()))
    }

    /// `reason` with a throttle's end read through `throttleEnd(after:)`.
    func currentReason(_ reason: BlockReason) -> BlockReason {
        if case .throttled(let until) = reason {
            return .throttled(until: self.throttleEnd(after: until))
        }
        return reason
    }

    /// Whether a blocked reason no longer applies to `job` at `lane`: lack of space is re-checked against the latest
    /// free-space read (T17); `awaitingSpace` waits for the reaper.
    func blockCleared(_ reason: BlockReason, lane: AssetPriority, job: Job) -> Bool {
        switch reason {
        case .offline, .policy:
            return self.laneVerdict(lane) == .admit
        case .throttled, .circuitOpen:
            // The origin's gates as the next dispatch reads them (F-40).
            return self.originGateNow().admits(reason) ?? true
        case .insufficientSpace:
            // `job` already holds the interest that changed its lane, so the ledger reads the lane's volume.
            return self.spaceBlock(job) == nil
        case .awaitingSpace:
            return false
        }
    }

    /// Re-queues the jobs parked `insufficientSpace` that the latest free-space read admits (T17; `sweepSpaceParked`).
    func reconsiderSpaceBlocked() {
        self.sweepSpaceParked(.read)
    }

    /// Re-checks the jobs parked for lack of space against the latest free-space read (T17), in the order the pump serves
    /// them (user singles, user batches, prefetch, bulk; by queue ticket within a lane). Each is admitted against the room
    /// the read leaves after the jobs re-admitted ahead of it, which the gate counts in flight once they start: those of
    /// this sweep and those earlier sweeps re-queued that still wait in the queue (`spaceAdmitted`). Re-queuing every job
    /// that fits on its own only for the gate to park all but the first again took 16 ms in one turn at 10,000 parked
    /// members (review of close-out cycle 7, C2), and the jobs it re-queued while every slot was taken waited in the queue
    /// for room the earlier ones had used. An admitted job is re-queued; an `insufficientSpace` one that is not stays
    /// parked until a later read; an `awaitingSpace` one that is not is treated as `sweep` says. Its figures, when it is
    /// parked `insufficientSpace`, are the bytes it needs against that room (F-22's convention). At most `parksPerPump`
    /// jobs are parked and at most `readmissionsPerTurn` re-queued per turn; the rest are left to a follow-up sweep (one
    /// turn that re-admitted 10,000 members when the volume gained room took about 15 ms: review of close-out cycle 8,
    /// C2). A read stops re-checking once the room left cannot admit even the smallest job parked `insufficientSpace`.
    ///
    /// Behind the follow barrier the sweep judges nothing (F-28; S3-R11 design D3): every verdict it gives (re-queue,
    /// park, the bytes counted ahead, a park's figures and fail-fast answers) reads ranks, lanes, interests and bytes in
    /// flight that the owed visits change, so a verdict given before them depends on whether they ran first, which
    /// cycles 2 to 8 patched case by case (PROBE-C5-LANEDROP, -C6-LANEGAIN, -C7-RANK-*, -C8-DROPPED*,
    /// -C8R-INFLIGHT-PROMOTE). The follow takes priority instead: the sweep's turn runs one follow turn, or one drain
    /// turn of the events that waited for it (`advanceFollowForSpaceSweep`, bounded as every such turn, C2), and owes
    /// itself to a follow-up sweep, which judges once the barrier is down, every job as the whole follow left it. A turn
    /// that follows judges nothing, and a turn that judges follows nothing (VERIFY-C8-C2-MIXED).
    ///
    /// A sweep that arrives behind the barrier also waits as an event at its arrival place (`.spaceSweep`, judged by
    /// `judgeSpaceSweep` in the drain on the followed state): a visit-first engine judged it before the requests that
    /// arrived after it, and a request replayed before the follow-up sweep's judgement took the room the sweep gave a
    /// parked job, a different answer (the cycle-12 residual R-C, ruling S3-R16 item 1(a); Stage 3 close-out cycle 13).
    /// Its own follow-up turns (`arriving: false`) only keep the follow moving and judge once the barrier is down, which
    /// leaves a job the drain re-queued alone (they judge parked jobs only).
    func sweepSpaceParked(_ sweep: SpaceSweep, arriving: Bool = true) {
        if self.followBarrier {
            if arriving, !self.state.drainingAfterFollow {
                self.deferToFollow(.spaceSweep(sweep))
            }
            self.advanceFollowForSpaceSweep()
            self.scheduleSpaceSweepFollowUp(sweep)
            return
        }
        self.judgeSpaceSweep(sweep)
    }

    /// The verdicts of `sweep` on the jobs parked for lack of space now (`sweepSpaceParked`); reached when no barrier
    /// holds, or from the drain's replay of a sweep that arrived behind it (`EventAfterFollow.spaceSweep`).
    func judgeSpaceSweep(_ sweep: SpaceSweep) {
        let ahead = self.spaceAdmittedAhead()
        var (candidates, smallest) = self.spaceSweepCandidates(sweep)
        // A read re-checks only jobs parked `insufficientSpace`, and leaves untouched each it does not admit: once the
        // room left cannot hold the smallest of them, nothing more changes.
        let room = sweep == .read ? self.state.freeSpace.map { self.largestRoom(in: $0) } : nil
        if let room, smallest > room.subtractingClamped(ahead) {
            return
        }
        candidates.sort { ($0.rank, $0.ticket) < ($1.rank, $1.ticket) }
        self.judgeSpaceParked(candidates, sweep: sweep, room: room, smallest: smallest, ahead: ahead)
    }

    /// One space-parked job a sweep may judge, with its place in the pump's order.
    private typealias SweepCandidate = (rank: Int, ticket: UInt64, transfer: TransferID)

    /// The jobs `sweep` judges (every space-parked job, or only the `insufficientSpace` ones for a read), unordered, and
    /// the size of the smallest.
    private func spaceSweepCandidates(_ sweep: SpaceSweep) -> (candidates: [SweepCandidate], smallest: Int64) {
        var candidates: [SweepCandidate] = []
        var smallest = Int64.max
        for transfer in self.state.spaceParked {
            guard let job = self.state.jobs[transfer], case .blocked(let reason) = job.state, sweep != .read || reason == .insufficientSpace else {
                continue
            }
            smallest = min(smallest, self.spaceSize(of: job))
            candidates.append((self.queueRank(job), job.ticket, transfer))
        }
        return (candidates, smallest)
    }

    /// Judges `candidates`, in the pump's order, against `room` (a read's) or the ledger (`sweepSpaceParked`), counting
    /// the bytes of the jobs re-admitted ahead of each. Reached only when no follow is owed (`judgeSpaceSweep`).
    private func judgeSpaceParked(_ candidates: [SweepCandidate], sweep: SpaceSweep, room: Int64?, smallest: Int64, ahead: Int64) {
        var ahead = ahead
        var requeues = 0
        var parks = 0
        var waiting = false
        for candidate in candidates {
            if let room, smallest > room.subtractingClamped(ahead) {
                break
            }
            let transfer = candidate.transfer
            guard let job = self.state.jobs[transfer], case .blocked(let reason) = job.state else {
                continue
            }
            guard let block = self.spaceBlock(job, ahead: ahead) else {
                guard requeues < Self.readmissionsPerTurn else {
                    self.scheduleSpaceSweepFollowUp(sweep)
                    break
                }
                if self.requeueSwept(job, ahead: &ahead) {
                    requeues += 1
                }
                continue
            }
            // A job that does not fit: an `insufficientSpace` one stays parked; an `awaitingSpace` one waits or is parked
            // within this turn's bound.
            guard reason == .awaitingSpace else {
                continue
            }
            if block == .awaitingSpace, sweep == .reclaimed || self.spaceWakeExpected {
                waiting = true
                continue
            }
            guard parks < Self.parksPerPump else {
                self.scheduleSpaceSweepFollowUp(sweep)
                break
            }
            if let space = self.state.freeSpace {
                // The room is computed before the write: the right side of an optional-chained assignment runs inside
                // the write's access to `state` (an exclusivity conflict, review of close-out cycle 6).
                let available = max(0, self.headroom(for: job, in: space).subtractingClamped(ahead))
                if case .insufficientSpace(let required, _)? = job.lastError {
                    // An earlier ENOSPC's figures: the bytes it needed, against the room this read leaves the job.
                    self.state.jobs[transfer]?.lastError = .insufficientSpace(required: required, available: available)
                } else if ahead > 0 {
                    // The fail-fast answer would report the room without the jobs admitted ahead of this one.
                    self.state.jobs[transfer]?.lastError = .insufficientSpace(required: job.entry.byteSize ?? 0, available: available)
                }
            }
            self.park(transfer, reason: .insufficientSpace)
            parks += 1
        }
        if waiting {
            // Re-parking would have asked for a wake (`park`); the jobs left waiting ask for it here.
            self.ensureSpaceWake()
        }
        if parks > 0 {
            self.checkRunSettled()
        }
        if requeues > 0 {
            self.pump()
        }
    }

    /// Re-queues a parked job the space sweep admitted, counts its bytes `ahead` of the jobs the sweep judges after it
    /// (the gate counts them in flight once it starts), and records it in `spaceAdmitted` so later sweeps count it too
    /// while it waits in the queue. `false` when the job could not leave its park (no transition to `.queued`).
    private func requeueSwept(_ job: Job, ahead: inout Int64) -> Bool {
        guard self.transition(job.transfer, to: .queued) else {
            return false
        }
        self.enqueue(job.transfer)
        ahead = PlanBuilder.adding(ahead, max(0, job.entry.byteSize ?? 0))
        self.state.spaceAdmitted[job.transfer] = self.state.jobs[job.transfer]?.ticket
        return true
    }

    /// The bytes of the jobs earlier sweeps re-queued that still wait in the queue with the ticket a sweep gave them;
    /// the others (started, parked again, re-queued by another path, removed) leave `spaceAdmitted`.
    private func spaceAdmittedAhead() -> Int64 {
        guard !self.state.spaceAdmitted.isEmpty else {
            return 0
        }
        var ahead: Int64 = 0
        var kept: [TransferID: UInt64] = [:]
        for (transfer, ticket) in self.state.spaceAdmitted {
            guard let job = self.state.jobs[transfer], job.state == .queued, job.ticket == ticket else {
                continue
            }
            kept[transfer] = ticket
            ahead = PlanBuilder.adding(ahead, max(0, job.entry.byteSize ?? 0))
        }
        self.state.spaceAdmitted = kept
        return ahead
    }

    /// The bytes the headroom ledger needs free for `job` (`spaceBlock`): its entry's size, or the larger figure an
    /// earlier ENOSPC reported.
    private func spaceSize(of job: Job) -> Int64 {
        var size = job.entry.byteSize ?? 0
        if case .insufficientSpace(let required, _)? = job.lastError {
            size = max(size, required)
        }
        return size
    }

    /// The largest room the ledger gives a job that is not in flight on either volume (`headroom(for:in:)` for the
    /// larger volume): a job that needs more fits on neither.
    private func largestRoom(in space: FreeSpace) -> Int64 {
        let volume = max(space.volumeImportant, space.volumeOpportunistic)
        return max(0, volume.subtractingClamped(max(0, space.reserveBytes)).subtractingClamped(self.state.inFlightBytes.clamped).subtractingClamped(self.state.committedSinceRead))
    }

    /// The order the pump serves a job's queue in.
    func queueRank(_ job: Job) -> Int {
        switch self.queueKind(job) {
        case .userSingle:
            return 0
        case .userBatch:
            return 1
        case .prefetch:
            return 2
        case .bulk:
            return 3
        }
    }

    /// Schedules one later sweep for the jobs a sweep left after `parksPerPump` parks (C2).
    private func scheduleSpaceSweepFollowUp(_ sweep: SpaceSweep) {
        let owed = self.state.spaceSweepFollowUp
        self.state.spaceSweepFollowUp = sweep.merged(with: owed)
        guard owed == nil else {
            return
        }
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the sweep re-reads every parked job.
            await engine.spaceSweepFollowUp()
        }
        if spawned == nil {
            self.state.spaceSweepFollowUp = nil
        }
    }

    /// Test seam: the next space sweep follow-ups keep their sweep owed until `releaseSpaceSweepFollowUps()`.
    func holdSpaceSweepFollowUps() {
        self.state.spaceSweepFollowUpsHeld = true
    }

    /// Test seam: lets a held follow-up sweep run in this turn, or disarms a hold nothing reached.
    func releaseSpaceSweepFollowUps() {
        self.state.spaceSweepFollowUpsHeld = false
        guard self.state.spaceSweepFollowUpWaiting else {
            return
        }
        self.state.spaceSweepFollowUpWaiting = false
        self.spaceSweepFollowUp()
    }

    /// The scheduled follow-up sweep, then the run's settling check: while the sweep was owed, a run's claim parked
    /// `insufficientSpace` counted as working (`checkRunSettled`), and a sweep that neither parks nor re-queues checks
    /// nothing itself (close-out cycle 17, F-37).
    private func spaceSweepFollowUp() {
        if self.state.spaceSweepFollowUpsHeld {
            // Test seam: the sweep stays owed (`spaceSweepFollowUp`) until the release runs it; a sweep owed meanwhile
            // merges into it without a second task (`scheduleSpaceSweepFollowUp`).
            self.state.spaceSweepFollowUpWaiting = true
            self.notifyObservers()
            return
        }
        guard let sweep = self.state.spaceSweepFollowUp else {
            return
        }
        self.state.spaceSweepFollowUp = nil
        guard self.isRunning else {
            return
        }
        self.sweepSpaceParked(sweep, arriving: false)
        self.checkRunSettled()
    }

    // MARK: Diagnostics

    /// Appends to the ring of recent errors (R-OBS-3): values only, never a URL, header or key (R-SEC-1).
    func record(_ id: AssetID?, _ failureClass: FailureClass, _ detail: String) {
        self.state.recentErrors.append(DiagnosticError(at: self.environment.time.now(), id: id, failureClass: failureClass, detail: detail))
        let overflow = self.state.recentErrors.count - EngineDiagnostics.recentErrorCapacity
        if overflow > 0 {
            self.state.recentErrors.removeFirst(overflow)
        }
        // The line carries the class and the hashed identifier only: error descriptions can name identifiers, so the
        // detail stays in the diagnostics ring (R-OBS-1, R-SEC-1).
        let label = String(describing: failureClass)
        let hashedID = id.map(AssetLog.hashed) ?? "-"
        self.log.log(.sync, .error, "failure \(label) \(hashedID)")
    }

    /// Takes the manifest the store applied as the engine's copy. The newest manifest seen stays the newest one fetched
    /// (sequence > 0) once there is one: an applied manifest never comes from a later fetch (a point admission, an
    /// `ensureAvailable` apply or a store re-read lands while a run holds a fetched, unapplied manifest), so replacing it
    /// would drop ids only that fetch lists from the S1-13 checks.
    func adoptApplied(_ manifest: ValidatedManifest, etag: ETag?) {
        self.state.copySerial &+= 1
        // The owed re-routes record the copy this replaces, before it changes (`layerOwedReroutes`).
        self.layerOwedReroutes()
        self.state.applied = manifest
        self.state.appliedETag = etag
        if (self.state.newest?.sequence ?? 0) == 0 {
            self.state.newest = (manifest, 0)
        }
        // Members registered while the copy did not list them are claimed once it does (L5-R1).
        self.claimNewlyListed()
    }
}
