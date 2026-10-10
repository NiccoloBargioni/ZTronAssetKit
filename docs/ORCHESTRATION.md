# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Owner decisions in force
- **Standalone package.** Nothing outside this repository is ever written, except the device containers of the iOS simulators agents test on (owner-accepted 2026-10-09, ADR-051). `../ZTronCarouselCore` and `../ZTronCarousel` are read-only prior art. PROMPT.md Stage 4 is cancelled; R-CAR-6 shims live in `Tests/ZTronAssetCompatibilityTests` (ADR-006, ADR-033).
- **iOS 15.0 minimum** (macOS 12 test floor). Never raise it.
- **Every test target builds and passes on the iOS Simulator** as well as on macOS (owner, 2026-10-09; ADR-051, convention in `docs/adr-drafts/ios.md` item 2). Agents use their own simulators, never the owner's booted iPhone 17.
- **Work proceeds level by level; the owner decides each level's scope and when to run it.** The owner sets a weekly-usage stop per run; at the stop: re-estimate, rewrite this file, ask.
- The harness is frozen (`git tag harness-frozen`; `Scripts/` never changes; `quality-gates.json` sha256 `2725907c…026f`).

## Where things stand (2026-10-10 evening; weekly usage 68 %, resets Thu 15 Oct 04:00 CEST)
| Item | State |
|---|---|
| Branch | `feature/asset-kit` (never `main`, never push); clean |
| Tags | `harness-frozen`, `contracts`, `l1-merged`, `l2-merged`, `l3-base`, **`l3-merged`** (WP-C + iOS Simulator tests + ADR-051/052) |
| Worktrees | none; no `wp/*` branches |
| Gates at `l3-merged` | `--quick` PASS; release + iOS builds green; **804/804 tests on an iOS 27 simulator**; whole-package TSan PASS, 0 reports; unsafe 0; docs 1281/1281; coverage Storage 97.35 %, Transport 99.08 %, AppleHosted 99.76 %, Model 99.31 %, overall 94.88 % (Kit 37.8 % and Sync 30.6 % are the WP-G/WP-F stubs); trace: 7 MUSTs without a test (R-CAR-1 → G; R-SYN-4/6/7/12/13/14 → F), 8 budgets (P-1/8/12 → G; P-4/7/11/14 → F; P-9 → F, G) |
| Benchmarks (idle host) | P-2 p95 8.97 ms (25), P-3 18.1 ms (80), P-5 ordered p95 13.2 / durable p95 22.4 ms (40), P-6 2,429 MB/s at 0.83× (≥ 800, 0.7×), P-10 8 connections (8), WP-C C2 holds ≤ 2 ms at 10,000 records; **P-13 fails** (unit max 10.7 ms vs 5 ms; owner ruling pending, ADR-050) |
| Owner stash | `git stash` "owner iOS 26 availability edits…" (identical to commit `b9f2752`); the owner may drop it |

## Run the next level (L4 = WP-F sync engine)
1. Pre-flight: `git status` clean; usage headroom (see the forecast); keep-awake (`caffeinate -ims -t 172800` in the background; stop it at the end). `git worktree add .worktrees/f -b wp/f l3-merged`.
2. Launch: `Workflow({scriptPath: ".claude/workflows/assetkit-stage2-level.js", args: {level: "L4", base: "l3-merged", wps: ["f"], usageStop: <owner's threshold>}})`. Per WP: author → two verifiers (own scratch paths and simulators) → up to two fix rounds; a haiku usage probe gates every agent. WP-F's notes in the script carry ADR-050's and ADR-052's assignments (R-NET-8 engine half, Apple-tier NetworkAccess gating, R-STO-1, R-APL-3 end to end, `waitUntil` cancellation, the legacy phase-3 call-again handoff R9/RE-S29, R-CLN-8's distinct engine test, C-9's claims of in-flight publications).
3. Close-out: adapt `.claude/workflows/assetkit-stage2-l3-close.js` (copy it to `…-l4-close.js`; replace `RULINGS`, `FOCUS`, the WP paths and simulator ids; it supports `fromCycle`, `maxCycle`, `verifyFirst`, `previousIssues` (a file pointer works), `extraFixNote`, `usageStop`). **Decide the close-out bar with the owner first** (strict vs converge, see the forecast) — Level 3 needed 8 cycles under the strict bar.
4. Merge `--no-ff`; `--quick`, `--gates-only` (commit `docs/TRACEABILITY.md`), release + iOS builds, a simulator run (`caffeinate -i xcodebuild test … -destination 'platform=iOS Simulator,id=897F9D8D-B10D-4D91-8E22-417A2B9D70AA' -derivedDataPath .build-orch/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never`), and on an idle machine `--perf`, whole-package TSan and the coverage export.
5. Documentation: write `.build-orchestrator/l4-rulings.md`, then `Workflow({scriptPath: ".claude/workflows/assetkit-level-docs.js", args: {level, worktree, base, drafts, rulings, adrs, amendTargets, usageStop}})` (ledger readers → writer → verifier, ≤ 3 rounds; it resolves contract doc comments too). Merge, apply the verifier's last notes, tag `l4-merged`, remove worktrees, report.

## Forecast for the remaining work (re-estimated 2026-10-10 from Levels 2–3 measurements)
Calibration: ~0.07 weekly points per API-equivalent dollar; a close-out cycle (fixer + two verifiers, each running macOS tests ×3, TSan, coverage, release/iOS builds and the ~800-test simulator suite) takes ~2–2.5 h and ~$30–45. Level 3 (WP-C, 19 §11 rows) cost $397 + orchestration = 28 points: iOS tests $18, main run $104, 8 close-out cycles ~$246, docs $29. "Strict" = 0 blocking with a fresh bug hunt every cycle; "converge" = after the first close-out cycles, verifiers confirm fixes and regressions, and new edge cases block only if they break I-1…I-5 or lose data (the rest go to Stage 3 with their probes).

| Step | Scope | Strict: points / run time | Converge: points / run time |
|---|---|---|---|
| L4 WP-F sync engine | 39 §11 rows (largest), 32 stubs, P-4/P-7/P-11/P-14, ADR-050/052 assignments | 32–53 / 28–45 h | 25–32 / 18–24 h |
| L5 WP-G facade | 19 rows, P-1/P-8/P-9/P-12, main-thread rules, KitContractTests `GatedRegistry.waitUntil` | 14–25 / 14–22 h | 11–16 / 10–14 h |
| L5 WP-K shims | R-CAR-6 shims, test target only | 6–10 / 6–10 h | 4–7 / 4–7 h |
| WP-I docs | `docs/**`, README | 3–6 / 3–5 h | 3–6 / 3–5 h |
| Stage 3 hardening | coverage closure, adversarial hunters, ≥ 12 mutation probes, benchmarks, the ADR-052 backlog (C-22/OI-9 maxEntries holds, R8 one-blob holders, OI-15, TSan headroom of WP-H's start/stop race, P-13 once ruled); up to 3 rounds | 18–32 / 12–24 h | 15–25 / 10–18 h |
| Stage 5 final | `verify.sh --full`, VERIFICATION / DEVICE-TEST-PLAN / RESIDUAL-RISKS | 3–6 / 3–6 h | 3–6 / 3–6 h |
| **Total** | | **76–132 points / 66–112 h** | **61–92 points / 48–74 h** |

Run time assumes the Mac stays awake, no outages and no waiting for the owner. With 32 % of this week left, L4's main run and part of its close-out fit before the reset; the week from 15 Oct (~100 points) covers the rest under "converge" and very likely under "strict". Confidence is lowest for WP-F and Stage 3 (whose exit needs `--full` green: P-13's ruling and Sync ≥ 90 % coverage).

## Cost — measured, Opus 5.5 API-equivalent
Summed from the agents' transcript usage (`subagents/workflows/<run>/agent-*.jsonl`, max usage per message) at $4 / $20 / $0.20 (cache read) / $5 (cache write) per MTok.

| Step | Cost | Weekly points |
|---|---|---|
| Stage 1 | ~$180 | — |
| Level 1 (H, A) | ~$190 | — |
| Level 2 (B, D, E) | ~$419 | 31 |
| Level 3 (iOS Simulator tests + C) | ~$397 + orchestration | 28 (40 % → 68 %) |

A full week holds roughly $1,300–1,400 of this workload.

## Trim candidates (owner decides per level)
Background URLSession (R-NET-3) · R-INT-4 deep verification · R-CLN-11 cache purging · crash enumeration beyond single-lifetime scenarios · benchmarks P-7 and P-9 · mutation probes (Q-8) · one verifier instead of two · the simulator run in every verifier (keep it in the author and one verifier) · the "converge" close-out bar. Cutting a MUST or a budget means marking it deferred in `SPEC.md` with a `DECISIONS.md` entry; never edit `Scripts/`.

## Open questions for the owner
1. **Close-out bar for L4 onward:** strict (Level 3's: 8 cycles) or converge (recommended)?
2. **P-13** (ADR-050 · NEEDS-HUMAN-REVIEW): Option A (recommended) p99 per batch; Option B raise `batch_ms_max` to 15 ms.
3. **NEEDS-HUMAN-REVIEW items:** ADR-050 — B-3 index layout; D-10 `shutdown()` cancels background downloads; public `startDownload(…resumeData:)`; D-19.2 task-tag format. ADR-052 — WP-C's R-STO-11 deviations C-12 (checksum-less legacy files without a local checksum are re-downloaded), C-13 (an undecodable legacy manifest adopts nothing), C-14 (a legacy root on another volume is dropped; a legacy file failing three times in one lifetime is abandoned), C-15 (phase 4 keeps unattributable files and a non-empty root).
4. Whether CLAUDE.md should mention the simulator run (ADR-051 "Open"; agents may not edit CLAUDE.md).
5. Outside-repository leftovers (owner may delete; agents may not): `CFNetworkDownload_*.tmp`, `ResultBundle_*.xcresult` and macro-expansion dumps in the per-user temp folder; `~/Library/Developer/Xcode/DerivedData/{l2fu-*,ZTronAssetKit-*}`.

## Lessons from Levels 0–3
- Always pass `-derivedDataPath` to `xcodebuild`; never `xcodebuild -list`; never an unscoped `pkill`; keep the Mac awake (`caffeinate`; simulator runs use `caffeinate -i`).
- One scratch path and one simulator per agent; never the session scratchpad. `verify.sh` writes `.verify-logs/` inside the worktree, so two verifiers running `--quick` in one worktree overwrite each other's logs (take verdicts from exit status).
- When a bug class repeats, demand an exhaustive enumeration (B-33; WP-C's legacy phase-1 state space).
- Benchmarks and TSan only on an idle machine — the owner's Xcode can load the host as much as two agents.
- Failing test committed on its own before the fix; TestSupport waits must end on cancellation (`require…` forms).
- Usage stop: a haiku probe before each agent; in-flight agents finish (≤ 1 point overshoot). A transient DNS outage kills agents; resume the workflow with `resumeFromRunId` (same session) and only the failed agents re-run.
- A verifier told to hunt for new bugs every cycle finds one almost every cycle; budget the close-out bar explicitly.
