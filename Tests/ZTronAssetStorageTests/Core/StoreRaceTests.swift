import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Interleavings found by the level-2 review (probes P1, P2, P3, P5), each held at its known point with
/// `SteppedBlockingExecutor` or `GatedSnapshotSink` (H-5).
@Suite("Core: review interleavings (H-2, H-5)")
struct StoreRaceTests {
    /// Waits for a held unit and releases the oldest one; throws once the test is cancelled (its time limit).
    @available(macOS 15.0, *)
    static func step(_ executor: SteppedBlockingExecutor) async throws {
        try await executor.requireHeldUnits(atLeast: 1)
        await executor.releaseNext()
    }

    @Test("R-INT-1: two publications binding one digest under a second extension copy it once and never place a torn copy", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func concurrentBindsOfOneExtraExtension() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata, bulk: bulk)
        let bytes = CoreFixture.bytes(170, count: 1_572_864)
        let a = CoreFixture.entry("a", bytes, ext: "png")
        let b = CoreFixture.entry("b", bytes, ext: "jpg")
        let c = CoreFixture.entry("c", bytes, ext: "png")
        let d = CoreFixture.entry("d", bytes, ext: "jpg")
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, b, c, d]), etag: nil, eviction: nil)
        let first = try await harness.stage(bytes, for: a, sequence: 1)
        let second = try await harness.stage(bytes, for: c, sequence: 2)
        await metadata.setHolding(true)
        await bulk.setHolding(true)
        let publishFirst = Task {
            try await harness.store.publish(first, binding: [a.identifier, b.identifier], expecting: a.contentIdentity, urgency: .bulk)
        }
        // The first publication: claim, two hash units, the png placement, the two jpg copy units; its jpg
        // placement is then held.
        try await StoreRaceTests.step(metadata)
        try await StoreRaceTests.step(bulk)
        try await StoreRaceTests.step(bulk)
        try await StoreRaceTests.step(metadata)
        try await StoreRaceTests.step(bulk)
        try await StoreRaceTests.step(bulk)
        try await metadata.requireHeldUnits(atLeast: 1)
        let firstPlacement = await metadata.heldUnits[0]
        let publishSecond = Task {
            try await harness.store.publish(second, binding: [c.identifier, d.identifier], expecting: c.contentIdentity, urgency: .bulk)
        }
        // The second publication: claim, two hash units, the png placement (a dedupe onto the first's blob).
        try await metadata.requireHeldUnits(atLeast: 2)
        await metadata.release(await metadata.heldUnits[1])
        try await StoreRaceTests.step(bulk)
        try await StoreRaceTests.step(bulk)
        try await metadata.requireHeldUnits(atLeast: 2)
        await metadata.release(await metadata.heldUnits[1])
        // The second binder of the jpg key reaches it while the first still places its copy.
        await metadata.release(firstPlacement)
        await metadata.setHolding(false)
        await bulk.setHolding(false)
        let firstLocations = try await publishFirst.value
        let secondLocations = try await publishSecond.value
        #expect(Set(firstLocations.keys) == [a.identifier, b.identifier])
        #expect(Set(secondLocations.keys) == [c.identifier, d.identifier])
        let jpg = CoreFixture.key(bytes, ext: "jpg")
        let png = CoreFixture.key(bytes, ext: "png")
        let copies = harness.fileSystem.operations.filter { $0.kind == .write && $0.url.lastPathComponent.hasSuffix(".parttmp") }
        #expect(copies.count == 2, "one copy of 1.5 MiB in two units; the second binder reuses it")
        #expect(Set(copies.map(\.url)).count == 1)
        #expect(await harness.state.core.blobTable[jpg] == .live(references: 2))
        #expect(await harness.state.core.blobTable[png] == .live(references: 2))
        #expect(await harness.state.core.publishing.isEmpty)
        let staging = try harness.fileSystem.contentsOfDirectory(at: harness.layout.stagingDirectory)
        #expect(!staging.contains { $0.name.hasSuffix(".parttmp") }, "no copy is left in staging")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-5: a replacement store whose epoch repeats never counts the previous store's snapshot as acknowledged", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func repeatedEpochNeverAcknowledges() async throws {
        let sink = ScriptedSnapshotSink()
        let bytes = CoreFixture.bytes(180)
        let entry = CoreFixture.entry("a", bytes)
        let key = CoreFixture.key(bytes)
        let first = CoreHarness.make(sink: sink)
        _ = try await first.store.open()
        _ = try await first.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        try await first.publish(bytes, [entry])
        for _ in 0..<10 {
            try await first.store.flushAndInstall()
        }
        let left = await sink.installed.key
        #expect(await sink.installed.location(for: entry.identifier, extensions: []) != nil)
        // The root was wiped and a replacement store opened on it, sharing the process's mirror: the epoch repeats.
        let second = CoreHarness.make(sink: sink)
        _ = try await second.store.open()
        #expect(await second.state.core.launchEpoch == left.epoch)
        _ = try await second.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        try await second.publish(bytes, [entry])
        _ = try await second.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        second.time.advance(by: 3_600)
        _ = await second.store.runDueWork()
        second.time.advance(by: 3_600)
        let work = await second.store.runDueWork()
        // Readers still see the first store's snapshot, which lists `a` at this very path: the blob stays.
        #expect(await sink.installed.key == left)
        #expect(work.reapedKeys == 0 && second.exists(second.layout.blobURL(key)))
        #expect(await second.state.core.snapshots.acknowledgedVersion == 0)
        // Once the replacement store's own snapshot is what readers see, the deletion proceeds.
        try await CorePoll.until("the replacement store's snapshot past version \(left.version)") {
            if await second.state.core.snapshots.version > left.version {
                return true
            }
            try await second.store.flushAndInstall()
            return false
        }
        #expect(await sink.installed.key.version > left.version)
        #expect(await sink.installed.location(for: entry.identifier, extensions: []) == nil)
        second.time.advance(by: 3_600)
        #expect(await second.store.runDueWork().reapedKeys == 1)
        #expect(!second.exists(second.layout.blobURL(key)))
    }

    @Test("R-CLN-1: a reused placement that fails after a prune dooms the key with a deadline and is reaped", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func failedReusedPlacementIsReaped() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata)
        let bytes = CoreFixture.bytes(190)
        let x = CoreFixture.entry("x", bytes)
        let y = CoreFixture.entry("y", bytes)
        let key = CoreFixture.key(bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([x, y]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [x], sequence: 1)
        let staged = try await harness.stage(bytes, for: y, sequence: 2, sidecar: true)
        harness.fileSystem.addFault(FaultRule(operation: .removeItem, matching: URLMatcher(lastComponentSuffix: ".resume"), occurrence: .every, error: .io))
        await metadata.setHolding(true)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [y.identifier], expecting: y.contentIdentity, urgency: .bulk)
        }
        try await StoreRaceTests.step(metadata)  // the claim
        try await metadata.requireHeldUnits(atLeast: 1)  // the dedupe placement holds a provisional reference
        let placement = await metadata.heldUnits[0]
        let applying = Task {
            try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        }
        try await metadata.requireHeldUnits(atLeast: 2)  // apply's commit, queued behind the placement
        await metadata.release(await metadata.heldUnits[1])
        _ = try await applying.value
        await metadata.release(placement)  // the sidecar removal fails: the provisional reference is dropped
        try await StoreRaceTests.step(metadata)  // the claimed file is discarded before the error is thrown (B-26)
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await publishing.value
        }
        #expect(!StoreRecoveryTests.stagingNames(harness).contains { $0.hasSuffix(".verifying") })
        await metadata.setHolding(false)
        guard case .doomed? = await harness.state.core.blobTable[key] else {
            Issue.record("the key is not doomed")
            return
        }
        #expect(await harness.store.nextDeadline() != nil, "the drop is committed and installed on a deadline")
        var reaped = 0
        for _ in 0..<4 where reaped == 0 {
            reaped += await harness.store.runDueWork().reapedKeys
            harness.time.advance(by: 10)
        }
        #expect(reaped == 1 && !harness.exists(harness.layout.blobURL(key)))
        #expect(try await harness.store.freeSpace().pendingReclaim == 0)
    }

    @Test("R-INT-2: a prune during a checksum-less publication's commit yields superseded and never returns the URL", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func pruneDuringPublicationCommit() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        var policy = StoragePolicy()
        policy.allowUnverifiedAssets = true
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(policy: policy), metadata: metadata)
        let bytes = CoreFixture.bytes(200)
        let x = CoreFixture.entry("x", bytes, checksum: false)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([x]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: x)
        await metadata.setHolding(true)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [x.identifier], expecting: x.contentIdentity, urgency: .bulk)
        }
        try await StoreRaceTests.step(metadata)  // the claim
        try await StoreRaceTests.step(metadata)  // the placement
        try await metadata.requireHeldUnits(atLeast: 1)  // the commit a checksum-less publication waits for (S1-05)
        let applying = Task {
            try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        }
        try await StoreRaceTests.waitForCommitWaiter(harness)
        await metadata.setHolding(false)
        await #expect(throws: StoreError.superseded(x.identifier)) {
            try await publishing.value
        }
        _ = try await applying.value
        #expect(await harness.store.location(for: x.identifier, extensions: [], recordingAccess: false) == nil)
        #expect(await harness.sink.installed.location(for: x.identifier, extensions: []) == nil)
    }

    @Test("R-INT-2: a prune during a publication's snapshot install yields superseded and never returns the URL", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func pruneDuringPublicationInstall() async throws {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let sink = GatedSnapshotSink()
        let store = AssetStore(configuration: CoreFixture.configuration(), environment: CoreHarness.environment(fileSystem: fileSystem, time: time, sink: sink))
        let bytes = CoreFixture.bytes(210)
        let x = CoreFixture.entry("x", bytes)
        let report = try await store.open()
        _ = try await store.apply(CoreFixture.manifest([x]), etag: nil, eviction: nil)
        let staging = try await store.makeStagingSink()
        let name = StagingFileName(transfer: x.transferID, attempt: TransferAttempt(epoch: report.launchEpoch, sequence: 1), kind: .partial)
        try staging.createPartial(name)
        _ = try staging.appendPartial(bytes, to: name)
        await sink.setHolding(true)
        let publishing = Task {
            try await store.publish(StagedFile(name: name, byteCount: 300, resumed: false, httpStatus: 200, etag: nil), binding: [x.identifier], expecting: x.contentIdentity, urgency: .userInitiated)
        }
        await sink.waitForHeldInstalls(atLeast: 1)  // the publication's install, with x present
        let applying = Task {
            try await store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        }
        await sink.waitForHeldInstalls(atLeast: 2)  // apply's install: x was pruned before it
        await sink.releaseOldest()
        await #expect(throws: StoreError.superseded(x.identifier)) {
            try await publishing.value
        }
        await sink.setHolding(false)
        _ = try await applying.value
        #expect(await store.location(for: x.identifier, extensions: [], recordingAccess: false) == nil)
    }

    /// Review round 2, probe 1: while a rescue's placement is held the key is live, so another record can gain it,
    /// appear in an acknowledged snapshot and lose it again (a decrement, no fresh doom). The dropped rescue must not
    /// restore the old doom, whose grace ended long before that snapshot was replaced.
    @Test("R-CLN-5: a rescue that binds nothing after another record gained and lost the key is doomed afresh and waits a new grace", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func droppedRescueIsDoomedAfresh() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata)
        let bytes = CoreFixture.bytes(900)
        let key = CoreFixture.key(bytes)
        let a = CoreFixture.entry("a", bytes)
        let x = CoreFixture.entry("x", bytes)
        let y = CoreFixture.entry("y", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, x]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [x], sequence: 1)
        // `a` publishes the same bytes later; its purge-style residency keeps it from adopting them at `apply`.
        await harness.store.setResidency(.absent(.purged), of: a.identifier, dooming: .purged)
        _ = try await harness.store.apply(CoreFixture.manifest([a]), etag: nil, eviction: nil)
        guard case .doomed(let first)? = await harness.state.core.blobTable[key], let oldEligibility = first.eligibleAt else {
            Issue.record("the pruned key is not doomed and acknowledged")
            return
        }
        harness.time.advance(by: 60)
        // `a`'s publication rescues the key; its placement unit is held.
        let staged = try await harness.stage(bytes, for: a, sequence: 2)
        await metadata.setHolding(true)
        let publication = Task {
            try await harness.store.publish(staged, binding: [a.identifier], expecting: a.contentIdentity, urgency: .bulk)
        }
        try await StoreRaceTests.step(metadata)  // the claim
        try await metadata.requireHeldUnits(atLeast: 1)  // the placement
        #expect(await harness.state.core.blobTable[key] == .live(references: 1))
        // `y` adopts the live key and readers get a snapshot listing it.
        let adopt = Task {
            try await harness.store.apply(CoreFixture.manifest([a, y]), etag: nil, eviction: nil)
        }
        try await metadata.requireHeldUnits(atLeast: 2)
        await metadata.release(await metadata.heldUnits[1])
        #expect(try await adopt.value.reused == [y.identifier])
        #expect(await harness.sink.installed.location(for: y.identifier, extensions: []) != nil)
        // The next manifest prunes `y` and changes `a`, so the held publication binds nothing.
        let prune = Task {
            try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("a", CoreFixture.bytes(901))]), etag: nil, eviction: nil)
        }
        try await metadata.requireHeldUnits(atLeast: 2)
        await metadata.release(await metadata.heldUnits[1])
        _ = try await prune.value
        #expect(await harness.sink.installed.location(for: y.identifier, extensions: []) == nil)
        let versionWithoutKey = await harness.state.core.snapshots.version
        await metadata.setHolding(false)
        await #expect(throws: StoreError.superseded(a.identifier)) {
            try await publication.value
        }
        guard case .doomed(let renewed)? = await harness.state.core.blobTable[key] else {
            Issue.record("the dropped rescue left the key undoomed")
            return
        }
        #expect(renewed.eligibleAt == nil, "the old eligibility (\(oldEligibility)) must not come back")
        #expect(renewed.sinceSnapshotVersion > versionWithoutKey && renewed.reason == .unreferenced)
        // No time passes: the snapshot listing `y` at this key was replaced only now, so no grace has run.
        let work = await harness.store.runDueWork()
        #expect(work.reapedKeys == 0 && harness.exists(harness.layout.blobURL(key)), "I-3: unlinked with no grace")
        // A full grace after the new acknowledgement, the key goes.
        harness.time.advance(by: 11)
        var reaped = await harness.store.runDueWork().reapedKeys
        harness.time.advance(by: 11)
        reaped += await harness.store.runDueWork().reapedKeys
        #expect(reaped == 1 && !harness.exists(harness.layout.blobURL(key)))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Waits until a caller is parked on the running commit (no sleeping: the actor is polled between yields).
    @available(macOS 15.0, *)
    static func waitForCommitWaiter(_ harness: CoreHarness, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await CorePoll.until("a caller parked on the running commit", sourceLocation: sourceLocation) {
            await !harness.state.core.commits.waiters.isEmpty
        }
    }
}

/// A snapshot sink that can hold installs at the await (REENTRANCY R6), answering like `SnapshotMirror` once released.
actor GatedSnapshotSink: SnapshotSink {
    private let inner = ScriptedSnapshotSink()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Starts or stops holding; stopping releases every held install.
    func setHolding(_ holding: Bool) {
        self.holding = holding
        if !holding {
            let released = self.held
            self.held = []
            for continuation in released {
                continuation.resume()
            }
        }
    }

    /// Releases the oldest held install.
    func releaseOldest() {
        guard !self.held.isEmpty else {
            return
        }
        self.held.removeFirst().resume()
    }

    /// Suspends until at least `count` installs are held.
    func waitForHeldInstalls(atLeast count: Int) async {
        if self.held.count >= count {
            return
        }
        // REENTRANCY: test sink — nothing: a terminal wait resumed by the install that reached `count`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.heldWaiters.append((count, continuation))
        }
    }

    func install(_ snapshot: AssetSnapshot) async -> InstallAck {
        if self.holding {
            // REENTRANCY: test sink — nothing: the install below answers from the inner sink's state at release.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.held.append(continuation)
                let count = self.held.count
                self.heldWaiters.removeAll { waiter in
                    guard waiter.count <= count else {
                        return false
                    }
                    waiter.continuation.resume()
                    return true
                }
            }
        }
        // REENTRANCY: test sink — nothing is read afterwards.
        return await self.inner.install(snapshot)
    }
}
