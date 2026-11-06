# design:minimal

Read-only analysis for ruling S3-R26 (workflow wf_6b2553de-48c, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## angle

First principles, fewest new states. A re-route that a site cannot finish in its own turn is a waiting join whose target is read late. The follow barrier (F-28) already orders waiting joins against every later input. So the design adds one kind of waiting event and nothing else, and the waiting event itself serves as the limbo index.

Can the re-routes leave earlier? No, at all three sites:
- The commit's ids and the `.superseded` ids are answered by the publication's outcome; a visit passes a publishing job (rerouteOnVisit, EngineFollow.swift:860-877).
- The moved-before ids must be off J before its verdict (the doc above takeOffMovedBefore, EngineFollow.swift:551).
- Letting them leave at J's deferral as owed moves off J was rejected for two reasons. The later move back onto J goes through deferBehindVerdict, which is O(E) a call (EngineFollow.swift:964-978), so the whole set costs O(N·E). And a waiting `.join` for such an id, replayed before J's verdict, would be answered by that verdict.

Does batching by destination help? Only for the converged one-token shape. The divergent shape and the one-waiter-per-id shape still need a per-turn bound, so batching adds a branch and removes none.

The choice:
- At each site, all or nothing: re-route everything in the site's turn when it fits (as startMove does, EngineMoves.swift:141-143), else re-route nothing there and owe all of it.
- In the drain, a budget counted per interest.

This keeps small shapes in today's single turn with the barrier untouched. It also keeps re-routes out of the large sites' turns, which in the one-waiter-per-id shape already spend a few ms on their own O(N) pass.

## design_summary

Each site builds, in one unsorted O(N) pass, the (id, token) items it would re-route today, plus a lane/kind stub per interest. It takes those interests off the job exactly as it does now.
- **Small sets.** When the items fit the site's budget (inboundIDsNow at the commit and at `.superseded`, drainIDsLeft in the drain's verdict replay), the site re-routes them all in its turn, as today. Only the order changes.
- **Large sets.** Otherwise the site re-routes none of them and queues them whole as one `EventAfterFollow.reroutes(OwedReroutes)`, at exactly the point where the loop runs today:
  - At the commit and at `.superseded`, the event is appended with the publication end's stamp. That raises the barrier and schedules a drain turn.
  - In `replayVerdict` and the `.spaceFailure` replay, the event is prepended at the verdict's position with the verdict's stamp, and the drain's batch ends there.

The drain replays the event within drainIDsLeft, the per-turn budget the follow and the drain share:
- per interest, in (asset, token) heap order (MoveProgress);
- through the existing `reroute`, deciding T21 under the site's copy and making the join under the current copy;
- putting the rest back at the head with the same stamp.

While the event waits, the existing barrier keeps every later join, waiter withdrawal and in-flight exit verdict behind it, and keeps any job from starting. Three inputs that apply at arrival read the event:
- a purge prunes it, as it prunes waiting joins;
- a 429's `followedLane` counts its items;
- the invariants accept its items.

What it adds: one event case and one value type. What it does not add: no EngineState field, index, seam, shutdown code or publication hold.

What it removes: `rerouteMovedBefore`, committed's deferred list and its in-loop re-route with transferID formatting, and the sorts at all three sites.

## mechanism

- 1. EngineMoves.swift, after VisitRemainder (:91-106): add `struct OwedReroutes { let from: TransferID; let copy: ValidatedManifest; let interests: [InterestToken: JobInterest]; var items: MoveProgress }`. `copy` is the site's copy. `interests` holds stubs `JobInterest(lane:kind:assets: [])`, as continueMove's stub at :202, so no id set is shared or copied. `items` reuses MoveProgress (`supersedes: false`; `lane` unused) for a deterministic (asset, token) pop order without a sort; its heapify is at :30-38. Add `MoveProgress.removeAll(where:)`: a filter plus the init's heapify.
- 2. EngineMoves.swift, beside continueMove (:179-226): add `func continueReroutes(_ owed: inout OwedReroutes, budget: Int) -> Int` = `var spent = 0; while spent < budget, let item = owed.items.popFirst() { spent += 1; guard let stub = owed.interests[item.token] else { continue }; reroute(item.token, interest: stub, asset: item.asset, from: owed.from, listing: owed.copy.entry(for: item.asset) == nil ? owed.copy : nil) }; return spent`. The budget counts interests, not ids: owed items are on no job, so continueMove's rule that an id leaves its job whole in one turn (:189-196) is not needed, and every grouping, including many tokens per id, stays bounded. In the site's own turn, `listing` equals the copy reroute reads anyway (EngineDispatch.swift:1151), so the fit case is today's re-route. The nil `stub` case is structural, covered by the clause in step 15.
- 3. EngineMoves.swift: add `func startReroutes(_ owed: OwedReroutes, budget: Int) -> (spent: Int, rest: OwedReroutes?)`, mirroring startMove's fit guard (:141-143): `guard owed.items.count > budget else { var all = owed; return (continueReroutes(&all, budget: budget), nil) }; return (0, owed)`. A set that does not fit makes no re-route in this turn.
- 4. EngineFollow.swift, next to deferToFollow (:233-236): add `func oweReroutes(_ owed: OwedReroutes) { deferToFollow(.reroutes(owed)); scheduleDrainFollowUp(); notifyObservers() }`. worldStamp (:250-264) appends the publication end's view, so the stamps clause holds. scheduleDrainFollowUp (:379-400) stays private: oweReroutes lives in the same file. A drain turn that runs while a follow is owed is a no-op (:189), and the follow's end drains the event.
- 5. EngineFollow.swift:1405-1444: add `case reroutes(OwedReroutes)` with `endsDrainBatch` false (:1436-1443). Add the arm to followBarrierViolations' exhaustive switch (EngineCommands.swift:2016-2030). laneEventsWaiting's `default` (EngineFailures.swift:845-863) is unchanged. OwedReroutes, MoveProgress, MoveItem and JobInterest must be Sendable, because the enum is (:1405).
- 6. EngineDispatch.swift:1100-1139, committed. Replace the sorted loop (:1109-1128), the deferred list (:1107), the in-loop re-route with its transferID formatting (:1121-1124) and the closure loop (:1133-1135) with one pass over `job.interests`. For each interest: `for asset in interest.assets where locations[asset] == nil` append `MoveItem(asset:token:)`, and set `refused` once `captured.contains(asset) && (copy.entry(for: asset).map { sameTransfer($0, job.entry) } ?? false)`. sameTransfer (EngineJobs.swift:210-219) is the same test as `transferID == transfer` without formatting. An interest with any unbound id gets a stub. A wholly unbound interest gets `setInterest(nil, for:)`, as :1115-1116; a partly unbound one gets `subtractAssets(Set(unbound), for:)` instead of building `bound`. Then `resolveAll(transfer, with: .committed(locations)) { if refused { holdForManifest(transfer) }; if let rest = startReroutes(owed, budget: inboundIDsNow).rest { oweReroutes(rest) } }`. The closure runs after removeJob (EngineJobs.swift:624-626), as the deferred ids need; the moved-away ids now also re-route after the job's answers, which changes order only. pump and reconcileIdle stay (:1137-1138).
- 7. EngineJobs.swift:631-645, publishTerminal: for `.committed`, iterate `job.assets.filter { locations[$0] != nil }.sorted()`, not the sort of every id at :635. The broadcasts are the same, in the same order, and 10,000 unbound ids are no longer sorted in the commit's turn (user lanes are above bulk, :632).
- 8. EngineDispatch.swift:1205-1211: `.superseded` calls a new `supersedePublication(transfer)`. supersede's prefix (:1260-1265: copy, removeAllInterests, removeJob, the F-20 predicate and holdForManifest) moves into a helper that both functions call. supersedePublication builds items and stubs from every interest, calls `startReroutes(budget: inboundIDsNow)`, owes any rest, then calls `checkRunSettled()` and `pump()` as :1277-1278. supersede itself, with its sorted loop (:1266-1273), stays for move (EngineFollow.swift:941).
- 9. EngineFollow.swift:551-568, takeOffMovedBefore, now returns `OwedReroutes?`. `held` (:552) and `assets.subtract(held)` (:557) are unchanged. One unsorted pass over `job.interests` builds items and stubs; the sorts at :558-559 go. A partly held interest gets `subtractAssets`. Wholly held tokens are collected and removed by `dropInterests(_:from:)` in EngineJobs.swift, which generalises dropInterest (:346-366) to a token list: one `before`; `setInterest(nil)` and the `run.held` check per token; one tail (heldLane, then claimHeld or retire when emptied, else relane); one notifyObservers. dropInterest calls it with one token. `copy` is `state.applied`, the copy rerouteMovedBefore reads today in the same turn.
- 10. EngineFollow.swift:607-620 (replayVerdict) and :346-356 (the `.spaceFailure` replay): replace `rerouteMovedBefore(off, from:)` (:619, :356) with `return rerouteTakenOff(off)`, which is `guard let off else { return nil }; let made = startReroutes(off, budget: state.drainIDsLeft); state.drainIDsLeft -= made.spent; return made.rest.map { .reroutes($0) }`. It runs after giveVerdict or decideSpaceFailure and followAfterVerdict, as today. A visit rest left by followAfterVerdict has already spent the turn's ids, so the whole set waits behind that rest. Delete rerouteMovedBefore (:570-576).
- 11. EngineFollow.swift:344-376, replay, now returns `EventAfterFollow?` (nil in every existing arm, except the two arms changed in step 10). New arm `case .reroutes(var owed): state.drainIDsLeft -= continueReroutes(&owed, budget: state.drainIDsLeft); return owed.items.isDone ? nil : .reroutes(owed)`.
- 12. EngineFollow.swift:204-216, drainEventsAfterFollow: `let left = withReading(stamp) { replay(event) }`; the break condition becomes `left != nil || followMoving != nil || drainIDsLeft <= 0`; the re-insert (:212-214) puts `(left, stamp)` ahead of `batch[(offset + 1)...]`. The tail (:218-229) is unchanged: followMoving leads to scheduleFollowFollowUp, waiting events to scheduleDrainFollowUp, and an empty queue to checkRunSettled, pump and endWorldHistory.
- 13. EngineCommands.swift:1049-1073, withdrawPurgedJoins. Change the early return (:1050-1052) to `eventsAfterFollow.isEmpty`. Add a `.reroutes` arm: remove every item whose stub is below `.userInitiated`, is not `.waiter`, and whose id isPurged. For a removed group item call `dropGroupMember(token, asset:, from: owed.from)`; for a system item set `heals[asset] = nil`; for a run item do nothing, as withdrawPurged does at :1022-1030. Write the event back. An emptied event stays and replays as a no-op, as withdrawn joins stay. The purge has already called settleRun (:973).
- 14. EngineFailures.swift:721-838, followedLane. In the events loop (:821-836), add a `.reroutes` arm. An item counts when: its token is not withdrawn; `owed.copy.entry(for: asset) != nil`; the current `copy.entry(for: asset)` is sameTransfer with job.entry; `state.boundContent[asset] != job.transfer` (EnginePresence.swift:9-11, no formatting); and `stillWants(token:asset:kind:transfer: owed.from)`, with stillWants (EngineFollow.swift:713-728) refactored to take fields so replayJoin's call is unchanged. A counted item calls `raise(stub.lane)`, and the loop stops at `.userInitiated`, as the joins loop does.
- 15. EngineCommands.swift, invariantViolations: build once `owed: [InterestToken: [AssetID: TransferID]]` from the waiting `.reroutes` items. The waiter clause (:1707-1712), the group clause (:1777-1783) and the run clause (:1812-1817) accept an interest that an owed item from that transfer carries, as they accept a waiting join. followBarrierViolations (:2003-2069), `.reroutes` arm: every item's token has a stub, and no item's interest is still on `jobs[owed.from]` or registered in joinsAfterFollow (one place per interest).
- 16. Pins. Tests at followIDsPerTurn = 4 hold drain turns with runOneHeldTurn (EngineFollowBarrierDrainBoundTests.swift:50-62) and read owed counts with readForTests. BenchSync: in timeCommit, end the window (BenchSync.swift:3256-3259) only when O's job is gone and `barrierUp` is false, and read `run.rerouted` (:3265-3267) after that. Add cases for the divergent and user-waiter shapes at each site, the `.superseded` converged and user shapes, and a 429 while 10,000 items are owed.

## invariants

- One place per interest: every (token, id) interest of a live owner is in exactly one of three places: a job's interests, a waiting `.join` (joinsAfterFollow), or an item of a waiting `.reroutes` from the transfer the owner names (waiter.transfer, group.pending[id], run.outstanding). Checked by the extended waiter, group and run clauses and by the new followBarrierViolations arm.
- A waiting `.reroutes` keeps the barrier up (followBarrier, EngineFollow.swift:97-99). While it waits there is no admission (pump, EngineDispatch.swift:95-108), no run settles (EngineRuns.swift:576), every in-flight exit is deferred (exitDefers covers downloading, verifying and committing, EngineFollow.swift:473-480), and every join is deferred (EngineJobs.swift:110-116). So no job the owed re-routes create or join can start, fail, throttle or publish before them.
- Events wait only while a follow is owed, a drain is scheduled or the drain is running (EngineCommands.swift:2006-2008). oweReroutes schedules a drain turn. An event prepended inside the drain is covered by the tail (EngineFollow.swift:219-225).
- C2 / R-SYN-11: a site's turn re-routes only when everything fits its budget. A drain turn's `.reroutes` replays, verdict visits and take-off re-routes together spend at most drainIDsLeft, counted per interest, with followIDsPerTurn seeded from the follow's last turn (:203).
- R-SYN-5: a 429's backoff lane (followedLane, read at EngineFailures.swift:346) counts every owed interest that its replay will join to the 429'd job.
- F-20: the hold for a refused id is set in the site's turn (as EngineDispatch.swift:1130-1132 and :1263-1265). T21 (`.notFound`, member drop, heal forgotten) applies only to an id the site's copy does not list.
- R-CAR-4: owed interests keep no job alive. Jobs are created only at replay, with their interest. The left job is removed (sites 1 and 3) or retired or kept exactly as today (site 2).
- One lane per token: the stubs carry the registered lane and kind (EngineMoves.swift:202), so every re-route passes on the token's one lane.
- Decision instants: each owed event carries its site's stamp, which stays in worldHistory while it waits (EngineCommands.swift:2034-2036), and every replay runs under it (withReading, EngineFollow.swift:268-282). Jobs created at replay therefore take their places from the site's instant.
- joinsAfterFollow stays exactly the waiting `.join` events; owed items are never registered there.
- A site whose re-routes fit leaves no event and does not raise the barrier.

## events_between_turns

- A later manifest apply: its follow runs first, because the drain refuses while followOwed (EngineFollow.swift:189). Owed items sit on no job, so its visits do not touch them. At replay, T21 is decided under the site's copy and the join under the current copy, which equals the visit that would have moved the joined interest. If the apply lands between the visit-first answer, given at the site, and ours, given at the drain, the content answered can differ (for example a bound id answered present). That is RR-23's family (S3-R24 item 5).
- A new request (waiter, prefetch, ensure, run): its join is deferred as a `.join` after the owed event (EngineJobs.swift:110-116), so it is replayed after the re-routes, as visit-first joined after them.
- A waiter's cancel: the caller is answered at once, and `.removal(token, waiter.transfer)` is deferred after the event (EngineCommands.swift:176-183). The owed re-route updates waiter.transfer (EngineDispatch.swift:1170-1174), and replayRemoval removes the interest from the job the waiter names at replay (EngineFollow.swift:734-741). If T21 fires first, it removes the record and resumes a nil continuation, so the caller is not answered twice.
- A group's release (applied at arrival, groups.removeValue at EngineCommands.swift:359): reroute's guards (EngineDispatch.swift:1175-1178), dropGroupMember's guard and answerPresent's guard make the item a no-op. This equals removing a joined interest, with possibly one request fewer. followedLane's stillWants skips the item, and the group clause iterates only live groups.
- The run's end or a claim's end: releaseRunClaim's guard (EngineRuns.swift:505-508) and reroute's run guard (EngineDispatch.swift:1180-1183) make run items no-ops. The run clause applies only while the run is transferring and unsettled.
- A purge: performPurge calls settleRun and then withdrawPurged (EngineCommands.swift:972-974). The new `.reroutes` arm of withdrawPurgedJoins prunes non-user, non-waiter items in purged ids (member dropped, heal forgotten), as visit-first's purge withdrew them from the jobs they had joined; this is PROBE-C13-PURGE-JOIN's class. User items stay and re-queue. dropBindings sends formerly bound items down the job path, which is the timing family.
- A 429 on an in-flight job X that owed items will join: the throttle applies at arrival, read on followedLane, which now counts those items (step 14). Its park and fail-fast answers are deferred as a `.throttle` verdict after the event.
- Any other exit of an in-flight destination (404, 5xx, time-out, ENOSPC, integrity): defersFailure defers it (EngineFollow.swift:449-469) after the owed event, and its verdict then answers the re-routed interests, as visit-first's did.
- An in-flight destination's attempt succeeds and its publication starts between turns: the publication captures the ids it holds now (EngineDispatch.swift:1049), so the owed items join after the capture. Its commit then re-routes them to a fresh job of the same content, which costs one more request; the answer is the same while the origin answers alike. That is RR-3/RR-16's family, already open today for a barrier-up commit's waiting joins. The fallback is a global publication hold (see risks).
- A destination's commit, `.superseded` or ENOENT re-queue between turns. Commit: owed items for its content were not captured, so they are not bound and join a fresh job (same residual as above). `.superseded`: F-20's hold is keyed by TransferID, so it covers the fresh job of the same content. ENOENT: RR-4's place.
- Another commit or `.superseded` with re-routes of its own: if they fit, its joins are deferred as `.join` events (the barrier is up); if not, a second `.reroutes` event is appended. Arrival order is kept.
- A conditions edge, readmit, unblock, retryDue, throttle-answers turn or space sweep: each is deferred as its own event after the owed one (endsDrainBatch), and is applied under its own reading to the jobs the re-routes created. The owed event replays under the site's reading.
- A free-space read or freed bytes: ledger inputs, applied at arrival (S3-R11 R1); no interaction.
- A catch-up (the store holds a newer manifest): its end releases holds when no follow is owed (EngineCatchUp.swift:255-266). Owed items still mapped to the left content replay under the caught-up copy, which equals visit-first's held fresh job being visited and released.
- Shutdown or degrade: drainEverything answers every waiter (EngineShutdown.swift:52-60) and group (:68-73), clears eventsAfterFollow (:118) and nils the run (:126). scheduleDrainFollowUp's spawn-nil branch (EngineFollow.swift:390-399) and drainFollowUp's isRunning guard (:403-418) stop the replays. No new code is needed.
- Bindings forgotten (eviction, pruneBoundContent): the binding ledger is a cache, and a missing binding costs a store read before the transfer (EnginePresence.swift:57-68).
- The follow's own rest after a verdict (site 2): the prepended event waits for followMoving, and the drain resumes with it first.
- A heal registered for an owed system item's id: deduplicated against heals[asset], which stays set until replay, as with a waiting `.join` today (UNCONFIRMED).

## answer_equality_argument

Claim: every interest gets visit-first's answer in both LaneDropVisit orders. The exceptions are the differences S3-R16 item 2 allows (order, place, ticket, timing, start count while the origin answers alike), in the RR-3, RR-16 and RR-23 families.

**(1) Small shapes are today's single turn.** The re-routes are the same `reroute` calls under the same copy. Two things change: the order (heap order instead of token-major), and the moved-away ids at the commit now re-route after the job's answers rather than before. Neither changes any answer:
- A moved-away id's target is another content or T21, independent of the left job's existence.
- Run claims end in the same state: deliver's recordRunOutcome clears `outstanding[F]` (EngineRuns.swift:519), and releaseRunClaim is then a guarded no-op (:505-508).
- Groups' pending entries are set by the re-route either way.

**(2) Large shapes: the owed event is a compressed run of waiting joins, placed where the loop runs today.**
- At the commit and at `.superseded`, it is appended at the publication end with that instant's stamp. In the drain, it is prepended at the verdict's position with the verdict's stamp, and the batch ends there.
- Its replay runs under that stamp (withReading), so jobs it creates take the site's instant as their place.
- It keeps the barrier up. So every input that reads or decides on the destination jobs waits behind it in arrival order: joins (EngineJobs.swift:110-116), waiter withdrawals (EngineCommands.swift:176-183), every in-flight exit (EngineFollow.swift:449-480), conditions, readmits, unblocks, retryDue, throttle answers and space sweeps.
- No job can start behind the barrier (EngineDispatch.swift:95-108). So a job created or joined by owed re-routes cannot fail, throttle or publish before them.

Under visit-first, the same re-routes ran at the site's instant, and those later inputs met the jobs they had joined. That is the state the drain reaches before replaying those inputs.

**(3) Inputs applied at arrival behind the barrier are mirrored.**
- A purge prunes non-user owed items, as it withdrew them from the jobs they had joined.
- A group release, run end or claim end makes the items no-ops through reroute's own guards. That equals removing a joined interest; visit-first might have spent one more request, never a different answer.
- A 429 decides its backoff at arrival, and followedLane counts the owed items exactly as their replay will place them: T21 under the site's copy, the target under the current copy, not bound, owner still wanting.
- An apply is followed before the drain resumes. Deciding T21 under the site's copy and joining under the current copy equals visit-first's re-route at the site followed by that apply's visit:
  - an id the site's copy did not list was answered `.notFound` at the site, and a later re-listing cannot revive it;
  - an id it listed ends wherever the latest copy maps it, or gets T21 if the latest copy dropped it.
- Shutdown answers waiters and groups by their own sweeps.

**(4) Site 2.** The take-off still completes before the verdict in the verdict's turn, so the verdict answers exactly the interests it answers today. The re-routes still come after the verdict and after the drain's visit after it. They now come after that visit's whole rest, rather than between its turns. The visit moves ids J still holds and the take-off moves ids already off J, so the two sets are disjoint and only the order of joins changes.

**(5) Residuals (record and rule).**
- An in-flight destination that publishes or commits between drain turns captures only the owed ids that have joined it. The rest need one more request, with the same content answered while the origin answers alike (RR-3/RR-16 family). Today's barrier-up commit already has this window through its waiting joins.
- An input that lands between visit-first's answer, given at the site, and ours, given at the drain, can change which path answers: a bound id answered present against a later apply, or a purge's dropBindings. Per S3-R24 item 5 this is timing; the answers agree when the input lands before both answers or after both.

## liveness_argument

**Every owed event is reachable by a drain turn.**
- At the commit and at `.superseded`, oweReroutes calls scheduleDrainFollowUp in the same turn. If a follow is owed, the follow's end drains the event instead.
- Inside the drain, the event is prepended and the existing tail schedules the next turn: scheduleDrainFollowUp when events remain (EngineFollow.swift:223-225), or scheduleFollowFollowUp when a visit rest is owed (:219-221), whose end drains.

**Each owed event makes progress whenever it heads a turn.**
- The drain's budget starts at followIDsPerTurn, at least 1 (EngineFollow.swift:203). A `.reroutes` event at the head of a batch pops min(budget, remaining) items, so at least one.
- If the event is reached with drainIDsLeft at 0, it is put back at the head and the next turn starts with a full budget.
- So its item count strictly decreases each time it heads a turn. Items are never added to an existing event: a later site makes a new event behind it.

**Purge-emptied events replay as no-ops** (isDone gives nil) and leave the queue.

**Nothing new waits on a continuation.** There is no publication hold and no new continuation or wait state, so nothing can strand.

**The barrier falls.** Once the last `.reroutes` event and the events behind it are drained, the tail runs checkRunSettled, pump and endWorldHistory (:227-229). Admissions resume and the run can settle. Follows that interpose in between are bounded per turn and finite; a stream of applies can postpone the drain, but that is already true of every waiting event.

**Shutdown and degrade.**
- drainEverything clears the events and answers every waiter, group and the run.
- The spawn-nil branch clears the events.
- drainFollowUp's isRunning guard stops replay.

No owner is left waiting: an owed waiter is in `waiters` and is answered by the sweep (EngineShutdown.swift:52-60).

**No hang in the tests.** Every new test uses held turns (runOneHeldTurn) and bounded checks, so a drop-mutant fails rather than hangs.

## c2_argument

Work per turn at 10,000 ids. N is the site's interests. No re-route happens in a large site's turn.

**Converged** (one prefetch group, one token, every id to one content; the shape of the existing benches):
- Site 1 turn: bind; one interest's pass (10,000 `locations` lookups and appends; `refused`'s two lookups per id until the first hit); heapify, which is O(N) and a fraction of a sort (EngineMoves.swift:16-19); resolveAll with no unbound interest left; publishTerminal sorting only bound ids. Estimated 2-4 ms (UNCONFIRMED).
- Site 2 turn (movedBeforeDrain): intersection, subtract, one interest's item pass, one setInterest(nil), then J's retirement and verdict as today. 0 re-routes, since 10,000 > drainIDsLeft.
- Site 3 turn: removeAllInterests; removeJob (O(N) retireProgress, as today); the F-20 predicate's lookups; the item pass.
- Drain turns: at most 512 re-routes, each joining one job in place. At about 5 µs each (followIDsPerTurn's doc, EngineMoves.swift:116-126) that is about 2.6-3 ms a turn, over about 20 turns.

**Divergent** (each id to its own content):
- Site turns are as converged; the pass never reads destinations.
- Drain turns: at most 512 re-routes, each creating a job. That is the same per-turn work as the follow's divergent turns, which meet C2 (divergenceTurns in the C2 inventory, docs/adr-drafts/s3f.md:4843-4846). Expected 3-6 ms (UNCONFIRMED until the new case runs).

**One user waiter per id** (10,000 tokens):
- Site 1 turn walks 10,000 interests. Per token: one lookup, one append, one stub insert, one setInterest(nil), which is O(1) with InterestCounts (f066083). The old per-token work is gone: the sort (:1109), three Set or array allocations (:1110, :1114, :1120) and the transferID formatting (:1121). publishTerminal no longer sorts 10,000 unbound ids (:635). Estimated 3-5 ms (UNCONFIRMED); this is the tightest site turn.
- Site 2 turn: dropInterests over 10,000 tokens with one tail and one notifyObservers. Today it makes 10,000 removeInterest calls, each with relane and notify, plus two sorts. Estimated 2-4 ms.
- Site 3 turn: one removeAllInterests plus the item pass.
- Drain turns: at most 512 waiter re-routes (waiter.transfer update and a join). userSharedApplyTurns measured 7.18-8.01 ms for 512 moves that also take each interest off a holder, so 512 bare re-routes should cost less (UNCONFIRMED). If the new case misses, spend at most inboundIDsNow on `.reroutes` per drain turn: one `min`, no new state.

**Any grouping** (many groups, many tokens per id): the drain counts interests, so a turn's re-routes stay at or below drainIDsLeft whatever the grouping.

**Between turns:**
- A 429's followedLane walks the owed items once: O(items) lookups, about 1-2 ms at 10,000 (UNCONFIRMED; new case).
- A purge filters them once and re-heapifies.

**Pins (S3-R23 item 3):**
- Deterministic per-turn tests at followIDsPerTurn = 4 (T1, T2, T3, T5, T6). The drop-mutants of the bound, the increment, both subtractions and the fit guard each fail one of them in both orders.
- BenchSync release cases, best of 3, at a 1-minute load of 10 or less:
  - concentrationCommitRerouteTurns, with its window extended to the barrier's fall;
  - movedBeforeDrainTurns (its window already covers the barrier);
  - new divergent and user-waiter cases for each site;
  - the `.superseded` converged and user cases;
  - a 429 while 10,000 items are owed.

**Outside RR-21's rows:** the commit's own answers in the all-bound user-waiter shape (resolveAll sorting and answering 10,000 tokens) have no figure today; see risks.

## new_branches

- **N1. continueReroutes' bound** (the loop condition `spent < budget` and `spent += 1`).
- **Test T1.** F is a prefetch group of 10 ids on content X. An apply moves all 10 to D while the store holds F's publication, and F commits. Use followIDsPerTurn = 4 and hold the drain follow-ups.
- **Asserts.** In the commit's turn, 10 items are owed and D holds none. After each held turn, the owed count goes 10 → 6 → 2 → 0 and D's interests 0 → 4 → 8 → 10. All 10 are served D's bytes in both LaneDropVisit orders. Both invariant functions are clean after every turn.
- **Kills.** Dropping the bound or the increment re-routes 10 in one turn: fails 2/2.
- **N2. The `.reroutes` replay's `drainIDsLeft -= ...`.**
- **Test T2.** Two publications, F1 and F2, each commit 3 moved-away ids (both owed, since 3 > inboundIDsNow 2) before the drain runs, so one batch holds both events.
- **Asserts.** Per-turn re-routes are [4, 2].
- **Kills.** The mutant gives [6].
- **N3. startReroutes' fit guard.**
- **Test T3, two sizes.** With 2 moved-away ids: after the commit's turn no `.reroutes` waits, followBarrier is false, and D holds both. With 3: all 3 are owed and none is re-routed in the commit's turn.
- **Kills.** 'Always owe' fails the 2-id case; 'never owe' fails the 3-id case; `>` → `>=` fails the 2-id case.
- **Site 2 variant T6s.** 2 moved-before ids are re-routed in the verdict's own drain turn, and no event follows.
- **N4. Site 1's `if let rest { oweReroutes(rest) }`.**
- **Test.** T1.
- **Kills.** Dropping it loses the 10 interests: the waiter and group clauses report them, and the bounded answer check fails without a time-out.
- **N5. supersedePublication's owe.**
- **Test T5.** F's publication returns `.superseded`, with 10 ids mapped by both the store's newer manifest and the engine's copy to D.
- **Asserts.** 0 re-routed in that turn, then [4, 4, 2], with D's bytes served.
- **Variants.** 2 ids: none owed. F-20: the copy still maps 3 ids to F, so a fresh held job of F's content gets them, never `.notFound`, until the catch-up.
- **Kills.** Dropping the owe loses the interests; dropping the fit guard breaks the per-turn counts.
- **N6. Site 2's rerouteTakenOff**, in both replayVerdict and the `.spaceFailure` replay.
- **Tests T6 (404 verdict) and T6' (ENOSPC verdict).** Use the takeOffLane setup (EngineFollowBarrierMovedBeforeTests.swift:184-196) widened to zz-a plus 10 moved-before user waiters that v4 maps back, with followIDsPerTurn = 4.
- **Asserts.** The verdict's drain turn re-routes 0 of the 10 and ends its batch; the following turns re-route [4, 4, 2]. A request that arrived after the verdict (a waiting `.join` onto the 10 ids' content) is replayed only after the last owed re-route; assert its job's join order and place.
- **T6s (subtraction).** 2 moved-before ids, with a second verdict in the same batch. The second verdict's visit gets 4 − 2 ids. The mutant of `drainIDsLeft -= made.spent` gives it 4, and the turn moves 6.
- **N7. The drain loop's `left != nil ||` and the prepend of `(left, stamp)`.**
- **Test.** T6, in the shape where followAfterVerdict moves nothing, so drainIDsLeft is still 4 when the event returns.
- **Kills.** Dropping either loses the event: the invariants report the 10 waiters, and the bounded answer check fails.
- **N8. The `.reroutes` replay's `isDone ? nil : .reroutes(owed)`.**
- **Test.** T1. Turns 1-2 reach 'not done'. Turn 3 reaches 'done': assert the barrier falls and the pump runs.
- **Kills.** Inverting it stalls (turn 1) or repeats (turn 3); caught by bounded checks.
- **N9. continueReroutes' T21 rule.**
- **Test T9a.** The apply during F's publication removes 3 user-waited ids from the manifest; the commit owes them. An apply between drain turns lists them again at D.
  - Asserts: `.notFound` in both orders, which is what visit-first answered at the commit.
  - Kills: 'Always the current copy' serves D's bytes.
- **Test T9b.** The commit's copy maps the 3 ids to D1; an apply between turns maps them to D2.
  - Asserts: D2's bytes are served and the invariants are clean.
  - Kills: 'Always the site's copy' joins D1 after the follow, so EngineCommands.swift:1752-1756 fires and D1's bytes are served.
- **N10. withdrawPurgedJoins' `.reroutes` arm and its widened guard.**
- **Test T10.** A prefetch group's 10 moved-away members are owed. A purge (.all) lands between drain turns.
- **Asserts.** No job of D is created and D never starts. The group's pending entries empty through dropGroupMember. The store holds nothing for those ids.
- **Kills.** Without the arm, or with the old `joinsAfterFollow.isEmpty` guard (true here), the drain re-routes and downloads them.
- **Variants.** A system heal (heals[asset] is nil afterwards); a user waiter (kept and served: the control); mixed user and group items in one event (the re-heapified rest still pops in (asset, token) order, asserted by the user waiters' job places).
- **N11. followedLane's `.reroutes` arm.**
- **Test T11.** Use the takeOffLane shape with 5 moved-before user waiters B1-B5, which v5 moves onto J's content, at followIDsPerTurn = 4. Hold the drain after O's verdict turn; then J gets a 429 with Retry-After 60 s.
- **Asserts.** Beyond the user cap, the 429 throttles nothing and answers P and B1-B5 `serverUnavailable`, as visit-first does.
- **Kills.** Dropping the arm decides the 429 on P's prefetch lane, which throttles and serves them by a retry.
- **Parameterised sub-shapes**, one per condition, each killing that condition's drop-mutant:
  - (a) B's waiters cancelled meanwhile (withdrawn): prefetch policy.
  - (b) A site-1 variant where the commit's copy did not list B's ids and a later apply lists them at J's content: not counted.
  - (c) B's ids moved to another content: not counted.
  - (d) A released ensure group on the user lane (stillWants false): not counted.
  - (e) An id bound at J's content, answered present at replay: reachability UNCONFIRMED. If no shape reaches it, S3-R24 item 3 applies (remove it with the argument, or show it Equivalent).
- **N12. invariantViolations' three acceptances and followBarrierViolations' `.reroutes` arm.**
- **Tests.** Evaluated after every held turn of T1, T5 and T6.
- **Kills.** Dropping an acceptance makes T1 and T6 report false violations. Inverting the new arm reports every owed item.
- **N13. dropInterests** (dropInterest generalised).
- **Tests.** T6, where 10 tokens leave at once and J keeps zz-a (one relane). A T6 variant where every interest was moved before, so J is retired before the verdict as today. Every existing caller of dropInterest covers the single-token path.
- **Kills.** Dropping the per-token `run.held` removal is caught by a run-kind variant of T6 (UNCONFIRMED whether an existing test already does).
- **N14. takeOffMovedBefore's partial-interest branch** (subtractAssets).
- **Test T14.** A prefetch group holds 6 ids on J, 5 of them moved before.
- **Asserts.** One member stays on J and is answered by J's verdict; 5 are owed.
- **Kills.** Treating the interest as whole takes the kept member off J.
- **N15. committed's rewritten `refused`** (sameTransfer on the site's copy).
- **Tests.** The existing F-20 commit tests (UNCONFIRMED which file holds them), plus T15: the store refuses 3 captured ids that the copy still maps to F, with 3 > 2.
- **Asserts.** The hold is set in the commit's turn, and the fresh job of F's content is created held at the drain.
- **Kills.** 'Refused never set' admits the job before the catch-up.
- **N16. publishTerminal's `.committed` filter.**
- **Not a decision branch:** the broadcasts are the same, in the same order.
- **Test.** Existing commit tests that assert assetAvailable (UNCONFIRMED which). If none does, a 2-id commit with one id moved away asserts exactly one assetAvailable.

## supersede

**Site 3, a publication that ends `.superseded`.** The `.superseded` arm (EngineDispatch.swift:1205-1211) stops calling supersede and calls a new supersedePublication(transfer).

**Shared prefix.** supersede's first steps (:1260-1265) move into one helper that both functions call: the copy, removeAllInterests, removeJob, the F-20 predicate and holdForManifest. The F-20 hold is therefore still set in the publication end's turn.

**The re-routes.**
- supersedePublication builds the items of every interest with lane/kind stubs, in one unsorted pass with none of the sorts at :1266-1271.
- It calls startReroutes(budget: inboundIDsNow). Up to the budget, everything is re-routed in this turn as today; only the order changes.
- Otherwise none is re-routed in this turn, and the whole set waits as one `.reroutes` event with the publication end's stamp.
- It then calls checkRunSettled and pump, as :1277-1278. Both refuse while the event waits.

**supersede itself is unchanged** for its one other caller, move (EngineFollow.swift:941).
- startMove calls move only when the moved ids fit the follow's turn (EngineMoves.swift:141-143), so that path is already bounded.
- Its re-routes must read the visit's `listing` for both T21 and the join (reroute, EngineDispatch.swift:1151). The owed path reads the current copy for the join, so routing the move path through it would change answers.

**Unchanged elsewhere.** RR-4 (the `.superseded` place at arrival) is unchanged. A fresh job of the same content, created at the drain for ids the copy still maps there, is covered by the F-20 hold, because heldForManifest is keyed by TransferID.

**Pins.**
- T5, in both orders, at followIDsPerTurn = 4.
- BenchSync supersededPublicationTurns (converged) and supersededUserTurns (one waiter per id) at 10,000, best of 3 ≤ c2Budget. Today this site has no figure at all (docs/adr-drafts/s3f.md:4857).

## fixer_design_assessment

The fixer's proposal is at docs/adr-drafts/s3f.md:4906-4933.

**Agree:**
- turn the owed re-routes into drain events that carry the (token, id) pairs and the copy that found them, queued where the re-routes are made now;
- each drain turn spends at most drainIDsLeft;
- T21 under the event's copy, the join under the current copy;
- extend the treatment to `.superseded`;
- pin with S3-R23 item 3's two pins.

**Drop:**
1. The limbo index. The waiting `.reroutes` events are the index. The invariants, the purge and followedLane scan them, so there is no second structure to keep equal, and no clause or drop-mutant for one.
2. The `rerouteIDsPerTurn` seam. followIDsPerTurn already drives inboundIDsNow and drainIDsLeft, and the existing tests hold drain turns.
3. Shutdown code. drainEverything clears eventsAfterFollow (EngineShutdown.swift:118) and answers waiters and groups by their own sweeps (:52-73). The spawn-nil branch clears the events (EngineFollow.swift:390-399).
4. The publication hold:
   - 'Off its job' is moot: the left job is removed (sites 1 and 3) or cannot start behind the barrier (site 2's retry).
   - 'Onto its job' is not adopted. It needs per-destination knowledge that every apply changes, plus wait and resume state. The window it closes is in RR-3/RR-16's family (one more request, the same answer while the origin answers alike), and today's barrier-up commit already has that window through its waiting joins. It is offered as a fallback in risks.

**Correct:** followedLane must count the owed items by where their replay sends them: the current copy, T21 under the site's copy, the binding, and stillWants against the left transfer. Counting them 'by the rule of the job they left', as the proposal says, is wrong: that job no longer holds them, and its rule (visit, movedBefore, after) is about ids a job holds.

**Missing:**
- (a) Purge pruning. Without it, a purge between turns lets the drain download and store purged ids again (PROBE-C13-PURGE-JOIN's class).
- (b) The sites' own O(N) work, which dominates in the one-waiter-per-id shape: committed's sort (:1109), its per-interest filter, subtracting and sorted (:1110-1120), its transferID formatting (:1121), publishTerminal's full sort (:635), and the take-off's sorts (:558-559) and per-token removeInterest.
- (c) committed's second loop, the deferred ids re-routed after removeJob (:1133-1135). The proposal names only the moved-away ids.
- (d) Keeping small shapes synchronous, so that a 2-id commit raises no barrier.
- (e) Where site 2's event goes: inside the drain it must be prepended at the verdict's position with the verdict's stamp, and must end the batch; appending it would let later events pass it.
- (f) Counting interests rather than ids, so that an id shared by many tokens stays bounded.

## risks

- The site turn in the one-waiter-per-id shape is estimated at 3-5 ms but has never been measured. The commit's own answers in the all-bound user-waiter shape (resolveAll sorting and answering 10,000 tokens, EngineJobs.swift:618-622) have no figure at all; that cost is outside RR-21's rows but in the same turn.
- The publication window: an in-flight destination that publishes between drain turns binds only the owed ids that have joined it, and the rest cost one more request. This is a new instance of RR-3/RR-16's family and needs recording and a ruling. Fallback, a global hold: add `|| eventsAfterFollow contains a non-empty .reroutes` to inboundBlocks (EngineFollow.swift:1159-1167), and resume `inboundWaits` whose inboundBlocks is false when the last `.reroutes` finishes. The stranded clause (EngineCommands.swift:2063-2067) already covers that. Cost: one disjunct, one resume loop and two branches.
- Order changes (heap order instead of token-major; the commit's moved-away re-routes now after its answers) may break tests that pin the order of answers, starts or places. Each such test needs a one-to-one change under S3-R16 item 4 and an entry in the draft.
- followedLane is O(owed items) per 429, about 10,000 lookups; it needs its own figure.
- Admission latency: a barrier-down commit that owes 10,000 re-routes holds the barrier for about 20 drain turns (pump refused, run settlement delayed). That is timing only, but it is new for barrier-down commits.
- Sendable: OwedReroutes, MoveProgress, MoveItem and JobInterest (EngineState.swift:558, no explicit conformance) must be Sendable for EventAfterFollow (EngineFollow.swift:1405). Implicit inference for internal structs should hold; otherwise declare it. No unsafe construct is needed.
- Binding the event out of the batch (`case .reroutes(var owed)`) copies the heap once per drain turn (copy on write, about 10,000 × 32 bytes); minor.
- Heals: an owed system item keeps heals[asset] set until its replay, so a heal registered meanwhile may be deduplicated against it, as against a waiting `.join` today (UNCONFIRMED).
- The binding check in followedLane may be unreachable (UNCONFIRMED). If so it must be removed or shown Equivalent (S3-R24 item 3), and removal is only safe if the bound state cannot coexist with an in-flight job of that content.
- deferBehindVerdict stays O(E) a call; this design does not touch it (an existing 'no figure' row).
- Existing tests at small bounds whose take-off or commit re-routes exceed drainIDsLeft or inboundIDsNow will see extra drain turns (UNCONFIRMED whether any exist).

## size_estimate

**Sources: about +190 / −70 lines.**
- EngineMoves.swift +60: OwedReroutes, removeAll(where:), continueReroutes, startReroutes.
- EngineDispatch.swift +40 / −35: committed, supersedePublication, the shared prefix.
- EngineFollow.swift +45 / −25: the event case, oweReroutes, rerouteTakenOff, replay's return value, the drain loop, takeOffMovedBefore; rerouteMovedBefore removed.
- EngineJobs.swift +20 / −8: dropInterests, publishTerminal.
- EngineFailures.swift +20: followedLane's arm.
- EngineCommands.swift +35 / −3: the purge arm, the three invariant acceptances, the followBarrierViolations arm.

**Tests: about +600 lines.** About 14 both-orders tests, in 2-3 new files under Tests/ZTronAssetSyncTests/Engine, mostly parameterised shapes on the held-turn helpers.

**BenchSync: about +250 lines.** 7-8 release cases and the timeCommit window change.

**Overall:** no EngineState field, no seam. One fix cycle plus its mutant table.

## state_added

- `EventAfterFollow.reroutes(OwedReroutes)` (EngineFollow.swift:1405-1444), with `endsDrainBatch` false.
- `struct OwedReroutes` (EngineMoves.swift) with four fields: `from: TransferID`; `copy: ValidatedManifest` (the site's copy); `interests: [InterestToken: JobInterest]` (lane/kind stubs, empty assets); `items: MoveProgress` (supersedes false, lane unused).
- `MoveProgress.removeAll(where:)`, a filter plus re-heapify for the purge. It is a method, not a stored field.

## state_removed

- No EngineState field is added or removed.
- rerouteMovedBefore (EngineFollow.swift:570-576) and its calls at :356 and :619.
- From committed (EngineDispatch.swift): the deferred list (:1107), the in-loop re-route and its transferID formatting (:1121-1124), the closure loop (:1133-1135), the sorts (:1109, :1120) and the per-interest `unbound`/`bound` sets (:1110, :1114).
- From takeOffMovedBefore: the sorts (EngineFollow.swift:558-559) and the per-token removeInterest calls (:563-565).
- The `.superseded` path's sorted re-route loop. supersede (:1266-1273) keeps it for move only.
- publishTerminal's sort of unbound ids for `.committed` (EngineJobs.swift:635).

## unconfirmed

- All per-operation cost figures: the site pass, stub inserts, heapify, and re-route plus join in the user-waiter shape. None was measured; S3-R23 forbids benchmarking now.
- The commit turn's cost in the user-waiter shape today, both with ids moved away and with every id bound.
- Whether any shape reaches followedLane's binding check (an owed id bound at an in-flight job's content).
- Whether reconcileIdle treats an engine with no jobs and one waiting `.reroutes` event as busy, as it presumably does for waiting joins.
- Which existing tests pin token-major re-route order, or answer order, at commits, take-offs or `.superseded`.
- How a purge treats run items: run items are mirrored as withdrawPurged handles them, and settleRun comes first (EngineCommands.swift:972-974). Not traced further.
- Implicit Sendable inference for JobInterest, MoveItem, MoveProgress and OwedReroutes.
- Whether heal registration deduplicates against heals[asset].
- Which existing tests cover committed's `refused` hold and publishTerminal's assetAvailable broadcasts.
- That S3-R16 item 2's text, which I did not read, covers the new publication-window instance; I rely on RR-16's record (docs/adr-drafts/s3f.md:4199-4217) and RR-3's (:2728-2733).
