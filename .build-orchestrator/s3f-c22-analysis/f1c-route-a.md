# f1c route A: completing the dating approach (S3-R28 item 1b input)

Status: complete. Read-only analysis of `.worktrees/s3f` at `9aa337c` (`git log`); nothing was built, tested or run.
- **Statuses and figures.** Every red or green is by code reading and UNCONFIRMED, except "m" (measured), which quotes f1's runs (`f1-enospc-windows.md:142-144`); step 0's table does not exist yet (no `.worktrees/s3f/.build-s3f/c23/`). Every cost and hour figure is an estimate with its basis (G2).
- **Paths** are under `Sources/ZTronAssetSync/Engine/` unless given in full; "probes" is `.build-orchestrator/s3f-probes-c22/VerifyC22CorrectProbes.swift`.
- **Orders and timings.** VF is the reference (the measured `.followVisitedFirst` run, N23.5) and SF the swept-first run; `LaneDropVisit` (`Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift:780-787`) changes only when the follow is released, so every change runs in both. SF only (N23.6): "in-read" releases the drain inside J's read (probes `:320`, `:445`), "late" after it returns.
- **Notation.** E, S: `appliesFollowed`, `stampsMinted` at J's end (`EngineState.swift:66`, `:71`); A_R: `appliesFollowed` at the read's return R; c_k: the copy after apply k; σ_k: its stamp.
- **Process note.** One read-only `sed` in this session ran after a `cd` into the worktree's `docs/adr-drafts`, which the hard rules forbid; every other command used absolute paths.
- **New names:** J-E2, T-F10b, W-WD, W-REL-OFF, W-ONOFF-home, W-PEND-LATE, W-NEST, W-AFTER, W-TWO, W-OBO, W-LANE / -rev / -3.

## 0. The answer in brief

- **Why J-E failed.** No clock read at SF's own instant can date a re-lane: SF compresses an id's path (H→U where VF went H→J→U; never moving an id VF moved onto J and back), and it runs visits before events VF ran first. Hence J-E's reds in both classes (f1b review must-fix 2-4).
- **J-E2 dates pairs, not events.** For each (token, id) pair that can touch J while J's window is open, it builds VF's path from VF's position at J's end (SF's state plus c_E) and each window apply's entry change onto or off J's content (a "crossing", recorded when the apply lands). If that path re-laned J inside the window, J gets T20's re-queue and no verdict; otherwise its verdict stands.
- **Who evaluates.** Three hooks take every pair SF touches (re-routes, direct joins, direct removals); the decision's close takes the pairs SF never touched. `relane`'s failed arm returns for a job in its window.
- **Kept from J-E as corrected:** the record at both ends before the first await; `begin ∩ away` (must-fix 1); (f) for direct events only, a hop dated by its chain (2); the transfer-end removal rule; (b) by `found`; (AV) re-dated by the holder's end; the clears and clauses (6, 7); must-fix 9. **Dropped:** R1 (so no `integrate-rr21.md:586` lift), clause (o) (must-fix 5 has nothing left to decide), the layers, the deferral reorder.
- **Result (code reading).** Every listed shape gets one of VF's answers in both orders and both drain timings, except the W-LANE family (timing by N23.6), W-OBO and W-PEND-LATE's tail (§9). Three shapes get one of VF's timing-dependent answers (§10). So `covers_all` is false.

## 1. The route (J-E2), in order

1. **The record.** It adds `Job.spaceEnd: SpaceWindow?` and `EngineState.spaceWindows: Set<TransferID>`.
   - **Fields:** E and S; `copy` = c_E, a retained reference to `state.applied`, not a copy; `begin` (publication end: `rerouteOnPass` if `rerouteFor == followsEnded`, else ∅, `EngineDispatch.swift:1033-1040`; transfer end: nil); `crossings: [AssetID: [Crossing]]`; `paths: [PairKey: VFPosition]`; `born: [PairKey: UInt64]`; `frozenAt: UInt64?`; `owed: Bool`.
   - **Written** in the end's turn, before the first await: at a transfer end in place of `transferSpaceEnd = applies` (`EngineFailures.swift:201-202`), before f-2's await (`:205-206`); at a publication end at the top of the `.noSpace`/`.insufficientSpace` arm (`EngineDispatch.swift:1298-1299`), the turn of `recordPublicationEnd` (`:1259`), before RE-S13 (`:1300`).
   - **Removed:** `Job.transferSpaceEnd` (`EngineState.swift:867`) and `AttemptEnd.stamped` (`EngineFollow.swift:2022`, written at `:529-532`).
2. **The lifetime** (must-fix 6, 7). Open from the end. Frozen at R when the verdict defers (`frozenAt = A_R`): it takes no crossing after A_R, so it does not grow with later applies, and it is held to the decision because the late drain's moves are dated against it.
   - **Cleared** at the decision; in `transition` (`EngineJobs.swift:21`, failed bookkeeping `:88-94`) when J leaves `.failed`, T20 included; first in `decideSpaceFailure` (`EngineFailures.swift:586`), which covers a retry verdict that stays failed; at the start (`EngineDispatch.swift:741-743`); when J leaves `state.jobs`.
   - **Clauses** in `invariantViolations()` (`EngineCommands.swift:1773`, beside `:1852`): `spaceWindows` equals the jobs with a `spaceEnd`; a `spaceEnd` sits only on a `failed(.nextRun)` job; `frozenAt` and `owed` each imply `attemptEnd?.deferredAfter != nil`.
3. **Crossings.** While a window is open and not frozen, `followApplied(from: previous)` (`EngineFollow.swift:47`) queues a diff of c_{k-1} (`previous`) against c_k (`state.applied`).
   - **When it runs.** The diff is `continueFollow`'s first step, at ≤ 2,048 entries a turn. It keeps `followOwed` (`:84`) true until it is done. So it finishes before any visit, move or replay that comes after apply k, and a lazy pass that later compares an older copy with c_k finds every crossing already recorded.
   - **What it records.** One diff serves every window. For each id whose old or new entry is a window's content, it appends `Crossing(apply: k, onto:, other:)`. `other` is the content the id left (for an onto) or reached (for an off), and nil when the id is unlisted.
   - **Unchanged:** `adoptApplied` (`EngineJobs.swift:1224-1235`), and RR-14's walk before it (`EngineCatchUp.swift:222-223`, `EngineRuns.swift:368`).
4. **VF's position at the end** of a pair (t, x), for job J's window:
   - **(a) The pair is on J in SF, with no `paths` or `born` entry.** VF had it on J, unless x ∈ M.
     - M is a predicate, not a set. x ∈ M when c_E maps x elsewhere or nowhere, and either the end is a transfer end or x ∈ `begin` (`begin ∩ away`, must-fix 1).
     - An x ∉ `begin` that c_E maps away was passed by J while J published. It is on J at E and leaves at E + 1 (W-PR, K19's shape).
   - **(b) The pair is on G ≠ J in SF** (H1's source, or the close's untouched holder). VF passed x on G at E iff all of these hold:
     - G's publication began at a count ≤ E;
     - G had not ended before E: its end count a_G ≥ E, or it is still publishing;
     - x ∉ G's begin set;
     - c_E maps x away from G.

     The counts come from a new `Job.publication: (began, ended?)`. It is written beside `EngineDispatch.swift:1039-1040` and in `recordPublicationEnd`, and cleared at the start. VF then holds x on G until it revisits G at a_G + 1 and moves x by that copy, because VF gives every verdict at once (`rerouteOnVisit`'s failed arm, `EngineFollow.swift:1160-1167`). This is (AV) dated by the holder's end, not by SF's deferral d_G. Otherwise, VF had x at c_E's content.
   - **(c) A move pending onto J, found at f ≤ E.** This needs a new `InboundMove.found`, set at `EngineFollow.swift:1389` (`EngineState.swift:705-719`). VF moved x onto J at f, and (a) follows (T-F7, T-F10). A move pending onto T2 ≠ J is case (b) with G = T2.
   - **(d) A waiting join or an owed re-route item.** A waiting join is a `JoinAfterFollow` (`EngineFollow.swift:2026-2050`); an owed item comes from `layerOwedReroutes` (`:693-724`). Either is born at its own reading's serial s, on its own entry or its batch copy's entry.
     - If s ≤ S, its position at E is case (b)'s answer for the holder it was born on.
     - If s > S, it is a direct event in the window: 5(c).
   - **(e) A pair born in the window** (H2 records `born`) starts at its arrival entry, at s.
5. **VF's path in the window, and the test.** Walk the window applies k ∈ (E, min(now, A_R)] in order. c_E and x's crossings tell whether c_k maps x to J's content.
   - **(a) On J.** VF's visit at k moves x off iff c_k maps it away. J is failed and never passes; a passed id moves at E + 1. Either move is a re-lane.
   - **(b) Off J, on holder h.** VF moves x onto J at the first k where c_k maps x to J and h does not pass x at k. h passes iff its publication covers apply k (began < k ≤ ended). With no SF job for h's content, h does not pass (§10's choice). The move is a re-lane.
   - **(c) A direct event at serial s > S** is a re-lane in two cases: a join whose own entry is J's content, or a removal of a pair that VF has on J at s (VF's path up to s). This is (f) for direct events only. A replay that reaches J through a later copy is handled by (b), along its chain (must-fix 2).
   - **The test.** VF re-laned J iff some step is a re-lane. T20's own conditions (`EngineJobs.swift:360`) then decide. They are read at the hook while J is not deferred, and at the replay once it is (§9.1, K27).
6. **The hooks.** A hook fires for each open window where x ∈ crossings, or where the pair's source or target is that window's job. It costs O(L + x's crossings).
   - **H1, in `reroute`** (`EngineDispatch.swift:1203`), for every caller: visits (`EngineFollow.swift:1267`), inbound moves (`EngineMoves.swift:335`), take-offs (`EngineFollow.swift:649`, `:758`), chained replays (`:995`), owed items (`EngineDispatch.swift:1182`, `:1189`) and supersession (`:1360`). The path starts at the source holder, or at the item's own birth for a replay or a batch item.
   - **H2, in `addInterest`** (`EngineJobs.swift:127`), for a direct join or the direct path of `replayJoin`. It records `born`.
   - **H3, in `dropInterest`** (`EngineJobs.swift:409`), for withdrawals, releases, run ends and purges (`EngineCommands.swift:1056`). A visit's removal belongs to H1.
   - **After each evaluation** the hook writes `paths[pair]`, so a later one continues from it. If VF re-laned J: not deferred → `requeueMetFailed(J)` (T20's block, factored out of `EngineJobs.swift:360-364`); deferred → `owed = true`. `relane`'s failed arm (`EngineJobs.swift:327`) gains `|| job.spaceEnd != nil` and returns.
7. **The decision.** In `spaceFailed`, after its guard (`EngineFailures.swift:570-572`):
   - **J no longer failed** (a T20 in the read): call `decideSpaceFailure`, which writes lastError and returns at `:592-596`. Clear the window. No deferral (must-fix 9).
   - **`defersToFollow`:** freeze the window, then run `:573-581` unchanged. The deferral walk's moves go through H1.
   - **Otherwise, and at the `.spaceFailure` replay** after its take-off (`EngineFollow.swift:391-393`, in place of the bare call at `:394`): the close. It evaluates every crossing id's pairs that have no `paths` entry, on their holder now, and at a publication end with A_R > E also J's ids that c_E maps away and are ∉ `begin`. If `owed`, or the close finds a re-lane: `requeueMetFailed(J)`, then `decideSpaceFailure` (lastError only); else the verdict. `chargeTakeOff`, `followAfterVerdict` and `landTakeOff` stay.
8. **D5 at a frozen window** (must-fix 3; review must-add 5). This changes `joinWaitsForVerdict` (`EngineJobs.swift:109-114`).
   - For a job with a frozen window, a follow visit's join of x goes in at once iff c_{A_R} maps x to J's content. That is the test `AttemptEnd.copy` already makes for the visit after a verdict.
   - Otherwise the join waits, as today (W-PEND-LATE).
9. **Unchanged:**
   - D3 (`rerouteOnVisit`, `EngineFollow.swift:1154-1177`), the take-off (`:594-620`) and `followAfterVerdict` (`:867-878`);
   - `bringInbound` and its guard (`:1316-1322`), `waitingTarget` (`:1579-1600`), and `replayJoin`'s routing;
   - `metInItsAttempt` (`EngineJobs.swift:289-297`) keeps its visit branch for a job with no window. Its replay branch returns false, since there is no stamp.

**Why R1, (o) and the layers go.**
- R1 existed so that a follow join at the end's count stood for an apply before the end (f1b §1 "why", (o)). J-E2 dates a late SF move by its pair's VF apply instead.
- f1b's layered close (f1b §1.6) becomes §1.7's untouched-pair half. It needs no per-layer scan, because crossings are recorded as the applies land. That scan was W-ONOFF's open cost in f1b §7.

## 2. Per-shape table

Cells are VF order / SF in-read / SF late. G is VF's answer and R is not; "m" is measured, all else UNCONFIRMED; G* is one of VF's timing-dependent answers (§10). The VF column is a prediction: the measured `.followVisitedFirst` run is the reference (N23.5), so 9aa337c's VF cell is G by construction, and J-E2 keeps it G because in VF order each hook sees the real path.

| Shape | VF's answer | 9aa337c | J-E2 | J-E2's path |
|---|---|---|---|---|
| correct #1 = T-F1a | A, X, V `insufficientSpace`; 1 start | G / R m / G | G / G / G | V born s ≤ S on T (4d), no re-lane; X by H1, 4b |
| T-F1b | all `ok`; 2 starts | G / G m / R | G / G / G | H2: s > S on T's content (5c) |
| correct #2 = T-F2a | A, X `insufficientSpace`; 1 start | G / R m / G | G / G / G | H1 H→T: c_E maps zz-x to T (4b); v4 is fillers |
| T-F2b | T20: all `ok`; 2 starts | G / G / R | G / G / G | H1: zz-x at home at E, onto at v4 (5b) |
| T-F2c | as T-F2a | G / R / G | G / G / G | as T-F2a, for the moves past the caps |
| T-F3 | T20 at zz-y | G / G / R | G / G / G | zz-x on T at E, no crossing; zz-y onto at v4 |
| T-F4 (as corrected) | T20 at v4 | G / G / R | G / G / G | H1 H→U: on T at E (4b), off at v4 |
| T-F4 lazy twin | T20 at v4 | G / G (D1's luck) / R | G / G / G | H1 H→T under v5: on T at E, off at v4 |
| T-F5 (W3) | A, X `insufficientSpace` | G / R / G | G / G / G | H1: on T at E; fillers only |
| T-F6 (W4) | Vx, Vy `insufficientSpace` | G / R / G | G / G / G | 4b: a_G < E, so at c_E's content |
| T-F7 (W5) | A, X `insufficientSpace` | G / R / G | G / G / G | 4c: found ≤ E |
| T-F8 (W-TR) | A `insufficientSpace`, B U's bytes | G / R / G | G / G / G | zz-b ∈ M (transfer end) |
| T-F8c | T20 at zz-c | G / G / R | G / G / G | zz-c ∉ M, off at v4 |
| T-F9 | A `insufficientSpace` | G / R / G | G / G / G | H3: s ≤ S, before the window |
| T-F10 | X `insufficientSpace` (passed) | G / G / G | G / G / G | 4c then 4a; no window apply |
| T-F10b (new) | T20 at v4's revisit | G / G / R | G / G / G | 4c, 4a: off at E + 1 |
| W-PR | T20 at v4: A `ok`, B U's bytes | G / G / R | G / G / G | 4a: zz-b ∉ begin, off at E + 1 |
| W-PD | A `insufficientSpace`; 1 start | G / R / G | G / G / G | zz-b ∈ begin ∩ away = M |
| W-PD-back | T20 | G / G / R | G / G / G | on U in SF; 4b: c_E maps it to T; off at v4 |
| W-PD-back2 | T20; 2 starts | G / G / R | G / G / G | zz-b ∉ begin ∩ away; off at v4 |
| K19's shape (review must-fix 8) | T20 at v4 | G / G / R | G / G / G | stale begin reads ∅ (`rerouteFor`); 4a: off at E + 1 |
| W-HP, publication end | T20 at v4 | G / G / R | G / G / G | 4b: H passes at E; a_H + 1 = 4 maps zz-x to J |
| W-HP, transfer end | T20 | G / G / R | G / G / G | as above |
| W-HP-d | T20 | G / G / R | G / G / G | 4b: a_H ≥ E |
| W-HP-d0 | T20 | G / G / R | G / G / G | a_H = E: VF revisits at E + 1 |
| W-HP-late (review: H's end before R) | T20 | G / G / R | G / G / G | H1 at `followAfterVerdict(H)`, before J's replay; §1.8 |
| W-HP-late (f1b: H's end after R) | X meets J's verdict | G / G / G | G / G / G | H's move comes after the decision |
| W-AWAY, publication end | T20 at v4: A `ok` | G / R / R | G / G / G | H1 H→U: on T at E, off at v4 |
| W-AWAY, transfer end | as above | G / R / R | G / G / G | as above |
| W-DB | T20 | G / G / R | G / G / G | H1 on the deferral walk's move: onto at v4 |
| W-DB-off | T20 | G / G / R | G / G / G | H1 on the reroute-set move: off at v4 |
| corner (i), W-DB-overflow | T20 | G / G / R | G / G / G | H1 on each move past the caps |
| corner (ii) | met | G / G, R with v4 fillers / G | G / G / G | 4b with G = T2: c_E maps x to J |
| corner (iii) = W-LANE family | per sub-shape | §9.1 | §9.1 | timing by N23.6 (§10) |
| corner (iv) | moot | – | – | R1 dropped; unreachable (review) |
| W-BACK, both ends | T20 at v4 | G / R / R | G / G / G | close: zz-b ∈ M, onto from U (no SF job) |
| W-BACK-PUB | T20, or no T20 (timing) | G / G* / G* | G / G* / G* | §10 |
| AV-away | T20 at v4 | G / G (luck) / R | G / G / G | 4b: a_Y < E, so on J at E; off at v4 |
| AV-off | T20 at v4 | G / R / R | G / G / G | H1 Y→U: on J at E, off at v4 |
| W-ONOFF | T20 at v4 | G / R / R | G / G / G | H1 H→U: onto at v4 from H |
| W-ONOFF-home (new) | T20 at v4 | G / R / R | G / G / G | close: the untouched pair on H, onto at v4 |
| W-JOIN-HOP, transfer end | T20 | G / G / R | G / G / G | H1 on the chained replay: born on W, onto at v4 |
| W-JOIN-HOP, publication end | T20 | G / R / R | G / G / G | as above |
| W-JOIN-OFF | T20 | G / R / R | G / G / G | H1: born on J (4d), off at v4 |
| multi-change lazy (X's answer) | X: U's bytes, or T's 2nd attempt | G* / G* / R | G* / G* / G* | §10 |
| T-B11, and its second attempt | T20 | G / G / G | G / G / G | window cleared at the decision; failed arm as today |
| W-WD (new) | T20 (A remains) | G / G / R | G / G / G | H3: s > S, pair on J in VF |
| W-REL-OFF (new) | T20 at the release | G / G / R | G / G / G | H1 at v4's move, then H3 at the release |
| W-PEND-LATE (new) | A, X `insufficientSpace` | G / G / R | G / G / G (tail §9.3) | §1.8 at once; 4b: no re-lane |
| W-NEST (new) | T20, or no T20 (timing) | G / G* / R | G / G* / G* | §10 |
| W-AFTER (new) | X meets J's verdict | G / G / G | G / G / G | frozen at A_R; D5 waits |
| W-TWO (new) | T20 for J and for Y | G / G / R | G / G / G | each window's hooks; 4b by Y's end count |

**The new shapes.**
- **T-F10b:** T-F10 plus v4 (fillers) in the read; VF's revisit of T moves zz-x off failed T: T20.
- **W-WD:** T-F9 with the withdrawal in the read (s > S); VF re-lanes T with A still user-lane: T20.
- **W-REL-OFF:** X's group released at s1 in the read, then v4 (σ_4 > s1) maps zz-x away from T; VF's T20 is at the release (A remains). On 9aa337c late, both re-lanes meet a deferred T.
- **W-ONOFF-home:** zz-x on H; v4 maps it onto T and v5 back to H, under a lazy pass. VF moves it onto T at v4 (T20) and back at v5; SF never moves it.
- **W-PEND-LATE:** f1b's corner (ii) in the late drain. x pending onto T2, k2 ≤ E maps it to J; J defers and the walk skips pending x (`EngineFollow.swift:1413`); T2's visit then moves x onto J. D5 makes X wait behind J's verdict; VF's verdict answers X.
- **W-NEST:** x on H; v4 maps it to G's content, v5 to J's. VF moves H→G→J and G's state at v5 decides; SF moves H→J.
- **W-AFTER:** T-F2b with the onto apply after R; VF and J-E2 both have X meet J's verdict.
- **W-TWO:** two publication ENOSPC windows (Y, J), zz-x passed on Y and mapped to J, v4 inside both reads.

## 3. Tests, red first

- **Step 0 (N20, N22 item 1).** Every §2 row on `9aa337c`, both orders, both drain timings, 2 rounds, measured; each asserts VF's answers and T's start count and serves every content (S3-R27 12.2). Built from `c22TransferSpaceDrainJoin` (`:255-342`) and `c22ApplyInRead` (`:384-466`); the late drain calls `releaseFollowFollowUps()` (`:320`, `:445`) only after J's read returns. The orchestrator checks §2 against it before the route binds (N21).
- **The red ones** go in one failing commit right before the fix (N20, P3). The fix lands in this order, riskiest first (N22), each step green in both orders and timings before the next:
  1. The diff and the close's C2 cases (§6), measured before the logic depends on them.
  2. The record, the lifetime, the clauses and the removals (T-B11, and the clauses' killers).
  3. §1.4-§1.5 with H1: T-F2a/b/c, T-F3 to T-F8c, T-F10b, W-PR, W-PD*, K19's shape, W-HP*, W-AWAY, W-DB*, AV-*, W-ONOFF, W-JOIN-*, W-TWO.
  4. H2 and H3: T-F1a, T-F1b, T-F9, W-WD, W-REL-OFF.
  5. The decision, the close and must-fix 9: W-BACK ×2, W-ONOFF-home.
  6. §1.8: W-PEND-LATE.
- **New tests beyond step 0's list:** T-F10b, W-WD, W-REL-OFF, W-ONOFF-home, W-PEND-LATE, W-NEST, W-AFTER, W-TWO, and the kill twins W-ONOFF-home-b (X's request after v4, so VF has no move at v4) and K16's twin.
- **Changed one to one:** the bound test's `#require` on `attemptEnd?.stamped` (`EngineFollowBarrierReroutePinSpaceTests.swift:106-107`) reads `spaceEnd?.endStamp`; the probes' `transferSpaceEnd` reads (`:251`, `:303`) read `spaceEnd`.
- **Controls, green in both orders:** e1-P1's `:160`, `:174` and the pin test; e1-P2's `EngineFollowBarrierAfterVerdictSpaceTests.swift:158`, `:169`; `barrierGivesAnENOSPCsVerdictAtTheCapAfterTheFollowsJoinInItsRead` (`EngineFollowBarrierSpaceReadTests.swift:35`); `barrierSkipsTheBackoffForAVisitAfterAPublicationsEnd` (`:189`); the Sync bundle.

## 4. Branches and kills (2/2 in each order and timing that reaches the branch)

| K | Branch | Mutant | Killed by |
|---|---|---|---|
| K1 / K2 | the record at the transfer / publication end | dropped | T-F5 / T-F2a |
| K3 | 5c: s > S | s ≥ S | `userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict` (`:160`; its join holds the last stamp before the end, `:106-107`) |
| K4 | 5c | forced re-lane / forced none | T-F1a, T-F9 / T-F1b, `:174` |
| K5 | 5c is direct-only (a hop goes by 5b) | (f) on the event's serial for hops too | W-JOIN-HOP at a publication end, in-read |
| K6 / K7 / K8 | H1 / H2 / H3 | dropped | T-F2b, AV-off, W-JOIN-OFF / T-F1b in both timings / W-WD |
| K9 | the failed arm's `spaceEnd` return | dropped (9aa337c's dating) | T-F2a, T-F5, T-F8 |
| K10 | M at a transfer end | dropped / every held id | T-F8 / T-F8c |
| K11 | M at a publication end: `begin ∩ away` | no `∩ away` / begin dropped | W-PD-back2 / W-PD |
| K12 | begin needs `rerouteFor == followsEnded` | ignored | K19's shape |
| K13 | 4a: a passed id leaves at E + 1 | dropped | W-PR, T-F10b |
| K14 | 4b: the passed holder | dropped (always c_E) | W-HP, W-HP-d |
| K15 | 4b: a_G ≥ E | a_G > E | W-HP-d0 |
| K16 | 4b/5b: the revisit moves x by c_{a_G+1} | onto J whenever the revisit falls in the window | `:169`, with its holder ending before X's end; else its twin |
| K17 | 4c: pending onto J, found ≤ E | as 4b | T-F10b, T-F7. This is f1-B9's successor (N4); T-F10 alone has no window apply |
| K18 | 4d: a waiting join starts at its birth | starts at SF's target | W-JOIN-OFF |
| K19 | 5b: an unknown holder does not pass | it passes | W-BACK (U's transfer held) |
| K20 | the close | dropped | W-BACK ×2, W-ONOFF-home |
| K21 | the close skips pairs with `paths` | re-evaluates them from SF's holder | Equivalent unless step 0 builds a pair moved off a passing holder and left untouched with a later crossing; argue or kill (S3-R16 1(e)) |
| K22 | the freeze at A_R | no freeze | W-AFTER |
| K23 | §1.8 | D5 unchanged | W-PEND-LATE |
| K24 | must-fix 9's branch | defer anyway / return with no `decideSpaceFailure` | W-AWAY with re-queued T admitted before the drain (`lastError` sizes it, `EngineDispatch.swift:593`); else argued Equivalent |
| K25 | the clears and `spaceWindows` | each one dropped | T-B11 and its second attempt, through the §1.2 clauses (G4, must-fix 7) |
| K26 | the diff keeps the follow owed; ≤ 2,048 a turn | not owed / unbudgeted | T-F4 lazy twin in VF order / `spaceWindowApplyTurns` |
| K27 | T20's conditions read at the replay for a deferred J | read at the hook | W-LANE, late (§9.1) |
| K28 | 5b: `other` is the holder's content | J's content | W-NEST in VF order, with G publishing at v5 |

## 5. REENTRANCY rows

| Row | Site | Re-validated after the await |
|---|---|---|
| f-2 | `EngineFailures.swift:205-206`, `resumePoint` | The lifecycle and the epoch (`:207-209`), unchanged. The window is written before the await (`:201-202`). A hook may re-queue J during it, and `spaceFailed` reads that |
| f-4 | `EngineFailures.swift:566-569`, `refreshFreeSpace` | The lifecycle and the epoch (`:570-572`). Then: is J still failed? If not (a hook's T20 in the read), `decideSpaceFailure`, clear, no deferral. Then `defersToFollow` (freeze) or the close |
| RE-S13 | `EngineDispatch.swift:1300`, `EngineFailures.swift:211` | Unchanged: the callee re-validates |
| RE-S45 | the drain's follow-up (`s3f.md:1720`) | Unchanged. The `.spaceFailure` replay reads `owed` and runs the close inside its own turn |

- No await is added. Each hook, and the close, runs within one turn. `docs/ARCHITECTURE.md:476` (f-2) and `:478` (f-4) take the text above.

## 6. C2 (estimates, except the ledger's figures)

- **The end's turn:** O(1), a few fields and a retained reference; M is a predicate and there is no walk (R1 dropped). Under 0.05 ms (basis: one set insert, one struct write).
- **Each window apply:** the diff's two lookups per entry at 50-150 ns, ≤ 2,048 entries a turn: 0.2-0.6 ms a turn, 1-3 ms over 10,000 entries in 5 turns (basis: f1b's ~0.1 µs a comparison). One diff serves L windows; sharing out is O(crossings).
- **Hooks:** about 0.1-0.5 µs a pair. A 512-id follow turn (`EngineMoves.swift:235`) gains 0.05-0.25 ms, a 256-id inbound turn 0.03-0.13 ms. **Riskiest:** a 10,000-id group release in one turn gains 1-5 ms on top of its own turn.
- **The close:** about 0.3-0.5 µs a crossing pair, so 3-5 ms at 10,000 crossings, plus about 1 ms for J's passed ids at a publication end. At R it is the whole turn. At the replay it adds to `drainVerdictTurns` 4.55 / 4.42 ms (`s3f.md:10450`): 8.5-10.5 ms, **which may miss 10 ms.** Fallback, ruled in advance (review must-add 6): the close in steps of ≤ 2,048 crossing ids before the verdict's replay, the drain pausing at the verdict, as the follow's own steps do.
- **Memory:** c_E per window, about 1-2 MB at 10,000 entries (the review's figure); one extra copy briefly per pending diff; `crossings` and `paths` at about 32 B a record, 0.3-0.6 MB at 10,000 each.
- **New BenchSync cases** in `Tests/ZTronAssetKitBenchmarks/BenchSync.swift`, shaped like `inboundWalkTurns` (`:607-625`), against P-9 and 10 ms, no `Scripts/` edit: `spaceWindowApplyTurns` (10,000 entries changed onto J's content), `spaceWindowReleaseTurns` (a 10,000-id release with a window open), `spaceWindowCloseTurns` (the close at R and at the replay, 10,000 crossings).
- **Re-measure** (best of 3): `sharedApplyTurns` 7.29 / 7.68 (`s3f.md:10448`), `drainVerdictTurns` (`:10450`), `concentrationNotFoundTurns` 5.62 (`:10451`), `concentrationFollowTurns` 3.76 (`:10452`), `publicationApplyTurns` 4.29 (`:10453`), `inboundWalkTurns` 3.74 (`:10455`).

## 7. Ruling and ARCHITECTURE lines to lift or correct

1. **Clarify S3-R26 item 5(i)** (`s3-rulings-s3f.md:553`). The fix stays in `relane`'s failed arm, which returns for a job in its window. T20 for that job comes from the hooks and the decision.
2. **`.build-orchestrator/s3f-c20-analysis/integrate-rr21.md`:** no lift of `:586` (`waitingTarget` and `replayJoin`'s routing do not change); clarify `:587` (RR-14's walk keeps its place before the adoption; the diff is queued in `followApplied`); `:560` and `:561` untouched.
3. **D5** (S3-R26 item 12, answer 5, candidate 4; `EngineJobs.swift:98-114` and its doc) is extended for a frozen window (§1.8).
4. **Correct RR-18** (`s3f.md:4385-4388`), as f1b §6.5 says.
5. **N1, N3, N4, N16** (handed to item 1b by N20). N1: the deferral freezes the window instead of clearing it; the verdict's clear stays first in `decideSpaceFailure`; the clauses are §1.2's. N3: clause (b) becomes 4c, read only inside a window. N4: f1-B9's killer becomes K17's (T-F10b, T-F7). N16: §9.
6. **Text naming the removed fields:** `metInItsAttempt`'s doc (`EngineJobs.swift:280-288`); `relane`'s doc and comment (`:299-303`, `:328-357`); the docs of `AttemptEnd.stamped` and `Job.transferSpaceEnd`; the start's comment (`EngineDispatch.swift:739-740`); the ledger's e1-P1 residual (`s3f.md:7151`), e1-P2 design (`:7175-7187`) and `t20-m6-no-clear`'s Equivalent argument (`:6511`).
7. **`docs/ARCHITECTURE.md`:** `:220` (failed → queued, T18-T20): in an ENOSPC window, T20 comes from VF's re-lane through the window's hooks or decision. `:273` (`insufficientSpace`): decided after the window's close, at R or at the deferred replay. `:476`, `:478`: §5's text.
8. **f1b's must-say 3, 4, 6, 7 and 8** are replaced by this route.

## 8. Fixer hours (estimates)

**Total: about 40-62 h, plus step 0 at about 8-12 h** (f1b's 4-6 h, doubled for the late drain and the added rows). By part: record, lifetime, clauses and removals 3-4 h; crossings and `spaceWindowApplyTurns` 4-6 h; §1.4-§1.5 with `Job.publication` and `InboundMove.found` 7-10 h; hooks, failed arm, `paths`, `born` 4-6 h; decision, close, must-fix 9 3-5 h; §1.8 1-2 h; new shapes as tests 8-14 h; kills 5-8 h; BenchSync 3-4 h; docs and ledger 2-3 h. Basis: f1b §8's step figures, the f1 review's 1-2 h per new shape, cycle 22's e1 pace. A part over 1.5 times its upper figure is a stop (N22 2(e)).

## 9. Shapes left open, and why

1. **The W-LANE family** (corner iii). T20's lane and origin conditions are read in SF's state: at the hook while J is not deferred, at the replay once it is. VF reads them at its own re-lane. Each choice of instant gets one sub-shape wrong:

   | Sub-shape | Setup | J-E2 in-read | J-E2 late | Same as 9aa337c? |
   |---|---|---|---|---|
   | W-LANE | a user waiter withdrawn before the crossing | R | G | yes |
   | W-LANE-rev | withdrawn after the crossing, before R | G | R | yes |
   | W-LANE-3 | the only user pair leaves J at a later window apply | G or R (the follow's visit order) | R | yes |

   - A route needs a per-window count of user-lane pairs on J along VF's paths. That needs every pair's path, not only the touched ones; its cost is not estimated.
   - N23.6 classes corner (iii) as timing (§10). If that classing is withdrawn, the family is open and blocking.
2. **W-OBO**, `begin ∩ away`'s residue: an id in J's begin set that VF moved off J, then back onto publishing J, then away again before the end. VF's J passes it (it re-joined after the begin), but `begin ∩ away` puts it in M: SF's begin set is fixed at the begin, VF's is not. Probe it; a route would update the begin set at each re-join while J publishes.
3. **W-PEND-LATE's tail.** Not traced to the end: whether T2's visit after its move lands (`continueInbound`, `EngineFollow.swift:1519-1567`) comes before J's replay in every order of the follow's steps. If it comes after, the window is closed and X meets J's verdict.
4. **The holder-state approximation in 4b and 5b.** Passing is read from SF's job of that content (its publication counts). With no SF job, the holder does not pass (§10); with a later SF attempt than VF's, its counts are later, so it reads as not passing. Not traced further.
5. **lastError's figures.** For a deferred J re-queued at its replay, `decideSpaceFailure` reads the figures then, as 9aa337c's deferral does; VF reads them at R. They are equal unless another read or admission changes the room in between (UNCONFIRMED).
6. **Outside item 1.** W-PEND-LATE's non-ENOSPC twin reads red by the same trace (UNCONFIRMED): a deferred `.attemptFailed` verdict, with D5 making the join wait. It is reported here, not routed.

## 10. Shapes whose VF answer depends on VF's timing (N21's reading)

| Shape | VF timing that selects | VF's answers | J-E2 gives |
|---|---|---|---|
| Multi-change lazy (T-F4's lazy twin, X; T-F4 eager too) | whether VF's U completes before v5's visit | U first: X gets U's bytes; else X rides T's second attempt; T20 at v4 either way | T's second attempt (SF starts no U in the lazy twin) |
| W-BACK-PUB | whether VF's U is downloading or publishing at v4 | downloading: T20, A `ok`, 2 starts; publishing: no T20, A `insufficientSpace` | T20 (5b: no SF job for U) |
| W-NEST (new) | whether VF's G is downloading, publishing or done at v5 | downloading: T20; publishing or done: no T20, X gets G's bytes | T20 |
| W-LANE family (N23.6) | the instant at which T20's lane is read | §9.1 | §9.1 |

## What the ruling must say

1. **J-E2 replaces J-E.** A re-lane of a job in its ENOSPC window is decided by the pair's VF path, not by any SF clock. `relane`'s failed arm returns for such a job, and T20 comes only from H1-H3 and the decision's close.
2. **The record** (§1.1) is written at both ends before the first await. `transferSpaceEnd` and `AttemptEnd.stamped` are removed, with one-to-one edits to the bound test and the probes.
3. **The lifetime and clauses** (§1.2). The window is frozen at a deferral, and cleared at the decision, on leaving failed, in `decideSpaceFailure`, at the start and at removal. It has three `invariantViolations()` clauses (must-fix 6, 7).
4. **Crossings** (§1.3) are the first follow step of each window apply, at ≤ 2,048 entries a turn, keeping the follow owed. `adoptApplied` and RR-14 do not change.
5. **VF's position at the end** (§1.4):
   - M is `begin ∩ away`;
   - passed ids are dated by the holder's end count (a_G ≥ E), not by SF's deferral;
   - `found` dates the moves pending onto J;
   - waiting joins and owed items are dated from their birth.
6. **The path** (§1.5). (f) applies to direct events at s > S. A hop is dated by its chain's crossing. An unknown holder does not pass (W-BACK-PUB, W-NEST).
7. **The decision** (§1.7) includes must-fix 9, and D5 is extended at a frozen window (§1.8). Both apply to ENOSPC windows only. The non-ENOSPC twin of W-PEND-LATE is recorded as a separate finding.
8. **Dropped:** R1 (no `integrate-rr21.md:586` lift), clause (o), the layers and the deferral reorder. S3-R26 item 5(i) and `:587` are clarified, RR-18 is corrected, and N1, N3, N4 and N16 are adopted as §7 says.
9. **Step 0** runs every §2 row on `9aa337c`, in both orders and both drain timings, 2 rounds, measured, against the measured VF run (N23.5). The orchestrator checks §2 against it before the route binds. A row that is G here and R measured is a stop under N22 2(c).
10. **C2.** The three new cases and six re-measures run first (N22). The close at the replay (8.5-10.5 ms, estimate) and the 10,000-id release are the risks. The stepped close is the fallback ruled in advance. A miss after it is blocking (S3-R16 1(f)).
11. **Kills K1-K28** are each killed 2/2, in every order and timing that reaches the branch. K21 and K24 are killed or argued Equivalent under S3-R16 1(e).
12. **Classification.** Under N21's reading, the multi-change lazy shape, W-BACK-PUB and W-NEST are matched by one of VF's answers (§10). The W-LANE family is timing under N23.6, or else open and blocking. W-OBO and W-PEND-LATE's tail are probed at step 0, and a red one is blocking with no route yet.
