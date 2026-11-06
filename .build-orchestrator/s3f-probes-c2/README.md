s3f close-out verification, cycle 2, correctness lens: probes (scratch, never committed). Worktree wp/s3f at e91b9c7.

- VerifyC2CorrectProbes.swift -> Tests/ZTronAssetSyncTests/Engine/ (uses EngineHarness, EngineSingleFlightTests.applied,
  readForTests, the follow hold seam). Debug: swift test --scratch-path <s> --filter 'noStaleStartsBetweenFollowTurns|noStaleStartsOverFollow|notFoundBeforeVisit|notFoundDuringFollowNoSeam'
  PROBE-W1  (hold seam): 700 changed members, 2 slots: between follow turns the 2 running transfers are of REPLACED content.
  PROBE-W1b (no seam): 3,000 changed members, 4 slots: 44 of 48 starts after the apply are of replaced content (HEAD);
            0 of 4 at b4c215d (VerifyC2CorrectProbes-b4c215d.swift, the cycle-1 one-turn follow).
  PROBE-W4  (hold seam): a user resolve of the last of 600 ids, its replaced content's transfer answers 404 before its
            follow visit: HEAD answers failure(notFound) although the copy lists the id; b4c215d answers success.
  PROBE-W4b (no seam): same with 3,000 ids, the 404 released as soon as the copy changes: notFound 3/3 runs at HEAD.
- VerifyC2CorrectFollowTurns.swift -> Tests/ZTronAssetKitBenchmarks/ (release, -enable-testing):
  PROBE-W2: the turn of a second apply landing while a 10,000-job follow owes 9,744 visits: 5.2-5.3 ms alone (load 10-11).
  PROBE-W3: the breaker's parked-order rebuild at 9,994 parked jobs in one call: 5.1-6.3 ms.
- VerifyC1ChangedRefresh-rerun.swift: the cycle-1 PROBE-V9, re-run: 100 % changed [4.85, 4.60, 5.44] ms (was 124-145 ms).
