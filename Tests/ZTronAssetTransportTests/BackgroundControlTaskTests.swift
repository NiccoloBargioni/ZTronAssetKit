import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
@testable import ZTronAssetTransport

/// R-SYN-14 for the background handle's one control task (S3-CONC-01): it delivers the handle's controls in order and
/// must end with the attach, however the attach ends, so no task outlives a background transfer (sync-2 S2-19).
@Suite("Background handle control task")
struct BackgroundControlTaskTests {
    @available(macOS 15.0, iOS 18.0, *)
    typealias Rig = BackgroundCoordinatorTests.Rig

    /// How the handle's attach ends.
    enum Ending: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case terminal, replaced, consumerGone, invalidated, handleDropped

        var testDescription: String {
            self.rawValue
        }
    }

    /// The control task ends once the attach ended (awaiting it returns, else the hang guard fails the test), and a
    /// control made afterwards reaches nothing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-14: a background handle's control task ends with its attach, however the attach ends", .timeLimit(.minutes(1)), arguments: Ending.allCases)
    func controlTaskEndsWithTheAttach(_ ending: Ending) async throws {
        let rig = try Rig("control-task-\(ending.rawValue)")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job(1)
        var handle: BackgroundTransferHandle? = try #require(await coordinator.start(job) as? BackgroundTransferHandle)
        let controlTask = try #require(handle?.controlTask)
        var kept: [any TransferHandle] = []
        switch ending {
        case .terminal:
            await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
            #expect(await run(try #require(handle)).terminal == BackgroundInterleavingTests.staged(job))
        case .replaced:
            // A later start for the same content joins the OS task and replaces this attach.
            kept.append(await coordinator.start(rig.job(2)))
            #expect(await run(try #require(handle)).terminal == .failed(.cancelled(.byClient)))
        case .consumerGone:
            let updates = try #require(handle).updates
            let reader = Task {
                for await _ in updates {}
            }
            reader.cancel()
            await reader.value
            await rig.awaitSignal("cancelled")
        case .invalidated:
            await coordinator.invalidate()
            #expect(await run(try #require(handle)).terminal == .failed(.cancelled(.byClient)))
        case .handleDropped:
            handle = nil
            await rig.awaitSignal("cancelled")
        }
        // `Task.value` ignores cancellation: past the hang guard the control task is cancelled, which ends its
        // iteration, so a timed-out case ends at once instead of holding the run (S3-R4).
        await withTaskCancellationHandler {
            await controlTask.value
        } onCancel: {
            controlTask.cancel()
        }
        #expect(!Task.isCancelled, "the control task outlived its attach")
        // The attach ended: a control made now is delivered nowhere.
        handle?.setPriority(.userInitiated)
        handle?.pause()
        #expect(await rig.driver.priorityChanges.isEmpty)
        let cancellations = await rig.driver.cancellations.map(\.producingResumeData)
        #expect(cancellations == ([.consumerGone, .handleDropped].contains(ending) ? [false] : []), "cancellations: \(cancellations)")
        withExtendedLifetime(kept) {}
    }

    /// The handle goes away while its update stream is still read, so the attach goes on (close-out cycle 3): the
    /// handle's `deinit` finishes the control stream, so the control task ends at once, before the transfer's
    /// terminal, and the reader still gets that terminal. In `controlTaskEndsWithTheAttach`'s `handleDropped` case
    /// the update stream goes too, so the attach ends with it and that case alone cannot show the `deinit` matters.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-14: a dropped background handle's control task ends at once while its transfer goes on", .timeLimit(.minutes(1)))
    func droppedHandleEndsItsControlTask() async throws {
        let rig = try Rig("control-task-dropped-while-read")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job(1)
        var handle: BackgroundTransferHandle? = try #require(await coordinator.start(job) as? BackgroundTransferHandle)
        let controlTask = try #require(handle?.controlTask)
        let updates = try #require(handle).updates
        let reader = Task { await ForegroundBackendTests.outcomes(of: updates) }
        handle = nil
        await withTaskCancellationHandler {
            await controlTask.value
        } onCancel: {
            controlTask.cancel()
        }
        #expect(!Task.isCancelled, "the control task outlived its handle")
        // The attach still holds the name: the control task ended with the handle, not with the attach.
        #expect(await coordinator.liveTransfers().map(\.name) == [job.partialName])
        #expect(await rig.driver.cancellations.isEmpty)
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        #expect(await reader.value == [BackgroundInterleavingTests.staged(job)])
    }
}
