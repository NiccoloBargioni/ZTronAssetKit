import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// `apply` yields between chunks (C2), so it must never be persisted half-applied: a commit or an adoption report
/// asked for while its writes run waits for all of them, and `close()` waits before its durable commit (review round
/// 2, probes 2 and 4; ADR draft B-23). Also the re-validation of proposed REENTRANCY rows b-6 and b-7.
@Suite("Core: apply's commit fence (H-5)")
struct StoreApplyFenceTests {
    /// Two manifests over the same ids with different content, large enough for many sweep chunks.
    static func manifests() -> (old: [ManifestEntry], new: [ManifestEntry]) {
        let count = AssetStore.sweepChunk * 12
        let old = (0..<count).map { CoreFixture.entry("e\($0)", CoreFixture.bytes(UInt64(10_000 + $0), count: 16)) }
        let new = (0..<count).map { CoreFixture.entry("e\($0)", CoreFixture.bytes(UInt64(50_000 + $0), count: 16)) }
        return (old, new)
    }

    /// The ids of `entries` whose reloaded record or applied-manifest entry does not carry the entry's content.
    static func stale(_ entries: [ManifestEntry], in state: StoreState) -> (records: Int, manifest: Int) {
        var applied: [AssetID: ContentHash?] = [:]
        for entry in state.core.appliedManifest.entries {
            applied[entry.identifier] = entry.checksum
        }
        let records = entries.filter { state.core.records[$0.identifier]?.entry.checksum != $0.checksum }.count
        let manifest = entries.filter { applied[$0.identifier] != .some($0.checksum) }.count
        return (records, manifest)
    }

    @Test("R-NET-5: a commit asked for while apply writes its chunks waits for the whole apply, so a crash never pairs the new ETag with old records", .timeLimit(.minutes(2)))
    @available(macOS 15.0, *)
    func commitWaitsForTheWholeApply() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(commitInterval: 1), bulk: bulk)
        let (old, new) = StoreApplyFenceTests.manifests()
        let etagOne = try #require(ETag(rawValue: "\"one\""))
        let etagTwo = try #require(ETag(rawValue: "\"two\""))
        _ = try await harness.store.open()
        harness.time.advance(by: 1)
        _ = try await harness.store.apply(CoreFixture.manifest(old, etagSeed: "1"), etag: etagOne, eviction: nil)
        // A mutation whose commit waits for the coalescing window (the store's own sleep, proposed row b-2).
        let synced = Task {
            try await harness.store.markSyncDue()
        }
        try await harness.time.requireSleepers(atLeast: 1)
        // apply's plan unit is held, then released; its first chunk is written once `etag` changed.
        await bulk.setHolding(true)
        let applying = Task {
            try await harness.store.apply(CoreFixture.manifest(new, etagSeed: "2"), etag: etagTwo, eviction: nil)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        await bulk.setHolding(false)
        try await CorePoll.until("apply's first chunk (ETag two)") {
            await harness.state.core.etag == etagTwo
        }
        // The window opens while the chunks are written: the woken commit must capture none of them half done.
        harness.time.advance(by: 1)
        try await synced.value
        // A crash now keeps what covered `markSyncDue` (apply's own commit may wait for the next window).
        let disk = harness.fileSystem.survivingDisk()
        harness.time.advance(by: 1)
        _ = try await applying.value

        let reopened = CoreHarness.make(disk: disk)
        _ = try await reopened.store.open()
        let state = await reopened.state
        let stale = StoreApplyFenceTests.stale(new, in: state)
        #expect(state.core.etag == etagTwo)
        #expect(stale.records == 0 && stale.manifest == 0, "ETag two with \(stale.records) records and \(stale.manifest) entries of manifest one")
        #expect(state.core.records.count == new.count)
        #expect(state.core.syncDue)
    }

    @Test("R-NET-5: close while apply writes its chunks waits for the whole apply before its durable commit", .timeLimit(.minutes(2)))
    @available(macOS 15.0, *)
    func closeWaitsForTheWholeApply() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata, bulk: bulk)
        let (old, new) = StoreApplyFenceTests.manifests()
        let etagOne = try #require(ETag(rawValue: "\"one\""))
        let etagTwo = try #require(ETag(rawValue: "\"two\""))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(old, etagSeed: "1"), etag: etagOne, eviction: nil)
        await metadata.setHolding(true)
        let synced = Task {
            try await harness.store.markSyncDue()
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        await bulk.setHolding(true)
        let applying = Task {
            try await harness.store.apply(CoreFixture.manifest(new, etagSeed: "2"), etag: etagTwo, eviction: nil)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        await bulk.setHolding(false)
        try await CorePoll.until("apply's first chunk (ETag two)") {
            await harness.state.core.etag == etagTwo
        }
        // close() drains the held commit, then must not commit until apply's writes are complete.
        let closing = Task {
            await harness.store.close()
        }
        await metadata.setHolding(false)
        await closing.value
        _ = await synced.result
        let applied = await applying.result
        if case .failure(let error) = applied {
            #expect(error as? StoreError == .closed, "apply ends with its writes complete, or with closed")
        }

        let reopened = CoreHarness.make(disk: harness.fileSystem.survivingDisk())
        _ = try await reopened.store.open()
        let state = await reopened.state
        let stale = StoreApplyFenceTests.stale(new, in: state)
        #expect(state.core.etag == etagTwo)
        #expect(stale.records == 0 && stale.manifest == 0, "ETag two with \(stale.records) records and \(stale.manifest) entries of manifest one")
    }

    @Test("R-NET-5: while apply's writes are fenced no commit, adoption report or close captures the state, and each resumes once the fence drops", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func fencedCallersWaitAndResume() async throws {
        let harness = CoreHarness.make()
        let a = CoreFixture.entry("a", CoreFixture.bytes(310))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a]), etag: nil, eviction: nil)
        let commits = await harness.state.core.metrics.commits
        // The fence held at a known point (a real `apply` passes through it between two yields).
        await harness.store.testRaiseApplyFence()
        let synced = Task {
            try await harness.store.markSyncDue()
        }
        try await StoreApplyFenceTests.waitForFenceWaiters(harness, atLeast: 1)
        let adoption = Task {
            try await harness.store.adoptionReport()
        }
        try await StoreApplyFenceTests.waitForFenceWaiters(harness, atLeast: 2)
        // The engine's alarm finds no commit to make while the fence is up, and is given no commit deadline.
        let work = await harness.store.runDueWork()
        #expect(!work.committed)
        #expect(await harness.store.nextDeadline() == nil)
        #expect(await harness.state.core.metrics.commits == commits)
        #expect(await harness.state.core.syncDue, "the mutation was made; only its commit waits")
        await harness.store.endApplyWrites()
        try await synced.value
        let report = try await adoption.value
        #expect(report.manifestRemotePaths == [a.remotePath])
        #expect(await harness.state.core.metrics.commits > commits)
        #expect(await harness.state.core.applyGate.writeWaiters.isEmpty)

        // close() drains, then waits for the fence before its durable commit.
        await harness.store.markDirty(.lazy)
        let beforeClose = await harness.state.core.metrics.commits
        await harness.store.testRaiseApplyFence()
        let closing = Task {
            await harness.store.close()
        }
        try await StoreApplyFenceTests.waitForFenceWaiters(harness, atLeast: 1)
        #expect(await harness.state.core.phase == .closing)
        #expect(await harness.state.core.metrics.commits == beforeClose, "no durable commit while the fence is up")
        await harness.store.endApplyWrites()
        await closing.value
        #expect(await harness.state.core.phase == .closed)
        #expect(await harness.state.core.metrics.commits == beforeClose + 1)
    }

    /// Waits until `count` callers are parked on the commit fence (no sleeping: the actor is polled between yields).
    @available(macOS 15.0, *)
    static func waitForFenceWaiters(_ harness: CoreHarness, atLeast count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await CorePoll.until("\(count) callers parked on the commit fence", sourceLocation: sourceLocation) {
            await harness.state.core.applyGate.writeWaiters.count >= count
        }
    }

    @Test("R-SYN-8: apply's writes re-read records changed during its plan unit, and adoption re-validates every planned candidate", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func writesRevalidateAfterThePlanUnit() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(bulk: bulk)
        let bytesA = CoreFixture.bytes(300)
        let bytesC = CoreFixture.bytes(302)
        let keyA = CoreFixture.key(bytesA)
        let keyC = CoreFixture.key(bytesC)
        let a = CoreFixture.entry("a", bytesA)
        let c = CoreFixture.entry("c", bytesC)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, c]), etag: nil, eviction: nil)
        try await harness.publish(bytesA, [a], sequence: 1)
        try await harness.publish(bytesC, [c], sequence: 2)
        // The next manifest changes a's content and adds b (a's bytes) and d (c's bytes): the plan, made against the
        // state captured before its unit, lists a, b and d as adoption candidates.
        let changedA = CoreFixture.entry("a", CoreFixture.bytes(301))
        let b = CoreFixture.entry("b", bytesA)
        let d = CoreFixture.entry("d", bytesC)
        await bulk.setHolding(true)
        let applying = Task {
            try await harness.store.apply(CoreFixture.manifest([changedA, b, c, d]), etag: nil, eviction: nil)
        }
        try await bulk.requireHeldUnits(atLeast: 1)  // the plan unit
        // Meanwhile c's bytes are purged (never re-adopted) and a is evicted (its key doomed `unreferenced`).
        await harness.store.setResidency(.absent(.purged), of: c.identifier, dooming: .purged)
        await harness.store.setResidency(.absent(.evicted), of: a.identifier, dooming: .unreferenced)
        await bulk.setHolding(false)
        let report = try await applying.value
        #expect(report.contentChanged == [a.identifier])
        #expect(report.added == [b.identifier, d.identifier])
        #expect(report.reused == [b.identifier], "d's planned candidate was purged meanwhile")
        let records = await harness.state.core.records
        #expect(records[a.identifier]?.residency == .absent(.evicted), "the content change re-read a's record")
        #expect(records[a.identifier]?.entry == changedA)
        #expect(records[b.identifier]?.referencedBlob == keyA, "b rescues a's evicted bytes")
        #expect(records[d.identifier]?.residency == .absent(.neverFetched))
        #expect(await harness.state.core.blobTable[keyA] == .live(references: 1))
        guard case .doomed(let info)? = await harness.state.core.blobTable[keyC] else {
            Issue.record("c's purged key is no longer doomed")
            return
        }
        #expect(info.reason == .purged)
        #expect(await harness.sink.installed.location(for: b.identifier, extensions: [])?.url == harness.layout.blobURL(keyA))
        #expect(await harness.sink.installed.location(for: d.identifier, extensions: []) == nil)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}

extension AssetStore {
    /// Raises `apply`'s commit fence as `apply` does before its first write (test seam: holds the fence at a known
    /// point; `endApplyWrites()` lowers it as `apply` does after its last write).
    func testRaiseApplyFence() {
        self.state.core.applyGate.writing = true
    }
}
