# S3-R28 draft: changes from the two reviews

- **Before:** `s3-r28-draft-v1.md`, the draft as reviewed, copied unchanged before any edit (195 lines). The reviews' "draft:N" are its lines.
- **After:** `s3-r28-draft.md`, 233 lines. The ruling is lines 1-183, and "For the orchestrator" is lines 185-233. Line numbers below are the new file's.
- **Reviews:**
  - `s3-r28-review-fidelity.md` (F): CORRECTED; must-fix 1-2, should-fix 1-11, For the orchestrator 1-5;
  - `s3-r28-review-consistency.md` (C): CORRECTED; must-fix 1-3, should-fix 1-9, For the orchestrator 1-7.
- **Counts:**
  - must-fix: 5 items, 5 distinct points. All 5 are applied. None would change an orchestrator decision (H, 1 to 7), so none is listed instead. Two are also put to the orchestrator: C M1, where the text takes the review's option (i) and the editor places a clear (note 1), and C M2, which F reads as a point for a ruling (F FO3; note 11);
  - should-fix: 20 items. The task names the must-fix items only, so none is applied for its own sake. F S9 is made in full by C M1, and C S1's last sentence by F M2. F S11 is carried as a correction to note 12, outside the ruling. The other 17 are not applied; each is listed below with where it would go (note 18);
  - For the orchestrator: F FO1-5 and C FO1-7 are all carried, in the intro and notes 1, 2, 3, 5, 7, 8, 11, 14, 16 and 17 (map below).
- **Method:** reading only. The facts each applied item rests on were checked against `.worktrees/s3f` at `9aa337c` (read-only `git show`), the rulings file, f1, f2 and f3 with their reviews, the fixer's draft and `docs/ORCHESTRATION.md` (list at the end). Nothing was built, run or measured.

## Must-fix

| Review, id | Where | Applied? | What changed, and why |
|---|---|---|---|
| F M1 | item 3, "Must-fix 3's option (i)" (line 109) | Yes | "C-2′ retires a claim-held job whose (b) holds, with today's end state" became "C-2′ empties a claim-held job whose C-2 (b) holds. After C-2's step 1 (the drops, the heals and the run's `held`), it moves the interest storages out whole to the freeing list, resets the counts, sets `heldLane = last` and writes `claimHeld`. The job stays, held by its claim, in today's end state (`settleRemoval`'s `claimHeld` arm, `EngineJobs.swift:427-431`)". Checked: f3 review must-fix 3 (i) words C-2′ so. At `9aa337c` the claim keeps the job (`EngineJobs.swift:427-431`), and `purgeThatEmptiesAJobKeepsItsEarlierRelane(claimed: true)` asserts `held` and `heldLane == .bulk` (`EnginePurgeWithdrawalTests.swift:102-104`). No decision changes: decision 3 adopts route C as f3's review corrects it. |
| F M2 | item 1, the clause (b) bullet (line 45) | Yes | "A removal keeps today's count" became "A removal made in a visit (`inFollowVisit` or `visitingAfterVerdict`, with `bringingInbound` included) keeps today's count, and a replayed removal is dated by clause (f)". Checked: f1 review must-fix 6 ("A removal in a visit uses (d) or (e), and otherwise today's count"); `continueInbound` sets `inFollowVisit` with `bringingInbound` (`EngineFollow.swift:1524-1525`); on `9aa337c` a replayed removal reaches the stamp branch (`EngineJobs.swift:293`). It matches decision 1's "clause (f) for replays only", and it keeps T-F9's replayed withdrawal on the stamp, as line 51 says. It also makes C S1's last sentence. |
| C M1 | item 1, "The stamp's lifetime" (line 47) and "Kills" (lines 62-66) | Yes, with the review's option (i) | Three parts. (a) Lines 63-66: a clear whose drop no test can observe stays, as must-fix 4 asks, and is killed on an `invariantViolations()` clause that its drop breaks, with a test that exercises it (S3-R19 item 3). For the deferral's and the verdict's clears, the clause is the review's "a job whose verdict deferred, or was given, holds no stamp". The text says why such a clear is not Equivalent (S3-R19 item 2) and not removed (S3-R16 1(e)), and gives the argument that the deferral's clear is one. The draft's "or their path is shown unreachable and removed" is gone, since every clear's path is reachable. (b) Line 62: f1-B11's shape under the replay half, a second attempt that ends without an ENOSPC and then reads the first end's stale count in a visit (`:291`) or its stale stamp in a replay (`:293`). f1's own B11 test needs the first end's copy (f1:183), which is item 1b's. This also makes F S9. (c) Line 47: `decideSpaceFailure`'s clear comes first, before its early returns (`EngineFailures.swift:587-596`), so that every path through it ends the stamp. Option (i) is taken over (ii) because must-fix 4 binds under the header rule (decision H) and (ii) departs from it. It also matches `9aa337c`, where the stamp already ends at the deferral: `recordDeferredVerdict` writes a new `AttemptEnd` with no `stamped` (`EngineFollow.swift:564-565`; the field's doc, `:2017-2021`). Checked: `EngineJobs.swift:327`; `EngineFollow.swift:390-394` (only `chargeTakeOff` between the clear of `attemptEnd` and `decideSpaceFailure`); `decideSpaceFailure`'s two guards (`EngineFailures.swift:587-589`, `:592-596`); S3-R19 items 2 and 3 (rulings:242, :245-247). No decision changes: decision 1 does not rule the lifetime, and must-fix 4 stays whole. The choice of (i) and the placement go to the orchestrator (note 1). |
| C M2 | item 3's decision rule (line 131) and item 5 (line 165) | Yes | Draft:123 extended 12.5.12 only to the commits before route C's parts. Line 131 now points to one rule for the whole cycle, item 5's "Red cases across the cycle", which carries the review's sentence: "From `9aa337c` to the close, the Benchmarks stage may stay red for every case already committed red that is not yet closed, or that is reported as a miss, and each commit message names those cases. Every other stage is green at every commit, except at S3-R26 item 11's red-first commits, which may also carry those cases." Checked: 12.5.12 keeps every other stage green (rulings:1255), and S3-R26 item 11 lets only the red-first commit be red (rulings:639). So step 1's red-shape commit, with the Sync stage red and the purge cases red, met neither rule as drafted. No decision rules red commits. F FO3 asks the orchestrator to rule the same point, so the sentence is put to the orchestrator for confirmation (note 11). |
| C M3 | header, the new "Names" bullet (lines 29-32), and the renames in lines 58-62, 84, 93, 94, 108, 109, 143, 157 and note 4 | Yes | The bullet: f1-B1 to f1-B13; f2-R1 to f2-R3; f1's clauses keep "clause (a)" to "clause (g)"; f3's conditions are C-2 (a) to C-2 (d); T-F1a to T-F10, the W- shapes, C-1 to C-5 and stages A to C keep their names; "in this ruling and in the draft's records". Renamed in the text: B1, B2, B3, B9 and B11 to f1-B1 and so on; R1 to f2-R1 (six places); "Condition (b)", "whose (b) holds" and "Each condition" to C-2 (b) and "Each of C-2 (a) to (d)"; the bare (f), (b) and (c) in the kill list to "clause (f)" and so on. Checked: S3-R27 12's names rule (rulings:1051); S3-R27 item 3's B1 (:846), B2 (:866) and R1 (:872); f1's B1 to B13 (f1:173-185) and clauses (a) to (g) (f1:110-120); f2's R1 to R3 (f2:85, :98, :116). The bullet names f2's R2 and R3 as well, though the text uses only R1, so that the draft's records cannot clash either. |

## Should-fix

None is applied for its own sake (the task names the must-fix items). "Where" is the line in the new file.

| Review, id | Point | Status | Where it would go |
|---|---|---|---|
| F S1 | f1-B3's split: forced false by e1-P1's tests and T-F1a, forced true by T-F1b and `userJoinFromInside…`; `pinSpaceRead` is a helper (`…ReroutePinSpaceTests.swift:56`), so name its tests (`:147`, `:160`) | Not applied (also C S2) | line 60 |
| F S2 | C-5's "otherwise remove the retired jobs by key in a second pass"; C-4's count (a job counts its purged ids with no Set and takes `.all`'s path when all are purged; f3 §3.1), on which §3.4's "C-4's count" kill depends | Not applied (the C-5 half is also C S6) | lines 116 and 111 |
| F S3 | Step 7's records: item 5's `followedLane` record (`s3f.md:6945`, `:7713-7714`); optionally reqs #10's `s3f.md:7367` and `:5750-5755` | Not applied | lines 149-152 |
| F S4 | Citations: "None, in any cycle" is `s3f.md:8214`, not `:8213`; `metInItsAttempt`'s doc is `EngineJobs.swift:280-288` | Not applied | lines 150 and 77 |
| F S5 | Label code reading: "The stamp fixes correct #1 and T-F9" (review "What holds", UNCONFIRMED); "It is red in every round" is by construction, not measured | Not applied | lines 51 and 84 |
| F S6 | Two overstatements: "in every state" is false for clause (b)'s joins (`EngineFollow.swift:1524-1525`), so "in every state but clause (b)'s"; "bind now only through step 0's shapes", though line 40 applies must-fix 2's two causes | Not applied | lines 49 and 74 |
| F S7 | The record of "why no scenario is lost" repeats f2's "never asserted", which f2 review should-fix 4 corrects; name should-fix 4, or cite `EngineFollowBarrierSharedMoveTests.swift:354`, or record that no test covers `EngineDispatch.swift:1078-1080` | Not applied | line 92 |
| F S8 | The bound test's change: the draft records its old and new text (`attemptEnd?.stamped` to the record's stamp), as 12.2 required for rr21-T8b | Not applied (also C S4) | line 56 |
| F S9 | f1-B11's killer under the replay half: a second attempt that reads the first end's stale stamp (a replay) or stale count (a visit) | Applied, through C M1 | line 62 |
| F S10 | C-3's place is fixed "before stage A's figures", not before `fourGroupJoins`' step-0 figure, which is taken on `9aa337c` and cannot move | Not applied (also C S5) | line 110 |
| F S11 | Note 12 is inaccurate: cycle 22 planned to take items 3's and 4's 'before' figures, but steps 5 and 6 never started (`s3f.md:7642-7643`) | Carried in note 12 (outside the ruling); checked at `s3f.md:6917-6918` and `:7642-7643` | note 12 |
| C S1 | Clause (b) without clause (a): record why it changes nothing outside an ENOSPC publication's read (the review's code-reading argument), or scope clause (b) to a job that holds a stamp; "a removal in a visit" | The last sentence is applied, through F M2; the rest is not (note 3) | lines 45 and 50 |
| C S2 | Item 1's kills: f1-B3's split (as F S1); "the publication end's write dropped" has no killer in item 1 (cycle 22 planned e1-P1's own test, `s3f.md:7148-7149`); one list of what counts as a kill (line 57 against line 145) | Not applied | lines 57-60, 143 and 145 |
| C S3 | Step 0's list: T-F4 is listed twice (the corrected T-F4 replaces f1's); a rule for a shape that cannot be built after a real attempt (S3-R27 12.5.2, with S3-R26 item 7's B-T5 rule: record the attempt and the residual risk, not blocking) | Not applied | lines 68-73 |
| C S4 | Item 1's records: the bound test's old and new text (as F S8); the record holds two values with two lifetimes (the stamp: both ends, cleared at the deferral, the verdict and the start; the count: the transfer's end, cleared at the start) | Not applied | lines 42, 47, 49 and 56 |
| C S5 | Route C's order: 12.5.15's extended audit before C-2 and C-3 in stage A, and before C-5 in stage B; C-3's place fixed before C-3's commit (as F S10) | Not applied | lines 103-104, 110, 133 and 158 |
| C S6 | Gaps in route C: C-5 for a small retired share (as F S2); the mutants of C-2′ and the narrowed C-2 (b); shutdown's freeing slices pinned as `settle`'s are (S3-R27 item 6); a class for a test that the F-1 clause turns red (S3-R16 1(b) if the state is real, no route in cycle 23, the clause uncommitted) | Not applied | lines 109-121 |
| C S7 | Bench files: 11.6 authorised the new `BenchSync*.swift` files of cycle 22 (rulings:1034), and no text authorises cycle 23's | Not applied; it is decision-level and is carried in note 17 | line 150, or a new authorisation in item 3 |
| C S8 | The verifiers' rules: item 1b binds a verifier only for the fixer runs started after it was appended; the load window, "when one occurs; otherwise ... not measured at a quiet load" (rulings:763) | Not applied | lines 5 and 172 |
| C S9 | Small points: whether the 30 iterations are run; cycle 23's rewritten mutants go under `.build-s3f/c23/tools/`, leaving `c22/` as it is; "in the committed test" for the clock moves; the margin list in the 8.5 ms sentence (rulings:764) | Not applied | lines 94, 33, 89 and 35 |

## For the orchestrator: where each review item went

| Review item | Note |
|---|---|
| F FO1: the mapping; a route to `:1001` through f3's new `.all` test; correct #2 open until item 1b; reqs #7 closed by the verifiers | 14 |
| F FO2: the fifth in-letter shape needs a ruling | 7 |
| F FO3: 12.5.12's extension does not cover the commits after stage C | 11 |
| F FO4: f3 review should-fix 3 is not named | 2 |
| F FO5: notes 1, 3, 5 and 6 are faithful; decision 5 omits f2 review "must add" 1's re-run | intro and 5 |
| C FO1: decision 4's "drop-mutant" does not compile at `:1004` and `:1009`; `:1001` has the same form | 14 |
| C FO2: the stage trigger should name the cases each stage can move | 8 |
| C FO3: W-DB has no route even under the candidate join rule | 16 |
| C FO4: the bar covers the fifth shape whether or not it is gated | 7 |
| C FO5: reqs #8 and reqs #9 | 17 |
| C FO6: must-fix 1 and should-fix 1 settle notes 1 and 3; note 5's Sync bundle; agreement with notes 4, 6 and 9 to 13 | intro, 1, 3 and 5 |
| C FO7: the mapping fits, with only `:1001` left over | 14 |

The writer's notes 1, 4, 6, 11, 12 and 14 are updated where the edits touch them (note 1 for C M1, note 4 for C M3, note 6 for F M1, note 11 for C M2, note 12 for F S11, and note 14 for the reviews' FO items). Note 18 is the editor's: the should-fix items above.

## Facts checked

- `9aa337c`:
  - `EngineJobs.swift:289-297`, `:291`, `:293`, `:327`, `:427-431`;
  - `EngineFollow.swift:390-394`, `:548-565`, `:1522-1526`, `:2005-2022`;
  - `EngineFailures.swift:196-212`, `:564-583`, `:586-596`;
  - `EngineCommands.swift:998-1012`;
  - `Tests/ZTronAssetSyncTests/Engine/EnginePurgeWithdrawalTests.swift:100-105`;
  - the callers of `decideSpaceFailure` (`EngineFailures.swift:582`, `EngineFollow.swift:394`) and every Sources use of `transferSpaceEnd` and `.stamped`.
- The rulings file: :242 and :245-247 (S3-R19 items 2 and 3); :585 and :639 (S3-R26 items 7 and 11); :722-764 (S3-R27's header and C2 rule); :846, :866 and :872 (S3-R27 item 3's B1, B2 and R1); :1034 (11.6); :1049-1053 (12's names rule); :1253-1256 (12.5.12).
- The analyses: f1 §3 (f1:89-185); f1 review must-fix 4 and 6 and "must add" 1 and 5; f2's R1 to R3; f3's C-2 conditions (f3:104-118); f3 review must-fix 3 to 5 and should-fix 5 and 6.
- The fixer's draft: `s3f.md:6917-6918` and `:7642-7643`.
- `docs/ORCHESTRATION.md:230-245`: decisions 1 to 5 of 11:20, and the editor's files (v1 is the copy before the changes).
