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
        try await CorePoll.until("the adopt-on-demand answered or waits for the batch's adoption") {
            for unit in await race.metadata.heldUnits where !placement.contains(unit) {
                await race.metadata.release(unit)
            }
            return await race.settled(onDemand.finished)
        }
        let answeredEarly = await onDemand.finished.value
        let readsWhileWaiting = race.reads() - readsBefore
        await race.releaseAll()
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
        try await CorePoll.until("the batch decided or waits for the adopt-on-demand's adoption") {
            for unit in await race.metadata.heldUnits where !placement.contains(unit) {
                await race.metadata.release(unit)
            }
            return await race.settled(batch.finished)
        }
        let batchDecidedEarly = await batch.finished.value
        await race.releaseAll()
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
        try await CorePoll.until("the second adopt-on-demand answered or waits for the first") {
            for unit in await race.metadata.heldUnits where !placement.contains(unit) {
                await race.metadata.release(unit)
            }
            return await race.settled(second.finished)
        }
        let secondAnsweredEarly = await second.finished.value
        let readsBySecond = race.reads() - readsBefore
        await race.releaseAll()
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
        try await CorePoll.until("the adopt-on-demand answered or waits for the batch's adoption") {
            for unit in await race.metadata.heldUnits where !placement.contains(unit) {
                await race.metadata.release(unit)
            }
            return await race.settled(onDemand.finished)
        }
        let answeredEarly = await onDemand.finished.value
        // close() begins while the batch's placement unit is held; its drain then lets that unit finish.
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

    /// Opens a store over `files` (the repository's `legacy-v0` fixture when `nil`) with the prior art's key set.
    static func open(files: [String: Data]? = nil) async throws -> LegacyRace {
        let tree = try files ?? LegacyFixture.fixtureFiles()
        let bulk = SteppedBlockingExecutor(holding: false)
        let metadata = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let harness = CoreHarness.cleanup(disk: try LegacyFixture.disk(tree), legacy: CleanupFixture.legacyPolicy, defaults: defaults, metadata: metadata, bulk: bulk)
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
        try await CorePoll.until("the file's placement unit is held") {
            for unit in await self.bulk.heldUnits where !keepingBulk.contains(unit) {
                await self.bulk.release(unit)
            }
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
