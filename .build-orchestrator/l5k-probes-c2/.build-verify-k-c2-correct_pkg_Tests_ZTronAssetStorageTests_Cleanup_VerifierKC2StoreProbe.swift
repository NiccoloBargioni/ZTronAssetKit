import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
@testable import ZTronAssetStorage

/// Verifier probes, WP-K close-out cycle 2, correctness lens (store level). Scratch copy only; never committed.
@Suite("Verifier K-C2 store probes", .serialized)
struct VerifierKC2StoreProbe {
    /// PS1b (cycle 1's regression shape, written anew): the batch hashed the file and its placement unit is held (its key
    /// in `publishing`, nothing bound); every later read of the file fails with `notFound`. The adopt-on-demand must not
    /// answer before the placement ended, and must answer the location the batch bound.
    @Test("PS1b-c2: an adopt-on-demand of a file a batch is placing answers the batch's location", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func ps1b() async throws {
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
        let publishing = await harness.state.core.publishing.contains { $0.hash == first.digest }
        harness.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(pathContains: path.path), occurrence: .every, error: .notFound))
        await bulk.setHolding(false)
        let finished = CleanupSteps.Finished()
        let onDemand = Task { () async throws -> AssetLocation? in
            let location = try await harness.store.adoptLegacyNow(id)
            await finished.set()
            return location
        }
        try await CorePoll.until("the adopt-on-demand answered or waits") {
            for unit in await metadata.heldUnits where !batchPlacement.contains(unit) {
                await metadata.release(unit)
            }
            let migration = await harness.state.migration
            let waiting = !(migration.adopting[first.components]?.isEmpty ?? true) || !(migration.onDemand[first.components]?.isEmpty ?? true)
            let keyWaiting = await harness.state.core.keyWaiters.contains { $0.key.hash == first.digest && !$0.value.isEmpty }
            return await finished.value || waiting || keyWaiting
        }
        let answeredEarly = await finished.value
        let stillHeld = Set(await metadata.heldUnits).isSuperset(of: batchPlacement)
        await metadata.setHolding(false)
        let progress = try await batch.value
        let answer = try await onDemand.value
        let location = await harness.store.location(for: id, extensions: [], recordingAccess: false)
        print("KC2-PROBE PS1b publishing=\(publishing) answeredBeforePlacementEnded=\(answeredEarly) placementHeldWhileWaiting=\(stillHeld) answer=\(String(describing: answer)) location=\(String(describing: location)) progress=\(progress)")
        #expect(!answeredEarly)
        #expect(answer != nil && answer == location)
        #expect(progress.adopted == 1 && progress.dropped == 0)
    }

    /// PS2: the PK2b interleaving itself. The batch holds the file and is hashing it; an adopt-on-demand of the same id
    /// arrives (no mark yet) and hashes it too. The batch's hash ends first: it marks the adoption and its placement unit
    /// is held (the file renamed away). Then the adopt-on-demand's hash ends with `notFound`. It must wait for the batch's
    /// adoption and answer the location, and the batch must count the file once.
    @Test("PS2: an adopt-on-demand whose own hash fails because a batch renamed the file answers the batch's location", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func ps2() async throws {
        let race = try await LegacyRace.open()
        await race.bulk.setHolding(true)
        await race.metadata.setHolding(true)
        let batch = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 1)
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let batchHash = Set(await race.bulk.heldUnits)
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await race.bulk.requireHeldUnits(atLeast: batchHash.count + 1)
        let onDemandHash = Set(await race.bulk.heldUnits).subtracting(batchHash)
        let marksBefore = await race.harness.state.migration
        // The batch's hash ends; its adoption starts and its placement unit is held.
        for unit in batchHash {
            await race.bulk.release(unit)
        }
        let placement = try await race.holdPlacement(keepingBulk: onDemandHash)
        let adoptingByBatch = await race.harness.state.migration.adopting[race.file.components] != nil
        race.renamedAway()
        for unit in onDemandHash {
            await race.bulk.release(unit)
        }
        try await CorePoll.until("the adopt-on-demand answered or waits for the batch's adoption") {
            for unit in await race.bulk.heldUnits {
                await race.bulk.release(unit)
            }
            for unit in await race.metadata.heldUnits where !placement.contains(unit) {
                await race.metadata.release(unit)
            }
            return await race.settled(onDemand.finished)
        }
        let answeredEarly = await onDemand.finished.value
        await race.releaseAll()
        let progress = try await batch.task.value
        let answer = try await onDemand.task.value
        let total = try await race.harness.store.migrateLegacy(maxFiles: 0)
        let location = await race.harness.store.location(for: race.id, extensions: [], recordingAccess: false)
        print("KC2-PROBE PS2 onDemandMarkedBeforeBatchAdoption=\(marksBefore.onDemand[race.file.components] != nil) adoptingByBatch=\(adoptingByBatch) answeredEarly=\(answeredEarly) answer=\(String(describing: answer)) location=\(String(describing: location)) batch=\(progress) total=\(total)")
        #expect(!answeredEarly, "the adopt-on-demand answered before the batch's adoption ended")
        #expect(answer != nil && answer == location, "nil makes the engine download a file the batch adopted (R-STO-11)")
        #expect(total.adopted == 1 && total.dropped == 0)
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }

    /// PS3: the migration loop's contract while an adopt-on-demand took the last queued file and is still processing it:
    /// what `migrateLegacy` answers, call after call, without waiting for anything (the engine's loop calls again at once
    /// while `remaining > 0 && !finished`, RE-S29).
    @Test("PS3: migrateLegacy while an adopt-on-demand holds the last file", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func ps3() async throws {
        let race = try await LegacyRace.open()
        // Drain the queue except one file.
        let queued = await race.harness.state.migration.queue.count
        if queued > 1 {
            _ = try await race.harness.store.migrateLegacy(maxFiles: queued - 1)
        }
        let last = try #require(await race.harness.state.migration.queue.last)
        let lastID = try #require(last.ids.first)
        await race.bulk.setHolding(true)
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(lastID)
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        var answers: [LegacyMigrationProgress] = []
        let start = DispatchTime.now().uptimeNanoseconds
        var calls = 0
        while DispatchTime.now().uptimeNanoseconds - start < 50_000_000 {
            let progress = try await race.harness.store.migrateLegacy(maxFiles: 64)
            calls += 1
            if answers.last != progress {
                answers.append(progress)
            }
        }
        let held = await race.bulk.heldUnits.count
        print("KC2-PROBE PS3 queuedAtStart=\(queued) callsIn50ms=\(calls) distinctAnswers=\(answers) heldUnits=\(held)")
        await race.releaseAll()
        _ = try await onDemand.task.value
        let final = try await race.harness.store.migrateLegacy(maxFiles: 64)
        print("KC2-PROBE PS3 afterOnDemand=\(final)")
        #expect(calls < 100, "\(calls) migrateLegacy calls returned in 50 ms, each `remaining > 0, finished == false` with nothing to do: the engine's loop calls again at once")
    }
}
