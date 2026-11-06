# Review of f2-flake.md (cycle 22 correct #3), for S3-R28

I am an independent reader (P4) and did not write f2. This review is read-only, at wp/s3f `9aa337c`, and every path:line
is at that commit. `DBT` = `Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierDeferBucketTests.swift`.
**I built, ran and measured nothing (G2).** Every figure is the cycle-22 correctness verifier's (`s3f-probes-c22/`)
or is labelled as an estimate with its basis.

## Verdict: CORRECTED

The mechanism, the class (S3-R16 1(d), not 1(a)) and the fix (`holdRetry: true` at DBT:763) stand. f2's correction of
the finding (:763, not :762) is right. But the ruling would copy three things that are wrong (Must fix 1-3). Once they
are corrected, I found no state where the route gives an answer different from visit-first's, or breaks a MUST, an
invariant, C3, C2 or G4. The attempts are listed below.

**Confirmed against the code and the logs** (every f2 citation resolves at 9aa337c):
- Inputs: DBT:115, :123, :136, :151. `retryLater` sets `failed(.at)` and the heap entry (`EngineFailures.swift:268-271`);
  the interactive base is 0.25 s (`SyncTuning.swift:40-47`); the set-up read `failed(.at(1023044292ns))`, 1 request.
- v4: `addInterest` :127; the bucket guard :137 needs `attemptEnd.deferredAfter`; `relane` :196, `.failed` arm :326;
  `metInItsAttempt` :290-291 compares `appliesFollowed` with nil, so false; T20 :360-363. `attemptEnd` is cleared at
  each start (`EngineDispatch.swift:742-743`) and set only by a deferred or a publication end (`EngineFollow.swift:531`,
  `:565`), so a timeout's verdict on arrival leaves it nil.
- The pump is refused under `followBarrier` (`EngineFollow.swift:97-99`, `EngineDispatch.swift:95-107`). A turn that
  moves ids pumps (`EngineFollow.swift:139-141`), which behind the barrier sets `pumpWaitsForFollow`. The last turn
  clears the order (:145) and pumps (:154-156). So O is `.downloading` with 11 interests in the turn that makes
  `applyHeld`'s wait true. Swept first, `defersFailure` sets `failed(.nextRun)` while O's verdict waits
  (`EngineFollow.swift:497`): the probe's "failed(.nextRun) interests 1".
- Shutdown's first turn sets `shuttingDown` (`EngineLifecycle.swift:490`). In `settle`'s argument (:498) it takes
  `waiters` (`EngineShutdown.swift:61-62`) and the job table (:101-102). `resolveAll` fixes every answer in its own
  turn (`EngineJobs.swift:715-720`). So no success is decided after that turn, and one decided before it is delivered.
- `answeredFromStore` (`EngineDispatch.swift:791`) cannot answer O: no copy of O's bytes is ever stored. With
  `holdRetry: true`, nothing can serve O before the shutdown.
- The logs match: the probe quotes; loads 128-132 at the race probe and {21.05, 95.01, 81.74} at sync3's end; 6/6 in
  3.2 s; Sync runs of 393-595 s; 44 `.failure(.shutDown)` in 17 files; `4783403`.
- T-PURGE and T-FL: T20 re-queues O at v4's barrier end in both, by code reading, as f2 says (zz-o's user waiter keeps
  O's lane user, `EngineJobs.swift:308-309`). In T-FL, v4 (DBT:657) and v5 (:662) come before C's 429 (:673), so
  "started before the 429" (DBT:616, :702-703) stays true.

**Attempts to break the route (each failed):**
1. *Answer.* Every view answers shutDown ×11. Visited first with the retry held, O parks at its second hold
   (`RecordingFakes.swift:629-637`). A visit-first engine at the same instant holds the same parked retry. Swept
   first, the joins wait behind the held follow.
2. *MUST or invariant (R-SYN-15, no hang).* Every driver path ends: `cancelRunningHandles` when the handle is stored
   (`EngineShutdown.swift:158-162`, then `RecordingFakes.swift:156-158`); the guard after the store read
   (`EngineDispatch.swift:796-798`); the cancel after `remote.transfer` (:817-839); the loop's exit (:852). Shutdown
   then joins the driver (`EngineLifecycle.swift:500-507`). f2 cites only the first path.
3. *C3 and C2.* There is no production change, and nothing is added inside an actor.
4. *G4.* The assertions stay. The premise check adds a kill: with T20 dropped, O stays `failed(.at)` and the check fails.
5. *A coupling f2 misses.* f1's route rewrites `metInItsAttempt` (`f1-enospc-windows.md` §3 step 2). Its case (a),
   "no `spaceEnd`: false", keeps T20 for this timeout. So the premise holds after f1 only if f1 is built as written
   (ruling add 1).

## Must fix

1. **The list of doc corrections misses T-FL's own lines.**
   - *Evidence.* Two lines make the claim that f2 corrects at DBT:95 and :534:
     - DBT:611: "(visited first it started at the verdict's arrival)";
     - DBT:681-682: "starts unthrottled: at the verdict's arrival visited first".

     f2 §1 attributes T-FL's claim only to `s3f.md:5526-5527`, and both R2 and ruling item 5 omit the two lines.
   - *Correction.* Add DBT:611 and DBT:681-682 to R2 and to ruling item 5. Leave DBT:616 and :702-703 as they are.
2. **The premise check is a wait, not a check.**
   - *Evidence.* R2 says the check "mirrors DBT:766-769" but specifies `awaitCondition`; DBT:766-769 is a
     `readForTests` and a `try #require`. An `awaitCondition` asserts nothing: if T20 stopped firing, the test would
     wait to its 3-minute limit. A time-out is a hang guard, which S3-R12 rule 2 reads by load; an assertion failure is
     not (the finding: "These are assertion failures, not a hang guard"). So a real regression could pass as a margin
     on a loaded host. S3-R25 item 7 asks for "a bounded check, not a time limit" for this reason
     (`s3-rulings-s3f.md:376`). By f2's own mechanism the read is deterministic: O is `.downloading` from the follow's
     last turn, and the held retry keeps it there. The verifier read "O downloading interests 11" in 3/3 rounds.
   - *Correction.* Visited first only, after DBT:765: read O's state and `interests.count` in one `readForTests`, and
     `try #require` `.downloading` and `count + 1`. Put it in A-T-SD, not in `deferBucketApplyV4`, where A-T1's
     unheld retry (DBT:314) would race it as this flake did.
3. **The residual's probe pair is wrong (ruling item 7).**
   - *Evidence.* A-T-SD with the retry held answers shutDown in both orders (6/6), and A-T1 serves 20 B in both orders
     (DBT:330, :336). Together they show agreement on each side of the race (f2 §1, point 2), not the difference. The
     difference: visited first, the T20 retry can serve the joins before a shutdown that, swept first with the follow
     still owed, finds them unanswered.
   - *Correction.* The probe is R1 (visited first, serve forced first: ok(20 B) ×11; the verifier's `serve=true` arm,
     2/2, printed but not asserted) beside A-T-SD's swept-first arm (shutDown ×11, behind 4, 3/3). Record R1's figures
     and that R1 is not committed. State the residual generally: a shutdown inside the barrier answers shutDown to
     every answer that waits for the drain. Note `EngineFollowBarrierTests.swift:1315` ("Shutdown has no visit-first
     counterpart"), which this record qualifies.

## Should fix

1. **The text of 1(d).** S3-R16 1(d) reads "any test that fails in any run" (`s3-rulings-s3f.md:158`). "A test that
   races its own set-up" is the cause, not the clause. Write both.
2. **"Sleeps or clock moves (C4)".** C4 forbids real sleeps and time that is not injected. Moving the injected
   `ManualTimeSource` is how these tests drive time (DBT:125-127, :140-144, `deferBucketFinish`). Forbid clock moves
   here for the real reason: they fire O's backoff alarm and other timers, and they put nothing in order against the
   shutdown.
3. **DBT:94-95 needs a condition, not a flat "at v4's barrier end".**
   - `deferBucketSetUp` also accepts `oByGroup: true` with `.group` wanters. O's lane then stays prefetch, and no T20
     fires (`EngineJobs.swift:308-309`, :360).
   - Suggested wording: "visited first it starts at v4's barrier end when v4's joins leave O user-initiated (T20);
     otherwise it starts at its backoff alarm, when the test drives the clock".
4. **"Never asserted" (R2's last bullet) is inaccurate.**
   - Round 1's interleaving, with O verifying at the shutdown, was asserted each time it occurred, and it passed. Say
     "asserted only at random".
   - Cite a test that shuts down during a publication deterministically, such as
     `EngineFollowBarrierSharedMoveTests.swift:354`, whose swept-first arm requires shutDown (:357-360). Otherwise,
     record that no test covers `EngineDispatch.swift:1078-1080`.
5. **The 6/6 covers only the answers.** The held probe asserts neither the tables nor the invariants
   (`VerifyC22CorrectProbes.swift:536-551`). R3 will be the first run to show DBT:777 and :779 with the retry held.
6. **The reason the tolerant tests are safe.**
   - "Neither test can fail on its answer" is wrong in two places:
     - `EngineFollowBarrierTests.swift:1369` requires A's answer to be exactly shutDown;
     - SharedMove's tolerant arm still fails on any other error case (:366-367).
   - The right reason is that neither test races a retry that has been served:
     - FollowBarrier :1318 runs swept first only, with the follow held (its doc, :1312-1315);
     - SharedMove's visited-first arm tolerates the race by design.
7. **The estimate.**
   - `--quick` does have a basis. It runs the Sync bundle, which the verifier measured at 393-595 s, plus six more
     bundles. So it takes about 10-15 min (estimate).
   - On its own, the item then costs about 2-3 h, not 1.5-2.5 h.
   - If the 3 Sync runs and `--quick` are the cycle's shared close runs, the item's own share is about 1-1.5 h
     (estimate, from f2's own lines). Say which one is meant.
8. **What 30 iterations prove.** The unfixed test passed 8/8 when run alone (the finding). So 30 green iterations on a
   quiet host cannot tell the fixed test from the unfixed one. The evidence is R1, the construction, and the bundle
   runs with their loads. Say so, so that a green 30× is not read as proof.
9. **Record the set-up change one to one in the draft.** Give the old value `holdRetry: false`, the new value `true`,
   the cause (T20, `EngineJobs.swift:360-363`) and why no scenario is lost. S3-R16 item 4 asks this of an assertion
   change, but ruling item 3 does not ask it of this change.

## What the ruling must add

1. **The order against f1.**
   - Land A-T-SD's change on its own commit, before f1's rewrite of `metInItsAttempt`.
   - Re-run A-T-SD in both orders on f1's last commit.
   - A premise failure there is a T20 regression in f1's case (a): fix the code, not the test.
2. **The premise check is an assertion,** in the form Must fix 2 gives, and in A-T-SD only.
3. **The full doc list:**
   - DBT:94-95, worded conditionally (Should fix 3);
   - DBT:533-535, :611, :681-682 and :756-758;
   - `s3f.md:5526-5527`.

   Afterwards, a grep of the Sync tests for "verdict's arrival" finds no claim that a retry starts there.
4. **The residual,** with Must fix 3's probe pair and its figures. Record it under "Residual risks (S3-R16)" as
   non-blocking (S3-R16 item 2).
5. **The close names its evidence:**
   - R1 red, by construction;
   - R3 green, with DBT:777-786 all passing in both orders;
   - the bundle runs, with their load samples.

   The runs of 30 iterations are a regression check only.
