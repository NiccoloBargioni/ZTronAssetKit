# Stage 3 close-out `s3f` — WP-F (sync engine), cycles 1 and 2

Branch `wp/s3f` from tag `s3-base`. Rulings: `.build-orchestrator/s3-rulings-s3f.md`; findings:
`.build-orchestrator/s3-findings-s3f.json`. WP-F's Stage 2 record is `docs/adr-drafts/f.md` (background only).

## Orchestrator rulings (close-out)

Each ruling below is recorded as given in the rulings file and applied in cycles 1 and 2. Cycle 2 applied them again to
the cycle-1 verifiers' findings (the section "Cycle 2" below); no ruling changed, and no new ruling was issued, so S3F-13
is implemented rather than demoted.

- **Orchestrator ruling (close-out) S3-R1, scope and order.** Blocking items first (failing test committed on its own,
  then the fix), then REQUIRED, then OPTIONAL; ADR-RECORD items get an entry here and no code; items not listed are out
  of scope. Applied: S3F-1 to S3F-5 first, each test commit before its fix commit.
- **Orchestrator ruling (close-out) S3-R2, probes.** Probes and mutant diffs are evidence to copy and adapt; committed
  tests follow SPEC 7.2 (requirement-ID display names, `.timeLimit` on anything that awaits, `ManualTimeSource`, no
  sleeps) and the iOS gating convention (ADR-051, `docs/adr-drafts/ios.md` item 2); probe suites are renamed into the
  owning suites; replays of a bug's old order are not committed. Applied: every new test is an extension of an owning
  suite (`EngineConditionsTests`, `EngineFailurePathTests`, `EngineEventsTests`, `EngineLaneTests`, `EngineSupportTests`,
  `EngineRecoveryTests`, `EngineGroupClaimTests`, `EngineIdleTests`, `EngineSyncTests`, `EngineRegressionTests`), every
  test that uses a Mutex-backed fake carries `@available(macOS 15.0, iOS 18.0, *)` on the `@Test` function.
- **Orchestrator ruling (close-out) S3-R3, mutation survivors.** Each surviving mutant assigned here has a test, and the
  mutant's diff was re-applied in a scratch copy (`.build-s3f/mut/src`, its own build path) to show the test fails; the
  failing lines are pasted under each item.
- **Orchestrator ruling (close-out) S3-R4, hang guards.** `.minutes(1)` by default; raised to `.minutes(3)` (or
  `.minutes(5)` for a model-based walk) only for a test measured above half its limit under TSan on a moderately loaded
  host, with the measurements recorded; never by cutting work; long loops check cancellation. Applied in S3F-2.
- **Orchestrator ruling (close-out) S3-R5, C2 at the reference scale.** A turn over 10 ms at 10,000 is fixed by bounding
  the work per turn or moving computation off the actor, pinned by a `c2Budget` benchmark in `BenchSync.swift` and, where
  possible, a structural unit test; a miss caused only by load is not blocking. Applied in S3F-4, S3F-5 and S3F-15.
- **Orchestrator ruling (close-out) S3-R6, shared files.** No public or package signature change; no edit of
  `Package.swift`, `Scripts/`, `SPEC.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/TRACEABILITY.md`,
  `docs/ORCHESTRATION.md`, `README.md`, `docs/MIGRATION.md` or any `*ContractTests.swift`; document changes are proposed
  below. Applied: none of those files changed (the backoff tests the mutation agent suggested for
  `SyncContractTests.swift` live in `EngineBoundaryTests.swift`).
- **Orchestrator ruling (close-out) S3-R7, parallel close-outs.** Only WP-F's files (ARCHITECTURE §1.2), nothing that
  depends on another work package's Stage 3 change. Applied: every changed file is under `Sources/ZTronAssetSync/**`,
  `Tests/ZTronAssetSyncTests/**`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` or this draft.
- **Orchestrator ruling (close-out) S3-R8, strict bar.** Findings in another work package's files are reported
  `other-wp:<wp>:`; pre-existing behaviour an ADR accepts is not a finding unless it breaks a MUST the record did not
  consider.
- **Orchestrator ruling (close-out) S3-R9, records.** This file: one entry per item, then "Authorised edits outside
  WP-F", "Proposed document changes" and "Not verified here".
- **Orchestrator ruling (close-out) S3F-1 to S3F-17.** The per-item rulings are quoted at the head of each entry below.

## Cycle 2: the cycle-1 verification findings

Every finding of the two cycle-1 lenses, with its disposition. Blocking ones first; each fix is detailed under its item.

| Lens | Finding | Disposition |
|---|---|---|
| reqs (blocking) | S3F-10 not applied: no behaviour test for any uncovered region | **Fixed**: tests for every region a seam reaches; the rest recorded with reasons (S3F-10 below) |
| reqs (blocking) | S3F-13 not applied: re-admission still quadratic, benchmark at 1,000 | **Fixed**: lazy re-admission from an ordered index, structural pin, `probeChainTurns` at 10,000 (S3F-13 below) |
| reqs (blocking) | S3F-14 partly done | **Fixed**: every remaining §12.3/§12.4 name written; R-SYN-15's join-before-close order has an engine-side check that M5 and M6 fail (S3F-14 below) |
| correct (blocking) | S3F-5 residual: the follow of an apply changing every member of a waiting 10,000-member group held the actor 111–145 ms | **Fixed**: the follow is bounded per turn (S3F-5 below) |
| reqs | S1-11's test hangs instead of failing under the strand mutant | **Fixed** (`ad98ac3`): `EngineHarness.value(of:)` forwards the time limit's cancellation to the awaited task; used at all 14 `withClock { await task.value }` sites. Strand mutant (`EngineDispatch.swift`, `guard let update = terminal else { return }`): `EngineSync1RegressionTests.swift:96:6: Time limit was exceeded: 60.000 seconds`, then `:114:9`, `:118:9`, `:119:9` recorded, `failed after 63.970 seconds with 4 issues` (it hung for over 31 minutes before). |
| reqs | S3F-4: no deterministic pin of settle's per-turn bound | **Fixed** (`243c6da`): settle records its slices (`EngineState.shutdownSlices`); `R-SYN-15: a shutdown over more waiters and jobs than one turn takes …` asserts every slice ≤ `shutdownStepsPerTurn`, their sum = 1,200, at least three. No-chunk mutant (`if steps == Int.max`): `EngineShutdownDrainTests.swift:52:9: … every turn of the settle takes at most shutdownStepsPerTurn steps: [1200]` and `:54:9` |
| reqs | S3F-15: `fireDue`'s use of the limit unpinned | **Fixed** (`243c6da`): `R-SYN-5: one alarm turn of the engine re-queues at most dueDeadlinesPerTurn retries that fell due together` (600 retries due at once, the alarm turn held and stepped). Mutant `popDue(at: now)`: `EngineBoundaryTests.swift:199:9: … one turn re-queued 600 retries` and `:200:9: … the rest wait for the next turn: 0` (lines 200 and 201 since the wait was made to end when no alarm is left, so the mutant fails at once instead of after the time limit) |
| reqs | P-4 missed at load (4 of 6 runs) | No change (planner untouched since `s3-base`); re-measured below; the orchestrator re-measures on a quiet host at the Stage 3 merge |
| correct | P-11 2.51 and the throttle extension under load | No change (dispatch untouched by this cycle); re-measured below |
| correct | S3F-13 still open | Same as the requirements finding (fixed) |
| correct | other-wp:b: P-13 unit max 6.83 ms | **other-wp:b:** not WP-F's file (`BenchStorage.swift`), not touched; routed to WP-B |

## Items

### S3F-1 [BLOCKING] S3-CONC-04 — a satisfied first conditions reading is an edge — **Fixed**

*Ruling:* a satisfied FIRST conditions reading counts as an edge for work that failed offline while no reading existed
(hunter's option 1 or 2); both probes become regression tests; propose the note beside PROBE-C9C-3's rule in §7.6.

- **Choice: option 1.** `apply` (`EngineConditions.swift`) now counts a satisfied reading with no previous reading as an
  edge (`previous.map { … } ?? true`). It covers both orders of the window: a failure that came before the first reading
  is re-queued by the edge's pass (`edgeOwed`), and a failure that arrives after it is retried at once by PROBE-C9C-3's
  rule, because the attempt recorded `networkEdgeSerial` before the reading bumped it. Option 2 (mark the job owed when
  it fails with `conditions == nil`) misses the second order. With nothing failed the edge re-queues nothing; a pending
  run waiting for an edge keeps the watcher (`hasWork`), so its first reading is never this one, and F-16's one-retry
  bound is unchanged (`offlineRunsWithoutEdge` is only reset by a first reading after an idle teardown, at most once per
  idle period: bounded, not polling).
- **Tests** (`Tests/ZTronAssetSyncTests/Engine/EngineFirstReadingTests.swift`, `extension EngineConditionsTests`; the
  probes' `GatedConditionsSource` lives there):
  - `R-SYN-13: an asset that failed offline before the engine's first conditions reading is retried once that reading shows a satisfied path` (the hunter's probe);
  - `R-SYN-13: an offline failure that arrives after the engine's first conditions reading showed a satisfied path is retried at once` (the second order);
  - `R-SYN-13: an unsatisfied first conditions reading retries nothing and the satisfied reading after it retries the asset once` (the confirmer's control).
- **Evidence.** Failing first (`c1cf975`) on `s3-base` code: `EngineFirstReadingTests.swift:158:9: Expectation failed:
  after != .failed(.whenOnline)` and `:186:9: Expectation failed: (try? answer.get()) != nil`; fix `a6457b8`; all three
  pass, Sync 354/354 at that commit.

### S3F-2 [BLOCKING] S3-STAB-03 — TSan hang guards — **Fixed (guards sized from measurements, steps made cheaper)**

*Ruling:* apply S3-R4 to `randomOperations` and the near misses; measure each under TSan alone and with a second TSan
process; make steps cheaper where possible; raise a guard only with measurements; the model loop checks
`Task.isCancelled` per operation.

- **Cheaper steps.** `EngineHarness.idleViolations()` returns in one engine hop (no store read) when the engine is not
  settled (it was three hops after each of the walk's 10,000 operations; the assertions are the same, read in the first
  hop). `R-CAR-4`'s join wait reads the job count before checking each member, O(1) per engine mutation instead of
  O(members): 14.8 s → 7.4 s beside the suite, 31.6–31.9 s → 16.9–17.0 s paired.
- **Cancellation.** The model walk checks `Task.isCancelled` before each operation; the two launch loops call
  `Task.checkCancellation()` per launch; the 2,000-round observation window stops at cancellation.
- **Measurements** (TSan build `.build-s3f-tsan`, whole `ZTronAssetSyncTests` bundle run directly, `.build-s3f/run-direct.sh`):

  | Test | alone in the suite, before → after | paired (2 TSan processes), before → after | guard |
  |---|---|---|---|
  | `R-SYN-2: 10,000 seeded random operations …` (`EngineModelTests.randomOperations`) | 29.8 → 29.5 s (8.0 s with only it) | 58.4/58.8 → 59.2/59.4 s | **5 min** |
  | `R-STO-11: ensureAvailable right after start, beside a legacy migration …` | 21.4 → 21.8 s | 44.9/45.2 → 49.0/49.6 s | **3 min** |
  | `R-STO-11: a user-initiated prefetch group joined right after start, …` | 22.4 → 22.8 s | 45.1/45.7 → 49.7/50.5 s | **3 min** |
  | `R-SYN-14: while a job's adoption holds the last claimed prior-art file …` | 18.2 → 16.3 s | 37.8/37.8 → 37.4/37.7 s | **3 min** |
  | `R-SYN-6: a run whose parked claim a re-admission turn still owes …` (`EngineRegressionCycle16Tests.swift:31`) | 18.2 → 16.4 s | 37.8/39.7 → 36.6/38.5 s | **3 min** |
  | `R-CAR-4: a join's give-up of more than releasesPerTurn claims …` (`EngineGroupClaimTests.swift:387`) | 14.8 → 7.4 s | 31.6/31.9 → 16.9/17.0 s | **1 min (kept)** |

  Loads: before, alone 14.7–28.1, paired 24.1–30.1; after, alone 19.8–27.2, paired 27.2–43.1. The paired run takes
  each raised test above half its limit (the ruling's condition); R-CAR-4 is now below half and keeps `.minutes(1)`.
- **Commit:** `0b76e30` (each raised guard's doc comment carries its measurements).

### S3F-3 [BLOCKING] S3-CONF-03 — a run over an asset failed at the integrity cap — **Fixed (test)**

*Ruling:* the run must not end `.complete` and must not write the stamp; the dropping mutant must fail it.

- **Test** (`EngineRunIntegrityCapTests.swift`, `extension EngineFailurePathTests`): `R-SYN-6: a run over an asset failed
  at the integrity cap ends completeWithFailures with an integrity failure for it`; beyond the probe it asserts
  `failedCount == 1` and that the store's sync stamp is unchanged (`StorePlanningView.stamp`). Production unchanged.
- **Mutant (S3-R3)**, `S3-CONF-03.mutant.diff` in the scratch copy: `✘ … recorded an issue at
  EngineRunIntegrityCapTests.swift:40:25: Issue recorded` (the run ended `.complete`). Commit `0140b37`.

### S3F-4 [BLOCKING] S3-PERF-01 — shutdown at 10,000 — **Fixed**

*Ruling:* bound the teardown per turn (S3-R5), also on the rootVanished reopen path; `BenchSync` benchmark beside
`handleReleaseTurns`.

- **Fix** (`EngineShutdown.swift`, new; `EngineLifecycle.performShutdown`): (1) handles are cancelled over `inFlight`
  (only a downloading job has an attempt, and every downloading job is in flight), not over the job table sorted twice;
  (2) `drainEverything(with:)` moves every continuation table and catalog-sized table out of the state in O(1) per
  table (the small joiner tables are still answered at once); (3) `settle(_:with:)` answers the waiters and the groups and
  frees the job table at most `shutdownStepsPerTurn` (512) steps per turn, a `Task.yield()` between slices; the drain is
  a `consuming` parameter and each table is swapped out of it, so removals free entries instead of copying the table.
  The rootVanished reopen path calls the same `performShutdown`. New REENTRANCY row **RE-S43 (proposed)**.
- **Benchmark:** `R-SYN-15: shutting down under a 10,000-member prefetch group and 10,000 waiting resolves holds the
  engine's actor at most C2's 10 ms per turn and answers every waiter shutDown` (`BenchSync.shutdownTurns`, production
  dispatch executors). Before (`ef5c81a`, load 17.7–19.7): runs [33.77, 22.05, 28.16] ms, group alone [25.00, 20.87,
  26.39] ms, `BenchSync.swift:250:13: Expectation failed: (runs.min() ?? .infinity) <= Self.c2Budget`. After (`523f9b1`,
  load 21.1→12.4): runs [1.48, 1.36, 1.41] ms, 1,000: 0.20 ms, group alone [0.63, 0.62, 0.62] ms; the control
  `handleReleaseTurns` 4.10–4.84 ms in the same run.
- **Structural test:** `R-SYN-15: a shutdown over more waiters and jobs than one turn takes answers every waiter shutDown
  and leaves the engine owning nothing` (`EngineShutdownDrainTests.swift`): 600 waiters and jobs; the drain takes every
  waiter, job and group and leaves none in the state; every waiter is answered `shutDown` once; no owned task remains.
  Cycle 2 (`243c6da`): the same test now pins the bound itself through the settle's recorded slices
  (`EngineState.shutdownSlices`), which the cycle-1 verifier showed a no-chunk mutant survived (see "Cycle 2").

### S3F-5 [BLOCKING] S3-PERF-02 — an apply under a 10,000-member group — **Fixed**

*Ruling:* make the follow proportional to what the apply changed or chunk it; same for `finishRun`'s and
`releaseSystemReattachments`' full sorted walks; `BenchSync` benchmark.

- **Fix.** `followApplied(from previous:)` visits only (a) the jobs of the ids whose transfer differs between the
  previous copy and the new one (one pass over `previous`, a lookup and a checksum or remote-path comparison per id,
  `SyncEngine.sameTransfer`, a transfer formatted only for an id that moved), and (b) `EngineState.unfollowed`: jobs joined
  for an entry the copy did not name then (`addInterest` → `noteJoin`), jobs a follow skipped while verifying or
  committing, and every job after the launch adoption that no follow accompanies. A job that follows the previous copy
  can only have moved for an id whose transfer changed, and that id's job is the transfer the previous copy named, so the
  visit set is exact. `releaseSystemReattachments` walks `EngineState.systemHeld` (jobs a system interest joined);
  `finishRun` walks `RunState.held` (jobs the run's interest joined and has not left). Three new rows in
  `invariantViolations()` check the indexes against the job table after every model-test operation.
- **Benchmark:** `R-SYN-6: a sync that applies a new manifest under a 10,000-member prefetch group holds the engine's
  actor at most C2's 10 ms per turn` (`BenchSync.refreshUnderGroupTurns`). Before (`8a2ad40`, load 6.6→5.1): runs
  [17.04, 16.38, 16.88] ms, `BenchSync.swift:272:13: Expectation failed`. After (`26f87da`, load 12.4→8.4): runs [1.20,
  1.20, 1.29] ms.
- **Behaviour test:** `R-SYN-2: an apply moves only the jobs of the ids it changed and leaves every other waiting job as
  it was` (`EngineFollowTests.swift`): the changed member's interest follows its new content, the dropped member's job
  ends, the others keep their jobs, exactly one job is created, `unfollowed` is empty and every invariant holds; a
  second apply of the same manifest moves nothing.
- **Cycle 2: the residual (correctness lens, blocking).** Proportional was not bounded: an apply that changes the content of
  every member of a waiting 10,000-member prefetch group (a catalog re-encode under `AssetClient.prefetch`) superseded,
  re-routed and re-created 10,000 jobs in one turn. Failing benchmark first (`b4c215d`): `R-SYN-6: a sync whose manifest
  changes the content of every member of a waiting 10,000-member prefetch group holds the engine's actor at most C2's 10
  ms per turn` (`BenchSync.changedRefreshTurns`, production dispatch executors, the PROBE-V9 shape at 100 %), runs
  [110.53, 111.25, 133.49] ms at load 6.7→10.5, `BenchSync.swift:293:13` (P-9's 50 ms median) and `:294:13` failed.
- **Fix** (`958348e`, `Sources/ZTronAssetSync/Engine/EngineFollow.swift`, new; `followApplied` moved there from
  `EngineRuns.swift`): the pass over the replaced copy is itself bounded (`followScansPerTurn` 16,384 entries compared and
  `followFormatsPerTurn` 2,048 changed transfers formatted per turn: the pass alone over 10,000 changed entries took 7.5 to
  15.6 ms, and the sort 3.4 to 3.6 ms, in a release probe), and at most `followsPerTurn` (256) jobs are visited per turn;
  `supersede(_:settling: false)` lets a follow check the run and pump once per turn instead of once per job. The rest is
  owed to owned follow-up turns (`EngineState.followScans`, `followOrder`/`followNext`; `followFollowUp()`): a job waits
  in `unfollowed` from the pass's finding until its visit, which is that set's documented meaning, and a later apply's
  follow restarts the visits from `unfollowed` and queues its pass behind the owed ones (every pass compares with the
  copy as it stands when it runs, so two applies in a row are followed exactly). While a follow is owed `checkRunSettled`
  does not settle (a claim may still move) and `manifestCaughtUp` keeps the jobs held for a catch-up held (the follow's
  last turn releases them). New `invariantViolations()` rules: a follow owed with no turn scheduled; an owed job missing
  from `unfollowed`; the `unfollowed` rule now accepts a job the owed pass has not reached (it follows the replaced copy).
  Shutdown drains the follow's state. **REENTRANCY RE-S44 (proposed)**, the follow-up's hop (row below).
- **Measured after** (release probe at load ~33): the follow's first turn 4.08 ms (was 111–145 ms in one turn); benchmark
  runs [6.47, 9.87, 10.43] ms at load ~32, then [3.68, 3.80, 3.76] ms at load 6–8 (14:51). Later runs are under "Gate
  evidence (cycle 2)".
- **Tests:** `R-SYN-2: an apply that moves more jobs than one turn takes follows them a bounded slice per turn with every
  invariant holding between turns` (2,148 changed members, the follow-up held and stepped one turn at a time with
  `holdFollowFollowUps()`: turn 1 stops its pass at 2,048 formats and moves 256 jobs, nine turns of at most 256 moves,
  every invariant holding and the run unsettled between turns, every member's interest on its new content at the end).
  Mutants: the visit bound removed → `EngineFollowTests.swift:111:9` (`first.moved == followsPerTurn`), `:112:9`,
  `:114:9`; `checkRunSettled`'s follow guard removed → `:117:17: Expectation failed: !turn.settled`. And `R-SYN-2: a job
  held for a manifest catch-up stays held until the follow that may move it has ended` (the catch-up and the held job are
  set up in one engine turn, the order a superseded publication and an apply in flight leave; jobs a release removes
  between two follow turns are skipped). Mutant (`manifestCaughtUp` without the follow guard) →
  `EngineFollowTests.swift:165:9: Expectation failed: first.held`.

### S3F-6 [REQUIRED] S3-CONC-03 — run progress order for a lagging subscriber — **Fixed**

- **Fix** (`SubscriberQueue.publish`): one run's `syncProgress` never replaces another run's undelivered progress in
  place; the next run's first progress takes a fresh slot at the tail, behind the previous `syncFinished` and its own
  `syncStarted`, and the superseded progress is dropped. The hunter's first suggestion (retire the run slot at
  `syncFinished`) was tried and rejected: it also dropped run 2's own progress before a lagging reader saw it, which the
  engine probe asserts is delivered. The existing `subscriberQueueOrder` expectation (same-run progress keeps its
  position) is unchanged; the type's doc now states the actual rule.
- **Tests** (`EngineEventOrderTests.swift`, `extension EngineEventsTests`): `R-SYN-12: a lagging subscriber receives a
  run's syncStarted before that run's syncProgress` (asserts `syncFinished(run1) < syncStarted(run2) <
  syncProgress(run2)`) and `R-SYN-12: a subscriber stalled across two runs receives the second run's syncStarted before
  its syncProgress`. Failing first `20e6bff` (`:32:13` and `:72:13`); fix `0c5e0c0`.

### S3F-7 [REQUIRED] S3-CONF-04 — **(a) Fixed (test); (b) recorded**

- (a) `R-SYN-7: at a critical thermal state user-initiated transfers are capped at interactiveConcurrencyAtCritical once
  the conditions are known` (`EngineGateConformanceTests.swift`). Mutant `S3-CONF-04.mutant.diff`: `✘ … at
  EngineGateConformanceTests.swift:70:9: Expectation failed: state.running == cap` and `:71:9: … starts.count == cap`.
- (b) **Recorded, no code (ruling: the documented design).** User-initiated work dispatched while the conditions are
  unknown (after the idle teardown) is not trimmed when a critical thermal reading then arrives; ADR-036's cap applies to
  dispatch decisions taken with the conditions known.

### S3F-8 [REQUIRED] S3-CONF-02 — **Fixed (test)**

`R-SYN-7: an Apple-tier catalog update check is refused on an expensive network the bulk policy forbids`. Mutant
`S3-CONF-02.mutant.diff`: `✘ … at EngineGateConformanceTests.swift:28:9: Expectation failed: request.allowsUpdateCheck == false`.

### S3F-9 [REQUIRED] S3-CONF-05 — **Fixed (test)**

`R-CAR-7: ensureAvailable while the auth breaker is open throws authRejected for a scope with missing assets`. Mutant
`S3-CONF-05.mutant.diff`: `✘ … at EngineGateConformanceTests.swift:100:9: Expectation failed: result == .failure(.authRejected(.confirmed))`.
Commit `3a602f6` (S3F-7a, S3F-8, S3F-9).

### S3F-10 [REQUIRED] S3-CONF-08 — uncovered Sync regions — **Fixed in cycle 2 (tests where a seam reaches; reasons for the rest)**

*Ruling:* a behaviour test through real APIs or a documented seam for each uncovered region the conformance hunter listed
in Sync, `other-wp:` for the Storage and Kit ones, §14 candidates for the rest. Cycle 1 wrote none (the cycle-1 verifiers'
blocking finding). Cycle 2 (`59e14fe`), every test in WP-F's suites, all passing on the current engine (none
showed a bug):

| Region (s3-base lines) | Test (display name) | Status |
|---|---|---|
| A publication the store refuses, `unverifiedRejected` (`EngineDispatch.swift:1112-1114`; R-INT-5, `allowUnverifiedAssets = false`) | `R-INT-5: with unverified assets disallowed a resolve of a checksum-less entry fails integrityFailure at publication and is not retried` | covered; the engine still downloads before the store refuses (the hunter's "decide whether a strict policy should refuse before downloading"): recorded as observed behaviour, a proposal for the orchestrator, not changed here (a pre-download refusal changes what a user resolve answers and when) |
| `unknownAsset` / `notPresent` (`:1109-1111`) | `R-CAR-2: a publication the store refuses as an unknown asset answers the waiter notFound and does not retry the transfer` (the store applies a manifest without the id behind the engine's copy while the transfer runs) | covered |
| `assetFailed` (`:1112-1114`) | `R-NET-6: a publication the store refuses because the asset's record failed meanwhile answers the waiter from that record` (`recordFailure(…, reason: .notFound)` behind the engine) | covered |
| An uncommanded `.cancelled(.byClient)` re-queue (`EngineFailures.swift:75-76`; §7.6 T7/T13) | `R-NET-6: a transfer cancelled by the client without the engine asking is re-queued at once and its next attempt delivers` | covered |
| The progress replay for a subscriber joining mid-run (`EngineEvents.swift:128-129`; R-SYN-12) | `R-SYN-12: a subscriber that joins a run in progress receives the run's syncStarted and then its latest syncProgress` | covered |
| Maintenance out of budget between steps (`EngineCommands.swift:1054-1056`, after orphan collection) | `R-SYN-16: maintenance whose time budget runs out during orphan collection stops before eviction and verification and reports the budget exhausted` (the sweep's bulk unit held, the clock passes the deadline) | covered |
| A maintenance step that throws `cancelled` (`:1081-1085`) | `R-SYN-16: a maintenance step cancelled by shutdown answers shutDown` | covered |
| A maintenance step that throws otherwise (`:1086-1092`) | `R-SYN-16: a maintenance step that throws fails the maintenance with the mapped error and the next one runs` (EIO on the staging listing) | covered |
| Source copies a source fails to release (`EngineRuns.swift:1034-1035`; R-CLN-10) | `R-CLN-10: source copies a source fails to release after a run are recorded for diagnostics` (`ReclaimFailingSource`) | covered |
| Maintenance out of budget after eviction (`EngineCommands.swift:1063-1065`, now `:1065-1067`) | — | **§14 candidate**: `evictIfNeeded`'s only executor unit is its free-space read on the metadata executor, which every earlier step also uses (staging and orphan listings, in an order WP-B owns), so no seam holds that unit without counting WP-B's units; the check is the same `expired()` as the tested exit after orphan collection |
| "Adoption report failed" (`EngineRuns.swift:1036-1037`, now `:1009`) | — | **§14 candidate**: `adoptionReport()` throws only while the store is not open or marked unavailable (`awaitOpen`, `checkWritable`); no fake path marks it unavailable between a run's last commit and this read without failing that commit first |
| The pending-run gate re-arming for conditions, breaker and throttle (`EngineRuns.swift:992-1004`, now `:963-976`, `pendingRunGate` → `.unarmed`) | — | **§14 candidate (defence in depth, as FULFIL and the F-39 re-check)**: `.unarmed` needs a pending run whose gate nothing will open; every path that sets or changes one arms it: a pending run is work, so the conditions watcher exists (`hasWork`, `ensureWatcher`); a breaker that rejects always has its cooldown or a probe's watchdog in the heap, or a probe whose outcome reconsiders (`scheduleBreakerDeadline` on every change); a throttle pending run's deadline is scheduled when it is set and moved by every extension (`throttleExtended(from:)`). `invariantViolations()`' `strandedPendingRun` names the state if it ever arises |
| Stale edge and origin re-admissions (`EngineReadmission.swift:128-129`, `:134`, `:141-142`, `:147`) | — | **already in §14** (level-4 merge: "the stale-entry branches of the re-admission turn"): `reindex` removes a job from `edgeOwed`/`originOwed` in the transition that leaves the owed state and `removeJob` does too, so the passes find no stale entry |
| An apply that adds an id over a detached record (`AssetStore+Apply.swift:206-210`) | — | **other-wp:b:** WP-B's file; the record kinds that stay detached are WP-B's to produce in a unit test |
| Kit: follower and group-registration races, `withAsset`'s "root vanished after every reopen" (`ClientLifecycle.swift:246-253`, `:508-515`, `AssetClient.swift:148-149`) | — | **other-wp:g:** WP-G's files (`AssetClient.swift:146-151` is already in §14) |

Cycle 2's own new code that no test runs (final coverage run, "Gate evidence (cycle 2)"), each a guard: the follow's
follow-up that cannot be spawned (shutting down) or finds nothing owed (`EngineFollow.swift`), a job visited that no
longer exists or did not move, the parked-order re-admission's illegal-transition `continue` and its no-breaker return
(`EngineReadmission.swift`), and `readmitOpenedOriginGates`' eager branch for a breaker that admits every transfer while
jobs stay parked (`EngineOriginGate.swift`: a closed breaker re-admits its parked jobs in the turn it closes, the rest owed
in `originOwed`, which the callers check first). Proposed for §14 below.

### S3F-11 [REQUIRED] M-N-09, M-N-12, M-N-14, M-N-16, M-N-20, M-N-39 — **Fixed (tests)**

Tests (`EngineBoundaryTests.swift`, commit `1dcc21e`), each with its mutant's failing line from the scratch copy:

- M-N-09 — `R-SYN-3: a queued bulk job a prefetch request joins is promoted and starts before the bulk job queued ahead of it`: `EngineBoundaryTests.swift:42:9: Expectation failed: Array(result.starts.prefix(2)) == result.order`.
- M-N-12 — `R-SYN-3: a queued bulk job a user-initiated request joins is promoted and starts before the bulk job queued ahead of it`: `:50:9` (and `:42:9`), the same expectation.
- M-N-14 — `R-SYN-5: the backoff ceiling doubles with every attempt, so some key draws above the previous attempt's ceiling`: `:73:13: Expectation failed: largest > previous` (five attempts).
- M-N-16 — `R-SYN-5: a window whose 5xx share equals serverErrorRatio exactly opens the breaker`: `:94:9: Expectation failed: breaker.state == .open(cause: .serverErrors, until: now.adding(seconds: 30), trips: 1)`.
- M-N-20 — `R-SYN-5: a Retry-After equal to maxRetryAfter is honoured, one above it defers to the next run`: `:102:25: Expectation failed: Backoff.delay(attempt: 1, retryAfter: policy.maxRetryAfter, …)`.
- M-N-39 — `R-SYN-5: a later transfer 429 with a shorter Retry-After never shortens the origin's throttle`: `:137:9: Expectation failed: end == throttledAt.adding(seconds: 60)` and `:139:9`. Unlike the candidate, the two 429s are released in a fixed order from held attempts, so the test does not depend on scheduling.

### S3F-12 [REQUIRED] S3-B-064, S3-B-065, S3-B-081, S3-B-082 — **Fixed**

- **S3-B-064 (L4-R24(1)).** `startRun` puts the run in place, then reserves the manifest probe, then spawns. The
  start-turn test `R-SYN-5: a run that starts while the half-open breaker admits only a probe holds it for its manifest
  fetch from its start turn` now records, from its condition observer, `invariantViolations()`' half-started-run rule at
  every observation once the watched run's id was taken. Only that rule is asserted mid-turn: an observer inside a turn
  sees the other rules' transients (an alarm about to be re-armed, a job about to be queued), which the first, broader
  form showed. Failing first `dfd4c05`/`2a49552`: `EngineRegressionCycle22Tests.swift:292:9: Expectation failed:
  watch.violations.isEmpty ↳ … "run 2: the breaker's probe is held for a manifest fetch that is neither in flight nor
  about to begin"`; fix `e21472b`.
- **S3-B-065 (L4-R24(4)).** A job only released groups wanted that a new interest joins is reinstated at its place
  (`reinstate`) in the queue its lane now selects, whether the interest keeps the lane, changes it or comes from user
  work; `relane`'s re-queue at the back stays for jobs that waited in their queue all along. Test `R-SYN-3: members of a
  released handle that regain a user-initiated interest keep their queue positions instead of going to the back`
  (`EngineRejoinLaneTests.swift`, arguments `laneChange`, `userWork`): before the fix `↳ laneChange: dispatched ["later",
  "m0574", "m0520"], expected ["m0520", "m0547", "m0574"]` and the same for `userWork` (`14768f8`/`bb58b56`); fix `6bb4c1e`.
- **S3-B-081 (L5-R16).** `countFailedAttempt` keeps a job that only a pending claim kept when its attempt failed while
  the retry policy of its held lane (`Job.heldLane`) has attempts left (`claimRetries`), so it backs off instead of
  ending `failed(.nextRun)` with an `assetFailed`. Test `R-CAR-4: a job only a claim keeps backs off after a transient
  failure under its held lane's retry policy instead of failing at once` (`EngineClaimRetryTests.swift`): failing first
  `df20979` (`↳ the claim-only job backs off under the prefetch policy instead of ending: nil`); fix `002844b`. G-13's
  qualification "except on failure" (L5-R16) can be lifted for retryable failures.
- **S3-B-082 (L5-R22(4)).** `invariantViolations()` reports a registered group in `releasing` only while its `Release`
  holds members. Test `R-CAR-4: invariantViolations reports a registered group in releasing only while its release holds
  members, not a large give-up's leftover claims` (`EngineGiveUpInvariantTests.swift`, the E2 shape: a give-up of
  `releasesPerTurn` + 24 claims of a registered group, checked in the give-up's own turn; and a release holding members
  while registered is still reported). Failing first `435c58c` (`["group 5 is released and registered"]`); fix `3cf147d`.

### S3F-13 [REQUIRED] S3-B-063 — lazy re-admission for probe chains — **Fixed in cycle 2**

*Ruling:* L4-R22: lazy re-admission with an ordered index (O(log n) per probe exit) so a chain of half-open probes is no
longer quadratic in the parked jobs; pin it structurally (re-admission work per exit) and extend `BenchSync.swift:328`
to 10,000 parked members under C2. Cycle 1 deferred it; no ruling demoted it, so cycle 2 implements it.

- **Failing test first** (`ce021cb`): `R-SYN-5: a chain of half-open probes ending without a verdict re-admits one parked
  job per probe exit, in the pump's order, not every job the breaker parked` (`EngineProbeChainTests.swift`, `extension
  EngineFailurePathTests`): on `s3-base`'s eager re-admission `EngineProbeChainTests.swift:80:9: Expectation failed:
  seen.mostQueued <= 1 ↳ at most one member waits in the queue for the probe: 64`.
- **Fix** (`e575681`): `CircuitParkedOrder` (new, `Sources/ZTronAssetSync/Engine/CircuitParkedOrder.swift`), a binary
  min-heap of the breaker-parked jobs by (queue rank, queue ticket, transfer) with lazy deletion: a job's place is pushed
  when it enters `blocked(circuitOpen)` (`transition`) and when an interest joins it while parked (`addInterest`, its rank
  may rise); a stale place (the job left the park, was queued again, or ranks lower now) is dropped or re-pushed at its
  rank when it reaches the top; the order is emptied when nothing is parked and rebuilt in O(n) when stale places
  outnumber live ones (`noteCircuitParked`). A breaker that admits a parked job only as its probe (open past its cooldown,
  half-open without a probe or past a silent probe's watchdog: `breakerAdmitsOnlyProbe()`) re-admits only the first parked
  job (`readmitForProbe()`), in `unblockOrigin(.circuitOpen)` (cooldown end, watchdog, probe exit without a verdict) and in
  `readmitOpenedOriginGates` (which schedules a pump only when it re-queued one, so `checkRunSettled` cannot loop); it
  re-admits nothing while that candidate (`EngineState.probeCandidate`) still waits in the queue and no parked job ranks
  before it. A closed breaker still re-admits every parked job (bounded per turn, as before). The pump's end re-admits the
  next parked job when the candidate was parked for another gate or ended (`ensureProbeCandidate()`; `removeJob` of the
  candidate owes a pump); a joiner of a job that stays parked behind the candidate gets the park's fail-fast answer now
  (`failFastJoiner`), as the eager design gave it when the pump parked that job again behind the probe.
- **The invariants, redefined.** F-40's rule "no job stays parked against a gate that admits at `now`" becomes, for a
  breaker that admits only a probe, "a queued job that the pump serves no later than the parked one (queue rank at or
  before it) will take the probe" (the gate model's I3 oracle, `EngineGateModelTests.staleParks`), and the engine's own
  `invariantViolations()` gains two rules: every parked job has its place in the order, and parked jobs are never stranded
  (the breaker admits only a probe, nothing is queued, no re-queue, pump or due breaker deadline is owed). `checkRunSettled`
  still counts a parked claim under a gate that admits as working: the candidate's dispatch takes the probe, after which
  the gate rejects and the run settles blocked as before. Two cycle-20/21 regression tests waited for the claim to be
  **queued** after the cooldown's turn; they now wait for it to be queued or parked behind the probe (their assertions
  are unchanged; `EngineRegressionCycle20Tests.swift`, `EngineRegressionCycle21Tests.swift`).
- **Structural pin:** the chain test counts the re-admission work (`EngineState.circuitReadmissions`, jobs re-queued from
  `blocked(circuitOpen)`): over 60 parked members and 60 probe exits, exactly 60 re-admissions, never more than one member
  queued nor more than one queued and one downloading at any notification, the members probing in the pump's order.
  Eager mutant (the lazy branches disabled): `EngineProbeChainTests.swift:91:9: Expectation failed: readmitted == count -
  slots`, `:92:9`, `:93:9`. Missing pump-end hook: the seeded gate walks fail (`EngineGateModelTests.swift:503:29` and the
  walk test). Plus `R-SYN-5: the breaker's parked order follows a parked job's rank as interests join and leave and stays
  bounded` (70 joins compact the order to its bound; a user-initiated join raises a parked member's rank and its release
  lowers it again; the cooldown re-admits the first member in the pump's order, once). Mutant (rank check removed) →
  `EngineProbeChainTests.swift:147:9: … probing.probe == members[0].transferID`. And `R-SYN-5: the breaker's parked order
  always yields its smallest entry by rank, then ticket` (three seeds, against a sorted model).
- **Benchmark:** `probeChainTurns` now runs 10,000 parked members (warm-up 1,000): `R-SYN-5: a chain of half-open probes
  ending without a verdict over 10,000 prefetch members parked by the breaker holds the engine's actor at most C2's 10 ms
  per turn, and reports the chain's total time`. At load 6–8 (14:51): runs [5.26, 2.08, 2.77] ms, totals [20.2, 22.3,
  24.6] s (the quadratic design's estimate was about 161 s; the total is now dominated by each probe's attempt round trip
  through the fake source and the bench's polling at default priority against utility-priority engine tasks, about 2 ms
  per probe, not by re-admission work, which the structural test counts as one per exit). `cooldownEndTurns` 0.05–0.07
  ms (one re-admission instead of 512 per turn). Later runs under "Gate evidence (cycle 2)".

### S3F-14 [REQUIRED] S3-B-068, S3-B-069, S3-B-070 — §12 regression names — **Fixed (cycles 1 and 2)**

Every name ARCHITECTURE §12.3/§12.4 gives is written, in `extension EngineRegressionTests`; all pass on the current engine
(no test failed first, so no bug was found and no fix commit was needed beyond the R-SYN-15 mark below):

| Finding | Test (display name) | File, commit |
|---|---|---|
| S1-01 | `R-SYN-4: a job whose last interest left during verification is not retried after an integrity failure` | `EngineSync1LivenessTests.swift`, `b336bd9` |
| S1-01 | `R-SYN-2: a stale commit with no interests removes the job and frees its pipeline slot` | same |
| S1-07 | `R-SYN-7: a user resolve of a policy-blocked bulk asset starts at once and its demotion pauses it again` | `EngineSync1RegressionTests.swift`, `ee95eb8` (cycle 1) |
| S1-09 (replaced alarm) | `R-SYN-15: an alarm replaced while its turn waits never unregisters its successor, which fires every due deadline` | `EngineSync1HalvesTests.swift`, `b336bd9` |
| S1-09 (replaced watcher) | `R-SYN-14: a watcher replaced while its observation is still being set up never unregisters its successor and never observes` (`HoldingConditionsSource` holds both watchers in `conditions()`; the harness gained `conditionsWrapper:`) | same |
| S1-11 | `R-SYN-2: a transfer stream that ends without a terminal element fails the job instead of stranding it` | `EngineSync1RegressionTests.swift`, `ee95eb8`/`60eab9c` (cycle 1), hang guard `ad98ac3` |
| S1-12 | `R-SYN-10: ensureAvailable during a bulk sync never fails with storageUnavailable because of concurrent commits` (the member's publication held while the bulk run commits and moves the index generation) | `EngineSync1LivenessTests.swift`, `b336bd9` |
| S1-15 (run form) | `R-SYN-3: a 100,000-entry plan never materialises more than the pipeline plus the lookahead as jobs` (a condition observer samples the job count at every notification; hang guard 3 min, S3-R4 measurement below) | same, `942c633`, `a528809` |
| S2-01 (`ensureAvailable` form) | `R-SYN-10: ensureAvailable completes after a breaker recovers from an abandoned probe` | `EngineSync2RegressionTests.swift`, `b336bd9` |
| S2-09 | `R-SYN-11: committed bytes stay in the headroom ledger so the reserve is never crossed` | same |
| S2-10 | `R-SYN-3: a user-initiated job starts while bulk work fills the verify and commit pipeline` | same |
| R-SYN-15 join-before-close | `R-SYN-15: shutdown joins every owned task before it begins closing the store` | `EngineSync1HalvesTests.swift`, `b336bd9` |

- **R-SYN-15's engine-side assertion.** `performShutdown` now sets `EngineState.closingStore` and notifies observers right
  before `store.close()`; a condition observer records the owned-task count whenever it sees the mark. The level-4
  verifier's mutants M5 and M6 are not on file, so they are reconstructed from `f.md` F-20's description: M5 moves the
  close before the join loop, M6 removes the join loop. Both fail the new test while the existing `R-SYN-15: no store
  mutation or commit happens after close returns` still passes under them (the gap the backlog item named): M5
  `EngineSync1HalvesTests.swift:216:9: Expectation failed: record.tasksAtMark.allSatisfy { $0 == 0 } ↳ no owned task was
  registered when the close began: [1, 0, 0, 0]`; M6 the same line with `[3, 2, 1, 0, 0, 0]`.
- **Mutants of the other tests** (scratch, re-applied and reverted in place, each rebuilt): the alarm body without its
  token check → `EngineSync1HalvesTests.swift:100:29` (the successor is no longer the registered alarm); a stale watcher's
  exit that unregisters the current watcher → `:153:9`, `:154:9`, `:156:9` (the two token checks alone are not the
  defence: AsyncStream iteration ends on the replaced watcher's cancellation, so a mutant removing both still passes, and
  the test pins the unregistration instead); the ledger without `committedSinceRead` →
  `EngineSync2RegressionTests.swift:46:25` (b was admitted); an abandon that records no breaker outcome →
  `EngineSync2RegressionTests.swift:154:25` (the ensure did not complete).
- **S3-R4, the S1-15 run test.** 5.7–6.4 s in a debug build alone; under TSan in the whole Sync bundle at load 11–18 it
  took 59.93 s of its 60 s limit, so its guard is `.minutes(3)` (`a528809`); the 100,000-entry manifest's encode, decode,
  plan and apply are the cost, and the plan size is the test's subject (G3).

### S3F-15 [REQUIRED] S3-B-077, S3-B-078 — C2 measurements at 10,000 — **Done; one fix**

- **Retries falling due together** — `R-SYN-5: retries of 10,000 prefetch members falling due together hold the engine's
  actor at most C2's 10 ms per turn` (`BenchSync.dueRetriesTurns`). Before (`cebb52b`): runs [64.38, 73.19, 81.34] ms
  (over P-9's 50 ms too). Cause: `DeadlineHeap.popDue` removed the first entry one at a time (quadratic in the entries
  due), and `fireDue` took every due deadline in one turn. Fix (`937d793`): `popDue(at:limit:)` finds the due prefix by
  binary search and removes it at once; `fireDue` takes at most `dueDeadlinesPerTurn` (512), the rest stay due and the
  re-armed alarm fires again at once. After: runs [1.32, 5.07, 1.48] ms at load 55→493 (the host was saturated by
  other work during the run). Structural test: `R-SYN-5: an alarm turn takes at most dueDeadlinesPerTurn due deadlines,
  in order, and none that is not due`.
- **Cycle 2** (`243c6da`): `fireDue`'s use of the limit is pinned through the engine: `R-SYN-5: one alarm turn of the
  engine re-queues at most dueDeadlinesPerTurn retries that fell due together` (see "Cycle 2" for its mutant).
- **The 10,000-id prune announcement** — `R-SYN-12: announcing a 10,000-id prune to a stalled subscriber holds the
  engine's actor at most C2's 10 ms per turn` (`BenchSync.pruneAnnouncementTurns`): runs [6.12, 6.69, 6.81] ms at load
  435→334; under C2 at the reference scale, no change. The ~35 ms estimate at `maxEntries` (100,000) is outside C2's
  reference scale and was not measured.
- **The first turn of each re-admission event** — measured by the existing benchmarks whose window contains that turn:
  `networkEdgeTurns` (edge), `cooldownEndTurns` (breaker), `spaceReadmissionTurns` (space), `throttleExtensionTurns`.
- **`registerGroup`'s de-duplication and sort** — inside `handleRejoinTurns`' measured window (a 10,000-id registration).
- **Shutdown** — S3F-4.

### S3F-16 [REQUIRED] S3-B-084, S3-B-085 — comments — **Fixed** (`50561da`)

`releasesPerTurn`'s doc now gives the re-measured cost (about 8–9 µs per removal; `handleReleaseTurns` 4.1–4.8 ms per
512-member turn, WP-G's probe 4.3–4.6 ms). The drive's REENTRANCY comment (f-11) names the lifecycle, epoch and attempt
re-checks before `remote.transfer` (L5K-R25) as well as after it.

### S3F-17 [ADR-RECORD] — statuses, no code

| Item | Status |
|---|---|
| S3-B-066 | Accepted deviation (L4-R26 (3)): ENOSPC with a pending reclaim waits `awaitingSpace` within the retry budget, no timed backoff; needs a device test to show churn. Unchanged. |
| S3-B-067 | Accepted (confirmed at merge): a job that fits alone but not behind those admitted ahead stays parked until the next free-space read. Unchanged. |
| S3-B-071 | Open, no seam: the binding-ledger windows (M-RESOLVEREG, M-JOIN) have no deterministic probe; they cost at most one job and one read. |
| S3-B-072 | Unproven suspicion by reading; no probe produced it. Unchanged. |
| S3-B-073 | Unproven residue (a holder gained between `blobHolders` and the quarantine). Unchanged. |
| S3-B-074 | Covered by the `takeApplyTurn` seam (f-13); the fix does not depend on task priorities. Unchanged. |
| S3-B-075 | No seam arms a deadline inside the read; the four space interleavings stay unpinned. |
| S3-B-076 | By construction, not produced (`joinGroup`'s copy change between two batches). Unchanged. |
| S3-B-079 | Documented in §14 (model tests' liveness phase, F-40 site diffs). Unchanged. |
| S3-B-080 | Shutdown-time races hardened, not produced. The S3F-4 drain keeps their guards (every registration answers while `shuttingDown`). |
| S3-B-083 | Argued, not tested: no running engine reaches G-13's give-up after a running join's read. S3F-12's E2-shape test now covers the invariant side of a large give-up. |
| S3-B-086 | Recorded in ADR-055 and §14; no seam reaches the second iteration. Unchanged. |
| S3-B-087 | Documented; no supported host has one cooperative thread. Unchanged. |

No real seam reaches any of them in this cycle, so no test was written. Cycle 2: unchanged (S3-B-063 aside, which is
S3F-13's; the R-SYN-15 order and S1-09's halves, part of S3-B-070, are S3F-14's).

## Authorised edits outside WP-F

None, in either cycle. Every changed file is WP-F's (ARCHITECTURE §1.2): `Sources/ZTronAssetSync/**`,
`Tests/ZTronAssetSyncTests/**`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift`, and this draft. No contract signature
changed (`followApplied(from:)` moved between WP-F files with its signature; `supersede(_:settling:)` gained a defaulted
internal parameter).

## Proposed document changes (for the orchestrator at the Stage 3 merge)

- **§7.6, the `offline(reason)` row, beside PROBE-C9C-3's rule:** "A satisfied first conditions reading (at launch or
  after the idle teardown set the conditions to `nil`) counts as a satisfied-path edge: user work is dispatched before
  any reading exists, so a job that failed offline before it is re-queued by it, and one failing after it is retried at
  once (Stage 3, S3-CONC-04)." The same clause in §7.1's `downloading → queued` row.
- **§7.9:** "A progress slot keeps its first undelivered position only for the same key and run: the next run's first
  `syncProgress` takes a fresh slot behind the previous run's `syncFinished` and its own `syncStarted`, and the
  superseded progress is dropped (Stage 3, S3-CONC-03)."
- **§7.10 (shutdown):** "Shutdown cancels the running attempts' handles over `inFlight`, drains every continuation and
  catalog-sized table out of the state, and answers and frees them at most `shutdownStepsPerTurn` (512) steps per turn
  (C2; Stage 3, S3-PERF-01)." And "The follow after an apply visits the jobs of the ids the copy's change moved plus
  `unfollowed`; a run's release of re-attachments visits `systemHeld`; its end visits `RunState.held` (S3-PERF-02)."
  And "An alarm turn takes at most `dueDeadlinesPerTurn` (512) due deadlines; the rest fire in the next turn (S3-B-077)."
- **§7.4 and DECISIONS F-30/F-31 (L4-R18) paragraph:** replace "A re-join that changes lane, or comes from user work,
  still goes to the back through `relane` (L4-R24(4), Stage 3)" with "A re-join is reinstated at its place in the queue
  its lane now selects, whatever lane the interest brings (Stage 3, S3-B-065)."
- **§7.2 / G-13 (L5-R16):** "A job only a pending claim keeps counts its failed attempts against the retry policy of the
  lane it held (Stage 3, S3-B-081)."
- **§10.2, new row:** `RE-S43 | shutdown: `settle(_:with:)`'s `Task.yield()` between slices, and `performShutdown`'s
  awaits of it | nothing: the drained continuations and tables belong to the call, and while the lifecycle is
  `shuttingDown` no new one is registered; the join loop drains again after each join`.
- **§12.3:** S1-07 and S1-11 regression tests now exist (names as in the table); S1-01, S1-09's halves, S1-12 and
  S1-15's run form remain not written. **§12.4:** S2-01's `ensureAvailable` form, S2-09 and S2-10 remain not written.
- **§14:** the S3F-10 regions above as candidates; S3-B-063's lazy re-admission as a Stage 3 follow-up with its
  invariant redefinition.
- **§1.2:** WP-F's new files: `Sources/ZTronAssetSync/Engine/EngineShutdown.swift`; tests
  `EngineFirstReadingTests.swift`, `EngineRunIntegrityCapTests.swift`, `EngineShutdownDrainTests.swift`,
  `EngineFollowTests.swift`, `EngineGateConformanceTests.swift`, `EngineBoundaryTests.swift`,
  `EngineEventOrderTests.swift`, `EngineRejoinLaneTests.swift`, `EngineClaimRetryTests.swift`,
  `EngineGiveUpInvariantTests.swift`, `EngineSync1RegressionTests.swift` (all under `Tests/ZTronAssetSyncTests/Engine/`).
- **DECISIONS (L4-R8 precedent):** the S3F-2 hang guards with their measurements (table above).

Cycle 2 adds:

- **§7.7 (circuit breaker), the "any other exit" sentence:** replace "re-admits in that turn every job the breaker parked (the
  first dispatched probes, the others park again)" with "re-admits the first job the breaker parked in the pump's order
  (`CircuitParkedOrder`, by queue rank then ticket; O(log n)), and so does a cooldown's end or a silent probe's watchdog;
  the others stay parked while that job waits in the queue to take the probe, and the pump's end re-admits the next when
  it was parked for another gate or ended; a joiner of a job left parked gets the park's fail-fast answer (Stage 3,
  S3-B-063, L4-R22). A closed breaker re-admits every parked job, `readmissionsPerTurn` per turn."
- **§7.10 settling and F-40 (§14 "the gate model"):** "A claim parked by a breaker that admits only a probe counts as
  working while a queued job ranked at or before it will take the probe (I3 for a probe-only breaker)."
- **§7.10, the follow:** "The follow after an apply compares the replaced copy with the copy at most
  `followScansPerTurn` (16,384) entries and `followFormatsPerTurn` (2,048) changed transfers per turn and visits at most
  `followsPerTurn` (256) jobs per turn; the rest is owed to owned follow-up turns; a job owed a visit is in `unfollowed`;
  no run settles and no job held for a catch-up is released while a follow is owed (Stage 3, S3F-5's residual)."
- **§7.10, shutdown (R-SYN-15):** "Shutdown marks `closingStore` after it joined every owned task and before it closes the
  store; the engine-side test of that order reads the mark."
- **§10.2, new row:** `RE-S44 | the follow's follow-up turn (`followFollowUp`, an owned task's hop) | the owed passes and
  the visit cursor (a newer apply's follow may have extended or restarted them), the copy as it stands (each pass compares
  with it), whether each job is still owed a visit (`unfollowed`, which `removeJob` leaves) and exists, and its state and
  ids`.
- **§11:** `R-SYN-5`'s probe-chain benchmark runs at 10,000 members; `R-SYN-6`'s new C2 benchmark of a refresh changing
  every member of a waiting 10,000-member group (`changedRefreshTurns`).
- **§12.3 / §12.4:** every regression test named there is written (cycle 2 table above); remove "not written at the
  level-4 merge" from S1-01, S1-07, S1-09, S1-11, S1-12, S1-15, S2-01, S2-09 and S2-10, and point S1-09's halves and
  R-SYN-15's order at the new names.
- **§14:** remove "R-SYN-15's join-before-close order has no engine-side assertion" (it has one); add the S3F-10 regions
  recorded above (maintenance's exit after eviction, the adoption-report failure, the pending-run gate's `.unarmed`
  re-arming, and cycle 2's new guards: the follow's unspawnable or empty follow-up, a visited job that no longer exists or
  did not move, `readmitForProbe`'s illegal-transition `continue` and no-breaker return, `readmitOpenedOriginGates`' eager
  branch for a closed breaker); note that the stale re-admission branches remain as already listed; the strict R-INT-5
  engine path (a checksum-less resolve under `allowUnverifiedAssets = false` downloads, then the store refuses) as an
  observed behaviour for the orchestrator's decision. Replace L4-R22's "Stage 3 hardening" text with "done in Stage 3
  (S3-B-063)".
- **§1.2:** WP-F's new files in cycle 2: `Sources/ZTronAssetSync/Engine/EngineFollow.swift`,
  `Sources/ZTronAssetSync/Engine/CircuitParkedOrder.swift`; tests `EngineProbeChainTests.swift`,
  `EngineSync1LivenessTests.swift`, `EngineSync1HalvesTests.swift`, `EngineSync2RegressionTests.swift`,
  `EnginePublicationRefusalTests.swift`, `EngineMaintenanceStepTests.swift`, `CircuitParkedOrderTests.swift` (all under
  `Tests/ZTronAssetSyncTests/Engine/`).
- **DECISIONS (L4-R8 precedent):** the S1-15 run test's hang guard (3 min; 59.93 s under TSan at load 11–18).

## Gate evidence (cycle 1)

All runs on this branch at `60eab9c`/HEAD (tests only changed after `60eab9c`: two `try` markers), scratch
`.build-s3f*`, on a shared host whose load swung from 20 to 630 during the runs (loads quoted per step).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (12:25, load 630→51): `VERIFY: PASS`; Transport 151,
  Sync 374, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. The first `--quick` (11:52)
  ended `VERIFY: FAIL (1 failed: tests)`: the new S1-11 test's first form read a `failed(.at)` state the jittered retry can
  skip (`EngineSync1RegressionTests.swift:116:9`); rewritten in `60eab9c` (S3F-14), no production change.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors`: `Build complete!
  (105,63 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug): `✔ Test run with 374 tests in 52 suites passed` after 11.04 s, 8.41 s, 8.34 s
  (load 48.6–77.0).
- **TSan once** (`.build-s3f-tsan`): `✔ Test run with 374 tests in 52 suites passed after 74.410 seconds` (load ~59);
  the S3F-2 tests took 13.1 s (R-CAR-4), 32.7 s (R-SYN-14), 32.8 s (R-SYN-6), 39.8 s and 40.8 s (R-STO-11), 55.3 s
  (R-SYN-2 model walk), each within its guard.
- **Coverage** (`--enable-code-coverage`, all targets passed): `COVERAGE target=ZTronAssetSync lines= 93.60% (8804/9406)
  min=90.0 OK`, overall 96.56 %, `COVERAGE: PASS`.
- **iOS:** `xcodebuild … -destination 'generic/platform=iOS' … OTHER_SWIFT_FLAGS='-warnings-as-errors'` exit 0. **iOS
  Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.29_12-30-58`):
  `result Passed, totalTestCount 1328, passedTests 1328, failedTests 0, skippedTests 0`. The first simulator run (12:07)
  failed to build: `EngineClaimRetryTests.swift:48:9: error: no calls to throwing functions occur within 'try' expression`
  under `-warnings-as-errors`; fixed with the second marker in the same pattern. Simulator shut down afterwards.
- **Mutants (S3-R3)**, scratch copy `.build-s3f/mut/src`: all ten killed (S3-CONF-02, -03, -04, -05; M-N-09, -12, -14,
  -16, -20, -39); failing lines under each item.
- **WP-F benchmarks** (`swift test -c release … --filter SyncBenchmarks`, 12:36–12:40, load 113→23): 18 of 19 passed:
  P-4 12.64 ms (ratio 2.12), P-7 4.09/1.80 MiB, P-11 speedup 3.22, P-14 0/0; the new C2 benchmarks shutdown 1.38–1.55 ms,
  refresh 1.21–1.26 ms, prune announcement 4.94–5.05 ms, due retries 0.87–0.96 ms; the existing C2 benchmarks 0.02–9.94
  ms best. `R-SYN-5: a 429 that extends the throttle under 10,000 user-initiated waiters …` missed (runs [38.71, 21.83,
  44.47] ms at load ~110–200) and passed alone right after at load 22–29 (runs [6.77, 7.54, 7.18] ms): a load miss.
  `R-SYN-5: a chain of half-open probes …` passed in the full run (best 2.19 ms) but failed once alone at load ~22–29
  (runs [16.02, 35.68, 81.45] ms); compared head to head with `s3-base` (release, same host, 12:47–12:49, load 305→91):
  base [33.30, 21.10, 44.89] ms (fail) then [6.39, 2.59, 3.06] ms (pass); HEAD [6.52, 4.13, 4.90] ms then [2.34, 8.63,
  394.13] ms (both pass); chain totals base 4.0–11.3 s, HEAD 5.1–10.9 s. A load miss on both trees, not a regression
  (S3F-13 still owes this benchmark's quadratic total).

## Gate evidence (cycle 2)

All runs on this branch at `a528809` (HEAD of the code; the draft's own commit changes this file only), scratch
`.build-s3f*`, on the shared 8-core host whose load swung from 4 to 200 during the runs (loads quoted per step).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (16:16–16:20, load 28→15): `VERIFY: PASS`; Transport
  151, Sync 399, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. (An earlier `--quick` at
  `eab2d5b`, 15:42–15:47, also `VERIFY: PASS`.)
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (15:47): `Build
  complete! (29,19 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug, load 31–36): `✔ Test run with 399 tests in 52 suites passed` after 19.83 s, 17.92 s,
  12.14 s. (Also ×3 at `eab2d5b`, load 8.6–16.8: 12.17 s, 13.37 s, 10.66 s.)
- **TSan once** (`.build-s3f-tsan`, 16:11–16:13, load 200→51): `✔ Test run with 399 tests in 52 suites passed after
  61.554 seconds`. The longest: the S1-15 run test 61.5 s (guard 3 min; it was 59.93 s of its former 60 s in the run at
  `eab2d5b`, 15:49–15:51, load 11–18, `✔ … 399 tests … passed after 59.931 seconds`), the stalled-subscriber test 49.1 s
  (guard 4 min), the gate walks 40.8 s and 40.6 s and the model walk 40.2 s (guards 5 min); every cycle-2 test under 20 s
  (the alarm-turn bound 18.7 s, the shutdown drain 13.7 s, the bounded follow 13.5 s at load 11–18).
- **Coverage** (`--enable-code-coverage`, all seven test targets passed, 16:04–16:11): `COVERAGE target=ZTronAssetSync
  lines= 94.04% (9187/9769) min=90.0 OK` (cycle 1: 93.60 %, 8804/9406), overall `96.68% (25695/26577)`, `COVERAGE:
  PASS`. (`ZTronAssetKit 97.63% (1441/1476)` against 97.83 % before: WP-G's schedule-dependent lines, §14; no Kit file
  changed.)
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (15:52). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.29_15-52-52-+0100.xcresult`, 15:52–15:58,
  load 20→143): `result Passed, totalTestCount 1353, passedTests 1353, failedTests 0, skippedTests 0` (`** TEST SUCCEEDED
  **`); the simulator is shut down.
- **Mutants (S3-R3 practice, scratch edits in place, each rebuilt and reverted; `git status` clean after each):** S1-11's
  strand, the settle without chunks, `fireDue` without its limit, the follow without its visit bound and without its
  settle guard, `manifestCaughtUp` without its follow guard, the eager breaker re-admission, the missing pump-end hook,
  the parked order without its rank check, M5, M6, the alarm without its token check, a stale watcher unregistering its
  successor, the ledger without committed bytes, an abandon without a breaker outcome: all killed (lines under each
  item and in "Cycle 2").
- **WP-F benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter
  SyncBenchmarks`, 15:59–16:04, load 53.7→5.1): `✔ Test run with 20 tests in 2 suites passed after 213.772 seconds`.
  P-4 11.53 ms (budget 20.0), ratio 2.05 (max 2.5); P-7 4.89 / 0.97 MiB; P-11 speedup 3.15 (min 3.0); P-14 0 timers, 0
  tasks; the stalled prune ratio 1.41. C2 (best of three, ms): the new `changedRefreshTurns` [3.73, 3.71, 3.75]; the
  probe chain at 10,000 [0.76, 0.73, 0.86], totals [40.3, 48.5, 44.1] s; cooldown end [0.07, 0.06, 0.07]; shutdown
  [1.75, 1.53, 1.37]; refresh under a group [1.22, 1.22, 1.27]; prune announcement [5.01, 5.00, 4.99]; due retries [0.86,
  0.86, 0.90]; releases 4.6–4.9; re-joins 4.9–5.1; space parking 4.1–4.2 and 3.1–3.6; space re-admission 4.4–4.6; network
  edges 1.1 and 4.5–4.6; throttle extension [14.39, 7.14, 17.22] (best 7.14, passing). The cycle-1 verifiers' load misses
  (P-4 at loads 13–189, P-11 2.51, the throttle extension's 20.6 ms best) did not recur at this load; P-4 and P-11 rest on
  code this close-out did not touch.

## Not verified here

- Device-only behaviour (NWPathMonitor's first callback timing behind S3-CONC-04, background URLSession, real packs,
  thermal and Low Power Mode).
- The ~35 ms prune announcement at `maxEntries` (outside C2's reference scale).
- Cycle 1 left S3F-10, S3F-13 and part of S3F-14 open; cycle 2 closed them (above). Still not reached by any test: the
  S3F-10 regions recorded above as §14 candidates, `other-wp:b` or `other-wp:g`.
- The level-4 verifier's mutants M5 and M6 are not on file: they are reconstructed from `f.md` F-20's description (close
  before the join; no join).
- The probe chain's total wall time at 10,000 (20–48 s across runs and loads) is reported, not budgeted; its scaling is
  pinned by the structural count of one re-admission per exit, not by the wall time, which the fake source's round trip
  and the benchmark's polling dominate.
