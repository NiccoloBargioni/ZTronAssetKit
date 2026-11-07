# S3-R28: the orchestrator's rulings on the editor's notes (6 Nov, 12:37)

These rule notes 1 to 18 of `s3-r28-draft.md`'s "For the orchestrator" section, and the reviews' should-fix items. They are final. The editor applies them to the ruling text (draft lines 1-183) and leaves the "For the orchestrator" section out of the final text. Line numbers are at `9aa337c`.

- **N1. The stamp's clears.**
  - Option (i) is confirmed: every clear stays. A clear whose drop no test can observe is killed on an `invariantViolations()` clause that the drop breaks, with a test that exercises it (S3-R19 item 3).
  - The verdict's clear stays first in `decideSpaceFailure`, before its early returns.
    - Add the reason: both callers check the job's epoch before they call it. These are `spaceFailed`, after its read (`EngineFailures.swift:570`), and the drain's replay of `.spaceFailure` (`EngineFollow.swift:387`).
    - So the clear ends only the stamp of the attempt whose verdict it gives, never a later attempt's. A later attempt changes the epoch.
  - **Each clause reads state that `invariantViolations()` can see.**
    - For the deferral's clear, the clause is "a job whose verdict has deferred (`attemptEnd?.deferredAfter != nil`) holds no stamp".
    - For the verdict's clear, the fixer either states such a clause or kills the clear by a test, and the draft records which. Note that a job T20 re-queued inside the read is `.queued` and still holds its stamp until the verdict, so "a queued job holds no stamp" is not a valid clause.
- **N2. The named should-fix items.**
  - The writer's list stands.
  - Two more are named:
    - f3 review should-fix 3: C-2's read also skips a job with nothing to withdraw, so that `userWaiters` and `ensures` keep today's cost. The per-stage measurement shows it.
    - f2 review should-fix 4: the "why no scenario is lost" record carries the correction (F S7).
  - f3 review should-fix 7 is ruled by N8.
- **N3. Clause (b).**
  - "Beyond clause (b)" is confirmed.
  - Clause (b) is **not** scoped to a job that holds a stamp. A scope check that no test can tell apart would be a branch whose drop-mutant survives (S3-R16 1(e)).
  - Instead, the draft records the code-reading argument (consistency should-fix 1). Clause (b) without clause (a) changes a re-lane only for a `.failed` job at its attempt's end whose verdict has not deferred:
    - `relane`'s `.failed` arm skips `metInItsAttempt` once `deferredAfter` is set (`EngineJobs.swift:327`);
    - an inbound move reaches only a job at its attempt's end (`continueInbound`'s doc, `EngineFollow.swift:1500-1520`; `waitingTarget`).

    So it changes nothing outside an ENOSPC end's read.
  - A verifier who finds a shape outside that read where clause (b) changes an answer reports it under 1(a).
- **N4. f1-B9's killer:** confirmed. The run decides, and the draft records the killing test in each order. If no test kills it 2/2, it is a survivor under 1(e).
- **N5. The order against f1.**
  - Decision 5's order stands: item 2 comes after the replay half.
  - f2 review "must add" 1's re-run is carried this way. A-T-SD's set-up check runs in every Sync bundle, so every later commit re-checks T20, item 1b's included. The draft's status list records A-T-SD green, in both orders, on the replay half's last commit and on item 1b's last commit.
  - A failure there is a T20 regression: fix the code, not the test.
- **N6. Option (i) inside C-2:** confirmed. e2-B′ is not authorised.
- **N7. The fifth in-letter shape is gated.**
  - It becomes the case `oneMemberGroupsFourPerID`: 40,000 one-member prefetch groups, four on each of 10,000 ids. It takes its 'before' figure from step 0, as item 3's other new cases do.
  - Item 3's new cases are named:
    - `keptUnderThreeGroups` and `fourGroupJoins`;
    - `mixedLaneGroups`, the mixed-lane shape;
    - `pendingClaimGroups`, the pending-claims shape;
    - `oneMemberGroupsFourPerID`.

    Five in all. Every count in the text that says "four" new cases becomes five.
- **N8. The stage trigger names the cases each stage can move** (f3 review should-fix 7).
  - Stages B and C change only the cost of retiring jobs from the job table (f3 §5).
  - So stage B runs only if a case that retires jobs in the purge's turn is above 8.5 ms after stage A. Stage C likewise runs only if one is above 8.5 ms after stage B.
  - A case above 8.5 ms that retires no job triggers neither stage. By f3's estimates these are `keptUnderThreeGroups` and `fourGroupJoins`. Item 3b routes them (N9).
  - The draft says, for each purge case, whether it retires jobs, from the case's set-up.
- **N9. f3 review "must add" 6 is answered: yes.**
  - Under S3-R16 items 2 and 3, the purge may skip `settleRemoval`'s re-lane of a kept `.queued` job whose lane the purge leaves unchanged. Today's `relane` re-enqueues every queued user job, even when its lane is unchanged (`EngineJobs.swift:311-314`), and that changes only the job's place and ticket.
  - This holds while item 1 holds:
    - a probe shows, in both orders, that the answers and every job's start count equal visit-first's;
    - the draft records the place difference under "Residual risks (S3-R16)".
  - The `.failed` arm's re-admission stays.
  - **Item 3b:** a route in one turn for the purge cases that route C does not reach is being analysed now (f3b, with its review). It covers `keptUnderThreeGroups`, `fourGroupJoins` and `oneMemberGroupsFourPerID`, plus `mixedLaneGroups` and `pendingClaimGroups` if option (i) leaves them above 8.5 ms.
    - The orchestrator appends it as "item 3b" between fixer runs, or between steps (N19).
    - Until it is appended, those cases are measured and reported, not routed.
    - So decision 3's "a miss after stage C is blocking, with no route in cycle 23" applies to a case after item 3b's route as well, once item 3b exists.
- **N10. 12.5.16** stands, as decision 3 says. Add one sentence: after C-4 removes the entry copy, 12.5.16's two conditions cannot hold, so a `.scope` miss after C-4 is WP-F's (blocking under 1(f)).
- **N11. "Red cases across the cycle":** confirmed, with "reported as a miss" defined.
  - A miss is reported when the draft's status list lists it with its figure, its loads, and the item that routes it, or "no route in cycle 23".
  - Each commit message names the cases that are red at that commit.
- **N12. The 'before' figures of S3-R27 items 3's and 4's cases** may be taken in step 0 or at the start of their steps (4 and 5). Either way they are taken on a scratch copy of `9aa337c` under `.build-s3f/c23/`.
- **N13. The mutant runs at step 6:** confirmed.
- **N14. The unreached lines become three.**
  - `EngineCommands.swift:1001` (`case .all: return true`) joins `:1004` and `:1009` in item 4. Each is reached by a test that kills, 2/2, its mutant that answers false (`return true` → `return false`), or it is removed with the reason recorded (S3-R16 1(e)).
  - Decision 4's "drop-mutant" is read that way for all three.
  - For `:1001`, the expected reach is f3 review must-fix 2's new `.all` test, with the groups' joins waiting swept first, through `withdrawPurgedJoins` (`EngineCommands.swift:1016`).
  - C-4 or C-3 may rewrite these arms. Then the rule applies at their new lines.
  - Item 7's row "correct #6 and #7 … → item 4" covers `:1001`.
- **N15.** No action.
- **N16. Red shapes with no route.**
  - A red step-0 shape that neither the replay half nor item 1b routes is blocking with no route in cycle 23. It is reported with its log; W-DB is the likely case.
  - Item 1b says, for each red shape, which route fixes it.
- **N17. Reqs #8 and #9.**
  - (a) Reqs #8, in step 6: add `.timeLimit(.minutes(1))` to `publishAllMatchesOnePublishPerEvent(seed:)` (`Tests/ZTronAssetSyncTests/Engine/SubscriberQueueBatchTests.swift:95`), as `SPEC.md:331` asks. It is a guard only, so G3 holds. Record it.
  - (b) Ownership (S3-R27 11.6; reqs #9; consistency should-fix 7).
    - Any new `Tests/ZTronAssetKitBenchmarks/BenchSync*.swift` file that cycle 23 adds is authorised as WP-F's, under 11.6's terms.
    - 11.6's first condition is amended to read: "Each file holds only `SyncBenchmarks` and `SyncBench` extensions and the helper types they use, declared in that file. No helper type's name collides with another work package's, and no file edits another work package's benchmark file."
    - Step 7's 11.6 record lists each file with its helper types.
- **N18. The 17 unapplied should-fix items** are applied as `s3-r28-changes.md` lists them, except where these rulings say otherwise:
  - C S1 is replaced by N3: the argument is recorded, and clause (b) is not scoped;
  - C S7 is ruled by N17 (b);
  - F S7 is made by N2.
- **N19. Appended items are picked up quickly.**
  - Item 6 adds: at the start of every step, the fixer re-reads the end of the rulings file for items appended since (item 1b, item 3b). It takes each one at the first step that starts after it is appended.
  - Item 5's order adds item 3b beside item 1b: its red cases first, then its route, and then every purge case's figures. Its natural place is after route C's stages.
  - The header's verifier rule (consistency should-fix 8) reads: item 1b and item 3b bind the cycle-23 verifiers for the work of every step that started after they were appended. The draft's status list records when each was taken.

## N20 (13:05): item 1's replay half is withdrawn; all of item 1 becomes item 1b

The f1b review (`f1b-join-rule-review.md`, verdict UNSOUND) changes decision 1. This ruling supersedes every part of N1 to N19, the 11:20 decisions and the draft that rules the replay half now.

- **Why.** f1b review must-fix 2 (W-JOIN-HOP, by code reading, UNCONFIRMED):
  - In the shape, a replay reaches J by a hop through a copy adopted since the end. Under clause (f), it would be dated as met, wherever the stamp is written.
  - At a transfer's end, `9aa337c` has no stamp, so the shape is green there today (`EngineJobs.swift:293-295`). The replay half as ruled would turn it red.
  - So the f1 review's "the replay half is sound" does not hold as stated. Its corrected form ("(f) for direct replays only; a hop dated by its chain") is a reviewer's proposal that no independent reader has checked (P4).
- **What changes in item 1:**
  - **Nothing in item 1 is ruled for the code now.** The fixer changes neither `metInItsAttempt`, `Job.transferSpaceEnd`, `AttemptEnd.stamped`, `relane`'s dating, nor the dating of any join or replay. Clause (b) is not ruled either.
  - **Correct #1 and #2 stay blocking** (S3-R16 1(a)) until item 1b routes them. The draft reports them with their logs.
  - **Item 1b becomes the whole of item 1's route:** the replay half (amended for hops, if that holds), the join rule, the close, the clears, the tests, the kills, C2 and the records. The orchestrator appends item 1b after three inputs:
    1. step 0's measured shape results (below);
    2. a re-analysis of f1b as its review corrects it (f1c), with its own review;
    3. the owner's answer, if one comes, on whether the dating of a join made in an ENOSPC end's read is timing (S3-R16 item 2).

    f1c is launched when step 0's shape results are committed. It is not launched if the owner has classed that dating as timing by then.
  - The draft's item 1 text keeps only what describes the findings and step 0's shapes. Its route, tests, kills, C2 and records move into one line: "item 1b".
- **Step 0's shapes, extended.** Run each one on `9aa337c`, in both orders, 2 rounds, and record it as red or green (measured), with its log:
  - **Drain timings.** Run every shape in both drain timings:
    - the drain released inside J's read, as the c22 probes do (`VerifyC22CorrectProbes.swift:320`, `:445`);
    - the "late drain", whose follow is released only after J's read returns, so that the drain runs after J's deferral (f1b review, line 8).
  - **The shapes:**
    - f1's T-F1a to T-F10 and W-PR;
    - the f1 review's W-HP and W-AWAY (each at both ends), W-DB, W-PD, T-F4 as its must-fix 5 corrects it, and T-F4's lazy twin;
    - f1b's new tests T-F2c, T-F8c, W-HP-d0, W-PD-back and T-B11, and its open shapes W-HP-late, AV-away, W-ONOFF and the multi-change lazy shape (f1b §7). Add the pending-move corners (i) to (iii) where they can be built; the review argues (iv) is unreachable;
    - the f1b review's W-PD-back2, W-JOIN-HOP (at both ends), W-JOIN-OFF, AV-off, K19's separating shape (its must-fix 8) and W-BACK-PUB.
  - **How:** build the shapes from the verifiers' helpers (`VerifyC22CorrectProbes.swift:255-342`, `:384-466`). Each asserts visit-first's answers and T's start count, and serves every content it requests (S3-R27 12.2's "Serving").
  - **A shape that cannot be built** after a real attempt is recorded with the attempt and the reason, as a residual risk (S3-R27 12.5.2), not as blocking.
  - **A VF answer that depends on timing.** For the multi-change lazy shape and W-BACK-PUB, record both VF answers and the timing that selects each. Their classification is item 1b's.
  - **Probes and commits.** The shapes are probes, kept under `.build-s3f/c23/`. A red shape is committed as a failing test only right before item 1b's fix for it.
  - **The results** go to the draft's cycle-23 status list as one table: shape × order × drain timing → red or green, with the log.
- **The order of work.** Step 1 becomes item 2 alone (f2-R1, then A-T-SD's change). Step 0's extended shapes may run after item 2's commits if that suits the fixer. N5's T20 check applies to item 1b's commits.
- **Everything else in N1 to N19 that concerns item 1** applies only once item 1b takes it up. That covers N1 (the clears), N3 (clause (b)), N4 (f1-B9) and N16 (red shapes with no route); it is item 1b's to adopt or change.
- **The mapping:** correct #1 and #2 → item 1, routed by item 1b.

## N21 (13:34): the owner's ruling, and f1c

- **The owner ruled at about 13:30 on 6 Nov: "Keep it blocking".** The question was whether a join's before/after dating inside an ENOSPC read should count as timing rather than as an answer.
  - So a join, request, removal or replay that meets a job during its ENOSPC end's free-space read gets visit-first's answer, including whether it counts as before or after the end.
  - A different answer is blocking (S3-R16 1(a)).
- **The orchestrator's reading, for VF's own timing.** Some shapes give answers in VF that depend on VF's internal timing rather than on the inputs and their order (the multi-change lazy shape and W-BACK-PUB, by f1b and its review). For those, SF matches when it gives one of VF's answers for the same inputs in the same order. The draft lists each such shape, with the timing that selects each answer. This is a reading of "visit-first's answer" where VF has more than one, not a narrowing of the bar.
- **f1c was launched at 13:33**, not after step 0, because the owner's answer removes the reason to wait. It is two analysts and a comparative review (`f1c-route-a.md`, `f1c-route-b.md`, `f1c-review.md`). Step 0's measured table still goes into item 1b: the orchestrator checks f1c's predictions against it before item 1b's route binds.
- **At the append,** S3-R28's text replaces "the owner's answer, if one comes" with this ruling, and N20's "f1c is launched when step 0's shape results are committed" with "f1c runs now (N21)".

## N22 (14:12): fail fast

The owner asked at about 14:05: "can we adopt a fail-fast policy? If the cycle is bound to fail let's not wait the 100h". S3-R28 gains **item 8, "Fail fast"**. It binds the fixer and the verifiers from cycle 23 on, wherever earlier rulings order the work otherwise.

1. **Measure first, riskiest first.** Step 0 measures on `9aa337c`, before any fix, in this order:
   - item 1's shapes;
   - item 3's five new cases' 'before' figures;
   - the rest.

   Commit each group's table as soon as the group is measured, so that the orchestrator can check it against the analyses while the fixer goes on.
2. **Stop conditions.** Check them at the end of every part and every measurement:
   - (a) a route's last part, or its last triggered stage, is in, and its case is still above 10 ms or its shape is still red;
   - (b) after a stage, a case is above 10 ms by more than the later stages' estimated savings (f3 §5), so they cannot close it;
   - (c) a measurement contradicts the analysis that a route rests on: a shape the analysis calls green is red on the route's base, or a figure is above its estimate's upper end;
   - (d) a fix needs a change that no ruling authorises;
   - (e) a part takes more than 1.5 times the upper end of its estimated fixer hours.
3. **On a stop:**
   - The fixer commits the evidence (the red test or the figures, red first).
   - Then it commits a status-list update whose subject starts `PUT-BACK: item <n>: ` and says what stopped, in one line.
   - It goes on only with work that does not depend on the stopped item, and it does not start the stages or parts that the stop makes useless. If no such work is left, it returns.
4. **The orchestrator:**
   - It watches `wp/s3f` for `PUT-BACK` commits and rules each one between steps. Item 6's re-read at each step picks the ruling up.
   - When a blocking item has no route that an independent review calls sound, it tells the owner at once, with the evidence and the options, instead of letting the cycle run on.
5. **Verification runs when it can pass.**
   - When the fixer returns with a blocking item known to be open (a stop, an item with no route, a known miss), the orchestrator does not run the two verifiers on that HEAD. It rules the item, then relaunches the fixer in the same cycle.
   - The two verifiers run when the fixer's status list shows every blocking item closed by its own measurements and gates. Item 6 sets the order of their checks.
6. **Early probing of a risky route.**
   - This applies to a class whose analyses an independent review has found unsound twice or more, as with the ENOSPC windows.
   - As soon as that class's route is committed (item 1b's), one independent correctness prober (P4) tries to break it with new shapes, in both orders and both drain timings, before the fixer moves on.
   - A red found then is a stop under 2(c).
7. **Re-forecast at every wake-up,** in hours and weekly %. When the routed work cannot finish before the weekly limit, take blocking items first, then kills, then records.

## N23 (14:22): the open items of the final text (`s3-r28-final.md`, 227 lines)

These rule the points that the final editor and the two checks (`s3-r28-final-review-fidelity.md` READY, `s3-r28-final-review-consistency.md` CORRECTED) left for the orchestrator.

1. **N21's replacements.** Apply them at the four places the fidelity review's O1 names (`s3-r28-final.md` :60, :71, :73 (both sentences) and :184), with O1's text. Add one line for N21's check: before item 1b's route binds, the orchestrator compares f1c's predicted reds and greens with step 0's measured table, and a contradiction is a stop under item 8's 2(c).
2. **Start-count-only differences (consistency M1):** confirmed. A step-0 shape that differs only in the failed job's start count, with visit-first's answers, is recorded and does not block (S3-R27 12.2 and 12.5.1; S3-R26 item 7).
3. **The e1-PS, e1-P1 and e1-P2 kills (consistency M2):** confirmed as applied. They run at step 6 on the code as it stands. They are rewritten for item 1b only if item 1b has been appended, and has rewritten their code, by then.
4. **Step 0's list is completed** (fidelity O2, consistency FO2). Add:
   - f1b §2's W-HP-d, W-DB-off, and W-BACK at both ends;
   - W-JOIN-HOP's owed-re-route and take-off variants (f1b review :53-54);
   - f1's windows 8 to 10, if f1 names them.

   Update every count of the shapes to match the list.
5. **The reference in step 0 is the measured VF run** (fidelity O4). A shape's visit-first answer is the one the `.followVisitedFirst` run gives, not the analyses' prediction. SF is red when its answer is none of VF's answers (N21's reading). Where the VF run misses an analysis's prediction, record it for f1c; it does not block.
6. **Drain timings (the amend editor's reading):** confirmed. Only the swept-first runs have two drain timings. Visited first, the follow ends inside the apply (`EngineFollowBarrierReachTests.swift:25-27`). Pending-move corner (iii) is classed with the timing-dependent shapes (f1b "must say" 12), beside the multi-change lazy shape and W-BACK-PUB.
7. **Stage C's trigger (consistency FO5).** Stage C also runs when, after stage B, a case that retires no job is above 8.5 ms by no more than 3.5 ms, since stage C's drop of the key sort (`EngineCommands.swift:1019`; 2-3.5 ms, estimate) may close it.
8. **N9's measuring point (consistency FO6) is after stage A,** where option (i) lands. After stage A, a case above 8.5 ms goes one of two ways:
   - if stages B or C can move it (N8, as point 7 refines it), it waits for them;
   - otherwise it is item 3b's.
9. **Item 3b's place (consistency FO7).** When item 3b is appended, it names:
   - its place in item 5's order;
   - the parts of route C it replaces or rewrites (f3b-route-a's A-1 rewrites C-3, and its A-3 replaces the sort at :1019);
   - what happens to any of them already committed.

   Until item 3b is appended, the fixer follows route C as ruled.
10. **Item 3 waits for item 3b's check (f3b's review, written from 14:11).**
    - The review says that option (i)'s C-2′ breaks R-SYN-3 for a kept claim-held job. It also says that N9's skip leaves `queuedAt` and `lastTicket` unchanged (`EngineJobs.swift:568`, `:570`) and drops a `notifyObservers`. These bear on N6 and N9.
    - So add to item 3: "Option (i) (C-2′) and N9's skipped re-lane are re-checked by item 3b, which may change them. If item 3b is not in the rulings file when step 2 would start, do steps 4 and 5 first, then step 2 once item 3b is appended."
    - Add to item 5's order that steps 4 and 5 may come before step 2 for that reason.
11. **`:1001`'s reach (consistency FO8).** Under `.all`, only `withdrawPurgedJoins` calls the predicate, because the jobs take the fast path (`EngineCommands.swift:1016`, `:1022`). So `:1001` is reached swept first only. Its kill is 2/2 in the order that reaches it, as S3-R27 item 6 ruled for the epoch clause. The record says that visited first cannot reach it, and why.
12. **f3b-route-a §9's three ungated in-letter shapes** (consistency FO9; one about 0.5 s, derived) are item 3b's. S3-R28 names them only as "item 3b gates or routes them".
13. **Item 8, "Fail fast", is N22,** written into the text after item 7 as its own item, in S3-R27's style. Update the header's item count, and the cross-references in items 5 and 6 (step 0's order, item 6's re-read, and the PUT-BACK commits).

## N24 (14:26): item 3b from f3b's review, and f3c

- **The go/no-go for item 3b is "go".** f3b's review (`f3b-review.md`) chose the merged route, with both routes CORRECTED. By estimate it closes all five of item 3's new cases. Item 3b is that merged route.
  - Its "What the ruling must say" points 1 to 12 bind as written. They amend N6, N9 (restated in its point 6) and N19 (item 3b's place, inside route C's stages, in its point 1).
  - Option (i)'s narrowing of C-2 (b) applies only where C-2 retires the job in the same step. A claim-held job whose lane falls takes today's pre-relane, since skipping it breaks R-SYN-3 (its point 7).
- **The open in-letter shapes** (its point 10) are gated and measured first:
  - failed user jobs with `.retry` deadlines under prefetch groups (about 500 ms if the origin admits users, derived from `s3f.md:7584` and `:7617`);
  - a bulk waiter under three prefetch groups (9-17 ms, estimate);
  - prefetch and bulk groups under a third group's pending claim (10-20 ms, estimate);
  - the three variants its point 10 names.

  Their 'before' figures come in step 0, right after item 1's shapes (item 8's "riskiest first").
- **f3c analyses a route for those shapes now:** A-6 with an in-place re-admission, and an in-place re-queue (f3b review "hours": 3.5-5.5 h and 2-3 h, estimates). It has its own review, and is appended as item 3c if the review finds it sound.
  - Until item 3c is appended, a measured miss among those shapes is a stop under item 8 2(c). The orchestrator reports it to the owner with the evidence and the options.
- **Item 3b's hours:** the core is 17-26.5 h (estimate), on top of route C's 19-28 h.

## N25 (14:37): the owner's ruling, three purge shapes become known misses

- **The owner's words** (the message after 14:27): "we need to end this package as soon as possible. Let's make it so: leave these three cases out of cycle 23 and record them as known misses of the 10 ms limit. But, in a few months, we might re-open this package, depending on how frequently the misses are. So you keep all your analysis results and persist what's needed for a later resume".
- **The three cases** are the first three rows of `f3b-review.md` §7:
  1. failed user jobs with `.retry` deadlines, under one to three prefetch groups (about 500 ms if the origin admits a user request; 9-18 ms otherwise; derived);
  2. a bulk waiter under three prefetch groups (9-17 ms, estimate);
  3. a prefetch group and a bulk group under a third group's pending claim (10-20 ms, estimate).
- **What it changes for cycle 23:**
  - The three cases are out of cycle 23. They are known misses of C2's 10 ms limit, and are not blocking (an owner ruling, for these three cases only). S3-R27 12.1's bar still holds for every other shape.
  - N24's gating of them, their step-0 'before' figures and its stop rule under item 8 2(c) are withdrawn, and there is no item 3c. f3c finishes, but only for a later re-open. It is kept, not appended.
  - No code, test or bench is added for them in cycle 23.
  - The variants in rows 4 and 5 of §7 stay as N24 rules them: they are measured as variants of item 3b's cases. A miss among them is still a stop under item 8 2(c), reported to the owner.
  - Item 3b says all this in place of its open-shapes part.
- **The record:**
  - The fixer records the three cases in the draft (`docs/adr-drafts/s3f.md`), under "Known misses of C2's 10 ms limit (owner ruling 2026-11-06)", for ADR-057 and for Stage 5's `RESIDUAL-RISKS.md` and `VERIFICATION.md`.
  - For each case, the record gives:
    - the shape;
    - its figure, labelled "derived" or "estimate", with the derivation and its citations;
    - what would close it (`f3b-review.md` §7, and f3c with its review);
    - the owner's re-open criterion: how often the miss happens in the field.
- **The verifiers** do not report the three cases as blocking. Any other C2 shape they find is reported under the bar as usual. A miss with no route is a fail-fast stop for the owner (item 8).
- **Persistence:**
  - Nothing under `.build-orchestrator/` is deleted, now or at the package's close. The folder matches `.gitignore`'s `.build*` and CLAUDE.md's `rm -rf` allowance, so a clean-up could remove it.
  - So the orchestrator snapshots it into the local branch `archive/build-orchestrator`, now and at the close, and writes a re-open dossier, tracked on `feature/asset-kit`.
  - The post-convergence clean-up removes the s3 worktrees only after their branches are pushed or archived, and never removes `.build-orchestrator/`.
- **Pushed (14:46, the owner's "Yes, push it"):** `archive/build-orchestrator` is on `origin` at `765102c`. Later snapshots need the owner's word before they are pushed.

## N26 (15:21): the append text's open items (`s3-r28-append.md`, from `wf_59564fea-9b2`)

The append review (`s3-r28-append-review.md`, CORRECTED) and its editor left O1 to O6. The orchestrator rules them, and applied each one to `s3-r28-append.md`; the copy from before these edits is `s3-r28-append-pre-n26.md`.
- **O1, item 8's stop conditions.** The review's proposed texts are taken:
  - (a) is "still red in a way that blocks", so a start-count-only red is not a stop (N23 point 2);
  - (b) reads the upper end of what the later stages and parts save on that case (f3 §3.2, and item 3b's estimates), so a stop means even the best estimate cannot close it. That is item 8's "cannot";
  - (c) for a step-0 'before' figure, the fixer commits the table and goes on, and the orchestrator's check decides whether it is a stop. The orchestrator rules a stop found by its check or by the early prober, and says what the fixer commits;
  - (e) covers a part, stage or step that items 2, 3, 3b or 6 estimate, and the status list times each one;
  - a figure above 10 ms seen only at a load above 10 stops nothing until rulings :763 decides it.
- **O2, the lines N24 and N25 left stale:**
  - item 3b names "C-3, and the sort at `:1019`";
  - item 3b says what cycle 23 does with route A §9's three shapes. Two of them are N25's known misses, and M-4 routes the third;
  - "a known miss" in item 8's point 5 becomes "a blocking miss".

  N25 itself goes into item 3 as its own bullet, so the verifiers read it in the rulings file before item 3b is appended.
- **O3:** the header says "An appended item decides where it differs from items 1 to 8". A later ruling wins, as everywhere.
- **O4:** N12's option is struck. S3-R27 items 3's and 4's 'before' figures are taken in step 0, as "the rest" (N22 point 1). The owner's "end this package as soon as possible" favours surfacing an unroutable miss early.
- **O5:** the lenient reading. While item 8's early prober runs, the fixer goes on only as point 3 allows after a stop. So no work that depends on item 1b's route goes on, and the fixer is not idle. The run may end when item 8 leaves it no work.
- **O6:** each visit-first answer is recorded with its inputs' order. Swept first matches only an answer for the same inputs in the same order, so the timing class cannot accept the other order's answer. "Keep it blocking" is not narrowed.
- **The editor's gap:** step 0's hours gain about 2-8 h for W-JOIN-HOP's variants (N23 point 4), so 13-26 h in all (derived). Item 3b's 17-26.5 h is added to item 6's list.
- **The time:** item 8 drops "at about 14:05", because the sources disagree on when the owner asked (N22 says about 14:05, ORCHESTRATION.md about 14:00).

## N27 (15:28): f1c's review, a no-go until the owner rules

- **f1c returned at 15:26** (`wf_8dc737d5-cbc`). The review (`f1c-review.md`) finds route A (`f1c-route-a.md`) and route B (`f1c-route-b.md`) both UNSOUND. It proposes a merged route Q (its §3), with 12 ruling points.
- **Q is not a route that an independent review calls sound:**
  - Q is the reviewer's own merge, and its point 9 says it binds only after an independent check (P4) by an agent that wrote none of A, B or the review. That check costs about 3-5 h (estimate).
  - Every red or green in the review is by code reading and UNCONFIRMED.
  - Q leaves four shapes open that block with no route if they are red (its point 11): W-OBO, W-PEND-LATE's tail, W-SUPER (new, not traced) and the holder-state approximation.
  - Q's hours are 44-67 h, step 0's 8-12 h included, plus the check (estimates).
- **The class's record:** f1 was UNSOUND, f1b UNSOUND, and f1c's A and B both UNSOUND. That is item 8's point 6 class.
- **Item 8's point 4 applies:** a blocking item (correct #1 and #2) has no route that an independent review calls sound. So the orchestrator tells the owner at once, with the evidence and the options:
  - (1) record correct #1 and #2 as known residual correctness risks, and drop item 1 and item 1b;
  - (2) run Q's independent check first, then rule item 1b on its result.

  Item 1b is not appended until the owner rules.
- **Meanwhile:** run 10's fixer is in step 0 (`verify.sh --quick`, then item 1's step-0 shapes). Its shapes are useful either way, as Q's measured reference or as the residual risk's evidence. So the run is not stopped. If the owner chooses (1), the orchestrator stops the run and relaunches it without item 1's work.

## N28 (15:33): the owner's ruling, the ENOSPC windows become known residual correctness risks

- **The owner's words** (after N27's report at 15:28): "Agreed let's document it as known risk". This answered the option "record correct #1 and #2 as known correctness risks, the same way as the three 10 ms misses".
- **Carried out as S3-R28 item 1c** (`s3-r28-item1c.md`, appended to the rulings file):
  - item 1's step-0 shapes and item 1b are withdrawn, and Q is not ruled;
  - correct #1 and #2, and any answer in the class "the ENOSPC windows", are known residual correctness risks, not blocking;
  - S3-R16 1(b) to 1(d) inside the window still block;
  - no code, test or early probe is added for them;
  - the fixer records them in the draft under "Known residual correctness risks (owner ruling 2026-11-06)".
- **Run 10 was stopped at 15:32** (`wf_bf008c3c-24c`). It was 10 minutes into step 0's `verify.sh --quick`, with no commit and a clean worktree. Run 11 relaunches cycle 23 with item 2 first, then a re-read, because the owner's decision on the remaining C2 work is still pending.
- **Records:** `docs/REOPEN-WP-F.md` lists the known risks next to N25's known misses. The archive branch gets them at the final snapshot.

## N29 (15:55): item 1c's independent check, and N28's scope corrected

- **The check** (`s3-r28-item1c-review.md`, `wf_76e8f9f2-6c4`, CORRECTED) found 7 must-fix items. The orchestrator accepts all 7 and appended them at 15:55 as "S3-R28 item 1c, amended" (rulings file line 1618; `s3-r28-item1c-amend.md`).
- **N28's scope is corrected:**
  - The owner ruled on correct #1 and #2: "record correct #1 and #2 as known correctness risks, the same way as the three 10 ms misses". N25 carried those three "for these three cases only".
  - N28's "and any answer in the class" went beyond that, so only correct #1 and #2 are exempt, defined by their deciding line.
  - Any other ENOSPC-window answer difference is blocking under S3-R16 1(a), with N21's reading, and goes to the owner at once (item 8's point 4).
- **The owner is asked in one line** whether every such difference that a verifier finds should also be a known risk. If the owner says yes, the class is defined by T20, as the check proposes: "an answer that differs only because T20 (EngineJobs.swift:360-364) re-queues a job failed at an ENOSPC end in one order and not the other, before that job's space verdict, given at once or at the follow's end after spaceFailed's deferral (EngineFailures.swift:573-582)". That definition covers both causes and the late drain.
- **Corrected in the record:**
  - S3-R16 1(e) and 1(f) still block, including the e1-PS, e1-P1 and e1-P2 kills.
  - The user-visible effect: in correct #1 the request was made before the end and replayed in the read. The probes cap retries at 1 and script the second attempt to succeed.
  - The archive's copy predated S3-R28 and f1c's review. Snapshot 2 follows now, locally.
- **Run 11's order** is now `verify.sh --quick` on HEAD, then the record amended on its own commit, then the re-read for the C2 ruling, then step 2.
- **The orchestrator's own report to the owner at 15:28 was also imprecise** on correct #1 ("arrives while the engine is checking free space"). The owner is told the corrected effect.

## N30 (16:15): run 12's order, while the owner's C2 ruling is pending

- **Run 11** (`wf_e1cbc5ed-f72`) returned at 16:12 at its working budget, with context 85 % full at 15:57.
  - It made 5 commits, to `247e85b`: step 1 (item 2) test-only; the known-miss and known-risk records, amended to N29; and `verify.sh --quick` PASS on HEAD and on `9aa337c`.
  - The workflow then started both verifiers. The orchestrator stopped it at 16:13 (item 8's point 5: a HEAD with known-open blocking items is not verified). No lock or process was left, the simulators were shut down, and the worktree was clean.
- **Run 12's order** (appended as "S3-R28, order for run 12"):
  - first, S3-R27 step 7's work outside the purge code: the e1 kills, the d4 survivors with the default-tuning probe, and reqs #8's guard;
  - then the records that no C2 route changes;
  - then the C2 work, as the owner rules, or, without a ruling, as item 1c's amended point 5.3 says.

  The three unreached purge lines wait for the C2 ruling.
- **The fixer reads narrowly** (S3-R28 and the draft's cycle-23 section), because run 11 spent most of its context on reading.

## N31 (16:47): the owner's close ruling, option (e)

- **The owner's answers** (about 16:40, to the orchestrator's question form after the options at 16:33):
  - to "Which way do you want to end WP-F?": "(e) Short close". Its description: "Merge what's on wp/s3f, add the long-purge log line, and run one short independent verification." The message with it said: "Under (e), I'd record any new finding from the verification rather than fix it. Anything that breaks a MUST or hangs would come to you first."
  - to the red purge benchmarks: "Accept the FAIL" ("The tests stay as written and red, and the misses are reported with their figures. G3 stays intact").
  - to the ENOSPC class: "Yes, the whole class" ("A different answer between the two visit orders, caused by an event inside the disk-full window, is recorded, not fixed. Broken MUSTs, hangs and flaky tests there still block"). N29's T20 definition applies.
  - to pushes: "Archive and feature branch", which means pushing `archive/build-orchestrator` snapshots and `feature/asset-kit` as they change, never `main` and never force.
- **Run 12 was stopped at 16:41** (`wf_ee08701d-249`) at `9e9a500`, after 7 commits from `247e85b`: reqs #8's guard, an e1-P1 kill and five d4-survivor kill tests. Its worktree was clean. No process, lock or booted simulator of set 1 was left. Watcher `bz02zu459` was stopped too.
- **The close ruling** is drafted as `s3-r28-close-e.md` ("S3-R28, the owner's close ruling"). Two independent checks of it run before it is appended (`wf_1c475778-94c`): fidelity to the owner's answers, and consistency as the fixer and verifiers will read it. Run 13 starts after the append.
- **Persistence:** snapshot 3 of the archive is made now and pushed, with `feature/asset-kit`.

## N32 (17:12): the close ruling's two checks, and its append

- **The checks** (`wf_1c475778-94c`, 16:45-17:08) both returned CORRECTED: fidelity (3 must-fix, 14 should-fix; `s3-r28-close-e-review-fidelity.md`) and consistency (10 must-fix, 10 should-fix; `s3-r28-close-e-review-consistency.md`). They read the orchestrator rulings before N31 was appended at 16:47.
- **Applied:** every must-fix item and every should-fix item, with these choices where the two differ:
  - a flaky test goes to the owner when it is inside the ENOSPC window (the owner's "there"), not "inside or after" it;
  - the class is the owner's words, with T20 as the test, and a late-drain difference is in it only when its cause is inside the window (fidelity); the consistency check's "the late drain is in by N29's definition" is not taken;
  - a defect in S1 found by the verification is reverted, not fixed (fidelity), because the owner chose "record rather than fix" and a fix would go unchecked;
  - run 13 makes the mutant runs for run 12's five kill tests (consistency must-fix 8), so that the verifiers re-run evidence instead of making it.
- **Appended at 17:12** as "S3-R28, the owner's close ruling" (`s3-r28-close-e-appended.md`; the first draft is `s3-r28-close-e-v1.md`; the rulings file before is `.before-close-e`). The revised text was not checked a third time. It is mostly the checks' own replacement texts, and run 13's verifiers read it.
- **Taken to the owner with the close:** f3c's two open shapes, which the options did not show; they are recorded as open and not as known misses. Before Stage 5's `--full`, the owner is also asked about the uncommitted `Package.swift`.

## N33 (22:04): the cycle-23 verification, sorted under the close ruling's point 8

- **Run 13's verifiers** (`wf_c02a97cf-a3e`, 20:12-22:00) closed both lenses on `d88bdb1` with 0 blocking findings and 9 non-blocking ones. correct #3 is closed by `03c4e59`: three host Sync runs, the full simulator suite and 30 simulator iterations of A-T-SD were all green. reqs #7 is closed by the heavy checks. The benchmarks show exactly the 7 expected issues: the six and P-13.
- **Nothing goes to the owner.** No finding is a broken MUST, a hang, a flaky test inside an ENOSPC window, or a new cause of the FAIL.
  - #7, the probe that hung, is in the test harness: `isIdleSilent` ignores an `applyAndFollow` in the caller's own task, and one clock advance ends it. It is not an engine hang.
  - #4: mutant `s1-late-start` survives against S1's test, because the ruling's test design advances the clock only at the `?(true)` mark. S1's code is right; the verifier confirmed it matches point 5 exactly. So this is not "a defect in S1" (no revert). It is a survivor, recorded as open under "anything else", with the re-open route the verifier gives: a mark inside the walk. `s1-groups-after` is equivalent.
- **Record corrections** (point 8, this ruling's own work; not independently verified):
  - #1, a stale citation;
  - #2 and #6, the mutant issue counts as ranges;
  - #3, three more cases on the margin list above 8.5 ms (the verifier's figures);
  - #5, `p2-after-verdict-true` killed 2/2 swept first by the verifier.
- **Recorded as they are:** #4 and #7 as open, with re-open notes; #8 (correct #1 and #2 still reproduce, known risks) and #9 (the accepted FAIL's figures).
- **Run 14** is a records-only agent that applies these to the draft. Then come the merge and point 10.
