# S3-R27 item 12: fidelity review

**Verdict: CORRECTED** (2 must-fix). With the two corrections below, the text carries D0 to D5. The should-fix items
are about precision and citations.

**Method.** Reading only. I checked the draft against e1 and e2 and their reviews, the code at `d5b2ab9`
(`.worktrees/s3f`, clean), `s3f-c21-issues.json`, the rulings it amends, and D0 to D5. I did not write the draft (P4).
I built, ran and measured nothing (G2). Line numbers ("line n") are the draft's.

## Must fix

### 1. 12.3, A1.4's test (line 118) leaves out the token order, so as written it can be red on the fix
- **Text.** "Its test: a claim-held job with a `.bulk` and a `.prefetch` interest ends with `heldLane == .prefetch`.
  The reversed-order mutant fails it 2/2 (e2 review "must add" 2)."
- **Evidence.**
  - How `heldLane` is set:
    - `settleRemoval` keeps `last`, the lane before the last removal, as `heldLane` (`EngineJobs.swift:390-396`);
    - a job's lane is the highest of its interests' lanes (`EngineState.swift:887-891`);
    - `.bulk` (0) is below `.prefetch` (1) (`ZTronAssetModel/Policy/AssetPriority.swift:9-11`);
    - tokens ascend in registration order (`nextToken()`, `EngineLifecycle.swift:85-88`).
  - e2 review must-fix 6, which binds under D0, builds the case with t1 from a `.bulk` group and t2 from a `.prefetch`
    group (`e2-purge-review.md:93-94`). Ascending removal then ends at `.prefetch`, and the reversed order at `.bulk`.
  - If the `.prefetch` interest is registered first, ascending removal ends at `.bulk`. The test is then red on
    `d5b2ab9` and on the fix, and green on the reversed-order mutant.
  - "Must add" 2 (`:176-178`), which D3 names, leaves the order out, and the text copies it.
- **Correction.** "Its test: a claim-held job whose `.bulk` interest is registered before its `.prefetch` interest
  (t1 < t2, as e2 review must-fix 6 builds it) ends with `heldLane == .prefetch`." This is still add 2's test (D3),
  with its construction made exact.

### 2. 12.4's step 1 (line 160) puts "all of" 12.2 before step 2, which contradicts its own steps 7 and 8
- **Text.** "**Step 1** also takes 12.2, all of it before item 6's `EngineFollow.swift` removal in step 2:"
- **Evidence.**
  - D4's step 1 "takes 12.2, all before item 6's EngineFollow.swift removal". It then lists three parts: the red
    T-E tests; R1 with rr21-T8b's change and T-E2 to T-E5; and the probes.
  - D4 puts R1's kills in step 7 and 12.2's records in step 8. The draft does the same (lines 170-171).
  - 12.2 also holds the kill table (lines 50-64) and the records (lines 84-86). So "all of it" contradicts lines 170
    and 171, and a verifier could cite line 160 against kills taken in step 7, after the removal.
- **Correction.** "**Step 1** also takes 12.2's tests, R1 and the probes, all before item 6's `EngineFollow.swift`
  removal in step 2 (R1's kills are in step 7, and 12.2's records in step 8):"

## Should fix

1. **Line 8.** Write "It includes item 4's list" instead of "That is item 4's list". Item 4 says "That includes:"
   (rulings :888), so the list is not complete, and the bar's rule is "more than 4 interests on one id".
2. **Line 77.** Answer 6.3's first bullet ends "rr21-T8 and rr21-T8b pin it" (rulings :681). Saying the bullet "holds
   for those two ends" keeps rr21-T8b as a pin for a class it has left. Say that rr21-T8, the commit pin
   (`integrate-rr21.md:403-406`), pins that bullet, and that rr21-T8b, once changed, pins R1's keep.
3. **Line 80.** Answer 8's second and third bullets (rulings :715-716) make rr21-T8b's kill item 5's "Reached"
   evidence in `followVisitedFirst` (e1 review M7). Say that T-E2, with any other killer the run shows, takes that
   role too. Add `s3f.md:5072` ("The arm is Reached in cycle 21 (Shape A …)") to the records; the drafter's item 3
   flags it.
4. **Line 69, P-3.** Give e1 §3's construction: "Shape A and rr21-T8b, with a conditions edge or a space sweep replayed
   between the re-queue and the move or the replay" (`e1-pin-requeue.md:213-214`). Give its last line too: "If it
   ever shows `.blocked`, that is the move's own finding" (:216). R1 makes the state moot for the pin (e1 "must say" 9).
5. **Line 103.** The case's own 1-minute load is 4.88; 5.23 is the mean over SyncBenchmarks (`s3f.md:6668-6670`). Write
   "10.04 ms in the fixer's second gate run, at a 1-minute load of 4.88 (mean 5.23 over SyncBenchmarks; a miss)".
6. **Line 111.** `purgeWhileOwedTurns` already exists (`BenchSyncReroutes.swift:68-74`; line 103 says so), so it has
   nothing to commit red. Say that an existing case only takes its 'before' figure in step 0, so that no fixer re-adds
   or alters it.
7. **Line 122.** A1.2 also changes the owed batch and the queue's `.join` events in place (line 116). Both arms call
   `isPurged` (arms at `EngineCommands.swift:1060` and `:1066`), which reads `self.state.applied` (`:994`). They also
   write `groups`, `heals` or `joinsAfterFollow` (`:1073`, `:1075`, `:1102-1110`), the overlap that e2 review
   must-fix 8 describes. Add both to the parenthetical, or write "for example". As written, the list can read as
   complete, though D3 says "every single-access step".
8. **Line 124.** "Only the order of the dropped ids and of the removed items changes" leaves out a second change:
   A1.4's single `settleRemoval` per job also cuts the turn's `notifyObservers` calls (`EngineJobs.swift:387`,
   `:406`). e2 §3's own "Equality with today" names that change (e2:211), and e2 review should-fix 5 repeats it. The
   ensure argument comes from e2 §3 A1.3 (e2:168) and from e2 review's "What holds" (`e2-purge-review.md:19`). It is
   not in "Equality with today", which has no such sentence.
9. **Line 162.** "then R1, with rr21-T8b's change and T-E2 to T-E5" counts T-E3 and T-E4 a second time if they are
   red, because line 161 has already committed them. Write "with each T-E test not committed red in the previous
   commit": e1 §7 point 1 and e1 review "must add" 6 split them. D4 has the same wording.
10. **Names.** Add a names line, as S3-R26's header does ("Names", rulings :421). Proposed: "In this item, R1 is e1's
    route, and A1, A2, A1.n and A2.n are e2 §3's; item 3's and item 4's labels keep their meanings." S3-R27 already
    uses these names for other things:
    - R1 for item 3's progress offer (:872), and R1 to R19 in `integrate-rr21.md`;
    - "A1 and A2" for item 4's d3 parts (:928, :1011), and A1 to A8 for item 3's d2 route (:832).
11. **Citations.**
    - Line 55: the test spans `EngineRaceTests.swift:82-122`, because `:123` closes the suite. The text copies e1
      review M2's range.
    - Line 78: cite rulings :441, as D2 does.
    - Line 86: the fold's kill ends at `s3f.md:6566` ("rr21-T8b (`RerouteRequeue:124`, `:130`) kills it in both
      orders", and e1 review M7 cites `:6565-6566`). So the range is `:6563-6566`, not e1's `:6563-6565`.
    - Lines 91 and 155: the file is `docs/ARCHITECTURE.md`.

## For the orchestrator

1. **Cycle 21's pin-record mutants under the flag form.** In `.build-s3f/c21/tools/mut-c4fix.py`:
   - these anchor texts no longer occur: p3's `= self.state.copySerial` (`:22`), the `index = Int(committed &- serial)`
     of p4 and p5 (`:23-24`), and p10's `$0 > self.state.copySerial` (`:29`);
   - p1, p2 and p2b's guard (`RECORD`, `:9`) would occur twice if R1's write copies `committed`'s guard, as e1 §2
     proposes;
   - their filters (PIN, LAYER, INV, JOIN) do not include the T-E tests.

   Renaming rr21-T8b (line 47) also removes it from the LAYER filters of `mut-c4fix.py`, `mut-c3.py`, `mut-c3fix.py`
   and `mut-pinend.py`, and from `mut-i5.py`'s `T8B`. No decision says whether these are rewritten and re-run, as item
   5 does for r6 and r8 (rulings :933-937).
2. **T-E2 is never run on `d5b2ab9`.** D4's step 0 runs T-E1, T-E3, T-E4 and T-E5, and T-E2's "green" on `d5b2ab9`
   rests on code reading only (e1 §4). If T-E2 is red there, it lands with R1, with no red commit (S3-R26 item 11).
3. **The probes' fixes have no step for their kills.** D2 kills a probe fix's branches, but D4's step 7 names only
   R1's, A1's and A2's kills. P-S's route (the `.superseded` arm) and the route of P-1 and P-2 (`relane`'s guard,
   `EngineJobs.swift:307`) need a step.
4. **P-3 can be red with visit-first's answers.** At the replay, its `#require(state == .queued)` can fail while the
   answers hold, because R1 reads no job state; e1 §3 calls a `.blocked` state "the move's own finding". D2 reports a
   red probe with no route as blocking. But S3-R16 1(a), and D2's own sentence ("A different answer … is blocking"),
   block only a different answer.
5. **The audit behind A2.6, and behind A1.4.** "A5's audit (item 3)" is item 3's audit of the answer-site suites'
   predicates (rulings :838), not of the purge suites'. So A2.6's gate rests on an audit that never looks at the
   purge's tests. So does the drafter's item 4: A1.4's `notifyObservers` change has no audit at all.
6. **(i) under `.scope`.** D3 does not say which ids the scope selects. e2's after-A1 estimate for this case, 35 to 45
   ms (e2:195), implies that it selects all of them and runs through the filter path. A scope that selects few ids
   withdraws almost nothing (`e2-purge-review.md:71`).
7. **The user-waiter case drops "or ensures".** e2 review must-fix 10 (`:121`) and "must add" 3 (`:185`) gate "10,000
   jobs held only by user waiters or ensures". D3 and the text (line 106) keep only the user waiters.
8. **Red cases that A1 does not close stay red through A1's and A2's commits.** S3-R26 item 11 says "Only that commit
   may be red" (rulings :639; it applies through S3-R27 item 10, :991). D3 commits each missing case red right before
   A1's first part, and A1 has seven commits, A2 up to six more. This is reqs #13's reading of the rule, and it needs
   a ruling either way.
9. **Regression controls.** e1 review S9 names them, in both orders: rr21-T8b as changed, the PIN-END suite,
   FBJoinGapFailure, Shape A and probe (ii), and the D-13 test. They guard R1's new write, which runs behind every
   ENOENT while events wait. No decision carries them, so they are advisory.
10. **`integrate-rr21.md`'s B17** ("Reached: T5 (pin holds) and T8/T8b (pin left)", `:971-972`) goes stale under R1,
    which keeps T8b's pin. D2's amendments to that file name only D6, its residual and its must_not.
11. **Answer 6.3's header predicate.** The header still says such a pin "follows the copy at the replay" (rulings
    :680). PIN-END's fix already changed that for the commit end: the walk now starts at the commit's copy and walks
    on (`s3f.md:5819-5822`). P-S's route, if it lands, would change it for the supersede end too. 12.2 re-scopes the
    class but keeps the predicate.

## Checked and found faithful

- **12.1.** The figures and loads (correct #5, reqs #6 and reqs #12) match the findings file, and the outside-the-bar
  shapes match item 4's list (rulings :888-893). `commitTwoStalledSubscribersTurns` is recorded and not gated
  (`BenchSyncCycle21.swift:156-161`), so it cannot trip item 10 step 8's FAIL rule, which now names P-13 only.
- **12.2.**
  - Every code citation checks out: `EngineDispatch.swift:1132-1133`, `:1261-1268`, `:1274-1283`;
    `EngineFollow.swift:372`, `:765-773`, `:794-820`, `:1561`, `:1581-1582`; `EngineShutdown.swift:130`;
    `EngineCommands.swift:2239-2250`; `EngineState.swift:217-222`; the PIN-END test, `:263-278`; and rr21-T8b,
    `:8-26`, `:124`, `:127`, `:142`.
  - The T-E table matches e1 §4 and review M1. The kill table carries M3's swap of the `next < layers.count` rows and
    M1's three semantic mutants.
  - The serving rule (M6) is right. So are the amendments' targets (rulings :680-682, :441, :713-716;
    `integrate-rr21.md:316-318`, `:586`, `:597`) and the records' lines, except `:6566`.
- **12.3.** The table's figures and loads match PURGE-QUEUED, PURGE-JOINS, the findings file and `s3f.md:6668-6670`,
  and every estimate is labelled as one. The code citations are right (`EngineCommands.swift:963-1117`,
  `EngineJobs.swift:395`, `:412`, `:483`, `DeadlineHeap.swift:79-81`, `ValidatedManifest.swift:78-83`). A1, A2, B
  and the decision rule match D3, e2 review must-fix 6 to 12, and "must add" 1 to 9.
- **12.4.** Every row of the findings mapping fits the findings file.
- **The drafter's "For the orchestrator" 1 to 11.** I checked each against its source, and each is accurate.

## Not verified

- I built, ran and measured nothing. T-E2 to T-E5's answers and R1's behaviour are e1's code readings, and the text
  labels them so. I did not re-trace them.
- I do not know whether `mut21s.py` refuses a doubled anchor or mutates its first match (For the orchestrator 1).
