import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// Independent confirmation of S3-CONC-01 in the H-4-relevant direction: an older demotion lands after a newer
/// promotion, so a background task a user now waits for keeps the bulk priority.
@Suite("S3 confirm: background priority order")
struct S3ConfirmPriorityTests {
    @available(macOS 15.0, iOS 18.0, *)
    typealias Rig = BackgroundCoordinatorTests.Rig

    @available(macOS 15.0, iOS 18.0, *)
    @Test("confirm S3-CONC-01 (reverse): the newest promotion is kept over an older demotion", .timeLimit(.minutes(1)))
    func newestPromotionWins() async throws {
        let rig = try Rig("s3-confirm-priority")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = try #require(await coordinator.start(rig.job()) as? BackgroundTransferHandle)
        await coordinator.setPriority(.userInitiated, of: handle.name, token: handle.token)
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.75])
        await rig.driver.holdNextSnapshot(.afterListing)
        let demotion = Task { await coordinator.setPriority(.bulk, of: handle.name, token: handle.token) }
        await rig.awaitSignal("snapshot")
        await coordinator.setPriority(.userInitiated, of: handle.name, token: handle.token)
        await rig.driver.releaseSnapshot()
        await demotion.value
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(changes.last == 0.75, "newest was userInitiated (0.75); OS task ends at \(String(describing: changes.last)); changes \(changes)")
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.75])
        withExtendedLifetime(handle) {}
    }
}
