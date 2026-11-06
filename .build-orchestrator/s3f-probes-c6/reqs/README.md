s3f close-out verification, cycle 6, requirements lens (worktree wp/s3f at e3a4c1a; code at daa2ba8). Scratch only; nothing committed.

- variants/*.diff: EngineJobs.swift mutants against HEAD. prefix = the file at 39dadd4 (the original PROBE-C5-LANEDROP defect);
  noLaneRejudge = the fixer's mutant (verdict = nil after the follow); noParkBound = the sweep's park bound removed;
  skipNotFit = a re-judged job that no longer fits is skipped (left as it was, no park, no wake); requeueNoAhead = re-queued
  anyway but not counted ahead. Built in a copy of the worktree (mut.sh / mut2.sh), each run twice.
  prefix, noLaneRejudge: committed test fails at EngineFollowTests.swift:845:9 (sweepFollowsFirst), and the cycle-5 probe at :114:9.
  noParkBound: EngineRegressionCycle8Tests.swift:306:9 and :307:9. skipNotFit and requeueNoAhead: the whole Sync bundle passes.
- VerifyC6ReqsProbes.swift: PROBE-C6R-LANEDROP-PARK (the committed lane-drop test plus: C's job parked insufficientSpace after
  the sweep; a later free-space read with room re-admits it). HEAD passes 10/10; skipNotFit fails PROBE-PARK in 4 of 10 runs
  (mut2/mut3 logs), so it is a survivor of the committed suite, not a liveness hang (PROBE-READMIT passes).
- logs/over-half.txt: one-minute Sync tests over 30 s in the paired TSan run (pairA/pairB, load 16.7 -> 40; first wave 16.7 -> ~33),
  with the alone figures of tsan (load 64 -> 25), tsan2 (7 -> 37, ramp) and tsan3 (11 -> 17, steady).
