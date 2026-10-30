import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// One adoption per prior-art file, whoever asks (orchestrator ruling L5K-R13, R-STO-11; REENTRANCY k-5 and k-6,
/// proposed in `docs/adr-drafts/k.md`). A migration batch and an adopt-on-demand, or two adopt-on-demand calls, that
/// process the same legacy file adopt it once, and every asker gets the outcome of that adoption: its location, or `nil`
/// only when the file was really dropped or kept. A failure caused only by the other adopter (the file renamed away by
/// its placement, its key in `publishing`, its caller's cancellation) is never reported as dropped, deferred or `nil`:
/// before L5K-R13 such an answer made the engine's pre-transfer read download a file the batch adopted moments later
/// (L5K-C1-00, the verifier's probes PS1 and PK2b).
///
/// Each test holds the call that goes first at a unit of a `SteppedBlockingExecutor` and gives the other call what it
/// would observe after a placement renamed the file away, a `notFound` fault on every later read of the file (the
/// verifier's probe PS1b), so every interleaving is deterministic.
@Suite("Cleanup: one adoption per legacy file (L5K-R13)")
struct LegacyOnDemandRaceTests {
    @Test("R-STO-11: an adopt-on-demand of a legacy file a batch is placing waits for that adoption and answers the location it bound (L5K-R13)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func onDemandJoinsTheBatchsAdoption() async throws {
        let race = try await LegacyRace.open()
        await race.metadata.setHolding(true)
        let batch = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 1)
        }
        // The batch hashed the file (bulk units run freely) and its placement unit is held: its key is in `publishing`,
        // no record is bound yet, and a reader of the file finds it gone (the rename, PS1b).
        let placement = try await race.holdPlacement()
        race.renamedAway()
        let readsBefore = race.reads()
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await CorePoll.releasing(race.metadata, .allExcept(placement), until: "the adopt-on-demand answered or waits for the batch's adoption") {
            await race.settled(onDemand.finished)
        }
        let answeredEarly = await onDemand.finished.value
        let readsWhileWaiting = race.reads() - readsBefore
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("both calls ended") {
            await LegacyRace.ended(batch.finished, onDemand.finished)
        }
        let progress = try await batch.task.value
        let answer = try await onDemand.task.value
        let location = await race.harness.store.location(for: race.id, extensions: [], recordingAccess: false)

        #expect(!answeredEarly, "the adopt-on-demand answered before the batch's adoption of the file ended")
        #expect(readsWhileWaiting == 0, "it read none of the file's bytes: the batch's hash serves it")
        #expect(answer != nil && answer == location, "it answers the location the batch bound, so the engine's pre-transfer read never downloads the file (R-STO-11)")
        #expect(race.harness.content(try #require(location).url) == race.bytes)
        #expect(progress.adopted == 1 && progress.dropped == 0, "the batch adopted the file and counted it once: \(progress)")
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }

    @Test("R-STO-11: a batch whose read of a legacy file fails while an adopt-on-demand places that file waits for that adoption and reports the file adopted once, never dropped (L5K-R13)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func batchWaitsForTheOnDemandAdoption() async throws {
        let race = try await LegacyRace.open()
        await race.bulk.setHolding(true)
        await race.metadata.setHolding(true)
        let batch = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 1)
        }
        // The batch holds the file and waits for its first hash unit.
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let batchHash = Set(await race.bulk.heldUnits)
        #expect(await race.harness.state.migration.claimed == [race.file], "the batch holds the file")
        // An adopt-on-demand of a file a batch has claimed but not hashed yet processes it at once (WP-C's
        // `adoptNowRacesBatch`): a lookup never waits behind a batch's hash. Its hash runs first and its placement is held.
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await race.bulk.requireHeldUnits(atLeast: batchHash.count + 1)
        let placement = try await race.holdPlacement(keepingBulk: batchHash)
        // The adopt-on-demand's placement renames the file away: the batch's read now fails with `notFound`.
        race.renamedAway()
        for unit in batchHash {
            await race.bulk.release(unit)
        }
        try await CorePoll.releasing(race.metadata, .allExcept(placement), until: "the batch decided or waits for the adopt-on-demand's adoption") {
            await race.settled(batch.finished)
        }
        let batchDecidedEarly = await batch.finished.value
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("both calls ended") {
            await LegacyRace.ended(batch.finished, onDemand.finished)
        }
        let progress = try await batch.task.value
        let answer = try await onDemand.task.value
        let total = try await race.harness.store.migrateLegacy(maxFiles: 0)
        let location = await race.harness.store.location(for: race.id, extensions: [], recordingAccess: false)

        #expect(!batchDecidedEarly, "the batch decided about the file before the adopt-on-demand's adoption of it ended")
        #expect(progress.dropped == 0, "the batch did not count as dropped the file the adopt-on-demand adopted: \(progress)")
        #expect(total.adopted == 1 && total.dropped == 0, "counted once, by the call that adopted it: \(total)")
        #expect(answer != nil && answer == location)
        #expect(race.harness.content(try #require(location).url) == race.bytes)
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }

    @Test("R-STO-11: an adopt-on-demand of a legacy file another adopt-on-demand is placing waits for it and answers the location it bound (L5K-R13)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func secondOnDemandJoinsTheFirstsAdoption() async throws {
        let race = try await LegacyRace.open()
        await race.metadata.setHolding(true)
        // The first call takes the file from the queue, hashes it and its placement unit is held.
        let first = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        let placement = try await race.holdPlacement()
        race.renamedAway()
        let readsBefore = race.reads()
        let second = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await CorePoll.releasing(race.metadata, .allExcept(placement), until: "the second adopt-on-demand answered or waits for the first") {
            await race.settled(second.finished)
        }
        let secondAnsweredEarly = await second.finished.value
        let readsBySecond = race.reads() - readsBefore
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("both calls ended") {
            await LegacyRace.ended(first.finished, second.finished)
        }
        let firstAnswer = try await first.task.value
        let secondAnswer = try await second.task.value
        let total = try await race.harness.store.migrateLegacy(maxFiles: 0)
        let location = await race.harness.store.location(for: race.id, extensions: [], recordingAccess: false)

        #expect(!secondAnsweredEarly, "the second call answered before the first call's adoption of the file ended")
        #expect(readsBySecond == 0, "the second call read none of the file's bytes")
        #expect(firstAnswer != nil && firstAnswer == location && secondAnswer == location, "both answer the location the first call bound")
        #expect(total.adopted == 1 && total.dropped == 0, "counted once: \(total)")
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }

    @Test("R-STO-11: two adopt-on-demand calls of one legacy file share one hash: the second waits for the first's processing and hashes nothing (L5K-R13)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func secondOnDemandSharesTheFirstsHash() async throws {
        let race = try await LegacyRace.open()
        await race.bulk.setHolding(true)
        let first = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        // The first call took the file from the queue and waits for its hash unit.
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let firstHash = await race.bulk.heldUnits.count
        #expect(await race.harness.state.migration.queue.contains(race.file) == false, "taken from the queue")
        let second = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await CorePoll.until("the second call hashes the file too, waits for the first, or answered") {
            if await race.bulk.heldUnits.count > firstHash {
                return true
            }
            return await race.settled(second.finished)
        }
        let secondHashed = await race.bulk.heldUnits.count > firstHash
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("both calls ended") {
            await LegacyRace.ended(first.finished, second.finished)
        }
        let firstAnswer = try await first.task.value
        let secondAnswer = try await second.task.value
        let location = await race.harness.store.location(for: race.id, extensions: [], recordingAccess: false)

        #expect(!secondHashed, "the second call submitted a hash of its own (C2 and the battery: one hash per file)")
        #expect(race.reads() == 1, "one pass over the file's bytes for both calls")
        #expect(firstAnswer != nil && firstAnswer == location && secondAnswer == location)
        #expect(try await race.harness.store.migrateLegacy(maxFiles: 0).adopted == 1)
    }

    @Test("R-STO-11: close() while an adopt-on-demand waits for another call's adoption of the same legacy file resumes it with the store's shutdown answer (L5K-R13)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func closeResumesAWaitingAsker() async throws {
        let race = try await LegacyRace.open()
        await race.metadata.setHolding(true)
        let batch = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 1)
        }
        let placement = try await race.holdPlacement()
        race.renamedAway()
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await CorePoll.releasing(race.metadata, .allExcept(placement), until: "the adopt-on-demand answered or waits for the batch's adoption") {
            await race.settled(onDemand.finished)
        }
        let answeredEarly = await onDemand.finished.value
        // close() begins while the batch's placement unit is held; its drain then lets that unit finish.
        let closing = LegacyRace.tracked {
            await race.harness.store.close()
        }
        try await CorePoll.until("the store is closing") {
            await race.harness.state.core.phase != .open
        }
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R25, L5K-C4-12).
        try await CorePoll.until("close() and both calls ended") {
            await LegacyRace.ended(closing.finished, batch.finished, onDemand.finished)
        }
        let batchResult = await batch.task.result
        let onDemandResult = await onDemand.task.result

        #expect(!answeredEarly, "the adopt-on-demand answered before the batch's adoption of the file ended")
        #expect(throws: StoreError.closed, "the waiting call ends with the store's shutdown answer") {
            try onDemandResult.get()
        }
        #expect(throws: StoreError.closed) {
            try batchResult.get()
        }
        let left = await race.harness.state.migration
        #expect(left.adopting.isEmpty && left.onDemand.isEmpty, "no flight or waiter is left")
    }

    @Test("R-STO-11: an adopt-on-demand waiting for another call whose caller was cancelled takes the file over and adopts it (L5K-R13)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func waiterTakesOverACancelledProcessing() async throws {
        // 1.5 MiB: two hash units, so the first call's cancellation is seen between them.
        let big = CoreFixture.bytes(782, count: 3 << 19)
        let small = CoreFixture.bytes(783)
        let entries = [CoreFixture.entry("big", big), CoreFixture.entry("small", small)]
        let race = try await LegacyRace.open(files: [
            "manifest.json": try LegacyFixture.manifestJSON(entries),
            LegacyFixture.relativePath(entries[0]): big,
            LegacyFixture.relativePath(entries[1]): small,
        ])
        try #require(race.file.ids == ["big"], "the next file is the big one")
        await race.bulk.setHolding(true)
        let first = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow("big")
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let firstHash = await race.bulk.heldUnits.count
        let second = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow("big")
        }
        try await CorePoll.until("the second call hashes the file too, waits for the first, or answered") {
            if await race.bulk.heldUnits.count > firstHash {
                return true
            }
            return await race.settled(second.finished)
        }
        let waited = await race.someoneWaits()
        first.task.cancel()
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("both calls ended") {
            await LegacyRace.ended(first.finished, second.finished)
        }
        let firstResult = await first.task.result
        let secondAnswer = try await second.task.value
        let total = try await race.harness.store.migrateLegacy(maxFiles: 0)

        #expect(waited, "the second call waited for the first instead of hashing the file itself")
        #expect(throws: StoreError.cancelled) {
            try firstResult.get()
        }
        #expect(secondAnswer != nil, "a failure caused only by the other call (its caller's cancellation) is never answered nil")
        #expect(secondAnswer == (await race.harness.store.location(for: "big", extensions: [], recordingAccess: false)))
        #expect(await race.harness.isPresent("big", at: CoreFixture.key(big)))
        #expect(total.adopted == 1 && total.dropped == 0 && total.remaining == 1, "adopted once; the small file is still queued: \(total)")
        #expect(await race.harness.state.migration.queue.map(\.ids) == [["small"]], "the big file is not queued twice")
    }

    @Test("R-STO-11: an adopt-on-demand waiting for another call whose read of the file failed transiently tries the file once more and adopts it (L5K-R13)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func waiterRetriesADeferredFile() async throws {
        let race = try await LegacyRace.open()
        await race.bulk.setHolding(true)
        let first = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let firstHash = await race.bulk.heldUnits.count
        let second = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await CorePoll.until("the second call hashes the file too, waits for the first, or answered") {
            if await race.bulk.heldUnits.count > firstHash {
                return true
            }
            return await race.settled(second.finished)
        }
        let waited = await race.someoneWaits()
        // The first call's read fails with an I/O error that says nothing about the file's bytes: it defers the file.
        race.harness.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(pathContains: race.path.path), occurrence: .nth(1), error: .io))
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("both calls ended") {
            await LegacyRace.ended(first.finished, second.finished)
        }
        let firstAnswer = try await first.task.value
        let secondAnswer = try await second.task.value
        let migration = await race.harness.state.migration
        let location = await race.harness.store.location(for: race.id, extensions: [], recordingAccess: false)
        let total = try await race.harness.store.migrateLegacy(maxFiles: 0)

        #expect(waited, "the second call waited for the first instead of hashing the file itself")
        #expect(firstAnswer == nil, "the call whose read failed answers nil, as an adopt-on-demand that defers its file always did")
        #expect(migration.deferrals[race.file.components] == 1, "that failure deferred the file once")
        #expect(secondAnswer != nil && secondAnswer == location, "the waiting call tried the file again rather than answer nil: nil only for a file dropped or kept")
        #expect(total.adopted == 1 && total.dropped == 0, "adopted once: \(total)")
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }
}

extension LegacyOnDemandRaceTests {
    @Test("R-STO-11: a migration batch that finds the queue empty while an adopt-on-demand holds the last claimed legacy file waits for that adoption and finishes the migration in the same call, so its caller never calls again at once (L5K-R17, PS3)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func batchWaitsForTheLastOnDemandAdoption() async throws {
        let race = try await LegacyRace.open()
        await race.bulk.setHolding(true)
        // An adopt-on-demand takes the next file from the queue and its hash unit is held.
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let onDemandHash = Set(await race.bulk.heldUnits)
        // A batch adopts every other file, then finds the queue empty and the one claimed file held by that call.
        let batch = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 64)
        }
        try await CorePoll.releasing(race.bulk, .allExcept(onDemandHash), until: "the batch returned or waits for the adopt-on-demand of the last claimed file") {
            await race.settled(batch.finished)
        }
        let returnedEarly = await batch.finished.value
        let held = await race.harness.state.migration
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("both calls ended") {
            await LegacyRace.ended(batch.finished, onDemand.finished)
        }
        let progress = try await batch.task.value
        let answer = try await onDemand.task.value
        let location = await race.harness.store.location(for: race.id, extensions: [], recordingAccess: false)

        #expect(held.queue.isEmpty && held.claimed == [race.file], "premise: the queue is empty and the adopt-on-demand holds the one claimed file")
        #expect(!returnedEarly, "migrateLegacy returned while that adoption ran, with nothing it could do: its caller calls again at once, a hot loop (L5K-C2-01)")
        #expect(progress.finished && progress.remaining == 0, "the same call finished the migration once that adoption ended: \(progress)")
        #expect(answer != nil && answer == location, "the adopt-on-demand answers its location")
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }

    @Test("R-STO-11: close() while a migration batch waits for the adopt-on-demand of the last claimed legacy file ends both calls with the store's shutdown answer and leaves no mark (L5K-R17, L5K-R22, row k-7)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func closeWhileTheBatchWaits() async throws {
        let race = try await LegacyRace.open()
        await race.bulk.setHolding(true)
        // An adopt-on-demand takes the next file from the queue and its hash unit is held.
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let onDemandHash = Set(await race.bulk.heldUnits)
        // A batch adopts every other file, then waits for that adoption of the one claimed file.
        let batch = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 64)
        }
        try await CorePoll.releasing(race.bulk, .allExcept(onDemandHash), until: "the batch returned or waits for the adopt-on-demand of the last claimed file") {
            await race.settled(batch.finished)
        }
        let returnedEarly = await batch.finished.value
        let closing = LegacyRace.tracked {
            await race.harness.store.close()
        }
        try await CorePoll.until("the store is closing") {
            await race.harness.state.core.phase != .open
        }
        await race.releaseAll()
        // A resume that never comes (an adopt-on-demand that never ends its mark, the verifier's mutant M8) fails at the
        // time limit, and the run goes on, instead of awaiting a result for ever (L5K-R25, L5K-C4-12).
        try await CorePoll.until("close() and both calls ended") {
            await LegacyRace.ended(closing.finished, batch.finished, onDemand.finished)
        }
        let batchResult = await batch.task.result
        let onDemandResult = await onDemand.task.result
        let left = await race.harness.state.migration

        #expect(!returnedEarly, "premise: the batch waited for the adopt-on-demand")
        #expect(throws: StoreError.closed) {
            try batchResult.get()
        }
        #expect(throws: StoreError.closed) {
            try onDemandResult.get()
        }
        #expect(left.adopting.isEmpty && left.onDemand.isEmpty, "no adoption or adopt-on-demand mark is left")
    }
}

extension LegacyOnDemandRaceTests {
    @Test("R-STO-13: a migration batch whose publication is coalesced returns right after it instead of waiting for the adopt-on-demand of the last claimed legacy file, so its caller can schedule the trailing install; the next call waits for that adoption and finishes (L5K-R20)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func coalescedBatchReturnsBeforeItWaits() async throws {
        // ARCHITECTURE §5's interval; the clock never moves, so after open's install the window stays closed.
        let race = try await LegacyRace.open(installInterval: 0.1)
        await race.bulk.setHolding(true)
        // An adopt-on-demand takes the next file from the queue and its hash unit is held.
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id)
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let onDemandHash = Set(await race.bulk.heldUnits)
        // A batch adopts every other file and publishes them inside the install window.
        let first = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 64)
        }
        try await CorePoll.releasing(race.bulk, .allExcept(onDemandHash), until: "the batch returned or waits for the adopt-on-demand of the last claimed file") {
            await race.settled(first.finished)
        }
        let returned = await first.finished.value
        let installDue = await race.harness.state.core.snapshots.installDue
        let claimed = await race.harness.state.migration.claimed
        // A second call finds the queue empty and the one claimed file held by the adopt-on-demand: it waits for it.
        let second = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 64)
        }
        try await CorePoll.until("the second call returned or waits for the adopt-on-demand") {
            await race.settled(second.finished)
        }
        let secondWaited = await !second.finished.value
        await race.releaseAll()
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("the three calls ended") {
            await LegacyRace.ended(first.finished, second.finished, onDemand.finished)
        }
        let progress = try await first.task.value
        let finished = try await second.task.value
        _ = try await onDemand.task.value

        #expect(returned, "migrateLegacy waited for the adopt-on-demand after a coalesced publication: its caller could not schedule the trailing install meanwhile (L5K-C3-01)")
        #expect(installDue, "premise: the batch's publication left the trailing install due")
        #expect(claimed == [race.file], "premise: the adopt-on-demand held the one claimed file")
        #expect(!progress.finished && progress.remaining == 1 && progress.adopted > 0, "the first call returned with the adopt-on-demand's file left: \(progress)")
        #expect(secondWaited, "the next call, which published nothing, waits for the adoption rather than returning at once (L5K-R17)")
        #expect(finished.finished && finished.remaining == 0, "and finishes the migration once it ended: \(finished)")
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }

    @Test("R-STO-13: the last migration batch installs its adoptions at once, so phases 3 and 4 run in the same call without a trailing install left due behind them (L5K-R20)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func lastBatchInstallsBeforePhasesThreeAndFour() async throws {
        // ARCHITECTURE §5's interval; the clock never moves, so after open's install a bulk publication stays coalesced.
        let race = try await LegacyRace.open(installInterval: 0.1)
        let queue = await race.harness.state.migration.queue
        let ids = queue.flatMap(\.ids)
        let installsBefore = await race.harness.sink.offeredKeys.count
        let progress = try await race.harness.store.migrateLegacy(maxFiles: 64)
        let installDue = await race.harness.state.core.snapshots.installDue
        let installs = await race.harness.sink.offeredKeys.count - installsBefore
        let installed = await race.harness.sink.installed
        let unseen = ids.filter { installed.location(for: $0, extensions: []) == nil }

        #expect(!queue.isEmpty && queue.count <= 64, "premise: one batch takes every file: \(queue.count)")
        #expect(progress == LegacyMigrationProgress(adopted: queue.count, remaining: 0, dropped: 0, finished: true), "the same call ran phases 3 and 4: \(progress)")
        #expect(!installDue, "R-STO-13: the call ran phases 3 and 4 with its batch's trailing install still due, which only the caller's alarm could run once the call returned (L5K-C3-01)")
        #expect(unseen.isEmpty, "the readers' snapshot holds every adopted file when the call returns: \(unseen.count) missing")
        #expect(installs == 1, "one install, the last batch's: \(installs)")
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }
}

extension LegacyOnDemandRaceTests {
    @Test("R-STO-11: a migration batch whose install suspends while the adopt-on-demand of the last claimed legacy file ends reads what is left again after its publication, installs at once and finishes, never answering RE-S29's back-off signal with every file adopted (L5K-R23, KC4-STALELAST)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func batchRereadsWhatIsLeftAfterItsInstall() async throws {
        let readers = ScriptedSnapshotSink()
        let sink = HeldForwardingSink(inner: readers)
        // ARCHITECTURE §5's interval.
        let race = try await LegacyRace.open(installInterval: 0.1, sink: readers, sinkOverride: sink)
        let queue = await race.harness.state.migration.queue
        let ids = queue.flatMap(\.ids)
        await race.bulk.setHolding(true)
        // A bulk-lane adopt-on-demand (a prefetch job's pre-transfer read) takes the next file; its hash unit is held.
        let onDemand = LegacyRace.tracked {
            try await race.harness.store.adoptLegacyNow(race.id, urgency: .bulk)
        }
        try await race.bulk.requireHeldUnits(atLeast: 1)
        let onDemandHash = Set(await race.bulk.heldUnits)
        // The install window is open again when the batch publishes, so its publication installs at once and suspends at
        // the sink, which holds it.
        race.harness.time.advance(by: 1)
        await sink.setHolding(true)
        let batch = LegacyRace.tracked {
            try await race.harness.store.migrateLegacy(maxFiles: 64)
        }
        try await CorePoll.releasing(race.bulk, .allExcept(onDemandHash), until: "the batch's install is held at the sink, or the batch returned") {
            if await sink.heldCount > 0 {
                return true
            }
            return await batch.finished.value
        }
        let atHold = await race.harness.state.migration
        // The adopt-on-demand ends while that install is held: it unclaims the last file, so nothing is left, and publishes
        // inside the window the batch's install has just closed.
        await race.bulk.setHolding(false)
        // A resume that never comes fails at the time limit, and the run goes on, instead of awaiting a result for ever
        // (L5K-R27 (1); Stage 3 ruling S3C-5).
        try await CorePoll.until("the adopt-on-demand ended") {
            await onDemand.finished.value
        }
        let answer = try await onDemand.task.value
        let installDueMeanwhile = await race.harness.state.core.snapshots.installDue
        await sink.setHolding(false)
        try await CorePoll.until("the batch ended") {
            await batch.finished.value
        }
        let progress = try await batch.task.value
        let phase = await race.harness.state.migration.phase
        let installDue = await race.harness.state.core.snapshots.installDue
        let installed = await readers.installed
        let unseen = ids.filter { installed.location(for: $0, extensions: []) == nil }

        #expect(atHold.queue.isEmpty && atHold.claimed == [race.file], "premise: the batch published with only the adopt-on-demand's file claimed")
        #expect(answer != nil, "premise: the adopt-on-demand adopted its file")
        #expect(installDueMeanwhile, "premise: the adopt-on-demand's bulk publication left the trailing install due while the batch's install was held")
        #expect(progress.finished || progress.remaining > 0, "migrateLegacy answered `remaining == 0 && !finished`, RE-S29's back-off signal, with every file adopted (L5K-C4-00): \(progress)")
        #expect(progress == LegacyMigrationProgress(adopted: queue.count, remaining: 0, dropped: 0, finished: true), "the same call finished the migration: \(progress)")
        #expect(phase == .done, "phases 3 and 4 ran: \(phase)")
        #expect(!installDue, "R-STO-13: phases 3 and 4 ran with the adopt-on-demand's trailing install still due (L5K-R20)")
        #expect(unseen.isEmpty, "the readers' snapshot holds every adopted file when the call returns: \(unseen.count) missing")
        #expect(await CoreInvariants.violations(of: race.harness).isEmpty)
    }
}

extension LegacyOnDemandRaceTests {
    @Test("R-STO-13: an adopt-on-demand publishes at its urgency: bulk adoptions wait for the install window, a user-initiated one installs at once and carries them (L5K-R14)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func adoptionPublishesAtItsUrgency() async throws {
        // ARCHITECTURE §5's interval; the clock never moves, so after one install the window stays closed.
        let race = try await LegacyRace.open(installInterval: 0.1)
        let queue = await race.harness.state.migration.queue
        try #require(queue.count >= 4, "the fixture queues enough files")
        let bulkIDs = queue.suffix(3).compactMap(\.ids.first)
        let userID = try #require(queue.first?.ids.first)
        let before = await race.harness.sink.offeredKeys.count
        var bulkLocations: [AssetLocation?] = []
        for id in bulkIDs {
            bulkLocations.append(try await race.harness.store.adoptLegacyNow(id, urgency: .bulk))
        }
        let bulkInstalls = await race.harness.sink.offeredKeys.count - before
        let userLocation = try await race.harness.store.adoptLegacyNow(userID)
        let userInstalls = await race.harness.sink.offeredKeys.count - before - bulkInstalls
        let installed = await race.harness.sink.installed

        #expect(bulkLocations.allSatisfy { $0 != nil } && userLocation != nil, "every call adopted its file")
        #expect(bulkInstalls <= 1, "\(bulkInstalls) installs for three bulk adoptions: at most one per install window")
        #expect(userInstalls == 1, "the user-initiated adoption installed its snapshot before it returned")
        #expect((bulkIDs + [userID]).allSatisfy { installed.location(for: $0, extensions: []) != nil }, "that install carries the coalesced bulk adoptions too")
    }

    @Test("R-STO-13: a user-initiated adopt-on-demand of an asset a bulk adoption made present, so far in a coalesced snapshot only, installs it before it answers (L5K-R18)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func userInitiatedAskOfACoalescedAdoptionInstalls() async throws {
        // ARCHITECTURE §5's interval; the clock never moves, so after one install the window stays closed.
        let race = try await LegacyRace.open(installInterval: 0.1)
        let queue = await race.harness.state.migration.queue
        try #require(queue.count >= 2, "the fixture queues enough files")
        let opener = try #require(queue.last?.ids.first)
        let id = try #require(queue.first?.ids.first)
        // The first bulk adoption installs (the window was open) and closes the window; the second publishes inside it.
        _ = try await race.harness.store.adoptLegacyNow(opener, urgency: .bulk)
        let coalesced = try await race.harness.store.adoptLegacyNow(id, urgency: .bulk)
        let before = await race.harness.sink.installed.location(for: id, extensions: [])
        let installsBefore = await race.harness.sink.offeredKeys.count
        // What the engine's funnel does for a job promoted to the user-initiated lane during that adoption (L5K-R18).
        let answer = try await race.harness.store.adoptLegacyNow(id)
        let installs = await race.harness.sink.offeredKeys.count - installsBefore
        let after = await race.harness.sink.installed.location(for: id, extensions: [])

        #expect(coalesced != nil && answer == coalesced, "both calls answer the adopted asset's location")
        #expect(before == nil, "premise: the bulk adoption was in a coalesced snapshot only")
        #expect(installs == 1, "the user-initiated call installed the snapshot before it answered: \(installs) installs")
        #expect(after != nil, "R-STO-13: the readers' snapshot holds the asset when the user-initiated call returns")
    }
}

/// A store over a legacy tree, opened, with stepped executors that let every unit through until a test holds them, and
/// the next file a batch takes (the queue's last).
@available(macOS 15.0, iOS 18.0, *)
struct LegacyRace {
    let harness: CoreHarness
    let bulk: SteppedBlockingExecutor
    let metadata: SteppedBlockingExecutor
    /// The next legacy file a batch takes.
    let file: LegacyFile
    /// The first id of `file`.
    let id: AssetID
    /// `file`'s bytes.
    let bytes: Data

    /// Opens a store over `files` (the repository's `legacy-v0` fixture when `nil`) with the prior art's key set and the
    /// given snapshot install interval. The store installs into `sinkOverride` when one is given (a sink that holds
    /// installs, answering from `sink`, which stays the harness's readers' view), otherwise into `sink`.
    static func open(
        files: [String: Data]? = nil,
        installInterval: TimeInterval = 0,
        sink: ScriptedSnapshotSink = ScriptedSnapshotSink(),
        sinkOverride: (any SnapshotSink)? = nil
    ) async throws -> LegacyRace {
        let tree = try files ?? LegacyFixture.fixtureFiles()
        let bulk = SteppedBlockingExecutor(holding: false)
        let metadata = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(
            disk: try LegacyFixture.disk(tree),
            legacy: CleanupFixture.legacyPolicy,
            defaults: defaults,
            installInterval: installInterval,
            metadata: metadata,
            bulk: bulk,
            sink: sink,
            sinkOverride: sinkOverride
        )
        _ = try await harness.store.open()
        let file = try #require(await harness.state.migration.queue.last, "a legacy file is queued")
        let id = try #require(file.ids.first)
        let bytes = try #require(tree[file.components.joined(separator: "/")], "the fixture holds the file's bytes")
        return LegacyRace(harness: harness, bulk: bulk, metadata: metadata, file: file, id: id, bytes: bytes)
    }

    /// `file`'s place in the prior art's tree.
    var path: URL {
        CleanupFixture.legacyRoot.appendingPathComponent(self.file.components.joined(separator: "/"))
    }

    /// Runs `operation` in a task and records when it returned or threw.
    static func tracked<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> (task: Task<T, any Error>, finished: CleanupSteps.Finished) {
        let finished = CleanupSteps.Finished()
        let task = Task { () async throws -> T in
            do {
                let value = try await operation()
                await finished.set()
                return value
            } catch {
                await finished.set()
                throw error
            }
        }
        return (task, finished)
    }

    /// Whether every one of the tracked calls has returned or thrown.
    static func ended(_ calls: CleanupSteps.Finished...) async -> Bool {
        for call in calls {
            guard await call.value else {
                return false
            }
        }
        return true
    }

    /// Every later read of the file fails with `notFound`: what a reader finds once a placement renamed it into `blobs/`
    /// and before that placement's binding (the verifier's probe PS1b).
    func renamedAway() {
        self.harness.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(pathContains: self.path.path), occurrence: .every, error: .notFound))
    }

    /// Whether some call waits for another call's processing of the file (`MigrationState.adopting`, `onDemand`).
    func someoneWaits() async -> Bool {
        let migration = await self.harness.state.migration
        let joiningAdoption = !(migration.adopting[self.file.components]?.isEmpty ?? true)
        let joiningOnDemand = !(migration.onDemand[self.file.components]?.isEmpty ?? true)
        return joiningAdoption || joiningOnDemand
    }

    /// Whether the tracked call has returned or some call waits for another's processing of the file.
    func settled(_ finished: CleanupSteps.Finished) async -> Bool {
        if await finished.value {
            return true
        }
        return await self.someoneWaits()
    }

    /// Reads of the file in the prior art's tree so far, failed ones included (the fake volume's log).
    func reads() -> Int {
        self.harness.fileSystem.operations.filter { $0.kind == .read && $0.url.standardizedFileURL.path == self.path.path }.count
    }

    /// Waits until the file's key is in `publishing` and the metadata executor holds a unit, releasing meanwhile every
    /// bulk unit outside `keepingBulk`, and returns the held metadata units: the placement's. A store over the fixture runs
    /// no other metadata unit here (commits run only when an operation requires one).
    func holdPlacement(keepingBulk: Set<Int> = []) async throws -> Set<Int> {
        // The bulk units are read before the check (S3C-1).
        try await CorePoll.releasing(self.bulk, .allExcept(keepingBulk), until: "the file's placement unit is held") {
            let placing = await self.harness.state.core.publishing.contains { $0.hash == self.file.digest }
            let held = await self.metadata.heldUnits
            return placing && !held.isEmpty
        }
        return Set(await self.metadata.heldUnits)
    }

    /// Stops holding either executor and releases every held unit.
    func releaseAll() async {
        await self.bulk.setHolding(false)
        await self.metadata.setHolding(false)
    }
}

/// A snapshot sink that holds installs while `holding` (at the await of REENTRANCY R6) and answers each, once released,
/// from `inner`, which stays the readers' view (`inner.installed`): a test suspends a publication at its install, lets
/// other calls run meanwhile, then reads what the readers see. `heldCount` lets a cancellation-aware poll wait for a held
/// install (`CorePoll.until`).
actor HeldForwardingSink: SnapshotSink {
    private let inner: ScriptedSnapshotSink
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(inner: ScriptedSnapshotSink) {
        self.inner = inner
    }

    /// The installs held now.
    var heldCount: Int {
        self.held.count
    }

    /// Starts or stops holding; stopping releases every held install in arrival order.
    func setHolding(_ holding: Bool) {
        self.holding = holding
        guard !holding else {
            return
        }
        let released = self.held
        self.held = []
        for continuation in released {
            continuation.resume()
        }
    }

    func install(_ snapshot: AssetSnapshot) async -> InstallAck {
        if self.holding {
            // REENTRANCY: test sink — nothing: the install below answers from the inner sink's state at release.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.held.append(continuation)
            }
        }
        // REENTRANCY: test sink — nothing is read afterwards.
        return await self.inner.install(snapshot)
    }
}
