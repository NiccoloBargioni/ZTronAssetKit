# critic:rr21-cost

Read-only analysis for ruling S3-R26 (workflow wf_c114d84e-f12, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## verdict

sound-with-amendments — the single .reroutes event, with MoveProgress and the drain's shared budget, is the right reuse: owed moves, visit rests and InboundMove cannot carry these items without raising followOwed or keeping a removed holder. But the C2 argument misses four groupings that still keep one turn above 10 ms, and several pins are blind to one order or leave drop-mutants alive. Each can be fixed without new EngineState.

## refutations

- {
 "claim": "c2_argument and invariants: 'a site's turn re-routes only when everything fits its budget'; 'Small shapes are today's single turn', so the commit's turn stays within C2.",
 "evidence": "The fit allowance is not charged against the commit's own work. The commit's binding and answers already cost 9.86 ms best at 10,001 bound ids, 'met, by 0.14 ms' (docs/adr-drafts/s3f.md:4855, concentrationPublicationTurns). startReroutes fits up to inboundIDsNow = max(1, 512/2) = 256 items (Sources/ZTronAssetSync/Engine/EngineMoves.swift:130-132), at about 5-6 us per re-route plus join (EngineMoves.swift:121). Counterexample at 10,000 ids, in the bench's shape: one prefetch group of 10,000 plus O's waiter, and v4 moves 256 members away during O's publication. The commit's turn binds and answers 9,745 ids (about 9.6 ms) and then re-routes the 256 in the same turn (about 1.5 ms): about 11 ms. 8e1fb24 does the same today, so RR-21 leaves this grouping open. The estimates are UNCONFIRMED; the 0.14 ms margin is measured.",
 "severity": "major",
 "fix": "Charge the bound answers in site 1's fit test, as design-fixer step 5 does (captured.count + U > budget means owe); for example, fit only when locations.count + unbound <= inboundIDsNow. Pin it with T3-captured in both orders: 1 bound + 2 moved-away ids at followIDsPerTurn = 4 must owe, and the drop-the-operand mutant re-routes them in the commit's turn (fails 2/2). Add BenchSync commitFitBoundaryTurns with 9,744 bound + 256 moved-away ids. Setup: 256 owed after the commit's turn, and D holds 256 once the barrier falls. Probe first (S3-R19 item 1)."
}
- {
 "claim": "c2_argument: 'No re-route happens in a large site's turn', and the drain turns bound the rest; integrate-c21 interaction 18: 'RR-21's per-turn budget (inboundIDsNow) bounds these spawns'.",
 "evidence": "When the ids moved to content the store already holds, the owed items lose their bindings before they replay. An apply records reused ids as bound (EngineRuns.swift:376-381). Then pruneBoundContent runs from the commit's reconcileIdle (EngineDispatch.swift:1138) and from every drain turn's (EngineFollow.swift:416). With no run, no presence reader and no group fetch left, it keeps only the ids of jobs (EnginePresence.swift:74-90), and owed items sit on no job. reroute therefore misses isBound (EngineDispatch.swift:1164) and joins a new job D, 512 per turn. After the barrier falls, D's pre-transfer read answers all 10,000 in one turn through answerPresentMembers (EnginePresence.swift:279, :338-354): a sort of 10,000 tokens, then answerPresent and answerWaiterFromStore, which spawns one task per waiter (:133-139; EngineLifecycle.swift:52-68). So the 'user waiter per id, bound elsewhere' shape is still one O(N) turn; it only moves from the site to after the barrier. The windows in step 16 end at the barrier's fall and cannot see it.",
 "severity": "major",
 "fix": "Keep the bindings while events wait: add self.state.eventsAfterFollow.isEmpty to pruneBoundContent's first guard. If existing tests change path, scan for a waiting .reroutes instead (O(E)). Owed bound items are then answered from the store at replay, at most 512 spawns per turn, as visit-first answered them at the site. Pin it with T-BOUND in both orders: 10 user waiters, v4 reuses D's blob for their ids, followIDsPerTurn = 4. Assert jobs[D] == nil and at most 4 new fromStore waiters after every held turn; the guard-drop mutant creates D and fails 2/2 in both orders. Add BenchSync userMovedToBound and groupMovedToBound, with windows that end when every owner is answered, not at the barrier's fall."
}
- {
 "claim": "c2_argument: drain turns are 'at most 512 re-routes, each joining one job in place ... about 2.6-3 ms a turn'; a purge 'filters them once and re-heapifies'.",
 "evidence": "This does not hold for the T21, purge and run arms on 8e1fb24. dropGroupMember uses `guard var group` and writes the group back (EngineJobs.swift:594-604). releaseRunClaim uses `guard var run ..., var claimed` (EngineRuns.swift:505-512). Each call therefore copies the group's pending map or the claimed set, up to 10,000 entries. removeJob never clears run.outstanding[from] (EngineJobs.swift:409-448), so a superseded run job's claims stay whole while they are owed. A drain turn of 512 delisted group members, or of 512 superseded run items, copies up to 10,000 entries 512 times, and the step-13 purge arm makes up to 10,000 such copies in the purge's single turn.",
 "severity": "major",
 "fix": "Name integrate-c21's C10 and C11 (integrate-c21.md:358-367, interaction 12) as hard prerequisites of steps 2 and 13, landed before RR-21 (implementation_order step 2). Add BenchSync groupDelistedAll, runSuperseded and purgeWhileOwed, each with setup expectations. groupDelistedAll: pending is emptied and no job is created. runSuperseded: outstanding[O] is nil and outstanding[D] holds 10,000 after the barrier falls. purgeWhileOwed: the owed event replays as a no-op."
}
- {
 "claim": "c2_argument for site 2: 'intersection, subtract, one interest's item pass, one setInterest(nil), then J's retirement and verdict as today. 0 re-routes'.",
 "evidence": "In both replays, followAfterVerdict runs between the take-off and rerouteTakenOff (EngineFollow.swift:355, :618), and it moves up to drainIDsLeft ids in that same turn (follow(..., ids: drainIDsLeft), :591). Take a retry verdict on a J that also holds ids moved after the deferral: that adds a 512-id visit, which costs 7.18-8.01 ms in the user shape (userSharedApplyTurns, docs/adr-drafts/s3f.md:4848). The O(N) take-off, with per-token removal of up to 10,000 tokens, runs in the same turn. The turn reaches about 10 ms (UNCONFIRMED).",
 "severity": "major",
 "fix": "Graft design-fixer's zeroing (step 8, N5): when the take-off does not fit, set drainIDsLeft = 0 before followAfterVerdict, so the whole visit becomes followMoving. Pin it with RR21-VERDICT-ZERO; its state arises only in sweepFollowsFirst. Add BenchSync movedBeforeAndAfterTurns: 5,000 ids moved before and 5,000 moved after the deferral. Setup: followMoving is set after the verdict turn, and that turn moved 0 ids."
}
- {
 "claim": "N7: dropping 'left != nil ||' or the prepend loses the event, and T6 kills it.",
 "evidence": "Only the prepend matters in both orders, and T1's turns 1 and 2 reach it through the existing drainIDsLeft <= 0 break (EngineFollow.swift:211). In the .reroutes arm, continueReroutes returns a rest only after spending its whole budget, so a rest already means drainIDsLeft == 0. The disjunct decides anything only when rerouteTakenOff refuses while ids are left, which is site 2. The take-off exists only for a verdict deferred under followOwed: recordDeferredVerdict's away needs followOwed (EngineFollow.swift:514), and the moved-before tests require a waiting verdict only in sweepFollowsFirst (Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierMovedBeforeTests.swift:63-68). In followVisitedFirst the disjunct's drop-mutant is Equivalent.",
 "severity": "minor",
 "fix": "With the zeroing graft, every rest comes with drainIDsLeft == 0 or followMoving != nil. Remove the disjunct (S3-R24 item 3, Removed) and keep the prepend of (left, stamp) inside the existing break."
}
- {
 "claim": "N12: T1, T5 and T6 kill the waiter, group and run acceptances and the followBarrierViolations .reroutes arm.",
 "evidence": "No new test carries a run item: T1 is a prefetch group, T6 has user waiters, and T5's kind is not given. So dropping the run-clause acceptance (EngineCommands.swift:1812-1817) survives. The waiter acceptance (:1707-1712) is reached only by T6, which exists only in sweepFollowsFirst. No test injects a violation into the new arm, so dropping the arm survives too. The arm's per-interest predicate also misfires once F-20's re-routes re-create jobs[owed.from] (integrate-c21 interaction 5).",
 "severity": "major",
 "fix": "Add T1-user (10 waiters) and T1-run in both orders. T1-run is design-fixer's RR21-RUN shape: a run's 5 moved-away ids owed at a commit. Check the invariants after every held turn. Add inject-one-violation tests for the arm (a missing stub; an item still on jobs[from]), like integrate-c21's T-PG1 to T-PG3, and make the arm per (token, asset)."
}
- {
 "claim": "T1 [10,6,2,0], T2 [4,2] and T3 ('no .reroutes waits, followBarrier is false, D holds both') hold 'in both LaneDropVisit orders'.",
 "evidence": "In sweepFollowsFirst, the first drain batch runs inside the follow's last turn on its leftover ids (EngineFollow.swift:158, :203). The site's fit re-routes are not joined there either: the barrier is up and the site is not draining (EngineFollow.swift:103-105), so they wait as .join events (EngineJobs.swift:110-116). The followVisitedFirst expectations therefore fail correct code in sweepFollowsFirst.",
 "severity": "minor",
 "fix": "Assert per order. In both orders: no turn above 4 items, and the right total. Exact sequences per order. In sweepFollowsFirst, the fit case is told apart by event kinds: two .join events and no .reroutes. Every mutant still gives a 6- or 10-item turn, or the wrong event kind, in both orders."
}
- {
 "claim": "T10 kills step 13's arm: the lane, kind and isPurged filters.",
 "evidence": "T10 purges .all, so isPurged is always true (EngineCommands.swift:992-1004), and dropping the isPurged condition survives.",
 "severity": "minor",
 "fix": "Add an .evictable or .scope variant in which one owed group item is not purged; it is kept and served D's bytes. Dropping isPurged then withdraws it, and the test fails 2/2 in both orders."
}
- {
 "claim": "T11, built on the takeOffLane shape, pins followedLane's .reroutes arm.",
 "evidence": "The take-off state exists only in sweepFollowsFirst (see the N7 refutation). The arm itself is reachable in both orders: a commit or .superseded owes items mapped to an in-flight job's content, and that job then gets a 429. followedLane has a single caller (EngineFailures.swift:346).",
 "severity": "minor",
 "fix": "Rebase T11 and its sub-shapes (a) to (d) on site 1, in both orders, and keep the takeOffLane form as an extra that runs only in sweepFollowsFirst."
}
- {
 "claim": "unconfirmed: reconcileIdle presumably treats an engine with no jobs and one waiting .reroutes as busy.",
 "evidence": "False. hasWork reads jobs, run, pendingRun, manifestFetch, unknownWaiters and conditionWaiters, never eventsAfterFollow (EngineConditions.swift:8-11). When F was the last job, the commit's reconcileIdle (EngineDispatch.swift:1138) stops the watcher and sets conditions = nil (EngineConditions.swift:17-20). The first replayed re-route that creates a job restarts it (EngineJobs.swift:152). Until its first element arrives, non-user admissions wait (EngineDispatch.swift:498).",
 "severity": "minor",
 "fix": "Record it as timing (S3-R16 item 2). It is newly reachable for barrier-down commits, and the tests must drive the conditions source. Alternatively add `|| !eventsAfterFollow.isEmpty` to hasWork, which needs one test and its drop-mutant."
}
- {
 "claim": "c2_argument: a drain turn's cost is its at most 512 re-routes.",
 "evidence": "Only the visits after verdicts and, newly, .reroutes items spend drainIDsLeft (EngineFollow.swift:592; step 11); replayJoin spends nothing (:692-709). When a .reroutes finishes mid-batch with ids left, the rest of the batch of at most 512 events (:173, :193-199) runs in the same turn: up to 511 .join replays, or a verdict's O(I) answers. The last owed turn can therefore carry about twice the work.",
 "severity": "minor",
 "fix": "Probe first. The user-waiter bench cases should put at least 511 waiting joins behind the event (for example, a prefetch of 600 other ids arriving after the commit). If a case misses, charge each .join replay one id against drainIDsLeft, with a per-turn count test."
}
- {
 "claim": "step 3: startReroutes mirrors startMove's fit guard (EngineMoves.swift:141-143).",
 "evidence": "startMove does not refuse: when a set does not fit, it moves budget ids in the same turn through continueMove and owes the rest (EngineMoves.swift:141-166).",
 "severity": "minor",
 "fix": "Record the all-or-nothing refusal as a deliberate difference that keeps the site's own O(N) pass alone in its turn. The partial form would add up to 256 re-routes to that turn, so it is not preferable for C2."
}

## amendments

- {
 "step": "2",
 "change": "Make C10 and C11 (in-place dropGroupMember and releaseRunClaim) explicit prerequisites. Record continueReroutes' nil-stub `continue` as unreachable (Equivalent under S3-R24 item 3), since a stub is built for every item's token. reserveCapacity the stubs.",
 "why": "Without C10 and C11, every T21 group item and every run item copies up to 10,000 entries per call (refutation 3). An unreachable else would show as uncovered in covdiff."
}
- {
 "step": "6",
 "change": "Fit only when locations.count + unbound <= inboundIDsNow. Fold C1 into this step and drop step 7, which C3 replaces (integrate-c21 interactions 8-9).",
 "why": "The commit's binding at 10,000 ids leaves 0.14 ms of C2 (refutation 1)."
}
- {
 "step": "new (EnginePresence.swift:74-90)",
 "change": "pruneBoundContent keeps every binding while eventsAfterFollow is non-empty. Fallback: keep them only while a .reroutes waits. Pin with T-BOUND and BenchSync userMovedToBound, timed to the last answer.",
 "why": "Otherwise the owed items lose their bindings, and their answers return as one answerPresentMembers turn of 10,000 spawns (refutation 2)."
}
- {
 "step": "9",
 "change": "Reuse removeInterest for each wholly held token instead of the new dropInterests. Here relane returns at once (EngineJobs.swift:285-296) and notifyObservers returns when nothing observes. Keep dropInterests only as the fallback if movedBeforeDrainWaitersTurns misses. Build the step on B5 (integrate-c21 interaction 10).",
 "why": "S3-R16 item 3: fewer changed branches. N13's multi-token path is reachable only in sweepFollowsFirst, and per-token removal is O(1) here."
}
- {
 "step": "10",
 "change": "When the take-off does not fit, set drainIDsLeft = 0 before followAfterVerdict, so its visit becomes followMoving (design-fixer step 8).",
 "why": "Otherwise the take-off turn also runs a visit of up to 512 ids (refutation 4)."
}
- {
 "step": "12",
 "change": "Drop the 'left != nil ||' disjunct and put (left, stamp) back inside the existing followMoving / drainIDsLeft <= 0 break.",
 "why": "With zeroing, the disjunct is redundant. Without zeroing it decides only in sweepFollowsFirst, and is Equivalent in the other order (refutation 5)."
}
- {
 "step": "13",
 "change": "Rely on C10. Add an .evictable or .scope variant of T10 in which a non-purged owed group item is kept and served.",
 "why": "Each purged item calls dropGroupMember, which copies the group without C10, and the isPurged condition's drop-mutant survives an .all purge."
}
- {
 "step": "14",
 "change": "Base T11 and sub-shapes (a) to (d) on a site-1 event and an in-flight job of the target content that gets a 429, in both orders.",
 "why": "The takeOffLane shape exists only in sweepFollowsFirst."
}
- {
 "step": "15",
 "change": "Make the .reroutes arm a per-(token, asset) check. Add T1-user and T1-run (RR21-RUN shape) in both orders, and add inject-one-violation tests for the arm.",
 "why": "Without them, the run acceptance and the arm keep surviving drop-mutants, and the per-interest form misfires once F-20 re-creates jobs[from] (refutation 6)."
}
- {
 "step": "16 (deterministic pins, per bound)",
 "change": "(a) Drain item bound: T1 at followIDsPerTurn 4 with held drain turns. Exact sequences per order; in both orders no turn above 4. Dropping `spent < budget` or `spent += 1` gives a 10-item turn, 2/2 in both orders. (b) Shared subtraction: T2 holds the drain between two commits that owe 3 each; the mutant makes a 6-item turn in both orders. (c) Fit guard and bound-answer charge: T3 (a 2-id job fits, 3 ids owe) and T3-captured, which kill always-owe, never-owe, '>' to '>=', and the dropped operand. (d) Site-2 zeroing: RR21-VERDICT-ZERO, which arises only in sweepFollowsFirst; rule on it under integrate-c21 open question 1. (e) Prune guard: T-BOUND in both orders. (f) Purge arm: T10 plus its non-purged variant. (g) followedLane arm: T11 on site 1.",
 "why": "S3-R23 item 3: each bound gets a small deterministic test whose drop-mutant fails 2/2, in both orders wherever the state exists in both."
}
- {
 "step": "16 (BenchSync pins)",
 "change": "Time each turn inside the actor by holding drain turns and using releaseOneHeldFollowOrDrainTurn (BenchSync.swift:1104-1120); movedBeforeDrain's releaseOneHeldTurn times follow turns only (:3457-3467). timeCommit's window ends at !jobExists(O) && !barrierUp, and rerouted is read after it (:3253-3266). Setup expectations: owed == 10,000 right after the site's turn, so a fit cannot pass the case, and the target holds 10,000 after the barrier falls. Cases: concentrationCommitRerouteTurns; commitRerouteWaitersTurns, with at least 511 joins behind the event; commitRerouteDivergentTurns; commitFitBoundaryTurns; userMovedToBound and groupMovedToBound, timed to the last answer; groupDelistedAll; runSuperseded; supersededRerouteTurns; supersededUserTurns; movedBeforeDrainTurns, unchanged (movedBefore, held, given and rerouted == 10,000); movedBeforeDrainWaitersTurns; movedBeforeAndAfterTurns; purgeWhileOwedTurns; lane429WhileOwed, timed with followedLaneMedian (BenchSync.swift:2900) while barrierUp and 10,000 items owed; and a 2-tokens-per-id commit (one group plus one waiter per id). Gate: best of 3 <= c2Budget at a 1-minute load <= 10.",
 "why": "Each new turn and each worst grouping needs a figure. Windows that end at O's removal or at the barrier's fall miss the drain turns and the relocated answers."
}

## checked_claims

- followBarrier = followOwed || !eventsAfterFollow.isEmpty (EngineFollow.swift:82-85, :97-99). A waiting .reroutes raises the barrier without raising followOwed, so publish's away filter (EngineDispatch.swift:1024-1027), recordDeferredVerdict's away (EngineFollow.swift:514) and bringInbound (:1003-1009) stay off. This is why a new event kind is the right vehicle.
- Reuse (S3-R16 item 3): continueMove drops all progress when its holder is gone (EngineMoves.swift:180-183) and skips items that are no longer on it (:205). Sites 1 and 3 remove the job (EngineJobs.swift:624; EngineDispatch.swift:1262). F-20 re-creates jobs[transfer] under the same TransferID, so neither a holder-keyed VisitRemainder nor a kept O fits. InboundMove needs one waitingTarget and drops otherwise (EngineFollow.swift:1220, :1251-1263). Deferring each item as a .join keeps the O(N) T21, present and spawn work at the site. MoveProgress and the drain's put-back are the right reuse.
- startMove makes partial progress in the site's own turn (EngineMoves.swift:141-166); design-minimal's refusal departs from it.
- The drain seeds drainIDsLeft from the follow's leftover ids or followIDsPerTurn (EngineFollow.swift:158, :203); joins spend nothing (:692-709); batches hold at most 512 events (:173).
- dropGroupMember (EngineJobs.swift:594-604) and releaseRunClaim (EngineRuns.swift:505-512) copy pending or claimed on every call; removeJob leaves run.outstanding untouched (EngineJobs.swift:409-448).
- pruneBoundContent keeps only the ids of jobs (EnginePresence.swift:74-90); reconcileIdle runs it after the commit (EngineDispatch.swift:1138) and after each drain turn (EngineFollow.swift:416); applies record reused ids as bound (EngineRuns.swift:376-381).
- answeredFromStore reads one id per await, but answerPresentMembers answers every present member in one turn (EnginePresence.swift:220, :279, :338-354); answerWaiterFromStore spawns one task per waiter (EnginePresence.swift:133-139).
- hasWork ignores eventsAfterFollow (EngineConditions.swift:8-11); gate() keeps non-user lanes waiting while conditions == nil (EngineDispatch.swift:498).
- relane returns at once for a failed job whose verdict waits (EngineJobs.swift:285-296), so removing one token at a time at the take-off is O(1) per token.
- Behind the barrier, .superseded and commits apply on arrival in both orders (EngineDispatch.swift:1089, :1205-1211). The take-off exists only for verdicts deferred while followOwed. Reached in both orders: N1-N5, N8-N10, N12 (with the added variants) and N15. Only in sweepFollowsFirst: N6, N7's disjunct, N13's multi-token path and N14. N11 as written runs only in sweepFollowsFirst but is reachable in both orders via site 1. N16 is superseded by C3.
- followAfterVerdict spends drainIDsLeft between the take-off and the re-route (EngineFollow.swift:351-356, :615-619, :591).
- materializeRun's limit counts run.outstanding keys (EngineRuns.swift:484).
- followedLane's walk over other jobs runs only while followOwed or a verdict waits; it has one caller (EngineFailures.swift:346, :721-838).
- invariantViolations has no production caller, so the step-15 recount costs no production turn.
- movedBeforeDrain's window ends at verdictOrBarrier (BenchSync.swift:3382, :3400-3402) and so covers the drain turns. Only follow follow-ups are held, so drain turns run free and the heartbeat covers them. timeCommit's window ends when O's job is gone (:3256).
- design-reuse.md and a judge-rr21 result are absent from .build-orchestrator/s3f-c20-analysis (listing at 08:15).

## concerns

- Per-turn work at 10,000 ids with design-minimal as written (all UNCONFIRMED). Site 1: about 3-6 ms converged; 4-8 ms with one user waiter per id (stub inserts, setInterest(nil) with B's index release of about 0.5-1 ms, 10,001 retireProgress); about 11 ms at the fit boundary. Site 3: about 2-5 ms (user shape 3-6 ms). Site 2: about 2-4 ms, plus the visit after the verdict (up to about 7-8 ms in the user shape) unless zeroed. Drain turns of at most 512 items: converged about 3 ms; divergent 3-6 ms; waiters 4-6 ms (each user join re-enqueues the queued job, EngineJobs.swift:270-273, :474-489); bound elsewhere with bindings kept 1-3 ms. T21 group and superseded run turns: 10-30 ms before C10/C11, under 3 ms after. Up to 511 uncharged joins can be added to any of these. Purge while owed: about 3-5 ms after C10, on top of withdrawPurged's existing walk. 429 while owed: about 1-3 ms (followedLane is O(E + items)).
- In the user-waiter shape, the site-1 turn is the tightest and has no fallback in design-minimal. Its own pass over 10,000 interests is O(N), and Phase 2 (C12) only splits answers. With many tokens per id, the site pass scales with items, not ids.
- integrate-c21 interaction 13 calls the binding prune 'one more job and one more read, a timing change', and interaction 18 assumes the spawns are bounded by RR-21's budget. Both cannot hold: without a prune guard, the spawns return in answerPresentMembers' single turn.
- At site 2 the verdict's O(I) answers are not charged; this predates RR-21. Add take-off fit re-routes of up to 512 and the turn can approach 10 ms (for example, J holds 9,500 un-moved interests answered by a 404 plus 500 fitting moved-before ids). Probe it with a movedBeforeFitBoundary case.
- Binding a .reroutes event by var in replay copies the item heap once per drain turn: O(items), plus one retain per heap-allocated AssetID in production. This is minor but belongs in the cost record.
- The take-off can arise only in sweepFollowsFirst, so every site-2 branch fails S3-R23 item 3's 'both orders' wording by construction. The answer for it is integrate-c21 open question 1.
- Bulk-releasing run claims at owing (design-fixer step 3) would lower materializeRun's outstanding count while items are owed (EngineRuns.swift:484) and materialize one fetch early. Keeping the claims, as design-minimal does, raises the count by one until the last owed item replays. Both are order-only changes and must be recorded under S3-R16 item 2.

## grafts

- design-fixer step 8 / N5: zero drainIDsLeft when the take-off does not fit (RR21-VERDICT-ZERO). This keeps followAfterVerdict's visit out of the O(N) take-off turn and makes step 12's disjunct removable.
- design-fixer step 5: count the publication's ids in site 1's fit test (captured.count + U > budget means owe). Here, locations.count + unbound <= inboundIDsNow.
- design-fixer step 18 (= integrate-c21 C10/C11): in-place dropGroupMember and releaseRunClaim, as named prerequisites of the drain's T21, run and purge arms.
- design-fixer step 20: per-turn in-actor timing through releaseOneHeldFollowOrDrainTurn, the cases supersededRerouteTurns, commitRerouteWaitersTurns and movedBeforeDrainWaitersTurns, and the timeCommit window that waits on jobExists(O) || barrierUp.
- design-fixer step 7: reuse removeInterest at the take-off rather than adding dropInterests, with its fallback note (line 274) as the trigger to bulk-drop.
- design-fixer's RR21-RUN test shape, to kill design-minimal's run-clause acceptance in both orders.
- Not grafted: the rerouteLayers chain, the global publication hold, the rerouteIDsPerTurn seam and a Hashable MoveItem withdrawn set. They add about 12 branches (N1-N28 against N1-N16) and are needed only if the correctness lens rules the publication window blocking. The bulk release of run claims (step 3 / N27) is optional once C11 lands.

## residual_risks

- Every millisecond figure above is an estimate, except the measured 9.86 ms commit binding and the 7.18-8.01 ms 512-move figure. The fit boundary, answerPresentMembers' turn and the per-turn copy costs need the probes before a ruling.
- Item C may lower the commit's turn enough to restore headroom for fitting re-routes. Until it is measured, charging the bound answers is the safe default.
- An owed event holds the barrier for about 20 drain turns, and meanwhile the watcher may stop when no job is left. Admissions and run settlement are later; this is timing only.
- The publication window (the RR-3/RR-16 family) is unaffected by these amendments; it belongs to the correctness lens.
- Retaining bindings while events wait may change which path some existing barrier tests take (store answer instead of a job). Order changes need one-to-one records under S3-R16 item 4.
- Before C10, the existing purge's withdrawPurged also does O(N^2) group copies. This predates RR-21 and should be recorded under S3-R19 item 1.

## unconfirmed

- Per-call cost of spawn (Task creation plus the tasks insert plus notifyObservers), and therefore the size of the answerPresentMembers turn at 10,000 waiters.
- Per-entry cost of the dictionary and set copies in dropGroupMember and releaseRunClaim at 10,000 entries, and thus whether the pre-C10/C11 drain turns exceed 10 ms.
- The about-11 ms fit-boundary estimate: linear scaling of the measured 9.86 ms commit, plus about 5-6 us per re-route (EngineMoves.swift:121).
- That the 'bound elsewhere' shape is reachable end to end in a test. The recording path (EngineRuns.swift:376-381) and the prune were read; no test was run.
- Whether a pruneBoundContent guard on eventsAfterFollow changes any existing test's outcome.
- Reachability of followedLane's binding sub-shape (e), as design-minimal also marks it.
- That the C2 reference set covers several tokens per id. S3-R22 to S3-R25 say 'any grouping'; the size of the site pass for 2 tokens per id is an estimate.
- design-reuse.md and the RR-21 judge's result were not available, so neither was compared.

## confidence

0.72
