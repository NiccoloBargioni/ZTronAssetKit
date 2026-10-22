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
    let mirror: SnapshotMirror
    /// The current store and engine, replaced as a pair by a reopen after a replaced root (B-15, B-17).
    let lifecycle: ClientLifecycle
    private let backgroundRelay: BackgroundEventsRelay
    private let cacheRelay: PurgeableCacheRelay

    /// Creates a client; performs no I/O and starts nothing (P-12). Without an `environment` it builds
    /// `.live(legacyDefaultsSuiteName: configuration.legacy.defaultsSuiteName)`, so the legacy stamp is read from
    /// the configured suite (R-STO-11, ADR-048); tests pass an environment of fakes.
    public init(configuration: AssetClientConfiguration, environment: AssetEnvironment? = nil) {
        let environment = AssetClient.resolvedEnvironment(environment, for: configuration)
        self.configuration = configuration
        self.environment = environment
        let mirror = SnapshotMirror(time: environment.time)
        self.mirror = mirror
        self.lifecycle = ClientLifecycle(configuration: configuration, environment: environment, mirror: mirror)
        self.backgroundRelay = BackgroundEventsRelay()
        self.cacheRelay = PurgeableCacheRelay()
    }

    deinit {
        let lifecycle = self.lifecycle
        Task {
            await lifecycle.shutdown()
        }
    }

    /// The environment a client runs in (ADR-048): the caller's, or `.live()` reading the legacy stamp from the
    /// configured `UserDefaults` suite. Pure; builds no conformer that does I/O (P-12).
    package static func resolvedEnvironment(
        _ environment: AssetEnvironment?,
        for configuration: AssetClientConfiguration
    ) -> AssetEnvironment {
        environment ?? .live(legacyDefaultsSuiteName: configuration.legacy.defaultsSuiteName)
    }

    /// The store's configuration (ADR-048): location, storage policy, legacy layout, the manifest limits (the
    /// publication cap `maxAssetBytes`) and the snapshot install interval from the clamped tuning (S2-12). Pure.
    package static func storeConfiguration(for configuration: AssetClientConfiguration) -> StoreConfiguration {
        StoreConfiguration(
            location: configuration.location,
            policy: configuration.storage,
            legacy: configuration.legacy,
            limits: configuration.limits,
            snapshotInstallInterval: configuration.tuning.clamped().tuning.snapshotInstallInterval
        )
    }

    /// The engine serving the client now (a test seam of the facade tests).
    func currentEngine() async -> SyncEngine {
        await self.lifecycle.current().engine
    }

    /// Runs one engine call on the current pair. A pair whose root was replaced (B-15) is reopened and the call
    /// repeated on the replacement: after a `.storageUnavailable` failure that names the replaced root, or any other
    /// `.storageUnavailable` failure while the store reports it (`AssetStore.unavailableReason`, orchestrator ruling
    /// L5-R4: a sync's staging listing fails with `.ioFailure` on a vanished root); with `reopensVanishedRootFirst`,
    /// also before the call when the store reports it (a lease is a read, which a replaced root still grants). A call
    /// that a reopen's shutdown of the old engine answered with `.shutDown` is repeated on the replacement too. Any other
    /// result is returned as the engine gave it, other storage failures included (L4-R23: `ensureAvailable` stays
    /// faithful). At most `AssetClient.reopenAttempts` reopens and repetitions, so a store that vanishes again and again
    /// reports the failure instead of looping.
    private func perform<T: Sendable>(
        reopensVanishedRootFirst: Bool = false,
        _ operation: @Sendable (SyncEngine) async -> Result<T, AssetError>
    ) async throws(AssetError) -> T {
        try await self.performOnCore(reopensVanishedRootFirst: reopensVanishedRootFirst) { core in
            await operation(core.engine)
        }
    }

    /// `perform` for an operation that also needs the generation of the engine it runs on.
    private func performOnCore<T: Sendable>(
        reopensVanishedRootFirst: Bool = false,
        _ operation: @Sendable (ClientCore) async -> Result<T, AssetError>
    ) async throws(AssetError) -> T {
        try await AssetClient.performOnCore(lifecycle: self.lifecycle, reopensVanishedRootFirst: reopensVanishedRootFirst, operation)
    }

    /// The reopen path on `lifecycle`'s current pair. Static, so a task that must not keep the client alive (the
    /// background-events hand-off) can take it without capturing the client. The store's reason is read only where it
    /// decides something: before a call with `reopensVanishedRootFirst`, and after a `.storageUnavailable` failure that
    /// does not name the replaced root. A root that vanishes between the read and the call is met by the call, as before
    /// (a lease taken then is a read under B-15).
    private static func performOnCore<T: Sendable>(
        lifecycle: ClientLifecycle,
        reopensVanishedRootFirst: Bool = false,
        _ operation: @Sendable (ClientCore) async -> Result<T, AssetError>
    ) async throws(AssetError) -> T {
        var core = await lifecycle.current()
        for _ in 0..<AssetClient.reopenAttempts {
            if reopensVanishedRootFirst, await core.store.unavailableReason == .rootVanished {
                guard let replacement = await lifecycle.reopen(replacing: core.generation) else {
                    throw .shutDown
                }
                core = replacement
                continue
            }
            let result = await operation(core)
            switch result {
            case .failure(.storageUnavailable(let reason)):
                var vanished = reason == .rootVanished
                if !vanished {
                    vanished = await core.store.unavailableReason == .rootVanished
                }
                guard vanished else {
                    return try result.get()
                }
                guard let replacement = await lifecycle.reopen(replacing: core.generation) else {
                    throw .shutDown
                }
                core = replacement
            case .failure(.shutDown):
                guard await lifecycle.hasRetired(core.generation) else {
                    throw .shutDown
                }
                core = await lifecycle.current()
            default:
                return try result.get()
            }
        }
        if reopensVanishedRootFirst, await core.store.unavailableReason == .rootVanished {
            // The root vanished again after every reopen allowed: the failure is reported, never a lease under it.
            throw .storageUnavailable(.rootVanished)
        }
        return try await operation(core).get()
    }

    /// How many times one call is repeated on a replacement pair.
    static let reopenAttempts = 3

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
        _ = try await self.perform { engine in
            await engine.start()
        }
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
        try await self.perform { engine in
            await engine.awaitAsset(id, lane: priority)
        }.url
    }

    /// Keeps `ids` warm at `priority` until the handle is cancelled or released (R-CAR-1, R-CAR-4). Synchronous:
    /// one handle and one registration task (P-8); `awaitRegistration()` reports a shut-down client.
    public func prefetch(_ ids: [AssetID], priority: AssetPriority = .prefetch) -> PrefetchHandle {
        PrefetchHandle(registry: self.lifecycle, ids: ids, priority: priority)
    }

    /// Present, missing, stale and failed counts; no network, no I/O (R-SYN-10).
    public func availability(scope: AssetScope) async throws(AssetError) -> AvailabilityReport {
        try await self.perform { engine in
            await engine.availability(scope: scope)
        }
    }

    /// Fetch-first, then fetches what is missing in scope at user-initiated priority (R-SYN-10).
    public func ensureAvailable(scope: AssetScope) async throws(AssetError) -> AvailabilityReport {
        try await self.perform { engine in
            await engine.ensureAvailable(scope: scope)
        }
    }

    /// Runs `body` with the asset's URL while a lease keeps eviction, prune and purge away from it (R-CAR-8).
    /// Untyped because the body is the caller's (ADR-004); the lease is released on every path. A store whose root was
    /// replaced still grants leases (they are reads), so the store is asked first and a vanished root reopened before
    /// the lease (L5-R4): the body never gets a URL under the vanished root.
    public func withAsset<T: Sendable>(_ id: AssetID, _ body: @Sendable (URL) async throws -> T) async throws -> T {
        let (engine, lease) = try await self.perform(reopensVanishedRootFirst: true) { engine in
            await engine.acquireLease(id).map { (engine, $0) }
        }
        do {
            let value = try await body(lease.url)
            await engine.releaseLease(lease)
            return value
        } catch {
            await engine.releaseLease(lease)
            throw error
        }
    }

    /// A multi-subscriber, bounded event stream (R-SYN-12); registers asynchronously. Made after shutdown, it
    /// yields `clientShutDown` and finishes.
    public var events: AsyncStream<AssetEvent> {
        EventForwarder.stream(lifecycle: self.lifecycle, first: nil)
    }

    /// A stream that returns after registration and the initial replay. The registration runs through the reopen
    /// path, so an engine a reopen retired meanwhile is replaced rather than reported as `.shutDown`.
    public func subscribe() async throws(AssetError) -> AsyncStream<AssetEvent> {
        try await self.start()
        let registered = try await self.performOnCore { core in
            await core.engine.subscribe().map { (stream: $0, generation: core.generation) }
        }
        return EventForwarder.stream(lifecycle: self.lifecycle, first: registered)
    }

    /// Runs a sync of the retention scope now (`.force`) or when due (`.ifDue`); single-flight. The outcome carries
    /// failures, `.failed(.shutDown)` after shutdown included.
    public func sync(_ mode: SyncMode = .ifDue) async -> SyncOutcome {
        do throws(AssetError) {
            return try await self.perform { engine in
                let outcome = await engine.sync(mode)
                if case .failed(let error) = outcome {
                    switch error {
                    case .shutDown, .storageUnavailable:
                        // Handed to `perform`, which reopens a replaced root (by the store's own reason, L5-R4) or
                        // follows the replacement before reporting it; any other failure comes back as given.
                        return .failure(error)
                    default:
                        break
                    }
                }
                return .success(outcome)
            }
        } catch {
            return .failed(error)
        }
    }

    /// Whether a launch sync is due (R-SYN-9).
    public func isSyncDue() async throws(AssetError) -> Bool {
        try await self.perform { engine in
            await engine.isSyncDue()
        }
    }

    /// When the last complete sync finished (R-SYN-9).
    public func lastSyncedAt() async throws(AssetError) -> Date? {
        try await self.perform { engine in
            await engine.lastSyncedAt()
        }
    }

    /// Replaces the retention scope (R-CAR-5, ADR-027), e.g. when the paywall state changes: bulk runs fetch only
    /// what it selects, eviction removes what it excludes first, and Apple packs whose remaining entries it
    /// excludes may be released. Deletes nothing and starts nothing by itself; use `ensureAvailable(scope:)` or
    /// `sync(.force)` to fetch newly retained entries now, and `purge(.scope(_:))` to delete excluded ones.
    public func setRetentionScope(_ scope: AssetScope) async throws(AssetError) {
        try await self.start()
        // The lifecycle records the scope before applying it, so a reopen meanwhile builds its replacement with it,
        // and leaves the engine on the newest of concurrent requests.
        try await self.lifecycle.setRetentionScope(scope).get()
    }

    /// Pins assets so eviction never removes them (R-CLN-4); `purge(.all)` and `purge(.scope(_:))` still do.
    public func pin(_ ids: Set<AssetID>) async throws(AssetError) {
        try await self.perform { engine in
            await engine.setPinned(ids, pinned: true)
        }
    }

    /// Removes pins; unknown or unpinned ids are ignored.
    public func unpin(_ ids: Set<AssetID>) async throws(AssetError) {
        try await self.perform { engine in
            await engine.setPinned(ids, pinned: false)
        }
    }

    /// Bytes by kind and state, pinned, evictable, staging, orphan, source-held, free space, last cleanup
    /// (R-CLN-9).
    public func storageReport() async throws(AssetError) -> StorageReport {
        try await self.perform { engine in
            await engine.storageReport()
        }
    }

    /// A user purge (R-CLN-6); typed, a deliberate narrowing of SPEC §4.5's sketch (ADR-004).
    public func purge(_ request: PurgeRequest) async throws(AssetError) -> PurgeResult {
        try await self.perform { engine in
            await engine.purge(request)
        }
    }

    /// GC, eviction and deep verification within a time budget, for a `BGProcessingTask` handler (R-SYN-16).
    @discardableResult
    public func performMaintenance(timeBudget: TimeInterval) async throws(AssetError) -> MaintenanceReport {
        try await self.perform { engine in
            await engine.performMaintenance(timeBudget: timeBudget)
        }
    }

    /// The UI could not decode the file: quarantine, delete after grace, re-download with backoff (R-CLN-8).
    public func reportUnreadable(_ id: AssetID) async throws(AssetError) {
        try await self.perform { engine in
            await engine.reportUnreadable(id)
        }
    }

    /// In-memory metrics (R-OBS-2): engine and store counters plus the mirror's lookup hits and misses.
    public func metrics() async throws(AssetError) -> MetricsSnapshot {
        let snapshot = try await self.perform { engine in
            await engine.metrics()
        }
        return await self.withLookupCounts(snapshot)
    }

    /// `snapshot` with the mirror's lookup hits and misses, read on the main actor.
    private func withLookupCounts(_ snapshot: MetricsSnapshot) async -> MetricsSnapshot {
        let mirror = self.mirror
        let (hits, misses) = await MainActor.run { (mirror.hits, mirror.misses) }
        var snapshot = snapshot
        snapshot.lookupHits = hits
        snapshot.lookupMisses = misses
        return snapshot
    }

    /// JSON for support (R-OBS-3): versions, configuration minus secrets, state counts, last errors; built from
    /// `SyncEngine.diagnostics()`, `metrics()` and `storageReport()`.
    public func diagnosticReport() async throws(AssetError) -> Data {
        let (diagnostics, metrics, storage) = try await self.perform { engine in
            await AssetClient.reportFigures(of: engine)
        }
        let report = DiagnosticReportBuilder.report(
            configuration: self.configuration,
            diagnostics: diagnostics,
            metrics: await self.withLookupCounts(metrics),
            storage: storage
        )
        return DiagnosticReportBuilder.encode(report)
    }

    /// The report's figures, all from `engine`, so they never mix generations across a reopen. A degraded store
    /// answers neither metrics nor storage (L4-R9): empty figures stand in, and the mirror's counts are still read. A
    /// `.shutDown` from any of the three goes back to `perform`, which repeats the whole read on the replacement when a
    /// reopen retired `engine` meanwhile, and reports `.shutDown` after a real shutdown.
    private static func reportFigures(
        of engine: SyncEngine
    ) async -> Result<(EngineDiagnostics, MetricsSnapshot, StorageReport?), AssetError> {
        let diagnostics: EngineDiagnostics
        switch await engine.diagnostics() {
        case .success(let value):
            diagnostics = value
        case .failure(let error):
            return .failure(error)
        }
        let metrics = await engine.metrics()
        let storage = await engine.storageReport()
        switch (metrics, storage) {
        case (.failure(.shutDown), _), (_, .failure(.shutDown)):
            return .failure(.shutDown)
        default:
            return .success((diagnostics, (try? metrics.get()) ?? MetricsSnapshot(), try? storage.get()))
        }
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
        await self.lifecycle.shutdown()
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
        let lifecycle = self.lifecycle
        let relay = self.backgroundRelay
        Task {
            // The engine opens the store (start) before it reaches the remote source, and launches a run only when
            // one is due (T2-11, ADR-028). Through the reopen path, so an engine a reopen retires meanwhile is replaced
            // rather than answering `.shutDown` before its replacement made the session; every outcome completes the
            // handler, at once after shutdown.
            _ = try? await AssetClient.performOnCore(lifecycle: lifecycle) { core in
                await core.engine.backgroundSessionEventsPending(identifier: identifier)
            }
            await MainActor.run {
                relay.complete(identifier: identifier)
            }
        }
        return true
    }

    /// Turns a relay change into one ordered engine call (the epoch orders unordered tasks).
    @MainActor
    private func apply(_ change: ObserverChange) {
        let lifecycle = self.lifecycle
        let relay = self.cacheRelay
        switch change {
        case .unchanged:
            return
        case .start(let epoch):
            Task {
                await lifecycle.observeMemoryPressure(epoch: epoch) { level in
                    let next = await relay.purge(level: level)
                    if case .stop(let stopEpoch) = next {
                        await lifecycle.observeMemoryPressure(epoch: stopEpoch, handler: nil)
                    }
                }
            }
        case .stop(let epoch):
            Task {
                await lifecycle.observeMemoryPressure(epoch: epoch, handler: nil)
            }
        }
    }
}
