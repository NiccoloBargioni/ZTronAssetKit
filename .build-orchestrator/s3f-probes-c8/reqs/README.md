s3f close-out verification, cycle 8, requirements lens (worktree wp/s3f at 40ecd95; code at 1b771e8). Scratch only; nothing committed.

- variants/*.diff: EngineJobs.swift (and EngineFollow.swift for prefix) mutants against HEAD, run in a copy of HEAD (git archive)
  with the cycle-7 probes (s3f-probes-c7/correct/VerifyC7CorrectProbes.swift, s3f-probes-c7/reqs/VerifyC7ReqsProbes.swift) added.
  prefix = both files at 7426fee (the original defect); c7gainNoAhead = 7426fee + s3f-probes-c7/reqs/variants/gainNoAhead.diff
  (its diff here is against HEAD); requeueNoAhead / requeueNoRecord = requeueSwept without the ahead count / the spaceAdmitted
  record; noReorder = no re-collection after the pre-phase follows; noResort = re-collected but unsorted; boundedJudges = a
  bounded pre-phase judges anyway. mut.sh ran them (logs/mut-test-*.log, logs/mut-sync-*.log, logs/timeline).
- VerifyC8ReqsProbes.swift: PROBE-C8R-INFLIGHT-PROMOTE, the setup of spaceSweepJudgesAJobItsFollowRaisesAtItsUserPlace with the
  holder C downloading (held) and kept by a prefetch waiter B, so the sweep's pre-phase does not follow it. 3/3 runs:
  sweepFollowsFirst A's user waiter insufficientSpace(3000000, 2500000), R served; followVisitedFirst A served, R
  insufficientSpace(3500000, 3000000) (logs/probe-c8-*.log). Drop it into Tests/ZTronAssetSyncTests/Engine/ of a copy.
- TSan: pair1 = the gate command (swift test --sanitize=thread) plus a direct run of the same bundle started 27 s later
  (logs/durations-pair1.txt); pair2 = two direct runs started together with --event-stream-output-path (logs/tsan-pair2*.jsonl.gz),
  windows.py gives each test's window and the 1-minute load over it (logs/pair2-overhalf.txt, logs/pair2-1min-overhalf.txt);
  load.log = 1-minute load every 5 s.
