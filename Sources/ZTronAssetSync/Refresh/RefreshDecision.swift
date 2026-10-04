import Foundation
import ZTronAssetModel

/// The pure refresh decision of R-SYN-9 (sync.md §12.3), exhaustively tested.
package enum RefreshDecision {
    /// How far the wall clock may run backwards behind the stamp before `.atMostEvery` treats the stamp as
    /// untrustworthy and syncs rather than staying stuck.
    package static let backwardsClockTolerance: TimeInterval = 300

    /// Whether a launch sync is due.
    ///
    /// Due when the persisted "sync due" flag is set (purge, OS-purge recovery, partial legacy migration), when
    /// there is no stamp, or when the app version changed — under **every** policy. Otherwise
    /// `.oncePerAppVersion` is not due, `.everyLaunch` is due until a run completed in this process, and
    /// `.atMostEvery(i)` is due once `i` seconds of wall time passed since the stamp, or when the clock went
    /// backwards by more than `backwardsClockTolerance`. A non-finite or non-positive interval is due, except
    /// `+infinity`, which never is.
    package static func isSyncDue(
        policy: RefreshPolicy,
        stamp: SyncStamp?,
        syncDueFlag: Bool,
        appVersion: String,
        now: Date,
        syncedThisLaunch: Bool
    ) -> Bool {
        if syncDueFlag {
            return true
        }
        guard let stamp else {
            return true
        }
        if stamp.appVersion != appVersion {
            return true
        }
        switch policy {
        case .oncePerAppVersion:
            return false
        case .everyLaunch:
            return !syncedThisLaunch
        case .atMostEvery(let interval):
            if interval == .infinity {
                return false
            }
            guard interval.isFinite, interval > 0 else {
                return true
            }
            let elapsed = now.timeIntervalSince(stamp.completedAt)
            if elapsed < -RefreshDecision.backwardsClockTolerance {
                return true
            }
            return elapsed >= interval
        }
    }
}
