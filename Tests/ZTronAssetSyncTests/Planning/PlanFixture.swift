import Foundation
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync

/// Builders for planner inputs: entries, manifests, records, views, free space and policies (WP-F tests).
enum PlanFixture {
    /// The wall clock every planner test plans at.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A deterministic content hash for content number `n`.
    static func hash(_ n: UInt64) -> ContentHash {
        ContentHash.sha256(of: Data("plan-content-\(n)".utf8))
    }

    /// An entry: checksummed unless `content` is `nil`.
    static func entry(
        _ id: String,
        content: UInt64?,
        size: Int64? = 100,
        policy: AssetPolicy = .standard,
        tags: [String] = [],
        path: String? = nil,
        directory: [String] = ["dir"],
        ext: String = "png"
    ) -> ManifestEntry {
        ManifestEntry(
            identifier: AssetID(id),
            fileExtension: ext,
            remotePath: path ?? "media/\(id).\(ext)",
            localPathComponents: directory,
            byteSize: size,
            checksum: content.map(PlanFixture.hash),
            tags: tags,
            policy: policy
        )
    }

    /// A manifest of `entries`; the digest follows the entries, so equal lists are equal manifests.
    static func manifest(_ entries: [ManifestEntry]) -> ValidatedManifest {
        let text = entries.map { "\($0.identifier.rawValue)|\($0.remotePath)|\($0.checksum?.hex ?? "-")" }.joined(separator: ",")
        // Fixture entries never repeat an identifier.
        return (try? ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data(text.utf8)))) ?? .empty()
    }

    /// The blob key of `hash` with `ext`.
    static func key(_ hash: ContentHash, ext: String = "png") -> BlobKey {
        BlobKey(hash: hash, ext: AssetFileExtension(ext) ?? AssetFileExtension("bin")!)
    }

    /// A record present at its entry's content (a checksum-less entry gets the digest `stored`).
    static func present(_ entry: ManifestEntry, stored: ContentHash? = nil) -> AssetRecord {
        let hash = entry.checksum ?? stored ?? ContentHash.sha256(of: Data(entry.remotePath.utf8))
        return AssetRecord(
            entry: entry,
            residency: .present(blob: PlanFixture.key(hash, ext: entry.fileExtension), byteSize: entry.byteSize ?? 100, integrity: entry.checksum == nil ? .unverified : .verified),
            expectedBlob: hash,
            lastAccess: PlanFixture.now
        )
    }

    /// A record serving `old` while its entry expects other content.
    static func stale(_ entry: ManifestEntry, old: ContentHash) -> AssetRecord {
        AssetRecord(
            entry: entry,
            residency: .present(blob: PlanFixture.key(old, ext: entry.fileExtension), byteSize: 50, integrity: .verified),
            expectedBlob: entry.checksum,
            lastAccess: PlanFixture.now
        )
    }

    /// A record with `residency` and no blob.
    static func record(_ entry: ManifestEntry, _ residency: Residency, integrity: IntegrityHistory = .clean) -> AssetRecord {
        AssetRecord(entry: entry, residency: residency, expectedBlob: entry.checksum, lastAccess: PlanFixture.now, integrity: integrity)
    }

    /// A planning view; `reversed` inserts the records (and live blobs) in the opposite order with another capacity.
    static func view(applied: ValidatedManifest, records: [AssetRecord], reversed: Bool = false, generation: UInt64 = 1) -> StorePlanningView {
        var table: [AssetID: AssetRecord] = [:]
        var live = Set<ContentHash>()
        if reversed {
            table.reserveCapacity(records.count * 4 + 7)
            live.reserveCapacity(records.count * 3 + 5)
        }
        for record in reversed ? records.reversed() : records {
            table[record.entry.identifier] = record
            if let blob = record.referencedBlob {
                live.insert(blob.hash)
            }
        }
        return StorePlanningView(
            generation: generation,
            appliedManifest: applied,
            records: table,
            liveBlobs: live,
            purgeEpoch: 0,
            stamp: nil,
            syncDue: false
        )
    }

    /// Free space: plenty unless stated.
    static func space(
        free: Int64 = 1 << 40,
        used: Int64 = 0,
        budget: Int64 = Int64.max,
        reserve: Int64 = 0,
        pending: Int64 = 0
    ) -> FreeSpace {
        FreeSpace(volumeImportant: free, volumeOpportunistic: free, usedBytes: used, pendingReclaim: pending, budgetBytes: budget, reserveBytes: reserve)
    }

    /// A planning policy at `now`.
    static func policy(unverified: Bool = true, onDemand: Bool = false, prefix: Bool = true, eviction: Bool = true) -> PlanningPolicy {
        PlanningPolicy(
            allowUnverifiedAssets: unverified,
            includeOnDemand: onDemand,
            admitLargestFittingPrefix: prefix,
            evictionPermitted: eviction,
            now: PlanFixture.now
        )
    }

    /// Plans with the production planner.
    static func plan(
        _ manifest: ValidatedManifest,
        _ view: StorePlanningView,
        scope: AssetScope = .all,
        policy: PlanningPolicy = PlanFixture.policy(),
        space: FreeSpace = PlanFixture.space()
    ) -> SyncPlan {
        SyncPlanner.plan(manifest: manifest, snapshot: view, scope: scope, policy: policy, freeSpace: space)
    }
}

/// A seeded random planning scenario: an applied manifest, its records in every residency, and a newer manifest with
/// adds, removals, content and metadata changes, renames and checksum-less path changes (sync.md §4.5).
struct PlanScenario {
    var applied: ValidatedManifest
    var records: [AssetRecord]
    var manifest: ValidatedManifest

    /// Builds the scenario of `seed` over `count` applied entries.
    static func make(seed: UInt64, count: Int = 60) -> PlanScenario {
        var random = SplitMix64(seed: seed)
        func roll(_ percent: UInt64) -> Bool {
            random.next() % 100 < percent
        }
        func pick<T>(_ values: [T]) -> T {
            values[Int(random.next() % UInt64(values.count))]
        }
        let policies: [AssetPolicy] = [.essential, .standard, .standard, .onDemand]
        let tagSets: [[String]] = [[], ["x"], ["y"], ["x", "z"]]
        var appliedEntries: [ManifestEntry] = []
        var records: [AssetRecord] = []
        for index in 0..<count {
            let content: UInt64? = roll(12) ? nil : UInt64(index)
            let entry = PlanFixture.entry(
                "a\(index)",
                content: content,
                size: roll(10) ? nil : Int64(100 + index),
                policy: pick(policies),
                tags: pick(tagSets)
            )
            appliedEntries.append(entry)
            let draw = random.next() % 100
            switch draw {
            case 0..<50:
                records.append(PlanFixture.present(entry))
            case 50..<58 where content != nil:
                records.append(PlanFixture.stale(entry, old: PlanFixture.hash(10_000 + UInt64(index))))
            case 58..<66:
                records.append(PlanFixture.record(entry, .absent(.neverFetched)))
            case 66..<71:
                records.append(PlanFixture.record(entry, .absent(.evicted)))
            case 71..<75:
                records.append(PlanFixture.record(entry, .absent(.purged)))
            case 75..<80:
                records.append(PlanFixture.record(entry, .needsHeal(lastBlob: PlanFixture.key(PlanFixture.hash(UInt64(index))))))
            case 80..<85:
                let until = PlanFixture.now.addingTimeInterval(roll(50) ? 3_600 : -3_600)
                records.append(PlanFixture.record(entry, .quarantined(until: until)))
            case 85..<90:
                records.append(PlanFixture.record(entry, .failed(pick([FailureReason.notFound, .integrity, .unreadable]))))
            default:
                records.append(PlanFixture.present(entry))
            }
        }
        var newEntries: [ManifestEntry] = []
        var added = 0
        for entry in appliedEntries {
            let draw = random.next() % 100
            var next = entry
            switch draw {
            case 0..<10:
                continue
            case 10..<20:
                if entry.checksum != nil {
                    next.checksum = PlanFixture.hash(20_000 + UInt64(newEntries.count))
                } else {
                    next.remotePath = "media/moved-\(entry.identifier.rawValue).png"
                }
            case 20..<30:
                next.localPathComponents = ["moved", "dir"]
                next.tags = entry.tags + ["m"]
            case 30..<34 where entry.checksum == nil:
                next.byteSize = (entry.byteSize ?? 0) + 7
            default:
                break
            }
            newEntries.append(next)
            if roll(10) {
                // A new id: fresh content, or the content of an applied entry (a rename or a duplicate).
                let content: UInt64 = roll(40) ? UInt64(random.next() % UInt64(count)) : 30_000 + UInt64(added)
                newEntries.append(PlanFixture.entry("n\(added)", content: content, policy: pick(policies), tags: pick(tagSets)))
                added += 1
            }
        }
        return PlanScenario(applied: PlanFixture.manifest(appliedEntries), records: records, manifest: PlanFixture.manifest(newEntries))
    }

    /// The view over the scenario's records.
    func view(reversed: Bool = false) -> StorePlanningView {
        PlanFixture.view(applied: self.applied, records: self.records, reversed: reversed)
    }
}
