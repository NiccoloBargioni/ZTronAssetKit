# design2:defer-bucket

Read-only analysis for ruling S3-R26 (workflow wf_bc7908d4-1ad, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## item

S3-R26, WP-F close-out (cycle 21): make deferBehindVerdict's per-join deferral O(1) amortised. Sources: s3f-c20-issues.json /lenses/reqs/issues/2 (reqs #3, PROBE-C20R-DEFER-BEHIND-C2, 35.78 ms best) and /lenses/correct/issues/1 (correct #2, PROBE-C20C-DEFER-BEHIND, 39.55 ms best). Every turn must stay within c2Budget at 10,000 ids in every grouping, and no answer may change in either LaneDropVisit order. This is a read-only analysis of wp/s3f at 8e1fb24 (worktree clean).

## recommendation

Keep each join that a follow's visit defers behind a waiting exit verdict out of the queue. It goes into one new EngineState table, keyed by the verdict event's own (transfer, epoch), in arrival order, together with its stamp.

**deferBehindVerdict.** It becomes two O(1) writes:
- the existing joinsAfterFollow registration;
- one append to the table.

The lastIndex scan, the fallback and both mid-array inserts are removed.

**The drain.** It puts a verdict's joins back when it replays that verdict event, whether the verdict is given or skipped:
- the joins leave the table;
- they go to the head of eventsAfterFollow, newest first. That is today's order, since each insert landed right behind the verdict;
- they sit ahead of the batch's rest, and behind RR-21's owed `.reroutes` if that lands;
- the batch ends there. So a turn makes at most one put-back, and it replays none of those joins; they replay in the following turns under the existing 512-event bound.

**Readers.** Three readers walk waiting joins between turns. Each is extended to the table with today's predicates and today's order:
- the purge, which walks each bucket at its verdict's position in the queue, newest first;
- followedLane, which takes a max, so order does not matter;
- the invariant recount.

laneEventsWaiting and followBarrier need no change.

**New clauses** for the new state:
- K1: exactly one waiting verdict event per key;
- the extended recount;
- K3: the stamps.

**Shutdown.** drainEverything clears the table. Separable and recommended: remove scheduleDrainFollowUp's unspawnable branch, which no test reaches (0 hits), following S3-R25 item 7, and add a not-running clause.

**Answers and order.** The drain replays today's exact event sequence under the same stamps. The only change is one extra drain-turn boundary after such a verdict, and today's drain already ends turns there; this is timing only. Order is kept, so nothing is recorded under S3-R16 item 2 and RR-15 stays as written.

**Pins.**
- One deterministic test family, run in both orders, with per-turn assertions in the sweep-first order.
- Forced-clause checks.
- Skip, purge, 429-lane and shutdown variants.
- A BenchSync release case, deferBehindVerdictTurns, over {404, timeout} × {one prefetch group, one user waiter per id} at 10,000 ids. It passes at best of 3 ≤ c2Budget, measured at a 1-minute load ≤ 10.

## mechanism

- 1. Types. In EngineFollow.swift, after JoinAfterFollow (:1572-1590), add two structs, each with a /// doc:
- `struct VerdictKey: Hashable, Sendable { let transfer: TransferID; let epoch: UInt64 }`. It identifies a waiting `.attemptFailed` or `.spaceFailure`. No other exit shares it, because lastEpoch is global (EngineState.swift:230) and is bumped at job creation (EngineJobs.swift:137) and at every start (EngineDispatch.swift:697-698).
- `struct JoinBehindVerdict: Sendable { var join: JoinAfterFollow; let stamp: WorldStamp }`.
TransferID is Hashable and Sendable (ZTronAssetModel/Identity/TransferID.swift:9). WorldStamp (:1531) and JoinAfterFollow (:1573) are Sendable.
- 2. Classifier. In EventAfterFollow, after endsDrainBatch (EngineFollow.swift:1436-1443), add `var verdictKey: VerdictKey?`. It uses an exhaustive switch with no default:
- `case .attemptFailed(let transfer, let epoch, _), .spaceFailure(let transfer, let epoch, _): return VerdictKey(transfer: transfer, epoch: epoch)`;
- `case .join, .removal, .conditions, .readmit, .unblock, .retryDue, .throttleAnswers, .spaceSweep: return nil`.
This is the predicate today's lastIndex closure uses (:967-972). When RR-21's `.reroutes` lands, the compiler forces it into the nil arm.
- 3. State. In EngineState.swift, after joinsAfterFollow (:156), add `var joinsBehindVerdicts: [VerdictKey: [JoinBehindVerdict]] = [:]`. Its doc says:
- these are the joins a follow's visit deferred behind a waiting exit verdict, by that verdict's key, in arrival order, each with the visit's decision instant;
- they are registered in joinsAfterFollow too;
- the drain puts them back at the head of eventsAfterFollow, newest first, when it replays the verdict, given or skipped;
- each key's verdict waits exactly once (invariantViolations()).
Also amend joinsAfterFollow's doc (:153-155) to name the table.
- 4. deferBehindVerdict (EngineFollow.swift:964-978). Its body becomes two O(1) writes:
- `self.state.joinsAfterFollow[join.token, default: [:]][join.asset] = join.entry.transferID` (today's :975);
- `self.state.joinsBehindVerdicts[VerdictKey(transfer: target.transfer, epoch: target.epoch), default: []].append(JoinBehindVerdict(join: join, stamp: self.worldStamp()))`.
Delete `let events` (:965), the lastIndex scan (:966-973), the fallback `verdict ?? events.count - 1` (:974, whose assumption becomes K1) and both inserts (:976-977).
worldStamp() returns the visit's reading (:251-253), which is today's stamp. Its only callers are visit (:797-799) and continueVisitRemainder (:821-823), because EngineJobs.swift:117 requires inFollowVisit and not bringingInbound.
Rewrite the doc (:955-963): the join waits aside under its verdict's key and is put back right behind the verdict, newest first. That is the place the cycle-17 insert gave it, without the O(E) scan and the two inserts per join.
- 5. Put-back in the drain loop (EngineFollow.swift:204-216).
- After `self.withReading(stamp) { self.replay(event) }`, add `let behind = event.verdictKey.flatMap { self.state.joinsBehindVerdicts.removeValue(forKey: $0) } ?? []`.
- The break condition (:210) becomes `!behind.isEmpty || self.state.followMoving != nil || self.state.drainIDsLeft <= 0`.
- The re-insert (:212-214) becomes `self.state.eventsAfterFollow.insert(contentsOf: behind.reversed().map { EventAfterFollow.join($0.join) } + rest.map { $0.0 }, at: 0)` and `self.state.eventStamps.insert(contentsOf: behind.reversed().map { $0.stamp } + rest.map { $0.1 }, at: 0)`. A cost-only variant inserts the rest first, then the reversed bucket, both at 0, so each join is copied once.

The put-back follows every replayed verdict event. It does not depend on replayVerdict's guards (:608-614), on the `.spaceFailure` arm's guard (:349-351), or on verdictsAfterFollow, which removeJob clears (EngineJobs.swift:434).
The tail (:217-229) is unchanged. The queue is non-empty, so scheduleDrainFollowUp runs, or scheduleFollowFollowUp when the verdict's after-visit left a rest.
Add one sentence to the doc (:175-186): a verdict's deferred joins go back to the head, newest first, when it replays, and the batch ends there.
- 6. Combined with RR-21 (design-minimal step 12), whichever lands first:
- `let left = self.withReading(stamp) { self.replay(event) }`;
- break when `left != nil || !behind.isEmpty || self.state.followMoving != nil || self.state.drainIDsLeft <= 0`;
- head = `(left.map { [($0, stamp)] } ?? []) + behind.reversed().map { (EventAfterFollow.join($0.join), $0.stamp) } + rest`, inserted into eventsAfterFollow and eventStamps at 0.
So the owed `.reroutes` comes first, then the bucket newest first, then the batch's rest.
- 7. followedLane (EngineFailures.swift:821-836).
- Hoist the queue loop's guards (:823-830, verbatim) into a local `func reaches(_ join: JoinAfterFollow) -> Bool`. It checks: !join.withdrawn; !withdrawn.contains(join.token); target is the copy's entry when join.listed and the copy moved the id, else join.entry; sameTransfer(target, job.entry); stillWants(join).
- The queue loop becomes `guard case .join(let join) = event, reaches(join) else { continue }`. Its `break` (:833) becomes `return .userInitiated`. The answer is the same as :837, and the bucket walk is skipped.
- After the queue loop, inside the same `if lane != .userInitiated` block, add `for bucket in self.state.joinsBehindVerdicts.values { for waiting in bucket where reaches(waiting.join) { raise(waiting.join.lane) } }`, with no early exit.
- Amend the doc (:709-720).
- 8. withdrawPurgedJoins (EngineCommands.swift:1049-1073).
- Move the per-join body into `private func withdrawPurgedJoin(_ join: inout JoinAfterFollow, _ isPurged: (AssetID) -> Bool) -> Bool`: `guard !join.withdrawn, join.lane < .userInitiated, join.kind != .waiter, isPurged(join.asset) else { return false }`, then today's unregister with dropGroupMember and heals (:1057-1068), then `join.withdrawn = true; return true`.
- The loop over `self.state.eventsAfterFollow.indices`:
  - for `.join(var join)`: if the helper returns true, write `.join(join)` back;
  - otherwise: `if let key = event.verdictKey, let count = self.state.joinsBehindVerdicts[key]?.count { for slot in (0..<count).reversed() { guard var join = self.state.joinsBehindVerdicts[key]?[slot].join, self.withdrawPurgedJoin(&join, isPurged) else { continue }; self.state.joinsBehindVerdicts[key]?[slot].join = join } }`.
- Each bucket is walked at its verdict's queue position, newest first: today's exact order of per-join operations.
- The guard (:1050-1052) stays valid.
- Withdrawn bucket joins stay in the bucket and replay as no-ops after the put-back (replayJoin :694-696).
- Amend the doc (:1041-1048).
- 9. followBarrierViolations (EngineCommands.swift:2003-2069).
- Before the loop: `var verdictEvents: [VerdictKey: Int] = [:]`.
- First line of the loop body (:2016): `if let key = event.verdictKey { verdictEvents[key, default: 0] += 1 }`.
- Before the recount comparison (:2031): `for bucket in self.state.joinsBehindVerdicts.values { for waiting in bucket where !waiting.join.withdrawn { joins[waiting.join.token, default: [:]][waiting.join.asset] = waiting.join.entry.transferID } }`.
- After the stamps clause (:2034-2036): K1 and K3, as given in invariants.
- Amend the doc (:1997-2002).
- 10. Shutdown. In EngineShutdown.swift, add `self.state.joinsBehindVerdicts = [:]` after `self.state.joinsAfterFollow = [:]` (:124). This is inside drainEverything, which runs synchronously in shutdown's first turn (EngineLifecycle.swift:490-498).
- 11. Separable, recommended: scheduleDrainFollowUp (EngineFollow.swift:379-400). Drop `let spawned =` and the `if spawned == nil { … }` branch (:390-398), as cycle 20 did for scheduleFollowFollowUp (S3-R25 item 7). spawn is @discardableResult (EngineLifecycle.swift:51).
The branch had 0 hits in cycle 20's coverage (s3f-probes-c20/correct/logs/covdiff.log:11-21), and it cannot run:
- spawn refuses only when not running (EngineLifecycle.swift:53-58);
- drainFollowUp returns unless running (:411-413);
- no follow runs after shutdown's first turn, which empties the queue (EngineShutdown.swift:118-125);
- the engine becomes degraded only during start (EngineLifecycle.swift:228, :260).
Its assumption becomes K4, placed next to the cycle-20 clause (EngineCommands.swift:2009-2013). If S3-R26 keeps this out of scope, keep the branch and add the clear after :396 instead; no test would reach that statement.
- 12. Tests: a new file, Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierDeferBehindTests.swift (extension EngineFollowBarrierTests). It reuses:
- followIDsPerTurn = 4 through EngineState.followIDsPerTurn (EngineState.swift:108; drainBoundIDsPerTurn);
- applyHeld and finishHeld (EngineFollowBarrierReachTests.swift:19-40);
- runOneHeldTurn (EngineFollowBarrierDrainBoundTests.swift:51-62);
- FollowBarrier.fillers (EngineFollowBarrierTests.swift:88-93);
- `engine.violations { }` (EngineOutcomeTests.swift:490-499).
Cases: T1, T1-skip, T-PG, T-FL, T-FL' and T-SD, plus the forced checks F-K1, F-K3, F-SPACE and F-K4. Shapes and mutants are in new_branches. Every case runs in both LaneDropVisit orders and expects the visit-first answers.
- 13. BenchSync (Tests/ZTronAssetKitBenchmarks/BenchSync.swift).
- Add `enum DeferBehindShape: String, Sendable, CaseIterable { case notFoundGroup, timeoutGroup, notFoundUsers, timeoutUsers }`. The reqs probe is notFoundGroup; the correct probe's verdict is timeoutGroup.
- Add `SyncBench.deferBehind(count:shape:) -> DeferBehindRun` beside movedBeforeDrain (:3278). Build it like PROBE-C20R-DEFER-BEHIND-C2 (.build-orchestrator/s3f-probes-c20/reqs/VerifyC20ReqsC2Probes.swift:62-115), on followBench (:3701), sharing (:3751), verdictWaits (:2889), longestWait (:1407) and releaseOneHeldFollowOrDrainTurn (:1104).
- The shape: `count` ids share H's 16 B, wanted by one prefetch group or by a user waiter each. O, with a user waiter, downloads, scripted [.hold, .fail(404), .stage(oBytes)] or [.hold, .fail(.transient(.timedOut, retryAfter: nil)), .stage(oBytes)]. v3 changes only the fillers, with follow-ups held, so O's verdict waits. v4 maps every id to O's content. The heartbeat times v4's apply, and every held follow and drain turn is timed inside the actor.
- The test `deferBehindVerdictTurns(_:)` goes in the R-SYN-11 suite next to concentrationTurns (:695-733): warm-up at 1,000, then 3 runs at 10,000.
- Per-run setup #expect:
  - verdictWaited;
  - no join entered eventsAfterFollow during the follow (its maximum equals its count before v4);
  - eventsAfterFollow.count is 10,000 and the table is empty after the turn that replayed O's verdict;
  - after the drain, O's content holds 10,000 ids (404, a fresh job) or 10,001 (timeout, O);
  - violations are empty.
- Timing #expect: best of 3 of max(applyWait, longest held turn) ≤ c2Budget (:129), and best of 3 heartbeat ≤ c2Budget, at a 1-minute load ≤ 10 (S3-R23 item 3).
- 14. Docs (docs/adr-drafts/s3f.md):
- Fill the inventory row (:4850): 'O(1) amortised a join; one O(B + E) put-back a verdict, ending its drain turn', with deferBehindVerdictTurns' figures.
- Record the decision: context; options, the rejected_alternatives; decision; consequences, namely the drain-turn boundary after such a verdict (timing only).
- RR-15 (:3871, :4195) stays true as written.

## invariants

- K1 (new; followBarrierViolations, after :2036). The code: `let orphaned = self.state.joinsBehindVerdicts.keys.filter { verdictEvents[$0] != 1 }`, with a violation when `!orphaned.isEmpty`. Message: '<orphaned.count> verdicts hold joins behind them without exactly one waiting event'.
Predicate: for every key k of joinsBehindVerdicts, exactly one e in eventsAfterFollow has e.verdictKey == k.
It replaces deferBehindVerdict's fallback (:974). It also implies, while any bucket exists:
- the barrier is up (followBarrier :97-99);
- the history is kept (endWorldHistory :336-338);
- a drain is owed or scheduled (the clause at :2006-2008).
- K2 (extended recount, :2031-2033). joinsAfterFollow == R, where R[token][asset] = entry.transferID. R covers every non-withdrawn join in a waiting `.join` event and every non-withdrawn bucket entry; later entries overwrite earlier ones, as today. The message is unchanged: '<n> interests' joins wait for the follow, <m> with their event'.
- K3 (new, after K1). The code: `let stale = self.state.joinsBehindVerdicts.values.reduce(0) { sum, bucket in sum + bucket.filter { $0.stamp.view >= self.state.worldHistory.count }.count }`, with a violation when `stale > 0`. Message: '<stale> joins wait behind verdicts with decision instants over <worldHistory.count> views'.
Predicate: every bucket entry's stamp.view < worldHistory.count. A replay reads worldHistory[stamp.view] under withReading (:273). K3 follows from K1 and the history being append-only, and it is still checked.
- K4 (new, only with mechanism 11; next to EngineCommands.swift:2011-2013). The code: `if !self.isRunning, !events.isEmpty`. Message: '<events.count> events wait for a follow while the engine is <lifecycle>'.
Predicate: when the engine is not running, eventsAfterFollow is empty, and by K1 so is joinsBehindVerdicts.
- Unchanged and still holding:
- The waiter, group and run acceptances (EngineCommands.swift:1707-1712, :1777-1783, :1812-1817) accept bucket joins through joinsAfterFollow, where deferBehindVerdict still registers them.
- The events-wait-only-while-owed clause (:2006-2008) covers buckets through K1.
- The stamps count clause (:2034-2036) holds, because a put-back inserts events and stamps in step.
- followBarrier needs no new disjunct, by K1.

## answer_equality_argument

1. **Same values.** Each deferred join is the same JoinAfterFollow that today's code inserts, with the same stamp: the visit's reading (EngineFollow.swift:251-253). It is registered in joinsAfterFollow as today (:975).

2. **Same place.** Today's insert put each join at lastIndex(verdict) + 1, so the joins behind a verdict sat right after it, newest first, ahead of everything that followed it. No other event could get between them:
- deferToFollow appends at the tail (:233-236);
- the drain takes a prefix and re-inserts its unreplayed suffix at the head (:199-214), and it does not run while a follow is owed (:189);
- deferBehindVerdict runs only inside a follow's visit (EngineJobs.swift:117);
- the purge rewrites events in place (EngineCommands.swift:1071).

The put-back at the verdict's replay places them exactly there: the reversed bucket, then the batch's rest, then the queue. So the drain replays the identical event sequence, each event under the identical stamp.

3. **Given or skipped.** The put-back is keyed by the event's own (transfer, epoch) and follows every replay of that event. It is independent of:
- replayVerdict's guards (:608-614);
- the `.spaceFailure` guard (:349-351);
- verdictsAfterFollow, which removeJob clears (EngineJobs.swift:434).

So a skipped verdict's joins replay right after it, as today. Once the job is gone, later visits join at once, because no job has deferredAfter set (EngineJobs.swift:117) — also as today.

4. **Turn boundary.** The put-back ends the drain turn, and the joins start the next one. Today's drain already ends a turn right after a verdict, when its after-visit leaves a rest, when the turn's ids are spent (:210-215), or at the 512th event. Every event re-validates what it names (:178-180), and per the drain's doc 'the events wait in order either way, so no answer changes' (:184-186). This is timing only (S3-R16 item 2), within the existing drain-boundary family.

5. **Readers between turns** see the same set of waiting joins, through the same predicates:
- the purge applies the same per-join body in the same order: queue order, each bucket at its verdict, newest first;
- followedLane takes the max over the same joins. Order does not matter, and the early return only skips work once .userInitiated is reached;
- the recount sees the same registrations;
- laneEventsWaiting reads only removals and verdicts (EngineFailures.swift:845-863);
- followBarrier is unchanged, because a bucket's verdict waits (K1).

6. **Both orders.** followVisitedFirst is the reference. In T1 its follow ends before the verdict arrives, so the verdict is given at once and no join waits behind it. sweepFollowsFirst replays today's sequence by points 2-5, so the visit-first answers that today's tests and mappedBack assert (EngineFollowBarrierHopTests.swift:170-191) still hold.

7. **RR-21.** The owed `.reroutes` stays at the verdict's position, ahead of the bucket. Today's rerouteMovedBefore ran inside the verdict's replay (:615-619, :352-356), before the joins behind it. The two (token, id) sets are disjoint under the one-place-per-interest clauses, and both join the verdict's content.

8. **Order is kept** (newest first). RR-15 (s3f.md:3871) stays true, and nothing is recorded for order under S3-R16 item 2.

## c2_argument

**Today.** Each deferral scans back to the verdict and shifts the queue twice (EventAfterFollow is 168 B). A follow turn of 512 deferrals costs about 4.98 ms plus 7.3 ns × E per deferral: 6.90 ms at E = 513, 20.85 ms at 4,097 and 39.55 ms at 9,217 (correct/logs/rel-deferq.log:7-10). The reqs probe measured 35.78 ms best (reqs/logs/probe2.log:11).

**After the change.**

(a) **Follow turns.** A deferral is two hashed writes, amortised O(1): the existing registration and one append. The queue is untouched. A turn of 512 deferrals keeps only the fit's base, about 2-5 ms. The control, where the same joins land in place, ran 2.95-5.95 ms in its middle turns (rel-deferq.log:16-18), and an append is cheaper than an in-place join.

(b) **The put-back.** It happens once per verdict that holds joins, in the drain turn that replays that verdict, and that turn ends there. It costs O(B) to build B events and stamps, plus one shift of the remaining queue — the same shift every break already makes (:212-214). At B = 10,000 that is about 10,000 element copies and up to about 1.8 MB moved, estimated at 0.5-1.5 ms. There is at most one put-back per turn.

(c) **Drain turns after it.** The joins replay as ordinary `.join` events under the existing bound of 512 events a turn (:173, :193-198). Each costs what it costs today: 2.91-3.91 ms per 512 in the probes' drains (rel-deferq.log:7-9). They spend no drainIDsLeft.

(d) **The worst turn.** In both probe shapes the verdict replays in the follow's last turn, which also runs the drain's first batch (:158). Today that turn is 24.89 ms: about 19.6 ms of O(E) deferrals, 2.6 ms of moves and about 3 ms for a 512-event batch. With the change it is the moves, the verdict and the put-back, estimated at 3.5-4.5 ms. The control's 8.70 ms best last turn is an upper reference. This is UNCONFIRMED and pinned by deferBehindVerdictTurns.

(e) **Readers.**
- followedLane walks the buckets only when the queue gave no user lane. That is O(B), and no more than today's walk over the same joins in the queue.
- withdrawPurgedJoins is O(E + B), as today with the joins in the queue.
- followBarrierViolations is O(E + B) and runs in tests only.

(f) **Groupings.**
- One group token, or a user waiter per id, changes only each replay's cost, and the 512 bound caps that.
- Ids split across several waiting verdicts give one put-back per verdict, each in its own turn.
- The number of waiting verdicts is bounded by the attempts in flight when the barrier rose, because no job starts behind it.

**Amortised per join:** O(1) at the deferral, an O(1) share of one put-back, and one replay.

## new_branches

- deferBehindVerdict's append (replacing the scan and inserts).
Test T1, `barrierPutsTheJoinsDeferredBehindAVerdictBackAfterIt(_ visit: LaneDropVisit, _ verdict: {notFound, timeout}, _ members: {group, users})`.
Setup:
- O (zz-o, 16 B, user waiter W_o) downloads, scripted [.hold, .fail(404 or .transient(.timedOut)), .stage(oBytes)].
- H (zz-h0…zz-h9, sharing 16 B) is wanted by one prefetch group G or by a user waiter each, and downloads, held.
- v3 changes only the fillers. O's attempt ends. v4 maps every zz-h id to O's content.
Sweep-first, after each held turn:
- invariantViolations() == [];
- eventsAfterFollow is exactly [O's verdict];
- the bucket under VerdictKey(O, e) grows by at most 4, ending at zz-h0…zz-h9 in arrival order.
Mutant (drop the append): the recount fires after the first turn that defers, and the members are never answered. Killed 2/2. mappedBack's one reaching case also kills it.
- The drain's put-back.
T1, after the follow's last turn (which replays O's verdict):
- the table is empty;
- eventsAfterFollow is exactly the joins for zz-h9…zz-h0;
- no job holds a zz-h id;
- W_o is answered notFound (404), or O is backing off (timeout);
- the next held drain turn replays all 10 and empties the queue.
Both orders, at the end:
- every zz-h member is served 16 B, by a fresh job of O's content (404) or by O's retry (timeout);
- the 404 reports zz-o failed and no zz-h id (reportsFailed, EngineFollowBarrierHopTests.swift:155-162).
Mutants, each killed 2/2 by T1:
- (a) drop the removeValue and put-back: K1 fires after that turn and the members hang;
- (b) drop `!behind.isEmpty ||`: the removed bucket is discarded, the recount fires and the members hang;
- (c) put back in arrival order: the order assertion fails;
- (d) put back before the replay: the 404 answers the zz-h ids.
- Given or skipped (a property of the put-back, not a separate branch).
Test T1-skip, in both orders: the verdict is a 404, and O is wanted only by a one-member prefetch group G_o instead of W_o.
Sweep-first, after the first turn that defers a join: `engine.releaseGroup(G_o)` (SyncEngine.swift:104) applies at arrival and retires O. #require: verdictsAfterFollow[O] == nil, O's event still waits, the bucket is non-empty.
The drain then skips O's verdict (:608-610) and puts the bucket back. Every zz-h member is served by the fresh job of O's content that later visits created at once.
The test asserts H's answers and invariants only.
Mutant (put-back gated on the verdict being given): K1 fires and the bucket's joins never replay. Killed 2/2.
- verdictKey's arms.
Forced check F-SPACE, taken between follow turns of T1 (sweep-first) with a bucket under key k:
`engine.violations { s in s.eventsAfterFollow.append(.spaceFailure(k.transfer, epoch: k.epoch &+ 1_000, required: 1)); s.eventStamps.append(s.eventStamps[0]); s.joinsBehindVerdicts[VerdictKey(transfer: k.transfer, epoch: k.epoch &+ 1_000)] = s.joinsBehindVerdicts.removeValue(forKey: k) }` must equal [].
Mutants:
- nil for `.spaceFailure` gives K1's message: killed;
- nil for `.attemptFailed` breaks T1's put-back: killed.
- followedLane's bucket walk.
Test T-FL, in both orders, modelled on barrierDecidesA429OnTheLaneAJoinALaterApplyMovedGives (EngineFollowBarrierLaneTests.swift:212-275), with shortInteractiveRetry:
- C (zz-b, 1 MB) downloads for a prefetch waiter P, scripted to a 429 with Retry-After 60 s;
- O (zz-o, user waiter) times out, so its verdict waits;
- Y holds zz-u for user waiter U.
Steps:
- v3 changes the fillers;
- v4 maps zz-u to O's content, and held turns run until Y's visit deferred U's join behind O's verdict;
- v5 maps zz-u to C's content, with the follow still owed;
- release C's 429.
Visit-first: C is user work at the 429, so the throttle is exhausted, nothing is throttled, and P and U are answered serverUnavailable.
Mutant (drop the walk): C stays prefetch, the origin is throttled 60 s and P is served. Killed 2/2.
- The walk's `where reaches(...)` filter.
Test T-FL': T-FL without v5. U's bucket join stays at O's content.
Visit-first: C stays prefetch, the origin is throttled 60 s, C's retry serves P, and O's retry serves U.
Mutant (count every bucket join): C becomes user work, the throttle is exhausted and P is answered serverUnavailable. Killed 2/2.
- withdrawPurgedJoins' bucket arm.
Test T-PG, in both orders, with a timeout verdict and group members. After the first turn that defers 4 joins (sweep-first), or after the follow and drain (visit-first), run `await engine.purge(.evictable)` (or a scope of the zz-h ids).
Sweep-first, right after the purge:
- joinsAfterFollow has no entry for G;
- groups[G].pending holds no zz-h id;
- every bucket entry is withdrawn;
- invariants are clean.
At the end, in both orders: no job holds a zz-h id, no zz-h id is present or announced available, and W_o is served by O's retry.
Mutant (drop the arm): the joins stay registered and G keeps waiting for them, so O's retry stores them. Killed 2/2. T-PG also kills dropping the recount's `where !waiting.join.withdrawn`, because its post-purge invariant check fails.
- The recount's bucket loop.
Mutant (drop it): every sweep-first T1 turn with a non-empty bucket fails invariantViolations() with the recount message. Killed 2/2.
- K1.
Forced check F-K1: `engine.violations { s in let entries = s.joinsBehindVerdicts.removeValue(forKey: k); s.joinsBehindVerdicts[VerdictKey(transfer: k.transfer, epoch: k.epoch &+ 1_000)] = entries }` must equal exactly [K1's message].
Mutant (drop K1): returns []. Killed.
- K3.
Forced check F-K3: `engine.violations { s in if let first = s.joinsBehindVerdicts[k]?.first { s.joinsBehindVerdicts[k]?[0] = JoinBehindVerdict(join: first.join, stamp: WorldStamp(at: first.stamp.at, view: s.worldHistory.count)) } }` must equal exactly [K3's message].
Mutant (drop K3): returns []. Killed.
- drainEverything's clear.
Test T-SD, in both orders, with a timeout verdict and user members: `await engine.shutdown()` after the first turn that defers. Afterwards:
- joinsBehindVerdicts, eventsAfterFollow and joinsAfterFollow are empty;
- invariantViolations() == [];
- W_o and every W_h are answered .shutDown.
Mutant (drop the clear): K1 and the recount fire. Killed 2/2.
- K4 (only with mechanism 11).
Forced check F-K4, after T-SD's shutdown, using a stamp and a view captured before it: `engine.violations { s in s.eventsAfterFollow = [.throttleAnswers]; s.eventStamps = [stamp]; s.worldHistory = [view] }` must equal exactly [K4's message].
Mutant (drop K4): returns []. Killed.
- Not a new branch: followedLane's `break` becomes `return .userInitiated` (:833). Its drop-mutant changes cost only (S3-R19 item 2), as the existing `break`'s did.

## interactions

- RR-21, design-minimal steps 10-12.
Head order after a verdict's turn: the owed `.reroutes` (with the verdict's stamp), then the bucket newest first (with each join's own stamp), then the batch's rest. Either condition ends the batch, and verdictKey is nil for `.reroutes`.
Why `.reroutes` first:
- today's rerouteMovedBefore ran inside the verdict's replay (:615-619, :352-356), before the joins right behind the verdict;
- in visit-first time, the moved-before ids were re-routed at applies before the verdict arrived (AttemptEnd.movedBefore, :1563-1567), while the deferred joins stand for visits at applies after the deferral (:955-963; EngineJobs.swift:118-120);
- the (token, id) sets are disjoint, and both join the verdict's content.
This is today's order, so nothing new is recorded.
Pin: if RR-21 lands first, T1 gains a variant where O holds more moved-before ids than drainIDsLeft (4). The head is then [.reroutes, zz-h9…zz-h0], and the joins wait until the `.reroutes` finishes.
- RR-21, steps 13-15.
- Its new withdrawPurgedJoins guard (eventsAfterFollow.isEmpty) is compatible, by K1.
- Its `.reroutes` arm sits beside the bucket arm in the same loop.
- Its followedLane `.reroutes` arm goes in the queue loop.
- Its one-place clause holds: bucket joins are registered in joinsAfterFollow and are never owed items.
- Landing order. Both items touch drainEventsAfterFollow's loop (:204-216), followedLane (:821-836), withdrawPurgedJoins (:1049-1073) and followBarrierViolations (:2003-2069). Land them one after the other in this worktree, rebasing the second onto the first. Neither changes the other's answers.
- addInterest's behind-verdict path (EngineJobs.swift:117-123) is unchanged: still `listed: true`, still skipped while bringingInbound. Owed moves (continueInbound :1208-1213) and the drain's after-verdict visits join at once.
- removeJob (EngineJobs.swift:434) and replayVerdict's guards (:608-614): the put-back is keyed by the event, so it is independent of both.
- S3-R25 item 1's drainIDsLeft: bucket joins spend none. An after-verdict rest (followMoving) still ends the batch, with the bucket at the head after it, as today's queue held them.
- The follow's last turn runs the drain's first batch (:158). In both probe shapes, the put-back lands in that turn.
- Unchanged readers:
- laneEventsWaiting (EngineFailures.swift:845-863);
- followBarrier (:97-99);
- the drain's emptiness guard (:189);
- the `.readmit` and `.unblock` checks (EngineCommands.swift:1949, :2126);
- FollowBarrier.joinWaits (EngineFollowBarrierTests.swift:84-86, which reads joinsAfterFollow).
The BenchSync helpers that count eventsAfterFollow (:2915-2940) have no bucket in their shapes. The scratch probes' queue-join counters would read 0 during the follow, so the new bench reads joinsBehindVerdicts instead.
- scheduleDrainFollowUp's unspawnable branch (:390-398): see mechanism 11.
- docs/adr-drafts/s3f.md:4850: the inventory row is filled from deferBehindVerdictTurns.

## risks

- The C2 estimate for the verdict's turn. In the probe shapes this is the follow's last turn, estimated at 3.5-4.5 ms, with 8.70 ms as an upper reference. It depends on the put-back's O(B) copies and is not measured.
Fallbacks if deferBehindVerdictTurns misses:
- insert the rest and then the bucket separately, so each join is copied once;
- when the drain runs inside the follow's last turn (ids != nil), end its batch before a verdict that holds joins. That is one timing-only disjunct;
- add a `.joinsBehind(VerdictKey)` placeholder that puts back at most 512 joins a turn. That is a new event case every reader must handle.
- There is a new drain-turn boundary after each verdict that holds joins. It is timing only, and adds at most one drain turn per such verdict. Waiting verdicts are bounded by the attempts in flight when the barrier rose (no start behind the barrier, EngineDispatch.swift:95-108, as cited by design-minimal).
- K1's 'exactly one' assumes one exit verdict per (transfer, epoch). Supporting code:
- lastEpoch is global, bumped at creation and at every start;
- recordDeferredVerdict and the deferral happen in one turn (EngineFollow.swift:463-465, EngineFailures.swift:571-572).
If some path deferred two exits for one attempt, today's lastIndex would place the joins after the later event, while the put-back places them after the first. K1 would show this in every test that checks invariants.
- followedLane's bucket walk has no early exit. It runs only when the queue gave no user lane, so its cost is at most today's worst case over the same joins.
- Pre-existing, unchanged: dropGroupMember copies the group per call (EngineJobs.swift:594-598). The bucket arm calls it exactly as the queue walk did.
- Pre-existing, unchanged: one id with thousands of interests still moves whole in one turn, per continueMove's rule (EngineMoves.swift:179-188). The deferral is now O(1) per interest there too, but the turn cost comes from that rule, which is outside this item.
- There will be merge friction with RR-21, since both change the same four functions.
- Mechanism 11 relies on the unreachability argument. If the argument is wrong, the not-running clause K4 would fire in tests rather than fail silently.

## unconfirmed

- None of the per-turn figures after the change could be measured, because building and running were not permitted:
- follow turns about 2-5 ms;
- the put-back about 0.5-1.5 ms at 10,000;
- the verdict's turn about 3.5-4.5 ms;
- drain turns about 3-4 ms in the group shape, and about 4-6 ms in the users shape.
- Which mappedBack case reaches the deferral today. covdiff.log:25-26 shows EngineJobs.swift:121-122 executed once in the whole suite. It is also unknown whether the `.spaceAtCap` case reaches it, and so whether any test covers a `.spaceFailure` bucket end to end; F-SPACE covers only the classifier.
- T1's exact per-turn bucket counts. They are at most 4 a turn, but the fillers' passes delay H's visit.
- Whether T-FL's three applies fit under one owed follow given how the fillers are placed.
- That releaseGroup retires O behind the barrier in T1-skip (the retire path of dropInterest). The test #requires it. Separately, G_o's own events differ from visit-first for a reason outside this item, so T1-skip does not assert them.
- The exact violation message strings.
- That `joinsBehindVerdicts[key]?[slot].join = join` mutates in place, through Dictionary's _modify accessor. This affects cost only.
- That MoveProgress pops zz-h0…zz-h9 in that order, by MoveItem's (asset, token) order (EngineMoves.swift:5-13).
- That K4 holds in every existing test.
- Whether S3-R22's reference set includes many tokens per id.

## events_between_turns

- Between follow turns, while the bucket is in the table.
- A purge withdraws the bucket's purged non-user joins at their verdict's position, newest first, and they replay as no-ops (T-PG).
- A 429 on an in-flight job: followedLane counts the bucket joins that reach that job (T-FL, T-FL').
- A group release, a claim end or a run end applies at arrival. Bucket joins whose owner has left fail stillWants (:701-703); the acceptances iterate live owners only.
- A waiter withdrawal, a new request, a conditions element, an alarm or another exit is deferred at the tail (:233-236), so it replays after the verdict and its bucket, as today.
- Another apply: its visits append to the same bucket while the verdict waits. They come out newest first at the put-back, as today's inserts did.
- Removal of the verdict's job: the verdict is skipped and its bucket is still put back (T1-skip).
- Shutdown clears everything (T-SD).
- Between drain turns, after the put-back: the joins are ordinary `.join` events at the queue head. This is the state today's drain leaves after a break right after a verdict (:210-215).

## rejected_alternatives

- Appending the join at the tail with deferToFollow. It would replay after every event that arrived after the verdict, which risks answers (S3-R20 item 3).
- An index, linked list or deque inside eventsAfterFollow. Either the inserts stay as memmoves, or every reader and the stamps' lockstep change.
- Splicing the bucket into the local batch, with a 512-replay counter. This keeps today's turn boundaries, but adds up to 511 replays to the follow's last turn and adds a counter disjunct whose mutant needs a bucket of at least 512.
- Merging each follow turn's deferred joins into the queue at the end of that turn. That is O(E) per turn, not O(1) amortised.
- A placeholder event that replays the bucket in pieces. This is held back as the fallback only.
- Creating the bucket at defersFailure and spaceFailed. That adds two write sites and an empty-bucket state.
- Keying by TransferID alone. (transfer, epoch) is the event's own identity.
- Walking the buckets in Dictionary order during the purge. The order would be non-deterministic per process.
- Putting the bucket back in arrival order. That changes today's order and needs an S3-R16 item 2 record and an RR-15 rewrite, for no answer gain.
- An early exit in followedLane's bucket walk. It changes cost only, so its mutant would be Equivalent.
- Keeping the unspawnable branch with an added clear. That statement has 0 hits, so its mutant cannot be killed.

## size_estimate

- Sources: about +80/−35 lines across 5 files (EngineFollow, EngineState, EngineFailures, EngineCommands, EngineShutdown).
- Tests: about 500-700 lines in one new file. T-FL's setup is the largest part.
- BenchSync: about +170 lines.
- Docs: one inventory row and one decision entry.
- Effort: one fixer cycle.
