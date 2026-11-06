# s3f close-out cycle 9 — reqs-lens verifier probes and mutants

Scratch copies were built from `git archive` of the branch head `719ce20` (sources identical to HEAD; checked with
`diff -r`) and of `7626a07` (the failing-first tests on `40ecd95`'s sources). Nothing here was committed.

## Probes (`VerifyC9ReqsProbes.swift`, `VerifyC9ReqsProbes2.swift`; extensions of `EngineSyncTests`, reuse `FollowBarrier`)

- `PROBE-C9R-JOIN-RESOLVE` (the draft's open residual "a join while a `.resolve` verdict waits"): fails in the
  sweep-first order 4/4 (`logs/probe-1.log`, `probe-2.log`, `probe-tj-2.log`, `probe-tj-3.log`); visit-first passes.
  Visit-first B = success (1,000,000 bytes, a new job); barrier B = `serverUnavailable(retryAfter: nil)`.
- `PROBE-C9R-THROTTLE-PRESENT` (the residual "the offline and throttle exits", isolated from the admission wait:
  zz-a's new content Y is present and bound, `bound: true` while the visit is owed): fails sweep-first 3/3
  (`logs/probe-present-*.log`); visit-first A = success (16 bytes), barrier A = `serverUnavailable(retryAfter: 600)`.
- `PROBE-C9R-THROTTLE-FAILFAST`: same, with Y not present (diagnostic only: its difference also includes the
  barrier's accepted admission wait, so it is not cited as the finding).
- `PROBE-C9R-OFFLINE-FAILFAST`: did not reproduce a difference (A served in both orders); its B0 assertion is wrong
  (the offline attempt was retried and B0 served), so it fails in both orders for that reason only.

## Mutants (`mut/mutants.py`, applied with `mut/apply.py`, driven by `mut/run.sh`, `mut/run2.sh`)

Killed (each 2/2): sweepNoBarrier, pumpOwedOnly, pumpNoBarrier, dropFront, dropAskedBefore, resortOwed, visitForward,
joinNoDefer, enqueueNoDefer. Survived (2/2): enospcNoDefer (and enospcNoDefer + enqueueNoDefer together, 1/1).
Original defect (7626a07 = 40ecd95's sources + the committed tests): the INFLIGHT-PROMOTE and the three DROPPED tests
fail sweep-first 2/2 (`logs/base-test-*.log`, `logs/base-dropped-*.log`).
