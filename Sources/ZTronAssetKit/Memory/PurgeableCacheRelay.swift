import ZTronAssetModel

/// What a registration change asks of the engine's memory-pressure observer (R-CLN-11).
package enum ObserverChange: Sendable, Hashable {
    /// Nothing to do.
    case unchanged
    /// The first live cache arrived: start the observer with this epoch.
    case start(epoch: UInt64)
    /// No live cache remains: stop the observer with this epoch.
    case stop(epoch: UInt64)
}

/// The carousel's purgeable caches, held weakly on the main actor (R-CLN-11, MAY; ADR-044).
///
/// Main-actor bookkeeping only: no I/O, no task. The facade turns each `ObserverChange` into one
/// `SyncEngine.observeMemoryPressure(epoch:handler:)` call; epochs are allocated here, on the main actor, in call
/// order, so the engine applies only the newest of calls that reach it out of order. A cache that deallocates
/// without unregistering is dropped at the next registration change or pressure event, and the observer stops when
/// none remains, so the engine can become idle-silent again (R-SYN-14). `close()` (shutdown) refuses further
/// registrations (R-SYN-15).
@MainActor
package final class PurgeableCacheRelay {
    private struct Entry {
        weak var cache: (any PurgeableCache)?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var epoch: UInt64 = 0
    private var observing = false
    package private(set) var isClosed = false

    /// Starts empty; callable from the nonisolated `AssetClient.init` (P-12).
    nonisolated package init() {}

    /// Caches still alive.
    package var liveCount: Int {
        self.entries.values.reduce(0) { $0 + ($1.cache == nil ? 0 : 1) }
    }

    /// Adds `cache` (idempotent); `nil` after `close()`.
    package func add(_ cache: any PurgeableCache) -> ObserverChange? {
        guard !self.isClosed else {
            return nil
        }
        self.entries[ObjectIdentifier(cache)] = Entry(cache: cache)
        return self.reconcile()
    }

    /// Removes `cache`; unknown caches are ignored.
    package func remove(_ cache: any PurgeableCache) -> ObserverChange {
        self.entries.removeValue(forKey: ObjectIdentifier(cache))
        return self.reconcile()
    }

    /// Purges every live cache, in registration-independent but deterministic order (by object identity), and
    /// drops dead entries.
    package func purge(level: MemoryPressureLevel) -> ObserverChange {
        let live = self.entries.sorted { $0.key < $1.key }.compactMap { $0.value.cache }
        for cache in live {
            cache.purge(level: level)
        }
        return self.reconcile()
    }

    /// Shutdown: drops every cache and refuses further registrations. The engine's shutdown stops the observer.
    package func close() {
        self.isClosed = true
        self.entries = [:]
        self.observing = false
    }

    private func reconcile() -> ObserverChange {
        self.entries = self.entries.filter { $0.value.cache != nil }
        let wanted = !self.entries.isEmpty
        guard wanted != self.observing else {
            return .unchanged
        }
        self.observing = wanted
        self.epoch += 1
        return wanted ? .start(epoch: self.epoch) : .stop(epoch: self.epoch)
    }
}
