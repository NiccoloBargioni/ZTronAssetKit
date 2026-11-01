import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Whom a waiting exit verdict answers, as `followedLane` reads it (`verdictAnswers`, `jobAtVerdict`; Stage 3 close-out
/// cycle 17): the drain gives the verdict and then moves the ids later applies moved, so a 429 counts an interest the
/// verdict leaves to move and not one it answers. `verdictLane` pins the endings that decide a 429's lane through a user
/// interest; a non-user interest decides it only when nothing else counts and the job's own lane is the user's, so its
/// answers are pinned here against what each verdict's replay does (`giveVerdict`, `replayThrottle`,
/// `decideSpaceFailure`): a resolution answers everyone; a retry those its count reaches the cap of and, when its
/// `Retry-After` exceeds the cap of the lane the job keeps, everyone (`retryLater`); a park its fail-fast's waiters and
/// ensures (`failFast`); a re-queue, an edge's fresh attempt and a pause that does not park nobody.
extension EngineFollowBarrierTests {
    /// One expectation of `verdictAnswersMirrorTheReplays`: what `verdictAnswers` said and what the replay does.
    struct VerdictAnswerCase: Sendable {
        /// The verdict, the job and the interest.
        let label: String
        /// `verdictAnswers`.
        let answers: Bool
        /// Whether the verdict's replay answers the interest.
        let expected: Bool
    }

    /// The verdicts and jobs of `verdictAnswersMirrorTheReplays`, read on a harness engine that is not started: the
    /// interactive policy caps two attempts and a `Retry-After` of 30 s, the background one four attempts and 3,600 s.
    /// U is a user waiter, W a prefetch waiter, G a prefetch group's member: the fail-fast answers U and W, never G.
    @available(macOS 15.0, iOS 18.0, *)
    static func verdictAnswerCases() async -> [VerdictAnswerCase] {
        let harness = EngineHarness.make(tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        return await harness.engine.readForTests { engine in
            let entry = EngineFixture.entry("va-o", EngineFixture.bytes(1_617_402, count: 16))
            let u = InterestToken(rawValue: 1)
            let w = InterestToken(rawValue: 2)
            let g = InterestToken(rawValue: 3)
            let interests = [
                u: JobInterest(lane: .userInitiated, kind: .waiter, assets: [entry.identifier]),
                w: JobInterest(lane: .prefetch, kind: .waiter, assets: [entry.identifier]),
                g: JobInterest(lane: .prefetch, kind: .prefetch, assets: [entry.identifier]),
            ]
            func job(_ tokens: [InterestToken], attempts: Int) -> Job {
                var job = Job(
                    transfer: entry.transferID,
                    entry: entry,
                    identity: entry.contentIdentity,
                    assets: [entry.identifier],
                    state: .failed(.nextRun),
                    epoch: 1,
                    queuedAt: MonotonicInstant(nanoseconds: 0)
                )
                job.attempts = attempts
                for token in tokens {
                    job.interests[token] = interests[token]
                }
                return job
            }
            let names = [u: "U", w: "W", g: "G"]
            // The retries' arrival on the wall clock: the clock now, which the verdict read before it carried its own.
            let wall = engine.environment.time.now()
            var cases: [VerdictAnswerCase] = []
            func expect(_ verdict: WaitingVerdict, _ label: String, _ job: Job, _ expected: [InterestToken: Bool], on engine: isolated SyncEngine) {
                for (token, answered) in expected.sorted(by: { $0.key < $1.key }) {
                    guard let interest = job.interests[token] else {
                        continue
                    }
                    let answers = engine.verdictAnswers(verdict, interest, of: job, at: nil)
                    cases.append(VerdictAnswerCase(label: "\(label): \(names[token] ?? "?")", answers: answers, expected: answered))
                }
            }
            let mixed = job([u, w, g], attempts: 0)
            let background = job([w, g], attempts: 0)
            let second = job([u, w, g], attempts: 1)
            // A resolution and a 429 beyond the caps answer everyone.
            expect(.attempt(.resolve(.notFound)), "404", mixed, [u: true, w: true, g: true], on: engine)
            expect(.attempt(.throttle(ThrottleFacts(retryAfter: 7_200, decision: .exhausted))), "429 beyond the caps", mixed, [u: true, w: true, g: true], on: engine)
            // A retry answers those its count reaches the cap of: the user lane's second attempt, not the background's.
            let timeout = TransferError.transient(.timedOut, retryAfter: nil)
            expect(.attempt(.retry(timeout, answer: nil, wall: wall)), "first timeout", mixed, [u: false, w: false, g: false], on: engine)
            expect(.attempt(.retry(timeout, answer: nil, wall: wall)), "second timeout", second, [u: true, w: false, g: false], on: engine)
            // A `Retry-After` beyond the cap of the lane the job keeps ends it for everyone (`Backoff.delay`, `retryLater`):
            // the user lane's 30 s when U stays, the background's 3,600 s without it.
            let unavailable = TransferError.transient(.serverError(httpStatus: 503), retryAfter: .seconds(120))
            expect(.attempt(.retry(unavailable, answer: nil, wall: wall)), "503 after 120 s, U kept", mixed, [u: true, w: true, g: true], on: engine)
            expect(.attempt(.retry(unavailable, answer: nil, wall: wall)), "503 after 120 s, background", background, [w: false, g: false], on: engine)
            // A throttle's park: its wait read against each lane's limit (2 s for the user lane, none for prefetch).
            let end = MonotonicInstant(nanoseconds: 10_000_000_000)
            expect(.attempt(.throttle(ThrottleFacts(retryAfter: 10, decision: .until(end)))), "429 for 10 s", mixed, [u: true, w: false, g: false], on: engine)
            // An offline exit: an edge's fresh attempt answers nobody; a wait for the next edge fails waiters fast.
            expect(.attempt(.offline(requeue: true)), "offline, edge passed", mixed, [u: false, w: false, g: false], on: engine)
            expect(.attempt(.offline(requeue: false)), "offline, waiting for an edge", mixed, [u: true, w: true, g: false], on: engine)
            // A pause parks only a policy pause of a lane below the user's with a lane-wide block, and answers what the
            // park's fail-fast answers: an offline block fails waiters fast, a policy block nobody.
            let offline = [LaneBlock(lane: .prefetch, reason: .offline), LaneBlock(lane: .bulk, reason: .offline)]
            expect(.attempt(.pause(policy: true, blocks: offline)), "policy pause, offline", background, [w: true, g: false], on: engine)
            expect(.attempt(.pause(policy: false, blocks: offline)), "preemption pause, offline", background, [w: false, g: false], on: engine)
            expect(.attempt(.pause(policy: true, blocks: [LaneBlock(lane: .prefetch, reason: .policy(.constrainedNetwork))])), "policy pause, Low Data Mode", background, [w: false, g: false], on: engine)
            expect(.attempt(.pause(policy: true, blocks: [LaneBlock(lane: .bulk, reason: .offline)])), "policy pause, bulk offline", background, [w: false, g: false], on: engine)
            expect(.attempt(.pause(policy: true, blocks: offline)), "policy pause of user work", mixed, [u: false, w: false, g: false], on: engine)
            expect(.attempt(.requeue), "re-queue", mixed, [u: false, w: false, g: false], on: engine)
            // An ENOSPC: parked for lack of space, its fail-fast answers waiters; a retry (the room is there after all)
            // or a wait for the store's reclaim answers those at their cap.
            let reserve = StoragePolicy().reserveFreeBytes
            func space(room: Int64, reclaim: Int64) -> FreeSpace {
                FreeSpace(volumeImportant: reserve + room, volumeOpportunistic: reserve + room, usedBytes: 0, pendingReclaim: reclaim, budgetBytes: .max, reserveBytes: reserve)
            }
            engine.state.freeSpace = space(room: 1_000_000, reclaim: 0)
            expect(.space(required: 20_000_000), "ENOSPC parked", second, [u: true, w: true, g: false], on: engine)
            engine.state.freeSpace = space(room: 1_000_000, reclaim: 50_000)
            expect(.space(required: 20_000_000), "ENOSPC awaiting the reclaim", second, [u: true, w: false, g: false], on: engine)
            engine.state.freeSpace = space(room: 100_000_000, reclaim: 0)
            expect(.space(required: 20_000_000), "ENOSPC retried", second, [u: true, w: false, g: false], on: engine)
            engine.state.freeSpace = nil
            return cases
        }
    }

    /// `verdictAnswers` answers, for every verdict a drain gives, exactly the interests that verdict's replay answers,
    /// a non-user interest included (`verdictAnswerCases`; Stage 3 close-out cycle 17: the user-interest endings are
    /// `verdictLane`'s, these are the answers no ending of it decides).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a waiting verdict answers in the 429's lane exactly the interests its replay answers (F-28)", .timeLimit(.minutes(3)))
    func verdictAnswersMirrorTheReplays() async {
        let cases = await Self.verdictAnswerCases()
        #expect(cases.count == 49, "every case ran: \(cases.count)")
        for item in cases {
            #expect(item.answers == item.expected, "\(item.label): verdictAnswers \(item.answers), the replay \(item.expected)")
        }
    }

    /// The job a waiting verdict meets (`jobAtVerdict`): without the interests a waiting withdrawal removes and those all
    /// of whose ids leave it before the verdict (`AttemptEnd.movedBefore`, `takeOffMovedBefore`), so the lane a retry's
    /// policy and an ENOSPC's room are read on is the one the replay meets (Stage 3 close-out cycle 17).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a waiting verdict meets its job without the interests that leave it before the drain gives it (F-28)", .timeLimit(.minutes(3)))
    func verdictMeetsTheJobTheDrainLeavesIt() async {
        let harness = EngineHarness.make()
        let met = await harness.engine.readForTests { engine in
            let a = EngineFixture.entry("va-a", EngineFixture.bytes(1_617_502, count: 16))
            let b = AssetID("va-b")
            let u = InterestToken(rawValue: 1)
            let w = InterestToken(rawValue: 2)
            let x = InterestToken(rawValue: 3)
            var job = Job(
                transfer: a.transferID,
                entry: a,
                identity: a.contentIdentity,
                assets: [a.identifier, b],
                state: .failed(.nextRun),
                epoch: 1,
                queuedAt: MonotonicInstant(nanoseconds: 0)
            )
            job.interests[u] = JobInterest(lane: .userInitiated, kind: .waiter, assets: [b])
            job.interests[w] = JobInterest(lane: .prefetch, kind: .waiter, assets: [a.identifier])
            job.interests[x] = JobInterest(lane: .bulk, kind: .ensure, assets: [a.identifier, b])
            job.attemptEnd = AttemptEnd(failedAfter: 1, deferredAfter: 1, movedBefore: [b])
            let leaving = engine.jobAtVerdict(job, withdrawn: [])
            let withdrawn = engine.jobAtVerdict(job, withdrawn: [w])
            job.attemptEnd = AttemptEnd(failedAfter: 1, deferredAfter: 1)
            let staying = engine.jobAtVerdict(job, withdrawn: [])
            return (leaving: Set(leaving.interests.keys), leavingLane: leaving.lane, withdrawn: Set(withdrawn.interests.keys), staying: Set(staying.interests.keys), stayingLane: staying.lane)
        }
        let (u, w, x) = (InterestToken(rawValue: 1), InterestToken(rawValue: 2), InterestToken(rawValue: 3))
        #expect(met.leaving == [w, x] && met.leavingLane == .prefetch, "U's only id leaves before the verdict; X keeps one that stays: \(met)")
        #expect(met.withdrawn == [x], "W's withdrawal waits before the verdict: \(met)")
        #expect(met.staying == [u, w, x] && met.stayingLane == .userInitiated, "nothing leaves: \(met)")
    }
}
