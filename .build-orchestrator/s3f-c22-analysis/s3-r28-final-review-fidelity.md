# S3-R28 final text: the fidelity review

- **Text:** `.build-orchestrator/s3f-c22-analysis/s3-r28-final.md` (209 lines, saved 13:23).
- **Against:** N1-N20 (`s3-r28-orchestrator-rulings.md`, N20 over the rest); the 11:20 decisions (`docs/ORCHESTRATION.md`)
  as N20 changes them; the reviews' items as N18 rules them (`s3-r28-changes.md`); f1, f1b, f2 and f3 with their reviews;
  `s3f-c22-issues.json`; and the code at `.worktrees/s3f`, HEAD `9aa337c`.
- **References:** ":n" is a line of the final; "N :n" of `s3-r28-orchestrator-rulings.md`; "rulings :n" of
  `s3-rulings-s3f.md`, as the final uses it; "review :n" of the f1b review.
- **How:** read only, with no builds and no tests. The reviewer is not the author (P4).

## Verdict: READY

- **Must fix:** none.
- **Should fix:** two items, in the mapping and in one record list. They touch no route and no decision.
- **For the orchestrator:** four points. One concerns N21, which was appended at 13:33, after this text.

## Checked and right

- **N20, part by part:**
  - "Nothing in item 1 is ruled for the code now", with its five things and clause (b) (:43); the why (:44-46); correct
    #1 and #2 stay blocking (:47).
  - Item 1b, its three inputs and f1c's condition (:64-69), word for word with N :100-105.
  - Step 0's list (:52-57) matches N :111-115 name for name, and its rules (:58-63) match N :116-120.
  - Step 1 is item 2 alone (:171), and the shapes may run after it (:170). N5's T20 check covers item 1b's commits
    (:83-84). N1, N3, N4 and N16 wait for item 1b (:70). The mapping is at :202.
- **No part of the replay half is ruled now.** The mentions of `metInItsAttempt`, `stamped`, clause (f), the join rule
  and the f1-B and f1b-K labels (:15, :31-33, :43-46, :57, :64) describe the findings or list item 1b's contents.
- **The editor's additions are faithful:**
  - **"Only the swept-first runs have two timings" (:49).** The f1b review defines the late drain as an SF run
    (review :8) and runs every SF row in both timings (review :149). Visited first, `applyHeld` releases the follow
    inside the apply (`EngineFollowBarrierReachTests.swift:19`, `:25-27`).
  - **Stage C's sort (:134)** is labelled as an estimate.
  - **C-2′'s reach** holds against `EnginePurgeWithdrawalTests.swift:83-91` and `:99-108`.
- **N1-N19 outside item 1:**
  - **N5 (:82-85):** the replay half has no commit now, so A-T-SD's own commit takes the place of its last one.
  - **The others:** N6 at :104 and :141; N7 at :121-129; N8 at :134; N9 at :129, :136 and :180; N10 at :106; N11 at
    :181-184; N12 at :170; N13 at :176; N14 at :156-160; N17 at :155 and :161; N19 at :178-180, :189 and :5.
  - **N18:** F S2-S5, S7 and S10, and C S3 and S5-S9, are present. The items that concern item 1 move with it (N20).
  - **The reviews' should-fix items:** the f2 review's 1-4, 6, 8 and 9, and the f3 review's 1, 3-6, 8 and 9, are carried.
- **Estimates and measurements:**
  - **Estimates** are labelled: 38-59 h (:197, as at ORCHESTRATION :274), 2-3.5 ms (:134), and the item hours (:196;
    3.7-5.5 h at rulings :1136).
  - **Measurements** cite their logs. SF is red 2/2 in both probe logs (:39). The seeds are at probe file :351 and :473.
    e1-P1's other side fails only by the 180 s limit, in both orders (:154; `mut-logs/v-e1p1-rule-false-run1.log:60`,
    `:67`).
- **Citations: more than 40 spot-checked, all right at `9aa337c`.**
  - **Engine:** `EngineJobs.swift` :289-297, :290-291, :293-295, :327, :360-364, :427-431 and :827;
    `EngineState.swift:867`; `EngineFollow.swift` :2017-2022, :981 and :800; `EngineCommands.swift` :1000-1011, :1016,
    :1019, :1065 and :1884; `EngineFailures.swift` :858-859 and :866-868; `ValidatedManifest.swift` :15 and :86-91.
  - **Probes and tests:** the probe file at :251, :255-342, :285, :303, :320, :384-466, :415, :443 and :445;
    `EngineFollowBarrierDeferBucketTests.swift` :312-337, :720-752 and :754-788; `SubscriberQueueBatchTests.swift:95`.
  - **Documents:** `SPEC.md:331`; `s3f.md` :5750-5755, :6910-6947, :6945, :6959, :7147-7149, :7367, :7713-7714, :8213
    (blank), :8214 and :8237-8238; the rulings at :585, :1091, :1136 and :1234.
  - **Facts:** `2abddd1` is e2-A2.5; `d5b2ab9..9aa337c` is 44 commits; there are 14 blocking findings, 7 per lens (:3);
    and the eight `BenchSync*` files (:163) exist.

## Must fix

None.

## Should fix

**S1. Item 7's mapping (:205-209) leaves out three named findings and hides reqs #3's split.**
- **Not mapped.** By the text's own rule (:10-12), three findings are named: correct #8, P-13 (:185); correct #9 (:147);
  and reqs #10 (:164). The mapping lists none of them.
- **Reqs #3.** Line 152 sends its e1-P1 kills to item 1b, but :206 maps all of reqs #3 to step 6.

Replace :205-209 with:

```
   - correct #5 and reqs #2 → item 4 (S3-R27's steps 5 and 6); correct #9 (not blocking) → item 4 (S3-R27's step 6);
   - correct #6 and #7, and reqs #3 and #4 → item 4 (S3-R27's step 7, and the three unreached lines, `:1001` included); reqs #3's e1-P1 kills wait for item 1b (item 4's kills);
   - reqs #5 and #6 → item 4 (the records);
   - reqs #7 → item 6;
   - reqs #8, #9 and #10 (not blocking) → item 4 (step 6's guard, the ownership rule, and step 7's records);
   - correct #8 (not blocking; P-13, WP-B's) → item 5's close (reported as such, S3-R26 item 10).
```

**S2. Line 164 names two of reqs #10's three places.**

The finding also names the doc comment at `Tests/ZTronAssetKitBenchmarks/BenchSyncCycle21.swift:156-158`. That comment
still says "open, for the owner", and the file is one of the eight that :163 authorises.

Replace everything after "and" on :164 with:

```
reqs #10's stale records, updated to cite 12.1 and e1-R1's change (`s3f.md:7367`, the doc comment at `Tests/ZTronAssetKitBenchmarks/BenchSyncCycle21.swift:156-158`, and rr21-T8b's at `s3f.md:5750-5755`);
```

## For the orchestrator

**O1. N21 changes four places, not two.** Its replacements at the append (N :132) cover :67 and :69. It also reaches
:170, whose wording differs from N20's phrase, and :60, which its reading changes. Suggested text:
- **:67:** "3. the owner's ruling (N21, about 13:30): a join, request, removal or replay that meets a job during its
  ENOSPC end's free-space read gets visit-first's answer, including whether it counts as before or after the end; a
  different answer is blocking (S3-R16 1(a))."
- **:69**, both sentences: "f1c runs now (N21). The orchestrator checks its predictions against step 0's measured
  table before item 1b's route binds."
- **:170:** in place of ": f1c is launched once it is committed (item 1)", "; the orchestrator checks f1c's predictions
  against it (item 1, N21)".
- **:60:** in place of "Their classification is item 1b's.", "SF matches when it gives one of those visit-first
  answers for the same inputs in the same order (N21)."

**O2. N20's step-0 list (N :111-115, carried faithfully at :52-57) leaves out shapes that its bound sources name.**
- **f1b §2:** f1b §3 runs this table whole at step 0 (f1b :125). Three of its shapes are missing:
  - W-HP-d (:116), which f1b review must-fix 3 calls red in the late drain (review :61);
  - W-DB-off (:120), red on `9aa337c` by code reading;
  - W-BACK at both ends (:121), also red by code reading.

  The review's "must add" 3 runs every SF row (review :149).
- **f1b review must-fix 2:** W-JOIN-HOP's variants through an owed re-route and through a take-off (review :53-54).
- **Optionally, f1 §3's windows 8-10:** their probes are not among T-F1a to T-F10 (f1 :200-207).

ORCHESTRATION :276 says "every shape named so far". Without these shapes, no measurement checks f1c's predictions for
them before item 1b binds (N21). Add them, or confirm that they are left out.

**O3. That e1-P1's four kills wait for item 1b (:152) is the editor's own reading of "the kills" in N :100.** N20 does
not rule S3-R27 12.5.4, and N13 keeps the mutant runs at step 6.
- **e1-P2:** its kills (`s3f.md:7184-7185`) hit the same function. `v-e1p2-no-after-verdict` (`mutants22.py:41`)
  mutates `EngineJobs.swift:290`, inside `metInItsAttempt`. The text does not say whether they wait as well.
- **A late item 1b:** if item 1b is not appended before step 6, or leaves these lines alone, the four have no step to
  run in. Reqs #3's e1-P1 part then stays open for the cycle.
- **The other side's new assertion (:154):** the text does not say whether it lands at step 6 or with item 1b.
- **Suggestion:** run e1-P1's and e1-P2's mutants at step 6 on the code as it stands. Skip that only if item 1b is
  appended by then and rewrites their lines; item 1b then runs them on its code.

**O4. Step 0 judges "red" against visit-first answers that, for most new shapes, are predicted by code reading
(UNCONFIRMED).**
- Each probe asserts the predicted answers (:58). The cycle-22 probes compared the two orders' runs directly (probe
  file :370).
- The table (:63) has no entry for a VF arm that misses its prediction.
- **Suggestion:** the measured VF answer is the reference, and SF is red when it gives no VF answer (N21's reading). A
  missed prediction is recorded, with its log, for f1c.
