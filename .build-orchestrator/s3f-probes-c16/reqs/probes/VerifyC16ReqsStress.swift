import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch stress probes (s3f close-out verification, cycle 16, requirements lens). Never committed. Each runs a
/// committed barrier test's own body in concurrent copies (the committed suite is `.serialized`; these are not), so a
/// race between the test's steps and the engine's owned tasks shows as a failure.
@Suite("VerifyC16ReqsStress")
struct VerifyC16ReqsStress {
    /// PROBE-C16R-RETRY-STRESS: `barrierAnswersAPassedJobsRetryAsVisitedFirst`, sweep-first (the branch f6ba277 fixed),
    /// in 24 concurrent copies, as the cycle-15 correctness verifier's stress probe ran the old steps.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16R-RETRY-STRESS", .timeLimit(.minutes(3)), arguments: 0..<24)
    func retryStress(_ copy: Int) async throws {
        try await EngineFollowBarrierTests().barrierAnswersAPassedJobsRetryAsVisitedFirst(copy % 6 == 5 ? .followVisitedFirst : .sweepFollowsFirst)
    }

    /// PROBE-C16R-NEW-STRESS: every test cycle 16 added, in both orders, in `copies` concurrent copies each.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16R-NEW-STRESS", .timeLimit(.minutes(3)), arguments: 0..<3, LaneDropVisit.allCases)
    func newStress(_ copy: Int, _ visit: LaneDropVisit) async throws {
        let t = EngineFollowBarrierTests()
        async let a1: Void = t.barrierDecidesA429BetweenDrainTurnsOnItsJobsOwnInterests(visit)
        async let a2: Void = t.barrierLeavesAPassedIdToAPublicationsSpaceRetry(visit)
        async let a3: Void = t.barrierGivesASpaceVerdictOnlyToTheJobThatFailed(visit)
        async let a4: Void = t.barrierLeavesAnIdMovedBackAndAwayToThePublication(visit)
        async let a5: Void = t.barrierSpendsTheRerouteOfAVisitThatFindsNothingMoved(visit)
        async let a6: Void = t.barrierSpendsTheRerouteForTheSameFollowsLaterVisits(visit)
        try await a1; try await a2; try await a3; try await a4; try await a5; try await a6
        async let b1: Void = t.barrierAnswersAnIdALaterApplyMovedWithAWaiting404(visit)
        async let b2: Void = t.barrierAnswersAnIdALaterApplyMovedWithAWaitingSpaceVerdict(visit)
        async let b3: Void = t.barrierAnswersAnIdALaterApplyMovedWithAWaitingRetryAtTheCap(visit)
        async let b4: Void = t.barrierMovesALaterApplysIdFromAJobItsWaitingRetryLeft(visit)
        async let b5: Void = t.barrierMovesALaterApplysIdFromAJobItsWaitingSpaceRetryLeft(visit)
        async let b6: Void = t.barrierSupersedesAFailedJobEveryIdOfWhichMovedBeforeItsFailure(visit)
        try await b1; try await b2; try await b3; try await b4; try await b5; try await b6
        async let c1: Void = t.barrierSupersedesAFailedJobAClaimWouldKeep(visit)
        async let c2: Void = t.barrierPassesAPublicationFailingInItsBookkeeping(visit)
        async let c3: Void = t.barrierMovesTheIdsOfAnApplyInsideAPublicationFailure(visit)
        try await c1; try await c2; try await c3
        for ending in EngineFollowBarrierTests.VerdictLaneEnding.allCases {
            try await t.barrierDecidesA429OnTheLaneAWaitingVerdictLeaves(visit, ending)
        }
        if visit == .sweepFollowsFirst {
            try await t.barrierRetriesAFailedPublicationWithNothingOfItsEnd()
        }
    }
}
