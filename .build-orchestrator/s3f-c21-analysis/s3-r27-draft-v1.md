## Orchestrator ruling added 2026-11-05 20:00 (the cycle-21 fixer's put-backs; written while the cycle-21 verifiers run, before the cycle-22 fixer starts)

Run 8's cycle-21 fixer returned at 17:54. It reported six blocking items and three put-backs, all listed in the draft's "Open at the close (cycle 21; blocking, reported)". The cycle-21 verifiers judge by S3-R26. Cycle 22 runs as run 9, and its fixer and verifiers read this ruling.

**S3-R27.** Cycle 21 implemented S3-R26 (`8e1fb24..d5b2ab9`, 73 commits; the last code commit is `e599ae1`): items A, B and C, RR-21, and item 5 with its probes. Its close left six blocking items and three put-backs, and this ruling routes them.

**From cycle 22 on, S3-R27 is the cycle's ruling.** S3-R26 still applies wherever S3-R27 does not change it. Where S3-R27 differs from S3-R26, from a specification or from an analysis, S3-R27 decides. The cycle-22 verifiers judge by S3-R16 to S3-R27.

Where to find things:
- **The cycle-21 verifiers' findings** are in run 9's findings file, `.build-orchestrator/s3f-c21-issues.json`. They are cited as "correct #n" and "reqs #n".
  - Fix them in S3-R1's order: blocking first.
  - A blocking finding that this ruling names is fixed as the ruling says.
  - A blocking finding that this ruling does not name follows S3-R16 and the general rulings.
- **The read-only analyses made for this ruling**, in `.build-orchestrator/s3f-c21-analysis/`:
  - `d1-stalled-subscriber.md`, with its review `d1-stalled-subscriber-review.md` (item 1);
  - `d2-present-members.md`, with `d2-present-members-review.md` (item 3);
  - `d3-many-holders.md` (item 4);
  - `d4-survivors.md`, with `d4-survivors-review.md` (items 5 and 6);
  - `d5-held-readers.md` (item 7).

  How to read them:
  - Each review corrects its report. Where a review and its report differ, the review wins. Where either differs from this ruling, the ruling wins.
  - Their line numbers are at `d5b2ab9`; re-cite them after a change.
  - Their figures are estimates from code reading and the draft's measurements, not measurements. A measurement decides.
- **Cycle 21's scratch evidence:** the close's probes in `.worktrees/s3f/.build-s3f/c21/apm/` (`ProbeC21APM.swift`, `ProbeC21Holders.swift`), and the mutation tools in `.build-s3f/c21/tools/`. Do not delete `.build-s3f/c21/`.

1. *`commitTurns(.waitersStalledSubscriber)`* (open item 1). Blocking (S3-R16 1(f)): best of 3 was 10.31, 10.45 and 11.09 ms, each at a quiet load.
   - **Route: d1's route (a) with c3, in one step.** Take c1 (`removeJob`'s walk of the smaller side) only if the case still measures above 8.5 ms after that step. The step's parts:
     - a1: one hash per terminal publish;
     - a2: one reservation per subscriber per batch;
     - a3: one publish path, `publishAll` and `broadcastAll`;
     - c3: `allBound` in `publishTerminal`.
   - **a2 has a guard** (d1 review M1). `publishAll` reserves `slots.count + n` only when `slots.count + n > 2 × slots.capacity`; otherwise it reserves nothing.
     - The guard's drop-mutant is Equivalent (S3-R19 item 2).
     - Never reserve `order` per commit.
     - This rules `reserveCapacity` for `waitersStalledSubscriber` as well. S3-R26 item 4 ruled it for `groupStalledSubscriber` only.
   - **Exclusivity** (d1 review, should-fix 2):
     - the events passed to `broadcastAll` are built once, as an array, before the access to `state.subscribers`;
     - no lazy filter is passed;
     - nothing inside the access reads `self.state`.
   - **Tests** (each new branch's drop-mutant killed 2/2):
     - T-A-1;
     - T-A-2, which asserts the hand-off directly, inside `withCheckedContinuation`;
     - T-A-3: a commit of 3 ids with one waiting and one stalled subscriber, in both orders. One id is already live in the stalled queue before the commit, so that the `coalesced` mutant dies.
   - **A scratch probe first** (d1, "Before committing"). Time 10,000 distinct terminal publishes into a fresh `SubscriberQueue` under four variants: today's `publish`, a1, a1 with a2, and `publishAll`. Also time the re-announcement shape, and ids over 15 bytes. Record the results: they are evidence, not a gate.
   - **Figures.** After each step, take `commitTurns(.waiters)` and `(.waitersStalledSubscriber)`, best of 3, with their loads.
   - **Two new cases, gated as C2.** A miss at a 1-minute load of 10 or less is blocking (S3-R16 1(f)).
     - The re-announcement shape (d1 review M1): `waitersStalledSubscriber`, with the stalled queue already holding all 10,000 ids from an earlier commit.
     - The `.failed` arm (d1 review M3): 10,000 user waiters on one job that fails at `.userInitiated`, by a 404 that `resolveAll(.failed)` resolves, with one stalled subscriber. Take its own turn and its heartbeat. The arm keeps `job.assets.sorted()` (S3-R26 answer 2).
   - **Decision rule** (d1 review M2):
     - At or below 8.5 ms closes item 1.
     - Between 8.5 and 10 ms is recorded "at the edge", with its loads. It is not blocking, and it does not start route (b).
     - Only a figure above `c2Budget` at a load of 10 or less is blocking. Report it with the per-step figures.
     - This ruling does not authorise route (b), owing the terminal events past the commit's turn: it would reverse `integrate-c21.md:447`, and it needs a new ruling.
   - **The two-subscriber figure** stays "open, for the owner" (S3-R26 answer 4). Re-measure it after item 1, and record it.
   - **Optional margin:** c6 (`guard !keys.isEmpty` in `broadcastAll`; Equivalent) may be added if `manyGroups` is still at the edge.
   - **Records:**
     - propose (S3-R6) an ARCHITECTURE §4.3 note: c3 relies on WP-B's contract that the store's `locations` keys are a subset of the binding;
     - name that dependency in `publishTerminal`'s doc comment.

2. *`purgeWhileOwedTurns`* (open item 2). Blocking (S3-R24 item 2): 10.04 ms best in one gate run.
   - **Route: the fixer's own.**
     - In `withdrawPurgedJoins`' owed-batch arm, read the purge's request before the copy lookup, so that a purge of `.all` makes no lookup. That saves about 1 ms.
     - If the re-measured parts show the walk still copies the batch's items, mutate the batch in place.
     - Then measure the parts again, as PROBE-C21-PURGE-PARTS did.
   - **The jobs' side has no figure.** `withdrawPurged` at 10,000 ids is estimated at 17–33 ms with 10,000 one-member prefetch groups (d3 (c); UNCONFIRMED).
     - Add BenchSync cases: a purge of `.all`, with one prefetch group of 10,000 members and with 10,000 one-member groups. Time the purge's synchronous turn, best of 3, with loads. A miss is blocking (S3-R16 1(f)).
     - Its route is branch-free first: one `groups` access per member with no `Group` copy (d2's A3 and A3′), and one jobs access per job.
     - A miss that stays is reported with its parts' figures, and it stays blocking.

3. *`answerPresentMembers`' answer turn* (open item 5, PROBE-C21-APM). Blocking (S3-R16 1(f)): 10.79, 12.76 and 14.17 ms best for the three shapes.
   - **Route: d2's route (a) and B1, as one change, corrected by d2's review.** Route (a) is A1, A2, A3 with A3′, A4, A5, A6a, A6b and A8. The review's corrections:
     - **M1, the zero-count guards.**
       - The single-waiter path, `answerWaiterFromStore`, stays byte-identical. The batched read exists only at `answerPresentMembers`.
       - The batched read discards its spawn result. Its doc comment gives the argument: both callers checked `isRunning` in this turn, and shutdown takes every waiter in the turn it begins. No refused arm is written.
       - A4's mark is written without a guard: `waiters[token]?.markFromStore(at:)`.
       - `Group.dropMember`'s nil-on-mismatch line is either reached by a test that kills its drop-mutant 2/2, or recorded as structural, with an argument and a citation.
       - Every relocated line is listed with its count on the final HEAD.
     - **M2:** B1 takes the code shape the review gives.
     - **B1's task.** B1 uses one owned task per answer site, with no batch bound and no test seam (review, should-fix 2). Its test checks three things: every waiter is answered `.success`, the invariants are clean, and the site has one task.
     - **M4:** A8 extends to `failed` (`EngineFailures.swift:73`): no `Job` copy is bound across `sparePresent`.
     - **Mutants.** Re-run the mutants of every condition the change moves, at their new lines (review, should-fix 4).
   - **The pins** (M3). Each is best of 3 against `c2Budget`, with 8.5 ms recorded as the edge.
     - **PIN-APM** times `unaskedIDs` and the factored `answerSite` (`EnginePresence.swift:277-292`) together, inside the actor.
       - Before timing, it sets `active.handle = nil` through a recorded state seam.
       - After timing, it asserts that `answerSite` returned true and that the job is gone with its 10,000 interests. For users, every waiter is `fromStore`; for groups, every pending is empty.
       - A run in which the guard fails is a failed case.
       - Its shapes: group, groups, users, ensure groups (with B2), and a run row (with R1).
     - **PIN-APM-SPARE** times `sparePresent`'s tail with the caller's pump and `reconcileIdle`, for group, groups and users.
   - **B2:** owe the ensure resumes through `owedAnswers` when the rows exceed `answersPerTurn`, with T-B3 (d2).
   - **Pre-ruled orders** (M6):
     - **A7.** At the present-answer site, the rows may follow the job table's order instead of the token order.
       - This is an accepted order (S3-R16 item 2), in the class of S3-R26 item 10's order of resumes.
       - Apply it only if groups, ensure groups or users is above 8.5 ms after (a), B1 and B2, and only after an audit of the answer-site tests for order assertions.
       - A test that depends on the order keeps the sorted order there, and the case is reported (G3).
     - **R1.** For a run row, make one progress offer with the final count, where the per-id answers made an immediate offer and a trailing one.
       - It changes no answer and no terminal event, and it keeps R-SYN-12. It is non-blocking, recorded as a residual risk.
       - Its row-kind branch is reached by a run-row answer-site test that kills its drop-mutant 2/2.
   - **The group walks** (M5). This applies if groups or ensure groups stays above 8.5 ms after (a), B1, B2 and A7.
     - First, cut the turn's two walks over every group without a branch: `materializeEnsures`' `compactMap` and `pruneBoundContent`'s `contains`. Read only the needed fields, with no `Group` copy.
     - Only if that is not enough, add an index of the ensure groups with fetches left, with a recount clause in `invariantViolations()`. Each update's drop-mutant is killed 2/2.
   - **A miss that stays** above `c2Budget` is blocking. Report it with the per-step figures.
   - **The integrity path's first turn** (d2 review, §4 item 2) is an inventory row with a figure. It runs two 10,000-id sorts, estimated at 6.5–7.5 ms (UNCONFIRMED).

4. *One id held by 10,000 interests* (open item 6, PROBE-C21-HOLDERS).
   - **Scope.**
     - The shape has 2 ids, not 10,000, so it is outside S3-R25's reference set as written (10,000 ids, however their interests are grouped).
     - Like the second subscriber (S3-R26 answer 4), it is "open, for the owner". For cycle 22 it is neither accepted nor blocking.
     - This replaces the condition of `integrate-c21.md` item B's residual 5 ("blocking if a case with h near 10,000 misses `c2Budget`"), which S3-R26 adopted with that file's residual risks.
     - The orchestrator puts the shape to the owner, with d3's sizing proposal, before it rules the close-out converged.
   - **The same mismatch inside the reference set.** The bounds count ids, and the cost counts (id, interest) pairs (d3 (c)).
     - Measure two in-letter shapes at 10,000 ids, each with k interests per id:
       - k = 2: a user waiter and a prefetch group per id;
       - k = 4: four prefetch groups over the same 10,000 ids (d3's `fourGroupsFollowTurns`).
     - For each, take the follow's visit with its moves, and the drain's replay of an owed batch at sites 1 and 3. Best of 3, with loads.
     - A miss at a load of 10 or less is blocking (S3-R16 1(f)).
   - **If any of them misses,** its route is d3's pair counting, P1–P4, in one step with its pins:
     - PAIRS-T1 to T4, each killing its mutant 2/2;
     - the PAIRS-T5 probes of the split state, in both orders;
     - the BenchSync cases d3 names.

     That step reverses, for pairs:
     - S3-R26 answer 7's "an id taken whole";
     - `integrate-rr21.md`'s Own 8, R8, R9 and D8, and R7's step (3).

     It authorises one-to-one updates of the k ≥ 2 low-budget turn-count assertions, at least `drainReroutesAnOwedIDWithAllItsTokensInOneTurn` and `barrierBoundsOneIDMovesOffAHolderPerTurn`. S3-R26 item 1's rules for such updates apply. No answer, MUST or invariant assertion changes.
   - **If all pass,** pair counting is not built in cycle 22. Record the figures. PROBE-C21-HOLDERS's figures stay recorded for the owner.
   - **Margin:** d3's branch-free A1 (hoist `decisionNow()` into the creation branch) and A2 (format the transfer id once) may be taken wherever they apply, with no new branch.

5. *The twelve survivors* (open item 3). Blocking (S3-R16 1(e)). Dispose of each as d4 says, corrected by its review.
   - **Remove** r7's `atEnd` (S3-R19 item 3): its only production caller runs for a downloading job, so `atEnd` is always false.
     - Delete `EngineFailures.swift:834` and the `!atEnd` conjunct at `:840`, and rewrite the comment at `:829-833`.
     - Rewrite r6's mutant text after the removal, and re-run r6 2/2 (G2).
   - **Kill** these, with the tests d4 gives in §3.3–§3.11 and the review's corrections:
     - b23-no-lane and b23-no-kind: two new rr21-T13 arguments, `userGroup` and `prefetchWaiters`;
     - f7-delisted-stays: in both orders, with an apply held in flight across the read (review M4). If that shape cannot be built, kill f7 in `sweepFollowsFirst`, and record the `followVisitedFirst` half as a residual risk (S3-R16 item 2). The hold for a manifest catch-up changes no answer.
     - b22-no-waiter-owner: with the answers in review M3;
     - p7 and r5: one pin-end test, in which J's answer is `.notFound` (review M2);
     - r8: kill it with a prefetch-lane waiter's answer and the throttle at arrival (review M1);
     - vy-owed-moves-too: with the follow-up turns held (review, should-fix 3);
     - r2c;
     - b22-no-run-owner: its state arises, so the test awaits `state.run == nil` (review, should-fix 2).
   - **r2b is open** (review M5): it is not Equivalent. Kill it 2/2 in `sweepFollowsFirst` under S3-R26 answer 1, or show that its state cannot be built. It stays blocking until then. Keep the `made` cache.
   - **Every kill** is a deterministic test, run in both orders, that asserts visit-first's answers.
     - A branch whose state arises only in `sweepFollowsFirst` follows S3-R26 answer 1. b22-no-waiter-owner, r8, vy and r2b are such branches.
     - Where a test does not show the difference that d4 predicts, the mutant stays open. Report it with what the test showed.
     - Never weaken a test to make it pass (G3). A kill that comes from a hang or a time limit does not count.
   - **Record `followedLane`'s lane** in the draft. It decides only the 429's retry policy (d4 §1, confirmed by its review). Record the tuning under which a wrong lane changes an answer, and whether the default tuning's backoff can (d4 §5).

6. *The four unreached places* (open item 4). Blocking (S3-R16 1(e), S3-R25 item 10).
   - **`EngineFailures.swift:861-862` and `:868-870`** belong to b22, under item 5.
   - **`EngineShutdown.swift:178-183`, `settle`'s slice.** Extend T-A3 (`EngineOwedAnswersTests.swift:190`) to 600 callers, shut down, and assert that the slices are exactly [512, 88]. The drop-mutant gives [600].
   - **`EngineFollow.swift:883`, `replayVerdict`'s second guard.** Both halves are unreachable (d4 §2, confirmed by its review), so:
     - remove `:882-884` and update the doc sentence at `:876`;
     - add an epoch clause next to the unfailed one (`EngineCommands.swift:2275`): "jobs whose failure verdict waits for a follow are at another epoch";
     - add one test with `violations(after:)`, from the `sweepFollowsFirst` state of `barrierFailsA429BeyondTheCapsAsOnArrival`. It sets the job `.queued`, then bumps its epoch, and expects each clause in turn. It kills both clauses' drop-mutants 2/2.

7. *The held-turn readers* (put-back). d5 found no racy reader.
   - Replace the draft's "not audited one by one … Put to the orchestrator" (`s3f.md:6653-6655` and `:9807-9808`) with d5's classification, suite by suite.
   - Add d5's pin at `EngineFollowBarrierWaitingTargetTests.swift:191-193`: `barrier` in `afterTurn`, and a `#require` that the move's turn is not the follow's last. Run it 2/2 in both orders.
   - Do not hold attempt terminals globally.

8. *`releaseRerouteHolds`' inventory row* (put-back). Give it one of these (S3-R26 item 9):
   - a BenchSync figure in its worst grouping;
   - the argument that it is O(1) amortised, with the bound on the publications that can wait, cited from the code.

9. *The fixer's own check before it returns.* S3-R26 item 9 applies again, on the final HEAD:
   - S3-R25 item 10, for every changed line and branch;
   - the inventory: every new per-id, per-pair, per-event or per-row operation of items 1 to 4 is a row with its cost. It also gets a figure, unless it is O(1) amortised and no specification names a case for it;
   - the re-measure of every C2 case the cycle's code passes through;
   - the margin list: every case above 8.5 ms, recorded "at the edge".

10. *Order of work.* Commit each step on its own. Run red first wherever the shape exists before the fix (S3-R26 item 11's rules). Keep the draft's cycle-22 status list current, so that a resumed fixer continues from the HEAD.
    0. Run `verify.sh --quick` on the HEAD. Take the 'before' figures of every case that items 1 to 4 add, best of 3 with loads. Item 1's scratch probe is part of this step.
    1. The verifiers' blocking findings of class S3-R16 1(a) to 1(c) (an answer, a MUST or invariant, liveness), each failing test first.
    2. Item 6's removal and settle slice, and item 5's removal and its cheap kills (b23 and f7), in d4's order.
    3. Item 1.
    4. Item 2.
    5. Item 3, in d2 review §4's order.
    6. Item 4's measurements, and pair counting if they trigger it.
    7. Item 5's remaining kills: b22, p7 with r5, r8, vy, r2c and r2b. Then the verifiers' other findings.
    8. Items 7 and 8, then the close: item 9, and every gate on the final HEAD.

    **Expect the weekly limit.** This cycle may be cut off by the weekly usage limit. That is why the C2 routes come before the long survivor work. A cut-off leaves every finished step committed.
