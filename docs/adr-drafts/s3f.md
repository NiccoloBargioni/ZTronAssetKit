# Stage 3 close-out `s3f` — WP-F (sync engine), cycles 1 to 4

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
S3-R8 (P-13 and the store's per-404 index commit routed `other-wp:b`).

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
  some ids is read again before its figures (the moved interests may have lowered its lane, which can only shrink the
  room its figures read, so the verdict holds). A job left waiting (`awaitingSpace` with a wake expected) acts on nothing
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
  bounds; `spaceParking`, `spaceReadmission` and the follow benchmarks re-run below.
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
`Tests/ZTronAssetSyncTests/Engine/`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` and this draft). Every changed file is WP-F's (ARCHITECTURE §1.2): `Sources/ZTronAssetSync/**`,
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
- Cycle 4: the S1-15 run test's guard (`.minutes(3)`, 101.8–104.7 s beside a second TSan process at load 12–32) awaits
  the orchestrator's ruling; the `noDispatchOwedFlag` and `noFlagPump` liveness terms have no test (reasons under "Cycle
  4" and "Cycle 3"); the 404 path's engine turns are no longer part of the probe-chain benchmark (the 404 path's own C2
  is not benchmarked at 10,000; its turns are per job, with no catalogue-sized walk).
