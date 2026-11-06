import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
@testable import ZTronAssetStorage

/// Verifier probe (WP-K close-out cycle 3, requirements lens; scratch copy only, never committed): row k-7's claim that
/// close() resumes a migration batch waiting (L5K-R17) for an adopt-on-demand of the last claimed file.
@Suite("Verifier K-C3 store wait probe", .serialized)
struct VerifierKC3StoreWaitProbe {
    @Test("KC3-CLOSEWAIT: close() while a batch waits for the last adopt-on-demand ends both calls with the shutdown answer", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func closeWhileTheBatchWaits() async throws {
        let race = try await LegacyRace.open()
        await race.bulk.setHolding(true)
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let onDemandHash = Set(await race.bulk.heldUnits)
        let batch = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 64)
        }
        try await CorePoll.until("the batch returned or waits") {
            for unit in await race.bulk.heldUnits where !onDemandHash.contains(unit) {
                await race.bulk.release(unit)
            }
            return await race.settled(batch.finished)
        }
        let returnedEarly = await batch.finished.value
        let closing = Task {
            await race.harness.store.close()
        }
        try await CorePoll.until("the store is closing") {
            await race.harness.state.core.phase != .open
        }
        await race.releaseAll()
        await closing.value
        let batchResult = await batch.task.result
        let onDemandResult = await onDemand.task.result
        let left = await race.harness.state.migration
        print("KC3-CLOSEWAIT returnedEarly=\(returnedEarly) batch=\(batchResult) onDemand=\(onDemandResult) adopting=\(left.adopting.count) onDemandMarks=\(left.onDemand.count)")
        #expect(!returnedEarly)
        #expect(throws: StoreError.closed) { try batchResult.get() }
        #expect(left.adopting.isEmpty && left.onDemand.isEmpty)
    }
}
