# challenge:drain-takeoff

Read-only analysis for ruling S3-R26 (workflow wf_72146a41-b2b, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## verdict

WEAKENED

## correctedVerdict

UNCERTAIN

## correctedConfidence

50

## refutations

- The code path holds; I confirmed it in the code. releaseOneHeldTurn (BenchSync.swift:3457-3467) runs releaseFollowFollowUps() synchronously inside an isolated call, so the timed 47 ms span is one turn: continueFollow (EngineFollow.swift:114-159), then the inline drainEventsAfterFollow(ids: budget.ids) at :158, then replay at :354, then replayVerdict (:607-620), then takeOffMovedBefore (:551-568) and rerouteMovedBefore (:572-576). For this case: followAfterVerdict calls follow, which returns (false, 0) because J is gone (:903-905). retryLater (EngineFailures.swift:244) works on a missing job. Log: reqs/logs/gates/bench.log:267 gives [47.03, 47.12, 47.31] ms with 4 held turns. correct/logs/bench-rerun.log:33 gives [47.90, 50.46, 47.03] ms, and the correct-lens issue records [49.08, 52.47, 52.25]. So best of 3 drifts from 47.03 to 49.08 between windows, and the 32 ms target needs a 32-35% cut, not 32%.
- Confirmed: no observers are registered in this benchmark. movedBeforeDrain (BenchSync.swift:3278-3395) polls with Task.yield and calls neither waitUntil nor awaitCondition, so notifyObservers (EngineCommands.swift:1679) and notifyConditions (:1665) return on their isEmpty guards. The analyst missed the notifyConditions half, but the conclusion stands. decisionNow (EngineFollow.swift:241-243) is cheap here because the drain runs under withReading. isReleasedOnly (EngineDispatch.swift:288-291) short-circuits because releasing is empty. Job.lane is O(1) through interestCounts (EngineState.swift:761-763). relane (EngineJobs.swift:262-) does nothing for a queued prefetch job whose lane is unchanged. The per-id path is linear, as claimed.
- Confirmed: 3 formats per id. reroute formats at EngineDispatch.swift:1164 (isBound) and :1179 (pending), and addInterest formats at EngineJobs.swift:109. noteJoin (:190-205) uses sameTransfer and formats nothing. The format itself (ContentHash.swift:74-95 and TransferID.swift:45-47) allocates more than the analyst counted: the digits array, the [w0..w3] literal (possibly stack-promoted, INFERRED), the bytes result, the scalars, String(decoding:) and the concatenation. That is about 5-6 allocations, which supports the analyst's 0.35-0.6 µs per format (INFERRED).
- The attribution is credible but not established, and the uncertainty runs pessimistic. Cross-check: concentrationCommitRerouteTurns has a commit window of 9.82-10.23 ms with 0 re-routes and 47.99-51.40 ms with 10,000 (bench.log:249,252; bench-rerun.log:7,21). The 38-40 ms difference covers more than the re-routes. Per id it adds a filter and a format plus compare at EngineDispatch.swift:1110,1124, plus a 10k sort. Taking those out leaves about 27-33 ms for the 10k reroute+join calls, about 2.7-3.3 µs each. The source's own figure is 'about 5 µs' per re-route plus join (EngineMoves.swift:120-121). Applied here, take-off plus fixed work is about 14-20 ms (INFERRED), not the analyst's 7-13 ms. The re-routes are less dominant than claimed, so format-only fixes reach less.
- F2b as written is a correctness bug and could change answers. ManifestEntry's identifier, remotePath and checksum are `public var` (ManifestEntry.swift:49,53,61). A stored transferID computed only in init goes stale when one of them is mutated. 18 test sites mutate these fields. Concrete case: EngineStoreTests.swift:27-31 sets `changed.checksum = ...`, then scripts `changed.transferID`, which would return the old transfer. Synthesized Equatable/Hashable would then compare a stale field. A correct version needs a didSet on all three properties to recompute it. Alternatively, precompute transfers in the immutable ValidatedManifest (ValidatedManifest.swift:15,30: `let entries`, `private let positions`), whose constructors are all outside the engine actor (IndexCodec.swift:433, AssetStore+Apply.swift:427, ValidatedManifest.swift:177). That second option moves about 10k formats (~4-6 ms, INFERRED) into the store's or decoder's turn. Both are public model-type changes: P1 makes them orchestrator-owned, and CLAUDE.md requires NEEDS-HUMAN-REVIEW for them.
- F2' is not a free engine-local change. ContentHash.hex also names the blob files (fanOut at ContentHash.swift:97-99 is the blobs/<aa>/ directory), so any output difference changes the on-disk layout. Byte-identical output is required and must be pinned by tests. C1 rules out String(unsafeUninitializedCapacity:), which leaves about 2 allocations, roughly 0.12-0.2 µs. After F1 that saves only about 2-4 ms.
- F1, F3 and F4 hold up as non-splitting, answer-preserving changes that add no branch. Checks: ManifestEntry.transferID is pure (ManifestEntry.swift:110-115). F3's index is used only between EngineJobs.swift:132 and :163; noteJoin runs before it at :129, and Dictionary.Values has an in-place _modify. failFastJoiner must keep its key-based reads, because failFast can resolve, which runs dropInterest, then retire, then removeJob (EngineJobs.swift:346-388). F4's sorted(interest.assets ∩ held) produces the same sequence as today, and subtractAssets exists (EngineState.swift:801-803). My estimates differ from the analyst's. F1: 7-12 ms. F2': 2-4 ms. F3: 2-5 ms. F4: 1.5-2.5 ms, since the 10k sort stays. Sum on the 47.03 ms best: 23.5-34.5 ms, center about 29 (INFERRED). On the 49.08 ms window: 25.5-36.5 ms. The 32 ms bound holds only around the center of that range, so FEASIBLE at 65 is overconfident. I put P(≤32 ms) at about 55-60% for this one grouping.
- The verdict ignores groupings the bar requires. Rulings S3-R22 to S3-R25 say 'however grouped', and there is no benchmark for a 10,000-user-waiter or many-groups version of this shape (grep shows no movedBeforeDrainWaiters in BenchSync.swift or the probes). In that shape each token's take-off calls removeInterest, then dropInterest (EngineJobs.swift:346-366; relane returns early at :286-294). Each user join calls relane, which does `isUser`, then enqueue (EngineJobs.swift:269-271), then a Job copy plus write-back, a ticket and a queue push (:474-489) once per id. reroute's .waiter arm copies and writes back waiters[token] (EngineDispatch.swift:1170-1175). My estimate for that shape: 60-75 ms today and 45-55 ms after F1-F4 (INFERRED). That would miss the 32 ms target, and likely the 40 ms ceiling as well, unless the per-id re-enqueue is also fixed. The precedent is PROBE-C19C-USER-SHARED-C2, where the user grouping ran 33-71 ms while the group case passed.
- F7 is fine, with a precedent the analyst missed. AssetID.hash already uses withContiguousStorageIfAvailable with a generic fallback (AssetID.swift:66-71), and that fallback's drop-mutant is likewise unkillable by any answer test. The bench ids 's%05d' are small strings, which are fast UTF-8, so the fast path applies. The saving is 1.5-4 ms, as the analyst says (INFERRED).

## missedFix

No cheaper branch-free fix beyond F1, F2', F3 and F4. Ranked by value:
(a) A correct F2b: precompute transfers once in the immutable ValidatedManifest and read them through `transferID(for:)`, or keep a didSet-maintained cache on ManifestEntry. Either removes the last format per id, a further 1.5-2 ms after F1+F2'. It is a model-type change and needs NEEDS-HUMAN-REVIEW.
(b) For the waiter grouping: make relane's per-id re-enqueue of an already-queued user job cheap. Write the ticket and queuedAt in place instead of copying the Job and writing it back at EngineJobs.swift:475-483. That is constant-factor work and adds no branch. Skipping the intermediate enqueues would need a batch path, which adds branches.
(c) Pass the manifest entry that reroute already looked up into noteJoin, saving the second applied lookup at EngineJobs.swift:191 (about 1-1.5 ms). It needs a branch whose drop-mutant is equivalent, so under G4 it needs a ruling.
(d) Hoist `let current = self.state.jobs[transfer]?.state` in failFastJoiner for the two leading tests, as F3 already proposes.
The analyst did not call anything NEEDS_SPLIT wrongly.

## answerRisks

- F2b as written (stored in init only) changes answers. Any code that mutates checksum, remotePath or identifier after init gets a stale transferID and stale equality; see EngineStoreTests.swift:27-31. Use the ValidatedManifest index or a didSet cache instead.
- F2' rewrites ContentHash.hex, which also names the blob files and the fan-out directory. A byte difference changes the on-disk layout, which touches a NEEDS-HUMAN-REVIEW area.
- F3: the Dictionary.Index must not live past a structural mutation of jobs. It is safe between EngineJobs.swift:132 and :163, but not across noteCircuitParked, reinstate, relane or failFastJoiner, because failFast can retire the job. A later edit that adds a call inside that window would silently corrupt state. Re-read by key after the window.
- F1 adds an addInterest overload; the forwarder keeps the other callers identical.
- F4: the order of `off`, and so the re-route order in both LaneDropVisit orders, is unchanged, and so is the point at which removeInterest runs.
- No fix touches an invariantViolations() or followBarrierViolations() clause, and none adds deferred state.
- The residual risk is not to answers but to the bar. The un-benchmarked waiter and many-groups groupings may still exceed 32-40 ms.

## cycleEstimate

2-3 cycles for the single-group benchmark alone; 3-4 cycles for the whole shape as the bar defines it.

- Cycle 1: implement F1+F2'+F3+F4. The expected figure is about 24-35 ms. F2' and F2b need orchestrator sign-off, because they change model types.
  - About 55-60% chance it lands at or under 32 ms best of 3. Otherwise a second cycle adds the ValidatedManifest transfer index and F7.
  - These fixes add no branches, so the G4 2/2 drop-mutant load is about zero. The correctness lens should pass S3-R16 1(a) and 1(e) on the first try.
- Next cycle, likely: the reqs lens will probe the 10k-user-waiter and many-groups variants. The precedent is PROBE-C19C-USER-SHARED-C2. Those variants are estimated at 45-55 ms even after F1-F4, which forces another constant-factor cycle on relane, enqueue and dropInterest, and possibly a ruling.
- About 25-35% chance the waiter grouping cannot reach 32 ms without batching. Batching adds branches, and their drop-mutants are equivalent under G4.

Cheapest settling measurements:
1. Apply F1 alone and rerun movedBeforeDrainTurns at load ≤ 10, best of 3. A result of 38 ms or less confirms the format attribution.
2. Add a movedBeforeDrain variant with one user waiter per id, and one with 10k single-id groups, and measure both today.
3. Optionally, take one release Time Profiler trace of the existing case.
