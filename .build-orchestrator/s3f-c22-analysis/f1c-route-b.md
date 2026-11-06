# f1c route B: remove the ENOSPC window instead of dating it (for item 1b)

This is a read-only analysis of `.worktrees/s3f` at `9aa337c`. Nothing was built, tested or run. Every red or green
comes from code reading and is UNCONFIRMED, unless it is marked "measured" (a c22 probe log exists). Every cost and
hour figure is an estimate (G2). `Engine/` is `Sources/ZTronAssetSync/Engine/`, and `Tests/…/` is
`Tests/ZTronAssetSyncTests/Engine/`.

## 0. The idea

- **The window today.** From J's ENOSPC end E to its read's return R, J is `failed(.nextRun)`, undecided and live.
  - Inputs that meet J in (E, R) are dated against E by `metInItsAttempt` (`Engine/EngineJobs.swift:289-297`). It
    has two clocks: the count `appliesFollowed == failedAfter ?? transferSpaceEnd` for visits, and the stamp
    `reading.serial <= stamped` for replays.
  - The deferral at R (`Engine/EngineFailures.swift:573-581`) makes J inert for every (E, R) input that the drain
    replays later. These are M1 to M5. M2, the late-drain class, has no dating fix.
- **Route B.** J's window moves into the drain's queue.
  - At E, in E's own turn, J defers as `defersFailure` (`Engine/EngineFollow.swift:489-511`) defers every other exit,
    with an **end marker** at E's place.
  - Each apply adopted behind the barrier while the window is open adds an **apply marker** at its place.
  - R adds the **read marker**, which is today's `.spaceFailure`.
  - The drain replays all three in arrival order. "Before or after the end" becomes queue order, which the drain
    already gives in VF's way.
- **The task's three examples.**
  - Example 1, holding and replaying in VF order, is the core.
  - Example 2: B1 makes E's own turn the dating instant, before `resumePoint` and `refreshFreeSpace`.
  - Example 3: R1 at E (the existing `bringInbound`), plus the virtual visits of B3.

## 1. The route's parts, in order

- **B0. Data.**
  - **New on `Job`: `spaceWindow`.** It holds:
    - the epoch and the end kind;
    - `A_E` (`appliesFollowed` at E) and `s_E` (`copySerial` at E);
    - the phase: `.endWaits`, `.window` or `.readWaits`;
    - `A_R` and `s_R`;
    - the virtual set N;
    - `offBy[layer]`: the ids the follow moved off J for each window layer.
  - **New events:** `.spaceEnd(J, epoch:)` and `.windowApply(J, epoch:, serial:)`. The apply marker names its copy by
    serial, through the copies the chain layers already hold.
  - **Retired:**
    - `metInItsAttempt`;
    - `transferSpaceEnd` (`Engine/EngineState.swift:867`), with its write (`Engine/EngineFailures.swift:201-202`) and
      its clear (`Engine/EngineDispatch.swift:743`, which becomes `spaceWindow = nil`);
    - `AttemptEnd.stamped`, written at `Engine/EngineFollow.swift:529-532`. `stampsMinted` stays for `worldStamp`.
- **B1. The end marker, in E's turn, before any await.**
  - **Where.** At the transfer end, in place of `Engine/EngineFailures.swift:201-202`, so before f-2's `resumePoint`.
    At the publication end, after `recordPublicationEnd` (`Engine/EngineDispatch.swift:1259`) and before `:1300`.
  - **The window.** J's window always opens.
  - **If `defersToFollow && exitDefers(job)`:**
    - `recordDeferredVerdict(J)`: the copy at E and `deferredAfter = A_E`;
    - `phase = .endWaits`;
    - `deferToFollow(.spaceEnd)`. Its stamp is E's decision instant (`Engine/EngineFollow.swift:264-267`).
    - `bringInbound(J)`: R1 at E. Its guard, `followOwed` (`:1316-1322`), is not widened.
  - **Otherwise:** `phase = .window`. This is always the case in the VF order.
  - **No new key.** As for today's `.spaceFailure`, J gets no `verdictsAfterFollow` key. The bucket key stays
    `VerdictKey(J, epoch)`.
  - **K19 fix** in `recordDeferredVerdict` (`:548-566`): `movedBefore = (rerouteFor == followsEnded ? rerouteOnPass :
    []) ∩ away`.
- **B2. The end marker's replay.**
  1. Guard the epoch.
  2. Run `takeOffMovedBefore` (`:594-616`) while J is still inert.
  3. Set `N = J's interests ∪ offBy[all window layers]`. This is VF's J at E: B6a keeps the window layers' joins in
     the bucket.
  4. Switch to `.window`. This clears `deferredAfter` and **restores VF's `attemptEnd` shape**: nil at a transfer end,
     and `recordPublicationEnd`'s value at a publication end. With this, `waitingTarget(_:epoch:)` (`:1589-1600`) and
     the failed arm of `rerouteOnVisit` (`:1154-1177`) stay unchanged (W-TGT).
  5. Land the take-off under the current copy. This gives W-BACK's T20.
- **B3. The apply markers.**
  - **When one is added.** `adoptApplied` (`Engine/EngineJobs.swift:1224-1235`) enqueues `.windowApply` for each J
    whose window is open. It does so only when `defersToFollow` holds at the adoption, before the apply's own follow
    starts. This never holds in the VF order (section 2).
  - **What its replay does.** VF's visit at that apply, made virtually on N:
    - remove the ids the layer maps off J's content: every moved id, passed ones included;
    - add the ids the layer maps onto J's content (from a diff against the previous layer) whose holder's visit
      would move them;
    - each change runs the arm VF's visit runs (a join: `relane` from `addInterest`, `Engine/EngineJobs.swift:196`).
      T20 (`:360-364`) is decided under the marker's stamp, because the origin gate reads `decisionNow()`
      (`Engine/EngineOriginGate.swift:81-83`), and J's lane is read from N.
  - **Limits.** The replay moves nothing and owes nothing. It ends its drain batch, as `.reroutes` does.
- **B4. The read's return,** in place of `Engine/EngineFailures.swift:573-581`.
  - **J's markers wait, or `defersToFollow` holds:**
    - set `phase = .readWaits`, `A_R` and `s_R`, then `deferToFollow(.spaceFailure)`;
    - if no end marker was placed (the barrier rose after E), also `recordDeferredVerdict` and R1 at R, as today.
  - **Otherwise:** bring J to N_R (in VF, N_R is J's interests), then `decideSpaceFailure`.
  - **J no longer failed:** `decideSpaceFailure` writes `lastError` and returns (`:591-596`).
- **B5. The read marker's replay.**
  1. Guard the epoch.
  2. Bring J to N_R, inert, in batches of at most 512 (`followIDsPerTurn`, `Engine/EngineMoves.swift:235`). The ids
     come only from J's bucket and from the existing `movedBefore`/`movesAfterVerdict` lists
     (`Engine/EngineFollow.swift:571-616`).
  3. Give the verdict if J is still failed, otherwise only `lastError` (f1b review must-fix 9).
  4. Then `followAfterVerdict` (`:867-878`) and the rest of the bucket.
- **B6. `relane`'s failed arm** (`Engine/EngineJobs.swift:326-365`), when J's window is open at its epoch.
  - Follow work (`inFollowVisit`, `bringingInbound`, `visitingAfterVerdict`) is inert. B6a and the markers decide
    for it.
  - Replays while the end marker waits are inert. They arrived before E, when VF's J was in flight.
  - Every other input takes the existing T20 path, with no clock and J's lane read from N. This covers direct inputs
    (W-REL) and replays after the end marker.
  - A direct T20 while the end marker waits retires J's markers. The owed visits then move the `movedBefore` ids, as
    they would for a queued job.
  - Jobs with no open window keep today's `deferredAfter != nil` return.
- **B6a. Follow work on J is assigned by copy, not by count.** The rule takes the first layer after `s_E` whose copy
  maps the id onto J's content, or off it:
  - **None, or an R1 move:** pre-end. It acts on J as VF's visit did before E.
  - **A marked window layer:**
    - a join waits in J's bucket, tagged with its layer;
    - a move off J happens, and is recorded in `offBy`;
    - the marker decides T20.
  - **After `s_R`:** the work waits behind the verdict (`deferBehindVerdict`, `Engine/EngineFollow.swift:1288-1291`).
    This covers W-HP-late.
  - **An unmarked window layer:** this is the first apply after the barrier dropped. T20 happens at the visit, as in
    VF, because the follow still runs before the replays that the barrier deferred.
  - For J only, this replaces `joinWaitsForVerdict`'s `!bringingInbound` (`Engine/EngineJobs.swift:109-114`).
- **B7. The hop rule.** A replay or batch before J's end marker can walk a chain (`replayJoin`,
  `Engine/EngineFollow.swift:981-1001`) into J's content at a layer with `applies ≥ A_E`. That walk goes to the
  layer's bucket. The `ends` filter (`:693-723`) cannot do this, because of its second-layer rule (W-JOIN-HOP).
- **B8. A visit after a holder's verdict, replayed before J's end marker.** The ids that the copy at E maps to J with
  `d < A_E` join J under that copy (met). `d = A_E` counts as after the end (AV-off, W-HP-d0).
- **Unchanged.** W-JOIN-OFF: J's waiting verdict (`deferredAfter = A_E` from E) is in the layers' `ends`, and
  `followLayers`' pin (`:800-842`) holds.

## 2. Per-shape answers, by order and drain timing

- **The VF order** (`followVisitedFirst`, `Tests/…/EngineFollowTests.swift:780-787`).
  - `applyHeld` awaits the barrier's drop (`Tests/…/EngineFollowBarrierReachTests.swift:19-32`). So no follow is owed
    and no event waits at E, at an adoption or at R.
  - Therefore B1 takes `.window`, B3 never fires, B4 decides at once, and B6 with no markers is today's T20.
    `metInItsAttempt` is never true in the VF order.
  - So every VF-order answer under B is 9aa337c's, which is VF's (UNCONFIRMED). Step 0 and K-V check it.
- **The SF order** (`sweepFollowsFirst`) is in the table below.
  - "in-read": the drain is released inside J's read. "late": the drain is released after R. B's column holds for
    both.
  - On 9aa337c, the late arm follows one rule (UNCONFIRMED; no test has run it): T20 shapes are red and verdict shapes
    are green, because J is inert from R's deferral.

| Shape | VF's answer | 9aa337c in-read | 9aa337c late | B | B's part |
|---|---|---|---|---|---|
| T-F1a | A, X, V `insufficientSpace`; 1 start | red (measured) | green | green | B1, B6 pre-end inert |
| T-F1b | all ok; 2 starts | green (measured) | red | green | B6 window replay |
| T-F2a | A, X `insufficientSpace`; 1 start | red (measured) | green | green | B1, B6 |
| T-F2b, T-F3 | T20 | green | red | green | B6 |
| T-F2c | the verdict | green | green | green | B5 |
| T-F4 corrected | T20 at v4 | green | red | green | B3, v4's marker |
| T-F4 lazy twin | T20 | green (D1's luck) | red | green | B3, B6a |
| T-F5, T-F7, T-F9 | the verdict | red | green | green | B1 |
| T-F6 | the verdict | red | green | green | B1; `joinWaitsForVerdict`'s copy at E |
| T-F8 | A `insufficientSpace`, B U's bytes | red | green | green | B1 `movedBefore`, B2 |
| T-F8c | T20 | green | red | green | B2, B6 |
| T-F10 | X `insufficientSpace` | green | green | green | B4/B5 N_R, not the copy at R |
| W-PR | T20 at the revisit | green | red | green | B3 |
| W-PD | the verdict | red | green | green | B1 |
| W-PD-back, W-PD-back2 | T20 | green | red | green | B3, passed ids count |
| K19's shape | T20 | green | red | green | B1's `rerouteFor` fix |
| W-AWAY, both ends | T20 | red | red | green | B3 removes the ids mapped off |
| W-HP, W-HP-d, W-HP-d0 | T20 | green | red | green | B3, B8 |
| W-HP-late | the verdict, then the revisit | green | green | green | B6a, after `s_R` |
| W-DB, W-DB-off | T20 | red | red | green | B1's R1 at E, B3 |
| W-BACK, both ends | T20 | red | red | green | B2 |
| W-JOIN-HOP | T20 | pub. end red, transfer end green | red | green | B7 |
| W-JOIN-OFF | T20 | red | red | green | existing pins |
| AV-off | T20 | red | red | green | B8 |
| AV-away | T20 | red | red | green | B3, lane from N |
| W-ONOFF | T20 | red | red | green | B3's diff |
| T-B11 | T20 | green | green | green | none |
| W-REL (new) | T20 at the direct input | green | green | green | B6 direct path |
| W-TGT (new) | no target at a transfer end | green | green | green | B2 restore |
| Multi-change lazy | timing (section 11) | ? | ? | one of VF's | B3 |
| W-BACK-PUB | timing (section 11) | ? | ? | T20, one of VF's | B2 |
| W-ONOFF-PUB (new) | open | ? | ? | open | section 10 |

- **f1b's corners.** (i) is closed by B3, (ii) by B6a, and (iii) by B3's stamp. (iv) is unreachable by the f1b
  review's argument, and B adds no path to it.
- **What step 0 decides.**
  - A 9aa337c cell marked red that measures green turns that test from red-first into a guard.
  - A late-arm result that breaks the rule is reported with its log. B's column does not depend on 9aa337c's.

## 3. Tests, red first

1. **Step 0, on 9aa337c.**
   - Run every row above in both orders and both drain timings.
   - The timing becomes a test argument, `drain: .inRead | .late`, built on `drainFollowUpsHeld`
     (`Engine/EngineFollow.swift:444-449`).
   - It goes on the InItsRead tests (`Tests/…/EngineFollowBarrierSpaceReadTests.swift:34`, `:120`) and on the c22
     probes promoted to tests (`.build-orchestrator/s3f-probes-c22/VerifyC22CorrectProbes.swift:207-342`,
     `:380-466`).
   - No new seam is needed.
2. **Red first, by the arm that fails on 9aa337c** (UNCONFIRMED):
   - **late:** T-F1b, T-F2b, T-F3, T-F4 and its twin, T-F8c, W-PR, W-PD-back, W-PD-back2, K19, W-HP, W-HP-d, W-HP-d0;
   - **in-read:** T-F1a, T-F2a, T-F5, T-F6, T-F7, T-F8, T-F9, W-PD;
   - **both:** W-AWAY ×2, W-DB, W-DB-off, W-BACK ×2, W-JOIN-HOP, W-JOIN-OFF, AV-off, AV-away, W-ONOFF.
3. **Guards, green today and under B:** T-F2c, T-F10, T-B11, W-HP-late, W-REL, W-TGT. A naive B, without B6's direct
   path or B2's restore, turns W-REL and W-TGT red.
4. **One-to-one changes.**
   - The setup `#require` at `Tests/…/EngineFollowBarrierReroutePinSpaceTests.swift:105-107`
     (`attemptEnd?.stamped == v3Serial`) becomes "V3's join precedes X's `.spaceEnd` in `eventsAfterFollow`".
     - The asserted answer does not change.
     - It needs a ledger line, but no `MIGRATION.md` entry, because it is not a CDN test.
   - The probe helpers' `transferSpaceEnd` reads (`VerifyC22CorrectProbes.swift:251`, `:303`) become
     `spaceWindow?.appliesAtEnd`.
5. **Risk checks.** B predicts green; step 0 re-runs them.
   - `EngineFollowBarrierSpaceReadTests.swift:85/89`, `:159/163`.
     - `isSpaceFailure` matches only `.spaceFailure` (`Tests/…/EngineFollowBarrierVerdictApplyTests.swift:37-42`), so
       the read marker still meets the awaits.
     - `read.t == [a, x]` still holds. v3 (and v3b) apply before the rename's ENOSPC, so B's R1 at E moves zz-x from H
       before the read's follow turn.
   - `:188` is an I/O end, which B does not touch.

## 4. Branches and kills

- **The rule.** Every kill is 2/2 runs per arm, by an answer, a start count or a clause, never by a hang or a time
  limit. All rows are UNCONFIRMED.
- **New `invariantViolations()` clauses,** beside `Engine/EngineCommands.swift:2300-2314`. The switch at `:2227-2245`
  gains the two new events.
  - **K-1.** A waiting `.spaceEnd` belongs to a job `failed(.nextRun)` at the marker's epoch, with `deferredAfter` set
    and in `.endWaits`.
  - **K-2.** A job in `.window` has no waiting `.spaceEnd` and no `deferredAfter`.
  - **K-3.** A `.windowApply` exists only for a job whose window is open at its epoch. It sits after that job's
    `.spaceEnd` (if any) and before its read marker.
  - **K-4.** `spaceWindow` exists only at the job's epoch. A start (`Engine/EngineDispatch.swift:739-743`) and
    shutdown (`Engine/EngineShutdown.swift:134`) clear it.
  - **K-5.** A read marker at the job's epoch waits only in `.readWaits`.
  - **K-6.** A waiting event implies an owed follow, or a drain follow-up that is scheduled or held. This is liveness:
    it lets "always defer" die by a clause.
- **K-V, a test.** In the VF order, no `.spaceEnd` or `.windowApply` is ever queued. It is read at E and at every
  adoption.

| # | Branch | Mutant | Killed by |
|---|---|---|---|
| 1 | B1 `defersToFollow` at E | never defer | T-F1a in-read (answer); T-F1b late (start count) |
| 2 | B1 | always defer | K-V; K-6 |
| 3 | B1 K19 fix | drop the `rerouteFor` check | K19's shape, both arms |
| 4 | B1 R1 at E | R1 at R | T-F8 in-read; `read.t` in test 5 |
| 5 | B2 epoch guard | no guard | W-REL with a restart before the late drain (K-1, K-4) |
| 6 | B2 take-off before the switch | switch first | W-BACK, both ends |
| 7 | B2 `attemptEnd` restore | keep it at a transfer end | W-TGT in-read |
| 8 | B2 N from `offBy` | J's interests only | W-AWAY, both ends |
| 9 | B3 only under `defersToFollow` | always | K-V |
| 10 | B3 | never | AV-away, W-ONOFF, the T-F4 twin (late) |
| 11 | B3 passed ids count as moved | moved only | W-PD-back2 |
| 12 | B3 diff | none | W-ONOFF |
| 13 | B3 the marker's stamp | the drain's reading | corner (iii) |
| 14 | B3/B6 lane from N | J's actual lane | AV-away |
| 15 | B4 read marker while markers wait | decide at once | T-F1b late (start count) |
| 16 | B4/B5 N_R | the copy at R | T-F10, both arms |
| 17 | B5 `lastError` when not failed | skip it | T-F2c (`lastError`) |
| 18 | B5 post-R work after the verdict | before it | W-HP-late |
| 19 | B6 pre-end replays inert | T20 | T-F1a in-read (start count) |
| 20 | B6 direct inputs get T20 | inert | W-REL |
| 21 | B6a by copy | the count clock | T-F4 twin, W-HP-late |
| 22 | B7 hop rule | none | W-JOIN-HOP, publication end |
| 23 | B8 `d < A_E` | `d ≤ A_E` | W-HP-d0 |
| 24 | B8 | none | AV-off |
| 25 | the start and shutdown clears | none | K-4 |

Row 2: if K-6 already holds by construction, "always" may be equivalent in answers, because the marker replays at the
next drain. It is then a survivor with evidence under 1(e), never re-killed by a hang.

## 5. REENTRANCY rows

B adds no await.

| Note | Site | Re-validated afterwards, under B |
|---|---|---|
| f-2 | `resumePoint`, `Engine/EngineFailures.swift:205-210` (ARCHITECTURE.md:476) | The lifecycle and the epoch, as today. During the sidecar read the phase may move (an in-read drain replayed the end marker), or a direct T20 may queue J (W-REL). `spaceFailed` re-reads the phase and never uses a value captured before the await. |
| f-4 | `refreshFreeSpace` in `spaceFailed`, `:566-568` (ARCHITECTURE.md:478) | The lifecycle and the epoch. The figures are a fresh snapshot. J's phase (`.endWaits`, `.window`, or queued by T20) picks B4's branch. The note's "waits for the follow" becomes "for its markers or the follow". |
| RE-S13 | `Engine/EngineDispatch.swift:1300` (ARCHITECTURE.md:445) | Unchanged. |
| none (new) | marker replays | Synchronous turns. Each re-checks the epoch and the phase (K-1 to K-5) when it starts. |

## 6. C2 estimates

- **E's turn,** both ends. It runs `recordDeferredVerdict`'s `away` scan over at most 10,000 ids (about 1 ms), then
  R1's walk, then at most 64 moves and 256 ids. The basis is `inboundWalkTurns` (3.31-3.75 ms) and
  `concentrationNotFoundTurns` (5.62 ms) in `docs/adr-drafts/s3f.md:10455` and `:10451`. That is about 5-7 ms. This
  is today's R-turn deferral moved to E, not new work.
- **R's turn** adopts the read, as today, plus an O(1) append, so it gets lighter.
- **The end marker's replay** is the existing chunked take-off, the `offBy` union and the switch: at most about
  2.5 ms.
- **An apply marker's replay** is |N| lookups (about 1 ms at 10,000 and 0.1 µs each) plus the layer's diff (about
  1 ms): about 2 ms. It ends its batch, so no batch holds two.
- **The read marker's replay** takes at most 512 ids a turn, with the verdict in the last turn: at most about 3 ms a
  turn. The basis is today's `.spaceFailure` replay.
- **B6a** does at most L lookups per id. Inside the follow's 512-id turns at L = 4, that is about 0.2 ms.
- **Memory.** Shared copies of the chain layers cost about 0. Unshared, the worst case is about 1-2 MB per layer at
  10,000 ids.
- **Off the actor.** `store.freeSpace()` (`Engine/EngineFailures.swift:686-694`) and the sidecar read stay off it.
- **BenchSync.**
  - New cases: E's turn at 10,000 (both ends), the apply marker's replay at L = 1, 2 and 4, and the read marker's
    replay at |N_R| = 10,000.
  - Re-measure `inboundWalkTurns`, `concentrationNotFoundTurns`, `sharedApplyTurns` (7.29 and 7.68 ms, `:10448`),
    `concentrationFollowTurns` and `publicationApplyTurns`.
  - All of these run against the 10 ms bar, which is not reopened.

All figures in this section are estimates.

## 7. Ruling, guard and documentation lines to lift or restate

- **`.build-orchestrator/s3f-c20-analysis/integrate-rr21.md`**
  - `:560` (no pseudo-follow): clarify. The apply marker is a drain event that moves and owes nothing: no `followOwed`
    source, VisitRemainder or InboundMove. If "pseudo-follow" covers it, lift for `.windowApply` only.
  - `:561`: kept. R1 at E keeps the guard, and the K19 fix reads `rerouteFor`, not `followOwed`.
  - `:586`: lift only for B7 in `replayJoin`. `waitingTarget` stays as it is, through B2's restore.
  - `:587` (RR-14): lift for one call in `adoptApplied`.
  - Batch placement: kept, with `.windowApply` added to "ends its batch".
- **`.build-orchestrator/s3-rulings-s3f.md`**
  - S3-R26 item 5 (i) and (ii) (`:553`, `:557`): retire the dating text.
  - S3-R27 12.2 (`:1068-1137`, e1-P1's stamp) and 12.5 (`:1232-1276`, e1-P2's count): retired. They are replaced,
    not weakened, and their probes become tests.
  - S3-R16 and S3-R19 are kept.
- **`s3-r28-orchestrator-rulings.md`**
  - N1 (the stamp's clears): moot. `attemptEnd = nil` at `Engine/EngineFollow.swift:392` stays.
  - N3 (clause (b)): retired with `metInItsAttempt`.
  - N4: restate against section 4.
  - N16: W-DB gets a route.
- **`docs/adr-drafts/s3f.md`**
  - RR-18 at `:4385` ("directly: the same answer"): restate as "J's end and read are queue events".
  - e1-P1 (`:7108-7158`, with residuals (1) and (2)) and e1-P2 (`:7159-7187`): retire.
  - `t20-m6-no-clear` (`:6511`): reword for B6.
- **Code docs**
  - `relane`'s comments: `Engine/EngineJobs.swift:299-303` and `:328-357`.
  - `metInItsAttempt`'s doc and the f-4 note.
- **ARCHITECTURE.md**
  - §7.6 (`:256`), the `insufficientSpace` row (`:273`): add "behind the barrier, at the read marker's place".
  - The f-2 and f-4 rows (`:476`, `:478`).
  - §7.10 (`:294`) does not change.
  - A grep finds no F-28 exit-deferral paragraph in ARCHITECTURE at 9aa337c. That text lives in the ADR draft.

## 8. Fixer hours (estimate)

| Part | Hours |
|---|---|
| Step 0, both arms and both orders | 5-7 |
| Core: B0, B1, B2, B4, B5 and the deletions | 7-10 |
| Apply markers and B6a | 6-9 |
| B7 | 2-3 |
| B8 | 1-2 |
| B6's direct path and W-REL | 1-2 |
| Kills and clauses | 5-8 |
| BenchSync | 2-3 |
| Tests, docs and records | 2-3 |
| **Total** | **about 31-47** |

## 9. Size and risk compared with route A (f1b plus its review's fixes)

- **Size.**
  - A takes 38-59 h, by the f1b review's must-add 8.
  - B takes about 31-47 h. Production code changes by about +400 / −120 lines, and tests grow by about +700 lines
    (est.).
- **Coverage.**
  - A keeps the window and both clocks and adds a dating rule per shape. It has no route for M2 (every T20 shape
    late) or for N (T-F10, W-AWAY).
  - B covers M1 to M5 with one mechanism and retires two clocks and their clears. It leaves the VF order untouched by
    construction (K-V).
- **B's risks.**
  - Three event kinds in the drain.
  - The virtual set N, with J's lane read from N, which is new.
  - Assignment by copy for every visit onto an open-window J.
  - W-REL's interplay with a waiting end marker.
  - W-ONOFF-PUB.
  - A wrong B3 diff stays silent unless rows 8-14 kill it.
- **Trade-off.** B is the larger conceptual change but the smaller total. A keeps more code that is already reviewed,
  but it stays open on whole classes.

## 10. Shapes left open, and why

- **W-ONOFF-PUB (new, open).**
  - VF's holder is publishing at the layer, so `rerouteOnVisit` passes or reroutes by `rerouteOnPass`.
  - B3 assumes the holder's visit moves the id.
  - A route needs the holder's state at the apply recorded in the marker (a proxy holder state). That is not traced.
- **W-HOP-DEFERRED (new, out of class).** A hop onto any deferred job's content through a later layer. It already
  happens at every deferred exit. B7 covers J only.
- **W-PROMO (new, out of class).** A pre-end replay onto a failed J skips `relane`'s downloading arm, so
  `metrics.promotions` and `setPriority` (`Engine/EngineJobs.swift:315-324`) differ from VF. It already happens at
  every deferred exit. It is a metric, not an answer, unless the ruling says otherwise.
- **W-TGT (new, closed by B2).** A move onto a transfer-end J inside its window. VF's `waitingTarget` there is nil,
  because `attemptEnd` is nil. Without the restore, B would target J.
- **W-REL (new, closed by B6, at answer level only).** Two points are still UNCONFIRMED:
  - that J's markers retire on a direct T20;
  - which `relane` callers sit outside `addInterest`. The fixer lists them.
- **G-ORIGIN (check).** Green if every T20 is decided under its event's or its marker's stamp.

## 11. Shapes whose VF answer depends on VF's timing

| Shape | Timing that picks the answer | B |
|---|---|---|
| Multi-change lazy | U answers X before or after v5's apply | one of VF's two answers |
| W-BACK-PUB | U's publication and commit land before or after R | T20, one of VF's |
| T-F4 corrected | U's start count, by whether U's attempt ends before v4's visit | not asserted; step 0 records both |
| W-ONOFF-PUB | whether the holder still publishes at the apply | open (section 10) |

For each of these, step 0 records both of VF's answers. SF matches if it gives one of them for the same inputs in the
same order.

## What the ruling must say

1. Item 1b takes route B. J's ENOSPC window becomes drain events: `.spaceEnd` at E, `.windowApply` for each apply
   adopted behind the barrier, and `.spaceFailure` at R. "Before or after the end" is queue order.
   `metInItsAttempt`, `transferSpaceEnd` and `stamped` are retired.
2. At both ends, in E's turn and before any await, J defers as `defersFailure` does under `defersToFollow`: R1 at E,
   and `recordDeferredVerdict` with the K19 `rerouteFor` fix. The window opens in every case.
3. The end marker's replay takes off `movedBefore`, sets N to VF's J at E (with `offBy`), and restores VF's
   `attemptEnd` shape for the end kind. So `waitingTarget` and `rerouteOnVisit` do not change.
4. The apply marker is VF's visit made virtually on N, with T20 under the marker's stamp and J's lane from N. It moves
   and owes nothing, and it ends its batch. `integrate-rr21.md:560` is clarified, and `:587` is lifted for one
   `adoptApplied` call.
5. Follow work onto J is assigned by copy, as B6a says: pre-end acts, marked window layers wait in the bucket, and
   post-R work goes behind the verdict. For a holder's verdict, d = A_E is after the end.
6. The verdict is given on N_R, not on the copy at R, in batches of at most 512. A J that is no longer failed gets
   `lastError` only.
7. In `relane`, follow work and pre-end replays are inert, and every other input takes T20 with no clock. A direct
   T20 retires J's markers.
8. B7's hop rule is adopted. `:586` is lifted only for `replayJoin` before J's end marker.
9. Step 0 measures every listed shape in 2 orders × 2 drain timings on 9aa337c, with the timing as a test argument.
   The bound test's setup `#require` changes one to one, with a ledger line.
10. Kills are 2/2, by answer, start count or clause. Add K-1 to K-6 and the VF-order test K-V.
11. For each shape in section 11, SF matches when it gives one of VF's recorded answers.
12. W-ONOFF-PUB is blocking with no route unless a proxy holder state is ruled in. W-HOP-DEFERRED and W-PROMO are out
    of class and go to the backlog. The new BenchSync cases decide C2. Section 7's lines are restated as listed.
