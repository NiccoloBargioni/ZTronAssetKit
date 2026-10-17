import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 17 of the level-4 close-out (`docs/adr-drafts/f.md`, F-37): a run that settled blocked for
/// lack of space while a follow-up free-space sweep still owed its parked claim a re-check; the network-edge and
/// conditions branches of the owed-claim check end to end; the `ensureAvailable` branch of the throttle-extension
/// answers; and the retry-after of a fetch-first `ensureAvailable` a throttle refuses. No test here moves the clock; every wait is a condition, a held seam or a join that ends on cancellation
/// (L4-R17).
@Suite("Engine regressions, close-out cycle 17")
struct EngineRegressionCycle17Tests {
    /// The engine of the cycle-16 correctness verifier's PROBE-SPACEOWED, set up to the point where a free-space read that
    /// found room has re-queued `readmissionsPerTurn` members parked `insufficientSpace` and owes the rest, the run's
    /// bulk claim among them, to a follow-up sweep that the hold keeps waiting, while the run's working claim is held in
    /// flight. A re-queued member that starts is held in flight; the others wait in the queue.
    @available(macOS 15.0, iOS 18.0, *)
    struct SpaceOwed {
        let harness: EngineHarness
        let fileSystem: FakeFileSystem
        /// The run's working claim (60 bytes, held in flight).
        let first: ManifestEntry
        /// The run's claim parked `insufficientSpace` (300 bytes).
        let second: ManifestEntry
        let run: Task<SyncOutcome, Never>
        let runID: SyncRunID
        let lastRunID: UInt64
        /// The prefetch group of `readmissionsPerTurn` + 8 members.
        let members: InterestToken
        /// The prefetch group of the two holders.
        let holders: InterestToken
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func spaceOwed() async throws -> SpaceOwed {
        let count = SyncEngine.readmissionsPerTurn + 8
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
        let holders = (0..<2).map { EngineHarness.onDemand("h\($0)", EngineFixture.bytes(40_000 + UInt64($0), count: 300)) }
        var members: [ManifestEntry] = []
        var memberBytes: [Data] = []
        for index in 0..<count {
            let bytes = EngineFixture.bytes(41_000 + UInt64(index), count: 300)
            memberBytes.append(bytes)
            members.append(EngineHarness.onDemand("m\(index)", bytes))
        }
        await harness.serveManifest(holders + members)
        let engine = harness.engine
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        // Two prefetch holders stay in flight: with the ballast below they leave 100 bytes of headroom.
        for holder in holders {
            await harness.source.script(holder.transferID, [.hold])
        }
        let holderToken = try await engine.registerGroup(holders.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.inFlight.count == 2 }
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(700, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        // Each member a sweep re-queues is held in flight once it starts, so the free slot holds one and the rest wait in
        // the queue: none of the 520 is downloaded (the members' transfers doubled the time of other tests in the suite,
        // close-out cycle 18, F-38), and the run's claims see the same parks and sweeps.
        for (member, bytes) in zip(members, memberBytes) {
            await harness.source.script(member.transferID, [.hold, .stage(bytes)])
        }
        // A prefetch group whose members (300 bytes each) do not fit the headroom: every member parks `insufficientSpace`.
        let token = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.spaceParked.count == count && !$0.state.pumpFollowUpScheduled && $0.state.laneParksOwed.isEmpty }
        let parkedStates = await engine.readForTests { engine in Set(engine.state.spaceParked.compactMap { engine.state.jobs[$0]?.state }) }
        try #require(parkedStates == [.blocked(.insufficientSpace)], "setup: every member parks insufficientSpace: \(parkedStates)")
        // A run plans two bundled entries: the small one fits the headroom the holders leave, the large one does not.
        let bytes1 = EngineFixture.bytes(42_001, count: 60)
        let bytes2 = EngineFixture.bytes(42_002, count: 300)
        let first = EngineFixture.entry("r1", bytes1)
        let second = EngineFixture.entry("r2", bytes2)
        await harness.serveManifest(holders + members + [first, second], etag: "v2")
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
        let runID = try #require(setup.2, "setup: the run is in progress")
        await engine.holdSpaceSweepFollowUps()
        // The volume gains room for every parked job: the read's sweep re-queues `readmissionsPerTurn` of them, prefetch
        // members first, and owes the rest, the run's bulk claim among them, to a follow-up sweep, which the hold keeps
        // waiting.
        try fileSystem.removeItem(at: ballast)
        await engine.refreshFreeSpace()
        await engine.awaitCondition { $0.state.spaceSweepFollowUpWaiting }
        let owed = await engine.readForTests { ($0.state.jobs[second.transferID]?.state, $0.state.spaceSweepFollowUp != nil) }
        try #require(owed.0 == .blocked(.insufficientSpace) && owed.1, "setup: the run's claim waits for the follow-up sweep: \(owed)")
        return SpaceOwed(harness: harness, fileSystem: fileSystem, first: first, second: second, run: run, runID: runID, lastRunID: setup.3, members: token, holders: holderToken)
    }

    // MARK: A run waits for the claim a follow-up space sweep still owes a re-check (R-SYN-6, R-SYN-11; cycle-16 verifier)

    /// A free-space read that finds room re-queues at most `readmissionsPerTurn` of the jobs parked `insufficientSpace`,
    /// in the pump's order (prefetch before bulk), and owes the rest to a follow-up sweep, an owned task of its own. When
    /// the run's last working claim finished before that sweep, the run settled `.blocked(.insufficientSpace)` although
    /// the latest read admits its bulk claim: the claim's job was retired, no pending run was set, and the sync caller
    /// was told the volume lacks space (the cycle-16 correctness verifier's PROBE-SPACEOWED). The follow-up is held here
    /// (`holdSpaceSweepFollowUps()`), so the order is fixed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose claim parked for space a follow-up free-space sweep still owes a re-check waits for it instead of settling blocked for lack of space", .timeLimit(.minutes(1)))
    func runWaitsForSpaceSweepFollowUp() async throws {
        let owed = try await Self.spaceOwed()
        let engine = owed.harness.engine
        // The run's working claim finishes; only the claim the follow-up sweep owes a re-check is left.
        await owed.harness.source.release(owed.first.transferID, with: .progress(received: 1, expected: nil))
        await engine.awaitCondition { $0.state.jobs[owed.first.transferID] == nil && $0.state.storeWorkRuns == 0 }
        let waiting = await engine.readForTests { engine in
            (engine.state.run?.id, engine.state.run?.settlement, engine.state.lastRunID, engine.state.jobs[owed.second.transferID]?.state)
        }
        #expect(waiting.0 == owed.runID, "the run is still in progress: \(String(describing: waiting.0))")
        #expect(waiting.1 == nil, "the run waits for the claim a follow-up sweep owes a re-check instead of settling: \(String(describing: waiting.1))")
        #expect(waiting.2 == owed.lastRunID, "no run started: \(waiting.2) after \(owed.lastRunID)")
        #expect(waiting.3 == .blocked(.insufficientSpace), "the claim's job survives, waiting for the follow-up sweep: \(String(describing: waiting.3))")
        // The follow-up sweep admits the claim. The bulk claim ranks after the members held in flight or queued, so the
        // members' group is released; the claim's transfer then runs and the run completes.
        await engine.releaseSpaceSweepFollowUps()
        let readmitted = await engine.readForTests { $0.state.jobs[owed.second.transferID]?.state }
        #expect(readmitted != .blocked(.insufficientSpace), "the follow-up sweep admits the run's claim: \(String(describing: readmitted))")
        await engine.releaseGroup(owed.members)
        let outcome = await joinCancelling(owed.run)
        if case .complete(let report) = outcome {
            #expect(report.fetched == 2, "the run fetched both of its assets: \(report.fetched)")
        } else {
            Issue.record("the run completes once the volume has room for its claim: \(outcome)")
        }
        await engine.releaseGroup(owed.holders)
        await engine.shutdown()
    }

    /// The other half of the fix: while the follow-up sweep was owed, the run's claim counted as working, so the sweep
    /// itself must check the run. A sweep that neither parks nor re-queues anything (here the volume lost its room again
    /// before the sweep ran, so the read's room cannot hold even the smallest parked job) checked nothing, and the run
    /// stayed open with nothing left to settle it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose claim parked for space the owed follow-up sweep does not admit settles blocked for lack of space once that sweep ran", .timeLimit(.minutes(1)))
    func runSettlesAfterSpaceSweepFollowUpAdmitsNothing() async throws {
        let owed = try await Self.spaceOwed()
        let engine = owed.harness.engine
        // The run's working claim finishes: of the run's claims only the one the follow-up owes a re-check is left (the
        // re-queued members are no claims of the run).
        await owed.harness.source.release(owed.first.transferID, with: .progress(received: 1, expected: nil))
        await engine.awaitCondition { $0.state.jobs[owed.first.transferID] == nil && $0.state.storeWorkRuns == 0 }
        // The volume loses its room again before the follow-up runs; this read's own sweep stops at once (the room cannot
        // hold the smallest parked job) and leaves the owed follow-up as it is.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(700, harness: owed.harness, fileSystem: owed.fileSystem)
        await engine.refreshFreeSpace()
        let beforeSweep = await engine.readForTests { engine in
            (engine.state.run?.id, engine.state.run?.settlement, engine.state.jobs[owed.second.transferID]?.state, engine.state.spaceSweepFollowUpWaiting)
        }
        try #require(beforeSweep.3, "setup: the follow-up sweep is still owed")
        #expect(beforeSweep.0 == owed.runID && beforeSweep.1 == nil, "the run waits for the owed follow-up sweep: \(beforeSweep)")
        #expect(beforeSweep.2 == .blocked(.insufficientSpace), "the claim waits for the owed follow-up sweep: \(String(describing: beforeSweep.2))")
        // The follow-up sweep runs in the release's turn, admits nothing, and checks the run.
        await engine.releaseSpaceSweepFollowUps()
        let afterSweep = await engine.readForTests { engine in
            (engine.state.run?.settlement, engine.state.spaceSweepFollowUp, engine.state.lastRunID, engine.state.run == nil)
        }
        #expect(afterSweep.1 == nil, "no further sweep is owed: \(String(describing: afterSweep.1))")
        // Once settled, the run's own task may already have ended the run (`state.run` cleared); the outcome below tells
        // which settlement it was.
        let settled = afterSweep.3 || afterSweep.0 == .blocked(.insufficientSpace)
        #expect(settled, "the run settles blocked for lack of space in the follow-up sweep's turn: \(String(describing: afterSweep.0))")
        if !settled {
            // Ends the run the sweep left open, so the join below returns.
            await engine.shutdown()
        }
        let outcome = await joinCancelling(owed.run)
        if case .blocked(.insufficientSpace, _) = outcome {
        } else {
            Issue.record("the sync caller is told the volume lacks space: \(outcome)")
        }
        #expect(afterSweep.2 == owed.lastRunID, "no run started: \(afterSweep.2) after \(owed.lastRunID)")
        await engine.releaseGroup(owed.members)
        await engine.releaseGroup(owed.holders)
        await engine.shutdown()
    }

    // MARK: The owed-claim check's network-edge and conditions branches, end to end (R-SYN-6; cycle-16 verifier)

    /// The launch run's two bundled claims run in both slots; `edge` decides how the bulk claim stops: failed `whenOnline`
    /// by an offline transfer while the device is offline, or parked by Low Data Mode while a user-initiated waiter keeps
    /// the other claim running. A prefetch group of `readmissionsPerTurn` + 8 members, parked by the same lane-wide gate,
    /// ranks ahead of the bulk claim. With the re-admission follow-up held, an unrestricted element re-queues
    /// `readmissionsPerTurn` members and owes the rest, the bulk claim among them, to the follow-up: through `edgeOwed`
    /// (a satisfied network edge) or through the conditions pass (`readmissionsOwed`). F-36's predicate test pinned
    /// `OwedRequeues.contains`; this pins the predicate's construction in `checkRunSettled` (the requirements verifier's
    /// PROBE-C16R; mutants that pass an empty `edge` or empty `lanes` there survived every committed test).
    @available(macOS 15.0, iOS 18.0, *)
    static func runWaitsForReadmissionOwedClaim(edge: Bool) async throws {
        let prefetchCount = SyncEngine.readmissionsPerTurn + 8
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        var entries: [ManifestEntry] = []
        for index in 0..<prefetchCount {
            let bytes = EngineFixture.bytes(UInt64(30_000 + index))
            let entry = EngineHarness.onDemand("p\(index)", bytes)
            entries.append(entry)
            // A re-queued member that starts is held in flight and the others wait in the queue, so none of the 520 is
            // downloaded (close-out cycle 18, F-38); the run's claims see the same parks and re-admissions.
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        let bytes1 = EngineFixture.bytes(7_101)
        let bytes2 = EngineFixture.bytes(7_102)
        let working = EngineFixture.entry("r1", bytes1)
        let claim = EngineFixture.entry("r2", bytes2)
        await harness.serveManifest(entries + [working, claim])
        // Both claims are held in flight; the bulk claim's next attempt stages its bytes.
        await harness.source.script(working.transferID, [.hold, .stage(bytes1)])
        await harness.source.script(claim.transferID, [.hold, .stage(bytes2)])
        let engine = harness.engine
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        await engine.awaitCondition { $0.state.jobs[working.transferID]?.active != nil && $0.state.jobs[claim.transferID]?.active != nil }
        var user: Task<Result<AssetLocation, AssetError>, Never>?
        if edge {
            await harness.conditions.send(EngineRegressionCycle10Tests.offline)
            await engine.awaitCondition { $0.state.conditions == EngineRegressionCycle10Tests.offline }
            await harness.source.release(claim.transferID, with: .failed(.offline(.noConnection)))
            await engine.awaitCondition { $0.state.jobs[claim.transferID]?.state == .failed(.whenOnline) }
        } else {
            // The working claim gains a user-initiated waiter, so Low Data Mode keeps it running while it parks the bulk claim.
            let waiter = Task { await engine.awaitAsset(working.identifier, lane: .userInitiated) }
            user = waiter
            await untilFinishedOrCondition(waiter, engine) { $0.state.jobs[working.transferID]?.lane == .userInitiated }
            await harness.conditions.send(EngineRegressionCycle10Tests.constrained)
            await engine.awaitCondition { $0.state.conditions == EngineRegressionCycle10Tests.constrained && $0.state.jobs[claim.transferID]?.state.isLaneParked == true }
        }
        let token = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        let parkedTarget = edge ? prefetchCount : prefetchCount + 1
        await engine.awaitCondition { $0.state.laneParked.count == parkedTarget && $0.state.laneParksOwed.isEmpty }
        let launch = await engine.readForTests { ($0.state.run?.id, $0.state.lastRunID) }
        let launchRun = try #require(launch.0, "setup: the launch run is in progress")
        // The unrestricted element re-queues `readmissionsPerTurn` members and owes the rest, the bulk claim among them,
        // to the follow-up turn, which the hold keeps waiting.
        await engine.holdReadmissionFollowUps()
        await harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.conditions == .unrestricted && $0.state.readmissionFollowUpWaiting }
        let owed = await engine.readForTests { engine in
            (
                engine.state.edgeOwed.contains(claim.transferID),
                engine.state.readmissionsOwed.contains(.conditions),
                engine.state.originOwed.contains(claim.transferID),
                engine.state.jobs[claim.transferID]?.state
            )
        }
        if edge {
            try #require(owed.0 && owed.3 == .failed(.whenOnline), "setup: a network edge owes the failed claim its re-queue: \(owed)")
        } else {
            try #require(!owed.0 && owed.1 && owed.3?.isLaneParked == true, "setup: a conditions pass owes the lane-parked claim its re-queue: \(owed)")
        }
        try #require(!owed.2, "setup: no origin owes the claim a re-queue")
        // The working claim finishes: of the run's claims only the one the follow-up owes a re-queue is left (the
        // re-queued members are no claims of the run).
        await harness.source.release(working.transferID, with: .progress(received: 1, expected: nil))
        await engine.awaitCondition { $0.state.jobs[working.transferID] == nil && $0.state.storeWorkRuns == 0 }
        let waiting = await engine.readForTests { engine in
            (engine.state.run?.id, engine.state.run?.settlement, engine.state.lastRunID)
        }
        #expect(waiting.0 == launchRun, "the launch run is still in progress: \(String(describing: waiting.0))")
        #expect(waiting.1 == nil, "the run waits for its owed claim instead of settling: \(String(describing: waiting.1))")
        #expect(waiting.2 == launch.1, "no run started: \(waiting.2) after \(launch.1)")
        // The follow-up re-queues the owed jobs. The bulk claim ranks after the members held in flight or queued, so their
        // group is released; the claim's next attempt then stages its bytes and the run completes.
        await engine.releaseReadmissionFollowUps()
        let requeued = await engine.readForTests { $0.state.jobs[claim.transferID]?.state }
        #expect(requeued == .queued, "the follow-up re-queues the run's claim: \(String(describing: requeued))")
        await engine.releaseGroup(token)
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) && $0.state.jobs.isEmpty }
        let finished = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        let end = await engine.readForTests { ($0.state.lastRunID, $0.invariantViolations()) }
        if case .syncFinished(_, .complete(let report))? = finished {
            #expect(report.fetched == 2, "the run fetched both of its assets: \(report.fetched)")
        } else {
            Issue.record("the launch run completes once its owed claim ran: \(String(describing: finished))")
        }
        #expect(end.0 == launch.1, "no second run: \(end.0) after \(launch.1)")
        #expect(end.1.isEmpty, "\(end.1)")
        if let user {
            let answer = await joinCancelling(user)
            #expect((try? answer.get()) != nil, "the user-initiated waiter gets the working claim's location: \(answer)")
        }
        await probe.stop()
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose failed-whenOnline claim a network-edge re-admission turn still owes a re-queue waits for it instead of settling offline", .timeLimit(.minutes(1)))
    func runWaitsForEdgeOwedClaim() async throws {
        try await Self.runWaitsForReadmissionOwedClaim(edge: true)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose claim a lane-wide park left that a conditions re-admission turn still owes a re-queue waits for it instead of settling blocked by the policy", .timeLimit(.minutes(1)))
    func runWaitsForConditionsOwedClaim() async throws {
        try await Self.runWaitsForReadmissionOwedClaim(edge: false)
    }

    // MARK: An ensureAvailable member is answered when a later 429 extends the throttle (R-SYN-5, R-SYN-10; cycle-16 verifier)

    /// F-36 decided that `interactiveMaxWait` bounds a user-initiated request's whole wait for an origin throttle, so a
    /// 429 that extends the throttle beyond it answers the user-initiated `resolve` and `ensureAvailable` interests of
    /// the jobs the throttle parked (`answerThrottledUsers`). Every earlier test used `awaitAsset` waiters only; a mutant
    /// that drops `.ensure` from the answered interests survived (the requirements verifier's PROBE-C16R-ENSURE). The
    /// user-initiated waiter of the first job, parked by the same throttle, is answered in the same turn under both, so
    /// its answer marks the turn as done without the test waiting on the behaviour it checks.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an ensureAvailable member waiting for a short throttle is answered once a later 429 extends the throttle beyond interactiveMaxWait", .timeLimit(.minutes(1)))
    func ensureMemberAnsweredOnExtension() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let bytesA = EngineFixture.bytes(6_301)
        let bytesB = EngineFixture.bytes(6_302)
        let bytesM = EngineFixture.bytes(6_303)
        let a = EngineHarness.onDemand("a", bytesA)
        let b = EngineHarness.onDemand("b", bytesB)
        let m = EngineHarness.onDemand("m", bytesM)
        await harness.serveManifest([a, b, m])
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        // Two user-initiated transfers take both slots.
        await harness.source.script(b.transferID, [.hold, .stage(bytesB)])
        await harness.source.script(a.transferID, [.hold, .stage(bytesA)])
        await harness.source.script(m.transferID, [.stage(bytesM)])
        let callerB = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        let callerA = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.active != nil && $0.state.jobs[a.transferID]?.active != nil }
        // `ensureAvailable` queues the missing member behind them.
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers([m.identifier])) }
        await untilFinishedOrCondition(ensure, engine) { $0.state.jobs[m.transferID]?.interests.values.contains { $0.kind == .ensure } == true }
        // A's 429 throttles the origin for 1 s and frees a slot: the gate parks the member, whose interest waits (1 s is
        // within interactiveMaxWait).
        await harness.source.release(a.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(1))))
        await untilFinishedOrCondition(ensure, engine) { $0.state.jobs[m.transferID]?.state.isThrottleParked == true }
        let parked = await engine.readForTests { engine in
            (
                engine.state.jobs[m.transferID]?.interests.values.contains { $0.lane == .userInitiated && $0.kind == .ensure } == true,
                engine.state.jobs[a.transferID]?.state.isThrottleParked == true
            )
        }
        try #require(parked.0 && parked.1, "setup: the member waits with its user-initiated ensure interest, and A is parked: \(parked)")
        let start = harness.time.monotonicNow()
        // B's 429 extends the throttle to 60 s: the answers turn gives A's waiter and the member's ensure interest the
        // fail-fast answer in one turn.
        await harness.source.release(b.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        let answeredA = await joinCancelling(callerA)
        #expect(EngineRegressionCycle16Tests.failedFast(answeredA), "A's waiter fails fast: \(answeredA)")
        let after = await engine.readForTests { engine in
            (engine.state.jobs[m.transferID]?.interests.values.contains { $0.kind == .ensure } == true, engine.state.throttles[origin])
        }
        #expect(!after.0, "the member's job no longer holds the ensure interest")
        let end = try #require(after.1, "the origin stays throttled")
        #expect(end.seconds(since: start) > SyncTuning().interactiveRetry.interactiveMaxWait, "the throttle ends beyond interactiveMaxWait")
        if after.0 {
            // Ends the wait the answers turn left, so the join below returns.
            await engine.shutdown()
        }
        let result = await joinCancelling(ensure)
        if case .success(let report) = result {
            #expect(report.missing == 1 && report.present == 0, "the member is answered without its bytes: \(report)")
        } else if !after.0 {
            Issue.record("ensureAvailable reports the scope's availability once its member was answered: \(result)")
        }
        if !after.0 {
            await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) && !$0.state.throttleAnswersScheduled }
            let violations = await engine.readForTests { $0.invariantViolations() }
            #expect(violations.isEmpty, "\(violations)")
        }
        await engine.shutdown()
        _ = await joinCancelling(callerB)
    }

    // MARK: A throttled fetch-first ensureAvailable reports the throttle's end (R-SYN-10, R-SYN-5; cycle-16 verifier)

    /// `ensureAvailable` fetches the manifest first; when the origin's throttle refuses that fetch and the store cannot
    /// answer the scope, the caller gets `.serverUnavailable`. It dropped the throttle's end (`retryAfter: nil`), while
    /// the same refusal answers an unknown-id `resolve` with the time left and ARCHITECTURE §7.6 maps a 429 to
    /// `.serverUnavailable(retryAfter:)` (the requirements verifier's first ensure probe). F-37 records why the request
    /// still fails at once rather than waiting.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: an ensureAvailable whose manifest fetch an origin throttle refuses reports the time left until the throttle ends", .timeLimit(.minutes(1)))
    func throttledEnsureReportsRetryAfter() async throws {
        let harness = EngineHarness.make()
        let bytesA = EngineFixture.bytes(6_401)
        let bytesM = EngineFixture.bytes(6_402)
        let a = EngineHarness.onDemand("a", bytesA)
        let m = EngineHarness.onDemand("m", bytesM)
        await harness.serveManifest([a, m])
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        // A prefetch transfer's 429 throttles the origin for 30 s.
        await harness.source.script(a.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(30))), .stage(bytesA)])
        let token = try await engine.registerGroup([a.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state.isThrottleParked == true }
        let throttle = await engine.readForTests { $0.state.throttles[origin] }
        let end = try #require(throttle, "setup: the 429 throttles the origin")
        let requests = await harness.source.manifestRequests.count
        let result = await engine.ensureAvailable(scope: .identifiers([m.identifier]))
        let expected = end.seconds(since: harness.time.monotonicNow())
        if case .failure(.serverUnavailable(retryAfter: let wait)) = result {
            #expect(wait == expected, "the caller is told when the throttle ends: \(String(describing: wait)), expected \(expected)")
        } else {
            Issue.record("a throttled fetch-first ensureAvailable that the store cannot answer is unavailable: \(result)")
        }
        let after = await harness.source.manifestRequests.count
        #expect(after == requests, "the throttle refuses the fetch before any request: \(after - requests)")
        await engine.releaseGroup(token)
        await engine.shutdown()
    }
}
