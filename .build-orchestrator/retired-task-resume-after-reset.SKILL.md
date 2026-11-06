---
name: ztron-assetkit-resume-after-reset
description: After the Thu 5 Nov weekly reset, resume ZTronAssetKit from docs/ORCHESTRATION.md: finish WP-F if needed, merge, close Stage 3, run Stage 5, then the facade method and the Electron app.
---

You are the orchestrator of the ZTronAssetKit project. Resume it now that the weekly usage limit has reset. The repository is /Users/admin/Documents/ZTronAssetKit, on branch feature/asset-kit. Never push, never force, never touch main. CLAUDE.md's standing orders apply to you and to every agent you start.

The owner's original request was "Finish from Orchestration.md". It explicitly asks for multi-agent orchestration with workflows (ultracode) for this job.

Owner decisions in force:
- **No usage stop.** Never pass usageStop and never invent one. Before each launch, check usage with mcp__ccd_session_mgmt__get_usage.
- **No cap on WP-F cycles.** Keep every close-out agent on Opus: pass no `models` argument.
- **Package.swift:** the owner's uncommitted swift-tools-version edit. Never commit or revert it; commit only explicit paths, never `git add -A` or `-a`.
- **The facade method:** one Opus fixer at medium effort, plus one independent Opus verifier at medium effort.
- **The Electron app** at /Users/admin/Documents/ZTronAssetManager: one Opus agent at medium effort, with no workflow. npm is allowed only there. You then run its build and tests yourself.
- **iOS Simulator tests are required.** Use simulator set 1 (897F9D8D-B10D-4D91-8E22-417A2B9D70AA, 6BE15CAF-7E02-4060-9338-9DAC025EDF0B, 5B940E6E-490F-4E9E-A917-A6456A18225E). Never use the owner's booted iPhone 17.
- **No real uploads or deletions** on AWS or App Store Connect, ever.
- **Network** is limited to Apple developer docs and Swift Evolution, plus npm for the Electron app only.
- **Reporting:** give forecasts in hours and weekly %, and ask the owner as little as possible.

Steps:
1. Read docs/ORCHESTRATION.md: the Stage 3 WP-F section (fix runs 4 and 5, the owner's decision of 31 Oct 23:25, the pending list), "Owner decisions in force", "Lessons", and "Cost — measured" with its 31 Oct correction. Then read only the files those sections name.
2. Pre-flight.
   - Call mcp__ccd_session_mgmt__get_usage; load it with ToolSearch "select:mcp__ccd_session_mgmt__get_usage". If "Weekly · all models" is above 10 %, the reset did not happen or other use consumed it. In that case launch nothing: record the reading in docs/ORCHESTRATION.md, commit, and report.
   - Check `git status`, `git worktree list` and `git -C .worktrees/s3f status`.
   - Make sure no workflow from an earlier session is still running: check the last run's journal.jsonl and look for swift-test, swift-build or xcodebuild processes. Never start a second writer in a worktree.
3. Start `caffeinate -ims -t 259200` with the Bash tool's run_in_background.
4. **If WP-F has not converged** (the last verification had blocking items, or a cycle was cut off by the weekly limit), finish it first.
   - Rule on any fixer put-backs in .build-orchestrator/s3-rulings-s3f.md.
   - Write the last verification's issues to a findings file.
   - Start a new run of .claude/workflows/assetkit-stage3-fix.js from the next cycle. Copy the args from .build-orchestrator/s3-fix-args-run5.json and change fromCycle, maxCycle and findingsFile.
   - Never SendMessage a workflow agent: it starts a duplicate writer. To change a running fixer's brief, stop the run and relaunch that cycle with the ruling in the rulings file.
5. **Once WP-F has converged**, work through ORCHESTRATION's pending list in order:
   - merge wp/s3f --no-ff into feature/asset-kit, with explicit paths;
   - tools-6.4 check (b) in .worktrees/t64;
   - the phase-A gates (verify.sh --quick and --gates-only, release, iOS, coverage, simulator);
   - whole-package TSan and --perf on an idle host;
   - an independent verifier for the P-13 BenchStorage p99 change;
   - an independent mutation re-check of the 11 survivors;
   - ADR-057 via .claude/workflows/assetkit-level-docs.js;
   - tag s3-merged, then remove the s3 worktrees and branches.
6. **Stage 5:**
   - `bash Scripts/verify.sh --full`; quote its last line;
   - VERIFICATION.md (both the 6.0 and 6.4 runs), DEVICE-TEST-PLAN.md, RESIDUAL-RISKS.md;
   - regenerate TRACEABILITY and the README doc-map rows;
   - the final tools-6.4 --full;
   - a final message of at most 60 lines.
7. **Post-stages:** first the facade method that decides at run time whether iOS 26+ is served by AWS or Apple-hosted packs, then the Electron app. Both are as specified in ORCHESTRATION.
8. Throughout:
   - keep docs/ORCHESTRATION.md cold-resumable: record each launch, result and ruling, with times read from `date`;
   - commit with messages ending "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>";
   - report progress to the owner with times and weekly-% forecasts.