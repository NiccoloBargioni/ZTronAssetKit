# Stage 3 WP-C close-out (`s3c`) — dispositions

Stage 3 hardening of WP-C (integrity, cleanup, eviction, migration), branch `wp/s3c` from tag `s3-base` (`b5796ba`), close-out
cycles 1 and 2. Rulings: `.build-orchestrator/s3-rulings-s3c.md` (recorded below as "Orchestrator ruling (Stage 3)", the label
the rulings file gives; each is the "Orchestrator ruling (close-out)" the close-out's task names); findings with
the hunters' evidence and the confirmers' verdicts: `.build-orchestrator/s3-findings-s3c.json`. One entry per item (id,
disposition, tests added with display names, evidence), then decisions, the proposed REENTRANCY rows, "Authorised edits
outside WP-C", "Proposed document changes" and "Not verified here". Evidence paths below are under `.build-s3c/` in this
worktree (git-ignored). No public or package signature changed; no contract file, `Package.swift`, `Scripts/`, `SPEC.md`,
`docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/TRACEABILITY.md` or `docs/ORCHESTRATION.md` edited; no WP-B `Core/` file
edited (none held a poll of the S3C-1 class); 0 unsafe escapes added.

## Commits (in order)

| Commit | Item | What |
|---|---|---|
| `c8ef118` | S3C-1 | the release poll helper in the sites' old order, with its deterministic race test (failing) |
| `16f0c61` | S3C-1 | the helper reads the held units first; all 26 polls converted |
| `43ee17e` | S3C-2 | `LargeBlobTests` and the asserted one-blob benchmark cases (failing) |
| `adb42bd` | S3C-2 | a blob of more records than a chunk taken a chunk per turn (eviction and purge) |
| `f6bcf2a` | S3C-5 | "ended" polls before every join in `LegacyOnDemandRaceTests` |
| `3372b76` | S3C-3, S3C-4 | the two lease guards and the orphan grace's boundary pinned |
| `1ffe5ab` | S3C-10 | the comment above L5K-R17's wait |
| `70e1dba` | S3C-9 | the presence test of `recordIntegrityFailure` (failing) |
| `100d1c2` | S3C-9 | the presence guard; the overlap test's integrity case retargeted to a stale record |
| `c7b19f3` | S3C-6 | reap steps and the I-3 audit in the model-based oracle (`CleanupAuditSink`) |
| `5b8365c` | S3C-7 | crash at every boundary of seven cleanup flows |
| `ab2a6fc` | S3C-8 | legacy kill-then-power-loss pairs; crash then OS purge, stamped |
| `2269d7c` | S3C-11 | the S3-B-035 audit's outcome in phase 3's check comment |
| `94304a0` | S3C-2 | tests of the turns that read a large blob's holders again |
| `bcfd742` | all | dispositions and evidence (cycle 1) |
| `4a3da14` | S3C-2 | cycle 2: one `apply` swapping a large blob's holder, before its first turn and between its chunks (failing) |
| `b518df3` | S3C-2 | cycle 2: every turn checks that the ids left are exactly the blob's holders |
| `4d02cdb` | S3C-6 | cycle 2: the oracle's reaps drawn between its 40 operations, not counted among them |
| (this draft) | all | cycle 2 dispositions and evidence |

## Orchestrator rulings (Stage 3)

- **Orchestrator ruling (Stage 3) S3-R1 — scope and order.** Blocking items first (S3C-1, S3C-2: failing test committed on
  its own, then the fix), then every REQUIRED item (S3C-3…S3C-10), the ADR-RECORD item (S3C-11) recorded without code. Done
  in that order; every item below has an entry.
- **Orchestrator ruling (Stage 3) S3-R2 — probes.** The hunters' and confirmers' probes were adapted, renamed into owning
  suites (`S3…Probe` names gone), display names starting with the requirement ID (the helper's own test uses the "Test
  support:" prefix of WP-H's `CancelledWaitTests`, as no requirement ID names a harness), `.timeLimit` on every awaiting
  test, `ManualTimeSource` only, no sleeps, ADR-051's gating on every `@Test` and helper. The replays that encode the old
  poll order (`S3-STAB-01.swift`, `S3-STAB-02.swift`) were not committed.
- **Orchestrator ruling (Stage 3) S3-R3 — mutation survivors.** M-S-07, M-S-08 and M-S-20 each re-applied in a scratch copy
  (`.build-s3c/mut/src`) against the new tests: the failing lines are pasted under S3C-3 and S3C-4.
- **Orchestrator ruling (Stage 3) S3-R4 — hang guards.** Every new test keeps `.timeLimit(.minutes(1))`; the measured
  durations are under S3C-7 and S3C-8 (none needed a raised guard). Long loops check `Task.isCancelled`
  (`Task.checkCancellation()` in the enumerations). Cycle 2 (both verification lenses): outside the ruling's envelope, the
  legacy pairs' heaviest case (`.powerLossDropUnsynced`, slice 0: 143 pairs against 90.7 on average, kill point 0 with the full
  second-lifetime migration, run in the suite's start-up burst) exceeded its one-minute guard under TSan twice, both at loads
  far above about 30 from other agents' builds, TSan and simulator runs: the requirements lens's run 1 (17:45 → 18:21, load 18
  → 180, the 5-minute average up to 180; `CrashPairTests.swift:40:6: Time limit was exceeded: 60.000 seconds`) and the
  correctness lens's single run (17:57 → 18:24, one-minute loads 100–296). The same lens's run 2 (load 5 → 111 → 8) passed every
  case: 128 cases, 11,606 pairs in 971.2 s, about 7.6 s per case, about 12 s for slice 0. The test passed in every other run
  (three debug, the coverage run, the simulator; the fixer's TSan runs at load 2.5–12: 4.9–6.7 s per case, the largest about
  7.7–10.5 s). These are load misses, not logic flakes, so no guard is raised and no slice or pair is cut (G3). For Stage 5:
  run `--full`'s TSan on a quiet host; if it meets the guard at a moderate load, raise it to `.minutes(3)` with the measured
  durations (S3-R4), or raise `legacySlices` (for example to 96 or 128) so the heaviest case shrinks, every pair kept. This
  cycle's own TSan measurement is under "Final runs (cycle 2)".
- **Orchestrator ruling (Stage 3) S3-R5 — C2 at the reference scale.** S3C-2 bounds the work per turn with owned follow-up
  turns (proposed rows s3c-1, s3c-2), pins it with the asserted C2 benchmark in `BenchCleanup.swift` and structurally in
  `LargeBlobTests`.
- **Orchestrator ruling (Stage 3) S3-R6 — shared files.** No signature change; the document changes are proposed below.
- **Orchestrator ruling (Stage 3) S3-R7 — parallel close-outs.** Only WP-C's files changed (ARCHITECTURE §1.2); nothing
  depends on another work package's Stage 3 change.
- **Orchestrator ruling (Stage 3) S3-R8 — strict bar.** The one fix that lies in WP-B's files (`apply`'s eviction hook for a
  blob of more records than a chunk) is reported non-blocking as `other-wp:b:` under S3C-2.
- **Orchestrator ruling (Stage 3) S3-R9 — records.** This file.
- **Orchestrator rulings (Stage 3) S3C-1…S3C-11.** Recorded with each item below.

## Close-out cycle 2 — the verification findings and their dispositions

The cycle-1 verification (requirements and correctness lenses) left two blocking findings, both in S3C-2's fix, and six
non-blocking ones. Each is dispositioned here and recorded in full under its item.

| # | Lens, area | Disposition |
|---|---|---|
| 1 | correctness, BLOCKING: the evictable purge of a blob of more records than a chunk trusted the reference count (`StorePurge.swift` `purgeTurnIDs`) | **fixed**: failing tests `4a3da14`, fix `b518df3` (S3C-2, "Close-out cycle 2") |
| 2 | correctness, BLOCKING: quota eviction across turns trusted the reference count (`QuotaEviction.swift` `acrossTurnsSlice`) | **fixed**: the same commits (S3C-2) |
| 3 | requirements, tests (S3C-6, G3 spirit): the oracle's reaps counted among its 40 steps | **fixed** `4d02cdb`; Z and G re-run, both killed (S3C-6, "Mutant evidence") |
| 4 | requirements, records: the label "Orchestrator ruling (Stage 3)" | **fixed**: every ruling entry now carries it (the close-out's label alongside on each item) |
| 5 | requirements, environment: the legacy pairs' slice 0 over its guard under TSan at load 18 → 180 | **recorded** under S3-R4 (load miss; no guard raised, nothing cut); Stage 5 to run TSan on a quiet host |
| 6 | correctness, the same miss in the correctness lens's TSan run (loads 100–296) | **recorded** under S3-R4, as 5 |
| 7 | `other-wp:b:` WP-B's `killThenPowerLoss` (`Core/StoreCrashTests.swift:113-115`) records every error after its time limit (1,961 `.cancelled` issues) | **routed** to WP-B, below; not WP-C's file and not an S3C-1 poll conversion, so not edited |
| 8 | `other-wp:b:` `apply`'s eviction hook for a blob 10,000 ids share | **routed** (already, S3C-2) |

**`other-wp:b:` (non-blocking, routed) — a timed-out crash enumeration that keeps recording.** In the correctness lens's
overloaded TSan run, 8 cases of WP-B's `R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5`
(`Core/StoreCrashTests.swift:167`) hit their time limit, and the enumeration went on recording `reopen or convergence failed
with .cancelled` (`:114`) 1,961 times: its catch records every error, `.cancelled` included, and the loop continues. The fix
belongs to WP-B: rethrow when the error is `.cancelled` or `Task.isCancelled` holds (or check cancellation per pair), so a
timed-out case ends with its one time-limit issue. WP-C's own enumerations (`CrashPairTests`, `CleanupFlowCrashTests`) already
call `Task.checkCancellation()` per crash point.

## S3C-1 [BLOCKING] — the check-then-act poll (S3-STAB-01, S3-STAB-02, S3-B-034)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-1"; the close-out's "Orchestrator ruling (close-out) S3C-1").** Enumerate every poll in `Tests/ZTronAssetStorageTests` that
releases a `SteppedBlockingExecutor` held unit after reading a condition; convert all to one helper that reads `heldUnits`
first, then the condition, and releases only a unit read before a false condition (fix (a)); the helper in a new file under
`Cleanup/` as an `extension CorePoll`, pinned by a deterministic test of exactly the race; a WP-B `Core/` site authorised for
this conversion only; each converted test 200 repetitions in debug and 20 under TSan, `phaseFourStopsListing` 50 fresh TSan
launches.

**Disposition: fixed.** `Tests/ZTronAssetStorageTests/Cleanup/CorePoll+Release.swift` (new): `CorePoll.releasing(_:_:until:_:)`
with `Release.oldest` (one unit per round, for a flow that runs one unit at a time) and `Release.allExcept(_:)` (every held
unit but the ones a test holds on purpose); it returns the units it released (`CleanupSteps.run` reports them). Each round reads
the held units, then the condition, and releases only what it read before a false condition. Why that is enough: the
condition, once true, stays true while the poll runs, and the store makes the change the condition reads before it submits
its next unit; so a unit held at the first read was submitted before that read, when the condition was still false (it is
false at the later read), and the unit the store submits after the change is never released. Polls that also waited for that
next unit (`return await !metadata.heldUnits.isEmpty` once the condition held) now wait for it after the poll, with
`requireHeldUnits(atLeast: 1)`, event-driven.

**Enumeration** (every `CorePoll.until`/loop in `Tests/ZTronAssetStorageTests` whose body releases held units, found by a
brace-matching scan for `.release(`, `releaseNext(`, `releaseAll(`, `setHolding(` and the helpers that release; line numbers at
`s3-base`). Shape A: condition, then a separate hop for the held unit (the race). Shape B: release first, then the condition,
so the next round releases whatever the store submitted after the change.

| # | Site (`s3-base`) | Test(s) | Shape | Now |
|---|---|---|---|---|
| 1 | `Cleanup/CleanupHarness.swift:237-243` `CleanupSteps.run` | its users in `EvictionOverlapTests`, `GarbageCollectionTests`, `HolderScanTests`, `IntegrityTests`, `LegacyMigrationTests`, `PurgeTests`, `LargeBlobTests` | B | `.allExcept(kept)` |
| 2 | `Cleanup/EvictionOverlapTests.swift:103-111` | `applyPlanAtChunkYield` | A (+ held after) | `.oldest`, then `requireHeldUnits` |
| 3 | `Cleanup/EvictionOverlapTests.swift:145-150` | `purgeWhileCandidatesRun` | B | `.allExcept([candidates])` |
| 4 | `Cleanup/EvictionTests.swift:64-72` | `chunkYieldRevalidates` | A (+ held after) | `.oldest`, then `requireHeldUnits` |
| 5 | `Cleanup/EvictionTests.swift:118-126` | `chunkCountsRecords` | A (+ held after) | `.oldest`, then `requireHeldUnits` |
| 6 | `Cleanup/EvictionTests.swift:235-243` | `evictionDuringReusingPublication` | A | `.oldest` |
| 7 | `Cleanup/EvictionTests.swift:553-561` | `applyPlanInChunksRevalidates` | A (+ held after) | `.oldest`, then `requireHeldUnits` |
| 8 | `Cleanup/EvictionTests.swift:615-623` | `applyPlanChunksAtBlobBoundaries` | A (+ held after) | `.oldest`, then `requireHeldUnits` |
| 9 | `Cleanup/GarbageCollectionTests.swift:233-238` | `supersededPublicationKeepsKeyProtected` (B waits for A's placement) | B | `.allExcept([placementA])` |
| 10 | `Cleanup/GarbageCollectionTests.swift:308-316` | the helper `cancelDuringSecondRemoval`, used by `cancelledStagingGCStamps` | A | `.oldest` |
| 11 | `Cleanup/GarbageCollectionTests.swift:516-524` | `noPhantomDoom` (both cases) | A | `.oldest` |
| 12 | `Cleanup/GarbageCollectionTests.swift:588-596` | `sweepChunksReleaseActor` | A | `.oldest` |
| 13 | `Cleanup/IdempotencyTests.swift:140-148` | `cancelledCollection` (`heldUnits.isEmpty`, then `releaseNext()`: two hops) | A | `.oldest` |
| 14 | `Cleanup/LeaseTests.swift:265-270` | `derefDuringInFlightCommit` | B | `.allExcept([held])` |
| 15 | `Cleanup/LegacyEdgeTests.swift:417-425` | `phaseFourStopsListing` (S3-STAB-01) | A | `.oldest` |
| 16–22 | `Cleanup/LegacyOnDemandRaceTests.swift:37-42, 83-88, 119-124, 186-191, 320-325, 355-360, 406-411` | `onDemandJoinsTheBatchsAdoption`, `batchWaitsForTheOnDemandAdoption`, `secondOnDemandJoinsTheFirstsAdoption`, `closeResumesAWaitingAsker`, `batchWaitsForTheLastOnDemandAdoption`, `closeWhileTheBatchWaits`, `coalescedBatchReturnsBeforeItWaits` | B | `.allExcept(placement / onDemandHash)` |
| 23 | `Cleanup/LegacyOnDemandRaceTests.swift:484-492` | `batchRereadsWhatIsLeftAfterItsInstall` | B | `.allExcept(onDemandHash)` |
| 24 | `Cleanup/LegacyOnDemandRaceTests.swift:676-683` `LegacyRace.holdPlacement` | every user of `holdPlacement` | B (bulk released, metadata read) | `.allExcept(keepingBulk)` on the bulk executor |
| 25 | `Cleanup/PurgeTests.swift:348-364` `EngineReaperOverlap.init` | `purgeWaitsForEngineReaper`, `purgeSkipsEndedDeletion`, `purgeCancelledDuringInFlightWait` | already held-first | `.allExcept([purgeYield])` |
| 26 | `Cleanup/PurgeTests.swift:377-390` `untilPurgeReturnsOrWaits` | the same | already held-first | `.allExcept([kept])` |

Examined and not in the class: `EvictionTests.swift:247-252` (a releaser task with no condition, cancelled when the eviction
returns: it never reads state before releasing), `LeaseTests.swift:329-331` (`HeldSnapshotSink.setHolding`'s own loop, not a
`SteppedBlockingExecutor`). `Core/**`, `StorageContractTests.swift` and `TestSupport/**`: every release there is straight-line
after `requireHeldUnits` (or a `FakeRemoteSource` release, another type), so no WP-B file was edited and the authorisation was
not used.

**Test added (pins the helper, deterministic):** `PollReleaseTests` (`Cleanup/PollReleaseTests.swift`, new), `Test support:
the release poll never lets through a unit submitted after a condition read it outran` (2 cases: `oldest`, `everyUnit`). The
product side submits unit 1, waits for a gate, makes the change the condition reads, then submits unit 2; in the second
round the condition captures its value, opens the gate and waits until unit 2 is held, which is exactly the race. Against the
old order (commit `c8ef118`), deterministically: `PollReleaseTests.swift:58:9: Expectation failed: held == [2]` / `↳ the unit
submitted after the condition held is still held: []` and `:59:9: Expectation failed: completed == [1]`, both cases
(`.build-s3c/s3c1-failing.log`). With the fix it passes.

**Evidence (commit `16f0c61`, the conversions; `.build-s3c/rep1/`, `.build-s3c/tsan1/`).** Run directly through
`swiftpm-testing-helper` (`.build-s3c/run-direct.sh`, adapted from the stability probes' `run-direct.sh`), over every suite that
holds a converted poll or uses one through `CleanupSteps.run`/`holdPlacement`/`EngineReaperOverlap` (`PollReleaseTests`,
`EvictionTests`, `EvictionOverlapTests`, `GarbageCollectionTests`, `HolderScanTests`, `IdempotencyTests`, `IntegrityTests`,
`LeaseTests`, `LegacyEdgeTests`, `LegacyMigrationTests`, `LegacyOnDemandRaceTests`, `PurgeTests`):
- debug, `--repetitions 200`: `✔ Test run with 121 tests in 12 suites passed after 61.246 seconds.`, repetition 200 reached,
  0 `✘` lines (load 3.77 → 18.87);
- TSan, `--repetitions 20`: `✔ Test run with 121 tests in 12 suites passed after 25.865 seconds.`, 0 `✘`, 0 ThreadSanitizer
  reports (load 7.66 → 7.00);
- `LegacyEdgeTests/phaseFourStopsListing`, 50 fresh TSan launches: 50 × `exit 0`, 50 × `✔ Test "R-STO-11: phase 4 stops
  listing…"`, 0 `✘`, 0 TSan reports (load 7.00 → 3.97).
The suites were re-run at the head of the branch (see "Final runs").

## S3C-2 [BLOCKING] — one blob that 10,000 ids share left in one turn (S3-B-025)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-2"; the close-out's "Orchestrator ruling (close-out) S3C-2").** C2 at the reference scale: evicting or purging one blob shared
by 10,000 ids held the actor 15.4–16.6 ms in one turn (`Eviction/QuotaEviction.swift:266`). Chunk one blob's holders across
owned turns (S3-R5) and make `BenchCleanup.swift`'s C2 benchmark assert the 10,000-holders-per-blob case.

**Disposition: fixed** for quota eviction and both purges; `apply`'s eviction hook is WP-B's chunk cutter (below,
`other-wp:b:`).
- **Quota eviction** (`QuotaEviction.swift`): a candidate of more records than `EvictionState.chunk` is a chunk of its own
  (never joined to others) and is taken by `evictAcrossTurns(_:chunk:rules:)`, `chunk` records per actor turn with a no-op
  metadata unit between turns (proposed row s3c-1). The first turn checks every victim, as `evict` did in its one turn
  (`acrossTurnsSlice(_:_:of:rules:first:)`), so a blob changed before its first turn is skipped whole; each later turn checks the
  blob (live, unleased, not being placed), that exactly the victims not evicted yet hold it (since cycle 2: each of them read
  again and still holding it, and the blob table's reference count equal to their number, else `holders(of:known:scan:)`), and
  its own victims (`EvictionOrder.stillEvictable`: still holding it,
  evictable under rules whose clock is read again, not accessed since the selection). A failed check stops the blob.
- **Purge** (`StorePurge.swift`): a group of more records than `CleanupState.chunk` is purged by `purgeAcrossTurns`, `chunk`
  records per turn (row s3c-2); `.all` and `.scope` re-read each record (still references the blob), `.evictable` checks the
  blob and, on the first turn every holder, on a later turn its own holders while the ids left are exactly the holders (since
  cycle 2: each of them still references the blob and the reference count matches; else every holder, read again); the blob
  is waited for once and its bytes counted toward `releasedBytes` in the turn it is doomed.

**Decision S3C-2 (for the orchestrator to ratify).** *Context:* bounding a blob's eviction per turn means its records cannot all
leave in one turn (C-1). *Options:* (a) stop on a failed check between turns, the records already taken staying so; (b) roll
them back (re-bind) on a failure; (c) one turn (the R8 exception). *Decision:* (a), as WP-C proposed in C-22 cycle 7 (2):
nothing is released, the blob stays live with the remaining records, the state C-3's `stillReferenced` (a publication in
flight) already produces, and the next run takes the rest once they are evictable again. (b) would show the records absent
and then present to anyone who reads in between, and a commit in between persists the split anyway. Only blobs of more
records than a chunk (1,000) are taken this way, and only a change between their turns splits them; a change before the
first turn keeps the blob whole, as before (`evictablePurgeKeepsSharedBlobWhole` still passes unchanged). A started blob is
finished even if other releases met the need meanwhile (stopping half-way frees nothing). *Consequences:* a split blob's
evicted (or purged) records are downloaded again on demand and dedupe onto the live blob (no new bytes on disk).

**Tests added** (`Cleanup/LargeBlobTests.swift`, new; chunk seams `testSetEvictionChunk(2)`/`testSetCleanupChunk(2)`, a blob
five records share):
- `R-CLN-4: quota eviction takes a blob that more records share than a chunk holds one chunk of its records per actor turn`
  (at the two releases between turns: `(2 evicted, 3 references)`, then `(4, 1)`; result `CleanupResult(bytesFreed: 100,
  filesRemoved: 1)`);
- `R-CLN-4: quota eviction stops taking a blob more records share than a chunk holds when a later record is accessed, leased
  or pinned between its chunks, and frees nothing` (3 cases);
- `R-CLN-4: quota eviction skips whole a blob more records share than a chunk holds when a later record was accessed before its
  first turn`;
- `R-CLN-6: a purge takes a blob that more records share than a chunk holds one chunk of its records per actor turn`;
- `R-CLN-6: an evictable purge of a blob more records share than a chunk holds stops at a holder pinned between its chunks, the
  rest keeping the blob`;
- (`94304a0`, the turns that read the holders again, which the first coverage run showed unreached)
  `R-CLN-4: quota eviction stops taking a blob more records share than a chunk holds when an id is bound to it or a later record
  leaves it between its chunks` (2 cases: an alias `apply` adopts onto the live blob; w4 pruned by `apply`), `R-CLN-6: an
  evictable purge of a blob more records share than a chunk holds also purges an id bound to it between its chunks` (6 records
  purged, the blob reaped) and `R-CLN-6: an evictable purge of a blob more records share than a chunk holds stops at a lease
  taken between its chunks`.
Before the fix (`43ee17e`, `.build-s3c/s3c2-failing.log`): `LargeBlobTests.swift:180:9: Expectation failed: first == (2, 3)`
(the purge took all five records in one turn), the eviction tests waited out their limits (`Time limit was exceeded: 60.000
seconds`: no release between the blob's records), and the stop cases recorded their issues.

**Benchmark** (`Tests/ZTronAssetKitBenchmarks/BenchCleanup.swift`, WP-C's): `C2: quota eviction and purges hold the actor at most
10 ms at 10,000 records when five or ten ids share each blob, or all share one` now asserts all five figures
(`boundedSharedBlobOperations = Set(sharedBlobOperations)`); the one-blob figures are WP-B's probe (`ActorHoldProbe`) around
`evictIfNeeded()`, `purge(.evictable)` and `purge(.all)` on stores where all 10,000 ids share one blob (best of three). Release
run of every `CleanupBenchmarks` test after the fix (`.build-s3c/bench2.log`, load 7.95 → 15.12):
`quota eviction of every blob with 5 ids per blob 2.307542 ms (max of runs 4.910583 ms), quota eviction of every blob with 10
ids per blob 2.395833 ms (max of runs 6.762416 ms), quota eviction of one blob every id shares 3.078167 ms (max of runs
4.504417 ms), purge(.evictable) of one blob every id shares 3.559292 ms (max of runs 17.91525 ms), purge(.all) of one blob every
id shares 1.804292 ms (max of runs 2.407709 ms)`; `✔ Test run with 6 tests in 2 suites passed after 212.675 seconds.` (the
17.9 ms worst run is one of three under load; the asserted figure is the best). Before: 15.4–16.6 ms of thread CPU for the
eviction, 13.4 ms for the purge (C-22 cycle 7 (2); the review).

**`other-wp:b:` (non-blocking, routed).** `apply`'s eviction of a plan naming a blob that 10,000 ids share still evicts that blob
in one turn: `ApplyEvictionChunks` (`Store/ApplyPlan.swift`, WP-B's) cuts chunks at blob boundaries, and the synchronous hook
`applyEviction(_:)` cannot await. A fix needs WP-B's cutter to split a large blob's run across chunks and the hook to accept a
run that continues a blob (re-validated as `acrossTurnsSlice` does); no Stage 3 ruling authorises either. Cycle 2's
correctness lens re-reported it (non-blocking, `other-wp:b:`, not re-measured: the released apply benchmarks, best 2.40–3.46 ms,
cover one or two ids per blob only); its fix is WP-B's cutter plus a hook that re-validates a continuing run exactly, with the
holder check of cycle 2 below. Still routed.

**Close-out cycle 2 — exact holders in every turn (correctness lens, two BLOCKING findings, fixed).** *Finding:* a later turn
decided that the ids left were still exactly the blob's holders by comparing the blob table's reference count with their number
alone. One `apply` can prune w4 (a holder leaves) and bind w9, an essential id with the same bytes (`reused`), in the same
window: the count does not change, so the new holder was never read. The evictable purge then took every other record of a
blob the essential record keeps, freeing nothing (before its first turn with a chunk of 2, where the first turn's check over
`known[offset...]` counted the departed w4 as purgeable and never saw w9; and between turns), and quota eviction evicted the
next chunk onto the blob instead of stopping (verifier probes P1–P3, `.build-orchestrator/s3c-probes-c1/`). *Fix* (`b518df3`):
- `purgeTurnIDs` (`.evictable`): every turn reads every id left again and requires each to still reference the blob and the
  reference count to equal their number (the ids are distinct records, `PurgeSelection.select`, so no other holder fits);
  otherwise the holders are read again (`holders(of:known:scan:)`, at most one scan) and every holder is checked. The first
  turn checks every holder, as `purgeChunk` does; a later turn whose holders did not change checks its own ids. `purgeable` no
  longer counts an id that left the blob (`?? false` with the reference compared).
- `acrossTurnsSlice`: every turn requires every victim not evicted yet to still hold the blob (O(victims left)); then, the
  victims being distinct records (`EvictionOrder.plan`), as many references as victims left are exactly them; another count is
  settled by the turn's one scan, which must find no more holders than victims left (a provisional reference of a publication
  in flight passes, a bound id does not).
- Cost: O(ids left) dictionary reads per turn instead of O(`chunk`): at 10,000 ids and a chunk of 1,000, about ten turns of at
  most 10,000 reads each. Row s3c-1's and s3c-2's texts are updated below. Release run of every `CleanupBenchmarks` test after
  the fix (`swift test -c release --scratch-path .build-s3c-perf -Xswiftc -enable-testing --filter 'CleanupBenchmarks'`,
  `.build-s3c/bench3.log`, 19:08 → 19:14, load 5.94 → 6.17): `✔ Test run with 6 tests in 2 suites passed after 153.985
  seconds.`; the asserted one-blob figures (best of three; worst run in brackets) `quota eviction of one blob every id shares
  4.284375 ms (max of runs 4.363375 ms)`, `purge(.evictable) of one blob every id shares 4.690167 ms (max of runs 4.819208 ms)`,
  `purge(.all) of one blob every id shares 1.198458 ms`, against 3.08, 3.56 and 1.80 ms at cycle 1 (`bench2.log`): about 1.2 ms
  more for the per-turn reads, inside the 10 ms budget. The other figures of the file passed too (e.g. `purge(.evictable)
  after an alias was bound to every selected blob 5.809625 ms`, `quota eviction after an alias was bound to every candidate
  2.935667 ms`, `apply with an eviction plan of every blob, two ids per blob 2.25675 ms`).
- *Tests* (`4a3da14`, `Cleanup/LargeBlobTests.swift`; each asserts the swap's premises — `pruned == ["w4"]`, `reused == ["w9"]`,
  the reference count unchanged, w9 at the blob — and I-1…I-5):
  `R-CLN-6: an evictable purge keeps whole a blob whose later holder was swapped for an essential id after the selection, before
  its first turn` (chunk 1,000, `purgeChunk`'s path, the control; and chunk 2);
  `R-CLN-6: an evictable purge of a blob more records share than a chunk holds stops when a later holder is swapped for an
  essential id between its chunks, the rest keeping the blob` (purged `["w0", "w1"]`, `PurgeResult(bytesFreed: 0,
  bytesDeferred: 0, assetsRemoved: 2)`, three references: w2, w3, w9);
  `R-CLN-4: quota eviction of a blob more records share than a chunk holds evicts no record after a later record is swapped for an
  essential id, before its first turn or between its chunks` (`beforeFirstTurn`, the control: the first turn was already
  exact; `betweenChunks`: 2 evicted, `CleanupResult()`, w2 and w3 keeping the blob).
- *Before the fix* (`4a3da14` on `bcfd742`'s sources, `.build-s3c/c2-failing.log`): `✘ Test run with 11 tests in 1 suite failed
  after 0.011 seconds with 16 issues.` — `LargeBlobTests.swift:446:9: Expectation failed: await
  LargeBlobTests.purgedIDs(harness, shared).isEmpty` (chunk 2), `:447:9: … result → PurgeResult(bytesFreed: 0, bytesDeferred: 0,
  assetsRemoved: 4)`, `:482:9: Expectation failed: await LargeBlobTests.purgedIDs(harness, shared) == ["w0", "w1"]`, `:483:9: …
  result → PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 4)`, `:543:9: Expectation failed: await
  LargeBlobTests.count(harness, shared, .absent(.evicted)) == taken` (`betweenChunks`); both controls passed. *After*
  (`c2-fixed.log`): `✔ Test run with 11 tests in 1 suite passed after 0.011 seconds.`
- Decision S3C-2 stands: a blob is split only at a failed check; the swap is now one.

## S3C-3 [REQUIRED] — the two lease guards of eviction (M-S-07, M-S-08)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-3"; the close-out's "Orchestrator ruling (close-out) S3C-3").** R-CLN-5: apply skips a victim leased after the plan even when its access stamp would not stop it (the guard at
`QuotaEviction.swift:268` reached); the dry run neither names nor counts a leased blob. Kill both mutants (S3-R3).

**Disposition: tests added** (`Cleanup/LeaseTests.swift`, an extension):
- `R-CLN-5: apply skips a planned victim leased after the plan, even when no access since the plan protects it` — zero
  residency and grace, a clock that does not move, and a premise that the lease's access stamp equals the planned one, so only
  `evict`'s lease guard can refuse the victim;
- `R-CLN-5: the eviction dry run neither names a leased asset nor counts its bytes`.

**Mutants re-applied in the scratch copy** (`.build-s3c/mut/results.txt`): see "Mutant evidence" below.

## S3C-4 [REQUIRED] — the orphan grace's boundary (M-S-20)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-4"; the close-out's "Orchestrator ruling (close-out) S3C-4").** R-CLN-2: an orphan younger than the grace is kept, one exactly at the grace as the code's documented boundary says
(`OrphanCollection.swift:236`: only orphans **older** than the grace are swept). Kill the mutant.

**Disposition: test added** (`Cleanup/GarbageCollectionTests.swift`, an extension): `R-CLN-2: an orphan younger than the orphan
grace, or exactly that old, is kept; one older is doomed` (half the grace: `CleanupResult()` and no doom; exactly the grace:
the same; one second past: `CleanupResult(bytesFreed: 60, filesRemoved: 1, bytesDeferred: 0)` and doomed `unreferenced`, not
unlinked). Mutant evidence below.

## S3C-5 [REQUIRED] — joins that hang instead of failing (S3-STAB-04, S3-B-042)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-5"; the close-out's "Orchestrator ruling (close-out) S3C-5").** Every direct `.task.value`/`.result` join in `LegacyOnDemandRaceTests` preceded by a "both calls ended" poll that
ends on cancellation (L5K-R27 (1)).

**Disposition: fixed** (`f6bcf2a`). All 23 joins in the file (the ruling's :46-47, :91-92, :128-129, :163-164, :252, :289-290,
:329-330 and the confirmer's :424-426, :497, :500, plus the two close tests that already had one) now follow
`CorePoll.until("… ended") { await LegacyRace.ended(…) }` (or `finished.value` for one call); a scan of the file shows every
`.task.value`/`.task.result` with such a poll in the eight lines before it. In `batchRereadsWhatIsLeftAfterItsInstall` the two
joins keep their order (the adopt-on-demand while the sink holds the batch's install, then the batch). No assertion changed.
The ~400 other direct joins in `Tests/` are outside this ruling.

## S3C-6 [REQUIRED] — the model-based oracle never unlinked a blob (S3-CRAS-02)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-6"; the close-out's "Orchestrator ruling (close-out) S3C-6").** Include deletion work (settle/reap) in the oracle's operation sequences so blobs are really unlinked, with I-3
asserted after every step; the confirmer's mutant Z (a `fatalError` in `BlobDeletionUnit.run`) must fail it.

**Disposition: fixed.** `OracleTests` (WP-C's): a `reap` step (one draw in four) drives the deletion protocol to its end
(`settleDeletions(audited:)`: `runDueWork()`, the grace, `runDueWork()`), and every relaunch after a crash reaps too. Every
lifetime installs into `CleanupAuditSink` (`Cleanup/CleanupAuditSink.swift`, new, adapted from the hunters' `S3AuditSink`), and
I-3 is asserted after every step, after a crash and at every close over that lifetime's unlinks. The audit goes further than
the hunters' sink, because the confirmer showed theirs passed mutant G: the sink journals each install against the volume's
operation log and every clock move the test reports (`clockMoved()`), so each unlink is placed in time exactly and checked for
(1) the readers' snapshot not holding its path, (2) an acknowledged snapshot without it after the last one that held it, and
(3) the deletion grace passed on the awake clock since that acknowledgement. One lifetime in four installs into a sink that
acknowledges nothing, where no blob may be unlinked at all. Display name now `R-STO-5: seeded random store, relocate, remove,
evict, reap, crash and reopen sequences match the oracle with I-1…I-5 after every step` (16 seeds, 40 steps, unchanged). The
extra draws change the sequences each seed explores (no seed, step or assertion removed).

Run (`.build-s3c/t8.log`): unlinks per seed 2, 0, 1, 1, 3, 3, 1, 4, 5, 1, 2, 4, 2, 0, 1, 0 (34 in all); every seed passed.
Mutant evidence below (Z, and what the audit adds against C, F, S and G).

**Close-out cycle 2 (requirements lens, non-blocking, fixed in `4d02cdb`).** *Finding:* the reap was one of each seed's 40 steps
(`step()` returns `.reap` on one draw in four and `steps += 1` counted it), so each seed ran about a quarter fewer of the
operations the oracle exercised before (store, change, relocate, remove, evict, reopen), about 160 fewer over the 16 seeds; the
G3 spirit asks for the same operation mix. *Fix:* the reap is still drawn by `step()` and run, checked against the oracle, I-1…I-5
and I-3 like any step, but it is no longer counted toward the 40 (`Step.isReap`; the seed's print line counts reaps apart), so
each seed runs 40 non-reap operations, as before the reap existed. No seed, step or assertion removed; the run is longer, not
thinner. Run (`.build-s3c/oracle2.log`, load 4.94): `✔ Test run with 1 test in 1 suite passed after 0.689 seconds.`; per seed
`40 steps and` 8, 15, 17, 15, 7, 15, 9, 9, 20, 10, 11, 16, 6, 12, 9, 13 reaps (192 in all), unlinks 2, 1, 4, 3, 3, 3, 6, 4, 8, 4,
6, 5, 2, 1, 2, 5 (59 in all, against 34 when reaps were counted). Mutants Z and G re-run against it (below): both still fail.

## S3C-7 [REQUIRED] — crash at every boundary of the cleanup flows (S3-CRAS-03)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-7"; the close-out's "Orchestrator ruling (close-out) S3C-7").** Crash-point enumerations (every point, every mode) for purge(.all), purge(.evictable), quarantine, orphan GC, deep
verification, the second-extension copy and an eviction held by a lease; adapt the hunters' probe and its audit sink.

**Disposition: tests added** (`Cleanup/CleanupFlowCrashTests.swift`, new; suite `Cleanup: crash at every boundary of purge,
quarantine, orphan GC, verification, a second extension and a leased eviction (R-STO-5)`), each over `CrashMode.allCases`,
`.serialized`, yielding and checking cancellation per crash point:
- `R-STO-5: crash at every boundary during purge(.all) preserves I-1…I-5` (15 points per mode);
- `R-STO-5: crash at every boundary during purge(.evictable) preserves I-1…I-5 and keeps the essential asset` (14);
- `R-STO-5: crash at every boundary during a quarantine, its reap and the re-download preserves I-1…I-5` (22);
- `R-STO-5: crash at every boundary during orphan GC's doom and reap preserves I-1…I-5` (8);
- `R-STO-5: crash at every boundary during deep verification preserves I-1…I-5` (7);
- `R-STO-5: crash at every boundary while identical bytes are copied under a second extension, then one is removed, preserves
  I-1…I-5` (32; `copyBlob` and the placement from `.parttmp`);
- `R-STO-5: crash at every boundary during an eviction whose reap waits for a lease preserves I-1…I-5` (13).
Every lifetime (the clean reference run, each crashed run, each reopened survivor) is audited for I-3 by `CleanupAuditSink`;
each survivor is reopened with I-5 checked against the disk it loaded (`CleanupCrashTests.checkGenerations`), I-1…I-5, the
relaunch's reap, the flow's own check and convergence (every byte back). Counts match the hunters' and the confirmer's.
The hunters' kill-then-power-loss pairs for these flows were not ruled for this item and are not committed.

## S3C-8 [REQUIRED] — kill, then power loss; crash, then OS purge (S3-CRAS-04)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-8"; the close-out's "Orchestrator ruling (close-out) S3C-8").** Kill-then-power-loss pairs for legacy migration (H-10) and for an OS purge after a crash; parameterise the legacy
pairs so each case stays inside its guard under TSan (S3-R4), every pair kept.

**Disposition: tests added** (`Cleanup/CrashPairTests.swift`, new; suite `Cleanup: a crash, then a power loss or an OS purge,
before the next launch (R-STO-11, R-CLN-7)`):
- `R-STO-11: a kill at every boundary of legacy migration, then a power loss at every boundary of the next lifetime, loses no
  verified legacy file` — arguments `[.powerLossDropUnsynced, .powerLossKeepMetadata] × 0..<64` (`legacySlices = 64`, 128
  cases, every kill point in exactly one case), `.serialized`; per pair: every verified legacy file's bytes are in the tree or
  a blob, I-1…I-5 on reopen (needsHeal allowed), and the migration then finishes (`progress.finished`, asserted, and I-1…I-5
  again — the probe only ran it). Debug run (`.build-s3c/pairs-debug.log`, load 7.98 → 21.00): `✔ Test run with 1 test in 1
  suite passed after 203.553 seconds.`, 11,606 pairs over the 128 cases (the hunters' total), about 1.6 s per case.
- `R-CLN-7: a crash at every boundary of a stamped first sync, then an OS purge between launches, heals without a stale synced
  claim` — `[.processKill, .powerLossDropUnsynced] × [blobs, root, half, staging]`. The hunters' check was vacuous (`FirstSync`
  never stamps); the run here is WP-B's first sync ending with `markSynced` and a durable flush, so a kill after the stamp's
  commit leaves a persisted claim, and an OS purge that loses a blob must reset it. A premise asserts the check bites: under
  `processKill`, 7 crash points each for `blobs` and `half` left a persisted stamp over a blob the purge removed
  (`.build-s3c/t9.log`: `R-CLN-7 processKill, purge blobs: 80 crash points, 7 stamped then lost a blob`, the same for `half`).

## S3C-9 [REQUIRED] — `recordIntegrityFailure` without the presence guard (S3-B-040)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-9"; the close-out's "Orchestrator ruling (close-out) S3C-9").** `recordIntegrityFailure` gets the presence guard `recordFailure` has; a failing test first if a seam reaches the
window, otherwise record why none does.

**Disposition: fixed.** The window is one await between the engine's presence read (`sparePresent`) and the store's write; an
adoption inside it leaves the store holding a record present at the failed content, which a direct call reproduces exactly (no
engine seam needed). Failing test first (`70e1dba`): `R-INT-3: recordIntegrityFailure leaves a record present at the failed
content unchanged, and still fails a stale one` (`maxIntegrityAttempts: 1`), failing on `s3-base` with `↳ a record present at
the failed content is left unchanged: Optional(…Residency.failed(…FailureReason.integrity))`, the blob doomed and the location
gone (`.build-s3c/s3c9-failing.txt`). Fix (`100d1c2`): `if record.referencedBlob != nil, !record.isStale { continue }`, as
`recordFailure` (L4-R16); doc comment updated. In the same commit the test reads the mutation count before its stale call
(the failing commit read it after, where the stale record's commit counts). **Retarget (WP-C's own test, assertions
unchanged):** `EvictionOverlapTests.releaseWhileCandidatesRun(.integrityFailures)` reported three integrity failures for a
record present at its current content, which the guard now spares; like its `.failure` case (L4-R16), it now changes o9's entry
first and reports the failures for the new content against the stale record, which still ends `failed(.integrity)` with its old
blob doomed `unreferenced`; every expectation is the same. No other caller relies on the old behaviour (the engine spares
present records itself; `IntegrityTests`' other cases use absent or quarantined records).

## S3C-10 [REQUIRED] — the comment above L5K-R17's wait (S3-B-039)

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-10"; the close-out's "Orchestrator ruling (close-out) S3C-10").** Comment
fix at `Migration/LegacyPhases.swift:426-431` (ARCHITECTURE §4.7 (3)).

**Disposition: fixed** (`1ffe5ab`): `Migration/LegacyPhases.swift`'s comment now names the return with `remaining > 0` when a
processing it waited for ended without an outcome for its file (ARCHITECTURE §4.7, level-5 WP-K amendment (3)). Comment only.

## S3C-11 [ADR-RECORD] — records

**Ruling (recorded as "Orchestrator ruling (Stage 3) S3C-11"; the close-out's "Orchestrator ruling (close-out) S3C-11").**
Record S3-B-026, S3-B-027, S3-B-031, S3-B-035, S3-B-028, S3-B-029, S3-B-030, S3-B-032, S3-B-033, S3-B-041, S3-B-036, S3-B-037 and
S3-B-038: S3-B-026 (OI-4) within C2 at 10,000, the async contract change declined for Stage 3; S3-B-027 OPTIONAL fix only if
C-24's serial fits inside WP-C's files; S3-B-035 audited by reading, with the audit table recorded; the NEEDS-HUMAN-REVIEW items
stay as ratified.

- **S3-B-026 (OI-4).** The synchronous dry run `evictionPlan(toFree:protecting:)` holds the actor about 2.5 ms at 10,000 records
  (this close-out's release run, `.build-s3c/bench2.log`: `dry run of the whole store 2.557625 ms (worst 2.6865 ms)` at 10,000,
  `40.56875 ms` at 100,000, recorded), within C2 at the reference scale. Moving it off the actor needs an async signature (a contract change with WP-F): declined for Stage 3, as
  ruled. No code.
- **S3-B-027 (C-24, R9).** Phase 3 can stay undecided under continuous access stamps (this run: `3 last calls, finished: false,
  16562 stamps` at 10,000 files; 28,657 at 100,000); RE-S29 and ruling R9 make the caller retry later. The OPTIONAL fix (C-24's
  serial bumped only by presence-reducing mutations) needs a new field in WP-B's `CommitBookkeeping` and bumps in WP-B's
  writers: it does not fit inside WP-C's files, so it is not made.
- **S3-B-035 — audit of `commits.mutationSerial`.** Read in this close-out: the serial is bumped only by `markDirtyInternal`
  (`Store/AssetStore+Commit.swift:14`). Every writer of persisted state, and whether it bumps in its own turn:

  | Writer (file) | Persisted state | Bumps in its turn | Presence-reducing for a legacy record | Phase 3 covered by |
  |---|---|---|---|---|
  | `setResidencyInternal` (`AssetStore+References`) — every WP-C doom (eviction, purge, quarantine, failures, legacy) and WP-B's | record residency, blob table | yes (`.soon`) | yes | the serial |
  | `bindRecords` (`AssetStore+References`) — publication, legacy adoption | records made present | yes (`.soon`) | no | — |
  | `recordAccessesInternal` (`AssetStore+Snapshot`) | `lastAccess` (STAMPS) | yes (`.lazy`) | no | the serial (S3-B-027's liveness) |
  | `performAdmit` (`AssetStore+Apply`) | one record | yes | no (an upsert of one entry) | — |
  | `performMarkSynced`, `performMarkSyncDue` | stamp, `syncDue` | yes | no | — |
  | `reap` (`AssetStore+Reaper`), `doomOrphans` (`StoreInternals`) | blob table | yes | no (doomed or unknown keys hold no record) | — |
  | `installLoadedState` (`AssetStore+Open`) | everything | yes | — | runs inside `open()` (phase `opening`) |
  | `acquireReference`, `releaseReference`, `dropProvisionalReference`, `placeAndBind`, `startGrace`, `confirmOrphans` | blob table, `publishing`, doom grace, orphans | through their callers' `setResidency`/`bindRecords`, or not at all | no record presence | — |
  | WP-C's `setPinned`, `recordFailure`, `recordIntegrityFailure`, quarantine, purge, eviction, legacy phases | records | yes (through `setResidency`/`markDirty`) | yes | the serial |
  | **`performApply`** (`AssetStore+Apply`: `applyDiff`, `adoptKnownBlob`, `prune`, `applyEvictionInChunks`) | applied manifest, ETag, records | **no: once, in its last writing turn**, after writes spread over turns (`pace`, 512 items) behind the commit fence | yes (`prune`, `changeContent`) | the manifest digest: `applyDiff` installs the new applied manifest in its first writing turn, before any record changes, and `finishLegacyMigration` compares `manifestDigest` with it in the turn after the pass, so any `apply` that changed a record meanwhile makes phase 3 refuse the stamp; an `apply` of the same manifest has an empty diff (nothing pruned or changed; adoptions only add presence) |

  Result: no gap that phase 3's decision can fall into; the one writer that does not bump in its turn is covered by the digest
  check, which the code comment on `legacyEntriesPresent` now says (WP-C's file, comment only). For the orchestrator:
  `StoreCoreState.swift:130`'s note ("which every persisted change bumps") is WP-B's and overstates the same way; a one-line
  precision there is proposed below.
- **S3-B-028 (C-12), S3-B-029 (C-13), S3-B-030 (C-14), S3-B-031 (OI-11, C-14 cycle 2), S3-B-032 (C-15) — NEEDS-HUMAN-REVIEW, as
  ratified.** Unchanged; the decisions and their reasons stand as recorded in `docs/adr-drafts/c.md` and ADR-052. S3-B-031's
  persisted per-file deferral count would need a STAMPS field in WP-B's codec (a CCR); not made.
- **S3-B-033 (C-2, C-4, C-6).** Accepted by ruling (ADR-052); unchanged.
- **S3-B-041.** The doom exception to L5K-R20 (a doom's removal-only install runs ahead of the failure's ordered commit; I-3 keeps
  the bytes until a snapshot without the asset is acknowledged) stays as recorded in ADR-055; `IntegrityBookkeeping.swift`
  unchanged. S3C-9's guard does not change it (it only skips present records).
- **S3-B-036, S3-B-037, S3-B-038 — device-only.** Listed under "Not verified here".

## Mutant evidence (S3-R3)

Re-applied in a scratch copy of this branch's working tree (`.build-s3c/mut/src`, its own scratch `.build-s3c/mut/build`;
`.build-s3c/mut/run-mutants.sh`, results in `.build-s3c/mut/results.txt`). The M-S diffs from `.build-orchestrator/s3-mutants/
storage/` applied cleanly (one build each, then reverted); the confirmers' environment-switched diff
(`confirm-crash/S3-CRAS-02-03-confirm-mutants.diff`, `S3MUT=<letter>`) was applied once.

- **M-S-07** (no lease re-check in `evict`): `LeaseTests.swift:387:9: Expectation failed: report.evicted.isEmpty` and `:388:9:
  Expectation failed: await harness.isPresent(asset.id, at: asset.key) && harness.hasBlob(asset.key)` — killed.
- **M-S-08** (the dry run's ranking keeps leased blobs): `LeaseTests.swift:409:9: Expectation failed: beyond == nil` — killed.
- **M-S-20** (age compared with 0): `GarbageCollectionTests.swift:622:9: Expectation failed: inside == CleanupResult() &&
  insideDoom == nil`, `:623:9: … atGrace …`, `:624:9: … past …` — killed.
- **Z** (`fatalError` in `BlobDeletionUnit.run`): `OracleTests` → `ZTronAssetStorage/BlobUnits.swift:169: Fatal error: S3MUT Z: a
  blob deletion unit ran` (the shipped oracle passed it); `CleanupFlowCrashTests` too — killed.
- **X** (`fatalError` in `copyBlob`): `CleanupFlowCrashTests` → `AssetStore+Publish.swift:358: Fatal error: S3MUT X: copyBlob ran`
  (every shipped test passed it) — killed.
- **G** (`deletionBlocker` answers `.none` for every doomed key: no acknowledgement, commit, lease or grace check), which the
  confirmer found no audited probe detected: `OracleTests` 235 issues, e.g. `seed 1, lifetime crash Optional(65)
  powerLossDropUnsynced, unacknowledged: … ["I-3: op 59 unlinked 629df459….png before a snapshot without it was
  acknowledged"]`; `CleanupFlowCrashTests` 363 issues, e.g. `["I-3: op 83 unlinked 77e0635e….png 0.0 s after the
  acknowledgement, inside the 10.0 s grace"]` — killed by the grace- and acknowledgement-aware audit.
- **C** (the reaper ignores the commit blocker), **F** (no acknowledged snapshot needed) and **S** (no grace) still pass the
  oracle and the flows: each is masked by another guard of `deletionBlocker` (F and S by the fresh acknowledged install after
  the deadline, which an unacknowledging sink never gives and which comes only after the grace; C by the flush that ends every
  oracle step), as the confirmer noted; each is killed by WP-B's targeted tests (`StoreDeletionTests`, `LeaseTests`,
  `StoreRecoveryTests`; the confirmer's runs). The hunter's further suggestion (commit faults inside the sequences, to reach C)
  is not part of the ruling and is not made.
- Baselines in the same copy without a mutant: `OracleTests` passed (0.580 s), `CleanupFlowCrashTests` passed (7 tests, 0.914 s).
- **Cycle 2** (the oracle with reaps drawn between its 40 operations, `4d02cdb`): the same scratch copy, the cycle-2 files copied
  in (`OracleTests.swift`, `LargeBlobTests.swift`, `StorePurge.swift`, `QuotaEviction.swift`; every other file changed since
  `bcfd742` compared equal), the environment-switched diff still applied (`.build-s3c/mut/run-oracle-c2.sh`, results in
  `.build-s3c/mut/results-c2.txt`): baseline `✔ Test run with 1 test in 1 suite passed after 0.883 seconds.`; **Z**
  `ZTronAssetStorage/BlobUnits.swift:169: Fatal error: S3MUT Z: a blob deletion unit ran` — killed; **G** `✘ Test run with 1 test
  in 1 suite failed after 0.756 seconds with 333 issues.`, e.g. `seed 1, lifetime crash Optional(65) powerLossDropUnsynced,
  unacknowledged: after ["add m1", "reopen", "publish m1", "evict m1", "reap"]: ["I-3: op 59 unlinked 629df459….png before a
  snapshot without it was acknowledged"]` — killed.

## Proposed REENTRANCY rows (ARCHITECTURE §10.1)

| Row | Await | Re-validated afterwards |
|---|---|---|
| s3c-1 | quota eviction's no-op metadata unit between the turns of one blob of more records than a chunk (`evictAcrossTurns`, `Eviction/QuotaEviction.swift`; Stage 3 ruling S3C-2) | the phase and writability; then the turn's check (`acrossTurnsSlice`): the blob still live, unleased and not being placed; exactly the victims not evicted yet hold it (each of them read again and still holding it, O(victims left), and the blob table's reference count equal to their number, else `holders(of:known:scan:)`, at most one scan of the records, finding no other holder); this turn's victims still hold it, are evictable under rules whose clock is read again and were not accessed since the selection. A failed check stops the blob: the records evicted in earlier turns stay evicted (`stillReferenced`), nothing is released. The caller's next candidate starts a chunk of its own after a release, with rules and a scan read again |
| s3c-2 | purge's no-op metadata unit between the turns of one blob of more records than a chunk (`purgeAcrossTurns`, `Cleanup/StorePurge.swift`; S3C-2) | the phase and writability; `.all`/`.scope`: each of the turn's records still references the blob; `.evictable` (`purgeTurnIDs`): the blob still live, unleased and not being placed; the ids left exactly its holders (each still references it, O(ids left), and the reference count equals their number); the turn's holders neither essential nor pinned (on the first turn, and whenever the ids left are not exactly the holders, every holder, read again); a failed check stops the blob, earlier turns' records staying purged; the blob is waited for once and its bytes count toward `releasedBytes` in the turn it is doomed |

Both cite "s3c-n (proposed)" in the code. R8 and c-5 may point to them ("a blob of more records than a chunk: s3c-1 / s3c-2").

## Authorised edits outside WP-C

None (cycles 1 and 2). Every changed file is WP-C's (`Sources/ZTronAssetStorage/{Eviction,Cleanup,Integrity,Migration}/**`,
`Tests/ZTronAssetStorageTests/Cleanup/**`, `Tests/ZTronAssetKitBenchmarks/BenchCleanup.swift`, this draft). The S3C-1
authorisation for WP-B `Core/` sites was not needed (no `Core/` test holds a poll of the class). The new tests reference WP-B's
test helpers (`CorePoll`, `CoreHarness.make`, `FirstSync`, `CoreInvariants`) without changing them.

## Proposed document changes (for the orchestrator at the Stage 3 merge)

- **ARCHITECTURE §10.1:** rows s3c-1 and s3c-2 above; R8's and c-5's text gain "a blob of more records than a chunk is taken
  a chunk of records per turn (s3c-1, s3c-2)".
- **ARCHITECTURE §4.6:** quota eviction "…marked in chunks of whole blobs…" → add: "a blob of more records than a chunk is a
  chunk of its own, taken a chunk of records per turn; its first turn checks every record, a later turn that the records left
  are exactly the blob's holders (each still holds it and the reference count matches) and its own records, and a failed check
  stops the blob, the records already taken staying evicted on the live blob (Stage 3 ruling S3C-2)"; purge "applied in chunks that end at blob boundaries" → the same exception for a blob of more
  records than a chunk.
- **ARCHITECTURE §1.1** (the `Integrity/` row): `recordIntegrityFailure` "(which, like `recordFailure`, leaves a record bound to
  a live blob at `identity` unchanged; Stage 3 ruling S3C-9)".
- **ARCHITECTURE §11 / §12:** S3-B-025 closed (ruling R8's recorded exception ended for quota eviction and purge; `apply`'s hook
  routed to WP-B); S3-STAB-01/02/04, S3-B-034, S3-B-039, S3-B-040, S3-B-042, S3-CRAS-02/03/04, M-S-07/08/20 closed.
- **ARCHITECTURE §14:** "Not verified here" additions below.
- **`StoreCoreState.swift:130`** (WP-B's, comment only, if the orchestrator agrees): "which every persisted change bumps" →
  "which every persisted change bumps in its own turn, except `apply`'s fenced writes, bumped in its last writing turn (phase 3
  relies on the manifest digest for those; S3-B-035)".
- **DECISIONS.md:** one ADR for this close-out (S3C-1 helper; S3C-2 decision; S3C-9 guard; the audit sink).
- **`docs/TRACEABILITY.md`:** regenerated at merge (new test names; the oracle's renamed).

## Not verified here

- S3C-2's per-turn costs on a device (macOS release with the fake file system only; S3-B-038's list gains "a blob of more
  records than a chunk taken across turns").
- `apply`'s eviction hook for a blob that 10,000 ids share (still one turn; `other-wp:b:` above).
- S3-B-036: legacy migration on a device (Caches → Application Support on one APFS volume, a root on another volume,
  `LiveLegacyDefaults`, Unicode normalisation or case differences, the overlap guard's identity walks, sandbox stat refusals,
  phase 3's ordered vs durable commit, OI-2).
- S3-B-037: deep verification's incarnation check against a real rename-over on APFS (inode reuse).
- S3-B-038: C-22's actor holds, `apply`'s chunked eviction, a purge's wait for another reaper's deletion (a kernel-blocked
  unlink) and the holders-scan prefilter's even-spread assumption, on a device.
- The kill-then-power-loss pairs model a power loss with the fake's two modes only (`powerLossDropUnsynced`,
  `powerLossKeepMetadata`); real APFS ordering is not modelled.

## Final runs (cycle 1)

Host: macOS 27, Xcode 27.0; loads as printed by `uptime` before and after each run (other agents' runs loaded the host, at times
heavily). Logs under `.build-s3c/`. The runs below were made at `2269d7c`; `94304a0` then added three tests to
`LargeBlobTests` (no source change), and the runs that execute tests were repeated at `94304a0` (listed after them).

- `SWIFTPM_SCRATCH=.build-s3c bash Scripts/verify.sh --quick` (`quick.log`, at `2269d7c`, load 7.49 → 16.43): `✔ Test run with 478
  tests in 64 suites passed after 258.533 seconds.` (Storage), every other bundle passed (151, 351, 84, 85, 71, 104 tests),
  `VERIFY: PASS`.
- `swift build -c release --scratch-path .build-s3c -Xswiftc -warnings-as-errors` (`release.log`): `Build complete! (58,12 s)`.
- `python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md`: `UNSAFE escapes found=0 max=3`,
  `UNSAFE: PASS`; `python3 Scripts/gates.py docs --sources "$PWD/Sources"`: `DOCS public declarations=1281 documented=1281
  exempt=0 fraction=100.0%`, `DOCS: PASS`.
- iOS library build (`xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3c/xcode
  build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, `ios-build.log`): exit 0, products in
  `.build-s3c/xcode/Build/Products/Debug-iphoneos/` (the one log line is `IDERunDestination: Supported platforms for the
  buildables in the current scheme is empty.`, the benign line `l2close.md` and `l2fu.md` record).
- `swift test --scratch-path .build-s3c-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetStorageTests` (`tsan-run.log`,
  15:50 → 16:05, load 12.30 → 10.11, the 5- and 15-minute averages 42.07 and 55.10 at the end: other agents' runs): `✔ Test run
  with 478 tests in 64 suites passed after 852.844 seconds.`, 0 `✘`, 0 ThreadSanitizer reports. Durations under TSan for S3-R4
  (each case's `.timeLimit` is one minute; every test below is `.serialized`, so a case's time is the test's divided among its
  cases): the legacy pairs 852.8 s for 128 cases (6.7 s per case on average; the largest case has 143 pairs against 90.7 on
  average, so about 10.5 s), the OS-purge pairs 47.8 s for 8 cases, the oracle 37.5 s for 16 seeds, the flow enumerations at
  most 21.2 s for 4 modes (`purge(.all)`). No case reached half its limit, so no guard was raised.
- iOS Simulator (ADR-051; `caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS Simulator,id=02CE21B4-…'
  -derivedDataPath .build-s3c/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never
  OTHER_SWIFT_FLAGS='-warnings-as-errors'`, `sim.log`, 16:06 → 16:15, load 15.96 → 29.86 with 5- and 15-minute averages up to 92
  and 88 from other runs on the host): `** TEST SUCCEEDED **`; `xcresulttool get test-results summary`: `result: Passed,
  totalTestCount: 1324, passedTests: 1324, failedTests: 0, skippedTests: 0`, device `iPhone 17e`, iOS 27.0. The simulator was
  shut down afterwards (xcodebuild had already shut it down).
- `swift test --scratch-path .build-s3c --skip Benchmarks --filter ZTronAssetStorageTests`, three times (`storage3.log`,
  `storage-run{1,2,3}.log`, 16:06 → 16:22, loads 15.96 → 37.60 → 13.70 → 4.98, 5-minute averages up to 116.59 from the host's
  other runs): `✔ Test run with 478 tests in 64 suites passed after 345.450 seconds.`, `… 309.072 seconds.`, `… 190.630
  seconds.`; 0 `✘` in each.
- S3C-1's evidence again at the head (`.build-s3c/rep2/`, the bundles of this head): debug `--repetitions 200` over the 13 suites
  (the 12 above and `LargeBlobTests`, which uses the helper): `✔ Test run with 130 tests in 13 suites passed after 162.800
  seconds.`, repetition 200 reached, 0 `✘` (load 4.37 → 65.89); TSan `--repetitions 20`: `✔ Test run with 130 tests in 13 suites
  passed after 74.709 seconds.`, 0 `✘`, 0 ThreadSanitizer reports (load → 61.86); `phaseFourStopsListing` in 50 fresh TSan
  launches: 50 × `exit 0`, 50 passes, 0 `✘`, 0 reports (load 58.23 → 49.76).

At `94304a0` (the three added `LargeBlobTests` tests; no source change since `2269d7c`, so the release build, the iOS library
build and the unsafe and docs gates above stand):
- `SWIFTPM_SCRATCH=.build-s3c bash Scripts/verify.sh --quick` (`quick2.log`, 16:45 → 16:55, load 46.94 → 245.60): `✔ Test run
  with 481 tests in 64 suites passed after 333.491 seconds.` (Storage), every other bundle passed (151, 351, 84, 85, 71, 104),
  `VERIFY: PASS`.
- TSan, first attempt (`tsan-run2.log`, 16:56 → 17:12, load 260.35 at the start from another agent's simulator run at ~700 % CPU):
  `✘ Test run with 481 tests in 64 suites failed after 937.698 seconds with 1 issue.` — the one issue is WP-H's `Test support:
  start racing stop ends every start exactly once, with a port or stopped, and never hangs`
  (`LoopbackHTTPServerTests.swift:400:6: Time limit was exceeded: 60.000 seconds`), the TSan-headroom environment item ADR-052
  records for that test (orchestrator note at the L3 close-out cycle 7: TSan on an idle host); every WP-C test passed, 0
  ThreadSanitizer reports. Re-run once the host was quiet (below).
- TSan, re-run (`tsan-run3.log`, 17:12 → 17:23, load 2.52 → 2.75): `✔ Test run with 481 tests in 64 suites passed after 628.982
  seconds.`, 0 ThreadSanitizer reports; the legacy pairs 628.979 s for 128 cases (4.9 s per case on average, about 7.7 s for the
  largest), well under half the one-minute guard.
- Coverage (`swift test --scratch-path .build-s3c --enable-code-coverage --skip Benchmarks`, `cov2.log`, from 17:24, load 2.56;
  every bundle passed, Storage `481 tests in 64 suites passed after 281.729 seconds`; `llvm-cov export -summary-only` over the
  seven test binaries other than the benchmarks into `.build-s3c/cov2.json`; `python3 Scripts/gates.py coverage --json
  .build-s3c/cov2.json`): `COVERAGE target=ZTronAssetStorage lines= 97.35% (8295/8521) min=90.0 OK`, `COVERAGE overall
  lines=96.56% (25310/26212) min=80.0 OK`, `COVERAGE: PASS`. Changed files: `StoreIntegrity.swift` 85/85, `QuotaEviction.swift`
  366/378, `StorePurge.swift` 359/366. New lines left unreached, all defensive: `evictAcrossTurns`' guard for an empty victim
  list and `purgeTurnIDs`' guard for an offset past the end (callers never pass either), `purgeTurnIDs`' "an id that left the
  blob" answer on the fast path (needs a leaver and a joiner that cancel in the reference count) and its stop after re-reading
  the holders (needs a pinned or essential id bound between two turns).
- Storage tests in debug at `94304a0`, three runs: the `--quick` run (`333.491 seconds`), the coverage run (`281.729 seconds`)
  and `swift test --scratch-path .build-s3c --skip Benchmarks --filter ZTronAssetStorageTests` (`storage-run4.log`, 17:30 →
  17:34, load 12.60 → 7.26): `✔ Test run with 481 tests in 64 suites passed after 194.940 seconds.`, 0 `✘`.
- iOS Simulator at `94304a0` (`sim2.log`, 17:24 → 17:30, load 2.56 → 19.20 with a 5-minute average of 89.97 from other runs):
  `** TEST SUCCEEDED **` (exit 0); `result: Passed, totalTestCount: 1327, passedTests: 1327, failedTests: 0, skippedTests: 0`,
  `iPhone 17e`, iOS 27.0; the simulator shut down afterwards.
- `LargeBlobTests` and `PollReleaseTests` at `94304a0` (`.build-s3c/rep3/`, load 6.45 → 7.53): debug `--repetitions 200`: `✔ Test
  run with 9 tests in 2 suites passed after 1.104 seconds.`, 0 `✘`; TSan `--repetitions 20`: `✔ Test run with 9 tests in 2
  suites passed after 0.345 seconds.`, 0 `✘`, 0 reports.
- Benchmarks (`swift test -c release --scratch-path .build-s3c-perf -Xswiftc -enable-testing --filter 'CleanupBenchmarks'`,
  `bench2.log`, 15:25 → 15:31, load 7.95 → 15.12), run on this branch's final `QuotaEviction.swift` and `StorePurge.swift` (the
  later source changes are `recordIntegrityFailure`'s guard and comments, which no benchmark measures): `✔ Test run with 6
  tests in 2 suites passed after 212.675 seconds.`; the shared-blob figures are under S3C-2, and every other WP-C C2 figure
  passed its assertion (e.g. at 10,000 assets `quota eviction after an alias was bound to every candidate 3.835125 ms`,
  `purge(.evictable) after an alias was bound to every selected blob 7.122 ms`, `apply with an eviction plan of every blob, two
  ids per blob 3.999417 ms`, best of three).
- `docs/TRACEABILITY.md` was not regenerated here (`--gates-only`/`--full` not run), so there is nothing to restore.

## Final runs (cycle 2, head of `wp/s3c`)

Made at `4d02cdb` (every source and test change of cycle 2; the draft commit after it changes only this file). Host: macOS 27,
Xcode 27.0; loads as printed by `uptime` before and after each run (other agents' runs loaded the host, at times heavily). Logs
under `.build-s3c/c2runs/` (`runs-c2.sh`, sequential; `summary.txt`).
- `SWIFTPM_SCRATCH=.build-s3c bash Scripts/verify.sh --quick` (`quick.log`, 19:14 → 19:21, load 5.45 → 6.61): `✔ Test run with 484
  tests in 64 suites passed after 295.734 seconds.` (Storage), every other bundle passed (151, 351, 84, 85, 71, 104 tests),
  `VERIFY: PASS`.
- `swift build -c release --scratch-path .build-s3c -Xswiftc -warnings-as-errors` (`release.log`): `Build complete! (46,03 s)`.
- `python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md`: `UNSAFE escapes found=0 max=3`,
  `UNSAFE: PASS`; `python3 Scripts/gates.py docs --sources "$PWD/Sources"`: `DOCS public declarations=1281 documented=1281
  exempt=0 fraction=100.0%`, `DOCS: PASS`.
- `swift test --scratch-path .build-s3c --skip Benchmarks --filter ZTronAssetStorageTests`, three times (`storage{1,2,3}.log`,
  19:22 → 19:35, loads 39.72 → 43.52 (5-minute average 133.35) → 6.86 → 6.52): `✔ Test run with 484 tests in 64 suites passed
  after 266.521 seconds.`, `… 226.628 seconds.`, `… 209.635 seconds.`; 0 `✘` in each.
- Coverage (`swift test --scratch-path .build-s3c --enable-code-coverage --skip Benchmarks`, `coverage.log`, 19:51 → 19:57, load
  4.83 → 8.47; every bundle passed, Storage `484 tests in 64 suites passed after 225.821 seconds`; `llvm-cov export
  -summary-only` over the seven test binaries other than the benchmarks into `.build-s3c/cov3.json`; `python3 Scripts/gates.py
  coverage --json .build-s3c/cov3.json`): `COVERAGE target=ZTronAssetStorage lines= 97.41% (8305/8526) min=90.0 OK`, `COVERAGE
  overall lines=96.57% (25317/26217) min=80.0 OK`, `COVERAGE: PASS`. Changed files: `StorePurge.swift` 363/368, `QuotaEviction.swift`
  369/381. Lines left at 0 in them (`llvm-cov show`): `purgeTurnIDs`' guard for an offset past the end and `evictAcrossTurns`'
  guard for an empty victim list (callers never pass either), `holders(of:known:scan:)`'s answer for a blob no longer live,
  `purgeChunk`'s skip of a blob with an unpurgeable holder (`:137`) and `purgeAcrossTurns`' skip of a selected record that no
  longer holds the blob (`:180`: since cycle 2 every `.evictable` id is read as a holder in the same turn, so only a record of
  `.all` or `.scope` that left between turns reaches it). No line cycle 2 added or changed is left at 0.
- iOS library build (`xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3c/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, `ios.log`): exit 0, `ZTronAssetStorage.o` rebuilt at 19:57 in
  `.build-s3c/xcode/Build/Products/Debug-iphoneos/` (the one log line is the benign `IDERunDestination: Supported platforms for
  the buildables in the current scheme is empty.`).
- iOS Simulator (ADR-051; `caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS Simulator,id=02CE21B4-…'
  -derivedDataPath .build-s3c/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never
  OTHER_SWIFT_FLAGS='-warnings-as-errors'`, `.build-s3c/sim3.log`, 19:58 → 20:06, load 8.12 → 489.77 from other agents' runs):
  `** TEST SUCCEEDED **` (exit 0); `xcresulttool get test-results summary` (`Test-ZTronAssetKit-2026.10.29_19-58-01-+0100.xcresult`):
  `result: Passed, total: 1330, passed: 1330, failed: 0, skipped: 0`, `iPhone 17e`, iOS 27.0. The simulator was already shut
  down afterwards (`simctl shutdown`: `Unable to shutdown device in current state: Shutdown`; `simctl list`: `(Shutdown)`).
- Benchmarks (release, `.build-s3c/bench3.log`, load 5.94 → 6.17): `✔ Test run with 6 tests in 2 suites passed after 153.985
  seconds.`; figures under S3C-2, "Close-out cycle 2".
- `OracleTests` (`.build-s3c/oracle2.log`) and mutants Z and G (`.build-s3c/mut/results-c2.txt`): under S3C-6 and "Mutant
  evidence".
- `swift test --scratch-path .build-s3c-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetStorageTests`, first run
  (`tsan.log`, 19:35 → 19:51, one-minute load 6.52 → 4.83, the 5-minute average 38.08 → 10.15 and the 15-minute 55.66 → 27.53 from
  the host's other runs): `✘ Test run with 484 tests in 64 suites failed after 895.818 seconds with 1 issue.` — the one issue is
  WP-H's `Test support: start racing stop ends every start exactly once, with a port or stopped, and never hangs`
  (`LoopbackHTTPServerTests.swift:400:6: Time limit was exceeded: 60.000 seconds`), the TSan-headroom environment item ADR-052
  records for that test (cycle 1's first TSan attempt met the same); every WP-C test passed, 0 ThreadSanitizer reports. Durations
  for S3-R4: the legacy pairs `with 128 test cases passed after 895.812 seconds` (7.0 s per case on average; slice 0, 143 pairs,
  about 11 s), the OS-purge pairs 54.0 s for 8 cases, the oracle (now 40 operations and the reaps per seed) 45.3 s for 16 seeds,
  the flow enumerations' suite 20.8 s: no case near half its one-minute guard.
- TSan, second run (`tsan2.log`, 20:17 → 20:49; per-minute samples in `tsan2-samples.txt`: one-minute load 19 → 48 by 20:23,
  then 221, 445, **602**, 598, 484, 426, 383, 357 from 20:24 to 20:31 (other agents' builds, TSan and simulator runs), back to
  10–40 by 20:44): `✘ Test run with 484 tests in 64 suites failed after 1854.087 seconds with 2136 issues.`, 0 ThreadSanitizer
  reports. Every issue is a time limit or what follows one, none a logic failure: 7 cases of WP-C's legacy pairs
  (`.powerLossDropUnsynced`, slices 0, 5, 6, 7, 8, 9, 11; `CrashPairTests.swift:40:6: Time limit was exceeded: 60.000 seconds`,
  one issue each, the enumeration ending at its `Task.checkCancellation()`), 8 cases of WP-B's `killThenPowerLoss`
  (`StoreCrashTests.swift:167:6`) followed by 2,118 `.cancelled` issues from its catch (`:114`, the `other-wp:b:` item above,
  seen again), one case each of WP-B's `IndexCommitStateSpaceTests` (`:222:6`, `:328:6`) and WP-H's `LoopbackHTTPServerTests`
  (`:400:6`). This is the load the verifiers met, far outside S3-R4's envelope (about 30): recorded, nothing raised or cut.
- TSan, third run (`tsan3.log`, 20:49 → 21:06; samples in `tsan3-samples.txt`: one-minute load 13 → 74 by 20:55, then 125, 336,
  **465**, 366, 139 from 20:56 to 21:00, back to 5 by 21:05): `✘ Test run with 484 tests in 64 suites failed after 994.755 seconds
  with 359 issues.`, 0 ThreadSanitizer reports. **Every WP-C test passed**, the legacy pairs included (`with 128 test cases
  passed after 994.749 seconds`, 7.8 s per case on average through the spike) and the oracle (`with 16 test cases passed after
  74.909 seconds`). The issues are other work packages' time limits: WP-B's `killThenPowerLoss` (8 cases at
  `StoreCrashTests.swift:167:6`, then 350 `.cancelled` issues at `:114`) and WP-H's `LoopbackHTTPServerTests.swift:400:6`, both
  already routed or recorded (above; ADR-052). No quiet window long enough for a fully clean storage TSan run came up in this
  cycle; the first run (one-minute load 4.8–6.5) is the cycle's measurement for S3-R4.
