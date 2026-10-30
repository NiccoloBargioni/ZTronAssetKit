import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension SyncEngine {
    /// Test seam: the transfer the engine's copy of the applied manifest names for `id`.
    func appliedTransferForTests(_ id: AssetID) -> TransferID? {
        self.state.applied.entry(for: id)?.transferID
    }

    /// Test seam: the heals the engine still schedules or runs.
    func healsForTests() -> [AssetID] {
        self.state.heals.keys.sorted()
    }

    /// Test seam: the state of the job of `transfer`, if any.
    func jobStateForTests(_ transfer: TransferID) -> JobStateKind? {
        self.state.jobs[transfer]?.state.kind
    }
}

/// Regressions the level-4 verifiers found in WP-F fix round 2. Each test failed before its fix (F-20).
@Suite("Engine regressions, round 2")
struct EngineRegressionRound2Tests {
    // MARK: Supersession while the engine's manifest copy lags the store (S1-13, T22)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a waiter whose job the store supersedes while a run's apply still commits follows the asset's new content", .timeLimit(.minutes(1)))
    func supersededWhileApplyCommits() async throws {
        let bulk = NextUnitGate()
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(metadata: metadata, bulk: bulk)
        let c1 = EngineFixture.bytes(2_101)
        let c2 = EngineFixture.bytes(2_102)
        let x1 = EngineHarness.onDemand("x", c1)
        let x2 = EngineHarness.onDemand("x", c2)
        await harness.serveManifest([x1])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(x1.transferID, [.hold, .stage(c1)])
        await harness.source.script(x2.transferID, [.stage(c2)])
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x1.transferID)
        // v2 changes x's content. The run's apply is held at its planning unit (the decode runs first), then at its
        // commit: its writes are in the store, its await has not returned to the engine.
        await harness.serveManifest([x2], etag: "v2")
        await bulk.holdNext(skipping: 1)
        let run = Task { await engine.sync(.force) }
        await bulk.waitForHold()
        await metadata.setHolding(true)
        await bulk.release()
        try await metadata.requireHeldUnits(atLeast: 1)
        #expect(try await harness.view().records["x"]?.entry.contentIdentity == x2.contentIdentity, "the apply's writes are in the store")
        // x@c1's transfer completes: the store answers its publication `.superseded`.
        await harness.source.release(x1.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { engine in
            engine.state.jobs[x1.transferID].map { $0.state != .downloading && $0.state != .verifying } ?? true
        }
        await metadata.setHolding(false)
        await metadata.releaseAll()
        let result = await waiter.value
        #expect(result.map(\.byteSize) == .success(Int64(c2.count)), "the waiter follows x's new content, got \(result)")
        _ = await run.value
        let starts = await harness.source.starts.filter { $0.id == x1.transferID }
        #expect(starts.count == 1, "the superseded content is not downloaded again while the apply commits")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a waiter whose job the store supersedes with a manifest the engine never applied follows the store's content", .timeLimit(.minutes(1)))
    func supersededByAnUnseenApply() async throws {
        let harness = EngineHarness.make()
        let c1 = EngineFixture.bytes(2_111)
        let c2 = EngineFixture.bytes(2_112)
        let x1 = EngineHarness.onDemand("x", c1)
        let x2 = EngineHarness.onDemand("x", c2)
        await harness.serveManifest([x1])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(x1.transferID, [.hold, .stage(c1)])
        await harness.source.script(x2.transferID, [.stage(c2)])
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x1.transferID)
        // The store applies v2 behind the engine's back: no apply of the engine is in flight to catch up with.
        let v2 = try ValidatedManifest(entries: [x2], digest: ContentHash.sha256(of: Data("v2".utf8)))
        _ = try await harness.store.apply(v2, etag: nil, eviction: nil)
        #expect(await engine.appliedTransferForTests("x") == x1.transferID, "the engine's copy still names x@c1")
        await harness.source.release(x1.transferID, with: .progress(received: 0, expected: nil))
        let result = await waiter.value
        #expect(result.map(\.byteSize) == .success(Int64(c2.count)), "the engine re-reads the store and follows x's content there, got \(result)")
        #expect(await engine.appliedTransferForTests("x") == x2.transferID)
        let starts = await harness.source.starts.filter { $0.id == x1.transferID }
        #expect(starts.count == 1)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: an id a shared publication cannot bind because the store moved it to new content follows that content", .timeLimit(.minutes(1)))
    func sharedPublicationPartlyBound() async throws {
        let harness = EngineHarness.make()
        let shared = EngineFixture.bytes(2_121)
        let c2 = EngineFixture.bytes(2_122)
        let a = EngineHarness.onDemand("a", shared)
        let b1 = EngineHarness.onDemand("b", shared)
        let b2 = EngineHarness.onDemand("b", c2)
        await harness.serveManifest([a, b1])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(a.transferID, [.hold, .stage(shared), .stage(shared)])
        await harness.source.script(b2.transferID, [.stage(c2)])
        let first = Task { await engine.awaitAsset("a", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        let second = Task { await engine.awaitAsset("b", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 2 }
        await engine.waitForHandle(a.transferID)
        // The store applies v2 (b's content changed) behind the engine's back, then the shared publication lands.
        let v2 = try ValidatedManifest(entries: [a, b2], digest: ContentHash.sha256(of: Data("v2".utf8)))
        _ = try await harness.store.apply(v2, etag: nil, eviction: nil)
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        #expect(await first.value.map(\.byteSize) == .success(Int64(shared.count)))
        let followed = await second.value
        #expect(followed.map(\.byteSize) == .success(Int64(c2.count)), "b follows its content in the store, got \(followed)")
        #expect(await engine.appliedTransferForTests("b") == b2.transferID)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: A purge while a run's apply commits (F-18 principle: the engine follows the store)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge during a run's apply leaves the engine following the manifest the store applied", .timeLimit(.minutes(1)))
    func purgeDuringApply() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let c1 = EngineFixture.bytes(2_201)
        let c2 = EngineFixture.bytes(2_202)
        let zBytes = EngineFixture.bytes(2_203)
        let x1 = EngineHarness.onDemand("x", c1)
        let x2 = EngineHarness.onDemand("x", c2)
        let z = EngineFixture.entry("z", zBytes)
        await harness.serveManifest([x1, z], etag: "v1")
        await harness.scriptTransfers([(z, zBytes)])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        await harness.source.script(x1.transferID, [.hold, .stage(c1)])
        await harness.source.script(x2.transferID, [.stage(c2)])
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x1.transferID)
        // v2: x changed, z pruned. The run's apply is held at its planning unit while a purge ends the run.
        await harness.serveManifest([x2], etag: "v2")
        await bulk.holdNext(skipping: 1)
        let run = Task { await engine.sync(.force) }
        await bulk.waitForHold()
        let purge = Task { await engine.purge(.scope(.identifiers(["nothing-here"]))) }
        await engine.awaitCondition { $0.state.run?.settlement == .cancelled }
        await bulk.release()
        #expect(await run.value == .failed(.cancelled))
        _ = await purge.value
        #expect(try await harness.view().appliedManifest.entry(for: "x")?.transferID == x2.transferID, "the store applied v2")
        #expect(await engine.appliedTransferForTests("x") == x2.transferID, "the engine's copy follows the store's committed apply")
        let result = await waiter.value
        #expect(result.map(\.byteSize) == .success(Int64(c2.count)), "the waiter follows x's new content, got \(result)")
        await engine.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        #expect(await probe.received.contains(.assetRemoved("z", .pruned)), "z was pruned by a committed apply")
        await probe.stop()
    }

    // MARK: Space (T17, ARCHITECTURE §7.6)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an insufficient-space failure on a volume that holds the transfer is retried, never parked", .timeLimit(.minutes(1)))
    func transientNoSpaceRetried() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(2_301)
        let x = EngineHarness.onDemand("x", bytes)
        await harness.serveManifest([x])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(x.transferID, [.fail(.insufficientSpace(requiredBytes: 10)), .stage(bytes)])
        let group = try await engine.registerGroup(["x"], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.lastError != nil }
        let state = await engine.introspect()
        #expect((state.jobsByState[.blocked] ?? 0) == 0, "a 64 GiB volume holds 10 bytes: the ENOSPC was transient")
        let resolved = await engine.awaitAsset("x", lane: .userInitiated)
        #expect(resolved.map(\.byteSize) == .success(Int64(bytes.count)), "a new job would download it now, got \(resolved)")
        await engine.releaseGroup(group)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// Two prefetches on a volume that holds one of them: the second parks `insufficientSpace` while the first is in
    /// flight; the first is then released, so the second fits.
    @available(macOS 15.0, iOS 18.0, *)
    static func parkedBehindAnotherTransfer(_ seed: UInt64) async throws -> (EngineHarness, ManifestEntry, Data, InterestToken) {
        let harness = EngineHarness.make(capacity: StoragePolicy().reserveFreeBytes + 5_000)
        let aBytes = EngineFixture.bytes(seed, count: 3_000)
        let bBytes = EngineFixture.bytes(seed + 1, count: 3_000)
        let a = EngineHarness.onDemand("a", aBytes)
        let b = EngineHarness.onDemand("b", bBytes)
        await harness.serveManifest([a, b])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(a.transferID, [.hold])
        await harness.source.script(b.transferID, [.stage(bBytes)])
        let first = try await engine.registerGroup(["a"], lane: .prefetch).get()
        await engine.waitUntil { $0.running == 1 }
        let second = try await engine.registerGroup(["b"], lane: .prefetch).get()
        await engine.waitUntil { ($0.jobsByState[.blocked] ?? 0) == 1 }
        await engine.releaseGroup(first)
        await engine.waitUntil { $0.running == 0 }
        return (harness, b, bBytes, second)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a job parked for lack of space starts once a fresh free-space read shows room", .timeLimit(.minutes(1)))
    func parkedJobReevaluatedOnRead() async throws {
        let (harness, b, _, group) = try await EngineRegressionRound2Tests.parkedBehindAnotherTransfer(2_311)
        let engine = harness.engine
        #expect((await engine.introspect().jobsByState[.blocked] ?? 0) == 1, "nothing has read the free space since")
        // A run reads the free space: the parked job's headroom now admits it.
        _ = await engine.sync(.force)
        let blocked = await engine.introspect().jobsByState[.blocked] ?? 0
        #expect(blocked == 0, "the read re-evaluates insufficientSpace (T17)")
        if blocked == 0 {
            await engine.waitForJobEnd(b.transferID)
            #expect(try await harness.view().records["b"]?.referencedBlob != nil)
        }
        await engine.releaseGroup(group)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a resolve that joins a job parked for lack of space downloads it once the job fits", .timeLimit(.minutes(1)))
    func parkedJobReevaluatedOnJoin() async throws {
        let (harness, b, bBytes, group) = try await EngineRegressionRound2Tests.parkedBehindAnotherTransfer(2_321)
        let engine = harness.engine
        let resolved = await engine.awaitAsset("b", lane: .userInitiated)
        #expect(resolved.map(\.byteSize) == .success(Int64(bBytes.count)), "the join re-checks the headroom, got \(resolved)")
        #expect(await harness.source.starts.filter { $0.id == b.transferID }.count == 1)
        await engine.releaseGroup(group)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a prefetch that joins a job parked for lack of space starts it once it fits", .timeLimit(.minutes(1)))
    func parkedJobReevaluatedOnSameLaneJoin() async throws {
        let (harness, b, _, group) = try await EngineRegressionRound2Tests.parkedBehindAnotherTransfer(2_331)
        let engine = harness.engine
        // Same lane: no promotion re-runs admission, the join itself re-checks the headroom.
        let joiner = try await engine.registerGroup(["b"], lane: .prefetch).get()
        await engine.waitForJobEnd(b.transferID)
        #expect(try await harness.view().records["b"]?.referencedBlob != nil)
        #expect(await harness.source.starts.filter { $0.id == b.transferID }.count == 1)
        await engine.releaseGroup(joiner)
        await engine.releaseGroup(group)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: Purge and groups (F-1 invariant)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge drops the prefetch group members whose interests it withdraws", .timeLimit(.minutes(1)))
    func purgeDropsGroupMembers() async throws {
        let harness = EngineHarness.make()
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(2_401))
        let y = EngineHarness.onDemand("y", EngineFixture.bytes(2_402))
        await harness.serveManifest([x, y])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(x.transferID, [.hold])
        await harness.source.script(y.transferID, [.hold])
        let group = try await engine.registerGroup(["x", "y"], lane: .prefetch).get()
        await engine.waitUntil { $0.running == 2 }
        _ = await harness.withClock { await engine.purge(.scope(.identifiers(["x"]))) }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        let state = await engine.introspect()
        #expect(state.running == 1, "y is not purged: its prefetch keeps running")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    // MARK: Breaker probe exits (ARCHITECTURE §7.7: any other exit returns to halfOpen(probe: nil))

    /// Opens the origin's 5xx breaker with five failing prefetches, then lets the cooldown pass.
    @available(macOS 15.0, iOS 18.0, *)
    static func openBreaker(_ harness: EngineHarness, failing: [ManifestEntry]) async throws {
        let engine = harness.engine
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let groups = try await engine.registerGroup(failing.map(\.identifier), lane: .prefetch).get()
        let opened = await probe.next { event in
            if case .circuitChanged(_, .open(.serverErrors, _)) = event {
                return true
            }
            return false
        }
        #expect(opened != nil)
        await engine.releaseGroup(groups)
        await probe.stop()
        harness.time.advance(by: CircuitBreakerPolicy().serverCooldownBase + 1)
    }

    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 30.1 to 31.8 s beside a second TSan process at a
    /// load of 20 to 35 (53 % of 60 s) and 13.8 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a half-open probe whose publication fails the store's hash check frees the probe slot", .timeLimit(.minutes(3)))
    func probeIntegrityFreesSlot() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 0))
        let failing = (0..<5).map { EngineHarness.onDemand("f\($0)", EngineFixture.bytes(UInt64(2_500 + $0))) }
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(2_510))
        let yBytes = EngineFixture.bytes(2_511)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest(failing + [x, y])
        for entry in failing {
            await harness.source.script(entry.transferID, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil))])
        }
        // x's bytes do not match its checksum (same length): the store's publication rejects them.
        await harness.source.script(x.transferID, [.stage(EngineFixture.bytes(2_599))])
        await harness.source.script(y.transferID, [.stage(yBytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        try await EngineRegressionRound2Tests.openBreaker(harness, failing: failing)
        #expect(await engine.awaitAsset("x", lane: .userInitiated) == .failure(.integrityFailure))
        let second = await engine.awaitAsset("y", lane: .userInitiated)
        #expect(second.map(\.byteSize) == .success(Int64(yBytes.count)), "the probe ended without a verdict, so y probes; got \(second)")
        await engine.shutdown()
    }

    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 35.6 to 35.9 s beside a second TSan process at a
    /// load of 20 to 35 (60 % of 60 s) and 15.9 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a half-open probe superseded by an apply frees the probe slot", .timeLimit(.minutes(3)))
    func probeSupersededFreesSlot() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 0), bulk: bulk)
        let failing = (0..<5).map { EngineHarness.onDemand("f\($0)", EngineFixture.bytes(UInt64(2_600 + $0))) }
        let c1 = EngineFixture.bytes(2_610)
        let c2 = EngineFixture.bytes(2_611)
        let x1 = EngineHarness.onDemand("x", c1)
        let x2 = EngineHarness.onDemand("x", c2)
        await harness.serveManifest(failing + [x1])
        for entry in failing {
            await harness.source.script(entry.transferID, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil))])
        }
        await harness.source.script(x1.transferID, [.hold, .stage(c1)])
        await harness.source.script(x2.transferID, [.stage(c2)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        // A run fetches v2 (x changed) while the breaker is closed; its apply is held at its planning unit.
        await harness.serveManifest(failing + [x2], etag: "v2")
        await bulk.holdNext(skipping: 1)
        let run = Task { await engine.sync(.force) }
        await bulk.waitForHold()
        try await EngineRegressionRound2Tests.openBreaker(harness, failing: failing)
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x1.transferID)
        // The apply commits v2: x@c1, the half-open probe, is superseded (T22) and the waiter follows x@c2.
        await bulk.release()
        _ = await run.value
        let result = await waiter.value
        #expect(result.map(\.byteSize) == .success(Int64(c2.count)), "the superseded probe frees the probe slot, got \(result)")
        await engine.shutdown()
    }

    // MARK: Staging hygiene (ARCHITECTURE §7.6, D-13)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-3: a failed attempt's partial without a sidecar is discarded, not left in staging", .timeLimit(.minutes(1)))
    func sidecarlessPartialDiscarded() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(2_701)
        let x = EngineHarness.onDemand("x", bytes)
        await harness.serveManifest([x])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(x.transferID, [.hold, .stage(bytes)])
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x.transferID)
        let first = try #require(await harness.source.starts.last)
        // What the live transport leaves after a dropped connection on a response without a validator: bytes in the
        // attempt's partial and no sidecar.
        let sink = try #require(await harness.source.attachedStaging)
        try sink.createPartial(first.partialName)
        _ = try sink.appendPartial(Data(repeating: 7, count: 120), to: first.partialName)
        await harness.source.release(x.transferID, with: .failed(.transient(.connectionLost(resumable: false), retryAfter: nil)))
        let result = await harness.withClock { await EngineHarness.value(of: waiter) }
        #expect(result.map(\.byteSize) == .success(Int64(bytes.count)), "\(result)")
        await engine.waitUntil { $0.jobsByState.isEmpty }
        let inventory = try await harness.store.stagingInventory()
        let left = inventory.items.keys.filter { $0.transfer == x.transferID && $0.attempt == first.attempt }
        #expect(left.isEmpty, "a partial nobody can continue is garbage: \(left)")
        #expect(await harness.source.starts.last?.resume == nil, "the retry starts from zero")
        await engine.shutdown()
    }

    // MARK: Shared content joined while it publishes (ADR-020, R-SYN-4 single flight)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a resolve that joins a shared-content job while it verifies is answered with its location", .timeLimit(.minutes(1)))
    func joinerDuringVerificationIsBound() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let shared = EngineFixture.bytes(2_801)
        let a = EngineHarness.onDemand("a", shared)
        let b = EngineHarness.onDemand("b", shared)
        #expect(a.transferID == b.transferID, "identical bytes share one transfer (ADR-020)")
        await harness.serveManifest([a, b])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // The second attempt is the one that binds b (the store deduplicates the bytes).
        await harness.source.script(a.transferID, [.hold, .stage(shared), .stage(shared)])
        let first = Task { await engine.awaitAsset("a", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(a.transferID)
        // The shared job's publication is held at its first store unit (the hash): the job is verifying.
        await bulk.holdNext()
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        #expect(await engine.jobStateForTests(a.transferID) == .verifying)
        let second = Task { await engine.awaitAsset("b", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 2 }
        await bulk.release()
        #expect(await first.value.map(\.byteSize) == .success(Int64(shared.count)))
        let joined = await second.value
        #expect(joined.map(\.byteSize) == .success(Int64(shared.count)), "b is in the manifest with the same bytes: never notFound, got \(joined)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose asset joins a shared-content job while it verifies fetches it and completes", .timeLimit(.minutes(1)))
    func runJoinsSharedJobWhileItVerifies() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let shared = EngineFixture.bytes(2_811)
        let a = EngineHarness.onDemand("a", shared)
        let b = EngineHarness.onDemand("b", shared)
        await harness.serveManifest([a, b])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // Runs now include both on-demand entries.
        _ = try await engine.setRetentionScope(.identifiers(["a", "b"])).get()
        await harness.source.script(a.transferID, [.hold, .stage(shared), .stage(shared)])
        let first = Task { await engine.awaitAsset("a", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(a.transferID)
        await bulk.holdNext()
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        // The run plans a and b (both absent) and joins the verifying job with both.
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.run?.outstanding[a.transferID]?.count == 2 }
        await bulk.release()
        #expect(await first.value.map(\.byteSize) == .success(Int64(shared.count)))
        let outcome = await run.value
        #expect(outcome.completeReport != nil, "b was never missing: \(outcome)")
        #expect(try await harness.view().records["b"]?.referencedBlob != nil)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: Heals (R-CLN-8)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-16: a heal whose re-download fails ends, and the engine forgets it", .timeLimit(.minutes(1)))
    func failedHealIsForgotten() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(2)
        await harness.serve(catalog)
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        let (entry, bytes) = catalog[0]
        let location = try await engine.awaitAsset(entry.identifier, lane: .userInitiated).get()
        var corrupted = bytes
        corrupted[corrupted.startIndex] ^= 0xFF
        try harness.fileSystem.write(corrupted, to: location.url, mode: .truncate)
        // The origin no longer has the content when the quarantine ends.
        await harness.source.script(entry.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        let report = try await engine.performMaintenance(timeBudget: 60).get()
        #expect(report.corruptFound == 1)
        #expect(await engine.healsForTests() == [entry.identifier], "the heal is scheduled at the quarantine's end")
        await harness.withClock {
            await engine.awaitCondition { $0.state.metrics.failures[.notFound] >= 1 && $0.state.jobs.isEmpty }
        }
        #expect(await harness.source.starts.count == 3, "two at the sync, one heal")
        #expect(await engine.healsForTests().isEmpty, "a heal that ended with a failure is not kept for the process lifetime")
        await engine.shutdown()
    }

    // MARK: Unknown identifiers (S1-13)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: an identifier the newest fetched manifest lists is admitted from it when the refetch fails", .timeLimit(.minutes(1)))
    func unknownIDAdmittedFromNewestWhenRefetchFails() async throws {
        let harness = EngineHarness.make(capacity: StoragePolicy().reserveFreeBytes + 4_096)
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(3_301))
        let qBytes = EngineFixture.bytes(3_302)
        let q = EngineHarness.onDemand("q", qBytes)
        let big = EngineFixture.entry("big", EngineFixture.bytes(3_303, count: 8_000))
        await harness.serveManifest([x])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // A run fetches v2, which lists q, but cannot hold v2's standard entry, so it applies nothing: v2 is the newest
        // manifest seen, and neither the engine nor the store applied it.
        await harness.serveManifest([x, q, big], etag: "v2")
        guard case .failed(.insufficientSpace) = await engine.sync(.force) else {
            Issue.record("the run was expected to stop before its apply")
            await engine.shutdown()
            return
        }
        #expect(try await harness.view().appliedManifest.entry(for: "q") == nil)
        let requests = try await engine.metrics().get().manifestRequests
        // The point-admission refetch for q fails.
        await harness.source.scriptManifest([.fail(.transient(.serverError(httpStatus: 503), retryAfter: nil))])
        await harness.source.script(q.transferID, [.stage(qBytes)])
        let resolved = await engine.awaitAsset("q", lane: .userInitiated)
        #expect(resolved.map(\.byteSize) == .success(Int64(qBytes.count)), "q is admitted from v2, got \(resolved)")
        #expect(try await engine.metrics().get().manifestRequests == requests + 1, "the refetch was asked for and failed")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: ensureAvailable materialisation (S1-15, C2)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable turns its fetches into jobs a pipeline at a time and completes the whole scope", .timeLimit(.minutes(1)))
    func ensureMaterialisesInBatches() async throws {
        // At most pipelineDepth × maxConcurrentTransfers + runLookahead = 2 × 2 + 4 = 8 members at a time.
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, pipelineDepth: 2, runLookahead: 4)
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<40).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(3_000 + index), count: 32)
            return (EngineHarness.onDemand("e\(index)", bytes), bytes)
        }
        await harness.serveManifest(catalog.map(\.0))
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.scriptTransfers(catalog)
        let peak = Mutex(0)
        let (registered, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let sampler = Task {
            await engine.awaitCondition { engine in
                peak.withLock { $0 = max($0, engine.state.jobs.count) }
                signal.yield()
                return false
            }
        }
        var registration = registered.makeAsyncIterator()
        _ = await registration.next()
        let report = try await engine.ensureAvailable(scope: .identifiers(Set(catalog.map(\.0.identifier)))).get()
        sampler.cancel()
        await sampler.value
        signal.finish()
        #expect(report.isComplete && report.present == 40, "\(report)")
        #expect(peak.withLock { $0 } <= 8, "jobs at once: \(peak.withLock { $0 })")
        #expect(peak.withLock { $0 } >= 2, "the sampler saw the ensure's jobs")
        #expect(await harness.source.starts.count == 40)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 35.2 to 36.0 s beside a second TSan process at a
    /// load of 20 to 35 (60 % of 60 s) and 15.9 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: an ensureAvailable whose members fail fast as they become jobs still settles, a batch per actor turn", .timeLimit(.minutes(3)))
    func ensureSettlesWhenMembersFailFast() async throws {
        let bulk = NextUnitGate()
        let tuning = SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 0, pipelineDepth: 1, runLookahead: 3)
        let harness = EngineHarness.make(tuning: tuning, bulk: bulk)
        let failing = (0..<5).map { EngineHarness.onDemand("f\($0)", EngineFixture.bytes(UInt64(3_100 + $0))) }
        let wanted = (0..<20).map { EngineHarness.onDemand("w\($0)", EngineFixture.bytes(UInt64(3_200 + $0))) }
        await harness.serveManifest(failing + wanted)
        for entry in failing {
            await harness.source.script(entry.transferID, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil))])
        }
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // The ensure fetches v2 and is held at its apply's planning unit while the origin's breaker opens.
        await harness.serveManifest(failing + wanted, etag: "v2")
        await bulk.holdNext(skipping: 1)
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers(Set(wanted.map(\.identifier)))) }
        await bulk.waitForHold()
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let groups = try await engine.registerGroup(failing.map(\.identifier), lane: .prefetch).get()
        let opened = await probe.next { event in
            if case .circuitChanged(_, .open(.serverErrors, _)) = event {
                return true
            }
            return false
        }
        #expect(opened != nil)
        await engine.releaseGroup(groups)
        await probe.stop()
        // Every member the ensure materialises is refused by the open breaker and answered at once.
        await bulk.release()
        let report = try await ensure.value.get()
        #expect(report.present == 0 && report.missing == 20, "\(report)")
        #expect(await harness.source.starts.filter { start in wanted.contains { $0.transferID == start.id } }.isEmpty)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: Re-attached transfers and the first run (R-NET-3)

    @available(macOS 15.0, iOS 18.0, *)
    static func relaunchWithLiveTransfer(_ seed: UInt64, appVersion: String) async throws -> (EngineHarness, FakeRemoteSource, ManifestEntry) {
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(seed)
        let entry = EngineHarness.onDemand("bg", bytes)
        let first = try await EngineLaunchTests.firstLifetime([entry], time: time)
        let source = FakeRemoteSource(capabilities: EngineLaunchTests.background)
        let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 9), kind: .partial)
        await source.scriptReattached([ReattachedTransfer(name: name, isRunning: true, bytesReceived: 100)])
        await source.script(entry.transferID, [.hold, .stage(bytes)])
        // An explicit retention scope includes the on-demand entry in runs, so a run plans it.
        let second = EngineHarness.make(
            disk: first.fileSystem.survivingDisk(),
            time: time,
            source: source,
            retentionScope: .identifiers(["bg"]),
            appVersion: appVersion
        )
        return (second, source, entry)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: at launch, staging files nobody can use are discarded: another transfer's partial, and a finished download that fails verification", .timeLimit(.minutes(1)))
    func launchDiscardsUnusableStaging() async throws {
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(2_921)
        let entry = EngineHarness.onDemand("done", bytes)
        let first = try await EngineLaunchTests.firstLifetime([entry], time: time)
        let fileSystem = FakeFileSystem(disk: first.fileSystem.survivingDisk(), time: time)
        let layout = StoreLayout(base: EngineHarness.base)
        // The OS finished a download whose bytes do not match the entry (same length), and a partial of a transfer the
        // manifest no longer wants is left over.
        let finished = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 4), kind: .partial)
        try fileSystem.write(EngineFixture.bytes(2_999), to: layout.stagingURL(finished), mode: .truncate)
        let stranger = EngineHarness.onDemand("gone", EngineFixture.bytes(2_922))
        let orphan = StagingFileName(transfer: stranger.transferID, attempt: TransferAttempt(epoch: 1, sequence: 5), kind: .partial)
        try fileSystem.write(Data(repeating: 1, count: 64), to: layout.stagingURL(orphan), mode: .truncate)
        let source = FakeRemoteSource(capabilities: EngineLaunchTests.background)
        await source.scriptReattached([ReattachedTransfer(name: finished, isRunning: false, bytesReceived: Int64(bytes.count))])
        let second = EngineHarness.make(time: time, source: source, fileSystem: fileSystem)
        try await second.start()
        #expect(try fileSystem.itemInfo(at: layout.stagingURL(finished)) == nil, "a finished download that fails verification is discarded")
        #expect(try fileSystem.itemInfo(at: layout.stagingURL(orphan)) == nil, "a partial nobody wants is discarded")
        #expect(try await second.view().records["done"]?.referencedBlob == nil, "nothing was adopted")
        #expect(await source.starts.isEmpty)
        await second.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: the first run after a relaunch joins a re-attached live transfer it plans, never cancels and restarts it", .timeLimit(.minutes(1)))
    func firstRunJoinsReattachedTransfer() async throws {
        let (second, source, entry) = try await EngineRegressionRound2Tests.relaunchWithLiveTransfer(2_901, appVersion: "1.0+1")
        try await second.start()
        let engine = second.engine
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(entry.transferID)
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.run?.outstanding[entry.transferID] != nil }
        await source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        let outcome = await run.value
        #expect(outcome.completeReport != nil, "\(outcome)")
        #expect(await source.cancelledTransfers.isEmpty)
        #expect(!(await source.controlLog).contains(FakeControlRecord(transfer: entry.transferID, control: .cancel)), "the run joins the live transfer it plans")
        #expect(await source.starts.count == 1, "joined once, never duplicated")
        #expect(try await second.view().records["bg"]?.referencedBlob != nil)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a launch run that is due joins the re-attached live transfer it plans", .timeLimit(.minutes(1)))
    func dueLaunchRunJoinsReattachedTransfer() async throws {
        // A new app version: the launch run is due under `.oncePerAppVersion`.
        let (second, source, entry) = try await EngineRegressionRound2Tests.relaunchWithLiveTransfer(2_911, appVersion: "2.0+1")
        try await second.start()
        let engine = second.engine
        await engine.awaitCondition { $0.state.run?.outstanding[entry.transferID] != nil }
        await engine.waitForHandle(entry.transferID)
        await source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        await engine.waitUntil { $0.jobsByState.isEmpty && $0.running == 0 }
        #expect(!(await source.controlLog).contains(FakeControlRecord(transfer: entry.transferID, control: .cancel)), "the launch run joins the live transfer")
        #expect(await source.starts.count == 1, "joined once, never duplicated")
        #expect(try await second.view().records["bg"]?.referencedBlob != nil)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
