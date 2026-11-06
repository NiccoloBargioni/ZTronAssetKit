# analyse:g4-reach

Read-only analysis for ruling S3-R26 (workflow wf_6b2553de-48c, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## Q1: waitingTarget's `.queued, .blocked, .downloading` case (Sources/ZTronAssetSync/Engine/EngineFollow.swift:1260-1261, 0 hits), judged against the fixer's 'Open' item 2 (docs/adr-drafts/s3f.md:4934-4956)

### findings

All paths are relative to /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f at 8e1fb24.

(a) TRUE. No path leaves a job downloading at an owed move's epoch.
- A move is recorded only onto a job at an attempt's end:
  - publish's bringInbound, once the job is verifying (EngineDispatch.swift:1013, :1018);
  - defersFailure, after its transition to failed (EngineFollow.swift:456-466);
  - spaceFailed (EngineFailures.swift:573);
  - an apply's walk, for verifying or committing jobs only (EngineFollow.swift:1023-1040).
- The only way into downloading is start (EngineDispatch.swift:693), which bumps the epoch in the same turn (:697-698).
- start's spawn-refusal return (:718-727) would leave the stored job downloading at its old epoch. But start is reached only from dispatch, behind pump's isRunning and barrier guards (:90, :95-108, :363-384), and spawn cannot refuse while the engine runs (EngineLifecycle.swift:51-57).
- Side note: Job.epoch's doc (EngineState.swift:685-686) says supersede and abandon bump the epoch. Only start (EngineDispatch.swift:697) and job creation (EngineJobs.swift:137) do.

(b) TRUE as stated, but the conclusion drawn from it holds only while the barrier stays up.
- blocked is entered only from queued, downloading or blocked (JobState.swift:70-80), and (a) excludes downloading. So blocked at the move's epoch does need queued first.
- The fixer concludes that the park then waits behind the barrier. In the T20 window of (c), the follow and its drain can end during the ENOSPC's free-space read:
  - the drain's pump (EngineFollow.swift:228) dispatches the re-queued job, and the gate can park it at the same epoch (EngineDispatch.swift:366-373);
  - if an apply makes a follow owed again before the read returns, spaceFailed's epoch guard passes (EngineFailures.swift:564) and it defers (:567-572);
  - its bringInbound (:573) checks no state (EngineFollow.swift:1003-1009), so it records moves onto the blocked job;
  - makeInboundNow reads those moves in the same turn (EngineFollow.swift:1176-1185, :1220), which reaches the blocked arm.
- UNCONFIRMED: this interleaving is read from the code, not run.

(c) FALSE. The ENOENT re-queue is not the only path to queued at the move's epoch.
- relane's T20 arm (EngineJobs.swift:285-301) re-queues a failed job without an epoch bump. Its only guard against the follow's own re-lanes is `attemptEnd?.deferredAfter != nil` (:286).
- The window. For a publication's ENOSPC, publicationFailed records the end with deferredAfter nil (EngineDispatch.swift:1203; EngineFollow.swift:489-492), sets failed(.nextRun) (EngineDispatch.swift:1228) and awaits spaceFailed. spaceFailed records the deferral only after its free-space read (EngineFailures.swift:563, then :571).
- Inside the read, refreshFreeSpace runs reconsiderSpaceBlocked (:671-673). Behind the barrier, sweepSpaceParked runs advanceFollowForSpaceSweep (EngineJobs.swift:773-779). That runs continueFollow (EngineFollow.swift:1319), whose continueInbound comes first (:116-117).
- waitingTarget's failed arm returns T (:1258-1259). The move's join goes through reroute to addInterest (EngineDispatch.swift:1188), where bringingInbound skips EngineJobs.swift:117, and re-lanes T (:177). If T's lane is user-initiated (any user waiter on T) and the origin admits users, T20 queues T at the move's epoch (:297-300).
- The move's rest, or any later move onto T, then reads the queued arm. A move larger than the turn's ids keeps a progress (EngineMoves.swift:140-166). The rest is read in spaceFailed's own bringInbound and makeInboundNow (EngineFailures.swift:573), or in the follow's next turn.
- Other triggers in the same window:
  - a visit's join onto T in that turn (addInterest's :117 reads deferredAfter, which is still nil);
  - an interest the follow takes off T while a user interest stays (dropInterest re-lanes, EngineJobs.swift:363);
  - the follow's own follow-up turns, if they run during the read.
- A transfer's ENOSPC (EngineFailures.swift:194-206) has the same window: a visit's join re-queues the job, and spaceFailed's bringInbound then records moves onto the queued job (UNCONFIRMED).
- enqueue's doc (EngineJobs.swift:466-470) lists who gives places. A T20 re-queue made by the follow's own join counts as 'a follow's visit', so the doc does not limit the paths that reach queued at a move's epoch.

(d) What differs between the two orders depends on the window.
- ENOENT window, with x still mapped to T. I agree with the fixer. Only three things differ, all S3-R16 item 2:
  - which job x waits on until H's visit;
  - the order in which x joins T;
  - T's place and ticket (relane's queued arm re-enqueues it at the later join, EngineJobs.swift:270-273).
  Everything that could read the difference is held back:
  - the pump (EngineDispatch.swift:95-108);
  - the sweep's verdicts (EngineJobs.swift:772-780);
  - exit verdicts (EngineFollow.swift:449-469);
  - H's own publication, which binds only once the dropped move is forgotten (EngineFollow.swift:1238-1239, :1265-1269; EngineDispatch.swift:1032-1045).
  No lane decision reads carried(x) in this window. followedLane reads carried() only for ids the current copy maps to the job deciding (EngineFailures.swift:777, :785, :801). Here that job is T, which is queued and so cannot receive a 429.
- ENOENT window with a later apply C2 that maps x to U while T still publishes. The walk records the move under the outgoing copy (EngineFollow.swift:1011-1022).
  - Visit-first: C2's visit passed x, and x rides T's re-queued attempt, the rule EngineFollowBarrierPublicationTests.swift:312-358 pins for a space retry. It stays there until T's commit re-routes it (EngineDispatch.swift:1120-1124) or T's failure answers it.
  - With the drop: H's visit moves x under C2 onto U (EngineFollow.swift:902-923; rerouteOnVisit returns nil for a non-publishing holder, :874-875).
  - If T's fresh attempt fails terminally, x gets a different answer. This is a 1(a) candidate, UNCONFIRMED. S3-R17 may make the barrier's answer acceptable if a MUST says x follows its current entry.
  - A 429 on U here does read carried(x), which is the lane decision S3-R25 item 7 asks for. But T's rule (queued, rerouteOnVisit nil) and a non-publishing H's rule both say 'moves' (EngineFailures.swift:736, :741-743). So the lane is the same with the case and with the fold.
- T20 window.
  - The arm itself makes only the same order and place difference.
  - The window carries a separate 1(a)/1(b) candidate that the arm does not cause. T20 skips the ENOSPC verdict, because decideSpaceFailure returns for a queued job (EngineFailures.swift:586-589). The attempt is not counted (countFailedAttempt in retryLater at :254, and in awaitReclaim at :600), and no park or fail-fast answer is given (:606-609).
  - Visit-first's join met T while it was publishing; relane's verifying arm does nothing (EngineJobs.swift:309-310), so the verdict stood. With an interest at its attempt cap, visit-first answers it with the ENOSPC figures, while the barrier starts one more attempt. That would be a different answer and a request past the R-SYN-5 cap. UNCONFIRMED.
  - relane's comment (EngineJobs.swift:286-295) says cycle 17 meant to stop this skip. But the guard reads deferredAfter, which spaceFailed sets only after the read.
  - The existing ENOSPC test (EngineFollowBarrierPublicationTests.swift:312-358) moves an id off C and passes C, so it does not exercise T20.

(e) A deterministic test is feasible with the existing fakes and seams; the shapes are in test_shape.
- The ENOENT shape needs a drained publication. FakeTransport's cancel ends the stream at once (Sources/ZTronAssetTestSupport/RecordingFakes.swift:209-212). So the staged terminal must already be held by holdAttemptTerminals (EngineDispatch.swift:846-856, :878) when the attempt is retired. Then:
  - finishAttempt routes it to drained (:916-920);
  - drained adopts it (:984-989);
  - the next start publishes it with cancelledAttempt true (:715-721, :993-996).
- The T20 shape reuses the ENOSPC rename fault and the seams as they are.
- In both shapes the window exists only in sweepFollowsFirst. In followVisitedFirst the move is made while T verifies, so that order reaches nothing and serves as the answer reference.

(f) If the case were folded into `return job`:
- continueInbound would make moves onto a target that is past its attempt's end, under the move's copy and before any visit:
  - onto a queued T, where each join re-enqueues T (EngineJobs.swift:270-273);
  - onto a blocked T, where a lane raise can clear the park (EngineJobs.swift:303-307). That is a park decision made behind the barrier.
- followedLane would count carried ids by T's rule. For a queued or blocked T that rule says 'moves', as a non-publishing holder's does. So lanes change only where the holder's rule passes x.
- Closer to visit-first only in part:
  - In the simple ENOENT window, yes, for order and place: x joins T before the visits, where visit-first already had it. Neither version changes an answer.
  - In the C2 variant, x would join T under the stale copy, and noteJoin would mark T unfollowed (EngineJobs.swift:190-195). Whether this follow's visits then move x on to U depends on the visit order (UNCONFIRMED).
  - In the T20 window it does nothing for the skipped verdict.
- The docs that state the drop would contradict it (EngineFollow.swift:1196-1199, :1248-1250; EngineFailures.swift:751-757).
- So folding is not uniformly closer to visit-first. And because the case is reachable, a fold would be a behaviour change, not 'Removed' under S3-R24 item 3.

### evidence

- Sources/ZTronAssetSync/Engine/EngineFollow.swift:1251-1263: waitingTarget. :1258-1259 returns a failed job whose attemptEnd is set; :1260-1261 is the case under ruling.
- EngineFollow.swift:1220 and EngineFailures.swift:763: the only two readers of waitingTarget (continueInbound and followedLane's carried()).
- EngineFollow.swift:1003-1009: bringInbound guards only followOwed and that the job exists, with no state check, and records at the job's current epoch.
- EngineFollow.swift:1023-1040: bringInboundOntoPublications, verifying or committing targets only. :1011-1022: its doc (records under the outgoing copy).
- EngineDispatch.swift:1013 and :1018: verifying, then bringInbound. :1029-1030: rerouteOnPass. :1032-1045: binding waits for owed moves. :1058: store.publish. :1061: publicationFailed.
- EngineFollow.swift:449-469: defersFailure transitions to failed (:456-459) before recordDeferredVerdict, deferToFollow and bringInbound (:463-466).
- EngineDispatch.swift:693, :697-698, :718-727, :733-734: start (transition, epoch bump, spawn-refusal return, attemptEnd reset). :90, :95-108, :363-384: pump's guards; dispatch is start's only caller.
- Sources/ZTronAssetSync/Engine/EngineLifecycle.swift:51-57: spawn refuses only in shuttingDown, shutDown and degraded.
- Sources/ZTronAssetSync/Engine/JobState.swift:70-80: blocked is entered only from queued, downloading or blocked.
- EngineDispatch.swift:1203: recordPublicationEnd. :1217-1226: the ENOENT re-queue where cancelledAttempt, with no epoch bump. :1227-1230: ENOSPC sets failed(.nextRun), then awaits spaceFailed.
- EngineFollow.swift:489-492: recordPublicationEnd sets AttemptEnd(failedAfter:, deferredAfter: nil).
- EngineFailures.swift:558-577: spaceFailed. :563 awaits refreshFreeSpace; :564 is the epoch guard; the deferral is recorded only after the read (:567-572); :573 is bringInbound.
- EngineFailures.swift:664-674: refreshFreeSpace runs reconsiderSpaceBlocked in the read's turn (:671-673).
- Sources/ZTronAssetSync/Engine/EngineJobs.swift:772-780: behind the barrier, sweepSpaceParked defers the sweep and runs advanceFollowForSpaceSweep (:777).
- EngineFollow.swift:1314-1326: advanceFollowForSpaceSweep calls continueFollow (:1319). :114-160: continueFollow makes the owed moves first (:116-117).
- EngineFollow.swift:1176-1185: makeInboundNow runs continueInbound in the attempt end's own turn.
- Sources/ZTronAssetSync/Engine/EngineMoves.swift:140-166 and :179-226: startMove keeps a progress when a move is larger than the budget; continueMove re-routes each interest.
- EngineDispatch.swift:1147-1189: reroute ends in addInterest (:1188).
- EngineJobs.swift:110: no deferral inside a follow visit. :117: deferBehindVerdict only when deferredAfter != nil and the join is not bringingInbound. :177: relane. :363: dropInterest re-lanes.
- EngineJobs.swift:263-312: relane. :270-273: queued arm re-enqueues. :285-301: failed arm, with the deferredAfter guard at :286 and the T20 re-queue at :297-300 (no epoch bump). :303-307: blocked arm can clear a park. :309-310: verifying and committing do nothing.
- EngineFailures.swift:580-611: decideSpaceFailure returns for a non-failed job (:586-589, the T20 comment). The attempt is counted at :600 and in retryLater at :254 (EngineFailures.swift:244-268). The park is at :606-609.
- EngineJobs.swift:466-470: enqueue's doc. Places are given by a follow's visit or the drain's replay, and only the ENOENT re-queue gives one at once.
- EngineFailures.swift:721-818: followedLane. rule(of:) :733-740 (visit is rerouteOnVisit); moves :741-750; carried :759-764; movesViaTarget :767-775. carried() is read only for ids mapped to the deciding job (:777, :785, :801).
- EngineFollow.swift:860-877: rerouteOnVisit returns nil (moves) for queued, blocked and downloading (:874-875). :902-923: follow (a holder's visit moves its ids under the current copy).
- EngineDispatch.swift:846-856 and :878-890: the attempt-terminal hold seam. :916-920: finishAttempt routes a draining attempt to drained. :970-990: drained adopts. :715-721: an adopted file is published through publishDrained (:993-996, cancelledAttempt true).
- Sources/ZTronAssetTestSupport/RecordingFakes.swift:209-212: the fake channel's cancel ends the stream with .failed(.cancelled(.byClient)). FakeFileSystem.swift:126-149: FaultRule takes any FileSystemError, .notFound included.
- Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierLegacyTargetTests.swift:24-89: a later apply's walk records an owed move onto a publishing T, asserted from inboundMoves at :68-74.
- Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierPublicationTests.swift:312-358: the ENOSPC rename fault (:330), holdSpaceSweepFollowUps (:333) and the .spaceFailure wait (:337). Its moved id leaves C; no join onto C happens in the read.
- Tests/ZTronAssetSyncTests/Engine/EngineRaceTests.swift:82-122: a drained-publication ENOENT built with RacingSource (:10-76).
- Sources/ZTronAssetSync/Engine/EngineState.swift:106-108: the followIDsPerTurn seam. :685-686: Job.epoch's doc, which is stale.
- docs/adr-drafts/s3f.md:4934-4956: the fixer's Open item 2. Its single-path claim for queued is at :4942-4949.
- /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-rulings-s3f.md: S3-R16 at :146-170, S3-R24 item 3 at :317-325, S3-R25 item 7 at :372-377.

### recommendation

1. Correct the draft's (c), and qualify its (b): the case is reachable through the ENOENT window and through T20 inside an ENOSPC's free-space read.
2. 'Reached' is the only way to close the case.
   - 'Removed' needs an unreachable assumption to turn into a clause, and this case is reachable.
   - 'Equivalent' needs no change of state, and the case changes where an id waits, the join order and T's ticket.
3. Commit Shape A (or Shape B, if A's drained publication does not compose with the walk).
   - Run it in both LaneDropVisit orders, with visit-first's answers asserted in both.
   - Kill the fold mutant 2/2 with the sweep-first state assertion.
4. State in S3-R26 that the window exists only in sweepFollowsFirst. 'Reached in both orders' then means the test runs in both orders and reaches the line in sweepFollowsFirst.
5. Tell the fixer about the carried() lane decision that S3-R25 item 7 asks for. It is reachable only in the C2 variant, and by this reading it gives the same lane under the mutant. It may be asserted, but it cannot be the kill.
6. Probe two candidates separately, before ruling on them (S3-R19 item 1).
   - (i) The T20 verdict skip. Run Shape B in both orders, with an interest at its cap (interactiveRetry.maxAttemptsPerRun = 1) or with a pending reclaim. If it is confirmed, it is blocking under 1(a)/(b). Its fix belongs in relane's failed arm, not in waitingTarget: for example, no T20 re-queue while attemptEnd is set and the barrier is up, as for a deferred verdict.
   - (ii) The C2 variant, with T's fresh attempt failing terminally. Rule it under S3-R17 if the barrier gives the SPEC's answer.
7. Fix three docs: enqueue's (EngineJobs.swift:466-470), the draft's single-path claim (s3f.md:4942-4949), and Job.epoch's (EngineState.swift:685-686).

### blocking_under_the_bar

Blocking, under S3-R16 1(e) via S3-R24 item 3: 0 hits, and not Reached, Removed or Equivalent. S3-R25 item 7 applies. Ruling the order-and-ticket difference a residual risk (S3-R16 item 2) covers the difference the arm makes. It does not cover G4 for code that stays, which 1(e) makes blocking on its own. The T20 verdict skip and the C2 answer difference are separate candidates under 1(a)/(b); each is blocking only once a probe in both orders shows it (S3-R19 item 1).

### confidence

High for (a), and for the mechanism in (c): every step is cited from the code. Medium for (b)'s blocked path and for the shapes' feasibility. Two details are UNCONFIRMED: that a drained publication composes with the walk, and that a .notFound rename fault surfaces as StoreError.fileSystem(.notFound). Low to medium for the two candidate answer differences, which stay UNCONFIRMED until probed. Nothing was built or run.

### test_shape

Shape A: the ENOENT window, S3-R25 item 7's first choice.
1. Set up with setUpHeldPublications (EngineFollowBarrierAnswerTests.swift:19-77): a checksummed T, and H downloading (held) with id x.
2. Hold attempt terminals and let T's .stage arrive. Cancel T's only waiter, so the job is removed and its attempt drains.
3. Add a user waiter A on T's content. It waits queued, as at EngineRaceTests.swift:96-100.
4. Arm holdPublication, then release the terminals. drained adopts the file, and the next start publishes it with cancelledAttempt true, held at its first store unit.
5. Sweep-first, with follow-ups held, apply v3, which maps x to T's content (H's visit is now owed). Then apply v3b, which changes only fillers. Its walk records M(H -> T, [x]) under v3. Assert it from inboundMoves, as EngineFollowBarrierLegacyTargetTests.swift:68-74 does.
6. Add FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .notFound), or use the unwritten partial of EngineRaceTests.swift:102-104. Release T's publication and await T queued.
7. #require that T.epoch == M.epoch and M is still owed.
8. Release one follow turn and hold the next. #expect that x is still on H and not on T, and that inboundOnto[T] == nil.
9. Release the rest. #expect visit-first's answers in both orders (A's and x's waiters get T's bytes), T's starts as in visit-first, and invariantViolations() empty.

Shape B: the T20 window, cheaper.
1. Start from barrierLeavesAPassedIdToAPublicationsSpaceRetry (EngineFollowBarrierPublicationTests.swift:312-358): T publishing (held), with a user waiter.
2. Add H downloading with x and y. v3 maps both to T's content, and v3b's walk records M(H -> T, [x, y]).
3. Set followIDsPerTurn = 1 (EngineState.swift:106-108, as EngineFollowBarrierStaleRerouteTests.swift:93). Keep the follow-ups held.
4. Add the rename .noSpace fault (:330) and holdSpaceSweepFollowUps (:333). Release T's publication.
5. The read's sweep turn moves x, and T20 queues T at M's epoch. y stays as M's rest, and spaceFailed's bringInbound and makeInboundNow read the queued arm.
6. Once .spaceFailure waits (:337), #expect T queued at M's epoch, y on H and not on T, and no owed move onto T.
7. Release, and #expect visit-first's answers in both orders.
8. Rerun with interactiveRetry.maxAttemptsPerRun = 1. That run is the probe for the T20 verdict skip.

Drop-mutant, for either shape: `case .queued, .blocked, .downloading: return job` (or `.queued` moved into the first arm). The mutant makes the move, or its rest, onto the queued T. The id is then on T and not on H at step 8 of Shape A or step 6 of Shape B, so that assertion fails on every run. Every step is gated by a seam, with no timing.

## Q2: scheduleDrainFollowUp's `spawned == nil` branch (Sources/ZTronAssetSync/Engine/EngineFollow.swift:390-398; 0 hits, against 21 on its `if`)

### findings

All paths are relative to /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f at 8e1fb24.

Callers, and whether each can run after shutdown has begun or while degraded:
- scheduleDrainFollowUp has one caller: drainEventsAfterFollow, at EngineFollow.swift:224. That function is synchronous (:188-230), so no lifecycle change can land inside it. It reaches :224 only when no follow is owed (:189) and a turn leaves events (:223).
- drainEventsAfterFollow has three callers.
  1. continueFollow (:158). It is called from three places:
     - followApplied (:77). Every follow start re-reads isRunning after its last await: EngineCatchUp.swift:48-49 (`where isRunning`, then applied, then EngineRuns.swift:393), EngineCatchUp.swift:181/:184, EngineCommands.swift:77/:81 and :283/:287, and EngineManifest.swift:393-396. None can run after shutdown has begun or while degraded.
     - followFollowUp (:1362). It guards !isShuttingDown and followOwed (:1359). As a task spawned before shutdown it can run after shutdown has begun, but it returns at that guard. A degraded engine never has a follow owed; bf1d4eb's clause (EngineCommands.swift:2011-2013) checks this.
     - advanceFollowForSpaceSweep (:1319); see caller 3.
  2. drainFollowUp (:414). It can run after shutdown has begun, but it clears the flag (:410) and then returns at `guard isRunning` (:411).
  3. advanceFollowForSpaceSweep (:1316). It is reached only from sweepSpaceParked behind the barrier (EngineJobs.swift:773-777). Every sweep entry re-reads isRunning after its await: EngineFailures.swift:671, EngineJobs.swift:991, EngineCommands.swift:677, EngineRuns.swift:179, and EngineTimers.swift:182, :389 and :406. EngineRuns.swift:646 is synchronous, inside run settlement.

No path makes spawn refuse here:
- spawn refuses only in shuttingDown, shutDown and degraded (EngineLifecycle.swift:51-57).
- degraded is written only during start (:228 and :260), and each write is followed by a return before running is set (:313). A degraded engine never runs, follows or defers.
- shutdown writes shuttingDown (:490), then notifies observers and cancels tasks (:491-495). It evaluates drainEverything as settle's argument (:498) in the same synchronous stretch.
- drainEverything clears the follow (EngineShutdown.swift:113-117) and every event index (:118-124). From then on the barrier is down, so no deferral can add an event (EngineJobs.swift:110), and :189 returns at once.
- The tasks joined afterwards (EngineLifecycle.swift:500-506) re-read the lifecycle, as listed above.
- So :392-398 is unreachable. This is bf1d4eb's argument for scheduleFollowFollowUp (EngineFollow.swift:1328-1334), applied to the drain.

Resets the branch makes, and who else makes each at shutdown:
1. drainFollowUpScheduled = false (:392). drainEverything does not make this reset. drainFollowUp makes it itself (:410) when the scheduled task runs, because shutdown joins every owned task (EngineLifecycle.swift:500-506). The exception is the test seam's held return (:404-408), which leaves the flag true. A stale true is inert: its only readers are :380 (unreachable after shutdown), :410, and the running-only clause at EngineCommands.swift:2006.
2. eventsAfterFollow = [] (:393): EngineShutdown.swift:118.
3. eventStamps = [] (:394): :119.
4. verdictsAfterFollow = [:] (:395): :123.
5. joinsAfterFollow = [:] (:396): :124.
6. worldHistory = [] (:397): :121.
7. followStamps = [:] (:398): :122.

That is six data resets plus the flag. S3-R25 item 7's 'five state resets' counted the scheduleFollowFollowUp branch that bf1d4eb removed. The draft's argument here should cover all seven.

drainEverything also clears what the branch leaves: reading (:120), followCarried (:125) and drainingAfterFollow (:126). It also answers every waiter (EngineLifecycle.swift:498). The branch drops .join events without answering their waiters, so if it ever ran on its own it would strand them; that is one more reason not to keep it as a fallback. Neither of them resets drainIDsLeft, which is inert because it is reassigned at :203 before every use. Neither releases the drain or follow follow-up seams (EngineShutdown.swift:85-91 releases other seams).

### evidence

- Sources/ZTronAssetSync/Engine/EngineFollow.swift:379-400: scheduleDrainFollowUp. :390 is `if spawned == nil`; :392-398 are the seven assignments.
- EngineFollow.swift:188-230: drainEventsAfterFollow (synchronous). :189 is its guard; :223-226 contain the only call of scheduleDrainFollowUp (:224).
- EngineFollow.swift:158, :414, :1316: every caller of drainEventsAfterFollow. :77, :1319, :1362: every caller of continueFollow.
- EngineFollow.swift:403-418: drainFollowUp. Seam return at :404-408 (the flag is kept); flag reset at :410; isRunning guard at :411.
- EngineFollow.swift:1351-1366: followFollowUp, guarded by !isShuttingDown and followOwed (:1359).
- EngineCatchUp.swift:48-49 (applied, then EngineRuns.swift:393); EngineCatchUp.swift:181, :184 and :207-231 (followStoreView, then followApplied at :229); EngineCommands.swift:77, :81, :283, :287; EngineManifest.swift:393-396. Each re-reads isRunning after its last await.
- EngineFailures.swift:671-673; EngineJobs.swift:991; EngineCommands.swift:676-678; EngineRuns.swift:178-180; EngineTimers.swift:181-186, :387-392, :405-409. Every space-sweep entry re-reads isRunning after its read. EngineJobs.swift:773-777: sweepSpaceParked reaches the follow only behind the barrier.
- Sources/ZTronAssetSync/Engine/EngineLifecycle.swift:50-57: spawn is @discardableResult and refuses only in shuttingDown, shutDown and degraded.
- EngineLifecycle.swift:155, :228, :260, :313, :490, :534: the only lifecycle writes. :226-231 and :257-264 degrade and then return before :313.
- EngineLifecycle.swift:490-498: shuttingDown, notifyObservers, task cancels, cancelRunningHandles, then drainEverything as settle's argument, all in one synchronous stretch. :500-506: joins every owned task and drains again.
- Sources/ZTronAssetSync/Engine/EngineShutdown.swift:113-126: drainEverything clears followOrder, followNext and followScans, calls releaseInboundWaits, and clears eventsAfterFollow :118, eventStamps :119, reading :120, worldHistory :121, followStamps :122, verdictsAfterFollow :123, joinsAfterFollow :124, followCarried :125 and drainingAfterFollow :126. It does not reset drainFollowUpScheduled. :85-91 releases other seams.
- Sources/ZTronAssetSync/Engine/EngineState.swift:167-174: drainIDsLeft, drainFollowUpScheduled, drainFollowUpsHeld and drainFollowUpWaiting. The only readers of drainFollowUpScheduled are EngineFollow.swift:380 and :410 and EngineCommands.swift:2006.
- EngineJobs.swift:110: a deferral needs defersToFollow (the barrier up), so no event can be added after drainEverything.
- Sources/ZTronAssetSync/Engine/EngineCommands.swift:2003-2069: followBarrierViolations. :2006 is the running-only drain clause; :2011-2013 is bf1d4eb's clause; :2027-2028 lists the events that need no index; :2034-2036 is the stamps clause. :1959: invariantViolations includes these.
- EngineCommands.swift:1665-1676 and :1679-1692: notifyConditions evaluates test conditions synchronously at EngineLifecycle.swift:491, before the drain at :498.
- Tests/ZTronAssetSyncTests/Engine/EngineFollowShutdownTests.swift:20-66: bf1d4eb's test. :62-64 forces followOrder and expects exactly one violation.
- Tests/ZTronAssetSyncTests/Engine/EngineOutcomeTests.swift:492-498: the violations(after:) helper, which restores the state.
- EngineFollow.swift:1328-1348: scheduleFollowFollowUp's doc carries bf1d4eb's removal argument. `git show bf1d4eb`: the removed branch reset six fields and called releaseInboundWaits.
- EngineFollow.swift:1387-1399: holdDrainFollowUps and releaseDrainFollowUps.
- /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-rulings-s3f.md:374-377: S3-R25 item 7's rule for the unspawnable branch.

### recommendation

Remove the branch, as bf1d4eb did for scheduleFollowFollowUp (S3-R24 item 3 'Removed', S3-R19 item 3).
1. Code. Call `self.spawn(.entry) { ... }` and drop its result (spawn is @discardableResult, EngineLifecycle.swift:50). Delete :390-398. Put the argument above in the doc and in the draft.
2. Clause. Add it to followBarrierViolations, next to :2006 and :2011-2013:
   `if !self.isRunning, !events.isEmpty { violations.append("\(events.count) events wait for a follow while the engine is \(self.state.lifecycle)") }`
   - The assumption it checks: events wait only while the engine runs. Together with :2006, they wait only while a follow is owed, a drain is scheduled or one runs. So a drain turn that leaves events always runs on a running engine, and its follow-up is always spawned.
   - Keep it separate from bf1d4eb's clause. EngineFollowShutdownTests.swift:63-64 expects an exact list, and G3 requires that expectation to stay unchanged.
3. Test. Add the clause test in test_shape.
4. Caveat. Between EngineLifecycle.swift:490 and :498, a condition evaluated by notifyObservers (:491; EngineCommands.swift:1665-1676) sees !isRunning while events still wait. Any condition that calls invariantViolations() there would see the new message for that instant. I found no condition that asserts it there, and readForTests cannot interleave inside that stretch.
5. Draft. Record all seven assignments, who else makes each, and the fact that the branch would have stranded waiters.

### blocking_under_the_bar

Blocking while it stays unreached (0 hits): S3-R16 1(e) via S3-R24 item 3, with S3-R25 item 7 applying. Removing it with the clause and that clause's test meets 'Removed'. Removal adds no liveness risk (1(c)): no path reaches the branch, and drainEverything already makes its data resets and answers every waiter.

### confidence

High. The lifecycle writes, spawn's refusal set, the synchronous drain turn and shutdown's same-turn drain are all confirmed by reading. Nothing was built or run.

### test_shape

Clause test, in EngineFollowShutdownTests.swift after `await shutdown.value`, next to :62-64.
1. `let forced = await engine.violations { $0.eventsAfterFollow = [.throttleAnswers]; $0.eventStamps = [<a stamp with view 0>]; $0.worldHistory = [<one view>] }` (the helper at EngineOutcomeTests.swift:492-498, which restores the state).
2. `#expect(forced == ["1 events wait for a follow while the engine is shutDown"])`.
3. .throttleAnswers needs no join or verdict index (EngineCommands.swift:2027-2028), and the stamp and view keep the stamps clause at :2034-2036 quiet. UNCONFIRMED: their initialisers. If they are awkward, filter the result to the new message and expect exactly one.
4. Control: on the running engine with a drain scheduled, the message is absent.
5. Kill: the clause's drop-mutant leaves `forced` without the message, so the test fails.

Optional liveness test, in S3-R25 item 7's shape, with bounded checks and no time limit.
1. Make a drain turn leave events: set followIDsPerTurn small (as EngineFollowBarrierDrainBoundTests.swift:79), or wait more than eventsAfterFollowPerTurn.
2. Call holdDrainFollowUps (EngineFollow.swift:1387-1389), then begin shutdown.
3. #expect every waiter answered .shutDown, `await shutdown.value` returning, and invariantViolations() empty.
4. Call releaseDrainFollowUps() after shutdown. #expect it to return at the isRunning guard (:1392-1399 -> :410-413), with eventsAfterFollow empty.
