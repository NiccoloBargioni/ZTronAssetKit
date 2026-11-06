# E2: the purge's first turn (correct #2, reqs #4)

Read-only analysis for S3-R27 item 12, at `d5b2ab9` (`.worktrees/s3f`, branch `wp/s3f`, clean tree). Nothing was built,
run or measured for this report. A figure marked *measured* cites the verifier's probe logs in
`.build-orchestrator/s3f-probes-c21/` or the draft (`docs/adr-drafts/s3f.md`). Every other figure is an estimate. Its
basis is the code path named beside it, scaled to the measured per-job cost, using typical arm64 costs:
- a SipHash-1-3 over a 66-byte `TransferID`: 60–90 ns;
- a small-string `AssetID` hash: 20–30 ns;
- a small allocation: 50–100 ns;
- the refcount traffic of a `Job` copy: 100–150 ns.

Read every estimate as ±50%. Paths are under `Sources/ZTronAssetSync/Engine/` unless a full path is given.

## 0. Verdict

**correct #2 is real.**
- `performPurge` runs `dropBindings`, `settleRun` and `withdrawPurged` before its first await (`EngineCommands.swift:968-976`).
- `withdrawPurged` first walks every waiting event (`withdrawPurgedJoins`, `:1056-1092`). It then sorts every job key and walks every job (`:1007-1038`). All of this runs in one actor turn.
- The verifier measured it at 1-minute loads of 4.85 to 7.65 (`probe-loads.txt`):

| Probe (release, 10,000) | Measured, ms | Log |
|---|---|---|
| PURGE-QUEUED, one job per member | 54.47 / 56.29 / 54.78; 57.43 / 55.96 / 58.37 | `probe-purgeq.summary.log:2-5`, `probe-purgeq2.summary.log:2-5` |
| PURGE-QUEUED, one job of 10,000 ids | 12.20 / 12.34 / 12.25; 12.03 / 12.46 / 13.62 | the same files, `:8-11` |
| PURGE-PARTS, `withdrawPurged` alone | 54.83 / 53.86 / 67.57; shared job 13.11 / 13.16 / 12.36 | `probe-parts.summary.log` |
| PURGE-PARTS, `dropBindings` and `settleRun` | 0.00 and 0.00 | the same |
| PURGE-JOINS, 9,216 joins in a verdict's bucket | 13.08 / 13.16 / 13.04 | `probe-purgej.summary.log:2-5` |
| PURGE-JOINS, 9,489 joins in the queue | 11.84 / 11.52 / 12.55 | `probe-purgej.summary.log:8-11` |

**No committed case times the jobs' side.** The probe says so itself (`VerifyC21CorrectPurgeProbes.swift:13-15`). Item 2's
case (i) is PURGE-QUEUED's first shape, so it misses on `d5b2ab9` by about 5.5×.

**reqs #4 is real, at the edge.**
- `purgeWhileOwedTurns` (`BenchSyncReroutes.swift:68-74`) gates both the heartbeat and the held turns (`:110-128`). Its heartbeat covers the whole window (`:337`).
- The fixer's second gate run missed at 10.04 ms. The first gave 9.57, and two re-runs gave 9.62 and 9.75 (`s3f.md:6668-6674`). The verifiers measured 9.57 to 9.83.
- The owed-batch walk takes 9.14 to 9.22 ms of the turn (`s3f.md:6676-6682`).

## 1. The purge's contract

### 1.1 What the documents bind

| Source | What it says | Does it bind the withdrawal to the first turn? |
|---|---|---|
| `SPEC.md:250`, R-CLN-6 [MUST] | the purge returns bytes freed, leaves the store consistent, and makes a sync due afterwards | No |
| `ARCHITECTURE.md:300`, the Purge row | "`purgeEpoch` bumped before any await". The run ends `failed(.cancelled)`, interests are withdrawn, user waiters re-queue. The store bumps its own epoch, and clears the stamp and sets `syncDue` before *its own* first await (ADR-052) | Only the engine's epoch. The withdrawal is listed without a turn |
| `ARCHITECTURE.md:49`; `docs/DECISIONS.md:392` (C-5) | "every purge clears the stamp and sets it before its first own await" | No: this is the store's purge (WP-C on WP-B) |
| `ARCHITECTURE.md:456`, RE-S24 | "afterwards jobs for purged ids are removed or re-queued" | No. It puts the removal *after* the store's await, so it is stale against the code |
| `EngineCommands.swift:961-962`, the doc comment | epoch first, then the withdrawal, then the purge in an owned task | It states a sequence, not a MUST |
| `s3f.md:2042`, `:2931`, `:3135`, I33 | "At once (removal 7)" | No: it means the withdrawal is not deferred to the follow's drain |
| `s3f.md:2826-2828`, RR-5 (PROBE-C13-PURGE-JOIN) | a waiting join was left unwithdrawn, the drain replayed it, and the purged id was stored again: a different answer | **Yes, by derivation.** Every waiting join, bucket join and owed item must be withdrawn before any drain turn can replay it |

Only runs read the engine's `purgeEpoch` (`EngineRuns.swift:85`, `:287`). "Before any await" guards `markSynced`'s race
(RE-S11, `ARCHITECTURE.md:443`).

### 1.2 What the tests pin

Every purge test asserts after `purge` returns:
- `EngineCommandTests.swift:184` and `:201`;
- `EngineRegressionRound2Tests.swift:282`;
- `EngineRegressionCycle6Tests.swift:153` and `:268`;
- `EngineIdleTests.swift:156`;
- the barrier suites: `EngineFollowBarrierAnswerTests.swift:197` and `:260`, `…DeferBucketTests.swift:541`, `…RerouteOwnerTests.swift:161`, `…ReplayTests.swift:344`, `…MoveRevalidationTests.swift:201`, `…LaneTests.swift:76`.

`EngineModelTests.swift:116-118` runs `invariantViolations()` after each random purge, but its catalogs are small.

Only `purgeDuringApply` (`EngineRegressionRound2Tests.swift:142-162`) pins an effect of the first turn. It awaits
`run?.settlement == .cancelled` while the apply is held, so `settleRun` must run before the store's work.

**No test pins that the withdrawal is atomic.** Slicing it breaks no assertion as such. The bar is S3-R16 item 1, applied
to every state a command can meet between slices.

### 1.3 What breaks if a command runs between withdrawal slices

"Naive" means today's walk cut into turns over a snapshot of the keys, and nothing else. The last column names route B's
measure (§4).

| # | Between two slices | Today (one turn) | With naive slices | S3-R16 class | Route B's measure |
|---|---|---|---|---|---|
| 1 | a new prefetch group, run or heal on a purged id (new token) | a new job; the interest stays | it joins the unvisited job, and that job's slice withdraws it | 1(a): the member is never fetched, and the run's report changes | a token watermark |
| 2 | an old group's join still in progress (`joinGroup`'s yields, `EngineCommands.swift:295`) | it lands after the walk and stays | it is withdrawn if it lands on an unvisited job | timing: the same outcome as if that join had come before the purge | rule the class, or withdraw on touch in `addInterest` |
| 3 | a user waiter or an ensure on a purged id | a new job at the back of its queue | it joins the old job at that job's place | order and place (item 2) | none |
| 4 | the pump meets a job that only withdrawn interests want | never | the job starts: an extra request, and the purged id is stored again | 1(a), the RR-5 class | the gate: `setsAside` extended (`EngineDispatch.swift:292-309`) |
| 5 | the drain replays a waiting join, a bucket join or an owed item | it was withdrawn first | it joins again | 1(a) (RR-5) | those arms stay in the first turn |
| 6 | a follow's move takes ids off an unvisited job | nothing purged is left to move | a purged pair is re-routed; an owed item breaks `EngineCommands.swift:2136-2139` | 1(a) and 1(b) | a filter at the take-offs (`EngineFollow.swift:594`, `:1248`; `EngineMoves.swift:339`) |
| 7 | a commit or fail-fast of a job that still holds a group's members | not reached | the member is answered (a group delivery) where today it was dropped | 1(a) | the groups' side runs in the first turn |
| 8 | a running non-user transfer | abandoned in that turn (`retire`, `EngineJobs.swift:411-428`) | it runs on and can publish | 1(a) | in-flight jobs are walked in the first turn, as the release does (`EngineCommands.swift:373-375`) |
| 9 | a resolve, or `isSyncDue` | the store's purge has begun | it has not begun yet, if it waits for the slices | timing | none |
| 10 | an apply of a new copy | `isPurged` is read once | `.scope` and `.evictable` are read under the new copy (`EngineCommands.swift:994`) | 1(a) for an id whose policy or tags changed | the snapshot captures the copy |
| 11 | a release of the old group | the walk is already done | both remove the same interests | idempotent | none |
| 12 | shutdown | it drains everything | the purge must still answer | 1(c) | shutdown resumes the waiting purge |
| 13 | a second purge | it runs after the walk | the two walks interleave | 1(b), 1(c) | walks run first in, first out |

**Conclusion.**
- Withdrawing everything in the first turn is not a MUST. It is a design property that every reader of a job's interests relies on without saying so.
- Slicing is admissible only if rows 1, 4–8, 10, 12 and 13 are designed away.
- Rows 2, 3 and 9 must then be ruled as S3-R16 item 2 classes, under S3-R26 answer 6's condition: the command lands between the purge's call and its answer.
- Ensures and user waiters are user lane, so they are never withdrawn (`EngineCommands.swift:737`, `EngineDispatch.swift:260`).

## 2. The cost model (estimates unless marked)

### 2.1 10,000 jobs with one interest each (measured 54–58 ms, 5.4–5.8 µs per job)

A bottom-up count gives about 4.3 µs per job. The rest is cache misses over 10,000 jobs, and the allocator.

| Operation | path:line | Share |
|---|---|---|
| About 13 removals keyed by `TransferID` on mostly empty sets and dicts. `Set.remove` and `Dictionary.removeValue` hash even when the collection is empty; only `lookup` has a count-0 path (SDK `Swift.swiftinterface`, checked earlier this session) | `EngineJobs.swift:452-482` | 18–25% |
| About 8 other `TransferID` lookups: the walk (`EngineCommands.swift:1008`), `dropInterest` (`EngineJobs.swift:380-383`), `settleRemoval` (`:395-397`), `retire` (`:412`) | as listed | 12–15% |
| Three `Job` copies: `:1008`, the `ClaimKey` map (`EngineJobs.swift:395`), `retire` (`:412`) | as listed | 7–10% |
| Temporaries: the filter `Set` (`:1011`), the interests array (`:1015`), the intersection (`:1016`), the sorted ids (`:1022`) | `EngineCommands.swift` | 8–11% |
| Queue compaction. `storedCount` makes 16 lookups on every `removeJob` (`LaneQueues.swift:262-266`), and geometric passes run `isValid` | `EngineJobs.swift:565-583` | 7–9% |
| `Job` deinit (about 5 frees) | `removeJob` | 5–8% |
| `dropGroupMember`: 3 `groups` accesses and a `Group` copy | `EngineJobs.swift:658-668` | 4–6% |
| The sort of 10,000 keys | `EngineCommands.swift:1007` | 4–7% |
| `setInterest(nil)`, `tokensByID`, `InterestCounts` | `EngineState.swift:903-924` | 3–5% |
| `isPurged`: `entry(for:)` plus a `ManifestEntry` copy | `EngineCommands.swift:993-1005`, `ValidatedManifest.swift:78-93` | 2–3% |
| Residual (cache misses, the allocator) | none | 15–25% |

The release confirms the scale: one removal costs 8 to 9 µs, and a 512-member turn takes 4.1 to 4.8 ms (`EngineCommands.swift:385-389`).

### 2.2 One job of 10,000 ids (measured 12.0–13.6 ms; bottom-up about 7.9 ms, so ×1.6)

| Operation | path:line | Estimate | Share |
|---|---|---|---|
| Sort of the 10,000 withdrawn ids | `:1022` | about 2.3 ms (the fixer timed 10,000 items alone at 2.26, `s3f.md:5792`) | 25–30% |
| `dropGroupMember` ×10,000, with `Group` copies | `:1025` | 2–3 ms | 25–30% |
| `filter(isPurged)` ×10,000 | `:1011` | 1.1–1.7 ms | 15–20% |
| `intersection` | `:1016` | 0.7–1 ms | ~10% |
| Releasing 10,000 ids from `tokensByID` | `EngineState.swift:903-924` | 0.6–1 ms | ~10% |

### 2.3 The waiting events

**Bucket joins** (`:1083-1090`). Each slot costs:
- two `VerdictKey` hashes, one to read it and one to write it;
- a `JoinAfterFollow` copied out and written back;
- `isPurged`'s copy lookup;
- a two-level `joinsAfterFollow` removal (`:1102-1105`);
- `dropGroupMember`.

**Queue joins** (`:1057-1063`) cost the same, plus a copy of the event and its write-back. Both shapes cost about 1.1 to 1.4 µs per join. PURGE-JOINS' figure includes its shape's jobs; the split is not measured.

**The owed batch** (`:1065-1081`). The draft measured the walk at 9.14–9.22 ms. The copy lookup is about 1 ms of that: 7.93–8.46 ms with `{ _ in true }` (`s3f.md:6676-6684`). The rest:
- the sort, 2.26 ms;
- the batch's items, copied by `removeAll` because `event` still shares them (`:1058`, `:1065-1066`) and freed at the write-back (`:1080`), estimated at 1–2 ms;
- `dropGroupMember` ×10,000.

### 2.4 Two in-letter shapes that no figure covers

- **Jobs that wait for a retry.** `removeJob` calls `heap.remove(.retry(transfer, epoch:))` (`EngineJobs.swift:483`), which is
  `entries.removeAll { $0.reason == reason }` (`DeadlineHeap.swift:74-76`): one pass over the heap per job.
  - Each failed job schedules one entry (`EngineFailures.swift:268`), and S3-B-077's bench builds 10,000 of them.
  - A purge of 10,000 such jobs is quadratic: about 10^8 comparisons, 0.2 to 1 s (UNCONFIRMED).
  - The release's 512-member turns pay 512 heap passes too.
- **k = 2 and k = 4.** Item 4 sizes the per-id dimension up to 4 interests per id, so these are in-letter.
  - Four prefetch groups over 10,000 jobs, 40,000 pairs: estimated at 85–130 ms today.
  - A waiter and a group per id: the jobs stay and are re-laned; estimated at 10–20 ms.

## 3. Route A: cuts inside one turn

### A1: branch-free, in item 2's step (one commit per part)

1. **`isPurged` reads the request before the copy lookup**, for all three callers: the walk, the joins and the owed arm (`:993-1005`). This is item 2's part (1).
2. **In place, with no copy of their items:**
   - the owed batch (item 2's part (2));
   - the queue's `.join` events (`:1058-1061`);
   - each bucket, in one `joinsBehindVerdicts[key]` access over its slots (`:1086-1089`), still newest first.
3. **No sort of the dropped ids or the removed items** (`:1022`, `:1070`).
   - The order is unobservable. The lane filter never withdraws an `.ensure` interest, so `dropGroupMember` never resumes anything from the purge.
   - `.system` only clears `heals[asset]`, and `.run` does nothing. The draft argues the same (`s3f.md:5792-5794`).
   - Dropping the owed arm's sort reverses `integrate-rr21.md` R15 (`s3f-c20-analysis/integrate-rr21.md:239`).
4. **One jobs access per job.** A `Job` mutating method removes every purged non-user, non-waiter interest and returns what it took. Then one `settleRemoval` runs.
   - Precedent: one access took `takeOff` from 27.66 to 7.26 ms (`EngineState.swift:1029-1076`).
   - Precedent: `settleRemoval` already settles "several, removed in one access" (`EngineJobs.swift:390-393`).
5. **A fast path for `.all`.** No filter and no intersection: `withdrawn = interest.assets`.
6. **A3 and A3′** (`Group.dropMember`, `d2-present-members.md:206-216`) at `:1025`, `:1073` and `:1108`, with d2 review M1's pending check.
7. **No `Job` copies** in `settleRemoval` (build `ClaimKey` in place, `EngineJobs.swift:395`) or in `retire` (`:412`).

### A2: a cheaper retirement (not branch-free, so it needs this ruling)

1. **Skip empty indexes.** `removeJob` touches an index only when it is not empty (`EngineJobs.swift:452-482`).
2. **Keep `storedCount` as a counter** in `LaneQueues`, with a recount clause beside `EngineCommands.swift:1864-1866`.
3. **Free retired jobs later.** The walk moves each removed `Job` into an array that the purge's owned task frees in slices of 512, with a yield between them, as `settle` frees the job table (`EngineShutdown.swift:170-214`).
4. **Optionally, walk in table order**, in place by index, which drops the sort and the per-job hash.
   - `Dictionary.values` and `Values.subscript(position:)` both have an in-place `_modify` (macOS SDK `Swift.swiftinterface:7931-7941` and `:8050-8058`). Cite the iOS SDK as well (C7).
   - This holds only if the order is accepted, after an audit of the purge suites for order assertions (A7's rule). Otherwise the sort stays.
5. **One pass over the heap** for the retired jobs' `.retry` entries, using `heap.removeAll(where:)` (`DeadlineHeap.swift:79-81`), in place of one pass per job.
6. **`notifyObservers` once per job**, after A5's audit of the `waitUntil` and `awaitCondition` predicates for states that exist only mid-turn.

### Figures after each step (estimates, heartbeat; ±50%)

| Shape at 10,000 ids | Today (measured) | After A1 | After A2 |
|---|---|---|---|
| (i) one group, 10,000 jobs, `.all` | 54.5–58.4 | 33–41 | 5–12 in table order; 7–15 sorted |
| (ii) 10,000 one-member groups | not measured | 34–44 | 6–14; 8–17 |
| (i) under `.scope` or `.evictable` | not measured | 35–45 | 6–13; 8–16 |
| one job of 10,000 ids, `.all` | 12.0–13.6 | 2–4 | 2–4 |
| the same, under `.scope` or `.evictable` | not measured | 4–7 | 4–7 |
| 9,216 joins in a bucket | 13.0–13.2 | 5–7.5 | 5–7.5 |
| 9,489 joins in the queue | 11.5–12.6 | 5–7 | 5–7 |
| `purgeWhileOwedTurns` | 9.51–10.04 (a gate miss at 10.04) | 8.4–9.3 after (1); 3.5–6 after (1)–(3) with A3 | the same |
| k = 4, four groups | not measured (est. 85–130) | 45–70 | 9–20 |
| 10,000 jobs waiting for a retry | not measured (est. 200–1,000) | as today | 7–15 |

- A1 alone leaves (i), (ii), k = 4 and the retry shape far above the bar.
- A2 may bring (i) and (ii) under the bar. The residual (cache misses) decides that, so only a measurement can tell.
- k = 4 very likely misses even after A2.

### Equality with today

- **A1** keeps every answer, every event and the order across jobs, because the keys stay sorted.
  - It changes only the order of removals within one job and how many `notifyObservers` calls happen inside the turn.
  - A job's lane only falls, and its last `relane` sets its place, so the final state is the same.
- **A2's table-order walk** reorders `retireProgress` events, re-queues of kept jobs, and abandons across jobs.
  - Those are S3-R16 item 2's order and place.
  - The hash seed changes per process, so the order does too, and a test that asserts it would flake (1(d)). The audit decides.
- **Freeing later** is invisible.

### Branches and their kill tests

| Branch | Kill |
|---|---|
| `isPurged` reads `.all` first | Drop: Equivalent (item 2 (1)) |
| the walk's `.all` fast path | **Always taken:** T-A-SCOPE, a `.scope` purge of one of two ids that share a content held by a prefetch group; the other member stays pending and keeps its interest, 2/2. **Never taken:** Equivalent |
| `Job.withdraw`'s whole and partial arms | Whole: `purgeDropsGroupMembers` (`EngineRegressionRound2Tests.swift:282`). Partial: T-A-SCOPE |
| moved lane and kind conditions | Re-run their mutants at the new lines (item 3's rule) |
| `Group.dropMember` returning nil on a mismatch | Item 3's M1: a test that reaches it, or a structural record |
| A2's empty-index guards | Drop: Equivalent (S3-R19 item 2). Negation: each index's invariant clause; the fixer lists the clause per index, and an index with none gets one |
| A2's queue counter | Each update's drop-mutant fails the recount clause |
| A2's freeing slice `if` | Equivalent (memory timing only) |
| A2's heap pass | The retry-shape case asserts that no `.retry` entry is left |

## 4. Route B: bounded slices over owned follow-up turns

**The pattern is the release's.**
- `performReleaseGroup` removes the group at once (`EngineCommands.swift:359`). It removes the members' interests over 512-member turns (`:385-440`), through `releaseFollowUp` with a scheduled flag and a hold seam (`:442-480`).
- `isReleasedOnly` keeps those jobs from starting (`EngineDispatch.swift:292-309`).
- A clause requires a scheduled turn (`EngineCommands.swift:2094-2095`), and shutdown drains `releasing` (`EngineShutdown.swift:91-92`).

**Phase 1, the purge's turn.** It is bounded by A1's cuts, not by a count.
1. As today: `purgeEpoch`, `lastStamp = nil`, `dropBindings` and `settleRun(.cancelled)` (`:968-973`).
2. `withdrawPurgedJoins` as today, cut by A1 (row 5).
3. **The groups' side, read from the groups** (row 7). Each non-user prefetch group drops each pending member whose id is purged and whose transfer holds the token's interest in that id.
   - That equals today's drops by construction, at one job lookup per member: 2 to 8 ms at k ≤ 4.
   - It gets cheaper if the F-1 clause (`EngineCommands.swift:1856-1862`, which checks only `interests[token] != nil`) is strengthened to the id and the suites pass (UNCONFIRMED). For `.all`, each group then needs only one `pending.removeAll()`.
4. **The in-flight jobs** (`state.inFlight`, at most `maxConcurrentTransfers`) are walked whole, so their transfers are abandoned in this turn (row 8).
5. **The snapshot:** `PurgeWalk(serial, request, copy: applied, watermark: last token issued, transfers, waiters)`.
   - The other jobs' keys are sorted in the first slice.
   - Each listed job gets the walk's serial as a mark, set in one in-place pass over `jobs.values`.
   - Capturing `applied` is O(1), copy-on-write, and settles row 10.
6. **The first slice is scheduled** with `spawn(.entry)`. The purge's owned task waits for the walk's end before `purgeTask`.

**Each slice** (`purgeFollowUp` → `continuePurge`):
- It visits snapshot jobs until at least `purgePairsPerTurn` (512, as `releasesPerTurn` and `followIDsPerTurn`, `EngineMoves.swift:235`) pairs are withdrawn, or the snapshot ends. A state seam sets the bound, as `EngineState.swift:118` does for `followIDsPerTurn`. A slice never splits a job.
- **Re-validation per job.** The slice skips a job unless `jobs[t]` exists and carries this walk's mark. A key can be re-created by a new job, which carries no mark.
- **What it withdraws:** interests whose token is at or below the watermark, below `.userInitiated`, not `.waiter`, on ids that are purged under `walk.copy`. It settles once, forgets those ids' heals, and clears the mark.
- **REENTRANCY.**
  - RE-S21 on the spawn: "nothing: the slice re-reads `purgeWalk`, each job and its mark".
  - A new row on the owned task's wait: "the lifecycle; the walk's end or a shutdown resumed it; `purgeTask` re-checks `isRunning` after the store (`:1124`)".
- **At the walk's end:**
  - restore the entries set aside (as `:414-421`);
  - resume the waiting purges;
  - then `purgeTask` runs as today. **The store's purge runs after the last slice**, which keeps today's order: withdraw, then purge.

**Between slices:**
- **The gate.** A marked job whose every interest is withdrawable is set aside. Each entry is stepped over once (C2). `addInterest`'s reinstate path covers it (`EngineJobs.swift:154`, `:188-194`). A heal that fired before the purge leaves its job set aside until its slice.
- **The take-off filter** (row 6). A moved pair that the walk would withdraw is dropped instead of re-routed. Its cost is bounded by the move's ids.
- **Shutdown** drains the walk and resumes its waiters, so the purge answers `.failure(.shutDown)` as today (`:1124-1125`, `:1145`).
  - The store's purge then never runs. Today that happens too when a shutdown overtakes the owned task's first hop: a timing class.
  - Shutdown also releases B's hold seam with the others (`EngineShutdown.swift:49`).
- **A second purge** runs its phase 1 at once and queues its walk behind the first, with its own snapshot and watermark. The gate and the filter read every pending walk.
- **New clauses:**
  - a walk implies a scheduled or held follow-up;
  - a mark implies an unvisited snapshot entry;
  - no withdrawable pair sits on an unmarked job while a walk is pending;
  - entries are set aside only for such jobs.

**Answers and events against today.**
- Commands before the purge, or after its answer, see what they see today.
- Between slices, rows 2, 3 and 9 differ in timing, order or place. Every other row is made equal.
- `retireProgress` for snapshot jobs comes in later turns. The purge's answer has the same value, about 20 turns later at (i).

**Tests** (S3-R16 1(a)–(d)).
- Each test is deterministic through a hold seam, `holdPurgeFollowUps` and `resumePurgeFollowUps`, built as `:465-480` is.
- Tests that involve a follow run in both orders (S3-R24 item 3).
- Each kill asserts by value; a hang does not count (item 5).

| Test | What it checks | Row |
|---|---|---|
| T-B1 | a new prefetch group and a new run on a purged id keep their interests: the member is fetched, and the run's report is today's | 1 |
| T-B2 | with a free slot, a job that only withdrawable interests want does not start: the control log has no request for it | 4 |
| T-B3 | a follow's move off a marked job re-routes and owes no purged pair, and `invariantViolations()` is empty, in both orders | 6 |
| T-B4 | a user waiter and an ensure on a purged id are answered as today | 3 |
| T-B5 | an apply that makes a purged id `.essential` between slices leaves the withdrawn set unchanged | 10 |
| T-B6 | a shutdown between slices: the purge answers `.failure(.shutDown)`, every owned task ends, and the walk is gone | 12 |
| T-B7 | a second purge between slices: both answer, and the stored set is today's | 13 |
| T-B8 | `invariantViolations()` after every slice, with the new clauses | — |

The existing purge tests stay unchanged (G3).

**Pins** (S3-R23 item 3).
- **BenchSync cases at 10,000**, one per shape: (i), (ii), the shared job, the bucket, the queue, `purgeWhileOwedTurns`, `.scope` over (i), and k = 4.
  - Each is gated on its heartbeat, best of 3, within `c2Budget`.
  - Phase 1 and the longest slice are recorded beside it.
- **A deterministic bound test.** With `purgePairsPerTurn` set to 4, a purge of 10 one-id prefetch jobs records `purgeSlices == [4, 4, 2]`, a recorded seam like `shutdownSlices`. The bound's drop-mutant gives `[10]` and must fail it 2/2.

**Branches and their kill tests:**

| Branch | Kill |
|---|---|
| the watermark | T-B1 |
| the gate | T-B2 |
| the take-off filter | T-B3 |
| the captured copy | T-B5 |
| the slice's "no job or no mark" skip | a release that retires a marked job between slices, then a new job on the same key; checked by T-B8 |
| the bound | the bound test |
| the walk queue | T-B7 |
| shutdown's resume | T-B6, by value |
| the groups' side | `purgeDropsGroupMembers` and T-B3's group assertions |
| `spawn`'s refused arm | not written: `spawn` refuses only from shutdown on (`EngineLifecycle.swift:52-56`), and shutdown drains the walk. This is the argument item 3 uses |

**Cost and risk** (estimates):
- **Phase 1:** 0.3 to 2 ms for (i) and (ii) under `.all`, and 2 to 8 ms under `.scope` at k ≤ 4, plus A1's join arms where joins wait.
- **A slice:** 0.6 to 2 ms. The first can reach about 5.5 with the key sort.
- **The heartbeat:** 3 to 8 ms.
- **Phase 1 stays unbounded in pairs**, for example a bucket of joins together with `.scope` at k = 4.
- **The main risk is the audit, not the slices.** Every site that moves, answers or starts a job's interests must be filtered, or shown unreachable for a marked job. The sites:
  - `resolve` and `resolveAll` (`EngineJobs.swift:688`);
  - `failFast` (`:816`);
  - `answerPresentMembers` (`EnginePresence.swift:345`);
  - `sparePresent` (`EngineFailures.swift:532`);
  - the take-offs.

  Interests whose group no longer waits must resolve as no-ops. `stillWants` checks per member (`EngineFollow.swift:996-997`), but showing that every resolution path does the same is UNCONFIRMED.

## 5. Interactions

- **S3-R27 item 2, the owed-batch arm.**
  - Item 2's parts (1) and (2) are A1.1 and A1.2.
  - A1.3 adds a part (3): drop the removed-items sort. It is Equivalent, and it reverses R15.
  - Item 2's branch-free rule and item 11.3 still bind A1. A2 and B need item 12.
- **Item 3: A3, A3′ and d2 review M1.**
  - They land in item 2's step. The purge's three callers keep the pending check, because the owed arm's `from` and the registry's transfer are both claims about where a member waits.
  - M1's nil line is reached by a test or recorded as structural.
  - Cite `index(forKey:)` and `remove(at:)` in both SDKs (C7).
- **RR-21's owed batches** stay withdrawn before any drain replay: in A's single turn, or in B's phase 1.
  - The owed clause (`EngineCommands.swift:2136-2139`) forbids an owed prefetch item whose member is not pending at its `from`. B's filter is what keeps a move from creating one.
- **Item A's buckets** (S3-R26 item 2) stay withdrawn in place, newest first. A1.2's single access per bucket keeps that order.
- **Phase 2's owed answers** are untouched. The purge never resumes an ensure group, so B2's `owing` stays `false` for its callers (d2 review should-fix 8).
- **The settle slice** (item 6) is the model twice over:
  - for A2.3's freeing;
  - for B's bound test, through T-A3's `count` pattern and `shutdownSlices`.

  Shutdown must drain B's walk as it drains `releasing`.
- **Item 4's sizing** makes the k ≤ 4 purge in-letter. Whether that purge is gated decides whether B is needed.
- **Item 9** needs inventory rows for:
  - the walk: O(jobs + pairs) in one turn, or O(bound) per slice under B;
  - A2's heap pass;
  - the retry shape.
- **Item 10's red-first rule:** (i), (ii), the shared job and both join shapes miss on `d5b2ab9`, so each is committed failing right before its fix.

## 6. Recommendation

1. **A1 in item 10's step 4**, together with item 2. The new cases come first, with the misses committed red. After each part, measure every purge case: best of 3, heartbeat, with loads.
2. **A2** if any purge case is above 8.5 ms after A1. For (i) and (ii) that is near certain. The table-order walk comes only after the order audit. Measure again.
3. **B** only on a miss after A2, at a quiet load, under §4's design. Schedule it after item 5's survivors (step 7). It is the largest change, the weekly limit is expected, and a cut-off should leave A1, A2 and the survivors committed. A miss after B is blocking, reported with its phase-1 and slice figures.
4. **The decision rule** at each step is item 1's:
   - at or below 8.5 ms, the item closes;
   - from 8.5 to 10 ms, it is recorded "at the edge" and is not blocking;
   - above 10 ms at a quiet load, it is a miss.
5. **Fixer hours**, estimated, including the cases, red commits, mutant re-runs and measurements:
   - A1: 5 to 8 h.
   - A2: 6 to 10 h.
   - B: 16 to 28 h, of which the audit and the filter take 6 to 10.

   Expected totals: 11 to 18 h without B, 27 to 46 h with it.
6. **If k = 4 is gated in cycle 22, B is very likely needed** (A2 is estimated at 9 to 20 ms there). Going from A1 straight to B is then cheaper than building A2 as well.

## What the ruling must say

1. Item 12 names correct #2 (`EngineCommands.swift:992-1092`; PROBE-C21C-PURGE-QUEUED, -PARTS and -JOINS) with reqs #4. It replaces item 2's "jobs' side" paragraph and item 11.3; item 2's parts (1) and (2) stand.
2. Withdrawing every non-user interest in the purge's first turn is not a MUST (`SPEC.md:250`; `ARCHITECTURE.md:300` binds only the epoch). Withdrawing every waiting join, bucket join and owed item before any drain turn is binding (RR-5, PROBE-C13-PURGE-JOIN).
3. Commit BenchSync cases at 10,000, each gated on its heartbeat (best of 3) with the purge's turn recorded beside it: (i), (ii), one job of 10,000 ids, 10,000 joins in a bucket, 10,000 joins in the queue, and (i) under `.scope`. Each case that misses on `d5b2ab9` is committed red.
4. The ruling says whether two shapes are gated or recorded in cycle 22: the k = 4 purge, and the purge of 10,000 jobs waiting for a retry. In the second, `removeJob` scans the whole heap per job (`EngineJobs.swift:483`).
5. A1 is branch-free and lands in item 2's step. It reads the request first, mutates the waiting events in place, drops the sorts of dropped ids and removed items (this reverses `integrate-rr21.md` R15), and uses one jobs access and one settle per job. It also adds the `.all` fast path, A3/A3′ with M1, and no `Job` copies.
6. The draft records A1's two order arguments. The purge never withdraws an `.ensure` interest, so its drop order is unobservable. A job's final lane and place do not depend on the order of its own removals.
7. A2 is authorised only if a purge case is above 8.5 ms after A1. Its parts are empty-index guards (drop-mutants Equivalent, negations killed by clauses), a queue counter with a recount clause, deferred freeing in the purge's owned task, one heap pass, and observers notified once per job after A5's audit.
8. The table-order walk is an accepted order (S3-R16 item 2) only after an audit of the purge suites for order assertions, as A7's rule requires. Otherwise the key sort stays.
9. Route B is authorised only on a miss after A2 at a quiet load, and it is scheduled after step 7. Its design is §4: joins, owed items, the groups' side and in-flight jobs go in the first turn; the rest goes in slices of at most 512 pairs over a sorted, marked snapshot, using a token watermark and the captured copy. It adds the gate and the take-off filter, runs the store's purge after the last slice, has shutdown resume the purge, and queues a second purge's walk.
10. Under B, rows 2, 3 and 9 of §1.3 are S3-R16 item 2 classes under S3-R26 answer 6's condition. Every other row must equal today's, shown by T-B1 to T-B8 in both orders and asserted by value.
11. B's pins are a BenchSync case per shape at 10,000 within `c2Budget`, and a bound test through a `purgePairsPerTurn` seam with recorded `purgeSlices`, whose drop-mutant fails 2/2. Every new branch is killed 2/2, or listed as Equivalent or structural (S3-R25 item 10).
12. Propose (S3-R6) RE-S24's corrected text, and under B the turn rule in `ARCHITECTURE.md:300`. A miss after the last authorised route is blocking and is reported with its parts' figures.
