# Re-open dossier review: `docs/REOPEN-WP-F.md` v1 (independent reader, P4)

Read on 6 Nov at about 15:20. The dossier is untracked (138 lines) on `feature/asset-kit` at `102b880`, `wp/s3f` is at `9aa337c` with a clean worktree, and `archive/build-orchestrator` is at `765102c`. The review was read-only: no build, test, bench or network. Restores ran only into `scratchpad/dossier-check2/`. The worktree commands were checked by reading `git worktree list` and git 2.54's `git-worktree(1)`, not run. Figures here were measured on this host unless marked.

## Verdict: CORRECTED (9 must-fix, each with replacement text)
Nearly every fact, ref and citation holds. The fixes: one slip in N25's scope; three steps a fresh session would follow wrongly (2, 5 and 7); one wrong precedent (step 6); an inconsistency in step 9; the budget's unlabelled figures; and two persistence gaps that the dossier misstates or leaves out.

## Checked and correct
- **Refs:** `9aa337c` = `origin/wp/s3f`, 324 commits after `s3-base` (`b5796ba`, the merge base). `s3f.md` has 10,949 lines, is on no other branch, and has no "Known misses" record yet. `765102c` is an orphan commit of 14:39:14 with 2,807 files (2,728, plus 78 logs, plus the README). 12 tags; `harness-frozen` is `7f24d4c`. `46b2eb1` is an ancestor of `a4c59b7` = `origin/feature/asset-kit`. `wip/s3f-c15a` (`5a87864`) is unmerged; the five `wp/*` were merged `--no-ff` on 30 Oct; the worktrees are as listed.
- **Code at `9aa337c`:** EngineCommands.swift:963, :968, :976; EngineJobs.swift:29, :360, :362, :1217; DeadlineHeap.swift:74-76; EngineRuns.swift:197 (the only interval in `ZTronAssetSync`); AssetClient.swift:323-324; BenchSync.swift:129; BenchSyncCycle22Purge.swift:17, :37, :201-204; BenchSyncReroutes.swift:72. `Sources/ZTronAssetKit` makes no log call. No `PurgeShape` builds the three shapes (`retryJobs` has no user waiter).
- **Rulings and analyses:** rulings:146, :288-290, :722-1276, :756-765, :803-806, :868-871, :1033-1037, :1054-1055, :1065-1066; orchestrator rulings :74-79, :134, :199, :215-240; s3-r28-final.md:139; f3b-review.md:89-92, :137, :141-152; f3b-route-a.md:68, :172, :192; f1c-route-a.md:221; f1c-route-b.md:340; s3f.md:6727-6728, :7584, :7593, :7617; SPEC.md:228; verify.sh:115, :132, :154; PROMPT.md:96; quality-gates.json:62; .gitignore:2; workflow lines :19, :25, :22. (571.12 − 36.24) / 10,000 = 53.5 µs, and × 10,000 = 0.53 s.
- **Words and times:** the quote matches the relayed request word for word; 14:19, 14:23, 14:26, 14:27, 14:37, 14:39 and 14:46 match ORCHESTRATION.md:315-371.
- **Commands, run into the scratch folder:** step 3's restore gives 2,728 files, and `diff -rq` against the live folder finds 4 files only live and 1 that differs (the push line). Step 4's restore gives 78 logs, byte-identical to the worktree's. On a fresh clone of a scratch stand-in for `origin` (built from the local `origin/*` refs), step 1's `branch` command and steps 2 and 3 work. Step 8's `simctl` shows the three devices on iOS 27.0, shut down. `s3-fix-args-run10.json` holds every field step 7 names. Host: Apple M3, Xcode 27.0, Swift 6.4; `.build-s3f/` is 26G by `du`.

## Must fix
1. **Line 22, N25's scope.** N25 says "in cycle 23", and the dossier drops it, which also clashes with step 9. Replace "No code, test or bench is added for them." with "No code, test or bench is added for them in cycle 23 (a re-open adds them: section 6, step 9)."
2. **Step 2.** A fresh session sees `M Package.swift` with no explanation. On a fresh clone, ORCHESTRATION.md is the one at `a4c59b7`: its "Now" bullet is dated 13:35, and it has no N24, N25 or archive (checked on the stand-in clone). Add after the commands:
   > If `git status` shows `M Package.swift`, it is the owner's own edit (tools 6.0 → 6.3; ORCHESTRATION.md:655). Never commit, revert or edit it, and commit only explicit paths, never `git add -A` or `commit -a`. On a fresh clone, ORCHESTRATION.md stops at `a4c59b7` and lacks N24, N25 and the archive: read those in the restored `s3-r28-orchestrator-rulings.md:199-239`.
3. **Step 5, "until then".** Item 1b has no file yet. `s3-r28-item3b.md` (14:46) still gates the three shapes (3b.5), stops on the failed-user shape (3b.6) and names item 3c (3b.7). Replace "S3-R28 and its items 1b and 3b, appended after `rulings:1276` (until then `s3-r28-append.md` and `s3-r28-item3b.md`)" with:
   > S3-R28 and its items 1b and 3b, appended after `rulings:1276`. Until then, S3-R28 is `s3-r28-append.md`. Item 3b is `s3-r28-item3b.md`; its 3b.5-3b.7 gate the three shapes and name item 3c, which N25 withdraws for them. Item 1b has no file at version 1: its inputs are `f1c-route-a.md`, `f1c-route-b.md` and `f1c-review.md` (a stub).
4. **Step 6.** S3-R26 has no `.before-` copy. The two copies belong to S3-R27 and its item 12 (ORCHESTRATION.md:124, :155). `tools/` also reads as a folder at the repo root. Make two replacements:
   - "keeping a `.before-` copy, as S3-R26 and S3-R27 were" becomes "keeping a `.before-` copy, as S3-R27 and its item 12 were (`.before-s3-r27`, `.before-item12`)";
   - "watched by `tools/watch_putback.py <worktree> <since> <journal> <seen>`" becomes "watched by `python3 .build-orchestrator/tools/watch_putback.py <worktree> <since> <journal> <seen>`".
5. **Step 7.** Run 10's focus also names the cycle-23 section to read and continue, `.build-s3f/c23/`, "Cycles 1-22" and `s3f-probes-c22/`. A re-open fixer told to "continue cycle 23" would take cycle 23's committed steps as its own. Runs 8 and 9 were stopped as soon as they started the next cycle's fixer, because a focus describes one cycle (ORCHESTRATION.md:77, :133, :203). Make three changes:
   - Replace "Copy the last arguments:" with "Copy the highest-numbered `s3-fix-args-run<N>.json` (run 10's at version 1):".
   - Replace the `wps[0].focus` item with:
     > `wps[0].focus`: replace every cycle-specific phrase (S3-R28, items 1b and 3b, `9aa337c`, "Cycles 1-22", `s3f-probes-c22/`, the cycle-23 section, `.build-s3f/c23/`) with the re-open's ruling, HEAD and cycle. Keep its standing rules: `sim.lock`, S3-R23's loads, "never edit Package.swift", and keeping `.build-s3f/c21/` and `c22/`. Stop the run once it starts the next cycle's fixer, and relaunch it with that cycle's focus.
   - Append to "Keep `base` (`s3-base`)": "while `wp/s3f` is unmerged; section 7 names the base after the merge".
6. **Step 9.** It measures "on a scratch copy of the base" but runs both commands "from the worktree root". `--perf` also fails today on P-13, which belongs to WP-B. The quiet-load rule is shortened. Make two replacements:
   - Replace "The second command, one case, runs from the worktree root, in the form cycle 21 used (`s3f.md:6727-6728`)." with:
     > Run both commands in the copy being measured, with its own `Scripts/verify.sh`; use the worktree's only while the worktree is still at the base. The second runs one test function with all its arguments, in the form of cycle 21's re-run alone (`s3f.md:6727-6728`, which added `--skip-build`). `--perf` also fails today on P-13, which is WP-B's and is reported as such (ORCHESTRATION.md:51, :194; `rulings:1063`).
   - Replace "A miss seen only above 10 is \"not measured at a quiet load\"." with:
     > A miss seen only at loads above 10 is re-run alone, at the lowest load that can be had (S3-R23 item 2, `rulings:297`). If no run reaches a load of 10 or less, the case is "not measured at a quiet load": it is neither confirmed nor blocking until the orchestrator measures it at a quiet load (`rulings:763`, `:301`).
7. **Step 10's figures have no label and no line,** although the header promises a label for every figure. Replace the step with:
   > **Budget** (ORCHESTRATION.md; wall times are measured from its timestamps, and points are read off the shared weekly meter, which includes the owner's other use). Cycle 21's fixer took 14 h 34 min (:28) plus 8 h 58 min (:49). Its verifiers took about 2 h 20 min (17:54 to 20:14, :49 and :133; derived), and the cycle cost about 30-38 points in all (:88; derived across the early reset of 5 Nov). Cycle 22's fixer took about 9.4 h (:183) and its verifiers about 1.3 h (08:44 to 10:03, :203; derived), with the meter at 42 → 51 % (:173, :213; measured). Check the meter right before the launch, and forecast in hours and weekly %.
8. **Lines 82-83, section 5's caveats, are wrong or incomplete.**
   - By a regex over `s3f.md` with its globs expanded, the draft cites 80 files under `c19/` to `c22/`. 78 are archived. The two that are not are `c20/gates/cov.profdata` (4.2 MB) and `c21/gates-b/cov.profdata` (4.7 MB).
   - Only 13 of the 24 cited folders are package copies or folders of 39-932 MB.
   - Snapshot 1 also lacks `s3-r28-append-v1.md` and `s3-r28-append-review.md`.

   Replace "except the 78 cited logs. The 24 cited folders hold build trees and are not copied (`ARCHIVE-README.md`)." with:
   > except 78 of the 80 files that `s3f.md` cites under `c19/` to `c22/`. The two `cov.profdata` files in `c20/gates/` and `c21/gates-b/`, each over 3 MB, are not archived. Of the 24 cited folders, 13 are package copies or build output. From the other 11, only their cited files are archived: `c19/final`, `c19/mut`, `c21/each`, `c21/gates`, `c21/pending`, `c21/red-c3`, `c21/red-holes`, `c22/mut`, `c22/mut-e2a`, `c22/rerun` and `c22/tools` (555 files, about 23 MB, none over 3 MB).

   In line 83, replace "`s3-r28-append.md`," with "`s3-r28-append.md` with its `-v1` and `-review` files,".
9. **Line 135, the final snapshot,** leaves out the logs that a re-open of cycle 23 or later would cite. Append:
   > It also holds the files that `s3f.md` cites under `.build-s3f/c23/` and later cycles, each under 3 MB as in snapshot 1, and the cited folders that hold no build tree (section 5's eleven and those added later), so that step 4's restore brings them back.

## Should fix
- **Step 3:** give the command for when the folder exists: `mkdir -p <scratch> && git -C /Users/admin/Documents/ZTronAssetKit archive archive/build-orchestrator .build-orchestrator | tar -x -C <scratch> && diff -rq <scratch>/.build-orchestrator /Users/admin/Documents/ZTronAssetKit/.build-orchestrator`.
- **Step 1:** "steps 1, 3 and 4 were run on a local clone" seems to contradict "This clone was not run". Write "step 1's `branch` command and steps 3 and 4".
- **Line 75:** f1c-route-b's 31-47 h includes its step 0 (5-7 h, f1c-route-b.md:331). Route A's 40-62 h does not include its step 0.
- **Line 134:** the `wp` key is at `assetkit-closeout.js:11`, but `base` is at :13.
- **Line 136:** 37.21-45.85 ms is the figure of PROBE-C21-HOLDERS (correct #5, reqs #6), which is one shape of that class.

## For the orchestrator
- **Commit the dossier.** It is untracked (`?? docs/REOPEN-WP-F.md`). Commit it by its explicit path, never with `git add -A`, because of `Package.swift`.
- **The fresh-machine resume needs a push.** `feature/asset-kit` must be pushed past `a4c59b7`: the stand-in clone has no dossier and no "N25" in ORCHESTRATION.md. The push needs the owner's word (CLAUDE.md). The owner's words at 14:19, 14:27 and 14:46 covered only the refs they named.
- **Persistence.** Three things stay unarchived:
  - the 11 small cited folders (about 23 MB), the append and item-3b files, and the push line, which a snapshot 2 taken now could add;
  - the 40 files and 15 folders that the draft cites for cycles 12-18;
  - the correction to ARCHIVE-README.md, which repeats the claim that all 24 cited folders hold build trees.

  Pushing a new snapshot needs the owner's word.
- **Apply N25 before the append.** In `s3-r28-item3b.md`, 3b.5-3b.7 still gate the three shapes and name item 3c. `s3-r28-append.md` still has item 3b gate f3b-route-a §9's shapes. N25 says item 3b states N25 in place of its open-shapes part.
- **Fix ORCHESTRATION.md.** Line 373 cites `Scripts/verify.sh:153` for the Benchmarks step, which is at :154. The post-convergence lists (:407, :599) still say "remove the s3 worktrees and branches", without N25's condition.

## Not verified
- GitHub itself, since there was no network: the pushes were checked only against the local `origin/*` refs and ORCHESTRATION.md.
- `git worktree prune` and `add`, which were not run, by the task's rule.
- Step 9's commands, and any bench, build or test.
