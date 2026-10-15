import Foundation
import ZTronAssetModel
import ZTronAssetStorage

extension SyncEngine {
    // MARK: Following the store's manifest (S1-13, T11, T22; F-18, F-20)

    /// A store `apply` the engine follows. While it is in flight, a publication the store supersedes waits for it
    /// (`holdForManifest`); once the store committed, the engine takes the manifest (removal events, T21, T22) whatever
    /// its caller does next, so a purge or a cancellation never leaves the engine's copy behind the store's (F-18).
    /// An `apply` that throws may have written in memory first (its index commit failed, or it was cancelled while
    /// waiting for the commit window; ADR-050): the engine then forgets every binding it remembers (an eviction or prune
    /// it never saw may have ended any of them; L4-R5) and re-reads the store once no `apply` is in flight (L4-R10).
    func applyAndFollow(_ manifest: ValidatedManifest, etag: ETag?, eviction: EvictionPlan?) async -> Result<ApplyReport, StoreError> {
        self.state.manifestCatchUps += 1
        let result: Result<ApplyReport, StoreError>
        do {
            // REENTRANCY: RE-S09 — the lifecycle: a committed apply is followed while the engine runs; jobs of pruned
            // ids end (T21) and jobs whose identity changed follow (T22); no generation guard (sync-1 S1-12).
            result = .success(try await self.store.apply(manifest, etag: etag, eviction: eviction))
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let report) where self.isRunning:
            self.applied(manifest, etag: etag, report: report)
        case .failure where self.isRunning:
            self.storeMutationFailed()
            self.state.catchUpAfterFailedApply = true
        case .success, .failure:
            break
        }
        self.manifestCaughtUp()
        return result
    }

    /// A store mutation threw after it may have unbound ids in memory (ADR-050): the binding ledger is a cache of what
    /// the engine saw the store bind, so it is dropped whole rather than trusted (L4-R5). An interest that would have
    /// been answered from it creates a job instead, which the store's own state then decides (a commit binds again).
    func storeMutationFailed() {
        self.dropBindings()
    }

    /// The store refused content that the engine's copy of the applied manifest still names for an asset (`.superseded`,
    /// or an id the publication did not bind): the store holds a newer manifest than the copy. The interests wait on a
    /// queued job of `transfer` that is not dispatched until the copy caught up, by the `apply` in flight or, when none
    /// is, by a re-read of the store; they then follow their asset's entry (T22), so a waiter is never answered
    /// `.notFound` for an asset the store still lists, and the superseded content is not downloaded again meanwhile.
    func holdForManifest(_ transfer: TransferID) {
        self.state.heldForManifest.insert(transfer)
        guard self.state.manifestCatchUps == 0 else {
            return
        }
        self.scheduleCatchUp(afterFailedApply: false)
    }

    /// Starts one re-read of the store (`catchUpWithStore`); it counts as a catch-up until it lands.
    private func scheduleCatchUp(afterFailedApply: Bool) {
        self.state.manifestCatchUps += 1
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle.
            await engine.catchUpWithStore(afterFailedApply: afterFailedApply)
        }
        if spawned == nil {
            self.manifestCaughtUp()
        }
    }

    /// Re-reads the store's applied manifest and follows it when it differs from the engine's copy. After a failed
    /// `apply` it also re-reads the store's next deadline: the work that `apply` left due (a commit to retry, a doomed
    /// blob to reap, which a job awaiting space waits for) is otherwise never run, since only a committed apply
    /// refreshed the heap's store entry.
    private func catchUpWithStore(afterFailedApply: Bool) async {
        let view: StorePlanningView?
        do {
            // REENTRANCY: f-9 (proposed) — the lifecycle; the copy is replaced only by a store view that differs from it,
            // and the held jobs are released in the same turn.
            view = try await self.store.planningView()
        } catch {
            view = nil
        }
        if self.isRunning, let view, view.appliedManifest.digest != self.state.applied.digest || view.appliedManifest.count != self.state.applied.count {
            // The store applied a manifest the engine did not see apply (its prunes, evictions and content changes
            // were never reported): every binding the engine remembers is checked against the view, and the ids of jobs
            // the view holds present at their entries' content follow there without a job (L4-R5).
            self.state.boundContent = self.state.boundContent.filter { SyncEngine.isPresent(view.records[$0.key], at: $0.value) }
            self.noteBound(from: view, ids: self.state.jobs.values.flatMap(\.assets))
            // What `applied` announces for an apply the engine made, announced for one it only finds (an apply that
            // threw after its in-memory writes): the ids the copy lists and the store no longer does, in the copy's
            // order, then the store's generation (L4-R7). A later apply of the same manifest prunes nothing, so these
            // removals would otherwise never be announced.
            let pruned = self.state.applied.entries.map(\.identifier).filter { !view.appliedManifest.contains($0) }
            self.adoptApplied(view.appliedManifest, etag: self.state.appliedETag)
            self.state.generation = max(self.state.generation, view.generation)
            for id in pruned {
                self.broadcast(.assetRemoved(id, .pruned))
            }
            self.broadcast(.snapshotChanged(generation: self.state.generation))
            self.followApplied()
        }
        if afterFailedApply, self.isRunning {
            // REENTRANCY: RE-S40 — the lifecycle; a stale entry is replaced by the newest deadline.
            await self.refreshStoreDeadline()
        }
        self.manifestCaughtUp()
    }

    /// One catch-up ended (an `apply` returned, or a re-read landed); the last one re-reads the store first when an
    /// `apply` threw meanwhile, else releases the held jobs: those whose content the copy now names elsewhere were moved
    /// by `followApplied`, the rest start again (T11).
    func manifestCaughtUp() {
        self.state.manifestCatchUps = max(0, self.state.manifestCatchUps - 1)
        guard self.state.manifestCatchUps == 0 else {
            return
        }
        if self.state.catchUpAfterFailedApply {
            self.state.catchUpAfterFailedApply = false
            if self.isRunning {
                // The held jobs stay held until the re-read landed (it ends with this method again).
                self.scheduleCatchUp(afterFailedApply: true)
                return
            }
        }
        guard !self.state.heldForManifest.isEmpty else {
            return
        }
        self.state.heldForManifest.removeAll()
        self.pump()
    }
}
