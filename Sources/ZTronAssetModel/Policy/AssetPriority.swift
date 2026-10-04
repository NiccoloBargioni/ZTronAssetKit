import Foundation

/// The three engine lanes (R-SYN-3): `userInitiated` > `prefetch` > `bulk`.
///
/// A job's lane is the maximum over its interests (ADR-020). The transport maps lanes to
/// `URLSessionTask.priority` as a hint (R-NET-10, ARCHITECTURE §7.5); the engine's lanes are authoritative.
public enum AssetPriority: Int, Sendable, Hashable, Comparable, CaseIterable, Codable {
    /// Background catalog sync.
    case bulk = 0
    /// Carousel neighbours (±N window, R-CAR-3).
    case prefetch = 1
    /// A page the user is looking at: overtakes everything (H-4).
    case userInitiated = 2

    /// Orders by urgency.
    public static func < (lhs: AssetPriority, rhs: AssetPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One target of the prefetch window (R-CAR-3): an identifier, its lane and its distance from the current page.
public struct PrefetchTarget: Sendable, Hashable {
    /// The asset.
    public var id: AssetID
    /// `userInitiated` for the current page, `prefetch` for neighbours.
    public var priority: AssetPriority
    /// Absolute distance from the current index (0 = current).
    public var distance: Int

    /// Creates a target.
    public init(id: AssetID, priority: AssetPriority, distance: Int) {
        self.id = id
        self.priority = priority
        self.distance = distance
    }
}

/// When a launch sync is due (R-SYN-9). Every policy also syncs when the app version changes.
public enum RefreshPolicy: Sendable, Hashable, Codable {
    /// Once per app version (the default and the prior art's behaviour).
    case oncePerAppVersion
    /// At every launch (in-memory "synced this launch" flag).
    case everyLaunch
    /// When at least this many seconds passed since the last complete sync (wall clock; a clock that went
    /// backwards by more than 300 s also makes it due, sync design §12.3).
    case atMostEvery(TimeInterval)
}

/// How a caller asks for a sync run.
public enum SyncMode: Sendable, Hashable, Codable {
    /// Run only if `RefreshPolicy` says it is due.
    case ifDue
    /// Run now (a "verify and repair" in prior-art terms).
    case force
}
