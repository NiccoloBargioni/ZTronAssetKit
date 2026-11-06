# f1c review: routes A (J-E2) and B (drain markers), adversarial (P4)

Status: complete. Read-only review of `.worktrees/s3f` at `9aa337c`. Nothing was built, tested or run.
- **Statuses.** Every red or green below is by code reading and UNCONFIRMED, except "m" (f1's measured runs, `f1-enospc-windows.md:142-144`). Every cost or hour figure is an estimate (G2). Paths are under `Sources/ZTronAssetSync/Engine/` unless given in full.
- **Cells** read VF order / SF in-read / SF late (N23.6). G is one of VF's answers, G* one of VF's timing-dependent answers (§7), R none of them, "?" not traced. The VF reference is the measured `.followVisitedFirst` run (N23.5).
- **Process.** Route A reports one forbidden `cd` (`f1c-route-a.md:7`); its content does not depend on it. This reviewer designed route Q (§3), so Q needs its own P4 check before it binds (MF10).

## 0. Verdicts in brief

- **Route A: UNSOUND.** It decides at SF's own instants (hooks inside `reroute`, `addInterest`, `dropInterest`; the close), where neither VF's re-lane trigger nor VF's lane holds. Three new shapes regress against 9aa337c in the VF order (W-PART, W-LASTUSER, and W-FIRSTUSER or W-FIRSTJOIN by where the hook sits). The W-LANE family and W-REL-ORDER stay red under "keep it blocking". Fixing them needs a per-token VF lane decided in serial order, which is B's N and B's markers: the result is no longer A.
- **Route B: UNSOUND.** Deferring J at E strands the ids a window apply maps off J (W-STRAND) and blinds RR-14's walk (RR14-OFF, a regression). B3's diff misses a passed holder's revisit (the W-HP family, an in-read regression). "No new key" contradicts the bucket invariant. N is undefined without an end marker, and no input updates it. Fixing them removes B's deferral at E and imports A's VF positions: the result is no longer B.
- **Choice: merged, "route Q".** 9aa337c's real moves, its deferral at R, RR-14's walk and its verdict code stay; only T20 of a job in its ENOSPC window changes. That T20 is decided on N (VF's J as (token, id, lane), built with A §1.4's position rules), at queue markers in serial order (B's idea), at VF's own re-lane triggers with the lane after the change. By code reading Q gives one of VF's answers for every listed shape except §6's open ones (UNCONFIRMED; not yet checked independently).

## 1. Route A: findings

- **A-1 W-PART (new), a regression, R/R/R.** §1.5(a) makes every move off J a re-lane. VF's visit re-lanes J for a move off only when the token's interest on J is left empty: `move` removes the id with `removeAsset`, which keeps the interest and its lane count (`EngineState.swift:950-952`), re-routes it, and calls `removeInterest` only if the interest is empty (`EngineFollow.swift:1265-1270`; `continueMove`, `EngineMoves.swift:332-342`). Only `dropInterest` reaches `relane` (`EngineJobs.swift:409-435`).
  - Shape: J (either end) holds user A (zz-a) and prefetch group P (zz-p1, zz-p2); in J's read v4 maps zz-p1 to U. VF: no re-lane; A and P's zz-p2 `insufficientSpace`, zz-p1 U's answer, 1 start. 9aa337c: G/G/G. A: re-lane, T20 on A's lane, 2 starts.
- **A-2 W-LASTUSER (new), a regression, R/R/G.** A reads T20's conditions "at the hook" (§1.5), and H1 runs inside `reroute` (`EngineDispatch.swift:1203`), before `move`'s `removeInterest`, so J's lane still counts the leaving token.
  - Shape: X (zz-x) is J's only user-lane interest, the rest prefetch; v4 maps zz-x to U. VF: `relane` after the removal reads `after = job.lane` = prefetch (`EngineJobs.swift:308-309`): no T20, the verdict. A: `userInitiated` at the hook: T20. Late is G, because the close reads the conditions after the take-off.
- **A-3 W-FIRSTUSER / W-FIRSTJOIN (new).** J's interests all prefetch; user X is moved onto J at v4 (W-FIRSTUSER) or joins directly at s > S (W-FIRSTJOIN, T-F1b's twin). VF: the join's `relane` reads the user lane: T20.
  - A reads the lane before or after the join depending on where H1 sits in `reroute` (its join is `addInterest` at `EngineDispatch.swift:1244`) and H2 in `addInterest`; A places neither. Before: R/R/G; after: G/G/G. No place inside `reroute` serves A-2 and A-3 at once, since the removal comes after `reroute` returns.
- **A-4 The W-LANE family is not timing.** A leaves W-LANE R in-read, W-LANE-rev and W-LANE-3 R late (A §9.1), relying on N23.6's classing of corner (iii) (`f1b-join-rule.md:232-233`). VF's answer there is fixed by the inputs' order (withdrawal before or after the crossing apply), not by VF's internal timing, and "keep it blocking" covers a removal meeting J in its read. So the family blocks, and A has no route (A §9.1: "its cost is not estimated").
- **A-5 W-REL-ORDER (new), R in SF.** A group release acts on arrival (`releaseEntryGroup`, `EngineCommands.swift:1606-1619`); a withdrawal waits instead (`:176-186`).
  - Shape: J's interests all prefetch; X, a user-lane group (`performRegisterGroup(_:lane:)`, `:198-206`), holds zz-x on H; behind the barrier v4 maps zz-x to J; X is released at s > σ_4 in the read. VF: v4's visit moves X onto J: T20. A: H3 finds VF's crossing but reads T20's lane at the hook from SF's J, which never held X: no T20. 9aa337c: G/R/R.
- **A-6 The diff is a new `followOwed` source.** A §1.3 keeps `followOwed` true for up to five turns per window apply at 10,000 entries (A §6). `followOwed` feeds `followBarrier` and `defersToFollow` (`EngineFollow.swift:82-104`), so every input defers then, and the reads that `integrate-rr21.md:561` protects, plus `bringInbound`'s guard, see a follow where 9aa337c sees none. `:560` names owed re-routes, so this is outside its letter but not its intent: it needs a ruling, and Q does without it.
- **A-7 The close's lookup is not costed.** The close evaluates every crossing id's pairs on their holder now; the state has no id-to-holder index (`holdings(of:)` is per job, `EngineState.swift:1008`; `boundContent` and `pending` are other maps, `:287`, `:1343`). So each close walks every job: about +1-2 ms at 10,000 held ids, on top of A's 8.5-10.5 ms (A §6).
- **What only a probe decides:** A's "in VF order each hook sees the real path" (A §2), which A-2 and A-3 contradict.

## 2. Route B: findings

- **B-1 The W-HP family, an in-read regression, G/R/R (tag h).** B3 adds only ids a layer's diff maps onto J's content; a publishing holder's revisit at a_H + 1 moves an id that c_E already mapped to J, so it is in no diff. B8 covers only holder visits replayed before J's end marker. So `followAfterVerdict(H)` joins X under a marked layer, B6a buckets it, and no marker decides T20: the verdict. 9aa337c in-read is G (the count at H's revisit is not the end's). Shapes: W-HP at both ends, W-HP-d, W-HP-d0, the review's W-HP-late (H's end before R), W-TWO's leg on Y.
- **B-2 W-STRAND: the deferral at E strands ids, R in SF (tag s).** B1 defers J at E, so the follow's visit of J moves only its reroute set (`rerouteOnVisit`, `EngineFollow.swift:1156`, `:1160-1167`): `rerouteOnPass` when `rerouteFor == followsEnded`, otherwise ∅, always ∅ at a transfer end.
  - B2.4 then clears `deferredAfter`, so `movesAfterVerdict` is false (`:571-573`) and `followAfterVerdict` returns at once (`:867-870`); `movedBefore` came from c_E; B5's lists hold no window-removed id. An id a window apply maps off J stays on SF's J and rides J's verdict or second attempt, where VF moved it. B6a's "a move off J happens" assumes a move the code does not make. 9aa337c's late arm avoids this by taking `movedBefore` from the copy at R.
  - Shapes: T-F4 corrected, T-F8c and W-PD-back2 when the id is not in J's begin set, T-F10b, W-PR, K19's shape, W-AWAY ×2, AV-away, AV-off, W-JOIN-OFF, W-PART, W-LASTUSER, RR14-OFF.
- **B-3 RR14-OFF (new), a regression, G/R/R.** RR-14's walk runs before each adoption (`EngineCatchUp.swift:221-223`) and filters each holder by `rerouteOnVisit` (`EngineFollow.swift:1408-1412`), so a J deferred at E hides its ids from it.
  - Shape: transfer-end J holds prefetch A (zz-a) and prefetch X (zz-x); in J's read v4 maps zz-x to publishing U's content, then v5 to W's, both behind the barrier. VF: X moves onto U at v4 and is passed at v5: U's bytes. 9aa337c: the walk at v5's adoption finds zz-x on undeferred J under c_4: G/G/G. B: X gets J's verdict (B-2) or W's bytes, never U's. B's open W-ONOFF-PUB partly comes from this mechanism.
- **B-4 The key contradiction (tag k).** `appendLayer` returns an exit verdict's `verdictKey`, and `layerOwedReroutes` pins the events before it (`EngineFollow.swift:1807-1821`, `:715-721`); the drain pulls a bucket when the event with its key replays (`:208`, `:232`); `invariantViolations` wants exactly one waiting keyed event per non-empty bucket (`EngineCommands.swift:2248-2253`, `:2282-2286`).
  - B6a buckets window joins before R while only `.spaceEnd` waits. Keyed, `.spaceEnd` releases the bucket at the end marker and, late, waits beside `.spaceFailure` with the same key (2). Unkeyed, the bucket has no keyed event in the read (0), and W-JOIN-OFF's claimed pin has no waiting verdict to come from. B1's "No new key" settles neither. In-read rows that bucket a join hit the clause as written: T-F2b, T-F3, W-DB, W-JOIN-HOP, W-FIRSTUSER.
- **B-5 N is undefined, then stale (tag n).** N is set only at the end marker's replay (B2.3), which the VF order never has, yet B6 reads J's lane from N "when J's window is open"; B §2 says B6 "is today's T20" there, which B6 does not say. No input or replay changes N, so W-FIRSTJOIN reads N without the join (R in SF) and W-LANE reads N with the withdrawn waiter (R in-read). N is "J's interests ∪ offBy", an id set, so W-PART's last-id test has no token; B3's "each change runs the arm VF's visit runs" needs (token, id, lane).
- **B-6 W-REL-ORDER, R in SF.** A release on arrival is decided before v4's waiting marker, which then lists zz-x's pairs from SF's state, where X is gone: no T20. B6's direct path also reads N before B2 sets it (W-REL-OFF: "?").
- **B-7 Out of class, and C2.** The K19 fix changes `recordDeferredVerdict` for every deferred exit (`EngineFollow.swift:504`, `EngineFailures.swift:577`), with no shapes or kills for the others. B4's in-read "bring J to N_R" may move up to 10,000 ids in R's turn with no batch bound (B5 has 512), yet B §6 counts R's turn as lighter.
- **B-8 The unmarked-layer rule fails across turns.** B6a lets the real follow decide T20 for a layer adopted while nothing waits. A follow spans turns (`followApplied` runs only the first, `EngineFollow.swift:70-77`; 512 ids a turn, `EngineMoves.swift:235`). W-ONOFF-home-0 (new): with nothing waiting, v4 changes over 512 entries, zz-x among them from H onto J, and v5 maps zz-x back before the held follow-ups run; the lazy pass skips VF's move: R in SF (9aa337c too).
- **Kept from B in Q:** markers in the drain's queue as the decision instants; T20 under the marker's stamp, which the origin gate reads (`decisionNow()`, `EngineOriginGate.swift:80-82`); the arm per change; the batch rule; K-6's liveness clause.

## 3. The choice: route Q, its parts in order

- **Q0. Before code.** Step 0 on 9aa337c (§8) and an independent P4 check of Q (MF10). Q changes nothing for a job outside an ENOSPC window.
- **Q1. Data.** `Job.spaceWindow`: epoch, E, S, end kind; c_E (a retained reference); begin (`rerouteOnPass` iff `rerouteFor == followsEnded` at a publication end, else ∅); N = `[token: (lane, ids)]`; parked = `[(token, id): holder]`. From A §1.4(b)-(c): `Job.publication: (began, ended?)` and `InboundMove.found`. Events `.windowApply(J, epoch, before: c_{k-1}, after: c_k)` and `.windowInput(J, epoch, pairs)`, neither with a `verdictKey`. Retired: `metInItsAttempt`, `transferSpaceEnd`, `AttemptEnd.stamped`, with A §3's one-to-one edits.
- **Q2. Open in E's turn, before the first await** (transfer end in place of `EngineFailures.swift:201-202`; publication end after `recordPublicationEnd`, `EngineDispatch.swift:1259`, before `:1300`). One walk builds N and parked from SF's state and c_E, by A §1.4:
  - J's pairs minus M (`begin ∩ away`; every away id at a transfer end);
  - pairs on G ≠ J that c_E maps to J's content and G's VF visit moved by E (G not passing at E, or a_G < E);
  - pending moves onto J found ≤ E;
  - pairs G passes at E (a_G ≥ E or still publishing) go to parked.
- **Q3. `relane`'s failed arm returns for a job with an open window**, for every caller (`EngineJobs.swift:326-327`). T20 of that job comes only from Q5-Q6, through the T20 block factored out of `:360-364`.
- **Q4. Markers.** `adoptApplied` enqueues `.windowApply` for each open window at every apply adopted before J's read returns (k ≤ A_R), in both orders. While `defersToFollow` holds, an on-arrival removal (`releaseEntryGroup`, purges, run ends) that touches N or a parked pair enqueues `.windowInput` with the pairs it removed. Both end their drain batch. Events queued before E need no marker: their serial s ≤ S makes them pre-end (A §1.5(c)).
- **Q5. Replays, in queue order, each under its own stamp.**
  - **`.windowApply` is VF's visit at k on N.** Off: a pair on N whose id c_k maps off J's content leaves; if all of N leaves, VF supersedes J (`EngineFollow.swift:1249-1261`) and no re-lane follows. Onto: an id the diff c_{k-1} → c_k maps onto J's content joins, pair by pair, unless its VF holder passes it at k (A §1.5(b): the parked holder, else the job of c_{k-1}'s content; it passes iff its publication covers k; no SF job does not pass). Revisits: a parked pair whose holder's end count a_h < k moves by c_k.
  - **Parked upkeep and enumeration.** A parked pair whose interest is gone (a commit answered it) leaves parked; one whose holder was superseded takes SF's new holder. Pairs come from SF's interests, the joins waiting in `joinsBehindVerdicts`, and the pairs held by `.windowInput` markers behind this one.
  - **Queued events.** A join, removal, replay or batch with s > S applies its VF change at s (A §1.5(c): a join on its own entry's content; a hop joins that content and later markers carry it on); with s ≤ S, its VF position at E (A §1.4(d)) with no T20. A `.windowInput` removes its pairs.
  - **The trigger.** A join always re-lanes (except `addInterest`'s `wasReleasedOnly` path, `EngineJobs.swift:188-197`); a removal re-lanes only when the token's last id on J leaves (A-1). T20 iff N's lane after the change is `userInitiated`, the disposition is not `.untilEntryChanges`, and `originAdmitsUser()` holds under the event's stamp.
- **Q6. At once.** With `defersToFollow` false, an on-arrival removal changes N and decides T20 in its own turn.
- **Q7. The read.** At R, a J no longer failed gets `decideSpaceFailure` at once, with no deferral (f1b review must-fix 9). Otherwise today's code: `recordDeferredVerdict`, `.spaceFailure` and `bringInbound` at R (`EngineFailures.swift:573-581`), and the replay as today (`EngineFollow.swift:383-396`), whose `decideSpaceFailure` writes only `lastError` for a re-queued J (`EngineFailures.swift:591-596`).
- **Q8. D5 for an ENOSPC-deferred J** (A §1.8): a follow visit's join goes in at once iff the copy at R maps the id to J's content (W-PEND-LATE).
- **Q9. Clears and clauses.** Cleared at T20, at the decision, at the start (`EngineDispatch.swift:739-743`), at shutdown, and at removal or supersession. Clauses beside `EngineCommands.swift:2300`: a window only on a `failed(.nextRun)` job at its epoch; markers only for an open window at their epoch, none after J's `.spaceFailure`; a waiting marker implies an owed follow or a drain follow-up scheduled or held (B's K-6); **K-N**: with no follow owed, no event waiting and J not deferred, N equals J's real (token, id) pairs.

## 4. Must fix (binding on Q's fixer)

- **MF1.** T20 of a job in its window is decided only on N, at VF's trigger, with the lane after the change (A-1, A-2, A-3, B-5).
- **MF2.** Serial order: a marker for every window apply in both orders, and an input marker for an on-arrival removal behind the barrier that keeps its pairs visible to earlier markers (A-4, A-5, B-6, B-8).
- **MF3.** Passed holders by A §1.4(b) (a_G ≥ E), with parked pairs revisited at a_G + 1; B3's diff alone is not enough (B-1).
- **MF4.** No deferral, R1 or `movedBefore` at E, and no change to `recordDeferredVerdict` (B-2, B-3, B-7). The deferral at R and the `.spaceFailure` replay stay today's code.
- **MF5.** No new `followOwed` source; RR-14, `bringInbound`'s guard, `waitingTarget` and `replayJoin` unchanged (A-6; `integrate-rr21.md:560-561`, `:586-587` not lifted).
- **MF6.** Markers carry no `verdictKey`: no bucket, pin or bucket-clause change (B-4).
- **MF7.** At R, a J no longer failed is decided at once, with no deferral; markers only for k ≤ A_R.
- **MF8.** D5 at an ENOSPC-deferred J as A §1.8.
- **MF9.** The C2 cases are measured before the logic depends on them (§8); a marker over 10 ms is split into steps of ≤ 2,048 entries a turn, each its own batch.
- **MF10.** Q binds only after an independent P4 check (by an agent that wrote none of A, B or this review) and step 0's table (N23.1).

## 5. Per-shape table

Tags for B: s = B-2, h = B-1, k = B-4, n = B-5. A finding number (A-1 …) marks this review's own finding; other A and B cells are the routes' own claims. Where A and B disagree about 9aa337c, the cell shows both.

| Shape | VF's answer | 9aa337c | A | B | Q |
|---|---|---|---|---|---|
| T-F1a (correct #1) | A, X, V `insufficientSpace`; 1 start | G/R m/G | G/G/G | G/G/G | G/G/G (V pre-end, s ≤ S) |
| T-F1b | all `ok`; 2 starts | G/G m/R | G/G/G | G/G/G | G/G/G (join at s > S) |
| T-F2a (correct #2) | A, X `insufficientSpace`; 1 start | G/R m/G | G/G/G | G/G/G | G/G/G (X on N at E) |
| T-F2b, T-F3 | T20 | G/G/R | G/G/G | G/G/G k | G/G/G (onto at v4) |
| T-F2c | as T-F2a | G/R (A) or G (B)/G | G/G/G | G/G/G | G/G/G (Q3 inert) |
| T-F4 corrected | T20 at v4; U's start count timing | G/G/R | G/G/G | G/R/R s | G/G/G (off at v4) |
| T-F4 lazy twin | T20 at v4; X timing (§7) | G/G (luck)/R | G/G*/G* | G/G*/G* | G/G*/G* |
| T-F5, T-F7, T-F9, W-PD | the verdict | G/R/G | G/G/G | G/G/G | G/G/G |
| T-F6 | Vx, Vy `insufficientSpace` | G/R/G | G/G/G | G/G/G | G/G/G (a_G < E) |
| T-F8 | A `insufficientSpace`, B U's bytes | G/R/G | G/G/G | G/G/G | G/G/G (zz-b ∈ M) |
| T-F8c | T20 at zz-c | G/G/R | G/G/G | G/R/R s (zz-c ∉ begin) | G/G/G |
| T-F10 | X `insufficientSpace` (passed) | G/G/G | G/G/G | G/G/G | G/G/G (no window apply) |
| T-F10b | T20 at v4's revisit | G/G/R | G/G/G | G/R/R s | G/G/G |
| W-PR | T20: A `ok`, B U's bytes | G/G/R | G/G/G | G/R/R s | G/G/G (passed id off at E + 1) |
| W-PD-back | T20 | G/G/R | G/G/G | G/G/G | G/G/G |
| W-PD-back2 | T20; 2 starts | G/G/R | G/G/G | G/R/R s (id ∉ begin) | G/G/G |
| K19's shape | T20 at v4 | G/G/R | G/G/G | G/R/R s | G/G/G (begin reads `rerouteFor`) |
| W-HP (both ends), W-HP-d, W-HP-d0 | T20 at a_H + 1 | G/G/R | G/G/G | G/R/R h | G/G/G (parked, revisit) |
| W-HP-late, H's end before R | T20 | G/G/R | G/G/G | G/R/R h | G/G/G |
| W-HP-late, H's end after R | X meets J's verdict | G/G/G | G/G/G | G/G/G | G/G/G (no marker after R) |
| W-AWAY, both ends | T20 at v4: A `ok` | G/R/R | G/G/G | G/R/R s | G/G/G |
| W-DB, W-DB-off, corner (i) | T20 | G/G (A) or R (B)/R | G/G/G | G/G/G k | G/G/G (moves past caps inert) |
| corner (ii) | met | G/G (R with v4 fillers)/G | G/G/G | G/G/G | G/G/G (found ≤ E) |
| corner (iii): W-LANE, -rev, -3 | by the inputs' order | as A §9.1 | G/R/G, G/G/R, G/G-or-R/R (A-4) | W-LANE G/R/R n; others G | G/G/G (markers in order) |
| corner (iv) | moot | – | – | – | – (the read's code unchanged) |
| W-BACK, both ends | T20 at v4 | G/R/R | G/G/G | G/G/G | G/G/G (U: no SF job) |
| W-BACK-PUB | timing (§7) | G/G*/G* | G/G*/G* | G/G*/G* | G/G*/G* |
| AV-away | T20 at v4 | G/G (luck, A) or R (B)/R | G/G/G | G/R/R s | G/G/G |
| AV-off | T20 at v4 | G/R/R | G/G/G | G/R/R s | G/G/G |
| W-ONOFF, W-ONOFF-home | T20 at v4 | G/R/R | G/G/G | G/G/G | G/G/G |
| W-ONOFF-home-0 (new, B-8) | T20 at v4 | G/R/R | G/G/G | G/R/R | G/G/G (marker always) |
| W-JOIN-HOP, transfer / publication end | T20 | G/G/R, G/R/R | G/G/G | G/G/G k | G/G/G (hop's content, then v4) |
| W-JOIN-OFF | T20 | G/R/R | G/G/G | G/R/R k s | G/G/G (pre-end on N, off at v4) |
| multi-change lazy | timing (§7) | G*/G*/R | G*/G*/G* | G*/G*/G* | G*/G*/G* |
| T-B11, second attempt | T20 | G/G/G | G/G/G | G/G/G | G/G/G |
| W-WD | T20 (A remains) | G/G/R | G/G/G | G/G/G | G/G/G |
| W-REL-OFF | T20 at the release | G/G/R | G/G/G | G/?/? n | G/G/G (input marker) |
| W-PEND-LATE | A, X `insufficientSpace` | G/G/R | G/G/G (tail §6) | G/G/G | G/G/G (Q8; tail §6) |
| W-NEST | timing (§7) | G/G*/R | G/G*/G* | ? | G/G*/G* |
| W-AFTER | X meets J's verdict | G/G/G | G/G/G | G/G/G | G/G/G |
| W-TWO | T20 for J and for Y | G/G/R | G/G/G | G/R/R h s | G/G/G (one N per window) |
| W-OBO | by path | ? | open | ? | open (§6) |
| W-REL, W-TGT (B's) | T20 at the input; no target | G/G/G | G/G/G | G/G/G | G/G/G |
| W-ONOFF-PUB (B's) | the holder passes the id | ? | not listed (G by 5b) | open | G/G/G (counts; RR-14 kept) |
| W-PART (new, A-1) | A, P's zz-p2 `insufficientSpace`; 1 start | G/G/G | R/R/R | G/R/R s n | G/G/G (last-id rule) |
| W-LASTUSER (new, A-2) | no T20; X gets U's answer | G/G/G | R/R/G | G/R/R s | G/G/G (lane after) |
| W-FIRSTUSER (new, A-3) | T20 | G/G/R | R/R/G or G/G/G (H1's place) | G/G/G k | G/G/G |
| W-FIRSTJOIN (new, A-3) | T20; 2 starts | G/G/R | R/R/G or G/G/G (H2's place) | G/R/R n | G/G/G |
| RR14-OFF (new, B-3) | A `insufficientSpace`; X U's bytes | G/G/G | G/G/G | G/R/R | G/G/G (no deferral at E) |
| W-REL-ORDER (new, A-5, B-6) | T20 at v4 | G/R/R | G or R/R/R | G/R/R | G/G/G (input marker) |

## 6. Shapes Q leaves open

1. **W-OBO** (A §9.2). `begin ∩ away` misplaces an id VF moved off publishing J and back before the end, since SF's begin set is fixed at the begin. A route would update it at each re-join while J publishes. Probed at step 0; a red is blocking with no route yet.
2. **W-PEND-LATE's tail** (A §9.3): whether T2's visit after its move lands comes before J's replay in every order of the follow's steps. Probe.
3. **The holder-state approximation** (A §9.4). Passing is read from SF's job of the content; VF's holder may have no SF job (Q: does not pass) or a later attempt. W-BACK-PUB and W-NEST are its timing instances (§7); other instances are not traced.
4. **W-SUPER** (new, not traced): VF's visit moves all of N at k while SF's J keeps ids. Q follows VF's supersede rule (no re-lane), but SF's J may still give a verdict for ids VF moved. Probe.
5. **`lastError`'s figures** (A §9.5): read at the replay for a deferred J, as 9aa337c does; equal to VF's unless another read or admission changes the room. Not an answer unless the ruling makes it one.
6. **Out of class** (backlog): W-HOP-DEFERRED and W-PROMO (B §10), W-PEND-LATE's non-ENOSPC twin (A §9.6).

## 7. Timing-dependent shapes (N21's reading)

| Shape | The VF timing that selects | VF's answers | Q gives |
|---|---|---|---|
| Multi-change lazy (X in T-F4's lazy twin) | whether VF's U completes before v5's visit | U first: X gets U's bytes; else X rides T's second attempt; T20 at v4 either way | T20 at v4's marker; X rides T's second attempt (SF starts no U) |
| W-BACK-PUB | whether VF's U is downloading or publishing at v4 | downloading: T20, A `ok`, 2 starts; publishing: no T20, A `insufficientSpace` | T20 (U has no SF job, so it does not pass) |
| W-NEST | VF's G at v5: downloading, or publishing or done | T20; or no T20 and X gets G's bytes | G's SF counts if G has an SF job, else T20 |
| T-F4 corrected | whether U's attempt ends before v4's visit | U's start count only (N23.2) | recorded, not asserted |

Not timing under Q: the W-LANE family (corner (iii)) and W-REL-ORDER, whose VF answer follows the inputs' order, as Q's markers do. N23.6's classing of corner (iii) is moot under Q; under A it is all that keeps A's family from blocking (A-4).

## 8. C2, C3, G4, and what step 0 decides

- **C2 (estimates).**
  - E's turn: one walk over J's pairs and the held pairs whose c_E entry is J's content, about 1-3 ms at 10,000 (basis: B's `away` scan about 1 ms; `inboundWalkTurns` 3.31-3.75 ms with moves, `docs/adr-drafts/s3f.md:10455`).
  - A `.windowApply` replay: |N| lookups (about 1 ms), the diff (about 1 ms) and a walk of the jobs' interests for the diff's ids (about 1-2 ms), so 3-4 ms in its own batch; stepped at ≤ 2,048 entries if a case passes 10 ms. A `.windowInput` for a 10,000-id release holds its pairs by reference; its replay is about 1 ms. The adoption's turn gains an O(1) append per open window.
  - Memory: N and parked about 0.3-0.6 MB each at 10,000; the copies are shared.
  - New BenchSync cases: `spaceWindowOpenTurns` (both ends), `spaceWindowApplyTurns` (10,000 entries onto J), `spaceWindowInputTurns` (a 10,000-id release). Re-measure `sharedApplyTurns` (7.29/7.68 ms, `:10448`), `drainVerdictTurns` (`:10450`), `publicationApplyTurns` and `inboundWalkTurns`. K-N is test-only (it walks N).
- **C3.** Q adds no await. f-2 (`EngineFailures.swift:205-206`): the window is written before it; after it, the lifecycle and epoch are re-checked as today. f-4 (`:566-569`): after it, "is J still failed?" picks Q7's branch; nothing captured before the await is used. Marker replays are synchronous turns that re-check the epoch.
- **G4.** Kills are 2/2, by an answer, a start count or a clause:
  - Q2: `∩ away` / begin dropped → W-PD-back2 / W-PD; a_G > E → W-HP-d0; `found` dropped → T-F7.
  - Q3: failed arm active in the window → T-F2a in-read (start count).
  - Q4: apply marker only under `defersToFollow` → W-ONOFF-home-0; input marker dropped → W-REL-ORDER; markers after R → W-AFTER.
  - Q5: last-id rule dropped → W-PART; lane read before the change → W-FIRSTUSER, W-LASTUSER; parked revisit dropped → W-HP; no-SF-job holder passes → W-BACK; T20 for pre-end events → T-F1a (start count); supersede re-lanes → a clause, or W-SUPER's probe.
  - Q7: defer when not failed → T-F2c (`lastError`). Q8: D5 unchanged → W-PEND-LATE. Q9: each clear → T-B11's second attempt, through the clauses.
  - K-N kills, by clause, the mutants that break N's upkeep in the VF order. A mutant that never queues markers and decides at the visit may be equivalent in the VF order, where the marker replays inside `applyHeld`'s await; it is killed in SF.
- **Step 0 decides.** It runs every §5 row on 9aa337c in 2 orders × 2 drain timings × 2 rounds against the measured VF run (N23.5), with this review's 7 new shapes (W-PART, W-LASTUSER, W-FIRSTUSER, W-FIRSTJOIN, RR14-OFF, W-REL-ORDER, W-ONOFF-home-0). A 9aa337c cell that measures other than predicted goes to the orchestrator's comparison (N23.1); a measured VF answer replaces any prediction here. Q's own cells are checked by the fixer's red-first commit and K-N.

## 9. Hours (estimates)

- **By part:** step 0 for 52 rows 8-12 h; Q1-Q2 (record, walk, `Job.publication`, `InboundMove.found`) 6-9 h; Q3-Q4 (markers, placement, clears) 6-9 h; Q5's virtual visit 6-9 h; Q5-Q6 (events and inputs on N, pre-end rule) 4-6 h; Q7-Q8 2-4 h; kills and clauses with K-N 6-9 h; BenchSync 3-4 h; tests, docs, retirements, ledger 3-5 h.
- **Total: about 44-67 h,** plus about 3-5 h for the P4 check of Q. Basis: A §8 and B §8's per-part figures, the f1 review's 1-2 h per new shape, and cycle 22's e1 pace. A part over 1.5 times its upper figure is a stop (N22 2(e)).

## What the ruling must say

1. **The route.** Item 1b takes route Q (§3). 9aa337c's real moves, its deferral at R, RR-14's walk and its verdict code stay; only T20 of a job in its ENOSPC window changes. A and B are not adopted as written; A's position rules (§1.4, §1.8) and B's queue markers are.
2. **The window** opens in E's turn, before the first await, at both ends. It holds N, VF's J as (token, id, lane), and the parked pairs, built by one walk with A §1.4 (M = `begin ∩ away` with `rerouteFor`; passed holders by `Job.publication`, a_G ≥ E; pending moves by `found`). `metInItsAttempt`, `transferSpaceEnd` and `AttemptEnd.stamped` are retired one to one.
3. **T20.** `relane`'s failed arm returns for a job with an open window, for every caller. Its T20 comes only from VF's changes to N, at VF's own trigger: a join always; a removal only for the token's last id; none when all of N leaves. The lane is the one after the change, and the origin gate is read under the event's stamp.
4. **Serial order.** Every apply adopted while the window is open and before R gets a `.windowApply` marker, in both orders. An on-arrival removal behind the barrier gets an input marker that keeps its pairs visible to earlier markers. Queued events with s ≤ S are pre-end. Markers carry no `verdictKey`.
5. **The apply marker** is VF's visit at k on N: off by c_k; onto by the diff unless the VF holder passes at k (publication counts; no SF job does not pass); parked pairs revisited at a_G + 1; answered parked pairs leave.
6. **Unchanged.** No deferral, R1 or `movedBefore` at E; no change to `recordDeferredVerdict`, `followOwed`'s sources, RR-14, `bringInbound`'s guard, `waitingTarget` or `replayJoin` (`integrate-rr21.md:560-561`, `:586-587` stand). At R a J no longer failed is decided at once. D5 is extended at an ENOSPC-deferred J as A §1.8.
7. **Corner (iii).** Under "keep it blocking", the W-LANE family and W-REL-ORDER are input-order shapes, not timing: N23.6's classing of corner (iii) is withdrawn for item 1b.
8. **Step 0** runs every §5 row, with the 7 new shapes, on 9aa337c in 2 orders × 2 drain timings × 2 rounds against the measured VF run. The orchestrator compares it with §5 before Q binds; a contradiction is a stop (N22 2(c), N23.1).
9. **P4.** Q binds only after an independent check of §3 by an agent that wrote none of A, B or this review. A red it finds with no route is blocking.
10. **Timing shapes (§7):** the multi-change lazy shape, W-BACK-PUB, W-NEST and T-F4's U start count match with one of VF's recorded answers; start-count-only differences do not block (N23.2).
11. **Open shapes.** W-OBO, W-PEND-LATE's tail, W-SUPER and the holder-state approximation are probed at step 0; a red one is blocking with no route yet. W-HOP-DEFERRED, W-PROMO and W-PEND-LATE's non-ENOSPC twin go to the backlog.
12. **C2 and G4.** The three new BenchSync cases and the re-measures run first (N22); one actor turn is ≤ 10 ms at 10,000; a marker over it is stepped at ≤ 2,048 entries, and a miss after that is blocking (S3-R16 1(f)). Each Q branch is killed 2/2 by an answer, a start count or a clause (§8), K-N included. About 44-67 h (estimate).
