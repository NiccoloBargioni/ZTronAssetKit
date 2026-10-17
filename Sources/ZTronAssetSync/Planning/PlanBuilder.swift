import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// The body of `SyncPlanner.plan` (R-SYN-1, R-SYN-8, R-SYN-11; sync.md §4.2 as amended by ADR-025 and ADR-030).
///
/// One pass over the new manifest (O(1) record probes), the diff's pass over the applied manifest for prunes, and a
/// sort of the fetches only. Every output list is built in manifest order (or applied-manifest order for prunes) and
/// the fetches are sorted by `(rank, manifestIndex)`, so no output depends on dictionary or set iteration (R-SYN-1).
///
/// The reconcile step mirrors `AssetStore.apply` exactly where the planner can see the same facts (ADR-030):
/// relocations are the diff's metadata changes that have a record, prunes the diff's removals, and reuses the ids
/// whose current content is a live blob that `apply` would adopt (an evicted record is never adopted by `apply`,
/// ruling R3). Blobs `apply` could also rescue (doomed `unreferenced`, launch orphans) are invisible to the planner, so
/// for those it plans a fetch, which publication then dedupes.
enum PlanBuilder {
    /// Plans a run.
    static func plan(
        manifest: ValidatedManifest,
        snapshot: StorePlanningView,
        scope: AssetScope,
        policy: PlanningPolicy,
        freeSpace: FreeSpace
    ) -> SyncPlan {
        let diff = ManifestDiff.compute(from: snapshot.appliedManifest, to: manifest)
        let changing = PlanBuilder.changingIDs(diff)
        var relocations: [AssetID] = []
        var reuses: [AssetID] = []
        var fetches: [PlannedFetch] = []
        var skipped: [(index: Int, skip: PlannedSkip)] = []
        var unchanged = 0
        for (index, entry) in manifest.entries.enumerated() {
            let id = entry.identifier
            let record = snapshot.records[id]
            let isChanging = changing.contains(id)
            let inApplied = snapshot.appliedManifest.contains(id)
            let relocated = inApplied && !isChanging && record != nil && entry != snapshot.appliedManifest.entry(for: id)
            if relocated {
                relocations.append(id)
            }
            if PlanBuilder.reuses(entry: entry, record: record, changing: isChanging, liveBlobs: snapshot.liveBlobs) {
                reuses.append(id)
                continue
            }
            guard let reason = PlanBuilder.fetchReason(entry: entry, record: record, changing: isChanging, added: !inApplied, now: policy.now) else {
                if let skip = PlanBuilder.heldBack(entry: entry, record: record, changing: isChanging, now: policy.now) {
                    skipped.append((index, PlannedSkip(id: id, reason: skip)))
                } else if !relocated {
                    unchanged += 1
                }
                continue
            }
            if let skip = PlanBuilder.ineligible(entry: entry, scope: scope, policy: policy) {
                skipped.append((index, PlannedSkip(id: id, reason: skip)))
                continue
            }
            fetches.append(
                PlannedFetch(
                    id: id,
                    entry: entry,
                    identity: entry.contentIdentity,
                    transfer: entry.transferID,
                    reason: reason,
                    rank: entry.policy.rank,
                    manifestIndex: index
                )
            )
        }
        fetches.sort { ($0.rank, $0.manifestIndex) < ($1.rank, $1.manifestIndex) }
        let prunes = diff.removed.filter { snapshot.records[$0] != nil }
        let pruneBytes = prunes.reduce(Int64(0)) { sum, id in
            guard case .present(_, let size, _)? = snapshot.records[id]?.residency else {
                return sum
            }
            return PlanBuilder.adding(sum, size)
        }
        let assessment = PlanBuilder.assess(fetches: fetches, pruneBytes: pruneBytes, policy: policy, freeSpace: freeSpace)
        var admitted = fetches
        if case .partial(let count, _) = assessment {
            admitted = Array(fetches.prefix(count))
            for fetch in fetches.dropFirst(count) {
                skipped.append((fetch.manifestIndex, PlannedSkip(id: fetch.id, reason: .overBudget)))
            }
            skipped.sort { $0.index < $1.index }
        }
        let totals = PlanTotals(
            fetchCount: admitted.count,
            fetchUnknownSizeCount: admitted.filter { $0.entry.byteSize == nil }.count,
            relocationCount: relocations.count,
            reuseCount: reuses.count,
            pruneCount: prunes.count,
            skippedCount: skipped.count,
            unchangedCount: unchanged,
            fetchBytes: PlanBuilder.knownBytes(admitted),
            pruneBytes: pruneBytes
        )
        return SyncPlan(
            baseGeneration: snapshot.generation,
            manifestDigest: manifest.digest,
            reconcile: ReconcileStep(relocations: relocations, reuses: reuses, prunes: prunes, adopts: manifest),
            fetches: admitted,
            skipped: skipped.map(\.skip),
            totals: totals,
            space: assessment
        )
    }

    // MARK: Classification

    /// Ids whose content `apply` changes: added and content-changed (their records accept adoption whatever their
    /// residency, unless evicted).
    private static func changingIDs(_ diff: ManifestDiff) -> Set<AssetID> {
        var ids = Set<AssetID>()
        ids.reserveCapacity(diff.added.count + diff.contentChanged.count)
        ids.formUnion(diff.added)
        ids.formUnion(diff.contentChanged)
        return ids
    }

    /// Whether `apply` binds the id to a live blob instead of fetching: the content after `apply` is a live blob and
    /// the record accepts adoption (store `ApplyPlan.compute` and `AssetRecord.acceptsAdoption`, mirrored).
    private static func reuses(entry: ManifestEntry, record: AssetRecord?, changing: Bool, liveBlobs: Set<ContentHash>) -> Bool {
        if let record, record.residency == .absent(.evicted) {
            return false
        }
        if !changing {
            guard let record, PlanBuilder.acceptsAdoption(record) else {
                return false
            }
        }
        let expected = entry.checksum ?? (changing ? nil : record?.expectedBlob)
        guard let hash = expected else {
            return false
        }
        return liveBlobs.contains(hash)
    }

    /// `AssetRecord.acceptsAdoption` as the planner can see it (that property is the store's own): never-fetched,
    /// healing, `needsHeal` or stale records; never purged, failed, quarantined or (for `apply`) evicted ones.
    private static func acceptsAdoption(_ record: AssetRecord) -> Bool {
        switch record.residency {
        case .absent(let reason):
            return reason != .purged && reason != .evicted
        case .needsHeal:
            return true
        case .present:
            return record.isStale
        case .quarantined, .failed:
            return false
        }
    }

    /// Why the entry needs bytes after `apply`, or `nil` when it is present at its content or held back.
    private static func fetchReason(entry: ManifestEntry, record: AssetRecord?, changing: Bool, added: Bool, now: Date) -> FetchReason? {
        if added || record == nil {
            return .added
        }
        if changing {
            return entry.checksum == nil ? .legacyPathChanged : .contentChanged
        }
        guard let record else {
            return .added
        }
        if PlanBuilder.inIntegrityBackoff(record, entry: entry, now: now) {
            return nil
        }
        switch record.residency {
        case .present:
            return record.isStale ? .contentChanged : nil
        case .absent:
            return .missingBlob
        case .needsHeal:
            return .needsHeal
        case .quarantined(let until):
            return until > now ? nil : .missingBlob
        case .failed:
            return nil
        }
    }

    /// Why an entry that is not present is not fetched yet: a quarantine or integrity backoff (R-INT-3, ADR-032) or a
    /// persisted failure until the entry changes (R-NET-6). `nil` for an entry that needs nothing.
    private static func heldBack(entry: ManifestEntry, record: AssetRecord?, changing: Bool, now: Date) -> SkipReason? {
        guard let record, !changing else {
            return nil
        }
        if case .failed = record.residency {
            return .failedUntilEntryChanges
        }
        if case .quarantined(let until) = record.residency, until > now {
            return .integrityQuarantined
        }
        if PlanBuilder.inIntegrityBackoff(record, entry: entry, now: now), record.referencedBlob == nil || record.isStale {
            return .integrityQuarantined
        }
        return nil
    }

    /// Whether the record's integrity history defers this content past `now` (ADR-032: every lane honours it).
    private static func inIntegrityBackoff(_ record: AssetRecord, entry: ManifestEntry, now: Date) -> Bool {
        guard let next = record.integrity.nextEligibleAt, next > now else {
            return false
        }
        return record.integrity.failedIdentity == entry.contentIdentity
    }

    /// Why a needed entry is not fetched by this run: scope, on-demand policy or unverified content.
    private static func ineligible(entry: ManifestEntry, scope: AssetScope, policy: PlanningPolicy) -> SkipReason? {
        if !scope.contains(entry) {
            return .outOfScope
        }
        if entry.policy == .onDemand, !policy.includeOnDemand {
            return .onDemandPolicy
        }
        if entry.checksum == nil, !policy.allowUnverifiedAssets {
            return .unverifiedDisallowed
        }
        return nil
    }

    // MARK: Space (R-SYN-11, ADR-025, sync-2 S2-06/S2-07/S2-08)

    /// The space verdict on pure data: zero fetch bytes always fit; unknown sizes count zero (the engine's headroom
    /// ledger admits them); eviction is asked for the exact shortfall; otherwise the largest fitting prefix, or
    /// `insufficient` with nothing admitted.
    static func assess(fetches: [PlannedFetch], pruneBytes: Int64, policy: PlanningPolicy, freeSpace: FreeSpace) -> SpaceAssessment {
        let need = PlanBuilder.knownBytes(fetches)
        guard need > 0 else {
            return .fits
        }
        let room = PlanBuilder.room(freeSpace: freeSpace, pruneBytes: pruneBytes)
        if need <= room {
            return .fits
        }
        if policy.evictionPermitted {
            return .needsEviction(bytes: need - room)
        }
        if policy.admitLargestFittingPrefix {
            var used: Int64 = 0
            var count = 0
            var seen = Set<TransferID>()
            for fetch in fetches {
                let bytes = seen.contains(fetch.transfer) ? 0 : max(0, fetch.entry.byteSize ?? 0)
                guard PlanBuilder.adding(used, bytes) <= room else {
                    break
                }
                used = PlanBuilder.adding(used, bytes)
                seen.insert(fetch.transfer)
                count += 1
            }
            if count > 0 {
                let rest = PlanBuilder.knownBytes(Array(fetches.dropFirst(count)), excluding: seen)
                return .partial(admittedFetches: count, skippedBytes: rest)
            }
        }
        return .insufficient(required: need, available: room)
    }

    /// `min(available, budgetRoom)` with `available = volume − reserve + pendingReclaim` and
    /// `budgetRoom = max(0, budget − (used − pruneBytes))` (ARCHITECTURE §7.10); never negative.
    private static func room(freeSpace: FreeSpace, pruneBytes: Int64) -> Int64 {
        let available = PlanBuilder.adding(freeSpace.volumeOpportunistic.subtractingClamped(max(0, freeSpace.reserveBytes)), max(0, freeSpace.pendingReclaim))
        let usedAfterPrunes = max(0, freeSpace.usedBytes.subtractingClamped(pruneBytes))
        let budgetRoom = max(0, freeSpace.budgetBytes.subtractingClamped(usedAfterPrunes))
        return max(0, min(available, budgetRoom))
    }

    /// Known bytes of `fetches`, each transfer counted once (two ids with one checksum share one download).
    private static func knownBytes(_ fetches: [PlannedFetch], excluding: Set<TransferID> = []) -> Int64 {
        var seen = excluding
        var total: Int64 = 0
        for fetch in fetches where seen.insert(fetch.transfer).inserted {
            total = PlanBuilder.adding(total, max(0, fetch.entry.byteSize ?? 0))
        }
        return total
    }

    /// Saturating addition: sizes come from untrusted manifests (R-MAN-2 bounds them, the sums must not trap).
    static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs > 0 ? Int64.max : Int64.min) : sum
    }
}

extension Int64 {
    /// `self - other`, saturating at the bounds instead of trapping.
    func subtractingClamped(_ other: Int64) -> Int64 {
        let (difference, overflow) = self.subtractingReportingOverflow(other)
        return overflow ? (other > 0 ? Int64.min : Int64.max) : difference
    }
}
