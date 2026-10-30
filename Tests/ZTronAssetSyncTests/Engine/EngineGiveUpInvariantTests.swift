import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineGroupClaimTests {
    /// The engine's invariant check tells a large give-up's leftover claims from a released group that is still
    /// registered (L5-R22(4); Stage 3, S3-B-082). A join's give-up of more than `releasesPerTurn` claims of a group that
    /// stays registered leaves the rest to the release follow-up (`releasing` holds the registered token with claims
    /// only, L5-R15): that is no violation, in the give-up's own turn or later. A `Release` that still holds members
    /// while its group is registered is one, and is still reported.
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 43.7 to 44.6 s beside a second TSan process at a
    /// load of 20 to 35 (74 % of 60 s) and 18.5 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 33.0 to 33.1 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-4: invariantViolations reports a registered group in releasing only while its release holds members, not a large give-up's leftover claims", .timeLimit(.minutes(3)))
    func giveUpLeftoverClaimsAreNoViolation() async throws {
        let count = SyncEngine.releasesPerTurn + 24
        let entries = (0..<count).map { EngineHarness.onDemand(String(format: "g%04d", $0), EngineFixture.bytes(UInt64(6_800 + $0), count: 32)) }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        try await EngineSingleFlightTests.applied(entries, harness: harness)
        let engine = harness.engine
        let ids = entries.map(\.identifier)
        let predecessor = try await engine.registerGroup(ids, lane: .prefetch).get()
        await engine.awaitCondition { engine in
            engine.state.jobs.count >= count && entries.allSatisfy { engine.state.jobs[$0.transferID]?.interests[predecessor] != nil }
        }
        let successor = await engine.inOneTurn { engine -> InterestToken in
            let successor = engine.recordGroup(ids, lane: .prefetch).token
            engine.performReleaseGroup(predecessor)
            return successor
        }
        await engine.awaitCondition { $0.state.releasing.isEmpty }
        let giveUp = await engine.inOneTurn { engine -> (leftover: Bool, registered: Bool, violations: [String]) in
            engine.endClaims(of: successor)
            let leftover = engine.state.releasing[successor].map { $0.members.isEmpty && !$0.claims.isEmpty } ?? false
            return (leftover, engine.state.groups[successor] != nil, engine.invariantViolations().filter { $0.contains("released and registered") })
        }
        #expect(giveUp.leftover && giveUp.registered, "setup: the registered group's give-up left claims for the follow-up: \(giveUp)")
        #expect(giveUp.violations.isEmpty, "a large give-up's leftover claims are no violation: \(giveUp.violations)")
        await engine.awaitCondition { $0.state.releasing.isEmpty && $0.state.claimHeld.isEmpty }
        // A release that still holds members while its group is registered is reported.
        let token = try await engine.registerGroup([ids[0]], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[entries[0].transferID]?.interests[token] != nil }
        let flagged = await engine.inOneTurn { engine -> [String] in
            guard let group = engine.state.groups[token] else {
                return ["setup: the group is not registered"]
            }
            engine.state.releasing[token] = Release(members: [ids[0]], pending: [ids[0]: entries[0].transferID])
            let violations = engine.invariantViolations().filter { $0.contains("released and registered") }
            engine.state.releasing[token] = nil
            engine.state.groups[token] = group
            return violations
        }
        #expect(flagged.count == 1, "a release holding members while registered is reported: \(flagged)")
        await engine.releaseGroup(token)
        await engine.releaseGroup(successor)
        await engine.shutdown()
    }
}
