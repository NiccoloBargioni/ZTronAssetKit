# critic:rr21-compose

Read-only analysis for ruling S3-R26 (workflow wf_c114d84e-f12, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## verdict

sound-with-amendments: interaction 1's replay order, step 12's put-back over A6, steps 13-15 over A8-A9 and the one-turn commit with C1 and C3 all compose, but owed items sit on no job. The site turn's reconcileIdle therefore prunes their bindings, which gives a different answer than visit-first in both orders (a blocking candidate) and must be guarded. Step 9, step 15, the stub lookup, the shutdown text and the implementation order also need the amendments below.

## refutations

- {
 "claim": "Interaction 13 (integrate-c21.md:510) and design-minimal's events_between_turns bullet ('Bindings forgotten ... a missing binding costs a store read before the transfer') say that pruning the bindings of owed items costs one more job and one more read, a timing change.",
 "evidence": "WHY THE CLAIM FAILS. The pre-transfer read runs only inside an admitted attempt: answeredFromStore has one caller, Sources/ZTronAssetSync/Engine/EngineDispatch.swift:782. A parked job answers its waiters and ensure members through park -> failFast (EngineDispatch.swift:468-486, failFast call at :480; Sources/ZTronAssetSync/Engine/EngineJobs.swift:651-690) and never reads the store.\n\nCOUNTEREXAMPLE. followIDsPerTurn = 4, so inboundIDsNow = 2 (Sources/ZTronAssetSync/Engine/EngineMoves.swift:130-132). Non-Apple tier, no run, no group, no other job.\n(1) User waiters W0..W3 wait on a0..a3, all at content C. Job O's publication is held in store.publish (EngineDispatch.swift:1058) with binding [a0..a3] (:1049).\n(2) A run applies v2, which maps a1..a3 to content X. The store already holds X, so report.reused records boundContent[ai] = T_X (Sources/ZTronAssetSync/Engine/EngineRuns.swift:374-381). The follow passes the verifying O (Sources/ZTronAssetSync/Engine/EngineFollow.swift:864-865). The run settles, and reconcileIdle keeps the bindings because O still holds a1..a3 (Sources/ZTronAssetSync/Engine/EnginePresence.swift:85-89).\n(3) X's byteSize is above the headroom, with pendingReclaim 0.\n(4) The store binds a0 only.\n\nANSWER AT 8e1fb24 (visit-first). committed re-routes a1..a3 in its own turn (EngineDispatch.swift:1121-1122). reroute finds isBound (:1164), and answerPresent -> answerWaiterFromStore answers W1..W3 .success(location). No job of X is ever created.\n\nANSWER UNDER design-minimal. Step 6 owes the 3 items, since 3 > 2. committed's reconcileIdle (EngineDispatch.swift:1138) reaches pruneBoundContent. run is nil, no reader is in flight, no group exists, and jobs is empty after removeJob, so removeAll runs (EnginePresence.swift:81-83); with another job alive, the filter at :85-89 drops these bindings too. In the drain, reroute misses isBound and addInterest creates X (drainingAfterFollow, EngineJobs.swift:110). The tail pump's gate lets the user lane pass with nil conditions (EngineDispatch.swift:498; Sources/ZTronAssetSync/Engine/EngineSupport.swift:239-240). spaceBlock returns .insufficientSpace (EngineDispatch.swift:583-595), so park -> failFast answers W1..W3 .failure(.insufficientSpace(required:available:)) (EngineJobs.swift:668-690).\n\nVARIANTS. With an origin throttle in force for 600 s and interactiveMaxWait = 2 s, W1..W3 get .serverUnavailable(retryAfter: about 600). With an open breaker they get .serverUnavailable(retryAfter: nil).\n\nBOTH ORDERS. No follow is owed at the commit, so both LaneDropVisit orders give these answers.\n\nNOT EXCUSED. S3-R17 item 2 does not apply: no gate changed. S3-R24 item 5 does not apply: no input lands between the two answers, because the prune runs in the site's own turn.\n\nOTHER SITES. The same happens at site 3 (publicationFailed's reconcileIdle, EngineDispatch.swift:1248) and at site 2 (drainFollowUp's reconcileIdle, EngineFollow.swift:416, between drain turns). Skipping the site's own call is not enough: setStoreDeadline's reconcileIdle (Sources/ZTronAssetSync/Engine/EngineTimers.swift:312) prunes in the next turn.\n\nNot probed: this run is read-only, and S3-R19 item 1 requires a probe.",
 "severity": "blocking",
 "fix": "In pruneBoundContent, after its first guard, add `guard self.state.eventsAfterFollow.isEmpty else { return }`. This is O(1). Add to the doc: 'or while events wait for the follow: an owed re-route consults its binding at replay'. The ledger is then trimmed at the first reconcileIdle after the queue empties (EngineFollow.swift:416).\n\nNarrower alternative (critic-commit-window.md:201-205): union the assets of the waiting .reroutes items into `wanted`, and never call removeAll while one waits. This costs O(items) per call.\n\nLand the guard in the same commit as step 6.\n\nPin: the shape above at each site (commit, .superseded, verdict take-off). Assert that W1..W3 get .success, that no job of T_X exists, and that the invariants are clean, in both orders. The guard's drop-mutant must fail 2/2 per order. Probe it on the RR-21 build before ruling.\n\nRewrite interaction 13 and design-minimal's 'Bindings forgotten' bullet to match."
}
- {
 "claim": "design-minimal (invariants, events_between_turns) says the drain replays the owed event under the site's reading and admits the jobs it creates as visit-first would, so idle handling needs no change.",
 "evidence": "hasWork (Sources/ZTronAssetSync/Engine/EngineConditions.swift:8-11) does not count eventsAfterFollow. So whenever the site removed the last job, the same reconcileIdle that prunes (EngineConditions.swift:15-24) also sets watcher = nil and conditions = nil. withReading sets only the reading instant; gate reads the live conditions.\n\nAt the drain, addInterest's ensureWatcher (Sources/ZTronAssetSync/Engine/EngineJobs.swift:150-152; EngineConditions.swift:29-41) only spawns the watcher. The tail pump runs in the same turn while conditions are still nil:\n- non-user lanes and the Apple tier wait, which is only timing;\n- a user-lane job on a non-Apple tier is admitted optimistically (Sources/ZTronAssetSync/Engine/EngineDispatch.swift:498; Sources/ZTronAssetSync/Engine/EngineSupport.swift:239-240).\n\nShape: NetworkPolicy.userInitiatedOverridesPolicy = false and prefetchOnExpensive = false, on a network already known to be expensive.\n- Visit-first parks X with .policy(.expensiveNetwork) (EngineSupport.swift:247-253). failFastError returns nil for .policy (EngineJobs.swift:687-688), so W1..W3 keep waiting.\n- design-minimal starts X. The new watcher's first reading then pauses it (applyConditionsToJobs -> pauseIfRefused, EngineConditions.swift:122-124).\n- If the attempt ends before that reading, W1..W3 get .success, or an offline-class error, where visit-first leaves them waiting. The attempt can end first with a fake transport that completes, or with a live transport that fails fast under NetworkAccess(allowsExpensive: false) (EngineDispatch.swift:551-561).\n\nThere is always one extra start. The answer depends on that race, so a probe may show (a) or a flake (d).",
 "severity": "major",
 "fix": "Add `|| !self.state.eventsAfterFollow.isEmpty` to hasWork (O(1)), so the watcher and the conditions stay alive while owed work waits. Land it with step 6.\n\nPin: the policy shape above at followIDsPerTurn = 4. Assert that X is parked with .policy, that no transport start happens, and that W1..W3 are unanswered, in both orders. The disjunct's drop-mutant must fail.\n\nProbe before ruling it blocking."
}
- {
 "claim": "design-minimal step 9: takeOffMovedBefore keeps its Job parameter and makes 'one unsorted pass over job.interests', called with the Job copies that replayVerdict and the .spaceFailure replay hold.",
 "evidence": "replayVerdict binds `job` at Sources/ZTronAssetSync/Engine/EngineFollow.swift:612 and keeps it alive across takeOffMovedBefore(job) and endDeferral(job) (:615-616). The .spaceFailure arm does the same at :349-353.\n\nThe take-off mutates the job in place: assets.subtract at :557, then removeAsset, subtractAssets and dropInterests. With the copy still alive, each of these copies the job's id set and interest table, which is O(N) at 10,000 ids. The pass also walks every interest's ids instead of the holders of the held ids.\n\nInteraction 10 and B12 (integrate-c21.md) require B5's moveItems or holdings with a TransferID, and B's must_not (integrate-c21.md:291) forbids a Job copy across removals. endDeferral (:537-541) also reads the copy, and interaction 10 does not cover it.",
 "severity": "major",
 "fix": "Change the signature to `takeOffMovedBefore(_ transfer: TransferID) -> OwedReroutes?`:\n- compute `held` through self.state.jobs[transfer]?;\n- in one scoped read, read moveItems(of: held), the lane and kind, and each token's interest count;\n- decide whole versus partial per token by comparing its item count with that count;\n- then mutate only through self.state.jobs[transfer]? (assets.subtract, subtractAssets, dropInterests).\n\nCallers:\n- guard on self.state.jobs[transfer]?.epoch and on the job's state, without binding a Job;\n- read movesAfter as a Bool before the take-off. That is exactly what endDeferral reads today from the pre-take-off copy, and it keeps followAfterVerdict's unfollowed.remove when the take-off retires the job;\n- then take off, set attemptEnd = nil, give the verdict, run followAfterVerdict, and call rerouteTakenOff."
}
- {
 "claim": "design-minimal step 2: the nil-stub `continue` in continueReroutes is 'structural, covered by the clause in step 15'.",
 "evidence": "Every item's token gets a stub at the site, and no writer removes a stub (steps 6, 8, 9 and 13), so the else branch cannot be reached. An unreached changed branch is the G4 class that made cycle-20 reqs #4 and #5 and correct #6 and #7 blocking (S3-R24 item 3, S3-R25 item 7). design-minimal's new_branches (N1-N16) lists no test for it.",
 "severity": "major",
 "fix": "Carry lane and kind in each owed item: either an OwedItem ordered by (asset, token), or MoveProgress made generic over its item. Then drop the stub dictionary and the 'every item's token has a stub' clause. followedLane and the purge read lane and kind from the item. As before, no id set is shared."
}
- {
 "claim": "Implementation order step 1 (integrate-c21.md:520-523): commit T4 and T5 stage 1, failing, on their own, before steps 2-4.",
 "evidence": "run_tests is `swift test ... --skip Benchmarks` (Scripts/verify.sh:92), so it runs T4 and T5. T4 fails on 8e1fb24 and T5 fails in sweep-first, so `bash Scripts/verify.sh --quick` is red from step 1 until B7 and B8 land in step 4. C Phase 1 (step 2) and A (step 3) would then land without a green inner loop, with new regressions hidden behind the known failures.\n\nBenchSync cases are skipped by --quick and run only in perf_tests (Scripts/verify.sh:115), so they can land early.",
 "severity": "major",
 "fix": "Step 1 lands only the BenchSync cases, and records T4's and T5's failing runs on 8e1fb24 in the draft. Each unit test then lands as the first commit of the sub-step that fixes it: T4 just before B7, T5 together with B8 and I2. This still meets P3's failing-test-first rule and keeps every commit green."
}
- {
 "claim": "Implementation order steps 2 and 6: commitTurns(.waiters), measured after Phase 1 at step 2, decides the Phase 2 trigger.",
 "evidence": "Step 5 adds RR-21's fit path to the commit's own turn. startReroutes(budget: inboundIDsNow) re-routes up to 256 items inside resolveAll's closure, at about 5 us each (Sources/ZTronAssetSync/Engine/EngineMoves.swift:121), which is about 1.3 ms. It also spawns one store read per waiter whose id is bound elsewhere (interaction 18; Sources/ZTronAssetSync/Engine/EnginePresence.swift:126-140).\n\nA mixed commit of 9,744 bound user waiters and 256 moved-away waiters pays both Phase 1's answers and this fit edge in one turn. That is a 10,000-id grouping. design-minimal's c2_argument does not cost it ('No re-route happens in a large site's turn'), and the measurement at step 2 cannot see it.",
 "severity": "major",
 "fix": "After step 5, re-measure commitTurns(.waiters) and add a mixed fit-edge case, including items bound elsewhere. Decide the Phase 2 trigger on those figures. If it fires, consider having site 1 owe everything (budget 0) when the job's interest count exceeds inboundIDsNow, before reaching for Phase 2."
}
- {
 "claim": "design-minimal step 15 says 'no item's interest is still on jobs[owed.from] or registered in joinsAfterFollow'; interaction 5 makes only the jobs half per (token, asset).",
 "evidence": "joinsAfterFollow is keyed [token: [asset: transfer]] (recount at Sources/ZTronAssetSync/Engine/EngineCommands.swift:2022-2033). Read per token, the clause reports valid states as violations:\n- a run R with a1 owed from O and a7 waiting as a .join. materializeRun runs before the barrier refusal (Sources/ZTronAssetSync/Engine/EngineDispatch.swift:89-108), and addInterest defers the join (Sources/ZTronAssetSync/Engine/EngineJobs.swift:110-116);\n- a group token with members in both places.",
 "severity": "minor",
 "fix": "Make both halves per (token, asset):\n- `jobs[owed.from]?.interests[item.token]?.assets.contains(item.asset) != true`;\n- `joinsAfterFollow[item.token]?[item.asset] == nil`.\nAlso report a (token, asset) that two waiting .reroutes events both carry (one place per interest)."
}
- {
 "claim": "design-minimal's liveness_argument ('The spawn-nil branch clears the events'), its events_between_turns shutdown bullet and fixer_design_assessment item 3 rely on scheduleDrainFollowUp's spawn-nil branch.",
 "evidence": "A11 removes Sources/ZTronAssetSync/Engine/EngineFollow.swift:390-399 at implementation step 3, before RR-21 lands at step 5 (interaction 5, integrate-c21.md:500).",
 "severity": "minor",
 "fix": "Cite instead:\n- drainEverything (Sources/ZTronAssetSync/Engine/EngineShutdown.swift:118-124);\n- drainFollowUp's isRunning guard (EngineFollow.swift:411);\n- K4;\n- interaction 14's running-turn argument: committed runs after EngineDispatch.swift:1069, publicationFailed has its guard at :1192, and drains run in running turns."
}
- {
 "claim": "Interaction 18 (integrate-c21.md:515): RR-21's per-turn budget (inboundIDsNow) bounds the answerPresent spawns of its re-route turns, and an 'already bound elsewhere' pin measures them.",
 "evidence": "Drain turns spend drainIDsLeft, which starts at followIDsPerTurn = 512 (Sources/ZTronAssetSync/Engine/EngineFollow.swift:203), not inboundIDsNow = 256.\n\nAlso, without refutation 1's fix, an owed item's binding is pruned before its drain turn unless a run is alive (the run == nil guard, Sources/ZTronAssetSync/Engine/EnginePresence.swift:75). The pin would then measure job creation, not answerPresent.",
 "severity": "minor",
 "fix": "State the bound as drainIDsLeft in drain turns and inboundIDsNow in site turns. Build the pin after refutation 1's fix, or with a live run, and assert that no job of the bound content is created."
}
- {
 "claim": "design-minimal step 14: an owed run item counts when stillWants(token:asset:kind:transfer: owed.from) holds, and the loop 'stops at .userInitiated, as the joins loop does'.",
 "evidence": "For a partly bound run interest, resolveAll -> deliver -> recordRunOutcome sets outstanding[O] = nil in the commit's turn (Sources/ZTronAssetSync/Engine/EngineRuns.swift:519). stillWants then reads false. The replay's reroute, though, checks only run?.token (Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1180-1184) and joins.\n\nRun interests are .bulk (EngineRuns.swift:499), so the miss matters only where nothing else is counted (`lane ?? job.lane`, Sources/ZTronAssetSync/Engine/EngineFailures.swift:837).\n\nA7 has changed the loop's `break` (:833) to `return .userInitiated`.",
 "severity": "minor",
 "fix": "For owed run items, test `self.state.run?.token == token`, as reroute does. End the loop with `return .userInitiated`, as A7 does."
}

## amendments

- {
 "step": "design-minimal step 6 (committed)",
 "change": "Collect first, then mutate.\n- In one scoped read, build the items with their lane and kind, the wholly and partly unbound tokens, and `refused`. Use C1's lazy `captured` and its cheapest-first conjunction.\n- Then call setInterest(nil) or subtractAssets through self.state.jobs[transfer]?, with no Job copy alive.\n- Call resolveAll(transfer, with: .committed(locations, ascending: ids)) (C3). Its closure runs holdForManifest, then startReroutes and, if needed, oweReroutes.\n- Keep pump and reconcileIdle, now behind the two idle fixes.",
 "why": "This is interactions 8 and 9, and C1 may land only here. The commit stays one synchronous turn: there is no await between Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1089 and :1091."
}
- {
 "step": "design-minimal step 7",
 "change": "Drop it. C3's walk of the sorted binding replaces it: publishTerminal iterates `ascending where locations[asset] != nil && job.assets.contains(asset)`.",
 "why": "Interaction 9. C's must_not also forbids iterating a Set for terminal events."
}
- {
 "step": "design-minimal steps 9-10",
 "change": "Rebuild the take-off on B5 with a TransferID and no Job copy alive, as refutation 3 describes. Callers read movesAfter before the take-off.",
 "why": "Interaction 10, B12 and B's rule against Job copies. The order of mutations stays as today: take-off, endDeferral, verdict, visit, re-routes."
}
- {
 "step": "design-minimal step 12",
 "change": "Insert events and stamps together: `[(left, stamp)] + batch[(offset + 1)...]` goes in at index 0 in one ordered insert, ahead of A6's overflow.\n\nAdd a pin with one verdict that both owes a take-off and has a materialised bucket that overflows the batch. Assert this order in both LaneDropVisit orders: verdict, .reroutes, bucket joins newest first, overflow, later events.",
 "why": "A6 moved the overflow to the head of the queue. No listed test kills the mutants 'bucket ahead of .reroutes' or 'put-back behind the overflow' (critic-defer-bucket A5(3))."
}
- {
 "step": "design-minimal step 13",
 "change": "- Guard on eventsAfterFollow.isEmpty.\n- Handle .join events through A8's helper, and buckets at their verdict's position.\n- Handle the .reroutes arm per event, with dropGroupMember in place (C10).\n- Call dropGroupMember for the removed items in (asset, token) order by sorting the removed subset, not in the heap's storage order.",
 "why": "Interaction 3, and A's must_not on Dictionary order: the heap's storage order comes from the site's Dictionary-order pass."
}
- {
 "step": "design-minimal step 14",
 "change": "Use `return .userInitiated` (A7), and test owed run items with run?.token == token, as refutation 10 describes.",
 "why": "Matches A7 and reroute's run guard, so followedLane counts what the replay joins."
}
- {
 "step": "design-minimal step 15",
 "change": "Use per-(token, asset) predicates for both jobs[owed.from] and joinsAfterFollow, and report duplicate owed items. Drop the stub clause if refutation 4 is adopted.",
 "why": "Interaction 5, and A11's point that F-20 re-creates jobs[owed.from] at replay."
}
- {
 "step": "design-minimal step 16 (pins)",
 "change": "Add these pins:\n- refutation 1's bound-elsewhere shape at each site;\n- refutation 2's policy shape;\n- step 12's composition pin;\n- a commit-site run shape with the run's interest wholly moved away, so outstanding[O] survives to the replay and exercises C11's in-place releaseRunClaim;\n- the same with the interest partly bound, so recordRunOutcome wipes outstanding[O];\n- refutation 6's mixed fit-edge commit case.",
 "why": "Each new behaviour needs a pin whose drop-mutant fails in both orders (S3-R23 item 3)."
}
- {
 "step": "New, landing with design-minimal step 6",
 "change": "pruneBoundContent returns early while eventsAfterFollow is not empty, and hasWork counts a non-empty eventsAfterFollow.",
 "why": "Refutations 1 and 2. Owed items sit on no job, so otherwise the idle reconciliation of every site turn and drain turn trims the bindings and the conditions that their replay reads."
}
- {
 "step": "design-minimal liveness_argument and events_between_turns",
 "change": "Cite drainEverything, drainFollowUp's guard and K4 instead of the spawn-nil branch. Replace 'a missing binding costs a store read before the transfer' with refutation 1's counterexample and its fix.",
 "why": "A11 removes that branch, and refutation 1 disproves the binding claim."
}
- {
 "step": "integrate-c21.md interaction 13",
 "change": "Replace 'a timing change' with refutation 1's counterexample and the prune guard.",
 "why": "The pruned binding changes the answer in both orders, which no ruling excuses."
}
- {
 "step": "integrate-c21.md interaction 18",
 "change": "Say drainIDsLeft for drain turns, and note that the pin needs refutation 1's fix or a live run.",
 "why": "See refutation 9."
}
- {
 "step": "integrate-c21.md implementation_order step 1",
 "change": "Land only the BenchSync cases early. Each failing unit test lands right before its fix, as refutation 5 describes.",
 "why": "Keeps --quick green at every step and still honours P3."
}
- {
 "step": "integrate-c21.md implementation_order step 5",
 "change": "Land RR-21's readers before its writers, each in the same commit as its tests and drop-mutants:\n(a) steps 1-5, with every exhaustive switch arm (replay, endsDrainBatch, A3's verdictKey, followBarrierViolations);\n(b) step 15's acceptances;\n(c) steps 11-12;\n(d) steps 13-14;\n(e) site 1 (step 6, with C1 and the two idle fixes), then site 3 (step 8), then site 2 (steps 9-10).",
 "why": "If an owing site lands before the acceptances, every existing test at followIDsPerTurn = 4 that commits more than two moved-away ids would report false violations (which tests these are is UNCONFIRMED). This order also lands no branch before its test."
}
- {
 "step": "integrate-c21.md implementation_order steps 2 and 6",
 "change": "Decide the Phase 2 trigger after step 5, using refutation 6's mixed fit-edge case.",
 "why": "The commit turn's C2 must include RR-21's fit path."
}

## checked_claims

- Interaction 1 holds with A6. Batch formation puts V's bucket right after V. replayVerdict (Sources/ZTronAssetSync/Engine/EngineFollow.swift:607-620) takes off before the verdict, and design-minimal step 10 returns the owed rest after followAfterVerdict (:586-593). Step 12 re-inserts that rest at the head, ahead of the bucket joins. The order is therefore: verdict; the visit, with its rest through followMoving and scheduleFollowFollowUp (:219-221); .reroutes; V's joins newest first; A6's overflow; later events.
- Step 12 composes with A6 within one batch. The overflow can only be the tail of the bucket of the batch's last verdict, and replaceSubrange has already put it at the head of the queue. One ordered insert at index 0 therefore keeps the logical order. K1 holds because formation removed the bucket key. If a later visit creates a new bucket for a put-back V, it is materialised ahead of V's older joins, which is newest first, as deferBehindVerdict's insert after V (:964-978) gives today.
- Steps 13-15 sit on A8-A9 as interactions 3-5 say. The purge guard on eventsAfterFollow.isEmpty is safe under K1. followedLane's queue loop (Sources/ZTronAssetSync/Engine/EngineFailures.swift:821-836) takes the .reroutes arm before A7's bucket walk. followBarrierViolations' exhaustive switch (Sources/ZTronAssetSync/Engine/EngineCommands.swift:2016-2030) takes the arm in the same loop as K1 and K2. Owed items are never registered in joinsAfterFollow, so K2's recount is unchanged.
- Folding C1 and C3 into step 6 keeps the commit one turn. committed (Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1100-1139) contains no await. resolveAll runs the closure after removeJob and publishTerminal (Sources/ZTronAssetSync/Engine/EngineJobs.swift:611-628). The next await is refreshStoreDeadlineAfterPublish at EngineDispatch.swift:1091.
- Interaction 14: oweReroutes runs only in running turns. committed runs after EngineDispatch.swift:1069, publicationFailed has its guard at :1192, and drains run after drainFollowUp's guard (EngineFollow.swift:411). So A11's removal of the branch leaves RR-21 no refused-spawn case.
- Interaction 12: today dropGroupMember (EngineJobs.swift:594-604) and releaseRunClaim (Sources/ZTronAssetSync/Engine/EngineRuns.swift:505-512) copy pending and outstanding on every call. C10 and C11 (step 2) must therefore precede RR-21's drain turns (step 5), and the plan's order does that.
- Interaction 16: under A5, deferBehindVerdict is O(1), so design-minimal's O(N·E) reason for not leaving at the deferral is moot. Its second reason still stands: a waiting .join replayed before J's verdict would be answered by that verdict.
- Interaction 17: owed items sit on no job, so I1-I3 are untouched.
- Interaction 2: these types are internal, so the new case and C3 change no public or package signature: EventAfterFollow (EngineFollow.swift:1405), MoveItem and MoveProgress (Sources/ZTronAssetSync/Engine/EngineMoves.swift:5, :20), JobInterest (EngineState.swift:558) and InterestOutcome (EngineJobs.swift:6). endsDrainBatch (EngineFollow.swift:1436-1443) and every exhaustive switch need the new arm.
- The must_nots are respected:
- B lands after C Phase 1 and its measured merge gate (step 2, then step 4);
- C1 lands only with step 6 (step 2 defers it, step 5 folds it in);
- B8 lands only with T5 and I2 (step 4);
- RR-21 adds no followBarrier disjunct, no await and no refused-spawn branch.
RR-21's batch end at a .reroutes rest is RR-21's own boundary, recorded by interaction 1; it is not A's rejected put-back.
- Steps 2-4 keep the build green as specified. C3's InterestOutcome change compiles at step 2, because committed already has ids and the patterns to update are EngineJobs.swift:553, publishTerminal's arm and EngineRuns.swift:521. A11 lands in step 3, before RR-21 calls scheduleDrainFollowUp. B lands in step 4, before step 9 needs B5.
- answeredFromStore has one caller, EngineDispatch.swift:782, inside an attempt. The other presence answers are reroute's answerPresent (:1164-1166), answerPresentMembers (Sources/ZTronAssetSync/Engine/EnginePresence.swift:350), a new waiter's check on arrival (EngineCommands.swift:102-106) and EngineManifest.swift:426.
- pruneBoundContent's only caller is reconcileIdle (Sources/ZTronAssetSync/Engine/EngineConditions.swift:16). setStoreDeadline also calls reconcileIdle (Sources/ZTronAssetSync/Engine/EngineTimers.swift:312) after every publication.
- recordRunOutcome counts fetched over the bound ids of the delivered interest only (EngineRuns.swift:520-524). Owing the unbound ids of a partly bound run interest therefore leaves fetched and failures as they are today.
- In the site's own turn, the fit path equals today's: the listing passed to reroute is the copy reroute reads anyway (EngineDispatch.swift:1151).

## concerns

- A take-off that fits within the ids left after a visit rest is re-routed before that rest, which is 8e1fb24's order. An owed take-off waits behind the whole rest (interaction 1). One shape thus has two orders. Both differ only in order, and both should be recorded.
- RR-21 moves T21's .notFound answers and the .success answers for ids bound elsewhere to the drain. A cancel that lands between turns is now answered .cancelled at once (Sources/ZTronAssetSync/Engine/EngineCommands.swift:176-192), where visit-first had already answered at the site. This is S3-R24 item 5's family, and the reason behind C's 'do not defer the answers' must_not; record it in the S3-R16 item 2 records.
- Refutation 1's O(1) guard keeps every binding while any event waits. A new request for such an id between turns is then answered from the store, where visit-first might already have pruned the binding; that is the timing family. The narrower `wanted` variant limits this to owed ids, at the cost of an O(items) walk per reconcileIdle.
- With refutation 1's fix, N11(e) (an owed id bound at the 429'd job's content) may become reachable. Its reachability must be re-checked under S3-R24 item 3.
- bind's doc (Sources/ZTronAssetSync/Engine/EnginePresence.swift:60, 'A binding not recorded only costs a store read before a transfer') is already imprecise on 8e1fb24 for a parked job, in the forget-serial case. That is pre-existing and outside RR-21, but RR-21 must not use it as its argument.
- A restarted watcher counts its first satisfied reading as an edge (EngineConditions.swift:95-101). It re-queues nothing, because a teardown leaves no failed job. Refutation 2's fix removes the restart altogether.
- Each owed event keeps the site's ValidatedManifest alive while it waits; this costs memory only.
- Inputs read: /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/design-minimal.md, integrate-c21.md, critic-commit-window.md, critic-defer-bucket.md, critic-move-index.md, design2-commit-window.md and design-fixer.md, together with /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-issues.json.

## grafts

- critic-commit-window.md:201-205, 'keep owed items' assets in wanted', as the narrower variant of refutation 1's fix.
- design-minimal's own C2 fallback, if the user-waiter drain case misses: spend at most inboundIDsNow on .reroutes per drain turn.
- A7's `return .userInitiated` for step 14's arm.
- B5's moveItems(of:), with its per-token counts, for step 9.
- A followBarrierViolations clause in K4's style, to pin refutation 2's disjunct: while running and while eventsAfterFollow is not empty, the watcher exists.

## residual_risks

- Jobs created at replay get different places and order than under visit-first (the RR-3, RR-16 and RR-23 families). This includes a later apply's visit creating the destination before the owed joins.
- An apply or a purge can land between the site and the drain (RR-23 family). A purge's dropBindings sends formerly bound items down the job path.
- A destination whose publication starts between turns does not capture the owed ids, so one more request is made (RR-3/RR-16).
- The purge's .reroutes arm resumes ensure groups in a different order; this is only an order difference once the removed items are sorted.
- Owed run items are .bulk, so followedLane's count can differ from the replay only in `lane ?? job.lane`. After refutation 10's fix it does not differ.
- Every C2 figure for RR-21's site and drain turns stays open until the BenchSync cases run at a load of 10 or less.

## unconfirmed

- Every cost estimate: about 5 us per re-route, the fit-edge commit turn, the spawn cost per answerPresent, the prune walk of the narrower fix, and the index releases in dropInterests.
- That, in refutation 1's shape, the test store's apply reports a1..a3 in report.reused when X's content is present, and that its publish binds a0 only (stillBound).
- That O's rerouteOnPass is empty in that shape, so the follow leaves a1..a3 on O.
- What a fake or live transport does with NetworkAccess(allowsExpensive: false) on an expensive path, and how the race in refutation 2 resolves.
- Which existing tests at followIDsPerTurn = 4 commit more than two moved-away ids. This is the reason for landing readers before writers.
- Whether the hasWork disjunct or the prune guard changes any existing idle-silence or ledger test.
- Whether removeJob clears `unfollowed`. It decides whether reading movesAfter after the take-off would give a different result.
- Whether Swift infers Sendable for OwedReroutes' members, which is needed because EventAfterFollow is Sendable.
- design-reuse.md and judge-rr21.md are not in /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/, so they were not read.
- Nothing was built, run or probed, because this run is read-only. Refutations 1 and 2 need probes under S3-R19 item 1.

## confidence

0.72
