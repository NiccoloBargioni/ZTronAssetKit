# design2:commit-window

Read-only analysis for ruling S3-R26 (workflow wf_bc7908d4-1ad, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## item

The commit's turn (cycle 20: correct #5, blocking; reqs #10, non-blocking), at 8e1fb24. The turn is EngineDispatch.swift:1069-1091: committed (:1100-1139), then resolveAll (EngineJobs.swift:611-628), then publishTerminal (:631-645). Measured 9.82-10.16 ms best of 3 at 10,001 bound ids (concentrationPublicationTurns, BenchSync.swift:645-650; gate run 9.86 ms, docs/adr-drafts/s3f.md:7515-7516), against c2Budget = 10 ms (BenchSync.swift:129).

## recommendation

Keep the commit in one actor turn and remove every sort and redundant O(N) step from it (Phase 1, steps 1-9). Fold these steps into RR-21's committed rewrite: they amend design-minimal step 6 and replace step 7. Step 7 still sorts the bound ids, so it saves nothing in the all-bound shapes.

Do not split the turn now:
- The split points that change only timing are the bounded resumption of answers computed in the commit's turn, and deferred deallocation. They save at most the cost of the resumes and the frees, and they add state, a follow-up turn and a shutdown branch.
- The split points that would save more each change something that is not timing:
  - deferring the answers behind the barrier changes answers: a withdrawal behind the barrier is answered .cancelled at once (EngineCommands.swift:177-182);
  - deferring the terminal events breaks R-SYN-12's latest-event-per-subject rule: a later assetRemoved would be superseded in a subscriber's slot by a deferred assetAvailable (SubscriberQueue.swift:116-129), and a subscriber registered in between would receive extra events;
  - deferring the binding is read by the commit's own re-routes (EnginePresence.swift:9) and saves only about 0.6 ms.

Pins:
- concentrationPublicationTurns, unchanged.
- A new commitTurns test with three shapes: waiters (10,000 ids sharing one content, a user waiter each, all bound), waitersStalledSubscriber, and groupStalledSubscriber.
- Each pin passes at best of 3 <= c2Budget, and each prints the commit window against the 7 ms aim. The waiters case supplies the missing figure for the one-waiter-per-id grouping (S3-R25 item 2).

Phase 2 (step 13, bounded owed answers) is fully specified below. Implement it only if commitTurns(.waiters) has a best of 3 above 7.0 ms, or any commitTurns case misses c2Budget.

Estimates after Phase 1, with no subscriber (S=0); none measured:

| Grouping | Today | After Phase 1 |
|---|---|---|
| One prefetch group | 9.86 ms, measured | 4.0-5.0 ms |
| 10,000 user waiters | about 13-16 ms, no figure, likely a C2 miss today | 6.3-9.1 ms, central 6.8; depends on the resume cost R, unconfirmed |
| Moved-away commit turn | | 3-4 ms, plus RR-21's drain turns |

Each subscriber adds about 0.25-0.35 µs per terminal event.

## mechanism

- 0. Inventory of the commit's turn at 8e1fb24. The turn runs from store.publish's return (EngineDispatch.swift:1058) to the await at EngineTimers.swift:298, or to its early return at :295. Costs are at 10,001 ids, calibrated to the measured 9.86 ms. Notation: S = subscribers, H = heap entries, I = interests, U = unbound ids, R = one continuation resume (UNCONFIRMED, 0.1-0.4 µs).
- (a) `let captured = Set(ids)` (:1104): O(N), about 0.7 ms. It is read only at :1125.
- (b) `bind(locations.keys)` (:1106, EnginePresence.swift:61-68): O(N) inserts with about 14 growths, about 0.75 ms.
- (c) `job.interests.sorted` (:1109): O(I log I) plus an array of I pairs. About 0 ms at I=2, about 0.6 ms at I=10,000.
- (d) The per-interest filter (:1110): about 0.6 ms for one group, about 1.0 ms for 10,000 interests. Only when ids are unbound: `subtracting` (:1114); `unbound.sorted()` (:1120), O(U log U); TransferID formatting (:1121), about 0.75 µs per id; and `reroute` (:1122), about 4.8 µs per id (RR-21's 48.68 ms).
- (e) resolveAll (EngineJobs.swift:611-628):
  - `keys.sorted()` (:618): O(I log I), about 0.3 ms at I=10,000.
  - The per-token re-read (:619): a hash of the 66-byte TransferID plus two lookups, about 1.1 ms at I=10,000.
  - deliver (:546-591) for a waiter: about 0.15 µs + R each, so 2.5-5.5 ms at 10,000.
  - deliver for a group: `pending` is copied on write at :563/:566, then 10,000 lookups and removals, then the old table is freed at :572. About 1.6-1.8 ms.
  - deliver for a run (:578, EngineRuns.swift:522-523, :528): `assets.filter` plus `assets.sorted()`, about 4 ms when a run's interest holds 10,000 ids.
- (f) `removeAllInterests` (:623): O(1). The interests' frees, about 0.6 ms at 10,000, land wherever the last Job copy dies.
- (g) `removeJob` (:624, loop at :443-445): `retireProgress` per id (EngineEvents.swift:68-79) does two hashed removals, a `DeadlineHeap.remove`, which is `removeAll(where:)` and O(H) (DeadlineHeap.swift:74-75), and a `subscribers.keys.sorted()` per id. About 1.3 ms at small H; O(N·H) in general.
- (h) publishTerminal (:625): `job.assets.sorted()` at :635 is O(N log N) with AssetID's byte-wise `<` (AssetID.swift), about 3.3 ms. Each id then costs a lookup plus a broadcast (EngineEvents.swift:10-31: sorted subscriber keys and notifyObservers per event), about 1.0 ms at S=0, plus 0.35 µs per event per subscriber.
- (i) `follow()` (:626): RR-21's work. Either up to inboundIDsNow re-routes (at most about 1.3 ms), or one owed event plus a MoveProgress heapify, O(U).
- (j) Bounded or small steps:
  - `checkRunSettled` (:627): O(1) without a run.
  - pump (:1137): bounded by parksPerPump; `slotCounts` is O(in-flight) (EngineDispatch.swift:47-61).
  - reconcileIdle (:1138): `pruneBoundContent` (EnginePresence.swift:74-90) is O(B) `removeAll` (about 0.2 ms), or an O(B + Σ job ids) filter (0.6-1 ms).
  - The prefix of refreshStoreDeadlineAfterPublish (EngineTimers.swift:292-296): O(H).
  - notifyObservers (EngineCommands.swift:1679-1692): O(1) with no observers; O(snapshot) per call under a waitUntil seam, which only tests use.
- (k) O(1): `recordBreaker` (:1072, EngineFailures.swift:953-974), `transition` (:1080), and the byte counters (:1081-1082).
- Sum: one group, about 9.9 ms (measured 9.86); 10,000 user waiters, about 13-16 ms.
- 1. EngineDispatch.swift:1104 and :1121-1125, folded into design-minimal step 6. Replace `let captured = Set(ids)` with `lazy var captured = Set(ids)`. In step 6's single unsorted pass, set refused with the cheap negative test first: `if !refused, let entry = copy.entry(for: asset), SyncEngine.sameTransfer(entry, job.entry), captured.contains(asset) { refused = true }`, where `copy` is `self.state.applied`. The Set is then built only when an unbound id still maps to this content, so never in the all-bound or moved-away shapes. Land this only together with step 6: removing the sorts at :1109 and :1120 alone would change today's re-route order, which step 6 replaces with MoveProgress's (asset, token) order.
- 2. EngineJobs.swift:618-622, resolveAll. Replace the sorted keys and the re-read with `for (token, interest) in job.interests { self.deliver(outcome, to: token, interest: interest, transfer: transfer) }`. In the doc at :606, replace 'in token order' with 'in the table's order'; the reason is that deliver never touches the job (:545), so the snapshot is exactly what the table holds. This removes the O(I log I) sort, I TransferID hashes, and the `if let` arm at :619, which nothing reaches.
- 3. EngineJobs.swift:635, publishTerminal. This replaces design-minimal step 7. Change `for asset in job.assets.sorted()` to `for asset in job.assets`, for both outcomes; this also covers the direct call at EngineFailures.swift:304. Keep the per-id `locations[asset] != nil` test, so the event set stays job.assets ∩ bound. Update the doc to say that the 10,001-id sort cost about 3.3 ms of the commit's turn.
- 4. EngineJobs.swift:443-445, removeJob. Change the loop to `for asset in job.assets where self.state.progress.lastEmitted[.transfer(asset)] != nil { self.retireProgress(.transfer(asset)) }`. Add a `///` note that a progress key's trailing emission, its deadline and its subscriber slots exist only with a lastEmitted entry (P1-P3, step 9). Transfer progress is published only for `job.assets.min()` (EngineDispatch.swift:905-906), so only a few keys are retired. This also removes the O(N·H) heap scans.
- 5. EngineJobs.swift:563, deliver's group arm. Change `guard var group = self.state.groups[token] else { return }` to `guard var group = self.state.groups.removeValue(forKey: token) else { return }`; the write-back at :572 stays. The group, taken out of the table, is uniquely referenced, so the removals at :566-568 mutate pending in place instead of first copying every member and later freeing the old table.
- 6. EngineRuns.swift:522-523 and :528, recordRunOutcome. Change `assets.filter { locations[$0] != nil }.count` to `assets.lazy.filter { locations[$0] != nil }.count`. Drop `.sorted()` at :523 and :528. `run.failures` is a dictionary, and the report sorts it (EngineRuns.swift:770).
- 7. EnginePresence.swift:64-67, bind. Inside the guard, before the loop, add `self.state.boundContent.reserveCapacity(self.state.boundContent.count + ids.underestimatedCount)`: one allocation instead of about 14 growths at 10,001 ids.
- 8. EngineEvents.swift:10-31 and EngineJobs.swift:631-645. Split broadcast:
- `func broadcast(_ event: AssetEvent)` becomes `self.broadcast(event, to: self.state.subscribers.keys.sorted())`.
- `func broadcast(_ event: AssetEvent, to keys: [UInt64])` holds today's body and loops over `keys`.
- publishTerminal computes `let keys = self.state.subscribers.keys.sorted()` once before its loop and calls the second form.
This is safe because no subscriber registers during the loop, and one that a finished handOff removes is skipped by the existing optional chain at :15. It saves the per-event key array at S≥1, about 0.06-0.1 µs per event.
- 9. EngineCommands.swift, in invariantViolations after the heldForManifest clause (:1818-1820), plus SubscriberQueue.swift after `liveCount` (:96).
- Add `var liveSlotKeys: [EventSlot] { Array(self.slots.keys) }` to SubscriberQueue.
- Add the progress-gate clause; its exact predicates are under invariants (P1-P3).
- This turns the premise of step 4's Equivalent mutant into a checked invariant.
- 10. Pins, in Tests/ZTronAssetKitBenchmarks/BenchSync.swift.
- Keep concentrationPublicationTurns (:645-650) unchanged as the one-group pin.
- Add after :664 `@Test(..., .timeLimit(.minutes(5)), arguments: CommitShape.allCases) func commitTurns(_ shape: CommitShape)`, with `CommitShape` = `waiters`, `waitersStalledSubscriber` and `groupStalledSubscriber`.
- The test runs one warm-up at 1,000 ids and three runs at 10,000. For each run it checks:
  - `#expect(run.ids == 10_000 && run.interests == (shape is a group shape ? 1 : 10_000) && run.served && run.committed)`;
  - for the subscriber shapes, `run.buffered >= 10_000`, read from introspect().bufferedEvents as pruneAnnouncementWait does (:2427, :2435-2441, keeping the stream alive with withExtendedLifetime);
  - it prints the waits and the commit window against the 7 ms aim, then checks `#expect((waits.min() ?? .infinity) <= Self.c2Budget)`.
- The helper `SyncBench.commitTurn(count:shape:)`:
  - builds concentration's environment (:3073-3104) with `SteppedBlockingExecutor(holding: false)` as the bulk executor;
  - applies `SyncBench.sharing(count, hBytes)` (:3751) with a forced sync, then calls `store.flush(.ordered)`;
  - scripts `source.script(H, [.hold, .stage(hBytes)])`;
  - for the waiter shapes, starts one `Task { await engine.awaitAsset(id, lane: .userInitiated) }` per id and spins as userShared does (:1132-1190) until `userHolding(engine, H)` is (count, count, count) and `isRunning(engine, H)`; for the group shape, calls `registerGroup(ids, lane: .prefetch)` and waits until H holds count ids and is running;
  - calls `engine.subscribe()` for the subscriber shapes, then `bulk.setHolding(true)`, `source.release(H, with: .progress(received: 0, expected: nil))` and `bulk.waitForHeldUnits(atLeast: 1)`, then `raiseOwnedTaskPriority(engine)`;
  - times the window as timeCommit does (:3253-3259): `longestWait { bulk.setHolding(false); bulk.releaseAll(); while jobExists(H) { bulk.releaseAll(); yield } }`;
  - sets `served` to every caller `.success`, or the group answered, and `committed` to `!jobExists(H)`;
  - shuts down and awaits the callers.
- RR-21 can add its moved-away user-waiter shape to the same helper.
- 11. Tests: T-PG1-T-PG4 in a new file, Tests/ZTronAssetSyncTests/Engine/EngineProgressGateTests.swift, and T-R1 and T-R2 beside RR-21's commit tests (EngineFollowBarrierPublicationTests.swift) unless design-minimal's tests already cover them. The shapes are under new_branches.
- 12. Docs, in docs/adr-drafts/s3f.md, plus one DECISIONS.md entry:
- record two order changes under S3-R16 item 2: publishTerminal's cross-subject event order, and resolveAll's order of resumes;
- record the Equivalent mutants of steps 2-8 under S3-R19 item 2;
- update the C2 inventory row 'The commit's binding' (:4855) with the new figures;
- the DECISIONS.md entry records that a job's terminal events are published in its id set's order.
- 13. Phase 2, CONTINGENT. Implement it only if commitTurns(.waiters) has a best of 3 above 7.0 ms, or any commitTurns case exceeds c2Budget, after steps 1-12. It bounds owed answers.
- EngineState gains `var owedAnswers: [OwedAnswer] = []`, `var owedAnswersHead = 0`, `var answerFollowUp: UInt64?`, and a hold seam like holdFollowFollowUps.
- `enum OwedAnswer { case waiter(InterestToken, CheckedContinuation<Result<AssetLocation, AssetError>, Never>, Result<AssetLocation, AssetError>); case ensure(InterestToken, CheckedContinuation<Bool, Never>) }`.
- SyncTuning gains `answersPerTurn` = 512, injectable like followIDsPerTurn.
- resolveAll (EngineJobs.swift:611) computes `let owe = job.interests.count > self.tuning.answersPerTurn` and passes it to deliver as `owing:`.
- deliver's resume sites (:552-560, :573-576) append an OwedAnswer instead of resuming when `owing` is set. After the loop, `if owe { self.scheduleAnswerFollowUp() }`.
- The follow-up is an owned task spawned when `answerFollowUp == nil`, with `// REENTRANCY: RE-S21 — nothing: it resumes answers stored in the commit's turn`. It resumes up to answersPerTurn answers from owedAnswersHead, compacts the array once it is emptied, clears answerFollowUp, and reschedules if answers remain.
- If spawn returns nil (only once shutdown began, EngineLifecycle.swift:52-56), the answers are left to the drain: drainEverything (EngineShutdown.swift:47-130) moves `owedAnswers[head...]` into ShutdownDrain and settles them with their stored values within shutdownStepsPerTurn.
- The new clause and tests T-A1-T-A5 are under invariants and new_branches.

## invariants

- NEW clause (step 9), the progress gate, with exact predicates. Let `emitted = state.progress.lastEmitted`.
- (a) For every slot in `state.progress.trailing.keys`: `emitted[slot] != nil`. Message: "the trailing \(slot) progress has no emission".
- (b) For every d in `state.heap.entries` (DeadlineHeap.swift:36): `if case .progress(let slot) = d.reason` then `emitted[slot] != nil`. Message: "the \(slot) progress deadline has no emission".
- (c) For every key in `state.subscribers.keys.sorted()` and every slot in `state.subscribers[key]?.liveSlotKeys ?? []`: `if case .transfer = slot` then `emitted[slot] != nil`. Message: "subscriber \(key) holds \(slot) with no emission".
- (c) is limited to `.transfer` slots, because a run's subscriber slots legitimately outlive `retireProgress(.run)` (EngineEvents.swift:72-77).
- Why it holds today:
  - trailing is set, and a `.progress` deadline scheduled, only inside `if let last = lastEmitted[slot]` (EngineEvents.swift:44-46);
  - lastEmitted is set before every broadcast of a progress event (:51-54, :62-63);
  - the only removal of lastEmitted (:70) also removes the trailing entry (:69), the deadline (:71) and every subscriber's `.transfer` slot (:75-77);
  - `EventSlot(.transferProgress)` is the only producer of `.transfer` slots (SubscriberQueue.swift:50-51), and `.transferProgress` is built only at EngineDispatch.swift:906;
  - ProgressGate is never reassigned (EngineState.swift:500).
- Relied on, existing and unchanged: deliver never writes state.jobs (EngineJobs.swift:545). Its callees write only waiters, groups, heals, run, the progress gate, the heap, subscribers, the alarm and test seams: recordRunOutcome (EngineRuns.swift:515-534), offerRunProgress (EngineEvents.swift:83-101, which only reads jobs), offerProgress, rearm (EngineTimers.swift:10-35), broadcast, notifyObservers and decisionNow (EngineFollow.swift:241-243). This is the basis of step 2.
- MUSTs kept unchanged:
- R-SYN-12: each subject has one slot holding its latest terminal event, and events are seen in publication order. Terminal events are still published after the job's progress keys retire: removeJob comes before publishTerminal (EngineJobs.swift:624-625).
- F-20: the hold is still set in the commit's turn (EngineDispatch.swift:1130-1132), with the same predicate value.
- RE-S14: answers go to the interests present now, which is resolveAll's snapshot, as today.
- T21/T22: as RR-21 defines them.
- The commit stays one actor turn. Phase 1 adds no await (so no REENTRANCY comment) and no turn boundary. Both LaneDropVisit orders (EngineFollowTests.swift:780-787) therefore meet the same interleavings as today.
- NOT relied on: that an interest's ids are a subset of job.assets. The reachable state in analyse-state-cost.md Q1 refutes it, so committed's per-interest lookup pass stays, with no shortcut through job.assets or counts.
- Phase 2 clause, CONTINGENT:
- `owedAnswersHead <= owedAnswers.count`.
- `isRunning && owedAnswers.count > owedAnswersHead` implies `answerFollowUp != nil`.
- For every owed `.waiter(token, _, _)`: `state.waiters[token] == nil`.
- For every owed `.ensure(token, _)`: `state.groups[token]?.continuation == nil`.

## answer_equality_argument

Phase 1 adds no await and no turn boundary. The store's answer, the binding, every answer, the job's removal, the terminal events, RR-21's owed re-routes and the pump all stay in the one synchronous turn EngineDispatch.swift:1069-1091. So nothing interleaves differently in either LaneDropVisit order, and equality reduces to each step leaving the same state and giving the same answers within the turn.

(1) Step 1, refused. It is the same boolean: there exists an unbound a with sameTransfer(copy.entry(a), job.entry) and a in ids. sameTransfer is the transferID test without formatting (EngineJobs.swift:208-219). Reordering the conjunction and building the Set lazily change only when work is done, and the F-20 hold is still set in the commit's turn.

(2) Step 2, resolveAll. deliver never writes state.jobs (doc at :545, callees listed under invariants), so the re-read at :619 always returned the snapshot's interest. Each token's delivery touches only its own waiter or group, its interest's heals (idempotent removals) or the single run. The only event produced inside the loop, the run's syncProgress, still precedes publishTerminal's events. So the same answers are given; only the order in which continuations are resumed changes, which is timing (recorded under S3-R16 item 2).

(3) Step 3, publishTerminal. The event set is the same: assetAvailable(a, generation) for every a in job.assets with locations[a] != nil, or assetFailed(a, error, .nextRun) for every a. Each event is published once, with state.generation unchanged during the loop. Each subject occurs once, so the order per subject is unchanged; only the order across subjects changes, from ascending AssetID to the Set's order. No test depends on that order:
- EngineFollowBarrierHopTests.swift:139-148 waits for one id's assetAvailable, then checks that a verdict's assetFailed events from an earlier turn are present.
- EngineRecoveryTests.swift:160-166 and :201-207, EngineClaimRetryTests.swift:53-56, EngineLiveTransportTests.swift:188-195, FacadeReopenTests.swift:285/:345/:353/:419/:643, EngineRegressionCycle3Tests.swift:296-299 and EventContinuityModelTests (I1/I2) each match a single subject.
- EngineUnitTests.swift:17-28 tests SubscriberQueue alone.
The order across subjects is not an answer, and no MUST fixes it: sync.md §10.3 promises publication order, which still holds.

(4) Step 4, removeJob. retireProgress(.transfer(a)) is a no-op when lastEmitted[.transfer(a)] is nil. By P1-P3, the trailing entry, the deadline and every subscriber's slot are then absent. SubscriberQueue.retire of an absent slot leaves both its slots and its storedOrderCount unchanged; a compaction pending after an exhausted take() only re-lays the order array. So the same keys retire, with the same effects.

(5) Step 5, the group arm. The final group value is the same. Only the groups table's layout changes, and every iteration of it whose order matters sorts first (EngineDispatch.swift:224, EngineShutdown.swift:70).

(6) Step 6, recordRunOutcome. The fetched count and the failures dictionary are the same; the report sorts failures (EngineRuns.swift:770), and progress only counts them (EngineEvents.swift:88).

(7) Step 7 changes capacity only.

(8) Step 8 publishes the same events in the same sequence: no subscriber can register inside the loop, and one removed by a finished handOff is skipped by the optional chain (EngineEvents.swift:15).

Phase 2, contingent. Every owed answer is computed in the commit's turn from the same state, and its waiter is removed from state.waiters in that turn, as today (EngineJobs.swift:549). So a later withdraw is a no-op (EngineCommands.swift:176-192), and the shutdown drain, which takes state.waiters, never answers it .shutDown. The follow-up or the drain resumes each owed continuation exactly once with its stored value, so every caller gets the unsplit engine's result; only the moment it returns changes.

## c2_argument

Unit costs used:
- AssetID-keyed lookup or insert: 50-80 ns. AssetID.swift hashes the count plus the UTF-8 bytes; == compares the count, then String ==, then elementsEqual.
- AssetID comparison (utf8.lexicographicallyPrecedes): 20-30 ns, so sorting 10,001 ids costs about 3.3 ms. EngineFollow.swift:15-17 records 3.6 ms for 10,000 TransferIDs.
- broadcast at S=0: about 40 ns. Each subscriber adds 0.35 µs per event (the prune case: 13.15 against 9.68 ms over 10,000 events); after step 8, about 0.25 µs.
- deliver to a waiter: 0.15 µs + R.
- This model gives about 9.9 ms for today's measured commit window (9.86 ms, s3f.md:7515), so its figures are scaled by 0.94.

After Phase 1, at S=0, every turn stays within c2Budget by estimate, in every grouping:

(1) One prefetch group of 10,000 plus O's waiter (concentrationPublicationTurns): 4.0-5.0 ms, against 9.86 today.
- bind, reserved: 0.6 ms
- pass: 0.65 ms
- group deliver in place: 1.3 ms
- retire filter: 0.6 ms
- unsorted publishTerminal: 1.1 ms
- prune, frees and the rest: 0.55 ms

(2) 10,000 single-id user waiters, all bound (new pin): about 5.7 ms + 10,000·R.
- bind 0.6, pass 0.8, deliver 10,000 × (0.15 µs + R), interest frees 0.6, retire 0.6, publishTerminal 1.1, the rest 0.4 ms.
- That is 6.3-9.1 ms after scaling, central 6.8 ms at R ≈ 0.15 µs, against about 13-16 ms today (no figure exists).
- It meets c2Budget for any R ≤ about 0.4 µs, and the 7 ms aim only for R ≤ about 0.15 µs; that is Phase 2's trigger.

(3) Moved-away mix after RR-21 (concentrationCommitRerouteTurns): commit turn about 3-4 ms.
- bind 1 id.
- The pass over 10,000 unbound ids (two lookups, sameTransfer and an append each): 1.5-2 ms.
- MoveProgress heapify: about 0.5 ms.
- Retire lookups 0.6 ms and publishTerminal lookups 0.6 ms; owing the re-routes is O(1).
- The drain turns, at most drainIDsLeft (512) × about 5 µs, are about 2.5-3 ms each (RR-21).
- A bound/moved-away mix with user waiters costs no more than shape (2): bound ids cost shape (2)'s per-id rate, and unbound ids cost about 0.15 µs each plus the heapify.

(4) Other groupings:
- 10,000 one-member prefetch groups: about 5-6 ms.
- 10,000 one-id ensure calls: as shape (2).
- A run's interest holding the 10,000-id job: about 3-4 ms (today about 4 ms more, from recordRunOutcome's filter and sort).

With S subscribers, add about 0.25 µs per terminal event each (2.5 ms per subscriber at 10,000 ids):
- one group at S=1: about 6.5-8 ms, against about 14 ms today (estimate);
- 10,000 user waiters at S=1: about 8.5-11.5 ms. So the waitersStalledSubscriber pin may trigger Phase 2.

Phase 2, contingent:
- The commit's turn loses 10,000·R (1-4 ms) and gains about 0.2-0.3 ms of appends.
- Each follow-up turn resumes at most answersPerTurn (512) continuations, about 0.1-0.25 ms.
- User waiters then come to about 5-5.5 ms at S=0 and about 7.5-8.5 ms at S=1.

Every other turn the design touches stays the same or gets cheaper. Verdicts reach resolveAll and publishTerminal from EngineFailures.swift:178-363, EngineFollow.swift:626/:674 and EngineDispatch.swift:1236-1246, and they lose the same sorts. Every removeJob loses its per-id heap scans.

## new_branches

- N1: removeJob's filter `where self.state.progress.lastEmitted[.transfer(asset)] != nil` (EngineJobs.swift:443).
- Both arms are reached by every non-bulk job that emitted progress.
- Drop-mutant (no filter): this is today's loop. It is Equivalent, cost only (S3-R19 item 2), under P1-P3.
- The negated mutant (`== nil`) and the `where false` mutant are each killed 2/2 by T-PG4.
- T-PG4 runs in both LaneDropVisit orders, on EngineFollowBarrierPublicationTests' publication-barrier setup. Content C is shared by 3 ids, each awaited by a user caller, and one subscriber reads nothing. Two progress elements arrive inside one progressInterval, so lastEmitted, trailing, a `.progress` heap deadline and the subscriber's slot all exist for C's least id. Then C commits.
- T-PG4 asserts that invariantViolations() is empty after every step, and that after the commit none of lastEmitted, trailing, the heap or `liveSlotKeys` holds a `.transfer` key of the 3 ids.
- N2: the clause's three predicates (step 9). Tests T-PG1-T-PG3 run on a started harness. They involve no follow, but each runs once per LaneDropVisit case to satisfy the both-orders rule. Each injects one violation through readForTests, expects exactly that message, then removes the injection before shutdown:
- (a) `state.progress.trailing[.transfer("x")] = .transferProgress("x", TransferProgress(received: 1, expected: 2))`, with no lastEmitted entry;
- (b) `state.heap.schedule(.progress(.transfer("y")), at: now)`;
- (c) a subscriber registered through subscribe(); its queue then gets `state.subscribers[key]?.publish(.transferProgress("z", …), sequence: lastEventSequence + 1)`.
Dropping that predicate's `violations.append` fails its test 2/2.
- N3: step 1's conjunction for refused inside step 6's pass, `!refused, let entry = copy.entry(for: asset), SyncEngine.sameTransfer(entry, job.entry), captured.contains(asset)`, with `lazy var captured`.
- Eager build of the Set: Equivalent, cost only.
- Dropping `!refused`: Equivalent, because the assignment is idempotent.
- Dropping the sameTransfer conjunct: killed 2/2 by T-R1, in both orders. In T-R1, v4 maps 3 members to another content while O's publication waits at the store. After the commit, heldForManifest does not contain O's transfer, and the 3 interests are re-routed or owed.
- Dropping `captured.contains`: killed 2/2 by T-R2, in both orders. In T-R2, an apply maps a new id to C after C's binding was captured, and that id is awaited. The commit moves it to a fresh job of C that starts at once, and heldForManifest stays empty.
- A predicate that is never true: killed by design-minimal's T15, where the store refuses 3 captured ids that the copy still maps to C, and C is held.
- Removed branch: resolveAll's `if let interest = self.state.jobs[transfer]?.interests[token]` (EngineJobs.swift:619). No path reaches its false arm, because deliver never writes the job.
- No new branch in steps 3, 5, 6, 7 and 8: each is a token deletion or a hoisted value. Re-inserting the removed code is cost-only, so those mutants are Equivalent (S3-R19 item 2). The existing branches in deliver and recordRunOutcome keep today's mutants and tests.
- CONTINGENT, Phase 2 only. All tests run at an injected answersPerTurn = 4, in both orders.
- A1, resolveAll's fit guard `job.interests.count > answersPerTurn`. T-A1: 10 waiters on C commit while the answer follow-ups are held. After the commit's turn, no caller has returned and 10 answers are owed; the released follow-ups answer 4, then 4, then 2, each `.success(location)`. It kills 2/2 both 'no fit guard' and 'the follow-up ignores the bound'. T-A5: 4 waiters are answered in the commit's turn with no follow-up, killing `>=` in place of `>`.
- A2, the follow-up's reschedule when answers remain: T-A1's third turn covers it.
- A3, the drain's flush of owed answers. T-A3 shuts down between the commit and its first follow-up, and every caller gets its `.success`. It kills 'answers dropped', which hangs until the time limit, and 'answered .shutDown'. The arm where spawn returns nil is covered by T-A3's flush.
- A4, withdraw between turns. T-A2 cancels one caller between the turns, and that caller gets `.success`, not `.cancelled`. It kills 'waiter kept in state.waiters until resumed'.
- A5, the clause. T-A4 injects owedAnswers with answerFollowUp = nil while running and expects the message, killing the clause's drop.

## interactions

- Step 1 amends design-minimal step 6. Keep its single unsorted pass over job.interests (MoveItems plus stubs), and change only `captured` (made lazy) and the order of refused's conjunction. Land the two together: the sorts at :1109 and :1120 define today's re-route order, which step 6 replaces with MoveProgress's (asset, token) order.
- Step 3 replaces design-minimal step 7. Step 7's `job.assets.filter { locations[$0] != nil }.sorted()` still sorts the 10,001 bound ids (about 3.3 ms) and builds a 10,001-element Set in every all-bound commit, so iterate job.assets with the lookup instead, for both outcomes.
- The order inside the commit's turn is unchanged:
- the answers (resolveAll);
- then removeAllInterests and removeJob, which retires the progress keys;
- then publishTerminal;
- then follow(): holdForManifest, then either startReroutes, which re-routes up to inboundIDsNow (256) at once, or oweReroutes, which queues one `.reroutes` event, raises the barrier and schedules a drain follow-up;
- then checkRunSettled, which returns at once behind the barrier;
- then pump (:1137), which refuses once the barrier is up;
- then reconcileIdle.
No answer or terminal event of the commit waits behind the owed event.
- resolveAll's snapshot is taken after step 6's pass. A wholly unbound interest (removed with setInterest(nil)) is therefore not delivered and its items are owed, exactly as with today's re-read. A partly unbound group has its bound members cleared in place (step 5) and its unbound members owed.
- The job's assets still hold the moved-away ids. Steps 3 and 4 cost one lookup each for them and publish no event; their progress keys retire with the job, as today.
- The `.reroutes` arm of followBarrierViolations (design-minimal step 15: no item's interest is still on jobs[owed.from]) holds at once, because the commit removes jobs[owed.from] in the same turn.
- Costs RR-21 adds to the commit's turn in the moved-away shapes (MoveItem appends, the stub table and the O(U) MoveProgress heapify) are counted in the C2 estimate (about 3-4 ms). The owed re-routes cost about 2.5-3 ms per drain turn, which is RR-21's own pin.
- Phase 2, if triggered, is independent of `.reroutes`:
- owed answers raise no barrier and never wait for the drain;
- the drain's verdict replays (resolveAll from replayVerdict, EngineFollow.swift:626) use the same fit guard;
- drainEverything must flush owed answers next to its clearing of eventsAfterFollow (EngineShutdown.swift:118);
- a re-route that ends a waiter under T21 resumes it directly in reroute (EngineDispatch.swift:1155), never through the owed answers.
- timeCommit's window (BenchSync.swift:3253-3259) ends when O's job is gone. design-minimal step 16 extends it to the point where the barrier comes down, and commitTurns uses the same end condition, so the shapes that owe re-routes are measured the same way.

## risks

- The resume cost R is unknown (UNCONFIRMED, 0.1-0.4 µs). The shutdown bench's doc gives an upper bound near 1 µs: 17-22 ms for one turn holding two 10,000-TransferID sorts, 10,000 resumes and 10,000 job frees (BenchSync.swift:226-229). After Phase 1 the user-waiter commit is therefore 6.3-9.1 ms by estimate, and the new pin decides whether Phase 2 is needed.
- Subscribers. Production has 0 to k engine subscribers, because the facade subscribes once per app event consumer (ClientLifecycle.swift:252/328), while every commit bench runs with none. Each subscriber adds 0.25-0.35 µs per terminal event. The user-waiter commit with one subscriber comes to about 8.5-11.5 ms after Phase 1 (7.5-8.5 ms with Phase 2), and today's measured one-group commit with one subscriber is about 14 ms by estimate, a C2 miss the benches cannot show.
- Event order. The cross-subject order of one job's terminal events becomes the Set's iteration order, which varies across launches because Swift's hash seed is per process. A future test that reads two subjects of one commit in sequence with a skipping probe would flake. Record this under S3-R16 item 2 and in DECISIONS.md.
- O(H) heap removals remain elsewhere: removeJob's `.retry` removal (EngineJobs.swift:442) and every DeadlineHeap.remove call (:74-75) are O(H). A turn that removes many jobs (prunes, verdicts) stays O(jobs·H). This is outside the item; put it to the orchestrator.
- pruneBoundContent (EnginePresence.swift:74-90) is O(B + Σ job ids) on every reconcileIdle call. That is about 0.2-1 ms in the commit's turn, and it runs again in the next turn through setStoreDeadline (EngineTimers.swift:312).
- The publication's start turn sorts the job's ids (EngineDispatch.swift:1049, about 3.3 ms at 10,001). Once the commit falls to about 4-5 ms, that turn may become concentrationPublicationTurns' longest window. This is outside the item.
- The interests' frees, about 0.6 ms, may land in the publication's tail turn rather than the commit's turn, if the compiler keeps `current` (EngineDispatch.swift:1073) alive across the await at :1091. The total is the same.
- The high-priority heartbeat (BenchSync.swift:1407-1430) could queue behind the tails of the 10,000 resumed waiters if the default actor did not run higher priorities first. The pin would then read more than the commit's turn. C2 still holds per turn, because each tail is a short turn of its own.
- The reachable Q1 state (analyse-state-cost.md) keeps committed's per-interest lookup pass, about 0.6-0.8 ms. No count or job.assets shortcut is safe.
- Step 2 assumes no awaitCondition or waitUntil closure writes state.jobs during a delivery; if one did, it would see a stale snapshot. None is known.
- After step 5's remove-and-reinsert, a test that reads state.groups in iteration order (for example values.first with several groups) could see a different order. If any such test exists, move the loop into a mutating Group helper called through `self.state.groups[token]?`, which mutates in place without changing the layout.
- Load noise (S3-R5). Today the margin is 0.14 ms; the estimates leave 2-5 ms at S=0.

## unconfirmed

- R, and which executor a waiter's withCheckedContinuation (EngineCommands.swift:91-133) resumes to: the engine actor or the generic executor.
- Every per-step figure. They are estimates calibrated against one measured total (9.86 ms, s3f.md:7515-7516), and none was measured per step. The all-bound user-waiter commit has no figure at all (design-minimal.md risks).
- That the prune case's 0.35 µs per event per subscriber applies to terminal events, and that hoisting the subscriber keys in step 8 saves 0.06-0.1 µs per event.
- That no test depends on the cross-subject order of terminal events or on the order of waiter resumes. The tests were read, not run.
- That ids can leave job.assets while the store publishes. This is why step 3 keeps job.assets ∩ bound instead of iterating the already sorted ids.
- That a local `lazy var` compiles under Swift 6 strict concurrency inside an actor method (C7: the compiler decides). If it does not, use an optional with one explicit build branch, whose 'never built' mutant T-R2 and T15 kill.
- Which existing tests kill recordRunOutcome's bound/unbound mutants. Also whether its `.committed` unbound arm is reachable at all, since committed narrows every interest to bound ids before resolveAll.
- Whether the default actor runs the high-priority heartbeat ahead of 10,000 resumed tails of lower priority.
- That no awaitCondition or waitUntil closure in the tests writes engine state.
- The O(N·H) per-entry cost (about 3 ns), and the about 30 ms figure at N=10,000 and H=1,000.

## events_between_turns

- Phase 1 adds no turn boundary. The commit's turn still ends at refreshStoreDeadlineAfterPublish's await (EngineTimers.swift:298) or its early return (:295). Any turns the owed re-routes add are RR-21's, and its design covers them.
- Phase 2, contingent. What may land between the commit's turn and each answer follow-up:
- a caller's cancellation: withdraw finds no waiter (EngineCommands.swift:176-192), so it is a no-op, and the owed `.success` is still delivered;
- shutdown: drainEverything resumes the owed answers with their stored values;
- a new resolve of a committed id: isBound holds, so it is answered from the store, as after an unsplit commit;
- a prune or quarantine of a committed id: its owed answer was already computed, just as the unsplit engine answered before the prune;
- a new subscriber: unaffected, because answers are not events;
- another large commit or verdict: its answers are appended behind, on independent tokens.

## rejected_alternatives

- Deferring the commit's answers behind the follow barrier as an owed event, with the waiters still registered. A withdrawal behind the barrier is answered .cancelled at once (EngineCommands.swift:177-182, Waiter doc at EngineState.swift:898-900), where the unsplit engine had answered .success. That changes answers.
- Answering in chunks while the job stays `.committing`. It needs new arms in withdraw, releaseGroup, shutdown, the follow visits that pass a committing job, and prunes. A prune between chunks would answer a pending waiter .notFound under T21 where the unsplit engine answered .success, so it changes answers unless every path learns about the pending commit.
- Deferring publishTerminal's broadcasts. A later event for the same subject, such as a prune's assetRemoved or a quarantine, would be superseded in a stalled subscriber's slot by the deferred assetAvailable (SubscriberQueue.swift:116-129). A subscriber registered in between would receive events the unsplit engine had published before it registered. And clientShutDown must stay last. Fixing all three needs a global ordered FIFO with per-subscriber registration stamps; keep it only as a fallback if Phase 2 still misses with a subscriber.
- Deferring the binding. It saves about 0.6 ms, but the commit's own re-routes and answerPresent read boundContent (EnginePresence.swift:9) in the same turn.
- design-minimal step 7, publishTerminal over `job.assets.filter { locations[$0] != nil }.sorted()`. It still sorts every bound id; superseded by step 3.
- Iterating the already sorted `ids` in publishTerminal to keep today's ascending order. It needs ids threaded through resolveAll, plus a second lookup per id (`job.assets.contains`), because ids may leave job.assets while the store publishes. That costs about 0.5 ms more. It remains the option if the orchestrator wants the order kept.
- Driving retirement by lastEmitted's keys, which is O(k). It saves a further 0.5 ms, but adds a `case .transfer` arm and a job-membership arm whose mutants (retiring `.run` or another job's slots) need new tests. Step 4's filter is Equivalent and needs none.
- Shortcutting committed's per-interest unbound check through job.assets or counts. The state in analyse-state-cost.md Q1 is reachable, and the shortcut would answer .notFound there.
- Deferred deallocation: keeping the removed Job in state and dropping it in a follow-up turn. It moves about 0.6 ms of frees and adds state for no semantic gain.
- Fusing committed's pass with resolveAll's delivery, so each waiter needs one lookup instead of two. It saves about 0.5 ms but restructures resolveAll for a single caller; held in reserve.

## size_estimate

Phase 1, production code: about +40/-20 lines.
- EngineDispatch.swift: +2/-2, inside RR-21's step 6.
- EngineJobs.swift: +6/-8 (resolveAll, publishTerminal, removeJob, deliver).
- EngineRuns.swift: three token edits.
- EnginePresence.swift: +1.
- EngineEvents.swift: +6/-2.
- EngineCommands.swift: +16 for the clause.
- SubscriberQueue.swift: +4.

Phase 1, tests: about +260 lines.
- BenchSync: commitTurns, SyncBench.commitTurn, CommitRun and CommitShape, about 120.
- EngineProgressGateTests (T-PG1 to T-PG4), about 80.
- T-R1 and T-R2, about 60, unless design-minimal's tests already cover them.

Phase 1, docs: the S3-R16 item 2 order records, the S3-R19 item 2 Equivalents, the C2 inventory row, and one DECISIONS.md entry.

Phase 2, only if triggered: about +90 lines of production code (state, OwedAnswer, the fit guard, the follow-up, the drain flush, the seam and the clause) and about +200 lines of tests (T-A1 to T-A5).
