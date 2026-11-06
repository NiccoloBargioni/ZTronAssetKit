s3f close-out verification, cycle 5, requirements lens (worktree wp/s3f at 39dadd4; code at 72b2ab2). Scratch only, nothing committed.

- mutants/*.diff: EngineJobs.swift variants against HEAD. prefix = the original defect (EngineJobs.swift as at 04ae782 / c8f01ca,
  each follow counted as the re-queue or park it precedes); noRequeueBudget / noParkBudget drop one branch's followFits; offByOne
  uses `follows <= followsPerTurn`. Applied to a copy of the worktree (rsync without .build*/.git) and run with mut.sh:
  `swift test --skip-build --filter spaceSweepFollowsAtMostOneTurnOfJobs`, twice each. Every mutant fails at
  EngineFollowTests.swift:672:9 (prefix/noRequeue/noPark: 344 jobs followed in one turn, plus :674:9; offByOne: 257); HEAD passes.
- probe-head.log / probe-prefix.log: the cycle-4 PROBE-C4-SWEEP2-C2 (s3f-probes-c4/VerifyC4CorrectBench.swift, VerifyC4CorrectBench2,
  release -enable-testing) on HEAD and on the prefix mutant. HEAD (load 7-10): heartbeat 5.19-6.10 ms one handle, 6.58-6.68 ms two
  handles; first turn follows 256 ("awaiting 10000->9744"). prefix: heartbeat 10.6-12.5 ms / up to 23.7 ms; 1,024 follows
  ("awaiting 10000->8976").
- bench-*.log: the committed `reclaimDuringFollowTurns` benchmark. prefix at load 7: [10.80, 11.53, 10.73] / [15.16, 16.00, 15.73] ms,
  fails BenchSync.swift:504:17. HEAD at load 7-12: wt1/wt2/pkg2 pass ([5.4-5.9] / [6.5-7.5] ms). bench-head-pkg.log is one HEAD
  miss ([12.04, 12.07, 12.53] / [13.03, 21.00, 20.57] ms) at 04:07:32-46 while the 1-min load rose 8.4 -> 16.1 just after a
  load-500 period (5-min 77-80): load only (S3-R5); the same binary passed at 04:08:37 at load 7.7.
- syncbench.log: all 21 SyncBenchmarks pass at load 7.8-16.6.
- tsan1 / pair1a / pair1b: ZTronAssetSyncTests under TSan, alone (load 14-24) and two bundles at once via run-direct.sh (load 8.8-20.8).
  S1-15 (`runMaterialisesAPipelineAtATime`, .minutes(3)): 66.07 s alone; 94.79 s and 95.62 s paired = 53 % of its 3-minute guard.
- cov.summary.log: the first coverage run at load 100-540 (other agents) had Storage time-outs (StoreCrashTests:167, LoopbackHTTPServerTests:400,
  60 s limits, other WPs' tests); cov2 re-run at load 6-11 passes every target; coverage-gate.log is from cov2 (Sync 94.03 %).
