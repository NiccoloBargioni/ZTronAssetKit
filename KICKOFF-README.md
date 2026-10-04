# ZTronAssetKit kickoff kit — how to run it (for you, not for Claude)

## What's here
| File | Purpose |
|---|---|
| `PROMPT.md` | The launch prompt: mission, stage plan, ownership, completion condition for `/goal`. |
| `SPEC.md` | 90 requirements, 14 performance budgets, quality gates, prior-art defects. Parallel agents read this from disk. |
| `CLAUDE.md` | Standing rules (immutable gates, honesty, strict concurrency, parallel-agent rules). Survives context compaction. |
| `Scripts/verify.sh`, `gates.py`, `quality-gates.json` | The Definition of Done as code. Thresholds and budgets are hash-pinned; the goal condition quotes the hash. |

## Run it
```sh
mkdir ZTronAssetKit && cd ZTronAssetKit          # next to ZTronCarouselCore and ZTronCarousel
unzip ../ztron-assetkit-kickoff.zip              # kit lands in the repo root
git init                                         # (Stage 0 will also do this if you forget)
claude --effort ultracode --add-dir ../ZTronCarouselCore ../ZTronCarousel
```
1. In the session: `Read PROMPT.md and execute it. Stop after the Stage 0 summary.`
2. Read the Stage 0 summary and `docs/RECON.md`. Confirm the baseline test count (~128 CDN tests) and the confirmed defects.
3. Paste the `/goal …` block from **PROMPT.md §9**. The agent then runs Stages 1–5 until `bash Scripts/verify.sh --full` prints `VERIFY: PASS`, or stops and tells you what it needs.

## Prerequisites and cautions
- **Claude Code ≥ 2.1.203** for `--effort ultracode`, and a model that supports `xhigh` (if *Ultracode* is missing from `/effort`, check `/model`). Run **interactively** — the `ultracode` keyword does not start workflows from `claude -p` prompts.
- **Permissions.** Workflow subagents obey your permission rules and the run pauses on every prompt. Pre-allow `swift`, `xcodebuild`, `xcrun`, `git`, `python3`, `bash Scripts/*` in your allow rules, or run the goal in auto mode. Unattended + auto means the agent runs many commands without asking: **commit or stash everything in the sibling repos first**; Stage 4 works only on a new branch there and never pushes.
- **Cost.** Ultracode with parallel fan-out uses far more tokens than a normal session and counts against plan limits. Watch `/workflows`; `/config workflowSizeGuideline=medium` bounds fan-out. Stages 0–1 are cheap and tell you whether the plan is sound before the expensive Stage 2.
- **Device-only behaviour cannot be verified by this run** (background URLSession re-attachment, real Apple-hosted packs through TestFlight, low-storage purges). The agent produces `docs/DEVICE-TEST-PLAN.md` for you to execute.

## Decisions baked in — flip them in `SPEC.md` *before* running if you disagree
- **Storage default:** `Application Support` excluded from backup, with module-owned eviction (not `Caches`). §4.4.
- **On-disk layout:** content-addressed blobs + one atomic index (a directory change becomes an index edit, not file moves). §4.3.
- **Platform floor:** iOS 15 (matches ZTronCarouselCore); Apple-hosted tier iOS 26+. §3.
- **Coverage:** 80 % overall, 70 % per target, 90 % for Storage and Sync — edit `quality-gates.json` *and* the hash in the goal condition together, before Stage 0.
- **Stage 4** (adopting the module in ZTronCarouselCore) is included; tell the agent to skip it if you want to review the module first.

## What in this kit is verified, and what isn't
- `gates.py` (coverage / trace / unsafe / docs) — self-tested, and the self-test was itself mutation-tested (every injected defect caught). It has only seen *synthetic* coverage JSON, not real SwiftPM output.
- `verify.sh` control flow — tested against a fake toolchain: pass, coverage failure, old toolchain, failing tests, quick mode, tampered harness. **The actual `swift` / `xcodebuild` flags were never run** (no Swift toolchain where this was written). Stage 0 step 6 exists to fix them on your machine before the harness is frozen.
- `SPEC.md` — internally consistent (IDs parsed, no dangling references, budgets match the JSON). The Swift/Apple API statements marked *(hint)* are unverified and flagged as such for the agent.
