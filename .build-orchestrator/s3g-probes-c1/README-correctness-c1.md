# s3g close-out cycle 1, correctness lens: verifier probes

All runs on a copy of the wp/s3g tree (be4092e) under the verifier's scratch path; the worktree was never edited.

- `VerifyS3GC1PrefetchProbe.swift` (Tests/ZTronAssetKitTests): the clamped `PrefetchWindow.targets` equals a brute-force
  reference over carousels with repeated ids, every `current` (out of range included) and radii from `Int.min` to
  `Int.max`; `Int.max` over 200,000 pages returns every page once. Output: `probe-prefetch.log`.
- `mutants.py`: MC1, M05, M01s, RA4, RA2, MT1, MT2 applied one at a time to the copy and reverted; `mutants.out` has the
  failing lines (every mutant fails the new tests; M05's pre-existing sibling still passes).
- MC2 (targets ignores `reach`): replace `let reach = PrefetchWindow.reach(count: ids.count, current: current, radius: radius)`
  with `let reach = max(radius, 0)` in Prefetch.swift, then
  `swift test --skip-build --scratch-path <scratch> --skip Benchmarks --filter hugeRadiusWalksOnlyTheCarousel`: the
  test helper spins at ~85 % CPU and reports nothing after 150 s (a hang, not a failure).
- Forced-timeout A/B for the event model (`timeout-new.log`, `timeout-base.log`): in a copy, `.timeLimit(.minutes(2))`
  of `eventContinuityModel` changed to `.minutes(1)`, then
  `EVENT_MODEL_SEED_COUNT=200000 timeout 420 swift test --scratch-path <scratch> --skip Benchmarks --filter eventContinuityModel`.
  Lines: EXIT (124 = killed by `timeout`), start/end dates, number of time-limit issues (10), number of cases whose walk
  returned (7 on wp/s3g, 5 on s3-base). The rest never return: the process idles until killed.
- `perf06-probe.log`: the hunters' S3-PERF-06 probe (`prefetchWindowRadius`) passes on wp/s3g (debug build).
