# D5: held-turn readers that loop "while followOwed", audited for the reservation-edge race

Read-only analysis of `wp/s3f` at `d5b2ab9` (code at `e599ae1`), worktree `/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f`.
Paths are relative to the worktree. Nothing was built, run or edited.

## Verdict

- **No racy reader in the seven listed suites.** Every reading taken after a turn that leaves the barrier down is
  safe. It is held at the source, its publication is held, its retry waits for the clock, or it reads only answers,
  logs, events, flags or invariants. Some readings also show the same value in both orders.
- **No racy reader in the rest of the Sync tests either.** One reader is safe only because of a premise it does not
  assert: `EngineFollowBarrierWaitingTargetTests.swift:191`. An optional one-line pin is proposed for it. Another,
  `EngineFollowBarrierSpaceReadTests.swift:236`, already tolerates the race by design.
- **Ruling suggestion:** no Sources change and no test fix is required. Record the audit in the draft in place of the
  "not audited one by one" lines (`docs/adr-drafts/s3f.md:6653-6655`, `:9807-9808`). Optionally add the WaitingTarget
  pin. C2 is untouched: 0 ms either way, since only tests would change.

## The race, as the code makes it

1. **The barrier holds back starts.** The pump admits nothing while `followBarrier || drainingAfterFollow` holds
   (`Sources/ZTronAssetSync/Engine/EngineDispatch.swift:95`).
2. **The follow's last turn pumps.** It pumps (`EngineFollow.swift:154`) and then runs the drain's first batch (`:158`).
   The drain's last batch pumps once the barrier is down (`EngineFollow.swift:259`). So the turn that drops the barrier
   can start attempts.
3. **A fake attempt can end inside that turn's start.** A step that is not `.hold` runs synchronously inside
   `transfer(_:)` (`Sources/ZTronAssetTestSupport/RecordingFakes.swift:340-344`). Its `.stage` or `.fail` terminal is
   delivered before the handle returns. The driver then hops onto the actor with it, after the turn and before or after
   the test's next `readForTests` call, as the scheduler orders them.
4. **Some attempts are never at risk:**
   - an unscripted attempt never ends (`RecordingFakes.swift:600-607`);
   - an attempt at `.hold` waits for `release`;
   - a `.stage` attempt whose publication meets a holding `SteppedBlockingExecutor` stays `.verifying`.
5. **Which retries start at once.** A retry starts at once only through T20, a user request skipping the backoff
   (`EngineJobs.swift:281-284`, `relane`). Otherwise it waits for the clock, and no held-turn loop advances the clock.
6. **The fix.** `takeOffTurns` holds the attempts' terminals for the whole reading sequence
   (`Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierRerouteTakeOffFixture.swift`, `e599ae1`), using
   `holdAttemptTerminals()` and `releaseAttemptTerminals()` (`EngineDispatch.swift:887-899`).

"Racy" below therefore requires all of these together:
- the reading comes after a held turn that leaves the barrier down, or after an `awaitCondition { !$0.followBarrier … }`;
- the reading reads a job, an id, an interest or a count;
- an attempt that changes that value can start in that turn and end at once (a `.stage` or `.fail` step, not held,
  whose publication is not held), as a fresh job or a T20 retry.

## Classification: the seven listed suites

Helpers used throughout:
- `runOneFollowTurn` (`EngineFollowBarrierAnswerTests.swift:49`) runs one follow turn inside one `readForTests` call.
- `runOneHeldTurn` (`EngineFollowBarrierDrainBoundTests.swift:52`) does the same for one follow or drain turn.
- `membersLeft` (`EngineFollowBarrierSharedMoveTests.swift:91`) returns 0 when the job is gone.

None of these loops holds the drain's follow-ups, except DeferBucket's `deferBucketTurns`. So the barrier drops either
in the follow's last held turn or in an unheld drain turn that runs before the test's next actor call.

### MoveHolders (`EngineFollowBarrierMoveHoldersTests.swift`)

**T2 `barrierReroutesAMovesInterestsByToken`:** SAFE.
- Loop `:65-69`: the loop reads `followOwed` only.
- `:77` `admissionsForTests`: an append-only log, read after every waiter is answered (`:74-76`). The eight contents'
  `.stage` attempts (`:43-44`) do end at once after the barrier drops. But each admission pops the queue head, and the
  move queued the eight in token order in one turn, behind the barrier. So the first-admission order is the queue order
  whichever attempt ends first. The race cannot reorder it.
- `:84` invariants, `:87` answer: SAFE.

**T3 `barrierReroutesEveryHolderOfAMovedID`:** SAFE.
- `:163` `after` reads O's interests, G's ids on O, and H's ids and interests. Both readings are held at the source:
  - O is `[.hold, .stage]` (`:127`), and the reading waits for O to be `.downloading` (`:160-162`);
  - H is `[.hold, .stage]` (`:126`).
- No other job exists for the moved ids.

**T6 `barrierBoundsOneIDMovesOffAHolderPerTurn`:** SAFE.
- `:265` `left()` runs after every follow turn, the last one included, and counts H's members. H is held at the source
  (`:210`).
- The moved members' targets, U0 to U7, are `.verifying`. Their publications are held by `bulk` (`:219`, `:226-229`),
  and the releaser lets only other units through (`:230-237`).
- No job can start and end after the barrier drops.
- `:268` invariants, `:277` `onUsers`: still held, before `bulk.setHolding(false)` at `:281`.

### Convergence (`EngineFollowBarrierConvergenceTests.swift`)

**`convergence` / `barrierMovesConvergingIDsOverTheFollowsTurns`:** SAFE.
- Loop `:140-144`: the loop reads `followOwed` only.
- After the barrier drops, the test reads only:
  - answers (`:148-152`);
  - `zStarts`, the fake's start log, read after every answer (`:153`).
- Z's `.stage` attempt (`:79`) ends at once, but a log entry does not depend on when it ends.

### MoveRevalidation (`EngineFollowBarrierMoveRevalidationTests.swift`)

**`moveRevalidation` / `barrierRereadsWhatLandsBetweenABoundedMovesTurns`:** SAFE.
- `:139` `rest`: read with H's visit's rest still owed (`followMoving`), so the barrier is up.
- `:145` `left`, read after each turn, the last included: the engine has one slot and no reserved slot
  (`maxConcurrentTransfers: 1, reservedInteractiveSlots: 0`, `:71`). O holds that slot at its `.hold` (`:90`) until
  `:167`.
- Nothing queued can start, and so nothing can end. P is `[.stage]` (`:91`) and H is `[.stage]` (`:92`), both prefetch.
  No user job waits, so preemption cannot apply.
- `:152-163` `state` (H's ids, lane and state `== .queued`; O's ids; G's and G2's jobs): the same slot argument. These
  are the readings the race would most easily break: H would leave `.queued` if it could start.
- `:176` `starts`: a log.

### MoveIndex (`EngineFollowBarrierMoveIndexTests.swift`)

**B-T4 `barrierTakesABoundedMovesUnheldIDsOffTheHolder`:** SAFE.
- `:64` reads H's ids. H is `[.hold, .stage]` (`:43`).
- G was released, so the moved ids have no interest and no target job.

**`restRejoin` (B-T5 and its two probes):** SAFE.
- `:215` and `:227`: the barrier is up. A rest is still owed: the loops stop on `followMoving` and on H's id count, and
  the requires assert `left.rest`.
- `:270-272` `held` (H's ids, and the interests that hold A): H's publication is held. `bulk.setHolding(true)` at
  `:234` stays on until `:281`, and `:269` requires the held unit. H's job cannot end before the reading.
- The other contents give no job a path to end and change H:
  - X is `[.hold]` (`:168`);
  - Y and Z (`:169-170`) get no job before the reading: T1 and T' stay on H, as visited first;
  - P was superseded earlier.
- `:295` `hStarts`: a log, read after the answers.

### SharedMove (`EngineFollowBarrierSharedMoveTests.swift`)

**`sharedMove` / `barrierMovesASharedContentsIDsOverBoundedTurns` and `…ShutsDownWhileAPublicationWaits…`:** SAFE.
- `:206` `membersLeft(holder)` after each turn, the last included. Converging, the holder is H, `[.hold, .stage]`
  (`:142`). It is superseded and gone once its last id moves, and `membersLeft` then returns 0.
- Diverging, the holder is O, `[.hold, .stage]` (`:136`):
  - The members' own contents are `[.stage]` (`:144-146`). Their jobs start when the barrier drops and end at once,
    since `setUpHeldPublications` builds its bulk executor unheld.
  - Their ends change the members' new jobs, not O's ids. Every member has already left O by the follow's last turn.
  - With `.divergencePublishes`, O's own publication can end O before the reading. `membersLeft` is 0 either way.
  - The reading has the same value in both orders.
- `:139`, `.convergenceBystander`: zz-t's new content is `[.stage]`. No reading names it except its waiter's answer.
- `:200`, `:210` `cancelsAtFirstMove`: read after the move's first turn, with the barrier up. `handle.cancel()` is
  synchronous in the turn (`EngineJobs.swift:442`).
- `:212` `resting`, `:218-231` (`moveSizes`, `pendingAtEnd`, `ended`, `carried`, `movesAfterApply`): the barrier is up
  (an owed move or rest).
- `:243` `inboundWaits.count`: a flag-like table that nothing fills once the follow ends.
- `:267`, `:269`: logs, read after the answers.

**`drainRemainder` / `barrierDrainsTheEventsAfterAVisitsRest`:** SAFE.
- `:468` reads C's ids among the members, after each turn. C is `[.hold, .fail(timedOut), .stage]` (`:419`).
- The drain's replay of C's verdict backs C off. Its retry waits for the clock (`shortInteractiveRetry`,
  `EngineFollowBarrierAnswerTests.swift:439`), and no T20 applies:
  - the members moved off C are prefetch waiters;
  - zz-c's user waiter joined before the failure, and no user request joins C later.
- Nothing advances the clock inside the loop (`driving` starts at `:479`).
- The value is also the same in both orders: by the follow's last turn every member has left C (0).
- N's 404 verdict ends N, which no reading names.

### TurnTotal (`EngineFollowBarrierTurnTotalTests.swift`)

**`barrierBoundsAnOwedMovesTurnAcrossHolders`:** SAFE.
- `:87` `left()` sums H1's and H2's members. Both are `[.hold, .stage]` (`:51-52`) and are superseded when their last
  ids move. After the last turn every member has left them, so the value is 0 whether they exist or not.
- O's verdict, a 404 with nothing scripted after it (`:50`), answers and ends O. No reading names O's job.
- `:78` `moveSizes`: the barrier is up.

**`barrierBoundsARestsTurnAcrossHolders`:** SAFE.
- `:182`: the same argument. H1 to H3 are held (`:150`), and O is held (`:147`) until `:188`.

### DeferBucket (`EngineFollowBarrierDeferBucketTests.swift`)

This suite has the shape closest to the take-off's. With `.timeoutUsers`, the drain replays O's timeout and places the
user joins behind it. T20 starts O's retry `[.stage(oBytes)]` (`:115`) at the drain's last pump. Its publication is not
held (`FollowBarrier.setUp`). It can end before the next reading.

**`deferBucketTurns` (`:224-235`), used by A-T1, A-T1-place, A-T1-skip, A-T-PURGE and the invariants test:** SAFE.
- It holds the drain's follow-ups (`:227`) and reads `deferBucketTurn` (`:197-218`) after each turn. That reading
  covers `owed`, `queue` (the waiting events), `registered` (`joinsAfterFollow`), `behind`, `buckets` (the verdict
  buckets), `violations` and the follow's own counters.
- Nothing there reads a job, so an attempt's end cannot change it. Once the barrier is down nothing defers, so a
  terminal adds no event.
- The invariants are one consistent snapshot in any order.
- A-T1 asserts only on readings with `owed == true` (`:321`), where the barrier is up, plus `violations` on every reading
  (`:327`).

**A-T1-place:** SAFE.
- `:366-371` reads `last.queue` after the follow's last turn. `:369` requires the queue non-empty, with the drain held,
  so the barrier is up.

**A-T1-skip:** SAFE.
- `:399-405`: the barrier is up. The follow is owed, and the require asserts the verdict's event waits.

**A-T1-space:** SAFE.
- `:495-499`: the loop's own condition reads `followOwed` and the buckets.
- `:500-507` `waiting`: the require asserts that the ENOSPC event waits, with the drain held, so the barrier is up.
- `:519` waits for C's retry, which is held at the source: `[.hold, .stage, .hold, .stage(wrong)]` (`:461`).

**A-T-PURGE:** SAFE.
- `:556-563` `after`: the barrier is up (the drain is held).
- `:575`: O's retry is held at the source (`holdRetry`, `:115`).
- `:581` `held`: read after O's retry has answered.

**429 test:** SAFE.
- `:665-668` and `:675`: the barrier is up (the follow is owed, or the drain is not yet released).
- O's retry is held: `[.hold, .fail, .hold, .stage]` (`:640`).
- C's retry waits for the throttle and the clock.

**Shutdown test:** SAFE.
- `:767`: the barrier is up. `:771`: read after shutdown.

## The rest of the Sync tests: the same pattern elsewhere

I searched every call of `runOneFollowTurn` and `runOneHeldTurn` (39 calls), every held-turn loop, and every reading
within four lines of an `awaitCondition { !$0.followBarrier … }` or `{ !$0.followOwed … }` (about 45 sites) in
`Tests/ZTronAssetSyncTests/Engine/`.

**No racy reader.** Several sites the fixer did not list are worth naming:

| Reading | Class | Why |
| --- | --- | --- |
| `EngineFollowBarrierWaitingTargetTests.swift:191-195` (`afterTurn`: H's and T's ids after one held follow turn) | SAFE, on an unasserted premise | T's later attempt is `tLater: [.stage(100 kB)]` (`:172`): if this turn dropped the barrier, its pump would start T, the attempt would end at once, and the unheld publication could end T, so `afterTurn.t == [a, x]` would fail. It does not drop the barrier. The `middle` layout puts 2,152 changed `g…` entries and 2,152 changed `f…` entries before the scenario's ids (`:22-24`, `:36-41`), more than one turn formats (`followFormatsPerTurn + 52`), and only one follow turn has run since v3 and v3b were applied. The reading checks `inboundOwed` only, not `followOwed`. |
| `EngineFollowBarrierSpaceReadTests.swift:236-237` (`read`) | SAFE by design | The comment and the expectation already accept "gone" ("the re-queued attempt can end before this read"). |
| `EngineFollowBarrierAnswerTests.swift:642`, `:766` (`passed`) | SAFE | The barrier is up: `#expect(passed.owed …)`, and C's publication is held. |
| `EngineFollowBarrierRunClaimTests.swift:137` | SAFE | The barrier is up: the require asserts T's verdict waits. |
| `EngineFollowBarrierRerouteOwnerTests.swift:266` | SAFE | Owed batches only (a flag). |
| `EngineCommitWindowTests.swift:126`, `EngineFollowBarrierRetryTests.swift:63`, `EngineFollowBarrierStaleRerouteTests.swift:154`, `EngineFollowBarrierPublicationTests.swift:249` | SAFE | The publication is held. |
| `EngineFollowBarrierLiveGateTests.swift:60`, `EngineFollowBarrierWorldTests.swift:256` | SAFE | They read the throttle flag and the start log. N's state appears only in the message. |
| `EngineFollowBarrierClassTests.swift:423`, `EngineFollowBarrierVerdictTests.swift:166` | SAFE | C's retry waits for the clock (no T20; the test notes "No clock movement"). A wrongly started retry fails the `failed(.at)` check and `cStarts` in either order. |
| `EngineFollowBarrierVerdictApplyTests.swift:315` | SAFE | C's later attempts are unscripted, so they never end. |
| `EngineFollowBarrierAnswerTests.swift:233`, `:296`; `EngineFollowBarrierLaneTests.swift:62`, `:142`; `EngineFollowBarrierReplayTests.swift:375` | SAFE | They expect no job. A job that started and ended could only pass falsely, and the starts counts beside them catch it. |
| `EngineFollowBarrierWorldTests.swift:408`, `:563`; `EngineFollowBarrierApplyTests.swift:180`; `EngineFollowBarrierClassTests.swift:57`; `EngineFollowBarrierMovedBeforeTests.swift:161`; `EngineFollowBarrierRerouteHealTests.swift:72` | SAFE | The jobs are held at the source (`.hold` first), or the reading only guards a `release`. |
| The post-barrier `awaitCondition { … .downloading }` waits (`EngineCommitWindowTests.swift:70`, `EngineFollowBarrierReachTests.swift:350`, `EngineFollowBarrierSlotTests.swift:68`, `EngineFollowBarrierMovedBeforeTests.swift:265`, `EngineFollowBarrierReplayTests.swift:178`, `EngineFollowBarrierWorldTests.swift:181`) | SAFE (no hang) | Each awaited job's script starts with `.hold`, and the test releases it next. A wait on a state that ends at once would hang; none does. |
| `EngineFollowTests.swift:1261`, `EngineSweepOrderTests.swift:487` | SAFE | Visited first. The expectations read `owed` only, and K is blocked on space. |
| `EngineOwedAnswersTests.swift:129`, `:194`; `EngineFollowBarrierWindowTests.swift:45` | Not this pattern | Answer follow-ups and a held metadata executor, not the barrier. |

The fixer's own list (Step 8: RerouteRequeue, RerouteCommit, DrainBound, RunClaim, ReroutePresent, RerouteHold,
RerouteRun, RerouteAnnounce, `releaseOwedTurns`, RestOrder) was not re-derived line by line. Spot checks at
`EngineFollowBarrierDrainBoundTests.swift:151-158` and `EngineFollowBarrierRestOrderTests.swift:121-128` agree with it.

## Concrete changes (all optional; none required by S3-R16)

1. **Record the audit** in `docs/adr-drafts/s3f.md`. Replace "were not audited one by one … Put to the orchestrator"
   (`:6653-6655`) and the matching clause in "Not reached …" (`:9807-9808`) with the table above, one line per suite.
   This closes the open item.
2. **Pin the WaitingTarget premise** (tests only, no new production branch). At
   `EngineFollowBarrierWaitingTargetTests.swift:191-193`, add `barrier: e.followBarrier` to `afterTurn`. Before the two
   `#expect`s, add `try #require(afterTurn.barrier, "setup: the move's turn is not the follow's last (its passes are owed), so T stays queued: \(afterTurn)")`.
   - It fails if a fixture or engine change ever makes that turn the follow's last, which is the one way this reading
     becomes racy. It turns a possible flake into a deterministic setup failure.
   - It adds no `Sources` branch, so S3-R16 1(e) does not apply.
   - G3 is satisfied: it adds an assertion and removes none.
3. **Do not** add `holdAttemptTerminals()` to `runOneFollowTurn` or to the listed loops.
   - None needs it.
   - Several tests then wait for answers that need the terminals (Convergence `:148`, T2 `:74`), so a global hold would
     need a matching release before every such wait. That is new surface for no gain (S3-R16 item 3).
   - If a later cycle adds a reading of a target job's state after a follow's last turn, the pattern to copy is
     `takeOffTurns`: hold, then release with the follow-ups.

## Expected saving and C2

None: these are test-only readings. No engine turn changes, so the C2 inventory and its figures are unchanged
(`purgeWhileOwedTurns` and the others in the draft's "Step 8").

## Correctness argument

Each SAFE verdict rests on one of these:
- an attempt that cannot reach a terminal before the reading: `.hold`, no script left, a held store unit, a held slot, or
  a retry that waits for the clock and has no T20 path;
- a reading whose value does not depend on that terminal: answers, start and control logs, the event queue, the
  buckets, flags, invariants, or a holder count that is 0 whether or not the holder still exists.

The answers themselves are awaited through `EngineHarness.value(of:)`, so they are order-free. Nothing here changes an
answer, a MUST or an invariant (S3-R16 1(a) to 1(c)).

## Tests, pins and new branches

- No new production branch.
- Change 2 adds one `#require` to an existing test: no mutant needed, and both `LaneDropVisit` orders still run. The
  `#require` lives inside the sweep-first branch.
- Verify by running that test 2 of 2 in both orders, in a later gate run (not run here: the host is reserved for the
  verifiers).

## What could go wrong

- **My premise for WaitingTarget is wrong** (one turn ends v3b's passes). Then change 2 fails at once, deterministically,
  and shows the reading was racy. The fix would then be `takeOffTurns`' pattern: `holdAttemptTerminals()` before
  `runOneFollowTurn` at `:190`, released after `afterTurn`.
- **A future fixture edit breaks a SAFE premise in a listed suite:**
  - giving MoveRevalidation a second slot;
  - un-holding `bulk` before T6's or `restRejoin`'s readings;
  - scripting O's retry as `[.stage]` in a DeferBucket test that then reads O's job.
  Those premises are listed per reading above, so a reviewer can check them.

## UNCONFIRMED

- The WaitingTarget premise: that the single follow turn at `:190` does not end the follow. This is argued from the
  fixture's entry counts and `followFormatsPerTurn`; I did not run it or trace `continueFollowScans`' exact per-turn
  budget.
- That `FollowBarrier.setUp`'s default bulk executor publishes without a hold. This is inferred from
  `setUpHeldPublications` building a `SteppedBlockingExecutor(holding: false)` only in its own variant. It matters only
  to say which attempts *could* end; no SAFE verdict depends on it.
- That no T20 path re-queues C at once in `drainRemainder` and in `ClassTests:423`. This is read from the waiters' lanes
  and from `relane`'s doc (`EngineJobs.swift:281-284`). `relane`'s body was not traced line by line.
- The fixer's own Step-8 list was spot-checked, not re-audited.
- Nothing was run: no test, no repetition, and no load-dependent observation.
