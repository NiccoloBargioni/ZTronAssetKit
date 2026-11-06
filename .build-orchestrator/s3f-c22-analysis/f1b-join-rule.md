# f1b: the join rule for a job in an ENOSPC window (for S3-R28)

This is a read-only analysis of `.worktrees/s3f` at `9aa337c` (checked with `git rev-parse`). Nothing was built, tested
or run. Every status comes from code reading and is UNCONFIRMED. The only exception is "measured", which quotes f1's
runs (`f1-enospc-windows.md:143-145`). Every cost and hour figure is an estimate with its basis (G2). Paths are under
`Sources/ZTronAssetSync/Engine/` unless given in full. "VF" means visit-first's answers, and "SF" means the swept-first
order. New names: W-DB-off, W-BACK, W-HP-d, W-HP-d0, T-F2c, T-F8c, W-PD-back, T-B11; open: W-HP-late, AV-away, W-ONOFF.

## 0. The answer in brief

- **No single clock dates every re-lane, so the rule ("J-E") dates each kind by its own instant:** replays by the
  stamp (f1's half, as written); walked moves by when the walk found them; the visit after a verdict by its holder's
  deferral plus the end's copy; removals by the end's copy or the publication's begin set. Every other follow join is
  "met J failed".
- **This needs every join VF made before the end to exist by the end's turn.** The review's candidate R1 gives that:
  `bringInbound(J)` at both ENOSPC ends, in the end's turn.
- **R1 alone falls short.** It turns T-F4's lazy twin (green by D1's luck) red, the candidate's per-id copy turns
  W-HP-d red, and neither makes the re-queues VF makes at applies inside the read that SF's lazy passes never make
  (W-DB-off, W-BACK).
- **J-E adds the holder's deferral instant and a window close.** At the read's return, the close keeps the copies
  adopted since the end ("layers"). It gives VF's one T20 if a layer moved an id VF had on J off J's content, or moved
  an id VF had moved off J back onto it.
- **With layers, every listed shape gives VF's answers in both orders** (code reading). Five shapes found while tracing
  stay open (§7).

## 1. The rule (J-E)

1. **Record.** `Job.spaceEnd: SpaceEnd?` = {`applies` (`appliesFollowed`), `stamped` (`stampsMinted`), `copy`
   (`state.applied`, CoW), `begin`, `held` (`job.assets`, CoW), `layers: [ValidatedManifest]`}.
   - `begin` is nil at a transfer end. At a publication end it is `rerouteOnPass` if `rerouteFor == followsEnded`, else
     `[]` (`EngineDispatch.swift:1033-1040`).
   - Both ends write the record in the end's turn, before the first await, and J joins a new
     `EngineState.spaceWindows`. The transfer end writes it in place of `transferSpaceEnd = applies`
     (`EngineFailures.swift:199-202`). The publication end writes it at the top of the `.noSpace`/`.insufficientSpace`
     arm (`EngineDispatch.swift:1298-1301`), in the turn of `recordPublicationEnd` (`:1259`).
   - `Job.transferSpaceEnd` (`EngineState.swift:867`) and `AttemptEnd.stamped` (`EngineFollow.swift:530`, `:2017-2022`)
     are removed, as the review's must-add 1 rules.
   - The record is cleared, and J leaves `spaceWindows`, at the start (`EngineDispatch.swift:742-743`), in
     `recordDeferredVerdict` (`EngineFollow.swift:543`), in `decideSpaceFailure` (`EngineFailures.swift:586`), and when J
     leaves `state.jobs`. The f-4 note (`EngineFailures.swift:566-568`) names it (C3).
2. **R1.** `bringInbound(J)` runs right after the write, in the same turn (`EngineFollow.swift:1316-1322`), with its
   guard unchanged.
   - At a transfer end its moves would be dropped. `waitingTarget(_ move:)` (`:1579-1584`) falls through to
     `waitingTarget(_:epoch:)`, which returns nil for `.failed` with no `attemptEnd` (`:1596-1597`).
   - The fix is one clause in `waitingTarget(_ move:)` only: same epoch, `.failed`, `spaceEnd != nil`. The pin and
     `waitingTarget(_:epoch:)` do not change.
3. **Instants.**
   - `InboundMove` (`EngineState.swift:705-719`) gets `found`, the value of `appliesFollowed` when `findInbound` appends
     the move (`EngineFollow.swift:1389`). `continueInbound` sets `bringingInbound = move.found` (`:1525`), and
     `EngineState.swift:105` becomes `UInt64?`.
   - `visitingAfterVerdict` becomes the holder's `deferredAfter`, a `UInt64?` (`EngineState.swift:110`). It is taken
     before `attemptEnd = nil` (`EngineFollow.swift:390-392`, and the `.attemptFailed` twin reaching `:905`), set at
     `:872`, and carried in `VisitRemainder` (`:1115`). `joinWaitsForVerdict` reads `!= nil` (`EngineJobs.swift:109-113`).
4. **`relane` is told what re-lanes** (f1's step 2). `addInterest` (`EngineJobs.swift:196`) passes the id joined.
   `settleRemoval` (`:435`), `continueMove` (`EngineMoves.swift:357`) and purge (`EngineCommands.swift:1056`) pass the id
   removed. `metInItsAttempt(job, change)` (`EngineJobs.swift:289-297`) then decides for a job with no `deferredAfter`.
   The guard's first clause (`:327`) does not change.
   - **(a)** No `spaceEnd`: false, so T20.
   - **(f)** Outside a visit (`!inFollowVisit && visitingAfterVerdict == nil`): `reading.serial <= spaceEnd.stamped`.
     With no reading: false.
   - **Joins.** **(b)** A walked move (`bringingInbound = found`): `found <= spaceEnd.applies`. **(AV)** The visit after
     a verdict (`visitingAfterVerdict = d`): `d < spaceEnd.applies`, and `spaceEnd.copy` maps the id to J's content.
     **(o)** Any other visit join: false.
   - **Removals in a visit** (the holder's side of `continueInbound` included): met at a transfer end iff `copy` maps
     the id elsewhere or not at all, at a publication end iff the id is in `begin`; else false.
5. **The deferral (W-DB).** `spaceFailed`'s defer branch (`EngineFailures.swift:573-581`) runs the window close, then
   `bringInbound(J)`, then a `guard` that J is still `.failed` at its epoch (else return), then `recordDeferredVerdict`
   and `deferToFollow`. The walk after the record (`:579`) is removed.
6. **The window close.** `adoptApplied` (`EngineJobs.swift:1224`) appends the new copy to `layers` for each job in
   `spaceWindows`.
   - It runs at the read's return in `spaceFailed`, after its guard (`:570-572`), in both branches, when `layers` is
     non-empty and J is still `.failed`.
   - **M, the ids moved off:** the ids in `held` that `copy` maps elsewhere (transfer end), or `begin ∩ held`
     (publication end).
   - **N, the ids on J:** J's ids now, plus those of J's pending moves with `found <= applies`, minus M.
   - If a layer maps an id of N off J's content, or an id of M onto it, VF's visit at that apply re-laned J while it was
     failed. J then gets T20's re-queue, on T20's own conditions (`EngineJobs.swift:360-364`), and no verdict.

**Why each clock (code reading).**
- **(f)** The reading is the arrival that VF processed.
- **(b)** A move stands for the visit whose walk found it. A move found by the end means VF joined J while it ran, even
  when the move is left past `inboundMovesNow` or `inboundIDsNow` (`EngineMoves.swift:239-241`) and made after an
  apply (T-F2c).
- **(AV)** The visit after Y's verdict stands for the applies after Y deferred (`movesAfterVerdict`,
  `EngineFollow.swift:571-573`). VF revisits Y at d+1, which comes before J's end iff `d < applies`. The end's copy shows
  whether the id was mapped to J by then.
- **(o)** After R1, every id that the end's copy maps to J, and that an owed visit would move, is on J or pending with
  `found <= applies`. A later follow join is therefore a passed holder's revisit (`EngineFollow.swift:1158-1159`,
  `:51-57`), or an id mapped since the end. Either way it comes at an apply after the end, where VF met J failed.
- **Removals** A downloading job is never passed (`:1173-1174`), and a publishing job is passed except for its begin set
  (`EngineDispatch.swift:1029-1036`).
- **The close** A lazy pass compares with the copy as it stands when the pass runs (`EngineFollow.swift:1041`,
  `:1058-1069`), so it misses a change that a later apply reverts.

## 2. Per-shape traces (VF in both orders; J-E holds in both orders)

| Shape | VF | 9aa337c | J-E path | J-E |
|---|---|---|---|---|
| correct #1 = T-F1a | A, X, V `insufficientSpace`; 1 start | red SF (measured 2/2) | replay (f): serial ≤ `stamped`, now written at the transfer end | green |
| T-F1b | all `ok`; 2 starts | green (measured) | (f): serial > `stamped`, so T20 | green |
| correct #2 = T-F2a | A, X `insufficientSpace`; 1 start | red SF (measured 2/2) | R1 brings zz-x in the end's turn: (b) 3 ≤ 3. v4 (fillers) moves neither zz-a nor zz-x | green |
| T-F2b | all `ok`; 2 starts | green | the end's copy does not map zz-x to T, so R1 skips it. v4's join (H's visit, or the deferral walk at found 4) is (o) or (b) false, so T20 | green |
| T-F3 | T20 at zz-y; all `ok`; 2 starts | green | zz-x via R1 is met; zz-y via v4 is not, so T20 | green |
| T-F4 (pass reaches zz-x under v4) | T20 at v4 (removal) | green | R1 brings zz-x. v4's visit of T (4 ≠ 3) moves it to U. It is neither mapped elsewhere by the end's copy nor in `begin`, so T20 | green |
| T-F4 lazy twin | T20 at v4 | green by D1's luck (H joins zz-x at 5 ≠ 3) | R1 brings zz-x. The pass compares v3 with v5 and sees no change. The close: v4 maps zz-x (in N) to U, so T20 | green; red without layers |
| T-F5 (W3) | A, X `insufficientSpace`; 1 start | red SF | R1 at the transfer end, kept by the target clause: (b) 3 ≤ 3 | green |
| T-F6 (W4) | Vx, Vy `insufficientSpace` | red SF | (AV): the holder deferred before X's end, and the end's copy maps the ids to X | green |
| T-F7 (W5) | A, X `insufficientSpace` | red SF | the begin walk's move, made after the end with v4 in: (b) found ≤ 3 | green |
| T-F8 (W-TR) | A `insufficientSpace`, B U's bytes; 1 start | red SF | T's visit removes zz-b, which the end's copy maps to U: met. The close: v4 does not map zz-b back | green |
| T-F9 | A `insufficientSpace` | red SF | (f) on the withdrawal's replay | green |
| T-F10 | X `insufficientSpace` | green | (b): the begin walk found it before the end | green |
| W-PR | T20 at v4's revisit: A `ok`, B U's bytes | green | T's revisit (D3, 4 ≠ 3) removes zz-b, which is not in `begin`, so T20 | green |
| W-PD | A `insufficientSpace`; 1 start | red (review) | zz-b ∈ `begin`: met. The close: v4 maps neither zz-b back nor zz-a away | green |
| W-HP, publication end (H's verdict at once) | T20 at v4's revisit of H: A, X `ok` | green | R1 skips H (passed). At v4, H's revisit or the deferral walk joins zz-x: (o), or (b) 4 > 3, so T20 | green |
| W-HP, transfer end | as above | green | as above | green |
| W-HP-d (H defers after J's end; the follow ends in J's read; the visit after H's verdict joins zz-x) | T20 | green (the visit branch's count) | (AV): d ≥ the end, so T20 | green; red under the candidate |
| W-AWAY, publication end | T20 at v4 (removal): A `ok`; 2 starts | red (review) | R1 brings zz-x; T's visit at v4 removes it, so T20 (or the close, if the pass is lazy) | green |
| W-AWAY, transfer end | as above | red (review) | as above, with the target clause | green |
| W-DB | T20 (v4's visit met T failed) | red (review) | the deferral walk runs before the record and joins x at found 4 > 3, so T20 | green |
| W-DB-off (new: v4 maps an id on T to U, behind 2,048 changed entries) | T20 at v4 | red: T's visit runs after the deferral and passes T (`EngineFollow.swift:1164-1167`) | the close: v4 maps an id of N off T, so T20 | green |
| W-BACK (new, both ends: zz-b mapped to U before the end, while T downloads or before `begin`; T's visit still owed; v4 maps zz-b back) | T20 at v4 (re-join) | red: T's visit under v4's copy finds zz-b at home, so nothing re-lanes T | the close: v4 maps an id of M onto T, so T20 | green |

## 3. Tests red first

- **Step 0 on 9aa337c** runs every row of §2, the new tests below, and the shapes of §7 as probes. Each runs in both
  orders (`LaneDropVisit`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift:783-787`), 2 rounds, measured, and
  asserts VF's answers and T's start count.
- **The red ones** go in one failing commit (P3). The fix then lands in order (record, R1, joins, removals, deferral,
  close), and each step is green in both orders before the next.
- **Fixtures** (in `Tests/ZTronAssetSyncTests/Engine/`): holds by `applyHeld` (`EngineFollowBarrierReachTests.swift:19-32`),
  `holdPublication` (`EngineFollowBarrierAnswerTests.swift:61`) and `releasing` (`EngineFollowBarrierRerouteFixture.swift:157`);
  laziness by `fillers`/`laterFillers` (`EngineFollowBarrierTests.swift:91`, `EngineFollowBarrierAnswerTests.swift:19`).
  T-F4 has no filler change at v4 (review must-fix 5) and its lazy twin keeps them; W-DB and W-DB-off sort over 2,048
  changed entries before the id; W-BACK and T-F4 hold U's transfer.
- **New tests:**
  - T-F2c, correct #2 with more than 64 holders onto T, kills K11;
  - T-F8c, T-F8 plus zz-c mapped to V at v4 (T's visit carries v3's stamp), kills K5 for removals;
  - W-HP-d0, with H deferring at J's end count and then one apply in J's read, kills K14;
  - W-PD-back kills K19. zz-b is in a begin set whose follow ended and re-routed it; it is mapped back while T
    publishes, then off at v4;
  - T-B11 is the review's must-fix 4 example, an old-stamped join replayed after J's retry verdict, giving T20. It also
    has a second-attempt variant.
- **Changed tests:** the bound test's `#require` reads `spaceEnd?.stamped` for `attemptEnd?.stamped`
  (`EngineFollowBarrierReroutePinSpaceTests.swift:106-107`), one to one; tests built from the probe helpers read
  `spaceEnd` (the helpers read `transferSpaceEnd`, `VerifyC22CorrectProbes.swift:251`, `:303`). R1 moves the join of
  `barrierGivesAnENOSPCsVerdictAtTheCapAfterTheFollowsJoinInItsRead` (`EngineFollowBarrierSpaceReadTests.swift:35`)
  into the end's turn; its `#require` near `:89` still holds.
- **Controls, green in both orders:** e1-P1's three (`EngineFollowBarrierReroutePinSpaceTests.swift:160`, `:174`, the
  pin test), e1-P2's two (`EngineFollowBarrierAfterVerdictSpaceTests.swift:158`, `:169`), the `…InItsRead` cases,
  `barrierSkipsTheBackoffForAVisitAfterAPublicationsEnd` (`:189`) and the Sync bundle.

## 4. Branches and kills (2/2, in each order that reaches the branch)

| K | Branch | Mutant | Killed by |
|---|---|---|---|
| K1 / K2 | the transfer / publication end writes `spaceEnd` | dropped | T-F1a, T-F5 / T-F2a, W-PD |
| K3 | (f) `<=` | `<` | `userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict` (`:160`) |
| K4 | (f) | forced false / forced true | T-F1a, T-F9 / T-F1b, `:174` |
| K5 | (f) only outside a visit | (f) first, in visits too | T-F3 (joins), T-F8c (removals) |
| K6 / K7 | R1 at the transfer / publication end | dropped | T-F5, W-AWAY (transfer) / T-F2a, W-AWAY (publication) |
| K8 | the transfer clause in `waitingTarget(_ move:)` | dropped | T-F5 |
| K9 | (b) | dropped (falls to (o)) | T-F2a, T-F7, T-F10 |
| K10 | (b) `<=` | `<` | T-F2a, T-F5 (found equals the end's count) |
| K11 | (b) | the count now (9aa337c's D1) | T-F7, T-F2c |
| K12 | (AV) | the per-id copy only (the candidate) | W-HP-d |
| K13 | (AV) | forced false | T-F6, `:158` |
| K14 | (AV) `<` | `<=` | W-HP-d0 |
| K15 | (AV)'s copy check | dropped | `:169` if its holder deferred before X's end, else a twin where it does |
| K16 | (o) | D1 (met at the end's count) | none, as it is unreachable after R1 (§1): show that, or kill it (S3-R16 1(e)) |
| K17 | the removal's transfer clause | dropped / forced true | T-F8 / W-AWAY (transfer), T-F8c |
| K18 | the removal's begin-set clause | dropped / forced true | W-PD / W-PR, W-AWAY (publication) |
| K19 | `begin` needs `rerouteFor == followsEnded` | ignored | W-PD-back |
| K20 / K21 | the deferral walk before the record / the re-check after it | after it (9aa337c) / dropped | W-DB / W-DB (a verdict on a queued job), or shown unreachable |
| K22 | the window close | dropped | T-F4 lazy twin, W-DB-off, W-BACK ×2 |
| K23 / K24 | the close's "off" / "back" half | dropped | T-F4 lazy twin, W-DB-off / W-BACK ×2 |
| K25 | the close | fires on any layer | T-F5, T-F7, W-PD (v4 is fillers) |
| K26 / K27 | the clears at the deferral and verdict / at the start, with `spaceWindows` | dropped | T-B11 / its second-attempt variant. A `spaceWindows` leak alone is cost-only (S3-R19 item 2) |

## 5. C2 (estimates, except the ledger's figures)

- **The end's turn** adds one walk, plus at most 64 moves and 256 ids. Over 10,000 jobs the deferral's walk is the
  ledger's `inboundWalkTurns` 404 turn, [3.74, 3.69, 3.75] ms (`docs/adr-drafts/s3f.md:10455`). That puts the end's
  turn at about 3.5-5.5 ms (estimate). The record itself is O(1).
- **The read's return** runs the close, at (1 + L) lookups per id on J.
  - At 10,000 ids and L = 2 that is 30,000 lookups at 50-150 ns each: 1.5-4.5 ms.
  - With the walk (about 3.7 ms), the turn is about 5-9 ms (estimate).
  - At L ≥ 4 it can pass 10 ms, and the close then needs a per-turn budget with J held failed. If so, report it; do not
    tune (G1).
- **The apply's turn** adds one retain per window job, which is negligible. The read keeps up to L old copies alive, so
  the memory case (`Tests/ZTronAssetKitBenchmarks/BenchSync.swift:86-88`) is re-measured.
- **A re-lane** adds at most 2,048 checks a turn: 0.1-0.3 ms (the review's estimate).
- **New BenchSync cases**, shaped like `inboundWalkTurns` (`BenchSync.swift:607-625`), check P-9 and 10 ms, with no
  `Scripts/` edit. One covers each ENOSPC end with an owed follow over 10,000 jobs. The other covers the read's return
  with 10,000 ids and two layers.
- **Re-measure** (best of 3, quiet load): `sharedApplyTurns` 7.29 / 7.68 (`s3f.md:10448`), `concentrationFollowTurns`
  3.76 (`:10452`), `publicationApplyTurns` 4.29 (`:10453`), `inboundWalkTurns` (`:10455`) and
  `concentrationNotFoundTurns` 5.62 (`:10451`).

## 6. Ruling lines to lift or correct

1. **Lift `integrate-rr21.md:586`** (the `waitingTarget` window), for the transfer clause in `waitingTarget(_ move:)`
   only, as S3-R26 item 5(ii) did for its fix (`s3-rulings-s3f.md:557`). The pin stays untouched.
2. **Clarify S3-R26 item 5(i)** (`s3-rulings-s3f.md:553`, "not in `waitingTarget`"). T20 is still decided in `relane`'s
   failed arm; the clause only keeps R1's moves alive.
3. **Clarify `integrate-rr21.md:560`** (no InboundMove made at a site) and **`:561`** (`bringInbound`'s guard). Both bind
   owed re-routes. R1 calls the existing `bringInbound`, guard unchanged, as `spaceFailed` does
   (`EngineFailures.swift:579`).
4. **Clarify `integrate-rr21.md:587`** (RR-14). The layers' append leaves RR-14's walk, and its place before the
   adoption, as they are (`EngineCatchUp.swift:222-223`, `EngineRuns.swift:368-369`).
5. **Correct RR-18** (`s3f.md:4385-4388`, S3-R22 item 2). "directly: the same answer" and "both orders answer it with
   the verdict" are false at an ENOSPC end, where VF re-queues (W-AWAY, T-F2b, W-DB).
6. **Replace the dating texts:** `metInItsAttempt`'s doc (above `EngineJobs.swift:289`); `relane`'s comment (`:328-357`,
   "cycle 22's residual" at `:355`); the ledger's e1-P2 design (`s3f.md:7175-7187`, 75b9e45's count) and e1-P1
   residual (`:7151`); `t20-m6-no-clear`'s Equivalent argument, which names `transferSpaceEnd` (`:6511`).
7. **Replace f1's must-say 1, 3, 4, 10, 11 and 12.** These are: one cause; the per-id copy with `movedAway`;
   `continueInbound` always met; no new C2 case; W-lazy as residual; and RR-18's T20 side only.
8. **Unchanged:** D5 (`EngineJobs.swift:98-114`), D3 (`EngineFollow.swift:1154-1177`), the take-off, and S3-R16's bar.

## 7. Open shapes, and why

- **W-HP-late** (D5's site; on 9aa337c already). H's I/O end comes after J's verdict deferred; the visit after H's
  verdict joins zz-x onto J, and D5's per-id copy (`EngineJobs.swift:110-112`) lets it join at once, so J's verdict
  answers X. VF moves zz-x only at the first apply after H's end. J's window has closed: this needs D5's own analysis.
- **AV-away.** (AV) reads the end's copy, not the layers. An id on a deferred holder since before J's end, mapped off J
  at v4 and back at v5: VF removed it at v4 (T20), J-E says met. N lacks the ids VF had moved from a deferred holder.
- **W-ONOFF.** An id mapped onto J and off again in the read, under a lazy pass: VF's join re-queued J, SF never
  re-lanes it. Closing it needs the holders of each id a layer maps onto J, a per-layer scan of unknown C2 cost.
- **Multi-change lazy (timing).** In the lazy twin VF re-queues at v4 and may start U before v5. If U answers X first,
  X gets U's bytes in VF and T's second attempt in J-E. VF's answer depends on timing (f1 leaves U's count unasserted).
- **Pending-move and lane corners.** (i) W-DB-overflow: the deferral walk's moves past `inboundMovesNow`/`inboundIDsNow`
  run after the record, so the guard's first clause skips VF's T20. (ii) R1 skips an id pending onto another target
  (`EngineFollow.swift:1413`); mapped to J before the end, it later joins as (o), a false re-queue. (iii) The close
  reads the lane at the read's return, VF at the layer's apply: a user waiter withdrawn in between changes the
  decision. (iv) A transfer end whose verdict comes at once drops R1's pending moves.

## 8. Fixer hours (estimates)

Step 0 4-6 h; record, (f), removals and clears 3-4 h; R1, the clause and (b) 3-4 h; (AV) 2-3 h; the deferral 1-1.5 h;
the close 3-5 h; kills 3-5 h; BenchSync 2-3 h; docs 1-1.5 h. **Total: about 22-33 h** (estimate); without the close,
about 19-28 h. Basis: the review's 16-24 h for f1 with must-fix 1-6 (review `:121-123`) and cycle 22's e1 pace.

## What the ruling must say

1. **Replays** follow the review's must-add 1. One `Job.spaceEnd` is written by both ENOSPC ends in the end's turn,
   before the first await. Clause (f), `reading.serial <= spaceEnd.stamped`, applies outside visits only.
   `transferSpaceEnd` and `AttemptEnd.stamped` are removed. This covers T-F1a, T-F1b, T-F9 and the bound test's
   one-to-one `#require`, and kills K1-K5.
2. **There are two classes, each blocking when red** (S3-R16 1(a)): a re-lane dated by the wrong clock, and a re-queue
   VF makes that SF never makes (W-AWAY, W-DB, W-DB-off, W-BACK, the lazy twin). This replaces f1's must-say 1.
3. **R1.** `bringInbound(J)` runs in the end's turn at both ends, with its guard unchanged, plus a transfer-end clause in
   `waitingTarget(_ move:)` only. This lifts `integrate-rr21.md:586` for that clause, and clarifies `:560`, `:561`,
   `:587` and S3-R26 item 5(i).
4. **Joins in the window.** A walked move is met iff `found <= spaceEnd.applies`. The visit after a verdict is met iff
   its holder deferred before the end and the end's copy maps the id to J. Every other visit join is not met, and
   nothing is met with no `spaceEnd`. The counts of 75b9e45 and cycle 21 are retired for joins; D5 and D3 do not change.
5. **Removals in a visit**, the holder's side included, are met iff a transfer end's copy maps the id elsewhere, or the
   id is in the publication's begin set (`rerouteOnPass` while `rerouteFor == followsEnded`).
6. **The deferral.** The walk runs before `recordDeferredVerdict`, then J is re-checked as failed. The walk after the
   record is removed (W-DB).
7. **The window close.** Layers are kept from the end. The read's return gives one T20 if VF re-laned J at a layer.
   Without the close, the T-F4 lazy twin, W-DB-off and W-BACK are blocking and open, not residual.
8. **`spaceEnd`'s lifetime** runs from the end to the deferral or the verdict. It is also cleared at the start and when
   the job leaves, and `spaceWindows` follows it. T-B11 kills K26 and K27.
9. **Step 0 on 9aa337c** runs every §2 shape, the new tests and the open probes, in both orders, 2 rounds, measured.
   The red ones go in one failing commit (P3). K1-K27 are each killed 2/2, and K16 is shown unreachable or killed
   (S3-R16 1(e)).
10. **C2.** Two new BenchSync cases are run against P-9 and 10 ms, and five per-turn cases are re-measured. A read's
    return over 10 ms is reported, and the close's per-turn budget is ruled on separately (G1).
11. **Corrections:** RR-18's two sentences; `metInItsAttempt`'s doc and `relane`'s comment; the ledger's e1-P2 design,
    e1-P1 residual and `t20-m6-no-clear`; and f1's must-say 3, 4, 10, 11 and 12.
12. **The open shapes** (W-HP-late, AV-away, W-ONOFF, multi-change, and the pending-move and lane corners) are probed
    at step 0. A red one is blocking, with its own route. The ruling names whether a VF answer that depends on timing
    (multi-change) or on the lane at another instant (corner iii) counts as an answer or as timing (S3-R16 item 2).
