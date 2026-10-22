# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Level 5 WP-G — RUNNING (launched 2026-10-22 09:49 CEST)
- **Launched by** the scheduled task `ztron-assetkit-level5-launch`, which fired at ~09:48 CEST instead of 04:20; the app was probably closed at 04:20.
- **Session:** `d8335845-1285-454d-9185-a6519bd816cc`. **Main run:** `wf_6593085d-170` (task `w9gtxnvf1`), via `assetkit-stage2-level.js` with `{level: "L5", base: "l4-merged", wps: ["g"], bar: "strict", usageStop: 50}`.
  - Run dir: `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/d8335845-1285-454d-9185-a6519bd816cc/subagents/workflows/wf_6593085d-170`.
- **Usage at launch:** weekly all models **0 %**, Fable 0 %, 5-hour 0 %. The week resets Thu 29 Oct 04:00 CEST.
- **Worktree:** `.worktrees/g` on `wp/g`, from `l4-merged` (`0d3f119`).
- **Keep-awake:** `caffeinate -ims -t 259200` from 22 Oct 09:48 runs to 25 Oct 09:48 (a background task of this session).
- **Stops:** 50 for the main run and close-out, 55 for docs: the 55 % WP-G default recorded on 18 Oct.
- **Forecast (strict; re-estimated 22 Oct 15:35, during close-out cycle 1).**
  - Measured in the main run: a fix round takes 42–66 min and a verification round 32–39 min; a cycle costs ~1.75 weekly points, the same as L4.
  - Close-out cycles with engine edits run longer (Sync ×3 + TSan): about 1.6–2.1 h each, and cycle 1 is 2–3 h.
  - Likely 6–12 cycles: 11–24 h and 10–23 points. Best case 4 cycles: ~8 h. Tail case 18 cycles: ~36 h.
  - Merge, gates and docs then add 4–6 h and ~3 points.
  - **WP-G ends:** likely Fri 23 Oct between ~07:00 and ~22:00, at weekly ~19–33 %. Best case Fri ~03:30 at ~14 %; tail case Sat 24 Oct ~09:30 at ~43 %.
  - The 50 % close-out stop triggers only past ~24 cycles.
- **Whole of Level 5 (WP-G, then WP-K), re-estimated 22 Oct 15:40.**
  - WP-K costs 10–24 h and ~8–17 points: a main run of 3–4.5 h, then 3–8 lighter cycles of 1.3–1.8 h each (no engine suites), then merge, gates and docs. Count from the moment the owner says go after `l5g-merged`.
  - **Level 5 ends:** likely between Fri 23 Oct ~17:00 and Sat 24 Oct ~22:00, at weekly ~30–47 %. Best case Fri ~13:30 at ~22 %; tail case Sun 25 Oct ~09:30 at ~60 %.
  - Every case fits before the 29 Oct reset. Renew caffeinate when WP-K starts (the current one ends 25 Oct 09:48).
  - WP-K needs the owner's go-ahead and its own stop.
- **Main run: done** at 14:30 (4.7 h, weekly 0 % → 5 %, no stop). Blocking went 2 → 3 → 4, out of 16, 12 and 9 issues in total. The author reported `VERIFY: PASS` (`--quick`) and Kit coverage 96.94 %.
- **The four blocking items left by round 3**, all ruled in `.build-orchestrator/l5-rulings.md` (local, gitignored):
  - **L5-R1** (CCR-G2): R-CAR-3 / S1-05 fail end to end. A release can overtake a registered group's join in the engine. Ruled as an authorised edit in WP-F's `EngineCommands`/`EngineJobs`/`EngineState`: pending claims at registration, checked by `retire(_:)`, covering both windows. Then the two `withKnownIssue` wrappers come out.
  - **L5-R2:** a shutdown from `created` leaked owned tasks (R-SYN-15). Ruled as an authorised edit in `EngineLifecycle.swift`, with a spawn-site enumeration.
  - **L5-R3:** the event forwarder lost the replacement's events (R-SYN-12). Ruled: subscribe the live forwarders before install, and forward the replacement's `clientStarted`.
- **The three cross-package requests:**
  - **L5-R4** approves CCR-G3: `AssetStore.unavailableReason` as a package read, plus the facade's reopen trigger.
  - **L5-R5** declines CCR-G1, because it would misfire on WP-D's tolerated early finish. The attestation counts as "wired", and the run-time half is Not verified.
  - **L5-R6** leaves P-13, P-11 and R-SYN-5 C2 as non-blocking `outside-wp` (load-related), to be re-run at merge.
- **Close-out cycle 1:** `wf_a049b89c-afb`, 14:39–17:34 (2.9 h, weekly 5 % → 8 %, i.e. ~3 points, heavier than the 1.75 forecast).
  - It fixed all four original blockers, and the verifiers confirmed each against mutants and probes.
  - It left 4 blocking items, 3 distinct, in `.build-orchestrator/l5-close1-remaining-g.json` (`L5-C1-nn`):
    - a `subscribe()` stream not yet pulled loses the replacement's events after a reopen (the same class as L5-V3-06);
    - two load-dependent Kit test flakes.
  - The orchestrator stopped the run 2 min into fix 2, before any change, and added the class rulings:
    - **L5-R13:** followership precedes registration, with a path enumeration and a seeded model test with invariants I1–I4.
    - **L5-R14:** an enumeration and conversion of every scheduling-dependent Kit test, plus stress runs under load.
    - **L5-R15:** `endClaims` gets a test and the C2 chunking; `heldLane` gets the same-lane test; g.md line fixes.
    - **L5-R16:** a claimed-only job's failure goes to Stage 3.
    - **L5-R17:** the cycle-1 deviations are accepted.
    - **L5-R18:** verifiers run only WP-G's five benchmarks.
- **Close-out: RUNNING from cycle 2:** `wf_0ec4322f-bdb` (task `w2c654soi`), launched 17:45 at weekly 8 %, with `fromCycle: 2` and `findingsFile` `.build-orchestrator/l5-close1-remaining-g.json`.
  - The other arguments are unchanged: strict, `maxCycle: 30`, `usageStop: 50`, `rulingsFile` `.build-orchestrator/l5-rulings.md`, sims fix `897F9D8D…`, reqs `6BE15CAF…`, correct `5B940E6E…`.
  - Run dir: `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/d8335845-1285-454d-9185-a6519bd816cc/subagents/workflows/wf_0ec4322f-bdb`.
- **Close-out cycle 2:** `wf_0ec4322f-bdb`, 17:45–20:55 (3.2 h, weekly 8 % → 12 %, ~4 points).
  - Requirements lens: **0 blocking**.
  - Correctness lens: 1 blocking, L5-C2-00. A retired generation's `clientStarted` is lost, because it shares the engine's terminal slot with `clientShutDown`, which the facade hides.
  - The orchestrator stopped the run 3 min into fix 3, before any change, and ruled:
    - **L5-R19:** `clientShutDown` gets its own engine slot (authorised `SubscriberQueue.swift` edit, two WP-F tests updated to the new mapping), and the model's exemptions are audited.
    - **L5-R20:** `AssetStore.verifyRootNow()` as a package method, plus the facade's root check after file-system-type failures.
    - **L5-R21:** non-blocking test and doc fixes, and an `EngineDispatch.swift` guard.
- **Close-out: RUNNING from cycle 3:** `wf_b17021d0-91c` (task `wyz8ryynw`), launched 21:07 at weekly 13 %, with `fromCycle: 3`, `findingsFile` `.build-orchestrator/l5-close2-remaining-g.json`, and the other arguments as before. Run dir: `…/subagents/workflows/wf_b17021d0-91c`.
- **Re-forecast (22 Oct 21:10).** Measured strict cycles here cost ~3–4 points and ~3 h each, about 2× the L4 calibration, because the fixers run the Kit, Sync and Storage suites and the verifiers run stress series.
  - The blocking count is 4 → 4 → 1, and the requirements lens passed in cycle 2, so likely 2–6 more cycles: 6–21 h and 6–24 points.
  - **WP-G ends:** likely Fri 23 Oct ~07:00 → Sat 24 Oct ~04:00, at weekly ~22–40 %.
  - **WP-K**, recalibrated: ~12–29 h and ~12–30 points.
  - **Level 5 ends:** Fri ~19:00 → Sun 25 Oct ~09:00, at weekly ~34–70 %. It finishes before the 29 Oct reset in every case.
- **Probes** are kept in `.build-orchestrator/l5-probes-r3/` (round 3) and `.build-orchestrator/l5-probes-c1/` (cycle 1, both lenses, plus the correctness verifier's `.fix` candidates).
- **Resume cold** (if this session is gone):
  1. Read the close-out's `journal.jsonl`; the last `verify:g:*:cN` results are the findings.
  2. Dump them to `.build-orchestrator/l5-closeN-remaining-g.json`.
  3. Add any class ruling to `l5-rulings.md` (a defect class repeating over two cycles gets an enumeration and one design fix).
  4. Relaunch `assetkit-closeout.js` with the same arguments, plus `fromCycle: N+1` and the new `findingsFile`.
  5. Delete `.worktrees/g/.build-verify-*` between runs.
- **After 0 blocking in both lenses:** follow steps 8–10 of the scheduled task. That is: merge `--no-ff`; the post-merge gates under `.build-orch`; docs with `assetkit-level-docs.js` (ADR-054, `usageStop: 55`); tag `l5g-merged`; then prepare WP-K and ask the owner.

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
