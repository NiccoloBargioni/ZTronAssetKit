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
            let staged = try await Self.stagedCopy(of: request, in: fixture)
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
        let staged = try await Self.stagedCopy(of: request, in: fixture)
        let driver = Self.driver(for: request, in: fixture)
        let terminal = await driver.conclude(staged)
        #expect(terminal == staged)
        driver.stop.request(.cancel)
        driver.stop.request(.pause)
        #expect(driver.stop.requested == nil)
        #expect(fixture.staging.contents[request.partialName] == asset.bytes)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test(
        "R-CLN-10: a copy staged from a pack downloaded on demand that reaches no consumer leaves the pack released for the generation",
        .timeLimit(.minutes(1))
    )
    func undeliveredCopyLeavesThePackReleased() async throws {
        // Verifier probe PROBE-C1-6: the consumer drops the stream after the driver claimed the terminal element and
        // before it yields it. Here the stream has no consumer at all and no stop is wired to it, which is the state
        // after the claim. The driver used to re-arm the release before the yield, so the pack was removed and
        // downloaded again although no consumer received the copy.
        let fixture = AppleTierFixture(
            installed: [Packs.media: [asset.path: asset.bytes]],
            remote: [Packs.media: [asset.path: asset.bytes]]
        )
        let report = AdoptionReport(manifestRemotePaths: [asset.remotePath], adoptedRemotePaths: [asset.remotePath])
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"])

        let request = asset.request(sequence: 2)
        await Self.driver(for: request, in: fixture).run()
        #expect(fixture.backend.calls.filter { $0 == .ensure(Packs.media) }.count == 1, "the pack was downloaded on demand")
        #expect(fixture.staging.contents[request.partialName] == nil, "the copy nobody received is discarded")
        #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "released once in this generation")
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 1)
        #expect(fixture.backend.installedPacks.contains(Packs.media), "the pack stays until the next generation")
        await fixture.source.invalidate()
    }

    /// A driver over the fixture's source with its own stop, as `PackTransferHandle.start` builds one, yielding into
    /// `updates`; without one, into a stream nobody holds (a consumer that dropped it after the terminal was claimed,
    /// since no stop is wired to it).
    @available(macOS 26.0, *)
    static func driver(
        for request: TransferRequest,
        in fixture: AppleTierFixture,
        updates: AsyncStream<TransferUpdate>.Continuation? = nil
    ) -> PackTransferDriver {
        let parts = PackTransferDriver.Parts(
            copier: fixture.source.copier,
            packs: fixture.source.packs,
            state: fixture.source.state,
            log: fixture.source.log
        )
        let continuation = updates ?? AsyncStream.makeStream(of: TransferUpdate.self).continuation
        return PackTransferDriver(request: request, parts: parts, updates: continuation, stop: PackTransferStop())
    }

    /// Copies the asset into `request`'s staging file as an attempt would, and returns the staged element the
    /// attempt proposes.
    @available(macOS 26.0, *)
    static func stagedCopy(of request: TransferRequest, in fixture: AppleTierFixture) async throws -> TransferUpdate {
        let location = try #require(PackLocation(remotePath: request.remotePath))
        let copied = await fixture.source.copier.copy(location, as: request.partialName, maxBytes: request.maxBytes)
        let size = Int64(asset.bytes.count)
        try #require(copied == .copied(bytes: size, digest: ContentHash.sha256(of: asset.bytes)))
        let file = StagedFile(name: request.partialName, byteCount: size, resumed: false, httpStatus: nil, etag: nil)
        return .staged(file)
    }
}
