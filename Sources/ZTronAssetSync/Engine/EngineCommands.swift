import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// How many bytes deep verification may hash per second of maintenance budget: the byte budget of a slice is derived
/// from the time budget, so a slice stops at its budget even when hashing is faster than the clock moves (R-SYN-16).
enum MaintenanceBudget {
    /// 256 MiB/s (the P-6 floor's order of magnitude).
    static let verificationBytesPerSecond: Double = 256 * 1_024 * 1_024

    /// The byte budget of a slice of `timeBudget` seconds (at least 1 byte).
    static func bytes(for timeBudget: TimeInterval) -> Int64 {
        guard timeBudget.isFinite, timeBudget > 0 else {
            return timeBudget == .infinity ? Int64.max : 1
        }
        let bytes = timeBudget * MaintenanceBudget.verificationBytesPerSecond
        return bytes >= Double(Int64.max) ? Int64.max : max(1, Int64(bytes))
    }
}

extension SyncEngine {
    // MARK: resolve (R-SYN-4, H-3)

    /// One asset at `lane`: the store's current location, an adopted legacy file, or a joined (or new) job; an unknown
    /// id is point-admitted from a fresh manifest (sync.md §6.5).
    func performAwaitAsset(_ id: AssetID, lane: AssetPriority) async -> Result<AssetLocation, AssetError> {
        if Task.isCancelled {
            return .failure(.cancelled)
        }
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // From the first read to the registration, a binding the engine learns (a commit of this id) is kept, so the
        // registration below never creates a job for an asset committed meanwhile (L4-R5).
        self.state.presenceReaders += 1
        let mark = self.state.copySerial
        let serial = self.state.ledgerForgets
        let view: StorePlanningView
        do {
            defer {
                self.state.presenceReaders -= 1
            }
            // REENTRANCY: RE-S36 — the lifecycle; a `nil` location falls through to the job path, which re-reads the record.
            let present = await self.store.location(for: id, extensions: [], recordingAccess: true)
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            if let present {
                self.state.metrics.resolveHits += 1
                return .success(present)
            }
            if self.state.migration.pending {
                do {
                    // REENTRANCY: RE-S36 — the lifecycle; a `nil` answer falls through to the job path.
                    if let location = try await self.store.adoptLegacyNow(id) {
                        return .success(location)
                    }
                } catch .cancelled {
                    return .failure(.cancelled)
                } catch {
                    // A legacy file that cannot be adopted is downloaded instead.
                }
                guard self.isRunning else {
                    return .failure(.shutDown)
                }
            }
            do {
                // REENTRANCY: f-5 (proposed) — the lifecycle; the record decides T2 (quarantined: no job) before the join,
                // which is synchronous, and a record present at its content (bound since the location read) is answered
                // from the store.
                view = try await self.store.planningView()
            } catch {
                return .failure(error.assetError)
            }
        }
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        // A store manifest the copy lacks is followed with its announcements, unless the read may predate the copy.
        self.followStoreView(view, readAt: mark)
        self.noteBound(from: view, ids: [id], since: serial)
        if let error = self.heldBackError(view.records[id], entry: view.appliedManifest.entry(for: id)) {
            return .failure(error)
        }
        if let error = self.missingSourceError {
            return .failure(error)
        }
        let token = self.nextToken()
        // REENTRANCY: RE-S25 — nothing: the body registers synchronously; the result arrives by value.
        return await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<AssetLocation, AssetError>, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                guard self.isRunning else {
                    continuation.resume(returning: .failure(.shutDown))
                    return
                }
                if let entry = self.state.applied.entry(for: id) {
                    self.state.waiters[token] = Waiter(asset: id, transfer: entry.transferID, continuation: continuation)
                    if self.isBound(id, to: entry.transferID) {
                        self.answerWaiterFromStore(token, asset: id, lane: lane, transfer: entry.transferID)
                        return
                    }
                    if self.state.jobs[entry.transferID] != nil {
                        self.state.metrics.resolveJoins += 1
                    }
                    self.addInterest(token, asset: id, entry: entry, lane: lane, kind: .waiter)
                    self.pump()
                    return
                }
                let now = self.environment.time.monotonicNow()
                if self.state.newest?.manifest.entry(for: id) != nil {
                    // A newer manifest than the applied one (a run's fetch not applied yet) lists it: never `.notFound`
                    // (sync-1 S1-13); the point admission below answers from the newest manifest seen.
                    self.state.negativeCache.remove(id)
                } else if self.state.negativeCache.contains(id, at: now) {
                    continuation.resume(returning: .failure(.notFound))
                    return
                }
                self.state.unknownWaiters[token] = UnknownWaiter(asset: id, lane: lane, continuation: continuation)
                self.beginManifestFetch()
                self.notifyObservers()
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop withdraws only this token (a no-op once it was resumed).
                await self.withdraw(token)
            }
        }
    }

    /// The error every fetch answers when `start()` could not build the remote source; `nil` when it exists.
    var missingSourceError: AssetError? {
        guard self.state.remote == nil else {
            return nil
        }
        return self.state.remoteError ?? .serverUnavailable(retryAfter: nil)
    }

    /// The stored answer for an asset that must not be fetched now (T2, ADR-032): failed until its entry changes, or
    /// quarantined / in integrity backoff for its current content.
    private func heldBackError(_ record: AssetRecord?, entry: ManifestEntry?) -> AssetError? {
        guard let record, let entry else {
            return nil
        }
        let now = self.environment.time.now()
        switch record.residency {
        case .failed(.notFound):
            return .notFound
        case .failed:
            return .integrityFailure
        case .quarantined(let until) where until > now:
            return .integrityFailure
        default:
            break
        }
        if let next = record.integrity.nextEligibleAt, next > now, record.integrity.failedIdentity == entry.contentIdentity, record.referencedBlob == nil {
            return .integrityFailure
        }
        return nil
    }

    /// A caller's cancellation (H-3): withdraws exactly its token. A waiter's one interest is in the job it names
    /// (`Waiter.transfer`, which every reroute moves with it; the model test checks both directions after every
    /// operation), so only that job is touched: a sorted pass over every job held the actor about 6 ms at 10,000 queued
    /// prefetch members (review of close-out cycle 9, PROBE-C9R-1, C2).
    ///
    /// Behind the follow barrier the caller is answered at once (R-SYN-4, R-SYN-10), and only the engine's removal of
    /// the interest waits (`removeInterest`, S3-R14 item 3): the record stays, without its continuation, so it follows
    /// the interest's re-routes and joins until the drain removes both (`replayRemoval`), and no later answer reaches the
    /// caller twice.
    func withdraw(_ token: InterestToken) {
        if let waiter = self.state.waiters[token], waiter.continuation != nil {
            waiter.continuation?.resume(returning: .failure(.cancelled))
            if self.defersToFollow, !waiter.fromStore {
                self.state.waiters[token]?.continuation = nil
                self.deferToFollow(.removal(token, waiter.transfer))
                self.notifyObservers()
            } else {
                self.state.waiters[token] = nil
                self.removeInterest(token, from: waiter.transfer)
                self.pump()
            }
        } else if let waiter = self.state.unknownWaiters.removeValue(forKey: token) {
            waiter.continuation.resume(returning: .failure(.cancelled))
        }
        self.reconcileIdle()
    }

    // MARK: Groups (R-CAR-3, R-CAR-4)

    /// Registers a prefetch handle's group synchronously; its members join in one owned task that skips assets
    /// already present (sync.md §6.3).
    func performRegisterGroup(_ ids: [AssetID], lane: AssetPriority) -> Result<InterestToken, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        if case .degraded(let reason) = self.state.lifecycle {
            return .failure(.storageUnavailable(reason))
        }
        let (token, members) = self.recordGroup(ids, lane: lane)
        self.spawnJoin(token, members: members, lane: lane)
        self.notifyObservers()
        return .success(token)
    }

    /// The registering turn's bookkeeping: a token, the group, whose members are `ids` de-duplicated and sorted (the
    /// order its join reaches them in), and a pending claim for every member (orchestrator ruling L5-R1): from this turn
    /// until the group's join reaches a member or the group is released, no release, waiter withdrawal or caller
    /// cancellation retires the job of the content the member names (`removeInterest`), whether that job exists yet or
    /// not. A member the engine's copy does not list yet is claimed once the copy lists it (`claimNewlyListed`). One
    /// manifest probe and one counter update per member: at SPEC §6's 10,000 members the turn stays within C2
    /// (`docs/adr-drafts/g.md`, L5-R1 figures). Kept apart from the join's spawn (`spawnJoin`) so a test can hold a
    /// registered group's join before its store read, a synchronous `AssetStore` call no test-target type can hold.
    func recordGroup(_ ids: [AssetID], lane: AssetPriority) -> (token: InterestToken, members: [AssetID]) {
        let token = self.nextToken()
        var group = Group(kind: .prefetch, lane: lane)
        group.members = Array(Set(ids)).sorted()
        group.claimed.reserveCapacity(group.members.count)
        let applied = self.state.applied
        // The table is taken out of the state while it is counted, so it is updated in place.
        var claims = self.state.claims
        self.state.claims = [:]
        claims.reserveCapacity(claims.count + group.members.count)
        for id in group.members {
            guard let position = applied.position(of: id) else {
                group.claimed.append(nil)
                group.unlistedClaims += 1
                continue
            }
            let key = ClaimKey(applied.entries[position])
            claims[key, default: 0] += 1
            group.claimed.append(key)
        }
        self.state.claims = claims
        self.state.unlistedClaims += group.unlistedClaims
        self.state.groups[token] = group
        return (token, group.members)
    }

    /// Spawns the join of the group `recordGroup` registered under `token` (one owned task, RE-S30).
    func spawnJoin(_ token: InterestToken, members: [AssetID], lane: AssetPriority) {
        self.spawn(.entry) { engine in
            // REENTRANCY: RE-S30 — nothing: the owned task hops onto the actor; `joinGroup` re-validates the group and the lifecycle.
            await engine.joinGroup(token, ids: members, lane: lane)
        }
    }

    /// Adds the group's interests for the members that are not present at their current content, at most
    /// `materializationLimit` members per actor turn, each batch dispatched before the task yields the actor: a
    /// 10,000-member group joined in one turn held the actor about 43 ms (C2; review of close-out cycle 7). After each
    /// yield the batch re-validates what may have changed meanwhile: the lifecycle, the source, the group (a release drops
    /// it), and the engine's manifest copy, whose change makes the view's records stale for the members left, so those
    /// join on a fresh read (this function again). A binding learned meanwhile is checked per member as before (L4-R5).
    ///
    /// The join ends each member's pending claim once it joined or skipped it (`joinMember`), and every claim left when
    /// it gives up early (`endClaims(of:)`), so a claim never outlives the join it waits for (L5-R1).
    private func joinGroup(_ token: InterestToken, ids: [AssetID], lane: AssetPriority) async {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        guard await self.ensureStarted() == nil, self.state.groups[token] != nil else {
            self.endClaims(of: token)
            return
        }
        let view: StorePlanningView
        let mark = self.state.copySerial
        self.state.presenceReaders += 1
        do {
            defer {
                self.state.presenceReaders -= 1
            }
            // REENTRANCY: RE-S30 — the lifecycle and the group still registered (a release drops it); a binding learned
            // while the read is in flight is kept for the joins below (L4-R5); the view's manifest is followed only when
            // the read cannot predate the copy (`followStoreView`).
            view = try await self.store.planningView()
        } catch {
            self.endClaims(of: token)
            return
        }
        guard self.isRunning, self.state.groups[token] != nil, self.missingSourceError == nil else {
            self.endClaims(of: token)
            return
        }
        self.followStoreView(view, readAt: mark)
        let copy = self.state.copySerial
        let batch = self.materializationLimit
        var next = 0
        while next < ids.count {
            if next > 0 {
                // REENTRANCY: f-14 (proposed) — the lifecycle, the source, the group still registered and the engine's
                // copy, re-checked below; a changed copy sends the members left through a fresh read.
                await Task.yield()
                guard self.isRunning, self.state.groups[token] != nil, self.missingSourceError == nil else {
                    self.endClaims(of: token)
                    return
                }
                guard self.state.copySerial == copy else {
                    // REENTRANCY: f-14 (proposed) — as above: the call re-reads the store and re-validates everything.
                    await self.joinGroup(token, ids: Array(ids[next...]), lane: lane)
                    return
                }
            }
            let end = min(next + batch, ids.count)
            for id in ids[next..<end] {
                self.joinMember(token, id: id, record: view.records[id], lane: lane)
            }
            next = end
            self.pump()
        }
    }

    /// Joins one prefetch member unless it is gone from the manifest, present at its current content, bound to it since
    /// the view was read (L4-R5), or held back (T2). Its pending claim ends afterwards, once its interest, if any, is
    /// in place (L5-R1).
    ///
    /// Behind the follow barrier the claim's end waits behind the member's join (`EventAfterFollow.endClaim`): it may
    /// retire a job only the claim kept, which a visit-first engine retired, or kept for the join, after the visits.
    private func joinMember(_ token: InterestToken, id: AssetID, record: AssetRecord?, lane: AssetPriority) {
        defer {
            if self.defersToFollow {
                self.deferToFollow(.endClaim(token, member: id))
            } else {
                self.endClaim(token, member: id)
            }
        }
        guard let entry = self.state.applied.entry(for: id) else {
            return
        }
        if record?.referencedBlob != nil, record?.isStale == false {
            return
        }
        if self.isBound(id, to: entry.transferID) {
            // Committed since the view was read (L4-R5).
            return
        }
        if self.heldBackError(record, entry: entry) != nil {
            return
        }
        self.state.groups[token]?.pending[id] = entry.transferID
        self.state.groups[token]?.joined.append(id)
        self.addInterest(token, asset: id, entry: entry, lane: lane, kind: .prefetch)
    }

    /// Releases a group; unknown tokens are ignored (idempotent, sync-1 S1-05). The group leaves `groups` at once, so
    /// nothing joins it again. Its pending claims end with it (L5-R1), before its members' interests leave, so a job only
    /// this group claimed and wanted retires. A group with more pending members and claims than `releasesPerTurn` loses
    /// the interests of its members in flight in this turn, which frees their slots, and the rest at most
    /// `releasesPerTurn` per actor turn, its claims first, then its members in the order they joined
    /// (`continueReleases`); a job only released groups want never starts meanwhile (`gate`). Removing the 10,000
    /// interests of a prefetch handle in one turn, after sorting their transfers, held the engine's actor about 15 ms
    /// (review of close-out cycle 8, C2).
    ///
    /// Behind the follow barrier the release waits (`EventAfterFollow.release`, S3-R14 item 3): it is a request, so a
    /// visit-first engine released the group after the visits and the events before it; the group stays registered
    /// until the drain, where the joins that arrived before the release are made and then removed with it. An
    /// `ensureAvailable` caller waiting on the group is answered at once.
    func performReleaseGroup(_ token: InterestToken) {
        if self.defersToFollow, self.state.groups[token] != nil {
            let continuation = self.state.groups[token]?.continuation
            self.state.groups[token]?.continuation = nil
            continuation?.resume(returning: false)
            self.deferToFollow(.release(token, entry: false))
            self.notifyObservers()
            return
        }
        guard let group = self.state.groups.removeValue(forKey: token) else {
            return
        }
        group.continuation?.resume(returning: false)
        let claims = group.claimed[group.claimCursor...]
        self.state.unlistedClaims -= group.unlistedClaims
        if group.pending.count + claims.count <= Self.releasesPerTurn {
            for claim in claims {
                self.dropClaim(claim)
            }
            for transfer in Set(group.pending.values).sorted() {
                self.removeInterest(token, from: transfer)
            }
        } else {
            for transfer in self.state.inFlight.sorted() where self.state.jobs[transfer]?.interests[token] != nil {
                self.removeInterest(token, from: transfer)
            }
            // Claims a large give-up of the group's join left for later turns (`endClaims(of:)`) are dropped first.
            let leftover = self.state.releasing[token]?.claims ?? []
            self.state.releasing[token] = Release(members: group.joined[...], pending: group.pending, claims: leftover + claims)
            self.continueReleases()
        }
        self.pump()
        self.reconcileIdle()
    }

    /// The members of released groups whose interests one actor turn removes at most: a removal costs about 8 to 9 µs in
    /// release (the member's transfer, the job's retirement with its queue entry and indexes), so a turn of 512 stays
    /// near 4 to 5 ms at SPEC §6's 10,000, under C2's 10 ms (re-measured in Stage 3, S3-B-084: `handleReleaseTurns`'s
    /// longest actor wait 4.1 to 4.8 ms; WP-G's probe 4.3 to 4.6 ms per 512-member turn).
    static let releasesPerTurn = 512

    /// Removes released groups' pending claims and then their interests, in token order and each group's member and
    /// join order, at most `releasesPerTurn` claims and members per turn; a later turn is owed the rest (`releasing`).
    /// `true` when nothing is left to release.
    @discardableResult
    private func continueReleases() -> Bool {
        var budget = Self.releasesPerTurn
        for token in self.state.releasing.keys.sorted() where budget > 0 {
            guard var release = self.state.releasing[token] else {
                continue
            }
            while budget > 0, let claim = release.claims.popFirst() {
                budget -= 1
                self.dropClaim(claim)
            }
            while budget > 0, let member = release.members.popFirst() {
                budget -= 1
                // A member that shares its content with an earlier one, or whose interest ended meanwhile, is a no-op.
                if let transfer = release.pending[member] {
                    self.removeInterest(token, from: transfer)
                }
            }
            self.state.releasing[token] = release.members.isEmpty && release.claims.isEmpty ? nil : release
        }
        guard !self.state.releasing.isEmpty else {
            // No release is left: an entry a scan set aside whose job is still queued (none, unless an interest of a
            // released group outlived its release) goes back to its queue.
            var queues = self.state.queues
            self.state.queues = LaneQueues()
            queues.restoreAside { self.isValid($0) }
            self.state.queues = queues
            return true
        }
        guard !self.state.releaseFollowUpScheduled else {
            return false
        }
        self.state.releaseFollowUpScheduled = true
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; `continueReleases` re-reads `releasing`.
            await engine.releaseFollowUp()
        }
        if spawned == nil {
            self.state.releaseFollowUpScheduled = false
        }
        return false
    }

    /// The scheduled continuation of `continueReleases`. The members it reaches wait in a queue or are parked (those in
    /// flight left in the release's own turn, and no job only released groups want starts), so it frees no slot and
    /// no room: the pump and the idle check follow once the last member left. It continues in any state but shutdown:
    /// a group released before the engine runs leaves claims to drop (L5-R1), and a release left for later would stay
    /// for good.
    private func releaseFollowUp() {
        if self.state.releaseFollowUpsHeld {
            // Test seam: the remaining members keep their interests and the turn stays scheduled until it is resumed.
            self.state.releaseFollowUpWaiting = true
            self.notifyObservers()
            return
        }
        self.state.releaseFollowUpScheduled = false
        guard !self.isShuttingDown else {
            return
        }
        if self.defersToFollow {
            // Behind the follow barrier the turn's claim ends and removals wait as the release's own (S3-R14 item 3).
            self.deferToFollow(.continueReleases)
            self.notifyObservers()
            return
        }
        self.resumeReleases()
    }

    /// One release turn (`continueReleases`), then the pump and the idle check once the last member left.
    func resumeReleases() {
        guard self.continueReleases() else {
            return
        }
        self.pump()
        self.reconcileIdle()
    }

    /// Test seam: the next release follow-up keeps the members it has not reached until `resumeReleaseFollowUps()`, so a
    /// test reads the engine while a release is part-way across other turns (a follow's, a drain's), which no
    /// production path can order (Stage 3 close-out cycle 10: the drain's `.reinstate` replay).
    func holdReleaseFollowUps() {
        self.state.releaseFollowUpsHeld = true
    }

    /// Test seam: lets a held release follow-up run in this turn, or disarms a hold nothing reached.
    func resumeReleaseFollowUps() {
        self.state.releaseFollowUpsHeld = false
        guard self.state.releaseFollowUpWaiting else {
            return
        }
        self.state.releaseFollowUpWaiting = false
        self.releaseFollowUp()
    }

    // MARK: Pending claims (L5-R1, CCR-G2)

    /// The group's join reached `id`, its next member in order, and joined or skipped it: the member's claim ends.
    func endClaim(_ token: InterestToken, member id: AssetID) {
        guard let group = self.state.groups[token], group.claimCursor < group.claimed.count, group.members[group.claimCursor] == id else {
            return
        }
        let claim = group.claimed[group.claimCursor]
        self.state.groups[token]?.claimCursor += 1
        if claim == nil {
            self.state.groups[token]?.unlistedClaims -= 1
            self.state.unlistedClaims -= 1
        }
        self.dropClaim(claim)
    }

    /// The group's join gave up before reaching every member (start failed, the store read failed, the source is
    /// missing, shutdown began): every claim it still holds ends, so no claim waits for a join that will not come.
    ///
    /// More than `releasesPerTurn` claims end the way a large release's do (orchestrator ruling L5-R15, C2): at most that
    /// many in this turn and the rest in the release follow-up's turns (`releasing`, `continueReleases`), so a give-up
    /// retires at most `releasesPerTurn` jobs that claims alone kept in one turn, whatever the group's size; a later
    /// release of the group drops what is left first. A degraded engine cannot spawn that follow-up, and its start failed
    /// before any job existed, so no claim drop can retire one there: it drops them all in this turn (one table update
    /// each). Internal so a test can give a registered group's claims up in one turn.
    ///
    /// Behind the follow barrier the claims' end waits as a claim's end does (`EventAfterFollow.endClaims`).
    func endClaims(of token: InterestToken) {
        guard let group = self.state.groups[token], group.claimCursor < group.claimed.count else {
            return
        }
        if self.defersToFollow {
            self.deferToFollow(.endClaims(token))
            self.notifyObservers()
            return
        }
        let claims = group.claimed[group.claimCursor...]
        self.state.groups[token]?.claimCursor = group.claimed.count
        self.state.groups[token]?.unlistedClaims = 0
        self.state.unlistedClaims -= group.unlistedClaims
        var degraded = false
        if case .degraded = self.state.lifecycle {
            degraded = true
        }
        if claims.count > Self.releasesPerTurn, !degraded {
            // No release of this registered group exists: `performReleaseGroup` removes the group, and a join gives up once.
            self.state.releasing[token] = Release(members: [], pending: [:], claims: claims)
            self.continueReleases()
        } else {
            for claim in claims {
                self.dropClaim(claim)
            }
        }
        if self.isRunning {
            self.pump()
            self.reconcileIdle()
        }
    }

    /// Uncounts one claim of a content; a job the claims alone kept (`claimHeld`: no interest, and now no claim left)
    /// retires in this turn. A claim that names no content counts only toward `unlistedClaims`, which its caller adjusts.
    private func dropClaim(_ claim: ClaimKey?) {
        guard let key = claim, let count = self.state.claims[key] else {
            return
        }
        guard count == 1 else {
            self.state.claims[key] = count - 1
            return
        }
        self.state.claims[key] = nil
        if let transfer = self.state.claimHeld.removeValue(forKey: key), self.state.jobs[transfer]?.interests.isEmpty == true {
            self.retire(transfer)
        }
    }

    /// Claims the content of registered groups' pending members that the engine's copy did not list when they were
    /// claimed and lists now (L5-R1): a group registered before `start()` claims its members' content when the launch
    /// adopts the store's manifest, before any join runs. Called whenever the copy changes (`adoptApplied`); a pass over
    /// those members only, and nothing while there are none.
    func claimNewlyListed() {
        guard self.state.unlistedClaims > 0 else {
            return
        }
        let applied = self.state.applied
        // The table is taken out of the state while it is counted, so it is updated in place.
        var claims = self.state.claims
        self.state.claims = [:]
        for token in self.state.groups.keys.sorted() where (self.state.groups[token]?.unlistedClaims ?? 0) > 0 {
            guard let group = self.state.groups[token] else {
                continue
            }
            var claimed = group.claimed
            // Taken out of the group while it is updated, so the array is not copied.
            self.state.groups[token]?.claimed = []
            var listed = 0
            for index in group.claimCursor..<claimed.count where claimed[index] == nil {
                guard let position = applied.position(of: group.members[index]) else {
                    continue
                }
                let key = ClaimKey(applied.entries[position])
                claimed[index] = key
                claims[key, default: 0] += 1
                listed += 1
            }
            self.state.groups[token]?.claimed = claimed
            self.state.groups[token]?.unlistedClaims -= listed
            self.state.unlistedClaims -= listed
        }
        self.state.claims = claims
    }

    // MARK: Availability (R-SYN-10)

    /// Counts from the store: no network, no I/O.
    func performAvailability(scope: AssetScope) async -> Result<AvailabilityReport, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S38 — the lifecycle; the answer is the store's snapshot.
        let report = await self.store.availability(of: scope)
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        return .success(report)
    }

    /// Fetch-first, then everything missing in scope at user-initiated priority (sync.md §12.2), in an owned task; the
    /// caller's cancellation withdraws the group and throws `.cancelled`.
    func performEnsureAvailable(scope: AssetScope) async -> Result<AvailabilityReport, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: true) { engine, token in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            .availability(await engine.ensureTask(token, scope: scope))
        }
        switch result {
        case .availability(let report):
            return report
        case .done(.failure(let error)), .purge(.failure(let error)), .maintenance(.failure(let error)):
            return .failure(error)
        default:
            return .failure(.cancelled)
        }
    }

    /// The `ensureAvailable` task.
    private func ensureTask(_ token: InterestToken, scope: AssetScope) async -> Result<AvailabilityReport, AssetError> {
        if let error = self.missingSourceError {
            return .failure(error)
        }
        // Until its group exists (which then keeps them while it materialises), bindings the engine learns after the
        // plan's view are kept, so no member is downloaded again (L4-R5).
        self.state.presenceReaders += 1
        var reading = true
        defer {
            if reading {
                self.state.presenceReaders -= 1
            }
        }
        // REENTRANCY: RE-S04 — the lifecycle; the outcome is that of the shared fetch.
        let outcome = await self.fetchManifest(token, deadline: false)
        guard self.isRunning, !Task.isCancelled else {
            return .failure(self.isShuttingDown ? .shutDown : .cancelled)
        }
        var manifest: ValidatedManifest?
        var etag = self.state.appliedETag
        var fresh = false
        switch outcome {
        case .fetched(let fetched, let tag, _):
            manifest = fetched
            etag = tag
            fresh = true
        case .notModified:
            fresh = true
        case .failed, .invalid, .circuitOpen, .throttled, .timedOut:
            // Unreachable: the applied manifest decides; a complete scope is answered, otherwise the mapped error.
            // REENTRANCY: RE-S20 — the lifecycle; the report is the store's snapshot.
            let report = await self.store.availability(of: scope)
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            if report.isComplete {
                return .success(report)
            }
            return .failure(self.unreachableError(outcome))
        case .cancelled:
            return .failure(.cancelled)
        case .shutDown:
            return .failure(.shutDown)
        }
        let space: FreeSpace
        let measured: FreeSpace
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S06 — the lifecycle and the caller's cancellation; the measured read became the ledger's
            // base in the turn it returned (L4-R7, also behind the follow barrier: S3-R11 R1), and parked jobs are
            // re-evaluated against it there, or, behind the barrier, by the sweep's follow-up once the follow ends (F-28).
            measured = try await self.readFreeSpace()
            if self.isRunning {
                self.reconsiderSpaceBlocked()
            }
            // User work plans against the space the OS keeps for important usage (sync-2 S2-23).
            space = FreeSpace(
                volumeImportant: measured.volumeImportant,
                volumeOpportunistic: measured.volumeImportant,
                usedBytes: measured.usedBytes,
                pendingReclaim: measured.pendingReclaim,
                budgetBytes: measured.budgetBytes,
                reserveBytes: measured.reserveBytes
            )
            // REENTRANCY: RE-S37 — the lifecycle; a snapshot `apply` re-validates.
            view = try await self.store.planningView()
        } catch {
            return .failure(error.assetError)
        }
        guard self.isRunning, !Task.isCancelled else {
            return .failure(self.isShuttingDown ? .shutDown : .cancelled)
        }
        // The headroom ledger keeps the measured reading (`readFreeSpace`): the important-for-opportunistic copy is this
        // ensure's own plan and space decision, never the base other lanes are admitted against (S2-23, L4-R6).
        let target = manifest ?? view.appliedManifest
        let policy = PlanningPolicy(storage: self.configuration.storage, includeOnDemand: scope.isExplicit, now: self.environment.time.now())
        // REENTRANCY: RE-S07 — the lifecycle; apply diffs against current state anyway.
        var plan = await SyncEngine.planOffActor(self.planner, manifest: target, view: view, scope: scope, policy: policy, space: space)
        var eviction: EvictionPlan?
        if case .needsEviction(let bytes) = plan.space {
            // REENTRANCY: RE-S37 — the lifecycle; a dry run `apply` re-validates per victim.
            eviction = await self.store.evictionPlan(toFree: bytes, protecting: Set(plan.fetches.map(\.id)))
            if eviction == nil {
                var fallback = policy
                fallback.evictionPermitted = false
                // REENTRANCY: RE-S07 — as above.
                plan = await SyncEngine.planOffActor(self.planner, manifest: target, view: view, scope: scope, policy: fallback, space: space)
            }
        }
        guard self.isRunning, !Task.isCancelled else {
            return .failure(self.isShuttingDown ? .shutDown : .cancelled)
        }
        if case .insufficient(let required, let available) = plan.space {
            return .failure(.insufficientSpace(required: required, available: available))
        }
        if manifest != nil || eviction != nil {
            // REENTRANCY: RE-S09 — the lifecycle; the callee has followed a committed apply (removal events, T21, T22)
            // even when this caller has gone, as after a run's apply.
            if case .failure(let error) = await self.applyAndFollow(target, etag: etag, eviction: eviction) {
                return .failure(error.assetError)
            }
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            // REENTRANCY: RE-S40 — the lifecycle; the heap's store entry is replaced (apply committed).
            await self.refreshStoreDeadline()
            guard self.isRunning, !Task.isCancelled else {
                return .failure(self.isShuttingDown ? .shutDown : .cancelled)
            }
        }
        // The fetches become members (and jobs) a pipeline's worth at a time (S1-15): registering a scope of 100,000
        // missing entries at once held the actor about 0.4 s (C2).
        var group = Group(kind: .ensure, lane: .userInitiated)
        group.fetches = plan.fetches
        self.state.groups[token] = group
        self.state.presenceReaders -= 1
        reading = false
        self.pump()
        if !(self.state.groups[token]?.isSettled ?? true) {
            // REENTRANCY: RE-S20 — the lifecycle and the group still registered; the report is recomputed from the
            // store afterwards.
            let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if self.state.groups[token]?.isSettled ?? true {
                    continuation.resume(returning: self.state.groups[token] != nil)
                } else {
                    self.state.groups[token]?.continuation = continuation
                }
            }
            guard completed, self.isRunning else {
                self.performReleaseGroup(token)
                return .failure(self.isShuttingDown ? .shutDown : .cancelled)
            }
        }
        let spaceFailure = self.state.groups[token]?.spaceFailure
        self.performReleaseGroup(token)
        // REENTRANCY: RE-S20 — the lifecycle; the report is recomputed from the store.
        var report = await self.store.availability(of: scope)
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        report.manifestFresh = fresh
        if let spaceFailure, !report.isComplete {
            // A member failed for lack of space at dispatch (the plan fitted, the headroom beside the bytes in flight did
            // not) and the scope is still incomplete: the caller gets the typed shortage, as from the plan (R-SYN-11).
            return .failure(spaceFailure)
        }
        return .success(report)
    }

    /// The error of an unreachable manifest for `ensureAvailable`. A fetch the origin's throttle refused reports the time
    /// left until the throttle ends, as ARCHITECTURE §7.6 maps a 429 and as the unknown-id `resolve` answers the same
    /// refusal (close-out cycle 17, F-37). The end is read in the answering turn through the origin's
    /// (`throttleEnd(after:)`): the outcome's end was read in the fetch's turn, and a transfer's 429 may have extended the
    /// throttle in the awaits since (close-out cycle 18, F-38).
    private func unreachableError(_ outcome: ManifestOutcome) -> AssetError {
        switch outcome {
        case .failed(let error):
            return error.assetError(now: self.environment.time.now())
        case .circuitOpen(let cause):
            return cause == .authentication ? .authRejected(.confirmed) : .serverUnavailable(retryAfter: nil)
        case .throttled(let until):
            return self.throttledError(after: until)
        default:
            return .serverUnavailable(retryAfter: nil)
        }
    }

    // MARK: Refresh (R-SYN-9)

    /// Whether a launch sync is due now.
    func performIsSyncDue() async -> Result<Bool, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        do {
            // REENTRANCY: RE-S38 — the lifecycle; the answer is the store's snapshot.
            let view = try await self.store.planningView()
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            return .success(RefreshDecision.isSyncDue(
                policy: self.configuration.refresh,
                stamp: view.stamp,
                syncDueFlag: view.syncDue,
                appVersion: self.state.launch?.appVersion ?? "",
                now: self.environment.time.now(),
                syncedThisLaunch: self.state.syncedThisLaunch
            ))
        } catch {
            return .failure(error.assetError)
        }
    }

    /// The stamp's completion time.
    func performLastSyncedAt() async -> Result<Date?, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        do {
            // REENTRANCY: RE-S38 — the lifecycle; the answer is the store's snapshot.
            let view = try await self.store.planningView()
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            return .success(view.stamp?.completedAt)
        } catch {
            return .failure(error.assetError)
        }
    }

    // MARK: Scope, pins, leases (ADR-027, ADR-044)

    /// Replaces the retention scope and pushes it to the store in an owned task (RE-S33); starts no run.
    func performSetRetentionScope(_ scope: AssetScope) async -> Result<Void, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        self.state.retentionScope = scope
        self.state.retentionSequence += 1
        let sequence = self.state.retentionSequence
        guard self.isRunning else {
            // `start()` pushes the scope in force after `open()`.
            return .success(())
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: false) { engine, _ in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            await engine.pushRetentionScope(sequence)
            return .done(.success(()))
        }
        if case .done(let outcome) = result {
            return outcome
        }
        return .failure(.cancelled)
    }

    private func pushRetentionScope(_ sequence: UInt64) async {
        guard self.state.retentionSequence == sequence else {
            return
        }
        // REENTRANCY: RE-S33 — the lifecycle; a scope set meanwhile has a newer sequence and pushes itself.
        await self.store.setRetentionScope(self.state.retentionScope)
    }

    /// Pins or unpins through the store in an owned task (ADR-039).
    func performSetPinned(_ ids: Set<AssetID>, pinned: Bool) async -> Result<Void, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: false) { engine, _ in
            do throws(StoreError) {
                // REENTRANCY: RE-S30 — the lifecycle.
                try await engine.store.setPinned(ids, pinned: pinned)
                // REENTRANCY: RE-S40 — the lifecycle.
                await engine.refreshStoreDeadline()
                return .done(.success(()))
            } catch {
                return .done(.failure(error.assetError))
            }
        }
        if case .done(let outcome) = result {
            return outcome
        }
        return .failure(.cancelled)
    }

    /// A lease, resolving first when the asset is absent (R-CAR-8); one acquired after shutdown began is released at
    /// once (RE-S30).
    func performAcquireLease(_ id: AssetID) async -> Result<AssetLease, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        for attempt in 0..<2 {
            do {
                // REENTRANCY: RE-S36 — the lifecycle; a lease acquired after shutdown began is released at once.
                let lease = try await self.store.acquireLease(id)
                guard self.isRunning else {
                    // REENTRANCY: RE-S30 — terminal.
                    _ = await self.store.releaseLease(lease)
                    return .failure(.shutDown)
                }
                return .success(lease)
            } catch .notPresent where attempt == 0 {
                // REENTRANCY: RE-S36 — the lifecycle; the lease is retried once after the resolve.
                switch await self.performAwaitAsset(id, lane: .userInitiated) {
                case .success:
                    continue
                case .failure(let error):
                    return .failure(error)
                }
            } catch .unknownAsset(_) where attempt == 0 {
                // REENTRANCY: RE-S36 — as above.
                switch await self.performAwaitAsset(id, lane: .userInitiated) {
                case .success:
                    continue
                case .failure(let error):
                    return .failure(error)
                }
            } catch {
                return .failure(self.isShuttingDown ? .shutDown : error.assetError)
            }
        }
        return .failure(.notFound)
    }

    /// Releases a lease and re-arms the alarm with the store's new deadline; a no-op after shutdown.
    func performReleaseLease(_ lease: AssetLease) {
        guard self.isRunning else {
            return
        }
        self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle.
            await engine.releaseLease(lease)
        }
    }

    /// The store's release, whose answer is the store's new deadline, applied against the updates that landed while it
    /// was in flight (`applyStoreDeadline`, orchestrator ruling L5K-R16).
    private func releaseLease(_ lease: AssetLease) async {
        let since = self.state.storeDeadlineUpdates
        // REENTRANCY: RE-S40 — the lifecycle; the heap's store entry is replaced by the newest deadline and a newer one is
        // never dropped.
        let deadline = await self.store.releaseLease(lease)
        guard self.isRunning else {
            return
        }
        self.applyStoreDeadline(deadline, readSince: since)
    }

    // MARK: Purge (R-CLN-6, RE-S24)

    /// Bumps the purge epoch before any await of the purge, ends the active run with `failed(.cancelled)`, withdraws
    /// non-user interests on purged ids (user waiters keep theirs and re-queue), then purges in an owned task.
    func performPurge(_ request: PurgeRequest) async -> Result<PurgeResult, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        self.state.purgeEpoch += 1
        // The store clears the stamp before its first await of the purge (R-CLN-6).
        self.state.lastStamp = nil
        // A purge unbinds what it removes: nothing the engine saw bound before it is assumed present (L4-R5).
        self.dropBindings()
        self.settleRun(.cancelled)
        if self.defersToFollow {
            // A request: its withdrawals wait for the follow and meet the jobs the visits and earlier events leave
            // (S3-R14 item 3).
            self.deferToFollow(.purge(request))
            self.notifyObservers()
        } else {
            self.withdrawPurged(request)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: true) { engine, _ in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            .purge(await engine.purgeTask(request))
        }
        if case .purge(let outcome) = result {
            return outcome
        }
        if case .done(.failure(let error)) = result {
            return .failure(error)
        }
        return .failure(.cancelled)
    }

    /// Withdraws the non-user interests a purge of `request` removes (user waiters keep theirs and re-queue): a group
    /// stops waiting for the members it no longer has an interest in, a heal of a purged id is forgotten.
    func withdrawPurged(_ request: PurgeRequest) {
        for transfer in self.state.jobs.keys.sorted() {
            guard let job = self.state.jobs[transfer] else {
                continue
            }
            let purged = job.assets.filter { asset in
                guard let entry = self.state.applied.entry(for: asset) else {
                    return true
                }
                switch request {
                case .all:
                    return true
                case .evictable:
                    return entry.policy != .essential
                case .scope(let scope):
                    return scope.contains(entry)
                }
            }
            guard !purged.isEmpty else {
                continue
            }
            for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) where interest.lane < .userInitiated && interest.kind != .waiter {
                let withdrawn = interest.assets.intersection(purged)
                guard !withdrawn.isEmpty else {
                    continue
                }
                // A group no longer waits for what it no longer has an interest in (F-1: member ⇒ interest); a heal of
                // a purged id is forgotten.
                for asset in withdrawn.sorted() {
                    switch interest.kind {
                    case .prefetch, .ensure:
                        self.dropGroupMember(token, asset: asset, from: transfer)
                    case .system:
                        self.state.heals[asset] = nil
                    case .run, .waiter:
                        break
                    }
                }
                if withdrawn.count == interest.assets.count {
                    self.removeInterest(token, from: transfer)
                } else {
                    self.state.jobs[transfer]?.interests[token]?.assets.subtract(withdrawn)
                }
            }
        }
    }

    private func purgeTask(_ request: PurgeRequest) async -> Result<PurgeResult, AssetError> {
        do {
            // REENTRANCY: RE-S24 — `purgeEpoch` was bumped before the await; afterwards the snapshot and the store's
            // deadline are refreshed.
            let result = try await self.store.purge(request)
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            // Bindings learned while the purge ran may be purged too (L4-R5).
            self.dropBindings()
            self.broadcast(.snapshotChanged(generation: self.state.generation))
            // The purge's reaper may have reclaimed what jobs parked for space wait for, outside the alarm's work.
            // REENTRANCY: f-4 (proposed) — nothing: the callee re-validates the lifecycle after its read.
            await self.spaceMayHaveBeenReclaimed()
            // REENTRANCY: RE-S40 — the lifecycle.
            await self.refreshStoreDeadline()
            self.pump()
            return .success(result)
        } catch {
            // A purge that threw may have removed records in memory first (ADR-050), bound meanwhile too (L4-R5).
            self.storeMutationFailed()
            // It may also have reaped before it threw (a grace wait cancelled after a round of reaping).
            // REENTRANCY: f-4 (proposed) — nothing: the callee re-validates the lifecycle after its read.
            await self.spaceMayHaveBeenReclaimed()
            // REENTRANCY: RE-S40 — the lifecycle.
            await self.refreshStoreDeadline()
            return .failure(self.isShuttingDown ? .shutDown : error.assetError)
        }
    }

    // MARK: Maintenance (R-SYN-16, RE-S23)

    /// Staging GC, orphan GC, eviction and deep verification within `timeBudget`, in an owned task whose caller's
    /// cancellation stops it between batches.
    func runMaintenance(timeBudget: TimeInterval) async -> Result<MaintenanceReport, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: true) { engine, _ in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            .maintenance(await engine.maintenanceTask(timeBudget: timeBudget))
        }
        if case .maintenance(let outcome) = result {
            return outcome
        }
        if case .done(.failure(let error)) = result {
            return .failure(error)
        }
        return .failure(.cancelled)
    }

    private func maintenanceTask(timeBudget: TimeInterval) async -> Result<MaintenanceReport, AssetError> {
        let deadline = self.environment.time.monotonicNow().adding(seconds: max(0, timeBudget))
        var report = MaintenanceReport(gcBytes: 0, evictedBytes: 0, verifiedBytes: 0, corruptFound: 0, budgetExhausted: false)
        func expired() -> Bool {
            Task.isCancelled || !self.isRunning || self.environment.time.monotonicNow() >= deadline
        }
        // Eviction and deep verification unbind assets the engine is not told about one by one: a binding seen before or
        // during maintenance is not assumed present afterwards (L4-R5).
        self.dropBindings()
        do {
            var claims = Set(self.state.jobs.keys)
            claims.formUnion(self.state.draining.keys)
            claims.formUnion(self.state.launchResumes.keys)
            // REENTRANCY: RE-S23 — the lifecycle, the deadline and cancellation, checked before every step.
            let staging = try await self.store.collectStaging(keeping: claims)
            report.gcBytes = PlanBuilder.adding(report.gcBytes, staging.bytesFreed)
            if expired() {
                report.budgetExhausted = true
                // REENTRANCY: RE-S40 — nothing: the callee re-reads the store deadline and the lifecycle.
                return await self.finishMaintenance(report)
            }
            // REENTRANCY: RE-S23 — as above.
            let garbage = try await self.store.collectGarbage(until: deadline)
            report.gcBytes = PlanBuilder.adding(report.gcBytes, garbage.bytesFreed)
            if expired() {
                report.budgetExhausted = true
                // REENTRANCY: RE-S40 — nothing: the callee re-reads the store deadline and the lifecycle.
                return await self.finishMaintenance(report)
            }
            // REENTRANCY: RE-S23 — as above.
            let eviction = try await self.store.evictIfNeeded()
            report.evictedBytes = eviction.bytesFreed
            self.dropBindings()
            if expired() {
                report.budgetExhausted = true
                // REENTRANCY: RE-S40 — nothing: the callee re-reads the store deadline and the lifecycle.
                return await self.finishMaintenance(report)
            }
            // REENTRANCY: RE-S23 — as above.
            let verification = try await self.store.verifyIntegrity(byteBudget: MaintenanceBudget.bytes(for: timeBudget), until: deadline)
            report.verifiedBytes = verification.bytesVerified
            report.corruptFound = verification.corrupt.count
            report.budgetExhausted = !verification.completedPass
            if !verification.corrupt.isEmpty {
                // REENTRANCY: RE-S30 — the lifecycle; the quarantined assets are announced and their re-downloads
                // scheduled from the records read as a snapshot (as after `reportUnreadable`).
                await self.quarantined(verification.corrupt, sharing: nil)
            }
            if self.state.migration.deferred, self.state.migration.pending, !expired() {
                self.startMigration()
            }
        } catch .cancelled {
            // The step that threw may have evicted or quarantined in memory first (ADR-050): no binding learned during
            // maintenance is trusted (L4-R5).
            self.storeMutationFailed()
            report.budgetExhausted = true
        } catch {
            // As above.
            self.storeMutationFailed()
            // That step may also have doomed blobs, which leaves a snapshot install due and a reap to schedule
            // (orchestrator ruling L5K-R16).
            // REENTRANCY: RE-S40 — the lifecycle (inside); the heap's store entry is replaced by the newest deadline.
            await self.refreshStoreDeadline()
            return .failure(self.isShuttingDown ? .shutDown : error.assetError)
        }
        // REENTRANCY: RE-S40 — nothing: the callee re-reads the store deadline and the lifecycle.
        return await self.finishMaintenance(report)
    }

    private func finishMaintenance(_ report: MaintenanceReport) async -> Result<MaintenanceReport, AssetError> {
        // REENTRANCY: RE-S40 — the lifecycle.
        await self.refreshStoreDeadline()
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        self.broadcast(.maintenanceFinished(report))
        return .success(report)
    }

    // MARK: Quarantine (R-CLN-8)

    /// Quarantines through the store, then schedules the re-download at the end of the quarantine.
    func performReportUnreadable(_ id: AssetID) async -> Result<Void, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: false) { engine, _ in
            // REENTRANCY: f-12 (proposed) — nothing: a snapshot of who holds the blob now; each holder is re-read from the
            // store's records after the quarantine before it is announced or healed.
            let holders = await engine.blobHolders(of: id)
            do throws(StoreError) {
                // REENTRANCY: RE-S30 — the lifecycle.
                try await engine.store.reportUnreadable(id)
            } catch {
                // The store may have quarantined the blob, and with it every holder, in memory before its commit threw
                // (ADR-050): no binding is trusted (L4-R5).
                // REENTRANCY: RE-S21 — nothing: a synchronous drop on the actor.
                await engine.storeMutationFailed()
                // The quarantine dooms the blob, whose snapshot install and reap the alarm runs (L5K-R16).
                // REENTRANCY: RE-S40 — the lifecycle (inside); the heap's store entry is replaced by the newest deadline.
                await engine.refreshStoreDeadline()
                return .done(.failure(error.assetError))
            }
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            await engine.quarantined([id], sharing: holders)
            return .done(.success(()))
        }
        if case .done(let outcome) = result {
            return outcome
        }
        return .failure(.cancelled)
    }

    /// Announces quarantined assets and schedules their re-downloads. `ids` are the assets the store reported: every
    /// holder of a corrupt blob, for deep verification (`holders` is `nil`). `reportUnreadable` reports only its id, yet
    /// the store quarantines every holder of the blob (R-CLN-8): `holders` are the other assets that referenced it in a
    /// snapshot taken before the quarantine, and each one the store's records show quarantined or failed afterwards is
    /// announced and healed too.
    private func quarantined(_ ids: [AssetID], sharing holders: [AssetID]?) async {
        if holders == nil {
            self.forgetBound(ids)
        } else {
            // The store quarantined holders of the blob the engine knows only from a snapshot (one gained between the
            // snapshot and the quarantine, or every one when the snapshot could not be read, is in no list): no binding
            // is trusted; an attempt asks the store first (L4-R5).
            self.dropBindings()
        }
        for id in ids {
            self.broadcast(.assetRemoved(id, .quarantined))
        }
        // REENTRANCY: RE-S30 — the lifecycle.
        await self.scheduleHeals(ids, sharing: holders ?? [])
        // REENTRANCY: RE-S40 — the lifecycle.
        await self.refreshStoreDeadline()
    }

    /// The other ids whose records reference `id`'s blob in a store snapshot, found off the actor (C2: the scan visits
    /// every record). Empty when the store cannot answer or `id` holds no blob.
    private func blobHolders(of id: AssetID) async -> [AssetID] {
        let view: StorePlanningView
        do {
            // REENTRANCY: f-12 (proposed) — nothing: the records are a snapshot, re-read after the quarantine; the caller's
            // next step re-validates the lifecycle.
            view = try await self.store.planningView()
        } catch {
            return []
        }
        guard let key = view.records[id]?.referencedBlob else {
            return []
        }
        // REENTRANCY: f-12 (proposed) — nothing: a pure scan of the snapshot off the actor (C2).
        return await SyncEngine.holdersOffActor(of: key, besides: id, in: view.records)
    }

    /// The ids of `records` other than `id` that reference blob `key`, sorted: a pure scan, off the actor (C2).
    @concurrent
    nonisolated static func holdersOffActor(of key: BlobKey, besides id: AssetID, in records: [AssetID: AssetRecord]) async -> [AssetID] {
        records.compactMap { $0.key != id && $0.value.referencedBlob == key ? $0.key : nil }.sorted()
    }

    /// Schedules a re-download at the end of each asset's quarantine (read from the store's records); a holder of a
    /// reported blob that the records show quarantined or failed is announced first.
    private func scheduleHeals(_ ids: [AssetID], sharing holders: [AssetID] = []) async {
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S30 — the lifecycle; the records are a snapshot.
            view = try await self.store.planningView()
        } catch {
            return
        }
        guard self.isRunning else {
            return
        }
        var healed = ids
        for holder in holders where !ids.contains(holder) {
            switch view.records[holder]?.residency {
            case .quarantined?, .failed(.unreadable)?:
                self.broadcast(.assetRemoved(holder, .quarantined))
                healed.append(holder)
            default:
                continue
            }
        }
        let wall = self.environment.time.now()
        let now = self.environment.time.monotonicNow()
        for id in healed {
            guard case .quarantined(let until)? = view.records[id]?.residency else {
                continue
            }
            self.scheduleHeal(id, at: now.adding(seconds: max(0, until.timeIntervalSince(wall))))
        }
    }

    // MARK: Reports (R-CLN-9, R-OBS-2, R-OBS-3)

    /// The store's report plus the source's copies (RE-S32).
    func performStorageReport() async -> Result<StorageReport, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S32 — the lifecycle; the two figures are independent snapshots.
        var report = await self.store.storageReport()
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        if let remote = self.state.remote {
            // REENTRANCY: RE-S32 — the lifecycle.
            report.sourceCopyBytes = await remote.sourceCopyBytes()
        }
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        return .success(report)
    }

    /// Engine counters plus the store's.
    func performMetrics() async -> Result<MetricsSnapshot, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S38 — the lifecycle; the store's counters are a snapshot.
        let stored = await self.store.metrics()
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        var metrics = self.state.metrics
        metrics.evictions = stored.evictions
        metrics.evictedBytes = stored.evictedBytes
        metrics.gcBytes = stored.gcBytes
        metrics.integrityFailures += stored.integrityFailures
        return .success(metrics)
    }

    /// Counters, recent errors, launch facts and the store's generation and stamp. A degraded engine, or a store that
    /// cannot answer, still answers, because that is when support needs the error ring most (R-OBS-3, L4-R9): with the
    /// last-known generation (0 if never read) and stamp (`nil` if never read). After shutdown it fails `.shutDown`
    /// (ADR-042); a caller cancelled while start runs gets `.cancelled`.
    func performDiagnostics() async -> Result<EngineDiagnostics, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            guard case .storageUnavailable = error else {
                return .failure(error)
            }
            return .success(self.makeDiagnostics())
        }
        do {
            // REENTRANCY: RE-S38 — the lifecycle; a snapshot, kept as the last-known figures.
            let view = try await self.store.planningView()
            self.state.lastIndexGeneration = view.generation
            self.state.lastStamp = view.stamp
        } catch {
            // The store cannot answer now: the last-known figures stand in.
        }
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        return .success(self.makeDiagnostics())
    }

    /// The diagnostics from the engine's own state and the last-known index figures. The generation is never older
    /// than one the engine already announced (`snapshotChanged` after an apply or a catch-up), even when the store
    /// last answered before those applies.
    private func makeDiagnostics() -> EngineDiagnostics {
        var errors = self.state.recentErrors
        for field in self.state.clampedFields {
            errors.append(DiagnosticError(at: self.environment.time.now(), id: nil, failureClass: .rejected, detail: "clamped \(field)"))
        }
        return EngineDiagnostics(
            introspection: self.currentIntrospection(),
            recentErrors: Array(errors.suffix(EngineDiagnostics.recentErrorCapacity)),
            appVersion: self.state.launch?.appVersion,
            launchEpoch: self.state.launch?.report.launchEpoch,
            indexGeneration: max(self.state.lastIndexGeneration, self.state.generation),
            stamp: self.state.lastStamp,
            retentionScope: self.state.retentionScope
        )
    }

    // MARK: Memory pressure (R-CLN-11, ADR-044)

    /// Starts or stops the one observer; only the newest epoch applies.
    func performObserveMemoryPressure(epoch: UInt64, handler: (@Sendable (MemoryPressureLevel) async -> Void)?) -> Result<Void, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        guard epoch > self.state.pressure.epoch else {
            return .success(())
        }
        self.state.pressure.epoch = epoch
        self.state.pressure.handler = handler
        if handler == nil {
            let task = self.state.pressure.task
            self.state.pressure.task = nil
            self.cancelTask(task)
        } else if self.state.pressure.task == nil, self.environment.memoryPressure != nil {
            self.state.pressure.token += 1
            let token = self.state.pressure.token
            let task = self.spawn(.pressure) { engine in
                // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
                await engine.observePressure(token: token)
            }
            self.state.pressure.task = task
        }
        self.notifyObservers()
        return .success(())
    }

    private func observePressure(token: UInt64) async {
        defer {
            if self.state.pressure.token == token {
                self.state.pressure.task = nil
                self.notifyObservers()
            }
        }
        guard let source = self.environment.memoryPressure else {
            return
        }
        // REENTRANCY: RE-S31 — the observer's token is still the applied one, else it exits.
        let stream = await source.pressureEvents()
        // REENTRANCY: RE-S31 — per element: the token, the lifecycle and a handler still set.
        for await level in stream {
            guard self.state.pressure.token == token, !self.isShuttingDown, let handler = self.state.pressure.handler else {
                return
            }
            // REENTRANCY: RE-S31 — a stop requested from inside the handler ends the loop after it returns.
            await handler(level)
            guard self.state.pressure.token == token, self.state.pressure.handler != nil, !self.isShuttingDown else {
                return
            }
        }
    }

    // MARK: Background events (R-NET-3, RE-S42)

    /// Makes sure the background session exists and returns once the preceding events are staged.
    func performBackgroundEvents(identifier: String) async -> Result<Void, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        if let remote = self.state.remote {
            // REENTRANCY: RE-S42 — the lifecycle.
            await remote.handleBackgroundEvents(identifier: identifier)
        }
        return self.isRunning ? .success(()) : .failure(.shutDown)
    }

    // MARK: Entry joins (ADR-039)

    /// Runs `body` in an engine-owned task joined by the caller: the caller's cancellation withdraws its token (and, when
    /// the work is the caller's alone, cancels the task).
    func joinEntry(stopsWorkOnCancel: Bool, _ body: @escaping @Sendable (SyncEngine, InterestToken) async -> EntryResult) async -> EntryResult {
        let token = self.nextToken()
        // REENTRANCY: RE-S25 — nothing: the body registers and spawns synchronously; the result arrives by value.
        return await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<EntryResult, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .done(.failure(.cancelled)))
                    return
                }
                self.state.entryJoins[token] = continuation
                guard let task = self.spawn(.entry, { engine in
                    // REENTRANCY: RE-S30 — nothing: the entry task's body re-validates the lifecycle after each of its awaits.
                    let result = await body(engine, token)
                    // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
                    await engine.finishEntry(token, result)
                }) else {
                    self.state.entryJoins.removeValue(forKey: token)?.resume(returning: .done(.failure(.shutDown)))
                    return
                }
                self.state.entryTasks[token] = task
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop withdraws only this token.
                await self.withdrawEntry(token, stopWork: stopsWorkOnCancel)
            }
        }
    }

    private func finishEntry(_ token: InterestToken, _ result: EntryResult) {
        self.state.entryTasks[token] = nil
        self.state.entryJoins.removeValue(forKey: token)?.resume(returning: result)
        self.reconcileIdle()
    }

    private func withdrawEntry(_ token: InterestToken, stopWork: Bool) {
        guard let continuation = self.state.entryJoins.removeValue(forKey: token) else {
            return
        }
        continuation.resume(returning: .done(.failure(.cancelled)))
        if stopWork {
            self.cancelTask(self.state.entryTasks[token])
            if self.defersToFollow, self.state.groups[token] != nil {
                // The caller is answered; the group's removal waits for the follow as a release does (S3-R14 item 3).
                let waiting = self.state.groups[token]?.continuation
                self.state.groups[token]?.continuation = nil
                waiting?.resume(returning: false)
                self.deferToFollow(.release(token, entry: true))
                self.notifyObservers()
            } else {
                self.releaseEntryGroup(token)
            }
        }
        self.reconcileIdle()
    }

    /// Removes a withdrawn entry's group (`withdrawEntry`): its claims end and its members' interests leave at once.
    func releaseEntryGroup(_ token: InterestToken) {
        guard let group = self.state.groups.removeValue(forKey: token) else {
            return
        }
        group.continuation?.resume(returning: false)
        // An `ensureAvailable` group holds no claim; every path that removes a group ends its claims (L5-R1).
        self.state.unlistedClaims -= group.unlistedClaims
        for claim in group.claimed[group.claimCursor...] {
            self.dropClaim(claim)
        }
        for transfer in Set(group.pending.values).sorted() {
            self.removeInterest(token, from: transfer)
        }
        self.pump()
    }

    // MARK: Introspection (R-SYN-14, P-14)

    /// The engine's counters.
    func currentIntrospection() -> EngineIntrospection {
        var byState: [JobStateKind: Int] = [:]
        var queued: [AssetPriority: Int] = [:]
        var running = 0
        var preempting = 0
        var interests = 0
        for job in self.state.jobs.values {
            byState[job.state.kind, default: 0] += 1
            interests += job.interests.count
            switch job.state {
            case .queued:
                queued[job.lane, default: 0] += 1
            case .downloading:
                if job.active?.preempting == true {
                    preempting += 1
                } else {
                    running += 1
                }
            default:
                break
            }
        }
        return EngineIntrospection(
            lifecycle: self.state.lifecycle,
            jobsByState: byState,
            queued: queued,
            running: running,
            preempting: preempting,
            waiters: self.state.waiters.count + self.state.unknownWaiters.count,
            interests: interests,
            groups: self.state.groups.count + (self.state.run == nil ? 0 : 1),
            armedTimers: self.state.alarm == nil ? 0 : 1,
            scheduledDeadlines: self.state.heap.count,
            ownedTasks: self.state.tasks.count,
            watcherActive: self.state.watcher != nil,
            subscribers: self.state.subscribers.count,
            bufferedEvents: self.state.subscribers.values.reduce(0) { $0 + $1.liveCount },
            memoryPressureObserverActive: self.state.pressure.task != nil
        )
    }

    /// Suspends until `predicate` holds, re-evaluated after every mutation (never polled), or until the caller is
    /// cancelled (the `CensusWaiting` pattern, l2fu-1): the wait then returns with the predicate unmet.
    func performWaitUntil(_ predicate: @escaping @Sendable (EngineIntrospection) -> Bool) async {
        self.state.lastObserver += 1
        let id = self.state.lastObserver
        // REENTRANCY: RE-S25 — nothing: a terminal wait registered synchronously; resumed once by the mutation that
        // met the predicate, by the caller's cancellation or by shutdown.
        await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if predicate(self.currentIntrospection()) || Task.isCancelled || self.state.lifecycle == .shutDown {
                    continuation.resume()
                } else {
                    self.state.observers[id] = Observer(predicate: predicate, continuation: continuation)
                    self.notifyConditions()
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop removes only this wait (a no-op once it was resumed).
                await self.cancelObserver(id)
            }
        }
    }

    private func cancelObserver(_ id: UInt64) {
        self.state.observers.removeValue(forKey: id)?.continuation.resume()
    }

    /// Test seam: registered `waitUntil` calls.
    func observerCount() -> Int {
        self.state.observers.count
    }

    /// Test seam: suspends until at least `count` `waitUntil` calls are registered; ends on the caller's cancellation.
    func waitUntilObservers(_ count: Int) async {
        // REENTRANCY: f-8 (proposed) — nothing: a terminal test wait.
        await self.awaitCondition { engine in
            engine.state.observers.count >= count
        }
    }

    /// Test seams' wait: suspends until `condition` holds on the actor, re-evaluated after every mutation, or until the
    /// caller is cancelled or shutdown ends (the `CensusWaiting` pattern).
    func awaitCondition(_ condition: @escaping @Sendable (isolated SyncEngine) -> Bool) async {
        self.state.lastObserver += 1
        let id = self.state.lastObserver
        // REENTRANCY: f-8 (proposed) — nothing: a terminal test wait registered synchronously and resumed once.
        await withTaskCancellationHandler {
            // REENTRANCY: f-8 (proposed) — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if condition(self) || Task.isCancelled || self.state.lifecycle == .shutDown {
                    continuation.resume()
                } else {
                    self.state.conditionObservers[id] = ConditionObserver(condition: condition, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: f-8 (proposed) — nothing: the hop removes only this wait.
                await self.cancelCondition(id)
            }
        }
    }

    private func cancelCondition(_ id: UInt64) {
        self.state.conditionObservers.removeValue(forKey: id)?.continuation.resume()
    }

    /// Re-evaluates the test seams' conditions.
    private func notifyConditions() {
        guard !self.state.conditionObservers.isEmpty else {
            return
        }
        for id in self.state.conditionObservers.keys.sorted() {
            guard let observer = self.state.conditionObservers[id], observer.condition(self) else {
                continue
            }
            self.state.conditionObservers[id] = nil
            observer.continuation.resume()
        }
    }

    /// Re-evaluates every `waitUntil` predicate (after a mutation).
    func notifyObservers() {
        self.notifyConditions()
        guard !self.state.observers.isEmpty else {
            return
        }
        let snapshot = self.currentIntrospection()
        for id in self.state.observers.keys.sorted() {
            guard let observer = self.state.observers[id], observer.predicate(snapshot) else {
                continue
            }
            self.state.observers[id] = nil
            observer.continuation.resume()
        }
    }

    /// The engine invariants (sync.md §6.2, ARCHITECTURE §7.1), as violations; checked by the model-based test.
    ///
    /// `storeDeadlineDue` is orchestrator ruling L5K-R16's tripwire: whether the store reported a time-only deadline
    /// (`nextDeadline() != nil`) when the caller read it while the engine was settled (`storeDeadlineSettled`). The store
    /// reports one whenever a coalesced publication's trailing install is due (`installDue`, ARCHITECTURE §5), so the
    /// engine must then hold a store deadline on its heap: settled, nothing else re-reads it, and without the alarm's
    /// `runDueWork()` the readers' snapshot would miss what the store holds (and its commit or reap would wait) until some
    /// unrelated store call (ADR-022, RE-S40). Callers that do not read the store pass `false`.
    func invariantViolations(storeDeadlineDue: Bool = false) -> [String] {
        var violations: [String] = []
        if storeDeadlineDue, self.storeDeadlineSettled, self.state.heap.deadline(for: .store) == nil {
            violations.append("the store has a deadline due (a trailing install among them) while the engine is settled with no store deadline on its heap: nothing will run it (L5K-R16)")
        }
        // A waiter whose join waits for a failure verdict (`joinsAfterFollow`) holds no interest until the drain.
        for (token, waiter) in self.state.waiters where !waiter.fromStore && self.state.jobs[waiter.transfer]?.interests[token] == nil {
            if self.state.joinsAfterFollow[token]?[waiter.asset] != waiter.transfer {
                violations.append("waiter \(token.rawValue) has no interest in \(waiter.transfer)")
            }
        }
        // A job the owed passes of a follow have not reached follows the copy they replaced (`followScans`).
        let unscanned = self.state.followScans.isEmpty ? [:] : self.unscannedFollowEntries()
        for (transfer, job) in self.state.jobs {
            if job.interests.isEmpty, job.state != .verifying, job.state != .committing {
                let key = ClaimKey(job: job)
                if self.state.claims[key] == nil {
                    violations.append("job \(transfer) has no interest and no claim in \(job.state.kind.rawValue)")
                } else if self.state.claimHeld[key] != transfer {
                    violations.append("job \(transfer) is kept by a claim that would not retire it")
                }
            }
            if (job.state == .downloading) != (job.active != nil) {
                violations.append("job \(transfer) in \(job.state.kind.rawValue) with active \(job.active != nil)")
            }
            // The indexes the proportional walks read (Stage 3, S3-PERF-02): a job outside `unfollowed` follows the
            // copy, a system interest's job is in `systemHeld`, and the run's interest's job is in its `held`.
            if !self.state.unfollowed.contains(transfer), let asset = job.assets.first(where: { self.state.applied.entry(for: $0)?.transferID != transfer && unscanned[$0]?.contains(transfer) != true }) {
                violations.append("job \(transfer) holds \(asset), which the copy maps elsewhere, and is not in unfollowed")
            }
            if job.interests.values.contains(where: { $0.kind == .system }), !self.state.systemHeld.contains(transfer) {
                violations.append("job \(transfer) holds a system interest and is not in systemHeld")
            }
            if let run = self.state.run, job.interests[run.token] != nil, !run.held.contains(transfer) {
                violations.append("job \(transfer) holds the run's interest and is not in its held set")
            }
            for token in job.interests.keys where job.interests[token]?.kind == .waiter {
                if let waiter = self.state.waiters[token] {
                    // A waiter's interest is only ever in the job it names (`withdraw` touches that job only).
                    if waiter.transfer != transfer {
                        violations.append("waiter \(token.rawValue) names \(waiter.transfer) but holds an interest in \(transfer)")
                    }
                } else {
                    violations.append("waiter interest \(token.rawValue) without a waiter")
                }
            }
        }
        if self.runningCount > self.tuning.maxConcurrentTransfers {
            violations.append("\(self.runningCount) running > \(self.tuning.maxConcurrentTransfers)")
        }
        for (token, group) in self.state.groups {
            for (asset, transfer) in group.pending where self.state.jobs[transfer]?.interests[token] == nil {
                if self.state.joinsAfterFollow[token]?[asset] != transfer {
                    violations.append("group \(token.rawValue) member \(asset) without an interest")
                }
            }
        }
        violations.append(contentsOf: self.claimViolations())
        if self.state.queues.storedCount > 2 * self.state.jobs.count + 16 {
            violations.append("lane queues hold \(self.state.queues.storedCount) entries for \(self.state.jobs.count) jobs")
        }
        if self.state.metrics.illegalTransitions > 0 {
            violations.append("\(self.state.metrics.illegalTransitions) illegal transitions")
        }
        for (key, queue) in self.state.subscribers where queue.storedOrderCount > 2 * queue.liveCount + 16 {
            violations.append("subscriber \(key) order \(queue.storedOrderCount) > 2 × \(queue.liveCount) + 16")
        }
        if let unfired = self.unfiredDeadline() {
            violations.append(unfired)
        }
        if let stranded = self.strandedPendingRun() {
            violations.append(stranded)
        }
        if let stranded = self.strandedBreakerParks() {
            violations.append(stranded)
        }
        if let unwakeable = self.unwakeableThrottleParks() {
            violations.append(unwakeable)
        }
        for (transfer, drain) in self.state.draining where self.isRunning && self.state.tasks[drain.driver] == nil {
            violations.append("\(transfer) drains an attempt whose driver ended")
        }
        if let run = self.state.run, run.transferring, run.settlement == nil {
            let waitingJoins = Set(self.state.joinsAfterFollow[run.token].map { Array($0.values) } ?? [])
            for transfer in run.outstanding.keys where self.state.jobs[transfer]?.interests[run.token] == nil && !waitingJoins.contains(transfer) {
                violations.append("the run claims \(transfer), whose job does not hold its interest")
            }
        }
        if self.isRunning, self.state.manifestCatchUps == 0, !self.followOwed, !self.state.heldForManifest.isEmpty {
            violations.append("\(self.state.heldForManifest.count) jobs held for a manifest catch-up nothing performs")
        }
        if self.isRunning, let origin = self.state.remote?.originID, self.state.breakers[origin]?.probe == .manifest,
           self.state.manifestFetch == nil, self.state.run == nil {
            // A probe held for a manifest fetch is that fetch's, in flight, or the starting run's, whose first turn begins
            // it; every fetch records its outcome on the breaker before it ends, and one that asks for nothing lets the
            // probe go (`releaseManifestProbe`, F-42).
            violations.append("the breaker's probe is held for a manifest fetch that is neither in flight nor about to begin")
        }
        var inFlight = InFlightBytes()
        var flying: Set<TransferID> = []
        var parkedForSpace: Set<TransferID> = []
        for job in self.state.jobs.values {
            if let bytes = job.ledgerBytes {
                inFlight.add(bytes)
                flying.insert(job.transfer)
            }
            if job.state.isSpaceParked {
                parkedForSpace.insert(job.transfer)
            }
        }
        if parkedForSpace != self.state.spaceParked {
            violations.append("the ledger's \(self.state.spaceParked.count) jobs parked for space differ from the table's \(parkedForSpace.count)")
        }
        violations.append(contentsOf: self.indexViolations())
        if inFlight != self.state.inFlightBytes || flying != self.state.inFlight {
            violations.append("the ledger's \(self.state.inFlight.count) jobs in flight (\(self.state.inFlightBytes.clamped) bytes) differ from the table's \(flying.count) (\(inFlight.clamped) bytes)")
        }
        return violations
    }

    /// Whether no engine work is under way that could still re-read the store's deadline, for L5K-R16's tripwire
    /// (`invariantViolations(storeDeadlineDue:)`): the engine runs, no job, run or migration loop exists, no alarm's store
    /// work, deadline re-read, settling read, presence read, `apply` or catch-up is in flight, and no owned task runs but
    /// the alarm, the conditions watcher and the memory-pressure observer, none of which re-reads the deadline outside
    /// the alarm's own `runDueWork()` turn.
    var storeDeadlineSettled: Bool {
        guard self.isRunning, self.state.jobs.isEmpty, self.state.run == nil, !self.state.migration.running,
              self.state.storeWorkRuns == 0, !self.state.spaceDeadlineReread, !self.state.spaceSettleRead,
              self.state.presenceReaders == 0, self.state.appliesInFlight == 0, self.state.manifestCatchUps == 0
        else {
            return false
        }
        let timers = Set([self.state.alarm?.task, self.state.watcher?.task, self.state.pressure.task].compactMap { $0 })
        return self.state.tasks.keys.allSatisfy { timers.contains($0) }
    }

    /// The claim counters against the groups' pending claims and the released groups' claims left to drop (L5-R1).
    private func claimViolations() -> [String] {
        var violations: [String] = []
        var tally: [ClaimKey: Int] = [:]
        var unlisted = 0
        for (token, group) in self.state.groups {
            if group.claimed.count != group.members.count {
                violations.append("group \(token.rawValue) claims \(group.claimed.count) contents for \(group.members.count) members")
            }
            let pending = group.claimed[min(group.claimCursor, group.claimed.count)...]
            let groupUnlisted = pending.filter { $0 == nil }.count
            if groupUnlisted != group.unlistedClaims {
                violations.append("group \(token.rawValue) counts \(group.unlistedClaims) unlisted claims for \(groupUnlisted)")
            }
            unlisted += groupUnlisted
            for case let key? in pending {
                tally[key, default: 0] += 1
            }
        }
        for release in self.state.releasing.values {
            for case let key? in release.claims {
                tally[key, default: 0] += 1
            }
        }
        if tally != self.state.claims {
            violations.append("the claim table's \(self.state.claims.count) contents differ from the groups' \(tally.count)")
        }
        if unlisted != self.state.unlistedClaims {
            violations.append("\(self.state.unlistedClaims) unlisted claims counted for \(unlisted)")
        }
        return violations
    }

    /// The indexes of jobs parked by a lane-wide gate or by their origin and of failed jobs, against the job table, and
    /// the owed re-queues against those indexes (C2).
    private func indexViolations() -> [String] {
        var violations: [String] = []
        var laneParked: Set<TransferID> = []
        var circuitParked: Set<TransferID> = []
        var throttleParked: Set<TransferID> = []
        var failed: Set<TransferID> = []
        for job in self.state.jobs.values {
            if job.state.isLaneParked {
                laneParked.insert(job.transfer)
            }
            if job.state.isCircuitParked {
                circuitParked.insert(job.transfer)
            }
            if job.state.isThrottleParked {
                throttleParked.insert(job.transfer)
            }
            if job.state.kind == .failed {
                failed.insert(job.transfer)
            }
        }
        if laneParked != self.state.laneParked {
            violations.append("the index's \(self.state.laneParked.count) jobs parked by a lane-wide gate differ from the table's \(laneParked.count)")
        }
        if circuitParked != self.state.circuitParked || throttleParked != self.state.throttleParked {
            violations.append("the index's \(self.state.circuitParked.count) and \(self.state.throttleParked.count) jobs parked by the breaker and the throttle differ from the table's \(circuitParked.count) and \(throttleParked.count)")
        }
        // Every job the breaker parked has its place in the breaker's order (S3-B-063).
        if !circuitParked.isEmpty {
            var placed: Set<TransferID> = []
            for entry in self.state.circuitOrder.entries where self.state.jobs[entry.transfer]?.ticket == entry.ticket {
                placed.insert(entry.transfer)
            }
            let unplaced = circuitParked.subtracting(placed).count
            if unplaced > 0 {
                violations.append("\(unplaced) jobs the breaker parked have no place in its order")
            }
        }
        if failed != self.state.failedJobs {
            violations.append("the index's \(self.state.failedJobs.count) failed jobs differ from the table's \(failed.count)")
        }
        if !self.state.edgeOwed.isSubset(of: failed) {
            violations.append("\(self.state.edgeOwed.subtracting(failed).count) jobs owed a re-queue by a network edge are not failed")
        }
        let originParked = circuitParked.union(throttleParked)
        if !self.state.originOwed.isSubset(of: originParked) {
            violations.append("\(self.state.originOwed.subtracting(originParked).count) jobs owed a re-queue by their origin are not parked by it")
        }
        // A re-admission turn that waits for the follow (`EventAfterFollow.readmit`) is the turn the owed re-queues wait for.
        let readmissionWaits = self.state.eventsAfterFollow.contains { if case .readmit = $0 { return true } else { return false } }
        if self.isRunning, !self.state.edgeOwed.isEmpty || !self.state.originOwed.isEmpty, !self.state.readmissionFollowUpScheduled, !readmissionWaits {
            violations.append("re-queues are owed but no turn is scheduled for them")
        }
        if self.isRunning, self.followOwed, !self.state.followFollowUpScheduled {
            violations.append("a follow owes \(self.state.followScans.count) passes and \(self.state.followOrder.count - self.state.followNext) visits but no turn is scheduled for them")
        }
        if self.isRunning, self.state.pumpWaitsForFollow, !self.followBarrier {
            violations.append("a pump waits for a follow that nothing owes")
        }
        violations.append(contentsOf: self.followBarrierViolations())
        if self.followOwed {
            let unmarked = self.state.followOrder[self.state.followNext...].filter { self.state.jobs[$0] != nil && !self.state.unfollowed.contains($0) }.count
            if unmarked > 0 {
                violations.append("\(unmarked) jobs a follow still owes a visit are not in unfollowed")
            }
        }
        // A release turn that waits for the follow (`EventAfterFollow.continueReleases`) is the turn the members wait for.
        let releaseWaits = self.state.eventsAfterFollow.contains { if case .continueReleases = $0 { return true } else { return false } }
        if self.isRunning, !self.state.releasing.isEmpty, !self.state.releaseFollowUpScheduled, !releaseWaits {
            violations.append("\(self.state.releasing.count) released groups keep interests but no turn is scheduled to remove them")
        }
        // A registered group's token is in `releasing` with claims only after a join's large give-up (L5-R15): that is
        // the follow-up's work, not a release of a registered group, which holds members (L5-R22(4); Stage 3, S3-B-082).
        for (token, release) in self.state.releasing where self.state.groups[token] != nil && !release.members.isEmpty {
            violations.append("group \(token.rawValue) is released and registered")
        }
        // A job set aside waits in no queue: it must be one only released groups want.
        let strayAside = self.state.queues.asideEntries.filter { entry in
            guard self.isValid(entry), let job = self.state.jobs[entry.transfer] else {
                return false
            }
            return !self.isReleasedOnly(job)
        }
        if !strayAside.isEmpty {
            violations.append("\(strayAside.count) queued jobs wait set aside for a release, but other interests want them")
        }
        // Every queued job can still be dispatched: a valid entry of it waits in its queue, put back, or aside while only
        // released groups want it (the rule above); a job with none would wait for ever (review of close-out cycle 10).
        // Behind the follow barrier no place waits any more (Stage 3 close-out cycle 12: the `.enqueue` event is gone).
        let reachable = Set(self.state.queues.storedEntries.lazy.filter { self.isValid($0) }.map(\.transfer))
        let stranded = self.state.jobs.values.filter { job in
            job.state == .queued && !reachable.contains(job.transfer)
        }.count
        if stranded > 0 {
            violations.append("\(stranded) queued jobs wait in no queue")
        }
        return violations
    }

    /// The follow barrier's own rules (F-28): the events wait only while a follow is owed, a drain turn is scheduled or a
    /// drain is in progress (none, between turns), so none waits for ever; every failure verdict that waits names a
    /// failed job with its event (Stage 3 close-out cycle 9, amendment (c) of S3-R11); the joins registered in
    /// `joinsAfterFollow` are exactly the waiting `.join` events (cycle 10); the carried jobs are gone once the barrier
    /// is down (cycle 11); every waiting event has its decision instant in the world history, every waiting commit names
    /// a committing job that owes the follow its visit, and once the barrier is down the history, the visits' and the
    /// places' decision instants and the marks of publications that owe a visit are gone (cycle 12, S3-R15).
    private func followBarrierViolations() -> [String] {
        var violations: [String] = []
        let events = self.state.eventsAfterFollow
        if self.isRunning, !events.isEmpty, !self.followOwed, !self.state.drainFollowUpScheduled, !self.state.drainingAfterFollow {
            violations.append("\(events.count) events wait for a follow, but no follow is owed and no drain is scheduled")
        }
        var verdicts: Set<TransferID> = []
        var joins: [InterestToken: [AssetID: TransferID]] = [:]
        for event in events {
            switch event {
            case .committed(let commit):
                if self.state.jobs[commit.transfer]?.epoch == commit.epoch, self.state.jobs[commit.transfer]?.state != .committing {
                    violations.append("a commit waits for the follow for a job that is not committing")
                }
            case .attemptFailed(let transfer, let epoch, _):
                if self.state.verdictsAfterFollow[transfer]?.epoch == epoch {
                    verdicts.insert(transfer)
                }
            case .join(let join):
                joins[join.token, default: [:]][join.asset] = join.entry.transferID
            case .spaceFailure, .endClaim, .endClaims, .removal, .release, .continueReleases, .purge, .conditions, .readmit, .unblock, .retryDue, .throttleAnswers:
                break
            }
        }
        if joins != self.state.joinsAfterFollow {
            violations.append("\(self.state.joinsAfterFollow.count) interests' joins wait for the follow, \(joins.count) with their event")
        }
        if events.count != self.state.eventStamps.count || self.state.eventStamps.contains(where: { $0.view >= self.state.worldHistory.count }) {
            violations.append("\(events.count) events wait for a follow with \(self.state.eventStamps.count) decision instants over \(self.state.worldHistory.count) views")
        }
        if !self.followBarrier, !self.state.followCarried.isEmpty {
            violations.append("the follow barrier is down with \(self.state.followCarried.count) carried jobs left")
        }
        if !self.followBarrier, !self.state.worldHistory.isEmpty || !self.state.followStamps.isEmpty || !self.state.placeStamps.isEmpty || !self.state.publishedOwingVisit.isEmpty {
            violations.append("the follow barrier is down with \(self.state.worldHistory.count) views, \(self.state.followStamps.count) visits' and \(self.state.placeStamps.count) places' decision instants and \(self.state.publishedOwingVisit.count) publications owing a visit left")
        }
        if verdicts != Set(self.state.verdictsAfterFollow.keys) {
            violations.append("\(self.state.verdictsAfterFollow.count) failure verdicts wait for a follow, \(verdicts.count) of them with their event")
        }
        let unfailed = self.state.verdictsAfterFollow.keys.filter { transfer in
            guard case .failed? = self.state.jobs[transfer]?.state else {
                return true
            }
            return false
        }
        if !unfailed.isEmpty {
            violations.append("\(unfailed.count) jobs whose failure verdict waits for a follow are not failed")
        }
        return violations
    }

    /// Why the heap's earliest deadline may never fire, if so. While running, `rearm` keeps one alarm armed at or before
    /// it, re-armed in the very turn that schedules a deadline, whose owned task stays alive until it fires or is
    /// replaced (ADR-022, R-SYN-14). Only an alarm turn's store work leaves the alarm cleared across an await
    /// (`storeWorkRuns`), and that turn re-arms before it returns. An alarm that is never moved earlier, or one whose
    /// task ended without firing, would leave every deadline after it unfired, a stall the model test could not name
    /// (close-out cycle 14, F-34).
    private func unfiredDeadline() -> String? {
        guard self.isRunning, let first = self.state.heap.first, !self.state.storeWorkInFlight else {
            return nil
        }
        guard let alarm = self.state.alarm, self.state.tasks[alarm.task] != nil else {
            return "no live alarm will fire the earliest deadline (\(first.reason))"
        }
        guard alarm.deadline <= first.at else {
            return "the alarm is armed after the earliest deadline (\(first.reason))"
        }
        return nil
    }

    /// Why the jobs the breaker parked may never be re-admitted, if so. A breaker that admits only a probe re-admits one
    /// parked job for it (`readmitForProbe()`, S3-B-063); the others wait, legitimately, while a queued job will take the
    /// probe. With the probe untaken, nothing queued, no re-queue or pump owed and no alarm turn due for the breaker (it
    /// re-admits at a cooldown's end or a watchdog), nothing would re-admit them: a half-open breaker without a probe has no
    /// deadline.
    private func strandedBreakerParks() -> String? {
        guard self.isRunning, let origin = self.state.remote?.originID, !self.state.circuitParked.isEmpty, self.breakerAdmitsOnlyProbe() else {
            return nil
        }
        if let due = self.state.heap.deadline(for: .breaker(origin)), due <= self.environment.time.monotonicNow() {
            return nil
        }
        if self.state.pumpFollowUpScheduled || !self.state.originOwed.isEmpty || self.state.jobs.values.contains(where: { $0.state == .queued }) {
            return nil
        }
        return "nothing re-admits the \(self.state.circuitParked.count) jobs the breaker parked for the probe it admits"
    }

    /// Why the jobs a throttle parked may never be re-admitted, if so. Only the origin's `.throttle` deadline re-admits
    /// them (`unblockOrigin(.throttled)` when it fires at the throttle's end; the jobs that turn cannot re-queue are owed a
    /// follow-up, `originOwed`), and the alarm keeps that deadline at the throttle's end while the throttle is in force.
    /// A parked job neither owed a re-queue nor behind that deadline waits for ever: the state a manifest 429 left when
    /// it moved the deadline before the throttle's end and the alarm dropped it (close-out cycle 15, F-35).
    private func unwakeableThrottleParks() -> String? {
        guard self.isRunning, let origin = self.state.remote?.originID, self.state.heap.deadline(for: .throttle(origin)) == nil else {
            return nil
        }
        let waiting = self.state.throttleParked.subtracting(self.state.originOwed)
        guard !waiting.isEmpty else {
            return nil
        }
        return "nothing will re-admit the \(waiting.count) jobs the throttle parked"
    }

    /// Why the pending run can never start, if so: with no run in progress, its gate is open, or nothing (a deadline,
    /// the conditions watcher, a probe in flight) will open it (sync-2 S2-03, S2-25). A gate the clock opened is not
    /// stranded while the deadline that starts its run is due and an alarm turn will fire it (`startsInAlarmTurn`).
    private func strandedPendingRun() -> String? {
        guard self.isRunning, self.state.run == nil, let pending = self.state.pendingRun else {
            return nil
        }
        switch self.pendingRunGate(pending) {
        case .open:
            if self.startsInAlarmTurn(pending) {
                return nil
            }
            return "the pending run's \(pending.gate) gate is open but no run started"
        case .armed:
            return nil
        case .unarmed:
            return "nothing will open the pending run's \(pending.gate) gate"
        }
    }

    /// Whether the run of `pending` starts in an alarm turn still to come: the clock reached the deadline that opens its
    /// throttle or breaker gate (`.pendingRun` at the throttle's end, `.breaker` at the cooldown's end), which is still in
    /// the heap, and an alarm will fire it. Two windows lie between the clock's move and that turn:
    /// - An alarm is armed: the move resumes its sleep, but it fires the deadline only once it has the actor (close-out
    ///   cycle 13, F-33). Only an alarm whose owned task is alive and whose deadline is at or before the gate's counts;
    ///   `rearm` keeps the alarm at the heap's earliest deadline in the turn that schedules one, so any other alarm
    ///   would never fire the gate's deadline in time.
    /// - An alarm turn's store work is under way (`storeWorkRuns`): the alarm clears `state.alarm` before it fires what
    ///   is due, and a due store deadline suspends its turn in `store.runDueWork()` (and in the free-space read after
    ///   reaped bytes). The turn re-arms at the heap's earliest deadline before it returns, and that alarm starts the
    ///   run; a run the turn still leaves pending is reported at the next check (close-out cycle 14, F-34).
    private func startsInAlarmTurn(_ pending: PendingRun) -> Bool {
        let reason: DeadlineReason
        switch pending.gate {
        case .throttle:
            reason = .pendingRun
        case .breaker:
            guard let origin = self.state.remote?.originID else {
                return false
            }
            reason = .breaker(origin)
        case .conditions:
            // Its gate reads armed while its debounce is in the heap (`pendingRunGate`).
            return false
        }
        guard let at = self.state.heap.deadline(for: reason), at <= self.environment.time.monotonicNow() else {
            return false
        }
        if self.state.storeWorkInFlight {
            return true
        }
        guard let alarm = self.state.alarm, self.state.tasks[alarm.task] != nil else {
            return false
        }
        return alarm.deadline <= at
    }
}
