# F3b: route B for the purge cases route C does not reach (input to item 3b)

Read-only analysis at `9aa337c` (`.worktrees/s3f`). Nothing was built, run or measured for it.
- **Figures.** *Measured* figures cite the draft (`docs/adr-drafts/s3f.md`, "s3f:"). **Every other figure is an estimate** (G2), with its basis.
- **Names.** Paths are under `Sources/ZTronAssetSync/Engine/` unless given in full. "f3" is `f3-purge-route.md` and "f3r" its review; "N" is the orchestrator's S3-R28 rulings; "rulings" is `.build-orchestrator/s3-rulings-s3f.md`.
- **SDK lines (C7)** come from the macOS 27.0 arm64e `Swift.swiftinterface` (the fixer cites the iOS SDK's): `Dictionary.values` `get`/`_modify`: :7931-7936; `Values`' `startIndex`, `endIndex`, `index(after:)` and `formIndex(after:)`: :8034-8049; `subscript(position:)` `get`/`_modify`: :8050-8060.

## 0. Verdict

- **Moving per-interest bookkeeping out of the purge's turn always needs every reader to honour a mark** (§1). B-L (lazy compaction of a kept job) is e2-B′'s visit on touch, without slices. It is not authorised (N6). B-G (a mark on purged groups) is the same rule, applied to the groups. B-J1 (waiting joins left to the drain) breaks RR-5's letter and a benchmark assertion, to save 1.6-3.4 ms.
- **Only the freeing moves with no reader:** A2.3's pinned slices, extended (B-5).
- **So route B does the bookkeeping whole in the purge's turn and defers only the frees:** each kept job is withdrawn whole, by a rebuild or in place, whichever is cheaper; under `.all`, a table-order pass handles the jobs whose visits change nothing outside them, with N9's skip; waiting prefetch joins are unregistered once per token, after C-3.
- **Estimates after route C and route B** (ms, §3): `keptUnderThreeGroups` 3.1-6.2; `fourGroupJoins` 2.4-5.8; `pendingClaimGroups` 3.0-6.0; `mixedLaneGroups` 4.3-8.1 at stage B and 2.1-4.3 at stage C; `oneMemberGroupsFourPerID` 3.5-7.2 at stage C.
- **Conditions:** the table-order pass is ruled (§8.1); `mixedLaneGroups` gets stage B; `oneMemberGroupsFourPerID` gets stage C (N8). Without them, those cases' tops are 11.0-14.7 ms (§10). Only the fixer's measurements close a case.

## 1. The angle's examples, read against the code

**B-J1: a purged group's waiting joins, dropped when the drain reaches them.**
- **Design.** Under `.all`, C-3 empties each purged group's `pending`, and the joins stay unflagged and registered. At the drain, `replayJoin` (`EngineFollow.swift:981-998`) removes each entry and returns at `stillWants`, whose prefetch arm reads `groups[token]?.pending[asset] == transfer` (`:1011-1012`).
- **Readers that must honour it:** a later purge's predicate and `withdrawJoinInterest` (`EngineCommands.swift:1095-1097`, `:1129-1144`), which withdraw again to the same end state; the barrier clause's `register` and comparison (`:2219-2224`, `:2256-2257`), consistent, though a later join of the same token and id overwrites the entry (`EngineJobs.swift:131`, `EngineFollow.swift:1289`); the group, run and owed clauses (`EngineCommands.swift:1883-1889`, `:1921-1923`, `:2164-2166`), where the owed clause fires once `pending` no longer names an owed item, so owed items keep today's path; `reaches` (`EngineFailures.swift:834-846`), false as today; `stillWants`' `.system` arm (`EngineFollow.swift:1015-1016`), true, so system joins keep today's path; the run's joins and shutdown's clear (`EngineRuns.swift:604`, `EngineShutdown.swift:135`), unaffected; and the benchmark's `liveAfter == 0` (`Tests/ZTronAssetKitBenchmarks/BenchSyncCycle22Purge.swift:44`, `:366`), which fails, and changing it touches G3.
- **Answers:** equal in both orders. No join is made, and PROBE-C13-PURGE-JOIN's different answer (a waiting join the purge missed, s3f:2881-2883) does not recur.
- **RR-5:** broken in its letter. The joins stay registered until the drain, while rulings :1140 binds their withdrawal to before any drain turn.
- **Not proposed.** It saves only B-4's flag pass, and it is not e2-B′.

**B-L: lazy compaction of a kept job at its next touch.**
- **Design.** The purge marks each kept job, and the next path that touches the job compacts it first. An interest joined after the purge must survive, which needs a per-interest serial or a compaction before `addInterest` and `insertAsset`.
- **Readers that must honour it:** every reader of `interests`, `interestCounts` (`lane`, `isSingleUser`), `tokensByID` or `queueKind`: `EngineState.swift:900-1153`; `EngineJobs.swift` :131, :152, :176, :308, :410, :533-538, :573, :594, :627, :736-752, :862-863, :1139; `EngineDispatch.swift` :53, :135, :160, :298, :380, :413, :505, :610, :625, :645-648, :708, :812, :831, :914, :993, :1060, :1143, :1343-1356; `EngineFailures.swift` :263, :288-310, :366, :460, :550, :792, :809, :910, :1004; `EngineMoves.swift` :262, :329-354; `EngineFollow.swift` :932, :1268; `EngineRuns.swift` :462-469, :638, :676, :825; `EnginePresence.swift` :218, :248, :284, :350; `EngineReadmission.swift` :85, :125; `EngineCommands.swift` :373, :545, :1633-1636, :1790-1869, :1884, :1922, :2174; `EngineSupport.swift` :95; and every whole-job copy among the 211 `state.jobs[` sites (f3 §4).
- **Answers:** equal only if every such path visits first. Otherwise a move carries a purged interest and requests a purged id (M3), and a late join batch is compacted away (M2).
- **RR-5** binds every move path. A purged interest that a move turns into an owed item or a waiting join would break it.
- **It is e2-B′ at once:** e2-B′'s visit on touch (f3 §4), without slices, cursor or bound.
- **The release precedent does not carry over.** `continueReleases` (`EngineCommands.swift:389-412`; `isReleasedOnly`, `EngineDispatch.swift:296-299`) works because a released group has left `groups`, but a purged group stays registered.
- **Saving:** B-2's rebuild, 2.4-4.3 ms.

**B-G: a mark on purged groups' `pending`.**
- **Readers that must honour it:** `isSettled`, `dropMember` and `clearPending` (`EngineState.swift:1369-1397`); the member writes (`EngineCommands.swift:340`, `EngineDispatch.swift:1235`); the release and the removal (`EngineCommands.swift:358-380`, `:408`, `:1606-1618`); F-1 (`:1884`); the owed clause and check (`:2164`, `EngineFailures.swift:862`); `stillWants` (`EngineFollow.swift:1012`).
- **A registration's join is a touch too:** `pendingClaimGroups`' second group (`EngineCommands.swift:211-232`, `:264-295`).
- **Saving:** C-3's pass, 0.8-2.0 ms. Not proposed: it is e2-B′'s touch rule.

## 2. Route B: the parts, in order

Route B runs after route C's stages (N19). Each part is its own commit, under item 1's exclusivity rule: `applied`, the request, `claims` and `systemHeld` are read into locals, and every write outside the job comes after the job's access.

**B-1. Two counts.**
- `InterestCounts` (`EngineState.swift:1218-1280`) gains `prefetchWaiters` and `bulkWaiters`.
- Under `.all`, a job's lane after the purge is then O(1): user if `userInitiated > 0`, else the highest waiter lane, else none (emptied). "Nothing to withdraw" is O(1) too.
- The recount clause covers both counts (`EngineCommands.swift:1811-1814`).

**B-2. A `Job` mutator withdraws a kept job whole under `.all`:** every interest below `.userInitiated` that is not a waiter's.
- **How:** it rebuilds from the kept interests when they hold no more (token, id) pairs than the purged ones, and removes in place otherwise. The counts and `tokensByID` equal their recount (`EngineState.swift:814-816`).
- **It returns:** the removed storage (moved out), the system ids, the run's flag, and the lanes before the first and the last removal in ascending tokens (e2-A1.4, rulings :1169).
- **It drops no member.** Ensure groups sit at the user lane (`EngineCommands.swift:737`), and C-3 made the prefetch drops.
- **`IDTokens.first` may differ, unobservably:** `holdings` sorts its pairs (`EngineState.swift:1020`), and `moveItems`' items go to a heap.

**B-3. Two passes over the jobs, under `.all` only.** Other scopes keep route C's path (C-4).
- **Pass 1** runs in table order, in place, through `values[i]`'s `_modify`. It inserts and removes no key; a debug check on the count enforces this (f3r must-fix 1). No second reference to the table lives across it: it uses `startIndex` and `formIndex(after:)`, never a retained `indices` (f3r should-fix 5).
  - It classes each job:

    | Class | The job | Pass 1 |
    |---|---|---|
    | A | has nothing to withdraw (B-1) | skips it |
    | B | is kept, its lane after the purge equals its lane now, and it is not `.failed` at the user lane | runs B-2 without a settle. Today's settle (`EngineJobs.swift:424-438`) only re-lanes such a job: N9's skip for a `.queued` job at the user lane, and a no-op otherwise (`:304-373`) |
    | B′ | is emptied and claimed, and its lane before the first removal equals its lane before the last | runs C-2′ (f3r must-fix 3(i)), reading the claim from a local copy of `claims` |
    | C | is a retirement, a due re-lane, or `.failed` at the user lane (re-admission, `:359-365`) | collects its key |
- **Pass 2** visits the class-C keys in sorted order: today's sequence, route C's C-2, and B-2 for a kept job.
- **Notification:** the walk's final `notifyObservers` (`EngineCommands.swift:1065`) stands for class B's skipped settles.
- **With C-5 (stage B),** pass 1 is C-5's collection pass.
- **Probe:** before B-3, a scratch probe times the classification over `userWaiters`' 10,000 jobs, recorded with step 0's figures (N12). Above 1.5 ms, §3's table-order rows do not hold.

**B-4. Waiting joins under `.all`.**
- C-3 runs before `withdrawPurgedJoins` (`EngineCommands.swift:1016`; f3r should-fix 9). Flags are set as today (`EngineFollow.swift:1832-1849`, `:2102-2109`).
- **For a `.prefetch` join,** `withdrawJoinInterest` removes the token's whole registry map once (`removeValue(forKey: token)`). The token's later joins miss on one `UInt64` probe.
- **No drop is made,** since C-3 made it. A debug check confirms the group's `pending` is empty, or the group is gone.
- **Everything else keeps today's path:** system, run and ensure joins, owed items, and the other scopes.

**B-5. Deferred frees.**
- A2.3's pinned slices also take B-2's removed storage, C-3's `pending` storage (swapped for an empty map), and B-4's registry maps.
- A slice frees at most 512 units or 16,384 entries, whichever comes first. A larger map is freed alone.
- Shutdown drains the list in slices (f3r should-fix 6).

## 3. Cost per case (estimates)

| Unit | Cost | Basis |
|---|---|---|
| key sort | 2-3.5 ms | f3 §1, S |
| sorted visit | 0.19-0.42 µs | C-2's read (f3r should-fix 2) |
| pass-1 visit | 0.03-0.08 µs | S's 0.4-0.5 µs per job (`userWaiters`, 6.83 ms measured, s3f:7735), less the key hash, the allocation and free, and the random-order misses. B-3's probe checks it |
| B-2 rebuild, one kept interest | 0.24-0.43 µs | f3r "must add" 6 |
| freeing-list append | 0.01-0.03 µs | one move into an array |
| claim check, C-2′ and `claimHeld` insert | 0.23-0.41 µs | two `ClaimKey` hashes at 60-90 ns (`EngineState.swift:1416-1435`) |
| C-3 per group, frees deferred | 0.02-0.05 µs | f3 §3.2's 0.065-0.125, less a small map's free |
| B-4 join | 0.04-0.085 µs | a flag and one `UInt64` probe. Today's 0.28-0.46 bottom-up fits `purgeJoinsTurns(.bucket)`'s 4.99 ms at 9,216 joins (measured, s3f:7737) |
| count-0 drop | 0.02-0.035 µs | a `UInt64` lookup, then the count-0 path (SDK :15906-15913; f3r) |
| rest of a purge turn | 0.3-0.8 ms | C-1's pass, compaction, `settleRun`, `dropBindings`, spawn, notification |

| Case | Today | After route C | After route C and route B | Retires jobs? |
|---|---|---|---|---|
| `keptUnderThreeGroups` | 38-48 (f3 §3.6) | 34-39 | **3.1-6.2** = 10,000 × (0.03-0.08 + 0.24-0.43 + 0.01-0.03) + 0.3-0.8. Sorted: 6.7-13.1 | no |
| `fourGroupJoins` | 15-22 (f3 §3.6) | 9-19 (f3r should-fix 9) | **2.4-5.8** = 40,000 × 0.04-0.085 + 0.8-2.4 (the measured 4.99, less the joins' bottom-up share; H retires whole) | H only |
| `pendingClaimGroups` | not measured | 16-18 (f3r must-fix 3(b)); option (i), sorted: 6.6-12.9 | **3.0-6.0** = 10,000 × (0.03-0.08 + 0.23-0.41 + 0.01-0.03) + 0.3-0.8 | no (held) |
| `mixedLaneGroups` | not measured | 24-33 (f3r must-fix 3(a)); option (i): A 5.1-11.6, B 4.3-8.1, C 2.1-4.3 (k = 2, between `oneGroup` and `fourGroups`, with should-fix 2's tops) | A **5.4-12.4**, B **4.3-8.1**, C **2.1-4.3** | yes |
| `oneMemberGroupsFourPerID` | not measured | 8-16 at stage A (f3r "must add" 1) | A **6.8-14.7**, B **5.7-11.0**, C **3.5-7.2** | yes |

- **`oneMemberGroupsFourPerID`'s basis:** f3 §3.2's `oneMemberGroups` (A 5.7-12 with should-fix 2, B 4.9-9.1, C 2.7-5.3), then: plus C-3 over 30,000 more groups (+1.95-3.75); less B-5's deferral of C-3's frees (−1.8-3.0); plus 30,000 count-0 drops (+0.6-1.1); plus pass 1 at stage A (+0.3-0.8).
- **The twelve gated cases:** `.all` cases that retire jobs gain 0.3-0.8 ms at stage A, and nothing once pass 1 is C-5's. `oneGroupScope` is unchanged. `userWaiters` and `ensures` (class A) fall to 0.6-1.6 ms. `purgeJoinsTurns` falls to 1.2-3.2 ms. `purgeWhileOwedTurns`' drops take the count-0 path.
- **Slices:** 512 job storages take 0.2-0.4 ms, and the entry cap adds at most 0.3-0.7 ms. A lone map has at most 40,000 entries in letter, and takes 0.8-1.6 ms. About 10 MB waits at `keptUnderThreeGroups`.

## 4. Answers against today's, shape by shape

"Both orders" are `LaneDropVisit`'s; where no follow is owed, they coincide. The purge's own answer is the store's, unchanged (`EngineCommands.swift:1146-1160`).

| Shape | Today | Route B | Differences (S3-R16 item 2) |
|---|---|---|---|
| `keptUnderThreeGroups` | three withdrawals and drops per job, then a settle that re-queues it (`EngineJobs.swift:311-314`) | class B: the same interests, counts and index; C-3's drops; no re-queue (N9) | each kept job's ticket and place (N9, recorded). Waiters are served as today, and start counts are equal (P-N9) |
| `fourGroupJoins`, swept first | per join: flag, registry entry, drop | flags as today; each token's map once; drops by C-3 | none (the frees come later) |
| `fourGroupJoins`, followed first | O loses its 40,000 pairs one by one | B-2 rebuilds O from its waiter's interest. O is class B, or class C when `.failed` at the user lane, then settled as today (`EngineJobs.swift:326-365`) | none |
| `oneMemberGroupsFourPerID` | 40,000 drops, 10,000 retirements | C-3, then C-2 per job in pass 2 | route C's (f3 §3.3) |
| `mixedLaneGroups` | re-queue to bulk, then the retirement | option (i): queued jobs retire directly, downloading ones take today's path | the skipped entry's ticket and place (f3r must-fix 3(i)) |
| `pendingClaimGroups` | withdrawal, then `claimHeld` at `heldLane` | class B′: C-2′ in pass 1, the same end state | none |
| class A (`userWaiters`, `ensures`) | a visit that withdraws nothing | skipped | none |

**Why pass 1 needs no audit beyond 12.5.15's.**
- **What a pass-1 visit writes:** its job, the freeing list, and maps whose order does not matter (`heals`, `run.held`, `claimHeld`).
- **What it leaves unchanged:** a class-B job keeps its lane, state, ticket and `isSingleUser` (`EngineState.swift:911-913`), since user interests are never withdrawn; a class-B′ job keeps its lane, through `heldLane`.
- **So pass 2's callees read today's values,** apart from N9's tickets. The callees: `abandon`; `recordBreaker` → `breakerChanged` → `unblockOrigin` → `readmit`/`readmitForProbe` (`EngineFailures.swift:1026-1094`, `EngineReadmission.swift:197-217`); `isValid` (`EngineJobs.swift:615-620`).
- **What can differ** is only the state a mid-turn `notifyObservers` shows, such as introspection's interest count (`EngineCommands.swift:1633-1636`). 12.5.15's extended audit covers it.
- The review checks this list.

## 5. Tests, red first

1. **Red before the first part:** the five cases' step-0 figures (N7, N11, N12). Only the Benchmarks stage is red, and each commit names its red cases (12.5.12).
2. **Red until their own part:** T-B1's J-B ticket, until B-3 (today re-queues J-B); and T-B4's slices, until B-5. Every other assertion passes before route B and pins today's answers. Assertions run in both orders wherever a follow is owed.
3. **T-B1 `purgeAllClassesEachJob`.** One `.all` purge. Then `invariantViolations()` must be empty, and the waiters' answers are checked after the drain.

   | Job | Set-up | After the purge |
   |---|---|---|
   | J-A | user waiter | unchanged |
   | J-B | user waiter + three prefetch groups, queued | ticket unchanged |
   | J-Bd | as J-B, but downloading | no priority call |
   | J-B′ | one prefetch group + a second group's pending claim | held at its lane |
   | J-Cr | one prefetch group | retired |
   | J-Cl | bulk waiter + prefetch group, queued | re-queued to bulk |
   | J-Cd | as J-Cl, but downloading | `setPriority(.bulk)`, and paused if refused |
   | J-Cf | user waiter + prefetch group, `.failed` with a retry deadline | re-admitted, with `.retry` gone |
   | J-Cc | prefetch interest, then bulk interest + a pending claim | re-queued to bulk, and held at bulk |
4. **T-B2 `purgeAllRebuildsOrTrimsASharedKeptJob`.** **Set-up:** two shared jobs. One has a user waiter on one id and two prefetch groups over all ids (rebuilt). The other has two user-lane groups and one prefetch group (trimmed in place). **Asserts:** the interests, the counts, `tokensByID` against its recount, and the user groups' answers.
5. **T-B3 `barrierPurgeAllUnregistersEachTokensJoins`,** in both orders, at the bucket and in the queue. **Set-up:** four prefetch groups' joins wait, with a system join, a prefetch waiter's join and a user-lane group's join. **After the purge:** the four groups' joins are flagged, and the registry keeps only the waiter's and the user group's entries. The heal is forgotten, and both violation lists are empty. **After the drain:** no purged id starts, and the waiter and the user group are served.
6. **T-B3b.** A `.scope` purge of one of a group's two waiting joins: the other join is made and served.
7. **T-B4.** Slices run at 4 units, recording units and entries per slice, as `shutdownSlices` does (`EngineShutdown.swift:178`). A map above the cap is freed alone, and a shutdown comes between slices.
8. **P-N9 (N9's probe).** Kept queued user jobs, with and without the re-queue, in both orders. The answers and the start counts must be equal.
9. **Unchanged (G3):** the purge suites, and f3r must-fix 2's `.all` model-test variant, which then runs pass 1 on random states.

## 6. Branches and kills (2/2 in each order that reaches the branch)

| Branch | Mutant | Killed by |
|---|---|---|
| B-1's counts | an update dropped | the recount clause: T-B1 (J-Cl's bulk waiter), and `purgeKeepsUserLaneAndWaiterInterests`' prefetch waiter (`Tests/ZTronAssetSyncTests/Engine/EnginePurgeWithdrawalTests.swift:201`) |
| class A | forced true | T-B1: J-B keeps its groups |
| class A | forced false | Equivalent, cost only (S3-R19 item 2) |
| class B lane test | forced true | T-B1: J-Cl, J-Cd |
| class B lane test | forced false | T-B1: J-B's ticket |
| class B `.failed` test | forced true | T-B1: J-Cf |
| class B′ lane test | forced true | T-B1: J-Cc |
| class B′ | forced false | Equivalent: pass 2 reaches the same end state |
| pass 1 removes no key | a class-C job retired in pass 1 | the stale index traps (SDK :8054-8060; f3r must-fix 1) |
| B-2's choice | rebuild forced, or in-place forced | Equivalent: the same contents; `IDTokens.first` unobservable |
| B-4 per-token arm | taken for `.system` | T-B3: the heal |
| B-4 per-token arm | taken under `.scope` | T-B3b |
| B-4 per-token arm | never taken | Equivalent, cost only |
| B-4's flags | not set | T-B3: `followBarrierViolations()` |
| B-5's slices | dropped, or run in the turn | T-B4's recorded slices (e2-A2.3, rulings :1187) |

## 7. REENTRANCY rows

- **No `await` is added to the purge's turn.** RE-S26, RE-S25 and RE-S21 (`EngineCommands.swift:964`, `:977`, `:979`) and RE-S24 (`:1148`) stand.
- **The freeing slice's spawn:** "REENTRANCY: nothing — a slice reads only the freeing list, whose entries no live state references; it re-reads the list's count each slice."
- **Shutdown's drain:** "REENTRANCY: the lifecycle — the list is drained in slices before the store closes" (f3r should-fix 6).
- **C4:** route B reads no clock and draws no random number.

## 8. Lines it needs lifted

1. **12.3's "Otherwise the key sort stays"** (rulings :1188), for classes A, B and B′, on §4's argument. Pass 1 is the silent subset of e2-A2.4's two-pass table-order walk, which is gated on A7's audit. If the ruling keeps A7's audit for pass 1, the audit comes before B-3 (not estimated here). Class C stays sorted until A7.
2. **e2-A2.3** (rulings :1187): extended to B-5's storage, with the 16,384-entry cap.
3. **12.5.15's audit** (rulings :1259-1262): extended to pass 1. No purge suite may wait on a state, between job visits, that pass 1 reorders.
4. **N8 and N19:** pass 1 exists without stage B. C-2′ (f3r must-fix 3(i)) moves into pass 1 as class B′.
5. **ARCHITECTURE §7.1** (`docs/ARCHITECTURE.md:226`): no amendment. No job leaves outside `retire` (f3r must-fix 4), and B-2 keeps the counts and the index. For the doc pass: §7.1's "Every interest removal … goes through `removeInterest`" already does not hold for the purge (`Job.withdrawPurged`, `EngineState.swift:1129-1153`).
6. **RR-5** (s3f:2881-2887; rulings :1140) **and N9:** unchanged.

## 9. Fixer hours (estimates, at e2 §6's 1-1.5 h per part, the rate f3:336 uses)

| Work | Hours |
|---|---|
| B-1 | 1-1.5 |
| B-2, with T-B2 | 2-3 |
| B-3, with its probe, T-B1 and P-N9 | 4-6 |
| B-4, with T-B3 and T-B3b | 2-3.5 |
| B-5, with T-B4 | 1.5-2.5 |
| 12.5.15's extension, inventory rows, the N9 residual | 1.5-2.5 |
| about 13 mutants at about 4 min each (s3f:7652-7655), and measuring 17 cases | 2.5-4 |
| **Total** (without its review, or A7's audit if ruled) | **14.5-23** |

For comparison (f3 §5): B-L on top would add 20-30 h, and e2-B′ costs 30-50 h.

## 10. Cases that stay above 8.5 ms

By estimate, none of the five stays above 8.5 ms under the full route (§3). If a condition fails:

| Condition that fails | Case | Estimate (ms) | Why |
|---|---|---|---|
| pass 1 not ruled | `keptUnderThreeGroups` | 6.7-13.1 | the sort, plus a key hash and a random-order miss per job: 3.6-6.9 ms more |
| pass 1 not ruled | `pendingClaimGroups` | 6.6-12.9 | the same |
| no stage B | `mixedLaneGroups` | 5.4-12.4 at stage A | its sorted retirements |
| no stage C | `oneMemberGroupsFourPerID` | 5.7-11.0 at stage B | 10,000 sorted retirements and 40,000 group visits |

- `mixedLaneGroups`' 8.1 ms top is 0.4 ms below the edge, so N8's trigger should take its stage-B figure.
- The next lever for any case is e2-B′ or B-L. Neither is authorised.

## What the ruling must say

1. **Item 3b is route B's B-1 to B-5,** in order, after route C's stages (N19). Each part is one commit, under item 1's exclusivity rule. e2-B′, B-L, B-G and B-J1 are not authorised.
2. **Pass 1 runs under `.all`, in table order, for classes A, B and B′ only.** This amends 12.3's "Otherwise the key sort stays". It changes no key (a debug check), and no second reference to the table lives across it. Class C stays sorted. Pass 1 becomes C-5's pass when stage B lands. B-3's probe comes first.
3. **Class B uses N9 as ruled.** P-N9 runs in both orders, and the place difference is recorded. A job `.failed` at the user lane stays in class C.
4. **B-2 withdraws a kept job whole,** by a rebuild or in place, whichever is cheaper in (token, id) pairs. The counts and the index equal their recount, and `IDTokens.first` is recorded as unobservable.
5. **Under `.all`, C-3 runs before `withdrawPurgedJoins`, and joins are flagged as today.** A `.prefetch` join's token is unregistered whole, with no drop. System, run and ensure joins, and owed items, keep today's path. RR-5 holds in its letter.
6. **B-5 extends e2-A2.3's pinned slices.** A slice frees 512 units or 16,384 entries, and a larger map is freed alone. The slices are recorded. Shutdown drains in slices. §7's REENTRANCY rows apply.
7. **12.5.15's audit covers pass 1.** The ruling also says whether A7's audit is required (§8.1).
8. **The kills are §6's,** 2/2 in each order that reaches the branch. Each Equivalent is recorded, with its reason.
9. **The five cases are judged after item 3b's last part.** Every purge case is measured, best of 3, with loads. A miss is blocking, with no route (N9). Commits name their red cases (N11).
10. **The draft records, per case,** whether it retires jobs, which pass handles each class (N8), and pass 1's probe figure.
11. **Hours (estimate):** 14.5-23 h, not counting the review.
12. **Every figure not cited as measured is an estimate.** Only the fixer's measurements close a case.
