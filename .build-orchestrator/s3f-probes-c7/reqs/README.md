s3f close-out verification, cycle 7, requirements lens (worktree wp/s3f at 7426fee; code at 22c7b89). Scratch only; nothing committed.

- variants/*.diff: EngineJobs.swift mutants against HEAD (gen.py builds them). prefixC6 = the file at 69e209e (before the
  cycle-7 fix); skipNotFit / requeueNoAhead / noLaneRejudge = the cycle-6 mutants re-applied at HEAD; gainNoAhead = the new
  park-branch re-queue without counting the job ahead or recording spaceAdmitted; gainNoBound = the new branch's
  readmissionsPerTurn guard removed. mut.sh ran them in a copy of the worktree (logs/mut-test-*.log, logs/mut.timeline).
  prefixC6: EngineFollowTests.swift:1038:9 and :1040:9 (sweepFollowsFirst) 2/2. skipNotFit, requeueNoAhead: :901:9 4/4 each.
  noLaneRejudge: :1258, :1153, :901, :906 2/2. gainNoAhead, gainNoBound: the 4 R-SYN-11 tests and the whole Sync bundle pass.
- VerifyC7ReqsProbes.swift: PROBE-C7R-GAIN-AHEAD (the setup of spaceSweepRequeuesAFollowedJobItsNewLaneFits plus D, 7 MB,
  a prefetch waiter behind C). HEAD 5/5 pass; gainNoAhead 5/5 fail at :88:9 with D `.queued` in the sweep's turn
  (logs/probe2-*.log).
- logs/durations-*.txt: per-test TSan durations against each test's guard (durations.py); run-summaries.txt; load.log
  (1-minute load every 5 s). pairA/B 07:23:12-07:25:16 load 16.0-32.4; pair2A/B 07:25:30-07:28:19 load 17.9-36.1;
  pair3A/B 07:41:30-07:43:02 load 19.6-25.6; tsan-once 07:20:31-07:23:02 load 18.0-25.2.
