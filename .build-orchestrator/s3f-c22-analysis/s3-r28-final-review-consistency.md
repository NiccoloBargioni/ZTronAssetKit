# Consistency review of s3-r28-final.md (S3-R28's final text)

This is an independent, read-only check (CLAUDE.md P4) of `s3-r28-final.md` (written 13:23). It reads the text against S3-R16 to S3-R27 (with S3-R27 12 and 12.5), CLAUDE.md, N1 to N20 and the 11:20 decisions, and against itself. The code is `.worktrees/s3f` at HEAD `9aa337c`. Nothing was built, run or measured, and every claim about code comes from reading it. Bare line numbers are the final text's. "rulings" is `s3-rulings-s3f.md`, and "orch" is `s3-r28-orchestrator-rulings.md`.

## Verdict: CORRECTED

The text carries N1 to N20 and the 11:20 decisions faithfully, and its routes, steps and counts fit together. Five places must change before it is appended:
- in four of them, two verifiers could judge the same work differently (M1 to M4: red shapes, e1-P1's kills, item-3b misses, N9's probe);
- one sets a kill rule that cannot be met (M5).

Ten smaller changes remove ambiguity. Nine points touch final rulings, or N21 (13:34, after this text), and belong to the orchestrator.

**Checked and consistent:**
- **Counts.**
  - 44 commits in `d5b2ab9..9aa337c` (git), and 14 blocking findings, 7 per lens (`s3f-c22-issues.json`).
  - Five new purge cases (:121-125) and three unreached lines (:156).
  - The eight bench files of :163: nine `BenchSync*.swift` at `9aa337c`, less WP-F's own `BenchSync.swift`.
  - Hours: 12-18 + 3-4 + 4-6 = 19-28 h for route C, 4-6 + 4-6 = 8-12 h for step 0, and 38-59 h for item 1b.
- **Ownership.** No edit outside WP-F is ordered or implied:
  - C-4 edits nothing outside WP-F (:106), and P-13 stays WP-B's (:185);
  - new bench files are WP-F's under 11.6 as amended (:161), and ARCHITECTURE changes are proposals (S3-R6);
  - nothing touches `../ZTronCarousel*`.
- **Rulings carried as ruled:** N12, N13, N14, N17, N19, and N20's "nothing in item 1 for the code" and "step 1 is item 2 alone".
- **S3-R27 item 1's records** are rightly absent from step 7's list (:162-166). `s3f.md:6945` calls them unwritten, but they exist at `s3f.md:7412-7413` and `:8827`.

## Must fix

**M1. Which red step-0 shapes block (:58, :61, :63).**

*Why.*
- **A start-count-only difference would block.** :58 makes the failed job's start count an assertion, and :61 makes every red shape blocking under S3-R16 1(a), which is a rule about answers. So a shape with visit-first's answers whose job starts twice reads as red and blocking. That goes against:
  - S3-R27 12.2 (rulings :1121): "Its other observations, such as a request count or a job's state, are recorded with it";
  - S3-R27 12.5.1 (:1233);
  - S3-R26 item 7's residual of "one more job and one more request" (:587).
- **Invariants and hangs are not covered.** The text does not say whether a broken invariant or a hang makes a shape red. The cycle-22 helpers record `invariantViolations()` (`VerifyC22CorrectProbes.swift:338`, `:461`), but their `#expect`s (`:361`, `:480`) check only answers and starts.
- **Rounds are not covered.** It does not say whether one red round in two counts.

*Replace* "**Every other red shape is blocking** (S3-R16 1(a)) and is reported with its log. Item 1b rules what follows for each one." *with:*

> "**Which red shapes block.** A shape is red in an order and drain timing when it fails there in either round. A red shape is blocking (S3-R16 1(a) to 1(c)) when it breaks S3-R16 item 1 there: an answer different from visit-first's, a broken MUST or invariant (`invariantViolations()`, `EngineCommands.swift:1773`, which the helpers record), or a hang (S3-R27 12.2, rulings :1121; 12.5.1, :1233). A shape red only by the failed job's start count, with visit-first's answers, is recorded as red by its count. It is not blocking (S3-R16 item 2; S3-R26 item 7, rulings :587). The two shapes of the bullet above are classed as that bullet says. Each blocking shape is reported with its log, and item 1b rules what follows for each one."

**M2. e1-P1's four mutants have no fallback (:152).**

*Why.* :43 rules nothing in item 1 for the code, so e1-P1's code stands until item 1b, which may come late or not at all (:199: "A cut-off inside the cycle is likely"). 12.5.4 (rulings :1236) puts these kills at S3-R27's step 7, which is this text's step 6 (N13). As written, at a close without item 1b no step runs them: one verifier reports them as blocking under 1(e), another as deferred.

*Replace* "So e1-P1's four (`s3f.md:7147-7149`) wait for item 1b: they are rewritten for its code and run with its kills." *with:*

> "So e1-P1's four (`s3f.md:7147-7149`) run here, on the code as it stands. If item 1b has been appended by step 6 and rewrites that code, they are rewritten for its code and run with its kills instead. If item 1b rewrites the code after they ran, its kills re-run them for its code (12.5.6). Until each is killed, it is blocking (S3-R16 1(e)), and the draft's status list reports it with its route."

**M3. Whether a miss on a case that item 3b covers is blocking (:139).**

*Why.* "The exception" can be read as an exception to "is blocking", so that a covered case's miss does not block before item 3b. It can also be read as an exception only to "no route in cycle 23". N9 (orch :54-57) makes no exception to blocking, and S3-R27 item 1's rule (:132) says a miss is blocking. Item 5's "reported" (:182) needs "the item that routes it, or 'no route in cycle 23'", and item 3b does not exist before its append.

*Replace* :139 ("A miss after stage C, … Report each miss with its parts' figures and loads.") *with:*

> "A miss after stage C, or after the last stage triggered, is blocking (S3-R27 item 1's rule), and is reported with its parts' figures and loads. For a case that item 3b covers (above), the route is item 3b. Until item 3b is appended, the draft's status list gives its route as 'item 3b, not yet appended'. Once item 3b exists, a miss after item 3b's route has no route in cycle 23. Every other miss, and a covered case's miss at the close if item 3b was never appended, has no route in cycle 23."

**M4. N9's probe has no place in item 5's order (:127).**

*Why.* The probe gates the skip, but item 5 (:169-185) gives it no place. The skip may come with route C (option (i)'s skipped re-queue, :104) or with item 3b: f3b-route-a runs a T-A1, which it calls N9's probe, before its A-3 (`f3b-route-a.md:110-111`). A verifier cannot tell whether a skip committed before its probe is a finding.

*Replace* "This holds while S3-R16 item 1 holds: a probe shows, … under "Residual risks (S3-R16)"." *with:*

> "This holds while S3-R16 item 1 holds. In the step that first skips the re-lane (a stage of route C, or item 3b's route), a probe runs before that commit. It must show, in both orders, that the answers and every job's start count equal visit-first's. That commit's message and the draft cite its log, and the draft records the place difference under "Residual risks (S3-R16)". If the probe shows a difference, the skip is not taken."

**M5. The model-test variant cannot be a killer of record (:116).**

*Why.*
- :114 requires each kill "2/2 in each order that reaches its branch, by value".
- The model test registers groups only at `.prefetch` (`EngineModelTests.swift:87`) and makes no ensure call. Under `.all`, the filter's kind and lane mutants therefore leave its random states as they are. Unless the variant also generates user-lane groups and ensures, which the text does not ask, it cannot meet :114.
- The f3 review's must-fix 2 (its :56) adds the variant "so that C-3 runs with the id-level F-1 checked afterwards"; only its "must add" 5 (:127) lists it in the kill table.

*Replace* "… pending on distinct contents, and by a new model-test variant that purges `.all`. The existing model test stays (G3);" *with:*

> "… pending on distinct contents, asserting by value right after the purge (f3 review must-fix 2). A new model-test variant that purges `.all` also runs C-3 on random states, with the id-level F-1 clause checked afterwards. It is not a killer of record, since the model test registers groups only at `.prefetch` (`EngineModelTests.swift:87`). The existing model test stays (G3);"

## Should fix

1. **:3.** "Step 4 up to e2-A2.5" reads as if e2-A2.1 to A2.4 were made, and :96 and stages A and C rely on their being unmade.
   - Replace "steps 0 to 3, step 4 up to e2-A2.5," with "steps 0 to 3, step 4's e2-A1.1 to A1.7 and e2-A2.5 (e2-A2.1 to A2.4 were not made, `s3f.md:6936-6937`),".
2. **:45.** By the f1b review's must-fix 2 (code reading), W-JOIN-HOP is red on `9aa337c` in three of its four swept-first cells, and a verifier may take a red late-drain cell as a regression.
   - Replace "At a transfer's end, `9aa337c` has no stamp, … the shape is green there today (`EngineJobs.swift:293-295`)." with "At a transfer's end, with the drain inside the read, `9aa337c` has no stamp, so the replay is not met and T20 re-queues the job, as visit-first does: that cell is green today (`EngineJobs.swift:293-295`). At a publication's end, and in the late drain at both ends, the shape is red on `9aa337c` already (f1b review must-fix 2)."
3. **:63.** :49 gives the visited-first runs one timing, so "order × drain timing" has a fourth cell that no run fills.
   - Replace the line with "**The results** go to the draft's cycle-23 status list as one table. Each shape has three cells: visited first, swept first with the drain inside the read, and swept first with the late drain. Each cell gives red or green for each of the 2 rounds, with the log."
4. **:76, :89.** "Not by measurement" can be read as "no run needed", but G2 and P3 ask for a red seen in a run.
   - At :76, replace "It is red in every round by construction, not by measurement:" with "Its red does not depend on load, by construction. The fixer runs it, 2 rounds, and records it red with its log (G2):".
   - At :89, replace "f2-R1 red, by construction;" with "f2-R1 red in the fixer's run (red by construction), with its log;".
5. **:77, :84.** Step 1 (:171) and the f2 review (its :127: "Land A-T-SD's change on its own commit") make A-T-SD's change one commit, but :77-78 number the fix and the check apart. :84's record needs the check on that commit, and item 1b may not land in cycle 23.
   - Replace "**The fix**, on its own commit:" with "**The fix**, on A-T-SD's commit, which also carries the set-up check (3); the doc fixes (4) may share it:".
   - Replace "on A-T-SD's own commit (step 1) and on item 1b's last commit." with "on A-T-SD's commit (step 1), and on item 1b's last commit if item 1b is taken in cycle 23."
6. **:153.** Inside item 4, "item 3" also names S3-R27 item 3 (:146).
   - Replace "Item 3's mutant runs, and item 1b's if item 1b places them here." with "Route C's mutant runs (item 3 above: f3 §3.4's kills, as corrected), and item 1b's if item 1b places them here."
7. **:133.** 12.5.13 (rulings :1257) still applies where S3-R28 is silent. But e2-A2.4 now sits in stage C, which may not run, and C-1 to C-5 are not e2-A2 parts.
   - Append: "12.5.13's re-measure of `purgeWhileOwedTurns` and PROBE-C21-PURGE-PARTS applies after each part of route C, e2-A2.1 to A2.4 and C-1 to C-5 alike. This per-stage measure replaces its 'after the last e2-A2 part'."
   - Limiting it to e2-A2's parts is a valid alternative if the text says so.
8. **:185.** "Red cases across the cycle" lets reported misses keep the Benchmarks stage red to the close, so the close's FAIL will usually have more causes than P-13, and the text does not say how that FAIL is reported.
   - Replace the sentence with "A FAIL whose only causes are P-13 (WP-B's; S3-R26 item 10) and the cases reported as misses under 'Red cases across the cycle' is reported as such (12.1), with each cause named from the benchmarks log. The misses stay blocking. Each of its other stages also runs and passes on its own."
   - This keeps 12.1's narrowing to P-13 (rulings :1063) and adds only the misses that S3-R28 itself keeps red.
9. **:201-209.** :11 has the fixer record "correct #n → item k", but five of the 21 findings have no row, and correct #8's location is WP-B's `BenchStorage.swift:249`. Add after :209:
   - "correct #8 (not blocking) → item 5's close: P-13 is WP-B's (S3-R26 item 10), and WP-F edits nothing for it;"
   - "correct #9 (not blocking) → item 4 (step 5's deciding figures);"
   - "correct #10 (not blocking) → no action: its two residuals stay as the draft records them;"
   - "reqs #10 (not blocking) → item 4 (step 7's stale records);"
   - "reqs #11 (not blocking) → item 6 (the quiet-load runs), with `commitTwoTokensTurns` kept on the margin list."
10. **:96.** "(i)" also names option (i) (:104, :123-124) and corner (i) (:56).
    - Replace "e2's after-A2 estimate for (i), 5-12 ms (e2:193)," with "e2's after-A2 estimate for case (i), `oneGroup`, 5-12 ms (e2:193),".

## For the orchestrator

1. **N21 (13:34) postdates this text.** Its two named replacements (:67, and :69's first sentence) leave three places stale:
   - :69's "It is not launched if the owner has classed that dating as timing by then";
   - :170's "f1c is launched once it is committed (item 1)";
   - :60's "Their classification is item 1b's". For step 0's table, N21's reading of VF's own timing now settles this: SF matches when it gives one of VF's answers.

   N21's check of f1c's predictions against step 0's table, before item 1b's route binds, has no line in the text.
2. **N20's step-0 list leaves out three of f1b §2's rows: W-HP-d, W-DB-off and W-BACK (both ends).**
   - f1b §3 (`f1b-join-rule.md:125`) runs every §2 row at step 0.
   - f1b rates W-DB-off and W-BACK red on `9aa337c` (:120-121, code reading), and the f1b review's must-fix 3 rates W-HP-d red in the late drain. With :70, W-HP-d's half of must-fix 3 binds nothing until item 1b.
   - The list holds 39 shapes, counting ends and corners, against ORCHESTRATION.md:276's "about 35". With these rows it would hold 43.
3. **M1 reads "red" as S3-R27 12.2 does.** If a start-count-only difference (T starting twice, with VF's answers) should block, rule it. S3-R26 item 7 treats one more job and one more request as a residual.
4. **M2's alternative.** Keep "wait for item 1b", and add that e1-P1's four stay blocking under 1(e) until item 1b runs them.
5. **N8's premise is inexact.** Stage C drops `jobs.keys.sorted()` (`EngineCommands.swift:1019`), which every purge pays (2-3.5 ms, f3 §3.2).
   - :134's "too little to close a case that retires no job" holds for f3 §3.6's two cases (15-39 ms), not in general.
   - `pendingClaimGroups` keeps its jobs under option (i) (C-2′), and after stage B it could sit within 3.5 ms above 8.5 ms.
   - Consider adding: "a case that retires no job and is above 8.5 ms by no more than 3.5 ms after stage B also triggers stage C".
6. **N9's "if option (i) leaves them above 8.5 ms" names no measuring point.** It could be after stage A, where option (i) lands with C-2, or after the last triggered stage. The choice decides which cases M3's item-3b clause covers.
7. **N19's two placements of item 3b conflict** if item 3b is appended before step 3. One is "the first step that starts after it is appended", the other "its natural place is after route C's stages".
   - f3b-route-a's A-1 rewrites C-3 (stage A).
   - Its A-3 replaces the `:1019` sort, which is stage C's ground, and its T-A1 runs red before A-3.
   - Let item 3b's text name its place and the parts it replaces.
8. **N14 against S3-R24 item 3.**
   - Under `.all`, the jobs take the fast path (`withdrawPurged(isPurged, all: all)`, `EngineCommands.swift:1022`), so only `withdrawPurgedJoins` (:1016) calls the predicate. N14's expected reach of :1001 is therefore swept first only.
   - S3-R24 item 3 asks for a reach "in both `LaneDropVisit` orders" (rulings :323).
   - Rule whether "2/2 in each order that reaches it" applies here, as S3-R27 item 6 ruled for the epoch clause.
9. **f3b-route-a §9 finds three more in-letter shapes with no gated case.** Its figures are derived, and `f3b-review.md` is still a stub.
   - One is about 0.5 s today: failed user jobs with `.retry` deadlines under prefetch groups (`EngineJobs.swift:362`'s heap scan).
   - None is among item 3's five, and S3-R27 12.1 would gate them. They are for item 3b.
