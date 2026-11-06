import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

// Temporary probe (WP-K close-out cycle 4, never committed): a prefetch job promoted while the store publishes its
// transfer at prefetch urgency. Does its user-initiated waiter return before the readers' snapshot holds the asset?
@Suite("Probe K4 commit promotion", .serialized)
struct ProbeK4CommitPromotion {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("K4-COMMITPROMO", .timeLimit(.minutes(1)))
    func commitPromotion() async throws {
        var rows: [String] = []
        for run in 0..<5 {
            let time = ManualTimeSource()
            let bulk = SteppedBlockingExecutor(holding: false)
            let bytes = EngineFixture.bytes(4_400 + UInt64(run), count: 4_096)
            let entry = EngineFixture.entry("page0", bytes, policy: .onDemand)
            let harness = EngineHarness.make(time: time, bulk: bulk, installInterval: 0.1)
            await harness.serve([(entry, bytes)])
            let engine = harness.engine
            _ = try await harness.start()
            _ = await engine.sync(.force)
            await bulk.setHolding(true)
            let token = try await engine.registerGroup([entry.identifier], lane: .prefetch).get()
            try await EngineLegacyMigrationTransferTests.release(bulk, keeping: [], on: engine) { engine in
                engine.state.jobs[entry.transferID]?.state == .verifying
            }
            try await bulk.requireHeldUnits(atLeast: 1)
            let resolve = Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
            await engine.awaitCondition { $0.state.jobs[entry.transferID]?.lane == .userInitiated }
            await bulk.setHolding(false)
            let location = try await resolve.value.get()
            let unseen = await EngineLegacyMigrationTransferTests.unseen(harness, [entry.identifier])
            rows.append("run=\(run) located=\(location.url.lastPathComponent.isEmpty == false) unseenAtReturn=\(unseen.count) starts=\(await harness.source.starts.count)")
            await engine.releaseGroup(token)
            await engine.shutdown()
        }
        for row in rows {
            print("K4-COMMITPROMO \(row)")
        }
        #expect(rows.count == 5)
    }
}
