import Foundation
import ZTronAssetModel

/// Staging GC (R-CLN-3, ADR-028, store.md §6.3): after launch reconciliation and after every sync.
extension AssetStore {
    /// `collectStaging(keeping:)`.
    func performCollectStaging(keeping claimed: Set<TransferID>) async throws(StoreError) -> CleanupResult {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        guard let layout = self.state.core.layout else {
            throw .notOpen
        }
        let interval = self.environment.log.interval(.gc, category: .store, "staging")
        defer {
            interval.end()
        }
        let fileSystem = self.environment.fileSystem
        let directory = layout.stagingDirectory
        // REENTRANCY: R14 — the phase and writability; the listing is a snapshot decided against the caller's claims and
        // the files' ages at sweep time (a file written after the listing is not in it, so it is never collected now).
        let listing = await self.runUnit(on: self.environment.metadataExecutor) {
            CleanupUnits.list(directory, fileSystem: fileSystem)
        }
        try self.checkLive()
        try self.checkWritable()
        let items: [FileItemInfo]
        switch listing {
        case .success(let values):
            items = values
        case .failure(let error):
            throw .fileSystem(error)
        }
        let garbage = StagingCollection.garbage(
            items,
            claimed: claimed,
            now: self.environment.time.now(),
            policy: self.configuration.policy
        ).map { (url: directory.appendingPathComponent($0.name, isDirectory: $0.kind == .directory), bytes: $0.byteSize) }
        // REENTRANCY: c-1 (proposed) — see `removeInUnits`.
        let (_, result) = try await self.removeInUnits(garbage)
        if result.filesRemoved > 0 {
            self.stampCleanup()
        }
        return result
    }
}

/// The staging GC decision (pure).
enum StagingCollection {
    /// The items of a `staging/` listing to remove, sorted by name: foreign names always; our names older than
    /// `stagingMaxAge`, or unclaimed and older than `stagingClaimGrace`. Items whose age is unknown or negative (a clock
    /// set back) are kept.
    static func garbage(_ items: [FileItemInfo], claimed: Set<TransferID>, now: Date, policy: StoragePolicy) -> [FileItemInfo] {
        items.sorted { $0.name < $1.name }.filter { item in
            guard item.kind == .file, let name = StagingFileName(parsing: item.name) else {
                return true
            }
            guard let modified = item.modifiedAt else {
                return false
            }
            let age = now.timeIntervalSince(modified)
            if age > policy.stagingMaxAge {
                return true
            }
            return !claimed.contains(name.transfer) && age > policy.stagingClaimGrace
        }
    }
}
