## Orchestrator ruling added 2026-11-04 HH:MM (cycle 20's verification and the cycle-20 fixer's put-backs; drafted 2 Nov, appended before run 7's cycle-21 fixer starts)

Run 6's first cycle-21 fixer was stopped at 05:30 on 2 Nov, one minute in, so that the fixer reads this ruling. The ruling was drafted on 2 Nov and reviewed twice (`s3f-c20-analysis/s3-r26-review-v1.md`, `s3-r26-review2.md`). The owner stopped Stage 3 on 2 Nov at 12:15 and asked for the next fix cycle on 4 Nov, so it is appended on 4 Nov, before run 7's cycle-21 fixer starts.

**S3-R26.** Cycle 20 fixed 7 of cycle 19's 8 distinct blocking items, and both verifiers confirmed it. `waitingTarget` (S3-R25 item 7) is the one item left open.

Where to find things:
- The verifiers left 8 distinct blocking items. They are in `.build-orchestrator/s3f-c20-issues.json`, with the non-blocking ones. "correct #n" and "reqs #n" below are each lens's issue numbers.
- Their probes, scripts and logs are in `.build-orchestrator/s3f-probes-c20/` (`correct/`, `reqs/`).
- The read-only analyses made for this ruling are in `.build-orchestrator/s3f-c20-analysis/`. **Two of them are the specifications to implement:**
  - `integrate-c21.md`: items A (the deferred joins), B (the move index) and C (the commit window), with their interactions with RR-21, an order of work and five open questions;
  - `integrate-rr21.md`: RR-21, in the same format.
- The rest is background:
  - the three RR-21 designs (`design-minimal.md`, `design-fixer.md`, `design-reuse.md`), the judge that rejected all three as written and proposed the synthesis `integrate-rr21.md` builds on (`judge-rr21.md`), and the three critiques of the minimal design (`critic-rr21-*.md`);
  - the designs and critiques behind items A–C (`design2-*.md`, `critic-defer-bucket.md`, `critic-move-index.md`, `critic-commit-window.md`);
  - the analysts' readings of `waitingTarget`, the drain branch, `continueMove` and the inventory rows (`analyse-g4-reach.md`, `analyse-state-cost.md`).

This ruling decides wherever those files differ from it. The cycle-21 verifiers judge by this ruling. Three rules apply to both specifications:
- **Names.** The two specifications reuse labels. In this ruling and in the draft's records:
  - `integrate-rr21.md`'s numbered labels carry `rr21-`: its tests (rr21-T1, rr21-T1-edge, rr21-T8b), its branches (rr21-B1 to rr21-B32) and its commit plan (rr21-C0 to rr21-C8). Its named tests (RR21-HOP, T-WATCH and the rest), R1–R19 and D1–D12 keep their names.
  - `integrate-c21.md`'s numbered tests carry their item's letter: A-T1, B-T5. Its steps A1–A13, B1–B13 and C0–C13, and its clauses K1–K4, I1–I3 and P1–P3, keep their names.
  - "C2" alone is the budget class (S3-R5). Item C's step is "step C2".
  - "P3" alone is CLAUDE.md P3: the failing test first, then the fix. Item C's progress-gate clauses are "clauses P1–P3".
- **Which specification wins.** `integrate-rr21.md`'s interactions_changed replaces `integrate-c21.md`'s interactions 1, 3, 7, 11, 13 and 18, which still describe `design-minimal.md`. Where they differ:
  - the replay returns `EventAfterFollow?`; there is no `rerouteTakenOff` and no `left`;
  - `withdrawPurgedJoins`' early return stays through step 3 (A8) and is removed at rr21-C3, not narrowed;
  - only the waiter and group clauses accept owed items; the run clause gets no acceptance;
  - drain turns spend `drainIDsLeft`; a site's own turn at sites 1 and 3 spends `inboundIDsNow`.
- **UNCONFIRMED claims.** Confirm each claim either specification marks UNCONFIRMED, in the code or by a probe.
  - Where one is false, use the simplest change that keeps that specification's invariants (K1–K4, I1–I3, clauses P1–P3, and RR-21's acceptances, new clauses and D1–D12), and record it.
  - List in the draft any claim left unconfirmed, with the reason.
  - A cost or time estimate is confirmed by its figure. A miss follows the route this ruling gives that figure (items 1, 3 and 4, answer 6.6). A miss with no route is blocking; report it with its figures.

1. *RR-21: the commit's re-routes, the drain's take-off, and `.superseded`'s re-routes* (reqs #1 and #2; correct #3 and #4). Blocking (S3-R24 item 2, S3-R22 item 1, S3-R25 item 3). All three re-route a job's whole interests in one turn. At 10,000 ids they take 47.99–49.34 ms, 47.03 ms and 41.09 ms, best of 3, at a 1-minute load of 10 or less.
   - **Implement `integrate-rr21.md`:** R1–R19, its invariants (the new clauses and D1–D12), its tests, its pins, its must_nots and its branches table (rr21-B1 to rr21-B32). In short:
     - Each site decides once, in its own turn, whether it owes.
       - If its work fits, it makes all its re-routes at once. At sites 1 and 3 the bound is `inboundIDsNow`. At the commit, the fit charge also counts the commit's own answers: `locations.count + items.count > inboundIDsNow`. Site 2's turn is a drain turn and spends `drainIDsLeft`.
       - If it owes, it makes none of its re-routes at once. It owes all of them as one `.reroutes(RerouteBatch)` event. The drain replays it at its queue position, at most `drainIDsLeft` distinct ids a drain turn, each id with all its tokens.
     - Each owed id is re-routed under the copy the reference engine would have used: `rerouteListing` walks the layers that `adoptApplied` records while a batch waits. A pin holds only while `waitingTarget(transfer, epoch:)` holds.
     - While any batch is owed (`reroutesWaiting > 0`), no publication binds (`inboundBlocks`) and no run settles (`checkRunSettled`). While any event waits, no binding is pruned and the watcher stays (`pruneBoundContent`, `hasWork`).
     - Site 2 decides before its verdict whether it owes. If it does not, it reserves its ids from `drainIDsLeft`; if it does, it zeroes `drainIDsLeft`, so the visit moves nothing in that turn.
   - **Rejected,** with the evidence in `judge-rr21.md` and `critic-rr21-answers.md`:
     - re-routing owed ids under the copy at the replay (`design-minimal.md`): it reopens RR-14 (refutation 1);
     - the publication hold as a fallback only: W1..W3's answers differ with no gate change during the barrier (refutation 2);
     - letting the site's own `reconcileIdle` prune owed pairs' bindings (refutation 3);
     - a pseudo-follow or any new source of `followOwed`, owed pairs on a holder job, and a hold per target;
     - a layer per commit, unless the probe of item 12's answer 6.3 breaks.
   - **Prerequisites.** RR-21 lands after item 4's Phase 1 (steps C3, C5, C10, C11), item 2 (A2–A11, so that item 6's branch is gone first) and item 3's B2–B5.
   - **The pins** (S3-R23 item 3: one deterministic test and one BenchSync case per bound):
     - the site's own turn at sites 1 and 3: rr21-T1-edge, rr21-T1-fit and rr21-T2-edge; `concentrationCommitRerouteTurns` and `supersededRerouteTurns`;
     - a drain turn: rr21-T1's and rr21-T3's per-turn id counts; `commitRerouteDivergentTurns` and `movedBeforeDrainTurns`;
     - site 2's own turn: RR21-VERDICT-ZERO and rr21-T3; `movedBeforeDrainWaitersTurns` and `movedBeforeAndAfterTurns`.

     The other BenchSync cases that `integrate-rr21.md` names, in its pins or its commit_plan, are item 9's inventory figures. Two of them are defined only in background files; build them from there: `supersededUserTurns` (`design-minimal.md:285`) and `groupDelistedFit` (`critic-commit-window.md:83`). Measure every one, O(1) rows included. A miss at a 1-minute load of 10 or less, best of 3, is blocking (S3-R16 1(f)); otherwise S3-R23 items 2 and 3 apply.
   - **Four holes are blocking fixes, whatever a probe shows:** the three that `critic-rr21-answers.md` found, and the mid-drain run settlement that `integrate-rr21.md` found. Each test runs red first as item 11 defines it for shapes that need the new code:
     - RR21-HOP and RR21-WINDOW-GATE, at sites 1 and 3. Site 2's targets cannot start or publish behind the barrier, so neither hole reaches site 2 (`critic-rr21-answers.md:103`). The draft cites that line in place of a site-2 test.
     - RR21-PRESENT-PRUNE, at all three sites.
     - RR21-RUN-MIDDRAIN, for the run that settles mid-drain.
   - **Existing tests that change path.** The fit charge, site 2's reservation and the idle guards can change the path of existing tests: the six low-budget suites, and the idle and ledger tests that `integrate-rr21.md`'s plan_gaps names.
     - Answer, MUST and invariant assertions never change (G3, S3-R16 item 4). A change there is a finding: fix the code, not the test.
     - An existing test whose path changes through `pruneBoundContent`'s or `hasWork`'s idle guard takes answer 6.5's narrow fallback first. This holds for the idle and ledger tests, the six suites and any other test.
     - If it still changes path, its assertions stay. Only the steps that reach them may change, for example releasing the owed drain turns before the idle assertion.
     - A low-budget suite whose turn count or order changes through the fit charge or the reservation may be updated one to one, to an expectation as exact as the old one. Each bound's drop-mutant must still fail it 2/2 (S3-R23 item 3, S3-R25 item 5).
     - Record each update in the draft: the old assertion, the new one and the cause. For an order change, also give its S3-R16 item 2 class.
     - This extends S3-R16 item 4 to these causes only.
   - **Residual risks:** `integrate-rr21.md`'s residual_risks, each in the class that file gives it, with the condition that would make it blocking. Where item 12's answer 6 differs, answer 6 decides. Record each in the draft with its test or probe.
     - Its order entries join item 10's accepted orders.
     - Its C2 entries (k tokens per id; the figures still open) are gates, not residual risks: a miss is blocking, as above.
     - "Memory only" is recorded without a class.

2. *`deferBehindVerdict` costs O(E) a join* (reqs #3, correct #2). Blocking: S3-R25 item 3's row now has a probe, which shows 35.78–39.55 ms.
   - **Implement item A of `integrate-c21.md`:** A1–A13, the clauses K1–K4, its tests, its pins and its must_nots.
     - A join that a follow's visit defers behind a waiting exit verdict goes into a bucket keyed by that verdict's (transfer, epoch).
     - The drain places the bucket right behind its verdict, newest first, when it forms that verdict's batch.
     - Batches, their boundaries, the order, and the barrier state inside every replay stay as today.
   - **Rejected:** putting a verdict's joins back after its replay, which is `design2-defer-bucket.md`'s recommendation. It changes `followBarrier` inside the replay and adds a turn boundary (A6r).
   - **The pins:**
     - A-T1's per-turn assertion;
     - the BenchSync case `deferBehindVerdictTurns`, over {404, timeout} × {one prefetch group, one user waiter per id} at 10,000 ids.
   - **A11 and K4**, the removal of the branch for a refused spawn, are item 6.

3. *`move` re-sorts its holder once per move* (correct #1; reqs #6, at the edge). Blocking: 79.55 ms at 16 owed moves off one 10,000-id holder, and 304.79 ms at 64.
   - **Implement item B of `integrate-c21.md`:** B1–B13 and the clauses I1–I3, with its tests, its pins and its must_nots, except B8, I2 and B-T5, which are item 7.
     - `Job.tokensByID` maps each id to the interests that hold it. Every `Job` mutator keeps it in step, so a move reads its ids' holders in O(moved + holders).
     - No `Job` copy stays alive across the table's mutations in `move`, `startMove`, `follow`, `continueInbound` or `answerPresentMembers`.
   - **When:** B lands after item 4's Phase 1 and its first measurements, and before item 1, which needs B2–B5.
   - **The merge gate:** `concentrationPublicationTurns` with the index in place, best of 3 at most `c2Budget` at a 1-minute load of 10 or less (`critic-move-index.md` A1).
     - Check it at step 4 in every case, before B merges.
     - If it fails, build the index lazily, at a job's first move off it (contingency (ii) in `critic-move-index.md`), and re-measure.
     - B lands either way. `integrate-c21.md`'s "do not merge without the merge gate" means measured before the merge, not passed. A miss that stays with the lazy index is blocking (S3-R16 1(f)): report it to the orchestrator with its figures and loads, and go on with the other steps (item 4's last rule). Phase 2 is not its remedy.
     - The gate decides the contingency, and the final figure is what the verifiers judge.
   - **The pins:**
     - `manyMovesTurns` at k = 1, 16, 64 and 256. 256 is the most moves one turn makes (`followsPerTurn`). If 256 held publications cannot be built, pin the largest k that can, and record why.
     - `partialMoveTurns`, with and without users.
   - **The index's own costs** are inventory rows, each with a figure:
     - the release in `dropInterest`, and in the `removeInterest` and `subtractAssets` calls of item 1's take-off and trims (item 1 has no `dropInterests`);
     - `keepInterests` on a copy;
     - the freeing at the commit.

4. *The commit turn's headroom* (correct #5; reqs #10). Blocking: a pinned case missed, at 10.16 ms best of 3 at a 1-minute load of 3.12 (S3-R24 item 2). The other lens measured 9.82 ms at the same load, so the case flaps.
   - **Implement Phase 1 of item C of `integrate-c21.md`:** C0–C11 and C13, the progress-gate clauses P1–P3, its tests, its pins and its must_nots. Its must_nots on Phase 2 bind step 6 too.
     - The commit stays one turn, with no added await (R-SYN-12, F-20, RE-S14).
   - **C1** lands only with item 1's rewrite of `committed`, in R4's form:
     - an id is moved away when `applied.entry(for:)?.transferID != transfer`;
     - for a deferred id, `if !refused, captured.contains(a) { refused = true }`, with `captured` lazy. This is R4's predicate in N3's guard form;
     - no `sameTransfer` conjunct is added.

     R4's mutants replace `integrate-c21.md`'s N3:
     - building `captured` eagerly, and dropping `!refused`, stay Equivalent (N3): setting `refused` twice changes nothing;
     - rr21-T3-captured kills "refused never set" (rr21-B3, rr21-B4);
     - build T-R1 and T-R2 from `design2-commit-window.md` N3. T-R1 kills "refused set for moved-away ids". T-R2 kills "refused set without `captured.contains`". Both run in both orders.
   - **Measure first,** right after Phase 1: `concentrationPublicationTurns` and `commitTurns(.waiters)`. Take both the heartbeat and the commit's own turn inside the actor, each best of 3, with its load.
   - **Phase 2 (C12)** defers only waiter and ensure answers, and only for a job with more than `answersPerTurn` (512) interests. It cannot cut `concentrationPublicationTurns`, `groupStalledSubscriber` or `manyGroups`, and it is never their remedy. It applies if any of these holds, each best of 3 at a 1-minute load of 10 or less:
     - after Phase 1, the in-actor `.waiters` commit turn is above 7.0 ms;
     - after Phase 1, the heartbeat of `.waiters` or `waitersStalledSubscriber` is above `c2Budget`;
     - at rr21-C3, `commitWaitersBoundTurns` or `commitRerouteWaitersTurns` is above `c2Budget`, in the commit's own turn or in its heartbeat.

     Phase 2 lands at step 6 in every case.
     - A `commitRerouteWaitersTurns` miss that stays with Phase 2 in place belongs to item 1. Report it with its figures.
     - A `groupStalledSubscriber` miss takes `SubscriberQueue.reserveCapacity` (`integrate-c21.md` C12).
     - Some misses stay: one that Phase 2 cannot cut, or one that remains with Phase 2 or `reserveCapacity` in place, item 3's merge gate included. Such a miss is blocking (S3-R16 1(f)). Report it to the orchestrator with its figures and loads (`integrate-c21.md:375`), and go on with the other steps.
     - Record the figures that decided it, either way.
   - **After `committed`'s rewrite (rr21-C3),** re-measure `concentrationPublicationTurns` (the merge gate) and every `commitTurns` shape: the heartbeat and the in-actor turn, best of 3, with their loads (`integrate-rr21.md:862-863`). A miss there is decided as this item says: Phase 2 for a shape it can cut, otherwise a report to the orchestrator with the figures.
   - **The order of resumes.**
     - `resolveAll` now resumes in the table's order (step C2). That is a residual risk (S3-R16 item 2).
     - If an existing test depends on the order of resumes, keep the sorted order there, measure its cost, and report it (G3).
   - **Terminal events stay ascending** (step C3; item 12's answer 2).
   - **Subscribers:** item 12's answer 4.

5. *`waitingTarget`'s queued, blocked and downloading case* (reqs #4, correct #6). Blocking (S3-R24 item 3, S3-R25 item 7).
   - **Only "Reached" is left.** `analyse-g4-reach.md` reads the case as reachable by two paths:
     - the ENOENT window that S3-R25 item 7 named;
     - a T20 re-queue (relane's failed arm) inside an ENOSPC's free-space read.

     The case changes where an id waits, the join order and the target's ticket. So it is not Equivalent, and it cannot be removed while a shape reaches it.
   - **The test.**
     - Commit Shape A (the ENOENT window) from that file as a test. Use Shape B (the T20 window) instead if A's drained publication does not compose with the walk.
     - Run it in both `LaneDropVisit` orders.
     - The window exists only in `sweepFollowsFirst`. In `followVisitedFirst` the move is made while the target verifies, and the same test is the answer reference.
     - Item 12's answer 1 says what "reached in both orders" means here. The test reaches `waitingTarget`'s `.queued, .blocked, .downloading` arm in `sweepFollowsFirst` (`EngineFollow.swift:1260-1261` at `8e1fb24`; re-cite it after step 5), and asserts visit-first's answers in both orders.
   - **The mutant.** Kill the fold mutant (`case .queued, .blocked, .downloading: return job`) 2/2. The test asserts the `sweepFollowsFirst` state after one follow turn: the id is still on its holder and not on the target, and no move onto the target is owed.
   - **Residual risk.** The order, place and ticket difference the case makes is a residual risk (S3-R16 item 2). Record it in the draft with the test's figures.
   - **Docs.** Correct three:
     - `enqueue`'s (`EngineJobs.swift:466-470`), which lists who gives places;
     - `Job.epoch`'s (`EngineState.swift:685-686`): only `start` and job creation bump it;
     - the draft's claim that only one path reaches `queued` (`s3f.md:4942-4949`).
   - **Probe two candidates while you build the shapes** (S3-R19 item 1). Run each probe in both orders. A probe that breaks S3-R16 item 1 in either order is blocking. Both windows exist only in `sweepFollowsFirst`, so a break there is enough. If one breaks, P3 applies: the failing test first, then the fix.
     - (i) *The T20 verdict skip.* Run Shape B with an interest at its cap (`interactiveRetry.maxAttemptsPerRun = 1`), or with a reclaim pending.
       - The question: does the barrier start one more attempt where visit-first answers with the ENOSPC figures? That would be a different answer and a request past the cap.
       - The fix belongs in relane's failed arm, not in `waitingTarget`. For example: no T20 re-queue while the attempt's end is recorded and the barrier is up, as for a deferred verdict. relane's comment (`EngineJobs.swift:286-295`) says cycle 17 meant to stop exactly this. It is not a fix of the `waitingTarget` window under `integrate-rr21.md`'s must_not.
       - Item 5's test lands before that fix. If the fix removes the test's only path, reach the case with Shape A, or through rr21-T8b's pin caller (item 12's answer 8). If no shape reaches it, remove the case with the reason (S3-R16 1(e)), and correct the line above that says it cannot be removed.
     - (ii) *The later-apply variant.* A later apply maps the id to U while T still publishes, and T's fresh attempt then fails terminally. If the answers differ, S3-R17 decides:
       - if a SPEC MUST says the id follows its current entry, the engine's answer that follows it stands, and the difference is a residual risk;
       - otherwise the difference is blocking. Fix it with the smallest change that makes the probe's answers equal visit-first's in both orders: commit the failing test first, then the fix. That fix may change the `waitingTarget` window; this lifts `integrate-rr21.md`'s must_not for that fix only. Record the design, its tests and its branches (answer 1).

6. *`scheduleDrainFollowUp`'s unspawnable branch* (reqs #5, correct #7). Blocking (S3-R16 1(e)), as S3-R25 item 7 ruled its twin.
   - **Remove it:** A11 of `integrate-c21.md`. `analyse-g4-reach.md` shows the branch is unreachable. Remove it as `bf1d4eb` did for `scheduleFollowFollowUp`:
     - call `spawn` and drop its result (`spawn` is `@discardableResult`): drop `let spawned =` at `EngineFollow.swift:384`;
     - delete the `if spawned == nil { … }` block, `EngineFollow.swift:390-399`.
   - **The clause:** K4 of item A. It states the assumption: work waits for a follow or a drain only while the engine runs.
     - It reports `!isRunning && !eventsAfterFollow.isEmpty`. Item 1's owed events wait in `eventsAfterFollow` too.
     - K1 covers the buckets: a bucket needs a waiting verdict event.
     - Keep K4 separate from `bf1d4eb`'s clause, so that `EngineFollowShutdownTests`' exact expectation stays unchanged (G3).
   - **The test:** F-K4.
     - Force the state after shutdown with the `violations(after:)` helper, and expect exactly K4's message.
     - Add a control on a running engine with a drain scheduled.
     - K4's drop-mutant fails the test 2/2.
   - **The draft.** The argument covers all seven assignments the branch makes:
     - six data resets, which `drainEverything` makes;
     - the flag, which `drainFollowUp` clears itself.

     It cites `drainEverything` and `drainFollowUp`'s guard (`EngineFollow.swift:411`), never the removed branch.
   - **The caveat.** `notifyObservers` evaluates conditions between `EngineLifecycle.swift:490` and `:498`. Check that no test condition there calls `invariantViolations()`, and record that you checked.

7. *`continueMove` takes the id out of `Job.assets` before its guards* (put-back 4; reqs #9). Not blocking by itself (S3-R25 item 9).
   - **Why it matters.** As `analyse-state-cost.md` shows it, the Q1 state gives the same answer, at the cost of one more job and one more request. It does break I2 (every interest's ids lie in `Job.assets`), the clause that this item adds with B8.
   - **Implement B8 with I2 and B-T5, together** (item B's must_not). They belong to item 3's blocking work, and may be dropped only as the last bullet says:
     - keep the removal at `EngineMoves.swift:195`;
     - after an id's last item, put the id back into `Job.assets` if an interest still holds it.
   - **B-T5 fails first** in `sweepFollowsFirst` on `8e1fb24` (P3, as item 11 defines it).
   - **Probe Q1's stages 2 and 3** (variant Y) in both orders (S3-R19 item 1). Each probe is blocking only if it breaks S3-R16 item 1 in either order: a different answer, a broken MUST or invariant, or a hang. P3 then applies.
   - **If B-T5 cannot be built** after a real attempt, drop B8 and I2 together:
     - record the attempt;
     - record Q1 and variant Y as residual risks in RR-16's family: one more job and one more request for the same content.

8. *`recordDeferredVerdict`'s away filter* (reqs #8). Not blocking.
   - Give it its figure. Wrap `movedBeforeDrain`'s release of J in its own `SyncBench.longestWait` window, as `analyse-state-cost.md` describes.
   - Report it best of 3 against `c2Budget`. A miss at a 1-minute load of 10 or less is blocking (S3-R25 item 3); otherwise S3-R23 items 2 and 3 apply.

9. *The fixer's own check before it returns.* S3-R25 item 10 applies again, on the final HEAD, to every line and branch this cycle changes. Also:
   - **Inventory.** Add the new work to the C2 inventory. Every per-id, per-event or per-owed-item operation of items 1–4 is a row:
     - the bucket's placement at batch formation, and the purge's and `followedLane`'s walks over the buckets (item 2). K2's recount is a test oracle (only `invariantViolations()` calls it), so it is not a row;
     - the index's upkeep in every mutator, and its release and freeing (item 3);
     - the commit window's rows, C0 (item 4);
     - each RR-21 site's own turn: the collect pass and trims, the take-off, site 3's item build, the run-claim release, and the adopt turn's layer pass (item 1);
     - the owed re-routes' replay, and every walk over owed items (item 1).

     Each row gets its cost. It also gets a BenchSync figure at 10,000 ids in its worst grouping, unless it is O(1) amortised per id and no specification names a case for it (item 1 measures every case its specification names).
   - **Re-measure.** Re-measure every existing C2 case the cycle's code passes through, best of 3 at a quiet load, and list them with their loads. The cases include `userSharedApplyTurns`, `sharedApplyTurns`, the concentration cases, `drainVerdictTurns` and `throttleExtension`.
   - **Margin.** A case with a best of 3 above 8.5 ms is listed as "at the edge", with what would cut it. The commit window flapped between 9.82 and 10.16 ms at the same load. Prefer designs that leave margin. This is not a new gate: `c2Budget` stays the bar.

10. *Residual risks and the non-blocking items:*
    - **The publication window is closed, not accepted.** Item 1's global hold keeps every publication from binding while re-routes are owed. A publication that binds only the ids that have joined it is blocking: RR21-WINDOW-GATE shows a different answer with no gate change during the barrier. What stays is item 12's answer 6.2: the hold's delays are timing.
    - **Residual risks of items 2–4:** record `integrate-c21.md`'s residual_risks for A, B and C as item 1 records RR-21's: each with its class, the condition that would make it blocking, and its test or probe. Where this ruling places one (items 4 and 10), the ruling decides.
    - **Accepted orders** (S3-R16 item 2), each recorded in the draft:
      - the newest-first order of the joins behind one verdict (item 2);
      - the table's order of resumes in `resolveAll` (item 4);
      - item 5's order, place and ticket;
      - item 1's replay in (asset, token) order, and the places of jobs created at the replay;
      - item 1's two orders at site 2, with `PROBE-RR21-RESERVE-REJOIN` (item 12's answer 7);
      - item 1's bulk release of run claims, which can let a run materialise more fetches, with rr21-T18.
    - **Item B's earlier take-off** is order and timing (S3-R16 item 2). On the bounded path, unheld moved ids now leave the holder at the first turn, as they do on the fit path. For each reader that `integrate-c21.md` B's residual risks lists, confirm on the new code that it reads no stale binding or failure record. A reader that gives a different answer is blocking (S3-R16 1(a)). Record the readers and the check.
    - **reqs #7** (`EngineDispatch.swift:1118`, reached in some runs only) is not blocking by itself. The line that replaces it in item 1's rewrite of `committed` is a changed line, so item 9 applies to it. Reach it with a deterministic test (one token, with one bound id and one unbound id; `integrate-c21.md` interaction 8), and kill its drop-mutant 2/2. A zero count there is blocking.
    - **P-13** (correct #8, reqs #11) stays routed to WP-B.
    - RR-20 and RR-23 stay as S3-R24 and S3-R25 placed them.

11. *Order of work:* `integrate-c21.md`'s implementation order, steps 0–8, with these changes.
    - **Step 1** also holds, on `8e1fb24`:
      - the probes of item 12's answer 5 and of item 7's stages 2 and 3;
      - the first probe of the join gap, `PROBE-RR21-JOIN-GAP` in `sweepFollowsFirst` (item 12's answer 6.4);
      - item 8's figure.

      `deferBehindVerdictTurns` takes its 'before' figure in step 1 without the expectations that read `joinsBehindVerdicts`, which does not exist yet. Step 3 (A12) adds them, with the drained count that includes bucket joins.
    - **Step 5** is item 1. `integrate-rr21.md`'s commit_plan replaces `integrate-c21.md`'s step-5 text, which still names `design-minimal.md`'s steps:
      - rr21-C0 opens step 5, on the HEAD after steps 2–4. It runs `verify.sh --quick` and takes the 'before' figures of `concentrationCommitRerouteTurns` and `movedBeforeDrainTurns`, best of 3, with their loads;
      - rr21-C1 is the step-1 probe above;
      - rr21-C2, the types and the pure helpers, changes no behaviour;
      - rr21-C3 lands the readers before site 1, or with it; never an owing site before the acceptances and the clauses. It also runs `PROBE-RR21-HEAL-T21` and `PROBE-RR21-PIN-END` (item 12's answers 6.1 and 6.3). It then runs the low-budget, idle and ledger suites, and re-measures the commit and drain turns, `concentrationPublicationTurns` and every `commitTurns` shape (item 4);
      - rr21-C4 re-probes the join gap in both orders, as item 12's answer 6.4 says;
      - rr21-C5 is site 3, and runs `PROBE-RR21-PIN-END` again;
      - rr21-C6 is site 2, with the chunking if `movedBeforeDrainWaitersTurns` misses (item 12's answer 6.6). It runs `PROBE-RR21-RESERVE-REJOIN`;
      - rr21-C7 is the records; rr21-C8 is step 8.
    - **Step 6** is item 4's Phase 2, if any of item 4's triggers fired.
    - **Step 7** is item 5, with its two probes.
    - **Red first.**
      - A test whose shape exists on the code before its fix is committed failing, on its own, immediately before its fix (S3-R1, P3). This holds inside step 5 too. Only that commit may be red, and its message names the test. Every other commit stays green.
      - A test whose fix comes in a later step is run on `8e1fb24` in step 1, with its failing line recorded, and committed failing right before its fix.
      - Where the shape cannot exist before the fix (item 1's four holes), "red first" is a scratch copy, as S3-R3 does. Remove the guard (the publishing term in `ends`, the hold term, the prune guard, or `reroutesWaiting == 0` in `checkRunSettled`), run the test, and paste its failing line into the draft. Then commit the test with its guard. For these four, this replaces S3-R1's separate failing commit.
      - A probe that holds is recorded with its result and is not committed as a failing test. A probe that breaks S3-R16 item 1 becomes a failing test under the first rule.
    - **A deciding figure without a quiet load.** If a figure that decides Phase 2, site 2's chunking or item 3's merge gate cannot be taken at a 1-minute load of 10 or less, decide on the best of 3 at the lowest load you get. Record it as "not measured at a quiet load" (S3-R23 item 3), with its loads. The orchestrator re-measures it before close-out, and a different result reopens that decision.
    - **Commits.** Commit each step on its own, with its tests, so that a verifier can read the cycle step by step. Within step 5, commit each of rr21-C2 to rr21-C7 on its own.

12. *Answers to the specifications' open questions.*
    1. **A branch whose state arises only in `sweepFollowsFirst`** counts as reached in both orders when all three hold:
       - its test runs in both `LaneDropVisit` orders and asserts visit-first's answers in both;
       - the test reaches the branch in `sweepFollowsFirst`, and the branch's drop-mutant fails it 2/2 there;
       - the draft says, per branch, why `followVisitedFirst` cannot reach it, with a citation (for example `EngineFollowBarrierTests.swift:97-108`). Where the test can observe that state, a per-order `#require` that pins its absence in `followVisitedFirst` may stand in for the citation.

       This covers every branch whose state arises only in `sweepFollowsFirst`. The draft lists each one, with its citation or its `#require`. They include:
       - item A's bucket branches and B8's re-insertion;
       - item 5's case, and any branch that a fix of its probes adds;
       - item 1's site-2 branches (rr21-B6 to rr21-B9, RR21-VERDICT-ZERO) and, if built, the chunking's branches (answer 6.6);
       - rr21-B26, if RR21-RUN-MIDDRAIN cannot reach it in `followVisitedFirst`.

       For such a branch, "2/2 in each order" or "2 out of 2 times in both orders" in either specification means 2/2 in `sweepFollowsFirst`; one example is A-T1's pin. This amends S3-R24 item 3's "Reached", and S3-R25 item 7, for these branches. A branch that `followVisitedFirst` can reach keeps S3-R24 item 3 unchanged.
    2. **No:** terminal events stay ascending (step C3). The saving is one lookup per id. A run-to-run order would make every subscriber's sequence vary.
    3. **Yes,** as item 7 says.
    4. **The reference set has one subscriber, which may be stalled,** as the existing R-SYN-12 pin has (`BenchSync.swift:297-312`).
       - Measure the cost of a second subscriber once: `commitTurns(.waiters)` with two stalled subscribers. Record it with its figure and load.
       - This sets the reference set's subscriber count. It waives nothing (S3-R20 item 1).
       - If the two-subscriber case misses `c2Budget` at a load of 10 or less, report it as "open, for the owner", with the figure. Like S3-R23 item 3's "not measured at a quiet load", it is neither accepted nor blocking for this cycle. The orchestrator puts it to the owner before it rules the close-out converged.
    5. **Probe them,** in step 1 (S3-R19 item 1). The candidates are:
       - orphaned run claims at a verdict replayed with the barrier down;
       - `recordRunOutcome`'s `outstanding[T] = nil` (`EngineRuns.swift:519`), which wipes a claim a visit re-routed onto T;
       - variant Y's T1 half (item 7's stage 3). T1 is `analyse-state-cost.md`'s prefetch-group token, not a test;
       - `followAfterVerdict` joins at once onto a job whose own verdict waits later in the queue (`integrate-c21.md:157`).

       Each probe is a deterministic test in both orders that asserts visit-first's answers.
       - A probe that breaks S3-R16 item 1 is blocking, and P3 applies.
       - Otherwise the probe stays only if it asserts answers (G4), and the candidate is recorded with it as evidence.
    6. **`integrate-rr21.md`'s rulings 1–7** (the judge's open questions) are decided as it recommends, with one condition on every timing class below: it holds only while the event lands between the two engines' answers (S3-R24 item 5). A probe that shows a different answer with the event before both answers, or after both, is blocking.
       1. *A cancel or a release between the owing instant and the replay* of a T21 or present pair gives `.cancelled`. This is timing (S3-R16 item 2).
          - A heal scheduled meanwhile, which the T21 replay forgets, is the same class.
          - `PROBE-RR21-HEAL-T21` compares the healed system interest's outcome with visit-first's, in both orders. Run it with the heal between the owing instant and the replay, again with the heal before the site, and again after the replay.
          - It is blocking if the outcomes differ with the heal before both answers or after both, or if a SPEC MUST on heals breaks (S3-R16 1(b)).
       2. *The global hold's delays* are timing. So is an apply during the hold that drops a held job's ids. There is no hold per target.
       3. *A pin whose job committed, was superseded or was re-queued by ENOENT* (rr21-T8b) between the apply and the replay follows the copy at the replay. There is no layer per commit.
          - With no apply between that end and the replay, this equals the reference. rr21-T8 and rr21-T8b pin it.
          - With one, the reference had re-routed the pair at that end. If the pair's new target is publishing at the later apply, the reference passes the pair, as in RR-14, and that apply lands before both answers.
          - Probe that shape, `PROBE-RR21-PIN-END`, in both orders, after site 1 lands (rr21-C3) and again after site 3 lands (rr21-C5). A different answer is blocking (S3-R21 item 4). The fix then starts from the judge's "layer per commit" (`judge-rr21.md`, open questions): the smallest change that makes the probe's answers equal visit-first's, with its tests, clauses and branches, recorded.
          - If the probe holds, record it as timing, with the probe.
       4. *`replayJoin`'s RR-14-class gap* (`EngineFollow.swift:704-707`) is probed twice: in step 1 in `sweepFollowsFirst`, and at rr21-C4 in both orders.
          - The step-1 probe is evidence. If it breaks, record its failing line, and run it again at rr21-C4.
          - R18 needs R10, R11 and the layers, so it lands no earlier than rr21-C4.
          - If the rr21-C4 run breaks S3-R16 item 1 in either order, the gap is blocking (S3-R21 item 4). Commit the probe as a failing test on its own, then land R18 with RR21-HOP's join variant.
          - If the rr21-C4 run holds in both orders, the gap is a residual risk with both results as evidence, and no `.join` layer is built (G4).
       5. *Present is decided at the replay.*
          - Keeping owed pairs' bindings through the site's own `reconcileIdle` is a blocking fix (RR21-PRESENT-PRUNE).
          - Use the broad guard (`eventsAfterFollow` is not empty) and the `hasWork` disjunct. Fall back to `reroutesWaiting > 0` only if an existing test changes path through these two guards, and record why.
          - A purge's `dropBindings`, an eviction or a quarantine between the owing instant and the replay is timing. So is the broad guard's later prune.
       6. *The figures that decide the contingencies:*
          - `movedBeforeDrainWaitersTurns`, all held and half held, decides site 2's chunking. If it misses, build the chunking as `judge-rr21.md`'s open questions sketch it: the take-off runs over drain turns before the verdict, and the verdict replays behind it in the same batch. Site 2 still decides before its verdict whether it owes. Add the chunking's branches to the branches table. Each gets a test that meets item 12's answer 1. Pin it twice (S3-R23 item 3), and record the design.
          - `commitRerouteWaitersTurns` (at least 511 joins behind the event) and `commitWaitersBoundTurns` are Phase 2 triggers (item 4).
          - A miss with 10,000 user waiters all bound belongs to item 4, not to a fourth RR-21 site.
       7. *A `.spaceFailure` verdict is identified by `VerdictKey`,* like `.attemptFailed`, whether or not `verdictsAfterFollow` holds it. It is live while `waitingTarget(t, epoch:)` holds.
    7. **`integrate-rr21.md`'s own nine questions are accepted as it recommends:**
       - the `reroutesWaiting` counter, with its clause;
       - the fit charge;
       - site 2's decision before its visit;
       - the `checkRunSettled` counter guard, a blocking fix, with RR21-RUN-MIDDRAIN red first as item 11 defines it;
       - the take-off's ascending sort of wholly held tokens;
       - the purge arm that removes items and sorts the removed subset;
       - `indirect`, unless the stride is unchanged without it;
       - an id taken whole;
       - the `.join` layers only after a broken probe.

       Two riders:
       - The reservation changes the order at or below the bound. That is the cycle-19 bounded-visit class. Run `PROBE-RR21-RESERVE-REJOIN` in both orders at rr21-C6 and record its results. It is blocking only if they break S3-R16 item 1 in either order.
       - Every sort that `integrate-rr21.md`'s must_not allows still needs its BenchSync figure.
    8. **`waitingTarget`'s two callers** (the judge's OQ8).
       - Item 5's test reaches the case through the `InboundMove` caller, and rr21-T8b reaches it through the pin caller. Both kill the fold mutant 2/2.
       - Item 5's "Reached" needs only item 5's test, and rr21-T8b belongs to item 1.
       - If item 5's fallback (probe (i)) leaves item 5 with no test on the case, rr21-T8b's 2/2 kill of the fold mutant counts for item 5's "Reached" too. Record that in the draft.
    9. **Inventory rows outside RR-21** (the judge's OQ9) go with their owners:
       - `move`'s sort with item 3's `moveItems`;
       - `deferBehindVerdict` with item 2's A5;
       - `deliver`'s group copy with item 4's C5.
