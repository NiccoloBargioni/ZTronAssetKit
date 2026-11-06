# Review of f1b-join-rule.md (P4, adversarial; for S3-R28)

Independent and read-only: I wrote neither f1b nor the code. Checked against `.worktrees/s3f` at `9aa337c` (`git log`
HEAD), f1 and its review, `s3f-c22-issues.json` correct #1 and #2, S3-R16, S3-R19 item 2 (rulings :242), S3-R26 item 5,
S3-R27 12.2/12.5, `integrate-rr21.md:558-588` and the draft. Nothing was built, run or measured: every red or green below
is by code reading (UNCONFIRMED), and every cost is an estimate (G2). Paths are under `Sources/ZTronAssetSync/Engine/`
unless given in full. VF and SF are as in f1b. New shape names: W-PD-back2, W-JOIN-HOP, W-JOIN-OFF, AV-off, W-BACK-PUB.
"Late drain" is an SF run whose follow is released only after J's read returns, so the drain runs after J's deferral. The
c22 probes release it inside the read (`VerifyC22CorrectProbes.swift:320`, `:445`), so no test has run the late drain.

## Verdict: UNSOUND as a whole. Several parts are sound and can be ruled now.

**What holds** (code reading):
- About 40 sampled citations match `9aa337c`, line numbers included.
- Both ENOSPC ends leave J `failed` across an await before its verdict (`EngineFailures.swift:196-212`, `:569-581`;
  `EngineDispatch.swift:1259`, `:1298-1301`), so the window is real at both ends.
- R1 and the transfer clause: today a transfer end's moves are dropped (`EngineFollow.swift:1596-1597`). R1 sees a passed
  holder's ids only through its reroute set (`:1408-1412`), which is why W-HP-d needs (AV), not the per-id copy.
- (b) dated by `found`: every move onto J is found by J's own walks, or by `bringInboundOntoPublications` before the copy
  changes (`EngineCatchUp.swift:222-229`, `EngineRuns.swift:368-393`), so `found` is the count it was found under.
- (AV) with `d < E` for a drain inside the read; the transfer-end removal rule (T-F8, T-F8c, W-AWAY); the W-DB reorder;
  the close for T-F4's lazy twin, W-DB-off and W-BACK with U's transfer held; C3 (no await is added).

**What fails:** two regressions against 9aa337c (Must fix 1, 2); three listed rows red in a legal SF timing (3);
second-class reds the close cannot see (4); a clause the count dominates, with a false "unreachable" (5); a window that
outlives its read (6); two G4 errors (7, 8); a deferral path that drops a write (9). So f1b:23, "every listed shape gives
VF's answers in both orders", does not hold.

## Must fix

1. **`begin` lacks `∩ away`, so J-E regresses W-PD-back2.** f1b's `begin` is `rerouteOnPass` when `rerouteFor` matches,
   with no check against the end's copy (f1b:30-31).
   - Shape: T downloads zz-a (A, a user waiter) and zz-b (B). k1 maps zz-b to U while T downloads, with the follow owed,
     so T's publication begins with zz-b in `rerouteOnPass` (`EngineDispatch.swift:1033-1040`). k2 maps zz-b back to T's
     content while T publishes. T's ENOSPC end comes; v4 in the read maps zz-b to W.
   - VF: k1's visit moves zz-b to U; k2's visit of U (transfer held) moves it back onto publishing T; v4's visit meets T
     failed and moves zz-b off: T20, A `ok`, 2 starts.
   - SF under J-E: T's visit is owed throughout, so `begin` = {zz-b}. After v4 the visit moves zz-b (`rerouteOnVisit`
     nil at 4 ≠ 3, `EngineFollow.swift:1164-1165`); the removal is in `begin`, so met. The close sees zz-b in M, but v4
     maps it to W, not back onto T. No T20: A `insufficientSpace`, 1 start. On 9aa337c the count (4 ≠ 3,
     `EngineJobs.swift:290-291`) gives T20, green, so this is a regression.
   - Fix: `begin = rerouteOnPass ∩` {held ids the end's copy maps elsewhere or not at all}, the intersection
     `recordDeferredVerdict` already takes (`EngineFollow.swift:554-561`). W-PD and W-PR keep their traces. The residue,
     an off-back-off before the end, is today's approximation in `recordDeferredVerdict`; probe it.

2. **(f) misdates a replay that reaches J through a later copy (W-JOIN-HOP, both ends).**
   - Shape: V, a user request for zz-y, arrives behind the barrier before J's end, when zz-y's entry is W's content (W's
     transfer held). v4 in J's read maps zz-y to J's content.
   - VF: V joins W at once; v4's visit of W moves zz-y onto failed J: T20.
   - SF, in-read drain: `replayJoin` (`EngineFollow.swift:981`) re-routes V onto J through its chain (`followLayers`,
     `:800`) under V's reading. On 9aa337c at a transfer end there is no `stamped`, so (f) is false
     (`EngineJobs.swift:293-295`) and T20 follows: green. Under J-E, `s_V ≤ stamped` is met and J's verdict answers A and
     V: red. At a publication end it is red on 9aa337c already (e1-P1's (f)). The same holds for an owed re-route item
     and a take-off that reach J through a copy adopted since E.
   - SF, late drain: J is deferred first and `relane` returns at `:327`, red at both ends on 9aa337c too (item 4's class).
   - Fix: (f) dates only what the event did on arrival. When the event's own entry, or its batch `copy`, names J's
     content, (f) stands (T-F1a, T-F9, the bound test, e1-P1's pinned batch). A hop onto J is dated by the first copy in
     its chain that maps the id to J's content, or by the pin's layer: met only if that count ≤ `spaceEnd.applies`. The
     f1 review's "the replay half is sound" (review :8) and correct #1's proposed fix need this amendment.

3. **W-HP (both ends) and W-HP-d are red in the late drain.** f1b assumes H's verdict comes at once. While the barrier
   is up, SF defers every exit (`retryLater` → `defersFailure`, `EngineFailures.swift:256`, `EngineFollow.swift:489-505`),
   and H's waiting verdict keeps the barrier up (`followBarrier`, `:97-99`).
   - When J's read returns first, J defers with `AttemptEnd.copy` = v4's copy, which maps zz-x to J (`:564`). The close
     sees nothing: zz-x is on H, not in N. The deferral walk skips zz-x: H is passed, and its reroute set was computed at
     H's deferral, before v4, when zz-x mapped to H (`:554-561`). Then `followAfterVerdict(H)` moves zz-x onto J, D5's
     copy check (`EngineJobs.swift:110-111`) joins it at once, and `relane` returns at `:327`. J's verdict answers A and
     X: `insufficientSpace`, 1 start. VF: H's revisit at v4 meets J failed: T20, `ok`, 2 starts. Red on 9aa337c too.
   - So W-HP-late is the late half of three listed rows, not a separate corner. §6 item 8's "D5 unchanged" is false at
     an ENOSPC deferral: D5's "before this verdict" includes J's read, where VF met J failed.

4. **N leaves out ids VF had on J that SF keeps elsewhere.** These are must-say 2's second class: blocking, with no route
   in J-E. Both shapes are red on 9aa337c too.
   - AV-off (one change; f1b's AV-away needs two): Y holds zz-y and its verdict defers at d = 2; v3 maps zz-y to J's
     content; J's end at E = 3; v4 maps zz-y to U. VF: v3 moves zz-y onto J, and v4's removal gives T20. SF: R1 skips
     zz-y (Y is passed). When v4 comes before Y's verdict is replayed (the c22 fixtures' order), `followAfterVerdict(Y)`
     sends zz-y straight to U, and J is never re-laned.
   - W-JOIN-OFF: V's join for zz-v (J's content) waits behind the barrier from before J's end; v4 maps zz-v to U. VF: V
     joined J, and v4's removal gives T20. SF: V's replay follows its chain to U, and J is never re-laned.
   - Route candidate (UNCONFIRMED): the deferral walk already visits every job (`foundInbound`, `:1399-1446`). It can add
     to N or to the T20 check: (a) passed ids of holders deferred at d < E that the end's copy maps to J's content; (b)
     for d ≥ E, ids that layer d+1 maps onto J's content (VF's T20s, item 3); (c) waiting joins and owed items with a
     serial ≤ `stamped` whose own copy names J's content; (d) waiting joins and owed items whose chain reaches J's
     content through a layer after E (VF's T20s, item 2's late drain).

5. **(o) = false is dominated by the count, and K16 is reachable.** At `appliesFollowed == spaceEnd.applies`, every
   follow join onto J stands for a visit at an apply ≤ E, or for a move VF never made in J's window; neither re-queued J
   in VF.
   - §7 (ii) reaches (o) at count E. T2's own R1 overflows and owes zz onto T2 under k1's copy. k2 ≤ E maps zz to J's
     content, and J's R1 skips zz as pending (`:1413`). T2's owed move lands, then k2's pass visits T2 (a transfer end,
     `rerouteOnVisit` nil) and moves zz onto J with no apply since E. VF: met. Under "false": T20, red. The count: met.
   - Fix: keep 9aa337c's count for (o), as the f1 review's candidate did (review :141). K16 goes. "(o) forced false" is
     killed by this shape, or argued Equivalent if step 0 cannot build it. K9's killer becomes T-F7, not T-F2a, since
     R1's move is made at count E.

6. **The window outlives its read.** On the defer branch, if J is no longer `.failed` (a T20 in the read, or from the
   walk), step 5's guard returns without clearing `spaceEnd` or `spaceWindows`; §1 item 1 clears only at the start, the
   deferral, `decideSpaceFailure` and removal. `adoptApplied` then keeps every new copy in `layers` until J's next start,
   which waits behind the barrier, the queue and any space or breaker block, so memory grows with each apply (about
   1-2 MB a copy at 10,000 entries, estimate). Fix: end the window at the read's return on every path, or when J leaves
   `.failed` at that epoch.

7. **G4: S3-R19 item 2 is misread.** §4 calls a `spaceWindows` leak "cost-only", but item 2 covers only a change of "not
   any decision, answer or state" (rulings :242), and a leaked membership with its layers is state. Fix: kill K26 and K27
   with `invariantViolations()` clauses: `spaceWindows` equals the jobs with a `spaceEnd`, and a `spaceEnd` exists only on
   a job that is `failed(.nextRun)` at its window's epoch.

8. **K19 cannot be killed by W-PD-back as written.** After "a begin set whose follow ended and re-routed it", J's visit
   has emptied the set (`EngineFollow.swift:1210-1211`; a visit's rest at `:1130-1131`), so a mutant that ignores
   `rerouteFor` (`:1156`) also reads []. A separating shape needs a stale set that is not empty: the follow that recorded
   it ends without J's visit, because zz-b was mapped back before its pass reached it; a later follow maps zz-b off while
   T publishes and stays owed through T's end; v4 comes in the read. VF: the revisit at v4 gives T20. The mutant: met.
   The shape still separates with Must fix 1's `∩ away`.

9. **Step 5's "else return" drops two things 9aa337c does for a J that is no longer failed.** (a) `decideSpaceFailure`
   writes `lastError = figures` before its guard (`EngineFailures.swift:591`), and admission sizes a re-queued job by it
   (`EngineDispatch.swift:593`, `EngineJobs.swift:1124`); VF writes it at its read's return. (b) 9aa337c records the
   deferral and replays `.spaceFailure` (a take-off, then `followAfterVerdict`). Fix: call `decideSpaceFailure` on that
   path, since it returns before any verdict for a job that is not failed (`:592-596`); trace the dropped deferral
   against VF in W-AWAY, T-F2b and W-DB; run the guard before `bringInbound` when the close has already re-queued J.

## Should fix

- **C2 at the read's return.** f1b's 5-9 ms leaves out `recordDeferredVerdict`'s per-id filter (`EngineFollow.swift:554`)
  and the walk's moves (≤ 256 ids at about 5 µs, `EngineMoves.swift:230`). `inboundWalkTurns`' 3.74 ms has no moves
  (`BenchSync.swift:616`); with moves onto one content the turn is `concentrationNotFoundTurns`' 5.62 ms
  (`s3f.md:10451`). Together that is about 8-12 ms at 10,000 ids and L = 2 (estimate), before Must fix 4 adds its walk.
  Time the whole turn, with moves, at L = 1, 2 and 4.
- **`held` is a CoW snapshot:** R1's first join copies J's whole id set inside the end's turn (about 0.3-1 ms,
  estimate). Count it, or compute M at the end.
- **`bringingInbound = move.found`** must be set per move inside the loop; `:1525` is before it.
- **`followedLane`** also reads `waitingTarget(_ move:)` (`:1575-1576`). Name it with the clause, and keep its 429 tests
  as controls.
- **§7 (iv) is unreachable:** a verdict at once needs `!followOwed`, and an owed R1 move keeps it true (`:82-90`,
  `:103`). Close it by that argument.
- **The close's own branches:** N's `found <= applies` is always true at the close, so its mutant is Equivalent; drop
  it. N's pending part and M's transfer and publication arms have no kills in §4; the pending part needs T-F2c in the
  late drain with a layer that moves the id off J.
- **State** that J's verdict follows when T20's conditions fail at the close.

## What the ruling must add

1. **Rule now** (sound by code reading): the record, written at both ends before the first await; R1 with the transfer
   clause (lifting `integrate-rr21.md:586` for that clause, and clarifying `:561`); (b) by `found`; (AV); the
   transfer-end removal rule; `begin ∩ away` with the `rerouteFor` check; (o) by today's count; the deferral reorder,
   with Must fix 9; the clears, plus the read's-return clear and the invariant clauses.
2. **(f) for direct replays only;** a hop onto J is dated by its chain (Must fix 2). W-JOIN-HOP joins step 0 at both
   ends, and the f1 review's "replay half is sound" is amended.
3. **Step 0:** every SF row runs in both drain timings, and W-PD-back2, W-JOIN-HOP ×2, W-JOIN-OFF, AV-off, K19's shape
   and W-BACK-PUB (U's publication held at v4) are added. A red is blocking.
4. **The close is not ruled until N is re-analysed** to hold VF's ids on J at the end (deferred holders, waiting joins,
   owed re-routes), and the d ≥ E holders and later-hop joins that VF moved onto J in the read. Until then, AV-off,
   W-JOIN-OFF and the late-drain rows are blocking with no route.
5. **D5 at an ENOSPC deferral** is in that re-analysis, not "unchanged".
6. **C2:** the read's-return case times the whole turn. A miss is blocking (S3-R16 1(f)), and the ruling names the
   fallback in advance, for example a close made in steps at each apply.
7. **Classify W-BACK-PUB with f1b's multi-change.** VF's U is publishing at v4, so U's visit passes zz-b
   (`rerouteOnVisit`'s `.verifying` arm, `EngineFollow.swift:1158-1159`) and VF makes no T20. SF has no job for U, so no
   rule on SF's state separates the shape from W-BACK. Classify it as timing (S3-R16 item 2), or as blocking for the
   owner.
8. **Hours** (estimate): f1b's 22-33 h plus about 16-26 h, so about 38-59 h, on f1b's step figures and the f1 review's
   1-2 h per new shape: Must fix 1 and 5-9, 3-5 h; item 2, 3-5 h; the late drain and the new shapes, 4-6 h; N's
   re-analysis and route, 6-10 h.
