# WP-F re-open dossier — resume here if WP-F is re-opened

Resume WP-F (the `ZTronAssetSync` engine, branch `wp/s3f`) from this file. Read it, then only what it names. Every figure is marked measured, derived or estimate (G2); an estimate never closes a case.
- **Names:** `rulings` is `.build-orchestrator/s3-rulings-s3f.md`, and `s3f.md` is `docs/adr-drafts/s3f.md` on `wp/s3f`. Analysis files named alone (`f3b-*.md`, `s3-r28-*.md`, f1c, f3c) are in `.build-orchestrator/s3f-c22-analysis/`.
- **Code lines are at `9aa337c`,** under `.worktrees/s3f`: `Engine*.swift` and `DeadlineHeap.swift` in `Sources/ZTronAssetSync/Engine/`, `BenchSync*.swift` in `Tests/ZTronAssetKitBenchmarks/`, `AssetClient.swift` in `Sources/ZTronAssetKit/Facade/`. `assetkit-*.js` are in `.claude/workflows/`.

## 1. Status
- **Version 1, 2026-11-06, about 15:00 CET**, written while cycle 23 is about to start: `wp/s3f` is at `9aa337c`, cycle 22's last commit, and S3-R28 is not yet appended to `rulings`. The final version is written at WP-F's close (section 7).
- **Edited at about 15:45 CET** with the nine must-fix items of `s3f-c22-analysis/reopen-dossier-review.md`. Version 1 as first written is `s3f-c22-analysis/REOPEN-WP-F-v1.md`. The edited lines give the facts at the edit, with their times: S3-R28 was appended at 15:21; at 15:33 the owner made the ENOSPC windows (correct #1 and #2) known residual correctness risks (N28, S3-R28 item 1c); run 10 was stopped at 15:32, and run 11 was launched at 15:34 for cycle 23, from `9aa337c` (ORCHESTRATION.md). The rest is as of version 1: it does not yet record N26 to N28, item 1c's known risks, or the owner's pending decision on the remaining C2 work. The next version adds them.

## 2. Why WP-F closed with known misses
- **The owner's words** (6 Nov, the message after 14:27), verbatim:

  > we need to end this package as soon as possible. Let's make it so:
  >
  > * leave these three cases out of cycle 23 and record them as known misses of the 10 ms limit.
  >
  > But, in a few months, we might re-open this package, depending on how frequently the misses are. So you keep all your analysis results and persist what's needed for a later resume

- **What led to it.** f3b's review listed three in-letter purge shapes that no authorised route closes (`f3b-review.md` §7, returned at 14:23). N24 gated them at 14:26. At 14:27 the orchestrator reported the fail-fast signal (N22): their candidate routes reach only 7-12 and 7-11.5 ms (estimates), which straddle the bar.
- **N25 (14:37)** records the ruling (`s3-r28-orchestrator-rulings.md:215-240`; a later ruling wins over N1-N24):
  - the three cases are out of cycle 23 and not blocking, by owner ruling, for these three only. S3-R27 12.1's bar holds for every other shape;
  - N24's gating of them, their step-0 figures, its stop rule and item 3c are withdrawn. No code, test or bench is added for them in cycle 23 (a re-open adds them: section 6, step 9). f3c finishes, for a re-open only;
  - the variants in `f3b-review.md` §7 rows 4 and 5 stay measured, and a miss there is still a fail-fast stop for the owner;
  - the fixer records the three in `s3f.md` under "Known misses of C2's 10 ms limit (owner ruling 2026-11-06)", for ADR-057 and Stage 5's `RESIDUAL-RISKS.md` and `VERIFICATION.md`. At `9aa337c` that record does not exist yet;
  - nothing under `.build-orchestrator/` is deleted. It is snapshotted to `archive/build-orchestrator` now and at the close, and this file is tracked on `feature/asset-kit`.

## 3. The known misses of C2's 10 ms limit
- All three are purges at 10,000 ids inside the bar's letter: at most 4 interests on one id, one subscriber (S3-R27 12.1, `rulings:1054-1055`).
- Each figure is the purge's first turn **after route C and item 3b** (`f3b-review.md:141-152`). Cycle 23 is to build both routes; at `9aa337c` neither exists.
- No BenchSync case builds these shapes, so `verify.sh --full` does not time them.

1. **Failed user jobs with `.retry` deadlines, under one to three prefetch groups.**
   - Figure: **about 500 ms if the origin admits a user request (derived)**, and that is today's cost too; 9-18 ms otherwise, on the sorted path (estimate).
   - Derivation: `retryJobs` measured 571.12 ms best before e2-A2.5 and 36.24 ms after it, at 1-minute loads of 2.72 to 4.38 (`s3f.md:7584`, `:7617`). e2-A2.5 removed the purge's per-job heap scan (`s3f.md:7593`), so (571.12 − 36.24) ms / 10,000 ≈ 53 µs a scan (`f3b-review.md:151`). In this shape each re-admission (`EngineJobs.swift:360`) calls `heap.remove` (`:362`), which scans the whole heap (`DeadlineHeap.swift:74-76`): 10,000 × 53 µs ≈ 0.5 s.
   - What would close it: A-6 alone reaches 11.5-18 ms; A-6 with an in-place re-admission 7-12 ms, for **3.5-5.5 h** of fixer work (estimates; `f3b-review.md:137`, `:145`; `f3b-route-a.md:68`, `:192`). Lower needs table order, which needs a ruling.
   - Not measured: the shape itself; the scan's cost on this path; whether the origin admits the request, which the breaker decides (`retryJobs`' timeouts leave its jobs `.failed(.at)`, `BenchSyncCycle22Purge.swift:201-204`).
2. **A bulk waiter under three prefetch groups (the lane falls).**
   - Figure: 9-17 ms (estimate; route A's own is 9-14.5). The lane falls, so the re-queue is due and stays sorted (`f3b-review.md:146`, `f3b-route-a.md:172`).
   - What would close it: an in-place re-queue, 7-11.5 ms, for **2-3 h** (estimates; `f3b-review.md:137`). Table-order re-queues after an A7-type order audit reach 4.5-8 ms (estimate), and need a ruling (A7: `rulings:868-871`).
   - Not measured: the shape. No figure of it exists.
3. **A prefetch group and a bulk group, under a third group's pending claim.**
   - Figure: 10-20 ms (estimate; `f3b-review.md:147`).
   - What would close it: shape 2's closers (`f3b-review.md:147`, "As in the row above"), within the same 2-3 h, since `:137` prices the in-place re-queue once for §7's shapes (estimate). f3b gives no figure for them on this shape. Skipping the re-queue instead breaks R-SYN-3's lanes (`SPEC.md:228`; `f3b-review.md:89-92`).
   - Not measured: the shape. No figure of it exists.

- **f3c** (the route analysis for these three) and its review are not written at version 1. They are expected in `/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c22-analysis/`, as `f3c-open-shapes.md` and a `f3c-*review*.md`. Where they differ from this section, they win.
- **Not measured for any of them:** a device figure (the benches' reference is an Apple-silicon Mac, `Scripts/quality-gates.json:62`; this host is an Apple M3 with Xcode 27.0, Swift 6.4); the field frequency (section 4).
- **Further known misses, if the owner rules more** (the final version fills this in):
  - none at version 1.

## 4. The re-open criterion
- The owner's criterion is **how often the misses happen in the field**. The owner gave no threshold; it is the owner's call.
- **Nothing measures that today.**
  - At `9aa337c` the engine has no signpost, log line or counter on the purge's first turn (`performPurge`, `EngineCommands.swift:963-976`); only the benches' test seam marks it (`commitTurnMarksForTests`, `:968`, `:976`). Its one signpost interval wraps a run's plan (`EngineRuns.swift:197`). Its two log calls report an illegal transition and a failure (`EngineJobs.swift:29`, `:1217`). `Sources/ZTronAssetKit` logs nothing.
  - The C2 cases run only on the Mac, in `verify.sh --perf` and `--full` (`Scripts/verify.sh:115`, `:132`, `:154`).
  - A signal would have to count purges (`AssetClient.purge(_:)`, `AssetClient.swift:323-324`) made while one of the three shapes holds, and time their first turns.
- **The options for a signal** are in `/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c22-analysis/end-sooner-options.md`, still being written at version 1 (`wf_d70ede79-565`). The final version records the owner's choice.

## 5. Where everything is
- **Branches** (6 Nov, 15:00):
  - `feature/asset-kit`: the integration branch, with this file and `docs/ORCHESTRATION.md`.
  - `wp/s3f` (`9aa337c`, 324 commits since `s3-base`): WP-F's code and the draft `s3f.md` (10,949 lines; only on this branch). Worktree `.worktrees/s3f`.
  - `wp/s3ah`, `wp/s3b`, `wp/s3c`, `wp/s3d`, `wp/s3g`: Stage 3's other close-outs, merged `--no-ff` into `feature/asset-kit` on 30 Oct. `wip/s3f-c15a` (`5a87864`): cycle 15's unfinished tests, never merged.
  - `archive/build-orchestrator` (`765102c`, 14:39): an orphan branch, never merged, holding snapshot 1 of `.build-orchestrator/`.
  - Detached worktrees: `.worktrees/s3m-gates` (`d97e4e7`) and `.worktrees/t64` (`9adfa91`, the tools-6.4 check).
- **Tags** (12): `contracts`, `harness-frozen` (`7f24d4c`; never moved, G1), `l1-merged`, `l2-merged`, `l3-base`, `l3-merged`, `l4-merged`, `l5g-merged`, `l5-merged`, `wpi-merged`, `s3-base` (`b5796ba`, `wp/s3f`'s base) and `s3-premerge-1`. `s3-merged` comes at WP-F's merge.
- **The remote:** `origin` is `https://github.com/NiccoloBargioni/ZTronAssetKit.git`. Pushed, each at the owner's word (ORCHESTRATION.md, "Pushed to GitHub at the owner's request (14:19)" and "Persistence (N25)"):
  - 14:19: `feature/asset-kit` at `46b2eb1`;
  - about 14:27 ("Push them too"): `wp/s3f`, the five other `wp/*` branches, `wip/s3f-c15a`, all 12 tags, and `feature/asset-kit` at `a4c59b7`;
  - 14:46 ("Yes, push it"): `archive/build-orchestrator` at `765102c`. Later snapshots need the owner's word.
  - Nothing else. The hand-off commits after `a4c59b7`, this file among them, stay local until the owner asks (CLAUDE.md: never push), so a fresh clone lacks them.
- **Inside the archive** (2,807 files; the folders below are under `.build-orchestrator/`):
  - rulings: `s3-rulings-s3f.md` (S3-R16 at :146, S3-R27 at :722-1276; copies `.before-s3-r27` and `.before-item12`), the other close-outs' `s3-rulings-s3*.md`, and `s3f-c22-analysis/s3-r28-final.md` with `s3-r28-orchestrator-rulings.md` (N1-N25);
  - analyses: `s3f-c20-analysis/` (RR-21, the 40 ms profile, S3-R26), `s3f-c21-analysis/` (d1-d5, e1, e2, S3-R27), `s3f-c22-analysis/` (f1, f1b, f2, f3 and f3b with their reviews, S3-R28's drafts) and `s3f-design/`;
  - item 1's routes (the ENOSPC windows, blocking at version 1 by the owner's "Keep it blocking", N21): `f1c-route-a.md` (40-62 h plus 8-12 h for step 0) and `f1c-route-b.md` (31-47 h), both estimates; `f1c-review.md` is a stub in the snapshot;
  - findings: `s3f-c<n>-issues.json` for ten cycles from 4 to 22, `s3-findings-s3f.json`, `s3-backlog.md`; probes `s3f-probes-c1/` to `s3f-probes-c22/`; mutants `s3-mutants/`;
  - fix arguments: `s3-fix-args-run3.json` to `s3-fix-args-run10.json`;
  - tools: `tools/watch_journal.py`, `tools/watch_putback.py`, `tools/dump_analysis.py`, `tools/wpf-profile-40ms*.js`;
  - at the archive's root: `worktree-s3f-logs/.build-s3f/c19/` to `c22/` (the 78 logs `s3f.md` cites) and `ARCHIVE-README.md`.
- **Caveats:**
  - `.build-orchestrator/` matches `.gitignore`'s `.build*` (`.gitignore:2`) and CLAUDE.md's `rm -rf` allowance, so a clean-up can delete it. The archive is the copy that lasts.
  - `.worktrees/s3f/.build-s3f/` (26 GB by `du` on 6 Nov) is not archived, except 78 of the 80 files that `s3f.md` names under `c19/` to `c22/`. Not archived: the two `cov.profdata` files in `c20/gates/` and `c21/gates-b/`, each over 3 MB, and the 46 small logs that only the draft's globs match (`c21/mut-*.log`, and `c22/each/`'s `before-*`, `after1-*`, `red4-*`, `a17-*` and `a25-*.log`; about 1.7 MB). Of the 24 folders it names, 13 are package copies or build and test output (build trees, coverage builds, `.xcresult` bundles), as are the 6 more that `c22/snap-*` matches. From the other 11, only their named files are archived: `c19/final`, `c19/mut`, `c21/each`, `c21/gates`, `c21/pending`, `c21/red-c3`, `c21/red-holes`, `c22/mut`, `c22/mut-e2a`, `c22/rerun` and `c22/tools` (555 files, about 23 MB, none over 3 MB). All counted on 6 Nov.
  - Snapshot 1 (14:39) predates everything written after it. At about 15:45 that was: `s3-r28-append.md` with its `-v1`, `-review` and `-pre-n26` files; `s3-r28-item3b.md` with its review; `s3-r28-item1c.md`; f3c (`f3c-open-shapes.md`); `end-sooner-options.md`; `reopen-dossier-review.md` and `REOPEN-WP-F-v1.md`; `s3-fix-args-run11.json`, and run 10's arguments as launched (their focus gained a sentence); S3-R28 and item 1c in `rulings`, with `.before-s3-r28` and `.before-item1c`; the push line and N26 to N28 of `s3-r28-orchestrator-rulings.md`; `f1c-review.md`'s full text (a stub in the snapshot); and cycle 23. Until a later snapshot holds them, they exist only in the live folder.

## 6. How to resume
1. **Only on a fresh machine,** clone to this path: both workflow scripts hard-code it (`.claude/workflows/assetkit-stage3-fix.js:19`, `assetkit-closeout.js:25`). This clone was not run for this file (no network); steps 1, 3 and 4 were run on a local clone in a scratch folder.
   ```bash
   git clone https://github.com/NiccoloBargioni/ZTronAssetKit.git /Users/admin/Documents/ZTronAssetKit
   git -C /Users/admin/Documents/ZTronAssetKit branch archive/build-orchestrator origin/archive/build-orchestrator
   ```
2. **Check the state**, then read `docs/ORCHESTRATION.md`'s Stage 3 section, newest bullet first:
   ```bash
   git -C /Users/admin/Documents/ZTronAssetKit status --short
   git -C /Users/admin/Documents/ZTronAssetKit worktree list
   git -C /Users/admin/Documents/ZTronAssetKit branch -a
   ```
   If `git status` shows `M Package.swift`, it is the owner's own edit (tools 6.0 → 6.3; ORCHESTRATION.md, "Uncommitted `Package.swift` in the main checkout", line 685 at `4a9d381`). Never commit, revert or edit it, and commit only explicit paths, never `git add -A` or `commit -a`. If the clone's `feature/asset-kit` is still at `a4c59b7`, the last push at version 1, its ORCHESTRATION.md stops before N24, N25 and the archive: read those in the restored `s3-r28-orchestrator-rulings.md:199-239`. Section 5's caveats list what snapshot 1 lacks.
3. **Restore `.build-orchestrator/`** only if it is missing. If it exists, restore into a scratch folder and `diff -rq` the two instead: the live folder may hold newer files.
   ```bash
   test -d /Users/admin/Documents/ZTronAssetKit/.build-orchestrator || git -C /Users/admin/Documents/ZTronAssetKit archive archive/build-orchestrator .build-orchestrator | tar -x -C /Users/admin/Documents/ZTronAssetKit
   ```
4. **Re-create the worktree** if `worktree list` lacks it. `add` creates `wp/s3f` from `origin/wp/s3f` (`9aa337c` until a later push) when the local branch is gone. Then restore the 78 logs if `.build-s3f/` is missing.
   ```bash
   git -C /Users/admin/Documents/ZTronAssetKit worktree prune
   git -C /Users/admin/Documents/ZTronAssetKit worktree add .worktrees/s3f wp/s3f
   test -d /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-s3f || git -C /Users/admin/Documents/ZTronAssetKit archive archive/build-orchestrator worktree-s3f-logs | tar -x -C /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f --strip-components 1
   ```
5. **Read, in order:** S3-R16, the bar (`rulings:146`); S3-R27 12.1, the owner's scope (`rulings:1054`); S3-R28 and the items appended after it. S3-R28 was appended at 15:21 (`rulings:1278`, byte-identical to `s3-r28-append.md`), and item 1c at 15:33 (`rulings:1582`): item 1c makes correct #1 and #2 known residual correctness risks (N28) and withdraws item 1b, which is never appended. Item 1b's inputs stay in `f1c-route-a.md`, `f1c-route-b.md` and `f1c-review.md` (complete at 15:26, a stub in snapshot 1). Until item 3b is appended, it is `s3-r28-item3b.md`; its 3b.5-3b.7 gate the three shapes and name item 3c, which N25 withdraws for them. Then N22, N25 and N28 (`s3-r28-orchestrator-rulings.md:134`, `:215`, `:280`); `s3f.md`'s last cycle section and its known-miss record; `f3b-review.md` §6-§7 and f3c.
6. **Rule the re-open** by appending a ruling to `rulings`, keeping a `.before-` copy, as S3-R27 and its item 12 were (`.before-s3-r27`, `.before-item12`), and S3-R28 and its item 1c since (`.before-s3-r28`, `.before-item1c`). Fail fast (N22) applies: riskiest first, stop conditions, `PUT-BACK` commits, watched by `python3 .build-orchestrator/tools/watch_putback.py <worktree> <since> <journal> <seen>`.
7. **The fix workflow** is `.claude/workflows/assetkit-stage3-fix.js`. Copy the highest-numbered `s3-fix-args-run<N>.json` (run 11's at this edit, run 10's at version 1):
   ```bash
   cp /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-fix-args-run11.json /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-fix-args-reopen1.json
   ```
   - Change `wps[0].fromCycle` (23: make it the next cycle) and `wps[0].findingsFile` (`s3f-c22-issues.json`: make it the last verification's). Raise both `maxCycle` fields (30) if `fromCycle` passes them.
   - `wps[0].focus`: replace every cycle-specific phrase (S3-R28, items 1b and 3b, `9aa337c`, "Cycles 1-22", `s3f-probes-c22/`, the cycle-23 section, `.build-s3f/c23/`; run 11's also names item 1c and run 10's stop) with the re-open's ruling, HEAD and cycle. Keep its standing rules: `sim.lock`, S3-R23's loads, "never edit Package.swift", and keeping `.build-s3f/c21/` and `c22/`. Stop the run once it starts the next cycle's fixer, and relaunch it with that cycle's focus.
   - Keep `base` (`s3-base`, while `wp/s3f` is unmerged; section 7 names the base after the merge), `bar` (`strict`), `wp`, `target`, `testTarget`, `sections`, `coverageMin` (90), `rulingsFile` and `models` (Opus for both). Add no `usageStop` unless the owner names one.
   - Launch `Workflow({scriptPath: ".claude/workflows/assetkit-stage3-fix.js", args: <the new JSON>})` with no `resumeFromRunId`, as runs 7 to 9 were.
8. **Simulators:** set 1 is `simSlots[0]`: fix `897F9D8D-B10D-4D91-8E22-417A2B9D70AA` (iPhone 18 Pro), reqs `6BE15CAF-7E02-4060-9338-9DAC025EDF0B` (iPhone 18 Pro Max), correct `5B940E6E-490F-4E9E-A917-A6456A18225E` (iPhone Air), all iOS 27.0 and shut down on 6 Nov. Never use the owner's booted simulators (`assetkit-closeout.js:22`). On a new machine, put three new UDIDs there. Simulator and coverage runs take `.build-orchestrator/sim.lock` (S3-R22 item 3, `rulings:288-290`).
   ```bash
   xcrun simctl list devices | grep -E '897F9D8D|6BE15CAF|5B940E6E'
   ```
9. **The C2 benches to measure first,** before any fix, on a scratch copy of the base under `.build-s3f/c<N>/` (as N12 did):
   - the three shapes of section 3, as cases in a new `Tests/ZTronAssetKitBenchmarks/BenchSync*.swift`, which the re-open ruling authorises as S3-R27 11.6 and N17 did (`rulings:1033-1037`; `s3-r28-orchestrator-rulings.md:74-79`); riskiest first: the failed-user shape with an origin that admits users;
   - then `f3b-review.md` §7's two variants and every gated purge case: `purgeTurns(_:)` and `purgeJoinsTurns(_:)` (`BenchSyncCycle22Purge.swift:17`, `:37`), `purgeWhileOwedTurns` (`BenchSyncReroutes.swift:72`), and cycle 23's additions;
   - read the 1-minute load before and after each case (`sysctl -n vm.loadavg`). Run both commands in the copy being measured, with its own `Scripts/verify.sh`; use the worktree's only while the worktree is still at the base. The second runs one test function with all its arguments, in the form of cycle 21's re-run alone (`s3f.md:6727-6728`, which added `--skip-build`). `--perf` also fails at `9aa337c` on P-13, which is WP-B's and is reported as such (ORCHESTRATION.md:51, :194; `rulings:1063`). Neither was run for this file:
   ```bash
   SWIFTPM_SCRATCH=.build-s3f bash /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Scripts/verify.sh --perf
   swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter "SyncBenchmarks/purgeTurns"
   ```
   - **The decision rule** (S3-R27, `rulings:756-765`, `:803-806`; S3-R28 item 3, `s3-r28-final.md:139`): the figure is the case's heartbeat, best of 3. At or below 8.5 ms closes a case. 8.5 to 10 ms is "at the edge": recorded, not blocking. Above `c2Budget`, 10 ms (`BenchSync.swift:129`), at 1-minute loads of 10 or less, is a miss. A miss seen only at loads above 10 is re-run alone, at the lowest load that can be had (S3-R23 item 2, `rulings:297`). If no run reaches a load of 10 or less, the case is "not measured at a quiet load": it is neither confirmed nor blocking until the orchestrator measures it at a quiet load (`rulings:763`, `:301`).
   - A gated case left red fails `verify.sh --full` (`Scripts/verify.sh:154`), and with it PROMPT.md's Done criterion, which needs `VERIFY: PASS` with passing benchmarks (`PROMPT.md:96`).
10. **Budget** (ORCHESTRATION.md; wall times are measured from its timestamps, and points are read off the shared weekly meter, which includes the owner's other use). Cycle 21's fixer took 14 h 34 min (:28) plus 8 h 58 min (:49). Its verifiers took about 2 h 20 min (17:54 to 20:14, :49 and :133; derived), and the cycle cost about 30-38 points in all (:88; derived across the early reset of 5 Nov). Cycle 22's fixer took about 9.4 h (:183) and its verifiers about 1.3 h (08:44 to 10:03, :203; derived), with the meter at 42 → 51 % (:173, :213; measured). Check the meter right before the launch, and forecast in hours and weekly %.

## 7. What the final version must add at WP-F's close
- **The close state:** the converged cycle, `wp/s3f`'s final HEAD, the merge commit, tag `s3-merged`, and the last line of `verify.sh --full`, with each FAIL cause named.
- **Where `wp/s3f` lives after the post-convergence clean-up** (N25: worktrees go only after their branches are pushed or archived), and which base and `wp` key a re-open uses (`assetkit-closeout.js:11`).
- **The final archive snapshot:** its commit, file count and restore test, and whether the owner allowed its push. Also whether `feature/asset-kit`, which carries this file, was pushed for a fresh clone. The snapshot also holds the files that `s3f.md` cites under `.build-s3f/c23/` and later cycles, each under 3 MB as in snapshot 1, with the files its globs match (section 5's 46 among them), and the cited folders that are neither package copies nor build and test output (section 5's eleven and those added later), so that step 4's restore brings them back.
- **Every other known miss or residual:** section 3's placeholder list; S3-R27 12.1's shapes outside the bar (more than 4 interests on one id, 37.21-45.85 ms; a second stalled subscriber, 15.57 ms; both measured, `rulings:1065-1066`); `s3f.md`'s "Residual risks (S3-R16)"; open survivors and unreached lines; P-13 (WP-B's).
- **f3c and its review** in section 3, and the signal the owner chose from `end-sooner-options.md`.
- **Pointers:** ADR-057 in `docs/DECISIONS.md`, and the Stage 5 entries for each known miss in `docs/VERIFICATION.md` ("Not verified") and `docs/RESIDUAL-RISKS.md`.
