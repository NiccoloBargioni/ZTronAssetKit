import Foundation
import ZTronAssetModel

/// Legacy migration phases 1–4 (R-STO-11, H-10; ADR-029, store.md §7, ARCHITECTURE §1.1 rule 1 and §4.7).
extension AssetStore {
    // MARK: Phase 1 (inside open())

    /// `runLegacyPhaseOne()`. Runs while `open()` is `opening`: every await is a unit (REENTRANCY R1) and nothing here
    /// publishes a snapshot.
    func performLegacyPhaseOne() async throws(StoreError) -> Bool {
        // A lifetime that could not read an index file writes nothing (ADR draft B-34): migration waits for a later one.
        guard (try? self.checkWritable()) != nil, let root = await self.resolveLegacyRoot() else {
            return false
        }
        try self.checkLive()
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
            // A crash during phase 4 left the tree or the key: `migrateLegacy` finishes the removal.
            // REENTRANCY: R1 — the phase.
            let stamp = await self.readLegacyStamp()
            try self.checkLive()
            return rootKind != nil || stamp != nil
        case .notStarted, .inProgress:
            break
        }
        guard rootKind == .directory else {
            // No legacy tree (a symbolic link is never followed, R-SEC-2). Before migration started, the stamp can never
            // be migrated (D-6): it goes. A tree that vanished during migration still needs phases 3 and 4.
            if self.state.migration.phase == .notStarted {
                self.state.migration.root = nil
                // REENTRANCY: R1 — the phase.
                await self.removeLegacyStamp()
                try self.checkLive()
                return false
            }
            self.state.migration.planCommitted = true
            return true
        }
        let starting = self.state.migration.phase == .notStarted
        // REENTRANCY: R1, R11 — the phase; the reads below are snapshots of the prior art's files, which no one writes.
        let stamp = starting ? await self.readLegacyStamp() : self.state.migration.legacyStamp
        let limit = self.configuration.limits.maxPayloadBytes
        // REENTRANCY: R1, R11 — as above.
        let manifestRead = await self.readLegacyFile(root.appendingPathComponent("manifest.json", isDirectory: false), limit: limit)
        // REENTRANCY: R1, R11 — as above.
        let checksumsRead = await self.readLegacyFile(root.appendingPathComponent("local-checksums.json", isDirectory: false), limit: limit)
        // REENTRANCY: R1, R11 — as above.
        let files = await self.listLegacyTree(root)
        let limits = self.configuration.limits
        // REENTRANCY: R1, R11 — the phase; decoding is pure and runs off the actor (C2).
        let decoded = await self.runUnit(on: self.environment.bulkExecutor) { () -> (manifest: ValidatedManifest?, undecodable: Bool, checksums: [String: String]) in
            LegacyDecoding.decode(manifest: manifestRead, checksums: checksumsRead, limits: limits)
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
            self.state.migration.planCommitted = true
        }
        let plan = LegacyPlanner.plan(entries: decoded.manifest?.entries ?? [], checksums: decoded.checksums, files: files)
        var queue: [LegacyFile] = []
        var dropped = plan.dropped
        for file in plan.files {
            if !self.legacyWanters(file).isEmpty {
                queue.append(file)
            } else if !self.legacyAdopted(file) {
                dropped += 1
            }
        }
        self.state.migration.queue = queue
        self.state.migration.claimed = []
        self.state.migration.legacyIDs = plan.legacyIDs
        self.state.migration.manifestDecoded = decoded.manifest != nil
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
                // REENTRANCY: c-4 (proposed) — see `finishLegacyRemoval`.
                try await self.finishLegacyRemoval(root)
            }
            return self.state.migration.progress
        case .inProgress:
            break
        }
        if !self.state.migration.planCommitted {
            // REENTRANCY: R17 — nothing but the phase: phase 1's writes reach a committed generation before any file moves.
            try await self.requireCommitted(.ordered)
            self.state.migration.planCommitted = true
        }
        var budget = max(0, maxFiles)
        var adoptedAny = false
        while budget > 0, !self.state.migration.queue.isEmpty {
            let file = self.state.migration.queue.removeFirst()
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

    /// Removes `file` from the claims, back to the head of the queue when its processing did not complete.
    func unclaimLegacyFile(_ file: LegacyFile, requeue: Bool) {
        if let index = self.state.migration.claimed.firstIndex(of: file) {
            self.state.migration.claimed.remove(at: index)
        }
        if requeue {
            self.state.migration.queue.insert(file, at: 0)
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

    /// Phase 3, then phase 4: the stamp migrates only when every legacy entry is present at its current content (and
    /// never over a newer stamp); otherwise a sync is made due. The "done" generation is committed **durably** before the
    /// irrevocable removal of the tree and of the `UserDefaults` key.
    func finishLegacyMigration(_ root: URL) async throws(StoreError) {
        let migration = self.state.migration
        let allAdopted = migration.manifestDecoded && migration.legacyIDs.allSatisfy { id in
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

    /// Phase 4: the tree, then the key. Idempotent: a crash or an error part way is finished by the next call.
    func finishLegacyRemoval(_ root: URL) async throws(StoreError) {
        // REENTRANCY: c-4 (proposed) — nothing: after the durable "done" commit the tree and the key are the migration's
        // alone, and every step of the removal is idempotent.
        let removed = try await self.removeLegacyTree(root)
        // REENTRANCY: c-4 (proposed) — as above.
        await self.removeLegacyStamp()
        try self.checkLive()
        self.state.migration.progress.remaining = 0
        self.state.migration.progress.finished = removed
    }

    // MARK: Adopt on demand

    /// `adoptLegacyNow(_:)`: the current location when the asset is present; otherwise, while migration runs, adopts its
    /// legacy file now (counted here only when this call took it from the queue) and installs the snapshot at once.
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
        let migration = self.state.migration
        let queued = migration.queue.firstIndex { $0.ids.contains(id) }
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
        }
        // REENTRANCY: R17, R18 — nothing but the phase: the location is read from the record afterwards.
        await self.publishSnapshot(urgency: .userInitiated)
        return self.location(for: id, extensions: [], recordingAccess: false)
    }
}

/// Decoding the prior art's metadata files (pure; run in a bulk unit).
enum LegacyDecoding {
    /// The legacy manifest decoded under `limits` with duplicate identifiers keeping the first (store.md §7, RECON
    /// D-13), whether it was present but undecodable, and the local checksums (an unusable file reads as none).
    static func decode(manifest: LegacyRead, checksums: LegacyRead, limits: ManifestLimits) -> (manifest: ValidatedManifest?, undecodable: Bool, checksums: [String: String]) {
        var decoded: ValidatedManifest?
        var undecodable = false
        switch manifest {
        case .absent:
            break
        case .unusable:
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
        return (decoded, undecodable, table)
    }
}
