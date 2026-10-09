# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Owner decisions in force
- **Standalone package.** Nothing outside this repository is ever written. `../ZTronCarouselCore` and `../ZTronCarousel` are read-only prior art. PROMPT.md Stage 4 (adoption in ZTronCarouselCore) is cancelled; R-CAR-6 shims live in `Tests/ZTronAssetCompatibilityTests` (ADR-006, ADR-033).
- **iOS 15.0 minimum** (macOS 12 test floor). Never raise it.
- **Work proceeds level by level; the owner decides each level's scope.** Level 2 ran at full specification. **Level 3's scope is not decided yet** — ask the owner (see "Trim candidates").
- The harness is frozen (`git tag harness-frozen`; `Scripts/` never changes; `quality-gates.json` sha256 `2725907c…026f`).

## Where things stand
| Item | State |
|---|---|
| Branch | `feature/asset-kit` (never `main`, never push) |
| Tags | `harness-frozen`, `contracts` (Stage 1), `l1-merged` (WP-H, WP-A), **`l2-merged`** (WP-B storage core, WP-D transport, WP-E Apple tier, follow-ups; ADR-050) |
| Worktrees | none (all Level 2 worktrees and `wp/*` branches removed) |
| Old runs | `wf_262e4b03-7f6` (paused Level 2 run of an earlier session, old prompts): **never resume it** |
| Gates at `l2-merged` | `--quick` PASS; release + iOS builds green; whole-package TSan 0 reports; unsafe 0; docs 1281/1281; coverage Storage 95.4 %, Transport 99.1 %, AppleHosted 99.8 %, Model 99.3 %, overall 93.5 % (Kit and Sync fail only as WP-F/G stubs); trace: 13 MUSTs without a test (R-CAR-1 → G; R-CLN-2/3/4/12 → C; R-CLN-6/8 → C, F; R-SYN-4/6/7/12/13/14 → F) and 8 budgets (P-1/8/12 → G; P-4/7/14 → F; P-9 → F, G; P-11 → F) |
| Benchmarks | P-2, P-3, P-5, P-6, P-10 pass with wide margins; **P-13 fails** (unit max 9–12 ms vs 5 ms, one kernel-stalled `unlink` per overrun) — proposal awaiting the owner (ADR-050) |

## Run the next level
1. Pre-flight: `git status` clean on `feature/asset-kit`; usage headroom; Mac kept awake (the app's keep-awake setting plus `caffeinate -ims -t 172800` in the background; stop it when the level ends). Create the worktree(s): `git worktree add .worktrees/<wp> -b wp/<wp> l2-merged`.
2. Launch: `Workflow({scriptPath: ".claude/workflows/assetkit-stage2-level.js", args: {level: "L3", base: "l2-merged", wps: ["c"]}})`. Per WP: author → two independent verifiers (each with its own scratch path) → up to two fix rounds. WP instructions, ADR-050's assignments and the Level 2 lessons are inside the script.
3. **Close-out (expect it):** every level so far ended its three rounds with blocking findings. Write the remaining findings to `.build-orchestrator/<level>-remaining-<wp>.json`, make the rulings, and run fix → two-lens verification cycles until 0 blocking (Level 2 needed five cycles for WP-B). Templates: this repository's session folder `~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/7fbcfa21-90df-4f76-8c7c-0ced89fa87b5/workflows/scripts/assetkit-stage2-l2-close*.js`. When one bug class repeats, demand an exhaustive enumeration (as B-33 did) instead of another probe.
4. Merge `--no-ff`; `verify.sh --quick`, `--gates-only` (rewrites `docs/TRACEABILITY.md`; commit it), release build, iOS `xcodebuild` with `-derivedDataPath .build/xcode`, then on an idle machine `--perf`, whole-package TSan and the coverage export.
5. Documentation: rulings file → three-step docs workflow (ledger readers per draft, one writer, independent verifier) → ADR-0nn, ARCHITECTURE amendments, REENTRANCY rows (draft identifiers become final), §11 assignments; then a close pass for the ADR's "Open" items. Tag `l<n>-merged`, remove worktrees, delete `wp/*` branches.
6. Report to the owner: what was built, gate lines, measured cost, open items; ask for the next level's scope.

## Later levels (same script, change `args`)
L3 `["c"]` on `l2-merged` · L4 `["f"]` · L5 `["g"]` then `["k"]` · then WP-I docs, Stage 3 hardening, Stage 5 final `verify.sh --full` (PROMPT.md §4, ARCHITECTURE §1.2). `docs/VERIFICATION.md` is written at Stage 5 from the drafts' "Not verified" sections (ADR-050 lists them).

## Cost — measured, Opus 5.5 API-equivalent
Summed from the agents' transcript usage (`subagents/workflows/<run>/agent-*.jsonl`, max usage per message), priced at $4 / $20 / $0.20 (cache read) / $5 (cache write) per MTok; script: `python3 cost.py <run dirs>` (re-create from this description if needed).

| Step | Cost |
|---|---|
| Stage 1 (designs, reviews, contracts) | ~$180 |
| Level 1 (H, A, incl. close-out) | ~$190 |
| **Level 2 (B, D, E, full spec)** | **~$419** — main run $170 (27 agents, ~4 h); close-out cycles 1–5 $157 (31 agents, ~7.6 h); follow-up + documentation $62 (13 agents); close pass $18 (4 agents); orchestrator session $12 |

Cache reads are 62–71 % of each run, cache writes 24–30 %, output 4–10 %. Measured on the plan: Level 2 moved the weekly all-models limit from 9 % to 40 % (31 points for ~$419), so a full week holds roughly $1,300 of this workload — the earlier $380–400 estimate was too low. 60 % of the week remained at Level 2's end (reset Thu 15 Oct 2026, 04:00 CEST). Close-out cost nearly as much as the main run: budget ~1× the main run for it.

## Token-saving rules already in the script
Logs go to files and only summary lines are read; large documents are read by section; nothing is re-read unchanged; independent commands are batched. These lower cost without lowering any check.

## Trim candidates (owner decides per level)
Background URLSession (R-NET-3) · legacy migration (R-STO-11 — droppable if the CDN build never shipped; it is the largest part of WP-C) · R-INT-4 deep verification · R-CLN-11 cache purging · crash enumeration beyond single-lifetime scenarios · benchmarks P-7 and P-9 · mutation probes (Q-8) · one verifier instead of two. Cutting a MUST or a budget means marking it deferred in `SPEC.md` with a `DECISIONS.md` entry; never edit `Scripts/`.

## Open questions for the owner
1. **P-13** (ADR-050 · NEEDS-HUMAN-REVIEW): a single APFS `unlink` occasionally stalls ~10 ms, so the per-batch maximum cannot fit 5 ms. Option A (recommended): read the bound as p99 (measured ≈ 1 ms), as P-1/P-9 do. Option B: keep the maximum and raise `batch_ms_max` to 15 ms. Either is the owner's edit of SPEC §6 or `quality-gates.json`; until then `--perf` fails on P-13 only.
2. **NEEDS-HUMAN-REVIEW items of ADR-050:** B-3 the v1 `index.bin` byte layout; D-10 an explicit `shutdown()` cancels in-flight background downloads; the public `BackgroundSessionDriver.startDownload(…resumeData:)` change; D-19.2 the background task tag format the OS persists in `taskDescription`.
3. Has the CDN version of the app shipped to users? (Decides legacy migration, the bulk of WP-C.)
4. Are Apple-hosted asset packs planned soon? (WP-E is built; decides how much device verification to plan.)
5. Outside-repository leftovers from agents (the owner may delete them; agents may not): ~760 `CFNetworkDownload_*.tmp` (~794 MiB), `ResultBundle_*.xcresult` (incl. two `ResultBundle_2026-09-10_*` from Level 2) and Swift macro-expansion dumps in the per-user temp folder; `~/Library/Developer/Xcode/DerivedData/{l2fu-*,ZTronAssetKit-*}`.

## Lessons from Levels 0–2
- Always pass `-derivedDataPath` to `xcodebuild`, and never run `xcodebuild -list` (it writes result bundles to the per-user temp folder even with the flag); never run an unscoped `pkill`; agents stall when the Mac sleeps.
- One scratch path per agent, verifiers included; never the session scratchpad (Level 2: a deleted coverage profile and a replaced mutant script).
- Correctness verifiers find new bugs of one class one probe at a time; after the second, demand an exhaustive enumeration of the state space.
- Benchmarks and TSan only on an otherwise idle machine; three parallel worktrees made storage benchmarks fail by 10–20×.
- Failing test committed on its own before the fix; test-support waits must end on cancellation (use the `require…` forms), or a regression hangs the run instead of failing it.
