import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Interleavings and failure paths of the store core (H-5 rows R1, R3, R4, R5, R7 and their edges).
@Suite("Core: interleavings and failure paths")
struct StoreEdgeTests {
    @Test("R-INT-2: a manifest change while a publication claims or hashes its file yields superseded and deletes the claim", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func supersededAfterClaimOrHash() async throws {
        for heldExecutor in ["metadata", "bulk"] {
            let stepped = SteppedBlockingExecutor(holding: false)
            let harness = heldExecutor == "metadata" ? CoreHarness.make(metadata: stepped) : CoreHarness.make(bulk: stepped)
            let bytes = CoreFixture.bytes(190)
            let entry = CoreFixture.entry("a", bytes)
            _ = try await harness.store.open()
            _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
            let staged = try await harness.stage(bytes, for: entry, sidecar: true)
            await stepped.setHolding(true)
            let publishing = Task {
                try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
            }
            // The claim (metadata) or the first hash unit (bulk) is held; the manifest changes meanwhile.
            try await stepped.requireHeldUnits(atLeast: 1)
            let changing = Task {
                try await harness.store.admit(CoreFixture.entry("a", CoreFixture.bytes(191)))
            }
            if heldExecutor == "metadata" {
                try await stepped.requireHeldUnits(atLeast: 2)  // the admission's commit, queued behind the claim
                await stepped.release(await stepped.heldUnits[1])
            }
            _ = try await changing.value
            await stepped.setHolding(false)
            await #expect(throws: StoreError.superseded(entry.identifier), "\(heldExecutor)") {
                try await publishing.value
            }
            for kind in [StagingFileName.Kind.partial, .verifying, .sidecar] {
                #expect(!harness.exists(harness.layout.stagingURL(staged.name.with(kind: kind))), "\(heldExecutor): \(kind)")
            }
            #expect(await harness.state.core.blobTable.isEmpty, "\(heldExecutor)")
        }
    }

    @Test("R-INT-2: bytes added to a claimed file while it is hashed are a size mismatch, never published", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func claimedFileGrowsDuringHash() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(hashChunkBytes: 100), bulk: bulk)
        let bytes = CoreFixture.bytes(192, count: 250)
        let entry = CoreFixture.entry("a", bytes, size: false)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry)
        await bulk.setHolding(true)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        try harness.fileSystem.write(Data(repeating: 1, count: 50), to: harness.layout.stagingURL(staged.name.with(kind: .verifying)), mode: .append)
        await bulk.setHolding(false)
        await #expect(throws: StoreError.integrity(.sizeMismatch(expected: 250, actual: 300))) {
            try await publishing.value
        }
        #expect(await harness.store.metrics().integrityFailures == 1)
    }

    @Test("R-CLN-5: a publication of a key whose deletion unit is in flight waits for it, then places the file afresh", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func publicationWaitsForDeletion() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata)
        let bytes = CoreFixture.bytes(193)
        let a = CoreFixture.entry("a", bytes)
        let b = CoreFixture.entry("b", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a])
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        harness.time.advance(by: 10)
        await metadata.setHolding(true)
        let reaping = Task {
            await harness.store.runDueWork()
        }
        try await metadata.requireHeldUnits(atLeast: 1)  // the deletion unit of the key
        await harness.store.testInsertRecord(b)
        let staged = try await harness.stage(bytes, for: b, sequence: 2)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [b.identifier], expecting: b.contentIdentity, urgency: .bulk)
        }
        try await metadata.requireHeldUnits(atLeast: 2)  // the publication's claim
        let held = await metadata.heldUnits
        await metadata.release(held[1])
        await metadata.release(held[0])
        await metadata.setHolding(false)
        #expect(await reaping.value.reapedKeys == 1)
        let location = try #require(try await publishing.value[b.identifier])
        #expect(harness.content(location.url) == bytes, "placed again after the unlink")
        #expect(await harness.state.core.blobTable[CoreFixture.key(bytes)] == .live(references: 1))
    }

    @Test("R-CLN-5: a rescued publication is committed before it returns", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func rescueIsCommitted() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(194)
        let a = CoreFixture.entry("a", bytes)
        let b = CoreFixture.entry("b", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a])
        // `b` arrives by point admission after `a`'s prune doomed the blob; it is not adopted there (the test
        // publishes first), so the publication rescues the doomed key.
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        await harness.store.testInsertRecord(b)
        try await harness.publish(bytes, [b], sequence: 2)
        let commits = await harness.state.core.commits
        #expect(commits.committedSerial == commits.mutationSerial)
        #expect(await harness.state.core.blobTable[CoreFixture.key(bytes)] == .live(references: 1))
        let onDisk = try IndexCodec.decode([UInt8](try #require(harness.content(harness.layout.indexURL(.current))))).get()
        #expect(onDisk.doomed.isEmpty && onDisk.records[b.identifier]?.referencedBlob == CoreFixture.key(bytes))
    }

    @Test("R-CLN-5: a key is never unlinked before the generation that dropped it is committed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func uncommittedDropBlocksDeletion() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(195)
        let a = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a])
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        await #expect(throws: StoreError.fileSystem(.noSpace)) {
            try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        }
        await harness.store.publishSnapshot(urgency: .userInitiated)
        harness.time.advance(by: 3_600)
        let work = await harness.store.runDueWork()
        #expect(work.reapedKeys == 0 && !work.committed)
        #expect(harness.exists(harness.layout.blobURL(CoreFixture.key(bytes))))
        #expect(await harness.store.deletionBlocker(CoreFixture.key(bytes)) == .commit)
    }

    // The interleavings of `open()` and `close()` (close-out cycle 4): each scenario on its own harness, so none depends
    // on the order in which the scheduler resumes the callers parked on a running open. Before, one test parked a second
    // open and a close on the same open and assumed the second open would reach the store first; it failed when the
    // close did (`Caught error: .closed`, under load).

    @Test("R-STO-9: open runs once for concurrent callers: a call made while an open runs returns that open's report", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func concurrentOpensShareOneReport() async throws {
        let metadata = SteppedBlockingExecutor(holding: true)
        let harness = CoreHarness.make(metadata: metadata)
        let first = Task {
            try await harness.store.open()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let second = Task {
            try await harness.store.open()
        }
        try await StoreEdgeTests.waitForOpenWaiters(opens: 1, others: 0, harness)
        await metadata.setHolding(false)
        let report = try await first.value
        #expect(try await second.value == report)
        #expect(try await harness.store.open() == report, "a call after the open returns the same report")
        #expect(await harness.state.core.phase == .open)
        #expect(harness.fileSystem.operations.filter { $0.kind == .acquireExclusiveLock }.count == 1, "one open ran")
        await harness.store.close()
    }

    @Test("R-STO-9: close() during a running open waits for it, then flushes and releases the lock", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func closeWaitsForARunningOpen() async throws {
        let metadata = SteppedBlockingExecutor(holding: true)
        let harness = CoreHarness.make(metadata: metadata)
        let first = Task {
            try await harness.store.open()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let closing = Task {
            await harness.store.close()
        }
        try await StoreEdgeTests.waitForOpenWaiters(opens: 0, others: 1, harness)
        #expect(await harness.state.core.phase == .opening, "close parked without cutting the open short")
        await metadata.setHolding(false)
        await closing.value
        // `openReport` is set only by a successful open: close returned after the open it waited for had finished.
        let finished = try #require(await harness.state.core.openReport)
        #expect(try await first.value == finished)
        #expect(await harness.state.core.phase == .closed)
        await #expect(throws: StoreError.closed) {
            try await harness.store.open()
        }
        // The lock is released: a new store over the same volume opens the root.
        let next = CoreHarness.make(fileSystem: harness.fileSystem, configuration: CoreFixture.configuration(), time: harness.time)
        let reopened = try await next.store.open()
        #expect(reopened.generation > finished.generation, "the next launch commits past the closed store's generation")
        await next.store.close()
    }

    @Test("R-STO-9: an open() parked beside a close() on a running open returns that open's report, whichever resumes first", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func parkedOpenAndCloseOnARunningOpen() async throws {
        let metadata = SteppedBlockingExecutor(holding: true)
        let harness = CoreHarness.make(metadata: metadata)
        let first = Task {
            try await harness.store.open()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        // Started together: the store resumes both when the open finishes, in no order the test controls. The running
        // open hands the parked call its report, so a close that reaches the store first cannot turn it into `.closed`
        // (ADR draft B-35).
        let second = Task {
            try await harness.store.open()
        }
        let closing = Task {
            await harness.store.close()
        }
        try await StoreEdgeTests.waitForOpenWaiters(opens: 1, others: 1, harness)
        await metadata.setHolding(false)
        let report = try await first.value
        #expect(try await second.value == report)
        await closing.value
        #expect(await harness.state.core.phase == .closed)
        await #expect(throws: StoreError.closed) {
            try await harness.store.open()
        }
    }

    @Test("R-STO-9: an open() parked on an open that fails throws notOpen, and a later call opens", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func parkedOpenOnAFailedOpen() async throws {
        let metadata = SteppedBlockingExecutor(holding: true)
        let harness = CoreHarness.make(metadata: metadata)
        // Another holder has the lock, once.
        harness.fileSystem.addFault(FaultRule(operation: .acquireExclusiveLock, occurrence: .nth(1), error: .wouldBlock))
        let first = Task {
            try await harness.store.open()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let second = Task {
            try await harness.store.open()
        }
        try await StoreEdgeTests.waitForOpenWaiters(opens: 1, others: 0, harness)
        await metadata.setHolding(false)
        await #expect(throws: StoreError.locked) {
            try await first.value
        }
        await #expect(throws: StoreError.notOpen) {
            try await second.value
        }
        #expect(await harness.state.core.phase == .created)
        let report = try await harness.store.open()
        #expect(try await harness.store.open() == report)
        await harness.store.close()
    }

    @Test("R-STO-9: close() drains an in-flight publication, which unwinds with closed, and the next launch adopts its blob", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func closeDrainsAnInFlightPublication() async throws {
        // A publication whose placement unit is in flight when close begins: close drains it, the publication
        // unwinds with `.closed`, and the blob it placed is adopted by the next launch.
        let draining = SteppedBlockingExecutor(holding: false)
        let next = CoreHarness.make(metadata: draining)
        let bytes = CoreFixture.bytes(196)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await next.store.open()
        _ = try await next.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await next.stage(bytes, for: entry)
        await draining.setHolding(true)
        let publishing = Task {
            try await next.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        }
        try await draining.requireHeldUnits(atLeast: 1)
        await draining.releaseNext()  // the claim
        try await draining.requireHeldUnits(atLeast: 1)  // the placement
        let closingNext = Task {
            await next.store.close()
        }
        await draining.setHolding(false)
        await closingNext.value
        await #expect(throws: StoreError.closed) {
            try await publishing.value
        }
        let reopened = CoreHarness.make(disk: next.fileSystem.survivingDisk())
        _ = try await reopened.store.open()
        #expect(await reopened.store.location(for: entry.identifier, extensions: [], recordingAccess: false) != nil)
    }

    @Test("R-STO-4: callers that need a commit while one runs share the next one, and a cancelled wait for the window throws cancelled", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func commitWaitersAndCancellation() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata)
        _ = try await harness.store.open()
        let commitsBefore = await harness.store.metrics().commits
        await metadata.setHolding(true)
        let first = Task {
            try await harness.store.markSyncDue()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let second = Task {
            try await harness.store.flush(.ordered)
        }
        // The flush is parked on the running commit before it is released.
        try await StoreRaceTests.waitForCommitWaiter(harness)
        await metadata.setHolding(false)
        try await first.value
        try await second.value
        let commits = await harness.state.core.commits
        #expect(commits.committedSerial == commits.mutationSerial)
        #expect(await harness.store.metrics().commits == commitsBefore + 1, "the flush shared the held commit and ran none of its own")

        let windowed = CoreHarness.make(configuration: CoreFixture.configuration(commitInterval: 0.25))
        _ = try await windowed.store.open()
        let waiting = Task {
            try await windowed.store.markSyncDue()
        }
        try await windowed.time.requireSleepers(atLeast: 1)
        waiting.cancel()
        await #expect(throws: StoreError.cancelled) {
            try await waiting.value
        }
        #expect(windowed.time.pendingSleepers == 0)
    }

    @Test("R-STO-1: stagingInventory lists our names with their metadata and everything else as foreign", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func stagingInventory() async throws {
        let harness = CoreHarness.make()
        _ = try await harness.store.open()
        let entry = CoreFixture.entry("a", CoreFixture.bytes(197))
        let staged = try await harness.stage(CoreFixture.bytes(197), for: entry, sidecar: true)
        try harness.fileSystem.write(Data([1]), to: harness.layout.stagingDirectory.appendingPathComponent("garbage.tmp"), mode: .truncate)
        try harness.fileSystem.createDirectory(at: harness.layout.stagingURL(staged.name.with(kind: .partialTemporary)))
        let inventory = try await harness.store.stagingInventory()
        #expect(Set(inventory.items.keys) == [staged.name, staged.name.with(kind: .sidecar)])
        #expect(inventory.items[staged.name]?.byteSize == 300)
        #expect(inventory.foreign == ["garbage.tmp", staged.name.with(kind: .partialTemporary).rawValue].sorted())
        harness.fileSystem.addFault(FaultRule(operation: .contentsOfDirectory, matching: URLMatcher(lastComponentSuffix: "staging"), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await harness.store.stagingInventory()
        }
    }

    @Test("R-STO-6: a sync falls back to fsync only where fcntl is unsupported, and the search paths are the user domain's")
    func syncDecisionAndSearchPaths() throws {
        try LiveFileSystem.finishSync(fcntlResult: 0, fcntlErrno: 0) {
            Issue.record("no fallback after a successful fcntl")
            return (0, 0)
        }
        try LiveFileSystem.finishSync(fcntlResult: -1, fcntlErrno: ENOTSUP) {
            (0, 0)
        }
        #expect(throws: FileSystemError.io) {
            try LiveFileSystem.finishSync(fcntlResult: -1, fcntlErrno: EINVAL) {
                (-1, EIO)
            }
        }
        #expect(throws: FileSystemError.io) {
            try LiveFileSystem.finishSync(fcntlResult: -1, fcntlErrno: EIO) {
                Issue.record("EIO is never masked by a fallback")
                return (0, 0)
            }
        }
        #expect(LiveFileSystem.searchPath(.applicationSupport) == .applicationSupportDirectory)
        #expect(LiveFileSystem.searchPath(.caches) == .cachesDirectory)
    }
}

extension AssetStore {
    /// Inserts an absent record and appends it to the applied manifest without adoption (test seam: the state a
    /// publication finds when it races an admission).
    func testInsertRecord(_ entry: ManifestEntry) {
        self.state.core.records[entry.identifier] = AssetRecord(
            entry: entry,
            residency: .absent(.neverFetched),
            expectedBlob: entry.checksum,
            lastAccess: self.environment.time.now()
        )
        if let manifest = try? ValidatedManifest(entries: self.state.core.appliedManifest.entries + [entry], digest: self.state.core.appliedManifest.digest) {
            self.state.core.appliedManifest = manifest
        }
        self.markDirty(.soon)
    }
}

extension StoreEdgeTests {
    /// Waits until `opens` further `open()` calls and `others` other callers (a `close()`, an async API) are parked on a
    /// running `open()` (polled between yields; no sleeping; ends with the test), then requires that the `open()` calls
    /// wait for the running open's report and the others for its phase (ADR draft B-35). Waiting for the total first
    /// makes a misplaced caller fail at once instead of at the time limit.
    @available(macOS 15.0, *)
    static func waitForOpenWaiters(opens: Int, others: Int, _ harness: CoreHarness, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await CorePoll.until("\(opens) open() calls and \(others) other callers parked on the running open()", sourceLocation: sourceLocation) {
            let core = await harness.state.core
            return core.openReportWaiters.count + core.openWaiters.count >= opens + others
        }
        let core = await harness.state.core
        try #require(
            core.openReportWaiters.count >= opens && core.openWaiters.count >= others,
            "\(core.openReportWaiters.count) callers wait for the running open's report (\(opens) expected) and \(core.openWaiters.count) for its phase (\(others) expected)",
            sourceLocation: sourceLocation
        )
    }
}
