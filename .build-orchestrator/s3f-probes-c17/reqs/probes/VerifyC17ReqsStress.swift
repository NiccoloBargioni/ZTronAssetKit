import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch stress probes (s3f close-out verification, cycle 17, requirements lens). Never committed. Each runs committed
/// barrier tests' own bodies in concurrent copies (the committed suite is `.serialized`; these are not), so a race between
/// a test's steps and the engine's owned tasks shows as a failure (S3-R16 1(d)).
@Suite("VerifyC17ReqsStress")
struct VerifyC17ReqsStress {
    /// PROBE-C17R-RETRY-END-STRESS: `barrierRetriesAFailedPublicationWithNothingOfItsEnd` (WindowTests `:195`, cycle 17's
    /// fix of the cycle-16 flake `reqs-1`) in 24 concurrent copies, as PROBE-C16R-RETRY-END-STRESS ran the old steps.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17R-RETRY-END-STRESS", .timeLimit(.minutes(3)), arguments: 0..<24)
    func retryEndStress(_ copy: Int) async throws {
        try await EngineFollowBarrierTests().barrierRetriesAFailedPublicationWithNothingOfItsEnd()
    }

    /// PROBE-C17R-NEW-STRESS: every scenario test cycle 17 added or changed, in both orders, in concurrent copies.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C17R-NEW-STRESS", .timeLimit(.minutes(3)), arguments: 0..<3, LaneDropVisit.allCases)
    func newStress(_ copy: Int, _ visit: LaneDropVisit) async throws {
        let t = EngineFollowBarrierTests()
        async let a1: Void = t.barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits(visit, .afterVerdict)
        async let a2: Void = t.barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits(visit, .beforeVerdict)
        async let a3: Void = t.barrierJoinsAnIDMappedBackAfterTheSpaceVerdictThatWaits(visit)
        async let a4: Void = t.barrierLeavesAPassedPublicationsInterestToItsOutcome(visit)
        async let a5: Void = t.barrierAnswersAnIDMovedBackDuringAPublicationWithItsOutcome(visit)
        async let a6: Void = t.barrierDecidesA429OnAnInterestTheDrainTakesOffBeforeAVerdict(visit)
        async let a7: Void = t.barrierLeavesAnAdmittedUnlistedIDToTheVerdictThatWaits(visit)
        try await a1; try await a2; try await a3; try await a4; try await a5; try await a6; try await a7
        for ending in EngineFollowBarrierTests.HopEnding.allCases {
            try await t.barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent(visit, ending)
        }
        for ending in EngineFollowBarrierTests.VerdictLaneEnding.allCases {
            try await t.barrierDecidesA429OnTheLaneAWaitingVerdictLeaves(visit, ending)
        }
        if visit == .sweepFollowsFirst {
            try await t.barrierRetriesAFailedPublicationWithNothingOfItsEnd()
        }
    }
}
