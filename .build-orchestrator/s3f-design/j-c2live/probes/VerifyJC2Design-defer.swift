import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport
@testable import ZTronAssetSync

/// Judge c2live (scratch): the per-design end of the extended C2 windows (D1 defer).
@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    static func jReclaimRead(_ engine: isolated SyncEngine) -> Bool {
        engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0
    }

    static func jSettled(_ engine: isolated SyncEngine) -> Bool {
        !engine.followOwed && engine.state.spaceSweepFollowUp == nil && !engine.state.pumpFollowUpScheduled && !engine.state.followFollowUpScheduled
            && !engine.spaceDecisionsOwed && !engine.state.spaceDecisionsTurnScheduled
    }
}
