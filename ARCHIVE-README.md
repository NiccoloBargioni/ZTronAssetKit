# Archive of `.build-orchestrator/` (snapshot 1, 2026-11-06 14:39 CET)

This branch keeps the orchestrator's working files for ZTronAssetKit's Stage 3, so that a later re-open of WP-F (the `ZTronAssetSync` engine) can resume. The owner asked for it on 2026-11-06: "keep all your analysis results and persist what's needed for a later resume".

## Why a branch

`.build-orchestrator/` matches `.gitignore`'s `.build*` pattern. CLAUDE.md also allows `rm -rf` inside `.build*`, so a clean-up could delete the folder. This branch holds a copy in git. It shares no history with `feature/asset-kit`, and it is never merged.

## What it holds

- `.build-orchestrator/`: the whole folder as it was at this snapshot. That includes:
  - the rulings files (`s3-rulings-*.md`; WP-F's is `s3-rulings-s3f.md`);
  - the findings (`s3-findings-*.json`, `s3f-c*-issues.json`) and the fix-workflow arguments (`s3-fix-args-*.json`);
  - the per-cycle analyses (`s3f-c20-analysis/`, `s3f-c21-analysis/`, `s3f-c22-analysis/`, `s3f-design/`);
  - the verifiers' probes (`s3f-probes-c*/`, `s3-probes/`), the mutants (`s3-mutants/`) and the watcher tools (`tools/`).
- `worktree-s3f-logs/.build-s3f/…`: the 78 log files, each under 3 MB, that WP-F's draft (`docs/adr-drafts/s3f.md` on `wp/s3f`) cites under `.build-s3f/c19/` to `c22/`.
  - The draft also cites 24 folders. They are not copied, because they hold build trees.
  - The worktree's other logs stay where they are (`.worktrees/s3f/.build-s3f/`), uncopied.

## How to restore

```bash
git archive archive/build-orchestrator .build-orchestrator | tar -x -C /path/to/ZTronAssetKit
git archive archive/build-orchestrator worktree-s3f-logs | tar -x -C /path/to/scratch
```

The re-open dossier on `feature/asset-kit` says what to read first.
