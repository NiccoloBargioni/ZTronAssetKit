s3f close-out verification, cycle 3, requirements lens (scratch, never committed). Worktree wp/s3f at 3f9f58e (code 776748a).

- VerifyC2CorrectProbes-c3reqs.swift: the cycle-2 correctness probes (PROBE-W1, W1b, W4, W4b), suite renamed; PROBE-W1's
  wait no longer requires inFlight == 2 between follow turns (with the fix nothing of the replaced content dispatches
  there, so that condition never holds and the unmodified probe hangs to its 120 s limit; first base log).
  Copy to Tests/ZTronAssetSyncTests/Engine/ of a scratch copy; mutate.py/run.py drive mutants (mut/src, ../build).
- mutant-logs/: base (probes at HEAD: W4/W4b success, W1b 4 starts/0 replaced, W1 0/0), noyield, m5closeonly, m5, m6,
  r3cancel, r5budget, r2split (cycle-2 reqs test-strength items: all killed), noFix / noResolveAllHook / noDispatchStall /
  noCountHook / noSpaceHook / listedOnlyAtDispatch / owedVisitsOnly / userHeadCounted (all killed; noFix reproduces
  cycle 2's notFound, 2 OLD downloads, 48/44 starts), noFlagPump and noDispatchOwedFlag (survive the whole Sync bundle).
- tsan-run1-*: first TSan Sync run (20:17-20:21, 1-min load 25.7->41.5, another verifier's TSan run overlapping): the
  S1-15 run test timed out at 180 s (194.17 s). tsan-run2-*: second run (20:45-20:47, load 11-24): passed, S1-15 82.7 s,
  alarm turn 38.25 s of 60 s. tsan-s115-alone-*: the S1-15 test alone (runs 1-2 at load 674/357: time-outs; run 3 at load
  13-28: 34.9 s).
- bench-sync-summary.txt: SyncBenchmarks (21:01-21:08, load 63->3.8): probeChainTurns exceeded its 3-minute limit while the
  host was at load 4-9 (chains 74.4 s, 95.0 s, third cut at 9.6 s); every C2 budget passed.
