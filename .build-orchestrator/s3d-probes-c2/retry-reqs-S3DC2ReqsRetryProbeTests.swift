import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
@testable import ZTronAssetTransport

/// Verifier probes (close-out cycle 2, reqs lens, retry): properties of S3D-1's fix that the committed suite may not pin.
/// Scratch only; never committed.
@Suite("S3D c2 reqs retry probes")
struct S3DC2ReqsRetryProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    typealias Rig = BackgroundCoordinatorTests.Rig

    /// Awaits a handle's control task; cancelled past the hang guard so a timed-out probe ends at once.
    private static func drained(_ handle: BackgroundTransferHandle) async {
        let controlTask = handle.controlTask
        await withTaskCancellationHandler {
            await controlTask.value
        } onCancel: {
            controlTask.cancel()
        }
    }

    /// Serial vs entry token check: the replaced handle's second control was made while its first write was in
    /// flight, so it is delivered after a start replaced the attach, while the joining handle's own change lists the
    /// tasks. The stale control must not take the newest serial, or the joining handle's change is dropped.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: PROBE a replaced handle's buffered control never cancels the joining handle's newer change", .timeLimit(.minutes(1)))
    func staleBufferedControl() async throws {
        let rig = try Rig("retry-probe-stale-control")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = try #require(await coordinator.start(rig.job(1)) as? BackgroundTransferHandle)
        await rig.driver.holdNextPriority()
        first.setPriority(.userInitiated)
        await rig.awaitSignal("priority held")
        // Buffered behind the held write in the first handle's control stream.
        first.setPriority(.prefetch)
        let second = try #require(await coordinator.start(rig.job(2)) as? BackgroundTransferHandle)
        #expect(second.name == first.name)
        #expect(await run(first).terminal == .failed(.cancelled(.byClient)))
        await rig.driver.holdNextSnapshot(.afterListing)
        second.setPriority(.bulk)
        await rig.awaitSignal("snapshot")
        // The first handle's write lands; its buffered prefetch reaches the coordinator with a stale token.
        await rig.driver.releasePriority()
        await Self.drained(first)
        await rig.driver.releaseSnapshot()
        // A cancel queued behind the change: once the second control task ended, the change has returned.
        second.cancel()
        #expect(await run(second).terminal == .failed(.cancelled(.byClient)))
        await Self.drained(second)
        #expect(!Task.isCancelled)
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(changes == [0.75, 0.25], "the joining handle's bulk (0.25) must reach the OS task: \(changes)")
    }

    /// Loop vs single re-check: the first rewrite itself lands after a third, newer write; the OS task must still end
    /// at the newest value.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: PROBE a rewrite that lands after a newer write is followed by the newest value", .timeLimit(.minutes(1)))
    func rewriteLandsLast() async throws {
        let rig = try Rig("retry-probe-rewrite-lands-last")
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
        // The first write lands late; its rewrite of 0.25 is held in turn.
        await rig.driver.holdNextPriority()
        await rig.driver.releasePriority()
        await rig.awaitSignal("priority")
        await rig.awaitSignal("priority held")
        second.setPriority(.prefetch)
        await rig.awaitSignal("priority")
        await rig.driver.releasePriority()
        await Self.drained(first)
        #expect(!Task.isCancelled)
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(Array(changes.prefix(4)) == [0.25, 0.75, 0.5, 0.25], "staged in landing order: \(changes)")
        #expect(changes.last == 0.5, "newest request was prefetch (0.5); the OS task ends at \(String(describing: changes.last)): \(changes)")
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.5])
        withExtendedLifetime(second) {}
    }
}
