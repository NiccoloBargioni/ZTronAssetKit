# s3f close-out cycle 12 — reqs-lens verifier probes and logs (HEAD 3f10eaa; sources as at dcee1cd)

Scratch copy: `git archive HEAD` into `.build-verify-s3f-c12-reqs/src`, probes placed in `Tests/ZTronAssetSyncTests/Verify/`.
Nothing here was committed.

- `Verify/VerifyC11CorrectProbes.swift`, `VerifyC11ReqsProbes.swift`: the cycle-11 probes; the COMMIT-PLACE and
  COMMIT-REROUTE copies have their B wait moved after the follow's release (waits only; the commit now waits for the
  visit). `VerifyC10CorrectProbes.swift` (THROTTLE-LANE read right after the 429), `VerifyC9CorrectProbes.swift`
  (C9-THROTTLE; `placesAfterFollow` reads replaced, STALE-PLACE not run). All pass 2/2 in both orders
  (`logs/probes-{1,2}.log`). `VerifyREProbe.swift` (renamed `probeREPendingRun`): times out sweep-first 2/2, and the
  time-out line precedes `DBGM`, so it hung at its first sweep-first wait (breaker not `.open`), as the fixer diagnosed.
- `Verify/VerifyC12ReqsProbes.swift`: PROBE-C12R-FOLLOWED-LANE (residual R-H) fails sweep-first 2/2
  (`logs/rh-{1,2}.log`): visit-first throttle 0.209572016 s (interactive), barrier 0.838288067 s (background).
- `Verify/VerifyC12RetryRepro.swift`: `barrierRetriesBehindTheOwedVisitsPlaces` with a state dump per wait; hung 1/30
  under six parallel runs (`logs/reps-5-2.log`): step 1 `cond=false`; step 2 R `downloading` (re-queued by the first
  conditions reading's edge); H never starts.
- `logs/mutchain.out`, `mut/`: the fixer's mutants (`fixer-mutants.json`) re-applied with `mut.py`; 15 kills 2/2.
