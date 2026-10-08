import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

private let seamAsset = PackAsset("ZTronMedia/seams/a.png", "pixels for the seam tests")

/// The tier's test seams wait without sleeping and end on cancellation, so a test's time limit turns a defect that
/// would make a wait endless into a failure instead of a hung run (ADR draft E-13).
@Suite("Apple tier: test seams")
struct AppleTestSeamTests {
    @available(macOS 26.0, *)
    @Test("Seams: a cancelled wait for pack waiters returns while the count is still unmet", .timeLimit(.minutes(1)))
    func cancelledWaiterWaitReturns() async throws {
        let fixture = AppleTierFixture(remote: [Packs.media: [seamAsset.path: seamAsset.bytes]])
        fixture.backend.scriptEnsure(Packs.media, [.hold])
        let handle = await fixture.source.transfer(seamAsset.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        let (registered, signal) = AsyncStream.makeStream(of: Void.self)
        let wait = Task {
            await fixture.source.packs.waitForWaiters(on: Packs.media, count: 2, registered: { _ = signal.yield() })
            return await fixture.source.packs.waiterCount(on: Packs.media)
        }
        for await _ in registered {
            break
        }
        wait.cancel()
        #expect(await wait.value == 1, "the wait ended by cancellation, not because a second caller joined")
        handle.cancel()
        #expect(await collect(handle) == [.failed(.cancelled(.byClient))])
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("Seams: a wait for pack waiters ends when the coordinator closes with the count unmet", .timeLimit(.minutes(1)))
    func waiterWaitEndsOnClose() async throws {
        let fixture = AppleTierFixture(remote: [Packs.media: [seamAsset.path: seamAsset.bytes]])
        fixture.backend.scriptEnsure(Packs.media, [.hold])
        let handle = await fixture.source.transfer(seamAsset.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        let (registered, signal) = AsyncStream.makeStream(of: Void.self)
        let wait = Task {
            await fixture.source.packs.waitForWaiters(on: Packs.media, count: 2, registered: { _ = signal.yield() })
            return await fixture.source.packs.waiterCount(on: Packs.media)
        }
        for await _ in registered {
            break
        }
        await fixture.source.invalidate()
        #expect(await wait.value == 0, "closing ended every pack wait, and the seam's wait with them")
        #expect(await collect(handle) == [.failed(.cancelled(.byClient))])
    }

    @available(macOS 26.0, *)
    @Test("Seams: a cancelled wait for a drain returns while a staging write is still open", .timeLimit(.minutes(1)))
    func cancelledDrainWaitReturns() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.media: [seamAsset.path: seamAsset.bytes]], staging: gated)
        gated.arm(.afterWrite)
        let handle = await fixture.source.transfer(seamAsset.request())
        await gated.waitForHeldWrites(1)
        let (registered, signal) = AsyncStream.makeStream(of: Void.self)
        let wait = Task {
            await fixture.source.state.waitForDrain(registered: { _ = signal.yield() })
            gated.note("wait returned")
        }
        for await _ in registered {
            break
        }
        wait.cancel()
        await wait.value
        #expect(gated.events == ["wait returned"], "the write was still held when the wait returned")
        gated.open()
        #expect(await collect(handle).last.map(AppleTransferTests.isStaged) == true)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("Seams: cancelling a settle cancels the update check, which is recorded as failed", .timeLimit(.minutes(1)))
    func cancelledSettleCancelsTheCheck() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        fixture.backend.scriptCheck([.hold])
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest())
        await fixture.backend.waitFor(.checkForUpdates)
        let settle = Task {
            await fixture.source.state.settleUpdateCheck()
        }
        settle.cancel()
        await settle.value
        await fixture.source.state.settleUpdateCheck()
        let report = await fixture.source.state.checkReport()
        #expect(report.completedChecks == 1)
        #expect(!report.updateChecked)
        await fixture.source.invalidate()
    }
}
