# judge:rr21

Read-only analysis for ruling S3-R26 (workflow wf_6b2553de-48c, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## scores

- {
 "angle": "Design 1: reuse. O' holds the unbound interests, with take-off sets on real jobs, a .takeOff drain event, widened inbound walks and takeOffJoins.",
 "answers": 2,
 "invariants_liveness": 3,
 "c2_all_shapes": 2,
 "g4_cost": 1,
 "size": 3,
 "breaks_found": [
  "RR-14, blocking class (S3-R21 item 4). The target is publishing at an apply, and its publication began before the owing instant with no follow owed. bringInboundOntoPublications returns at its guard (EngineFollow.swift:1024), which Design 1 leaves unchanged. K1's follow then finds the ids on O' (queued) and moves them under K1, so they skip the target's outcome; the at-once engine answers them with it (for example integrityFailure).",
  "Pseudo-follow. Widening bringInbound's guard (EngineFollow.swift:1004) to followBarrier lets an attempt end with no follow owed record inbound moves beyond inboundIDsNow. inboundOwed then makes followOwed true (EngineFollow.swift:82-85). An unrelated verdict deferred in that window computes `away` over its unlisted or passed ids (:514), so movedBefore is non-empty and the drain takes them off before the verdict. That is the Unlisted class (EngineFollowBarrierUnlistedTests).",
  "foundInbound walks every job (EngineFollow.swift:1086-1130). With the widened guard it also brings the passed ids of other jobs in `unfollowed` onto the target, unless the walk is restricted to take-off sets. That changes answers in shapes unrelated to RR-21.",
  "Site 2: B16-B18 make the verdict skip take-off ids. That changes today's answers (Design 1's own risks (i) and (ii)), which S3-R20 item 3 forbids, and it is scope creep.",
  "C2: dropGroupMember (EngineJobs.swift:594-604) and releaseRunClaim (EngineRuns.swift:505-512) stay copy-on-write, O(pending) per call. The T21 shape of a 10,000-member group, and the run shape, cost O(N) per id even at 512 ids a turn.",
  "Common to all three designs: a cancel that lands between the owing instant and a T21 or present pair's replay is answered .cancelled at once (withdraw, EngineCommands.swift:176-192). The at-once engine had already answered .notFound or present."
 ]
}
- {
 "angle": "Design 2: the fixer's design, completed. .reroutes(RerouteBatch) with layers and the rerouteListing chain, a global publication hold, purge withdrawal, CoW fixes, a bulk run release and the rerouteIDsPerTurn seam.",
 "answers": 3,
 "invariants_liveness": 3,
 "c2_all_shapes": 4,
 "g4_cost": 1,
 "size": 1,
 "breaks_found": [
  "Final validation (step 11) returns K0's `landed` entry when the kept target left its attempt end, for example a target publishing at the owing instant that commits during the batch. Design 2 then creates a fresh job of the old content. The at-once engine re-routed the id at that commit, under the copy of that instant: an extra request (RR-16 family), or a different answer when that copy dropped or moved the id.",
  "The double-hop approximation it admits can give a different answer when the apply lands before both answers. The chain does not apply the rule that a verdict deferred before the previous layer's apply was given at once on a visit-first engine.",
  "The global hold (inboundBlocks || reroutesOwed) delays every publication while any batch is owed. An apply during the hold that drops a held job's ids gives .notFound where the at-once engine committed first. That is timing only under RR-23's rule, but it is a new instance. The resume site (reroutesSettled) strands a wait if it is missed (EngineCommands.swift:2061-2064).",
  "28 new branches, each needing a both-orders test and a 2/2 drop-mutant kill. This is the largest G4 surface, and a new seam (rerouteIDsPerTurn) duplicates followIDsPerTurn.",
  "Common: the cancel timing described under Design 1."
 ]
}
- {
 "angle": "Design 3: first principles. .reroutes(OwedReroutes), all or nothing per site, T21 decided under the site's copy, the join made under the current copy, a purge prune, a followedLane arm and invariant acceptances.",
 "answers": 1,
 "invariants_liveness": 3,
 "c2_all_shapes": 2,
 "g4_cost": 3,
 "size": 4,
 "breaks_found": [
  "P-a, blocking. At t0 the commit owes E, and K0 maps the items to Z, which is downloading. At t2, Z's 404 is deferred behind E. At t3, K2 maps the items to W. E replays after K2's follow, and its joins are made under the current copy, so W serves the items. The at-once engine had them on Z, whose 404 answered .notFound. The apply lands before both answers.",
  "RR-14, blocking class (S3-R21 item 4). Z is publishing when an apply moves the items on, and Z's publication then fails (integrity). The at-once engine answers integrityFailure; Design 3 serves the new content. Its claim that RR-23's family covers this fails, because the apply lands before both answers.",
  "There is no hold. A target whose publication starts while pairs are owed binds without them, and the pairs later join a fresh job of the same content: a second request (RR-16 family).",
  "The C2 copy-on-write in dropGroupMember and releaseRunClaim remains, so the T21 group shape and the run shape are O(N) per id.",
  "Common: the cancel timing described under Design 1."
 ]
}
- {
 "angle": "Synthesis (recommended). Design 3's single drain event per site, all or nothing above the bound, reusing reroute(listing:); Design 2's layer chain with its final validation corrected and the verdict filter applied per layer; Design 2's in-place owner updates and global hold; Design 1's verdict-first order for site 2. No pseudo-follow, no Job.takeOff, no new seam.",
 "answers": 4,
 "invariants_liveness": 4,
 "c2_all_shapes": 4,
 "g4_cost": 2,
 "size": 2,
 "breaks_found": [
  "The common cancel and release timing class remains (open question 1). It has a precedent: a cancel during today's owed follow beats a T21 answer that the follow's visit would have given.",
  "A pin whose job left its end between the apply and the replay re-routes under the copy at the replay, not the copy at that job's commit. This is exact unless another apply came in between, the same approximation as continueInbound's dropped move (EngineFollow.swift:1188-1199).",
  "The global hold's timing window for unrelated publications (see Design 2's third break) remains.",
  "Present is decided at the replay: a binding forgotten between owing and replay (a purge's dropBindings, an eviction) turns a present answer into a join that asks the store (answeredFromStore). UNCONFIRMED whether any probe can tell the difference.",
  "There is no figure yet for site 2's take-off at once with 10,000 user waiters, or for the commit's own turn with 10,000 user waiters (the sorts at EngineDispatch.swift:1109 and EngineJobs.swift:618). Either can still miss C2. UNCONFIRMED."
 ]
}

## recommendation

None of the three designs should go to cycle 21 as written.
- **Design 3** is the smallest, but it breaks two blocking classes, P-a and RR-14, because it joins under the copy at the replay.
- **Design 1** keeps the interests on real jobs, but it misses RR-14 when the target was already publishing at the owing instant. Widening bringInbound creates a pseudo-follow that changes the Unlisted class's answers, and it changes today's site-2 answers.
- **Design 2** has the right semantics (a layer chain), but its final validation is wrong (it keeps K0 for a target that is gone) and it carries 28 branches.

Recommended: a synthesis.
1. **The event.** Each of the three sites owes its pairs as one `.reroutes(RerouteBatch)` drain event, but only when they exceed the bound. Below the bound, today's code runs byte for byte, so existing tests and answers do not move.
   - The bound is inboundIDsNow at the commit and at supersede, and drainIDsLeft at the verdict replay.
   - The batch lives in the event, so the existing clears drop it. It ends its drain batch and stays at the head of the queue until it is empty.
   - No pseudo-follow: the barrier is up because an event waits, and followOwed is never raised, so no reader of followOwed changes.
2. **The replay.** Each pair is replayed through the existing `reroute(listing:)`. The only new decision is which copy to pass, computed by a corrected layer chain:
   - an id K0 does not list is T21 at the owing instant;
   - a layer is appended in adoptApplied at every copy change while a batch waits; it records the publishing jobs, and the waiting verdicts queued behind the batch (on later layers, only those deferred after the previous apply);
   - a pin is honoured only while waitingTarget(transfer, epoch) holds, and otherwise the pair follows the copy at the replay;
   - an id that an intermediate copy dropped is answered under that copy.

   With no apply between turns, this is exactly the at-once engine's re-route under the same copy, at the owing instant's stamp. P-a, RR-14 and the double hop are answered from the target the visit-first engine had.
3. **The holds and the readers.**
   - A global publication hold (inboundBlocks) makes a target's binding capture the pairs joined to it, with one resume when the last batch ends.
   - A followedLane arm, a purge arm, and invariant acceptance for owners that name `from`.
   - A bulk release of the run's claims at owing.
4. **Site 2.** The take-off happens at once, without sorting and in place. The verdict and the visit after it follow, and then the batch at the head of the queue, before every later event. The at-once path now spends drainIDsLeft.
5. **In-place updates.** dropGroupMember, releaseRunClaim and deliver's group branch become O(1) amortised. Without this, the T21 and run shapes breach C2 even at 512 ids a turn.

The design has about 20 branches, each pinned by a both-orders test with a named drop-mutant and by BenchSync cases for every grouping. That includes the user-waiter shapes, which none of the three designs measured.

## design_spec

- 1. In-place owner updates; no new branch.
- dropGroupMember (EngineJobs.swift:594-604): guard on `self.state.groups[token]?.pending[asset] == transfer`, remove through `self.state.groups[token]?.pending[asset] = nil`, then do the ensure completion from a read of the group. isSettled is O(1) (EngineState.swift:949-951).
- releaseRunClaim (EngineRuns.swift:505-512): guard on `self.state.run?.token == token`, call `self.state.run?.outstanding[transfer]?.remove(asset)`, and nil the entry when it is empty.
- deliver's group branch (EngineJobs.swift:563-576): remove the members in place.
- Why: each of these took a `var` copy of the Group or RunState, so every mutation copied the whole collection, O(pending) per call. A 10,000-member group's T21 or purge, and a run whose claims converge, are O(N) per id even at 512 ids a turn.
- 2. A new value type next to MoveProgress (EngineMoves.swift:20-88); make MoveItem Hashable.
- RerouteBatch { from: TransferID; copy: ValidatedManifest (the copy at the owing instant); applies: UInt64 (appliesFollowed at owing, for the invariant only); moves: MoveProgress (a heap by (asset, token), never sorted); owners: [InterestToken: (lane: AssetPriority, kind: InterestKind)]; withdrawn: Set<MoveItem>; layers: [RerouteLayer] }.
- RerouteLayer { outgoing: ValidatedManifest; applies: UInt64; ends: [TransferID: UInt64] }.
- Add `case reroutes(RerouteBatch)` to EventAfterFollow (EngineFollow.swift:1405-1435), and list it among the true cases of endsDrainBatch (:1436-1443).
- There is no EngineState field: the existing clears drop the batch with the events (EngineFollow.swift:393, EngineShutdown.swift:118).
- 3. One owing helper in EngineFollow.swift, beside rerouteMovedBefore (:572-576).
- `owe(items:owners:from:) -> RerouteBatch` builds the batch under `self.state.applied`.
- When the run's token is among the owners, it bulk-releases the run's claims on `from` for those ids: `self.state.run?.outstanding[from]?.subtract(ids)`, nil when empty.
- Callers count their pairs first and keep today's code verbatim at or below the bound.
- Sites 1 and 3 then call `deferToFollow(.reroutes(batch))` (:233-236). When `!followOwed && !drainingAfterFollow`, they also call `scheduleDrainFollowUp()` (:379-400), so 'events wait implies owed, scheduled or draining' (EngineCommands.swift:2006-2008) holds.
- Bounds: inboundIDsNow (EngineMoves.swift:130-132) at sites 1 and 3; drainIDsLeft (EngineState.swift:167) at site 2. There is no new seam: tests set followIDsPerTurn (EngineState.swift:108).
- 4. Site 1, committed (EngineDispatch.swift:1100-1139).
- The interest loop (:1109-1128) still trims each interest to its bound ids (:1114-1119) and still computes `refused` (:1125).
- It collects every unbound pair as a MoveItem. That covers both the moved-away ids (today re-routed at :1121-1122) and the ids the copy maps here (today `deferred`, :1126).
- At or below inboundIDsNow: re-route the moved-away pairs right after the loop, and the deferred ones in the closure, as today. This is call-for-call today's work; only the interleaving of trims and re-routes changes, and they touch disjoint state. Record that argument in the draft.
- Above the bound: the resolveAll closure (:1129-1136) keeps holdForManifest and then owes one batch from `transfer`.
- Optional, at no branch cost: publishTerminal (EngineJobs.swift:635) iterates only the bound ids for .committed. The events and their order are identical, and it gives the converged commit back part of its 0.14 ms margin.
- 5. Site 3, supersede (EngineDispatch.swift:1256-1279), only from the .superseded exit (:1205-1211).
- Count the pairs.
- At or below inboundIDsNow: unchanged.
- Above: keep removeAllInterests, removeJob and the F-20 hold (:1261-1265), and owe the pairs instead of running the loop at :1266-1273. checkRunSettled and pump stay; behind the barrier they are no-ops.
- move's supersede (EngineFollow.swift:931-955, settling: false) is already bounded by startMove's budget and is not touched.
- 6. Site 2: replayVerdict (EngineFollow.swift:607-620) and the .spaceFailure arm (:346-356).
- takeOffMovedBefore (:551-568) drops both sorts. When all of an interest's ids are held, it removes the interest whole with one removeInterest. It returns MoveItems and owners.
- After giveVerdict or decideSpaceFailure and followAfterVerdict (:586-593, which spends drainIDsLeft):
  - if the items fit drainIDsLeft, call rerouteMovedBefore as today and subtract their count from drainIDsLeft (new: today's re-routes spend nothing);
  - otherwise, owe a batch (from: transfer, under the copy now) and return it.
- replay(_:) (:344-376) returns `EventAfterFollow?`.
- In drainEventsAfterFollow (:204-216), a returned event is inserted at index 0 with the current stamp, ahead of the batch's rest, and the turn ends. Widen the existing spent-budget branch to do this, so the batch replays right after its verdict and before every later event.
- 7. The drain arm, `case .reroutes(var batch)`, calls `continueReroutes(&batch, budget: drainIDsLeft)`, modelled on continueMove (EngineMoves.swift:179-217).
- It takes items by id, at most `budget` distinct ids, and skips withdrawn items.
- For each item: `self.reroute(item.token, interest: JobInterest(lane: owners[token].lane, kind: owners[token].kind, assets: []), asset: item.asset, from: batch.from, listing: self.rerouteListing(item.asset, batch))`. Existing guards in reroute (EngineDispatch.swift:1147-1189) cover a waiter that is gone, a released group and an ended run.
- It subtracts the spent ids from drainIDsLeft.
- If items are left, it returns `.reroutes(batch)` to the drain (step 6's path). If none are left, it calls releaseRerouteHolds() (step 10).
- Joins made here are made at once (drainingAfterFollow is set), and never behind a verdict (inFollowVisit is false, EngineJobs.swift:117-123).
- 8. rerouteListing(_ asset:, _ batch:) -> ValidatedManifest?, Design 2's chain corrected:
```
guard var entry = batch.copy.entry(for: asset) else { return batch.copy }
for (index, layer) in batch.layers.enumerated() {
    if let epoch = layer.ends[entry.transferID] {
        return self.waitingTarget(entry.transferID, epoch: epoch) != nil ? layer.outgoing : nil
    }
    let incoming = index + 1 < batch.layers.count ? batch.layers[index + 1].outgoing : self.state.applied
    guard let next = incoming.entry(for: asset) else { return incoming }
    entry = next
}
return nil
```
- What it returns:
  - T21 at the owing instant: the batch's copy;
  - a valid pin: that layer's outgoing copy;
  - a pin whose job left its end: nil, the copy now. This is the fix for Design 2's `landed` bug;
  - an id an intermediate apply dropped: that copy, so the pair is answered .notFound.
- With no layers it returns nil; the copy now is the batch's copy (step 9), so the replay is exactly the at-once re-route.
- Refactor waitingTarget (EngineFollow.swift:1251-1263) into `waitingTarget(_ transfer: TransferID, epoch: UInt64) -> Job?`, with the InboundMove overload forwarding to it. This adds no branch; its unreached case stays the open S3-R24 item 3 one.
- 9. Layers in adoptApplied (EngineJobs.swift:1018-1027), before `self.state.applied = manifest`. That line is the only writer of the copy; adoptApplied is called from EngineRuns.swift:369, EngineCatchUp.swift:223 and EngineLifecycle.swift:399.
- If a .reroutes event waits, make one pass over eventsAfterFollow and append, to each batch in place, `RerouteLayer(outgoing: self.state.applied, applies: self.state.appliesFollowed, ends: E)`.
- E is:
  - every job in inFlight that is verifying or committing, with its epoch (a visit passes it, rerouteOnVisit EngineFollow.swift:860-877);
  - plus every live waiting verdict queued after that batch: .attemptFailed whose verdictsAfterFollow epoch matches, or .spaceFailure at the job's epoch (UNCONFIRMED: no verdictsAfterFollow entry for space failures). Its job must be failed with attemptEnd.deferredAfter set.
  - From a batch's second layer on, only verdicts with `deferredAfter > previousLayer.applies`. A visit-first engine gave a verdict deferred before that apply at once, and the pair joined the job the verdict left.
- Jobs failed in publication bookkeeping are not ends: a new apply's visit moves them (:879-889).
- Cost: O(events + in-flight) per apply.
- 10. Publication hold.
- inboundBlocks (EngineFollow.swift:1159-1167) also returns true while any .reroutes event waits (a scan with early exit).
- publish then waits in awaitInboundMoves (EngineDispatch.swift:1032-1045), as it does for owed moves. A target's binding therefore captures the pairs the batch joins to it while it waits verifying.
- releaseRerouteHolds() runs only at a batch's end. It resumes each inboundWaits entry whose inboundBlocks is now false, with inboundMade's loop (:1272-1275).
- releaseInboundWaits (:1297-1307) already resumes every wait at shutdown.
- 11. followedLane: in the events walk (EngineFailures.swift:821-836), add `case .reroutes(let batch)`.
- Count an item only if it is not withdrawn, its token is not in laneEventsWaiting's `withdrawn` (:845-863), and its owner still names batch.from: the waiter is present, not fromStore, waiter.transfer == from and the asset is the same; or group.pending[asset] == from; or the token is the run's; or the kind is system.
- `let entry = (rerouteListing(asset, batch) ?? self.state.applied).entry(for: asset)`. Skip nil (T21) and `isBound(asset, to: entry.transferID)` (answered present).
- Raise the item's lane when `sameTransfer(entry, job.entry)`.
- Cost: O(items × layers) per 429 (R-SYN-5).
- 12. Purge: withdrawPurgedJoins (EngineCommands.swift:1049-1073).
- The early return at :1050 also requires that no .reroutes event waits.
- For each batch, take each live item with lane < userInitiated, kind != waiter and isPurged(asset). Call dropGroupMember(token, asset, from: batch.from) for prefetch and ensure, or set heals[asset] = nil for system. Insert the item into batch.withdrawn, then write the event back.
- User waiters' items are kept, as withdrawPurged keeps them (:992-1039).
- 13. Invariants.
- invariantViolations: the waiter clause (EngineCommands.swift:1708-1712) and the group clause (:1777-1783) also accept an owner that names a live batch item's `from` for that (token, asset).
- followBarrierViolations (:2003-2069): the exhaustive switch (:2016-2030) gets .reroutes. New clauses:
  - (a) a live item's owner names `from`, or is gone;
  - (b) the run claims no live run item on `from`;
  - (c) no empty batch waits;
  - (d) a batch's layers are at most the copies adopted since it was owed.
- The stranded-wait clause (:2061-2064) covers the hold unchanged.
- 14. Records in docs/adr-drafts/s3f.md (the cycle-21 section).
- In the C2 inventory, replace the three RR-21 rows with the bounded design and its figures, and add rows for deliver, dropGroupMember and releaseRunClaim (O(1) amortised).
- List open questions 1, 4 and 5 as timing or residual classes, citing S3-R16 item 2 and RR-23's rule.
- Record the one-to-one argument for committed's at-or-below-bound reordering.
- Record the site-2 drainIDsLeft spend.

## invariants

- No batch raises followOwed (EngineFollow.swift:82-85). So none of these change while re-routes are owed: publish's `away` (EngineDispatch.swift:1024-1027), recordDeferredVerdict's `away` (EngineFollow.swift:514), holdsMovedID, bringInbound, bringInboundOntoPublications, and the end of continueFollow.
- While a .reroutes event waits, the barrier is up (followBarrier, EngineFollow.swift:97-99). Nothing is admitted, no space verdict is given, no run settles (EngineRuns.swift:576), and every input that defers is replayed after the batch, at its own stamp.
- Owner stasis: from owing to replay, a live item's owner names `from` (waiter.transfer, group.pending[asset]) or is gone. The run claims none of the batch's run items (bulk-released at owing).
- Copy history: every copy change while a batch waits appends exactly one layer (adoptApplied is the only writer of state.applied). With no layer, the copy now equals batch.copy, and the replay equals the at-once engine's reroute under the same copy at the owing instant's stamp.
- T21 under batch.copy is answered as T21 (.notFound, member dropped, heal forgotten) whatever a later copy lists. An id that an intermediate copy did not list is answered under that copy.
- A pin is honoured only while waitingTarget(transfer, epoch) holds. A pair whose pinned job left that end follows the copy now. No fresh job of a former target is created from an old copy.
- Order: a batch replays at its queue position. Site 2's batch replays right after its verdict and the visit after it, before every later event. A batch ends its drain batch and stays at the head until it is empty.
- Bound: at most drainIDsLeft distinct ids a drain turn, shared with the turn's visits after verdicts. Sites 1 and 3 make at most inboundIDsNow re-routes in their own turn. Site 2's at-once path spends drainIDsLeft.
- Liveness: a drain turn with ids left makes at least one item. A turn with none left re-inserts the batch and schedules a follow-up, whose fresh budget makes progress. An owed follow is finite and ends with the drain. Every publication wait is resumed at the last batch's end, or at shutdown.
- At or below the bound, every site runs today's code with the same calls (committed only regroups re-routes after its trims, on disjoint state).
- Owner updates are O(1) amortised: no live `var` copy of a Group or RunState exists while a collection inside it is mutated (dropGroupMember, releaseRunClaim, deliver).
- Purge: a withdrawn non-user item joins nothing, and its group member is dropped or its heal forgotten. User waiters' items are kept.

## tests

- Every test below runs at followIDsPerTurn = 4 and in both LaneDropVisit orders (EngineFollowTests.swift:780-787). Each asserts invariantViolations() and followBarrierViolations() after every released turn, uses .timeLimit and has no sleeps.
- T1, the bound at site 1 (S3-R23 item 3). A commit leaves 10 unbound pairs; drain follow-ups are held and released one turn at a time. Each turn makes at most 4 distinct ids and at least 1. The answers equal a run at followIDsPerTurn = 512. Kills: drop `spent < budget`; drop the drainIDsLeft subtraction in continueReroutes. A companion case with 2 pairs asserts that no .reroutes event is created, killing the drop of the at-once count test.
- T2, the bound at site 3. A .superseded publication with 10 pairs, same shape and assertions as T1. Kills: drop site 3's count test (with the 2-pair companion); owe before removeJob (the F-20 hold is then lost: a held fresh job is expected).
- T3, the bound and order at site 2. A verdict (404) and a .spaceFailure each hold 10 moved-before ids, and a waiting .removal of one pair's waiter is queued behind the verdict. The batch replays right after the verdict, the removal then removes the re-joined interest, and no stray job is left. Kills: insert the returned event at the tail or after the rest; drop the drainIDsLeft subtraction on the at-once path (two verdicts in one drain batch, 3 and 3 ids: the second must be owed).
- T4, T21 at the owing instant. K0 drops the ids; an apply that re-lists them lands between turns. Expect .notFound, the group members dropped. Kills: remove rerouteListing's `else { return batch.copy }`.
- T5, RR-14 at layer 0. The pairs' K0 target X0 is publishing when an apply moves them to W, and X0's publication then fails with integrity. Expect integrityFailure for the pairs. Kills: drop the publishing term of `ends`.
- T6, P-a. X0 is downloading at t0, X0's 404 is deferred behind the batch, then an apply maps the pairs to W. Expect .notFound. Kills: drop the verdict term of `ends`.
- T7, a verdict ahead of the batch. X0's verdict waits at the owing instant, queued before the batch (the sweep-first order makes this natural); an apply then moves the pairs. Expect the pairs to follow the apply and get W's answer, not X0's verdict. Kills: count verdicts queued before the batch.
- T8, a pin that left its end. X0 is publishing at the apply and commits before the replay. Expect the pairs to follow the copy now: W's job, no job of X0's content created after the commit, and a fixed jobsCreated. Kills: return layer.outgoing instead of nil (Design 2's `landed` bug).
- T9, a double hop. K1 moves the pairs from a downloading X0 to X1, which is publishing at K2; K2 moves them on; X1's publication then fails. Expect X1's failure. Kills: stop the chain after the first layer.
- T10, an id unlisted by an intermediate apply. K1 drops the ids and K2 re-lists them. Expect .notFound. Kills: remove `guard let next ... else { return incoming }`.
- T11, the second layer's verdict filter. X1's verdict was deferred behind the batch but before K1, and K2 moves the pairs. Expect no pin at K2: the pairs follow K2. Kills: drop `deferredAfter > previousLayer.applies`.
- T12, a 429 while a batch is owed (R-SYN-5). A user waiter's pair targets the throttled job. Expect a userInitiated backoff policy and fail-fast answers as at once. Kills: drop the followedLane arm; use batch.copy's entry instead of rerouteListing (with an apply in between); drop the owner-names-from check (the waiter cancelled meanwhile must not raise the lane).
- T13, a purge while a batch is owed. Non-user pairs of purged ids are withdrawn: no job is created after the replay, the member is dropped, the heal is forgotten. User waiters' pairs are kept. Kills: drop the purge arm; keep withdrawPurgedJoins' early return.
- T14, a target's publication starts while a batch is owed. It waits, its binding then captures the pairs, and they are answered .committed with no second request. Kills: drop the hold term in inboundBlocks; drop releaseRerouteHolds (the stranded-wait clause fires and the publication never binds within the time limit).
- T15, cancel and release while owed. Cancelling a join pair's waiter answers .cancelled at once, and its interest is gone after the replay. A released group gets no member re-joined. The invariants stay clean on every turn. Kills: drop the waiter or the group invariant acceptance; drop clause (a) of followBarrierViolations (mutate an owner in limbo in a seeded probe).
- T16, shutdown midway through a batch. Every waiter gets .shutDown, nothing hangs, no wait is stranded, and no event or batch remains. This is an exercise; it kills no new mutant.
- T17, two sites while owed. A second commit is owed behind the first batch; the answers equal at-once in both orders. Kills: insert sites 1 and 3 at the head instead of appending.
- T18, the run shape. A run's claims converge on O and are moved away. The run settles only after the batch, and outstanding names the new jobs. Kills: drop the bulk release (the run-claim invariant at EngineCommands.swift:1812-1817 fires).
- BenchSync: concentrationCommitRerouteTurns and movedBeforeDrainTurns, unchanged (BenchSync.swift:655-659 and 675-690). Best of 3 at most c2Budget at a 1-minute load of 10 or less, with the loads recorded (S3-R23).
- New BenchSync cases, each best of 3 at most c2Budget, plus a per-turn maximum:
- the commit moved away with 10,000 user waiters (one per id), converged on D, and divergent onto 10,000 contents;
- the commit with v4 dropping the 10,000 members (T21), for a group and for user waiters (this pins step 1's in-place updates);
- a .superseded publication of 10,000 ids, group and user waiters;
- site 2 with 10,000 user waiters, all held and half held;
- the run shape with 10,000 converged claims moved away;
- an apply while a 10,000-pair batch waits with publications in flight, and the replay through two layers;
- a 429 on the target while a 10,000-pair batch waits (followedLane);
- the commit with 10,000 user waiters all bound (the inventory row, open question 2).

## must_not

- Do not raise followOwed, or add any new source of it, for owed re-routes. No pseudo-follow; no VisitRemainder or InboundMove created at a site.
- Do not widen the guards of bringInbound (EngineFollow.swift:1004) or bringInboundOntoPublications (:1024), and do not change the followOwed reads in recordDeferredVerdict (:514), publish (EngineDispatch.swift:1024-1027) or holdsMovedID (:424-431).
- Do not put owed pairs on a holder job (Design 1's O' or take-off sets), and do not add Job.takeOff, takeOffJoins, a holder epoch or a new job state.
- Do not re-route a pair under a later copy when batch.copy does not list it (T21 at the owing instant).
- Do not join a pinned job once waitingTarget(transfer, epoch) fails, and do not fall back to K0's entry (Design 2's `landed`). Fall back to the copy now.
- Do not change any site's code path at or below the bound, and do not change today's site-2 verdict semantics: no verdict skips ids, giveVerdict is not touched.
- Do not insert the site-2 batch at the tail of the queue or before its verdict, and do not let the rest of the drain batch go ahead of it.
- Do not make .reroutes a non-batch-ending event, and do not let a drain turn with drainIDsLeft <= 0 drop the batch instead of re-inserting it.
- Do not sort a batch's items, or any 10,000-element collection, in a turn; use the MoveProgress heap.
- Do not mutate a Group's pending, a RunState's outstanding or a Job's id sets through a `var` copy of the enclosing struct.
- Do not add a new seam: use followIDsPerTurn, inboundIDsNow and drainIDsLeft.
- Do not leave a publication wait without its resume, at a batch's end and at shutdown.
- Do not fix replayJoin's pre-existing approximation, or the waitingTarget window, in this cycle; record them.
- Do not edit anything under Scripts/, lower a gate, widen a coverage exclusion, or add a @unchecked Sendable or UNSAFE exception: the batch is a plain Sendable value inside the event.
- Do not take timing figures while the S3-R23 verifiers measure. Measure at a 1-minute load of 10 or less, record the three load averages, and take the sim.lock (S3-R22 item 3).

## open_questions

- Cancel or release between the owing instant and a T21 or present pair's replay: the caller gets .cancelled, where the at-once engine had already answered .notFound or present. This affects all three designs and the synthesis. Today's owed follow has the same class (a cancel during an owed visit beats the visit's T21). Rule it timing (S3-R16 item 2, by RR-23's rule), or require the site to answer terminal pairs at once, which costs O(N) lookups and resumes in the commit's turn and is UNCONFIRMED within C2.
- The commit's own turn with 10,000 user waiters all bound has no figure: the sort of 10,000 tokens at EngineDispatch.swift:1109, resolveAll's sort at EngineJobs.swift:618, 10,000 resumes, and publishTerminal's sort at :635. The converged group shape is at 9.86 ms. If this case misses, it is a fourth RR-21 site: bounded delivery of a commit's answers.
- Site 2's take-off at once (O(held), unsorted, whole interests) has no figure with 10,000 user waiters. If it misses, chunk it before the verdict: re-run the verdict behind a take-off phase of the same batch. That adds about 3 branches.
- The global hold delays unrelated publications. An apply during the hold that drops a held job's ids answers .notFound where the at-once engine committed first. Confirm this is timing under RR-23's rule (the apply lands between the two answers), or require a per-target hold (an O(N × layers) walk at each publication start).
- A pin whose job committed or was superseded between the apply and the replay follows the copy at the replay, not the copy at that commit. This is exact unless another apply landed in between, the same approximation as continueInbound's dropped move. Rule it residual, or keep a layer per commit (more state).
- replayJoin's pre-existing RR-14-class gap: a waiting .join whose target was publishing at a later apply is re-routed under the current copy (EngineFollow.swift:704-707). It is outside RR-21 and is now inconsistent with the batches' pins (at or below the bound versus above it). Is it blocking? The layers could serve .join events too. UNCONFIRMED whether any existing test pins today's sweep-first answer in that shape.
- Present is decided at the replay. A binding forgotten after the owing instant (a purge's dropBindings, an eviction) turns a present answer into a join that asks the store (answeredFromStore). Acceptable as equivalent, or should the site record a presence bit per item (an O(N) lookup at owing)?
- waitingTarget's unreached queued, blocked and downloading case (S3-R24 item 3, cycle-20 Open item 2) now also guards pins. Its Reached, Removed or Equivalent ruling applies to both callers.
- Inventory rows outside RR-21 that still have no figure, and are reachable in the same shapes: move's sort of a holder's whole interests (EngineFollow.swift:945-946); deferBehindVerdict's O(E) scan and insert (:964-978); deliver's per-call group copy-on-write when one drain turn resolves many jobs of one large group (fixed by step 1, figure UNCONFIRMED).
- The .spaceFailure verdict has no verdictsAfterFollow entry (UNCONFIRMED). Layer `ends` must then identify a live space verdict by the job's epoch and attemptEnd. Confirm before implementing.

## clean_cycle_probability

About 0.25 (range 0.2 to 0.35) that cycle 21 finds no blocking item in RR-21's area, if the synthesis is implemented as specified with every listed test and BenchSync case. The figure rises to about 0.35 if the orchestrator rules open questions 1, 4 and 5 timing or residual before the verifiers start.

It is pulled down by:
- about 20 new branches, each needing a 2/2 kill in both orders;
- the user-waiter C2 shapes, which no one has measured (open questions 2 and 3);
- the verifiers' record of finding a new interleaving in every cycle.

For the designs as written: Design 2 about 0.1, Design 1 about 0.05, Design 3 about 0.02, because P-a and RR-14 are both known blocking classes.
