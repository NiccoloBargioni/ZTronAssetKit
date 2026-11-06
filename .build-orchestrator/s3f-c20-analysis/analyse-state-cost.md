# analyse:state-cost

Read-only analysis for ruling S3-R26 (workflow wf_6b2553de-48c, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## Q1: continueMove takes the id out of Job.assets at the id's first item, before the per-interest guards run (EngineMoves.swift:195, guards at :202-206)

### findings

(a) The state is reachable without a re-created holder. The follow's own inbound move joins a new interest onto the rest's live holder, at once, in an id the rest still owes.

Sweep-first construction (seam followIDsPerTurn = 4; A is named 'zz-z' so it sorts after B1..B7):
1. P (content p) is publishing and holds A for T', a prefetch-lane waiter. C1 maps A to h, and C1's visit passes P.
2. T1, a prefetch group with member A, joins H (content h, downloading). H also holds B1..B7 for T_B and D for T_D.
3. P's publication fails transiently while the barrier is down. P goes to failed(.at), keeps T', and has attemptEnd(deferredAfter: nil).
4. C_v maps A and B1..B7 to x; D stays on h. P's visit runs first (the sorted 'others'), supersedes P and creates X (queued) for T'. H's visit has 8 ids and 3 left in the turn, so it leaves a rest R. R moves B1-B3 and still owes B4-B7 and (A, T1).
5. C_w maps A back to h. Its pass finds X. R moves B4-B7.
6. H's download completes. publish makes H verifying and calls bringInbound(H) (EngineDispatch.swift:1013-1018). The walk under C_w finds X's A, because its `pending` covers inbound moves only, not R's items (EngineFollow.swift:1136-1153). makeInboundNow supersedes X and joins T' onto H for A at once: inFollowVisit and bringingInbound are set (EngineFollow.swift:1208-1209), so EngineJobs.swift:117 does not defer the join, and :156-164 adds it. Now H.interests[T'] = {A}. H's binding then waits, because inboundBlocks names R's holder (EngineFollow.swift:1159-1162).
7. T1's group is released. The release applies at once and drops only T1's interest (EngineCommands.swift:358-371; EngineJobs.swift:346-350).
8. R's last turn takes (A, T1). Line :195 removes A from H.assets, then :202-203 skips T1, which is gone.
Result: H.interests[T'] = {A} while H.assets = {D}.

Variant Y: instead of step 7, C_y maps A to y before step 8. R re-routes the live T1 to y, and T' is left hidden in the same way.

Visit-first: the state never arises. R finishes inside C_v's follow. X's visit at C_w then supersedes X and joins T' and T1 onto H, which re-inserts A (EngineJobs.swift:156). H binds {A, D}.

The draft's argument at docs/adr-drafts/s3f.md:4873-4876 misses these joins. It says that behind the barrier the only interests in a rest's id are its items' tokens.

(b) What the state causes: A is hidden from every reader of Job.assets while T' waits on it.
- H's binding (EngineDispatch.swift:1049) leaves A out. The commit therefore treats T' as unbound and re-routes it after resolveAll (EngineDispatch.swift:1109-1136) to a fresh job of h (EngineJobs.swift:136-154). T' gets the same bytes, later, at the cost of one more job and probably one more request for h. That is the RR-16 family. It is UNCONFIRMED whether a pre-transfer store read would bind A without downloading.
- These other readers miss it too: the visit's moved filter (EngineFollow.swift:907), the supersede counts (EngineFollow.swift:933 and EngineMoves.swift:145), the walk (EngineFollow.swift:1099), recordDeferredVerdict (:514), takeOffMovedBefore (:552), publish's away set (EngineDispatch.swift:1026), withdrawPurged (EngineCommands.swift:1011), the store pre-reads (EnginePresence.swift:208 and :298), removeJob's progress retirement (EngineJobs.swift:443-445) and followedLane (EngineFailures.swift:777). As a result, no later apply moves T' off H.
- A different answer needs one more chain (UNCONFIRMED; I have not built it). H's publication fails transiently. C_z maps A to z, and H's visit moves nothing because A is not in H.assets. H's retry then hits T''s attempt cap, or gets a 404. T' would receive H's failure, or .notFound while A is still listed (resolveAll's F-20 guard works only behind the barrier, EngineJobs.swift:606-611). Visit-first served T' z's bytes.
- Liveness: no hole found. Every exit answers or re-routes by interests: resolveAll (EngineJobs.swift:611-628), supersede (EngineDispatch.swift:1266-1273) and committed (:1109-1126). retire does not need ids.
- Invariant: no clause checks that interest ids ⊆ Job.assets. The nearest clause in invariantViolations (EngineCommands.swift:1752-1756) reads only job.assets. followBarrierViolations (EngineCommands.swift:2003-2069) has no such clause, and no test asserts it.

Related, UNCONFIRMED (possibly a 1(a) break): R re-routes under the copy as it stands at each turn (EngineFollow.swift:832, listing: nil). It keeps doing so after its holder has begun publishing with A outside rerouteOnPass (EngineDispatch.swift:1024-1031). In variant Y, sweep-first moves T1 to y while visit-first passes T1 on the publishing H (EngineFollow.swift:860-865). The two orders agree if H commits, and can differ if H's publication fails.

### evidence

- Sources/ZTronAssetSync/Engine/EngineMoves.swift:187-196: an id leaves Job.assets at its first item (:195), before any guard
- Sources/ZTronAssetSync/Engine/EngineMoves.swift:202-206: the guards skip an interest that is gone (:202-203) or no longer holds the id (:205-206)
- Sources/ZTronAssetSync/Engine/EngineMoves.swift:156-163: a rest's items are the holder's interests when its visit began
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:1203-1229: continueInbound sets inFollowVisit and bringingInbound and makes an owed move with startMove
- Sources/ZTronAssetSync/Engine/EngineJobs.swift:117: bringingInbound skips deferBehindVerdict; :156-164: the join in place adds the interest and re-inserts the id
- Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1013-1018: publish makes the job verifying, then calls bringInbound
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:1099-1109: the walk excludes only the target's own ids; :1136-1153: pending covers inbound moves, not followMoving's items
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:1159-1162 and EngineDispatch.swift:1032-1049: the binding waits for the rest, then binds job.assets
- Sources/ZTronAssetSync/Engine/EngineCommands.swift:358-371: a group release applies at once; EngineJobs.swift:346-350: dropInterest never touches Job.assets
- Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1109-1136: committed re-routes unbound interests after resolveAll; EngineJobs.swift:136-154: the only place a Job is created
- Sources/ZTronAssetSync/Engine/EngineCommands.swift:1752-1756: the only nearby invariant reads job.assets; :2003-2069: followBarrierViolations has no interest-ids ⊆ assets clause
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:832 and :860-865, EngineDispatch.swift:1024-1031: the rest re-routes under the copy at the turn, a visit passes a publishing job, and rerouteOnPass is fixed when the publication starts
- docs/adr-drafts/s3f.md:4873-4876 (the draft's claim) and :4877-4882 (the observation it put to the orchestrator)

### recommendation

(c) Ask the verifier for a probe, and record a residual risk until it runs. Do not take the small reorder.

Why not the reorder: moving :195 below :205, once per id, adds a new branch, 'the first live item of an id removes it'.
- An id whose items are all stale would then stay in Job.assets with no interest on it. That is the common case of a group released in the middle of a rest. Once the rest ends, EngineCommands.swift:1752-1756 trips.
- It does not change variant Y.

Telling these cases apart needs to know whether any interest still holds the id. Two ways:
- Per-id interest counts on Job, kept by setInterest, insertAsset and removeAsset, so :195 removes the id only when its count reaches zero.
- A pending-id set in MoveProgress, plus pushing (id, token) whenever an at-once join targets followMoving?.holder for an owed id.

If stage 2 of the probe gives a different answer, fix it with the counts. Add an invariantViolations clause, 'every interest's ids ⊆ Job.assets', in any case: the barrier suites would then catch this state.

### blocking_under_the_bar

Not blocking as shown. The answer is the same, at the cost of one more job and request: the RR-16 precedent and S3-R16 item 2 (timing and order) cover that. No MUST and no checked invariant breaks, and there is no liveness hole. It becomes a 1(a) break only if stage 2 or stage 3 of the probe gives T' or T1 a different answer than visit-first; stage 2 would also break the code's F-20 rule.

### confidence

High for the construction and for the missing invariant clause (from reading 8e1fb24; UNCONFIRMED by running). Medium for the extra request. Low to medium that stage 2 gives a different answer.

### test_shape

In the style of EngineFollowBarrierMoveRevalidationTests: followIDsPerTurn = 4; runOneFollowTurn and holdPublication (EngineFollowBarrierAnswerTests.swift:48-75); applyHeld (EngineFollowBarrierReachTests.swift:19-32); arguments LaneDropVisit.allCases; ids B1..B7, D and A = 'zz-z'.
Stage 1 (steps 1-8), after R's last turn:
- Sweep-first: H.interests[T'] == {A} and !H.assets.contains(A).
- Visit-first: H.assets contains A and D.
- Both orders: T' gets h's bytes. h's transport starts are predicted at 2 sweep-first and 1 visit-first.
Stage 2: hold H's publication and fail it transiently, apply C_z mapping A to z, and script H's retry to return 404 (or to fail transiently up to T''s cap). Assert T' gets z's bytes in both orders; predicted to fail sweep-first.
Stage 3 (variant Y, T1 live): apply C_y after H's publication starts and before R's turn, then fail H's publication with an integrity error. Assert T1's outcome is the same in both orders.

## Q2 row (draft :4850): deferBehindVerdict's O(E) scan and insert. Highest risk: quadratic in the joins behind one verdict.

### findings

(a) Each call scans eventsAfterFollow from the end until it finds the target's verdict (EngineFollow.swift:965-973). It then inserts the join right behind the verdict, in both eventsAfterFollow and eventStamps (:974-977). All earlier deferred joins sit after the verdict, so every call scans and memmoves all of them. The k-th join behind one verdict costs about k elements; 10,000 joins cost about 50M element visits plus 50M element moves.

Calls per turn: only the follow's visits and visit rests make them. EngineJobs.swift:117 requires inFollowVisit and !bringingInbound. Inbound moves set bringingInbound (EngineFollow.swift:1209). The drain's visit after a verdict calls follow directly, outside inFollowVisit (EngineFollow.swift:586-593). So a turn makes at most followIDsPerTurn = 512 calls (EngineMoves.swift:126; one visit rest), or 256 one-id visits (EngineFollow.swift:11).

How large E gets in the reference set: a later apply that maps 10,000 ids onto a content whose verdict waits puts 10,000 joins behind that verdict. Deferred user joins can add up to 10,000 more.

Element size: EventAfterFollow is not indirect (EngineFollow.swift:1405). Its .join case carries a whole ManifestEntry (EngineFollow.swift:1573-1590; ManifestEntry.swift:49-65; ContentHash.swift:11-17), so a slot is about 170-185 bytes, plus a WorldStamp slot of about 50-60 bytes.

(b) Estimate (UNCONFIRMED): about 3-7 ns per event after the verdict, plus 512 re-routes at about 4.7 µs each (about 2.4 ms).
- A turn passes 10 ms once about 3,000-5,000 joins wait behind the verdict, around turns 6-10 of the 20.
- The last turns run about 20-40 ms each, and the whole follow about 0.2-0.5 s.
- It would be worse if the `let events` copy (:965) were still alive at the insert (:976), since that copies the whole array on every call. This is UNCONFIRMED: Array's eager-move lifetime should end the copy after :974.

It can exceed 10 ms, and no budget bounds the per-call cost. No bench reaches this path at scale. inboundHolder and concentration map the ids to O before the verdict, so those joins go through bringInbound. drainVerdicts and movedBeforeDrain move ids off the waiting job, not onto it.

### evidence

- Sources/ZTronAssetSync/Engine/EngineFollow.swift:964-978: lastIndex scan from the end, then insert at verdict+1 into both arrays
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:960-963: the joins' order behind the verdict is documented as an order only
- Sources/ZTronAssetSync/Engine/EngineJobs.swift:117-124: only a visit (inFollowVisit and not bringingInbound) onto a job whose verdict waits defers behind it
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:820-832 (a visit rest sets inFollowVisit, and bringingInbound only after a verdict), :1208-1209 (inbound moves set bringingInbound), :586-593 (the drain's visit)
- Sources/ZTronAssetSync/Engine/EngineMoves.swift:126 and EngineState.swift:108 (followIDsPerTurn = 512); EngineFollow.swift:11 (followsPerTurn = 256)
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:1405-1432 (enum, not indirect) and :1573-1590 (JoinAfterFollow); Sources/ZTronAssetModel/Manifest/ManifestEntry.swift:49-65
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:188-215: the drain already puts a batch's rest back at the head (:209-215)
- Sources/ZTronAssetSync/Engine/EngineJobs.swift:434: removeJob clears verdictsAfterFollow; EngineFollow.swift:610-611: replayVerdict clears it before giving the verdict
- Readers of .join events: EngineFollow.swift:359, EngineFailures.swift:822-823, EngineCommands.swift:1054-1071 and :2022
- Tests/ZTronAssetKitBenchmarks/BenchSync.swift:3891-3958 (inboundHolder: the mapping comes before the 404) and :3362-3371 (movedBeforeDrain: a second apply through applyAndFollow while the follow is held)

### recommendation

(d) The smallest fix is to make the deferral O(1).
- Keep the joins a visit defers behind a waiting verdict in a side table, appended together with their stamps. Key it by the verdict event's (transfer, epoch), not by the job. removeJob clears verdictsAfterFollow (EngineJobs.swift:434), and the joins must still replay if a release retires the job first.
- When the drain reaches that event, whether it gives the verdict or skips it, splice the joins in right behind it at the head of eventsAfterFollow. The drain already puts a batch's rest back the same way (EngineFollow.swift:209-215). That costs one O(E) insertion per verdict instead of one per join.
- Replay the joins newest first to keep today's order.
- The other readers of .join events must read the table too: replay (:359), followedLane (EngineFailures.swift:822-823), withdrawPurgedJoins (EngineCommands.swift:1054-1071) and followBarrierViolations (EngineCommands.swift:2022).

### blocking_under_the_bar

Not blocking yet, because there is no figure. Under S3-R25 item 3 it becomes blocking once the probe shows a turn over c2Budget at load ≤ 10. That is predicted for the second half of the moves. The requirement at stake is C2 (CLAUDE.md), which falls under 1(b).

### confidence

High that the cost is quadratic and that a turn can make up to 512 calls (by reading). Medium on the millisecond figures: the memmove and scan constants, and whether the copy is made.

### test_shape

New BenchSync case 'deferredJoinTurns', a variant of SyncBench.inboundHolder (BenchSync.swift:3891) with the mapping moved after the verdict.
Setup:
- followBench.
- A prefetch group of followsPerTurn + 44 'ahead' members (ownContents, waiting awaitingSpace) plus 10,000 members sharing H's 16 bytes (one job, downloading, held).
- O, a user request, scripted [.hold, .fail(404)].
Steps:
1. v3 gives only the ahead members fresh contents, with holdFollowFollowUps; the first turn visits 256 of them, so the follow stays owed.
2. Release O and wait for verdictWaits(O). v3 maps nothing to O, so the walk finds nothing.
3. Apply v4 = v3's ahead members + SyncBench.sharing(10_000, oBytes) + [o] with engine.applyAndFollow, as movedBeforeDrain does (BenchSync.swift:3369-3371). H's owed visit now moves its 10,000 ids onto O behind the verdict, 512 per turn.
4. Under SyncBench.longestWait, release the held turns one at a time with releaseOneHeldTurn (each timed inside the actor) until followDrained.
Setup assertions: the verdict waited; 10,000 .join events stand behind O's verdict before the drain; the drain gave the verdict; the content's job then holds the 10,000 ids.
Figure: the longest held turn and the heartbeat, best of three against c2Budget, after a 1,000-member warm-up. Print the per-turn series to show the growth.

## Q2 row (draft :4858): supersede's O(N) re-routes in one turn. Second highest risk: near-certain, about 5× C2.

### findings

(a) supersede (EngineDispatch.swift:1256-1279) re-routes every interest's ids in one turn (:1266-1273). Before that it runs an O(N) holdForManifest scan (:1263-1265) and removeJob, which is O(N) (EngineJobs.swift:443-445).

It has two callers:
- move (EngineFollow.swift:941) is bounded. move runs only when the moved ids fit the turn (EngineMoves.swift:141-142), so at most 512.
- publicationFailed(.superseded) (EngineDispatch.swift:1205-1211) is not bounded: N is all of the publication's ids. The store throws .superseded when no record still wants the bytes after one of its awaits (AssetStore+Publish.swift:31, :68, :114, :130, :194). That happens, for example, when an apply changes every bound id's content while the hash runs.

In the reference set, one publication binds 10,000 ids (10,001 in concentration's shape). There is one call per turn, one per publication failure; E is not involved.

(b) Estimate: with the barrier down the joins are made at once, so 10,001 re-routes at about 4.5-4.9 µs each cost 45-49 ms. The sort of every interest's ids (about 1.5-4 ms), the scan (about 1-2 ms) and removeJob bring the total to about 50-55 ms, about 5× C2. This is the same per-id path as committed's loop over unbound ids (EngineDispatch.swift:1109-1136). concentrationCommitRerouteTurns measures that loop at 48.68 ms best (draft :4856, RR-21, 'miss: blocking, open').

Behind a barrier the joins defer instead (EngineJobs.swift:110-116), at about 1-2 µs each including reroute's own bookkeeping. That gives about 15-25 ms (UNCONFIRMED), still over.

It can exceed 10 ms in both states.

### evidence

- Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1256-1279: supersede (scan :1263-1265, then the re-route loop :1266-1273)
- Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1205-1211: publicationFailed(.superseded) moves the job to queued, then supersedes it with all N ids
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:941 with EngineMoves.swift:141-142: move's call is bounded by the turn's ids
- Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift:31, :68, :114, :130, :194: where the store throws .superseded
- Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1109-1136: committed's re-routes, the same per-id path
- docs/adr-drafts/s3f.md:4856 (RR-21's 48.68 ms) and :4858 (this row)
- Sources/ZTronAssetSync/Engine/EngineJobs.swift:110-116: behind a barrier the re-routed joins defer
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:147 and :824: ending followMoving ends a follow, and a visit rest joins as the follow's own

### recommendation

(d) Fix it inside RR-21's fix. Both loops re-route every interest of a job leaving the table in one turn, so one bounded mechanism should serve committed's unbound re-routes and supersede.

The smallest form:
- Decide holdForManifest once, up front.
- Keep the job queued; publicationFailed already moves it there at :1210.
- Build its (id, token) items as startMove does (EngineMoves.swift:156-163), with the supersedes semantics: the job is removed when its last interest leaves (:218-221).
- Continue the items followIDsPerTurn ids per turn, in owned follow-up turns, behind the barrier, so no admission or event sees a half-moved job.

Do not reuse followMoving as it is, for two reasons:
- Ending it ends a follow: followsEnded += 1 (EngineFollow.swift:147), which rerouteFor reads.
- Its joins are made as the follow's own (inFollowVisit, :824). supersede's joins must still wait behind a barrier that is owed for another reason.

### blocking_under_the_bar

Not blocking yet, because there is no figure. Under S3-R25 item 3 it becomes blocking once the probe shows a turn over c2Budget at load ≤ 10. That is predicted: the path is the same per-id path that RR-21 measured at 48.68 ms and already carries as blocking, open.

### confidence

High: a single call re-routes all N ids through the same per-id path as a measured miss.

### test_shape

Add ConcentrationCommit.superseded (BenchSync.swift:2968-2976) and a test like concentrationCommitRerouteTurns (BenchSync.swift:657-664) that runs concentrationTurns(.publication, commit: .superseded).

In timeCommit (BenchSync.swift:3217) it does what .movedAway does, except that v4 also maps O's own id to D (SyncBench.entry("o", dBytes, policy: .onDemand)). When the window releases O's held store unit, no record wants O's bytes any more. The store throws .superseded at AssetStore+Publish.swift:114, and supersede re-routes all 10,001 interests in one turn. The barrier is down, because the window waits for appliedAndFollowed(v4) first.

Setup assertions: O's job is gone without a commit; D's job holds 10,001 ids (inbound(engine, d).ids); O's waiter is not yet served.

Figure: run.commit (the heartbeat), best of three against c2Budget.

Variant: release the unit while v4's follow is still held (holdFollowFollowUps). This measures the deferred-join form.

## Q2 row (draft :4846): move's sort of each interest's whole ids. Third risk: over C2 when one turn makes several moves off one large holder.

### findings

(a) On every call, move (EngineFollow.swift:931-955) sorts the interests by key (:945) and sorts each interest's whole id set before filtering by moved.contains (:946). The cost is O(I log I + Σ n_i log n_i) for the holder, whatever the number of moved ids m. It runs whenever the moved ids fit the turn (EngineMoves.swift:141-142).

Callers:
- The visits (follow, :902-923).
- The drain's visit after a verdict (:591).
- continueInbound (EngineFollow.swift:1226-1227).

Visits and the drain sort at most about 10,000 ids per turn in total, because each job is visited once.

continueInbound is different: it calls move once for each owed move. One walk records one move per (holder, target) pair (the `others` list, :1096-1126), and the targets are all the publications in flight (:1023-1040). So a 10,000-id holder that gives one id to each of k publishing targets makes k moves in the next follow turn, each one re-sorting all 10,000 ids. Only followsPerTurn = 256 bounds k per turn. In practice k is the number of publications in flight: the pipeline caps only non-user lanes, at pipelineDepth × maxConcurrentTransfers, 8 by default and 32 at 16 slots (SyncTuning.swift:104-110, :140-142; EngineDispatch.swift:25-31). E is not involved.

(b) Estimate per call on a 10,000-id holder (UNCONFIRMED):
- The sort costs about 1.5-4 ms. AssetID's < is a byte-wise lexicographicallyPrecedes (AssetID.swift:75-77). The code's own figure for sorting 10,000 TransferIDs is 3.6 ms (EngineFollow.swift:15-17). publishTerminal's sort of 10,001 ids (EngineJobs.swift:635) fits inside the 9.86 ms commit window.
- The contains pass adds about 0.3-0.5 ms.
- Up to two copy-on-write copies of 10,000-id sets happen while the caller holds a snapshot (EngineFollow.swift:1220, :903).
- Total: about 2-5 ms per call.

k calls in one turn cost about k × 2-5 ms, so a turn passes 10 ms from k ≈ 3-5, and reaches about 30-80 ms at k = 16.

A single visit that moves exactly 512 of 10,000 ids costs about 7-10 ms, which is borderline. For comparison, sharedApplyTurns' 6.82 ms best has the same pass, filter and 512 re-routes, with startMove's heap build where this path has the sort.

It can exceed 10 ms.

### evidence

- Sources/ZTronAssetSync/Engine/EngineFollow.swift:931-955: move; the whole-set sorts at :945-946
- Sources/ZTronAssetSync/Engine/EngineMoves.swift:141-142: move runs whenever the moved ids fit the turn
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:1096-1126: one walk records one move per (holder, target), via the `others` list
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:1023-1040: the targets are every publication in flight; the apply's walk makes no move itself
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:1214-1229: each owed move costs one of 256 holders and its own startMove → move
- Sources/ZTronAssetModel/Identity/AssetID.swift:75-77: a byte-wise comparison; EngineFollow.swift:15-17: 3.6 ms for 10,000 TransferIDs
- Sources/ZTronAssetModel/Policy/SyncTuning.swift:104-110: user work is not gated by the pipeline
- docs/adr-drafts/s3f.md:4846 (the row) and the gate evidence for sharedApplyTurns (6.82 ms best)

### recommendation

(d) The smallest fix is to have move sort only the moved ids.
- Iterate only the interests that hold a moved id: job.interests.filter { !$0.value.assets.isDisjoint(with: moved) }, sorted by key.
- Within each, iterate interest.assets.intersection(moved).sorted(). This assumes the stdlib iterates the smaller set, which is UNCONFIRMED; otherwise iterate moved and test contains.

The order and the decisions stay the same, and a call costs O(I + m log m) instead of O(Σ n log n). For one 10,000-id group holder that is about 0.1-0.3 ms per call instead of 2-5 ms; the copy-on-write copies remain.

For a holder of many single-id interests, a cost of k × O(I) remains, about 0.5 ms per move at I = 10,000. If a probe shows that variant over C2, also coalesce one walk's consecutive moves off one holder in continueInbound (EngineFollow.swift:1214-1240).

takeOffMovedBefore (:558-559) has the same pattern, once per verdict.

### blocking_under_the_bar

Not blocking yet, because there is no figure. Under S3-R25 item 3 it becomes blocking if the multi-target probe shows a turn over c2Budget at load ≤ 10, which is predicted for k ≥ about 4. The single-visit form is borderline.

### confidence

Medium to high on the k-fold re-sort (from reading the walk and continueInbound). Medium on the per-sort milliseconds.

### test_shape

Shape 1, a new case 'inboundTargetsTurns', built from SyncBench.publicationApply (BenchSync.swift:3479) crossed with inboundHolder's H.
Setup:
- SyncTuning(maxConcurrentTransfers: 16, reservedInteractiveSlots: 0).
- 16 user requests O1..O16, 16 distinct bytes each, complete their downloads. Their publications are held at their first store unit: bulk.setHolding(true), waitForHeldUnits(atLeast: 16), and later units released by publicationApply's releaser (:3553).
- A prefetch group of followsPerTurn + 44 'ahead' members (waiting awaitingSpace) plus 10,000 members sharing H's 16 bytes (one job, downloading, held).
Steps:
1. v3 gives the ahead members fresh contents and maps sharing member i (i < 16) to Oi's content, with holdFollowFollowUps so H's visit stays owed.
2. v4 changes the ahead members again via applyAndFollow. Its walk under v3 records 16 moves, all off H (inboundMovesRecorded − before == 16).
3. Release the held turns one at a time (releaseOneHeldTurn); the first makes the 16 moves.
Figure: the longest held turn, best of three, with k = 1 as the control.

Shape 2: SyncBench.sharedApply(.convergence) (BenchSync.swift:3785) with v3 mapping only 512 of the 10,000 sharing members to O's content. H's single visit then fits the turn and runs move. Time it with timedApply.

## Q2 row (draft :4854): recordDeferredVerdict's away filter. Lowest risk.

### findings

(a) recordDeferredVerdict (EngineFollow.swift:508-526) filters the deferring job's ids against the copy once (:514): one lookup plus sameTransfer per id.

Calls per turn: one. It runs once per deferral, from defersFailure (:464) and spaceFailed (EngineFailures.swift:567-573). Each of these runs in the attempt's own end turn, one transfer per call (EngineDispatch.swift:947, :950 and :1230; resolveAll's deferral at EngineJobs.swift:611-614 is per transfer too).

Size: N ≤ 10,000. The shape below builds exactly that: one job of 10,000 ids whose 500 defers with every id moved. E is not involved.

The same turn also:
- walks every job (bringInbound → findInbound, :465 and EngineFollow.swift:1003-1009);
- runs failed's two job.assets.min() scans (EngineFailures.swift:77 and :80).

(b) Estimate (UNCONFIRMED): the filter costs about 1.5-3 ms at 10,000 ids. It is the same expression as the visit's filter (EngineFollow.swift:907), which is part of sharedApplyTurns' 6.82 ms. The walk is measured: inboundWalkTurns' 404 turn over 10,000 jobs is 3.31 ms best, and publicationApply's walk is 2.1 ms median. With it, the deferral turn is about 5-7 ms.

It is not expected to exceed 10 ms. makeInboundNow's moves in the same turn are bounded at 64 holders and 256 ids, but each holder carries the sort cost of the move row (draft :4846).

### evidence

- Sources/ZTronAssetSync/Engine/EngineFollow.swift:508-526: recordDeferredVerdict; the filter at :514
- Sources/ZTronAssetSync/Engine/EngineFollow.swift:449-468: defersFailure, which runs the filter (:464), then deferToFollow and bringInbound (:465-466)
- Sources/ZTronAssetSync/Engine/EngineFailures.swift:558-577: spaceFailed's deferral (:571)
- Sources/ZTronAssetSync/Engine/EngineDispatch.swift:947, :950, :1230: one attempt end per call
- Sources/ZTronAssetSync/Engine/EngineFailures.swift:77 and :80: two O(N) min scans in the same turn
- Tests/ZTronAssetKitBenchmarks/BenchSync.swift:3362-3367: movedBeforeDrain releases J's 500 outside any timed window; :684 asserts movedBefore == 10_000
- docs/adr-drafts/s3f.md:4854 (the row) and the gate evidence (inboundWalkTurns 3.31 ms, publicationApply walk 2.1 ms)

### recommendation

(d) Take a figure; no fix is needed on this estimate. If the figure shows the turn over 10 ms, the cheapest cut is to collect the away ids in the walk this turn already makes. foundInbound looks up every id of every job in the copy, including the deferring job's own ids (EngineFollow.swift:1099-1109), so collecting them there saves one lookup per id.

### blocking_under_the_bar

Not blocking. There is no figure yet, and it is predicted to stay within C2. It would become blocking under S3-R25 item 3 only if the timed window shows best of three over c2Budget at load ≤ 10.

### confidence

Medium to high.

### test_shape

Reuse SyncBench.movedBeforeDrain(members: 10_000) (BenchSync.swift:3278). It already builds the worst case: J's 500 waits with all 10,000 ids moved before it, and run.movedBefore == 10_000 is asserted at BenchSync.swift:684. However, it releases J outside any timed window (BenchSync.swift:3362-3366).

Wrap that release and its verdictWaits loop in their own SyncBench.longestWait(on: engine), as concentration times its ending (BenchSync.swift:3159-3165), and report the result (e.g. run.ending). Judge it best of three against c2Budget in movedBeforeDrainTurns (BenchSync.swift:677). The window covers failed → retryLater → defersFailure → recordDeferredVerdict over 10,000 ids → bringInbound's walk of the 600 fillers and J.
