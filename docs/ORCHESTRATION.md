# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Stage 3 (hardening) — RUNNING: fix close-outs (launched 2026-10-29, session `eaf5a17f-…`). Next session: start here
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
  - If cycle 18 still blocks, rule and start run 6 from cycle 19 (no cap).
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
- ~0.065 weekly points per API-equivalent dollar (L4 cycles 11–22, no other use; the main run measured 0.076).
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
