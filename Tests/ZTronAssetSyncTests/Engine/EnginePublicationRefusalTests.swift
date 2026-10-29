import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The engine's handling of a publication the store refuses (ARCHITECTURE §7.6's store rows) and of a cancel the engine
/// did not ask for (T7/T13): paths no earlier test ran (Stage 3, S3-CONF-08).
extension EngineFailurePathTests {
    /// Stages `entry`'s transfer and holds it at its first step; returns a waiter for `entry` once its transfer runs.
    @available(macOS 15.0, iOS 18.0, *)
    static func heldWaiter(_ harness: EngineHarness, _ entry: ManifestEntry, staging bytes: Data) async -> Task<Result<AssetLocation, AssetError>, Never> {
        let engine = harness.engine
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        let waiter = Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[entry.transferID]?.state == .downloading }
        await engine.waitForHandle(entry.transferID)
        return waiter
    }

    /// R-INT-5 under `allowUnverifiedAssets = false`: a user resolve of a checksum-less entry downloads it, and the store
    /// refuses the publication (`unverifiedRejected`, before any hashing). The waiter gets `integrityFailure`, the job
    /// fails until the entry changes and is removed, and the asset is not downloaded again.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-5: with unverified assets disallowed a resolve of a checksum-less entry fails integrityFailure at publication and is not retried", .timeLimit(.minutes(1)))
    func unverifiedPublicationRefused() async throws {
        let harness = EngineHarness.make(storage: StoragePolicy(allowUnverifiedAssets: false))
        let bytes = EngineFixture.bytes(9_701)
        let entry = EngineFixture.entry("unverified", bytes, policy: .onDemand, checksum: false)
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let answer = await engine.awaitAsset(entry.identifier, lane: .userInitiated)
        #expect(answer == .failure(.integrityFailure), "\(answer)")
        await engine.awaitCondition { $0.state.jobs[entry.transferID] == nil }
        #expect(await harness.source.starts.count == 1, "no second download of the refused asset")
        #expect(await engine.readForTests { $0.state.metrics.illegalTransitions } == 0)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// A publication for an id the store no longer knows (its manifest dropped the id behind the engine's copy, which a
    /// catch-up follows later): `unknownAsset` fails the job until the entry changes and answers the waiter `notFound`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: a publication the store refuses as an unknown asset answers the waiter notFound and does not retry the transfer", .timeLimit(.minutes(1)))
    func unknownAssetPublicationRefused() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(9_711)
        let entry = EngineHarness.onDemand("dropped-behind", bytes)
        let other = EngineHarness.onDemand("kept-behind", EngineFixture.bytes(9_712))
        try await EngineSingleFlightTests.applied([entry, other], harness: harness)
        let engine = harness.engine
        let waiter = await Self.heldWaiter(harness, entry, staging: bytes)
        // The store applies a manifest without the id while its transfer runs; the engine is not told.
        let dropped = try ValidatedManifest(entries: [other], digest: ContentHash.sha256(of: Data("dropped-behind".utf8)))
        _ = try await harness.store.apply(dropped, etag: nil, eviction: nil)
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        let answer = await EngineHarness.value(of: waiter)
        #expect(answer == .failure(.notFound), "\(answer)")
        #expect(await harness.source.starts.count == 1, "the refused transfer is not retried")
        #expect(await engine.readForTests { $0.state.metrics.illegalTransitions } == 0)
        await engine.shutdown()
    }

    /// A publication whose every id the store has recorded as failed meanwhile (here the origin's 404 for that content,
    /// recorded behind the engine) is refused (`assetFailed`): the job fails until the entry changes and the waiter gets
    /// the record's answer, `notFound`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: a publication the store refuses because the asset's record failed meanwhile answers the waiter from that record", .timeLimit(.minutes(1)))
    func failedRecordPublicationRefused() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(9_721)
        let entry = EngineHarness.onDemand("failed-behind", bytes)
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        let waiter = await Self.heldWaiter(harness, entry, staging: bytes)
        try await harness.store.recordFailure([entry.identifier], identity: entry.contentIdentity, reason: .notFound)
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        let answer = await EngineHarness.value(of: waiter)
        #expect(answer == .failure(.notFound), "\(answer)")
        let job = await engine.readForTests { $0.state.jobs[entry.transferID]?.state }
        #expect(job == nil || job == .failed(.untilEntryChanges), "the job fails until the entry changes: \(String(describing: job))")
        #expect(await harness.source.starts.count == 1, "the refused transfer is not retried")
        await engine.shutdown()
    }

    /// A transfer the transport reports cancelled by the client although the engine cancelled nothing (an app extension,
    /// a cancelled task the engine did not own) is no failure (T7/T13): the job is re-queued at once, with no backoff and
    /// no failure counted, and its next attempt delivers the asset.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: a transfer cancelled by the client without the engine asking is re-queued at once and its next attempt delivers", .timeLimit(.minutes(1)))
    func uncommandedClientCancelRequeues() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(9_731)
        let entry = EngineHarness.onDemand("cancelled-elsewhere", bytes)
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        await harness.source.script(entry.transferID, [.fail(.cancelled(.byClient)), .stage(bytes)])
        let answer = await engine.awaitAsset(entry.identifier, lane: .userInitiated)
        #expect((try? answer.get()) != nil, "the next attempt delivered: \(answer)")
        #expect(await harness.source.starts.count == 2, "re-queued once, at once")
        let after = await engine.readForTests { engine in
            (failures: engine.state.metrics.failures, errors: engine.state.recentErrors.count, illegal: engine.state.metrics.illegalTransitions)
        }
        #expect(after.failures == FailureCounts(), "no failure was counted: \(after.failures)")
        #expect(after.errors == 0, "no failure was recorded: \(after.errors)")
        #expect(after.illegal == 0)
        await engine.shutdown()
    }
}
