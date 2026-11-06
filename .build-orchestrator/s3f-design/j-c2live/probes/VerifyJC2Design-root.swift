import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport
@testable import ZTronAssetSync

/// Judge c2live (scratch): the per-design end of the extended C2 windows (D3 root).
@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    static func jReclaimRead(_ engine: isolated SyncEngine) -> Bool {
        engine.state.storeWorkRuns == 0 && (engine.state.freeSpace?.pendingReclaim == 0 || engine.state.eventsAfterFollow.contains { event in
            if case .read(let space, _) = event {
                return space.pendingReclaim == 0
            }
            return false
        })
    }

    static func jSettled(_ engine: isolated SyncEngine) -> Bool {
        !engine.followOwed && engine.state.spaceSweepFollowUp == nil && !engine.state.pumpFollowUpScheduled && !engine.state.followFollowUpScheduled
            && engine.state.eventsAfterFollow.isEmpty && !engine.state.drainFollowUpScheduled && !engine.state.drainingAfterFollow
    }
}
