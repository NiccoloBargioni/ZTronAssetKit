import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 18 of the level-4 close-out (`docs/adr-drafts/f.md`, F-38): the throttle end a run, a
/// fetch-first `ensureAvailable` and an unknown-id `resolve` report when a 429 extends the origin's throttle between
/// their manifest fetch's outcome and their answer. No test here moves the clock; every wait is a condition, a held seam or a join that ends on
/// cancellation (L4-R17).
@Suite("Engine regressions, close-out cycle 18")
struct EngineRegressionCycle18Tests {
    /// An engine whose origin a prefetch transfer's 429 throttled for 30 s, with a second prefetch transfer held in
    /// flight whose 429 the test sends later, and the manifest fetch outcomes held from their waiters.
    @available(macOS 15.0, iOS 18.0, *)
    struct Throttled {
        let harness: EngineHarness
        /// The transfer held in flight; its 429 extends the throttle.
        let extender: ManifestEntry
        /// An on-demand entry nothing fetched yet.
        let missing: ManifestEntry
        /// The throttle's end the first 429 set.
        let firstEnd: MonotonicInstant
        /// The manifest requests made before the throttled fetch.
        let requests: Int
        let tokens: [InterestToken]
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func throttled() async throws -> Throttled {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let bytesA = EngineFixture.bytes(6_501)
        let bytesB = EngineFixture.bytes(6_502)
        let bytesM = EngineFixture.bytes(6_503)
        let a = EngineHarness.onDemand("a", bytesA)
        let b = EngineHarness.onDemand("b", bytesB)
        let m = EngineHarness.onDemand("m", bytesM)
        await harness.serveManifest([a, b, m])
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        // B is held in flight; A's 429 then throttles the origin for 30 s.
        await harness.source.script(b.transferID, [.hold, .stage(bytesB)])
        let tokenB = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.active != nil }
        await harness.source.script(a.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(30))), .stage(bytesA)])
        let tokenA = try await engine.registerGroup([a.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state.isThrottleParked == true }
        let throttle = await engine.readForTests { $0.state.throttles[origin] }
        let firstEnd = try #require(throttle, "setup: the first 429 throttles the origin")
        let requests = await harness.source.manifestRequests.count
        await engine.holdManifestOutcomeDelivery()
        return Throttled(harness: harness, extender: b, missing: m, firstEnd: firstEnd, requests: requests, tokens: [tokenA, tokenB])
    }

    /// Waits until the fetch the caller joined holds its outcome, then lets B's 429 extend the origin's throttle to 60 s
    /// before the outcome reaches the caller; returns the extended end.
    @available(macOS 15.0, iOS 18.0, *)
    static func extendWhileHeld<T: Sendable>(_ throttled: Throttled, caller: Task<T, Never>) async throws -> MonotonicInstant {
        let engine = throttled.harness.engine
        let origin = throttled.harness.source.originID
        await untilFinishedOrCondition(caller, engine) { $0.manifestOutcomeHeld }
        let held = await engine.readForTests { $0.manifestOutcomeHeld }
        try #require(held, "setup: the throttled fetch's outcome waits for the release")
        await throttled.harness.source.release(throttled.extender.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        let firstEnd = throttled.firstEnd
        await engine.awaitCondition { ($0.state.throttles[origin] ?? .zero) > firstEnd }
        let extended = await engine.readForTests { $0.state.throttles[origin] }
        let end = try #require(extended, "setup: the origin stays throttled")
        try #require(end > firstEnd, "setup: B's 429 extends the throttle")
        return end
    }

    // MARK: A fetch-first ensureAvailable answered after a 429 extended the throttle (R-SYN-10, R-SYN-5; cycle-17 verifier)

    /// `ensureAvailable` answers a throttled manifest fetch with the time left until the throttle ends (F-37). It read
    /// that end from the fetch's outcome, which the fetch's turn computed; its answer comes after two awaits (the
    /// waiter's resumption and the store's availability read), and a transfer's 429 in either window extends the
    /// origin's throttle. The caller was then told to retry 30 s before the throttle ends, while a request made at the
    /// same moment is told the extended end (F-36's rule; the cycle-17 correctness verifier's PROBE-C17C-ENSURESTALE).
    /// The fetch's outcome is held from the caller here (`holdManifestOutcomeDelivery()`), so the order is fixed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: an ensureAvailable whose throttled manifest fetch is answered after a 429 extended the throttle reports the time left until the extended end", .timeLimit(.minutes(1)))
    func ensureReportsExtendedEnd() async throws {
        let throttled = try await Self.throttled()
        let harness = throttled.harness
        let engine = harness.engine
        let origin = harness.source.originID
        let missing = throttled.missing.identifier
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers([missing])) }
        let extended = try await Self.extendWhileHeld(throttled, caller: ensure)
        await engine.releaseManifestOutcomeDelivery()
        let result = await joinCancelling(ensure)
        let throttle = await engine.readForTests { $0.state.throttles[origin] }
        #expect(throttle == extended, "nothing moved the throttle after B's 429")
        let expected = extended.seconds(since: harness.time.monotonicNow())
        if case .failure(.serverUnavailable(retryAfter: let wait)) = result {
            #expect(wait == expected, "the caller is told when the extended throttle ends: \(String(describing: wait)), expected \(expected)")
        } else {
            Issue.record("a throttled fetch-first ensureAvailable that the store cannot answer is unavailable: \(result)")
        }
        let requests = await harness.source.manifestRequests.count
        #expect(requests == throttled.requests, "the throttle refuses the fetch before any request: \(requests - throttled.requests)")
        for token in throttled.tokens {
            await engine.releaseGroup(token)
        }
        await engine.shutdown()
    }

    // MARK: A throttled sync answered after a 429 extended the throttle (R-SYN-5, R-SYN-6; cycle-17 verifier)

    /// A run whose manifest fetch the throttle refuses settles `.blocked(.throttled(until:))` and leaves a pending run
    /// for the throttle's end. The run reported the end the fetch's outcome carried, while its pending run was scheduled
    /// at the origin's end when the run answered: a transfer's 429 between the two (the run's task resumes after the
    /// fetch's turn) left the caller's outcome and `syncFinished` 30 s short of the throttle and of the pending run
    /// (the cycle-17 correctness verifier's PROBE-C17C-RUNEND, which reached the order 13 times in 300 without a seam).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a sync whose manifest fetch the throttle refuses reports the origin's end when a 429 extends the throttle before the run answers", .timeLimit(.minutes(1)))
    func throttledRunReportsExtendedEnd() async throws {
        let throttled = try await Self.throttled()
        let harness = throttled.harness
        let engine = harness.engine
        let origin = harness.source.originID
        let run = Task { await engine.sync(.force) }
        let extended = try await Self.extendWhileHeld(throttled, caller: run)
        await engine.releaseManifestOutcomeDelivery()
        let outcome = await joinCancelling(run)
        let after = await engine.readForTests { engine in
            (engine.state.throttles[origin], engine.state.heap.deadline(for: .pendingRun), engine.state.pendingRun?.gate)
        }
        #expect(after.0 == extended, "nothing moved the throttle after B's 429")
        if case .blocked(.throttled(let until), _) = outcome {
            #expect(until == extended, "the run reports the origin's throttle end \(extended), not \(until)")
            #expect(after.1 == until, "the pending run waits for the end the run reports: \(String(describing: after.1)), reported \(until)")
        } else {
            Issue.record("the run is blocked by the throttle: \(outcome)")
        }
        #expect(after.2 == .throttle, "the pending run waits for the throttle: \(String(describing: after.2))")
        let requests = await harness.source.manifestRequests.count
        #expect(requests == throttled.requests, "the throttle refuses the fetch before any request: \(requests - throttled.requests)")
        for token in throttled.tokens {
            await engine.releaseGroup(token)
        }
        await engine.shutdown()
    }

    // MARK: An unknown-id resolve answered after a 429 extended the throttle (R-SYN-5, R-SYN-4; F-36's readers)

    /// The unknown-id waiters of a fetch the throttle refused are answered in token order, and a waiter whose id the
    /// newest manifest seen lists is admitted first (`store.admit`, an await). Every later waiter's answer was computed
    /// before those awaits, from the end the fetch's outcome carried: a transfer's 429 during an admission left it short
    /// of the origin's throttle (found by this cycle's review of F-36's readers). Here the manifest request is held at
    /// the source until both waiters are registered, its 429 throttles the origin for 30 s, the first waiter's
    /// admission is held at the store's metadata executor while B's 429 extends the throttle to 60 s, and then the
    /// second waiter is answered.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an unknown-id resolve that a throttled manifest fetch answers after an earlier waiter's admission reports the time left until the origin's extended end", .timeLimit(.minutes(1)))
    func unknownWaiterReportsExtendedEnd() async throws {
        let base = FakeRemoteSource()
        let gatedSource = ManifestRequestGate(base: base)
        let metadata = UnitHoldingGate()
        let harness = EngineHarness.make(
            source: base,
            tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0),
            metadata: metadata,
            remote: gatedSource
        )
        let bytesB = EngineFixture.bytes(6_601)
        let bytesY = EngineFixture.bytes(6_602)
        let b = EngineHarness.onDemand("b", bytesB)
        let y = EngineHarness.onDemand("y", bytesY)
        await harness.serveManifest([b])
        let engine = harness.engine
        let origin = base.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        // An unknown-id resolve fetches a newer manifest that lists Y but not its own id: the newest manifest seen lists
        // Y, the applied one does not.
        await harness.serveManifest([b, y], etag: "v2")
        let absent = await engine.awaitAsset(AssetID("w"), lane: .userInitiated)
        try #require(absent == .failure(.notFound), "setup: an id no manifest lists is not found: \(absent)")
        // B is held in flight.
        await base.script(b.transferID, [.hold, .stage(bytesB)])
        let token = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.active != nil }
        // Y's resolve starts a manifest fetch, held at the source until the second unknown-id waiter joins it.
        await base.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(30)))])
        await gatedSource.holdNext()
        let resolveY = Task { await engine.awaitAsset(y.identifier, lane: .userInitiated) }
        var manifestHolds = gatedSource.holds.makeAsyncIterator()
        _ = await manifestHolds.next()
        let resolveZ = Task { await engine.awaitAsset(AssetID("z"), lane: .userInitiated) }
        await untilFinishedOrCondition(resolveZ, engine) { $0.state.unknownWaiters.count == 2 }
        let registered = await engine.readForTests { $0.state.unknownWaiters.count }
        try #require(registered == 2, "setup: both unknown-id waiters joined the held fetch")
        // The fetch's 429 throttles the origin for 30 s; Y's admission (listed in the newest manifest) is held.
        await metadata.holdNext()
        await gatedSource.release()
        var unitHolds = metadata.holds.makeAsyncIterator()
        _ = await unitHolds.next()
        let throttle = await engine.readForTests { $0.state.throttles[origin] }
        let firstEnd = try #require(throttle, "setup: the manifest's 429 throttles the origin")
        // B's 429 extends the throttle to 60 s while Y's admission is held; Z is not answered yet.
        await base.release(b.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        await engine.awaitCondition { ($0.state.throttles[origin] ?? .zero) > firstEnd }
        let during = await engine.readForTests { ($0.state.throttles[origin], $0.state.unknownWaiters.count) }
        let extended = try #require(during.0, "setup: the origin stays throttled")
        try #require(during.1 == 2, "setup: neither waiter was answered before the extension: \(during.1)")
        await metadata.release()
        let answerZ = await joinCancelling(resolveZ)
        let expected = extended.seconds(since: harness.time.monotonicNow())
        if case .failure(.serverUnavailable(retryAfter: let wait)) = answerZ {
            #expect(wait == expected, "the waiter is told when the extended throttle ends: \(String(describing: wait)), expected \(expected)")
        } else {
            Issue.record("an unknown id that a throttled fetch cannot list is unavailable: \(answerZ)")
        }
        await engine.releaseGroup(token)
        await engine.shutdown()
        _ = await joinCancelling(resolveY)
    }

    // MARK: A run whose claim parked for space settles only while the ledger refuses it (R-SYN-6, R-SYN-11; cycle-17 verifier)

    /// A job parked `insufficientSpace` waits for the next free-space read (F-28): room another job's bytes in flight
    /// leave when it ends without committing is used at that read. A run whose working claim then finished counted its
    /// claim parked for space as blocked and settled `.blocked(.insufficientSpace)`, although the ledger admits the
    /// claim: its job was retired and the caller was told the volume lacks space (the cycle-17 correctness verifier's
    /// PROBE-C17C-INFLIGHT). Here a prefetch holder's 200 bytes are in flight with 450 bytes of room, so the gate parks the
    /// run's 300-byte claim beside its 100-byte one; the holder then ends with a 404, and the run's other claim finishes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose claim parked for space the ledger admits once a job in flight ended without committing fetches it instead of settling blocked for lack of space", .timeLimit(.minutes(1)))
    func runFetchesClaimTheLedgerAdmits() async throws {
        let reserve = StoragePolicy().reserveFreeBytes
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 4_000_000, opportunisticCapacity: reserve + 4_000_000)
        )
        let harness = EngineHarness.make(
            time: time,
            tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0),
            storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            fileSystem: fileSystem
        )
        let holder = EngineHarness.onDemand("h", EngineFixture.bytes(6_701, count: 200))
        await harness.serveManifest([holder])
        let engine = harness.engine
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await harness.source.script(holder.transferID, [.hold])
        let token = try await engine.registerGroup([holder.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[holder.transferID]?.active != nil }
        _ = try await EngineRegressionCycle6Tests.leaveRoom(450, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        // The run plans two bundled entries that fit the read together (400 of 450 bytes); beside the holder's 200 bytes
        // in flight the gate starts the small one and parks the large one.
        let bytes1 = EngineFixture.bytes(6_702, count: 100)
        let bytes2 = EngineFixture.bytes(6_703, count: 300)
        let first = EngineFixture.entry("r1", bytes1)
        let second = EngineFixture.entry("r2", bytes2)
        await harness.serveManifest([holder, first, second], etag: "v2")
        await harness.source.script(first.transferID, [.hold, .stage(bytes1)])
        await harness.source.script(second.transferID, [.stage(bytes2)])
        let run = Task { await engine.sync(.force) }
        await untilFinishedOrCondition(run, engine) { engine in
            engine.state.jobs[first.transferID]?.active != nil && engine.state.jobs[second.transferID]?.state == .blocked(.insufficientSpace)
        }
        let setup = await engine.readForTests { engine in
            (engine.state.jobs[first.transferID]?.active != nil, engine.state.jobs[second.transferID]?.state, engine.state.run?.id, engine.state.lastRunID)
        }
        try #require(setup.0 && setup.1 == .blocked(.insufficientSpace), "setup: r1 runs and r2 is parked for space: \(setup)")
        try #require(setup.2 != nil, "setup: the run is in progress")
        // The holder ends with a 404: its 200 bytes leave the ledger, which now admits r2; nothing reads free space.
        await harness.source.release(holder.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
        await engine.awaitCondition { $0.state.jobs[holder.transferID] == nil && $0.state.storeWorkRuns == 0 }
        let fits = await engine.readForTests { engine in
            engine.state.jobs[second.transferID].map { engine.spaceBlock($0) == nil }
        }
        try #require(fits == true, "setup: the ledger admits r2 once the holder's bytes left it: \(String(describing: fits))")
        // The run's other claim finishes; the run must fetch r2 rather than report a lack of space the ledger denies.
        await harness.source.release(first.transferID, with: .progress(received: 1, expected: nil))
        let outcome = await joinCancelling(run)
        if case .complete(let report) = outcome {
            #expect(report.fetched == 2, "the run fetched both of its assets: \(report.fetched)")
        } else {
            Issue.record("the run fetches the claim the ledger admits instead of settling: \(outcome)")
        }
        let after = await engine.readForTests { ($0.state.lastRunID, $0.invariantViolations()) }
        #expect(after.0 == setup.3, "no second run: \(after.0) after \(setup.3)")
        #expect(after.1.isEmpty, "\(after.1)")
        await engine.releaseGroup(token)
        await engine.shutdown()
    }

    /// The other branch of the same check: the jobs parked for space are re-checked in the pump's order, so a prefetch job
    /// parked ahead of the run's bulk claim takes the room the ledger gained, and the claim stays parked; the run then
    /// settles `.blocked(.insufficientSpace)` in the same turn, as before the fix, instead of waiting for an unrelated
    /// event (here the prefetch job stays in flight, so nothing else would end the run).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose claim parked for space loses the room the ledger gained to a job ranked ahead of it settles blocked for lack of space at once", .timeLimit(.minutes(1)))
    func runSettlesWhenRoomGoesAhead() async throws {
        let reserve = StoragePolicy().reserveFreeBytes
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 4_000_000, opportunisticCapacity: reserve + 4_000_000)
        )
        let harness = EngineHarness.make(
            time: time,
            tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0),
            storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            fileSystem: fileSystem
        )
        let holder = EngineHarness.onDemand("h", EngineFixture.bytes(6_801, count: 200))
        let ahead = EngineHarness.onDemand("p", EngineFixture.bytes(6_802, count: 300))
        await harness.serveManifest([holder, ahead])
        let engine = harness.engine
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await harness.source.script(holder.transferID, [.hold])
        await harness.source.script(ahead.transferID, [.hold])
        let holderToken = try await engine.registerGroup([holder.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[holder.transferID]?.active != nil }
        _ = try await EngineRegressionCycle6Tests.leaveRoom(450, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        // A prefetch job of 300 bytes does not fit beside the holder's 200 bytes in flight: it parks for space.
        let aheadToken = try await engine.registerGroup([ahead.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[ahead.transferID]?.state == .blocked(.insufficientSpace) && !$0.state.pumpFollowUpScheduled }
        let bytes1 = EngineFixture.bytes(6_803, count: 100)
        let bytes2 = EngineFixture.bytes(6_804, count: 300)
        let first = EngineFixture.entry("r1", bytes1)
        let second = EngineFixture.entry("r2", bytes2)
        await harness.serveManifest([holder, ahead, first, second], etag: "v2")
        await harness.source.script(first.transferID, [.hold, .stage(bytes1)])
        await harness.source.script(second.transferID, [.stage(bytes2)])
        let run = Task { await engine.sync(.force) }
        await untilFinishedOrCondition(run, engine) { engine in
            engine.state.jobs[first.transferID]?.active != nil && engine.state.jobs[second.transferID]?.state == .blocked(.insufficientSpace)
        }
        let setup = await engine.readForTests { engine in
            (engine.state.jobs[first.transferID]?.active != nil, engine.state.jobs[second.transferID]?.state, engine.state.run?.id, engine.state.lastRunID)
        }
        try #require(setup.0 && setup.1 == .blocked(.insufficientSpace) && setup.2 != nil, "setup: r1 runs and r2 is parked for space: \(setup)")
        // The holder ends with a 404: the ledger now admits the prefetch job or r2, not both.
        await harness.source.release(holder.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
        await engine.awaitCondition { $0.state.jobs[holder.transferID] == nil && $0.state.storeWorkRuns == 0 }
        let fits = await engine.readForTests { engine in
            (
                engine.state.jobs[second.transferID].map { engine.spaceBlock($0) == nil },
                engine.state.jobs[ahead.transferID]?.state
            )
        }
        try #require(fits.0 == true && fits.1 == .blocked(.insufficientSpace), "setup: the ledger admits r2 on its own, and the prefetch job is still parked: \(fits)")
        // r1 finishes: the re-check admits the prefetch job, ranked ahead, and the run settles in that turn.
        await harness.source.release(first.transferID, with: .progress(received: 1, expected: nil))
        await engine.awaitCondition { $0.state.jobs[first.transferID] == nil && $0.state.storeWorkRuns == 0 }
        let after = await engine.readForTests { engine in
            (engine.state.run?.settlement, engine.state.run == nil, engine.state.jobs[ahead.transferID]?.active != nil, engine.state.lastRunID)
        }
        #expect(after.2, "the re-check gives the room to the prefetch job ranked ahead of r2")
        let settled = after.1 || after.0 == .blocked(.insufficientSpace)
        #expect(settled, "the run settles blocked for lack of space in r1's turn: \(String(describing: after.0))")
        if !settled {
            // Ends the run the check left open, so the join below returns.
            await engine.shutdown()
        }
        let outcome = await joinCancelling(run)
        if case .blocked(.insufficientSpace, _) = outcome {
        } else {
            Issue.record("the sync caller is told the volume lacks space for r2: \(outcome)")
        }
        #expect(after.3 == setup.3, "no second run: \(after.3) after \(setup.3)")
        await engine.releaseGroup(aheadToken)
        await engine.releaseGroup(holderToken)
        await engine.shutdown()
    }

    /// The check's last step: when the re-check re-queues nothing, nothing else may check the run again. Here an earlier
    /// read's sweep re-queued a prefetch job that waits for a slot, so its bytes count ahead of the run's claim: the
    /// ledger admits the claim on its own, the re-check does not, and the run must settle in the same turn. Every slot
    /// stays taken by transfers of unknown size (which hold no ledger bytes), and a user-initiated job takes the slot the
    /// run's other claim frees, so no later dispatch checks the run.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose claim parked for space the ledger admits alone but not behind a re-queued job waiting for a slot settles blocked for lack of space at once", .timeLimit(.minutes(1)))
    func runSettlesWhenRequeuedJobWaitsAhead() async throws {
        let reserve = StoragePolicy().reserveFreeBytes
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 4_000_000, opportunisticCapacity: reserve + 4_000_000)
        )
        let harness = EngineHarness.make(
            time: time,
            tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0, preemptLowerLanes: false),
            storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            fileSystem: fileSystem
        )
        // Sizes in tens of kilobytes: this test reads free space again after the store wrote its index, which the
        // margins absorb.
        let holder = EngineHarness.onDemand("h", EngineFixture.bytes(6_901, count: 20_000))
        let ahead = EngineHarness.onDemand("p", EngineFixture.bytes(6_902, count: 30_000))
        // Transfers of unknown size: they take slots and hold no ledger bytes.
        let unsized = (0..<4).map { EngineFixture.entry("u\($0)", EngineFixture.bytes(6_910 + UInt64($0)), policy: .onDemand, size: false) }
        await harness.serveManifest([holder, ahead] + unsized)
        let engine = harness.engine
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        for entry in [holder, ahead] + unsized {
            await harness.source.script(entry.transferID, [.hold])
        }
        let first = try await engine.registerGroup([holder.identifier, unsized[0].identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[holder.transferID]?.active != nil && $0.state.jobs[unsized[0].transferID]?.active != nil }
        _ = try await EngineRegressionCycle6Tests.leaveRoom(45_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        let aheadToken = try await engine.registerGroup([ahead.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[ahead.transferID]?.state == .blocked(.insufficientSpace) && !$0.state.pumpFollowUpScheduled }
        // The run takes the third slot with r1, and the gate parks r2 for space at the fourth.
        let bytes1 = EngineFixture.bytes(6_903, count: 10_000)
        let bytes2 = EngineFixture.bytes(6_904, count: 30_000)
        let r1 = EngineFixture.entry("r1", bytes1)
        let r2 = EngineFixture.entry("r2", bytes2)
        await harness.serveManifest([holder, ahead] + unsized + [r1, r2], etag: "v2")
        await harness.source.script(r1.transferID, [.hold, .stage(bytes1)])
        await harness.source.script(r2.transferID, [.stage(bytes2)])
        let run = Task { await engine.sync(.force) }
        await untilFinishedOrCondition(run, engine) { engine in
            engine.state.jobs[r1.transferID]?.active != nil && engine.state.jobs[r2.transferID]?.state == .blocked(.insufficientSpace)
        }
        let setup = await engine.readForTests { engine in
            (engine.state.jobs[r1.transferID]?.active != nil, engine.state.jobs[r2.transferID]?.state, engine.state.run?.id, engine.state.lastRunID)
        }
        try #require(setup.0 && setup.1 == .blocked(.insufficientSpace) && setup.2 != nil, "setup: r1 runs and r2 is parked for space: \(setup)")
        // The holder ends with a 404, and two more unsized transfers take the free slots.
        await harness.source.release(holder.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
        await engine.awaitCondition { $0.state.jobs[holder.transferID] == nil && $0.state.storeWorkRuns == 0 }
        let second = try await engine.registerGroup([unsized[1].identifier, unsized[2].identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[unsized[1].transferID]?.active != nil && $0.state.jobs[unsized[2].transferID]?.active != nil }
        // A read re-queues the prefetch job (ranked ahead of r2), which waits for a slot; r2 does not fit behind it.
        await engine.refreshFreeSpace()
        let read = await engine.readForTests { engine in
            (engine.state.jobs[ahead.transferID]?.state, engine.state.jobs[r2.transferID]?.state, engine.state.jobs[r2.transferID].map { engine.spaceBlock($0) == nil })
        }
        try #require(read.0 == .queued && read.1 == .blocked(.insufficientSpace), "setup: the prefetch job waits in the queue and r2 stays parked: \(read)")
        try #require(read.2 == true, "setup: the ledger admits r2 on its own: \(read)")
        // A user-initiated transfer of unknown size waits for a slot and takes the one r1 frees.
        let user = Task { await engine.awaitAsset(unsized[3].identifier, lane: .userInitiated) }
        await untilFinishedOrCondition(user, engine) { $0.state.jobs[unsized[3].transferID]?.state == .queued }
        await harness.source.release(r1.transferID, with: .progress(received: 1, expected: nil))
        await engine.awaitCondition { engine in
            engine.state.jobs[r1.transferID] == nil && engine.state.storeWorkRuns == 0 && engine.state.jobs[unsized[3].transferID]?.active != nil
        }
        let after = await engine.readForTests { engine in
            (engine.state.run?.settlement, engine.state.run == nil, engine.state.jobs[ahead.transferID]?.state, engine.state.lastRunID)
        }
        #expect(after.2 == .queued, "the prefetch job still waits for a slot: \(String(describing: after.2))")
        let settled = after.1 || after.0 == .blocked(.insufficientSpace)
        #expect(settled, "the run settles blocked for lack of space in r1's turn: \(String(describing: after.0))")
        if !settled {
            // Ends the run the check left open, so the join below returns.
            await engine.shutdown()
        }
        let outcome = await joinCancelling(run)
        if case .blocked(.insufficientSpace, _) = outcome {
        } else {
            Issue.record("the sync caller is told the volume lacks space for r2: \(outcome)")
        }
        #expect(after.3 == setup.3, "no second run: \(after.3) after \(setup.3)")
        for token in [first, second, aheadToken] {
            await engine.releaseGroup(token)
        }
        await engine.shutdown()
        _ = await joinCancelling(user)
    }
}

/// A `FakeRemoteSource` whose next manifest request waits until the test releases it (or the fetch is cancelled), so a
/// test registers more unknown-id waiters on the fetch before its outcome. An actor: no lock (C1).
@available(macOS 15.0, iOS 18.0, *)
actor ManifestRequestGate: RemoteSource {
    nonisolated let base: FakeRemoteSource
    /// One element each time a manifest request is held; iterating it ends on cancellation.
    nonisolated let holds: AsyncStream<Void>
    private let holdSignal: AsyncStream<Void>.Continuation
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?

    init(base: FakeRemoteSource) {
        self.base = base
        (self.holds, self.holdSignal) = AsyncStream.makeStream(of: Void.self)
    }

    nonisolated var originID: String {
        self.base.originID
    }

    nonisolated var capabilities: RemoteSourceCapabilities {
        self.base.capabilities
    }

    /// Holds the next manifest request.
    func holdNext() {
        self.armed = true
    }

    /// Lets the held request go on, or disarms a hold nothing reached.
    func release() {
        self.armed = false
        self.held?.resume()
        self.held = nil
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        if self.armed {
            self.armed = false
            // REENTRANCY: nothing: resumed once by `release()`, also on the fetch's cancellation; the base fetch below
            // reads no state of this actor.
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.held = continuation
                    self.holdSignal.yield()
                }
            } onCancel: {
                Task {
                    // REENTRANCY: nothing: `release()` is idempotent.
                    await self.release()
                }
            }
        }
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        return try await self.base.fetchManifest(request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.transfer(request)
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.reattachedTransfers()
    }

    func cancelTransfer(_ name: StagingFileName) async {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.cancelTransfer(name)
    }

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.reclaimSourceCopies(report)
    }

    func sourceCopyBytes() async -> Int64 {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.sourceCopyBytes()
    }

    func handleBackgroundEvents(identifier: String) async {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.handleBackgroundEvents(identifier: identifier)
    }

    func invalidate() async {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.invalidate()
    }
}

/// A blocking executor that holds the next unit it is given until the test releases it, and signals each hold through a
/// stream whose iteration ends on cancellation; a release before the unit arrives lets it pass (L4-R17).
actor UnitHoldingGate: BlockingExecutor {
    /// One element each time a unit is held.
    nonisolated let holds: AsyncStream<Void>
    private let holdSignal: AsyncStream<Void>.Continuation
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?

    init() {
        (self.holds, self.holdSignal) = AsyncStream.makeStream(of: Void.self)
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        if self.armed {
            self.armed = false
            // REENTRANCY: nothing: `work` is the caller's value; only `release()` resumes the unit.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.held = continuation
                self.holdSignal.yield()
            }
        }
        return work()
    }

    /// Holds the next unit.
    func holdNext() {
        self.armed = true
    }

    /// Lets the held unit run, or disarms a hold nothing reached.
    func release() {
        self.armed = false
        self.held?.resume()
        self.held = nil
    }
}
