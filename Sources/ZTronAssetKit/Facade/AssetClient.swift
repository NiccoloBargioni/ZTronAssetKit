import Foundation
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync
import ZTronAssetTransport

/// The carousel-facing facade (SPEC §4.5, R-CAR-1; WP-G): a `Sendable` final class with immutable stored
/// properties only.
///
/// `init` stores values and creates actors: no I/O, no `Bundle` or `UserDefaults` read, no task, no URLSession
/// (P-12, sync-2 S2-18). `start()` opens the store and builds the remote source; every async API awaits it, so a
/// `resolve` before `start()` neither hangs nor fails. `lookup` reads the main-actor mirror only (P-1, P-8).
/// Every store-touching operation runs as an engine-owned task (ADR-039), so `shutdown()` cancels and joins it.
///
/// After `shutdown()` (R-SYN-15, ADR-042) every API fails with `AssetError.shutDown`: the async APIs throw it,
/// `sync` returns `.failed(.shutDown)`, `withAsset` throws it, a new `PrefetchHandle` reports it from
/// `awaitRegistration()` and holds nothing, `register(_:)` throws it, a new `events` stream yields `clientShutDown`
/// and finishes, and `lookup` returns `nil`. The releases (`PrefetchHandle.cancel()`, `unregister(_:)`) and
/// `shutdown()` stay idempotent no-ops; `handleBackgroundEvents` completes UIKit's handler at once.
public final class AssetClient: Sendable {
    /// The configuration.
    public let configuration: AssetClientConfiguration
    private let environment: AssetEnvironment
    private let mirror: SnapshotMirror
    private let store: AssetStore
    private let engine: SyncEngine
    private let backgroundRelay: BackgroundEventsRelay
    private let cacheRelay: PurgeableCacheRelay

    /// Creates a client; performs no I/O and starts nothing (P-12).
    public init(configuration: AssetClientConfiguration, environment: AssetEnvironment = .live()) {
        self.configuration = configuration
        self.environment = environment
        let mirror = SnapshotMirror(time: environment.time)
        let store = AssetStore(
            configuration: StoreConfiguration(
                location: configuration.location,
                policy: configuration.storage,
                legacy: configuration.legacy
            ),
            environment: StoreEnvironment(environment: environment, snapshotSink: mirror)
        )
        self.mirror = mirror
        self.store = store
        self.engine = SyncEngine(
            store: store,
            environment: environment,
            configuration: EngineConfiguration(
                tuning: configuration.tuning.clamped().tuning,
                storage: configuration.storage,
                network: configuration.network,
                power: configuration.power,
                refresh: configuration.refresh,
                remote: configuration.remote,
                limits: configuration.limits,
                retentionScope: configuration.retentionScope
            )
        )
        self.backgroundRelay = BackgroundEventsRelay()
        self.cacheRelay = PurgeableCacheRelay()
    }

    deinit {
        let engine = self.engine
        Task {
            await engine.shutdown()
        }
    }

    /// The executor for bounded blocking units off the cooperative pool (ADR-003, C2), shared with the fallback
    /// chain's bundle enumeration (sync-2 S2-13).
    var bulkExecutor: any BlockingExecutor {
        self.environment.bulkExecutor
    }

    /// Opens the store, publishes the first snapshot, builds the remote source and launches the due run.
    /// Idempotent and single-flight; returns when the client is ready, not when the sync finished. Throws
    /// `.storageUnavailable` when the store cannot be opened (every async API then throws it too) and `.shutDown`
    /// after shutdown.
    public func start() async throws(AssetError) {
        _ = try await self.engine.start().get()
    }

    /// The local step of the fallback chain: O(1), zero I/O, main actor only (R-CAR-1, P-1, P-8). `extensions`
    /// filters case-insensitively; empty means any. `nil` after shutdown.
    @MainActor
    public func lookup(_ id: AssetID, extensions: [String] = []) -> AssetLocation? {
        self.mirror.lookup(id, extensions: extensions)
    }

    /// The network step: single-flight, at `priority`, fetch-first for unknown ids (R-CAR-1, R-SYN-4). The
    /// caller's cancellation affects only this caller (H-3).
    public func resolve(_ id: AssetID, priority: AssetPriority = .userInitiated) async throws(AssetError) -> URL {
        try await self.engine.awaitAsset(id, lane: priority).get().url
    }

    /// Keeps `ids` warm at `priority` until the handle is cancelled or released (R-CAR-1, R-CAR-4). Synchronous:
    /// one handle and one registration task (P-8); `awaitRegistration()` reports a shut-down client.
    public func prefetch(_ ids: [AssetID], priority: AssetPriority = .prefetch) -> PrefetchHandle {
        PrefetchHandle(registry: self.engine, ids: ids, priority: priority)
    }

    /// Present, missing, stale and failed counts; no network, no I/O (R-SYN-10).
    public func availability(scope: AssetScope) async throws(AssetError) -> AvailabilityReport {
        try await self.engine.availability(scope: scope).get()
    }

    /// Fetch-first, then fetches what is missing in scope at user-initiated priority (R-SYN-10).
    public func ensureAvailable(scope: AssetScope) async throws(AssetError) -> AvailabilityReport {
        try await self.engine.ensureAvailable(scope: scope).get()
    }

    /// Runs `body` with the asset's URL while a lease keeps eviction, prune and purge away from it (R-CAR-8).
    /// Untyped because the body is the caller's (ADR-004); the lease is released on every path.
    public func withAsset<T: Sendable>(_ id: AssetID, _ body: @Sendable (URL) async throws -> T) async throws -> T {
        let lease = try await self.engine.acquireLease(id).get()
        do {
            let value = try await body(lease.url)
            await self.engine.releaseLease(lease)
            return value
        } catch {
            await self.engine.releaseLease(lease)
            throw error
        }
    }

    /// A multi-subscriber, bounded event stream (R-SYN-12); registers asynchronously. Made after shutdown, it
    /// yields `clientShutDown` and finishes.
    public var events: AsyncStream<AssetEvent> {
        self.engine.makeEventStream()
    }

    /// A stream that returns after registration and the initial replay.
    public func subscribe() async throws(AssetError) -> AsyncStream<AssetEvent> {
        try await self.engine.subscribe().get()
    }

    /// Runs a sync of the retention scope now (`.force`) or when due (`.ifDue`); single-flight. The outcome carries
    /// failures, `.failed(.shutDown)` after shutdown included.
    public func sync(_ mode: SyncMode = .ifDue) async -> SyncOutcome {
        await self.engine.sync(mode)
    }

    /// Whether a launch sync is due (R-SYN-9).
    public func isSyncDue() async throws(AssetError) -> Bool {
        try await self.engine.isSyncDue().get()
    }

    /// When the last complete sync finished (R-SYN-9).
    public func lastSyncedAt() async throws(AssetError) -> Date? {
        try await self.engine.lastSyncedAt().get()
    }

    /// Replaces the retention scope (R-CAR-5, ADR-027), e.g. when the paywall state changes: bulk runs fetch only
    /// what it selects, eviction removes what it excludes first, and Apple packs whose remaining entries it
    /// excludes may be released. Deletes nothing and starts nothing by itself; use `ensureAvailable(scope:)` or
    /// `sync(.force)` to fetch newly retained entries now, and `purge(.scope(_:))` to delete excluded ones.
    public func setRetentionScope(_ scope: AssetScope) async throws(AssetError) {
        try await self.engine.setRetentionScope(scope).get()
    }

    /// Pins assets so eviction never removes them (R-CLN-4); `purge(.all)` and `purge(.scope(_:))` still do.
    public func pin(_ ids: Set<AssetID>) async throws(AssetError) {
        try await self.engine.setPinned(ids, pinned: true).get()
    }

    /// Removes pins; unknown or unpinned ids are ignored.
    public func unpin(_ ids: Set<AssetID>) async throws(AssetError) {
        try await self.engine.setPinned(ids, pinned: false).get()
    }

    /// Bytes by kind and state, pinned, evictable, staging, orphan, source-held, free space, last cleanup
    /// (R-CLN-9).
    public func storageReport() async throws(AssetError) -> StorageReport {
        try await self.engine.storageReport().get()
    }

    /// A user purge (R-CLN-6); typed, a deliberate narrowing of SPEC §4.5's sketch (ADR-004).
    public func purge(_ request: PurgeRequest) async throws(AssetError) -> PurgeResult {
        try await self.engine.purge(request).get()
    }

    /// GC, eviction and deep verification within a time budget, for a `BGProcessingTask` handler (R-SYN-16).
    @discardableResult
    public func performMaintenance(timeBudget: TimeInterval) async throws(AssetError) -> MaintenanceReport {
        try await self.engine.performMaintenance(timeBudget: timeBudget).get()
    }

    /// The UI could not decode the file: quarantine, delete after grace, re-download with backoff (R-CLN-8).
    public func reportUnreadable(_ id: AssetID) async throws(AssetError) {
        try await self.engine.reportUnreadable(id).get()
    }

    /// In-memory metrics (R-OBS-2): engine and store counters plus the mirror's lookup hits and misses.
    public func metrics() async throws(AssetError) -> MetricsSnapshot {
        var snapshot = try await self.engine.metrics().get()
        let mirror = self.mirror
        let (hits, misses) = await MainActor.run { (mirror.hits, mirror.misses) }
        snapshot.lookupHits = hits
        snapshot.lookupMisses = misses
        return snapshot
    }

    /// JSON for support (R-OBS-3): versions, configuration minus secrets, state counts, last errors; built from
    /// `SyncEngine.diagnostics()`, `metrics()` and `storageReport()`.
    public func diagnosticReport() async throws(AssetError) -> Data {
        fatalError("WP-G: AssetClient.diagnosticReport not implemented")
    }

    /// Registers a derived in-memory cache (decoded images) to purge on memory pressure (R-CLN-11, ADR-044). Held
    /// weakly; the engine observes `AssetEnvironment.memoryPressure` only while a registered cache is alive. Throws
    /// `.shutDown` after shutdown.
    @MainActor
    public func register(_ cache: any PurgeableCache) throws(AssetError) {
        guard let change = self.cacheRelay.add(cache) else {
            throw .shutDown
        }
        self.apply(change)
    }

    /// Unregisters a cache; idempotent, also after shutdown.
    @MainActor
    public func unregister(_ cache: any PurgeableCache) {
        self.apply(self.cacheRelay.remove(cache))
    }

    /// Cancels every task, finishes every stream, flushes the index; every API fails with `.shutDown` afterwards
    /// and `lookup` returns `nil` (R-SYN-15, ADR-042). Idempotent.
    public func shutdown() async {
        await self.engine.shutdown()
        let mirror = self.mirror
        let cacheRelay = self.cacheRelay
        await MainActor.run {
            mirror.reset()
            cacheRelay.close()
        }
    }

    /// Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` here (R-NET-3). Returns
    /// `false` for identifiers that are not ours; the handler is called once the session's events are staged, or
    /// at once after shutdown.
    @MainActor
    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard self.backgroundRelay.accept(identifier: identifier, completionHandler: completionHandler) else {
            return false
        }
        let engine = self.engine
        let relay = self.backgroundRelay
        Task {
            _ = await engine.backgroundSessionEventsPending(identifier: identifier)
            await MainActor.run {
                relay.complete(identifier: identifier)
            }
        }
        return true
    }

    /// Turns a relay change into one ordered engine call (the epoch orders unordered tasks).
    @MainActor
    private func apply(_ change: ObserverChange) {
        let engine = self.engine
        let relay = self.cacheRelay
        switch change {
        case .unchanged:
            return
        case .start(let epoch):
            Task {
                _ = await engine.observeMemoryPressure(epoch: epoch) { level in
                    let next = await relay.purge(level: level)
                    if case .stop(let stopEpoch) = next {
                        _ = await engine.observeMemoryPressure(epoch: stopEpoch, handler: nil)
                    }
                }
            }
        case .stop(let epoch):
            Task {
                _ = await engine.observeMemoryPressure(epoch: epoch, handler: nil)
            }
        }
    }
}
