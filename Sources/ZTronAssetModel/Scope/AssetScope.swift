/// Which assets an operation concerns (R-CAR-5): a value, never a closure, so ZTronCarouselCore maps paywall and
/// filter state to it without the module importing that code, and so plans stay pure and comparable.
public enum AssetScope: Sendable, Hashable, Codable {
    /// Every entry of the applied manifest.
    case all
    /// Exactly these identifiers (also makes on-demand entries eligible for `ensureAvailable`).
    case identifiers(Set<AssetID>)
    /// Entries carrying at least one of these tags (R-MAN-6).
    case tags(Set<String>)
    /// Entries whose identifier starts with this prefix (UTF-8 bytes, e.g. `"bo7.ri."`).
    case prefix(String)

    /// Whether `entry` is in scope. Pure and O(1) except for the tag intersection.
    public func contains(_ entry: ManifestEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .identifiers(let ids):
            return ids.contains(entry.identifier)
        case .tags(let tags):
            return entry.tags.contains(where: { tags.contains($0) })
        case .prefix(let prefix):
            return entry.identifier.rawValue.utf8.starts(with: prefix.utf8)
        }
    }

    /// Whether the scope names identifiers explicitly, which makes `onDemand` entries eligible (sync design §12.2).
    public var isExplicit: Bool {
        if case .identifiers = self {
            return true
        }
        return false
    }
}
