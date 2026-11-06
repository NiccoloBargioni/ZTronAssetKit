# critic:commit-window

Read-only analysis for ruling S3-R26 (workflow wf_bc7908d4-1ad, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## verdict

sound with amendments

## refutations

- R1 (C2 miss when ids move away from a prefetch group; amendment A1 is required).
- What the design claims: the moved-away commit turn costs 3-4 ms (recommendation table, c2_argument (3)), and the drain turns cost 512 x about 5 us (interactions [6]). docs/adr-drafts/s3f.md:4848 lists reroute as 'O(1) amortised an id'.
- What the code does: dropGroupMember (EngineJobs.swift:594-599) copies the group out (`guard var group = self.state.groups[token]`) and removes one member (`group.pending[asset] = nil`). That copies the whole pending table on write. It then writes the group back (:599) and frees the old table. This is the same pattern the design's own step 5 diagnoses at :563-572.
- How reroute reaches it, once per id:
  - prefetch members whose asset left the manifest (T21, EngineDispatch.swift:1151-1156);
  - members answered present (:1164-1165, then EnginePresence.swift:100-103).
- Such a re-route therefore costs O(|pending|), not about 4.8 us. The 48.68 ms of concentrationCommitRerouteTurns (s3f.md:4856) is a T22 figure: its ids are mapped to another content (BenchSync.swift:651-653), which takes the in-place arm (EngineDispatch.swift:1176-1179).
- Shape (i): one 10,000-member prefetch group. 256 members share O's content; the rest are pending on their own jobs. v4 delists the 256 while O's publication waits at the store. design-minimal step 3's fit case (count <= inboundIDsNow = 256, EngineMoves.swift:130-132) re-routes all 256 in the commit's turn: 256 copies and frees of a table of about 10,000 [AssetID: TransferID] entries. TransferID is a heap String (TransferID.swift:21).
- Shape (ii): the concentrationCommitRerouteTurns setup, with v4 deleting the members instead of mapping them elsewhere. Each 512-item drain turn (design-minimal step 11) makes 512 such copies.
- Estimate (UNCONFIRMED, not measured): 13-75 ms in the commit's turn for (i), and 25-150 ms per drain turn for (ii).
- Today the inline loop (EngineDispatch.swift:1120-1123) makes this O(U x |pending|) in a single turn.
- Ensure groups are not affected: their pending is at most materializationLimit (EngineDispatch.swift:216-229).
- R2 (C2 for run claims in RR-21's owed re-routes).
- releaseRunClaim (EngineRuns.swift:505-512) copies `run` and the claim Set out, removes one id (a copy on write of the Set, then of `outstanding` at :510) and writes back. That is O(|claimed| + |outstanding|) per call.
- reroute calls it first for every run interest (EngineDispatch.swift:1148-1150).
- In the commit's turn it is a guarded no-op, because recordRunOutcome has already cleared outstanding[O] (EngineRuns.swift:519; design-minimal.md:104).
- supersede keeps the claim, though (EngineDispatch.swift:1256-1273), and design-minimal step 8 owes those re-routes. A run interest holding the 10,000-id job then copies Sets of about 10,000 elements 512 times per drain turn (UNCONFIRMED by measurement).
- The design still uses 'drainIDsLeft (512) x about 5 us' for every owed re-route.
- R3 (a gap in the C2 inventory).
- The design treats pump as bounded (mechanism 0(j)). But every pump calls materializeEnsures (EngineDispatch.swift:94). It sorts every group key and copies every Group out of the table to test its kind (:224-225): O(G log G) plus G struct copies, prefetch groups included.
- The commit's pump (:1137) pays this cost.
- At 10,000 one-member groups, which is S3-R22-25's 'many groups' grouping, it adds about 0.8-1.5 ms (UNCONFIRMED). The design estimates 5-6 ms for that prefetch grouping and 6.3-9.1 ms for 10,000 one-id ensure calls (c2_argument (4)); the ensure grouping can then reach c2Budget.
- No pin covers any many-groups shape.
- R4 (rulings).
- Step 12's 'one DECISIONS.md entry' is an edit S3-R6 forbids: DECISIONS.md changes are PROPOSED in the draft (s3-rulings-s3f.md:11).
- Phase 2's 'SyncTuning gains answersPerTurn' changes a public, Codable, Hashable type in ZTronAssetModel (Sources/ZTronAssetModel/Policy/SyncTuning.swift:103). That breaks S3-R6 (no public or package signature changes) and S3-R7 (this work package's files only).
- 'Injectable like followIDsPerTurn' is inconsistent: followIDsPerTurn is a `static let` on SyncEngine (EngineMoves.swift:126) with a seam in EngineState (EngineState.swift:106-108). It is not a SyncTuning member.
- R5 (evidence for the subscriber cost).
- The design's '0.35 us per event per subscriber (the prune case: 13.15 against 9.68 ms over 10,000 events)' pairs two unrelated figures:
  - 13.15 ms is a throttle-extension miss (s3f.md:6221);
  - 9.68 is a mean load reading (s3f.md:6398).
- The prune case itself measured [6.12, 6.69, 6.81] ms for the whole apply turn with one stalled subscriber (s3f.md:5353-5354). That bounds the subscriber cost at about 0.6 us per event or less, not 0.35.
- At 0.6 us, groupStalledSubscriber can reach about 9.5-11 ms.
- Phase 2 cannot help that shape: a single interest is never over answersPerTurn, so nothing is owed. The contingency plan is incomplete for it.
- R6 (Phase 2's unreachable arm).
- The claim 'The arm where spawn returns nil is covered by T-A3's flush' (new_branches A3) is wrong. T-A3's commit runs while lifecycle == .running (guard at EngineDispatch.swift:1069), so spawn returns a key (EngineLifecycle.swift:53-58) and the nil arm is not taken.
- To be reached, the arm needs resolveAll with `owe`, or a reschedule, while the engine is not running. committed's guard and drainFollowUp's guard (EngineFollow.swift:411) exclude every path I found (others UNCONFIRMED).
- As specified, it is a branch no listed test reaches (S3-R16 1(e)).
- Minor: spawn also returns nil while degraded (EngineLifecycle.swift:54), not only once shutdown has begun.
- R7 (interaction with RR-21, interactions [5]).
- The design says design-minimal step 15's `.reroutes` clause ('no item's interest is still on jobs[owed.from]') holds at once. That is true in the commit's turn only.
- Owed items that the copy still maps to O's content re-route onto a fresh job of that same content (doc at EngineDispatch.swift:1094-1099; reroute, then addInterest at :1188).
- From the first drain turn, jobs[owed.from] therefore exists again and holds the same group token, while that token's later items are still owed.
- A check by token alone would then report a false violation; it must test the (token, asset) pair. UNCONFIRMED: step 15's exact predicate is not given.

## amendments

- A1, required (closes R1): rewrite dropGroupMember (EngineJobs.swift:594-604) to mutate in place, with the same branches as today:
```
guard self.state.groups[token]?.pending[asset] == transfer else { return }
self.state.groups[token]?.pending[asset] = nil
guard let group = self.state.groups[token], group.kind == .ensure, group.isSettled, let continuation = group.continuation else { return }
self.state.groups[token]?.continuation = nil
continuation.resume(returning: true)
```
- The group ends with the same value and no branch is added, so no answer changes.
- It also removes the per-id copy from:
  - reroute's T21 and present arms in the follow (EngineFollow.swift:941/948; EngineMoves.swift:208);
  - withdrawPurged (EngineCommands.swift:1022-1025) and withdrawPurgedJoins (:1063);
  - design-minimal step 13's purge arm.
- A2, required for RR-21's `.superseded` drain turns (closes R2): rewrite releaseRunClaim (EngineRuns.swift:505-512) to mutate in place:
```
guard self.state.run?.token == token, self.state.run?.outstanding[transfer] != nil else { return }
self.state.run?.outstanding[transfer]?.remove(asset)
if self.state.run?.outstanding[transfer]?.isEmpty == true { self.state.run?.outstanding[transfer] = nil }
```
Optionally write recordRunOutcome (EngineRuns.swift:516-532) through `self.state.run?` too, so `outstanding` and `failures` are not copied on every verdict.
- A3, step 5 (EngineJobs.swift:563-572): prefer a mutating method on Group (EngineState.swift:917-952) over removeValue and re-insert:
- add `mutating func clearPending(_ assets: Set<AssetID>, on transfer: TransferID)`;
- call it as `self.state.groups[token]?.clearPending(interest.assets, on: transfer)`.
It is also in place and keeps the groups table's layout, so risk [10] disappears. A1 uses the same idiom.
- A4, pins (step 10). Add these shapes to commitTurns, or to RR-21's helper, each at best of 3 <= c2Budget:
- groupDelistedFit: a 10,000-member prefetch group whose 256 members on O's content are delisted by v4 while O publishes (the fit case, in the commit's turn);
- groupDelistedAll: all 10,000 delisted, timing the drain turns;
- groupMovedToBound: the members are moved to content the store holds bound;
- manyGroups: 10,000 one-member prefetch groups sharing one content, all bound;
- runSuperseded: a run interest holding the 10,000-id job is superseded, if RR-21 owns that site.
Without these shapes, R1-R3 stay unmeasured.
- A5, docs/adr-drafts/s3f.md:4848: correct the row.
- Until A1 and A2 land, reroute is O(1) only for T22 and for waiters. It is O(|pending|) for a prefetch member ended by T21 or answered present, and O(|claimed| + |outstanding|) for a run interest whose claim still stands.
- After A1 and A2, cite the new pins.
- Add materializeEnsures (EngineDispatch.swift:224-225) to the commit's row (:4855) and to the design's inventory item (j).
- A6, step 12:
- Put the DECISIONS.md entry into docs/adr-drafts/s3f.md as PROPOSED, per S3-R6.
- Word it as 'the order across subjects of one job's terminal events is unspecified (Set iteration)', not 'published in its id set's order'.
- Flag it to the orchestrator as a change in the observable order of the public events stream.
- A7, Phase 2 (step 13):
- Replace 'SyncTuning gains answersPerTurn' with `static let answersPerTurn = 512` on SyncEngine, next to followIDsPerTurn (EngineMoves.swift:126), and `var answersPerTurn = SyncEngine.answersPerTurn` in EngineState (by EngineState.swift:108) as the test seam.
- Start the follow-up with `guard self.isRunning else { return }`, as drainFollowUp does (EngineFollow.swift:411).
- In the same turn as drainEverything's flush (next to EngineShutdown.swift:118), empty owedAnswers and reset owedAnswersHead, so no continuation is resumed twice.
- Schedule the follow-up when `owedAnswers.count > owedAnswersHead`, not on `owe`: prefetch groups and runs owe nothing.
- Remove the spawn-nil arm: assign spawn's result to answerFollowUp and let the clause 'isRunning && owed > head implies answerFollowUp != nil' check it. Otherwise give the arm a test that reaches it.
- A8, step 6 (EngineRuns.swift:521-525): settle the design's unconfirmed item [6] by removing code.
- Why the loop is unreachable:
  - committed narrows every interest to its bound ids (EngineDispatch.swift:1110-1119);
  - resolveAll's snapshot is taken after that (EngineJobs.swift:615);
  - `.committed` is delivered only from :1129, because resolve (EngineJobs.swift:537-543) is called only with `.failed` (:660).
- Delete the unbound loop (:523-525) and write `run.fetched += assets.count` at :522, with the precondition in a `///` comment.
- Record the reason in the draft under S3-R19 item 3, rather than editing a line no test can reach.
- A9, c2_argument and risks [1]:
- Base the cost per subscriber on s3f.md:5353-5354 (at most about 0.6 us per event), or on the measured difference groupStalledSubscriber minus concentrationPublicationTurns.
- Add a contingency Phase 2 cannot cover: `SubscriberQueue.reserveCapacity(slots:order:)` (SubscriberQueue.swift, next to publish at :107), called once per subscriber with job.assets.count before publishTerminal's loop. It changes only capacity (an Equivalent mutant) and avoids about 14 rehashes of each stalled subscriber's table.
- If groupStalledSubscriber still misses, put S >= 1 to the orchestrator.
- A10, commitTurns:
- Also time the commit's own turn inside the actor, as concentration times its held turns (BenchSync.swift:663, :3066-3067).
- Use that figure for the 7 ms aim and for Phase 2's trigger, and keep the heartbeat's best of 3 as the gate.
- Reason: the 10,000 awaitAsset tails resume on the actor as separate jobs (EngineCommands.swift:91-93), and the heartbeat may queue behind them (risk [7]; UNCONFIRMED).
- A11, interactions [5]:
- Require design-minimal step 15's clause to test `jobs[owed.from]?.interests[token]?.assets.contains(asset)` for each owed item, not merely whether the token is present.
- State that F-20's deferred items re-create jobs[owed.from] from the first drain turn onward.

## checked_claims

- Step 1 (confirmed).
- sameTransfer is the transferID test without formatting (EngineJobs.swift:210-219), and Job.entry is a `let` (EngineState.swift:676-678).
- The reordered conjunction gives the same boolean, and building the Set lazily changes only cost.
- Step 2 (confirmed).
- deliver (EngineJobs.swift:546-590) never writes state.jobs. Its callees only resume continuations or publish (recordRunOutcome, EngineRuns.swift:515-534; broadcast, EngineEvents.swift:10-33), with no synchronous re-entry.
- So the re-read at :619 always returns the snapshot's interest, and its false arm cannot be reached.
- Each token's delivery touches only its own waiter or group, its heals, or the single run. Only the order of resumes changes.
- `.committed` reaches deliver only through resolveAll at EngineDispatch.swift:1129; resolve (EngineJobs.swift:537-543) is called only with `.failed` (:660). Confirmed by grep.
- Hence recordRunOutcome's unbound loop for `.committed` (EngineRuns.swift:523-525) is unreachable.
- So is deliver's `.notFound` arm for `.committed` (EngineJobs.swift:556-557).
- Step 3 (confirmed; tests read, not run).
- The event set is unchanged: the per-id test against locations stays (EngineJobs.swift:637-639).
- No subscriber is removed during publishTerminal's loop. Removal (EngineEvents.swift:24-25) needs a finished queue, and publish rejects a finished queue before any hand-off (SubscriberQueue.swift:108-110).
- No test compares event sequences that span several subjects (grep over Tests/); EngineFollowBarrierHopTests and EventContinuityModelTests each match a single subject.
- Step 4 (confirmed). Premises P1-P3 hold:
- trailing and the `.progress` deadline are set only when a lastEmitted entry exists (EngineEvents.swift:44-47);
- lastEmitted is removed only by retireProgress, which also removes trailing, the deadline and the `.transfer` slots (:68-79);
- `.transferProgress` is produced only through offerProgress (EngineDispatch.swift:906);
- DeadlineHeap is a sorted array, so removing an absent reason changes nothing (DeadlineHeap.swift:33-36, :74-76);
- retire of an absent slot only runs compactIfNeeded. After an exhausted take(), that re-lays `order` with nothing stored (SubscriberQueue.swift:138-175), so the order-bound clause (EngineCommands.swift:1791-1793) is unaffected.
The drop-mutant is therefore Equivalent under S3-R19 item 2 (s3-rulings-s3f.md:242).
- Step 5 (confirmed).
- No path exits between :563 and the write-back at :572, so removing the group and writing it back never loses it.
- Iterations over groups whose order matters sort first (EngineDispatch.swift:224, EngineShutdown.swift:70).
- The unsorted ones are the invariant clauses (EngineCommands.swift:1777, :1871) and scans of the values (EngineDispatch.swift:265, EnginePresence.swift:78); none depends on order.
- Step 6 (confirmed). run.failures is a dictionary (EngineState.swift:1092). The report sorts it and keeps the first 1,000 (EngineRuns.swift:770-785), and progress only counts it (EngineEvents.swift:88). The order does not matter.
- Step 7 (confirmed): it changes capacity only. pruneBoundContent's removeAll (EnginePresence.swift:81-83) drops the capacity again whenever no job is left, so the growths recur at every commit and the saving recurs too.
- Step 8 (confirmed): equivalent, by the same argument as step 3 (no subscriber is added or removed during the loop).
- Phase 1 adds no await (confirmed). The commit's turn is EngineDispatch.swift:1069-1091, ending at the await at :1091.
- The reasons for rejecting alternatives hold (confirmed):
- behind the barrier, withdraw answers .cancelled at once (EngineCommands.swift:177-182);
- a non-progress event in a live slot is replaced and moved to the tail (SubscriberQueue.swift:119-128);
- isBound reads boundContent (EnginePresence.swift:9-11).
- Phase 2 changes no answers, only timing (read, not run):
- awaitAsset does not check anything after its resume (EngineCommands.swift:91-133);
- an ensure caller that cancels gets .cancelled at once from withdrawEntry (:1522-1531);
- the ensure task re-reads the lifecycle after its resume (:753-764);
- drainEverything takes waiters and groups (EngineShutdown.swift:52-71) and clears eventsAfterFollow (:118), so owed answers do need the flush the design adds.
- spawn (confirmed): isRunning means lifecycle == .running (EngineLifecycle.swift:99-101), and spawn returns nil only when shutting down, shut down or degraded (:53-55).
- New clause (confirmed).
- invariantViolations is called only from tests and once from BenchSync.swift:2411, so the clause costs no production turn.
- readForTests (EngineRegressionCycle3Tests.swift:459) gives isolated, writable access, so the injections in T-PG1 to T-PG3 are possible.
- reroute's T22 arms mutate in place: groups (EngineDispatch.swift:1176-1179), waiters (:1170-1174) and runs (:1184). So about 4.8 us per id holds for T22 and for waiters (confirmed).
- Invariants [2]'s 'removeJob comes before publishTerminal' holds in resolveAll (EngineJobs.swift:624-625). The retry-cap path does the reverse (EngineFailures.swift:304-305) and is unchanged. A precision note, not a defect.
- No bench covers members leaving the manifest, or a purge, under a waiting prefetch group (grep of BenchSync's @Test titles). No measured figure contradicts R1.

## confidence

Medium-high on answer equality, invariants and the G4 reasoning: I read every line the design touches, and their callers, at 8e1fb24. Medium on the C2 refutations R1-R3: the copy-on-write mechanism is cited line by line, and the design's own step 5 relies on the same mechanism. But nothing could be measured (the review was read-only), and the cost of copying and freeing a 10,000-entry table is an estimate.

## c2_concerns

- R1 also hits turns outside the commit, and A1 fixes all of them:
- reroute's T21 and present arms in the follow copy a prefetch group's pending table once per id (EngineFollow.swift:941/948 through supersede; EngineMoves.swift:208);
- withdrawPurged's loop is unbounded within its turn (EngineCommands.swift:1007-1031), so a purge under a waiting 10,000-member prefetch group is O(N^2) in one turn. That predates Stage 3 and is unmeasured.
- Two or more subscribers. Neither phase reduces the O(N x S) broadcasts. At about 0.25-0.6 us per event per subscriber, two consumers add 5-12 ms at 10,000 ids: a likely C2 miss in every grouping. The facade subscribes once per app event consumer (ClientLifecycle.swift:252, :328). Put this to the orchestrator.
- The waiters estimate (6.3-9.1 ms) depends on R, the resume cost, which is unmeasured. With materializeEnsures counted, the 10,000 one-id ensure calls come to about 7-10.5 ms.
- recordRunOutcome copies `outstanding` and `failures` once per call (EngineRuns.swift:516-532: `guard var run`, then a write-back). That is small in the commit, but O(jobs x failures) in a turn that resolves many of a run's jobs. Minor; UNCONFIRMED.

## g4_concerns

- Step 6 edits line :523, whose loop body (EngineRuns.swift:523-525) no test can reach, so no test can kill its drop-mutant. Remove it, as in A8 (S3-R19 item 3).
- deliver's `.notFound` arm for `.committed` (EngineJobs.swift:556-557) is unreachable for the same reason. It predates this design and the design leaves it untouched. Record it or remove it under S3-R19 item 3; not blocking.
- Phase 2 as written has two arms no test reaches:
- the spawn-nil arm, because T-A3 does not take it;
- 'owe' set with nothing owed (prefetch groups or runs over answersPerTurn), which no test tells apart.
A7 removes both.
- A1 and A2 change lines inside existing branches. The rule on changed lines (S3-R25 item 10) needs tests that reach them and kill their drop-mutants 2/2 in both orders.
- Candidates are tests that mention a member leaving the manifest or dropGroupMember: EngineFollowTests.swift, EngineRegressionCloseOutTests.swift and EngineRegressionRound3Tests.swift.
- Which of them kill the mutants is UNCONFIRMED. Name them in the draft, or add a test of a prefetch member removed under T21 and one of a member answered present, at followIDsPerTurn = 4.
- The mutant claims for N1-N3 are consistent with the code: T-PG4, T-R1, T-R2 and T15 follow from EngineEvents.swift:68-79 and design-minimal step 6. None of them was run.

## residual_risks

- The order across subjects of a commit's terminal events becomes the Set's iteration order. Native Set storage is seeded per instance as well as per process (UNCONFIRMED here), so the order can differ between two engines, or between two commits, within one test process, not only between launches. No test today reads two subjects of one commit in order (grep).
- resolveAll's order of resumes changes, and with it the order in which ensure and waiter tails run; each tail re-reads the store or the lifecycle (EngineCommands.swift:753-771). This is timing only, a residual risk under S3-R16 item 2.
- Whether the default actor runs the high-priority heartbeat ahead of 10,000 queued medium-priority tails is UNCONFIRMED. A10 separates the two in the measurement.
- For RR-21, not this design: pruned bindings.
- reconcileIdle at the end of the commit's turn (EngineDispatch.swift:1138, then EnginePresence.swift:81-89) prunes the bindings of ids that are in no job, which includes every owed `.reroutes` item.
- A later drain turn's reroute then finds isBound (EngineDispatch.swift:1164) false where the inline re-route found it true, so an answer from the store (L4-R5) becomes a job.
- Per EnginePresence.swift:48-51 and :57-60, that costs a store read before any transfer. Whether an offline or space gate can answer first is UNCONFIRMED.
- Put it to the RR-21 judge: keep owed items' assets in `wanted`.
- None of the design's per-step figures is measured. All are calibrated against one total (9.86 ms).
- Whether a local `lazy var` compiles under Swift 6 inside an actor method is UNCONFIRMED (C7). The design's fallback is an optional built once in one explicit branch.
- DeadlineHeap removals stay O(H) elsewhere, and pruneBoundContent stays O(B + total job ids) on every reconcileIdle. Both are outside the item, as the design records.
