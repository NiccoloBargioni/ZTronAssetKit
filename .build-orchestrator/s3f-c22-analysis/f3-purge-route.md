# F3: the purge's six C2 misses after cycle 22 (input to S3-R28)

This is a read-only analysis at `9aa337c` (`.worktrees/s3f`, branch `wp/s3f`). Nothing was built, run or measured for it.
- A figure marked *measured* cites the fixer's draft (`docs/adr-drafts/s3f.md`, cited as "s3f:") or the cycle-22 verifier logs (`s3f-probes-c22/correct-bench-perf1.summary.log`, "v22:").
- Every other figure is an *estimate*, with its basis beside it (G2). Unit costs are e2's: a `TransferID` hash (a 66-byte string) is h ≈ 60-90 ns, a small allocation 50-100 ns, and a `Job` copy's refcount traffic 100-150 ns. Below they are calibrated against the measured shapes.
- Paths are under `Sources/ZTronAssetSync/Engine/` unless given in full.

## 0. Verdict

- **e2-A2.1 to A2.4 cannot close any of the six** (estimate). They leave `oneGroup` at about 15-22 ms and `fourGroups` at 41-48 ms (§2).
  - e2's after-A2 figure for (i), 5-12 ms (e2:193), does not hold. e2-A1 measured as e2 predicted (33.97 ms; e2 said 33-41), but what A2.1-A2.4 target totals only 14-21 ms of the remaining 36.
  - Three things lie outside A2: the per-interest withdrawal (about 8.5 ms at k = 1 and 34 ms at k = 4), three more hashes per job, and e2-A2.5's own per-job insert.
- **A one-turn route (route C, §3) can plausibly close all six:** about 5-12 ms with today's sorted walk, and 2-7 ms with the table rebuilt or walked in table order. Its answers equal today's. It has four new conditions and one precondition (an id-level F-1 clause). Only a measurement decides.
- **Two in-letter shapes have no gated case,** and route C is not expected to close them (§3.6).
  - **`keptUnderThreeGroups`:** a user waiter on each id plus three prefetch groups. The purge keeps all 10,000 jobs and withdraws 30,000 pairs in place. Estimated at 38-48 ms today and 34-39 ms after route C.
  - **`fourGroupJoins`:** 40,000 waiting joins. Estimated at 15-22 ms.
  - For the first, sliced turns (e2-B′, §4) are the only route found. The ruling must gate these shapes or route them.

## 1. Cost model of `9aa337c`

**The walk.** `performPurge`'s synchronous stretch (`EngineCommands.swift:968-976`) runs `withdrawPurged` (`:994-1066`):
1. the event walk (`:1017`; empty in `purgeTurns`);
2. the sorted keys (`:1019`);
3. one access per job (`:1022` → `Job.withdrawPurged`, `EngineState.swift:1129-1153`);
4. the member drops and heals (`:1028-1039`);
5. one settle per job (`:1058` → `settleRemoval`, `EngineJobs.swift:424-438` → `retire` `:442-462` → `removeJob` `:483-530`);
6. A2.5's heap pass (`:1062-1065`).

**The draft has no per-part split of the job walk.** Its probe (PROBE-C21-PURGE-PARTS, s3f:7530-7545) times only the event walk (9.09 → 2.87 ms). So the parts below are anchored on measured shapes and the differences between them, taken from one gate run where possible (s3f:7791-7797). Only the split *inside* R and W is bottom-up.

| Part | Where (`9aa337c`) | How it is fixed |
|---|---|---|
| **S**, the walk skeleton: the key sort and one in-place access per job, with its one-element `interests.sorted` (`EngineState.swift:1135`) | `EngineCommands.swift:1019`, `:1022` | measured as `userWaiters` and `ensures`, which walk 10,000 jobs and withdraw nothing: 6.82 and 6.92 ms (s3f:7618-7619); 7.13 and 7.15 (v22:50-51). Split (estimate): sort 2-3.5; per job 0.4-0.5 µs (a hash, the `Optional` subscript's move out and in, the allocation, misses) |
| **W**, withdrawing one 1-id interest and dropping its member: `setInterest(nil)` (3 `InterestToken` hashes, `EngineState.swift:920-940`), `release` (1-2 `AssetID` hashes, `:1167-1171`), the `off` arrays (`:1140`, `:1145`), `dropGroupMember` (`EngineJobs.swift:696-701` → `Group.dropMember`, `EngineState.swift:1381-1391`) | as listed | k = 1: about 0.85 µs a job (oneGroup − S − R). k = 4: 0.88 µs per extra interest, *measured difference* (62.21 − 35.71)/30,000. One shared job: 0.43-0.46 µs a pair (sharedJob 4.63/10,000, sharedJobFourGroups 17.82/40,000) |
| **F**, the `.scope` filter: `assets.filter` and `intersection` (`EngineState.swift:1131`, `:1136`), `isPurged`'s `entry(for:)` copy (`EngineCommands.swift:1002-1011`; `ValidatedManifest.swift:78-83`) | as listed | 4.03 ms, *measured difference* (39.74 − 35.71) |
| **R**, the retirement | `EngineJobs.swift:424-530`, `:603-620`; `LaneQueues.swift:262-266` | about 2.0 µs a job, 20 ms at 10,000 (oneGroup − S − W). Split below |
| **G**, 10,000 groups' tables instead of one | `EngineJobs.swift:696` | 1.40 ms, *measured difference* (37.11 − 35.71) |
| **H**, `retryJobs` only: the heap pass over 10,000 entries with `retired.contains` | `EngineCommands.swift:1064` | 1-1.5 ms (estimate) |

**R's split** (estimates, with h ≈ 70-80 ns so that the parts sum to the inferred 2.0 µs):
- 10-11 removals on empty indexes (`EngineJobs.swift:491-511`): `Set.remove` and `Dictionary.removeValue` hash even on an empty collection (SDK lines in s3f:7628-7631). 7-9 ms.
- `holdIfUnwanted`, `retirement` and `removeValue` with its backward shift (`:427`, `:445`, `:484`). 2.5-3.5 ms.
- e2-A2.5's per-job insert into `retiredRetries` (`:517-520`), with the Set's growth rehashes. 1.6-2.2 ms. The measured signature: after A2.5 the four shapes that retire 10,000 jobs rose 1.62-2.17 ms, while `sharedJob`, `sharedJobFourGroups` and `userWaiters` rose 0.02-0.04 (s3f:7574-7587 against :7608-7621). A load effect would have scaled with each figure. The fixer left the cause open (s3f:7625).
- `storedCount` on every removal: 16 `Kind` lookups. 0.8-1.6 ms.
- The geometric compactions: about 20,000 `isValid` calls, each a hash and, for a live job, a `Job` copy (`EngineJobs.swift:603-620`). 2-3 ms.
- The `Job` deinit: 1.5-3 ms.
- Two notifications, the progress check and the `ClaimKey`: 0.3-0.6 ms.

**Totals and dominant parts** (best of 3, measured, s3f:7791-7797; the model's sum beside it):

| Shape | Measured | S + W + R (+ F, G, H) | Dominant parts |
|---|---|---|---|
| `fourGroups` | 62.21 | 7.5 + 34.9 + 20.2 = 62.6 | W at k = 4 (56%), R (33%) |
| `oneGroupScope` | 39.74 | 7 + 8.5 + 20.2 + F 4.0 = 39.7 | R (51%), W (21%), S (18%), F (10%) |
| `oneMemberGroups` | 37.11 | 7 + 8.5 + 20.2 + G 1.4 = 37.1 | R (54%), W, S |
| `retryJobs` | 36.06 | 7 + 8.5 + (R − 2.5 compaction + 1.0 bigger frees) + H 1.2 ≈ 35.4 | R (55%), W, S. No compaction: its queue holds no entries, since every job started once |
| `oneGroup` | 35.71 | 7 + 8.5 + 20.2 = 35.7 | R (57%), W (24%), S (20%) |
| `sharedJobFourGroups` | 17.82 | 40,000 × 0.43 + one retirement with a 10,000-id progress check ≈ 17.7 | the per-pair `tokensByID` releases with `IDTokens.others` (`EngineState.swift:768-778`), and 40,000 drops |

## 2. After e2-A2.1 to A2.4 (as e2 §3 and its review define them)

What each part saves, at 10,000 retired jobs (estimates, from §1's split):
- **A2.1, empty-index guards:** 10-11 hashes a job, so −6.9 to −9.0 ms. `retryJobs` gets −6.2 to −8.2, since `failedJobs` is not empty there.
- **A2.2, a counter and one compaction after the walk:**
  - It saves `storedCount` and the geometric passes, for −2.7 to −4.4 ms. The one pass after the walk is cheap: once the table is empty, `isValid` takes `lookup`'s count-0 path.
  - `retryJobs` saves `storedCount` only: −0.8 to −1.6.
- **A2.3, freeing later:**
  - It saves the deinit, less one append per job: −1.1 to −2.8 ms (`retryJobs` −1.3 to −3.0).
  - The later turn costs 1.5-3 ms.
- **A2.4, table order in two passes:**
  - It saves the sort and the walk's own hash and moves: −2.9 to −4.7 ms.
  - Pass 2 still hashes each retired key (review should-fix 7).

| Shape | Now (measured) | After A2.1-A2.4 (estimate) | Without A2.4 (no order audit) |
|---|---|---|---|
| `fourGroups` | 62.21 | 41.0-48.3 | 46.0-51.5 |
| `oneGroupScope` | 39.74 | 18.8-26.1 | 23.5-29.0 |
| `oneMemberGroups` | 37.11 | 16.2-23.5 | 20.9-26.4 |
| `retryJobs` | 36.06 | 18.6-24.9 | 23.3-27.8 |
| `oneGroup` | 35.71 | 14.8-22.1 | 19.5-25.0 |
| `sharedJobFourGroups` | 17.82 | 17.5-17.8: A2 touches neither the per-pair path nor a one-job walk | the same |

## 3. Route C: one turn, whole-job retirement

**Representations considered.**
- **An index from id to interest (a global `tokensByID`)** helps only a narrow `.scope`, which is not among the misses. Under `.all` every pair is withdrawn whatever the index. Each job already has such an index (`Job.tokensByID`, `EngineState.swift:825`).
- **Tombstoned or lazy withdrawal** makes every reader filter the withdrawn interests. That is e2-B's audit without e2-B's bound.
- **What pays is not editing what dies:**
  - a job retired whole needs none of its own bookkeeping (C-2);
  - under `.all`, a group loses every pending member at once (C-3: whole interests instead of pairs).

  Outside `.all`, the drop is the per-pair cost that remains.

### 3.1 Parts (each its own commit, with S3-R27 item 1's exclusivity rule)

**e2-A2.1, A2.2 and A2.3, as authorised.** A2.3's freeing runs in pinned slices of 512, because under C-2 a retired job keeps its interests and so costs more to free (§3.2).

**C-1 replaces e2-A2.5's collection.**
- Inside the walk, `removeJob` leaves its retry deadline, as A2.5 already does.
- One pass after the walk removes every `.retry(t, e)` whose job is gone or has another epoch: `let jobs = self.state.jobs; heap.removeAll { if case .retry(let t, let e) = $0 { jobs[t]?.epoch != e } else { false } }`.
- There is no per-job `DeadlineReason`, and no Set. On a table the walk emptied, each lookup takes the count-0 path.
- A stale `.retry` that predates the purge is removed too. It is harmless today, because the firing re-validates it (`EngineTimers.swift:110-112`). No clause names that state; record it.

**C-2, whole-job retirement.**
- The walk reaches each job by `index(forKey:)` (one hash), then reads it in place through `values[i]` (no move, no allocation; the SDK lines are cited in s3f:7496-7499).
- **The conditions.** A job is retired whole when:
  - (a) every interest is below `.userInitiated`, is not `.waiter`, and loses all its ids (`.all`, or C-4);
  - (b) its lane before the last removal equals its lane before the first, so no re-lane is due (the `before != last` arm, `EngineCommands.swift:1051`);
  - (c) no claim names its content (read from a local copy of `claims`; the purge changes none);
  - (d) it is not verifying or committing.
- **What it does.** After the access, in today's order:
  1. the drops (unless C-3 applies), the heals and the run's `held`;
  2. `retire`'s abandon and breaker record;
  3. `remove(at:)`;
  4. `removeJob`'s effects on the removed value;
  5. the two notifications.
- Its interests, counts and `tokensByID` are never edited. Every other job takes today's path.

**C-3: under `.all`, drop the members once per group.**
- It needs the **id-level F-1 clause** first, in its own commit, with every suite green:
  - at `EngineCommands.swift:1884`, `interests[token]?.assets.contains(asset) != true` replaces `interests[token] == nil`;
  - the join and owed exemptions stay.
- One in-place pass over `groups.values` empties `pending` for each group whose kind is `.prefetch` and whose lane is below `.userInitiated`. Under `.all`, the job walk then drops no member.

**C-4: `.scope` and `.evictable`.**
- A job counts its purged ids without building a Set. If all of them are purged, it takes `.all`'s path.
- `isPurged` reads the copy in place: `position(of:)`, then `entries[i].policy` or `scope.contains(entries[i])`.
  - Both are public (`ValidatedManifest.swift:15`, `:86-91`), so this needs no `ManifestEntry` copy and no edit to ZTronAssetModel.
  - This answers 12.3's "`isPurged` keeps its entry copy" and 12.5.16.

**C-5: the rebuild (sorted order kept).**
1. One table-order pass collects (key, index) pairs, which are sorted.
2. The visits go by index.
3. The retired jobs are not removed one by one. A new table holds the kept jobs, rehashed, and the old storage goes to the freeing.
4. Each retired value's `interests`, `tokensByID` and `assets` are moved out in place to the freeing list (a `Job` method), so the old storage's shells free in one turn (0.3-0.5 ms).

There is no rebuild when nothing was retired. **A2.4's table order** is a further option, after the order audit (A7's rule).

### 3.2 Cost (estimates)

**Per retired job (sorted):**
- 0.28-0.56 µs at k = 1, and 0.31-0.60 at k = 4. That is a hash, the in-place read, the claim check, `remove(at:)` with its shift, `removeJob`'s guarded effects and the append.
- With C-5, 0.18-0.36.

**Fixed costs:**
- the sort: 2-3.5 ms;
- C-3's pass: 0.05-0.4 ms with 1 to 4 groups, and 0.65-1.25 ms with 10,000;
- the final compaction: 0.1-0.2 ms;
- C-1's pass: 0.1-0.3 ms at `retryJobs`.

| Shape | C-1 to C-4, sorted | + C-5 (sorted) | + A2.4, table order | What decides it |
|---|---|---|---|---|
| `fourGroups` | 5.4-10.4 | 4.5-8.7 | 2.3-4.9 | C-3. Without it, add 5-7.5 ms: 40,000 drops and four sets read per job |
| `oneGroupScope` | 6.8-12.2 | 6.0-10.5 | 3.8-6.7 | 10,000 drops (no C-3 under `.scope`), 1-1.5 ms; C-4's `isPurged`, 0.6-0.8 ms |
| `oneMemberGroups` | 5.7-10.8 | 4.9-9.1 | 2.7-5.3 | C-3's pass over 10,000 groups |
| `retryJobs` | 5.9-11.1 | 5.1-9.4 | 2.9-5.6 | `failedJobs`' real removals, 0.8-1.3 ms |
| `oneGroup` | 5.0-9.5 | 4.2-7.8 | 2.0-4.0 | the sort, and one hash and shift per job |
| `sharedJobFourGroups` | 0.6-1.5 | the same | the same | C-2 with C-3. C-2 alone: 4.5-7.5 |

**The freeing slices.** 0.25-0.4 ms each, at 512 jobs of four interests. Unsliced, the freeing would be 5-8 ms at k = 4.

**The cases that close today stay closed.** `userWaiters` and `ensures` fall to about 3.5-6 ms, because C-2's read replaces the move and the allocation. The joins cases and `purgeWhileOwedTurns` are untouched.

### 3.3 Answers against today's

- **C-2** makes, for each job, the same effects in the same order. Inside one job, the drops' order is unobservable (e2-A1.3: no drop resumes anything, because an `.ensure` interest is always user-initiated).
- **C-3** is equal on every state where today's purge leaves F-1 intact.
  - F-1 (`EngineCommands.swift:1883-1889`) requires that each pending member's transfer holds the token's interest, or its join or owed item.
  - Under `.all` the walk withdraws all of those. So a member that today's walk did not drop breaks F-1 after today's purge.
  - The id-level clause turns this argument into a check. The joins' and owed arm's later drops become no-ops.
- **C-1 and C-4** give the same values. C-1 differs only on the stale-retry state noted in §3.1.
- **C-5** keeps the contents. The table's iteration order is per process, so no test can depend on it (S3-R16 1(d)).
- **A2.4** changes the order of retirements, re-queues and abandons across jobs: order and place, only after the audit.
- **What changes for observers.** Mid-turn states change: the job's interests are not removed one by one, and under C-5 retired jobs stay in the table until the rebuild. Extend 12.5.15's audit to the walk and record it.

### 3.4 Branches and kills (2/2 in each order that reaches the branch; by value)

| Branch | Mutant | Killed by |
|---|---|---|
| C-1's epoch test | `!=` → `==` | `purgeTakesItsRetiredJobsRetryDeadlinesOut` (y's deadline must stay) |
| C-1's pass | removes nothing | the same test, and the cases' `retriesAfter == 0` |
| C-1's walk flag | set outside a walk | A2.5's `a25-defer-outside` killer (s3f:7677) |
| C-2 (a) | forced true | `purgeKeepsUserLaneAndWaiterInterests` (a prefetch waiter's and a user-lane group's interests stay) |
| C-2 (b) | forced true | `purgeThatEmptiesAJobKeepsItsEarlierRelane(claimed: false)` (`[.setPriority(.bulk), .cancel]`) |
| C-2 (c) | forced true | `purgeRemovesInAscendingTokenOrder`, and `…EarlierRelane(claimed: true)` |
| C-2 (d) | forced true | a purge while a publication is held at its first store unit, if a purge suite does that (`EngineRegressionRound2Tests.swift:444-448` and `EngineIdleTests.swift:227-231` hold a job verifying; the run decides). Otherwise a new test: the job stays until its verification ends |
| C-2, any condition | forced false | Equivalent: cost only (S3-R19 item 2) |
| C-3's `.all` gate | forced true | T-A-SCOPE (`scopePurgeWithdrawsOnlyItsIDs`) |
| C-3's group filter | every group | `purgeKeepsUserLaneAndWaiterInterests` (the user-lane group keeps its members) |
| the id-level F-1 clause | the id test dropped | a seam that leaves a member pending at a job whose interest lacks the id, as `forgetIndexForTests` does for I1 |
| C-4's count | forced "all purged" | T-A-SCOPE |
| C-5's "no rebuild when nothing was retired" | either way | Equivalent: same contents |
| A2.1 to A2.3 | as 12.3 | as 12.3: each index's clause, adding one for `unfollowed`, `systemHeld`, the run's `held` and `spaceAdmitted` (s3f:7631-7637); the recount clause; the pinned slices |

### 3.5 Tests and pins

**Tests.**
- The purge suites stay unchanged (G3).
- New:
  - the F-1 clause's seam test;
  - C-2 (d)'s test, if none reaches it;
  - T-A-SCOPE extended with a second job whose ids are all purged (C-4);
  - the freeing slices' pin (recorded slices, as `shutdownSlices`).

**Pins.** The twelve purge cases stay gated as they are. Record the purge's turn and the longest freeing slice beside each.

### 3.6 What route C does not reach (in-letter by S3-R27 12.1; no gated case)

**`keptUnderThreeGroups`**, a user waiter on each of 10,000 ids plus three prefetch groups over them:
- The kept jobs take today's path: three in-place withdrawals at about 0.85 µs each, then a re-lane that re-queues every job (`relane`'s `isUser`, `EngineJobs.swift:311-314`) with two `Job` copies, and then a compaction.
- That is about 38-48 ms today, and 34-39 ms after route C (estimates).
- Even with every in-place cut, it is about 15-21 ms. One turn cannot hold it.

**`fourGroupJoins`**, 40,000 joins waiting for the follow:
- The case at 9,216 joins measures 5.00 ms (s3f:7620), so 40,000 joins give at most about 22 ms, or 15-22 ms (estimate).
- RR-5 binds these joins to the first turn, before any drain turn.

**Sizing a turn.** A one-turn route costs O(the pairs withdrawn from kept jobs) at about 0.4-0.9 µs per pair, plus O(kept jobs) re-lanes. For a kept shape like the first, that does not fit the bar in one turn.

## 4. e2-B′: e2-B re-specified with the review's corrections (for its own review; not authorised)

### Phase 1, the purge's turn

1. **As today:** `purgeEpoch`, `lastStamp`, `dropBindings` and `settleRun` (`EngineCommands.swift:969-974`).
2. **`withdrawPurgedJoins`** as A1 left it (RR-5). B′ does not bound it, so `fourGroupJoins` stays open. Holding the drain while a walk is pending is named, not designed.
3. **The in-flight jobs** (`inFlight`, `EngineState.swift:458`; verifying and committing included) are visited whole, with C-2 where it applies (row 8).
4. **The marks.** Every other job with a non-user, non-waiter interest gets this walk's mark, in one in-place pass over `jobs.values`: 1-2.5 ms at 10,000 (estimate).
   - The walk is `PurgeWalk(serial, request, copy: applied, list, cursor)`. Capturing the copy is O(1).
   - **One mark per walk:** `Job.purgeMarks`, ascending walk serials (should-fix 11). A visit clears only its own walk's mark. A job re-created under an old key carries none.
5. **The store's purge starts one hop after this turn, as today, and does not wait for the slices.**
   - Its reason: no marked job can publish before its visit. In-flight jobs are visited in step 3, and the start, the retry and the unblock all visit first (touch, below).
   - So row 9 and the commit row (should-fix 10) equal today's.
   - The owned task waits for the walk's end after `store.purge` (`EngineCommands.swift:1150`) and before it answers. Tests assert after the answer.
6. **The first slice** is scheduled, with a flag and a hold seam, as `releaseFollowUp` is (`EngineCommands.swift:442-480`).

### A slice

- **It visits in sorted order.** The first slice sorts the list, at 2-3.5 ms (estimate).
- **Re-validation:** `jobs[t]` exists and carries this walk's mark.
- **The withdrawal.** The slice withdraws this walk's pairs from the job's token cursor on, and **drops their members and forgets their heals** (M2; `EngineCommands.swift:1028-1039`). It settles each portion as `dropInterest` settled one interest: re-laned from the lane before the portion's first removal, and retired at the last.
- **The bound** is at most `purgeJobsPerTurn` jobs (256) and `purgePairsPerTurn` pairs (512) *visited*, withdrawn or not. It stops between two interests, which splits a job by interest (M4).
- **One interest is never split.** In the reference set, a whole interest of 10,000 ids measures 4.63 ms (`sharedJob`).
- **Its REENTRANCY row:** "nothing: the slice re-reads the walk, each job, its mark and its cursor".

### Visit on touch (M1, M3, should-fix 13)

Before a path below changes a marked job, or decides on one, it runs every pending walk's withdrawal on that job, oldest walk first, with the settle. This happens in the touching turn, and counts against that turn's C2.

**The paths:**
- **Interests:** `addInterest` on the content (`EngineJobs.swift:127`): waiters, ensures, joins, runs and heals.
- **Claims:** a claim on the content (`EngineCommands.swift:236`, `:576`), *before it is counted*, so that the settle sees no claim, as today's walk did.
- **Starts:** the pump's start (`EngineDispatch.swift:688`), a retry's firing (`EngineTimers.swift:110` → `retryDue` `:199`), the re-admissions and the unblocks.
- **Answers:** `resolveAll` (`EngineJobs.swift:721`), `failFast` (`:857`), `failFastJoiner` (`:243`), `answerPresentMembers` (`EnginePresence.swift:345`) and `sparePresent` (`EngineFailures.swift:534`).
- **Moves:** every take-off (`EngineFollow.swift:594`, …), the commit's re-routes (`EngineDispatch.swift:1127` → `reroute` `:1203`), `supersede` (`:1336`) and the follow's apply.
- **Removals:** `dropInterest`'s callers: a release, a waiter's withdrawal and a cancel.

**The audit** covers the 211 `state.jobs[` sites in 12 engine files (`grep -c` at `9aa337c`) and every loop over `jobs`. A read-only site, such as introspection or the invariants, is listed as one that does not touch.

**Its cost** is one job's pending pairs. For a small job that is at most 0.5-2 ms. On one kept job of 10,000 ids with a waiter and three groups it is 12-18 ms (estimate), so a case pins it (`touchKeptShared`). If that case misses, the touch must defer: a named difference, not designed here.

### Clauses

- A pending walk implies a scheduled or held follow-up.
- A mark names a pending walk that lists the job.
- A marked job is not in flight.
- A walk's cursor is within its list.
- **There is no "unmarked" clause** (M2).

### Shutdown and cancel, against today's (M11, should-fix 10)

**Today, shutdown:**
- The first turn withdrew everything.
- The caller is answered `.shutDown` at once (`EngineShutdown.swift:241-242`).
- The owned task still runs `store.purge`: nothing checks the lifecycle before `:1150`, and `isRunning` is read after it (`:1151`). Shutdown joins the owned tasks before the store closes, so the records are purged.

**Under B′, shutdown:**
- It first drains every pending walk in its own sliced turns, before `settle` (`EngineShutdown.swift:170-218`). That drain clears the marks, withdraws the remaining pairs (so that no group event reports a member today's purge dropped) and resumes the owned task's wait.
- The store's purge started as today did. So the caller's answer and the durable state equal today's.

**Cancel:**
- Today, `withdrawEntry(token, stopWork: true)` (`EngineCommands.swift:1593-1603`) answers `.cancelled` and cancels the owned task. A purge has no group to release.
- Under B′ the same happens, and the walk runs on to its end: the walk is the engine's state, not the caller's. The owned task's wait ignores cancellation, and the walk's end or a shutdown resumes it.

### Differences left, for the ruling (M12)

- **A kept marked job's re-queue comes at its visit.** A job queued between slices can then be served before it, where today the purge's turn re-queued every kept job first. This is order and place. A fix would be to reserve a block of back places in phase 1 and re-queue at them (sketch only).
- **`retireProgress` events and abandons** spread over the slices (touches first).
- **Introspection** sees marked jobs unvisited. It is internal (`EngineCommands.swift:1625`).

Everything else, e2 §1.3's rows 1-8 and 10-13 with the commit and cancel rows, equals today's by construction.

### Tests

Each test asserts by value. A test with a follow runs in both orders. The holds are `holdPurgeFollowUps` and `resumePurgeFollowUps`. No kill counts by a hang.

| Test | What it checks |
|---|---|
| T-B′1 (M1) | An ensure lands between slices on a prefetch job that failed once (cap 2, source [fail, stage]). It is answered success (a fresh job), not `.failed` at the cap |
| T-B′2 (M2) | A late join batch (`joinGroup`'s yield) lands on a marked job. The member stays pending with its interest, and `invariantViolations()` is empty |
| T-B′3 (M3) | A commit's re-route and a supersede's re-route off a marked job: no purged pair is re-routed or requested |
| T-B′4 | A new prefetch group and a new run on a purged id are fetched, and the run's report is today's |
| T-B′5 | With a free slot, the start visits first: no request for the marked job |
| T-B′6 (M11) | A shutdown between slices: the caller gets `.shutDown`, the tasks end, the walk is gone, and the store's records are purged, as today |
| T-B′7 (should-fix 10) | A cancel between slices: `.cancelled`, the walk ends, and the store's state is today's |
| T-B′8 (should-fix 11) | A second purge over shared jobs: both answer, each walk visits a shared job once, and the stored set is that of the two purges in sequence |
| T-B′9 (should-fix 13) | A marked `.system` job fails between slices: its heal is not kept |
| T-B′10 (row 10) | An apply makes a purged id `.essential`: the walk keeps its copy |
| T-B′11 | The clauses hold after every slice |

**Pins:**
- At bounds of 4 and 4, a purge of ten one-id jobs records `purgeSlices == [4, 4, 2]`.
- At 4 pairs, a job of three interests of two ids each records a split by interest.
- Each bound's drop-mutant fails 2/2.
- Every purge case is gated, with phase 1, the longest slice and the longest touch recorded beside it.
- Three cases are added: `keptUnderThreeGroups`, `touchKeptShared` and `fourGroupJoins`.

**Cost** (estimate): phase 1 is 1-3 ms plus the joins; a slice 0.5-3 ms (the first adds the sort); the heartbeat 3-6 ms. A touch on a big kept job stays open.

## 5. Recommendation

**The order:**
1. **Stage A.** e2-A2.1, A2.2 and A2.3, C-1 and C-4; then the id-level F-1 clause on its own; then C-2 and C-3.
   - Expected: 5-12 ms for the five 10,000-job shapes, and about 1 ms for `sharedJobFourGroups`.
   - Take step 0's figures for `keptUnderThreeGroups` and `fourGroupJoins` first.
2. **Stage B.** C-5, the rebuild in sorted order. It needs no order audit. Expected: 4-10.5 ms.
3. **Stage C.** e2-A2.4's table order, only after the order audit (A7's rule) and with the iOS SDK cited. Expected: 2-7 ms.
4. **e2-B′**, after its own review, for whatever misses after stage C, and for the two added shapes. Most of C-2 and C-3 carry over into B′'s visits.

**The decision rule** (item 1's form):
- After the last part of each stage, measure every purge case: the twelve, plus the added ones. Each is its heartbeat, best of 3, with 1-minute loads before and after each run.
- At or below 8.5 ms, a case closes. From 8.5 to 10 ms it is "at the edge", and not blocking. Above 10 ms at a 1-minute load of 10 or less, it is a miss.
- The next stage runs only if some case is above 8.5.
- A miss after stage C is blocking. It is reported with its parts' figures, and B′ is its route once reviewed.
- If the F-1 clause turns any test red, C-3 is not made. That red test is reported as a finding of its own (F-1's id direction), and `fourGroups` then depends on stage C.

**Fixer hours** (estimates, at e2 §6's rate of about 1-1.5 h per part with its tests, kills and commit):

| Work | Hours |
|---|---|
| Stage A (eight parts, the 12.5.15 audit's extension, measurement, records) | 12-18 |
| Stage B | 3-4 |
| Stage C (with the order audit) | 4-6 |
| Route C in all | 19-28 |
| e2-B′ (its review not included; of which the touch audit over 211 sites is 8-14 h, and the tests 8-12 h) | 30-50 |

## What the ruling must say

1. **The six misses stand as measured and blocking** (s3f:7791-7797; c22 correct #4, reqs #1). e2-A2.1 to A2.4 alone are estimated to close none of them (§2). e2's after-A2 estimate for (i) is superseded, and the draft records that.
2. **Route C is authorised in one turn,** in stages A to C (§3.1, §5). Every in-place access follows item 1's exclusivity rule: locals for `applied`, the request and `claims`, and the writes made after the access.
3. **C-1 replaces e2-A2.5's per-job collection with one pass keyed on the job table.** The stale-retry difference is recorded, and A2.5's kills are re-run.
4. **C-2's four conditions are binding,** with its one hash per job and §3.4's kills. Each condition forced false is Equivalent (cost only).
5. **C-3 needs the id-level F-1 clause first,** committed alone with every suite green. A red test there is a finding, and C-3 is not made.
6. **C-4 authorises `isPurged`'s in-place read** through `position(of:)` and `entries[i]` (public; no ZTronAssetModel edit). This amends 12.3's "`isPurged` keeps its entry copy" and retires 12.5.16.
7. **C-5's rebuild keeps sorted order and needs no order audit.** e2-A2.4's table order still needs A7's audit and the iOS SDK citation. The freeing is sliced and pinned (A2.3), not one later turn, because under C-2 retired jobs keep their interests.
8. **The decision rule and the stage gates are §5's.** Every purge case is measured after each stage, with loads (G2).
9. **Two cases are gated as in-letter** (12.1): `keptUnderThreeGroups` and `fourGroupJoins`, measured at step 0 before any part. Their route is e2-B′ once it has been reviewed. Until then, a miss is blocking with no route, or the orchestrator asks the owner about that shape.
10. **e2-B′ (§4) goes to an independent review before any authorisation.** Its review checks five things: visit on touch at every listed path, claims before they are counted; a mark per walk; both bounds, with a split by interest; the store's purge one hop after phase 1; and shutdown and cancel against today's.
11. **The ruling must class e2-B′'s remaining order difference** (a kept job re-queued at its visit), or require the reserved places, and name the window it uses (M12).
12. **Records:**
    - item 9's inventory rows for C-1's pass, C-3's pass, the rebuild and the freeing slices;
    - RE-S24's text, as 12.3 says;
    - the extended 12.5.15 audit.
13. **Hours** (estimates): route C 19-28 h; e2-B′ 30-50 h after its review.
14. **Every figure here not cited as measured is an estimate.** The fixer's measurements decide, and an estimate never closes a case.
