import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetStorage
import ZTronAssetTestSupport

/// Verifier probe, WP-K close-out cycle 1, correctness lens (store level). Scratch copy only.
///
/// The interleaving behind PK2b: a batch has claimed a legacy file, hashed it and is placing it (its key is in
/// `publishing`, its binding not yet made); an adopt-on-demand of the same id (the engine's pre-transfer read since
/// L5K-R1) finds the file in `claimed`, hashes it, and its read fails with `notFound` because the batch's placement
/// renamed the file away. The probe holds the batch's placement unit and makes the on-demand read fail with `notFound`
/// (the state the on-demand call observes after the rename and before the binding), deterministically.
@Suite("Verifier K-C1 store probe", .serialized)
struct VerifierKC1StoreProbe {
    @Test("PS1: an adopt-on-demand of a file a batch is placing answers nil, although the batch adopts the file", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func adoptNowWhileBatchPlaces() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let bulk = SteppedBlockingExecutor(holding: false)
        let metadata = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: CleanupFixture.legacyPolicy, defaults: defaults, metadata: metadata, bulk: bulk)
        _ = try await harness.store.open()
        let first = try #require(await harness.state.migration.queue.last, "the next file is the queue's last")
        let id = try #require(first.ids.first)
        let path = CleanupFixture.legacyRoot.appendingPathComponent(first.components.joined(separator: "/"))
        await bulk.setHolding(true)
        await metadata.setHolding(true)
        let batch = Task {
            try await harness.store.migrateLegacy(maxFiles: 1)
        }
        // The batch's hash unit: let it run.
        try await bulk.requireHeldUnits(atLeast: 1)
        for unit in await bulk.heldUnits {
            await bulk.release(unit)
        }
        // The batch's placement unit (metadata executor) is held: its key is publishing, nothing bound yet.
        try await metadata.requireHeldUnits(atLeast: 1)
        let batchPlacement = Set(await metadata.heldUnits)
        let publishing = await harness.state.core.publishing.contains { $0.hash == first.digest }
        #expect(publishing, "the batch's placement of the file is in flight")
        // The batch's placement renamed the file away: every later read of it finds nothing.
        harness.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(pathContains: path.path), occurrence: .every, error: .notFound))
        print("KC1-PROBE PS1 file=\(first.components) faultPath=\(path.path) publishing=\(publishing) batchPlacementUnits=\(batchPlacement.sorted())")
        // Bulk units run freely from here; every metadata unit but the batch's placement is released.
        await bulk.setHolding(false)
        let (value, released) = try await CleanupSteps.run(metadata, keeping: batchPlacement) {
            try await harness.store.adoptLegacyNow(id)
        }
        let answer: AssetLocation?? = .some(value)
        print("KC1-PROBE PS1 releasedMetadataUnitsForOnDemand=\(released)")
        let onDemandAnswer = answer ?? nil
        let stillHeld = Set(await metadata.heldUnits).isSuperset(of: batchPlacement)
        print("KC1-PROBE PS1 onDemandAnswer=\(String(describing: onDemandAnswer)) batchPlacementStillHeld=\(stillHeld)")
        // The batch goes on and adopts the file.
        await bulk.setHolding(false)
        await metadata.setHolding(false)
        let progress = try await batch.value
        let location = await harness.store.location(for: id, extensions: [], recordingAccess: false)
        print("KC1-PROBE PS1 batchProgress=\(progress) locationAfterBatch=\(String(describing: location))")
        #expect(location != nil, "the batch adopted the file")
        #expect(onDemandAnswer != nil, "adoptLegacyNow answered nil for a file a batch was adopting: the engine's pre-transfer read then downloads it (L5K-R1, R-STO-11)")
    }

    /// The regression-test shape for the fix: the adopt-on-demand of a file whose racing placement is in flight waits for
    /// that placement and answers the file's location; it fails on the current code (nil before the placement ends).
    @Test("PS1b: an adopt-on-demand of a file a batch is placing waits for the placement and answers its location", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func adoptNowWaitsForBatchPlacement() async throws {
        let files = try LegacyFixture.fixtureFiles()
        let bulk = SteppedBlockingExecutor(holding: false)
        let metadata = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: CleanupFixture.legacyPolicy, defaults: defaults, metadata: metadata, bulk: bulk)
        _ = try await harness.store.open()
        let first = try #require(await harness.state.migration.queue.last)
        let id = try #require(first.ids.first)
        let path = CleanupFixture.legacyRoot.appendingPathComponent(first.components.joined(separator: "/"))
        await bulk.setHolding(true)
        await metadata.setHolding(true)
        let batch = Task {
            try await harness.store.migrateLegacy(maxFiles: 1)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        for unit in await bulk.heldUnits {
            await bulk.release(unit)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let batchPlacement = Set(await metadata.heldUnits)
        #expect(await harness.state.core.publishing.contains { $0.hash == first.digest })
        harness.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(pathContains: path.path), occurrence: .every, error: .notFound))
        await bulk.setHolding(false)
        let finished = CleanupSteps.Finished()
        let onDemand = Task { () async throws -> AssetLocation? in
            let location = try await harness.store.adoptLegacyNow(id)
            await finished.set()
            return location
        }
        try await CorePoll.until("the adopt-on-demand answered or waits for the racing placement") {
            for unit in await metadata.heldUnits where !batchPlacement.contains(unit) {
                await metadata.release(unit)
            }
            let waiting = await harness.state.core.keyWaiters.contains { $0.key.hash == first.digest && !$0.value.isEmpty }
            return await finished.value || waiting
        }
        let answeredEarly = await finished.value
        await metadata.setHolding(false)
        _ = try await batch.value
        let answer = try await onDemand.value
        print("KC1-PROBE PS1b answeredBeforeThePlacementEnded=\(answeredEarly) answer=\(String(describing: answer))")
        #expect(!answeredEarly, "the adopt-on-demand answered before the racing placement ended")
        #expect(answer != nil, "the adopt-on-demand answers the location the racing placement bound")
    }
}
