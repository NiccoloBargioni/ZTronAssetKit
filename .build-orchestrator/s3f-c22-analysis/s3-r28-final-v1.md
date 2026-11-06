## Orchestrator ruling added 2026-11-06 (cycle 22's verification; written before the cycle-23 fixer starts)

**S3-R28.** Cycle 22 implemented S3-R27 in part (`d5b2ab9..9aa337c`, 44 commits; the last production commit is `2abddd1`, e2-A2.5): steps 0 to 3, step 4 up to e2-A2.5, e2's kills, and step 8's gates and re-measures (`s3f.md:6910-6947`). Its verifiers left 14 blocking findings, 7 in each lens, and S3-R27's steps 5 to 8 are unfinished. This ruling routes them, except correct #1 and #2: their route is item 1b, which the orchestrator appends later (item 1). Cycle 23 starts as run 10, and its fixer may take several runs (item 6).

**S3-R28 is cycle 23's ruling.** S3-R16 to S3-R27 apply wherever S3-R28 does not change them. Where S3-R28 differs from an earlier ruling, from a specification or from an analysis, S3-R28 decides. The cycle-23 verifiers judge by S3-R16 to S3-R28. Item 1b and item 3b, once appended (items 1 and 3), bind the cycle-23 verifiers for the work of every step that started after they were appended. The draft's status list records when each was taken (item 6).

Where to find things:
- **The cycle-22 verifiers' findings** are in `.build-orchestrator/s3f-c22-issues.json`, on `9aa337c`. They are cited as "correct #n" (`lenses.correct.issues[n-1]`) and "reqs #n" (`lenses.reqs.issues[n-1]`).
  - Fix them in S3-R1's order: blocking first.
  - A verifier finding is **named** by this ruling when it reports the same case, shape, mutant or `path:line` (at `9aa337c`) as an item here.
    - The fixer records the mapping ("correct #n → item k") in the draft's cycle-23 status list (item 7).
    - A named finding is closed by its item's route and decision rule, even where the finding proposes another fix.
  - A blocking finding that this ruling does not name follows S3-R16 and the general rulings.
- **The read-only analyses made for this ruling**, in `.build-orchestrator/s3f-c22-analysis/`:
  - `f1-enospc-windows.md`, with its review `f1-enospc-windows-review.md` (item 1). The review finds f1 UNSOUND as a whole, and its replay half sound. That second finding does not hold as stated (f1b review must-fix 2);
  - `f1b-join-rule.md`, with its review `f1b-join-rule-review.md` (item 1). The review finds f1b UNSOUND;
  - `f2-flake.md`, with `f2-flake-review.md` (item 2; CORRECTED);
  - `f3-purge-route.md`, with `f3-purge-route-review.md` (item 3; CORRECTED).

  How to read them (S3-R27's header rules, applied to f1, f1b, f2 and f3):
  - Each review corrects its report. Where a review and its report differ, the review wins. Where either differs from this ruling, the ruling wins.
  - **What in a review binds.** Its must-fix items bind, as this ruling corrects them. Its should-fix items bind only where this ruling names them, as this ruling corrects them:
    - f1 review: "The probe helpers" and "The REENTRANCY note" (its should-fix items are not numbered). Both concern item 1's route, so they bind only once item 1b takes them up;
    - f2 review: should-fix 1, 2, 3, 4, 6, 8 and 9;
    - f3 review: should-fix 1, 3, 4, 5, 6, 8 and 9.

    A review's "What the ruling must add", a report's recommendation, every other should-fix item and every "optional" bind only as this ruling carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.
  - Below, "must add" n is a review's "What the ruling must add" n, and "must say" n is a report's "What the ruling must say" n.
  - Their line numbers are at `9aa337c`; re-cite them after a change. Their figures not marked "measured" are estimates, from code reading and from the draft's and the verifiers' measurements. A measurement decides.
- **Names** (S3-R27 12's names rule still applies). R1 already means S3-R11's, `integrate-rr21.md`'s and S3-R27 item 3's, and B1 and B2 are S3-R27 item 3's too, which step 4 runs in this cycle. So, in this ruling and in the draft's records:
  - f1's branches are f1-B1 to f1-B13, and f2's R1 to R3 (its probe, its fix and its check) are f2-R1 to f2-R3;
  - f1's clauses keep their names, clause (a) to clause (g), and f3's conditions on C-2 are C-2 (a) to C-2 (d);
  - f1b's labels carry its name: its kills are f1b-K1 to f1b-K27 (`integrate-c21.md` has clauses K1 to K4, rulings :423), its R1 is f1b-R1, and its clauses are f1b's, for example f1b's (b), which is not f1's clause (b);
  - T-F1a to T-F10, T-F2c, T-F8c, T-B11, the W- shapes, AV-away, AV-off, C-1 to C-5 and stages A to C keep their names.
- **Cycle 22's scratch evidence:** the verifiers' probes, logs and tools in `.build-orchestrator/s3f-probes-c22/` (`VerifyC22CorrectProbes.swift`, `reqs/tools/`), and the fixer's `.worktrees/s3f/.build-s3f/c22/` (the scratch copy `snap0`, `tools/`). Do not delete them. Cycle 23's scratch files go under `.build-s3f/c23/`. Its rewritten mutants go in its own copies under `.build-s3f/c23/tools/`, and `.build-s3f/c22/` stays as cycle 22 left it, as 12.5.6 left `.build-s3f/c21/` (rulings :1243).

**How a C2 figure is read in cycle 23.** S3-R27's rule ("How a C2 figure is read in cycle 22") applies to every C2 case that cycle 23 measures. The bar is the owner's (S3-R27 12.1): `c2Budget`, 10 ms, over 10,000 ids however grouped, with at most 4 interests on one id and one subscriber, which may be stalled. 8.5 ms decides only the routes that name it, and the margin list (S3-R27 item 9; rulings :764).

1. *Correct #1 and #2: the ENOSPC windows.* Blocking (S3-R16 1(a)). Both are measured 2/2, red swept first (`s3f-probes-c22/correct-probeC22TransferSpaceDrainJoin.summary.log`, `correct-probeC22ApplyInRead.summary.log`).
   - **Correct #1** (PROBE-C22C-TS-DRAIN-JOIN, seed 2_029_101). A user request made before T's transfer ENOSPC is replayed inside the free-space read and meets no stamp (`EngineJobs.swift:293-294`), so T20 re-queues T (`:360-364`). Visit-first answers A, X and V `insufficientSpace` and starts T once. Swept first, all three get `ok(100000 B)` and T starts twice. With V made inside the read (seed 2_029_201), both orders give `ok` and 2 starts.
   - **Correct #2** (PROBE-C22C-APPLY-IN-READ, seed 2_029_301). v4, applied inside a publication's free-space read, makes the visit branch (`:290-291`) date v3's move after the end, so T20 re-queues T. Visit-first answers A and X `insufficientSpace` with one start; swept first, `ok` with two.
   - **The causes are two** (f1 §1, as review must-fix 2 corrects it): a re-lane dated by the wrong clock, and a re-queue that visit-first makes and the swept-first engine never makes before the verdict.
   - **Nothing in item 1 is ruled for the code now.** The fixer does not change `metInItsAttempt` (`EngineJobs.swift:289-297`), `Job.transferSpaceEnd` (`EngineState.swift:867`), `AttemptEnd.stamped` (`EngineFollow.swift:2017-2022`), `relane`'s dating (`EngineJobs.swift:327`), or the dating of any join or replay. f1's clause (b), which counts a join made while `bringingInbound` as met (f1 §3, step 2), is not ruled either.
     - **Why** (f1b review must-fix 2, W-JOIN-HOP; by code reading, UNCONFIRMED). In the shape, a replay reaches the failed job by a hop through a copy adopted since the end (`replayJoin`, `EngineFollow.swift:981`, through `followLayers`, `:800`). f1's clause (f) dates a replay by its stamp (`reading.serial <= stamped`), so it would date this one as met, wherever the stamp is written.
     - At a transfer's end, `9aa337c` has no stamp, so the replay is not met and T20 re-queues the job, as visit-first does: the shape is green there today (`EngineJobs.swift:293-295`). f1's replay half, one stamp written at both ends with clause (f) for replays (f1 review "must add" 1), would turn it red.
     - So the f1 review's "The replay half is sound" (its line 8) does not hold as stated. Its corrected form, "(f) for direct replays only; a hop onto J is dated by its chain" (f1b review "must add" 2), is a reviewer's proposal that no independent reader has checked (P4).
   - **Correct #1 and #2 stay blocking** (S3-R16 1(a)) until item 1b routes them. The draft's status list reports them with their logs.
   - **Step 0's shapes.** Run each one on `9aa337c`, in both orders, 2 rounds each, and record it as red or green (measured), with its log.
     - **Drain timings.** Run every shape in both drain timings. The helpers apply through `applyHeld` (`VerifyC22CorrectProbes.swift:285`, `:415`, `:443`), which, visited first, lets the follow end inside the apply (`EngineFollowBarrierReachTests.swift:25-27`). So only the swept-first runs have two timings:
       - the drain released inside the failed job's free-space read, as the cycle-22 probes do (`VerifyC22CorrectProbes.swift:320`, `:445`);
       - the "late drain", whose follow is released only after the read returns, so that the drain runs after the job's verdict defers (f1b review, line 8). No probe has run it.
     - **The shapes:**
       - f1's T-F1a to T-F10 and W-PR, with f1's T-F4 replaced by the corrected T-F4 below;
       - the f1 review's W-HP and W-AWAY, each at the transfer's end and at the publication's (must-fix 1 and 2), W-DB (must-fix 2) and W-PD (must-fix 3);
       - T-F4, built as f1 review must-fix 5 corrects it (v4's pass reaches zz-x while v4's copy stands, and visit-first's T20 comes at v4), and its lazy twin;
       - f1b's new tests T-F2c, T-F8c, W-HP-d0, W-PD-back and T-B11 (f1b §3), and its open shapes W-HP-late, AV-away, W-ONOFF and the multi-change lazy shape (f1b §7). Add f1b §7's pending-move corners (i) to (iii) where they can be built. The f1b review argues that corner (iv) is unreachable (its should-fix "§7 (iv) is unreachable");
       - the f1b review's W-PD-back2 (must-fix 1), W-JOIN-HOP at both ends (must-fix 2), W-JOIN-OFF and AV-off (must-fix 4), the shape that separates f1b-K19 (must-fix 8), and W-BACK-PUB, with U's publication held at v4 ("must add" 3 and 7).
     - **How.** Build the shapes from the verifiers' helpers (`VerifyC22CorrectProbes.swift:255-342`, `:384-466`). Each asserts visit-first's answers and the failed job's start count, and serves every content it requests (S3-R27 12.2's "Serving", rulings :1091).
     - **A shape that cannot be built** after a real attempt follows S3-R26 item 7's B-T5 rule, as S3-R27 12.5.2 applies it to e1-PR (rulings :585, :1234). The draft records the attempt, why the shape cannot be built, and the residual risk. The shape is not blocking.
     - **A visit-first answer that depends on timing.** For the multi-change lazy shape and W-BACK-PUB, record both visit-first answers and the timing that selects each (f1b §7; f1b review "must add" 7). Their classification is item 1b's.
     - **Every other red shape is blocking** (S3-R16 1(a)) and is reported with its log. Item 1b rules what follows for each one.
     - **Probes and commits.** The shapes are probes, kept under `.build-s3f/c23/`. A red shape is committed as a failing test only right before item 1b's fix for it.
     - **The results** go to the draft's cycle-23 status list as one table: shape × order × drain timing → red or green, with the log.
   - **Item 1b is item 1's whole route:** the replay half (amended for hops, if that holds), the join rule, the window's close (f1b §1, step 6), the stamp's clears, the tests, the kills, C2 and the records. The orchestrator appends it after three inputs, between fixer runs or between steps, and the fixer takes it as item 6 says:
     1. step 0's measured shape results (above);
     2. f1c, a re-analysis of f1b as its review corrects it, with its own review;
     3. the owner's answer, if one comes, on whether the dating of a join made in an ENOSPC end's read is timing (S3-R16 item 2).

     f1c is launched when step 0's shape results are committed. It is not launched if the owner has classed that dating as timing by then.
   - **Until item 1b is appended,** the f1 and f1b reviews' must-fix items bind only through step 0's shapes and drain timings, and f1 review must-fix 2 through the two causes as well. Every other part of f1, f1b and their reviews binds only as item 1b carries it.

2. *Correct #3: the flake in `shutdownClearsTheJoinsBehindAVerdict(.followVisitedFirst)`* (A-T-SD, `EngineFollowBarrierDeferBucketTests.swift:754-788`, "DBT" below). Blocking (S3-R16 1(d)): a test that fails in any run. Its cause is a test that races its own set-up (f2 §1; review should-fix 1). It is not 1(a).
   - **The failure.** The third of the verifier's three debug Sync runs (09:16:20-09:26:20; it ended at load averages 21.05, 95.01 and 81.74) failed at DBT:781 and :786: zz-o's waiter and every member got `.success(… byteSize: 20)` for `.failure(.shutDown)`. Run alone, the test passed 8/8. PROBE-C22C-SHUTDOWN-BUCKET-RACE gave both outcomes at a 1-minute load of 128-132 (`correct-probeC22ShutdownBucketRace.summary.log`).
   - **The mechanism** is f2 §1's, confirmed by its review. v4's visit re-queues O by T20 (`EngineJobs.swift:360-363`). With `holdRetry: false`, the retry can resolve before shutdown's first turn takes the waiters.
   - **Route: f2's, as its review corrects it:**
     1. **The probe first** (f2 §2, f2-R1). Visited first, with `holdRetry: false`, force the serve first (`driving([b.s.time], fence: engine) { awaitCondition { $0.state.jobs[b.o.transferID] == nil } }`), then shut down and assert DBT:781 and :786 unchanged. It is red in every round by construction, not by measurement: the verifier's `serve=true` arm printed ok(20 B) in 2/2 rounds but asserted nothing (f2 §2). Record O's state and request count after the set-up and after v4. It is not committed.
     2. **The fix**, on its own commit: `holdRetry: true` at DBT:763 (f2 corrects the finding's :762). DBT:777-786, the seed, the ending, the wanters, the count and the arguments stay as they are (G3).
     3. **The set-up check** (review must-fix 2). Visited first only, after DBT:765, one `readForTests` of O's state and `interests.count`, then `try #require` that they are `.downloading` and `count + 1`. It is an assertion, not an `awaitCondition`, and it sits in A-T-SD, not in `deferBucketApplyV4`, where A-T1's unheld retry (DBT:314) would race it.
     4. **The doc fixes** (review "must add" 3): DBT:94-95, worded conditionally (should-fix 3); DBT:533-535 and :756-758; DBT:611 and :681-682 (must-fix 1); and `s3f.md:5526-5527`. Afterwards, a grep of the Sync tests for "verdict's arrival" finds no claim that a retry starts there.
   - **The other tests f2 names** (§3), as its review confirms them. T-PURGE (DBT:542, held at :544) and T-FL (DBT:622, held at :640) already hold the retry, so only their doc lines change (above). A-T1 (DBT:312-337) and DBT:720-752 stay, for f2 §3's reasons. `EngineFollowBarrierSharedMoveTests.swift:354-372` and `EngineFollowBarrierTests.swift:1318` stay (G3), because neither races a served retry (should-fix 6). No other set-up changes.
   - **No other route:** no assertion that accepts either answer, no prefetch-lane substitute, no clock moves in the committed test (they fire O's backoff alarm and order nothing against the shutdown; should-fix 2), and the visited-first argument stays (f2 §2).
   - **The order.** Item 2 is step 1, on its own (item 5). Item 1 changes no code before item 1b, so T20 fires here as it does on `9aa337c` (`EngineJobs.swift:360-363`; f2 §1).
     - f2 review "must add" 1's re-run is carried this way. A-T-SD's set-up check runs in every Sync bundle, so every later commit re-checks T20, item 1b's included.
     - The draft's status list records A-T-SD green, in both orders, with its set-up check, on A-T-SD's own commit (step 1) and on item 1b's last commit.
     - A failure there is a T20 regression: fix the code, not the test (review "must add" 1).
   - **Records:**
     - the set-up change, one to one: the old `holdRetry: false`, the new `true`, the cause (T20) and why no scenario is lost (should-fix 9). That record carries should-fix 4's correction: the "O verifying at the shutdown" interleaving was asserted only at random, not never. It cites a test that shuts down during a publication deterministically, such as `EngineFollowBarrierSharedMoveTests.swift:354`, whose swept-first arm requires `shutDown` (`:357-360`), or records that no test covers `EngineDispatch.swift:1078-1080`;
     - the residual (must-fix 3), under "Residual risks (S3-R16)", non-blocking (S3-R16 item 2): a shutdown inside the barrier answers `shutDown` to every answer that waits for the drain. Its probe is f2-R1 beside A-T-SD's swept-first arm (`shutDown` ×11, 4 joins behind, 3/3). f2-R1's figures are recorded, with the note that f2-R1 is not committed. The record qualifies `EngineFollowBarrierTests.swift:1315`.
   - **Evidence at the close** (review "must add" 5): f2-R1 red, by construction; A-T-SD green, with DBT:777-786 passing in both orders; the bundle runs, with their load samples. 30 iterations per argument, on the host and on the iOS Simulator under `sim.lock`, are run, as a regression check only (should-fix 8).
   - **Fixer hours** (estimate; review should-fix 7): 2-3 h on its own, or 1-1.5 h if the cycle's shared close runs cover its bundle runs.

3. *Correct #4 and reqs #1: the purge's six misses.* Blocking (S3-R16 1(f)). Best of 3, heartbeat:
   - correct #4, the verifier's full release Benchmarks run (09:33:14-09:46:39): `fourGroups` 64.00 ms (1-minute load 3.61 to 3.60), `oneGroupScope` 41.69 (3.76 to 3.61), `oneMemberGroups` 38.17 (4.99 to 3.76), `retryJobs` 37.59 (3.60 to 3.36), `oneGroup` 36.91 (4.12 to 4.99) and `sharedJobFourGroups` 18.70 (3.61);
   - reqs #1, the fixer's gate run and re-run at loads of 6.07 or less (`s3f.md:7791-7797`): 62.21 and 62.56, 39.74 and 39.82, 37.11 and 37.38, 36.06 and 36.19, 35.71 and 35.98, and 17.82 and 17.91 ms, in the same order;
   - `sharedJob` (4.76), `userWaiters` (7.13) and `ensures` (7.15 ms) pass (correct #4), and `purgeWhileOwedTurns` closes at 5.01 ms (`s3f.md:7797`).
   - **e2-A2.1 to A2.4 alone close none of the six** (f3 §2, estimate; its review finds this robust). e2's after-A2 estimate for (i), 5-12 ms (e2:193), is superseded, and the draft records that (f3 "must say" 1).
   - **Route C, in one turn,** in stages A, B and C (f3 §3.1 and §5), as its review corrects it. Each part is its own commit. Every in-place access follows S3-R27 item 1's exclusivity rule: `applied`, the request and `claims` are taken into locals, and the other writes come after the access (f3 "must say" 2).
     - **Stage A:** e2-A2.1, A2.2 and A2.3, C-1 and C-4; then the id-level F-1 clause (`EngineCommands.swift:1884`) on its own, with every suite green; then 12.5.15's audit, extended to C-2's and C-3's mid-turn states; then C-2 and C-3. Estimated 5-12 ms for the five 10,000-job shapes, and about 1 ms for `sharedJobFourGroups` (f3 §5; review should-fix 2).
     - **Stage B:** the extended audit for C-5's mid-turn state (retired jobs stay in the table until the rebuild; f3 §3.3), then C-5, the rebuild in sorted order, with no order audit. Estimated 4-10.5 ms.
     - **Stage C:** e2-A2.4's table order, only after the purge suites' order audit (S3-R27 item 3's A7 rule), with the iOS SDK cited (C7). Estimated 2-7 ms.
   - **The parts, with the review's corrections:**
     - **C-1** replaces e2-A2.5's per-job collection with one pass keyed on the job table, and A2.5's kills are re-run (f3 "must say" 3). The stale-retry difference is heap and alarm only, not an answer (`EngineTimers.swift:110-112`), and it is recorded. C-1's epoch arm is killed on a built state with a stale `.retry` of a kept job, or dropped and classed Equivalent (should-fix 4).
     - **C-2's four conditions bind** (f3 "must say" 4). It reads the job through a `mutating` `Job` method on `values[i]` (`_modify`, SDK :8054-8060), not through the getter (should-fix 1). Its read also skips a job with nothing to withdraw, so that `userWaiters` and `ensures` keep today's cost; the per-stage measurement shows it (should-fix 3). The draft gives the argument for its window (should-fix 8). It stays a variant of `retire`'s funnel, for example `retire(at:whole:)` calling `removeJob(at:)`, or the draft proposes the ARCHITECTURE §7.1 amendment (S3-R6; must-fix 4). Each of C-2 (a) to (d) forced false is Equivalent (S3-R19 item 2).
     - **Must-fix 3's option (i) is part of C-2.** C-2 (b) applies only to a `.downloading` job. C-2′ empties a claim-held job whose C-2 (b) holds. After C-2's step 1 (the drops, the heals and the run's `held`), it moves the interest storages out whole to the freeing list, resets the counts, sets `heldLane = last` and writes `claimHeld`. The job stays, held by its claim, in today's end state (`settleRemoval`'s `claimHeld` arm, `EngineJobs.swift:427-431`). The skipped re-queue of a `.queued` job, a ticket and a place, is recorded under S3-R16 items 2 and 3. Option (ii)'s route, e2-B′, is not authorised.
     - **C-3** comes after the F-1 clause. A test that the clause turns red is a finding of its own: S3-R16 1(b) if its state is real, with no route in cycle 23, and the clause stays uncommitted. C-3 is then not made, and `fourGroups` depends on stage C (f3 §5). C-3's place in the turn, before or after `withdrawPurgedJoins` (`EngineCommands.swift:1016`), is fixed before C-3's commit, and stage A's figures are taken with C-3 in that place (should-fix 9). `fourGroupJoins`' step-0 figure is taken on `9aa337c`, which has no C-3.
     - **C-4** reads the applied copy in place, through `position(of:)` and `entries[i]` (public: `ValidatedManifest.swift:15`, `:86-91`). A job counts its purged ids with no Set, and takes `.all`'s path when all of them are purged (f3 §3.1); f3 §3.4's kill of "C-4's count" depends on it. C-4 edits no file outside WP-F (P1). It amends 12.3's "`isPurged` keeps its entry copy". S3-R27 12.5.16's rule for the `.scope` copy stands. After C-4 removes the entry copy, 12.5.16's two conditions cannot hold, so a `.scope` miss after C-4 is WP-F's (blocking under S3-R16 1(f)).
     - **C-5** (must-fix 1, "must add" 2; should-fix 5):
       - every removal the walk makes waits for the rebuild, or for the second pass below, through a walk mode of `removeJob`;
       - no key is inserted into or removed from `state.jobs` between the collection and the rebuild (or the second pass), and a debug-build check says so;
       - the order is the walk, the rebuild (or the second pass), the compaction, C-1's pass, then the final `notifyObservers` (`EngineCommands.swift:1065`), with both SDKs cited (C7);
       - the rebuild runs only when the retired share is large. Otherwise the retired jobs are removed by key in a second pass. The draft records the threshold and its mutants;
       - the rebuild moves the kept values, and no second reference to the table lives across the visits.
     - **The freeing** (e2-A2.3) runs in pinned slices of 512, not in one later turn (f3 "must say" 7). Its spawn gets a REENTRANCY row. Shutdown drains the list in its own slices (should-fix 6), pinned as S3-R27 item 6 pins `settle`'s: the slices recorded, and the slice's drop-mutant failing 2/2.
     - **The kills** are f3 §3.4's, corrected (must-fix 2; should-fix 4 and 5). Each is 2/2 in each order that reaches its branch, by value:
       - C-2 (c) forced true is reached only by `purgeRemovesInAscendingTokenOrder`;
       - C-3's group filter is killed by a new `.all` test, in both orders, with a `.prefetch` group, a `.userInitiated` prefetch group and an `ensureAvailable` group pending on distinct contents, and by a new model-test variant that purges `.all`. The existing model test stays (G3);
       - C-2′ forced false changes only cost (Equivalent, S3-R19 item 2). C-2′'s writes to the end state are killed by a test that reaches C-2′, a claim-held job whose C-2 (b) holds. By code reading, `purgeRemovesInAscendingTokenOrder` is one (`EnginePurgeWithdrawalTests.swift:83-91`), and `…EarlierRelane(claimed: true)` is not, since C-2 (b) fails there (must-fix 2). The run decides;
       - the narrowed C-2 (b)'s `.downloading` test is killed each way, or classed with its argument (S3-R19 item 2);
       - the rebuild filter's mutants are listed and killed.
   - **The in-letter shapes with no gated case** (S3-R27 12.1; f3 §3.6, review must-fix 3 and "must add" 1). Each becomes a BenchSync case, gated as 12.3 gates its cases: its heartbeat, best of 3, with loads, with the purge's synchronous turn beside it, and its 'before' figure from step 0. One that misses on `9aa337c` is committed red right before stage A's first part. A new file for them follows item 4's ownership rule. The five cases:
     - `keptUnderThreeGroups`: a user waiter on each of 10,000 ids plus three prefetch groups. Estimated 38-48 ms today, and 34-39 ms after route C.
     - `fourGroupJoins`: 40,000 joins waiting for the follow. Estimated 15-22 ms.
     - `mixedLaneGroups`, the mixed-lane shape: two prefetch groups over the same 10,000 ids, each id with its own content, the first registered at `.prefetch` and the second at `.bulk`. Estimated 24-33 ms after route C without option (i).
     - `pendingClaimGroups`, the pending-claims shape: two prefetch groups over the same 10,000 ids, the second registered just before the purge. Estimated 16-18 ms after route C without option (i).
     - `oneMemberGroupsFourPerID`: 40,000 one-member prefetch groups, four on each of 10,000 ids. Estimated 8-16 ms after route C (review "must add" 1).
   - **The re-lane of a kept `.queued` job** (review "must add" 6, answered yes). Under S3-R16 items 2 and 3, the purge may skip `settleRemoval`'s re-lane (`EngineJobs.swift:435`) of a kept `.queued` job whose lane the purge leaves unchanged. Today's `relane` re-enqueues every queued user job, even when its lane is unchanged (`:311-314`), and that changes only the job's place and ticket (`enqueue`, `:563-578`).
     - This holds while S3-R16 item 1 holds: a probe shows, in both orders, that the answers and every job's start count equal visit-first's, and the draft records the place difference under "Residual risks (S3-R16)".
     - The `.failed` arm's re-admission stays.
   - **Item 3b,** a route in one turn for the purge cases that route C does not reach, is being analysed now (f3b, with its review). It covers `keptUnderThreeGroups`, `fourGroupJoins` and `oneMemberGroupsFourPerID`, plus `mixedLaneGroups` and `pendingClaimGroups` if option (i) leaves them above 8.5 ms.
     - The orchestrator appends it as "item 3b" between fixer runs, or between steps; the fixer takes it as item 6 says.
     - Until it is appended, those cases are measured and reported, not routed.
   - **The decision rule** is S3-R27 item 1's: at or below 8.5 ms closes a case; 8.5 to 10 ms is recorded "at the edge" and is not blocking; a miss is blocking.
     - Measure every purge case after each stage: 12.3's twelve and the five above, best of 3, with loads.
     - **The stage trigger names the cases each stage can move** (should-fix 7). Stages B and C change only the cost of retiring jobs from the job table (f3 §5). Stage C also drops the walk's key sort (`EngineCommands.swift:1019`; 2-3.5 ms, f3 §3.2, estimate), too little to close a case that retires no job (f3 §3.6).
       - So stage B runs only if a case that retires jobs in the purge's turn is above 8.5 ms after stage A. Stage C likewise runs only if one is above 8.5 ms after stage B.
       - A case above 8.5 ms that retires no job triggers neither stage. By f3's estimates these are `keptUnderThreeGroups` and `fourGroupJoins`. Item 3b routes them.
       - The draft says, for each purge case, whether it retires jobs, from the case's set-up.
       - A trigger without a quiet load follows S3-R27 item 10's rule for deciding figures.
     - A miss after stage C, or after the last stage triggered, is blocking, with no route in cycle 23. The exception is a case that item 3b covers (above). Its route is item 3b, and once item 3b exists, a miss after item 3b's route is blocking, with no route in cycle 23. Report each miss with its parts' figures and loads.
     - Red cases across route C's parts, and across every other cycle-23 commit, follow item 5's "Red cases across the cycle" (S3-R27 12.5.12, extended).
   - **e2-B′ is not authorised** (f3 §4). The fixer does not build it.
   - **Records** (f3 "must say" 12): item 9's rows for C-1's pass, C-3's pass, the rebuild and the freeing slices, in place of 12.5.17's rows for the parts they replace; RE-S24's text, as 12.3 says; 12.5.15's audit, extended to the walk (f3 §3.3) and to C-3's mid-turn state (should-fix 9), made before the parts it gates (stages A and B above).
   - **Fixer hours** (estimates, f3 §5): stage A 12-18 h, stage B 3-4 h and stage C 4-6 h, 19-28 h in all. Option (i) and the five new cases are not in them.

4. *S3-R27's unfinished work* (correct #5 to #7, reqs #2 to #6). S3-R27's routes and rules stand. In S3-R27's order:
   - **S3-R27's step 5 (cycle 23's step 4): item 3, the APM answer turn** (correct #5). PROBE-C21-APM, rebuilt on `9aa337c` and run in release with `-enable-testing`, in-actor, best of 3, at a 1-minute load of 9.85 to 8.65: group 9.37 ms (at the edge), groups 11.10 ms and users 13.93 ms (misses). A3 and A3′ landed in e2-A1.6 (`332b6cc`), so sub-step 4 reuses them.
   - **S3-R27's step 6 (step 5): item 4,** the k = 2 and k = 4 in-letter shapes, with A1 and A2 if taken (reqs #2). Correct #9 calls them unmeasured, so unproven.
   - **S3-R27's step 7 (step 6): the kills.**
     - Item 5's remaining kills, d4 review's steps 6 to 12: b22-no-waiter-owner, p7 with r5, r8, vy, r2c, b22-no-run-owner and r2b. b22's owner checks are now `EngineFailures.swift:858-859` and `:866-868`, still at 0 hits (correct #7).
     - The 429 probe: item 5's default-tuning probe.
     - e1-R1's rewritten mutants (12.5.6), with 12.2's kill table.
     - The kills of the e1-PS, e1-P1 and e1-P2 fixes (12.5.4). A mutant whose code item 1b rewrites is rewritten for that code and run there, as 12.5.6 does for e1-R1. So e1-P1's four (`s3f.md:7147-7149`) wait for item 1b: they are rewritten for its code and run with its kills.
     - Item 3's mutant runs, and item 1b's if item 1b places them here. Their tests land with their parts.
     - What reqs #3 already ran is evidence, not kills of record. `v-e1r1-no-enoent-record`, `v-e1r1-kept-returns-nil` and `v-e1ps-no-supersede-record` failed 2/2. `v-e1p1-rule-false` failed its one run (12 issues), but in one test only by its 180 s time limit, which is no kill (S3-R27 item 5). That test, e1-P1's other side, gets an assertion on an answer, a start count or a clause that fails first. The specs are `s3f-probes-c22/reqs/tools/mutants22.py` and `mutants22b.py`.
     - Reqs #8's guard: `.timeLimit(.minutes(1))` on `publishAllMatchesOnePublishPerEvent(seed:)` (`Tests/ZTronAssetSyncTests/Engine/SubscriberQueueBatchTests.swift:95`), as `SPEC.md:331` asks. It is a guard only, so G3 holds. The draft records it.
   - **The three unreached lines** (correct #6, reqs #4): `EngineCommands.swift:1001`, `:1004` and `:1009`. They are the purge predicate's `return true` under `.all` (`:1000-1001`), and its answer for an id that the applied copy does not list, under `.evictable` and under `.scope` (`:1003-1005`, `:1008-1010`).
     - Each is reached by a test that kills, 2/2, its mutant that answers false (`return true` → `return false`), or it is removed with the reason recorded (S3-R16 1(e)). That mutant is the drop-mutant for all three: dropping the `return` leaves an empty `case` (`:1001`) or a `guard` body that falls through (`:1004`, `:1009`), and Swift rejects both.
     - For `:1001`, the expected reach is f3 review must-fix 2's new `.all` test (item 3), with the groups' joins waiting swept first, through `withdrawPurgedJoins` (`EngineCommands.swift:1016`).
     - For `:1004` and `:1009`, the state is reqs #4's: a purge of `.scope` and one of `.evictable` while a job, a waiting join or an owed re-route holds a non-user interest in an id that an apply delisted while a follow is owed.
     - C-4 or C-3 may rewrite these arms. Then this applies at their new lines, in step 6.
   - **Ownership** (S3-R27 11.6; reqs #9). Any new `Tests/ZTronAssetKitBenchmarks/BenchSync*.swift` file that cycle 23 adds is authorised as WP-F's, under 11.6's terms. 11.6's first condition is amended to read: "Each file holds only `SyncBenchmarks` and `SyncBench` extensions and the helper types they use, declared in that file. No helper type's name collides with another work package's, and no file edits another work package's benchmark file."
   - **S3-R27's step 8 (step 7): every record still missing** (reqs #5 and #6):
     - reqs #6's 11.6 record. List under "Authorised edits outside WP-F" the eight bench files (`BenchSyncCycle21.swift`, `BenchSyncJoinChains.swift`, `BenchSyncReroutePins.swift`, `BenchSyncRerouteTakeOff.swift`, `BenchSyncReroutes.swift`, `BenchSyncWaitersBound.swift`, `BenchSyncCycle22.swift` and `BenchSyncCycle22Purge.swift`) and any that cycle 23 adds, each with its helper types, citing 11.6 as amended above. Correct `s3f.md:8214` (reqs #6 cites `:8213`, a blank line) and `:8237-8238`, add the ARCHITECTURE §1.2 proposal (S3-R6), and point row `:6959` at the record;
     - item 5's `followedLane` record (S3-R27 item 5), which cycle 22 did not write (`s3f.md:6945`, `:7713-7714`), and reqs #10's stale records, updated to cite 12.1 and e1-R1's change (`s3f.md:7367`, and rr21-T8b's at `:5750-5755`);
     - item 9's rows, items 7 and 8, and the "Proposed document changes" of cycles 21 to 23 (reqs #5; cycle 21's reqs #9, #10, #11 and #14);
     - the 12.x records: 12.2's, 12.3's, 12.5.9's and 12.5.18's, found by content where their lines moved.
   - **Item 9** applies on the final HEAD, with `9aa337c` in place of `d5b2ab9`. The cycle-22 dispositions ("Not reached and structural lines (cycle 22)", `s3f.md:7758-7788`) stay listed, updated where cycle 23 changes them.

5. *Order of work.* Commit each step on its own. Red first: S3-R27 item 10's red-first rules apply, with `9aa337c` in place of `d5b2ab9`. A named finding goes with its item.
   0. Run `verify.sh --quick` on `9aa337c`. Run item 1's step-0 shapes on `9aa337c`, and commit their table to the draft's status list: f1c is launched once it is committed (item 1). The shapes may run after step 1's commits instead, if that suits the fixer; they still run on `9aa337c`. In a scratch copy of `9aa337c` under `.build-s3f/c23/`, take the 'before' figures, best of 3 with loads, of item 3's five new cases. S3-R27 items 3's and 4's cases take theirs here or at the start of steps 4 and 5, on such a scratch copy either way. The twelve purge cases' 'before' figures are cycle 22's (item 3).
   1. Item 2: f2-R1, then A-T-SD's change on its own commit.
   2. Item 3, stage A: the red cases' commit, then each part, with the extended audit before C-2 and C-3, then every purge case's figures.
   3. Item 3, stage B and then stage C, each only if item 3's stage trigger fires, each followed by every purge case's figures. Stage B's extended audit comes before C-5.
   4. S3-R27's step 5: its item 3 (item 4 above).
   5. S3-R27's step 6: its item 4.
   6. S3-R27's step 7: the kills, the three unreached lines and reqs #8's guard.
   7. S3-R27's step 8: the records, then the close.
   - **Item 1b and item 3b** are each taken at the first step that starts after it is appended (item 6).
     - Item 1b: its red shapes first, then its route.
     - Item 3b: its red cases first, then its route, and then every purge case's figures. Its natural place is after route C's stages.
   - **Red cases across the cycle** (S3-R27 12.5.12, extended). From `9aa337c` to the close, the Benchmarks stage may stay red for every case already committed red that is not yet closed, or that is reported as a miss.
     - A miss is reported when the draft's status list lists it with its figure, its loads, and the item that routes it, or "no route in cycle 23".
     - Each commit message names the cases that are red at that commit.
     - Every other stage is green at every commit, except at S3-R26 item 11's red-first commits, which may also carry those cases.
   - **The close** (step 7): item 9 and every gate on the final HEAD. Run `verify.sh --full` and quote its last line. A FAIL whose only cause is P-13 (WP-B's; S3-R26 item 10) is reported as such (12.1), and each of its other stages also runs and passes on its own.

6. *The budget.*
   - A fixer run may end at its working budget. The next run continues from HEAD. So commit every step when it is done, and keep the draft's cycle-23 status list current, with item 7's mapping.
   - **Appended items.** At the start of every step, the fixer re-reads the end of the rulings file for items appended since (item 1b, item 3b). It takes each one at the first step that starts after it is appended, and the draft's status list records when each was taken.
   - Every agent keeps its command output short: it sends the output to a log file and reads the summary lines back.
   - The verifiers run lens 3's heavy checks first (reqs #7): Sync ×3, TSan, the iOS generic build and the iOS Simulator suite, the benchmarks and the mutants. Then the rest.
     - `sim.lock` is held for the simulator and coverage runs, and the release benchmarks run in a window with a 1-minute load of 10 or less, when one occurs. Otherwise the C2 rule's "not measured at a quiet load" applies (rulings :763).
     - These runs also re-measure the cycle-22 "closes" figures that reqs #7 left unproven (cycle 21's reqs #2 to #4: `commitTurns(.waitersStalledSubscriber)`, `commitTurns(.manyGroups)` and `purgeWhileOwedTurns`).
   - **Fixer hours** (estimates):
     - step 0's shapes, about 8-12 h: f1b's 4-6 h for its step 0 (f1b §8), plus the f1b review's 4-6 h for the late drain and its new shapes (its "must add" 8);
     - item 2, 2-3 h; item 3, 19-28 h; e1-R1's kills, 3.7-5.5 h of mutant runs (12.2);
     - item 1b is not in them. The f1b review puts f1b's route, as it corrects it, at about 38-59 h, step 0 included (its "must add" 8), up from f1's 12-18 h (16-24 h by its review) and f1b's 22-33 h.

     A cut-off inside the cycle is likely.

7. *The named findings.* The draft's cycle-23 status list keeps this mapping:
   - correct #1 and #2 → item 1, routed by item 1b;
   - correct #3 → item 2;
   - correct #4 and reqs #1 → item 3;
   - correct #5 and reqs #2 → item 4 (S3-R27's steps 5 and 6);
   - correct #6 and #7, and reqs #3 and #4 → item 4 (S3-R27's step 7, and the three unreached lines, `:1001` included);
   - reqs #5 and #6 → item 4 (the records);
   - reqs #7 → item 6;
   - reqs #8 and #9 (not blocking) → item 4 (step 6's guard, and the ownership rule).
