# Review of the S3-R27 draft: fidelity to the analyses

Read-only review of `.build-orchestrator/s3f-c21-analysis/s3-r27-draft.md`, judged against d1 to d5, the reviews of d1, d2
and d4, and the code at `d5b2ab9` in `.worktrees/s3f`. Nothing was built, run or measured. Code lines were read with
`git show d5b2ab9:<path>`. Draft citations are given as "item n, bullet" because the draft's own line numbers will move.

## Verdict: CORRECTED

The draft routes every open item the way its analyses and reviews do. It carries most of the reviews' must-fix items
correctly. Nine places need correcting before the fixer and the verifiers use the ruling:
- one misplaced cut (c6);
- one wrong expected value (T-A3's slices);
- one misattributed condition (residual 5);
- one quote that does not exist in d1;
- three review must-fix items that were dropped or reduced (d4's ruling on the default-tuning case, d2's M1 rule
  "collected unconditionally", and d2's M4 assertion for PIN-APM-SPARE);
- one B1 test that contradicts its own "no test seam";
- one missing mutant-text update (r8) that the r7 removal makes necessary.

The should-fix list is mostly review recommendations dropped with no reason given.

## 1. Citations checked against the code at `d5b2ab9`

| Draft citation | Holds? |
|---|---|
| `8e1fb24..d5b2ab9`, 73 commits; last code commit `e599ae1` | yes (`git rev-list --count`: 73; `git log -1 -- Sources Tests`: `e599ae1`) |
| item 1: 10.31, 10.45, 11.09 ms, each at a quiet load | yes. 10.31 is the c12 heartbeat at `2c351e8` (`c12-sort.out:8`, load 4.18–4.33). 10.45 and 11.09 are the gate runs (`s3f.md:6828-6829`, mean loads 5.60 and 5.23) |
| item 1: `integrate-c21.md:447` | yes: "Do not defer the broadcasts or the binding." |
| item 1: S3-R26 item 4 ruled `reserveCapacity` for `groupStalledSubscriber` only | yes (rulings, S3-R26 item 4) |
| item 1: "(d1, 'Before committing')" | **no.** d1 has no such phrase. The probe is d1 §4 item 3, "Measure first". See M4 |
| item 1: c6 "`guard !keys.isEmpty` in `broadcastAll`" | **no.** d1 (§3 table) and its review (should-fix 6) put it at `publishTerminal`'s top. See M1 |
| item 2: 10.04 ms best in one gate run; the request read first saves about 1 ms | yes (`s3f.md:6830-6832`, `:6668-6696`; d4 §3.3: 9.17 − 8.14 ≈ 1.0 ms) |
| item 2: `withdrawPurged` "at 10,000 ids … 17–33 ms with 10,000 one-member prefetch groups (d3 (c))" | partly. d3 §2(c) row 14 estimates 17–33 ms for 10,000 one-member groups **on one id m**. For 10,000 ids it says only that "the same O(pairs) holds". See S9 |
| item 3: 10.79, 12.76, 14.17 ms | yes (`s3f.md:6834-6836`; d2 §0) |
| item 3: `EnginePresence.swift:277-292` | yes: the final guard (`:277-281`), `bind` and `answerPresentMembers` (`:282-283`), the interests guard (`:284-286`), `retire`, `pump`, `reconcileIdle` (`:289-291`) |
| item 3: `EngineFailures.swift:73` | yes: `guard let job = self.state.jobs[transfer]`; the copy is used at `:145`, `:153` and `:193` |
| item 4: the shape has 2 ids; S3-R25's set is "10,000 ids, however their interests are grouped" | yes (d3 §3.2; rulings line 342) |
| item 4: "`integrate-c21.md` item B's residual 5 ('blocking if a case with h near 10,000 misses `c2Budget`'), which S3-R26 adopted" | **no.** `integrate-c21.md`'s residual (line 305) says only "An id with many holders still moves whole in one turn, at O(h log h) for the pairs' sort." The blocking condition is the cycle-21 fixer's own record under S3-R26 item 10 (`s3f.md:5645-5646`). See M3 |
| item 4: `drainReroutesAnOwedIDWithAllItsTokensInOneTurn`, `barrierBoundsOneIDMovesOffAHolderPerTurn` | yes (`EngineFollowBarrierRerouteCommitTests.swift:306`, `EngineFollowBarrierMoveHoldersTests.swift:189`) |
| item 4: `fourGroupsFollowTurns` | a case d3 proposes (§2(b) BenchSync cases), not yet in the code. The draft names it as d3's, which is right |
| item 5: `EngineFailures.swift:834`, the `!atEnd` conjunct at `:840`, the comment at `:829-833` | yes |
| item 5: r6's mutant text | yes, but incomplete: r8's text also contains `!atEnd` (`.build-s3f/c21/tools/mut-c4fix.py:42-44`). See M8 |
| item 6: `EngineFailures.swift:861-862` and `:868-870` | yes as the draft's names (the guards start at `:860` and `:868`; d4 §0) |
| item 6: `EngineShutdown.swift:178-183` | yes (the `if` is at `:177`) |
| item 6: T-A3 at `EngineOwedAnswersTests.swift:190`; slices exactly [512, 88]; drop-mutant [600] | the test exists (`:190` is the `@Test` line, the func is at `:191`). **The expected slices hold only for one of its two arguments.** See M7 |
| item 6: `EngineFollow.swift:882-884`, the doc at `:876`, the clause beside `EngineCommands.swift:2275` | yes |
| item 6: `barrierFailsA429BeyondTheCapsAsOnArrival` | yes (`EngineFollowBarrierReachTests.swift:50`) |
| item 7: `s3f.md:6653-6655`, `:9807-9808` | yes |
| item 7: `EngineFollowBarrierWaitingTargetTests.swift:191-193` | yes: `afterTurn`, inside the `sweepFollowsFirst` branch (`:184-197`) |
| item 8: `releaseRerouteHolds`' row has no figure | yes (`s3f.md:4961`; `EngineFollow.swift:827`) |
| "S3-R6" for the ARCHITECTURE note | yes: S3-R6 makes document changes proposals in the draft |

## 2. Fidelity, analysis by analysis

The key: **C** carried correctly; **C~** carried, but weakened or imprecise; **O** deliberately overridden, with a reason
stated; **O?** overridden with no reason; **D** dropped with no reason.

### d1 and its review (draft item 1)

| Item | Draft | Status |
|---|---|---|
| d1 §4.1: (a) = a1, a2, a3, with c3, in one step | "Route: d1's route (a) with c3, in one step" | C |
| d1 §4.2: c1 only if still above 8.5 ms | as stated | C |
| d1 §4.2: c1's tests (T-C1-1), and a BenchSync case for its arm choice | absent | **D** (S2) |
| d1 §4.3: the scratch probe, four variants | carried, attributed to a phrase that does not exist | C~ (M4) |
| Review M1: a2's guard, its Equivalent drop-mutant, the re-announcement shape | carried. The review says "recorded … outside the gate"; the draft says "gated as C2". Both make a miss blocking | C~ (S5) |
| Review M2: the decision rule, and route (b) not started | carried | C |
| Review M3: the `.failed`-arm case, keeping `sorted()` | carried | C |
| Review should-fix 1: c1's saving | not needed by the ruling | n/a |
| Review should-fix 2: capture `generation` first; no lazy `filter`; nothing in the access reads `self.state` | carried and made stricter ("events built once, as an array"), with no reason given | **O?** (S4) |
| Review should-fix 3: T-A-3's pre-live id | carried | C |
| Review should-fix 4: the ARCHITECTURE §4.3 note and the doc comment | carried | C |
| Review should-fix 5: authorise a2 for `waitersStalledSubscriber` | carried | C |
| Review should-fix 6: c6 at `publishTerminal`'s top | carried at the wrong site | **wrong** (M1) |
| Review should-fix 7: the probe's controls | carried | C |
| Review should-fix 8: c1's tests (T-C1-1 with another job's `.transfer` key and a `.run` key; T-PG4) | absent | **D** (S2) |
| Review should-fix 9: T-A-2 asserts the hand-off directly | carried | C |
| Review "must add": the per-step order, and measuring four shapes plus the two-subscriber case after a3 and again after c3 | reduced to `.waiters` and `.waitersStalledSubscriber` "after each step" | **D** (S3) |
| Review "must add": the branch table (c3's forced-true kill by T-ORDER in `sweepFollowsFirst`; its drop-mutant Equivalent) | absent. The draft's "each new branch's drop-mutant killed 2/2" contradicts it | **D** (M2) |
| Review "must add": covdiff over every changed line | covered by item 9 | C |
| Review "must add": the two-subscriber figure stays "open, for the owner" | carried | C |

### d2 and its review (draft item 3)

| Item | Draft | Status |
|---|---|---|
| d2 §3: (a) = A1, A2, A3 with A3′, A4, A5, A6a, A6b, A8, plus B1 | carried | C |
| d2 §3 decision rule: the A6b variant if still above 8.5 ms | absent | D (S11) |
| d2 §3: route (c) only above 10 ms | not mentioned. The draft makes every miss blocking but does not say (c) is not authorised | D (S11) |
| d2 §2.2: a probe of an apply that re-binds an id between two reads | absent | D (S11) |
| Review M1: byte-identical single path; the discarded spawn result and its argument | carried. The argument loses its premise, "`spawn` refuses only outside `.running`" | C~ (S6) |
| Review M1: A4's mark without a guard, **and the read collected unconditionally** | the first half only | **D** (M6) |
| Review M1: `Group.dropMember`'s mismatch line; relocated lines with counts | carried | C |
| Review M2: B1's code shape | carried by reference | C |
| Review M3: PIN-APM's state seam, its post-timing assertions, its shapes | carried | C |
| Review M4: A8 extended to `failed` | carried | C |
| Review M4: PIN-APM-SPARE factors `:541-552`, **asserts that the job was removed**, and measures the 404 end | the timing only. No assertion, no end named | **D** (M5) |
| Review M5: cut the group walks, then the index | carried (adds B2 to the trigger, which is consistent) | C |
| Review M5: "its groups and ensureGroups shapes keep their 10,000 groups registered" | absent | D (S7) |
| Review M6: A7 and R1 ruled now | carried. R1 is filed under "Pre-ruled orders", but it is a progress-event class, not an order | C~ (S8) |
| Review should-fix 2: one owned task, with no bound and no seam; the test kills the read loop's call | carried, but the test checks "the site has one task", which needs a seam | **contradiction** (M5) |
| Review should-fix 3: A5 by moving `notifyObservers()`; the `waitUntil`/`awaitCondition` audit before A2 and A5 | the A5 shape comes in through the order of work (§4.3 item 2). The audit is absent | D (S6) |
| Review should-fix 4: re-run the relocated conditions' mutants | carried | C |
| Review should-fix 5: the drive continuation is outside the pin | absent | D (S6, minor) |
| Review should-fix 7: shutdown's cancelled-but-reading task as a residual risk; no `Task.isCancelled` branch | absent | D (S6) |
| Review should-fix 8: B2's `owing` defaults to `false` | absent | D (S6) |
| Review §1: cite the iOS SDK's interface for A3′ and A6a (C7) | absent | D (S6) |
| Review §4.1: name both callers in the C2 inventory row | absent from item 9 | D (S6) |
| Review §4.2: the integrity path's first turn as a row with a figure | carried, but "two 10,000-id sorts" leaves out the 10,000 inserts and two `min()` walks behind the 6.5–7.5 ms | C~ (S6) |
| Review §4.3: the order of work | carried (item 10, step 5) | C |
| Review §4.4: the `lastEmitted` aside, one probe | absent | D (S6) |

### d3 (no review; draft items 2 and 4)

| Item | Draft | Status |
|---|---|---|
| §0, §3.3: the owner sizes the per-id dimension; take d3's sizing proposal | carried | C |
| §0, §3.3 recommendation 2: "Whatever the owner rules, implement (b)" | built only if an in-letter shape misses. No reason is stated for departing from d3 | **O?** (S10) |
| §2(c) row 12: k ≥ 4 over 10,000 ids, "arguably inside" the letter | made in-letter and measured at k = 2 and k = 4 | O (a ruling, and allowed) |
| §2(c) row 7: site 2's verdict take-off counts ids | not among the measured parts of the k-shapes | D (S10) |
| §2(b): P1–P4, PAIRS-T1 to T5, the BenchSync cases | carried | C |
| §2(b): the clauses and rulings to change | carried in part. Missing: the doc comments at `EngineMoves.swift:228-235` and `:282-294`; S3-R22 item 1 and S3-R25 item 1 read as pairs; the residual "One id with k tokens costs k re-routes in one id slot" closed | D (S10) |
| §2(a): A1 to A3 as margin | A1 and A2 only. A3 is the largest saving, −7.5 to −8 ms in shape 3, and it is branch-free | **D** (S10) |
| §2(c) row 14: the purge's estimate | its scope is misquoted | C~ (S9) |
| §4 item 1: the progress-key and run-metric readers, to be probed in PAIRS-T5 (i) | absent | D (S10, minor) |

### d4 and its review (draft items 5 and 6)

| Item | Draft | Status |
|---|---|---|
| r7's removal; the replayVerdict removal with its epoch clause and clause test | carried | C |
| Review M1 (r8), M2 (p7), M3 (b22-no-waiter-owner) | carried | C |
| Review M4: f7 in both orders with an in-flight apply, and its fallback ruled | carried; "if that shape cannot be built" stands in for the review's "if the in-flight apply changes the commit's path" | C |
| Review M5: r2b is open | carried. The review's alternative to building the test, "argue … citing every writer of `rerouteFor` and the take-off's ids", becomes "show that its state cannot be built" | C~ (S12) |
| Review should-fix 1: rewrite r6's, r7's and r8's mutant texts; re-run r6 | r6 only | **D** (M8) |
| Review should-fix 2: await `state.run == nil` | carried | C |
| Review should-fix 3: vy's follow-up turns held | carried | C |
| Review should-fix 4: extend T-A3; exactly [512, 88] | carried, but wrong for one of T-A3's two arguments | **wrong** (M7) |
| Review "must add" 3: rule the class of d4 §1's default-tuning case | not ruled: the fixer is told to "record" it | **D** (M9) |
| Review "must add" 4: the removal texts | the draft says "rewrite" and "update" but gives no text | D (S12) |
| Review "must add" 5: each new test's first run on unmutated code is green before its kill counts | absent | D (S12) |
| The review's amended order | item 10, step 2 says "in d4's order", but the review's order differs, and by the draft's own rule the review wins | C~ (S12) |

### d5 (no review; draft item 7)

| Item | Draft | Status |
|---|---|---|
| Record the audit in place of `s3f.md:6653-6655` and `:9807-9808` | carried | C |
| The optional WaitingTarget pin | made required; allowed | O |
| "Do not" hold attempt terminals globally | carried | C |
| What could go wrong: if the pin fails, hold terminals locally around `:190` (`takeOffTurns`' pattern) | absent. "Do not hold … globally" alone leaves the local fallback unstated | D (S13) |
| The fixer's own Step-8 list was spot-checked, not re-derived | "d5 found no racy reader" says nothing of that limit | C~ (S13) |

## 3. Must-fix

**M1. Item 1, "Optional margin": c6 is at the wrong site.** d1 (§3, table, "c6") and its review (should-fix 6) put
`guard !keys.isEmpty` at `publishTerminal`'s top. Its 0.7–0.9 ms saving is the filter's two hashes per id
(`EngineJobs.swift:802`), which run before any broadcast. Inside `broadcastAll` the guard comes after `announced` is
built, so it skips almost nothing. Replace the bullet with:

> - **Optional margin:** c6, `guard !keys.isEmpty else { return }` at the top of `publishTerminal`, after its `lane`
>   guard and the `keys` sort (`EngineJobs.swift:796-799`), so that neither arm filters or broadcasts when no subscriber
>   exists. It is Equivalent: only `lastEventSequence` and the observer passes change (d1 review, should-fix 6). It may
>   be added if `manyGroups` is still at the edge.

**M2. Item 1, "Tests": c3's branch has no disposition, and "each new branch's drop-mutant killed 2/2" cannot hold for
it.** The reasons:
- c3's drop-mutant ("always look up") is Equivalent.
- Its forced-true mutant is killed by T-ORDER in `sweepFollowsFirst` only: in `followVisitedFirst`, zz-o5 has left
  `job.assets` before the commit (d1 review, Settled 3).
- a2's guard is also Equivalent, as the draft itself says.

A verifier reading the draft literally would report c3 as blocking. Replace "**Tests** (each new branch's drop-mutant
killed 2/2):" and its list with:

> - **The branches and their kills** (S3-R16 1(e); d1 review, "What the ruling must add"):
>   - a1's compound `if`: T-A-1 (both flips of `replaced`, and dropping `isProgress`), 2/2;
>   - a2's reserve and its guard: Equivalent (S3-R19 item 2);
>   - `publishAll`'s hand-off `if let`: T-A-2, which asserts the hand-off directly, inside `withCheckedContinuation`;
>   - `coalesced ? 1 : 0`: T-A-3, a commit of 3 ids with one waiting and one stalled subscriber, in both orders. One id
>     is already live in the stalled queue before the commit;
>   - c3's `allBound`: forcing it to `true` is killed by T-ORDER 2/2 in `sweepFollowsFirst`. The state, an unbound id
>     still in `job.assets` at the commit, arises only there (S3-R26 answer 1; the citation is d1 review, Settled 3:
>     visited first, the visit removed zz-o5 from `job.assets` before the commit). Dropping it is Equivalent;
>   - c1's two arms, if taken: T-C1-1 and T-PG4.

**M3. Item 4, "Scope", third bullet: the condition it replaces is the fixer's, not `integrate-c21.md`'s.**
`integrate-c21.md:305` gives residual 5 as a cost with no condition. "Blocking if a case with h near 10,000 misses
`c2Budget` at a quiet load" is the cycle-21 fixer's classification, recorded under S3-R26 item 10 (`s3f.md:5645-5646`).
Replace the bullet with:

> - This replaces the condition the cycle-21 fixer recorded for `integrate-c21.md` item B's residual 5 under S3-R26
>   item 10 ("blocking if a case with h near 10,000 misses `c2Budget` at a quiet load", `s3f.md:5645-5646`).

**M4. Item 1, "A scratch probe first": the quoted source does not exist.** d1 has no "Before committing". Replace
"(d1, "Before committing")" with:

> (d1 §4 item 3, "Measure first"; the controls are d1 review, should-fix 7)

**M5. Item 3, "B1's task", and "PIN-APM-SPARE": a test that needs a seam the draft forbids, and a pin with no
assertion.**
- (i) "The site has one task" cannot be observed without a task-count seam, and the same sentence says "no test seam".
  The review's test (should-fix 2) instead kills the drop-mutant of the read loop's call.
- (ii) Review M4 requires PIN-APM-SPARE to assert that the job was removed, so that it cannot pass vacuously, as M3
  guards PIN-APM. The draft keeps only the timing.

Replace the two bullets with:

> - **B1's task.** B1 uses one owned task per answer site, with no batch bound and no test seam (d2 review,
>   should-fix 2): `// REENTRANCY: RE-S36` on the loop's await, RE-S21 on the spawn closure. Its test: five waiters at
>   the site, every one answered `.success` with the store's location, `invariantViolations()` empty, and the drop-mutant
>   of the read loop's call killed 2/2.
> - **PIN-APM-SPARE** factors `EngineFailures.swift:541-552` into an internal function the bench calls inside the actor.
>   It times `sparePresent`'s post-read tail with the caller's `pump` and `reconcileIdle`, for group, groups and users,
>   at the 404 end (the job's own `assets` set passed in, the worse end). After timing it asserts that the job was
>   removed and every interest answered; a run in which that fails is a failed case (d2 review M4).

**M6. Item 3, "M1, the zero-count guards", third sub-bullet: half of the review's rule is missing.** Without "collected
unconditionally", a fixer may append the read only when the mark found a waiter. That is a new conditional, and it is
unreachable (`EnginePresence.swift:131-132` is at count 0), so it would be blocking under 1(e). Replace the sub-bullet
with:

> - A4's mark is written without a guard, `self.state.waiters[row.token]?.markFromStore(at: transfer)`, and the read is
>   collected unconditionally. A missing waiter makes its read return at `readPresentLocation`'s existing guard
>   (`EnginePresence.swift:151`, unchanged), so A4 adds no conditional.

**M7. Item 6, the settle slice: [512, 88] is wrong for one of T-A3's two arguments.**
- T-A3 runs `arguments: LaneDropVisit.allCases, [0, 1]` (`EngineOwedAnswersTests.swift:190`). Its set-up sets
  `answersPerTurn = 4` (`:39`).
- At `turns: 1`, one follow-up resumes 4 answers before the shutdown, so 596 remain: correct code records [512, 84], and
  the drop-mutant records [596].
- `steps` also carries over into the waiter and job loops (`EngineShutdown.swift:185-219`), so the exact value holds
  only when no waiter or job is left at the shutdown (d4 review, should-fix 4).

Replace the bullet with:

> - **`EngineShutdown.swift:178-183`, `settle`'s slice.** Give T-A3 (`EngineOwedAnswersTests.swift:190`) a 600-caller
>   argument and shut down. Assert that the slices are exactly [512, 600 − 4 × turns − 512]: [512, 88] at `turns: 0`, and
>   [512, 84] at `turns: 1`. The setup's `#require` reads `count − 4 × turns`, and the setup requires that no waiter or
>   job is left before the shutdown. The drop-mutant gives one slice, [600 − 4 × turns]; kill it 2/2.

**M8. Item 5, "Remove": r8's mutant text also contains `!atEnd`.** `mut-c4fix.py:42-44` gives all three texts as
`if join.chain != nil, !atEnd, !here(join.asset) {`. After the removal, r8's original no longer matches the source, so
r8 cannot be run, and "r8: kill it with …" cannot be met. d4 §3.1 and its review (should-fix 1) name r6, r7 and r8.
Replace "Rewrite r6's mutant text after the removal, and re-run r6 2/2 (G2)." with:

> - Rewrite the mutant texts in `.build-s3f/c21/tools/mut-c4fix.py` after the removal. The original of each becomes
>   `if join.chain != nil, !here(join.asset) {`. r6's mutant becomes `if join.chain != nil {`, and r8's becomes
>   `if !here(join.asset) {`. r7's entry is retired with its branch. Re-run r6 2/2 in its LANE list (G2). r8's kill
>   below runs on the rewritten text.

**M9. Item 5, "Record `followedLane`'s lane": the review asked for a ruling, and the draft gives a recording task.** d4
review, "What the ruling must add" 3: rule whether d4 §1's default-tuning case (from the third attempt, a seeded
background backoff above `interactiveMaxWait` makes another user's request fail fast; d4 §5 item 6) is S3-R16 item 2 or
a probe-first 1(a) item. The draft says "Record … whether the default tuning's backoff can", which leaves the class to
the verifiers. Replace the bullet with one ruling. The text below takes S3-R16 item 2's letter ("which lane's backoff
policy applies") with S3-R26 answer 6's condition:

> - **Record `followedLane`'s lane** in the draft. It decides only the 429's retry policy (d4 §1, confirmed by its
>   review). Record the tuning under which a wrong lane changes an answer (`shortInteractiveRetry`: `.exhausted` against
>   `.until`; the survivor tests use it).
> - **The default-tuning case** (d4 §1, §5 item 6) is ruled S3-R16 item 2, "which lane's backoff policy applies": a
>   residual risk, recorded with its condition. A seeded background ceiling above `interactiveMaxWait`, from the third
>   attempt, can make another user's request fail fast where the interactive end lets it wait. It needs no probe this
>   cycle. A probe that shows a different answer with the 429 before both answers, or after both, is blocking
>   (S3-R16 1(a)).

(If the orchestrator wants it the other way, the alternative is: "a probe-first 1(a) item: build it in both orders at
the third attempt with a fixed seed; blocking if the answers differ".)

## 4. Should-fix

**S1. Item 10, step 2, "in d4's order".** By the draft's own rule the review wins, and its order differs (the
replayVerdict removal before b23, f7 after the settle slice). Replace with:

> 2. Item 6's removal and settle slice, and item 5's removal and its cheap kills (b23 and f7), in d4 review's amended
>    order (its steps 1 to 5).

In step 7, write "b22-no-waiter-owner, p7 with r5, r8, vy, r2c, b22-no-run-owner and r2b" (the review's steps 6 to 12).

**S2. Item 1: c1's tests and its arm-choice case are missing** (d1 §4 item 2; review should-fix 8). Add to the route
bullet:

> c1, if taken, comes with T-C1-1, in which `lastEmitted` holds another job's `.transfer` key and a `.run` key, and
> T-PG4, which already reaches the `lastEmitted` arm. The arm choice's drop-mutant is Equivalent. It also gets a BenchSync
> case with many live progress keys and many removals in one turn, or the draft records why none can be built.

**S3. Item 1, "Figures": the per-step measurement is narrower than the review's.** Replace with:

> **Figures.** After a3, after c3, and after c1 if taken, take `commitTurns(.waiters)`, `(.waitersStalledSubscriber)`,
> `(.groupStalledSubscriber)` and `(.manyGroups)`, and the two-subscriber case, each best of 3 with its load (d1 review,
> "What the ruling must add"). Commit each with its figure. The scratch probe's four variants go in the draft.

**S4. Item 1, "Exclusivity", first bullet: stricter than the review, with no reason.** The review forbids a lazy
`filter` and any read of `self.state` inside the access. It allows d1's `announced.lazy.map` with `generation` captured
first. Building 10,000 `AssetEvent`s (about 48 B each) is a new cost on every commit, `.waiters` and `manyGroups`
included. Either give the reason, or replace the bullet with:

> - the ids are filtered once, into an array (`announced`), before the access to `state.subscribers`; the events may be
>   a lazy `map` over that array whose closure captures `generation` beforehand (d1 §3 a3);

**S5. Item 1, "Two new cases, gated as C2".** Review M1 and M3 make both cases recorded ("outside the gate"; "a
recorded BenchSync case"), with a miss still blocking. If gating them is intended, say so: "Gated, not only recorded as
the review has it, so that `verify.sh --full` fails on a miss." Otherwise write "recorded".

**S6. Item 3: review recommendations dropped with no reason.** Add after "Mutants":

> - **The spawn argument** (M1) states its premise: `spawn` refuses only outside `.running`
>   (`EngineLifecycle.swift:52-56`), and both callers checked `isRunning` earlier in this turn (`EnginePresence.swift:277`,
>   `EngineFailures.swift:543`).
> - **Audit first** (review, should-fix 3). Before A2 and A5, audit the `waitUntil` and `awaitCondition` predicates of the
>   answer-site suites for a state that exists only mid-turn. Record the audit.
> - **B2's `owing`** defaults to `false`, so that `reroute` and the purge walk keep their behaviour (review, should-fix 8).
>   `scheduleAnswerFollowUp` may become internal.
> - **Shutdown with the batched read** (review, should-fix 7). A cancelled read task still runs its remaining reads, so
>   the shutdown's join waits longer. This is timing: record it as a residual risk (S3-R16 item 2). Add no
>   `Task.isCancelled` branch.
> - **C7.** Cite A3′'s and A6a's `Dictionary` APIs in the iOS SDK's `Swift.swiftinterface` (`iPhoneOS27.0.sdk`) as well
>   as the macOS one (review §1).
> - **The inventory** (item 9) names both callers' tails as rows, each with its pin: `answeredFromStore`'s (PIN-APM) and
>   `sparePresent`'s (PIN-APM-SPARE) (review §4 item 1).
> - **The pin's scope** (review, should-fix 5). The turn also runs `drive`'s continuation, `taskEnded` on `true` and the
>   `interests` walk on `false` (`EngineDispatch.swift:812`). Neither is in the pin. The draft records this.
> - **One probe, not blocking** (review §4 item 4). After `answerPresentMembers` subtracts the present ids, `removeJob`
>   retires only the progress keys of the ids left (`EngineJobs.swift:488`). Probe whether a present id's `lastEmitted`
>   entry is left behind on the 404 path.

Also, in "The integrity path's first turn", replace "It runs two 10,000-id sorts" with "It runs two `job.assets.min()`
walks, two 10,000-id sorts and 10,000 inserts (`EngineFailures.swift:77`, `:80`, `:193`, `:494`, `:535`)".

**S7. Item 3, "PIN-APM", shapes.** Add: "Its groups and ensure-groups shapes keep their 10,000 groups registered through
the timed tail, so that `materializeEnsures`' and `pruneBoundContent`'s walks are inside the figure (d2 review M5)."

**S8. Item 3, "Pre-ruled orders": R1 is not an order.** d2 §2.5 notes that its progress-event difference is not in
S3-R16 item 2's list. Rename the heading "**Pre-ruled classes** (M6)" and open R1's bullet with: "R1's difference, one
progress offer where there were two, is added by this ruling to S3-R16 item 2's non-blocking list, for this site only."

**S9. Item 2, "The jobs' side has no figure": the estimate's scope.** Replace the sentence with:

> `withdrawPurged` with 10,000 one-member prefetch groups on one id is estimated at 17–33 ms, and the same O(pairs) holds
> for 10,000 one-member groups on 10,000 ids (d3 §2(c) row 14; UNCONFIRMED).

Add: "Reading the request first adds an early return whose drop-mutant is cost-only: Equivalent (S3-R19 item 2; d4
§3.3). b23's kill tests purge a `.scope`, so they stay valid."

**S10. Item 4: d3's recommendation is departed from with no reason, and parts of its list are missing.**
- After "If all pass, pair counting is not built in cycle 22", add: "This departs from d3's 'implement (b) whatever the
  owner rules' (d3 §0, §3.3). At k = 1 the move sites meet C2. Pair counting reverses S3-R26 answer 7 and four
  `integrate-rr21.md` rules, and adds a branch, five mutants and five probes. Under S3-R16 item 3 it is built only on a
  measured miss, or on the owner's sizing."
- In "Measure two in-letter shapes", add site 2: "and site 2's verdict turn with its take-off (d3 §2(c) row 7)".
- In "That step reverses, for pairs", add: "the doc comments of `continueMove` and `followIDsPerTurn`
  (`EngineMoves.swift:228-235`, `:282-294`); S3-R22 item 1 and S3-R25 item 1 are read as pairs; `integrate-rr21.md`'s
  residual 'One id with k tokens costs k re-routes in one id slot' is closed; PAIRS-T5 (i) also checks the run's report
  counts (d3 §4 item 1)."
- In "Margin", replace "A1 … and A2 …" with "A1 (hoist `decisionNow()`), A2 (format the transfer id once) and A3 (one
  jobs-table read per join, with no `Job` copy bound at `EngineJobs.swift:137`; d3 §2(a), the largest of the three)",
  or state why A3 is left out.

**S11. Item 3, the route's contingencies.** Add: "Route (c), a bounded answer over turns (d2 §2.4), is not authorised in
cycle 22: a miss is reported. The A6b variant that saves two lookups (d2 §3) may be taken as margin, with its rewritten
branch killed by the add and remove tests 2/2. Probe B1 once in both orders: an apply that re-binds one id between two
reads of the site's task (d2 §2.2; S3-R19 item 1)."

**S12. Items 5 and 6: the review's texts and its first-run rule.**
- Under "Remove", give the comment at `:829-833` the review's text: "The lane is read only at a downloading job's 429
  (`throttled`), never at an attempt's end, so no pin of this job holds a waiting join: a chained join reaches it only
  where the engine's copy maps its id here."
- Under item 6, give `:876`'s last sentence the review's text: "While its record waits, the job is present, failed and
  at the record's epoch (`invariantViolations()`), so the replay checks the record only."
- Under "Every kill", add: "Each new test's first run on unmutated code is green before its kill counts (d4 review,
  'What the ruling must add' 5)."
- In "r2b is open", replace "or show that its state cannot be built" with "or argue in the draft that no take-off item's
  entry can name a later verdict's content, citing every writer of `rerouteFor` and the take-off's ids (d4 review,
  'What the ruling must add' 1)".

**S13. Item 7: d5's limit and its fallback.**
- Replace "d5 found no racy reader." with "d5 found no racy reader in the seven listed suites or the rest of the Sync
  tests. It spot-checked the fixer's own Step-8 list and did not re-derive it; the draft records that."
- After "Do not hold attempt terminals globally", add: "If the pin fails, the reading was racy. Hold the attempts'
  terminals around that one turn only (`holdAttemptTerminals()` before `runOneFollowTurn` at `:190`, released after
  `afterTurn`), as `takeOffTurns` does (d5, 'What could go wrong')."
