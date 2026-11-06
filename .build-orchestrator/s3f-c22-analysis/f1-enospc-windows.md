# f1: the ENOSPC windows (cycle 22 correct #1 and correct #2)

Read-only analysis for S3-R28. Code at `.worktrees/s3f` `9aa337c` (`wp/s3f`); every `path:line` is at that commit.
Nothing was built, run or measured here. Every red/green status not marked "measured" is from code reading
(UNCONFIRMED), and every cost is an estimate with its basis (CLAUDE.md G2). "Measured" means the verifier's logs in
`s3f-probes-c22/` or the draft's cycle-22 records.

Sources: `s3f-c22-issues.json` correct #1 and #2; `s3-rulings-s3f.md` S3-R16 (:144-184), S3-R22 item 2 (:285-287),
S3-R27 12.2 (:1068-1137) and 12.5 (:1232-1276); commits 94aa4b5, b83112c, 9005651, 58e2c1c, f7c993f, 75b9e45;
`docs/adr-drafts/s3f.md:7108-7187` (e1-P1, e1-P2 and the fixer's two residuals) and `:4378-4389` (RR-18);
`s3f-probes-c22/VerifyC22CorrectProbes.swift:207-488` and its two summary logs; `s3f-c21-analysis/e1-pin-requeue.md`.

## 1. The root cause, common to the four cases

**The question.** While a job J is `failed(.nextRun)` at an ENOSPC end, before its verdict defers or is given, a
re-lane of J (a join or a removal) while J's lane is user-initiated re-queues it (T20, `EngineJobs.swift:360-364`), and `decideSpaceFailure` then gives no
verdict (`EngineFailures.swift:592-596`). The guard (`EngineJobs.swift:327`, `metInItsAttempt` at `:289-297`) asks
whether the input behind the re-lane met J's attempt on a visit-first engine. If it did, it did nothing (J was
downloading or publishing). If not, it met J failed and re-queued it. The two ENOSPC ends are the only ends that leave
J `failed` with a re-queueable disposition across an await: the transfer's (`EngineFailures.swift:196-212`: the resume
point's read and the free-space read) and the publication's (`EngineDispatch.swift:1298-1301`, then
`EngineFailures.swift:569`). An integrity end is `.untilEntryChanges` (`EngineFailures.swift:490`), which T20 excludes.

**How each input is dated at 9aa337c:**

| Dating | Where | Clock | Right? |
|---|---|---|---|
| D1. A follow's join: own visit, visit rest, owed inbound move (`continueInbound` sets `inFollowVisit`, `EngineFollow.swift:1524-1525`), visit after a verdict (75b9e45) | `EngineJobs.swift:290-291` | `appliesFollowed` now == `attemptEnd.failedAfter ?? transferSpaceEnd` | **No** for a join onto J: it dates the join by the *latest* apply |
| D2. The drain's replay: a request, a withdrawal, a pinned batch, a chain | `EngineJobs.swift:293-296` | the event's `reading.serial` <= `attemptEnd.stamped` (`b83112c`, `58e2c1c`) | **Yes**, but written only by `recordPublicationEnd` (`EngineFollow.swift:529-532`). The transfer's end writes only the count (`EngineFailures.swift:201-202`) |
| D3. The visit of J itself (pass or move) | `rerouteOnVisit`, `EngineFollow.swift:1164`, `:1169` | the count now | **Yes** (see below) |
| D4. Moved ids at a deferral | `recordDeferredVerdict`, `EngineFollow.swift:556` | the count now | Yes (the same side as D3) |
| D5. A join onto a job whose verdict waits | `joinWaitsForVerdict`, `EngineJobs.swift:109-114` | per id: the copy at the deferral (`AttemptEnd.copy`), and `bringingInbound` | Yes. This is the per-id oracle that cycle 21 already uses |

**Why D3 is right and D1 is wrong.** A visit-first engine *passes* a publishing job: "A passed id puts the job in
`unfollowed`, for the next follow" (`EngineFollow.swift:1216-1233`, insert at `:1229`). `followApplied` revisits every
`unfollowed` job at each later apply (`:51-57`). So the job's own visit stands for the latest apply, and the count is
its date. A join onto J is different. A visit-first engine makes it once, at the visit of the apply that mapped that
id to J's content. A sweep-first visit owed since apply k keeps k's stamp (`:56-58`, `:1066-1068`) and moves, under
the copy as it stands, the ids of every apply since. So a join's date is **per id**. One visit can stand for applies on
both sides of the end.

**The root cause.** The guard dates a join by a clock that is not the join's own. That clock is either the count of
applies now (D1), which stands for the latest apply, or no record at all (D2 at a transfer's end). The join's own
instant is the visit-first input it stands for:
- for a replay, the event's arrival, which D2 already has;
- for a join a follow makes, the apply that mapped that id onto J.

All four cases are a missing or wrong instant in that one comparison:
- **e1-P1** (red on `b4eebb1`, measured): replays had no date. Fixed by D2.
- **e1-P2** (red on `58e2c1c`, measured): the visit after a verdict was left undated (`58e2c1c` excluded it with
  `!visitingAfterVerdict`), and its reading, the verdict's arrival, is not its instant. 75b9e45 dated it by D1, which has
  D1's flaw (W4 below).
- **correct #1** (PROBE-C22C-TS-DRAIN-JOIN, measured 2/2): V's join was deferred before T's transfer ENOSPC
  (`c22Join`, probe `:232-245`) and replayed inside the held read. At the transfer's end `attemptEnd` is nil, so D2
  returns false (`:293-294`) and T20 re-queues T: epoch 7, two starts, every answer `ok`. Visit-first: every answer
  `insufficientSpace`, one start.
- **correct #2** (PROBE-C22C-APPLY-IN-READ, measured 2/2): H's visit is owed since v3, before T's publication's end
  (`failedAfter` 3). v4 is applied inside the read and changes only fillers. The visit then joins zz-x onto T, D1
  compares 4 with 3, and T20 re-queues T. This proves the T20 consequence that RR-18's withdrawal
  (`s3f.md:4378-4389`) did not consider. That text reads only D3, which is right.

**The verifier's fix for correct #2 is wrong in both steps.** Its step 1 dates a visit by its `followStamps` instant.
That is the *oldest* apply the visit stands for, so it moves a later apply's join before the end (T-F3 below: green on
9aa337c, red under step 1, by code reading). Its step 2 makes the same change in D3. That breaks revisit semantics: the
passed job is dated "publishing" where visit-first's revisit at the later apply moved its ids and re-queued it (W-PR
below: green on 9aa337c, red under step 2, by code reading).

## 2. Were e1-P1's and e1-P2's fixes the right shape?

- **e1-P1** (`b83112c`, `58e2c1c`): **right clock, wrong place.** It has the right parts:
  - the clock: one decision-instant serial (`EngineState.stampsMinted`, `:71`; minted in `worldStamp`,
    `EngineFollow.swift:296-297`; never reset);
  - the comparison: `<=`, with the bound tested by `userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict`;
  - the scope: every replay.

  The fault is where the record lives. `stamped` sits in `AttemptEnd`: it is written by every publication end, never
  by a transfer's end, and dropped at the deferral (`:564`). Keep the clock and the comparison. Move the record into one
  window record that both ENOSPC ends write.
- **e1-P2** (`75b9e45`): **right diagnosis, wrong replacement.** The verdict's arrival is not the date of the move.
  But D1 dates K's move by the latest apply, so an unrelated apply inside X's read re-queues X (W4, red by code
  reading). Replace D1 for joins with the per-id rule. e1-P2's two tests stay as controls.
- **Cycle 21's count** (S3-R26 item 5 (i)) for the follow's own visit has the same flaw (correct #2, W3, W5). It is
  right only while no apply has come since the end. Keep it for D3 and D4, and for removals at a publication's end
  (§3, B12).
- **One design replaces D1 for joins:** the end's copy, per id. This is D5's oracle, applied to the window before the
  deferral. It also needs a set of the ids moved away from J since the end, so that a later re-map is not read as
  "already there".

## 3. The route

**Steps** (S3-R16 item 3: one record replaces two):
1. **One window record.** Add `Job.spaceEnd: SpaceEnd?` with these fields:
   - `applies`: today's count;
   - `stamped`: `stampsMinted`;
   - `copy`: `state.applied`, an O(1) CoW retain;
   - `publication: Bool`;
   - `movedAway: Set<AssetID>`.

   Both ENOSPC ends write it in the end's own turn, before the first await:
   - the transfer's in place of `transferSpaceEnd = applies` (`EngineFailures.swift:199-202`);
   - the publication's in the `.fileSystem(.noSpace), .insufficientSpace` arm, before `spaceFailed`
     (`EngineDispatch.swift:1298-1301`; the same turn as `recordPublicationEnd`, `:1259`).

   It is cleared at the attempt's start, with the others (`EngineDispatch.swift:741-743`). Remove `Job.transferSpaceEnd`
   (`EngineState.swift:867`) and `AttemptEnd.stamped` (`EngineFollow.swift:2017-2022`): `metInItsAttempt` is their only
   reader (grep at 9aa337c). Keep `stampsMinted` and `WorldStamp.serial`.
2. **`relane` is told what re-lanes.** `addInterest`'s call (`EngineJobs.swift:196`) passes the id joined. The removal
   callers (`:435`, `EngineMoves.swift:357`, `EngineCommands.swift:1056`) pass the id removed where one exists, or none.
   `metInItsAttempt(job, joining:)` then decides:
   - (a) no `spaceEnd`: false. A publication end whose verdict was given at once re-queues on any later visit (T20), as
     `barrierSkipsTheBackoffForAVisitAfterAPublicationsEnd` asserts.
   - (b) a join while `bringingInbound`: true. The move was found while J published, so it stands for a join before the
     end (`bringInbound`'s doc, `EngineFollow.swift:1293-1316`).
   - (c) a join while `inFollowVisit || visitingAfterVerdict`: `copy` maps the id to J's content (`sameTransfer`) and
     the id is not in `movedAway`.
   - (d) a removal in a visit at a publication's end: `appliesFollowed == applies` (today's, as D3).
   - (e) a removal in a visit at a transfer's end: the end's `copy` already mapped the removed id elsewhere. This is
     W-TR's branch; take it only if T-F8 is red at step 0.
   - (f) otherwise, under a reading (the drain's replay): `reading.serial <= stamped`.
   - (g) else: false.
3. **The pass records moves away.** In `continueFollowScans`, take a changed id (`EngineFollow.swift:1058-1069`) whose
   previous transfer's job has a `spaceEnd`. Insert the id into that job's `movedAway`, in place. The pass already looks
   the job up at `:1063`, so read `spaceEnd` from that same lookup: one read per changed id, and no second `Job` copy.
4. **Unchanged:** `rerouteOnVisit` (`EngineFollow.swift:1154-1177`), `recordDeferredVerdict`, `joinWaitsForVerdict`,
   e1-R1's pin. Correct #2's fix steps 1 and 2 are not taken (§1).
5. **Docs:** update `metInItsAttempt`, `relane`'s comment (`EngineJobs.swift:328-357`, including "cycle 22's residual"),
   `Job` and `AttemptEnd`. The draft closes its residuals (1) and (2) (`s3f.md:7151-7158`).
   - One-to-one test change: the bound test's setup `#require` on `attemptEnd?.stamped`
     (`EngineFollowBarrierReroutePinSpaceTests.swift:105-107`) reads `spaceEnd?.stamped`. It is cycle 22's own test,
     so no `MIGRATION.md` entry is needed.

**Tests.** They go in a new `EngineFollowBarrierSpaceWindowTests.swift`, built from the verifiers' helpers:
`c22TransferSpaceDrainJoin`, probe `:255-342`, and `c22ApplyInRead`, `:384-466`. Those use `setUpHeldPublications(…,
metadata:)`, `applyHeld`, `holdPublication(of:)`, `releasing(except:)`, the `.rename`/`.verifying` noSpace `FaultRule`
and the interactive cap of 1.
- Every test runs in both orders and asserts visit-first's answers and T's start count.
- Step 0 runs every shape on 9aa337c in both orders, 2 rounds, and records red or green. The red ones go in one
  failing commit, then the fix.
- "VF" below means visit-first's answers.

| Test | Shape | VF | 9aa337c |
|---|---|---|---|
| T-F1a | correct #1 `beforeEnd` (seed 2_029_101) | A, X, V `insufficientSpace`; T starts 1 | red swept first (measured 2/2) |
| T-F1b | correct #1 `inRead` (2_029_201) | all `ok`; T starts 2 | green both (measured) |
| T-F2a | correct #2 (2_029_301) | A, X `insufficientSpace`; 1 start | red swept first (measured 2/2) |
| T-F2b | T-F2a, but v4 in the read is the apply that maps zz-x to T (v3 does not) | T20: all `ok`, 2 starts | green both |
| T-F3 | H holds zz-x (X) and zz-y (Y); v3 maps zz-x→T; v4 in the read maps zz-y→T | T20 at zz-y: all `ok`, 2 starts | green both; red under correct #2's step 1 |
| T-F4 | zz-x: v3 →T; v4 in the read →U; v5 in the read →T | T20 at v5: `ok`. U's request count is recorded, not asserted: visit-first may start U between v4 and v5 | green both; red with no `movedAway` |
| T-F5 (W3) | T-F1's shape with no V, and v4 (fillers) in the transfer's read | A, X `insufficientSpace`; 1 start | red swept first |
| T-F6 (W4) | `afterVerdictSpaceRead(.beforeEnd)` with v4 (fillers) in X's read | Vx, Vy `insufficientSpace` | red swept first |
| T-F7 (W5) | `barrierGivesAnENOSPCsVerdictAtTheCap…InItsRead(walked: true)` with v4 in the read | A, X `insufficientSpace` | red swept first |
| T-F8 (W-TR) | transfer's end; T holds zz-a (A) and zz-b (B); v3 maps zz-b→U while T downloads; v4 in the read | A `insufficientSpace`, B U's bytes; T starts 1 | red swept first |
| T-F9 | W-withdrawal: one of two user waiters on T withdrawn before the transfer's ENOSPC, replayed in its read | A `insufficientSpace` | red swept first: `withdraw` defers it (`EngineCommands.swift:179-181`) and its replay re-lanes T (`EngineFollow.swift:1024-1030`) |
| T-F10 | walked, and v3b maps zz-x on to U; T's ENOSPC; no apply in the read | X `insufficientSpace` (passed at v3b) | green both; red with no clause (b) |
| W-PR | publication's end; T holds zz-a (A) and zz-b (B); v3 maps zz-b→U while T publishes; v4 in the read | T20 at v4's revisit: A `ok`, B U's bytes | green both; red under correct #2's step 2 |

Serving: following S3-R27 12.2's "Serving", each shape serves every content a mutant can request, and asserts which
contents were requested.

The controls stay green in both orders:
- e1-P1's three tests and e1-P2's two;
- the two `…InItsRead` tests, three cases (`walked` false and true, and the transfer's), and
  `barrierSkipsTheBackoffForAVisitAfterAPublicationsEnd`
  (`EngineFollowBarrierSpaceReadTests.swift:35`, `:121`, `:189`);
- the later-verdict test (ten cases; the draft's control list, `s3f.md:7180-7182`);
- the Sync bundle.

**Branches and kills.** Each kill is 2/2 in each order that reaches the branch, after a green unmutated run in both
orders. Each is killed by an answer, never by a time limit.

| Branch | Mutant | Killed by |
|---|---|---|
| B1: the transfer's end writes `spaceEnd` | dropped | T-F1a |
| B2: (f)'s `<=` | `<` | e1-P1's bound test |
| B3: (f) | forced false / forced true | `pinSpaceRead`, T-F1a / T-F1b, `userJoinFromInsideAnENOSPCsReadSkipsItsVerdict` |
| B4: (c) | forced true | T-F2b, e1-P2's `inRead` |
| B5: (c) | forced false | T-F2a, `barrierGivesAnENOSPCsVerdictAtTheCap…InItsRead` (unwalked), its transfer twin |
| B6: (c) | the visit's reading (correct #2's step 1) | T-F3 |
| B7: (c) | the count (9aa337c's D1) | T-F2a, T-F5, T-F6 |
| B8: `movedAway`'s insert | dropped | T-F4 |
| B9: (b) | dropped (falls to (c)) | T-F10 |
| B10: (a) | no `spaceEnd` read as met (true) | `barrierSkipsTheBackoff…` (X then waits out the backoff) |
| B11: the clear at the start | dropped | a test where a second attempt ends with an I/O retry and a later visit joins an id the first end's copy mapped. Otherwise Equivalent, with the argument (S3-R19 item 2) |
| B12: (d) | the visit's reading | W-PR |
| B13: (e), if taken | the count | T-F8 |

**Other windows that may share the cause**, each with the probe that settles it:
1. **W3:** a transfer's end with an apply inside its reads, and the follow's visit dated by D1. Settled by T-F5.
2. **W4:** e1-P2 with an unrelated apply inside X's read (75b9e45's count). Settled by T-F6.
3. **W5:** an inbound move found while T published, made after its end with an apply since (D1 via
   `continueInbound`). Settled by T-F7.
4. **W-TR:** a removal from a downloading job's visit, made after its transfer's end, with an apply since. The job is
   moved, not passed, so D1's count misdates it. Settled by T-F8.
5. **W-withdrawal:** correct #1's twin for a removal replay. Settled by T-F9; fixed by B1 if it is red.
6. **W-PR:** the publication end's removal. Green by revisit semantics; W-PR pins it.
7. **W-lazy:** a pass that runs past later applies (over 2,048 changed ids, `followFormatsPerTurn`,
   `EngineFollow.swift:20`; or over 16,384 entries). Visits keep running while it is owed (`:115`, `:123`), so an
   away-and-back can be missed, which is `movedAway`'s residual. Settled by T-F4 at 2,049 changed ids. If no shape
   reaches it, record it (S3-R26 item 7's rule).
8. **The deferred window's away-and-back:** D5 for a join made after the deferral, with the id mapped away and back
   since. Settled by e1-P2's shape with K2 (away) and K3 (back) after the deferral, both orders.
9. **Take-off re-routes onto a job in its window,** dated by the verdict's arrival
   (`takeOffMovedBefore`/`landTakeOff`). Visit-first re-routed them at its verdict, so this is consistent by code
   reading. Settled by one probe with a take-off onto a job in its read.
10. **Unlisted ids** (a waiter joined from the store's newer manifest, `EngineManifest.join`): (c) assumes that the end's
    copy names where visit-first held the id. Settled by an unlisted waiter's id mapped to T at the end, both orders;
    otherwise record it.
11. **Not a window:** the integrity end (`.untilEntryChanges`; T20 excluded, `EngineJobs.swift:360`). Other publication
    failures give their verdict at once or defer it, and transient transfer failures await while `.downloading`
    (`EngineFailures.swift:107-118`, `:126-133`).

## 4. C2 impact and fixer hours (estimates)

- **C2** (estimate, from operation counts; not measured):
  - An ENOSPC end turn gains one struct write and a few CoW retains: under 1 µs.
  - A join onto a job in its window gains one `entry(for:)` (O(1), `ValidatedManifest.swift:78`) and one set lookup:
    under 1 µs. Such joins are rare.
  - A pass turn gains one field read per changed id on a lookup it already makes: at most 2,048 a turn × ~10-20 ns,
    under 0.05 ms. Set inserts happen only for ids that leave a job in its window.
  - No new BenchSync case. Re-measure these as controls, best of 3 at a quiet load: `sharedApplyTurns` (6.82 ms best,
    `s3f.md:10350`), `concentrationFollowTurns`, `publicationApplyTurns`.
  - If the pass's test takes a second `Job` read through the table's getter (a copy), the cost rises to ~0.1-0.2 ms a
    turn (estimate) and must be measured.
  - Unlike `bringInbound` at the end (`inboundWalkTurns` 3.3-3.7 ms at 10,000, `s3f.md:10455`), this route adds no
    walk.
- **Fixer hours: about 12-18 h** (estimate). The basis:
  - e1-P1 and e1-P2's red tests and fixes took 01:13 to 01:56 (measured from the commit times), without kills;
  - a Sync bundle run takes 352-357 s (measured, `s3f.md:7147`, `:7183`);
  - the e1 review's 3-5 h per probe set, and S3-R27 12.5.20's +1 h.

  The split:
  - step 0 and the shapes: 3-4 h;
  - the core: 2-3 h;
  - B13: 1-2 h;
  - 13 branches (about 14 mutants) × 2 orders: 3-5 h;
  - gates and BenchSync controls: 2-3 h;
  - records: 1 h.

## What the ruling must say

1. Correct #1 and correct #2 are blocking (S3-R16 1(a)). Both have one cause: the T20 guard dates a join by the count
   of applies now, or by nothing at a transfer's end, instead of by the visit-first input that the join stands for.
2. Replays keep e1-P1's clock and comparison (`reading.serial <= stamped`). The record moves to one `Job.spaceEnd`,
   written by both ENOSPC ends in the end's turn. `transferSpaceEnd` and `AttemptEnd.stamped` are removed.
3. A join made by a follow's visit, a visit's rest or the visit after a verdict is met in the attempt only if the
   end's copy mapped that id to the job and no pass has since moved it away (`movedAway`). This replaces 75b9e45's and
   cycle 21's count for joins.
4. A join brought in by `continueInbound` is met. A removal at a publication's end keeps the count. `rerouteOnVisit`
   and `recordDeferredVerdict` do not change, because a visit-first engine revisits a passed job at every apply.
5. Correct #2's proposed fix is rejected as written. Step 1 (the visit's stamp) breaks T-F3 and step 2 (the stamp in
   `rerouteOnVisit`) breaks W-PR, both green on 9aa337c by code reading.
6. Step 0 runs T-F1a to T-F10 and W-PR on 9aa337c in both orders, 2 rounds, and records each as red or green
   (measured). The red ones land in one failing commit before the fix (P3).
7. W3, W4, W5, W-TR and W-withdrawal are blocking only if their step-0 run is red. The route covers each one. B13 (a
   transfer end's removal dated by the end's copy) is taken only if T-F8 is red.
8. Every branch B1 to B13 that lands is killed 2/2, in each order that reaches it, by the test the table names. B11 may
   be ruled Equivalent instead, with its argument (S3-R19 item 2).
9. The controls stay green in both orders: e1-P1's three tests, e1-P2's two, the two `…InItsRead` tests
   (three cases), `barrierSkipsTheBackoffForAVisitAfterAPublicationsEnd`, the later-verdict test and the Sync bundle.
10. C2: no new case. Re-measure `sharedApplyTurns`, `concentrationFollowTurns` and `publicationApplyTurns`, best of 3
    at a quiet load. The pass's added test reads `spaceEnd` from the lookup it already makes.
11. W-lazy, the deferred window's away-and-back, take-offs and unlisted ids are probed if a shape reaches them.
    Otherwise they are recorded as residual risks with the attempt (S3-R26 item 7's rule).
12. The draft closes its cycle-22 residuals (1) and (2), corrects RR-18's withdrawal (the T20 side), and records the
    one-to-one `#require` change in the bound test.
