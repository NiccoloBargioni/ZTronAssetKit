# review2:resolved

Verdict: 33 of the 42 findings are fully resolved; eight more are resolved only in part or with a new gap, reported below as five should-fix findings (answer 12.1's closed list, idle-guard path changes outside the idle and ledger tests, R4's `refused ||` mutant, a miss that outlives Phase 2, and answer 12.8 against item 5's rr21-T8b fallback); and review:bar #17's HH:MM header placeholder is still unfilled.

## review2:resolved #1 [should-fix] review:bar #8 and review:spec #8: s3-r26-draft.md:239 (item 12's answer 1), with :275 (answer 6.6) and :53 (RR21-RUN-MIDDRAIN). Files are in /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/.

**Problem:** Answer 1 now amends S3-R24 item 3 'for these branches only', but its list leaves out two kinds of branch that exist only in sweepFollowsFirst: the chunking's branches, for which answer 6.6 asks only 2/2 in sweepFollowsFirst, and rr21-B26 if RR21-RUN-MIDDRAIN cannot run in followVisitedFirst. Read literally, both must be reached in both orders, which cannot be done.

**Evidence:**
Draft :239: 'This covers item A's bucket branches, B8's re-insertion, item 5's case and item 1's site-2 branches (rr21-B6 to rr21-B9, RR21-VERDICT-ZERO). ... This amends S3-R24 item 3's "Reached", and S3-R25 item 7, for these branches only. Every other branch keeps S3-R24 item 3 unchanged.'
Draft :275 (answer 6.6), on the chunking: 'Add the chunking's branches to the branches table, each with a test that kills its drop-mutant 2/2 in `sweepFollowsFirst`.' The chunking acts on the moved-before state, which arises only in sweepFollowsFirst (integrate-rr21.md:380, :939). Its branches are not rr21-B6 to rr21-B9.
Draft :53 makes RR21-RUN-MIDDRAIN a blocking fix. integrate-rr21.md:994: 'B26 checkRunSettled `reroutesWaiting == 0`. Reached: RR21-RUN-MIDDRAIN (both orders UNCONFIRMED; otherwise a #require).' integrate-rr21.md:906 lists 'RR21-RUN-MIDDRAIN in followVisitedFirst' as unconfirmed.
Answer 1 opens with a general rule (:234 'A branch whose state arises only in `sweepFollowsFirst`'), but :239 then names a list and says 'these branches only'. One verifier will read the rule as general; another will hold to the list and report the chunking's branches, or rr21-B26, as unreached.

**Suggested:**
Answer 1, second paragraph, first sentence:
- This covers every branch whose state arises only in `sweepFollowsFirst`. Among them are item A's bucket branches, B8's re-insertion and item 5's case. Item 1's are its site-2 branches (rr21-B6 to rr21-B9, RR21-VERDICT-ZERO, and the chunking's if it is built), and rr21-B26 if RR21-RUN-MIDDRAIN's state cannot arise in `followVisitedFirst`.

Answer 6.6:
- Add the chunking's branches to the branches table. Each gets a test that meets item 12's answer 1.

## review2:resolved #2 [should-fix] review:bar #2 and review:spec #11: s3-r26-draft.md:54-57 (item 1, 'Existing tests that change path') and :272 (answer 6.5)

**Problem:** The lead sentence says the idle guards can change the paths of the six low-budget suites, but neither remedy covers that case. The one-to-one update covers the suites only for changes through the fit charge and the reservation. The narrow fallback is open only to idle and ledger tests. A suite, or any other test, whose path the broad guard changes can be neither updated nor fixed by the fallback.

**Evidence:**
Draft :54: 'The fit charge, site 2's reservation and the idle guards can change the path of existing tests: the six low-budget suites, and the idle and ledger tests that `integrate-rr21.md`'s plan_gaps names.'
:56: 'An idle or ledger test that changes path takes answer 6.5's narrow fallback first.'
:57: 'A low-budget suite whose turn count or order changes through the fit charge or the reservation may be updated one to one'.
:272 (answer 6.5): 'Fall back to `reroutesWaiting > 0` only if an existing idle or ledger test changes path, and record why.'
integrate-rr21.md:860: 'The six low-budget suites can change path through the fit charge, site-2 reservation or the idle guards'. Which tests change path is unconfirmed (integrate-rr21.md:907).
The broad guard keeps every binding while any event waits, so it acts during every barrier, not only RR-21's. v1's catch-all (v1 :44) is gone, and so is the 'any other test' bullet that review:spec #11 suggested. The fixer may read :54 as extending :57 to idle-guard causes, while the verifier holds to :57's two causes.

**Suggested:**
Item 1, 'Existing tests that change path', replace the second bullet:
- An existing test whose path changes through `pruneBoundContent`'s or `hasWork`'s idle guard takes answer 6.5's narrow fallback first. This holds for the idle and ledger tests, the six suites and any other test.
- If it still changes path, its assertions stay. Only the steps that reach them may change, for example releasing the owed drain turns before the idle assertion.

Answer 6.5:
- Fall back to `reroutesWaiting > 0` only if an existing test changes path through these two guards, and record why.

## review2:resolved #3 [should-fix] review:spec #2: s3-r26-draft.md:96-103 (item 4, C1 in R4's form, and the mutant list that replaces N3)

**Problem:** The new mutant list replaces all of N3, including its rows of Equivalent mutants. In R4's prescribed form, the counterpart of N3's 'dropping `!refused`' is dropping `refused ||`, and that mutant is not Equivalent. The collect pass is unsorted, so no test kills it deterministically. The ruling neither lists it nor gives the fixer a way to kill it.

**Evidence:**
Draft :98: 'for a deferred id, `refused = refused || captured.contains(a)`, with `captured` lazy'. Draft :101-103: 'R4's mutants replace `integrate-c21.md`'s N3', followed by three mutants: refused never set; refused set for moved-away ids; refused set without `captured.contains`.
N3 also held integrate-c21.md:421: 'Building `captured` eagerly, and dropping `!refused`, are Equivalent.' That holds for c21's guard form, where setting `refused = true` twice is harmless.
In R4's form, dropping `refused ||` gives `refused = captured.contains(a)`, so `refused` keeps only the last deferred id's capture. Consider a commit that holds both a captured and an uncaptured deferred id (rr21-T3-captured's and T-R2's shapes together). If the captured id comes first, the F-20 hold is lost, so the mutant is not Equivalent.
integrate-rr21.md:96: 'Collect pass: one scoped, unsorted read of the interests.' Which deferred id is last therefore changes from run to run.
The verifiers drop single disjuncts (/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c19/reqs/mut.py:44-52, laneVisitedCarriedDrop and findInboundPendingDrop). Item 9 also applies S3-R25 item 10 to this changed line. Yet the ruling's list implies the mutant does not exist.

**Suggested:**
Item 4, C1, second sub-bullet:
- for a deferred id, `if !refused, captured.contains(a) { refused = true }`, with `captured` lazy. This is R4's predicate in N3's guard form.

Add to the list after 'R4's mutants replace `integrate-c21.md`'s N3':
- building `captured` eagerly, and dropping `!refused`, stay Equivalent (N3): setting `refused` twice changes nothing.

## review2:resolved #4 [should-fix] review:spec #6 and review:spec #3: s3-r26-draft.md:82-83 (item 3, the merge gate's step-6 path) and :111-114 (item 4, what follows Phase 2)

**Problem:** Only two misses that outlive Phase 2 have an outcome: commitRerouteWaitersTurns and groupStalledSubscriber. integrate-c21's 'Otherwise, report to the orchestrator', which review:spec #6 quoted as dropped, has still not come back. On item 3's step-6 path Phase 2 is already in place, so 'If it still fails, Phase 2 is triggered' leads nowhere.

**Evidence:**
Draft :82: 'If step 2's figures already triggered Phase 2, check the gate at step 6 instead, with Phase 2 in place.' Draft :83: 'If the gate fails, build the index lazily ... and re-measure. If it still fails, Phase 2 is triggered (item 4).'
Draft :111-113: 'Phase 2 lands at step 6 in every case.' / 'A `commitRerouteWaitersTurns` miss that stays with Phase 2 in place belongs to item 1. Report it with its figures.' / 'A `groupStalledSubscriber` miss takes `SubscriberQueue.reserveCapacity`'.
integrate-c21.md:375: 'For groupStalledSubscriber the contingency is SubscriberQueue.reserveCapacity. Otherwise, report to the orchestrator.' review:spec #6 quoted both sentences as dropped. Only the first is back.
So nothing says what to do when, with Phase 2 in place (and, for the gate, the lazy index), one of these still misses: the in-actor `.waiters` turn, a heartbeat, commitWaitersBoundTurns or item 3's merge gate. One fixer will design another fix under S3-R5. Another will stop and report.

**Suggested:**
Item 3, the merge gate, second sub-bullet:
- If the gate fails, build the index lazily, at a job's first move off it (contingency (ii) in `critic-move-index.md`), and re-measure.
- If it still fails at step 4, Phase 2 is triggered (item 4).
- If it still fails at step 6, item 4's last rule applies.

Item 4, after the `groupStalledSubscriber` bullet:
- Any other miss that stays with Phase 2 in place, item 3's merge gate included, is reported to the orchestrator with its figures and loads (`integrate-c21.md` C12). It stays blocking (S3-R16 1(f)).

## review2:resolved #5 [should-fix] review:spec #10: s3-r26-draft.md:142 (item 5, probe (i), the new fallback), against :294-295 (item 12's answer 8)

**Problem:** The new fallback lets rr21-T8b reach item 5's case, and it cites answer 8 for that. But answer 8 says item 5's 'Reached' needs only item 5's own test, which reaches the case through the InboundMove caller, and that rr21-T8b belongs to item 1. If the fallback is taken, verifiers can judge item 5 two ways.

**Evidence:**
Draft :142: 'If the fix removes the test's only path, reach the case with Shape A, or through rr21-T8b's pin caller (item 12's answer 8).'
Draft :294: 'Item 5's test reaches the case through the `InboundMove` caller, and rr21-T8b reaches it through the pin caller.' Draft :295: 'Item 5's "Reached" needs only item 5's test. rr21-T8b belongs to item 1.'
The fallback is taken when Shape A does not compose and (i)'s fix removes Shape B's only path. Then no item-5 test is left on the case. One verifier counts rr21-T8b for item 5 by :142. Another reads answer 8 as tying item 5's 'Reached' to its own test, finds item 5 unreached, and reports it blocking (S3-R24 item 3).

**Suggested:**
Answer 8, second bullet:
- Item 5's "Reached" needs only item 5's test, and rr21-T8b belongs to item 1.
- If item 5's fallback (probe (i)) leaves item 5 with no test on the case, rr21-T8b's 2/2 kill of the fold mutant counts for item 5's "Reached" too. Record that in the draft.

# review2:fresh

Verdict: Not ready to append. Three problems block it. Answer 12.1's closed list contradicts answer 6.6, and it leaves some sweep-only branches needing a kill in both orders that cannot exist. The merge gate and Phase 2 send concentrationPublicationTurns and groupStalledSubscriber misses to a Phase 2 that defers nothing in those shapes. Probe (ii) can turn blocking while an adopted must_not forbids its only fix. Seven should-fix gaps come on top of these.

## review2:fresh #1 [must-fix] s3-r26-draft.md:239 (item 12, answer 1, last paragraph), with :130, :138 and :275

**Problem:** The rewrite made answer 1 a closed list ("for these branches only"). It leaves out branches that the ruling itself says arise only in sweepFollowsFirst. For those branches, "Every other branch keeps S3-R24 item 3 unchanged" demands a kill in both orders, and no such kill can exist. Answer 6.6 then demands the opposite for the chunking's branches.

**Evidence:**
- s3-r26-draft.md:239: "This covers item A's bucket branches, B8's re-insertion, item 5's case and item 1's site-2 branches (rr21-B6 to rr21-B9, RR21-VERDICT-ZERO). … This amends S3-R24 item 3's "Reached", and S3-R25 item 7, for these branches only. Every other branch keeps S3-R24 item 3 unchanged."
- s3-r26-draft.md:275 (answer 6.6): "Add the chunking's branches to the branches table, each with a test that kills its drop-mutant 2/2 in `sweepFollowsFirst`." These are new site-2 branches, not rr21-B6 to rr21-B9.
- s3-r26-draft.md:138: "Both windows exist only in `sweepFollowsFirst`, so a break there is enough. If one breaks, P3 applies: the failing test first, then the fix." A fix of probe (i) in relane's failed arm (:141, "while the attempt's end is recorded and the barrier is up") adds a branch whose state exists only there. "item 5's case" names only waitingTarget's arm.
- integrate-rr21.md:994: "B26 … Reached: RR21-RUN-MIDDRAIN (both orders UNCONFIRMED; otherwise a #require)". :464 says the same. :906 lists "RR21-RUN-MIDDRAIN in followVisitedFirst" as unconfirmed. If that shape cannot be built, :239 now forbids the #require.
- integrate-rr21.md:347 states the rule in general: "Where a shape's state arises only in sweepFollowsFirst, a per-order #require pins its absence in followVisitedFirst".
- s3-rulings-s3f.md:323 (S3-R24 item 3): "Reached. A test reaches it in both `LaneDropVisit` orders and kills its drop-mutant 2/2."

**Suggested:**
This covers every branch whose state arises only in `sweepFollowsFirst`. The draft lists each one, with its citation or its `#require`. They include:
- item A's bucket branches and B8's re-insertion;
- item 5's case, and any branch that a fix of its probes adds;
- item 1's site-2 branches (rr21-B6 to rr21-B9) and, if built, the chunking's branches (answer 6.6);
- rr21-B26, if RR21-RUN-MIDDRAIN cannot reach it in `followVisitedFirst`.

For such a branch, "2/2 in each order" or "2 out of 2 times in both orders" in either specification means 2/2 in `sweepFollowsFirst`. A-T1's pin is one example. This amends S3-R24 item 3's "Reached", and S3-R25 item 7, for these branches. A branch that `followVisitedFirst` can reach keeps S3-R24 item 3 unchanged.

## review2:fresh #2 [must-fix] s3-r26-draft.md:82-84 (item 3, merge gate) and :105-113 (item 4, Phase 2)

**Problem:** The ruling sends misses to Phase 2 that Phase 2 cannot change.
- Phase 2 defers only waiter and ensure answers, and only for a job with more than answersPerTurn (512) interests.
- concentrationPublicationTurns is both the merge gate's case and item 4's own blocking case. It has one prefetch group and one waiter, so Phase 2 owes nothing there. groupStalledSubscriber and manyGroups are the same.
- Following the text, a fixer builds Phase 2 for these misses. Through :82, it also puts the gate and the lazy-index decision off until after RR-21 is built on the eager index.
- The final figure then still misses (:84), with no route left: the rewrite dropped integrate-c21.md's "Otherwise, report to the orchestrator".
- Deferring the gate to step 6 also merges B at step 4 without its gate. B's must_not, which :77 adopts, forbids that.

**Evidence:**
- s3-r26-draft.md:82: "If step 2's figures already triggered Phase 2, check the gate at step 6 instead, with Phase 2 in place."
- s3-r26-draft.md:83: "If it still fails, Phase 2 is triggered (item 4)."
- s3-r26-draft.md:84: "B lands either way. … the final figure is what the verifiers judge."
- s3-r26-draft.md:107: "after Phase 1, any heartbeat is above `c2Budget`"
- s3-r26-draft.md:108: "item 3's merge gate fails even with the lazy index"
- s3-r26-draft.md:113: "A `groupStalledSubscriber` miss takes `SubscriberQueue.reserveCapacity`"
- design2-commit-window.md:105: "resolveAll … computes `let owe = job.interests.count > self.tuning.answersPerTurn`"
- critic-commit-window.md:101: "prefetch groups and runs owe nothing"
- integrate-c21.md:447: "Do not defer the broadcasts or the binding."
- Tests/ZTronAssetKitBenchmarks/BenchSync.swift at 8e1fb24: :3131 is one `awaitAsset(o.identifier, lane: .userInitiated)` waiter, and :3135 is `registerGroup(old.map(\.identifier), lane: .prefetch)`, one 10,000-member group. That makes two interests on O.
- critic-commit-window.md:44: "Phase 2 cannot help that shape: a single interest is never over answersPerTurn, so nothing is owed."
- critic-commit-window.md:112-113: "a contingency Phase 2 cannot cover … If groupStalledSubscriber still misses, put S >= 1 to the orchestrator."
- integrate-c21.md:375: "For groupStalledSubscriber the contingency is SubscriberQueue.reserveCapacity. Otherwise, report to the orchestrator." The ruling does not carry this over.
- s3-r26-draft.md:77 adopts "its must_nots". integrate-c21.md:290: "do not merge without the merge gate".

**Suggested:**
The merge gate:
- Check it at step 4 in every case: `concentrationPublicationTurns` with the index in place, best of 3 at most `c2Budget` at a 1-minute load of 10 or less (`critic-move-index.md` A1).
- If it fails, build the index lazily (contingency (ii)) and re-measure.
- B lands either way, so the gate is measured before B merges, not passed. A miss that stays is blocking (S3-R16 1(f)). Report it to the orchestrator with its figures and loads.

Phase 2 (C12):
- Phase 2 defers only waiter and ensure answers, and only for a job with more than `answersPerTurn` (512) interests. It cannot cut `concentrationPublicationTurns`, `groupStalledSubscriber` or `manyGroups`, and it is never their remedy.
- It applies if any of these holds, each best of 3 at a 1-minute load of 10 or less:
  - after Phase 1, the in-actor `.waiters` commit turn is above 7.0 ms;
  - after Phase 1, the heartbeat of `.waiters` or `waitersStalledSubscriber` is above `c2Budget`;
  - at rr21-C3, `commitWaitersBoundTurns` or `commitRerouteWaitersTurns` is above `c2Budget`, in the commit's own turn or in its heartbeat.
- A `groupStalledSubscriber` miss takes `SubscriberQueue.reserveCapacity`.
- Some misses stay: one that Phase 2 cannot cut, or one that remains with Phase 2 or `reserveCapacity` in place. Such a miss is blocking. Report it to the orchestrator with its figures and loads (`integrate-c21.md:375`), and go on with the other steps.

## review2:fresh #3 [must-fix] s3-r26-draft.md:138-145 (item 5, probe (ii))

**Problem:** Suppose probe (ii) shows a difference and no SPEC MUST covers it.
- The ruling makes it blocking, and "P3 applies" demands a fix.
- The ruling gives no place for that fix, and the must_not that item 1 adopts forbids fixing the waitingTarget window this cycle.
- Only probe (i)'s fix is cleared of that must_not.
The fixer cannot both fix the blocking difference and keep the must_not.

**Evidence:**
- s3-r26-draft.md:138: "A probe that breaks S3-R16 item 1 in either order is blocking. … If one breaks, P3 applies: the failing test first, then the fix."
- s3-r26-draft.md:141, for (i) only: "It is not a fix of the `waitingTarget` window under `integrate-rr21.md`'s must_not."
- s3-r26-draft.md:143-145: "(ii) The later-apply variant. … If the answers differ, S3-R17 decides: … otherwise the difference is blocking."
- s3-r26-draft.md:31 adopts "its must_nots". integrate-rr21.md:586: "Do not fix replayJoin's approximation or the waitingTarget window this cycle, unless ruling 4's probe breaks; then add only the .join layers."
- analyse-g4-reach.md:54-57 places (ii) in that window: "ENOENT window with a later apply C2 that maps x to U while T still publishes … With the drop: H's visit moves x under C2 onto U … If T's fresh attempt fails terminally, x gets a different answer."

**Suggested:**
- If (ii) is blocking, fix it with the smallest change that makes the probe's answers equal visit-first's in both orders. Commit the failing test first, then the fix.
- That fix may change the `waitingTarget` window. This lifts `integrate-rr21.md`'s must_not for that fix only.
- Record the design, its tests and its branches (answer 1).

## review2:fresh #4 [should-fix] s3-r26-draft.md:104-109 (item 4) and :218 (item 11, rr21-C3)

**Problem:** Committed's rewrite at rr21-C3 changes the commit turn of every shape, and its trims release index entries. The specification says to re-check B's merge gate and C's Phase 2 trigger at that point. The ruling re-checks only the two new RR-21 cases.

"After Phase 1" can mean "right after step 2" or "at any point after Phase 1". So the fixer may not re-measure concentrationPublicationTurns or commitTurns until item 9's final re-measure. By then no route is left, and the verifiers judge that final figure (:84).

**Evidence:**
- s3-r26-draft.md:104: "Measure first, right after Phase 1: `concentrationPublicationTurns` and `commitTurns(.waiters)`."
- s3-r26-draft.md:109: "at rr21-C3, `commitWaitersBoundTurns` or `commitRerouteWaitersTurns` is above `c2Budget`"
- s3-r26-draft.md:218 (rr21-C3) only "re-measures the commit and drain turns".
- integrate-rr21.md:862: "B's merge gate (concentrationPublicationTurns with the index) must be re-measured after committed's rewrite, because the trims now release index entries through subtractAssets."
- integrate-rr21.md:863: "C's Phase 2 trigger must be re-checked after site 1."
- integrate-rr21.md:1035: "re-check C's Phase 2 trigger and B's merge gate".
- integrate-rr21.md:539: "re-measure C's commitTurns afterwards."

**Suggested:**
- After committed's rewrite, rr21-C3 also re-measures `concentrationPublicationTurns` (the merge gate) and every `commitTurns` shape. It takes the heartbeat and the in-actor turn, best of 3, with their loads.
- A miss there is decided as item 4 says: Phase 2 for a shape it can cut, otherwise a report to the orchestrator with the figures.

## review2:fresh #5 [should-fix] s3-r26-draft.md:32-33 (item 1, 'In short')

**Problem:** "The rest is owed" reads as a split: make up to inboundIDsNow re-routes at once and owe the remainder. In the specification, each site decides once. It makes all its re-routes at once, or it makes none at once and owes all of them.

The ruling decides wherever it differs from the specification (:18). So a fixer could build a split, and a verifier could hold the specification's pins against it. Also, "counting its own answers" applies to site 1 only.

**Evidence:**
- s3-r26-draft.md:32-33: "At sites 1 and 3, the site's own turn makes at most `inboundIDsNow` re-routes, counting its own answers. … The rest is owed as one `.reroutes(RerouteBatch)` event."
- integrate-rr21.md:108 (R4), all items: "When it owes: `resolveAll(…) { …; self.deferReroutes(items, from: transfer) }`"
- integrate-rr21.md:113-115 (R5): "`if let bound, pairs > bound` … call deferReroutes(items, from: transfer) instead of the loop". Site 3 counts pairs, not answers.
- integrate-rr21.md:132 and :136 (R7): "`let owes = off.ids > self.state.drainIDsLeft` … If it owes, return `.reroutes(self.oweReroutes(off.items, from: transfer))`"
- integrate-rr21.md:517, the pin setup: "the commit turn owes one batch and makes no re-routes".

**Suggested:**
- Each site decides once, in its own turn, whether it owes.
- If its work fits, it makes all its re-routes at once.
  - At sites 1 and 3 the bound is `inboundIDsNow`.
  - At the commit, the fit charge also counts the commit's own answers: `locations.count + items.count > inboundIDsNow`.
  - Site 2's turn is a drain turn and spends `drainIDsLeft`.
- If it owes, it makes none of its re-routes at once. It owes all of them as one `.reroutes(RerouteBatch)` event.

## review2:fresh #6 [should-fix] s3-r26-draft.md:94 (item 4)

**Problem:** Items 2 and 3 adopt their item's must_nots. Item 4 does not. Several of item C's must_nots appear nowhere else in the ruling, and they bind Phase 1's deliveries and Phase 2. A fixer may read the omission as deliberate, while a verifier who reads integrate-c21.md may still hold the fixer to them.

**Evidence:**
- s3-r26-draft.md:66: "A1–A13, the clauses K1–K4, its tests, its pins and its must_nots"
- s3-r26-draft.md:77: "with its tests, its pins and its must_nots"
- s3-r26-draft.md:94: "C0–C11 and C13, the progress-gate clause (P1–P3), its tests and its pins."
- integrate-c21.md:446-448: "Do not defer the answers behind the barrier. … Do not defer the broadcasts or the binding. Do not shortcut the deliveries through job.assets or interestCounts."
- integrate-c21.md:450: "do not change SyncTuning"
- integrate-c21.md:452: "Do not remove recordRunOutcome's `.committed` loop."

**Suggested:**
- **Implement Phase 1 of item C of `integrate-c21.md`:** C0–C11 and C13, the progress-gate clauses P1–P3, its tests, its pins and its must_nots. Its must_nots on Phase 2 bind step 6 too.

## review2:fresh #7 [should-fix] s3-r26-draft.md:60 (item 1) against items 2-4; :246-249 (answer 5)

**Problem:** Item 1 adopts RR-21's residual_risks, each with its class and record. Items 2-4 do not adopt integrate-c21.md's, and item 10 takes only some of them.

One of item A's pre-existing candidates is neither probed nor recorded. Answer 5 lists three candidates; A's residual_risks list a fourth, and it lies in item A's own code path. A verifier who probes it would be judging a fixer who was never told about it.

**Evidence:**
- s3-r26-draft.md:60: "Residual risks: `integrate-rr21.md`'s residual_risks, each in the class that file gives it…"
- integrate-c21.md:154-157: "Pre-existing candidates, recorded and unchanged by this item: … followAfterVerdict joins at once onto a job whose own verdict waits later in the queue;"
- s3-r26-draft.md:246-249 (answer 5) lists only "orphaned run claims…", "`recordRunOutcome`'s `outstanding[T] = nil`…" and "variant Y's T1 half".
- integrate-c21.md:456-469, C's residual_risks, is not adopted either. It covers the heartbeat behind resumed tasks, the per-id costs left unchanged, and pre-existing code that cannot run.

**Suggested:**
- **Residual risks of items 2-4:** record `integrate-c21.md`'s residual_risks for A, B and C as item 1 records RR-21's: each with its class and the condition that would make it blocking. Where this ruling places one (items 4 and 10), the ruling decides.
- Answer 5 gets a fourth candidate: `followAfterVerdict` joins at once onto a job whose own verdict waits later in the queue (`integrate-c21.md:157`). Probe it in step 1 with the other three.

## review2:fresh #8 [should-fix] s3-r26-draft.md:28 (preamble, 'UNCONFIRMED claims')

**Problem:** Both specifications mark every cost and time estimate UNCONFIRMED. The rule asks the fixer to confirm each one "in the code or by a probe" and, where one is false, to take "the simplest change". That competes with the routes the ruling names for misses: the lazy index, Phase 2, the chunking, reserveCapacity and the reports.

Its closed list of clauses also leaves out RR-21's new followBarrierViolations clauses and changed acceptances. Item 1 adopts them (:31), but they carry no names.

**Evidence:**
- s3-r26-draft.md:28: "Confirm each claim either specification marks UNCONFIRMED, in the code or by a probe. Where one is false, use the simplest change that keeps that specification's clauses (K1–K4, I1–I3, P1–P3, D1–D12), and record it."
- integrate-c21.md:560: "Every cost and time estimate, including the 6.3-9.1 ms commit figure…"
- integrate-rr21.md:904: "Every cost and time estimate: per-re-route cost, the take-off turn, …"
- s3-r26-draft.md:31: "its invariants (the new clauses and D1–D12)"
- integrate-rr21.md:270-293 holds the waiter and group acceptances, the run clause with no acceptance, and eight new clauses, from the owner of a waiter item to the counter.

**Suggested:**
- **UNCONFIRMED claims.** Confirm each claim either specification marks UNCONFIRMED, in the code or by a probe.
  - Where one is false, use the simplest change that keeps that specification's invariants (K1–K4, I1–I3, clauses P1–P3, and RR-21's acceptances, new clauses and D1–D12), and record it.
  - List in the draft any claim left unconfirmed, with the reason.
- A cost or time estimate is confirmed by its figure. A miss follows the route this ruling gives that figure (items 1, 3 and 4, answer 6.6). A miss with no route is blocking; report it with its figures.

## review2:fresh #9 [should-fix] s3-r26-draft.md:21, :28, :94 against :138, :171, :172, :226, :252; and :249

**Problem:** The Names rule keeps integrate-c21.md's progress-gate clauses as P1–P3, and :28 and :94 use the name that way. Five other places use a bare "P3" for CLAUDE.md P3 (the failing test first, then the fix). "P3 then applies" (:172) and "P3 applies" (:252) can be read as clause P3.

Answer 5's "variant Y's T1 half" also uses a bare T1. It is neither A-T1 nor rr21-T1: it is analyse-state-cost.md's prefetch-group token.

**Evidence:**
- s3-r26-draft.md:21: "its clauses K1–K4, I1–I3 and P1–P3, keep their names"
- s3-r26-draft.md:28: "(K1–K4, I1–I3, P1–P3, D1–D12)"
- s3-r26-draft.md:94: "the progress-gate clause (P1–P3)"
- s3-r26-draft.md:138: "If one breaks, P3 applies: the failing test first, then the fix."
- s3-r26-draft.md:171: "(P3, as item 11 defines it)"
- s3-r26-draft.md:172: "P3 then applies."
- s3-r26-draft.md:226: "(S3-R1, P3)"
- s3-r26-draft.md:252: "A probe that breaks S3-R16 item 1 is blocking, and P3 applies."
- s3-r26-draft.md:249: "variant Y's T1 half (item 7's stage 3)"
- analyse-state-cost.md:13: "T1, a prefetch group with member A".

**Suggested:**
Add to the Names rule:
- "P3" alone is CLAUDE.md P3: the failing test first, then the fix. Item C's progress-gate clauses are "clauses P1–P3".

At :249, write "variant Y's T1 half (item 7's stage 3). T1 is `analyse-state-cost.md`'s prefetch-group token, not a test."

## review2:fresh #10 [should-fix] s3-r26-draft.md:215 (item 11, step 5)

**Problem:** "rr21-C0 is step 0" maps rr21-C0 to the wrong point in the order. Step 0 is the baseline on 8e1fb24. rr21-C0 is the baseline after C Phase 1, A and B, and its 'before' figures isolate RR-21's own effect. A fixer could take the 'before' figures on 8e1fb24, while a verifier could expect them at the start of step 5.

**Evidence:**
- s3-r26-draft.md:215: "rr21-C0 is step 0, plus the 'before' figures of `concentrationCommitRerouteTurns` and `movedBeforeDrainTurns`"
- integrate-c21.md:519: "0 Baseline at 8e1fb24"
- integrate-rr21.md:1020-1022: "C0 Baseline on wp/s3f after C Phase 1, A and B. … Record 'before' figures for concentrationCommitRerouteTurns and movedBeforeDrainTurns".

**Suggested:**
- rr21-C0 opens step 5, on the HEAD after steps 2–4. It runs `verify.sh --quick` and takes the 'before' figures of `concentrationCommitRerouteTurns` and `movedBeforeDrainTurns`, best of 3, with their loads.
