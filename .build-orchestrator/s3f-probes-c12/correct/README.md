# s3f close-out cycle 12 — correctness-lens verifier probes (HEAD 3f10eaa; sources as at 2e22cf6 + tests to dcee1cd)

Scratch copy: `git archive HEAD` into the verifier's scratch `src/`; probes placed in
`Tests/ZTronAssetSyncTests/Verify/`. Nothing here was committed. Run with
`swift test --skip-build --scratch-path <pb> --filter <name>`.

## New probes (VerifyC12CorrectProbes.swift, VerifyC12RetrySetupProbe.swift)

- `PROBE-C12-PLACE-SLOT` (residual R-I proven): one slot; C holds it for user waiters A, B; v3 moves zz-a to N; C gets a
  429 Retry-After 60 while the follow owes C's visit. Visit-first: N queued at the apply, refused by the live throttle
  after the 429, A = serverUnavailable(60), N never started. Barrier: the barrier-end pump admits N on the apply's
  place stamp (no throttle in that view) although the origin is throttled: N starts (request to a throttled origin),
  A served 16 bytes. Fails `.sweepFollowsFirst` 2/2 at :75 and :82 (logs/probes-1.log, probes-2.log); visit-first passes.
- `PROBE-C12-UNDECIDED-LANE` (residual R-H proven): D (zz-a, content Z) and C (zz-b, content X) download for user
  waiters; v3 maps zz-a to X and zz-b to Y; C gets a 429 without Retry-After while the follow owes D's then C's visit.
  Visit-first: throttle 0.2096 s on arrival, zz-none fetch refused (requests 3 -> 3, serverUnavailable(0.2096)).
  Barrier: `followedLane(C)` is nil (D's interest is not counted), decision `.undecided`, no throttle until the drain:
  the throttled origin gets a manifest request (3 -> 4), caller answered `.notFound`. Fails `.sweepFollowsFirst` 2/2 at
  :135, :140, :143.
- `PROBE-C12-RETRY-SETUP-RACE` (test defect in 30c2a39's `barrierRetriesBehindTheOwedVisitsPlaces`): with the watcher's
  first reading delivered after R's 500 (gated), the first reading's edge re-queues R (R = downloading on its `.hold`
  step, one slot), so the test's wait for H downloading never holds: 2/2 (logs/race-1.log, race-2.log). The committed
  test timed out 180 s in both orders in verify --quick (load sampled 42-494) and in `.followVisitedFirst` in the
  coverage run (1-min load mean 104.71), then `#require(backoffEnd)` failed at ReplayTests:141
  (logs/verify-quick-backoff-failure.txt, cov-backoff-failure.txt). Isolated it passes 3/3 in 0.64 s.

## Earlier blocking probes re-run at HEAD (2/2 unless noted)

Pass in both orders: PROBE-C11-JOIN-THROTTLE-EXT, -JOIN-THROTTLE-END, -MANIFEST-THROTTLE, PROBE-C10-THROTTLE-LANE (its
original read right after the 429), -THROTTLE-EXTENDED, -JOIN-RETIRE, -PAUSE-LANE, -DOUBLE-PLACE (read of the removed
`placesAfterFollow` replaced by `eventsAfterFollow.count`, print only), PROBE-C9-THROTTLE.
PROBE-C11-COMMIT-PLACE and PROBE-C11R-COMMIT-REROUTE: with their original waits they time out sweep-first (they wait
for C's commit before releasing the follow, and the commit now waits for C's visit; logs/probes-1.log). With the waits
adapted (sweep-first waits for the deferred `.committed` event; B's answer read after the drain) both pass 2/2
(logs/probesB-1.log, probesB-2.log); assertions unchanged.
PROBE-C11R-RE-PENDING-RUN: still stalls 60 s sweep-first at its own wait for the breaker to leave `.open` (consistent
with the fixer's diagnosis: the re-admission that would admit a probe waits for the held follow).
