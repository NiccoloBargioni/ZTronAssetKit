import Foundation
import ZTronAssetModel

/// The pure part of `apply`, computed on the bulk executor from values captured on the actor (C2: diffing,
/// comparing, creating and scanning 10,000 records on the actor held it for 10–16 ms, review probe P4). The actor
/// then performs only the writes, and re-validates every adoption candidate against its live state.
struct ApplyPlan: Sendable {
    /// The diff from the applied manifest to the new one.
    var diff: ManifestDiff
    /// Whether the new manifest equals the applied one.
    var identical: Bool
    /// The record of each added id: absent, never fetched, expecting the entry's checksum (`insertRecord`).
    var newRecords: [AssetID: AssetRecord]
    /// The ids, in target order, whose record may adopt a blob the store knows (live, doomed `unreferenced`, or a
    /// confirmed orphan): added and content-changed ids, and existing records that accept adoption, except evicted ones
    /// (only the launch adoption takes those, OI-1; ruling R3 at the L3 close-out). `adoptKnownBlob` decides each on the
    /// actor. A blob placed during the unit is bound by its own publication; a record that starts accepting adoption
    /// during the unit adopts at the next `apply` or launch.
    var adoptionCandidates: [AssetID]

    /// Builds the plan; pure.
    static func compute(
        applied: ValidatedManifest,
        manifest: ValidatedManifest,
        records: [AssetID: AssetRecord],
        blobTable: [BlobKey: BlobState],
        orphans: [BlobKey: Int64],
        now: Date
    ) -> ApplyPlan {
        let diff = ManifestDiff.compute(from: applied, to: manifest)
        var newRecords: [AssetID: AssetRecord] = [:]
        newRecords.reserveCapacity(diff.added.count)
        for id in diff.added {
            guard let entry = diff.upserts[id] else {
                continue
            }
            newRecords[id] = AssetRecord(entry: entry, residency: .absent(.neverFetched), expectedBlob: entry.checksum, lastAccess: now)
        }
        func adoptable(_ key: BlobKey?) -> Bool {
            guard let key else {
                return false
            }
            switch blobTable[key] {
            case .live?:
                return true
            case .doomed(let info)?:
                return info.reason == .unreferenced
            case .deleting?:
                return false
            case nil:
                return orphans[key] != nil
            }
        }
        var candidates: [AssetID] = []
        if !blobTable.isEmpty || !orphans.isEmpty {
            var entries: [AssetID: ManifestEntry] = [:]
            entries.reserveCapacity(manifest.entries.count)
            for entry in manifest.entries {
                entries[entry.identifier] = entry
            }
            let changing = Set(diff.added).union(diff.contentChanged)
            for id in diff.targetOrder {
                let fromEntry = entries[id].flatMap { entry in
                    entry.checksum.flatMap { hash in AssetFileExtension(entry.fileExtension).map { BlobKey(hash: hash, ext: $0) } }
                }
                // A record that exists and keeps its content adopts only if it accepts adoption already; one that
                // starts accepting it during the unit adopts at the next `apply` or launch.
                if let record = records[id], record.residency == .absent(.evicted) || (!changing.contains(id) && !record.acceptsAdoption) {
                    continue
                }
                if adoptable(fromEntry) || adoptable(records[id]?.expectedKey) {
                    candidates.append(id)
                }
            }
        }
        return ApplyPlan(diff: diff, identical: applied == manifest, newRecords: newRecords, adoptionCandidates: candidates)
    }
}

/// `apply`'s eviction plan cut into the chunks it passes to WP-C's hook `applyEviction(_:)`, one actor turn each (C2;
/// orchestrator ruling R6 at the L3 close-out cycle 7, CCR-3): in one turn the hook held the actor about 1.4 µs per
/// victim, 14 ms for a plan of 10,000 blobs and 20 ms for one of 10,000 records over 5,000 blobs. Pure: computed on the
/// bulk executor from the plan, a value.
struct ApplyEvictionChunks: Sendable, Hashable {
    /// The plan's victims in chunks of whole blobs: each chunk ends at the first blob boundary at or past the record
    /// limit (a blob's records leave together, and the hook re-validates them together), so a blob of more records than
    /// a chunk is one chunk, unlike quota eviction, which since Stage 3 takes such a blob across turns (S3C-2).
    var chunks: [EvictionPlan]
    /// Whether the chunks list the victims in plan order. A plan lists each blob's victims together (the dry run's
    /// `EvictionOrder.plan`); one that names a blob in several places is grouped by key, its blobs in the order the plan
    /// first names them, so `apply` restores the plan's order in its report itself.
    var inPlanOrder: Bool

    /// Cuts `plan` into chunks of whole blobs holding at least `records` victims each (the last may hold fewer).
    init(cutting plan: EvictionPlan, records: Int) {
        let victims = plan.victims
        var runs: [ArraySlice<EvictionVictim>] = []
        var seen: Set<BlobKey> = []
        var grouped = false
        var start = 0
        while start < victims.count {
            var end = start + 1
            while end < victims.count, victims[end].blob == victims[start].blob {
                end += 1
            }
            guard seen.insert(victims[start].blob).inserted else {
                grouped = true
                break
            }
            runs.append(victims[start..<end])
            start = end
        }
        if grouped {
            var order: [BlobKey] = []
            var groups: [BlobKey: [EvictionVictim]] = [:]
            for victim in victims {
                if groups[victim.blob] == nil {
                    order.append(victim.blob)
                }
                groups[victim.blob, default: []].append(victim)
            }
            runs = order.map { (groups[$0] ?? [])[...] }
        }
        let limit = max(1, records)
        var chunks: [EvictionPlan] = []
        var current: [EvictionVictim] = []
        var bytes: Int64 = 0
        for run in runs {
            current.append(contentsOf: run)
            // A blob is counted once, as the dry run's `EvictionPlan.bytes` counts it.
            bytes = bytes.addingSaturating(run.first?.byteSize ?? 0)
            if current.count >= limit {
                chunks.append(EvictionPlan(victims: current, bytes: bytes))
                current = []
                bytes = 0
            }
        }
        if !current.isEmpty {
            chunks.append(EvictionPlan(victims: current, bytes: bytes))
        }
        self.chunks = chunks
        self.inPlanOrder = !grouped
    }
}
