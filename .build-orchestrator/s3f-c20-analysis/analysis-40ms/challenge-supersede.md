# challenge:supersede

Read-only analysis for ruling S3-R26 (workflow wf_72146a41-b2b, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## verdict

WEAKENED

## correctedVerdict

UNCERTAIN

## correctedConfidence

60

## refutations

- MEASUREMENT CONFIRMED. rel-superq.log:7-10 gives windows [41.833, 41.275, 41.094] ms, best 41.094. The 1-minute load was 4.44, then 4.24 (rel-superq.log.meta). rel-super1.log.meta shows a start load of 546.08, and rel-super1.log hit the 600 s time limit, so that log is unusable. The window is SyncBench.longestWait (BenchSync.swift:1407-1430): a high-priority heartbeat records its longest single wait on the engine actor. That is one actor turn, not a sum of turns. No module sets a custom executor (grep unownedExecutor: none), so store-actor work is not counted.
- CODE PATH CONFIRMED, line numbers off by 1-2. publicationFailed is at EngineDispatch.swift:1192, not :1191. It is entered synchronously from the catch at :1061, and the .superseded arm at :1205-1211 has no await, so the arm, supersede (:1256-1280) and reconcileIdle all run in one turn. In addInterest the cited lines are off: the if-let job read is at EngineJobs.swift:132 (not :131), assets.insert at :156 (not :155), the isCircuitParked read at :165 (not :164; when it is true, a second `let job` lookup is bound there too), relane at :177 (not :179), failFastJoiner at :179 (not :180).
- LOOKUP COUNT CONFIRMED: 9 jobs[transfer] accesses per joined id on the non-parked join path. They are :132, :156, :157, :161, :165, relane :264, and failFastJoiner :225, :232, :244. The 3 TransferID formats per group id are also confirmed: reroute :1164 and :1179, and addInterest :109. Each format allocates several times (ContentHash.swift:74-95; TransferID.swift `content` does `"c-" + hash.hex`). INFERRED: some of the 'Job copies' the analyst counts may already be narrowed to field loads by the optimizer, because Dictionary's getter is @inlinable. A copy is certain only where the whole Job is bound and handed to a non-inlined callee: :132 to isReleasedOnly, and relane's guard. So bucket (b), 10-13 ms, is the upper end. A pessimistic figure is about 5-8 ms: hashing a 66-byte String plus a probe costs about 50-70 ns per lookup, plus exclusivity checks on self.state.
- LINEARITY CLAIM OVERSTATED. The 1,000-id run at 4.47 ms is the first, cold run of the process, while the 10,000-id runs come later and warm. So a ratio of 9.2x for 10x the ids does not show linear scaling. It is consistent with mild superlinearity from cache misses in the 10,000-entry sets and dictionaries. No O(N^2) term is visible in this shape: DeadlineHeap.remove (DeadlineHeap.swift:74-76) is O(H), with H small (INFERRED), and notifyObservers/notifyConditions return early when the observer tables are empty (EngineCommands.swift:1665-1683). The probe registers neither kind of observer (INFERRED from the probe source).
- F1 HOLDS. It is a pure value-threading change. TransferID is a pure function of the entry (ManifestEntry.swift:110-115), so it adds no branch and no deferred state, and stays within one turn. Estimated saving: 2 formats x 10,001 ids x 0.3 us, per the in-code figure at EngineState.swift:966-967, which is about 6 ms. The range is 5-8 ms, giving 33-36 ms. Risk: the new `transfer:` parameter on addInterest creates an implicit precondition, transfer == entry.transferID, at every caller (addSystemInterest :198; EngineRuns.swift:499; the manifest join; the drain's JoinAfterFollow replays). A caller that passes the wrong value would key a job wrongly with no compile error. The safe form is to add the parameter only on a reroute-private path, or to keep the parameter and add a debug assertion. An assertion is a branch, so it needs care under G4.
- F2 'NO NEW BRANCHES' IS WRONG AS WRITTEN. Hoisting `!self.state.releasing.isEmpty` ahead of the job read, so that the pre-join job is read only when releasing is non-empty, adds a condition whose drop-mutant is behaviour-equivalent: isReleasedOnly (EngineDispatch.swift:288-291) re-checks the same condition. That mutant cannot be killed 2/2, so S3-R16 1(e) fails. The same trap catches any 'skip' fast path. A branch-free F2 keeps the one if-let read at :132, which is needed for `before` and wasReleasedOnly. It replaces :156-161 with a single in-place Job.join modify, takes isCircuitParked from the state that join returns, passes (after, state) to a relane body whose .failed and .blocked arms still read the job (EngineJobs.swift:285-305), and reads state once in failFastJoiner, refreshing that local after readmitOpenedOriginGates. That cuts 9 accesses to about 4, not 2. Moved branches (insertAsset vs setInterest; the relane arms) still have to be re-shown as killed 2/2 in both orders, which costs one verifier pass even when nothing is wrong.
- F2 ESTIMATE IS OPTIMISTIC. The analyst gives 27 ms (24-31) after F1+F2. The pessimistic reading is about 5 removed lookups x 10,001 x 60-100 ns, which is 3-5 ms, plus 0.3 ms for moving the clock read. That gives about 28-33 ms after F1+F2 on the measured group shape. The 32 ms margin is therefore a coin flip at the pessimistic end, not a likely pass.
- F3 HAS A G4 TRAP. The proposed `self.state.run?.outstanding[transfer] != nil` guard condition is redundant before an optional-chained `?.remove(asset)`, so its drop-mutant is equivalent and cannot be killed. Write it as `guard self.state.run?.token == token`, then the in-place remove, then the existing empty-to-nil decision. Its O(N^2) diagnosis is confirmed in the code (EngineRuns.swift:505-512): `var run` and `var claimed` copies, then claimed.remove, copy-on-write-copy a set of up to N elements for each id. The run grouping is not reached by the measured shape.
- MISSED SHAPE AT THE SAME SITE: spread destinations. The store throws .superseded when no record still wants the bytes. An apply that maps each of the 10,000 ids to its own new content (analyse-state-cost.md:156 names this case) makes supersede take the creation path (EngineJobs.swift:137-153) 10,000 times in one turn. Each id then pays 3 formats, a Job init (allocates the asset set, the interests dictionary and the interest's asset set), a launchResumes removal, enqueue (EngineJobs.swift:474-489, a Job copy and write-back plus a queue push), ensureWatcher and notifyObservers. F2 does not touch that path. This variant is unmeasured; estimate 40-70 ms now and 35-60 ms after F1 (INFERRED). C2 applies to any single turn at 10,000 ids, so on the pessimistic reading it is in scope.
- USER-WAITER-PER-ID VARIANT. The analyst estimates 45-60 ms; that is plausible but likely low. rel-userq.log shows 512 user waiters moved per follow turn in 3.4-5.6 ms, which is 6.6-11 us per moved id. Here every join re-enqueues (EngineJobs.swift:270-273). With only about 3 jobs in the table, compactQueuesIfStale's threshold of 2*jobs.count+16 (EngineJobs.swift:514-516) fires about every 16-20 enqueues. Each id also allocates a JobInterest set and a 1-element sorted() array. Estimate 50-70 ms now and 35-50 ms after F1+F2 plus the enqueue extension (INFERRED). That is likely above 32 ms and borderline at 40.
- SORT MUST STAY, which the analyst got right implicitly. supersede's sorted order (EngineDispatch.swift:1266-1272) decides which id's entry creates D. The creating id's entry becomes Job.entry, the representative entry, with its remotePath (EngineJobs.swift:139-146), and it also fixes the ticket and join order. Replacing the sort would change caller-visible requests.
- VERDICT. UNCERTAIN stands, but the analyst's confidences are too high. My estimates: the measured group shape reaches 32 ms or less with F1 plus a branch-free F2 at about 55%, and 40 ms or less at about 90% (F1 alone probably clears 40). Every grouping and destination spread at this site reaches 32 ms or less without a split at about 30%.

## missedFix

There is no single cheaper fix that settles the shape. There are three refinements, plus one larger orchestrator-owned option.

(1) Write F2 branch-free. Keep the :132 read. Replace :156-161 with one in-place mutating Job.join. Take isCircuitParked and the relane input from the state that join returns. Read state once in failFastJoiner, and refresh it after readmitOpenedOriginGates. Do not hoist releasing.isEmpty: its drop-mutant is behaviour-equivalent.

(2) Reserve capacity on the creation path inside supersede. reserveCapacity for D.assets and the new interest's set, sized to interest.assets.count, removes about 14 rehash doublings per set, about 1 ms (INFERRED). Risk: Set iteration order changes. Every answer path must be audited for unsorted Set iteration.

(3) Larger than the analyst's F1b, owned by the orchestrator and tagged NEEDS-HUMAN-REVIEW, since it changes a contract type. Store transferID in ManifestEntry at decode and validation, as a `public let` replacing the computed var. That removes all 3 formats per id at this site and also at the RR-21 commit re-route (47.99-49.35 ms) and in follows. It adds no branch. Cost: about 3 ms of formatting for 10,000 checksummed entries, and 10,000 SHA-256 calls for legacy entries. Both move into manifest validation, which must stay off the engine actor's turn and off the main thread (C2). If ManifestEntry's Equatable and Hashable are synthesized, they change shape but not meaning.

The F2 hoist and a memo of the last TransferID inside the loop were both rejected: each adds a perf-only branch whose drop-mutant cannot be killed 2/2.

## answerRisks

F1:
- The new addInterest `transfer:` parameter creates an implicit invariant, transfer == entry.transferID, at every caller: addSystemInterest, EngineRuns.swift:499, the manifest join, and the JoinAfterFollow replays.
- A wrong value would key the job, the joinsAfterFollow entry (EngineJobs.swift:112) and unfollowed under the wrong TransferID. That breaks invariantViolations() and would differ between LaneDropVisit orders.
- Safer: keep the parameter only on the reroute path, or recompute it in deferred replays.

F2:
- Moving the insertAsset/setInterest choice into Job must keep interestCounts updates identical, since invariantViolations recounts them.
- The relane variant must keep the .failed arm's attemptEnd.deferredAfter early return and its retry-heap removal by job.epoch (EngineJobs.swift:285-299), and the .blocked arm's blockCleared(job:) read, all from a fresh table read.
- failFastJoiner's local state must be refreshed after readmitOpenedOriginGates, and after the first branch's transition, which returns.
- The decisionNow move is safe: the live and manual clocks have no side effects (ManualTimeSource.swift:72-74). In a racy test that advances the clock on another thread, the value read can shift slightly.

F3:
- Must keep the token check and the empty-key removal, or checkRunSettled never settles.
- Its in-place form must not keep a live copy of state.run, or copy-on-write returns silently.

reserveCapacity:
- Changes Set iteration order. Any unsorted iteration that feeds an answer or a place differs between runs. Mitigated only because hashing is already per-process seeded (INFERRED).

Stored TransferID:
- A public contract change (P1, NEEDS-HUMAN-REVIEW).
- Moves SHA-256 work for legacy entries into validation, which could create a new C2 turn if validation runs on an actor.

All of the above:
- They touch shared helpers (addInterest, relane, failFastJoiner, enqueue) that the follow, drain and RR-21 paths also call.
- Both LaneDropVisit orders and the followBarrierViolations() suite must be re-run, not just the supersede probe.

## cycleEstimate

2-4 fix-and-verify cycles at a 40 ms ceiling, with roughly a 50% chance that at least one variant at this site still ends in a split. Reasoning:

Cycle 1:
- Apply F1, a branch-free F2, the enqueue single-modify, and F3.
- The group shape probably lands at 28-33 ms (INFERRED), passing 40 ms but only possibly meeting the 32 ms margin.
- Both adversarial lenses have probed new groupings at every cycle in the C19 and C20 history. They will very likely build the one-user-waiter-per-id and spread-destination variants at this site. Estimated after the fixes: 35-50 and 35-60 ms (INFERRED). At least one is likely to fail 32 ms, and possibly 40 ms.
- The moved branches (Job.join, the relane arms, the failFastJoiner refactor) must be re-shown as killed 2/2 in both orders. Any perf-only conditional that slipped in gets a G4 finding.

Cycle 2:
- Either the orchestrator-owned stored TransferID in ManifestEntry (needs a NEEDS-HUMAN-REVIEW decision, plus contract-test churn), or a batched join for consecutive ids with the same destination.
- The batched join is high answer risk: failFast(only:) per join, ticket and join order, and the representative entry. Its boundary branch needs its own killing tests.
- Or concede a split for the failing variant.

Cycle 3 verifies, and cycle 4 is likely if cycle 2's batching moved any answer under S3-R16 1(a).

Cheapest settling measurement, before any cycle and about 15 s of release runtime at a 1-minute load of 10 or less, on 8e1fb24:
- Add two variants to VerifyC20SupersedeBench: 10,000 user waiters instead of the group, and v4 mapping each id to its own content.
- Record their baselines, then apply only F1 and rerun all three.
- If both variants' baselines are 45 ms or less and F1 brings the group shape to 35 ms or less, the verdict becomes FEASIBLE_WITHOUT_SPLIT.
- If either baseline is over 55 ms, this site needs the stored-TransferID contract change or a split.
- Alternative with no code change: an xctrace Time Profiler run of the existing probe. Check the share of ContentHash.hex, TransferID.content, Dictionary<TransferID, Job> lookups, swift_beginAccess, and retain/release.
