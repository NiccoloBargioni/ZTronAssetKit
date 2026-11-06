# F3b, angle A: one-turn routes for the purge cases route C does not reach (input to item 3b)

Read-only analysis at `9aa337c` (`.worktrees/s3f`, branch `wp/s3f`). Nothing was built, run or measured for it.
- *Measured* figures cite the fixer's draft (`docs/adr-drafts/s3f.md`, as "s3f:"). A *derived* figure is arithmetic on two measured ones, and is still an estimate of what it names. Every other figure is an *estimate*, with its basis given (G2).
- Paths are under `Sources/ZTronAssetSync/Engine/` unless given in full. "Rulings :n" is `.build-orchestrator/s3-rulings-s3f.md`; N7 to N9 are in `s3-r28-orchestrator-rulings.md`; "f3" and "the review" are `f3-purge-route.md` and its review.
- Process: four read-only commands ran with the shell's directory inside the worktree, which this task's rule forbids. They wrote nothing.

## 0. Verdict

- **Route A** has three core parts, A-1, A-2 and A-3, placed after route C's stage A. Three more (A-5, A-3b, A-6) are made only when triggered.
- **It closes (estimates):** `keptUnderThreeGroups`, about 3-6 ms (38-48 today); `fourGroupJoins`, about 2-5 ms in a bucket and 2.7-7 ms in the queue (15-22 today); `pendingClaimGroups`, about 2-4.6 ms, with A-5 only.
- **It does not close** `oneMemberGroupsFourPerID` or `mixedLaneGroups`. Both retire every job, so route C's sort and retirements set their cost. Route A takes 2-4 ms off the first and almost nothing off the second. Both stay above 8.5 ms at the top of their stage-A estimates and close, by estimate, only at route C's stage C (N8).
- **Rulings:** no ARCHITECTURE §7.1 amendment (no part removes a job). It needs N9 widened by one field (`queuedAt`) and an exception to rulings :1175's sorted order for three classes of job.
- **Found on the way:** an in-letter, ungated shape, failed user jobs under a prefetch group. The purge re-admits each job with an O(heap) scan: about 0.5 s today, derived from `retryJobs`' measured 571.12 ms (§9).

## 1. Where the turns go (basis)

| Case | Shape | Today; after route C (estimates) | What dominates |
|---|---|---|---|
| keptUnderThreeGroups | a user waiter and 3 prefetch groups on each of 10,000 ids | 38-48; 34-39 (f3 §3.6) | 30,000 in-place withdrawals at W ≈ 0.85 µs (f3 parts table), the sort, and a re-queue of every job (`EngineJobs.swift:311-314`) |
| fourGroupJoins | 40,000 joins waiting for the follow | 15-22, scaled from 5.00 ms *measured* at 9,216 joins (s3f:7620) | `withdrawJoinInterest` per join (`EngineCommands.swift:1129-1144`): about 4 token and 2 id hashes |
| oneMemberGroupsFourPerID | 40,000 one-member prefetch groups, 4 on each id (N7) | 8-16 after route C (review "must add" 1) | route C's sorted retirement at k = 4; C-3's pass over 40,000 groups |
| mixedLaneGroups | two groups on the same ids, one `.prefetch`, one `.bulk` | 24-33 without (i) (review must-fix 3) | with option (i): route C's retirement at k = 2 |
| pendingClaimGroups | one group joined, a second registered just before the purge | 16-18 without (i) | with option (i): C-2′'s claim arm per job, and the sort |

Measured anchors: `userWaiters`, 6.82 ms (s3f:7618), is the walk's skeleton S (f3 splits it, as an estimate, into a 2-3.5 ms sort and 0.4-0.5 µs a job); `purgeJoinsTurns`, 5.00 and 5.15 ms (s3f:7620-7621); the gate runs at `9aa337c` (s3f:7725-7738).

## 2. The parts, in order

Each part is its own commit, with every suite green, under item 1's exclusivity rule: an in-place access only marks and collects; `applied`, the request and `claims` are locals; every other write comes after the access.

### A-1. C-3 first and whole (`.all` only; before `withdrawPurgedJoins`, `EngineCommands.swift:1016`)

- **The pass.** One index loop over `groups.values` takes each group whose kind is `.prefetch` and whose lane is below `.userInitiated`. Its `pending` is moved out whole to the freeing list, not emptied in place. After that access, if `joinsAfterFollow` is not empty, `removeValue(forKey: token)` moves the group's row there too.
- **The joins walk is unchanged.** Every join is still marked (RR-5, rulings :1140), and `withdrawJoinInterest` returns at its guard (`:1130-1131`) after one failed `UInt64` token lookup. Under `.all` the job walk makes no drop for a withdrawn `.prefetch` interest (C-3's rule). `.system`, `.run` and `.ensure` joins, and joins whose group is gone, stay on the per-join path.
- **Why it is equal.**
  - A token's lane is fixed at registration: `Group.kind` and `Group.lane` are `let` (`EngineState.swift:1339-1341`), and every join and re-route carries the token's lane (`EngineCommands.swift:1797-1799`). So every join under a taken token is one today's walk withdraws.
  - The joins clause (`:2219-2224`, `:2256`, documented at `:2187`) makes the row exactly the token's non-withdrawn joins. A row and its event are written in one synchronous stretch (`EngineJobs.swift:131-133`) and removed the same way (`EngineFollow.swift:983-988`, `EngineCommands.swift:1130-1135`), so the clause holds at every turn boundary, not only at idle.
  - The id-level F-1 clause (route C's prerequisite at `:1884`) makes every pending member one that today's walk drops. `Group.dropMember` returns a continuation only for `.ensure` (`EngineState.swift:1381-1391`), so no drop resumes anything, and the drops' order cannot be observed (e2-A1.3).
  - `replayJoin` (`EngineFollow.swift:983`) and `stillWants` (`:1003-1018`) read only what the pass removed, as they read it today.
- **Cost (estimate):** 10-30 ns a group (a move and an append), against C-3's 65-125 ns emptying (f3 §3.2). Per join left: 40-90 ns in a bucket, 60-130 ns in the queue (the mark through `switch consume self`, `EngineFollow.swift:1832-1845`, and one failed lookup).

### A-2. Rebuild a kept job (a `Job` mutating method; `.all` only)

- **Kept:** interests at `.userInitiated` or of kind `.waiter` (today's filter, `EngineState.swift:1135`).
- **The rule.** Only when exactly one interest is kept, and its ids are no more than the withdrawn pairs, A-2 builds a one-entry `interests`, recounts `interestCounts` (`InterestCounts.init(_:)`, `:1232`), builds `tokensByID` from the kept ids, and returns the old storages for the freeing list. Otherwise it runs today's `withdrawPurged`. The rule is for cost only: A-2 never hashes more than today's release.
- **It returns** whether the run's token was removed, the withdrawn `.system` ids (for the heals), and both lanes without a sort: before the first removal, `lane`; before the last, the higher of the kept lanes and the highest withdrawn token's lane.
- **Why one kept interest.** `interests` is read in hash order with visible order at `EngineJobs.swift:737` (delivery) and `EngineDispatch.swift:1348` (re-route items); a one-entry table has one order. The index's readers do not depend on order (`EngineState.swift:1008-1040`: sorted, or "in no order"). The counts equal the recount by the counts clause (`EngineCommands.swift:1811`).
- **Cost (estimate):** 0.2-0.4 µs a job (two one-entry allocations at f3's 50-100 ns, two hashes, a recount, two appends). Today's three withdrawals cost about 2.5 µs (3 × W), plus 0.3-0.4 µs for the re-queue.

### A-3. One table-order pass classifies every job (replaces the `:1019` sort for two classes)

- **(α)** `userInitiated > 0` and not `.failed`: handled in place (A-2 under `.all`, otherwise today's method with its drops after the access), with no `settleRemoval` and one `notifyObservers` per job.
- **(β)** `prefetch + bulk == 0` (`InterestCounts`, `EngineState.swift:1218`): nothing can be withdrawn, so it is skipped with no hash, no key and nothing beyond the read. Claim-held jobs, which have no interests, fall here.
- **(γ)** every other job: its key is collected, and the keys are sorted and walked through route C (C-2, C-2′, or today's path). At stage B this is C-5's collection.
- **Why (α)'s skip is exact except where N9 applies.** The lane is `.userInitiated` before and after, so `relane` (`EngineJobs.swift:304-374`) does nothing for `.downloading` (`:316`), `.blocked` (it needs `after > before`), `.verifying` or `.committing`, and `holdIfUnwanted` returns nil since interests remain. The skipped part is the `.queued` re-queue (`:311-314`): place, ticket and `queuedAt` (`enqueue`, `:563-578`; `queuedAt` is read for bulk aging, `EngineDispatch.swift:335`). `.failed` jobs stay in (γ), so their re-admission (`:360-365`) is kept, as N9 requires.
- **Why the order across classes is free.** An (α) or (β) visit writes only its job, `run.held`, `heals`, the freeing list and one notification, and changes no lane, state or queue kind (`EngineDispatch.swift:298`). (γ)'s callees, `unblockOrigin` and `reconsiderPendingRun` (`EngineFailures.swift:1026-1094`, `EngineReadmission.swift:197-217`), read only lanes and states: that is the review's should-fix 8 argument, which 12.5.15's audit must now extend to (α). One interleaving changes: a (γ) retirement can unblock an (α) job, which today's later visit would re-queue and route A's earlier visit does not. That is a place difference, inside N9.
- **Not e2-A2.4:** no job is retired out of sorted order, so no A7 audit is needed.
- **Cost (estimate):** 30-80 ns a job for the pass (sequential `values[i]` reads), plus 10-30 ns for each (γ) key.

### Parts made only when triggered

- **A-5: C-2′ in the pass, as class (δ).** Made if `pendingClaimGroups` is above 8.5 ms after A-3.
  - Eligible under `.all` when every interest is withdrawn (no user interest and no waiter, by a scan of at most 4), the job is not verifying or committing, (b) holds as option (i) narrows it, and a claim is held (from the local `claims` copy).
  - It writes C-2′'s end state: storages to the freeing list, counts reset, `heldLane` from the highest token, `claimHeld` written. That is a hold, not a removal.
  - Cost (estimate): 0.15-0.35 µs a job (two content-key hashes and the moves). The case retires no job, so N8 gives it no stage, and A-5 is its only route.
- **A-3b.** Made if the ruling gates the prefetch-waiter shape (§9). It widens (α) to a job that keeps a waiter, whose lane the purge leaves unchanged, and that is not `.failed`; there `relane` does nothing even for `.queued`, so the skip is exact. It needs a waiter count in `InterestCounts`, with the counts clause updated.
- **A-6.** Made if the ruling gates the failed-user shape (§9). Inside the walk, the `.failed` arm leaves its `.retry` removal (`EngineJobs.swift:362`) to C-1's pass, whose predicate must also remove an entry whose job is no longer `.failed`: a re-admitted job keeps its epoch, which changes only at dispatch (`EngineDispatch.swift:705-706`).

### The freeing slices: route C's A2.3, extended

- Four more kinds: the groups' `pending`, the `joinsAfterFollow` rows, and each job's old `interests` and `tokensByID`. Bounded by jobs and by elements, pinned, and drained at shutdown in their own slices (the review's should-fix 6).
- Estimates: 3-6 ms of freeing after `keptUnderThreeGroups` and 2-4 ms after `oneMemberGroupsFourPerID`; 0.15-0.4 ms for a slice of 512 jobs; about 10 MB held until freed.

### Not recommended

- **A-4, a mark-only arm keyed on A-1's tokens.** It skips the returned array but still hashes the token: about 10-30 ns a join saved (estimate), within the estimates' error.
- **J-TRUE, a per-token withdrawal cut.** A serial on every join grows the event stride from 168 to 176 bytes, and every reader of joins would have to check the cut. A-1 reaches the case without it.

## 3. Cost per case after route C plus route A (all estimates, ms)

| Case | Route C stage A + A-1..A-3 | Basis | Closes |
|---|---|---|---|
| keptUnderThreeGroups, joined order | 3-6 | A-2, 10,000 × 0.2-0.4 µs; pass 0.3-0.8; no sort; fixed 0.1-0.3 | yes |
| keptUnderThreeGroups, waiting order | 1.8-5 | 30,000 joins × 40-130 ns; 10,000 jobs in (β) | yes |
| fourGroupJoins, bucket | 2-5 | 40,000 × 40-90 ns, plus 0.3-1.4 fixed and job side | yes |
| fourGroupJoins, queue | 2.7-7 | 40,000 × 60-130 ns, plus 0.3-1.8 | yes |
| oneMemberGroupsFourPerID | 6-12.5; 5-10.5 at stage B; 3-7 at stage C | the review's 8-16, less C-3's pass over 40,000 groups (2.6-5), plus A-1's 0.4-1.2; f3's per-stage savings for `oneMemberGroups` | at stage C only |
| mixedLaneGroups, option (i) | 5-10.5; 4.5-8.5 at B; 2-5 at C | between f3's `oneGroup` and `fourGroups` rows (k = 2), plus the pass | at stage C |
| pendingClaimGroups, option (i) | 4.6-9.8; 2-4.6 with A-5 | C-2′ at 0.25-0.55 µs a job plus the sort; with A-5, the pass plus 0.15-0.35 µs, no sort | with A-5 |
| userWaiters, ensures | 0.4-1.1 | every job in (β): no sort | stay closed |
| purgeJoinsTurns | 1-2.5 | 9,216 joins at A-1's per-join cost | stays closed |
| the existing retiring cases | +0.1-0.3 | A-3's pass and key collection | unchanged |

## 4. Answers against today's (S3-R16), shape by shape

"Joined": the groups' joins reached the jobs before the purge. "Waiting": they still wait for the follow when the purge runs. Every probe and pin runs in both suite orders.

| Shape | Joined | Waiting | Class |
|---|---|---|---|
| keptUnderThreeGroups | Answers and start counts equal. Queued user jobs keep their place, ticket and `queuedAt`; today re-queues them in key order. | Equal: today re-queues nothing there either. | N9; route A makes the two orders agree |
| fourGroupJoins | (not reached) | Every join is marked; `joinsAfterFollow` and `pending` end equal; no replay joins anything. | none |
| oneMemberGroupsFourPerID | Equal; `pending` is emptied before the joins walk. | As `fourGroupJoins`. | mid-turn only (12.5.15) |
| mixedLaneGroups | As option (i) classes it; route A adds nothing. | As `fourGroupJoins`. | option (i)'s |
| pendingClaimGroups | Equal. With A-5, `claimHeld`'s insertion order differs. | (not reached) | S3-R16 1(d) |
| userWaiters, ensures | Equal; today takes `continue` (`:1041-1042`). | Equal. | none |

## 5. Tests, red first

- **Order of work:** step 0 measures the five cases (N7); T-A1 is written next and run red before A-3.
- **T-A1 `purgeKeepsAQueuedUserJobsPlace`** (red before A-3; N9's probe for item 1).
  - Set-up: a blocker holds the one slot; user waiters on a, b and c are queued in that order, and their transfer keys sort c < b < a; a prefetch group covers all three; `purge(.all)`, then the blocker is released.
  - Asserts: starts in the order a, b, c (today: c, b, a); each job starts once; every waiter gets its bytes. In the waiting order: a, b, c before and after route A.
- **Pins** (green before and after):
  - **T-A2 `purgeAllRebuildsAKeptJob`**: both arms (one kept interest; two kept), with a heal and the run's token. Asserts `interests`, the counts against the recount, the index (I1), `heals` and `run.held`.
  - **T-A3 `purgeAllWithdrawsWaitingGroupJoinsWhole`**: in a bucket and in the queue, with joins waiting from a prefetch group, a user-lane group and a heal. Asserts the joins clause, that the user-lane join replays and delivers, and that the heal is forgotten.
  - **T-A4 `purgeKeepsAFailedUserJobsReadmission`**: the purge re-admits a failed user job under a prefetch group and leaves no `.retry`; no clock is driven.
  - **Route C's must-fix 2** `.all` test and `.all` model variant, extended with waiting joins, so the F-1, joins and token-lane clauses are checked after A-1 on random states.
  - **If A-5 is made:** a claim-held job in each lane order, and one with a waiter.
- No committed test is changed (G3).

## 6. Branches and kills

| Branch | Mutant | Killed by |
|---|---|---|
| A-1 `.all` gate | forced true | T-A-SCOPE (`scopePurgeWithdrawsOnlyItsIDs`, `EnginePurgeWithdrawalTests.swift:119`) |
| A-1 lane filter | dropped | must-fix 2's `.all` test (the user-lane group keeps its members) |
| A-1 kind filter | dropped | equivalent: an `.ensure` group is never below the user lane; recorded |
| A-1 joins row | removed for every token | T-A3 (the user-lane join must replay) |
| A-1 joins row | not removed | equivalent: the per-join path removes it; recorded |
| A-1 `pending` take | dropped | the F-1 clause in the `.all` model variant; `purgeDropsGroupMembers` (`EngineRegressionRound2Tests.swift:283`) |
| A-2 kept filter | waiter or user lane dropped | T-A2; `purgeKeepsUserLaneAndWaiterInterests` (`:201`), `.all` form |
| A-2 kept filter | a prefetch interest kept | T-A2 |
| A-2 recount or index | left stale | T-A2's counts clause; I1 in the model variant |
| A-2 one-kept rule | forced either way | equivalent, each arm reached by T-A2; recorded |
| A-2 run flag, heal ids | dropped | T-A2 |
| A-3 (α) | forced true | the retiring tests: `purgeTakesItsRetiredJobsRetryDeadlinesOut` (`:141`), `purgeDropsGroupMembers` |
| A-3 (α) | forced false | T-A1 |
| A-3 (α) `userInitiated > 0` | dropped | `purgeThatLeavesInterestsRelanesOnce` (`:183`) |
| A-3 `.failed` exclusion | dropped | T-A4 |
| A-3 (β) | forced true | T-A2, and every withdrawal test |
| A-3 (β) | forced false | equivalent (cost only); recorded |
| A-5 claim check | forced | the retiring tests |
| A-5 (b) | forced | `purgeThatEmptiesAJobKeepsItsEarlierRelane(claimed: true)` (`:99`) |
| A-5 `heldLane` | from the lowest token | `purgeRemovesInAscendingTokenOrder` (`:83`) |
| A-6 deferral | also outside a walk | A2.5's `a25-defer-outside` killer (s3f:7677) |

Each killer must kill in both orders (2/2).

## 7. REENTRANCY rows

- The purge's turn gains no await: `:968-976` stays synchronous, and RE-S26 (`:965`) and RE-S25 (`:977`) stand.
- The freeing slices use route C's row, extended to the new kinds. After each yield a slice re-checks only whether shutdown has begun; the list is owned by the engine and only appended to within a turn.

## 8. Lines to lift

- **`docs/ARCHITECTURE.md:300`, "user waiters re-queue":** propose under S3-R6 "user-lane interests and waiters are kept; a kept job re-queues only when its lane changes, and a failed one is re-admitted (T20)". The same words are in `docs/design/sync.md:442` (RE-S24) and `:966` (§12.4 step 3), and in the doc comments at `EngineCommands.swift:961-962` and `:991-993`. Separately, sync.md:442 says non-user waiters get `.cancelled`, while `Job.withdrawPurged` keeps every waiter (`EngineState.swift:1135`): an older mismatch, reported here, not routed.
- **Rulings :1175** ("the order across jobs (the sorted keys) … is kept"): an exception for (α), (β) and (δ). **Rulings :1169** (e2-A1.4's "then one `settleRemoval`"): none for them.
- **N9:** "skip the re-lane" becomes "skip the settle of an (α) job"; "place and ticket" becomes "place, ticket and `queuedAt`".
- **12.5.15's audit** (rulings :1259-1262): extended to the notifications (α) and (δ) send in table order, and to the callee argument. **12.5.17's inventory:** rows for A-1's pass, A-2, A-3's pass, A-5 and the new freeing kinds.
- **No §7.1 amendment:** no part removes a job, and C-2 stays inside `retire`'s funnel.

## 9. What stays above 8.5 ms, and why

- **`oneMemberGroupsFourPerID`** (6-12.5 at stage A) and **`mixedLaneGroups`** (5-10.5): every job retires, so the cost is route C's sort (2-3.5) and retirements (0.3-0.72 µs a job). Route A has nothing more to take; N8 sends both to stages B and C, and by estimate they close only at stage C.
- **`pendingClaimGroups` without A-5** (4.6-9.8): no job retires, so no stage moves it; A-5 is its route.
- **Three in-letter shapes are not gated** (rulings :887: "any mix with at most 4 interests on every id"):

| Shape | After route C + A (estimates) | What would close it |
|---|---|---|
| Failed user jobs with `.retry` deadlines, each under one to three prefetch groups | About 0.5 s, today too: the `.failed` arm's `heap.remove` (`EngineJobs.swift:362`) scans the heap once per job (`DeadlineHeap.swift:74-76`). Derived: (571.12 − 36.24) ms / 10,000 ≈ 53 µs a job (s3f:7584, :7617). | A-6: 11.5-18 (A-2 runs in (γ); getter copies remain in `relane`, `transition` and `enqueue`). An in-place re-admission: 7-12. Table order would need a ruling. |
| A bulk waiter and 3 prefetch groups | 9-14.5: the lane falls, so the re-queue is due and stays sorted | An in-place re-queue: 7-11.5. Table-order re-queues, if ruled: 4.5-8. |
| A prefetch waiter and 3 groups | 6-10, sorted, with A-2 in (γ) | A-3b: 3-5.5 |

- The failed shape is reached when `retryDelay` gives a user-lane failure a delay (`EngineFailures.swift:263-270`; it takes the lane).
- **e2-B′** is not needed by any of the five cases. It slices jobs, not groups, so it would not bound A-1's group pass either: slicing 40,000 groups' `pending` would need a group mark that every reader of `pending` checks.

## 10. Fixer hours (estimates)

| Work | Hours |
|---|---|
| A-1, placed before `:1016` | 2-3 |
| A-2 | 2.5-4 |
| A-3 | 3-5 |
| T-A1 to T-A4, and the model variant's joins | 4-6 |
| Mutant runs, in both orders | 2-3 |
| Audit (12.5.15), inventory rows, proposals, draft | 1.5-2.5 |
| Measuring the 17 purge cases after A-3 | 1.5-2.5 |
| **Core** | **16.5-26** |
| A-5 | 2-3 |
| A-3b | 2-3 |
| A-6, with the in-place re-admission | 3.5-5.5 |
| **Everything** | **24-37.5** |

Route C's 19-28 h are not included.

## What the ruling must say

1. **Item 3b is route A:** A-1, A-2 and A-3 in that order, each its own commit, after route C's stage A. A-1 replaces C-3 and runs before `withdrawPurgedJoins` (the review's should-fix 9). A-5, A-3b and A-6 are made only when triggered, as §2 says.
2. **A-1 is authorised under `.all` only.** The id-level F-1 clause lands first; the joins and token-lane clauses are its preconditions. RR-5 stands: every join is still marked in the first turn.
3. **A-2 is authorised.** It rebuilds only when exactly one interest is kept and the rebuild hashes no more than today's release; otherwise it runs today's method.
4. **N9 is widened.** The purge may skip the whole settle of an (α) job, recording its place, ticket and `queuedAt`. T-A1 is item 1's probe for it, red before A-3. The `.failed` arm stays in the sorted walk.
5. **A-3 is an exception to rulings :1175 and :1169** for (α), (β) and (δ). It is not e2-A2.4 and needs no A7 audit. 12.5.15's audit covers (α)'s and (δ)'s notifications and the callee argument: no (γ) callee reads another job's interests, counts or index.
6. **A-5 is made if `pendingClaimGroups` is above 8.5 ms after A-3.** It is that case's only route, since the case retires no job (N8).
7. **The freeing slices** are route C's A2.3 extended to four kinds: bounded by jobs and elements, drained at shutdown, with their REENTRANCY row extended.
8. **Docs:** the ARCHITECTURE.md:300 amendment ("user waiters re-queue") is proposed under S3-R6, with sync.md:442 and :966 and the two doc comments. No §7.1 amendment.
9. **Tests:** T-A1 red first; T-A2 to T-A4 and the `.all` model variant with waiting joins as pins; every mutant killed 2/2 or recorded as equivalent; no committed test changed (G3).
10. **Measure all 17 purge cases after A-3,** with their loads. N8 stands: `oneMemberGroupsFourPerID` and `mixedLaneGroups` go on to stages B and C.
11. **The three ungated in-letter shapes (§9):** gate them, with A-6 (plus an in-place re-admission) and A-3b as their routes, or record them as open for the owner. The failed-user shape is about 0.5 s today (derived from measured figures; an estimate).
12. **A miss after route A and route C's stage C is blocking,** with no route in cycle 23. J-TRUE, A-4 and e2-B′ are not authorised. Every figure here is an estimate; the core is 16.5-26 h.
