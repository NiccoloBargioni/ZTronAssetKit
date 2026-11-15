import Foundation

/// What a view asks about one asset or about the pages around the current one. Every method forwards to the client,
/// its fallback chain or its prefetch window; the asynchronous ones start the library first, as they start the client.
extension AssetLibrary {
    /// The local step alone: O(1), no I/O (R-CAR-1, P-1, P-8). `extensions` filters case-insensitively; empty means
    /// any. `nil` until `phase` is `.ready`, after shutdown, and for an asset the snapshot does not hold yet.
    public func lookup(_ id: AssetID, extensions: [String] = []) -> AssetLocation? {
        self.client.lookup(id, extensions: extensions)
    }

    /// The synchronous steps of the fallback chain (R-CAR-2): the app bundle, then the local store, for each
    /// candidate extension of `kind`; no I/O. The bundle step finds only kinds that were indexed: the ones named with
    /// `Setup.bundled(_:)`, once `start()` returned, and the ones `url(for:kind:)` was asked for.
    public func locate(_ id: AssetID, kind: AssetKind) -> ChainHit? {
        self.chain.locate(id, kind: kind)
    }

    /// The whole fallback chain (R-CAR-2): bundle, then local, then network at user-initiated priority. It indexes the
    /// bundle for `kind` first when that was not done yet (off the main thread), so it never skips the bundle step.
    public func url(for id: AssetID, kind: AssetKind) async throws(AssetError) -> URL {
        self.begin()
        // REENTRANCY: ui-4 — the chain is read after the wait, which is the point: the index now covers `kind`.
        await self.index([kind])
        switch self.chain.locate(id, kind: kind) {
        case .bundle(let url)?:
            return url
        case .local(let location)?:
            return location.url
        case nil:
            // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
            return try await self.chain.fetch(id, kind: kind)
        }
    }

    /// The network step alone (R-CAR-1): single-flight, at `priority`; a stored asset is answered without a transfer
    /// and an unknown identifier makes the client fetch the manifest first.
    public func resolve(_ id: AssetID, priority: AssetPriority = .userInitiated) async throws(AssetError) -> URL {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.resolve(id, priority: priority)
    }

    /// Runs `body` with the asset's URL while a lease keeps eviction, prune and purge away from the file (R-CAR-8):
    /// what a video player holds for as long as it plays.
    public func withAsset<T: Sendable>(_ id: AssetID, _ body: @Sendable (URL) async throws -> T) async throws -> T {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        return try await self.client.withAsset(id, body)
    }

    /// Keeps `ids` warm at `priority` until the handle is cancelled or released (R-CAR-4).
    public func prefetch(_ ids: [AssetID], priority: AssetPriority = .prefetch) -> PrefetchHandle {
        self.begin()
        return self.client.prefetch(ids, priority: priority)
    }

    /// Moves the carousel's prefetch window (R-CAR-3): the page at `current` is fetched at user-initiated priority,
    /// its neighbours up to the radius of `Setup.prefetchRadius(_:)` are prefetched, and what left the window is
    /// cancelled. Call it on every page change; it does bookkeeping only and never waits.
    public func updatePrefetchWindow(ids: [AssetID], current: Int) {
        self.begin()
        self.window.update(ids: ids, current: current)
    }

    /// Ends the prefetch window, for example when the carousel leaves the screen.
    public func cancelPrefetchWindow() {
        self.window.cancelAll()
    }

    /// Pins assets so eviction never removes them (R-CLN-4); a purge of everything or of their scope still does.
    public func pin(_ ids: Set<AssetID>) async throws(AssetError) {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        try await self.client.pin(ids)
    }

    /// Removes pins; unknown or unpinned identifiers are ignored.
    public func unpin(_ ids: Set<AssetID>) async throws(AssetError) {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        try await self.client.unpin(ids)
    }

    /// Reports a file the UI could not decode (R-CLN-8): it is quarantined and downloaded again with backoff.
    public func reportUnreadable(_ id: AssetID) async throws(AssetError) {
        self.begin()
        // REENTRANCY: ui-5 — nothing of the library is read after the client's answer.
        try await self.client.reportUnreadable(id)
    }
}
