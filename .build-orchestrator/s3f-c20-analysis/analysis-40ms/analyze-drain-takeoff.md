# analyze:drain-takeoff

Read-only analysis for ruling S3-R26 (workflow wf_72146a41-b2b, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## shape

The drain's take-off of moved-before ids: takeOffMovedBefore (EngineFollow.swift:551-568) followed by rerouteMovedBefore (EngineFollow.swift:572-576). Both are reached from replayVerdict (:607-620) and from the .spaceFailure replay (:346-356). The measured figure is BenchSync movedBeforeDrainTurns, 47.03 ms best of 3: one prefetch group token holding 10,000 ids on one job J, all of them taken off and re-routed back to J's own content C.

## measuredTurn

Benchmark: BenchSync.swift:677-690 (the test) and :3271-3395 (SyncBench.movedBeforeDrain).
- The timed window is :3379-3388: longestWait over releaseOneHeldTurn (:3457). The follow's follow-up turns are held and released one at a time.
- Log line (reqs/logs/gates/bench.log): longest actor wait [47.03, 47.12, 47.31] ms, longest held turn [47.03, 47.11, 47.31] ms, 4 held turns, movedBefore/held/rerouted = 10,000. The 47 ms is therefore the one held follow turn that ends the follow and runs the drain inline.

Path of that turn:
- continueFollow (EngineFollow.swift:114). It visits the last owed jobs: about 88 fillers and J (INFERRED from the setup comment at BenchSync.swift:3271-3279).
  - J's visit runs follow (:902-922): a filter of 10,000 ids at :907 that finds nothing moved, then rerouteOnPass = [].
- The follow ends and calls drainEventsAfterFollow(ids: budget.ids) at :158 (body at :188). It runs replay (:344), then .attemptFailed, then replayVerdict (:607). replayVerdict does five things:
  1. takeOffMovedBefore(job) (:551-568):
     - held = job.assets ∩ movedBefore (:552), O(N);
     - jobs[J].assets.subtract(held) (:557), O(N), on a set the live `job` copy shares;
     - interests sorted, one token here (:558);
     - interest.assets.sorted() (:559), O(N log N) AssetID compares through utf8.lexicographicallyPrecedes (AssetID.swift ~:75-77);
     - per id: held.contains, then jobs[J]?.removeAsset (2 dictionary modifies plus a Set remove; the first one copy-on-write copies the 10k set because `job` is alive), then off.append (:560-561);
     - then removeInterest (:564), dropInterest (EngineJobs.swift:346), retire (:370) and removeJob (:409). J is retired.
  2. endDeferral (:537).
  3. giveVerdict(.retry) (:623), then retryLater (EngineFailures.swift:244) on a job that no longer exists.
  4. followAfterVerdict (:586-593): follow finds no job and returns (false, 0) at :903-905.
  5. rerouteMovedBefore (:572-576): 10,000 × reroute (EngineDispatch.swift:1147-1191).
     - Per id in reroute: applied.entry(for:) (:1156); entry.transferID formatted for isBound (:1164); groups[token] != nil; groups[token]?.pending[asset] = entry.transferID, formatted again (:1179); addInterest (EngineJobs.swift:108).
     - Per id in addInterest: entry.transferID formatted a third time (:109); defersToFollow is false (drainingAfterFollow); noteJoin (:190) does a second applied.entry lookup; the first id creates the new job of C and enqueues it (:136-151).
     - Each later id takes the join path, with 9 jobs[transfer] lookups each hashing a 66-byte TransferID string: :132, which copies the whole Job; :156; :157-158 interests[token]; insertAsset; :163 isCircuitParked; relane :263, which copies the whole Job again; failFastJoiner :224, which reads jobs[transfer]?.state 3 times. notifyObservers returns early, since the benchmark registers no observers (INFERRED: the cost is linear, not quadratic).
- Then checkRunSettled, pump and endWorldHistory.

Format cost:
- TransferID.content is "c-" + ContentHash.hex (TransferID.swift ~:47; ContentHash.swift:74-95).
- One format makes about 5 heap allocations: the bytes array, the digits array, the scalars array, String(decoding:), and the concatenation.

## costModel

Per turn: one take-off of N = 10,000 held ids, plus N re-routes, plus a fixed part. N log N for the sort; everything else is O(N) with large constants.

Fixed part, about 2-5 ms (INFERRED):
- about 88 filler visits at about 10-12 µs each (the figure in the comment at EngineFollow.swift:6-10);
- J's visit filter of 10,000 ids, about 1.5-3 ms (analyse-state-cost Q2 estimate);
- pump.

Take-off, about 5-8 ms (INFERRED):
- intersection about 0.5 ms;
- subtract plus copy-on-write about 0.5 ms;
- sort of 10k AssetIDs with a generic per-byte compare, about 2-5 ms. The 3.6 ms figure for sorting 10k TransferIDs is from the comment at EngineFollow.swift:15-17, not re-measured;
- per-id removal loop about 1.5-3 ms.

Re-routes, about 33-38 ms, about 3.5 µs per id. This part dominates.
- Per id, 3 TransferID formats. The source comment at EngineFollow.swift:14-15 says "a formatted transfer and its job lookup about 0.75 µs in release", so a format alone is about 0.4-0.65 µs. That is about 1.2-2.0 µs per id, or 12-20 ms per turn: the largest single item (INFERRED; not profiled).
- About 9 TransferID-keyed jobs lookups (SipHash over 66 bytes plus a compare on hit), about 0.5-0.6 µs.
- About 2 whole Job copies, each retaining and releasing about 15 references, about 0.3-1.0 µs (INFERRED: depends on the optimizer).
- 2 manifest lookups with ManifestEntry copies, about 0.3 µs.
- boundContent, groups ×2 and pending, about 0.2 µs.

Cross-check from logs: concentrationCommitRerouteTurns' commit window is 9.82-10.23 ms with 0 re-routes and 47.99-51.40 ms with 10,000. That puts 10k sort+filter+re-routes at about 38-40 ms, about 3.8 µs per id. committed formats a 4th time per id at EngineDispatch.swift:1124. This agrees with the model.

Ownership: the dominant term is constant factors in reroute/addInterest, not the take-off's own loop. The take-off as such is only about 15% of the 47 ms (INFERRED).

## fixes

- {
 "change": "F1 (engine-only). In reroute, compute `let transfer = entry.transferID` once (EngineDispatch.swift:1147, before :1164) and use it at :1164, :1165, :1173, :1179 and :1184. Pass it to a new internal addInterest(_:asset:entry:transfer:lane:kind:) that holds today's body minus line :109. Keep today's addInterest signature as a one-line forwarder `addInterest(token, asset:, entry:, transfer: entry.transferID, lane:, kind:)` for the other callers. This takes the per-id formats from 3 to 1.",
 "estimatedMs": "About 34-39 ms. It removes 2 formats \u00d7 0.4-0.65 \u00b5s \u00d7 10,000, which is 8-13 ms off 47.03. Not enough alone.",
 "splitsWork": false,
 "whyAnswersUnchanged": "ManifestEntry.transferID is a pure function of the entry (ManifestEntry.swift:110-115: checksum gives .content, else .legacy). The same value is used at every site that formatted it before, in the same order. No state, order or call sequence changes.",
 "newBranches": "None. It hoists a value and adds a forwarding overload with no condition.",
 "answerRisk": "low"
}
- {
 "change": "F2b (model type, orchestrator-owned per P1). Make ManifestEntry.transferID a stored `public let`, computed once in each init (ManifestEntry.swift:68 memberwise, :124 init(from:)) with today's expression. It is not encoded: CodingKeys are explicit at :117. Manifest decoding runs on the bulk executor, off the actor (EngineManifest.swift:195-201), so the formats leave the actor turn. With F2b, F1 is unnecessary, since every read is a field load. Fallback if the model type may not change: F2'. Rewrite ContentHash.hex/TransferID.content (ContentHash.swift:74-95) to build one [UInt8] of capacity 66 including the 'c-' prefix from w0..w3, using a static digits table and a single String(decoding:). That gives about 2 allocations instead of about 5, branch-free, with no mutable pointers (C1).",
 "estimatedMs": "F2b gives about 27.5-35 ms alone: all 3 formats per id go, 12-19.5 ms. F1+F2' gives about 31-37 ms: 1 cheaper format remains, saving a further 1.5-4.5 ms after F1. INFERRED.",
 "splitsWork": false,
 "whyAnswersUnchanged": "TransferID values are byte-identical: the same 'c-'+lowercase hex, or the legacy SHA path. Synthesized Hashable/Equatable on ManifestEntry includes a field derived from the others, so equality is unchanged. The field is not in CodingKeys, so the on-disk/JSON format is unchanged.",
 "newBranches": "None new. The existing checksum/legacy branch moves from the computed getter into init, and the existing ManifestEntry/TransferID tests cover both kinds (INFERRED). F2' adds none.",
 "answerRisk": "low"
}
- {
 "change": "F3 (engine-only). In addInterest's join path (EngineJobs.swift:132-170), resolve the job once with `if let index = self.state.jobs.index(forKey: transfer)` in place of `if let job = self.state.jobs[transfer]`. Read lane/state and mutate (assets.insert at :156, interests[token] test, insertAsset/setInterest, isCircuitParked at :163) through `self.state.jobs.values[index]` (in place via _modify). No jobs insert or remove happens between them: noteJoin touches only unfollowed, systemHeld and run. In failFastJoiner (:224-), read `self.state.jobs[transfer]?.state` once for the two leading `if case` tests. The final switch keeps its own read, because readmitOpenedOriginGates may change the state.",
 "estimatedMs": "About 2-4 ms off: 4-5 of the 9 TransferID hashes per id and probably one whole Job copy (INFERRED; it depends on the optimizer).",
 "splitsWork": false,
 "whyAnswersUnchanged": "The same dictionary entry is read and mutated in the same order. Dictionary.Index stays valid because no structural mutation happens in between. relane, reinstate and failFastJoiner still see the same post-join job.",
 "newBranches": "None. if-let on an index replaces if-let on a value, and the existing branches are kept one-to-one.",
 "answerRisk": "low"
}
- {
 "change": "F4 (engine-only, the take-off itself). In takeOffMovedBefore (EngineFollow.swift:558-566), per token: `let mine = interest.assets.intersection(held)`, then one `self.state.jobs[job.transfer]?.subtractAssets(mine, for: token)` (EngineState.swift:801), then `for asset in mine.sorted() { off.append(...) }`. Keep the isEmpty \u2192 removeInterest check. This sorts only the held subset rather than the whole interest, and does one in-place subtract instead of N removeAsset calls (2 dictionary modifies and a Set remove each).",
 "estimatedMs": "About 1.5-3 ms off. Here mine equals the whole interest, so the sort cost stays (INFERRED).",
 "splitsWork": false,
 "whyAnswersUnchanged": "sorted(interest.assets \u2229 held) is the same sequence as sorted(interest.assets).filter(held.contains), so off and the re-route order are identical. The interest's final id set is identical, and nothing runs between today's per-id removals, so no intermediate state is observable. removeInterest runs under the same condition at the same point.",
 "newBranches": "None added. It removes the `where held.contains(asset)` filter at :559.",
 "answerRisk": "low"
}
- {
 "change": "F7 (optional, model type). AssetID `<` (AssetID.swift ~:75-77) compares through `withContiguousStorageIfAvailable` on both UTF-8 views, using UnsafeBufferPointer.lexicographicallyPrecedes (read-only pointers), and falls back to today's generic compare. This speeds the take-off sort, and every other AssetID sort in the engine.",
 "estimatedMs": "About 1.5-4 ms off the take-off's 2-5 ms sort (INFERRED).",
 "splitsWork": false,
 "whyAnswersUnchanged": "Unsigned byte-wise lexicographic order is identical between the buffer path and the UTF8View path, so every sort order is identical.",
 "newBranches": "1: the non-contiguous (bridged NSString) fallback. It is reachable with an NSString-bridged AssetID test. Its drop-mutant (always the fast path) cannot be killed by an answer test, because the fast path returns nil there and would need a crash or wrong order to be observed. Use only if F1-F4 fall short.",
 "answerRisk": "low"
}

## verdict

FEASIBLE_WITHOUT_SPLIT

## confidence

65

## whatWouldSettleIt

The cheapest check is one release-build Time Profiler sample of the existing case: run `xcrun xctrace record --template 'Time Profiler'` over `swift test -c release --filter movedBeforeDrainTurns`. Read the self-time share of ContentHash.hex / TransferID.content, of Dictionary<TransferID, Job> lookups (TransferID hashing), of Job retain/release, and of the AssetID sort within the 47 ms turn.

Thresholds:
- The fixes reach ≤ 32 ms in the pessimistic bound if formatting is ≥ about 25% of the turn (≥ 12 ms) and lookups plus Job copies are ≥ about 10%.
- If formatting is under about 15%, the verdict drops to UNCERTAIN.

Alternatives:
- Apply F1 alone (about 10 lines in EngineDispatch.swift/EngineJobs.swift) and re-run movedBeforeDrainTurns best of 3 at 1-minute load ≤ 10. A drop to ≤ 38 ms confirms the format attribution.
- A release micro-timer of 30,000 `entry.transferID` calls measures the per-format cost f directly.

Combined estimates: F1+F3+F4, engine-only, about 27.5-35.5 ms (marginal). F2b+F3+F4 about 21-31.5 ms. Adding F7 gives about 17.5-30 ms.

Not covered: the 10,000-user-waiter variant (movedBeforeDrainWaitersTurns) has no figure (INFERRED risk from per-token removeInterest/relane and the token sort). The .spaceFailure replay shares the same code, so the same fixes apply.
