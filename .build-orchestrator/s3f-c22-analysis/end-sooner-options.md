# Ending WP-F sooner: the open work, the gates and the options, priced

For the owner. Written 6 Nov 2026, about 15:15 CET, read-only, at `wp/s3f` `9aa337c`. Revised about 16:30 CET with every must-fix item of its independent check (`end-sooner-options-review.md`, CORRECTED), each fact re-verified first; the copy before is `end-sooner-options-v1.md`. Of the check's should-fix items, only the moved ORCH citations are applied. Nothing was built, run or tested for either version.
- Every hour and point figure is an **estimate** unless it says "measured". "My sum" and "my estimate" mean this note made it (G2).
- Paths: analysis files are in this folder; `c21/` is `.build-orchestrator/s3f-c21-analysis/`; `rulings` is `.build-orchestrator/s3-rulings-s3f.md` (1,683 lines at 16:15); N-n is in `s3-r28-orchestrator-rulings.md` (N1-N30); `ORCH` is `docs/ORCHESTRATION.md`, cited at `df79d98` (16:16; its lines move); `s3f.md` is WP-F's draft. Code is cited at `9aa337c` in `.worktrees/s3f`; `wp/s3f`'s HEAD, `247e85b` (16:12), has the same sources (my `git diff 9aa337c HEAD -- Sources` is empty). Draft lines are at `9aa337c` unless a commit is named.
- **Since v1:** the owner's ruling N28, which N29 scopes to correct #1 and #2, makes them known residual risks (item 1c and its amendment, rulings:1582-1664). Run 11 committed rows 3 and 7 and `--quick` on HEAD, and returned at its working budget at 16:12 (ORCH:415-420). Run 12 runs from 16:16, with rows 10-12 and 14 first, then the records that no C2 route changes (N30; rulings:1666-1683). The owner's ruling on the remaining C2 work is pending (rulings:1657, :1668).
- This note prices the options and recommends none. The re-open dossier v1 (`docs/REOPEN-WP-F.md`, untracked, last changed 15:45) points here for §4.

## 1. The ledger

S3-R28's order of work (`s3-r28-final.md:183-199`), as item 1c, its amendment and run 12's order change it (rulings:1582-1683), then item 6 and the post-convergence list (`ORCH:657`). "Closes" is item 7's mapping (`s3-r28-final.md:215-227`), with item 1c's (rulings:1602).

| # | Obligation | Closes | Basis | Hours (estimate; source) | Depends on |
|---|---|---|---|---|---|
| 1 | Step 0 as amended: `verify.sh --quick` on HEAD, which replaces the run on `9aa337c` (rulings:1655); the 'before' figures for item 3's cases and S3-R27 items 3-4, unless the owner drops that work (rulings:1657-1658); without a ruling they follow run 12's first two steps (:1681). Run 11 reports `--quick` PASS on `9aa337c` and on HEAD, and item 3's five cases written in a scratch copy, not run (`be8804a`, `247e85b`; ORCH:418-419) | nothing alone | records, G2 | not estimated; the step-0 shapes and their 13-26 h left with item 1c (rulings:1586-1590, :1601) | — |
| 2 | Item 1c as amended (N29): correct #1 and #2 are known residual risks for their S3-R16 1(a) answers only; any other ENOSPC-window answer difference blocks under N21 and goes to the owner at once; 1(b)-1(f) still block, the e1 kills included (rulings:1622-1639) | correct #1, #2, by ruling | the owner's ruling N28, as N29 scopes it | 0 h: item 1b is withdrawn under every option | the owner's answer on the whole class (ORCH:414; rulings:1636) |
| 3 | Step 1, item 2: the flake (f2-R1's probe, then A-T-SD's change); in as `03c4e59` (15:44), not verified | correct #3 | 1(d) | 2-3 h, or 1-1.5 h with shared close runs (`s3-r28-final.md:94`); spent in run 11 | — |
| 4 | Steps 2-3, item 3: route C, stages A, B, C | correct #4, reqs #1 | C2 and 1(f). As ruled, option (i)'s C-2′ breaks R-SYN-3 (`SPEC.md:228`, a MUST: 1(b)) for a kept claim-held job. N9's skipped re-lane leaves `queuedAt` and `lastTicket` stale and drops a `notifyObservers`. Item 3b re-checks both (rulings:1447; `f3b-review.md:35-37`, `:89-92`, `:97-100`) | 19-28 h (`f3-purge-route.md:343`, `:363`), without option (i) or the five new cases (`s3-r28-final.md:154`) | the extended audits (`s3-r28-final.md:186-187`); N23's stage trigger; item 3b's append. Step 2 waits for it, and steps 4-5 go first meanwhile (rulings:1446, :1507). Item 3b's text has its review's six must-fix items (`s3-r28-item3b.md`, 16:14; review CORRECTED, `s3-r28-item3b-review.md`, 15:41), but it is not appended: it waits for the owner's C2 ruling (ORCH:428), and rulings ends with run 12's order (:1666) |
| 5 | N7's five new purge cases, gated BenchSync cases, red first | correct #4, reqs #1 | C2 | not estimated (`s3-r28-final.md:154`); written in a scratch copy, not built or run (`be8804a`) | row 1's 'before' figures |
| 6 | Item 3b: the merged route, M-0 to M-5 | the five, by estimate; two only at stage B or C (`s3-r28-item3b.md:3`) | C2 | core 17-26.5 h, on top of route C (`s3-r28-item3b.md:126-129`) | its append (rulings:1426-1433), with its review's must-fix items, now applied (ORCH:428); the owner's C2 ruling. Its code then builds on row 4 (`s3-r28-final.md:194`) |
| 7 | N25's and item 1c's records: in as `4b38eb4` (15:50); item 1c's amended to N29 on a commit of its own (rulings:1656), `5e518b8` (16:02) | — | records | spent in run 11; not verified | — |
| 8 | Step 4 (S3-R27 step 5): APM's answer turn | correct #5; reqs #2 with row 9 | 1(f), C2 | not estimated; cycle 22's lump for S3-R27 items 1-3 was 10-15 h (`ORCH:435`) | d2's route (a) and B1 (`rulings:832`); the owner's C2 ruling (rulings:1657) |
| 9 | Step 5 (S3-R27 step 6): item 4, the k = 2 and k = 4 shapes | reqs #2; correct #9 (not blocking) | C2 | not estimated | A1, A2 if taken; the owner's C2 ruling (rulings:1657) |
| 10 | Step 6: d4's kills, steps 6-12 | correct #7; reqs #3, with rows 11 and 12 | 1(e) | writing 14.5-18.5 h with r2b argued in the draft (rulings:947), 18-24 h with r2b built; 14 runs (16 with r2b built) at 10-15 min, 2.3-4 h (`c21/d4-survivors.md:517-523`, `:525-531`; my sum) | none: it is outside the purge code, and run 12 takes it first (rulings:1670-1672) |
| 11 | Step 6: the 429 default-tuning probe | reqs #3, with rows 10 and 12 | running it: a ruled step (rulings:954-958), blocking under reqs #3; what it finds: S3-R16 item 2, or 1(a) | not estimated | run 12 takes it first (rulings:1672) |
| 12 | Step 6: e1-R1's rewritten mutants; the e1-PS, e1-P1, e1-P2 kills | reqs #3, with rows 10 and 11 | 1(e) | e1-R1: 3.7-5.5 h of runs (`s3-r28-final.md:210`); the rest not estimated | none; the kills run on the code as it stands (rulings:1639), and run 12 takes them first (:1671) |
| 13 | Step 6: the unreached `EngineCommands.swift:1001`, `:1004`, `:1009` | correct #6, reqs #4 | 1(e) | not estimated | the owner's C2 ruling (rulings:1682); `:1001`'s reach is route C's new `.all` test (`s3-r28-final.md:172`) |
| 14 | Step 6: reqs #8's guard, `.timeLimit(.minutes(1))` at `SubscriberQueueBatchTests.swift:95` | reqs #8 (not blocking) | a guard; G3 holds | not estimated (minutes) | run 12 takes it first (rulings:1673) |
| 15 | Step 7 (S3-R27 step 8): every missing record, the false 11.6 record (`s3f.md:6959` against `:8212`) included | reqs #5, #6, #9, #10 | records, G2 | not estimated | rows 1-14; run 12 takes the records that no C2 route changes second (rulings:1674-1678) |
| 16 | Step 7: item 9 and the close, every gate and `--full` on the final HEAD (`s3-r28-final.md:199`) | correct #8 reported as WP-B's; correct #10 no action | gates | not estimated | rows 1-15 |
| 17 | Item 6: two-lens verification, lens 3's heavy checks first (`s3-r28-final.md:205`) | reqs #7; reqs #11's quiet-load runs | P4, G2 | measured for cycle 22: about 1.3 h and 2 points, incomplete (`ORCH:201`, `:203`, `:213`); 2-3 h (`ORCH:29`), 4-6 points (`ORCH:88`) | the fixer's HEAD; a load of 10 or less |
| 18 | Between cycles: findings into rulings | — | records | measured, account-wide: S3-R28 ran from 51 % at 10:05 (ORCH:213) to 66 % at 14:27 and 71 % at 15:23 (ORCH:389), about 15-20 points over 4.4-5.3 h. The 4 points in 74 min (ORCH:221, :248) were its first analysis run only. S3-R27's was 6-10 points (ORCH:93) | a cycle that blocks |
| 19 | Merge `wp/s3f` `--no-ff` (329 commits, 164 files since `b5796ba`, at `247e85b`; my git count) | — | P2 | rows 19-26 together: 8-16 h (`ORCH:85`), 10-20 points (`ORCH:89`) | convergence, or the owner's stop |
| 20 | The tools-6.4 check; the phase-A gates | — | gates | in row 19 | row 19 |
| 21 | TSan and `--perf` on an idle host | — | gates, C2 | in row 19 | row 19 |
| 22 | An independent verifier for P-13, judged on its p99 (`feature/asset-kit` `BenchStorage.swift:253`) | follows correct #8 | gates | in row 19 | row 19 |
| 23 | The mutation re-check of the 11 survivors | — | 1(e) | in row 19 | row 19 |
| 24 | ADR-057 through `assetkit-level-docs.js` | — | records | in row 19 | row 15 |
| 25 | Tag `s3-merged`; remove the s3 worktrees and branches only once pushed or archived (N25) | — | records | in row 19 | rows 19-24 |
| 26 | Stage 5: `--full`, `VERIFICATION.md`, `DEVICE-TEST-PLAN.md`, `RESIDUAL-RISKS.md` (`PROMPT.md:64-65`) | — | Done | in row 19 | row 25 |
| 27 | The final archive snapshot (pushing it needs the owner's word, `ORCH:371`) and the dossier's final version (`docs/REOPEN-WP-F.md:135`) | — | records | not estimated | row 26 |

- **Sums** (my sums): row 3, 2-3 h, spent; rows 4 and 6, 36-54.5 h; rows 10 and 12, 20.5-33.5 h. Rows 1, 5, 8, 9, 11 and 13-16 have no estimate; row 2 is 0 h, and row 7 is spent.

## 2. The gates

- **Gated today: a failing assertion in a Benchmarks suite.**
  - `purgeTurns(_:)` runs the nine `PurgeShape` cases (`BenchSyncCycle22Purge.swift:15-33`, `:54-72`). `purgeJoinsTurns(_:)` runs `bucket` and `queue` (`:35-50`, `:139-141`). `purgeWhileOwedTurns` is at `BenchSyncReroutes.swift:70-74`.
  - Each asserts `#expect((waits.min() ?? .infinity) <= Self.c2Budget, …)` (`BenchSyncCycle22Purge.swift:32`, `:49`). `c2Budget = 10.0` lives in the test, because `quality-gates.json` has no C2 key (`BenchSync.swift:124-129`).
  - They are in `SyncBenchmarks`, inside `ZTronAssetKitBenchmarks` (`BenchSync.swift:21-22`; `ZTronAssetKitBenchmarks.swift:11-12`), which `--filter Benchmarks` selects by name (`:6-7`).
  - `perf_tests` runs that filter in release (`Scripts/verify.sh:115`). `--perf` runs it (`:130-132`), and so does `--full` (`:154`; `ORCH:374` says `:153`). A failed step joins `FAILED` (`:48`), and then the run prints `VERIFY: FAIL (…)` (`:164-169`).
- **Recorded, and judged by a verifier.** `commitTwoStalledSubscribersTurns` is the pattern (`BenchSyncCycle21.swift:156-173`): it asserts its setup, prints its figure, and has no C2 expect. A verifier reads the figure by the C2 rule: a best of 3 above 10 ms at a load of 10 or less, in any run, is a miss (`rulings:756-762`).
- **Ungated:** N7's five, N25's three, APM (a probe only, `s3-r28-final.md:157`), f3b-review §7's two variants (`f3b-review.md:148-149`; measured as variants of item 3b's cases, rulings:1445) and route A §9's third shape (`f3b-route-a.md:173`; item 3b's M-4 routes it, `s3-r28-item3b.md:90`). None has a case in `Tests/` at HEAD (my grep for the five names, `purgeInLetterTurns` and APM; N25 adds none).
- **The six measured misses**, all gated and red, from the draft's last purge table (after e2-A2.5; best of 3 at loads of 9.09 to 3.33):
  - `oneGroup` 36.14 ms, `oneMemberGroups` 37.17, `oneGroupScope` 39.59 (`s3f.md:7611-7613`); `sharedJobFourGroups` 17.85, `fourGroups` 61.09, `retryJobs` 36.24 (`:7615-7617`). The verifier measured 18.70 to 64.00 (correct #4).
  - Closed: `sharedJob`, `userWaiters`, `ensures` and both joins cases, at 4.63-6.92 (`s3f.md:7614`, `:7618-7621`); `purgeWhileOwedTurns` at 5.01 (`ORCH:187`).
- **N7's five** are written in a scratch copy, `.build-s3f/c23/bench0`, and not built or run (`be8804a`; ORCH:419). N7 gates them, committed red if they miss on `9aa337c` (`s3-r28-final.md:124`). Estimates (`:125-129`): `keptUnderThreeGroups` 38-48 ms today and `fourGroupJoins` 15-22; after route C, `mixedLaneGroups` 24-33, `pendingClaimGroups` 16-18 and `oneMemberGroupsFourPerID` 8-16.
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
  - With a gated miss red, Done is not met, and the session must "stop and report" (`PROMPT.md:96`). Only the owner can accept that FAIL as the end state. The owner has already set aside Done's Stage 4 clause (`ORCH:675`).
- **At `9aa337c`, by the fixer's report** (`ORCH:189-194`; not re-run for this note): `--quick` and `--gates-only` PASS; Sync ×3; TSan clean; the iOS Simulator suite 1660/1660; Sync coverage 95.06 %. The benchmarks fail only on P-13 and the six, and `--full` was not run.
  - Run 11 adds, by its report, `--quick` PASS on `9aa337c` and on HEAD (`be8804a`, `247e85b`; ORCH:418). The rest of the gate set was not run on HEAD (`be8804a`).

## 3. The options

### 3.0 Rates and risks
- **Budget.** 71 % at 15:23 (ORCH:389, measured) leaves at most 29 points, less what has run since: run 11 until 16:13 (ORCH:402, :415-420), at about 1.1 points an hour for the fixer alone (ORCH:389, an estimate); run 12 from 16:16 (ORCH:426); and the checks, finishers and the orchestrator. So read `get_usage` first. From 16:30 Fri to Thu 12 Nov 03:00 CET, about 130 h of wall time are left.
- **Points** = fixer hours ÷ k × r + cycles × V + (cycles − 1) × A + P (my formula).
  - r: the low ends take 0.65 points an hour and the high ends 0.74; forecasts use 0.65-1.8 (`ORCH:88`). 0.74 is an account-wide rate, measured 02:00-08:46 (ORCH:201), not a rate per fixer hour. ORCH:389 forecasts about 1.1 for the fixer alone. At 1.8, the fixer term would be about 2.4 times larger.
  - k is the estimated hours done per wall hour: 4 at the low ends, 1 at the high ends. **k is not measured.**
    - v1 read 4 from cycle 22's fixer: steps 0-4 and part of step 7 (`ORCH:184-188`) in 9.4 h (`:183`). But the 35-50 h it used (ORCH:435) is the 19:40 forecast for all of cycle 22, and it includes D4's 24-30 h, which the fixer did not start (ORCH:198). With item 12, the forecast was 55-90 h (ORCH:153).
    - Two later samples point opposite ways. Run 11 did row 3 (2-3 h, an estimate) in about 11 min: launched at 15:34 (ORCH:402), committed at 15:44:53. It returned at its working budget at 16:12, its context 85 % full at 15:57 (ORCH:415). ORCH:389's forecast implies k below about 2-2.75 for cycle 23 (my reading).
  - V (row 17) is 2-6 points: 2 is a floor, from an incomplete run, and ORCH:88 forecasts 4-6. A (row 18) is 6-20 points and 1.2-5.3 h. P (rows 19-26) is 10-20 points and 8-16 h. Wall hours = fixer hours ÷ k, plus 1.3-3 h a verification, 1.2-5.3 h an analysis, and 8-16 h.
- **Cycles.** Cycles 13-19 left 7, 5, ~8, 5, 6, 5 and 8 blockers (`ORCH:542`); cycle 22 left 14 (`s3f-c22-issues.json`). A cycle's own additions keep raising new ones (`ORCH:913`).
- **The risks, and what a user would see.**
  - **R1, ENOSPC** (correct #1, #2; 1(a); a known residual risk by N28 and N29). On a near-full disk, the same requests answer `insufficientSpace` after one transfer start, or `ok(100000 B)` after a second start; the follow's timing decides which (`s3-r28-final.md:40-41`). The user sees a different answer depending on timing, and a repeated download. The probes cap retries at one attempt and script the second to succeed (rulings:1647-1650).
  - **R2, the flake** (correct #3; 1(d)). A test races its own set-up under heavy load (`s3-r28-final.md:76-78`). It has no product effect, but any `--full` can FAIL in one of its 3 runs. Row 3's fix is in, not verified.
  - **R3, the six gated misses** (C2). A purge's first turn at 10,000 ids holds the engine actor on one cooperative-pool thread for 17.85-61.09 ms. During it, `resolve` answers, events and progress wait. `lookup` is `@MainActor` and does not wait (`AssetClient.swift:190-191`).
  - **R4, N7's five, and three in-letter shapes with no case** (C2). `keptUnderThreeGroups` 38-48 ms today and `fourGroupJoins` 15-22; the other three are estimated only after route C, at 8-33 ms. f3b-review §7's two variants (`fourGroupJoins` over 40,000 one-member groups, 3-11.5 ms; three kept interests over one purged one, 4.5-8.9 ms) are estimated only after route C and item 3b's merge (`f3b-review.md:148-149`), and route A §9's third shape (a prefetch waiter under three groups) at 6-10 ms after route C and route A's A-2 (`f3b-route-a.md:173`). None of the three has a figure for today. The effect is R3's.
  - **R5, N25's three** (ruled known misses).
    - Today, case 1 takes about 500 ms when the origin admits a user request (derived; the heap scan is today's cost too, `f3b-review.md:151`). No analysis gives a figure for today for case 1's other path, case 2 or case 3.
    - After route C and item 3b's merge, which happen only under (a): 9-18, 9-17 and 10-20 ms (estimates, `f3b-review.md:143-147`). f3c itemises them at 11.9-22.5, 13.7-24.9 and 12.5-23.8 ms (`f3c-open-shapes.md:87-89`). Its review corrects case 2 to 12.9-23.3 ms and case 3 to about 21-34 ms (estimates, `f3c-open-shapes-review.md:37`, `:59`, 15:57).
    - In production, both of case 1's paths cost 15-60 ms more, today and after, from `originID` builds that the benches' fake hides (estimate, `f3c-open-shapes.md:95`).
    - The draft's own record already labels the figures "after route C and item 3b's merge … none measured" (`s3f.md:8129` at `247e85b`; `:8073` at `4b38eb4`).
  - **R6, APM** (correct #5). Answering 10,000 present members holds the actor 11.10 ms (groups) and 13.93 ms (users). One group, at 9.37 ms, is at the edge. These are measured by probe (`s3-r28-final.md:157`).
  - **R7, item 4** (reqs #2). Unmeasured. A follow or drain turn at k ≥ 4 is estimated at 9-10 ms (`c21/d3-many-holders.md:25-26`, UNCONFIRMED).
  - **R8, mutants and unreached lines** (correct #6, #7; reqs #3, #4). No direct effect, but a later change in those branches can break behaviour with no failing test.
  - **R9, the 429 case** (UNCONFIRMED; its probe is part of reqs #3, row 11). From the third attempt, another user's request on the same origin can fail fast where it should wait (`rulings:954`).
  - **R10, records** (reqs #5, #6, #10). ADR-057 and `RESIDUAL-RISKS.md` would misstate the state (G2).
  - **R11, the verification gap** (reqs #7). Cycle 22's "closes" are unproven (`s3-r28-final.md:207`).
  - **R12, the non-blocking items:** reqs #8 (a hang there stalls the suite), reqs #9 (the ownership wording), reqs #11 (`commitTwoTokensTurns` at 9.02 ms), correct #8 (P-13) and correct #10 (recorded as it stands).

### (a) The current plan, minus N25's three and item 1b
- **Hours:** 58.5-91 fixer h (rows 3, 4, 6, 10, 12; my sum, estimates; 56.5-88 h now, with row 3 spent), plus the unestimated rows, and the orchestrator's append of item 3b. **Points:** 29.5-171. **Wall:** 26-135 h. **Cycles:** 2-4 likely; a fail-fast stop (N22) can end one early.
- **Usage:** it does not fit the at most 29 points left at 15:23, even at its low end. The limit cuts it, and it resumes after Thu 12 Nov 03:00.
- **Route C waits for item 3b's append** (row 4): as ruled, option (i)'s C-2′ is a 1(b) risk, so route C cannot start as ruled without that risk. Item 3b's text is ready and waits for the owner's C2 ruling (ORCH:428).
- **Route C may need all three stages.** Its stage-A upper ends reach 9.5-12.2 ms (`f3-purge-route.md:153-157`). Item 3b closes `mixedLaneGroups` and `oneMemberGroupsFourPerID` only at stage B or C (`f3b-review.md:76-77`). All of these are estimates.
- **Leaves open:** R1 and R5 (both ruled), R12, and whatever a stop leaves.
- **Records:** N25's and item 1c's are in (row 7); rows 15, 24, 26 and 27.
- **`--full`:** it can PASS only if every blocker closes, P-13 passes on the merged head, and no flake fires in the 3 test runs. P-13 is judged on its p99 (`feature/asset-kit` `BenchStorage.swift:253`), never measured on the merged head; `wp/s3f`'s maximum fails it today (`:249`; correct #8, 8.818 ms against 5.0). A red `benchmarks` step blocks Done (S3-R16 1(f), rulings:160; `PROMPT.md:96`).
- **Owner's word:** N25 and N28 are given; N29, the orchestrator's, scopes N28 to correct #1 and #2. The owner is deciding on items 3 and 3b, S3-R27 items 3-4 (rulings:1616, :1657) and the ENOSPC class (ORCH:414). Stops go to the owner (N22).
- **Re-open:**
  - N25's three: f3c's route, core 12-18.5 h plus 4-6.5 h for OS-4, OS-5 and OS-0, with stage C not estimated, nor the A7 audit that its review's must-fix 3 moves into the core (`f3c-open-shapes.md:171-180`; OS-6 is dropped by `f3c-open-shapes-review.md:38`). Even at stage C, failedUserRetries' top, 10.8 ms, misses (review :75).
  - Correct #1 and #2: route Q, 44-67 h plus a 3-5 h check. It leaves four shapes that block if red, with no route (`f1c-review.md:136-144`, `:175-176`).

### (b) Merged into (c)
- After N28 and N29, correct #1 and #2 are known residual risks under every option (row 2), so v1's (b) and (c) are one option. (c) below carries (b)'s content.

### (c) (a), with every other C2 purge miss also a known miss
- **What it drops:** items 3 and 3b (rows 4 and 6) together, with item 3's 'before' figures (rulings:1616, :1657).
- **Hours:** 22.5-36.5 fixer h (rows 3, 10 and 12; 20.5-33.5 h now, with row 3 spent), plus the unestimated rows 8, 9, 11 and 13-16. **Points:** 16-79. **Wall:** 15-64 h. **Cycles:** 1-2.
- **The gated cases.** The six stay red. N7's five are known misses under this option, so they follow N25's and N28's precedent: no code, test or bench (rulings:1439, :1590), and a record by estimate. Their scratch copy (`be8804a`) stays uncommitted. Building them red would add up to five red gated cases, and `--full` would then need the G3 word for up to eleven.
  - `:1001` loses route C's `.all` test (row 13), so it needs a test of its own.
- **Leaves open:** R1 (ruled), R3, R4, R5 (ruled), R12.
- **Records:** under N25's heading:
  - the six; N7's five;
  - f3b-review §7's two variants (`fourGroupJoins` 3-11.5 ms and three-kept 4.5-8.9 ms, after route C and item 3b's merge; `f3b-review.md:148-149`; rulings:1445);
  - and route A §9's third shape (a prefetch waiter under three groups, 6-10 ms after route C and route A's A-2, and 3-5.5 ms with A-3b; `f3b-route-a.md:173`), which only item 3b's M-4 closes (`s3-r28-item3b.md:90`; N26 O2).
  - Each goes with its figure (measured with its loads, or estimate), its closer and the re-open criterion. The two variants and the third shape have no figure for today.
  - The G3 choice goes in `docs/DECISIONS.md`. Correct #1 and #2 are already under "Known residual correctness risks (owner ruling 2026-11-06)" (rulings:1604; `s3f.md:8027` at `247e85b`), as under every option.
- **`--full`:** FAIL at `benchmarks` while the six are red. It can PASS only with the G3 word for every red gated case (§2), and if P-13 passes on the merged head, where it is judged on its p99, never measured there; `wp/s3f`'s maximum fails it today (correct #8, 8.818 ms against 5.0; (a)).
- **Owner's word:** C2 (`CLAUDE.md:26`) for the six, N7's five, the two variants and the third shape; G3 (`:21`) if a PASS is wanted; the /goal (`PROMPT.md:96`). N28 and N29 already exempt correct #1 and #2, and N21 stands for the rest of the ENOSPC class until the owner answers ORCH:414.
- **Re-open:** (a)'s list, plus route C (19-28 h) and item 3b (17-26.5 h). Both are re-derived on the merged code, because the `9aa337c` lines will have moved.

### (c′) (c), with S3-R27 steps 5 and 6 also known misses
- **What it is:** (c), with rows 8 and 9 also known misses: S3-R27 steps 5-6, correct #5 and reqs #2 (rulings:1657).
- **Hours:** (c)'s, with two fewer unestimated rows. **Points:** 16-79. **Wall:** 15-64 h. **Cycles:** 1-2.
- **The gated cases:** (c)'s. It adds no red gated case: APM is a probe only (`s3-r28-final.md:157`), and item 4 has no case (correct #9).
- **Leaves open:** R1, R3-R7, R12.
- **Records:** (c)'s, plus APM's probe figures (R6) and item 4's unmeasured shapes (R7).
- **`--full`:** as for (c).
- **Owner's word:** (c)'s, plus C2 for R6 and R7.
- **Re-open:** (c)'s list, plus APM (d2's route (a) and B1, `rulings:832`) and item 4, neither estimated.

### (d) Stop WP-F now: merge HEAD, with every open finding recorded
- **What it merges:** `wp/s3f`'s HEAD at the stop, not `9aa337c`: `247e85b` at 16:12, with row 3's fix in, not verified, plus whatever run 12 has committed by then.
- **Hours** (my estimate, low confidence): 3-6 h of records and about 1 h (1-2 points) for a records check (P4), then rows 19-27. **Points:** 12-26. **Wall:** 10-23 h. **Cycles:** none.
- **Leaves open:** R1-R9, R11, R12; R2's fix is in, unverified. The merge still carries cycle 22's gains, for example `retryJobs` from 571.12 to 36.24 ms (`s3f.md:7617`).
- **Records:** all 14 blocking and 7 non-blocking findings, each with its figure, route and hours, in the draft, ADR-057 and `RESIDUAL-RISKS.md`; the corrected 11.6 record; everything not verified, in `VERIFICATION.md`.
- **`--full`:** FAIL at `benchmarks` (the six, and P-13 as in (c)). It can PASS only as for (c), and if the flake does not fire in any of the 3 test runs, since nothing verifies row 3's fix.
- **Owner's word:** (c′)'s list, plus closing with S3-R16 1(e) blockers open and 1(d)'s fix unverified (the owner's bar).
- **Re-open:** (c′)'s list, plus the 429 probe, the kills (20.5-33.5 h, less what run 12 commits), the unreached lines and a check of row 3's fix, with a full verification of it all.

### (e) A cut between (c) and (d): stop, with a short close
- **What it is:** (d), plus signal S1 (§4, 1.5-3 h), plus one short two-lens verification with lens 3's heavy checks first. Item 2 is already in (row 3), so the verification checks it.
- **Hours:** 4.5-9 fixer h now (my sum; 6.5-12 with row 3's spent 2-3 h, as v1 counted it). **Points:** 13-35. **Wall:** 11-31 h. **Cycles:** 1.
- **Leaves open:** R1, R3-R9, R12. It closes R2 if its verification confirms row 3's fix, and R10, and R11 too if the heavy checks run.
- **`--full`:** as for (d), P-13 included; its verification checks row 3's fix.
- **Owner's word:** as for (d).
- **Re-open:** as for (d), without the check of row 3's fix. S1's line is in place for when an app adopts the kit (not planned; §4).

| Option | Fixer h | Points | Wall h | Cycles | `--full` PASS? | Left open |
|---|---|---|---|---|---|---|
| (a) | 58.5-91 (56.5-88 now) + unestimated | 29.5-171 | 26-135 | 2-4 | only if every blocker closes, P-13's p99 passes on the merged head, and no flake fires | R1, R5 (both ruled), R12 |
| (c) | 22.5-36.5 (20.5-33.5 now) + unestimated | 16-79 | 15-64 | 1-2 | only with the G3 word for every red gated case, and P-13 as in (a) | R1, R3-R5, R12 |
| (c′) | 22.5-36.5 (20.5-33.5 now) + fewer unestimated | 16-79 | 15-64 | 1-2 | as (c) | R1, R3-R7, R12 |
| (d) | 3-6 + a check | 12-26 | 10-23 | 0 | as (c), and no flake | R1-R9, R11, R12 |
| (e) | 6.5-12 (4.5-9 now) | 13-35 | 11-31 | 1 | as (c) | R1, R3-R9, R12 |

- **Basis** (estimates; the formula in §3.0 with A = 6-20, and rows 10 and 12 at 20.5-33.5 h; my arithmetic). Points and wall hours count row 3's spent 2-3 h, as v1 did. "Now" drops them: the points are then about 29-169 for (a), 15-77 for (c) and (c′) and 13-33 for (e), and the wall hours 26-132, 14-61 and 10-28.
- **Every PASS** also needs the 3 test runs green, so the flake must not fire in any of them. Row 3's fix for it is in, not verified.
- **Sensitivities** (estimates, on the table's basis). At r = 1.1 the high ends become about 204 points for (a), 92 for (c) and (c′), 29 for (d) and 39 for (e). At k = 2 the low ends become about 39 for (a), 19 for (c) and (c′), 14 for (e) and 12 for (d).
- **Fit against the at most 29 points left at 15:23,** less the use since. (a) does not fit, even at its low end. (c) and (c′) fit only near their low ends. (e) fits only in the lower part of its 13-35, below what is left. (d) fits at r = 0.74 and is borderline at r = 1.1.

## 4. The field signal

- **No signal yields data without an app that adopts the kit.** Stage 4 stays cancelled (ORCH:675), the sibling repos are writable only in Stage 4 (`PROMPT.md:19`), and S1's reader (a `LogSink`, `AssetEnvironment.swift:31`, or `OSLogStore`) and N0's count (`AssetClient.swift:324`) are both app code.
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
  - R1's re-open criterion is field frequency too (rulings:1611). S1 does not cover it, and a site of its own is not estimated.
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
1. Which option do you choose: (a), (c), (c′), (d) or (e)?
2. Under (c) to (e), for every red gated case: is `VERIFY: FAIL (benchmarks)` accepted as WP-F's end state, or do you give the explicit G3 word to make them recorded and not gated?
3. Under (c) or (c′): are N7's five recorded by estimate (N25's precedent), or built as recorded cases to measure them?
4. Which field signal: S1, S2, S3, S4, or N0 alone? Is adoption by ZTronCarousel planned? Without it, no signal yields data.
5. May the final archive snapshot be pushed to `origin` at the close, as the 14:46 one was?
