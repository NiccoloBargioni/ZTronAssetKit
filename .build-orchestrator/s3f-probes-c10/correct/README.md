# s3f close-out cycle 10 — correctness-lens verifier probes (never committed)

Built from `git archive` of wp/s3f HEAD `5203ccb` (sources = `a206500`) into the verifier's scratch copy; each probe
file goes in `Tests/ZTronAssetSyncTests/Engine/`. Every probe runs in both orders (`LaneDropVisit`) and expects the
visit-first outcome. Run: `swift test --filter 'VerifyC10CorrectProbes'` (or the PROBE name).

## New (VerifyC10CorrectProbes.swift) — each 3/3 (logs/c10-probes-1..3.log, c10-double-1..3.log)
- PROBE-C10-THROTTLE-EXTENDED: visit-first B = serverUnavailable(60); barrier B = serverUnavailable(300). Also the
  origin's `.throttle` alarm: visit-first 300 s, barrier 60 s while the throttle runs to 300 s (c10-throttle-ext-alarm.log).
- PROBE-C10-JOIN-RETIRE: visit-first C failed(.at), attempts 1, 1 start; barrier C retired and re-created (epoch 8),
  attempts 0, downloading, 2 starts.
- PROBE-C10-PAUSE-LANE: visit-first N user-lane, not paused; barrier N prefetch-lane, policyPause constrainedNetwork, 2 starts.
- PROBE-C10-THROTTLE-LANE: visit-first origin throttle 0.838 s (background policy); barrier 0.2096 s (interactive).
- PROBE-C10-DOUBLE-PLACE: visit-first P starts before X (3 < 4); barrier X before P (3 < 4).
- PROBE-C10-EDGE-ORDER: inconclusive (same F/C order in both orders; visit-first starts C a third time) — not cited.

## Cycle-9 probes re-run on HEAD (ReC9*.swift, adapted only where `VerdictAfterFollow.joined` was read) — rec9-1.log
Pass both orders: C9-JOIN-RESOLVE, C9R-JOIN-RESOLVE, C9-OFFLINE, C9-JOIN-RETRY-PLACE, C9-SPURIOUS-JOIN,
C9-STALE-PLACE(+CONTROL), C9R-THROTTLE-PRESENT. Still fail sweep-first: C9-THROTTLE and C9R-THROTTLE-FAILFAST (N created by
the visit is admitted only after the barrier, by then under C's 429 throttle: R2's admission wait). C9R-OFFLINE-FAILFAST
fails in both orders (its own B0 assertion, as the cycle-9 README says).

## Mutants (mut/mutants.py, mut/run.sh; whole EngineFollowBarrierTests suite per mutant) — logs/mut-test-*.log
Killed: enospcNoDefer (sweep-first, time limit 180 s + :1116), reinstateNoReplay (:789, :790), edgeNoReplay
(Verdict :369, :371). Survived 33/33: relaneNoDefer (the `.relane` deferral dropped), throttleAtNow (`answeredAt: nil`).
