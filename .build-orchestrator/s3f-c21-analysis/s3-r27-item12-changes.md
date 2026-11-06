# S3-R27 item 12 draft: changes from the two reviews

- Before: `s3-r27-item12-draft-v1.md` (the draft as reviewed, copied unchanged before any edit).
- After: `s3-r27-item12-draft.md` (233 lines; line numbers below are the new file's).
- Reviews:
  - `s3-r27-item12-review-fidelity.md` (F: must-fix 1-2, should-fix 1-11, For the orchestrator 1-11);
  - `s3-r27-item12-review-consistency.md` (C: must-fix 1-5, should-fix 1-13, For the orchestrator 1-5).
- Counts:
  - must-fix: 7 items, which make 6 distinct points (F M2 and C M3 are one). All 7 are applied. None would change an orchestrator decision. C M2 is applied and is also put to the orchestrator for confirmation (For the orchestrator 15), because F reads the same point as a question for a ruling (F, For the orchestrator 4);
  - should-fix: 24 items. 16 are applied in full, 4 in part, and 4 are not applied: F S10, which C M1 supersedes, and C S1, S8 and S11, which are decision-level and are listed for the orchestrator.
- Method: reading only. Before editing, I checked the facts each applied item rests on against `.worktrees/s3f` at `d5b2ab9` (clean), the rulings file, `integrate-rr21.md`, the worktree's `docs/adr-drafts/s3f.md`, `SPEC.md` and `s3f-c21-issues.json` (list at the end). Nothing was built, run or measured.

## Must-fix

| Review, id | Where | Applied? | What changed, and why |
|---|---|---|---|
| F M1 | 12.3, e2-A1.4's test (line 121) | Yes | The test now reads "a claim-held job whose `.bulk` interest is registered before its `.prefetch` interest (t1 < t2, as e2 review must-fix 6 builds it) ends with `heldLane == .prefetch`". Checked: `settleRemoval` keeps `last` as `heldLane` (`EngineJobs.swift:394-396`); the lane is the highest interest's (`EngineState.swift:890-891`); `.bulk` = 0 < `.prefetch` = 1 (`AssetPriority.swift`); tokens ascend (`nextToken`, `EngineLifecycle.swift:86-88`). With `.prefetch` registered first, ascending removal ends at `.bulk`, so the test as drafted would be red on the fix. This is still add 2's test (D3), with its construction made exact. No decision changes |
| F M2 | 12.4, step 1 (line 163) | Yes, merged with C M3 | "takes 12.2, all of it" became "takes these parts of 12.2, all of them before item 6's … removal in step 2 (e1-R1's kills are in step 7; 12.2's records, and item 9's re-measures, are in step 8)". D4 itself puts R1's kills in step 7 and the records in step 8, so "all of it" contradicted 12.4's steps 7 and 8. I took F's scope ("R1's kills") and not C's ("12.2's kills"): C's wording would also put the probe fixes' kills in step 7, which D4 does not, so that point goes to the orchestrator (item 14). C's "item 9's re-measures" is kept: item 9 runs in item 10's step 8 (rulings :1013) |
| C M1 | Header: a new "Names" bullet (line 3), and every e1 and e2 label in 12.2 to 12.4 | Yes | Checked, the collisions are real: R1 is S3-R11's (rulings :152), `integrate-rr21.md`'s (:422) and item 3's (:872); A1 and A2 are item 3's (:832, :838), item 4's (:928, :1011) and `integrate-c21.md`'s (:423); P-1 to P-3 are SPEC's benchmarks (`SPEC.md:296-298`), beside P-13. The bullet follows S3-R26's Names rule ("in this item and in the draft's records"), with C's text. Its last sentence ("Unprefixed R1, An and P-n keep their earlier meanings") would make any unprefixed label inside item 12 mean the old thing. So every e1 and e2 label is prefixed throughout 12.2 to 12.4, not only in 12.4: e1-R1; e1-PS, e1-P1, e1-P2, e1-P3, e1-PR; e2-A1, e2-A1.n, e2-A2, e2-A2.n, e2-B. Item 3's labels (A3, A3′, A5, A7, M1) stay unprefixed, as the rule says. The labels are renamed and nothing they decide changes. The "For the orchestrator" section keeps the decisions' unprefixed labels, and says so in its first paragraph. F S10, a lighter names line, is superseded |
| C M2 | 12.2, the probes: e1-P3's bullet (line 70) and the paragraph after the probe list (line 73) | Yes, and also listed for the orchestrator (item 15) | D2's sentence "A different answer from visit-first's is blocking" is kept word for word. After it: "A probe is red when it breaks S3-R16 item 1 in an order that reaches it: a different answer, a broken MUST or invariant, or a hang (S3-R26 items 7 and 11). Its other observations, such as a request count or a job's state, are recorded with it." This is S3-R26's own rule (rulings :584, :642). e1-P3 now records X's state at the move and at the replay, with no `#require`, and runs on to the answers. A `.blocked` state with visit-first's answers is recorded as the move's own finding (e1 §3, :212-216). F S4's construction from e1 §3 is merged into the same bullet. Why it is applied: D2 does not define "red", and its explicit blocking sentence is about answers. With the `#require`, e1-P3 could be red with visit-first's answers and then be reported as blocking with no route, against S3-R16 item 1. Why it is also listed: F (For the orchestrator 4) reads D2's "A red probe with no route … is reported as blocking" as the decision, so the orchestrator should confirm the definition |
| C M3 | 12.4, step 1 (line 163) | Yes | One point with F M2; applied there |
| C M4 | 12.2, Amendments, D6 (line 80) | Yes | Added "D6's first sentence reads as S3-R26 item 1's, amended above." Checked: D6 is three sentences (`integrate-rr21.md:316-318`), and its first, "A pin holds only while waitingTarget(transfer, epoch) holds", is the same sentence the draft amends in S3-R26 item 1 (rulings :441). The draft's "lose the ENOENT re-queue" amends only the second sentence (:317) and the residual (:597). D2 amends D6 as a whole, so this carries D2 |
| C M5 | 12.3, after "For each case" (line 114); 12.4, step 4 (line 170) | Yes | Added: "`purgeWhileOwedTurns` is already in the tree, so it is not committed again. Its cycle-21 figures (the table) and its step-0 figure are its 'before' figures. Its cycle-21 miss stands, and the decision rule below judges it after e2-A1 and after e2-A2." Step 4's first bullet now reads "the cases not yet in the tree, committed red where they miss", so that it does not contradict 12.3. Checked: the case exists (`BenchSyncReroutes.swift:68-74`), and the table already says so. Item 10's red-first rule commits a case that a step adds (rulings :992-994), so "committed red" cannot apply to it. I wrote "its cycle-21 miss" where C has "its `d5b2ab9` figures": I did not verify which HEAD the fixer's second gate run used. "Judges it after e2-A1 and after e2-A2" replaces C's "until A1 or A2 closes it", because "closes" is the decision rule's word for "at or below 8.5 ms". Covers F S6 |

## Should-fix

| Review, id | Status | Where, or why not |
|---|---|---|
| F S1 | Applied | Line 9: "It includes item 4's list". Item 4 says "That includes" (rulings :888), and the rule is "more than 4 interests on one id" |
| F S2 | Applied, merged with C S3 | Line 78: the first bullet's "rr21-T8 and rr21-T8b pin it" reads "rr21-T8 pins it" (the commit pin, `integrate-rr21.md:403-406`, checked). rr21-T8b's new role is already in the bullet ("the pair rides X's fresh attempt (T-E1, rr21-T8b)") |
| F S3 | In part | Answer 8: applied, merged with C S2 (line 81: every other rr21-T8b in answer 8, the "Reached" evidence of its second and third bullets included, reads "T-E2, with those tests"). D2 amends answer 8 at :713-716, all three bullets. Not applied: adding `s3f.md:5072` to 12.2's records. That extends D2's records list. It is noted under the drafter's For the orchestrator 3, with reqs #10's finding that Shape A no longer kills the fold since `58b278e` |
| F S4 | Applied | Line 70, merged into C M2's e1-P3 text: "Shape A and rr21-T8b, with a conditions edge or a space sweep replayed between the re-queue and the move or the replay" and the move's own finding (`e1-pin-requeue.md:213-216`) |
| F S5 | Applied | Line 104: "at a 1-minute load of 4.88 (mean 5.23 over SyncBenchmarks; a miss)". Checked at `s3f.md:6668-6670` |
| F S6 | Applied | Through C M5 |
| F S7 | Applied, merged with C S12 | Line 125: the rule now covers "every in-place access … e2-A1.2's owed batch, `.join` events and buckets, e2-A1.4's method and e2-A2.4's walk among them". Checked: both arms call `isPurged` (`EngineCommands.swift:1060`, `:1066`), which reads `self.state.applied` (`:994`). D3 says "every single-access step" |
| F S8 | Applied | Line 127: "Two things change: the order of the dropped ids and of the removed items, and, with e2-A1.4's one `settleRemoval` per job, the number of `notifyObservers` calls inside the turn". The ensure argument now cites e2-A1.3 and e2 review's "What holds". Checked: `settleRemoval` ends with `notifyObservers()` (`EngineJobs.swift:406`), and e2 §3's "Equality with today" names the change (e2:211). This corrects a factual "only"; it adds no audit (see For the orchestrator 4) |
| F S9 | Applied, with C S13 | Line 165: "each T-E test not committed red in the previous commit". C's "with the T-E tests that step 0 found green" is not used, because T-E2 is not run in step 0 and would fall out of both commits |
| F S10 | Not applied as written | Superseded by C M1's Names bullet |
| F S11 | Applied | `EngineRaceTests.swift:82-122` (line 56; checked: `:123` closes the struct); "(rulings :441)" (line 79); `s3f.md:6563-6566` (line 87; checked: the kill sentence ends at `:6566`); `docs/ARCHITECTURE.md` (lines 92 and 158) |
| C S1 | Not applied; for the orchestrator (item 18) | Whether the missing cases go into one red commit, and whether they may stay red across e2-A1's and e2-A2's part commits, both turn on S3-R26 item 11's "Only that commit may be red", which D3 does not settle. The keying on step 4's starting HEAD is item 10's own third rule, which D3 already invokes ("under item 10's red-first rules"), so it is not restated |
| C S2 | Applied | Merged with F S3 |
| C S3 | Applied | Merged with F S2 |
| C S4 | Applied | Line 29: the change lands "in e1-R1's commit, where the value's type changes" and is authorised "as an exception to S3-R26 item 1's 'Answer, MUST and invariant assertions never change' (rulings :462)". Line 165 lists it in step 1's e1-R1 commit. The test writes raw `UInt64`s, so it cannot compile past the type change in a later commit. The drafter's For the orchestrator 6 is annotated |
| C S5 | In part | Applied: line 174, "Item 9's check covers 12.2's and 12.3's lines" (whose lines). Not applied: inventory rows for e2-A2.2, e2-A2.3 and e2-A2.5. Item 9's inventory covers "items 1 to 4" (rulings :986), and no decision extends it, so this is For the orchestrator 24 |
| C S6 | Applied | Line 168: any other citation of this ruling that a change in this item moves is found by its content, with the `relane` guard example (item 1's c6 site and 12.3's `EngineJobs.swift` lines). It is a reading rule only |
| C S7 | In part | Applied: line 64, "If they do not kill it 2/2 in each order that reaches it, a PIN-END test that does is added". This states D2's "killed" concretely. Not applied: a step for the probe fixes' kills, which D4's step 7 does not list (For the orchestrator 14) |
| C S8 | Not applied; for the orchestrator (items 25 and 9) | A step for 12.1's records (and the stale doc at `BenchSyncCycle21.swift:156-158`, checked) extends D4. "Recorded only if measured (11.2)" for row 14, and re-pointing "(item 2)", change D1's and D3's words |
| C S9 | In part | Applied: line 106, the retry case's jobs are "each one that the purge removes (held only by interests it withdraws)". The case's own estimate (`removeJob`'s heap scan) presupposes that. Not applied: which ids the `.scope` selects (For the orchestrator 16) and "or ensures" (17). Both change D3's case list |
| C S10 | Applied | Line 156: "e2 review must-fix 1 to 5, 11 and 12 are about e2-B. They are recorded for that re-specification, and bind the cycle-22 fixer only where 12.3 carries them." Checked: all seven are about B. The part of must-fix 4 that gates two shapes, and the part of must-fix 5 that makes a miss with no route blocking, are carried by 12.3's cases and decision rule, hence "only where 12.3 carries them" |
| C S11 | Not applied; for the orchestrator (item 26) | It adds a record duty, `EngineCommands.swift:1053` (checked: "in (id, token) order, as `withdrawPurged` drops them"), that D3's records list does not have |
| C S12 | Applied | Merged with F S7 |
| C S13 | Applied | As F S9's wording |

## For the orchestrator: what was added

- The section is kept. The drafter's items 1 to 11 are unchanged, except for one-line annotations: C agrees with 2, 5, 7 and 11; 3 carries F S3's `:5072` point; 4 carries F's and C's audit points; 6 is now addressed in the text; 9 carries C S8's row-14 point.
- New items 12 to 26 are the reviews' decision-level items, merged where both raise one point:
  - 12: F 1, the flag-form mutant anchors and filters;
  - 13: F 2 and C 1, T-E2 not run in step 0;
  - 14: F 3 and C S7, the probe fixes' kills;
  - 15: F 4 and C M2, what makes a probe red (applied; confirm);
  - 16: F 6 and C S9, which ids the `.scope` case selects;
  - 17: F 7 and C S9, "or ensures";
  - 18: F 8 and C S1, red purge cases across part commits;
  - 19 to 21: F 9 to 11 (regression controls, B17, answer 6.3's header predicate);
  - 22: C 3 (`.scope` copy case against S3-R8);
  - 23: C 5 (a probe that cannot be built);
  - 24: C S5 (item 9's inventory for 12.3);
  - 25: C S8 (12.1's records);
  - 26: C S11 (the doc at `EngineCommands.swift:1053`).
- F 5 and C 2 are merged into the drafter's item 4. C 4 is recorded as agreement under the drafter's items 2, 5, 7 and 11.

## Facts checked for the applied items

At `d5b2ab9`, `.worktrees/s3f` (clean):
- `EngineJobs.swift:383-407` (`dropInterest`'s settle; `settleRemoval`, `heldLane = last`, `notifyObservers()` at `:406`);
- `EngineState.swift:890-891`;
- `ZTronAssetModel/Policy/AssetPriority.swift` (bulk 0, prefetch 1);
- `EngineLifecycle.swift:86-88`;
- `EngineCommands.swift:990-1012`, `:1048-1112` (`:1053`'s doc; `:1060` and `:1066` call `isPurged`), `:2239-2250`;
- `EngineDispatch.swift:1128-1135`, `:1272-1284`;
- `Tests/ZTronAssetSyncTests/Engine/EngineRaceTests.swift:80-123`;
- `Tests/ZTronAssetKitBenchmarks/BenchSyncCycle21.swift:150-176`;
- `.build-s3f/c21/tools/mut-c4fix.py:1-30`.

Elsewhere:
- `docs/adr-drafts/s3f.md:5070-5074`, `:5819-5825`, `:6560-6567`, `:6664-6672` (in the worktree);
- `integrate-rr21.md:314-319`, `:401-407`, `:584-587`, `:595-598`, `:969-973`;
- `SPEC.md:294-299`, `:308`;
- the rulings file at :1-35, :144-185, :403-1047;
- `s3f-c21-issues.json`: correct #1, #2 and #5, and reqs #4, #6, #10, #12 and #13.
