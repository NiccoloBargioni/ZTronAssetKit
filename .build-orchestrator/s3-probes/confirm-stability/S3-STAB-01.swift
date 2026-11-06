import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Stage 3 stability probes (lens "stability"; S3-STAB-01).
@Suite("S3 stability probes: legacy phase 4 stop (R-STO-11)")
struct S3StabilityLegacyProbes {
    /// S3-STAB-01. Replays, step by step, the interleaving under which `LegacyEdgeTests.phaseFourStopsListing` fails with
    /// `listings() → 3`: its poll reads `listings()` (0) while the root's listing unit, released by the previous round,
    /// has not run yet; the round's `heldUnits` read then hops to the executor after that unit ran and phase 4 submitted
    /// its next listing, and the round releases that second phase-4 unit before the stop. The replay waits where the poll
    /// races, so it is deterministic. The product behaves (exactly the unit in flight lists after the stop: the last
    /// expectation passes); the test's oracle, `listings() == 2`, does not hold under this legal schedule.
    @Test(
        "R-STO-11: (S3-STAB-01) phase 4's stop test counts the root and the unit in flight even when its poll's listing read predates the root's listing",
        .timeLimit(.minutes(1)),
        arguments: LegacyEdgeTests.PhaseFourStop.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func phaseFourStopPollReplay(_ stop: LegacyEdgeTests.PhaseFourStop) async throws {
        let files = try LegacyFixture.fixtureFiles()
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(files), legacy: CleanupFixture.legacyPolicy, defaults: defaults, metadata: metadata)
        _ = try await harness.store.open()
        let root = CleanupFixture.legacyRoot.standardizedFileURL.path
        let count = {
            harness.fileSystem.operations.filter { $0.kind == .contentsOfDirectory && $0.url.standardizedFileURL.path.hasPrefix(root) }.count
        }
        let phaseOne = count()
        let listings = {
            count() - phaseOne
        }
        await metadata.setHolding(true)
        let migration = Task {
            try await harness.store.migrateLegacy(maxFiles: 100)
        }
        // The poll's rounds up to the one that releases the root's listing unit: each releases the oldest held unit. The
        // replay then waits for the next held unit, so the released unit has run before the next round's reads.
        try await metadata.requireHeldUnits(atLeast: 1)
        var readBeforeLastRelease = listings()
        while listings() == 0 {
            readBeforeLastRelease = listings()
            let unit = try #require(await metadata.heldUnits.first)
            await metadata.release(unit)
            try await metadata.requireHeldUnits(atLeast: 1)
        }
        // The losing round. Its `listings()` read was taken right after the previous round's release, before the root's
        // unit ran (it read `readBeforeLastRelease`, 0), so it does not return; its `heldUnits` read reaches the executor
        // after the root's unit ran and phase 4 submitted its next listing, and it releases that unit.
        #expect(readBeforeLastRelease == 0)
        #expect(listings() == 1, "the root's listing ran; phase 4's next listing is held")
        let next = try #require(await metadata.heldUnits.first)
        await metadata.release(next)
        // The next round reads `listings() > 0` and the poll returns: from here on the test runs as written.
        try await metadata.requireHeldUnits(atLeast: 1)
        let atStop = listings()
        let closing: Task<Void, Never>?
        switch stop {
        case .cancelled:
            migration.cancel()
            closing = nil
        case .closed:
            closing = Task {
                await harness.store.close()
            }
            try await CorePoll.until("close() began") {
                await harness.state.core.phase == .closing
            }
        }
        await metadata.setHolding(false)
        await metadata.releaseAll()
        await #expect(throws: stop == .cancelled ? StoreError.cancelled : StoreError.closed) {
            _ = try await migration.value
        }
        await closing?.value
        // phaseFourStopsListing's oracle (LegacyEdgeTests.swift:444): fails here with 3.
        #expect(listings() == 2, "the root, then the unit that was in flight; no listing after it")
        // The product's property, independent of how many units the poll let through before the stop: holds.
        #expect(listings() == atStop + 1, "exactly the unit in flight lists after the stop")
    }
}
