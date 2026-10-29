# Stage 3 close-out `s3f` — WP-F (sync engine), cycle 1

Branch `wp/s3f` from tag `s3-base`. Rulings: `.build-orchestrator/s3-rulings-s3f.md`; findings:
`.build-orchestrator/s3-findings-s3f.json`. WP-F's Stage 2 record is `docs/adr-drafts/f.md` (background only).

## Orchestrator rulings (close-out)

Each ruling below is recorded as given in the rulings file and applied in this cycle.

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

### S3F-10 [REQUIRED] S3-CONF-08 — uncovered Sync regions — **Open (not reached in cycle 1)**

No behaviour test was added for the listed regions in this cycle. The regions, as §14 candidates until tests reach
them: the engine's handling of a publication the store refuses (`unknownAsset`, `notPresent`, `assetFailed`,
`unverifiedRejected`; R-INT-5 with `allowUnverifiedAssets = false`); an uncommanded `.cancelled(.byClient)` re-queue
(§7.6 T7/T13); the progress replay for a subscriber joining mid-run; maintenance exhausting its budget between steps and a
step that throws (R-SYN-16, L4-R5); the pending-run gate re-arming for conditions, breaker and throttle; stale edge and
origin re-admissions; an apply adding an id over a detached record. The Kit regions (follower and group-registration
races, `withAsset`'s "root vanished after every reopen") are **other-wp:g:**. Sync line coverage after this cycle:
93.60 % (8804/9406), up from the hunter's 93.49 %; the gate's floor is 90 %.

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

### S3F-13 [REQUIRED] S3-B-063 — lazy re-admission for probe chains — **Open (deferred to cycle 2)**

Not implemented in this cycle. A lazy re-admission (re-queue only the next parked job when a probe exits without a
verdict, from an ordered index of `circuitParked` by `(rank, ticket)`) changes what the engine's gate invariants mean:
today no job may stay parked against a gate that admits at `now` (F-40; `EngineGateModelTests`, `checkRunSettled`'s
"parked claim counts as working"), and a lazy design deliberately leaves all but one parked while the half-open breaker
would admit a probe. The invariants and the run-settling rule need a reviewed redefinition (e.g. "the head of the
ordered parked index is queued or probing") before the change; doing it inside this cycle risked the five blocking
fixes. The `probeChainTurns` benchmark therefore still runs at 1,000 members (10,000 would take about 161 s under the
quadratic total).

### S3F-14 [REQUIRED] S3-B-068, S3-B-069, S3-B-070 — §12 regression names — **Partly done**

Written (`EngineSync1RegressionTests.swift`, `extension EngineRegressionTests`, commit `ee95eb8`), both passing (no
bug found):

- S1-11 — `R-SYN-2: a transfer stream that ends without a terminal element fails the job instead of stranding it`
  (a `TruncatingSource` returns a handle whose stream finishes with no element; the engine records the attempt's
  `incompleteCallbackSequence` failure once, and the retry delivers the asset; the first form read the `failed(.at)`
  state, which the backoff's full jitter can make due at once, and failed once in `verify.sh --quick`, so it was
  rewritten in `60eab9c`).
- S1-07 — `R-SYN-7: a user resolve of a policy-blocked bulk asset starts at once and its demotion pauses it again`.

Open for cycle 2: S1-01 (both names), S1-12, S1-15's run form, S2-09, S2-10, S2-01's `ensureAvailable` form, S1-09's
replaced-alarm and replaced-watcher halves (the watcher half can use `GatedConditionsSource` to hold the old watcher in
`conditions()` while a new one starts), and the engine-side join-before-close assertion for R-SYN-15 (it needs an
observable mark of the store's close, e.g. a `closingStore` flag checked by a condition observer, since `close()` drains
and the file-system record cannot tell M5/M6 apart).

### S3F-15 [REQUIRED] S3-B-077, S3-B-078 — C2 measurements at 10,000 — **Done; one fix**

- **Retries falling due together** — `R-SYN-5: retries of 10,000 prefetch members falling due together hold the engine's
  actor at most C2's 10 ms per turn` (`BenchSync.dueRetriesTurns`). Before (`cebb52b`): runs [64.38, 73.19, 81.34] ms
  (over P-9's 50 ms too). Cause: `DeadlineHeap.popDue` removed the first entry one at a time (quadratic in the entries
  due), and `fireDue` took every due deadline in one turn. Fix (`937d793`): `popDue(at:limit:)` finds the due prefix by
  binary search and removes it at once; `fireDue` takes at most `dueDeadlinesPerTurn` (512), the rest stay due and the
  re-armed alarm fires again at once. After: runs [1.32, 5.07, 1.48] ms at load 55→493 (the host was saturated by
  other work during the run). Structural test: `R-SYN-5: an alarm turn takes at most dueDeadlinesPerTurn due deadlines,
  in order, and none that is not due`.
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

No real seam reaches any of them in this cycle, so no test was written.

## Authorised edits outside WP-F

None. Every changed file is WP-F's (ARCHITECTURE §1.2): `Sources/ZTronAssetSync/**`, `Tests/ZTronAssetSyncTests/**`,
`Tests/ZTronAssetKitBenchmarks/BenchSync.swift`, and this draft.

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

## Gate evidence

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

## Not verified here

- Device-only behaviour (NWPathMonitor's first callback timing behind S3-CONC-04, background URLSession, real packs,
  thermal and Low Power Mode).
- The ~35 ms prune announcement at `maxEntries` (outside C2's reference scale).
- S3F-10, S3F-13 and the open part of S3F-14 (above).
