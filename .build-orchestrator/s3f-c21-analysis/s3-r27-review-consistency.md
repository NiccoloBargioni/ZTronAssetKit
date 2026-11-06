# Review of the S3-R27 draft: verifier consistency

Lens: could two careful verifiers judge the same fixer work differently? Read-only. Nothing was built, run or measured.
Code is cited at `d5b2ab9` in `.worktrees/s3f` (I checked the HEAD and the citations with `git show`). The rulings file is
cited as `rulings:line`, the draft as `draft:line`.

What I read: the draft (all 184 lines); S3-R16, S3-R20 to S3-R26 in `s3-rulings-s3f.md`; d1 to d5 and the reviews of d1, d2
and d4; the fixer's `s3f.md` cycle-21 close ("Step 8" from :6610, "Not reached" and "Open at the close (cycle 21)" at
:6826); `integrate-rr21.md` (its residual risks and Own 8); `mut-c4fix.py`; and the code at every line the draft cites for
items 5 to 7.

## Verdict: CORRECTED

The draft routes every blocking item and every put-back (see the table at the end), and its citations for items 5 to 7
are accurate at `d5b2ab9`. But it has 16 places where two verifiers could reach different verdicts on the same work.
Most of them come from one source: almost every C2 figure it governs sits between 8.5 and 11 ms. At that margin the
rules this ruling leaves unsaid decide the outcome: which figure counts, which load, which run, and which base to diff
against.

The worst gaps are these:
- **MF-1.** No rule says how to read a figure that passes in one run and fails in another. Items 1 to 4 all depend on
  it.
- **MF-10.** Item 4's scope rule counts ids. Adding 9,998 unrelated ids to PROBE-C21-HOLDERS would put it back inside
  S3-R25's set as written. The rule also leaves standing S3-R26 item 1's gate on "a probe with very many tokens per id".
- **MF-11.** r8's mutant text also contains `!atEnd`. After the removal in item 5, the r8 mutant can no longer be
  applied as written.
- **MF-12.** "Exactly [512, 88]" holds for only one of T-A3's two `turns` arguments.

---

## Must-fix

### MF-1. A C2 figure at the edge has no reading rule (items 1–4, item 9)

**Where.** Item 1's decision rule (draft:50-53), item 2 (draft:61-69), item 3's pins (draft:83-89, :102), item 4
(draft:112-116), and item 9's margin list (draft:171).

**Problem.** Every case this ruling governs flaps around the gate:
- `waitersStalledSubscriber` measured 10.31, 10.45 and 11.09;
- `purgeWhileOwedTurns` measured 10.04 in one gate run, then 9.62 and 9.75 alone;
- PIN-APM measured 10.51 to 14.17;
- d3 estimates the k = 4 case at 9–10 ms.

The draft never says four things:
- **Which figure.** BenchSync gates the heartbeat (`BenchSyncCycle21.swift:145-157`), while S3-R26 item 4 and item 1's
  ".failed arm" take both the heartbeat and the in-actor turn. The two differ by about 0.005 ms, which matters at 8.5.
- **Which load reading.** The fixer used a "mean over SyncBenchmarks" next to "the case's own reading"
  (`s3f.md:6676-6677`).
- **Which run counts** when the fixer's gate run passes and a verifier's run fails, or the other way round.
- **Whether a passing re-run alone cancels a miss.** S3-R22 item 3 says "re-run it alone before reporting". The fixer
  read that as not cancelling (`s3f.md:6696-6698`), and S3-R26 item 4 treated a case that flaps as blocking.

So one verifier will call item 2 closed on a 9.8 ms run, and another will call it blocking on a 10.1 ms run at the same
load.

**Replacement.** Insert this as a new block after "How to read them" (after draft:24):

> - **How a C2 figure is read in cycle 22.** This applies to every case in items 1 to 4, and to every case that item 9
>   re-measures.
>   - **The figure** is the one the BenchSync case asserts. That is its heartbeat (longest wait), best of 3, unless
>     this ruling names the in-actor turn. The in-actor turn is recorded beside it.
>   - **The load** is the 1-minute load read just before the case's first timed run and just after its last. Both are
>     recorded. "At a load of 10 or less" means both readings are 10 or less.
>   - **A miss** is a best of 3 above `c2Budget` at a load of 10 or less, in any run of that case on the HEAD being
>     judged: the fixer's gate run, a re-run alone, or a verifier's run.
>     - A passing run does not cancel a miss.
>     - A case that misses in one such run and passes in another is reported as a miss, with both figures. This
>       follows the precedents of S3-R26 item 4's commit window and cycle 21's `purgeWhileOwedTurns`.
>   - **A miss seen only at a load above 10** follows S3-R23 items 2 and 3. If no run reaches a load of 10 or less,
>     the case is "not measured at a quiet load".
>   - **8.5 ms** is read on the same figure, under the same load rule. It decides only the routes this ruling makes
>     conditional on it. It is never a gate.

### MF-2. Figures that decide a route have no rule for a load above 10

**Where.** Six decisions depend on a figure:
- c1 (draft:28);
- c6 (draft:56);
- item 2's in-place batch (draft:64);
- A7 (draft:94);
- the group walks (draft:99);
- item 4's pair-counting trigger (draft:117).

**Problem.** S3-R26 item 11's rule for a deciding figure taken without a quiet load (rulings:643) names only Phase 2,
site 2's chunking and the merge gate. On a busy host, one verifier will accept a decision taken at load 14. Another will
call it unfounded.

**Replacement.** Add this to item 10, after its opening paragraph:

> - **A deciding figure without a quiet load.** S3-R26 item 11's rule applies to every figure that decides a route in
>   this ruling: c1 and c6 (item 1), the in-place batch (item 2), A7 and the group walks (item 3), and pair counting
>   (item 4).
>   - Decide on the best of 3 at the lowest load you get.
>   - Record it as "not measured at a quiet load", with its loads.
>   - The orchestrator re-measures it before close-out, and a different result reopens that decision.

### MF-3. The ruling does not say whether the reviews' should-fix items bind

**Where.** draft:22: "Each review corrects its report. Where a review and its report differ, the review wins."

**Problem.** Each review has must-fix and should-fix sections. The draft names some should-fix items and not others:
- d1: should-fix 2 to 7 and 9 are named; 1 and 8 are not.
- d2: should-fix 2 and 4 are named; 3, 5, 7 and 8 are not.
- d4: should-fix 2 and 3 are named; should-fix 1 is named only in part (MF-11); 4 and 5 are not.

Several unnamed items are obligations a verifier can check:
- d1 should-fix 8: c1's tests;
- d2 should-fix 3: the `waitUntil` audit before A2 and A5, a hang risk under 1(c) and 1(d);
- d2 should-fix 7: shutdown with read tasks still running;
- d2 should-fix 8: B2's `owing` default;
- d4 should-fix 5: W3's answer.

A verifier who reads "the review wins" as covering the whole review will report them as blocking. One who reads only
the named items will not.

**Replacement.** Insert after draft:22:

> - **What in a review binds.** A review's must-fix items bind, as this ruling corrects them. Its should-fix items bind
>   only where this ruling names them:
>   - d1 review: should-fix 2, 3, 4, 5, 7, 8 and 9;
>   - d2 review: should-fix 2, 3, 4, 7 and 8;
>   - d4 review: should-fix 1 to 5.
>
>   Every other should-fix item, and every "optional" in a report, is advisory. A verifier does not report its absence
>   as blocking.

(If the orchestrator binds these, item 1 needs d1 should-fix 8 (MF-6), and item 3 needs d2 should-fix 3, 7 and 8
(SF-3).)

### MF-4. "A blocking finding that this ruling names" is undefined, and so is precedence over S3-R16 to S3-R25

**Where.** draft:7 and draft:10-13.

**Problem 1.** The ruling is written before `s3f-c21-issues.json` exists, so it cites no "correct #n" or "reqs #n".
Literally, it names no finding.
- The cycle-21 verifiers will almost certainly report `waitersStalledSubscriber`, the purge, PROBE-C21-APM, the
  survivors and PROBE-C21-HOLDERS.
- One cycle-22 verifier will treat those findings as named, and so closed by this ruling's routes and decision rules.
- Another will treat them as unnamed, and so governed by S3-R16 and the general rulings. Under that reading,
  PROBE-C21-HOLDERS stays blocking under `integrate-c21.md` B's residual 5.

**Problem 2.** draft:7 says S3-R27 decides where it differs "from S3-R26, from a specification or from an analysis". It
does not say the same for S3-R16 to S3-R25. At least two parts of S3-R27 relax an earlier ruling:
- item 5's f7 fallback relaxes S3-R16 1(e) and S3-R24 item 3's "both orders";
- item 4's scope relaxes S3-R20 item 1 and S3-R21 item 1 ("Option (c) … is not available").

**Replacement.** Replace draft:7 with:

> **From cycle 22 on, S3-R27 is the cycle's ruling.** S3-R16 to S3-R26 still apply wherever S3-R27 does not change
> them. Where S3-R27 differs from an earlier ruling, from a specification or from an analysis, S3-R27 decides. The
> cycle-22 verifiers judge by S3-R16 to S3-R27.

Replace draft:12 with:

> - A verifier finding is **named** by this ruling when it reports the same case, mutant or `path:line` (at `d5b2ab9`)
>   as an item here.
>   - The fixer records the mapping ("correct #n → item k") in the draft's cycle-22 status list.
>   - A named finding is closed by its item's route and decision rule, even where the finding proposes another fix.

### MF-5. The bases for "red first" and for `covdiff` are still cycle 21's

**Where.** draft:173 ("S3-R26 item 11's rules") and draft:168 ("S3-R25 item 10, for every changed line and branch").

**Problem 1: red first.** S3-R26 item 11 says a test whose fix comes later "is run on `8e1fb24` in step 1"
(rulings:640). Carried over unchanged, that base is wrong for cycle 22.

**Problem 2: covdiff.** S3-R25 item 10 means "every line changed this cycle". The fixer's covdiff ran over
`8e1fb24..HEAD` (`s3f.md:6732`). A verifier who diffs from `8e1fb24` again will re-find cycle 21's 30 zero-count lines
and call the structural ones new. One who diffs from `d5b2ab9` will not.

**Problem 3: benchmarks.** The draft does not say whether a new BenchSync case that misses on `d5b2ab9` must be
committed red on its own. The precedent is `b4c215d`, the failing benchmark first. Without a rule, one verifier will
call a missing red commit a P3 break and another will not.

**Replacement.** Use this as the new opening paragraph of item 10:

> 10. *Order of work.* Commit each step on its own.
>     - S3-R26 item 11's red-first rules apply, with `d5b2ab9` in place of `8e1fb24`.
>     - A BenchSync case that misses on `d5b2ab9` is such a test: it is committed failing, on its own, right before
>       its fix, as `b4c215d` was.
>     - A case that passes on `d5b2ab9` lands with the step that adds it.
>     - Keep the draft's cycle-22 status list current, so that a resumed fixer continues from the HEAD.

And in item 9, replace "S3-R25 item 10, for every changed line and branch" with:

> - S3-R25 item 10, for every line and branch changed in `d5b2ab9..HEAD`. The cycle-21 dispositions in "Not reached
>   and structural lines (cycle 21)" stay listed, updated where this cycle changes them.

### MF-6. Item 1's test list leaves c3 and c1 without a stated kill

**Where.** draft:41-44: "Tests (each new branch's drop-mutant killed 2/2): T-A-1; T-A-2 …; T-A-3".

**Problem.**
- **c3's `allBound ||`** is a new branch, and no test is named for it.
  - Its drop-mutant ("always look up") is Equivalent.
  - The mutant that matters is the one that forces `allBound` to true. T-ORDER kills it only in `sweepFollowsFirst`
    (d1 review, Settled 3).
  - So it needs S3-R26 answer 1's citation explaining why `followVisitedFirst` cannot reach that state. Without it, one
    verifier counts the branch as reached and another calls it 1(e).
- **c1**, if taken, adds two arms that need T-C1-1 and T-PG4 (d1 review should-fix 8). d1 §3's table also requires a
  BenchSync case for c1's per-removal O(k) risk.
- **"Each new branch's drop-mutant"** misdescribes a1. a1's kills are "both flips of `replaced`, and dropping
  `isProgress`", not drop-mutants. It also omits that a2's reserve, the arm choice and c3's drop-mutant are Equivalent.

**Replacement.** Replace draft:41-44 with:

> - **Tests and kills** (d1 review, "The branches, and how each is killed"; S3-R16 1(e)):
>
>   | Branch | Kill |
>   |---|---|
>   | a1's compound `if` | T-A-1: both flips of `replaced`, and dropping `isProgress`, each 2/2 |
>   | a2's reserve and its guard | Equivalent (S3-R19 item 2), with the argument in the draft |
>   | `publishAll`'s hand-off `if let` | T-A-2, which asserts the hand-off directly inside `withCheckedContinuation`, 2/2 |
>   | `coalesced ? 1 : 0` | T-A-3, with one id already live in the stalled queue, 2/2 in both orders |
>   | c3's `allBound` | Forced to true: killed by T-ORDER (`EngineCommitWindowTests.swift:18-79`), 2/2 in `sweepFollowsFirst`, under S3-R26 answer 1. The draft cites why `followVisitedFirst` cannot reach the state: its visit removed zz-o5 from `job.assets` before the commit (d1 review, Settled 3). Dropped ("always look up"): Equivalent |
>   | c1's two arms, if taken | T-C1-1, with another job's `.transfer` key and a `.run` key in `lastEmitted`, and T-PG4, each 2/2. The arm choice is Equivalent |
>
>   T-A-3 asserts d1 §3's four checks. If c1 is taken, it is an inventory row (item 9) with a BenchSync figure: many
>   live progress keys and many job removals in one turn.

### MF-7. Item 1's figures, decision rule and optional c6 refer to figures nobody is told to take

**Where.** draft:46, :49, :50-53 and :56.

**Problem.**
- **"After each step"** is unclear, because the route is "in one step" (draft:28). Then "Report it with the per-step
  figures" (draft:53) has only one step to report.
- **Too few cases are measured.** The draft takes only `.waiters` and `.waitersStalledSubscriber`.
  - Yet c6 depends on "if `manyGroups` is still at the edge" (draft:56), and nothing measures `manyGroups`.
  - d1 review ("What the ruling must add", item 2) also asks for `.groupStalledSubscriber` and the two-subscriber case.
- **Which figure decides** is unstated: heartbeat or in-actor turn (see MF-1).
- **The ".failed arm" case** says "Take its own turn and its heartbeat" (draft:49) without saying which one is gated.

**Replacement.** Replace draft:46 with:

> - **Figures.** Take these on `d5b2ab9` (step 0), after the step, and after c1 if it is taken:
>   - `commitTurns(.waiters)`, `(.waitersStalledSubscriber)`, `(.groupStalledSubscriber)` and `(.manyGroups)`;
>   - `commitTwoStalledSubscribersTurns`.
>
>   Each is best of 3, heartbeat and in-actor turn, with loads. In this item, "the per-step figures" means these
>   figures together with the four variants of the scratch probe.

In draft:47-49, after "gated as C2", add: "The gate is the heartbeat, best of 3. The in-actor turn is recorded."

In draft:51, replace "At or below 8.5 ms" with: "`commitTurns(.waitersStalledSubscriber)`'s heartbeat, best of 3,
at or below 8.5 ms".

Replace draft:56 with:

> - **Optional margin: c6.** Add c6 (`guard !keys.isEmpty` at the top of `publishTerminal`, before the filter; d1 §3;
>   d1 review should-fix 6; Equivalent) only if `commitTurns(.manyGroups)` is above 8.5 ms after the step.

(See SF-1 on where c6 goes.)

### MF-8. Item 2 has no decision rule, an undefined trigger, an unspecified shape and a dependency on item 3

**Where.** draft:61-69, and draft:177-179 (step 4 runs before step 5).

**Problem.**
1. **No decision rule.** Nothing says what closes item 2, so one verifier closes it at 9.9 ms and another wants
   8.5 ms. Item 1 has a rule; item 2 does not.
2. **An undefined trigger.** "If the re-measured parts show the walk still copies the batch's items" has no pass
   condition. PROBE-C21-PURGE-PARTS times parts in milliseconds; it does not report copies.
3. **An unspecified shape.** "10,000 one-member prefetch groups" does not say whether they sit on 10,000 ids or on one
   id.
   - The estimate it cites, "17–33 ms … (d3 (c))", is d3 row 14's shape: "10,000 one-member groups on m", one id.
   - Item 4 puts one id with 10,000 holders outside the reference set.
   - So one verifier builds the one-id shape and calls a miss open-for-owner, and another builds 10,000 ids and calls
     it blocking.
4. **A dependency on item 3.** The jobs-side route is "d2's A3 and A3′" (`Group.dropMember`). That is item 3's code,
   which lands at step 5. Step 4 cannot reuse it.

**Replacement.** Replace draft:62-69 with:

> - **Route, in order, each part its own commit.** After each part, re-measure `purgeWhileOwedTurns` and
>   PROBE-C21-PURGE-PARTS, best of 3, with loads.
>   1. In `withdrawPurgedJoins`' owed-batch arm, read the purge's request before the copy lookup, so that a purge of
>      `.all` makes no lookup.
>   2. Only if `purgeWhileOwedTurns` is still above 8.5 ms after (1): mutate the owed batch in place, with no copy of
>      its items.
> - **Decision rule** (as item 1's):
>   - at or below 8.5 ms closes the item;
>   - 8.5 to 10 ms is recorded "at the edge", and is not blocking;
>   - a miss (as defined above) is blocking, reported with the parts' figures.
> - **The jobs' side** has no figure.
>   - Add two BenchSync cases for a purge of `.all` over 10,000 distinct ids, each id with its own content and job:
>     (i) one prefetch group of 10,000 members; (ii) 10,000 one-member prefetch groups.
>   - Time the purge's synchronous turn, best of 3, with loads. A miss is blocking (S3-R16 1(f)).
>   - The same purge over one id held by 10,000 groups (d3 (c) row 14's shape, estimated at 17–33 ms) falls under
>     item 4's scope. It is measured once and recorded for the owner.
> - **Its route is branch-free.** Use one `groups` access per member with no `Group` copy, and one jobs access per job.
>   - Where it needs `Group.dropMember` (d2's A3 and A3′), item 2 lands A3 and A3′ in this step, with d2 review M1's
>     obligation for the pending check. Item 3 then reuses them.
>   - A miss that stays is reported with its parts' figures, and it stays blocking.

### MF-9. Item 3: R1's status, PIN-APM-SPARE's pass condition, the integrity row, and "one change"

**Where.** draft:72, :80, :89, :96-98, :103 and :179.

**Problem.**
1. **R1's status is unclear.** It sits under "Pre-ruled orders" next to A7, which has an explicit "Apply it only if".
   R1 has no condition, but PIN-APM's shapes include "a run row (with R1)", and d2 review §4 lists R1 as step 11. One
   verifier will require R1; another will treat it as optional, like A7.
2. **PIN-APM-SPARE has no pass condition.** It "times `sparePresent`'s tail" but asserts nothing. The review (M4) says
   it should assert that the job was removed and should measure at the 404 end. Unlike PIN-APM, it can pass vacuously.
   Its misses also have no route: A7 and the group walks name only PIN-APM's shapes.
3. **The integrity path's first turn** is "an inventory row with a figure". The draft does not say whether that figure
   is a BenchSync case or a probe, or whether a miss is blocking.
4. **"One change" conflicts with the sub-step order.** draft:72 says "as one change", but draft:179 says "in d2 review
   §4's order", which is 11 sub-steps with a re-measure at sub-step 7. Verifiers will disagree on commit granularity,
   and on whether the sub-step 7 figures were owed.
5. **B1's "the site has one task" is not observable as written,** because the draft also says "no test seam". There
   is no stated way to observe it: `state.tasks` and `lastTaskKey` also move for other spawns in the same turn. d2
   review should-fix 2 asked for the read loop's drop-mutant kill instead.

**Replacement.**

Replace draft:80 with:

> - **B1's task.** B1 uses one owned task per answer site, with no batch bound and no test seam (review, should-fix 2).
>   - Its test holds the attempt, so that no other spawn happens in the answer turn.
>   - It asserts that every waiter is answered `.success`, that the invariants are clean, and that
>     `state.lastTaskKey` advances by exactly one across the answer turn.
>   - The drop-mutant of the read loop's call is killed 2/2.

Replace draft:89 with:

> - **PIN-APM-SPARE** times `sparePresent`'s tail at the 404 end, where the assets argument is the job's own set
>   (review M4).
>   - The timed span is `EngineFailures.swift:541-552`, factored into an internal function, together with the caller's
>     pump and `reconcileIdle`.
>   - Shapes: group, groups and users.
>   - After timing, it asserts that the job was removed. For users, every waiter must be `fromStore`; for groups, every
>     pending must be empty. A run in which an assertion fails is a failed case.
>   - A7 and the group walks apply to its groups and users shapes exactly as to PIN-APM's.

Replace draft:96-98 with:

> - **R1 is part of the route.** It lands at d2 review §4's sub-step 11. For a run row, make one progress offer with
>   the final count, where the per-id answers made an immediate offer and a trailing one.
>   - It changes no answer and no terminal event, and it keeps R-SYN-12. It is non-blocking, recorded as a residual
>     risk.
>   - Its row-kind branch is reached by a run-row answer-site test that kills its drop-mutant 2/2.
>   - PIN-APM's run-row shape is gated from that sub-step on.

Replace draft:103 with:

> - **The integrity path's first turn** (d2 review, §4 item 2) is an inventory row. It runs two 10,000-id sorts,
>   estimated at 6.5–7.5 ms (UNCONFIRMED).
>   - Give it a BenchSync figure at 10,000 ids, best of 3, with loads.
>   - A miss is blocking (S3-R25 item 3). Its route is not ruled here: report it with the figure.

Replace draft:72's "as one change" with "as one step (item 10, step 5)", and add:

> - **Sub-steps.** The step is committed in d2 review §4's sub-steps 1 to 11.
>   - A7 and the group walks run only under their own rules.
>   - PIN-APM's and PIN-APM-SPARE's figures are taken after sub-step 7 and at the end.
>   - The behaviour-free factoring of `answerSite` and of `sparePresent`'s tail lands first. PIN-APM and
>     PIN-APM-SPARE are then committed red, on their own (MF-5).

### MF-10. Item 4's scope can be flipped by padding ids, leaves S3-R26's k-tokens gate standing, and does not address S3-R20 and S3-R21

**Where.** draft:106-127.

**Problem.**
1. **The scope test counts ids, not interests per id.** The draft says the shape "has 2 ids, not 10,000, so it is
   outside S3-R25's reference set as written". S3-R25 defines the set as "10,000 ids however their interests are
   grouped" (rulings:342).
   - A verifier who builds PROBE-C21-HOLDERS with 9,998 unrelated ids beside it has 10,000 ids, inside the letter. It
     would still cost about 39 ms.
   - Two verifiers would then classify the same defect differently.
2. **In-letter k is not bounded.** d3 (c) row 12 estimates k = 4 at 9–10 ms and k = 5 at 11–12 ms (UNCONFIRMED).
   - A verifier who adds a fifth group over the same 10,000 ids has a "many groups" shape inside the letter. It would
     probably miss.
   - So the trigger "If any of them misses" at k = 2 and 4 is not the real decision. Any in-letter k triggers it.
3. **S3-R26's RR-21 gate is untouched.** S3-R26 item 1 (rulings:470) made `integrate-rr21.md`'s C2 residual a gate:
   "Its C2 entries (k tokens per id …) are gates, not residual risks: a miss is blocking."
   - That residual (`integrate-rr21.md:622-624`) says it becomes blocking on "a probe with very many tokens per id,
     missing c2Budget".
   - The draft replaces only `integrate-c21.md` B's residual 5. So a verifier who builds d3 row 5 or 6 (one id with
     10,000 holders, replayed at site 1 or 3, about 48 ms) still has a blocking finding under S3-R26 item 1, which
     still applies "wherever S3-R27 does not change it".
4. **S3-R20 and S3-R21 are not addressed.** S3-R20 item 1 says the orchestrator cannot waive C2 (rulings:255-257).
   S3-R21 item 1 says "Option (c), ruling the shape outside C2, is not available" (rulings:269). A verifier can read
   item 4 as option (c). The draft should say why it is not.
5. **No pass rule for d3's `manyHolders*` cases.** If pair counting is triggered, the draft takes "the BenchSync cases
   d3 names". d3 specifies them as "best of 3 ≤ `c2Budget`". Four of them (`manyHoldersMoveTurns`, `…OwedTurns`,
   `…TakeOffTurns`, `…CommitTurns`) are the out-of-scope shape. One verifier gates them, and another treats them as
   open-for-owner.
6. **The in-letter cases are underspecified.** The k = 2 and k = 4 measurements do not say:
   - whether they are committed BenchSync cases or scratch probes (S3-R23 item 3 asks for a BenchSync case per bound);
   - which figure counts (draft:115, "the follow's visit with its moves");
   - which HEAD decides. They get 'before' figures at step 0 and figures again at step 6, and items 1 to 3 may change
     them in between.

**Replacement.** Replace draft:106-117 with:

> - **Scope: the per-id dimension, sized for cycle 22**, as S3-R26 answer 4 sized the subscribers.
>   - For cycle 22, S3-R25's reference set is 10,000 ids with at most 4 interests on any one id. That covers one
>     prefetch group, many groups, one user waiter per id, and any mix with k ≤ 4 interests on every id.
>   - A shape with more than 4 interests on one id is "open, for the owner", however many ids it has. That includes:
>     - PROBE-C21-HOLDERS and any variant padded with other ids;
>     - d3 (c) rows 1 to 8 with one hot id;
>     - row 12 with k > 4;
>     - row 14 on one id.
>   - Such a shape is measured once and recorded with its figure and load. For cycle 22 it is neither accepted nor
>     blocking.
>   - The orchestrator puts the dimension to the owner, with d3 §3's sizing proposal, before it rules the close-out
>     converged.
>   - This is not S3-R20's or S3-R21's option (c). Those shapes had 10,000 ids, inside the letter. This ruling sizes a
>     dimension that no ruling had sized, as answer 4 did, and waives nothing (S3-R20 item 1).
>   - For shapes with more than 4 interests on one id, this replaces two conditions:
>     - `integrate-c21.md` item B's residual 5 ("blocking if a case with h near 10,000 misses `c2Budget`"), which
>       S3-R26 adopted with that file's residual risks;
>     - `integrate-rr21.md`'s residual "One id with k tokens costs k re-routes in one id slot", as S3-R26 item 1 made
>       it a gate ("a probe with very many tokens per id").
>
>     For k ≤ 4 both stay gates: `commitTwoTokensTurns` and the cases below.
> - **The in-letter shapes.** Commit BenchSync cases, named in the draft, at 10,000 ids with k interests on every id:
>   - k = 2: a user waiter and a one-member prefetch group per id;
>   - k = 4: four prefetch groups over the same ids (d3's `fourGroupsFollowTurns`).
>
>   For each, take three figures, best of 3, with loads:
>   - a follow's visit with its moves and its rest (the heartbeat);
>   - the drain's replay of an owed batch at site 1 (the drain turn);
>   - the same at site 3.
>
>   'Before' figures come from step 0. The deciding figures are taken in step 6, on the HEAD after step 5, and after
>   A1 and A2 if they are taken. A miss (as defined above) is blocking (S3-R16 1(f)).

In draft:117-120, after "the BenchSync cases d3 names", add:

> The in-letter cases (`fourGroupsFollowTurns`, the k = 2 cases, and `commitTwoTokensTurns`, re-measured) are gated.
> `manyHoldersMoveTurns`, `manyHoldersOwedTurns`, `manyHoldersTakeOffTurns` and `manyHoldersCommitTurns` are recorded,
> not gated, as `commitTwoStalledSubscribersTurns` is. Their figures go to the owner. The PAIRS-T5 probes assert answers
> only. A probe that breaks S3-R16 item 1 in either order is blocking, and P3 applies.

Replace draft:128 with:

> - **Margin.** d3's branch-free A1 (hoist `decisionNow()` into the creation branch) and A2 (format the transfer id once)
>   may be taken, with no new branch. If taken, they land at the start of step 6, each as its own commit, before item
>   4's deciding figures.

(4 is the largest k the ruling measures. The orchestrator may choose another number, but it has to choose one, or the
trigger is decided by whatever k a verifier picks.)

### MF-11. Item 5: r8's mutant text, f7's fallback trigger, and the default-tuning class

**Where.** draft:131-133, :136 and :148.

**Problem.**
1. **r8's mutant text breaks with the removal.** `mut-c4fix.py:44` (r8-fast-any-join) has the original text
   `if join.chain != nil, !atEnd, !here(join.asset) {` and the replacement `if !atEnd, !here(join.asset) {`.
   - After the removal, the original no longer matches, and the replacement names a deleted symbol.
   - The draft rewrites only r6's text (d4 review should-fix 1 says "alongside r7's and r8's").
   - So the r8 kill ruled at draft:139 cannot run as written. One verifier will read a mutant that fails to apply as a
     "survivor"; another will read it as "not run".
2. **f7's fallback has no defined trigger.** "If that shape cannot be built" says nothing about what counts as unable to
   be built. The review's trigger is concrete: "If the in-flight apply changes the commit's path". Without it, a fixer
   can declare the shape unbuildable after any failing attempt.
3. **The default-tuning class is left open.** "Record … whether the default tuning's backoff can" change an answer is
   recorded but not classified. d4 review ("What the ruling must add", item 3) asks for a ruling.
   - S3-R16 item 2's "which lane's backoff policy applies" is non-blocking only "while item 1 holds", so it cannot
     cover an answer that differs.
   - One verifier will call a seeded fail-fast difference 1(a). Another will call it backoff length.

**Replacement.** Replace draft:133 with:

> - Rewrite r6's and r8's mutant texts after the removal (`mut-c4fix.py:42` and `:44`; both match `!atEnd`):
>   - r6 becomes `if join.chain != nil, !here(join.asset) {` → `if join.chain != nil {`;
>   - r8 becomes `if join.chain != nil, !here(join.asset) {` → `if !here(join.asset) {`.
>
>   Re-run r6 2/2 on the new code (G2). r8 is killed in step 7, on its rewritten text.

In draft:136, replace "If that shape cannot be built" with:

> If, with the apply held in flight, the commit takes another path than T-R1's in `followVisitedFirst`, use the
> fallback. The draft names the line that differs, with the run's output. A shape that runs but does not separate the
> mutant is not this fallback: the mutant stays open, as below. Under the fallback,

Replace draft:148's last sentence with:

> Record the tuning under which a wrong lane changes an answer. Then probe the default tuning once (d4 §5 item 6): a
> seeded 429 with no Retry-After, from the third attempt, with a second user request on another job, in both orders.
> - If a caller's answer differs from visit-first's, that is 1(a): blocking, and P3 applies.
> - Otherwise, the throttle length's difference is S3-R16 item 2, recorded as a residual risk with the probe.

### MF-12. Item 6's settle-slice assertion is wrong for one of T-A3's arguments

**Where.** draft:152.

**Problem.** T-A3 takes `arguments: LaneDropVisit.allCases, [0, 1]` (`EngineOwedAnswersTests.swift:190-191`), with
`answersPerTurn = 4` (`:39`).
- At turns = 1, 4 answers are resumed before shutdown, so 600 callers give 596 owed answers and slices of [512, 84].
- So "assert that the slices are exactly [512, 88]" fails on correct code for half the runs.
- The test also hard-codes 10 at `:195` (`owed.left == 10 - 4 * turns`) and in its bytes check.

One verifier will read "exactly [512, 88]" as limiting the test to turns = 0. Another will call the test red.

**Replacement.** Replace draft:152 with:

> - **`EngineShutdown.swift:178-183`, `settle`'s slice.** Give T-A3 (`EngineOwedAnswersTests.swift:190`) a `count`
>   argument of [10, 600], and replace its literal 10 with `count`, one to one (G3: the expectations stay as exact).
>   - At count 600 it asserts `shutdownSlices == [512, 88 - 4 × turns]`: [512, 88] at turns 0 and [512, 84] at
>     turns 1. No job is left to free (d4 review should-fix 4).
>   - Every caller gets C's bytes.
>   - The drop-mutant of the `if` gives one slice, and must fail every count-600 case, 2/2.

### MF-13. Item 8: "O(1) amortised" cannot hold as written for an O(P log P) row

**Where.** draft:163-165.

**Problem.** The draft's own inventory row (`s3f.md:4961`) gives `releaseRerouteHolds` as "O(P log P) for P
publications, at most one a job". That is a sort, not O(1) amortised per id.
- One verifier will reject the argument route outright.
- Another will accept "P ≤ jobs, each held once" as amortised.
- "Its worst grouping" does not say what is varied.
- The draft also does not say whether a miss is blocking.

**Replacement.** Replace draft:163-165 with:

> 8. *`releaseRerouteHolds`' inventory row* (put-back). Give it one of these:
>    - **The argument.** It must cite, from the code, a bound on P (the publications that can wait while
>      `reroutesWaiting > 0`) that does not grow with ids or interests. The row is then O(P log P) at that bound and is
>      recorded with the bound.
>    - **A figure.** If no such bound is cited, give a BenchSync figure: the largest P the harness can hold behind
>      owed re-routes at 10,000 ids, best of 3, with loads. A miss is blocking (S3-R25 item 3).

### MF-14. Item 10's order is incomplete, and step 0 asks for figures that cannot yet be taken

**Where.** draft:173-184.

**Problem.**
1. **Step 0 asks for figures before their cases can run.** Several of the cases it covers need code that does not exist
   on `d5b2ab9`:
   - PIN-APM needs the factored `answerSite` and the handle seam;
   - PIN-APM-SPARE needs the factored tail;
   - item 4's `manyHolders*` cases exist only if pair counting is triggered.

   One verifier will accept scratch figures. Another will expect committed cases at step 0, and a red commit for each.
2. **"in d4's order" (step 2) is ambiguous.** d4 §4 and d4 review's "Order of work (amended)" differ: the review puts
   the `replayVerdict` removal second and the settle slice before f7.
3. **Not placed:**
   - item 4's margin A1 and A2 (see MF-10);
   - item 5's `followedLane` record (draft:148);
   - item 1's records (draft:57-59);
   - verifier findings of class 1(d), flakiness. A flake corrupts every later gate run, yet step 7 puts it after the
     named items.
4. **A circular dependency.** Item 2 (step 4) needs item 3's A3 and A3′ (see MF-8).

**Replacement.** Replace steps 0 to 2 and step 6 (draft:174-180) with:

>     0. Run `verify.sh --quick` on `d5b2ab9`.
>        - In a scratch copy of `d5b2ab9`, build every case that items 1 to 4 add, and take its 'before' figure, best
>          of 3, with loads.
>        - A case that needs a seam gets it in the scratch copy only. The seam lands later as its own behaviour-free
>          commit (MF-9).
>        - Item 4's `manyHolders*` cases take no 'before' figure unless pair counting is triggered.
>        - Item 1's scratch probe is part of this step.
>     1. The verifiers' blocking findings of class S3-R16 1(a) to 1(d), each failing test first.
>     2. Item 6's removal and settle slice, then item 5's removal and its cheap kills (b23 and f7), in d4 review's
>        amended order, steps 1 to 5.
>     ...
>     4. Item 2, including A3 and A3′ (`Group.dropMember`) if its jobs' side needs them.
>     ...
>     6. Item 4: A1 and A2 if taken, then its deciding figures, then pair counting if they trigger it.

And in step 8, after "Items 7 and 8", add: "item 5's `followedLane` record; item 1's records".

### MF-15. The two-subscriber figure is "open" whatever it measures, which contradicts S3-R26 answer 4

**Where.** draft:55.

**Problem.** S3-R26 answer 4 (rulings:664) makes the case "open, for the owner" only "If the two-subscriber case
misses `c2Budget` at a load of 10 or less". The draft says it "stays 'open, for the owner'" with no condition.
- d1 review expects 9.2–10.7 ms after item 1, so it may pass.
- One verifier will close it on a pass. Another will keep it open.

**Replacement.** Replace draft:55 with:

> - **The two-subscriber figure** (S3-R26 answer 4). Re-measure `commitTwoStalledSubscribersTurns` after item 1, and
>   record it with its loads.
>   - If it misses `c2Budget` at a load of 10 or less, it stays "open, for the owner".
>   - Otherwise it is recorded as met.

### MF-16. Item 9's "no specification names a case for it" has no referent in cycle 22

**Where.** draft:169.

**Problem.** In S3-R26, "specification" meant `integrate-c21.md` and `integrate-rr21.md`. S3-R27 has analyses, not
specifications, and they name cases: d1's c1 arm case, d2's PIN-APM-REAL, and d3's five BenchSync cases.
- One verifier reads "specification" to include d1 to d5, and so requires a figure for every O(1) row an analysis
  names.
- Another reads it narrowly and does not.

**Replacement.** In draft:169, replace "no specification names a case for it" with:

> neither this ruling nor `integrate-c21.md` or `integrate-rr21.md` names a case for it. A case that only an analysis
> names (d1 to d5) needs a figure only if this ruling adopts it.

---

## Should-fix

- **SF-1. c6's location.** The draft puts it "in `broadcastAll`" (draft:56). d1 §3's table and d1 review should-fix 6
  put it at the top of `publishTerminal`.
  - Its saving is the filter's two hashes per id. Under a3, that filter runs in `publishTerminal` before the events are
    built (draft:38; `EngineJobs.swift:799-803`).
  - A guard inside `broadcastAll` therefore saves almost nothing.
  - Use MF-7's replacement text.
- **SF-2. A wrong citation.** `(d1, "Before committing")` (draft:45) does not exist in d1. The probe is d1 §4 item 3
  ("Measure first"). Replace it with `(d1 §4 item 3; review should-fix 7)`.
- **SF-3. d2's unrouted should-fix items.** If MF-3 adopts the "named only" reading, add these three to item 3:
  - "Before A2 and A5, audit the answer-site suites' `waitUntil` and `awaitCondition` predicates for a state that exists
    only mid-turn (d2 review should-fix 3). Record the audit."
  - "Shutdown with read tasks still running is a timing residual risk. Add no `Task.isCancelled` branch (should-fix
    7)."
  - "B2's `owing` defaults to `false` (should-fix 8)."
- **SF-4. Item 6's clause test and the visit orders.** The clause test runs from a `sweepFollowsFirst` state.
  - State this: "The epoch clause is an invariant clause, not a replay or deferral branch. Its test runs in
    `sweepFollowsFirst` only, and S3-R24 item 3's both-orders rule does not apply."
  - Otherwise a verifier will ask for a `followVisitedFirst` run that cannot build the state.
- **SF-5. Item 7's pin: say what a failure means.** Add: "If the `#require` fails, the reader is racy. That is a 1(d)
  finding: hold the attempt terminals as `takeOffTurns` does, and record it."
- **SF-6. Item 4 and site 2 at k = 4.** Site 2's charge counts distinct ids (`EngineFollow.swift:614`). At the edge, it
  can make 4 × 512 re-routes in the verdict's turn (d3 (c) row 7).
  - Add a site-2 figure (the verdict's turn, at k = 4, at the edge) to the in-letter shapes.
  - Or say explicitly that it is outside them.
- **SF-7. `verify.sh --full` and P-13.** The fixer did not run `--full`, because P-13 and the known misses make it end
  in `VERIFY: FAIL` (`s3f.md:9800-9802`).
  - Add to step 8: "Run `verify.sh --full` and quote its last line. A FAIL whose only causes are P-13 (WP-B's; S3-R26
    item 10) and the cases this ruling leaves open, for the owner, is reported as such. Each of its other stages also
    runs and passes on its own."
- **SF-8. Item 5: the green-first rule.** Add d4 review's "What the ruling must add" item 5: "Each new test's first run
  on unmutated code is green, in both orders, before its kill counts."
- **SF-9. Item 3's re-run mutants need a pass condition.** At draft:82, add: "each killed 2/2 at its new line, or given
  a disposition under S3-R25 item 10."
- **SF-10. Item 3's group walks when A7 was not taken.** At draft:99, "after (a), B1, B2 and A7" has no defined meaning
  when A7 was not applied: either below 8.5, or kept sorted because a test depends on the order. Replace it with:
  "after (a), B1, B2, and A7 where A7 applies".

---

## The checks requested

### Item 4's reclassification against S3-R25's reference set and S3-R26 answer 4

- **S3-R25's letter.** The draft is consistent with it: PROBE-C21-HOLDERS has 2 ids. But the letter's test is the id
  count, and that test does not separate the defect: padding the probe with ids puts it back inside the set (MF-10.1).
- **S3-R26 answer 4's precedent.** The draft follows it only in part.
  - Answer 4 did two things. It sized a dimension ("The reference set has one subscriber … This sets the reference
    set's subscriber count"). It then measured the next value once, open for the owner only on a miss.
  - The draft takes only the "open, for the owner" half. It sizes nothing, so in-letter k stays unbounded (MF-10.2).
  - The figure is also already a miss, measured in a scratch probe rather than a committed, recorded case.
- **Not reconciled.** The reclassification is not reconciled with S3-R26 item 1's RR-21 gate on "very many tokens per
  id" (MF-10.3), or with S3-R20 and S3-R21's refusal of option (c) (MF-10.4).
- **What makes it consistent.** MF-10's replacement does: it sizes k at 4 for cycle 22, applies "open, for the owner"
  above that, and names both residuals it replaces.

### Item 10's order of work

It is complete except for the gaps in MF-14:
- step 0's 'before' figures for cases that need seams;
- the ambiguous "d4's order";
- the unplaced A1 and A2, `followedLane` record and item 1 records;
- 1(d) flakes placed late;
- item 2's dependency on item 3's A3 and A3′.

### Routing of the fixer's open items and put-backs

| Fixer's item (`s3f.md:6826-6845`) | Routed to | Note |
|---|---|---|
| 1. `waitersStalledSubscriber` | Item 1 | MF-6, MF-7 |
| 2. `purgeWhileOwedTurns` | Item 2 | MF-8 |
| 3. Twelve survivors | Item 5 | All 12 are named (r7 removed, 10 killed, r2b open). r8 needs MF-11.1 |
| 4. Four unreached places | Item 6 | b22's two places go via item 5. Settle slice: MF-12 |
| 5. PROBE-C21-APM | Item 3 | MF-9 |
| 6. PROBE-C21-HOLDERS | Item 4 | MF-10 |
| Put-back: the held-turn readers | Item 7 | Citations `s3f.md:6653-6655` and `:9807-9808` are correct. SF-5 |
| Put-back: `releaseRerouteHolds` | Item 8 | MF-13 |
| Put-back: the two-subscriber figure | Item 1 (draft:55) | MF-15 |

Every item is routed. No item is routed twice, except b22's two unreached places, which item 6 correctly sends to
item 5.

### Citations I checked at `d5b2ab9`

All of these match the code:
- the header's 73 commits and last code commit `e599ae1`;
- `EngineFailures.swift:829-833`, `:834` and `:840`;
- `EngineFollow.swift:876` and `:882-884`;
- the unfailed clause at `EngineCommands.swift:2275`;
- `EngineShutdown.swift:178-183`;
- `EngineOwedAnswersTests.swift:190`;
- `EngineFollowBarrierWaitingTargetTests.swift:191-193`;
- `EnginePresence.swift:277-292`;
- `EngineFailures.swift:73`;
- `integrate-c21.md:447`.

The only bad citation is d1's "Before committing" (SF-2).
