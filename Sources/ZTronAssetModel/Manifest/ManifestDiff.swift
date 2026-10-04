/// How one identifier changed between two manifests (R-MAN-4).
public enum ManifestChange: Sendable, Hashable, CaseIterable {
    /// Only in the newer manifest.
    case added
    /// Only in the older manifest.
    case removed
    /// Content identity differs (checksum, or `remotePath` for checksum-less entries, R-MAN-5, ADR-034).
    case contentChanged
    /// Same content identity; any other field differs (remotePath, directory, file name, extension, tags, policy).
    case metadataChanged
    /// Identical entries.
    case unchanged
}

/// The classification of every identifier of two manifests, each exactly once (R-MAN-4).
///
/// Lists keep manifest order: `removed` in the older manifest's order, everything else in the newer one's. That
/// makes the diff O(n) and deterministic; callers that need sorted output sort. A metadata-only change costs zero
/// downloads because the layout is content-addressed (R-SYN-8, SPEC §4.3).
///
/// The diff also carries what it takes to *apply* it (`targetOrder` and `upserts`), so the R-MAN-4 property
/// "applying `diff(a, b)` to `a` yields `b`" can be written against this contract (`applied(to:)`).
public struct ManifestDiff: Sendable, Hashable {
    /// Identifiers only in the newer manifest.
    public var added: [AssetID]
    /// Identifiers only in the older manifest.
    public var removed: [AssetID]
    /// Identifiers whose content identity changed.
    public var contentChanged: [AssetID]
    /// Identifiers whose metadata changed with the same content identity.
    public var metadataChanged: [AssetID]
    /// Identifiers whose entries are identical.
    public var unchanged: [AssetID]
    /// The newer manifest's identifiers in its order: the order `applied(to:)` reproduces.
    public var targetOrder: [AssetID]
    /// The newer manifest's entries for `added ∪ contentChanged ∪ metadataChanged`: the only entries a consumer
    /// of the diff cannot take from the older manifest.
    public var upserts: [AssetID: ManifestEntry]

    /// Creates a diff from its five classes and its application payload.
    public init(
        added: [AssetID] = [],
        removed: [AssetID] = [],
        contentChanged: [AssetID] = [],
        metadataChanged: [AssetID] = [],
        unchanged: [AssetID] = [],
        targetOrder: [AssetID] = [],
        upserts: [AssetID: ManifestEntry] = [:]
    ) {
        self.added = added
        self.removed = removed
        self.contentChanged = contentChanged
        self.metadataChanged = metadataChanged
        self.unchanged = unchanged
        self.targetOrder = targetOrder
        self.upserts = upserts
    }

    /// Classifies every identifier of `old ∪ new` in O(n).
    public static func compute(from old: ValidatedManifest, to new: ValidatedManifest) -> ManifestDiff {
        var diff = ManifestDiff()
        diff.targetOrder.reserveCapacity(new.count)
        for entry in new.entries {
            diff.targetOrder.append(entry.identifier)
            guard let previous = old.entry(for: entry.identifier) else {
                diff.added.append(entry.identifier)
                diff.upserts[entry.identifier] = entry
                continue
            }
            switch ManifestDiff.classify(old: previous, new: entry) {
            case .contentChanged:
                diff.contentChanged.append(entry.identifier)
                diff.upserts[entry.identifier] = entry
            case .metadataChanged:
                diff.metadataChanged.append(entry.identifier)
                diff.upserts[entry.identifier] = entry
            case .unchanged, .added, .removed:
                diff.unchanged.append(entry.identifier)
            }
        }
        for entry in old.entries where !new.contains(entry.identifier) {
            diff.removed.append(entry.identifier)
        }
        return diff
    }

    /// Classifies two versions of the same identifier: `.contentChanged`, `.metadataChanged` or `.unchanged`.
    public static func classify(old: ManifestEntry, new: ManifestEntry) -> ManifestChange {
        if old.contentIdentity != new.contentIdentity {
            return .contentChanged
        }
        return old == new ? .unchanged : .metadataChanged
    }

    /// The entries of the newer manifest, rebuilt from `old` plus this diff in O(n); `nil` when the diff does not
    /// belong to `old` (an unchanged identifier is missing from it). This is the R-MAN-4 "apply" operation.
    public func applied(to old: ValidatedManifest) -> [ManifestEntry]? {
        var result: [ManifestEntry] = []
        result.reserveCapacity(self.targetOrder.count)
        for id in self.targetOrder {
            if let entry = self.upserts[id] {
                result.append(entry)
            } else if let entry = old.entry(for: id) {
                result.append(entry)
            } else {
                return nil
            }
        }
        return result
    }

    /// The class of `id`, or `nil` if the diff does not mention it. O(n): for diagnostics and tests only; planners
    /// iterate the class lists instead.
    public func change(of id: AssetID) -> ManifestChange? {
        if self.added.contains(id) {
            return .added
        }
        if self.removed.contains(id) {
            return .removed
        }
        if self.contentChanged.contains(id) {
            return .contentChanged
        }
        if self.metadataChanged.contains(id) {
            return .metadataChanged
        }
        if self.unchanged.contains(id) {
            return .unchanged
        }
        return nil
    }

    /// Whether applying the diff needs no work at all.
    public var isEmpty: Bool {
        self.added.isEmpty && self.removed.isEmpty && self.contentChanged.isEmpty && self.metadataChanged.isEmpty
    }
}
