import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
@testable import ZTronAssetTransport

/// Verifier probes (close-out cycle 2, reqs lens): two properties of S3D-1's fix that no committed test pins.
@Suite("S3D c2 reqs probes")
struct S3DC2ReqsProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    typealias Rig = BackgroundCoordinatorTests.Rig

    private static func controlsDelivered(_ handle: BackgroundTransferHandle) async {
        let controlTask = handle.controlTask
        await withTaskCancellationHandler {
            await controlTask.value
        } onCancel: {
            controlTask.cancel()
        }
    }

    /// MJ: the serial must be taken after the entry token check. A replaced handle's control, buffered behind its
    /// in-flight write when a start joined the task, reaches the coordinator with a stale token while the joining
    /// handle's newer request is listing; it must not supersede that request.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: PROBE a replaced handle's stale buffered control never supersedes the joining handle's newer request", .timeLimit(.minutes(1)))
    func staleControlNeverSupersedes() async throws {
        let rig = try Rig("probe-c2-mj")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = try #require(await coordinator.start(rig.job(1)) as? BackgroundTransferHandle)
        await rig.driver.holdNextPriority()
        first.setPriority(.userInitiated)
        await rig.awaitSignal("priority held")
        first.setPriority(.prefetch)
        let second = try #require(await coordinator.start(rig.job(2)) as? BackgroundTransferHandle)
        #expect(second.name == first.name)
        #expect(await run(first).terminal == .failed(.cancelled(.byClient)))
        await rig.driver.holdNextSnapshot(.afterListing)
        second.setPriority(.bulk)
        await rig.awaitSignal("snapshot")
        await rig.driver.releasePriority()
        await Self.controlsDelivered(first)
        await rig.driver.releaseSnapshot()
        second.cancel()
        #expect(await run(second).terminal == .failed(.cancelled(.byClient)))
        await Self.controlsDelivered(second)
        #expect(!Task.isCancelled)
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(changes == [0.75, 0.25], "the joining handle's bulk (0.25) must reach the OS task: \(changes)")
    }

    /// MK: a rewrite that itself lands after a third, newer write must be followed by the newest value again
    /// (`while`, not a single re-check).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: PROBE a rewrite that lands after a newer write is followed by the newest value again", .timeLimit(.minutes(1)))
    func rewriteThatLandsLast() async throws {
        let rig = try Rig("probe-c2-mk")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = try #require(await coordinator.start(rig.job(1)) as? BackgroundTransferHandle)
        await rig.driver.holdNextPriority()
        first.setPriority(.userInitiated)
        await rig.awaitSignal("priority held")
        let second = try #require(await coordinator.start(rig.job(2)) as? BackgroundTransferHandle)
        #expect(await run(first).terminal == .failed(.cancelled(.byClient)))
        second.setPriority(.bulk)
        await rig.awaitSignal("priority")
        await rig.driver.holdNextPriority()
        await rig.driver.releasePriority()
        await rig.awaitSignal("priority held")
        second.setPriority(.prefetch)
        await rig.awaitSignal("priority")
        await rig.driver.releasePriority()
        await Self.controlsDelivered(first)
        #expect(!Task.isCancelled)
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(Array(changes.prefix(4)) == [0.25, 0.75, 0.5, 0.25], "staged: \(changes)")
        #expect(changes.last == 0.5, "the newest request was prefetch (0.5); the OS task ends at \(String(describing: changes.last)); changes \(changes)")
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.5])
        withExtendedLifetime(second) {}
    }
}
