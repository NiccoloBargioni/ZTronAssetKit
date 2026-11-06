# Consistency review of s3-r28-draft.md (for S3-R28)

This is an independent, read-only check (CLAUDE.md P4) of `s3-r28-draft.md`. It was read against S3-R27 (items 1 to 12, with 12.5), S3-R26, S3-R16, CLAUDE.md, the orchestrator's decisions H and 1 to 7, `s3f-c22-issues.json`, the f1 to f3 reports with their reviews, and `.worktrees/s3f` at `9aa337c`. Nothing was built, run or measured. A claim made "by code reading" is UNCONFIRMED (G2). "draft:n" is a line of the draft, and "rulings:n" is a line of `s3-rulings-s3f.md`.

## Verdict: CORRECTED

The draft carries decisions H and 1 to 7 faithfully. Its mapping fits the findings file, except for correct #6's `:1001`, which the draft's own note 14 reports. Three things must change before the draft is appended:
- one kill rule cannot be met as written (must fix 1);
- the red-commit rule contradicts itself across the cycle (must fix 2);
- three labels clash with a names rule that still applies (must fix 3).

The should-fix items are ambiguities and steps with no place in the order.

**What holds** (checked):
- **The header.** S3-R28 is cycle 23's ruling, and S3-R16 to S3-R27 apply beneath it. The named-finding and review-binding rules are S3-R27's, applied to f1 to f3, and the should-fix items it names are those reviews' own. The C2 reading rule is S3-R27's, and the bar is the owner's (12.1).
- **The cycle's span.** `d5b2ab9..9aa337c` has 44 commits, and the last commit to touch `Sources/` is `2abddd1` (e2-A2.5).
- **The citations.** The ones I sampled resolve at `9aa337c`:
  - `metInItsAttempt` (`EngineJobs.swift:289-297`), the `.failed` arm (`:326-329`) and T20 (`:360-364`);
  - `transferSpaceEnd`'s write and clear (`EngineFailures.swift:202`, `EngineDispatch.swift:743`);
  - the bound test and the other-side test (`EngineFollowBarrierReroutePinSpaceTests.swift:160`, `:174`), and DBT:763 and :765;
  - `isPurged`'s arms (`EngineCommands.swift:1000-1011`), `:1016`, `:1065` and `:1884`;
  - `s3f.md:4385`, `:5526-5527`, `:7147-7158` and `:7790-7807`.
- **Items 1 to 3.**
  - Item 1's replay half is "must add" 1 plus must-fix 4 and 6, and it keeps the join rule for item 1b.
  - Items 2 and 3 take f2's route and f3's route as their reviews correct them, and they carry every must-fix item of those reviews.
  - e2-B′ is not authorised, and C-4 edits no file of ZTronAssetModel.
  - Every gated case has a blocking statement (draft:119, :122).

## Must fix

1. **The kill rule for the clears (draft:58) cannot be met for the deferral's clear, and its fallback fits none of the three clears.**
   - **The rule.** draft:43 binds three clears of the stamp: at the start (B11), in `recordDeferredVerdict` and in `decideSpaceFailure`. draft:58 says that each is "killed by a test, or their path is shown unreachable and removed (S3-R16 1(e))". The phrase comes from f1 review must-fix 4, which meant it for B11 alone.
   - **Why the deferral's clear cannot be killed.** By code reading, nothing reads the stamp between the deferral and `decideSpaceFailure`:
     - `relane`'s `.failed` arm skips `metInItsAttempt` while `deferredAfter` is set (`EngineJobs.swift:327`);
     - the verdict's replay clears `attemptEnd` and calls `decideSpaceFailure` in the same turn, with only `chargeTakeOff` between them (`EngineFollow.swift:392-394`).

     So dropping that clear changes no answer, no start count and no clause, and no test can kill the drop. The draft's own note 1 suspects this.
   - **Why the fallback does not fit.** `recordDeferredVerdict` runs at every deferral, so its path is reachable. A fixer who removes the clear under draft:58 contradicts draft:43. S3-R19 item 2 (rulings:242) cannot class the drop as Equivalent, because the drop changes state, not only cost.
   - **Correction.** State what happens to a clear whose drop no test can observe. Either:
     - (i) add an `invariantViolations()` clause, "a job whose verdict deferred, or was given, holds no stamp", and a test that exercises it, so that the drop fails on a clause (S3-R19 item 3, rulings:245-247); or
     - (ii) leave the clear out and record the argument above. This departs from must-fix 4 for that one clear.
   - **B11's shape.** Name B11's shape under the replay half. f1's B11 killer assumes clause (c) (f1:183), which belongs to item 1b.
   - **Where `decideSpaceFailure`'s clear sits.** Say whether it comes before that function's early returns (`EngineFailures.swift:587-596`) or at the verdict only. Which states B11's test can reach depends on that choice.

2. **The red-commit rule (draft:123) contradicts step 1 and stops before the cycle ends.**
   - **Step 1's red commit is covered by neither rule.** draft:123 extends S3-R27 12.5.12 to "every cycle-23 commit before" route C's parts. 12.5.12 also requires that "every other stage is green at every commit" (rulings:1255). Step 1's commit of the red shapes (draft:65, :149) has the Sync stage red, with the six purge cases red as well:
     - S3-R26 item 11 allows its Sync red, but not the purge cases;
     - 12.5.12 allows the purge cases only while every other stage is green.
   - **After stage C, no rule covers the red commits.** f3 estimates `keptUnderThreeGroups` at 34-39 ms and `fourGroupJoins` at 15-22 ms after route C (draft:115-116). A miss there is blocking, with no route (draft:122), so the Benchmarks stage stays red at every commit of steps 4 to 7.
     - S3-R26 item 11 says that every other commit stays green (rulings:639), and no rule covers those commits.
     - The same holds for PIN-APM if its miss stays (S3-R27 item 3).
     - Cycle 22 carried its six red cases through steps 7 and 8 the same way, uncovered.
   - **Correction:** one sentence. From `9aa337c` to the close, the Benchmarks stage may stay red for every case already committed red that is not yet closed, or that is reported as a miss, and each commit message names those cases. Every other stage is green at every commit, except at S3-R26 item 11's red-first commits, which may also carry those cases.

3. **Three labels clash with S3-R27 12's names rule, which still applies.**
   - **The rule.** rulings:1051 says "Unprefixed R1, An and P-n keep their earlier meanings", and labels from an analysis carry the analysis's name.
   - **The clashes.**
     - The draft calls f2's probe "R1" (draft:76, :85-86, :149) and f1's branches "B1" to "B11" (draft:54-58, :135).
     - Step 4 runs S3-R27 item 3 in the same cycle. That item's B1 (rulings:846), B2 (:866) and R1 (:872) are d2's.
     - So a record such as "B2 killed by the bound test" (draft:135) is ambiguous, and an unprefixed R1 reads as S3-R11's R1 or as item 3's.
     - draft:101's "Condition (b)" is C-2's condition, while draft:41's "clause (b)" is f1's.
   - **Correction.** Add a names bullet: f1's branches are f1-B1 to f1-B13, and f2's probe is f2-R1. f1's clauses keep "clause (a)" to "(g)", and f3's conditions become "C-2 (a)" to "(d)". T-F*, W-*, C-1 to C-5 and stages A to C keep their names. Apply the bullet in the text and in the draft's records.

## Should fix

1. **Clause (b) without f1's clause (a)** (draft:41, :46).
   - **The gap.** In f1, (b) is reached only after (a) has turned away a job with no window (f1:110-113). The draft takes (b) alone, so the text should say why that changes nothing outside the read of an ENOSPC publication.
   - **The argument, by code reading:**
     - the joins that `continueInbound` makes reach a failed job only through `waitingTarget`, which needs `attemptEnd` (`EngineFollow.swift:1596-1597`), so they never reach a transfer's end;
     - any other publication end that ends while moves are owed defers its verdict: `followOwed` includes `inboundOwed` (`:82-90`), and `defersToFollow` and `exitDefers` defer it (`:103-105`, `:513-520`);
     - a job whose verdict is deferred skips the check (`EngineJobs.swift:327`).
   - **Correction.** Record that argument, or scope (b) to a job that holds a stamp. Also, "A removal keeps today's count" (draft:41) should read "a removal in a visit". T-F9's removal is a replay, which the stamp dates under (f) (draft:47).
2. **Name item 1's kills.**
   - **B3.** Split it as f1's table does (f1:175):
     - forced false is killed by T-F1a and by the tests that use `pinSpaceRead`;
     - forced true is killed by T-F1b and `userJoinFromInsideAnENOSPCsReadSkipsItsVerdict`.

     `pinSpaceRead` is a helper, not a test (`EngineFollowBarrierReroutePinSpaceTests.swift:56`), so name its test, for example `owedReroutePinnedToAJobInItsSpaceReadGetsItsVerdict` (`:147`).
   - **"The publication end's write dropped"** (draft:135) has no killer in item 1. Cycle 22 planned e1-P1's own test for it (`s3f.md:7148-7149`).
   - **What counts as a kill.** Item 1 counts a kill "by an answer, a start count or a clause" (draft:53), while item 4 asks e1-P1's other-side test for "an answer or a clause" (draft:137). Use one list.
3. **Step 0's list.**
   - **T-F4 is listed twice.** "f1's T-F1a to T-F10" (draft:61) includes f1's own T-F4, whose fixture and annotation must-fix 5 calls wrong, and draft:63 adds the corrected T-F4. Say that the corrected T-F4 replaces f1's.
   - **No rule for a shape that cannot be built.** Give one for a shape that still cannot be built after a real attempt. W-DB's more than 2,048 changed entries ahead of x is one candidate, and the lazy twin is another. S3-R27 12.5.2 applies S3-R26 item 7's B-T5 rule to e1-PR (rulings:1234, :585): record the attempt and the residual risk, and the shape is not blocking.
4. **Item 1's records.**
   - **The bound test's `#require` change** (draft:52). Record its old and new text in the draft, as f1 "must say" 12 asks, and as 12.2 did for rr21-T8b (rulings:1098).
   - **The record's two values** (draft:38, :43, :45). Say, where the record is defined, that it holds two values with two lifetimes, so that "the stamp is cleared" is not read as clearing the whole record:
     - the stamp: written by both ends, and cleared at the deferral, at the verdict and at the start;
     - the count: written by the transfer's end, and cleared at the start.
5. **Route C's order.**
   - **The extended audit.** 12.5.15's audit, extended to the walk and to C-3's mid-turn state (draft:125), appears only under "Records", and step 2 (draft:150) does not list it. 12.5.15 runs its audit before the change it gates (rulings:1259-1261). Place the extended audit before C-2 and C-3 in stage A, and before C-5 in stage B.
   - **C-3's place.** The draft fixes C-3's place "before `fourGroupJoins`' step-0 figure" (draft:102), but that figure is taken on `9aa337c`, which has no C-3. Fix the place before C-3's commit, and take the case's stage-A figure with C-3 in that place.
6. **Gaps in route C.**
   - **C-5 has no path for a small retired share.** Its rebuild runs "only when the retired share is large" (draft:108), but every removal waits for the rebuild (draft:105). Carry the other half of f3 review should-fix 5: otherwise, remove the retired jobs by key in a second pass. Record the threshold and its mutants.
   - **C-2′ and the narrowed condition (b)** (draft:101) are missing from the kill list (draft:110-113). List their mutants:
     - C-2′ forced false changes only cost;
     - C-2′'s writes to the end state need a killer. `…EarlierRelane(claimed: true)` may serve, if the run shows that it reaches C-2′.
   - **Shutdown's freeing slices.** Shutdown's draining of the freeing list (draft:109) is pinned as `settle`'s slice is pinned (S3-R27 item 6).
   - **A test that the F-1 clause turns red** is "a finding of its own" (draft:102), with no class given. Give it one: S3-R16 1(b) if the state is real, with no route in cycle 23, and with the clause left uncommitted.
7. **Bench files.**
   - **The authorisation is cycle 22's.** 11.6 authorises new `BenchSync*.swift` files "that this cycle adds" (rulings:1034), and that cycle was cycle 22.
   - **No text authorises cycle 23's.** draft:142 lists "any that cycle 23 adds, citing 11.6", but nothing in the ruling's body authorises such files.
   - **Correction.** Extend 11.6 to cycle 23 in the body, with its two conditions, or require that the new cases go into 11.6's files.
8. **The verifiers' rules.**
   - **Item 1b.** draft:5 says the verifiers judge "with item 1b once it is appended". Say that item 1b binds a verifier only for the fixer runs that started after it was appended. Until then, its shapes stay blocking as reported.
   - **The load window.** draft:163 says that the release benchmarks run "in a window with a 1-minute load of 10 or less". Add "when one occurs; otherwise the C2 rule's 'not measured at a quiet load' applies" (rulings:763).
9. **Small points.**
   - **The 30 iterations** (draft:86): say whether they are run.
   - **The rewritten mutants.** Cycle 23's rewrites go under `.build-s3f/c23/tools/` (draft:29), and `c22/` stays as cycle 22 left it. 12.5.6 edited cycle 22's copies in place (rulings:1243), so say this outright.
   - **The clock.** f2-R1 drives the clock (draft:76), while draft:81 forbids clock moves. Add "in the committed test" to draft:81.
   - **The margin list.** draft:31's "8.5 ms decides only the routes that name it" leaves out the margin list (rulings:764).

## For the orchestrator

1. **Decision 4's drop-mutant.**
   - `EngineCommands.swift:1004` and `:1009` are each a `return true` inside a `guard`'s `else` (`:1003-1005`, `:1008-1010`). With the `return` dropped, the code does not compile, so "kills its drop-mutant" cannot be met as worded. Read it as "the mutant that answers false".
   - `:1001` (`case .all: return true`) has the same form, and correct #6 names it (the draft's note 14). Correct #6's alternative, a constant predicate for `.all`, would remove that arm.
2. **The stage trigger** (decision 3; the draft's note 8; f3 review should-fix 7). As worded, `keptUnderThreeGroups` and `fourGroupJoins` start stages B and C, which by f3's estimates do not reach them (7-10 h, f3 §5). A trigger that names the cases each stage can move would avoid that.
3. **W-DB.** f1 review "must add" 2 says that even the candidate join rule leaves W-DB without a route. If W-DB is red in step 0, item 1b should route it, or state that it is blocking with no route in cycle 23. The same applies to any other red shape that item 1b does not reach.
4. **The fifth in-letter shape** (the draft's note 7). The bar covers 40,000 one-member groups, four on each id, whether or not the shape is gated (12.1; S3-R16 1(f)). A verifier who builds it and sees a miss reports a blocking miss with no route. Leaving the shape ungated only delays that.
5. **The unmapped non-blocking findings.**
   - Reqs #8 is SPEC.md:331's `.timeLimit` on a test that awaits. S3-R16 1(f) gates "the hang guards", so reqs #8 may deserve a one-line route in step 6.
   - Reqs #9 (11.6's "only … extensions" against the files' helper types) bears on should-fix 7, so rule it before step 2 adds cases.
6. **The draft's own notes.**
   - Must fix 1 and should-fix 1 give the text a lawful outcome for notes 1 and 3, so the orchestrator need only confirm the choice. Reading decision 1's "does not change the dating of joins" as "beyond clause (b)" is right.
   - Note 5 (the order against f1): A-T-SD's setup check runs in every Sync bundle, so item 1b's commits re-check T20 without a separate rule.
   - I agree with notes 4, 6, 9, 10, 11, 12 and 13.
7. **The mapping**, checked against `s3f-c22-issues.json`:
   - correct #1 to #7 and reqs #1 to #7 fit the items that decision 7 maps them to;
   - only correct #6's `:1001` is left over (the draft's note 14);
   - correct #8 to #10 and reqs #8 to #11 are non-blocking and unmapped, as the draft lists them.
