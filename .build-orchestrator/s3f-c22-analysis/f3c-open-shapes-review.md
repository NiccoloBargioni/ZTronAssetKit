# f3c review: the open in-letter purge shapes (independent reader, P4)

Read-only at `9aa337c` (`.worktrees/s3f`). Paths are under `Sources/ZTronAssetSync/Engine/` unless named, and "rulings :n" is `s3-rulings-s3f.md`. I wrote neither f3c nor anything it rests on. Nothing was built, run or measured: every figure is an estimate unless it is marked derived (G2).
- **Process:** one early read-only `grep` (for `struct CircuitBreaker`) ran after a `cd` into the worktree, against the task's rule. It wrote nothing. Every other command used absolute paths.

## Verdict: CORRECTED

- **What holds.** OS-1 to OS-4 give today's answers at stages A and B, in both orders. They keep R-SYN-2, R-SYN-3 and R-SYN-5 and every clause, and they add no await, clock read or random draw.
- **What must change before f3c can be a ruling's base:** a lever that route C already makes (OS-6), the base for the red figures and the pins, a circular stage rule, stage C's answers, and three kills that do not kill as written.

## What holds (traced against the code)

- **OS-1.** `(.queued, .failed)` is not a transition (`JobState.swift:70-80`). The epoch changes only at dispatch (`EngineDispatch.swift:705-706`), and `retryLater` is the only way into `.failed(.at)` (`EngineFailures.swift:269`).
  - So no entry that fireDue's guard skips (`EngineTimers.swift:111`) can fire for its job again. The widened pass changes the heap and the alarm only.
  - `remove` filters the whole sorted array (`DeadlineHeap.swift:74-76`), so 53 µs a scan (derived, s3f:7584, :7617) holds for every disposition except `.untilEntryChanges`.
- **OS-2.**
  - The guard order is `relane`'s (`EngineJobs.swift:327`, `:360`). `metInItsAttempt` is false: the walk's only caller is `performPurge` (`EngineCommands.swift:975`), which holds no reading (`EngineJobs.swift:289-297`).
  - The gate reads the clock itself (`EngineOriginGate.swift:81-83`), and `enqueue` reads it again for `queuedAt` (`EngineJobs.swift:568`). OS-2 keeps both reads, in that order (C4).
  - Nothing pushes between the precomputed place and the push. `reindex` touches no queue, and a probe's abandon re-admits through `unblockOrigin` and only schedules the pump (`EngineFailures.swift:1064-1071`).
  - `.failed → .queued` is always legal (`JobState.swift:78`). Reading the gate before the access keeps S3-R27 item 1's exclusivity rule.
- **OS-3.** The kind is taken after the removal, so every entry lands in its lane's queue (R-SYN-3, `SPEC.md:228`). (b) keeps today's order (`EngineCommands.swift:1051-1058`, `EngineJobs.swift:424-431`), and a `.downloading` job keeps `setPriority` and `pauseIfRefused`.
- **OS-4.**
  - No 429 arrives inside the walk. `endThrottle` clears only an ended throttle, which `admitsThrottleParked` already reads as none (`EngineOriginGate.swift:26-28`, `:40-43`).
  - Inside the walk the breaker changes only in `recordBreaker` (`EngineJobs.swift:456`). T-OS6's shape is real: a half-open breaker rejects every other transfer while its probe runs (`EngineSupport.swift:421-425`).
- **Both orders.**
  - Followed first, the end state equals today's: the tickets and places come in sorted order, and `queuedAt` is equal under the injected clock.
  - Swept first, the jobs hold only waiters. The walk skips them (`EngineCommands.swift:1040-1042`), and the widened pass keeps their `.failed(.at)` entries.
- **§3's arithmetic** reproduces from its own units within 0.1 ms in every row, except claimHeldFalls' baseline (should-fix 1).
- **§8 is right:**
  - a gate read builds `originID` three times (`EngineOriginGate.swift:71`, `:74`, `:76`; `EngineFollow.swift:327-340`). HTTP parses its URL on each build (`HTTPRemoteSource.swift:115-117`), the fake holds a `let` (`ZTronAssetTestSupport/RecordingFakes.swift:363`), and there are 36 reads;
  - the heap scans outside a walk (`EngineReadmission.swift:165-167`; `EngineJobs.swift:517-520`), at 512 a turn, give 27-55 ms a turn.
- **§7:** nothing suspends between `:975` and `:977` (C3).

## Must fix

1. **OS-6 is route C's e2-A2.2, already in stage A.** There `storedCount` becomes a counter, with a recount clause, and the queues compact once, after the walk (rulings :1186; `s3-r28-final.md:102`). f3c still charges 16 lookups for every push (0.08-0.16 µs, §0 and §3). Three things follow:
   - The after-OS-3 figures fall by 0.8-1.6 ms for every row that pushes (the table below). The baselines that include `enqueue` fall by the same amount: 18.0-31.4 and 12.9-23.3.
   - OS-6 is not a lever, so its row, its 1-1.5 h and its share of N22 2(b) go. OS-4 then moves only the failed-user rows, and the re-queue rows reach 3.0-8.2 and 3.5-8.4 at stage C with OS-3 alone.
   - OS-2's and OS-3's compaction check follows A2.2's rule, not a check after every push. "The compaction points are unchanged" does not describe the base.
2. **The base is the re-open's HEAD, not `9aa337c`.**
   - The route comes after route C and item 3b (§0). So the four cases' 'before' figures and the pins ("must say" 6: "green on `9aa337c`") are taken on the HEAD the re-open starts from; N12 rules cycle 23 only.
   - T-OS5 adds fields to T-B1, which will be a committed test by then. Say that this strengthens it (G3), or make T-OS5 a new test with T-B1's set-up.
3. **The stage rule is circular, and it ignores the likely base.**
   - "Must say" 5 runs stage C on figures taken "after stage B", but stage B runs only "whenever stage C does".
   - By f3b-review §4, `oneMemberGroupsFourPerID` closes only at stage C, so N8 is expected to bring stages B and C into cycle 23. At a re-open, OS-2 and OS-3 would then run in table order from their first commit. A7's audit, extended to their arms, comes before them, and its hours belong in the core, not under "not estimated".
   - Where the stages are not in the base, give one decidable trigger after OS-3: run B and C together when a shape is above 8.5 ms by no more than about 7 ms (B 0.9 + C 6.1, estimates).
4. **Stage C is not "order and place only" (§4).**
   - In table order, a failed user job's gate read can come before or after a retirement whose abandon frees the half-open probe (`EngineJobs.swift:456`, `EngineFailures.swift:1044`, `EngineSupport.swift:421-425`). So which jobs T20 re-admits, and which one probes, can differ from visit-first's sorted order.
   - That is at least a backoff difference (S3-R16 item 2), and the answers must be shown equal: A7's audit names it, and T-OS6 runs at stage C in both orders. A different answer is blocking (S3-R16 1(a)).
5. **Three kills do not kill as written (G4; S3-R16 1(e)).**
   - **"`heldLane` written after the kind" survives J-Cc.** An emptied job with no `heldLane` reads `.bulk` anyway (`EngineState.swift:908`), and `last` is always `.bulk` when `before ≠ last`. Take the kind from `last`, so the mutant does not exist, or build a stale `.prefetch` `heldLane`.
   - **T-OS1's edge-owed job cannot exist with "a few jobs".** The edge's own turn re-queues up to 512 (`EngineConditions.swift:126-135`, `EngineReadmission.swift:101`, `:163-171`). Use 513 or more transient failures and purge before the follow-up, as `EngineRegressionCycle17Tests.swift:214-269` does, or cite that test for the guard.
   - **T-OS4's `.failed(.untilEntryChanges)` user job** exists only inside the store reads after a 404 or an integrity failure (`EngineFailures.swift:139-145`, `:490-494`). Hold that read in the test. Otherwise leave the disposition to today's settle, by pass 1's tag, so that OS-2 has no copy of the test to kill.

## Should fix

1. **claimHeldFalls' baseline (§3) is low.**
   - 12.5-23.8 reproduces only if the withdrawal costs C-2′'s moves (0.02-0.06 µs a job). Item 3b's point 7 denies C-2′ to a job whose lane falls.
   - Today's path is `Job.withdrawPurged` of two one-id interests: two `setInterest(nil)`, two releases, the sorted copy and the result arrays, about 0.8-1.3 µs at h = 70-90 ns. With `heldLane`'s own access, the baseline is about 21-34 ms (estimate). The after-OS-3 figure stands.
2. **OS-1's in-place predicate** reads `self.state.jobs` inside the closure of `heap.removeAll`, which overlaps the access to `self.state`.
   - Take the heap out of the state for the pass, as `compactQueuesIfStale` does with the queues (`EngineJobs.swift:608-611`), and read through `values[i]`'s `_modify`.
   - Otherwise, price the getter: 1.7-2.4 ms, f3c's own figure.
3. **Timeouts never feed the breaker.** `.timedOut` is `.neutral` (`EngineFailures.swift:222-233`), and a closed breaker ignores it (`EngineSupport.swift:486-487`).
   - So failedUserRetries needs no threshold care.
   - failedUserRefused needs a named way to open the breaker: a manifest 403 with an empty body (`EngineSupport.swift:468-471`), or a 429.
4. **`purgeTurn` takes no visit order** (`Tests/ZTronAssetKitBenchmarks/BenchSyncCycle22Purge.swift:15-31`, `:186`). The bench cases run once, not "in both orders like its other cases".
5. **`scheduledDeadlines` is a count** (`EngineSupport.swift:58`).
   - T-OS1 asserts `retryScheduled` false for each job instead (`Tests/ZTronAssetSyncTests/Engine/EngineSync1LivenessTests.swift:12-18`).
   - It holds alarm turns while the clock moves (`EngineTimers.swift:78`), since a jittered backoff can be near zero.
6. **Consistency:**
   - §2 places OS-1 "in stage A, right after C-1", against §0 and "must say" 1;
   - for a `.failed` or `.blocked` job whose lane falls, OS-3's "skips it" says neither "today's settle" nor "no settle", and "no settle" would widen item 3b's point 6;
   - OS-2's illegal-transition fallback can never be reached (`JobState.swift:78`), so a debug assertion replaces it;
   - "must say" 4 amends item 3b's point 7 for `.queued` jobs, and should say so;
   - §0's "its top misses 8.5 ms" understates it: the top, 10.8 ms, misses the 10 ms bar.
7. **bulkWaiterFalls' set-up order decides the compaction.** With the waiter first, 10,000 stale bulk entries are left; with the groups first, none. The case must fix one order.
8. **Two corrections:**
   - the bench builds the fake source in `BenchKit.swift:28` and `:302`, not at `BenchSyncCycle22Purge.swift:302`;
   - the queue clause (`EngineCommands.swift:2139-2147`) catches a skipped push, not a push to another kind (f3b-review A1). T-OS1's kind assertion is the killer.

## Re-derived figures (ms, estimates; e2-A2.2 in the base)

| Shape | After OS-1 to OS-3: stage A / B / C | With OS-4, stage C | N22 2(c) / 2(b) after OS-3 |
|---|---|---|---|
| failedUserRetries | 9.6-19.6 / 8.8-18.8 / 6.0-12.7 | 5.2-10.8: the top misses 10 | 19.6 / above about 18.9 |
| failedUserRefused | 8.5-17.8 / 7.7-17.0 / 4.9-10.9 (no push, unchanged) | 4.1-9.0 | 17.8 / above about 18.9 |
| bulkWaiterFalls | 7.1-15.3 / 6.3-14.5 / 3.5-8.4; +2-3 ms with a compaction | as OS-3; +1.4-2 with OS-5 | 15.3 (18.3) / above about 17 (18) |
| claimHeldFalls | 6.6-15.1 / 5.8-14.3 / 3.0-8.2; likewise | as OS-3; +1.4-2 with OS-5 | 15.1 (18.1) / above about 17 (18) |

- **N22 2(b) is per shape.** The failed-user rows can still save B 0.9 + C 6.1 + OS-4 1.9 ms, and the re-queue rows B + C, plus OS-5's 1.0 ms with a compaction. f3c's 21.5 ms applies every lever to every shape.
- **So failedUserRetries' stage-A top (19.6) is above its 2(b) threshold.** A figure in the top 0.7 ms of its own estimate stops the route after OS-3.

## What the ruling must add

1. **f3c stays kept, not appended (N25),** corrected by must-fixes 1 to 5. At a re-open, the base, the triggers and the order follow must-fixes 2 and 3.
2. **§8.2 belongs to cycle 23, not to the re-open.** It lies outside N25's three cases, so the bar applies to it now.
   - Two cases are measured first (G2):
     - a satisfied edge over 10,000 jobs that failed transiently with `.retry` deadlines (T19);
     - a release of a 10,000-member group whose jobs are `.failed(.at)`.
   - No bench covers either: the breaker benches fail about five jobs (`Tests/ZTronAssetKitBenchmarks/BenchSync.swift:1735-1760`).
   - A miss has no reviewed route, so it is a stop for the owner (N22 item 4), and f3c's sketch needs its own review (P4).
3. **§8.1 reaches beyond the failed-user rows.** Every per-job gate read pays three `originID` builds in production, `blockCleared` among them (`EngineJobs.swift:936`), and the bench's fake hides every one. Record those C2 figures as "not verified" (G2), or choose OS-0 (NEEDS-HUMAN-REVIEW) now.
4. **Route C's own stage C in cycle 23 already carries must-fix 4,** because today's `relane` re-admits in the walk's order. A7's rule audits tests' order assertions only (rulings :868-871). So stage C's ruling names this difference, and a probe of T-OS6's shape runs in table order, in both orders, before stage C's commit.
5. **N25's record** gives case 3 as about 21-34 ms (should-fix 1) and case 1's refused form as 11.9-22.5 ms (f3c §3), beside f3b-review §7's figures. All of these are estimates.
6. **The swept-first backoff (f3c §4) is a backoff difference under S3-R16 item 2,** and f3c does not change it: `withdrawPurgedJoins` takes the joins, so the job is never re-laned. The draft records it, with T-OS1 and T-OS1w as its probe. No line of the draft names it (a grep for T20 with the purge, swept first or `withdrawPurgedJoins`).
