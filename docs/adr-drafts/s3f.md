# Stage 3 close-out `s3f` — WP-F (sync engine), cycles 1 to 7

Branch `wp/s3f` from tag `s3-base`. Rulings: `.build-orchestrator/s3-rulings-s3f.md`; findings:
`.build-orchestrator/s3-findings-s3f.json`. WP-F's Stage 2 record is `docs/adr-drafts/f.md` (background only).

## Orchestrator rulings (close-out)

Each ruling below is recorded as given in the rulings file and applied in cycles 1 to 3. Cycle 2 applied them again to
the cycle-1 verifiers' findings (the section "Cycle 2" below), and cycle 3 to the cycle-2 verifiers' findings (the section
"Cycle 3"); no ruling changed, and no new ruling was issued, so S3F-13 is implemented rather than demoted. In cycle 3 the
rulings file was re-read: S3-R1 (the blocking finding first, its failing test committed on its own before the fix),
S3-R2 (the probes PROBE-W1 and PROBE-W4/W4b renamed into `EngineFollowTests`), S3-R3 (every mutant re-applied in place,
rebuilt, run and reverted), S3-R4 (the hang guards re-measured, below), S3-R5 (the fix keeps the follow's per-turn bound:
a queue head waiting for the follow is left in place, not followed by the pump), S3-R6 and S3-R7 (only WP-F's files and
this draft changed) and S3-R8 (P-13 stays `other-wp:b`). In cycle 4 the rulings file was re-read again (no ruling changed or
was added): S3-R1 (the blocking correctness finding's failing test `996ac21` committed before its fix `c8f01ca`), S3-R3
(the fix's two hooks each removed in place and shown to fail the new test), S3-R4 (every hang guard over half its limit
beside a second TSan process at a load at most about 30 raised to `.minutes(3)` with its measurements; the S1-15 run test,
which is neither model-based nor exhaustive, stays at `.minutes(3)` over half of it, and a ruling is requested below),
S3-R5 (the probe-chain benchmark passes C2 at 10,000 on a quiet host), S3-R6/S3-R7 (only WP-F's files and this draft) and
S3-R8 (P-13 and the store's per-404 index commit routed `other-wp:b`). In cycle 5 the rulings file was re-read again: no ruling changed
or was added, and at that time it held no ruling on the S1-15 run test's guard (requested in cycle 4), so that guard stayed
`.minutes(3)` (S3-R4 reserves `.minutes(5)` for model-based or exhaustive tests) and the request stood; S3-R1 (the
blocking correctness finding's failing test `04ae782` committed before its fix `e18d5aa`), S3-R3 (each branch's budget
removed in place and shown to fail the new test), S3-R5 (the fix bounds the sweep's follows per turn, pinned by a
structural test and a `c2Budget` benchmark), S3-R6/S3-R7 (only WP-F's files and this draft) and S3-R8 (P-13 and the
per-404 index commit stay `other-wp:b`). The statement that no ruling exists on that guard is no longer true: the
orchestrator added **S3-R10** to the rulings file on 2026-10-30 (the file was saved at 03:00:55, after cycle 5's last
commit `39dadd4` at 01:18:56), and cycle 6 applies it. In cycle 6 the rulings file was re-read: S3-R1 to S3-R9 are
unchanged and S3-R10 is new; applied: S3-R1 (the blocking correctness finding's failing test `48c8dfc` committed before
its fix `b94fd27`), S3-R2 (PROBE-C5-LANEDROP renamed into `EngineFollowTests`), S3-R3 (the fix's re-judgement and the
sweep's park bound each mutated in place and shown to fail a test), S3-R4/S3-R10 (S1-15's run test guard raised to
`.minutes(5)`, nothing cut, figures recorded; the other guards re-measured), S3-R5 (the re-judgement is O(1) per
re-queued job; the cycle-5 C2 benchmark re-run), S3-R6/S3-R7 (only WP-F's files and this draft) and S3-R8 (P-13, the
per-404 index commit and the Storage time-outs at load 100–540 reported `other-wp:`). In cycle 7 the rulings file was
re-read (unchanged since 03:00:55; S3-R10 is still the last ruling, and none answers the cycle-6 hang-guard margins):
applied: S3-R1 (the blocking correctness finding's failing test `69e209e` committed before its fix `22c7b89`), S3-R2
(PROBE-C6-LANEGAIN, PROBE-C6-READDROP and PROBE-C6-PARKFIGURES renamed into `EngineFollowTests`), S3-R3 (the cycle-6
survivors `skipNotFit` and `requeueNoAhead` re-applied in place and shown to fail the strengthened test), S3-R4 (every
one-minute Sync test over half its guard beside a second TSan process raised to `.minutes(3)` with its measurements,
nothing cut), S3-R5 (the fix adds one O(1) `spaceBlock` per parked job the sweep follows), S3-R6/S3-R7 (only WP-F's
files and this draft) and S3-R8 (P-13, the per-404 index commit and the Storage figures stay `other-wp:`).

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
- **Orchestrator ruling (close-out) S3-R10 — Orchestrator ruling (Stage 3), added 2026-10-30: S1-15's run test hang
  guard.** `R-SYN-3: a 100,000-entry plan never materialises more than the pipeline plus the lookahead as jobs`
  (`EngineSync1LivenessTests.swift`, `runMaterialisesAPipelineAtATime`) may take `.timeLimit(.minutes(5))`: its cost is
  the SPEC-mandated scale (S1-15's 100,000-entry catalog) decoded by WP-A's parser under TSan, not WP-F's own work
  (101.8–130.1 s beside a second TSan process at load 10–32, 34–43 % of 5 minutes; 47.5–72.3 s alone). Every entry,
  operation, assertion and cancellation check stays (G3), and the figures go in the test's doc comment and here. The
  parser's sanitizer cost is not a defect (a release build decodes the manifest in well under a second): it is recorded
  as a note for Stage 5's residual risks, with no WP-A change. Verifiers judge the guard by S3-R4's rule against 5
  minutes: blocking only if the test exceeds half of 5 minutes at a load of about 30 or less, or if the raise came with
  any cut to the test. Applied in cycle 6 (`daa2ba8`; "Cycle 6" below).
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

## Cycle 3: the cycle-2 verification findings

Every finding of the two cycle-2 lenses, with its disposition; the blocking one first (failing test `8b688ad` committed
on its own, fix `df5cfe3`). Mutants were applied in place on the committed tree, rebuilt in `.build-s3f`, run and reverted
(`git status` clean after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | Regression of the bounded follow: a waiter of a listed id answered `notFound` (PROBE-W4/W4b), and transfers of replaced content dispatched after the apply (PROBE-W1/W1b) | **Fixed** (below) |
| reqs | S3F-4: the settle's yield unpinned (deleting both yields survived) | **Fixed** (`6cd13e9`): an observer on the engine's actor, queued before the shutdown, reads the slices between its own yields and must see a count strictly between 0 and the last. Mutant `noyield` (both `await Task.yield()` deleted): `EngineShutdownDrainTests.swift:62:9: Expectation failed: seen.contains { $0 > 0 && $0 < slices.count }` |
| reqs | S3F-14: a close moved alone before the joins (close-only M5) survived | **Fixed** (`e58a34f`): `closeStore()` sets `closingStore` and closes in one step, and the R-SYN-15 test reads the store while the shutdown joins the task its bulk unit holds (it must still be open). Mutants on the new code: close-only M5 (`await self.store.close()` added before the join loop) → `EngineSync1HalvesTests.swift:223:9: Expectation failed: openWhileJoining`; M5 (`closeStore()` moved before the join loop) → `:222:9` (`record.tasksAtMark.allSatisfy { $0 == 0 }`) and `:223:9`; M6 (no join) → `:222:9` and `:223:9` |
| reqs | S3F-10: an uncommanded client cancel treated as the system's (retry with backoff) survived | **Fixed** (`dc964d7`): a condition observer records the job's states, counted attempts and retry deadlines; the test also checks `metrics.retries`. Mutant `r3cancel`: `EnginePublicationRefusalTests.swift:146:9: Expectation failed: after.retries == FailureCounts()`, `:154:9` (`!record.states.contains { $0.kind == .failed }`), `:155:9` (`record.attempts == 0`), `:156:9` (`record.retries == 0`) |
| reqs | S3F-10: the maintenance exit after orphan collection unpinned (eviction was a no-op) | **Fixed** (`758c22f`): new `R-SYN-16: maintenance whose time budget runs out during orphan collection evicts nothing from a store over its budget` (a store over a 64-byte budget whose assets left the retention scope; a maintenance with time to spare then evicts them, the control). Mutant `r5budget` (the check after `collectGarbage` disabled): `EngineMaintenanceStepTests.swift:136:9: Expectation failed: report.budgetExhausted && report.evictedBytes == 0`, `:138:9`, `:140:9` |
| reqs | S3F-10: the `assetFailed` refusal indistinguishable from `notFound` | **Fixed** (`dc964d7`): the test runs for a 404 record and an unreadable one (`integrityFailure`). Mutant `r2split` (`.assetFailed` moved into the `notFound` branch): `EnginePublicationRefusalTests.swift:91:9: … reason → .unreadable … Expectation failed: answer == .failure(expected)` |
| reqs | Records: cycle-1 proposals for §12.3/§12.4 and §14 contradicted cycle 2's | **Fixed**: removed; "Proposed document changes" now carries one set (cycle 2's texts) |
| reqs | Hang-guard margins of the cycle-2 tests under TSan (observation) | Re-measured under TSan in this cycle ("Gate evidence (cycle 3)"); no guard changed (see there) |
| reqs | `probeChainTurns` noisy at 10,000 (observation) | No change for WP-F; re-run in this cycle's benchmarks; the orchestrator re-runs it on a quiet host at the merge |
| correct | The alarm-turn test's TSan margin | Re-measured in this cycle's TSan run (below); S3-R4 applied to the measurement |
| correct | PROBE-W3: the parked order's rebuild at 9,994 jobs took 5.1–6.3 ms in one call | Recorded, no code: within C2 by itself; a turn that combines it with a join batch or a pump's parks is not benchmarked (§14 candidate below) |
| correct | other-wp:b: P-13 | **other-wp:b:** `BenchStorage.swift` is WP-B's; not touched; routed to WP-B |

### The blocking finding: replaced content acting before its follow visit — **Fixed**

*Finding:* since the bounded follow (`958348e`), an id whose content an apply changed keeps its interest on the job of
its replaced content until the follow visits that job, up to about 40 turns later at 10,000. (1) A failure of that job's
attempt in the window was delivered to every interest, so a listed id's waiter got `notFound` (F-20) and a prefetch
member was settled; (2) every pump between follow turns dispatched the replaced content's jobs, still queued ahead of the
new content's (PROBE-W1b: 44 of 48 starts after the apply at 3,000 members).

- **Failing tests first** (`8b688ad`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, the probes renamed into
  `EngineSyncTests`):
  - `R-CAR-2: a failure of an id's replaced content before its follow visit answers the id's waiter from its new content`
    (PROBE-W4 with the hold seam, 600 ids; arguments `notFound` (a 404), `serverErrorAtCap` (a 503 at an interactive cap
    of 1), `noSpace` (ENOSPC)). At `8b688ad`: `EngineFollowTests.swift:276:9: Expectation failed: (try? answer.get()) !=
    nil` with `failure(AssetError.notFound)`, `failure(AssetError.serverUnavailable(retryAfter: nil))` and
    `failure(AssetError.insufficientSpace(required: 5000, available: 0))`, and `:277:9` (the new content never fetched).
  - `R-SYN-2: a 404 for a prefetch member's replaced content before the follow's pass reached it moves the member to its
    new content` (PROBE-W4b's shape with the hold seam: `followFormatsPerTurn` + 64 members, the member listed last so
    the pass has not reached it). At `8b688ad`: `:324:9: Expectation failed: after.pending == [replacement.transferID]`
    (`[]`: the member was settled by the 404) and `:325:9`.
  - `R-SYN-2: no transfer of a replaced content starts after the apply while a bounded follow still owes its job`
    (PROBE-W1 with the hold seam, 700 members, two slots). At `8b688ad`: `:369:9: Expectation failed:
    startedBetween.isEmpty` (`2 transfers of replaced content started after the apply`), `:370:9`, `:377:9`.
- **Fix** (`df5cfe3`, then `2fb46be` and `776748a`, each after its own failing test). Two predicates in
  `EngineFollow.swift`, both false unless a follow is owed (one lookup and one formatted transfer per id of the job):
  `holdsMovedID(_:)`, the job holds an id the copy *lists* at another transfer; `awaitsFollow(_:)`, the job holds an id
  the copy does not map to its content (listed elsewhere or dropped). Either covers the jobs the follow owes a visit,
  those its pass has not reached, and any joined meanwhile for a replaced entry.
  - (1) Failures: `followBeforeActing(_:)` brings the follow's visit forward (the private `follow(_:)`, unchanged) where a
    job holding a moved id is about to answer its interests with a failure: `resolveAll` for `.failed` outcomes (the 404,
    auth, `rejected`, integrity, the 429 and backoff give-ups, every publication refusal), `countFailedAttempt` (an
    answer at the cap) and `spaceFailed` after its free-space read (the park's figures). The moved ids' interests follow
    their new content (T22); only the ids the copy still maps to the content get the failure; a pump is scheduled for the
    new jobs. A dropped id is not counted here: a waiter joined from the store's newer manifest (`EngineManifest.join`)
    holds an id the copy does not list yet, and the follow would end it `.notFound`; a dropped id's interest therefore
    gets the failure's own answer rather than the follow's `.notFound` (no rule forbids it; F-20 concerns listed ids).
  - (2) Dispatch: `dispatch(_:parkLimit:)` leaves a job that `awaitsFollow` at the head of its queue (`.waitsForFollow`)
    and the pump stops that queue for the turn; `hasQueuedUser()` does not count a user queue whose first ready entry
    awaits the follow, so such a job neither preempts a running transfer nor keeps the other lanes from a free slot;
    `pumpWaitsForFollow` makes every follow turn pump again and counts as a dispatch owed for a pending run behind the
    breaker (F-41). The pump does not follow the job itself: that would move up to a queue of jobs per pump and break
    the follow's per-turn bound (C2; `followIsBoundedPerTurn` pins 256 moves per turn and still passes). A job joined
    from the store's newer manifest waits too while a follow is owed, harmlessly (it starts when the follow ends).
  - New `invariantViolations()` rule: a pump waiting for a follow nothing owes. Shutdown resets the flag.
- **Found while fixing, each failing test first:**
  - `48d9d59` (failing) / `2fb46be` (fix): `R-SYN-2: a queued user job of an id the apply dropped does not start while
    the follow still owes its visit` (700 changed prefetch members, two user transfers in both slots, the dropped id's
    user job queued; a slot freed between follow turns). At `48d9d59`: `EngineFollowTests.swift:427:9: Expectation
    failed: !startedBetween.contains(dropped.transferID)` (`the dropped id's transfer was requested after the apply`),
    `:428:9`, `:435:9`: the first dispatch check counted only listed ids. After the follow the waiter is answered
    `.notFound` (T21).
  - `c0c0563` (failing) / `776748a` (fix): the same test with an unchanged two-member prefetch group: the freed slot
    goes to its member and nothing is preempted. At `c0c0563` (the per-round `userWaitsForFollow` flag of `2fb46be`):
    `EngineFollowTests.swift:437:9: Expectation failed: between.preemptions == preemptions` (7 against 0: once a
    prefetch member started, the next round's `hasQueuedUser()` counted the waiting job and preempted it, and so on).
    The test's earlier check of the internal `pumpWaitsForFollow` flag was dropped in that commit, with the reason: a
    later pump with every slot taken stalls no head, so the flag reads false while the job still waits (the job's
    `queued` state and the absent start are still asserted).
- **The ENOSPC case's scenario** changed in the first fix commit: on the 4 KiB volume of the first form the new content
  could not fit either (after the fix: `insufficientSpace(required: 16, available: 0)`), so the case now asks for 1 TiB
  on the default volume; the `noSpaceHook` mutant below shows it fails without the fix.
- **Mutants** (in place on `776748a`; filter `replacedContentFailure|noReplacedContentStarts|droppedUserJobWaitsForTheFollow`;
  lines under "Gate evidence (cycle 3)"): `noResolveAllHook`, `noCountHook`, `noSpaceHook`, `noDispatchStall`,
  `listedOnlyAtDispatch` (dispatch counting listed ids only), `owedVisitsOnly` (`holdsMovedID` also requiring
  `unfollowed.contains`, so a job the pass has not reached is missed), `userHeadCounted` (`hasQueuedUser` counting a
  head that awaits the follow). The whole fix removed is the failing commit `8b688ad` above. `.waitsForFollow`
  breaking only the `switch` (not the user queue's loop) livelocks the pump on the actor: the test hung and was killed
  after 30 minutes (a hang, so killed, but no time-limit line is printed).
  - **Surviving, recorded:** the `|| self.state.pumpWaitsForFollow` terms of `continueFollow`'s two pump conditions
    (`noFlagPump`: the whole Sync bundle, `✔ Test run with 403 tests in 52 suites passed`). A queue head waits for a
    job the follow owes a visit or whose entry its pass has not reached, and that visit moves it, so the turn pumps on
    `moved` already. The terms are a liveness net for a head the follow never visits (a job joined meanwhile for a
    replaced entry, or from the store's newer manifest); no seam orders one before the follow's last turn, and the
    invariant rule reports a flag left set once the follow ended (§14 candidate below).
- **C2:** the stall costs one queue head per lane and pump; the follow's per-turn bound is unchanged
  (`changedRefreshTurns` and `followIsBoundedPerTurn` re-run below).
- **REENTRANCY:** no new `await` in production code (the hooks are synchronous; `spaceFailed`'s existing f-4 comment
  now names the follow re-check after its read). Proposed amendment of row f-4 below.

## Cycle 4: the cycle-3 verification findings

Every finding of the two cycle-3 lenses, with its disposition; the blocking ones first. Mutants were applied in place on
the committed tree, rebuilt in `.build-s3f`, run and reverted (`git status` clean after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | A space sweep during an owed follow answers a listed id's waiter with its replaced content's `insufficientSpace` figures (PROBE-C3-SPACE) | **Fixed** (failing test `996ac21`, fix `c8f01ca`; below) |
| reqs (blocking) | S1-15's run test (`EngineSync1LivenessTests.swift:175`) timed out under TSan beside a second TSan process (194.17 s at load ~33) | **Setup made cheaper, phases measured; still over half of 3 min paired: orchestrator ruling requested** (below) |
| reqs (blocking) | `probeChainTurns` over its 3-minute limit on a quiet host | **Fixed** (`7a81bc9`, `07ca8cb`): chains take 1.1 s instead of 6 to 95 s; all 20 `SyncBenchmarks` pass at load 3 (below) |
| reqs | The S3-R4 record contradicted: the alarm-turn test over half its limit at load ≤ 30; shutdown drain and bounded follow at the threshold | **Fixed** (`2211585`): re-measured beside a second TSan process at load 16–26; all three over 30 s, raised to `.minutes(3)` with their measurements, and seven more over half their limit raised the same way (table below) |
| reqs | Surviving mutant `noDispatchOwedFlag` (`EngineRuns.swift:947`, `\|\| self.state.pumpWaitsForFollow` in `dispatchOwed`) unrecorded | **Recorded** (no test; reason below) and proposed for §14 |
| reqs | PROBE-W1 (cycle 2) now hangs: a lane dispatches nothing while its head waits for an owed follow | No change (expected behaviour, already in the proposed §7.10 text) |
| reqs | other-wp:b: P-13 | **other-wp:b:** `BenchStorage.swift` is WP-B's; not touched |
| correct | Hang-guard margins of the alarm-turn and the cycle-12 seeded release/re-join tests under TSan | **Fixed** (`2211585`): both `.minutes(3)` with the verifiers' and this cycle's measurements; the seeded loop calls `Task.checkCancellation()` per operation |
| correct | Load benchmarks: `probeChainTurns` over its limit, the throttle extension 10.66 ms best, P-11 2.94 at load 11–23 | `probeChainTurns` fixed (above); re-run at load 3: throttle extension [7.15, 7.81, 6.75] ms, P-11 3.43, every benchmark passing |
| correct | The `noFlagPump` survivor (`continueFollow`'s two `\|\| pumpWaitsForFollow` terms) unpinned (optional test) | Kept as recorded in cycle 3 (§14 candidate (a)); no test this cycle |
| correct | other-wp:b: P-13 | **other-wp:b:** as above |
| (found here) | other-wp:b: a 404 has the store commit its whole index before the engine goes on | **other-wp:b:** reported below; no WP-F change needed (the benchmark no longer measures it) |

### The blocking correctness finding: a space sweep during an owed follow — **Fixed**

*Finding:* `sweepSpaceParked` (the alarm's `.reclaimed` sweep after reaped bytes, `.settle`, a purge's reclaim) could
re-park the `awaitingSpace` job of a listed id's replaced content `insufficientSpace` while the bounded follow still owed
its visit, and `park` → `failFast` answered that id's waiter or ensure member with the replaced content's figures,
although the copy lists the id at content that fits (F-22, T22, R-CAR-2); the cycle-3 hooks covered `resolveAll`,
`countFailedAttempt` and `spaceFailed`, not this park.

- **Failing test first** (`996ac21`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, `extension
  EngineSyncTests`): `R-SYN-11: a space sweep during an owed follow moves a listed id's interest to its new content before
  it answers or re-queues the replaced content's job (R-CAR-2)`, arguments `SweptReplacedContent.waiterReparked`,
  `.ensureReparked` (an `ensureAvailable` member; its fetch-first finds the manifest unchanged) and `.waiterRequeued`.
  PROBE-C3-SPACE's shape with the hold seam: 4 MB of a pruned blob wait for the reclaim, the target's 5 MB user job is
  parked `awaitingSpace` against 4 MB of room, a forced sync moves the target to 16 bytes while 2,100 changed entries
  sort before it (the pass stops before its entry), the test sets the room the reclaim adds to (0.5 MB: re-park; 2 MB:
  re-queue), and the deletion grace ends. At `996ac21`: `EngineFollowTests.swift:573:9: Expectation failed:
  answered.fromNewContent` with `failure(ZTronAssetModel.AssetError.insufficientSpace(required: 5000000, available:
  4500000))` for `.waiterReparked` and `.ensureReparked`, and `:569:9: Expectation failed: !afterSweep.holds` (`the
  replaced content's job no longer holds the id after the sweep: Optional(ZTronAssetSync.JobState.queued)`) for
  `.waiterRequeued`.
- **Fix** (`c8f01ca`, `EngineJobs.swift` `sweepSpaceParked`, doc of `followBeforeActing` in `EngineFollow.swift`): the
  sweep calls `followBeforeActing(transfer)` just before it re-queues a candidate and just before it parks one
  `insufficientSpace`. A superseded job is skipped and counted against the same per-turn bound as the action it preceded
  (`readmissionsPerTurn` re-queues, `parksPerPump` parks), so the sweep stays bounded per turn (C2); a job that keeps
  some ids is read again before its figures (the moved interests may have lowered its lane; this entry reasoned that a
  lower lane can only shrink the room its figures read, so the verdict holds, which is wrong: the two volume readings
  are not ordered, and cycle 7 re-judges the job after its follow, under "Cycle 7"). A job left waiting (`awaitingSpace` with a wake expected) acts on nothing
  and is not followed. The verifier's prototype put the hook at the loop's head, which follows every candidate including
  the waiting ones, unbounded per turn at 10,000 parked jobs; this placement follows only the jobs the turn acts on.
- **Mutants** (in place on `c8f01ca`, filter `spaceSweepFollowsTheReplacedContent`):
  - `noSweepParkHook` (`guard let parked = self.state.jobs[transfer] else {`): `EngineFollowTests.swift:573:9: Expectation
    failed: answered.fromNewContent` for `.ensureReparked` and `.waiterReparked`; `✘ Test run with 1 test in 1 suite
    failed after 1.111 seconds with 2 issues.`
  - `noSweepRequeueHook` (`if false, self.followBeforeActing(transfer) {`): `EngineFollowTests.swift:569:9: Expectation
    failed: !afterSweep.holds` for `.waiterRequeued`; `✘ Test run with 1 test in 1 suite failed after 1.083 seconds with
    1 issue.`
- **REENTRANCY:** no new `await` (the hook is synchronous). **C2:** at most one follow per action the turn already
  bounds; `spaceParking`, `spaceReadmission` and the follow benchmarks re-run below. *(Corrected in cycle 5: that bound
  was not C2's. A follow costs about ten times the re-queue or park it precedes, so one turn could follow
  `readmissionsPerTurn + parksPerPump` = 1,024 jobs, 9.3 to 13 ms at 10,000 members, and none of those benchmarks owes a
  follow. The sweep now follows at most `followsPerTurn` jobs per turn: "Cycle 5" below.)*
- The test's payloads are repeated bytes (`2211585`), not generated megabytes, which took seconds under TSan: 12.2 s in
  the bundle at load 4–9, 24.7 s beside a second TSan process at load 12–32 (of 60 s).

### S1-15's run test under TSan — **setup cheaper; ruling requested**

*Finding:* `runMaterialisesAPipelineAtATime` (`.minutes(3)`) exceeded its limit beside a second TSan process; make the
setup cheaper without cutting entries or assertions, measure the phases, re-measure alone and paired at load ≤ ~30, and
ask for a ruling if it cannot stay under half of 3 minutes.

- **Phases** (TSan, the test's own steps timed in a scratch copy, never committed; `sample` profiles of the process):
  at load 5–12 the 100,000 entries' catalog 0.4–0.5 s, their encoding 4.0–4.4 s (a first hand-built encoder; one
  `JSONEncoder` call took 2.7–8.3 s on its own), then 30.1–36.3 s from the forced sync to the applied copy (56.2 s at
  load 11–18), of which the engine's decode of the 21 MB manifest (`ManifestDecoder.decode`: `ManifestParser.survey`
  and `parse`, WP-A's model code, instrumented byte by byte) took about two thirds of the samples, the plan (`PlanBuilder`,
  mostly formatting 100,000 transfer ids) about an eighth and the store's apply and index commit (WP-B) most of the rest;
  the shutdown's store close (another index commit) 2.2–2.8 s; the materialisation itself under 5 ms.
- **Cheaper** (`c745edc`): the wire bytes are encoded in eight slices at once and joined
  (`EngineFixture.manifestDataInSlices`, byte for byte `manifestData`'s output, which the test checks on a 100-entry
  prefix): 1.0–1.3 s against 2.7–8.3 s for one `JSONEncoder` call (a hand-built encoder was no faster under TSan:
  2.9–6.4 s as strings, 10.1–14.6 s as bytes). Entries, operations and assertions are unchanged. A store seeded with the manifest and
  a 304 run was tried and dropped: it removes the fetch-and-decode operation from the test (G3), and the store's next
  open read nothing back (the run planned an empty manifest).
- **Measured after** (TSan, `.build-s3f-tsan`, whole bundle run directly): alone (only it) 32.5 s at load 3.2–3.7 and
  46.1 s at load 11–18; in the bundle 60.6 s (load 3.7–8.6), 68.3 s (load 16–19), 99.0 s (load 13–30); beside a second
  TSan process 101.8 s twice (load 12–32) and 104.3–104.7 s (load 16–26); at load 59–464 193.3 s (reported passed:
  the limit is enforced coarsely). Over half of `.minutes(3)` at a load at most about 30 in every paired run.
- **Requested ruling (S1-15 guard):** S3-R4 reserves `.minutes(5)` for model-based or exhaustive tests; this one is
  neither, and its time is the decode of a 100,000-entry manifest it needs (S1-15's catalog size), in another work
  package's parser, under TSan. Requested: `.minutes(5)` for this test (paired 101.8–104.7 s, 34–35 % of 5 minutes), or
  another ruling the orchestrator prefers (for example routing the parser's sanitizer cost to WP-A, `other-wp:a`, which is
  not a defect: release decodes the same manifest in well under a second). Until a ruling, the guard stays `.minutes(3)`
  and the test's doc comment records the measurements.

### `probeChainTurns` — **Fixed**

*Finding:* WP-F's benchmark exceeded its 3-minute limit at load 4–9; make the chain cheaper without reducing the 10,000
members, the three runs or the 1,000 warm-up, then show it passing at load ≤ ~10.

- **Cause, measured** (`sample` of the release benchmark mid-chain): with 404 exits each exit had the store record the
  failure and commit its whole index before the engine went on (`AssetStore.recordFailure` → `persistBookkeeping` →
  `requireCommitted(.ordered)` → `IndexCommitUnit.run` → `IndexCodec.encode`, ADR-032), about 5 ms at 10,000 records on
  the store's actor, so 10,000 exits took 50 s or more per chain whatever the engine did. With 400 exits, chains still took
  6 to 88 s at load 3–14, with the process's threads idle most of the time: each of the 10,000 probes is a handful of hops
  between the engine's owned tasks (`.medium` follow-ups), which queued behind the `.high` heartbeat's pulses on the
  actor. Cycle 2's reading of the wall time (the fake source's round trip and the bench's polling) was wrong.
- **Fix** (`7a81bc9`, `07ca8cb`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` only): the exits are 400s, which also
  end a probe without a verdict (`breakerOutcome`: `.neutral`) and re-admit exactly as a 404 does, and write nothing to
  the store; the bench's O(n) polls on the actor are preceded by O(1) waits on the engine's own notifications
  (`SyncBench.originQuiet`); the chain's engine runs its owned tasks at the heartbeat's priority
  (`SyncBench.raiseOwnedTaskPriority`, the `ownedTaskPriorityFloor` seam the engine tests' harness uses, F-17). The engine's
  turns are the same; the measured figure (the heartbeat's longest wait) does not depend on a task's priority. Members,
  runs and warm-up unchanged.
- **Measured:** alone at load 3.5–3.6: totals [1.12, 1.17, 1.13] s and [1.11, 1.12, 1.11] s, waits [0.22, 5.69, 0.93] and
  [0.19, 0.19, 0.18] ms, `✔ Test run with 1 test in 2 suites passed after 4.038 seconds` and `3.932 seconds`. Whole
  `SyncBenchmarks` at load 2.95–3.42: `✔ Test run with 20 tests in 2 suites passed after 90.579 seconds`, chain totals
  [1.13, 1.16, 1.14] s, waits [0.54, 1.21, 0.32] ms. (Before the priority change, with 400 exits: `failed after 190.589
  seconds` at load 3–4, totals [87.9, 71.6, 22.3] s.)
- **other-wp:b (new):** a burst of 404s rewrites the store's whole index once per failure (`recordFailure` commits
  `.ordered` per call): at 10,000 records about 5 ms of CPU and an index-sized write per 404, so 10,000 missing assets
  rewrite the index 10,000 times. Not on the engine's actor (no C2 breach); a write-amplification question for WP-B
  (coalescing the failures of one burst into one commit would keep ADR-032's durability).

### Hang guards (S3-R4) — **Fixed**

Measured under TSan in the whole Sync bundle (`.build-s3f-tsan`, run directly): alone at load 16–19 and beside a second
TSan process (two bundles at once) at load 16–26, at `c8f01ca` plus this cycle's test edits; each raised guard's doc
comment carries its numbers. Re-measured on the final tree (`07ca8cb`): alone at load 3.7–8.6, paired at load 12–32.

| Test | alone | paired (load 16–26) | final tree: alone / paired (load 12–32) | guard |
|---|---|---|---|---|
| `R-SYN-5: one alarm turn of the engine re-queues at most dueDeadlinesPerTurn …` (`EngineBoundaryTests.swift`) | 33.8 s | 54.7–55.1 s | 23.3 / 47.5–47.8 s | **3 min** |
| `R-SYN-3: seeded random releases and re-joins …` (`EngineRegressionCycle12Tests.swift`) | 40.5 s | 67.0–67.4 s | 28.4 / 58.1–58.4 s | **3 min** |
| `R-SYN-15: a shutdown over more waiters and jobs than one turn takes …` (`EngineShutdownDrainTests.swift`) | 24.2 s | 40.3–42.9 s | 18.1 / 35.2–37.6 s | **3 min** |
| `R-SYN-2: an apply that moves more jobs than one turn takes …` (`EngineFollowTests.swift`) | 26.7 s | 41.2–41.4 s | 17.5 / 36.1–36.2 s | **3 min** |
| `R-SYN-5: when a 429 extends the throttle under more user-initiated waiters …` (`EngineRegressionCycle16Tests.swift`) | 26.5 s | 41.2–41.7 s | — | **3 min** |
| `R-SYN-6: one failing asset among 100 …` (`EngineSyncTests.swift`) | 24.6 s | 35.7–37.5 s | — | **3 min** |
| `R-SYN-2: a 404 for a prefetch member's replaced content …` (`EngineFollowTests.swift`) | 24.3 s | 37.0–37.2 s | — | **3 min** |
| `R-SYN-3: never more than maxConcurrentTransfers …` (`EngineLaneTests.swift`) | 22.3 s | 33.1–33.4 s | — | **3 min** |
| `R-SYN-5: a chain of half-open probes … re-admits one parked job per probe exit …` (`EngineProbeChainTests.swift`) | 22.3 s | 33.0–33.2 s | — | **3 min** |
| `R-SYN-6: with the default tuning, a run does not download …` (`EngineRegressionCycle3Tests.swift`) | 20.7 s | 30.5–30.9 s | — | **3 min** |
| `R-STO-13: during legacy migration a bulk sync … install-rate limiter …` (`EngineLegacyMigrationTransferTests.swift`) | 21.1 s | 30.5–30.6 s | — | **3 min** |

The cycle-16 throttle test also timed out (60 s) in both processes of a paired run at load 59–464 (a load miss, as the
cycle-3 verifier's run 1), which with 41 s paired at load ≤ 30 is why it is in the table. Every other test with a 1-minute
guard stayed at or under 30 s paired at load 16–26 (the space-sweep test 29.2 s with its old payloads, 24.7 s now). The
S3F-2 guards hold: `randomOperations` 66.1–79.2 s of 5 min, the four 3-minute ones 47.8–57.4 s.

### The `noDispatchOwedFlag` survivor — **recorded, no test**

Removing `|| self.state.pumpWaitsForFollow` from `dispatchOwed` (`EngineRuns.swift:947`) passes the Sync bundle (the
cycle-3 requirements verifier: `✔ Test run with 408 tests in 53 suites passed after 57.786 seconds`). The term keeps
F-41's order (the re-admitted jobs probe before a pending run's manifest fetch) when the job the breaker re-admitted for
its probe waits at its queue's head for an owed follow. It only matters while a pending run exists, and
`reconsiderPendingRun` requires `state.run == nil`, while no run settles as long as a follow is owed: so the follow must
come from an apply that is not a run's (`ensureAvailable`'s fetch-first apply, or a catch-up), the breaker must have
tripped and a run been refused after that apply, and the cooldown must end, all inside one bounded follow (about 40 turns
at 10,000). The hold seam makes that orderable, but the test was not written in this cycle (its size: an `ensureAvailable`
apply, a 5xx trip, a refused run and a cooldown's end around a held follow). Proposed §14 entry below, next to
`noFlagPump`.

## Cycle 5: the cycle-4 verification findings

Every finding of the two cycle-4 lenses, with its disposition; the blocking ones first. The rulings file was re-read and
holds no ruling on the S1-15 run test's guard. Each mutant was applied in place on the committed tree, rebuilt in
`.build-s3f` (release: `.build-s3f-perf`), run and reverted (`git diff --stat Sources/` empty after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | C2 regression from `c8f01ca`: `sweepSpaceParked` counted each follow as one re-queue or one park, so one sweep turn followed up to `readmissionsPerTurn + parksPerPump` = 1,024 jobs (PROBE-C4-SWEEP2-C2: 9.3 to 13 ms at 10,000) | **Fixed** (failing test `04ae782`, fix `e18d5aa`, C2 benchmark `8cc5940`, test cheaper `72b2ab2`; below) |
| reqs (blocking) | S1-15's run test (`EngineSync1LivenessTests.swift:179`, `.minutes(3)`) at 129.9 / 130.1 s beside a second TSan process at load 10.5–25.9 (72 %); the ruling requested in cycle 4 not issued | **Open: awaits the orchestrator's ruling.** Guard unchanged (S3-R4 gives `.minutes(5)` only to model-based or exhaustive tests; this one is neither); re-measured (below); the request stands with the verifiers' and this cycle's figures. *Ruled after cycle 5 (S3-R10) and applied in cycle 6 (`daa2ba8`)* |
| correct | The same test at 108.76 s alone in the TSan bundle at load 26–35 (60 %); ruling pending | As above |
| reqs | `SyncBenchmarks` misses on a loaded host (P-4 ratio, P-11, network edges, throttle extension), all five passing on the verifier's rerun at load 11–14 | No change (load only); the whole `SyncBenchmarks` re-run under "Gate evidence (cycle 5)" |
| reqs | Survivor `noDispatchOwedFlag` confirmed (`EngineRuns.swift:947`) | Kept as recorded in cycle 4 (§14 candidate (c)); no test this cycle |
| correct | Survivors `noDispatchOwedFlag` and `noFlagPump` carried over | Kept as recorded (§14 candidates (a) and (c)); no test this cycle |
| reqs | other-wp:b: P-13 and the per-404 index commit | **other-wp:b:** `BenchStorage.swift` and `AssetStore.recordFailure` are WP-B's; not touched |
| correct | other-wp:b: the per-404 index commit and P-13 | **other-wp:b:** as above |

### The blocking correctness finding: a space sweep's follows per turn — **Fixed**

*Finding:* cycle 4's fix (`c8f01ca`) followed a job just before the sweep re-queued or parked it and counted that
follow as the re-queue (`readmissionsPerTurn`, 512) or the park (`parksPerPump`, 512) it preceded. A follow (supersede,
re-route each interest, create the new content's job) costs about 10 to 12 µs, a re-queue about 1 µs and a park about
2 µs, which is why a follow turn visits `followsPerTurn` = 256 jobs. One `.reclaimed` sweep turn (the alarm's after
reaped bytes, `EngineTimers.swift:177`; also `.settle` and a purge's reclaim) could follow 1,024 jobs: the verifier's
PROBE-C4-SWEEP2-C2 measured heartbeat waits of 10.18–10.83 ms (one handle) and 13.62–14.05 ms (two handles) at 10,000
members, against 6.2–7.3 ms with no follow owed.

- **Failing test first** (`04ae782`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, `extension
  EngineSyncTests`): `R-SYN-11: one space sweep turn during an owed follow follows at most followsPerTurn jobs and leaves
  the rest to its follow-up sweep (C2)` (`spaceSweepFollowsAtMostOneTurnOfJobs`). Prefetch members alternating 400 and
  3,000 bytes wait `awaitingSpace` for a pruned 2,000-byte blob with 200 bytes of room; a forced sync changes every
  member's content and the follow's follow-ups are held after its first turn's 256 visits; the space sweep's follow-ups
  are held too (`holdSpaceSweepFollowUps()`); the deletion grace ends and the alarm's `.reclaimed` sweep re-queues the
  400-byte members and parks the 3,000-byte ones. The test counts the jobs that still hold a moved id
  (`holdsMovedID`) before and after that one turn, and requires exactly `followsPerTurn` follows, of both sizes, a held
  follow-up, and, after the holds end, every member's interest on its new content's job, no invariant violation and no
  replaced content requested. At `04ae782` (1,000 members): `EngineFollowTests.swift:672:9: Expectation failed:
  followed.small + followed.large == SyncEngine.followsPerTurn` / `one sweep turn followed 744 jobs (372 re-queued, 372
  parked), at most followsPerTurn = 256`; `✘ Test run with 1 test in 1 suite failed after 0.374 seconds with 1 issue.`
- **Fix** (`e18d5aa`, `EngineJobs.swift`): `sweepSpaceParked` counts every candidate that holds a moved id against its
  own budget of `followsPerTurn` per turn (`followFits(_:follows:)`), beside the re-queue and park bounds; once it is
  spent, the sweep schedules its follow-up (`scheduleSpaceSweepFollowUp`) and stops, as the other two bounds do. The
  verifier's prototype (`proto-sweep-follow-budget.diff`) did the same inline. A job that holds no moved id is not
  counted; a job left waiting acts on nothing and is not followed. The doc comment's C2 sentence is corrected (cycle 4's
  "the follow counts against the same per-turn bound as the action it precedes"), and so is the cycle-4 entry above.
- **Cheaper** (`72b2ab2`): the test runs over 600 members (344 owed after the follow's first turn, still more than one
  sweep turn may follow): 1.7 s alone under TSan with 1,000 members, 28.6 s in the TSan bundle at load 13–17; with
  600: 12.6 s in the bundle at load 3.7–4.7 and 19.2 / 21.3 s beside a second TSan process at load 4–14 (of 60 s).
- **Mutants and the pre-fix tree** (S3-R3; in place on `72b2ab2`'s tree, filter `spaceSweepFollowsAtMostOneTurnOfJobs`):
  - pre-fix (`EngineJobs.swift` as at `04ae782`): `EngineFollowTests.swift:672:9: Expectation failed: followed.small +
    followed.large == SyncEngine.followsPerTurn` / `one sweep turn followed 344 jobs (172 re-queued, 172 parked), at most
    followsPerTurn = 256`, and `:674:9: Expectation failed: after.followUpHeld`; `✘ Test run with 1 test in 1 suite
    failed after 0.237 seconds with 2 issues.`
  - `noRequeueFollowBudget` (`guard requeues < Self.readmissionsPerTurn else {`): `:672:9` with `one sweep turn followed
    344 jobs (172 re-queued, 172 parked)`, and `:674:9`; `failed after 0.247 seconds with 2 issues.` (At 1,000 members:
    `one sweep turn followed 513 jobs (257 re-queued, 256 parked)`.)
  - `noParkFollowBudget` (`guard parks < Self.parksPerPump else {`): `:672:9` with `one sweep turn followed 344 jobs (172
    re-queued, 172 parked)`, and `:674:9`; `failed after 0.239 seconds with 2 issues.` (At 1,000 members: `one sweep turn
    followed 512 jobs (256 re-queued, 256 parked)`.)
  - With the fix: `✔ Test run with 1 test in 1 suite passed after 0.241 seconds.`
- **C2 benchmark** (`8cc5940`, `BenchSync.swift`, S3-R5): `R-SYN-11: a reclaim of space during an owed follow under a
  10,000-member prefetch group, re-queueing and parking its members, holds the engine's actor at most C2's 10 ms per
  turn` (`reclaimDuringFollowTurns`; helper `SyncBench.reclaimDuringFollowWait`), the verifier's VerifyC4CorrectBench2
  in the heartbeat form, with one handle and with two over the same ids; the bench waits on an O(1) condition
  (`reclaimSwept`: the alarm's store work over, its read after the reclaim adopted, no sweep owed) and checks afterwards
  that no member still waits for space. Release, load 4.6–7.4: one handle [5.60, 6.02, 5.42] ms, two handles [6.62,
  6.47, 6.55] ms, `✔ Test run with 1 test in 2 suites passed after 7.390 seconds`. With `EngineJobs.swift` as at
  `04ae782` (release, load 6.4–11.7): one handle [13.83, 12.08, 13.23] ms, two handles [15.12, 14.52, 14.25] ms,
  `BenchSync.swift:504:17: Expectation failed: (runs.min() ?? .infinity) <= Self.c2Budget` twice, `✘ Test run with 1
  test in 2 suites failed after 7.910 seconds with 2 issues.`
- **REENTRANCY:** no new `await` (the budget is synchronous); no ledger row.

### S1-15's run test under TSan — **open in cycle 5; Fixed in cycle 6 (ruling S3-R10)**

*Cycle 6:* the orchestrator ruled after this cycle (S3-R10, 2026-10-30) and cycle 6 applied the ruling (`daa2ba8`,
`.minutes(5)`, nothing cut): see "Cycle 6". The text below is cycle 5's record.

*Findings (both lenses):* the test (`.minutes(3)`) stays over half its limit under TSan; the requirements verifier
measured 129.863 s and 130.143 s beside a second TSan process at load 10.5–25.9 (72 %) and 61.949 s alone at load 24–49;
the correctness verifier 108.76 s in the bundle alone at load 26–35 (60 %). Cycle 3's time-out (194 s at load ~33) had
the paired shape.

- **No change to the guard.** S3-R4 allows `.minutes(3)` for a test over half of `.minutes(1)`, and `.minutes(5)` only
  for a model-based or exhaustive enumeration; this test is neither, and the rulings file holds no ruling for it. Its
  100,000 entries, the fetch-and-decode, the plan, the apply and its assertions stay (G3).
- **No cheaper step left in WP-F that reaches the bar.** Cycle 4's phases: the engine's decode of the 21 MB manifest
  (WP-A's `ManifestDecoder`, `ManifestParser.survey` and `parse`) about two thirds of the samples, WP-F's plan
  (`PlanBuilder`, mostly formatting 100,000 transfer ids) about an eighth, the store's apply and index commit (WP-B) most
  of the rest; the wire bytes are already encoded in slices (`c745edc`). Removing the whole plan phase would still
  leave the verifier's paired figure above 110 s, over the alternative bar of 90 s paired at load about 30.
- **Measured this cycle** (TSan, `.build-s3f-tsan` at `72b2ab2`): alone in the bundle 72.27 s at load 13–17 (with the
  1,000-member sweep test; the bundle `passed after 72.273 seconds`) and 47.50 s at load 3.7–4.7 (`passed after 47.507
  seconds`); beside a second TSan process (`.build-s3f/run-direct.sh`, two bundles at once) 79.19 s and 79.49 s at load
  4.1–13.9 (44 % of 3 minutes; both bundles `passed after 79.189` / `79.503 seconds`). So the test is under half of 3
  minutes paired at load up to about 14 and over it paired at load 10.5–25.9 (the verifier), which the alternative bar
  (paired, load about 30) does not accept.
- **Requested ruling (unchanged, with these figures):** `.minutes(5)` for this test only (130.1 s paired at load ≤ 26 is
  43 % of 5 minutes), recorded with the measurements above and cycle 4's, as the DECISIONS L4-R8 precedent line; or the
  parser's sanitizer cost routed to WP-A (`other-wp:a`; not a defect: release decodes the manifest in well under a
  second). Until a ruling, the guard stays `.minutes(3)` and the doc comment carries the measurements (`007a2bb`).

### Load-only benchmark misses, survivors, `other-wp:b`

- **`SyncBenchmarks` on a loaded host:** the verifier's four misses (P-4 ratio 3.89, P-11 1.01, network edges best 10.18
  ms, throttle extension [85.4, 41.2, 107.1] ms) came at load 24–226 and passed on its rerun at load 11–14; nothing
  changed. The whole suite is re-run under "Gate evidence (cycle 5)".
- **`noDispatchOwedFlag` and `noFlagPump`:** recorded as in cycles 3 and 4 (reasons there), §14 candidates (a) and (c);
  the ordered hold-seam test the cycle-4 entry sketches is not written.
- **other-wp:b:** P-13 (`BenchStorage.swift:249`) and `AssetStore.recordFailure`'s whole-index commit per 404 (a burst
  of N 404s rewrites the index N times, about 5 ms each at 10,000 records): routed to WP-B, with the suggestion to
  coalesce one burst's failure records into one ordered commit; P-13 to be re-run on a quiet host.

## Cycle 6: the cycle-5 verification findings

Every finding of the two cycle-5 lenses, with its disposition; the blocking ones first. The rulings file was re-read: it
now holds S3-R10 (2026-10-30) on the S1-15 run test's guard. Each mutant was applied in place on the committed tree,
rebuilt in `.build-s3f`, run and reverted (`git diff --stat Sources/` empty after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | R-SYN-11, F-22: in a `.reclaimed` or `.settle` sweep during an owed follow, `sweepSpaceParked`'s re-queue branch judged a job on its pre-follow lane; a follow that kept a prefetch id lowered the lane, the job was re-queued anyway and its bytes counted `ahead`, so the next user job was parked `insufficientSpace` and its fail-fast answered its waiter with a shortage that did not exist (PROBE-C5-LANEDROP) | **Fixed** (failing test `48c8dfc`, fix `b94fd27`, the sweep's park bound pinned `7c8d737`; below) |
| reqs (blocking) | S3-R10 issued but not applied: S1-15's run test still `.minutes(3)`, its doc comment and this draft still say the ruling is pending; 94.8 / 95.6 s paired at load 8.8–20.8 (53 % of 3 minutes) | **Fixed** (`daa2ba8`: the trait alone, `.minutes(5)`; doc comment, this draft, the Stage 5 note; below) |
| correct | The same guard, non-blocking under S3-R10 (71.47 s alone at load 17.7–30.6) | As above |
| reqs | `reclaimDuringFollowTurns` missed C2 in one run at load 8.4→16.1 right after load 540, and passed in every other run | No change (load only, S3-R5); re-run under "Gate evidence (cycle 6)" |
| reqs | `spaceSweepFollowsAtMostOneTurnOfJobs` at 27.4 / 27.8 s paired at load 8.8–20.8 (46 % of 60 s), about 20 other `.minutes(1)` Sync tests at 46–50 % in the same run | Recorded (cycle 5's DECISIONS line now carries the paired figure); no test over half its guard, so none raised (S3-R4); re-measured below |
| reqs | other-wp:b / other-wp:h: Storage time-outs (`StoreCrashTests.swift:167`, `LoopbackHTTPServerTests.swift:400`) at load 100–540 | **other-wp:b / other-wp:h:** not WP-F's files, not touched; the Storage target passed in the verifier's rerun at load 6–11 and in this cycle's `--quick` (load 12.8 → 178) and simulator runs ("Gate evidence (cycle 6)") |
| reqs, correct | Survivors `noDispatchOwedFlag` and `noFlagPump` carried over | Kept as recorded (§14 candidates (a) and (c)); no test this cycle |
| reqs, correct | other-wp:b: P-13 and the per-404 index commit | **other-wp:b:** `BenchStorage.swift` and `AssetStore.recordFailure` are WP-B's; not touched |

### The blocking correctness finding: a space sweep re-queued a job on its pre-follow lane — **Fixed**

*Finding (correctness lens, PROBE-C5-LANEDROP):* content C (5 MB) is listed by A, which has a user waiter, and by B, a
prefetch group's member, so its job is user-lane. During an owed follow the reclaim's sweep found C's job fits A's user
lane, followed it (`followBeforeActing`: A moves to its new content, B stays, the job drops to prefetch), and re-queued it
with its 5 MB counted `ahead`; the next user job K (3 MB) was then judged against 6 − 5 = 1 MB, parked
`insufficientSpace`, and its fail-fast answered K's waiter `insufficientSpace(required: 3000000, available: 999000)`
with 6 MB free, while the gate parked C's job and C never took the room. The cycle-4 entry reasoned that a lane drop only
shrinks the room, which is why the park branch re-reads the job; the re-queue branch did not, and there a drop turns
"fits" into "does not fit". (That premise is wrong in the other direction too: the opportunistic reading may exceed the
important one, so in the park branch a drop can turn "does not fit" into "fits"; fixed in cycle 7, under "Cycle 7".) At `s3-base` the follow moved every job in the apply's turn, so the window did not exist.

- **Failing test first** (`48c8dfc`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, `extension
  EngineSyncTests`): `R-SYN-11: a space sweep judges a job again on the lane its follow leaves before it re-queues it, so
  a lane the follow lowered takes no room from the next waiter (F-22)` (`spaceSweepJudgesAFollowedJobOnItsNewLane`,
  arguments `LaneDropVisit.followVisitedFirst` (the control: the follow visits C's job before the reclaim) and
  `.sweepFollowsFirst`), the verifier's probe with its setup asserted (the follow owed or not, the job's lane and ids,
  both jobs `awaitingSpace`), the follow-owed state after the sweep, C's job prefetch-lane and not queued, no invariant
  violation, K's waiter answered from its 3 MB, A's from its 16-byte content, C never started, and the sync complete. In
  the control the follow's turns are awaited without the clock driver (they are owned tasks), so the 60 s grace cannot
  end early. At `48c8dfc`: `EngineFollowTests.swift:845:9: Expectation failed: (try? kResult.get())?.byteSize ==
  Int64(kBytes.count)` / `K's waiter is answered from its 3 MB, with 6 MB of room for user work:
  failure(ZTronAssetModel.AssetError.insufficientSpace(required: 3000000, available: 999000))` with `visit →
  .sweepFollowsFirst`; the control passed; `✘ Test run with 1 test in 1 suite failed after 0.448 seconds with 1 issue.`
- **Fix** (`b94fd27`, `EngineJobs.swift`, `sweepSpaceParked`): after `followBeforeActing` returns `false` the sweep
  re-reads the job and judges it again (`spaceBlock(job, ahead: ahead)`) before it re-queues it or counts it in `ahead`;
  a job that no longer fits falls through to the code of a job that never did, so it stays parked when it was parked
  `insufficientSpace`, is left waiting (`awaitingSpace` with a wake expected), or is parked `insufficientSpace` with its
  figures (F-22's convention) against `parksPerPump`, scheduling the follow-up sweep when that bound is spent; it is never
  added to `ahead` or `spaceAdmitted`. Its follow is done and not counted again (`followFits` counts only a job that holds
  a moved id). The verifier's prototype (`proto-lanedrop.diff`) handled the drop inline and lacked the park bound; the
  fall-through shares the wait, the figures and the bound with the park branch instead. The doc comment of
  `sweepSpaceParked` is corrected. With the fix: `✔ Test "R-SYN-11: a space sweep judges a job again …" with 2 test cases
  passed after 0.610 seconds`; the Sync bundle `✔ Test run with 407 tests in 52 suites passed after 20.813 seconds`.
- **Mutants** (S3-R3 style, in place on `b94fd27`, rebuilt with `-warnings-as-errors`, reverted):
  - `noLaneRejudge` (`verdict = self.spaceBlock(job, ahead: ahead)` → `verdict = nil`, the pre-fix behaviour):
    `EngineFollowTests.swift:845:9: Expectation failed: (try? kResult.get())?.byteSize == Int64(kBytes.count)` / `failure(…
    insufficientSpace(required: 3000000, available: 999000))`; `✘ Test run with 1 test in 1 suite failed after 0.358
    seconds with 1 issue.` (Deleting the line instead fails the build: `variable 'verdict' was never mutated`.)
  - `noParkBound` (`guard parks < Self.parksPerPump, self.followFits(job, follows: &follows) else {` → `guard
    self.followFits(job, follows: &follows) else {`): the whole Sync bundle passed (`✔ Test run with 407 tests in 52
    suites passed after 12.075 seconds`); only the release benchmark measured that bound. So `7c8d737` adds
    `R-SYN-11: one space sweep turn parks at most parksPerPump jobs and leaves the rest to its follow-up sweep (C2)`
    (`EngineRegressionCycle8Tests.spaceSweepParksAtMostOneTurnOfJobs`: 576 members wait for 300 reaped bytes, the purge
    path's `.reclaimed` sweep runs with its follow-ups held, its one turn re-queues the first member and parks exactly
    `parksPerPump`; then every other member ends parked and no invariant breaks). Against `noParkBound`:
    `EngineRegressionCycle8Tests.swift:306:9: Expectation failed: turn.parked == SyncEngine.parksPerPump` / `one sweep
    turn parked 575 jobs, at most parksPerPump = 512`, and `:307:9` / `(parked: 575, waiting: 0, followUpHeld: false)`;
    `✘ Test run with 2 tests in 2 suites failed after 0.511 seconds with 2 issues.` With the bound: `passed after 0.130
    seconds`. The lane-drop park goes through that same guard line.
- **C2 (S3-R5):** the re-judgement adds one dictionary read and the ledger's O(1) `spaceBlock` per re-queued job (at
  most `readmissionsPerTurn` per turn); `reclaimDuringFollowTurns` re-run under "Gate evidence (cycle 6)".
- **REENTRANCY:** no new `await` (synchronous); no ledger row.

### S1-15's run test under TSan — **Fixed (ruling S3-R10)**

- **`daa2ba8`** (`EngineSync1LivenessTests.swift`): the trait alone becomes `.timeLimit(.minutes(5))`; outside the doc
  comment the diff is that one line (`git diff 39dadd4 daa2ba8 -- …EngineSync1LivenessTests.swift`), so the 100,000
  entries, every operation, every assertion and the cancellation checks stay (G3). The doc comment's last sentence (the
  guard awaiting a ruling) is replaced by S3-R10 and its figures: 101.8–130.1 s beside a second TSan process at load
  10–32 (34–43 % of 5 minutes), 47.5–72.3 s alone, and the cycle-5 verifiers' 94.8 / 95.6 s paired at load 8.8–20.8
  and 66.1 s alone at load 14–24 (71.5 s alone at 18–31); its earlier "so the guard is `.minutes(3)`" now reads "became".
- **Measured this cycle** (TSan, `.build-s3f-tsan` at `daa2ba8`): alone in the bundle (04:41:08–04:42:28, load
  10.9–23.5) `✔ Test "R-SYN-3: a 100,000-entry plan …" passed after 49.787 seconds` (17 % of 5 minutes); beside a second
  TSan process (`.build-s3f/run-direct.sh`, two bundles at once; 05:15:31–05:16:59, load 6.1–25.6) 84.583 s and 84.821 s
  (28 % of 5 minutes; both bundles `passed after 84.589` / `84.829 seconds`). An earlier paired run (04:42:51–04:45:47)
  is not a moderate-load measurement: two other close-outs' verifiers started their test bundles during it and the load
  rose from 7.9 to 54.7 (above 30 from 04:44:01, about 70 s into the run); there the test took 175.718 s and 175.840 s
  (59 % of 5 minutes), both bundles passed, no ThreadSanitizer report. By S3-R10's rule (half of 5 minutes at a load of
  about 30 or less) the guard holds: no measurement at a load of about 30 or less reaches half of 5 minutes (the highest
  is 130.1 s, the ruling's own figure, at load 10–32).
- **Stage 5 residual-risk note (S3-R10):** under ThreadSanitizer, WP-A's manifest parser (`ManifestDecoder`,
  `ManifestParser.survey` and `parse`) takes about two thirds of this test's 47–130 s decoding S1-15's 21 MB,
  100,000-entry manifest. It is not a defect: a release build decodes that manifest in well under a second, and no WP-A
  change is made. The risk carried to Stage 5 is the test's wall time on a loaded CI host: the guard is 5 minutes, and a
  paired TSan run at load above about 30 has not been measured.

### Hang-guard margins, load-only misses and `other-wp`

- **`spaceSweepFollowsAtMostOneTurnOfJobs` (`.minutes(1)`):** the cycle-5 verifier measured 27.371 and 27.816 s beside a
  second TSan process at load 8.8–20.8 (46 % of 60 s), and about 20 other `.minutes(1)` Sync tests at 46–50 % in that run
  (the highest `R-STO-1: a cancelled, paused or failed foreground …` at 29.809 s); none over half its limit, so S3-R4
  raises none. This cycle, paired at load 6.1–25.6: 23.710 s and 23.661 s (39 %); the
  new tests of this cycle 22.540 / 22.243 s (lane drop) and 20.981 / 20.627 s (park bound); the highest `.minutes(1)`
  Sync test was `R-SYN-4: the transfer is cancelled only after the last of 100 callers cancels` at 26.770 s (45 %), and no
  Sync test exceeded half its guard (both bundles `passed after 84.6 seconds`). In the earlier paired run at load 7.9 →
  54.7 (other verifiers' bundles started during it; not moderate) every one of these took 50–77 % of its guard
  (`spaceSweepFollowsAtMostOneTurnOfJobs` 39.3 s, the two new tests 34–38 s, the 100-caller cancel test 46.4 s); all
  passed. Recorded rule: if a paired run at a load of about 30 or less takes this test over
  30 s, its guard is raised to `.minutes(3)` under S3-R4 with the measurements.
- **`reclaimDuringFollowTurns`:** the verifier's single miss (one handle [12.04, 12.07, 12.53] ms, two [13.03, 21.00,
  20.57] ms) came at load 8.4→16.1 straight after a period at load 540; its other runs passed (5.47–7.55 ms). Load only
  (S3-R5); re-run below.
- **other-wp:b / other-wp:h:** the Storage time-outs at load 100–540 (`StoreCrashTests.swift:167`, `R-STO-5: a process
  kill followed by a power loss …`; `LoopbackHTTPServerTests.swift:400`) are WP-B's and WP-H's files: if they return at a
  moderate load, the orchestrator routes them to those work packages.
- **Survivors and `other-wp:b`:** `noDispatchOwedFlag` and `noFlagPump` stay §14 candidates (a) and (c); P-13 and
  `AssetStore.recordFailure`'s per-404 index commit stay routed to WP-B (not re-run).

## Cycle 7: the cycle-6 verification findings

Every finding of the two cycle-6 lenses, with its disposition; the blocking ones first. The rulings file was re-read:
unchanged since 03:00:55 (S3-R10 is the last ruling; none rules on the hang-guard margins, so S3-R4 applies as written).
Each mutant was applied in place on the committed tree, rebuilt in `.build-s3f` with `-warnings-as-errors`, run and
reverted (`git diff --stat Sources/` empty after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | R-SYN-11, F-22: `sweepSpaceParked`'s park branch judged a job on its pre-follow lane and parked it after `followBeforeActing` without judging it again; a follow that lowered a user-lane job to prefetch moved it onto the opportunistic reading, which may exceed the important one, so a job that now fits was parked `insufficientSpace` and its kept waiter answered `insufficientSpace(required: 5000000, available: 10000003)` (PROBE-C6-LANEGAIN) | **Fixed** (failing test `69e209e`, fix `22c7b89`; below) |
| reqs (blocking) | S3-R4 / S3-R10, S3F-2 S3-STAB-03: 31 one-minute Sync tests over 30 s in a paired TSan run at a 1-minute load of 16.7–34.5 (up to 38.4 s, 64 %), `spaceSweepFollowsAtMostOneTurnOfJobs` at 37.0 s, which meets cycle 6's own recorded rule | **Fixed** (re-measured paired at load 20–35: 93 one-minute guards raised to `.minutes(3)` (`1602a8b`) and three model walks from `.minutes(3)` to `.minutes(5)` (`7499908`), each with its figures; one 4-minute SPEC-scale guard over half awaits a ruling; nothing cut; below) |
| reqs | Test strength: a re-judged job that no longer fits is not pinned to be parked in the sweep's turn (mutants `skipNotFit` and `requeueNoAhead` survived the Sync bundle) | **Fixed** (`18921e4`: C's job read in the sweep's own turn; both mutants fail 6/6 and 3/3; below) |
| reqs | Records: "Authorised edits outside WP-F" omitted cycle 6's files | **Fixed** (cycles 6 and 7 added to that paragraph) |
| correct | Test strength: the `.read` sweep's lane drop and the kept waiter's F-22 figures on the park fall-through had no committed test | **Fixed** (`2b6cd11`: PROBE-C6-READDROP and PROBE-C6-PARKFIGURES committed as R-SYN-11 tests; both fail against `noLaneRejudge`; below) |
| reqs | `SyncBenchmarks` spread at load 13–19 (`shutdownTurns`, `refreshUnderGroupTurns`), clean at load 8–10 | No change (load only, S3-R5); re-run under "Gate evidence (cycle 7)" |
| correct | S1-15's run test under TSan: 190.9 s at load 21–446 (not moderate), 88.3 s at load 6.6–37.6 | Recorded in the Stage 5 note below; no change (S3-R10) |
| reqs, correct | Survivors `noDispatchOwedFlag` and `noFlagPump` carried over | Kept as recorded (§14 candidates (a) and (c)); no test this cycle |
| reqs, correct | other-wp:b / other-wp:h: P-13, `AssetStore.recordFailure`'s per-404 index commit, the Storage time-outs | **other-wp:b / other-wp:h:** not WP-F's files, not touched |

### The blocking correctness finding: a space sweep parked a job its follow had moved onto a volume with room — **Fixed**

*Finding (correctness lens, PROBE-C6-LANEGAIN):* content C (5 MB) is wanted by A (a user waiter) and B (a prefetch
waiter), so its job is user-lane; it waits `awaitingSpace` with no room for user work, 6 MB for prefetch work (the
opportunistic reading is 6 MB larger than the important one) and 4 MB pending reclaim. During an owed follow the
reclaim's `.reclaimed` sweep judged C on A's user lane (4 MB of room: does not fit), reached the park branch, followed
the job (A left, B stayed: prefetch, 10 MB of room) and parked it `insufficientSpace` anyway; its fail-fast answered B's
waiter `insufficientSpace(required: 5000000, available: 10000003)`, which breaks `headroom`'s documented invariant that
`required` exceeds `available` whenever a job is parked. The cycle-4 entry's premise that a lane drop "can only shrink
the room" is wrong: neither the store (`AssetStore+Reads.swift`) nor the ledger orders the two readings, and
`largestRoom` already takes their larger. The same failure occurs on the code before cycle 6 (`39dadd4`); at
`s3-base` the follow moved every job in the apply's turn, so the window did not exist. Whether a device reports an
opportunistic reading above the important one is not verified (below).

- **Failing test first** (`69e209e`, `EngineFollowTests.swift`, `extension EngineSyncTests`): `R-SYN-11: a space sweep
  judges a job again on the lane its follow leaves before it parks it, so a lane whose volume has room re-queues it
  (F-22)` (`spaceSweepRequeuesAFollowedJobItsNewLaneFits`, arguments `LaneDropVisit.followVisitedFirst` (control) and
  `.sweepFollowsFirst`): the verifier's probe with its setup asserted (the follow owed or not, the job's lane and ids,
  the job `awaitingSpace`; after the reclaim, C fits the opportunistic room and not the important one), the follow-owed
  state after the sweep, C's job not parked and prefetch-lane (or done), no invariant violation, B's waiter answered
  from C's 5 MB, A's from its 16-byte content, C's transfer started, and the sync complete. At `69e209e`:
  `EngineFollowTests.swift:972:9: Expectation failed: (try? bResult.get())?.byteSize == Int64(cBytes.count)` / `B's
  prefetch waiter is answered from C's 5 MB, with 10 MB of room for prefetch work:
  failure(ZTronAssetModel.AssetError.insufficientSpace(required: 5000000, available: 10000003))` and `:974:9:
  Expectation failed: await harness.source.starts.map(\.id).contains(a.transferID)`, both with `visit →
  .sweepFollowsFirst`; the control passed; `✘ Test run with 1 test in 1 suite failed after 0.387 seconds with 2
  issues.`
- **Fix** (`22c7b89`, `EngineJobs.swift`, `sweepSpaceParked`), the verifier's option (B): after the park branch's
  `followBeforeActing` the re-read job is judged again (`spaceBlock(parked, ahead: ahead)`); a job that fits is
  re-queued as an admitted one is (to `.queued`, enqueued, its bytes added to `ahead`, recorded in `spaceAdmitted`)
  within `readmissionsPerTurn`, and when that bound is spent the sweep schedules its follow-up and stops, leaving the
  followed job for the follow-up turn (which re-queues it without a second follow: it no longer holds a moved id). The
  re-queue code of both branches is one helper, `requeueSwept(_:ahead:)`. A job without a follow is the same job, which
  did not fit, so the re-judgement changes nothing for it. Option (A) (clamp the opportunistic reading to the important
  one) changes ADR-025/S2-23's use of the readings and needs a ruling; not taken. The doc comment of `sweepSpaceParked`
  and the park branch's comment now say the readings are not ordered and the job is judged again either way; the
  cycle-4 and cycle-6 entries above carry a correction note. With the fix: `✔ Test "R-SYN-11: a space sweep judges a
  job again on the lane its follow leaves before it parks it, …" with 2 test cases passed after 0.605 seconds`; the
  Sync bundle `✔ Test run with 409 tests in 52 suites passed after 11.119 seconds`.
- **Mutants:** removing the re-judgement is the code at `69e209e`, which fails the new test as quoted above. Removing
  the new branch's `readmissionsPerTurn` guard is not pinned by a test: that branch only runs for a job the turn
  follows, so it is already bounded by `followsPerTurn` (256) per turn, and the total re-queues of one turn stay under
  `readmissionsPerTurn + followsPerTurn` even without it (recorded under "Not verified here").
- **Not changed (no false answer, delay only; recorded):** `checkRunSettled`'s `admittedBySpace`, the `.read` sweep (it
  takes only `insufficientSpace` jobs, which never reach the park branch) and the waiting branch (a job left waiting is
  not followed) still read a job on its pre-follow lane until its follow visit; each can delay such a job until the
  next sweep or read, none answers a waiter.
- **C2 (S3-R5):** one more O(1) `spaceBlock` per parked job the sweep follows (at most `followsPerTurn` per turn).
- **REENTRANCY:** no new `await` (synchronous); no ledger row.

### Hang guards (S3-R4) — **Fixed**

*Finding (requirements lens):* in two TSan Sync bundles run at once at `daa2ba8` (1-minute load 16.65 → 34.48 in the
first wave, then up to 40), 31 tests with a one-minute guard took over 30 s (up to 38.4 s, 64 %), among them this
close-out's `EngineFollowTests` tests at `:609`, `:744`, `:346`, `:394`, `:230`, `:488`,
`EngineRegressionCycle8Tests.swift:261`, `EngineProbeChainTests.swift:116` and `EngineGiveUpInvariantTests.swift:15`;
`spaceSweepFollowsAtMostOneTurnOfJobs` at 37.0 s met cycle 6's recorded rule. No ruling answers it, so S3-R4 applies.

*Re-measured* (TSan bundle `.build-s3f-tsan` at `2b6cd11`, the cycle's code and tests before the guard commit, run
directly with `.build-s3f/run-direct.sh`, 1-minute load sampled every 5 s):

- **Paired, not moderate** (06:15:39–06:18:59, load 50.4–77.6, other close-outs' verifiers building and testing): both
  bundles failed on time limits alone, `✘ Test run with 411 tests in 52 suites failed after 196.462 seconds with 145
  issues.` / `197.278 seconds with 119 issues.`: 44 and 38 one-minute tests exceeded 60 s; every other issue belongs to a
  test that also exceeded its limit (the cancelled waits' expectations), and no ThreadSanitizer report. S3-R4 does not
  judge a run above load about 30; it is recorded as the host's limit (below, Stage 5 note).
- **Paired, moderate** (06:28:23–06:30:54, load 20.1 → 34.9, 31–35 for its second half): `✔ Test run with 411 tests in
  52 suites passed after 148.824 seconds.` / `148.896 seconds.`, no ThreadSanitizer report. 93 of the 335 one-minute
  Sync tests took over 30 s in at least one bundle (up to 55.1 s, 92 %), all 31 of the verifier's list among them; the
  other 242 took at most 29.97 s.
- **Alone** (06:31:23–06:32:24, load 12.9–18.4): `✔ Test run with 411 tests in 52 suites passed after 58.364 seconds.`,
  no report; the longest one-minute test 20.4 s (34 %).

*Fix* (`1602a8b`): each of the 93 tests' guard becomes `.timeLimit(.minutes(3))` (S3-R4) and its doc comment carries its
alone and paired figures and loads (and the cycle-6 verifier's paired figure where it measured one). The diff is the trait
and doc lines only (`git diff 2b6cd11 1602a8b -- Tests | grep '^[-+]'` shows nothing else): no operation, seed, crash
point or assertion is cut (G3). The long loops already check `Task.isCancelled` (S3F-2). The tests are not made cheaper:
alone they take 13–20 s at load 13–18, and the paired figures move with the whole bundle (every test of the first wave
took about a third of the bundle's 149 s), so the margin is the bundle's contention under TSan, not a step of any one
test.

| Test (display name, file) | alone (load 13–18) | paired (load 20–35) | cycle-6 verifier paired (load 17–34) | guard |
|---|---|---|---|---|
| `R-SYN-4: the transfer is cancelled only after the last of 100 calle …` (`EngineSingleFlightTests.swift`) | 20.3 s | 50.7–55.1 s (92 %) | 37.8–37.9 s | **3 min** |
| `R-SYN-3: lane queues stay within twice their live entries while que …` (`EngineSafetyTests.swift`) | 20.4 s | 50.3–51.3 s (86 %) | 38.3–38.4 s | **3 min** |
| `R-SYN-5: the breaker's parked order follows a parked job's rank as …` (`EngineProbeChainTests.swift`) | 20.0 s | 48.7–49.9 s (83 %) | 37.2–37.4 s | **3 min** |
| `R-SYN-7: a Low Data Mode flap reported as two conditions elements n …` (`EngineRegressionCycle10Tests.swift`) | 20.1 s | 48.8–49.8 s (83 %) | — | **3 min** |
| `R-SYN-2: no transfer of a replaced content starts after the apply w …` (`EngineFollowTests.swift`) | 19.9 s | 48.3–49.5 s (82 %) | 36.3–37.0 s | **3 min** |
| `R-SYN-11: one space sweep turn during an owed follow follows at mos …` (`EngineFollowTests.swift`) | 19.9 s | 48.5–49.0 s (82 %) | 37.0–37.0 s | **3 min** |
| `R-SYN-2: a queued user job of an id the apply dropped does not star …` (`EngineFollowTests.swift`) | 20.0 s | 48.5–49.0 s (82 %) | 36.6–36.7 s | **3 min** |
| `R-SYN-5: prefetch probes that each end without a verdict start no r …` (`EngineRegressionCycle21Tests.swift`) | 19.7 s | 47.5–48.9 s (82 %) | 34.4–36.4 s | **3 min** |
| `R-SYN-5: a run whose transfers open the 5xx breaker ends blocked an …` (`EngineRunPathTests.swift`) | 19.4 s | 46.5–48.1 s (80 %) | 35.8–35.8 s | **3 min** |
| `R-SYN-6: a run whose claim a lane-wide park left that a conditions …` (`EngineRegressionCycle17Tests.swift`) | 19.3 s | 46.0–47.2 s (79 %) | 35.2–35.2 s | **3 min** |
| `R-CAR-2: a failure of an id's replaced content before its follow vi …` (`EngineFollowTests.swift`) | 19.3 s | 46.2–47.2 s (79 %) | 35.1–35.2 s | **3 min** |
| `R-SYN-11: the kept prefetch waiter of a job a space sweep parks aft …` (`EngineFollowTests.swift`) | 19.3 s | 45.7–47.2 s (79 %) | — | **3 min** |
| `R-SYN-6: a run whose claim parked for space a follow-up free-space …` (`EngineRegressionCycle17Tests.swift`) | 19.2 s | 45.7–47.1 s (79 %) | 34.7–35.1 s | **3 min** |
| `R-STO-13: during legacy migration a page a user resolves is in the …` (`EngineLegacyMigrationTransferTests.swift`) | 19.2 s | 45.5–47.0 s (78 %) | 34.7–34.7 s | **3 min** |
| `R-SYN-6: a run whose failed-whenOnline claim a network-edge re-admi …` (`EngineRegressionCycle17Tests.swift`) | 19.2 s | 45.7–47.0 s (78 %) | 34.7–35.1 s | **3 min** |
| `R-SYN-6: a run whose claim parked for space the owed follow-up swee …` (`EngineRegressionCycle17Tests.swift`) | 19.2 s | 45.4–47.0 s (78 %) | 34.6–35.0 s | **3 min** |
| `R-SYN-4: 100 callers on one asset with seeded random cancellations …` (`EngineSingleFlightTests.swift`) | 20.1 s | 43.5–47.0 s (78 %) | — | **3 min** |
| `R-SYN-11: a space sweep judges a job again on the lane its follow l …` (`EngineFollowTests.swift`) | 19.2 s | 45.7–47.0 s (78 %) | 35.0–35.1 s | **3 min** |
| `R-SYN-11: a space sweep during an owed follow moves a listed id's i …` (`EngineFollowTests.swift`) | 18.7 s | 44.4–46.2 s (77 %) | 34.7–35.2 s | **3 min** |
| `R-SYN-12: transfer progress published to subscribers never exceeds …` (`EngineEventsTests.swift`) | 18.8 s | 42.4–45.6 s (76 %) | 33.0–33.1 s | **3 min** |
| `R-SYN-3: members of a released handle that regain an interest keep …` (`EngineRegressionCycle11Tests.swift`) | 18.8 s | 44.2–45.5 s (76 %) | — | **3 min** |
| `R-SYN-11: a space sweep judges a job again on the lane its follow l …` (`EngineFollowTests.swift`) | 18.7 s | 44.2–45.5 s (76 %) | 35.0–35.1 s | **3 min** |
| `R-SYN-5: prefetch members that wait for a slot and each end without …` (`EngineRegressionCycle22Tests.swift`) | 18.7 s | 44.6–45.4 s (76 %) | 33.6–33.8 s | **3 min** |
| `R-STO-1: a cancelled, paused or failed foreground transfer leaves n …` (`EngineLiveTransportTests.swift`) | 19.1 s | 43.8–44.9 s (75 %) | 36.9–37.0 s | **3 min** |
| `R-SYN-13: when the network returns under more members parked offlin …` (`EngineRegressionCycle9Tests.swift`) | 18.5 s | 43.7–44.9 s (75 %) | — | **3 min** |
| `R-CAR-4: a join's give-up of more than releasesPerTurn claims retir …` (`EngineGroupClaimTests.swift`) | 18.5 s | 43.6–44.6 s (74 %) | 32.9–33.0 s | **3 min** |
| `R-CAR-4: invariantViolations reports a registered group in releasin …` (`EngineGiveUpInvariantTests.swift`) | 18.5 s | 43.7–44.6 s (74 %) | 33.0–33.1 s | **3 min** |
| `R-STO-11: a later launch that resumes an interrupted legacy migrati …` (`EngineLegacyMigrationTransferTests.swift`) | 18.5 s | 43.1–44.5 s (74 %) | 33.4–33.8 s | **3 min** |
| `R-CAR-4: a lane-wide park during a handle's release parks every oth …` (`EngineRegressionCycle10Tests.swift`) | 18.5 s | 43.1–44.4 s (74 %) | — | **3 min** |
| `R-SYN-11: one space sweep turn parks at most parksPerPump jobs and …` (`EngineRegressionCycle8Tests.swift`) | 18.4 s | 41.7–43.1 s (72 %) | 32.2–32.8 s | **3 min** |
| `R-SYN-11: once the store reclaimed what jobs waited for, every one …` (`EngineRegressionCycle8Tests.swift`) | 18.5 s | 42.2–43.0 s (72 %) | — | **3 min** |
| `R-SYN-11: when the network returns under more queued members than o …` (`EngineRegressionCycle8Tests.swift`) | 18.2 s | 41.7–42.7 s (71 %) | — | **3 min** |
| `R-STO-11: when legacy migration ends while the run that took the la …` (`EngineLegacyMigrationTransferTests.swift`) | 18.0 s | 40.3–42.7 s (71 %) | 29.8–30.5 s | **3 min** |
| `R-SYN-3: lane queues stay within twice their live entries after a r …` (`EngineRegressionCycle11Tests.swift`) | 17.9 s | 42.1–42.2 s (70 %) | — | **3 min** |
| `R-CAR-4: a member of a released handle that another interest wants …` (`EngineRegressionCycle10Tests.swift`) | 17.5 s | 41.0–42.1 s (70 %) | — | **3 min** |
| `R-CAR-4: releasing a prefetch handle of more members than one turn …` (`EngineRegressionCycle9Tests.swift`) | 17.0 s | 39.1–42.0 s (70 %) | — | **3 min** |
| `R-SYN-14: after a sync quiesces the engine owns zero timers and zer …` (`EngineIdleTests.swift`) | 17.3 s | 38.9–41.7 s (69 %) | 30.1–30.5 s | **3 min** |
| `R-SYN-11: when the volume gains room for more members parked for sp …` (`EngineRegressionCycle9Tests.swift`) | 17.0 s | 40.1–41.4 s (69 %) | — | **3 min** |
| `R-SYN-5: a retry that falls due in the alarm turn of the cooldown's …` (`EngineRegressionCycle22Tests.swift`) | 16.9 s | 40.1–41.2 s (69 %) | 30.7–30.8 s | **3 min** |
| `R-STO-11: an id of the same content that joins a job during the job …` (`EngineLegacyMigrationTransferTests.swift`) | 17.6 s | 39.4–41.1 s (68 %) | 30.1–30.6 s | **3 min** |
| `R-STO-13: the prior-art files a bulk sync's jobs adopt during legac …` (`EngineLegacyMigrationTransferTests.swift`) | 19.0 s | 39.1–40.9 s (68 %) | 29.8–30.1 s | **3 min** |
| `R-SYN-3: members of a released handle that regain a user-initiated …` (`EngineRejoinLaneTests.swift`) | 17.1 s | 39.4–40.8 s (68 %) | — | **3 min** |
| `R-NET-8: an invalid resume yields resumeRejected and the engine's n …` (`EngineLiveTransportTests.swift`) | 17.6 s | 40.0–40.8 s (68 %) | 32.7–33.1 s | **3 min** |
| `R-STO-11: an id of the same content that joins a job during the ans …` (`EngineLegacyMigrationTransferTests.swift`) | 17.5 s | 40.1–40.8 s (68 %) | 30.7–31.9 s | **3 min** |
| `R-SYN-7: a lane-wide policy park that stops at its turn's bound rea …` (`EngineRegressionCycle10Tests.swift`) | 16.8 s | 39.0–39.4 s (66 %) | — | **3 min** |
| `R-SYN-5: a half-open probe that ends without a verdict lets the nex …` (`EngineRegressionCycle20Tests.swift`) | 17.1 s | 39.0–39.4 s (66 %) | — | **3 min** |
| `R-SYN-15: no store mutation or commit happens after close returns` (`EngineIdleTests.swift`) | 16.1 s | 38.9–39.1 s (65 %) | — | **3 min** |
| `R-SYN-5: a run started while the breaker is open ends blocked witho …` (`EngineOutcomeTests.swift`) | 16.6 s | 38.2–39.0 s (65 %) | — | **3 min** |
| `R-STO-13: the prior-art files legacy migration's own batches adopt …` (`EngineLegacyMigrationTransferTests.swift`) | 16.1 s | 36.3–38.8 s (65 %) | — | **3 min** |
| `R-CAR-4: releasing a user-initiated handle of more members than one …` (`EngineRegressionCycle9Tests.swift`) | 16.5 s | 37.1–38.7 s (65 %) | — | **3 min** |
| `R-STO-13: a prefetch job promoted to the user-initiated lane while …` (`EngineLegacyMigrationTransferTests.swift`) | 16.3 s | 36.9–38.6 s (64 %) | — | **3 min** |
| `R-SYN-11: a free-space read's sweep judges a followed job again on …` (`EngineFollowTests.swift`) | 16.1 s | 37.7–38.5 s (64 %) | — | **3 min** |
| `R-STO-13: an older answer of the store's deadline that the engine a …` (`EngineLegacyMigrationTransferTests.swift`) | 16.2 s | 36.4–37.7 s (63 %) | — | **3 min** |
| `R-STO-11: a prefetch group joined during legacy migration adopts th …` (`EngineLegacyMigrationTransferTests.swift`) | 16.1 s | 36.2–37.5 s (63 %) | — | **3 min** |
| `R-STO-13: ensureAvailable that joins a prefetch job while the job's …` (`EngineLegacyMigrationTransferTests.swift`) | 15.9 s | 35.8–37.1 s (62 %) | — | **3 min** |
| `R-SYN-12: two committed applies are followed in the store's order, …` (`EngineRegressionCycle5Tests.swift`) | 16.0 s | 36.0–36.7 s (61 %) | — | **3 min** |
| `R-SYN-7: bulk pauses on Low Data Mode and resumes when it is turned …` (`EngineConditionsTests.swift`) | 16.0 s | 35.9–36.7 s (61 %) | — | **3 min** |
| `R-SYN-6: a run whose claim parked for space the ledger admits alone …` (`EngineRegressionCycle18Tests.swift`) | 16.0 s | 35.9–36.6 s (61 %) | — | **3 min** |
| `R-STO-13: a job of two ids promoted while its read of the second id …` (`EngineLegacyMigrationTransferTests.swift`) | 15.8 s | 35.0–36.6 s (61 %) | — | **3 min** |
| `R-SYN-10: an ensureAvailable whose members fail fast as they become …` (`EngineRegressionRound2Tests.swift`) | 15.9 s | 35.2–36.0 s (60 %) | — | **3 min** |
| `R-SYN-5: a half-open probe superseded by an apply frees the probe slot` (`EngineRegressionRound2Tests.swift`) | 15.9 s | 35.6–35.9 s (60 %) | — | **3 min** |
| `R-SYN-6: a run whose last working claim ends after a half-open prob …` (`EngineRegressionCycle20Tests.swift`) | 15.9 s | 35.1–35.8 s (60 %) | — | **3 min** |
| `R-SYN-6: an offline run ends blocked and a new run starts when the …` (`EngineRunPathTests.swift`) | 15.9 s | 35.5–35.8 s (60 %) | — | **3 min** |
| `R-STO-11: a run that starts while the launch run waits for legacy m …` (`EngineLegacyMigrationTransferTests.swift`) | 15.5 s | 29.2–35.4 s (59 %) | — | **3 min** |
| `R-CLN-8: reportUnreadable announces, forgets and heals every asset …` (`EngineRegressionCycle3Tests.swift`) | 15.9 s | 33.8–35.2 s (59 %) | — | **3 min** |
| `R-STO-13: the prior-art files a migration batch adopted reach the r …` (`EngineLegacyMigrationTransferTests.swift`) | 15.5 s | 33.9–35.2 s (59 %) | — | **3 min** |
| `R-CAR-5: the retention scope bounds bulk runs and evicts excluded e …` (`EngineStoreTests.swift`) | 15.8 s | 32.3–35.0 s (58 %) | — | **3 min** |
| `R-STO-13: a job of two ids schedules the trailing install of its fi …` (`EngineLegacyMigrationTransferTests.swift`) | 15.2 s | 32.3–35.0 s (58 %) | — | **3 min** |
| `R-SYN-12: a prune an apply wrote before it threw is announced when …` (`EngineRegressionCycle4Tests.swift`) | 15.7 s | 33.5–34.5 s (57 %) | — | **3 min** |
| `R-SYN-10: ensureAvailable whose member waits for space fetches it a …` (`EngineRegressionCycle6Tests.swift`) | 15.5 s | 33.1–33.9 s (57 %) | — | **3 min** |
| `R-STO-11: ensureAvailable during legacy migration adopts the prior- …` (`EngineLegacyMigrationTransferTests.swift`) | 13.4 s | 32.4–33.3 s (55 %) | — | **3 min** |
| `R-STO-11: when a job's adoption of the last claimed prior-art file …` (`EngineLegacyMigrationTransferTests.swift`) | 13.8 s | 30.9–32.6 s (54 %) | — | **3 min** |
| `R-SYN-12: a subscriber stalled across two runs receives the second …` (`EngineEventOrderTests.swift`) | 14.0 s | 31.2–32.5 s (54 %) | — | **3 min** |
| `R-SYN-10: availability counts present, missing, stale and failed wi …` (`EngineStoreTests.swift`) | 13.9 s | 30.7–32.3 s (54 %) | — | **3 min** |
| `R-SYN-5: a transfer that probes after the cooldown publishes the ha …` (`EngineOutcomeTests.swift`) | 13.9 s | 30.9–32.2 s (54 %) | — | **3 min** |
| `R-STO-11: an explicit sync during legacy migration adopts every pri …` (`EngineLegacyMigrationTransferTests.swift`) | 13.9 s | 30.4–32.2 s (54 %) | — | **3 min** |
| `R-SYN-11: a job waiting for space keeps waiting after a reclaim tha …` (`EngineRegressionCycle8Tests.swift`) | 13.9 s | 30.8–32.1 s (53 %) | — | **3 min** |
| `R-SYN-16: maintenance finds a corrupted blob, announces its quarant …` (`EngineRecoveryTests.swift`) | 13.9 s | 30.5–32.0 s (53 %) | — | **3 min** |
| `R-SYN-5: a half-open probe whose publication fails the store's hash …` (`EngineRegressionRound2Tests.swift`) | 13.8 s | 30.1–31.8 s (53 %) | — | **3 min** |
| `R-SYN-15: no foreground staging write lands after the store is closed` (`EngineLiveTransportTests.swift`) | 14.0 s | 30.5–31.8 s (53 %) | 28.3–33.6 s | **3 min** |
| `R-STO-11: ensureAvailable's adoption of a prior-art file the held m …` (`EngineLegacyMigrationTransferTests.swift`) | 13.2 s | 29.9–31.6 s (53 %) | — | **3 min** |
| `R-SYN-11: ensureAvailable whose member waits for bytes a purge recl …` (`EngineRegressionCycle6Tests.swift`) | 13.8 s | 31.2–31.3 s (52 %) | — | **3 min** |
| `R-SYN-15: shutdown joins every owned task before it begins closing …` (`EngineSync1HalvesTests.swift`) | 13.2 s | 29.3–31.2 s (52 %) | — | **3 min** |
| `R-STO-11: a job whose last group is released while its pre-transfer …` (`EngineLegacyMigrationTransferTests.swift`) | 13.3 s | 29.7–31.2 s (52 %) | — | **3 min** |
| `R-OBS-3: the diagnostics keep the last 32 errors` (`EngineRunPathTests.swift`) | 13.9 s | 29.7–31.2 s (52 %) | — | **3 min** |
| `R-SYN-5: a pending run that waits for a half-open breaker starts on …` (`EngineRegressionCycle21Tests.swift`) | 13.6 s | 30.0–31.1 s (52 %) | — | **3 min** |
| `R-SYN-12: after a run's apply throws past its in-memory writes, the …` (`EngineRegressionCloseOutTests.swift`) | 13.3 s | 29.4–30.9 s (51 %) | — | **3 min** |
| `R-SYN-16: maintenance stops at its time budget on ManualTimeSource …` (`EngineStoreTests.swift`) | 13.2 s | 29.1–30.5 s (51 %) | — | **3 min** |
| `R-SYN-8: reconcile is committed before the first transfer starts` (`EngineSyncTests.swift`) | 13.1 s | 29.2–30.2 s (50 %) | — | **3 min** |
| `R-SYN-5: a run that starts while the half-open breaker admits only …` (`EngineRegressionCycle22Tests.swift`) | 13.2 s | 29.2–30.2 s (50 %) | — | **3 min** |
| `R-SYN-11: with eviction not permitted a run that does not fit evict …` (`EngineStoreTests.swift`) | 13.5 s | 29.1–30.2 s (50 %) | — | **3 min** |
| `R-STO-11: a user-initiated prefetch group's adoption of a prior-art …` (`EngineLegacyMigrationTransferTests.swift`) | 12.9 s | 28.6–30.2 s (50 %) | — | **3 min** |
| `R-SYN-13: runs that keep failing offline while the path reads satis …` (`EngineRegressionTests.swift`) | 12.9 s | 28.6–30.2 s (50 %) | — | **3 min** |

*Longer guards in the same moderate paired run* (S3-R4 judges every guard, not only the one-minute ones):

- **Raised to `.minutes(5)` (`7499908`)**, model-based walks over half of 3 minutes: `R-SYN-6: seeded walks over clock
  moves, held alarm turns, probe outcomes, 429s and space events …` (`EngineGateModelTests.gateModel`) 115.2–116.8 s
  (65 %), `R-SYN-6: the seeded gate walks with one slot reserved for user-initiated work …` (`gateModelWithReservedSlot`)
  115.5–116.7 s (65 %), and `R-SYN-3: seeded random releases and re-joins of overlapping handles …`
  (`EngineRegressionCycle12Tests.randomReleasesAndRejoins`, an invariant check after every seeded operation) 98.1–99.5 s
  (55 %); alone 45.2, 45.2 and 37.4 s at load 13–18; re-check pair 76.4–77.5, 76.4–77.2 and 65.0–65.5 s at load 6–27.
  Both walks already check `Task.isCancelled` per step (`EngineGateModelTests.swift:451`, `EngineRegressionCycle12Tests.swift:185`).
  Traits and doc comments only.
- **Ruling requested (not raised): `R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and
  subject during a 10,000-asset sync`** (`EngineEventsTests.stalledSubscriberIsBounded`, `.minutes(4)`, the L4-R8 precedent
  S3-R4 names): 132.0–132.4 s beside a second TSan process at load 20–35 (55 % of 4 minutes), 92.2–92.6 s at load 6–27
  (38 %), 51.5 s alone at load 13–18. It is neither model-based nor an exhaustive enumeration, so S3-R4 gives no step
  above it; its cost is the SPEC-scale 10,000-asset sync, as S1-15's was for S3-R10. Proposed: `.minutes(5)` under an
  S3-R10-style ruling, nothing cut. Until then it stays `.minutes(4)`.
- Every other 3-minute guard stayed at or under 87.9 s (49 %) in that run; S1-15's run test 148.8–148.9 s of its
  5 minutes (S3-R10; below).

*Re-check on the final tree* (`.build-s3f-tsan` rebuilt at `1602a8b` by the TSan gate run, two bundles at once,
06:42:53–06:44:41, load 5.9–27.0): `✔ Test run with 411 tests in 52 suites passed after 105.129 seconds.` / `105.671
seconds.`, no ThreadSanitizer report; the longest one-minute test 20.0 s (33 %), no one-minute test over 30 s; the
longest 3-minute test 77.5 s (43 %); `stalledSubscriberIsBounded` 92.6 s (39 % of 4 minutes); S1-15's run test 105.7 s
(35 % of 5 minutes).

### Test strength: the re-judged job's park in the sweep's own turn, and the two optional probes — **Fixed**

- **`18921e4`** (`spaceSweepJudgesAFollowedJobOnItsNewLane`): C's job is now also read in the first turn whose condition
  check sees K leave its wait (the reclaim's sweep turn; a condition is evaluated in every turn that notifies, the
  technique of `EngineGateModelTests.Recorder` and `EngineRegressionCycle22Tests.RunStartWatch`), through a
  Mutex-backed `SweepTurnWatch`, and must be `.blocked(.insufficientSpace)` there in both arguments. A read after the
  turn could not pin it: under `skipNotFit` the store's settle read (`settleUnwakeableSpaceWaits`, spawned in the
  alarm's turn) parks the job a turn later, which is why the verifier's probe failed only 4 of 10 times. The verifier's
  suggested `holdSpaceSweepFollowUps` would not have held that path (it is not a follow-up sweep). HEAD: 5 of 5 runs
  passed (`✔ Test run with 1 test in 1 suite passed after 0.538` … `0.434 seconds`). Mutants (in place, reverted):
  - `skipNotFit` (`if verdict != nil { continue }` after the re-judgement): 6 of 6 runs fail, `visit →
    .sweepFollowsFirst at EngineFollowTests.swift:871:9: Expectation failed: watch.state == .blocked(.insufficientSpace)`
    / `… not left awaitingSpace with nothing pending and no wake: Optional(ZTronAssetSync.JobState.blocked(
    ZTronAssetModel.BlockReason.awaitingSpace))`; `✘ Test run with 1 test in 1 suite failed after 0.445 seconds with 1
    issue.`
  - `requeueNoAhead` (re-queued without being counted ahead): 3 of 3 runs fail at the same line with
    `Optional(ZTronAssetSync.JobState.queued)`.
- **`2b6cd11`**: the correctness lens's two optional probes as R-SYN-11 tests in `EngineFollowTests.swift`, arguments
  `LaneDropVisit.allCases`: `R-SYN-11: a free-space read's sweep judges a followed job again on its new lane, so a lane
  the follow lowered takes no room from the next parked job` (`readSweepJudgesAFollowedJobOnItsNewLane`, PROBE-C6-READDROP:
  the `.read` sweep with group interests only) and `R-SYN-11: the kept prefetch waiter of a job a space sweep parks after
  its follow gets its own lane's figures (F-22)` (`spaceSweepParksAFollowedJobWithItsNewLanesFigures`,
  PROBE-C6-PARKFIGURES: B's waiter gets `insufficientSpace(required: 5000000, available: 0)`, K's and A's waiters their
  assets). HEAD: 3 of 3 runs pass (`✔ Test run with 2 tests in 1 suite passed after 1.031 seconds`). Against
  `noLaneRejudge` (`verdict = nil` after the follow, the behaviour before cycle 6): `visit → .sweepFollowsFirst at
  EngineFollowTests.swift:1114:9: Expectation failed: after.k != .blocked(.insufficientSpace)` / `K (3 MB, user lane)
  is re-queued for the 6 MB of room user work has: Optional(…blocked(…insufficientSpace))`, and `:1215:9: Expectation
  failed: (try? kResult.get())?.byteSize == Int64(kBytes.count)` / `failure(…insufficientSpace(required: 3000000,
  available: 999000))`; `✘ Test run with 2 tests in 1 suite failed after 1.994 seconds with 2 issues.`

### S1-15's run test, benchmarks, survivors and `other-wp`

- **S1-15's run test (S3-R10):** the correctness lens measured 190.914 s (64 % of 5 minutes) while another agent's
  simulator run drove the 1-minute load from 21 to 446 (above 30 for most of the test, so S3-R10 does not judge it), and
  88.302 s (29 %) at load 6.6–37.6; both bundles passed with no ThreadSanitizer report. Added to the Stage 5 note:
  S1-15's run test took 148.812 and 148.869 s beside a second TSan process at load 20–35 in this cycle (just under
  half of 5 minutes, 150 s; it is the bundle's longest test and ended last) and 58.358 s alone at load 13–18; the
  correctness lens's 190.9 s at load 21–446 and 88.3 s at load 6.6–37.6; a
  paired TSan run at load 50–78 timed out 44 and 38 one-minute Sync tests (time limits only, every other issue a
  consequence), so on this 8-core host the Sync bundle's one-minute guards hold under TSan beside a second TSan process
  only up to a load of about 35; a CI host should run the TSan Sync bundle alone or at a load at most about 30.
- **`SyncBenchmarks`:** the requirements lens's spread at load 13–19 (`shutdownTurns` [31.85, 8.19, 17.43] ms,
  `refreshUnderGroupTurns` [18.82, 9.12, 2.83] ms) was gone at load 8–10 ([1.35–1.49] and [1.21–2.03] ms): load only
  (S3-R5). Re-run under "Gate evidence (cycle 7)".
- **Survivors:** `noDispatchOwedFlag` and `noFlagPump` stay §14 candidates (a) and (c) (not re-run).
- **other-wp:b / other-wp:h:** P-13 (`BenchStorage.swift:249`), `AssetStore.recordFailure`'s per-404 index commit,
  `StoreCrashTests.swift:167` and `LoopbackHTTPServerTests.swift:400` are WP-B's and WP-H's; not touched.

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

- **Cycle 3:** the settle's release of the actor between slices is pinned by an actor-side observer (`6cd13e9`; see
  "Cycle 3").

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

- **Cycle 3: the bounded follow's regression** (the cycle-2 correctness lens, blocking): jobs of replaced content the
  follow had not visited yet answered moved ids with their failures and were dispatched between follow turns. Fixed
  with failing tests first; see "Cycle 3" above (`8b688ad`, `df5cfe3`, `48d9d59`, `2fb46be`, `c0c0563`, `776748a`).

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

- **Cycle 3:** three of these tests were strengthened after the cycle-2 requirements lens's surviving mutants: the
  uncommanded cancel (states, attempts and retry deadlines observed), the refused failed record (a second, unreadable
  reason) and maintenance's exit after orphan collection (a store over budget); `dc964d7`, `758c22f`; see "Cycle 3".

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

- **Cycle 3:** `closeStore()` marks and closes in one step, and the R-SYN-15 test reads the store while the shutdown joins
  (close-only M5 now fails it); `e58a34f`; see "Cycle 3".

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

None, in any cycle (cycle 4 changed `Sources/ZTronAssetSync/Engine/EngineJobs.swift`, `EngineFollow.swift`, tests under
`Tests/ZTronAssetSyncTests/Engine/`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` and this draft; cycle 5 changed
`Sources/ZTronAssetSync/Engine/EngineJobs.swift`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`,
`EngineSync1LivenessTests.swift` (a doc comment), `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` and this draft; cycle 6
changed `Sources/ZTronAssetSync/Engine/EngineJobs.swift`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`,
`EngineRegressionCycle8Tests.swift`, `EngineSync1LivenessTests.swift` and this draft; cycle 7 changed
`Sources/ZTronAssetSync/Engine/EngineJobs.swift`, test files under `Tests/ZTronAssetSyncTests/Engine/` (listed under
"Cycle 7") and this draft). Every changed file is WP-F's (ARCHITECTURE §1.2): `Sources/ZTronAssetSync/**`,
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
- **§12.3, §12.4 and §14:** one set of texts only, the cycle-2 items below (every §12.3/§12.4 regression test is
  written; S3-B-063 was done in Stage 3). Cycle 1's interim proposals for these sections are withdrawn (close-out
  cycle 3).
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

Cycle 3 adds:

- **§7.10, the follow (after cycle 2's sentence):** "While a follow is owed, a job holding an id the copy does not map
  to its content (listed elsewhere or dropped) is not dispatched: its queue's head stays in place, counts as no user
  work waiting for a slot (no preemption), and every follow turn pumps again (`pumpWaitsForFollow`). A job holding an id
  the copy lists at another transfer is followed before it answers its interests with a failure (`resolveAll`, an
  answer at the retry cap, the park after an ENOSPC), so the moved ids follow their new content (T22) and only the ids
  the copy still maps to it receive the failure (Stage 3, close-out cycle 3; F-20: never `.notFound` while the asset is
  listed)."
- **§7.10, shutdown (R-SYN-15), replacing cycle 2's sentence:** "Shutdown closes the store through `closeStore()`, which
  marks `closingStore` and closes in one step, after it joined every owned task; the engine-side test reads the mark and
  reads the store while the join waits (it must still be open)."
- **§10.2, row f-4 (proposed in WP-F's Stage 2 record), re-validation column:** add "and, after the free-space read, the
  follow: the ids an owed follow moved leave the job before its park answers them (`followBeforeActing`)".
- **§14:** (a) the liveness terms `|| pumpWaitsForFollow` of `continueFollow`'s pumps (a queue head the follow never
  visits; no join site produces one today; the invariant rule "a pump waits for a follow that nothing owes" reports a
  flag left set); (b) PROBE-W3: the breaker's parked-order rebuild at 9,994 parked jobs took 5.1–6.3 ms in one call,
  within C2 alone; a turn that combines it with a join batch or a pump's parks is not benchmarked.
- **DECISIONS / §11:** the R-SYN-2 and R-CAR-2 regression tests of this cycle (names under "Cycle 3"); no hang guard
  changed in cycle 3 (measurements under "Gate evidence (cycle 3)").

Cycle 4 adds:

- **§7.10, the follow (cycle 3's sentence):** replace "(`resolveAll`, an answer at the retry cap, the park after an
  ENOSPC)" with "(`resolveAll`, an answer at the retry cap, the park after an ENOSPC, and a space sweep's park or
  re-queue, each counted against that sweep's per-turn bound)".
- **§10.2:** no new row (no new `await`).
- **§11:** `R-SYN-5`'s probe-chain benchmark ends each probe with a 400 (a 404's store commit is not the re-admission's
  cost) and runs the engine's owned tasks at the heartbeat's priority; a 10,000-member chain takes about 1.1 s.
- **§14:** (c) the `|| pumpWaitsForFollow` term of `dispatchOwed` (F-41's order for a pending run behind a probe-only
  breaker while the probe candidate waits for an owed follow; reachable only through a follow of a non-run apply; the
  survivor `noDispatchOwedFlag`), next to (a).
- **For routing (`other-wp:b`, not a WP-F document change):** `AssetStore.recordFailure` commits the whole index once per
  call, so a burst of N 404s rewrites the index N times (about 5 ms each at 10,000 records in release).
- **DECISIONS (L4-R8 precedent):** the cycle-4 hang guards with their measurements (table under "Cycle 4"), and the
  orchestrator's ruling on the S1-15 run test's guard once given.

Cycle 5 adds:

- **§7.10, the follow (cycle 4's replacement text):** replace "and a space sweep's park or re-queue, each counted against
  that sweep's per-turn bound" with "and a space sweep's park or re-queue; a space sweep follows at most `followsPerTurn`
  (256) jobs per turn besides its `readmissionsPerTurn` re-queues and `parksPerPump` parks, and leaves the rest to its
  follow-up sweep (Stage 3 close-out cycle 5, PROBE-C4-SWEEP2-C2)".
- **§11:** `R-SYN-11`'s new C2 benchmark of a reclaim's space sweeps during an owed follow under a 10,000-member
  prefetch group, with one handle and with two (`reclaimDuringFollowTurns`); and the structural test
  `spaceSweepFollowsAtMostOneTurnOfJobs` (one sweep turn follows exactly `followsPerTurn` of 344 owed jobs).
- **§10.2:** no new row (no new `await`).
- **DECISIONS (L4-R8 precedent):** the S1-15 run test's guard, ruled after this cycle (S3-R10) and applied in cycle 6:
  see "Cycle 6 adds". The new cycle-5 test keeps `.minutes(1)` (19.2–21.3 s paired at load 4–14 here; 27.4–27.8 s
  paired at load 8.8–20.8 in the cycle-5 verification, 46 % of 60 s).
- **For routing (`other-wp:b`, unchanged from cycle 4):** `AssetStore.recordFailure`'s whole-index commit per 404, and
  P-13.

Cycle 6 adds:

- **§7.10, the follow (cycle 5's replacement text):** after "and leaves the rest to its follow-up sweep (Stage 3
  close-out cycle 5, PROBE-C4-SWEEP2-C2)" add "; a job a sweep follows before re-queuing it is judged again on the lane
  the follow left it, and one that no longer fits is treated as one that never did (left parked, left waiting, or parked
  within `parksPerPump`), never re-queued nor counted ahead of the jobs behind it (Stage 3 close-out cycle 6,
  PROBE-C5-LANEDROP)".
- **§11:** the R-SYN-11 regression test `spaceSweepJudgesAFollowedJobOnItsNewLane` (both visits) and the structural test
  `spaceSweepParksAtMostOneTurnOfJobs` (one sweep turn parks exactly `parksPerPump` of 575 jobs that do not fit).
- **§10.2:** no new row (no new `await`).
- **DECISIONS (L4-R8 precedent):** S1-15's run test guard (`EngineSync1LivenessTests.swift`,
  `runMaterialisesAPipelineAtATime`) is `.minutes(5)` by the orchestrator's ruling S3-R10: the SPEC-mandated scale
  (100,000 entries) decoded by WP-A's parser under TSan; 101.8–130.1 s beside a second TSan process at load 10–32 (34–43 %
  of 5 minutes), 47.5–72.3 s alone, and this cycle's figures under "Cycle 6"; nothing cut (G3).
- **Stage 5 residual risks:** WP-A's manifest parser under ThreadSanitizer costs about two thirds of S1-15's run test
  (47–130 s for the 21 MB, 100,000-entry manifest); not a defect (release decodes it in well under a second); no WP-A
  change; the guard is 5 minutes and a paired TSan run at load above about 30 is unmeasured.
- **For routing:** `other-wp:b` / `other-wp:h`, the Storage time-outs at load 100–540 (`StoreCrashTests.swift:167`,
  `LoopbackHTTPServerTests.swift:400`), only if they return at a moderate load; `other-wp:b` P-13 and the per-404 index
  commit, unchanged.

Cycle 7 adds:

- **§7.10, the follow (cycle 6's replacement text):** after "never re-queued nor counted ahead of the jobs behind it
  (Stage 3 close-out cycle 6, PROBE-C5-LANEDROP)" add "; and a job a sweep follows before parking it is judged again
  too, and one that fits on the lane the follow left it is re-queued within `readmissionsPerTurn`, never parked: the two
  volume readings are not ordered, so a lowered lane may read the larger room (Stage 3 close-out cycle 7,
  PROBE-C6-LANEGAIN)". **§7.6 / §7.10 (F-22):** wherever the text says or implies that a lane drop only shrinks a job's
  room, say instead that the important and opportunistic readings are unordered and a job's room is read on its current
  lane.
- **§11:** the R-SYN-11 regression tests `spaceSweepRequeuesAFollowedJobItsNewLaneFits`,
  `readSweepJudgesAFollowedJobOnItsNewLane` and `spaceSweepParksAFollowedJobWithItsNewLanesFigures` (both visits each),
  and the in-turn park check added to `spaceSweepJudgesAFollowedJobOnItsNewLane`.
- **§10.2:** no new row (no new `await`).
- **DECISIONS (L4-R8 precedent):** the cycle-7 hang guards: 93 one-minute Sync tests raised to `.minutes(3)` and three
  seeded model walks raised from `.minutes(3)` to `.minutes(5)`, each with its alone and paired TSan figures (table and
  list under "Cycle 7"); nothing cut (G3).
- **Ruling requested (S3-R10 style):** `EngineEventsTests.stalledSubscriberIsBounded` (`.minutes(4)`, a 10,000-asset
  sync) took 132.0–132.4 s beside a second TSan process at load 20–35 (55 % of 4 minutes); S3-R4 has no step above
  3 minutes for a test that is neither model-based nor exhaustive. Proposed: `.minutes(5)`, nothing cut.
- **Stage 5 residual risks:** S1-15's run test 148.8–148.9 s paired at load 20–35 (just under half of 5 minutes), 58.4 s
  alone; the correctness lens's 190.9 s at load 21–446 and 88.3 s at load 6.6–37.6. Under ThreadSanitizer the Sync
  bundle's guards hold beside a second TSan process only up to a load of about 35 on this 8-core host: at load 50–78 the
  paired bundles timed out 44 and 38 one-minute tests (time limits only). CI should run the TSan Sync bundle alone or at
  a load of at most about 30.
- **Not verified, for §14 or a device test:** whether a device reports an opportunistic free-space reading above the
  important one (the precondition of PROBE-C6-LANEGAIN); the store does not clamp them.

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

## Gate evidence (cycle 3)

All runs on this branch at `776748a` (the code's HEAD; the draft's commit changes this file only), scratch `.build-s3f*`,
on the shared 8-core host whose load swung from 4 to 360 during the cycle (loads quoted per step).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (19:08–19:12, load 5.4→10.9): `VERIFY: PASS`;
  Transport 151, Sync 404, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. (Also
  `VERIFY: PASS` at `758c22f`, 17:46–17:58, load ~100.)
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (19:14): `Build
  complete! (55,33 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug, 19:15–19:18, load 14–34): `✔ Test run with 404 tests in 52 suites passed after
  20.876 seconds`, `20.842 seconds`, `15.418 seconds`.
- **TSan once** (`.build-s3f-tsan`, 19:12–19:14, load 9.1→6.5): `✔ Test run with 404 tests in 52 suites passed after
  55.005 seconds`. Every test within its guard; this cycle's tests: the prefetch-member 404 test 15.3 s, the dropped-id
  user test 11.5 s, the W1 test 11.2 s, the parameterised waiter test 10.7 s (all three cases), the others under 9 s.
  **S3-R4 re-measurement** of the cycle-2 tests the verifiers flagged (60 s guards): the alarm turn 23.65 s (39 %), the
  shutdown drain 17.9 s, the bounded follow 17.1 s in this run; alone (18:12, load 141→75) 3.0 s, 2.0 s and 11.2 s; in a
  full TSan run at load 358→224 (18:07–18:11, `✔ … 403 tests … passed after 132.604 seconds`) 48.9 s, 35.6 s and 33.9 s,
  no time-out. At load at most about 30 each stays under half its limit, so by S3-R4 no guard changed; the 48.9 s at
  load 220–360 is recorded for the orchestrator's two-process re-measurement at the merge. A second TSan process beside
  this one was not run (the host's own load stood in for it).
- **Coverage** (`--enable-code-coverage`, all seven test targets passed, 19:18–19:21): `COVERAGE target=ZTronAssetSync
  lines= 94.01% (9242/9831) min=90.0 OK` (cycle 2: 94.04 %, 9187/9769), overall `96.67% (25751/26639)`, `COVERAGE: PASS`.
  Of this cycle's new Sync lines only two are unrun: the reset of `pumpWaitsForFollow` on the follow's unspawnable
  follow-up (shutting down; the branch was already unreached) and the new invariant rule's message.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (19:21). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.29_19-22-01-+0100.xcresult`, 19:22–19:27,
  load 6→105): `result Passed, totalTestCount 1358, passedTests 1358, failedTests 0, skippedTests 0` (`** TEST SUCCEEDED
  **`); the simulator is shut down.
- **WP-F benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter
  SyncBenchmarks`, 19:27–19:34, load 76→17): `✘ Test run with 20 tests in 2 suites failed after 226.391 seconds with 2
  issues`; 18 passed. P-4 13.03 ms (budget 20.0), ratio 2.08 (max 2.5); P-7 5.48 / 0.52 MiB; P-14 0 timers, 0 tasks; the
  stalled prune ratio 1.35. C2, runs in ms: refresh changing every member of a 10,000-member group [3.84, 3.87, 4.17]
  (the follow this cycle changed); refresh under a group [1.31, 1.38, 1.24]; shutdown [1.44, 1.55, 1.48]; due retries
  [0.91, 0.99, 0.99]; prune announcement [5.08, 4.93, 5.04]; releases 4.8–5.1; re-joins 5.1–5.5; space parking 4.3–5.0
  and 3.9–4.1; space re-admission 5.2–5.3; network edges 1.1–1.2 and 5.1–5.5; cooldown end 0.07–0.08; cancelled resolve
  0.02–0.03; throttle extension [12.42, 8.07, 8.20] (best 8.07, passing). The two issues, each compared head to head
  with `e91b9c7` (cycle 2's code, an archive built in `.build-s3f/perf-base`, run alternately on the same host):
  - P-11 speedup 2.98 (min 3.0) at load 76–150; alone right after (19:58–20:00, load 7.4→6.0): HEAD 3.18 and 3.20, base
    3.18 and 3.18, all passing. A load miss.
  - `probeChainTurns` exceeded its 3-minute limit (`BenchSync.swift:439:10: Time limit was exceeded: 180.000 seconds`):
    the chain's wall time, which is reported and not budgeted (a warm-up and three 10,000-member chains of about 60 s
    each on this host now; 40–48 s in cycle 2). HEAD alone first (19:34–19:37, load 11→29): totals [62.0, 86.9, 35.1] s,
    waits [63.60, 68.68, 115.11] ms (C2 and P-9 missed too). The base exceeds the limit the same way: base at load 26→6 totals [64.5, 63.6,
    59.1] s, waits [1.17, 72.77, 1.43] ms; HEAD right after at load 6→5 totals [64.2, 59.5, 61.3] s, waits [3.92, 11.16,
    4.21] ms; HEAD again at load 4.8→19 totals [62.4, 97.3, 24.8] s, waits [2.64, 37.42, 88.81] ms; the base again was
    stopped by the limit before it printed. The C2 waits are as noisy on both trees (one 72.8 ms run on the base, the
    verifier's 43 ms in cycle 2); best and median pass in the HEAD runs at load ≤ 6. A load and wall-time miss shared with
    the base, not a regression; the benchmark's own limit is the orchestrator's call at the merge (S3-R4 governs TSan
    test guards; this cycle did not change it).
- **Mutants of the fix** (in place on `776748a`, each rebuilt, run and reverted; filter
  `replacedContentFailure|noReplacedContentStarts|droppedUserJobWaitsForTheFollow`):
  - `noResolveAllHook`: `EngineFollowTests.swift:275:9: … argument failure → .notFound … Expectation failed: (try?
    answer.get()) != nil`, `:276:9`, `:323:9` (`after.pending == [replacement.transferID]`), `:324:9`.
  - `noCountHook`: `:275:9 … → .serverErrorAtCap`, `:276:9`.
  - `noSpaceHook`: `:275:9 … → .noSpace`, `:276:9`.
  - `noDispatchStall`: `:368:9: Expectation failed: startedBetween.isEmpty`, `:369:9`, `:376:9`, and `:433:9`
    (`!startedBetween.contains(dropped.transferID)`), `:434:9`, `:435:9`.
  - `listedOnlyAtDispatch`: `:433:9`, `:434:9`, `:435:9`, `:443:9`.
  - `owedVisitsOnly`: `:323:9`, `:324:9`.
  - `userHeadCounted`: `:435:9: Expectation failed: between.steady == .downloading`.
  - `noFlagPump` (both `|| pumpWaitsForFollow` terms removed): survives, recorded above (`✔ Test run with 403 tests in
    52 suites passed`, run at `758c22f`).
- **Mutants of the non-blocking items** (in place, each rebuilt, run and reverted): lines in the "Cycle 3" table; the
  M5, close-only M5 and M6 runs are on `e58a34f` (`closeStore()`).

## Gate evidence (cycle 4)

All runs on this branch at `07ca8cb` (the code's HEAD; the draft's commit changes this file only) unless a step names an
earlier commit, scratch `.build-s3f*`, on the shared 8-core host whose load swung from 3 to 464 during the cycle (loads
quoted per step).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (at `340a28b`, 22:59–23:03, load 17→7): `VERIFY:
  PASS`; Transport 151, Sync 405, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. (Also
  `VERIFY: PASS` at 22:10–22:15 on the tree before the guard and benchmark commits.)
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (22:09, sources as
  at `07ca8cb`): `Build complete! (27,92 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug, 22:30, load 36–51): `✔ Test run with 405 tests in 52 suites passed after 13.685
  seconds`, `14.199 seconds`, `13.518 seconds`.
- **TSan once** (`.build-s3f-tsan`, the whole bundle run directly, 22:47–22:48, load 3.7–8.6): `✔ Test run with 405
  tests in 52 suites passed after 60.633 seconds`; beside a second TSan process (22:48–22:50, load 12–32) both `✔ Test
  run with 405 tests in 52 suites passed after 101.795 seconds` / `101.806 seconds`, no time-limit line. Per-test
  durations in the tables under "Cycle 4".
- **Coverage** (`--enable-code-coverage`, all seven test targets passed, 22:31–22:34): `COVERAGE target=ZTronAssetSync
  lines= 94.03% (9254/9842) min=90.0 OK`, overall `96.68% (25765/26650)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (22:10, sources as at `07ca8cb`). **iOS Simulator tests**
  (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.29_22-50-34-+0100.xcresult`,
  22:50–22:57, load 27 at the start): `"result" : "Passed"`, `"totalTestCount" : 1359`, `"passedTests" : 1359`, `"failedTests" : 0`,
  `"skippedTests" : 0` (`** TEST SUCCEEDED **`); the simulator is shut down.
- **WP-F benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter
  SyncBenchmarks`, 22:44:57–22:46:27, load 2.95–3.42): `✔ Test run with 20 tests in 2 suites passed after 90.579
  seconds`. P-4 12.04 ms (budget 20.0), ratio 2.24 (max 2.5); P-7 4.89 / 0.31 MiB; P-11 speedup 3.43 (min 3.0); P-14 0
  timers, 0 tasks; the stalled prune ratio 1.43. C2, runs in ms: probe chain [0.54, 1.21, 0.32] (totals [1.13, 1.16,
  1.14] s); throttle extension [7.15, 7.81, 6.75]; refresh changing every member [3.67, 3.71, 3.65]; refresh under a
  group [1.23, 1.20, 1.21]; shutdown [1.36, 1.43, 1.39]; due retries [0.84, 0.85, 0.83]; prune announcement [5.00, 4.90,
  4.91]; releases 4.15–4.58 and 4.33–4.48; re-joins 4.57–4.72; space parking 4.02–4.51 and 2.72–3.13; space re-admission
  3.90–4.28; network edges 1.04–1.10 and 4.14–4.33; cooldown end 0.06–0.12; cancelled resolve 0.02. (At `2211585`,
  with the 400 exits but before the priority change, the same run at load 3–4 failed only in `probeChainTurns`: `BenchSync.swift:443:10: Time
  limit was exceeded: 180.000 seconds`, totals [87.9, 71.6, 22.3] s.)

## Gate evidence (cycle 5)

All runs on this branch at `72b2ab2` (the code's HEAD; the draft's commit changes this file only) unless a step names an
earlier commit, scratch `.build-s3f*`, on the shared 8-core host whose load swung from 3.7 to 94 during the cycle (loads
quoted per step, 1-minute averages).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (01:12–01:17, load 13.6→9.5): `VERIFY: PASS`;
  Transport 151, Sync 406, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. (Also `VERIFY:
  PASS` at `007a2bb`, 00:44–00:48.)
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (at `007a2bb`, whose
  sources are `72b2ab2`'s): `Build complete! (30,22 s)`, exit 0.
- **Gates** (sources as at `72b2ab2`): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public
  declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug, 01:17–01:18, load 9.5–14): `✔ Test run with 406 tests in 52 suites passed after
  12.605 seconds`, `11.676 seconds`, `11.426 seconds`. (At `007a2bb`, load 10–19: `11.617`, `11.548`, `11.509 seconds`.)
- **TSan once** (`swift test --skip-build --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, 00:55–00:57, load 3.7–4.7): `✔ Test run with 406 tests in 52 suites passed after 47.507
  seconds`; no ThreadSanitizer report, no time-limit line. Beside a second TSan process (`.build-s3f/run-direct.sh`,
  00:57–00:58, load 4.1–13.9): `✔ Test run with 406 tests in 52 suites passed after 79.189 seconds` / `79.503 seconds`.
  (At `007a2bb`, alone, load 13–17: `passed after 72.273 seconds`.) Per-test figures under "Cycle 5".
- **Coverage** (`--enable-code-coverage`, all seven test targets passed, 00:58–01:02): `COVERAGE target=ZTronAssetSync
  lines= 94.08% (9270/9853) min=90.0 OK`, overall `96.68% (25775/26661)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (01:02). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.30_01-02-31-+0100.xcresult`, 01:02–01:08,
  load 8 at the start, 82 at the end): `"result" : "Passed"`, `"totalTestCount" : 1360`, `"passedTests" : 1360`,
  `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED **`); the simulator is shut down.
- **WP-F benchmarks** (`swift test -c release --skip-build --scratch-path .build-s3f-perf --filter SyncBenchmarks` after
  `swift build -c release --build-tests --scratch-path .build-s3f-perf -Xswiftc -enable-testing`, 01:09:48–01:11:20, load
  13.4–18.5): `✘ Test run with 21 tests in 2 suites failed after 89.494 seconds with 1 issue`: 20 of 21 pass, the one
  miss is the throttle extension, best 13.15 ms ([13.15, 16.20, 13.60]), `BenchSync.swift:478:13`, a benchmark this cycle
  did not touch (no follow is owed and no job is parked for space in it, so the sweep's budget never runs). Re-run alone
  twice right after: load 13.6–17.7 [23.65, 16.20, 12.31] ms (miss), load 17.7–14.4 [13.51, 9.51, 6.51] ms, `✔ Test run
  with 1 test in 2 suites passed after 22.557 seconds`; cycle 4 measured [7.15, 7.81, 6.75] at load 3 and the cycle-4
  verifier a pass at load 11–14, so the miss is load only (S3-R5). The other figures: P-4 11.78 ms (budget 20.0), ratio
  2.03 (max 2.5); P-7 3.88 / 1.52 MiB; P-11 speedup 3.26 (min 3.0); P-14 0 timers, 0 tasks; the stalled prune ratio
  1.44. C2, runs in ms: the new reclaim during an owed follow [6.55, 6.33, 6.43] (one handle) and [7.06, 8.21, 7.30]
  (two handles); probe chain [1.45, 12.04, 9.14] (totals [1.85, 1.93, 1.93] s); refresh changing every member [4.02,
  3.77, 3.76]; refresh under a group [1.26, 1.25, 1.25]; shutdown [1.40, 6.07, 2.74]; due retries [0.84, 0.92, 0.92];
  prune announcement [4.98, 4.89, 4.90]; releases 4.75–5.26 and 4.39–5.27; re-joins 8.21–17.27 and 8.42–13.80; space
  parking 4.10–9.56 and 4.05–5.20; space re-admission 5.41–8.68; network edges 1.12–1.26 and 4.83–6.05; cooldown end
  0.00–0.28; cancelled resolve 0.00–0.14. The new benchmark alone at load 4.6–7.4: [5.60, 6.02, 5.42] and [6.62, 6.47,
  6.55] ms.

## Gate evidence (cycle 6)

All runs on this branch at `daa2ba8` (the code's HEAD; the draft's commit changes this file only), scratch
`.build-s3f*`, on the shared 8-core host, where other close-outs' verifiers drove the load from 6 to 571 during the cycle
(loads quoted per step, 1-minute averages).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (04:33:17–04:37:52, load 12.8 → 178): `VERIFY: PASS`;
  `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 408, Storage 459 (`passed after 73.124 seconds`), Model
  84, Kit 85, Compatibility 71, AppleHosted 104 tests passed.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (04:38–04:39, load
  143 → 94): `Build complete! (46,91 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  04:40–04:41, load 87 → 27): `✔ Test run with 408 tests in 52 suites passed after 15.033 seconds`, `12.214 seconds`,
  `11.380 seconds`.
- **TSan once** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, 04:41:08–04:42:28, load 10.9–23.5): `✔ Test run with 408 tests in 52 suites passed after
  49.793 seconds`; no `WARNING: ThreadSanitizer` line, no time-limit line. Beside a second TSan process
  (`.build-s3f/run-direct.sh`, 05:15:31–05:16:59, load 6.1–25.6): `passed after 84.589 seconds` / `84.829 seconds`,
  no report; the earlier paired run at load 7.9 → 54.7: `passed after 175.722 seconds` / `175.847 seconds`, no report.
  Per-test figures under "Cycle 6".
- **Coverage:** the `--quick` run above is `swift test --scratch-path .build-s3f --enable-code-coverage --skip
  Benchmarks` (every target passed); exported with `xcrun llvm-cov export -summary-only -instr-profile
  .build-s3f/out/Products/Debug/codecov/default.profdata` over the eight test binaries: `COVERAGE target=ZTronAssetSync
  lines= 93.96% (9271/9867) min=90.0 OK`, overall `96.65% (25782/26675)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (04:46). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.30_04-46-59-+0100.xcresult`,
  04:46:52–04:53:33, load 46 → 571): `"result" : "Passed"`, `"totalTestCount" : 1362`, `"passedTests" : 1362`,
  `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED **`); the simulator is shut down.
- **WP-F benchmarks** (`swift test -c release --skip-build --scratch-path .build-s3f-perf --filter SyncBenchmarks` after
  `swift build -c release --build-tests --scratch-path .build-s3f-perf -Xswiftc -enable-testing`, 05:14:21–05:15:21, load
  7.4–11.8): `✔ Test run with 21 tests in 2 suites passed after 56.821 seconds`, every one within its budget. The reclaim
  during an owed follow [6.54, 6.61, 6.38] ms (one handle) and [7.26, 6.97, 6.76] ms (two handles); P-4 11.61 ms
  (budget 20.0), ratio 2.02 (max 2.5); P-7 3.97 / 1.53 MiB; P-11 speedup 3.25 (min 3.0); P-14 0 timers, 0 tasks; the
  stalled prune ratio 1.44; space parking [4.13, 4.39, 4.33] ms; space re-admission [4.64, 4.76, 4.76] ms; network edges
  1.13–1.15 and 4.47–4.56 ms; releases 4.88–5.14 and 4.90–5.22 ms; re-joins 5.09–5.49 and 5.06–5.67 ms; shutdown [1.54,
  1.44, 2.39] ms; refresh under a group 1.25–1.29 ms, changing every member 3.74–3.82 ms; prune announcement 5.07–5.08 ms;
  due retries 0.93–0.95 ms; cancelled resolve 0.02–0.05 ms; cooldown end 0.04–0.07 ms; probe chain longest wait 0.25 ms
  (totals 1.12–1.16 s); throttle extension [6.62, 6.91, 7.43] ms.

## Gate evidence (cycle 7)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host, where other close-outs' verifiers drove the
1-minute load from 5 to 510 during the cycle (loads quoted per step). The code (`Sources/`) is unchanged since `22c7b89`;
`1602a8b` and `7499908` change test traits and doc comments only. The final-tree runs are at `7499908` (the draft's
commit changes this file only).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** at `7499908` (06:58:04–07:01:28, load 5.5 → 8.0):
  `VERIFY: PASS`; `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 411 (`passed after 13.534 seconds`),
  Storage 459 (`70.308 seconds`), Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. An earlier `--quick`
  at `1602a8b` (06:34:36–06:38:42, load 5.3 → 14.2) also ended `VERIFY: PASS`.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` at `1602a8b` (same
  `Sources/` as the final tree; 06:39, load 10.6): `Build complete! (27,36 s)`, exit 0.
- **Gates** (06:39, same `Sources/`): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** at `7499908` (`swift test --scratch-path .build-s3f --skip Benchmarks --filter
  ZTronAssetSyncTests`, 07:01:35–07:04:17, load 7.4 → 37): `✔ Test run with 411 tests in 52 suites passed after 23.056
  seconds.`, `29.993 seconds.`, `29.605 seconds.` (at `1602a8b`, load 7.7–12.2: `11.453`, `11.395`, `11.439 seconds`).
- **TSan once** at `7499908` (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, 07:04:17–07:06:55, load 153–210, another close-out's run): `✔ Test run with 411 tests in 52
  suites passed after 110.010 seconds.`; no `WARNING: ThreadSanitizer` line, no time-limit line. At `1602a8b`
  (06:41:03–06:42:45, load 6.6–10.4): `passed after 51.782 seconds`, no report, no time-limit line. Paired runs and
  per-test figures under "Cycle 7".
- **Coverage:** the final `--quick` run above runs the tests with `--enable-code-coverage`; exported with `xcrun llvm-cov
  export -summary-only -instr-profile .build-s3f/out/Products/Debug/codecov/default.profdata` over the seven
  non-benchmark test binaries: `COVERAGE target=ZTronAssetSync lines= 93.96% (9290/9887) min=90.0 OK`, overall `96.64%
  (25798/26695)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` at `7499908`, exit 0 (06:47). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.30_06-47-43-+0100.xcresult`,
  06:47:39–06:53:39, load 148 → 510 with another close-out's simulator run): `"result" : "Passed"`, `"totalTestCount" :
  1365`, `"passedTests" : 1365`, `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED **`); the simulator is
  shut down.
- **WP-F benchmarks** (`swift test -c release --skip-build --scratch-path .build-s3f-perf --filter SyncBenchmarks` after
  `swift build -c release --build-tests --scratch-path .build-s3f-perf -Xswiftc -enable-testing` at `7499908`,
  06:56:35–06:57:47, load 6.5–12.8): `✔ Test run with 21 tests in 2 suites passed after 69.195 seconds.`, every one
  within its budget. The reclaim during an owed follow [5.86, 6.19, 7.17] ms (one handle) and [6.63, 8.06, 10.96] ms
  (two handles; best 6.63 of the 10 ms budget); P-4 11.92 ms (budget 20.0), ratio 2.03 (max 2.5); P-7 5.14 / 0.69 MiB;
  P-11 speedup 3.21 (min 3.0); P-14 0 timers, 0 tasks; the stalled prune ratio 1.35; space parking [4.07, 4.29, 4.12] ms;
  space re-admission [4.61, 4.74, 5.18] ms; network edges 1.09–1.17 and 4.56 ms; releases 4.47–4.98 and 4.45–5.26 ms;
  re-joins 4.75–5.33 and 4.72–5.39 ms; shutdown [1.57, 1.46, 1.35] ms; refresh under a group 1.22–1.28 ms, changing
  every member 3.80–3.91 ms; prune announcement 5.00–5.12 ms; due retries 0.89–0.95 ms; cancelled resolve 0.02 ms;
  cooldown end 0.07–0.10 ms; probe chain longest wait 0.23 ms (totals about 1.1 s); throttle extension [6.59, 6.22,
  7.25] ms.
- **`git status`:** clean after the draft's commit; `docs/TRACEABILITY.md` untouched (no `--gates-only` or `--full`
  run).

## Not verified here

- Device-only behaviour (NWPathMonitor's first callback timing behind S3-CONC-04, background URLSession, real packs,
  thermal and Low Power Mode).
- The ~35 ms prune announcement at `maxEntries` (outside C2's reference scale).
- Cycle 1 left S3F-10, S3F-13 and part of S3F-14 open; cycle 2 closed them (above). Still not reached by any test: the
  S3F-10 regions recorded above as §14 candidates, `other-wp:b` or `other-wp:g`.
- The level-4 verifier's mutants M5 and M6 are not on file: they are reconstructed from `f.md` F-20's description (close
  before the join; no join).
- Cycle 3: a catch-up waiter (joined from the store's newer manifest) whose job fails while a follow is owed is not
  followed (its id is unlisted, `holdsMovedID`); no test orders that case, and the `pumpWaitsForFollow` liveness terms
  survive their mutant (both recorded under "Cycle 3"). Cycle 4 ran the two-TSan-process re-measurement (tables under
  "Cycle 4").
- The probe chain's total wall time at 10,000 is reported, not budgeted; its scaling is pinned by the structural count of
  one re-admission per exit. Cycle 4 corrected the cause of its 20–95 s totals (the store's per-404 index commit and the
  owned tasks' priority below the heartbeat's, not the fake source or the polling); it is about 1.1 s now.
- Cycle 4: the S1-15 run test's guard (`.minutes(3)`, 101.8–104.7 s beside a second TSan process at load 12–32) awaited
  the orchestrator's ruling (given after cycle 5 as S3-R10 and applied in cycle 6); the `noDispatchOwedFlag` and `noFlagPump` liveness terms have no test (reasons under "Cycle
  4" and "Cycle 3"); the 404 path's engine turns are no longer part of the probe-chain benchmark (the 404 path's own C2
  is not benchmarked at 10,000; its turns are per job, with no catalogue-sized walk).
- Cycle 5: the S1-15 run test's guard still awaited the orchestrator's ruling (S3-R10, applied in cycle 6; it was under half of 3 minutes paired at
  load up to about 14, 79.2–79.5 s, and was over it paired at load 10.5–25.9 in the verifier's run, 129.9–130.1 s; no
  paired run at load about 30 was made here); the survivors `noDispatchOwedFlag` and `noFlagPump` still have no test;
  the sweep's follow budget is pinned at 10,000 by the benchmark on this host only (no device run); `other-wp:b` items
  not re-run (P-13, the per-404 index commit).
- Cycle 6: S1-15's run test is judged against 5 minutes (S3-R10); a paired TSan run at a load above about 30 took it to 175.7–175.8 s (59 %), which the
  ruling does not judge, and no paired run at a load of 26–30 was made here (the moderate one reached 25.6). The lane-drop fix is pinned by one two-member
  scenario (A and B on one content) and the sweep's park bound by a 576-member count; a lane drop in a `.settle` sweep
  or the purge path's `.reclaimed` one runs the same code but has no test of its own. The survivors `noDispatchOwedFlag` and `noFlagPump` still
  have no test; `other-wp:b` (P-13, the per-404 index commit) and `other-wp:b` / `other-wp:h` (the Storage time-outs at
  load 100–540) are not re-run here.
- Cycle 7: whether iOS reports `volumeAvailableCapacityForOpportunisticUsage` above
  `volumeAvailableCapacityForImportantUsage` on a device (the precondition of PROBE-C6-LANEGAIN; the fake file system
  sets it, the store does not clamp it). The new re-queue branch's `readmissionsPerTurn` guard has no test of its own
  (removing it leaves one turn bounded by `readmissionsPerTurn + followsPerTurn` re-queues, since only a followed job
  reaches it). `checkRunSettled`'s `admittedBySpace`, the `.read` sweep and the waiting branch still read a job on its
  pre-follow lane until its follow visit (a delay, never a false answer; no test). The hang guards are sized from paired
  runs on this 8-core host at load up to 35; at load 50–78 a paired TSan run times out about 40 one-minute tests, and
  `stalledSubscriberIsBounded` (4 minutes) is over half its limit at load 20–35 pending a ruling. The survivors
  `noDispatchOwedFlag` and `noFlagPump` still have no test; `other-wp:b` / `other-wp:h` items are not re-run here.
