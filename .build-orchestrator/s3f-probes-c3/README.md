s3f close-out verification, cycle 3, correctness lens: probes (scratch, never committed). Worktree wp/s3f at 3f9f58e (code at 776748a).

How they were run: the package was copied (rsync, without .build*/.git) to `.build-verify-s3f-c3-correct/pkg` inside the worktree's
scratch path, `VerifyC3CorrectProbes.swift` was added under `Tests/ZTronAssetSyncTests/Engine/` of the COPY only, then
`swift build --build-tests --scratch-path <scratch>/pkg-build` and `swift test --skip-build --scratch-path <scratch>/pkg-build --filter VerifyC3CorrectProbes`.

Probes (all in VerifyC3CorrectProbes.swift):
- PROBE-C3-W4 (hold seam; the pass-bound form: 2,100 changed on-demand fillers sort before the target, so the follow's first
  pass stops at followFormatsPerTurn before the target's entry; the target's old transfer running for a user waiter):
  the old content fails with a 404, an integrity failure (sizeMismatch), a 400 rejection, or a transient failure at an
  interactive cap of 1. HEAD: success from the new content in all 4. Fix removed (mutant below): notFound, integrityFailure,
  serverUnavailable, serverUnavailable.
- PROBE-C3-PARTIAL (hold seam): one job shared by two ids (same bytes); the apply moves only one; 404 before the pass reaches
  them. HEAD: moved id success, unmoved id notFound. Fix removed: both notFound.
- PROBE-C3-W4b (no seam; 3,000 ids, 404 released as soon as the copy changes; 1,792 visits owed at release), 3 rounds:
  HEAD success 3/3; fix removed notFound 3/3.
- PROBE-C3-W1b (no seam; 3,000 members, 4 slots; a 503 and a client cancel free slots between follow turns), 2 rounds:
  HEAD "starts since the apply 4, stale 0"; fix removed "starts since the apply 48, stale 44".
- PROBE-C3-SPACE (hold seam; NEW DEFECT): the target's replaced content (5 MB) is parked `awaitingSpace` (300 bytes of a
  pruned blob pending reclaim, 1 MB of room); the apply moves the target to a 16-byte content; before the follow's pass
  reaches it, the store's grace ends, the alarm's due work reaps 300 bytes and `sweepSpaceParked(.reclaimed)` parks the
  old job `insufficientSpace`, whose `failFast` answers the waiter with the OLD content's figures:
  `failure(insufficientSpace(required: 5000000, available: 1000303))` (PROBE-C3-SPACE-head.log), although the copy lists
  the id at 16 bytes that fit. With the one-line prototype `proto-sweep-follow.diff` (followBeforeActing in the sweep's
  candidate loop) the waiter gets `success` and the whole Sync suite passes (`✔ Test run with 404 tests in 52 suites
  passed after 45.680 seconds`, SYNC-suite-with-sweep-prototype.log).
  (PROBES-head-first-run.log holds an earlier version of this probe, 4,000 bytes and 50 bytes of room, which the store's own
  manifest files overran: its `available: 0` is not evidence; the 5 MB version is.)

Fix-removed mutant (applied in the copy, rebuilt, run, restored; cmp-checked identical afterwards):
  EngineJobs.resolveAll: `if case .failed = outcome, false, self.followBeforeActing(transfer)`;
  EngineFailures.countFailedAttempt: `guard var job = self.state.jobs[transfer] else` (hook removed);
  EngineFailures.spaceFailed: `!self.followBeforeActing(transfer),` removed from the guard;
  EngineDispatch.dispatch: `if let job = self.state.jobs[transfer], false, self.awaitsFollow(job)`.
