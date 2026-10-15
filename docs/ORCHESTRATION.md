# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Level 4 in progress (2026-10-15)
- **Owner decisions (2026-10-15 08:55 CEST):** close-out bar **strict**; weekly-usage stop **55 %**; all roles on **Opus 5.5** (session model, no `models` arg). Usage at launch: weekly all-models 2 %, Fable 0 % (reset 15 Oct 04:00; next reset Thu 22 Oct 04:00 CEST).
- **Forecast (strict):** Level 4 in total 27–45 weekly points, 25–35 h (main run ~8–11 points; close-out 7–10 cycles; docs 2–3 points). Rest of the project after L4 under strict: 44–79 points — likely spills into the week of 22 Oct.
- **Running:** main run `Workflow({scriptPath: ".claude/workflows/assetkit-stage2-level.js", args: {level: "L4", base: "l3-merged", wps: ["f"], bar: "strict", usageStop: 55}})`, run id `wf_3286fe9b-a79`, session `4920f51b-9e95-4e57-8e1e-df565b6e74bf` (resume only from that session with `resumeFromRunId`; from a fresh session, read the run's `journal.jsonl` under `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/4920f51b-9e95-4e57-8e1e-df565b6e74bf/subagents/workflows/wf_3286fe9b-a79/` and continue by hand). `caffeinate -ims -t 172800` started 08:55.
- **Next:** after the main run, write `.build-orchestrator/l4-rulings.md` and `l4-remaining-f.json`, then the close-out (`assetkit-closeout.js`, `bar: "strict"`, `usageStop: 55`, the args listed under "Level 4" below), merge, gates, docs, tag `l4-merged`.

## Previous hand-off (written 2026-10-11 when the owner moved to a fresh session to save credits)
Level 3 is **complete** (`l3-merged`, see the table below). Nothing is running; no worktrees; `feature/asset-kit` is clean. Before anything else, settle with the owner:
1. **Close-out bar for L4 onward** — "converge" recommended (see the forecast). Level 3's strict bar took 8 close-out cycles.
2. **Model plan** (owner asked; analysis below) — recommended: L4 and L5 on Opus 5.5 with the converge bar; **Stage 3's adversarial hunters and mutation-probe agent on Fable 5.1** (note 2026-10-13: Fable usage also counts toward the all-models limit, so this costs ~1.7× Opus for those agents) (fresh eyes over the whole package, backstop for edge cases deferred under "converge"), Stage 3 fixers on Opus; Stage 5 on Opus. The level script's `agent()` calls take a `model` option (`'fable'`, `'opus'`, `'sonnet'`, `'haiku'`) — add an `args.authorModel` / `args.fixModel` / `args.verifyModel` if a level should use another model.
3. **P-13** and the **NEEDS-HUMAN-REVIEW** items (open questions below).
4. **Unanswered owner question: "any non-blocking bugs up to this point?"** Planned answer (not started): a read-only workflow over (a) `docs/adr-drafts/{a,h,b,d,e,l2fu,ios,c}.md`, (b) ADR-049…052's Open / Deferred / Stage 3 bullets, (c) the last verification findings in `.build-orchestrator/` (`l2-remaining-*.json`, `l2-close-remaining-*.json`, `l2-close3-remaining-*.json`, `l2-close5-remaining-*.json`, `l3-remaining-c.json`, `l3-close1-verify-c.json`, `l3-close6-verify-c.json`, `l3-close8-verify-c.json`) — collect every non-blocking item, merge duplicates, check each one still claimed open against the code at `l3-merged` (read-only, no builds), and report them grouped as: proven bugs still open · unproven suspicions · accepted deviations (NEEDS-HUMAN-REVIEW) · performance limits (C-22/OI-9, R8, P-13) · test/environment items (TSan headroom, simulator load). Known examples to expect: OI-15 (an evicted record whose new content is already live is downloaded again), R8 (evicting one blob shared by > ~6,500 records holds the actor ~16 ms), OI-9/C-22 (actor holds of 20–44 ms at 100,000 records), OI-11(b) (a crash between phase 3's durable commit and the end of phase 4 can remove a kept legacy file), D-19.1 (a fresh background task finishing with a ranged 206 is rejected — device check pending), E-10 (released packs tracked in memory only), the TSan time-limit headroom of WP-H's start/stop race under load.

**Tools:** `.claude/tools/cost.py <run dirs>` (API-equivalent cost) and `.claude/tools/timesplit.py <run dirs>` (model vs tool time per agent role). Run dirs: `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/<session>/subagents/workflows/<run id>`; this project's runs so far are under session `7fbcfa21-90df-4f76-8c7c-0ced89fa87b5`. Usage: `mcp__ccd_session_mgmt__get_usage` (reachable from subagents too; the workflows' usage gate uses it).

**Model choice analysis (2026-10-11).** Level 3's fixers and verifiers spent 59–74 % of their wall time in tools (builds, tests ×3, TSan, the ~800-test simulator suite, probes) and 26–41 % in the model, so a faster or better model shortens a cycle by at most a third; the cycle *count* (driven by the close-out bar) dominates. Prices per MTok (input / output / cache read): Opus 5.5 $4 / $20 / $0.20; Sonnet 5.5 $2 / $10 / $0.20 (positioned below Opus for coding; ~15–30 % cheaper on this cache-read-heavy workload, likely more bugs); Fable 5.1 $10 / $50 / $0.25 (most capable; longer turns; ~1.7× Opus per token here; the plan shows a separate "Weekly · Fable" window — whether Fable also counts toward "all models" is unmeasured, so log both windows when trying it; Fable's prompting guide warns that very prescriptive prompts can reduce output quality).

## Level 4 (WP-F sync engine) — prepared 2026-10-13, launch after the weekly reset
- **Usage on 2026-10-13 22:30: 95 %** of the weekly limit (resets **Thu 15 Oct 04:00 CEST**). Level 3 ended at 68 %; the extra 27 points were not this project's workflows (none ran) — over the same days the separate Fable window rose 12 % → 35 %, so **Fable usage evidently also counts toward the all-models limit**. Do not launch Level 4 before the reset.
- **Prepared:** worktree `.worktrees/f` on `wp/f` at `l3-merged`; the level script takes `models: {author, fix, verify}` and `bar: 'strict' | 'converge'` (converge from verification round 2: confirm fixes and regressions; new findings block only if severe — invariant or MUST violation, data loss, crash/deadlock/leak, secret, C2 at 10k, failing gate, a requirement test that does not verify its requirement (G4) — the rest are labelled `stage3:`), passes each round's issues to the next round's verifiers, and carries ADR-050/052's WP-F assignments; the generic close-out `.claude/workflows/assetkit-closeout.js` takes the rulings and findings as files (`args`: wp, name, base, target, testTarget, sections, coverageMin, rulingsFile, findingsFile, focus, bar, models, sims, fromCycle, maxCycle, verifyFirst, usageStop).
- **Launch (from a fresh session, after the reset; owner chooses bar and stop):** `caffeinate -ims -t 172800` in the background, then `Workflow({scriptPath: ".claude/workflows/assetkit-stage2-level.js", args: {level: "L4", base: "l3-merged", wps: ["f"], bar: "converge", usageStop: 40}})`. Close-out: write `.build-orchestrator/l4-rulings.md` and the remaining findings to `.build-orchestrator/l4-remaining-f.json`, then `Workflow({scriptPath: ".claude/workflows/assetkit-closeout.js", args: {wp: "f", name: "WP-F (sync engine)", base: "l3-merged", target: "ZTronAssetSync", testTarget: "ZTronAssetSyncTests", sections: "sections 1.1, 1.2, 2, 7, 10.2, 13.5, 14", coverageMin: 90, rulingsFile: "<abs>/.build-orchestrator/l4-rulings.md", findingsFile: "<abs>/.build-orchestrator/l4-remaining-f.json", bar: "converge", sims: {fix: "897F9D8D-B10D-4D91-8E22-417A2B9D70AA", reqs: "6BE15CAF-7E02-4060-9338-9DAC025EDF0B", correct: "5B940E6E-490F-4E9E-A917-A6456A18225E"}, maxCycle: 4, usageStop: 40}})`. Merge, gates, docs (`assetkit-level-docs.js`), tag `l4-merged` as in Level 3.
- **Refined estimate (2026-10-13).** WP-F has 39 §11 rows / 104 named tests (WP-C 21 / 92, WP-B 28 / 68), the most concurrent code, four benchmarks (P-4, P-7 1 GiB, P-11 loopback, P-14) and cross-layer integration tests. Calibration 0.074 weekly points per API-equivalent dollar (Level 2, no other usage in that window). Main run $115–150; close-out strict 7–10 cycles ($210–400) or converge 2–4 cycles ($60–160); docs $30–45; orchestration from a fresh session $5–15.

  | Bar | Weekly points | Run time | Ends at (started right after the reset, no other usage) |
  |---|---|---|---|
  | converge | 16–27 | 14–21 h | ~16–27 % |
  | strict | 27–45 | 25–35 h | ~27–45 % |

  The rest of the project after Level 4 (G, K, I, Stage 3, Stage 5): converge 36–60 points, strict 44–79 — so under "converge" everything should fit in the week from 15 Oct (~52–87 % in total); under "strict" it likely spills into the week after. Fable for Stage 3's hunters costs ~1.7× Opus per token and counts toward the all-models limit.

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
1. ~~Close-out bar for L4 onward~~ — answered 2026-10-15: **strict** for L4 (ask again for L5).
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
