## Orchestrator ruling added 2026-11-06 (cycle 22's verification; written before the cycle-23 fixer starts)

**S3-R28.** Cycle 22 implemented S3-R27 in part (`d5b2ab9..9aa337c`, 44 commits; the last production commit is `2abddd1`, e2-A2.5): steps 0 to 3, step 4 up to e2-A2.5, e2's kills, and step 8's gates and re-measures (`s3f.md:6910-6947`). Its verifiers left 14 blocking findings, 7 in each lens, and S3-R27's steps 5 to 8 are unfinished. This ruling routes them. Cycle 23 starts as run 10, and its fixer may take several runs (item 6).

**S3-R28 is cycle 23's ruling.** S3-R16 to S3-R27 apply wherever S3-R28 does not change them. Where S3-R28 differs from an earlier ruling, from a specification or from an analysis, S3-R28 decides. The cycle-23 verifiers judge by S3-R16 to S3-R28, with item 1b once it is appended (item 1).

Where to find things:
- **The cycle-22 verifiers' findings** are in `.build-orchestrator/s3f-c22-issues.json`, on `9aa337c`. They are cited as "correct #n" (`lenses.correct.issues[n-1]`) and "reqs #n" (`lenses.reqs.issues[n-1]`).
  - Fix them in S3-R1's order: blocking first.
  - A verifier finding is **named** by this ruling when it reports the same case, shape, mutant or `path:line` (at `9aa337c`) as an item here.
    - The fixer records the mapping ("correct #n → item k") in the draft's cycle-23 status list (item 7).
    - A named finding is closed by its item's route and decision rule, even where the finding proposes another fix.
  - A blocking finding that this ruling does not name follows S3-R16 and the general rulings.
- **The read-only analyses made for this ruling**, in `.build-orchestrator/s3f-c22-analysis/`:
  - `f1-enospc-windows.md`, with its review `f1-enospc-windows-review.md` (item 1). The review finds f1 UNSOUND as a whole, and its replay half sound;
  - `f2-flake.md`, with `f2-flake-review.md` (item 2; CORRECTED);
  - `f3-purge-route.md`, with `f3-purge-route-review.md` (item 3; CORRECTED).

  How to read them (S3-R27's header rules, applied to f1, f2 and f3):
  - Each review corrects its report. Where a review and its report differ, the review wins. Where either differs from this ruling, the ruling wins.
  - **What in a review binds.** Its must-fix items bind, as this ruling corrects them. Its should-fix items bind only where this ruling names them, as this ruling corrects them:
    - f1 review: "The probe helpers" and "The REENTRANCY note" (its should-fix items are not numbered);
    - f2 review: should-fix 1, 2, 3, 6, 8 and 9;
    - f3 review: should-fix 1, 4, 5, 6, 8 and 9.

    A review's "What the ruling must add", a report's recommendation, every other should-fix item and every "optional" bind only as this ruling carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.
  - Below, "must add" n is a review's "What the ruling must add" n, and "must say" n is a report's "What the ruling must say" n.
  - Their line numbers are at `9aa337c`; re-cite them after a change. Their figures not marked "measured" are estimates, from code reading and from the draft's and the verifiers' measurements. A measurement decides.
- **Cycle 22's scratch evidence:** the verifiers' probes, logs and tools in `.build-orchestrator/s3f-probes-c22/` (`VerifyC22CorrectProbes.swift`, `reqs/tools/`), and the fixer's `.worktrees/s3f/.build-s3f/c22/` (the scratch copy `snap0`, `tools/`). Do not delete them. Cycle 23's scratch files go under `.build-s3f/c23/`.

**How a C2 figure is read in cycle 23.** S3-R27's rule ("How a C2 figure is read in cycle 22") applies to every C2 case that cycle 23 measures. The bar is the owner's (S3-R27 12.1): `c2Budget`, 10 ms, over 10,000 ids however grouped, with at most 4 interests on one id and one subscriber, which may be stalled. 8.5 ms decides only the routes that name it.

1. *Correct #1 and #2: the ENOSPC windows.* Blocking (S3-R16 1(a)). Both are measured 2/2, red swept first (`s3f-probes-c22/correct-probeC22TransferSpaceDrainJoin.summary.log`, `correct-probeC22ApplyInRead.summary.log`).
   - **Correct #1** (PROBE-C22C-TS-DRAIN-JOIN, seed 2_029_101). A user request made before T's transfer ENOSPC is replayed inside the free-space read and meets no stamp (`EngineJobs.swift:293-294`), so T20 re-queues T (`:360-364`). Visit-first answers A, X and V `insufficientSpace` and starts T once. Swept first, all three get `ok(100000 B)` and T starts twice. With V made inside the read (seed 2_029_201), both orders give `ok` and 2 starts.
   - **Correct #2** (PROBE-C22C-APPLY-IN-READ, seed 2_029_301). v4, applied inside a publication's free-space read, makes the visit branch (`:290-291`) date v3's move after the end, so T20 re-queues T. Visit-first answers A and X `insufficientSpace` with one start; swept first, `ok` with two.
   - **The causes are two** (f1 §1, as review must-fix 2 corrects it): a re-lane dated by the wrong clock, and a re-queue that visit-first makes and the swept-first engine never makes before the verdict.
   - **The replay half is ruled now** (f1 review "must add" 1):
     - one stamp record on the job (f1's `Job.spaceEnd`), holding `stampsMinted` at the end. Both ENOSPC ends write it in the end's own turn, before the first await: the transfer's in place of `transferSpaceEnd = applies` (`EngineFailures.swift:198-205`), and the publication's in its ENOSPC arm (`EngineDispatch.swift:1298-1301`), in the turn of `recordPublicationEnd` (`:1259`). `transition` mints no stamp between them;
     - clause (f), `reading.serial <= stamped`, for replays only: outside a visit (`!inFollowVisit && !visitingAfterVerdict`; review must-fix 6);
     - `Job.transferSpaceEnd` (`EngineState.swift:867`) and `AttemptEnd.stamped` (`EngineFollow.swift:2017-2022`) removed. `metInItsAttempt` is their only reader (`EngineJobs.swift:291`, `:293`);
     - clause (b): a join made while `bringingInbound` is met (f1 §3 step 2 (b)). For this, `relane` is told a join from a removal (f1 §3 step 2). A removal keeps today's count (review must-fix 6);
     - correct #2's proposed fix is rejected (f1 "must say" 5). Its step 1 breaks T-F3 and its step 2 breaks W-PR, both green on `9aa337c` by code reading.
   - **The stamp's lifetime** (review must-fix 4) runs from the end to the deferral or the verdict. The stamp is cleared in `recordDeferredVerdict` and in `decideSpaceFailure`, as well as at the attempt's start (`EngineDispatch.swift:741-743`). `spaceFailed`'s f-4 note (`EngineFailures.swift:566-568`) names it among what the epoch check re-validates (C3).
   - **Joins keep today's dating, apart from clause (b),** until item 1b.
     - The visit branch reads, in every state, the count it reads on `9aa337c`. `transferSpaceEnd`'s count moves into the record with its writer (the transfer's end only) and its lifetime (cleared only at the start).
     - f1's `copy`, `publication` and `movedAway` fields and its clauses (c) to (e) are item 1b's. So is its clause (a), which also changes the visit branch.
     - So correct #2 (T-F2a) stays blocking until item 1b. The stamp fixes correct #1 and T-F9 (review, "What holds"), and clause (b) fixes T-F7 (f1 §3, by code reading).
   - **Tests,** in f1's new `EngineFollowBarrierSpaceWindowTests.swift`:
     - T-F1a and T-F1b (correct #1's two sides), T-F9 (correct #1's twin, for a withdrawal), T-F7 and T-F10 (clause (b)), and T-F3 and W-PR, kept as tests of the rejection;
     - each runs in both orders and asserts visit-first's answers and T's start count. It serves every content a mutant can request and asserts which were requested, as S3-R27 12.2's "Serving" says;
     - they are built from the verifiers' helpers (`VerifyC22CorrectProbes.swift:255-342`, `:384-466`), changed to read the new record instead of `transferSpaceEnd` (`:251`, `:303`; review, "The probe helpers");
     - the bound test's setup `#require` (`EngineFollowBarrierReroutePinSpaceTests.swift:105-107`) reads the record's stamp, one to one. It is cycle 22's own test, so no `MIGRATION.md` entry is needed.
   - **Kills** (f1 §3's table, as its review corrects it). Each is 2/2 in each order that reaches its branch, after a green run of the unmutated code in both orders. A kill is by an answer, a start count or a clause, never by a hang or a time limit:
     - B1, the transfer's end's write dropped: T-F1a;
     - B2, (f)'s `<=` as `<`: `userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict` (`EngineFollowBarrierReroutePinSpaceTests.swift:160`);
     - B3, (f) forced false and forced true: `pinSpaceRead`, T-F1a, T-F1b and `userJoinFromInsideAnENOSPCsReadSkipsItsVerdict` (`:174`);
     - B9, (b) dropped. Without (c) it falls to today's count, so T-F7 is its expected killer. The run decides, and the draft records the killing test in each order;
     - B11, the clear at the start, is not Equivalent (review must-fix 4). It and the two new clears are each killed by a test, or their path is shown unreachable and removed (S3-R16 1(e)).
   - **The controls** stay green in both orders (f1 §3): e1-P1's three tests and e1-P2's two; the two `…InItsRead` tests in their three cases, and `barrierSkipsTheBackoffForAVisitAfterAPublicationsEnd` (`EngineFollowBarrierSpaceReadTests.swift:35`, `:121`, `:189`); the later-verdict test's ten cases (`s3f.md:7180-7182`); the Sync bundle.
   - **Step 0's shapes.** Run each on `9aa337c`, in both orders, 2 rounds each, and record it as red or green (measured):
     - f1's T-F1a to T-F10 and W-PR;
     - the review's W-HP and W-AWAY, each at the transfer's end and at the publication's (must-fix 1 and 2), W-DB (must-fix 2) and W-PD (must-fix 3);
     - T-F4, built as must-fix 5 corrects it (v4's pass reaches zz-x while v4's copy stands, and visit-first's T20 comes at v4), and its lazy twin, as a probe.

     Each red shape is blocking (S3-R16 1(a)). Its fix is the replay half or item 1b. A red shape that the replay half fixes is committed red in step 1, right before the fix. Any other red shape is committed red right before item 1b's fix, and is reported until then with its log.
   - **Item 1b, the join rule** (f1's clauses (c) to (e)), is not ruled here. The orchestrator appends it between fixer runs, after a re-analysis that is running now. Until it is appended, the fixer does not change the dating of joins beyond clause (b). Review must-fix 1, 2, 3 and 5 bind now only through step 0's shapes.
   - **C2.** The replay half adds one O(1) write to each ENOSPC end's turn (f1 §4, estimate). No new case.
   - **Records:**
     - the docs of `metInItsAttempt` (`EngineJobs.swift:289-297`), of `relane` (`:328-357`, "cycle 22's residual" included), of `Job` and of `AttemptEnd` (f1 §3 step 5), and every other comment that names `transferSpaceEnd` or `AttemptEnd.stamped` (for example `EngineState.swift:68`, `EngineFollow.swift:1976`, `EngineDispatch.swift:740` and `EngineFailures.swift:199`);
     - the draft closes its residual (1) (`s3f.md:7151-7155`). Residual (2) (`:7156-7158`) and RR-18's correction (f1 "must say" 12, with review must-fix 2's "directly" sentence, `s3f.md:4385`) wait for item 1b.

2. *Correct #3: the flake in `shutdownClearsTheJoinsBehindAVerdict(.followVisitedFirst)`* (A-T-SD, `EngineFollowBarrierDeferBucketTests.swift:754-788`, "DBT" below). Blocking (S3-R16 1(d)): a test that fails in any run. Its cause is a test that races its own set-up (f2 §1; review should-fix 1). It is not 1(a).
   - **The failure.** The third of the verifier's three debug Sync runs (09:16:20-09:26:20; it ended at load averages 21.05, 95.01 and 81.74) failed at DBT:781 and :786: zz-o's waiter and every member got `.success(… byteSize: 20)` for `.failure(.shutDown)`. Run alone, the test passed 8/8. PROBE-C22C-SHUTDOWN-BUCKET-RACE gave both outcomes at a 1-minute load of 128-132 (`correct-probeC22ShutdownBucketRace.summary.log`).
   - **The mechanism** is f2 §1's, confirmed by its review. v4's visit re-queues O by T20 (`EngineJobs.swift:360-363`). With `holdRetry: false`, the retry can resolve before shutdown's first turn takes the waiters.
   - **Route: f2's, as its review corrects it:**
     1. **The probe first** (f2 §2, R1). Visited first, with `holdRetry: false`, force the serve first (`driving([b.s.time], fence: engine) { awaitCondition { $0.state.jobs[b.o.transferID] == nil } }`), then shut down and assert DBT:781 and :786 unchanged. It is red in every round. Record O's state and request count after the set-up and after v4. It is not committed.
     2. **The fix**, on its own commit: `holdRetry: true` at DBT:763 (f2 corrects the finding's :762). DBT:777-786, the seed, the ending, the wanters, the count and the arguments stay as they are (G3).
     3. **The set-up check** (review must-fix 2). Visited first only, after DBT:765, one `readForTests` of O's state and `interests.count`, then `try #require` that they are `.downloading` and `count + 1`. It is an assertion, not an `awaitCondition`, and it sits in A-T-SD, not in `deferBucketApplyV4`, where A-T1's unheld retry (DBT:314) would race it.
     4. **The doc fixes** (review "must add" 3): DBT:94-95, worded conditionally (should-fix 3); DBT:533-535 and :756-758; DBT:611 and :681-682 (must-fix 1); and `s3f.md:5526-5527`. Afterwards, a grep of the Sync tests for "verdict's arrival" finds no claim that a retry starts there.
   - **The other tests f2 names** (§3), as its review confirms them. T-PURGE (DBT:542, held at :544) and T-FL (DBT:622, held at :640) already hold the retry, so only their doc lines change (above). A-T1 (DBT:312-337) and DBT:720-752 stay, for f2 §3's reasons. `EngineFollowBarrierSharedMoveTests.swift:354-372` and `EngineFollowBarrierTests.swift:1318` stay (G3), because neither races a served retry (should-fix 6). No other set-up changes.
   - **No other route:** no assertion that accepts either answer, no prefetch-lane substitute, no clock moves (they fire O's backoff alarm and order nothing against the shutdown; should-fix 2), and the visited-first argument stays (f2 §2).
   - **The order.** Item 2 lands after item 1's replay half (item 5). The replay half leaves the visit branch unchanged, and a timeout end writes no stamp, so T20 still fires here by code reading. If the set-up check fails there, it is a T20 regression: fix the code, not the test (review "must add" 1).
   - **Records:**
     - the set-up change, one to one: the old `holdRetry: false`, the new `true`, the cause (T20) and why no scenario is lost (should-fix 9);
     - the residual (must-fix 3), under "Residual risks (S3-R16)", non-blocking (S3-R16 item 2): a shutdown inside the barrier answers `shutDown` to every answer that waits for the drain. Its probe is R1 beside A-T-SD's swept-first arm (`shutDown` ×11, 4 joins behind, 3/3). R1's figures are recorded, with the note that R1 is not committed. The record qualifies `EngineFollowBarrierTests.swift:1315`.
   - **Evidence at the close** (review "must add" 5): R1 red, by construction; A-T-SD green, with DBT:777-786 passing in both orders; the bundle runs, with their load samples. 30 iterations per argument, on the host and on the iOS Simulator under `sim.lock`, are a regression check only (should-fix 8).
   - **Fixer hours** (estimate; review should-fix 7): 2-3 h on its own, or 1-1.5 h if the cycle's shared close runs cover its bundle runs.

3. *Correct #4 and reqs #1: the purge's six misses.* Blocking (S3-R16 1(f)). Best of 3, heartbeat:
   - correct #4, the verifier's full release Benchmarks run (09:33:14-09:46:39): `fourGroups` 64.00 ms (1-minute load 3.61 to 3.60), `oneGroupScope` 41.69 (3.76 to 3.61), `oneMemberGroups` 38.17 (4.99 to 3.76), `retryJobs` 37.59 (3.60 to 3.36), `oneGroup` 36.91 (4.12 to 4.99) and `sharedJobFourGroups` 18.70 (3.61);
   - reqs #1, the fixer's gate run and re-run at loads of 6.07 or less (`s3f.md:7791-7797`): 62.21 and 62.56, 39.74 and 39.82, 37.11 and 37.38, 36.06 and 36.19, 35.71 and 35.98, and 17.82 and 17.91 ms, in the same order;
   - `sharedJob` (4.76), `userWaiters` (7.13) and `ensures` (7.15 ms) pass (correct #4), and `purgeWhileOwedTurns` closes at 5.01 ms (`s3f.md:7797`).
   - **e2-A2.1 to A2.4 alone close none of the six** (f3 §2, estimate; its review finds this robust). e2's after-A2 estimate for (i), 5-12 ms (e2:193), is superseded, and the draft records that (f3 "must say" 1).
   - **Route C, in one turn,** in stages A, B and C (f3 §3.1 and §5), as its review corrects it. Each part is its own commit. Every in-place access follows S3-R27 item 1's exclusivity rule: `applied`, the request and `claims` are taken into locals, and the other writes come after the access (f3 "must say" 2).
     - **Stage A:** e2-A2.1, A2.2 and A2.3, C-1 and C-4; then the id-level F-1 clause (`EngineCommands.swift:1884`) on its own, with every suite green; then C-2 and C-3. Estimated 5-12 ms for the five 10,000-job shapes, and about 1 ms for `sharedJobFourGroups` (f3 §5; review should-fix 2).
     - **Stage B:** C-5, the rebuild in sorted order, with no order audit. Estimated 4-10.5 ms.
     - **Stage C:** e2-A2.4's table order, only after the purge suites' order audit (S3-R27 item 3's A7 rule), with the iOS SDK cited (C7). Estimated 2-7 ms.
   - **The parts, with the review's corrections:**
     - **C-1** replaces e2-A2.5's per-job collection with one pass keyed on the job table, and A2.5's kills are re-run (f3 "must say" 3). The stale-retry difference is heap and alarm only, not an answer (`EngineTimers.swift:110-112`), and it is recorded. C-1's epoch arm is killed on a built state with a stale `.retry` of a kept job, or dropped and classed Equivalent (should-fix 4).
     - **C-2's four conditions bind** (f3 "must say" 4). It reads the job through a `mutating` `Job` method on `values[i]` (`_modify`, SDK :8054-8060), not through the getter (should-fix 1). The draft gives the argument for its window (should-fix 8). It stays a variant of `retire`'s funnel, for example `retire(at:whole:)` calling `removeJob(at:)`, or the draft proposes the ARCHITECTURE §7.1 amendment (S3-R6; must-fix 4). Each condition forced false is Equivalent (S3-R19 item 2).
     - **Must-fix 3's option (i) is part of C-2.** Condition (b) applies only to a `.downloading` job. C-2′ retires a claim-held job whose (b) holds, with today's end state. The skipped re-queue of a `.queued` job, a ticket and a place, is recorded under S3-R16 items 2 and 3. Option (ii)'s route, e2-B′, is not authorised.
     - **C-3** comes after the F-1 clause. A test that the clause turns red is a finding of its own, C-3 is not made, and `fourGroups` then depends on stage C (f3 §5). C-3's place in the turn, before or after `withdrawPurgedJoins` (`EngineCommands.swift:1016`), is fixed before `fourGroupJoins`' step-0 figure (should-fix 9).
     - **C-4** reads the applied copy in place, through `position(of:)` and `entries[i]` (public: `ValidatedManifest.swift:15`, `:86-91`). It edits no file outside WP-F (P1). It amends 12.3's "`isPurged` keeps its entry copy". S3-R27 12.5.16's rule for the `.scope` copy stands.
     - **C-5** (must-fix 1, "must add" 2; should-fix 5):
       - every removal the walk makes waits for the rebuild, through a walk mode of `removeJob`;
       - no key is inserted into or removed from `state.jobs` between the collection and the rebuild, and a debug-build check says so;
       - the order is the walk, the rebuild, the compaction, C-1's pass, then the final `notifyObservers` (`EngineCommands.swift:1065`), with both SDKs cited (C7);
       - the rebuild runs only when the retired share is large, it moves the kept values, and no second reference to the table lives across the visits.
     - **The freeing** (e2-A2.3) runs in pinned slices of 512, not in one later turn (f3 "must say" 7). Its spawn gets a REENTRANCY row, and shutdown drains the list in its own slices (should-fix 6).
     - **The kills** are f3 §3.4's, corrected (must-fix 2; should-fix 4 and 5). Each is 2/2 in each order that reaches its branch, by value:
       - C-2 (c) forced true is reached only by `purgeRemovesInAscendingTokenOrder`;
       - C-3's group filter is killed by a new `.all` test, in both orders, with a `.prefetch` group, a `.userInitiated` prefetch group and an `ensureAvailable` group pending on distinct contents, and by a new model-test variant that purges `.all`. The existing model test stays (G3);
       - the rebuild filter's mutants are listed and killed.
   - **The in-letter shapes with no gated case** (S3-R27 12.1; f3 §3.6, review must-fix 3). Each becomes a BenchSync case, gated as 12.3 gates its cases: its heartbeat, best of 3, with loads, with the purge's synchronous turn beside it, and its 'before' figure from step 0. One that misses on `9aa337c` is committed red right before stage A's first part.
     - `keptUnderThreeGroups`: a user waiter on each of 10,000 ids plus three prefetch groups. Estimated 38-48 ms today, and 34-39 ms after route C.
     - `fourGroupJoins`: 40,000 joins waiting for the follow. Estimated 15-22 ms.
     - The mixed-lane shape: two prefetch groups over the same 10,000 ids, each id with its own content, the first registered at `.prefetch` and the second at `.bulk`. Estimated 24-33 ms after route C without option (i).
     - The pending-claims shape: two prefetch groups over the same 10,000 ids, the second registered just before the purge. Estimated 16-18 ms after route C without option (i).
   - **The decision rule** is S3-R27 item 1's: at or below 8.5 ms closes a case; 8.5 to 10 ms is recorded "at the edge" and is not blocking; a miss is blocking.
     - Measure every purge case after each stage: 12.3's twelve and the four above, best of 3, with loads.
     - The next stage runs only if a case is above 8.5 ms. A trigger without a quiet load follows S3-R27 item 10's rule for deciding figures.
     - A miss after stage C is blocking, with no route in cycle 23. Report it with its parts' figures and loads.
     - S3-R27 12.5.12's rule for red cases across part commits applies to route C's parts, and to every cycle-23 commit before them, for the purge cases only.
   - **e2-B′ is not authorised** (f3 §4). The fixer does not build it.
   - **Records** (f3 "must say" 12): item 9's rows for C-1's pass, C-3's pass, the rebuild and the freeing slices, in place of 12.5.17's rows for the parts they replace; RE-S24's text, as 12.3 says; 12.5.15's audit, extended to the walk (f3 §3.3) and to C-3's mid-turn state (should-fix 9).
   - **Fixer hours** (estimates, f3 §5): stage A 12-18 h, stage B 3-4 h and stage C 4-6 h, 19-28 h in all. Option (i) and the four new cases are not in them.

4. *S3-R27's unfinished work* (correct #5 to #7, reqs #2 to #6). S3-R27's routes and rules stand. In S3-R27's order:
   - **S3-R27's step 5 (cycle 23's step 4): item 3, the APM answer turn** (correct #5). PROBE-C21-APM, rebuilt on `9aa337c` and run in release with `-enable-testing`, in-actor, best of 3, at a 1-minute load of 9.85 to 8.65: group 9.37 ms (at the edge), groups 11.10 ms and users 13.93 ms (misses). A3 and A3′ landed in e2-A1.6 (`332b6cc`), so sub-step 4 reuses them.
   - **S3-R27's step 6 (step 5): item 4,** the k = 2 and k = 4 in-letter shapes, with A1 and A2 if taken (reqs #2). Correct #9 calls them unmeasured, so unproven.
   - **S3-R27's step 7 (step 6): the kills.**
     - Item 5's remaining kills, d4 review's steps 6 to 12: b22-no-waiter-owner, p7 with r5, r8, vy, r2c, b22-no-run-owner and r2b. b22's owner checks are now `EngineFailures.swift:858-859` and `:866-868`, still at 0 hits (correct #7).
     - The 429 probe: item 5's default-tuning probe.
     - e1-R1's rewritten mutants (12.5.6), with 12.2's kill table.
     - The kills of the e1-PS, e1-P1 and e1-P2 fixes (12.5.4). A mutant whose code item 1 or item 1b rewrites is rewritten for that code and run there, as 12.5.6 does for e1-R1. So e1-P1's four (`s3f.md:7147-7149`) become B3's two, B2, and the publication end's write dropped.
     - Item 1's and item 3's mutant runs. Their tests land with their parts.
     - What reqs #3 already ran is evidence, not kills of record. `v-e1r1-no-enoent-record`, `v-e1r1-kept-returns-nil` and `v-e1ps-no-supersede-record` failed 2/2. `v-e1p1-rule-false` failed its one run (12 issues), but in one test only by its 180 s time limit, which is no kill (S3-R27 item 5). That test, e1-P1's other side, gets an assertion on an answer or a clause that fails first. The specs are `s3f-probes-c22/reqs/tools/mutants22.py` and `mutants22b.py`.
   - **The two unreached lines** (correct #6, reqs #4): `EngineCommands.swift:1004` and `:1009`, the purge predicate's answer for an id that the applied copy does not list, under `.evictable` and under `.scope`.
     - Each is reached by a test that kills its drop-mutant 2/2, or removed with the reason recorded. C-4 rewrites both arms, so this applies at their new lines, in step 6.
     - The state is reqs #4's: a purge of `.scope` and one of `.evictable` while a job, a waiting join or an owed re-route holds a non-user interest in an id that an apply delisted while a follow is owed.
   - **S3-R27's step 8 (step 7): every record still missing** (reqs #5 and #6):
     - reqs #6's 11.6 record. List under "Authorised edits outside WP-F" the eight bench files (`BenchSyncCycle21.swift`, `BenchSyncJoinChains.swift`, `BenchSyncReroutePins.swift`, `BenchSyncRerouteTakeOff.swift`, `BenchSyncReroutes.swift`, `BenchSyncWaitersBound.swift`, `BenchSyncCycle22.swift` and `BenchSyncCycle22Purge.swift`) and any that cycle 23 adds, citing 11.6. Correct `s3f.md:8213` and `:8237-8238`, add the ARCHITECTURE §1.2 proposal (S3-R6), and point row `:6959` at the record;
     - item 9's rows, items 7 and 8, and the "Proposed document changes" of cycles 21 to 23 (reqs #5; cycle 21's reqs #9, #10, #11 and #14);
     - the 12.x records: 12.2's, 12.3's, 12.5.9's and 12.5.18's, found by content where their lines moved.
   - **Item 9** applies on the final HEAD, with `9aa337c` in place of `d5b2ab9`. The cycle-22 dispositions ("Not reached and structural lines (cycle 22)", `s3f.md:7758-7788`) stay listed, updated where cycle 23 changes them.

5. *Order of work.* Commit each step on its own. Red first: S3-R27 item 10's red-first rules apply, with `9aa337c` in place of `d5b2ab9`. A named finding goes with its item.
   0. Run `verify.sh --quick` on `9aa337c`. Run item 1's step-0 shapes on `9aa337c`. In a scratch copy of `9aa337c`, take the 'before' figures, best of 3 with loads, of item 3's four new cases and of S3-R27 items 3's and 4's cases. The twelve purge cases' 'before' figures are cycle 22's (item 3).
   1. Item 1's replay half: the red shapes it fixes, in one failing commit, then the fix, with its tests, the bound test's change and the controls. Then item 2: R1, then A-T-SD's change on its own commit.
   2. Item 3, stage A: the red cases' commit, then each part, then every purge case's figures.
   3. Item 3, stage B and then stage C, each only if triggered, each followed by every purge case's figures.
   4. S3-R27's step 5: its item 3 (item 4 above).
   5. S3-R27's step 6: its item 4.
   6. S3-R27's step 7: the kills, and the two unreached lines.
   7. S3-R27's step 8: the records, then the close.
   - **Item 1b** is taken at the first step that starts after it is appended: its red shapes first, then its route.
   - **The close** (step 7): item 9 and every gate on the final HEAD. Run `verify.sh --full` and quote its last line. A FAIL whose only cause is P-13 (WP-B's; S3-R26 item 10) is reported as such (12.1), and each of its other stages also runs and passes on its own.

6. *The budget.*
   - A fixer run may end at its working budget. The next run continues from HEAD. So commit every step when it is done, and keep the draft's cycle-23 status list current, with item 7's mapping.
   - Every agent keeps its command output short: it sends the output to a log file and reads the summary lines back.
   - The verifiers run lens 3's heavy checks first (reqs #7): Sync ×3, TSan, the iOS generic build and the iOS Simulator suite, the benchmarks and the mutants. Then the rest.
     - `sim.lock` is held for the simulator and coverage runs, and the release benchmarks run in a window with a 1-minute load of 10 or less.
     - These runs also re-measure the cycle-22 "closes" figures that reqs #7 left unproven (cycle 21's reqs #2 to #4: `commitTurns(.waitersStalledSubscriber)`, `commitTurns(.manyGroups)` and `purgeWhileOwedTurns`).
   - **Fixer hours** (estimates): item 2, 2-3 h; item 3, 19-28 h; e1-R1's kills, 3.7-5.5 h of mutant runs (12.2). f1's 12-18 h (16-24 h by its review) cover f1's whole route, not the replay half alone. A cut-off inside the cycle is likely.

7. *The named findings.* The draft's cycle-23 status list keeps this mapping:
   - correct #1 and #2 → item 1;
   - correct #3 → item 2;
   - correct #4 and reqs #1 → item 3;
   - correct #5 and reqs #2 → item 4 (S3-R27's steps 5 and 6);
   - correct #6 and #7, and reqs #3 and #4 → item 4 (S3-R27's step 7, and the two unreached lines);
   - reqs #5 and #6 → item 4 (the records);
   - reqs #7 → item 6.

## For the orchestrator (not part of the ruling)

1. **f1 review must-fix 4 (the stamp's lifetime)** is not in "must add" 1, but it binds as a must-fix item under the header rule, so the text applies it to the stamp. The count keeps `transferSpaceEnd`'s writer and lifetime, so that joins keep today's dating (decision 1). Moved whole into f1's record, the count would be written at both ends (f1 §3 step 1) and cleared at the verdict (must-fix 4). Either would change the visit branch after a verdict (`EngineJobs.swift:291`). The deferral's clear may be unobservable: `relane`, `metInItsAttempt`'s only caller, skips it while a verdict has deferred (`EngineJobs.swift:327`), and the replay clears `attemptEnd` (`EngineFollow.swift:392`, `:902`). If no test kills its drop, the text's S3-R16 1(e) arm removes it, which departs from must-fix 4; classing the drop Equivalent (S3-R19 item 2) would keep it.
2. **The named should-fix items** are the writer's choice, since the decisions name none: those that correct a ruled route's parts. The others stay advisory: f1 review's C2, baseline, hours and `spaceEnd.publication` items; f2 review's 4, 5 and 7; f3 review's 2, 3 and 7.
3. **"Does not change the dating of joins"** is read as "beyond clause (b)", which decision 1 rules now and which dates the joins made while `bringingInbound`. Clause (b) needs `relane` to tell a join from a removal, a small part of f1 §3 step 2. The same reading keeps f1's clause (a) for item 1b, since it changes the visit branch.
4. **B9's killer.** f1 names T-F10, which assumes (c). Under the replay half, (b)'s drop falls to today's count, which passes T-F10 (no apply in the read). T-F7 should kill it (red on `9aa337c` by code reading). The text lets the run decide.
5. **The order against f1** (f2 review "must add" 1). The review asks that A-T-SD's change land before f1's rewrite of `metInItsAttempt`. Decision 5 puts item 2 after the replay half, and the text keeps that order, since by code reading the replay half leaves T20 for a timeout end unchanged. The review's re-run of A-T-SD on f1's last commit is not carried; item 1b could carry it.
6. **f3 review must-fix 3** offers option (i) or option (ii). (ii)'s route is e2-B′, which decision 3 does not authorise, so the text takes (i), inside C-2. If the orchestrator prefers (ii) with no route, strike that bullet; the shapes stay gated either way.
7. **"The in-letter shapes f3 names as ungated"** is read as f3's two plus must-fix 3's two, since a must-fix binds. The review's "must add" 1 adds a fifth (40,000 one-member prefetch groups, four on each id; estimated 8-16 ms after route C), which the text does not carry.
8. **The stage trigger** (f3 review should-fix 7, not named). `keptUnderThreeGroups` and `fourGroupJoins` are estimated above 8.5 ms after every stage (34-39 and 15-22 ms), so they will trigger stages B and C, which do not reach them.
9. **f3 review "must add" 6** asks one question before `keptUnderThreeGroups` is routed: may the `.queued` arm's re-queue of a kept user job go (S3-R16 item 3)? If so, a one-turn route may exist (estimated 6.5-12.5 ms, unmeasured).
10. **12.5.16.** f3 "must say" 6 retires it, and decision 3 keeps it. Once C-4 removes the entry copy, 12.5.16's two conditions cannot be met, so a `.scope` miss after C-4 is WP-F's.
11. **12.5.12, extended.** The six purge cases are red on `9aa337c`, so the Benchmarks stage stays red at every commit until route C closes them. The text extends 12.5.12 to those commits.
12. **Step 0's 'before' figures** include S3-R27 items 3's and 4's cases, as S3-R27 item 10's step 0 asked. Cycle 22 took them at the start of their steps instead (`s3f.md:6917-6918`). The orchestrator may allow that again if step 0 is too heavy.
13. **The mutant runs' place.** Item 1's and item 3's mutant runs are placed at step 6, as S3-R27 12.4 placed e1-R1's and e2's, so that the C2 work comes first. Their tests land with their parts.
14. **The mapping, checked against the findings file.**
    - Correct #6 also names `EngineCommands.swift:1001`, the `.all` arm. Its text is unchanged, and it has had 0 hits since e2-A1.5's fast path. Item 4 covers `:1004` and `:1009` only, so under the named-finding rule `:1001` would close unaddressed. It needs a ruling: a test, correct #6's constant predicate for `.all`, or a structural record.
    - Correct #5 is S3-R27's step 5 only; reqs #2 spans steps 5 and 6. Correct #7's owner checks fit S3-R27's step 7 (b22; S3-R27 item 6). Every other row fits.
    - The non-blocking findings are not mapped: correct #8 (P-13, WP-B's), #9 (item 4's shapes) and #10 (unprobed residuals); reqs #8 (`SubscriberQueueBatchTests.swift:95` has no `.timeLimit`, which `SPEC.md:331` asks of anything that awaits), #9 (11.6's "only SyncBenchmarks and SyncBench extensions" against the files' helper types: nest them, or amend 11.6), #10 (stale records: 12.5.18's and `s3f.md:7367`, in step 7) and #11 (`commitTwoTokensTurns` at 9.02 ms, on the margin list).
15. **Not read:** `f1b-join-rule.md` is already in the analysis folder. It is not a source of this ruling.
