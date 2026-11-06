# design:reuse

Read-only analysis for ruling S3-R26 (workflow wf_6b2553de-48c, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## angle

reuse

## design_summary

Every interest stays on a real job. The design reuses the drain, the follow's move machinery (continueMove, reroute, addInterest), addInterest's placement behind a waiting verdict, and the walk at an attempt's end (bringInbound). Nothing sits in a limbo, so no invariant needs an exemption.

(1) Above the at-once bound, the commit and the .superseded exit no longer re-route. `committed` and the `.superseded` exit re-route at once only when the unbound (token, id) pairs fit `inboundIDsNow`; that is today's code, unchanged. Above it they classify instead:
- The bound parts are delivered by the existing resolveAll, as today.
- In resolveAll's closure, the fresh job O' of T is created in the same turn. This is the job visit-first created at the commit: new epoch, queued, held for manifest when refused. It holds every unbound interest.
- The ids the copy does not map to T's content, or that are bound, become O''s take-off set (`Job.takeOff`), together with the commit's copy K0.
- One `.takeOff(T)` drain event is queued at the commit's place, so the barrier stays up until it ends.

(2) A `.takeOff` event ends its drain batch, so every later waiting event is still queued. Each turn it routes at most the drain turn's remaining ids, through continueMove → reroute → addInterest:
- An id that is terminal under K0 (unlisted, or bound) is answered under K0.
- Any other id follows the copy as it stands.
- When the target job's exit verdict waits, addInterest's existing verdict branch buffers the join. One pass per turn splices the buffer right behind that verdict (deferBehindVerdict's placement). The join is marked `rerouted`, so its replay re-routes and restores a run claim that a verdict's recordRunOutcome wiped.

(3) Site 2 reuses the same event. A verdict whose job still holds moved-before ids puts `.takeOff(T)` and itself back at the head of the queue. takeOffMovedBefore and rerouteMovedBefore are deleted.

(4) Between turns:
- Follow visits never move take-off ids, so a later apply cannot re-list a T21 id into a job.
- bringInbound also runs while only events wait, and walks the take-off sets. An id the copy maps to a job whose attempt ends is therefore on that job when its publication binds or its verdict answers (P-a).
- followedLane counts take-off ids for a 429 decided at arrival.

## mechanism

- M1 Bound (EngineMoves.swift:126-132). Reuse `inboundIDsNow` (followIDsPerTurn/2: 256 in release, 2 at seam 4) as the number of re-routes the commit or supersede turn makes at once. It is already 'the ids an attempt's end … moves in its own turn'. No new constant.
- M2 committed (EngineDispatch.swift:1100-1139):
- Keep `bind` (:1105) first.
- One unsorted pre-pass counts the unbound (token, id) pairs (`locations[id] == nil`), stopping at inboundIDsNow+1.
- At or below the bound: the body runs unchanged.
- Above it, the loop (:1108-1127) still narrows each interest to its bound part (:1114-1118). The per-id part (:1120-1127) classifies instead of re-routing:
  - `kept[token]` gets the unbound ids.
  - (b) = `applied.entry(for:)?.transferID == transfer` (:1123) and `!isBound(id, to: transfer)` (EnginePresence:9).
  - (a) = every other unbound id (mapped elsewhere, unlisted, or bound).
  - `refused ||= captured.contains(id)` for ids mapped to T, exactly as :1126.
- Then `resolveAll(transfer, with: .committed(locations)) { if refused { holdForManifest(transfer) }; self.installRemainder(...) }` (EngineJobs:611). It delivers in sorted tokens, removes O, runs publishTerminal and then the closure, as today.
- Then pump and reconcileIdle (:1136-1137).
- M3 .superseded (EngineDispatch.swift:1205-1211). After `transition(transfer, to: .queued)`:
- If the job's (token, id) pairs exceed inboundIDsNow: snapshot `kept` = job.interests (all unbound). Classify (b) = `copy.entry(for:).map { sameTransfer($0, job.entry) } == true && !isBound`, and refused = today's predicate at :1264. Then `removeAllInterests`, `removeJob`, `holdForManifest` if refused, `installRemainder(...)`, `checkRunSettled`, `pump`.
- Otherwise call `supersede(transfer)` as today.
- move()'s `supersede(settling: false)` (EngineFollow.swift:941) is untouched.
- M4 installRemainder (new, EngineJobs.swift, beside resolveAll :611). It mirrors addInterest's fresh-job block (:136-157):
- `lastEpoch += 1`; `jobsCreated += 1` only when (b) is non-empty.
- O' = `Job(transfer: T, entry: <the copy's entry of the first (b) pair in today's re-route order (tokens, then ids, ascending), else O.entry>, identity, assets: all unbound ids, state: .queued, epoch: lastEpoch, queuedAt: decisionNow())` (EngineFollow:241).
- `resume = launchResumes.removeValue(forKey: T)`.
- `setInterests(kept)`: a new bulk mutator beside keepInterests (EngineState:817), with the same recount.
- `takeOff = TakeOff(ids: (a), decided: applied, moves: nil)`.
- `jobs[T] = O'`, `enqueue(T)` (EngineJobs:474), `ensureWatcher()` (EngineConditions:29).
- Re-add what removeJob (EngineJobs:409-448) dropped:
  - `unfollowed.insert(T)`;
  - systemHeld, if a kept interest is .system;
  - run.held, if the run's token is kept;
  - `run.outstanding[T].formUnion(the run's kept ids)`, because deliver → recordRunOutcome wiped it (EngineRuns:519).
- `deferToFollow(.takeOff(T))` (EngineFollow:233). If `!followOwed`, call `scheduleDrainFollowUp()` (EngineFollow:379, made internal).
- `notifyObservers()`.
- The event is queued unconditionally, even with (a) empty. It is then done at its first replay, so there is no emptiness branch.
- M5 State (EngineState.swift):
- `var takeOff: TakeOff?` on `struct Job` beside attemptEnd (:728), where `struct TakeOff { var ids: Set<AssetID>; let decided: ValidatedManifest; var moves: MoveProgress? }`.
- `EngineState.inTakeOff: Bool` beside inFollowVisit (:90).
- `EngineState.takeOffJoins`: a turn-local buffer of (join, target, epoch, stamp).
- `EventAfterFollow.takeOff(TransferID)` (EngineFollow:1405), with endsDrainBatch → true (:1436-1443).
- `JoinAfterFollow.rerouted = false` (EngineFollow:1573-1592).
- The progress lives on the job, so removeJob drops it with the job. There is no engine-level slot to clear.
- M6 follow (EngineFollow.swift:906-913). After `moved` is computed:
`if let off = job.takeOff?.ids { if !moved.isDisjoint(with: off) { unfollowed.insert(transfer) }; moved.subtract(off) }`.
A visit moves O''s other ids normally and never a take-off id. The job stays in `unfollowed` (the invariant at EngineCommands:1749-1755), as for a passed publication (:909-912).
- M7 continueMove (EngineMoves.swift:179-226):
- Read `let decided = jobs[holder]?.takeOff?.decided` once, before the loop.
- Where an id is first taken (:198-200), also do `jobs[holder]?.takeOff?.ids.remove(asset)`, so a B-stay (an id routed back to T) becomes an ordinary id.
- At the reroute (:208), pass `listing: decided.map { isTerminal(asset, under: $0) ? $0 : listing } ?? listing`.
- New helper `isTerminal(_:under:)` beside isBound (EnginePresence:9): `copy.entry(for:).map { isBound(asset, to: $0.transferID) } ?? true`.
- Factor startMove's item building (:161-167) into `moveProgress(of:ids:)`, so a take-off reuses it.
- M8 replay returns Int (EngineFollow.swift:344-376): the count of events it put back at the head of the queue. New arm `.takeOff(T)` → `continueTakeOff(T)`:
- `guard let job = jobs[T] else { return 0 }`.
- `off = job.takeOff ?? TakeOff(ids: job.assets ∩ (job.attemptEnd?.movedBefore ?? []), decided: applied, moves: nil)`. The fallback is site 2's first turn; its K is today's copy at the verdict's replay.
- `moves = off.moves ?? moveProgress(of: job, ids: off.ids ∩ job.assets)`, with supersedes false.
- Write takeOff back with moves = nil, swapped out so the heap is unique and CoW-free.
- `inTakeOff = true`, `continueMove(&moves, of: T, listing: nil, budget: drainIDsLeft)`, `inTakeOff = false`.
- Flush takeOffJoins (M11).
- If `moves.isDone || jobs[T] == nil`: set `jobs[T]?.takeOff = nil` and return 0.
- Otherwise store moves, insert `.takeOff(T)` and the reading's stamp at index 0, and return 1.
- M9 Site 2 (EngineFollow.swift):
- replayVerdict (:607-620): keep the record guard (:608). Clear the record and return 0 on a failed job guard (:612), as today.
- Then, `if !job.assets.isDisjoint(with: job.attemptEnd?.movedBefore ?? [])`: insert `[.takeOff(T), .attemptFailed(T, epoch, verdict)]` with the reading's stamp twice at index 0, keep the record, and return 2.
- Otherwise clear the record, then endDeferral (:537), giveVerdict (:623) and followAfterVerdict (:586), and return 0.
- The .spaceFailure arm (:346-356) does the same with decideSpaceFailure.
- Delete takeOffMovedBefore (:551-569) and rerouteMovedBefore (:572-576). Nothing else references them, tests included (grep), but their names appear in docs at :507, :545, :606, :1567 and EngineFailures:731, :868; reword those.
- M10 Drain loop (EngineFollow.swift:202-216):
- `let held = withReading(stamp) { replay(event) }`.
- Break when `held > 0 || followMoving != nil || drainIDsLeft <= 0`.
- Insert the batch's rest, events and stamps, at index `held` instead of 0.
- The tail (:218-229) is unchanged; it schedules the follow-up while events wait.
- M11 addInterest (EngineJobs.swift:117-123). The condition becomes `(inFollowVisit || inTakeOff) && !bringingInbound && target.attemptEnd?.deferredAfter != nil`.
- When inTakeOff: register `joinsAfterFollow[token][asset] = transfer` and append (JoinAfterFollow(…, listed: true, rerouted: true), target, epoch, worldStamp()) to takeOffJoins, instead of calling deferBehindVerdict.
- New `deferBehindVerdicts()` beside deferBehindVerdict (:964) rebuilds eventsAfterFollow/eventStamps in one O(L+k) pass. Each target's joins go right behind its .attemptFailed/.spaceFailure at the target's epoch (the predicate at :966-973), else at the end (as :975; unreachable under invariant N5).
- This avoids deferBehindVerdict's O(L) scan and insert per id.
- M12 replayJoin (EngineFollow.swift:692-711). After the registration guard and its removal (:694-701):
`if join.rerouted { drainIDsLeft -= 1; reroute(join.token, interest: JobInterest(lane: join.lane, kind: join.kind, assets: []), asset: join.asset, from: transfer); return }`.
This bypasses stillWants (:713). reroute (EngineDispatch:1147-1188) re-validates the owner: the waiter (:1168), the group (:1174), run.token (:1180). It re-inserts the run claim at the new transfer.
- M13 Walk:
- bringInbound's guard (EngineFollow.swift:1004): `followOwed` → `followBarrier` (:97).
- foundInbound (:1094-1099), per job:
  - `off = takeOffSet(job)` = `job.takeOff?.ids`, else, when `attemptEnd?.deferredAfter != nil`, `attemptEnd.movedBefore`;
  - `visit` = followOwed ? `rerouteOnVisit(job).map { off.map($0.union) ?? $0 }` : off;
  - skip the job when !followOwed and off is nil;
  - in the id loop, skip an id in `off` that is terminal under `job.takeOff?.decided`.
- makeInboundNow (:1176-1185) already schedules follow turns for the rest.
- bringInboundOntoPublications (:1023) is unchanged.
- M14 followedLane (EngineFailures.swift):
- rule(of:) (:733-740): `movedBefore: (other.attemptEnd?.movedBefore ?? []).union(other.takeOff?.ids ?? [])`, plus `decided: other.takeOff?.decided` (a new LaneMoveRule field, :1040).
- moves (:741-751) first returns false for a take-off id that is terminal under decided, before the visit test. So a K0-terminal id never counts, even when visit is nil.
- The jobs-walk guard (:796) adds `|| waiting.takeOffs`.
- laneEventsWaiting (:845-864) reports whether a .takeOff waits.
- throttled computes followedLane (:346) before defersFailure walks (:355 → EngineFollow:466), so this count is needed.
- M15 Invariants:
- followBarrierViolations (EngineCommands:2003) and invariantViolations (:1702) gain N1-N5 (see invariants).
- Add the .takeOff case wherever a switch over EventAfterFollow is exhaustive: replay (EngineFollow:344) and endsDrainBatch; laneEventsWaiting uses default.
- Shutdown (EngineShutdown.swift:117-125) and the spawn-nil branch (EngineFollow:389-398) already clear the queue and the joins. Take-off state lives on jobs, so they need nothing new.
- M16 Pins:
- Per-turn counts at followIDsPerTurn = 4 (EngineState:108), with the holdDrainFollowUps/runOneHeldTurn idiom of EngineFollowBarrierDrainBoundTests:
  - the commit turn routes 0 ids when there are more than 2 pairs;
  - a .takeOff turn routes at most 4 ([4, 4, 2] for 10);
  - rerouted-join replays are at most 4 per drain turn.
- BenchSync release cases, best of 3, at most c2Budget: listed under c2_argument.

## invariants

- Unchanged and needing no exemption: waiter ⇒ interest at waiter.transfer or a registered join (EngineCommands:1708). Take-off ids stay on O' (T) or on T; rerouted joins are registered in the turn they are queued.
- Unchanged: group members ⇒ interest or registered join; run claims ⇒ an interest or a waiting join at that transfer. installRemainder restores run.outstanding[T] after recordRunOutcome's wipe (EngineRuns:519).
- Unchanged: a system interest's job is in systemHeld, and the run's interest's job is in run.held. installRemainder re-adds both after removeJob (EngineJobs:432-434).
- Unchanged: a job outside unfollowed follows the copy (EngineCommands:1749-1755). T is inserted at install, and again by follow() while take-off ids map elsewhere.
- Unchanged: registered joins equal the waiting .join events, and verdict events' transfers equal the verdictsAfterFollow keys (followBarrierViolations :2003). takeOffJoins is flushed in its turn, and V is put back with its record kept.
- Unchanged: events wait ⇒ followOwed, a scheduled drain or draining. installRemainder schedules the drain when !followOwed.
- Unchanged: downloading ⇒ no attemptEnd and no rerouteOnPass.
- N1 (new): job.takeOff != nil ⇒ a .takeOff(job.transfer) event waits.
- N2 (new): job.takeOff?.moves != nil ⇒ the first waiting event is .takeOff(job.transfer). Only the head take-off is in progress: an unfinished one puts itself back at index 0, and its batch ends with it.
- N3 (new): job.takeOff != nil ⇒ the job is queued (sites 1 and 3), or failed with attemptEnd.deferredAfter set (site 2). A take-off holder is never admitted: the barrier is up until its event ends.
- N4 (new): between turns, inTakeOff is false and takeOffJoins is empty.
- N5 (new): job.attemptEnd?.deferredAfter != nil ⇒ its .attemptFailed or .spaceFailure at job.epoch waits. This makes the splice's end-of-queue fallback unreachable.

## events_between_turns

- An apply or a catch-up (followApplied, EngineFollow:47; followStoreView, EngineCatchUp:207):
- Its passes and visits run first; the drain's guard (:189) waits for !followOwed.
- O' is visited as an `unfollowed` job, but follow() never moves its take-off ids (M6).
- The take-off then routes the rest under the newest copy, with K0-terminal ids under K0. A T21 id re-listed by the apply is still answered .notFound.
- An attempt's end of another job Z, while the take-off waits:
- The cases are a publication start (EngineDispatch:1018), a deferred 404/5xx/429/offline verdict (defersFailure, EngineFollow:466) and an ENOSPC (EngineFailures:573).
- bringInbound, whose guard is now followBarrier, walks the take-off sets. It owes moves for the non-terminal ids the copy maps to Z (findInbound) and makes the first ones (makeInboundNow).
- Z's publication waits for them (inboundBlocks :1159), and Z's deferred verdict, queued after .takeOff, answers them. This is P-a in both orders: '404 then apply' gives .notFound, 'apply then 404' serves.
- A 429/503 decided at arrival (throttled, EngineFailures:337-358): followedLane counts the take-off ids that would reach Z (M14) before defersFailure walks.
- A waiter's cancel:
- The `.removal` is queued after .takeOff and replayed after the take-off. It removes the interest from the job the record names then (replayRemoval :734).
- If the waiter's rerouted join replays first, the removal follows it. If the removal replays first, it deletes the record and reroute's waiter guard drops the join. The answer is cancelled either way.
- A group release, a claim's end or a run's end (these apply on arrival, e.g. performReleaseGroup, EngineCommands:358):
- The interests leave O' or T, and their heap items are skipped (continueMove's removeAsset guard :205).
- A holder that is emptied is retired with its take-off. The stale `.takeOff` finds no job and returns 0.
- Queued rerouted joins are dropped by reroute's owner guards.
- A purge: withdrawPurged (EngineCommands:992) removes non-user interests from O', and their items are skipped. withdrawPurgedJoins (:1049) marks the rerouted joins withdrawn, and the registration guard (:694) drops them.
- Another commit or a .superseded publication of a job X that was already publishing: X gets its own remainder, and .takeOff(X) is appended after. Take-offs progress one at a time, at the head of the queue (N2).
- A publication commit of a job that received brought ids: normal binding. Its own unbound remainder goes through M2 again.
- A space sweep, a conditions edge, a readmit or unblock, a retryDue or throttle answers:
- Each is an event queued after .takeOff.
- O' is queued behind the barrier and the pump admits nothing (EngineDispatch:95-107), so none of them admits or parks it before the take-off ends.
- Site 2's verdict V itself: it waits right behind its .takeOff (the pair put back at the head) until the take-off ends. The B-joins wait right behind V, so the barrier is up while V is given and checkRunSettled stays suppressed (EngineRuns:576).
- The holder retired mid-take-off (empty after a release or purge): removeJob drops Job.takeOff. The .takeOff replay returns 0, and site 2's V finds no job, clears its record and returns.
- Shutdown: releaseInboundWaits and the clears at EngineShutdown.swift:117-125, or the spawn-nil branch at EngineFollow:389-398, empty the queue and the joins. Nothing is admitted, and the take-off state goes with the jobs.
- A drain turn whose earlier events spent the turn's ids: the loop breaks before .takeOff (:211), which starts the next turn with a full budget.

## answer_equality_argument

**Sites 1 and 3.** Visit-first, at the commit (or the superseded exit) t:
- delivered the bound parts;
- created a fresh job of T for the (b) ids;
- moved each (a) id to its K0 content, or answered it T21 or present under K0.

Each moved id then followed every later apply. V2 makes the same deliveries in the same turn through the same resolveAll. It creates that fresh job (O') in the same turn, with queuedAt t, held exactly when today's predicate says. Only its epoch, its place and its admission (after the barrier) differ: order and timing.

**Each (a) id:**
- Terminal under K0: it is answered under K0 at its take-off turn, with the same answer as at t. An apply in between cannot change it: follow() never moves a take-off id, and the walk skips K0-terminal ids. That is P-T21.
- Otherwise it is routed under the copy as it stands at its turn. That is the end of visit-first's chain of moves:
  - If no apply landed since t, the copy is K0.
  - If one did, the id goes straight to the apply's content, which is where visit-first's visit moved it. An id moved back to T's content rejoins O', the fresh job visit-first moved it to.
  - The only intermediate state visit-first could expose is the id sitting on its K0-era job Z when Z's attempt ends. The walk reproduces it: at any attempt's end during the take-off, it brings the ids the copy then maps to Z onto Z. Z's publication binds them, or its deferred verdict answers them. So '404 then apply' gives .notFound and 'apply then 404' serves. The fixer's design does not give these (P-a).
  - When the routing turn finds Z's verdict waiting, that verdict is from an attempt that ended before the apply that mapped the id to Z. Visit-first's move at that apply met Z as its verdict left it. The join waits right behind the verdict, which is the placement deferBehindVerdict already uses for follow visits. Its replay re-routes, so a run claim the verdict wiped is restored.

**Site 2.** The moved-before ids are routed before V is given and never answered by it, as today. Today, ids mapped back to E rejoin T after V (PROBE-C16C-VERDICT-MAPPED-BACK); the B-join right behind V gives the same. K0 is today's copy at V's replay. Routes A and D move from after V to before it, which is order only: V's verdicts act on T alone (giveVerdict :623-660). Two cases move today's answers toward visit-first:
- the walk brings moved-before ids at an attempt end while only events wait, or after a later follow ended;
- an id mapped to a job whose verdict waits joins behind that verdict, not before it.

Both are argued as visit-first in risks.

**Everything else** is a request count (RR-16), an order, a place or a ticket.

**Bounding changes no answer.** Splitting a take-off across turns changes only when an id is routed. Every event that lands meanwhile either:
- waits behind .takeOff and meets the state as the whole take-off leaves it;
- is an apply, whose effect on a take-off id is applied at the id's routing (current copy, K0 for terminal ones);
- is an attempt end or a 429 lane decision, which read the take-off sets through the walk and followedLane;
- or is an owner-side withdrawal applied on arrival, which skips the item.

## liveness_argument

**Commit turn.** It does a bounded amount of O(N) work and queues one .takeOff. It schedules a drain follow-up when no follow is owed; otherwise the follow's end drains (continueFollow → drainEventsAfterFollow).

**Take-off turns.** Each .takeOff turn starts its batch's last event with drainIDsLeft ≥ 1. A batch that spent its ids breaks before it, and the next turn starts with a full budget. So continueMove routes at least one id per turn (its `spent < budget` guard). The heap only shrinks, so a take-off of N pairs ends after at most ⌈ids/drainIDsLeft⌉ of its turns.

**Interleaved work.** Follows (bounded passes, visits and rests) and inbound moves (makeInboundNow, then follow turns) each end in bounded turns, after which the drain resumes. Rerouted joins replay at most drainIDsLeft per drain turn and never create new waiting events, except through the existing pass-through paths.

**Site 2.** V puts [.takeOff, V] back exactly once per non-empty intersection. After the take-off, T holds no moved-before id: a B id goes behind V (addInterest's verdict branch, since T's deferral is set), a D id goes elsewhere, and an A id is answered. So V's second replay gives the verdict, and there is no livelock. A holder retired meanwhile ends both replays.

**After the take-off.** The queue empties. checkRunSettled and pump run (EngineFollow:218-229), so O' is admitted and the run can settle. heldForManifest is released by the catch-up or the follow's end as today. Starvation by a stream of applies is the pre-existing property of the drain.

## c2_argument

The per-id costs come from cycle-19/20 measurements (a reroute plus a join ≈ 5 µs, a fresh job ≈ 10-12 µs). The totals are estimates, UNCONFIRMED until the BenchSync cases run.

**Converged** (10,000 (a) ids to one content W, concentrationCommitRerouteTurns):
- Commit turn ≈ 4-6 ms: classification (one copy lookup and one isBound per id ≈ 2-3 ms), plus resolveAll with removeJob and publishTerminal (today's non-re-route part, ≈ 3 ms of today's 48.68), plus building O' (bulk interest install with one recount, the asset set ≈ 0.5 ms).
- First .takeOff turn ≈ 4 ms: heap build ≈ 1 ms, plus 512 joins.
- Later turns ≈ 2.6-3 ms.

**Divergent** (10,000 ids to 10,000 contents):
- Commit turn: same as converged.
- Take-off turns ≈ 512 × 10-12 µs ≈ 5-6 ms. This is the same work as a 512-id visit turn of BenchSync.divergenceTurns, which is within budget since cycle 19.

**One user waiter per id** (10,000 tokens):
- Commit turn ≈ 5-7 ms. The sorted-token delivery is today's. Classification is one unsorted pass. Building O' moves the dictionary.
- Take-off turns ≈ 512 × 6-7 µs ≈ 3.5 ms. relane's re-enqueue of the user-lane O' or target is O(1) per id (UNCONFIRMED).
- Many groups: like user waiters, with dropGroupMember and pending updates per id.

**Mixed commit** (half bound): the commit turn is at most the all-bound commit (≈ 9.6-9.9 ms measured) minus the delivered half, plus classification of the other half.

**Superseded publication** (site 3): like the commit without deliveries, ≈ 3-5 ms.

**Site 2** (movedBeforeDrainTurns, 10,000):
- V's first replay: one intersection (≈ 0.3 ms) and a 2-event head insert.
- Take-off turns: as above.
- B-heavy: plus one O(L+512) splice per turn (≈ 0.2-0.5 ms at L = 10,000), plus B-join replays of at most 512 × 5 µs ≈ 2.6 ms per drain turn.

**Attempt end during a 10,000-id take-off:** the walk is one pass over jobs and take-off ids (≈ 1-3 ms), plus makeInboundNow of at most 256 ids (≈ 1.3 ms).

**Barrier-up commit:** the same commit turn; nothing at once.

**Pins:**
- The existing concentrationCommitRerouteTurns and movedBeforeDrainTurns must pass.
- New BenchSync cases: supersededRerouteTurns; commitRemainderBHeavyTurns; commitRemainderMixedTurns; commitRemainderUserTurns; takeOffDivergentTurns; takeOffWalkTurns; takeOffBarrierUpTurns; movedBeforeMappedBackTurns (10,000 B-joins with 10,000 events waiting); takeOffBehindVerdictTurns (10,000 C-joins).

## new_branches

- B1 committed's bound (> inboundIDsNow). Seam 4 (inboundIDsNow = 2), in both LaneDropVisit orders.
- Commit A: 2 unbound (a) waiters. Both are answered in the commit turn.
- Commit B: 3 unbound (a) waiters. 0 are answered in the commit turn; the drain turns answer [3] under holdDrainFollowUps.
- Kills: always-old (the commit turn answers 3) and always-new (A's commit turn answers 0).
- B2 The .superseded bound, same shape: a .superseded publication with 2 pairs re-routes at once (today); with 3, 0 in that turn and then at most 4 per drain turn. Kills both mutants.
- B3 (b) excludes bound ids. Both orders: an unbound id the copy maps to T that the store holds bound to T (via an apply's reused report, EngineRuns:377-381).
- Its waiter must get the present location, with no origin request for it.
- Mutant (keep it in (b)): O' refetches it, giving one extra request and a committed location.
- B4 The run-claim restore in installRemainder. Both orders: a run whose interest on O has 2 bound and 3 unbound (a) ids.
- The run must not settle until the 3 are answered at their new jobs, and its fetched and failure counts include them.
- Mutant: recordRunOutcome's wipe stands and the run settles early.
- B5 The index re-adds (unfollowed, systemHeld, run.held). Both orders: the remainder holds a heal's system interest and the run's interest. invariantViolations() must be empty after the commit turn. Each mutant reports its index.
- B6 follow()'s take-off subtraction and its unfollowed insert (P-T21). Both orders: a commit at t with (a) id x unlisted at K0; before the first .takeOff turn, an apply re-lists x at content W.
- Expected: .notFound, and invariantViolations() empty between turns.
- Mutant (no subtraction): the apply's visit of O' moves x to W, and it is served.
- Mutant (no insert): an invariant is violated after the visit.
- B7 continueMove's decided listing.
- Shape 1, as B6, but x stays unlisted until its own .takeOff turn and an apply re-lists it between take-off turns (seam 4, x at position 6). Expected .notFound. Mutant (listing nil): served from W.
- Shape 2: x bound to its K0 content (reused) and re-mapped by an apply before its turn. Expected: the present location of the K0 blob. Mutant: a new download and another location.
- B8 continueMove's takeOff.ids removal. Both orders: an apply between turns maps take-off id y back to T (a B-stay that rejoins O'), and after the take-off ends a second apply maps y to V.
- Expected: y is served from V.
- Mutant: y stays in takeOff.ids, follow() keeps skipping it, and it is fetched as T's content.
- B9 The .takeOff replay, not done vs done. Seam 4, 10 (a) ids, both orders.
- Expected: routed per drain turn [4, 4, 2], all answered, Job.takeOff nil afterwards.
- Mutant (no re-insert): 6 waiters hang, and N1 is violated.
- Mutant (no clear on done): N1 is violated, and the B8 shape fails.
- B10 The drain loop's held > 0 break and the insert at index held. Both orders: the batch is [V(T, a 404, with moved-before x still on T), J], where J is another waiter's join for T's content that arrived after V.
- Expected: J replays after V (a fresh job, served).
- Mutant (no break): J replays in the same turn, before .takeOff and V, joins T, and V's 404 answers it.
- Mutant (rest at index 0): the same.
- B11 replayVerdict and .spaceFailure: deferral to .takeOff when T still holds moved-before ids.
- The existing EngineFollowBarrierMovedBeforeTests shapes (VERDICT-MAPPED-BACK, takeOffLane :196-313) must pass in both orders.
- Add a seam-4 run with 6 moved-before ids, half mapped back.
- Add a .spaceFailure twin: an ENOSPC deferred while x, moved before, still sits on T. x must not be parked or answered insufficientSpace.
- Mutant (give V at once): V answers x.
- B12 addInterest's `|| inTakeOff` buffer.
- B: site 2, x mapped back to E, V = .resolve(.notFound). Expected: x served by a fresh job. Mutant (a direct join to T): .notFound.
- C, site 1: (a) x mapped at K0 to W. Z 404s with its verdict deferred. Then an apply maps x to Z's content. The take-off finds Z's verdict waiting. Expected: x joins behind it and is served. Mutant: a direct join to Z, and Z's 404 answers x .notFound.
- Both in both orders.
- B13 JoinAfterFollow.rerouted in replayJoin. Both orders: the B shape with x a run interest of the run that also holds T's own ids.
- Expected: the run counts x after x's fresh job ends, and it does not settle before.
- Mutant (no rerouted path): stillWants is false after recordRunOutcome's wipe, x is dropped, and the run settles without it.
- B14 replayJoin's `drainIDsLeft -= 1`. Seam 4, both orders: 10 B-joins behind V. The replays per drain turn after V are at most 4 ([4, 4, 2]). Mutant: all 10 replay in one turn.
- B15 deferBehindVerdicts places each group right behind its own target's verdict.
- Covered by B12-C with two targets Z1 and Z2 (verdicts queued Z1 then Z2), and x1→Z2, x2→Z1. Each must be served by its own content's fresh job.
- Mutant (insert all behind the first verdict found): x1's join meets Z2 before Z2's 404, which answers it .notFound.
- The end-of-queue fallback is unreachable under N5, which the invariant test pins.
- B16 bringInbound's guard → followBarrier. P-a in both event orders, each in both LaneDropVisit orders. A commit with (a) x mapped at K0 to Z, which is downloading:
- (i) Z 404s (verdict deferred), then an apply maps x to W. Expected .notFound.
- (ii) The apply first, then Z 404s. Expected: served from W.
- Mutant (guard followOwed): in (i), !followOwed during the take-off, so there is no walk; x is routed to W and served.
- B17 foundInbound's restriction to take-off sets when !followOwed. Both orders, the EngineFollowBarrierUnlistedTests shape: while only a .takeOff waits, a waiter joined from the store's newer manifest sits on a job of the newer content that the copy maps elsewhere (to Z), and Z 404s.
- Expected: that waiter is not answered by Z's 404.
- Mutant (walk all ids): it is brought onto Z and answered .notFound.
- B18 foundInbound's union with the take-off set when followOwed. Both orders: a site-2 holder T whose deferral's follow has ended (rerouteFor ≠ followsEnded, so rerouteOnVisit is []), with moved-before x mapped to Z. Z 404s while a new follow is owed.
- Expected .notFound: x is on Z at the 404, as in visit-first.
- Mutant: x stays on T and later joins behind Z's verdict, and is served.
- B19 foundInbound's K0-terminal skip. Both orders: x is unlisted at K0, an apply re-lists it at Z's content, and Z's publication starts during the take-off.
- Expected: x is not bound and is answered .notFound.
- Mutant: x is brought, bound and served.
- B20 followedLane's take-off rule, its K0-terminal exclusion and its guard. Both orders: during a take-off with no follow owed and no verdict waiting, Z (a background lane) gets a 429.
- Shape 1: a user waiter's take-off id is mapped to Z. Expected: the user-lane policy (EngineFailures:346), observable as the waiter's fail-fast answer. Mutant (guard or rule unchanged): the background policy.
- Shape 2: the user waiter's id is K0-unlisted but re-listed at Z. Expected: the background policy. Mutant (no exclusion): the user policy.

## supersede

Site 3 (the `.superseded` exit, EngineDispatch:1205-1211) uses the same remainder.
- At or below inboundIDsNow (token, id) pairs, it calls today's `supersede(transfer)` unchanged.
- Above it, it snapshots the interests (all unbound), and does removeAllInterests, removeJob and holdForManifest under today's predicate (:1264). Then `installRemainder`, with (b) = ids whose entry is sameTransfer with job.entry and that are not bound to T.
- O' is exactly the fresh, held job of T that today's re-routes create (F-20). The other ids are its take-off set under K0. There are no deliveries.

`move()`'s supersede (EngineFollow:933-941, `settling: false`) is untouched. It runs only when the moved ids fit the visit's budget (startMove, EngineMoves:140-145; cycle 19). An id is taken whole, with all its tokens, which is the existing convention.

The move-progress heap is built by the helper factored out of startMove (:161-167). So startMove, inbound moves, visit rests and take-offs share one builder and one mover (continueMove).

## fixer_design_assessment

The fixer's proposal (`.reroutes(batch)` events with a limbo index, docs/adr-drafts/s3f.md:4916-4930) bounds the work, but three things make it the costlier and riskier route.

**(1) Limbo interests sit on no job.** Every reader that walks jobs or names a job must be taught about them:
- the waiter invariant (EngineCommands:1708);
- group members, run claims, systemHeld and run.held, and unfollowed (:1749);
- performReleaseGroup (:358) and withdrawPurged (:992), which remove interests from jobs;
- replayRemoval (EngineFollow:734), which removes from the job the record names;
- foundInbound (:1086), which walks jobs;
- followedLane (:721);
- inboundBlocks (:1159), which becomes O(limbo) for every publication check.

Each exemption is a new branch with a drop-mutant to kill, and each missed one is an invariant or answer bug.

**(2) 'T21 under the event's copy, the join under the current copy' misses P-a.** Take a limbo id whose K0 target Z 404s, with the verdict deferred and queued after .reroutes, and that is then moved by an apply. It is served in their design. Visit-first had it on Z at the 404 and answered .notFound. Holding publications in inboundBlocks covers only the publication half, and not verdicts.

**(3) Holding every publication while any re-route is owed** delays unrelated bindings and adds per-check cost.

**V2 instead:**
- keeps the interests on O', the very job visit-first created at the commit, and on T for site 2, so no invariant changes;
- gets P-a from the existing attempt-end walk, by widening its guard and its visit set;
- reuses continueMove, reroute/addInterest's verdict-behind branch, the drain barrier and batch, and the run-claim logic of reroute;
- deletes takeOffMovedBefore and rerouteMovedBefore.

Its genuinely new parts are a take-off set on Job, one event kind, a one-pass splice and the rerouted-join flag.

One part of the fixer's design is kept: deciding T21 under the copy that found the re-route (K0). It is right, and V2 keeps it via continueMove's decided listing.

## risks

- Barrier-up commit: O' exists while the events that arrived before the commit replay. Only a join or a removal acts on a queued job behind the barrier, and either meets the same T job. This is the same class as a later apply's visits made before earlier-arrived events replay, which the drain already accepts. A verifier may still ask for it to be argued explicitly.
- Site-2 timing changes: every verdict whose job still holds moved-before ids now takes two extra drain turns, one for .takeOff and one for V again. Routes A and D happen before V instead of after it. EngineFollowBarrierMovedBeforeTests (takeOffLane :172-313) may pin turn counts and need one-to-one updates under S3-R16 item 4.
- Two changes of today's answers, both argued as visit-first:
- (i) the walk brings moved-before ids at an attempt end while only events wait, or after a later follow ended (the union in M13);
- (ii) an id mapped to a job whose verdict waits joins behind that verdict instead of being answered by it.
A verifier could read them as unasked behaviour changes, or ask for probes that show today's code wrong.
- The bound reuses inboundIDsNow, so at seam 4 a commit with 3 or more unbound pairs switches path. Six test files set followIDsPerTurn (DrainBound, RestOrder, StaleReroute, SharedMove, MoveRevalidation, TurnTotal), and any that commits 3 or more unbound pairs changes timing. Fallback: a fixed constant (8).
- K0-bound ids read the binding at their take-off turn. An eviction in between makes them refetch instead of being answered present at t.
- jobsCreated is off by one when (b) is empty and a B-stay later rejoins O'.
- While queued, O''s lane includes its take-off interests. This is place only, since it is not admitted until the take-off ends.
- The rerouted-join replay bypasses stillWants and relies on reroute's owner guards (waiter, group, run token). A legitimately released run claim cannot be re-added while the join waits, because the run's end changes its token, but that argument should be pinned.
- The commit turn's figures depend on removeJob's per-asset retireProgress (EngineJobs:444-446) and publishTerminal's sort of all of O's ids (:635). Both are in today's cost too, and both are UNCONFIRMED at 10,000.
- Pre-existing holes this design does not fix:
- T21 in follow visit rests and passes, when an id is re-listed between turns;
- deferBehindVerdict's O(L) scan and insert per id in follow visits;
- the run-claim wipe for non-take-off joins behind a .resolve verdict;
- early checkRunSettled windows in a last drain batch.
- Inbound-only follows (the walk records moves while !followOwed) increment followsEnded. This was analysed as harmless, because no rerouteOnPass set is live when no follow is owed (recordDeferredVerdict, EngineFollow:516).
- The splice's end-of-queue fallback is unreachable by N5. Coverage tooling will show its line unexecuted; it is justified by the invariant.

## size_estimate

Production: about +260 / −70 lines (about +400 with /// docs):
- the committed and .superseded split and installRemainder, ≈ 90;
- the .takeOff event, replay and continueTakeOff, ≈ 60;
- the splice, ≈ 30;
- the drain loop and replay returning Int, ≈ 15;
- addInterest, replayJoin and follow(), ≈ 20;
- foundInbound and bringInbound, ≈ 20;
- followedLane and laneEventsWaiting, ≈ 15;
- continueMove and isTerminal, ≈ 10;
- invariants N1-N5, ≈ 30;
- deleted: takeOffMovedBefore and rerouteMovedBefore plus their call sites, ≈ −45, and reworded docs.

Tests: about +1,100 to 1,400 lines: 20 deterministic tests (B1-B20) in both LaneDropVisit orders, at seam 4 where a count is pinned, plus 9 new BenchSync release cases.

Files touched: EngineDispatch, EngineJobs, EngineFollow, EngineMoves, EngineState, EngineFailures, EnginePresence and EngineCommands; tests under Tests/ZTronAssetSyncTests/Engine; and Tests/ZTronAssetKitBenchmarks/BenchSync.swift.

## state_added

- Job.takeOff: TakeOff? (EngineState.swift, beside attemptEnd :728), where TakeOff { var ids: Set<AssetID>; let decided: ValidatedManifest; var moves: MoveProgress? }. Set at install for sites 1 and 3, and at site 2's first .takeOff turn. It lives and dies with the job.
- EventAfterFollow.takeOff(TransferID), with endsDrainBatch true (EngineFollow.swift:1405-1443).
- JoinAfterFollow.rerouted: Bool = false (EngineFollow.swift:1573-1592).
- EngineState.inTakeOff: Bool, a turn-local flag beside inFollowVisit (:90).
- EngineState.takeOffJoins: a turn-local buffer of (JoinAfterFollow, target TransferID, epoch, WorldStamp), flushed by deferBehindVerdicts in the same turn.
- LaneMoveRule.decided: ValidatedManifest? (EngineFailures.swift:1040), and laneEventsWaiting's takeOffs flag.

## state_removed

- takeOffMovedBefore (EngineFollow.swift:551-569) and rerouteMovedBefore (:572-576), and their calls in replay's .spaceFailure arm (:352, :356) and replayVerdict (:615, :619). Their work is now the site-2 .takeOff.
- The re-route loops of committed's per-id part (EngineDispatch.swift:1120-1127, the deferred reroutes in resolveAll's closure :1132-1134) on the path above the bound. They stay as today's code at or below inboundIDsNow.

## unconfirmed

- All C2 figures are estimates built from earlier per-id measurements; none was measured in this session (no builds or benchmarks ran, by instruction).
- The cost of removeJob's per-asset retireProgress and of publishTerminal's sort at 10,000 ids in the commit turn.
- Whether relane's re-enqueue of a user-lane O' or target (EngineJobs:263) is O(1) amortised.
- Whether EngineFollowBarrierMovedBeforeTests or other existing tests pin per-turn counts that the extra site-2 drain turns change, and whether any seam-4 test commits 3 or more unbound pairs.
- That the pump (EngineDispatch:95-107) is the only admission path, so no job is admitted while a .takeOff waits; other start paths were not re-read in this session.
- That recordDeferredVerdict (EngineFollow:508) is the only setter of attemptEnd.deferredAfter, which N5 and the splice rely on.
- That bringInboundOntoPublications (EngineFollow:1023) needs no take-off awareness: its publications took their take-off ids at their own start through the widened walk.
- The pre-existing holes listed under risks (T21 in visit rests, the run-claim wipe behind .resolve for ordinary joins, deferBehindVerdict's per-id O(L), early checkRunSettled in a last batch) were inferred from reading, not probed.
- That EventAfterFollow keeps its element size with the new case. replay (EngineFollow:344) and endsDrainBatch were confirmed as the only exhaustive switches in Sources, and grep found none in the tests.
