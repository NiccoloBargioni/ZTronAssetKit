# integrate:rr21

Read-only analysis for ruling S3-R26 (workflow wf_c114d84e-f12, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## design_source

The section starts from the judge's synthesis in /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/judge-rr21.md: design_spec steps 1-14, the invariants, tests T1-T18, must_not and the 10 open questions. It does not start from design-minimal.

Grafts:
- design-fixer step 8 / N5: zero drainIDsLeft when a take-off does not fit (via critic-rr21-cost).
- design-reuse: the MoveProgress heap and stillWants in field form (integrate interaction 4).
- design-minimal: the call-for-call argument for the fit path, and its C2 fallback.

Critique amendments applied:
- critic-rr21-answers: the prune guard; the RR21-HOP, RR21-WINDOW-GATE and RR21-PRESENT-PRUNE pins; S3-R24 item 5 applied to callers' answers.
- critic-rr21-compose: the hasWork disjunct; per-(token, asset) clauses; readers before writers; T-COMPOSE; run-shape pins; A7's `return .userInitiated`; run items checked by `run?.token == token`.
- critic-rr21-cost: the fit charge; zeroing; removal of the `left != nil` disjunct; BenchSync windows that end at the last answer.

Kept consistent with integrate-c21.md:
- A: VerdictKey, joinsBehindVerdicts, A6's order at batch formation, A11.
- B: B5 moveItems/holdings; B4's index releases are counted.
- C Phase 1: C5, C10 and C11 are in place; C1 and C3 are folded into committed's rewrite.

Every step was re-verified read-only in /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f at 8e1fb24. Anchors take the form Sources/ZTronAssetSync/Engine/<file>:<line> at 8e1fb24. Within one entry, later anchors are shortened to <file>:<line>.

New in this section, beyond the judge and the critics:
- a guard in checkRunSettled on reroutesWaiting, which closes a mid-drain run-settlement hole;
- the reroutesWaiting counter itself;
- site 2 decides before its visit (reservation or zeroing);
- the take-off removes whole interests in ascending token order, which keeps heldLane deterministic;
- the purge arm removes items from the batch, so no withdrawn set is needed;
- four simplifications removed by S3-R16 item 3: the `!drainingAfterFollow` conjunct, the guard on the layer append, withdrawPurgedJoins' early return, and the !inboundBlocks filter.

## item

RR-21 (WP-F, Stage 3 close-out cycle 21; it feeds ruling S3-R26) bounds the three O(N) re-route sites:
- committed's re-routes: 47.99-49.34 ms;
- the drain's take-off of moved-before ids: 47.03 ms;
- the .superseded exit through supersede: 41.09 ms (PROBE-C20C-SUPERSEDE-C2).

These are the rows at docs/adr-drafts/s3f.md:4855-4858.

After the change:
- A site's own turn makes at most inboundIDsNow re-routes, counting its own answers.
- A drain turn makes at most drainIDsLeft distinct ids.
- The rest is owed as one .reroutes event, replayed in the drain at its queue position under copy layers.

Supporting pieces:
- a global publication hold;
- idle guards that keep owed pairs' bindings and the watcher, and keep the run from settling, while re-routes are owed;
- invariants for every new piece of state.

## spec

- R1 Prerequisites and order.
- C Phase 1 is in place:
  - C5: deliver's group arm in place (Sources/ZTronAssetSync/Engine/EngineJobs.swift:563-576);
  - C10: dropGroupMember in place (EngineJobs.swift:594-604);
  - C11: releaseRunClaim in place (EngineRuns.swift:505-512);
  - C3: .committed(locations, ascending:) (EngineJobs.swift:553, :631-645; EngineRuns.swift:521).
- A2-A11 are in place:
  - VerdictKey and the exhaustive verdictKey switch;
  - joinsBehindVerdicts;
  - A6's materialisation at batch formation;
  - A11's removal of scheduleDrainFollowUp's spawn-nil branch (EngineFollow.swift:388-399).
- B2-B5 are in place: IDTokens, Job.tokensByID, in-place mutators that release index entries, and moveItems(of:) -> (items: [MoveItem], unheld: [AssetID]).
- RR-21 lands after all three, with its readers before its writers (see commit_plan).
- R2 Types.
- In Sources/ZTronAssetSync/Engine/EngineMoves.swift, beside MoveItem (:5-14) and MoveProgress (:20-88):
  - extract `struct MinHeap<Element: Comparable & Sendable>: Sendable` from MoveProgress's heap (heapify :30-39, first :47-49, popFirst :52-62, siftDown :69-87);
  - add `mutating func removeAll(where:) -> [Element]`, which partitions the matches out and heapifies the rest, O(n);
  - MoveProgress wraps MinHeap<MoveItem>, with no change in behaviour;
  - MoveItem gains Hashable, for the owed-pairs map.
- `struct RerouteItem: Comparable, Sendable { asset: AssetID; token: InterestToken; lane: AssetPriority; kind: InterestKind }`, ordered by (asset, token) like MoveItem (:11-13). Because items carry lane and kind, the judge's owners map and continueMove's stub lookup (:202) are not needed.
- `struct RerouteLayer: Sendable { outgoing: ValidatedManifest; applies: UInt64; ends: [TransferID: UInt64] }`.
- `struct RerouteBatch: Sendable { from: TransferID; copy: ValidatedManifest; serial: UInt64; items: MinHeap<RerouteItem>; layers: [RerouteLayer] }`. serial is copySerial at the owing instant (EngineState.swift:214).
- EventAfterFollow (EngineFollow.swift:1405-1435) gains `indirect case reroutes(RerouteBatch)`:
  - endsDrainBatch (:1436-1443) returns true for it;
  - A3's verdictKey returns nil for it;
  - laneEventsWaiting's default arm (EngineFailures.swift:845-863) ignores it;
  - measure MemoryLayout<EventAfterFollow>.stride with and without `indirect`.
- EngineState gains `var reroutesWaiting = 0` (beside drainIDsLeft, EngineState.swift:167). It counts owed batches not yet replayed whole, whether in the queue or in a drain turn's local batch.
- R3 Owing helpers, in Sources/ZTronAssetSync/Engine/EngineFollow.swift beside rerouteMovedBefore (:572-576).
- `func oweReroutes(_ items: [RerouteItem], from: TransferID) -> RerouteBatch`:
  - heapifies the items, with no sort;
  - releases the run's claims on `from` for its own owed items in place: `let run = self.state.run?.token; self.state.run?.outstanding[from]?.subtract(items.lazy.filter { $0.kind == .run && $0.token == run }.map(\.asset)); if self.state.run?.outstanding[from]?.isEmpty == true { self.state.run?.outstanding[from] = nil }`;
  - does `reroutesWaiting += 1`;
  - returns RerouteBatch(from:, copy: self.state.applied, serial: self.state.copySerial, items:, layers: []).
- `func deferReroutes(_ items: [RerouteItem], from: TransferID)`:
  - calls `self.deferToFollow(.reroutes(self.oweReroutes(items, from: from)))` (:233-236 stamps the owing instant), then `self.scheduleDrainFollowUp()` unconditionally;
  - scheduleDrainFollowUp stays private (:379). When a follow is owed, the extra follow-up turn returns at drainEventsAfterFollow's guard (:189).
  - The judge's `!followOwed && !drainingAfterFollow` condition is Removed. Sites 1 and 3 run after an await (EngineDispatch.swift:1058), never inside a synchronous drain.
- No caller ever owes an empty list.
- R4 Site 1: committed (Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1100-1139). One rewrite that includes C1 and C3; no Job copy stays alive across a mutation.
- Guard with `self.state.jobs[transfer] != nil`. bind (:1106) is unchanged.
- Collect pass: one scoped, unsorted read of the interests.
  - For each token that has unbound ids (locations[a] == nil), record whether the interest is wholly unbound, and its unbound ids.
  - Each unbound id becomes a RerouteItem carrying the interest's lane and kind.
  - It is moved-away (T22 and T21, :1121-1122) when `self.state.applied.entry(for: a)?.transferID != transfer`; otherwise it is deferred.
  - For a deferred id, `refused = refused || captured.contains(a)`, where `captured` is C1's lazy Set(ids).
- Trim pass: `setInterest(nil, for:)` for a wholly unbound interest, otherwise `subtractAssets(unbound, for:)`. This replaces setAssets at :1118.
- Bound: `let owes = !items.isEmpty && locations.count + items.count > self.inboundIDsNow` (EngineMoves.swift:130-132). The fit charge counts the commit's own answers, so a converged commit at 9.86 ms makes no re-routes at once.
- When it does not owe:
  - sort the moved-away items and the deferred items (each list at most inboundIDsNow) by (token, asset);
  - call `reroute(item.token, interest: JobInterest(lane: item.lane, kind: item.kind, assets: []), asset: item.asset, from: transfer)` for the moved-away ones now;
  - call it for the deferred ones in resolveAll's closure, after `if refused { holdForManifest(transfer) }`.
  - These are today's calls in today's order (:1121-1122, :1129-1136). Only the interleaving of trims and re-routes changes, and they touch disjoint state: reroute reads only interest.lane and interest.kind (:1146-1189). Record this argument.
- When it owes: `resolveAll(transfer, with: .committed(locations, ascending: ids)) { if refused { self.holdForManifest(transfer) }; self.deferReroutes(items, from: transfer) }`. pump (:1137) and reconcileIdle (:1138) follow as today.
- R5 Site 3: supersede (Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1256-1279).
- Add a parameter `bound: Int? = nil`.
  - publicationFailed's .superseded arm (:1205-1211) passes `bound: self.inboundIDsNow`.
  - move's call (EngineFollow.swift:941) passes nothing and is untouched; it is already bounded by startMove (EngineMoves.swift:141-143).
- removeAllInterests (:1261), removeJob (:1262) and the F-20 hold (:1263-1265) run as today. Then `if let bound, pairs > bound`, where pairs is the sum of interest.assets.count over the `job` copy, counted only when bound is set:
  - build RerouteItems from job.interests, with no sort;
  - call deferReroutes(items, from: transfer) instead of the loop at :1266-1273.
- checkRunSettled and pump (:1274-1278) stay. Behind the barrier they do nothing (EngineRuns.swift:576; EngineDispatch.swift:95).
- At or below the bound, the loop is unchanged.
- R6 Site 2: the take-off (Sources/ZTronAssetSync/Engine/EngineFollow.swift:551-568). New signature: `takeOffMovedBefore(_ transfer: TransferID) -> (items: [RerouteItem], ids: Int)`.
- held = job.assets ∩ attemptEnd.movedBefore (:552); return ([], 0) when held is empty.
- `jobs[t]?.assets.subtract(held)` (:557).
- B5's moveItems(of: held) gives (items, unheld). Lane and kind are read per token in one scoped read.
- A partial interest loses its held ids through subtractAssets.
- The tokens whose interest is wholly held are sorted ascending and removed with removeInterest (EngineJobs.swift:339-341) in that order.
  - Only these tokens are sorted, where today's code (:558) sorts every interest.
  - Job.lane is computed from the remaining interests (EngineState.swift:761-763), and heldLane is set at the last removal (EngineJobs.swift:354-356). Removing in ascending order gives today's heldLane, with no Dictionary-order flake.
- ids = held.count - unheld.count.
- The callers at :352 and :615 pass the TransferID, not a Job copy.
- R7 Site 2: the replays. These are replayVerdict (Sources/ZTronAssetSync/Engine/EngineFollow.swift:607-620) and the .spaceFailure arm (:346-356).
- Their guards are rewritten so that no Job copy is bound: compare epoch and state through optional chaining.
- (1) `let movesAfter = self.state.jobs[transfer].map(self.movesAfterVerdict) ?? false`. It is read before the take-off, as endDeferral reads today's copy from before the take-off (:537-541).
- (2) `let off = self.takeOffMovedBefore(transfer)`, then `self.state.jobs[transfer]?.attemptEnd = nil`. endDeferral goes.
- (3) `let owes = off.ids > self.state.drainIDsLeft`, then `self.state.drainIDsLeft = owes ? 0 : self.state.drainIDsLeft - off.ids`.
  - Zeroing keeps followAfterVerdict's visit out of the O(held) take-off turn: startMove with budget 0 leaves its whole move as followMoving (EngineMoves.swift:141-143, :189-194). It also makes the drain's existing break re-insert the batch.
  - The reservation keeps the turn at or below drainIDsLeft when the re-routes run at once.
- (4) giveVerdict (:617) or decideSpaceFailure (:354), then followAfterVerdict(transfer, movesAfter) (:586-593).
- (5) If it owes, return `.reroutes(self.oweReroutes(off.items, from: transfer))`. Otherwise call rerouteMovedBefore(off.items sorted by (token, asset), from: transfer). These are today's calls and order (:619), now charged to drainIDsLeft.
- replay(_:) (:344-376) returns `EventAfterFollow?`: these two arms as above, .reroutes as in R9, and nil everywhere else.
- R8 The drain loop (Sources/ZTronAssetSync/Engine/EngineFollow.swift:204-217).
- `let owed = self.withReading(stamp) { self.replay(event) }`. withReading is generic (:273).
- The put-back stays inside the existing break (:211-216): `let rest = (owed.map { [($0, stamp)] } ?? []) + batch[(offset + 1)...]`, followed by the two existing inserts at index 0.
- owed != nil only with drainIDsLeft == 0: site 2 zeroes it, and continueReroutes returns a rest only after spending the turn. So the `left != nil ||` disjunct is Removed.
- The batch keeps the stamp of the event that returned it, and goes ahead of the drain batch's rest and of A6's overflow at the queue head.
- Resulting order: verdict -> the visit's rest (:219-221) -> .reroutes -> the verdict's bucket joins, newest first -> overflow -> later events.
- R9 Replaying a batch: `case .reroutes(var batch): self.continueReroutes(&batch); return batch.items.isEmpty ? nil : .reroutes(batch)`.
- continueReroutes is modelled on continueMove (Sources/ZTronAssetSync/Engine/EngineMoves.swift:179-226), but drops :195 and :202:
```swift
var spent = 0
var current: AssetID?
var listing: ValidatedManifest?
while let item = batch.items.first {
    if item.asset != current {
        guard spent < self.state.drainIDsLeft else { break }
        spent += 1
        current = item.asset
        listing = self.rerouteListing(item.asset, batch)
    }
    _ = batch.items.popFirst()
    self.reroute(item.token, interest: JobInterest(lane: item.lane, kind: item.kind, assets: []), asset: item.asset, from: batch.from, listing: listing)
}
self.state.drainIDsLeft -= spent
if batch.items.isEmpty {
    self.state.reroutesWaiting -= 1
    self.releaseRerouteHolds()
}
```
- An id is taken whole, with all its tokens, as in continueMove.
- There is no owner guard: reroute's own guards answer a gone waiter, a released group and an ended run (EngineDispatch.swift:1150-1186).
- Joins are made at once, because drainingAfterFollow is set and inFollowVisit is false (EngineJobs.swift:110-122).
- Nothing writes jobs[from]: it may be an F-20 job that an earlier item created again.
- R10 rerouteListing(_ asset: AssetID, _ batch: RerouteBatch) -> ValidatedManifest? is exactly the judge's chain:
```swift
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
- waitingTarget becomes `waitingTarget(_ transfer: TransferID, epoch: UInt64) -> Job?`, with the body of Sources/ZTronAssetSync/Engine/EngineFollow.swift:1251-1263. The InboundMove overload forwards to it. No new branch.
- R11 Layers, in adoptApplied (Sources/ZTronAssetSync/Engine/EngineJobs.swift:1018-1027).
- Placement: after `copySerial &+= 1` (:1019) and before `self.state.applied = manifest` (:1020), the copy's only writer. Its callers are EngineRuns.swift:369, EngineCatchUp.swift:223 and EngineLifecycle.swift:399.
- One backward pass over eventsAfterFollow:
  - collect the live verdicts: A's VerdictKey(t, epoch) with `waitingTarget(t, epoch:) != nil`, for .attemptFailed and .spaceFailure alike (ruling 7);
  - at each .reroutes, append `RerouteLayer(outgoing: self.state.applied, applies: self.state.appliesFollowed, ends: E)` in place.
- E is:
  - the in-flight jobs that are verifying or committing, with their epochs, computed once per adopt;
  - plus the live verdicts queued after that batch;
  - from a batch's second layer on, only verdicts whose job's attemptEnd.deferredAfter is greater than the batch's last layer's applies.
- applies is read before followApplied's increment in the same turn (EngineRuns.swift:369 -> :393; EngineCatchUp.swift:223 -> :229).
- There is no reroutesWaiting guard: the pass is O(E) and appends nothing when no batch waits (Removed).
- Jobs failed in publication bookkeeping are not ends (EngineFollow.swift:879-889).
- R12 Publication hold.
- inboundBlocks (Sources/ZTronAssetSync/Engine/EngineFollow.swift:1159-1167) starts with `if self.state.followMoving?.holder == transfer || self.state.reroutesWaiting > 0 { return true }`.
  - publish then waits in awaitInboundMoves (EngineDispatch.swift:1032-1045), and its binding captures the pairs a batch joined to its job meanwhile.
  - inboundMade (:1272-1275) leaves those waits alone.
- `private func releaseRerouteHolds()`: `guard self.state.reroutesWaiting == 0 else { return }`, then take inboundWaits and resume each entry in sorted key order, as releaseInboundWaits does (:1297-1307).
- No !inboundBlocks filter is needed:
  - a batch ends only inside a drain turn;
  - a drain turn starts only while !followOwed (:189) and breaks at any visit rest (:211);
  - bringInbound and bringInboundOntoPublications return while !followOwed (:1004, :1024);
  - so every other term of inboundBlocks is false at that point.
- awaitInboundMoves does not re-check after it resumes (:1284-1293), so record this argument beside the code.
- At shutdown, releaseInboundWaits (EngineShutdown.swift:117) resumes every wait.
- R13 Idle guards. They land with site 1.
- pruneBoundContent (Sources/ZTronAssetSync/Engine/EnginePresence.swift:74-90):
  - adds `self.state.eventsAfterFollow.isEmpty` to its first guard (:75);
  - this covers every reconcileIdle caller (EngineDispatch.swift:1138, :1248; EngineFollow.swift:416, :1364; EngineTimers.swift:312);
  - doc: 'or while events wait for the follow: an owed re-route or a waiting join reads its binding at its replay'.
- hasWork (EngineConditions.swift:8-11) adds `|| !self.state.eventsAfterFollow.isEmpty`. reconcileIdle (:15-24) then keeps the watcher and the conditions while events wait, and the watch loop (:57) keeps running.
- checkRunSettled's guard (EngineRuns.swift:576) adds `self.state.reroutesWaiting == 0`. The hole it closes:
  - owed run items hold no claim (R3);
  - a drain turn that moved the batch into its local array leaves eventsAfterFollow empty (EngineFollow.swift:200-201), so followBarrier is false mid-drain;
  - a replayed verdict's resolveAll -> checkRunSettled (EngineJobs.swift:627) would then settle the run before the batch claims those items again.
- Narrow fallback, used only if an existing idle or ledger test changes path: replace the first two guards with `self.state.reroutesWaiting > 0`.
- R14 followedLane (Sources/ZTronAssetSync/Engine/EngineFailures.swift:721-838).
- Add `case .reroutes(let batch)` in the queue loop (:821-836), before A7's bucket walk.
- An item counts when:
  - its token is not in laneEventsWaiting's withdrawn set (:845-863);
  - its owner still waits for it at batch.from. This is stillWants' field form (EngineFollow.swift:713-728) with transfer = from:
    - waiter: present, !fromStore, same asset, waiter.transfer == from;
    - group: pending[asset] == from;
    - run: only `self.state.run?.token == token`, because its claims were released at owing;
    - system: always.
- For a counted item:
  - take `entry = (self.rerouteListing(asset, batch) ?? self.state.applied).entry(for: asset)`;
  - skip a nil entry (T21) and `isBound(asset, to: entry.transferID)` (answered present);
  - raise item.lane when `SyncEngine.sameTransfer(entry, job.entry)`, with A7's `return .userInitiated`.
- Cost: O(items x layers) per 429.
- R15 Purge (Sources/ZTronAssetSync/Engine/EngineCommands.swift:1049-1073).
- withdrawPurgedJoins' early return (:1050-1052) is Removed.
  - An empty walk costs nothing.
  - Under A8/K1, a bucket exists only while its verdict waits in the queue.
- The walk gains `.reroutes(var batch)`:
  - `let removed = batch.items.removeAll { $0.lane < .userInitiated && $0.kind != .waiter && isPurged($0.asset) }`;
  - over `removed` sorted by (asset, token): dropGroupMember(token, asset:, from: batch.from) for prefetch and ensure, `self.state.heals[asset] = nil` for system, nothing for run and waiter. These are withdrawPurged's arms (:992-1039).
  - Write the event back.
- There is no withdrawn set. An emptied batch stays queued, and its replay completes it: the counter goes down and the holds are released.
- R16 Shutdown and liveness.
- drainEverything (Sources/ZTronAssetSync/Engine/EngineShutdown.swift:117-135) also sets `self.state.reroutesWaiting = 0`, next to the clear at :118.
- Liveness rests on:
  - drainEverything (:117-118, :124, :130);
  - drainFollowUp's isRunning guard (EngineFollow.swift:411);
  - the sites' running turns (EngineDispatch.swift:1069, :1193);
  - spawn's refusals only outside running (EngineLifecycle.swift:52-54).
- It never relies on the spawn-nil branch, which A11 removes.
- R17 Invariant code (Sources/ZTronAssetSync/Engine/EngineCommands.swift).
- The waiter (:1707-1712) and group (:1777-1783) acceptances, and the new .reroutes arm of followBarrierViolations (:2003-2069), are listed under invariants.
- The owed-pairs map, of type [MoveItem: TransferID], is built once per call.
- R18 Contingency for ruling 4: the probe runs at step 1 in sweep-first, and again after site 1 lands, in both orders. If it breaks S3-R16 item 1:
- listed .join events get copy, serial and layers in R11's same pass;
- replayJoin's re-route (Sources/ZTronAssetSync/Engine/EngineFollow.swift:704-707) uses R10's chain, started from join.entry;
- bucket joins (A) get no layers and keep the current copy.
- R19 Records: docs/adr-drafts/s3f.md, cycle-21 section.
- Inventory rows:
  - replace :4855-4858 with the bounded design and its BenchSync figures;
  - add rows for deliver, dropGroupMember and releaseRunClaim (O(1) amortised).
- S3-R16 item 2 classes for rulings 1, 2, 3 and 5, and the residuals.
- Arguments:
  - the call-for-call argument for site 1;
  - site 2's drainIDsLeft charge and its two orders;
  - the release argument for releaseRerouteHolds.
- The Removed and Equivalent branches, and the mutation table (S3-R25 item 10).

## invariants

- Checked clause: waiter acceptance (Sources/ZTronAssetSync/Engine/EngineCommands.swift:1707-1712).
- The existing message stays: `waiter \(token.rawValue) has no interest in \(waiter.transfer)`.
- It is not reported when an owed item (token, waiter.asset) has batch.from == waiter.transfer.
- Checked clause: group acceptance (EngineCommands.swift:1777-1783).
- The existing message stays: `group \(token.rawValue) member \(asset) without an interest`.
- It is not reported when an owed item (token, asset) has batch.from == transfer.
- Checked clause: no run acceptance (EngineCommands.swift:1812-1817). Owed run items hold no claim, because of the bulk release at owing.
- The existing message keeps firing for any claim left on `from`: `the run claims \(transfer), whose job does not hold its interest`.
- This kills the drop of the bulk release and the drop of the nil-when-empty write.
- New followBarrierViolations clause (EngineCommands.swift:2003-2069), .reroutes arm, owner of a waiter item. For kind .waiter, it fires when waiters[token] exists and (fromStore, or asset != item.asset, or transfer != from):
- `waiter \(token.rawValue) owed a re-route of \(asset) from \(from) waits for \(waiter.asset) in \(waiter.transfer)`
- New clause: owner of a group item. For .prefetch and .ensure, it fires when groups[token] exists and pending[asset] != from:
- `group \(token.rawValue) member \(asset) owed a re-route from \(from) is pending at \(String(describing: group.pending[asset]))`
- New clause: per (token, asset), the pair is no longer on jobs[from]. It fires when jobs[from]?.interests[token]?.assets.contains(asset) == true:
- `interest \(token.rawValue) in \(asset) owed a re-route from \(from) is still held there`
- New clause: per (token, asset), the pair is not also a waiting join. It fires when joinsAfterFollow[token]?[asset] is not nil:
- `interest \(token.rawValue) in \(asset) owed a re-route from \(from) also waits to join \(transfer)`
- New clause: no pair is owed twice. It fires when the same (token, asset) appears more than once across all batches:
- `interest \(token.rawValue) in \(asset) is owed \(count) re-routes`
- New clause: the run claims no owed run item. For kind .run, it fires when run?.token == token and run.outstanding[from]?.contains(asset) == true:
- `the run claims \(asset) on \(from), which a re-route owes`
- New clause, per batch: the copy history. It fires when layers.count != copySerial &- serial:
- `a re-route batch from \(from) holds \(batch.layers.count) copies for \(self.state.copySerial &- batch.serial) adopted since it was owed`
- New clause: the counter. It fires when reroutesWaiting differs from the number of .reroutes events in eventsAfterFollow. It is checked between turns.
- `\(self.state.reroutesWaiting) re-route batches counted, \(waiting) waiting`
- Existing clauses relied on, with their messages unchanged:
- events wait (EngineCommands.swift:2006-2008): `\(events.count) events wait for a follow, but no follow is owed and no drain is scheduled`;
- stamps (:2034-2036): events and decision instants stay in step through the put-back;
- stranded wait (:2061-2064): `\(stranded.count) publications wait for owed moves that nothing owes`. inboundBlocks now includes the counter;
- manifest hold (:1818-1819): `\(self.state.heldForManifest.count) jobs held for a manifest catch-up nothing performs`. holdForManifest at owing schedules a catch-up (EngineCatchUp.swift:145-151).
- D1 No batch raises followOwed (Sources/ZTronAssetSync/Engine/EngineFollow.swift:82-85). The following are therefore unchanged while re-routes are owed:
- publish's away (EngineDispatch.swift:1024-1027);
- recordDeferredVerdict's away (:514);
- holdsMovedID (:424-431);
- bringInbound and bringInboundOntoPublications (:1004, :1024);
- the end of continueFollow.
The only followOwed source is site 2's zeroed visit, through the existing followMoving.
- D2 While reroutesWaiting > 0:
- nothing is admitted: pump stops at followBarrier or drainingAfterFollow (EngineDispatch.swift:95);
- no run settles: EngineRuns.swift:576 with the counter, including mid-drain;
- no publication binds (inboundBlocks);
- no binding is pruned and the watcher stays (R13);
- every deferred input replays after the batch, at its own stamp.
- D3 Owner stasis: from the owing instant to the replay, a live item's owner names `from` or is gone. This covers waiter.transfer and group.pending[asset]. The run claims none of the batch's run items.
- D4 Copy history: every copy change while a batch waits appends exactly one layer, so layers.count == copySerial - serial. With no layer, the copy now equals batch.copy, and the replay equals the at-once engine's reroute under that copy, at the owing instant's stamp.
- D5 T21 under batch.copy is answered as T21: .notFound, the member dropped, the heal forgotten, whatever a later copy lists. An id that an intermediate copy unlisted is answered under that copy.
- D6 A pin holds only while waitingTarget(transfer, epoch) holds.
- A pair whose pinned job left that end, by commit, supersede or an ENOENT re-queue, follows the copy now.
- No new job of a former target is created from an old copy.
- D7 Order:
- a batch replays at its queue position;
- site 2's batch replays right after its verdict and the whole visit after it, before every later event;
- a batch ends its drain batch and stays at the head until it is empty;
- invariant: owed != nil implies drainIDsLeft == 0 at the put-back.
- D8 Bounds:
- a drain turn makes at most drainIDsLeft distinct ids, shared with the turn's visits after verdicts;
- sites 1 and 3 make at most inboundIDsNow re-routes in their own turn. Site 1 counts its answers too (locations.count + items.count);
- at site 2, at-once re-routes plus the visit together make at most drainIDsLeft ids.
- D9 Liveness:
- a drain turn with ids left makes at least one item;
- a turn with none left re-inserts the batch and schedules a follow-up, whose fresh budget makes progress;
- every publication wait is resumed at the last batch's end, or at shutdown;
- the run settles at the drain's tail once reroutesWaiting == 0.
- D10 At or below the bound:
- sites 1 and 3 make today's calls;
- site 2's re-routes are today's calls, but its visit gets drainIDsLeft - ids. This is an order difference only, of the cycle-19 bounded-visit class, and is recorded.
- D11 Owner updates are O(1) amortised: no `var` copy of a Group, a RunState or a Job is alive while a collection inside it is mutated. This covers dropGroupMember, releaseRunClaim, deliver, the take-off and committed's trims.
- D12 Purge: a withdrawn non-user item leaves its batch at the purge, its group member is dropped and its heal forgotten. User waiters' items are kept.

## tests_and_mutants

- Common setup, unless a test says otherwise:
- followIDsPerTurn = 4, so inboundIDsNow = 2 and drainIDsLeft = 4;
- both LaneDropVisit orders (EngineFollowTests.swift:780-787);
- drain and follow follow-ups held, and released one turn at a time;
- invariantViolations() and followBarrierViolations() empty after every released turn;
- .timeLimit, and no sleeps.
Every mutant must fail 2/2 in each order. Where a shape's state arises only in sweepFollowsFirst, a per-order #require pins its absence in followVisitedFirst (integrate Q1).
- T1, the bound at site 1.
- Setup: a commit leaves 10 unbound pairs on 10 distinct ids.
- Assertions: each held drain turn makes at most 4 and at least 1 distinct ids. The answers equal a run at followIDsPerTurn = 512.
- Kills: drop `spent < drainIDsLeft` (a 10-id turn); drop `spent += 1`; drop the put-back's owed prefix (the counter clause fires).
- T1-two: two commits owe 3 pairs each while the drain is held. Kills the drop of `drainIDsLeft -= spent` (a 6-id turn).
- T1-zero, T1-edge and T1-fit, the bound test at site 1.
- T1-zero: 3 bound ids and no unbound pair. Assert eventsAfterFollow is empty after the commit turn. Kills the drop of `!items.isEmpty`.
- T1-edge: 1 bound + 1 unbound (2 == inboundIDsNow). Assert no .reroutes event. Kills `>` -> `>=`.
- T1-fit: 1 bound + 2 unbound. Assert a .reroutes event. Kills dropping the `locations.count +` operand, always-owe and never-owe.
- Both orders.
- T3-captured, the F-20 hold.
- Setup: deferred ids that the publication captured (refused), on the fit path and on the owing path.
- Assertions: a held fresh job of the content exists, with no download before the copy catches up.
- Kills: drop `captured.contains` (refused stays false); drop the owing closure's holdForManifest.
- Both orders.
- T2, the bound at site 3.
- Setup: a .superseded publication with 10 pairs. T2-two: 2 pairs. T2-edge: exactly 2 pairs.
- Assertions: as in T1.
- Kills: drop the count test; `>` -> `>=`; publicationFailed passes nil instead of inboundIDsNow; owe before removeJob (the F-20 hold is lost: a held fresh job is expected).
- Both orders.
- T3, the bound and order at site 2.
- Setup:
  - a 404 verdict and a .spaceFailure, each holding 10 moved-before ids;
  - a .removal of one pair's waiter queued behind the verdict;
  - an interest with two ids, only one of them held (partial).
- Assertions:
  - the batch replays right after the verdict and its visit;
  - the removal then removes the re-joined interest;
  - no stray job is left;
  - the partial interest keeps its other id.
- Kills: insert at the tail or after the rest; always use removeInterest (the partial interest's other id is lost); always use subtractAssets (an emptied interest is left).
- T3-two: two verdicts of 3 ids each in one drain batch. Kills the drop of the reservation (a 6-id turn).
- Orders: sweepFollowsFirst for the moved-before state (EngineFollowBarrierMovedBeforeTests.swift:63-68, per critic-rr21-cost), with the #require in the other order.
- RR21-VERDICT-ZERO.
- Setup: a take-off that does not fit, and moves owed after the verdict.
- Assertions: followMoving is set after the verdict turn, and that turn moved 0 visit ids. Order: verdict -> the whole visit -> batch -> rest.
- Kills: drop the zeroing. The visit then runs in the owing turn; and when the visit has no moves, the batch is lost and the counter clause fires.
- Orders: sweepFollowsFirst only, with the #require.
- RR21-HELDLANE.
- Setup: a job kept by a claim (claims[key] set), all of whose moved-before interests are taken off. The interests have different lanes: the greatest token's is userInitiated, the rest bulk.
- Assertions: heldLane == .userInitiated, as today.
- Kills: sort descending, deterministically. Dropping the sort is killed only probabilistically with 64 interests; record its kill rate over 10 runs.
- Order: sweepFollowsFirst.
- T4, T21 at owing.
- Setup: K0 drops the ids, and an apply that lists them again lands between turns.
- Assertions: .notFound, the group members dropped, the heal forgotten.
- Kills: remove rerouteListing's `else { return batch.copy }`.
- Both orders.
- T5, RR-14 at layer 0.
- Setup: X0 is publishing at the apply that moves the pairs to W. X0's publication then fails with integrity; its verdict defers behind the batch.
- Assertions: integrityFailure for the pairs.
- Kills: drop ends' publishing term.
- T6 (P-a): X0 is downloading at owing, its 404 is deferred behind the batch, then an apply maps the pairs to W. Expect .notFound. Kills the drop of ends' verdict term.
- T7: X0's verdict is queued before the batch, then an apply moves the pairs. Expect W's answer. Kills counting verdicts queued before the batch.
- Both orders.
- T8, a pin whose job committed.
- Setup: X0 is publishing at the apply and commits before the replay.
- Assertions: W's job; no job of X0's content created after the commit; a fixed jobsCreated.
- Kills: return layer.outgoing instead of nil.
- T8b: X0's publication ends in ENOENT for a cancelled attempt (EngineDispatch.swift:1217-1225), so it is re-queued at the same epoch before the replay. waitingTarget's .queued arm returns nil (EngineFollow.swift:1260-1261). Expect the waiters' transfer to be W at the replay, X0 not holding their ids, and W's answers. Kills: return the job for .queued.
- Both orders.
- T9, a double hop.
- Setup: K1 moves the pairs from a downloading X0 to X1, which is publishing at K2. K2 moves them on, then X1's publication fails.
- Assertions: X1's failure.
- Kills: stop the chain after the first layer.
- T10: K1 drops the ids and K2 lists them again. Expect .notFound. Kills removing `guard let next ... else { return incoming }`.
- T11: X1's verdict was deferred behind the batch but before K1, and K2 moves the pairs. Expect no pin at K2. Kills the drop of `deferredAfter > previous.applies`.
- Both orders.
- T12, a 429 while owed, on site 1, with sub-shapes:
- (a) a live user waiter's pair targets the throttled job: expect a userInitiated backoff policy and fail-fast answers as at once. Kills: drop the arm; use batch.copy's entry instead of rerouteListing (with an apply in between); drop `return .userInitiated`.
- (b) the waiter was cancelled behind the barrier (record without its continuation, a .removal waiting): no raise. Kills: drop the withdrawn-token check.
- (c) a T21 item: no raise. Kills: drop the nil skip.
- (d) an isBound item: no raise. Kills: drop the isBound skip.
- A group variant and a run variant kill each owner predicate.
- Both orders.
- T13, a purge while owed.
- Assertions:
  - non-user pairs of purged ids are withdrawn at the purge;
  - no job of them exists after the replay;
  - the member is dropped and the heal forgotten;
  - user waiters' pairs are kept.
- T13-nonpurged: items of other ids stay and are re-routed.
- Kills: drop the arm; restore the early return; drop the isPurged conjunct (the nonpurged variant); swap the group and system effects.
- Both orders.
- T14, a publication starts while owed.
- Assertions: it waits; its binding then captures the pairs; they are answered .committed with no second request.
- Kills: drop inboundBlocks' counter term; drop releaseRerouteHolds (the stranded-wait clause fires and the time limit fails).
- T17-hold: two batches owed while a publication waits. It must stay waiting after the first batch ends. Kills the drop of `guard reroutesWaiting == 0`.
- Both orders.
- T15, cancel and release while owed.
- Assertions:
  - cancelling a waiter answers .cancelled at once, and its interest is gone after the replay;
  - a released group gets no member re-joined;
  - invariants are clean every turn.
- Kills: drop the waiter or the group acceptance (T1 fires falsely); drop the owner clauses (seeded owner mutation, below).
- Both orders.
- T16, shutdown midway through a batch.
- Assertions: every waiter gets .shutDown; nothing hangs; no stranded wait; no event remains; reroutesWaiting == 0.
- Kills: drop R16's zeroing (the counter clause).
- Both orders.
- T17, two sites while owed.
- Setup: a second commit is owed behind the first batch.
- Assertions: the answers equal at-once.
- Kills: insert at the head instead of appending.
- Both orders.
- T18, the run shape.
- Setup: the run's claims converge on O and are moved away (wholly unbound).
- Assertions: the run settles only after the batch, and outstanding names the new jobs.
- Kills: drop the bulk release; drop the nil-when-empty write (the run clause fires).
- T18-partial: the interest is partly bound, so recordRunOutcome wipes outstanding[O] (EngineRuns.swift:519). The answers equal at-once.
- Both orders.
- RR21-RUN-MIDDRAIN.
- Setup: the queue holds only [V, B]. V is the deferred verdict of the run's other job; B owes the run's moved-away items. They form one drain batch, so eventsAfterFollow is empty mid-drain.
- Assertions: the run settles only after B, with every planned asset fetched.
- Kills: drop `reroutesWaiting == 0` from checkRunSettled's guard. The run settles at V's resolveAll with fetched short.
- Run it red first (S3-R19 item 1).
- Orders: both (UNCONFIRMED; otherwise the #require).
- RR21-HOP (critic answers, refutation 1).
- At sites 1 and 3, with integrity and .locked variants.
- Assertions: Q and W1..W3 get P's failure; zStarts == 0.
- Kills: drop ends' publishing term at that site's batch.
- Both orders.
- RR21-WINDOW-GATE (refutation 2).
- Setup: the gate closes before the site, and P's publication starts during the window.
- Assertions: W1..W3 get P's locations; no fresh job of P's content.
- Kills: drop the hold term.
- Both orders.
- RR21-PRESENT-PRUNE (refutation 3).
- At each of the three sites, with the breaker open, offline, and insufficientSpace.
- Setup: v4 reuses D's blob for a1..a3 (EngineRuns.swift:374-381). No run, group fetch or presence reader.
- Assertions: W1..W3 are served from the store; jobs[D] stays nil; at most 4 new fromStore waiters per held turn.
- Kills: drop the prune guard.
- Both orders.
- T-WATCH.
- Setup: NetworkPolicy.userInitiatedOverridesPolicy = false, prefetchOnExpensive = false, on an expensive path already known. The site removes the last job.
- Assertions: the watcher is active after the site's turn; X is parked with .policy; no transport start; W1..W3 are unanswered.
- Kills: drop the hasWork disjunct (one transport start, deterministically).
- Both orders.
- T-COMPOSE: A6 overflow with a site-2 batch.
- Assertions, the order: verdict, the visit's rest, .reroutes, the bucket joins newest first, overflow, later events.
- Kills: insert the owed batch after the rest, or after the overflow.
- Order: sweepFollowsFirst.
- T-shared.
- Setup: [V, B] in one drain batch.
- Assertions: V's visit and B share drainIDsLeft (at most 4 ids in the turn).
- Kills: continueReroutes uses followIDsPerTurn instead of drainIDsLeft.
- Both orders.
- T-two-tokens.
- Setup: a waiter and a group member on each of 6 ids.
- Assertions: at most 4 ids per turn, and both tokens of an id in the same turn.
- Kills: drop `item.asset != current` (counts per item).
- Both orders.
- Inject-one-violation tests: one per new clause.
- Mutate, through @testable state, one owner, jobs[from], joinsAfterFollow, a duplicate pair, run.outstanding[from], layers, or the counter.
- Assert the exact message.
- Kills: drop the clause.
- Probes recorded, not committed as failing tests:
- PROBE-RR21-JOIN-GAP: ruling 4, at step 1 and after site 1;
- PROBE-RR21-HEAL-T21: a scheduleHeal of a T21 system item's asset between owing and replay;
- PROBE-RR21-RESERVE-REJOIN: moved-back ids at the reservation edge with a retry cap, compared with visit-first in both orders.

## pins

- Common to every BenchSync pin:
- gate: best of 3 per-turn maximum at most c2Budget = 10 ms (BenchSync.swift:129), at a 1-minute load of 10 or less, with the three load averages recorded and sim.lock taken (S3-R22 item 3);
- measured inside the actor per held turn, through releaseOneHeldFollowOrDrainTurn (lines UNCONFIRMED);
- S3-R23 item 3: two pins per bound, one deterministic and one BenchSync.
- Bound in the site's own turn, sites 1 and 3:
- deterministic: T1-edge/T1-fit and T2-edge;
- BenchSync concentrationCommitRerouteTurns (BenchSync.swift:655-659). Setup expectations: 10,000 converged ids moved away; the commit turn owes one batch and makes no re-routes; every drain turn makes at most 512 ids;
- BenchSync supersededRerouteTurns. Setup: a .superseded publication of 10,000 ids (a group) owes one batch.
- Bound in a drain turn:
- deterministic: T1 and T3 per-turn id counts;
- BenchSync commitRerouteDivergentTurns: 10,000 ids onto 10,000 contents; 20 drain turns, each at most 512 ids;
- BenchSync movedBeforeDrainTurns (:675-690): the verdict turn owes and moves 0 visit ids, then drain turns of at most 512 ids.
- Site 2 with user waiters (ruling 6):
- deterministic: T3;
- BenchSync movedBeforeDrainWaitersTurns, for 10,000 user waiters all held and half held. The figure is the take-off turn at once (O(held), the token sort, B's index releases). If it misses, chunk the take-off before the verdict.
- Commit with user waiters (ruling 6, judge open question 2):
- deterministic: T1 with one user waiter per id;
- BenchSync commitRerouteWaitersTurns: 10,000 user waiters moved away, converged on D, with at least 511 joins queued behind the event;
- BenchSync commitWaitersBoundTurns: 10,000 user waiters all bound, which owes nothing. If it misses after C Phase 1, it is C Phase 2's trigger.
- Present answers:
- deterministic: RR21-PRESENT-PRUNE;
- BenchSync userMovedToBound and groupMovedToBound, with windows that end at the last answer, not at the barrier's fall. Setup: jobs[D] stays nil; at most 512 answerWaiterFromStore spawns per drain turn (EnginePresence.swift:133-139).
- Zeroing:
- deterministic: RR21-VERDICT-ZERO;
- BenchSync movedBeforeAndAfterTurns: 5,000 ids moved before and 5,000 after the deferral; followMoving is set after a verdict turn that moved 0 ids.
- Fit edge:
- deterministic: T1-fit;
- BenchSync commitFitBoundaryTurns: locations.count + items.count at inboundIDsNow (at once), and at inboundIDsNow + 1 (owed);
- re-measure C's commitTurns afterwards.
- Two tokens per id:
- deterministic: T-two-tokens;
- BenchSync commitTwoTokensTurns: 10,000 ids x 2 tokens.
- T21:
- deterministic: T4;
- BenchSync groupDelistedAll: v4 drops 10,000 members, for a group and for user waiters. This pins C10's in-place updates.
- Run:
- deterministic: T18 and RR21-RUN-MIDDRAIN;
- BenchSync runSuperseded: 10,000 converged claims moved away at site 1 and superseded at site 3. It also times countRunFetched/offerRunProgress per present run item.
- Layers:
- deterministic: T5-T11;
- BenchSync applyWhileOwedLayers: an apply while a 10,000-pair batch waits, with publications in flight, then the replay through two layers. The adopt turn's pass is O(E + in-flight).
- followedLane:
- deterministic: T12;
- BenchSync lane429WhileOwed: a 429 on the target while a 10,000-pair batch of non-user items waits (O(items x layers)).
- Purge:
- deterministic: T13;
- BenchSync purgeWhileOwedTurns: a purge of all while a 10,000-pair batch waits (removeAll(where:), the sort of the removed subset, dropGroupMember after C10).

## must_not

- Do not raise followOwed or add any new source of it for owed re-routes. No pseudo-follow, and no VisitRemainder or InboundMove created at a site. Site 2's zeroed visit uses the existing followMoving.
- Do not widen bringInbound's guard (Sources/ZTronAssetSync/Engine/EngineFollow.swift:1004) or bringInboundOntoPublications' (:1024). Do not change the followOwed reads in recordDeferredVerdict (:514), publish (EngineDispatch.swift:1024-1027) or holdsMovedID (:424-431).
- Do not put owed pairs on a holder job. Add no Job.takeOff, takeOffJoins, holder epoch or new job state.
- Do not re-route a pair under a later copy when batch.copy does not list it (T21 at the owing instant).
- Once waitingTarget(transfer, epoch) fails:
- do not join a pinned job;
- do not fall back to K0's entry;
- fall back to the copy now.
- At or below the bound:
- do not change the calls of sites 1 and 3;
- do not change site 2's verdict semantics: no verdict skips ids, and giveVerdict is untouched.
- Do not insert the site-2 batch at the queue's tail or before its verdict. Do not let the drain batch's rest, or A6's overflow, go ahead of it.
- Keep .reroutes a batch-ending event. Never drop a batch on a turn with no ids left: re-insert it.
- Do not sort a batch's items in a turn; use the heap. Only these sorts are allowed:
- at most inboundIDsNow fit items at sites 1 and 3;
- at most drainIDsLeft ids' fit items at site 2;
- the take-off's wholly held tokens, fewer than today's sort at :558;
- the purge's removed subset, as withdrawPurged sorts.
Each has a BenchSync figure. This amends the judge's 'no 10,000-element sort'.
- Do not mutate a Group's pending, a RunState's outstanding, or a Job's id sets through a `var` copy. Do not keep a Job copy alive across the take-off or committed's trims.
- Add no new seam: use followIDsPerTurn, inboundIDsNow and drainIDsLeft. reroutesWaiting is state, not a seam.
- Do not leave a publication wait without its resume, at a batch's end and at shutdown.
- Never owe an empty batch.
- Never let a run settle while reroutesWaiting > 0.
- While events wait, do not prune bindings and do not stop the watcher.
- Do not fix replayJoin's approximation or the waitingTarget window this cycle, unless ruling 4's probe breaks; then add only the .join layers.
- Do not reopen P-a, RR-14, the reconcileIdle prune ruling or the Unlisted class. The prune guard is RR-21's own fix; it only narrows that ruling's window.
- Do not edit anything under Scripts/, lower a gate, or widen a coverage exclusion. Add no @unchecked Sendable or UNSAFE exception: the batch is a plain Sendable value.
- Do not take timing figures while the S3-R23 verifiers measure. Measure at a 1-minute load of 10 or less, record the three load averages, and take sim.lock.

## residual_risks

- Cancel or release between the owing instant and a T21 or present pair's replay gives .cancelled.
- Category: timing (S3-R16 item 2). The cancel lands between the two answers (S3-R24 item 5). Ruling 1.
- The global hold delays unrelated publications. An apply during the hold can drop a held job's ids: .notFound where at-once had committed first.
- Category: timing. Ruling 2.
- A pin whose job committed, was superseded or was ENOENT-re-queued (T8b) between the apply and the replay follows the copy at the replay. This is exact unless another apply landed between that end and the replay.
- Category: timing. Ruling 3.
- A purge's dropBindings (EngineCommands.swift:971), an eviction or a quarantine between the owing instant and the replay turns a present answer into a join.
- Category: timing. Ruling 5.
- A scheduleHeal (EngineTimers.swift:429-433) of a T21 system item's asset, landing between the owing instant and the replay, is forgotten at the replay (EngineDispatch.swift:1158).
- Category: timing, ruling 1's class.
- Probe that would make it blocking: PROBE-RR21-HEAL-T21, if it shows the heal landing before both answers.
- Owed re-routes replay in (asset, token) order, not (token, asset). Jobs created at the replay take other places.
- Category: order/place (the RR-3, RR-16 and RR-23 families).
- Site 2 has two orders for one shape: at-once re-routes come before the visit's rest, owed re-routes after the whole visit. The reservation also shifts which shapes take which order.
- Category: order (the cycle-19 bounded-visit class).
- Probe that would make it blocking: PROBE-RR21-RESERVE-REJOIN (moved-back ids rejoin the old job, with its retry state, or a fresh one), if answers differ from visit-first.
- The bulk release lowers outstanding.count during the window. materializeRun runs before the barrier check (EngineDispatch.swift:93 vs :95; EngineRuns.swift:481-484), so the run can materialise more fetches than at once.
- Category: order/timing. T18's equality of the run's outcome would catch an answer change.
- Owed run items of a run that a purge cancelled replay into a run that is settled but not yet finished (EngineRuns.swift:722-726). They are removed with its interests.
- Category: timing. That finishRun removes them is UNCONFIRMED.
- The broad idle guards keep every binding and the watcher while any event waits. A new request between turns may be answered from the store where visit-first had pruned.
- Category: timing (critic-compose).
- Admissions and run settlement wait for every owed batch: about 20 drain turns at 10,000 ids.
- Category: timing.
- Each owed batch keeps its ValidatedManifest, and each layer's outgoing copy, alive.
- Category: memory only.
- replayJoin's RR-14-class gap (EngineFollow.swift:704-707).
- Residual only if PROBE-RR21-JOIN-GAP passes in both orders after site 1.
- Otherwise it is blocking (S3-R21 item 4), and R18 lands.
- One id with k tokens costs k re-routes in one id slot, as continueMove does.
- Category: C2 class of cycle 19.
- What would make it blocking: commitTwoTokensTurns, or a probe with very many tokens per id, missing c2Budget.
- Every C2 figure for RR-21's site and drain turns stays open until the BenchSync cases run at a load of 10 or less.
- Category: gates. A miss is blocking under S3-R16 1(f).

## amendments_decided

- Applied, from critic-rr21-answers:
- The prune guard (R13), with integrate interaction 13 reworded as an answer difference.
- S3-R24 item 5 applied to callers' answers in every residual.
- The liveness citations: drainEverything, spawn's nil cases, the isRunning guards.
- The per-(token, asset) clause.
- The pins RR21-HOP, RR21-WINDOW-GATE and RR21-PRESENT-PRUNE.
- Site 2's superseding-rest case, recorded as a residual (two orders).
- Moot, from critic-rr21-answers:
- 'mechanism 9 dropInterests heldLane': the synthesis keeps per-token removeInterest, in ascending order.
- The chain and the hold: already in the judge's synthesis.
- Applied, from critic-rr21-compose:
- the hasWork disjunct;
- per-(token, asset) predicates and the report of duplicates;
- shutdown and liveness text citing drainEverything and drainFollowUp's guard;
- readers before writers;
- T-COMPOSE;
- the run-shape pins (wholly and partly bound);
- the mixed fit-edge case;
- A7's `return .userInitiated`, with run items checked by run?.token == token;
- interaction 18 reworded to drainIDsLeft.
- Not adopted, from critic-rr21-compose:
- The stub clause: moot, because items carry lane and kind.
- The K4-style 'watcher exists while events wait' clause: a deferred join does not start the watcher (addInterest defers at EngineJobs.swift:110-116, before ensureWatcher at :152), so the clause could fire falsely. UNCONFIRMED. T-WATCH pins the disjunct instead.
- Applied, from critic-rr21-cost:
- the fit charge;
- design-fixer's zeroing;
- removal of the `left != nil` disjunct;
- C10 and C11 as prerequisites;
- BenchSync windows that end at the last answer;
- T-BOUND, merged into RR21-PRESENT-PRUNE.
Moot, from critic-rr21-cost:
- the nil-stub Equivalent: there is no stub;
- the hasWork timing alternative: superseded by the disjunct.
- design-minimal step 7 is replaced by C3.
- Own amendments to the judge:
- The reroutesWaiting counter, instead of 'no field'.
- Clause (c), 'no empty batch waits', is dropped: a purge can empty a batch.
- Clause (d) is strengthened to equality.
- The run acceptance is dropped, because of the bulk release.
- Site 2 decides before its visit (reservation or zeroing), not after it.
- checkRunSettled gains the counter guard.
- The take-off sorts its wholly held tokens. This amends the judge's must_not.
- The purge arm removes items and sorts the removed subset; there is no withdrawn set.
- Own removals (S3-R16 item 3):
- withdrawPurgedJoins' early return;
- the layer append's guard;
- the sites' `!followOwed && !drainingAfterFollow` condition (scheduleDrainFollowUp is now unconditional);
- releaseRerouteHolds' !inboundBlocks filter;
- the drain's `left != nil` disjunct.

## interactions_changed

- 1 Order of replays at verdict V.
- New sequence: movesAfter read, take-off, attemptEnd cleared, owing decided (zeroing or reservation), verdict, visit, then owe or re-route at once.
- The put-back stays inside the existing break; there is no `left != nil` disjunct.
- The final order is unchanged when owed.
- On the fit path, the re-routes precede the visit's rest, as today.
- 3 withdrawPurgedJoins.
- Its early return is removed, not narrowed to eventsAfterFollow.isEmpty.
- The .reroutes arm removes items through MinHeap.removeAll(where:); there is no withdrawn set.
- 4 followedLane.
- The .reroutes owner predicate is stillWants' field form with transfer = from.
- A run item needs only run?.token == token, because its claims were released.
- 5 followBarrierViolations.
- Adds the layer-count equality and the counter clause.
- Drops the judge's clause (c).
- Uses per-(token, asset) predicates, as integrate states.
- 6 drainEverything also zeroes reroutesWaiting.
- 7 invariantViolations.
- Only the waiter and group clauses accept owed items.
- The run clause gets no acceptance: the bulk release happens at owing.
- 8 committed.
- Adds the fit charge (locations.count + items.count > inboundIDsNow) and `!items.isEmpty`.
- Trims use subtractAssets.
- 10 takeOffMovedBefore.
- Also reads lane and kind per token.
- Removes wholly held interests in ascending token order.
- Returns the count of ids.
- 11 There is no dropInterests.
- A whole interest goes through per-token removeInterest, a partial one through subtractAssets.
- Each releases B's index entries in O(ids), which is counted in the site-2 figures.
- 13 Replaced: the pruned binding is an answer difference in both orders.
- It is fixed by pruneBoundContent's eventsAfterFollow guard, plus the hasWork disjunct.
- 14 Still true, and extended: site 2 owes inside drain turns, which are running turns (EngineFollow.swift:411, followFollowUp, advanceFollowForSpaceSweep).
- 18 Drain turns spend drainIDsLeft (512), not inboundIDsNow.
- Spawns: at most 512 per drain turn, and at most inboundIDsNow minus the fit charge in a site's turn.
- The pin needs the prune guard.
- New 19: checkRunSettled (EngineRuns.swift:576) gains `reroutesWaiting == 0`.
- A, B and C do not touch it.
- C's commit turn returns from it early only when it owes.
- New 20: inboundBlocks gains the counter term.
- B's index and A's buckets do not touch it.
- inboundMade's resume loop stays as it is.
- Unchanged and still true as written: 2, 9, 12, 15 (timeCommit; RR-21 adds its own windows to the last answer), 16 and 17.

## recommended_answers

- {
 "question": "Ruling 1: is a cancel or release between the owing instant and the replay of a T21 or present pair timing (.cancelled)?",
 "recommendation": "Agree: timing under S3-R16 item 2. Extend the record to a heal scheduled meanwhile that the T21 replay forgets.",
 "why": "The cancel lands between the two engines' answers (S3-R24 item 5). Today's owed follow has the same class. Answering terminal pairs at the site would cost O(N) lookups and resumes in a commit turn that has 0.14 ms of C2 margin. The heal case is the same shape (EngineTimers.swift:429-433, EngineDispatch.swift:1158)."
}
- {
 "question": "Ruling 2: are the global hold's delays, and an apply during the hold that drops a held job's ids, timing, with no per-target hold?",
 "recommendation": "Agree.",
 "why": "The hold is one O(1) term in inboundBlocks plus a resume at the last batch's end, pinned by T14, T17-hold and the stranded clause. A per-target hold costs O(N x layers) at each publication start. The dropped-id case lands between the two answers."
}
- {
 "question": "Ruling 3: does a pin whose job committed or was superseded between the apply and the replay follow the copy at the replay, as timing, with no layer per commit?",
 "recommendation": "Agree, and include the ENOENT re-queue (T8b).",
 "why": "waitingTarget's .queued, .blocked and .downloading arm drops the pin. The reference re-routes those pairs at that job's next end under the copy then, which equals the copy at the replay unless another apply lands in between: the same approximation as continueInbound's dropped move."
}
- {
 "question": "Ruling 4: probe replayJoin's RR-14-class gap at step 1 in both orders, and add layers for .join if it breaks S3-R16 item 1?",
 "recommendation": "Agree, with a rider: probe twice, at step 1 and again after site 1 lands, in both orders. If the second probe breaks, land R18 in that commit.",
 "why": "A waiting .reroutes keeps followBarrier up in followVisitedFirst too. Joins deferred behind it then reach EngineFollow.swift:704-707 in both orders, so breakage is likely after site 1 even if step 1 passes. Building R18 only when it breaks avoids unreached code (G4)."
}
- {
 "question": "Ruling 5: is present decided at the replay, provided the site's own reconcileIdle keeps owed pairs' bindings, with a purge or eviction in between treated as timing?",
 "recommendation": "Agree. Use the broad guard on eventsAfterFollow in pruneBoundContent plus the hasWork disjunct. Fall back to reroutesWaiting > 0 only if an existing test changes path.",
 "why": "The guard covers the site's own call and every later reconcileIdle (EngineTimers.swift:312, EngineFollow.swift:416), including joins deferred behind a finished batch. It narrows the earlier prune ruling's window without reopening it."
}
- {
 "question": "Ruling 6: which BenchSync figures decide site 2's chunking and C Phase 2?",
 "recommendation": "Agree. Site 2: movedBeforeDrainWaitersTurns, all held and half held. Commit: commitRerouteWaitersTurns, with at least 511 joins behind it, and commitWaitersBoundTurns. If site 2 misses, chunk before the verdict. If the commit misses after C Phase 1, apply C Phase 2.",
 "why": "Because of the fit charge, a large commit makes no re-routes at once, so the commit turn's figure is C's to meet. Site 2's turn is O(held) plus the sort of wholly held tokens plus index releases, with no visit when owing."
}
- {
 "question": "Ruling 7: is a .spaceFailure verdict identified by VerdictKey, whether or not verdictsAfterFollow holds it?",
 "recommendation": "Agree. This is confirmed in the code.",
 "why": "spaceFailed defers with recordDeferredVerdict and deferToFollow(.spaceFailure) and writes no verdictsAfterFollow entry (EngineFailures.swift:569-572). The only writer is defersFailure (EngineFollow.swift:463). A key is live when waitingTarget(t, epoch:) != nil."
}
- {
 "question": "integrate Q1: does a branch reached only in sweepFollowsFirst count as reached in both orders?",
 "recommendation": "Yes, if the test #requires, per order, that the branch's state is absent in followVisitedFirst.",
 "why": "The absence is then pinned rather than assumed. This applies to RR21-VERDICT-ZERO, site 2's take-off branches and A's bucket branches."
}
- {
 "question": "integrate Q2: may one job's terminal events take the Set's order before Phase 2?",
 "recommendation": "No. Keep C3's ascending order.",
 "why": "Subscribers observe that order, and a Set order varies from run to run (a flake under S3-R16 1(d)). C3 already avoids the sort."
}
- {
 "question": "integrate Q3: if T5 cannot be built, may B8 and I2 be dropped together, with Q1 and variant Y recorded?",
 "recommendation": "Yes.",
 "why": "RR-21 does not depend on B8. Its items sit on no job, so I1-I3 hold either way."
}
- {
 "question": "integrate Q4: are misses that depend on stalled subscribers inside C2's reference set?",
 "recommendation": "Include one stalled subscriber; record misses that need more than one.",
 "why": "A single slow consumer is a reachable shape. S3-R22 to S3-R25 name 10,000 ids but no subscriber count."
}
- {
 "question": "integrate Q5: probe the pre-existing candidates now, or only record them?",
 "recommendation": "Probe the ones RR-21 touches this cycle: orphaned run claims at a verdict replayed with the barrier down, and recordRunOutcome's outstanding[T] = nil (EngineRuns.swift:519). Record variant Y's T1 half.",
 "why": "RR-21's bulk release and the checkRunSettled guard interact with both run candidates, so their state must be known before RR21-RUN-MIDDRAIN is ruled."
}
- {
 "question": "Judge OQ1, OQ4, OQ5, OQ6, OQ7 and OQ10.",
 "recommendation": "Answered by rulings 1, 2, 3, 4, 5 and 7 above.",
 "why": "Each one maps directly to the ruling with the same subject."
}
- {
 "question": "Judge OQ2: the commit's own turn with 10,000 user waiters, all bound.",
 "recommendation": "Pin it as commitWaitersBoundTurns after C Phase 1. If it misses, it is C Phase 2's trigger, not a fourth RR-21 site.",
 "why": "With no unbound pair, RR-21 owes nothing (`!items.isEmpty`). C3 removes publishTerminal's sort. resolveAll's token sort (EngineJobs.swift:618) and the resumes remain C's."
}
- {
 "question": "Judge OQ3: site 2's take-off at once with 10,000 user waiters.",
 "recommendation": "Ruling 6: movedBeforeDrainWaitersTurns decides. The fallback is chunking before the verdict, about 3 branches.",
 "why": "When owing, zeroing removes the visit from that turn. What is left is O(held) plus the token sort plus index releases."
}
- {
 "question": "Judge OQ8: waitingTarget's unreached case.",
 "recommendation": "Reached. T8b covers the pin caller and integrate step 7's Shapes A and B cover the InboundMove caller, in both orders. One ruling covers both callers of the single refactored function.",
 "why": "ENOENT for a cancelled attempt re-queues the pinned job at the same epoch (EngineDispatch.swift:1217-1225)."
}
- {
 "question": "Judge OQ9: inventory rows outside RR-21.",
 "recommendation": "Record them with their owners' pins: move's sort (EngineFollow.swift:945-946) goes with B's moveItems; deferBehindVerdict goes with A5, now O(1); deliver's group copy goes with C5, now in place.",
 "why": "Each one is fixed by an integrate-c21 item that is already in the plan."
}
- {
 "question": "Own 1: accept the reroutesWaiting counter as new EngineState?",
 "recommendation": "Yes.",
 "why": "inboundBlocks runs for each move made while a wait exists (EngineFollow.swift:1273-1275), and checkRunSettled runs on every resolve, so an O(E) scan there is a C2 risk. The counter has its own clause."
}
- {
 "question": "Own 2: accept the fit charge at site 1?",
 "recommendation": "Yes.",
 "why": "The converged commit is 0.14 ms under budget. The cost is that more commits owe: the six low-budget suites may change path, each with a record."
}
- {
 "question": "Own 3: should site 2 decide before its visit, with reservation or zeroing, rather than after it as the judge has it?",
 "recommendation": "Yes, before.",
 "why": "One decision, no new break disjunct, and the turn bound holds. The visit's budget at or below the bound shrinks by ids, which is an order difference within an existing class, recorded with PROBE-RR21-RESERVE-REJOIN."
}
- {
 "question": "Own 4: is the checkRunSettled counter guard a blocking fix?",
 "recommendation": "Yes. Probe it first with RR21-RUN-MIDDRAIN (S3-R19 item 1).",
 "why": "Without the guard, [V, B] as the queue's last events settles the run at V's resolveAll, because followBarrier is false mid-drain. The run ends with fewer assets fetched than at-once, in both orders: S3-R16 1(a)."
}
- {
 "question": "Own 5: accept the take-off's sort of wholly held tokens, amending the judge's must_not?",
 "recommendation": "Yes.",
 "why": "heldLane is set at the last removal (EngineJobs.swift:354-356), and Job.lane is computed from the remaining interests, so removing in Dictionary order is a flake. The sort is never larger than today's at :558."
}
- {
 "question": "Own 6: should the purge remove items and sort the removed subset, instead of keeping a withdrawn set?",
 "recommendation": "Yes.",
 "why": "There are fewer branches, the replay never meets a withdrawn item, and the sort mirrors withdrawPurged. The figure is purgeWhileOwedTurns."
}
- {
 "question": "Own 7: use `indirect` for the .reroutes case?",
 "recommendation": "Yes, unless MemoryLayout shows the stride unchanged without it.",
 "why": "Every put-back inserts at index 0 and memmoves the queue (EngineFollow.swift:213-214)."
}
- {
 "question": "Own 8: take an id whole in continueReroutes?",
 "recommendation": "Yes, as continueMove does.",
 "why": "Splitting one id's tokens across turns would answer the same id at two instants. commitTwoTokensTurns pins the cost."
}
- {
 "question": "Own 9: build the .join layers before the re-probe?",
 "recommendation": "No. Build them in the commit after the re-probe that follows site 1, and only if it breaks.",
 "why": "G4: code that no test reaches if the probe passes."
}

## plan_gaps

- The six low-budget suites can change path through the fit charge, site-2 reservation or the idle guards: EngineFollowBarrierDrainBoundTests, MoveRevalidationTests, RestOrderTests, SharedMoveTests, StaleRerouteTests (at 1, so inboundIDsNow 1) and TurnTotalTests. Each changed expectation needs a one-to-one record. The idle and ledger tests also need checking: EngineFirstReadingTests:115, EngineIdleTests:40, EngineSync1HalvesTests:125/:136/:159, EngineRegressionCycle3Tests:57/:96/:290/:307.
- B5 returns MoveItem (asset, token) only. RR-21 reads lane and kind per token in one scoped read; B5's signature is unchanged.
- B's merge gate (concentrationPublicationTurns with the index) must be re-measured after committed's rewrite, because the trims now release index entries through subtractAssets.
- C's Phase 2 trigger must be re-checked after site 1. The commit turn now includes either the collect pass and owing, or at most inboundIDsNow re-routes at once.
- A11 must land before RR-21. With the spawn-nil branch present, a refused spawn would clear events without zeroing the counter.
- continueReroutes must have no analogue of continueMove's :195 (jobs[from] can be an F-20 job) and no stub lookup (:202).
- recordDeferredVerdict's away filter (EngineFollow.swift:514) has no figure. It costs O(job.assets) when followOwed. Time the deferral turn in movedBeforeDrain.
- waitingTarget: integrate step 7's Shapes A and B reach the InboundMove caller; T8b reaches the pin caller. Both orders.
- The drain branch's removal (A11): the liveness argument must cite drainEverything and the isRunning guards, never the spawn-nil branch.
- The judge's invariant 'no run settles while a batch waits' held only for the queue. The gap mid-drain needs the checkRunSettled guard (R13) and RR21-RUN-MIDDRAIN.
- scheduleDrainFollowUp is private (EngineFollow.swift:379), while sites 1 and 3 live in EngineDispatch.swift. Add the internal deferReroutes wrapper.
- Integrate interaction 1 names rerouteTakenOff returning left; under this design, replay returns EventAfterFollow?. Update the integrate text.
- The S3-R25 item 10 mutation table must list every RR-21 branch with its test and per-order kill counts, including the probabilistic drop-sort kill rate for RR21-HELDLANE.
- Draft row :4858 (site 3) has no inventory figure today. supersededRerouteTurns supplies it.

## likely_blocking

- replayJoin's RR-14 gap becomes reachable in followVisitedFirst once batches defer joins in both orders.
- Prevention: re-probe after site 1 in both orders. If it breaks, land R18 in the same commit (ruling 4).
- Run settlement mid-drain while owed run items hold no claim.
- Prevention: checkRunSettled's counter guard, plus RR21-RUN-MIDDRAIN, probed red first.
- C2 misses in four places:
- site 2 at once with 10,000 user waiters;
- the owing commit's collect pass and trims, on top of C Phase 1's turn;
- followedLane with 10,000 non-user items x layers;
- countRunFetched/offerRunProgress per present run item.
Prevention: the BenchSync figures before merge. Contingencies: site-2 chunking (ruling 6); C Phase 2; a per-batch lane summary to skip batches in followedLane (UNCONFIRMED).
- G4: about 30 new branches, each needing a 2/2 kill per order, including sweep-first-only ones.
- Prevention: the branches table, per-order #require, inject-one-violation tests, and the Removed and Equivalent records.
- Flake from Dictionary-order removal (heldLane) or from unsorted purge effects.
- Prevention: the take-off sorts its wholly held tokens; the purge's removed subset is sorted.
- False violations in existing tests if an owing site lands before the acceptances.
- Prevention: readers before writers, or readers and site 1 in one commit.
- The A6 composition: the put-back against the overflow.
- Prevention: T-COMPOSE.
- Idle-silence or ledger tests change path because of the broad guards.
- Prevention: run the full suite at that commit; use the narrow fallback, with its record.
- A verifier reports that site 2's calls at or below the bound changed, through the reservation.
- Prevention: record it as order (the cycle-19 class), with PROBE-RR21-RESERVE-REJOIN results in both orders.
- An empty batch owed by a large commit.
- Prevention: `!items.isEmpty`, with T1-zero.

## unconfirmed

- Every cost and time estimate: per-re-route cost, the take-off turn, the collect pass, the followedLane walk, the purge sort, index releases and per-spawn cost.
- MemoryLayout<EventAfterFollow>.stride with and without `indirect`.
- That every test shape can be built: T5-T11, T8b's ENOENT shape, RR21-HOP's .locked variant, and RR21-RUN-MIDDRAIN in followVisitedFirst.
- Which existing tests change path.
- That no synchronous replay path calls reconcileIdle. The callers found are async entries, plus finishRun (EngineRuns.swift:828), which the counter guard keeps from running mid-drain.
- BenchSync helper lines cited from the critics: releaseOneHeldFollowOrDrainTurn :1104-1120, timeCommit :3253-3266, followedLaneMedian :2900.
- B5's and A6's exact code, which does not exist yet.
- That the .spaceFailure job is .failed while it is deferred. relane's comment covers ENOSPC (EngineJobs.swift:285-296). This matters for heldLane and for pin liveness.
- That C1's local `lazy var` compiles in Swift 6.3 strict mode; C1 has a fallback.
- That the moved-before state, and RR21-VERDICT-ZERO's state, arise only in sweepFollowsFirst.
- That a deferred join can leave eventsAfterFollow non-empty with no watcher started. This is the reason the K4-style watcher clause was not adopted.
- That the purge arm's predicate mirrors withdrawPurged exactly, under the copy now.
- That ValidatedManifest is Sendable.
- That finishRun removes the interests of a cancelled run's owed items that replay into it.
- Whether PROBE-RR21-HEAL-T21 and PROBE-RR21-RESERVE-REJOIN shapes are reachable end to end.

## branches

- B1 committed `!items.isEmpty`.
- Reached: T1-zero (both orders).
- Drop-mutant: an empty batch is owed; killed by asserting eventsAfterFollow is empty after the commit turn.
- B2 committed `locations.count + items.count > inboundIDsNow`.
- Reached: T1-edge and T1-fit (both orders).
- Mutants killed: dropped operand; `>=`; always-owe; never-owe.
- B3 committed lazy `captured` (C1).
- Reached: T3-captured (both orders).
- Drop-mutant: refused is never set, so the F-20 hold is missing.
- B4 owing closure `if refused { holdForManifest }`.
- Reached: T3-captured on the owing path (both orders).
- Drop-mutant: an unheld fresh job downloads superseded content.
- B5 supersede `if let bound, pairs > bound`.
- Reached: T2, T2-two and T2-edge (both orders).
- Mutants killed: dropping the count test; `>=`; nil passed by publicationFailed.
- B6 site 2 `owes = ids > drainIDsLeft`.
- Reached: T3 and T3-two.
- Arises only in sweepFollowsFirst (the moved-before state), with a #require in the other order.
- Mutants killed: always and never.
- B7 site 2 ternary `owes ? 0 : left - ids`.
- Zeroing: RR21-VERDICT-ZERO. Reservation: T3-two.
- Sweep-first only.
- Drop-mutants: the batch is lost or the visit runs (counter clause); a 6-id turn.
- B8 take-off: whole interest (removeInterest) vs partial (subtractAssets).
- Reached: T3 (sweep-first).
- Mutants killed: always removeInterest (an id is lost); always subtractAssets (an empty interest is left).
- B9 take-off ascending sort of wholly held tokens.
- Reached: RR21-HELDLANE (sweep-first).
- Descending mutant killed 2/2. The drop mutant's kill rate is recorded.
- B10 continueReroutes `item.asset != current`.
- Reached: T-two-tokens (both orders).
- Drop-mutant: counts per item.
- B11 continueReroutes `guard spent < drainIDsLeft`.
- Reached: T1 (both orders).
- Drop-mutant: a 10-id turn.
- B12 continueReroutes empty-heap tail: counter decrement and release.
- Reached: T14 and T16 (both orders).
- Drop-mutant: holds are never released (time limit, counter clause).
- B13 releaseRerouteHolds `guard reroutesWaiting == 0`.
- Reached: T17-hold (both orders).
- Drop-mutant: early bind with a second request.
- B14 replay arm `items.isEmpty ? nil : .reroutes(batch)`.
- Reached: T1 (both orders).
- Mutants killed: always nil (the batch is lost: counter clause); always returned (an endless re-insert: time limit).
- B15 drain put-back owed prefix.
- Reached: T1 and T3.
- Drop-mutant: the batch is lost (counter clause).
- B16 rerouteListing T21 `return batch.copy`.
- Reached: T4 (both orders).
- B17 rerouteListing pin `layer.ends` plus the waitingTarget ternary.
- Reached: T5 (pin holds) and T8/T8b (pin left) (both orders).
- B18 rerouteListing `guard let next else return incoming`.
- Reached: T10.
B19 rerouteListing `index + 1 < layers.count`.
- Reached: T9.
- Both orders.
- B20 layer append ends terms.
- publishing: T5. verdict: T6. after-the-batch: T7. `deferredAfter > previous.applies`: T11.
- Both orders; T7's state is natural in sweep-first.
- B21 inboundBlocks counter term.
- Reached: T14 and RR21-WINDOW-GATE (both orders).
- B22 followedLane arm predicates.
- Owner (waiter, group, run, system), withdrawn token, T21 skip, isBound skip, sameTransfer raise, `return .userInitiated`.
- Reached: T12 (a)-(d) plus the group and run variants (both orders).
- B23 purge arm.
- Predicate conjuncts and owner effects per kind.
- Reached: T13 and T13-nonpurged, with group and heal variants (both orders).
- B24 pruneBoundContent eventsAfterFollow guard.
- Reached: RR21-PRESENT-PRUNE at each site (both orders).
B25 hasWork disjunct.
- Reached: T-WATCH (both orders).
- B26 checkRunSettled `reroutesWaiting == 0`.
- Reached: RR21-RUN-MIDDRAIN (both orders UNCONFIRMED; otherwise a #require).
- B27 oweReroutes run release and nil-when-empty.
- Reached: T18 (both orders).
- Drop-mutant: the run clause fires.
- B28 deferReroutes' scheduleDrainFollowUp call.
- Reached: T1 with no follow owed.
- Drop-mutant: the events-wait clause fires.
- The condition the judge had is Removed, so it has no mutant.
- B29 drainEverything counter zeroing.
- Reached: T16.
B30 waitingTarget `.queued, .blocked, .downloading`.
- Reached: T8b (pin caller) and integrate Shapes A and B (InboundMove caller), both orders.
- B31 each new invariant clause.
- Reached: inject-one-violation tests.
B32 contingent .join layers (R18).
- Reached only if ruling 4's probe breaks, with RR21-HOP's join variant in both orders.
- Removed, with no mutant:
- the `left != nil` disjunct;
- the `!followOwed && !drainingAfterFollow` condition;
- the layer-append guard;
- withdrawPurgedJoins' early return;
- the !inboundBlocks filter;
- clause (c).

## commit_plan

- C0 Baseline on wp/s3f after C Phase 1, A and B.
- Run `SWIFTPM_SCRATCH=.build-rr21 bash Scripts/verify.sh --quick` and quote its last line.
- Record 'before' figures for concentrationCommitRerouteTurns and movedBeforeDrainTurns, at load 10 or less, under sim.lock.
- C1 Probe replayJoin's gap (ruling 4) in sweepFollowsFirst and record the result in the draft. Commit no failing test.
- C2 Types and pure helpers, with no change in behaviour:
- MinHeap, with MoveProgress wrapping it (its tests unchanged) and removeAll(where:) unit tests;
- RerouteItem, RerouteLayer and RerouteBatch;
- `indirect case reroutes` with every exhaustive switch arm;
- replay returning EventAfterFollow?, with the drain put-back;
- reroutesWaiting;
- the waitingTarget refactor.
- C3 Readers and site 1, in one commit, or readers first with tests that assert real outcomes through deferReroutes.
- Readers: continueReroutes, releaseRerouteHolds, the inboundBlocks term, rerouteListing, the layer append, the invariant acceptances and clauses, the followedLane arm, the purge arm, drainEverything's zeroing, and the checkRunSettled guard (RR21-RUN-MIDDRAIN red first).
- Site 1: committed's rewrite with C1, C3 and the fit charge, plus the idle guards.
- Tests: T1 family, T3-captured, T4-T18, RR21-HOP, RR21-WINDOW-GATE, RR21-PRESENT-PRUNE and T-WATCH at site 1.
- Then run the low-budget, idle and ledger suites, measure the commit and drain turns, and re-check C's Phase 2 trigger and B's merge gate.
- C4 Re-probe the join gap in both orders. If it breaks, add R18 with its tests in this commit.
- C5 Site 3: supersede's bound.
- Tests: T2 family; RR21-HOP, RR21-WINDOW-GATE and RR21-PRESENT-PRUNE at site 3.
- Measure supersededRerouteTurns, supersededUserTurns and runSuperseded.
- C6 Site 2: the take-off, the decision before the visit, and the replay's return.
- Tests: T3 family, RR21-VERDICT-ZERO, RR21-HELDLANE, T-COMPOSE, T-shared, PRESENT-PRUNE at site 2.
- Measure movedBeforeDrainTurns, movedBeforeDrainWaitersTurns and movedBeforeAndAfterTurns.
- If site 2 misses C2, add the chunking here (ruling 6).
- C7 Records (R19), and the mutation table with per-order kill counts.
- C8 Close-out:
- the full SyncBenchmarks at load 10 or less, under sim.lock;
- covdiff on the changed lines, and the mutation table (S3-R25 item 10);
- 30 simulator iterations per argument;
- coverage three times;
- the tools-6.4 check with 0 warnings (S3-R13);
- `bash Scripts/verify.sh --full`, quoting `VERIFY: PASS`.
Every commit stays green with `SWIFTPM_SCRATCH=.build-<name> bash Scripts/verify.sh --quick`. Each failing test is run red before its fix in the same commit (P3).

## clean_cycle_estimate

RR-21's area: about 0.3 (range 0.2-0.4) that cycle 21 finds no blocking item there. That assumes it is implemented as specified, with every test and BenchSync case, and with rulings 1-7 given as intended before the verifiers start. It falls to about 0.2 if the join-gap re-probe breaks and the .join layers land in the same cycle.

Whole plan (A, B, C Phase 1 and RR-21): about 0.12 (range 0.08-0.2).

What pulls it down:
- about 30 new branches, each needing a 2/2 kill per order;
- the user-waiter C2 shapes, which are not measured yet (ruling 6);
- two holes found only in this pass (the run settling mid-drain, and the prune), which suggests more interleavings of that kind;
- the verifiers have found a new interleaving every cycle.
