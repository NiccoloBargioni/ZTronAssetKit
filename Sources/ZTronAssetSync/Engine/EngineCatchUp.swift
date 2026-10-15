import Foundation
import ZTronAssetModel
import ZTronAssetStorage

extension SyncEngine {
    // MARK: Following the store's manifest (S1-13, T11, T22; F-18, F-20)

    /// A store `apply` the engine follows. While it is in flight, a publication the store supersedes waits for it
    /// (`holdForManifest`); once the store committed, the engine takes the manifest (removal events, T21, T22) whatever
    /// its caller does next, so a purge or a cancellation never leaves the engine's copy behind the store's (F-18).
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
        if case .success(let report) = result, self.isRunning {
            self.applied(manifest, etag: etag, report: report)
        }
        self.manifestCaughtUp()
        return result
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
        self.state.manifestCatchUps += 1
        let spawned = self.spawn(.entry) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle.
            await engine.catchUpWithStore()
        }
        if spawned == nil {
            self.manifestCaughtUp()
        }
    }

    /// Re-reads the store's applied manifest and follows it when it differs from the engine's copy.
    private func catchUpWithStore() async {
        let view: StorePlanningView?
        do {
            // REENTRANCY: f-9 (proposed) — the lifecycle; the copy is replaced only by a store view that differs from it,
            // and the held jobs are released in the same turn.
            view = try await self.store.planningView()
        } catch {
            view = nil
        }
        if self.isRunning, let view, view.appliedManifest.digest != self.state.applied.digest || view.appliedManifest.count != self.state.applied.count {
            // The ids of jobs the view holds present at their entries' content follow there without a job (L4-R5).
            self.noteBound(from: view, ids: self.state.jobs.values.flatMap(\.assets))
            // What `applied` announces for an apply the engine made, announced for one it only finds (an apply that
            // threw after its in-memory writes): the ids the copy lists and the store no longer does, in the copy's
            // order, then the store's generation (L4-R7). A later apply of the same manifest prunes nothing, so these
            // removals would otherwise never be announced.
            let pruned = self.state.applied.entries.map(\.identifier).filter { !view.appliedManifest.contains($0) }
            self.adoptApplied(view.appliedManifest, etag: self.state.appliedETag)
            self.state.generation = max(self.state.generation, view.generation)
            for id in pruned {
                self.state.boundContent[id] = nil
                self.broadcast(.assetRemoved(id, .pruned))
            }
            self.broadcast(.snapshotChanged(generation: self.state.generation))
            self.followApplied()
        }
        self.manifestCaughtUp()
    }

    /// One catch-up ended (an `apply` returned, or a re-read landed); the last one releases the held jobs: those whose
    /// content the copy now names elsewhere were moved by `followApplied`, the rest start again (T11).
    func manifestCaughtUp() {
        self.state.manifestCatchUps = max(0, self.state.manifestCatchUps - 1)
        guard self.state.manifestCatchUps == 0, !self.state.heldForManifest.isEmpty else {
            return
        }
        self.state.heldForManifest.removeAll()
        self.pump()
    }
}
