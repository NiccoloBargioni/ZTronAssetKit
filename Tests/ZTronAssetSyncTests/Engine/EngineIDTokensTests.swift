import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins of a job's index of its interests by id (`Job.tokensByID`, `IDTokens`; Stage 3 close-out cycle 21, ruling
/// S3-R26 item 3, `integrate-c21.md` B2–B4): every mutator keeps it equal to a recount made from the interests directly.
/// Some steps here are their mutants' only kills, the state being one no engine path leaves for the invariant check to
/// see (critique A11): `insertAsset` without an interest, `keepInterests` on a copy that is never stored back,
/// `removeAllInterests` right before its job is removed, and `setInterest`'s replacement of one token's ids. The engine's
/// own paths are pinned by the index's clause of the invariant check (I1, `invariantsReportAMisindexedJob`), which every
/// engine test that checks the invariants runs.
@Suite("Job interest index")
struct EngineIDTokensTests {
    /// The holders of each id, recounted from `job`'s interests directly, never through `IDTokens`.
    static func recount(_ job: Job) -> [AssetID: Set<InterestToken>] {
        var holders: [AssetID: Set<InterestToken>] = [:]
        for (token, interest) in job.interests {
            for asset in interest.assets {
                holders[asset, default: []].insert(token)
            }
        }
        return holders
    }

    /// The holders `job`'s index lists for each id, read from its fields.
    static func indexed(_ job: Job) -> [AssetID: Set<InterestToken>] {
        job.tokensByID.mapValues { $0.others.union([$0.first]) }
    }

    /// An id's holders: one kept apart, the others in a set; adding the first again changes nothing; removing another
    /// keeps the first; removing the first promotes another, or leaves none; `forEach` gives the first first.
    @Test("R-SYN-6: an id's holders keep the first apart, promote another when it leaves, and report none when the last leaves")
    func holdersPromoteAndEmpty() {
        let t1 = InterestToken(rawValue: 1)
        let t2 = InterestToken(rawValue: 2)
        let t3 = InterestToken(rawValue: 3)
        var holders = IDTokens(t1)
        holders.add(t1)
        #expect(holders.first == t1 && holders.others.isEmpty && holders.tokens == [t1], "the first added again is still one holder")
        holders.add(t2)
        holders.add(t3)
        #expect(holders.first == t1 && holders.others == [t2, t3] && holders.tokens == [t1, t2, t3], "two more holders join the others")
        var walked: [InterestToken] = []
        holders.forEach { walked.append($0) }
        #expect(walked.first == t1 && Set(walked) == [t1, t2, t3] && walked.count == 3, "forEach gives the first first, then each other once: \(walked)")
        let keptAfterOther = holders.remove(t3)
        #expect(keptAfterOther && holders.first == t1 && holders.others == [t2], "removing another holder keeps the first")
        let keptAfterFirst = holders.remove(t1)
        #expect(keptAfterFirst && holders.first == t2 && holders.others.isEmpty, "removing the first promotes the other")
        let keptAfterSole = holders.remove(t2)
        #expect(!keptAfterSole, "removing the sole holder leaves none")
    }

    /// Each insertion, re-insertion, second holder, removal (of another holder, of the first, of the sole one), no-op
    /// insertion, replacement of a token's ids, in-place change, subtraction, filtered copy and clear keeps the index equal
    /// to a recount, with the direct counts each step must leave (the first holder's re-insertion counts one).
    @Test("R-SYN-6: a job's index of its interests by id follows every change to its interests")
    func tokensFollowEveryChange() {
        let t1 = InterestToken(rawValue: 1)
        let t2 = InterestToken(rawValue: 2)
        let t3 = InterestToken(rawValue: 3)
        let none = InterestToken(rawValue: 9)
        let a = AssetID("index-a")
        let b = AssetID("index-b")
        let c = AssetID("index-c")
        var job = EngineInterestCountsTests.job()
        func check(_ step: String) {
            #expect(Self.indexed(job) == Self.recount(job), "\(step): the index equals a recount: \(Self.indexed(job)) against \(Self.recount(job))")
            #expect(job.tokensByID.values.allSatisfy { !$0.others.contains($0.first) }, "\(step): no first holder among the others")
        }
        check("none")
        #expect(job.tokensByID.isEmpty, "no interest, no entry")
        job.setInterest(JobInterest(lane: .prefetch, kind: .prefetch, assets: [a]), for: t1)
        check("t1 inserted")
        #expect(job.tokensByID[a]?.tokens.count == 1 && job.tokensByID[a]?.first == t1, "an insert indexes one holder")
        job.insertAsset(a, for: t1)
        check("t1's a inserted again")
        #expect(job.tokensByID[a]?.tokens.count == 1 && job.tokensByID[a]?.others.isEmpty == true, "the same token again is still one holder")
        job.setInterest(JobInterest(lane: .userInitiated, kind: .waiter, assets: [a]), for: t2)
        check("t2 inserted")
        #expect(job.tokensByID[a]?.tokens.count == 2 && job.tokensByID[a]?.first == t1, "a second token is a second holder")
        let secondHeld = job.removeAsset(a, for: t2)
        #expect(secondHeld, "t2 held a")
        check("the second holder removed")
        #expect(job.tokensByID[a]?.tokens == [t1], "the first holder stays")
        job.insertAsset(a, for: t2)
        check("t2's a inserted in place")
        #expect(job.tokensByID[a]?.tokens == [t1, t2], "an in-place insert indexes its holder")
        let firstHeld = job.removeAsset(a, for: t1)
        #expect(firstHeld, "t1 held a")
        check("the first holder removed")
        #expect(job.tokensByID[a]?.first == t2 && job.tokensByID[a]?.others.isEmpty == true, "the other holder is promoted")
        let soleHeld = job.removeAsset(a, for: t2)
        #expect(soleHeld, "t2 held a")
        check("the sole holder removed")
        #expect(job.tokensByID[a] == nil, "an id no interest holds has no entry")
        let heldAgain = job.removeAsset(a, for: t2)
        #expect(!heldAgain, "t2 holds a no longer")
        check("a removed again")
        job.insertAsset(b, for: none)
        check("an insert for a token with no interest")
        #expect(job.tokensByID[b] == nil && job.interests[none] == nil, "a token with no interest indexes nothing")
        job.setInterest(JobInterest(lane: .prefetch, kind: .prefetch, assets: [a]), for: t1)
        job.setInterest(JobInterest(lane: .prefetch, kind: .prefetch, assets: [b]), for: t1)
        check("t1's {a} replaced by {b}")
        #expect(job.tokensByID[a] == nil && job.tokensByID[b]?.tokens == [t1], "a replacement releases the ids it drops and indexes those it adds")
        job.setAssets([b, c], for: t1)
        check("t1's ids set to {b, c}")
        job.setAssets([c], for: t1)
        check("t1's ids set to {c}")
        #expect(job.tokensByID[b] == nil && job.tokensByID[c]?.tokens == [t1], "an in-place replacement releases b")
        job.setAssets([a], for: none)
        check("setAssets for a token with no interest")
        job.setInterest(JobInterest(lane: .bulk, kind: .run, assets: [a, b, c]), for: t3)
        check("t3 inserted with {a, b, c}")
        job.subtractAssets([a, b], for: t3)
        check("t3's a and b subtracted")
        #expect(job.tokensByID[a] == nil && job.tokensByID[b] == nil && job.tokensByID[c]?.tokens == [t1, t3], "a subtraction releases each id it takes")
        var copy = job
        copy.keepInterests { token, _ in token != t3 }
        #expect(Self.indexed(copy) == Self.recount(copy) && copy.tokensByID[c]?.tokens == [t1], "the filtered copy releases the interests it drops")
        check("the original after its copy was filtered")
        #expect(job.tokensByID[c]?.tokens == [t1, t3], "the original keeps its index")
        job.setInterest(nil, for: t1)
        check("t1 removed")
        #expect(job.tokensByID[c]?.tokens == [t3], "a removal releases every id")
        job.removeAllInterests()
        check("every interest removed")
        #expect(job.tokensByID.isEmpty, "no interest, no entry")
    }

    /// The index's clause of the invariant check (I1) reports an id whose holders the index forgot, and only that, in
    /// one exact message; the interest clause (I3) reports an interest with no id.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: the invariant check reports a job whose index of its interests' ids is wrong, or that holds an interest with no id", .timeLimit(.minutes(1)))
    func invariantsReportAMisindexedJob() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(2_021_801)
        let entry = EngineHarness.onDemand("held", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let group = try await engine.registerGroup(["held"], lane: .prefetch).get()
        await engine.waitUntil { $0.running == 1 }
        #expect(await engine.invariantViolations().isEmpty, "a healthy engine")
        let transfer = entry.transferID
        let forgotten = await engine.violations { $0.jobs[transfer]?.forgetIndexForTests(AssetID("held")) }
        #expect(forgotten == ["job \(transfer) indexes the holders of 1 ids unlike its interests, 0 with its first holder among the others"], "\(forgotten)")
        let empty = await engine.violations { $0.jobs[transfer]?.setInterest(JobInterest(lane: .prefetch, kind: .prefetch, assets: []), for: InterestToken(rawValue: 999_999)) }
        #expect(empty.contains("job \(transfer) holds interest 999999 with no id"), "\(empty)")
        #expect(await engine.invariantViolations().isEmpty, "the check restored the state")
        await harness.source.release(transfer, with: .progress(received: 0, expected: nil))
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}
