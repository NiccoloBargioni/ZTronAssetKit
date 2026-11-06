# Review of f3-purge-route.md (independent reader, CLAUDE.md P4)

Read-only, at `9aa337c` (`.worktrees/s3f`). Nothing was built, run or measured for this review.
- A figure not cited as measured is an estimate, with its basis beside it (G2).
- "SDK" lines are the macOS 27.0 and iOS 27.0 `Swift.swiftinterface` (`arm64e`). I read them this session, and the cited lines are the same in both.
- Paths are under `Sources/ZTronAssetSync/Engine/` unless given in full. "Tests/…" is `Tests/ZTronAssetSyncTests/Engine/`.

## Verdict: CORRECTED

**What holds** (checked against the code, the draft, the probes and S3-R27):
- **The figures.** The measured figures are quoted correctly (s3f:7574-7621 and :7791-7797; v22:43-51), and §1's sums and §2's arithmetic are right.
- **§2's conclusion is robust.** S and W alone come to about 15 ms at k = 1, and A2.1 to A2.4 do not touch W. So no plausible error in R's split lets e2-A2 alone close `oneGroup`.
- **C-1, C-2's four conditions, C-3 and C-4 give today's answers** at `9aa337c`:
  - **C-2.** `retire` reads only whether the job's interests are empty (`EngineJobs.swift:442-462`). `removeJob` reads only `ledgerBytes`, `adopt`, `epoch` and `assets` of the removed value (`:483-530`). Nothing in the walk writes `claims`: its writers are `recordGroup` (`EngineCommands.swift:236`), `claimNewlyListed` (`:576`) and `dropClaim` (`:536-545`).
  - **C-3.** After today's `.all` purge, no job, waiting join or owed item holds such a group's token: the owed map comes from `eventsAfterFollow` alone (`EngineCommands.swift:1780-1787`), and the token-lane clause ties every interest, join and owed item to `Group.lane` (`:1800-1807`). So a member left pending breaks F-1 (`:1883-1889`), and the id-level clause is the right check of the state before the purge.
  - **C-4.** I2 (`:1829-1833`) makes "every id of the job purged" equal to `.all` for that job. `entries` and `position(of:)` are public (`Sources/ZTronAssetModel/Manifest/ValidatedManifest.swift:15`, `:86-91`).
  - **The count-0 paths** the report relies on exist (SDK :15906-15913 `lookup`, :15885-15893 `index(forKey:)`).
- **§4 (e2-B′)** was checked only for what it says about today's code: the `:1150` and `:1151` lifecycle reads, and the 211 `state.jobs[` lines in 12 files. Both are correct. Its design is left to its own review.

**What does not hold:**
- C-5, as written, traps (must-fix 1).
- One kill in §3.4 cannot be reached (must-fix 2).
- §3.6's "two shapes" leaves out two in-letter shapes that route C's own conditions send to today's path (must-fix 3).
- C-2 bypasses ARCHITECTURE §7.1's funnel (must-fix 4).

With these corrections, route C stays the best one-turn route found.

## Must fix

1. **C-5 traps: a removal inside the walk invalidates every index the walk collected.**
   - **Evidence.**
     - `_NativeDictionary._delete(at:)` calls `invalidateIndices()`, which runs `_storage._age &+= 1` (SDK :16136-16141, :15726-15728).
     - `Values.subscript(position:)`'s `_modify` checks the age with a precondition (SDK :8054-8060 → :15835-15838).
     - C-5's step 3 keeps C-2's retired jobs in the table, but an emptied job whose (b) fails, with no claim and not verifying or committing, still takes today's path: `settleRemoval` → `retire` → `removeJob`'s `removeValue(forKey:)` (`EngineJobs.swift:432`, `:442`, `:484`; the arm at `EngineCommands.swift:1051-1058`). The next visit by a collected index then traps.
     - `purgeThatEmptiesAJobKeepsItsEarlierRelane(claimed: false)` has one job (Tests/…/EnginePurgeWithdrawalTests.swift:100), so no visit follows the removal, and no test in the suite would show the trap. Must-fix 3's mixed-lane shape would.
   - **Two more faults if anything reads the table before the rebuild.** The retired jobs are still in `state.jobs` at their epochs:
     - C-1's `jobs[t]?.epoch != e` keeps their `.retry` deadlines;
     - A2.2's compaction finds their queued entries valid (`isValid`, `EngineJobs.swift:615-620`), and its guard still counts them (`:604`). The queue clause of `invariantViolations` (`EngineCommands.swift:1891-1892`) then fires after the rebuild.
   - **Correction.**
     - Under C-5, every removal the walk makes waits for the rebuild, through a walk mode of `removeJob`, so the funnel stays one.
     - State the precondition that no key is inserted into or removed from `state.jobs` between the collection and the rebuild, and check it in debug builds.
     - Order the steps: the walk, the rebuild, the compaction, C-1's pass, then the final `notifyObservers` (`EngineCommands.swift:1065`).
     - Cite both SDKs (C7).

2. **C-3's group filter has no killer.**
   - **Evidence.**
     - §3.4 kills "every group" with `purgeKeepsUserLaneAndWaiterInterests`. That test purges `.scope([zz-u, zz-p])` (Tests/…/EnginePurgeWithdrawalTests.swift:232), and C-3 runs only under `.all`. The suite's helper also purges `.scope` (`:56`).
     - I found no test that purges `.all` while a user-lane group or an ensure group is pending:
       - the sync `.all` sites are `EngineCommandTests.swift:153` and `:215`, with no group, and `EngineIdleTests.swift:156`, after shutdown;
       - the facade `.all` purges (`FacadeRaceTests`, `FacadeReopenTests`, `EventContinuityModelTests`) have only default-lane prefetches and no ensure in flight, and `FacadeLifecycleTests` calls both after `shutdown()`;
       - the model test purges only `.evictable` or `.scope` (`EngineModelTests.swift:117`), so C-3 never runs on its random states either.
     - Also, `…EarlierRelane(claimed: true)` cannot kill C-2 (c) forced true, because (b) is false there (`[.prefetch, .bulk]`, `:100`). Only `purgeRemovesInAscendingTokenOrder` reaches it.
   - **Correction.**
     - Add a new `.all` test, in both orders, with three groups pending on distinct contents: a `.prefetch` group, a `.userInitiated` prefetch group and an `ensureAvailable` group.
     - Right after the purge, it asserts by value that the `.prefetch` group keeps no member, that the other two keep their members and interests, and that the ensure call gets its answer. The filter's kind and lane mutants then fail by value, not by a hang.
     - Add a new model-test variant that purges `.all`, so that C-3 runs with the id-level F-1 checked afterwards. Leave the existing model test unchanged (G3).

3. **Two more in-letter shapes have no gated case, and route C's own conditions send every job in them to today's path (C2).**
   - **(a) Mixed lanes.**
     - **The shape.** Two prefetch groups over the same 10,000 ids, each id with its own content. The first is registered at `.prefetch` and the second at `.bulk`. The public API takes any lane (`Sources/ZTronAssetKit/Facade/AssetClient.swift:205`).
     - **Why route C misses it.** Removed in token order, every job has `before == .prefetch` and `last == .bulk`, so (b) fails for every job. Each job pays two withdrawals, a re-queue with two `Job` copies (`relane` → `enqueue`, `EngineJobs.swift:311-314`, `:563-578`) and today's retirement.
     - **Estimate after route C: about 24-33 ms.** The basis is §1's parts: S at 7 ms; W without the drop at about 0.6-0.7 µs per interest; the re-queue at 0.3-0.4 µs per job; R after A2.1 to A2.3 and C-1 at about 2-8 ms (§2's "without A2.4" column, less S, W and A2.5's insert).
   - **(b) Pending claims.**
     - **The shape.** Two prefetch groups over the same 10,000 ids, the second registered just before the purge.
     - **Why route C misses it.** `recordGroup` claims every member's content in the registering turn (`EngineCommands.swift:219-241`), and a claim ends only when the group's join reaches its member (`endClaim`, `:484-485`). The join suspends at `ensureStarted`, `planningView` and a `Task.yield` between batches (`:264`, `:278`, `:295`), so the purge can run first. Every job then fails (c), and today's path keeps it for the claim (`settleRemoval`'s `claimHeld` arm, `EngineJobs.swift:427-431`).
     - **Estimate after route C: about 16-18 ms.** The basis: S at 7 ms; W without the drop at 6-7 ms; the claim arm at 0.3-0.35 µs per job.
   - **Correction: either (i) or (ii).**
     - **(i) Narrow (b) and add C-2′.**
       - Apply (b) only to a `.downloading` job, the one state where the re-lane before the last removal reaches the transport (`setPriority`, `pauseIfRefused`).
       - For a `.queued` job, that re-lane only re-queues an entry that the same step retires: a ticket and a place. That is non-blocking, and removable under S3-R16 items 2 and 3; record it. For a failed or blocked job at a non-user lane, `relane` does nothing.
       - Add C-2′ for a claim-held job whose (b) holds. After C-2's step 1 (the drops, the heals, the run's `held`), it moves the interest storages out whole to the freeing list, resets the counts, sets `heldLane = last` and writes `claimHeld`. The end state is the same as today's.
     - **(ii)** Gate both shapes as in-letter, with B′ as their route.

     Either way, both shapes become gated cases with step-0 figures.

4. **C-2 adds a second removal path, which ARCHITECTURE §7.1 does not allow.**
   - **Evidence.** §7.1 is normative (`docs/ARCHITECTURE.md:200`): removal goes through one synchronous funnel, `retire`, for a job with no interest (`:226`). C-2 removes a job that still holds its interests with `remove(at:)`, and replays the effects of `retire` and `removeJob` itself.
   - **Correction.** Make C-2 a variant of the funnel, for example `retire(at:whole:)` calling `removeJob(at:)`. Otherwise, propose the §7.1 amendment in the draft (S3-R6).

## Should fix

1. **C-2's read is not in place, as cited.**
   - §3.1 rests on s3f:7496-7499, which cite `Values.subscript(position:)`'s getter (SDK :8050-8053). The getter returns a copy; the code's own finding is that a getter read copies the job (`EngineState.swift:1105-1108`, e2-A1.7).
   - Name the `_modify` accessor instead: a `mutating` `Job` method on `values[i]` (SDK :8054-8060).
   - Read through the getter, C-2 costs another 1-1.5 ms at 10,000 jobs, at the report's own 100-150 ns per copy (estimate). C-1's `jobs[t]?.epoch` also copies the job, for each `.retry` whose job is still in the table.
2. **The per-job estimate is low at its upper end.** §3.2 gives 0.28-0.56 µs per retired job at k = 1. Rebuilt from §1's parts:
   - C-2's read is today's per-job access (S less the sort: 0.35-0.5 µs) less its allocation and free (0.08-0.16), so 0.19-0.42 µs;
   - `remove(at:)`'s shift hashes every key from the deleted bucket to the next hole (`_HashTable.delete`, SDK :12458-12480): 0.06-0.22 µs as the table empties (a linear-probing estimate);
   - `removeJob`'s guarded effects and the append: 0.03-0.08 µs.

   That is 0.28-0.72 µs (estimate). It puts `oneGroup` at 5.0-11.3 ms sorted, and `fourGroups` at 5.4-12. §0's 5-12 ms holds; §3.2's upper bounds of 9.5 and 10.4 ms do not.
3. **`userWaiters` and `ensures` "fall to 3.5-6 ms" only if C-2's read also skips a job with nothing to withdraw.**
   - §3.1 says every other job takes today's path. That adds C-2's read to today's access: +0.5-2 ms (estimate: 50-200 ns a job), about 7.5-9 ms, at the 8.5 ms edge. The report should say which it means.
   - §3.2 calls the joins cases and `purgeWhileOwedTurns` untouched, while §3.3 says their later drops become no-ops. Their figures can move.
4. **C-1's epoch arm has no killer.**
   - §3.4's `!=` → `==` mutant is killed. The mutant that tests only `jobs[t] == nil`, though, differs only on a stale `.retry` of a kept job (§3.1), and no listed test builds one. The removal sites I found are `EngineJobs.swift:362`, `EngineReadmission.swift:166` and `EngineJobs.swift:517-520`.
   - Either build that state and kill the mutant, or drop the arm and class it Equivalent. §3.1's "record it" should class the difference as heap and alarm only, not an answer (`EngineTimers.swift:110-112`).
5. **C-5's rebuild.**
   - **Rebuild only when the retired share is large;** otherwise remove the retired jobs by key in a second pass. One retirement among 10,000 kept jobs would rehash every kept job (1-3 ms, estimate). `userWaiters` plus one prefetch-only job would then reach about 4.5-9 ms if should-fix 3's skip holds, and 8.5-12 ms if it does not.
   - **Say whether the rebuild moves or copies the kept values.** A copy shares each kept job's collections with the old storage until that storage is freed. Left to a freeing slice, the next change to a kept job copies them (1-4 ms for a job of 10,000 interests, estimate). So the old storage is dropped in the purge's turn.
   - **No second reference to the table may live across the visits.** `_modify`'s `ensureUniqueNative` would copy the whole table (SDK :9081-9090). The copy keeps the age and the buckets (:15801-15805), so the indices survive, but it costs 1-3 ms (estimate: 10,000 `Job` copies at 100-150 ns, plus the keys).
   - **List the rebuild filter's mutants** in §3.4.
6. **The freeing slices.**
   - Their spawn needs a REENTRANCY row (C3).
   - Shutdown must drain the list in its own slices, not drop it in one turn: 5-8 ms at k = 4, by the report's own figure.
7. **The stage trigger** ("the next stage runs only if some case is above 8.5") should name the cases each stage can move. As written, `keptUnderThreeGroups` and `fourGroupJoins` are above 8.5 ms by the report's own estimates (34-39 and 15-22 ms), so they start stages B and C, which do not reach them.
8. **C-2's window.**
   - Between C-2's read and `remove(at:)`, `abandon` and `recordBreaker` run while the job is still in the table and holds its interests; today it holds none at that point.
   - §3.3 needs the argument that no callee reads those interests, and that nothing inserts or removes a job in that window, so the index stays valid.
   - The callees to cite: `recordBreaker` → `breakerChanged` → `unblockOrigin` and `reconsiderPendingRun` (`EngineFailures.swift:1026-1094`; `EngineReadmission.swift:197-217`); `startRun` only spawns (`EngineRuns.swift:71-100`).
9. **C-3's place in the turn.**
   - §3.1 places it only before the job walk. Say whether it also runs before `withdrawPurgedJoins` (`EngineCommands.swift:1016`; §1 cites `:1017`).
   - Run first, it also turns `fourGroupJoins`' 40,000 join drops into count-0 no-ops. That moves the case's 15-22 ms by an unknown 3-6 ms (estimate, from §3.2's `fourGroups` saving), so its step-0 figure is taken with the placement fixed.
   - Either way, 12.5.15's extended audit lists C-3's mid-turn state: every such group's pending set is emptied before the walk.

## What the ruling must add

1. **Three more gated in-letter cases** (12.1):
   - must-fix 3's mixed-lane shape;
   - must-fix 3's pending-claims shape;
   - 40,000 one-member prefetch groups, four on each id.

   The third loads C-3's pass and G. It comes to about 8-16 ms after route C. The estimate's basis is §3.2's `oneMemberGroups` (5.7-10.8 ms, or up to 12 with should-fix 2), plus C-3's pass over 30,000 more groups at §3.2's 0.065-0.125 µs each. The 30,000 more count-0 drops come on top.
2. **C-5's precondition and step order** (must-fix 1) are binding, with both SDKs cited.
3. **The two shapes' route** (must-fix 3): either (b) narrowed to `.downloading` jobs, with C-2′, and the skipped re-queue classed under S3-R16 items 2 and 3; or B′ as their route.
4. **C-2 stays inside `retire`'s funnel,** or the ruling takes the §7.1 amendment, proposed in the draft under S3-R6 (must-fix 4).
5. **The kill table is corrected:** must-fix 2's new `.all` test and model-test variant, and should-fix items 4 and 5's mutants.
6. **Before `keptUnderThreeGroups` is routed to B′,** the ruling asks one question: may the `.queued` arm's re-queue of a kept user job go?
   - Today `settleRemoval` re-lanes every kept job (`EngineJobs.swift:435`). `relane`'s `isUser` arm then moves each queued user job to the back, in sorted key order (`:311-314`).
   - The `.failed` arm's re-admission is a state change, so it stays.
   - If the re-queue is order-only machinery that S3-R16 item 3 lets the purge drop, a one-turn route may exist: rebuild each kept job's interests from the ones it keeps.
   - Estimate (unmeasured): about 6.5-12.5 ms. The basis is C-2's read (0.19-0.42 µs) and a one-interest rebuild (0.24-0.43 µs) per job, plus §3.2's fixed costs (2.2-4.1 ms).
7. **C-1's stale-retry difference** is classed and recorded, or the arm is dropped (should-fix 4).
