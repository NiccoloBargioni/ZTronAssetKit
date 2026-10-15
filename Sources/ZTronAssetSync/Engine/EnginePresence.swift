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
    /// downloaded twice. One O(1) read per id of the job, never a planning view (C2). The window between the last read and
    /// the transfer is the one the 404 path has (a legacy or orphan adoption of the same content; single flight rules out
    /// any other binding of this content while its job exists). `true` when the attempt ended here.
    func answeredFromStore(_ transfer: TransferID, epoch: UInt64, attempt: TransferAttempt) async -> Bool {
        guard let job = self.state.jobs[transfer] else {
            return false
        }
        let serial = self.state.ledgerForgets
        var present: Set<AssetID> = []
        for id in job.assets.sorted() where self.state.applied.entry(for: id)?.transferID == transfer {
            // REENTRANCY: f-11 (proposed) — the lifecycle, the job epoch and the attempt (still without a handle),
            // re-checked after the reads; the interests answered are those the job holds then; the bindings are recorded
            // only when nothing was forgotten during the reads.
            if let location = await self.store.location(for: id, extensions: [], recordingAccess: false), !location.isStale {
                present.insert(id)
            }
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
