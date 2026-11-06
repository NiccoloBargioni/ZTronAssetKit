# f2: correct #3 of cycle 22, the flake in `shutdownClearsTheJoinsBehindAVerdict(.followVisitedFirst)`

Read-only analysis of wp/s3f at 9aa337c. Citations are path:line at 9aa337c; test paths are under
`Tests/ZTronAssetSyncTests/Engine/`, and `DBT` means `EngineFollowBarrierDeferBucketTests.swift`.
**I built, ran and measured nothing (G2).** Every figure below is either from the cycle-22 correctness verifier's logs
in `.build-orchestrator/s3f-probes-c22/`, or it is labelled as an estimate with its basis.
One small correction to the finding: the set-up call is at `DBT:763`, not :762 (:762 is `let count = 10`).

## 1. Mechanism (by code reading), and the class

**Inputs, visited first.**
- zz-o has one user waiter (`DBT:123`), and so does each of the 10 members (`DBT:136`).
- O's script is `[.hold, .fail(.timedOut), .stage(oBytes)]` (`DBT:114-115`, `holdRetry: false`), so its second
  attempt runs unheld.
- At O's release (`DBT:151`), the verdict is given on arrival. `retryLater` sets `failed(.at(now + U[0, 0.25 s]))` and
  puts the retry on the heap (`EngineFailures.swift:269-270`).
- The test never drives the manual clock after that, so the alarm never fires.
- The verifier read: "after the set-up O failed(.at(1023044292ns)) interests 1, O requests 1"
  (`correct-probeC22ShutdownBucketRace.summary.log`). So the retry had **not** started at the verdict's arrival.

**v4's follow.** `applyHeld` releases the follow's turns and waits for `!followBarrier && !drainFollowUpScheduled`
(`EngineFollowBarrierReachTests.swift:25-27`).
1. H's visit moves each member's user interest onto O's content (`addInterest`, `EngineJobs.swift:127`).
2. O's verdict did not defer, so the bucket guard (`:137`) is false and the visit calls `relane(O)` (`:196`).
3. `relane` takes its `.failed` arm (`:326`). `metInItsAttempt` is false (`:289-291`), because `attemptEnd` and
   `transferSpaceEnd` are both nil.
4. So T20 fires (`:360-363`): the lane is user, the disposition is `.at`, and the origin admits. O is queued, and its
   backoff entry is removed.
5. The pump waits while the barrier holds (`EngineDispatch.swift:95-107`).
6. The follow's last turn pumps (`EngineFollow.swift:154-156`). O's second attempt starts in that turn: `.downloading`
   (`EngineDispatch.swift:701`), with its driver spawned (`:726`). The same turn makes `applyHeld`'s wait true.

**From that turn, two chains race.**
- **(A) The test.** It resumes, makes one `readForTests` (`DBT:167`), then calls `engine.shutdown()` (`DBT:770`).
  - That is two engine hops.
  - Shutdown's first turn sets `shuttingDown` (`EngineLifecycle.swift:490`) and takes the `waiters` table
    (`EngineShutdown.swift:61-62`).
  - Those waiters are then answered `.shutDown` (`EngineLifecycle.swift:498`).
- **(B) The retry.** It runs:
  1. the driver, then `drive` (`EngineDispatch.swift:784`), with a store read at `:791`;
  2. the source's unheld `.stage` (`RecordingFakes.swift:614-620`);
  3. `publish` (`:1011`), which moves to `.verifying` (`:1022`);
  4. `store.publish` (`:1067`), then `.committing` (`:1090`);
  5. `resolveAll` (`EngineJobs.swift:721`).

  That is at least four suspensions, across the engine, the source and the store.

**The interleaving that gives the success.** (B)'s `resolveAll` turn runs before (A)'s shutdown turn. Then all 11
waiters get success (20 B), and `DBT:781` and `DBT:786` fail.
- If the shutdown comes first, success cannot happen. A shutdown during `store.publish` meets `guard self.isRunning`
  (`EngineDispatch.swift:1078-1080`), and by then the waiters have already been answered.
- The verifier saw both outcomes at a 1-minute load of 128-132:
  - round 1: "after v4 O verifying … 11 interests", then shutDown;
  - round 2: "after v4 O gone", then ok(20 B) ×11.
- sync3 ended at loads {21.05, 95.01, 81.74}.
- At low load, (A) wins: run alone, the test passed 8/8 (the finding).

**Class: S3-R16 1(d), a test that races its own set-up. It is not 1(a).**
1. The success is the engine's true answer at that instant. It is given in a turn before shutdown's first turn, and no
   success can be given after that turn. R-SYN-15 (`SPEC.md:240`) says nothing against an answer given before the
   shutdown.
2. Both orders agree on each side of the race.
   - Shutdown before the serve: shutDown in both orders, 6/6 (the verifier's PROBE-C22C-SHUTDOWN-HELD-RETRY).
   - Serve before the shutdown: success in both orders. A-T1's `timeoutUsers` (`DBT:312-337`) asserts 20 B for every
     member (`:330`) and for zz-o (`:336`).
3. The only cross-order difference is when the answer arrives. Swept first, T20 waits for the drain's replay of the
   joins behind O's verdict, so a shutdown inside the barrier finds them unanswered. That is S3-R16 item 2
   ("when an answer arrives within the barrier and its drain"), which is non-blocking. The draft records no residual
   of this kind: a grep for lines naming both "residual" and "shut" finds none.
4. What the test assumes, and why it fails. Its visited-first premise (`DBT:758`: "the members waited on O's job for
   its retry") needs the retry still pending at the shutdown. But T20 starts the retry at v4's barrier end, and
   `holdRetry: false` lets it finish.

**Doc comments that state the wrong mechanism.**
- `DBT:95` says "(visited first it starts at the verdict's arrival)". The set-up reading above contradicts it.
- `DBT:534` (T-PURGE) and `s3f.md:5526-5527` (T-FL) make the same claim.
- By code reading, not measured, T20 starts the retry at v4's barrier end in those two tests as well.
  - In T-FL, U's user join does it.
  - In T-PURGE, the prefetch group's join does it, because `isUser` reads the job's lane after the join
    (`EngineJobs.swift:308-309`), and zz-o's waiter keeps that lane user.
- Both tests hold the retry, so neither is affected. All three tests were added in `4783403`.

## 2. Route

**R1: a deterministic red reproduction (a probe, not committed).**
1. Build the committed shape: `.followVisitedFirst`, seed 2_022_781, `.timeout`, `.users`, 10 members,
   `holdRetry: false`.
2. After `deferBucketApplyV4`, force the serve first:
   `driving([b.s.time], fence: engine) { awaitCondition { $0.state.jobs[b.o.transferID] == nil } }`.
3. Shut down, and assert `DBT:781` and `DBT:786` unchanged. Every round should be red with ok(20 B).
   - The verifier's `serve=true` arm (`VerifyC22CorrectProbes.swift:502-506`) got ok(20 B) in 2/2 rounds, but it only
     printed the answers; it did not assert them.
4. Record what pins T20 as the cause: O's state and request count after the set-up (`failed(.at)`, 1 request) and
   after v4 (2 requests, 11 interests).
5. An optional control, predicted by code reading and not measured. With no user interest on O (`oByGroup: true`,
   `.group`) and no clock moves, O should stay `failed(.at)` with 1 request after v4.

**R2: the fix, in the test, as the mechanism decides.**
- At `DBT:763`, pass `holdRetry: true`. The script becomes `[.hold, .fail, .hold, .stage]` (`DBT:115`).
  - The retry then parks at its second hold (`RecordingFakes.swift:629-637`), waiting for a release that never comes.
  - Shutdown ends it, through `cancelRunningHandles` (`EngineShutdown.swift:158-162`) and the fake handle's `cancel()`
    (`RecordingFakes.swift:156-158`).
  - The verifier saw no hang: 6 rounds in 3.2 s.
- After `DBT:765`, add a visited-first set-up check that states the premise. It mirrors `DBT:766-769`:
  `awaitCondition` until O is `.downloading` with `count + 1` interests.
  - Read the engine, not `source.starts`: the driver's call to the source is a separate hop.
  - The verifier read "O downloading interests 11" in 3/3 rounds.
- Correct the doc comments at `DBT:756-758`, `DBT:94-95`, `DBT:533-535` and `s3f.md:5526-5527`.
- Under G3, nothing else changes: not the assertions at `DBT:777-786`, the seed, the ending, the wanters, the count,
  or either argument.
- Swept first is unchanged: O's second attempt never starts. The verifier read "behind 4 … O requests 1 … shutDown"
  in 3/3 rounds.
- No scenario is lost. The visited-first case becomes the one its doc describes. The "O verifying at the shutdown"
  case was never asserted; it only happened at random.

**R3: green.** The serve can no longer come before the shutdown, by construction.

**Routes the ruling should forbid:**
- an assertion that tolerates either answer, as `EngineFollowBarrierSharedMoveTests.swift:362-370` does (S3-R16 item 4);
- a prefetch-lane substitute. It drops the user-waiter scenario, and zz-o's waiter would still trigger T20;
- sleeps or clock moves (C4);
- dropping the visited-first argument.

## 3. Other tests with the same pattern

- **`deferBucketSetUp` with `.timeout` and the default `holdRetry: false`:**
  - `DBT:312-337` (A-T1, `timeoutGroup` and `timeoutUsers`): **safe, no change.**
    - Visited first, T20 starts the same unheld retry.
    - But the test waits for every answer (`deferBucketFinish`, `DBT:252-301`). `EventProbe.next` returns events
      already received (`RecordingFakes.swift:976+`).
    - It asserts only the served answers (`:330`, `:336`).
  - `DBT:720-752` (swept first only): **safe.** The follow stays held through every read.
- **Already held:**
  - `DBT:542`: T-PURGE, with `holdRetry: true` at `:544`;
  - `DBT:622`: T-FL, with an explicit held retry at `:640`.
- **A T20 re-queue racing a shutdown elsewhere: none found.** I scanned `Tests/ZTronAssetSyncTests` by regex.
  1. Every `.failure(.shutDown)`: 44 in 17 files. Only `DBT:761` has one beside an unheld transient retry.
  2. Every function with a transient failure followed by an unheld success step: 57 functions. Crossed with
     assertions after a shutdown, 7 remain. None is T20:
     - `EngineRegressionCycle16Tests.swift:129`, `:189`, `:293`, `:342` and `:402` are throttle-parked jobs: `relane`'s
       `.blocked` arm (`EngineJobs.swift:366`).
     - `EngineRegressionCycle15Tests.swift:175` and `:263` are `quiet` before the shutdown, with no driver left
       (`:156-160`).
- **The same family, tolerant by design.** Neither test can fail on its answer; leave both unchanged (G3).
  - `EngineFollowBarrierSharedMoveTests.swift:354-372`: a publication, not T20. The visited-first arm accepts
    `.success` or `.shutDown` (`:362-370`).
  - `EngineFollowBarrierTests.swift:1318`: a space re-admission, where K accepts either answer (`:1368`).
- **The scan's limits.**
  - Scripts built inside helpers were checked only where the helper returns answers after a shutdown. `sharedMove`
    (`EngineFollowBarrierSharedMoveTests.swift:107`) is the only such helper.
  - I did not scan for T20 retries racing state reads.

## 4. Estimate (fixer hours)

**About 2 h of wall-clock time (1.5-2.5 h). This is an estimate; none of it is measured.**
- The edit, the premise check, three doc comments and the draft line, with reading: ~0.5 h.
- The R1 and R3 probes, with one build: ~0.5 h. The verifier's 6-round probe took 3.2 s.
- Runs:
  - 3 debug Sync runs at the verifier's measured 393-595 s each: ~20-30 min;
  - 30 iterations per argument on the host and on the simulator, with the build and the boot: ~15-30 min;
  - `verify.sh --quick`: I have no duration for it.
- The draft's records: ~0.25-0.5 h.

## What the ruling must say

1. **The class.** Correct #3 is blocking under S3-R16 1(d): a test that races its own set-up. It is not 1(a).
   - The success is given before shutdown's first turn, which takes every waiter.
   - Both orders answer shutDown when the shutdown comes before the serve, and success when the serve comes first.
2. **The failing probe first.** Run R1: served first, with `holdRetry: false`, asserting `DBT:781` and `DBT:786`. It is
   red in every round.
   - Record O's state and its request count after the set-up and after v4.
   - The probe is not committed.
3. **The fix.** Set `holdRetry: true` at `DBT:763`. Add the visited-first set-up check: O is `.downloading` with
   `count + 1` interests before the shutdown. Nothing else in the test changes (`DBT:777-786`, seed, ending,
   wanters, count, arguments).
4. **Forbidden routes:** an assertion that accepts either answer, a prefetch-lane substitute, sleeps or clock moves,
   and dropping the visited-first argument.
5. **Doc corrections** at `DBT:756-758`, `DBT:94-95`, `DBT:533-535` and `s3f.md:5526-5527`: the retry starts by T20 at
   v4's barrier end, not at the verdict's arrival.
6. **The sweep.** The draft records §3's result. Only `DBT:763` changes. A-T1, the invariants test, T-PURGE, T-FL,
   SharedMove `:354` and FollowBarrier `:1318` stay as they are, each with its reason.
7. **The residual.** Record the timing difference of a shutdown inside the barrier under "Residual risks (S3-R16)", as
   non-blocking (item 2). Its probe is the pair A-T-SD (held) and A-T1 `timeoutUsers`.
8. **Close with:**
   - R1 red and R3 green;
   - the fixed test, 30 iterations per argument, 0 failures, on the host and on the iOS Simulator under sim.lock;
   - 3 debug Sync runs, with load samples per S3-R12 rule 1;
   - `verify.sh --quick`'s `VERIFY:` line, quoted.
