## Orchestrator ruling added 2026-11-02 HH:MM (cycle 20's verification and the cycle-20 fixer's put-backs; written before the cycle-21 fixer starts)

Run 6's first cycle-21 fixer was stopped at 05:30, one minute in, so that the fixer reads this ruling.

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

This ruling decides wherever those files differ from it. The cycle-21 verifiers judge by this ruling.

1. *RR-21: the commit's re-routes, the drain's take-off, and `.superseded`'s re-routes* (reqs #1 and #2; correct #3 and #4). Blocking (S3-R24 item 2, S3-R22 item 1, S3-R25 item 3). All three re-route a job's whole interests in one turn. At 10,000 ids they take 47.99–49.34 ms, 47.03 ms and 41.09 ms, best of 3, at a 1-minute load of 10 or less.
   - **Implement `integrate-rr21.md`:** R1–R19, its invariants (the new clauses and D1–D12), its tests, its pins, its must_nots and its branches table (B1–B32). In short:
     - A site's own turn makes at most `inboundIDsNow` re-routes, counting its own answers. At the commit this is the fit charge, `locations.count + items.count > inboundIDsNow`.
     - The rest is owed as one `.reroutes(RerouteBatch)` event. The drain replays it at its queue position, at most `drainIDsLeft` distinct ids a drain turn, each id with all its tokens.
     - Each owed id is re-routed under the copy the reference engine would have used: `rerouteListing` walks the layers that `adoptApplied` records while a batch waits. A pin holds only while `waitingTarget(transfer, epoch:)` holds.
     - While any batch is owed (`reroutesWaiting > 0`), no publication binds (`inboundBlocks`) and no run settles (`checkRunSettled`). While any event waits, no binding is pruned and the watcher stays (`pruneBoundContent`, `hasWork`).
     - Site 2 decides before its verdict whether it owes. If it does not, it reserves its ids from `drainIDsLeft`; if it does, it zeroes `drainIDsLeft`, so the visit moves nothing in that turn.
   - **Rejected,** with the evidence in `judge-rr21.md` and `critic-rr21-answers.md`:
     - re-routing owed ids under the copy at the replay (`design-minimal.md`): it reopens RR-14 (refutation 1);
     - the publication hold as a fallback only: W1..W3's answers differ with no gate change during the barrier (refutation 2);
     - letting the site's own `reconcileIdle` prune owed pairs' bindings (refutation 3);
     - a pseudo-follow or any new source of `followOwed`, owed pairs on a holder job, a hold per target, and a layer per commit.
   - **Prerequisites.** RR-21 lands after item 4's Phase 1 (C3, C5, C10, C11), item 2 (A2–A11, so that item 6's branch is gone first) and item 3's B2–B5.
   - **The pins** (S3-R23 item 3: one deterministic test and one BenchSync case per bound):
     - the site's own turn at sites 1 and 3: T1-edge, T1-fit and T2-edge; `concentrationCommitRerouteTurns` and `supersededRerouteTurns`;
     - a drain turn: T1's and T3's per-turn id counts; `commitRerouteDivergentTurns` and `movedBeforeDrainTurns`;
     - site 2's own turn: RR21-VERDICT-ZERO and T3; `movedBeforeDrainWaitersTurns` and `movedBeforeAndAfterTurns`.

     The other BenchSync cases in `integrate-rr21.md`'s pins are item 9's inventory figures. Measure every one; a miss is blocking (S3-R16 1(f)).
   - **The critics' four holes are blocking fixes.** Each test runs red first wherever its shape exists before the fix (S3-R19 item 1, P3):
     - RR21-HOP, RR21-WINDOW-GATE and RR21-PRESENT-PRUNE, at each site;
     - RR21-RUN-MIDDRAIN, for the run that settles mid-drain.
   - **Existing tests that change path.** The fit charge, site 2's reservation and the idle guards can change the path of the six low-budget suites and of the idle and ledger tests in `integrate-rr21.md`'s plan_gaps.
     - A test whose expected answers change is a finding. Fix the code, not the test (G3).
     - A test whose turn count, order or path expectation changes may be updated, to an expectation as exact as the old one. Each update gets a one-to-one record in the draft that names its S3-R16 item 2 class.
   - **What `integrate-rr21.md` marks UNCONFIRMED,** confirm in the code or by a probe. Where it is false, use the simplest change that keeps D1–D12, and record it.
   - **Residual risks:** `integrate-rr21.md`'s residual_risks, in the classes item 12's answer 6 gives. Record each in the draft with its test or probe.

2. *`deferBehindVerdict` costs O(E) a join* (reqs #3, correct #2). Blocking: S3-R25 item 3's row now has a probe, which shows 35.78–39.55 ms.
   - **Implement item A of `integrate-c21.md`:** A1–A13, the clauses K1–K4, its tests, its pins and its must_nots.
     - A join that a follow's visit defers behind a waiting exit verdict goes into a bucket keyed by that verdict's (transfer, epoch).
     - The drain places the bucket right behind its verdict, newest first, when it forms that verdict's batch.
     - Batches, their boundaries, the order, and the barrier state inside every replay stay as today.
   - **Rejected:** putting a verdict's joins back after its replay, which is `design2-defer-bucket.md`'s recommendation. It changes `followBarrier` inside the replay and adds a turn boundary (A6r).
   - **The pins:**
     - T1's per-turn assertion;
     - the BenchSync case `deferBehindVerdictTurns`, over {404, timeout} × {one prefetch group, one user waiter per id} at 10,000 ids.
   - **A11 and K4**, the removal of the branch for a refused spawn, are item 6.

3. *`move` re-sorts its holder once per move* (correct #1; reqs #6, at the edge). Blocking: 79.55 ms at 16 owed moves off one 10,000-id holder, and 304.79 ms at 64.
   - **Implement item B of `integrate-c21.md`:** B1–B13, the clauses I1–I3, its tests, its pins and its must_nots.
     - `Job.tokensByID` maps each id to the interests that hold it. Every `Job` mutator keeps it in step, so a move reads its ids' holders in O(moved + holders).
     - No `Job` copy stays alive across the table's mutations in `move`, `startMove`, `follow`, `continueInbound` or `answerPresentMembers`.
   - **When:** B lands after item 4's Phase 1 and its first measurements. Its merge gate is `concentrationPublicationTurns`, re-measured with the index in place.
   - **The pins:**
     - `manyMovesTurns` at k = 1, 16, 64 and 256. 256 is the most moves one turn makes (`followsPerTurn`). If 256 held publications cannot be built, pin the largest k that can, and record why.
     - `partialMoveTurns`, with and without users.
   - **The index's own costs** are inventory rows, each with a figure:
     - the release in `dropInterest`, and in the `removeInterest` and `subtractAssets` calls of item 1's take-off and trims (item 1 has no `dropInterests`);
     - `keepInterests` on a copy;
     - the freeing at the commit.
   - **B8, I2 and T5** are item 7.

4. *The commit turn's headroom* (correct #5; reqs #10). Blocking: a pinned case missed, at 10.16 ms best of 3 at a 1-minute load of 3.12 (S3-R24 item 2). The other lens measured 9.82 ms at the same load, so the case flaps.
   - **Implement Phase 1 of item C of `integrate-c21.md`:** C0–C11 and C13, the progress-gate clause (P1–P3), its tests and its pins.
     - The commit stays one turn, with no added await (R-SYN-12, F-20, RE-S14).
     - C1 lands only with item 1's rewrite of `committed`.
   - **Measure first,** right after Phase 1: `concentrationPublicationTurns` and `commitTurns(.waiters)`. Take both the heartbeat and the commit's own turn inside the actor, each best of 3, with its load.
   - **Phase 2 (C12)** applies only if, after Phase 1:
     - the in-actor `.waiters` turn's best of 3 is above 7.0 ms; or
     - any heartbeat is above `c2Budget`.
     Record the figures that decided it, either way.
   - **The order of resumes.**
     - `resolveAll` now resumes in the table's order (C2). That is a residual risk (S3-R16 item 2).
     - If an existing test depends on the order of resumes, keep the sorted order there, measure its cost, and report it (G3).
   - **Terminal events stay ascending** (C3; item 12's answer 2).
   - **Subscribers:** item 12's answer 4.

5. *`waitingTarget`'s queued, blocked and downloading case* (reqs #4, correct #6). Blocking (S3-R24 item 3, S3-R25 item 7).
   - **Only "Reached" is left.** `analyse-g4-reach.md` reads the case as reachable by two paths:
     - the ENOENT window that S3-R25 item 7 named;
     - a T20 re-queue (relane's failed arm) inside an ENOSPC's free-space read.

     The case changes where an id waits, the join order and the target's ticket. So it is not Equivalent, and it cannot be removed.
   - **The test.**
     - Commit Shape A (the ENOENT window) from that file as a test. Use Shape B (the T20 window) instead if A's drained publication does not compose with the walk.
     - Run it in both `LaneDropVisit` orders.
     - The window exists only in `sweepFollowsFirst`. In `followVisitedFirst` the move is made while the target verifies, and the same test is the answer reference.
     - Item 12's answer 1 says what "reached in both orders" means here: the test reaches `EngineFollow.swift:1261` in `sweepFollowsFirst`, and asserts visit-first's answers in both orders.
   - **The mutant.** Kill the fold mutant (`case .queued, .blocked, .downloading: return job`) 2/2. The test asserts the `sweepFollowsFirst` state after one follow turn: the id is still on its holder and not on the target, and no move onto the target is owed.
   - **Residual risk.** The order, place and ticket difference the case makes is a residual risk (S3-R16 item 2). Record it in the draft with the test's figures.
   - **Docs.** Correct three:
     - `enqueue`'s (`EngineJobs.swift:466-470`), which lists who gives places;
     - `Job.epoch`'s (`EngineState.swift:685-686`): only `start` and job creation bump it;
     - the draft's claim that only one path reaches `queued` (`s3f.md:4942-4949`).
   - **Probe two candidates while you build the shapes** (S3-R19 item 1). Each is blocking only if its probe, in both orders, breaks S3-R16 item 1. If one does, P3 applies: the failing test first, then the fix.
     - (i) *The T20 verdict skip.* Run Shape B with an interest at its cap (`interactiveRetry.maxAttemptsPerRun = 1`), or with a reclaim pending.
       - The question: does the barrier start one more attempt where visit-first answers with the ENOSPC figures? That would be a different answer and a request past the cap.
       - The fix belongs in relane's failed arm, not in `waitingTarget`. For example: no T20 re-queue while the attempt's end is recorded and the barrier is up, as for a deferred verdict. relane's comment (`EngineJobs.swift:286-295`) says cycle 17 meant to stop exactly this.
     - (ii) *The later-apply variant.* A later apply maps the id to U while T still publishes, and T's fresh attempt then fails terminally. If the answers differ, S3-R17 decides:
       - if a SPEC MUST says the id follows its current entry, the engine's answer that follows it stands, and the difference is a residual risk;
       - otherwise the difference is blocking.

6. *`scheduleDrainFollowUp`'s unspawnable branch* (reqs #5, correct #7). Blocking (S3-R16 1(e)), as S3-R25 item 7 ruled its twin.
   - **Remove it:** A11 of `integrate-c21.md`. `analyse-g4-reach.md` shows the branch is unreachable. Remove it as `bf1d4eb` did for `scheduleFollowFollowUp`:
     - call `spawn` and drop its result (`spawn` is `@discardableResult`);
     - delete `EngineFollow.swift:390-398`.
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

7. *`continueMove` takes the id out of `Job.assets` before its guards* (put-back 4; reqs #9).
   - **Why it matters.** As `analyse-state-cost.md` shows it, the Q1 state gives the same answer, at the cost of one more job and one more request. It does break I2 (every interest's ids lie in `Job.assets`), the clause item 3 adds.
   - **Implement B8 with I2 and T5, together** (item B's must_not):
     - keep the removal at `EngineMoves.swift:195`;
     - after an id's last item, put the id back into `Job.assets` if an interest still holds it.
   - **T5 fails first** in `sweepFollowsFirst` on `8e1fb24` (P3).
   - **Probe Q1's stages 2 and 3** (variant Y) in both orders (S3-R19 item 1). Each is blocking only if it gives T' or T1 a different answer than visit-first; P3 then applies.
   - **If T5 cannot be built** after a real attempt, drop B8 and I2 together:
     - record the attempt;
     - record Q1 and variant Y as residual risks in RR-16's family: one more job and one more request for the same content.

8. *`recordDeferredVerdict`'s away filter* (reqs #8). Not blocking.
   - Give it its figure. Wrap `movedBeforeDrain`'s release of J in its own `SyncBench.longestWait` window, as `analyse-state-cost.md` describes.
   - Report it best of 3 against `c2Budget`. A miss is blocking (S3-R25 item 3).

9. *The fixer's own check before it returns.* S3-R25 item 10 applies again, on the final HEAD, to every line and branch this cycle changes. Also:
   - **Inventory.** Add the new work to the C2 inventory. Every per-id, per-event or per-owed-item operation of items 1–4 is a row:
     - the bucket's placement at batch formation, and the purge's, `followedLane`'s and the recount's walks over the buckets (item 2);
     - the index's upkeep in every mutator, and its release and freeing (item 3);
     - the commit window's rows, C0 (item 4);
     - the owed re-routes' replay, and every walk over owed items (item 1).

     Each row gets its cost, and a BenchSync figure at 10,000 ids in its worst grouping unless it is O(1) amortised per id.
   - **Re-measure.** Re-measure every existing C2 case the cycle's code passes through, best of 3 at a quiet load, and list them with their loads. The cases include `userSharedApplyTurns`, `sharedApplyTurns`, the concentration cases, `drainVerdictTurns` and `throttleExtension`.
   - **Margin.** A case with a best of 3 above 8.5 ms is listed as "at the edge", with what would cut it. The commit window flapped between 9.82 and 10.16 ms at the same load. Prefer designs that leave margin. This is not a new gate: `c2Budget` stays the bar.

10. *Residual risks and the non-blocking items:*
    - **The publication window is closed, not accepted.** Item 1's global hold keeps every publication from binding while re-routes are owed. A publication that binds only the ids that have joined it is blocking: RR21-WINDOW-GATE shows a different answer with no gate change during the barrier. What stays is item 12's answer 6.2: the hold's delays are timing.
    - **Accepted orders** (S3-R16 item 2), each recorded in the draft:
      - the newest-first order of the joins behind one verdict (item 2);
      - the table's order of resumes in `resolveAll` (item 4);
      - item 5's order, place and ticket.
    - **Item B's earlier take-off.** On the bounded path, unheld moved ids now leave the holder at the first turn, as they do on the fit path. Record the readers that see it earlier (`integrate-c21.md` B's residual risks).
    - **reqs #7** (`EngineDispatch.swift:1118`, reached in some runs only). Item 1 rewrites `committed`. Whatever replaces that line is reached by a deterministic test: one token with one bound id and one unbound id (`integrate-c21.md` interaction 8).
    - **P-13** (correct #8, reqs #11) stays routed to WP-B.
    - RR-20 and RR-23 stay as S3-R24 and S3-R25 placed them.

11. *Order of work:* `integrate-c21.md`'s implementation order, steps 0–8, with these changes.
    - **Step 1** also holds, on `8e1fb24`:
      - the probes of item 12's answer 5 and of item 7's stages 2 and 3;
      - the first probe of the join gap, `PROBE-RR21-JOIN-GAP` in `sweepFollowsFirst` (item 12's answer 6.4);
      - item 8's figure.
    - **Step 5** is item 1. `integrate-rr21.md`'s commit_plan replaces `integrate-c21.md`'s step-5 text, which still names `design-minimal.md`'s steps:
      - its C0 is step 0, plus the 'before' figures of `concentrationCommitRerouteTurns` and `movedBeforeDrainTurns`;
      - its C1 is the step-1 probe above;
      - C2, the types and the pure helpers, changes no behaviour;
      - C3 lands the readers before site 1, or with it; never an owing site before the acceptances and the clauses. It then runs the low-budget, idle and ledger suites and re-measures the commit and drain turns;
      - C4 re-probes the join gap in both orders. R18 lands in that commit only if the probe breaks;
      - C5 is site 3. C6 is site 2, with the chunking if `movedBeforeDrainWaitersTurns` misses. C7 is the records;
      - its C8 is step 8.
    - **Step 6** decides item 4's Phase 2 at two points: on step 2's figures, and again on C3's commit-turn figures (`commitWaitersBoundTurns`, `commitRerouteWaitersTurns`). Either trigger applies Phase 2.
    - **Step 7** is item 5, with its two probes.
    - **Commits.** Commit each step on its own, with its tests, so that a verifier can read the cycle step by step. Within step 5, commit each of C2–C7 on its own.

12. *Answers to `integrate-c21.md`'s open questions.*
    1. **A branch whose state arises only in `sweepFollowsFirst`** counts as reached in both orders when all three hold:
       - its test runs in both `LaneDropVisit` orders and asserts visit-first's answers in both;
       - the test reaches the branch in `sweepFollowsFirst`, and the branch's drop-mutant fails it 2/2 there;
       - the draft says, per branch, why `followVisitedFirst` cannot reach it, with a citation (for example `EngineFollowBarrierTests.swift:97-108`). Where the test can observe that state, a per-order `#require` that pins its absence in `followVisitedFirst` may stand in for the citation.

       This covers item A's bucket branches, B8's re-insertion, item 5's case and item 1's site-2 branches (B6–B9, RR21-VERDICT-ZERO). For such a branch, "2/2 in each order" in `integrate-rr21.md` means 2/2 in `sweepFollowsFirst`.
    2. **No:** terminal events stay ascending (C3). The saving is one lookup per id. A run-to-run order would make every subscriber's sequence vary.
    3. **Yes,** as item 7 says.
    4. **The reference set has one subscriber, which may be stalled,** as the existing R-SYN-12 pin has (`BenchSync.swift:297-312`).
       - Measure the cost of a second subscriber once: `commitTurns(.waiters)` with two stalled subscribers. Record it as a residual risk, with its figure.
       - A miss that needs two or more subscribers is not blocking in this work package.
    5. **Probe them,** in step 1 (S3-R19 item 1). The candidates are:
       - orphaned run claims at a verdict replayed with the barrier down;
       - `recordRunOutcome`'s `outstanding[T] = nil` (`EngineRuns.swift:519`), which wipes a claim a visit re-routed onto T;
       - variant Y's T1 half (item 7's stage 3).

       Each probe is a deterministic test in both orders that asserts visit-first's answers.
       - A probe that breaks S3-R16 item 1 is blocking, and P3 applies.
       - Otherwise the probe stays only if it asserts answers (G4), and the candidate is recorded with it as evidence.
    6. **`integrate-rr21.md`'s rulings 1–7** (the judge's open questions) are decided as it recommends:
       1. *A cancel or a release between the owing instant and the replay* of a T21 or present pair gives `.cancelled`. This is timing (S3-R16 item 2): it lands between the two engines' answers (S3-R24 item 5).
          - A heal scheduled meanwhile, which the T21 replay forgets, is the same class.
          - `PROBE-RR21-HEAL-T21` makes it blocking only if the heal lands before both answers, or if a SPEC MUST on heals breaks (S3-R17).
       2. *The global hold's delays* are timing. So is an apply during the hold that drops a held job's ids. There is no hold per target.
       3. *A pin whose job committed, was superseded or was re-queued by ENOENT* (T8b) between the apply and the replay follows the copy at the replay. This is timing. There is no layer per commit.
       4. *`replayJoin`'s RR-14-class gap* (`EngineFollow.swift:704-707`) is probed twice: in step 1 in `sweepFollowsFirst`, and after site 1 lands in both orders.
          - If either probe breaks S3-R16 item 1, the gap is blocking (S3-R21 item 4). R18 then lands in that commit, with RR21-HOP's join variant.
          - Otherwise it is a residual risk with both probes as evidence, and no `.join` layer is built (G4).
       5. *Present is decided at the replay.*
          - Keeping owed pairs' bindings through the site's own `reconcileIdle` is a blocking fix (RR21-PRESENT-PRUNE).
          - Use the broad guard (`eventsAfterFollow` is not empty) and the `hasWork` disjunct. Fall back to `reroutesWaiting > 0` only if an existing test changes path, and record why.
          - A purge's `dropBindings`, an eviction or a quarantine between the owing instant and the replay is timing. So is the broad guard's later prune.
       6. *The figures that decide the contingencies:*
          - `movedBeforeDrainWaitersTurns`, all held and half held, decides site 2's chunking before the verdict.
          - `commitRerouteWaitersTurns` (at least 511 joins behind the event) and `commitWaitersBoundTurns` decide item 4's Phase 2, as a trigger beside item 4's own.
          - A miss with 10,000 user waiters all bound belongs to item 4, not to a fourth RR-21 site.
       7. *A `.spaceFailure` verdict is identified by `VerdictKey`,* like `.attemptFailed`, whether or not `verdictsAfterFollow` holds it. It is live while `waitingTarget(t, epoch:)` holds.
    7. **`integrate-rr21.md`'s own nine questions are accepted as it recommends:**
       - the `reroutesWaiting` counter, with its clause;
       - the fit charge;
       - site 2's decision before its visit;
       - the `checkRunSettled` counter guard, a blocking fix, with RR21-RUN-MIDDRAIN red first;
       - the take-off's ascending sort of wholly held tokens;
       - the purge arm that removes items and sorts the removed subset;
       - `indirect`, unless the stride is unchanged without it;
       - an id taken whole;
       - the `.join` layers only after a broken probe.

       Two riders:
       - The reservation changes the order at or below the bound. That is the cycle-19 bounded-visit class. Record it with `PROBE-RR21-RESERVE-REJOIN`'s results in both orders. It is blocking only if those results differ from visit-first's answers.
       - Every sort that `integrate-rr21.md`'s must_not allows still needs its BenchSync figure.
    8. **`waitingTarget`'s two callers** (the judge's OQ8).
       - Item 5's test reaches the case through the `InboundMove` caller, and T8b reaches it through the pin caller. Both kill the fold mutant 2/2.
       - Item 5's "Reached" needs only item 5's test. T8b belongs to item 1.
    9. **Inventory rows outside RR-21** (the judge's OQ9) go with their owners:
       - `move`'s sort with item 3's `moveItems`;
       - `deferBehindVerdict` with item 2's A5;
       - `deliver`'s group copy with item 4's C5.
