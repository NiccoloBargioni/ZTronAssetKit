import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

private let asset = PackAsset("ZTronMedia/images/a.heic", "pixels of a")

/// R-APL-1 (ADR-021): a control either lands before the driver claims the terminal element, and becomes it, or after,
/// and is a no-op. Driven through `PackTransferStop` and the driver's `conclude` seam, so the window between a finished
/// copy and the terminal element is reached deterministically.
@Suite("Apple tier: terminal claim")
struct PackTransferStopTests {
    @available(macOS 26.0, *)
    @Test("R-APL-1: the first stop requested before the claim is the terminal; a stop after the claim is ignored")
    func claimDecidesOnce() {
        let stopped = PackTransferStop()
        stopped.request(.pause)
        stopped.request(.cancel)
        #expect(stopped.claimTerminal() == .pause, "the first request wins")
        #expect(stopped.requested == .pause)

        let finished = PackTransferStop()
        #expect(finished.claimTerminal() == nil)
        finished.request(.cancel)
        finished.request(.pause)
        #expect(finished.requested == nil, "a control after the claimed terminal is a no-op")
        #expect(finished.claimTerminal() == nil)
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a racing stop is recorded exactly when the claim reports it", .timeLimit(.minutes(1)))
    func claimAndRequestAreOneDecision() async {
        for round in 0..<500 {
            let stop = PackTransferStop()
            let claimed = await withTaskGroup(of: PackTransferStop.Kind?.self) { group in
                group.addTask {
                    stop.request(round.isMultiple(of: 2) ? .cancel : .pause)
                    return nil
                }
                group.addTask {
                    stop.claimTerminal()
                }
                var claimed: PackTransferStop.Kind?
                for await kind in group where kind != nil {
                    claimed = kind
                }
                return claimed
            }
            // Either the stop landed first and the claim returned it, or it landed after the claim and was dropped.
            #expect(stop.requested == claimed, "round \(round)")
        }
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a cancel or pause landing after the copy staged and before the claim ends the transfer stopped and discards the copy", .timeLimit(.minutes(1)))
    func stopBeforeClaimReplacesAStagedCopy() async throws {
        for control in [TransferControl.cancel, .pause] {
            let fixture = AppleTierFixture(installed: [Packs.media: [asset.path: asset.bytes]])
            let request = asset.request()
            let staged = try await Self.stagedAttempt(of: request, in: fixture, downloaded: nil)
            let driver = Self.driver(for: request, in: fixture)
            driver.stop.request(control == .pause ? .pause : .cancel)
            let terminal = await driver.conclude(staged)
            #expect(terminal == (control == .pause ? .paused(resumable: false) : .failed(.cancelled(.byClient))), "\(control)")
            #expect(fixture.staging.contents[request.partialName] == nil, "\(control): the staged copy is discarded")
            await fixture.source.invalidate()
        }
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a control after the claim leaves the staged copy delivered and intact", .timeLimit(.minutes(1)))
    func controlAfterClaimIsANoOp() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: [asset.path: asset.bytes]])
        let request = asset.request()
        let staged = try await Self.stagedAttempt(of: request, in: fixture, downloaded: nil)
        let driver = Self.driver(for: request, in: fixture)
        let terminal = await driver.conclude(staged)
        #expect(terminal == staged.terminal)
        driver.stop.request(.cancel)
        driver.stop.request(.pause)
        #expect(driver.stop.requested == nil)
        #expect(fixture.staging.contents[request.partialName] == asset.bytes)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: only a delivered staged copy re-arms the release of a pack downloaded on demand", .timeLimit(.minutes(1)))
    func onlyADeliveredCopyRearmsTheRelease() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: [asset.path: asset.bytes]])
        let report = AdoptionReport(manifestRemotePaths: [asset.remotePath], adoptedRemotePaths: [asset.remotePath])
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"])

        // The pack came back for this transfer, but the transfer was cancelled before its terminal was claimed.
        fixture.backend.install(Packs.media, files: [asset.path: asset.bytes])
        let cancelledRequest = asset.request(sequence: 2)
        let cancelled = Self.driver(for: cancelledRequest, in: fixture)
        cancelled.stop.request(.cancel)
        let cancelledAttempt = try await Self.stagedAttempt(of: cancelledRequest, in: fixture, downloaded: Packs.media)
        #expect(await cancelled.conclude(cancelledAttempt) == .failed(.cancelled(.byClient)))
        #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "a stopped transfer re-arms nothing")

        // The same download delivered as a staged copy: the pack is released once more after adoption.
        let deliveredRequest = asset.request(sequence: 3)
        let deliveredAttempt = try await Self.stagedAttempt(of: deliveredRequest, in: fixture, downloaded: Packs.media)
        #expect(await Self.driver(for: deliveredRequest, in: fixture).conclude(deliveredAttempt) == deliveredAttempt.terminal)
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"])
        await fixture.source.invalidate()
    }

    /// A driver over the fixture's source with its own stop, as `PackTransferHandle.start` builds one.
    @available(macOS 26.0, *)
    static func driver(for request: TransferRequest, in fixture: AppleTierFixture) -> PackTransferDriver {
        let parts = PackTransferDriver.Parts(
            copier: fixture.source.copier,
            packs: fixture.source.packs,
            state: fixture.source.state,
            log: fixture.source.log
        )
        let (_, updates) = AsyncStream.makeStream(of: TransferUpdate.self)
        return PackTransferDriver(request: request, parts: parts, updates: updates, stop: PackTransferStop())
    }

    /// Copies the asset into `request`'s staging file as an attempt would, and returns that attempt's staged result.
    @available(macOS 26.0, *)
    static func stagedAttempt(
        of request: TransferRequest,
        in fixture: AppleTierFixture,
        downloaded: PackID?
    ) async throws -> PackTransferDriver.AttemptResult {
        let location = try #require(PackLocation(remotePath: request.remotePath))
        let copied = await fixture.source.copier.copy(location, as: request.partialName, maxBytes: request.maxBytes)
        let size = Int64(asset.bytes.count)
        try #require(copied == .copied(bytes: size, digest: ContentHash.sha256(of: asset.bytes)))
        let file = StagedFile(name: request.partialName, byteCount: size, resumed: false, httpStatus: nil, etag: nil)
        return PackTransferDriver.AttemptResult(terminal: .staged(file), downloaded: downloaded)
    }
}
