import CryptoKit
import Foundation
import ZTronAssetModel

/// Publication of a staged file and the streaming hash (R-STO-3, R-INT-1/2/5/6; ARCHITECTURE §4.3; WP-B).
extension AssetStore {
    /// `publish(_:binding:expecting:urgency:)`: claim → size → hash → compare → sidecar → reference → barrier →
    /// rename → bind → snapshot at `urgency`. The expectation always comes from the records (R-INT-6).
    func performPublish(
        _ staged: StagedFile,
        binding ids: [AssetID],
        expecting identity: ContentIdentity,
        urgency: AssetPriority
    ) async throws(StoreError) -> [AssetID: AssetLocation] {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        guard let layout = self.state.core.layout, let first = ids.first else {
            return [:]
        }
        let expectation = BindingExpectation.identity(identity)
        // (1) The records must still carry this identity before any hashing (sync.md X-3).
        let known = ids.filter { self.state.core.records[$0] != nil }
        guard let firstKnown = known.first else {
            throw .unknownAsset(first)
        }
        if known.allSatisfy({ self.isFailed($0) }), case .failed(let reason)? = self.state.core.records[firstKnown]?.residency {
            throw .assetFailed(firstKnown, reason)
        }
        guard self.wanted(ids, expectation) else {
            throw .superseded(firstKnown)
        }
        let part = layout.stagingURL(staged.name.with(kind: .partial))
        let verifying = layout.stagingURL(staged.name.with(kind: .verifying))
        let sidecar = layout.stagingURL(staged.name.with(kind: .sidecar))
        let fileSystem = self.environment.fileSystem
        // R-INT-5: a checksum-less entry is refused before any work when unverified assets are not allowed.
        if case .unverified = identity, !self.configuration.policy.allowUnverifiedAssets {
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after removing the staged bytes.
            await self.runUnit(on: self.environment.metadataExecutor) {
                try? fileSystem.removeItem(at: part)
                try? fileSystem.removeItem(at: sidecar)
            }
            throw .unverifiedRejected(known.first(where: { self.wanted([$0], expectation) }) ?? firstKnown)
        }
        // (2) Claim: no producer writes `.verifying`, so bytes appended to `.part` later are never published
        // (store-1 S1-12).
        // REENTRANCY: R4 — phase, then the records' identity, re-validated right below.
        let claimed = await self.runUnit(on: self.environment.metadataExecutor) { () -> Result<Int64, FileSystemError> in
            do throws(FileSystemError) {
                try fileSystem.rename(from: part, to: verifying, mode: .exclusive)
                return .success(try fileSystem.itemInfo(at: verifying)?.byteSize ?? 0)
            } catch {
                return .failure(error)
            }
        }
        try self.checkLive()
        let size: Int64
        switch claimed {
        case .success(let bytes):
            size = bytes
        case .failure(let error):
            throw .fileSystem(error)
        }
        guard self.wanted(ids, expectation) else {
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
            await self.discardClaimed(verifying, sidecar)
            throw .superseded(firstKnown)
        }
        // (3) Size first, without hashing (R-INT-2, R-NET-7).
        let limit = self.configuration.limits.maxAssetBytes
        if size > limit {
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
            try await self.rejectIntegrity(.oversize(limit: limit, actual: size), verifying, sidecar)
        }
        if let expected = ids.compactMap({ self.state.core.records[$0] }).filter(expectation.accepts).compactMap(\.entry.byteSize).first(where: { $0 != size }) {
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
            try await self.rejectIntegrity(.sizeMismatch(expected: expected, actual: size), verifying, sidecar)
        }
        // (4) Streaming hash on the bulk executor, cancellation-aware.
        let digest: ContentHash
        let hashedBytes: Int64
        do throws(StoreError) {
            // REENTRANCY: R2 — every bound record still has the expected identity, else `.superseded` before more
            // work; the phase is re-checked first.
            (digest, hashedBytes) = try await self.hashFileInternal(at: verifying)
        } catch .cancelled {
            // The caller may retry with the same staged file: hand the claim back.
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
            await self.runUnit(on: self.environment.metadataExecutor) {
                try? fileSystem.rename(from: verifying, to: part, mode: .exclusive)
            }
            throw .cancelled
        } catch {
            throw error
        }
        try self.checkLive()
        guard self.wanted(ids, expectation) else {
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
            await self.discardClaimed(verifying, sidecar)
            throw .superseded(firstKnown)
        }
        if hashedBytes != size {
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
            try await self.rejectIntegrity(.sizeMismatch(expected: size, actual: hashedBytes), verifying, sidecar)
        }
        // (5) Compare with the manifest's claim; checksum-less entries record our digest instead (R-INT-5/6).
        if case .checksum(let expected) = identity, expected != digest {
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
            try await self.rejectIntegrity(.checksumMismatch(expected: expected, actual: digest), verifying, sidecar)
        }
        // (6)–(10) Sidecar, reference, barrier, rename, bind; ids with another extension get their own copy.
        let groups = self.extensionGroups(ids, expectation)
        guard let primary = groups.first else {
            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
            await self.discardClaimed(verifying, sidecar)
            throw .superseded(firstKnown)
        }
        let primaryKey = BlobKey(hash: digest, ext: primary.ext)
        // REENTRANCY: R3, R4 — `bindVerifiedFile` re-validates every record after its awaits.
        var (locations, rescued) = try await self.bindVerifiedFile(
            at: verifying,
            sidecar: sidecar,
            key: primaryKey,
            byteCount: size,
            ids: primary.ids,
            expecting: expectation
        )
        for group in groups.dropFirst() {
            // REENTRANCY: R4 — as above, for the copy bound under the group's extension.
            if let extra = try? await self.bindCopy(of: primaryKey, ext: group.ext, byteCount: size, ids: group.ids, expecting: expectation) {
                locations.merge(extra.locations) { current, _ in current }
                rescued = rescued || extra.rescued
            }
        }
        // Checksum-less and rescue publishes are committed before they return (store-1 S1-05): their blobs could
        // not be adopted by hash after a crash.
        if case .unverified = identity {
            // REENTRANCY: R5, R4 — the phase, then every bound record is re-validated below (store-2 S2-15).
            try await self.requireCommittedInternal(.ordered)
            locations = try self.stillBound(locations, expectation, first: firstKnown)
        } else if rescued {
            // REENTRANCY: R5, R4 — as above.
            try await self.requireCommittedInternal(.ordered)
            locations = try self.stillBound(locations, expectation, first: firstKnown)
        }
        // REENTRANCY: R6, R4 — the phase, then every bound record is re-validated (store-2 S2-15): a record pruned or
        // changed during the install is dropped, and `.superseded` is thrown when none remains; the returned
        // locations are re-read from actor state (ADR-016).
        await self.publishSnapshotInternal(urgency: urgency)
        return try self.stillBound(locations, expectation, first: firstKnown)
    }

    /// The bound locations that are still valid after an await (ARCHITECTURE §4.3 step 9, store-2 S2-15): each record
    /// still exists, still wants these bytes and is still present at the returned blob; the location is re-read from
    /// the current snapshot entry. Throws `.closed` once the store closed and `.superseded` when nothing remains, so a
    /// URL of a doomed blob is never handed out.
    private func stillBound(_ locations: [AssetID: AssetLocation], _ expectation: BindingExpectation, first: AssetID) throws(StoreError)
        -> [AssetID: AssetLocation]
    {
        try self.checkLive()
        var current: [AssetID: AssetLocation] = [:]
        for (id, location) in locations {
            guard let record = self.state.core.records[id], expectation.accepts(record),
                let entry = self.state.core.presentTable[id], entry.location.url == location.url
            else {
                continue
            }
            current[id] = entry.location
        }
        guard !current.isEmpty else {
            throw .superseded(first)
        }
        return current
    }

    /// `hashFile(at:)`: streaming SHA-256 in `hashChunkBytes` (≤ 1 MiB) units on the bulk executor, cancellation
    /// checked between units (R-INT-1, P-6), inside one `verify` signpost interval (R-OBS-1).
    func hashFileInternal(at url: URL) async throws(StoreError) -> (digest: ContentHash, byteCount: Int64) {
        let fileSystem = self.environment.fileSystem
        let chunk = min(max(1, self.configuration.hashChunkBytes), 1 << 20)
        let interval = self.environment.log.interval(.verify, category: .store, "chunk \(chunk)")
        defer {
            interval.end()
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        while true {
            if Task.isCancelled {
                throw .cancelled
            }
            try self.checkLive()
            let current = hasher
            let start = offset
            // REENTRANCY: R2/R16 — nothing but the phase (loop top): the running hash and offset are locals, and every
            // caller re-validates its records after the call.
            let unit = await self.runUnit(on: self.environment.bulkExecutor) {
                StreamingHashUnit.run(fileSystem: fileSystem, url: url, offset: start, chunk: chunk, hasher: current)
            }
            switch unit {
            case .success(let step):
                hasher = step.hasher
                offset += Int64(step.count)
                if step.count < chunk {
                    return (ContentHash(digest: hasher.finalize()), offset)
                }
            case .failure(let error):
                throw .fileSystem(error)
            }
        }
    }

    /// `adoptVerifiedFile(at:digest:byteCount:for:)`: binds an already hashed file to every id whose record still
    /// expects `digest` (legacy migration, ADR-029). Publishes no snapshot.
    func adoptVerifiedFileInternal(at url: URL, digest: ContentHash, byteCount: Int64, for ids: [AssetID]) async throws(StoreError)
        -> [AssetID: AssetLocation]
    {
        try self.checkLive()
        try self.checkWritable()
        let expectation = BindingExpectation.digest(digest)
        let groups = self.extensionGroups(ids, expectation)
        guard let primary = groups.first else {
            return [:]
        }
        let primaryKey = BlobKey(hash: digest, ext: primary.ext)
        // REENTRANCY: R11/R18 — `bindVerifiedFile` re-validates that each record still expects the blob.
        var (locations, _) = try await self.bindVerifiedFile(
            at: url,
            sidecar: nil,
            key: primaryKey,
            byteCount: byteCount,
            ids: primary.ids,
            expecting: expectation
        )
        for group in groups.dropFirst() {
            // REENTRANCY: R11 — as above, for the copy bound under the group's extension.
            if let extra = try? await self.bindCopy(of: primaryKey, ext: group.ext, byteCount: byteCount, ids: group.ids, expecting: expectation) {
                locations.merge(extra.locations) { current, _ in current }
            }
        }
        return locations
    }

    // MARK: Helpers

    /// Whether some id's record still wants the bytes.
    private func wanted(_ ids: [AssetID], _ expectation: BindingExpectation) -> Bool {
        ids.contains { id in
            self.state.core.records[id].map(expectation.accepts) ?? false
        }
    }

    private func isFailed(_ id: AssetID) -> Bool {
        if case .failed? = self.state.core.records[id]?.residency {
            return true
        }
        return false
    }

    /// The wanted ids grouped by their blob extension, in first-seen order: one blob per extension.
    func extensionGroups(_ ids: [AssetID], _ expectation: BindingExpectation) -> [(ext: AssetFileExtension, ids: [AssetID])] {
        var groups: [(ext: AssetFileExtension, ids: [AssetID])] = []
        for id in ids {
            guard let record = self.state.core.records[id], expectation.accepts(record), let ext = AssetFileExtension(record.entry.fileExtension) else {
                continue
            }
            if let index = groups.firstIndex(where: { $0.ext == ext }) {
                if !groups[index].ids.contains(id) {
                    groups[index].ids.append(id)
                }
            } else {
                groups.append((ext, [id]))
            }
        }
        return groups
    }

    /// Identical bytes under a second extension (two entries with one checksum and different extensions): one blob
    /// per extension (ADR draft B-11). The destination key is acquired **before** any copy, so binders of one key are
    /// serialised (review probe P1): a live or rescuable key is already on disk and is bound in place without
    /// copying; a new or replaced key is held in `publishing` while the placed blob is copied into a staging name of
    /// its own and verified (`copyBlob`), then placed like any verified file.
    private func bindCopy(
        of source: BlobKey,
        ext: AssetFileExtension,
        byteCount: Int64,
        ids: [AssetID],
        expecting expectation: BindingExpectation
    ) async throws(StoreError) -> (locations: [AssetID: AssetLocation], rescued: Bool) {
        let key = BlobKey(hash: source.hash, ext: ext)
        // REENTRANCY: R3 — `acquireReference` waits out a publication, replacement or deletion of `key` and decides
        // from the blob table as it is then; the records are re-validated by `bindRecords` / `placeAndBind`.
        let acquisition = try await self.acquireReference(key)
        switch acquisition {
        case .reused, .rescued:
            // A live or rescuable key's file is complete (I-2): no copy, no I/O, no await before the binding.
            return try self.bindRecords(key: key, byteCount: byteCount, ids: ids, expecting: expectation, acquisition: acquisition)
        case .new, .replaced:
            break
        }
        let copy: URL
        do throws(StoreError) {
            // REENTRANCY: b-4 (proposed) — `copyBlob` re-checks the phase after each unit; `key` stays held.
            copy = try await self.copyBlob(source, byteCount: byteCount)
        } catch {
            self.abandonAcquisition(key, acquisition)
            throw error
        }
        // REENTRANCY: R4 — `placeAndBind` re-validates every record after its placement unit.
        return try await self.placeAndBind(
            source: copy,
            sidecar: nil,
            key: key,
            byteCount: byteCount,
            ids: ids,
            expecting: expectation,
            acquisition: acquisition
        )
    }

    /// Copies the blob `source` into `staging/<transfer>.<epoch>-<seq>.parttmp` in ≤ 1 MiB units on the bulk
    /// executor, hashing the bytes as they are copied. The sequence is allocated by the store (counting down from
    /// `UInt32.max`, away from the engine's start counter), so no two copies share a name; the copy is accepted only
    /// with exactly `byteCount` bytes hashing to `source.hash`, so I-1 holds even if the source changed meanwhile.
    private func copyBlob(_ source: BlobKey, byteCount: Int64) async throws(StoreError) -> URL {
        guard let layout = self.state.core.layout else {
            throw .notOpen
        }
        let sequence = self.state.core.nextCopySequence
        self.state.core.nextCopySequence = sequence > UInt32.max / 2 ? sequence - 1 : UInt32.max
        let copyName = StagingFileName(
            transfer: .content(source.hash),
            attempt: TransferAttempt(epoch: self.state.core.launchEpoch, sequence: sequence),
            kind: .partialTemporary
        )
        let destination = layout.stagingURL(copyName)
        let origin = layout.blobURL(source)
        let fileSystem = self.environment.fileSystem
        var hasher = SHA256()
        var offset: Int64 = 0
        var failure: StoreError?
        copying: while true {
            let start = offset
            let running = hasher
            // REENTRANCY: b-4 (proposed) — the phase; the copy has a name no one else writes and its destination key
            // is held in `publishing`, so no other binder writes or places it; the bytes are verified below.
            let step = await self.runUnit(on: self.environment.bulkExecutor) { () -> Result<(hasher: SHA256, count: Int), FileSystemError> in
                do throws(FileSystemError) {
                    let data = try fileSystem.read(from: origin, offset: start, maxLength: 1 << 20)
                    try fileSystem.write(data, to: destination, mode: start == 0 ? .truncate : .append)
                    var next = running
                    next.update(data: data)
                    return .success((next, data.count))
                } catch {
                    return .failure(error)
                }
            }
            do throws(StoreError) {
                try self.checkLive()
            } catch {
                failure = error
                break copying
            }
            switch step {
            case .success(let unit):
                hasher = unit.hasher
                offset += Int64(unit.count)
                if unit.count == 0 || offset >= byteCount {
                    break copying
                }
            case .failure(let error):
                failure = .fileSystem(error)
                break copying
            }
        }
        if failure == nil {
            let digest = ContentHash(digest: hasher.finalize())
            if offset != byteCount {
                failure = .integrity(.sizeMismatch(expected: byteCount, actual: offset))
            } else if digest != source.hash {
                failure = .integrity(.checksumMismatch(expected: source.hash, actual: digest))
            }
        }
        guard let failure else {
            return destination
        }
        // REENTRANCY: b-3 (proposed) — nothing: the call throws right after removing the copy.
        await self.runUnit(on: self.environment.metadataExecutor) {
            try? fileSystem.removeItem(at: destination)
        }
        throw failure
    }

    /// Deletes the claimed bytes and the sidecar of a publication that cannot proceed.
    private func discardClaimed(_ verifying: URL, _ sidecar: URL) async {
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: b-3 (proposed) — nothing: the caller throws right after.
        await self.runUnit(on: self.environment.metadataExecutor) {
            try? fileSystem.removeItem(at: verifying)
            try? fileSystem.removeItem(at: sidecar)
        }
    }

    /// R-INT-2: deletes the staged bytes, counts the failure and throws `.integrity` (the engine records the
    /// R-INT-3 bookkeeping, ADR-032).
    private func rejectIntegrity(_ failure: StoreIntegrityFailure, _ verifying: URL, _ sidecar: URL) async throws(StoreError) -> Never {
        self.state.core.metrics.integrityFailures += 1
        let reason = AssetStore.describe(.integrity(failure))
        self.environment.log.log(.store, .error, "publication rejected: \(reason)")
        // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
        await self.discardClaimed(verifying, sidecar)
        throw .integrity(failure)
    }
}
