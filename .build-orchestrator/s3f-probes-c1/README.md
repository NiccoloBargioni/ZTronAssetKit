s3f close-out verification, cycle 1, correctness lens: probes (scratch, never committed)

- VerifyC1CorrectProbes.swift -> Tests/ZTronAssetSyncTests/Engine/ (uses FirstReadingRig, EngineHarness,
  EngineSingleFlightTests.applied, EngineFailurePathTests.settleDue). Run:
  swift test --scratch-path <scratch> --skip Benchmarks --filter VerifyC1CorrectProbes
  PROBE-V1 (S3F-1, user-lane group), V1b (control), V3 (S3F-3 beside a healthy asset), V4 (S3F-4 settle races),
  V5 (S3F-5 follow), V6 (S3F-6 three runs), V7 (S3F-15 retries beyond one alarm turn). All pass on wp/s3f HEAD
  (probes-head.log). Mutants M1 (`?? true` -> `?? false`, EngineConditions.swift:98), M3 (S3-CONF-03 diff), M5
  (followApplied's previous-copy diff disabled) and M6 (isAnotherRun check removed) fail V1, V3, V5, V6
  respectively; V1b and V4 stay green (probes-mutants.log).
- VerifyC1CorrectFollowCost.swift -> same folder; release with -enable-testing:
  PROBE-V8 times followApplied(from:) alone at 10,000 waiting members (nothing moved ~1.1 ms, 10 % changed
  12.3-12.5 ms, every id changed 139-216 ms).
- VerifyC1ChangedRefresh.swift -> Tests/ZTronAssetKitBenchmarks/; release:
  swift test -c release --scratch-path <scratch> -Xswiftc -enable-testing --filter VerifyC1ChangedRefresh
  PROBE-V9: forced sync whose manifest changes 1 %, 10 % or 100 % of a waiting 10,000-member prefetch group's content,
  production dispatch executors, SyncBench.longestWait heartbeat. HEAD (load 11-12): 1 % [2.28, 2.21, 2.26] ms,
  10 % [10.27, 10.35, 10.45] ms, 100 % [144.9, 143.6, 124.6] ms -> fails C2 (PROBE-V9-head.log).
  VerifyC1ChangedRefresh-s3-base.swift is the same probe with HEAD's SyncBench.dispatchBench copied in, for s3-base
  (load 180-197): 1 % 38-46 ms, 10 % 39-46 ms, 100 % 131-201 ms (PROBE-V9-s3-base.log): pre-existing, not a regression.
