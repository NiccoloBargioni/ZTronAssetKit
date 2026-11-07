Cycle-23 reqs verifier (WP-F close-out, wp/s3f at d88bdb1), evidence copied before the scratch paths were deleted.
- mut/results.txt, mut/logs/: the 15 mutant runs (2 per mutant) and the baseline (tools/mutc23.py); mut/p1repeat.out and
  mut/logs/p1-rule-false-rep*.log: p1-rule-false six more times (tools/p1repeat.py); mut/logs/f2r1-*.log: the fixer's
  f2-R1 probe (ProbeC23F2R1-as-run-by-reqs-c23.swift, copied into the Sync-only snapshot as VerifyC23ReqsF2R1.swift)
  run 2/2 on d88bdb1's code. tools/mutsum.py re-parses the logs per visit order.
- logs/: sync1-3 (Sync x3), tsan, ios-generic, release, quick (+quick-logs/ from .verify-logs), cov.log, cov-gate.log,
  cov-enginecommands.txt (llvm-cov show of EngineCommands.swift: S1's line counts), sim-build/sim.log/sim-atsd30/
  sim-summaries (iOS Simulator 6BE15CAF, iOS 27.0), bench-run2 (full release Benchmarks), bench-rerun-hi and
  bench-rerun-edge (quiet-load re-runs), each with -load.txt (1-minute load samples) and .times stamps.
- cov.json: llvm-cov export -summary-only over the 8 .xctest bundles of the --quick run.
