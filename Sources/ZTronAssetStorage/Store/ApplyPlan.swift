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
    /// confirmed orphan): added and content-changed ids, and existing records that accept adoption. `adoptKnownBlob`
    /// decides each on the actor. A blob placed during the unit is bound by its own publication; a record that starts
    /// accepting adoption during the unit adopts at the next `apply` or launch.
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
                if !changing.contains(id), let record = records[id], !record.acceptsAdoption {
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
