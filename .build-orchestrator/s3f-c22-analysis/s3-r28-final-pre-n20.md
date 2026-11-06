## Orchestrator ruling added 2026-11-06 (cycle 22's verification; written before the cycle-23 fixer starts)

**S3-R28.** Cycle 22 implemented S3-R27 in part (`d5b2ab9..9aa337c`, 44 commits; the last production commit is `2abddd1`, e2-A2.5): steps 0 to 3, step 4 up to e2-A2.5, e2's kills, and step 8's gates and re-measures (`s3f.md:6910-6947`). Its verifiers left 14 blocking findings, 7 in each lens, and S3-R27's steps 5 to 8 are unfinished. This ruling routes them. Cycle 23 starts as run 10, and its fixer may take several runs (item 6).

**S3-R28 is cycle 23's ruling.** S3-R16 to S3-R27 apply wherever S3-R28 does not change them. Where S3-R28 differs from an earlier ruling, from a specification or from an analysis, S3-R28 decides. The cycle-23 verifiers judge by S3-R16 to S3-R28. Item 1b and item 3b, once appended (items 1 and 3), bind the cycle-23 verifiers for the work of every step that started after they were appended. The draft's status list records when each was taken (item 6).

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
    - f2 review: should-fix 1, 2, 3, 4, 6, 8 and 9;
    - f3 review: should-fix 1, 3, 4, 5, 6, 8 and 9.

    A review's "What the ruling must add", a report's recommendation, every other should-fix item and every "optional" bind only as this ruling carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.
  - Below, "must add" n is a review's "What the ruling must add" n, and "must say" n is a report's "What the ruling must say" n.
  - Their line numbers are at `9aa337c`; re-cite them after a change. Their figures not marked "measured" are estimates, from code reading and from the draft's and the verifiers' measurements. A measurement decides.
- **Names** (S3-R27 12's names rule still applies). R1 already means S3-R11's, `integrate-rr21.md`'s and S3-R27 item 3's, and B1 and B2 are S3-R27 item 3's too, which step 4 runs in this cycle. So, in this ruling and in the draft's records:
  - f1's branches are f1-B1 to f1-B13, and f2's R1 to R3 (its probe, its fix and its check) are f2-R1 to f2-R3;
  - f1's clauses keep their names, clause (a) to clause (g), and f3's conditions on C-2 are C-2 (a) to C-2 (d);
  - T-F1a to T-F10, the W- shapes, C-1 to C-5 and stages A to C keep their names.
- **Cycle 22's scratch evidence:** the verifiers' probes, logs and tools in `.build-orchestrator/s3f-probes-c22/` (`VerifyC22CorrectProbes.swift`, `reqs/tools/`), and the fixer's `.worktrees/s3f/.build-s3f/c22/` (the scratch copy `snap0`, `tools/`). Do not delete them. Cycle 23's scratch files go under `.build-s3f/c23/`. Its rewritten mutants go in its own copies under `.build-s3f/c23/tools/`, and `.build-s3f/c22/` stays as cycle 22 left it, as 12.5.6 left `.build-s3f/c21/` (rulings :1243).

**How a C2 figure is read in cycle 23.** S3-R27's rule ("How a C2 figure is read in cycle 22") applies to every C2 case that cycle 23 measures. The bar is the owner's (S3-R27 12.1): `c2Budget`, 10 ms, over 10,000 ids however grouped, with at most 4 interests on one id and one subscriber, which may be stalled. 8.5 ms decides only the routes that name it, and the margin list (S3-R27 item 9; rulings :764).

1. *Correct #1 and #2: the ENOSPC windows.* Blocking (S3-R16 1(a)). Both are measured 2/2, red swept first (`s3f-probes-c22/correct-probeC22TransferSpaceDrainJoin.summary.log`, `correct-probeC22ApplyInRead.summary.log`).
   - **Correct #1** (PROBE-C22C-TS-DRAIN-JOIN, seed 2_029_101). A user request made before T's transfer ENOSPC is replayed inside the free-space read and meets no stamp (`EngineJobs.swift:293-294`), so T20 re-queues T (`:360-364`). Visit-first answers A, X and V `insufficientSpace` and starts T once. Swept first, all three get `ok(100000 B)` and T starts twice. With V made inside the read (seed 2_029_201), both orders give `ok` and 2 starts.
   - **Correct #2** (PROBE-C22C-APPLY-IN-READ, seed 2_029_301). v4, applied inside a publication's free-space read, makes the visit branch (`:290-291`) date v3's move after the end, so T20 re-queues T. Visit-first answers A and X `insufficientSpace` with one start; swept first, `ok` with two.
   - **The causes are two** (f1 §1, as review must-fix 2 corrects it): a re-lane dated by the wrong clock, and a re-queue that visit-first makes and the swept-first engine never makes before the verdict.
   - **The replay half is ruled now** (f1 review "must add" 1):
     - one record on the job (f1's `Job.spaceEnd`). It holds two values with two lifetimes, and a clear of the stamp leaves the count:
       - the stamp, `stampsMinted` at the end. Both ENOSPC ends write it in the end's own turn, before the first await: the transfer's in place of `transferSpaceEnd = applies` (`EngineFailures.swift:198-205`), and the publication's in its ENOSPC arm (`EngineDispatch.swift:1298-1301`), in the turn of `recordPublicationEnd` (`:1259`). `transition` mints no stamp between them. It is cleared at the deferral, at the verdict and at the start (its lifetime, below);
       - the count, `transferSpaceEnd`'s, with that field's writer and lifetime ("Joins keep today's dating", below);
     - clause (f), `reading.serial <= stamped`, for replays only: outside a visit (`!inFollowVisit && !visitingAfterVerdict`; review must-fix 6);
     - `Job.transferSpaceEnd` (`EngineState.swift:867`) and `AttemptEnd.stamped` (`EngineFollow.swift:2017-2022`) removed. `metInItsAttempt` is their only reader (`EngineJobs.swift:291`, `:293`);
     - clause (b): a join made while `bringingInbound` is met (f1 §3 step 2 (b)). For this, `relane` is told a join from a removal (f1 §3 step 2). A removal made in a visit (`inFollowVisit` or `visitingAfterVerdict`, with `bringingInbound` included) keeps today's count, and a replayed removal is dated by clause (f) (review must-fix 6);
     - correct #2's proposed fix is rejected (f1 "must say" 5). Its step 1 breaks T-F3 and its step 2 breaks W-PR, both green on `9aa337c` by code reading.
   - **Clause (b) is not scoped** to a job that holds a stamp. A scope check that no test can tell apart would be a branch whose drop-mutant survives (S3-R16 1(e)). By code reading (UNCONFIRMED), clause (b) without clause (a) changes a re-lane only for a `.failed` job at its attempt's end whose verdict has not deferred:
     - `relane`'s `.failed` arm skips `metInItsAttempt` once `deferredAfter` is set (`EngineJobs.swift:327`);
     - an inbound move reaches only a job at its attempt's end (`continueInbound`'s doc, `EngineFollow.swift:1502-1518`; `waitingTarget`, `:1579-1601`), and a failed job only with its publication's end recorded (`:1596-1597`);
     - a publication that ends while a move is owed defers its verdict in the end's own turn (`followOwed` includes `inboundOwed`, `EngineFollow.swift:82-90`; `defersToFollow`, `:103-105`). The exceptions are the ENOSPC end, whose verdict waits for its read, and the integrity end, whose reads come first but where T20 does not apply (`.untilEntryChanges`, `EngineJobs.swift:360`).

     So it changes nothing outside an ENOSPC end's read. The draft records this argument. A verifier who finds a shape outside that read where clause (b) changes an answer reports it under S3-R16 1(a).
   - **The stamp's lifetime** (review must-fix 4) runs from the end to the deferral or the verdict. The stamp is cleared in `recordDeferredVerdict` and in `decideSpaceFailure`, as well as at the attempt's start, with the whole record (`EngineDispatch.swift:741-743`). `decideSpaceFailure`'s clear comes first in the function, before its early returns (`EngineFailures.swift:587-596`), so that every path through it ends the stamp.
     - This is safe: both callers check the job's epoch before they call it. These are `spaceFailed`, after its read (`EngineFailures.swift:570`), and the drain's replay of `.spaceFailure` (`EngineFollow.swift:387`).
     - So the clear ends only the stamp of the attempt whose verdict it gives, never a later attempt's. A later attempt changes the epoch (`EngineDispatch.swift:705-706`).
     - `spaceFailed`'s f-4 note (`EngineFailures.swift:566-568`) names the stamp among what the epoch check re-validates (C3).
   - **Joins keep today's dating, apart from clause (b),** until item 1b.
     - The visit branch reads, in every state but clause (b)'s joins, the count it reads on `9aa337c` (`continueInbound` sets `inFollowVisit` with `bringingInbound`, `EngineFollow.swift:1524-1525`). `transferSpaceEnd`'s count moves into the record with its writer (the transfer's end only) and its lifetime (cleared only at the start).
     - f1's `copy`, `publication` and `movedAway` fields and its clauses (c) to (e) are item 1b's. So is its clause (a), which also changes the visit branch.
     - So correct #2 (T-F2a) stays blocking until item 1b. By code reading (UNCONFIRMED), the stamp fixes correct #1 and T-F9 (review, "What holds"), and clause (b) fixes T-F7 (f1 §3).
   - **Tests,** in f1's new `EngineFollowBarrierSpaceWindowTests.swift`:
     - T-F1a and T-F1b (correct #1's two sides), T-F9 (correct #1's twin, for a withdrawal), T-F7 and T-F10 (clause (b)), and T-F3 and W-PR, kept as tests of the rejection;
     - each runs in both orders and asserts visit-first's answers and T's start count. It serves every content a mutant can request and asserts which were requested, as S3-R27 12.2's "Serving" says;
     - they are built from the verifiers' helpers (`VerifyC22CorrectProbes.swift:255-342`, `:384-466`), changed to read the new record instead of `transferSpaceEnd` (`:251`, `:303`; review, "The probe helpers");
     - the bound test's setup `#require` (`EngineFollowBarrierReroutePinSpaceTests.swift:105-107`, in the helper `pinSpaceRead`) reads the record's stamp, one to one. The draft records its old and new text, as f1 "must say" 12 asks and as 12.2 did for rr21-T8b. The old text reads `$0.state.jobs[xT]?.attemptEnd?.stamped`. It is cycle 22's own test, so no `MIGRATION.md` entry is needed.
   - **Kills** (f1 §3's table, as its review corrects it). Each is 2/2 in each order that reaches its branch, after a green run of the unmutated code in both orders. A kill is by an answer, a start count or a clause, never by a hang or a time limit. Item 4 uses the same list for e1-P1's mutants:
     - f1-B1, the transfer's end's write dropped: T-F1a;
     - f1-B2, clause (f)'s `<=` as `<`: `userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict` (`EngineFollowBarrierReroutePinSpaceTests.swift:160`);
     - f1-B3, clause (f) forced false: `owedReroutePinnedToAJobInItsSpaceReadGetsItsVerdict` (`:147`), the bound test (`:160`) and T-F1a. Forced true: T-F1b and `userJoinFromInsideAnENOSPCsReadSkipsItsVerdict` (`:174`). `pinSpaceRead` (`:56`) is their helper, not a test;
     - the publication end's write dropped: `owedReroutePinnedToAJobInItsSpaceReadGetsItsVerdict` (`:147`), e1-P1's own test, as cycle 22 planned (`s3f.md:7148-7149`);
     - f1-B9, clause (b) dropped. Without clause (c) it falls to today's count, so T-F7 is its expected killer. The run decides, and the draft records the killing test in each order. If no test kills it 2/2, it is a survivor under S3-R16 1(e);
     - f1-B11, the record's clear at the start, is not Equivalent (review must-fix 4). Under the replay half, its kill needs a second attempt that ends without an ENOSPC (for example with an I/O retry) and then reads the first end's stale count in a visit (`EngineJobs.swift:291`) or its stale stamp in a replay (`:293`). f1's own test for it needs the first end's copy (f1:183), which is item 1b's, so the fixer does not wait for item 1b;
     - the stamp's two new clears, at the deferral and at the verdict: each is killed by a test where a test can observe its drop;
     - **a clear whose drop no test can observe** stays, as review must-fix 4 asks, and is killed on a clause: an `invariantViolations()` clause that the drop breaks, with a test that exercises it (S3-R19 item 3). Each clause reads state that `invariantViolations()` can see:
       - for the deferral's clear, the clause is "a job whose verdict has deferred (`attemptEnd?.deferredAfter != nil`) holds no stamp";
       - for the verdict's clear, the fixer either states such a clause or kills the clear by a test, and the draft records which. A job that T20 re-queued inside the read is `.queued` and still holds its stamp until the verdict (or the deferral), so "a queued job holds no stamp" is not a valid clause;
       - such a clear is not classed Equivalent: its drop changes state, not only cost (S3-R19 item 2). Its path is reachable, so it is not removed under S3-R16 1(e);
       - by code reading, the deferral's clear is one. While `deferredAfter` is set, `relane` skips `metInItsAttempt` (`EngineJobs.swift:327`). The verdict's replay clears `attemptEnd` and calls `decideSpaceFailure` in the same turn, with only `chargeTakeOff` between them (`EngineFollow.swift:392-394`). The draft records this argument beside the kill.
   - **The controls** stay green in both orders (f1 §3): e1-P1's three tests and e1-P2's two; the two `…InItsRead` tests in their three cases, and `barrierSkipsTheBackoffForAVisitAfterAPublicationsEnd` (`EngineFollowBarrierSpaceReadTests.swift:35`, `:121`, `:189`); the later-verdict test's ten cases (`s3f.md:7180-7182`); the Sync bundle.
   - **Step 0's shapes.** Run each on `9aa337c`, in both orders, 2 rounds each, and record it as red or green (measured):
     - f1's T-F1a to T-F10 and W-PR, with f1's T-F4 replaced by the corrected T-F4 below;
     - the review's W-HP and W-AWAY, each at the transfer's end and at the publication's (must-fix 1 and 2), W-DB (must-fix 2) and W-PD (must-fix 3);
     - T-F4, built as must-fix 5 corrects it (v4's pass reaches zz-x while v4's copy stands, and visit-first's T20 comes at v4), and its lazy twin, as a probe.

     Each red shape is blocking (S3-R16 1(a)). Its fix is the replay half or item 1b. A red shape that the replay half fixes is committed red in step 1, right before the fix. Any other red shape is committed red right before item 1b's fix, and is reported until then with its log. A red shape that neither the replay half nor item 1b routes is blocking with no route in cycle 23, and is reported with its log; W-DB is the likely case (review "must add" 2). Item 1b says, for each red shape, which route fixes it.

     A shape that still cannot be built after a real attempt follows S3-R26 item 7's B-T5 rule, as S3-R27 12.5.2 applies it to e1-PR (rulings :585, :1234). The draft records the attempt, why the shape cannot be built, and the residual risk. The shape is not blocking.
   - **Item 1b, the join rule** (f1's clauses (c) to (e)), is not ruled here. The orchestrator appends it between fixer runs, or between steps, after a re-analysis that is running now; the fixer takes it as item 6 says. Until it is appended, the fixer does not change the dating of joins beyond clause (b). Review must-fix 1, 3 and 5 bind now only through step 0's shapes, and must-fix 2 through them and through the two causes above.
   - **C2.** The replay half adds one O(1) write to each ENOSPC end's turn (f1 §4, estimate). No new case.
   - **Records:**
     - the docs of `metInItsAttempt` (`EngineJobs.swift:280-288`, above the function at `:289-297`), of `relane` (`:328-357`, "cycle 22's residual" included), of `Job` and of `AttemptEnd` (f1 §3 step 5), and every other comment that names `transferSpaceEnd` or `AttemptEnd.stamped` (for example `EngineState.swift:68`, `EngineFollow.swift:1976`, `EngineDispatch.swift:740` and `EngineFailures.swift:199`);
     - the draft closes its residual (1) (`s3f.md:7151-7155`). Residual (2) (`:7156-7158`) and RR-18's correction (f1 "must say" 12, with review must-fix 2's "directly" sentence, `s3f.md:4385`) wait for item 1b.

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
   - **The order.** Item 2 lands after item 1's replay half (item 5). The replay half leaves the visit branch unchanged, and a timeout end writes no stamp, so T20 still fires here by code reading.
     - f2 review "must add" 1's re-run is carried this way. A-T-SD's set-up check runs in every Sync bundle, so every later commit re-checks T20, item 1b's included.
     - The draft's status list records A-T-SD green, in both orders, with its set-up check, on the first commit that holds both the replay half and A-T-SD's change (A-T-SD's own, step 1) and on item 1b's last commit.
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
     - The kills of the e1-PS, e1-P1 and e1-P2 fixes (12.5.4). A mutant whose code item 1 or item 1b rewrites is rewritten for that code and run there, as 12.5.6 does for e1-R1. So e1-P1's four (`s3f.md:7147-7149`) become f1-B3's two, f1-B2, and the publication end's write dropped, each with item 1's killer.
     - Item 1's and item 3's mutant runs. Their tests land with their parts.
     - What reqs #3 already ran is evidence, not kills of record. `v-e1r1-no-enoent-record`, `v-e1r1-kept-returns-nil` and `v-e1ps-no-supersede-record` failed 2/2. `v-e1p1-rule-false` failed its one run (12 issues), but in one test only by its 180 s time limit, which is no kill (S3-R27 item 5). That test, e1-P1's other side, gets an assertion on an answer, a start count or a clause (item 1's list) that fails first. The specs are `s3f-probes-c22/reqs/tools/mutants22.py` and `mutants22b.py`.
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
   0. Run `verify.sh --quick` on `9aa337c`. Run item 1's step-0 shapes on `9aa337c`. In a scratch copy of `9aa337c` under `.build-s3f/c23/`, take the 'before' figures, best of 3 with loads, of item 3's five new cases. S3-R27 items 3's and 4's cases take theirs here or at the start of steps 4 and 5, on such a scratch copy either way. The twelve purge cases' 'before' figures are cycle 22's (item 3).
   1. Item 1's replay half: the red shapes it fixes, in one failing commit, then the fix, with its tests, the bound test's change and the controls. Then item 2: f2-R1, then A-T-SD's change on its own commit.
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
   - **Fixer hours** (estimates): item 2, 2-3 h; item 3, 19-28 h; e1-R1's kills, 3.7-5.5 h of mutant runs (12.2). f1's 12-18 h (16-24 h by its review) cover f1's whole route, not the replay half alone. A cut-off inside the cycle is likely.

7. *The named findings.* The draft's cycle-23 status list keeps this mapping:
   - correct #1 and #2 → item 1;
   - correct #3 → item 2;
   - correct #4 and reqs #1 → item 3;
   - correct #5 and reqs #2 → item 4 (S3-R27's steps 5 and 6);
   - correct #6 and #7, and reqs #3 and #4 → item 4 (S3-R27's step 7, and the three unreached lines, `:1001` included);
   - reqs #5 and #6 → item 4 (the records);
   - reqs #7 → item 6;
   - reqs #8 and #9 (not blocking) → item 4 (step 6's guard, and the ownership rule).
