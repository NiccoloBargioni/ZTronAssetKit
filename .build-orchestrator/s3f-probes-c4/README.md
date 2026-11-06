s3f close-out verification, cycle 4, correctness lens (worktree wp/s3f at c2a78a0, code at 07ca8cb). Scratch probes, never committed.

How they were run: the worktree was copied (rsync without .build*/.git) to `.build-verify-s3f-c4-correct/pkg`; the two probe files were
added to the COPY only (`Tests/ZTronAssetSyncTests/Engine/VerifyC4CorrectProbes.swift`, `Tests/ZTronAssetKitBenchmarks/VerifyC4CorrectBench.swift`).
Debug: `swift build --build-tests --scratch-path ../pkg-build`, `swift test --skip-build --scratch-path ../pkg-build --filter VerifyC4CorrectProbes`.
Release: `swift build -c release --build-tests --scratch-path ../pkg-perf -Xswiftc -enable-testing`, then
`swift test -c release --skip-build --scratch-path ../pkg-perf --filter VerifyC4CorrectBench2` (or `VerifyC4CorrectBench`).
The prototype: a second copy `pkg2` with `proto-sweep-follow-budget.diff` applied (builds `../pkg2-build`, `../pkg2-perf`).

- PROBE-C4-SPACE-ORIG (the cycle-3 PROBE-C3-SPACE, 300-byte reclaim): HEAD answers success at 16 bytes (fixed). PROBES-space-head-run*.log
- PROBE-C4-SPACE-PARTIAL (one 5 MB content shared by zz-keep and zz-target, the apply moves only zz-target; 0.5 MB / 2 MB room before
  the 4 MB reclaim): HEAD answers zz-target success(16) and zz-keep insufficientSpace(required: 5000000, available: 4500000) when
  re-parked, success(5000000) when re-queued (the fix's partial path). Run 1's one failure was the probe's own expectation (the
  re-parked job is removed once its last waiter is answered); corrected in run 2, which passes.
- PROBE-C4-SWEEP-C2 (`.read` sweep only, 512 follows per turn): first turn 6.2-7.7 ms vs 3.3-3.5 ms without an owed follow (load ~40).
- PROBE-C4-SWEEP2-C2 (BLOCKING, C2): 10,000 prefetch members alternating 400 / 3,000 bytes parked awaitingSpace behind a 2,000-byte
  pending reclaim; a forced sync changes every member's content (follow-ups held); the reclaim leaves 2,100 bytes, so one `.reclaimed`
  sweep turn re-queues 512 and parks 512, and since c8f01ca follows each first: 1,024 follows in one actor turn (4x followsPerTurn).
  HEAD at load 2.8-3.2: heartbeat 10.18 / 10.52 / 10.83 ms (one handle), 13.62 / 14.05 / 13.83 ms (two handles over the same ids);
  direct first turn 9.28-9.92 ms and 12.92-12.96 ms; without the changed manifest 6.2-7.3 ms heartbeat, 3.2-3.4 ms direct.
  With proto-sweep-follow-budget.diff (a follow budget of followsPerTurn per sweep turn) at load 3.6-4.2: heartbeat 4.91-5.66 ms
  and 6.40-6.54 ms, direct 4.22-4.65 ms and 5.26-5.27 ms; the whole Sync bundle passes with it
  (`✔ Test run with 407 tests in 53 suites passed after 19.561 seconds`, the 405 committed plus the two space probes).
