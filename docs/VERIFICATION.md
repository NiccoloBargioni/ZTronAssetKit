# Verification (Stage 5)

What ran, against which thresholds, with what result, and what no run could prove (`PROMPT.md:65`; SPEC §8,
`SPEC.md:351`).

- **Verdict.** The final `bash Scripts/verify.sh --full`, on `45df2e1`, printed **`VERIFY: FAIL (1 failed:
  benchmarks)`** (`full5:129`). Every other step passed. The benchmarks step's 7 issues are the six R-CLN-6 purge
  shapes and P-13, the only causes of a FAIL the owner accepted as WP-F's end state (ADR-057 close point 3,
  `DECISIONS.md:633`, `:659`), so the run ends in the accepted end state (§4.4). The /goal's Done is **not met**:
  `PROMPT.md:96` asks for `VERIFY: PASS` with passing benchmarks, and the owner set that aside for WP-F
  (`DECISIONS.md:633`).
- **How this file was made.** Written on 10 Nov 2026 on `wp/s5docs` from the logs and records of 6-7 Nov. Nothing was
  built, tested or re-run for it. Every figure cites the line it comes from (G2); §5 lists what no run proved.

## 0. Conventions

| Short name | Path, under the main checkout `/Users/admin/Documents/ZTronAssetKit` (git-ignored, `.gitignore:2`, `:7`) |
|---|---|
| `full5` | `.build-orch/stage5-full.log`: Stage 5's `--full` transcript |
| `s5/` | `.build-orch/stage5-verify-logs-45df2e1/`: that run's `.verify-logs/`, copied after it (ORCH:614). At this writing all 16 of its files have the same SHA-256 as those in `.worktrees/merge-check/.verify-logs/`, the path `docs/RESIDUAL-RISKS.md` cites |
| `fullM`, `m/` | `.build-orch/merge-full.log` and `.build-orch/merge-verify-logs-e840b0e/`: the `--full` on the merged head `e840b0e` (ORCH:580) |
| `u2b`, `p13q` | `.build-orch/merge-userToBound-rerun1.log`, `.build-orch/merge-P13-quiet.log` |
| `t64b/`, `t64c/` | `.build-orch/t64b/`, `.build-orch/t64c/`: the tools-6.4 checks (b) and (c) |
| `sim/`, `mut/` | `.build-orch/sim-merged/` (the iOS Simulator suite), `.build-orch/mut-recheck/` (the mutation re-check) |
| `pm/` | `.build-orchestrator/s3-post-merge/` |
| `ORCH` | `docs/ORCHESTRATION.md` on `feature/asset-kit` at `0f909f2`, read with `git show 0f909f2:docs/ORCHESTRATION.md`; this branch's copy is older and its line numbers differ |

- `DECISIONS.md`, `quality-gates.json`, `verify.sh` and `gates.py` mean `docs/` and `Scripts/` at this branch's head;
  `Scripts/` is unchanged since the tag `harness-frozen` (`7f24d4c`; `full5:9`).
- **Load** is the 1-minute load average as a log prints it. **The load rule** (`DECISIONS.md:633`, `:659`, citing
  rulings :763): a C2 miss is a best of 3 above `c2Budget` at a load of 10 or less; a figure seen only above 10 is
  recorded with its loads and re-run alone. "Quiet" below means a load of 10 or less.

## 1. Scope

| | |
|---|---|
| Head verified | `45df2e1` "Merge the Stage 3 merge documentation (ADR-057)" (`full5:3`): `feature/asset-kit` after the Stage 3 merge `e840b0e` (WP-F, 6 Nov 22:32) and ADR-057; tag `s3-merged` (ORCH:578) |
| Code under test | The merged head's. Between `e840b0e` and `45df2e1`, `Tests/`, `Scripts/` and `Package.swift` are unchanged and every changed line in `Sources/` (18 files) is a `///` line (`git diff e840b0e 45df2e1`, checked for this file) |
| When | 7 Nov 2026, 04:38:29-06:02:55 CET (`full5:1`, `:132`); load 4.11 at the start, 7.77 at the end (`full5:2`, `:131`) |
| Where | `.worktrees/merge-check`, a clean worktree detached at `45df2e1`, with the committed manifest `// swift-tools-version: 6.0` (ORCH:579). The owner's uncommitted `Package.swift` edit in the main checkout was left alone: the owner answered "Yes, clean worktree" (ORCH:585) |
| Host | Apple-silicon Mac, macOS 27: `Target: arm64-apple-macosx27.0.0` (`s5/toolchain.log:2`); F's result bundle says "Built with macOS 27.0" (`sim/sim-summary.json:23`). No Stage 5 log prints the CPU model or the Xcode version; the records give Apple M3 (8 cores, 24 GB) and Xcode 27.0 (27A266a) (`docs/BASELINE.md:19`; `docs/APPLE-API-VERIFICATION.md:3`, `:8`, recorded 2026-10-04) |
| Toolchain | `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`, swift-driver 1.168.6 (`full5:12`) |
| Later commits | Documentation only. `git log 45df2e1..HEAD` in the main checkout (`feature/asset-kit` at `0f909f2`) lists 9 commits, each changing only `docs/ORCHESTRATION.md`: `accfd99`, `d002758`, `18b3e15`, `5827a2e`, `f6842e0`, `2bec927`, `253b398`, `8f77d29`, `0f909f2` (7-10 Nov). This branch, `wp/s5docs` from `d002758`, adds `docs/MUTATION-PROBES.md`, `docs/DEVICE-TEST-PLAN.md`, `docs/RESIDUAL-RISKS.md` and this file. Neither branch changes `Sources/`, `Tests/`, `Scripts/` or `Package.swift` after `45df2e1` |

## 2. What ran

### 2.1 `verify.sh --full` on `45df2e1`

The steps run in this order (`verify.sh:141-157`). Each step's whole output goes to `.verify-logs/<step>.log`; the
transcript keeps a filtered summary, or the last 40 lines of a failing step (`verify.sh:37-50`). `$SCRATCH` is
`$SWIFTPM_SCRATCH`, default `.build` (`verify.sh:22`).

| # | Step | Command (`verify.sh` line) | Log |
|---|---|---|---|
| 1 | gates-selftest | `python3 Scripts/gates.py selftest` (:84) | `s5/gates-selftest.log` |
| 2 | harness | SHA-256 of `Scripts/quality-gates.json`; `git diff --quiet harness-frozen -- Scripts/` and an empty `git status --porcelain -- Scripts/` (:69-82) | `s5/harness.log` |
| 3 | toolchain | `swift --version` against `swift.min_toolchain` (:53-67) | `s5/toolchain.log` |
| 4 | build-debug | `swift build --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors` (:85) | `s5/build-debug.log` |
| 5 | build-release | `swift build -c release --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors` (:86) | `s5/build-release.log` |
| 6 | build-ios | `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/xcode" build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` (:87-91) | `s5/build-ios.log` |
| 7-9 | tests-run-1-of-3 to 3-of-3 | `swift test --scratch-path "$SCRATCH" --enable-code-coverage --skip Benchmarks`, `tests.full_run_repeats` times (:92, :148-151) | `s5/tests-run-<i>-of-3.log` |
| 10 | coverage | `xcrun llvm-cov export -summary-only` of the merged profile over every `.xctest` bundle, then `python3 Scripts/gates.py coverage --json … --config Scripts/quality-gates.json` (:93-113) | `s5/coverage.log`, `s5/coverage-export.json` |
| 11 | tsan | `swift test --scratch-path "$SCRATCH-tsan" --sanitize=thread --skip Benchmarks`, when `tests.tsan` is true (:114, :153) | `s5/tsan.log` |
| 12 | benchmarks | `swift test -c release --scratch-path "$SCRATCH-perf" -Xswiftc -enable-testing --filter Benchmarks` (:115) | `s5/benchmarks.log` |
| 13 | trace | `python3 Scripts/gates.py trace --spec SPEC.md --tests "$ROOT/Tests" --config … --write docs/TRACEABILITY.md` (:118) | `s5/trace.log` |
| 14 | unsafe | `python3 Scripts/gates.py unsafe --sources "$ROOT/Sources" --audit docs/UNSAFE-AUDIT.md --config …` (:119) | `s5/unsafe.log` |
| 15 | docs | `python3 Scripts/gates.py docs --sources "$ROOT/Sources" --config …` (:120) | `s5/docs.log` |

### 2.2 The other runs

| Run | When (CET) and where | What ran | Records |
|---|---|---|---|
| A. `--full` on the merged head | 6-7 Nov, started about 22:42 (ORCH:517); `.worktrees/merge-check` at `e840b0e`, scratch `.build-orch-merge` (ORCH:516) | `bash Scripts/verify.sh --full` | `fullM`, `m/`; ORCH:503-511 |
| B. `userToBound` alone (the load-only re-run) | 7 Nov 00:08:28-00:08:57 (`u2b:1`, `:20`), on `e840b0e`, after A (`DECISIONS.md:593`; ORCH:507-508) | the `--perf` command with `--filter userMovedToBound` (ORCH:508) | `u2b` |
| C. tools-6.4 check (b) | 7 Nov 00:10:27-00:23:12 (`t64b/started.txt:1`, `t64b/status.txt:6`); `.worktrees/t64` detached at `e840b0e` (`t64b/head.txt:1`) with only line 1 of `Package.swift` set to `// swift-tools-version: 6.4` (`t64b/manifest-line.txt:1`, `t64b/git-status.txt:1`), never committed (ORCH:512) | `bash Scripts/verify.sh --quick`, the release build, the iOS generic build, and a grep for `warning:` over every log (ORCH:513-515) | `t64b/` |
| D. P-13 alone, three runs | 7 Nov 00:23:35-00:23:48 (`p13q:1`, `:54`); `.worktrees/merge-check` at `e840b0e`, scratch `.build-orch-merge-perf` (`DECISIONS.md:674`) | the `--perf` command filtered to `StorageBenchmarks/reclaim()` (`DECISIONS.md:674`) | `p13q`; ORCH:525-529 |
| E. P-13's independent verifier | 7 Nov 00:24-00:45 (`DECISIONS.md:574`); workflow `wf_19408ffa-9ba`, read-only | three lenses: ruling fidelity, measurement soundness, an adversarial refuter (ORCH:530) | `pm/p13-verify-wf_19408ffa-9ba.json`; `pm/docs-followup-items.md` (items P1-P8) |
| F. iOS Simulator suite | 7 Nov 00:24:11-00:36:26 (`sim/status.txt:1`), on `e840b0e` (`sim/head.txt:1`); simulator `897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, iPhone 18 Pro, iOS 27.0 (24A434) (`sim/sim-summary.json:6-10`), under `sim.lock` (`sim/lock.txt:1-2`) | `xcodebuild test` with `-skip-testing:ZTronAssetKitBenchmarks` (`sim/sim.log:1-2`; §6.4) | `sim/`; ORCH:517-522 |
| G. Mutation re-check of discovery's 11 survivors | 7 Nov, launched 00:36, done 01:26 (ORCH:541, :555); `.worktrees/merge-check` at `e840b0e`, scratch `.build-orch-merge` (ORCH:556) | each survivor's diff applied alone, that target's tests run the way `run_tests` runs them, the file restored with `git checkout -- <file>` (ORCH:556-558) | `mut/`; `pm/mut-recheck/first-issues.txt`; ORCH:540-559 |
| H. Stage 5's `--full` | §1, §2.1 | | `full5`, `s5/` |
| I. tools-6.4 check (c) | 7 Nov 06:03:38-07:33:20 (`t64c/started.txt:1`, `t64c/status.txt:5`); `.worktrees/t64` at `45df2e1` (`t64c/head.txt:1`), line 1 at 6.4 (`t64c/manifest-line.txt:1`) | `bash Scripts/verify.sh --full`, then the `warning:` grep (ORCH:615-616) | `t64c/` |

TSan ran inside A, H and I (step 11). No separate `--perf` run was made: the `--full`s' benchmarks steps and runs B
and D stand in for it (`DECISIONS.md:674`).

## 3. Thresholds

### 3.1 Gates

| Gate (SPEC §7.1, `SPEC.md:319-328`) | Key in `quality-gates.json` (line) | Threshold | Measured on `45df2e1` | Record |
|---|---|---|---|---|
| Q-9 harness integrity | the file's SHA-256, against `PROMPT.md:96` | `2725907cf8ef6ea610bd0b3436c4d670a29d97f84c4954eac94d7dcc9b4f026f`; `Scripts/` unchanged since `harness-frozen` | the same hash; `HARNESS: unchanged since harness-frozen` | `s5/harness.log:1-2` |
| Toolchain | `swift.min_toolchain` (:4) | 6.3 | 6.4 | `s5/toolchain.log:1`, `:3` |
| Q-1 build | none: `-warnings-as-errors` is passed on the command line (`verify.sh:85-90`) | 0 warnings, debug and release; compiles for `generic/platform=iOS` | all three built; 0 `warning:` lines in `full5` and in `s5/` (counted for this file) | `full5:15-22` |
| Q-2 coverage, overall | `coverage.overall_min_lines_pct` (:7) | 80.0 % | 96.93 % | `s5/coverage.log:8` |
| Q-2 coverage, every other target | `coverage.per_target_min_lines_pct` (:8) | 70.0 % | 97.99 % at the lowest (Kit) | `s5/coverage.log:2-4`, `:7` |
| Q-2 coverage, critical targets | `coverage.critical_targets` (:9-12), `coverage.critical_min_lines_pct` (:13) | Storage and Sync 90.0 % | 97.52 %, 95.11 % | `s5/coverage.log:5-6` |
| Q-2 targets present | `coverage.expected_targets` (:14-21) | 6 targets, a missing one fails (`gates.py:70`) | all 6 | `s5/coverage.log:2-7` |
| Q-2 exclusions | `coverage.exclude_path_regexes` (:22-28) | `/Tests/`, `/\.build`, `/checkouts/`, `/DerivedData/`, `/ZTronAssetTestSupport/` | applied (`gates.py:54-55`) | |
| Q-2 device-only share | `coverage.device_only_path_regexes` (:29-32), `coverage.device_only_max_lines_fraction` (:33) | `BackgroundSessionBackend.swift` and `LiveAssetPackBackend.swift`, at most 3 % of all lines (`gates.py:91`) | 177 lines, 0.58 % | `s5/coverage.log:9` |
| Q-5 stability | `tests.full_run_repeats` (:36) | 3 consecutive passing runs | 3 of 3 | `full5:23-52` |
| Q-3 Swift 6 mode | none: the manifest sets it, and no gate checks it | Swift 6 language mode (`SPEC.md:321`) | met by the committed manifest, unchanged since `45df2e1`: `Package.swift:94` (`swiftLanguageModes: [.v6]`) and `:10` (`StrictConcurrency=complete`); built in the debug, release and iOS steps | `full5:15-22` |
| Q-3 Thread Sanitizer | `tests.tsan` (:37) | the step runs and passes | passed | `full5:64-73` |
| Q-3 unsafe (C1) | `unsafe.max_escapes` (:40), `unsafe.patterns` (:41-51, 9 patterns) | at most 3, each marked and audited | 0 | `s5/unsafe.log:1-2` |
| Q-7 documentation | `docs.min_documented_public_fraction` (:54), `docs.max_exempt` (:55) | 100 %, at most 10 exempt | 1281 of 1281, 0 exempt | `s5/docs.log:1-2` |
| Q-6 traceability | `trace.require_all_must` (:58), `trace.require_all_budgets` (:59) | every MUST and every budget has a test whose display name carries its ID (`gates.py:107`, `:111`, `:121`); `SPEC.md:324` asks that the name start with it; no unknown ID | 90 requirements (78 MUST), 14 budgets, 1661 ID citations in test names (`tests-with-ids`, `gates.py:131`). The stronger form also holds: each of the 78 MUSTs and 14 budgets has a test whose display name starts with its ID (checked for this file with the gate's regexes over `Tests/` at `45df2e1`; the per-ID counts match `docs/TRACEABILITY.md`) | `s5/trace.log:1-2` |
| Q-4 determinism, Q-8 mutation, Q-10 compatibility | none: `gates.py` has only the `coverage`, `trace`, `unsafe`, `docs` and `selftest` subcommands (`gates.py:331-335`) | | Q-8 §4.6 (G); Q-4 and Q-10 §5.3 | |

### 3.2 Budgets (SPEC §6, `SPEC.md:290-311`; `quality-gates.json` → `budgets`, :61-121)

Reference: an Apple-silicon Mac, release, N = 10,000 unless stated (`quality-gates.json:62`). Measured by Stage 5's
benchmarks step; every line number is in `s5/benchmarks.log`.

| ID | Keys (line) and thresholds | Measured | Result |
|---|---|---|---|
| P-1 | `lookup_p99_us` (:64) 25 µs; `scale_ratio_max` (:65) 3.0 | p99 0.417 µs at 10,000 (0.375 µs at 100); ratio 1.112 (:57) | pass (:58) |
| P-2 | `index_load_ms` (:68) 25 ms | p50 8.96 ms, max 9.06 ms (:119) | pass (:120) |
| P-3 | `manifest_decode_validate_ms` (:71) 80 ms | the 3,283,455-byte reference: p50 18.11 ms, max 19.23 ms (:86). 26 fuzzed cases at up to 32 MiB: worst 326.71 ms (:112) against 817.54 ms (:89-114; §3.3) | pass (:87, :115) |
| P-4 | `plan_ms` (:74) 20 ms; `doubling_ratio_max` (:75) 2.5 | 11.38 ms; 20,000 against 10,000: 2.09 (:164) | pass (:165) |
| P-5 | `index_commit_ms` (:78) 40 ms; `commits_per_s_max` (:79) 4 | ordered p50 13.43 ms, max 15.69 ms; durable p50 20.86 ms, max 22.89 ms; 40 commits in 10 s, at most 4 in any second (:122) | pass (:123) |
| P-6 | `hash_mb_per_s_min` (:82) 800; `vs_oneshot_min_ratio` (:83) 0.7; `memory_delta_mib_max` (:84) 4 | 2,377.96 MB/s; ratio 0.816; peak resident delta 0.0 MiB (:125) | pass (:126) |
| P-7 | `sync_memory_delta_mib_max` (:87) 48 MiB; `catalog_gib` (:88) 1 | 0.84 MiB for 256 MiB, 0.14 MiB for 1,024 MiB (:170) | pass (:171) |
| P-8 | `main_thread_fs_calls_max` (:91) 0; `ui_call_ms_max` (:92) 1.0 ms | 0 main-thread file-system calls; highest p99 0.024 ms (window update), highest max 0.076 ms (events) (:60-68); prefetch window medians 0.0066 and 0.0063 ms (:74-75) | pass (:69, :72, :76) |
| P-9 | `heartbeat_tick_ms` (:95) 10; `heartbeat_gap_ms_p99_max` (:96) 50 ms; `concurrent_resolves` (:97) 64 | heartbeat gap p99 15.13 ms with 64 resolves (:78) | pass (:79) |
| P-10 | `assets` (:100) 500; `connections_max` (:101) 8 | 8 TCP connections for 500 requests (:463) | pass (:464) |
| P-11 | `assets` (:104) 200; `server_latency_ms` (:105) 10; `concurrency` (:106) 5; `speedup_min` (:107) 3.0 | speed-up 3.46 (:173) | pass (:174) |
| P-12 | `init_ms_max` (:110) 1.0 ms | p99 0.0051 ms over fakes, 0.0052 ms over `.live()`; 0 file-system calls (:81) | pass (:82) |
| P-13 | `blobs` (:113) 10,000; `gc_total_s_max` (:114) 2.0 s; `batch_ms_max` (:115) 5 ms | total 0.588 s; 525 units, unit p99 5.836 ms, max 10.72 ms (:128) | **fail** on the p99 (:129-134); the total passed. The scaling test passed (:136-137) |
| P-14 | `idle_timers_max` (:118) 0; `idle_tasks_max` (:119) 0 | 0 armed timers, 0 owned tasks (:167) | pass (:168) |

### 3.3 Thresholds outside `quality-gates.json`

| Threshold | Value | Source | Used by |
|---|---|---|---|
| C2, an actor's longest turn | 10 ms on the best of 3 runs (`static let c2Budget = 10.0`) | `Tests/ZTronAssetKitBenchmarks/BenchSync.swift:129`; CLAUDE.md C2; no JSON key | every R-SYN-n and R-CLN-6 C2 benchmark, e.g. `BenchSyncCycle22Purge.swift:32` |
| P-13's statistic | the nearest-rank p99 of the deletion units' wall times; it tolerates n − ceil(0.99 n) units over 5 ms: 4 for 400 ≤ n < 500, 5 for 500-599, 6 for 600-699 | `BenchStorage.swift:253`, `:591-598`; `SPEC.md:308` (owner ruling 2026-10-29, ADR-050 option A); `DECISIONS.md:635` | P-13 |
| P-3 at the payload limit | P-3's budget scaled by limit / reference bytes: 817.54 ms for 32 MiB, stricter than R-MAN-3's 1 s | `BenchModel.swift:36-38`; printed at `s5/benchmarks.log:89` | R-MAN-3 (`SPEC.md:172`), §4.7 |
| P-13 scaling | P-4's `doubling_ratio_max` 2.5; the control ratio 1.5, a literal | `BenchStorage.swift:262`, `:274`, `:276` | the scaling test: 2.007 and 1.028 (`s5/benchmarks.log:136`) |
| The load rule | §0 | `DECISIONS.md:633`, `:659` | how a benchmark red is judged (§4.4) |

## 4. Results

### 4.1 Stage 5's `--full`, step by step

| Step | Result | Figures | Record |
|---|---|---|---|
| gates-selftest | OK | `SELFTEST: PASS` | `full5:4-6` |
| harness | OK | `GATES-CONFIG sha256=` the /goal's hash (§3.1); `HARNESS: unchanged since harness-frozen` | `full5:7-10` |
| toolchain | OK | `toolchain OK: Swift 6.4 >= 6.3` | `full5:11-14` |
| build-debug | OK | `Build complete! (6,77 s)` | `full5:15-17` |
| build-release | OK | `Build complete! (32,45 s)` | `full5:18-20` |
| build-ios | OK | exit 0; the log holds only xcodebuild's `IDERunDestination` line, which is not a warning | `full5:21-22`; `s5/build-ios.log:1` |
| tests-run-1-of-3 to 3-of-3 | OK, 3 of 3 | 1,732 tests per run (§4.2); 0 `✘` lines in the three logs | `full5:23-52` |
| coverage | OK | overall 96.93 % (§4.3) | `full5:53-63` |
| tsan | OK | 1,732 tests passed; 0 `ThreadSanitizer` and 0 `✘` lines in `s5/tsan.log` | `full5:64-73` |
| benchmarks | **FAIL** | 88 tests in 8 suites, 7 issues (§4.4) | `full5:112`, `:115`; `s5/benchmarks.log:479` |
| trace | OK | `TRACE requirements=90 (MUST=78) budgets=14 tests-with-ids=1661`. The step regenerated `docs/TRACEABILITY.md`, identical to the committed copy (ORCH:613) | `full5:116-119` |
| unsafe | OK | `UNSAFE escapes found=0 max=3` | `full5:120-123` |
| docs | OK | `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%` | `full5:124-127` |
| Verdict | | `::: SUMMARY mode=--full steps-failed=1`, `VERIFY: FAIL (1 failed: benchmarks)`, `exit 1` | `full5:128-130` |

### 4.2 Tests per target

The transcript does not name the bundles. Each block's first suite identifies its target
(`s5/tests-run-1-of-3.log:58`, `:642`, `:3199`, `:5858`, `:6171`, `:6391`, `:6557`; "Transfer classification", for
one, is in `Tests/ZTronAssetTransportTests/ClassifierTests.swift`), in the order ADR-057 records (`DECISIONS.md:634`).

| Test target | Run 1 | Run 2 | Run 3 | TSan |
|---|---|---|---|---|
| ZTronAssetTransportTests | 165 | 165 | 165 | 165 |
| ZTronAssetSyncTests | 713 (366.9 s) | 713 (366.6 s) | 713 (366.0 s) | 713 (1,739.5 s) |
| ZTronAssetStorageTests | 500 (176.0 s) | 500 (175.5 s) | 500 (175.8 s) | 500 (641.4 s) |
| ZTronAssetModelTests | 89 | 89 | 89 | 89 |
| ZTronAssetKitTests | 90 | 90 | 90 | 90 |
| ZTronAssetCompatibilityTests | 71 | 71 | 71 | 71 |
| ZTronAssetAppleHostedTests | 104 | 104 | 104 | 104 |
| All passed | 1,732 | 1,732 | 1,732 | 1,732 |
| Record | `full5:25-31` | `full5:35-41` | `full5:45-51` | `full5:66-72` |

The same seven counts passed in each of A's three runs (`fullM:22-48`) and its TSan step (`fullM:63-69`), in C's
`--quick` (`t64b/quick.out:14-20`), and in I's three runs and TSan step (`t64c/tests-run-<i>-of-3.log`,
`t64c/tsan.log`). F reports totals only: 1,732 of 1,732 (`sim/sim-summary.json:27`, `:61`).

### 4.3 Coverage (lines)

| Target | Floor | H: `45df2e1` | A: `e840b0e` | I: `45df2e1` at tools 6.4 |
|---|---|---|---|---|
| ZTronAssetAppleHosted | 70.0 % | 99.76 % (1248/1251) | 99.76 % (1248/1251) | 99.68 % (1247/1251) |
| ZTronAssetKit | 70.0 % | 97.99 % (1464/1494) | 97.99 % (1464/1494) | 97.99 % (1464/1494) |
| ZTronAssetModel | 70.0 % | 99.32 % (3383/3406) | 99.32 % (3383/3406) | 99.32 % (3383/3406) |
| ZTronAssetStorage | 90.0 % | 97.52 % (8410/8624) | 97.54 % (8412/8624) | 97.58 % (8415/8624) |
| ZTronAssetSync | 90.0 % | 95.11 % (12375/13011) | 95.07 % (12370/13011) | 95.10 % (12374/13011) |
| ZTronAssetTransport | 70.0 % | 99.10 % (2427/2449) | 99.10 % (2427/2449) | 99.10 % (2427/2449) |
| Overall | 80.0 % | 96.93 % (29307/30235) | 96.92 % (29304/30235) | 96.94 % (29310/30235) |
| Device-only, excluded | at most 3.0 % | 177 lines, 0.58 % | 177 lines, 0.58 % | 177 lines, 0.58 % |
| Record | | `s5/coverage.log:2-9` | `fullM:51-58` | `t64c/coverage.log:2-9` |

The export covers 8 test bundles (`s5/coverage.log:1`). Besides the two device-only files, the gate excludes tests,
build products and `ZTronAssetTestSupport` (`quality-gates.json:22-28`).

### 4.4 Benchmarks: 88 tests, 7 issues

`✘ Test run with 88 tests in 8 suites failed after 612.338 seconds with 7 issues.` (`s5/benchmarks.log:479`). Two
tests failed: P-13's reclaim test (1 issue, `:134`) and "R-CLN-6: a purge's first turn over 10,000 ids holds the
engine's actor at most C2's 10 ms" (6 issues in 9 cases, `:386`), declared at `BenchSyncCycle22Purge.swift:15` and
asserting at `:32`. Every other test passed.

| # | Issue (line) | Figure | Threshold | Loads in the case | Why it is accepted |
|---|---|---|---|---|---|
| 1 | `.oneGroup` (:340) | best 35.80 ms (:339) | `c2Budget` 10 ms | 3.03-3.12 (:339) | a known miss of C2's limit by the owner's ruling (close point 2, `DECISIONS.md:625-626`), one of the six causes of the accepted FAIL (point 3, `:633`); RESIDUAL-RISKS RES-01 |
| 2 | `.oneMemberGroups` (:347) | best 37.23 ms (:346) | 10 ms | 2.55-3.03 (:346) | as 1 |
| 3 | `.oneGroupScope` (:354) | best 39.45 ms (:353) | 10 ms | 2.65-2.71 (:353) | as 1 |
| 4 | `.sharedJobFourGroups` (:363) | best 18.65 ms (:362) | 10 ms | 2.65 (:362) | as 1 |
| 5 | `.fourGroups` (:370) | best 62.29 ms (:369) | 10 ms | 2.54-2.68 (:369) | as 1 |
| 6 | `.retryJobs` (:377) | best 36.20 ms (:376) | 10 ms | 2.45-2.70 (:376) | as 1 |
| 7 | P-13, `p99 <= batchBudget` at `BenchStorage.swift:253` (:129) | p99 5.836 ms; 7 of 525 units over 5 ms, 5 tolerated (:128) | 5 ms | none printed (P-13 prints no load, `DECISIONS.md:635`) | "A P-13 red with no code change falls inside the accepted FAIL, not a new cause" (`DECISIONS.md:635`); the code is the merged head's (§1); RES-02 |

- The six purge shapes ran at loads of 2.45-3.12, so all six are misses measured at a quiet load. On the merged code
  this is the first quiet measurement of `oneGroupScope`, `sharedJobFourGroups` and `fourGroups`, which ran only
  above 10 in A (`DECISIONS.md:589`). The figures lie inside the range recorded since Stage 3, 17.82-64.00 ms
  (`:626`).
- The purge shapes that passed: `sharedJob` 4.64 ms (:360), `userWaiters` 6.80 ms at 2.55-2.60 (:383) and `ensures`
  7.28 ms while the load rose from 2.55 to 16.27 (:385); both joins shapes passed (:389, :391).
- The step printed loads on 61 case lines between :242 and :449 (RESIDUAL-RISKS.md §0.4), from 2.45 (:376) to 16.27
  (:385-394). The first is at :242 (2.61), after the storage benchmarks.

**The accepted end state holds.** ADR-057 accepts this FAIL only under these conditions (`DECISIONS.md:633`, `:659`):

| Condition | Stage 5 | Record |
|---|---|---|
| Its causes are the six purge shapes and P-13, each named from the benchmarks log | the 7 issues above, and no other | `s5/benchmarks.log:129`, `:340-377`, `:479` |
| Every other stage passes on its own | 14 of the 15 steps OK | `full5:4-73`, `:116-127` |
| No red at a load of 10 or less in a margin-list case or in `userToBound` (that would be a new cause) | all passed: `commitTwoTokensTurns` 8.71 ms at 14.22 → 13.56 (:408); `userSharedApplyTurns(.keep)` 8.27 ms, no load printed (:281); `divergenceTurns` 7.53 and 7.60 ms, no load printed (:266); `concentrationCommitRerouteTurns` 7.39 ms at 2.90 (:248); `userToBound` 4.63 ms at 13.56 → 11.75 (:411-412) | `s5/benchmarks.log` |
| G3 holds: no `withKnownIssue`, no `.disabled`, no change to `allCases`, `c2Budget` or the Benchmarks tree | `Tests/` is unchanged since `e840b0e` (§1); it has no `withKnownIssue` and no `.disabled` trait (its three `.disabled` matches are `OSSignposter.disabled` and an argument value) | `git diff e840b0e 45df2e1 -- Tests` and a grep of `Tests/`, both run for this file |

The orchestrator's record of the run says the same and sends nothing to the owner (ORCH:607-612; RESIDUAL-RISKS.md
§0.4).

### 4.5 P-13 across the runs

| Run | Head | Load | Units | Over 5 ms (tolerated) | p99 | Max | Total | Result | Record |
|---|---|---|---|---|---|---|---|---|---|
| A, `--full` | `e840b0e` | not printed | 525 | 5 (5) | 4.80 ms | 8.09 ms | 0.578 s | pass | `m/benchmarks.log:160-161` |
| D, run 1 | `e840b0e` | 4.14 → 4.05 | 528 | 5 (5) | 4.89 ms | 10.51 ms | 0.581 s | pass | `p13q:1`, `:12-13`, `:18` |
| D, run 2 | `e840b0e` | 4.05 → 3.88 | 509 | 5 (5) | 4.81 ms | 9.70 ms | 0.565 s | pass | `p13q:19`, `:30-31`, `:36` |
| D, run 3 | `e840b0e` | 3.88 → 3.65 | 519 | 5 (5) | 4.31 ms | 8.00 ms | 0.573 s | pass | `p13q:37`, `:48-49`, `:54` |
| H, Stage 5 | `45df2e1` | not printed | 525 | 7 (5) | 5.84 ms | 10.72 ms | 0.588 s | **fail** | `s5/benchmarks.log:128-134` |
| I, tools 6.4 | `45df2e1` | not printed | 515 | 2 (5) | 4.66 ms | 8.05 ms | 0.564 s | pass | `t64c/benchmarks.log:158-159` |

"Over 5 ms" counts the entries of each line's "units over the batch budget" list (counted for this file); the
tolerance is §3.3's.

- **Stage 5's red.** Its seven over-budget units took 5.13-10.72 ms of wall time but at most 0.948 ms on CPU. Over all
  525 units the p50 was 0.965 ms, the p95 0.997 ms and the largest on-CPU time 1.008 ms; the reclaim's blob unlinks
  peaked at 10.54 ms, 11 of them over 4.0 ms (`s5/benchmarks.log:128`). The cause the records give: one `unlink(2)`
  stalls about every 850-1,060 unlinks with the fan-out, by count, whatever the store controls (`DECISIONS.md:621`).
- **The ruling.** The owner ruled the nearest-rank p99 (ADR-050 option A, "List P99"); only the owner can change the
  statistic or the number, and the bar stays as ruled (`DECISIONS.md:380`, `:383`, `:635`; RES-02). P1: no spare
  units, since every run on `e840b0e` had exactly the 5 tolerated. P2: about 30 % of runs fail the p99 with no code
  change (17 of 53 recorded runs, Wilson 95 % 0.21-0.45; the refuter's 14 of 50) (`DECISIONS.md:635`). Stage 5's red
  is one such run.
- **E's verdicts.** Fidelity, measurement and refuter each `PASS_WITH_NOTES` with no blocking item
  (`pm/p13-verify-wf_19408ffa-9ba.json:7-9`, `:73-75`, `:137-139`); nothing went to the owner (ORCH:531).

### 4.6 The other runs

- **A, `--full` on `e840b0e`.** `VERIFY: FAIL (1 failed: benchmarks)` (`fullM:126`); every other step OK
  (`fullM:1-70`, `:113-124`), with the same hash (`fullM:5`). Benchmarks: 88 tests, 7 issues (`fullM:109`): the six
  purge shapes (`m/benchmarks.log:350-387`) and `userToBound` (`:422`); P-13 passed (§4.5). `userToBound` was red only
  at loads 14.35 → 10.54 (best 13.24 ms, `:421`), a load-only figure under the load rule and not a cause of the FAIL
  (`DECISIONS.md:593`, `:634`).
- **B, `userToBound` alone.** Heartbeat [4.37, 4.63, 4.63] ms, best 4.37 ms, longest held turn 1.23 ms, at loads
  3.19 → 3.06; passed (`u2b:13-17`).
- **C, tools 6.4 (b) on `e840b0e`.** `--quick` printed `VERIFY: PASS` (`t64b/quick.out:23`); the release build and the
  iOS generic build exited 0 (`t64b/status.txt:2-3`); 0 `warning:` lines (`t64b/status.txt:4`; `t64b/warnings.txt` is
  empty).
- **F, the iOS Simulator suite on `e840b0e`.** `** TEST SUCCEEDED **` (`sim/status.txt:2`); `result: Passed`, 1,732 of
  1,732 tests and 3,653 device test runs passed, 0 failed, 0 skipped (`sim/sim-summary.json:14-16`, `:25-32`, `:61`).
  8 `warning:` lines, all from `appintentsmetadataprocessor`, none from the compiler (`sim/status.txt:3-4`;
  ORCH:520). Load mean 44.87, range 3.02-257.43 over 147 samples (`sim/status.txt:13`); the suite has no timing
  assertion (`DECISIONS.md:574`). The benchmarks bundle is skipped (`sim/sim.log:2`): built, not run
  (`DECISIONS.md:390`).
- **G, the mutation re-check on `e840b0e`.** All 11 survivors KILLED, each by an assertion failure in a test named for
  its mutant, with no time-out (`mut/summary.txt:1-11`; `pm/mut-recheck/first-issues.txt:1-11`; `DECISIONS.md:686`).
  The unmutated head passed those tests in A's three runs, in TSan and on the simulator (ORCH:553), and `git status`
  was the same before and after (`mut/status-before.txt`, `mut/status-after.txt`).

  | Mutant | Target | First failing line | Requirement |
  |---|---|---|---|
  | M-S-07 | Storage | `LeaseTests.swift:387` | R-CLN-5 |
  | M-S-08 | Storage | `LeaseTests.swift:409` | R-CLN-5 |
  | M-S-11 | Storage | `StagingSinkTests.swift:180` | R-STO-6 |
  | M-S-20 | Storage | `GarbageCollectionTests.swift:622` | R-CLN-2 |
  | M-N-09 | Sync | `EngineBoundaryTests.swift:42` | R-SYN-3 |
  | M-N-12 | Sync | `EngineBoundaryTests.swift:50`, and 13 more issues | R-SYN-3; R-SYN-2 (F-28) |
  | M-N-14 | Sync | `EngineBoundaryTests.swift:73` | R-SYN-5 |
  | M-N-16 | Sync | `EngineBoundaryTests.swift:94` | R-SYN-5 |
  | M-N-20 | Sync | `EngineBoundaryTests.swift:102` | R-SYN-5 |
  | M-N-22 | Transport | `SizeAndResumeTests.swift:213` | R-NET-8 |
  | M-N-39, re-made at `EngineFailures.swift:374` (`mut/M-N-39.reapplied.diff`) | Sync | `EngineBoundaryTests.swift:137` | R-SYN-5 |

  Q-8's totals: 64 mutants (27 storage, 37 network), 53 killed at discovery, 11 survivors, all 11 killed by close-out
  tests and re-checked here (`docs/MUTATION-PROBES.md:11-14`). No gate checks Q-8 (§3.1).
- **I, tools 6.4 (c) on `45df2e1`.** `VERIFY: FAIL (1 failed: benchmarks)` (`t64c/full.out:126`); every other step OK
  (`t64c/status.txt:3`); 0 `warning:` lines (`t64c/status.txt:2`; `t64c/warnings.txt` is empty). Benchmarks: 88 tests,
  6 issues (`t64c/benchmarks.log:487`), the six purge shapes at `BenchSyncCycle22Purge.swift:32` (`:348-385`), best
  35.59, 36.55, 39.77, 17.97, 61.04 and 35.87 ms at loads 3.62-5.29 (`:347-384`); P-13 passed (§4.5). Coverage overall
  96.94 % (§4.3); TSan passed with 0 `ThreadSanitizer` lines (`t64c/tsan.log`). The check's own criterion, 0 warnings
  at tools 6.4 with only the accepted reds, is met (ORCH:615-618); its `--full` did not print `VERIFY: PASS`. Load
  5.41 at the start, 9.91 at the end (`t64c/started.txt:2`, `t64c/status.txt:6`).

### 4.7 What ADR-057 asks this file to state

- **R-MAN-3's 1 s bound** (S3-B-005; `DECISIONS.md:644`). R-MAN-3 bounds a fuzzed 32 MiB manifest at 1 s
  (`SPEC.md:172`). In every harness run the bound is asserted by the release benchmark "P-3: the reference decode rate
  holds for fuzzed manifests at the 32 MiB payload limit, keeping R-MAN-3 within 1 s" (`BenchModel.swift:32`), whose
  threshold of 817.54 ms is stricter than 1 s (§3.3); in Stage 5 its worst case took 326.71 ms
  (`s5/benchmarks.log:112`, passed at `:115`). The fuzz test asserts the 1 s bound only when its target is built
  optimised; an unoptimised build, as in `--full`'s test runs, asserts linear growth from 1 MiB to 32 MiB instead
  (`Tests/ZTronAssetModelTests/Manifest/ManifestFuzzTests.swift:15-18`). `docs/TRACEABILITY.md` is generated and
  cannot carry this.
- **The /goal's conditions** (`PROMPT.md:96`). The owner set the Done aside (`DECISIONS.md:633`); as a reader's note,
  not a ruling (`:659`), Stage 5's output against each condition:

  | Condition | Stage 5 | Record |
  |---|---|---|
  | the final `--full` prints exactly `VERIFY: PASS` | **no**: `VERIFY: FAIL (1 failed: benchmarks)` | `full5:129` |
  | `GATES-CONFIG sha256=2725907c…4f026f` | yes | `full5:8` |
  | `HARNESS: unchanged since harness-frozen` | yes | `full5:9` |
  | coverage overall ≥ 80.0, Storage and Sync ≥ 90.0, every other target ≥ 70.0 | yes | `full5:54-62` |
  | `TRACE: PASS`, `UNSAFE: PASS`, `DOCS: PASS` | yes | `full5:118`, `:122`, `:126` |
  | 3 consecutive passing test runs | yes | `full5:23-52` |
  | a passing TSan step | yes | `full5:64-73` |
  | passing benchmarks | **no** | `full5:112`, `:115` |
  | the ZTronCarouselCore branch builds and its pre-existing CDN tests pass through the shims | **not verified** (§5.3) | |
  | `docs/VERIFICATION.md` lists everything not verified | §5 | |
  | shown in "this session's transcript" | **no**: the run was on 7 Nov (ORCH:607), before the fresh session that resumed on 10 Nov (ORCH:622-623); the records show no later `--full` | |

## 5. Not verified

Nothing below was proven by a run in §2. Each item says why, and where it is carried: `docs/DEVICE-TEST-PLAN.md` (47
tests, DT-…, none of them run, `DEVICE-TEST-PLAN.md:5`), `docs/RESIDUAL-RISKS.md` (RES-nn), and the UNVERIFIED rows of
`docs/APPLE-API-VERIFICATION.md` §5 (by line, `:279-297`).

### 5.1 Device-only behaviour

| Area | Why no run here proves it | Device tests | Also |
|---|---|---|---|
| Background `URLSession` re-attachment: relaunch, UIKit's background-events hook, resume data, a fresh ranged 206, `taskDescription` across a relaunch, the live driver's callback order and priority writes, `shutdown()` with downloads in flight | `BackgroundSessionBackend.swift` is device-only and excluded from coverage (`quality-gates.json:30`); the host and simulator suites drive its logic through fakes (`DEVICE-TEST-PLAN.md:28-31`), among them `Tests/ZTronAssetTransportTests/FakeBackgroundSessionDriver.swift` | DT-BG-01 to DT-BG-09 | §5 rows `:284-287`, `:295`, `:296`; RES-65, RES-68 |
| Apple-hosted packs through TestFlight | needs TestFlight and Apple-hosted packs; `LiveAssetPackBackend.swift` is device-only (`quality-gates.json:31`); R-APL-3 runs over a fake pack backend (`ARCHITECTURE.md:981`) | DT-APL-01 to DT-APL-10 | rows `:279-283`, `:288`, `:289`, `:291` |
| Low storage | ENOSPC comes from the fakes, which do not model the OS's storage policy (`DEVICE-TEST-PLAN.md:31-34`) | DT-STO-01 to DT-STO-07, DT-APL-09 | row `:293`; RES-10, RES-40 |
| Memory warnings | `.live()` has no memory-pressure source (S3-B-009); the tests use fake sources, which do not model the OS's memory policy (`DEVICE-TEST-PLAN.md:31-34`) | DT-MEM-01, DT-MEM-02; DT-MEM-03 for R-MAN-3's allocation bound (S3-B-004) | RES-81 |
| Networks: `NWPathMonitor`'s transitions and first callback, expensive and constrained paths, HTTP/2 against CloudFront | the live `NWPathMonitor` test proves only the first element and notification-driven updates, and P-10 is HTTP/1.1 keep-alive on loopback (`docs/adr-drafts/d.md:149-150`) | DT-NET-01 to DT-NET-04 | row `:294` |
| Low Power Mode and thermal states | the conditions come from fakes (`DEVICE-TEST-PLAN.md:31-34`); the live signals are device-only (`DECISIONS.md:460`, `:674`) | DT-PWR-01 | |
| Performance on a device: C2, P-8, P-9, P-13's unlink stalls, L5K-R24's lag | every figure in §4 is this Mac's (`DEVICE-TEST-PLAN.md:37`) | DT-PERF-01 to DT-PERF-06 | row `:297`; RES-02, RES-88 |
| The unified log: `OSLogStore`'s retention of S1's `.info` line; no secret in the device log | the tests read the injected `LogSink` tap (`DECISIONS.md:674`) | DT-OBS-01, DT-OBS-02 | row `:292`; RESIDUAL-RISKS.md §0.2 |
| The iOS 15 floor at run time | no iOS 15 simulator boots on this host, and the test bundles build at iOS 17.0 (`DECISIONS.md:390`, `:394`) | DT-FLR-01, DT-FLR-02 | row `:290` |
| The adopted app: `MainBundleLookup`, legacy migration from the prior-art app, the shims' live paths | the adoption was never built (§5.3) | DT-KIT-01, DT-MIG-01, DT-MIG-02, blocked until the adoption | RES-85 |

### 5.2 Gaps in this run and its records

- **No device run.** Every result in §4 comes from this Mac or the iOS 27.0 Simulator (RES-86).
- **Nothing re-run on 10 Nov.** Every run in §2 is from 6-7 Nov. The 10 Nov resume (ORCH:623-627) planned only the
  documents' workflow, and this file's writer built and tested nothing; its only checks read git objects (§1's `git
  diff`, §3.1's Q-6 stronger form).
- **On `e840b0e`, not on `45df2e1`:** runs B, D, F and G, none repeated on `45df2e1`, and C, which I repeats there as
  a `--full`. Only `///` lines differ between the two heads (§1).
- **The benchmark bundle on the iOS Simulator:** built, never run (`sim/sim.log:2`; `DECISIONS.md:390`, `:394`). It is
  part of S3-B-100, and DEVICE-TEST-PLAN.md §14 leaves it to this file as a host task. Not done.
- **S3B-13 and S3-B-011:** S3B-13 (user-initiated publications are quadratic: 10k/5k ratio 2.71-2.86, about 0.5-1 ms
  each at 10,000) with the owner's P-8 run, and the chunked `startGrace` for S3-B-011 at `maxEntries` (grace start
  37.31 ms), both assigned to Stage 5 (`DECISIONS.md:647`; figures at `:621`): not done. RESIDUAL-RISKS.md RES-44 and
  RES-45 carry the risk.
- **Loads not printed.** The TSan step prints none (RESIDUAL-RISKS.md §0.4), nor do P-5 (`s5/benchmarks.log:122`)
  and P-13 (`:128`); the benchmarks log's first load is at `:242`. Hence:
  - *P-5 on a quiet host* (S3-B-021's host part, DEVICE-TEST-PLAN.md §14): not shown. P-5 passed in A, H and I with
    no load recorded.
  - *P-13 on a quiet host:* shown only by run D on `e840b0e`, in substance rather than to the letter
    (`DECISIONS.md:674`).
  - *WP-C's quiet-host TSan* (`DECISIONS.md:650`): Stage 5's TSan passed all 500 Storage tests in 641.418 s
    (`full5:68`), the 128 cases of the legacy kill-then-power-loss pairs in 641.410 s (`s5/tsan.log:5830`) and `start
    racing stop` in 43.233 s (`:4802`). Whether the step ran at a load of at most about 30 is not shown: no load is
    logged between the run's start, 4.11 (`full5:2`), and the benchmarks step after TSan, whose first load is 2.61
    (`s5/benchmarks.log:242`). The decision `:650` names (raise the pairs' one-minute guard to three minutes with the
    measured durations, or raise `legacySlices`) was not taken; `Tests/` is unchanged (§1). RES-53, RES-42.
  - *The TSan Sync bundle alone* (`DECISIONS.md:659`: "The TSan Sync bundle runs alone, or paired only at an S3-R12
    rule-1 mean of 30 or less"): the step is one `swift test --sanitize=thread` invocation (`verify.sh:114`); it
    reports the seven bundles one after another (`full5:66-72`; Sync's 713 tests at `:67`), which fits them running in
    sequence within that invocation. The "alone" reading rests on the step's structure. No load was logged during the
    step, so the paired alternative is not shown; the condition was not measured. RES-38.
- **No separate `--perf` run**, as for `e840b0e`: close point 10's "TSan and `--perf` on an idle host" is met through
  stand-ins (`DECISIONS.md:674`). Stage 5's benchmarks step printed loads from 2.45 to 16.27 (§4.4).
- **Host details** that no Stage 5 log prints: the CPU model and the Xcode version (§1).
- **Not yet archived:** `s5/`, `t64c/` and all but the first 23 lines of `full5` (§6.7).

### 5.3 Gates and requirements with no run behind them

- **Q-10, compatibility** (`SPEC.md:328`). Not verified. PROMPT Stage 4, the adoption inside ZTronCarouselCore
  (`PROMPT.md:62`), was replaced by the owner's standalone-package instruction (ADR-006, `DECISIONS.md:36-39`): nothing
  outside this repository was built or written, ZTronAssetCompatibilityTests exercises the shims here (71 tests,
  §4.2), and `docs/MIGRATION.md` describes the adoption. ZTronCarouselCore has no pre-existing CDN tests to port
  (`docs/BASELINE.md:7`). So the /goal's ZTronCarouselCore condition is not shown (RES-85).
- **Q-4, determinism** (`SPEC.md:322`). No gate checks it (`gates.py:331-335`), so no run in §2 shows that tests never
  sleep or wait on the wall clock, print their seeds, or pass in any order; the three consecutive passing runs (Q-5)
  are the nearest evidence.
- **Q-8, mutation probes.** No gate; the evidence is `docs/MUTATION-PROBES.md` and run G (§4.6).

### 5.4 ADR-057's Not-verified list (`DECISIONS.md:668-674`)

The six drafts' "Not verified here" sections, by reference: `docs/adr-drafts/s3ah.md:246-253`, `s3g.md:206-211`,
`s3b.md:554-565`, `s3c.md:543-556`, `s3d.md:496-507` (with `d.md:143-152`) and `s3f.md:11992-12205` (for WP-F,
minus the entries ruled, fixed or superseded since they were written, `DECISIONS.md:674`).

**WP-A and WP-H** (`:669`)

| Item | Where |
|---|---|
| Device behaviour of every changed line | the flows of DEVICE-TEST-PLAN.md §4 to §8 and DT-FLR-01 (`DEVICE-TEST-PLAN.md:911`) |
| S3AH-1's transport side is checked only through the Model test's restatement (`transportAccepts`), so a change to `RequestFactory.swift:68-81` fails no Model test | a host gap; the transport test is assigned to WP-D, a later round or Stage 5 (`DECISIONS.md:643`), and is not written: `Tests/` is unchanged since `e840b0e` (§1) |
| S3-B-108: the loopback server's refusal of a LAN address is not probed | RES-83 |
| OI-2: ordered versus durable commits, by reading only (S3-B-105) | DT-MIG-01 through S3-B-036 (`s3c.md:548-550`) |
| S3-B-004: R-MAN-3's allocation bound on device allocators | DT-MEM-03 |

**WP-G** (`:670`)

| Item | Where |
|---|---|
| S3-B-094 and S3-B-098 (a replaced root; a real `rootVanished` and its reopen) | DT-STO-04; RES-69 |
| S3-B-099 (UIKit's background-events hook end to end; the live `MainBundleLookup`) | DT-BG-02, DT-KIT-01 |
| S3-B-100 (P-8, P-9 and C2 on a device; the benchmark bundle on the simulator) | DT-PERF-01, DT-PERF-02, DT-PERF-04; the simulator half is §5.2 |
| The S3G-1 figures: macOS host, release, under load | host figures only; a device run is DT-PERF-04 |
| (a′) and (a″) are limits, not checks | RES-73 |
| S3-B-095 and S3-B-097, by reading only | RES-72 |
| s3g's mutants and 5,000-seed model run were measured on `wp/s3g`, before WP-F's merge changed `SubscriberQueue.swift`, `EngineEvents.swift` and `EngineLifecycle.swift`, and not re-run on the merged head | RES-87. On the merged code Kit's 90 tests passed in every run and under TSan (§4.2) |

**WP-B** (`:671`)

| Item | Where |
|---|---|
| S3-B-021: fsync semantics and cost, file protection, iOS 15 at run time, P-5 and P-13 on a quiet host | DT-STO-05, DT-STO-06, DT-PERF-03, DT-FLR-01; the host part §5.2 |
| S3-B-022: a `rename(2)` that takes effect and reports failure, `lstat`/`pread` I/O errors, `LiveFileSystem`'s catch paths, the killed-rename undo window | DT-STO-06 |
| S3-B-018 to S3-B-020's recorded limits | unchanged (`s3b.md:440-443`) |
| The benchmark figures were taken while other worktrees built (loads quoted) | host conditions; §4 gives Stage 5's loads |
| S3-B-015, not reproduced | RES-49 |
| S3B-9's take-back is not exercised for WP-C's dooms | RES-48 |
| S3B-12's low-load claims could not be checked at load 93-106 | run D's quiet runs (§4.5); RES-02 |
| The unlink-stall periodicity is host APFS evidence only | DT-PERF-03; row `:297`; RES-02 |

**WP-C** (`:672`; `DECISIONS.md:650` asks this file to carry them)

| Item | Where |
|---|---|
| S3C-2's per-turn costs on a device (macOS release over the fake only) | DT-PERF-03, DT-PERF-01 (S3-B-038) |
| `apply`'s hook for a blob 10,000 ids share: one turn, not re-measured | RES-55 |
| Legacy migration on a device: one APFS volume, a root on another volume, `LiveLegacyDefaults`, Unicode normalisation or case, the overlap guard's identity walks, sandbox stat refusals, OI-2 (S3-B-036) | DT-MIG-01 |
| The incarnation check against a real rename-over, inode reuse (S3-B-037) | DT-STO-07 |
| C-22's actor holds, `apply`'s chunked eviction, a purge's wait for another reaper's kernel-blocked deletion, the prefilter's even spread (S3-B-038) | DT-PERF-03, DT-PERF-01; the prefilter's spread is not observable (`DEVICE-TEST-PLAN.md:889`) |
| Power loss is modelled by the fake's two modes only; real APFS ordering is not (`s3c.md:554-555`) | not modelled; DT-STO-06 kills and restarts on a device |
| Cycle 2 had no clean Storage TSan run | the merged code's TSan passed all 500 Storage tests in A (643.249 s, `fullM:65`), H (641.418 s, `full5:68`) and I (638.178 s, `t64c/tsan.log:5933`) |
| S3C-1's repetitions predate cycle 2 and the merge | not repeated |
| The S3-B-035 audit, by reading only | not tested (`ARCHITECTURE.md:981`) |
| What the engine answers an integrity job's waiters for an id bound during `recordIntegrityFailure`'s await | not tested (`:672`); ADR-053 left that window open (`DECISIONS.md:460`) |

**WP-D** (`:673`; `:652` asks this file for the drafts' "Not verified here")

| Item | Where |
|---|---|
| Whether UIKit hands a second background-events handler for one identifier while the first waits (`s3d.md:498-500`) | DT-BG-02; row `:295` |
| The order in which the live driver's two priority writes for one name land, and whether the OS applies the last one written; proven with the fake driver only (`s3d.md:501-506`) | DT-BG-08; row `:296` |
| A rewrite to an old task identifier after the same name was created anew, by reading the coverage-excluded live driver only | DEVICE-TEST-PLAN.md §14 (DT-BG-08 records one if it occurs) |
| S3-B-046: a fresh background download finished with a ranged 206 (`d.md:144`) | DT-BG-05; row `:285` |
| S3-B-047: `taskDescription` on a task made from resume data, across a relaunch (`d.md:145`) | DT-BG-06; row `:286` |
| S3-B-049: background resume data end to end, and the errors for stale data (`d.md:146`) | DT-BG-04; row `:284` |
| S3-B-050: the live driver, its task creation against `invalidate()` (`d.md:147`), its callback order (`d.md:148`), and Stage 2's surviving mutant ME at `BackgroundSessionBackend.swift:58-60` | DT-BG-01, DT-BG-04, DT-BG-07; RES-68 |
| S3-B-051: real path transitions (`d.md:149`), D-18.5, HTTP/2 against CloudFront (`d.md:150`) | DT-NET-01, DT-NET-02, DT-NET-04 |
| S3-B-054: R-NET-3's run-time half | DT-BG-03; RES-65 |
| Two host observations designed around, not relied upon: an early `-1005` with `closeAfter`, and MIME sniffing holding the first bytes (`d.md:151-152`) | host only |
| Evidence that survives only as quotes in the draft: the cycle-1 verifier's probes and runs (`.build-verify-s3d-c1-correct/`, `.build-s3d/mutpkg`, both gone) | cannot be re-checked |

**WP-F** (`:674`)

| Item | Where |
|---|---|
| Every C2 figure is this host's only (Apple M3), with no device run; the run-to-run spread reaches about 17 % | DT-PERF-01, DT-PERF-02 |
| The known misses' field frequency, the owner's re-open criterion, is not measured | RESIDUAL-RISKS.md §0.3. S1's line is the only field signal (§0.2), and only if the app collects `.info` lines (DT-OBS-01; Stage 4's decision, `DECISIONS.md:658`) |
| Of the known misses, only the six purge shapes and APM's turn are measured (APM's by a scratch probe); N7's five, f3b-review §7's variants, route A §9's third shape and N25's three are estimates; item 4's shapes are unmeasured | RES-03 to RES-07; the six re-measured in §4.4 |
| The ENOSPC suspects rest on code reading; correct #1's and #2's probes cap retries at 1 and script the second attempt to succeed | RES-10 |
| d5's audit of the held-turn readers is an analysis with one premise pinned (`3a551f4`) | `DECISIONS.md:674` only |
| RR-2, RR-4, RR-10, RR-12, RR-13, RR-15, RR-23 and RR-25 are analysed, not probed | RES-19, RES-21, RES-24, RES-25, RES-26, RES-27, RES-28, RES-14 |
| f3c's heap scans are unmeasured | RES-08 |
| The production `originID` cost (UNCONFIRMED) | RES-09 |
| `releaseRerouteHolds` (R12) has no figure; `waitingTarget`'s window is analysed; the ~35 ms prune announcement at `maxEntries` is an estimate | RES-39 |
| Whether an app's `OSLogStore` read returns S1's line | DT-OBS-01; row `:292` |
| Device-only: `NWPathMonitor`'s first callback, background `URLSession`, Apple-hosted packs, thermal state and Low Power Mode, the opportunistic and important capacities' order, S3-B-066's churn | DT-NET-02, DT-BG-01 to -09, DT-APL-01 to -10, DT-PWR-01, DT-STO-03, DT-STO-02; rows `:293`, `:294`; RES-40 |
| M5 and M6 (R-SYN-15 mutants) are reconstructed | `docs/MUTATION-PROBES.md:198` |
| The R1 boundary probes (PROBE-D2-READ-ORDER, -D3-READ-PROMOTE, -J-UNRELATED-FREE) were never re-run | not re-run |
| Cycles 21 and 22 did not run `--full`; their TSan loads were sampled every 10 s, or at start and end only, where S3-R12 rule 1 asks for 5 s or less | the merged code's `--full` ran three times (A, H, I); their TSan steps print no load at all (§5.2) |
| *What point 8's verification did not reach:* neither verifier ran `--gates-only` or `--full`; run 14's corrections (c23 #1, #2, #3, #5, #6) rest on a verifier's run and run 14's reading of it, and no verifier checked them; `p2-after-verdict-true`'s kill comes from one unrepeated run of the cycle-23 correctness verifier | not re-checked; A, H and I ran after the merge |
| *Loads:* at the close, `.userWaiters` and `.ensures` ran above 10 and were not re-run; at the merged head `oneGroupScope`, `sharedJobFourGroups` and `fourGroups` ran only above 10, and `.ensures`' load rose from 6.90 to 17.87 | H measured all six purge shapes at 2.45-3.12 (§4.4) and `.userWaiters` at 2.55-2.60 (6.80 ms, `s5/benchmarks.log:383`); `.ensures` passed at 7.28 ms while the load rose again, from 2.55 to 16.27 (`:385`), cause not measured |
| *Close point 10's "TSan and `--perf` on an idle host":* met through stand-ins | the same at Stage 5 (§5.2) |
| *P-13 "judged in the idle `--perf`":* met in substance, not to the letter | §4.5, §5.2 |

**Process** (`:675`, outside the list)

| Item | Where |
|---|---|
| The second sentence of `DECISIONS.md:685` (the first is in the WP-F table's point-8 row): ADR-050's amendment for P-13's records (P3, P4) and the P5 corrections ADR-057's pass made (ARCHITECTURE §12 S2-27, `BlobUnits.swift:155-162`) are not independently verified until their verifier checks them; ADR-050 says the same of P3 and P4 (`DECISIONS.md:383`) | not independently verified: ORCH:569-571 records the ADR-057 docs workflow's round-2 verifier at 0 blocking and P3-P5 as fixed, not a check of these claims |
| The `///` doc comments made true at the merge "are recorded as this pass's, not independently verified" (`DECISIONS.md:690`) | not independently verified; ORCH:569 records round 1's verifier finding `SyncEngine.swift:13-18`'s continuation rule untrue of the code, and round 2 at 0 blocking; no check of each comment is recorded |

### 5.5 The earlier merges' Not-verified lists, by reference

Each merge carried its drafts' "Not verified here" to this file. `docs/ARCHITECTURE.md:981` collects them, and
DEVICE-TEST-PLAN.md §13 maps their device items to tests. The host-side items of note:

| ADR (`DECISIONS.md` line) | By reference | Host-side items |
|---|---|---|
| ADR-050, level 2: WP-B, WP-D, WP-E (:372) | `b.md` and `d.md` "Not verified here"; WP-E's E-3, E-5, E-6, E-8, E-9, E-12, E-16, E-17 | what the index state-space enumeration does not cover (B-33); the sliced release survey at 100,000 entries (one probe); E-8 and E-9 checked at source level only |
| ADR-051, iOS Simulator test build (:394) | ARCHITECTURE §14 | tests run on the iOS 27.0 Simulator only, none below iOS 17; the benchmarks bundle is built, not run; the loopback LAN refusal is not probed; a runner crash's restart is taken from xcodebuild's message; the ungated-`.timeLimit` rule holds for this Xcode only |
| ADR-052, level 3: WP-C (:420) | `c.md` | phase 3's mutation-serial guard, by reading; OI-8's allocation measurements (macOS 27 and the iOS 27 Simulator only); the kept set across a crash (OI-11 (b)) |
| ADR-053, level 4: WP-F (:460) | `f.md` F-14 and the residues of F-20 to F-42 | OI-2 against the fake's model only; the binding-ledger windows without a deterministic probe; the listed space interleavings; C2 at 10,000: the rows it left unmeasured were measured in Stage 3, and only the prune announcement at `maxEntries`, about 35 ms by estimate, stays unmeasured (`:588`); test-fidelity limits (F-33's priority floor, F-34's missing liveness phase, F-41) |
| ADR-054, level 5: WP-G (:498) | `g.md` | the untested interleavings (L5-R9); the "no give-up after a running join's read" invariant, argued only; R-CAR-5's lost update, never reproduced; the claims' C2 figures from macOS release probes |
| ADR-055, level 5: WP-K (:531) | `k.md` | Q-10 (§5.3); the shims below iOS 17; the live provider and monitor; `CDNLocalStore(baseDirectory:)` in an app container; the migration window's device costs; the shims across a facade reopen (RES-82) |
| ADR-056, WP-I (:559) | `i.md` I-1, I-2, I-3, I-6, item 9 | the Swift 6.2 consumer floor (only Swift 6.4 built the package); the README quick start compiled, never run; the other snippets compiled over stubs, not under `-warnings-as-errors`; the Installation fragment not compiled; the README's simulator commands not re-run; the Apple-hosting setup beyond APPLE-API-VERIFICATION §1.7 |

## 6. How to reproduce

### 6.1 The harness

```
bash Scripts/verify.sh --quick        # harness, toolchain, debug build, one test run (verify.sh:124-129)
bash Scripts/verify.sh --full         # the 15 steps of §2.1 (verify.sh:141-157)
bash Scripts/verify.sh --perf         # toolchain and benchmarks (verify.sh:130-133)
bash Scripts/verify.sh --gates-only   # selftest, harness, trace, unsafe, docs (verify.sh:134-140)
python3 Scripts/gates.py selftest
SWIFTPM_SCRATCH=.build-<name> bash Scripts/verify.sh --full    # one scratch path per agent (CLAUDE.md)
```

The last line is `VERIFY: PASS` or `VERIFY: FAIL (<n> failed: …)`, and the exit code mirrors it (`verify.sh:9`,
`:164-170`). Each step overwrites `.verify-logs/<step>.log` (`verify.sh:40-42`), so copy the folder before the next run.

### 6.2 Stage 5's run (H)

In a clean worktree detached at the head, with the committed manifest, never in the main checkout, whose
`Package.swift` edit is the owner's (ORCH:585). For example (the records do not give the commands that made
`.worktrees/merge-check`):

```
git worktree add --detach .worktrees/<name> 45df2e1
cd .worktrees/<name>
SWIFTPM_SCRATCH=.build-<name> bash Scripts/verify.sh --full
```

Stage 5 used `.worktrees/merge-check` (ORCH:579); A, in the same worktree, used the scratch `.build-orch-merge`
(ORCH:516). Record the date and the 1-minute load before and after, as `full5:1-2` and `:131-132` do (`verify.sh` prints
neither), and copy `.verify-logs/` (ORCH:614). Judge a benchmarks FAIL by §4.4's conditions; any other failure is a
new cause and goes to the owner (`DECISIONS.md:633`).

### 6.3 The single-case re-runs (B, D)

The `--perf` command (`verify.sh:115`) with its filter narrowed, as the records describe it; the exact command lines
were not logged:

```
swift test -c release --scratch-path <scratch>-perf -Xswiftc -enable-testing --filter 'StorageBenchmarks/reclaim\(\)'
swift test -c release --scratch-path <scratch>-perf -Xswiftc -enable-testing --filter userMovedToBound
```

The first is D's (P-13, `DECISIONS.md:674`; its filter as `pm/docs-followup-items.md:50` records it), the second B's
(`userToBound`, ORCH:508). Record the load before and after each run, as `p13q:1`, `:18` and `u2b:2`, `:19` do.

### 6.4 The iOS Simulator suite (F)

As F ran it (`sim/sim.log:1-2`), with ADR-051's rules (`DECISIONS.md:40`, `:391`): one named simulator that is not the
owner's booted one, a `-derivedDataPath` inside the repository, after the `--full` and never during it, under
`sim.lock` (ORCH:517):

```
xcodebuild test -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=<UDID>" -derivedDataPath <scratch>/xcode-sim -resultBundlePath <dir>/sim.xcresult "-skip-testing:ZTronAssetKitBenchmarks" -collect-test-diagnostics never OTHER_SWIFT_FLAGS=-warnings-as-errors
xcrun xcresulttool get test-results summary --path <dir>/sim.xcresult
xcrun simctl shutdown <UDID>
```

F's values: `<UDID>` `897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, `<scratch>` `.build-orch-merge` and `<dir>` the main
checkout's `.build-orch/sim-merged` (`sim/sim.log:2`). Its summary is `sim/sim-summary.json`, and the shutdown found
the device already shut down (`sim/shutdown.txt:1-3`).

### 6.5 The tools-6.4 checks (C, I)

In `.worktrees/t64`, detached at the head, set only line 1 of `Package.swift` to `// swift-tools-version: 6.4` and
never commit it (ORCH:512, :615). Check (b) runs `bash Scripts/verify.sh --quick`, the release build and the iOS
generic build (ORCH:513-514); check (c) runs `bash Scripts/verify.sh --full` (ORCH:615). Then grep every log for
`warning:`: the check needs 0 lines (ORCH:515, :616).

### 6.6 The mutation re-check (G)

For each survivor, in a clean worktree at the head: apply its discovery diff (`<id>.diff` in
`.build-orchestrator/s3-mutants/storage/` or `network/`, ORCH:555), or for M-N-39 the re-made
`mut/M-N-39.reapplied.diff` (ORCH:558); keep the diff as applied (`mut/<id>.applied.diff`); run that target's tests
the way `run_tests` does (`verify.sh:92`); restore the file with `git checkout -- <file>`; and compare `git status`
before and after (ORCH:554-558). A kill is an assertion failure in a test, never a time-out alone (S3-R3;
`docs/MUTATION-PROBES.md` §2.2; `DECISIONS.md:684`). G's script, `mut-recheck.sh`, was kept in the 7 Nov session's
scratchpad (ORCH:555) and is not archived.

### 6.7 Where the logs are

Locally, at the paths of §0. Archived on the branch `archive/build-orchestrator`:

| Snapshot | Commit | What it holds of this file's evidence |
|---|---|---|
| 4 (7 Nov, committed 04:40, done 04:42; pushed and restore-tested, ORCH:649-656) | `cd17cdc` | `build-orch-logs/`: `merge-full.log`, `merge-verify-logs-e840b0e/`, `merge-userToBound-rerun1.log`, `merge-P13-quiet.log`, `t64b/`, `sim-merged/` without `sim.xcresult`, `mut-recheck/`, and the first 23 lines of `stage5-full.log`; `.build-orchestrator/s3-post-merge/` with the P-13 verifier's JSON, `docs-followup-items.md` and `mut-recheck/first-issues.txt` |
| 1 to 3 (6 Nov 14:39, 15:55, 16:47) | `765102c`, `5ba3601`, `2d87b7c` | earlier Stage 3 evidence; snapshot 3 predates runs 13 and 14 (ORCH:583) |
| 5 | not taken yet | due after Stage 5, adding `stage5-verify-logs-45df2e1/`, `t64c/` and the whole `stage5-full.log` (ORCH:641) |

Read an archived file with `git show archive/build-orchestrator:build-orch-logs/<path>`, or
`git show archive/build-orchestrator:.build-orchestrator/s3-post-merge/<file>` for `pm/`.
