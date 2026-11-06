import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineLaneTests {
    /// The lane of the released handle whose members regain a user-initiated interest.
    enum RejoinCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// A prefetch handle: the re-join changes the members' lane (prefetch to user-initiated).
        case laneChange
        /// A user-initiated handle: the re-join comes from user work at the members' own lane.
        case userWork

        var testDescription: String {
            self.rawValue
        }

        var handleLane: AssetPriority {
            self == .laneChange ? .prefetch : .userInitiated
        }
    }

    /// Members of a released handle that regain an interest keep their queue positions whatever lane the interest brings
    /// (L4-R24(4); Stage 3, S3-B-065): with every slot busy, a handle of `releasesPerTurn` + 64 members waits queued, then
    /// one user-initiated job is queued after them (the busy slots run user-initiated work, so it preempts none); in one turn the handle is released and three of its members still
    /// waiting regain a user-initiated interest (system interests, the synchronous stand-in for a second handle's join),
    /// out of their queue order. When the slots free, the three are dispatched first, in their queue order, then the job
    /// queued after them: a re-join that changes lane, or comes from user work, goes back to its place in the queue its
    /// lane selects (R-SYN-3: a request for a queued asset jumps the queue), not to the back. The dispatch order is the
    /// engine's own (`startSequence`).
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 39.4 to 40.8 s beside a second TSan process at a
    /// load of 20 to 35 (68 % of 60 s) and 17.1 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-3: members of a released handle that regain a user-initiated interest keep their queue positions instead of going to the back",
        .timeLimit(.minutes(3)),
        arguments: RejoinCase.allCases
    )
    func rejoinedMembersKeepTheirPlacesAcrossLanes(rejoin: RejoinCase) async throws {
        let count = SyncEngine.releasesPerTurn + 64
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 3, reservedInteractiveSlots: 0))
        let engine = harness.engine
        let blockers = (0..<3).map { EngineHarness.onDemand("b\($0)", EngineFixture.bytes(11_510 + UInt64($0), count: 300)) }
        let later = EngineHarness.onDemand("later", EngineFixture.bytes(11_519, count: 300))
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "m%04d", $0), EngineFixture.bytes(11_600 + UInt64($0), count: 300)) }
        await harness.serveManifest(blockers + [later] + members)
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        // The blockers run at the user-initiated lane, so the later user-initiated job cannot preempt one of them.
        let blockerToken = try await engine.registerGroup(blockers.map(\.identifier), lane: .userInitiated).get()
        await engine.awaitCondition { $0.state.inFlight.count == 3 }
        let handle = try await engine.registerGroup(members.map(\.identifier), lane: rejoin.handleLane).get()
        await engine.awaitCondition { $0.state.jobs.count == count + 3 }
        await engine.waitForAllHandles()
        let wanted = [574, 520, 547].map { members[$0] }
        let watched = wanted + [later]
        let turn = await engine.readForTests { engine in
            engine.addSystemInterest(entry: later, lane: .userInitiated)
            engine.performReleaseGroup(handle)
            let releasedOnly = wanted.allSatisfy { member in engine.state.jobs[member.transferID].map { engine.isReleasedOnly($0) } == true }
            for member in wanted {
                engine.addSystemInterest(entry: member, lane: .userInitiated)
            }
            // Frees the three slots: the pump dispatches the head of the user-initiated queue.
            engine.performReleaseGroup(blockerToken)
            let order = watched.compactMap { entry in
                engine.state.jobs[entry.transferID]?.active.map { (entry.identifier, $0.startSequence) }
            }.sorted { $0.1 < $1.1 }.map(\.0)
            return (releasedOnly, order)
        }
        #expect(turn.0, "setup: the three members were wanted only by the released handle")
        let expected = [520, 547, 574].map { members[$0].identifier }
        #expect(turn.1 == expected, "\(rejoin): dispatched \(turn.1.map(\.rawValue)), expected \(expected.map(\.rawValue))")
        await engine.awaitCondition { !$0.state.releaseFollowUpScheduled }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.shutdown()
    }
}
