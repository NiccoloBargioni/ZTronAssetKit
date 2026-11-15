import Foundation

/// What a settings screen, a paywall or the app delegate asks about the catalog as a whole. Every method forwards to
/// the client; the asynchronous ones start the library first, as they start the client.
extension AssetLibrary {
    /// Runs a sync of the retention scope now (`.force`) or when the refresh policy says it is due (`.ifDue`);
    /// single-flight. The outcome carries failures instead of throwing; `syncActivity` follows the run from the
    /// client's events, so it settles a moment after this returns.
    @discardableResult
    public func sync(_ mode: SyncMode = .ifDue) async -> SyncOutcome {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return await self.client.sync(mode)
    }

    /// Whether a launch sync is due (R-SYN-9).
    public func isSyncDue() async throws(AssetError) -> Bool {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.isSyncDue()
    }

    /// When the last complete sync finished (R-SYN-9).
    public func lastSyncedAt() async throws(AssetError) -> Date? {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.lastSyncedAt()
    }

    /// Present, missing, stale, failed and unverified counts of `scope` against the applied manifest; no network, no
    /// I/O (R-SYN-10).
    public func availability(scope: AssetScope) async throws(AssetError) -> AvailabilityReport {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.availability(scope: scope)
    }

    /// Fetches the manifest, then everything missing in `scope` at user-initiated priority (R-SYN-10): what a
    /// "download for offline use" button calls.
    public func ensureAvailable(scope: AssetScope) async throws(AssetError) -> AvailabilityReport {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.ensureAvailable(scope: scope)
    }

    /// Replaces the retention scope (R-CAR-5), for example when the paywall state changes. It deletes and fetches
    /// nothing by itself: `ensureAvailable(scope:)` fetches what it newly includes and `purge(_:)` deletes what it
    /// dropped.
    public func setRetentionScope(_ scope: AssetScope) async throws(AssetError) {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        try await self.client.setRetentionScope(scope)
    }

    /// Bytes by kind and state, pinned, evictable, staging, orphan, source-held, free space and the last cleanup
    /// (R-CLN-9).
    public func storageReport() async throws(AssetError) -> StorageReport {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.storageReport()
    }

    /// A user purge (R-CLN-6): everything, what is evictable, or one scope. It makes a sync due. It returns once the
    /// bytes are reclaimed, which waits out the deletion grace (`StoragePolicy.deletionGrace`, 10 s by default), so a
    /// "clear storage" button shows progress meanwhile; a caller that is cancelled during the wait leaves the purge
    /// committed.
    public func purge(_ request: PurgeRequest) async throws(AssetError) -> PurgeResult {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.purge(request)
    }

    /// Garbage collection, eviction and deep verification within a time budget, for a `BGProcessingTask` handler
    /// (R-SYN-16).
    @discardableResult
    public func performMaintenance(timeBudget: TimeInterval) async throws(AssetError) -> MaintenanceReport {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.performMaintenance(timeBudget: timeBudget)
    }

    /// The in-memory counters (R-OBS-2).
    public func metrics() async throws(AssetError) -> MetricsSnapshot {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.metrics()
    }

    /// JSON for support (R-OBS-3): versions, the configuration without secrets, state counts and the last errors.
    public func diagnosticReport() async throws(AssetError) -> Data {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.diagnosticReport()
    }

    /// A new stream of every client event (R-SYN-12), for what the published state leaves out: per-asset outcomes,
    /// transfer progress, breaker changes and maintenance reports. It registers on its first pull.
    public var events: AsyncStream<AssetEvent> {
        self.client.events
    }

    /// A stream that is registered when this returns, with the current state replayed.
    public func subscribe() async throws(AssetError) -> AsyncStream<AssetEvent> {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.subscribe()
    }

    /// Registers a derived in-memory cache, such as decoded images, to purge on memory pressure (R-CLN-11). Held
    /// weakly. Nothing is ever purged unless the chain named a source with `Setup.memoryPressure(from:)`.
    public func register(_ cache: any PurgeableCache) throws(AssetError) {
        try self.client.register(cache)
    }

    /// Unregisters a cache; idempotent.
    public func unregister(_ cache: any PurgeableCache) {
        self.client.unregister(cache)
    }

    /// Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` here when the chain enabled
    /// background transfers (R-NET-3). Returns `false`, and keeps nothing, for a session that is not the kit's. An
    /// accepted call starts the client, so it starts the library too: an app relaunched in the background for its
    /// transfers publishes its state like one launched by the user.
    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        let accepted = self.client.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
        if accepted {
            self.begin()
        }
        return accepted
    }
}
