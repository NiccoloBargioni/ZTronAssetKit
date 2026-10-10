# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Owner decisions in force
- **Standalone package.** Nothing outside this repository is ever written, except the device containers of the iOS simulators agents test on (owner-accepted 2026-10-09). `../ZTronCarouselCore` and `../ZTronCarousel` are read-only prior art. PROMPT.md Stage 4 is cancelled; R-CAR-6 shims live in `Tests/ZTronAssetCompatibilityTests` (ADR-006, ADR-033).
- **iOS 15.0 minimum** (macOS 12 test floor). Never raise it.
- **Every test target builds and passes on the iOS Simulator** as well as on macOS (owner, 2026-10-09; convention in `docs/adr-drafts/ios.md`). Agents use their own simulators, never the owner's booted iPhone 17.
- **Level 3 runs at full specification** (WP-C). **Weekly-usage stop:** stop launching agents at the owner's threshold (last set: 55 %), re-estimate, rewrite this file, ask the owner whether to continue now or after the weekly reset.
- The harness is frozen (`git tag harness-frozen`; `Scripts/` never changes; `quality-gates.json` sha256 `2725907c…026f`).

## Where things stand (2026-10-09 evening; weekly usage 55 %, resets Thu 15 Oct 04:00 CEST)
| Item | State |
|---|---|
| Branch | `feature/asset-kit` (never `main`, never push); clean |
| Tags | `harness-frozen`, `contracts`, `l1-merged`, `l2-merged`, **`l3-base`** (`l2-merged` + the iOS Simulator test build + doc follow-ups) |
| Worktrees | **`.worktrees/c` on `wp/c`**: WP-C implemented, 72 commits on `l3-base`, clean |
| Level 3 progress | Main run `wf_7bbebd31-575` done (author → 3 verification rounds → 2 fix rounds; blocking 8 → 5 → 5). Close-out `wf_23e43bcf-739`: cycle 1 fixed all 5 and applied rulings R1–R5 (its verification: 2 blocking / 11); **cycle 2 fixed both blockers and the clear non-blocking items but is NOT yet independently verified** — the run stopped at the usage gate before `verify:2` (55 %) |
| Live run | Level 3 close-out finished: 8 cycles, final verification 0 blocking in both lenses. **WP-C merged** (38d23f9): `--quick` PASS, release + iOS green, 804/804 on the iOS 27 simulator, unsafe 0, docs 1281/1281, trace 7 MUSTs left (F/G). Docs pass `wf_db814090-f2d` (ADR-051 iOS Simulator tests, ADR-052 Level 3) in `.worktrees/l3docs`. Pending: idle-machine `--perf`, whole-package TSan and coverage (deferred while the owner's Xcode was busy), then tag `l3-merged` |
| Findings files | `.build-orchestrator/l3-remaining-c.json` (round 3), `.build-orchestrator/l3-close1-verify-c.json` (close-out cycle 1 — what cycle 2 fixed) |
| Rulings | In `.claude/workflows/assetkit-stage2-l3-close.js` (`RULINGS`) and recorded in `docs/adr-drafts/c.md`: R1 CCR-2 (orphan GC vs `apply` adoption; merge-gating), R2 CCR-1 (`doomOrphans` primitive in `StoreInternals.swift`), R3 OI-1 (`apply` never re-adopts `absent(.evicted)`), R4 C2 ≤ 10 ms at 10,000 records, R5 deviations C-6/C-12/C-13/C-14/C-15 accepted, to be tagged NEEDS-HUMAN-REVIEW in ADR-051 |
| Owner stash | `git stash` "owner iOS 26 availability edits…" = the owner's original edits, identical to commit `b9f2752`; the owner may drop it |
| Gates at `l3-base` | `--quick` PASS (macOS); 669/669 tests on an iOS 27 simulator; release + iOS builds green; unsafe 0; docs 1281/1281 |
| Gates on `wp/c` (fixer-reported for cycle 2, not yet independently verified) | `--quick` PASS (Storage 416 tests); release + iOS green; Storage coverage ~97 %; simulator `TEST SUCCEEDED`; C2 longest actor hold ≤ 2.2 ms at 10,000 records; trace: 7 MUSTs left (R-CAR-1 → G; R-SYN-4/6/7/12/13/14 → F) |

## Resume Level 3 (remaining steps)
1. Pre-flight: `git status` clean; usage headroom; keep-awake (`caffeinate -ims -t 172800` in the background; stop it at the end).
2. **Verify cycle 2, then fix/verify until 0 blocking**, from any session: `Workflow({scriptPath: ".claude/workflows/assetkit-stage2-l3-close.js", args: {usageStop: <threshold>, fromCycle: 2, maxCycle: 4, verifyFirst: true, previousIssues: <JSON contents of .build-orchestrator/l3-close1-verify-c.json>}})`. It verifies the committed cycle-2 fixes with both lenses (reproducing the cycle-1 issues), then runs fix → verify cycles 3–4 if needed, with the usage gate before every agent.
3. Also fix **OI-8** in the next fix cycle: WP-A's `R-MAN-3: the table estimate bounds the storage of a dictionary from AssetID to Int reserved for any count` failed twice on the iOS Simulator in cycle 1 (process-wide heap measurement: measured 544 vs estimated 128 at count 1) and passed in cycle 2's run — make it deterministic on the simulator without weakening it (an orchestrator-authorised edit to WP-A's test).
4. Merge `wp/c` `--no-ff`; `verify.sh --quick`, `--gates-only` (commit `docs/TRACEABILITY.md`), release + iOS builds, an iOS Simulator run, and on an idle machine `--perf`, whole-package TSan and the coverage export.
5. Documentation: rulings file → ledger reader for `docs/adr-drafts/c.md` → one writer → independent verifier (ADR-051; ARCHITECTURE amendments incl. OI-6: §1.1, §4.6, §4.7, §10.1 rows c-n, §11 R-CLN-8 naming, §12.2 S2-06, §14 `LiveLegacyDefaults` figure; the new `BenchCleanup.swift` in §1.2; NEEDS-HUMAN-REVIEW for the R-STO-11 deviations) → close pass for ADR-051's open items. Templates: the Level 2 finish scripts in session `7fbcfa21…` (`~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/7fbcfa21-90df-4f76-8c7c-0ced89fa87b5/workflows/scripts/assetkit-stage2-l2-finish-*.js`, `…-l2-close-pass-*.js`).
6. Tag `l3-merged`, remove the worktree, delete `wp/c`, report.

## Usage estimate to finish Level 3 (re-estimated at 55 %)
Calibration: the plan meter moved ~0.075 points per API-equivalent dollar in Level 2 and in Level 3 (main run $104 ≈ 8 points).

| Remaining step | API-equivalent | Weekly points |
|---|---|---|
| Verify cycle 2 (two lenses) | $15–20 | ~1.3 |
| 1–2 more fix/verify cycles (+ OI-8) | $30–60 | 2.3–4.5 |
| Merge, gates, idle benchmarks/TSan/simulator (orchestrator) | ~$5 | ~0.4 |
| Docs: ledger, writer, verifier, close pass (one draft) | $30–45 | 2.3–3.4 |
| Orchestrator session | ~$10 | ~0.8 |
| **Total** | **$90–140** | **~7–10 → Level 3 ends at ~62–65 %** |

Spent on Level 3 so far: the iOS Simulator test build $18, the main run $104, close-out cycles 1–2 ~$55 — 15 weekly points with orchestration (40 % → 55 %). Blocking findings went 8 → 5 → 5 → 2 → (unverified); Level 2's WP-B needed five close-out cycles, so one or two more is the likely range, with three as the bad case (~+2 points).

## Forecast for the remaining work (re-estimated 2026-10-10 from Levels 2–3 measurements)
Calibration: ~0.072 weekly points per API-equivalent dollar; a close-out cycle (fixer + two verifiers, each running macOS tests ×3, TSan, coverage, release/iOS builds and the ~800-test simulator suite) takes ~2–2.5 h and ~$30–45. Level 3 (WP-C, 19 §11 rows) needed a $104 main run plus 8 close-out cycles (~$240): the correctness verifier, told to hunt for new bugs every cycle, proved one new edge case almost every round. "Strict" = keep that bar (0 blocking, hunting every cycle); "converge" = after the first close-out cycles, verifiers confirm fixes and regressions, and new edge cases block only if they break I-1…I-5 or lose data (the rest go to Stage 3 with their probes).

| Step | Scope | Strict: points / run time | Converge: points / run time |
|---|---|---|---|
| Level 3 rest | cycle 8 verification, ≤ 1 more cycle, merge, docs (ADR-051) | 5–7 / 4–7 h | 4–5 / 4–5 h |
| L4 WP-F sync engine | 39 §11 rows (largest), 32 stubs, P-4/P-7/P-11/P-14, ADR-050 assignments | 32–53 / 28–45 h | 25–32 / 18–24 h |
| L5 WP-G facade | 19 rows, P-1/P-8/P-9/P-12, main-thread rules | 14–25 / 14–22 h | 11–16 / 10–14 h |
| L5 WP-K shims | R-CAR-6 shims, test target only | 6–10 / 6–10 h | 4–7 / 4–7 h |
| WP-I docs | `docs/**`, README | 3–6 / 3–5 h | 3–6 / 3–5 h |
| Stage 3 hardening | coverage closure, adversarial hunters, ≥ 12 mutation probes, benchmarks, Stage-3 backlog (C-22/OI-9 maxEntries holds, R8, TSan headroom, P-13 once ruled); up to 3 rounds | 18–32 / 12–24 h | 15–25 / 10–18 h |
| Stage 5 final | `verify.sh --full`, VERIFICATION / DEVICE-TEST-PLAN / RESIDUAL-RISKS | 3–6 / 3–6 h | 3–6 / 3–6 h |
| **Total after Level 3** | | **76–132 points / 66–112 h** | **61–92 points / 48–74 h** |

Run time assumes the Mac stays awake, no outages and no waiting for the owner. Calendar: Level 3 ends at ~70–72 % this week, so ~28 points remain before the reset (Thu 15 Oct 04:00 CEST) — enough for most of L4's main run; L4 finishes after the reset. The week from 15 Oct (~100 points) then covers the rest under "converge" (~33–64 points left) and very likely under "strict" (~48–104), with the bad strict case spilling into the following week. Confidence is lowest for WP-F (most concurrent code, most requirements) and Stage 3 (its exit needs `--full` green, which needs the owner's P-13 ruling and Sync ≥ 90 % coverage).

## Cost — measured, Opus 5.5 API-equivalent
Summed from the agents' transcript usage (`subagents/workflows/<run>/agent-*.jsonl`, max usage per message) at $4 / $20 / $0.20 (cache read) / $5 (cache write) per MTok.

| Step | Cost |
|---|---|
| Stage 1 | ~$180 |
| Level 1 (H, A) | ~$190 |
| Level 2 (B, D, E) | ~$419 (31 weekly points) |
| Level 3 so far (iOS tests + C) | ~$177 (15 weekly points incl. orchestration) |

A full week holds roughly $1,300 of this workload.

## Trim candidates (owner decides per level)
Background URLSession (R-NET-3) · R-INT-4 deep verification · R-CLN-11 cache purging · crash enumeration beyond single-lifetime scenarios · benchmarks P-7 and P-9 · mutation probes (Q-8) · one verifier instead of two · the simulator run in every verifier (keep it in the author and one verifier). Cutting a MUST or a budget means marking it deferred in `SPEC.md` with a `DECISIONS.md` entry; never edit `Scripts/`.

## Open questions for the owner
1. ~~Continue Level 3 now?~~ Answered 2026-10-10: finish Level 3.
2. **P-13** (ADR-050 · NEEDS-HUMAN-REVIEW): Option A (recommended) p99 per batch; Option B raise `batch_ms_max` to 15 ms.
3. **NEEDS-HUMAN-REVIEW items of ADR-050:** B-3 index layout; D-10 `shutdown()` cancels background downloads; public `startDownload(…resumeData:)`; D-19.2 task-tag format. Coming in ADR-051: WP-C's R-STO-11 deviations (C-12 checksum-less legacy files without a local checksum are re-downloaded, C-13 an undecodable legacy manifest adopts nothing, C-14 a legacy root on another volume is dropped, C-15 phase 4 keeps unattributable files and a non-empty root).
4. Outside-repository leftovers (owner may delete; agents may not): `CFNetworkDownload_*.tmp`, `ResultBundle_*.xcresult` and macro-expansion dumps in the per-user temp folder; `~/Library/Developer/Xcode/DerivedData/{l2fu-*,ZTronAssetKit-*}`.

## Lessons from Levels 0–3
- Always pass `-derivedDataPath` to `xcodebuild`; never `xcodebuild -list`; never an unscoped `pkill`; keep the Mac awake (`caffeinate`; agents' simulator runs use `caffeinate -i`).
- One scratch path and one simulator per agent; never the session scratchpad.
- When a bug class repeats, demand an exhaustive enumeration (B-33 for WP-B; WP-C's legacy phase-1 state space).
- Benchmarks and TSan only on an idle machine.
- Failing test committed on its own before the fix; TestSupport waits must end on cancellation (`require…` forms).
- Usage stop: a haiku probe before each agent (`mcp__ccd_session_mgmt__get_usage` is reachable from subagents); in-flight agents finish, so expect up to ~1 point of overshoot.
