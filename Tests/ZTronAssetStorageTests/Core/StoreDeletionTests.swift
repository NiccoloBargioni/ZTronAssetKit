import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

@Suite("Core: deletion protocol (I-3) and deadlines")
struct StoreDeletionTests {
    /// Opens a store with `a` and `b` published, then prunes `a`: its blob is doomed.
    @available(macOS 15.0, iOS 18.0, *)
    static func prunedStore(sink: ScriptedSnapshotSink = ScriptedSnapshotSink()) async throws -> (CoreHarness, BlobKey, BlobKey) {
        let harness = CoreHarness.make(sink: sink)
        let a = CoreFixture.bytes(70)
        let b = CoreFixture.bytes(71)
        let entryA = CoreFixture.entry("a", a)
        let entryB = CoreFixture.entry("b", b)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entryA, entryB]), etag: nil, eviction: nil)
        try await harness.publish(a, [entryA], sequence: 1)
        try await harness.publish(b, [entryB], sequence: 2)
        return (harness, CoreFixture.key(a), CoreFixture.key(b))
    }

    @Test("R-CLN-1: prune removes blobs of removed entries only after acknowledgement and grace", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func pruneWaitsForAcknowledgementAndGrace() async throws {
        let (harness, keyA, keyB) = try await StoreDeletionTests.prunedStore()
        let report = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        let committedBy = harness.fileSystem.operations.count
        #expect(report.pruned == ["a"])
        guard case .doomed(let info)? = await harness.state.core.blobTable[keyA] else {
            Issue.record("the pruned blob is not doomed")
            return
        }
        #expect(info.reason == .unreferenced && info.eligibleAt != nil && info.droppedInGeneration <= report.generation)
        #expect(await harness.store.runDueWork().reapedKeys == 0)
        harness.time.advance(by: 5)
        let early = await harness.store.runDueWork()
        #expect(early.reapedKeys == 0 && harness.exists(harness.layout.blobURL(keyA)))
        #expect(early.nextDeadline == harness.time.monotonicNow().adding(seconds: 5))
        harness.time.advance(by: 5)
        let installs = await harness.sink.offeredKeys.count
        let due = await harness.store.runDueWork()
        #expect(due.installedSnapshot && due.reapedKeys == 1 && due.reapedBytes == 300)
        #expect(await harness.sink.offeredKeys.count == installs + 1, "a fresh install proved the main actor ran after the grace")
        #expect(!harness.exists(harness.layout.blobURL(keyA)) && harness.exists(harness.layout.blobURL(keyB)))
        let removal = try #require(harness.fileSystem.operations.firstIndex { $0.kind == .removeItem && $0.url == harness.layout.blobURL(keyA) })
        #expect(removal >= committedBy, "the generation that dropped the key was committed before the unlink")
        #expect(await harness.state.core.blobTable[keyA] == nil)
        #expect(due.nextDeadline == nil)
    }

    @Test("R-CLN-5: a sink that keeps an older or foreign snapshot never counts as acknowledgement", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func olderOrForeignSnapshotsNeverCount() async throws {
        let sink = ScriptedSnapshotSink()
        let (harness, keyA, _) = try await StoreDeletionTests.prunedStore(sink: sink)
        let epoch = await harness.state.core.launchEpoch
        for behaviour in [SnapshotSinkBehaviour.ignore, .report(SnapshotKey(epoch: epoch + 1, version: 999)), .report(SnapshotKey(epoch: epoch - 1, version: 999))] {
            let fresh = try await StoreDeletionTests.prunedStore(sink: ScriptedSnapshotSink())
            await fresh.0.sink.setBehaviour(behaviour)
            _ = try await fresh.0.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
            fresh.0.time.advance(by: 3_600)
            let work = await fresh.0.store.runDueWork()
            #expect(work.reapedKeys == 0 && fresh.0.exists(fresh.0.layout.blobURL(fresh.1)), "\(behaviour)")
            #expect(await fresh.0.store.nextDeadline() == nil, "an acknowledgement-blocked key keeps no deadline (\(behaviour))")
            #expect(await fresh.0.state.core.blobTable[fresh.1].map { if case .doomed(let info) = $0 { info.eligibleAt == nil } else { false } } == true)
        }
        // Once the sink acknowledges again, the grace starts and the blob goes.
        await sink.setBehaviour(.ignore)
        _ = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        harness.time.advance(by: 60)
        #expect(await harness.store.runDueWork().reapedKeys == 0)
        await sink.setBehaviour(.acknowledge)
        try await harness.store.flushAndInstall()
        harness.time.advance(by: 10)
        #expect(await harness.store.runDueWork().reapedKeys == 1)
        #expect(!harness.exists(harness.layout.blobURL(keyA)))
    }

    @Test("R-CLN-5: deletion grace uses the awake clock and a fresh acknowledgement after a device sleep", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func awakeClockAndFreshAcknowledgement() async throws {
        let (harness, keyA, _) = try await StoreDeletionTests.prunedStore()
        _ = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        harness.time.sleepDevice(for: 3_600)
        let asleep = await harness.store.runDueWork()
        #expect(asleep.reapedKeys == 0 && harness.exists(harness.layout.blobURL(keyA)))
        #expect(asleep.nextDeadline == harness.time.monotonicNow().adding(seconds: 10), "ten seconds of awake time remain")
        harness.time.advance(by: 10)
        // The grace passed, but the install that would prove the main actor ran comes back unacknowledged.
        await harness.sink.setBehaviour(.report(SnapshotKey(epoch: 0, version: 0)))
        let unproven = await harness.store.runDueWork()
        #expect(unproven.installedSnapshot && unproven.reapedKeys == 0)
        #expect(unproven.nextDeadline == nil)
        await harness.sink.setBehaviour(.acknowledge)
        let proven = await harness.store.runDueWork()
        #expect(proven.installedSnapshot && proven.reapedKeys == 1)
        #expect(!harness.exists(harness.layout.blobURL(keyA)))
    }

    @Test("R-STO-4: a degraded fallback deletes no blob listed in the older generation's doomed set", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func degradedFallbackProtectsDoomedKeys() async throws {
        let (harness, keyA, _) = try await StoreDeletionTests.prunedStore()
        let entryB = CoreFixture.entry("b", CoreFixture.bytes(71))
        _ = try await harness.store.apply(CoreFixture.manifest([entryB]), etag: nil, eviction: nil)
        await harness.store.close()
        var disk = harness.fileSystem.survivingDisk()
        let bin = harness.layout.indexURL(.current).path
        let prev = harness.layout.indexURL(.previous).path
        #expect(disk.files[prev] != nil)
        disk.files[bin]?[80] ^= 0xFF
        disk.durableFiles[bin]?[80] ^= 0xFF
        let reopened = CoreHarness.make(disk: disk)
        let report = try await reopened.store.open()
        #expect(report.degraded)
        guard case .doomed? = await reopened.state.core.blobTable[keyA] else {
            Issue.record("the older generation's DOOMED key is not doomed after the fallback")
            return
        }
        reopened.time.advance(by: 3_600)
        let work = await reopened.store.runDueWork()
        #expect(work.reapedKeys == 0 && reopened.exists(reopened.layout.blobURL(keyA)))
        #expect(await reopened.store.nextDeadline() == nil)
        // The next manifest and adoption end degraded mode; only then does the reaper proceed.
        _ = try await reopened.store.apply(CoreFixture.manifest([entryB]), etag: nil, eviction: nil)
        #expect(await reopened.state.core.degraded == false)
        reopened.time.advance(by: 10)
        #expect(await reopened.store.runDueWork().reapedKeys == 1)
    }

    @Test("R-CLN-5: a doomed key blocked only by a lease keeps no deadline, and releasing the lease makes it deletable at once", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func leaseBlockedKeys() async throws {
        let (harness, keyA, _) = try await StoreDeletionTests.prunedStore()
        let lease = try await harness.store.acquireLease("a")
        #expect(lease.blob == keyA)
        _ = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        harness.time.advance(by: 60)
        let leased = await harness.store.runDueWork()
        #expect(leased.reapedKeys == 0 && leased.nextDeadline == nil)
        #expect(await harness.store.reapDeletable(maxKeys: 10) == CleanupResult(bytesFreed: 0, filesRemoved: 0, bytesDeferred: 300))
        let free = try await harness.store.freeSpace()
        #expect(free.pendingReclaim == 0 && free.usedBytes == 300)
        _ = await harness.store.releaseLease(lease)
        #expect(await harness.store.nextDeadline() == harness.time.monotonicNow())
        #expect(await harness.store.runDueWork().reapedKeys == 1)
    }

    @Test("R-CLN-5: a failed unlink keeps the key doomed with backoff and retries it", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func failedUnlinkBacksOff() async throws {
        let (harness, keyA, _) = try await StoreDeletionTests.prunedStore()
        harness.fileSystem.addFault(FaultRule(operation: .removeItem, matching: URLMatcher(pathContains: keyA.hash.hex), occurrence: .nth(1), error: .io))
        _ = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        harness.time.advance(by: 10)
        let failed = await harness.store.runDueWork()
        #expect(failed.reapedKeys == 0 && harness.exists(harness.layout.blobURL(keyA)))
        guard case .doomed(let info)? = await harness.state.core.blobTable[keyA] else {
            Issue.record("the key left the doomed state after a failed unlink")
            return
        }
        #expect(info.failedUnlinks == 1)
        #expect(failed.nextDeadline == harness.time.monotonicNow().adding(seconds: 1))
        harness.time.advance(by: 1)
        #expect(await harness.store.runDueWork().reapedKeys == 1)
        #expect(AssetStore.unlinkBackoff(afterFailures: 1) == 1 && AssetStore.unlinkBackoff(afterFailures: 4) == 8)
        #expect(AssetStore.unlinkBackoff(afterFailures: 40) == 300)
    }

    @Test("P-13: reaping runs in sorted units of deletionBatchSize and honours maxKeys", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func reapBatches() async throws {
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(deletionBatchSize: 16))
        _ = try await harness.store.open()
        let payloads = (0..<40).map { CoreFixture.bytes(1_000 + UInt64($0), count: 32) }
        let entries = payloads.enumerated().map { CoreFixture.entry("e\($0.offset)", $0.element) }
        _ = try await harness.store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
        for (index, (bytes, entry)) in zip(payloads, entries).enumerated() {
            try await harness.publish(bytes, [entry], sequence: UInt32(index + 1))
        }
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        harness.time.advance(by: 10)
        _ = await harness.store.runDueWorkInstallOnly()
        let start = harness.fileSystem.operations.count
        let partial = await harness.store.reapDeletable(maxKeys: 10)
        #expect(partial.filesRemoved == 10 && partial.bytesFreed == 320)
        let all = await harness.store.reapDeletable(maxKeys: .max)
        #expect(all.filesRemoved == 30)
        let removed = harness.fileSystem.operations[start...].filter { $0.kind == .removeItem }.map(\.url)
        let expected = payloads.map { harness.layout.blobURL(CoreFixture.key($0)) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(removed == expected)
        #expect(await harness.state.core.blobTable.isEmpty)
    }
}

@Suite("Core: time-bounded deletion units")
struct DeletionUnitTests {
    @Test("P-13: a deletion unit stops when its time budget is spent and the reaper carries the rest to the next unit", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func timeBoundedUnits() async throws {
        let clock = SteppingClock()
        let metadata = CountingExecutor()
        let fake = FakeFileSystem(time: clock.base)
        let store = AssetStore(
            configuration: CoreFixture.configuration(),
            environment: CoreHarness.environment(fileSystem: fake, time: clock, metadata: metadata)
        )
        _ = try await store.open()
        let payloads = (0..<20).map { CoreFixture.bytes(2_000 + UInt64($0), count: 16) }
        let entries = payloads.enumerated().map { CoreFixture.entry("t\($0.offset)", $0.element) }
        _ = try await store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
        let sink = try await store.makeStagingSink()
        for (index, (bytes, entry)) in zip(payloads, entries).enumerated() {
            let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: UInt32(index + 1)), kind: .partial)
            try sink.createPartial(name)
            _ = try sink.appendPartial(bytes, to: name)
            _ = try await store.publish(StagedFile(name: name, byteCount: 16, resumed: false, httpStatus: nil, etag: nil), binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        }
        _ = try await store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        clock.base.advance(by: 10)
        await store.runDueWorkInstallOnly()
        let before = await metadata.units
        clock.setStepping(true)
        let result = await store.reapDeletable(maxKeys: .max)
        clock.setStepping(false)
        #expect(result.filesRemoved == 20)
        // Each unlink is seen to take 1 ms (one clock read). Before its k-th unlink a unit has spent k − 1 ms and
        // predicts 1 ms more, so it admits k unlinks while k ms ≤ the budget: one per unit at the 1 ms budget (without
        // the prediction it would make two, ADR draft B-10), and the next unit carries on.
        let perUnit = max(1, Int((BlobDeletionUnit.budget * 1_000).rounded(.down)))
        #expect(perUnit == 1)
        #expect(await metadata.units - before == (20 + perUnit - 1) / perUnit, "the budget that predicts the last 1 ms unlink admits \(perUnit) per unit")
        #expect(await store.state.core.blobTable.isEmpty)
        let removed = fake.operations.filter { $0.kind == .removeItem && $0.url.path.contains("/blobs/") }.map(\.url)
        #expect(removed == payloads.map { CoreFixture.layout.blobURL(CoreFixture.key($0)) }.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }
}

/// A clock whose monotonic reads advance 1 ms each while stepping (a slow volume, seen from inside a unit).
@available(macOS 15.0, iOS 18.0, *)
final class SteppingClock: TimeSource {
    let base = ManualTimeSource()
    private let stepping = Mutex(false)

    func setStepping(_ value: Bool) {
        self.stepping.withLock { $0 = value }
    }

    func now() -> Date {
        self.base.now()
    }

    func monotonicNow() -> MonotonicInstant {
        let value = self.base.monotonicNow()
        if self.stepping.withLock({ $0 }) {
            self.base.advance(by: 0.001)
        }
        return value
    }

    func uptimeNow() -> MonotonicInstant {
        self.base.uptimeNow()
    }

    func sleep(until deadline: MonotonicInstant) async throws(CancellationError) {
        try await self.base.sleep(until: deadline)
    }
}

extension AssetStore {
    /// Commits pending state and installs a snapshot now.
    func flushAndInstall() async throws(StoreError) {
        try await self.requireCommittedInternal(.ordered)
        await self.installSnapshot()
    }

    /// The fresh install of `runDueWork()` without reaping, so a test can reap through `reapDeletable(maxKeys:)`.
    func runDueWorkInstallOnly() async {
        await self.installSnapshot()
    }
}
