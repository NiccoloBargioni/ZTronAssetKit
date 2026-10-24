import Foundation
import ZTronAssetModel
import ZTronAssetStorage

extension SyncEngine {
    // MARK: Present assets get no job (ARCHITECTURE §7.1, T22, R-NET-6; L4-R5)

    /// Whether the engine knows the store holds `asset` bound to `transfer`'s content.
    func isBound(_ asset: AssetID, to transfer: TransferID) -> Bool {
        self.state.boundContent[asset] == transfer
    }

    /// Whether a store record is present at the content of `transfer`: a referenced blob that is its current content.
    static func isPresent(_ record: AssetRecord?, at transfer: TransferID) -> Bool {
        guard let record, record.referencedBlob != nil, !record.isStale else {
            return false
        }
        return record.entry.transferID == transfer
    }

    /// Records what a store view shows for `ids`: an id present at its applied entry's content is bound to it, unless
    /// the engine forgot a binding since the read began (`serial`, see `bind(_:to:since:)`).
    func noteBound(from view: StorePlanningView, ids: some Sequence<AssetID>, since serial: UInt64) {
        guard self.state.ledgerForgets == serial else {
            return
        }
        for id in ids {
            guard let transfer = view.appliedManifest.entry(for: id)?.transferID, SyncEngine.isPresent(view.records[id], at: transfer) else {
                continue
            }
            self.state.boundContent[id] = transfer
        }
    }

    /// Forgets bindings the engine learned have ended (or may have: a recorded failure, a quarantine). Any forget makes
    /// the bindings of reads and mutations still in flight untrusted (`bind(_:to:since:)`).
    func forgetBound(_ ids: some Sequence<AssetID>) {
        var forgot = false
        for id in ids {
            self.state.boundContent[id] = nil
            forgot = true
        }
        if forgot {
            self.state.ledgerForgets &+= 1
        }
    }

    /// Drops every binding: something unbound ids the engine was not told about one by one (a store mutation that threw
    /// past its in-memory writes, a purge, a maintenance step, a quarantine of a shared blob). An id the ledger no longer
    /// knows is unknown, not absent: before any of its content is downloaded, the attempt asks the store
    /// (`answeredFromStore`).
    func dropBindings() {
        self.state.boundContent.removeAll()
        self.state.ledgerForgets &+= 1
    }

    /// Records that the store bound `ids` to `transfer`'s content, as a read or a mutation that began when the forget
    /// serial was `serial` showed it. Nothing is recorded when the engine forgot a binding since: that result may predate
    /// what ended the binding (an eviction or quarantine the engine processed first), and a stale binding would make an
    /// interest skip an absent asset. A binding not recorded only costs a store read before a transfer.
    func bind(_ ids: some Sequence<AssetID>, to transfer: TransferID, since serial: UInt64) {
        guard self.state.ledgerForgets == serial else {
            return
        }
        for id in ids {
            self.state.boundContent[id] = transfer
        }
    }

    /// Keeps only the bindings something could still consult: everything while a run exists (its plan is a snapshot),
    /// while an `ensureAvailable` group has fetches left to materialise, or while a store read whose answer registers an
    /// interest is in flight; otherwise only the ids of jobs (an interest that follows its asset's entry may meet them).
    /// The ledger therefore scales with outstanding work and a plan in progress, never with the catalog.
    func pruneBoundContent() {
        guard !self.state.boundContent.isEmpty, self.state.run == nil, self.state.presenceReaders == 0 else {
            return
        }
        guard !self.state.groups.values.contains(where: { $0.cursor < $0.fetches.count }) else {
            return
        }
        guard !self.state.jobs.isEmpty else {
            self.state.boundContent.removeAll()
            return
        }
        var wanted = Set<AssetID>()
        for job in self.state.jobs.values {
            wanted.formUnion(job.assets)
        }
        self.state.boundContent = self.state.boundContent.filter { wanted.contains($0.key) }
    }

    /// Answers `token`'s interest in `asset`, which the store holds bound to `transfer`'s content, instead of creating or
    /// joining a job: a waiter gets the location from a store read, a group drops the member as done, a run counts the
    /// asset as fetched, a heal is forgotten. `old` is the job the interest leaves, if any (its run claim and group
    /// member go with it).
    func answerPresent(_ token: InterestToken, kind: InterestKind, lane: AssetPriority, asset: AssetID, at transfer: TransferID, from old: TransferID?) {
        switch kind {
        case .waiter:
            self.answerWaiterFromStore(token, asset: asset, lane: lane, transfer: transfer)
        case .prefetch, .ensure:
            if let old {
                self.dropGroupMember(token, asset: asset, from: old)
            }
        case .run:
            if let old {
                self.releaseRunClaim(token, asset: asset, from: old)
            }
            self.countRunFetched(token)
        case .system:
            self.state.heals[asset] = nil
        }
        self.notifyObservers()
    }

    /// The run counts a planned asset it found present as fetched.
    func countRunFetched(_ token: InterestToken) {
        guard var run = self.state.run, run.token == token else {
            return
        }
        run.fetched += 1
        self.state.run = run
        self.offerRunProgress()
    }

    /// Moves waiter `token` off the job path: an owned task reads the asset's location from the store.
    func answerWaiterFromStore(_ token: InterestToken, asset: AssetID, lane: AssetPriority, transfer: TransferID) {
        guard var waiter = self.state.waiters[token] else {
            return
        }
        waiter.transfer = transfer
        waiter.fromStore = true
        self.state.waiters[token] = waiter
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the waiter.
            await engine.readPresentLocation(token, asset: asset, lane: lane)
        }
        if spawned == nil {
            self.state.waiters.removeValue(forKey: token)?.continuation.resume(returning: .failure(self.isShuttingDown ? .shutDown : .cancelled))
        }
    }

    /// The store read behind `answerWaiterFromStore`: the location, or, when the binding ended meanwhile, the job path.
    private func readPresentLocation(_ token: InterestToken, asset: AssetID, lane: AssetPriority) async {
        // REENTRANCY: RE-S36 — the lifecycle and the waiter still registered (and still answered from the store), else
        // nothing is answered; a `nil` location falls through to the job path, which re-reads the entry.
        let location = await self.store.location(for: asset, extensions: [], recordingAccess: true)
        guard self.isRunning, self.state.waiters[token]?.fromStore == true else {
            return
        }
        if let location {
            self.state.metrics.resolveHits += 1
            self.state.waiters.removeValue(forKey: token)?.continuation.resume(returning: .success(location))
            self.reconcileIdle()
            return
        }
        self.forgetBound([asset])
        guard let entry = self.state.applied.entry(for: asset) else {
            self.state.waiters.removeValue(forKey: token)?.continuation.resume(returning: .failure(.notFound))
            self.reconcileIdle()
            return
        }
        self.state.waiters[token]?.fromStore = false
        self.state.waiters[token]?.transfer = entry.transferID
        self.addInterest(token, asset: asset, entry: entry, lane: lane, kind: .waiter)
        self.pump()
    }

    /// Before an attempt asks the source for bytes, asks the store whether it already holds them (L4-R5; close-out cycle
    /// 3, F-23). The binding ledger is a cache: an id it does not know (dropped after a store mutation that threw, a
    /// maintenance pass, a purge or a quarantine; never learned; not recorded because a forget overlapped its read) is
    /// unknown, not absent. Every id of the job that the engine's copy maps to this content and the store serves at its
    /// current content (a location that is not stale) is answered from the store (`answerPresentMembers`); when no
    /// interest is left, the attempt ends before it started (no stream exists, so nothing drains), and nothing is
    /// downloaded twice. One O(1) read per id of the job, never a planning view (C2). While legacy migration is pending,
    /// the read adopts the id's prior-art file instead (`storedLocation(of:lane:)`, orchestrator ruling L5K-R1): every job
    /// passes here before any bytes, whatever created it, so no transfer starts for a file migration can still adopt
    /// (R-STO-11). An id of the same content that joins the job during the reads (ADR-020: a prefetch join,
    /// `ensureAvailable`, a run's later materialisation, a reroute) is read too, round after round until no new id is left
    /// (orchestrator ruling L5K-R23), so its prior-art file is adopted rather than downloaded. The window between the last
    /// read and the transfer is the one the 404 path has (a legacy or orphan adoption of the same content; single flight
    /// rules out any other binding of this content while its job exists).
    ///
    /// After each bulk-urgency adoption, before the job's next read, that adoption's trailing install is scheduled: the
    /// store's deadline is re-read into the heap (RE-S40, orchestrator rulings L5K-R16 and L5K-R23), in O(1) while the alarm
    /// already wakes within about two install intervals (F-12), so the adoption reaches the readers' snapshot within about
    /// two install intervals however long the job's later reads take. Then, after the last ordinary await (the last read,
    /// or its re-read of the deadline), the answer site checks the job's interests (orchestrator ruling L5K-R21): when the
    /// job holds a user-initiated interest and an id was answered by a read that did not itself install the snapshot at
    /// once (a bulk-urgency adoption, a present asset whose trailing install may still be due, or a plain location read),
    /// one user-initiated publication follows (`adoptLegacyNow` at `.userInitiated` of that id, which installs the whole
    /// state at once, ARCHITECTURE §5), and nothing else is awaited before the synchronous answer. So a user-initiated
    /// asker, whether it joined before the reads, during any of them or of their re-reads of the deadline, or as migration
    /// ended mid-loop, is never answered before the readers' snapshot holds the asset; a promotion after the check cannot
    /// interleave, since no suspension follows it. `true` when the attempt ended here.
    func answeredFromStore(_ transfer: TransferID, epoch: UInt64, attempt: TransferAttempt) async -> Bool {
        guard let job = self.state.jobs[transfer] else {
            return false
        }
        let serial = self.state.ledgerForgets
        var present: Set<AssetID> = []
        // The last id answered by a read that installed nothing at once, unless a later user-initiated adoption installed
        // the whole state after it.
        var uninstalled: AssetID?
        // Every id asked so far: an id the job gains during the reads is asked once too (orchestrator ruling L5K-R23).
        var asked: Set<AssetID> = []
        var next = job.assets.filter { self.state.applied.entry(for: $0)?.transferID == transfer }.sorted()
        while !next.isEmpty {
            for id in next {
                asked.insert(id)
                // The job's lane as of this read (a promotion during an earlier read raised it): only a user-initiated
                // job's adoption installs its snapshot at once (L5K-R14).
                let lane = self.state.jobs[transfer]?.lane ?? job.lane
                // REENTRANCY: f-11 (proposed), k-4 (proposed) — the lifecycle, the job epoch and the attempt (still without
                // a handle), re-checked after the reads; the ids the job gained meanwhile are read too (`unaskedIDs`); the
                // interests answered are those the job holds then, checked for a user-initiated one after the last ordinary
                // await (L5K-R21); the bindings are recorded only when nothing was forgotten during the reads (an adoption
                // here is such a binding).
                let read = await self.storedLocation(of: id, lane: lane)
                if read.location != nil, read.urgency == .userInitiated {
                    // A user-initiated adoption installed the whole state at once, the earlier answers included.
                    uninstalled = nil
                }
                if let location = read.location, !location.isStale {
                    present.insert(id)
                    if read.urgency != .userInitiated {
                        uninstalled = id
                    }
                }
                if read.urgency == .bulk {
                    // REENTRANCY: RE-S40 — the lifecycle (inside); the heap's store entry is replaced by the newest deadline,
                    // so the trailing install this bulk-urgency adoption left due runs on the alarm while the job's later
                    // reads run (L5K-R16; orchestrator ruling L5K-R23). The job's interests are checked after the last of
                    // these awaits, below, and the rest as f-11 says.
                    await self.refreshStoreDeadlineAfterPublish()
                }
            }
            // An id of this content that joined the job during the reads (a prefetch join, `ensureAvailable`, a run's later
            // materialisation, a reroute) is asked before the answer too, round after round until no new id is left:
            // otherwise its interest stays and the transfer downloads content whose prior-art file migration can still
            // adopt (orchestrator ruling L5K-R23; L5K-C4-02). Each id is asked once, so the rounds end.
            next = self.unaskedIDs(of: transfer, epoch: epoch, attempt: attempt, asked: asked)
        }
        if let id = uninstalled, self.isRunning, self.state.jobs[transfer]?.lane == .userInitiated {
            // The answer site (orchestrator ruling L5K-R21): a user-initiated asker joined before, during a read or during
            // the re-read, and an answered id may be in a coalesced snapshot only. One user-initiated publication installs
            // the whole state before the answer below, which follows it synchronously.
            // REENTRANCY: k-4 (proposed) — the lifecycle, the job epoch and the attempt, re-checked below as f-11 says; a
            // promotion during this await finds the snapshot it installs, which holds every answered id (bound before
            // it); an answer that throws (the store closing) leaves the caller's lifecycle check to discard the answers.
            _ = try? await self.store.adoptLegacyNow(id, urgency: .userInitiated)
        }
        guard !present.isEmpty, self.isRunning, let current = self.state.jobs[transfer], current.epoch == epoch,
              let active = current.active, active.attempt == attempt, active.handle == nil
        else {
            return false
        }
        self.bind(present, to: transfer, since: serial)
        self.answerPresentMembers(of: transfer, present)
        guard self.state.jobs[transfer]?.interests.isEmpty == true else {
            return false
        }
        // The attempt never asked for bytes: no stream will exist, so retiring it leaves nothing to drain.
        self.state.jobs[transfer]?.active?.terminalReceived = true
        self.retire(transfer)
        self.pump()
        self.reconcileIdle()
        return true
    }

    /// The ids `transfer`'s job holds that the engine's copy maps to this content and `answeredFromStore`'s reads have not
    /// asked (`asked`): those the job gained during the reads, sorted. None once the engine stopped or the job's epoch or
    /// attempt moved on, since that attempt is not answered from the store anyway (the final check after the reads).
    private func unaskedIDs(of transfer: TransferID, epoch: UInt64, attempt: TransferAttempt, asked: Set<AssetID>) -> [AssetID] {
        guard self.isRunning, let job = self.state.jobs[transfer], job.epoch == epoch, job.active?.attempt == attempt else {
            return []
        }
        return job.assets.filter { !asked.contains($0) && self.state.applied.entry(for: $0)?.transferID == transfer }.sorted()
    }

    /// What the pre-transfer read gets from the store for `id` (L5K-R1, CCR-K1), with the urgency of the adoption that
    /// answered (`nil` for a plain location read). With no legacy migration pending, the O(1) location read. While it is
    /// pending (running, or backed off to the next maintenance window), `adoptLegacyNow`, which answers a present asset's
    /// location, otherwise adopts the asset's prior-art file at once and answers its location, so a file migration can
    /// still adopt is moved, never downloaded again (R-STO-11), as on the resolve path (ADR-029). The store does the work
    /// on its executors (the hash on the bulk executor), never on the main actor, and only for the ids of a job about to
    /// transfer (C2). The adoption's snapshot is published at `.userInitiated` for a job of `lane` `.userInitiated`
    /// (installed at once, as a resolve's; a present asset's too, L5K-R18) and at `.bulk` otherwise, which the store's
    /// install-rate limiter coalesces, so ARCHITECTURE §5's bound (at most one bulk install per `snapshotInstallInterval`)
    /// holds while a sync adopts (L5K-R14); the caller schedules the trailing install a bulk-urgency adoption leaves due
    /// (L5K-R16) and installs at once before it answers a user-initiated asker (L5K-R21). The location is `nil` when the
    /// store holds nothing for `id`: no prior-art file to adopt, or one that cannot be adopted (it did not verify, it was
    /// kept, or the store refused), which is then downloaded, as on the resolve path; never because a migration batch or
    /// another call is adopting the same file at that moment (the store's single flight per prior-art file, orchestrator
    /// ruling L5K-R13).
    func storedLocation(of id: AssetID, lane: AssetPriority) async -> (location: AssetLocation?, urgency: AssetPriority?) {
        guard self.state.migration.pending else {
            // REENTRANCY: f-11 (proposed) — nothing here: the caller re-validates after its reads.
            return (await self.store.location(for: id, extensions: [], recordingAccess: false), nil)
        }
        let urgency: AssetPriority = lane == .userInitiated ? .userInitiated : .bulk
        do {
            // REENTRANCY: k-4 (proposed) — nothing here: the caller re-validates after its reads. The store runs one
            // adoption per prior-art file (L5K-R13, rows k-5 and k-6): a queued file is claimed before its hash, so no batch
            // takes it; a call that finds the file being processed by another adopt-on-demand, or adopted by a batch, waits
            // for that processing and reads the location it bound; when a batch has not finished hashing the file, both may
            // hash it, and the one whose bytes verify second waits out the other's adoption before it decides. So the
            // answer is that one adoption's outcome, never a failure the other adopter caused. A thrown `StoreError` (the
            // caller's cancellation at shutdown, a store that refuses) reads as "nothing stored".
            return (try await self.store.adoptLegacyNow(id, urgency: urgency), urgency)
        } catch {
            return (nil, urgency)
        }
    }

    /// Takes the interests in `present` out of `transfer`'s job and answers them from the store, so that an outcome of
    /// the job (a 404 of its content) never reaches an asset the store holds (R-NET-6, L4-R5).
    func answerPresentMembers(of transfer: TransferID, _ present: Set<AssetID>) {
        guard !present.isEmpty, let job = self.state.jobs[transfer] else {
            return
        }
        for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) {
            let held = interest.assets.intersection(present)
            guard !held.isEmpty else {
                continue
            }
            let left = interest.assets.subtracting(held)
            self.state.jobs[transfer]?.interests[token] = left.isEmpty ? nil : JobInterest(lane: interest.lane, kind: interest.kind, assets: left)
            for asset in held.sorted() {
                self.answerPresent(token, kind: interest.kind, lane: interest.lane, asset: asset, at: transfer, from: transfer)
            }
        }
        self.state.jobs[transfer]?.assets.subtract(present)
    }
}
