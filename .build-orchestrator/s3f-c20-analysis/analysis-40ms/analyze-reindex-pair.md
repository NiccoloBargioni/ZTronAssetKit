# analyze:reindex-pair

Read-only analysis for ruling S3-R26 (workflow wf_72146a41-b2b, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## shape

Two shapes. Shape (1) is MOVE: owed one-id moves off one 10,000-id holder H, made in one follow turn by continueInbound. Shape (2) is DEFERBEHINDVERDICT: H's bounded visit joins 512 ids per turn behind O's waiting exit verdict, and each join is inserted into eventsAfterFollow right after that verdict. Neither shape has a BenchSync case at 8e1fb24: Tests/ZTronAssetKitBenchmarks/BenchSync.swift has no manyMoves, partialMove or deferBehindVerdict case, and c2Budget = 10.0 is at :129.

## measuredTurn

MOVE (PROBE-C20C-MANY-MOVES, correct/logs/rel-manyq3.log). The held turn is continueFollow (EngineFollow.swift:114-117), which calls continueInbound(&budget) with FollowBudget(holders: followsPerTurn = 256 (:11), ids: 512).
- continueInbound loops over the owed moves (:1214-1240). For each move, :1220 binds `let holder = self.state.jobs[move.holder]`, a live copy of H's Job, and keeps it alive across the call. :1226 computes holder.assets.intersection(move.ids), and :1227 calls startMove(ids, of: holder, ...).
- startMove's fit path (EngineMoves.swift:141-142) calls move(moved, of: job, listing:).
- In move (EngineFollow.swift:931-955), the supersede test at :933 is false (1 id != 10,000). Then:
  - :944 `assets.subtract` runs while the copy is alive, so it copies H's 10,000-id Set on write.
  - :945 sorts job.interests.
  - :946 runs `interest.assets.sorted() where moved.contains(asset)`: a full sort of the group interest's 10,000 AssetIDs, plus a 10,000-id contains filter.
  - :947 removeAsset copies the interest's 10,000-id Set on write (the copy at :1220 shares its storage).
  - :948 reroute → addInterest joins the publication target at once (bringingInbound is true, EngineFollow.swift:1209), then :1239 inboundMade.
- The probe's H is one prefetch group: registerGroup gives one token holding 10,000 ids (VerifyC20CorrectProbes.swift:305-441).
- Log, best of 3: k=1 8.22 ms; k=16 79.55 ms; k=64 304.79 ms. Thread CPU equals wall time. The next follow turn is about 1.3 ms. Violations [].

DEFERBEHINDVERDICT (PROBE-C20C-DEFER-BEHIND, correct/logs/rel-deferq.log; PROBE-C20R-DEFER-BEHIND-C2 in reqs). The call path:
- continueFollow → continueVisitRemainder (EngineFollow.swift:820-847), under withReading;
- → continueMove (EngineMoves.swift:179-226), which moves 512 ids a turn (followIDsPerTurn, EngineMoves.swift:126);
- → per id, reroute (EngineDispatch.swift:1147-1189) → addInterest;
- → the branch at EngineJobs.swift:117-121 (inFollowVisit, !bringingInbound, target.attemptEnd.deferredAfter != nil);
- → deferBehindVerdict (EngineFollow.swift:964-978).

deferBehindVerdict does three things per join:
- :965-973 binds a local `events` and runs a backward lastIndex scan to O's verdict. Every earlier deferred join sits after the verdict, because each is inserted at verdict+1, newest first.
- :976 eventsAfterFollow.insert(at: verdict+1) shifts every later element. The log prints the stride as 168 B.
- :977 eventStamps.insert shifts the stamps. WorldStamp is MonotonicInstant(UInt64) plus Int, so 16 B (EngineFollow.swift:1531-1536; Time.swift:10).

Log figures:
- Per turn: 6.90 ms at E=513, 20.85 ms at E=4097, 39.55 ms at E=9217→9729. The best of 3 was 39.55 ms, at a 1-minute load of 9.82.
- reqs, best of 3: 35.78 ms and 36.52 ms at quiet loads.
- Control (the same joins landing in place): 8.70 ms.
- Drain turns: about 3 ms.

## costModel

MOVE: turn ≈ base + k × c_move.
- Linear fit to the log: c_move ≈ 4.7 ms ((304.79-8.22)/63 = 4.71; (304.79-79.55)/48 = 4.69). Base ≈ 3.5-4.4 ms.
- What dominates c_move (INFERRED from the code plus the fit): the O(N log N) sort at EngineFollow.swift:946.
  - AssetID `<` is utf8.lexicographicallyPrecedes (AssetID.swift:76), about 30-40 ns per compare × about 130k compares ≈ 4-5 ms.
  - The rest is O(N): the 10,000 hashed moved.contains checks (about 0.2-0.3 ms), plus the two 10,000-id copy-on-write Set copies caused by the copy at :1220 (about 0.1-0.4 ms).
- Complexity: O(k × (N log N + N)) for k owed moves off an N-id holder.
- Per-id grouping (INFERRED, unmeasured): with one user waiter per id (T = 10,000 interests), :945 sorts 10,000 tokens and :946 allocates a 1-element array per token. The copy also clones the 10,000-entry interests dictionary. That is O(k × T log T), about 2-3 ms per move (INFERRED).
- Worst case per turn: k = 256, the budget.holders limit (EngineFollow.swift:11, :1214-1218).

DEFERBEHINDVERDICT: per join, an O(E_after) backward scan plus two O(E_after) memmoves (168 B and 16 B per element).
- Measured slope: (39.55-6.90) ms / (9217-513) E per 512-join turn ≈ 7.3 ns per element per join. reqs' 34.29/36.29/38.13 ms at E 8705/9217/9729 gives the same 3.75 ms per 1,000 E. Intercept ≈ 5.0 ms (correct shape) and ≈ 1.7 ms (reqs shape).
- 7.3 ns per element matches the memmove of a 168-B stride plus a strided tag scan (about 3-5 ns). A copy-on-write copy of the queue from the local `events` at :965 would need about 30-40 ns per element (element copy plus retains of the ManifestEntry strings). So the optimizer drops `events` before the insert today (INFERRED).
- The turn is O(512 × E) and grows over the follow. E counts every waiting event after the verdict, so tail events (for example 10,000 deferred user requests) roughly double it (INFERRED).

## fixes

- {
 "change": "MOVE-M1, the smallest change: remove the sort, the filter and the live Job copy; no index. (a) continueInbound (EngineFollow.swift:1220-1227): do not bind a Job copy. In the existing condition, bind only a snapshot without Set storage, with the held ids computed as move.ids.filter(job.assets.contains), for example `let holder = self.state.jobs[move.holder].map { MoveHolder($0, moving: move.ids) }`. (b) startMove and move take the TransferID or that snapshot instead of `job: Job` (EngineMoves.swift:140-142; EngineFollow.swift:931-933). (c) In move, before :944, take one scoped snapshot of rows (token, JobInterest(lane:kind:assets: []), held = movedSorted.filter(interest.assets.contains)) for every token, sorted by token. Run today's body per row: removeAsset, reroute with the stub, and today's per-token empty check, kept for every token so that nothing relies on I3. (d) Sort `moved` once per move. That is O(m log m), m being the moved ids.",
 "estimatedMs": "INFERRED, unmeasured. Measured group shape (T = 1 interest): about base 3.5-4.4 ms + k \u00d7 (reroute and join \u2248 5-10 \u00b5s, per EngineMoves.swift:121's 'about 5 \u00b5s'). k=16 \u2248 4-5 ms; k=64 \u2248 4-6 ms; k=256 \u2248 6-9 ms. Per-id grouping (T = 10,000 user waiters): O(T) per move, from the rows scan (one AssetID hash per token, about 25-30 ns) and the all-token sort and empty check, about 0.35-0.6 ms per move. design2-move-index.md's rejected alternative (b) gives the same 0.3-0.6 ms. So k=64 \u2248 26-42 ms and k=256 \u2248 90-150 ms. M1 passes 32 ms only in the measured grouping. It misses the per-id grouping at k=256 and is marginal at k=64.",
 "splitsWork": false,
 "whyAnswersUnchanged": "The (token, asset) pairs and their order are unchanged. Today's order is tokens ascending (:945), then sorted(interest.assets \u2229 moved) (:946), which is the same sequence as movedSorted filtered by interest.assets.contains. AssetID ==, hash and < are consistent (AssetID.swift:56-77). The snapshot is taken at the same point (before :944) from the same table state: no mutation lies between :1220 and :944. reroute reads only interest.kind and interest.lane (EngineDispatch.swift:1147-1188); continueMove already passes the same stub (EngineMoves.swift:202). The order of `ids` does not matter: move sorts, and the bounded path heapifies. The supersede test reads the same count, state and active attempt. No invariantViolations or followBarrierViolations clause changes.",
 "newBranches": "0 new decision branches, provided the snapshot is taken inside the existing `let holder =` binding at :1220 and follow's `guard let job` at :903. The `where moved.contains` clause at :946 becomes a filter on interest.assets.contains, the same predicate, whose existing kill is reused. A scoped read through `self.state.jobs[t]?` with `??` or `if let` instead would add 1 unreachable nil arm per read; B7 records that as the default of the optional-chaining idiom, but it cannot be drop-mutant-killed. Pins only (no branch): a BenchSync manyMovesTurns case, k = 1/16/64/256, best of 3 at or under the bar.",
 "answerRisk": "low"
}
- {
 "change": "MOVE-B-reduced: the index from integrate-c21.md part B without its behaviour changes. Keep B2-B6 (IDTokens, the tokensByID index kept by every Job mutator, holdings(of:) sorted by (token, asset)), B9 (follow's copy ends in a helper that keeps unfollowed.insert, critic A8) and B10 (continueInbound holds no holder copy). Keep moveItems for the bounded path without the unheld subtraction. Drop B7's subtraction of unheld ids, B8's re-insertion and I2: those change observations (critic R2; T5 asserts a start count that changes, '2 sweep-first' today). An optional simpler variant indexes [AssetID: Set<InterestToken>] instead of IDTokens. That removes IDTokens' first/others arms (NB1-NB4) and leaves one release-to-nil branch; at a 40 ms bar its allocation per id is affordable (design2's +50-80 ns per join).",
 "estimatedMs": "INFERRED. Both groupings: each move costs O(moved + holders). k=64 \u2248 4-6 ms (design2 c2_argument); k=256 \u2248 6-11 ms (critic-move-index R6). PARTIAL-MOVE users=true \u2248 6-7 ms; users=false \u2248 4-5 ms. Costs the index adds elsewhere: the commit window gains 40-90 \u00b5s to free a 10,001-entry index; releasing an n-id interest costs O(n), about 0.5-1 ms at 10,000; each live Job copy pays one more copy of the index. All are well under a 40 ms bar.",
 "splitsWork": false,
 "whyAnswersUnchanged": "holdings(of:) returns the same pairs in the same (token asc, asset asc) order as :945-946 while I1 (the index equals a recount from interests) holds. The per-pair empty check equals today's per-token check if no token without a moved id is empty, which is I3 (every writer removes an emptied interest; integrate-c21 I3 lists them). The design as written is not answer-neutral: B7 changes what the bounded path's readers see (binding, 404 record), and B8 changes Q1's transport starts. That is why both are excluded. A caveat for the orchestrator: I1, and I3 if it is relied on, are new invariantViolations clauses (additions; no existing clause changes).",
 "newBranches": "The IDTokens design has NB1-NB8, NB11 and NB12 (design2-move-index.md:233-290): about 10 items, 12 counting NB6's three arms, plus the I1 clause, the I3 clause if added, and one unreachable nil arm per scoped read. Four have no engine kill and can be killed only by unit tests, on the f066083 InterestCounts precedent (critic A11): NB5 insertAsset's no-interest arm, setInterest's replace arm, NB7 keepInterests' release, NB8 removeAllInterests' clear. Unit tests have no LaneDropVisit order, so S3-R16 1(e)'s 'both orders' needs a ruling for them. Further conditions: NB3's promote arm needs T3 with the waiter joining first (critic A6, R10); NB11's order test must assert Job.epoch, not source.starts (critic A3, R3). The Set-index variant reduces NB1-NB4 to one release-to-nil branch; the rest are the same.",
 "answerRisk": "low"
}
- {
 "change": "DEFER-D1: constant factor only; no new state. (a) Declare `indirect enum EventAfterFollow` (EngineFollow.swift:1405). Every payload becomes one box reference with the case tag in its spare bits, so the stride drops from 168 B (measured, log 'stride 168 B') to 8 B (INFERRED). The insert's memmove at :976 and the backward scan at :966-973 then touch 8 B per element instead of 168 B. (b) Remove the local copy `let events = self.state.eventsAfterFollow` (:965) and scan self.state.eventsAfterFollow in place. No copy is then alive when :976 mutates the array, a copy that would cost E retains with boxed elements. (c) Optional D1+: change lastIndex to firstIndex. It is equivalent only if (transfer, epoch) names one verdict event. The critic's reading confirmed that, but no existing clause checks it: the verdicts clause at EngineCommands.swift:2043 compares sets. Record it as an Equivalent mutant under S3-R19 item 2. The scan then costs O(position of V) instead of O(events after V).",
 "estimatedMs": "INFERRED; the stride and the per-element cost must be measured. Per element per join, about 1.5-3 ns instead of 7.3: the memmoves shift 8 B + 16 B, and the scan reads the tag without dereferencing the box. Correct shape at E \u2248 9.2-9.7k: 5.0 + 512 \u00d7 9.5k \u00d7 (1.5-3) ns \u2248 12-20 ms, central about 13-15 ms. reqs shape \u2248 1.7 + 7-15 \u2248 9-17 ms. Per-id grouping (intercept 7-9.5 ms, as userSharedApplyTurns and PARTIAL-MOVE users measure) \u2248 15-25 ms. With 10,000 extra tail events (E_after \u2248 20k), D1 gives about 20-36 ms: marginal. D1+ gives about 10-20 ms there, because only the 24 B per element of memmove scales with E_after. Box costs: one allocation per deferred event, about 25-40 ns, so about 20 \u00b5s per 512-join turn; the drain's frees are about 10 \u00b5s per turn. Drain turns stay about 3 ms or less.",
 "splitsWork": false,
 "whyAnswersUnchanged": "A representation change only. The queue's order, insert position, stamps, batch boundaries, replay, purge (EngineCommands.swift:1053-1071 rewrites `.join(join)` in place, so a new box), followedLane (EngineFailures.swift:822) and every exhaustive switch are unchanged. No new state, no new turn, no clause change in invariantViolations or followBarrierViolations (EngineCommands.swift:2003-2054 reads the same events). Removing the local copy does not change the computed index.",
 "newBranches": "0. (a) and (b) add no conditional. (c) changes one call; its lastIndex\u2194firstIndex mutant is Equivalent (S3-R19 item 2). Pins only: BenchSync deferBehindVerdictTurns {group, users} at 10,000, plus a tail-events variant, best of 3 at or under the bar. A MemoryLayout<EventAfterFollow>.stride check is optional.",
 "answerRisk": "low"
}
- {
 "change": "DEFER-A as written (integrate-c21.md part A): the joinsBehindVerdicts bucket keyed by VerdictKey(transfer, epoch), materialized at drain batch formation (A6). It also includes A7 (followedLane walks the buckets), A8 (purge walks them), A9 (K2 recount at the verdict's position; new clauses K1, K3, K4), A10 (cleared at shutdown) and A11 (removes the unspawnable branch).",
 "estimatedMs": "INFERRED. Follow turns drop to the in-place control: about 8.7 ms in the correct shape, 2-5 ms in the reqs shape, 7-10 ms in the per-id grouping (critic-defer-bucket A6). The drain turn that materializes about 10,000 joins: about 3-4 ms replay + 1-3 ms copy + an O(E) shift \u2248 5-9 ms.",
 "splitsWork": false,
 "whyAnswersUnchanged": "Its batches equal today's (A6, critic A1). But it does not meet this task's non-splitting definition. It adds a second store for waiting joins, which purges, 429s (followedLane) and shutdown landing between follow turns must each walk. It changes followBarrierViolations: the joins recount is extended (K2) and K1, K3 and K4 are added. Its bucket branches run only in sweepFollowsFirst (critic A7; g4_concerns), the same S3-R16 1(e) both-orders problem the splits hit. A11 is unrelated scope.",
 "newBranches": "About 10 or more: the verdictKey classifier's two arms; the materialization branch, the batch and overflow split and the bucket removeValue; A7's bucket walk and its reaches(); A8's bucket arm; A9's bucket walk; K1, K3, K4; A10's clear. All are reached in sweep-first only. The tests listed are T1, T1-place, T1-skip, T1-space/F-SPACE, T-PURGE, T-FL, T-FL', T-SD and F-K1/F-K3/F-K4.",
 "answerRisk": "medium"
}

## verdict

FEASIBLE_WITHOUT_SPLIT

## confidence

0.65

## whatWouldSettleIt

Five checks, each a release build on Apple silicon, best of 3, at a 1-minute load of 10 or less.
1. Build MOVE-M1 and then MOVE-B-reduced on a scratch branch off 8e1fb24. Run PROBE-C20C-MANY-MOVES (VerifyC20CorrectProbes.swift:305-441) with k = 1, 16, 64 and 256, at 10,000 ids, in two groupings:
   - the probe's one prefetch group;
   - a new variant with one user waiter per H member (10,000 awaitAsset calls on ids sharing H's content before v3).
   This decides whether M1 is enough or the index is needed. The per-id figures at 8e1fb24, and for M1, are INFERRED: nothing has measured that grouping.
2. Build DEFER-D1, with and without firstIndex. Measure:
   - MemoryLayout<EventAfterFollow>.stride, expected 8 against the 168 measured;
   - PROBE-C20C-DEFER-BEHIND and PROBE-C20R-DEFER-BEHIND-C2 at 10,000;
   - a per-id variant;
   - a variant with about 10,000 tail events queued after O's verdict (deferred user requests during the follow).
   Pass: the longest held turn is 32 ms or less, best of 3.
3. Check answer equality in both LaneDropVisit orders on the full suite, with invariantViolations() and followBarrierViolations() empty after every turn.
4. Ruling needed for B-reduced: S3-R16 1(e) must say whether unit-only kills of the index's engine-unreachable arms are acceptable on the f066083 precedent (NB5, NB7, NB8, setInterest's replace arm). It must also say whether new invariantViolations clauses (I1, and I3 if used) count as changing a clause.
5. Confirm by reading or a debug assertion that each (transfer, epoch) has exactly one verdict event, before D1+ uses firstIndex.
