import ZTronAssetModel
import ZTronAssetSync

/// The engine side of a prefetch handle (R-CAR-4): group interests registered and released by token.
///
/// `SyncEngine` conforms, and so does the facade's `ClientLifecycle`, through which every `AssetClient` handle
/// registers: it binds each facade token to the engine token of the generation it was registered with, so a release
/// after a reopen never reaches another engine's token (G-1). Handle tests use a fake whose registration can be held
/// back, which is how the sync-1 S1-05 regression (a re-lane must never let the asset's interest drop to zero) is
/// tested without the engine; end to end, the re-lane also relies on the engine's pending claims (L5-R1).
package protocol PrefetchRegistry: Sendable {
    /// Registers one group interest; `.failure(.shutDown)` after shutdown, holding nothing (R-SYN-15).
    func registerGroup(_ ids: [AssetID], lane: AssetPriority) async -> Result<InterestToken, AssetError>
    /// Releases a group interest; unknown tokens are ignored, so releasing twice is harmless.
    func releaseGroup(_ token: InterestToken) async
}

extension SyncEngine: PrefetchRegistry {}

/// A prefetch registration (R-CAR-4): cancels on `cancel()` and on deinit, leaving no transfer for nobody.
///
/// Only `let`s of `Sendable` types, so `Sendable` without escapes. Every release is ordered after the registration
/// it undoes, so "cancel immediately after prefetch" cannot leave a transfer running for nobody (sync.md §6.3).
/// `cancel(after:)` also orders it after another handle's registration **and keeps this handle alive until that
/// ordered release ran**, so its deinit cannot start an earlier, unordered release: moving a window never lets an
/// asset's interest drop to zero in between (sync-1 S1-05). The deinit release that follows is a no-op, because the
/// registry ignores a token it already released.
public final class PrefetchHandle: Sendable {
    private let registry: any PrefetchRegistry
    private let registration: Task<Result<InterestToken, AssetError>, Never>

    /// Registers `ids` at `priority` in one task (P-8: the caller never waits).
    package init(registry: any PrefetchRegistry, ids: [AssetID], priority: AssetPriority) {
        self.registry = registry
        self.registration = Task {
            await registry.registerGroup(ids, lane: priority)
        }
    }

    deinit {
        PrefetchHandle.release(self.registration, from: self.registry)
    }

    /// Suspends until the engine registered this handle's interest. Throws `.shutDown` when the client was shut
    /// down first (R-SYN-15); the handle then holds nothing and `cancel()` is a no-op.
    public func awaitRegistration() async throws(AssetError) {
        if case .failure(let error) = await self.registration.value {
            throw error
        }
    }

    /// Releases the interest; idempotent (the registry ignores tokens it no longer knows).
    public func cancel() {
        PrefetchHandle.release(self.registration, from: self.registry)
    }

    /// Releases the interest only after `successor` registered: a priority change keeps the asset wanted
    /// throughout, so its transfer is promoted, never restarted. The task holds `self`, so this handle's deinit (and
    /// its own release) runs only after the ordered release (sync-1 S1-05).
    package func cancel(after successor: PrefetchHandle) {
        Task {
            _ = await successor.registration.value
            await PrefetchHandle.releaseNow(self.registration, from: self.registry)
        }
    }

    private static func release(_ registration: Task<Result<InterestToken, AssetError>, Never>, from registry: any PrefetchRegistry) {
        Task {
            await PrefetchHandle.releaseNow(registration, from: registry)
        }
    }

    private static func releaseNow(
        _ registration: Task<Result<InterestToken, AssetError>, Never>,
        from registry: any PrefetchRegistry
    ) async {
        if case .success(let token) = await registration.value {
            await registry.releaseGroup(token)
        }
    }
}

/// The pure prefetch window (R-CAR-3).
public enum PrefetchWindow {
    /// The targets around `current` in priority order: current, +1, −1, +2, −2, … up to `radius` (negative radii
    /// count as 0). Out-of-range indices are skipped, a repeated id keeps its first (closest) occurrence, the
    /// current page is `.userInitiated` and every neighbour `.prefetch`. An out-of-range `current` yields nothing.
    public static func targets(ids: [AssetID], current: Int, radius: Int) -> [PrefetchTarget] {
        guard ids.indices.contains(current) else {
            return []
        }
        var result: [PrefetchTarget] = [PrefetchTarget(id: ids[current], priority: .userInitiated, distance: 0)]
        var seen: Set<AssetID> = [ids[current]]
        let reach = max(radius, 0)
        var distance = 1
        while distance <= reach {
            for index in [current + distance, current - distance] where ids.indices.contains(index) {
                let id = ids[index]
                if seen.insert(id).inserted {
                    result.append(PrefetchTarget(id: id, priority: .prefetch, distance: distance))
                }
            }
            distance += 1
        }
        return result
    }
}

/// Keeps the carousel's window prefetched (R-CAR-3; WP-G). Main-actor bookkeeping only: O(radius) per update,
/// no I/O, no await.
@MainActor
public final class PrefetchWindowController {
    private let client: AssetClient
    private let radius: Int
    private var handles: [AssetID: (handle: PrefetchHandle, priority: AssetPriority)]

    /// Creates a controller (callable from any isolation). `radius` defaults to the client's
    /// `configuration.prefetchRadius` (R-CAR-3, ADR-048).
    nonisolated public init(client: AssetClient, radius: Int? = nil) {
        self.client = client
        self.radius = PrefetchWindowController.resolvedRadius(radius, configuration: client.configuration)
        self.handles = [:]
    }

    /// The window radius a controller uses: the explicit one, else the configuration's `prefetchRadius`. Pure.
    nonisolated package static func resolvedRadius(_ radius: Int?, configuration: AssetClientConfiguration) -> Int {
        radius ?? configuration.prefetchRadius
    }

    /// Moves the window: starts what entered, cancels what left, re-lanes what changed priority (new handle first,
    /// old one released after it registered, sync-1 S1-05). After shutdown every new handle holds nothing.
    public func update(ids: [AssetID], current: Int) {
        let targets = PrefetchWindow.targets(ids: ids, current: current, radius: self.radius)
        var next: [AssetID: (handle: PrefetchHandle, priority: AssetPriority)] = [:]
        for target in targets {
            if let existing = self.handles[target.id] {
                if existing.priority == target.priority {
                    next[target.id] = existing
                } else {
                    let replacement = self.client.prefetch([target.id], priority: target.priority)
                    existing.handle.cancel(after: replacement)
                    next[target.id] = (replacement, target.priority)
                }
            } else {
                next[target.id] = (self.client.prefetch([target.id], priority: target.priority), target.priority)
            }
        }
        for (id, entry) in self.handles where next[id] == nil {
            entry.handle.cancel()
        }
        self.handles = next
    }

    /// Cancels everything.
    public func cancelAll() {
        for entry in self.handles.values {
            entry.handle.cancel()
        }
        self.handles = [:]
    }
}
