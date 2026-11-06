# D3: one id held by 10,000 interests (PROBE-C21-HOLDERS)

This is a read-only analysis for the orchestrator and the owner. Nothing was built, run or changed. Code citations are
`path:line` at `d5b2ab9` in `.worktrees/s3f`; the last code commit is `e599ae1`. Every figure marked UNCONFIRMED is
arithmetic on measured figures, not a measurement of this shape or of patched code.

## 0. The answer in brief

- **The cost.** The turn costs 3.90 µs a holder with user waiters (39.01 ms / 10,000) and 4.10 µs with one-member
  groups (40.98 / 10,000). It is the same path, at the same cost per pair, as profile-40ms's shape 3: the superseded
  publication's unbounded `supersede`, 40.21 ms for 10,000 pairs. About 2.5 to 2.9 µs of each holder's cost is
  `addInterest` on O. About 0.9 to 1.1 µs is `reroute`. About 0.25 µs is `supersede`'s own walk over H's interests.
- **(a) Branch-free cuts.** They take the shape to about **21 to 24 ms**, still more than twice `c2Budget`. Even a
  bulk join path, which is not branch-free, would reach at best about 7 to 9 ms at 10,000 holders, and it grows with h.
- **(b) Bounding one id's holders.** This is feasible as a change of unit: count (id, interest) pairs, not ids, in the
  four places that spend a turn's id budget on moves or re-routes.
  - The state between turns already exists today: holders split between H and O, with H keeping m in its ids (I2's
    re-insertion, `EngineMoves.swift:349-351`).
  - It needs **one new branch** and three changed operands. It reverses one accepted rule: "an id taken whole"
    (S3-R26 answer 7; `integrate-rr21.md`'s "Own 8", R8 and D8).
  - It is one cycle of work, at medium risk. The expected figure is **about 3 to 4 ms best** for PROBE-C21-HOLDERS,
    over 20 turns.
- **(c) The same mismatch elsewhere.** Every site that takes "an id whole" breaks the same way: the visit's move (both
  branches), the bounded rest, the owed inbound moves, and the drain's replay of RR-21's three sites. It also breaks
  without a hot id: **10,000 ids with k ≥ 4 interests each** (for example four groups over every id) cost an estimated
  9 to 10 ms a follow or drain turn today (UNCONFIRMED). That shape is arguably inside S3-R25's letter ("many groups").
  - Three sites count interests, not ids, and pair counting does not change them: the commit's and the verdict's
    answers, `answerPresentMembers`, and the purge's withdrawals. For one id × 10,000 they cost about 4 to 6 ms, about
    13 to 14 ms (already open item 5), and an estimated 17 to 33 ms (no figure; UNCONFIRMED).
- **(3) Scope.** By S3-R25's letter (10,000 *ids*), the shape (2 ids) is outside the reference set. ZTronCarousel's
  request paths make tens of interests on one id plausible, and at worst a few hundred, not 10,000.
  - My recommendation: the owner sizes the reference set's per-id dimension, as answer 4 sized the subscribers.
  - Whatever the owner rules, implement (b): it also closes the k-interests-per-id class. With (b) in place, the
    10,000-holder move passes without needing the scope ruling.

## 1. Per-holder cost, by part

### 1.1 The path

1. `follow` reads `visitMoves`: H holds only m, so moved = {m} (`EngineFollow.swift:1187-1199`, `:1205-1219`).
2. `startMove`: `moved.count (1) > budget` is false, so it calls `move` with no bound (`EngineMoves.swift:258-259`).
3. `move`: `moved.count == job.assets.count` and H is not publishing, so it takes the supersede branch. It calls
   `abandon`, then `recordBreaker`, then `supersede(transfer, settling: false, listing:)` with **no `bound`**
   (`EngineFollow.swift:1233-1246`).
4. `supersede` (`EngineDispatch.swift:1322-1355`):
   - `removeAllInterests` and `removeJob` (O(1) per holder: the index is dropped whole);
   - the listing check `contains(where:)` over every interest's ids (`:1329`);
   - `bound == nil`, so `job.interests.keys.sorted()` (`:1341`);
   - per token, `job.interests[token]` (`:1343`) and `interest.assets.sorted()`, a one-element array (`:1345`);
   - then `reroute` per pair.
5. `reroute` (`EngineDispatch.swift:1203-1250`):
   - `applied.entry(for:)` with an entry copy;
   - `isBound(asset, to: entry.transferID)`, format 1 (`:1220`);
   - for a waiter, the `waiters[token]` copy, `waiter.transfer = entry.transferID` (format 2) and the write-back
     (`:1226-1231`);
   - for a group, `groups[token] != nil` and `groups[token]?.pending[asset] = entry.transferID` (format 2, `:1233-1236`);
   - then `addInterest`.
6. `addInterest` (`EngineJobs.swift:127-200`):
   - `let transfer = entry.transferID`, format 3 (`:128`);
   - the visit check, which copies O's whole `Job` (`:137`);
   - `let now = self.decisionNow()` (`:144`), used only by the creation branch (`:160`);
   - `noteJoin`: a copy lookup and `sameTransfer`;
   - `if let job = self.state.jobs[transfer]`, a second `Job` copy (`:151`);
   - `assets.insert` (a no-op after the first);
   - `interests[token] != nil`, then `setInterest(JobInterest(..., assets: [asset]))`: the counts, the index's
     `others.insert` into a set growing to 10,000, the one-element `Set` allocation and the interests insert
     (`EngineState.swift:903-923`, `:1085-1088`);
   - `isCircuitParked` (`:189`);
   - `relane`, a third `Job` copy; O is downloading at the same lane, so it returns at once (`EngineJobs.swift:284-...`);
   - `failFastJoiner`, two or three state reads (`EngineJobs.swift:243-...`);
   - `notifyObservers`, two empty-table checks.

### 1.2 Estimates

The estimates are UNCONFIRMED. They are calibrated on profile-40ms §4's micro-timings and §3's shape-3 shares,
normalised to the measured 3.90 µs (waiters) and 4.10 µs (groups).

| Part | µs per holder | Where |
|---|---|---|
| Transfer-id formatting, 3 per pair | 0.63 to 0.75 (3 × 0.21 to 0.25) | `EngineDispatch.swift:1220`, `:1229`/`:1235`, `EngineJobs.swift:128` |
| `decisionNow()`: a whole-`EngineState` copy and its destroy per join | about 0.5 (profile: 12.8 % of shape 3) | `EngineJobs.swift:144` → `EngineFollow.swift:272-274`. Still called on every join at `d5b2ab9`; the profile was at `8e1fb24` and the line is unchanged since (UNCONFIRMED that the copy is still emitted) |
| Jobs-table accesses and `Job` copies (about 9 to 12 hashed accesses: `:137`, `:151`, the in-place writes, `relane`, `failFastJoiner`) | about 1.0 to 1.1 (profile: 1.09 µs per id in shape 3) | `EngineJobs.swift:137-198`, `:243-262`, `:284-290` |
| Manifest lookup and entry copy (`reroute`, `noteJoin`) | about 0.35 | `EngineDispatch.swift:1214`, `EngineJobs.swift:206` |
| Insertion on O: `setInterest` with the counts, the index and the `JobInterest` set allocation | 0.3 to 0.45, of which **the index** is 0.05 to 0.1 | `EngineState.swift:903-923`, `:1085-1088` |
| Removal from H | about 0 (`removeAllInterests` drops interests, counts and index whole; `removeJob` is O(1)) | `EngineDispatch.swift:1327-1328` |
| Sorts: `keys.sorted()` of 10,000 `UInt64` tokens, and 10,000 one-element `assets.sorted()` | 0.13 to 0.2 | `EngineDispatch.swift:1341`, `:1345` |
| `supersede`'s listing check (provably false on the visit path: every moved id maps elsewhere) | about 0.1 (profile: 1.0 ms at 10,000) | `EngineDispatch.swift:1329` |
| Waiter's write (`waiters[token]` copy and write-back) | about 0.2 to 0.3 | `EngineDispatch.swift:1226-1231` |
| Group's write instead (`groups[token]?.pending[asset] =`, in place) | about 0.25 plus the extra lookup, which accounts for the +0.2 µs of the groups variant | `EngineDispatch.swift:1233-1236` |
| Retain/release and value destroys passed down `supersede` → `reroute` → `addInterest` | about 0.35 | profile: "everything else", 9.5 % |
| **Per-holder events** | **0**. Terminal and progress events are per id (`publishTerminal`, `onProgress`), not per interest, and a join publishes none | |
| **Sum** | **about 3.6 to 4.3** (measured: 3.90 and 4.10) | |

## 2. The three questions

### 2(a) Branch-free cuts

Each cut keeps today's calls and order. The savings are profile-40ms §6's shape-3 column, the same function. The
holders-specific savings are estimated.

| Cut | Change | Saving at 10,000 |
|---|---|---|
| A1. Stop calling `decisionNow()` on the join path | Move `let now = self.decisionNow()` (`EngineJobs.swift:144`) into the creation branch, where `now` is used (`:153-160`). It is a pure read, so moving it is a move, not a branch | −5.1 ms |
| A2. Format each transfer id once per pair | `reroute` computes `let target = entry.transferID` once and passes it to `addInterest` through a new internal parameter. `addInterest` is internal, so S3-R6 does not apply. This replaces `:1220`, `:1229`/`:1235` and `EngineJobs.swift:128` | −4.3 ms (2 of 3 formats) |
| A3. One jobs-table read per join | Read O's `state`, `attemptEnd`, `lane` and `isReleasedOnly` in one scoped access; `:137` binds no `Job` copy. `failFastJoiner` and `relane` keep their conditions but read through one projection | −7.5 to −8 ms |
| A4. The holders-specific cuts in `supersede` | Iterate `interest.assets` without a per-token sort when the interest holds one id. That is a new branch, so it is excluded from "branch-free". The listing check needs a flag (also a branch) | −0.5 to −2 ms, not branch-free |

- **Expected figure:** 39.01 × (1 − 0.42) ≈ **22.6 ms** with waiters, and 40.98 × (1 − 0.42) ≈ **23.7 ms** with groups.
  A1 to A3 are 16.9 to 17.4 ms of shape 3's 40.21, which is 42 to 43 %. With A4 the figures are about 21 to 22 ms.
  This is UNCONFIRMED: arithmetic on shares measured at `8e1fb24`, and the index's upkeep was added since.
- **A bulk join is not branch-free and not recommended.** It would join all of one id's tokens to O in one `Job` access,
  with the per-id work (entry, formats, `isBound`, `noteJoin`, `relane`, notify) hoisted. Its floor is about 0.6 to
  0.9 µs a pair: the waiter or group write, the interest insert, the index and the set allocation. That gives about 6
  to 9 ms at 10,000, still O(h) in one turn, and it misses at about 12,000. Each side effect of `addInterest` would need
  a per-pair fallback with its own branch and test: a parked O's fail-fast answer per joiner, a waiting verdict's
  bucket, released-only reinstatement and the circuit order.
- **Cuts A1 to A3 are worth taking as margin** whatever route is chosen. Every per-pair path pays them, including the
  cases at the edge: `commitTwoTokensTurns` 8.82 ms, and the drain turns. They are not a C2 route for this shape.

### 2(b) Bounding one id's holders over turns: pair counting

**The state between turns.** Use "holders split between two jobs". Do not use "the id off the job while holders still
hold it": that breaks I2, and a later publication, verdict or visit of H would not see m.

- In the split state, H keeps m in `Job.assets` while any holder remains. `continueMove` already re-inserts it after an
  id's items, when `tokensByID[m] != nil` (`EngineMoves.swift:349-351`; B8 and I2, reached today by B-T5's join shape).
- The moved holders are on O.
- For an owed batch, the remaining items stay in the batch, on no job. That is today's owed state (D3, owner stasis):
  their owners still name `from`.
- So the state is the one today's whole-id rests create for the ids not yet moved, applied to one id's tokens.

**The changes.** There are four sites. Only the first adds a branch.

| # | Site | Today | Change | Branches |
|---|---|---|---|---|
| P1 | `continueMove`, `EngineMoves.swift:311-344` | `spent += 1` per id. The guard `spent < budget` is checked only before an id (`:313`), and the inner loop (`:318`) takes all of the id's items | Spend per item. The inner loop becomes `while spent < budget, let item = progress.first, item.asset == asset { _ = progress.popFirst(); spent += 1; … }`. Keep the outer guard at `:313`, which still stops a new id from starting at the bound, the removal at `:317` and the re-insertion at `:349-351`. A partly moved id goes back into H's ids, with its remaining holders | **+1** (the inner condition) |
| P2 | `startMove`'s fit test, `EngineMoves.swift:258-263` | `guard moved.count > budget else { move(...) }`, with `spent = moved.count` | Read `built = job.moveItems(of: moved)` first (it is already read for the bounded path, `:262`). Fit when `built.items.count + built.unheld.count <= budget`, and return that count as `spent`. When every id has at most one holder, this is today's `moved.count`, so k = 1 paths and figures are unchanged. `move`'s supersede and holdings branches are then reached only when their pairs fit | 0 (operand) |
| P3 | `continueReroutes`, `EngineFollow.swift:742-764` | The guard `spent < drainIDsLeft` sits inside `if item.asset != current`, so an id is taken whole (R8) | Check the guard per item, before the `if`, and spend per item. `current` and `listing` stay local, so a split id's second turn reads `rerouteListing` again: the copy at its replay, as two ids of one batch do today (ruling 12, answer 6.3's class) | 0 (the guard moves) |
| P4 | Site 2's charge, `takeOffMovedBefore`'s return, `EngineFollow.swift:614` | `return (off.items, off.ids)`, distinct held ids, charged at `:391` and `:888` | `return (off.items, off.items.count)`. One line covers both callers; rename the label if wished (it is internal) | 0 (operand) |

These sites are already right and need no change:
- Site 1's fit charge counts pairs: `locations.count + rerouted` (`EngineDispatch.swift:1164`).
- Site 3's bound counts pairs: Σ `interest.assets.count` (`:1334`).
- Their replays go through P3.
- `continueInbound` (`EngineFollow.swift:1504-1546`), `followAfterVerdict` and `continueVisitRemainder` (`:1101-1123`)
  go through P1 and P2, and subtract `spent` from the same budgets.

**Expected figures.** All are UNCONFIRMED.

- PROBE-C21-HOLDERS, both groupings:
  - ⌈10,000 / 512⌉ = 20 follow turns, or 21 if the first runs in the apply's turn at `inboundIDsNow = 256`;
  - each turn about 512 × 3.9 to 4.1 µs = 2.0 to 2.1 ms of re-routes, plus turn overhead, giving 2.4 to 3.0 ms. The
    drain's 512-pair held turn measures 2.42 ms (`concentrationCommitRerouteTurns`);
  - the first turn adds `moveItems` and `MinHeap` heapify over 10,000 items, about 0.5 to 1 ms;
  - heap pops add log₂ 10,000 ≈ 14 comparisons, about 0.2 µs a pair, about 0.1 ms a turn;
  - heartbeat best **about 3 to 4 ms**, and about 2 ms with A1 to A3.
- Site 3 at one id × 10,000 (owed batch): about 512 × 4.8 µs ≈ **2.5 ms** a drain turn (`commitTwoTokensTurns`: 4.89 ms
  for 1,024 pairs).
- Site 2 at one id × 10,000: the verdict's turn keeps the O(h) take-off (`Job.takeOff`, about 3 to 7 ms; compare
  `movedBeforeDrainWaitersTurns`' 7.11 ms verdict turn at 10,000 waiters) and owes the re-routes, which then take
  about 2.5 ms a drain turn.
- k = 4 over 10,000 ids: 512 pairs (128 ids) a turn, about 2.3 to 2.5 ms, over 79 turns instead of 20.
- k = 1: unchanged turns and figures.
- k = 2: drain turns about 2.5 ms instead of 4.89 ms, and twice as many turns.

**The correctness argument.**

1. **No new kind of state.** Every reader of a rest keys either on (token, id) or on `Job.assets`:
   - the rest's heap, D3's owner stasis, `waiter.transfer`, `group.pending[asset]`;
   - `findInbound`, `recordDeferredVerdict`'s `away`, `rerouteOnPass`, `takeOffMovedBefore`'s `held`.

   H keeps m in its ids while a holder remains (I2), so each reader sees m on H exactly as it sees an id not yet moved
   in today's whole-id rest. An id on two jobs at once already exists today (B-T5's shape).
2. **What can happen to O between two turns of a split id.** Each case rides today's machinery:
   - *O commits.* O can, since only the holder is held (`inboundBlocks`, `EngineFollow.swift:1459-1467`). The first
     half is answered by the commit. The second half is re-routed, finds `isBound(m, O)` and is answered from the store
     with the same content. Visit-first answers all of them with O's commit: the same answer. Today a whole id not yet
     moved instead gets a fresh job (RR-16's class). With the split it gets no extra request.
   - *O fails.* The verdict defers, because a follow is owed. `bringInbound(O)` → `findInbound` walks H, finds m in H's
     ids mapped to O's content and owes an `InboundMove`. `continueInbound` runs first in the next turn, so the
     remaining holders join O before its verdict. Visit-first gives the same answer.
   - *An apply while O publishes.* `bringInboundOntoPublications` brings the remaining holders onto O under the outgoing
     copy, and O's binding waits (`inboundOnto`), as RR-14 does. The answers are the same.
   - *A holder withdraws.* The removal is an event behind the barrier, so the case is unchanged.
3. **H between turns.**
   - When H is superseded, it is abandoned and queued behind the barrier: `pump` admits nothing while `followOwed`, so
     H cannot start a request.
   - When H keeps other ids, its publication waits (`followMoving?.holder == H`).
   - R-SYN-4 (single-flight) holds: there is one job per content, and the remaining holders cannot make a second
     request for m's old content.
4. **Owed batches.**
   - The global hold (D2) keeps every publication from binding while `reroutesWaiting > 0`, so O cannot commit between
     two drain turns of a split id.
   - A pin's target that leaves its end between those turns gives the second half the copy at its replay. That is the
     class ruling 12's answer 6.3 already accepts for different ids of one batch, held to its condition (an answer that
     differs with the event before both answers, or after both, is blocking).
   - D7 (order), D9 (liveness: "a drain turn with ids left makes at least one item") and "owed ≠ nil ⇒
     `drainIDsLeft == 0`" all hold with the per-item guard.
5. **Why ids were kept whole.** `integrate-rr21.md`'s "Own 8" gives the reason: "would answer the same id at two
   instants". That is the timing class of S3-R16 item 2 ("when an answer arrives within the barrier and its drain"). I
   found no SPEC MUST that ties one id's holders to one instant: R-SYN-4 is about transfers, and it holds.
6. **Invariants.**
   - Unchanged and holding: I1 (the index), I2 (interests' ids within the job's ids), I3 (no empty interest), the
     `followMoving` exemption of the "not in unfollowed" clause (`EngineCommands.swift:1830-1835`), the waiter clause
     ("an interest only in the job it names") and the counts.
   - No new clause is needed: I2 is the split state's invariant and now has a second path to it.

**The clauses and rulings it touches.** The ruling has to say each of these explicitly.

- S3-R26 answer 7, "an id taken whole": reversed, for the follow and the drain.
- `integrate-rr21.md`:
  - R8, R9 and the `continueReroutes` text ("each id with all its tokens") become "at most `drainIDsLeft` pairs a turn;
    an id's tokens may span turns";
  - D8 (Bounds) becomes pairs in its first and third bullets;
  - R7's step (3) charges `off.items.count`;
  - "Own 8" is withdrawn;
  - the residual "One id with k tokens costs k re-routes in one id slot" is closed.
- `integrate-c21.md` item B's residual 5 is closed by the pin. Its must_nots still hold, since P1 keeps them:
  - "Do not move :195. Do not re-derive items between turns. Do not merge move with continueMove."
- The `continueMove` and `followIDsPerTurn` doc comments (`EngineMoves.swift:228-235`, `:282-294`) change: the unit is
  an (id, interest) pair, and an id no interest holds counts one.
- S3-R22 item 1 and S3-R25 item 1 ("ids per turn") are read as pairs. For k = 1 that is the same number.
- I1 to I3 and D1 to D7 and D9 to D12 are unchanged.

**The tests.**

- **Deterministic tests** (SPEC 7.2 names, `.timeLimit`, both `LaneDropVisit` orders, answers equal visit-first's,
  `invariantViolations()` and `followBarrierViolations()` empty after every held turn):

  | Test | Shape | What it asserts | Mutants it kills (2/2) |
  |---|---|---|---|
  | PAIRS-T1 | `followIDsPerTurn = 4`; H holds only m; m is held by 10 interests (6 user waiters and 4 one-member groups); v3 maps m to O's content | each follow turn moves at most 4 interests (O's and H's interest counts between held turns); m stays in H's ids while H holds an interest in it; at the end O holds m with all 10, and H is removed | M-split-inner (P1's inner condition dropped: 10 in one turn); M-fit-ids (P2 reverted to `moved.count`: `move`'s supersede makes all 10 at once); B8's re-insert drop (I2 breaks between turns, a second killer besides B-T5) |
  | PAIRS-T2 | as T1, but H also holds id k, which its own interest keeps | as T1 | M-fit-ids on `move`'s holdings branch |
  | PAIRS-T3 | site 3: a superseded publication of one id with 10 holders, `drainIDsLeft = 4` | at most 4 re-routes a drain turn; `reroutesWaiting` reaches 0; the answers | M-reroutes-guard (the guard back inside `if item.asset != current`) |
  | PAIRS-T4 | site 2: a verdict's take-off of one id × 10 holders at the edge | the verdict's turn makes 0 re-routes and owes them (RR21-VERDICT-ZERO's form), then at most 4 a drain turn | M-charge-ids (`off.ids` back at `:614`) |
  | PAIRS-T5 (probes) | between two turns of a split id: (i) O commits; (ii) O fails with a 404; (iii) an apply while O publishes; (iv) a remaining waiter cancels; (v) a pin end between two drain turns of one owed id (PROBE-RR21-PIN-END with the id split) | answers only (G4). A break is blocking, and P3 applies (the failing test first) | none |

- **BenchSync cases** (best of 3 ≤ `c2Budget`, at a 1-minute load of 10 or less):
  - `manyHoldersMoveTurns`, users and groups: PROBE-C21-HOLDERS committed. Expected about 3 to 4 ms.
  - `manyHoldersOwedTurns`: site 3 at one id × 10,000. Expected about 2.5 ms a drain turn; the heartbeat includes the
    exit's own turn.
  - `manyHoldersTakeOffTurns`: site 2. Expected about 5 to 8 ms, the verdict's own turn; at the edge is possible.
  - `manyHoldersCommitTurns`: O's commit with 10,001 interests on two ids (§2(c), row 9). Expected about 4 to 6 ms.
  - `fourGroupsFollowTurns`: 10,000 ids × 4 groups, a visit's rest and an owed batch. Expected about 2.5 ms a turn
    after the change, and an estimated 9 to 10 ms before it (take the "before" figure first).
- **Re-measure** `commitTwoTokensTurns`. Its drain turn should drop from 4.89 to about 2.5 ms; its 8.82 ms heartbeat is
  the commit's own turn and should not move.
- **Existing tests that change path** (G3 and S3-R16 item 4 need the ruling to authorise one-to-one updates, as S3-R26
  item 1 did for the fit charge). Low-budget tests with k ≥ 2 change their turn counts:
  - `drainReroutesAnOwedIDWithAllItsTokensInOneTurn` (`EngineFollowBarrierRerouteCommitTests.swift:305`): `made` goes
    from `[4, 2]` ids to `[2, 2, 2]`, `!run.split` still holds, and the display name ("counting ids, not interests") is
    inverted;
  - `barrierBoundsOneIDMovesOffAHolderPerTurn` (`EngineFollowBarrierMoveHoldersTests.swift:188`, 8 ids with 2 tokens
    each);
  - probably some `waitersAndGroup` shapes in the RerouteSupersede, RerouteOwner, RerouteInvariant and RerouteLayer
    tests;
  - the doc of `BenchSyncReroutePins.commitTwoTokensTurns` ("1,024 interests of 512 ids").

  The exact list is UNCONFIRMED; the fixer lists every one. No answer, MUST or invariant assertion may change. If one
  does, that is a finding.

**New branches:** one, P1's inner condition. P2 and P4 change operands, and P3 moves a guard. Each of them has a
revert mutant in the table above.

**Cycles and risk.** One fixer cycle, if the PAIRS-T5 probes hold, and one more if a probe breaks S3-R16 item 1.
- The code is about 20 lines in two files.
- Most of the cost is the tests: 5 mutants × 2 whole-Sync runs, 5 benchmarks and 5 probes in both orders.
- The risk is medium. The code reuses machinery that whole-id rests already exercise. The uncertainty is in readers not
  yet audited for a split id (below).

### 2(c) Other sites where the bound counts ids and the cost counts pairs

| # | Site | Bound counts | Expected at one id × 10,000 today | With pair counting (b) |
|---|---|---|---|---|
| 1 | A visit's `move`, supersede branch (`EngineFollow.swift:1240-1246` → `supersede` with no bound) | ids (`startMove` `:258`) | **39.01 / 40.98 ms** (measured) | about 3 to 4 ms over 20 turns |
| 2 | A visit's `move`, holdings branch (a holder that keeps other ids: `holdings` + sort + `removeAsset` / `reroute` / `removeInterest` per pair, `:1247-1255`) | ids | about 45 to 55 ms (UNCONFIRMED: `removeInterest` → `dropInterest` → `settleRemoval`/`relane` per pair on top of row 1) | as row 1 |
| 3 | A bounded rest (`continueMove`, a visit of more than 512 ids that includes m) | ids (`EngineMoves.swift:313`) | at least 10,000 pairs in m's turn: about 45 to 50 ms | as row 1 |
| 4 | Owed inbound moves (`continueInbound` → `startMove`/`continueMove`; `makeInboundNow` at `inboundIDsNow`) | ids | as rows 1 to 3, about 40 to 50 ms; in an attempt's end or apply turn, which also walks every job | bounded |
| 5 | RR-21 site 1 (the commit's re-routes): the own turn charges pairs (`EngineDispatch.swift:1164`) and owes; the **drain's replay** takes m whole (`continueReroutes`, `EngineFollow.swift:748`) | own turn: pairs ✓; replay: ids | replay about 10,000 × 4.8 µs ≈ **48 ms** | about 2.5 ms a drain turn |
| 6 | RR-21 site 3 (the superseded exit): the own turn charges pairs (`:1334`) and owes; the replay is as row 5 | as row 5 | about 48 ms (profile shape 3 measured the at-once form at 40.21 ms) | about 2.5 ms a drain turn |
| 7 | RR-21 site 2 (the verdict's take-off): `chargeTakeOff(off.ids)` sees 1 id, so it fits, and the 10,000 re-routes are made in the verdict's turn (`EngineFollow.swift:391`, `:888`, `:614`) | ids | the take-off (about 3 to 7 ms) plus 10,000 re-routes: about 45 to 55 ms (profile shape 2: 44.92 ms for this path at 10,000) | the verdict's turn keeps the O(h) take-off, about 5 to 8 ms; the re-routes are owed |
| 8 | The drain's replay (R8), generally | ids | rows 5 to 7 | pairs |
| 9 | A commit's answers: the fit charge counts `locations.count` (ids bound, 2 here), and `resolveAll` delivers to every interest (`EngineJobs.swift:688-726`) | ids for the charge; nothing bounds the answers (Phase 2 owes only the resumes) | 10,001 deliveries plus 2 terminal events: about **4 to 6 ms** (UNCONFIRMED; `commitTurns(.waiters)` is 7.27 ms for 10,000 waiters on 10,000 ids, which also pays per-id events, location lookups and retires). A stalled subscriber adds only 2 events. The charge's undercount adds at most `inboundIDsNow` re-routes, about 1.2 ms | unchanged (not a move site). Optionally charge `job.interests.count` instead of `locations.count`: identical for k = 1, and it removes the +1.2 ms. Measure `manyHoldersCommitTurns` first |
| 10 | The verdict's answers (`giveVerdict` → `resolveAll`, a failure) | nothing | about 4 to 6 ms, as row 9 | unchanged |
| 11 | `answerPresentMembers` (the bind and answer of present ids) | rows: one per (interest, id) | one id × 10,000 waiters is 10,000 rows: about **13 to 14 ms**, PROBE-C21-APM's waiter case (13.27 to 14.17). Already open item 5, the same class | unchanged; item 5's own route |
| 12 | The follow's visits and moves: `followsPerTurn = 256` visits and `followIDsPerTurn = 512` ids (`EngineFollow.swift:11`, `:116-135`) | visits and ids | Not the D3 shape, but the same mismatch: **256 one-id jobs × 40 holders** = 10,240 pairs, about 41 to 46 ms; **10,000 ids × k = 4** = 2,048 pairs a turn, about 9 to 10 ms; k = 5, about 11 to 12 ms (UNCONFIRMED) | at most 512 pairs a turn |
| 13 | The join gap and the drain's joins (`replayJoin`, one pair per event; buckets at most 512 a batch) | events, which are pairs | 512 × about 4 to 5 µs ≈ 2 to 2.5 ms a drain turn: **met** | unchanged |
| 14 | The purge: `withdrawPurged` (`EngineCommands.swift:992-1040`) | nothing: one turn | For 10,000 one-member groups on m: a sort of 10,000 interest tuples (`:1012`), then per group `dropGroupMember` + `removeInterest`, probably with one copy-on-write of H's interests and index (the `job` copy is alive at `:1006-1012`). Estimated **17 to 33 ms** (UNCONFIRMED, no figure). User waiters are skipped (`:1012` filter), so one id × 10,000 waiters costs only the sort, about 2 to 3 ms. The same O(pairs) holds for 10,000 groups on 10,000 ids, so this is a reference-set row with no BenchSync figure today. The owed-batch walk (`withdrawPurgedJoins`) at 10,000 items is `purgeWhileOwedTurns`' 9.15 to 9.57 ms, at the edge and blocking (open item 2) | unchanged; needs its own bound (out of D3's scope) |
| 15 | Shutdown: `drainEverything` takes waiters and groups in one turn (sorted keys); `settle` answers 512 a turn; the job table is freed 512 jobs a turn (`EngineShutdown.swift:46`, `:170-215`) | callers / jobs | The same as 10,000 waiters on 10,000 ids (S3F-4's case). The one job of 10,001 interests is one free step, about 1 ms: **met** (UNCONFIRMED) | unchanged |
| 16 | `inboundPendingIDs` (`EngineFollow.swift:1434-1451`) walks the owed moves' heaps per item | items | about 0.3 to 0.5 ms a call with one `InboundMove` of 10,000 items. Called by `findInbound` and `followedLane` | unchanged (a row, not a miss) |

Rows 1 to 8 and 12 are one defect: ids are taken whole while their work is priced per pair. Pair counting fixes them all.
Rows 9 to 11 and 14 count interests, not ids, in turns that no id bound splits, so pair counting does not touch them.

## 3. The scope question, for the owner

### 3.1 For counting 10,000 holders of one id as inside the reference set

- C2 is a per-turn standing order, and the cost here is per interest. The shape has the same 10,000 interests as "one
  user waiter per id", which S3-R25 item 2 put inside the set "however their interests are grouped".
- The ruling already made it blocking. S3-R26 item 10 recorded `integrate-c21.md` B's residual risks with their
  conditions, and residual 5 says "blocking if a case with h near 10,000 misses". The fixer reported it as blocking.
- The library sets no limit on concurrent `resolve` calls or handles for one asset. An app bug (a re-render loop that
  calls `resolve`) can produce many.
- The defect is not specific to h = 10,000. The same id-for-pair pricing reaches shapes inside S3-R25's letter: 10,000
  ids × 4 groups is "many groups" (§2(c), row 12).

### 3.2 Against

- **The letter.** SPEC §6 (`SPEC.md:292`) sets N = 10,000 *assets*. S3-R25 (rulings `:342`) defines the set as
  "10,000 *ids* however their interests are grouped", and each grouping it lists has one interest per id per grouping.
  This shape has 2 ids. Its scale is callers per asset, a dimension neither SPEC nor any ruling sizes.
- **Precedent.** S3-R26 answer 4 sized another non-id dimension of the set, the subscribers, explicitly, at one. A
  dimension never sized is not implicitly 10,000.
- **Rarity.** The turn happens only when an apply changes that one asset's content while its download is in flight or
  held, with all the holders waiting on it.
- **Real use** makes h ≈ 10,000 implausible (3.3).

### 3.3 What ZTronCarousel's real use makes plausible

| Interest | How many on one id | Basis |
|---|---|---|
| User waiters | One per live view whose asset missed locally. `ZTronSVGView.attemptNetworkResolve` (`../ZTronCarousel/.../ZTronSVGView.swift:143-160`) starts one unstructured `Task` per view instance, which is **not** cancelled when the view goes away (`[weak self]`), and keeps at most one connectivity retry per instance. `BasicImagePage` does the same for images | Ordinarily 1 to 3. A shared asset shown in every visible cell (a common outline, badge or frame) gives about the visible cells, 10 to 30. **Worst case:** fast scrolling through a long carousel while that shared asset's download runs, one waiter per page passed, a few hundred. Offline, waiters do not pile up: they fail fast with `.offline` and retry singly |
| Prefetch groups | `PrefetchWindowController.update` (`Sources/ZTronAssetKit/Prefetch/Prefetch.swift:146-170`) gives one one-member handle per id in ±radius (default 2), and two at once during a re-lane (`cancel(after:)`). One controller per live carousel | 1 to 2 per controller, about 2 to 10 in all |
| Ensure groups | One per `ensureAvailable(scope:)` call in flight (`AssetClient.swift:217-221`) | 1 to 3 |
| Run claim | One `.run` interest per planned fetch, only within the pipeline plus the lookahead (R-SYN-3) | at most 1 |
| System (heal, re-attach) | | at most 1 |

- **Plausible per id:** about 5 to 15 ordinarily, a few tens with a shared asset in a grid, and at most a few hundred
  in the scroll case. Across all 10,000 ids, k is about 1 to 2 (an ensure group, sometimes a second scope or an app's
  own `prefetch` of everything). k ≥ 4 across many ids needs several overlapping large-scope handles: possible, but
  unusual.
- **Today's code handles a hot id** up to about 2,000 holders at about 8 ms (2,000 × 4 µs) and misses at about 2,500.
  That is 5 to 10 times the plausible worst case.
- **Recommendation to the owner:**
  1. Size the per-id dimension in a ruling, for example "at most 1,000 interests on any one id, and at most 2 interests
     per id across 10,000 ids". Pin both with BenchSync cases, so that the claim is measured.
  2. Separately, take (b). It makes the move and replay sites independent of h, and so it removes the need to argue
     scope for them.
  3. The answer sites stay O(interests) per turn whatever is ruled: the commit, the verdict, `answerPresentMembers`
     and the purge. The size chosen in step 1 is what keeps them within C2.

## 4. What could go wrong with (b)

1. **A reader not yet audited for a split id.** I checked the rest's readers (§2(b), points 1 to 4).
   - Not checked: whether the per-id progress keys (`lastEmitted[.transfer(m)]`) can see progress from H and from O
     for the same id. The same state exists today with B8's re-insertion. UNCONFIRMED.
   - Not checked: the run's report counts when a run claim in the second half is answered from the store
     (`countRunFetched` and `resolveHits`) rather than by O's commit. This is metrics only. UNCONFIRMED; probe it in
     PAIRS-T5 (i).
2. **Turn counts change for k ≥ 2.** Tests and benchmarks that pin per-turn id counts need one-to-one updates under
   the ruling. Any answer, MUST or invariant assertion that changes is a finding.
3. **Longer barriers.** The barrier holds about 20 turns for 10,000 holders of one id, and 4 times as many turns at
   k = 4. Admissions and run settlement wait that long. This is timing (S3-R16 item 2).
4. **Two instants for one id's holders**, the reason ids were kept whole. If a PAIRS-T5 probe shows a different answer
   with an event before both answers or after both, that is blocking, and P3 applies.
5. **The fit path builds `moveItems`, and `move` then builds `holdings`.** That is O(p) twice, but bounded by the
   budget (at most 512 pairs, about 50 µs).
6. **Item 6 does not close by itself.** The answer sites (rows 9 to 11 and 14) remain O(interests) per turn. Measure
   `manyHoldersCommitTurns` so that the commit's figure is known, not assumed.

## 5. Not confirmed

- §1.2's per-part split for this shape. It is derived from profile-40ms at `8e1fb24`, not profiled on PROBE-C21-HOLDERS.
- That `decisionNow()` still copies `EngineState` at `d5b2ab9`. The line is unchanged and the profile is older.
- §2(a)'s expected figure, 21 to 24 ms.
- §2(b)'s expected figures: about 3 to 4 ms, 2.5 ms a drain turn, and 5 to 8 ms for site 2's verdict turn.
- The figures in §2(c), rows 2 to 7, 9, 10, 12, 14 and 15.
- The exact list of existing tests whose turn counts change under pair counting.
- That no SPEC MUST requires one id's holders to be answered at one instant. I found only R-SYN-4, which is about
  transfers and holds.
- The progress-key and run-metric readers in §4, item 1.
