# end-sooner-options.md: independent check

Reviewer: independent of the note's author (P4). 6 Nov 2026, 15:35-16:05 CET. Read-only; nothing was built or run. My figures are estimates unless marked "measured"; measured ones are quoted from the file named.
- Code and draft were read at `9aa337c`. Since then `wp/s3f` has gained run 11's `03c4e59` (15:44, row 3's fix: a test and the draft) and `4b38eb4` (15:50, the draft's records). The rulings file was read at 1,664 lines (N29 appended at 15:55), ORCH at `93b40b2` (15:56).
- ORCH lines past :390 have moved by +39 since the note: its `:377`, `:484`, `:599`, `:617` and `:855` are now `:416`, `:523`, `:638`, `:656` and `:894`.

## Verdict: CORRECTED
The method holds: every gate claim, every §4 citation, every source hour and every formula cell re-derives. But the note predates N26-N29, the 71 % reading, run 11, item 3b's review, and f3c with its review. Nine points change the choice the owner is given. After N28 and N29, (b) and (c) are one option. The owner's open question (rulings:1616, :1657) maps onto (a), (c) and a new (c′).

## Re-derived and right
- **Gates.** `perf_tests` runs `--filter Benchmarks` in release (`Scripts/verify.sh:115`), from `--perf` (:130-132) and `--full` (:154); a failed step joins `FAILED` (:48) and prints `VERIFY: FAIL (…)` (:164-169). The nine shapes and both joins cases assert `waits.min() <= c2Budget` (`BenchSyncCycle22Purge.swift:32`, `:49`), a test literal (`BenchSync.swift:124-129`); `quality-gates.json` has no C2 key, so G1 is untouched and green needs the G3 word (`CLAUDE.md:3`, `:21`). `purgeWhileOwedTurns` is gated through `commitRerouteTurns` (`BenchSyncReroutes.swift:70-74`, `:126-127`); the recorded pattern is `BenchSyncCycle21.swift:156-174`; no case exists for N7's five, APM or item 4 (my grep).
- **Figures and hours.** The six misses and five closes match `s3f.md:7611-7621` at `9aa337c`; Done needs passing benchmarks, 3 runs and TSan (`PROMPT.md:14`, `:96`). Every source hour matches its file (`f1c-route-a.md:221`; `f1c-route-b.md:331`, `:340`; `f1b-join-rule-review.md:161-163`; `s3-r28-final.md:94`, `:209-210`; `f3-purge-route.md:343`, `:363`; `s3-r28-item3b.md:126-129`; `d4-survivors.md:517-531`; ORCH:85, :89), and the formula reproduces every cell of the note's table (my arithmetic).
- **§4.** Every code and SDK citation holds (`AssetLog.swift:3`, `:24`, `:29-30`, `:64-69`, `:158-171`; `EnvironmentSeams.swift:36-45`, `:55-71`; `AssetEnvironment.swift:31`, `:33`; `AssetClient.swift:33`, `:190-191`, `:324`, `:346`; `EngineJobs.swift:29`, `:1217`; `EngineRuns.swift:197`; `EngineCommands.swift:968`, `:976`; `Reports.swift:186`, `:264-276`; `EngineSupport.swift:116`; `AssetEvent.swift:123-150`; `Store.h:28`, `:88-90`; `MXMetricManager.h:60`). N0's thresholds re-derive (derived): 10 ms ÷ each figure × 10,000 gives 1,637-5,602 ids; 10 ms ÷ 53 µs gives about 189 jobs.

## Must fix
1. **Re-base the note on N26-N29 and run 11.**
   - **Row 1:** `| 1 | Step 0 as amended: verify.sh --quick on HEAD, which replaces the run on 9aa337c (rulings:1655); the 'before' figures for item 3's cases and S3-R27 items 3-4, only if the owner keeps that work (rulings:1657) | nothing alone | records, G2 | not estimated; the step-0 shapes and their 13-26 h left with item 1c (rulings:1586-1590, :1601) | — |`
   - **Row 2:** `| 2 | Item 1c as amended (N29): correct #1 and #2 are known residual risks for their S3-R16 1(a) answers only; any other ENOSPC-window answer difference blocks under N21 and goes to the owner at once; 1(b)-1(f) still block, the e1 kills included (rulings:1622-1639) | correct #1, #2, by ruling | owner rulings N28, N29 | 0 h: item 1b is withdrawn under every option | the owner's answer on the whole class (ORCH:415; rulings:1636) |`
   - **Rows 3, 7, 12.** Row 3 adds "in as `03c4e59` (15:44), not verified". Row 7: "N25's and item 1c's records are in (`4b38eb4`); item 1c's is amended to N29 on a commit of its own (rulings:1656)". Row 12, "Depends on": "none; the kills run on the code as it stands (rulings:1639)".
   - **(a).**
     - Hours: "58.5-91 fixer h (rows 3, 4, 6, 10, 12; my sum, estimates), plus the unestimated rows and item 3b's append".
     - Owner's word: "N25, N28 and N29 are given. The owner is deciding on items 3 and 3b, S3-R27 items 3-4 (rulings:1616, :1657) and the ENOSPC class (ORCH:415)".
     - Re-open, N25's three: "f3c's route, core 12-18.5 h plus 4-6.5 h for OS-4, OS-5 and OS-0, with stage C not estimated (`f3c-open-shapes.md:171-180`; OS-6 is dropped by `f3c-open-shapes-review.md:38`). Even at stage C, failedUserRetries' top, 10.8 ms, misses (review :75)".
     - Re-open, correct #1 and #2: "route Q, 44-67 h plus a 3-5 h check. It leaves four shapes that block if red, with no route (`f1c-review.md:136-144`, `:175-176`)".
   - **(b) and (c).**
     - Keep (c) and drop (b).
     - (c)'s record heading is "Known residual correctness risks (owner ruling 2026-11-06)" (rulings:1604), not "Residual risks (S3-R16)".
     - Drop "reversing N21". N28 and N29 already exempt correct #1 and #2, and N21 stands for the rest of the class until the owner answers ORCH:415.
   - **New (c′).**
     - It is (c), with rows 8 and 9 also known misses: S3-R27 steps 5-6, correct #5 and reqs #2 (rulings:1657).
     - Its hours are (c)'s, with two fewer unestimated rows. It leaves R1, R3-R7 and R12 open.
     - It adds no red gated case: APM is a probe only (`s3-r28-final.md:157`), and item 4 has no case (correct #9).
     - Owner's word: (c)'s, plus C2 for R6 and R7.
   - **(d) and (e).** (d) merges HEAD (row 3's fix in, not verified), not `9aa337c`. (e)'s fixer hours lose row 3's 2-3 h, which leaves 4.5-9 h (my arithmetic).
   - **§5, question 1:** "(a), (c), (c′), (d) or (e)?"
2. **Budget and rates (§3.0, row 18, the table).**
   - **Budget:** "71 % at 15:23 (ORCH:389, measured) leaves at most 29 points, less run 11's use since 15:34 (ORCH:6; about 1.1 points an hour for the fixer alone, ORCH:389, an estimate)".
   - **Row 18:** "measured, account-wide: S3-R28 ran from 51 % at 10:05 (ORCH:213) to 66 % at 14:27 and 71 % at 15:23 (ORCH:389), about 15-20 points over 4.4-5.3 h. The 4 points in 74 min (ORCH:221, :248) were its first analysis run only. S3-R27's was 6-10 points (ORCH:93)". So A = 6-20 points and 1.2-5.3 h of wall time.
   - **V:** 2 points is a floor, from an incomplete run. ORCH:88 forecasts 4-6. The table below keeps 2-6 so it can be compared with the note's.
   - **k is not measured.**
     - The 35-50 h (now ORCH:416) is the 19:40 forecast for all of cycle 22. It includes D4's 24-30 h, which the fixer did not start (ORCH:198). With item 12, the forecast was 55-90 h (ORCH:153).
     - Two later samples point opposite ways. Run 11 did row 3 (2-3 h, an estimate) in about 11 min: launched at 15:34 (ORCH:6), committed at 15:44:53. ORCH:389's forecast implies k below about 2-2.75 for cycle 23 (my reading).
   - **r:** 0.74 is an account-wide rate, measured 02:00-08:46 (ORCH:201), not a rate per fixer hour. ORCH:389 forecasts about 1.1 for the fixer alone.
   - **Replacement table** (estimates; the note's formula with A = 6-20, and rows 10 and 12 at 20.5-33.5 h; my arithmetic):

| Option | Fixer h | Points | Wall h | Cycles | `--full` PASS? | Left open |
|---|---|---|---|---|---|---|
| (a) | 58.5-91 + unestimated | 29.5-171 | 26-135 | 2-4 | only if every blocker closes, P-13's p99 passes on the merged head, and no flake fires | R1, R5 (both ruled), R12 |
| (c) | 22.5-36.5 + unestimated | 16-79 | 15-64 | 1-2 | only with the G3 word for every red gated case, and P-13 as in (a) | R1, R3-R5, R12 |
| (c′) | 22.5-36.5 + fewer unestimated | 16-79 | 15-64 | 1-2 | as (c) | R1, R3-R7, R12 |
| (d) | 3-6 + a check | 12-26 | 10-23 | 0 | as (c), and no flake | R1-R9, R11, R12 |
| (e) | 6.5-12 (4.5-9 now) | 13-35 | 11-31 | 1 | as (c) | R1, R3-R9, R12 |

   - **Sensitivities (estimates).** At r = 1.1 the high ends become about 204 points for (a), 92 for (c) and (c′), 29 for (d) and 39 for (e). At k = 2 the low ends become about 39 for (a), 19 for (c), 14 for (e) and 12 for (d).
   - **Fit against the at most 29 points left.** (a) does not fit, even at its low end; (c) and (c′) fit only near their low ends; (e) only in its lower half; (d) fits at r = 0.74 and is borderline at r = 1.1.
3. **Rows 10-12, "Closes".** reqs #3 names item 5's default-tuning probe together with the d4 survivors and e1's kills (`s3f-c22-issues.json`, reqs #3).
   - Row 10: "correct #7; reqs #3, with rows 11 and 12".
   - Row 11: `| 11 | Step 6: the 429 default-tuning probe | reqs #3, with rows 10 and 12 | running it: a ruled step (rulings:954-958), blocking under reqs #3; what it finds: S3-R16 item 2, or 1(a) | not estimated | — |`
   - Row 12: "reqs #3, with rows 10 and 11".
   - R8 then names reqs #3 as open under (d) and (e).
4. **Rows 4 and 6: basis and dependencies.**
   - **Row 4, basis:** "C2 and 1(f). As ruled, option (i)'s C-2′ breaks R-SYN-3 (`SPEC.md:228`, a MUST: 1(b)) for a kept claim-held job. N9's skipped re-lane leaves `queuedAt` and `lastTicket` stale and drops a `notifyObservers`. Item 3b re-checks both (rulings:1447; `f3b-review.md:35-37`, `:89-92`, `:97-100`)".
   - **Row 4, "Depends on":** add "item 3b's append. Step 2 waits for it, and steps 4-5 go first meanwhile (rulings:1446, :1507). Item 3b's review is written (`s3-r28-item3b-review.md`, 15:41, CORRECTED), but the append is not made: the rulings file ends with N29".
   - **Row 6, "Depends on":** "its append, with its review's must-fixes (rulings:1426-1433). Its code then builds on row 4 (`s3-r28-final.md:194`)".
   - **The consequence:** under (a), route C cannot start as ruled without a 1(b) risk. Under (c) and (c′), the two rows are dropped together.
5. **(b) and (c): N7's five, and the shapes that lose their closer.**
   - **Replace "The gated cases" with:** "The six stay red. N7's five are known misses under this option, so they follow N25's and N28's precedent: no code, test or bench (rulings:1439, :1590), and a record by estimate. Building them red would add up to five red gated cases, and `--full` would then need the G3 word for up to eleven".
   - **Replace the records with:** "the six; N7's five; f3b-review §7's two variants (`fourGroupJoins` 3-11.5 ms and three-kept 4.5-8.9 ms, after route C; `f3b-review.md:148-149`; rulings:1445); and route A §9's third shape (a prefetch waiter under three groups, 6-10 ms with A-3b, `f3b-route-a.md:167-173`), which only item 3b's M-4 closes (N26 O2). Each goes with its figure, load, closer and the re-open criterion".
   - **§2's ungated list and R4** add the two variants and the third shape.
   - **§5:** question 2 reads "every red gated case". Question 3 reads "recorded by estimate (N25's precedent), or built as recorded cases to measure them?"
6. **The `--full` column needs P-13 under every option.** Add to every table row, and to the `--full` bullets of (b) to (e): "and P-13 passes on the merged head. It is judged on its p99 (`feature/asset-kit` `BenchStorage.swift:253`), which has never been measured. `wp/s3f`'s maximum fails it today (`:249`; correct #8, 8.818 ms against 5.0)". A red `benchmarks` step blocks Done (S3-R16 1(f), rulings:160; `PROMPT.md:96`).
7. **R5's figures.** Replacement: "**R5, N25's three** (ruled known misses).
   - Today, case 1 takes about 500 ms when the origin admits a user request (derived; the heap scan is today's cost too, `f3b-review.md:151`). Case 3 takes about 21-34 ms (estimate, `f3c-open-shapes-review.md:59`, 15:57). Case 1's other path and case 2 have no figure for today.
   - After route C and item 3b's merge, which happen only under (a): 9-18, 9-17 and 10-20 ms (estimates, `f3b-review.md:143-147`)."
   - The draft's own record already labels these "after route C and item 3b's merge … none measured" (`s3f.md:8073` at `4b38eb4`).
8. **Field data.** None can exist without an app that adopts the kit: Stage 4 stays cancelled (ORCH:656), the sibling repos are writable only in Stage 4 (`PROMPT.md:19`), and S1's reader (a `LogSink`, `AssetEnvironment.swift:31`, or `OSLogStore`) and N0's count (`AssetClient.swift:324`) are both app code.
   - In (e)'s re-open, "it starts with field data" becomes "the line is in place for when an app adopts the kit (not planned)". §4 adds: "R1's re-open criterion is field frequency (rulings:1611); S1 does not cover it, and a site of its own is not estimated". Question 4 adds: "Is adoption by ZTronCarousel planned? Without it, no signal yields data".
9. **The low end of rows 10 and 12.** r2b may be argued in the draft instead of built (rulings:947; `d4-survivors.md:523`).
   - The low end is then 14.5 h of writing, plus 14 runs (2.3 h), plus e1-R1's 3.7 h: 20.5 h, not 24.4 (my arithmetic, estimates).
   - The sums line reads "rows 10 and 12, 20.5-33.5 h". (d)'s re-open reads "the kills (20.5-33.5 h)".

## Should fix
- §2's "the draft's last purge table" becomes "the after-e2-A2.5 table (`s3f.md:7608-7621`)". The last purge table is the step-8 gate run, at 35.71-62.56 ms (`:7726-7745`).
- §2's ungated list adds item 4's k = 2 and k = 4 shapes (no case; correct #9).
- R3: the figures are from the Mac reference host (`quality-gates.json:62`), and there is no device figure. f3c's review adds that the benches' fake hides production's `originID` builds (`f3c-open-shapes-review.md:102`), so the real cost may be higher (not verified).
- (a)'s "2-4 likely" becomes "2-4, a guess". Cycles 13-19 left a flat 5-8 blockers each (ORCH:523), and cycle 22 left 14.
- (d)'s owner's word adds reqs #7 (R11): the close would come with cycle 22's closes unproven.
- (e) says what happens to a new blocking finding from its short verification: another cycle, or the owner's word to record it.
- Re-point the moved ORCH citations, as listed in the header.

## For the orchestrator
- **The owner's question** (rulings:1616, :1657) maps onto three options: keep all = (a); drop items 3 and 3b = (c); also drop S3-R27 steps 5-6 = (c′). The ENOSPC class question (ORCH:415) applies under every option. Run 11 has already committed row 3 (`03c4e59`) and the records (`4b38eb4`).
- **f3c's review** (15:57) asks that §8.2's two cases be measured in cycle 23 (`f3c-open-shapes-review.md:96-101`). If that is ruled, it is a ledger row under every option except (d), and a miss is an owner stop (N22 item 4).
- **Archive snapshot 2** (`5ba3601`, 15:55) is local only. It holds the note, f1c's review, f3c and its review. `origin` still holds `765102c` (14:46). The owner wants the analyses kept for a later resume, so ask now whether to push it (ORCH:413; N25), not only at the close. A later snapshot is needed for this review and the owner's ruling.
- **The owner's uncommitted `Package.swift`** (tools 6.0 → 6.3) is outside every option. Stage 5's `--full` would verify a tree with an uncommitted change (G2). Ask the owner, and never touch the file.
- **`withKnownIssue`:** the interface (`Testing.swiftinterface:822-825`) has `isIntermittent: Bool = false` and no doc comments. Whether a miss that goes away then fails stays UNVERIFIED (C7). The recorded-case precedent (`BenchSyncCycle21.swift:156-174`) needs no such check.
- **`c2Budget`:** the literal is an exception to `quality-gates.json:62`'s "never from literals", ruled by ADR-052 R4 (`BenchSync.swift:124-129`). Raising it is not a route to green: it would break C2, that ruling and the /goal (`PROMPT.md:83`, `:96`).
- **`commitTwoTokensTurns`** is gated through `commitRerouteTurns` (`BenchSyncReroutePins.swift:45-47`) and measured 9.02 ms (`s3f.md:7745`), 0.98 ms under the limit. A noisy gate run can turn `benchmarks` red under every option.
- **Item 3b's review** is written (15:41, CORRECTED), but item 3b is not appended. Under (a), step 2 waits for the append (rulings:1446, :1507).
