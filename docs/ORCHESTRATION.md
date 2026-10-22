# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Next session: start here (written 2026-10-23 01:00 CEST, after WP-G)
- **WP-G is complete.**
  - `l5g-merged` = `da8d444`, WP-G plus its documentation (ADR-054). See "Level 5 WP-G — done".
  - Nothing is running. There are no worktrees and no `wp/*` branches, and `feature/asset-kit` is clean.
  - Weekly usage is **17 %** (Fable 0 %). It resets **Thu 29 Oct 04:00 CEST**.
  - A `caffeinate -ims -t 259200` from 22 Oct 09:48 holds the Mac awake until 25 Oct 09:48. It is a background task of session `d8335845-…`, so start a new one when launching from another session.
- **Waiting for the owner:** whether to run **WP-K** now, and its weekly-usage stop. The 55 % stop covered WP-G only.
  - Unless the owner says otherwise, the L5 decisions carry over: **strict** bar, all roles on the session model (no `models` argument).
  - Do not re-ask the bar.
- **Next:** WP-K, the second half of Level 5 (ARCHITECTURE §1.2: "L5, after G"). See "Level 5 WP-K — prepared" below. After it comes `l5-merged`, then WP-I docs, Stage 3 and Stage 5.

## Level 5 WP-K (R-CAR-6 compatibility shims) — prepared
- **Scope:** WP-K's notes in `.claude/workflows/assetkit-stage2-level.js`.
  - Drop-in shims in `Tests/ZTronAssetCompatibilityTests/Shims/` for every pre-existing public CDN symbol of the prior art (`../ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/`, read-only), as adapters over `AssetClient`.
  - Tests that re-express RECON §5's observable behaviours against a real `AssetClient` over the fakes.
  - Optionally `docs/MIGRATION.md`.
  - The target is "(test target only)", the test target `ZTronAssetCompatibilityTests`, and the coverage minimum 70.
- **Script ready:** authors now read ADR-054, and WP-K's notes cite ADR-054's "WP-K (Level 5, after G)" note:
  - the facade's reopen, event-continuity and `ensureAvailable` semantics;
  - L5-R14's test rules;
  - `KitHarness` is not importable, so WP-K builds its own harness;
  - `--filter` matches function names.
- **Launch:**
  1. `get_usage` right before launch, and check that `git status` is clean.
  2. Start `caffeinate -ims -t 172800` with `run_in_background`.
  3. `git worktree add .worktrees/k -b wp/k l5g-merged`.
  4. `Workflow({scriptPath: "/Users/admin/Documents/ZTronAssetKit/.claude/workflows/assetkit-stage2-level.js", args: {level: "L5", base: "l5g-merged", wps: ["k"], bar: "strict", usageStop: <owner stop − 5>}})`.
- **Close-out** (as for WP-G):
  1. Write `.build-orchestrator/l5k-rulings.md` in the style of `l5-rulings.md`, and dump `l5k-remaining-k.json`.
  2. Run `assetkit-closeout.js` with `{wp: "k", name: "WP-K (compatibility shims)", base: "l5g-merged", target: "(test target only)", testTarget: "ZTronAssetCompatibilityTests", sections: "sections 1.2, 8, 14; ADR-006, ADR-033, ADR-054; docs/RECON.md section 5", coverageMin: 70, rulingsFile, findingsFile, focus, bar: "strict", sims: {fix: "897F9D8D-B10D-4D91-8E22-417A2B9D70AA", reqs: "6BE15CAF-7E02-4060-9338-9DAC025EDF0B", correct: "5B940E6E-490F-4E9E-A917-A6456A18225E"}, maxCycle: 30, usageStop: <owner stop − 5>}`.
  3. When a class repeats, stop the run right after its verification, before the next fixer has changed anything; add the class ruling; relaunch with `fromCycle`.
- **Merge, gates and docs:**
  - Merge `--no-ff`.
  - Gates: `.build-orch/l5/l5-gates-a.sh` (phase A; point its `L` at `.build-orch/l5k`), then near-idle TSan and `--perf`.
  - Docs: `assetkit-level-docs.js` with `level: "L5 (WP-K)"`, `worktree: "l5kdocs"`, `drafts: ["k"]`, `adrs: "ADR-055 (Stage 2 level 5 merge: WP-K compatibility shims)"`.
  - Confirm the acknowledged items, apply the last notes, merge, re-run `--quick` and `--gates-only`, then tag **`l5-merged`**.
- **Forecast (strict, from L5 WP-G's measured costs).**
  - Main run: $50–80, 3.5–5 h.
  - 2–6 close-out cycles at $25–45 and 1.5–2.5 h each. These are lighter than WP-G's, because there are no engine or store suites unless WP-K's tests expose a facade bug.
  - Docs and gates: ~$40, 2–3 h.
  - **Total ~9–23 h and ~8–24 weekly points.** Launched at 17 %, it ends at **~25–41 %**, within a day if runs are continuous.
  - The main risk: a facade bug that WP-K's tests expose sends work back into WP-G's code as an authorised edit.

## Level 5 WP-G — done (22–23 Oct)
- **Owner decisions (18 Oct):**
  - Level 5 starts with WP-G only, after the 22 Oct reset.
  - Strict bar; session model.
  - Stop 55 % for all of WP-G: 50 for the main run and the close-out, 55 for docs.
- **Launch:** the scheduled task `ztron-assetkit-level5-launch` launched it, firing at 09:48 rather than 04:20. Session `d8335845-1285-454d-9185-a6519bd816cc`.
- **Runs:**

  | Run | What | Time | Weekly | Cost |
  |---|---|---|---|---|
  | `wf_6593085d-170` | main run: author + 3 verification rounds; blocking 2 → 3 → 4 | 09:49–14:30 | 0 → 5 % | $75 |
  | `wf_a049b89c-afb` | close-out cycle 1; 4 blocking left, 3 distinct | 14:39–17:34 | 5 → 8 % | $62 |
  | `wf_0ec4322f-bdb` | cycle 2 (after L5-R13…R18); reqs 0, correct 1 | 17:45–20:55 | 8 → 12 % | $64 |
  | `wf_b17021d0-91c` | cycle 3 (after L5-R19…R21); **0 blocking in both lenses** | 21:07–22:47 | 13 → 15 % | $37 |
  | `wf_bdef0756-da0` | docs: ledger + 1 round, 0 blocking (ADR-054) | 23:05–00:35 | 15 → 16 % | $37 |

  Total **~$275 plus orchestration**, about 15 h from launch to tag. Weekly 0 % → 17 %, which is 0.062 points per dollar.
- **Records:**
  - Rulings L5-R1…R24 are in `.build-orchestrator/l5-rulings.md`, which is local and gitignored.
  - ADR-054 is in `docs/DECISIONS.md`, with ARCHITECTURE amended (§1, §2, §5, §6.4, §7, §8, H-9, §10.6 rows g-1…g-12, §11, §12, §14).
  - WP-G's decisions G-1…G-18 are in `docs/adr-drafts/g.md`.
  - Findings files: `l5-remaining-g.json`, `l5-close1-remaining-g.json`, `l5-close2-remaining-g.json`. Probes: `l5-probes-r3/`, `l5-probes-c1/`, `l5-probes-c2/`.
- **Class rulings that converged it:**
  - L5-R1: engine pending claims, for R-CAR-3.
  - L5-R2: shutdown from `created`.
  - L5-R13/R19: event continuity. Followership comes before registration, a seeded model test checks invariants I1–I4, and `clientShutDown` gets its own `.clientEnd` engine slot.
  - L5-R14: the scheduling-dependent Kit tests.
  - L5-R20: `AssetStore.verifyRootNow()` after failures that may stem from the file system.
- **Authorised edits outside WP-G:**
  - WP-F: `EngineCommands`, `EngineJobs`, `EngineState`, `EngineLifecycle`, `EngineDispatch` (guard only), `SubscriberQueue`, two Level 4 tests updated to the new slot mapping, and three new engine test files.
  - WP-B: `AssetStore.unavailableReason` and `verifyRootNow()` (package API), and a new store test file.
  - `KitContractTests.swift` (G-8).
- **Gates at `l5g-merged`** (logs `.build-orch/l5/summary.txt`):
  - `--quick` PASS at `3de588e` and at `da8d444`; `--gates-only` PASS at both (TRACE PASS: P-1, P-8 and P-12 now have benchmarks).
  - Release and iOS builds are green; the simulator ran **1,195/1,195**.
  - Coverage: Kit 97.83 %, Sync 93.54 %, Storage 97.41 %, overall 96.60 %.
  - Whole-package TSan: 0 reports.
  - `--perf` at near-idle: 34/35. **P-13 fails** (8.89 ms vs 5 ms, owner item), so `--perf` is `VERIFY: FAIL (1 failed: benchmarks)`.
- **Stage 3 backlog added** (ADR-054 Assignments):
  - L5-R16: a claim that inherits the retry policy.
  - L5-R22 (1): pin the stopped-registration exit.
  - L5-R22 (3): pin `sync`'s trigger list.
  - L5-R22 (4): the false positive in the engine's own invariant check.
  - The model tightening of L5-R22 (2).
  - CCR-G1's run-time detection (L5-R5).
  - The optional P-9 survey.

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

## Where things stand (2026-10-23 01:00 CEST; weekly usage 17 %)
| Item | State |
|---|---|
| Branch | `feature/asset-kit` (never `main`, never push); clean after this commit |
| Tags | `harness-frozen`, `contracts`, `l1-merged`, `l2-merged`, `l3-base`, `l3-merged`, `l4-merged`, **`l5g-merged`** (`da8d444`: WP-G + ADR-054) |
| Worktrees | none; no `wp/*` branches |
| Gates at `l5g-merged` | `--quick` PASS; `--gates-only` PASS (trace PASS, unsafe 0, docs 1281/1281); release + iOS builds green; **1,195/1,195 on an iOS 27 simulator**; whole-package TSan PASS, 0 reports (7 targets: 151, 323, 445, 84, 85, 3, 104 tests); coverage Kit 97.83 %, Sync 93.54 %, Storage 97.41 %, Transport 99.08 %, AppleHosted 99.76 %, Model 99.31 %, overall 96.60 % |
| Benchmarks (load ~3–5) | 34/35 pass: P-1 0.417 µs (25), P-2 p95 9.10 ms (25), P-3 18.0 ms (80), P-4 11.4 ms (20; ratio 2.02), P-5 ordered p95 14.9 / durable p95 30.9 ms (40), P-6 2,392 MB/s at 0.82×, P-7 0.89 / 0.16 MiB (48), P-8 p99 ≤ 0.04 ms (1.0), P-9 heartbeat p99 15.1 ms (50), P-10 8 connections, P-11 speedup 3.43 (≥ 3), P-12 0.009 ms, P-14 0/0; every C2 benchmark ≤ 6.0 ms (10); **P-13 fails** (8.89 ms vs 5 ms; owner ruling pending, ADR-050) |
| Logs | `.build-orch/l5/` (summary.txt, quick, gates, coverage, sim, tsan, perf; `l5-gates-a.sh` is the phase-A script) |
| Owner stash | `git stash` "owner iOS 26 availability edits…" (identical to commit `b9f2752`); the owner may drop it |

## Run a level (the Level 4/5 procedure)
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
   - Run the phase-A gates; the script is `.build-orch/l5/l5-gates-a.sh` (copy it and point `L` at the new log dir): `--quick`; `--gates-only` (commit `docs/TRACEABILITY.md`); release and iOS builds; the coverage export; a simulator run with `-derivedDataPath .build-orch/xcode-sim -collect-test-diagnostics never`.
   - Then, on a near-idle machine: whole-package TSan (`--scratch-path .build-orch-tsan`) and `verify.sh --perf`.
5. **Docs:**
   - Add a worktree `.worktrees/<lN>docs` at the merge head.
   - Run `assetkit-level-docs.js` (`level`, `worktree`, `base`, `drafts`, `rulings`, `adrs`, `amendTargets`, `usageStop`).
   - Confirm or rule on every "Acknowledged at merge" item the writer raises, and apply the verifier's last notes yourself.
   - Merge, then run `--quick` and `--gates-only` again, tag, remove the worktrees and branches, and rewrite this file.

## Forecast for the remaining work (re-estimated 2026-10-23 from Level 5 WP-G)
**Calibration:**
- ~0.062 weekly points per API-equivalent dollar (L5 WP-G, orchestration included).
- Strict close-out cycles in L5 cost $37–64 (≈ 2.3–4 points) and 1.7–3.2 h when they carry cross-package edits and stress series; L4's cycles cost ~$27 and ~2.1 h.
- Class rulings at the first repeat kept WP-G to 3 close-out cycles, against 6–15 forecast.

| Step | Scope | Strict: points / run time |
|---|---|---|
| L5 WP-K shims | R-CAR-6 shims, test target only; 2–6 cycles | 8–24 / 9–23 h |
| WP-I docs | `docs/**`, README | 3–6 / 3–5 h |
| Stage 3 hardening | coverage closure, adversarial hunters (Fable optional, ~1.7× Opus), ≥ 12 mutation probes, the ADR-052/053/054 backlogs, P-13 once ruled | 28–50 / 20–38 h |
| Stage 5 final | `verify.sh --full`, VERIFICATION / DEVICE-TEST-PLAN / RESIDUAL-RISKS | 3–6 / 3–6 h |
| **Total** | | **42–86 points / 35–72 h** |

**When it ends:**
- The week to 29 Oct 04:00 has ~83 points left (17 % used), so WP-K, WP-I and most or all of Stage 3 fit before the reset if runs are continuous.
- The project could finish around 25–28 Oct.
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
| Level 5 WP-G (strict, main run + 3 cycles + docs) | ~$275 + orchestration | 17 (0 % → 17 %) |

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
1. **WP-K now?** If yes, give a weekly stop for it. The forecast ends at ~25–41 %, so a stop of 45 % would leave room; the close-out then gets 40. The bar stays strict.
2. **P-13** (ADR-050 · NEEDS-HUMAN-REVIEW): Option A (recommended) judges the p99 per batch; Option B raises `batch_ms_max` to 15 ms. It still fails at `l5g-merged`: 8.89 ms wall (1.04 ms on CPU) vs 5 ms at near-idle.
3. **NEEDS-HUMAN-REVIEW items:**
   - ADR-050: B-3 index layout; D-10 `shutdown()` cancels background downloads; public `startDownload(…resumeData:)`; D-19.2 task-tag format.
   - ADR-052: WP-C's R-STO-11 deviations C-12…C-15.
   - Levels 4 and 5 added none. ADR-054 lists owner *information* only: G-1/G-5's reopen behaviour, pins lost with a vanished root, and R-NET-3's run-time half undetected (the attestation is what "wired" means, L5-R5).
4. **Unanswered: "any non-blocking bugs up to this point?"** The planned read-only survey (drafts a, h, b, d, e, l2fu, ios, c, f, g; ADR-049…054's Open, Deferred and Stage 3 bullets; `.build-orchestrator/` findings) has not started. It now includes ADR-054's Stage 3 list.
5. Whether CLAUDE.md should mention the simulator run (ADR-051 "Open"; agents may not edit CLAUDE.md).
6. Outside-repository leftovers (the owner may delete them; agents may not): `CFNetworkDownload_*.tmp`, `ResultBundle_*.xcresult` and macro-expansion dumps in the per-user temp folder; `~/Library/Developer/Xcode/DerivedData/{l2fu-*,ZTronAssetKit-*}`.

## Lessons from Levels 0–5
- Always pass `-derivedDataPath` to `xcodebuild`; never `xcodebuild -list`; never an unscoped `pkill`; keep the Mac awake (`caffeinate`; simulator runs use `caffeinate -i`).
- One scratch path and one simulator per agent; never the session scratchpad. `verify.sh` writes `.verify-logs/` inside the worktree, so two verifiers running `--quick` in one worktree overwrite each other's logs (take verdicts from exit status).
- **When a bug class repeats, order an exhaustive enumeration and one design fix.** Examples: B-33, WP-C's legacy phase-1 state space, L4-R17 (scheduling-dependent tests), and L4-R20 (stale gates: three cycles to converge after 19 cycles of case-by-case fixes).
- The strict bar finds real bugs late: cycles 7–9 of L4 found pre-existing C2 stalls and liveness bugs. It also costs: L4 took 22 cycles. Budget the bar explicitly, and log blocking counts per cycle to spot a non-converging family early.
- Benchmarks and TSan only on a near-idle machine. The owner's Xcode can load the host as much as two agents.
- Failing test committed on its own before the fix; TestSupport waits must end on cancellation (`require…` forms).
- Usage stop: a haiku probe before each agent; in-flight agents finish (≤ 1 point overshoot). A transient DNS outage kills agents; resume the workflow with `resumeFromRunId` (same session), and only the failed agents re-run.
- Verifiers' scratch builds grow ~2–4 GB each per cycle; delete `.build-verify-*` between runs.
- Answer agents' questions to the orchestrator promptly in the rulings file; an unanswered one (the cycle-1 `recordFailure` guard question) is carried as residue for many cycles.
- **L5: class rulings at the first repeat, then stop and relaunch.** Stop the close-out right after a verification, while the next fixer has changed nothing yet (`TaskStop`, check that the tree is clean, relaunch with `fromCycle`). It costs minutes and gives the fixer the ruling from its first read.
- **Rule semantics only after reading the code.** L5-R22 (5) stated `current()`'s behaviour imprecisely; the docs writer rightly kept the code's actual semantics, and L5-R24 corrected the ruling.
- **Authorised edits across packages beat workarounds.** The engine claims (L5-R1), the `.clientEnd` slot (L5-R19) and `verifyRootNow()` (L5-R20) each landed in one cycle. Name the files, keep signatures, and require failing-first tests in the owning package's target.
- **A seeded model test with a direct-subscriber oracle finds lifecycle races, but audit its exemptions.** An unjustified exemption hid L5-C2-00.
- **Verifiers ran the whole 35-test benchmark suite.** It took 432 s and loaded the host to 100–200 for the other lens. Each lens now runs only its WP's benchmarks (L5-R18); the orchestrator runs the full suite at near-idle.
- **Shell:** `grep -c` with no match prints 0 and exits 1, so use `n=$(grep -c … || true)`. Foreground `sleep` over 2 min moves a command to the background.

## Tools and model notes
- **Tools:** `.claude/tools/cost.py <run dirs>` (API-equivalent cost) and `.claude/tools/timesplit.py <run dirs>` (model vs tool time per agent role).
  - Run dirs are `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/<session>/subagents/workflows/<run id>`.
  - Sessions: `7fbcfa21-90df-4f76-8c7c-0ced89fa87b5` (Levels 1–3), `4920f51b-9e95-4e57-8e1e-df565b6e74bf` (Level 4) and `d8335845-1285-454d-9185-a6519bd816cc` (Level 5 WP-G).
  - Usage: `mcp__ccd_session_mgmt__get_usage`.
- **Models:**
  - L4 close-out agents spent ~45–55 % of their wall time in tools, and ~45–55 % in the model.
  - Prices per MTok (input / output / cache read): Opus 5.5 $4 / $20 / $0.20; Sonnet 5.5 $2 / $10 / $0.20; Fable 5.1 $10 / $50 / $0.25, which counts toward the all-models limit (observed 13 Oct).
  - The level and close-out scripts take `models: {author, fix, verify}` (`'opus' | 'fable' | 'sonnet'`).
