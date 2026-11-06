# integrate:c21

Read-only analysis for ruling S3-R26 (workflow wf_bc7908d4-1ad, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## A. defer-bucket: joins behind a waiting verdict are stored in O(1) and placed at the drain's batch formation (reqs #3, correct #2). The item also removes scheduleDrainFollowUp's branch for a refused spawn, which cannot run (reqs #5, correct #7).

### spec

- A1 Problem. deferBehindVerdict (EngineFollow.swift:964-978) finds the verdict with lastIndex (:966-973), then inserts each join right behind it in both eventsAfterFollow and eventStamps (:976-977). Every earlier join behind the same verdict sits after it, so the k-th join scans and shifts k elements. A follow therefore costs O(N^2). Measured: reqs #3 35.78-37.91 ms; correct #2 39.55 ms against an 8.70 ms control.
- A2 Types. After JoinAfterFollow (EngineFollow.swift:1573-1590), add two types, each with a /// doc that says why it exists:
- `struct VerdictKey: Hashable, Sendable { let transfer: TransferID; let epoch: UInt64 }`. It names one attempt's exit verdict: lastEpoch is global and is bumped at every job creation and every start (EngineJobs.swift:137, EngineDispatch.swift:697).
- `struct JoinBehindVerdict: Sendable { var join: JoinAfterFollow; let stamp: WorldStamp }`. `join` is a var so that a purge can withdraw it in place. WorldStamp and JoinAfterFollow are already Sendable (:1531, :1573).
- A3 Classifier. Add `var verdictKey: VerdictKey?` to EventAfterFollow, after endsDrainBatch (EngineFollow.swift:1436-1443). Write it as an exhaustive switch with no default:
- .spaceFailure(t, epoch, _) and .attemptFailed(t, epoch, _) return VerdictKey(t, epoch).
- .join, .removal, .conditions, .readmit, .unblock, .retryDue, .throttleAnswers and .spaceSweep return nil, and so does RR-21's .reroutes.
- A4 State. Add `var joinsBehindVerdicts: [VerdictKey: [JoinBehindVerdict]] = [:]` to EngineState after joinsAfterFollow (EngineState.swift:156). Its doc says:
- these are the joins a follow's visit waits behind a waiting exit verdict, oldest first, each with its decision instant;
- the drain places them right behind their verdict, newest first, when it forms that verdict's batch;
- they are registered in joinsAfterFollow like any waiting join.
Amend joinsAfterFollow's doc (:153-155): its joins wait in eventsAfterFollow or behind a verdict.
- A5 deferBehindVerdict. Rewrite EngineFollow.swift:964-978 as two O(1) writes:
- keep the registration at :975;
- append `JoinBehindVerdict(join: join, stamp: self.worldStamp())` to `self.state.joinsBehindVerdicts[VerdictKey(transfer: target.transfer, epoch: target.epoch), default: []]`.
Delete :965-974 and :976-977. worldStamp() returns the visit's reading (:251-253), the same stamp the old insert used.
Rewrite the doc (:957-963). It drops the tail fallback (`?? events.count - 1`, :974), because the caller's guard (EngineJobs.swift:117: inFollowVisit, !bringingInbound, attemptEnd.deferredAfter != nil) holds only while the verdict event waits in the queue:
- deferredAfter is set together with the deferral (EngineFollow.swift:508-526, EngineFailures.swift:571-572) and cleared by endDeferral when the verdict replays (EngineFollow.swift:537-541).
- The drain's own visits run with inFollowVisit false (:586-593) or with bringingInbound true (:824-825, :1208-1209), so no call happens while a batch is out of the queue.
K1 checks this.
- A6 Batch formation. Rewrite :192-201 as one walk over the queue, in step with eventStamps (as the zip at :199 pairs them):
- Append each event, with its stamp, to `batch`.
- When the event's verdictKey has a bucket, `removeValue` the bucket and append its joins newest first (`reversed()`), each as `.join(entry.join)` with entry.stamp. A join goes to `batch` while batch.count < eventsAfterFollowPerTurn (:173), and to `overflow` after that.
- Stop when batch.count reaches eventsAfterFollowPerTurn, or after an event that endsDrainBatch (inclusive, as at :195-197). No verdict ends a batch (:1440).
- Then `eventsAfterFollow.replaceSubrange(0..<consumed, with: overflow events)`, and the same on eventStamps with the overflow stamps. This is one O(E) shift, the same as removeFirst at :200-201 today.
The replay loop (:204-216) and the tail (:218-229) stay unchanged. The result is exactly today's batches, batch boundaries, order and barrier state inside every replay. Add one sentence to the doc at :175-187.
- A6r Rejected:
- The design's put-back of a verdict's joins after the verdict replays, together with its `!behind.isEmpty` disjunct (critique R1). It changes followBarrier inside V's replay (EngineFollow.swift:97-99), so checkRunSettled's barrier guard (EngineRuns.swift:576) and the orphan pass (:650-660) can run differently, and it adds a turn boundary.
- Critique A2's followBarrier disjunct. It is moot under A6, and it would change the barrier where the whole queue fits one batch.
- A7 followedLane (EngineFailures.swift:821-836):
- Hoist the guards at :823-830 into a local `func reaches(_ join: JoinAfterFollow) -> Bool`.
- Change the `break` at :833 to `return .userInitiated`. This is the same result, because :837 returns `lane ?? job.lane` with lane == .userInitiated.
- After the queue loop, walk `self.state.joinsBehindVerdicts.values` and call raise(join.lane) for every non-withdrawn join that reaches. It needs no early exit: the maximum does not depend on order. This is the only Dictionary-order walk the item allows.
Amend the doc (:704, :709-720).
- A8 withdrawPurgedJoins (EngineCommands.swift:1049-1073):
- Move today's per-join body (:1054-1070: the filter, the joinsAfterFollow removal, the dropGroupMember or heal arm, and `withdrawn = true`) into a private helper `withdrawPurgedJoin(_ join: inout JoinAfterFollow, _ isPurged: (AssetID) -> Bool)`.
- The .join arm calls the helper and writes the event back (:1071).
- At each event whose verdictKey has a bucket, walk the bucket newest first, `for slot in (0..<count).reversed()`, calling the helper in place on `self.state.joinsBehindVerdicts[key]?[slot].join`. This happens at the verdict's queue position, which is today's queue order, so dropGroupMember's resumes keep their order.
The guard at :1050 stays valid, because bucket joins are registered. Withdrawn bucket joins replay as no-ops (EngineFollow.swift:692-709).
- A9 followBarrierViolations, loop at EngineCommands.swift:2016-2030:
- Count verdict events per verdictKey.
- At each verdict event, register its bucket's non-withdrawn joins into `joins`, newest first (critique A4: the recount walks them at their position, where the queue held them).
Add K1 and K3 after the stamps clause (:2034-2036). Amend the doc (:1997-2002).
- A10 Shutdown. In drainEverything, add `self.state.joinsBehindVerdicts = [:]` after EngineShutdown.swift:124.
- A11 Remove scheduleDrainFollowUp's branch for a refused spawn (EngineFollow.swift:384-399). Drop `let spawned =` and the `if spawned == nil` block; spawn is @discardableResult (EngineLifecycle.swift:51). Mirror the doc of scheduleFollowFollowUp (:1328-1334).
Each of the branch's seven resets is either inert or redone elsewhere:
- drainFollowUpScheduled is cleared by drainFollowUp (:410), whose guard (:411) stops an engine that is not running. Its readers are :380, :410 and the running-only clause at EngineCommands.swift:2006.
- eventsAfterFollow, eventStamps, worldHistory, followStamps, verdictsAfterFollow and joinsAfterFollow are cleared by drainEverything (EngineShutdown.swift:118-124).
The branch cannot run:
- Shutdown's first turn calls drainEverything synchronously after setting shuttingDown (EngineLifecycle.swift:490-498).
- spawn refuses only in shuttingDown, shutDown and degraded (EngineLifecycle.swift:53-55).
- The engine degrades only while starting (EngineLifecycle.swift:228, :260).
- Every drain runs in a running turn (EngineFollow.swift:158; :414 after :411; :1316).
Add K4 next to the followOwed clause (EngineCommands.swift:2009-2013).
- A12 Bench. Add the BenchSync case `deferBehindVerdictTurns` (see pins). Its count of drained events must include bucket joins: BenchSync.releaseHeldFollow counts eventsAfterFollow only (Tests/ZTronAssetKitBenchmarks/BenchSync.swift:2916-2931).
- A13 Draft. Fill row docs/adr-drafts/s3f.md:4850 with the measured figures. Record the decision and why materialization was chosen over put-back. RR-15's text stays true.

### invariants

- K1 (followBarrierViolations): every key of joinsBehindVerdicts names exactly one waiting event in eventsAfterFollow with that verdictKey, and no bucket is empty. Example message: '<n> verdicts hold joins behind them without exactly one waiting event'. K1 implies that the barrier is up (EngineFollow.swift:97-99), the world history is kept (endWorldHistory, :335-341) and a drain is owed (EngineCommands.swift:2006-2008).
- K2 extends the existing recount (EngineCommands.swift:2031-2033). joinsAfterFollow equals the recount of the queue's non-withdrawn .join events, with each bucket's non-withdrawn joins counted at its verdict's position, newest first.
- K3: every bucket entry has stamp.view < worldHistory.count, as the stamps clause (EngineCommands.swift:2034-2036) checks for the queue.
- K4: when !isRunning and eventsAfterFollow is not empty, report '<n> events wait for a follow while the engine is <lifecycle>'. Together with K1 and the existing joins (:2031-2033), history (:2040-2042) and verdicts (:2043-2045) clauses, it covers every reset the removed branch made.
- Unchanged clauses:
- The waiter (EngineCommands.swift:1707-1712), group (:1777-1783) and run (:1812-1817) clauses still accept a bucket join through joinsAfterFollow.
- The stamps clause still holds, because A6 moves events and stamps in step.

### tests_and_mutants

- Coverage of the two orders. Every test runs in LaneDropVisit.allCases and asserts visit-first's answers. The bucket branches are reached in sweep-first only: followVisitedFirst releases the follow before any verdict arrives (EngineFollowBarrierTests.swift:97-108). See open question 1.
- T1, end-to-end, parameterized by {404, timeout} x {prefetch group, user waiters}.
Setup:
- O is zz-o, with user waiter W_o, scripted [.hold, .fail, .stage].
- H holds ids zz-h0.. that share 16 B.
- v3 changes only the fillers, so O's verdict waits.
- v4 maps every zz-h id to O's content.
Assert on every held follow turn in sweep-first:
- `eventsAfterFollow == [V]`;
- the bucket grows by at most followIDsPerTurn = 4, in arrival order;
- violations are empty.
Assert at the end: the members are served, and a 404 reports only zz-o as failed (as EngineFollowBarrierHopTests.swift:155-162).
Mutants it kills:
- dropping the append;
- reverting to the queue insert (the per-turn assertion fails);
- dropping the materialization (K1 fires and the members hang; use a bounded condition, not an unbounded await).
- T1-place, white-box, sweep-first.
Setup:
- Size zz-h so that the follow's last turn spends all 4 ids, which gives drainIDsLeft 0 for the first batch (:158, :203).
- A request for zz-x arrives between follow turns and waits as a tail .join (EngineJobs.swift:110-116).
After the first drain turn, `#require` that eventsAfterFollow == [join zz-h(n-1) ... join zz-h0, join zz-x].
Mutants it kills: materializing in arrival order; materializing at the tail.
- T1-skip, 404.
Setup:
- O is wanted only by the one-member prefetch group G_o.
- `SyncEngine.releaseGroup(G_o)` (SyncEngine.swift:104) retires O.
`#require`: verdictsAfterFollow[O] == nil, O's event still waits, and the bucket is not empty.
The drain skips the verdict (EngineFollow.swift:608-610) but must still replay the bucket. Mutant it kills: materializing only for a verdict that is given.
- T1-space: use the ENOSPC shape (EngineFollowBarrierPublicationTests.swift:312-358) if it can be built. Otherwise F-SPACE: a unit check that verdictKey of `.spaceFailure(t, epoch: e, required: r)` is VerdictKey(t, e), and that every other case gives nil. Mutant it kills: dropping the .spaceFailure arm. T1 kills the .attemptFailed arm's mutant.
- T-PURGE. A purge of the zz-h ids of prefetch group G while their joins wait behind V. In sweep-first the joins are in the bucket; in visit-first they joined at once.
Assert:
- joinsAfterFollow has no entry for G;
- G.pending holds no zz-h id;
- in sweep-first, every bucket entry is withdrawn;
- at the end, no job holds a zz-h id, none is stored, and W_o is served by O's retry.
Mutants it kills: dropping the bucket arm of A8 (the group clause or K2 fires); dropping the recount's !withdrawn filter for bucket joins (K2 fires).
- T-FL and T-FL', modelled on EngineFollowBarrierLaneTests.swift:212-275 with shortInteractiveRetry. O gets a 429 while a user-lane join waits in O's bucket.
- T-FL: followedLane must read .userInitiated, so the 429 is decided on the user policy.
- T-FL': the bucket join is aimed at another content, so it must not count.
Mutants they kill: dropping the bucket walk (T-FL); counting every bucket join without `reaches` (T-FL').
- Recount walk: dropping it makes K2 fire on every T1 turn that has a bucket.
- Forced oracle checks, each expecting exactly one message:
- F-K1: move a bucket to a key that has no event; expect exactly [K1].
- F-K3: set one entry's stamp.view = worldHistory.count; expect exactly [K3].
- F-K4: after shutdown, set eventsAfterFollow = [.throttleAnswers], eventStamps = [stamp] and worldHistory = [view]; expect exactly [K4].
- T-SD: shut down after the first deferral. Assert: every follow table is empty, joinsBehindVerdicts included; violations are empty; W_o and the members are answered .shutDown. Mutant it kills: dropping A10's clear (K1 and K2 fire).
- Equivalent (S3-R19 item 2): the change of `break` to `return .userInitiated` at EngineFailures.swift:833.
- Close-out (S3-R25 item 10): run covdiff on the changed lines and record every drop-mutant in the draft's mutation table (docs/adr-drafts/s3f.md:4777-4824).

### pins

- Deterministic pin (S3-R23 item 3): T1's per-turn assertion. eventsAfterFollow stays [V] through the follow, and the bucket grows by at most 4 per turn. Reverting to the queue insert must fail it 2 out of 2 times in both orders.
- BenchSync pin `deferBehindVerdictTurns`, in the R-SYN-11 suite.
Shapes: {notFoundGroup, timeoutGroup, notFoundUsers, timeoutUsers} at 10,000 ids, after a warm-up at 1,000. Build them like PROBE-C20R-DEFER-BEHIND-C2 (/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/reqs/VerifyC20ReqsC2Probes.swift:62-115).
The setup expects:
- the verdict waited;
- no join entered eventsAfterFollow during the follow (joinsBehindVerdicts holds them);
- after the follow's last turn the table is empty and about 9,489 joins wait (10,000 minus the 511 that fit the first batch behind V);
- O's content holds 10,000 ids for a 404, or 10,001 for a timeout;
- violations are empty.
Gate: the best of 3 of the longest held turn, and of the heartbeat, is at most c2Budget (10 ms), at a 1-minute load of at most 10.

### must_not

- Do not put a verdict's joins back after its replay. Do not add a drain-turn boundary. Do not add a disjunct to followBarrier.
- Do not append joins behind a verdict to the tail through deferToFollow. Do not key buckets by TransferID alone.
- Do not iterate a Dictionary where order matters: the purge (A8) and the recount (A9) walk buckets at their verdict's queue position. Only followedLane's maximum (A7) may use Dictionary order.
- Do not make materialization depend on replayVerdict's guards or on verdictsAfterFollow, since T1-skip needs it unconditionally. Do not change the newest-first order.
- Do not keep the branch for a refused spawn, even with an added clear.
- Do not add an await or an unsafe construct. Do not change a public or package signature. Do not edit DECISIONS.md, SPEC, Scripts or Package.swift (S3-R6).

### residual_risks

- C2 of the follow turns in the users shape. The per-id bookkeeping of the moved ids costs about what userSharedApplyTurns measures (7.18-8.18 ms), so the bucket fixes the O(N^2) term but leaves little margin. UNCONFIRMED until deferBehindVerdictTurns runs.
- Materialization costs one O(E) shift plus O(B) copies per batch. UNCONFIRMED.
- K1 assumes one exit verdict per (transfer, epoch), that is, an attempt ends once. K1 reports any violation.
- Pre-existing candidates, recorded and unchanged by this item:
- orphaned run claims when a verdict replays with the barrier down, in a batch that holds the whole queue (the orphan pass at EngineRuns.swift:650-660; critic); probe before fixing;
- recordRunOutcome's `outstanding[T] = nil` (EngineRuns.swift:519) wipes a claim that a visit re-routed onto T;
- followAfterVerdict joins at once onto a job whose own verdict waits later in the queue;
- the newest-first order of joins behind one verdict (accepted).

## B. move-index: a per-job index from id to holders, so a move costs O(moved + holders) with no Job copy alive across the table's mutations (correct #1, reqs #6). It also covers reqs #9, the Q1 half and variant Y's T' half (EngineMoves.swift:195), and the bounded path's orphan.

### spec

- B1 Problem.
- move (EngineFollow.swift:931-955) and startMove (EngineMoves.swift:140-166) find a moved id's interests by walking every interest of the holder: :945-946 sort the walk, and :158-162 build the items from it.
- Both run with a Job copy alive across the table's mutations: follow's copy (:903), startMove's parameter, and continueInbound's holder (:1220). So each move pays O(interests) plus copies of the ids and interests.
Measured: correct #1 MANY-MOVES k=1 8.22 ms, k=16 79.55 ms, k=64 304.79 ms; reqs #6 partial move 8.44-9.50 ms.
- B2 IDTokens. In EngineState.swift, before Job (:672), add `struct IDTokens: Sendable { private(set) var first: InterestToken; private(set) var others: Set<InterestToken> = [] }`. Members:
- `init(_ token:)`.
- `mutating func add(_ token:)`: inserts into `others` only when token != first.
- `mutating func remove(_ token:) -> Bool`: returns whether a holder is left. If token != first, it removes token from others and returns true. If token == first, it promotes `others.popFirst()` into first and returns true, or returns false when first was the only holder.
- `var tokens: Set<InterestToken>`: others plus first, for the oracle.
- `func forEach(_:)`: first, then others.
The doc says why: the common id, held by one interest, costs no Set. Give it no custom `==`; the design's version was asymmetric (critique A4/R4).
- B3 Job (EngineState.swift:673-821).
- Add `private(set) var tokensByID: [AssetID: IDTokens] = [:]` after interestCounts (:692). Its doc: every mutator keeps it in step with interests, so a move reads a moved id's holders in O(holders); invariantViolations recounts it.
- Add private helpers: `index(_ asset:, _ token:)` is `self.tokensByID[asset, default: IDTokens(token)].add(token)`; `release(_ asset:, _ token:)` is `if self.tokensByID[asset]?.remove(token) == false { self.tokensByID[asset] = nil }`, in place.
- Amend the interests doc (:687-688) to name the index.
- B4 Mutators (EngineState.swift:774-820). All work in place.
- setInterest (:774-787): keep its count arms. Before `self.interests[token] = interest`, release the old interest's ids that the new one lacks, and index the new one's ids that the old one lacked.
- insertAsset (:790-792): index only when `insert(asset).inserted` is true. With no interest it does nothing.
- removeAsset (:796-798): release when it removed.
- subtractAssets (:801-803): remove and release id by id: `for asset in assets where self.interests[token]?.assets.remove(asset) != nil`.
- setAssets (:806-808) stays (critique A7's fallback; EngineInterestCountsTests.swift:81-83 is unchanged): release old minus new, index new minus old, then assign.
- removeAllInterests (:811-814): also empty tokensByID.
- keepInterests (:817-820): evaluate the predicate once per interest (`let dropped = self.interests.filter { !isIncluded($0.key, $0.value) }`), release and remove each dropped interest, then recount. When nothing is dropped it never touches the index, so jobAtVerdict's copy (EngineFailures.swift:872-879) does not copy tokensByID.
- B5 New reads on Job.
- `func holdings(of moved: Set<AssetID>) -> [(token: InterestToken, asset: AssetID, interest: JobInterest)]`. For each moved id with an entry, one pair per holder, with the interest's stub `JobInterest(lane:, kind:, assets: [])`, which is all that reroute reads (EngineMoves.swift:198-202). Sorted by (token, asset), which is today's order: tokens ascending, then each interest's moved ids ascending (EngineFollow.swift:945-946).
- `func moveItems(of moved: Set<AssetID>) -> (items: [MoveItem], unheld: [AssetID])`. One MoveItem per (id, holder), plus the moved ids that no interest holds.
- B6 move becomes `move(_ moved: Set<AssetID>, of transfer: TransferID, listing: ValidatedManifest? = nil) -> Bool` (EngineFollow.swift:931-955).
- The supersede branch (:933-943) reads the count, state and active attempt in its own scoped read. That copy lives only inside the branch, which ends in supersede.
- Otherwise: `let pairs = self.state.jobs[transfer]?.holdings(of: moved) ?? []`; then `assets.subtract(moved)` (:944); then, per pair, removeAsset, reroute with the stub, and removeInterest when that token's interest is now empty.
Checking after every pair gives today's result. An interest that holds only moved ids empties exactly at its last pair, and a token that holds no moved id is never empty (I3).
Read and mutate through `self.state.jobs[transfer]?.`, as continueMove does (EngineMoves.swift:195-216), and add no new existence guard.
- B7 startMove becomes `startMove(_ moved:, of transfer: TransferID, listing:, budget:)` (EngineMoves.swift:140-166).
- The fit path calls move(moved, of: transfer, listing:).
- The bounded path reads, in one scoped read that ends before the first mutation: whether the move supersedes (:145), the downloading state and the active attempt (:146-155), the lane (:163) and `moveItems(of: moved)`.
- At the first turn it subtracts the unheld ids from Job.assets. This aligns with the subtract in move (:944) and closes the orphan that the I5 clause (EngineCommands.swift:1752-1756) reports.
- Then it heapifies as today (EngineMoves.swift:30-39) and continues.
If the scoped read finds no job, return (false, 0, nil). No caller reaches that case: every caller holds an existing job (follow, EngineFollow.swift:903; continueInbound, :1220). Record it under S3-R19 item 3 as the default of the optional-chaining idiom.
- B8 continueMove (EngineMoves.swift:179-226).
- Keep: the guard (:180-183), the budget check at an id's first item (:189-194), the removal from Job.assets at the id's first item (:195), and the body (:197-216).
- Change: restructure the loop per id, so that after an id's last item it runs `if self.state.jobs[holder]?.tokensByID[asset] != nil { self.state.jobs[holder]?.assets.insert(asset) }`.
Why: an interest that joined the holder after the rest's items were fixed keeps its id in Job.assets. In Q1 this is the inbound move's join made at once (analyse-state-cost.md, steps 1-8). Visit-first's join re-inserted the id the same way (EngineJobs.swift:156).
`current` (:186) goes, and :218-224 stay unchanged. This step lands only together with T5 and I2.
- B9 follow (EngineFollow.swift:902-923).
- Move the job read, rerouteOnVisit (:906), the moved filter (:907) and the handling of passed ids (:908-914) into a private `visitMoves(of transfer:) -> (moved: Set<AssetID>, reroute: Set<AssetID>?)?`, whose Job copy dies on return.
- Keep `self.state.unfollowed.insert(transfer)` when passed is not empty, before startMove (critique A8). Its doc must not call the helper pure.
- Then call `startMove(moved, of: transfer, listing: nil, budget:)`.
:916-922 stay unchanged.
- B10 continueInbound (EngineFollow.swift:1220-1229).
- Replace `let holder = self.state.jobs[move.holder]` with the condition `self.state.jobs[move.holder] != nil`.
- Compute `let ids = self.state.jobs[move.holder]?.assets.intersection(move.ids) ?? []`.
- Call `startMove(ids, of: move.holder, ...)`.
No holder copy is then alive across continueMove or startMove. Today the copy at :1220 is alive across both, so every turn copies the holder's ids and interests.
- B11 answerPresentMembers (EnginePresence.swift:338-354; critique A10).
- First collect the rows in a scoped read that leaves no Job or JobInterest copy alive. Each row is (token, kind, lane, held = interest.assets ∩ present, whole = held.count == interest.assets.count), sorted by token as at :342.
- Then, per row: `whole ? setInterest(nil, for: token) : subtractAssets(held, for: token)`. The interest keeps the same lane, kind and counts as today's replacement at :348, and the index work is O(held) instead of O(interest).
- Then call answerPresent for each held id, ascending (:349-351).
:353 stays unchanged.
- B12 Not touched by this item:
- committed, which RR-21 step 6 rewrites;
- takeOffMovedBefore, which RR-21 step 9 rewrites to use moveItems or holdings and to take the TransferID. Its callers at EngineFollow.swift:352 and :615 pass Job copies today.
- B13 Clauses. I1, I2 and I3 go inside the per-job loop, after the counts clause (EngineCommands.swift:1727-1732).

### invariants

- I1: for every job, `job.tokensByID.mapValues { $0.tokens }` equals a recount built directly from `job.interests` as [AssetID: Set<InterestToken>]. The oracle must not use IDTokens code and must never build the recount through add. In addition, no entry's `others` contains its `first`.
- I2: every interest's ids are a subset of Job.assets (equivalently, tokensByID.keys ⊆ assets). It lands only together with B8: without B8, the Q1 state violates it in sweep-first.
- I3: no job holds an interest with no id. B6's per-pair removal relies on it. Today every writer removes an emptied interest: EngineMoves.swift:210-216; EngineFollow.swift:563-565 and :950-952; EngineJobs.swift:350; EnginePresence.swift:348; EngineDispatch.swift:1115-1116.
- The I5 clause (EngineCommands.swift:1752-1756) now holds on the bounded path too, because of B7's subtraction of unheld ids.
- Unchanged: the lane clause (:1718-1726). The oracle's exact `miscounted` expectation (EngineOutcomeTests.swift:457) stays a single message.

### tests_and_mutants

- EngineIDTokensTests (unit). Check the index against a recount after every step:
- insert;
- the same token again;
- a second token;
- remove a second holder;
- remove the first holder (promote);
- remove the sole holder;
- insertAsset with no interest;
- setInterest replacing {a} with {b};
- keepInterests on a copy;
- removeAllInterests;
- setAssets;
- the release lines of removeAsset and subtractAssets.
The direct count steps are the real kill for NB1. Only these unit tests kill NB5, NB7, NB8 and the mutant of the replacement arm (critique A11, on the f066083 precedent).
- T2, the order of re-routes.
Setup: 8 user waiters t1<...<t8 whose ids sort in the reverse order of their tokens, plus a 9th waiter that stays.
Assert the order from the new jobs' Job.epoch (EngineJobs.swift:137) or from admissionsForTests (EngineState.swift:77-82). Never assert it from source.starts (critique A3).
Mutants it kills: dropping the sort (killed with probability 1 - 1/8!); sorting by (asset, token) (killed deterministically).
- T3: the waiter joins first, then the group joins; release the waiter; then move. Run it both in the fit path and in the bounded path with budget 4 (critique A6). Mutants it kills: a wrong promote arm; holdings that reads `first` only.
- T4. It must fail first on 8e1fb24 (P3).
Setup: H holds w for waiter W and o1..o6 for group G. G is released while H downloads. v3 moves o1..o6, and the move is bounded.
Assert in both orders: violations are empty, and H.assets == [w].
Mutant it kills: dropping B7's subtraction of unheld ids.
- T5, the Q1 construction (analyse-state-cost.md, stage 1: followIDsPerTurn = 4, ids B1..B7, D, and A = 'zz-z'). It must fail first in sweep-first.
Assert:
- H.assets ⊇ {A, D};
- T' is served h's bytes;
- h's start count == 1 in both orders. Assert a count, not an order.
Mutant it kills: dropping the re-insertion of B8 (killed in sweep-first).
- T6, the per-turn pin of owed moves.
Setup: 8 held user publications; H is a 40-member group; 8 owed one-id moves.
Assert: the apply's turn moves at most 2 ids (inboundIDsNow), and each follow turn moves at most 4.
Mutant it kills: dropping `budget.ids -= made.spent` (EngineFollow.swift:1231).
- T7, oracle injections:
- I1, expecting the exact message;
- I2 and I3, each with a contains check (the injected state may trip neighbouring clauses).
- Run T2-T6 for 30 iterations per argument on the simulator under sim.lock, with 0 failures (critique A13).

### pins

- manyMovesTurns, from /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/correct/VerifyC20CorrectProbes.swift:305-441.
- k = 1, 16, 64 and 256. 256 is the most moves one turn makes (followsPerTurn, EngineFollow.swift:11; critique A2).
- Gate: best of 3 at most c2Budget, at load at most 10.
- Setup expects: violations empty; publishing == moves == owedOffH; one held turn makes k moves.
- If 256 publications cannot be held, pin the largest k that can be held and record it.
- partialMoveTurns, from /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/reqs/VerifyC20ReqsC2Probes.swift:142-197. Run it with users false and with users true. Setup expects onO == 501 and onH == 9,500.
- Merge gate: re-measure concentrationPublicationTurns with the index in place.
- Draft inventory:
- fill row docs/adr-drafts/s3f.md:4846;
- add rows for the index's own costs (critique A12): release in dropInterest, keepInterests on a copy, freeing at the commit;
- refresh the stale figures: throttleExtension 8.12-8.13 ms, handleRelease 5.27-5.67 ms.

### must_not

- Do not merge before commit-window Phase 1, and do not merge without the merge gate.
- Do not keep a Job copy alive across removals, in move, startMove, follow, continueInbound or answerPresentMembers.
- Do not give IDTokens an asymmetric `==`, and do not build the oracle's recount through add.
- Do not assert the order of source.starts.
- Do not remove setAssets or change its test.
- Do not drop `unfollowed.insert`.
- Do not land the re-insertion without T5, and do not land I2 without the re-insertion.
- Do not move :195. Do not re-derive items between turns. Do not merge move with continueMove.
- Do not change a public or package signature.

### residual_risks

- Unheld moved ids now leave the holder at the first turn, as they do on the fit path (critique R2). Readers that see this earlier than before: EngineFollow.swift:933; EngineMoves.swift:145; EngineDispatch.swift:1049; EngineFailures.swift:77, :80, :145 and :193; EngineDispatch.swift:1216; EnginePresence.swift:87; EngineDispatch.swift:905; EngineJobs.swift:443-445. Whether 8e1fb24 leaves a stale binding or failure record there is UNCONFIRMED.
- The Q1 holder now binds A, so the shape takes one transport start fewer.
- Variant Y's T1 half (the rest re-routes under the copy at its turn, EngineFollow.swift:832, while visit-first passes T1 on a publishing H, :860-865) stays an open 1(a) candidate. It is analyse-state-cost.md's stage 3.
- Memory: about +0.5 MB per job of 10,000 ids. Releasing the index costs O(ids): about +0.5-1 ms per 10,000 in dropInterest and RR-21's dropInterests. Freeing it costs about 50-150 µs in the commit window. keepInterests on jobAtVerdict's copy copies tokensByID once when it drops an interest. All figures UNCONFIRMED.
- An id with many holders still moves whole in one turn, at O(h log h) for the pairs' sort.
- Pre-existing:
- moved ids leave Job.assets without retireProgress;
- an empty binding can occur on the bounded path (the RR-20 family).

## C. commit-window: cut the commit's own turn below 7 ms in every grouping, without splitting it (correct #5, blocking; reqs #10). A contingent Phase 2 splits the answers only if a trigger fires.

### spec

- C0 Inventory. Record the commit turn's inventory in the draft: row docs/adr-drafts/s3f.md:4855, plus materializeEnsures, and correct row :4848 (critique A5). Mark its figures UNCONFIRMED until measured. Measured today: correct #5 10.16 ms best at load 3.12, and [14.65, 10.21, 10.45] in the full run; reqs #10 9.82 ms.
- C1 Lands only with RR-21 step 6, which rewrites the same lines (EngineDispatch.swift:1100-1139).
- Make `captured` lazy: `lazy var captured = Set(ids)`, replacing the eager Set at :1104 that every commit builds.
- Order refused's conjunction cheapest first: `!refused, let entry = copy.entry(for:), sameTransfer(entry, job.entry), captured.contains(asset)`.
If a local lazy var does not compile, fall back to an optional built once inside the branch.
- C2 resolveAll (EngineJobs.swift:611-628). Iterate `for (token, interest) in job.interests { self.deliver(...) }`.
- Remove the re-read at :619. It never fails, because deliver never writes state.jobs (EngineJobs.swift:546-590): it writes waiters, groups, run and heals only, and resumed continuations run after the turn.
- The doc at :606 becomes 'in the table's order'.
This is a change in the order of resumes; record it under S3-R16 item 2.
- C3 publishTerminal keeps today's ascending order without sorting, by walking the publication's sorted binding.
- Change `InterestOutcome.committed` (EngineJobs.swift:6-11) to `case committed([AssetID: AssetLocation], ascending: [AssetID])`, documented as the binding that publish sorted (EngineDispatch.swift:1049).
- committed builds `.committed(locations, ascending: ids)` (:1129).
- The patterns at EngineJobs.swift:553 and EngineRuns.swift:521 become `.committed(let locations, _)`.
- publishTerminal's `.committed` arm (EngineJobs.swift:635-640) becomes `for asset in ascending where locations[asset] != nil && job.assets.contains(asset)`.
This broadcasts the same set in the same order as `job.assets.sorted()`, given that locations.keys ⊆ ids:
- the store binds only ids from `ids` (AssetStore.swift:199-200; AssetStore+Publish.swift:285);
- stillBound returns a subset (AssetStore+Publish.swift:180-196).
The `.failed` arm (:641-642) is unchanged. C3 replaces RR-21 step 7, which kept the order but sorted the bound ids.
- C4 removeJob: `for asset in job.assets where self.state.progress.lastEmitted[.transfer(asset)] != nil { self.retireProgress(.transfer(asset)) }` (EngineJobs.swift:443-445).
Under P1-P3, a skipped retire is a no-op:
- trailing, lastEmitted and the heap entry are absent;
- no queue holds the slot;
- a no-op SubscriberQueue.retire never compacts, because compactIfNeeded's condition is unchanged since the last mutation (SubscriberQueue.swift:138-149, :161-175).
Progress is offered only for `job.assets.min()` (EngineDispatch.swift:905-906), so almost every id today pays a retire that does nothing: two hash removals, an O(H) heap scan (DeadlineHeap.swift:74-76), and a sort of the subscriber keys plus a retire per subscriber (EngineEvents.swift:74-78).
- C5 deliver's group arm (EngineJobs.swift:562-576), in place.
- Add `mutating func clearPending(_ assets: Set<AssetID>, on transfer: TransferID)` to Group (EngineState.swift:917-952). It drops the members in `assets` that still wait for `transfer`.
- Keep the arm's existence guard as `self.state.groups[token] != nil`, then call `self.state.groups[token]?.clearPending(interest.assets, on: transfer)`.
- Set spaceFailure through `self.state.groups[token]?` under today's condition (:569-571).
- For a settled ensure group, read the continuation, nil it in place, and resume it (critique A3).
Today `guard var group` plus the write-back at :572 copies `pending` on every delivery.
- C6 recordRunOutcome (EngineRuns.swift:515-534).
- Drop `.sorted()` at :523 and :528: the targets are dictionary assignments, so order does not matter.
- Use `lazy.filter` at :522.
- Write through `self.state.run?.` (outstanding at :519, failures, fetched) instead of `guard var run` and the write-back at :532, which copies outstanding and failures.
- Keep the `.committed` unbound loop. Critique A8's removal is rejected because it relies on an unchecked precondition; record the loop as pre-existing under S3-R19 item 3.
- C7 bind (EnginePresence.swift:61-68): after the guard, call `self.state.boundContent.reserveCapacity(self.state.boundContent.count + ids.underestimatedCount)`.
- C8 broadcast (EngineEvents.swift:10-33): split it into `broadcast(_ event:)`, which forwards the sorted keys, and `broadcast(_ event:, to keys: [UInt64])`, which holds today's body. publishTerminal hoists `self.state.subscribers.keys.sorted()` once for its loop.
A stale key is harmless:
- a finished subscriber removed mid-loop yields nil at :15 and is skipped;
- no subscriber can register mid-turn.
- C9 Progress-gate clause.
- Add the clause after the subscriber order clause (EngineCommands.swift:1791-1793). It reads the heap through `self.state.heap.entries` (DeadlineHeap.swift:36).
- Add `var liveSlots: [EventSlot] { Array(self.slots.keys) }` to SubscriberQueue. It must return an Array, because `slots` (:84) and `Live` (:79-82) are private. SubscriberQueue.swift is WP-F's file (ARCHITECTURE §1.2).
- C10 dropGroupMember in place (EngineJobs.swift:594-604; critique A1):
- `guard self.state.groups[token]?.pending[asset] == transfer else { return }`;
- `self.state.groups[token]?.pending[asset] = nil`;
- `guard let group = self.state.groups[token], group.kind == .ensure, group.isSettled, let continuation = group.continuation else { return }`;
- `self.state.groups[token]?.continuation = nil`;
- `continuation.resume(returning: true)`.
- C11 releaseRunClaim in place (EngineRuns.swift:505-512; critique A2):
- `guard self.state.run?.token == token, self.state.run?.outstanding[transfer] != nil else { return }`;
- `self.state.run?.outstanding[transfer]?.remove(asset)`;
- `if self.state.run?.outstanding[transfer]?.isEmpty == true { self.state.run?.outstanding[transfer] = nil }`.
- C12 Phase 2 is contingent. Trigger: after Phase 1, the in-actor commit turn for the .waiters shape has a best of 3 above 7.0 ms, or any heartbeat is above c2Budget. The commit-window design's owed answers then apply, with critique A7's changes:
- `static let answersPerTurn = 512` on SyncEngine, with an EngineState seam, not a SyncTuning field;
- the follow-up starts with `guard isRunning`;
- schedule when `owedAnswers.count > head`;
- no arm for a refused spawn;
- drainEverything flushes the owed answers and empties them;
- a // REENTRANCY: row on the follow-up's await.
For groupStalledSubscriber the contingency is SubscriberQueue.reserveCapacity. Otherwise, report to the orchestrator.
- C13 Records:
- the order of resumes under S3-R16 item 2;
- the Equivalent mutants under S3-R19 item 2;
- the inventory rows of C0;
- no DECISIONS.md change, since C3 keeps the order of terminal events.

### invariants

- Progress-gate clause:
- P1: every key in progress.trailing has a progress.lastEmitted entry.
- P2: every heap `.progress(slot)` deadline's slot has a lastEmitted entry.
- P3: every subscriber's live `.transfer(asset)` slot has a lastEmitted entry.
They hold by construction:
- the only writers are EngineEvents.swift:45-46, :51-53, :59-62 and :69-71;
- registerSubscriber replays no .transfer slot (:108-133);
- transferProgress is offered only through offerProgress (EngineDispatch.swift:906).
- deliver never writes state.jobs (EngineJobs.swift:546-590). C2 relies on it.
- MUSTs kept:
- R-SYN-12: removeJob runs before publishTerminal (EngineJobs.swift:624-625).
- F-20: the hold is set in the commit's turn.
- RE-S14.
- The commit stays one turn with no added await.
- Not relied on: interest ids ⊆ Job.assets. That is B's I2, and it fails on 8e1fb24 in the Q1 state.
- Phase 2's own clause is contingent, per the commit-window design.

### tests_and_mutants

- N1, the removeJob filter (C4).
- Dropping the filter is Equivalent under P1-P3.
- T-PG4 kills the `== nil` and `where false` mutants. It runs in both orders, on the publication-barrier setup:
  - C is shared by 3 user waiters;
  - one subscriber reads nothing;
  - two progress elements arrive inside one progressInterval, so a trailing flush is scheduled for the min id;
  - then C commits.
  Assert: violations are empty at every step, and after the commit no `.transfer` key of the 3 ids remains in lastEmitted, trailing, the heap or any queue.
- N2: T-PG1, T-PG2 and T-PG3 each inject one violation and expect exactly that message:
- trailing without lastEmitted;
- a heap `.progress` deadline without lastEmitted;
- a live .transfer slot without lastEmitted, by publishing a transferProgress straight into a queue.
- T-ORDER (C3), in both orders. A user-lane commit of 8 ids, one of them unbound. Assert exactly 7 assetAvailable events, in ascending order.
Mutants it kills:
- iterating `locations` or `job.assets` unsorted (probability 1 - 1/7!);
- dropping `locations[asset] != nil` (deterministic: an event for the unbound id).
Dropping `job.assets.contains` is Equivalent unless the store binds an id the job no longer holds. Record it as Equivalent if no shape reaches that case.
- N3, with RR-21.
- Building `captured` eagerly, and dropping `!refused`, are Equivalent.
- Dropping sameTransfer is killed by T-R1.
- Dropping `captured.contains` is killed by T-R2.
- 'Never true' is killed by T15 (design-minimal N15).
- The re-read removed at EngineJobs.swift:619 can never fail, because deliver never writes state.jobs.
- C5-C8 only change cost or capacity, so the mutants that re-insert the old code are Equivalent. Record them.
- C10 and C11, changed lines (S3-R25 item 10). Tests must reach each changed line in both orders, and kill each drop-mutant 2 out of 2 times:
- dropping the pending removal leaves an ensure group unsettled; use a bounded check;
- dropping the resume hangs the ensure caller; use a bounded check;
- dropping the claim removal keeps the run unsettled.
Use the T21 member drop and the run claim release (UNCONFIRMED which existing tests already reach them).
- Phase 2 tests T-A1 to T-A5, per the commit-window design, only if Phase 2 is triggered.

### pins

- concentrationPublicationTurns, unchanged.
- New BenchSync case `commitTurns(CommitShape)` at 10,000 ids, with shapes waiters, waitersStalledSubscriber, groupStalledSubscriber and manyGroups (critique A4).
- Gate: the heartbeat's best of 3 is at most c2Budget, at load at most 10.
- Also time the commit's own turn inside the actor (critique A10). That figure checks the 7.0 ms aim and decides the Phase 2 trigger.
- Added with RR-21: groupDelistedFit, groupDelistedAll, groupMovedToBound and runSuperseded.
- Measure concentrationPublicationTurns and commitTurns(.waiters) first after Phase 1: correct #5 is blocking, and item B's merge gate depends on them.

### must_not

- Do not split the commit's turn in Phase 1.
- Do not defer the answers behind the barrier. A withdrawal there is answered .cancelled at once (EngineCommands.swift:176-185).
- Do not defer the broadcasts or the binding.
- Do not shortcut the deliveries through job.assets or interestCounts.
- Do not iterate job.assets, locations or a Set for terminal events: the order stays ascending (C3).
- Do not edit DECISIONS.md, and do not change SyncTuning.
- C1 lands only with RR-21 step 6.
- Do not remove recordRunOutcome's `.committed` loop.
- Phase 2 has no arm for a refused spawn.

### residual_risks

- The resume cost R per continuation is unknown. A commit with 10,000 user waiters is estimated at 6.3-9.1 ms. UNCONFIRMED.
- Each subscriber adds about 0.25-0.6 µs per event, so two subscribers may miss C2. UNCONFIRMED; see open question 4.
- resolveAll's order of resumes becomes the table's order. Swift seeds each Dictionary's iteration from its storage, so that order varies from run to run. Recorded under S3-R16 item 2.
- The heartbeat may queue behind the resumed tasks.
- Unchanged by this item:
- DeadlineHeap.remove is an O(H) scan (DeadlineHeap.swift:74-76), now paid only by keys with a lastEmitted entry;
- pruneBoundContent walks every job's ids (EnginePresence.swift:74-90) at reconcileIdle (EngineDispatch.swift:1138);
- publish sorts the binding in an earlier turn (EngineDispatch.swift:1049);
- materializeEnsures sorts every group's token on each pump (EngineDispatch.swift:224), O(G log G) in the manyGroups shape;
- answerWaiterFromStore spawns one task per waiter (EnginePresence.swift:133-139).
Their costs are UNCONFIRMED.
- Pre-existing code that cannot run: EngineJobs.swift:556-557, a committed waiter with no location; and recordRunOutcome's `.committed` loop (EngineRuns.swift:523-525).

## rr21_source

design-minimal.md, at /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/design-minimal.md.

The RR-21 judge has not finished. The journal at /Users/admin/.claude/projects/-Users-admin-Documents-ZTronAssetKit/03c95f5a-f115-421f-9542-6de93e7caf98/subagents/workflows/wf_6b2553de-48c/journal.jsonl has 10 lines, was last written at 06:01 CET and was re-read at 07:51 CET on 2 Nov 2026. It has no 'started' entry labelled 'judge:rr21'.
- Started entries: design:reuse, analyse:g4-reach, design:fixer, design:minimal, analyse:state-cost.
- Result entries: analyse:g4-reach, analyse:state-cost, design:minimal, design:fixer.

RR-21 is not redesigned here. Only its interactions with the three items are specified.

Every code citation has the form Sources/ZTronAssetSync/Engine/<file>:<line>. It refers to the worktree /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f at commit 8e1fb24, which is clean, unless the citation gives another path.

## interactions

- 1 Order of replays at verdict V.
- Batch formation (A6) places V's bucket right after V.
- V's replay runs, in order: the take-off (RR-21 step 9, using moveItems or holdings), endDeferral, the verdict, followAfterVerdict, and rerouteTakenOff, which returns `left`.
- RR-21 step 12 puts `[(left, V's stamp)] + batch[(offset+1)...]` back at the head in one ordered insert. That suffix starts with V's bucket joins, newest first.
Final order: the verdict; the visit and its rest over follow turns; .reroutes; V's joins, newest first; the later events. The only order change is RR-21's own (moved-before re-routes come after the visit's whole rest), and RR-21 records it.
- 2 EventAfterFollow.verdictKey is an exhaustive switch, and RR-21's .reroutes returns nil. followBarrierViolations' switch (EngineCommands.swift:2017-2029) also gets RR-21's .reroutes arm.
- 3 withdrawPurgedJoins.
- RR-21 step 13's guard becomes `eventsAfterFollow.isEmpty`. K1 makes that safe: a bucket exists only while its verdict waits in the queue.
- It has three arms: A8's .join helper; the bucket at its verdict's position; RR-21's .reroutes.
- All three go through the in-place dropGroupMember (C10).
- 4 followedLane.
- RR-21 step 14's .reroutes arm goes in the queue loop (EngineFailures.swift:822-835), and A7's bucket walk comes after the loop.
- stillWants keeps its JoinAfterFollow form (:713-728) and delegates to RR-21's field-based version.
- 5 followBarrierViolations: one loop holds K1's counts, K2's bucket recount at each verdict's position, and RR-21's .reroutes arm.
- The .reroutes predicate is per (token, asset): `jobs[owed.from]?.interests[item.token]?.assets.contains(item.asset) != true`. The commit-window critique (A11) requires this because F-20's deferred items re-create jobs[owed.from].
- K3 and K4 follow.
- RR-21's shutdown and liveness argument must cite drainEverything (EngineShutdown.swift:118-124) and drainFollowUp's guard (EngineFollow.swift:411). It must not cite the spawn-nil branch (:390-399), which A11 removes.
- 6 drainEverything: clears joinsBehindVerdicts (A10); .reroutes events go with the clear at :118; Phase 2's flush is added if triggered.
- 7 invariantViolations: RR-21's acceptances, where the waiter (:1707-1712), group (:1777-1783) and run (:1812-1817) clauses accept .reroutes items; I1, I2 and I3; the progress-gate clause.
- 8 committed: one rewrite combining RR-21 step 6, C1 and 'collect first, mutate after', with no `job` copy alive across setInterest or subtractAssets. It also builds `.committed(locations, ascending: ids)` (C3).
- The setAssets call at :1118 disappears; setAssets stays for its unit test.
- Add the deterministic test from reqs #7: one token with one bound id and one unbound id.
- 9 publishTerminal: C3 replaces RR-21 step 7. Both keep the ascending order; C3 also avoids the sort. C8's hoisted keys serve both arms.
- 10 takeOffMovedBefore: RR-21 step 9 is built on B5's moveItems or holdings and the per-token counts, and it takes the TransferID. Its callers at EngineFollow.swift:352 and :615 stop passing Job copies.
- 11 Mutators: RR-21's dropInterests calls setInterest(nil), which releases index entries in O(ids), about +0.5-1 ms per 10,000 (UNCONFIRMED). Count it in RR-21's turn pins.
- 12 C10 and C11 (the in-place dropGroupMember and releaseRunClaim) are prerequisites for the C2 of RR-21's drain turns in the T21 shape and the .superseded run shape. Each turn of today's code copies `pending` or `outstanding`.
- 13 reconcileIdle and pruneBoundContent (EnginePresence.swift:74-90). With no run, no group with fetches left and no presence reader, pruneBoundContent keeps only the ids of jobs (:85-89). RR-21's .reroutes items sit on no job, so the commit's reconcileIdle (EngineDispatch.swift:1138) prunes their bindings. Their later reroute then misses the isBound check (EngineDispatch.swift:1164-1167) and joins a job, and that job's pre-transfer read answers them from the store (EnginePresence.swift:197-289). The cost is one more job and one more read, a timing change. This is RR-21's decision to make and record.
- 14 oweReroutes runs only in running turns (EngineDispatch.swift:1069, and publicationFailed's turns), so spawn succeeds (EngineLifecycle.swift:52-58). RR-21 needs no arm for a refused spawn.
- 15 The timeCommit window (BenchSync.swift:3253-3259, UNCONFIRMED) extends to the fall of the barrier, and commitTurns uses the same end.
- 16 deferBehindVerdict is now O(1) (A5), so design-minimal's O(N·E) objection no longer applies. Design-minimal itself is unchanged.
- 17 RR-21's .reroutes items sit on no job, so I1, I2 and I3 hold with RR-21 in place.
- 18 RR-21's re-route turns reach reroute, then answerPresent, then answerWaiterFromStore, which spawns one task per waiter (EnginePresence.swift:133-139). RR-21's per-turn budget (inboundIDsNow) bounds these spawns. Its pins should include an 'already bound elsewhere' shape (the cost per spawn is UNCONFIRMED).

## implementation_order

- 0 Baseline at 8e1fb24, in /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f: `SWIFTPM_SCRATCH=.build-<fixer> bash Scripts/verify.sh --quick`, then quote its last line. Take sim.lock for every simulator run (S3-R22 item 3).
- 1 Failing tests and pins first, committed on their own (P3), with their 'before' figures recorded on 8e1fb24:
- T4, which fails on 8e1fb24 (the I5 orphan);
- T5 stage 1, which fails in sweep-first;
- the new BenchSync cases: deferBehindVerdictTurns, manyMovesTurns at k = 1, 16, 64 and 256, partialMoveTurns, and the commitTurns shapes.
- 2 Commit-window Phase 1: C2-C11 and the C9 clause, with T-PG1 to T-PG4 and T-ORDER. C1 waits for RR-21. C3's InterestOutcome change can land now, because committed already has `ids`. The build stays green, since every step is local.
Measure first: concentrationPublicationTurns and commitTurns(.waiters), both the heartbeat and the in-actor turn. This decides the Phase 2 trigger and opens item B's merge gate.
- 3 Defer-bucket: A2-A10 with K1-K3 and their tests. Then A11, the branch removal, with K4 and F-K4.
Measure: deferBehindVerdictTurns, and the T1 per-turn pin in both orders.
- 4 Move-index, in this order:
- B2-B4 with I1 and I3, and EngineIDTokensTests (unit, green before any caller changes);
- B5-B7 and B9-B11 with T2, T3, T4 and T6;
- B8 with I2 and T5, together.
Measure: manyMovesTurns at k = 256 first, then partialMoveTurns, then concentrationPublicationTurns with the index in place (the merge gate).
- 5 RR-21, design-minimal steps 1-16:
- fold C1 into its step 6;
- its step 7 is already replaced by C3;
- build its step 9 on B5;
- its steps 12-15 edit the code that A6-A9 left.
Measure: concentrationCommitRerouteTurns, movedBeforeDrainTurns, and the superseded, delisted and run shapes.
- 6 Phase 2 (C12), only if triggered, with T-A1 to T-A5.
- 7 waitingTarget (reqs #4, correct #6): tests for the `.queued, .blocked, .downloading` case (EngineFollow.swift:1260-1261), using Shapes A and B from /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/analyse-g4-reach.md.
- 8 Close:
- the full SyncBenchmarks at load at most 10;
- covdiff on the changed lines, and the mutation table (S3-R25 item 10);
- 30 simulator iterations per argument (critique A13);
- coverage three times;
- the tools-6.4 check with 0 warnings (S3-R13);
- `bash Scripts/verify.sh --full`, quoting `VERIFY: PASS`;
- update the draft: inventory rows :4846, :4848, :4850 and :4855-4858, the S3-R16 item 2 records and the Equivalents. Do not edit DECISIONS.md, SPEC, Scripts or Package.swift.

## open_questions

- 1 Does a branch reached only in sweepFollowsFirst count as 'reached in both orders'? The state does not arise in followVisitedFirst by construction. This affects A5-A9's bucket branches, B8's re-insertion and the waitingTarget case.
- 2 Suppose Phase 1's in-actor .waiters commit turn stays above 7.0 ms. Before Phase 2 splits the answers, may the cross-subject order of one job's terminal events become the Set's order? That order is unspecified and varies run to run, and it would save one lookup per id. C3's default keeps the ascending order.
- 3 If T5 cannot be built, may B8's re-insertion and I2 be dropped together, with Q1 and variant Y recorded as residual risks?
- 4 Are misses that depend on one or more stalled subscribers inside C2's reference set? S3-R22 to S3-R25 name 10,000 ids in any grouping, but no subscriber count.
- 5 Should the pre-existing candidates be probed this cycle, or only recorded (S3-R19 item 1)? They are: orphaned run claims at a verdict replayed with the barrier down; recordRunOutcome's `outstanding[T] = nil` at EngineRuns.swift:519; and variant Y's T1 half.

## unconfirmed

- Every cost and time estimate, including the 6.3-9.1 ms commit figure, the index costs, the materialization shift and the per-subscriber cost.
- That a local `lazy var` compiles in Swift 6.3 strict mode. C1 gives a fallback.
- That locations.keys ⊆ ids. AssetStore.swift:199-200 and AssetStore+Publish.swift:180-196 and :285 support it; bindRecords and placeAndBind were not read.
- That no reachable shape binds an id the job no longer holds, which would make the `job.assets.contains` mutant of C3 Equivalent.
- Citations into files not read in this session: BenchSync.swift:3253-3259 and the bench names it holds; EngineFollowBarrierHopTests.swift:155-162; EngineFollowBarrierPublicationTests.swift:312-358; EngineFollowBarrierLaneTests.swift:212-275; EngineInterestCountsTests.swift:81-83; EngineOutcomeTests.swift:457; EngineState.swift:77-82 (admissionsForTests); the probe files under .build-orchestrator/s3f-probes-c20; EngineDispatch.swift:1013-1045 beyond the lines quoted.
- That Set.intersection iterates the smaller operand (the critic read it from the SDK).
- That T5, T-FL, T1-space and manyMovesTurns at k = 256 can be built.
- That the MoveRevalidation outcomes are unchanged by B6-B10.
- That in-place mutation through Dictionary's _modify (the `self.state.x[key]?.y` idiom) avoids the copies in both debug and release builds. Verify with the pins.
- That the empty-Set singleton allocates nothing per IDTokens entry.
- Whether an end-to-end .spaceFailure bucket test can be built.
- That no existing test depends on the order of resumes or of group completions (C2).
- Whether any existing BenchSync case defers joins behind a verdict and counts drained events from eventsAfterFollow only (BenchSync.swift:2916-2931, :585).
- Q1 stages 2 and 3, and whether variant Y can be reached (analyse-state-cost.md).
