# critic:rr21-answers

Read-only analysis for ruling S3-R26 (workflow wf_c114d84e-f12, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## verdict

unsound - in followVisitedFirst, today's at-once re-route gives visit-first's answers and the owed re-route does not, in three ways: (1) joining under the current copy reopens RR-14, so W is served Z's bytes where visit-first gives P's .integrityFailure; (2) without the hold, a destination can bind before the items replay, so a gate that closed before the site answers them .serverUnavailable where visit-first serves P's bytes; (3) the site's own reconcileIdle prunes the bindings that would answer owed present ids from the store, giving .offline or .serverUnavailable where visit-first gives success.

## refutations

- {
 "claim": "answer_equality_argument (3): \"Deciding T21 under the site's copy and joining under the current copy equals visit-first's re-route at the site followed by that apply's visit.\" Also events_between_turns' later-apply bullet and residual (5), which call a later apply 'RR-23's family (S3-R24 item 5)'.",
 "evidence": "This is RR-14's shape entering through the commit's door.\n\nSetup (the hop harness of EngineFollowBarrierPublicationHopTests):\n- held publications;\n- P scripted [.hold, .stage(wrongBytes)];\n- drainFollowUpsHeld (EngineFollow.swift:404-409);\n- followIDsPerTurn = 4, so inboundIDsNow = 2 (EngineMoves.swift:130-132).\n\nState under v3:\n- zz-o, a1, a2 and a3 map to content O; zz-p maps to P.\n- User waiters W1..W3 wait on a1..a3 (job O); Q waits on zz-p (job P).\n- Both publications are held in verifying.\n\nSequence:\n(1) v4 maps a1..a3 to P's content. Its visit passes O, which is verifying (rerouteOnVisit, EngineFollow.swift:864-865), so a1..a3 stay on O.\n(2) O commits, binding zz-o only.\n- Today: committed re-routes a1..a3 in this same turn (EngineDispatch.swift:1121-1124). In followVisitedFirst they join P, which is verifying, at once.\n- Design: 3 items > 2, so step 6 owes one `.reroutes`.\n(3) v5 maps a1..a3 to Z.\n- Visit-first, and today's followVisitedFirst: v5's visit meets P verifying and passes a1..a3, so they stay on P. bringInboundOntoPublications returns at its followOwed guard (:1023-1025).\n- Design: v5's follow sees no owed item, because they sit on no job. At the follow's end the drain replays the event. T21 under v4 lists the ids, so `listing` is nil, reroute reads v5 (EngineDispatch.swift:1151) and the items join a new job Z.\n(4) P's publication fails integrity: integrityFailed calls resolveAll(.failed(.integrityFailure)) (EngineFailures.swift:517). If the event still waits, the verdict is deferred behind it (EngineJobs.swift:612-614); either way W1..W3 are already on Z.\n\nExpected (visit-first, and today's followVisitedFirst): Q and W1..W3 get .integrityFailure, and Z never starts. This is exactly the RR-14 test's assertion (q, w, zStarts).\nDesign, both orders: Q gets .integrityFailure; W1..W3 are served Z's 48 bytes; zStarts = 1.\n\nVariants with the same result:\n- `.locked`, `.purgeRaced` or `.storageUnavailable` instead of integrity (resolveAll, EngineDispatch.swift:1242-1246);\n- site 3, where O's publication throws `.superseded` (step 8).\n\nWhy it is blocking:\n- It is S3-R16 1(a) and RR-14's class, which S3-R21 item 4 ruled blocking.\n- It is not RR-23 timing. A non-present id gets no answer at the site; visit-first answers it at P's verdict, which comes after v5. So v5 lands before both engines' answers, which is the case S3-R24 item 5 itself makes blocking.\n- The design's fallback hold does not help, because P captured its binding before the site.",
 "severity": "blocking",
 "fix": "Adopt design-fixer's chain for the replay (its steps 11 and 14).\n- While any `.reroutes` waits, adoptApplied appends a RerouteLayer {copy, publishing, waiting}.\n- At replay, each item's target is kept through every layer in which it was publishing, or had a verdict waiting that is not in the event's `preceding`. Otherwise it is re-targeted under that layer's copy.\n- The kept target is joined while its job is still at the attempt's end; otherwise the item re-routes under the current copy.\n- followedLane (step 14) counts items by the same walk.\n\nPin it as RR21-HOP:\n- this shape at sites 1 and 3, in both orders, at followIDsPerTurn = 4, with the integrity and `.locked` variants;\n- the drop-mutant (join under the current copy) must fail 2/2."
}
- {
 "claim": "fixer_design_assessment item 4 and residual (5): the publication window is 'RR-3/RR-16's family (one more request, the same answer while the origin answers alike)', so the global hold is only a fallback.",
 "evidence": "This counterexample needs no later apply and no gate change during the barrier.\n\nState under v3:\n- zz-o and a1..a3 map to O; zz-p maps to P.\n- W1..W3 wait on a1..a3 (job O); Q waits on zz-p.\n- Jobs E1..En hold other contents.\n\nSequence:\n(1) v4 maps a1..a3 to P's content. Its visit passes O, which is verifying.\n(2) E1..En fail with 5xx and the breaker opens.\n- P's transfer is still in flight and keeps going: breakerChanged stops nothing in flight (EngineFailures.swift:1001-1020).\n- An open breaker ignores the outcomes of transfers started before the trip (EngineSupport.swift:362-369), so P's later success does not close it.\n(3) O commits zz-o.\n- Today, followVisitedFirst: a1..a3 join P (downloading) at once (EngineDispatch.swift:1121-1124).\n- Design: the items are owed.\n(4) P's bytes arrive. publish captures `job.assets.sorted()` (EngineDispatch.swift:1049).\n- Today it captures {a1, a2, a3, zz-p}.\n- The design captures {zz-p}, because inboundBlocks has no `.reroutes` disjunct (:1159-1167). P commits; Q gets success.\n(5) Design, replay:\n- isBound(ai, P) is false, because the commit bound only zz-p (:1106), so a new job of P's content is created.\n- The drain's tail pumps. The gate hits the breaker: .block(.circuitOpen) (EngineDispatch.swift:490-536).\n- park calls failFast (:468-480), which answers W1..W3 .serverUnavailable(retryAfter: nil) (EngineJobs.swift:668-690).\n- With an offline reading the answer is .offline. With a throttle past interactiveMaxWait, user lanes get .serverUnavailable(retryAfter:).\n\nExpected: W1..W3 succeed with P's locations.\nDesign: an error.\n\nWhy it is blocking:\n- No second request reaches the origin, so this is not RR-16's accepted start-count family.\n- No gate changes during the barrier: the breaker opened before the site. So S3-R17 item 2 does not cover it, and it is S3-R16 1(a).\n- The window is wide in production. By the design's own admission-latency risk, a barrier-down commit owing 10,000 items holds the barrier for about 20 drain turns.",
 "severity": "blocking",
 "fix": "Adopt the global hold (design-minimal's own fallback, design-fixer's `inboundBlocks || reroutesOwed`).\n- No publication binds while a non-empty `.reroutes` waits.\n- The drain turn that empties the last one resumes the held waits in sorted order.\n- drainEverything's releaseInboundWaits (EngineShutdown.swift:117) covers shutdown.\n\nPin it as RR21-WINDOW-GATE: W1..W3 get P's locations and no fresh job of P's content is created. The hold's drop-mutant must fail 2/2."
}
- {
 "claim": "events_between_turns: \"Bindings forgotten (eviction, pruneBoundContent): the binding ledger is a cache, and a missing binding costs a store read before the transfer.\" integrate-c21.md:510 (interaction 13) repeats it as 'a timing change'.",
 "evidence": "State under v3:\n- zz-o and a1..a3 map to O; zz-d maps to D, which the store holds.\n- W1..W3 are waiters (any lane) on a1..a3 (job O).\n- One other job E is parked, so the watcher stays up.\n- There is no run, no ensure group with fetches left, and no presence read.\n- The breaker is open, or the conditions are offline, before the site.\n\nSequence:\n(1) v4 maps a1..a3 onto D's content.\n- They are content-changed adoption candidates (ApplyPlan.swift:60-72), so the store adopts zz-d's blob for them and reports them as reused (AssetStore+Apply.swift:42-44).\n- applied() binds them to D when the apply is trusted (EngineRuns.swift:374-381).\n- v4's visit passes O (verifying). The ids stay on O, so pruneBoundContent keeps their bindings (EnginePresence.swift:82-89).\n(2) O commits zz-o.\n- Today, in both orders: reroute checks isBound(ai, D) (EngineDispatch.swift:1164-1167), then answerPresent and answerWaiterFromStore (EnginePresence.swift:127-141). W1..W3 succeed from the store.\n- Design: the items are owed. The commit's own reconcileIdle (EngineDispatch.swift:1138) runs pruneBoundContent, which keeps only the ids of jobs (EnginePresence.swift:74-90). Owed ids sit on no job, so their bindings go. The same prune runs at site 3 (:1248) and at site 2 (EngineFollow.swift:416).\n(3) Replay:\n- isBound is false, so a new job D is created and the pump runs.\n- The gate gives circuitOpen, or laneVerdict gives offline. park calls failFast before any start.\n- So answeredFromStore, which only drive calls (EngineDispatch.swift:782), never runs.\n- W1..W3 get .serverUnavailable(retryAfter: nil) or .offline.\n\nExpected: success, served from the store.\nDesign: an error.\n\nWhy it is blocking:\n- Nothing lands between the site and the replay: the gate predates the site, and the prune is the site's own. So neither S3-R17 item 2 nor S3-R24 item 5 applies.\n- It is S3-R16 1(a), in both orders.\n- design-fixer's chain also reads isBound at replay (its step 11), so it has the same gap.",
 "severity": "blocking",
 "fix": "Make pruneBoundContent return early while eventsAfterFollow is non-empty (O(1)), the same way it keeps bindings while a run exists.\n- This covers `.reroutes` and the waiting `.join`s.\n- Forgets caused by inputs (eviction, a purge's dropBindings, quarantine) stay in the timing family.\n- Correct integrate-c21's interaction 13.\n\nPin it as RR21-PRESENT-PRUNE, once with the breaker open and once offline: W1..W3 are served from the store and no job of D is created. The retention's drop-mutant must fail 2/2."
}
- {
 "claim": "liveness_argument and events_between_turns: 'The spawn-nil branch clears the events' (EngineFollow.swift:390-399). Also 'drainEverything ... nils the run (:126)'.",
 "evidence": "integrate-c21's A11 removes that branch (integrate-c21.md:53, :500). The liveness argument still holds without it:\n- spawn returns nil only in shuttingDown, shutDown or degraded (EngineLifecycle.swift:52-58), and degraded is only set during start (:228, :260).\n- Every site guards isRunning: publish after store.publish (EngineDispatch.swift:1069), publicationFailed (:1193) and drainFollowUp (EngineFollow.swift:411). So no site can owe an event after shutdown begins.\n- performShutdown calls drainEverything at shutdown and again after each joined task (EngineLifecycle.swift:498, :506).\n- drainEverything resumes the inbound waits (EngineShutdown.swift:117), clears the events (:118), answers waiters and groups .shutDown, and nils the run at :130 (not :126).",
 "severity": "minor",
 "fix": "Cite drainEverything, spawn's nil cases and the isRunning guards instead of the spawn-nil branch, and correct :126 to :130."
}
- {
 "claim": "answer_equality_argument (4): at site 2, 'only the order of joins changes'.",
 "evidence": "Consider the case where followAfterVerdict's visit does not fit and supersedes J, because every remaining id moves (EngineMoves.swift:145).\n- Today: rerouteMovedBefore (EngineFollow.swift:619) joins the take-off items to J in the verdict's turn. At the rest's end, continueMove relanes J instead of removing it (EngineMoves.swift:218-224).\n- Design: the whole take-off set waits behind the rest (step 10). J is removed at the rest's end, and the replay creates a fresh job of J's content, with a new epoch and without J's retry deadline or attempt history.\n- The answers agree while the origin answers alike; the start count and the retry timing differ.",
 "severity": "minor",
 "fix": "Either record this as an S3-R16 item 2 residual with its probe, or keep J alive while a `.reroutes` from J waits."
}

## amendments

- {
 "step": "mechanism 2 and 11 (the `.reroutes` replay), with 14 (followedLane)",
 "change": "Replace 'T21 under the site's copy, the join under the current copy' with design-fixer's layered chain:\n- While any `.reroutes` waits, adoptApplied appends a layer {copy, publishing = in-flight jobs that are verifying or committing, waiting = verdictsAfterFollow plus the waiting .spaceFailure transfers}.\n- At replay, the target is kept or re-targeted layer by layer, honouring the event's `preceding`.\n- The item joins the kept target while its job is at the attempt's end, and otherwise re-routes under the current copy.\n- followedLane counts by the same walk.",
 "why": "Refutation 1: RR-14 through the commit and .superseded doors (S3-R21 item 4)."
}
- {
 "step": "fixer_design_assessment item 4 and the risks' 'Fallback, a global hold'",
 "change": "Make the hold mandatory:\n- inboundBlocks (EngineFollow.swift:1159-1167) is also true while a non-empty `.reroutes` waits.\n- The drain turn that empties the last one resumes the held waits in sorted order.\n- Shutdown is covered by releaseInboundWaits (EngineShutdown.swift:117).\n- The stranded clause (EngineCommands.swift:2063-2067) pins liveness.",
 "why": "Refutation 2: when a gate that closed before the site refuses the second request, the window is not RR-16's start-count family."
}
- {
 "step": "events_between_turns 'Bindings forgotten', and EnginePresence.swift:74-90 (pruneBoundContent); integrate-c21 interaction 13",
 "change": "Add `self.state.eventsAfterFollow.isEmpty` to pruneBoundContent's first guard, so every binding is kept while barrier events wait, as while a run exists. Reword interaction 13 as an answer difference, not a timing change.",
 "why": "Refutation 3: a parked job is answered by failFast before any pre-transfer read (EngineDispatch.swift:468-480, :782)."
}
- {
 "step": "answer_equality_argument (3) and (5), the events_between_turns later-apply bullet, and the invariants bullet 'no job ... can publish before them'",
 "change": "Apply S3-R24 item 5 to the caller's answer:\n- An id not answered present at the site is answered at its target's commit or verdict.\n- So a later apply that lands before that verdict is 'before both answers', and is blocking when the answers differ.\n\nAlso state that a successful attempt's publication, its commit and .superseded apply on arrival behind the barrier (EngineDispatch.swift:1076-1084). The bullet therefore holds only with the hold.",
 "why": "As written, the argument classes refutation 1 as RR-23 timing and claims a guarantee the barrier does not give."
}
- {
 "step": "liveness_argument 'Shutdown and degrade' and events_between_turns 'Shutdown or degrade'",
 "change": "Cite these instead of the spawn-nil branch that A11 removes:\n- drainEverything (EngineShutdown.swift:117-118, run nil at :130), called at EngineLifecycle.swift:498 and :506;\n- spawn returning nil only in shuttingDown, shutDown or degraded (EngineLifecycle.swift:52-58);\n- the isRunning guards (EngineDispatch.swift:1069, :1193; EngineFollow.swift:411).",
 "why": "Refutation 4; integrate-c21.md:500."
}
- {
 "step": "mechanism 9 (dropInterests)",
 "change": "Set heldLane as dropInterest does today, from the lane before the last token's removal (EngineJobs.swift:347-356). Otherwise, record the highest-lane difference as an S3-R16 item 2 residual.",
 "why": "One `before` for the whole list sets a claim-held job's lane (EngineState.swift:762) to the highest removed lane. claimRetries reads that lane (EngineFailures.swift:318-323)."
}
- {
 "step": "mechanism 15 (followBarrierViolations, the `.reroutes` arm)",
 "change": "Make the 'not still on jobs[owed.from]' check per (token, asset), as integrate-c21.md:498 specifies.",
 "why": "A replayed F-20 item re-creates jobs[owed.from] with its token while that token's other items in the same event still wait, so a per-token check fires falsely."
}
- {
 "step": "mechanism 16 (pins)",
 "change": "Add three tests:\n- RR21-HOP: refutation 1 at sites 1 and 3, both orders, followIDsPerTurn = 4, with integrity and .locked variants. Q and W1..W3 get P's failure; zStarts = 0.\n- RR21-WINDOW-GATE: refutation 2. W1..W3 get P's locations, and no fresh job of P's content is created.\n- RR21-PRESENT-PRUNE: refutation 3, with the breaker open and with offline. W1..W3 are served from the store.\nEach fix's drop-mutant must fail 2/2.",
 "why": "S3-R23 item 3 and S3-R16 1(e)."
}
- {
 "step": "answer_equality_argument (4), site 2",
 "change": "Record the superseding-rest case (fresh job versus J kept) as a residual, or keep J alive while a `.reroutes` from J waits.",
 "why": "Refutation 5."
}

## checked_claims

- Withdrawal (EngineCommands.swift:176-185): the caller is answered .cancelled at once, and the `.removal` waits behind the barrier. The owed re-route updates waiter.transfer (EngineDispatch.swift:1170-1174), and replayRemoval reads it at replay (EngineFollow.swift:734-741). T21, or answerWaiterFromStore, resumes a nil continuation, so the caller is never answered twice. Holds.
- Group release: reroute's group guard (EngineDispatch.swift:1176-1179), dropGroupMember's guard and answerPresent make the item a no-op. Holds.
- Run end and claims: releaseRunClaim's guard (EngineRuns.swift:505-512) and reroute's run guard (:1181-1184) make run items no-ops. checkRunSettled's `!followBarrier` guard (EngineRuns.swift:576) keeps the run from settling while items are owed. Holds.
- Purge (step 13): with the early return changed to eventsAfterFollow.isEmpty, the arm removes non-user, non-waiter items, including run items, as withdrawPurged does. User items replay. Holds.
- Shutdown: drainEverything answers every owed owner .shutDown and clears the events. No site can owe after isRunning drops. Holds without the spawn-nil branch.
- R-SYN-12: resolveAll still calls removeJob (EngineJobs.swift:624) before publishTerminal (:625). Step 7's filter gives the same assetAvailable broadcasts in the same order (EngineJobs.swift:634-638). Holds.
- F-20: holdForManifest runs in the site's turn (the step 6 closure, step 8's helper). The hold is keyed by TransferID, so it covers the fresh job a replay creates. Holds.
- R-SYN-5: replays only create or join jobs, and pump admits them on the live gates (EngineDispatch.swift:490-536). A 429 throttles on arrival, and step 14 counts owed items for the backoff lane. No attempt-cap breach; refutation 1's extra Z start is a start count.
- A destination's failure (404, 5xx, integrity, ENOSPC) that arrives while the event waits is deferred behind it (EngineJobs.swift:612-614; EngineFollow.swift:449-469). The replay joins first and the verdict then answers the joined items, which equals visit-first. Without a later apply this is not a counterexample.
- A 429 on the destination: its park and fail-fast answers are deferred behind the event, so they answer the joined items. Holds.
- A later apply that leaves the target queued, blocked or downloading: visit-first's visit moves the item, and the replay under the current copy gives the same target. Holds.
- Site 2's targets are J's content (EngineFollow.swift:543-548, :572-576), which cannot start or publish behind the barrier (EngineDispatch.swift:95-108). So refutations 1 and 2 do not reach site 2; refutation 3 does (drainFollowUp's reconcileIdle, EngineFollow.swift:416).
- Liveness: oweReroutes schedules a drain, and each turn that heads the event pops at least 1 item. A `left != nil` from continueReroutes implies drainIDsLeft == 0. Site 2's all-or-nothing rest replays the next turn with a full budget. A purge-emptied event replays as a no-op. Holds.
- Fit case at site 1: re-routes in the resolveAll closure after removeJob reach the same run, group and T21 states. recordRunOutcome wipes outstanding[O] (EngineRuns.swift:519), and releaseRunClaim is then a guarded no-op. Order only.
- RE-S14: the commit's locations go to the job's interests; owed ids are unbound by construction. Holds.

## concerns

- hasWork ignores eventsAfterFollow (EngineConditions.swift:8-11). With no other work, the site's reconcileIdle tears down the watcher and sets conditions to nil (:15-24) while items are owed. Jobs created at replay restart the watcher; non-user lanes and the Apple tier wait for the first reading (EngineDispatch.swift:497-499). This is timing only, but under refutation 3 the park that answers can come from that first reading.
- materializeRun runs in pump before the barrier check (EngineDispatch.swift:93-95). recordRunOutcome has wiped outstanding[O] (EngineRuns.swift:519), so while run items are owed the run can materialise past its limit (EngineRuns.swift:481-484). Order and timing only. design-fixer's in-place claim release has the same window.
- With the mandatory hold, every publication waits while any `.reroutes` waits, not only those of targets: about 20 drain turns at 10,000 items. That means commit latency and verifying bytes held longer. The ledger counts them, so R-SYN-11 holds; record it as timing.
- The design's own admission-latency risk (the barrier up for about 20 drain turns at 10,000 items) is what widens refutations 1 and 2 in production. Any apply or attempt end in those turns falls inside the window.
- With the chain, followedLane costs O(items x (1 + layers)) per 429. It needs a BenchSync figure (C2).

## grafts

- From design-fixer:
- the RerouteLayer chain (`rerouteListing`, with `preceding`), for refutation 1;
- the global hold (`inboundBlocks || reroutesOwed`, resumed by reroutesSettled), for refutation 2.
- New, needed by design-minimal, design-fixer and integrate-c21 alike: pruneBoundContent keeps every binding while eventsAfterFollow is non-empty, for refutation 3.
- From integrate-c21:
- A11 with the shutdown citation (integrate-c21.md:500);
- the per-(token, asset) followBarrierViolations predicate (:498).
- Keep from design-minimal:
- all-or-nothing site budgets counted per interest;
- the purge arm (step 13);
- site 2 prepended with endsDrainBatch;
- the publishTerminal filter (step 7);
- followedLane counting items by their replay destination (step 14, extended to the chain).

## residual_risks

- Pre-existing, in today's sweepFollowsFirst: behind the barrier, a commit's re-routed joins wait as `.join` events.
- replayJoin re-routes a listed join under the current copy (EngineFollow.swift:704-707).
- bringInboundOntoPublications and findInbound walk only jobs (:1023-1040, :1051).
- So refutation 1's shape with the follow held probably serves Z today too: RR-14's class through waiting joins, including requests that join behind the barrier.
- Not probed. Put it to the orchestrator under S3-R19 item 1.
- design-minimal's 'already open today' relies on this gap. The chain should cover `.join` events too.
- The same prune also reaches today's waiting `.join`s that a later apply re-routes onto bound content: pre-existing and not probed. The eventsAfterFollow guard in amendment 3 covers it.
- Inputs that land between the site's present answer and the replay still change which path answers: eviction, a purge's dropBindings, a gate change. This is timing or R1 (S3-R24 item 5, S3-R17 item 2).
- Without the hold and with open gates, a destination that commits between owed turns costs one more request (RR-16's family).
- Site 2's superseding-rest case (refutation 5): a fresh job instead of J kept, which changes the start count and the retry timing.
- C2 for the chain's layer capture, its per-item walk and the hold's resume loop is unmeasured.

## unconfirmed

- No test, probe or build was run, because the task is read-only. The three counterexamples are traced in the code at 8e1fb24 against design-minimal.md's text. The design is not implemented, so each needs its probe once it is.
- Refutation 1 assumes the hop harness can hold O and P in verifying together at followIDsPerTurn = 4: held publications, P scripted [.hold, .stage(wrongBytes)], and drainFollowUpsHeld (EngineFollow.swift:404-409, :1388-1397). Not run.
- Refutation 2 assumes a harness can open the breaker with scripted 5xx while P's transfer is held. That an open breaker ignores P's success was read at EngineSupport.swift:362-369, not run.
- Refutation 3 assumes the store reports a1..a3 as reused when v4 maps them onto zz-d's on-disk blob with the same extension (ApplyPlan.swift:60-72; AssetStore+Apply.swift:42-44), and that the apply is trusted (EngineRuns.swift:374). Read, not run.
- The pre-existing sweep-first gap through waiting joins is inferred from replayJoin and the apply-time walk; not probed.
- Whether refutation 2 falls under S3-R16 1(a) or RR-16's accepted family is the orchestrator's call. By S3-R17 item 2's wording it is 1(a), because no gate changes during the barrier.
- design-reuse.md and judge-rr21.md were not in .build-orchestrator/s3f-c20-analysis/ when checked.

## confidence

0.8
