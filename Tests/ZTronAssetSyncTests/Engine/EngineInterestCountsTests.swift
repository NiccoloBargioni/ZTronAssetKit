import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins of the per-lane interest counts a job's lane is read from (`Job.interestCounts`; Stage 3 close-out cycle 20,
/// ruling S3-R25 item 2): every change to a job's interests keeps them, so `Job.lane` and `Job.isSingleUser` answer
/// what a walk of the interests answered, in O(1). The engine's own paths are pinned by the invariant check's clause
/// (`EngineOutcomeTests.invariantOracle`), which every engine test that checks the invariants runs.
@Suite("Job interest counts")
struct EngineInterestCountsTests {
    /// What a walk of `job`'s interests answers, as `Job.lane` and `Job.isSingleUser` read before the counts.
    static func walked(_ job: Job) -> (lane: AssetPriority, singleUser: Bool) {
        let lane = job.interests.values.map(\.lane).max() ?? job.heldLane ?? .bulk
        let singleUser = job.interests.values.contains { $0.lane == .userInitiated && $0.kind != .ensure }
        return (lane, singleUser)
    }

    /// A job with no interest.
    static func job() -> Job {
        let entry = EngineFixture.entry("counts", EngineFixture.bytes(2_020_201, count: 16))
        return Job(
            transfer: entry.transferID,
            entry: entry,
            identity: entry.contentIdentity,
            assets: [entry.identifier],
            state: .queued,
            epoch: 1,
            queuedAt: MonotonicInstant(nanoseconds: 0)
        )
    }

    /// Each insertion, lane change (a replacement of a token's interest by one of another lane or kind), removal and
    /// in-place change of an interest's ids keeps the counts equal to a recount, and the lane and the single-user rank
    /// equal to the walk's. The steps are chosen so that a count left behind by any of them changes the lane or the
    /// rank read afterwards: the insertion of a prefetch interest over a bulk one, the lane changes of one token up to
    /// user-initiated and back down to prefetch, and the removals down to the held lane.
    @Test("R-SYN-3: a job's lane and single-user rank, read from its interest counts, follow every change to its interests")
    func countsFollowEveryChange() {
        let bulk = InterestToken(rawValue: 1)
        let prefetch = InterestToken(rawValue: 2)
        let ensure = InterestToken(rawValue: 3)
        let waiter = InterestToken(rawValue: 4)
        let a = AssetID("counts-a")
        let b = AssetID("counts-b")
        var job = Self.job()
        var steps: [(step: String, lane: AssetPriority, singleUser: Bool, counts: InterestCounts)] = []
        func record(_ step: String) {
            steps.append((step, job.lane, job.isSingleUser, job.interestCounts))
            #expect(job.interestCounts == InterestCounts(job.interests.values), "\(step): the counts equal a recount")
            #expect(job.lane == Self.walked(job).lane && job.isSingleUser == Self.walked(job).singleUser, "\(step): the walk's lane and rank")
        }
        record("none")
        job.setInterest(JobInterest(lane: .bulk, kind: .run, assets: [a]), for: bulk)
        record("bulk inserted")
        job.setInterest(JobInterest(lane: .prefetch, kind: .prefetch, assets: [a]), for: prefetch)
        record("prefetch inserted")
        job.setInterest(JobInterest(lane: .userInitiated, kind: .ensure, assets: [a, b]), for: ensure)
        record("ensure inserted")
        job.setInterest(JobInterest(lane: .userInitiated, kind: .waiter, assets: [b]), for: waiter)
        record("waiter inserted")
        job.setInterest(nil, for: waiter)
        record("waiter removed")
        job.setInterest(nil, for: ensure)
        record("ensure removed")
        job.setInterest(JobInterest(lane: .userInitiated, kind: .waiter, assets: [a]), for: prefetch)
        record("prefetch's token raised to a user waiter")
        job.setInterest(JobInterest(lane: .prefetch, kind: .prefetch, assets: [a]), for: prefetch)
        record("prefetch's token lowered back")
        job.insertAsset(b, for: prefetch)
        let held = job.removeAsset(a, for: prefetch)
        let heldAgain = job.removeAsset(a, for: prefetch)
        let heldByRemoved = job.removeAsset(a, for: waiter)
        #expect(held && !heldAgain && !heldByRemoved, "the interest held a and no longer does; a removed token's holds nothing")
        #expect(job.interests[prefetch]?.assets == [b])
        record("prefetch's ids changed in place")
        job.subtractAssets([b], for: prefetch)
        #expect(job.interests[prefetch]?.assets.isEmpty == true, "the interest stays with no id until its caller removes it")
        record("prefetch's ids subtracted")
        job.setAssets([a, b], for: prefetch)
        #expect(job.interests[prefetch]?.assets == [a, b])
        record("prefetch's ids replaced")
        job.setInterest(nil, for: prefetch)
        record("prefetch removed")
        job.setInterest(nil, for: bulk)
        job.heldLane = .prefetch
        record("bulk removed, the lane held")
        job.setInterest(nil, for: bulk)
        record("a removal of a removed token")
        let read = steps.map { "\($0.step): \($0.lane) \($0.singleUser)" }
        #expect(steps.map(\.lane) == [.bulk, .bulk, .prefetch, .userInitiated, .userInitiated, .userInitiated, .prefetch, .userInitiated, .prefetch, .prefetch, .prefetch, .prefetch, .bulk, .prefetch, .prefetch], "\(read)")
        #expect(steps.map(\.singleUser) == [false, false, false, false, true, false, false, true, false, false, false, false, false, false, false], "\(read)")
        #expect(steps.last?.counts == InterestCounts(), "\(read)")
    }

    /// The two whole-set changes: a removal of every interest clears the counts, and a filter recounts the interests it
    /// keeps (`SyncEngine.jobAtVerdict`'s copy of a job), so a copy's lane is that of the interests it kept.
    @Test("R-SYN-3: removing every interest of a job, or keeping some, leaves the counts of the interests it holds")
    func wholeSetChangesRecount() {
        let tokens = (1...4).map { InterestToken(rawValue: $0) }
        let lanes: [AssetPriority] = [.userInitiated, .prefetch, .bulk, .userInitiated]
        let kinds: [InterestKind] = [.waiter, .prefetch, .run, .ensure]
        var job = Self.job()
        for index in tokens.indices {
            job.setInterest(JobInterest(lane: lanes[index], kind: kinds[index], assets: [AssetID("whole-\(index)")]), for: tokens[index])
        }
        #expect(job.interestCounts == InterestCounts(job.interests.values) && job.lane == .userInitiated && job.isSingleUser)
        var kept = job
        kept.keepInterests { token, _ in token != tokens[0] }
        #expect(kept.interests.count == 3 && kept.interestCounts == InterestCounts(kept.interests.values), "a filter recounts what it keeps")
        #expect(kept.lane == .userInitiated && !kept.isSingleUser, "the ensure batch keeps the lane, and no single request is left")
        kept.keepInterests { token, _ in token == tokens[1] || token == tokens[2] }
        #expect(kept.lane == .prefetch && kept.interestCounts == InterestCounts(kept.interests.values))
        #expect(job.lane == .userInitiated && job.interests.count == 4, "the job the copy was made of keeps its interests")
        job.removeAllInterests()
        #expect(job.interests.isEmpty && job.interestCounts == InterestCounts(), "a removal of every interest clears the counts")
        #expect(job.lane == .bulk && !job.isSingleUser)
    }

    /// The lane a retry keeps (`verdictAnswers`): the highest lane an interest asks for among those the predicate
    /// admits, `nil` when it admits none.
    @Test("R-SYN-5: the highest lane among the admitted ones is read from the counts")
    func highestAdmittedLane() {
        var counts = InterestCounts()
        #expect(counts.highest == nil && counts.highest(where: { _ in true }) == nil)
        counts.add(JobInterest(lane: .bulk, kind: .run, assets: []))
        counts.add(JobInterest(lane: .userInitiated, kind: .waiter, assets: []))
        #expect(counts.highest == .userInitiated)
        #expect(counts.highest(where: { $0 != .userInitiated }) == .bulk, "a prefetch lane with no interest is passed")
        #expect(counts.highest(where: { $0 == .prefetch }) == nil)
        counts.add(JobInterest(lane: .prefetch, kind: .prefetch, assets: []))
        #expect(counts.highest(where: { $0 < .userInitiated }) == .prefetch)
        counts.remove(JobInterest(lane: .userInitiated, kind: .waiter, assets: []))
        #expect(counts.highest == .prefetch && counts.singleUser == 0 && counts.userInitiated == 0)
        counts.remove(JobInterest(lane: .prefetch, kind: .prefetch, assets: []))
        #expect(counts.highest == .bulk && counts.highest(where: { $0 > .bulk }) == nil)
    }
}
