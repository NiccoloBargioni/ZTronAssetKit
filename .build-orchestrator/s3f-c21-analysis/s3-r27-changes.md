# S3-R27 draft: changes from the two reviews

- Before: `s3-r27-draft-v1.md` (the draft as reviewed, copied unchanged).
- After: `s3-r27-draft.md`.
- Reviews: `s3-r27-review-consistency.md` (C, MF-1 to MF-16, SF-1 to SF-10) and `s3-r27-review-fidelity.md` (F, M1 to M9, S1 to S13).
- Counts: 25 must-fix, 24 applied, 1 not applied as written (C MF-15, replaced by fixed decision 3). Of 23 should-fix, 19 applied in full, 3 in part, 1 skipped.

## Must-fix

| Review, id | Where | What changed, or why not |
|---|---|---|
| C MF-1 | New block "How a C2 figure is read in cycle 22", before item 1 | Which figure (the case's assertion: heartbeat, or in-actor time for a pin), which load (before and after, both ≤ 10), which run (any run on the HEAD judged; a pass does not cancel a miss), loads above 10 (S3-R23), and 8.5 ms read the same way but never a gate. Per fixed decision 1, it states `c2Budget` is 10 ms, and adds "No work is hidden from a measurement" |
| C MF-2 | Item 10, "A deciding figure without a quiet load" | S3-R26 item 11's rule extended to c1, c6, the in-place batch, A7, the group walks and pair counting |
| C MF-3 | "How to read them", "What in a review binds" | Must-fix items bind as corrected; should-fix items bind only where named. Lists: d1 2, 3, 4, 5, 7, 8, 9 (and 6 where c6 is taken); d2 2, 3, 4, 5, 7, 8; d4 1 to 5. d1 6 and d2 5 were added to the review's lists because the merged text now names them (C SF-1/F M1; F S6). Added that "What the ruling must add" and report recommendations bind only as the ruling carries them |
| C MF-4 | Precedence paragraph; "Where to find things" | Precedence now covers S3-R16 to S3-R26 ("an earlier ruling"), as fixed decision 4 says. "Named" defined by case, mutant or `path:line`, with the mapping kept in the status list and the named finding closed by its item's route |
| C MF-5 | Item 10, "Red first"; item 9, first bullet | Red-first base is `d5b2ab9`; a BenchSync case or pin that misses on `d5b2ab9` is committed red on its own before its fix (`b4c215d`), one that passes lands with its step; covdiff base is `d5b2ab9..HEAD`, cycle-21 dispositions kept |
| C MF-6 | Item 1, "Tests and kills" table | Merged with F M2 and F S2: per-branch kills, a2 and c3-dropped Equivalent, c3 forced-true by T-ORDER in `sweepFollowsFirst` with answer 1's citation, c1's T-C1-1 and T-PG4, c1's BenchSync row or a recorded reason |
| C MF-7 | Item 1, "Figures", "Two new cases", "Decision rule", c6 | Figures on `d5b2ab9`, after the step and after c1, for `.waiters`, `.waitersStalledSubscriber`, `.groupStalledSubscriber`, `.manyGroups` and the two-subscriber case; "per-step figures" defined; the gate is the heartbeat; the decision rule names its figure; c6 triggered by `manyGroups` above 8.5 ms |
| C MF-8 | Item 2 | Two parts in order, each its own commit, with re-measures; the in-place batch triggered by `purgeWhileOwedTurns` above 8.5 ms; a decision rule as item 1's; the jobs' side's shape fixed at 10,000 distinct ids, the one-id shape sent to item 4; A3 and A3′ land in item 2 when needed, item 3 reuses them. Merged with F S9 |
| C MF-9 | Item 3 | "One step (item 10, step 5)" with d2 review's sub-steps; factoring first, pins red; B1's test merged with F M5 (i) (held attempt, `lastTaskKey` +1, drop-mutant 2/2); PIN-APM-SPARE merged with F M5 (ii); R1 part of the route at sub-step 11, run-row shape gated from there; the integrity row gets a BenchSync figure, a miss blocking |
| C MF-10 | Item 4 | Applied as fixed decision 2 states it: the reference set stays 10,000 ids, the per-id dimension sized at up to 4 interests on one id; more than 4 on one id, however many ids, is "open, for the owner"; k = 2 and k = 4 are committed, gated cases that decide pair counting; PROBE-C21-HOLDERS and `manyHolders*` recorded only; not option (c); both residual conditions replaced above k = 4 and kept as gates at k ≤ 4. "Puts the shape to the owner" became "the owner has been asked" (decision 2). The residual-5 attribution follows F M3, not the review's replacement text |
| C MF-11 | Item 5 | (1) r6's and r8's mutant texts given, r7 retired, r8 killed in step 7 (merged with F M8). (2) f7's fallback trigger: the commit's path differs from T-R1's, with the line and output; a non-separating shape leaves the mutant open. (3) The default-tuning class merged with F M9: ruled S3-R16 item 2 under answer 6's condition, with this review's one probe in both orders deciding 1(a) |
| C MF-12 | Item 6, settle slice | Merged with F M7: a `count` argument [10, 600], the literal replaced one to one; `[512, 88 − 4 × turns]`; no waiter or job left before shutdown; drop-mutant `[600 − 4 × turns]` fails every count-600 case 2/2 |
| C MF-13 | Item 8 | O(P log P) stated; the argument route needs a cited bound on P that does not grow with ids or interests; otherwise a BenchSync figure at the largest P; a miss is blocking |
| C MF-14 | Item 10, steps 0, 1, 2, 4, 6, 7, 8 | Step 0 builds the cases in a scratch copy, with seams there only; `manyHolders*` take no 'before' figure unless triggered; step 1 includes 1(d); step 2 follows d4 review's amended order (merged with F S1); step 4 carries A3 and A3′; step 6 places A1 and A2 first; step 8 places item 5's `followedLane` record and item 1's records. The default-tuning probe is placed in step 7 |
| C MF-15 | Item 1, "The two-subscriber figure" | **Not applied as written.** Fixed decision 3 holds: a second stalled subscriber stays "open, for the owner". The ambiguity is removed the other way: it stays open "whatever it measures", is re-measured and recorded, is neither accepted nor blocking, and a pass does not close it |
| C MF-16 | Item 9, inventory bullet | "Specification" replaced by this ruling, `integrate-c21.md` or `integrate-rr21.md`; a case only an analysis names needs a figure only if this ruling adopts it |
| F M1 | Item 1, "Optional margin: c6" | c6 moved to the top of `publishTerminal`, after the `lane` guard and the `keys` sort, before the filter. Merged with C SF-1 and C MF-7's trigger |
| F M2 | Item 1, "Tests and kills" | Merged into C MF-6's table |
| F M3 | Item 4, "Scope", the replaced conditions | The condition is the cycle-21 fixer's record under S3-R26 item 10 (`s3f.md:5645-5646`), not `integrate-c21.md`'s text (its residual, line 305, has no condition). Checked against both files |
| F M4 | Item 1, "A scratch probe first" | Citation corrected to d1 §4 item 3, "Measure first", controls in d1 review should-fix 7. Merged with C SF-2 |
| F M5 | Item 3, "B1's task", "PIN-APM-SPARE" | (i) Merged with C MF-9: five waiters, `.success` with the store's location, invariants empty, drop-mutant of the read loop's call 2/2, REENTRANCY tags; "one task" made observable through `state.lastTaskKey` (C MF-9's route; tests read state through `readForTests`). (ii) PIN-APM-SPARE asserts the job removed and every interest answered, at the 404 end |
| F M6 | Item 3, "M1, the zero-count guards", third bullet | "The read is collected unconditionally", with `readPresentLocation`'s guard at `EnginePresence.swift:151` |
| F M7 | Item 6, settle slice | Merged into C MF-12 |
| F M8 | Item 5, "Remove" | Merged into C MF-11 (1): `mut-c4fix.py:42-44`, the three texts, r7's entry retired, r6 re-run in its LANE list |
| F M9 | Item 5, "The default-tuning case" | Merged with C MF-11 (3). The two reviews conflict: F rules S3-R16 item 2 with no probe; C probes once and classes by the result. The merged text takes F's class and condition (S3-R26 answer 6, S3-R24 item 5) and C's single probe, since d4 marks the case UNCONFIRMED (§5 item 6) |

## Should-fix

| Review, id | Status | Where, or why skipped |
|---|---|---|
| C SF-1 | Applied | Item 1, c6 (with F M1) |
| C SF-2 | Applied | Item 1, probe citation (with F M4) |
| C SF-3 | Applied | Item 3: "Audit first", "Shutdown with the batched read", B2's `owing` default (bound by C MF-3) |
| C SF-4 | Applied | Item 6: the epoch clause's test runs in `sweepFollowsFirst` only |
| C SF-5 | Applied | Item 7: a failed `#require` is 1(d), with d5's local hold (merged with F S13) |
| C SF-6 | Applied | Item 4: site 2's verdict turn added to the in-letter figures (merged with F S10). Required by fixed decision 2 (k = 4 at 10,000 ids is in the set) and decision 1 (no work hidden from a measurement) |
| C SF-7 | Applied | Item 10, step 8: `verify.sh --full`, its last line quoted, P-13 and the owner's open cases named |
| C SF-8 | Applied | Item 5, "Every kill": first run green in both orders (with F S12) |
| C SF-9 | Applied | Item 3, "Mutants": killed 2/2 at the new line, or a disposition under S3-R25 item 10 |
| C SF-10 | Applied | Item 3, group walks: "and A7 where A7 applies" |
| F S1 | Applied | Item 10, steps 2 and 7: d4 review's amended order, its steps 1 to 5 and 6 to 12 (with C MF-14) |
| F S2 | Applied | Item 1, c1's tests and BenchSync row (with C MF-6) |
| F S3 | Skipped | Measuring after a3 and again after c3 splits the route drafted "in one step" (fixed decision 7) and adds figures only. C MF-7's widened set of cases is applied |
| F S4 | Applied | Item 1, "Exclusivity": relaxed to d1 review should-fix 2 (`generation` captured first, `announced` array, lazy `map` allowed, no lazy `filter`). The draft's stricter rule had no reason and added a per-commit cost |
| F S5 | Applied | Item 1, "Two new cases": gated, not only recorded, said explicitly |
| F S6 | In part | Applied: the spawn argument's premise; the audit; B2's `owing` default; shutdown residual; C7's iOS SDK citation; both callers' tails in the inventory; the pin's scope (d2 review should-fix 5, now named as binding); the integrity row's corrected work list. Skipped: "`scheduleAnswerFollowUp` may become internal" (an optional permission) and the `lastEmitted` probe (d2 review §4 item 4, "worth one probe; not blocking": optional work) |
| F S7 | Applied | Item 3, PIN-APM: the 10,000 groups stay registered through the timed tail (fixed decision 1) |
| F S8 | Applied | Item 3: "Pre-ruled classes"; R1's difference added to S3-R16 item 2's list for this site only |
| F S9 | Applied | Item 2: the estimate's scope corrected; the early return's drop-mutant Equivalent, b23's tests still valid (with C MF-8) |
| F S10 | In part | Applied: the reason for departing from d3's "implement (b) whatever the owner rules"; site 2 (with C SF-6); the doc comments, S3-R22 item 1 and S3-R25 item 1 read as pairs, the rr21 residual closed, PAIRS-T5 (i)'s report counts. Skipped: A3 as margin (optional work; its saving is measured on the one-hot-id shape, which is outside cycle 22's dimension) |
| F S11 | In part | Applied: route (c) is not authorised (removes ambiguity). Skipped: the A6b variant as margin (optional work) and the B1 re-bind probe (optional work; d2 §2.2 classes the read's moment as S3-R16 item 2, and d2's review did not ask for it) |
| F S12 | Applied | Item 5: the comment text by reference to d4 review "must add" 4; the first-run rule; r2b's argue route. Item 6: `:876`'s text by reference to the same |
| F S13 | Applied | Item 7: d5's limit stated; the local hold as the fallback (with C SF-5) |

## The re-read for consistency

- **Cross-references checked:** item 1's probe → step 0; item 3 → step 5 and d2 review §4 item 3's sub-steps 1, 4, 7, 9, 10 and 11; item 2 ↔ item 3 on A3 and A3′ (step 4 before step 5); item 4's 'before' figures (step 0), deciding figures (step 6, after step 5) and margin (start of step 6); item 5's r8 kill and default-tuning probe → step 7; item 5's record and item 1's records → step 8; step 2 and step 7 against d4 review's amended order 1–12; item 2's one-id purge → item 4; "How a C2 figure is read" → items 1 to 4, 8 and 9.
- **Order of work:** every item and sub-route now has a step. No step needs code from a later step: item 2's possible need for A3 and A3′ is met inside step 4.
- **Precedence:** one sentence, covering S3-R16 to S3-R26, specifications and analyses; the "What in a review binds" rule sits under it, and "named" findings are defined.
- **Fixed decisions:** C2 is 10 ms and 8.5 ms is never a gate (C2 block, items 1 to 3, item 9); the per-id dimension at k ≤ 4 with k = 2 and k = 4 gated (item 4); the second subscriber open (item 1); route (b) not authorised (item 1); no signature changes are added (A2's new parameter is internal, as d3 states).

## Checker

An independent check of the edit (not the editor). Read only, except this section and the fixes below in `s3-r27-draft.md`. Nothing was built, run or measured. Code was read with `git show d5b2ab9:<path>` in `.worktrees/s3f`.

### Must-fix: carried?

All 25 checked against both reviews and their sources (d1 to d4 reviews, `s3-rulings-s3f.md`, `s3f.md`, `integrate-c21.md`, `integrate-rr21.md`, `mut-c4fix.py`, and the code).
- C MF-1 to MF-14 and MF-16: carried. C MF-15: replaced by fixed decision 3, as logged ("whatever it measures").
- F M1 to M9: carried. F M9's conflict with C MF-11(3) is merged as logged; neither text relaxes the bar.
- Citations re-checked and holding: `EngineJobs.swift:796-799` (c6's site); `EngineCommitWindowTests.swift:18-79` (T-ORDER); `mut-c4fix.py:42-44` (all three originals match `!atEnd`; r6's and r8's new texts are right); `EngineFailures.swift:73`, `:77`, `:80`, `:145`, `:153`, `:193`, `:494`, `:535`, `:541-552`, `:829-840`; `EnginePresence.swift:151`, `:277-292`; `EngineFollow.swift:876`, `:882-884`; `EngineCommands.swift:2275`; `EngineShutdown.swift:178-183`; `EngineOwedAnswersTests.swift:190`; `EngineMoves.swift:228-235`, `:282-294`; `s3f.md:4961`, `:5645-5646`; `integrate-c21.md:305`, `:447`; `integrate-rr21.md:622-624`; d4 review's amended order 1-12 against steps 2 and 7; d2 review §4 item 3's sub-steps 1, 4, 7, 9, 10 and 11.
- Nothing relaxes the owner's bar beyond fixed decisions 1 to 3. `c2Budget` stays the only gate; 8.5 ms is never one.

### Fixes made in the draft

| Where | Fix | Why |
|---|---|---|
| "How a C2 figure is read", "The figure" | Added: a case that asserts both the heartbeat and the held turns (`commitRerouteTurns`, `BenchSyncReroutes.swift:110-128`, used by `purgeWhileOwedTurns` and `commitTwoTokensTurns`) misses when either misses | "The other is recorded beside it" let a verifier call a held-turn miss non-blocking while `verify.sh` fails on it (S3-R16 1(f)). The fix is stricter, not looser |
| Same block, "8.5 ms" | Added: a route conditional on 8.5 ms is decided on the fixer's figure at the point the route names (item 10's rule without a quiet load); a verifier's figure on the other side of 8.5 ms goes to the margin list and is not blocking | Otherwise a verifier's 8.7 ms could make "c1 (or c6, A7, the in-place batch, the group walks) was not taken" blocking, which makes 8.5 ms a gate (fixed decision 1) |
| Item 2, the jobs' side's cases | "Time the purge's synchronous turn" became: the figure is the heartbeat, as the C2 block says; the purge's turn is recorded beside it | Two readings (in-actor turn or heartbeat) against the C2 block. The heartbeat is the stricter one and hides no work (decision 1) |
| Item 3, M1's spawn argument | "`spawn` refuses only outside `.running`" became "only in `.shuttingDown`, `.shutDown` and `.degraded`"; `EngineFailures.swift:543` became `:542` | `spawn` also accepts `.created` and `.starting` (`EngineLifecycle.swift:52-56`). `sparePresent`'s `isRunning` guard is at `:542` at `d5b2ab9` (`:543` is its `return absent`; d2 review's off-by-one) |
| Item 4, the in-letter figures | The labels "(the heartbeat)" and "(the drain turn)" replaced by one rule: each figure is a BenchSync case's heartbeat, the named turn recorded beside it | "(the drain turn)" read as the in-actor turn conflicts with the C2 block; at the estimated 9-10 ms the two readings give different verdicts |
| Item 4, "That step reverses" | Names and lines paired: `followIDsPerTurn` (`EngineMoves.swift:228-235`) and `continueMove` (`:282-294`) | The draft listed `continueMove` first against `:228-235`, which is `followIDsPerTurn`'s doc |
| Item 6, the settle slice | (1) The literal 10 is replaced at all three places, the setup call's `count: 10` included. (2) Added: `@Test` takes at most two argument collections (checked in the installed `Testing.swiftinterface`: `Test<C1, C2>` is the largest overload), and T-A3 already has two, so `turns` and `count` go in as one collection of pairs, every existing case still running at count 10 | (1) The parenthesis named only two of the three places. (2) "A count argument" read as a third collection does not compile; read as a restructure, a verifier could call it a G3 change. The note makes the one-to-one form explicit |
| Item 10, "Red first" | Added: a case that misses on `d5b2ab9` but passes on the HEAD where its step starts lands green with that step, its `d5b2ab9` figure recorded as 'before' | Item 4's cases are decided at step 6, after steps 1 to 5. "Committed failing right before its fix" cannot apply to a case that passes then |
| Item 10, step 1 | "that this ruling does not name. A named finding goes with its item" | With "named" now defined, step 1 and the items' steps both claimed a named 1(a)-1(d) finding |

### Left for the orchestrator (unchanged in the draft)

1. **Item 4: a miss that pair counting cannot fix.** With the heartbeat as the figure, a k = 4 case's heartbeat may be set by a turn pair counting does not change: the commit's or the verdict's answers (40,000 interests at k = 4; d3 §2(c) rows 9 to 11 and 14). "If any of them misses, its route is pair counting" would then build pair counting for a miss it cannot cut. Suggested: "A miss whose longest turn is one that pair counting does not change (d3 §2(c) rows 9 to 11 and 14) is blocking with no route here: report it with its figures (S3-R26: a miss with no route)."
2. **Item 4: "Such a shape is measured once and recorded."** Read as a duty, the fixer must build and measure every listed out-of-dimension shape: d3 rows 1 to 8 with one hot id, row 12 at k > 4, row 14 on one id, and the `manyHolders*` cases (step 0 says these take no figure unless pair counting is triggered). Read as a recording rule, it only says what happens to a figure if one is taken; PROBE-C21-HOLDERS's cycle-21 figures already exist. The orchestrator should say which, and if a duty, which shapes.
3. **Item 2: is the jobs' side's route conditional?** "The jobs' side's route is branch-free. Use one `groups` access per member ..." can be read as unconditional work, or as the route if case (i) or (ii) misses. Suggested: "If either case misses, its route is branch-free".
4. **Item 3, PIN-APM's excluded work (decision 1).** The pin leaves `drive`'s continuation (`taskEnded` on `true`) out of the timed span and lists it beside the figure (d2 review should-fix 5). Whether listing meets "No work is hidden from a measurement", or the pin must time it too, is the orchestrator's call.
5. **Minor, item 3, B1's test:** "holds the attempt" does not say which hold (the attempt is at its answer site with `active.handle == nil`). Probably the remote transfer's start, so that no other job spawns; the fixer should name it in the draft.
