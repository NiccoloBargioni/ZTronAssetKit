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
            // The root could not even be stat-ed: decide nothing in this lifetime.
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
        let tree = try await self.listLegacyTree(root)
        guard manifestRead != .failed, checksumsRead != .failed, !tree.failed else {
            // An I/O error while reading the prior art's files decides nothing in this lifetime, as a root that cannot be
            // stat-ed (review round 3, ZProbe-read and ZProbe-list): nothing is written or committed, a relaunch in
            // phase `inProgress` keeps its persisted plan, and no later phase runs on a view this one could not read.
            self.state.migration.root = nil
            self.environment.log.log(.store, .error, "legacy phase 1 could not read the prior art's files; migration waits for a later launch")
            return false
        }
        let limits = self.configuration.limits
        // REENTRANCY: R1, R11 — the phase; decoding and planning are pure and run off the actor (C2).
        let decoded = await self.runUnit(on: self.environment.bulkExecutor) {
            LegacyDecoding.decode(manifest: manifestRead, checksums: checksumsRead, limits: limits, files: tree.files)
        }
        try self.checkLive()
        if starting {
            self.applyLegacyPlanWrites(decoded.manifest, undecodable: decoded.undecodable, checksums: decoded.checksums, stamp: stamp)
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
        let plan = decoded.plan
        var queue: [LegacyFile] = []
        var dropped = plan.dropped
        for file in plan.files {
            if !self.legacyWanters(file).isEmpty {
                queue.append(file)
            } else if !self.legacyAdopted(file) {
                dropped += 1
            }
        }
        // An entry whose file is no longer in the tree was adopted by an earlier lifetime when its record holds the
        // bytes it expected (moved into `blobs/`); otherwise it is dropped.
        dropped += plan.unlisted.filter { !self.legacyAdopted($0) }.count
        self.state.migration.queue = queue.reversed()
        self.state.migration.claimed = []
        self.state.migration.legacyIDs = plan.legacyIDs
        self.state.migration.manifestDigest = decoded.manifest?.digest
        self.state.migration.progress = LegacyMigrationProgress(adopted: 0, remaining: queue.count, dropped: dropped, finished: false)
        return true
    }

    /// Phase 1's writes (ARCHITECTURE §1.1 rule 1): the legacy manifest becomes the applied one (no ETag) only while
    /// none is applied; records are inserted only for ids the applied manifest lists and the index lacks, as
    /// `absent(.neverFetched)` expecting the planned digest; an undecodable manifest degrades the launch.
    func applyLegacyPlanWrites(_ manifest: ValidatedManifest?, undecodable: Bool, checksums: [String: String], stamp: String?) {
        if undecodable {
            self.state.core.degraded = true
        }
        if let manifest {
            if self.state.core.appliedManifest.entries.isEmpty {
                self.state.core.appliedManifest = manifest
                self.state.core.etag = nil
            }
            let now = self.environment.time.now()
            for legacy in manifest.entries where self.state.core.records[legacy.identifier] == nil {
                guard let applied = self.state.core.appliedManifest.entry(for: legacy.identifier) else {
                    continue
                }
                let planned = legacy.checksum ?? LegacyPlanner.localDigest(checksums[legacy.identifier.rawValue])
                let expected = applied.checksum ?? (applied.contentIdentity == legacy.contentIdentity ? planned : nil)
                self.state.core.records[legacy.identifier] = AssetRecord(
                    entry: applied,
                    residency: .absent(.neverFetched),
                    expectedBlob: expected,
                    lastAccess: now
                )
            }
        }
        self.state.migration.legacyStamp = stamp
        self.state.migration.phase = .inProgress
        self.markDirty(.soon)
    }

    /// The ids of `file` whose records still want its bytes (REENTRANCY R11): they expect its digest, accept adoption
    /// and name a valid extension.
    func legacyWanters(_ file: LegacyFile) -> [AssetID] {
        file.ids.filter { id in
            guard let record = self.state.core.records[id] else {
                return false
            }
            return record.expectedBlob == file.digest && record.acceptsAdoption && AssetFileExtension(record.entry.fileExtension) != nil
        }
    }

    /// Whether some record of `file` already holds its bytes (adopted earlier, by launch reconciliation or on demand).
    func legacyAdopted(_ file: LegacyFile) -> Bool {
        file.ids.contains { self.state.core.records[$0]?.referencedBlob?.hash == file.digest }
    }

    /// Whether the record of an entry whose file is not in the tree holds the bytes the entry expected.
    func legacyAdopted(_ entry: LegacyUnlisted) -> Bool {
        guard let digest = entry.digest else {
            return false
        }
        return self.state.core.records[entry.id]?.referencedBlob?.hash == digest
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
    }

    /// Hashes one legacy file and adopts it for the records that still want it (hash, re-validate, `adoptVerifiedFile`).
    /// Throws only the lifecycle and cancellation errors; every other failure drops the file.
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
            return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
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
        }
        return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
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
            self.unclaimLegacyFile(file, requeue: false)
            self.count(outcome)
            adoptedAny = adoptedAny || outcome == .adopted
            budget -= 1
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
        case .alreadyAdopted:
            break
        }
    }

    // MARK: Phases 3 and 4

    /// Phase 3, then phase 4: the stamp migrates only when the applied manifest is still the legacy one phase 1 decoded
    /// and every one of its entries is present at its current content (and never over a newer stamp); otherwise a sync
    /// is made due. The "done" generation is committed **durably** before the irrevocable removal of the tree and of the
    /// `UserDefaults` key.
    func finishLegacyMigration(_ root: URL) async throws(StoreError) {
        let migration = self.state.migration
        // A manifest applied during migration (the engine synced, or an interrupted run resumed after an apply) may list
        // entries nobody fetched: a stamp over its digest would claim them synced (review round 3, ZProbe-stamp).
        let current = migration.manifestDigest.map { $0 == self.state.core.appliedManifest.digest } ?? false
        let allAdopted = current && migration.legacyIDs.allSatisfy { id in
            guard let record = self.state.core.records[id] else {
                return false
            }
            return record.referencedBlob != nil && !record.isStale
        }
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
        if queued != nil {
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
}
