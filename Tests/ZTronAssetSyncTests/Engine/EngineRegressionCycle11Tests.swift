import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions and pins from the verifiers of close-out cycle 10 (cycle 11 of the level-4 close-out; orchestrator ruling
/// L4-R18, `docs/adr-drafts/f.md`, F-31).
@Suite("Engine regressions, close-out cycle 11")
struct EngineRegressionCycle11Tests {
    // MARK: At most one immediate retry per network edge (R-SYN-13 "without polling"; L4-C10-00)

    /// PROBE-C10R-1: a prefetch member runs, the path drops and returns (one satisfied edge), and every attempt from then
    /// on fails `.offline` while the path reads satisfied. The first failure arrives after the edge, so it is retried at
    /// once (F-30); the retry started after that edge, so its failure waits for the next one. Each attempt records the
    /// edge count it started under (`ActiveAttempt.edgeSerial`); without that record (mutant M-EDGESTART) every failure
    /// looks later than the edge and the member restarts with no backoff, for ever. The wait ends on either outcome: the
    /// member waits `failed(whenOnline)`, or a third attempt began.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-13: after one network edge a member whose attempts keep failing offline while the path reads satisfied starts twice, then waits for the next edge",
        .timeLimit(.minutes(1))
    )
    func offlineFailuresRetryOncePerEdge() async throws {
        let (harness, transfer) = try await EngineRegressionCycle10Tests.runningPrefetchMember(seed: 11_301)
        let engine = harness.engine
        let requests = await engine.readForTests { $0.state.metrics.transferRequests }
        for conditions in [EngineRegressionCycle10Tests.offline, DeviceConditions.unrestricted] {
            await harness.conditions.send(conditions)
            await engine.awaitCondition { $0.state.conditions == conditions }
        }
        await harness.source.script(transfer, Array(repeating: FakeTransferStep.fail(.offline(.noConnection)), count: 24))
        await engine.awaitCondition { engine in
            engine.state.jobs[transfer]?.state == .failed(.whenOnline) || engine.state.metrics.transferRequests >= requests + 2
        }
        #expect(await engine.readForTests { $0.state.jobs[transfer]?.state } == .failed(.whenOnline), "the retry's failure waits for the next edge")
        #expect(await harness.source.starts.count == 2, "the first attempt and one retry after the edge")
        let timers = await engine.readForTests { engine in
            engine.state.heap.entries.filter { deadline in
                if case .retry(transfer, _) = deadline.reason {
                    return true
                }
                return false
            }.count
        }
        #expect(timers == 0, "no timer brings it back")
        // The next edge retries it once more, and only once.
        let before = await engine.readForTests { $0.state.metrics.transferRequests }
        for conditions in [EngineRegressionCycle10Tests.offline, DeviceConditions.unrestricted] {
            await harness.conditions.send(conditions)
            await engine.awaitCondition { $0.state.conditions == conditions }
        }
        await engine.awaitCondition { engine in
            let started = engine.state.metrics.transferRequests
            return (started == before + 1 && engine.state.jobs[transfer]?.state == .failed(.whenOnline)) || started >= before + 2
        }
        #expect(await engine.readForTests { $0.state.metrics.transferRequests } == before + 1, "one attempt for the second edge")
        #expect(await harness.source.starts.count == 3)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: Lane queues within twice their live entries after jobs leave (R-SYN-3; found writing L4-C10-01's test)

    /// The lane queues compacted their stale entries only when an entry was added (`enqueue`): a released handle whose
    /// members waited queued behind busy slots left every one of their entries stored, so the queues held far more than
    /// twice the jobs left until the next enqueue, which the engine's own invariant check reports (sync.md §7.2: the
    /// queues stay within twice their live entries). Both a release in one turn and one over several turns.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-3: lane queues stay within twice their live entries after a released handle's queued members leave, with nothing queued since",
        .timeLimit(.minutes(1)),
        arguments: [200, SyncEngine.releasesPerTurn + 64]
    )
    func releasedQueuedMembersLeaveNoStaleEntries(count: Int) async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        let blockers = (0..<3).map { EngineHarness.onDemand("b\($0)", EngineFixture.bytes(11_320 + UInt64($0), count: 300)) }
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "q%04d", $0), EngineFixture.bytes(12_000 + UInt64($0), count: 300)) }
        await harness.serveManifest(blockers + members)
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        _ = try await engine.registerGroup(blockers.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.inFlight.count == 3 }
        let handle = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count + 3 }
        #expect(await engine.readForTests { $0.state.queues.storedCount } >= count, "setup: every member waits in its queue")
        await engine.releaseGroup(handle)
        await engine.awaitCondition { $0.state.jobs.count == 3 && $0.state.releasing.isEmpty && !$0.state.releaseFollowUpScheduled }
        let stored = await engine.readForTests { $0.state.queues.storedCount }
        #expect(stored <= 2 * 3 + 16, "\(stored) entries stored for 3 jobs")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.shutdown()
    }

    // MARK: A released member that regains an interest keeps its place (R-SYN-3; L4-C10-01)

    /// Where the members of the released handle wait when the new interests arrive.
    enum Place: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Still in their queue: no scan met them yet (no slot was free).
        case inPlace
        /// Set aside by the release's own pump (its in-flight members' slots freed).
        case setAside

        var testDescription: String {
            self.rawValue
        }
    }

    /// The members that regain an interest, in the order their interests arrive (not their queue order).
    static let rejoined = [574, 520, 547]

    /// PROBE-C10R-3: the members of a released handle that gain an interest while the release continues were each pushed
    /// to the front of their lane, so members joined in one turn were dispatched in reverse join order and ahead of work
    /// queued before them. They must keep their original places: earlier queued work first, then the members in the
    /// order they were queued, whatever the order of the new interests. A handle of `releasesPerTurn` + 64 members is
    /// released and, in the same actor turn, three of the 64 still waiting gain an interest (system interests, the
    /// synchronous stand-in for a second handle's join); the dispatch order is the engine's own (`startSequence`), not
    /// the order the attempts reach the fake.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-3: members of a released handle that regain an interest keep their queue order and never pass earlier queued work",
        .timeLimit(.minutes(1)),
        arguments: Place.allCases
    )
    func rejoinedMembersKeepTheirPlaces(place: Place) async throws {
        let count = SyncEngine.releasesPerTurn + 64
        let harness = EngineHarness.make()
        let engine = harness.engine
        let blockers = (0..<3).map { EngineHarness.onDemand("b\($0)", EngineFixture.bytes(11_310 + UInt64($0), count: 300)) }
        let early = EngineHarness.onDemand("early", EngineFixture.bytes(11_319, count: 300))
        // Zero-padded, so the handle's join order (its sorted identifiers) is the members' numeric order.
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "m%04d", $0), EngineFixture.bytes(11_400 + UInt64($0), count: 300)) }
        await harness.serveManifest(blockers + [early] + members)
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        // The three prefetch slots: the blockers (in place) or the handle's first members (set aside).
        let blockerToken: InterestToken?
        if place == .inPlace {
            blockerToken = try await engine.registerGroup(blockers.map(\.identifier), lane: .prefetch).get()
            await engine.awaitCondition { $0.state.inFlight.count == 3 }
            _ = try await engine.registerGroup([early.identifier], lane: .prefetch).get()
            await engine.awaitCondition { $0.state.jobs[early.transferID]?.state == .queued }
        } else {
            blockerToken = nil
        }
        let handle = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        let jobs = place == .inPlace ? count + 4 : count
        await engine.awaitCondition { $0.state.jobs.count == jobs && $0.state.inFlight.count == 3 }
        await engine.waitForAllHandles()
        let wanted = Self.rejoined.map { members[$0] }
        let watched = (place == .inPlace ? [early] : []) + wanted
        let turn = await engine.readForTests { engine in
            engine.performReleaseGroup(handle)
            let aside = wanted.filter { member in
                engine.state.queues.asideEntries.contains { $0.transfer == member.transferID && engine.isValid($0) }
            }.count
            let releasing = !engine.state.releasing.isEmpty
            for member in wanted {
                engine.addSystemInterest(entry: member, lane: .prefetch)
            }
            if let blockerToken {
                // Frees the three slots: the pump dispatches the head of the queue.
                engine.performReleaseGroup(blockerToken)
            } else {
                engine.pump()
            }
            let order = watched.compactMap { entry in
                engine.state.jobs[entry.transferID]?.active.map { (entry.identifier, $0.startSequence) }
            }.sorted { $0.1 < $1.1 }.map(\.0)
            return (aside, releasing, order)
        }
        #expect(turn.0 == (place == .setAside ? wanted.count : 0), "setup: the members wait \(place)")
        #expect(turn.1, "setup: the release continues in a later turn")
        let expected = (place == .inPlace ? [early.identifier] : []) + Self.rejoined.sorted().prefix(place == .inPlace ? 2 : 3).map { members[$0].identifier }
        #expect(turn.2 == expected, "\(place): dispatched \(turn.2.map(\.rawValue)), expected \(expected.map(\.rawValue))")
        await engine.awaitCondition { !$0.state.releaseFollowUpScheduled }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.shutdown()
    }

    /// The lane queues' places (`LaneQueues.Entry.place`): appends take ascending places and front pushes places before
    /// every other; entries put back (`reinstate`) in any order are merged at their places in one pass, after entries of
    /// the same place (a stale copy left in place), and `restoreAside` merges the valid set-aside entries the same way.
    @Test("R-SYN-3: lane queues put entries back at their places, in place order, whatever the order they come back in")
    func laneQueuesReinstateAtTheirPlaces() {
        var queues = LaneQueues()
        let now = MonotonicInstant(nanoseconds: 1)
        var places: [UInt64: Int64] = [:]
        for ticket in UInt64(1)...6 {
            places[ticket] = queues.push(LaneQueues.Entry(ticket: ticket, transfer: EngineUnitTests.transfer(Int(ticket)), queuedAt: now), to: .prefetch)
        }
        let front = queues.push(LaneQueues.Entry(ticket: 7, transfer: EngineUnitTests.transfer(7), queuedAt: now), to: .prefetch, front: true)
        #expect(places.values.allSatisfy { front < $0 } && places[1]! < places[2]!, "appends ascend, a front push precedes them")
        var live = Set<UInt64>(1...7)
        let isValid: (LaneQueues.Entry) -> Bool = { live.contains($0.ticket) }
        // 2 and 4 are set aside by a scan that takes 7, then come back with new tickets (12, 14), 4 first.
        #expect(queues.pop(.prefetch, isValid: isValid, setAside: { $0.ticket == 2 || $0.ticket == 4 }, accept: { $0.ticket == 7 || $0.ticket == 5 })?.ticket == 7)
        #expect(queues.asideEntries.isEmpty, "the scan found 7 first, before meeting them")
        #expect(queues.pop(.prefetch, isValid: isValid, setAside: { $0.ticket == 2 || $0.ticket == 4 }, accept: { $0.ticket == 5 })?.ticket == 5)
        #expect(queues.asideEntries.map(\.ticket) == [2, 4])
        live.subtract([2, 4, 5, 7])
        live.formUnion([12, 14])
        queues.reinstate(LaneQueues.Entry(ticket: 14, transfer: EngineUnitTests.transfer(4), queuedAt: now, place: places[4]!), to: .prefetch)
        queues.reinstate(LaneQueues.Entry(ticket: 12, transfer: EngineUnitTests.transfer(2), queuedAt: now, place: places[2]!), to: .prefetch)
        #expect(queues.storedCount == 7, "three queued, two aside (now stale), two put back")
        let order = (0..<4).compactMap { _ in queues.pop(.prefetch, isValid: isValid)?.ticket }
        #expect(order == [1, 12, 3, 14], "back at their places between 1, 3 and 6: \(order)")
        // restoreAside: 6 is set aside and restored behind a later append.
        #expect(queues.pop(.prefetch, isValid: isValid, setAside: { $0.ticket == 6 }, accept: { _ in false }) == nil)
        queues.push(LaneQueues.Entry(ticket: 8, transfer: EngineUnitTests.transfer(8), queuedAt: now), to: .prefetch)
        live.insert(8)
        queues.restoreAside(isValid: isValid)
        #expect((0..<2).compactMap { _ in queues.pop(.prefetch, isValid: isValid)?.ticket } == [6, 8], "6 waited before 8")
        #expect(queues.pop(.prefetch, isValid: isValid) == nil)
    }

    /// The reachability rule added in this cycle (review of close-out cycle 10, L4-C10-13) is not vacuous: a queued job
    /// whose entry went stale (no valid entry in any queue, put back or aside) is reported.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: the invariant check reports a queued job that waits in no queue", .timeLimit(.minutes(1)))
    func strandedQueuedJobIsReported() async throws {
        let (harness, _, entries) = try await EngineRegressionCycle8Tests.started(count: 4, seed: 11_501)
        let engine = harness.engine
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == 4 && $0.state.inFlight.count == 3 }
        #expect(await engine.invariantViolations().isEmpty, "a healthy engine")
        let queued = try #require(await engine.readForTests { engine in
            engine.state.jobs.values.first { $0.state == .queued }?.transfer
        })
        let stranded = await engine.violations { state in
            state.jobs[queued]?.ticket += 1
        }
        #expect(stranded.contains("1 queued jobs wait in no queue"), "\(stranded)")
        #expect(await engine.invariantViolations().isEmpty, "the check restored the state")
        await engine.shutdown()
    }
}
