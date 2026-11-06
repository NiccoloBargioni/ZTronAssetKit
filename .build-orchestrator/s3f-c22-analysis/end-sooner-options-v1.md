# Ending WP-F sooner: the open work, the gates and the options, priced

For the owner. Written 6 Nov 2026, about 15:15 CET, read-only, at `wp/s3f` `9aa337c`. Nothing was built, run or tested for it.
- Every hour and point figure is an **estimate** unless it says "measured". "My sum" and "my estimate" mean this note made it (G2).
- Paths: analysis files are in this folder; `c21/` is `.build-orchestrator/s3f-c21-analysis/`; `rulings` is `.build-orchestrator/s3-rulings-s3f.md`; N-n is in `s3-r28-orchestrator-rulings.md`; `ORCH` is `docs/ORCHESTRATION.md` (its lines move); `s3f.md` is WP-F's draft. Code is at `9aa337c` in `.worktrees/s3f`.
- This note prices the options and recommends none. The re-open dossier v1 (`docs/REOPEN-WP-F.md`, untracked at 15:05) points here for §4.

## 1. The ledger

S3-R28's order of work (`s3-r28-final.md:183-199`), then item 6 and the post-convergence list (`ORCH:599`). "Closes" is item 7's mapping (`s3-r28-final.md:215-227`).

| # | Obligation | Closes | Basis | Hours (estimate; source) | Depends on |
|---|---|---|---|---|---|
| 1 | Step 0: `--quick` on `9aa337c`; item 1's step-0 shapes, about 35 (`ORCH:276`); the new purge cases' 'before' figures (N7) | nothing alone | records, G2 | 8-12 h (`s3-r28-final.md:209`); route B's own step 0 is 5-7 h (`f1c-route-b.md:331`) | — |
| 2 | Item 1b: the ENOSPC route | correct #1, #2 | 1(a), kept blocking by the owner (N21) | route A 40-62 h + step 0 (`f1c-route-a.md:221`); route B 31-47 h with its step 0 (`f1c-route-b.md:340`); f1b review 38-59 h (`f1b-join-rule-review.md:161-163`) | row 1; the f1c review, not written (`f1c-review.md:3`) |
| 3 | Step 1, item 2: the flake (f2-R1's probe, then A-T-SD's change) | correct #3 | 1(d) | 2-3 h, or 1-1.5 h with shared close runs (`s3-r28-final.md:94`) | — |
| 4 | Steps 2-3, item 3: route C, stages A, B, C | correct #4, reqs #1 | 1(f), C2 | 19-28 h (`f3-purge-route.md:343`, `:363`), without option (i) or the five new cases (`s3-r28-final.md:154`) | the extended audits (`s3-r28-final.md:186-187`); N23's stage trigger |
| 5 | N7's five new purge cases, gated BenchSync cases, red first | correct #4, reqs #1 | C2 | not estimated (`s3-r28-final.md:154`) | row 1's 'before' figures |
| 6 | Item 3b: the merged route, M-0 to M-5 | the five, by estimate; two only at stage B or C (`s3-r28-item3b.md:3`) | C2 | core 17-26.5 h, on top of route C (`s3-r28-item3b.md:126-129`) | row 4 (`s3-r28-final.md:194`) |
| 7 | N25's record of the three known misses | — | records | not estimated (in row 15) | — |
| 8 | Step 4 (S3-R27 step 5): APM's answer turn | correct #5; reqs #2 with row 9 | 1(f), C2 | not estimated; cycle 22's lump for S3-R27 items 1-3 was 10-15 h (`ORCH:377`) | d2's route (a) and B1 (`rulings:832`) |
| 9 | Step 5 (S3-R27 step 6): item 4, the k = 2 and k = 4 shapes | reqs #2; correct #9 (not blocking) | C2 | not estimated | A1, A2 if taken |
| 10 | Step 6: d4's kills, steps 6-12 | correct #7 | 1(e) | writing 18-24 h with r2b built, 14.5-18.5 h with r2b reported; 16 runs at 10-15 min, 2.7-4 h (`c21/d4-survivors.md:517-523`, `:525-531`; my sum) | re-killed where rows 2, 4, 6 rewrite code (`s3-r28-final.md:164-165`) |
| 11 | Step 6: the 429 default-tuning probe | — | S3-R16 item 2, unless it shows 1(a) (`rulings:954-958`) | not estimated | — |
| 12 | Step 6: e1-R1's rewritten mutants; the e1-PS, e1-P1, e1-P2 kills | reqs #3 | 1(e) | e1-R1: 3.7-5.5 h of runs (`s3-r28-final.md:210`); the rest not estimated | row 2, if it rewrites their code |
| 13 | Step 6: the unreached `EngineCommands.swift:1001`, `:1004`, `:1009` | correct #6, reqs #4 | 1(e) | not estimated | `:1001`'s reach is route C's new `.all` test (`s3-r28-final.md:172`) |
| 14 | Step 6: reqs #8's guard, `.timeLimit(.minutes(1))` at `SubscriberQueueBatchTests.swift:95` | reqs #8 (not blocking) | a guard; G3 holds | not estimated (minutes) | — |
| 15 | Step 7 (S3-R27 step 8): every missing record, the false 11.6 record (`s3f.md:6959` against `:8212`) included | reqs #5, #6, #9, #10 | records, G2 | not estimated | rows 1-14 |
| 16 | Step 7: item 9 and the close, every gate and `--full` on the final HEAD (`s3-r28-final.md:199`) | correct #8 reported as WP-B's; correct #10 no action | gates | not estimated | rows 1-15 |
| 17 | Item 6: two-lens verification, lens 3's heavy checks first (`s3-r28-final.md:205`) | reqs #7; reqs #11's quiet-load runs | P4, G2 | measured for cycle 22: about 1.3 h and 2 points, incomplete (`ORCH:201`, `:203`, `:213`); 2-3 h (`ORCH:29`), 4-6 points (`ORCH:88`) | the fixer's HEAD; a load of 10 or less |
| 18 | Between cycles: findings into rulings | — | records | measured for S3-R28: 4 points in 74 min (`ORCH:221`, `:248`); S3-R27's 6-10 points (`ORCH:93`) | a cycle that blocks |
| 19 | Merge `wp/s3f` `--no-ff` (324 commits, 164 files since `b5796ba`; my git count) | — | P2 | rows 19-26 together: 8-16 h (`ORCH:85`), 10-20 points (`ORCH:89`) | convergence, or the owner's stop |
| 20 | The tools-6.4 check; the phase-A gates | — | gates | in row 19 | row 19 |
| 21 | TSan and `--perf` on an idle host | — | gates, C2 | in row 19 | row 19 |
| 22 | An independent verifier for P-13, judged on its p99 (`feature/asset-kit` `BenchStorage.swift:253`) | follows correct #8 | gates | in row 19 | row 19 |
| 23 | The mutation re-check of the 11 survivors | — | 1(e) | in row 19 | row 19 |
| 24 | ADR-057 through `assetkit-level-docs.js` | — | records | in row 19 | row 15 |
| 25 | Tag `s3-merged`; remove the s3 worktrees and branches only once pushed or archived (N25) | — | records | in row 19 | rows 19-24 |
| 26 | Stage 5: `--full`, `VERIFICATION.md`, `DEVICE-TEST-PLAN.md`, `RESIDUAL-RISKS.md` (`PROMPT.md:64-65`) | — | Done | in row 19 | row 25 |
| 27 | The final archive snapshot (pushing it needs the owner's word, `ORCH:371`) and the dossier's final version (`docs/REOPEN-WP-F.md:132`) | — | records | not estimated | row 26 |

- **Sums** (my sums): rows 1-2, 31-74 h; row 3, 2-3 h; rows 4 and 6, 36-54.5 h; rows 10 and 12, 24.4-33.5 h. Rows 5, 7-9, 11 and 13-16 have no estimate.

## 2. The gates

- **Gated today: a failing assertion in a Benchmarks suite.**
  - `purgeTurns(_:)` runs the nine `PurgeShape` cases (`BenchSyncCycle22Purge.swift:15-33`, `:54-72`). `purgeJoinsTurns(_:)` runs `bucket` and `queue` (`:35-50`, `:139-141`). `purgeWhileOwedTurns` is at `BenchSyncReroutes.swift:70-74`.
  - Each asserts `#expect((waits.min() ?? .infinity) <= Self.c2Budget, …)` (`BenchSyncCycle22Purge.swift:32`, `:49`). `c2Budget = 10.0` lives in the test, because `quality-gates.json` has no C2 key (`BenchSync.swift:124-129`).
  - They are in `SyncBenchmarks`, inside `ZTronAssetKitBenchmarks` (`BenchSync.swift:21-22`; `ZTronAssetKitBenchmarks.swift:11-12`), which `--filter Benchmarks` selects by name (`:6-7`).
  - `perf_tests` runs that filter in release (`Scripts/verify.sh:115`). `--perf` runs it (`:130-132`), and so does `--full` (`:154`; `ORCH:374` says `:153`). A failed step joins `FAILED` (`:48`), and then the run prints `VERIFY: FAIL (…)` (`:164-169`).
- **Recorded, and judged by a verifier.** `commitTwoStalledSubscribersTurns` is the pattern (`BenchSyncCycle21.swift:156-173`): it asserts its setup, prints its figure, and has no C2 expect. A verifier reads the figure by the C2 rule: a best of 3 above 10 ms at a load of 10 or less, in any run, is a miss (`rulings:756-762`).
- **Ungated:** N7's five, N25's three and APM (a probe only, `s3-r28-final.md:157`). None has a case in `Tests/` (my grep for the five names and APM; N25 adds none).
- **The six measured misses**, all gated and red, from the draft's last purge table (after e2-A2.5; best of 3 at loads of 9.09 to 3.33):
  - `oneGroup` 36.14 ms, `oneMemberGroups` 37.17, `oneGroupScope` 39.59 (`s3f.md:7611-7613`); `sharedJobFourGroups` 17.85, `fourGroups` 61.09, `retryJobs` 36.24 (`:7615-7617`). The verifier measured 18.70 to 64.00 (correct #4).
  - Closed: `sharedJob`, `userWaiters`, `ensures` and both joins cases, at 4.63-6.92 (`s3f.md:7614`, `:7618-7621`); `purgeWhileOwedTurns` at 5.01 (`ORCH:187`).
- **N7's five** are not built. N7 gates them, committed red if they miss on `9aa337c` (`s3-r28-final.md:124`). Estimates (`:125-129`): `keptUnderThreeGroups` 38-48 ms today and `fourGroupJoins` 15-22; after route C, `mixedLaneGroups` 24-33, `pendingClaimGroups` 16-18 and `oneMemberGroupsFourPerID` 8-16.
- **What "a known miss" can mean for a gated case.**
  - G1 is not touched: the bar is in the test, not in `quality-gates.json`.
  - Within G3 (`CLAUDE.md:21`), the case stays as written and stays red. The miss is recorded with its figures. `--full` prints `VERIFY: FAIL (1 failed: benchmarks)`, and the report names each cause from the log. S3-R28 already reports cycle 23's close this way, with those misses still blocking (`s3-r28-final.md:199`). P-13 is handled the same way (S3-R26 item 10).
  - Turning the case green needs the owner's explicit G3 word (`CLAUDE.md:3`). Each route to green also runs against the /goal's "passing benchmarks" and its ban on weakening a test to pass (`PROMPT.md:96`):
    - the recorded form above, keeping the setup expects (G4);
    - `withKnownIssue` around the expect (macOS SDK, `Testing.swiftmodule/arm64e-apple-macos.swiftinterface:822-825`), which is green while the miss lasts. Whether it flags a miss that goes away is not checked here (C7);
    - `.disabled`, removing the shape from `allCases`, or moving it out of the Benchmarks tree; or raising `c2Budget`, which also contradicts C2 (`CLAUDE.md:26`).
- **What Done then requires.** `VERIFY: PASS` needs passing benchmarks, 3 consecutive passing test runs, TSan, coverage and the other gates (`PROMPT.md:14`, `:96`). That means:
  - every gated case green in one `--full`;
  - P-13 passing on the merged head, where it is judged on the p99 (`feature/asset-kit` `BenchStorage.swift:253`). `wp/s3f` still asserts the maximum (`:249`), and the p99 has never been measured on the merged head;
  - the flake not firing in any of the 3 runs.
  - With a gated miss red, Done is not met, and the session must "stop and report" (`PROMPT.md:96`). Only the owner can accept that FAIL as the end state. The owner has already set aside Done's Stage 4 clause (`ORCH:617`).
- **At `9aa337c`, by the fixer's report** (`ORCH:189-194`; not re-run for this note): `--quick` and `--gates-only` PASS; Sync ×3; TSan clean; the iOS Simulator suite 1660/1660; Sync coverage 95.06 %. The benchmarks fail only on P-13 and the six, and `--full` was not run.

## 3. The options

### 3.0 Rates and risks
- **Budget.** 55 % at 11:25 (`ORCH:248`) leaves at most 45 points. The use since then (S3-R28's text, f1c, item 3b, this run) is unrecorded, so read `get_usage` first. From 15:06 Fri to Thu 12 Nov 03:00 CET, about 132 h of wall time are left.
- **Points** = fixer hours ÷ k × r + cycles × V + (cycles − 1) × A + P (my formula).
  - r is 0.74 points per fixer hour, measured over cycle 22 (`ORCH:201`); forecasts use 0.65-1.8 (`:88`). The low ends here take 0.65 and the high ends 0.74. At 1.8, the high ends would be about 2.4 times larger.
  - k is the estimated hours done per wall hour: 4 at the low ends, 1 at the high ends. The 4 is my reading of one sample, with low confidence: cycle 22's fixer did steps 0-4 and part of step 7 (`ORCH:184-188`) of work estimated at 35-50 h (`:377`), in 9.4 h (`:183`).
  - V is 2 points (measured, incomplete) to 6; A is 4 (measured) to 10; P is 10-20 points and 8-16 h (rows 17-19). Wall hours = fixer hours ÷ k, plus 1.3-3 h a verification, 1.2-3 h an analysis, and 8-16 h.
- **Cycles.** Cycles 13-19 left 7, 5, ~8, 5, 6, 5 and 8 blockers (`ORCH:484`); cycle 22 left 14 (`s3f-c22-issues.json`). A cycle's own additions keep raising new ones (`ORCH:855`).
- **The risks, and what a user would see.**
  - **R1, ENOSPC** (correct #1, #2; 1(a)). On a near-full disk, the same requests answer `insufficientSpace` after one transfer start, or `ok(100000 B)` after a second start; the follow's timing decides which (`s3-r28-final.md:40-41`). The user sees a different answer depending on timing, and a repeated download.
  - **R2, the flake** (correct #3; 1(d)). A test races its own set-up under heavy load (`s3-r28-final.md:76-78`). It has no product effect, but any `--full` can FAIL in one of its 3 runs.
  - **R3, the six gated misses** (C2). A purge's first turn at 10,000 ids holds the engine actor on one cooperative-pool thread for 17.85-61.09 ms. During it, `resolve` answers, events and progress wait. `lookup` is `@MainActor` and does not wait (`AssetClient.swift:190-191`).
  - **R4, N7's five** (C2). `keptUnderThreeGroups` 38-48 ms today and `fourGroupJoins` 15-22; the other three are estimated only after route C, at 8-33 ms. The effect is R3's.
  - **R5, N25's three** (already ruled known misses). About 500 ms when the origin admits a user request (derived, and today's cost too), otherwise 9-18 ms; then 9-17 and 10-20 ms (estimates; `f3b-review.md:145-147`, `:151`).
  - **R6, APM** (correct #5). Answering 10,000 present members holds the actor 11.10 ms (groups) and 13.93 ms (users). One group, at 9.37 ms, is at the edge. These are measured by probe (`s3-r28-final.md:157`).
  - **R7, item 4** (reqs #2). Unmeasured. A follow or drain turn at k ≥ 4 is estimated at 9-10 ms (`c21/d3-many-holders.md:25-26`, UNCONFIRMED).
  - **R8, mutants and unreached lines** (correct #6, #7; reqs #3, #4). No direct effect, but a later change in those branches can break behaviour with no failing test.
  - **R9, the 429 case** (UNCONFIRMED). From the third attempt, another user's request on the same origin can fail fast where it should wait (`rulings:954`).
  - **R10, records** (reqs #5, #6, #10). ADR-057 and `RESIDUAL-RISKS.md` would misstate the state (G2).
  - **R11, the verification gap** (reqs #7). Cycle 22's "closes" are unproven (`s3-r28-final.md:207`).
  - **R12, the non-blocking items:** reqs #8 (a hang there stalls the suite), reqs #9 (the ownership wording), reqs #11 (`commitTwoTokensTurns` at 9.02 ms), correct #8 (P-13) and correct #10 (recorded as it stands).

### (a) The current plan, minus N25's three
- **Hours:** 93-165 fixer h (my sum), plus every unestimated row. **Points:** 33-196. **Wall:** 35-202 h. **Cycles:** 2-4 likely; a fail-fast stop (N22) can end one early.
- **Usage:** only its low end fits the at most 45 points left. The limit probably cuts it, and it resumes after Thu 12 Nov 03:00.
- **Route C may need all three stages.** Its stage-A upper ends reach 9.5-12.2 ms (`f3-purge-route.md:153-157`). Item 3b closes `mixedLaneGroups` and `oneMemberGroupsFourPerID` only at stage B or C (`f3b-review.md:76-77`). All of these are estimates.
- **Leaves open:** R5 (ruled), R12, and whatever a stop leaves.
- **Records:** N25's heading in `s3f.md`; rows 15, 24, 26 and 27.
- **`--full`:** it can PASS, if every blocker closes and P-13's p99 passes on the merged head.
- **Owner's word:** nothing beyond N25. Stops go to the owner (N22).
- **Re-open:** the three cases only. f3c and its review are still to be written (`docs/REOPEN-WP-F.md:46`). Their closers are 3.5-5.5 h and 2-3 h (`s3-r28-item3b.md:129`), and each shape needs a case, red first.

### (b) (a), with every other C2 purge miss also a known miss
- **Hours:** 57-111 fixer h (rows 1-3, 10 and 12), plus the unestimated rows 8, 9, 11 and 13-16. **Points:** 27-140. **Wall:** 26-142 h. **Cycles:** 2-3.
- **The gated cases.** The six stay red. N7's five are built red as N7 rules; if N7 is withdrawn, they are built as recorded cases to measure them (not estimated) or recorded by estimate only.
  - `:1001` loses route C's `.all` test (row 13), so it needs a test of its own.
- **Leaves open:** R3, R4, R5, R12.
- **Records:** the six and the five go under N25's heading, each with its figure (measured or estimate), its loads, its closer (route C or item 3b) and the re-open criterion. The G3 choice goes in `docs/DECISIONS.md`.
- **`--full`:** FAIL at `benchmarks` while the six are red. It can PASS only with the G3 word (§2).
- **Owner's word:** C2 (`CLAUDE.md:26`) for the eleven shapes; G3 (`:21`) if a PASS is wanted; the /goal (`PROMPT.md:96`).
- **Re-open:** (a)'s list, plus route C (19-28 h) and item 3b (17-26.5 h). Both are re-derived on the merged code, because the `9aa337c` lines will have moved.

### (c) (b), with the ENOSPC windows left as residual risks
- **Hours:** 26-37 fixer h (rows 3, 10 and 12), plus the unestimated rows 8, 9, 11 and 13-16. **Points:** 16-69. **Wall:** 16-62 h. **Cycles:** 1-2.
- **Leaves open:** R1, R3, R4, R5, R12. e1-P1's mutants run on today's code (`s3-r28-final.md:163`).
- **Records:** (b)'s list, plus correct #1 and #2 under "Residual risks (S3-R16)" (`s3f.md:2850`), with their probe logs (`s3-r28-final.md:39`) and f1c's two routes.
- **`--full`:** as for (b).
- **Owner's word:** (b)'s list, plus reversing the owner's own N21 ("Keep it blocking"). N21 is S3-R16 1(a), not a CLAUDE.md rule.
- **Re-open:** (b)'s list, plus item 1b at 31-74 h with step 0, once f1c's review is written.

### (d) Stop WP-F now: merge `9aa337c`, with every open finding recorded
- **Hours** (my estimate, low confidence): 3-6 h of records and about 1 h (1-2 points) for a records check (P4), then rows 19-27. **Points:** 12-26. **Wall:** 10-23 h. **Cycles:** none.
- **Leaves open:** R1-R9, R11, R12. The merge still carries cycle 22's gains, for example `retryJobs` from 571.12 to 36.24 ms (`s3f.md:7617`).
- **Records:** all 14 blocking and 7 non-blocking findings, each with its figure, route and hours, in the draft, ADR-057 and `RESIDUAL-RISKS.md`; the corrected 11.6 record; everything not verified, in `VERIFICATION.md`.
- **`--full`:** FAIL at `benchmarks` (the six), and the flake can also fail a test run.
- **Owner's word:** (c)'s list, plus C2 for R6 and R7, plus closing with S3-R16 1(d) and 1(e) blockers still open (the owner's bar).
- **Re-open:** (c)'s list, plus APM, item 4, the 429 probe, the kills (24.4-33.5 h), the unreached lines and the flake (2-3 h), with a full verification of it all.

### (e) A cut between (c) and (d): stop, with a short close
- **What it is:** (d), plus item 2 (2-3 h), plus signal S1 (§4, 1.5-3 h), plus one short two-lens verification with lens 3's heavy checks first.
- **Hours:** 6.5-12 fixer h (my sum). **Points:** 13-35. **Wall:** 11-31 h. **Cycles:** 1.
- **Leaves open:** R1, R3-R9, R12. It closes R2 and R10, and R11 too if the heavy checks run.
- **`--full`:** as for (d), but without the flake's risk.
- **Owner's word:** as for (d).
- **Re-open:** as for (d) without the flake, and it starts with field data.

| Option | Fixer h | Points | Wall h | Cycles | `--full` PASS? | Left open |
|---|---|---|---|---|---|---|
| (a) | 93-165 + unestimated | 33-196 | 35-202 | 2-4 | yes, if every blocker closes | R5, R12 |
| (b) | 57-111 + unestimated | 27-140 | 26-142 | 2-3 | only with the G3 word | R3-R5, R12 |
| (c) | 26-37 + unestimated | 16-69 | 16-62 | 1-2 | only with the G3 word | R1, R3-R5, R12 |
| (d) | 3-6 + a check | 12-26 | 10-23 | 0 | only with the G3 word, and no flake | R1-R9, R11, R12 |
| (e) | 6.5-12 | 13-35 | 11-31 | 1 | only with the G3 word | R1, R3-R9, R12 |

## 4. The field signal

- **Today the kit cannot show how often the misses happen.**
  - The unified log and the signposts exist (`AssetLog.swift:3`, `:24`, `:29-30`; `OSLogSink` in `.live()`, `AssetEnvironment.swift:29-31`).
  - Six interval names are public (`AssetLog.swift:158-171`; R-OBS-1, `SPEC.md:272`). Sync's only interval is `.plan`, around a sync run (`EngineRuns.swift:197`).
  - Sync writes two log lines: a fault (`EngineJobs.swift:29`) and one error per failure (`:1217`). Neither is in `performPurge` (`EngineCommands.swift:963-990`).
  - The purge's first turn is marked only by the test seam `commitTurnMarksForTests` (`EngineCommands.swift:968`, `:976`; `EngineState.swift:94`).
  - `MetricsSnapshot` counts retries and failures by class, with no durations (`Reports.swift:264`, `:274`, `:276`). `diagnosticReport()` keeps the last 32 errors (`EngineSupport.swift:113-116`). `AssetEvent` has no stall event (`AssetEvent.swift:123-150`).
  - Only R1 has a partial count, `failures.insufficientSpace` (`Reports.swift:186`). It cannot tell which answers the order changed.
- **S1, one log line, with no public API change.**
  - At `:968` and `:976`, read the injected `monotonicNow()` (as `EngineManifest.swift:140` does) and take `seconds(since:)` (`Time.swift:40`). Above 10 ms, write one `.info` line on `.sync` with the milliseconds, the job count and the group count. The levels are debug, info, error and fault (`EnvironmentSeams.swift:36-45`).
  - The app can read the line in its own process: `AssetEnvironment.logSink` is a public var, and `LogLine`'s fields are public (`AssetEnvironment.swift:31`; `EnvironmentSeams.swift:55-66`; `AssetLog.swift:64-69`).
  - It can also read its own log with `OSLogStore`, iOS 15.0+ (iOS SDK, `OSLog.framework/Headers/Store.h:28`, `:88-90`). Whether `.info` lines are kept for that read is not checked (C7).
  - Hours: 1.5-3 h (estimate, at f3's 1-1.5 h a part, `f3-purge-route.md:336`), with a test through `logTap` and a time source that advances. It touches only WP-F's file. The line's text becomes a soft contract, to be recorded in `docs/DECISIONS.md`.
  - It covers every purge shape, R3-R5 included. APM and item 4 would each need a site of their own (0.5-1 h each, estimate).
  - A device's turn time includes preemption, so the counts on the line are what tie a long turn to a shape.
- **S2, a `MetricsSnapshot` counter.** It changes a public Codable struct (`Reports.swift:264`): NEEDS-HUMAN-REVIEW. It touches WP-A's model and WP-G's facade as well as WP-F (`PROMPT.md:71`, `:77`). 3-5 h (estimate). The app reads it through `metrics()` (`AssetClient.swift:346`).
- **S3, a `diagnosticReport()` key.** The report is public JSON (R-OBS-3, `SPEC.md:274`): NEEDS-HUMAN-REVIEW. 2-4 h (estimate). It reaches only the reports users send.
- **S4, a `.purge` interval.** It adds a case to a public enum (`AssetLog.swift:158`) and goes past R-OBS-1's list: NEEDS-HUMAN-REVIEW. 1.5-2.5 h (estimate). Instruments can show it.
  - It might also reach MetricKit through the app's own `LogSink`, by `OSSignposter(logHandle:)` (iOS 15.0+, `os.swiftinterface:1900`, `:1913`) on `makeLogHandle(category:)` (`MXMetricManager.h:60`, deprecated for `MetricManager.logHandle`; aggregation per `MXSignpostMetric.h:67`). That path is UNVERIFIED (C7).
- **N0, no code in the kit.**
  - Purges are user-initiated (R-CLN-6, `SPEC.md:250`). The app can count its own `purge` calls (`AssetClient.swift:324`), with the ids and groups it holds at each call.
  - Scaling the figures at 10,000 ids linearly gives where 10 ms is passed:
    - about 1,600 ids (`fourGroups`) to about 5,600 (`sharedJobFourGroups`), and 2,500-2,800 for the other four;
    - for R5's first case, about 190 failed user jobs with `.retry` deadlines (10 ms ÷ 53 µs, `f3b-review.md:151`).
    - These are derived, with low confidence: the scaling ignores the sort and the fixed costs, and the Mac-to-device ratio is unmeasured.

## 5. Open questions for the owner
1. Which option do you choose: (a), (b), (c), (d) or (e)?
2. Under (b) to (e), for the six gated cases: is `VERIFY: FAIL (benchmarks)` accepted as WP-F's end state, or do you give the explicit G3 word to make them recorded and not gated?
3. Under (b) or (c): are N7's five built as recorded cases to measure them, or recorded by their estimates only?
4. Which field signal: S1, S2, S3, S4, or N0 alone?
5. May the final archive snapshot be pushed to `origin` at the close, as the 14:46 one was?
