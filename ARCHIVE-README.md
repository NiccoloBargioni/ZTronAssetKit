# Archive of `.build-orchestrator/` (snapshot 4, 2026-11-07 04:40 CET)

## Snapshot 4: what changed since snapshot 3

The tree starts from snapshot 3's tree (`2d87b7c`), so every file that snapshot 3 held is still here. It adds:

- **`.build-orchestrator/`**, refreshed. It now includes:
  - the close ruling's appendix in `s3-rulings-s3f.md`;
  - notes N31-N33;
  - `s3f-c23-issues.json`;
  - the post-merge folder `s3-post-merge/`:
    - P-13's independent verification `p13-verify-wf_19408ffa-9ba.json`, with its items in `docs-followup-items.md`;
    - the mutation re-check `mut-recheck/`;
    - the ADR-057 docs workflow's output and journal.
- **`worktree-<wp>-logs/.build-<wp>/…`**: every file, each up to 3 MB, that is cited under `.build-<wp>/` by the final Stage 3 drafts (`docs/adr-drafts/s3*.md` at `45df2e1`), or by a `.worktrees/s3*/…` path in `docs/ORCHESTRATION.md`, `docs/DECISIONS.md` or `.build-orchestrator/**/*.md`. This adds WP-F's cycle 23 evidence (runs 13 and 14) and the s3c, s3d and s3g citations.
- **`build-orch-logs/`**: the post-merge evidence from the main checkout's `.build-orch/`:
  - the merged head's `--full` (`merge-full.log`), with its `.verify-logs` copied as `merge-verify-logs-e840b0e/`;
  - the quiet re-runs (`merge-userToBound-rerun1.log`, `merge-P13-quiet.log`);
  - the tools-6.4 check (b) (`t64b/`);
  - the simulator run (`sim-merged/`, without the 35 MB xcresult bundle; its summary is `sim-summary.json`);
  - the mutation re-check logs (`mut-recheck/`);
  - Stage 5's `--full` log as far as it had run (`stage5-full.log`; the run was still going).

The state these files belong to: WP-F is merged into `feature/asset-kit` (`e840b0e`), ADR-057 is merged (`45df2e1`), and the post-merge checks are done (`docs/ORCHESTRATION.md`, the checklist under 6 Nov). The re-open dossier is `docs/REOPEN-WP-F.md` on `feature/asset-kit`.

The rest of this README is snapshot 3's text. It is still true of the files it describes.


This branch keeps the orchestrator's working files for ZTronAssetKit's Stage 3, so that a later re-open of WP-F (the `ZTronAssetSync` engine) can resume. The owner asked for it on 2026-11-06: "keep all your analysis results and persist what's needed for a later resume".

## Why a branch

`.build-orchestrator/` matches `.gitignore`'s `.build*` pattern. CLAUDE.md also allows `rm -rf` inside `.build*`, so a clean-up could delete the folder. This branch holds a copy in git. It shares no history with `feature/asset-kit`, and it is never merged.

## What it holds

- `.build-orchestrator/`: the whole folder as it was at this snapshot. That includes:
  - the rulings files (`s3-rulings-*.md`; WP-F's is `s3-rulings-s3f.md`);
  - the findings (`s3-findings-*.json`, `s3f-c*-issues.json`) and the fix-workflow arguments (`s3-fix-args-*.json`);
  - the per-cycle analyses (`s3f-c20-analysis/`, `s3f-c21-analysis/`, `s3f-c22-analysis/`, `s3f-design/`);
  - the verifiers' probes (`s3f-probes-c*/`, `s3-probes/`), the mutants (`s3-mutants/`) and the watcher tools (`tools/`).
- `worktree-s3f-logs/.build-s3f/…`: the 283 files, each under 3 MB, that WP-F's draft (`docs/adr-drafts/s3f.md` on `wp/s3f`, at `9e9a500`) cites under `.build-s3f/`, by name or by a pattern such as `c21/mut-*.log`. They are logs, scripts and tables from cycles 10 to 23.
  - Not copied: the 76 folders the draft cites, which hold package copies, build trees, or test output such as `.xcresult` bundles; and three coverage `.profdata` files over 3 MB. Seven cited names match no file.
  - The worktree's other files stay where they are (`.worktrees/s3f/.build-s3f/`), uncopied.

## Snapshots

- Snapshot 1 (14:39, `765102c`), pushed at 14:46 with the owner's word.
- Snapshot 2 (15:55, `5ba3601`): S3-R28 as appended, item 1c and its amendment, rulings N24 to N29.
- Snapshot 3 (this one): the end-sooner options as revised, item 3b's finished text, f3c with its review, N30 and N31 (the owner's close ruling, option (e)), the draft's full set of cited logs. Pushed with the owner's standing word of 16:40 ("Archive and feature branch").

## How to restore

```bash
git archive archive/build-orchestrator .build-orchestrator | tar -x -C /path/to/ZTronAssetKit
git archive archive/build-orchestrator worktree-s3f-logs | tar -x -C /path/to/scratch
```

The re-open dossier on `feature/asset-kit` says what to read first.
