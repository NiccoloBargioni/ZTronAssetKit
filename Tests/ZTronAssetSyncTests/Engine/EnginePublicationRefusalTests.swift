import Foundation
import Synchronization
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

    /// A publication whose every id the store has recorded as failed meanwhile (the origin's 404 for that content, or
    /// a copy repeatedly unreadable, recorded behind the engine) is refused (`assetFailed`): the job fails until the
    /// entry changes and the waiter gets the record's answer, `notFound` for the 404 and `integrityFailure` for the
    /// unreadable copy (the second reason tells the refusal's own mapping apart from an unknown asset's `notFound`: the
    /// close-out cycle-2 requirements lens).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: a publication the store refuses because the asset's record failed meanwhile answers the waiter from that record", .timeLimit(.minutes(1)), arguments: [FailureReason.notFound, .unreadable])
    func failedRecordPublicationRefused(_ reason: FailureReason) async throws {
        let expected: AssetError
        switch reason {
        case .notFound:
            expected = .notFound
        case .integrity, .unreadable:
            expected = .integrityFailure
        }
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(9_721)
        let entry = EngineHarness.onDemand("failed-behind", bytes)
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        let waiter = await Self.heldWaiter(harness, entry, staging: bytes)
        try await harness.store.recordFailure([entry.identifier], identity: entry.contentIdentity, reason: reason)
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        let answer = await EngineHarness.value(of: waiter)
        #expect(answer == .failure(expected), "\(answer)")
        let job = await engine.readForTests { $0.state.jobs[entry.transferID]?.state }
        #expect(job == nil || job == .failed(.untilEntryChanges), "the job fails until the entry changes: \(String(describing: job))")
        #expect(await harness.source.starts.count == 1, "the refused transfer is not retried")
        await engine.shutdown()
    }

    /// A transfer the transport reports cancelled by the client although the engine cancelled nothing (an app extension,
    /// a cancelled task the engine did not own) is no failure (T7/T13): the job is re-queued at once, with no backoff and
    /// no failure counted, and its next attempt delivers the asset. A condition observer, called at every notification,
    /// records the job's states, counted attempts and retry deadline: it never waits `failed(.at)` for a backoff, never
    /// counts the attempt and never has a retry scheduled (a cancel treated as the system's, retried with backoff,
    /// passed every other check: the close-out cycle-2 requirements lens).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: a transfer cancelled by the client without the engine asking is re-queued at once and its next attempt delivers", .timeLimit(.minutes(1)))
    func uncommandedClientCancelRequeues() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(9_731)
        let entry = EngineHarness.onDemand("cancelled-elsewhere", bytes)
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        let transfer = entry.transferID
        let seen = Mutex<(states: [JobState], attempts: Int, retries: Int)>(([], 0, 0))
        let (registered, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            await engine.awaitCondition { engine in
                signal.yield()
                if let job = engine.state.jobs[transfer] {
                    let retry = engine.state.heap.deadline(for: .retry(transfer, epoch: job.epoch)) != nil
                    seen.withLock { record in
                        if record.states.last != job.state {
                            record.states.append(job.state)
                        }
                        record.attempts = max(record.attempts, job.attempts)
                        record.retries += retry ? 1 : 0
                    }
                }
                return false
            }
        }
        var registration = registered.makeAsyncIterator()
        _ = await registration.next()
        await harness.source.script(transfer, [.fail(.cancelled(.byClient)), .stage(bytes)])
        let answer = await engine.awaitAsset(entry.identifier, lane: .userInitiated)
        #expect((try? answer.get()) != nil, "the next attempt delivered: \(answer)")
        #expect(await harness.source.starts.count == 2, "re-queued once, at once")
        let after = await engine.readForTests { engine in
            (
                failures: engine.state.metrics.failures,
                retries: engine.state.metrics.retries,
                errors: engine.state.recentErrors.count,
                illegal: engine.state.metrics.illegalTransitions
            )
        }
        #expect(after.failures == FailureCounts(), "no failure was counted: \(after.failures)")
        #expect(after.retries == FailureCounts(), "no retry was counted: \(after.retries)")
        #expect(after.errors == 0, "no failure was recorded: \(after.errors)")
        #expect(after.illegal == 0)
        await engine.shutdown()
        await EngineHarness.value(of: observer)
        signal.finish()
        let record = seen.withLock { $0 }
        #expect(record.states.contains(.downloading), "the observer saw the attempts: \(record.states)")
        #expect(!record.states.contains { $0.kind == .failed }, "the job never failed or waited for a backoff: \(record.states)")
        #expect(record.attempts == 0, "no attempt was counted against the retry cap: \(record.attempts)")
        #expect(record.retries == 0, "no retry deadline was scheduled")
    }
}
