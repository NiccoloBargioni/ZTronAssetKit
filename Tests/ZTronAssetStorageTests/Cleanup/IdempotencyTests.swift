import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// R-CLN-12: every cleanup operation is idempotent and safe under cancellation at any suspension point
/// (store.md §6.9).
@Suite("Cleanup: idempotency and cancellation (R-CLN-12)")
struct IdempotencyTests {
    enum Operation: String, CaseIterable, Sendable {
        case stagingGC
        case orphanGC
        case eviction
        case purgeEvictable
        case purgeAll
        case quarantine
        /// Deep verification that quarantines a corrupt blob (review round 3, store.md §6.9).
        case deepVerification
        /// Legacy migration run to its end, then called again (review round 3, store.md §6.9).
        case legacyMigration
    }

    /// A store with something for every operation to do: an unclaimed old staging file, an old orphan blob, assets
    /// over a zero budget; for `.legacyMigration` the prior art's tree (`Tests/Fixtures/legacy-v0`) instead.
    @available(macOS 15.0, iOS 18.0, *)
    static func prepared(_ operation: Operation) async throws -> (CoreHarness, [CleanupFixture.Asset]) {
        if operation == .legacyMigration {
            let (harness, _) = try LegacyFixture.harness(files: try LegacyFixture.fixtureFiles())
            #expect(try await harness.store.open().legacyMigrationPending)
            return (harness, [])
        }
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(budget: .bytes(0)))
        let assets = [CleanupFixture.asset("a", seed: 600), CleanupFixture.asset("b", seed: 601)]
        try await harness.seed(assets)
        _ = try await harness.stage(CoreFixture.bytes(602, count: 90), for: CleanupFixture.asset("staged", seed: 602).entry, sequence: 7)
        _ = try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(603, count: 70))
        harness.time.advance(by: 2 * 3_600)
        return (harness, assets)
    }

    /// Runs `operation`; `first` says whether it has work to do (a purge with a selection waits for the grace in the
    /// caller's task, one without returns at once).
    @available(macOS 15.0, iOS 18.0, *)
    static func run(_ operation: Operation, _ harness: CoreHarness, _ assets: [CleanupFixture.Asset], first: Bool) async throws {
        let deadline = harness.time.monotonicNow().adding(seconds: 60)
        switch operation {
        case .stagingGC:
            _ = try await harness.store.collectStaging(keeping: [])
        case .orphanGC:
            _ = try await harness.store.collectGarbage(until: deadline)
        case .eviction:
            _ = try await harness.store.evictIfNeeded()
        case .purgeEvictable, .purgeAll:
            let request: PurgeRequest = operation == .purgeAll ? .all : .evictable
            guard first else {
                #expect(try await harness.store.purge(request) == PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 0))
                return
            }
            _ = try await PurgeTests.purge(harness, request)
        case .quarantine:
            try await harness.store.reportUnreadable(assets[0].id)
        case .deepVerification:
            if first {
                // Bit rot: the same size, other bytes.
                try harness.fileSystem.write(CoreFixture.bytes(604), to: harness.layout.blobURL(assets[1].key), mode: .truncate)
            }
            let report = try await harness.store.verifyIntegrity(byteBudget: .max, until: deadline)
            #expect(report.completedPass && report.corrupt == (first ? [assets[1].id] : []), "\(first ? "first" : "second") run")
        case .legacyMigration:
            let progress = first ? try await LegacyMigrationTests.migrateAll(harness) : try await harness.store.migrateLegacy(maxFiles: 100)
            #expect(progress.finished)
        }
    }

    @Test("R-CLN-12: every cleanup operation run twice is a no-op the second time", .timeLimit(.minutes(1)), arguments: Operation.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func secondRunIsNoOp(operation: Operation) async throws {
        let (harness, assets) = try await IdempotencyTests.prepared(operation)
        let initial = harness.fileSystem.survivingDisk()
        let before = await harness.state
        try await IdempotencyTests.run(operation, harness, assets, first: true)
        let afterFirst = await harness.state
        let disk = harness.fileSystem.survivingDisk()
        // Orphan GC dooms (CCR-1): its first run changes the blob table, and the reaper changes the disk later.
        #expect(disk != initial || afterFirst.core.blobTable != before.core.blobTable, "\(operation): the first run did something")
        let mutations = harness.fileSystem.mutationCount
        try await IdempotencyTests.run(operation, harness, assets, first: false)
        let afterSecond = await harness.state
        #expect(harness.fileSystem.mutationCount == mutations, "\(operation): the second run touched the file system")
        #expect(afterSecond.core.records == afterFirst.core.records, "\(operation): the second run changed a record")
        #expect(afterSecond.core.blobTable == afterFirst.core.blobTable, "\(operation): the second run changed the blob table")
        #expect(afterSecond.cleanup.lastCleanupAt == afterFirst.cleanup.lastCleanupAt, "\(operation): a no-op is not a cleanup")
        #expect(afterSecond.core.stamp == afterFirst.core.stamp && afterSecond.core.syncDue == afterFirst.core.syncDue, "\(operation): the stamp")
        #expect(afterSecond.migration.phase == afterFirst.migration.phase && afterSecond.migration.progress == afterFirst.migration.progress)
        if operation == .deepVerification {
            // The corrupt bytes stay under their doomed name until the reaper runs (I-1 holds again after it).
            await harness.settleDeletions()
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test(
        "R-CLN-12: a staging or orphan collection cancelled between its units leaves every file removed or for the next run",
        .timeLimit(.minutes(1)),
        arguments: [Operation.stagingGC, .orphanGC]
    )
    @available(macOS 15.0, iOS 18.0, *)
    func cancelledCollection(operation: Operation) async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(deletionBatchSize: 1, metadata: metadata)
        _ = try await harness.store.open()
        var garbage: [URL] = []
        for index in 0..<3 {
            if operation == .stagingGC {
                let name = try await GarbageCollectionTests.stage(harness, CleanupFixture.asset("s\(index)", seed: 610 + UInt64(index)).entry, bytes: 50, sequence: UInt32(index + 1))
                garbage.append(harness.layout.stagingURL(name))
            } else {
                let key = try GarbageCollectionTests.plantBlob(harness.fileSystem, CoreFixture.bytes(620 + UInt64(index), count: 50))
                garbage.append(harness.layout.blobURL(key))
            }
        }
        harness.time.advance(by: 2 * 3_600)
        await metadata.setHolding(true)
        let task = Task { () throws -> CleanupResult in
            switch operation {
            case .stagingGC:
                return try await harness.store.collectStaging(keeping: [])
            default:
                return try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
            }
        }
        // Let units through one at a time until one garbage file is gone (staging GC removes in units) or the listing of
        // `blobs/` ran (orphan GC lists in units and dooms in one turn after its last one), then cancel the caller.
        let blobsListed = {
            harness.fileSystem.operations.filter { $0.kind == .contentsOfDirectory && $0.url.standardizedFileURL.path == harness.layout.blobsDirectory.standardizedFileURL.path }.count
        }
        let launchListings = blobsListed()
        try await CorePoll.releasing(metadata, until: "one unit of the collection ran") {
            operation == .stagingGC ? garbage.contains(where: { !harness.exists($0) }) : blobsListed() > launchListings
        }
        task.cancel()
        await metadata.setHolding(false)
        let outcome = await task.result
        let remaining = garbage.filter { harness.exists($0) }
        switch outcome {
        case .failure(let error):
            #expect(error as? StoreError == .cancelled)
        case .success:
            Issue.record("the cancelled collection ran to the end")
        }
        if operation == .stagingGC {
            #expect(remaining.count < garbage.count && !remaining.isEmpty, "the unit that ran stays done, the rest is left")
        } else {
            let doomed = await harness.state.core.blobTable.count { if case .doomed = $0.value { return true } else { return false } }
            #expect(remaining.count == garbage.count && doomed == 0, "a cancelled listing decides nothing: every orphan is left for the next run")
        }
        _ = operation == .stagingGC
            ? try await harness.store.collectStaging(keeping: [])
            : try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
        if operation == .orphanGC {
            // The sweep doomed them; the reaper unlinks them after the grace (I-3).
            #expect(garbage.allSatisfy { harness.exists($0) })
            await harness.settleDeletions()
        }
        #expect(garbage.allSatisfy { !harness.exists($0) }, "the next run finishes the collection")
    }
}
