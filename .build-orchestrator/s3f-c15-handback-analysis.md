# Cycle-15 analysis from a stopped fixer copy (31 Oct 16:40) — unverified input, not a ruling

A message sent to the cycle-15 fixer at 16:31 started a second copy of it in the same worktree. That copy read S3-R18, made no edits, ran nothing, and stopped when it saw the other writer. Its analysis is below, read from the code at `388f744`. **Nothing here was run or verified.** The fixer checks each point before acting on it; where this file and the rulings disagree, the rulings win.

The original fixer's unfinished, uncompiled tests are on branch `wip/s3f-c15a` (`5a87864`): AnswerTests changes, LaneTests, PublicationTests, SlotTests. Reuse what fits S3-R18. SlotTests' comment describes counting places ahead, which S3-R18 item 1 rules out; the STAMP-AHEAD scenario itself is still the test to add.

## 1. Gap in S3-R18 item 2: a later apply while the earlier follow is still owed
- **Scenario.** C's publication begins after v3's apply (`publishingSince` = 3). Then v4 applies while v3's follow still owes C's visit.
- **The gap.** C is then visited under v3's stamp, and "3 >= 3" says re-route. But `follow` computes `moved` against the live copy (v4), so it would also move zz-c, which v4 moved.
- **Visit-first.** v4's follow found C publishing and passed it, so zz-c's user gets C's outcome.
- This is the MARK-TWO-APPLIES class through another path. The cycle-14 code (`publishedAfterApply` + `followPassedPublication`) fails it too.
- **Suggested fix.**
  - In `publish`, record `job.rerouteOnPass`: the ids the copy maps elsewhere when `followOwed` is true, and an empty set otherwise. At that instant the copy is the one after apply P.
  - In `follow`, for a verifying or committing job, re-route `moved ∩ rerouteOnPass` at once, using the partial-move code: subtract the ids from `assets`, re-route each interest, and call `removeInterest` when an interest empties. Leave the bytes, ledger and publication alone, then clear the set.
  - The other moved ids are passed, and the job stays in `unfollowed`.
- **What could then go:** `PassedPublication`, `passedPublishing`, `publishingSince`, `appliesFollowed`, `WorldStamp.apply`, `followPassedPublication`, the `publicationEnded` parameter of `visit`/`follow`, and the call in `publicationFailed`. `followedForVerdict`'s visit could go too; only its epoch check is still needed.
- **Test to add:** two applies, where v4 applies while v3's follow is still owed.

## 2. followedLane
- **Jobs walk.** Replace the skip of verifying or committing jobs: count a publishing job's interest only in ids that are `here` and in `rerouteOnPass`.
  - Mutant-killing tests: PASSED-LANE, plus a variant where Y was already publishing at the apply. In that variant visit-first throttles too, so C is prefetch work and P is served.
- **Fallback (lines 717-720).** Replace it with `return lane ?? job.lane` and make the return non-optional (the requirements verifier's suggestion). The reason to record: when nothing counts, either nobody the verdict answers is left on the job, or it is a claim-only job, whose `job.lane` is its held lane.
- **Joins walk `continue` (705-706).** Two tests in both orders, with C prefetch and a 429 with Retry-After 60. In both, the expected outcome is that the origin is throttled and P is served.
  - a user join for other content (zz-o);
  - a user-lane group's waiting join for zz-b, released before the 429 (kills dropping `stillWants`).

## 3. Removing the stamps (S3-R18 item 1)
- **Source to remove:**
  - `gate`'s stamp-throttle refusal (EngineDispatch :548);
  - `dispatch`'s stamped park (:391-400); the `answeredAt`/`answerEnd` parameters of `park` and `at`/`answerEnd` of `failFast`, if only the stamped park passes them;
  - `enqueue`'s stamping (EngineJobs :471);
  - `freeSlots()`, `FreeSlots` and `WorldStamp.freeSlots`;
  - `start`'s edge serial read from the stamp (EngineDispatch :768);
  - the `placeStamps` field, its clears (EngineFollow :289 and :342, EngineShutdown :122, EngineJobs :422) and its invariant clause (EngineCommands :2010).
- **Keep but re-cite:** EngineTimers :123, the `.throttle` deadline with no live throttle. `replayThrottle` can still park on an ended throttle.
- **Tests that change one to one** (sweep-first only, under S3-R18 item 1's exception):
  - WorldTests `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply`: U is served N (16 B) instead of `serverUnavailable(10)`;
  - AnswerTests `barrierGatesAPlaceWithoutASlotOnTheLiveThrottle` and `barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle` (:302, :359): re-check both;
  - AnswerTests :749: the setup assertion `mark == .publishingAtApply` becomes "C verifies, still holds zz-c, and is in `unfollowed`".
- **Expected after the removal:** STAMP-AHEAD passes.

## 4. Non-blocking
- `barrierStartsAVisitsPlaceOnceTheBreakerCloses`, sweep-first: assert `invariantViolations()` is empty after the breaker closes and before `releaseFollowFollowUps()`, while `.unblock(.circuitOpen)` still waits. This reaches the 0-hit exclusion in `unwakeableBreakerParks`.
- `!join.withdrawn` in followedLane's joins walk may be redundant except for system (heal) joins; check its coverage.
