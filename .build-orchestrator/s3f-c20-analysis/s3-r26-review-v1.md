# review:spec

Verdict: Not ready to append: the order of work can be carried out and its step numbers match both specifications, but the draft requires RR21-HOP and RR21-WINDOW-GATE at site 2, which no shape reaches, and it leaves open whether integrate-c21's C1/N3 or integrate-rr21's R4/B3-B4 governs committed's refused predicate and its kill tests; it should also settle the merge-gate, Phase 2, R18, chunking and idle-fallback triggers, say which spec wins where integrate-rr21 replaced integrate-c21's interactions, and disambiguate the reused labels.

## review:spec #1 [must-fix] s3-r26-draft.md:39-41 (item 1, 'The critics' four holes')

**Conflicts with:** integrate-rr21.md:466, :1034, :1038, :1041; critic-rr21-answers.md:103

**Evidence:**
Draft :40 says: 'RR21-HOP, RR21-WINDOW-GATE and RR21-PRESENT-PRUNE, at each site'. integrate-rr21.md:466 (RR21-HOP) says: 'At sites 1 and 3, with integrity and .locked variants.' Its commit plan puts HOP and WINDOW-GATE at site 1 (:1034) and site 3 (:1038) only. Site 2 gets only 'PRESENT-PRUNE at site 2' (:1041). critic-rr21-answers.md:103 says: 'Site 2's targets are J's content ..., which cannot start or publish behind the barrier ... So refutations 1 and 2 do not reach site 2; refutation 3 does'. The ruling overrides the specs (draft :18), so it now requires two tests whose shape cannot exist. A verifier judging by the ruling can report the missing site-2 variants as an open blocking hole. Any test written to fill the gap cannot run red (G4).

**Suggested:**
- RR21-HOP and RR21-WINDOW-GATE, at sites 1 and 3. Site 2's targets cannot start or publish behind the barrier, so neither hole reaches site 2 (`critic-rr21-answers.md:103`). The draft cites that line in place of a site-2 test.
- RR21-PRESENT-PRUNE, at all three sites.
- RR21-RUN-MIDDRAIN, for the run that settles mid-drain.

## review:spec #2 [must-fix] s3-r26-draft.md:74-76 (item 4: 'C1 lands only with item 1's rewrite of committed'), with :21

**Conflicts with:** integrate-c21.md:318 and N3 :420-424, against integrate-rr21.md:99-100 (R4), :928-933 (B3, B4), :358 (T3-captured), :437 (T15)

**Evidence:**
integrate-c21.md:318 says: 'Order refused's conjunction cheapest first: `!refused, let entry = copy.entry(for:), sameTransfer(entry, job.entry), captured.contains(asset)`.' Its N3 (:422-424) says: 'Dropping sameTransfer is killed by T-R1. Dropping `captured.contains` is killed by T-R2. 'Never true' is killed by T15 (design-minimal N15).' integrate-rr21.md:99-100 keeps today's split instead: 'moved-away ... when `self.state.applied.entry(for: a)?.transferID != transfer`; otherwise it is deferred. For a deferred id, `refused = refused || captured.contains(a)`'. Its branches table maps C1 to T3-captured (:928-930). Neither spec defines T-R1 or T-R2; only design2-commit-window.md:228-229 does. integrate-rr21's T15 is 'cancel and release while owed' (:437). The draft orders both 'its tests' (:74) and 'its tests' (:21) over the same lines. The predicate, the mutant list and the S3-R25 item 10 table can therefore each be built two ways, and two verifiers can judge them differently.

**Suggested:**
- C1 lands only with item 1's rewrite of `committed`, in `integrate-rr21.md` R4's form. An id is moved-away when `applied.entry(for:)?.transferID != transfer`. For a deferred id, `refused = refused || captured.contains(a)`, with `captured` lazy. No `sameTransfer` conjunct is added.
- R4's mutants replace `integrate-c21.md`'s N3:
  - T3-captured kills 'refused never set' (B3, B4);
  - build T-R1 and T-R2 from `design2-commit-window.md:228-229`. T-R1 kills a refused set for moved-away ids. T-R2 kills the dropped `captured.contains`. Both run in both orders.
- In this ruling, T15 is `integrate-rr21.md`'s cancel-and-release test. `design-minimal.md`'s T15 is T3-captured.

## review:spec #3 [should-fix] s3-r26-draft.md:63 (item 3, 'When'), with :32 and :182

**Conflicts with:** integrate-c21.md:282, :290, :539; critic-move-index.md:26-27; integrate-rr21.md:862, :1035

**Evidence:**
Draft :63 says: 'Its merge gate is `concentrationPublicationTurns`, re-measured with the index in place.' It gives no bar and no path for a miss. integrate-c21.md:290 says: 'do not merge without the merge gate'. The bar appears only in critic-move-index.md:27: 'best of 3 ≤ c2Budget at a 1-minute load ≤ 10'. The case already stands at 10.16 ms (draft :73). Suppose it misses with the index. Then B cannot land. RR-21 needs B2-B5 (draft :32). Phase 2 waits for step 6, which comes after RR-21 (draft :182; integrate-c21.md:539). Nothing can land first, so the plan stops. integrate-rr21.md:862 and :1035 re-check the gate at C3, also with no outcome for a miss.

**Suggested:**
- **The merge gate:** `concentrationPublicationTurns` with the index in place, best of 3 at most `c2Budget`, at a 1-minute load of 10 or less (`critic-move-index.md:27`).
- If it misses, take contingency (ii): build the index lazily, at a job's first move off it (`critic-move-index.md:26`). Re-measure.
- If it still misses, decide Phase 2 on step 2's figures and land it before step 4. Then re-measure.
- A miss at C3's re-check is blocking (S3-R16 1(f)) and is fixed in C3.

## review:spec #4 [should-fix] s3-r26-draft.md:174 (item 11, step 5), with :10-12

**Conflicts with:** integrate-c21.md:486-488, :491, :502, :515, against integrate-rr21.md:682-688, :699-700, :714, :871

**Evidence:**
The draft replaces only 'integrate-c21.md's step-5 text, which still names design-minimal.md's steps' (:174). integrate-c21's interactions still describe design-minimal, and integrate-rr21's interactions_changed contradicts four of them:
- Interaction 1 (:486) says '... rerouteTakenOff, which returns `left`'. integrate-rr21.md:871 says 'under this design, replay returns EventAfterFollow?. Update the integrate text.'
- Interaction 3 (:491) says 'RR-21 step 13's guard becomes `eventsAfterFollow.isEmpty`'. :688 says 'Its early return is removed, not narrowed to eventsAfterFollow.isEmpty.'
- Interaction 7 (:502) says 'the waiter ..., group ... and run (:1812-1817) clauses accept .reroutes items'. :699-700 say 'Only the waiter and group clauses accept owed items. The run clause gets no acceptance'.
- Interaction 18 (:515) says 'RR-21's per-turn budget (inboundIDsNow) bounds these spawns'. :714 says 'Drain turns spend drainIDsLeft (512), not inboundIDsNow.'
Item A's A8 (step 3) is written against interaction 3.

**Suggested:**
- `integrate-rr21.md`'s interactions_changed replaces `integrate-c21.md`'s interactions 1, 3, 7, 11, 13 and 18, which still describe `design-minimal.md`. Where they differ, `integrate-rr21.md` wins:
  - the replay returns `EventAfterFollow?`. There is no `rerouteTakenOff` and no `left`;
  - `withdrawPurgedJoins`' early return is removed in C3, not narrowed. A8 (step 3) keeps it until then;
  - only the waiter and group clauses accept owed items. The run clause gets no acceptance;
  - drain turns spend `drainIDsLeft`. Site turns spend `inboundIDsNow`.

## review:spec #5 [should-fix] s3-r26-draft.md:39, :176 and :184 (red-first runs, C1 folded into step 1, commits within step 5)

**Conflicts with:** S3-R1 (s3-rulings-s3f.md:6); integrate-c21.md:520, against integrate-rr21.md:504, :1023, :1052

**Evidence:**
S3-R1 says: 'failing test committed on its own, then the fix; CLAUDE.md P3'. integrate-c21.md:520 says: 'Failing tests and pins first, committed on their own (P3)'. integrate-rr21.md says the opposite in three places:
- :1052: 'Every commit stays green ... Each failing test is run red before its fix in the same commit (P3).'
- :1023 (C1): 'Commit no failing test.'
- :504: 'Probes recorded, not committed as failing tests'.
The draft makes C1 part of step 1 (:176 'its C1 is the step-1 probe above'). It asks for red-first tests inside step 5 (:39; :228 'RR21-RUN-MIDDRAIN red first'). It also says 'Within step 5, commit each of C2–C7 on its own' (:184). It never says which rule holds inside step 5, or whether a breaking JOIN-GAP probe at step 1 is committed.

**Suggested:**
- **Red first.** A test that fails on the code before its fix is committed on its own, then the fix (S3-R1, P3). This holds inside step 5 too. Such a commit is the only one allowed to be red, and its message names the test. Every other commit stays green.
- A probe that holds is recorded with its result. It is not committed as a failing test (`integrate-rr21.md:504`). A probe that breaks S3-R16 item 1 becomes a failing test under the rule above.

## review:spec #6 [should-fix] s3-r26-draft.md:78-81 (item 4, Phase 2), with :182 and :221

**Conflicts with:** integrate-c21.md:368, :375; integrate-rr21.md:529; design2-commit-window.md:257

**Evidence:**
Draft :78 says: 'Phase 2 (C12) applies only if, after Phase 1:', followed by two conditions. Draft :182 and :221 then add C3's figures: 'Either trigger applies Phase 2.' and 'as a trigger beside item 4's own'. Neither gives the bar for C3's figures. Item 4's own bar is the in-actor turn 'above 7.0 ms' (integrate-c21.md:368). integrate-rr21.md:529 says of commitWaitersBoundTurns: 'If it misses after C Phase 1, it is C Phase 2's trigger', which means above c2Budget. commitRerouteWaitersTurns also times RR-21's own re-routes, and 'Phase 2, if triggered, is independent of `.reroutes`' (design2-commit-window.md:257). The draft drops integrate-c21.md:375: 'For groupStalledSubscriber the contingency is SubscriberQueue.reserveCapacity. Otherwise, report to the orchestrator.'

**Suggested:**
- **Phase 2 (C12)** applies if any of these holds, best of 3 at a 1-minute load of 10 or less:
  - after Phase 1 (step 2): the in-actor `.waiters` turn is above 7.0 ms, or any heartbeat is above `c2Budget`;
  - at C3: `commitWaitersBoundTurns` or `commitRerouteWaitersTurns` is above `c2Budget`, in the commit's own turn or its heartbeat.
- A `commitRerouteWaitersTurns` miss that stays with Phase 2 in place belongs to RR-21. Report it with its figures.
- A `groupStalledSubscriber` miss takes `SubscriberQueue.reserveCapacity` (`integrate-c21.md:375`).
- Record the figures that decided it, either way.

## review:spec #7 [should-fix] s3-r26-draft.md:179 and :213 (the join gap's R18 trigger)

**Conflicts with:** integrate-rr21.md:253-255, :620-621

**Evidence:**
Draft :179 says: 'C4 re-probes the join gap in both orders. R18 lands in that commit only if the probe breaks'. Draft :213 says: 'If either probe breaks S3-R16 item 1, the gap is blocking (S3-R21 item 4). R18 then lands in that commit'. integrate-rr21.md:620-621 says: 'Residual only if PROBE-RR21-JOIN-GAP passes in both orders after site 1. Otherwise it is blocking (S3-R21 item 4), and R18 lands.' Suppose only the step-1 probe on 8e1fb24 breaks. Then :213 makes the gap blocking and puts R18 in step 1's commit, where R18 cannot exist yet: it uses R10's chain and R11's pass (integrate-rr21.md:254-255), which arrive in C3.

**Suggested:**
- The C4 re-probe decides, in both orders. If it breaks S3-R16 item 1, the gap is blocking (S3-R21 item 4). R18 lands in C4, with RR21-HOP's join variant.
- The step-1 probe is evidence only. If it breaks and C4's holds, record both results. No `.join` layer is built (G4).

## review:spec #8 [should-fix] s3-r26-draft.md:180 and :220 (site 2's chunking)

**Conflicts with:** integrate-rr21.md:525, :1043, :920-1016 (branches B1-B32); judge-rr21.md:264

**Evidence:**
Draft :180 says: 'C6 is site 2, with the chunking if `movedBeforeDrainWaitersTurns` misses.' Neither spec designs the chunking. integrate-rr21.md:525 says only 'If it misses, chunk the take-off before the verdict', and :1043 says 'If site 2 misses C2, add the chunking here (ruling 6)'. The only sketch is judge-rr21.md:264: 're-run the verdict behind a take-off phase of the same batch. That adds about 3 branches.' Those branches are not in B1-B32, which the draft makes the bar (:21). They have no invariant, test or pin, and they touch site 2's decision before the verdict (:26).

**Suggested:**
- **If `movedBeforeDrainWaitersTurns` misses,** build the chunking as `judge-rr21.md:264` sketches it. The take-off runs over drain turns before the verdict, and the verdict replays behind it in the same batch. Site 2 still decides before its verdict whether it owes.
  - Add its branches to the branches table. Each gets a test that kills its drop-mutant 2/2 in `sweepFollowsFirst`.
  - Pin it twice (S3-R23 item 3).
  - Record the design in the draft.

## review:spec #9 [should-fix] s3-r26-draft.md:169-173 (item 11, step 1), with :56

**Conflicts with:** integrate-c21.md:520-523, against :131-137 and :63 (A12)

**Evidence:**
integrate-c21.md:520-523 puts 'the new BenchSync cases: deferBehindVerdictTurns, ...' in step 1, 'with their 'before' figures recorded on 8e1fb24'. But the case's setup expects 'no join entered eventsAfterFollow during the follow (joinsBehindVerdicts holds them)' (:134). A12 (:63) adds the case in step 3, with a drained count that 'must include bucket joins'. joinsBehindVerdicts does not exist at 8e1fb24: git grep in Sources and Tests finds nothing. The draft's step 1 (:170 'Step 1 also holds, on 8e1fb24') keeps the case, so step 1 needs a field that step 3 adds.

**Suggested:**
- `deferBehindVerdictTurns` takes its 'before' figure in step 1 without the expectations that read `joinsBehindVerdicts`. Step 3 (A12) adds them, together with the drained count that includes bucket joins.

## review:spec #10 [should-fix] s3-r26-draft.md:95 and :106-108 (item 5's test shape and probe (i)'s fix)

**Conflicts with:** analyse-g4-reach.md:158-166 (Shape B); integrate-rr21.md:586

**Evidence:**
Draft :95 allows Shape B 'if A's drained publication does not compose with the walk'. Draft :108 gives (i)'s fix: 'no T20 re-queue while the attempt's end is recorded and the barrier is up'. Shape B reaches the case only through that re-queue: 'The read's sweep turn moves x, and T20 queues T at M's epoch' (analyse-g4-reach.md:163). So the fix can remove item 5's test path, while draft :93 says the case 'cannot be removed'. integrate-rr21.md:586 says: 'Do not fix replayJoin's approximation or the waitingTarget window this cycle, unless ruling 4's probe breaks'. The draft says neither which rule wins nor in what order the test and the fix land.

**Suggested:**
- Item 5's test lands before (i)'s fix.
- If (i)'s fix removes the test's only path, reach the case with Shape A. If no shape reaches it, remove the case with the reason (S3-R16 1(e)), and correct the 'cannot be removed' line.
- (i)'s fix changes relane. It is not a fix of the `waitingTarget` window under `integrate-rr21.md:586`.

## review:spec #11 [should-fix] s3-r26-draft.md:42-44 (existing tests that change path), with :217

**Conflicts with:** integrate-rr21.md:218, :895-896

**Evidence:**
Draft :42-44 lets 'the idle and ledger tests in integrate-rr21.md's plan_gaps' be updated when their 'turn count, order or path expectation changes'. For the same event, draft :217 says 'Fall back to `reroutesWaiting > 0` only if an existing test changes path'. integrate-rr21.md:218 says: 'Narrow fallback, used only if an existing idle or ledger test changes path'. :896 says: 'Prevention: run the full suite at that commit; use the narrow fallback, with its record.' One trigger has two remedies, with no order between them.

**Suggested:**
- An idle or ledger test that changes path because of the broad idle guards takes the narrow fallback first (`reroutesWaiting > 0`, item 12's answer 6.5), with its record. Update the test only if it still changes path under the narrow guard.
- Any other test whose turn count, order or path expectation changes may be updated, to an expectation as exact as the old one. Each update gets a one-to-one record in the draft that names its S3-R16 item 2 class.

## review:spec #12 [should-fix] s3-r26-draft.md:78-81, :180, :182 and :220-221 (contingency triggers), with :63

**Conflicts with:** S3-R23 item 3 (s3-rulings-s3f.md:301); integrate-rr21.md:589

**Evidence:**
S3-R23 item 3 says: 'If the load never falls that low during your run, report the case as 'not measured at a quiet load', with its figures and loads. It is then neither confirmed nor blocking.' Phase 2 (:78-81, :182), the chunking (:180, :220) and B's merge gate (:63) each depend on a best-of-3 figure. The host is shared (S3-R23), so that figure may never be taken at a load of 10 or less. The draft gives no default, so the fixer cannot decide whether to build Phase 2, build the chunking or land B.

**Suggested:**
- **A deciding figure without a quiet load.** If a figure that decides Phase 2, the chunking or B's merge gate cannot be taken at a 1-minute load of 10 or less, decide on the best of 3 at the lowest load you get. Record it as 'not measured at a quiet load' (S3-R23 item 3), with its loads.
- The orchestrator re-measures it before close-out. A different result reopens that decision.

## review:spec #13 [should-fix] s3-r26-draft.md:32-36, :55, :71, :83, :85, :175-182 and :192

**Conflicts with:** integrate-c21.md:79-122 and :250-269 (T1-T7), :162-224 (B1-B13), :313-376 (C0-C13), against integrate-rr21.md:339-507 (T1-T18 families), :920-1016 (B1-B32), :1018-1052 (C0-C8)

**Evidence:**
The two specs reuse labels, and the draft mixes them:
- :192 'B8's re-insertion' is item B's B8. In the same paragraph, 'item 1's site-2 branches (B6–B9, RR21-VERDICT-ZERO)' are integrate-rr21's branches, where B8 is 'take-off: whole interest (removeInterest) vs partial (subtractAssets)' (integrate-rr21.md:945).
- :85 'Terminal events stay ascending (C3 ...)' is item C's C3. :178 'C3 lands the readers' and :182 'C3's commit-turn figures' are the commit_plan's C3.
- 'C2' means resolveAll's order at :83, the types commit at :177 and the budget class at :148.
- :55 'T1's per-turn assertion' is item A's T1. :34-35 'T1-edge, T1-fit' and 'T1's and T3's per-turn id counts' are RR-21's.
- integrate-c21's T4 is B's orphan test (:255). integrate-rr21's T4 is groupDelistedAll's (:544).
Verifiers judge by the ruling, and the S3-R25 item 10 table keys on these names.

**Suggested:**
- **Names.** The two specifications reuse labels. In this ruling and in the draft's records:
  - item A's, B's and C's labels carry their letter: A-T1, B-B8, B-T5, C-C3;
  - `integrate-rr21.md`'s labels carry RR-: RR-B6 to RR-B9, RR-C3, RR-T1-edge, RR-T15;
  - 'C2' alone is the budget class (S3-R5).
- For example, item 12's answer 1 reads: 'This covers item A's bucket branches, B-B8's re-insertion, item 5's case and item 1's site-2 branches (RR-B6 to RR-B9, RR21-VERDICT-ZERO).'

## review:spec #14 [should-fix] s3-r26-draft.md:46 and :160-163 (residual risks, accepted orders)

**Conflicts with:** integrate-rr21.md:604-610, :617-626; integrate-c21.md:488; S3-R16 item 2 (s3-rulings-s3f.md:161-166)

**Evidence:**
Draft :46 says: 'integrate-rr21.md's residual_risks, in the classes item 12's answer 6 gives.' Answer 6 (:207-222) gives a class only to rulings 1, 2, 3 and 5 (timing). integrate-rr21's list also uses these categories:
- 'order/place' (:605: the (asset, token) replay and new jobs' places);
- 'order' (:607: site 2's two orders);
- 'order/timing' (:610: the bulk release);
- 'C2 class of cycle 19' (:623), 'gates' (:626) and 'memory only' (:618).
The last three are not S3-R16 item 2 classes. Draft :160 'Accepted orders (S3-R16 item 2), each recorded in the draft' lists three orders and leaves out RR-21's own, which integrate-c21.md:488 says 'RR-21 records'.

**Suggested:**
- **Residual risks:** `integrate-rr21.md`'s residual_risks, each in the class it gives there. Its 'C2 class' and 'gates' entries are not residual: a miss at a quiet load is blocking (S3-R16 1(f)). 'Memory only' is recorded without a class.
- Add to the accepted orders:
  - item 1's replay in (asset, token) order, and the places of jobs created at the replay;
  - item 1's two orders at site 2, with `PROBE-RR21-RESERVE-REJOIN`;
  - item 1's bulk release, which can let a run materialise more fetches, with T18.

## review:spec #15 [nit] s3-r26-draft.md:116

**Conflicts with:** integrate-c21.md:53, :500; EngineFollow.swift:384-399 at 8e1fb24

**Evidence:**
Draft :116 says: 'delete `EngineFollow.swift:390-398`.' At 8e1fb24, `if spawned == nil {` is at :390 and its closing brace at :399. integrate-c21.md:500 cites 'the spawn-nil branch (:390-399)', and :53 says '(EngineFollow.swift:384-399). Drop `let spawned =` and the `if spawned == nil` block'. The draft's range leaves out the brace. The :390-398 range comes from analyse-g4-reach.md:170.

**Suggested:**
- delete the `if spawned == nil` block (`EngineFollow.swift:390-399`) and `let spawned =` at :384.

## review:spec #16 [nit] s3-r26-draft.md:39

**Conflicts with:** integrate-rr21.md:26-27; critic-rr21-answers.md:103; S3-R1 and S3-R19 item 1 (s3-rulings-s3f.md:6, :237-240)

**Evidence:**
Draft :39 says: 'The critics' four holes are blocking fixes. Each test runs red first ... (S3-R19 item 1, P3)'. The critics found three holes (refutations 1-3: HOP, WINDOW-GATE, PRESENT-PRUNE). integrate-rr21.md:26-27 lists the checkRunSettled guard, which is RR21-RUN-MIDDRAIN's fix, as 'New in this section, beyond the judge and the critics'. S3-R19 item 1 is 'Probe first'. The red-first rule is S3-R1.

**Suggested:**
- **Four holes are blocking fixes:** the critics' three refutations and `integrate-rr21.md`'s mid-drain settlement. Each test runs red first wherever its shape exists before the fix (S3-R1, P3):

## review:spec #17 [nit] s3-r26-draft.md:149 and :154

**Conflicts with:** integrate-c21.md:48-51, :69, :497; EngineCommands.swift:1702, :1959 at 8e1fb24

**Evidence:**
Draft :149 makes 'the recount's walks over the buckets' an inventory row, and :154 gives each row 'a BenchSync figure at 10,000 ids'. The recount is A9/K2 inside followBarrierViolations (integrate-c21.md:48-51, :69). Only invariantViolations() calls followBarrierViolations (EngineCommands.swift:1959). Nothing in Sources calls invariantViolations(); only tests do. The recount is therefore a test oracle, not engine work.

**Suggested:**
- the bucket's placement at batch formation, and the purge's and `followedLane`'s walks over the buckets (item 2). K2's recount is a test oracle, so it is not a row.

## review:spec #18 [nit] s3-r26-draft.md:38

**Conflicts with:** integrate-c21.md:440; integrate-rr21.md:545, :1039; critic-commit-window.md:83; design-minimal.md:285

**Evidence:**
integrate-c21.md:440 says: 'Added with RR-21: groupDelistedFit, groupDelistedAll, groupMovedToBound and runSuperseded.' integrate-rr21's pins define groupDelistedAll (:545) but not groupDelistedFit, which only critic-commit-window.md:83 defines. integrate-rr21.md:1039 says: 'Measure supersededRerouteTurns, supersededUserTurns and runSuperseded', but only design-minimal.md:285 defines supersededUserTurns. Draft :38 says 'Measure every one; a miss is blocking'.

**Suggested:**
Two cases that the specifications name are defined only in background files: `groupDelistedFit` (`critic-commit-window.md:83`) and `supersededUserTurns` (`design-minimal.md:285`). Build them from there, and measure them with the rest.

## review:spec #19 [nit] s3-r26-draft.md:169-184 (item 11), with :209 and :236

**Conflicts with:** integrate-rr21.md:505-507, :1018-1052

**Evidence:**
Item 11 places PROBE-RR21-JOIN-GAP (step 1 at :172; C4 at :179). It does not place PROBE-RR21-HEAL-T21 (answer 6.1, :209) or PROBE-RR21-RESERVE-REJOIN (the rider at :236). integrate-rr21.md:505-507 lists both, but its commit_plan places neither. HEAL-T21 needs owed T21 items, which first exist at site 1 (C3). RESERVE-REJOIN needs the reservation, which first exists at site 2 (C6).

**Suggested:**
- C3 also runs `PROBE-RR21-HEAL-T21`, and C6 runs `PROBE-RR21-RESERVE-REJOIN`, both in both orders. Record each result in the draft.

## review:spec #20 [nit] s3-r26-draft.md:22

**Conflicts with:** integrate-rr21.md:714-715; s3-r26-draft.md:26

**Evidence:**
Draft :22 says: 'A site's own turn makes at most `inboundIDsNow` re-routes, counting its own answers.' Site 2's own turn is a drain turn. integrate-rr21.md:714 says: 'Drain turns spend drainIDsLeft (512), not inboundIDsNow.' The draft's own :26 has site 2 reserve from `drainIDsLeft`.

**Suggested:**
- At sites 1 and 3, the site's own turn makes at most `inboundIDsNow` re-routes, counting its own answers. At the commit this is the fit charge, `locations.count + items.count > inboundIDsNow`. Site 2's turn is a drain turn and spends `drainIDsLeft`.

## review:spec #21 [nit] s3-r26-draft.md:192

**Conflicts with:** integrate-c21.md:107, :129

**Evidence:**
Draft :192 says: 'For such a branch, '2/2 in each order' in integrate-rr21.md means 2/2 in sweepFollowsFirst.' Item A's pin uses the same requirement: 'Reverting to the queue insert must fail it 2 out of 2 times in both orders' (integrate-c21.md:129). A bucket exists only in sweep-first: 'In sweep-first the joins are in the bucket; in visit-first they joined at once' (:107).

**Suggested:**
For such a branch, '2/2 in each order' or '2 out of 2 times in both orders' in either specification means 2/2 in `sweepFollowsFirst`. One example is T1's pin (`integrate-c21.md:129`).

# review:bar

Verdict: Not ready to append as written: the figures and issue references check out, but four places would mislead or stall the fixer or the verifiers (answer 6.3 calls timing an RR-14-shaped case that S3-R24 item 5 and S3-R21 item 4 make blocking; item 1's test-change rule contradicts answer 6.5's fallback and drops S3-R16 item 4's protection of MUST assertions; answer 6.4 puts R18 in a step-1 commit, where it cannot exist, which also contradicts item 11's C4; item 1 asks for RR21-HOP and RR21-WINDOW-GATE at site 2, where the critic shows they cannot be built), and there are eleven should-fix ambiguities and six nits on top.

## review:bar #1 [must-fix] s3-r26-draft.md:211 (item 12, answer 6.3); also the lead of answer 6 at :206

**Conflicts with:** S3-R24 item 5 (s3-rulings-s3f.md:330) and S3-R21 item 4 (s3-rulings-s3f.md:276), which the draft does not say it overrides; the draft's own item 1 at s3-r26-draft.md:28

**Evidence:**
Paths: the draft and specs are in /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/. The rulings are /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-rulings-s3f.md. The code is /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f at 8e1fb24.
Draft :211: "A pin whose job committed, was superseded or was re-queued by ENOENT (T8b) between the apply and the replay follows the copy at the replay. This is timing. There is no layer per commit."
The sources say this is not always exact:
- integrate-rr21.md:597: "This is exact unless another apply landed between that end and the replay."
- judge-rr21.md:266: "This is exact unless another apply landed in between ... Rule it residual, or keep a layer per commit".
- integrate-rr21.md:740: "The reference re-routes those pairs at that job's next end under the copy then, which equals the copy at the replay unless another apply lands in between".
Take that case. The reference has already re-routed the pair onto W at the job's end. If W is publishing when the later apply lands, the reference passes the pair, and the pair gets W's outcome. The design replays under the later copy and sends the pair elsewhere. Both answers come after that apply.
S3-R24 item 5 (rulings:330): "It is blocking only if a probe shows a different answer when the later apply lands after both engines' answers, or before both." This is RR-14's shape, and S3-R21 item 4 (rulings:276) made RR-14 blocking.
The draft rejects the same mechanism in item 1. :28 says re-routing under the copy at the replay "reopens RR-14 (refutation 1)". It also probes the similar replayJoin gap twice (:212-214). Yet it gives 6.3 no probe.
Only 6.1 (:207) states the condition that the event "lands between the two engines' answers". Answers 6.2, 6.3 and 6.5 call their cases timing without it.

**Suggested:**
Lead of answer 6:
- Each timing class below holds only while the event lands between the two engines' answers (S3-R24 item 5).
- A probe that shows a different answer with the event before both answers, or after both, is blocking.

Answer 6.3:
3. *A pin whose job committed, was superseded or was re-queued by ENOENT* (T8b) between the apply and the replay follows the copy at the replay. There is no layer per commit.
   - With no apply between that end and the replay, this equals the reference. T8 and T8b pin it.
   - With one, the reference re-routed the pair at that end. If its new target is publishing at the later apply, the reference passes the pair, as in RR-14. That apply lands before both answers.
   - Probe that shape in both orders after site 1 lands, and again after site 3 lands. A different answer is blocking (S3-R21 item 4). Otherwise record it as timing, with the probe.

## review:bar #2 [must-fix] s3-r26-draft.md:42-44 (item 1, "Existing tests that change path"), against :217 (answer 6.5)

**Conflicts with:** S3-R16 item 4 and "What stands" (s3-rulings-s3f.md:168, :150); G3; S3-R17 item 3 (s3-rulings-s3f.md:196); integrate-rr21.md:218 and :895-896; S3-R23 item 3 and S3-R25 item 5 (the bound pins' 2/2 kills)

**Evidence:**
Draft :42: "The fit charge, site 2's reservation and the idle guards can change the path of the six low-budget suites and of the idle and ledger tests". :44: "A test whose turn count, order or path expectation changes may be updated, to an expectation as exact as the old one. Each update gets a one-to-one record in the draft that names its S3-R16 item 2 class."
Draft :217 (answer 6.5): "Fall back to `reroutesWaiting > 0` only if an existing test changes path, and record why."
So an idle test whose path the broad guard changes has two remedies: update the test (:44), or narrow the guard (:217). The spec gives only the second. integrate-rr21.md:218: "Narrow fallback, used only if an existing idle or ledger test changes path". :896: "use the narrow fallback, with its record".
The idle tests the spec names assert R-SYN-14, which is a MUST (SPEC.md:239). integrate-rr21.md:860 names "EngineIdleTests:40, EngineSync1HalvesTests:125/:136/:159". EngineIdleTests.swift:40 is `#expect(state.armedTimers == 0 && state.ownedTasks == 0 && state.scheduledDeadlines == 0 && !state.watcherActive)`. The draft's :43 protects only "expected answers".
S3-R16 item 4 (rulings:168) allows a change only for "a removal under item 3". It requires "the old assertion, the new one and the reason", and it says "Answer and MUST assertions are never changed." Rulings:150: "G3 holds: no test that passes today loses an operation, a scenario or an assertion, except as item 4 allows."
The draft extends item 4 to new causes without saying so. The precedent is S3-R17 item 3 (rulings:196), which says "as an exception to S3-R16 item 4".
A turn-count change has no S3-R16 item 2 class; those classes are order, place, ticket, answer timing and backoff. So the record that :44 asks for cannot be written for a turn-count change.
The six suites include EngineFollowBarrierTurnTotalTests. Its lines :106 and :199-200 kill `inboundSpentDrop` and `restSpentDrop` 2/2 (docs/adr-drafts/s3f.md:4796-4797; S3-R25 item 5). :44 does not require those kills to survive.

**Suggested:**
- **Existing tests that change path.**
  - Answer, MUST and invariant assertions never change (G3, S3-R16 item 4). A change there is a finding: fix the code, not the test.
  - An idle or ledger test that changes path: use answer 6.5's narrow fallback. Do not change the test.
  - A low-budget suite whose turn count or order changes through the fit charge or site 2's reservation may be updated one to one, to an expectation as exact as the old one. Each bound's drop-mutant must still fail it 2/2 (S3-R23 item 3, S3-R25 item 5).
  - Record each update in the draft: the old assertion, the new one, and the cause. For an order change, also give its S3-R16 item 2 class.
  - This extends S3-R16 item 4 to these causes only.

Answer 6.5: "Fall back to `reroutesWaiting > 0` only if an existing idle or ledger test changes path, and record why."

## review:bar #3 [must-fix] s3-r26-draft.md:212-214 (answer 6.4), against item 11 at :176 (C1) and :179 (C4)

**Conflicts with:** Item 11 (s3-r26-draft.md:179); integrate-rr21.md:254-255 (R18 is built from R10 and R11), :744, :854 and :1023; S3-R1 (s3-rulings-s3f.md:6) and answer 12.5 (s3-r26-draft.md:204)

**Evidence:**
Draft :212-213: "probed twice: in step 1 in `sweepFollowsFirst`, and after site 1 lands in both orders. - If either probe breaks S3-R16 item 1, the gap is blocking (S3-R21 item 4). R18 then lands in that commit, with RR21-HOP's join variant."
If the step-1 probe breaks, "that commit" is step 1, on 8e1fb24. R18 cannot land there. integrate-rr21.md:254-255 builds R18 in "R11's same pass" and on "R10's chain", and both arrive in step 5.
The spec lands R18 only after the second probe. integrate-rr21.md:744: "If the second probe breaks, land R18 in that commit." :854: "Build them in the commit after the re-probe that follows site 1, and only if it breaks."
Draft :179 (item 11): "C4 re-probes the join gap in both orders. R18 lands in that commit only if the probe breaks". Suppose step 1 breaks and C4 does not. Answer 6.4 then says the gap is blocking and R18 lands, while item 11 says R18 does not land.
Draft :176 adopts integrate-rr21's C1 ("its C1 is the step-1 probe above"), and integrate-rr21.md:1023 says "Commit no failing test." But answer 12.5 (:204) says "A probe that breaks S3-R16 item 1 is blocking, and P3 applies". S3-R1 (rulings:6) says "failing test committed on its own, then the fix".

**Suggested:**
4. *`replayJoin`'s RR-14-class gap* (`EngineFollow.swift:704-707`) is probed twice: in step 1 in `sweepFollowsFirst`, and at C4 in both orders.
   - If the step-1 probe breaks S3-R16 item 1, the gap is blocking (S3-R21 item 4). Commit the probe as a failing test in step 1, with `integrate-c21.md`'s other step-1 failing tests (P3). C1's "Commit no failing test" does not apply to it.
   - R18 needs R10, R11 and the layers, so it lands no earlier than C4.
   - At C4, run that test, or the probe, in both orders. If it breaks, commit it failing on its own, unless it is already committed. Then land R18 with RR21-HOP's join variant.
   - If neither run breaks, it is a residual risk with both probes as evidence, and no `.join` layer is built (G4).

Item 11, C4: "C4 re-probes the join gap in both orders. R18 lands in C4 if this probe breaks, as answer 6.4 says."

## review:bar #4 [must-fix] s3-r26-draft.md:40 (item 1, the four holes)

**Conflicts with:** integrate-rr21.md:466, :476, :1034, :1038 and :1041; critic-rr21-answers.md:103

**Evidence:**
Draft :40: "RR21-HOP, RR21-WINDOW-GATE and RR21-PRESENT-PRUNE, at each site". Draft :18 says the draft "decides wherever those files differ from it", so this line overrides the spec.
The spec places the tests by site:
- integrate-rr21.md:466 puts RR21-HOP "At sites 1 and 3, with integrity and .locked variants".
- :1034 and :1038 run HOP and WINDOW-GATE at sites 1 and 3 only.
- :476 runs PRESENT-PRUNE "At each of the three sites", and :1041 runs it at site 2.
critic-rr21-answers.md:103: "Site 2's targets are J's content ..., which cannot start or publish behind the barrier ... So refutations 1 and 2 do not reach site 2; refutation 3 does".
HOP needs P to be publishing (integrate-rr21.md:465-469). WINDOW-GATE needs "P's publication starts during the window" (:471). So neither shape can be built at site 2. Neither drop-mutant can be killed there either: "drop ends' publishing term at that site's batch" and "drop the hold term".

**Suggested:**
- RR21-HOP and RR21-WINDOW-GATE, at sites 1 and 3;
- RR21-PRESENT-PRUNE, at all three sites;
- RR21-RUN-MIDDRAIN, for the run that settles mid-drain.

Site 2's targets cannot start or publish behind the barrier, so refutations 1 and 2 do not reach it (`critic-rr21-answers.md`).

## review:bar #5 [should-fix] s3-r26-draft.md:39 (item 1, "The critics' four holes"), and :228 (answer 7, "RR21-RUN-MIDDRAIN red first")

**Conflicts with:** S3-R1 (s3-rulings-s3f.md:6); S3-R19 item 1 (s3-rulings-s3f.md:238); item 11's C3 (s3-r26-draft.md:178); integrate-rr21.md:26-27 and :1052; critic-rr21-answers.md:94

**Evidence:**
Draft :39: "The critics' four holes are blocking fixes. Each test runs red first wherever its shape exists before the fix (S3-R19 item 1, P3)".
- None of the four shapes exists at 8e1fb24, because each needs an owing site. The only state before the fix is an owing site without its guard. Item 11 forbids committing that state (:178: "never an owing site before the acceptances and the clauses").
- integrate-rr21.md:1052 resolves this with "Each failing test is run red before its fix in the same commit (P3)". S3-R1 (rulings:6) requires a "failing test committed on its own, then the fix". A verifier who applies S3-R1 will look for a red commit that cannot exist.
- S3-R19 item 1 (rulings:238) is a probe-first rule: "Each is blocking only if a probe ... shows S3-R16 item 1 broken". Citing it next to "are blocking fixes" lets a reader treat a test that cannot go red as not blocking.
- "The critics' four" is wrong for one of them. RR21-RUN-MIDDRAIN is integrate-rr21's own find. integrate-rr21.md:26-27: "New in this section, beyond the judge and the critics: a guard in checkRunSettled on reroutesWaiting". The critic found the run guard sound (critic-rr21-answers.md:94: "Holds").

**Suggested:**
- **Four holes are blocking fixes, whatever a probe shows:** the three in `critic-rr21-answers.md`, and the mid-drain run settlement in `integrate-rr21.md`.
  - "Red first" means a scratch copy, as S3-R3 does. Remove the test's guard: the publishing term in `ends`, the hold term, the prune guard, or `reroutesWaiting == 0` in `checkRunSettled`. Run the test, and paste its failing line into the draft.
  - Then commit the test with its guard. For these four only, this replaces S3-R1's separate failing commit.

Answer 7: "the `checkRunSettled` counter guard, a blocking fix, with RR21-RUN-MIDDRAIN red first as item 1 defines it".

## review:bar #6 [should-fix] s3-r26-draft.md:132-141 (item 7), and :236 (answer 7's first rider)

**Conflicts with:** S3-R25 item 9 (s3-rulings-s3f.md:384-387), which reqs #9 cites; S3-R16 item 1 (s3-rulings-s3f.md:151); item 3 (s3-r26-draft.md:59-60)

**Evidence:**
- Item 7's header (:132) has no blocking label. Items 1-6 and 8 each have one. In s3f-c20-issues.json, reqs #9 is `"blocking": false`, and its area cites "(S3-R25 item 9)".
- Yet :134 says "Implement B8 with I2 and T5, together", :137 says "T5 fails first ... (P3)", and :139 lets B8 and I2 be dropped. A verifier cannot tell whether a missing B8 is blocking.
- :138: "Each is blocking only if it gives T' or T1 a different answer than visit-first". S3-R25 item 9 (rulings:387): "It becomes blocking only if a probe shows a different answer, a broken MUST or invariant, or a hang." S3-R16 item 1 also counts liveness.
- Q1's own stages break I2 (:133), and I2 becomes an invariant once item 3 adds it.
- :236 (answer 7, rider): "It is blocking only if those results differ from visit-first's answers." This narrows the same bar.
- Neither place says it overrides S3-R25 item 9 or S3-R16 item 1.

**Suggested:**
7. *`continueMove` takes the id out of `Job.assets` before its guards* (put-back 4; reqs #9). Not blocking by itself (S3-R25 item 9).
   - B8, I2 and T5 belong to item 3, which is blocking. They may be dropped only as the last bullet says, with the attempt recorded.
   - Probe Q1's stages 2 and 3 (variant Y) in both orders. Each probe is blocking only if it breaks S3-R16 item 1 in either order: a different answer, a broken MUST or invariant, or a hang. P3 then applies.

Answer 7's rider: "It is blocking only if those results break S3-R16 item 1 in either order."

## review:bar #7 [should-fix] s3-r26-draft.md:209 (answer 6.1, PROBE-RR21-HEAL-T21)

**Conflicts with:** S3-R24 item 5 (s3-rulings-s3f.md:330); S3-R16 item 1(b) (s3-rulings-s3f.md:151); integrate-rr21.md:506

**Evidence:**
Draft :209: "`PROBE-RR21-HEAL-T21` makes it blocking only if the heal lands before both answers, or if a SPEC MUST on heals breaks (S3-R17)."
- S3-R24 item 5 (rulings:330) needs "a different answer". It also counts both cases: "after both engines' answers, or before both". The draft drops both parts. Read literally, a heal before both answers is blocking even when the answers agree.
- integrate-rr21.md:506 defines the probe as "a scheduleHeal of a T21 system item's asset between owing and replay". Visit-first decides T21 at the site, and the design decides it at the replay. So in this probe the heal always lands between the two answers, and "before both" cannot happen.
- A broken MUST is blocking under S3-R16 item 1(b). S3-R17 only settles a conflict between 1(a) and 1(b).

**Suggested:**
- `PROBE-RR21-HEAL-T21` compares the healed system interest's outcome with visit-first's, in both orders.
- Run it with the heal between the owing instant and the replay. Run it again with the heal before the site, and again after the replay.
- It is blocking if the outcomes differ with the heal before both answers, or after both (S3-R24 item 5). It is also blocking if a SPEC MUST on heals breaks (S3-R16 item 1(b)).

## review:bar #8 [should-fix] s3-r26-draft.md:187-192 (answer 12.1), used by item 5 at :88 and :98

**Conflicts with:** S3-R24 item 3, "Reached" (s3-rulings-s3f.md:323); S3-R25 item 7 (s3-rulings-s3f.md:372)

**Evidence:**
S3-R24 item 3 (rulings:323): "Reached. A test reaches it in both LaneDropVisit orders and kills its drop-mutant 2/2." S3-R25 item 7 (rulings:372): "S3-R24 item 3 applies unchanged." The draft's item 5 cites both (:88: "Blocking (S3-R24 item 3, S3-R25 item 7)").
Draft :187-189 counts a branch as "reached in both orders" when "the test reaches the branch in `sweepFollowsFirst`, and the branch's drop-mutant fails it 2/2 there". :192: "'2/2 in each order' in `integrate-rr21.md` means 2/2 in `sweepFollowsFirst`."
This redefines "Reached" for these branches, but it never says it amends S3-R24 item 3 or S3-R25 item 7. A verifier who reads S3-R25 item 7's "unchanged" will still call item 5's case unreached.

**Suggested:**
Add to answer 12.1, after the three conditions:
- This amends S3-R24 item 3's "Reached", and S3-R25 item 7, for these branches only. Every other branch keeps S3-R24 item 3 unchanged.

## review:bar #9 [should-fix] s3-r26-draft.md:195-197 (answer 12.4)

**Conflicts with:** S3-R20 item 1 (s3-rulings-s3f.md:256); S3-R21 item 1 (s3-rulings-s3f.md:269); S3-R5 (s3-rulings-s3f.md:10); S3-R23 item 3 (s3-rulings-s3f.md:301) as the precedent

**Evidence:**
Draft :197: "A miss that needs two or more subscribers is not blocking in this work package."
S3-R20 item 1 (rulings:256): "C2 is a standing order. The orchestrator cannot waive it; only the owner can, explicitly." S3-R21 item 1 (rulings:269): "Option (c), ruling the shape outside C2, is not available." S3-R5 (rulings:10) sets the bar as "A single actor turn over about 10 ms at 10,000 records".
The draft may set the reference set's subscriber count to one. But ruling a measured C2 miss not blocking is a waiver, and an orchestrator ruling cannot make one. The fixer would record such a miss as a residual risk, while a verifier who applies S3-R20 would call it blocking.

**Suggested:**
4. **The reference set has one subscriber, which may be stalled,** as the existing R-SYN-12 pin has (`BenchSync.swift:297-312`).
   - Measure the cost of a second subscriber once: `commitTurns(.waiters)` with two stalled subscribers. Record it with its figure and load.
   - This sets the reference set's subscriber count. It waives nothing (S3-R20 item 1).
   - If the two-subscriber case misses `c2Budget` at a load of 10 or less, report it as "open, for the owner", with the figure. Like S3-R23 item 3's "not measured at a quiet load", it is neither accepted nor blocking for this cycle. The orchestrator puts it to the owner before it rules the close-out converged.

## review:bar #10 [should-fix] s3-r26-draft.md:164-165 (item 10: "Item B's earlier take-off" and "reqs #7")

**Conflicts with:** integrate-c21.md:302 (its readers are UNCONFIRMED); item 9 (s3-r26-draft.md:147), through S3-R25 item 10 (s3-rulings-s3f.md:388-392)

**Evidence:**
- :164: "Item B's earlier take-off. ... Record the readers that see it earlier". It has no class and no blocking condition. integrate-c21.md:302 lists ten readers and says "Whether 8e1fb24 leaves a stale binding or failure record there is UNCONFIRMED." A stale binding read there could change an answer (S3-R16 1(a)).
- :165: "reqs #7 ... Whatever replaces that line is reached by a deterministic test". It sits under "Residual risks and the non-blocking items", but it is worded as a requirement. In s3f-c20-issues.json, reqs #7 also offered "Or list the line in the draft as reached only in some runs, with the reason".
- Item 9 applies S3-R25 item 10 to every changed line, so a zero count on the new line would be blocking there. The draft does not say which rule applies.

**Suggested:**
- **Item B's earlier take-off** is order and timing (S3-R16 item 2). For each reader `integrate-c21.md` lists, confirm on the new code that it reads no stale binding or failure record. A reader that gives a different answer is blocking (S3-R16 1(a)). Record the readers and the check.
- **reqs #7** is not blocking by itself. The line that replaces `EngineDispatch.swift:1118` is a changed line, so item 9 applies to it. Reach it with a deterministic test (one token, with one bound id and one unbound id), and kill its drop-mutant 2/2. A zero count there is blocking.

## review:bar #11 [should-fix] s3-r26-draft.md:78-81 (item 4, Phase 2's triggers), :63 (item 3, merge gate), :182 (item 11, step 6), :221 (answer 6.6)

**Conflicts with:** The draft's own item 4, against item 11 and answer 6.6; integrate-c21.md:282, :290 and :525; integrate-rr21.md:529 and :1035

**Evidence:**
- :78-80: "Phase 2 (C12) applies only if, after Phase 1: the in-actor `.waiters` turn's best of 3 is above 7.0 ms; or any heartbeat is above `c2Budget`."
- :182 and :221 add a third trigger: "again on C3's commit-turn figures (`commitWaitersBoundTurns`, `commitRerouteWaitersTurns`). Either trigger applies Phase 2." This trigger has no threshold. integrate-rr21.md:529 says "If it misses", which means `c2Budget`. Item 4's own in-actor threshold is 7.0 ms. Item 4's "only if" also rules the third trigger out.
- :63: "Its merge gate is `concentrationPublicationTurns`, re-measured with the index in place." It gives no pass criterion. integrate-c21.md:282 gives none either, and :290 says "do not merge without the merge gate". integrate-rr21.md:1035 re-checks "B's merge gate" at C3, after B has already merged.
- This can dead-end. Suppose step 2's heartbeat is above `c2Budget`, and the gate is read as "at most `c2Budget`". Then B cannot merge at step 4. RR-21 needs B2–B5 (:32), so step 5 cannot land, and Phase 2 waits for step 6.

**Suggested:**
- **Phase 2 (C12)** applies if any of these holds, each best of 3 at a load of 10 or less:
  - after Phase 1, the in-actor `.waiters` commit turn is above 7.0 ms;
  - after Phase 1, any heartbeat is above `c2Budget`;
  - at C3, `commitWaitersBoundTurns` or `commitRerouteWaitersTurns` is above `c2Budget`.
  Record the figures that decided it, either way.
- **B's merge gate:** `concentrationPublicationTurns` with the index in place, best of 3 at a load of 10 or less. It passes at or below `c2Budget`. If step 2's figures already triggered Phase 2, it passes at or below step 2's figure, and step 6 then brings it under `c2Budget`.

## review:bar #12 [should-fix] s3-r26-draft.md:45 (item 1, the UNCONFIRMED rule), as it applies to items 2-4 (:48-86)

**Conflicts with:** integrate-c21.md:558-573 (its unconfirmed list)

**Evidence:**
Draft :45: "What `integrate-rr21.md` marks UNCONFIRMED, confirm in the code or by a probe. Where it is false, use the simplest change that keeps D1–D12, and record it."
Items 2-4 implement integrate-c21.md, but no item gives a rule for its unconfirmed list. That list includes:
- "That locations.keys ⊆ ids";
- "That no reachable shape binds an id the job no longer holds, which would make the `job.assets.contains` mutant of C3 Equivalent";
- "That T5, T-FL, T1-space and manyMovesTurns at k = 256 can be built";
- "That in-place mutation through Dictionary's _modify ... avoids the copies";
- "That no existing test depends on the order of resumes or of group completions (C2)".
Only the last is covered (:84), and only for resumes. The verifiers cannot tell whether a claim left unconfirmed is a finding.

**Suggested:**
- **What `integrate-c21.md` marks unconfirmed** (items 2-4) follows the same rule. Confirm each claim in the code or by a probe. Where one is false, use the simplest change that keeps K1–K4, I1–I3 and P1–P3, and record it. List any claim left unconfirmed in the draft, with the reason.

## review:bar #13 [should-fix] s3-r26-draft.md:38 (item 1, "Measure every one"), against :148-154 (item 9's inventory)

**Conflicts with:** Item 9's O(1) exemption (s3-r26-draft.md:154); integrate-rr21.md:518, :545, :551 and :1039; S3-R25 item 2 (s3-rulings-s3f.md:342)

**Evidence:**
- :38: "The other BenchSync cases in `integrate-rr21.md`'s pins are item 9's inventory figures. Measure every one; a miss is blocking". :154: "a BenchSync figure at 10,000 ids in its worst grouping unless it is O(1) amortised per id."
- integrate-rr21.md:545: "groupDelistedAll ... This pins C10's in-place updates". Those updates are O(1) amortised per id. So item 1 says to measure the case, and item 9 exempts it.
- :152 lists item 1's rows as "the owed re-routes' replay, and every walk over owed items". It leaves out each site's own-turn work: the collect pass and trims, site 2's take-off, site 3's item build, the run-claim release, and the adopt turn's layer pass. integrate-rr21.md:551: "The adopt turn's pass is O(E + in-flight)".
- integrate-rr21.md:1039 (C5): "Measure supersededRerouteTurns, supersededUserTurns and runSuperseded." supersededUserTurns is not among the pins (:517-557), and the draft never names it. supersededRerouteTurns is the group shape only (:518). Yet S3-R25 item 2 (rulings:342) puts "one user waiter per id" inside the reference set.

**Suggested:**
Item 1:
- The other BenchSync cases that `integrate-rr21.md` names, in its pins or its commit_plan, are item 9's inventory figures. They include `supersededUserTurns`. Measure every one, O(1) rows included. A miss is blocking (S3-R16 1(f), with S3-R23 item 3's load rule).

Item 9, a new bullet:
- each RR-21 site's own turn: the collect pass and trims, the take-off, site 3's item build, the run-claim release, and the adopt turn's layer pass (item 1).

## review:bar #14 [should-fix] s3-r26-draft.md:46 (item 1, "Residual risks"), and item 10's accepted orders (:160-163)

**Conflicts with:** integrate-rr21.md:604-626 (the residual_risks that answer 6 does not class)

**Evidence:**
Draft :46: "`integrate-rr21.md`'s residual_risks, in the classes item 12's answer 6 gives." Answer 6 classes only rulings 1-7. integrate-rr21's residual_risks also hold these entries:
- "(asset, token) order" and "Site 2 has two orders for one shape", in order and place (:604-607);
- "The bulk release lowers outstanding.count during the window", in order and timing (:609-610);
- "Owed run items of a run that a purge cancelled", in timing, with "That finishRun removes them is UNCONFIRMED" (:611-612);
- admissions waiting for owed batches, and memory (:615-618);
- k tokens per id: "What would make it blocking: commitTwoTokensTurns ... missing c2Budget" (:622-624);
- "Every C2 figure ... stays open ... A miss is blocking under S3-R16 1(f)" (:625-626).
Answer 6 gives none of these a class. Item 10's "Accepted orders" (:160-163) also leaves out item 1's orders. The last two entries carry blocking conditions, yet the draft's wording files them as residual risks.

**Suggested:**
- **Residual risks:** `integrate-rr21.md`'s residual_risks, each in the class that file gives it, with the condition that would make it blocking. Where answer 6 differs, answer 6 decides. Record each in the draft with its test or probe.
- Its order entries (the (asset, token) order; site 2's two orders) join item 10's accepted orders.
- Its C2 entries (k tokens per id; the open figures) are gates, not residual risks. A miss is blocking (S3-R16 1(f)).

## review:bar #15 [should-fix] s3-r26-draft.md:105 (item 5, "Probe two candidates")

**Conflicts with:** S3-R16 item 1 (s3-rulings-s3f.md:151: "Blocking, in either `LaneDropVisit` order"); S3-R19 item 1 (s3-rulings-s3f.md:238)

**Evidence:**
Draft :105: "Each is blocking only if its probe, in both orders, breaks S3-R16 item 1." Draft :97: "The window exists only in `sweepFollowsFirst`." analyse-g4-reach.md:72: "In both shapes the window exists only in sweepFollowsFirst."
Read as "breaks in both orders", :105 means neither candidate can ever be blocking, because `followVisitedFirst` has no window.
S3-R16 item 1 (rulings:151) makes a break blocking "in either `LaneDropVisit` order". The draft cites S3-R19 item 1 (rulings:238), which says "a probe in both `LaneDropVisit` orders shows S3-R16 item 1 broken". There, the probe runs in both orders, and one break is enough.

**Suggested:**
- **Probe two candidates while you build the shapes** (S3-R19 item 1). Run each probe in both orders. A probe that breaks S3-R16 item 1 in either order is blocking. Both windows exist only in `sweepFollowsFirst`, so a break there is enough. If one breaks, P3 applies: the failing test first, then the fix.

## review:bar #16 [nit] s3-r26-draft.md:116 (item 6)

**Conflicts with:** EngineFollow.swift:390-399 at 8e1fb24 (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f)

**Evidence:**
Draft :116: "delete `EngineFollow.swift:390-398`." At 8e1fb24, `if spawned == nil {` is at :390, and its closing brace is at :399. The function's own closing brace is at :400. Deleting 390-398 leaves a stray `}`.
critic-defer-bucket.md:21 and :34, and design-fixer.md:62, cite 390-399. The verifiers' issues (reqs #5, correct #7) cite 390-398.

**Suggested:**
- delete the `if spawned == nil { ... }` block (`EngineFollow.swift:390-399`).

## review:bar #17 [nit] s3-r26-draft.md:1 (header)

**Conflicts with:** The header form of every earlier ruling (for example s3-rulings-s3f.md:304, "2026-11-01 21:35")

**Evidence:**
Draft :1: "## Orchestrator ruling added 2026-11-02 HH:MM". The time placeholder is unfilled.

**Suggested:**
Replace HH:MM with the time at which the ruling is appended.

## review:bar #18 [nit] s3-r26-draft.md:60, :71 and :133 (items 3 and 7)

**Conflicts with:** The draft's own cross-references

**Evidence:**
Draft :60: "B1–B13, the clauses I1–I3". :71: "B8, I2 and T5 are item 7." :133: "It does break I2 (...), the clause item 3 adds." Each item points to the other one for I2.

**Suggested:**
Item 3: "B1–B13 and the clauses I1–I3, except B8, I2 and T5, which are item 7." Item 7: "It does break I2 (every interest's ids lie in `Job.assets`), the clause that item 7 adds with B8."

## review:bar #19 [nit] s3-r26-draft.md:192 (answer 12.1), and the T labels at :34-35, :55, :71, :134-137 and :239

**Conflicts with:** The labels of integrate-c21.md and integrate-rr21.md

**Evidence:**
In :192, "B8's re-insertion" is integrate-c21's item B. "B6–B9" in the same sentence come from integrate-rr21's branches table (integrate-rr21.md:937-948): B6 and B7 are site 2's decision, and B8 and B9 are the take-off.
"T1" is integrate-c21's item A test at :55, and integrate-rr21's test at :34-35. "T5" is integrate-c21's item B test at :71 and :134-137, and integrate-rr21's pin test (integrate-rr21.md:972: "T5 (pin holds)").

**Suggested:**
Prefix each label with its spec the first time an item uses it: c21-B8, rr21-B6–B9, c21-T1, rr21-T1, c21-T5.

## review:bar #20 [nit] s3-r26-draft.md:38 and :145

**Conflicts with:** S3-R25 item 3 (s3-rulings-s3f.md:353); S3-R23 items 2 and 3 (s3-rulings-s3f.md:297-301)

**Evidence:**
Draft :38: "a miss is blocking (S3-R16 1(f))". :145: "A miss is blocking (S3-R25 item 3)."
S3-R25 item 3 (rulings:353): "blocking only if a probe shows a turn over `c2Budget` at a 1-minute load of 10 or less."
S3-R23 (rulings:297-301): a miss seen only above a load of 50 is not blocking by itself. A case "not measured at a quiet load" is "neither confirmed nor blocking".

**Suggested:**
"A miss at a 1-minute load of 10 or less, best of 3, is blocking. Otherwise S3-R23 items 2 and 3 apply."

## review:bar #21 [nit] s3-r26-draft.md:98 (item 5)

**Conflicts with:** Item 11's order (s3-r26-draft.md:174, :183); integrate-rr21.md:1004 (B30)

**Evidence:**
Draft :98: "the test reaches `EngineFollow.swift:1261` in `sweepFollowsFirst`". At 8e1fb24, :1261 is the `return nil` under `case .queued, .blocked, .downloading:`.
Step 5 (item 1) refactors this into `waitingTarget(_:epoch:)` (integrate-rr21.md:1004, B30). Item 5 runs at step 7 (:183), so by then the line will have moved.

**Suggested:**
"the test reaches `waitingTarget`'s `.queued, .blocked, .downloading` arm in `sweepFollowsFirst` (`EngineFollow.swift:1260-1261` at `8e1fb24`; re-cite it after step 5)"
