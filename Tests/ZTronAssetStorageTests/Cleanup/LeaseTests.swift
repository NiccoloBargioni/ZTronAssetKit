import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Leases (R-CAR-8, R-CLN-5) and the deletion protocol they gate (H-2, ARCHITECTURE §4.4).
@Suite("Cleanup: leases and the deletion protocol (R-CLN-5)")
struct LeaseTests {
    @Test("R-CLN-5: deletion waits for the acknowledged snapshot without the blob, the grace window and every lease", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func deletionWaitsForAckGraceAndLease() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 10)
        try await harness.seed([a])
        let lease = try await harness.store.acquireLease(a.id)
        #expect(lease.id == a.id && lease.blob == a.key && lease.url == harness.layout.blobURL(a.key))
        // The sink keeps its old snapshot: no acknowledgement, so the doomed blob must stay.
        await harness.sink.setBehaviour(.ignore)
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        harness.time.advance(by: 3_600)
        _ = await harness.store.runDueWork()
        #expect(harness.hasBlob(a.key), "no acknowledged snapshot lacks the blob yet")
        #expect(await harness.store.deletionBlocker(a.key) == .acknowledgement)
        // Acknowledged now: the grace window starts.
        await harness.sink.setBehaviour(.acknowledge)
        await harness.store.publishSnapshot(urgency: .userInitiated)
        harness.time.advance(by: harness.configuration.policy.deletionGrace - 1)
        _ = await harness.store.runDueWork()
        #expect(harness.hasBlob(a.key), "the grace window has not passed")
        harness.time.advance(by: 1)
        let leased = await harness.store.runDueWork()
        #expect(leased.reapedKeys == 0 && harness.hasBlob(a.key), "a lease holds the blob")
        #expect(await harness.store.deletionBlocker(a.key) == .lease)
        #expect(leased.nextDeadline == nil, "a lease-blocked key keeps no deadline")
        // Releasing the lease re-arms the engine's alarm, and the next run reaps the blob.
        let deadline = await harness.store.releaseLease(lease)
        #expect(deadline != nil)
        let reaped = await harness.store.runDueWork()
        #expect(reaped.reapedKeys == 1 && !harness.hasBlob(a.key))
    }

    @Test("R-CLN-5: every lease on a blob must end before it is deleted, and a second release is a no-op", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func everyLeaseMustEnd() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 11)
        try await harness.seed([a])
        let first = try await harness.store.acquireLease(a.id)
        let second = try await harness.store.acquireLease(a.id)
        #expect(first.token != second.token, "tokens are never reused")
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        await harness.settleDeletions()
        _ = await harness.store.releaseLease(first)
        _ = await harness.store.releaseLease(first)
        _ = await harness.store.runDueWork()
        #expect(harness.hasBlob(a.key), "the second lease still holds the blob after the first was released twice")
        _ = await harness.store.releaseLease(second)
        _ = await harness.store.runDueWork()
        #expect(!harness.hasBlob(a.key))
        #expect(await harness.store.state.cleanup.leases.isEmpty)
    }

    @Test("R-CAR-8: a lease is refused before open, for an unknown asset and for an asset without a blob", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func leaseRefusals() async throws {
        let harness = CoreHarness.cleanup()
        await #expect(throws: StoreError.notOpen) {
            _ = try await harness.store.acquireLease("a")
        }
        let a = CleanupFixture.asset("a", seed: 12)
        let b = CleanupFixture.asset("b", seed: 13)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a.entry, b.entry]), etag: nil, eviction: nil)
        try await harness.publish(a.bytes, [a.entry])
        await #expect(throws: StoreError.unknownAsset("zzz")) {
            _ = try await harness.store.acquireLease("zzz")
        }
        await #expect(throws: StoreError.notPresent(b.id)) {
            _ = try await harness.store.acquireLease(b.id)
        }
        await harness.store.close()
        await #expect(throws: StoreError.closed) {
            _ = try await harness.store.acquireLease(a.id)
        }
    }

    @Test("R-CLN-4: acquiring a lease counts as an access for the LRU order", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func leaseBumpsLastAccess() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 14)
        try await harness.seed([a])
        let before = try #require(await harness.record(a.id)).lastAccess
        harness.time.advance(by: 120)
        _ = try await harness.store.acquireLease(a.id)
        let after = try #require(await harness.record(a.id)).lastAccess
        #expect(after == before.addingTimeInterval(120))
    }

    /// store-2 S2-07: a second store on the same root in the same process (same mirror) must give a reader of the
    /// first store's last snapshot the whole grace window: the launch DOOMED keys wait for the new store's first
    /// acknowledgement plus grace, and the first store's leases ended with it.
    @Test("R-CLN-5: reopening the same root in one process never deletes a blob within the grace window of its last acknowledgement", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func reopenKeepsGrace() async throws {
        let time = ManualTimeSource()
        let sink = ScriptedSnapshotSink()
        let first = CoreHarness.cleanup(time: time, sink: sink)
        let a = CleanupFixture.asset("a", seed: 15)
        let b = CleanupFixture.asset("b", seed: 16)
        try await first.seed([a, b])
        _ = try await first.store.acquireLease(a.id)
        _ = try await first.store.apply(CoreFixture.manifest([b.entry]), etag: nil, eviction: nil)
        _ = await first.store.runDueWork()
        // The first store's snapshot without `a` was acknowledged; half the grace passes, then the store closes with
        // its lease still held (leases end at close).
        time.advance(by: first.configuration.policy.deletionGrace / 2)
        await first.store.close()
        let disk = first.fileSystem.survivingDisk()
        let second = CoreHarness.cleanup(disk: disk, time: time, sink: sink)
        _ = try await second.store.open()
        #expect(StoreRecoveryTests.isDoomed(await second.state.core.blobTable[a.key], .unreferenced))
        time.advance(by: second.configuration.policy.deletionGrace - 1)
        let early = await second.store.runDueWork()
        #expect(early.reapedKeys == 0 && second.hasBlob(a.key), "the reopened store waits a full grace from its own first acknowledgement")
        time.advance(by: 1)
        let due = await second.store.runDueWork()
        #expect(due.reapedKeys == 1 && !second.hasBlob(a.key), "the closed store's lease no longer holds the blob")
        #expect(second.hasBlob(b.key))
    }

    /// store-2 S2-13: a dereference made while a commit is in flight belongs to a later generation; the blob must not
    /// become deletable when the in-flight one lands.
    @Test("R-CLN-5: a deref during an in-flight commit or install never makes its blob deletable before a later commit and acknowledgement", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func derefDuringInFlightCommit() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(metadata: metadata)
        let a = CleanupFixture.asset("a", seed: 17)
        let b = CleanupFixture.asset("b", seed: 18)
        try await harness.seed([a, b])
        await metadata.setHolding(true)
        // A commit (of a pin) is captured and held.
        let pin = Task {
            try await harness.store.setPinned([b.id], pinned: true)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let held = await harness.store.state.core.commits.inFlight
        #expect(held)
        // Meanwhile `a` is quarantined: its blob is doomed by a generation after the held one.
        let report = Task {
            try await harness.store.reportUnreadable(a.id)
        }
        try await CorePoll.until("a's blob doomed") {
            StoreRecoveryTests.isDoomed(await harness.store.state.core.blobTable[a.key], .corrupt)
        }
        harness.time.advance(by: 3_600)
        // The held commit lands: it does not cover the doom.
        await metadata.releaseNext()
        try await metadata.requireHeldUnits(atLeast: 1)
        #expect(await harness.store.deletionBlocker(a.key) == .commit)
        #expect(harness.hasBlob(a.key))
        await metadata.setHolding(false)
        try await pin.value
        try await report.value
        await harness.settleDeletions()
        #expect(!harness.hasBlob(a.key), "deleted once a later commit and acknowledgement covered it")
    }

    @Test("R-CLN-5: a deref during an in-flight install starts its grace only with a later acknowledged install", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func derefDuringInFlightInstall() async throws {
        let sink = HeldSnapshotSink()
        let harness = CoreHarness.cleanup(sinkOverride: sink)
        let a = CleanupFixture.asset("a", seed: 19)
        let b = CleanupFixture.asset("b", seed: 20)
        try await harness.seed([a, b])
        await sink.setHolding(true)
        // An install of the current state (which still lists `a`) is in flight.
        let install = Task {
            await harness.store.publishSnapshot(urgency: .userInitiated)
        }
        try await sink.requireHeld(atLeast: 1)
        // `a` is quarantined meanwhile; its blob is dropped by the next snapshot version.
        let quarantine = Task {
            try await harness.store.reportUnreadable(a.id)
        }
        try await sink.requireHeld(atLeast: 2)
        await sink.releaseNext()
        await install.value
        #expect(await harness.store.deletionBlocker(a.key) == .acknowledgement, "the in-flight install still listed a's blob")
        await sink.setHolding(false)
        try await quarantine.value
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        _ = await harness.store.runDueWork()
        #expect(!harness.hasBlob(a.key), "the later acknowledged install started the grace")
    }
}

/// A sink that can hold installs in arrival order, then acknowledges like the mirror (a newer key swaps).
actor HeldSnapshotSink: SnapshotSink {
    private var holding = false
    private var current: AssetSnapshot = .empty
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    /// Starts or stops holding; stopping releases every held install in order.
    func setHolding(_ holding: Bool) {
        self.holding = holding
        if !holding {
            while !self.gates.isEmpty {
                self.releaseNext()
            }
        }
    }

    /// Releases the oldest held install.
    func releaseNext() {
        guard !self.gates.isEmpty else {
            return
        }
        self.gates.removeFirst().resume()
    }

    /// Suspends until `count` installs are held (installs only ever arrive from the store under test, so the wait
    /// ends; a test past its limit is cancelled and throws).
    func requireHeld(atLeast count: Int) async throws {
        while self.gates.count < count {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    func install(_ snapshot: AssetSnapshot) async -> InstallAck {
        if self.holding {
            // REENTRANCY: test sink — the install is applied after release against the snapshot current then.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.gates.append(continuation)
            }
        }
        guard snapshot.key > self.current.key else {
            return InstallAck(installed: self.current.key, accesses: [:], retired: nil)
        }
        let retired = self.current
        self.current = snapshot
        return InstallAck(installed: snapshot.key, accesses: [:], retired: retired)
    }
}
