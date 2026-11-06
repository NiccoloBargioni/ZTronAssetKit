# design:fixer

Read-only analysis for ruling S3-R26 (workflow wf_6b2553de-48c, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## angle

The fixer's design: draft Open item 1, docs/adr-drafts/s3f.md:4906-4933. The design is completed and repaired against the code at 8e1fb24.

## design_summary

Below a threshold, the existing at-once code runs unchanged. Above it, the owing turn takes the interests off and owes their re-routes as one `EventAfterFollow.reroutes(RerouteBatch)` in `eventsAfterFollow`.

That event raises `followBarrier` (EngineFollow.swift:97-99) and never raises `followOwed` (:82-85), so the pseudo-follow hazards in `recordDeferredVerdict`'s and `publish`'s `away` and in `bringInbound` cannot arise.

Where each batch goes:
- Batches from a commit (`committed`) or a superseded publication (`publicationFailed .superseded`) are appended at the tail.
- A batch from a verdict's moved-before take-off (`replayVerdict` and the `.spaceFailure` replay) is put at the head, followed by the rest of its drain batch.

How a batch is replayed:
- Each drain turn spends the drain's shared `drainIDsLeft` (EngineFollow.swift:203). Each item costs `min(1 + layers since the batch, followIDsPerTurn)`.
- Each item goes through `reroute(...listing:)` (EngineDispatch.swift:1147), under the copy its chain lands on.

How the chain works:
- It starts at the owing turn's copy. It walks one `RerouteLayer` per apply adopted while a batch is owed (`adoptApplied`, EngineJobs.swift:1018).
- At each layer it keeps the target if that job was publishing, or had a verdict waiting that is not ahead of the batch. Otherwise it re-targets under the layer's copy.
- It stops at T21 or at a present target.
- A kept job that has since left its attempt's end falls back to the current copy (`waitingTarget`'s rule, EngineFollow.swift:1251-1263).

Holds, purges and lanes:
- While any batch is owed, no publication binds (`inboundBlocks || reroutesOwed`). The drain turn that empties the last batch resumes the held publications and clears the layers.
- A purge withdraws purged non-user items, as `withdrawPurgedJoins` does for joins.
- A 429 counts user items that land on its job (`followedLane`).

Invariants and supporting changes:
- The waiter and group invariant clauses accept owed items.
- The batch builder releases the run's claims on its items.
- `dropGroupMember` and `releaseRunClaim` become in-place.
- Site 2 zeroes the turn's ids when it owes, so the visit after the verdict becomes its rest (`followMoving`).

What is not added: any await, any follow state, any limbo index or any `rerouteIDsLeft`. `reroutesOwed` is derived from the events.

## mechanism

- 1. Types and state. Add `case reroutes(RerouteBatch)` to `EventAfterFollow` (EngineFollow.swift:1405-1433), with `endsDrainBatch` false (:1436-1443). A new EngineReroutes.swift holds two structs. `RerouteBatch` has `from: TransferID`, `copy: ValidatedManifest`, `items: MoveProgress` (the existing heap, EngineMoves.swift:20-89, with supersedes false), `owners: [InterestToken: JobInterest]` (lane and kind, assets empty), `withdrawn: Set<MoveItem>`, `firstLayer: Int` and `preceding: Set<TransferID>`. `RerouteLayer` has `copy`, `publishing: Set<TransferID>` and `waiting: Set<TransferID>`. EngineState (beside :108-112) gains `var rerouteIDsPerTurn = SyncEngine.followIDsPerTurn` (a seam no production path writes, like `followIDsPerTurn`) and `var rerouteLayers: [RerouteLayer] = []`. `MoveItem` (EngineMoves.swift:5) gains `Hashable`.
- 2. `var reroutesOwed: Bool` is `eventsAfterFollow.contains { if case .reroutes = $0 ... }`. It is read only between drain turns. Its readers are `inboundBlocks`, reached from EngineDispatch.swift:1032, EngineFollow.swift:843, :1273 and EngineCommands.swift:2064; `adoptApplied`; and `reroutesSettled` after the drain loop. None of these runs inside a drain's replay.
- 3. `rerouteBatch(items:owners:from:preceding:)` builds the heap with `MoveProgress.init` (EngineMoves.swift:30-39, O(n)). It sets copy = `state.applied` and firstLayer = `rerouteLayers.count`. It releases the run's claims on its run items in place (`state.run?.outstanding[from]?.subtract`, nil when empty), because `recordRunOutcome` wipes `outstanding[from]` (EngineRuns.swift:519) and the run clause (EngineCommands.swift:1812-1816) would otherwise name a removed job.
- 4. `oweReroutes(_:)` (sites 1 and 3) calls `deferToFollow(.reroutes(batch))` (EngineFollow.swift:233-236), whose stamp is `worldStamp()`. It then always calls `scheduleDrainFollowUp()` (EngineFollow.swift:379; `private` is dropped). That function guards itself. A follow-up that finds a follow owed returns at :189, and the follow's last turn drains at :160. Last, `notifyObservers`. The batch's `preceding` is `verdictsAfterFollow.keys` plus the transfers of the waiting `.spaceFailure` events: the verdicts ahead of it.
- 5. Site 1, `committed` (EngineDispatch.swift:1100-1139). After `bind` (:1106), count the unbound items U = the sum over interests of their ids with no location. If `U > 0 && captured.count + U > state.rerouteIDsPerTurn`, call `commitOwing` and then `pump`/`reconcileIdle`. Otherwise run the existing loop (:1107-1136) unchanged. `commitOwing` iterates `job.interests` unsorted. For each interest it calls `setInterest(nil)` when every id is unbound, else `subtractAssets(unbound)` (EngineState.swift:774, :801). It records `owners[token]`. For each unbound id it sets `refused ||= captured.contains(a)` when `applied.entry(for: a)?.transferID == transfer` (the existing test at :1121/:1125) and appends a `MoveItem`. Then it calls `resolveAll(transfer, .committed(locations)) { if refused { holdForManifest(transfer) }; oweReroutes(rerouteBatch(...)) }`. The closure runs after `removeJob` (EngineJobs.swift:611-628), and its `checkRunSettled` is then held by the barrier (EngineRuns.swift:576).
- 6. Site 3, `publicationFailed .superseded` (EngineDispatch.swift:1205-1211). After `transition(.queued)`, if the sum of `|interest.assets|` exceeds `state.rerouteIDsPerTurn`, call `supersedeOwing(transfer)`. Otherwise call `supersede(transfer)` unchanged. `supersedeOwing` does `removeAllInterests` and `removeJob` as at :1261-1262. In one unsorted pass it builds the items and the hold predicate of :1264. It calls `holdForManifest` when that predicate holds, then `oweReroutes`, `checkRunSettled` and `pump`.
- 7. Site 2 take-off (`takeOffMovedBefore`, EngineFollow.swift:551-568) returns `(items, owners)` instead of tuples. It computes `held = job.assets ∩ movedBefore` (:552) and calls `assets.subtract(held)` (:557). For each interest, unsorted, it computes `off = interest.assets ∩ held`. An emptied interest goes to `removeInterest` (EngineJobs.swift:339, reused: retire, claimHeld and run.held as today; `relane` is a no-op on a job whose verdict waits, EngineJobs.swift:285-295, so the order is immaterial). A partial interest gets `subtractAssets(off)`.
- 8. Site 2 verdict replays: `.spaceFailure` (EngineFollow.swift:346-356) and `replayVerdict` (:607-620). After the verdict, if `off.count > drainIDsLeft`, set `drainIDsLeft = 0`. The take-off then fills the turn, and `followAfterVerdict` (:586-593) leaves its whole visit as `followMoving`. Next, `followAfterVerdict` runs, and then `rerouteMovedBefore` returns a value. If `off.count <= drainIDsLeft`, it decrements the budget, re-routes at once in (token, asset) order (today's order) and returns nil. Otherwise it returns `rerouteBatch(..., preceding: [])`. `replay(_:)` (:344) now returns `RerouteBatch?`.
- 9. Drain loop (EngineFollow.swift:204-217): `let owed = withReading(stamp) { replay(event) }`. When `owed != nil`, insert `[.reroutes(owed)] + batch[(offset+1)...]` at index 0, with stamps `[stamp] + rest`, and break. Otherwise use the existing put-back (:211-216). After `drainingAfterFollow = false` (:218), call `reroutesSettled()` before the `followMoving` and `scheduleDrainFollowUp` tail (:219-229).
- 10. `replayReroutes(_ batch) -> RerouteBatch?` is the `.reroutes` case of `replay`. Let cost = `min(1 + rerouteLayers.count - firstLayer, state.followIDsPerTurn)`. While `drainIDsLeft >= cost`, it pops an item (`MoveProgress.popFirst`, EngineMoves.swift:52-62) and charges cost. It skips the item if `withdrawn` holds it. Otherwise it calls `reroute(token, interest: JobInterest(lane: owner.lane, kind: owner.kind, assets: []), asset:, from: batch.from, listing: rerouteListing(asset, of: batch))`. `reroute`'s own guards re-validate the owner: waiter :1170-1172, group :1176-1178, run :1181-1183, T21 :1151-1162, and `dropGroupMember`'s pending check. Joins are made at once, because `defersToFollow` is false while draining (EngineFollow.swift:103-105), under the owing turn's stamp (`decisionNow`). It returns nil when the heap is done, otherwise the rest.
- 11. `rerouteListing(asset, of batch)` is the chain. Start with `landed = batch.copy` and `target = landed.entry(for:)?.transferID`. For each layer in `rerouteLayers[firstLayer...]`: `guard let t = target, !isBound(asset, to: t) else { break }` (T21 or present). If `layer.publishing ∋ t`, or (`layer.waiting ∋ t` and `!batch.preceding.contains(t)`), set kept = true and continue. Otherwise set kept = false, landed = layer.copy and re-target. If kept, the target exists and `!isAtAttemptEnd(jobs[t])`, return `state.applied`. `isAtAttemptEnd` is factored out of `waitingTarget`'s switch (EngineFollow.swift:1255-1262), which then calls it. Otherwise return `landed`.
- 12. `reroutesSettled()` acts when `!reroutesOwed`: it sets `rerouteLayers = []` and resumes the `inboundWaits`, in sorted order, whose `!inboundBlocks` holds. The shape is that of EngineFollow.swift:1273-1275.
- 13. `inboundBlocks` (EngineFollow.swift:1159-1167) gains `return self.reroutesOwed` as its last term, after the `followMoving` and owed-move tests. The two existing resume sites (:843, :1273) already re-check `inboundBlocks`, so a publication stays held while a batch is owed.
- 14. `adoptApplied` (EngineJobs.swift:1018) gets a new first statement. If `reroutesOwed`, it appends `RerouteLayer` with `copy: manifest`. `publishing` is the `inFlight` jobs in verifying or committing, read as `bringInboundOntoPublications` reads them (EngineFollow.swift:1027-1032). `waiting` is `verdictsAfterFollow.keys` plus the waiting `.spaceFailure` transfers. The call sites are EngineRuns.swift:369 and EngineCatchUp.swift:223; at launch, EngineLifecycle.swift:399, no batch is owed.
- 15. Purge, in `withdrawPurgedJoins` (EngineCommands.swift:1049-1073). The early return at :1050 guards on `eventsAfterFollow` instead of `joinsAfterFollow`. A new `case .reroutes(var batch)` handles items that are not yet withdrawn, whose owner has lane < `.userInitiated` and kind != `.waiter`, and whose id `isPurged`. Groups get `dropGroupMember(token, asset, from: batch.from)`. A system owner gets `heals[asset] = nil`. Each such item goes into `withdrawn`, and the batch is written back.
- 16. `followedLane`'s event walk (EngineFailures.swift:821-836) becomes a switch. In the `.reroutes(let batch)` case it skips items whose token has a waiting removal (`laneEventsWaiting().withdrawn`). It takes `entry = rerouteListing(...).entry(for:)` and requires `sameTransfer(entry, job.entry)` and `!isBound(asset, to: entry.transferID)`. It then calls `raise(owner.lane)` and breaks at `.userInitiated`. Only the user lane chooses the policy: the sole caller is at EngineFailures.swift:346, and `retryPolicy` is at :632-634.
- 17. Invariants. The waiter clause (EngineCommands.swift:1707-1712) and the group clause (:1776-1782) also accept a (token, asset) that an owed batch from that transfer still holds. An `[MoveItem: TransferID]` map is built once per call from the unpopped, unwithdrawn items. In `followBarrierViolations`, `.reroutes` joins the switch's break list (:2027).
- 18. Copy-on-write fixes. `dropGroupMember` (EngineJobs.swift:594-604) becomes in place: guard `groups[token]?.pending[asset] == transfer`, then `groups[token]?.pending[asset] = nil`, then the settled check on the stored group. Today one group's T21 of 10,000 copies `pending` per member, O(N²). `releaseRunClaim` (EngineRuns.swift:505-512) becomes in place: `state.run?.outstanding[transfer]?.remove(asset)`, nil when empty. Today it copies `outstanding` per call whenever the key exists.
- 19. Shutdown adds nothing. `drainEverything` resumes the held publications (EngineShutdown.swift:117; `publish` returns at `isRunning`), clears the events and so the batches (:118), and answers every waiter (:52-66) and group (:68-73). The spawn-refused branch of `scheduleDrainFollowUp` (EngineFollow.swift:390-399) clears them the same way. Stale layers die with the engine.
- 20. BenchSync. `timeCommit`'s window (BenchSync.swift:3256-3262) waits for `jobExists(O) || barrierUp(engine)` (:3415) and reads `rerouted` after it. `movedBeforeDrain` already waits for `verdictOrBarrier` (:3400), which includes `followBarrier`. Add three release cases, each checked best-of-three against `c2Budget`, with per-turn timings taken inside the actor by `releaseOneHeldFollowOrDrainTurn`: `supersededRerouteTurns` (site 3), `commitRerouteWaitersTurns` (site 1 with one user waiter per id) and `movedBeforeDrainWaitersTurns` (site 2 with one waiter per id).
- 21. Docs. Extend RE-S48's text at EngineDispatch.swift:1035-1041 to name the batches. The ADR draft records the chain, the hold and the residuals.

## invariants

- Waiter clause (EngineCommands.swift:1707-1712). A waiter whose record names `from` holds no interest there while its item is owed. Exemption: the item (asset, token) is unpopped and unwithdrawn in a batch whose `from` is that transfer.
- Group clause (EngineCommands.swift:1776-1782). `pending[asset]` keeps naming `from` while the item is owed. Same exemption. Purged items leave `pending`, through `dropGroupMember` from `from`.
- Run clause (EngineCommands.swift:1812-1816). No exemption is needed: `rerouteBatch` releases the run's claims on its items. `checkRunSettled` cannot settle meanwhile (`!followBarrier`, EngineRuns.swift:576).
- The 'events wait for a follow but nothing drains' clause (EngineCommands.swift:2006-2008) stays clean. `oweReroutes` schedules a drain follow-up, and the drain reschedules while events remain (EngineFollow.swift:223-225).
- The switch in `followBarrierViolations` (EngineCommands.swift:2016-2030) is exhaustive with `.reroutes`. The `joinsAfterFollow` equality clause (:2031-2033) is unaffected: items are not joins.
- Stamps and world history (EngineCommands.swift:2034-2036). Every batch event has its stamp: `deferToFollow`'s at sites 1 and 3, the verdict's at site 2's put-back. The history is ended only when the barrier is down (EngineFollow.swift:228).
- Stranded publication waits (EngineCommands.swift:2064-2067). `inboundBlocks` is true while a batch is owed. `reroutesSettled` resumes, in the turn that empties the last batch, every wait nothing else blocks.
- No interest and no claim (EngineCommands.swift:1729-1736). Sites 1 and 3 remove the job in the owing turn. Site 2's take-off reuses `removeInterest`, which retires the job or records `claimHeld`.
- Interest counts (EngineCommands.swift:1724-1727). `setInterest`, `subtractAssets` and `removeInterest` keep `interestCounts`.
- `unfollowed` (EngineCommands.swift:1744-1749). Owed items are on no job. A join replayed under an older listing is recorded by `noteJoin` (EngineJobs.swift:183-188), as an owed move's join is.
- `heldForManifest` with no catch-up (EngineCommands.swift:1818-1820). `holdForManifest` schedules one (EngineCatchUp.swift:145-151). `manifestCaughtUp` may release while batches are owed, since `followOwed` excludes them; that is correct, because the copy has caught up.
- RE-S48 (EngineDispatch.swift:1035-1047). A held publication stays verifying at its epoch. No admission happens behind the barrier, a verifying job is never retired, and withdrawals wait.
- F-28, no admission behind the barrier (EngineDispatch.swift:95-108). Batches raise `followBarrier` through `eventsAfterFollow`. No start, park or fail-fast answer reads a half-re-routed state.
- R-SYN-5. A 429 decided while a batch is owed reads the user lane of any user item that lands on its job (`followedLane`, step 16).
- R-SYN-11 and space safety. No bytes are admitted while a batch is owed. Space verdicts, `.spaceSweep` judgements and ENOSPC rooms are decided after the batch, on the interests it left. A kept target's ENOSPC verdict answers its items.
- S3-R15 decision instants. Items replay under the owing turn's stamp (`withReading`, EngineFollow.swift:205), so their joins' request times and world view are the owing instant's.

## events_between_turns

- A later apply (`applied`, EngineRuns.swift:363-369) or a catch-up's `followStoreView` (EngineCatchUp.swift:207-231). `adoptApplied` appends a layer (copy, publishing, waiting). The apply's follow runs before the drain (EngineFollow.swift:189) but cannot see the items: they are on no job, and `findInbound` walks the jobs' ids. The chain applies the layer at replay: keep, re-target, T21 or present.
- A 429 on any job (`throttled`, EngineFailures.swift:337-352). It defers, deciding now on `followedLane`; the batch walk counts a user item that lands on the job. Its park replays after the batch and fails fast on the interests the items joined.
- A 503 or other attempt failure, or a timeout or 404 (`defersFailure`, EngineFollow.swift:449-469). It defers behind the batch. `recordDeferredVerdict` puts no owed item in `movedBefore`. A later layer records the job as waiting; it is kept unless the verdict is in `preceding`. Items that land on it join the failed job (`relane` is a no-op, EngineJobs.swift:285-295) before its verdict answers them, and `followAfterVerdict` then moves any a later apply moved.
- A waiter cancel (`withdraw`, EngineCommands.swift:176-192). The waiter is answered `.cancelled` at once, its record is kept with a nil continuation, and the `.removal` is deferred behind the batch. The item re-routes (`reroute`'s guard finds the record), and the removal then removes it from the job the record names (EngineFollow.swift:734-741). This is precedent (3), draft :159-160.
- A group release (`performReleaseGroup`, EngineCommands.swift:358-383). The record goes at once. Its removals, at once or in `continueReleases`, find no owed interest. At replay, `reroute`'s group guard (EngineDispatch.swift:1176-1178) and `dropGroupMember`'s guard skip the item.
- A run's end or a new run. Nothing settles behind the barrier (EngineRuns.swift:576). `reroute`'s run guard (EngineDispatch.swift:1181-1183) skips the items of a run that is gone. Their claims were released at the owing turn.
- A purge (`withdrawPurged`, EngineCommands.swift:992-1037). The batch walk withdraws purged non-user, non-waiter items, drops their group members against `batch.from` and forgets their heals. User items and waiters stay. Bindings the purge drops (:1084) are read at replay (present drift, residual).
- A publication start (`publish`, EngineDispatch.swift:1002-1047), of a target or of any job. `inboundBlocks` holds it, verifying, until the last batch is done, so its binding includes every item that lands on it. `reroutesSettled` resumes it.
- A commit of another job. It binds and answers at once. Its unbound ids re-route at once, as joins behind the batch, or owe a second batch at the tail. An item whose target that job was lands on a fresh job of the content, as an interest that joined after the binding would have done.
- A superseded publication of another job. It re-routes at once or owes a batch. Items that targeted it land on a fresh job of the content, held while `holdForManifest` keys its transfer.
- An ENOENT on a cancelled attempt (EngineDispatch.swift:1221-1229). The job is re-queued at once. The pump is blocked, and a later layer records it as not publishing.
- A space sweep (`sweepSpaceParked` and `advanceFollowForSpaceSweep`, EngineFollow.swift:1315-1320). With no follow owed it runs a drain turn with a full budget, which advances the batch. Its own verdicts wait as `.spaceSweep` events behind it.
- A new request, ensure, join or run materialisation (`addInterest`, EngineJobs.swift:110-116). It is deferred as a `.join` behind the batch, in arrival order.
- A conditions edge, a re-admission, an unblock, a retry falling due or a throttle-answer pass. Each is a deferred event behind the batch.
- A catch-up landing (`manifestCaughtUp`, EngineCatchUp.swift:250-276). It releases `heldForManifest`. Later items follow the caught-up copy, as a layer when one was adopted.
- An eviction, a forgotten binding or `dropBindings`. These change `isBound` at replay (present drift, RR-16 family or timing).
- Another owing site. Its batch has its own `firstLayer` and `preceding`, and goes at the tail (sites 1 and 3) or the head (site 2).
- Shutdown (`drainEverything`, EngineShutdown.swift:50-143). Held publications are resumed (:117), the batches are dropped with the events (:118), and every waiter and group is answered (:52-73).
- A refused follow-up spawn while shutting down (EngineFollow.swift:390-399). The events, and with them the batches, are cleared.

## answer_equality_argument

1. Below the thresholds nothing changes. The existing code runs: EngineDispatch.swift:1107-1136 and :1211, and site 2's at-once re-routes in (token, asset) order. So every existing test keeps its visit-first answers in both LaneDropVisit orders.

2. Above the thresholds, the batch takes the items' place in arrival order. Sites 1 and 3 append it. Site 2 puts it at the head, ahead of its drain batch's rest, and the rest always returns to the head. So every input that arrived after the owing instant and waits meets the state the re-routes left, as a visit-first engine's inputs met the interests already re-routed. That covers joins, removals, verdicts, 429 parks, space failures, conditions, re-admissions, retries and sweeps. No admission, park or fail-fast is decided meanwhile (EngineDispatch.swift:95-108).

3. Items replay under the owing turn's stamp. Their joins' times and world view are the owing instant's, as at once.

4. Each input that applies at once even behind the barrier is reproduced:
- Applies, by the chain. A visit-first engine's visit at that apply passed a job that was publishing or had its own verdict waiting (RR-14, S3-R21 item 4), and moved the rest under its copy. T21 and present answers come from the same chain. A verdict ahead of the batch was given before it in a visit-first engine, so it keeps nothing (`preceding`).
- Publication starts, by the hold. No binding is captured while an item could still land, so the binding includes it, as it included the interest already joined in a visit-first engine.
- A kept job that ended, by the final validation. It follows the copy as it stands, as that engine's interest followed its content when the job ended (the `waitingTarget` precedent, EngineFollow.swift:1236-1250).
- Commits and supersedes of targets, by the fresh job created at replay. That engine's interest had joined after the binding.
- Purges, by withdrawal (the PROBE-C13-PURGE-JOIN precedent).
- Releases, run ends and answered owners, by `reroute`'s guards.
- Cancels, by the removal waiting behind the batch (precedent (3)).
- A 429's lane, by the batch walk (R-SYN-5).

5. What remains is allowed:
- order: the heap's (asset, token) order and the jobs' creation order (S3-R16 item 2);
- places and tickets taken at replay at the owing instant;
- timing: publications held, and targets admitted, a few turns later (the RR-19 and RR-23 class);
- an extra request when an at-once withdrawal retires a job an owed item would have kept (the RR-16 family; the removal-deferral residual at EngineJobs.swift:335-338);
- present decisions read at replay (timing or RR-16);
- old-view fail-fast decisions (S3-R17 item 2).

Both LaneDropVisit orders create the batch at the same arrival. The replay depends only on the queue and the layers, so each order keeps the answers the at-once code gave.

## liveness_argument

Every batch drains, by four routes:
- `oweReroutes` schedules a drain follow-up.
- The drain reschedules while events remain (EngineFollow.swift:223-225).
- A follow owed first drains in its last turn (:160).
- A space sweep runs a drain turn (:1315-1320).

Every fresh drain turn pops at least one item, because the cost is capped at `followIDsPerTurn`, the fresh turn's budget. So N items need at most N turns, and 20 at the default. A follow that runs first ends as before, bounded per turn. No new await is added.

The only new wait is the existing publication wait, now also held by batches. It is resumed in four places:
- `reroutesSettled`, in the drain turn that empties the last batch;
- the two existing resume sites (:843, :1273), which re-check `inboundBlocks`;
- shutdown (`releaseInboundWaits`, EngineShutdown.swift:117).

The stranded-waits clause (EngineCommands.swift:2064-2067) checks this between turns. There is no cycle: a held publication waits for the batches, the batches for the drain, and the drain for the follow. The follow makes its moves and visits without waiting on any publication.

Every owner is settled:
- Each owned item is re-routed, answered T21 or present, or skipped by `reroute`'s guards. In the guard case its owner was already settled.
- A withdrawn item's group member was dropped against `from`, which can complete an ensure, or its heal was forgotten.
- Shutdown answers all owners.

The run is checked at the drain's end (EngineFollow.swift:226). Held-for-manifest jobs have a scheduled catch-up (EngineCatchUp.swift:146-151). The pump runs at the drain's end (:227). Layers are cleared by `reroutesSettled`, and nothing waits on them. Only tests hold drain follow-ups.

## c2_argument

The budget is 10 ms (`c2Budget`). Every figure below is UNCONFIRMED: nothing was built or measured.

Converged shape (10,000 ids onto one content; one prefetch group or many):
- Site 1's owing turn binds O's one id. Its take-off is one unsorted pass: a location lookup and a copy lookup per id, `setAssets`/`setInterest`, the item appends, a heap build and few owners. That is about 2-4 ms, against 48.68 ms today, whose cost is 10,000 re-routes at about 4.4 µs each.
- Site 2's verdict turn is a set-operation take-off of about 2-3 ms. Its visit after the verdict gets zero ids when the turn owes (step 8).
- Site 3's owing turn is items plus the hold predicate, about 2-3 ms.
- Replay turns re-route at most 512 items, sharing `drainIDsLeft` with the visits after verdicts. Joins onto one job are in place since cycle 18, at about 5 µs each (EngineMoves.swift:120-122), so about 3 ms plus the drain's at most 512 events, about 1 ms. T21 of one group is O(1) per item once `dropGroupMember` is in place.

Divergent shape (10,000 contents):
- Owing turns are as above; the owing work does not depend on the target.
- Replay turns create at most 512 jobs. The follow's 512-move turns of `divergenceTurns` already fit.

User waiters, one per id:
- Site 1's owing turn handles 10,000 interests at O(1) each with no allocation for whole ones, plus 10,000 `owners` inserts: about 3-6 ms.
- Site 2's take-off makes 10,000 `removeInterest` calls (`relane` is a no-op, `notifyObservers` returns with no observers): about 3-6 ms. The zeroing rule keeps the 512-id visit, about 7.2 ms (`userSharedApplyTurns` measured 7.18 ms per 512), out of that turn.
- Replay turns are at most 512 × 14 µs, about 7.2 ms, plus events: the tightest margin.

Turns between the owing turn and the replay:
- An apply's layer capture is O(in-flight + verdicts + events).
- A purge's batch walk is O(items), about 2-3 ms, beside the existing job walk.
- A 429's batch walk is O(items × (1 + layers)).
- `inboundBlocks` and `reroutesOwed` scans are O(events) per publication start or resume.
- Shutdown's cost is pre-existing.

Pins:
- BenchSync's three existing cases, with `timeCommit`'s window extended to the barrier.
- Three new release cases: site 3, site 1 with one waiter per id, and site 2 with one waiter per id.
- Deterministic per-turn counts with `rerouteIDsPerTurn` and `followIDsPerTurn` set to 4.

## new_branches

- N1. The site-1 owing condition `U > 0 && captured.count + U > rerouteIDsPerTurn`. Test RR21-COMMIT-BOUND, both orders: seams set to 4 and drain follow-ups held. C publishes zz-c and 2 ids; v4 maps 3 waiters' ids to N while C is at the store; the commit binds 3 and leaves 3 unbound. Assertions: after the commit turn, N holds 0 of them and one `.reroutes` event waits, with invariants clean; after one drain turn, N holds 3; each waiter is served N's content. Mutants: dropping `captured.count +` makes the re-routes happen at once (N holds 3 after the commit), failing; dropping `U > 0` leaves an empty `.reroutes` event after a 5-id commit with no unbound id, which the test asserts against.
- N2. The `holdForManifest` call on the owed commit path. Test RR21-COMMIT-REFUSED: the store holds a newer manifest (as in the F-20 tests) and refuses at least 3 captured same-content ids above the threshold. C's fresh job stays held until the catch-up (C starts once), and no waiter gets `.notFound`. Mutant without the hold: C starts twice.
- N3. The site-3 call-site threshold. Test RR21-SUPERSEDE-BOUND: C's publication of 5 waiters' ids is held at its store unit; v4 maps all 5 to N; the store throws `.superseded`. N holds 0 after that turn, then 4 and 1 after the drain turns; each waiter is served N. Mutant that always supersedes at once: 5 after the failure's turn.
- N4. The hold in `supersedeOwing`. Test RR21-SUPERSEDE-HELD: the store's newer manifest maps the ids elsewhere while the copy still maps them to C. Items land on a fresh held job of C, then follow the catch-up; C is never restarted. Mutant without the hold: C starts twice.
- N5. Site-2 zeroing (`off.count > drainIDsLeft` sets it to 0). Test RR21-VERDICT-ZERO with `followIDsPerTurn` = 4: J's 503 waits with 6 members moved before it and moved back, and v5 then moves 3 more. The verdict turn moves 0 ids (`followMoving` holds 3); the follow turn moves 3; the batch drains 4 then 2. Mutant without zeroing: 3 ids move in the verdict turn.
- N6. The site-2 at-once rule and its decrement. Test RR21-VERDICT-ATONCE with the budget at 4: three verdicts wait in one drain batch, each with 2 moved-before items. J1 and J2 re-route at once in turn 1 (4 in all); J3 is owed and re-routes 2 in turn 2. Mutants: always owing re-routes 0 in turn 1; dropping the decrement re-routes 6 in turn 1.
- N7. The head put-back `[batch] + rest`. Test RR21-HEAD-ORDER: J's verdict owes 5 items targeting N, and N's own 404 deferred behind J's verdict. Visit-first, the items join N before its 404 and get `.notFound`. Mutant appending at the tail: N's 404 replays first and retires N, the items create a fresh N and are served (a second N start).
- N8. The replay budget `drainIDsLeft >= cost`. Test RR21-REPLAY-BOUND: a commit owes 10 items at a budget of 4; the drain turns re-route 4, 4 and 2. Mutant without the check: 10 in one turn.
- N9. The layer cost `1 + layers`. Test RR21-LAYER-COST: v5 and v6 are adopted while a 4-item batch is owed; at cost 3 the drain re-routes 1 item per turn. Mutant with cost 1: 4 in the first turn.
- N10. The cost cap `min(..., followIDsPerTurn)`. Test RR21-LAYER-CAP: 4 layers at a budget of 4 give 1 item per turn. Mutant without the cap: 4 released turns later the batch still holds 4, which the per-turn count catches without hanging.
- N11. The replay's `withdrawn` skip. Test RR21-PURGE: a commit owes 5 prefetch-group items, an ensure group's items, a heal's item and a user waiter's item; a purge (`.all`) runs before the drain. Afterwards no job exists for the purged targets, the heal is forgotten, the ensure resumes, and the user waiter is served. Mutant without the skip: `reroute` resurrects `pending` (EngineDispatch.swift:1179) and creates jobs.
- N12. The purge walk in `withdrawPurgedJoins`. RR-21-PURGE kills each mutant: (a) dropping the lane/kind filter withdraws the user item, which is never answered; (b) dropping `dropGroupMember(from:)` leaves the ensure unsettled and fires the group clause once the batch is gone; (c) dropping the heal clear leaves `heals[asset]` set; (d) keeping the `joinsAfterFollow` guard withdraws nothing, since no join waits.
- N13. Chain re-target. Test RR21-CHAIN-MOVE: items are owed to N, which is queued; v5 maps them to M while owed; they land on M. Mutant without layers: they land on N (N starts, or they are served N's content).
- N14. Chain publishing keep. Test RR21-CHAIN-PUBLISHING: N was admitted before the commit; its download ends while the batch is owed, so its publication is held; v5 maps the ids to M. Items are kept on N, bound and served N. Mutant: served M.
- N15. Chain waiting keep. Test RR21-CHAIN-VERDICT: N's 404 defers behind the batch, then v5 maps the ids to M. Items join N before the 404 and get `.notFound` (visit-first). Mutant: served M.
- N16. The `preceding` exclusion. Test RR21-CHAIN-PRECEDING: N's 404 waits ahead of the batch; v5 maps the ids to P, which was admitted earlier and is now held at publication; v6 maps them to Q. Visit-first they are served P. Mutant: kept on N, the final validation sends them to the current copy and they are served Q.
- N17. The chain's T21 stop. Test RR21-CHAIN-T21: v5 unlists the ids while owed and v6 re-lists them at M. Waiters get `.notFound`. Mutant: served M.
- N18. The chain's present stop. Test RR21-CHAIN-PRESENT: v4 reuses D's blob, so D is present when the commit owes; v5 then maps the ids to M. They are answered from the store at D. Mutant: they join M and are served M.
- N19. The final validation. Test RR21-CHAIN-ENDED: N's binding was captured before the commit, and v5 maps the ids to M while N publishes; N commits before the drain. The items land on M. Mutant using listing = `copy`: a fresh N job and a second N start.
- N20. The global hold `|| reroutesOwed`. Test RR21-HOLD: N was admitted before the commit, the items target N, and N's download ends while they are owed. N publishes once and binds them (one N start). Mutant without the hold: they are unbound at N's commit and a fresh N starts.
- N21. The resume in `reroutesSettled`. RR21-HOLD catches it: without the resume, N never commits and the stranded-waits clause fires after the last drain turn.
- N22. The layer append (only while owed) and the layer clear. Test RR21-LAYERS reads `rerouteLayers.isEmpty` after an apply with no batch owed and after the last batch's drain turn. Mutants that always append or never clear leave it non-empty.
- N23. The batch walk in `followedLane`, including the lands-on-job test. Test RR21-LANE-USER: a user waiter's item targets N, which otherwise holds only a prefetch interest; N's 429 arrives while owed, with a Retry-After above `interactiveMaxWait`. It is decided on `interactiveRetry`, and the waiter gets `.serverUnavailable` at the replayed park. Mutant without the walk: the background policy decides. Test RR21-LANE-ELSEWHERE, where the item lands on M, kills an 'always lands' mutant.
- N24. The `followedLane` skip of waiting removals. Test RR21-LANE-CANCELLED: the user waiter is cancelled before the 429, so the background policy decides. Mutant: the user policy.
- N25. The `followedLane` present skip. Test RR21-LANE-PRESENT: the user item's id is bound at N's content while another id keeps N downloading. The background policy decides. Mutant: the user policy.
- N26. The waiter-clause and group-clause exemptions. Test RR21-INVARIANTS: after the owing turn, with a waiter item and a group item owed and drain follow-ups held, `invariantViolations()` and the follow-barrier rules are clean. Mutant: either clause reports a violation.
- N27. The bulk release of the run's claims in `rerouteBatch`. Test RR21-RUN: a run interest's 5 ids, all moved away, are owed at a commit. Invariants are clean between turns, and the run report counts them once their content commits. Mutant: the run clause fires because `outstanding[C]` names a removed job.
- N28. The partial-versus-emptied split in the site-2 take-off. Test RR21-TAKEOFF-PARTIAL: J holds a group with 2 ids moved before and back plus 1 unmoved, and its 503 retries. The unmoved id stays on J and the 2 re-route. Mutant that always calls `removeInterest`: the third id loses its interest and the group clause fires. The emptied branch is already reached by EngineFollowBarrierMovedBeforeTests (a job left empty is retired before its verdict).
- No branch, but statements a drop would remove. The `scheduleDrainFollowUp()` call in `oweReroutes` is dropped-and-killed by RR21-COMMIT-BOUND in both orders: with no follow owed, nothing drains and the 'events wait' clause fires. The in-place `dropGroupMember` and `releaseRunClaim` change cost only and are pinned by the BenchSync cases.

## supersede

Site 3 is treated at its call site, not inside `supersede`.

In `publicationFailed`'s `.superseded` case (EngineDispatch.swift:1205-1211), after `transition(.queued)`, the engine counts the job's interest-ids. Above `rerouteIDsPerTurn` it calls `supersedeOwing(transfer)`, which:
- removes the job as `supersede` does (EngineDispatch.swift:1261-1262);
- holds the transfer for a catch-up when the copy still maps an id to the job's content, using the predicate at :1264 evaluated in the same unsorted pass that builds the items;
- owes the batch at the tail, with `preceding` read now;
- then calls `checkRunSettled` and `pump`, which the barrier makes no-ops.

At or below the threshold it calls `supersede(transfer)` unchanged, so cycle 13's behaviour and its tests hold.

The follow's `move` (EngineFollow.swift:931-945) keeps calling `supersede(settling: false, listing:)` at once:
- that visit is the follow's own, and its joins must be made in the visit (`inFollowVisit`);
- large moves already go through `startMove`/`continueMove` (EngineMoves.swift:140-226);
- owing it would put a visit behind events that a visit-first engine applied after it.

The many-tokens-per-id case of `move` (one id counted once, its interests unbounded) is pre-existing and outside RR-21.

## fixer_design_assessment

The fixer's core is right:
- A drain event in `eventsAfterFollow` reuses the barrier's guarantees: arrival order, no admission, and decision instants.
- Spending the drain's shared `drainIDsLeft` is necessary for C2 in the one-waiter-per-id shape. Separate budgets allow about 512 visit ids plus 512 re-routes in one turn, about 14 ms.
- Shutdown dropping the batches is right.
- Supersede does need the same treatment.

Flaws and their repairs:
1. The batched pairs lack lane and kind, which are gone once the interests are taken off. Repair: `owners`.
2. Queueing outside the drain needs a scheduled drain. Otherwise EngineCommands.swift:2006-2008 fires and nothing advances.
3. Site 2's batch must go at the head, ahead of its drain batch's rest, not at the tail.
4. There is no at-once path below a threshold. Without one, every existing commit, supersede or moved-before test changes timing (G3 risk). Repair: keep the existing code below `rerouteIDsPerTurn` and the drain's ids.
5. Sorting at the owing site costs milliseconds at 10,000. Repair: the existing `MoveProgress` heap.
6. A limbo index is redundant. Repair: derive `reroutesOwed` from the events, and the invariants' set from the batches.
7. "followedLane by the rule of the job they left" is wrong. That job is gone at sites 1 and 3, and at site 2 the items are no longer its moved-before set. The walk must read where each item lands, by the same chain.
8. "Join under the current copy" is RR-14 class, which is blocking (S3-R21 item 4). Repair: per-layer keeps for publishing jobs and for jobs with a waiting verdict not ahead of the batch, plus `waitingTarget`'s final validation. T21 and present answers must come from the same chain, or an item a later apply unlisted and re-listed would be joined.
9. The per-job hold "onto or off its job" cannot name targets that change with later applies without per-item work. Repair: a global hold, which also needs a resume site (`reroutesSettled`), since the existing resume sites fire only on moves and rests.
10. The `supersede` treatment must stay out of the follow's `move`.

Omissions, now covered:
- purge (the PROBE-C13-PURGE-JOIN class);
- the waiter and group invariant clauses;
- `recordRunOutcome` wiping limbo run claims (EngineRuns.swift:519). Repair: bulk release.
- the O(N²) copy-on-write in `dropGroupMember`, and the per-call copy in `releaseRunClaim`;
- the commit's mixed shape (count the binding);
- site 2's combined take-off plus visit turn (zeroing);
- BenchSync's `timeCommit` window, which waits only for `jobExists(O)`.

`rerouteIDsPerTurn` is kept as the owing seam for sites 1 and 3; `rerouteIDsLeft` is not needed.

## risks

- The one-waiter-per-id site-2 owing turn, 10,000 `removeInterest` calls, is estimated at 3-6 ms (UNCONFIRMED). If `movedBeforeDrainWaitersTurns` fails, the fallback is a bulk drop of emptied interests, whose replicated tail branches (run.held, claimHeld, retire) would each need a test.
- The replay's one-waiter turn is about 7.2 ms plus up to 512 events. This is the narrowest margin, about 2 ms (UNCONFIRMED).
- The commit's own binding of 10,000 user waiters is pre-existing and unmeasured; the `captured.count` term keeps the re-routes out of that turn but not the binding.
- Layers grow with every apply adopted while a batch is owed. Each retains a manifest (memory). The replay is bounded by the cost rule, but `followedLane`'s walk is O(items × layers) in a 429's turn. Hundreds of applies during one batch are unmeasured.
- Present drift. An item's `isBound` is read at replay, not at the owing instant, so bindings forgotten or added in between change present answers (timing or RR-16 family).
- Double hop. When a kept job ends, the final validation follows the current copy. If the content's next job would itself have been kept by a later layer, that is missed. This is the same approximation the `waitingTarget` precedent accepts.
- The retire corner. An at-once withdrawal retires a job that an owed item would have kept; the replay then makes an extra request (RR-16 family).
- Releasing run claims lowers `run.outstanding.count`. `materializeRun` (EngineRuns.swift:484) can then materialise fetches early while items are owed (order or timing).
- System re-attachment items: `releaseSystemReattachments` (EngineRuns.swift:455-472) does not see them. This mirrors waiting joins (`stillWants(.system) == true`, EngineFollow.swift:724-725).
- The global hold delays unrelated publications by up to ceil(N/512) drain turns. This widens the apply-before-bind window (RR-19 class timing).
- The derived `reroutesOwed` is false during a drain's replay, because the batch being replayed is outside `eventsAfterFollow`. It is correct only because its four readers run between drain turns (grep).
- G3. Site 2's at-once rule reads `drainIDsLeft`, which can be small in a follow's last turn even at the default seam. A moved-before test whose follow spent most of the turn would switch to the owed path, changing timing only (UNCONFIRMED that none does).
- Pre-existing and outside RR-21. Below the threshold, at-once re-routes behind a follow barrier become `.join` events, which `replayJoin` (EngineFollow.swift:704-707) re-routes under the current copy. That is RR-14 class; put it to the orchestrator.
- Old-view fail-fast decisions, and origin gates changing during the barrier: S3-R17 item 2, non-blocking.

## size_estimate

Source: about 450-550 lines.
- A new EngineReroutes.swift of about 280-330 lines: the types, `rerouteBatch`, `oweReroutes`, `commitOwing`, `supersedeOwing`, `replayReroutes`, `rerouteListing`, `reroutesSettled`, `reroutesOwed`, the layer capture, and the purge, lane and invariant helpers.
- About 150-200 lines of edits across EngineFollow (the enum, the drain loop, the replay returns, the take-off, the at-once/owed split, `inboundBlocks`, `isAtAttemptEnd`, visibility), EngineDispatch, EngineCommands, EngineFailures, EngineJobs, EngineRuns, EngineMoves and EngineState.

Tests: about 1,100-1,500 lines, in one new suite of about 28 both-orders tests. It reuses the fixtures of the MovedBefore, Publication and SharedMove suites. No pre-existing test changes, so no MIGRATION.md entry.

Bench: about 200-300 lines, for the `timeCommit` window and three release cases.

Docs: the ADR draft section, and RE-S48's text.

## state_added

- `EventAfterFollow.reroutes(RerouteBatch)`, with `endsDrainBatch` false.
- `RerouteBatch`: `from`, `copy`, `items` (the `MoveProgress` heap), `owners: [InterestToken: JobInterest]` (lane and kind only), `withdrawn: Set<MoveItem>`, `firstLayer: Int` and `preceding: Set<TransferID>`.
- `RerouteLayer`: `copy`, `publishing: Set<TransferID>` and `waiting: Set<TransferID>`.
- `EngineState.rerouteLayers: [RerouteLayer]`, appended only while a batch is owed and cleared by `reroutesSettled`.
- `EngineState.rerouteIDsPerTurn`, the owing-threshold seam for sites 1 and 3 (default `SyncEngine.followIDsPerTurn`, 512; never written in production).
- `MoveItem: Hashable`.
- The derived `SyncEngine.reroutesOwed` (no storage).

## state_removed

- No stored state is removed. `takeOffMovedBefore`'s `[(token, interest, asset)]` return becomes `(items: [MoveItem], owners)`, and `rerouteMovedBefore` returns `RerouteBatch?`.
- Deliberately not added, compared with the fixer's draft and an earlier plan: a limbo index, `rerouteIDsLeft`, any `followOwed` term, a per-job hold map, and a run-clause exemption.

## unconfirmed

- Every millisecond figure and per-item cost: owing turns at 2-6 ms, replay turns at up to about 7.2 ms, the purge and lane walks. Nothing was built or benchmarked, per the task.
- That no existing unit or seam test reaches a threshold. Six suites set `followIDsPerTurn`; their `movedBefore` hits are setup comments, none uses `.superseded`, and large counts found by grep are byte sizes. This rests on grep only.
- That no moved-before test at the default seam meets a drain turn with fewer ids left than its take-off.
- That every publication-failure exit, including `integrityFailed` and the paths through `retryLater`, defers behind a batch via `defersFailure`.
- That `follow(transfer, ids: 0, afterVerdict: true)` leaves the whole visit as `followMoving`.
- That `inboundBlocks`, `reroutesOwed` and `adoptApplied` are never reached during a drain's replay beyond the call sites grepped.
- That `ValidatedManifest`, `MoveProgress` and `JobInterest` are inferred `Sendable` for the payload of `EventAfterFollow: Sendable`.
- The per-call costs of `notifyObservers`, `offerRunProgress`, `countRunFetched` and `answerWaiterFromStore` inside replay turns, with observers absent.
- That the dictionary-order iteration in the take-offs changes nothing observable. `relane` is confirmed a no-op on a job with a deferred verdict; the order of notifications is not.
- Whether `materializeRun`'s early materialisation while claims are released is visible to any test.
- That no path ends a run while the barrier is up, other than shutdown.
- The site-3 bench's setup: that releasing O's held store unit after v4 maps every id away makes the store throw `.superseded`.
- That the concentration bench's window never holds drain follow-ups, so the batch drains inside `timeCommit`'s extended window.
