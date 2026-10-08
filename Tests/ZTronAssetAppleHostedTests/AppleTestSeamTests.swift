import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

/// The tier's test seams wait without sleeping and end on cancellation, so a test's time limit turns a defect that
/// would make a wait endless into a failure instead of a hung run (ADR draft E-13).
@Suite("Apple tier: test seams")
struct AppleTestSeamTests {
    @available(macOS 26.0, *)
    @Test("Seams: waits return at once when their condition already holds", .timeLimit(.minutes(1)))
    func immediateReturns() async throws {
        let fixture = AppleTierFixture()
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 0)
        await fixture.source.state.waitForDrain()
        await fixture.source.state.settleUpdateCheck()
        await fixture.source.invalidate()
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        #expect(await fixture.source.packs.waiterCount(on: Packs.media) == 0)
    }

    @available(macOS 26.0, *)
    @Test("Seams: a cancelled wait for pack waiters returns", .timeLimit(.minutes(1)))
    func cancelledWaiterWaitReturns() async throws {
        let fixture = AppleTierFixture()
        let wait = Task {
            await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        }
        wait.cancel()
        await wait.value
        #expect(await fixture.source.packs.waiterCount(on: Packs.media) == 0)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("Seams: a cancelled wait for a drain returns while staging is still busy", .timeLimit(.minutes(1)))
    func cancelledDrainWaitReturns() async throws {
        let fixture = AppleTierFixture()
        #expect(await fixture.source.state.beginStaging())
        let wait = Task {
            await fixture.source.state.waitForDrain()
        }
        wait.cancel()
        await wait.value
        await fixture.source.state.endStaging()
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
