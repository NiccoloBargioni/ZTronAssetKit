# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Stage 3 (hardening) — RUNNING: fix close-outs (launched 2026-10-29, session `eaf5a17f-…`). Next session: start here
- **Now (5 Nov 08:57 CET): run 8 resumes cycle 21, at the owner's word "resume". Session `c4407fcb-53ee-44ae-8d93-02e7220ac38a` (app session "Resume"). Read this bullet first. The 4 Nov bullet below it is history; this session applied its cut-off procedure (steps 1 to 4).**
  - **What cut off run 7:** the weekly limit. The cycle-21 fixer (agent `ad6043d9…`) hit it at 03:55:48 CET in step 5, while it was starting rr21-C5's red benches. The four verifier attempts after it failed at once on the same limit.
  - **Usage at 08:52 and 08:56:** weekly all models **2 %**, Fable 0 %. The meter reset early again; the next reset is **Thu 12 Nov 03:00 CET** (02:00 UTC). No 5-hour window is shown. There is no usage stop (the 29 Oct ruling stands).
  - **The retired scheduled task fired at 08:51:** `ztron-assetkit-resume-after-reset`, catching up its 5 Nov 03:10 time. Its guard held: it launched and changed nothing (app session "ZTronAssetKit: resume after the Thu 5 Nov weekly reset", 12 s). It is disabled, and as a one-time task it does not fire again.
  - **State at the cut-off (checked 08:52–08:55):**
    - `wp/s3f` is at `7876a28`, 49 commits from `8e1fb24`. Per the draft's "Status (resume here)" list, steps 0 to 4 are committed, and so are step 5's rr21-C0 to rr21-C4. Next: rr21-C5, then rr21-C6, then the mutant results. Steps 6 to 8 are pending.
    - No `sim.lock`; simulator set 1 is shut down; no build or test process runs; no keep-awake or watcher is left from 4 Nov.
  - **The uncommitted work is saved** as `.build-orchestrator/s3f-c21-interrupted.patch`, which applies cleanly to `7876a28`. It is rr21-C5's red step, never run (6 files, +361/−52):
    - site 3's tests rr21-T2, rr21-T2-two and rr21-T2-edge, in a new `EngineFollowBarrierRerouteSupersedeTests.swift`;
    - the fixture's `away` shape;
    - the benches `supersededRerouteTurns`, `supersededUserTurns` and `runSuperseded`, and a pin.
    - The worktree was then reverted to `7876a28`. `.build-s3f/c21/pending/` (10 entries) is untouched.
  - **Mutants at the cut-off:**
    - `mut21-c3c.txt` is complete.
    - `mut21-c3fix.txt` ran f1 to f6 twice. f7-delisted-stays ran once and **passed**, so it survives unless its second run fails. f8 to f11 never ran.
    - `mut21-pinend.txt` and `mut21-c4fix.txt` were never started.
  - **Run 8 launched 08:56:** `wf_f90e12fa-faa` (task `wr2wci9rf`).
    - Script and args: `.claude/workflows/assetkit-stage3-fix.js` with `.build-orchestrator/s3-fix-args-run8.json`. That is run 7's fields with `fromCycle: 21`: Opus fixer and verifiers, simulator set 1, no usage stop. The focus adds the cut-off, the patch and the mutant state.
    - Journal: `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/c4407fcb-53ee-44ae-8d93-02e7220ac38a/subagents/workflows/wf_f90e12fa-faa/journal.jsonl`. Fixer agent `a0286a63…` started at 08:56.
    - Keep-awake `caffeinate -ims -t 259200` runs as background task `b1drmseq1`. The watcher `watch_journal.py <journal> 0 1` runs as task `bcvg68496`.
    - The host's 1-minute load was 4.69 at 08:56.
  - **Forecast (08:57):**
    - Run 7's fixer took 14 h 34 min for steps 0 to 4 and rr21-C0 to rr21-C4. That covers most of S3-R26's code: items A and B, item C's Phase 1, the candidates, and RR-21's sites 1 and 2 with the layers and R18.
    - What is left: rr21-C5 to rr21-C7 with the mutant runs, Phase 2 if a trigger fires (step 6), item 5 (step 7) and the close (step 8). Expect 7–12 h of fixing, so the fixer should finish about 16:00–21:00. Verification then takes 2–3 h, so cycle 21's verdict is due about 18:00–24:00.
    - Cost: on 4 Nov the meter rose 0.5–0.9 points an hour with one fixer running (90 → 96 % in 6 h 50 min, with the profiling alongside; 96 → 100 % in 8 h 14 min). The rest of cycle 21 is about 5–13 weekly points.
    - The integrator put a clean cycle 21 at about 0.12 for the whole plan. So plan for 1–3 more cycles: 7–12 h and 4–11 points each. The merge, the gates, ADR-057 and Stage 5 add 10–20 points.
    - All of this fits before the 12 Nov reset.
  - **Progress at 15:40 (6 h 44 min in):** 21 commits since `7876a28` (70 in cycle 21); the last is `28c2700`, at 14:53. Per the draft's status list:
    - **Step 5 committed.**
      - rr21-C5, site 3: the patch was re-applied unchanged, red at `ddecf1f`, fixed at `42a3689`.
      - rr21-C6, site 2: `e437c28`, plus the take-off in one access (`8647760`).
      - rr21-C7: `2c351e8` removes two checks no path reaches. Its mutation table leaves **12 survivors open**: no test kills them and none is shown Equivalent, so they are reported, not claimed.
    - **Step 6 committed:** Phase 2 was triggered (`06d5e40`, `28d533e`, `57d5d8c`). At a 1-minute load of 4.18, every gated case meets C2 except `waitersStalledSubscriber`, at **10.31 ms** best. That is blocking and reported (S3-R26 item 4).
    - **Step 7 committed:** item 5 (`waitingTarget` reached, `4aeb321`). Its probes found three real bugs, each fixed red-first:
      - an ENOENT window's later apply;
      - an ENOSPC read's visit re-queueing its job;
      - the same in the transfer's ENOSPC read.
    - **Now in step 8:** the gate run on `2c351e8` (TSan was running at 15:40). The draft has uncommitted edits.
    - **Expected when the fixer returns:** at least two blocking put-backs, the 0.31 ms miss and the 12 survivors. So cycle 22 is likely, and they need rulings before its fixer starts.
  - **Usage at 15:40:** weekly all models **20 %** (2 % at 08:56): 18 points in 6 h 44 min, or 2.7 an hour account-wide. Weekly Fable went 0 → 21 %. Run 8 is all Opus, so part of the 18 points is the owner's other use. The 08:57 rate of 0.5–0.9 an hour was too low.
  - **Re-forecast (15:40), taking 2.7 an hour as the upper bound:**
    - The fixer should finish about 16:30–18:30, and the verdict is due about 19:00–21:30. The rest of cycle 21 costs about 8–16 points, which puts the meter at about 28–36 %.
    - Each further cycle (7–12 h) costs up to 19–32 points. Two more cycles plus the merge and Stage 5 (10–20 points) fit before the 12 Nov reset. A third cycle at this rate would likely reach the limit first.
  - **Cycle 21's fixer returned at 17:54** (8 h 58 min into run 8; 73 commits in cycle 21, 24 of them since `7876a28`). `wp/s3f` is at `d5b2ab9`, and its last code commit is `e599ae1`. Step 8 found a test race and fixed it red-first (`a380c78`, then `e599ae1`).
    - **Gates on `e599ae1`** (logs in `.worktrees/s3f/.build-s3f/c21/gates-b/`): `--quick` PASS; the release build with `-warnings-as-errors`; UNSAFE 0 of 3; DOCS 1281/1281; Sync 681/681 three times, and once under TSan; the iOS generic build; coverage, Sync 94.86 %; the simulator, 1635/1635 on 897F… plus 420 repeated runs.
    - The release benchmarks failed with 3 issues: P-13 (WP-B's), `waitersStalledSubscriber` at 11.09 ms and `purgeWhileOwedTurns` at 10.04 ms.
    - **Blocking and reported** (the draft's "Open at the close (cycle 21)"):
      1. `commitTurns(.waitersStalledSubscriber)`: 10.45 and 11.09 ms best in the two gate runs. A stalled subscriber costs about 0.3 µs an event, and Phase 2 cannot cut it.
      2. `purgeWhileOwedTurns`: 10.04 ms in the second gate run; 9.57 in the first, and 9.62 and 9.75 run alone. A route is recorded: read the purge's request before the copy lookup, which saves about 1 ms.
      3. 12 mutant survivors with no killing test.
      4. 4 places (12 lines) of changed code that no test reaches; two of them are survivors.
      5. PROBE-C21-APM: `answerPresentMembers`' answer turn at 10,000 present ids takes 10.79, 12.76 and 14.17 ms (one group, 10,000 groups, 10,000 user waiters). No route found.
      6. PROBE-C21-HOLDERS: one id held by 10,000 interests moves in one turn, 39.01 and 40.98 ms. No route found within "an id taken whole".
    - **Put to the orchestrator:**
      - the held-turn readers that loop `while followOwed` were not audited for the reservation-edge race;
      - `releaseRerouteHolds` (R12) has no C2 figure;
      - the two-subscriber figure, 13.68 ms, is for the owner (S3-R26 answer 4).
    - Not run: `verify.sh --full` and `--gates-only`; their steps ran on their own.
    - The verifiers `verify:s3f:reqs:c21` (`a0dbaa44…`) and `verify:s3f:correct:c21` (`a06aaa2f…`) started at 17:54. The host's 1-minute load was 3.81 at 17:55.
  - **Usage at 17:55:** weekly all models **24 %**, Fable 21 %. That is 4 points in 2 h 15 min since 15:40, or 1.8 an hour.
  - **S3-R27's analysis, launched 18:03:** `wf_cbf1b459-e34` (task `wgzpso5k4`).
    - It is read-only: no build, test or benchmark runs while the verifiers take their C2 figures.
    - Five analysts, each writing its report to `.build-orchestrator/s3f-c21-analysis/`:
      - D1, `waitersStalledSubscriber`;
      - D2, PROBE-C21-APM;
      - D3, PROBE-C21-HOLDERS, with the scope question for the owner;
      - D4, the 12 survivors and the 4 unreached places;
      - D5, the audit of the `while followOwed` readers.
    - An adversarial reviewer checks D1, D2 and D4 (`*-review.md`).
    - S3-R27 is written from these reports and appended to `s3-rulings-s3f.md`.
    - The watcher for the first verifier result, `watch_journal.py <journal> 1 2`, is task `bap4d120y`.
  - **Cycle 22 runs as run 9, not inside run 8.** Run 8's focus calls S3-R26 "this cycle's ruling" and carries cycle 21's cut-off paragraph, so a cycle-22 fixer started inside run 8 could put S3-R26 above S3-R27. So:
    1. Once both verifier results are in run 8's journal, stop run 8 (`TaskStop wr2wci9rf`) as soon as its cycle-22 fixer starts.
    2. Check that `.worktrees/s3f` is clean at `d5b2ab9`, that there is no `sim.lock`, and that set 1 is shut down.
    3. Write `.build-orchestrator/s3f-c21-issues.json` from the two verifier results, in `s3f-c20-issues.json`'s shape (`cycle`, `head`, `lenses.reqs`, `lenses.correct`).
    4. Write `s3-fix-args-run9.json` from run 8's, with `fromCycle: 22` and `findingsFile: s3f-c21-issues.json`. Its focus names S3-R27 as the cycle's ruling and drops the cut-off paragraph.
    5. Launch run 9 once S3-R27 is appended, as on 1 Nov (S3-R25's second ruling).
  - **Usage at 18:57:** weekly all models **30 %**, Fable 21 %. That is 6 points in 62 min, with the two verifiers, the five analysts and this session running: about 0.85 points an hour an agent.
  - **Forecast for five more cycles, 22 to 26** (the owner asked at 18:57: "Assume we need 26 cycles, would this fit within this week"):
    - **Wall time fits.** About 150 h are left before the Thu 12 Nov 03:00 reset. Cycle 22 takes about 12–22 h, since it carries S3-R27's design changes; cycles 23–26 about 6–12 h each, as cycles 19 and 20 did. That is 50–100 h, plus 8–16 h for the merge, the post-convergence checks and Stage 5.
    - **Usage does not, at today's rates.**
      - About 60–64 points are left when cycle 22 starts (about 21:00, at 36–40 %).
      - Cycle 22 costs about 15–30 points; each later cycle about 10–16 (the fixer 0.65–1.8 points an hour, and 4–6 for the two verifiers). Cycle 21 cost about 30–38 in all.
      - Five cycles therefore need about 55–95 points, before the merge and Stage 5 (10–20).
      - Central case: 37 → 57 % after cycle 22 (Fri afternoon), then about 70, 83 and 96 % after cycles 23–25 (Sat evening). The limit arrives early in cycle 26, so about four days are left idle before the reset.
      - Five fit only in the optimistic case (15, then 10 a cycle), with nothing left for the merge.
    - **Levers that would bring five within reach:**
      - rule between cycles from the fixer's report alone, with no read-only analysis run (S3-R27's cost about 6–10 points);
      - start a fresh orchestrator session each cycle (this one's context is about 240 k tokens, which makes every turn dearer);
      - merge and run Stage 5 after the reset;
      - get the owner's scope rulings on PROBE-C21-HOLDERS and the second subscriber;
      - use Sonnet verifiers, which are cheaper but weaken the bar (the owner's choice).
      Under "near the limit: launch anyway", the cycles run until the limit, and the rest resumes after the reset.
    - **Twenty-six more cycles** fit neither budget: 150–600 h of wall time and several hundred points. Run 9's `maxCycle` is 30 in any case.
  - **Next:** as in the 4 Nov bullet's "Next" list. At each wake-up, record the result here and commit. Rule put-backs between cycles by appending to `s3-rulings-s3f.md`. Check `get_usage`.
  - **If this session ends before convergence:** follow the 4 Nov bullet's steps 1 to 4 with run 8's journal, writing `s3-fix-args-run9.json` from run 8's. A run resumes only in its own session.
- **Earlier (4 Nov 12:55 CET): resumed two days early, at the owner's request ("Run the next fix cycle. Be aware that we're close to usage limits, so save often so I will resume on next reset"). Session `993d93ff-5346-4c12-8776-2873c1660fc2`. The 2 Nov bullet below it is history, and its "Restart" steps are superseded by this one.**
  - **Usage at 12:50:** weekly all models **90 %**, Fable 4 %, 5-hour 3 %. The reset is **Fri 6 Nov 19:00 CET** (18:00 UTC). A cycle costs 10–13 weekly points, so this run is expected to be cut off by the limit before cycle 21 ends. The owner accepted that: no usage stop is set (the 29 Oct ruling stands), and the state is saved here after every step so that the next session resumes cold.
  - **Path:** the owner's words choose path B (continue the cycles). The profiling (the 2 Nov step 1a) runs alongside, read-only, because the host was quiet (1-minute load 5.7 at 12:47).
  - **Done so far this session:**
    1. Checks at 12:47: `.worktrees/s3f` clean at `8e1fb24`; no `sim.lock`; simulator set 1 (897F…/6BE1…/5B94…) shut down and available; a `caffeinate -i -s -t 123600` (pid 9782, started 3 Nov 23:58, not ours) was running.
    2. **Profiling resumed 12:53:** `wf_e80338c6-07f` (task `wjsdg4nf0`), from `.build-orchestrator/tools/wpf-profile-40ms-resume.js`; journal `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/993d93ff-5346-4c12-8776-2873c1660fc2/subagents/workflows/wf_e80338c6-07f/journal.jsonl`. Its report, when written, is `.build-orchestrator/s3f-c20-analysis/profile-40ms.md`; the result is recorded under "Profiling result" below when it arrives. If that entry is missing, the run was cut off: resume it as the 2 Nov step 1a says (do not delete `.build-prof40/`). Report it to the owner as "if the ceiling were 40 ms": analysis only, C2 stays 10 ms.
    3. **S3-R26 finalized 12:54:** all 15 findings of `s3-r26-review2.md` (3 must-fix, 12 should-fix) are applied to `.build-orchestrator/s3f-c20-analysis/s3-r26-draft.md`; the version before them is kept as `s3-r26-draft-v2.md` (`s3-r26-draft-v1.md` is the first draft). An independent read-only check by an Opus agent (done 13:15; 21 min, ~273 k tokens) found 14 of 15 resolved, one partly (the rr21-C3 re-check), and six places where two verifiers could judge the fixer differently, each with replacement text; all seven are applied (v3 is kept as `s3-r26-draft-v3.md`; the appended text is v4, 319 lines). One open point was ruled: a `followedLane` miss takes the per-batch lane summary that `integrate-rr21.md:886` names, with its branches in the table and its own inventory row. **Appended to `s3-rulings-s3f.md` at 13:19** (its last ruling, from line 403).
    4. `s3-fix-args-run7.json` now carries `models: {fix: "opus", verify: "opus"}` inside `wps[0]` (the stage3-fix script forwards only per-work-package fields to the close-out script). Run 6 ran on Opus as its session's model; this session's model is Fable, and Opus keeps cycle 21 comparable with cycles 1–20 and cheaper. The owner can change it.
  - **Profiling result (done 13:17; 2 agents, no errors, 23 min, ~408 k subagent tokens):** `wf_e80338c6-07f`. Report `.build-orchestrator/s3f-c20-analysis/profile-40ms.md`; independent review `profile-40ms-review.md` (verdict CORRECTED: shape 3 must be read from its clean trace only, a 0.2 ms slip in shape 2's arithmetic, C4 is underestimated by 0–20 %; the conclusions stand); both results as Markdown in `profile-40ms-run2/`. **This is analysis only, under the 2 Nov rule: a value the owner floats is not a ruling. C2 stays 10 ms.** Report it to the owner as "if the ceiling were 40 ms":
    - Quiet baselines on 4 Nov (1-minute load 4.75–5.26): commit re-routes 49.08 ms, drain take-off 44.92 ms, `supersede` 40.21 ms, best of 3. The CPU profiles are from 2 Nov under load (shares only; the ms are share × quiet baseline).
    - Shares per turn (commit / drain / supersede, the last from the clean trace): transfer-id formatting 20.6 / 16.9 / 16.3 % (10.1 / 7.6 / 6.6 ms, 4 formats per id in the commit, 3 elsewhere, 0.25–0.30 µs each); jobs-table access 21.1 / 27.8 / 29.6 % (10.4 / 12.5 / 11.9 ms; 10 hashed `Dictionary<TransferID, Job>` accesses and 2 whole-`Job` copies per id, 1.0–1.2 µs/id); sorting 12.1 / 5.7 / 8.1 %; other Set/Dictionary work 16 / 22 / 15 %; manifest lookups 7 / 7 / 7 %; **a whole-`EngineState` copy (260 fields) per join in `decisionNow()` (`EngineFollow.swift:242`, inlined into `addInterest`) 10.7 / 10.4 / 13.7 % = 4.9–5.5 ms, confirmed in the binary; the 2 Nov analysis did not name it.** No single cost dominates.
    - Claims of `analysis-40ms.md`: C1 PARTLY (the format count holds, the 40–50 % share is refuted: it is 16–21 %); C2 CONFIRMED; C3 PARTLY (the two 3 ms sorts hold; `retireProgress`+`removeJob` is 0.6 ms, not 1.3); C4 confirmed but 0–20 % low. Micro-timings re-run by the reviewer at load 4.12, all within ±7 %.
    - **If the ceiling were 40 ms (branch-free fixes only: format each id once, one jobs-table access per id with no `Job` copy, filter before sorting; arithmetic on shares, not patched code):** commit 30.6–31.1 ms only if both per-id fixes land in full (33–35 ms otherwise, the honest reading); drain 29.2–29.7 ms; `supersede` 27.3–27.8 ms. Removing the `decisionNow` copy as well (engine-only, no branch): 25.4–25.9 / 24.3–24.8 / 21.8–22.3 ms. **At 10 ms nothing here suffices:** 23–26 ms of per-id work remains with every branch-free fix, so `analysis-40ms.md`'s finding 4 stands and S3-R26's bounded-turn design (RR-21) is still what the 10 ms bar needs.
    - Nothing tracked was modified; `.build-prof40/` stays (800 MB release build, traces, pickles, `review/` scripts) until the owner says to delete it.
  - **Run 7 launched 13:21:** `wf_380c4f39-d5b` (task `wlemwp41k`): `.claude/workflows/assetkit-stage3-fix.js` with `.build-orchestrator/s3-fix-args-run7.json` (its focus gained one sentence: keep the draft's cycle-21 section current step by step, for a resume). Journal: `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/993d93ff-5346-4c12-8776-2873c1660fc2/subagents/workflows/wf_380c4f39-d5b/journal.jsonl`. Keep-awake `caffeinate -ims -t 259200` runs as background task `bj0c5mzco` from 13:19. The watcher `watch_journal.py <journal> 0 1` runs as a background task. The fixer runs on Opus with simulator 897F…; the verifiers on 6BE1… (reqs) and 5B94… (correct), also Opus. No usage stop.
  - **Progress at 19:41 (6 h 20 min in, 29 commits on `wp/s3f`, weekly 96 %):** per the draft's "Status (resume here)" list (`docs/adr-drafts/s3f.md`, the "Cycle 21" section): step 0 done (`--quick` PASS), steps 1–3 committed (step 1 the failing tests, pins and probes; step 2 item C Phase 1 plus candidates 1 and 2, which broke and were fixed red-first; step 3 item A, item 6 and candidate 4, which also broke and was fixed), step 4 (item B) in progress: B2–B4 with the I1/I3 clauses committed at `f9bce7a` (Sync 587 tests green), the pins and B-T4 committed red at 19:39, B5–B11 being wired in. Pending: step 5 RR-21, step 6 Phase 2 if triggered, step 7 item 5, step 8 the close. Every figure so far is "not measured at a quiet load" (the host was busy); step 8 re-measures. **Tests written ahead of their fix wait in `.worktrees/s3f/.build-s3f/c21/pending/` (ignored by git): never delete `.build-s3f` before cycle 21 ends.** The cut-off is expected inside step 5, about 3 h after 19:41 at 1.4 points an hour.
  - **Next:** at each wake-up, record the result here and commit; rule any put-back between cycles by appending to `s3-rulings-s3f.md`, as before; check `get_usage`. Convergence is 0 blocking from both lenses; then the post-convergence list in the 2 Nov bullet's path A step 3 applies (merge `wp/s3f` with `--no-ff`, the tools-6.4 check, the phase-A gates, TSan and `--perf` on an idle host, P-13's verifier, the mutation re-check, ADR-057, tag `s3-merged`, then Stage 5).
  - **If this session was cut off by a usage limit (the expected case), on the next resume:** the weekly limit resets Fri 6 Nov 19:00 CET; the 5-hour window (3 % at 12:50, resetting 17:10 CET) may cut the run first, and then a resume is possible after that reset with whatever weekly headroom `get_usage` shows (about 1.4 points an hour of fixing). Either way:
    1. `get_usage`. Then `git -C .worktrees/s3f status --short` and `git -C .worktrees/s3f log --oneline 8e1fb24..HEAD`. The cycle-21 fixer commits each step on its own, so its finished steps are on `wp/s3f`; `docs/adr-drafts/s3f.md` in the worktree records what it did.
    2. If the worktree is dirty: `git -C .worktrees/s3f add -A && git -C .worktrees/s3f diff --cached > .build-orchestrator/s3f-c21-interrupted.patch && git -C .worktrees/s3f reset -q`, read the patch, then revert the worktree (`git -C .worktrees/s3f checkout -- . && git -C .worktrees/s3f clean -fd`; ignored `.build*` scratch dirs are untouched). The next fixer is told the patch exists and what it holds. Remove a stale `.build-orchestrator/sim.lock` if no `xcodebuild` or `swift test` process runs. Shut down any simulator of set 1 that is still booted (`xcrun simctl shutdown <udid>`).
    3. If the fixer was cut off mid-cycle: write `s3-fix-args-run8.json` from run 7's (same fields, `fromCycle: 21`) and add to its focus: "A cycle-21 fixer was cut off by the usage limit at <HEAD>, after <the steps the draft and `git log 8e1fb24..HEAD` show>. Continue cycle 21 from the worktree HEAD: read the draft's cycle-21 section and the commit list first, do not redo a finished step, and run every gate on your final HEAD." Launch it with no `resumeFromRunId` (a run resumes only in its own session).
    4. If the fixer had finished (its result is in the journal) and the verifiers were cut off: launch run 8 with `verifyFirst: true` and `fromCycle: 21`, so cycle 21 is verified without a second fix.
    5. Then this bullet's "Next" list continues from the point reached.
- **Earlier (2 Nov 14:15 CET): Stage 3 was STOPPED before WP-F's cycle 21, by the owner's decision. At the owner's request, the read-only profiling run was paused at 14:19, before its report: see "Restart" step 1a. Restart the WP-F cycles from a fresh session on Fri 6 Nov after the 19:00 CET reset: see "Restart" below. Nothing is scheduled.** Fix run 6 (`wf_d6632791-fdd`, session `03c95f5a-f115-421f-9542-6de93e7caf98`) ran from 1 Nov 14:13 and is finished; its cache is same-session only, so it is not resumed.
  - **Owner, 1 Nov ~14:05:** "continue fix cycle from stage 5", read as: continue WP-F from where run 5 stopped (cycle 19).
  - **Usage:** the weekly meter reset early. At 14:08 it read 0 % for all models and for Fable. The next reset is **Fri 6 Nov 19:00 CET**, not Thu 5 Nov 03:00.
  - **Args:** `.build-orchestrator/s3-fix-args-run6.json`: fromCycle 19, maxCycle 30, findings `s3f-c18-issues.json`, simulator set 1, Opus, no usage stop. The focus also names S3-R23.
  - **S3-R23** (14:15, before the run), on the shared host:
    - Context: the owner's ZTronScrollView sessions run simulator UI tests, which held the load at 51–1,008 on 8 cores at 14:09–14:11.
    - Every timing figure carries the load.
    - A miss seen only above load 50 follows S3-R12 and S3-R5.
    - A turn bound is pinned twice: by a deterministic test, and by the BenchSync case taken at load ≤ 10.
    - A case not measured at a quiet load is neither confirmed nor blocking. The orchestrator measures it before ruling convergence.
  - **Keep-awake:** `caffeinate -ims -t 259200` ran from 1 Nov 14:12 and was stopped on 2 Nov at 12:40, when the owner stopped the work.
  - **Watcher:** `watch_journal.py` wakes the orchestrator at each agent result, so put-backs are ruled between cycles. A copy is in `.build-orchestrator/tools/`.
  - **Retired scheduled task:** `ztron-assetkit-resume-after-reset` (Thu 5 Nov 03:10) waited for a reset that had already come.
    - Owner, 1 Nov: "Yes, disable it".
    - `list_scheduled_tasks` shows no tasks at all, so nothing is armed that the tool can disable.
    - As a guard, its `SKILL.md` now says do nothing if it fires. The original prompt is kept in `.build-orchestrator/retired-task-resume-after-reset.SKILL.md`.
    - If the task still appears under Claude app → Scheduled, the owner can delete it there.
  - **At convergence:** the reset the owner's 31 Oct 23:25 decision waited for has come, so the pending list follows, as in the scheduled task's steps 5–8: merge `wp/s3f`, the gates, ADR-057, Stage 5, then the post-stages. The owner can say stop.
  - **Forecast:**
    - A cycle took 4–5 h before (fix 2.5–3.7 h, verification 1.1–1.5 h); under this load, expect about 5–6 h. Each cycle costs about 3.5–4 weekly points.
    - Cycles 13–18 left 7, 5, ~8, 5, 6 and 5 blocking items, so there is no clear trend. Plan for 2–5 more cycles: about 10–30 h and 7–20 weekly points.
    - Re-estimated at 17:20: about 85–90 % that cycle 20 is needed. About 4 cycles counting cycle 19 if the items keep shrinking, about 8 if they stay flat. The plan now reads "Ultra" (it read "Max" at 13:08), and weekly usage was 5 % at 17:20, account-wide.
  - **Cycle 19 fix** ran 14:13–21:30 (7 h 17 min, slowed by the host load) and ended at `49a0493`, 11 commits from `5dd145a`.
    - **Fixes:**
      - moves are bounded per follow turn: `followIDsPerTurn` is 512, with a seam;
      - an owed move's ids take their job's lane;
      - two invariants, removals and doc corrections; RR-18 is withdrawn;
      - `0684845` stops copying an interest's ids for each id moved.
    - **Gates per the fixer:**
      - `VERIFY: PASS`; Sync 552 tests ×3; TSan clean at a mean load of 62;
      - Sync coverage 94.23 %; simulator 1,506/1,506; tools-6.4 builds with 0 warnings;
      - the new C2 cases run 6.67–7.25 ms best at a 1-minute load ≤ 6.28. The benchmarks fail only P-13 (WP-B).
    - **Mutants:** 27 in all; 26 killed 2/2, one removed with its clause.
    - **Put back:** RR-20 (#14), RR-21 (#11), three branches no test reaches, #6, and RR-23.
  - **S3-R24** (21:35, while the cycle-19 verifiers run):
    - RR-20 is not blocking.
    - RR-21 is pinned in the next fix cycle; a miss at load ≤ 10 is blocking.
    - The unreached branches are blocking until reached, removed with an invariant, or shown equivalent.
    - #6 is accepted.
    - RR-23 is a timing difference in RR-16's family.
  - **Cycle 19 verification** ran 21:30–23:22 and left **8 distinct blocking items**. The correctness lens reported 3 blocking of 6 issues, the requirements lens 6 of 10, and both report the flake.
    - The issues are in `.build-orchestrator/s3f-c19-issues.json`, numbered per lens. The probes and scripts are in `.build-orchestrator/s3f-probes-c19/{correct,reqs}/`.
    - Both lenses confirm every cycle-18 item fixed.
    - **C2 (2 items):**
      - the drain gives each waiting verdict its own 512-id budget: 41.6 ms at 8,000 ids, load 5.6;
      - `Job.lane` and `dropInterest` cost O(interests) per id, in code that predates s3-base: 33.7 and 66.4 ms per 512-id turn with 10,000 user waiters, load 7–8.
    - **G4 (5 items):**
      - two subtractions in the bound survive their drop-mutants;
      - the checksum-less lookups are reachable, and the reqs probe reaches them;
      - `waitingTarget`'s queued case, the unspawnable branch and three `EngineMoves` lines are not reached.
    - **Flake (1 item):** `barrierReadmitsBehindTheOwedVisitsPlaces` failed once in the coverage run and twice on the simulator (1 in 60 runs alone). The two lenses read two different mechanisms.
    - **The other gates pass:**
      - `VERIFY: PASS`; Sync ×3; TSan clean;
      - Sync coverage 94.19–94.20 %; the iOS build;
      - every WP-F C2 case within budget at load ≤ 10. The only benchmark failure is P-13 (WP-B).
      - RR-21's commit window measures 9.76 ms best, inside the budget by 0.24 ms.
  - **S3-R25** (23:35): all 8 items are blocking, fixed as the verifiers describe. The ruling adds:
    - C2's reference set is 10,000 ids however their interests are grouped, user waiters included. A cost that predates s3-base is not exempt.
    - per-lane interest counts, with an invariant that recounts them;
    - an inventory of the per-id work in the follow's turns;
    - the flake is settled by observing the engine's own admission order, with the test's tuning unchanged (G3), then a sweep of the tests that assert the transport's start order;
    - `:203` and `:206` are reached, not removed, and no holder epoch is added;
    - the fixer runs the verifiers' covdiff and mutant scripts on its own HEAD before it returns.
  - **Restart so that the fixer reads S3-R25 (23:28–23:29):**
    - The cycle-20 fixer started at 23:21 and read the rulings at 23:22, before S3-R25 existed.
    - It had changed nothing: the worktree was clean at `49a0493`, with no `sim.lock`.
    - The orchestrator stopped task `wge0vsaky` and resumed with the same script and args. The three cycle-19 results came from the cache.
    - A fresh cycle-20 fixer (agent `a1176e45…`) read the rulings through S3-R25 at 23:29.
  - **Forecast (23:35):**
    - Cycle 19 took 9 h 9 min.
    - Cycles 13–19 left 7, 5, ~8, 5, 6, 5 and 8 blocking items, which is flat. S3-R25's self-checks target the two kinds that keep recurring: the fixer's own unreached branches, and per-id C2 costs.
    - Plan for 2–5 more cycles, about 3 expected: 18–45 h.
    - The weekly meter is account-wide, so it includes the owner's other sessions. It went from 0 to 13 % between 14:08 and 23:30, about 1.4 points an hour, or about 10–13 points a cycle.
    - That gives 20–60 points for the cycles, plus 10–20 for the merge, the gates, ADR-057 and Stage 5. The reset is Fri 6 Nov 19:00.
  - **Cycle 20 fix** ran 23:29–03:44 (4 h 15 min) and ended at `8e1fb24`, 13 commits from `8cfc76e`.
    - **Fixed or met** 7 of the 8 items:
      - the drain shares one turn's ids (`drainIDsLeft`, `ddb0ba1`);
      - per-lane interest counts with a recount invariant, and `dropInterest` in place (`f066083`);
      - the unspawnable branch is removed. Trying to reach it found a real path: an admission whose store calls straddle shutdown's start. The admission now re-reads the lifecycle (`429ace5` the failing test, `bf1d4eb` the fix);
      - the flaky test now asserts the engine's admission order (`daa426d`). The engine admitted N first in 60 of 60 runs on the simulator and under coverage, and no other test asserts the transport's start order with more than one attempt in flight;
      - the turn-total pins and the checksum-less target (`ca6df35`), and `EngineMoves :203/:206/:222` reached (`c2f9e31`).
    - **Gates per the fixer:**
      - `VERIFY: PASS`; Sync 561 tests ×3; TSan clean; Sync coverage 94.54 %; simulator 1,515/1,515;
      - the new C2 cases run 4.1–8.0 ms; the commit window is 9.86 ms (inside by 0.14 ms).
      - Benchmarks fail only P-13 (WP-B) and RR-21's two new cases.
    - **Mutants:** 42; 41 killed 2/2 and 1 Equivalent.
    - **Open, blocking:**
      - RR-21: the commit's re-routes take 48.68 ms and the drain's take-off of moved-before ids 45.67 ms, best at load ≤ 5.6. A design is proposed but not built.
      - `waitingTarget`'s queued case: there is only a reading of it.
    - **Put back:**
      - RR-21's design;
      - `waitingTarget`'s window;
      - 4 C2 inventory rows with no figure (`move`'s sort, `deferBehindVerdict`, `recordDeferredVerdict`'s filter, `supersede`'s re-routes);
      - `continueMove` taking the id off `Job.assets` before its guards;
      - `scheduleDrainFollowUp`'s unspawnable branch (0 hits).
  - **Analysis for S3-R26:** `wf_6b2553de-48c` (task `wsmhgi3wg`), launched 03:50.
    - It is read-only and makes no builds.
    - Three independent RR-21 designs (reuse the bounded moves; the fixer's design; fewest states) go to an adversarial judge.
    - Two analysts take the other put-backs: `waitingTarget` and the drain branch; `continueMove`'s order and the inventory rows.
    - The analysts and the minimal design were done by 05:05. Their results are saved as Markdown in `.build-orchestrator/s3f-c20-analysis/`.
  - **Cycle 20 verification** (03:44–05:29, on `8e1fb24`): not converged. correct: 7 blocking of 8; reqs: 5 blocking of 11. The verdicts are in `.build-orchestrator/s3f-c20-issues.json`, numbered per lens, and the probes are in `.build-orchestrator/s3f-probes-c20/`.
    - 7 of cycle 19's 8 items are confirmed fixed. Only `waitingTarget` is left (0 hits).
    - 8 distinct blocking items:
      1. RR-21: the commit's re-routes (47.99–49.34 ms best).
      2. RR-21: the drain's take-off (47.03 ms best).
      3. `supersede` of a superseded publication (41.09 ms).
      4. `deferBehindVerdict` is O(E) a join (35.78–39.55 ms).
      5. `move` re-sorts a holder once per owed move (79.55 ms at 16 moves, 304.79 ms at 64).
      6. The commit-window pin misses: 10.16 ms best at load 3.12 (correct lens); reqs measured 9.82 ms.
      7. `waitingTarget` is still unreached.
      8. `scheduleDrainFollowUp`'s unspawnable branch is unreached.
    - Rows 3–5 are the inventory's "no figure" rows, now measured at a load of 10 or less. The analysts predicted them.
    - No regression: `--quick` PASS, 561/561 ×3, TSan clean, coverage 94.4 %, simulator 1,515/1,515 on both lenses.
  - **Cycle-21 fixer paused** at 05:30, one minute in: TaskStop `wt8pjmmof`, with the worktree clean at `8e1fb24` and no `sim.lock`. Its first start (agent `a36c8f13…`) read the rulings before S3-R26 existed. Resuming starts a fresh fixer, as at 23:29.
  - **Second analysis:** `wf_bc7908d4-1ad` (task `wv109mqwm`), launched 05:37, read-only, **done 08:14** (7 agents, no errors).
    - Three designers took the new C2 items: the deferred joins behind a verdict, `move`'s cost (with `continueMove`'s `Job.assets` removal), and the commit turn's headroom.
    - An adversarial critic checked each design, and an integrator combined them into `.build-orchestrator/s3f-c20-analysis/integrate-c21.md`:
      - item A: a bucket per waiting verdict, placed at the drain's batch formation;
      - item B: a per-job id-to-holders index;
      - item C: commit-window Phase 1, in place, plus a contingent Phase 2;
      - 18 interactions with RR-21, an implementation order, and 5 open questions for the orchestrator.
    - The RR-21 judge had not finished, so the integrator built on `design-minimal.md`.
  - **Analysis 1 at 08:15:** `design:reuse` (agent `afde5b69…`) is still reading code after 4.5 hours. `judge:rr21` has not started. `design-fixer.md` is saved.
  - **Third analysis:** `wf_c114d84e-f12` (task `wuzekt260`), launched 08:20, read-only.
    - Three critics vet `design-minimal`'s RR-21 against the code and `integrate-c21.md`: answers, MUSTs and liveness; C2, G4, pins and reuse; composition with items A–C.
    - An integrator then writes RR-21's section in the same format.
    - The critics were done by 09:02. The answers lens finds the design **unsound**: joining under the copy at the replay reopens RR-14; there is no hold over the publication window; and the site's own `reconcileIdle` prunes the bindings that owed present ids need. The compose lens finds the same prune. The cost lens finds four groupings still above 10 ms.
  - **Analysis 1 done 09:50** (6 agents, no errors). `design-reuse.md` and `judge-rr21.md` are saved.
    - The judge rejects all three designs as written: minimal breaks P-a and RR-14; reuse misses RR-14 and makes a pseudo-follow; the fixer's design keeps a stale copy and has 28 branches.
    - It recommends a synthesis: one `.reroutes` event per site above the bound, a corrected layer chain that picks the copy, a global publication hold, in-place owner updates, and site 2's take-off at once. It has about 20 branches, and the judge puts a clean cycle in RR-21's area at about 0.25–0.35.
  - **Integrator restarted 09:53:** TaskStop `wuzekt260`, then resumed `wf_c114d84e-f12` as task `w8lgfmkvv`, with the critics served from the cache. The new integrator prompt builds RR-21's section from the judge's synthesis, the three critiques and `integrate-c21.md`, and states the orchestrator's intended rulings on the judge's open questions. The critiques are saved as `critic-rr21-*.md`.
  - **Third analysis done 11:00** (4 agents, no errors). `integrate-rr21.md` (1,064 lines) builds RR-21 from the judge's synthesis and the three critiques, consistent with items A–C:
    - A site's own turn makes at most `inboundIDsNow` re-routes, counting its own answers. The rest is one `.reroutes` event, which the drain replays at most `drainIDsLeft` ids a turn, under the copy layers recorded while it waits.
    - While re-routes are owed, there is a global publication hold, no binding is pruned, the watcher stays, and no run settles.
    - It found one more hole: a run that settles mid-drain. The fix is a counter guard in `checkRunSettled`.
    - About 32 branches, 30 tests and 17 BenchSync cases. It puts a clean cycle 21 at about 0.3 in RR-21's area, and about 0.12 for the whole plan.
  - **S3-R26 written 11:10** from `integrate-c21.md` and `integrate-rr21.md`. It answers the 7 RR-21 open questions, the integrator's 9 and `integrate-c21.md`'s 5. The draft is `.build-orchestrator/s3f-c20-analysis/s3-r26-draft.md`.
  - **Ruling review:** `wf_192ea945-460` (task `wuul7n4ml`), launched 11:10, read-only. Two lenses (the bar and earlier rulings; the two specs) looked for contradictions before the ruling is appended.
    - **Done 11:54:** 42 findings (6 must-fix, 24 should-fix, 12 nits), saved as `.build-orchestrator/s3f-c20-analysis/s3-r26-review-v1.md`. The must-fix ones:
      - two tests required at site 2, where their shapes cannot exist;
      - two forms of the commit's `refused` check;
      - a pin case ruled timing that S3-R24 item 5 makes blocking, now a probe (`PROBE-RR21-PIN-END`);
      - a test-change rule looser than G3 and S3-R16 item 4;
      - R18 placed in a step where it cannot exist yet.
    - All 42 are applied in the rewrite (`s3-r26-draft.md`; the first version is `s3-r26-draft-v1.md`). Other changes in the rewrite:
      - labels carry their spec's prefix (`rr21-`, `A-`, `B-`);
      - Phase 2 has four triggers, all landing at step 6;
      - item 3's merge gate has a criterion and a contingency (a lazy index);
      - a decision rule for figures that cannot be taken at a quiet load;
      - a red-first rule for shapes that need the new code (a scratch copy, as S3-R3 does).
  - **Second review:** `wf_de4b1184-3b7` (task `wym0emnzq`), 11:57–12:35, read-only. 33 of the 42 findings are fully resolved. 3 must-fix and 12 should-fix findings remain, saved as `.build-orchestrator/s3f-c20-analysis/s3-r26-review2.md`. **S3-R26 is not appended.**
  - **Owner, 2 Nov ~12:15:** "stop before cycle 21 and write to orchestration to restart from a clean session on Friday. You don't schedule it, I will open a new session and request to resume".
    - The keep-awake (`bcrry29s9`) was stopped at 12:40.
    - Nothing runs: the worktree is clean at `8e1fb24`, with no `sim.lock`.
  - **Owner, 2 Nov ~12:40:** about 150 % of a weekly Ultra allowance went into this work this week (100 % on another account, 38 % on this one), and that many fix cycles to fix what was first built is too much.
    - The orchestrator put a freeze on the table (path A below). The choice is the owner's: only the owner can waive C2 (S3-R20 item 1).
    - Time spent since "continue fix cycle from stage 5" (1 Nov 14:05): about 22 h. Cycles 19 and 20 took about 15 h (fix and verification); the read-only analyses and the S3-R26 work took about 7 h.
  - **Owner, 2 Nov, after the stop:** "can we decide if it's realistically possible to converge to 10ms or it will never happen because during design we were too strict?"
    - The orchestrator's answer is in `.build-orchestrator/s3f-c20-analysis/convergence-2nov.md`.
    - Under 10 ms is technically reachable. The loop under the current bar does not converge: cycles 13–20 stayed at 5–8 blocking, and since cycle 12 nearly every item is a C2 figure or sits in the machinery added to split work over turns.
    - The design was not too strict. SPEC.md:111 makes "~10 ms" a *(hint)* that P-9 proves (heartbeat gap p99 ≤ 50 ms).
    - The hard 10.0 ms per turn at 10,000 ids came from Stage 2's `c2Budget` and from the rulings S3-R5, S3-R16 1(f) and S3-R20 to S3-R25. It was applied to an engine built without bounded turns.
    - Path C below was added.
  - **Restart (Fri 6 Nov, after the 19:00 CET reset, in a fresh session the owner opens):**
    1. Read this block only. Check `get_usage`, that `git -C .worktrees/s3f status` is clean at `8e1fb24`, and that `.build-orchestrator/sim.lock` does not exist.
    1a. **Unfinished: the profiling the owner asked for on 2 Nov ("Profile them").** Do this whenever the owner resumes, even before Friday. It is analysis only: C2 stays 10 ms.
       - **What it is.** The read-only workflow `wf_6927a3a9-c76` started at about 14:00.
         - It profiles commit re-routes, the drain take-off and `supersede` in a scratch copy of `8e1fb24` under `.build-prof40/`, with one profiler and one independent reviewer.
         - The goal is to test the INFERRED cost split in `.build-orchestrator/s3f-c20-analysis/analysis-40ms.md`. That split says formatting the transfer id 3–4 times per id is about 40–50 % of the 41–49 ms turns.
       - **What happened.** The owner asked for a pause, so the run was stopped at 14:19, just before the profiler wrote its report. The reviewer never ran.
         - Done, in `/Users/admin/Documents/ZTronAssetKit/.build-prof40/`: the build, the three CPU profiles, the attribution tables and the micro-timings. The baselines ran on a loaded host.
         - The unreviewed numbers, and the list of what is left, are in `.build-orchestrator/s3f-c20-analysis/profile-40ms-progress.md`.
         - First reading, unreviewed: transfer-id formatting is 16–21 % of the three turns, not 40–50 %. Jobs-table access is 21–27 %. A whole-`EngineState` copy in `decisionNow` is 11–13 %. No single cost dominates.
       - **To resume, do not delete `.build-prof40/`.** Run `Workflow({scriptPath: "/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/tools/wpf-profile-40ms-resume.js"})`, with no `resumeFromRunId`, because a run resumes only in its own session.
         - The resume script is the original plus a RESUME note. The note tells the profiler to reuse the scratch copy, the build and the exports. It then does only what is left: quiet baselines, the verdicts and the report. The independent review follows.
         - Expect about 20–40 min and under 1 weekly point.
         - Timings count only at a 1-minute load of 10 or less (S3-R23). The profile shares hold at any load.
       - **To start over instead:** delete `.build-prof40/`, then run `.build-orchestrator/tools/wpf-profile-40ms.js`.
       - **Then report to the owner,** as "if the ceiling were 40 ms", per the 2 Nov rule: a value the owner floats is analysis, not a ruling.
    2. Ask the owner which path to take, unless they have already said.
    3. **Path A, freeze WP-F at `8e1fb24`** (the orchestrator's recommendation on 2 Nov).
       - Cycle 20's verification left no answer difference. `--quick` PASS, 561/561 ×3, TSan clean, coverage 94.4 %, simulator 1,515/1,515 on both lenses.
       - Of its 8 blocking items, 6 are C2 figures at 10,000 ids in worst-case groupings (41–49 ms, 47 ms, 41 ms, 36–40 ms, 80–305 ms, and 10.16 ms against the 10 ms budget). 2 are G4: `waitingTarget`'s unreached case, and `scheduleDrainFollowUp`'s unspawnable branch.
       - It needs the owner's explicit C2 waiver for those six shapes. Record it, with the figures, in `docs/adr-drafts/s3f.md` and in Stage 5's `docs/RESIDUAL-RISKS.md`.
       - Optional small pass, one fixer and one verifier: remove the unspawnable branch (S3-R26 draft item 6), and add item 5's test. Otherwise record both as residual G4 gaps.
       - Then the post-convergence list: merge `wp/s3f` with `--no-ff`; the tools-6.4 check; the phase-A gates; TSan and `--perf` on an idle host; an independent verifier for P-13; the mutation re-check of the 11 survivors; ADR-057 through `assetkit-level-docs.js`; tag `s3-merged`; remove the s3 worktrees and branches. Then Stage 5.
    4. **Path B, continue the cycles.**
       - Apply `s3-r26-review2.md`'s findings to `.build-orchestrator/s3f-c20-analysis/s3-r26-draft.md`. Fill in its time, and append it to `.build-orchestrator/s3-rulings-s3f.md`.
       - Launch a new run from cycle 21: `Workflow({scriptPath: ".claude/workflows/assetkit-stage3-fix.js", args: <the JSON in .build-orchestrator/s3-fix-args-run7.json>})`. It has `fromCycle: 21`, `findingsFile: s3f-c20-issues.json`, the S3-R26 focus, and no usage stop. Pass no `resumeFromRunId`.
       - Start the keep-awake, `caffeinate -ims -t 259200`, as a background task.
       - Watch with `python3 .build-orchestrator/tools/watch_journal.py <the new run's journal.jsonl> 0 1`. `.build-orchestrator/tools/dump_analysis.py` saves a read-only workflow's results as Markdown.
       - Forecast, 2 Nov: about 3 more cycles (2–5), 30 h or more, 40–50 weekly points, and about 12 % that cycle 21 is clean.
       - Revised later on 2 Nov: there is no end to forecast under this bar. See `convergence-2nov.md`.
    5. **Path C, re-scope C2.** This applies only if the owner rules a new per-turn ceiling. Until then, C2 stays 10 ms.
       - On 2 Nov the owner said 100 ms is too much, and asked for an analysis of 40 ms only: "remember I didn't say to set to 40ms, bar is still 10ms. Just run analysis."
       - The analysis is in `.build-orchestrator/s3f-c20-analysis/analysis-40ms.md`. In short:
         - Each of the five shapes over 32 ms has a fix that splits no work: format each transfer id once, filter before sorting, join in place, use smaller deferred events, and drop the sort and copy per move.
         - The main risk is the "any grouping" rule. The reviewers expect the verifiers to build new groupings, estimated at 35–60 ms even after the fixes.
         - Forecast: about 3–4 cycles (2–5), about 20–40 h and about 45–60 weekly points.
       - If the owner rules a new ceiling:
         - The answer, MUST and G4 bars stay unchanged.
         - Write the ruling as S3-R26 in place of the RR-21 draft.
         - Write a new focus into a copy of `s3-fix-args-run7.json`, then launch from cycle 21.
- **Owner, 29 Oct:** "Finish from Orchestration.md", taken as the go-ahead for Stage 3 and then Stage 5 (Stage 4 stays cancelled).
  - No stop was given, so the orchestrator first applied a default of 70 % (the hunt and the close-outs gated at 65).
- **Owner, 29 Oct 15:2x: "Do not set any budget stop. List P99".**
  - **No weekly-usage stop** for the rest of Stage 3 and for Stage 5: new runs omit `usageStop` (the scripts then call no usage probe). Forecasts are still given in hours and weekly points.
  - The fix run `wf_e5c64595-1d9` was launched with `usageStop: 65` before this and is **not killed** (that would discard two fix agents mid-cycle and leave their worktrees half-edited). If one of its gates reads ≥ 65 %, its close-outs end; resume it at once with `resumeFromRunId: "wf_e5c64595-1d9"` and the same args except `usageStop: 100` (the gate prompts are unchanged, so every finished agent is cached, and 100 % never stops a run that can still run).
  - **P-13 ruled: option A, the p99** ("List P99" read as the ruling; the owner can correct it). Recorded in SPEC §6's P-13 row and ADR-050's 2026-10-29 amendment; no number in `quality-gates.json` changes.
  - Usage at launch: weekly all models 0 %, Fable 0 % (reset Thu 29 Oct 04:00 CET; next reset **Thu 5 Nov 03:00 CET**).
  - Keep-awake: `caffeinate -ims -t 259200` from 29 Oct 08:56 to 1 Nov 08:56 (background, this session).
- **Base:** tag `s3-base` = `b5796ba` (`wpi-merged` plus the Stage 2 hand-off commit).
- **Plan** (PROMPT §4 Stage 3, at most 3 rounds):
  1. **Discovery (done, below)** `wf_124dbd46-f15` (task `wwqhvzu68`), args `{base: "s3-base", usageStop: 65, pool: 4, sim: "897F9D8D-B10D-4D91-8E22-417A2B9D70AA"}`; run dir `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/eaf5a17f-3bdc-4079-a3a3-92d480a65b26/subagents/workflows/wf_124dbd46-f15`. Resume in the same session with `resumeFromRunId`; from a fresh session, read its `journal.jsonl` and re-run only the missing lenses with `only: [...]`. Script `.claude/workflows/assetkit-stage3-hunt.js` (read-only on the repo): a backlog survey (Sonnet; writes `.build-orchestrator/s3-backlog.{json,md}`, which also answers the owner's "non-blocking bugs?" question); six independent hunters (stability, concurrency, crash/fault, security, performance incl. P-13 root cause, conformance/G4), each proving bugs with failing probes copied to `.build-orchestrator/s3-probes/<lens>/`; two mutation agents (Sonnet, ≥ 21 mutants, diffs in `.build-orchestrator/s3-mutants/`); one independent confirmer per hunter. At most 4 building agents at once.
  2. **Triage (orchestrator):** rulings `.build-orchestrator/s3-rulings.md`; findings per work package `.build-orchestrator/s3-findings-<wp>.json`.
  3. **Fix:** `assetkit-closeout.js` per affected work package, `wp: "s3<wp>"` (worktree `.worktrees/s3<wp>`, branch `wp/s3<wp>`, draft `docs/adr-drafts/s3<wp>.md`), from `s3-base`, strict bar, `usageStop: 65`. At most two close-outs at once (6 agents).
  4. **Merge** in dependency order; phase-A gates; then TSan and `--perf` on an idle host; `docs/MUTATION-PROBES.md`; **after merging `wp/s3b`, the orchestrator changes `BenchStorage.swift`'s P-13 assertion from the maximum to the p99** (`StorageBench.percentile(units, 0.99) <= batchBudget`, the maximum still printed; the doc comment's "**maximum** … is asserted" becomes the p99 with the ruling's date), verified by an agent that did not write it and judged in the idle `--perf`; ADR-057 via `assetkit-level-docs.js` (no `usageStop`). Tag `s3-merged`.
  5. **Stage 5** (orchestrator): `verify.sh --full`, VERIFICATION, DEVICE-TEST-PLAN, RESIDUAL-RISKS, TRACEABILITY.
  6. **Tools 6.4 with 0 warnings: an owner requirement (30 Oct).** The owner said: "we design and test this package to pass with 0 warnings on 6.4 and I will manually reset it to 6.0". They also said "Min target stays iOS 15.0".
     - **Toolchain and manifest.** The installed toolchain is Swift 6.4 (Xcode 27.0, 27A266a). The committed manifest stays at tools 6.0, as SPEC §3 (`SPEC.md:84`) and ADR-056 (WPI-R5) require; the orchestrator never commits a tools-version change. The owner's uncommitted line in the main checkout is theirs to reset.
     - **How it is checked.** Use the clean detached worktree `.worktrees/t64`, with only line 1 of `Package.swift` set to 6.4 (never committed). Move it to each new head with `git -C .worktrees/t64 checkout --detach <sha>`, then re-apply line 1. Run the verify modes there, then grep every log for `warning:`, because `-warnings-as-errors` does not cover SwiftPM's manifest warnings or linker warnings. "0 warnings" means both of these: the run ends with `VERIFY: PASS`, and the grep finds nothing.
     - **When it is checked.**
       - (a) On the merged head before s3f's next run. This waits until the design judges finish, so their C2 timings stay undisturbed.
       - (b) After merging `wp/s3f`.
       - (c) Finally, after Stage 5's reports, with `--full`, alongside the committed 6.0 run.
     - **Any warning is a defect.** Fix it in `Sources/` or `Tests/`, never in `Scripts/` or the flags. VERIFICATION.md records both the 6.0 and the 6.4 runs, and ADR-057 records the requirement.
- **Forecast at launch** (strict; Level 5's measured costs, ~0.062 points per dollar): discovery ~11–19 points and ~6–9 h; fix close-outs ~19–37 points and ~15–30 h; merge, gates and docs ~3–5 points and ~3–5 h; **Stage 3 ≈ 33–61 points, ~24–44 h**. Stage 5 ≈ 3–6 points, ~3–6 h.
- **Baseline:** `--quick` at `s3-base` in this session: `VERIFY: PASS` (Transport 151, Sync 351, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104; log `.build-orch/s3/quick-base.log`).
- **Discovery: DONE** `wf_124dbd46-f15`, 08:58–10:46, 30 agents, **$112, weekly 0 % → 5 %** (~0.045 points per dollar). Result: `.build-orchestrator/s3-hunt-result.json`; backlog `.build-orchestrator/s3-backlog.{json,md}` (133 items, 122 open).
  - Hunters: 30 findings; confirmers: 29 confirmed, 1 refuted (S3-CONF-07, recorded as K-11). **13 confirmed blocking:** WP-B S3-SECU-01 (an `Int64` overflow trap in `currentAvailability`), S3-CONF-01/CRAS-01 (SPEC 7.3's crash enumeration missing for update, relocation and removal), S3-CONF-06; WP-C S3-STAB-01/02 (the check-then-act poll class, the known TSan flake among them), plus backlog S3-B-025 (a C2 breach at 10,000); WP-D S3-CONC-01 (background priority order); WP-F S3-CONC-04 (offline failure before the first conditions reading never retried), S3-STAB-03 (TSan time limits), S3-CONF-03, S3-PERF-01/02 (C2 breaches at 10,000).
  - Mutation: 64 mutants (27 storage, 37 network), **11 survived** (M-S-07, 08, 11, 20; M-N-09, 12, 14, 16, 20, 22, 39); diffs in `.build-orchestrator/s3-mutants/`. All go to close-outs as tests (S3-R3).
  - Owner's "non-blocking bugs?" answer (backlog): no blocking bug was open; 4 proven non-blocking bugs (L4-R24(1), L4-R24(2), L5-R16, L5-R22(4)), 11 unproven suspicions, 35 accepted deviations, 33 test gaps, 22 device-only checks, 8 performance limits.
- **Triage:** rulings `.build-orchestrator/s3-rulings-<wp>.md` (general S3-R1…R9 plus per-item levels BLOCKING / REQUIRED / OPTIONAL / ADR-RECORD) and evidence `.build-orchestrator/s3-findings-<wp>.json`, generated by `.build-orchestrator/s3_make_rulings.py`. Close-outs: `s3f` (17 items), `s3b` (14), `s3c` (11), `s3ah` (6; A and H), `s3d` (6), `s3g` (5). No WP-E or WP-K close-out. Left for the orchestrator (Stage 5): e/k/i device items to DEVICE-TEST-PLAN, S3-B-117 (shims across a reopen) to RESIDUAL-RISKS, S3-B-125 README rows, S3-B-129 (the `-collect-test-diagnostics never` flag in `assetkit-stage2-l3-close.js`; that script is retired).
- **Fix: RUNNING** `wf_e5c64595-1d9` (task `w85pou4p2`), launched 10:55 at weekly 5 %: `.claude/workflows/assetkit-stage3-fix.js` runs `assetkit-closeout.js` inline per close-out, two at a time (simulator sets: 897F…/6BE1…/5B94… and 02CE…/7E25…/0E21…), order f, b, c, ah, d, g, strict, `maxCycle: 6`, `usageStop: 65`, verifiers delete their scratch (`cleanScratch`). Worktrees `.worktrees/s3{f,b,c,ah,d,g}` on `wp/s3*` from `s3-base`. Arguments: `.build-orchestrator/s3-fix-args.json`. Resume in this session with `resumeFromRunId`; from a fresh session, read the run's `journal.jsonl` and relaunch the unfinished close-outs with `fromCycle` and the last verification's issues as `findingsFile`.
- **Re-forecast (10:55):** close-outs ~$700–950 → ~35–50 points and ~20–30 h (f is the long pole); merge, gates, mutation re-check and ADR-057 ~3–5 points; Stage 3 should end around weekly 45–60 %, Fri 30 Oct evening to Sat 31 Oct.
- **Progress (30 Oct 03:10, weekly 37 %):** `s3b` converged in 2 cycles (0 blocking), `s3c` in 2 (0 blocking), `s3ah` in 1 (0 blocking). `s3f` cycles 1–4 left 4, 2, 3, 2 blocking; cycle 5's fix is done. `s3d` cycle 1's fix is done. `s3g` has not started. Pace about 2.6 weekly points per hour.
- **Network outage, 30 Oct ~01:57–02:00 CET** (`ENOTFOUND`): the four verifiers of `s3f` cycle 5 and `s3d` cycle 1 died, and the close-out script went on to fix cycles with an empty finding list (`s3f` c6, `s3d` c2). The orchestrator stopped the run at 03:00, saved the interrupted `s3f` c6 draft edit to `.build-orchestrator/s3f-c6-interrupted.patch` and reverted it (no code was touched), and changed `assetkit-closeout.js`: a verifier with no result is retried twice (`:retryN` labels), and a cycle still missing a lens ends the close-out (`out.incomplete`) instead of fixing from a partial list. Added ruling **S3-R10** to `s3-rulings-s3f.md` (S1-15's run test may take `.minutes(5)`; WP-F's cycle-4/5 request).
- **The resume missed the cache (03:01):** `resumeFromRunId` with changed args (`usageStop`, `maxCycle`) and the edited close-out script gave every agent a new key although the task texts were byte-identical, so it re-started the cycle-1 fixers of `s3b` and `s3f`. The orchestrator stopped it within a minute (task `wd4d6i51y`); both worktrees were unchanged. Lesson: a resume is cached only with the same script and the same args; to change either, start a new run from explicit cycle positions.
- **Fix run 2: DONE** `wf_7d85c00a-ec5` (03:08–09:35, 19 agents, ~5.1 M subagent tokens): `s3d` converged at cycle 3 and `s3g` at cycle 1 (0 blocking). **`s3f` did not converge at cycle 8**: 4 blocking (`.build-orchestrator/s3f-c8-issues.json`): the sweep/follow visit-order class again (dropped ids; a moved id's holder that is downloading or queued), a C2 regression from the cycle-8 restructure `1b771e8` (10.0–12.0 ms best at 10,000 with 1 member in 20 changed), and the hang-guard margins awaiting a ruling.
- **Merged (30 Oct 09:45)** `--no-ff` onto `feature/asset-kit`: `s3ah` `f68eb1b`, `s3b` `48b662d`, `s3c` `e92e456`, `s3d` `768e9c0`, `s3g` `d59bcc4` (no conflicts; tag `s3-premerge-1` marks the head before them). Then `d97e4e7`: P-13 asserts the p99 (owner ruling). `wp/s3f` merges after its close-out ends.
- **Gates on the partial merge `d97e4e7`** (clean detached worktree `.worktrees/s3m-gates`, logs `.build-orch/s3m/`): `--quick` `VERIFY: PASS` (Transport 165, Sync 351, Storage 500, Model 89, Kit 90, Compatibility 71, AppleHosted 104); `--gates-only` `VERIFY: PASS` (trace: 1,247 tests with ids). A gates worktree must not sit under a `.build*` path: `gates.py` skips every path containing `/.build`, so trace then finds 0 tests and fails (first attempt, `.build-orch-gates-wt`).
- **Uncommitted `Package.swift` in the main checkout** (`swift-tools-version: 6.0` → `6.3`, modified 29 Oct 20:29; no agent transcript touches it). **Owner, 30 Oct: the owner made it by hand to see whether the latest tools version gives concurrency warnings.** Leave it as it is: do not commit it and do not revert it. Commit only explicit paths (never `git add -A` or `git commit -a`) so it stays out of every commit. The orchestrator's gates run in the clean detached worktree `.worktrees/s3m-gates` at the committed `Package.swift` (tools 6.0, logs `.build-orch/s3m/`). The decision waits for step 6 (the tools-version 6.4 pass).
- **Rulings added to `s3-rulings-s3f.md`:** S3-R10 (S1-15 guard `.minutes(5)`), S3-R12 (hang guards: steady-state load reading from 60 s after the later bundle's start; blocking only on a time-out at mean ≤ 50 or over half in a paired run at mean ≤ 30; raises now: `stalledSubscriberIsBounded` 4 → 6 min, the R-SYN-14 migration-loop wait and the R-SYN-6 owed re-queue 3 → 5 min; the 29 one-minute tests at 50–55 % in the first 35 s are not raised).
- **WP-F design panel: DONE** `wf_8bbbb235-852` (09:52–11:44, 5 agents, ~2.0 M subagent tokens; weekly 49 % at 12:30): three designers prototype (D1 defer every space decision while a follow is owed; D2 an exact pre-phase within a per-turn budget; D3 root cause, free choice, including whether the pump has the same class), each in a detached worktree at `40ecd95`, outputs in `.build-orchestrator/s3f-design/`; then two judges (adversarial correctness; C2, liveness and conformance). Next: rule the design as S3-R11 in `s3-rulings-s3f.md` and continue `s3f` from cycle 9 (`fromCycle: 9`, findings = `s3f-c8-issues.json`, `maxCycle` about 12) with a new run.
- **Panel verdict:** both judges ("break", "c2live") recommend **D3 "root"** as the base, with amendments.
  - **Results:**
    - D3 is the only design with no wrong answer across the 29 cross-design probe tests in both orders.
    - D1 fails TICKET, READ-PROMOTE and READ-ORDER, and needs 11 test adaptations.
    - D2 fails 12 tests (5 even with its pump extension).
    - All three meet C2 at 10,000: 7.4–8.8 ms best-of-3, against 13.2–14.2 ms at base.
  - **Amendments before the fixer starts** (`j-break`, `j-c2live` results in the run's `journal.jsonl`):
    - A deferred `.enqueue` keeps `front:` and `queuedAt`, and `reinstate` goes through the event list.
    - The "queued jobs wait in no queue" invariant exempts pending `.enqueue` jobs (`j-break/d3-amendment-A1-invariant.diff`, 415/415).
    - FAILURE-ORDER becomes `.attemptFailed` events (PROBE-J-FAIL-REROUTE and -FAIL-TICKET).
    - The pump is barred on `followBarrier` during a multi-turn drain.
    - SECOND-APPLY-REORDER keeps `followOrder[followNext...]` in order.
    - Every designer and judge probe is committed failing-first.
  - **Orchestrator rulings needed (S3-R11):**
    - (R1) Where the class ends. The judges lean to (a): real-world ledger inputs (freed bytes, free-space reads) apply on arrival, D3's `.read` deferral is dropped, L4-R7 is kept, and READ-ORDER, READ-PROMOTE and UNRELATED-FREE are out of the class.
    - (R2) The R-SYN-2 assertion `between.steady == .downloading` becomes `.queued`. Admissions then wait for a multi-turn follow: 131–143 ms at 10,000 on macOS release; not measured on a device.
    - (R3) G3 records for D3's six one-to-one assertion replacements.
- **Fix run 3: RUNNING** `wf_87a53c2d-041` (task `wsitz52bo`), launched about 12:55 on the owner's "Launch on D3", at weekly 49 %, with no usage stop.
  - **Scope:** `s3f` only, from cycle 9 (`fromCycle: 9`, `maxCycle: 12`), with simulator set 1 (897F…/6BE1…/5B94…).
  - **Inputs:** findings `s3f-c8-issues.json`; the args are saved in `.build-orchestrator/s3-fix-args-run3.json`.
  - **Rulings added** to `s3-rulings-s3f.md`:
    - **S3-R11:** D3 with amendments (a)–(f); R1 option (a), so real-world ledger inputs apply on arrival and L4-R7 is kept; R2 (the R-SYN-2 assertion becomes `.queued`); R3 (one-to-one G3 records); the failing-first test list; C2.
    - **S3-R13:** 0 warnings at tools 6.4, checked in a `git archive` export. Nobody edits `Package.swift`.
    - **S3-R14** (17:55, before cycle 11's fixer starts): close the class by inventory. The cycle-11 fixer tables every decision site in `Engine/` and how it waits or why it is R1. Verifiers check the table; a missing or wrong row is blocking. In class: the cycle-10 fixer's six recorded residuals, amendment (e) with an incomplete old pass, and a withdrawal that overtakes a deferred answer (the engine's removal waits; the public layer may still answer a cancelled caller at once). Also: tests for the two unreached replay branches, with the mutant shown failing, and kill-or-prove-equivalent for `noDispatchOwedFlag` and `noFlagPump`.
  - **Cycle 9:** the fix ran 12:34–14:55 (`719ce20`) and verification 14:55–15:55. It found 4 blocking (reqs) and 6 blocking (correct), 8 distinct.
  - **Cycle 10:** the fix ran 15:55–17:28 (`5203ccb`) and fixed all 8, each with its failing test first. Gates per the fixer:
    - `VERIFY: PASS`; Sync has 448 tests; the simulator ran 1402 of 1402.
    - TSan passed (0 warnings; the longest one-minute test took 18.95 s), and the tools-6.4 export has 0 warnings.
    - C2: follow end 3.3–4.0 ms, drain turn 3.7–4.1 ms. P-13 fails again (WP-B's).
    - The fixer recorded 6 residuals and amendment (e) as open; S3-R14 rules on them.
  - **Verification for cycle 10** started 17:28. Weekly usage was 56 % at 17:45 (about 3.5 points per cycle).
    - Results (to 18:47): correct had 5 blocking (two of them regressions from cycle 10's own fixes); reqs had 3 blocking (mostly S3-R14 items still open).
  - **Cycle 11:** the fix ran 18:47–22:20 and ended at `3a86b92`.
    - `6cc4d92` defers every barrier decision to the drain in arrival order. The inventory (I1–I38) is in the draft.
    - Gates: `VERIFY: PASS`; Sync has 460 tests; the simulator ran 1414 of 1414.
    - The fixer asked for rulings on residuals R-A–R-E and PROBE-C9-THROTTLE.
    - Correct verifier (to 22:54): 5 blocking, all from one root cause: replays and visits read non-ledger real-world inputs (throttles, conditions, edge) as the drain leaves them. Also: R-A proven, 0-hit replay branches, and wrong inventory rows.
  - **S3-R15** (23:30, before cycle 12's fixer starts): one view of the world per decision instant, as a single mechanism. Replays read the inputs as of their arrival; visits read them as of the apply.
    - A 429 throttles on arrival, using the followed lane.
    - R-A, R-C, R-D and PROBE-C9-THROTTLE are in the class. R-B is split: breaker decisions are in, pure metric counters are out.
    - R-E (the store-work stall) is to be diagnosed as a liveness defect.
    - Every replay branch must be reached by a test, with its mutant shown failing.
  - **Cycle 12 is this run's last** (`maxCycle: 12`). If it still blocks, start a new run from cycle 13 with cycle 12's issues as `findingsFile`. Weekly usage was 63 % at 23:17.
- **Fix run 3: ENDED, not converged** (12:55 on 30 Oct → about 03:15 on 31 Oct; 12 agents, ~2.55 M subagent tokens; weekly 49 % → 66 %).
  - Blocking by cycle: c9 4+6, c10 5+3, c11 5+5, c12 6+5 (reqs+correct, with overlap).
  - **Cycle 12 fix:** 23:3x–02:2x, head `3f10eaa`, under S3-R15.
    - `2e22cf6` keeps a history of world views. Events carry arrival stamps and follows carry apply stamps. A 429 throttles on arrival with `followedLane`. R-A's commit is deferred.
    - R-E was the probe's own wait, not a liveness defect. `noDispatchOwedFlag` is killed.
    - Gates per the fixer: `VERIFY: PASS`, Sync 474, simulator 1428/1428, TSan clean, tools-6.4 0 warnings.
  - **Cycle 12 verification:** 11 blocking, about 8 distinct. The issues are in `.build-orchestrator/s3f-c12-issues.json` (19 issues); the probes are in `.build-orchestrator/s3f-probes-c12/`.
    1. The new test `barrierRetriesBehindTheOwedVisitsPlaces` is flaky. It hung in 4 of 6 bundle runs; the cause is a setup race, and the verifiers' runs of `--quick` ended `VERIFY: FAIL`.
    2. R-I is proven: a place stamp admits with no free slot. N's request goes out under a live 60 s throttle, which breaks R-SYN-5. This is a regression from cycle 12.
    3. R-H is proven twice: `followedLane` ignores interests that another owed visit moves. The backoff is wrong, or the decision is `.undecided` and leaves the origin unthrottled, so a manifest request goes to an origin that has just returned a 429.
    4. R-C is not implemented.
    5. The R-A integrity-failure remainder is open.
    6. 12 surviving mutants and 0-hit replay branches (G4).
    7. Inventory rows are uncited or stale.
    - Non-blocking but unproven: a follow visit now removes a verifying or committing job, freeing its headroom while the store still publishes.
  - **Orchestrator assessment:** eight cycles (5–12) on one class have not converged. Each fix adds machinery, and the verifiers find new members in it; cycle 12's fix introduced a SPEC MUST break (R-I).
  - **Scope decision put to the owner (31 Oct ~03:30)**, as promised at 23:30:
    - (A) narrow the bar to observable correctness, the recommendation;
    - (B) a design panel for a full freeze: every input queues during a multi-turn follow, which reverses R1 and L4-R7 and reworks cycles 9–12;
    - (C) keep the strict bar and cycle.
  - **Nothing is running.** The `wp/s3f` worktree is clean at `3f10eaa`.
  - **Next run:** `fromCycle: 13`, `findingsFile` `s3f-c12-issues.json`, plus the ruling that follows from the owner's choice.
- **Owner, 31 Oct: "Narrow the bar"** (option A). This is ruling **S3-R16** in `s3-rulings-s3f.md`.
  - **Blocking:**
    - a different answer to a caller;
    - a broken SPEC MUST or invariant (R-SYN-5: nothing goes to a live-throttled origin, and a 429 always throttles on arrival; space safety);
    - liveness and flakiness;
    - G4 for code that stays;
    - the gates.
  - **Recorded as residual risks:** order, place and timing differences.
  - **Simplification is preferred:** for example, removing the place stamps behind R-I. One-to-one test records apply (G3).
  - ADR-057 records S3-R16 as the owner's decision.
- **Fix run 4** (args in `.build-orchestrator/s3-fix-args-run4.json`): `s3f` from cycle 13 to 16, findings `s3f-c12-issues.json`, simulator set 1, no usage stop. **STOPPED 16:41 after cycle 14** `wf_94baddee-151` (task `wybwtb9zp`), launched 31 Oct 09:46 (the owner's answer came in the morning) at weekly 66 %.
  - **Owner, 31 Oct ~10:00: "No cap".** WP-F runs until it converges under S3-R16. If cycle 16 still blocks, rule and start a new run from cycle 17. Do not offer the cap again.
  - **Cycle 13 fix** ran 09:46–12:19 and ended at `314eedb`. It fixed the hang, R-I, UNDECIDED-LANE and R-C (a probe showed R-C changes an answer).
    - It removed 11 pieces of order-only machinery under S3-R16 item 3.
    - All 34 mutants are tabled: every branch that stays is killed 2/2, and alarmAtPark is equivalent by reasoning.
    - Gates per the fixer: `VERIFY: PASS`, Sync 483 tests, simulator 1437/1437.
    - Verification started at 12:19. Weekly usage was 68 % at 12:37.
  - **S3-R17** (12:45) answers the fixer's put-back: S3-R16 1(a) conflicts with 1(b) when the visit-first answer needs admission to a live-throttled origin.
    - The MUST wins, and live origin gates (throttle, breaker, reachability and conditions) join R1's real-world inputs.
    - The two changed answer assertions are authorised one-to-one.
  - **Cycle 13 verification** found 4 + 3 blocking: two were the S3-R17 conflict; the real ones were PURGE-JOIN, STAMP-NO-SLOT, EXHAUST-LANE, STAMP-BREAKER (liveness) and two 0-hit branches.
  - **Cycle 14 fix** ran 13:10–15:22 and ended at `388f744` (9 commits from `85636a1`). It fixed all of cycle 13's blocking items.
    - Gates per the fixer: `VERIFY: PASS`, Sync 495 tests; ×3 and TSan clean; simulator 1449/1449; Sync coverage 93.93 %.
  - **Cycle 14 verification** ran 15:22–16:21. Both lenses confirm every cycle-13 item is fixed and the gates pass. They found 3 + 2 blocking in three groups:
    - **the place stamp's slot view** (PROBE-C14C-STAMP-AHEAD): a place ahead that visit-first started is not counted, and K2 is refused on a past throttle;
    - **the passed-publication mark** (C14C-MARK-TWO-APPLIES, C14C/C14R-PASSED-LANE, C14R-PASSED-FAIL): answer differences; RR-1's remainder is not a residual risk;
    - **G4:** followedLane's new branches have 0 hits.
  - **S3-R18** (16:30), written after cycle 15's fixer had started (16:21) and delivered to it by message at 16:31; it re-read the ruling before changing any code.
    - Remove the place stamps' admission: the barrier-end pump reads only the live gates. Sweep-first answer assertions that expected a stamp's past view may change one to one (visit-first assertions never change).
    - A passed publication re-routes its moved ids at once (the requirements verifier's simplification); the mark, `followPassedPublication` and followedLane's publishing-job skip go. Per-pass id lists are the fallback only if a probe shows a MUST breaks.
    - Put-backs: finding 11 is accepted as a residual risk; `failureMoveBehindBarrier` is killed or removed; RR-2 and RR-4 are not blocking.
  - **Cycle 15 (run 4) was stopped at 16:41; run 4 ended there.**
    - **What happened:** a `SendMessage` to the running workflow fixer did not reach it. It started a second copy from the fixer's transcript, in the same worktree. That copy read S3-R18, saw the other writer, made no edits, and handed back an unverified analysis. The original fixer never got S3-R18 and was writing the stamp fix S3-R18 rules out (counting places ahead).
    - **Kept:** the original's unfinished tests are on `wip/s3f-c15a` (`5a87864`). `wp/s3f` is clean at `388f744`. The copy's analysis is in `.build-orchestrator/s3f-c15-handback-analysis.md`.
    - **S3-R18a** (16:42) adds the case the copy found: a later apply while the earlier follow is owed. It also names the inputs above.
  - **Lesson: never `SendMessage` a workflow agent.** It starts a duplicate that writes in the same worktree. To change a running fixer's brief, stop the run and relaunch from the same cycle with the ruling in the rulings file.
- **Fix run 5** (args in `.build-orchestrator/s3-fix-args-run5.json`): `s3f` from cycle 15 to 18, findings `s3f-c14-issues.json`, simulator set 1, no usage stop, Opus. **RUNNING** `wf_7c1faaa8-af9` (task `w0kg1yplq`), launched 31 Oct 16:43 at weekly 72 %.
  - **Resume:** in this session, use `resumeFromRunId` with the same args. From a fresh session, read `subagents/workflows/wf_7c1faaa8-af9/journal.jsonl` and start a new run from the next cycle with the last verification's issues as `findingsFile`. Run 4 (`wf_94baddee-151`) is finished: do not resume it.
  - **Cycle 15 fix** ran 16:43–18:28 and ended at `e64cdba` (`b461450`, `0f32845`, `9673e2f`, `e64cdba`).
    - **S3-R18 is done:** the place stamps are removed, a passed publication re-routes its moved ids at once (`rerouteOnPass`, two applies included), and `followedLane` is non-optional.
    - **Gates per the fixer:** `VERIFY: PASS`; Sync 511 tests ×3, TSan clean; simulator 1465/1465; Sync coverage 93.84 %. The benchmark failure is P-13 (WP-B).
    - **Mutants:** two survive (`laneJobsWalkAlways`, `spaceFailureEpochDropped`).
    - **Put back:** a verdict that waits across a later apply; the publication failure's await window; a drain-turn seam.
  - **Cycle 15 verification** started 18:29. Weekly usage was 74 % at 18:35.
  - **S3-R19** (18:36) rules on cycle 15's put-backs:
    - the two analysed items are probed first and are blocking only if item 1 breaks (smallest fix);
    - a cost-only mutant is equivalent;
    - the defensive check is removed, turned into an invariant, or recorded as pre-existing and out of class.
  - **Cycle 15 verification** ran 18:29–19:50. The two lenses found 5 + 6 blocking items; every cycle-14 item is confirmed fixed. The new items:
    - S3-R19 item 1's two analysed cases, probed in both orders and both real: a verdict waiting across a later apply, and the publication failure's await window;
    - a re-route answer difference new in `0f32845` (S3-R18a);
    - `laneJobsWalkAlways` is not cost-only and `spaceFailureEpochDropped` is reachable (G4);
    - a test race from `0f32845`, which fails the Sync bundle under TSan (flaky).
  - **Cycle 16 fix** ran 19:50–22:35 and ended at `aa2b444`, after 12 commits from `39e18d2`.
    - The fixer reported `--quick` PASS, Sync 528 tests x3, TSan 528 passed, Sync coverage 93.99 % and the simulator at 1,482/1,482.
    - It declined 5 items, all covered by S3-R19: P-13 is WP-B's; RR-2, RR-4 and RR-10 are unprobed; there is no 10,000-job `followedLane` benchmark; `laneJobsWalkAlways` is cost-only; it made no `--full` run.
  - **Cycle 16 verification** ran 22:35–23:48. The reqs lens found 5 issues (2 blocking) and the correct lens 9 (4 blocking), about 5 distinct, all probed:
    - a setup race in cycle 16's new test `barrierRetriesAFailedPublicationWithNothingOfItsEnd` (WindowTests:211, 23 of 120 copies). The verifier's fix is probe-checked: gate the first conditions reading.
    - RR-11 is an answer difference, not only a lane-policy one. `verdictAnswers` misses `retryLater`'s answer when the Retry-After exceeds the lane's maxRetryAfter; both lenses found this, and it breaks R-SYN-5. It also counts no answer for a waiting 429's park fail-fast. The offline and ENOSPC fail-fasts are the same, unprobed.
    - The re-route set of a waiting verdict misses an id that a later apply maps back to the job's own content.
    - Older than cycle 16: two applies inside one owed follow skip the intermediate content (a different error, and different bytes; 2 of 2 runs). The verifier offered to have it ruled out of scope as a residual risk. It was not ruled out: S3-R16 item 1(a) makes an answer difference blocking.
    - Non-blocking:
      - no "Cycle 16 adds:" document proposal;
      - two surviving condition mutants, equivalent by analysis;
      - P-13 (WP-B);
      - P-11 misses that depend on load;
      - two other-WP tests that failed only while the verifiers' simulator runs overlapped (load up to 782), and passed alone.
  - **Cycle 17 fix** started 23:48 automatically. Weekly usage was 83 % at 23:50. Forecast: cycle 17's verdict about 03:50 (about 87 %) and cycle 18's about 07:50 (about 91 %). Cycles 19 and 20 in run 6 would end at about 95 % and 99 %, and the limit stops cycle 21.
  - **Cycle 17 fix at 02:31:** 8 commits, `05f94cc` to `346a8cb`.
    - The flaky test is fixed, and failing-first tests cover every cycle-16 item.
    - The fix, `5843c41`:
      - whom a waiting verdict answers is now read through the functions its replay uses (`retryDelay`, `failFastError`, `spaceVerdict`);
      - ids that a later apply maps back to a job whose verdict waits are taken off before the verdict and re-routed after it;
      - `bringInbound`: when an attempt ends while a follow is owed, its job gets the interests the owed visits would move there.
    - Then G4 tests, removal of order-only placement (S3-R16 item 3), and 10,000-job walk benchmarks.
    - **Put-back:** `bringInbound` makes its moves in one turn, about 400 ms with 10,000 ids converging on one content, which breaks C2.
    - **S3-R20 (02:34):** this is blocking unless the owner waives C2. The verifiers measure it, and a fix must keep every turn within C2.
  - **Usage at 02:31: 89 %** (85 % at 01:31).
    - This machine's agents used about $18 in that hour, roughly 1 point.
    - The rest came from use elsewhere on the account; the Fable bar also rose from 12 to 14 %.
  - **Put to the owner at 02:40:** switch WP-F to the full-freeze design (option (B) of 31 Oct 02:22)? The evidence:
    - 4 of cycle 16's 5 items came from cycle 16's own code;
    - cycle 17's fix adds about 400 engine lines, and its new step collides with C2, the constraint the owed follow exists for.
  - **Owner, 1 Nov 02:39: "No, keep fixing".** The full freeze is declined a second time; the first was "Narrow the bar" on 31 Oct.
    - Keep cycling until convergence, with S3-R20 in force: C2 is not waived.
    - Do not offer the freeze again at each verdict. Raise it again only on a new kind of evidence: a liveness failure, or a C2-bounded fix that cannot keep the answers equal.
  - **Cycle 17 fix** ran 23:48–03:29 and ended at `e1cf3e5`, 10 commits from `05f94cc`.
    - The fixer reported `--quick` PASS, Sync 537 tests x3, TSan 537 passed alone, Sync coverage 94.17 % and the simulator at 1,491/1,491. The benchmarks failed only P-13 (WP-B).
    - It put back 3 items: `bringInbound`'s C2 cost, RR-14, and PROBE-C17-ADMIT-DURING-APPLY. It did not see S3-R20, because it started before the ruling.
  - **Cycle 17 verification** ran 03:29–04:44. The reqs lens found 6 issues (4 blocking) and the correct lens 5 (5 blocking), 6 distinct. Every cycle-16 item is confirmed fixed. The new items:
    - a waiting retry verdict converts an HTTP-date Retry-After at the drain, not on arrival: a different answer;
    - RR-14 is proven by both lenses: an id moved twice during a publication skips that publication's outcome;
    - C2: `bringInbound` measured 408 to 432 ms at 10,000 converging ids (S3-R20);
    - C2, older than cycle 17: the owed follow's own turns take 17.7 to 19.1 ms in the 10,000-member concentration shape, because `addInterest` joins through copies of the Job;
    - G4: four cycle-17 mutants survive, the `rerouteOnPass` narrowing and three stamp or take-off drops.
    - Non-blocking: a start-count difference when `bringInbound` meets a superseded holder (record it as a residual risk), and WP-B benchmarks that missed under a load spike.
  - **S3-R21 (04:46):**
    - The follow's own turns in the concentration shape are inside C2, so they are blocking; fix by joining in place and, if needed, bounding the turns by work.
    - S3-R20 stands for `bringInbound`, and RR-14 is blocking.
    - PROBE-C17-ADMIT-DURING-APPLY is pre-existing and outside the class, so it is not blocking. It goes in the residual risks and is marked for the owner in Stage 5: a wrong `notFound` under a race.
    - Cycle 17's issues are in `.build-orchestrator/s3f-c17-issues.json`.
  - **Cycle 18 fix** started 04:44 automatically, with S3-R20 in the rulings file. S3-R21 reaches cycle 18's verifiers and the next fixer. Weekly usage was 94 % at 04:45, so the limit will probably cut cycle 18 off between about 07:00 and 08:30.
  - **Cycle 18 fix** ran 04:44–07:54 and ended at `4b1c3a6`, 13 commits from `d788d75`.
    - Its fixes:
      - a Retry-After date is now read on arrival;
      - interests join in place;
      - the moves an attempt's end or an apply owes now run over the follow's turns (S3-R20);
      - RR-14 is fixed by a walk at each apply.
    - The fixer reported `--quick` PASS, Sync 543 tests, Sync coverage 94.02 % and the simulator at 1,497/1,497.
    - It recorded RR-16 (a start-count difference), RR-17 (PROBE-C17-ADMIT-DURING-APPLY, per S3-R21) and RR-18 (unprobed, put to the orchestrator).
  - **Cycle 18 verification** ran 07:54–09:18. The correct lens found 6 issues (1 blocking) and the reqs lens 9 (4 blocking).
    - Every cycle-17 item is confirmed fixed, including the S3-R20 and S3-R21 C2 items (408 ms and 17.7 ms before).
    - The new items:
      - PROBE-C18C-PENDING-LANE: cycle 18's owed moves make `followedLane` decide a 429 on the wrong lane, when a move's target is a failed job whose verdict waits and a later apply was followed;
      - C2: a single visit or owed move that carries 10,000 ids takes 54–56 ms in one turn;
      - G4: five surviving drop-mutants of cycle 18's deferral code, branches never run, and the unpinned release paths of the publication's wait for owed moves (liveness).
    - Non-blocking:
      - a timing-only difference from the publication's wait;
      - a C2 benchmark that missed only under load;
      - P-13;
      - doc and invariant notes;
      - RR-18's difference may not exist.
  - **Run 5 ended 09:19** after cycle 18 (12 agents, 0 errors). Weekly usage was 99 %, so run 6 waits for the reset.
    - **S3-R22 (09:20):**
      - the many-ids-in-one-turn shape is inside C2, so it is blocking;
      - RR-18 is not blocking;
      - simulator and coverage runs take turns under a lock directory.
    - Cycle 18's issues are in `.build-orchestrator/s3f-c18-issues.json`.
    - **Run 6 is ready:** `.build-orchestrator/s3-fix-args-run6.json`, with fromCycle 19, maxCycle 30, the c18 findings, and a focus that names S3-R20 to S3-R22.
      - The worktree is clean at `4b1c3a6`, and no build or test processes are left.
      - After the reset, launch `.claude/workflows/assetkit-stage3-fix.js` with those args.
    - Blocking items per cycle: 7 in cycle 13, then 5, about 8, 5, 6 and 5 in cycles 14 to 18. Cycle 18's 5 include only 1 answer difference (cycle 17 had 2); the rest are 1 C2 shape and 3 G4 test-strength items.
  - **Signal for the owner:** 4 of cycle 16's 5 items come from cycle 16's own additions (3 in new code, 1 a new test), and 1 is an older structural gap. As promised on 31 Oct at 22:12, if cycle 17's verifiers again find new cases in the same logic, put the full-freeze alternative back in front of the owner. That is option (B) of 31 Oct 02:22: about 2 h of design panel plus 2–3 cycles, 12–16 weekly points. Unused weekly budget does not carry over, so cycles run this week cost next week nothing.
  - **For run 6's args:** both verifiers ran simulator suites at the same time as timing-sensitive macOS runs, and the load reached 782. That caused two other-WP flakes and a coverage re-run. Add to the focus: take a lock (`mkdir .build-orchestrator/sim.lock`, removed afterwards) around each simulator or coverage run.
  - If cycle 18 still blocks, rule and start run 6 from cycle 19 (no cap).
  - **Owner, 31 Oct 23:25: "when we do not need any more cycle, we stop. We'll continue next reset."**
    - Keep running WP-F cycles until a verification has 0 blocking items. If cycle 18 still blocks, rule and start run 6 from cycle 19.
    - **At convergence, stop.** No merge, no gates, no ADR-057, no Stage 5, no post-stage work: everything after convergence waits for the Thu 5 Nov 03:00 reset. Record the converged cycle and HEAD here.
    - If the weekly limit stops the agents mid-cycle, resume that cycle after the reset; committed work stays on `wp/s3f`.
    - **After the reset, start with** the merge of `wp/s3f`, then the pending list (6.4 check (b), phase-A gates, TSan and `--perf`, the P-13 verifier, the mutation re-check, ADR-057, Stage 5, then the facade method and the Electron app).
    - **Scheduled 31 Oct 23:31: one-time task `ztron-assetkit-resume-after-reset`** (Claude app → Scheduled; file `~/.claude/scheduled-tasks/ztron-assetkit-resume-after-reset/SKILL.md`) fires **Thu 5 Nov 03:10 CET**.
      - It runs only while the app is open; otherwise it runs at the next launch. It starts in the default permission mode unless the owner sets one on the task.
      - Its pre-flight launches nothing if weekly usage is above 10 %. It also checks that no earlier workflow is still writing.
      - It then finishes WP-F if needed and works through the list above.
      - **Keep-awake (owner, 23:37: "Yes, keep it awake"):** `caffeinate -ims` runs from 31 Oct 23:37 to Thu 5 Nov 05:00, so the task fires on time.
        - It is a background task of session `eaf5a17f`, so it ends if that session or the app stops.
        - Lid closed or battery power can still let the Mac sleep.
  - **Owner, 31 Oct ~10:05: "Keep Opus".** The owner was offered a Fable fixer and kept every close-out agent on Opus (no `models` arg). To resume in this session, use `resumeFromRunId` with the same args. From a fresh session, read its `journal.jsonl` and start a new run from the next cycle.
  - **Resume:**
    - In this session, use `resumeFromRunId` with the same script and the same args.
    - From a fresh session, read the run's `journal.jsonl` and start a new run from the next cycle with the last verification's issues as `findingsFile`.
- **Tools-6.4 probe (a): PASS, 0 warnings** (`.worktrees/t64` at `9adfa91`, manifest line 1 = `// swift-tools-version: 6.4`, logs in `.build-orch/t64/`).
  - `verify.sh --quick`: `VERIFY: PASS`, with the same counts as at tools 6.0: Transport 165, Sync 351, Storage 500, Model 89, Kit 90, Compatibility 71, AppleHosted 104.
  - Release build: complete. iOS generic build: exit 0, with the iOS objects in `Debug-iphoneos`. xcodebuild prints an `IDERunDestination: Supported platforms … is empty` line, which is not a warning.
  - The grep for `warning:` over every log found 0 lines.
  - Still to come: (b) after merging `wp/s3f`, and (c) the final `--full`.
- **Queued after every stage (owner, 30 Oct; choices not settled, the question form was cancelled):**
  - (1) A facade method that decides at run time whether iOS 26+ is served by AWS or Apple-hosted packs. Today `TierSelection.select` decides once, at client build, with a static `awsOnly`.
  - (2) A simple Electron app with these features:
    - browse the remote manifest's assets, update or delete parts, and add assets;
    - `.gguf` support for Qwen LLMs;
    - one interface that uploads to both Apple-hosted packs and AWS (CloudFront + S3);
    - upload correctness checked "in the sense of this package";
    - a log written before every upload.
  - Owner: "All of this is executed by an Opus agent on Medium effort" (`model: "opus"`, `effort: "medium"`; an independent Opus-medium verifier per P4).
  - **Owner answers (30 Oct, about 12:50):**
    - **What drives the tier decision:** "A method on the interface of the facade". The app chooses AWS or Apple-hosted for iOS 26+. `TierSelection.select` (R-APL-5) gains the choice as one more pure input, and keeps its exhaustive tests and its single `#available`. It is a public-API addition, so it is NEEDS-HUMAN-REVIEW, and it needs a new SPEC row.
    - **When a change takes effect:** "When I next push an update to the app store for app users, right now in dev mode". So the choice is fixed per app build and read when the client is built. There is no live switch.
    - **Where the app lives, and npm:** "In Documents folder, you can use NPM only on for the Electron app". Folder: `/Users/admin/Documents/ZTronAssetManager`, its own local git repo. The npm registry is allowed for that folder only; CLAUDE.md's network rule still holds everywhere else, and this Swift package stays dependency-free.
    - **Qwen models over 4 GiB:** "Planning to use a 500MB model, preserve the 4GB limit for now. If it's not an hard rule enforced by Apple, we might provide a configuration method on the facade of this package".
      - Keep `maxAssetBytes` at 4 GiB.
      - It is already configurable on the facade: `AssetClientConfiguration.limits: ManifestLimits`, `maxAssetBytes`, R-MAN-2 and ADR-048.
      - The agent checks Apple's asset-pack size limits in the Apple developer documentation and records them. If Apple has no hard limit, it proposes a facade configuration method; it does not change the 4 GiB default.
  - **Never in tests:** real uploads or deletions on AWS or App Store Connect. The owner does the first real upload.
  - **Owner, 31 Oct ~14:20:** "I don't need the Electron App to run on UltraCode, medium effort is ok". So the two items run differently:
    - **(2) The Electron app:**
      - No workflow fan-out and no close-out cycles.
      - One Opus agent at `effort: "medium"` in `/Users/admin/Documents/ZTronAssetManager`, which is outside this repo, so P4 does not bind it.
      - The orchestrator then runs the app's own build and tests itself and reports the output.
      - No separate verifier, unless that check fails.
    - **(1) The facade tier method:** it changes this package, so CLAUDE.md applies (P4, gates). It runs as one Opus-medium fixer plus one independent Opus-medium verifier pass. Ultracode does not apply.
    - **Estimated cost:** about 4–7 weekly points for both items, against the earlier 6–11.
- **Still open for the owner:** the NEEDS-HUMAN-REVIEW list (ADR-050 without P-13, 052, 055, 056).

## Stage 2 — COMPLETE (`wpi-merged` = `0554b8f`, 24 Oct 15:20 CEST). Next session: start here
- **State.** Stage 2 is complete: `l5-merged` (WP-G + WP-K), then WP-I (README, ADR-056).
  - Nothing is running. There are no worktrees and no `wp/*` branches, and `feature/asset-kit` is clean.
  - Weekly usage is **66 %** (Fable 34 %, the owner's own use). It resets **Thu 29 Oct 04:00 CEST**.
  - `caffeinate` runs until 25 Oct 11:42, as background tasks of session `d8335845-…`; start a new one for the next run.
- **Gates at `wpi-merged`:** `--quick` gave `VERIFY: PASS` (Transport 151, Sync 351, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104), and `--gates-only` gave `VERIFY: PASS` (logs `.build-orch/wpi/summary.txt`).
  - Earlier, at `l5-merged`: coverage PASS, the simulator 1,305/1,305, whole-package TSan with 0 reports, and `--perf` 34/35 (only P-13 fails, the owner item).
- **WP-I:**
  - `wf_3045417c-704`: README, the round-2 verification found 0 blocking; $44.
  - `wf_915bed8f-166`: ADR-056, round 2 found 0 blocking; $23.
  - Rulings WPI-R1…R9 are in `.build-orchestrator/wpi-rulings.md`.
  - The WP-I workflow script is `.claude/workflows/assetkit-wp-i-docs.js`.
- **Owner questions:**
  1. P-13 (ADR-050): option A, the p99 per batch, recommended; or option B, `batch_ms_max` raised to 15 ms. Stage 5's `--full` needs it.
  2. The NEEDS-HUMAN-REVIEW list in DECISIONS.md, now including ADR-055 (K-2/K-3/K-5/K-6/K-15) and **ADR-056 (WPI-R5: consumers need Swift 6.2+)**.
  3. The unanswered "any non-blocking bugs?" survey.
  4. **Whether to run Stage 3 (hardening) now, and its stop.**
- **Stage 3 forecast** (strict; Level 5's measured costs): ~30–55 weekly points and ~25–45 h.
  - Scope: coverage closure; adversarial hunters; ≥ 12 mutation probes (`docs/MUTATION-PROBES.md`); `--perf`; and the backlogs of ADR-052…056, among them `installIfDue()`, the WP-C TSan flake, the liveness waits, the claim retry policy, the invariant false positive, and P-13 once ruled.
  - About 34 points are left this week, less the owner's other use, so Stage 3 likely spans into the week of 29 Oct.
  - Stage 5 then needs ~3–6 points and ~3–6 h.

## WP-I (documentation and README) — done (launched 2026-10-24 12:11 CEST; merged, tagged `wpi-merged`)
- **Owner:** "Run WP-I: documentation and README" (24 Oct).
  - The owner gave no stop, so the orchestrator applied a default of 70 %. **Owner, 24 Oct 12:16: "set usage threshold at 75". WP-I's stop is now 75 %.**
  - The running script still has 70 built in. If its gate halts the run at 70 %, resume it with `Workflow({scriptPath: ".claude/workflows/assetkit-wp-i-docs.js", resumeFromRunId: "wf_3045417c-704", args: {base: "l5-merged", worktree: "i", usageStop: 75, maxRounds: 6}})`. Completed agents replay from cache.
  - The merge-docs step (ADR-056) uses 75 as well.
  - Weekly usage at launch: 60 % (Fable 32 %).
- **Scope** (ARCHITECTURE §1.2, row "end | I docs"; SPEC §8):
  - `README.md` with a quick start of at most 20 code lines, compiled against the public API in a scratch package;
  - status notes on historical WP-I-owned docs;
  - decisions in `docs/adr-drafts/i.md`.
  - Excluded: ARCHITECTURE, DECISIONS, TRACEABILITY, ORCHESTRATION, MIGRATION (WP-K's), other drafts, and the Stage 3/5 reports.
- **Run:** `wf_3045417c-704` (task `w2j6uh9aw`). It uses a dedicated script, **`.claude/workflows/assetkit-wp-i-docs.js`**: an author, an accuracy verifier and a usability verifier, and fix rounds (at most 6), with no builds or simulator runs beyond the quick-start compile. Arguments: `{base: "l5-merged", worktree: "i", usageStop: 70, maxRounds: 6}`. Worktree `.worktrees/i` on `wp/i`.
- **Result:** `wf_3045417c-704` ended 13:4x.
  - Round 1: 3 blocking out of 19 (README facts). The fix round fixed all 19. **Round 2: 0 blocking out of 11.**
  - The quick start is 19 code lines, compiled verbatim, with an iOS 15 cross-build.
  - The orchestrator applied the 11 last notes after checking each fact (`f234cda`).
  - Rulings WPI-R1…R8 are in `.build-orchestrator/wpi-rulings.md`.
- **Merged:** `wp/i` as `70b339b`. The orchestrator's WPI-R7 pointer in MIGRATION.md step 3 is `52936d6`.
  - Gates are running (logs `.build-orch/wpi/summary.txt`).
  - **Docs: RUNNING** `wf_915bed8f-166` (task `wf9yrmid0`), worktree `.worktrees/widocs` from `52936d6`, ADR-056, `usageStop: 75`. WPI-R5 (the consumer toolchain, Swift 6.2+) is tagged NEEDS-HUMAN-REVIEW.
- **Then:**
  1. Merge `--no-ff`.
  2. Run `--quick` and `--gates-only`.
  3. Fold `i.md` into DECISIONS as ADR-056, by `assetkit-level-docs.js` or, if small, by the orchestrator, with the reasons recorded.
  4. Tag `wpi-merged`, which completes Stage 2.
  5. Remove the worktree and branch, and update this file.

## Level 5 — DONE (`l5-merged` = `45e25a1`, 24 Oct 08:30 CEST). Next session: start here
- **State.** WP-G (`l5g-merged` = `da8d444`, ADR-054) and WP-K (merged `23807ac`, docs `45e25a1`, ADR-055) are on `feature/asset-kit`.
  - Nothing is running. There are no worktrees and no `wp/*` branches, and the tree is clean.
  - Weekly usage was about 59–60 % at the tag, with the owner's own Fable use counting toward it (the Fable meter was 32 %). The week resets **Thu 29 Oct 04:00 CEST**.
  - `caffeinate` holds the Mac awake until 25 Oct 11:42. Both instances are background tasks of session `d8335845-…`.
- **Gates at `l5-merged`** (logs `.build-orch/l5k/summary.txt`):
  - `--quick` gave `VERIFY: PASS` (Transport 151, Sync 351, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104).
  - `--gates-only` gave `VERIFY: PASS` (trace PASS, 1,181 tests with ids; unsafe 0; docs 1281/1281).
  - At the WP-K merge head `23807ac`/`a9e464d`: coverage PASS (Kit 97.83 %, Sync 93.42 %, Storage 97.36 %, overall 96.51 %); release and iOS builds green; simulator **1,305/1,305**; whole-package TSan, 0 reports.
  - `--perf`: 34/35. **P-13 fails** (8.70 ms vs 5 ms; owner ruling pending, ADR-050), so `VERIFY: FAIL (1 failed: benchmarks)`.
- **WP-K runs** (session `d8335845-…`):

  | Run | What | Cost |
  |---|---|---|
  | `wf_5feaaf72-e33` | main run: author + 3 verification rounds | $93 |
  | `wf_d5c59efd-6db` | close-out cycle 1 | $47 |
  | `wf_d80dd07d-5cd` | cycle 2 | $33 |
  | `wf_cfb1c56d-e3f` | cycle 3 | $67 |
  | `wf_da30f4d9-921` | cycle 4 | $48 |
  | `wf_02981dcc-c86` | cycle 5, **0 blocking** | $43 |
  | `wf_763379c2-80b` | docs: ADR-055, 2 rounds | $59 |

  WP-K: **~$390 plus orchestration**, 11:42 on 23 Oct → 08:30 on 24 Oct (about 21 h). Weekly 18 % → ~59 %, of which ~24 points are WP-K's and the rest the owner's other use.
  - Level 5 in total, WP-G plus WP-K: **~$665** and ~36 h.
- **Records:**
  - Rulings L5K-R1…R29 are in `.build-orchestrator/l5k-rulings.md` (local). Findings files: `l5k-remaining-k.json` and `l5k-close{1..4}-remaining-k.json`. Probes: `l5k-probes-c{1,3,4}/`.
  - ADR-055 in `docs/DECISIONS.md` adds **NEEDS-HUMAN-REVIEW K-2, K-3, K-5, K-6 and K-15** to the owner review list. WP-K's decisions are in `docs/adr-drafts/k.md`; `docs/MIGRATION.md` is the adoption guide.
- **Stage 3 backlog added by Level 5** (ADR-054 and ADR-055 Assignments):
  - L5-R16: a claim that inherits the retry policy.
  - L5-R22 (1)–(4) and the model tightening.
  - CCR-G1's run-time detection.
  - The P-9 survey.
  - L5K-R24's optional `installIfDue()` for ADR-016's lag at the pre-existing answer sites.
  - L5K-R27: the remaining liveness waits in `LegacyOnDemandRaceTests`, and a **pre-existing WP-C TSan flake to settle before Stage 5's `--full`**.
- **Next (owner decides):** WP-I docs (`docs/**`, README), then Stage 3 hardening, then Stage 5 (`--full`; VERIFICATION, DEVICE-TEST-PLAN, RESIDUAL-RISKS).
  - **Forecast**, re-estimated from Level 5's measured costs: ~$40–65 per strict cycle, ~0.062 points per dollar, plus the owner's other use.

    | Step | Points | Run time |
    |---|---|---|
    | WP-I docs | ~4–8 | ~3–6 h |
    | Stage 3 hardening | ~30–55 | ~25–45 h |
    | Stage 5 | ~3–6 | ~3–6 h |
    | **Total** | **~37–69** | **~31–57 h** |

  - About 40 points are left this week, less the owner's other use, so Stage 3 probably runs into the week of 29 Oct.
  - `--full` green at Stage 5 needs the owner's P-13 ruling.
- **Owner questions:**
  - P-13 (ADR-050): Option A, the p99 per batch, recommended; or Option B, `batch_ms_max` raised to 15 ms.
  - The NEEDS-HUMAN-REVIEW list, now including ADR-055's K-2/K-3/K-5/K-6/K-15.
  - The unanswered "any non-blocking bugs up to this point?" survey.
  - Which step runs next, and its stop.

## Level 5 WP-K — done (launched 2026-10-23 11:42 CEST; merged and tagged `l5-merged`)
- **WP-G is complete.**
  - `l5g-merged` = `da8d444` (WP-G + ADR-054).
  - The final `--quick` and `--gates-only` passed at `da8d444`; near-idle TSan had 0 reports; `--perf` was 34/35, with only WP-B's P-13 failing (owner item).
  - The worktrees `g` and `l5gdocs`, and the branches `wp/g` and `wp/l5gdocs`, are removed.
  - The WP-G section below predates the tag. Its "Still to do" steps 1–4 are done.
- **Main run:** `wf_5feaaf72-e33` (task `wr0g9rxsb`), via `assetkit-stage2-level.js` with `{level: "L5", base: "l5g-merged", wps: ["k"], bar: "strict", usageStop: 40}`.
  - The level script's authors read ADR-054, and WP-K's notes cite ADR-054's WP-K note.
  - Run dir: `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/d8335845-1285-454d-9185-a6519bd816cc/subagents/workflows/wf_5feaaf72-e33`.
- **Owner:** "continue" (23 Oct), taken as the go-ahead for WP-K.
  - Strict bar and the session model, as for WP-G.
  - The owner gave no stop, so the orchestrator applied its suggested default of **45 % for all of WP-K**: 40 for the main run and the close-out, 45 for docs. **Changed by the owner on 24 Oct to 65 %** (close-out 60, docs 65).
- **Usage at launch:** weekly all models 18 %, Fable 0 %, 5-hour 0 %. The week resets Thu 29 Oct 04:00 CEST.
- **Worktree:** `.worktrees/k` on `wp/k`, from `l5g-merged`.
- **Keep-awake:** a new `caffeinate -ims -t 172800` from 23 Oct 11:42 runs to 25 Oct 11:42. The earlier one ends 25 Oct 09:48.
- **Forecast (strict, from WP-G's measured costs):** ~9–23 h and ~8–24 weekly points, so it ends between Fri 23 Oct ~21:00 and Sat 24 Oct ~11:00, at weekly ~26–42 %.
- **Main run: done** at 16:44 (5.0 h, weekly 18 % → 25 %). Blocking went 3 → 2 → 2, out of 18, 10 and 11 issues in total.
  - The author's `--quick` gave `VERIFY: PASS`. Shims coverage was 97.59 % in the compatibility bundle, and the simulator ran 1,246/1,246.
  - Both remaining blockers trace back to **CCR-K1**: an explicit sync during legacy migration downloads prior-art files that R-STO-11 wants moved. The other is the tripwire test that races migration under TSan.
- **Rulings:** L5K-R1…R12 in `.build-orchestrator/l5k-rulings.md` (local), with findings in `l5k-remaining-k.json` (`L5K-V3-nn`).
  - **L5K-R1:** CCR-K1 as a class. While migration is pending or running, the pre-transfer read (`answeredFromStore`) adopts instead of downloading. Authorised edits in `EnginePresence`, `EngineRuns`, `EngineState` and `EngineLifecycle`, plus a new engine test file.
  - **L5K-R2:** L5-R14's enumeration applied to every compatibility test.
  - **L5K-R3…R12:** the auto-advancing clock accepted with conditions, the docs rescoped, the NEEDS-HUMAN-REVIEW shim decisions approved as defaults, ownership, no benchmarks in the close-out, and coverage.
- **Close-out: RUNNING** `wf_d5c59efd-6db` (task `wzgzwm1jw`), launched 16:52 at weekly 25 %, with `usageStop: 40`, the sections and focus as in the rulings, and the same sims.
  - Run dir: `…/subagents/workflows/wf_d5c59efd-6db`.
  - Resume cold from its `journal.jsonl` with `fromCycle` and the last verification's issues.
- **Close-out cycle 1:** `wf_d5c59efd-6db`, 16:52–19:16, weekly 25 % → 28 %.
  - Both original blockers are fixed. Requirements lens: 0 blocking. Correctness lens: 1 blocking, **L5K-C1-00**, a second shape of CCR-K1: a race between an on-demand adoption and a migration batch adopting the same file in the store, so a user-initiated job still downloads it.
  - The orchestrator stopped the run 1 min into fix 2, before any change, and ruled:
    - **L5K-R13:** one adoption per prior-art file. Authorised edits in `LegacyPhases.swift`, `MigrationState.swift` and `StoreMigration.swift`, with an interleaving enumeration and new store race tests.
    - **L5K-R14:** `adoptLegacyNow(_:urgency:)`, so bulk-lane adoptions keep §5's install-rate bound. This corrects L5K-R1's wrong limiter claim.
    - **L5K-R15:** three small test and doc items.
  - Findings: `l5k-close1-remaining-k.json`. Probes: `l5k-probes-c1/`.
- **Close-out cycle 2:** `wf_d80dd07d-5cd`, 19:22–21:22, weekly 28 % → 30 %. L5K-C1-00 is fixed. 2 distinct blocking defects remained:
  - **(A)** Coalesced `.bulk` publications whose trailing install the engine never schedules: the funnel's adoptions under L5K-R14, and migration batches after a run took the parked launch run's place.
  - **(B)** `migrateLoop` busy-spins while an on-demand adoption holds the last claimed file.
  - The orchestrator stopped the run 1 min into fix 3 and ruled:
    - **L5K-R16:** the trailing-install class. Enumerate every publishing store call, add the RE-S40 re-arm where it is missing, add an idle tripwire to `invariantViolations()`, and add a compatibility test at the production install interval.
    - **L5K-R17:** no hot loop. `performMigrateLegacy` awaits the on-demand flight, with an enumeration of the engine's store loops.
    - **L5K-R18:** re-read the lane after an adoption.
    - **L5K-R19:** small items.
  - Findings: `l5k-close2-remaining-k.json`.
- **Close-out cycle 3:** `wf_cfb1c56d-e3f`, 21:31–00:43, weekly 30 % → 34 %. Every cycle-2 blocker is fixed. 3 blocking items in two repeating classes remained:
  - a coalesced publication followed by a wait inside the same store call (L5K-R17's wait);
  - a user-initiated asker answered before the install, by a promotion during the re-arm's await;
  - plus a test premise.
  - The orchestrator stopped the run 3 min into fix 4 and ruled:
    - **L5K-R20:** a store call returns right after a coalesced publication; `migrateLegacy` follows option (b).
    - **L5K-R21:** the check of the job's interests at the answer site, after the last await, then one user-initiated publication.
    - **L5K-R22:** the test premise, liveness tests, records, and ratifications.
  - Findings: `l5k-close3-remaining-k.json`. Probes: `l5k-probes-c3/`.
- **Close-out: RUNNING from cycle 4** `wf_da30f4d9-921` (task `wle5pdlf9`), launched 00:58 at weekly 34 %, with `fromCycle: 4`, `findingsFile` `l5k-close3-remaining-k.json` and `usageStop: 40`. **Owner, 24 Oct 01:25: "move usage target to 65%".** The WP-K stop is now 65 % (close-out 60, docs 65). The run above still has 40 built in.
  - At the next clean boundary (cycle 4's verification, or the old gate halting the run), relaunch `assetkit-closeout.js` with `usageStop: 60`, `fromCycle` set to the next cycle, and `findingsFile` set to the last verification's issues (`verifyFirst: true` if fix 4 finished but was not verified).
  - Docs then run with `usageStop: 65`.
- **Close-out cycle 4:** `wf_da30f4d9-921`, 00:58–03:2x, weekly 34 % → 44 %. The verifiers cost about 7 points, and the owner's own Fable use (the Fable meter went 0 → 12 %) also moved the meter.
  - The run stopped at the old 40 % gate before fix 5.
  - It left 4 blocking items, 3 of them with fixes the verifiers validated in scratch: a stale `last` across an await in `migrateLegacy`, the per-read re-arm lost in a multi-id job, and a late joiner never read.
  - The fourth was L5K-R21 applied to pre-existing answer sites: ADR-016's lag of at most about two install intervals.
  - Rulings:
    - **L5K-R23:** the three validated fixes.
    - **L5K-R24:** L5K-R21 is scoped to the funnel; the other sites keep ADR-016's lag, recorded for the owner, with Stage 3 holding an optional `installIfDue()`.
    - **L5K-R25:** small fixes, including `drive`'s guard against a request for a retired job (`EngineDispatch.swift`, guard only).
    - **L5K-R26:** a verification budget.
  - Findings: `l5k-close4-remaining-k.json`. Probes: `l5k-probes-c4/`.
- **Close-out: RUNNING from cycle 5** `wf_02981dcc-c86` (task `w60vy571x`), launched 03:37 at weekly 44 %, with **`usageStop: 60`** (owner's 65 % for WP-K), `fromCycle: 5` and `findingsFile` `l5k-close4-remaining-k.json`. Docs will run with `usageStop: 65`.
- **Close-out cycle 5:** `wf_02981dcc-c86`, 03:37–05:4x, weekly 44 % → 57 %, including the owner's own Fable use (the Fable meter 12 → 32 %). **0 blocking in both lenses** at `2df51ab`, so the close-out converged.
  - Over 5 cycles, blocking went 2 → 1 → 3 → 6 (4 distinct) → 0.
  - L5K-R27 sends the non-blocking items to Stage 3 or the docs level; L5K-R28 is the docs brief for ADR-055.
- **Merged:** `wp/k` into `feature/asset-kit` as `23807ac` (`--no-ff`), 24 Oct 05:5x.
  - **Phase-A gates at `23807ac` (logs `.build-orch/l5k/summary.txt`):**
    - `--quick` gave `VERIFY: PASS` (Transport 151, Sync 351, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104).
    - Coverage: `COVERAGE: PASS` (Kit 97.83 %, Sync 93.42 %, Storage 97.36 %, overall 96.51 %).
    - `--gates-only` gave `VERIFY: PASS`; TRACEABILITY is committed in `7d90719`.
    - The release build completed, and the iOS build exited 0 with no error or warning lines.
    - The simulator: `** TEST SUCCEEDED **`, 1,305/1,305.
  - **Deferred:** TSan and `--perf`. The load at 05:54 was about 50; run them near-idle, after the docs.
  - **Docs: RUNNING** `wf_763379c2-80b` (task `wzw2li006`), worktree `.worktrees/l5kdocs` on `wp/l5kdocs` from `7d90719`, ADR-055, `usageStop: 65`.
  - Next: commit TRACEABILITY.md; near-idle TSan and `--perf`; the docs worktree `l5kdocs` with `assetkit-level-docs.js` (ADR-055, `usageStop: 65`); confirm the acknowledged items; merge the docs; re-run `--quick` and `--gates-only`; tag **`l5-merged`**; remove the worktrees and `wp/*` branches.
- **Next, as for WP-G** (step 1 is done):
  1. Write `.build-orchestrator/l5k-rulings.md` and dump `l5k-remaining-k.json`.
  2. Run `assetkit-closeout.js` with `{wp: "k", name: "WP-K (compatibility shims)", base: "l5g-merged", target: "(test target only)", testTarget: "ZTronAssetCompatibilityTests", coverageMin: 70, bar: "strict", maxCycle: 30, usageStop: 40}`, using the same sims as WP-G.
  3. When a class repeats, stop right after the verification and relaunch with `fromCycle`.
  4. Merge, gates (`.build-orch/l5/l5-gates-a.sh` with its log dir moved to `.build-orch/l5k`), docs (`l5kdocs`, ADR-055, `usageStop: 45`), then tag `l5-merged`.

## Level 5 WP-G — MERGED; docs running (updated 2026-10-22 23:10 CEST)
- **Session:** `d8335845-1285-454d-9185-a6519bd816cc`, launched by the scheduled task `ztron-assetkit-level5-launch`. It fired at 09:48 rather than 04:20.
- **Runs:**

  | Run | What | Time | Weekly |
  |---|---|---|---|
  | `wf_6593085d-170` | main run: author + 3 verification rounds; blocking 2 → 3 → 4 | 09:49–14:30 | 0 → 5 % |
  | `wf_a049b89c-afb` | close-out cycle 1; blocking 4 left (3 distinct) | 14:39–17:34 | 5 → 8 % |
  | `wf_0ec4322f-bdb` | cycle 2; reqs 0, correct 1 blocking | 17:45–20:55 | 8 → 12 % |
  | `wf_b17021d0-91c` | cycle 3; **0 blocking in both lenses** | 21:07–22:47 | 13 → 15 % |
  | `wf_bdef0756-da0` | docs: ADR-054, worktree `.worktrees/l5gdocs` on `wp/l5gdocs` from `6d1e0cc`, usageStop 55 | started 23:05 | 15 % → … |

- **Rulings:** L5-R1…R23 in `.build-orchestrator/l5-rulings.md`, which is local and gitignored. The class rulings were:
  - L5-R1: engine pending claims, for R-CAR-3.
  - L5-R2: shutdown from `created`.
  - L5-R13/R19: event continuity, with the model test and the `.clientEnd` slot.
  - L5-R14: scheduling-dependent tests.
  - L5-R20: `verifyRootNow()`.

  L5-R22 sends the five remaining non-blocking items to the docs level or Stage 3, and L5-R23 is the docs brief.
- **Findings files:** `l5-remaining-g.json`, `l5-close1-remaining-g.json`, `l5-close2-remaining-g.json`. Probes are in `l5-probes-r3/`, `l5-probes-c1/` and `l5-probes-c2/`.
- **Merge:** `wp/g` merged `--no-ff` into `feature/asset-kit` as `3de588e`; `6d1e0cc` regenerated `docs/TRACEABILITY.md`.
- **Post-merge phase A (orchestrator, `.build-orch`, logs in `.build-orch/l5/summary.txt`):**
  - `--quick` gave `VERIFY: PASS` (Transport 151, Sync 323, Storage 445, Model 84, Kit 85, Compat 3, AppleHosted 104).
  - Coverage: `COVERAGE: PASS`, with Kit 97.83 %, Sync 93.54 % and Storage 97.41 %.
  - `--gates-only` gave `VERIFY: PASS`. TRACE now passes: P-1, P-8 and P-12 have benchmarks.
  - The release build completed, and the iOS generic build exited 0 with no error or warning lines.
  - On simulator 897F9D8D, `** TEST SUCCEEDED **`, 1,195 of 1,195.
- **Still to do, in order:**
  1. **TSan (whole package, `--scratch-path .build-orch-tsan`) and `verify.sh --perf` on a near-idle machine.** They were deferred because at 23:03 the load was ~40 from three simulators that are not ours plus Xcode. Run them after the docs workflow, when `sysctl vm.loadavg` is low. P-5, P-11, P-13 and R-SYN-5 C2 must be judged at near-idle (L5-R6/R18).
  2. When docs end: confirm or rule on every "Acknowledged at merge" item, and apply the verifier's last notes. Also fix the `FacadeReopenTests.swift:534` comment myself (L5-R22 (5)).
  3. Merge `wp/l5gdocs`, re-run `--quick` and `--gates-only`, then tag `l5g-merged`.
  4. Remove `.worktrees/g` and `.worktrees/l5gdocs`, and the branches `wp/g` and `wp/l5gdocs`.
  5. Rewrite this file for WP-K, and ask the owner whether to run it now. Give its forecast, and ask for a WP-K stop, because 55 % covered WP-G only.
- **Keep-awake:** `caffeinate -ims -t 259200` runs until 25 Oct 09:48.
- **Forecast (23:10).**
  - WP-G's remaining docs, TSan, perf and final gates take ~2–3 h and ~2–3 points, so `l5g-merged` lands around Fri 23 Oct 01:00–02:00 at weekly ~17–18 %.
  - All of WP-G then cost ~17–18 points and ~16 h, against the 17 Oct forecast of 19–38 points and 22–43 h.
  - **WP-K**, from the owner's go-ahead, at the measured L5 cycle cost of ~3 points and ~3 h per strict cycle: a main run of 3–4.5 h and 3–5 points, then 2–6 cycles, then merge and docs. Total **~12–26 h and ~12–25 points**, so Level 5 would end at weekly ~30–43 %.

## Next session: start here (written 2026-10-17 19:15 CEST, after Level 4)
Level 4 is **complete** (`l4-merged` = `0d3f119`, see "Level 4 — done"). Nothing is running; no worktrees; no `wp/*` branches; `feature/asset-kit` is clean. Weekly usage **68 %** (all models; Fable 0 %), resets **Thu 22 Oct 04:00 CEST**. A `caffeinate -ims -t 172800` started 17 Oct 11:30 ends by itself on 19 Oct 11:30.

**Owner decision (2026-10-18): wait for the weekly reset on Thu 22 Oct, then start Level 5 (WP-G) with the strict bar.** No stop was given, so the orchestrator recorded a **default of 55 % for all of WP-G**: usageStop 50 for the main run and close-out, 55 for docs. This was the owner's first L4 stop; the owner may change it.
- **Scheduled:** one-time task `ztron-assetkit-level5-launch` (Claude app → Scheduled; file `~/.claude/scheduled-tasks/ztron-assetkit-level5-launch/SKILL.md`) fires **Thu 22 Oct 04:20 CEST** in Auto mode.
  - It starts a fresh session that reads this file and checks `get_usage`; it launches nothing if weekly usage is above 10 %.
  - It then starts caffeinate, creates `.worktrees/g`, runs the level script for `wps: ["g"]` (strict, usageStop 50), and continues through the close-out, merge, gates and docs to `l5g-merged`.
  - After that it asks the owner about WP-K. At any stop it re-forecasts and asks only for a new stop.
  - The app must be open; if it is closed at 04:20, the task runs on next launch.
- **Keep-awake:** `caffeinate -ims -t 367211` from 18 Oct 01:00 holds the Mac awake until Thu 22 Oct 07:00 (session `4920f51b-…`, background task).
- Still-open owner items (below): P-13, the NEEDS-HUMAN-REVIEW list, and the unanswered "any non-blocking bugs up to this point?". A read-only survey for the last one was proposed as a session card ("Survey non-blocking bugs across Levels 1–4").

## Level 5 (WP-G facade, then WP-K shims) — prepared
- **Script ready:** `.claude/workflows/assetkit-stage2-level.js` now has authors read ADR-049, 050, 052 and 053, and WP-G's notes carry ADR-053's assignments:
  - L4-R23: the facade `ensureAvailable` keeps a throttled-out member as missing, and a fresh refused call throws `.serverUnavailable(retryAfter:)`.
  - L4-R9: `diagnosticReport()` may rely on the engine's degraded diagnostics.
  - L4-R11: Kit coverage ≥ 70 %, and P-1/P-8/P-9/P-12.
  - The §12 names now in §11 R-CAR-3, R-NET-3 and P-8.
- **WP-K runs after WP-G is merged** (ARCHITECTURE §1.2: "L5, after G"; its tests use a real `AssetClient`).
- **Launch WP-G:**
  1. `git worktree add .worktrees/g -b wp/g l4-merged`.
  2. Start `caffeinate -ims -t 172800` in the background.
  3. `Workflow({scriptPath: ".claude/workflows/assetkit-stage2-level.js", args: {level: "L5", base: "l4-merged", wps: ["g"], bar: "<owner>", usageStop: <owner>}})`.
- **Close-out:**
  1. Write `.build-orchestrator/l5-rulings.md` (answer every orchestrator question in the author's `open`/`contract` items first, as L4-R1…R15 did).
  2. Dump the last round's issues to `.build-orchestrator/l5-remaining-g.json`.
  3. Run `Workflow({scriptPath: ".claude/workflows/assetkit-closeout.js", args: {wp: "g", name: "WP-G (facade)", base: "l4-merged", target: "ZTronAssetKit", testTarget: "ZTronAssetKitTests", sections: "sections 1.1, 1.2, 2, 5, 8, 13.5, 14", coverageMin: 70, rulingsFile: "<abs>/.build-orchestrator/l5-rulings.md", findingsFile: "<abs>/.build-orchestrator/l5-remaining-g.json", focus: "…", bar: "<owner>", sims: {fix: "897F9D8D-B10D-4D91-8E22-417A2B9D70AA", reqs: "6BE15CAF-7E02-4060-9338-9DAC025EDF0B", correct: "5B940E6E-490F-4E9E-A917-A6456A18225E"}, maxCycle: 30, usageStop: <owner's stop minus ~5 for merge and docs>}})`.
  4. When a defect class repeats over two or more cycles, add a ruling that orders its exhaustive enumeration and a single design fix (L4-R17, L4-R20 converged L4).
- **Merge and docs:** do these as in Level 4 (see "Run a level" below). Tag `l5g-merged`, then run WP-K the same way from it (`wps: ["k"]`, target "(test target only)", testTarget `ZTronAssetCompatibilityTests`, coverageMin 70). Tag `l5-merged`.

## Level 4 — done (WP-F sync engine; 15–17 Oct)
- **Owner decisions:** strict bar; stops 55 % → 65 % → 70 %; all Opus 5.5.
- **Runs** (session `4920f51b-9e95-4e57-8e1e-df565b6e74bf`):

  | Run | What | Cost |
  |---|---|---|
  | `wf_3286fe9b-a79` | main run: author + 3 verification rounds, blocking 13 → 11 → 8 | $144 |
  | `wf_0989cd6c-62c` | close-out cycles 1–10 | $251 |
  | `wf_d8affeb1-4b4` | cycles 11–19 | $247 |
  | `wf_7e52a3a2-ebc` | cycles 20–22, blocking 1, 1, **0** | $74 |
  | `wf_922413b4-a66` | docs: 2 rounds, 0 blocking | $37 |

  Total **$753**, ~52 h of runs. Weekly 2 % → 68 %, about 13–15 points of which were the account's other use.
- **Blocking per close-out cycle:** 1, 3, 1, 3, 1, 1, 1, 5, 3, 2 | 1, 1, 1, 4, 3, 1, 3, 2, 3 | 1, 1, 0. Two class rulings ended the tail:
  - L4-R17: every scheduling-dependent test converted to an explicit wait.
  - L4-R20: the stale-gate race family, with one pure origin-gate evaluation at `now` and a seeded gate model with invariants I1–I6.
- **Records:**
  - Rulings L4-R1…R26 in `.build-orchestrator/l4-rulings.md`.
  - **ADR-053** in `docs/DECISIONS.md`, with ARCHITECTURE amended (§1, §7, §10.2 rows f-1…f-14, §11, §12, §14).
  - WP-F's decisions F-1…F-42 in `docs/adr-drafts/f.md`.
  - Findings files `l4-remaining-f.json`, `l4-close10-remaining-f.json`, `l4-close19-remaining-f.json`.
- **Authorised edits outside WP-F:**
  - `Package.swift`: a test-only AppleHosted dependency for `ZTronAssetSyncTests` (L4-R1).
  - `StoreIntegrity.swift`: the `recordFailure` presence guard, plus WP-C's retargeted R-CLN-4 case (L4-R16).
- **Stage 3 backlog added by Level 4** (ADR-053 Assignments):
  - L4-R22: the probe-chain total, which is quadratic (10,000 parked: ~161 s).
  - L4-R24: the half-started run seen by test seams; `ManualTimeSource.advance(to:)` landing 1 ns short; `recordIntegrityFailure` having no guard; relane order; the late joiner's second download (with OI-15); `gainReferenceInPlace`'s table copy.
  - The §12 names not yet written (S1-01, S1-07, S1-11, S1-12, S1-15 run form, S2-09, S2-10, S2-19, the remaining halves of S1-09, S2-01, T2-06).
  - F-27(c): a backoff for `awaitingSpace`, if device tests show churn.

## Owner decisions in force
- **Standalone package.** Nothing outside this repository is ever written, except the device containers of the iOS simulators agents test on (owner-accepted 2026-10-09, ADR-051). `../ZTronCarouselCore` and `../ZTronCarousel` are read-only prior art. PROMPT.md Stage 4 is cancelled; R-CAR-6 shims live in `Tests/ZTronAssetCompatibilityTests` (ADR-006, ADR-033).
- **iOS 15.0 minimum** (macOS 12 test floor). Never raise it.
- **Every test target builds and passes on the iOS Simulator** as well as on macOS (owner, 2026-10-09; ADR-051, convention in `docs/adr-drafts/ios.md` item 2). Agents use their own simulators, never the owner's booted iPhone 17.
- **Work proceeds level by level; the owner decides each level's scope and when to run it.** The owner sets a weekly-usage stop per run. At the stop: re-estimate, rewrite this file, and ask only for the new threshold. Apply a stop across the whole level: give the close-out a gate about 5 points lower, so the merge and docs fit.
- The harness is frozen (`git tag harness-frozen`; `Scripts/` never changes; `quality-gates.json` sha256 `2725907c…026f`).

## Where things stand (2026-10-17 19:15 CEST; weekly usage 68 %)
| Item | State |
|---|---|
| Branch | `feature/asset-kit` (never `main`, never push); clean |
| Tags | `harness-frozen`, `contracts`, `l1-merged`, `l2-merged`, `l3-base`, `l3-merged`, **`l4-merged`** (`0d3f119`: WP-F + ADR-053) |
| Worktrees | none; no `wp/*` branches |
| Gates at the WP-F merge (`331653b`) and at `l4-merged` | `--quick` PASS (both heads); release + iOS builds green; **1,100/1,100 tests on an iOS 27 simulator**; whole-package TSan PASS, 0 reports (all 7 targets); unsafe 0; docs 1281/1281; coverage Storage 97.38 %, Sync 93.33 %, Transport 99.08 %, AppleHosted 99.76 %, Model 99.31 %, overall 95.16 % (Kit 37.82 % is WP-G's stub); trace: **every MUST has a test** (78/78); budgets without a benchmark: P-1, P-8, P-12 (WP-G) |
| Benchmarks (load ~3) | P-2 p95 8.98 ms (25), P-3 18.0 ms (80), P-4 11.4 ms (20; ratio 2.02 ≤ 2.5), P-5 ordered p95 14.1 / durable p95 28.9 ms (40), P-6 2,405 MB/s at 0.83× (≥ 800, 0.7×), P-7 1.36 / 0.19 MiB (48), P-10 8 connections (8), P-11 speedup 3.70 (≥ 3), P-14 0 timers / 0 tasks; WP-F's ten C2 benchmarks ≤ 6.1 ms (10); **P-13 fails** (unit max 9.27 ms vs 5 ms; owner ruling pending, ADR-050) |
| Logs | `.build-orch/l4/` (summary.txt, quick, gates, coverage, sim, tsan, perf) |
| Owner stash | `git stash` "owner iOS 26 availability edits…" (identical to commit `b9f2752`); the owner may drop it |

## Run a level (the Level 4 procedure)
1. **Pre-flight:**
   - `git status` clean; check `get_usage` right before launch (the owner's other use moves the meter).
   - Start `caffeinate -ims -t 172800` in the background.
   - Add the worktree from the base tag.
2. **Main run:** the level script runs the author, two verifiers on their own scratch paths and simulators, and up to two fix rounds. A haiku usage probe gates every agent.
3. **Close-out:**
   - Write the rulings file: answer every question the agents put to the orchestrator.
   - Dump the findings to JSON.
   - Run `assetkit-closeout.js`. To resume from a fresh session, read the run's `journal.jsonl` and relaunch with `fromCycle` = next and `findingsFile` = the last verification's issues.
   - Delete the reviewers' `.build-verify-*` scratch dirs as they pile up: L4 left 164 GB.
4. **Merge and gates:**
   - Merge `--no-ff`.
   - Run the phase-A gates; the script is `l4-gates-a.sh` (recreate it from `.build-orch/l4/summary.txt`'s steps): `--quick`; `--gates-only` (commit `docs/TRACEABILITY.md`); release and iOS builds; the coverage export; a simulator run with `-derivedDataPath .build-orch/xcode-sim -collect-test-diagnostics never`.
   - Then, on a near-idle machine: whole-package TSan (`--scratch-path .build-orch-tsan`) and `verify.sh --perf`.
5. **Docs:**
   - Add a worktree `.worktrees/<lN>docs` at the merge head.
   - Run `assetkit-level-docs.js` (`level`, `worktree`, `base`, `drafts`, `rulings`, `adrs`, `amendTargets`, `usageStop`).
   - Confirm or rule on every "Acknowledged at merge" item the writer raises, and apply the verifier's last notes yourself.
   - Merge, then run `--quick` and `--gates-only` again, tag, remove the worktrees and branches, and rewrite this file.

## Forecast for the remaining work (re-estimated 2026-10-17 from Level 4)
**Calibration:**
- ~0.065 weekly points per API-equivalent dollar as measured from transcripts (L4 cycles 11–22, no other use; the main run measured 0.076). Those transcripts undercount by ~23 %: about 0.053 per real dollar (see "Cost — measured", correction of 31 Oct).
- A strict close-out cycle costs ~$27 (~1.75 points) and ~2.1 h.
- Level 4 cost 1.3–2.1× its forecast in dollars and took 22 cycles against the forecast 7–10.

| Step | Scope | Strict: points / run time | Converge: points / run time |
|---|---|---|---|
| L5 WP-G facade | 19 §11 rows, P-1/P-8/P-9/P-12, main-thread rules, ADR-050/053 assignments; strict 6–15 cycles | 19–38 / 22–43 h | 12–19 / 12–20 h |
| L5 WP-K shims (after G) | R-CAR-6 shims, test target only; strict 3–8 cycles | 8–17 / 10–24 h | 6–10 / 7–12 h |
| WP-I docs | `docs/**`, README | 3–6 / 3–5 h | 3–6 / 3–5 h |
| Stage 3 hardening | coverage closure, adversarial hunters (Fable optional, ~1.7× Opus), ≥ 12 mutation probes, the ADR-052 and ADR-053 backlogs, P-13 once ruled | 25–45 / 18–35 h | 18–30 / 12–22 h |
| Stage 5 final | `verify.sh --full`, VERIFICATION / DEVICE-TEST-PLAN / RESIDUAL-RISKS | 3–6 / 3–6 h | 3–6 / 3–6 h |
| **Total** | | **58–112 points / 56–113 h** | **42–71 points / 37–65 h** |

**When it ends:**
- This week has ~32 points left (to 100 %); the week from 22 Oct has ~100.
- Under strict, WP-G alone (19–38) roughly fills this week's remainder, so the rest runs in the week of 22 Oct. The project completes around 24–28 Oct if runs are continuous.
- Under converge it could end around 23–25 Oct.
- `--full` green at Stage 5 still needs P-13's ruling.

## Cost — measured, Opus 5.5 API-equivalent
Summed from the agents' transcripts with `.claude/tools/cost.py <run dirs>`, at $4 / $20 / $0.20 (cache read) / $5 (cache write) per MTok.

| Step | Cost | Weekly points |
|---|---|---|
| Stage 1 | ~$180 | — |
| Level 1 (H, A) | ~$190 | — |
| Level 2 (B, D, E) | ~$419 | 31 |
| Level 3 (iOS Simulator tests + C) | ~$397 + orchestration | 28 (40 % → 68 %) |
| Level 4 (F, strict, 22 cycles) | ~$753 + orchestration | ~51 of 66 (2 % → 68 %; the rest was the account's other use) |

A full week holds roughly $1,400–1,500 of this workload.

**Correction, measured 31 Oct 18:45 CET: the figures above are about 23 % low.**
- **Cause:**
  - Claude Code 2.1.286–2.1.299 (sessions of 4–25 Oct) saved each message's usage before the final output count arrived, on about two thirds of messages. So transcript sums, `cost.py` included, miss output tokens for those sessions.
  - `cost.py` also prices every cache write at the 5-minute rate; 1-hour writes cost $8/MTok, not $5.
- **Method now:**
  - For sessions recorded by those versions, use Claude Code's own `cost-state` record (`totalCostUSD`). It reads each response's final usage; its cache counts match the transcripts exactly, and its prices are the list prices.
  - Transcripts from 2.1.308 on are accurate: tracker against transcript was 0.996 for this session.
  - A blind independent recount (`wf_34cda007-ffd`) matched the transcript arithmetic to $1.

| Step | Corrected cost |
|---|---|
| Stage 0–1 | $241 |
| Level 1 | $255 |
| Level 2 | $526 |
| Level 3 | $520 |
| Level 4 | $958 |
| Level 5 | $892 |
| WP-I and gaps | $122 |
| Stage 3 to 31 Oct 18:45 | $1,274 |
| **Total** | **$4,787** |

- **Split:** workflow agents $4,460, orchestrator $327; Opus 5.5 is 99.6 %.
- **Weekly points:** about 0.050–0.053 per real dollar; the 0.065 above was per undercounted dollar. A full week holds about $1,900–2,000 of this workload.
- **A WP-F close-out cycle** costs $50–60, about 3 points.
- **Forecast to the end, as of 31 Oct:** about $350 more (range $190–570), so the whole project comes to about $5,150 ($5,000–5,350).

## Trim candidates (owner decides per level)
- Background URLSession (R-NET-3)
- R-INT-4 deep verification
- R-CLN-11 cache purging
- Crash enumeration beyond single-lifetime scenarios
- Benchmarks P-7 and P-9
- Mutation probes (Q-8)
- One verifier instead of two
- The simulator run in every verifier (keep it in the author and one verifier)
- The "converge" close-out bar

Cutting a MUST or a budget means marking it deferred in `SPEC.md` with a `DECISIONS.md` entry; never edit `Scripts/`.

## Open questions for the owner
1. ~~Level 5 launch~~ — answered 2026-10-18: after the 22 Oct reset, strict bar. Stop defaulted to 55 % (owner may change); scheduled task `ztron-assetkit-level5-launch`.
2. **P-13** (ADR-050 · NEEDS-HUMAN-REVIEW): Option A (recommended) p99 per batch; Option B raise `batch_ms_max` to 15 ms. It still fails at `l4-merged` (9.27 ms vs 5 ms).
3. **NEEDS-HUMAN-REVIEW items:**
   - ADR-050: B-3 index layout; D-10 `shutdown()` cancels background downloads; public `startDownload(…resumeData:)`; D-19.2 task-tag format.
   - ADR-052: WP-C's R-STO-11 deviations: C-12 (checksum-less legacy files without a local checksum are re-downloaded), C-13 (an undecodable legacy manifest adopts nothing), C-14 (a legacy root on another volume is dropped; a legacy file failing three times in one lifetime is abandoned), C-15 (phase 4 keeps unattributable files and a non-empty root).
   - Level 4 added none.
4. **Unanswered: "any non-blocking bugs up to this point?"** Planned answer, not started: a read-only workflow over the drafts `docs/adr-drafts/{a,h,b,d,e,l2fu,ios,c,f}.md`, the Open / Deferred / Stage 3 bullets of ADR-049…053, and the findings files in `.build-orchestrator/`. Report them grouped as proven bugs still open · unproven suspicions · accepted deviations · performance limits · test/environment items. It now also includes ADR-053's Stage 3 list.
5. Whether CLAUDE.md should mention the simulator run (ADR-051 "Open"; agents may not edit CLAUDE.md).
6. Outside-repository leftovers (owner may delete; agents may not): `CFNetworkDownload_*.tmp`, `ResultBundle_*.xcresult` and macro-expansion dumps in the per-user temp folder; `~/Library/Developer/Xcode/DerivedData/{l2fu-*,ZTronAssetKit-*}`.

## Lessons from Levels 0–4
- Always pass `-derivedDataPath` to `xcodebuild`; never `xcodebuild -list`; never an unscoped `pkill`; keep the Mac awake (`caffeinate`; simulator runs use `caffeinate -i`).
- One scratch path and one simulator per agent; never the session scratchpad. `verify.sh` writes `.verify-logs/` inside the worktree, so two verifiers running `--quick` in one worktree overwrite each other's logs (take verdicts from exit status).
- **When a bug class repeats, order an exhaustive enumeration and one design fix.** Examples: B-33, WP-C's legacy phase-1 state space, L4-R17 (scheduling-dependent tests), and L4-R20 (stale gates: three cycles to converge after 19 cycles of case-by-case fixes).
- The strict bar finds real bugs late: cycles 7–9 of L4 found pre-existing C2 stalls and liveness bugs. It also costs: L4 took 22 cycles. Budget the bar explicitly, and log blocking counts per cycle to spot a non-converging family early.
- Benchmarks and TSan only on a near-idle machine. The owner's Xcode can load the host as much as two agents.
- Failing test committed on its own before the fix; TestSupport waits must end on cancellation (`require…` forms).
- Usage stop: a haiku probe before each agent; in-flight agents finish (≤ 1 point overshoot). A transient DNS outage kills agents; resume the workflow with `resumeFromRunId` (same session), and only the failed agents re-run.
- Verifiers' scratch builds grow ~2–4 GB each per cycle; delete `.build-verify-*` between runs.
- Answer agents' questions to the orchestrator promptly in the rulings file; an unanswered one (the cycle-1 `recordFailure` guard question) is carried as residue for many cycles.

## Tools and model notes
- **Tools:** `.claude/tools/cost.py <run dirs>` (API-equivalent cost) and `.claude/tools/timesplit.py <run dirs>` (model vs tool time per agent role).
  - Run dirs are `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/<session>/subagents/workflows/<run id>`.
  - Sessions: `7fbcfa21-90df-4f76-8c7c-0ced89fa87b5` (Levels 1–3) and `4920f51b-9e95-4e57-8e1e-df565b6e74bf` (Level 4).
  - Usage: `mcp__ccd_session_mgmt__get_usage`.
- **Models:**
  - L4 close-out agents spent ~45–55 % of their wall time in tools, and ~45–55 % in the model.
  - Prices per MTok (input / output / cache read): Opus 5.5 $4 / $20 / $0.20; Sonnet 5.5 $2 / $10 / $0.20; Fable 5.1 $10 / $50 / $0.25, which counts toward the all-models limit (observed 13 Oct).
  - The level and close-out scripts take `models: {author, fix, verify}` (`'opus' | 'fable' | 'sonnet'`).
