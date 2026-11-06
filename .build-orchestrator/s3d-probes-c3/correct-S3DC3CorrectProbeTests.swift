import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
@testable import ZTronAssetTransport

/// s3d close-out cycle 3, correctness verifier: probes (scratch only, never committed).
@Suite("S3DC3 correctness probes")
struct S3DC3CorrectProbeTests {
    /// S3D-4, the OLD order: the interval edges read as soon as the readers returned, before `stop()`. Under the
    /// timing amplifier (`AMP-delay-interval-end`) this must fail, proving the amplifier exercises the race the
    /// committed test's new order closes; the edges read after `stop()` must still be complete.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE S3D-4: edges read before stop (old order) vs after stop (new order)", .timeLimit(.minutes(1)))
    func edgesOldVersusNewOrder() async throws {
        let arrivals = Arrivals()
        let rig = try await LoopbackRig.make(requestTimeout: LoopbackRig.heldStallTimeout) { request in
            arrivals.signal(request.target)
            switch request.target {
            case "/staged.bin":
                return LoopbackResponse(body: TransportFixtures.payload(1_000))
            case "/missing.bin":
                return LoopbackResponse(status: 404)
            default:
                return LoopbackResponse(body: TransportFixtures.payload(100_000), ending: .stallAfter(bodyBytes: 10))
            }
        }
        let paths = ["staged.bin", "missing.bin", "paused.bin", "cancelled.bin"]
        var handles: [any TransferHandle] = []
        var readers: [Task<[TransferUpdate], Never>] = []
        for (index, path) in paths.enumerated() {
            let request = rig.request(TransportFixtures.contentID(UInt8(index + 1)), path: path, expected: index == 0 ? 1_000 : 100_000)
            let handle = await rig.source.transfer(request)
            #expect(await arrivals.next() == "/" + path)
            let updates = handle.updates
            readers.append(Task { await ForegroundBackendTests.outcomes(of: updates) })
            handles.append(handle)
        }
        handles[2].pause()
        handles[3].cancel()
        for reader in readers {
            #expect(await reader.value.count == 1)
        }
        let early = transferIntervalEdges(rig.tap)
        print("PROBE edgesOldVersusNewOrder early began=\(early.began) ended=\(early.ended)")
        handles.removeAll()
        await rig.stop()
        let late = transferIntervalEdges(rig.tap)
        print("PROBE edgesOldVersusNewOrder late began=\(late.began) ended=\(late.ended)")
        #expect(late.began == 4 && late.ended == 4, "new order: every interval ended once stop() returned")
        #expect(early.ended == 4, "old order: an interval was still ending when the readers returned")
    }

    /// Hunt: a replaced handle's buffered PAUSE, delivered while the joining handle's priority change lists the
    /// tasks, must neither stop the joined OS task nor cancel the joining change (token checked before any await).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE hunt: replaced handle's buffered pause never reaches the joined transfer", .timeLimit(.minutes(1)))
    func staleBufferedPause() async throws {
        let rig = try BackgroundCoordinatorTests.Rig("s3dc3-stale-buffered-pause")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = try #require(await coordinator.start(rig.job(1)) as? BackgroundTransferHandle)
        await rig.driver.holdNextPriority()
        first.setPriority(.userInitiated)
        await rig.awaitSignal("priority held")
        first.pause()
        first.cancel()
        let second = try #require(await coordinator.start(rig.job(2)) as? BackgroundTransferHandle)
        #expect(second.name == first.name)
        #expect(await run(first).terminal == .failed(.cancelled(.byClient)))
        await rig.driver.holdNextSnapshot(.afterListing)
        second.setPriority(.bulk)
        await rig.awaitSignal("snapshot")
        await rig.driver.releasePriority()
        let firstControls = first.controlTask
        await withTaskCancellationHandler { await firstControls.value } onCancel: { firstControls.cancel() }
        await rig.driver.releaseSnapshot()
        second.cancel()
        #expect(await run(second).terminal == .failed(.cancelled(.byClient)))
        let secondControls = second.controlTask
        await withTaskCancellationHandler { await secondControls.value } onCancel: { secondControls.cancel() }
        let changes = await rig.driver.priorityChanges.map(\.priority)
        let cancellations = await rig.driver.cancellations.map(\.producingResumeData)
        print("PROBE staleBufferedPause changes=\(changes) cancellations=\(cancellations)")
        #expect(changes == [0.75, 0.25])
        // Only the joining handle's own cancel reached the OS task.
        #expect(cancellations == [false])
    }

    /// Hunt: many lane changes while a listing is held: the control stream drains them one by one, the OS task ends
    /// at the last value, and every change is delivered (no drop) before the control task ends.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE hunt: a burst of lane changes ends at the last one", .timeLimit(.minutes(1)))
    func burstEndsAtLast() async throws {
        let rig = try BackgroundCoordinatorTests.Rig("s3dc3-burst")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = try #require(await coordinator.start(rig.job(1)) as? BackgroundTransferHandle)
        await rig.driver.holdNextSnapshot(.afterListing)
        handle.setPriority(.userInitiated)
        await rig.awaitSignal("snapshot")
        let lanes: [AssetPriority] = (0..<200).map { [.bulk, .prefetch, .userInitiated][$0 % 3] } + [.prefetch]
        for lane in lanes {
            handle.setPriority(lane)
        }
        await rig.driver.releaseSnapshot()
        handle.cancel()
        #expect(await run(handle).terminal == .failed(.cancelled(.byClient)))
        let controls = handle.controlTask
        await withTaskCancellationHandler { await controls.value } onCancel: { controls.cancel() }
        let changes = await rig.driver.priorityChanges.map(\.priority)
        print("PROBE burstEndsAtLast count=\(changes.count) last=\(String(describing: changes.last))")
        #expect(changes.count == lanes.count + 1)
        #expect(changes.last == AssetPriority.prefetch.urlSessionTaskPriority)
    }
}
