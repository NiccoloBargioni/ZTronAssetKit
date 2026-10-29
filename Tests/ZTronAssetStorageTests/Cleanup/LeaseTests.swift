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

    /// A way to drop `a`'s last reference (§11 R-CLN-5: WP-C's dereferencing APIs as well as `apply`).
    enum Deref: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case applyDropping
        case reportUnreadable
        case evictIfNeeded
        case applyWithPlan
        case purgeScope

        var testDescription: String {
            self.rawValue
        }

        /// The doom the dereference gives `a`'s blob.
        var reason: DoomReason {
            switch self {
            case .applyDropping, .evictIfNeeded, .applyWithPlan:
                return .unreferenced
            case .reportUnreadable:
                return .corrupt
            case .purgeScope:
                return .purged
            }
        }

        /// Starts the dereference of `a` (the least recently used asset, its only eviction victim; `b` is kept).
        @available(macOS 15.0, iOS 18.0, *)
        func start(_ seeded: LeaseTests.Seeded) -> Task<Void, any Error> {
            let store = seeded.harness.store
            let (a, b, plan) = (seeded.a, seeded.b, seeded.plan)
            switch self {
            case .applyDropping:
                return Task {
                    _ = try await store.apply(CoreFixture.manifest([b.entry]), etag: nil, eviction: nil)
                }
            case .reportUnreadable:
                return Task {
                    try await store.reportUnreadable(a.id)
                }
            case .evictIfNeeded:
                return Task {
                    _ = try await store.evictIfNeeded()
                }
            case .applyWithPlan:
                return Task {
                    _ = try await store.apply(CoreFixture.manifest([a.entry, b.entry]), etag: nil, eviction: plan)
                }
            case .purgeScope:
                return Task {
                    _ = try await store.purge(.scope(.identifiers([a.id])))
                }
            }
        }
    }

    /// A store holding `a` and `b` (300 bytes each, `a` read least recently, both outside the residency window) over a
    /// budget only `a`'s eviction meets, and the dry run that evicts `a`.
    @available(macOS 15.0, iOS 18.0, *)
    struct Seeded: Sendable {
        let harness: CoreHarness
        let a: CleanupFixture.Asset
        let b: CleanupFixture.Asset
        let plan: EvictionPlan
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func seeded(metadata: (any BlockingExecutor)? = nil, sink: (any SnapshotSink)? = nil) async throws -> Seeded {
        let policy = CleanupFixture.policy(budget: .bytes(300), hysteresisTarget: 1)
        let harness = CoreHarness.cleanup(policy: policy, metadata: metadata, sinkOverride: sink)
        let a = CleanupFixture.asset("a", seed: 17)
        let b = CleanupFixture.asset("b", seed: 18)
        try await EvictionTests.seedWithAccesses(harness, [a, b], recent: [b.id])
        let plan = try #require(await harness.store.evictionPlan(toFree: 1, protecting: []))
        #expect(plan.victims.map(\.id) == [a.id])
        return Seeded(harness: harness, a: a, b: b, plan: plan)
    }

    /// Lets the dereference finish and the deletion protocol run to its end. With `graceStartsLate`, the grace must start
    /// only now, from the acknowledgement of an install made after the held one (an hour has passed since that one).
    /// `purge` waits out the protocol itself (REENTRANCY R9) on the manual clock.
    @available(macOS 15.0, iOS 18.0, *)
    static func finish(_ deref: Deref, _ task: Task<Void, any Error>, _ seeded: Seeded, graceStartsLate: Bool) async throws {
        let harness = seeded.harness
        let key = seeded.a.key
        if deref == .purgeScope {
            try await CorePoll.until("purge waits out its grace") {
                if case .grace = await harness.store.deletionBlocker(key) {
                    return true
                }
                return !graceStartsLate && !harness.hasBlob(key)
            }
            #expect(harness.hasBlob(key) || !graceStartsLate)
            harness.time.advance(by: harness.configuration.policy.deletionGrace)
            try await task.value
        } else {
            try await task.value
            if graceStartsLate {
                _ = await harness.store.runDueWork()
                let blocker = await harness.store.deletionBlocker(key)
                if case .grace = blocker {} else {
                    Issue.record("\(deref): the grace starts with the later acknowledgement, got \(blocker)")
                }
                #expect(harness.hasBlob(key))
            }
            await harness.settleDeletions()
        }
    }

    /// store-2 S2-13: a dereference made while a commit is in flight belongs to a later generation; the blob must not
    /// become deletable when the in-flight one lands, whichever API dereferenced it.
    @Test(
        "R-CLN-5: a deref during an in-flight commit or install never makes its blob deletable before a later commit and acknowledgement",
        .timeLimit(.minutes(1)),
        arguments: Deref.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func derefDuringInFlightCommit(deref: Deref) async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let seeded = try await LeaseTests.seeded(metadata: metadata)
        let harness = seeded.harness
        let key = seeded.a.key
        await metadata.setHolding(true)
        // A commit (of a pin) is captured and held.
        let pin = Task {
            try await harness.store.setPinned([seeded.b.id], pinned: true)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        let held = try #require(await metadata.heldUnits.first)
        #expect(await harness.store.state.core.commits.inFlight)
        // Meanwhile `a` loses its last reference: its blob is doomed by a generation after the held one. The
        // dereference's own units (a free-space measurement, say) run; only the held commit waits.
        let dereference = deref.start(seeded)
        try await CorePoll.releasing(metadata, .allExcept([held]), until: "a's blob doomed by \(deref)") {
            StoreRecoveryTests.isDoomed(await harness.store.state.core.blobTable[key], deref.reason)
        }
        // A snapshot without `a` is acknowledged and the grace passes: only the commit is missing.
        await harness.store.publishSnapshot(urgency: .userInitiated)
        harness.time.advance(by: 3_600)
        // The held commit lands: it does not cover the doom.
        await metadata.release(held)
        try await pin.value
        #expect(await harness.store.deletionBlocker(key) == .commit)
        #expect(harness.hasBlob(key))
        await metadata.setHolding(false)
        try await LeaseTests.finish(deref, dereference, seeded, graceStartsLate: false)
        #expect(!harness.hasBlob(key), "deleted once a later commit and acknowledgement covered it")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test(
        "R-CLN-5: a deref during an in-flight install starts its grace only with a later acknowledged install",
        .timeLimit(.minutes(1)),
        arguments: Deref.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func derefDuringInFlightInstall(deref: Deref) async throws {
        let sink = HeldSnapshotSink()
        let seeded = try await LeaseTests.seeded(sink: sink)
        let harness = seeded.harness
        let key = seeded.a.key
        await sink.setHolding(true)
        // An install of the current state (which still lists `a`) is in flight.
        let install = Task {
            await harness.store.publishSnapshot(urgency: .userInitiated)
        }
        try await sink.requireHeld(atLeast: 1)
        // `a` loses its last reference meanwhile; its blob is dropped by a later snapshot version.
        let dereference = deref.start(seeded)
        try await CorePoll.until("a's blob doomed by \(deref)") {
            StoreRecoveryTests.isDoomed(await harness.store.state.core.blobTable[key], deref.reason)
        }
        await sink.releaseNext()
        await install.value
        harness.time.advance(by: 3_600)
        #expect(await harness.store.deletionBlocker(key) == .acknowledgement, "the in-flight install still listed a's blob")
        #expect(harness.hasBlob(key))
        await sink.setHolding(false)
        try await LeaseTests.finish(deref, dereference, seeded, graceStartsLate: true)
        #expect(!harness.hasBlob(key), "the later acknowledged install started the grace")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }
}

/// A sink that can hold installs in arrival order, then acknowledges like the mirror (a newer key swaps).
actor HeldSnapshotSink: SnapshotSink {
    private var holding = false
    private var current: AssetSnapshot = .empty
    private var gates: [CheckedContinuation<Void, Never>] = []

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
