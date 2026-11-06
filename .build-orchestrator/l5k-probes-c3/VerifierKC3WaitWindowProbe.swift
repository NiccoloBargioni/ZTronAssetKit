import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Verifier probe (WP-K close-out cycle 3, requirements lens; scratch copy only, never committed). L5K-R17 makes a
/// migration batch wait inside `migrateLegacy` for an adopt-on-demand of the last claimed file, after the batch has
/// already published its own adoptions at bulk urgency. L5K-R16's re-arm for the batch runs only once the call returns.
/// Do the batch's adoptions reach the readers within an install interval while the batch waits?
@Suite("Verifier K-C3 wait-window probe", .serialized)
struct VerifierKC3WaitWindowProbe {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("KC3-WAITWINDOW: a batch's bulk adoptions reach the readers while the batch waits for an on-demand adoption", .timeLimit(.minutes(1)))
    func batchAdoptionsWhileTheBatchWaits() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(4, seed: 9_600)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        // The job takes the last pending file (still queued: the batch takes the files in path order).
        let jobAsset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let token = try await engine.registerGroup([jobAsset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let batchIDs = pending.subtracting([jobAsset.identifier])
        // Let the batch adopt every other pending file and publish them; it then waits for the job's adoption.
        while !harness.tap.lines.contains(where: { $0.message.contains("a migration batch waits for an adopt-on-demand") }) {
            for unit in await bulk.heldUnits where !jobHash.contains(unit) {
                await bulk.release(unit)
            }
            await Task.yield()
            try Task.checkCancellation()
        }
        let view = try await harness.view()
        let storedByBatch = batchIDs.filter { view.records[$0]?.referencedBlob != nil }.count
        let unseenAtWait = await EngineLegacyMigrationTransferTests.unseen(harness, batchIDs)
        let storeNextAtWait = await harness.store.nextDeadline()
        let heapAtWait = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        // The clock passes the install window by far; whatever the engine armed runs.
        time.advance(by: 1)
        try await EngineLegacyMigrationTransferTests.runStoreWork(harness)
        let unseenAfterWindow = await EngineLegacyMigrationTransferTests.unseen(harness, batchIDs)
        let heapAfter = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        let storeNextAfter = await harness.store.nextDeadline()
        let now = time.monotonicNow()
        print("KC3-WAITWINDOW batchIDs=\(batchIDs.count) storedByBatch=\(storedByBatch) unseenAtWait=\(unseenAtWait.count) storeNextAtWait=\(String(describing: storeNextAtWait)) heapAtWait=\(String(describing: heapAtWait)) now=\(now) unseenAfterWindow=\(unseenAfterWindow.count) heapAfter=\(String(describing: heapAfter)) storeNextAfter=\(String(describing: storeNextAfter))")
        #expect(storedByBatch == batchIDs.count, "premise: the batch adopted its files before it waited")
        #expect(unseenAfterWindow.isEmpty, "\(unseenAfterWindow.count) of \(batchIDs.count) files the batch adopted are still out of the readers' snapshot 1 s after their publication, while the batch waits")
        for unit in jobHash {
            await bulk.release(unit)
        }
        await EngineLegacyMigrationTransferTests.finishMigration(harness, bulk: bulk)
        try await harness.drive { $0.isIdleSilent }
        let unseenAtEnd = await EngineLegacyMigrationTransferTests.unseen(harness, catalog.map(\.0.identifier))
        print("KC3-WAITWINDOW atEnd unseen=\(unseenAtEnd.count) starts=\(await harness.source.starts.count)")
        await engine.releaseGroup(token)
        await engine.shutdown()
    }
}

/// Row k-7 / L5K-R17: shutdown while the migration loop's call waits for a job's adoption of the last claimed file.
@Suite("Verifier K-C3 shutdown-wait probe", .serialized)
struct VerifierKC3ShutdownWaitProbe {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("KC3-SHUTDOWNWAIT: shutdown while the batch waits for a job's adoption returns and leaves no flag", .timeLimit(.minutes(1)))
    func shutdownWhileTheBatchWaits() async throws {
        let time = ManualTimeSource()
        let catalog = EngineLegacyMigrationTransferTests.catalog(4, seed: 9_700)
        let (harness, bulk) = try await EngineLegacyMigrationTransferTests.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await EngineLegacyMigrationTransferTests.startHoldingMigration(harness, bulk: bulk)
        let pending = try await EngineLegacyMigrationTransferTests.pending(harness, catalog)
        let jobAsset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let token = try await engine.registerGroup([jobAsset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        while !harness.tap.lines.contains(where: { $0.message.contains("a migration batch waits for an adopt-on-demand") }) {
            for unit in await bulk.heldUnits where !jobHash.contains(unit) {
                await bulk.release(unit)
            }
            await Task.yield()
            try Task.checkCancellation()
        }
        _ = token
        let stopping = Task { await engine.shutdown() }
        await engine.awaitCondition { !$0.isRunning }
        await bulk.setHolding(false)
        await stopping.value
        let flags = await engine.readForTests { ($0.state.migration.running, $0.state.migration.launchRunWaiting) }
        print("KC3-SHUTDOWNWAIT returned running=\(flags.0) launchRunWaiting=\(flags.1) starts=\(await harness.source.starts.count)")
        #expect(!flags.0 && !flags.1)
    }
}
