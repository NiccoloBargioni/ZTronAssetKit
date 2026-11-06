# D4: the 12 open survivors and the 4 unreached places (Stage 3, WP-F, cycle 21)

Read-only analysis at `d5b2ab9` (worktree `.worktrees/s3f`, branch `wp/s3f`; last code commit `e599ae1`). Every
`path:line` below is relative to the worktree, at `d5b2ab9`. Nothing was built, run or timed; every claim is a reading
of the code, the tests and `docs/adr-drafts/s3f.md`. What could not be settled from the code is marked UNCONFIRMED and
listed at the end.

Classes: **REACHABLE** (a deterministic test shape is given), **EQUIVALENT** (S3-R19 item 2), **UNREACHABLE** (S3-R19
item 3: what to remove), **SIMPLIFY** (S3-R16 item 3). For every REACHABLE case the difference is classed as an
**answer** (S3-R16 1(a)), a **MUST/invariant** (1(b)), or **item 2** (order, place, ticket, timing, backoff length).

## 0. Verdicts at a glance

| # | Case | Site | Class | What differs | Change | Kills in |
|---|---|---|---|---|---|---|
| 1 | `r7-fast-ignores-end` | `EngineFailures.swift:834`, `:840` | **UNREACHABLE** (the mutant is EQUIVALENT) | nothing: `atEnd` is always `false` at the only production caller | remove `atEnd` and its conjunct | n/a (branch gone) |
| 2 | `replayVerdict`'s second guard (place 4) | `EngineFollow.swift:882-884` | **UNREACHABLE** (both halves) | nothing on any path | remove the guard; add an epoch clause; one clause test | clause test, both edits |
| 3 | `b23-no-lane` | `EngineCommands.swift:1066` | REACHABLE | MUST 1(b) (R-CLN-6: a user-lane interest kept), observable as content not stored | rr21-T13 variant, user-lane group | both orders |
| 4 | `b23-no-kind` | `EngineCommands.swift:1066` | REACHABLE | answer 1(a) (prefetch-lane waiters never answered: hang) | rr21-T13 variant, prefetch-lane waiters | both orders |
| 5 | `f7-delisted-stays` | `EngineDispatch.swift:1152` | REACHABLE | item 2 (a needless F-20 hold and a store re-read; answers equal) | T-R1 sibling with a delisted id | both orders |
| 6 | `settle`'s owed-answer slice (place 3) | `EngineShutdown.swift:177-183` | REACHABLE | C2 bound of the shutdown turn (the slice is the bound) | new test, 600 owed answers | single order (no follow) |
| 7 | `b22-no-waiter-owner` (place 1) | `EngineFailures.swift:860-862` | REACHABLE | answer 1(a) under a tuning whose lanes' `maxRetryAfter` differ; item 2 under defaults | rr21-T12 new shape `removedAhead` | `sweepFollowsFirst` (sweep-only state) |
| 8 | `p7-forget-at-last-batch` | `EngineFollow.swift:760` | REACHABLE | answer 1(a) (`.notFound` becomes another content's bytes) | pinEnd variant with a chained join | both orders |
| 9 | `r5-lane-engine-copy` | `EngineFailures.swift:843` | REACHABLE | answer 1(a) (tuning as 7) | same test as 8 | both orders |
| 10 | `r8-fast-any-join` | `EngineFailures.swift:840` | REACHABLE | answer 1(a) (tuning as 7) | unlisted-join sibling | `sweepFollowsFirst` (sweep-only state) |
| 11 | `vy-owed-moves-too` | `EngineMoves.swift:308` | REACHABLE | answer 1(a) (`serverUnavailable` becomes a second attempt's bytes) | new MoveHolders test (T7) | `sweepFollowsFirst` (sweep-only state) |
| 12 | `r2c-made-ignores-verdicts` | `EngineFollow.swift:702` | REACHABLE | answer 1(a) | reroute fixture + a verdict between two owing events | both orders |
| 13 | `b22-no-run-owner` (place 2) | `EngineFailures.swift:868-870` | REACHABLE (partly UNCONFIRMED) | answer 1(a) for another caller (fail-fast under a throttle the correct code never sets) | rr21-T18 variant with a purge | both orders |
| 14 | `r2b-made-ignores-previous` | `EngineFollow.swift:702` | EQUIVALENT in every arrival-order queue; REACHABLE only through a composed take-off state (UNCONFIRMED) | answer 1(a) in that state | take-off fixture, or report the residual | `sweepFollowsFirst` if built |

The draft's names map: places 1 and 2 are the b22 pair (`EngineFailures.swift:861-862` and `:868-870` in the draft;
the guards are at `:860` and `:868` here), place 3 is `EngineShutdown.swift:178-183` (the `if` is at `:177`), place 4
is `EngineFollow.swift:883` (the guard spans `:882-884`). 12 survivors + 4 places = 16 cases, places 1 and 2 being the
two b22 survivors.

---

## 1. Special attention (1): what `followedLane`'s lane decides

`followedLane(_:)` (`EngineFailures.swift:729-913`) has one production caller, `throttled` at `EngineFailures.swift:350`,
inside `if self.defersToFollow, self.exitDefers(job)` (`:347`); the only other caller is the benchmark
`BenchSync.followedLaneMedian` (`Tests/ZTronAssetKitBenchmarks/BenchSync.swift:2947-2960`). Its value feeds exactly one
expression: `self.retryPolicy(for: self.followedLane(job))` (`:350`), and `retryPolicy` (`:637-639`) picks
`tuning.interactiveRetry` for `.userInitiated` and `tuning.retry` for every other lane. That policy is read only by
`Backoff.delay(attempt: job.attempts + 1, retryAfter: seconds, policy:, ...)` (`EngineFailures.swift:351`;
`EngineSupport.swift:201-216`), which reads three fields:

- `maxRetryAfter`: a `Retry-After` above it returns `nil`, so the decision is `.exhausted` (`:357-358`): the origin is not
  throttled, and the replay fails the job and answers every interest it holds then
  `serverUnavailable(retryAfter:)` (`replayThrottle`, `EngineFollow.swift:944-947`).
- `baseDelay` and `maxDelay`: the jittered ceiling, so `.until(now + max(delay, Retry-After))` (`:352-355`): the origin's
  throttle end is written **at the arrival** (`self.state.throttles[origin] = ...`, `:353`), and the replay parks the job
  until it (`EngineFollow.swift:949-954`).

It is **not** read for `maxAttemptsPerRun`: no 429 path counts an attempt against a cap (`throttled` calls neither
`reachesCap`, `EngineFailures.swift:643-645`, nor `claimRetries`, `:322-327`, whose lane is the claim's `Job.heldLane`,
L5-R16). It is not the `interactiveMaxWait` of this job either: the replay's park reads the job's lane at the replay.
It is read, indirectly, by **other** requests: the throttle end it writes is what a later user request's gate compares
with `interactiveMaxWait` (2 s) before failing fast.

So:

- **Default tuning** (`RetryPolicy.background` and `.interactive` both have `maxRetryAfter` 3,600,
  `Sources/ZTronAssetModel/Policy/SyncTuning.swift:31-47`): `.exhausted` is lane-independent. A wrong lane changes
  only the throttle length, and not at all when the `Retry-After` is at least the background ceiling (300 s). Without a
  `Retry-After` the ends differ (interactive at most 2 s, background up to 1·2^(n−1) s, jittered by seed): item 2. Only
  in one narrow case does it reach an answer: from the third attempt the background ceiling passes 2 s, so a seeded
  draw above `interactiveMaxWait` can make another user's request fail fast where the interactive end let it wait.
- **A tuning whose lanes' `maxRetryAfter` straddle the `Retry-After`** (public `SyncTuning(interactiveRetry:)`; the tests'
  `shortInteractiveRetry`, `maxRetryAfter` 30, `EngineFollowBarrierAnswerTests.swift:439`, with `Retry-After` 60): the
  lane flips `.exhausted` (no throttle, everyone on the job `serverUnavailable`) against `.until` (origin throttled 60 s,
  the retry serves the job, other users fail fast meanwhile). Both are **answers** (1(a)).

Therefore **b22 (both), r5 and r8 bear on answers** under such a tuning (the tests below use it, as rr21-T12 does,
`EngineFollowBarrierRerouteOwnerTests.swift:58`). **r7 bears on nothing** (§3.1). No survivor can put a request past a
retry cap: the lane never reaches the cap or the claim lane.

## 2. Special attention (2): `replayVerdict`'s second guard (`EngineFollow.swift:882-884`)

```swift
guard self.state.verdictsAfterFollow[transfer]?.epoch == epoch else { return nil }       // :878
self.state.verdictsAfterFollow[transfer] = nil                                            // :881
guard self.state.jobs[transfer]?.epoch == epoch, case .failed? = self.state.jobs[transfer]?.state else {  // :882
    return nil
}
```

Every writer of the record, and of the job's epoch and state while the record exists:

- **The record.** It is written only by `defersFailure` (`EngineFollow.swift:501`), with the epoch of the job present
  then. It is cleared by the replay itself (`:881`) and by `removeJob` (`EngineJobs.swift:475`). `supersede` and
  `retire` go through `removeJob` (`EngineDispatch.swift:1328`, `EngineJobs.swift:427`). So **while the record
  exists, the job exists**.
- **The epoch.** It is written only by a start (`EngineDispatch.swift:705-706`) and by creating a job that does not
  exist (`EngineJobs.swift:156`), which cannot happen while the job exists. A start is made only by `dispatch`
  (`EngineDispatch.swift:392`), reached only from `pump`, which returns while `followBarrier ||
  drainingAfterFollow` (`EngineDispatch.swift:95`). While the record exists, its `.attemptFailed` event is either in
  `eventsAfterFollow`, so `followBarrier` is true (`EngineFollow.swift:97-99`), or in the drain's current batch, so
  `drainingAfterFollow` is true. (The clause at `EngineCommands.swift:2272-2274` already ties each record to its event.)
  **The epoch half is always true.**
- **The state.** `.failed` can only go to `.queued` or stay `.failed` (`JobState.swift:78-79`). The engine has 17
  `transition(_, to: .queued)` sites, and no job state is written outside `transition`. None of the 17 can take a job
  whose verdict waits:
  - `relane`'s failed arm (`EngineJobs.swift:331`) is skipped while `attemptEnd?.deferredAfter != nil`
    (`EngineJobs.swift:307`). `recordDeferredVerdict` sets that in the same turn as the record
    (`EngineFollow.swift:562-563`). Only the replay clears it (`:887`), after the guard. `recordPublicationEnd`
    (`:528-529`), which would reset it, runs only in `publicationFailed` (`EngineDispatch.swift:1259`).
  - `retryDue` (`EngineTimers.swift:199-206`) takes `.failed(.at)` only, and its alarm is deferred behind the barrier
    (`EngineTimers.swift:114-118`).
  - `readmit`'s edge pass (`EngineReadmission.swift:132-168`) takes `owedOnEdge` only, that is `.failed(.whenOnline)`
    and transient `.failed(.at)` (`EngineReadmission.swift:55-64`). Its conditions element is itself deferred
    (`EngineConditions.swift:108-112`).
  - `paused` (`EngineFailures.swift:40`) and `requeue` (`:240`) are an attempt's exits, and both defer first (`:31`,
    `:236`). They are reached only through `finishAttempt`'s guard on the running attempt
    (`EngineDispatch.swift:931`), and a failed job has none (`transition` clears `active`, `EngineJobs.swift:51-53`).
  - `decideSpaceFailure` (`EngineFailures.swift:611`) decides an ENOSPC. That is an event of its own,
    `.spaceFailure` (`:575-576`), which writes no `verdictsAfterFollow` record; an attempt has one exit.
  - `publicationFailed` (`EngineDispatch.swift:1267`, `:1280`) is the one outcome of a publication at the epoch. A job
    whose verdict waits has no publication in flight. Its publication, if it had one, ended in the outcome that
    deferred (`EngineDispatch.swift:1293-1303`, `EngineFailures.swift:521`). `failed → verifying` is not a transition
    (`JobState.swift:72`), so no new publication begins (`EngineDispatch.swift:1022`).
  - The rest take blocked or downloading jobs only:
    - `startMove`'s supersede (`EngineMoves.swift:270`; downloading only, `:264`)
    - `failFastJoiner` (`EngineJobs.swift:245`; `.blocked(.insufficientSpace)`)
    - `relane`'s blocked arm (`:338`)
    - `requeueSwept` (`:1051`; blocked, `:994`)
    - `readmitForProbe` (`EngineReadmission.swift:327`; `.blocked(.circuitOpen)`, `:33-38`)
  - Four are the verdict's own replay, after the guard (`EngineFollow.swift:904`, `:914`, `:923`, `:952`).

  A job whose verdict waits is `.failed(.nextRun)` (`EngineFollow.swift:495`) or `.failed(.untilEntryChanges)` (the
  404 arm, `EngineFailures.swift:139`; `integrityFailed`, `:488`). The events replayed before it in its drain batch
  run in one turn with `drainingAfterFollow` set (`EngineFollow.swift:223-249`). So `pump` starts nothing
  (`EngineDispatch.swift:95`), and those events reach the job only through the sites above. **The `.failed` half is
  always true.** `invariantViolations()` already states it ("jobs whose failure verdict waits for a follow are not
  failed", `EngineCommands.swift:2275-2283`). That clause also counts a record whose job is missing.

**Decision: remove the guard (S3-R19 item 3), and keep the invariant as a clause that a test exercises.**

- Delete `EngineFollow.swift:882-884`. Change the doc sentence at `:876` ("The guards bind no copy of the job") to say
  that while its record waits, the job is present, failed and at the record's epoch (`invariantViolations()`).
- Add the epoch half as a clause next to the `unfailed` one (`EngineCommands.swift:2275`):
  `verdictsAfterFollow.filter { self.state.jobs[$0.key]?.epoch != $0.value.epoch }`, reported as "N jobs whose failure
  verdict waits for a follow are at another epoch".
- Test (G4: the clause must be exercised). Use the `violations(after:)` seam (`EngineOutcomeTests.swift:492-498`), in
  the style of `invariantsReportAWaitingJoinsChainWithoutItsCopies`
  (`EngineFollowBarrierJoinGapFailureTests.swift:99-139`). Build one waiting verdict: the sweep-first state of
  `barrierFailsA429BeyondTheCapsAsOnArrival` (`EngineFollowBarrierReachTests.swift:50`), after the 429 is deferred.
  Then assert that `violations(after: { $0.jobs[c]?.state = .queued })` contains the "not failed" line, and that
  `violations(after: { $0.jobs[c]?.epoch &+= 1 })` contains the "another epoch" line. Kills the drop-mutants of both
  clauses 2/2. It has no barrier order: it builds the state once, in `sweepFollowsFirst`.
- Saving: two dictionary reads per replayed verdict, about 0.05 µs each. At the drain's 512 events a turn
  (`eventsAfterFollowPerTurn`) that is at most about 0.05 ms, below any measured figure's noise.
- What could go wrong: a future writer that breaks the invariant would hand `giveVerdict` a non-failed job
  (`downloading → queued` is legal, so a running job would be re-queued). Both clauses then fire in every barrier test
  that reads the invariants after each turn (`releaseOwedTurns`, `finishHeld`). The removal adds no branch.

---

## 3. Per case

### 3.1 `r7-fast-ignores-end` (`EngineFailures.swift:840`): UNREACHABLE conjunct, EQUIVALENT mutant

- **Mutant**: `if join.chain != nil, !atEnd, !here(join.asset)` becomes `if join.chain != nil, !here(join.asset)`.
- **Argument**: `atEnd` (`:834`) is `waitingTarget(job.transfer, epoch: job.epoch) != nil`, which is non-nil only for
  `.verifying`, `.committing`, or `.failed` with an `attemptEnd` (`EngineFollow.swift:1572-1584`). The one production
  caller (`throttled`, `:350`) runs inside `failed()` for an attempt's terminal element. `finishAttempt` admits that
  element only while `job.active?.attempt == request.attempt` (`EngineDispatch.swift:931`), and only a downloading job
  holds `active` (`transition` clears it on every other state, `EngineJobs.swift:51-53`). So the job is
  `.downloading`, and `atEnd` is `false` on every production call.
- **Change** (S3-R19 item 3): delete `:834`, drop `!atEnd` from `:840`, and rewrite the comment at `:829-833`: the lane
  is read only for a downloading job, at its 429's arrival, never at an attempt's end, so no pin of this job can hold a
  waiting join, and a chained join reaches it only where the copy maps its id here. No new branch; the mutant ceases to
  exist. Update the r7 and r8 texts in `.build-s3f/c21/tools/mut-c4fix.py` (in the worktree); r8 becomes
  `if !here(join.asset)`.
- **Saving**: one `jobs` read, one `waitingTarget` read and a switch per call. The timed path does not change.
  - The benches time `followedLane` (`BenchSync.followedLaneMedian`, `BenchSync.swift:2949-2960`) at
    `BenchSync.swift:2924` and `:3242` and at `BenchSyncJoinChains.swift:165` and `:181`.
  - Every one times a `.blocked(.awaitingSpace)` job: `othersAwaitingSpace` (`BenchSync.swift:2932-2934`),
    `allAwaitingSpace` (`:2647-2648`), or `lastOwedHolder` (`:3552-3554`), the holder of a move owed off such a job.
  - `waitingTarget` is `nil` for those jobs too, so the benches already time the fast path, with 6.75 ms for 10,000
    joins through two layers (`EngineFailures.swift:829-833`). Their figures can only fall, by the removed lookup.
- **What could go wrong**: a future caller for a job at its end would miss joins pinned to it; state the precondition
  in the doc comment.

### 3.2 `replayVerdict`'s second guard: §2

### 3.3 `b23-no-lane` and `b23-no-kind` (`EngineCommands.swift:1066`): REACHABLE

- **Mutants**: drop `$0.lane < .userInitiated` (no-lane) or `$0.kind != .waiter` (no-kind) from the batch arm's filter
  in `withdrawPurgedJoins`. The arm mirrors the job arm, `where interest.lane < .userInitiated && interest.kind !=
  .waiter` (`EngineCommands.swift:1015`).
- **Interest kinds that separate them**: a **user-lane non-waiter**, either a prefetch group registered at `.userInitiated`
  (`recordGroup` takes any lane, `EngineCommands.swift:221`; public `prefetch(_:priority:)`) or an ensure member
  (`.userInitiated`, `EngineCommands.swift:737`, `EngineDispatch.swift:260`). A **non-user waiter**:
  `awaitAsset(id, lane: .prefetch)`. rr21-T13 (`EngineFollowBarrierRerouteOwnerTests.swift:160-203`) has only
  user-lane waiters and a prefetch-lane group, so both mutants keep its strings.
- **Test**: parametrize rr21-T13 with `PurgeKeeps` ∈ {`.userGroup`, `.prefetchWaiters`}, in both `LaneDropVisit`
  orders. Both orders reach the arm: `oweThroughK0` owes the batch in both, since the drain's turns are held
  (`EngineFollowBarrierRerouteLayerTests.swift:40-53`).
  - `.userGroup`: `stageOwedCommit(seed:, moved: 3, wanters: .group, groupLane: .userInitiated)` (the `.released` shape
    of rr21-T12 already builds it, `EngineFollowBarrierRerouteOwnerTests.swift:59`); no waiters on the moved ids.
    Purge `.scope(.identifiers([zz-a1, zz-a2]))` as T13 does.
    - Asserted (visit-first): batch items at the purge `["zz-a1 prefetch", "zz-a2 prefetch", "zz-a3 prefetch"]`; group
      `pending == ["zz-a1", "zz-a2", "zz-a3"]`. After X's release, X's job held all three for the group and the
      store holds zz-a1…zz-a3 at X's content (`harness.store` records, or `boundContent`).
    - Under no-lane: items `["zz-a3 prefetch"]`, pending `["zz-a3"]`, zz-a1 and zz-a2 never stored.
    - Class **1(b)**: R-CLN-6 withdraws only non-user interests ("user waiters keep theirs and re-queue", the job arm's
      own rule), with an observable consequence: the prefetched content is missing, so a later request downloads it.
  - `.prefetchWaiters`: `stageOwedCommit(seed:, moved: 3, wanters: .waiters, lane: .prefetch)`.
    - Asserted with `try #require`, so that a mutant ends the test instead of hanging it: items at the purge
      `["zz-a1 waiter", "zz-a2 waiter", "zz-a3 waiter"]`. Then, as T13: W1…W3 get X's 18 bytes and K O's 16.
    - Under no-kind: items `["zz-a3 waiter"]`. W1 and W2 are on no job and in no batch, so they are never answered:
      **1(a)** (and "nothing hangs").
- **Change**: test only (one parameter and two expectation tables). T13's name is already in `mut-c3.py`'s OWNER
  list, which both mutants run, so the new arguments of the same test need no list change.
- **Cost**: none in production. The kill tests purge a `.scope`, so they stay valid if the fixer also takes the draft's
  `.all` route on the same predicate (read the request before the copy lookup, `docs/adr-drafts/s3f.md:6687-6691`).
  That route is about 1 ms of the 9.15 ms walk: PROBE-C21-PURGE-PARTS gives 9.15, 9.22 and 9.14 ms with the
  predicate, against 7.93, 8.03 and 8.46 ms with `{ _ in true }`, a mean difference of 9.17 − 8.14 ≈ 1.0 ms. Its own
  early return would be cost-only (Equivalent, S3-R19 item 2).
- **What could go wrong**: X must be admitted at prefetch lane in `.prefetchWaiters` (X then holds only prefetch
  waiters). T6's H downloads for a prefetch group (`EngineFollowBarrierMoveHoldersTests.swift:180`, `:214`),
  but the gate under `setUpHeldPublications`' conditions is UNCONFIRMED. If it parks X, keep one user waiter on an
  unpurged id of X's content.

### 3.4 `f7-delisted-stays` (`EngineDispatch.swift:1152`): REACHABLE, item 2

- **Mutant**: `?? false` becomes `?? true`, so an unbound id the copy no longer lists is classed as staying, not moved.
- **Effect**: a delisted id the publication captured (`captured`, `:1142`) sets `refused` (`:1157`). The commit then
  calls `holdForManifest(transfer)` (`:1167` or `:1186`), which inserts the transfer into `heldForManifest` and, with no
  catch-up in flight, schedules a store re-read (`EngineCatchUp.swift:145-151`). The deferred item's re-route still
  ends the interest (T21), so the waiter's answer is `.notFound` either way. The difference is a needless F-20 hold
  and one extra catch-up: **item 2**, with no answer and no MUST. The `:1899` clause stays satisfied, since the hold
  schedules its catch-up.
- **Test**: a sibling of T-R1 `commitHoldsNothingForIDsMovedAway` (`EngineFollowBarrierRerouteCapturedTests.swift:108-129`)
  in both orders.
  - v4 maps zz-a1 and zz-a2 to W's content and **omits zz-a3**: `c.manifest(onW.prefix(2), round: 1)`.
  - Asserted (visit-first): the commit owes the three re-routes; `heldForManifest.isEmpty`; W1 and W2 get W's 20 bytes,
    W3 `.notFound`, K O's 16; no violations.
  - Under f7: `held == [O]`.
  - Both orders reach `committed`, a publication turn with no barrier dependence.
- **Change**: test only; add its name to `mut-c3fix.py`'s CAP list (f7 runs `T1|CAP|LAYER`). Cost: none.
- **What could go wrong**: if the store refuses to bind a delisted id the copy still names nowhere, `captured` still
  contains it, so the mutant's hold appears as argued.

### 3.5 `settle`'s owed-answer slice (`EngineShutdown.swift:177-183`): REACHABLE

- **Argument**: the slice runs only when more than `shutdownStepsPerTurn` (512, `EngineShutdown.swift:46`) owed
  answers reach `settle`. The suites resumed 32 in all (draft `:6791-6794`).
- **Test** (`EngineShutdownDrainTests.swift`, beside R-SYN-15's `shutdownDrainsOverSeveralTurns`, `:18-66`):
  1. `EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))`, one entry zz-c applied.
  2. Start 600 tasks `awaitAsset(zz-c, lane: .userInitiated)`: 600 tokens on one job, more than `answersPerTurn` (512),
     so the commit owes the resumes (`EngineJobs.swift:703`).
  3. `holdAnswerFollowUps()` (as `EngineOwedAnswersTests.swift:71`), then let C stage and commit; require 600 owed
     answers and `answerFollowUpWaiting`.
  4. `shutdown()`. Every caller gets C's location: the stored answers, not `.shutDown`, since the owed answers'
     waiters left `waiters` at the resolution (`EngineShutdown.swift:55-60`).
  5. Assert `shutdownSlices == [512, 88]`, or at least that every slice is at most 512 and the slices sum to 600.
  6. Optionally, `shutdownSliceCounts` (`EngineShutdownDrainTests.swift:76-90`) to see the actor released between the
     slices.
  - The drop-mutant of the `if` at `:177-183` gives `[600]`.
  - Order-independent: no follow is involved.
- **Alternative (SIMPLIFY)**: have `drainEverything` append each drained waiter as
  `.waiter(token, continuation, .failure(error))` to `drain.owedAnswers` and delete `settle`'s waiter loop
  (`EngineShutdown.swift:185-197`). One slice then serves both, and R-SYN-15's existing 600-waiter test reaches it.
  This removes about 11 lines and changes one assertion: `drained.waiters == count` becomes
  `drained.owedAnswers == count` (`EngineShutdownDrainTests.swift:46`). Cost: one enum value per waiter, about 20 ns,
  so 0.2 ms at 10,000, in the shutdown's first turn. Recommended only if the fixer is touching `settle` anyway; the
  test is cheaper and touches no production code.
- **What could go wrong**: the test takes about as long as R-SYN-15's (24-43 s under TSan, its comment `:14-16`), so
  give it `.timeLimit(.minutes(3))`.

### 3.6 `b22-no-waiter-owner` (`EngineFailures.swift:860-862`): REACHABLE, sweep-only

- **Mutant**: the waiter guard becomes always true, so every owed waiter item counts.
- **Argument**: the guard (`:860`) decides only for an owed waiter item whose waiter left without a **waiting**
  removal. A waiting one puts its token in `withdrawn` (`laneEventsWaiting`, `:920-938`), which `:855` checks first;
  that is why rr21-T12 `.cancelled` passes under the mutant.
  - The removal must have **replayed already** while the item is still owed. `replayRemoval` sets
    `waiters[token] = nil` (`EngineFollow.swift:1009-1015`), and `withdraw` keeps the record behind the barrier
    (`EngineCommands.swift:179-181`).
  - That needs the removal **ahead of** the batch in the queue: the cancel comes behind the barrier **before** the
    commit owes. It also needs a drain turn that ends **between** the removal and the waiter's item.
- **Test**: a new rr21-T12 shape `.removedAhead` in `throttleWhileOwed`
  (`EngineFollowBarrierRerouteOwnerTests.swift:49-107`), with tuning `shortInteractiveRetry`.
  1. `stageOwedCommit(seed:, moved: 5, extra: [y], tuning:)`: W1…W5, user lane. Y's script is `[.hold,
     .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(yBytes)]`; P (prefetch) downloads Y.
  2. K0 maps zz-a1…zz-a4 to Z's content (script `.stage`) and **only zz-a5 to Y's**. If W1…W4 joined Y, Y's own lane
     would be user and decide alone.
  3. Split `oweThroughK0` (or give it a `beforeCommit` closure). After `applyHeld(K0, visit)` and before O's unit is
     released, cancel W5; it is answered `.cancelled` at once (R-SYN-4).
     - `sweepFollowsFirst`: `#require` that one removal waits. `followVisitedFirst`: `#require` that none waits and that
       O's job holds no W5 interest. That is S3-R26 12.1's citation: once the follow has ended, the barrier is down,
       so `withdraw` removes the interest at once (`EngineCommands.swift:183-186`) and the commit never owes W5's item.
  4. `holdDrainFollowUps()`; release O's unit. The batch holds 5 items swept first, 4 visited first.
  5. Release the follow's turns until `!followOwed && drainFollowUpWaiting`, then run one drain turn with
     `runOneHeldTurn` (`EngineFollowBarrierDrainBoundTests.swift:52-64`). `drainIDsLeft` is `followIDsPerTurn` = 4
     (`EngineFollowBarrierRerouteFixture.swift:19`; `EngineFollow.swift:224`), and the items pop in (id, token) order
     (a `MinHeap`, `EngineFollow.swift:665`; `RerouteItem.<`, `EngineMoves.swift:162-163`), so zz-a5's is last.
     Swept first, `#require(waiters[W5] == nil)` and that the batch still holds the zz-a5 item. Whether a removal
     spends an id is UNCONFIRMED; with it the turn makes three ids and zz-a5 still waits.
  6. Release Y's 429. Read `throttled` as rr21-T12 does (`:103`), then `finishOwed(c, held:, others: [p])`.
  - Asserted (visit-first): `throttled == true` (Y's lane is P's prefetch; `Retry-After` 60 ≤ 3,600); P gets Y's 24
    bytes after the throttle; W1…W4 get Z's bytes, W5 `.cancelled`, K O's 16; no violations.
  - Under the mutant (sweep first): W5's item counts, so the lane is user and 60 > 30 gives `.exhausted`.
    `throttled == false`, and P gets `serverUnavailable(retryAfter: 60)`: **1(a)**.
  - Kill 2/2 in `sweepFollowsFirst`. The test runs both orders asserting the visit-first answers (S3-R26 12.1).
- **Change**: test only, plus one fixture hook. `throttleWhileOwed`'s test (`owedReroutesDecideA429sLane`) is already
  in `mut-c3.py`'s OWNER list, which this mutant runs. Cost: none.
- **What could go wrong**: if the first drain turn also takes zz-a5, the shape needs one more leading id (`moved: 6`);
  the per-order `#require` shows it.

### 3.7 `p7-forget-at-last-batch` (`EngineFollow.swift:760`) and `r5-lane-engine-copy` (`EngineFailures.swift:843`): REACHABLE, one test

- **p7**: it clears `reroutePinCommits` when the last batch is made. Production clears it only when the barrier comes
  down (`endWorldHistory`, `EngineFollow.swift:372`) and at shutdown (`EngineShutdown.swift:130`). Waiting chained
  joins read the pins too (`joinListing` → `followLayers`, `EngineFollow.swift:785-820`, the lookup at `:806`).
- **r5**: it reads a waiting join's reach under the engine's copy, not under its chain (`joinListing`). It decides for
  a chained join whose chain walks its id to a copy that maps it differently from the engine's.
- **Test**: a new test in `EngineFollowBarrierReroutePinEndTests.swift`, built from `pinEndDropped` (`:90-114`), in both
  orders, with tuning `shortInteractiveRetry`. The batch is owed in both orders (drain held), so J's join waits in
  both.
  1. `stageOwedCommit(seed:, moved: 3, extra: [x, zp], tuning:)`, where zp is zz-p on Z's content (zBytes). X's script
     is `[.hold, .stage(xBytes)]`; Z's is `[.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))),
     .stage(zBytes)]`.
  2. V = `downloadingWaiter(x, c)` (user); P = `downloadingWaiter(zp, c, lane: .prefetch)`, so Z downloads before the
     barrier rises.
  3. `oweThroughK0(c, k0: [x, zp] + onX, publishing: [xT], visit:)`.
  4. **J = `awaitAsset(zz-a1, .userInitiated)`**: K0 lists zz-a1 at X's content, so its join waits **with a chain**
     (`EngineJobs.swift:129-135`). `#require(FollowBarrier.joinWaits(e, zz-a1))`.
  5. K1 = `applyBehindBatch(c.manifest([x, zp], round: 2))`. It drops zz-a1…zz-a3 while X publishes, so the batch's
     and J's K1 layers pin X; `#expect(pins(xT, c) == [true])`.
  6. Release X's unit; X commits (a pin commit is recorded, `EngineDispatch.swift:1132-1133`); await `jobs[xT] == nil`.
  7. K2 = `applyBehindBatch(c.manifest([x, zp] + onZ, round: 3))`, listing the ids again on Z's content.
  8. Release Z's 429. Read `throttled`.
  9. `finishOwed(c, held:, others: [v, p, j])`, driving the clock past 60 s.
  - Asserted (visit-first):
    - J joined X publishing, K1's visit passed X, and X's commit re-routed J under K1's copy: T21, so J `.notFound`.
      W1…W3 `.notFound` (`pinEndDropped`'s answers).
    - V gets X's 18 bytes.
    - Z's 429 meets only P (prefetch): `throttled == true`, and P gets Z's 24 bytes after the retry.
  - Under **p7**: at the batch's end the pins are forgotten, so J's walk returns `nil` (`:806-808`) and J follows K2 to
    Z: J gets Z's 24 bytes, not `.notFound`. **1(a)**.
  - Under **r5**: J's reach is read under K2, where zz-a1 is on Z, so it counts: user, `.exhausted`,
    `throttled == false`, P `serverUnavailable(retryAfter: 60)`. **1(a)**.
  - Kills 2/2 in each order, for both mutants.
- **Change**: test only. Add its name to `mut-c4fix.py`'s JOIN list: p7 runs `PIN|JOIN` and r5 runs `LANE|JOIN`.
  Cost: none.
- **What could go wrong**: Z's attempt must still be held when K2 lands (its script holds it); and the throttle's
  retry needs the clock driven (`EngineRegressionCycle6Tests.driving`), as rr21-T12 does.

### 3.8 `r8-fast-any-join` (`EngineFailures.swift:840`): REACHABLE, sweep-only

- **Mutant**: it drops `join.chain != nil` (after §3.1, it reads `if !here(join.asset)`), so an **unchained** join the
  copy does not map here is skipped. Such a join can still reach the job through its own entry: for an unlisted join
  (`join.listed == false`), `target = join.entry` (`:844`).
- **Test**: a sibling of `barrierLeavesAnAdmittedUnlistedIDToTheVerdictThatWaits`
  (`EngineFollowBarrierUnlistedTests.swift:28-113`), in both orders, with tuning `shortInteractiveRetry`.
  1. X (zz-x) downloads for a **prefetch group** (`registerGroup([zz-x], lane: .prefetch)`); its script is `[.hold,
     .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(xBytes)]`.
  2. `applyHeld(v3, visit)`.
  3. `holdNextApplyFollow()` and apply v4, which adds zz-u at X's content; `serveManifest(v4)`.
  4. U = `awaitAsset(zz-u, .userInitiated)`. Swept first its join waits **unlisted** (chain `nil`: the copy, v3, does not
     list zz-u, `EngineJobs.swift:130-133`, admitted from v4, `EngineManifest.swift:423-430`). Visited first it joins
     X at once.
  5. Release X's 429 **while U's join waits**: before `releaseFollowFollowUps`, unlike the existing test. Read
     `throttled`. Then release the follow, the drain and the apply's follow.
  - Asserted (visit-first): X holds U (user), so `.exhausted` and `throttled == false`; U gets
    `serverUnavailable(retryAfter: 60)`.
  - Under r8 (sweep first): U's join is skipped, the lane is the group's prefetch, the origin is throttled, and the
    retry serves U X's bytes. **1(a)**.
  - Kill 2/2 in `sweepFollowsFirst`. S3-R26 12.1's citation: an unlisted join waits only behind the barrier
    (`addInterest`'s `defersToFollow`, `EngineJobs.swift:129`); visited first, it was made at once.
- **Change**: test only; add its name to `mut-c4fix.py`'s LANE list, the one r8 runs. Cost: none.

### 3.9 `vy-owed-moves-too` (`EngineMoves.swift:308`): REACHABLE, sweep-only

- **Mutant**: `listing == nil ?` becomes `true ?`, so the visit-rest passing rule also applies to an owed inbound move
  (`continueInbound` passes `listing: move.copy`, `EngineFollow.swift:1526`, `:1530`).
- **Where it decides** (the draft's state does not separate it):
  - `startMove` calls `continueMove` only for a move larger than its budget (`EngineMoves.swift:257-258`); a move that
    fits goes through `move`, which has no passing rule. The rule computes a set only for a **verifying** holder.
  - A move found off a verifying holder records only ids in that holder's `rerouteOnVisit` (`foundInbound`,
    `EngineFollow.swift:1393-1397`), so those always pass the rule.
  - It separates only when the holder was **downloading when the move was found and is verifying when the move is
    continued**. That happens inside the holder's own `publish`: `transition(.verifying)` (`EngineDispatch.swift:1022`),
    then `bringInbound(H)` → `makeInboundNow` → `continueInbound`, which continues the owed move off H.
  - At that moment H's `rerouteOnPass` is still `nil` from its start (`EngineDispatch.swift:741`); `publish` writes it
    only after (`:1039`). So `rerouteOnVisit(H)` is `[]` (`EngineFollow.swift:1141`) and the mutant passes every
    remaining item.
- **Test**: new T7 in `EngineFollowBarrierMoveHoldersTests.swift`, in both orders.
  1. `FollowBarrier.setUp` with `maxConcurrentTransfers` ≥ 2 and `followIDsPerTurn = 4`, so `inboundIDsNow` is 2.
  2. v2: zz-h0…zz-h3 on H's content (user waiters W0…W3); zz-t on T's content (user waiter WT).
  3. Scripts: H `[.hold, .stage(hBytes)]`; T `[.hold, .fail(.transient(.throttled, retryAfter: .seconds(7_200))),
     .stage(tBytes)]`. 7,200 exceeds both lanes' 3,600, so `.exhausted` under default tuning.
  4. `applyHeld(v3, visit)`: v3 moves zz-h1…zz-h3 to T's content and keeps zz-h0 on H's, so H is not superseded.
  5. Release T: its 429 defers (`defersFailure`); `bringInbound(T)` finds one move off H of three ids and makes two
     (h1, h2). Swept first, `#require` that the owed move off H has one item left (zz-h3) and that T's verdict waits;
     visited first, `#require` that T's job is gone (answered).
  6. Release H. Its `publish` continues the move: correct, zz-h3 joins T at once (`bringingInbound`,
     `EngineJobs.swift:113`); mutant, it stays on H.
  7. Await `jobs[H] == nil`. Release the follow's turns and await the drain's end.
  - Asserted (visit-first, where v3's visit moved zz-h1…zz-h3 onto T downloading before its 429): W0 gets H's bytes;
    WT, W1, W2 and **W3** get `serverUnavailable(retryAfter: 7200)`; `starts(T's transfer) == 1`; invariants clean.
    Swept first, after step 6, `jobs[T].assets.contains(zz-h3)`.
  - Under the mutant: zz-h3 rides H. H's commit leaves it unbound and re-routes it, and its join waits behind T's
    verdict as an event. After the replay removes T, the join creates T', whose second attempt stages: **W3 gets T's
    bytes, `starts == 2`**. **1(a)**.
  - Kill 2/2 in `sweepFollowsFirst`. S3-R26 12.1's citation: `bringInbound` returns unless `followOwed`
    (`EngineFollow.swift:1302`); visited first, the follow ended before T's 429, so no move is owed off H.
- **Change**: test only; add T7's name to `mut-b.py`'s `T6` list (vy runs `T6|Q1`). Cost: none.
- **What could go wrong**: if H's publication waits (`inboundBlocks`), step 7 waits for the follow first. That holds
  only while a move or a rest is owed onto or off H, and none is once the move is done.

### 3.10 `r2c-made-ignores-verdicts` (`EngineFollow.swift:702`): REACHABLE

- **Mutant**: `layerOwedReroutes` reuses the last layer made whenever the previous apply matches, ignoring a verdict
  appended between. The walk is backward (`:713`), so the newer event B's layer, made before any verdict, is reused for
  the older event A across a live verdict V between them (A < V < B), and A's `ends` lack V.
- **Test**: in `EngineFollowBarrierRerouteLayerTests.swift`, in both orders (the batch is owed in both).
  1. `stageOwedCommit(seed:, moved: 3, extra: [x, j])`: W1…W3 user waiters, plus zz-j on its own content (script
     `.stage`).
  2. X's script is `[.hold, .fail(.transient(.throttled, retryAfter: .seconds(7_200)))]`; V' =
     `downloadingWaiter(x, c)` (user).
  3. A = `oweThroughK0(c, k0: [x, j] + onX, visit:)`: zz-a1…zz-a3 go to X's content; one batch.
  4. Release X's 429; it defers behind A (`verdictsAfterFollow[X] != nil`).
  5. B = `awaitAsset(zz-j, .userInitiated)`: its join waits with a chain. `#require` that the queue holds the batch, then
     X's verdict, then J's join.
  6. K1 = `applyBehindBatch(c.manifest([x, j] + onY, round: 2))`, moving zz-a1…zz-a3 to Y's content (script `.stage`).
  7. `#expect(pins(xT, c) == [true])`: under r2c `[false]`.
  8. `finishOwed(c, held:, others: [v', jWaiter])`.
  - Asserted (visit-first, where O's commit re-routed W1…W3 onto X downloading and X's 429 answered them):
    W1…W3 and V' get `serverUnavailable(retryAfter: 7200)`; J gets zz-j's bytes; `starts(Y) == 0`.
  - Under r2c: W1…W3 follow K1 to Y and get Y's bytes. **1(a)**. Kill 2/2 in both orders.
- **Change**: test only; add its name to `mut-c4fix.py`'s LAYER list (r2c runs `JOIN|LAYER`). Cost: none.
- **Why not SIMPLIFY (drop the cache)**: without `made`, each owing event rebuilds its `ends`, an O(verdicts) loop and,
  if any verdict qualifies, a dictionary allocation. With 10,000 waiting joins and many verdicts behind them this is
  O(events × verdicts). The cache exists for the joins one stretch of the queue deferred (`:697-699`). With it, the
  pass took 2.96 to 3.15 ms for 10,000 waiting joins (`BenchSync.joinChainTurns`, `:687-689`). Keep it.

### 3.11 `b22-no-run-owner` (`EngineFailures.swift:868-870`): REACHABLE (partly UNCONFIRMED)

- **Mutant**: `case .run: break`, so an owed run item counts even when its run is no longer the engine's. Run items
  are `.bulk` (`EngineRuns.swift:499`), so counting one changes the lane only where nothing else counts: `return lane
  ?? job.lane` (`:912`) becomes `.bulk`. That differs in policy only when `job.lane` is `.userInitiated`.
- **State**:
  1. An owed batch holds a run's items.
  2. The run is gone: `finishRun` sets `state.run = nil` (`EngineRuns.swift:828`). Normal settlement waits for every
     owed batch (`checkRunSettled`, `EngineRuns.swift:592`), but a purge settles the run `.cancelled` directly
     (`EngineCommands.swift:973`). A purge of an unrelated scope keeps the items (the arm removes only purged ids).
  3. The 429's job keeps a user interest whose removal waits (in `withdrawn`, so not counted, but still on the job, so
     `job.lane` is user).
- **Test**: a variant of rr21-T18 (`EngineFollowBarrierRerouteRunTests.swift:88-130`), in both orders.
  1. Give `stageOwedRun` (`:49`) a `tuning:` parameter, set to `shortInteractiveRetry`.
  2. Extras zz-y (Y's content: U, a user waiter, downloading; script `[.hold, .fail(.transient(.throttled, retryAfter:
     .seconds(60))), .stage(yBytes)]`), zz-q (the purge's scope) and zz-r (R's content, script `.stage`).
  3. K0 maps the run's zz-a1…zz-a3 to Y's content; O's commit owes the three run items.
  4. Purge `.scope(.identifiers([zz-q]))`, then `#require(state.run == nil)` (UNCONFIRMED: that the run task reaches
     `finishRun` while the batch waits).
  5. Cancel U: it is answered `.cancelled` and its removal waits.
  6. Release Y's 429; read `throttled`.
  7. U2 = `awaitAsset(zz-r, .userInitiated)`; release the turns.
  - Asserted (visit-first: the commit re-routed the claims onto Y; the purge's `finishRun` took the run's interest off
    Y; U's cancel retired Y before any 429): `throttled == false` and U2 gets R's bytes. Correct code: the fallback is
    user, so `.exhausted` and no throttle.
  - Under the mutant: `.bulk`, so `.until`: the origin is throttled 60 s at the arrival (`EngineFailures.swift:353`).
    U2's job, admitted after the drain, fails fast `serverUnavailable`, since 60 s exceeds `interactiveMaxWait` 2 s.
    **1(a)** for U2.
  - Kill 2/2 in both orders.
- **Change**: test plus one fixture parameter; add its name to `mut-c3.py`'s RUNT list (the mutant runs
  `OWNER|RUNT`). Cost: none.
- **What could go wrong**: the UNCONFIRMED `finishRun` timing. If the run task waits for something the batch holds,
  `state.run` stays the settled run (same token) and the state does not arise. Then the guard is unreachable for that
  route, and the fixer should look for another run end while owed (`settleRun(.blocked)`, `EngineRuns.swift:744`)
  before claiming it. The case would then be an UNREACHABLE candidate, with removal of the run arm's check.

### 3.12 `r2b-made-ignores-previous` (`EngineFollow.swift:702`): EQUIVALENT in arrival order; composed state UNCONFIRMED

- **Mutant**: it reuses the last layer whenever the verdict count matches, ignoring `previous`.
- **Argument, arrival order**: two owing events A (older) and B (newer) with no live verdict between them.
  - B was created after A, and both take a layer at every apply from B's creation on (`appendLayer`,
    `EngineFollow.swift:1790-1799`; the invariant `layers.count == copySerial − serial`, `EngineCommands.swift:2205`,
    `:2210`). So `previous` differs only when B has no layer yet (`nil`) and A has one (N = the last apply's
    `appliesFollowed` before its increment). `adoptApplied` layers before `followApplied` increments
    (`EngineJobs.swift:1183-1186`, `EngineFollow.swift:48`).
  - Every verdict behind B was deferred after B's creation, hence after that increment, so its `deferredAfter` is at
    least N + 1 > N and it counts for A as it does for B (`nil`). The two `ends` are equal.
  - A batch the drain puts back at the head after a partial turn keeps its own layers, so the same holds for it.
- **The only queue that breaks arrival order** is a take-off batch T put at the head by `landTakeOff`
  (`EngineFollow.swift:632-640`) with `layers: []`, ahead of events that have layers.
  - T's first layer may then wrongly drop a live verdict V (`deferredAfter` ≤ the next event's `previous`).
  - That matters only if one of T's items starts from an entry naming V's content (the walk reads
    `layer.ends[entry.transferID]`, `:800`). T's ids are those still on the verdict's job; a visit passes them while their
    `rerouteFor` is current. Such an item therefore needs a **stale** `rerouteFor` (a follow ended between the
    verdict's deferral and the apply that moved it) and a later verdict on that content.
  - Not built; UNCONFIRMED both that it arises and that the correct layer gives the visit-first answer there.
- **Recommendation**: do it last. If it is built, use `EngineFollowBarrierRerouteTakeOffFixture.swift`, with an
  apply between two drain turns (the drain held) after the take-off is owed, and assert T's item's answer is its
  verdict's. Otherwise report it with this argument: EQUIVALENT for every queue in arrival order; the composed
  take-off state is the open residual.

---

## 4. Order of work and estimate

Cheapest kills first. The hours are a fixer's writing and debugging time. Each mutant then needs its two runs in the
killing order, using the worktree's `.build-s3f/c21/tools/mut-*.py` scripts at about 10-15 min a run (the draft's
900 s budget). The close needs one gate run.

| Step | Case(s) | Kind | Writing | Mutant runs |
|---|---|---|---|---|
| 1 | r7 (§3.1) | removal, 2 lines and a comment | 0.5 h | none (branch gone; the lane benches' path is unchanged) |
| 2 | b23 ×2 (§3.3) | test parameter | 1 h | 4 (2 mutants × 2) |
| 3 | f7 (§3.4) | T-R1 sibling | 1 h | 2 |
| 4 | settle slice (§3.5) | new test | 1 h | 2 |
| 5 | `replayVerdict` guard (§2) | removal, clause and clause test | 1.5 h | 2 (the new clause) |
| 6 | b22-no-waiter-owner (§3.6) | rr21-T12 shape and a hook | 2-3 h | 2 |
| 7 | p7 + r5 (§3.7) | one pinEnd test | 3 h | 4 |
| 8 | r8 (§3.8) | unlisted sibling | 2 h | 2 |
| 9 | vy (§3.9) | MoveHolders T7 | 2-3 h | 2 |
| 10 | r2c (§3.10) | layer test | 2-3 h | 2 |
| 11 | b22-no-run-owner (§3.11) | rr21-T18 variant and a fixture parameter | 3-4 h | 2 |
| 12 | r2b (§3.12) | composed take-off test, or report | 4-6 h, or 0.5 h to report | 2 if built |

Totals:

- **Writing, steps 1 to 11.** At the low end: 0.5 + 1 + 1 + 1 + 1.5 + 2 + 3 + 2 + 2 + 2 + 3 = 19 h. At the high end:
  0.5 + 1 + 1 + 1 + 1.5 + 3 + 3 + 2 + 3 + 3 + 4 = 23 h.
- **With r2b.** Reporting it adds 0.5 h, for **19.5-23.5 h**. Building it adds 4-6 h, for **23-29 h**.
- **Mutant runs.** There are 4 + 2 + 2 + 2 + 2 + 4 + 2 + 2 + 2 + 2 = 24 runs, or 26 with r2b built. At 10-15 min each
  that is 4.0-6.0 h of machine time (4.3-6.5 h with r2b), at most two at once on separate simulator sets.
- **The close.** One gate run.

Steps 1 to 5 can land first, one small commit each. In about 5 hours they dispose of four survivors (r7 removed; b23 ×2
and f7 killed) and two places (place 3 reached, place 4 removed). None adds work to a timed path.

## 5. UNCONFIRMED

1. §3.11: that a purge-cancelled run reaches `finishRun` (`state.run = nil`) while an owed batch with its items waits.
   If not, the route is closed and `b22-no-run-owner` needs another run end, or becomes an UNREACHABLE candidate.
2. §3.12: whether the take-off-at-head state with a stale-`rerouteFor` item naming a later verdict's content arises,
   and that the correct layer gives the visit-first answer there.
3. §3.6: whether a `.removal` event spends a drain id (`drainIDsLeft`). The shape guards it with a per-order
   `#require` and one spare leading id.
4. §3.3: prefetch-lane admission of X when it holds only prefetch-lane waiters under `setUpHeldPublications`.
5. The exact `serverUnavailable(retryAfter:)` payloads (7,200 or 60) in §3.7 to §3.10: assert equality with the job's
   own waiter's answer, not a literal, if the fake's `RetryAfter` conversion differs.
6. §1: that no fail-fast differs under default tuning in practice. Only seeded draws above 2 s from the third attempt
   could make one differ; not enumerated.
7. Every test shape in §3 is a reading of the fixtures. None was compiled or run (READ ONLY), so each needs the
   fixer's 2/2 kill run in the stated order before it counts. The answers the shapes assert are the visit-first
   answers derived from the code, and the first run of each shape against the unmutated code confirms them.

The bench question an earlier draft listed here is settled (§3.1). Every `followedLane` bench times a
`.blocked(.awaitingSpace)` job, so `atEnd` is `false` there too. Every `path:line` above was re-read with `sed -n` at
`d5b2ab9` before this report was finalised.
