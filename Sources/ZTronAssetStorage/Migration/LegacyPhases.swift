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
        /// Someone else adopted it meanwhile (a batch and an adopt-on-demand raced).
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
    func processLegacyFile(_ file: LegacyFile) async throws(StoreError) -> LegacyOutcome {
        guard let root = self.state.migration.root, !self.legacyWanters(file).isEmpty else {
            return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
        }
        let url = file.components.dropLast().reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent(file.components.last ?? "", isDirectory: false)
        let hashed: (digest: ContentHash, byteCount: Int64)
        do throws(StoreError) {
            // REENTRANCY: R11, R18 — after the hash: the phase; the records still expect the digest (`legacyWanters`
            // below); the file's bytes are what was planned (the digest and size checks).
            hashed = try await self.hashFile(at: url)
        } catch {
            try AssetStore.rethrowLifecycle(error)
            return self.legacyFailureOutcome(file, error)
        }
        try self.checkLive()
        let wanting = self.legacyWanters(file)
        guard hashed.digest == file.digest, file.byteSize.map({ $0 == hashed.byteCount }) ?? true, !wanting.isEmpty else {
            return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
        }
        do throws(StoreError) {
            // REENTRANCY: R11, R18, R3, R4 — `adoptVerifiedFile` re-validates every record after its placement unit and
            // binds only those that still expect the digest.
            let locations = try await self.adoptVerifiedFile(at: url, digest: hashed.digest, byteCount: hashed.byteCount, for: wanting)
            if !locations.isEmpty {
                return .adopted
            }
        } catch {
            try AssetStore.rethrowLifecycle(error)
            return self.legacyFailureOutcome(file, error)
        }
        return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
    }

    /// The outcome of a file whose hash or move failed with `error`: adopted by a racing call, deferred when the error
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

    /// `migrateLegacy(maxFiles:)`.
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
                // REENTRANCY: R11 — `processLegacyFile` re-validates after each of its awaits; the queue and the claims
                // are this call's own (an adopt-on-demand of a claimed file never counts it).
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
            // REENTRANCY: R17 — nothing but the phase: the adoptions were bound before the await.
            await self.publishSnapshot(urgency: .bulk)
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
        let present = try await self.legacyEntriesPresent()
        try self.checkWritable()
        guard self.state.migration.phase == .inProgress, self.state.migration.queue.isEmpty, self.state.migration.claimed.isEmpty else {
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

    /// Passes of phase 3's chunked check that a mutation may interrupt before the check is made in one turn.
    static let legacyCheckPasses = 3

    /// Phase 3's check: whether every legacy entry is present at its current content, as of the turn it returns in. The
    /// entries are read in chunks of `MigrationState.checkChunk` with the actor released in between (a no-op metadata
    /// unit); a pass answers "yes" only if no mutation was counted meanwhile (`CommitBookkeeping.mutationSerial`, which
    /// every persisted change bumps in its own turn through `markDirty`), else it starts again; after
    /// `MigrationState.checkPasses` interrupted passes the check is made in one turn. An entry found missing is missing in that
    /// turn, so "no" needs no such guard.
    func legacyEntriesPresent() async throws(StoreError) -> Bool {
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
        return LegacyDecoding.present(ids[...], in: self.state.core.records)
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

    /// `adoptLegacyNow(_:)`: the current location when the asset is present; otherwise, while migration runs, adopts its
    /// legacy file now and installs the snapshot at once. Each adoption is counted once, by the call that adopted the
    /// file; a drop only by the call that took the file from the queue.
    func performAdoptLegacyNow(_ id: AssetID) async throws(StoreError) -> AssetLocation? {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        if let location = self.location(for: id, extensions: [], recordingAccess: false) {
            return location
        }
        try self.checkWritable()
        guard self.state.migration.phase == .inProgress else {
            return nil
        }
        if !self.state.migration.planCommitted {
            // No legacy file moves before a generation holding the phase-1 plan is committed, on demand too (C-13).
            // REENTRANCY: R17, R18 — then the call starts again: the location, the phase, the queue and the claims are
            // read anew (a batch may have adopted the asset meanwhile).
            try await self.commitLegacyPlanIfNeeded()
            // REENTRANCY: R18 — as above.
            return try await self.performAdoptLegacyNow(id)
        }
        let migration = self.state.migration
        // One linear search per call (adopt-on-demand serves a lookup miss); batches take files from the end in O(1).
        let queued = migration.queue.lastIndex { $0.ids.contains(id) }
        guard let file = queued.map({ migration.queue[$0] }) ?? migration.claimed.first(where: { $0.ids.contains(id) }) else {
            return nil
        }
        if let queued {
            self.state.migration.queue.remove(at: queued)
            self.state.migration.claimed.append(file)
        }
        let outcome: LegacyOutcome
        do throws(StoreError) {
            // REENTRANCY: R18 — `processLegacyFile` re-validates after each await; a batch that adopted the file meanwhile
            // wins and the location is read from the record below.
            outcome = try await self.processLegacyFile(file)
        } catch {
            if queued != nil {
                self.unclaimLegacyFile(file, requeue: true)
            }
            throw error
        }
        if queued != nil, outcome == .deferred {
            _ = self.deferLegacyFile(file)
        } else if queued != nil {
            self.unclaimLegacyFile(file, requeue: false)
            self.count(outcome)
        } else if outcome == .adopted {
            // A batch holds the file and will see it adopted (`alreadyAdopted`, uncounted): this call counts it.
            self.count(outcome)
        }
        // REENTRANCY: R17, R18 — nothing but the phase: the location is read from the record afterwards.
        await self.publishSnapshot(urgency: .userInitiated)
        return self.location(for: id, extensions: [], recordingAccess: false)
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
