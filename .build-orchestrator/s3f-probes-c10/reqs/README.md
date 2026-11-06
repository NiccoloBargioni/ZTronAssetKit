# s3f close-out cycle 10 — reqs-lens verifier probes and mutants (HEAD 5203ccb)

Scratch copy: `git archive 5203ccb` (Sources identical to the worktree, checked with `diff -r` before and after the
mutants). Nothing here was committed.

## Probes (extensions of `EngineSyncTests` or the cycle-9 correct-lens suite; reuse `FollowBarrier`)

- `VerifyC10ReqsProbes.swift` — `PROBE-C10R-POLICY-PAUSE` (the cycle-10 draft's residual "a policy pause reads the
  job's pre-visit lane"; S3-R14 item 2): fails in `.sweepFollowsFirst` 2/2 (`logs/probes-1.log`, `probes-2.log`):
  `pauses=1 starts=2` against visit-first `pauses=0 starts=1` (`VerifyC10ReqsProbes.swift:48`, `:58`).
- `VerifyC9ReqsProbes.swift`, `VerifyC9ReqsProbes2.swift`, `VerifyC9CorrectProbes.swift`: the cycle-9 probes, with their
  waits adapted to HEAD (the removed `VerdictAfterFollow.joined` flag replaced by the `joinsAfterVerdict` registry;
  assertions unchanged). At HEAD, 2/2 runs: JOIN-RESOLVE (both), SPURIOUS-JOIN, JOIN-RETRY-PLACE, OFFLINE, STALE-PLACE
  (+ control), THROTTLE-PRESENT pass in both orders. PROBE-C9-THROTTLE (correct lens) and PROBE-C9R-THROTTLE-FAILFAST
  still fail sweep-first (A = serverUnavailable(retryAfter: 60)): N is created by the owed visit and admitted only after
  the barrier (R2's admission wait), by when the 429's throttle parks it. PROBE-C9R-OFFLINE-FAILFAST fails in both orders
  on its own wrong B0 assertion (as in cycle 9).

## Mutants (`mut/mutants.py`, applied with `mut/apply.py`, driven by `mut/run.sh`)

All 8 killed 2/2, each in `.sweepFollowsFirst`: enospcNoDefer (EngineFollowBarrierTests.swift:1116 U =
insufficientSpace(required: 1500000, available: 1000000), plus the 180 s limit), reinstateSkip (:789, :790),
enqueueNoEpoch (EngineFollowBarrierVerdictTests.swift:248), joinNoVerdictDefer (:68, :69), visitRelaneEvent (:170,
:172), offlineNoDefer (:300, :303), throttleNoDefer (:422, :475), edgeNoNote (:369, :371).

## Gates at 5203ccb (logs/)

- verify.sh --quick: `VERIFY: PASS` (Sync 448, Storage 459, Model 84, Kit 85, Compat 71, AppleHosted 104, Transport 151).
- Coverage from quick's profile: `COVERAGE target=ZTronAssetSync lines= 93.67% (9621/10271) min=90.0 OK`, `COVERAGE: PASS`.
  Whole-bundle hits (follow-replay-coverage.txt): `.relane` replay EngineFollow.swift:166 = 0, `replayJoin`'s reroute :327 = 0.
- Sync x3 passed (61.4 s, 170.5 s, 66.3 s); release build 0 warnings; UNSAFE found=0; DOCS 1281/1281.
- TSan: run 1 paired with the correct lens's TSan, rule-1 mean 421.31: 74 time-outs, 23 other issues all in timed-out
  cases, 0 ThreadSanitizer reports; run 2 mean 392.95 passed (547.3 s); run 3 alone, mean 5.98, passed (162.6 s), 0
  time-outs, longest 63.9 s (S1-15, 5-minute guard), no test over half its guard.
- iOS generic build exit 0, 0 warnings. Simulator 6BE15CAF (iOS 27.0) at load 333-351: 1402 tests, 1381 passed, 21 failed,
  all ZTronAssetTransportTests (`.transient(.timedOut)` / progress never reached); Sync 448/448 passed; the Transport-only
  re-run (test-without-building) 151/151 passed at load 205-253.
- Benchmarks (load mean 10.72): SyncBenchmarks passed; only P-13 (WP-B) failed, unit max 7.66 ms vs 5.0 ms.
- S3-R13: tools 6.4 export, build-tests -warnings-as-errors and release: exit 0, 0 warnings, 0 errors.
