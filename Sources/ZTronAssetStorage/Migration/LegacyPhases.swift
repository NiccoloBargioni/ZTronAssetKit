import Foundation
import ZTronAssetModel

/// Legacy migration phases 1–4 (R-STO-11, H-10; ADR-029, store.md §7, ARCHITECTURE §1.1 rule 1 and §4.7).
extension AssetStore {
    // MARK: Phase 1 (inside open())

    /// `runLegacyPhaseOne()`. Runs while `open()` is `opening`: every await is a unit (REENTRANCY R1) and nothing here
    /// publishes a snapshot.
    func performLegacyPhaseOne() async throws(StoreError) -> Bool {
        // A lifetime that could not read an index file writes nothing (ADR draft B-34): migration waits for a later one.
        // REENTRANCY: R1, R11 — nothing: no state was read before it; `checkLive()` below re-checks the phase.
        guard (try? self.checkWritable()) != nil, let root = await self.resolveLegacyRoot() else {
            return false
        }
        try self.checkLive()
        guard let layout = self.state.core.layout else {
            return false
        }
        // REENTRANCY: R1, R11 — the phase (`checkLive` below); where the two directories lie is a snapshot.
        let overlaps = await self.legacyRootOverlapsStore(root, layout: layout)
        try self.checkLive()
        guard let overlaps else {
            // The root could not even be stat-ed, or an I/O error hid where it lies: decide nothing in this lifetime.
            self.environment.log.log(.store, .error, "could not tell whether the legacy root overlaps the store's directory; migration waits for a later launch")
            return false
        }
        if overlaps {
            // Migrating would move files inside the store's own tree and phase 4 would remove it (review round 2):
            // nothing is written, the prior art's stamp stays, and the app's configuration decides a later launch.
            self.environment.log.log(.store, .error, "the legacy root overlaps the store's directory; legacy migration is skipped")
            return false
        }
        self.state.migration.root = root
        // REENTRANCY: R1, R11 — the phase (`opening`); the root's kind is a snapshot.
        let kind = await self.legacyItemKind(root)
        try self.checkLive()
        guard case .success(let rootKind) = kind else {
            // The root could not even be stat-ed: decide nothing in this lifetime.
            self.state.migration.root = nil
            return false
        }
        switch self.state.migration.phase {
        case .done:
            // A crash during phase 4 left the prior art's files or the key: `migrateLegacy` finishes the removal. A root
            // holding only files that are not the prior art's stays, and is not pending (ADR draft C-15).
            // REENTRANCY: R1 — the phase.
            let stamp = await self.readLegacyStamp()
            try self.checkLive()
            guard rootKind == .directory else {
                return rootKind != nil || stamp != nil
            }
            // REENTRANCY: R1 — the phase; the root's names are a snapshot.
            let pending = await self.legacyRemovalPending(root)
            try self.checkLive()
            return pending || stamp != nil
        case .notStarted, .inProgress:
            break
        }
        guard rootKind == .directory else {
            // No legacy tree (a symbolic link is never followed, R-SEC-2). Before migration started, the stamp can never
            // be migrated (D-6): it goes. A tree that vanished during migration still needs phases 3 and 4 (phase 4 removes
            // a link at the root itself, never what it points to).
            if self.state.migration.phase == .notStarted {
                self.state.migration.root = nil
                // REENTRANCY: R1 — the phase.
                await self.removeLegacyStamp()
                try self.checkLive()
                return false
            }
            return true
        }
        let starting = self.state.migration.phase == .notStarted
        // REENTRANCY: R1, R11 — the phase; the reads below are snapshots of the prior art's files, which no one writes.
        let stamp = starting ? await self.readLegacyStamp() : self.state.migration.legacyStamp
        let limit = self.configuration.limits.maxPayloadBytes
        // REENTRANCY: R1, R11 — as above; the phase is re-checked inside after every unit.
        let manifestRead = try await self.readLegacyFile(root.appendingPathComponent("manifest.json", isDirectory: false), limit: limit)
        // REENTRANCY: R1, R11 — as above.
        let checksumsRead = try await self.readLegacyFile(root.appendingPathComponent("local-checksums.json", isDirectory: false), limit: limit)
        // REENTRANCY: R1, R11, c-4 (proposed) — as above.
        let walk = try await self.listLegacyTree(root)
        if walk.reachesStore {
            // The store's own directory lies inside the legacy root through a link below the root (review of the L3
            // close-out): an overlap, found by the listing; nothing was written.
            self.state.migration.root = nil
            self.environment.log.log(.store, .error, "the legacy root overlaps the store's directory; legacy migration is skipped")
            return false
        }
        guard manifestRead != .failed, checksumsRead != .failed, !walk.failed else {
            // An I/O error while reading the prior art's files decides nothing in this lifetime, as a root that cannot be
            // stat-ed (review round 3, ZProbe-read and ZProbe-list): nothing is written or committed, a relaunch in
            // phase `inProgress` keeps its persisted plan, and no later phase runs on a view this one could not read.
            self.state.migration.root = nil
            self.environment.log.log(.store, .error, "legacy phase 1 could not read the prior art's files; migration waits for a later launch")
            return false
        }
        let limits = self.configuration.limits
        let records = self.state.core.records
        let applied = self.state.core.appliedManifest
        let now = self.environment.time.now()
        // REENTRANCY: R1, R11 — the phase; decoding, planning, phase 1's record writes and the queue are computed off the
        // actor from snapshots (C2 at `maxEntries`, review of the L3 close-out cycle 2). While the store is `opening`
        // nothing else writes the records or the applied manifest (R1), so what the unit built from them is current.
        let phaseOne = await self.runUnit(on: self.environment.bulkExecutor) {
            LegacyDecoding.phaseOne(
                manifest: manifestRead,
                checksums: checksumsRead,
                limits: limits,
                tree: LegacyTree(walk),
                starting: starting,
                records: records,
                applied: applied,
                now: now
            )
        }
        try self.checkLive()
        if starting {
            self.applyLegacyPlanWrites(phaseOne, stamp: stamp)
            do throws(StoreError) {
                // REENTRANCY: R17, R1 — nothing but the phase: phase 1's writes were made synchronously above; a failed
                // commit leaves them dirty (R5) for the launch commit, and phase 2 commits before moving any file.
                try await self.requireCommitted(.ordered)
                self.state.migration.planCommitted = true
            } catch .closed {
                throw .closed
            } catch .notOpen {
                throw .notOpen
            } catch {
                self.environment.log.log(.store, .error, "legacy phase 1 could not commit its plan; it is retried before any file moves")
            }
        } else {
            // A relaunch counts the loaded plan committed only once this lifetime's barrier or a commit succeeded (ADR
            // draft B-36). Marking the state dirty makes the gate of the first move (`commitLegacyPlanIfNeeded`) wait for
            // a commit of this lifetime; the launch commit, which every open() makes, normally covers it already.
            self.markDirty(.soon)
        }
        // The queue was built from the records as phase 1 left them (`LegacyDecoding.phaseOne`), in reverse path order.
        self.state.migration.queue = phaseOne.queue
        self.state.migration.claimed = []
        self.state.migration.legacyIDs = phaseOne.decoded.plan.legacyIDs
        self.state.migration.manifestDigest = phaseOne.decoded.manifest?.digest
        self.state.migration.progress = LegacyMigrationProgress(adopted: 0, remaining: phaseOne.queue.count, dropped: phaseOne.dropped, finished: false)
        return true
    }

    /// Phase 1's writes (ARCHITECTURE §1.1 rule 1), computed by `LegacyDecoding.phaseOne` off the actor: the legacy
    /// manifest becomes the applied one (no ETag) only while none is applied; records are inserted only for ids the
    /// applied manifest lists and the index lacks, as `absent(.neverFetched)` expecting the planned digest; an
    /// undecodable manifest degrades the launch. The records the unit built (the store's own plus those inserts) replace
    /// the store's in O(1): only `open()` runs while it is `opening` (R1), so nothing changed them since the snapshot.
    func applyLegacyPlanWrites(_ phaseOne: LegacyDecoding.PhaseOne, stamp: String?) {
        if phaseOne.decoded.undecodable {
            self.state.core.degraded = true
        }
        if phaseOne.adoptsManifest, let manifest = phaseOne.decoded.manifest {
            self.state.core.appliedManifest = manifest
            self.state.core.etag = nil
        }
        self.state.core.records = phaseOne.records
        self.state.migration.legacyStamp = stamp
        self.state.migration.phase = .inProgress
        self.markDirty(.soon)
    }

    /// The ids of `file` whose records still want its bytes (REENTRANCY R11): they expect its digest, accept adoption
    /// and name a valid extension.
    func legacyWanters(_ file: LegacyFile) -> [AssetID] {
        LegacyDecoding.wanters(of: file, in: self.state.core.records)
    }

    /// Whether some record of `file` already holds its bytes (adopted earlier, by launch reconciliation or on demand).
    func legacyAdopted(_ file: LegacyFile) -> Bool {
        LegacyDecoding.adopted(file, in: self.state.core.records)
    }

    // MARK: Phase 2 (after open())

    /// What processing one legacy file did.
    enum LegacyOutcome: Sendable, Hashable {
        /// Its bytes verified and its records were bound to them.
        case adopted
        /// Another call adopted it meanwhile: a batch and an adopt-on-demand, or two adopt-on-demand calls, processed it
        /// at once, and this call waited out that adoption before deciding (orchestrator ruling L5K-R13).
        case alreadyAdopted
        /// Its bytes did not verify, or it vanished, or no record wants it any more.
        case dropped
        /// Reading or moving it failed with an error that says nothing about its bytes (I/O, a full volume, a refused
        /// permission): it goes back to the head of the queue and the batch ends (review of the L3 close-out, ZProbe-hash),
        /// so phases 3 and 4 never run while it waits (`deferLegacyFile`).
        case deferred
    }

    /// Attempts of one legacy file per lifetime before it is kept where it is (`deferLegacyFile`): a file that cannot be
    /// read or moved three times in a row is left in the legacy tree, never removed by phase 4, and its asset is downloaded
    /// again, so a permanently unreadable file cannot hold migration back forever.
    static let legacyAttempts = 3

    /// Whether `error` (not a lifecycle error) says nothing about a legacy file's bytes, so its processing is retried
    /// rather than the file dropped: any file-system error but a missing file (it vanished) or a cross-device rename (a
    /// root on another volume is dropped, C-14), and a volume too full to place it.
    static func isTransientLegacyFailure(_ error: StoreError) -> Bool {
        switch error {
        case .fileSystem(.notFound), .fileSystem(.crossDevice):
            return false
        case .fileSystem, .insufficientSpace:
            return true
        default:
            return false
        }
    }

    /// Hashes one legacy file and adopts it for the records that still want it (hash, re-validate, `adoptVerifiedFile`).
    /// Throws only the lifecycle and cancellation errors; a transient failure defers the file, every other one drops it.
    ///
    /// At most one adoption of a file runs at a time (orchestrator ruling L5K-R13). Two calls may hash the same file at
    /// once (an adopt-on-demand of a file a batch holds but has not finished hashing, so a lookup never waits behind a
    /// batch's hash); the first whose bytes verify marks the file in `MigrationState.adopting` in the turn it decides, and
    /// the other, whatever its own hash gave, waits out that adoption before it decides from the records
    /// (`awaitLegacyAdoption`). So a file the other call renamed away (a `notFound` read) or is placing (its key in
    /// `publishing`) reads as `alreadyAdopted`, never as dropped or deferred. The callers start it only while no adoption
    /// of the file is in flight: a batch on a file it just took from the queue, an adopt-on-demand only after it found
    /// none (`performAdoptLegacyNow`).
    func processLegacyFile(_ file: LegacyFile) async throws(StoreError) -> LegacyOutcome {
        guard let root = self.state.migration.root, !self.legacyWanters(file).isEmpty else {
            return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
        }
        let url = file.components.dropLast().reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent(file.components.last ?? "", isDirectory: false)
        let hashed: (digest: ContentHash, byteCount: Int64)
        do throws(StoreError) {
            // REENTRANCY: R11, R18 — after the hash: the phase; another call's adoption of the file is waited out before
            // anything is decided (k-6, below); the records still expect the digest (`legacyWanters` below); the file's
            // bytes are what was planned (the digest and size checks).
            hashed = try await self.hashFile(at: url)
        } catch {
            try AssetStore.rethrowLifecycle(error)
            // REENTRANCY: k-6 (proposed) — a racing adoption may have renamed the file away: its outcome is waited for,
            // then the records decide (`legacyFailureOutcome`).
            try await self.awaitLegacyAdoption(of: file)
            return self.legacyFailureOutcome(file, error)
        }
        try self.checkLive()
        // REENTRANCY: k-6 (proposed) — the records below are read once no other call's adoption of the file is in flight.
        try await self.awaitLegacyAdoption(of: file)
        let wanting = self.legacyWanters(file)
        guard hashed.digest == file.digest, file.byteSize.map({ $0 == hashed.byteCount }) ?? true, !wanting.isEmpty else {
            return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
        }
        // No other adoption of the file is in flight in this turn (the wait above): this call's starts.
        self.state.migration.adopting[file.components] = []
        let locations: [AssetID: AssetLocation]
        do throws(StoreError) {
            // REENTRANCY: R11, R18, R3, R4 — `adoptVerifiedFile` re-validates every record after its placement unit and
            // binds only those that still expect the digest; this call's mark in `adopting` keeps every other call that
            // processes the file waiting until the binding is done (k-5, k-6).
            locations = try await self.adoptVerifiedFile(at: url, digest: hashed.digest, byteCount: hashed.byteCount, for: wanting)
        } catch {
            self.endLegacyAdoption(of: file)
            try AssetStore.rethrowLifecycle(error)
            return self.legacyFailureOutcome(file, error)
        }
        self.endLegacyAdoption(of: file)
        if !locations.isEmpty {
            return .adopted
        }
        return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
    }

    /// Waits until no other call's adoption of `file` is in flight (`MigrationState.adopting`) and returns in the turn in
    /// which none is, so the caller decides from the records as that adoption left them and may start its own adoption in
    /// that turn (L5K-R13). Throws the store's shutdown answer when it closed meanwhile: `close()` lets the adopting call's
    /// units finish and resumes its key waiters, so that call ends (with `.closed`) and resumes this one.
    func awaitLegacyAdoption(of file: LegacyFile) async throws(StoreError) {
        while self.state.migration.adopting[file.components] != nil {
            self.environment.log.log(.store, .debug, "a legacy file's processing waits for another call's adoption of the same legacy file")
            // REENTRANCY: k-6 (proposed) — the loop re-reads `adopting` and the phase (`checkLive`) once that adoption ended;
            // the caller then reads the records anew.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if self.state.migration.adopting[file.components] != nil {
                    self.state.migration.adopting[file.components]?.append(continuation)
                } else {
                    continuation.resume()
                }
            }
            try self.checkLive()
        }
    }

    /// Ends this call's adoption of `file`: the mark goes and every call waiting for it is resumed; each re-reads the
    /// records (REENTRANCY k-5, k-6).
    func endLegacyAdoption(of file: LegacyFile) {
        guard let waiters = self.state.migration.adopting.removeValue(forKey: file.components) else {
            return
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// The outcome of a file whose hash or move failed with `error`, once no other call's adoption of it is in flight (a
    /// racing placement renames the file away before it binds, L5K-R13): adopted by that call, deferred when the error
    /// says nothing about the file (`isTransientLegacyFailure`), dropped otherwise.
    func legacyFailureOutcome(_ file: LegacyFile, _ error: StoreError) -> LegacyOutcome {
        if self.legacyAdopted(file) {
            return .alreadyAdopted
        }
        return AssetStore.isTransientLegacyFailure(error) ? .deferred : .dropped
    }

    /// Puts a deferred file back at the head of the queue, or, at its `legacyAttempts`-th deferral in this lifetime, keeps
    /// it where it is: out of the queue, counted dropped (its asset is downloaded again) and out of phase 4's removal set
    /// (`MigrationState.kept`). Returns whether it was kept.
    func deferLegacyFile(_ file: LegacyFile) -> Bool {
        let attempts = (self.state.migration.deferrals[file.components] ?? 0) + 1
        self.state.migration.deferrals[file.components] = attempts
        guard attempts >= AssetStore.legacyAttempts else {
            self.unclaimLegacyFile(file, requeue: true)
            return false
        }
        self.unclaimLegacyFile(file, requeue: false)
        self.state.migration.kept.insert(file.components)
        self.count(.dropped)
        self.environment.log.log(.store, .error, "a legacy file could not be read or moved; it is left where it is and downloaded again")
        return true
    }

    /// Rethrows the errors that end a migration call (the store closing, the caller's cancellation, a lifetime that
    /// cannot write); every other error is a property of one file.
    static func rethrowLifecycle(_ error: StoreError) throws(StoreError) {
        switch error {
        case .closed, .notOpen, .cancelled, .storageUnavailable:
            throw error
        default:
            return
        }
    }

    /// `migrateLegacy(maxFiles:)`. No call suspends behind a coalesced publication of its own (orchestrator ruling
    /// L5K-R20): a batch that leaves files to process publishes at bulk urgency and, when that left the trailing install
    /// due, returns right after it (`remaining > 0`, `finished` false), so the engine schedules that install before it
    /// calls again; the last batch, which phases 3 and 4 follow in the same call, installs at once. What is left is read
    /// after the publication returned, never before it (orchestrator ruling L5K-R23): an install that suspends at the sink
    /// lets an adopt-on-demand of the last claimed file end meanwhile, and a batch that then finds nothing left installs at
    /// once and goes on to phases 3 and 4 rather than returning "nothing remaining, not finished", the caller's back-off
    /// signal (RE-S29). Only a call with no install of its own left due waits for an adopt-on-demand of the last claimed
    /// files (L5K-R17).
    func performMigrateLegacy(maxFiles: Int) async throws(StoreError) -> LegacyMigrationProgress {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        let nothing = LegacyMigrationProgress(adopted: 0, remaining: 0, dropped: 0, finished: true)
        guard let root = self.state.migration.root else {
            return nothing
        }
        switch self.state.migration.phase {
        case .notStarted:
            return nothing
        case .done:
            if !self.state.migration.progress.finished {
                // "done" may be in memory only: the call that wrote it throws when its durable commit fails, and a retry
                // (or a second call while the first one waits) must not remove what that commit protects.
                // REENTRANCY: R17 — nothing but the phase: `done` is terminal and was written before this call.
                try await self.requireCommitted(.durable)
                // REENTRANCY: c-4 (proposed) — see `finishLegacyRemoval`.
                try await self.finishLegacyRemoval(root)
            }
            return self.state.migration.progress
        case .inProgress:
            break
        }
        // REENTRANCY: R17 — nothing but the phase: the queue and the claims are read after it, and a call that finished the
        // migration meanwhile left them empty.
        try await self.commitLegacyPlanIfNeeded()
        var budget = max(0, maxFiles)
        var adoptedAny = false
        while budget > 0, let file = self.state.migration.queue.popLast() {
            self.state.migration.claimed.append(file)
            let outcome: LegacyOutcome
            do throws(StoreError) {
                // REENTRANCY: R11, k-6 (proposed) — `processLegacyFile` re-validates after each of its awaits and waits out
                // another call's adoption of the file before it decides; the queue and the claims are this call's own (an
                // adopt-on-demand of a claimed file never counts it).
                outcome = try await self.processLegacyFile(file)
            } catch {
                self.unclaimLegacyFile(file, requeue: true)
                throw error
            }
            budget -= 1
            if outcome == .deferred {
                guard self.deferLegacyFile(file) else {
                    // The file waits at the head of the queue for a later batch; this one ends, so no phase 3 or 4 runs.
                    break
                }
                continue
            }
            self.unclaimLegacyFile(file, requeue: false)
            self.count(outcome)
            adoptedAny = adoptedAny || outcome == .adopted
        }
        if adoptedAny {
            // A batch publishes at bulk urgency, and inside the install window that only marks the trailing install due,
            // which only the engine's alarm runs once the engine re-reads the deadline after this call: so no call waits
            // or runs a later phase behind a coalesced publication (orchestrator ruling L5K-R20). With files left (queued,
            // or claimed by an adopt-on-demand) the call returns right after it, with `remaining > 0`, and the next call
            // goes on. With nothing left, phases 3 and 4 follow in this call, so the batch installs at once instead: a
            // return then would read "nothing remaining, not finished", which tells the caller to back off (RE-S29).
            let last = self.state.migration.queue.isEmpty && self.state.migration.claimed.isEmpty
            // REENTRANCY: R17 — the queue, the claims and `installDue`, read again below: the adoptions were bound before
            // the await, but an install that suspends at the sink lets an adopt-on-demand of the last claimed file end
            // meanwhile, which unclaims the file and publishes inside the window this install closed (L5K-C4-00).
            await self.publishSnapshot(urgency: last ? .userInitiated : .bulk)
            if self.state.core.snapshots.installDue {
                // What is left is read after the publication (orchestrator ruling L5K-R23): with files left the call
                // returns with `remaining > 0`; with none, phases 3 and 4 follow, so what is due installs at once first, an
                // adoption that an adopt-on-demand ended during this call's install included.
                guard self.state.migration.queue.isEmpty, self.state.migration.claimed.isEmpty else {
                    return self.state.migration.progress
                }
                // REENTRANCY: R17 — nothing but the phase: nothing is queued or claimed, and a file returns to the queue
                // only from the claims, so nothing is left after this await either; the finish check below re-reads the
                // queue, the claims and the phase.
                await self.publishSnapshot(urgency: .userInitiated)
            }
        }
        // With the queue empty and every claimed file an adopt-on-demand's (from its claim to its snapshot), this call can
        // only wait: returning would make its caller call again at once, a hot loop for as long as that adoption hashes
        // (orchestrator ruling L5K-R17). It waits for one such processing at a time, then re-reads the queue, the claims
        // and the phase, so it finishes the migration itself once the last one ended. Each wait is bounded by one
        // adoption, and `close()` resumes it through that adoption (row k-5). A call gets here with no install of its own
        // left due (L5K-R20), and phases 3 and 4 publish no snapshot.
        while self.state.migration.queue.isEmpty, self.state.migration.phase == .inProgress,
              let held = self.state.migration.claimed.first,
              self.state.migration.claimed.allSatisfy({ self.state.migration.onDemand[$0.components] != nil })
        {
            self.environment.log.log(.store, .debug, "a migration batch waits for an adopt-on-demand of the last claimed legacy files")
            // REENTRANCY: k-7 (proposed) — the queue, the claims and the phase are re-read once that processing ended
            // (adopted, dropped or kept: no longer claimed; deferred or cancelled: back in the queue, which ends the wait);
            // `checkLive` answers a closing store.
            await self.awaitLegacyFlight(of: held)
            try self.checkLive()
        }
        if self.state.migration.queue.isEmpty, self.state.migration.claimed.isEmpty, self.state.migration.phase == .inProgress {
            // REENTRANCY: R17, c-4 (proposed) — see `finishLegacyMigration`.
            try await self.finishLegacyMigration(root)
        }
        return self.state.migration.progress
    }

    /// Commits the phase-1 plan before the first legacy file of this lifetime moves (ADR draft C-13): phase 1's own commit
    /// may have failed, and a relaunch counts the loaded plan committed only once its barrier or a commit succeeded.
    func commitLegacyPlanIfNeeded() async throws(StoreError) {
        guard !self.state.migration.planCommitted else {
            return
        }
        // REENTRANCY: R17 — nothing but the phase: phase 1's writes were made before this call; the callers re-read the
        // migration state after it.
        try await self.requireCommitted(.ordered)
        self.state.migration.planCommitted = true
    }

    /// Removes `file` from the claims, back to the head of the queue (its end) when its processing did not complete.
    func unclaimLegacyFile(_ file: LegacyFile, requeue: Bool) {
        if let index = self.state.migration.claimed.firstIndex(of: file) {
            self.state.migration.claimed.remove(at: index)
        }
        if requeue {
            self.state.migration.queue.append(file)
        }
        self.state.migration.progress.remaining = self.state.migration.queue.count + self.state.migration.claimed.count
    }

    /// Counts one processed file.
    func count(_ outcome: LegacyOutcome) {
        switch outcome {
        case .adopted:
            self.state.migration.progress.adopted += 1
        case .dropped:
            self.state.migration.progress.dropped += 1
        case .alreadyAdopted, .deferred:
            break
        }
    }

    // MARK: Phases 3 and 4

    /// Phase 3, then phase 4: the stamp migrates only when the applied manifest is still the legacy one phase 1 decoded
    /// and every one of its entries is present at its current content (and never over a newer stamp); otherwise a sync
    /// is made due. The "done" generation is committed **durably** before the irrevocable removal of the tree and of the
    /// `UserDefaults` key.
    func finishLegacyMigration(_ root: URL) async throws(StoreError) {
        // REENTRANCY: c-7 (proposed) — see `legacyEntriesPresent`, which returns in the turn its answer holds for; then
        // writability and the migration: a call that finished it meanwhile, or a file back in the queue, leaves it here.
        let answer = try await self.legacyEntriesPresent()
        try self.checkWritable()
        guard self.state.migration.phase == .inProgress, self.state.migration.queue.isEmpty, self.state.migration.claimed.isEmpty else {
            return
        }
        guard let present = answer else {
            // Every pass was interrupted by a counted mutation (access stamps, pins, publications): the next call checks
            // again, rather than this one checking every entry in one turn (35–40 ms at `maxEntries`, close-out cycle 4).
            self.environment.log.log(.store, .info, "legacy phase 3's check was interrupted in every pass; the next call decides")
            return
        }
        let migration = self.state.migration
        // A manifest applied during migration (the engine synced, or an interrupted run resumed after an apply) may list
        // entries nobody fetched: a stamp over its digest would claim them synced (review round 3, ZProbe-stamp).
        let current = migration.manifestDigest.map { $0 == self.state.core.appliedManifest.digest } ?? false
        let allAdopted = current && present
        if self.state.core.stamp == nil {
            if allAdopted, let legacyStamp = migration.legacyStamp {
                self.state.core.stamp = SyncStamp(
                    appVersion: legacyStamp,
                    completedAt: self.environment.time.now(),
                    manifestETag: self.state.core.etag,
                    manifestDigest: self.state.core.appliedManifest.digest
                )
            } else if !allAdopted {
                self.state.core.syncDue = true
            }
        }
        self.state.migration.phase = .done
        self.markDirty(.soon)
        // REENTRANCY: R17 — nothing but the phase: phase 3 was written synchronously above.
        try await self.requireCommitted(.durable)
        // REENTRANCY: c-4 (proposed) — see `finishLegacyRemoval`.
        try await self.finishLegacyRemoval(root)
    }

    /// Ids phase 3's check reads between two releases of the actor (C2 at `maxEntries`: one turn over 100,000 legacy
    /// entries took 26 ms in release, review of the L3 close-out cycle 2); `MigrationState.checkChunk`.
    static let legacyCheckChunk = 5_000

    /// Passes of phase 3's chunked check that a mutation may interrupt before the call leaves phase 3 to the next call.
    static let legacyCheckPasses = 3

    /// Phase 3's check: whether every legacy entry is present at its current content, as of the turn it returns in, or
    /// `nil` when no pass could answer. The entries are read in chunks of `MigrationState.checkChunk` with the actor
    /// released in between (a no-op metadata unit); a pass answers "yes" only if no mutation was counted meanwhile
    /// (`CommitBookkeeping.mutationSerial`, which every persisted change bumps in its own turn through `markDirty`), else
    /// it starts again. After `MigrationState.checkPasses` interrupted passes the answer is `nil`: a check of every entry
    /// in one turn would hold the actor 35–40 ms at `maxEntries` (review of close-out cycle 3: reachable whenever access
    /// stamps or pins arrive during the check), so the caller decides nothing and the next call checks again. A store of
    /// at most one chunk of legacy entries is checked in one turn and always answers. An entry found missing is missing
    /// in that turn, so "no" needs no such guard.
    func legacyEntriesPresent() async throws(StoreError) -> Bool? {
        let ids = self.state.migration.legacyIDs
        let chunk = max(1, self.state.migration.checkChunk)
        for _ in 0..<max(1, self.state.migration.checkPasses) {
            let serial = self.state.core.commits.mutationSerial
            var start = 0
            while start < ids.count {
                let end = min(start + chunk, ids.count)
                guard LegacyDecoding.present(ids[start..<end], in: self.state.core.records) else {
                    return false
                }
                start = end
                if start < ids.count {
                    // REENTRANCY: c-7 (proposed) — the phase; the pass answers only if no mutation was counted meanwhile.
                    await self.runUnit(on: self.environment.metadataExecutor) {}
                    try self.checkLive()
                }
            }
            if self.state.core.commits.mutationSerial == serial {
                return true
            }
        }
        return nil
    }

    /// Phase 4: the tree, then the key (only once the tree is done, so the order holds when a call stops part way).
    /// Idempotent: a crash or an error part way is finished by the next call.
    func finishLegacyRemoval(_ root: URL) async throws(StoreError) {
        // REENTRANCY: c-4 (proposed) — the phase and the caller's cancellation (inside); after the durable "done" commit
        // the tree and the key are the migration's alone, and every step of the removal is idempotent.
        let removed = try await self.removeLegacyTree(root)
        if removed {
            // REENTRANCY: c-4 (proposed) — as above.
            await self.removeLegacyStamp()
        }
        try self.checkLive()
        self.state.migration.progress.remaining = 0
        self.state.migration.progress.finished = removed
    }

    // MARK: Adopt on demand

    /// `adoptLegacyNow(_:urgency:)`: the current location when the asset is present; otherwise, while migration runs,
    /// adopts its legacy file now and publishes the snapshot at `urgency` (at once for `.userInitiated`, L5K-R14). A
    /// `.userInitiated` call installs the snapshot before it answers an asset that is present already too, since the
    /// adoption that made it present may be in a coalesced snapshot only (orchestrator ruling L5K-R18); a `.bulk` or
    /// `.prefetch` call answers it at once. Each adoption is counted once, by the call that adopted the file; a drop only by
    /// the call that took the file from the queue.
    ///
    /// One adoption per legacy file, whoever asks (orchestrator ruling L5K-R13). A call that finds the file being
    /// processed by another adopt-on-demand (`MigrationState.onDemand`, from its claim to its snapshot) or being adopted by
    /// a batch (`MigrationState.adopting`) waits for that processing to end and starts again (REENTRANCY k-5): it shares
    /// that hash and answers the location that adoption bound, published at its own urgency; it answers `nil` only when
    /// the file was dropped or kept; and when the processing ended without an outcome for the file (its caller was
    /// cancelled, or a transient failure deferred it back to the queue) it takes the file and processes it itself, as a
    /// call arriving then would. A file a batch holds but has not finished hashing is processed at once (the two hashes
    /// may overlap, one adoption still binds, `processLegacyFile`): a lookup never waits behind a batch's hash.
    func performAdoptLegacyNow(_ id: AssetID, urgency: AssetPriority) async throws(StoreError) -> AssetLocation? {
        var joined = false
        while true {
            // REENTRANCY: R1, k-5 (proposed) — nothing was read before it, or everything is read again below after a wait;
            // `awaitOpen` re-reads the phase itself.
            try await self.awaitOpen()
            if let location = self.location(for: id, extensions: [], recordingAccess: false) {
                guard joined || urgency == .userInitiated else {
                    return location
                }
                // The adoption this call waited for, or one that ended before it asked (a batch's, a bulk-lane call's), may
                // be in a coalesced snapshot only: this call publishes at its own urgency, so a user-initiated one installs
                // its answer at once, whoever adopted the file (L5K-R14; orchestrator ruling L5K-R18: a job promoted to the
                // user-initiated lane during its bulk adoption asks again at this urgency).
                // REENTRANCY: R17 — nothing but the phase: the location is read from the record afterwards.
                await self.publishSnapshot(urgency: urgency)
                return self.location(for: id, extensions: [], recordingAccess: false)
            }
            try self.checkWritable()
            guard self.state.migration.phase == .inProgress else {
                return nil
            }
            if !self.state.migration.planCommitted {
                // No legacy file moves before a generation holding the phase-1 plan is committed, on demand too (C-13).
                // REENTRANCY: R17, R18 — then the call starts again: the location, the phase, the queue, the claims and the
                // files in flight are read anew (a batch may have adopted the asset meanwhile).
                try await self.commitLegacyPlanIfNeeded()
                continue
            }
            let migration = self.state.migration
            // One linear search per call (adopt-on-demand serves a lookup miss); batches take files from the end in O(1).
            let queued = migration.queue.lastIndex { $0.ids.contains(id) }
            guard let file = queued.map({ migration.queue[$0] }) ?? migration.claimed.first(where: { $0.ids.contains(id) }) else {
                return nil
            }
            if migration.onDemand[file.components] != nil || migration.adopting[file.components] != nil {
                joined = true
                self.environment.log.log(.store, .debug, "an adopt-on-demand waits for the processing of the same legacy file in flight")
                // REENTRANCY: k-5 (proposed) — then the call starts again and reads everything anew: the processing it
                // waited for has ended (adopted: the location is present; dropped or kept: the file is neither queued nor
                // claimed; cancelled or deferred: the file is back in the queue and this call takes it).
                await self.awaitLegacyFlight(of: file)
                continue
            }
            if let queued {
                self.state.migration.queue.remove(at: queued)
                self.state.migration.claimed.append(file)
            }
            self.state.migration.onDemand[file.components] = []
            // REENTRANCY: R18, k-6 (proposed) — the file is this call's to process (claimed or held by a batch, marked in
            // `onDemand`); `processLegacyFileOnDemand` re-reads the location from the record after its awaits.
            return try await self.processLegacyFileOnDemand(file, id: id, taken: queued != nil, urgency: urgency)
        }
    }

    /// Processes `file` for an adopt-on-demand of `id` that marked it in `MigrationState.onDemand` (and took it from the
    /// queue when `taken`), books the outcome, publishes the snapshot at `urgency`, then ends the mark, so the
    /// adopt-on-demand calls waiting for it find the adoption published.
    func processLegacyFileOnDemand(_ file: LegacyFile, id: AssetID, taken: Bool, urgency: AssetPriority) async throws(StoreError) -> AssetLocation? {
        let outcome: LegacyOutcome
        do throws(StoreError) {
            // REENTRANCY: R18, k-6 (proposed) — `processLegacyFile` re-validates after each await and waits out another
            // call's adoption of the file before it decides; a batch that adopted the file meanwhile wins and the location
            // is read from the record below.
            outcome = try await self.processLegacyFile(file)
        } catch {
            if taken {
                self.unclaimLegacyFile(file, requeue: true)
            }
            self.endLegacyOnDemand(file)
            throw error
        }
        if taken, outcome == .deferred {
            _ = self.deferLegacyFile(file)
        } else if taken {
            self.unclaimLegacyFile(file, requeue: false)
            self.count(outcome)
        } else if outcome == .adopted {
            // A batch holds the file and will see it adopted (`alreadyAdopted`, uncounted): this call counts it.
            self.count(outcome)
        }
        // REENTRANCY: R17, R18 — nothing but the phase: the location is read from the record afterwards; the calls waiting
        // for this one are resumed only after the publication (`endLegacyOnDemand` below).
        await self.publishSnapshot(urgency: urgency)
        self.endLegacyOnDemand(file)
        return self.location(for: id, extensions: [], recordingAccess: false)
    }

    /// Suspends until the processing of `file` that an adopt-on-demand must not duplicate has ended: another
    /// adopt-on-demand's (`MigrationState.onDemand`, which ends after its snapshot), otherwise another call's adoption
    /// (`MigrationState.adopting`). Returns at once when neither is in flight. `close()` lets that call's units finish and
    /// resumes its key and commit waiters, so it ends (with `.closed`) and resumes this one.
    func awaitLegacyFlight(of file: LegacyFile) async {
        // REENTRANCY: k-5 (proposed) — nothing here: the caller starts its call again and reads everything anew.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.state.migration.onDemand[file.components] != nil {
                self.state.migration.onDemand[file.components]?.append(continuation)
            } else if self.state.migration.adopting[file.components] != nil {
                self.state.migration.adopting[file.components]?.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    /// Ends an adopt-on-demand's processing of `file`: the mark goes and the adopt-on-demand calls waiting for it are
    /// resumed; each starts again (REENTRANCY k-5).
    func endLegacyOnDemand(_ file: LegacyFile) {
        guard let waiters = self.state.migration.onDemand.removeValue(forKey: file.components) else {
            return
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Decoding the prior art's metadata files and planning (pure; run in a bulk unit, C2).
enum LegacyDecoding {
    /// What phase 1 learns from the prior art's files.
    struct Decoded: Sendable {
        /// The legacy manifest, when it decoded.
        var manifest: ValidatedManifest?
        /// It was present but could not be read whole or decoded.
        var undecodable: Bool
        /// The local checksums (an unusable file reads as none).
        var checksums: [String: String]
        /// The plan over `files`.
        var plan: LegacyPlan
    }

    /// The legacy manifest decoded under `limits` with duplicate identifiers keeping the first (store.md §7, RECON
    /// D-13), whether it was present but undecodable, the local checksums, and the plan over the listed `files`.
    static func decode(manifest: LegacyRead, checksums: LegacyRead, limits: ManifestLimits, files: Set<[String]>) -> Decoded {
        var decoded: ValidatedManifest?
        var undecodable = false
        switch manifest {
        case .absent:
            break
        case .unusable, .failed:
            // Phase 1 and phase 4 never decode a failed read (they decide nothing from it); treated as undecodable here.
            undecodable = true
        case .bytes(let data):
            do throws(ManifestError) {
                decoded = try ManifestDecoder.decode(data, options: ManifestDecodingOptions(limits: limits, duplicates: .keepFirst))
            } catch {
                undecodable = true
            }
        }
        var table: [String: String] = [:]
        if case .bytes(let data) = checksums {
            table = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        let plan = LegacyPlanner.plan(entries: decoded?.entries ?? [], checksums: table, files: files)
        return Decoded(manifest: decoded, undecodable: undecodable, checksums: table, plan: plan)
    }

    /// What phase 1 decides, computed in its bulk unit (C2 at `maxEntries`: the record writes and the queue were two
    /// actor turns of about 100 and 60 ms over 100,000 legacy files, review of the L3 close-out cycle 2).
    struct PhaseOne: Sendable {
        /// What the prior art's files decoded to.
        var decoded: Decoded
        /// The store's records with phase 1's inserts (the snapshot unchanged unless `starting`).
        var records: [AssetID: AssetRecord]
        /// Whether the legacy manifest becomes the applied one (only while none is applied).
        var adoptsManifest: Bool
        /// The files some record still wants, in **reverse** path order (`MigrationState.queue`).
        var queue: [LegacyFile]
        /// Entries dropped while planning, files no record wants or holds, and unlisted entries no record holds.
        var dropped: Int
    }

    /// Phase 1 over snapshots of the store's `records` and `applied` manifest: decodes the prior art's files, makes phase
    /// 1's record writes when `starting` (as `AssetStore.applyLegacyPlanWrites(_:stamp:)` documents), then queues the
    /// planned files that a record still wants. An entry whose file is no longer in the tree was adopted by an earlier
    /// lifetime when its record holds the bytes it expected (moved into `blobs/`); otherwise it is dropped.
    static func phaseOne(
        manifest: LegacyRead,
        checksums: LegacyRead,
        limits: ManifestLimits,
        tree: LegacyTree,
        starting: Bool,
        records: [AssetID: AssetRecord],
        applied: ValidatedManifest,
        now: Date
    ) -> PhaseOne {
        let decoded = LegacyDecoding.decode(manifest: manifest, checksums: checksums, limits: limits, files: tree.files)
        var records = records
        var adoptsManifest = false
        if starting, let legacy = decoded.manifest {
            var current = applied
            if current.entries.isEmpty {
                current = legacy
                adoptsManifest = true
            }
            for entry in legacy.entries where records[entry.identifier] == nil {
                guard let listed = current.entry(for: entry.identifier) else {
                    continue
                }
                let planned = entry.checksum ?? LegacyPlanner.localDigest(decoded.checksums[entry.identifier.rawValue])
                let expected = listed.checksum ?? (listed.contentIdentity == entry.contentIdentity ? planned : nil)
                records[entry.identifier] = AssetRecord(entry: listed, residency: .absent(.neverFetched), expectedBlob: expected, lastAccess: now)
            }
        }
        var queue: [LegacyFile] = []
        var dropped = decoded.plan.dropped
        for file in decoded.plan.files {
            if !LegacyDecoding.wanters(of: file, in: records).isEmpty {
                queue.append(file)
            } else if !LegacyDecoding.adopted(file, in: records) {
                dropped += 1
            }
        }
        dropped += decoded.plan.unlisted.filter { !LegacyDecoding.adopted($0, in: records) }.count
        queue.reverse()
        return PhaseOne(decoded: decoded, records: records, adoptsManifest: adoptsManifest, queue: queue, dropped: dropped)
    }

    /// The ids of `file` whose records in `records` still want its bytes: they expect its digest, accept adoption and
    /// name a valid extension.
    static func wanters(of file: LegacyFile, in records: [AssetID: AssetRecord]) -> [AssetID] {
        file.ids.filter { id in
            guard let record = records[id] else {
                return false
            }
            return record.expectedBlob == file.digest && record.acceptsAdoption && AssetFileExtension(record.entry.fileExtension) != nil
        }
    }

    /// Whether some record of `file` in `records` already holds its bytes.
    static func adopted(_ file: LegacyFile, in records: [AssetID: AssetRecord]) -> Bool {
        file.ids.contains { records[$0]?.referencedBlob?.hash == file.digest }
    }

    /// Whether every id of `ids` has a record in `records` that holds a blob of its current content (phase 3).
    static func present(_ ids: ArraySlice<AssetID>, in records: [AssetID: AssetRecord]) -> Bool {
        ids.allSatisfy { id in
            guard let record = records[id] else {
                return false
            }
            return record.referencedBlob != nil && !record.isStale
        }
    }

    /// Whether the record of an entry whose file is not in the tree holds the bytes the entry expected.
    static func adopted(_ entry: LegacyUnlisted, in records: [AssetID: AssetRecord]) -> Bool {
        guard let digest = entry.digest else {
            return false
        }
        return records[entry.id]?.referencedBlob?.hash == digest
    }
}
