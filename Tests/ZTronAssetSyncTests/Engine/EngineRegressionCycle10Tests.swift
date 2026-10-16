import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 9 found in WP-F (cycle 10 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-30).
@Suite("Engine regressions, close-out cycle 10")
struct EngineRegressionCycle10Tests {
    /// A satisfied path that Low Data Mode constrains (the prefetch lane's policy refuses it by default).
    static let constrained = DeviceConditions(network: NetworkConditions(satisfied: true, expensive: false, constrained: true), power: PowerConditions(lowPowerMode: false, thermal: .nominal))

    /// No network, nominal power.
    static let offline = DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal))

    /// One on-demand 300-byte entry, absent after a first sync, and a prefetch handle of it whose attempt runs and holds
    /// its handle.
    @available(macOS 15.0, iOS 18.0, *)
    static func runningPrefetchMember(seed: UInt64) async throws -> (EngineHarness, TransferID) {
        let harness = EngineHarness.make(time: ManualTimeSource())
        let entry = EngineHarness.onDemand("c\(seed)", EngineFixture.bytes(seed, count: 300))
        await harness.serveManifest([entry])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        _ = try await harness.engine.registerGroup([entry.identifier], lane: .prefetch).get()
        let transfer = entry.transferID
        await harness.engine.awaitCondition { $0.state.jobs[transfer]?.state == .downloading }
        await harness.engine.waitForAllHandles()
        return (harness, transfer)
    }

    /// The job's epoch (a new attempt takes a new one).
    @available(macOS 15.0, iOS 18.0, *)
    static func epoch(_ engine: SyncEngine, _ transfer: TransferID) async -> UInt64? {
        await engine.readForTests { $0.state.jobs[transfer]?.epoch }
    }

    // MARK: A policy pause whose block cleared before the pause arrived (T17; PROBE-C9C-1a, 1b)

    /// PROBE-C9C-1a: a constrained path refuses the prefetch lane, so the running member is paused (§11.3); the path is
    /// unrestricted again before the transport's `.paused` reaches the engine (both elements in one actor turn, as the
    /// watcher applies two buffered elements). The re-admission of the second element cannot see the member, which still
    /// downloads; `paused()` then parked it `blocked(policy(constrainedNetwork))` under conditions that admit its lane,
    /// and nothing re-queued it until a later conditions element or a user request (T17: blocked → queued once the gate
    /// admits). It must start again at once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-7: a member paused for a policy that cleared before its pause arrived is re-queued and starts again",
        .timeLimit(.minutes(1))
    )
    func policyPauseClearedBeforeItArrives() async throws {
        let (harness, transfer) = try await Self.runningPrefetchMember(seed: 11_001)
        let engine = harness.engine
        let first = try #require(await Self.epoch(engine, transfer))
        await engine.readForTests { engine in
            engine.apply(Self.constrained)
            engine.apply(.unrestricted)
        }
        #expect(await harness.source.controlLog.contains { $0.transfer == transfer && $0.control == .pause }, "setup: the constrained path paused the member")
        // Until the pause has reached the engine: the member is parked, or it runs again in a new attempt.
        await engine.awaitCondition { engine in
            guard let job = engine.state.jobs[transfer] else {
                return true
            }
            return job.state.kind == .blocked || job.epoch != first
        }
        let state = await engine.readForTests { $0.state.jobs[transfer]?.state }
        #expect(state == .downloading, "the member runs again, not parked under conditions that admit its lane: \(String(describing: state))")
        await engine.waitForAllHandles()
        #expect(await harness.source.starts.count == 2, "a second attempt started")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// PROBE-C9C-1b: the same flap through the conditions source, two elements sent back to back (Low Data Mode switched
    /// on and off, which `NWPathMonitor` reports as two path updates); the verifier saw the member left parked in 50 of 50
    /// rounds. Twenty rounds on one member: each must end with the member running (a new attempt when it was paused).
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-7: a Low Data Mode flap reported as two conditions elements never leaves a paused prefetch member parked (20 rounds)",
        .timeLimit(.minutes(1))
    )
    func lowDataModeFlapLeavesNoMemberParked() async throws {
        let (harness, transfer) = try await Self.runningPrefetchMember(seed: 11_002)
        let engine = harness.engine
        var paused = 0
        var parked = 0
        for round in 0..<20 {
            let before = try #require(await Self.epoch(engine, transfer))
            // Each round's unrestricted element differs from the last round's (Low Power Mode, which the prefetch lane
            // runs in by default), so the wait below sees this round's element applied, not the last one's.
            let restored = DeviceConditions(network: DeviceConditions.unrestricted.network, power: PowerConditions(lowPowerMode: round.isMultiple(of: 2), thermal: .nominal))
            await harness.conditions.send(Self.constrained)
            await harness.conditions.send(restored)
            // Until the second element is applied and the member settled: parked, running again in a new attempt, or
            // never paused (the source keeps only the newest element, so the first may be dropped).
            await engine.awaitCondition { engine in
                guard engine.state.conditions == restored, let job = engine.state.jobs[transfer] else {
                    return engine.state.jobs[transfer] == nil
                }
                return job.state.kind == .blocked || job.epoch != before || (job.state == .downloading && job.active?.policyPause == nil)
            }
            // A round the first element reached paused the member (the engine's own record: the source records the
            // control from the handle's thread).
            let after = await engine.readForTests { engine in
                (engine.state.jobs[transfer]?.state, engine.state.jobs[transfer]?.epoch)
            }
            if after.0?.kind == .blocked || after.1 != before {
                paused += 1
            }
            guard after.0 == .downloading else {
                parked += 1
                break
            }
            await engine.waitForAllHandles()
        }
        #expect(parked == 0, "the member was left parked after \(paused) paused rounds")
        #expect(paused > 0, "setup: at least one round paused the member")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: An offline failure that arrives after the network returned (R-SYN-13; PROBE-C9C-3)

    /// PROBE-C9C-3: the path drops while a prefetch member runs (it is not paused: offline is no policy) and returns (a
    /// satisfied edge) while the member still downloads, so the edge re-queues nothing; the transfer then reports
    /// `.offline` (URLSession's error lags the path monitor). The member was failed `whenOnline` and waited for an edge
    /// that had already passed: the path stays satisfied, no deadline was armed, and it was never retried (R-SYN-13 [MUST]:
    /// assets that failed offline are retried when the path becomes satisfied). It must start again at once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-13: a member whose offline failure arrives after the network returned is retried at once, not left waiting for an edge that already passed",
        .timeLimit(.minutes(1))
    )
    func offlineFailureAfterTheEdgeIsRetried() async throws {
        let (harness, transfer) = try await Self.runningPrefetchMember(seed: 11_003)
        let engine = harness.engine
        let first = try #require(await Self.epoch(engine, transfer))
        await harness.conditions.send(Self.offline)
        await engine.awaitCondition { $0.state.conditions == Self.offline }
        await harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.conditions == .unrestricted }
        #expect(await engine.readForTests { $0.state.jobs[transfer]?.epoch } == first, "setup: the member still runs its first attempt")
        await harness.source.script(transfer, [.fail(.offline(.noConnection))])
        await engine.awaitCondition { engine in
            guard let job = engine.state.jobs[transfer] else {
                return true
            }
            return job.state.kind == .failed || job.epoch != first
        }
        let state = await engine.readForTests { $0.state.jobs[transfer]?.state }
        #expect(state == .downloading, "the member is retried, not failed waiting for a network edge: \(String(describing: state))")
        await engine.waitForAllHandles()
        #expect(await harness.source.starts.count == 2, "a second attempt started")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// The other order must keep waiting for an edge: the path drops, returns and drops again while the member runs, and
    /// then the transfer reports `.offline`. The member waits `failed(whenOnline)` (no attempt into a path that reads
    /// unsatisfied), and the next satisfied edge retries it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-13: a member whose offline failure arrives after the network dropped again waits for the next edge and is retried there",
        .timeLimit(.minutes(1))
    )
    func offlineFailureAfterASecondDropWaitsForTheNextEdge() async throws {
        let (harness, transfer) = try await Self.runningPrefetchMember(seed: 11_004)
        let engine = harness.engine
        let first = try #require(await Self.epoch(engine, transfer))
        for conditions in [Self.offline, DeviceConditions.unrestricted, Self.offline] {
            await harness.conditions.send(conditions)
            await engine.awaitCondition { $0.state.conditions == conditions }
        }
        await harness.source.script(transfer, [.fail(.offline(.noConnection))])
        await engine.awaitCondition { engine in
            guard let job = engine.state.jobs[transfer] else {
                return true
            }
            return job.state.kind == .failed || job.epoch != first
        }
        #expect(await engine.readForTests { $0.state.jobs[transfer]?.state } == .failed(.whenOnline), "the member waits for the network")
        #expect(await harness.source.starts.count == 1, "no attempt starts while the path reads unsatisfied")
        await harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.jobs[transfer].map { $0.epoch != first } ?? true }
        #expect(await engine.readForTests { $0.state.jobs[transfer]?.state } == .downloading, "the next edge retries it")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: A released member another interest wants during the release (R-CAR-4; the set-aside of close-out cycle 10)

    /// Since cycle 10 a scan takes the queue entries of jobs only released groups want out of their queue (each is
    /// stepped over once, C2), so such a job waits in no queue until the release has removed its interest. An interest
    /// that joins it meanwhile at its own lane (a second prefetch handle's join; here a system interest, the synchronous
    /// stand-in) re-queues nothing in `relane`, so `addInterest` must queue it again, or it would wait for the release's
    /// last turn while a live interest wants it. More members than one turn releases wait behind three running ones; in
    /// one actor turn the handle is released (its pump sets the remaining members aside), then the last member gains an
    /// interest and the engine pumps: that member must start in this turn.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-CAR-4: a member of a released handle that another interest wants while the release continues starts at once",
        .timeLimit(.minutes(1))
    )
    func releasedMemberWantedAgainStartsAtOnce() async throws {
        let count = SyncEngine.releasesPerTurn + 64
        let (harness, _, entries) = try await EngineRegressionCycle8Tests.started(count: count, seed: 11_101)
        let engine = harness.engine
        let token = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.inFlight.count == 3 }
        await engine.waitForAllHandles()
        let last = try #require(entries.last)
        let turn = await engine.readForTests { engine in
            engine.performReleaseGroup(token)
            let aside = engine.state.queues.asideEntries.contains { $0.transfer == last.transferID && engine.isValid($0) }
            engine.addSystemInterest(entry: last, lane: .prefetch)
            engine.pump()
            return (aside, engine.state.releasing.isEmpty, engine.state.jobs[last.transferID]?.state)
        }
        #expect(turn.0, "setup: the release's pump set the member aside")
        #expect(!turn.1, "setup: the release continues in a later turn")
        #expect(turn.2 == .downloading, "the member starts in the turn its new interest arrived: \(String(describing: turn.2))")
        await engine.awaitCondition { !$0.state.releaseFollowUpScheduled }
        #expect(await engine.readForTests { $0.state.jobs.count } == 1, "only the member the new interest wants keeps a job")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
