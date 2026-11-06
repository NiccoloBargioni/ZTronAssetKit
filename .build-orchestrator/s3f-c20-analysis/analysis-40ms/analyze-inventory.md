# analyze:inventory

Read-only analysis for ruling S3-R26 (workflow wf_72146a41-b2b, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## inventorySource

/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/docs/adr-drafts/s3f.md:4833 (heading "### The C2 inventory (S3-R25 item 3)"; table header :4840, rows :4842-:4858, 15 rows; no later inventory exists, the only other hit is the "Not verified" note at :7690). Benchmarks: /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Tests/ZTronAssetKitBenchmarks/BenchSync.swift (c2Budget = 10.0 at :129). Code: worktree at 8e1fb24 (git log -1), /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/. Figure sources: draft "Gate evidence (cycle 19)" ~:7305-7360 and "(cycle 20)" :7481-7548; /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-issues.json; /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/correct/logs/{bench.log,bench-rerun.log,rel-userq.log,rel-drainq.log} and reqs/logs/{gates/bench.log,probe1-3.log}.

## rows

- {
 "operation": "INV :4842 follow's passes over the copy (continueFollowScans)",
 "where": "EngineFollow.swift:749-786; bounds followScansPerTurn=16_384 (:18), followFormatsPerTurn=2_048 (:20)",
 "cost": "bounded per turn: <=16,384 entries and <=2,048 formats; independent of grouping",
 "figure": "concentrationNotFoundTurns c19 6.20, c20 6.24 best (draft :7531); reqs gate 6.66 (reqs/logs/gates/bench.log:246); correct 6.56 (correct/logs/bench.log:247)",
 "over32ms": "no",
 "worstGrouping": "any (per-turn bound)",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "INV :4843 a visit's filter of the moved ids (rerouteOnVisit + follow's filter)",
 "where": "EngineFollow.swift:860-878, :906-914",
 "cost": "O(N) once per visit, one copy lookup per id; summed over visits <= total ids (10,000) a turn",
 "figure": "inside sharedApplyTurns / divergenceTurns (below), all <=8.6 ms",
 "over32ms": "no",
 "worstGrouping": "one holder of 10,000 ids",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "INV :4844 startMove building items",
 "where": "EngineMoves.swift:140-166 (loop :158-162 scans every interest's ids of the job)",
 "cost": "O(N of the job), not O(moved ids) as the row says: it walks all interests' assets and tests moved.contains. Once per visit fine; once per owed move off the same holder it is O(N x k)",
 "figure": "inside sharedApplyTurns/inboundHolderTurns <=7.4 ms; many-moves shape 79.55 ms (k=16) and 304.79 ms (k=64) best (c20-issues correct[0]) is the move shape",
 "over32ms": "yes",
 "worstGrouping": "many owed moves off one 10,000-id holder (part of the excluded move shape)",
 "nonSplittingFix": "EXCLUDED (move shape, other agent). Note for that agent: per-job asset->tokens index kept by Job mutators lets startMove build items in O(moved) (c20-issues correct[0] fix)."
}
- {
 "operation": "INV :4845 continueMove / continueInbound / continueVisitRemainder",
 "where": "EngineMoves.swift:180ff; bound followIDsPerTurn=512 (EngineMoves.swift:126), followsPerTurn=256 (EngineFollow.swift:11)",
 "cost": "O(log ids) a moved id, <=512 ids a turn",
 "figure": "turn-total tests; sharedApplyTurns, divergenceTurns, inboundHolderTurns <=7.4 ms (below)",
 "over32ms": "no",
 "worstGrouping": "any",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "INV :4846 move (fits the turn)",
 "where": "EngineFollow.swift:931-956",
 "cost": "sorts every interest's ids per call: O(N log N) per holder per move",
 "figure": "PROBE-C20R-PARTIAL-MOVE-C2 best 8.44-9.22 (users=false), 9.29-10.10 (users=true) (reqs/logs/probe1-3.log); many-moves 304.79 ms at k=64",
 "over32ms": "yes",
 "worstGrouping": "many moves",
 "nonSplittingFix": "EXCLUDED (move shape)"
}
- {
 "operation": "INV :4847 findInbound walk",
 "where": "EngineFollow.swift:1051ff",
 "cost": "one pass over jobs' ids, one lookup each",
 "figure": "inboundWalkTurns 404 turn c19 3.25, c20 3.31; publicationApplyTurns walk median 2.09/2.10, apply wait 3.90/4.02, near-every-member move 5.78/5.86 (draft :7337-7342, :7534-7540); correct 4.50 apply wait (bench.log:292)",
 "over32ms": "no",
 "worstGrouping": "10,000 owed jobs",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "INV :4848 reroute, addInterest",
 "where": "EngineDispatch.swift:1145ff (reroute)",
 "cost": "O(1) amortised per id",
 "figure": "concentrationFollowTurns c19 3.66, c20 3.64 best",
 "over32ms": "no",
 "worstGrouping": "any",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "INV :4849 removeInterest, dropInterest, relane, Job.lane, isSingleUser",
 "where": "EngineJobs.swift:339 (removeInterest); counts from f066083",
 "cost": "O(1) per id (was O(I) per id before f066083)",
 "figure": "userSharedApplyTurns supersede 7.18, keep 8.01 best (c20 gate, draft :7513-7515); pre-fix 32.89 / 70.82 on 49a0493; reqs gate 7.21 / 8.11 (gates/bench.log:299-301); correct 7.45 / 8.18 (bench.log:311-313); C19C-USER-SHARED-TURNS apply window 10.46 / 11.01 ms, follow turns <=5.65 (correct/logs/rel-userq.log:7,14)",
 "over32ms": "no",
 "worstGrouping": "one user waiter per id",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "INV :4850 deferBehindVerdict",
 "where": "EngineFollow.swift:963-978",
 "cost": "O(E) per join (lastIndex scan + two mid-array inserts)",
 "figure": "PROBE-C20R-DEFER-BEHIND-C2 35.78/36.52/37.91 best; PROBE-C20C-DEFER-BEHIND 39.55 best",
 "over32ms": "yes",
 "worstGrouping": "10,000 joins behind one waiting verdict",
 "nonSplittingFix": "EXCLUDED (deferBehindVerdict shape)"
}
- {
 "operation": "INV :4851 drain's events (drainEventsAfterFollow)",
 "where": "EngineFollow.swift:188-228; eventsAfterFollowPerTurn=512 (:173)",
 "cost": "<=512 events a turn; one removeFirst(count) O(E) per turn (:200-201), not per event; visits after verdicts share drainIDsLeft",
 "figure": "drainVerdictTurns 500/job 4.13, 625/job 4.08 best (c20 gate); pre-fix 40.79 on 49a0493; reqs gate 4.14 / 4.11; correct 4.30 / 4.15 (bench.log:305-307); C19C-DRAIN-C2 3.02-3.14 (rel-drainq.log:8,11)",
 "over32ms": "no",
 "worstGrouping": "16 waiting verdicts / 10,000 places",
 "nonSplittingFix": "not needed (the verdict replay's take-off is the excluded drain take-off shape)"
}
- {
 "operation": "INV :4852 verdictAnswers (retry verdict's per-interest answer)",
 "where": "EngineFailures.swift:895-905",
 "cost": "O(1) per interest, O(I) per verdict",
 "figure": "no own figure; covered indirectly by the 429/throttle cases (<=9.2 ms)",
 "over32ms": "no",
 "worstGrouping": "one job with 10,000 user waiters: 10,000 O(1) checks, INFERRED ~1-2 ms",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "INV :4853 followedLane",
 "where": "EngineFailures.swift:721-837; sole caller throttled() :346",
 "cost": "row says O(I) a call; code walks all jobs and their interests (:788-818), all waiting events (laneEventsWaiting :845-863 and :820-835), pending inbound ids (inboundPendingIDs EngineFollow.swift:1136ff), jobAtVerdict copies a job once per rule (:872-879). Linear in jobs + interests + ids + E, once per 429 turn",
 "figure": "concentrationNotFoundTurns followedLane c19 3.37, c20 3.45; inboundWalkTurns 429 c19 2.83, c20 2.73; correct 2.80 (bench.log:244)",
 "over32ms": "no",
 "worstGrouping": "10,000 jobs with a verdict waiting and ~10,000 events waiting: INFERRED linear, a few ms",
 "nonSplittingFix": "not needed; row's cost text should read O(jobs+interests+ids+E) per call"
}
- {
 "operation": "INV :4854 recordDeferredVerdict's and publication start's away filters",
 "where": "EngineFollow.swift:508-526 (filter :515)",
 "cost": "O(N) once per event, one copy lookup per id; mutations write scalar fields and one Set, no per-id CoW",
 "figure": "publication start inside concentrationPublicationTurns; verdict's filter unmeasured",
 "over32ms": "no",
 "worstGrouping": "one job of 10,000 ids failing while a follow is owed: INFERRED ~1 ms (one lookup per id, compare findInbound's 3.3 ms over 10,000 jobs)",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "INV :4855 commit's binding (committed -> resolveAll -> publishTerminal)",
 "where": "EngineDispatch.swift:1100-1138; EngineJobs.swift:611-645",
 "cost": "bind O(N); per token sorted interests + filter; resolveAll sorts tokens and delivers per token; publishTerminal sorts assets and broadcasts per asset: O(N log N + I log I)",
 "figure": "concentrationPublicationTurns c19 5.03 (start only); c20 gate 9.86 best (through commit), 9.81 pre-commit; reqs gate 9.82 (gates/bench.log:249); correct 10.21 at load <=11.24 and 10.16 rerun at 3.12-3.14 (bench.log:250, bench-rerun.log:7). Bench shape is ONE prefetch group + one user waiter (BenchSync.swift:3131-3137), so per-token costs are measured at I=2",
 "over32ms": "unknown",
 "worstGrouping": "one user waiter per id (10,000 interests answered at commit, 10,001 broadcasts with a subscriber): unmeasured. INFERRED estimate ~15-20 ms = 10 ms measured + ~2 ms for 10,000 waiter resumes (shutdown with 10,000 resolves 1.6-1.8 ms, bench.log:196) + ~5-6 ms for 10,000 broadcasts (prune announcement to a stalled subscriber 4.8-5.8 ms, bench.log:205) + token sort/loops",
 "nonSplittingFix": "yes if needed: constant-factor only, in-turn: iterate job.interests once without the extra per-token self.state.jobs[transfer]?.interests[token] re-lookup (EngineJobs.swift:619-621) where no delivery can mutate other tokens (needs proof), reserveCapacity for deferred, skip the bound/unbound filter for tokens whose assets are all bound by one count check, avoid Set(ids) when locations already keys it. Recommend a BenchSync variant with one user waiter per id to measure first"
}
- {
 "operation": "INV :4856 commit's re-routes of ids moved away",
 "where": "EngineDispatch.swift:1109-1135",
 "cost": "O(N) re-routes in one turn",
 "figure": "concentrationCommitRerouteTurns c20 48.68 (gate), 47.99 (reqs), 49.35/49.34 (correct)",
 "over32ms": "yes",
 "worstGrouping": "10,000 converged ids moved away",
 "nonSplittingFix": "EXCLUDED (commit re-routes shape)"
}
- {
 "operation": "INV :4857 replayVerdict take-off and re-route of moved-before ids",
 "where": "EngineFollow.swift:543ff (takeOffMovedBefore)",
 "cost": "O(N log N) in one turn (sorts tokens and each interest's ids)",
 "figure": "movedBeforeDrainTurns c20 45.67 (gate), 47.03 (reqs), 49.08/47.03 (correct)",
 "over32ms": "yes",
 "worstGrouping": "10,000 ids",
 "nonSplittingFix": "EXCLUDED (drain take-off shape)"
}
- {
 "operation": "INV :4858 supersede of a superseded publication",
 "where": "EngineDispatch.swift:1256 (per c20-issues reqs[0] fix text)",
 "cost": "O(N) re-routes in one turn",
 "figure": "PROBE-C20C-SUPERSEDE-C2 41.09 best (c20-issues correct[2])",
 "over32ms": "yes",
 "worstGrouping": "10,000 ids",
 "nonSplittingFix": "EXCLUDED (supersede shape)"
}
- {
 "operation": "BENCH spaceParkingTurns (:140)",
 "where": "BenchSync.swift:138-157",
 "cost": "10,000-member prefetch group parking / ENOSPC read",
 "figure": "c20 gate in range 0.02-5.24 (draft :7543-7545); reqs 4.30 / 3.16; correct 5.01 / 3.36. c19: not itemised in draft",
 "over32ms": "no",
 "worstGrouping": "many groups / waiter per id unmeasured; INFERRED O(1) per id",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH spaceReadmissionTurns (:166)",
 "where": "BenchSync.swift:164",
 "cost": "re-admission of 10,000 parked",
 "figure": "reqs 4.19; correct 5.26; c20 gate within 0.02-5.24",
 "over32ms": "no",
 "worstGrouping": "n/a",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH networkEdgeTurns (:187)",
 "where": "BenchSync.swift:185",
 "cost": "offline/online edge",
 "figure": "reqs 1.37 / 3.97; correct 1.39 / 4.32",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH handleReleaseTurns (:212) and userHandleReleaseTurns (:345)",
 "where": "BenchSync.swift:210, :343",
 "cost": "release of 10,000-member handle (continueReleases bounded, EngineCommands.swift:395)",
 "figure": "prefetch: reqs 5.67, correct 5.50; user: reqs 5.89, correct 5.40",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH shutdownTurns (:235)",
 "where": "BenchSync.swift:233",
 "cost": "shutdown with 10,000 members + 10,000 waiting resolves",
 "figure": "reqs 1.61; correct 1.77",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH refreshUnderGroupTurns (:261), changedRefreshTurns (:283)",
 "where": "BenchSync.swift:259, :281",
 "cost": "apply under / changing a 10,000 group",
 "figure": "reqs 1.26 / 4.19; correct 1.24 / 4.29",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH pruneAnnouncementTurns (:303)",
 "where": "BenchSync.swift:301",
 "cost": "10,000-id prune to stalled subscriber",
 "figure": "reqs 4.83; correct 5.78. Draft 'Not verified': ~35 ms at maxEntries (outside 10,000 reference)",
 "over32ms": "no",
 "worstGrouping": "at 10,000 no; at maxEntries ~35 ms (not C2 reference scale)",
 "nonSplittingFix": "not needed at 10,000"
}
- {
 "operation": "BENCH dueRetriesTurns (:322)",
 "where": "BenchSync.swift:320",
 "figure": "reqs 1.23; correct 1.25",
 "cost": "10,000 retries due",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH handleRejoinTurns (:370)",
 "where": "BenchSync.swift:368",
 "cost": "re-join of released handle",
 "figure": "prefetch reqs 5.68 / correct 5.69; bulk reqs 6.31 / correct 5.88",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH resolveCancelTurns (:394), cooldownEndTurns (:416), probeChainTurns (:445)",
 "where": "BenchSync.swift:392, :414, :443",
 "cost": "cancel / breaker",
 "figure": "reqs 0.030 / 0.079 / 0.88; correct 0.022 / 0.077 / 0.80",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH throttleExtensionTurns (:467)",
 "where": "BenchSync.swift:465",
 "cost": "429 under 10,000 user waiters (failFast per token)",
 "figure": "c19 gate 6.77 best [6.77,10.41,6.90]; c20 gate 7.20; reqs 8.27; correct 9.22",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH reclaimDuringFollowTurns (:494)",
 "where": "BenchSync.swift:492",
 "cost": "reclaim during owed follow",
 "figure": "1 handle c19 3.74-3.80, c20 3.79; 2 handles c19 4.89, c20 4.83; reqs 3.92/5.06; correct 4.11/5.11",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH reclaimDuringMixedFollowTurns (:519)",
 "where": "BenchSync.swift:517",
 "cost": "mixed reclaim",
 "figure": "c19 gate 6.21 / 7.58 (3cd80c7 run 11.88 one handle, under load); c20 5.81 / 6.85; reqs 6.23 / 7.88; correct 6.84 / 7.86. Draft notes judging turns of sweep follow-ups 4.0-11.8 ms by scratch probe only",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH followDrainTurns (:546), followEndTurn (:573)",
 "where": "BenchSync.swift:544, :571",
 "cost": "follow end + drain of 10,000 places",
 "figure": "followDrain c19 4.88, c20 4.86; reqs 5.21; correct 5.15. followEnd turn c19 4.71, c20 4.65 (wait 4.94); reqs 5.21; correct 5.19",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH inboundWalkTurns (:607)",
 "where": "BenchSync.swift:605",
 "cost": "404 walk over 10,000 owed jobs + 429 followedLane",
 "figure": "c19 3.25 / 2.83; c20 3.31 / 2.73; reqs 3.71 / 2.81; correct 3.74 / 2.80",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH concentrationNotFoundTurns (:635)",
 "where": "BenchSync.swift:633",
 "cost": "10,000 ids converge, 404 verdict waits",
 "figure": "c19 6.20 (lane 3.37); c20 6.24 (lane 3.45); reqs 6.66; correct 6.56",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH concentrationPublicationTurns (:647)",
 "where": "BenchSync.swift:645-649",
 "cost": "publication begins and commits (see INV :4855)",
 "figure": "c19 5.03 (start only); c20 9.86 gate, 9.82 reqs, 10.21 / 10.16 correct",
 "over32ms": "no",
 "worstGrouping": "user waiter per id unmeasured (see INV :4855)",
 "nonSplittingFix": "see INV :4855"
}
- {
 "operation": "BENCH concentrationCommitRerouteTurns (:657)",
 "where": "BenchSync.swift:655",
 "cost": "commit re-routes",
 "figure": "c20 48.68 gate / 47.99 reqs / 49.35, 49.34 correct",
 "over32ms": "yes",
 "nonSplittingFix": "EXCLUDED"
}
- {
 "operation": "BENCH concentrationFollowTurns (:666)",
 "where": "BenchSync.swift:664",
 "cost": "follow's own moving turns",
 "figure": "c19 3.66; c20 3.64; reqs 3.72; correct 3.77",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH movedBeforeDrainTurns (:677)",
 "where": "BenchSync.swift:675",
 "cost": "drain take-off",
 "figure": "c20 45.67 gate / 47.03 reqs / 49.08, 47.03 correct",
 "over32ms": "yes",
 "nonSplittingFix": "EXCLUDED"
}
- {
 "operation": "BENCH publicationApplyTurns (:738)",
 "where": "BenchSync.swift:736",
 "cost": "bringInboundOntoPublications walk",
 "figure": "c19 2.09/3.90/5.78; c20 2.10/4.02/5.86; reqs 2.13/4.53; correct 2.34/4.50",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH sharedApplyTurns (:769)",
 "where": "BenchSync.swift:767",
 "cost": "visit of 10,000 sharing one content",
 "figure": "c19 gate 6.67 / 7.08 (3cd80c7: 23.37 / 22.98; 4b1c3a6: 69.20 / 83.03); c20 6.82 / 7.24; reqs 6.81 / 7.25; correct 6.98 / 7.40",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH divergenceTurns (:798)",
 "where": "BenchSync.swift:796",
 "cost": "converged ids mapped away",
 "figure": "c19 7.00 / 6.96 (3cd80c7: 22.96 / 23.22; 4b1c3a6: 58.84 / 56.46); c20 7.03 / 7.04; reqs 7.17 / 7.12; correct 7.22 / 7.39",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH inboundHolderTurns (:825)",
 "where": "BenchSync.swift:823",
 "cost": "attempt end bringing 10,000 ids onto content",
 "figure": "c19 7.25 (3cd80c7 19.93; 4b1c3a6 50.63); c20 7.18; reqs 7.22; correct 7.36",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH drainVerdictTurns(500/625) (:852)",
 "where": "BenchSync.swift:850",
 "cost": "drain visits after 16 verdicts",
 "figure": "c20 4.13 / 4.08 (49a0493 pre-fix 40.79 / 4.61); reqs 4.14 / 4.11; correct 4.30 / 4.15",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}
- {
 "operation": "BENCH userSharedApplyTurns(supersede/keep) (:876)",
 "where": "BenchSync.swift:874",
 "cost": "apply, 10,000 user waiters sharing one content",
 "figure": "c20 7.18 / 8.01 (49a0493 pre-fix 32.89 / 70.82); reqs 7.21 / 8.11; correct 7.45 / 8.18",
 "over32ms": "no",
 "nonSplittingFix": "not needed"
}

## summary

At a 40 ms ceiling with a 32 ms target, the only operations measured over 32 ms at 10,000 ids are the five excluded shapes. Those figures are best of 3 at a 1-minute load of 10 or less:
- commit re-routes: 47.99 to 49.35 ms;
- drain take-off: 45.67 to 49.08 ms;
- supersede: 41.09 ms;
- deferBehindVerdict: 35.78 to 39.55 ms;
- move with many owed moves: 79.55 ms at k=16 and 304.79 ms at k=64.

Every other BenchSync C2 case measures 11.01 ms or less in cycles 19 and 20 at quiet load. That covers 31 benchmark functions, counting each parameterised case once. Figures from runs under load were higher: for example, sharedApplyTurns and divergenceTurns measured 56 to 83 ms on 4b1c3a6, and 3cd80c7's mixed reclaim measured 11.88 ms. Both were pre-fix commits. The highest non-excluded figures at HEAD are:
- concentrationPublicationTurns through the commit: 9.82 to 10.21 ms;
- the C19C-USER-SHARED-TURNS apply window: 10.46 and 11.01 ms;
- throttle extension: 9.22 ms.

Two pre-fix figures over 32 ms are already fixed at 8e1fb24: drainVerdictTurns at 40.79 ms and userSharedApplyTurns keep at 70.82 ms.

One non-excluded row has a grouping that is unmeasured and over32ms "unknown": the commit's binding (INV :4855) with one user waiter per id and a subscriber. Its bench covers only one prefetch group and one waiter (BenchSync.swift:3131-3137). The INFERRED estimate is about 15 to 20 ms. It is built from the measured 10 ms commit, about 2 ms for 10,000 waiter resumes (by analogy with shutdown's 1.6 to 1.8 ms) and about 5 to 6 ms for 10,000 broadcasts (by analogy with the prune announcement's 4.8 to 5.8 ms). If it does exceed 32 ms, a non-splitting constant-factor fix exists. The fix list is in that row. A BenchSync variant should measure this grouping first.

Inventory rows whose stated cost does not match the code:
- startMove (:4844) is O(job's ids) per call, not O(moved ids) (EngineMoves.swift:158-162). That makes it O(N×k) under many moves. This belongs to the excluded move shape and its fix is an asset→token index.
- followedLane (:4853) is O(jobs + interests + ids + waiting events) per call, not O(I) (EngineFailures.swift:721-837). It runs once per 429 and measures 2.7 to 3.5 ms, so it is not flagged.

recordDeferredVerdict's away filter (EngineFollow.swift:515) is O(N) once with one lookup per id. INFERRED at about 1 ms, so it is not flagged. The drain's removeFirst runs once per turn, not once per event (EngineFollow.swift:200), so it is not flagged.

Two items fall outside the 10,000-id reference: the prune announcement at maxEntries, about 35 ms (draft "Not verified"), and the WP-B P-13 unit, 8.4 to 10.16 ms.
