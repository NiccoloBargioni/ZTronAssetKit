# s3f close-out cycle 11 — reqs-lens verifier probes and mutants (HEAD 3a86b92; sources as at 32c7ffe)

Scratch copy: `git archive HEAD` into `src/` (Sources identical to the worktree; each mutant's revert checked by an md5
of `git archive HEAD Sources` against the scratch Sources). Nothing here was committed.

## Probes (`Verify/`, placed in `Tests/ZTronAssetSyncTests/Verify/` of the scratch copy)

- `VerifyC10CorrectProbes.swift`, `VerifyC10ReqsProbes.swift`, `VerifyC9CorrectProbes.swift`: the cycle-10 verifiers'
  probes, adapted in waits and read points only (S3-R2): `joinsAfterVerdict` -> `joinsAfterFollow` (renamed state);
  JOIN-RETIRE's wait for the withdrawn waiter now counts only waiters whose continuation is live (since cycle 11 a
  withdrawn waiter's record stays, continuation `nil`, until the drain removes it); THROTTLE-LANE reads its figures after
  the drain (the no-Retry-After throttle is decided by the replay since cycle 11). Assertions unchanged.
  At HEAD, 2/2 runs each: THROTTLE-EXTENDED, JOIN-RETIRE, PAUSE-LANE, THROTTLE-LANE, DOUBLE-PLACE, C10R-POLICY-PAUSE pass
  in both orders. PROBE-C9-THROTTLE still fails sweep-first (A = serverUnavailable(retryAfter: 60)), the R2 question.
  PROBE-C10-EDGE-ORDER fails visit-first (inconclusive, as in cycle 10; not cited).
- `VerifyC11ReqsProbes.swift`:
  - `PROBE-C11R-COMMIT-REROUTE` (residual R-A): fails `.sweepFollowsFirst` 4/4 (logs/probes-1.log, probes-2.log,
    probes2-1.log, probes2-2.log): visit-first `(n: downloading, r: queued)`, barrier `(n: queued, r: downloading)`.
  - `PROBE-C11R-UNCONSTRAIN-DEMOTE` (residual R-D, Low Data Mode -> unrestricted during the barrier, a visit that lowers a
    downloading job): inconclusive / converged (1 pause, 2 starts in both orders); its tail times out (probe defect);
    applies v3 through `applyAndFollow` directly because the run did not reach its apply under Low Data Mode. Not cited.
- `VerifyREProbe.swift`: the fixer's R-E probe (`.build-s3f/probe/...pendingRunProbe.swift`, second test only, renamed
  `PROBE-C11R-RE-PENDING-RUN`), unchanged otherwise. On clean HEAD it stalls in `.sweepFollowsFirst` 2/2
  (logs/re-probe-1.log, re-probe-2.log): `DBGE run=(run-4, false, true, false) storeRuns=1 ... sleepers=0 next=nil`,
  `DBGS ... units=1 commitsInFlight=true`, time limit 60 s.

## Mutants (`mutants.py`; logs `mut/<name>-run<n>.log`)

Killed 2/2: noReroute (ApplyTests:186), throttleAtNow (ClassTests:213), noFlagPump (SurvivorTests:56), condNow
(ClassTests:53, :64, :615 + probes), pauseNow (ClassTests:135), throttleAnswersNow (ClassTests:352), removalNow
(ClassTests:420/422/423 + JOIN-RETIRE probe), joinNow (ClassTests:486), throttleParkNow (ClassTests:278 + THROTTLE-LANE
probe), relaneNoDefer (45-test suite, 7 issues).
Survived 2/2: readmitNow (`readmit`'s `.readmit` deferral removed; `barrierPlacesAReadmissionAsTheFollowLeavesIt`
passes), alarmAtPark (`park` schedules the throttle alarm at the park's own end; ClassTests:158 passes).
