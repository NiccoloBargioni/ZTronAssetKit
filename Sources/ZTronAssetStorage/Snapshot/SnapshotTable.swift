import Foundation
import ZTronAssetModel

/// Builds the snapshot entries of present records (R-STO-13, ADR-016).
///
/// The store keeps the table next to its records and updates it per changed record, so publishing a snapshot wraps
/// the dictionary in O(1) (copy-on-write) instead of rebuilding 10,000 `URL`s per install (store.md §4.3).
enum SnapshotTable {
    /// The entry of `record`, or `nil` unless it is present. The URL comes from `StoreLayout.blobURL`, never from a
    /// staging path (I-4 by construction).
    static func entry(for record: AssetRecord, layout: StoreLayout) -> SnapshotEntry? {
        guard case .present(let blob, let byteSize, let integrity) = record.residency else {
            return nil
        }
        let location = AssetLocation(
            id: record.entry.identifier,
            url: layout.blobURL(blob),
            fileExtension: blob.ext,
            byteSize: byteSize,
            integrity: integrity,
            isStale: record.isStale
        )
        return SnapshotEntry(location: location, essential: record.entry.policy == .essential)
    }

    /// The whole table, built from scratch (at open, and in tests that check the incremental table).
    static func build(records: [AssetID: AssetRecord], layout: StoreLayout) -> [AssetID: SnapshotEntry] {
        var table: [AssetID: SnapshotEntry] = [:]
        for (id, record) in records {
            if let entry = SnapshotTable.entry(for: record, layout: layout) {
                table[id] = entry
            }
        }
        return table
    }
}
