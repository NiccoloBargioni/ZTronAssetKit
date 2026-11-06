# analyze:commit-reroutes

Read-only analysis for ruling S3-R26 (workflow wf_72146a41-b2b, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## shape

RR-21 commit re-route: one publication (O) whose 10,000 converged prefetch-group ids an apply (v4) moved to another content D while O's store publication was held. The store binds only O's own id, and committed() re-routes the other 10,000 interests in the same turn, with the barrier down. Bench: BenchSync.concentrationCommitRerouteTurns (Tests/ZTronAssetKitBenchmarks/BenchSync.swift:657-664) -> concentrationTurns(.publication, commit: .movedAway) (:695-729) -> SyncBench.concentration (:3072ff) -> timeCommit (:3217ff). timeCommit first waits for appliedAndFollowed(v4) (:3420-3422: !followBarrier && !drainFollowUpScheduled), so in the timed turn addInterest takes the immediate join path, not the deferred one (EngineJobs.swift:110-116 not taken). The heartbeat window ends when jobExists(O) is false (:3425-3427). Measured best of 3: 47.99 ms (reqs, load mean 3.04) and 49.34 ms (correct, load 3.14). Target is 32 ms or less.

## measuredTurn

The single engine turn that resumes publish() after store.publish returns (EngineDispatch.swift:1061-1091) runs:
1. transition to .committing (:1083).
2. committed(transfer, binding: [O], ...) (:1100-1139):
   - bind 1 id (:1106).
   - `for (token, interest) in job.interests.sorted` (:1109), with 2 tokens.
   - For the group token:
     - `interest.assets.filter { locations[$0] == nil }` builds a Set of 10,000 (:1110).
     - `subtracting` (:1114).
     - setInterest(nil) (:1116).
     - `unbound.sorted()` sorts 10,000 AssetIDs with byte-wise `<` (:1120; AssetID.swift `<` = utf8.lexicographicallyPrecedes).
     - Per id: `applied.entry(for:)?.transferID == transfer` (:1121), which is TransferID FORMAT #1. Then reroute(...) (:1122).
3. reroute (:1147-1189), per id:
   - applied.entry(for:) (:1151).
   - isBound(asset, to: entry.transferID) (:1164): FORMAT #2, plus a boundContent lookup.
   - The prefetch arm: groups[token] != nil, then `groups[token]?.pending[asset] = entry.transferID` (:1175-1179): FORMAT #3.
   - addInterest (:1188).
4. addInterest (EngineJobs.swift:108-181), per id:
   - `let transfer = entry.transferID` (:109): FORMAT #4.
   - defersToFollow is false; decisionNow() (:125) makes an existential time call.
   - noteJoin (:126) does a third manifest lookup.
   - `if let job = self.state.jobs[transfer]` (:132) copies the whole Job. The first id creates D's job (:138-154, enqueue); later ids find it queued, and isReleasedOnly short-circuits on releasing.isEmpty (EngineDispatch.swift:288-291).
   - `jobs[transfer]?.assets.insert` (:156).
   - `jobs[transfer]?.interests[token] != nil` (:157), then insertAsset (:161).
   - `jobs[transfer]?.state.isCircuitParked` (:165).
   - relane (:177) does another full Job copy; it is a no-op for a queued prefetch job with an unchanged lane (EngineJobs.swift:263-273).
   - failFastJoiner (:179) reads jobs again.
   - notifyObservers (:180), which is cheap with no observers.
   - Net: about 7-8 lookups into the jobs table, keyed by a 66-byte TransferID string, and 4 TransferID formats.
5. Each FORMAT is ContentHash.hex (ContentHash.swift:86-95): it allocates `bytes` (:74-82) and `digits`, appends 64 bytes into an array, then builds a String. TransferID.content then concatenates "c-" + hex (TransferID.swift). That is about 4-5 heap allocations per call. The bench entries carry checksums (BenchSync.swift:1220-1228), so the content form applies, not the legacy SHA form.
6. After the loop:
   - resolveAll (EngineJobs.swift:611-628) answers O's waiter.
   - removeJob (:409-448) calls retireProgress for all 10,001 job.assets (:443-445). Each call makes 2 hashed removals, an O(H) DeadlineHeap.remove (DeadlineHeap.swift:74-75) and a `subscribers.keys.sorted()` (EngineEvents.swift:68-79).
   - publishTerminal (:631-645): the job's lane is userInitiated because of O's waiter, so `job.assets.sorted()` sorts 10,001 ids (:635), then does 10,001 locations lookups, for a single broadcast.
   - pump (:1137) and reconcileIdle/pruneBoundContent (:1138; EnginePresence.swift:74-90).

## costModel

Per turn, with N = 10,000 unbound ids, one group token and one waiter: O(N log N) sorts (two, of 10k and 10,001 ids) + O(N) set building + N x (re-route + join) + O(N) retire. No O(N x k) factor and no copy-on-write copy of a large collection per id. The in-place join was already fixed in cycle 18, per the comment at EngineJobs.swift:129-131. Measured anchors:
- 47.99-49.34 ms for this turn.
- The engine's own doc: "a formatted transfer and its job lookup about 0.75 µs in release" (EngineFollow.swift:14-16).
- "a moved id costs a re-route and a join, about 5 µs in release" (EngineMoves.swift:120-121).
- The bound commit window (all 10,001 bound): 9.82-10.21 ms (s3f-c20-issues.json).

Decomposition (INFERRED, using design2-commit-window.md unit costs: AssetID sort of 10,001 = 3.3 ms; retire 1.3 ms; set filter 0.6 ms):
- Fixed non-loop part, about 9-11 ms:
  - filter + subtracting: about 1-1.2 ms
  - unbound.sorted(): about 3.3 ms
  - removeJob retire: about 1.3 ms
  - publishTerminal's 10,001-id sort + lookups: about 3.9 ms
  - prune/pump/rest: about 0.5-1 ms
- The re-route loop takes about 37-40 ms, so about 3.8-4.0 µs per id. Inside it:
  - 4 TransferID formats at about 0.45-0.65 µs each (INFERRED: the 0.75 µs documented figure minus about 0.1-0.15 µs for a lookup): about 1.8-2.6 µs per id, i.e. 18-26 ms of the turn.
  - About 7-8 hashed jobs-table accesses on the 66-byte key plus 2-3 whole-Job copies (relane, `if let job`, optional-chained getters): about 0.7-1.0 µs per id.
  - 3 manifest lookups with ManifestEntry copies, plus the group pending, assets and interest inserts: about 0.5-0.7 µs per id.

Dominant term (INFERRED, not profiled): the redundant TransferID formatting, 4 per id where 1 suffices, about 40-50% of the turn. Second: the two O(N log N) sorts plus O(N) retire, about 8-9 ms. The commit window measured about 10 ms on the bound shape. Its sort, retire and publishTerminal parts are also in this turn, but its per-id bind and deliver parts are not.

## fixes

- {
 "change": "C1 (WP-F files only): format the TransferID once per re-routed id instead of 4 times. (a) committed (EngineDispatch.swift:1121): replace `self.state.applied.entry(for: asset)?.transferID == transfer` with `guard let listed = self.state.applied.entry(for: asset), SyncEngine.sameTransfer(listed, job.entry) else { reroute }`. This is the same compound condition; sameTransfer (EngineJobs.swift:210-219) compares checksums with no formatting, and noteJoin already uses it. (b) reroute (:1147-1188): `let target = entry.transferID` once, used at :1164, :1165, :1173, :1179, :1184 and passed to addInterest. (c) addInterest: add a core `addInterest(token, asset:, entry:, transfer:, lane:, kind:)`. The existing signature becomes a one-line wrapper that passes `entry.transferID`, so other callers do not change. Net: 4 formats per id become 1.",
 "estimatedMs": "About 29-36 ms. 3 formats removed x 0.45-0.65 \u00b5s x 10,000 = 13.5-19.5 ms off 48-49.3 ms. This alone is INSUFFICIENT with margin: it reaches 32 ms only if a format costs 0.55 \u00b5s or more.",
 "splitsWork": false,
 "whyAnswersUnchanged": "(b) and (c) reuse the identical value `entry.transferID` instead of recomputing a pure function, so every key, comparison and stored value is bit-identical. (a): Job is created only at EngineJobs.swift:139, with `transfer = entry.transferID` (:109) and `let entry` (EngineState.swift:676-678), so job.entry.transferID == transfer. Both checksummed: equal hex <=> equal checksum. Mixed: the 'c-' and 'l-' prefixes differ and sameTransfer is false. Neither checksummed: sameTransfer compares identifier and remotePath, versus SHA-256(identifier || 0x00 || remotePath). These differ only for a structural NUL ambiguity (an identifier containing 0x00) or a SHA-256 collision (INFERRED: not checked whether manifest validation rejects NUL in ids). If the orchestrator wants zero argument, keep (a) as is: 4 formats become 2, which saves about 1.0-1.3 \u00b5s per id instead. No SPEC MUST and no invariantViolations or followBarrierViolations clause reads how a TransferID was computed.",
 "newBranches": "None. (a) keeps the same two outcomes, the guard's else-arm and fall-through, with the same truth table; only the comparison operator changes. (b) and (c) add no conditional. The wrapper is straight-line. The existing tests of the T22 re-route versus deferred/refused arms (commit with an id moved away, and with one still listed here) already cover both outcomes; no new drop-mutant target.",
 "answerRisk": "low"
}
- {
 "change": "C2 (WP-F): publishTerminal (EngineJobs.swift:631-645). For `.committed(let locations)`, iterate `locations.keys.sorted()` where `job.assets.contains(asset)`, instead of `job.assets.sorted()` with a `locations[asset] != nil` test. Keep `job.assets.sorted()` for `.failed`. The switch moves outside the loop. This keeps today's ascending AssetID order exactly, which avoids design2-commit-window step 3's cross-subject order change.",
 "estimatedMs": "About 3.3-3.9 ms less on this shape: a sort of 1 key instead of 10,001, and 1 lookup instead of 10,001 (sort cost from design2-commit-window.md:168). With C1: about 25-32 ms. On the all-bound commit window it costs about +0.5 ms (10,001 contains, design2-commit-window.md:310), which is irrelevant under a 40 ms ceiling.",
 "splitsWork": false,
 "whyAnswersUnchanged": "Same event set: {a in job.assets : locations[a] != nil} = {a in locations.keys : job.assets.contains(a)}. Same order: ascending AssetID in both. Same generation, read once per event as before. `.failed` is untouched.",
 "newBranches": "The outcome switch moves from inside the loop to outside; its two arms already exist. The `where job.assets.contains(asset)` filter replaces the per-id `locations[asset] != nil` test. Its drop-mutant would broadcast assetAvailable for an id the store bound but that left job.assets during the publication. That needs one test, in both LaneDropVisit orders, unless an existing one covers it (INFERRED: not checked): an id withdrawn from O's job while O publishes, the store still returns it in locations, and the expected result is no assetAvailable for it. Killed 2/2 deterministically.",
 "answerRisk": "low"
}
- {
 "change": "C3 (ZTronAssetModel, orchestrator-owned under P1, so report rather than edit): make ContentHash.hex and TransferID.content cheap with no unsafe code. Use a static 16-byte digit table instead of `Array(\"0123456789abcdef\".utf8)` per call. Write the nibbles directly from w0-w3 instead of materialising `bytes` (ContentHash.swift:74-82). For TransferID.content, build one [UInt8] of capacity 66 that already holds \"c-\", then call String(decoding:as:) once, removing the `\"c-\" + hex` concatenation. That is 2 allocations instead of about 5. Do not use String(unsafeUninitializedCapacity:), which is mutable-pointer use banned by C1.",
 "estimatedMs": "With C1+C2: the remaining 1 format per id drops from about 0.45-0.65 to about 0.12-0.2 \u00b5s, about 3-4.5 ms less, giving about 21-28 ms. On its own, without C1: about 1.2-1.8 \u00b5s per id less, about 12-18 ms. It also speeds every other shape that formats transfers: follow scans, supersede, drain re-routes.",
 "splitsWork": false,
 "whyAnswersUnchanged": "Pure functions with byte-identical output: the same lowercase hex, prefix and length. Existing ContentHash and TransferID round-trip and fixture tests pin the strings (INFERRED that they exist; the blob file names depend on `hex`).",
 "newBranches": "None: straight-line loops over 4 words x 8 bytes.",
 "answerRisk": "low"
}
- {
 "change": "C4 (WP-F, optional margin): in addInterest's existing-job path (EngineJobs.swift:132-180), fold `assets.insert` (:156), the `interests[token] != nil` test (:157) and insertAsset/setInterest (:158-163) into one `mutating func join(_ asset:, token:, lane:, kind:)` on Job, called through a single `self.state.jobs[transfer]?.join(...)`. Read the isCircuitParked test (:165) from the `job` already copied at :132; join never changes `state`, so the value is the same.",
 "estimatedMs": "About 2-3 hashed 66-byte-key accesses and 1-2 optional-chained Job reads less per id, about 0.15-0.3 \u00b5s, so about 1.5-3 ms. With C1+C2+C3: about 19-26 ms.",
 "splitsWork": false,
 "whyAnswersUnchanged": "The same mutations run in the same order on the same Job value in place. The if/else on an existing interest moves unchanged into Job.join. isCircuitParked is read before relane, and relane is the first call that can change state (it runs after :165 today too).",
 "newBranches": "No new branch. The existing interest-present/absent if/else is relocated into Job.join and still needs its current tests: a second id of the same token joining, and a different token joining. The orchestrator should confirm whether a relocated branch must be re-pinned under S3-R16 1(e).",
 "answerRisk": "low"
}

## verdict

FEASIBLE_WITHOUT_SPLIT

## confidence

70

## whatWouldSettleIt

The cheapest check needs no engine change. In a release build, time 40,000 calls to `ManifestEntry.transferID` on a checksummed entry, together with the existing jobs-table lookup. One run takes seconds.
- If one format costs 0.45 µs or more, C1+C2 reach 32 ms or less by arithmetic: 48 - 13.5 - 3.3 = about 31 ms or less.
- If it costs under 0.4 µs, C3 (and C4) are needed.

Confirm afterwards: apply C1+C2 (about 30 lines in EngineDispatch.swift and EngineJobs.swift) in a scratch worktree, run only concentrationCommitRerouteTurns, and check the best of 3 is 32 ms or less at a 1-minute load of 10 or less. Re-run concentrationPublicationTurns to see the +0.5 ms effect of C2 on the bound commit window.

Alternative: one Time Profiler sample of the current bench, attributing samples under ContentHash.hex / TransferID.content versus Dictionary<TransferID, Job> access versus Array sort.

What is unverified here: the per-format cost (INFERRED from the 0.75 µs-with-lookup figure at EngineFollow.swift:14-16), the split of the fixed part (INFERRED from design2-commit-window unit costs), and whether any test already kills C2's `where` drop-mutant. Nothing was built or run in this analysis.
