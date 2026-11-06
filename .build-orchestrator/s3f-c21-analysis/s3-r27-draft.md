## Orchestrator ruling added 2026-11-05 20:00 (the cycle-21 fixer's put-backs; written while the cycle-21 verifiers run, before the cycle-22 fixer starts)

Run 8's cycle-21 fixer returned at 17:54. It reported six blocking items and three put-backs, all listed in the draft's "Open at the close (cycle 21; blocking, reported)". The cycle-21 verifiers judge by S3-R26. Cycle 22 runs as run 9, and its fixer and verifiers read this ruling.

**S3-R27.** Cycle 21 implemented S3-R26 (`8e1fb24..d5b2ab9`, 73 commits; the last code commit is `e599ae1`): items A, B and C, RR-21, and item 5 with its probes. Its close left six blocking items and three put-backs, and this ruling routes them.

**From cycle 22 on, S3-R27 is the cycle's ruling.** S3-R16 to S3-R26 still apply wherever S3-R27 does not change them. Where S3-R27 differs from an earlier ruling, from a specification or from an analysis, S3-R27 decides. The cycle-22 verifiers judge by S3-R16 to S3-R27.

Where to find things:
- **The cycle-21 verifiers' findings** are in run 9's findings file, `.build-orchestrator/s3f-c21-issues.json`. They are cited as "correct #n" and "reqs #n".
  - Fix them in S3-R1's order: blocking first.
  - A verifier finding is **named** by this ruling when it reports the same case, mutant or `path:line` (at `d5b2ab9`) as an item here.
    - The fixer records the mapping ("correct #n → item k") in the draft's cycle-22 status list.
    - A named finding is closed by its item's route and decision rule, even where the finding proposes another fix.
  - A blocking finding that this ruling does not name follows S3-R16 and the general rulings.
- **The read-only analyses made for this ruling**, in `.build-orchestrator/s3f-c21-analysis/`:
  - `d1-stalled-subscriber.md`, with its review `d1-stalled-subscriber-review.md` (item 1);
  - `d2-present-members.md`, with `d2-present-members-review.md` (item 3);
  - `d3-many-holders.md` (items 2 and 4);
  - `d4-survivors.md`, with `d4-survivors-review.md` (items 5 and 6);
  - `d5-held-readers.md` (item 7).

  How to read them:
  - Each review corrects its report. Where a review and its report differ, the review wins. Where either differs from this ruling, the ruling wins.
  - **What in a review binds.** A review's must-fix items bind, as this ruling corrects them. Its should-fix items bind only where this ruling names them, as this ruling corrects them:
    - d1 review: should-fix 2, 3, 4, 5, 7, 8 and 9, and should-fix 6 where c6 is taken;
    - d2 review: should-fix 2, 3, 4, 5, 7 and 8;
    - d4 review: should-fix 1 to 5.

    A review's "What the ruling must add", a report's recommendation, every other should-fix item and every "optional" in a report bind only as this ruling carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.
  - Their line numbers are at `d5b2ab9`; re-cite them after a change.
  - Their figures are estimates from code reading and the draft's measurements, not measurements. A measurement decides.
- **Cycle 21's scratch evidence:** the close's probes in `.worktrees/s3f/.build-s3f/c21/apm/` (`ProbeC21APM.swift`, `ProbeC21Holders.swift`), and the mutation tools in `.build-s3f/c21/tools/`. Do not delete `.build-s3f/c21/`.

**How a C2 figure is read in cycle 22.** This applies to every case in items 1 to 4 and 8, and to every case that item 9 re-measures.
- **The bar** is `c2Budget`, 10 ms (S3-R5). 8.5 ms is never a gate.
- **The figure** is the one the case asserts: for a BenchSync case, its heartbeat (longest wait), best of 3; for an in-actor pin (PIN-APM, PIN-APM-SPARE), its in-actor time, best of 3. Where both exist, the other is recorded beside it. A case that asserts both (for example `commitRerouteTurns`' heartbeat and held turns, `BenchSyncReroutes.swift:110-128`) misses when either misses.
- **The load** is the 1-minute load read just before the case's first timed run and just after its last. Both are recorded, with the three load averages (S3-R23 item 1). "At a load of 10 or less" means both readings are 10 or less.
- **A miss** is a best of 3 above `c2Budget` at a load of 10 or less, in any run of that case on the HEAD being judged: the fixer's gate run, a re-run alone, or a verifier's run.
  - A passing run does not cancel a miss.
  - A case that misses in one such run and passes in another is reported as a miss, with both figures. This follows S3-R26 item 4's commit window and cycle 21's `purgeWhileOwedTurns`.
- **A miss seen only at a load above 10** follows S3-R23 items 2 and 3. If no run reaches a load of 10 or less, the case is "not measured at a quiet load".
- **8.5 ms** is read on the same figure, under the same load rule. It decides only the routes this ruling makes conditional on it, and the margin list (item 9). Such a route is decided on the fixer's figure at the point the route names (item 10's rule applies where no quiet load is reached). A verifier's figure on the other side of 8.5 ms goes to the margin list and is not blocking.
- **No work is hidden from a measurement.** A case or pin times the whole of the work it names. What a pin leaves out of the turn is listed in the draft beside its figure.

1. *`commitTurns(.waitersStalledSubscriber)`* (open item 1). Blocking (S3-R16 1(f)): best of 3 was 10.31, 10.45 and 11.09 ms, each at a quiet load.
   - **Route: d1's route (a) with c3, in one step.** Take c1 (`removeJob`'s walk of the smaller side) only if `commitTurns(.waitersStalledSubscriber)`'s heartbeat, best of 3, is still above 8.5 ms after that step. The step's parts:
     - a1: one hash per terminal publish;
     - a2: one reservation per subscriber per batch;
     - a3: one publish path, `publishAll` and `broadcastAll`;
     - c3: `allBound` in `publishTerminal`.
   - **a2 has a guard** (d1 review M1). `publishAll` reserves `slots.count + n` only when `slots.count + n > 2 × slots.capacity`; otherwise it reserves nothing.
     - The guard's drop-mutant is Equivalent (S3-R19 item 2).
     - Never reserve `order` per commit.
     - This rules `reserveCapacity` for `waitersStalledSubscriber` as well (d1 review should-fix 5). S3-R26 item 4 ruled it for `groupStalledSubscriber` only.
   - **Exclusivity** (d1 review, should-fix 2):
     - `generation` is captured into a local before the access to `state.subscribers`;
     - the ids are filtered once, into an array (`announced`), before that access;
     - the events passed to `broadcastAll` may be a lazy `map` over that array (d1 §3, a3); no lazy `filter` is passed;
     - nothing inside the access reads `self.state`.
   - **Tests and kills** (S3-R16 1(e); d1 review, "The branches, and how each is killed"):

     | Branch | Kill |
     |---|---|
     | a1's compound `if` | T-A-1: both flips of `replaced`, and dropping `isProgress`, each 2/2 |
     | a2's reserve and its guard | Equivalent (S3-R19 item 2), with the argument in the draft |
     | `publishAll`'s hand-off `if let` | T-A-2, which asserts the hand-off directly, inside `withCheckedContinuation` (d1 review should-fix 9), 2/2 |
     | `coalesced ? 1 : 0` | T-A-3: a commit of 3 ids with one waiting and one stalled subscriber, 2/2 in both orders. One id is already live in the stalled queue before the commit (d1 review should-fix 3). It asserts d1 §3's four checks |
     | c3's `allBound` | Forced to `true`: killed by T-ORDER (`EngineCommitWindowTests.swift:18-79`), 2/2 in `sweepFollowsFirst`, under S3-R26 answer 1. The draft cites why `followVisitedFirst` cannot reach the state: its visit removed zz-o5 from `job.assets` before the commit (d1 review, Settled 3). Dropped ("always look up"): Equivalent |
     | c1's two arms, if taken | T-C1-1, with another job's `.transfer` key and a `.run` key in `lastEmitted`, and T-PG4, which already reaches the `lastEmitted` arm, each 2/2. The arm choice is Equivalent (d1 review should-fix 8) |

     If c1 is taken, it is an inventory row (item 9) with a BenchSync figure: many live progress keys and many job removals in one turn. If no such case can be built, the draft records why.
   - **A scratch probe first** (d1 §4 item 3, "Measure first"; the controls are d1 review, should-fix 7). Time 10,000 distinct terminal publishes into a fresh `SubscriberQueue` under four variants: today's `publish`, a1, a1 with a2, and `publishAll`. Also time the re-announcement shape, and ids over 15 bytes. Record the results: they are evidence, not a gate. The probe is part of item 10's step 0.
   - **Figures.** Take these on `d5b2ab9` (step 0), after the step, and after c1 if it is taken:
     - `commitTurns(.waiters)`, `(.waitersStalledSubscriber)`, `(.groupStalledSubscriber)` and `(.manyGroups)`;
     - `commitTwoStalledSubscribersTurns`.

     Each is best of 3, heartbeat and in-actor turn, with loads. In this item, "the per-step figures" means these figures together with the scratch probe's four variants.
   - **Two new cases, gated as C2.** Each is a committed BenchSync case that asserts `c2Budget`: gated, not only recorded as d1 review M1 and M3 have them. The gate is the heartbeat, best of 3; the in-actor turn is recorded. A miss is blocking (S3-R16 1(f)).
     - The re-announcement shape (d1 review M1): `waitersStalledSubscriber`, with the stalled queue already holding all 10,000 ids from an earlier commit.
     - The `.failed` arm (d1 review M3): 10,000 user waiters on one job that fails at `.userInitiated`, by a 404 that `resolveAll(.failed)` resolves, with one stalled subscriber. The arm keeps `job.assets.sorted()` (S3-R26 answer 2).
   - **Decision rule** (d1 review M2), on `commitTurns(.waitersStalledSubscriber)`'s heartbeat, best of 3:
     - At or below 8.5 ms closes item 1.
     - Between 8.5 and 10 ms is recorded "at the edge", with its loads. It is not blocking, and it does not start route (b).
     - Only a miss is blocking. Report it with the per-step figures.
     - The two new cases are judged on their own, as above.
     - This ruling does not authorise route (b), owing the terminal events past the commit's turn: it would reverse `integrate-c21.md:447`, and it needs a new ruling.
   - **The two-subscriber figure** stays "open, for the owner" (S3-R26 answer 4), whatever it measures. Re-measure `commitTwoStalledSubscribersTurns` after the step, and record it with its loads. It is neither accepted nor blocking in cycle 22, and a pass does not close it: the owner sizes the subscriber count.
   - **Optional margin: c6.** `guard !keys.isEmpty else { return }` at the top of `publishTerminal`, after its `lane` guard and the `keys` sort (`EngineJobs.swift:796-799`), before the filter, so that neither arm filters or broadcasts when no subscriber exists (d1 §3; d1 review should-fix 6). It is Equivalent. Add it only if `commitTurns(.manyGroups)` is above 8.5 ms after the step.
   - **Records** (d1 review should-fix 4):
     - propose (S3-R6) an ARCHITECTURE §4.3 note: c3 relies on WP-B's contract that the store's `locations` keys are a subset of the binding;
     - name that dependency in `publishTerminal`'s doc comment.

2. *`purgeWhileOwedTurns`* (open item 2). Blocking (S3-R24 item 2): 10.04 ms best in one gate run.
   - **Route: the fixer's own, in order, each part its own commit.** After each part, re-measure `purgeWhileOwedTurns` and PROBE-C21-PURGE-PARTS, best of 3, with loads.
     1. In `withdrawPurgedJoins`' owed-batch arm, read the purge's request before the copy lookup, so that a purge of `.all` makes no lookup. That saves about 1 ms. The early return's drop-mutant changes only cost: Equivalent (S3-R19 item 2; d4 §3.3). b23's kill tests purge a `.scope`, so they stay valid.
     2. Only if `purgeWhileOwedTurns` is still above 8.5 ms after (1): mutate the owed batch in place, with no copy of its items.
   - **Decision rule** (as item 1's):
     - at or below 8.5 ms closes the item;
     - 8.5 to 10 ms is recorded "at the edge", and is not blocking;
     - a miss is blocking, reported with the parts' figures.
   - **The jobs' side has no figure.** `withdrawPurged` with 10,000 one-member prefetch groups on one id is estimated at 17–33 ms, and the same O(pairs) holds for 10,000 one-member groups on 10,000 ids (d3 §2(c) row 14; UNCONFIRMED).
     - Add two BenchSync cases for a purge of `.all` over 10,000 distinct ids, each id with its own content and job: (i) one prefetch group of 10,000 members; (ii) 10,000 one-member prefetch groups.
     - Each case's figure is its heartbeat, best of 3, with loads, as "How a C2 figure is read" says; the purge's synchronous turn is recorded beside it. A miss is blocking (S3-R16 1(f)).
     - The same purge over one id held by 10,000 groups (row 14's shape) is outside the per-id dimension (item 4). It is measured once and recorded for the owner.
   - **The jobs' side's route is branch-free.** Use one `groups` access per member with no `Group` copy, and one jobs access per job.
     - Where it needs `Group.dropMember` (d2's A3 and A3′), item 2 lands A3 and A3′ in its own step, with d2 review M1's obligation for the pending check (item 3). Item 3 then reuses them.
     - A miss that stays is reported with its parts' figures, and it stays blocking.

3. *`answerPresentMembers`' answer turn* (open item 5, PROBE-C21-APM). Blocking (S3-R16 1(f)): 10.79, 12.76 and 14.17 ms best for the three shapes.
   - **Route: d2's route (a) and B1, as one step (item 10, step 5), corrected by d2's review.** Route (a) is A1, A2, A3 with A3′, A4, A5, A6a, A6b and A8.
   - **Sub-steps.** The step is committed in d2 review §4 item 3's sub-steps 1 to 11.
     - The behaviour-free factoring of `answerSite` and of `sparePresent`'s tail lands first. PIN-APM and PIN-APM-SPARE are then committed red, on their own (item 10's red-first rules).
     - If item 2 landed A3 and A3′, sub-step 4 reuses them.
     - PIN-APM's and PIN-APM-SPARE's figures are taken after sub-step 7 and at the end.
     - A7 and the group walks (sub-steps 9 and 10) run only under their own rules below.
   - **Audit first** (d2 review should-fix 3). Before A2 and A5, audit the `waitUntil` and `awaitCondition` predicates of the answer-site suites for a state that exists only mid-turn: a partial removal, or some waiters marked but not all. Record the audit. A5 moves `notifyObservers()` to the callers, with no "quiet" flag.
   - **M1, the zero-count guards.**
     - The single-waiter path, `answerWaiterFromStore`, stays byte-identical. The batched read exists only at `answerPresentMembers`.
     - The batched read discards its spawn result. Its doc comment gives the argument: `spawn` refuses only in `.shuttingDown`, `.shutDown` and `.degraded` (`EngineLifecycle.swift:52-56`); both callers checked `isRunning` earlier in this turn (`EnginePresence.swift:277`, `EngineFailures.swift:542`); and shutdown takes every waiter in the turn it begins. No refused arm is written.
     - A4's mark is written without a guard, `self.state.waiters[row.token]?.markFromStore(at: transfer)`, and the read is collected unconditionally. A missing waiter makes its read return at `readPresentLocation`'s existing guard (`EnginePresence.swift:151`, unchanged), so A4 adds no conditional.
     - `Group.dropMember`'s nil-on-mismatch line is either reached by a test that kills its drop-mutant 2/2, or recorded as structural, with an argument and a citation.
     - Every relocated line is listed with its count on the final HEAD.
   - **M2:** B1 takes the code shape the review gives.
   - **B1's task.** B1 uses one owned task per answer site, with no batch bound and no test seam (d2 review, should-fix 2): `// REENTRANCY: RE-S36` on the loop's await, RE-S21 on the spawn closure.
     - Its test puts five waiters at the site and holds the attempt, so that no other spawn happens in the answer turn.
     - It asserts that every waiter is answered `.success` with the store's location, that `invariantViolations()` is empty, and that `state.lastTaskKey` advances by exactly one across the answer turn.
     - The drop-mutant of the read loop's call is killed 2/2.
   - **M4:** A8 extends to `failed` (`EngineFailures.swift:73`): read `job.identity` and the assets argument into locals before the reads, so that no `Job` copy is bound across `sparePresent` (`:145`, `:153`, `:193`).
   - **Mutants.** Re-run the mutants of every condition the change moves, at their new lines (d2 review, should-fix 4). Each is killed 2/2 at its new line, or given a disposition under S3-R25 item 10.
   - **Shutdown with the batched read** (d2 review, should-fix 7). A cancelled read task still runs its remaining reads, so the shutdown's join waits longer. This is timing: record it as a residual risk (S3-R16 item 2). Add no `Task.isCancelled` branch.
   - **C7.** Cite A3′'s and A6a's `Dictionary` APIs in the iOS SDK's `Swift.swiftinterface` as well as the macOS one (d2 review §1).
   - **The pins** (M3). Each is best of 3 against `c2Budget`, with 8.5 ms recorded as the edge.
     - **PIN-APM** times `unaskedIDs` and the factored `answerSite` (`EnginePresence.swift:277-292`) together, inside the actor.
       - Before timing, it sets `active.handle = nil` through a recorded state seam.
       - After timing, it asserts that `answerSite` returned true and that the job is gone with its 10,000 interests. For users, every waiter is `fromStore`; for groups, every pending is empty.
       - A run in which an assertion fails is a failed case.
       - Its shapes: group, groups, users, ensure groups (with B2), and a run row (with R1). The groups and ensure-groups shapes keep their 10,000 groups registered through the timed tail, so that `materializeEnsures`' and `pruneBoundContent`'s walks are inside the figure (d2 review M5).
       - The turn also runs `drive`'s continuation: `taskEnded` on `true`, and the `interests` walk on `false` (`EngineDispatch.swift:812`). Neither is in the pin; the draft lists them beside its figure (d2 review should-fix 5).
     - **PIN-APM-SPARE** times `sparePresent`'s tail at the 404 end, where the assets argument is the job's own set, the worse end (d2 review M4).
       - The timed span is `EngineFailures.swift:541-552`, factored into an internal function the bench calls inside the actor, together with the caller's `pump` and `reconcileIdle`.
       - Shapes: group, groups and users.
       - After timing, it asserts that the job was removed and every interest answered. For users, every waiter is `fromStore`; for groups, every pending is empty. A run in which an assertion fails is a failed case.
       - A7 and the group walks apply to its groups and users shapes exactly as to PIN-APM's.
   - **B2:** owe the ensure resumes through `owedAnswers` when the rows exceed `answersPerTurn`, with T-B3 (d2). `dropGroupMember`'s `owing` parameter defaults to `false`, so that the reroute and purge callers keep their behaviour (d2 review should-fix 8).
   - **Pre-ruled classes** (M6):
     - **A7.** At the present-answer site, the rows may follow the job table's order instead of the token order.
       - This is an accepted order (S3-R16 item 2), in the class of S3-R26 item 10's order of resumes.
       - Apply it only if groups, ensure groups or users is above 8.5 ms after (a), B1 and B2, and only after an audit of the answer-site tests for order assertions.
       - A test that depends on the order keeps the sorted order there, and the case is reported (G3).
     - **R1 is part of the route.** It lands at sub-step 11. For a run row, make one progress offer with the final count, where the per-id answers made an immediate offer and a trailing one.
       - This ruling adds R1's difference, one progress offer where there were two, to S3-R16 item 2's non-blocking list, for this site only. It changes no answer and no terminal event, and it keeps R-SYN-12. It is recorded as a residual risk.
       - Its row-kind branch is reached by a run-row answer-site test that kills its drop-mutant 2/2.
       - PIN-APM's run-row shape is gated from that sub-step on.
   - **The group walks** (M5). This applies if groups or ensure groups stays above 8.5 ms after (a), B1, B2, and A7 where A7 applies.
     - First, cut the turn's two walks over every group without a branch: `materializeEnsures`' `compactMap` and `pruneBoundContent`'s `contains`. Read only the needed fields, with no `Group` copy.
     - Only if that is not enough, add an index of the ensure groups with fetches left, with a recount clause in `invariantViolations()`. Each update's drop-mutant is killed 2/2.
   - **A miss that stays** above `c2Budget` is blocking. Report it with the per-step figures. Route (c), a bounded answer over turns (d2 §2.4), is not authorised in cycle 22.
   - **The inventory** (item 9) names both callers' tails as rows, each with its pin: `answeredFromStore`'s (PIN-APM) and `sparePresent`'s (PIN-APM-SPARE) (d2 review §4 item 1).
   - **The integrity path's first turn** (d2 review, §4 item 2) is an inventory row. It runs two `job.assets.min()` walks, two 10,000-id sorts and 10,000 inserts (`EngineFailures.swift:77`, `:80`, `:193`, `:494`, `:535`), estimated at 6.5–7.5 ms (UNCONFIRMED).
     - Give it a BenchSync figure at 10,000 ids, best of 3, with loads.
     - A miss is blocking (S3-R25 item 3). Its route is not ruled here: report it with the figure.

4. *One id held by 10,000 interests* (open item 6, PROBE-C21-HOLDERS), and the per-id dimension.
   - **Scope: the per-id dimension, sized for cycle 22,** as S3-R26 answer 4 sized the subscribers.
     - S3-R25's reference set stays 10,000 ids, however their interests are grouped. For cycle 22, its per-id dimension is sized at up to 4 interests on one id. That covers one prefetch group, many groups, one user waiter per id, and any mix with at most 4 interests on every id.
     - More than 4 interests on one id, however many ids the shape has, is "open, for the owner". That includes:
       - PROBE-C21-HOLDERS (2 ids), and any variant padded with other ids;
       - d3 §2(c) rows 1 to 8 with one hot id;
       - row 12 with k > 4;
       - row 14 on one id (item 2);
       - d3's `manyHolders*` cases.
     - Such a shape is measured once and recorded with its figure and loads. For cycle 22 it is neither accepted nor blocking.
     - The owner has been asked to size the dimension, with d3 §3's sizing proposal. The orchestrator does not rule the close-out converged before the owner answers.
     - This is not S3-R20's or S3-R21's option (c). Those shapes had 10,000 ids, inside the letter. This ruling sizes a dimension that no ruling had sized, as answer 4 did, and waives nothing (S3-R20 item 1).
     - For shapes with more than 4 interests on one id, this replaces two conditions:
       - the condition the cycle-21 fixer recorded for `integrate-c21.md` item B's residual 5 under S3-R26 item 10 ("blocking if a case with h near 10,000 misses `c2Budget` at a quiet load", `s3f.md:5645-5646`);
       - `integrate-rr21.md`'s residual "One id with k tokens costs k re-routes in one id slot" (`:622-624`), as S3-R26 item 1 made it a gate ("a probe with very many tokens per id").

       For k ≤ 4 both stay gates: `commitTwoTokensTurns` and the cases below.
   - **The in-letter shapes.** The bounds count ids, and the cost counts (id, interest) pairs (d3 §2(c)). Commit BenchSync cases, named in the draft, at 10,000 ids with k interests on every id:
     - k = 2: a user waiter and a one-member prefetch group per id;
     - k = 4: four prefetch groups over the same ids (d3's `fourGroupsFollowTurns`).

     For each, take four figures, best of 3, with loads. Each is a BenchSync case's heartbeat, as "How a C2 figure is read" says, and the turn it names is recorded beside it:
     - a follow's visit with its moves and its rest;
     - the drain's replay of an owed batch at site 1;
     - the same at site 3;
     - site 2's verdict turn with its take-off (d3 §2(c) row 7).

     'Before' figures come from step 0. The deciding figures are taken in step 6, on the HEAD after step 5, and after A1 and A2 if they are taken. A miss is blocking (S3-R16 1(f)).
   - **If any of them misses,** its route is d3's pair counting, P1–P4, in one step with its pins:
     - PAIRS-T1 to T4, each killing its mutant 2/2;
     - the PAIRS-T5 probes of the split state, in both orders. They assert answers only, and PAIRS-T5 (i) also checks the run's report counts (d3 §4 item 1). A probe that breaks S3-R16 item 1 in either order is blocking, and P3 applies;
     - the BenchSync cases d3 names. The in-letter cases (`fourGroupsFollowTurns`, the k = 2 cases, and `commitTwoTokensTurns`, re-measured) are gated. `manyHoldersMoveTurns`, `manyHoldersOwedTurns`, `manyHoldersTakeOffTurns` and `manyHoldersCommitTurns` are recorded, not gated, as `commitTwoStalledSubscribersTurns` is; their figures go to the owner.

     That step reverses, for pairs:
     - S3-R26 answer 7's "an id taken whole";
     - `integrate-rr21.md`'s Own 8, R8, R9 and D8, and R7's step (3);
     - the doc comments of `followIDsPerTurn` (`EngineMoves.swift:228-235`) and `continueMove` (`:282-294`).

     S3-R22 item 1 and S3-R25 item 1 are then read as pairs, and `integrate-rr21.md`'s residual "One id with k tokens costs k re-routes in one id slot" is closed.

     It authorises one-to-one updates of the k ≥ 2 low-budget turn-count assertions, at least `drainReroutesAnOwedIDWithAllItsTokensInOneTurn` and `barrierBoundsOneIDMovesOffAHolderPerTurn`. S3-R26 item 1's rules for such updates apply. No answer, MUST or invariant assertion changes.
   - **If all pass,** pair counting is not built in cycle 22. Record the figures. PROBE-C21-HOLDERS's figures stay recorded for the owner.
     - This departs from d3's "implement (b) whatever the owner rules" (d3 §0, §3.3). Pair counting reverses S3-R26 answer 7 and four `integrate-rr21.md` rules, and adds a branch, five mutants and five probes. Under S3-R16 item 3 it is built only on a measured in-letter miss, or on the owner's sizing.
   - **Margin.** d3's branch-free A1 (hoist `decisionNow()` into the creation branch) and A2 (format the transfer id once) may be taken, with no new branch. If taken, they land at the start of step 6, each as its own commit, before item 4's deciding figures.

5. *The twelve survivors* (open item 3). Blocking (S3-R16 1(e)). Dispose of each as d4 says, corrected by its review.
   - **Remove** r7's `atEnd` (S3-R19 item 3): its only production caller runs for a downloading job, so `atEnd` is always false.
     - Delete `EngineFailures.swift:834` and the `!atEnd` conjunct at `:840`. Replace the comment at `:829-833` with d4 review's text ("What the ruling must add" 4).
     - Rewrite the mutant texts in `.build-s3f/c21/tools/mut-c4fix.py` after the removal (`:42-44`; all three match `!atEnd`). The original of each becomes `if join.chain != nil, !here(join.asset) {`:
       - r6's mutant becomes `if join.chain != nil {`;
       - r8's mutant becomes `if !here(join.asset) {`;
       - r7's entry is retired with its branch.
     - Re-run r6 2/2 in its LANE list, on the new code (G2). r8 is killed in step 7, on its rewritten text.
   - **Kill** these, with the tests d4 gives in §3.3–§3.11 and the review's corrections:
     - b23-no-lane and b23-no-kind: two new rr21-T13 arguments, `userGroup` and `prefetchWaiters`. Under `.prefetchWaiters`, also record W3's answer and the job set after the replay (d4 review should-fix 5);
     - f7-delisted-stays: in both orders, with an apply held in flight across the read (review M4). If, with the apply held in flight, the commit takes another path than T-R1's in `followVisitedFirst`, use the fallback. The draft names the line that differs, with the run's output. A shape that runs but does not separate the mutant is not this fallback: the mutant stays open, as below. Under the fallback, kill f7 in `sweepFollowsFirst`, and record the `followVisitedFirst` half as a residual risk (S3-R16 item 2). The hold for a manifest catch-up changes no answer;
     - b22-no-waiter-owner: with the answers in review M3;
     - p7 and r5: one pin-end test, in which J's answer is `.notFound` (review M2);
     - r8: kill it with a prefetch-lane waiter's answer and the throttle at arrival (review M1);
     - vy-owed-moves-too: with the follow-up turns held (review, should-fix 3);
     - r2c;
     - b22-no-run-owner: its state arises, so the test awaits `state.run == nil` (review, should-fix 2).
   - **r2b is open** (review M5): it is not Equivalent. Kill it 2/2 in `sweepFollowsFirst` under S3-R26 answer 1, or argue in the draft that no take-off item's entry can name a later verdict's content, citing every writer of `rerouteFor` and the take-off's ids (d4 review, "What the ruling must add" 1). It stays blocking until then. Keep the `made` cache.
   - **Every kill** is a deterministic test, run in both orders, that asserts visit-first's answers.
     - Each new test's first run on unmutated code is green, in both orders, before its kill counts (d4 review, "What the ruling must add" 5).
     - A branch whose state arises only in `sweepFollowsFirst` follows S3-R26 answer 1. b22-no-waiter-owner, r8, vy and r2b are such branches.
     - Where a test does not show the difference that d4 predicts, the mutant stays open. Report it with what the test showed.
     - Never weaken a test to make it pass (G3). A kill that comes from a hang or a time limit does not count.
   - **Record `followedLane`'s lane** in the draft. It decides only the 429's retry policy (d4 §1, confirmed by its review). Record the tuning under which a wrong lane changes an answer (`shortInteractiveRetry`: `.exhausted` against `.until`; the survivor tests use it).
   - **The default-tuning case** (d4 §1; §5 item 6, UNCONFIRMED). From the third attempt, a seeded background ceiling above `interactiveMaxWait` can make another user's request fail fast where the interactive end lets it wait.
     - It is ruled S3-R16 item 2, "which lane's backoff policy applies", under S3-R26 answer 6's condition: the class holds only while the 429 lands between the two engines' answers (S3-R24 item 5).
     - Probe it once, in step 7: a seeded 429 with no Retry-After, from the third attempt, with a second user request on another job of the same origin, in both orders.
     - A caller's answer that differs from visit-first's with the 429 before both engines' answers, or after both, is 1(a): blocking, and P3 applies.
     - Otherwise it is recorded as a residual risk, with the probe and its result.

6. *The four unreached places* (open item 4). Blocking (S3-R16 1(e), S3-R25 item 10).
   - **`EngineFailures.swift:861-862` and `:868-870`** belong to b22, under item 5.
   - **`EngineShutdown.swift:178-183`, `settle`'s slice.** Give T-A3 (`EngineOwedAnswersTests.swift:190`) a `count` argument of [10, 600], and replace its literal 10 with `count`, one to one, at all three places: the setup call's `count: 10`, the setup's `#require` (`owed.left == count - 4 * turns`) and the bytes check (G3: the expectations stay as exact).
     - `@Test` takes at most two argument collections (`Testing.swiftinterface`), and T-A3 already has two (`LaneDropVisit.allCases, [0, 1]`). So `turns` and `count` are passed as one collection of pairs, all four of them; every existing (visit, turns) case still runs at count 10.
     - At count 600 it asserts `shutdownSlices == [512, 88 - 4 × turns]`: [512, 88] at `turns: 0`, and [512, 84] at `turns: 1`.
     - The setup requires that no waiter or job is left to free before the shutdown (d4 review should-fix 4).
     - Every caller gets C's bytes.
     - The drop-mutant of the `if` gives one slice, [600 − 4 × turns], and must fail every count-600 case, 2/2.
   - **`EngineFollow.swift:883`, `replayVerdict`'s second guard.** Both halves are unreachable (d4 §2, confirmed by its review), so:
     - remove `:882-884`, and replace `:876`'s last sentence with d4 review's text ("What the ruling must add" 4);
     - add an epoch clause next to the unfailed one (`EngineCommands.swift:2275`): "jobs whose failure verdict waits for a follow are at another epoch";
     - add one test with `violations(after:)`, from the `sweepFollowsFirst` state of `barrierFailsA429BeyondTheCapsAsOnArrival`. It sets the job `.queued`, then bumps its epoch, and expects each clause in turn. It kills both clauses' drop-mutants 2/2.
     - The epoch clause is an invariant clause, not a replay or deferral branch. Its test runs in `sweepFollowsFirst` only, and S3-R24 item 3's both-orders rule does not apply to it.

7. *The held-turn readers* (put-back). d5 found no racy reader in the seven listed suites or in the rest of the Sync tests. It spot-checked the fixer's own Step-8 list and did not re-derive it; the draft records that limit.
   - Replace the draft's "not audited one by one … Put to the orchestrator" (`s3f.md:6653-6655` and `:9807-9808`) with d5's classification, suite by suite.
   - Add d5's pin at `EngineFollowBarrierWaitingTargetTests.swift:191-193`: `barrier` in `afterTurn`, and a `#require` that the move's turn is not the follow's last. Run it 2/2 in both orders.
   - **If the `#require` fails,** the reading is racy: a 1(d) finding. Hold the attempts' terminals around that one turn only (`holdAttemptTerminals()` before `runOneFollowTurn` at `:190`, released after `afterTurn`), as `takeOffTurns` does (d5, "What could go wrong"), and record it.
   - Do not hold attempt terminals globally.

8. *`releaseRerouteHolds`' inventory row* (put-back). Its row (`s3f.md:4961`) is O(P log P) for P publications. Give it one of these (S3-R26 item 9):
   - **The argument.** Cite from the code a bound on P (the publications that can wait while `reroutesWaiting > 0`) that does not grow with ids or interests. The row is then O(P log P) at that bound, and is recorded with the bound.
   - **A figure.** If no such bound is cited, give a BenchSync figure: the largest P the harness can hold behind owed re-routes at 10,000 ids, best of 3, with loads. A miss is blocking (S3-R25 item 3).

9. *The fixer's own check before it returns.* S3-R26 item 9 applies again, on the final HEAD:
   - S3-R25 item 10, for every line and branch changed in `d5b2ab9..HEAD`. The cycle-21 dispositions in "Not reached and structural lines (cycle 21)" stay listed, updated where this cycle changes them;
   - the inventory: every new per-id, per-pair, per-event or per-row operation of items 1 to 4 is a row with its cost. It also gets a figure, unless it is O(1) amortised and neither this ruling nor `integrate-c21.md` or `integrate-rr21.md` names a case for it. A case that only an analysis names (d1 to d5) needs a figure only if this ruling adopts it;
   - the re-measure of every C2 case the cycle's code passes through;
   - the margin list: every case above 8.5 ms, recorded "at the edge".

10. *Order of work.* Commit each step on its own.
    - **Red first.** S3-R26 item 11's red-first rules apply, with `d5b2ab9` in place of `8e1fb24`.
      - A BenchSync case or pin that misses on `d5b2ab9` is such a test: it is committed failing, on its own, right before its fix, as `b4c215d` was.
      - A case that passes on `d5b2ab9` lands with the step that adds it.
      - A case that misses on `d5b2ab9` but passes on the HEAD where its step starts (for example item 4's cases after steps 1 to 5) lands, green, with that step. Its `d5b2ab9` figure is recorded as its 'before' figure.
    - **A deciding figure without a quiet load.** S3-R26 item 11's rule applies to every figure that decides a route in this ruling: c1 and c6 (item 1), the in-place batch (item 2), A7 and the group walks (item 3), and pair counting (item 4).
      - Decide on the best of 3 at the lowest load you get.
      - Record it as "not measured at a quiet load", with its loads.
      - The orchestrator re-measures it before close-out, and a different result reopens that decision.
    - Keep the draft's cycle-22 status list current, with the named findings' mapping, so that a resumed fixer continues from the HEAD.

    0. Run `verify.sh --quick` on `d5b2ab9`.
       - In a scratch copy of `d5b2ab9`, build every case that items 1 to 4 add, and take its 'before' figure, best of 3, with loads.
       - A case that needs a seam gets it in the scratch copy only. The seam lands later as its own behaviour-free commit (item 3's sub-steps).
       - Item 4's `manyHolders*` cases take no 'before' figure unless pair counting is triggered.
       - Item 1's scratch probe is part of this step.
    1. The verifiers' blocking findings of class S3-R16 1(a) to 1(d) (an answer, a MUST or invariant, liveness, flakiness) that this ruling does not name, each failing test first. A named finding goes with its item.
    2. Item 6's removal and settle slice, and item 5's removal and its cheap kills, in d4 review's amended order, its steps 1 to 5: r7's removal with the mutant texts and r6's re-run; `replayVerdict`'s removal with its clause and test; b23; the settle slice; f7.
    3. Item 1.
    4. Item 2, including A3 and A3′ (`Group.dropMember`) if its jobs' side needs them.
    5. Item 3, in its sub-steps.
    6. Item 4: A1 and A2 if taken, then its deciding figures, then pair counting if they trigger it.
    7. Item 5's remaining kills, in d4 review's amended order, its steps 6 to 12: b22-no-waiter-owner, p7 with r5, r8, vy, r2c, b22-no-run-owner and r2b. Then item 5's default-tuning probe. Then the verifiers' other findings.
    8. Items 7 and 8, item 5's `followedLane` record and item 1's records. Then the close: item 9, and every gate on the final HEAD.
       - Run `verify.sh --full` and quote its last line.
       - A FAIL whose only causes are P-13 (WP-B's; S3-R26 item 10) and the cases this ruling leaves "open, for the owner" is reported as such. Each of its other stages also runs and passes on its own.

    **Expect the weekly limit.** This cycle may be cut off by the weekly usage limit. That is why the C2 routes come before the long survivor work. A cut-off leaves every finished step committed.

11. *Amendments, and the findings the cycle-21 requirements verifier adds.* Where this item and items 1 to 10 differ, this item decides.
    1. **Item 4: a k = 2 or k = 4 miss that pair counting cannot cut.**
       - Such a miss is in a turn that pair counting does not change. Examples: the commit's answers, or a verdict's answers, over 40,000 interests.
       - It is blocking, has no route in this ruling, and is reported with its figures and parts (S3-R26: "A miss with no route is blocking").
       - Pair counting is built only for a miss in a turn that it bounds.
    2. **Item 4: "measured once and recorded"** is a recording rule, not a duty to build shapes.
       - The fixer records the out-of-dimension figures it takes.
       - PROBE-C21-HOLDERS's cycle-21 figures stand.
       - The `manyHolders*` cases are built only if pair counting is triggered.
    3. **Item 2: the jobs' side.** The branch-free route applies only if case (i) or case (ii) misses.
    4. **Item 3: PIN-APM's span.**
       - Drive's continuation in the same turn (`taskEnded`, when `answerSite` returns true) is part of the answer turn.
       - PIN-APM times it together with `unaskedIDs` and `answerSite`. No part of the turn is left out of the timed span.
    5. **Item 3: B1's test** names the hold it uses: the attempt at its answer site with `active.handle == nil`, set through PIN-APM's state seam.
    6. **Ownership** (reqs, "ownership (lens part 2)").
       - These six files are authorised as WP-F's: `Tests/ZTronAssetKitBenchmarks/BenchSyncCycle21.swift`, `BenchSyncJoinChains.swift`, `BenchSyncReroutePins.swift`, `BenchSyncRerouteTakeOff.swift`, `BenchSyncReroutes.swift` and `BenchSyncWaitersBound.swift`. So is any new `Tests/ZTronAssetKitBenchmarks/BenchSync*.swift` file that this cycle adds.
       - Two conditions apply. Each file holds only `ZTronAssetKitBenchmarks.SyncBenchmarks` and `SyncBench` extensions. No file edits another work package's benchmark file.
       - No code is moved.
       - The draft lists the files under "Authorised edits outside WP-F", which corrects `s3f.md:7273-7274`. It also proposes the ARCHITECTURE §1.2 addition (S3-R6).
    7. **`commitTurns(.manyGroups)`** (reqs, "C2 flake at loads of 10 or less"). Blocking (S3-R16 1(f)).
       - The figures: best 10.27 and 10.96 ms in 2 of the verifier's 4 runs at loads of 10 or less, and 9.40 in the other two.
       - A case that flaps around `c2Budget` is a miss, as S3-R26 item 4 ruled for the commit window.
       - The route is branch-free first, in this order:
         - item 1's c3 and c1;
         - item 1's c6, at the top of `publishTerminal`;
         - item 3's group-walk cut, applied to the commit's turn: no `Group` copy in the walks of `materializeEnsures` and `pruneBoundContent`.
       - These land in steps 3 and 5 of item 10. Measure after each, best of 3 with loads. Item 1's decision rule and the C2 block decide.
       - A miss that stays is blocking, and is reported with the per-step figures. Owing the group deliveries across follow-ups needs a new ruling.
    8. **The correctness verifier's findings** reach the fixer through the findings file, and follow the "named finding" rule above.

12. *The owner's ruling, and the cycle-21 correctness verifier's two new findings.* Where this item and items 1 to 11 differ, this item decides.
    - **Its analyses** are in `.build-orchestrator/s3f-c21-analysis/`: `e1-pin-requeue.md`, with its review `e1-pin-requeue-review.md` (12.2), and `e2-purge.md`, with `e2-purge-review.md` (12.3). The header's rules for reading the analyses apply to them. Below, "must add" n is a review's "What the ruling must add" n, and "must say" n is a report's "What the ruling must say" n.
    - **Names.** R1, A1, A2 and P-1 to P-3 already have meanings here: R1 is S3-R11's (S3-R16 1(a)), `integrate-rr21.md`'s and item 3's; item 3 has d2's A1 to A8, item 4 d3's A1 and A2, and `integrate-c21.md` steps A1 to A13; P-1 to P-3 are SPEC's benchmarks, beside P-13. So, in this item and in the draft's records, e1's and e2's labels carry their analysis: e1-R1; the probes e1-PS, e1-P1, e1-P2, e1-P3 and e1-PR; e2-A1 (e2-A1.1 to e2-A1.7), e2-A2 (e2-A2.1 to e2-A2.6) and e2-B. T-E1 to T-E5 and T-A-SCOPE keep their names. Unprefixed R1, An and P-n keep their earlier meanings.
    - **What in e1's and e2's reviews binds,** extending the header's rule: their must-fix items bind, as this item corrects them. Their should-fix items bind only where this item names them. A report's recommendation, and a review's "must add" items, bind only as this item carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.

    1. **The owner's ruling (5 Nov, 21:15).** To "Should the 10 ms bar cover only 10,000 assets with one subscriber?", the owner answered "Yes, keep it" (`docs/ORCHESTRATION.md`).
       - **The bar,** `c2Budget` at 10 ms, covers only the reference set: 10,000 ids however their interests are grouped, with at most 4 interests on one id as item 4 sizes it, and one subscriber, which may be stalled (S3-R26 answer 4).
       - **Outside the bar:**
         - every shape with more than 4 interests on one id. It includes item 4's list: PROBE-C21-HOLDERS and its padded variants, the `manyHolders*` cases, row 14 on one id (item 2), d3 §2(c) rows 1 to 8 with one hot id, and row 12 with k > 4;
         - a second subscriber (`commitTwoStalledSubscribersTurns`).
       - **Such shapes are recorded** with their figures and loads, as residual risks (S3-R16 item 2), where items 1, 2 and 4 say to measure them. They are neither gated nor blocking, and a verifier does not report them as blocking.
       - **What this changes:**
         - every "open, for the owner" in items 1, 2 and 4 now reads "outside the bar, by the owner's ruling of 5 Nov";
         - item 4's condition, that the orchestrator not rule the close-out converged before the owner answers, is met;
         - item 10 step 8's FAIL rule now names P-13 only: a FAIL whose only cause is P-13 (WP-B's; S3-R26 item 10) is reported as such.
       - **Named findings:**
         - correct #5 and reqs #6 (PROBE-C21-HOLDERS): 37.21 to 45.85 ms, best of 3, across the fixer's runs (1-minute loads 6.92 to 8.33), reqs #6's (4.60 to 4.74) and correct #5's (about 6.25). They go to 12.1, recorded and not blocking. Their in-letter part, k ≤ 4, stays with item 4, gated;
         - reqs #12 (two stalled subscribers): 15.57 ms, best of 3, at a 1-minute load of 7.44. It goes to 12.1, recorded.

    2. **Correct #1: the pin after an ENOENT re-queue.** Blocking (S3-R16 1(a)), confirmed by PROBE-C21C-PIN-ENOENT-404 and by e1 §1.
       - **The break** (`.build-orchestrator/s3f-probes-c21/PROBE-C21C-PIN-ENOENT-404.log`, 2/2 per case). rr21-T8b's shape, with X's fresh attempt failing with a 404. Visit-first answers W1…W3 `.failure(.notFound)` and never requests W's content. In three of the four cases (order × owe), W1…W3 get W's 20 bytes and W is requested. V2 gets `.notFound` and K 16 bytes in every case, and no invariant breaks.
       - **The mechanism** (e1 §1). The ENOENT arm (`EngineDispatch.swift:1274-1283`) re-queues X at the same epoch and keeps no record. `waitingTarget(_:epoch:)` returns nil for `.queued` (`EngineFollow.swift:1581-1582`), so the pin check returns nil (`:806-808`), and both callers, `rerouteListing` and `joinListing`, follow the engine's copy. Answer 6.3's premise, that the reference re-routed the pair at that end, is false for an ENOENT re-queue: visit-first's pair rode X's fresh attempt.
       - **Route: e1-R1** (e1 §2), as e1 review "must add" 1 states it. While events wait, the ENOENT arm keeps (X, epoch) with `copySerial`, marked as a re-queue. At the pin, with no layer after that serial, the walk returns the pin layer's outgoing copy. Otherwise it takes the copy that the first layer after the re-queue adopted (index `end.serial - serial + 1`, or the engine's copy), and walks on.
         - e1-R1 reads no job state. It reuses the record's clears (`endWorldHistory`, `EngineFollow.swift:372`; shutdown, `EngineShutdown.swift:130`) and its three clauses (`EngineCommands.swift:2239-2250`).
         - The verifier's fix step 3 (the entry handed to the copy at the re-queue) is rejected as written, and so is a walk-on keyed on X's state (e1 §2; the last row of e1 §4's kill table). The verifier's step 1 becomes T-E1, and its step 4 becomes rr21-T8b's change below.
       - **The record's form: a flag on `reroutePinCommits`' value** (e1 review must-fix 4, "must add" 2). Its duties:
         - `committed`'s write (`EngineDispatch.swift:1133`) records a commit (`keepsEntry: false`);
         - the "ahead" clause (`EngineCommands.swift:2247`) reads the value's serial;
         - `invariantsReportCommitsKeptForOwedReroutes` (`EngineFollowBarrierReroutePinEndTests.swift:263-278`) writes and compares raw `UInt64`s and expects the clauses' "commits kept" messages. It changes one to one, as exact as before, in e1-R1's commit, where the value's type changes, and the draft records the old and new text, the messages included if they are renamed. This item authorises that change, as an exception to S3-R26 item 1's "Answer, MUST and invariant assertions never change" (rulings :462);
         - the `keepsEntry` literal's mutant is killed (the table below).

         A sibling map is allowed only if the flag form cannot hold. It then needs its own clears and its own clauses, each with its kill, and the draft records the reason.
       - **The tests,** in `EngineFollowBarrierRerouteRequeueTests.swift`, from rr21-T8b's fixture, owing, in both orders, unless a row says otherwise (e1 §4; T-E5 is e1 review must-fix 1):

         | Test | Shape | Visit-first's answers | On `d5b2ab9` |
         |---|---|---|---|
         | T-E1 | the probe's, with `arguments: LaneDropVisit.allCases, [false, true]` (order × owe) | W1…W3 and V2 `.notFound`, K 16 bytes; after the replay X holds zz-a1…zz-a3 and zz-x; W never requested; no violation | red in 3 of 4 cases (the verifier's probe) |
         | T-E2 | K1 drops zz-a1…zz-a3 while X publishes; X's ENOENT; K2 lists them at U; X's fresh attempt fails with a 404 | W1…W3 U's bytes, V2 `.notFound` | green (code reading) |
         | T-E3 | K1 as in rr21-T8b; after the re-queue, K2 drops the pair and K3 lists it at U | W1…W3 `.notFound`; U never requested | red (code reading) |
         | T-E4 | T-E3, with K2 also mapping zz-x to Y, so that X is superseded | W1…W3 `.notFound`, V2 Y's bytes | red (code reading) |
         | T-E5 | after the re-queue, K2 lists the pair at U (no job of U at an end) and K3 at Z | W1…W3 Z's outcome | green (code reading) |

         - **Serving** (e1 review must-fix 6, "must add" 4). Every T-E test serves each content a mutant can request (W, U, Z), only if its job exists, and asserts which contents were requested. A mutant then fails on an answer, not on a time limit.
         - Each test is green in both orders on the fix before any kill counts.
       - **rr21-T8b changes one to one** (e1 "must say" 5; e1 §2, step 4). It lands in e1-R1's commit, since its old `:124` is red under e1-R1:
         - `:124` becomes `replayed.x == (ids + [xID]).sorted() && replayed.w.isEmpty`: X holds zz-a1…zz-a3 and zz-x, and W has no job;
         - the loop at `:127` delivers X before W, since W's job now appears only at X's commit;
         - its display and function names (`:25-26`) and its docs (`:8-23`) say that the pin holds. The answers at `:142` stay.

         The draft records old and new. No `MIGRATION.md` entry is needed: it is cycle 21's own test.
       - **The kills** (e1 review "must add" 3; e1 §4, corrected by must-fix 1 to 3). Each is 2/2 in each order that can reach its branch, after a green first run of the unmutated code in both orders. A kill is by an answer or a clause, never by a hang or a time limit (item 5).

         | Branch | Mutant | Killed by |
         |---|---|---|
         | the ENOENT arm's write | dropped | T-E1 |
         | the write's `!eventsAfterFollow.isEmpty` | forced true | `enoentAfterCancelIsTheCancellation` (`EngineRaceTests.swift:82-122`), strengthened with an `invariantViolations()` check after the fresh attempt and recorded, or a new barrier-down ENOENT test. Without a follow the orders are moot, and the draft says so (must-fix 2) |
         | `end.keepsEntry` | dropped (read as a commit) | T-E1 and T-E2 |
         | `next < layers.count` | forced true (always jump) | T-E1 |
         | `next < layers.count` | forced false (always keep) | T-E2 |
         | `index = next + 1` | `index = next` (the verifier's step 3) | T-E2 |
         | `index = next + 1` | `return nil` (`d5b2ab9`'s answer) | T-E3 and T-E4 |
         | the walk on, after the jump | no walk-on: the jump's copy is returned (p5's form) | T-E5 |
         | the record decides, not X's state | a walk-on keyed on X's state | T-E4 |
         | `committed`'s `keepsEntry` literal | read as a re-queue | killed; e1's review expects p4's killers (draft `:6309`) to kill it, unverified. If they do not kill it 2/2 in each order that reaches it, a PIN-END test that does is added |
         | `i5-pin-fold` (re-run) | `.queued` returns the job in `waitingTarget(_:epoch:)` | T-E2, moved from rr21-T8b. The run decides which tests kill it in each order, and the draft records the killing line per order |

       - **The probes** (e1 §3 and §7, step 4; e1-PR is added here). Each asserts visit-first's answers, and runs in every order that can reach it. e1 §3 gives the shapes:
         - **e1-PS:** X's own publication superseded, then a later apply: (i) K2, mapping the pair to U, adopted while J publishes, then J's terminal failure; (ii) K2 drops the pair and K3 re-lists it at U. Owing, both orders. Visit-first: (i) J's integrity failure, (ii) `.notFound`. Route if red: the commit-shaped record (`keepsEntry: false`) at the `.superseded` arm (`EngineDispatch.swift:1261-1268`);
         - **e1-P1 and e1-P2:** a T20 re-queue during an ENOSPC free-space read, from the drain's replay of a user join (e1-P1) and from `followAfterVerdict`'s joins (e1-P2). Both orders. Visit-first: for e1-P1, `insufficientSpace` for the pair and for V2, with X requested once; for e1-P2, X's ENOSPC verdict answers Y's id. Route if red: `relane`'s guard (`EngineJobs.swift:307`);
         - **e1-P3:** a park at the same epoch while the barrier holds: Shape A and rr21-T8b, with a conditions edge or a space sweep replayed between the re-queue and the move or the replay. Both orders. It records X's state at the move and at the replay, with no `#require`, and runs on to the answers. Visit-first: the id rides X. A `.blocked` state with visit-first's answers is recorded as the move's own finding: e1-R1 makes the state moot for the pin, but the move's `.queued` arm still depends on it (e1 §3). If kept as a test, it asserts visit-first's answers;
         - **e1-PR:** the untraced removal edge in e1 §3's table: X dropped by a removal replayed before the batch, with no apply since the re-queue. `sweepFollowsFirst` only. e1-R1 is expected to join a new job of X's content, so that the answers equal visit-first's (UNCONFIRMED).

         A different answer from visit-first's is blocking. A probe is red when it breaks S3-R16 item 1 in an order that reaches it: a different answer, a broken MUST or invariant, or a hang (S3-R26 items 7 and 11). Its other observations, such as a request count or a job's state, are recorded with it.
         - A red probe with a route given here is fixed in cycle 22: its failing test first, then the smallest change that makes the answers equal visit-first's, with its branches killed and the design recorded.
         - A red probe with no route given here (e1-P3, e1-PR) stays out of the suite, as scratch evidence, and is reported as blocking with its probe and its log.
         - A probe that holds is recorded with its result (S3-R26 item 11).
       - **Amendments** (e1 review "must add" 5). Visit-first re-routes only at a commit or a supersede, so an ENOENT re-queue keeps the pin:
         - S3-R26 answer 6.3: its header's class is now a pin whose job committed or was superseded, and the ENOENT re-queue and rr21-T8b leave it. Its first and second bullets hold for those two ends, and the first's "rr21-T8 and rr21-T8b pin it" reads "rr21-T8 pins it" (the commit pin, `integrate-rr21.md:403-406`). After an ENOENT re-queue the reference re-routed nothing at that end (D-13). With no apply since, the pair rides X's fresh attempt (T-E1, rr21-T8b). With one or more, the first visit after the re-queue moved it under the copy that visit's apply adopted, and later visits moved it on (T-E2 to T-E5);
         - S3-R26 item 1's "A pin holds only while `waitingTarget(transfer, epoch:)` holds" (rulings :441) now reads: a pin holds while `waitingTarget(transfer, epoch:)` holds, and, after an ENOENT re-queue at that epoch, until the first copy adopted after the re-queue;
         - `integrate-rr21.md`'s D6 (`:316-318`) and its residual (`:597`) lose the ENOENT re-queue, and its must_not on the `waitingTarget` window (`:586`) is lifted for this fix. D6's first sentence reads as S3-R26 item 1's, amended above. Its last sentence, "No new job of a former target is created from an old copy", holds for the commit and supersede ends only (e1 §2);
         - S3-R26 answer 8: the pin caller's kill of the fold mutant is T-E2's, with the other tests the run shows killing `i5-pin-fold` in each order. Every other rr21-T8b in answer 8, the "Reached" evidence of its second and third bullets included, reads "T-E2, with those tests".

         "There is no layer per commit" stands: a kept serial is no layer. The nested ENOENT, a commit's next target re-queued by its own ENOENT, is in the class, and e1-R1's branch covers it (e1 review "must add" 7).
       - **C2** (e1 "must say" 11). No new inventory row: `followLayers` stays O(layers) an id, and the ENOENT arm gains O(1). Item 9 re-measures `applyWhileOwedLayers`, `lane429WhileOwed` and `joinChainTurns`. e1-R1's added cost is estimated at 0.2 ms or less a drain turn.
       - **Records** (e1 "must say" 10):
         - the doc comments at `EngineFollow.swift:765-773` and `:1561`, whose "An owed re-route's pin keeps the end's own window" is now false; at `EngineState.swift:217-221`; and on the ENOENT arm (`EngineDispatch.swift:1275-1278`);
         - the draft at `s3f.md:5695-5700` (rr21-T8b); `:5821-5824` (the residual, and the wrong "The records go when the last batch is replayed whole": they go at `endWorldHistory` and at shutdown); `:6563-6566` and `:6601-6607` (the fold's kill, and the first UNCONFIRMED sibling, now confirmed and fixed); and `:6814-6816` (RR-21's ruling-3 residual).
       - **Fixer hours,** estimated (e1 review "must add" 8): about 6-10 h of writing and 3.7-5.5 h of mutant runs for the fix, its tests, kills and records, plus 3-5 h for the probes. A sibling's fix is not included.

    3. **Correct #2, with reqs #4: the purge's first turn.** Blocking (S3-R16 1(f)). `withdrawPurged` walks every waiting event and every job in one turn, the synchronous stretch after `ensureStarted()` (`EngineCommands.swift:968-976`). The figures are in the cases' table below (correct #2's probes in `.build-orchestrator/s3f-probes-c21/`; e2 §0, confirmed by e2's review).
       - **What it replaces:** item 2's paragraphs "The jobs' side has no figure" and "The jobs' side's route is branch-free", and item 11.3. Item 2's part (1) stands, as e2-A1.1. Its part (2) is no longer conditional: it lands in e2-A1.2.
       - **The contract** (e2 §1; e2 "must say" 2), recorded in the draft. Withdrawing every non-user interest in the purge's first turn is not a MUST (`SPEC.md:250`; `docs/ARCHITECTURE.md:300` binds only the engine's epoch). Withdrawing every waiting join, bucket join and owed item before any drain turn is binding (RR-5, PROBE-C13-PURGE-JOIN).
       - **The gated cases** (e2 review "must add" 3): eleven BenchSync cases at 10,000 ids, in 11.6's files. Each purges `.all` unless its row says otherwise.

         | Case | Today, best of 3 |
         |---|---|
         | (i) one prefetch group of 10,000 members, each id with its own content and job | 54.47 ms at a 1-minute load of 7.65, and 55.96 at 4.85 (PURGE-QUEUED) |
         | (ii) 10,000 one-member prefetch groups, each id with its own content and job | not measured |
         | (i) under a `.scope` purge | not measured |
         | the shared job at k = 1: one job of 10,000 ids | 12.20 ms at 7.65, and 12.03 at 4.85 |
         | the shared job at k = 4: four groups over its ids | estimated 43-48 ms (e2 review must-fix 10) |
         | the bucket joins: PURGE-JOINS' shape at 10,000 members | 13.04 ms with 9,216 joins behind the verdict, at 7.36 to 7.23 |
         | the queue joins: the same shape | 11.52 ms with 9,489 joins in the queue, at 7.23 to 6.88 |
         | `purgeWhileOwedTurns` (reqs #4; it exists), 10,000 owed items | 10.04 ms in the fixer's second gate run, at a 1-minute load of 4.88 (mean 5.23 over SyncBenchmarks; a miss); 9.57 to 9.83 in the verifiers' runs, at 3.39 to 7.14 |
         | k = 4 over 10,000 jobs: four prefetch groups | estimated 85-130 ms (e2 §2.4) |
         | 10,000 jobs waiting for a retry, each one that the purge removes (held only by interests it withdraws) | estimated 0.1-0.5 s: `removeJob` scans the heap once per job (`EngineJobs.swift:483`; e2 review must-fix 10) |
         | 10,000 jobs held only by user waiters | estimated 8-14 ms (e2 review must-fix 10) |

         For each case:
         - its figure is its heartbeat, best of 3, with loads, as "How a C2 figure is read" says, and the purge's synchronous turn is recorded beside it;
         - its 'before' figure is taken in step 0, in the scratch copy;
         - if it misses on `d5b2ab9`, it is committed red right before e2-A1's first part, under item 10's red-first rules.

         `purgeWhileOwedTurns` is already in the tree, so it is not committed again. Its cycle-21 figures (the table) and its step-0 figure are its 'before' figures. Its cycle-21 miss stands, and the decision rule below judges it after e2-A1 and after e2-A2.

         The purge over one id held by 10,000 groups (row 14) is outside the bar (12.1), and is recorded only.
       - **e2-A1 (e2 §3's A1.1 to A1.7), with e2 review's corrections.** Each part is its own commit.
         - e2-A1.1 (item 2's part (1)): `isPurged` reads the request before the copy lookup, in the walk, the joins and the owed arm (`EngineCommands.swift:993-1005`).
         - e2-A1.2: the owed batch (item 2's part (2)), the queue's `.join` events and each bucket are changed in place, with no copy of their items. A bucket takes one `joinsBehindVerdicts[key]` access, still newest first.
         - e2-A1.3: no sort of the dropped ids or of the removed items (`:1022`, `:1070`).
         - e2-A1.4: one jobs access per job, through a `Job` mutating method, then one `settleRemoval`. The method removes in ascending token order and returns the lanes before the first and before the last removal, as `takeOff` does (e2 review must-fix 6). Its test: a claim-held job whose `.bulk` interest is registered before its `.prefetch` interest (t1 < t2, as e2 review must-fix 6 builds it) ends with `heldLane == .prefetch`. The reversed-order mutant fails it 2/2 (e2 review "must add" 2).
         - e2-A1.5: the `.all` fast path, below.
         - e2-A1.6: A3 and A3′ (`Group.dropMember`) at `:1025`, `:1073` and `:1108`, with d2 review M1's pending check and item 3's C7 citations. Item 3's sub-step 4 then reuses them.
         - e2-A1.7: no `Job` copy in `settleRemoval` (`EngineJobs.swift:395`) or in `retire` (`:412`).
       - **Exclusivity** (e2 review must-fix 8, "must add" 1). Every step that works inside one access takes `applied` and the request into locals, marks and collects inside the access, and makes the other writes after it, in the same order, as item 1's exclusivity rule says. Every in-place access is such a step: e2-A1.2's owed batch, `.join` events and buckets, e2-A1.4's method and e2-A2.4's walk among them.
       - **The reversals** (e2 review "must add" 6). e2-A1.3 reverses `integrate-rr21.md` R15 (the owed arm's sort, `:239`) and S3-R26 answer 7's "the purge arm that removes items and sorts the removed subset".
       - **The order.** The draft records e2-A1's order arguments, corrected: the order across jobs (the sorted keys) and within a job (ascending tokens) is kept. Two things change: the order of the dropped ids and of the removed items, and, with e2-A1.4's one `settleRemoval` per job, the number of `notifyObservers` calls inside the turn (`EngineJobs.swift:406`; e2 §3, "Equality with today"). The purge never withdraws an `.ensure` interest, so no drop resumes anything (e2-A1.3; e2 review, "What holds").
       - **e2-A1's one branch, the `.all` fast path (e2-A1.5):** `withdrawn = interest.assets`, with no filter and no intersection. This item authorises it, amending item 2's and item 11.3's "branch-free" (e2 review must-fix 7).
         - Always taken: killed by T-A-SCOPE, 2/2 in each order that reaches it. T-A-SCOPE purges a `.scope` of one of two ids that share a content held by a prefetch group. The other member stays pending and keeps its interest (e2 §3).
         - Never taken: Equivalent, cost only (S3-R19 item 2).
       - **e2-A1's other kills** are e2 §3's table:
         - `isPurged`'s early read: drop-mutant Equivalent (item 2's part (1));
         - the method's whole arm: `purgeDropsGroupMembers` (`EngineRegressionRound2Tests.swift:282`); its partial arm: T-A-SCOPE;
         - the moved lane and kind conditions, b23's among them: re-run at their new lines (item 3's rule);
         - `Group.dropMember`'s nil line: item 3's M1.
       - **e2-A2 (e2 §3's A2.1 to A2.6),** authorised only if a purge case is above 8.5 ms after e2-A1. Each part is its own commit. With e2 review's corrections ("must add" 4):
         - e2-A2.1: `removeJob` touches an index only when it is not empty;
         - e2-A2.2: `storedCount` becomes a counter in `LaneQueues`, with a recount clause, and the queues are compacted once, after the walk;
         - e2-A2.3: the retired jobs are freed later. Either the freeing slice is pinned, with recorded slices and a drop-mutant that fails 2/2, as item 6 pins `settle`'s, or the freeing runs unsliced in one later turn, with its figure and a REENTRANCY row;
         - e2-A2.4, the table-order walk, comes only after the purge suites' order audit (item 3's A7 rule), in two passes, with the iOS SDK's `Swift.swiftinterface` cited (C7). Otherwise the key sort stays;
         - e2-A2.5: one heap pass for the retired jobs' `.retry` entries (`DeadlineHeap.swift:79-81`);
         - e2-A2.6 is dropped unless A5's audit (item 3) is done first.
       - **e2-A2's kills** are e2 §3's table, with e2 review's corrections:
         - the empty-index guards: drop-mutants Equivalent (S3-R19 item 2); each negation killed by its index's clause, which the fixer lists per index, adding one where an index has none;
         - the queue counter: each update's drop-mutant fails the recount clause;
         - e2-A2.3's freeing slice is not Equivalent (e2 review must-fix 9): it is pinned as above;
         - the heap pass: the retry case asserts that no `.retry` entry is left.
       - **The decision rule** is item 1's: at or below 8.5 ms closes a case; 8.5 to 10 ms is recorded "at the edge" and is not blocking; a miss is blocking. Measure every purge case after e2-A1, and after e2-A2. A miss after e2-A2, or after e2-A1 when e2-A2 is not triggered, is blocking with no route in cycle 22. Report it with its parts' figures and loads.
       - **Route e2-B, slices over owned follow-up turns (e2 §4), is not authorised in cycle 22** (e2 review "must add" 5). The fixer does not build it. The orchestrator will have e2-B re-specified with e2 review's corrections, and reviewed, for a later ruling:
         - visit on touch, claims included, with its cost counted in the touching turn;
         - member drops in the slices;
         - a bound on both the jobs and the pairs visited, with a job split by interest;
         - a mark per walk, and no "unmarked" clause;
         - shutdown and cancel behaviour stated against today's.

         e2 review must-fix 1 to 5, 11 and 12 are about e2-B. They are recorded for that re-specification, and bind the cycle-22 fixer only where 12.3 carries them.
       - **`isPurged` keeps its entry copy** (`ValidatedManifest.swift:78-83`). There is no edit to `ZTronAssetModel`, which is not WP-F's (P1). If a `.scope` figure shows that the copy decides a miss, report it with the figure.
       - **Records.** Propose (S3-R6) RE-S24's corrected text (`docs/ARCHITECTURE.md:456`; e2 §1.1): it puts the purged ids' job removals after the store's await, and the code makes them before it, in the purge's first turn. Every estimate stays labelled as one (G2).
       - **Fixer hours,** estimated (e2 §6): e2-A1 5-8 h, and e2-A2 6-10 h, with the cases and red commits included.

    4. **The order of work** (item 10), amended:
       - **Step 0** also runs T-E1, T-E3, T-E4 and T-E5 on `d5b2ab9`, recording each red or green, and takes the 'before' figures of 12.3's cases.
       - **Step 1** also takes these parts of 12.2, all of them before item 6's `EngineFollow.swift` removal in step 2 (e1-R1's kills are in step 7; 12.2's records, and item 9's re-measures, are in step 8):
         - every T-E test that is red on `d5b2ab9`, committed failing in one commit (item 10's red-first rules);
         - then e1-R1, with rr21-T8b's change, the PIN-END invariants test's change, and each T-E test not committed red in the previous commit;
         - then the probes e1-PS, e1-P1, e1-P2, e1-P3 and e1-PR. A red one with a route gets its failing commit, then its fix by 12.2's routes; one with none follows 12.2.

         e1-R1 moves `EngineFollow.swift`'s lines below `:820`, so item 6 finds `replayVerdict`'s lines by content (e1 §5). Any other citation of this ruling that a change in this item moves is found by its content too: for example, a fix at `relane`'s guard (`EngineJobs.swift:307`) moves item 1's c6 site and 12.3's `EngineJobs.swift` lines.
       - **Step 4** takes 12.3 with item 2:
         - the cases not yet in the tree, committed red where they miss;
         - e2-A1's parts, one commit each, then the figures of every purge case;
         - e2-A2's parts if triggered, one commit each, then the figures again.
       - **Step 7** adds e1-R1's kills and e2-A1's and e2-A2's kills, beside item 5's.
       - **Step 8** adds the records of 12.2 and 12.3. Item 9's check covers 12.2's and 12.3's lines.
       - **The named findings.** The draft's status list keeps this mapping:
         - correct #1 → 12.2;
         - correct #2 and reqs #4 → 12.3 with item 2;
         - correct #3 and reqs #2 → item 1;
         - correct #4 and reqs #5 → item 3;
         - correct #5, reqs #6 and reqs #12 → 12.1;
         - correct #6, reqs #7 and reqs #8 → items 5 and 6;
         - reqs #1 → 11.6, and reqs #3 → 11.7.
       - **Expect the weekly limit.** Item 10's paragraph stands. With item 12, cycle 22's fixer work is estimated at about 55-90 h, so a cut-off inside the cycle is likely. Commit every finished step when it is done.
    5. **Settled points.** The writer, the two checkers and the editor of this item left these for the orchestrator. Where this sub-item and 12.1 to 12.4 differ, this sub-item decides.
       1. **A probe is blocking only when it breaks S3-R16 item 1:** an answer different from visit-first's, or a broken MUST or invariant. e1-P3 records X's state and asserts visit-first's answers. A `.blocked` state with visit-first's answers is recorded, and is not blocking.
       2. **A probe that cannot be built.** If e1-PR's shape, the removal edge in `sweepFollowsFirst` only, cannot be built after a real attempt, follow S3-R26 item 7's B-T5 rule. Record the attempt, why the shape cannot be built, and the residual risk beside e1's UNCONFIRMED claim. It is not blocking.
       3. **T-E2 joins step 0** with T-E1, T-E3, T-E4 and T-E5. Its result on `d5b2ab9` is measured, not read from the code.
       4. **The kills of a red probe's fix** land at step 7, beside e1-R1's. Those are the branches of the commit-shaped record at the `.superseded` arm and of `relane`'s guard (`EngineJobs.swift:307`).
       5. **e1-R1's ENOENT write** goes inside `if self.transition(transfer, to: .queued)` (`EngineDispatch.swift:1280`), so that a record exists only when the re-queue happened.
       6. **The cycle-21 mutants whose anchors or filters e1-R1 changes** are rewritten for e1-R1's code and re-run at step 7, as item 5 does for r6 and r8:
          - `mut-c4fix.py`'s p1, p2, p2b, p3, p4, p5 and p10;
          - the LAYER filters of `mut-c4fix`, `mut-c3`, `mut-c3fix` and `mut-pinend`;
          - `mut-i5`'s T8B.

          Their filters include the T-E tests and rr21-T8b's new name. Rewrite them in cycle 22's own copies under `.build-s3f/c22/tools/`, and leave `.build-s3f/c21/` unchanged. The draft records each old and new text and its result.
       7. **The regression controls** of e1 review should-fix 9 bind. They are rr21-T8b as changed, the PIN-END suite, `FBJoinGapFailure`, Shape A, probe (ii) and the D-13 test, each run green in both orders on e1-R1's commit.
       8. **Two more amendments** under 12.2, for the ENOENT re-queue end:
          - answer 6.3's header predicate, "follows the copy at the replay" (rulings :680);
          - `integrate-rr21.md`'s B17 entry, "T8/T8b (pin left)" (`:971-972`).

          For that end, the pin holds (e1-R1). Neither file is edited: this item decides.
       9. **12.2's records** add `s3f.md:5072` (reqs #10's record; fidelity should-fix 3). For `s3f.md:5823-5824`, add a cross-reference to `:5857-5862`, not a rewrite (e1 review should-fix 6).
       10. **The `.scope` case** selects every id of case (i), so that every id goes through `isPurged`'s filter path. A narrow scope is not a case.
       11. **The user-waiter case** has two variants, both gated: 10,000 jobs held only by user waiters, and 10,000 jobs held only by ensures (e2 review must-fix 10). They can be one BenchSync case with a parameter.
       12. **Red purge cases across the part commits.** The 12.3 cases that miss on `d5b2ab9` go in one red commit, right before e2-A1.1 (reqs #13's reading).
           - Only the Benchmarks stage may stay red through e2-A1's and e2-A2's part commits, and only for those cases, because those parts are their fix in steps. This amends S3-R26 item 11's "Only that commit may be red" for these cases only.
           - Each part commit's message names the cases still red, and every other stage is green at every commit.
           - A case still red after the last authorised part is a miss, under 12.3's decision rule.
       13. **Measuring between parts.** After each e2-A1 and e2-A2 part, re-measure `purgeWhileOwedTurns` and PROBE-C21-PURGE-PARTS, as item 2 says. After the last e2-A1 part, and after the last e2-A2 part, measure every 12.3 case, as 12.3's decision rule says.
       14. **The deciding-figure list** in item 10 now names e2-A2's 8.5 ms trigger (12.3) in place of item 2's in-place batch.
       15. **An audit before e2-A1.4.** e2-A1.4's single `settleRemoval` per job cuts the mid-turn `notifyObservers` calls (`EngineJobs.swift:406`; e2 review should-fix 5).
           - Before e2-A1.4, audit the purge suites' `waitUntil` and `awaitCondition` predicates for states that exist only mid-turn, as item 3's A5 audit does for the answer-site suites. Record the audit.
           - Where a predicate depends on such a state, keep a `notifyObservers` call there, and record it.
           - The same audit gates e2-A2.6.
       16. **The `.scope` copy and S3-R8.** A `.scope` miss counts as other-wp:a under S3-R8, and is not WP-F's blocking miss, only when two things are measured after e2-A1 and e2-A2:
           - the turn without `isPurged`'s entry copy is within `c2Budget`, for example in a scratch probe that reads the policy and tags in place;
           - the copy is the only remaining part above it.

           Otherwise the miss is WP-F's, and it is blocking. No file of ZTronAssetModel is edited (P1).
       17. **Item 9's inventory** gains rows, each with its figure, for any of these that land:
           - e2-A2.2's counter and the compaction;
           - e2-A2.3's freeing turn, or its later unsliced turn;
           - e2-A2.5's heap pass.
       18. **Two more records:**
           - 12.1's: the doc at `BenchSyncCycle21.swift:156-158` now says "outside the bar, by the owner's ruling of 5 Nov; recorded", at step 8;
           - 12.3's: the doc at `EngineCommands.swift:1053` ("in (id, token) order, as withdrawPurged drops them"), corrected where e2-A1.3 makes it false.
       19. **Row 14** (the purge over one id held by 10,000 groups) is outside the bar (12.1). It is not measured in cycle 22; its d3 estimate stays recorded.
       20. **e1-PR's cost** is not in e1 review's 3–5 h probe estimate. Add about 1 h (estimate).
