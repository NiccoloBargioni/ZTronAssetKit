# analyze:supersede

Read-only analysis for ruling S3-R26 (workflow wf_72146a41-b2b, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## shape

supersede of a superseded publication (PROBE-C20C-SUPERSEDE-C2). O's job holds 10,001 ids: one prefetch-group token with 10,000 ids plus o's user waiter. While the publication is held at the store, v4 maps all 10,000 members to D and o to E. The store refuses the publication with .superseded, and publicationFailed calls supersede, which re-routes all 10,001 interests in one actor turn. Measured at commit 8e1fb24, release build: windows [41.83, 41.27, 41.09] ms, best 41.09 ms, at 1-minute load {4.44 22.48 187.12} -> {4.24 22.14 186.03}. Source: /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/correct/logs/rel-superq.log:10. The 1,000-member warm-up in the same log took 4.47 ms, so the cost scales linearly: about 4.1 us per id, with no O(N^2) term at work. Setup checks passed: O gone, D holds 10,000, E holds 1. The probe's other log, rel-super1.log, was run at a 1-minute load of 546 and hit the time limit; it is not usable. The probe covers only the group grouping. The same site with one user waiter per id has never been measured.

## measuredTurn

The turn is the engine's handling of the store's .superseded verdict. It starts at publicationFailed, /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1191 (paths below are relative to that Engine/ folder). Steps in order:
- recordBreaker (:1200), recordPublicationEnd (:1202), transition(.queued) (:1209).
- supersede(transfer) (:1210 -> :1256-1280), then reconcileIdle (:1245).

Inside supersede:
- (1) A Job copy (:1260), removeAllInterests (:1262, EngineState.swift:811-814) and removeJob (:1263). removeJob (EngineJobs.swift:409-447) runs retireProgress once per asset, 10,001 times (:443-445). Each call (EngineEvents.swift:68-80) does two EventSlot-keyed dictionary removals, plus heap.remove: DeadlineHeap.swift:74-76 is an O(H) removeAll over the heap entries (H is small here, INFERRED), plus a check that subscribers are empty.
- (2) The holdForManifest pre-scan (:1264): it short-circuits on the first match, but in this shape nothing matches, so it does 10,001 copy.entry(for:) lookups plus sameTransfer (EngineJobs.swift:210-219). That is about 0.1 us per id, per the comment at EngineFollow.swift:14-16, so about 1 ms.
- (3) job.interests.keys.sorted() (2 tokens) and interest.assets.sorted() (:1270): a sort of 10,000 AssetIDs (String-backed, AssetID.swift:13-17), O(N log N), INFERRED at 1.5-3.5 ms (EngineFollow.swift:16 measured 3.6 ms for 10,000 longer TransferIDs).
- (4) For each id, reroute (:1147-1189). Group path:
  - an interest.kind check (:1148);
  - applied.entry(for:) (:1151), a lookup plus a ManifestEntry copy;
  - isBound(asset, to: entry.transferID) (:1164), FORMAT #1;
  - groups[token] != nil (:1176), a getter copy of the group;
  - groups[token]?.pending[asset] = entry.transferID (:1179), FORMAT #2;
  - addInterest (:1188).
- In addInterest (EngineJobs.swift:108-182):
  - let transfer = entry.transferID (:109), FORMAT #3;
  - defersToFollow (:110, EngineFollow.swift:103-105) is false here, because the window opens after appliedAndFollowed(v4s);
  - decisionNow() (:125), an existential clock read under a Mutex in the probe (ManualTimeSource.swift:72-74); its value is used only when a job is created (:146);
  - noteJoin (:126, :188-205), another entry lookup;
  - then lookups of jobs[transfer], keyed by a 66-byte String TransferID (TransferID.swift:21, :45-47): if-let copy (:131), assets.insert (:155), interests[token] != nil getter copy (:156), insertAsset (:160), isCircuitParked getter copy (:164);
  - relane (:179 -> :263-266): a guard-let Job copy; in the .queued arm the lane stays prefetch and the interest is not a user one, so it is a no-op (:269-273);
  - failFastJoiner (:180 -> :224-251): three more getter reads of jobs[transfer]?.state (:225, :232, :244), each a full Job copy, and no arm fires for .queued;
  - notifyObservers (:181, EngineCommands.swift:1665-1683): two isEmpty checks (observers are empty, INFERRED).
- The first group id creates D (queued) at :137-152, and the other 9,999 take the join path. o's waiter creates E.
- (5) checkRunSettled and pump once each (:1276-1277).

Each format of entry.transferID (ManifestEntry.swift:110-115 -> TransferID.content -> ContentHash.hex, ContentHash.swift:74-95) makes about 6 heap allocations: a digits array, the bytes array, a word-array literal, the scalars array, a 64-char String, and the "c-" concatenation. So 3 formats per id plus 9 TransferID-keyed jobs lookups (7 of them copy the whole Job) form the per-id hot path.

## costModel

Per turn: O(N log N) for one sort, plus O(N) id work at about 4.1 us per id, measured as 41.09 ms / 10,001 ids. The 1,000-id run took 4.47 ms (rel-superq.log), which shows the cost is linear, with no CoW copy of a large set per id in this shape.

Breakdown, all INFERRED, with each estimate checked against figures the code itself records:
- (a) 3 TransferID formats per id at about 0.3 us each: about 0.9 us per id, so 9 ms. Sources: EngineState.swift:966-967 says formatting 10,000 transfers takes about 3 ms; EngineFollow.swift:14-16 says one format plus its job lookup takes about 0.75 us.
- (b) About 9 lookups of jobs[transfer] keyed by a 66-byte TransferID per id. Each hashes the 66-byte string; the freshly formatted string has different storage from the dictionary key, so equality runs a full memcmp. 7 of the lookups copy and destroy a Job through Dictionary's getter, about 10 refcounted fields. Together with the runtime exclusivity checks this is about 0.1-0.15 us per lookup, so about 1.0-1.3 us per id, or 10-13 ms.
- (c) 2-3 manifest entry lookups with ManifestEntry copies, the group lookup and assignment, AssetID inserts into D.assets and into the interest set (amortized rehash, no reserveCapacity), and a clock read: about 0.6-0.9 us per id, or 6-9 ms.
- (d) removeJob's 10,001 retireProgress calls: about 0.1-0.2 us each, so 1-2 ms.
- (e) The holdForManifest scan: about 1 ms.
- (f) The sort of 10,000 AssetIDs: about 1.5-3.5 ms.
- (g) The heartbeat's scheduling and pulse overhead: under 0.5 ms.

The figure is dominated by the per-id reroute -> addInterest chain, which is (a)+(b)+(c), about 75-85% of 41 ms. Within that chain, the redundant formats and the redundant Job lookups and copies are about half.

Other groupings (bar applies to every grouping):
- One user waiter per id: unmeasured. Each id also does a waiters get and set (EngineDispatch.swift:1170-1174), a new interest (EngineState.swift:774-788), and relane -> enqueue on every join, because relane re-enqueues on every user join (EngineJobs.swift:270-273, 474-489). enqueue adds 3 more jobs lookups, a Job copy and write-back, a LaneQueues push, and amortized compaction. Estimate, INFERRED: 45-60 ms now. For comparison, C19's user-waiter follow turns cost 6.5-11 us per moved id, including the cost of leaving H (logs/rel-userq.log).
- A run's interest on the superseded job: releaseRunClaim (EngineRuns.swift:505-512) copies RunState, then `var claimed = run.outstanding[transfer]` and `claimed.remove` copy-on-write the claimed set, and the write-back copies the outstanding dictionary. That is O(|claimed|) per id, so O(N^2). INFERRED; this shape does not reach it.

## fixes

- {
 "change": "F1: format the destination transfer once per re-route and pass it down. In reroute (EngineDispatch.swift:1147-1189), compute `let target = entry.transferID` once, after the not-listed guard at :1151. Use it at :1164, :1165, :1173, :1179 and :1184. Pass it to addInterest through a `transfer:` parameter that replaces EngineJobs.swift:109; the other callers compute it as they do today. This takes 3 formats per id down to 1. Optional extension F1b, which belongs to the orchestrator because ZTronAssetModel is a contract type (P1): have ValidatedManifest keep each entry's TransferID beside its position, built at validation off the actor. reroute and noteJoin would then format nothing, and every sharing of the key's String storage would make TransferID equality pointer-fast.",
 "estimatedMs": "About 35 ms (range 33-37) for F1 alone: 41.09 - 2 formats x 10,001 x about 0.3 us (EngineState.swift:966-967), which is about 6 ms. F1b would remove the last format, about 3 ms more, and make the 9 jobs-key comparisons pointer-equal: about 31-33 ms. INFERRED from the code's own recorded per-format figures, not measured on this shape.",
 "splitsWork": false,
 "whyAnswersUnchanged": "TransferID is a pure function of the entry (ManifestEntry.swift:110-115: .content(checksum) or .legacy(identifier, remotePath)). The same entry gives an equal value whether it is formatted once or three times. No branch condition, order, place or answer reads anything but that value. invariantViolations and followBarrierViolations see equal keys.",
 "newBranches": "None. Only parameters are threaded through; no conditional is added, so there is no new drop-mutant to kill.",
 "answerRisk": "low"
}
- {
 "change": "F2: collapse the join-existing path's jobs table accesses from about 9 to 2, with no Job copies.\n- Add `mutating func join(asset:token:lane:kind:) -> (before: AssetPriority, after: AssetPriority, state: JobState)` on Job (EngineState.swift, next to insertAsset at :790). It does the assets.insert, the insertAsset-or-setInterest choice (the existing if/else at EngineJobs.swift:156-162, moved), and reads lane before and after. Call it through a single `self.state.jobs[transfer]?.join(...)` modify access, in place of :131-133 and :155-162.\n- Keep wasReleasedOnly's value. Evaluate `!self.state.releasing.isEmpty` first (the short circuit isReleasedOnly already has at EngineDispatch.swift:288-291), and read the job before the join only when releasing is non-empty.\n- Read isCircuitParked from the returned state (:164). noteCircuitParked does not change state or lane.\n- Give relane a variant that takes (before, after, state) instead of `guard let job` (EngineJobs.swift:263-266). Its .failed and .blocked arms keep reading attemptEnd, epoch and job from the table inside the arm.\n- In failFastJoiner (:224-251), read `self.state.jobs[transfer]?.state` once into a local instead of three times. Re-read it only inside the existing readmitOpenedOriginGates branch (:235-241), which can change it.\n- Move `let now = self.decisionNow()` (:125) into the creation branch, its only use (:146).\n- Merge reroute's group guard and assignment (EngineDispatch.swift:1176-1179) into `guard (self.state.groups[token]?.pending[asset] = target) != nil else { return }`.\n- Same-pattern extension for the user-waiter grouping: give enqueue (EngineJobs.swift:474-489) one modify access instead of a get, a whole-Job write-back and a queuePlace modify.",
 "estimatedMs": "About 27 ms (range 24-31) after F1+F2 on the measured group shape: 35 - about 7 jobs lookups and Job copies x 10,001 x 0.1-0.15 us (7-10 ms) - about 1 ms for the clock read and the group copy. The one-user-waiter-per-id grouping at this site (unmeasured, estimated at 45-60 ms today) is estimated at about 30-42 ms after F1+F2 plus the enqueue extension. That could still exceed 32 ms. All INFERRED.",
 "splitsWork": false,
 "whyAnswersUnchanged": "The same reads and writes happen in the same order. Only redundant re-reads of a value that nothing changed in between are dropped:\n- Between the join and relane, only noteCircuitParked runs (EngineReadmission.swift:348), and it touches circuitOrder, not the job's state or lane.\n- Inside failFastJoiner, state changes only in readmitOpenedOriginGates, where the read is repeated.\n- The value of decisionNow is unused on the join path; the live and manual clocks have no side effects.\n- The optional-chained assignment returns nil exactly when groups[token] is nil, the same as the old guard.\nNo enqueue, ticket, place, lane, answer or failFast call changes, so the visit-first equivalence (S3-R16 1(a)) and invariantViolations() and followBarrierViolations() see identical state.",
 "newBranches": "None if written as described: the existing if/else and switch arms move into Job.join, relane and failFastJoiner. relane's `guard let job` else-path disappears for this caller, because the job is known to exist. Do not add a 'nothing to do' fast path that skips relane or failFastJoiner: its drop-mutant would be behaviour-equivalent and could not be killed 2/2 (S3-R16 1(e)).",
 "answerRisk": "medium"
}
- {
 "change": "F3, a guard for the run grouping, not reached in the measured shape. Rewrite releaseRunClaim (EngineRuns.swift:505-512) to mutate in place: `guard self.state.run?.token == token, self.state.run?.outstanding[transfer] != nil else { return }`, then `self.state.run?.outstanding[transfer]?.remove(asset)`, and drop the key when the set is empty. This replaces copying the RunState and the claimed set and writing both back, which copy-on-writes the claimed set and the outstanding dictionary for every id: O(N) per id, so O(N^2) per supersede.",
 "estimatedMs": "0 ms change on the measured shape, which has no .run interest. That interest-kind check (EngineDispatch.swift:1148) is false for both tokens (INFERRED from the onDemand policy and the linear 1k->10k scaling). For a run interest of N ids on a superseded job it removes an O(N^2) term: INFERRED to be hundreds of ms at 10,000, never measured.",
 "splitsWork": false,
 "whyAnswersUnchanged": "After the call, run.outstanding[transfer] holds the same set: asset removed, and the key removed when the set is empty. The existing ternary's empty-to-nil logic is kept. Nothing reads the intermediate copies.",
 "newBranches": "None net. The existing guard conditions and the isEmpty ternary keep their shape; they are re-expressed as in-place accesses.",
 "answerRisk": "low"
}

## verdict

UNCERTAIN

## confidence

55

## whatWouldSettleIt

Two measurements, each about 5 s of release runtime at a 1-minute load of 10 or less, with no code split:
- (1) Apply F1, which adds no branches and is about 15 lines, and rerun the existing /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/correct/VerifyC20SupersedeBench.swift. A best of 3 at or under 35 ms confirms the per-format model.
- (2) Add a one-user-waiter-per-id variant of the same probe (10,000 waiters instead of the group) and record its baseline on 8e1fb24.

If the group shape is at or under 35 ms after F1 and the user variant's baseline is at or under 45 ms, F1+F2 very likely bring both to 32 ms or less, and the verdict becomes FEASIBLE_WITHOUT_SPLIT. If the user variant's baseline is over 55 ms, this site needs either F1b (the TransferID precomputed in ValidatedManifest, owned by the orchestrator) or a split.

An alternative that needs no code change is an xctrace Time Profiler run of the current probe at 10,000. If ContentHash.hex/TransferID.content plus Dictionary<TransferID, Job> lookups and Job copies are 25% or more of the turn (10.3 ms or more), F1+F2 reach 32 ms on the group shape.

Group-shape-only confidence that F1+F2 reach 32 ms or less: about 70. Confidence for every grouping at this site: about 45.

Side note, INFERRED: the RR-21 commit re-route row (47.99 ms, BenchSync.swift:722) runs the same reroute -> addInterest chain. F1+F2 would cut it by a similar 25-35%, to about 31-36 ms, which may not be enough on its own.
