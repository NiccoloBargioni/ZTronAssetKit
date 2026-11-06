# f3c: a route for the open in-letter purge shapes (read-only analysis, kept for a re-open)

Read-only at `9aa337c` (`.worktrees/s3f`); paths are under `Sources/ZTronAssetSync/Engine/` unless named. Every figure is an estimate unless it is marked derived. Nothing was built, run or measured for this file (G2).

- **Status.** N25 (14:37) made the first three shapes known misses of C2's 10 ms limit and withdrew item 3c. This file is kept for a later re-open and is not appended (`s3-r28-orchestrator-rulings.md:216-240`).
- **Sources.** `f3b-review.md` §4, §6, §7 and points 1-12; `f3b-route-a.md:67-68`, `:165-195`; `f3b-route-b.md` §2, §3 and T-B1 (`:132-144`); `f3-purge-route.md` §1-§3.2; `f3-purge-route-review.md:60-72`; N8, N22-N25.

## 0. Verdict

- **The route.** OS-1 (= A-6), OS-2 (an in-place re-admission) and OS-3 (an in-place re-queue) come after item 3b's M-5. OS-4 to OS-6 are made only on triggers. Route C's stage C is the closing lever.
- **By estimate (§3), none closes at stage A or B.** failedUserRetries falls from about 0.55 s to 10.4-21.2 ms, bulkWaiterFalls to 7.9-16.9 ms (+2-3 with a compaction), and claimHeldFalls to 7.4-16.7 ms.
- **At stage C, with OS-4 to OS-6:** claimHeldFalls is 3.0-8.2 ms and bulkWaiterFalls 3.5-8.4 ms (each 4.4-10.4 ms when the purge compacts the queues). failedUserRefused is 4.1-9.0 ms, at the edge, and failedUserRetries is 5.2-10.8 ms: its top misses 8.5 ms.
- **What §7's "each can be closed within one turn" becomes.** By this estimate it holds only for the two re-queue shapes, and only without a compaction. Below stage C, the re-admissions would have to be sliced across turns, which changes order and place. No ruling authorises that, and it is not designed here.
- **Why these figures are above §7's 7-12 and 7-11.5, which were not itemised.** Every job of these shapes is class C. So it pays the pass-1 visit, the sort and a sorted visit (4.3-8.8 ms in all at stage A) before B-2's rebuild (2.2-4.9 ms) and its own work. Every re-queue also pays `storedCount`'s 16 lookups (`LaneQueues.swift:262-266`).
- **Found on the way (§8).** Production's gate cost is invisible on the bench. Per-job heap scans outside a walk cost 27-55 ms a turn, a shape outside N25's three cases.

## 1. The shapes (10,000 ids, at most 4 interests on an id; `f3b-review.md` §7)

| Name here | Shape | Item 3b class | Today's settle |
|---|---|---|---|
| failedUserRetries | each job `.failed(.at)` at the user lane (a user waiter), with a `.retry`, under 1-3 prefetch groups; the origin admits a user request | C (failed at the user lane) | T20 re-admission: `transition`, `heap.remove` (a full scan), `enqueue` (`EngineJobs.swift:360-363`) |
| failedUserRefused | the same, with the breaker open or a throttle in force. This is my reading of point 10's third variant (§7 row 1's "9-18 otherwise") | C | the gate read only (`:360`, `:378-386`) |
| bulkWaiterFalls | a `.queued` job with a bulk waiter and three prefetch groups; its lane falls | C (a due re-lane) | re-queued to `.bulk` (`:311-314`, `:563-578`) |
| claimHeldFalls | a `.queued` job with a prefetch group and a bulk group, under a third group's pending claim; emptied, with `before` (prefetch) ≠ `last` (bulk) | C (not B′: point 7) | `heldLane = last`, then a re-lane, then `claimHeld` (`EngineCommands.swift:1051-1058`, `EngineJobs.swift:424-431`) |
| §7 rows 4 and 5 | `fourGroupJoins` over 40,000 one-member groups; three kept interests over one purged | joins / B | untouched by this route: 3-11.5 and 4.5-8.9 (§7) |

- **The scan.** The re-admission scans the heap for every disposition except `.untilEntryChanges` (`ZTronAssetModel/Events/EngineStates.swift:2-13`), whether or not an entry exists, so the 0.5 s needs only a large heap. Derived: (571.12 − 36.24) ms / 10,000 ≈ 53 µs a scan (s3f:7584, :7617), about 10.7 ns an entry at the walk's average heap of 5,000.
- **The variant count.** Point 10 names "three variants", but §7 has two variant rows, and N25 keeps rows 4 and 5. Here failedUserRefused is measured with failedUserRetries, as row 1's second form.
- **No reading in the walk.** The purge holds no reading and runs no visit (`EngineCommands.swift:963-979`), so `metInItsAttempt` is false (`EngineJobs.swift:289-297`). The arm's early return then reads `deferredAfter` alone (`:327`).

## 2. The parts (each its own commit, every suite green, under item 1's exclusivity rule)

**OS-1 = A-6 (in stage A, right after C-1).**
- **Inside a walk** (C-1's walk flag), the `.failed` arm leaves its `heap.remove` (`EngineJobs.swift:362`) to C-1's pass. Outside a walk, the removal stays.
- **C-1's predicate becomes the negation of fireDue's guard** (`EngineTimers.swift:111`). It removes `.retry(t, e)` when `jobs.index(forKey: t)` is nil, when `values[i].epoch != e`, or when `values[i].state` is not `.failed(.at)`. That is one hash per `.retry` entry, read in place with no `Job` copy.
- **Why the state test.** A re-admitted job keeps its epoch, which changes only at dispatch (`EngineDispatch.swift:705-706`, `f3b-route-a.md:68`), so the state test removes its entry. A job dispatched or retired inside the walk is caught by the epoch test or the lookup.
- **The record.** C-1's stale-retry difference widens to every entry that fireDue would skip.

**OS-2, the in-place re-admission (after M-5).**
- **Before B-2's access,** for a class-C job failed at the user lane (pass 1's tag, or a read through C-2's index), the arm's guard (`:327`, `:360`) is evaluated in today's order: `deferredAfter`, then the disposition, then the gate (`originAdmitsUser`).
  - Only if the gate admits does it read the instant (`decisionNow`), the ticket `lastTicket + 1` and the back place, from a new read-only `LaneQueues.nextBackPlace` (`lastBack + 1`, `LaneQueues.swift:60-61`). These are today's clock reads, in today's order (C4).
- **Inside the access, after B-2,** the `Job` half of `transition` runs (one `allows` table, `state`, `active = nil`, the ledger bytes). It then writes `queuedAt`, `ticket`, `queuePlace`, and the kind computed after the removal.
- **After the access:**
  - `lastTicket`, then the engine half: `reindex`, which skips `edgeOwed.remove` when `edgeOwed` is empty, and the circuit and in-flight branches (`EngineJobs.swift:36-50`);
  - then `push` (debug-checked to take the precomputed place), `compactQueuesIfStale`, and one `notifyObservers`.
- **A refused gate** makes no settle and one notification: today's settle does nothing else for that job (`:424-438`, `:326-365`).
- **`transition` becomes the two halves,** and today's callers call both, so `Job.state` keeps one mutator.
- **Everything else takes today's settle after the access:** a deferred verdict, `.untilEntryChanges`, a lane other than user, an illegal transition, and any walk under a reading or a visit.

**OS-3, the in-place re-queue (after OS-2).**
- **(a)** A kept `.queued` class-C job whose lane changes runs OS-2's re-queue writes after B-2.
- **(b)** An emptied, claim-held `.queued` job with `before ≠ last` runs, inside the access, C-2′'s moves, `heldLane = last`, then the re-queue writes, with the kind taken from `last`. After the access come `push`, `lastTicket`, the compaction check, then `claimHeld`. That is today's order (`EngineCommands.swift:1051-1058`, then `EngineJobs.swift:424-431`), and R-SYN-3 holds.
- **A `.downloading` job keeps today's re-lane,** because `setPriority` and `pauseIfRefused` reach the transport.
- **A `.failed` or `.blocked` job whose lane falls** has a no-op re-lane (`:326-372`), and OS-3 skips it.

**Triggered parts** (made when a shape they move is above 8.5 ms after OS-3, at the stage the ruling allows).
- **OS-4: walk-local gate inputs.** `throttleRecorded`, the live throttle and `breakerRecorded` (`EngineOriginGate.swift:67-83`, `EngineFollow.swift:327-340`) are read once, and refreshed after every `recordBreaker` (`EngineFailures.swift:1026-1047`); a retirement's abandon records one inside the walk.
  - Each job still takes its own `decisionNow`. A debug check compares the result with `originGate(at:)` at the same instant. OS-4 applies only while `readingView` is nil.
- **OS-5: `isValid` reads in place** (`EngineJobs.swift:615-620`). A compaction of about 20,000 entries falls from 2-3 ms to 1.4-2 ms.
- **OS-6: `storedCount` becomes a running count,** debug-checked against today's sum of 16 `Kind` lookups (0.08-0.16 µs a call, f3 §1's R split).
  - The compaction points are unchanged, so the clause at `EngineCommands.swift:1891-1892` holds as today. Deferring the compaction out of the turn would break that clause, so it is not an option.

**Stages.** These shapes retire no job, so N8 triggers no stage for them.
- Stage C (A2.4's table order, after A7's audit) is their main lever. It removes the sort and the random-order second visit, saving 2.8-6.1 ms from stage B.
- Stage C builds on stage B's C-5 (f3 §3.2's columns), whose index visits save 0.7-0.9 ms.

## 3. Cost per shape (ms, estimates)

**Units, in µs a job** (bases: f3 §1-§3.2, B §3 and the review's §4, with h = 70-90 ns and a `Job` copy 100-150 ns, as there):

| Work | Cost |
|---|---|
| pass-1 visit and its key | 0.04-0.11 |
| pass-2 visit | sorted 0.19-0.42; by index at stage B 0.11-0.34; in table order at stage C 0.03-0.08 |
| B-2's rebuild with its appends | 0.22-0.49 |
| C-2′'s moves / its claim arm | 0.02-0.06 / 0.15-0.41 |
| the gate | 0.1-0.25 (OS-4: 0.02-0.06) |
| OS-2's re-admission | 0.19-0.34 (OS-6: 0.11-0.18) |
| OS-3's re-queue | 0.11-0.23 (OS-6: 0.03-0.07) |
| today's settle: `holdIfUnwanted` / `relane`'s copy / `transition` / `enqueue` | 0.07-0.09 / 0.17-0.24 / 0.41-0.56 / 0.45-0.7 |

**Fixed parts, in ms a purge:** the sort 2-3.5 (stages A and B); the rest of the turn 0.2-0.5; C-1's pass 0.65-1.0 with 10,000 live `.retry` entries, else 0-0.3; a compaction 2-3 (OS-5: 1.4-2).

| Shape | After route C + item 3b: §7 / itemised | After OS-1 to OS-3: stage A / B / C | With OS-4 to OS-6: stage A / C |
|---|---|---|---|
| failedUserRetries | ~500 / ~0.55 s (scans 535 derived, + 18.8-33.0); OS-1 alone 19.5-33.7 (A §9 said 11.5-18) | 10.4-21.2 / 9.6-20.4 / 6.8-14.3 | 8.8-17.7 / 5.2-10.8 |
| failedUserRefused | 9-18 / 11.9-22.5 (route C's C-1 reads by the getter: 1.7-2.4) | 8.5-17.8 / 7.7-17.0 / 4.9-10.9 | 7.7-15.9 / 4.1-9.0 |
| bulkWaiterFalls | 9-17 / 13.7-24.9 | 7.9-16.9 / 7.1-16.1 / 4.3-10.0 | 7.1-15.3 / 3.5-8.4 |
| claimHeldFalls | 10-20 / 12.5-23.8 | 7.4-16.7 / 6.6-15.9 / 3.8-9.8 | 6.6-15.1 / 3.0-8.2 |
| §7 rows 4 and 5 | 3-11.5; 4.5-8.9 | untouched | untouched |

- **Compactions.** Add 2-3 ms (OS-5: 1.4-2) to the two re-queue rows when the purge's re-queues cross 2 × jobs + 16 (`EngineJobs.swift:603-612`).
  - That is likely for bulkWaiterFalls when its set-up leaves one stale entry a job, for example from a group join that raised the lane: the 17th re-queue then compacts about 20,000 entries.
  - It is borderline for claimHeldFalls, whose re-queues bring it to 20,000 stored entries against a threshold of 20,016.
- **Production adds 15-60 ms** to both failed-user rows, today and after this route, unless OS-4 or OS-0 is made (§8.1).
- **Stops after OS-3** (N22):
  - 2(c), a figure above its stage-A top: 21.2, 17.8, 16.9 (19.9 with a compaction) and 16.7 (19.7);
  - 2(b), a figure above about 21.5 ms, since the later levers save at most about 11.5 ms (B 0.9, C 6.1, OS-4 1.9, OS-6 1.6, OS-5 1).

## 4. The answers against today's, in both orders (S3-R16's bar)

| Part | Followed first (joined) | Swept first (waiting) |
|---|---|---|
| OS-1 | At the turn's end the heap equals today's, less the `.retry` entries that fireDue skips (C-1's recorded difference, widened). The walk's per-visit notifications still count the re-admitted jobs' entries, as A2.5's count retired ones (`EngineCommands.swift:1060-1065`). Where a stale entry was the heap's minimum, the alarm re-arms later and `isIdle` comes sooner; that firing did nothing (`EngineTimers.swift:111`) | The groups' joins wait. `withdrawPurgedJoins` takes them, and the walk skips the jobs (`EngineCommands.swift:1040-1042`). Their entries are `.failed(.at)` at their epochs, so they stay. Equal |
| OS-2 | Equal: the state and its indexes, the tickets in today's sorted order, the places (debug-checked), the kinds, `lastTicket` and one notification a visit. `queuedAt` is today's second clock read, made before the access: equal under the injected clock; live, earlier by the access (under 1 µs). The gate is read after every earlier job's retirement and breaker record, as today | Not reached (class A) |
| OS-3 | Equal, as OS-2's re-queue half. (b) writes `heldLane` before it takes the kind, and `claimHeld` after the push, as today | Not reached (class A) |
| OS-4 to OS-6 | Equal: one `decisionNow` a job and a snapshot refreshed after each breaker record (OS-4); the same `isValid` answer (OS-5); the same compaction points (OS-6) | Equal |
| Stage C | Tickets and places in table order. That is order and place only (S3-R16 items 2 and 3), after A7's audit | Not reached |

- **The MUSTs.** R-SYN-3's lanes are kept by OS-3 (b) and by today's re-lane for `.downloading` jobs. R-SYN-2 and R-SYN-5's backoff are untouched: a refused gate keeps the deadline. Every test below also asserts `invariantViolations()` empty.
- **A pre-existing difference, unchanged by this route.** In failedUserRetries swept first, the purge takes the groups' joins before they reach the job, so the job keeps its backoff. Followed first, the purge's settle re-admits it (T20). The re-open's review should confirm how S3-R16's records class this (not checked here).

## 5. The tests, red first

- **Red first: four bench cases** in `purgeTurn` (`Tests/ZTronAssetKitBenchmarks/BenchSyncCycle22Purge.swift:186-285`), in both orders like its other cases, with their 'before' figures on a scratch copy of `9aa337c` (N12). By estimate each is red there.
  - The cases are failedUserRetries, failedUserRefused (the breaker open), bulkWaiterFalls and claimHeldFalls.
  - For failedUserRetries the breaker must stay closed. `retryJobs`' timeouts (`:201-204`) feed it (§7's note), so the set-up keeps the failures below its threshold.
- **Behavioural tests,** each green on `9aa337c`, where it pins today's answers, and committed before the part it guards:
  - **T-OS1** (followed first): failedUserRetries with a few jobs, the clock moved between the failure and the purge. It asserts `.queued`, tickets ascending in sorted id order, the places, `queuedAt`, the kind and `lastTicket`; no `.retry` in `scheduledDeadlines`; `failedJobs` empty. One job is owed an edge, and `edgeOwed` is empty after.
  - **T-OS1w** (swept first, both drain timings): every job stays `.failed(.at)`, with its `.retry` at its epoch.
  - **T-OS1o:** a re-admission outside a purge (a user join to a failed user job). Its `.retry` is gone at that turn's end.
  - **T-OS2:** failedUserRefused. The jobs stay failed, and their deadlines fire (`retryScheduled`, `Tests/ZTronAssetSyncTests/Engine/EngineSync1LivenessTests.swift:12-18`).
  - **T-OS3:** a deferred verdict behind the barrier, not re-admitted.
  - **T-OS4:** `.failed(.untilEntryChanges)` at the user lane, and a failed job left at a non-user lane, neither re-admitted.
  - **T-OS5:** T-B1's J-Cf, J-Cl, J-Cc and J-Cd gain P-N9's four fields (ticket, place, `queuedAt`, `lastTicket`). J-Cm is one purge that mixes them with a retirement, ids interleaved, and asserts the tickets' order across the arms. A forced compaction after J-Cl's re-queue: the next dispatch serves J-Cl from `.bulk`, not from its stale `.prefetch` entry.
  - **T-OS6** (with OS-4): a half-open breaker whose probe is a prefetch-only download. The purge retires it, its id sorting between failed user jobs, and the jobs after it follow the breaker its abandon left. If no outcome inside a walk can change the gate, OS-4 needs no refresh, and its debug check replaces T-OS6.
- **No committed test changes** (G3), and none is assertion-free (G4).

## 6. The kills (2/2 in each order that reaches the branch; swept first reaches only OS-1's pass)

| Part | Mutant | Killed by |
|---|---|---|
| OS-1 | the scan kept inside the walk | equivalent, cost only (S3-R19 item 2); the bench case shows it |
| OS-1 | the predicate without its state test | T-OS1 (`scheduledDeadlines`) |
| OS-1 | the predicate removes every `.retry` | T-OS2 (followed first), T-OS1w (swept first) |
| OS-1 | deferral outside a walk | T-OS1o (A2.5's `a25-defer-outside` pattern, s3f:7677) |
| OS-2 | no ticket bump, or a wrong `lastTicket` | T-OS1, J-Cm |
| OS-2 | `queuedAt` not written | T-OS1 (the clock moved) |
| OS-2 | the push skipped, or pushed to another kind | T-OS1 (places, kind); the queue clause (`EngineCommands.swift:2139-2147`) |
| OS-2 | `reindex` skipped | the failed-jobs clause (`EngineCommands.swift:2093-2094`) in T-OS1 |
| OS-2 | the `edgeOwed` guard inverted | T-OS1's edge-owed job, and the index clauses |
| OS-2 | the gate / `deferredAfter` / disposition / lane test dropped | T-OS2 / T-OS3 / T-OS4 / T-OS4 |
| OS-2 | the visit's notification dropped | equivalent: the walk's last notification (`:1065`) resumes the same observers; recorded with N9's (point 6) |
| OS-3 | (a) re-queue skipped | J-Cl (R-SYN-3) |
| OS-3 | (b) re-queue skipped, or `heldLane` written after the kind | J-Cc (its entry is in `.bulk`) |
| OS-3 | a `.downloading` job taken in place | J-Cd (the fake's `setPriority` record) |
| OS-4 | no refresh after `recordBreaker` | T-OS6 |
| OS-5 / OS-6 | `isValid`'s ticket test dropped / one mutator not counted | T-OS5's forced compaction / the running count's debug check, in every suite that re-queues |

## 7. REENTRANCY

- **No await is added.** RE-S26, RE-S25, RE-S21 and RE-S24 stand (`EngineCommands.swift:964`, `:977`, `:979`, `:1148`), and no `// REENTRANCY:` row is new.
- **The walk, C-1's pass and the last notification run between `:975` and `:977` with no suspension.** So `fireDue`, which runs in its own turn (`EngineTimers.swift:104-121`), cannot see OS-1's deferred entries, and OS-4's snapshot never crosses a suspension.
- **B-5's slices and their rows** (B §7) are unchanged. No clock read or random draw is added (C4).

## 8. Found on the way (not routed; estimates)

1. **Production's gate cost is invisible on the bench.**
   - A gate read builds `originID` three times (`EngineOriginGate.swift:71`, `:74`, `:76`, through `EngineFollow.swift:327-340`). `HTTPRemoteSource` parses its URL on every read (`ZTronAssetTransport/HTTPRemoteSource.swift:116-118`, `Policy/TransportSecurity.swift:22-40`). The bench's `FakeRemoteSource` stores the id instead (`ZTronAssetTestSupport/RecordingFakes.swift:363`; `BenchSyncCycle22Purge.swift:302`).
   - At 0.5-2 µs a build (unmeasured), 10,000 gate reads cost 15-60 ms more.
   - **OS-0** caches the id when `remote` is set (`EngineLifecycle.swift:280`), for all 36 reads in ZTronAssetSync. It is sound only if a source's id is constant for its lifetime. HTTP's `configuration` is a `let` (`HTTPRemoteSource.swift:12`), but `RemoteSource`'s doc does not say so (`ZTronAssetModel/Transfer/RemoteSource.swift:90-91`). Stating it changes a public protocol's contract: NEEDS-HUMAN-REVIEW.
2. **Heap scans outside a walk.**
   - `readmit` scans the heap once for each failed candidate (`EngineReadmission.swift:165-167`), up to 512 a turn (`:101`). `removeJob` does the same outside a walk (`EngineJobs.swift:517-520`), up to 512 releases a turn (`EngineCommands.swift:389`).
   - With 5,000 to 10,000 `.retry` entries, that is 512 × 53-107 µs ≈ 27-55 ms a turn, from the derived 10.7 ns an entry. The shape is in letter.
   - Unreviewed sketch of a route: OS-1's deferral around each batch, with one pass after it (0.65-1.0 ms).

## 9. Hours (estimates, at f3:336's 1-1.5 h a part; N22 2(e) stop in brackets, 1.5 × the top)

| Part | Hours |
|---|---|
| OS-1 | 1.5-2 [3] |
| OS-2, with the `transition` split | 3-4.5 [6.75] |
| OS-3 (a) and (b) | 2-3 [4.5] |
| T-OS1 to T-OS5 with J-Cm | 2.5-4 [6] |
| The four bench cases with their 'before' figures | 1-1.5 [2.25] |
| About 16 mutants, in the orders that reach them | 1.5-2.5 [3.75] |
| Records: the draft, 12.5.15's audit extended to OS-2's and OS-3's callees, DECISIONS | 0.5-1 [1.5] |
| **Core** | **12-18.5** |
| OS-4 with T-OS6 / OS-5 / OS-6 / OS-0 | 2-3 / 1-1.5 / 1-1.5 / 1-2 |
| Stage C for these shapes (A7's audit extended to OS-2's and OS-3's arms) | not estimated |

- **The review's figures** (3.5-5.5 h and 2-3 h) cover the parts alone. The same parts are 6.5-9.5 h here; the rest is tests, benches, mutants and records.
- **Not included:** route C's 19-28 h and item 3b's 17-26.5 h.

## What the ruling must say

1. **Status and place.** f3c is the route for N25's three known misses if the package re-opens, after route C's stage A and item 3b's M-5; it is not item 3c in cycle 23. OS-1, OS-2 and OS-3 come in that order, each its own commit, and OS-4 to OS-6 only on their triggers. failedUserRefused is measured as row 1's second form; rows 4 and 5 stay as N25 rules them.
2. **OS-1 (A-6).** Inside a walk the `.failed` arm leaves its `.retry` to C-1's pass. The pass's predicate is the negation of fireDue's guard, read in place. The record names the widened stale-retry difference and the mid-walk heap that A2.5 already shows.
3. **OS-2.** A class-C job failed at the user lane is re-admitted inside B-2's access when the arm's guard holds. The guard is read before the access, with today's clock reads in today's order. `transition` is split into a `Job` half and an engine half over one `allows` table, and today's callers call both. Every other job, and any walk under a reading or a visit, takes today's settle.
4. **OS-3.** A `.queued` class-C job whose lane falls is re-queued in place: a kept one after B-2, and an emptied, claim-held one with `before ≠ last` after `heldLane = last` and before `claimHeld`. A `.downloading` job keeps today's re-lane (R-SYN-3).
5. **Stages and stops.** These shapes retire no job.
   - For them, stage C runs when, after stage B, a shape is above 8.5 ms by no more than 6 ms. This amends N23 item 7's 3.5 ms, because here stage C also removes the sorted second visit.
   - Stage B runs whenever stage C does, and A7's audit is extended to OS-2's and OS-3's arms. §3's stops apply under N22 2(b) and 2(c).
6. **Tests and kills.** The four bench cases come red first, with their 'before' figures. T-OS1 to T-OS5 with J-Cm, and T-OS6 with OS-4, are green on `9aa337c`. §6's kills are 2/2 in each order that reaches them, and no committed test is changed (G3).
7. **Production's gate cost.** The ruling chooses one of:
   - OS-0, with `RemoteSource`'s doc stating that the id is constant (NEEDS-HUMAN-REVIEW);
   - OS-4, made together with OS-2;
   - a bench fake that builds its id as HTTP does.

   Until then, the failed-user shapes' production cost is "not verified" (G2).
8. **The scans outside a walk (§8.2, 27-55 ms a turn, estimate)** are outside N25's three cases, so under N25 they are reported under the bar now. They are gated as a case, with a 'before' figure and a reviewed route, or taken to the owner (N22 item 4).
