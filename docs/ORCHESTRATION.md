# Orchestration state — resume here

Compact hand-off for whoever orchestrates the next step (a fresh Claude Code session in this folder is the cheapest way to resume). Read this file, then only the sections it names; do not re-read the whole repository.

## Owner decisions in force
- **Standalone package.** Nothing outside this repository is ever written. `../ZTronCarouselCore` and `../ZTronCarousel` are read-only prior art. PROMPT.md Stage 4 (adoption in ZTronCarouselCore) is cancelled; R-CAR-6 shims live in `Tests/ZTronAssetCompatibilityTests` (ADR-006, ADR-033).
- **iOS 15.0 minimum** (macOS 12 test floor). Never raise it.
- **Work proceeds level by level; the owner decides each level's scope.** Level 2 = **full specification** (WP-B, WP-D, WP-E), to run after the weekly usage reset (Thu 8 Oct 2026, 04:00 CEST). Later levels may be trimmed (see "Trim candidates").
- The harness is frozen (`git tag harness-frozen`; `Scripts/` never changes; `quality-gates.json` sha256 `2725907c…026f`).

## Where things stand
| Item | State |
|---|---|
| Branch | `feature/asset-kit` (never `main`, never push) |
| Tags | `harness-frozen`, `contracts` (Stage 1), `l1-merged` (WP-H fakes + WP-A Model) |
| Worktrees | `.worktrees/b`, `.worktrees/d`, `.worktrees/e` on `wp/b`, `wp/d`, `wp/e` at `l1-merged`, clean, nothing implemented |
| Paused run | Level 2 workflow `wf_262e4b03-7f6`, paused in the original session after ~27 calls (~$2). It uses the older prompts: **stop it before launching Level 2 anywhere else** (two runs on one worktree conflict) |
| Gates at `l1-merged` | `--quick` PASS; unsafe 0; docs 1270/1270; trace: 35 MUSTs still without tests (all owned by L2–L5) |

## Run Level 2
1. Pre-flight: `git status` clean on `feature/asset-kit`; the three worktrees clean; usage reset; Mac kept awake — the app's keep-awake setting, or else start `caffeinate -ims -t 172800` in the background right before launching (prevents idle and system sleep for 48 h; the display may still sleep; a closed laptop lid still sleeps unless on power with an external display). Sleep stalled agents ~6 h in Level 1.
2. Launch: `Workflow({scriptPath: ".claude/workflows/assetkit-stage2-level.js", args: {level: "L2", base: "l1-merged", wps: ["b", "d", "e"]}})`. Per WP: author → two independent verifiers (requirements/tests and correctness/concurrency) → up to two fix rounds. All WP instructions are inside the script (`WPS` table, `notes`).
3. If any WP ends with blocking findings, run one close-out round (fixer + independent verifier that reproduces the original failures), as was done for Level 1 (`DECISIONS.md` ADR-049 documents the pattern).
4. Merge in order **b, d, e**: `git merge --no-ff wp/<x>`; then `bash Scripts/verify.sh --quick`, `bash Scripts/verify.sh --gates-only` (rewrites `docs/TRACEABILITY.md`), the release build and the iOS `xcodebuild` (always with `-derivedDataPath .build/xcode`).
5. Record the level in `DECISIONS.md` (ADR-050): ratify or veto each author's contract-change requests, fold `docs/adr-drafts/{b,d,e}.md` by reference, number proposed REENTRANCY rows. Commit, `git tag l2-merged`, `git worktree remove --force` the three worktrees, delete the `wp/*` branches.
6. Report to the owner: what was built, gate lines, measured cost (method below), open items; ask for Level 3's scope.

## Later levels (same script, change `args`)
L3 `["c"]` on `l2-merged` · L4 `["f"]` · L5 `["g"]` then `["k"]` · then WP-I docs, Stage 3 hardening, Stage 5 final `verify.sh --full` (see PROMPT.md §4 and ARCHITECTURE §1.2).

## Cost — measured, Opus 5.5 API-equivalent
Summed from the agents' transcript usage (`subagents/workflows/<run>/agent-*.jsonl`, max usage per message), priced at $4 / $20 / $0.20 (cache read) / $5 (cache write) per MTok:

| Step | Cost |
|---|---|
| Stage 1 (designs, reviews, contracts) | ~$180 |
| Level 1 (H, A, incl. close-out) | ~$190 |
| Level 2 (estimate, full spec) | ~$300–450 |

About 85 % of the cost is agents re-reading long context (cache reads ~45 %, cache writes ~40 %); output is ~10 %. One Max 20x week ≈ $380–400 of this workload. Sonnet 5.5 for authors saves only ~25–30 % (cache reads cost the same $0.20).

## Token-saving rules already in the script
Logs go to files and only summary lines are read; large documents are read by section; nothing is re-read unchanged; independent commands are batched. These lower cost without lowering any check.

## Trim candidates (owner decides per level)
Apple-hosted tier (WP-E) · background URLSession (R-NET-3) · legacy migration (R-STO-11 — droppable if the CDN build never shipped) · R-INT-4 deep verification · R-CLN-11 cache purging · crash enumeration beyond single-lifetime sync scenarios · benchmarks P-7 and P-9 · mutation probes (Q-8) · one verifier instead of two. Cutting a MUST or a budget means marking it deferred in `SPEC.md` with a `DECISIONS.md` entry; never edit `Scripts/`.

## Open questions for the owner
1. Has the CDN version of the app shipped to users? (Decides legacy migration.)
2. Are Apple-hosted asset packs planned soon? (Decides WP-E's priority if later levels are trimmed.)
3. Outside-repository leftovers from agents (the owner may delete them; agents may not): ~760 `CFNetworkDownload_*.tmp` (~794 MiB) and a few `ResultBundle_*.xcresult` in the per-user temp folder, Swift macro-expansion dumps there, and a default DerivedData folder for this package.

## Lessons from Levels 0–1
Always pass `-derivedDataPath` to `xcodebuild` (even `-list`); never run an unscoped `pkill`; agents stall when the Mac sleeps (the runtime retries, hours are lost); three verification rounds were not always enough — budget a close-out round per level.
