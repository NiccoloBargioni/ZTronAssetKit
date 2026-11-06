# Review of e2-purge.md (correct #2, with reqs #4)

I did not write e2, so this review is independent (P4). It is read-only, against `.worktrees/s3f` on branch wp/s3f at HEAD d5b2ab9 (confirmed with `git -C … rev-parse`; the worktree is clean).
- Nothing was built, tested, run or measured.
- Engine paths are under `Sources/ZTronAssetSync/Engine/`. `e2:` cites `e2-purge.md`, and `R:` cites `s3-rulings-s3f.md`.
- A figure from a probe log or the draft names its source. Every other figure is an estimate, with its basis.
- Process note: some of my read-only commands used `cd` into the worktree, against the task's rule. They only read files; nothing was written there.

## Verdict: CORRECTED

A1 then A2 is the right default route, with corrections: A1 needs M6–M8 before it lands, A2 needs M9, and the list of gated shapes needs M10.

Route B as written cannot be authorised: it gives different answers (M1–M3), its bound does not bound the turn (M4, M5), and its shutdown and timing claims are wrong (M11, M12). A re-specified B needs its own review.

What holds (checked against the sources):
- correct #2 and reqs #4 are real, and every measured figure in e2 §0 matches its log in `s3f-probes-c21/`: purgeq 54.47/56.29/54.78, purgeq2 57.43/55.96/58.37, the shared job 12.20/12.34/12.25 and 12.03/12.46/13.62, parts 54.83/53.86/67.57 and 13.11/13.16/12.36, purgej 13.08/13.16/13.04 (9,216 bucket joins) and 11.84/11.52/12.55 (9,489 queue joins), loads 4.85–7.65.
- `purgeWhileOwedTurns` [10.22, 11.55, 10.04] and its earlier runs are as the draft records them (`docs/adr-drafts/s3f.md:6668-6690`).
- The documents are read correctly (`SPEC.md:250`, `ARCHITECTURE.md:300`, `:443`, `DECISIONS.md:392`): withdrawing in the first turn is not a MUST, and withdrawing waiting joins, bucket joins and owed items before any drain turn is binding (RR-5).
- An `.ensure` interest is always `.userInitiated` (`EngineCommands.swift:737`, `EngineDispatch.swift:260`). So the purge never drops an ensure member, and A1.3's drop-order argument holds for the drops themselves.
- The SDK citations hold: the macOS `_modify` accessors (`Swift.swiftinterface:7931-7941`, `:8050-8058`), and `Set.remove` and `Dictionary.removeValue` hashing on an empty collection (`:22111-22121`, `:9125-9137`).
- `spawn` also refuses in `.degraded` (`EngineLifecycle.swift:52-56`), but only `runStart` sets that state (`:228`, `:260`). So e2:319's argument holds.
- §1.3's rows 4–8, 10 and 13 are real breaks of naive slicing.

## Must fix

1. **B, rows 1 and 3: a command between slices joins the old job and inherits its attempt count (S3-R16 1(a)).**
   - Row 1's token watermark keeps the new interest, but on the job no slice has visited yet.
     - `addInterest` joins an existing job (`EngineJobs.swift:151-154`, `:175-183`). It creates one with `attempts` 0 only when none exists (`:155-173`).
     - Row 3 (a waiter or an ensure) takes the same path, and e2 classes it as "order and place" (e2:81).
   - `Job.attempts` belongs to the job and is never reset.
     - It starts at 0 (`EngineState.swift:816`); its only write is `EngineFailures.swift:287`.
     - It caps every interest by that interest's lane (`:295-303`, `reachesCap` at `:643-645`), and it sets the backoff (`:351`, `:365`).
   - A state that shows it: a prefetch job failed once (attempts 1, a `.retry` entry), the `.userInitiated` cap is 2, and the source answers [fail, stage].
     - Today the walk retires the job, and the ensure's fresh job fails, then stages: success.
     - Under B the ensure joins the old job. Its first failure makes attempts 2, so it is answered `.failed` at the cap.
     - T-B1 and T-B4 (e2:289, :292) start from attempts 0 and cannot see this.
   - Correction (my proposal; not built, not reviewed): **visit on touch.**
     - Touching means adding an interest *or a claim* on a marked job's content, starting it, answering it, or moving or re-routing its pairs. Each such path first runs that job's own withdrawal and settle, as today's walk would have.
     - Claims are included because a new group's claim exists from `registerGroup` on, before its join, and would keep the old job alive (`EngineJobs.swift:394-401`).
     - Rows 1–3 then equal today's instead of needing a class, and the watermark is no longer needed.

2. **B, row 2: a late join batch breaks F-1 and B's own clause (1(b), 1(e)).**
   - e2 classes row 2 as "the same outcome as if that join had come before the purge" (e2:80).
     - That outcome includes dropping the member (`EngineCommands.swift:1025`).
     - B's slices drop no members (e2:255); only phase 1 does (e2:241-243).
   - How a late batch lands:
     - `joinGroup` resumes after its yield with the group's old token, at or below the watermark, and with its pre-purge view (`EngineCommands.swift:295-308`).
     - The purge does not change `copySerial`; only `adoptApplied` bumps it (`EngineJobs.swift:1184`).
     - `joinMember` then sets `pending[id]` and adds the interest (`EngineCommands.swift:340-342`).
   - On a marked job, the slice withdraws that interest and leaves the member pending without `interests[token]`. The F-1 clause rejects that state (`:1856-1862`).
   - If the batch creates a new job instead, that unmarked job holds a pair B calls withdrawable. So B's clause "no withdrawable pair sits on an unmarked job" (e2:274) is false, and T-B8 fails.
   - The kill e2 names for the slice's "no job or no mark" skip (e2:314) does not kill it (my reading; not run).
     - It re-creates the job from new registrations, whose tokens are above the watermark.
     - So the skip's drop-mutant withdraws nothing there and survives.
   - Correction:
     - with visit on touch, the late batch lands after the visit and stays, which is today's outcome (e2:80);
     - slices that withdraw also drop the members, as today's walk does (`:1022-1031`);
     - the "unmarked" clause goes.

3. **B: the take-off filter misses RR-21's sites 1 and 3 (1(a)).**
   - The filter sits at `EngineFollow.swift:594`, `:1248` and `EngineMoves.swift:339` (e2:266, row 6).
   - Two other paths also move a marked job's pairs, onto unmarked jobs or into owed batches that phase 1 never saw:
     - the commit's re-routes (`EngineDispatch.swift:1151`, `:1181-1183`, and the deferred ones at `:1188-1190`);
     - `supersede`'s re-routes (`:1322-1345`, with `deferReroutes` at `:1339`, called from `EngineFollow.swift:1245`).
   - Such a pair is never withdrawn, and its purged id is fetched again: e2's own RR-5 class.
   - Correction: visit on touch covers every path that moves pairs. Without it, the filter also goes into `reroute` and every `RerouteItem` builder (`EngineDispatch.swift:1151`, `:1336`; `EngineState.swift:1060`), each with its kill.

4. **B, C2: the slice bound counts only the pairs it withdraws.**
   - A slice runs "until at least 512 pairs are withdrawn, or the snapshot ends", and "never splits a job" (e2:253).
   - Two shapes escape that bound:
     - 10,000 jobs held only by user waiters or ensures, or a `.scope` that matches few ids, withdraw nothing, so the first slice visits every job;
     - one job of 10,000 ids held by four groups (k = 4, in-letter by R:886-893) puts 40,000 pairs in one slice.
   - Estimate for that slice after A1 (not measured): e2's after-A1 figure for the shared job at k = 1 is 2–4 ms (e2:196). The per-pair parts run four times and the filter once (×2.5 to ×4), so about 5–16 ms.
   - Correction: bound the jobs visited and the pairs visited, split a job by interest, and gate both shapes.

5. **B: phase 1 at k = 4 is underestimated, so §6 item 6 has no basis.**
   - Phase 1 checks every pending member (e2:241-243): 40,000 at k = 4 over 10,000 jobs.
   - Each check costs about 140–290 ns at e2's own unit costs:
     - a job lookup (`TransferID` hash), 60–90 ns;
     - an interest and membership test plus an A3 drop (2–3 `AssetID` hashes and a group access), about 40–100 ns;
     - the copy lookup under `.scope`, 30–60 ns.
   - That totals 5.6–11.6 ms bottom-up, or 7–19 ms at e2's own measured-over-bottom-up ratios (×1.3 in §2.1, ×1.6 in §2.2). This is an estimate; e2 gives 2–8 ms (e2:243, :322).
   - The `.all` figure of 0.3–2 ms (e2:322) assumes the F-1 strengthening, which e2 marks UNCONFIRMED (e2:244).
   - So phase 1 alone may miss at k = 4, and "Going from A1 straight to B is then cheaper" (e2:376) is unsupported. A miss with no route is blocking (R:1022).

6. **A1.4: the order of removals within one job is observable through `heldLane`.**
   - How `heldLane` is set and read:
     - when a claim keeps a job that lost its last interest, `settleRemoval` sets `heldLane` to `last`, the lane before the last removal (`EngineJobs.swift:390-397`);
     - `Job.lane` falls back to it (`EngineState.swift:891`);
     - `claimRetries` takes its cap from it (`EngineFailures.swift:322-327`).
   - The purge leaves claims alone (`EngineCommands.swift:960-1120` touches none).
   - Today's walk removes in ascending token order (`:1015`), as `takeOff` does on purpose (`EngineFollow.swift:585-588`, `EngineState.swift:1068-1074`). S3-R26 answer 7 accepted that sort (R:704).
   - Example: a job holds t1 from a `.bulk` group and t2 from a `.prefetch` group, both withdrawn, while a third group holds a claim on it.
     - In ascending order `heldLane` ends at `.prefetch`; removing t2 first leaves `.bulk`.
     - The job's lane, queue place and retry cap then differ.
   - So "A job's lane only falls, and its last `relane` sets its place" (e2:212) and ruling item 6 (e2:385) are false as written.
   - Correction: the `Job` method removes whole interests in ascending token order, and returns the lanes before the first and before the last removal, as `takeOff` does.

7. **A1 is not branch-free.**
   - The `.all` fast path (e2:174) is a new branch; e2 lists its kill, T-A-SCOPE (e2:223).
   - S3-R27 item 2 makes the jobs' side branch-free (R:827), item 11.3 keeps that (R:1028), and e2 says both still bind A1 (e2:340).
   - Correction: move the fast path to A2, which needs item 12 anyway, or have item 12 authorise it as a branch. T-A-SCOPE then kills always-taken, and never-taken is Equivalent because it changes only cost (S3-R19 item 2).

8. **A1.2 and A1.4, as worded, trap at run time (exclusivity).**
   - `isPurged` reads `self.state.applied` (`EngineCommands.swift:993-994`).
   - `withdrawPurgedJoin` writes `joinsAfterFollow`, `groups` (through `dropGroupMember`) and `heals` (`:1102-1110`).
   - Inside A1.2's single access to `joinsBehindVerdicts[key]` (e2:166), or A1.4's `Job` mutating method on `jobs[t]` (e2:171), each of those is an overlapping access to `state`.
   - Today's code copies out and writes back to avoid this (`:1086-1088`; `withdrawPurgedJoin`'s doc at `:1094-1097`). So does the pump (`EngineDispatch.swift:315`).
   - Correction: capture `applied` and the request in locals, mark and collect inside the access, and make the other writes after it, in the same order (S3-R27 item 1, R:777-781).

9. **A2.3's freeing slice is not Equivalent.**
   - e2 lists its `if` as "Equivalent (memory timing only)" (e2:229).
   - S3-R27 item 6 pins `settle`'s identical slice with `shutdownSlices`, and its drop-mutant must fail 2/2 (R:962-967). S3-R5 asks for a deterministic test wherever a bound can be asserted structurally (R:10).
   - Correction: pin it (recorded slices, a drop-mutant that fails 2/2), or free everything in one later turn, branch-free, with its own figure and a REENTRANCY row. That turn is about 2.7–4.7 ms at (i), from e2's own `Job` deinit share (5–8% of 54.5–58.4 ms, e2:112; estimate).

10. **"Gated or recorded" is not open for k = 4 and the retry shape, and two in-letter shapes are missing.**
    - e2 asks the ruling to choose (e2:383), yet says both are in-letter (e2:154, :354).
    - Item 4 sizes cycle 22 at up to 4 interests per id, and records only shapes above 4 (R:886-893). So both are gated, and a miss is blocking.
    - Missing from e2's list (estimates):
      - **the shared job at k = 4:** about 43–48 ms today (§2.2's per-pair parts ×4, the filter once);
      - **10,000 jobs held only by user waiters or ensures:** it withdraws nothing, yet pays per job a lookup, a `Job` copy, the filter (its copy lookups and its `Set`), the interests sort and the frees, about 0.4–0.65 µs. With the key sort (e2's 4–7% share, 2.2–4.1 ms) and ×1.3, that is about 8–14 ms today.
    - The heap scan is about n²/2 = 5×10^7 comparisons, not 10^8 (e2:152), because each removal scans only what is left (`DeadlineHeap.swift:74-76`). At e2's implied cost per comparison that is 0.1–0.5 s (estimate), still far above the bar.

11. **B's shutdown claim is false in both directions (e2:267-268).**
    - e2 says: "The store's purge then never runs. Today that happens too when a shutdown overtakes the owned task's first hop."
    - Today a cancelled purge task still purges:
      - nothing checks the lifecycle before `store.purge` (`EngineCommands.swift:1123`); `isRunning` is read only after it (`:1124`);
      - the store checks only its own phase (`Sources/ZTronAssetStorage/Cleanup/StorePurge.swift:15-18`; `Store/AssetStore+Lifecycle.swift:35`);
      - shutdown joins every owned task before it closes the store (`EngineLifecycle.swift:502`, `:515`).
    - B's own new REENTRANCY row (e2:258) also reaches the store before it re-checks.
    - The caller is answered `.shutDown` at once either way (`EngineShutdown.swift:93`, `:241-242`). Only the durable state would differ, if a fixer added a check.
    - Correction:
      - strike the sentence;
      - T-B6 asserts by value that the records are purged, as today;
      - the wait's row reads "nothing: as today's first hop; `:1124` answers";
      - a check that skips the store's purge is a named difference for the ruling.

12. **Rows 2, 3 and 9 are not classes "under S3-R26 answer 6's condition".**
    - Answer 6 holds a timing class "only while the event lands between the two engines' answers". With the event "before both answers", a different answer is blocking (R:674; S3-R24 item 5).
    - Both engines answer the purge only after the store's purge, which B starts after its last slice. So an event between slices lands before both answers.
    - e2 restates the condition as "the command lands between the purge's call and its answer" (e2:96, :389). That is a new, wider window (a linearization argument) that only the ruling can adopt.

## Should fix

1. **The first await (e2:17)** is `ensureStarted()` (`EngineCommands.swift:965`). The synchronous stretch, `:968-976`, comes after it.
2. **The engine's `purgeEpoch` (e2:52)** is read by nothing.
   - `EngineRuns.swift:85` copies it into `RunState` (`EngineState.swift:1395`), and `:287` passes the store view's epoch.
   - The race guard is the store's own bump (`StorePurge.swift:23`), which B moves to after the last slice. RE-S24's proposed text should say so.
3. **Item 2's part (2) is conditional (R:818).** e2 makes it unconditional in A1 (e2:164, :384) and also says "(1) and (2) stand" (e2:380). The ruling must pick one.
4. **Dropping `:1070`'s sort reverses two rulings:** S3-R26 answer 7 (R:705) and R15 (`integrate-rr21.md:239-241`). Name both.
5. **`notifyObservers`.**
   - A1.4's single settle also cuts `notifyObservers` calls inside the turn (`EngineJobs.swift:406`; e2:211), so it needs item 3's mid-turn audit (R:838), as A2.6 does.
   - A2.6 saves nothing in the benches, because `notifyObservers` returns early with no observers (`EngineCommands.swift:1709-1736`).
6. **A2.2 leaves the geometric compaction passes** (`EngineJobs.swift:566-583`): about 2 × 10,000 `isValid` calls, each a lookup and a `Job` copy, so about 3–5 ms at (i) (estimate). One compaction after the walk is cheaper and branch-free.
7. **A2.4's walk.**
   - `Dictionary` removal invalidates indices, so the walk needs a second pass for the retired keys, and each still hashes. "Drops the per-job hash" (e2:183) holds only for the jobs that are kept.
   - Cite the iOS SDK too (C7); I did not check it.
8. **A2's figure for (i)** (5–12 ms, e2:193) leaves out the residual.
   - If the 15–25% residual stays (8–15 ms of 54.5–58.4), (i) is about 10–18 ms (estimate).
   - e2 says only a measurement decides (e2:205), so do not plan B's need from 5–12.
9. **Not measured on d5b2ab9:** (ii), (i) under `.scope`, k = 4, the shared job at k = 4, the retry shape and the user-waiter shape. Step 0 measures them before the red commits (G2).
10. **Two rows missing under B.**
    - **A commit between slices whose content the later store purge selects.** Today the window is one hop to the selection snapshot (`StorePurge.swift:25`); under B it is about 20 turns, so `assetsRemoved` and `bytesFreed` can grow.
    - **A caller's cancel between slices** (`withdrawEntry`, `EngineCommands.swift:1566-1576`). Today the store's purge still runs, as in M11; B must say the same, or name the difference.
    - So "The purge's answer has the same value" (e2:280) holds only when neither event lands.
11. **Row 13 needs a mark per walk.** With one serial per job (e2:248), a second purge's marking pass overwrites the first walk's marks, and the first walk skips the jobs both walks share.
12. **The gate's cost.** Its test, "every interest is withdrawable" (e2:265), costs O(pairs) on each evaluation: up to 40,000 copy lookups at the shared k = 4 job. Count it in the turn that evaluates it.
13. **An extra heal.** A marked job that fails between slices delivers its withdrawable `.system` interest, and `deliver` keeps a heal still due later (`EngineJobs.swift:641-650`). Today's walk forgets it (`EngineCommands.swift:1027`). Visit on touch covers this.
14. **Minor.**
    - `Set.contains` also has a count-0 path (`Swift.swiftinterface:16490-16494`), so "only `lookup`" (e2:107) is too narrow.
    - `inFlight` includes verifying and committing jobs (`EngineJobs.swift:454-456`). Those are removed only when that work ends, so "abandoned in this turn" (e2:245) is not exact for them.

## What the ruling must add

1. **Exclusivity**, for every step that works inside one access (A1.2's bucket, A1.4's `Job` method, A2.4's walk). Use locals for `applied` and the request, mark and collect inside the access, and make the other writes after it, in the same order (R:777-781).
2. **A1.4's order.** Remove in ascending token order, and settle with the lanes before the first and before the last removal.
   - Its test: a claim-held job with a `.bulk` and a `.prefetch` interest ends with `heldLane == .prefetch`.
   - The reversed-order mutant fails 2/2.
3. **The gated cases**, at 10,000, on the heartbeat, best of 3, with loads; each case that misses on d5b2ab9 is committed red. A miss with no route is blocking (R:1022). The cases:
   - (i), (ii), and (i) under `.scope`;
   - the shared job at k = 1 and at k = 4;
   - the bucket and queue joins, and `purgeWhileOwedTurns`;
   - k = 4 over 10,000 jobs;
   - 10,000 retry-waiting jobs;
   - 10,000 jobs held only by user waiters or ensures.
4. **A2's corrections.**
   - Pin the freeing slice (recorded slices, drop-mutant 2/2), or free unsliced in one later turn with its figure and REENTRANCY row.
   - Compact once, after the walk.
   - Drop A2.6, or keep it only after the audit.
   - Do A2.4 in two passes, with the iOS SDK cited.
5. **B is not authorised in cycle 22 as written.** A re-specified B lands only after its own review, and it needs:
   - visit on touch, claims included, with its cost counted in the touching turn;
   - member drops in the slices;
   - a bound on the jobs and pairs visited, splitting a job by interest;
   - a mark per walk, and no "unmarked" clause;
   - its shutdown and cancel behaviour, stated against today's.
6. **The reversals.** Name them (R15, and S3-R26 answer 7's purge-arm sort), and say whether item 2's part (2) stays conditional.
7. **The timing condition.** Either adopt "between the purge's call and its answer" as a new condition, or rule rows 2, 3 and 9 blocking under answer 6 as written. Class the commit row and the cancel row (should fix 10) the same way.
8. **The `.all` fast path** lands in A2 under item 12, or item 12 authorises it as a branch, killed by T-A-SCOPE, with its never-taken mutant Equivalent.
9. **Figures.** Every estimate stays labelled. The step-0 figures come before the red commits, and they decide whether A2 is needed (G2).
