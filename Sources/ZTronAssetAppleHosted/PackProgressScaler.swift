import Foundation
import ZTronAssetModel

/// Turns the progress of a whole pack download into byte values of one asset (R-APL-2, transport.md §11.3).
///
/// A pack holds many assets and the OS reports progress for the pack only, so a waiter for one asset sees the
/// pack's completed fraction times the asset's catalog size: the engine's per-asset progress (R-SYN-12) stays in the
/// asset's own byte units whatever the pack's size. Values are quantised to steps of at least 1 % of the asset (the
/// step rounds up, so a 150-byte asset steps by 2; the final value is always reported), never decrease and never
/// exceed the asset size, so one pack download yields at most 101 progress elements per waiter however chatty the OS
/// is: after the first value, at most 100 full steps fit below the asset size, and a final partial step replaces one.
struct PackProgressScaler: Sendable {
    /// The asset's catalog size.
    let expectedBytes: Int64
    /// The last value handed out, `nil` before the first.
    private(set) var lastReported: Int64?

    /// A scaler for an asset of `expectedBytes`.
    init(expectedBytes: Int64) {
        self.expectedBytes = expectedBytes
        self.lastReported = nil
    }

    /// The byte value to report for `progress`, or `nil` when nothing new is worth reporting (an unknown total,
    /// no advance, or less than one step since the last value).
    mutating func received(for progress: PackProgress) -> Int64? {
        guard self.expectedBytes > 0, progress.total > 0 else {
            return nil
        }
        let completed = min(max(progress.completed, 0), progress.total)
        let fraction = Double(completed) / Double(progress.total)
        let value = min(self.expectedBytes, Int64((Double(self.expectedBytes) * fraction).rounded(.down)))
        if let last = self.lastReported {
            let step = self.step
            guard value > last, value - last >= step || value == self.expectedBytes else {
                return nil
            }
        }
        self.lastReported = value
        return value
    }

    /// One percent of the asset, rounded up (never zero for a positive size, never overflowing).
    private var step: Int64 {
        self.expectedBytes / 100 + (self.expectedBytes % 100 == 0 ? 0 : 1)
    }
}

extension PackProgress {
    /// Reads a live `Foundation.Progress` once, at the backend boundary (D-12, APPLE-API-VERIFICATION §1.3): the
    /// SDK hands out a mutable reference that keeps changing, and only a value may cross into the tier's logic. An
    /// indeterminate total (`totalUnitCount ≤ 0`) becomes a zero total, which the scaler ignores; completed units
    /// are clamped into `0...total`.
    init(snapshotOf progress: Progress) {
        let total = progress.totalUnitCount
        guard total > 0 else {
            self.init(completed: 0, total: 0)
            return
        }
        self.init(completed: min(max(progress.completedUnitCount, 0), total), total: total)
    }
}
