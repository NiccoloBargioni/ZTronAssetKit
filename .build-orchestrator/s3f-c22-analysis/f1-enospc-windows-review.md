# Review of f1-enospc-windows.md (for S3-R28)

Independent, read-only review (CLAUDE.md P4) of `f1-enospc-windows.md` against `.worktrees/s3f` at `9aa337c`,
`s3f-c22-issues.json`, `s3f-probes-c22/`, `s3-rulings-s3f.md` and `docs/adr-drafts/s3f.md`. Nothing was built, run or
measured. Every red or green below that is not marked "measured" comes from reading the code (UNCONFIRMED), and every
cost is an estimate with its basis (G2). W-HP, W-AWAY, W-DB and W-PD are new shape names introduced here.

## Verdict: UNSOUND as a whole. The replay half is sound and can be ruled as written.

**What holds** (checked):
- The measured statuses. In the two summary logs, TS-DRAIN-JOIN `beforeEnd` is red swept first in 2/2 rounds and
  `inRead` is green in both orders; APPLY-IN-READ is red swept first in 2/2. The `path:line` citations I sampled match
  `9aa337c`.
- **The replay half.** `metInItsAttempt` is the only reader of `transferSpaceEnd` and `AttemptEnd.stamped` in Sources
  (`EngineJobs.swift:291`, `:293`). One stamp, written by both ENOSPC ends before their first await, fixes correct #1
  and T-F9. The write sites are `EngineFailures.swift:198-205`, and `EngineDispatch.swift:1259` then `:1298-1301`
  (`transition` mints no stamp between them). Dropping `stamped` from the other publication ends changes no decision:
  their verdict comes at once, so every later replay arrived after the end.
- Clause (b), with T-F7 and T-F10; the rejection of correct #2's fix, with T-F3 and W-PR; and C3 (the route adds no
  await).

**What fails:** clause (c), the end's copy per id plus `movedAway`, changes an answer in both orders (Must fix 1). The
root cause leaves out a second class, re-queues that visit-first makes and the swept-first engine loses (2). Clause (d)
keeps a red window open (3). `spaceEnd` lives past the window (4). T-F4 cannot kill B8 on the recommended fixture (5).
The clause order sends a visit's removals to (f) (6).

## Must fix

1. **(c) misdates a join made by a passed holder's revisit; this is a regression in both orders.**
   - **The premise is false.** f1 §1 says a visit-first engine joins an id "once, at the visit of the apply that mapped
     that id to J's content". That fails when the holder H is publishing at that apply: H's visit passes it
     (`EngineFollow.swift:1158-1159`), the passed id stays on H with H in `unfollowed` (`:1226-1231`), and the id moves
     only when H is revisited after H's own end (`:1160-1166`), which can be after J's end.
   - **Shape W-HP** (UNCONFIRMED). X is a prefetch interest on H, so H's I/O failure is retried, not answered. v3 maps
     zz-x to J's content while H publishes. J's ENOSPC end comes (at either end) with its read held, and H's publication
     then fails with an I/O error (verdict at once, with a backoff). v4 (fillers) is applied in J's read, and H's
     revisit moves zz-x onto J.
   - **On 9aa337c**, in both orders, D1 compares 4 with 3 and T20 re-queues J, so J's second attempt serves A and X.
     This matches visit-first, as `relane`'s own rule says (`EngineJobs.swift:346-347`, "a visit for an apply made
     since the end met the job failed").
   - **Under (c):** J's end copy maps zz-x to J and no pass moved it away. So (c) answers "met", T20 is skipped, and A
     and X get J's ENOSPC verdict at the cap. If H's own verdict deferred instead, `followAfterVerdict(H)` takes the
     same path. Both orders agree, so no order comparison catches it, and by their docs no listed control has a passed
     holder in an ENOSPC window (`barrierSkipsTheBackoff…` is an I/O end, clause (a)).
   - **D5 is misread too.** `joinWaitsForVerdict` (`EngineJobs.swift:98-114`) uses the per-id copy only for the visit
     after a verdict. For a follow's visit it relies on `bringInbound` having brought, at the boundary, the ids "an
     owed visit would move", which leaves out passed holders.
   - **Correction:** do not adopt (c) for `inFollowVisit` joins as written (see "What the ruling must add" 2). W-HP joins
     step 0, at both ends.

2. **A second cause: re-queues that visit-first makes and the swept-first engine loses.**
   - **W-AWAY.** RR-18 says "The sweep-first holder's visit moves the id to that content directly: the same answer"
     (`s3f.md:4385`). At an ENOSPC end that is false. Take correct #2's shape (or T-F5's), with v4 in the read mapping
     zz-x on to a new content U, and no v5.
     - Visit-first: v3's visit joined zz-x to T before the end. v4's pass finds T (`EngineFollow.swift:1058-1069`), and
       T's visit meets T failed with an apply since the end (`:1161-1166`) and moves zz-x to U. X's interest leaves T
       (`EngineMoves.swift:337-342`), `settleRemoval` re-lanes T (`EngineJobs.swift:424-436`), and D1 (4 against 3)
       lets T20 re-queue it: A gets `ok`, and T starts twice.
     - Swept first: H's owed visit moves zz-x straight to U, and T is never re-laned. `bringInboundOntoPublications`
       walks only jobs that are verifying or committing (`EngineFollow.swift:1342`), and the deferral's `bringInbound`
       runs under v4's copy. T's verdict comes at the cap: A gets `insufficientSpace`, and T starts once.
     - So W-AWAY is red on 9aa337c and stays red under the route, which changes only the guard. T-F4 is green only
       because of its v5.
   - **W-DB.** The deferral's `bringInbound` (`EngineFailures.swift:577-579`) reads the copy as it is after the read,
     and its walk takes every holder whose visit would move the id (`foundInbound`, `EngineFollow.swift:1407-1412`).
     Shape: an apply inside the read maps x to T, and x sorts after more than 2,048 changed entries, so the pass has not
     reached it in that turn. Swept first, x joins T after `recordDeferredVerdict` has run, so the guard's first clause
     applies and T's verdict answers X and A. Visit-first: that apply's visit met T failed, so T20 re-queued T. Red on
     9aa337c, and untouched by the route.
   - **Correction:** f1's must-say 1, "one cause", becomes two: a re-lane dated by the wrong clock, and a re-queue the
     swept-first engine never makes before the verdict. W-AWAY (at both ends) and W-DB join step 0; a red result is
     blocking (S3-R16 1(a)) and needs a route. RR-18's correction (must-say 12) also covers its "directly" sentence.

3. **(d)'s count keeps W-PD red.** W-PD is a removal, at a publication's end, of an id that was mapped away while the
   job still downloaded.
   - Swept first: v3 maps zz-b (B's interest) to U while T downloads, and T's visit is owed. T's publication begins and
     records `rerouteOnPass = {zz-b}` (`EngineDispatch.swift:1032-1040`), then fails with ENOSPC, and v4 (fillers) is
     applied in the read. T's visit sees the count at 4 against 3 (`EngineFollow.swift:1164`), moves zz-b and re-lanes
     T, and (d) gives T20: A gets `ok`, and T starts twice.
   - Visit-first moved zz-b at v3, while T downloaded, and never revisits T (nothing of T's changes at v4, and T is not
     in `unfollowed`): A gets `insufficientSpace`, and T starts once. f1's W-PR covers only ids mapped while T publishes.
   - **Correction:** (d) counts as met when the count equals the end's, or when the removed id is in the publication's
     begin set (`rerouteOnPass` while `rerouteFor == followsEnded`, snapshotted into `spaceEnd`). Add W-PD to step 0,
     and add the mutant that ignores the set.

4. **`spaceEnd` lives past the window.** f1 clears it only at the start, so it is still read after the verdict defers
   and after the verdict is given; at both points 9aa337c reads nothing, since the replay clears `attemptEnd`
   (`EngineFollow.swift:392`).
   - Example: an old-stamped visit's join waits behind J's verdict under the visit's reading (`deferBehindVerdict`,
     `:1290`; `worldStamp` returns the reading, `:282-285`). The verdict is a retry, so J waits out a backoff. Replayed
     after it, the join meets (f) with a serial ≤ `stamped`, so T20 is skipped, where 9aa337c and visit-first re-queue
     J. Here the effect is only the backoff (S3-R16 item 2), but it is a change against 9aa337c in both orders.
   - **Correction:** also clear `spaceEnd` in `recordDeferredVerdict` and in `decideSpaceFailure`. B11 cannot be ruled
     Equivalent: S3-R19 item 2 covers mutants that change only cost, and a dropped clear changes later decisions. It is
     killed by the test f1 names, or its path is shown unreachable and removed (S3-R16 1(e)).

5. **T-F4, B8 and W-lazy on the recommended fixture.** The helpers apply 2,100 leading and 2,100 later fillers on every
   apply (`FollowBarrier.fillers`, `laterFillers`), so every pass spans turns.
   - At v5, v4's pass compares v3's copy with v5's (`copy = state.applied`, `EngineFollow.swift:1041`, `:1058`), finds
     zz-x unchanged, and leaves `movedAway` empty. U's visit then joins zz-x to T, and (c) answers "met": T-F4 is red
     under the route, and B8 survives.
   - T-F4's annotation is also wrong: visit-first's T20 comes at v4 (the removal, as in 2), not at v5. W-lazy is this
     fixture's normal case, not a corner.
   - **Correction:** build T-F4 so that v4's pass reaches zz-x while v4's copy stands (for example, no filler change at
     v4), and make its lazy twin a probe. A red twin is a different answer, so it is blocking, not a residual.

6. **The clause order sends a visit's removals to (f).** If (e) is not taken, a removal made in a visit at a transfer's
   end carries the visit's reading (`:1098`) and falls to (f), which is correct #2's step 1, the very step f1 rejects.
   The removals on the holder's side in `continueInbound` (`inFollowVisit` and `bringingInbound`) are not named.
   **Correction:** (f) applies only outside a visit (`!inFollowVisit && !visitingAfterVerdict`). A removal in a visit
   uses (d) or (e), and otherwise today's count.

## Should fix

- **C2.** "Such joins are rare" is unsupported: when interests concentrate onto a job in its window, every join is such
  a join. Bound it per turn: at most 512 ids (`followIDsPerTurn`, `EngineMoves.swift:235`) × 4 interests = 2,048
  checks, each two hash lookups, about 0.1-0.3 ms a turn (estimate, at 50-150 ns a check). No listed control puts the
  target in an ENOSPC window, so record the figure as unmeasured, or add the case.
- **The `sharedApplyTurns` baseline.** 6.82 ms is from cycle 20's gate (`s3f.md:10350`); cycle 21's gate measured 7.29
  ms (onto one content) and 7.68 ms (each onto its own) (`s3f.md:10448`).
- **The hours' basis.** "01:13 to 01:56" is clock time, 43 minutes from `94aa4b5` to `75b9e45`; e1-P1's test began after
  `3bc3bf8`, at 00:24. With must-fix 1-6 the estimate is about 16-24 h: about 1-2 h for each of the four new shapes,
  and 2-4 h to redesign the join rule and kill its mutants.
- **The probe helpers** read `transferSpaceEnd` (`VerifyC22CorrectProbes.swift:251`, `:303`); the tests built from them
  must read `spaceEnd`.
- **A mutant for `spaceEnd.publication`.** Inverting it routes a removal to the wrong clause; name it in the kill table
  (T-F8 and W-PR kill it).
- **The REENTRANCY note.** If the clears move into `recordDeferredVerdict` and `decideSpaceFailure`, `spaceFailed`'s
  f-4 note (`EngineFailures.swift:566-568`) names `spaceEnd` among what the epoch check re-validates (C3).

## What the ruling must add

1. **Rule the sound parts now:** one stamp record, written by both ENOSPC ends in the end's turn before the first
   await; (f) for replays only; `transferSpaceEnd` and `AttemptEnd.stamped` removed; T-F1a, T-F1b, T-F9, the bound
   test's one-to-one `#require` change, and the kills B1-B3; clause (b), with T-F7 and T-F10; and correct #2's fix
   rejected, with T-F3 and W-PR kept as tests.
2. **Have the join rule re-analysed before it is ruled.**
   - **The candidate** (UNCONFIRMED) is D5's own rule, moved to the window's start. At an ENOSPC end with a follow owed,
     `bringInbound(J)` runs in the end's turn, as `spaceFailed` already does at the deferral. Every id the end's copy
     maps to J that an owed visit would move then joins at once, as clause (b) "met", with passed holders left out.
     Every later follow join onto J then stands for an apply made since the end, so today's count (D1) dates it right.
   - **What it settles, by code reading:** correct #2, T-F2b, T-F3, T-F5, W-AWAY, T-F4 (with T20 at v4) and W-HP. It
     needs no `movedAway`, and W-lazy goes away. It leaves the visit after a verdict on the per-id copy (T-F6), as D5
     does now, and W-DB still needs its own route.
   - **Its costs.** One walk runs in the end's turn: `inboundWalkTurns` measured 3.31-3.75 ms at 10,000
     (`s3f.md:10455`), so this turn's cost is an estimate from that figure and needs a BenchSync case. At a transfer's
     end, `continueInbound` drops the moves onto J, because `waitingTarget` (`EngineFollow.swift:1596-1597`) returns nil
     for a job with no `attemptEnd`. The transfer end therefore needs its own target predicate, which
     `integrate-rr21.md:586-587` binds (do not touch the `waitingTarget` window, do not reopen RR-14), so the ruling
     must lift those lines or route around them.
3. **Step 0** runs W-HP and W-AWAY at both ends, plus W-DB, W-PD and T-F4's lazy twin, with the fixtures above. It
   records visit-first's answers in both orders over 2 rounds, as measured results, and each one that is red is
   blocking.
4. **Removals:** (d) is met when the count equals the end's, or when the removed id is in the publication's begin set;
   (e) applies at a transfer's end if T-F8 is red; a visit's reading never dates a removal; and `continueInbound`'s
   removals on the holder's side are named.
5. **`spaceEnd`'s lifetime** runs from the end to the deferral or the verdict, and it is also cleared at the start. B11
   is killed by a test.
6. **Corrected amendments.** f1's must-say 1 and 12 are corrected as in Must fix 2, and the hours as above.
