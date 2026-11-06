# challenge:commit-reroutes

Read-only analysis for ruling S3-R26 (workflow wf_72146a41-b2b, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## verdict

WEAKENED

## correctedVerdict

FEASIBLE_WITHOUT_SPLIT

## correctedConfidence

60

## refutations

- Code path: correct in substance. EngineDispatch.swift:1083 -> committed :1100-1139 -> reroute :1147-1189 -> addInterest EngineJobs.swift:108-181. Read in code: 4 TransferID formats per moved id (EngineDispatch.swift:1121, :1164, :1179; EngineJobs.swift:109). With the barrier down (BenchSync.swift:3420-3422), defersToFollow (EngineFollow.swift:103-105) is false. The O job's assets are never reduced by committed: setInterest/setAssets touch only interests (EngineState.swift:774-809). So removeJob retires 10,001 ids (EngineJobs.swift:443-445), and publishTerminal sorts 10,001 at userInitiated lane (EngineJobs.swift:635; Job.lane = interestCounts.highest, EngineState.swift:761-763).
- Omission in the fixed part: `let captured = Set(ids)` (EngineDispatch.swift:1104) builds a 10,001-element Set every commit, although only the deferred arm reads it (:1125). About 0.5-0.8 ms, INFERRED.
- Undercounted lookups. failFastJoiner (EngineJobs.swift:224-253) reads `self.state.jobs[transfer]?.state` three times on the common path (:225, :233, :246), each a 66-byte-key hash plus an Optional<Job> getter. With :132, :156, :157, :161, :165 and relane's :264, that is about 9 jobs-table accesses per id, not 7-8.
- The attribution is credible but unprofiled. Log evidence (correct/logs/bench-rerun.log): wait == commit (51.40/50.42/49.34 ms), ending 7.25 ms, longest held follow turn 4.60 ms. So the figure is the commit window alone. The bound commit window is 10.16-10.23 ms. In movedBeforeDrain, the in-actor turn equals the heartbeat wait (47.02 vs 47.03), so a heartbeat wait here is about one turn. INFERRED: the window may also hold D's first attempt turn, answeredFromStore's prelude (EnginePresence.swift:208), which formats and sorts 10,000 ids. It is a separate turn of about 8-12 ms: under 32, but it sets a floor.
- Per-format cost is the crux and is unmeasured. The only anchor is EngineFollow.swift:14-16: about 0.75 µs for a format plus its job lookup, and 7.5-15 ms per 10,000 changed entries. Counting the hex code (ContentHash.swift: the `bytes` array, the [w0..w3] literal, the per-call `digits` Array, `scalars`, the String, then the "c-" + hex concat in TransferID.content) gives about 5-6 allocations, i.e. 0.3-0.65 µs per format (INFERRED). C1 alone saves 9-19.5 ms, so after C1 the turn is about 29-39 ms. C1+C2 is about 26-36 ms, which straddles 32. The analyst's 70 confidence that C1+C2 suffice is too high.
- C2 as written adds a genuinely new branch: `where job.assets.contains(asset)` over locations.keys. Its drop-mutant needs a store binding for an id that left O's job during the publication. That id would have to be moved off by a visit's rerouteOnPass (EngineFollow.swift:860-874, move :907-930) and then bound by the store. That is hard to construct and may be judged Equivalent in practice, which means friction under S3-R16 1(e). A same-predicate variant exists (see missedFix).
- C4 hazard. 'Read isCircuitParked from the job already copied at :132' must be read into a Bool inside the if-scope. If `job` is kept alive past :156-161, its live references to `assets`/`interests` force a full copy-on-write copy of D's 10,000-id set per join. That is the cycle-18 regression documented at EngineJobs.swift:129-131 (O(N^2), seconds at 10k).
- C1(a) equivalence holds, with one correction. Job is constructed only at EngineJobs.swift:139 (grep), with transfer = entry.transferID. The legacy NUL ambiguity is closed by manifest validation: ManifestRules.swift:102-104 rejects identifiers with control characters (identifierControlCharacter). So sameTransfer <=> equal TransferID up to a SHA-256 collision. No legacy-entry commit re-route test was found in a grep of Tests/ZTronAssetSyncTests (INFERRED absent). A lens may ask for one, because a checksum-only mutant of the substituted comparison could survive.
- C3 touches ZTronAssetModel (ContentHash.swift, TransferID.swift), which P1 makes orchestrator-owned contract code. It is non-splitting and byte-identical, but it needs orchestrator action, not a WP-F fixer edit.

## missedFix

1) A publishTerminal variant with no new branch class: for .committed, iterate `job.assets.filter { locations[$0] != nil }.sorted()`; for .failed, iterate `job.assets.sorted()` (switch hoisted). This is the same predicate as today's EngineJobs.swift:638, so the drop-mutant is today's (killed by any unbound-id test), with the same set and the same ascending order. Cost: one O(N) filter of about 0.3-0.5 ms, instead of a 10,001-id sort of about 3 ms. Prefer it over the analyst's C2.
2) Pass the manifest entry instead of re-looking it up, when listing == nil. committed's :1121 lookup feeds reroute's :1151 lookup, and noteJoin's EngineJobs.swift:191 lookup is trivially sameTransfer==true for an entry taken from self.state.applied. That is 2 of 3 lookups, each an AssetID hash, the triple-compare == (AssetID.swift ==), and a ManifestEntry copy. About 0.2-0.35 µs per id, 2-3.5 ms (INFERRED).
3) failFastJoiner: read `jobs[transfer]?.state` once and return early unless it is .blocked or .failed(.whenOnline). This saves 2 table accesses and Job getters per id, about 1-2 ms. Caveat: the early-return's drop-mutant is Equivalent, so prefer restructuring the three existing checks into one switch.
4) Move `decisionNow()` (EngineJobs.swift:125) into the job-creation arm. `now` is used only at :146, so this saves an existential clock call per join, which is small.
5) Orchestrator-owned: AssetID `<` (AssetID.swift:75-77, generic utf8.lexicographicallyPrecedes) via contiguous bytes, which is the same byte order. Also drop the redundant elementsEqual in AssetID ==. Both speed both 10k sorts and every hashed hit.
Recommended set: C1 + missedFix-1 first. If the cheap measurement shows a format under 0.5 µs, add 2 and C3.

## answerRisks

C1(a): equivalent under ManifestRules' control-character rejection, up to a SHA-256 collision. A lens may require a legacy (no-checksum) commit re-route test in both LaneDropVisit orders. C1(b)/(c): bit-identical values, no risk. C2 (analyst's form): output-identical, but the new `where` branch may be unkillable, which is S3-R16 1(e) friction. The same-predicate variant avoids this. C3: byte-identical strings, but it touches contract types (P1). C4: answer-safe only if isCircuitParked is captured as a Bool inside the :132 scope. Keeping the Job copy alive reintroduces an O(N) copy-on-write per join. Manifest-entry pass-through: safe only for listing == nil. With a listing (continueInbound), noteJoin must still compare against self.state.applied. None of these touches invariantViolations() or followBarrierViolations() clauses, the reroute order (unbound.sorted() is kept), resolveAll's token order, or event order.

## cycleEstimate

About 2 cycles (range 1-3).
- Cycle 1: C1 + publishTerminal same-predicate variant (no new branches, about 30-40 lines). The bench lands about 26-36 ms (INFERRED), so roughly a 55-65% chance of 32 ms or less, best of 3.
- If it misses: cycle 2 adds the manifest-entry pass-through, the failFastJoiner read-once and C3 (orchestrator edit), which reach about 22-28 ms.
- Verifier load: two lenses will re-run concentrationCommitRerouteTurns and concentrationPublicationTurns, and will probably ask for a legacy-entry re-route test pinning C1(a), which adds a test but no new deferred state.
- A third cycle is likely only if C2 is done the analyst's way (unkillable `where` mutant) or if C4 is implemented with a live Job copy.
Cheapest settling measurement: a release micro-timing of 40,000 `ManifestEntry.transferID` calls on a checksummed entry, separately from a jobs-table lookup. A format of 0.53 µs or more means C1 alone closes. Then one Time Profiler sample of concentrationCommitRerouteTurns, splitting ContentHash.hex/TransferID.content, Dictionary<TransferID,Job> access, Array sort and swift_beginAccess.
