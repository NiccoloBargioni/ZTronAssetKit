import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

// Verifier probes, WP-K close-out cycle 4, correctness lens (third file). Scratch copy only; never committed.

@Suite("Verifier K-C4 engine probes 3", .serialized)
struct VerifierKC4EngineProbe3 {
    typealias T = EngineLegacyMigrationTransferTests

    /// P1-LATEJOIN (L5K-R1's invariant): one content under two ids, both with prior-art files that verify. A prefetch job
    /// for the first id runs its pre-transfer read (`answeredFromStore`), which adopts that id's file; its hash is held.
    /// Meanwhile a second asker (a prefetch group, or ensureAvailable) wants the second id of the same content: it joins the
    /// job, adding the id to `job.assets`. The read loop iterates over the job as captured before the reads, so the second
    /// id is never asked: is the content downloaded for it, although its prior-art file can be adopted?
    @available(macOS 15.0, iOS 18.0, *)
    @Test("P1-LATEJOIN: a second id of the same content joins during the pre-transfer read", .timeLimit(.minutes(1)), arguments: [false, true])
    func p1LateJoin(viaEnsure: Bool) async throws {
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(9_970)
        let other = T.catalog(1, seed: 9_975)[0]
        let first = EngineFixture.entry("legacy1", bytes)
        let second = EngineFixture.entry("legacy2", bytes)
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk([other, (first, bytes), (second, bytes)], time: time),
            time: time,
            bulk: bulk,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.scriptTransfers([other, (first, bytes)])
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        try #require(first.transferID == second.transferID, "premise: one content, one job")
        let view = try await harness.view()
        let bothPending = view.records[first.identifier]?.referencedBlob == nil && view.records[second.identifier]?.referencedBlob == nil
        let token = try await engine.registerGroup([first.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let firstHash = Set(await bulk.heldUnits).subtracting(migration)
        // The second asker joins the job while the first id's adoption hashes.
        var token2: InterestToken?
        var ensure: Task<Result<AvailabilityReport, AssetError>, Never>?
        if viaEnsure {
            ensure = Task { await engine.ensureAvailable(scope: .identifiers([second.identifier])) }
        } else {
            token2 = try await engine.registerGroup([second.identifier], lane: .prefetch).get()
        }
        try await T.release(bulk, keeping: migration.union(firstHash), on: engine) { engine in
            engine.state.jobs[first.transferID]?.assets.contains(second.identifier) == true || engine.state.jobs[first.transferID] == nil
        }
        let joined = await engine.readForTests { $0.state.jobs[first.transferID]?.assets.contains(second.identifier) == true }
        for unit in firstHash {
            await bulk.release(unit)
        }
        // Let everything but the migration run until the job has ended.
        try await T.release(bulk, keeping: migration, on: engine) { engine in
            engine.state.jobs[first.transferID] == nil
        }
        if let ensure {
            let (result, task) = try await T.duringMigration(keeping: migration, bulk: bulk) {
                await ensure.value
            }
            _ = result
            await task.value
        }
        let starts = await harness.source.starts.map(\.remotePath)
        print("KC4-PROBE P1-LATEJOIN viaEnsure=\(viaEnsure) bothPending=\(bothPending) joinedDuringRead=\(joined) starts=\(starts)")
        #expect(bothPending && joined, "premises")
        #expect(starts.isEmpty, "P1-LATEJOIN: the content was downloaded for the second id, whose prior-art file migration could still adopt (L5K-R1)")
        await engine.releaseGroup(token)
        if let token2 {
            await engine.releaseGroup(token2)
        }
        await T.finishMigration(harness, bulk: bulk)
        await engine.shutdown()
    }
}
