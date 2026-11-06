# critic:move-index

Read-only analysis for ruling S3-R26 (workflow wf_bc7908d4-1ad, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## verdict

sound with amendments

## refutations

- R1. The C2 argument starts from a stale figure. It says the commit window (concentrationPublicationTurns) is 9.86 ms best, a 0.14 ms margin. On the same HEAD 8e1fb24 the cycle-20 correctness verifier measured [10.18, 10.23, 10.16] ms, best 10.16, at a 1-minute load of 3.14 (/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/correct/logs/bench-rerun.log). In the full run it measured [14.65, 10.21, 10.45] (/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/correct/logs/bench.log). This is s3f-c20-issues.json correct #5, which is blocking; only reqs #10 saw 9.82 ms. So the case is already over c2Budget. The eager index then adds a 10,001-entry free to that same turn: resolveAll keeps its `job` copy alive through removeAllInterests, removeJob and publishTerminal (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineJobs.swift:615-627). 'Measure that case first' cannot pass on its own. The interactions' 'land the index first' contradicts the design's own merge gate.
- R2. 'No interest holds them, so no answer reads them' (answer_equality_argument, about unheld moved ids) is wrong as stated. On the bounded path these ids are still read today by the supersede counts (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineFollow.swift:933, EngineMoves.swift:145), publish's binding `job.assets.sorted()` (EngineDispatch.swift:1049), the breaker and record asset `job.assets.min()` (EngineFailures.swift:77, :80), the 404's persisted failure ids through sparePresent (EngineFailures.swift:145), integrityFailed's ids (EngineFailures.swift:193; EngineDispatch.swift:1216), pruneBoundContent's wanted set (EnginePresence.swift:87), onProgress's progress key (EngineDispatch.swift:905) and removeJob's retireProgress loop (EngineJobs.swift:443-445). Each of these moves toward the fit path, which already drops the ids at EngineFollow.swift:944. So the change is an alignment (S3-R16 item 2), not a no-op. One more consequence: before the change, the bounded path can differ from the fit path depending on the remaining turn budget, so it can differ between orders too; the change removes that. Through the binding and the 404 record, 8e1fb24 may also offer an unheld moved id to the holder's old-content publication, or persist a failure for it (UNCONFIRMED). The change closes that as well.
- R3. NB11/T2 pins the order through `source.starts`, with at least 8 attempts in flight. That is the observation S3-R25 item 4's sweep removed from ZTronAssetSyncTests, because the fake transport's `.started` records race once more than one attempt runs. As designed, T2 is a new flake (S3-R16 1(d)).
- R4. IDTokens `==` as specified is not symmetric: `lhs.count == rhs.count && rhs.contains(lhs.first) && lhs.others.allSatisfy(rhs.contains)`. Take lhs = {first a, others {a}} and rhs = {first a, others {b}}. Then lhs == rhs is true but rhs == lhs is false. That breaks Equatable, and I1 then checks the index against the recount in one direction only. The design also does not say how Job.recountTokens is built. If it is built through IDTokens.init/add, NB1's mutant (`others.insert(first)`) corrupts both sides alike. The NB1 kill claim ('the unit recount fails 2/2, and every engine test's invariantViolations() fails') is then false. What kills it instead is the unit test's direct count steps. In the engine, only the stale entry left after a per-id release catches it (remove(first) pops `first` itself and keeps the entry). removeAllInterests clears the index wholesale, so a job that simply commits leaves no stale entry to find.
- R5. NB9, the re-insertion, is killed in sweep-first only. S3-R24 item 3's 'Reached' requires both LaneDropVisit orders, and S3-R25 item 8 says 'in both orders' for continueMove's own lines. No existing shape reaches the true arm visit-first. In MoveRevalidation's mappedBack shape, the visit-first run lands v4 only after the follow ended (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierMoveRevalidationTests.swift:118-119 and :148-149), so no holder is mid-rest. The only kill is T5, the analysis' Q1 steps 1-8, which nobody has built (UNCONFIRMED). The design does not say what happens if T5 cannot be built.
- R6. The MANY-MOVES pin uses k = 1, 16 and 64, which misses the per-turn maximum. A follow turn runs continueInbound with FollowBudget(holders: followsPerTurn = 256, ids: 512) (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineFollow.swift:11, :116, :1214-1218). So one turn can make 256 owed one-id moves off H. The probe's own doc says 'a follow turn of up to followsPerTurn moves' (/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/correct/VerifyC20CorrectProbes.swift:307-311). 64 is only the apply turn's limit (inboundMovesNow, EngineFollow.swift:1172, :1180). The design's own 10-30 µs per move on a base of about 3.5 ms gives about 6-11 ms at k = 256. So S3-R25 item 1's 'every grouping' is not pinned.
- R7. Removing setAssets takes an operation away from a passing pre-existing test: EngineInterestCountsTests.swift:81-83, the 'prefetch's ids replaced' step (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Tests/ZTronAssetSyncTests/Engine/EngineInterestCountsTests.swift). The 'same ids' claim is true, because the interest is empty after :78. But S3-R16's 'What stands' says no test that passes today loses an operation, except as item 4 allows, and item 4 covers only order, place and timing assertions. So 'record the edit in the draft' does not authorise the change.
- R8. Step 7's helper is described as reading the job, calling rerouteOnVisit and the moved filter, and returning both sets. That description leaves out follow's one state write: `self.state.unfollowed.insert(transfer)` when a publishing job's passed set is non-empty (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineFollow.swift:908-914). Built as described, a passed job would never be visited again.
- R9 (minor). The C2 table's figures are stale. It gives throttleExtension at 7.20 ms; the cycle-20 gate runs measured 8.12-8.13 ms best. It gives handleRelease at 4.1-4.8 ms; the runs measured 5.27-5.67 ms (/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/reqs/logs/gates/bench.log:192 and correct/logs/bench.log). The margins still hold.
- R10. T3, NB3's engine kill, does not control which token is `first`. `first` is the token that indexed the id first (step 2's default subscript), not a Set-order choice. So 'the waiter released first' reaches IDTokens.remove's promote arm only if the waiter joined before the group. Otherwise the release takes the `others` arm, and NB3 gets no engine kill.

## amendments

- A1 (C2, blocking, commit window): this item must not land ahead of whatever fixes s3f-c20 correct #5.
- Either sequence it after or together with that fix, for example one that bounds or removes publishTerminal's 10,001-id sort at /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineJobs.swift:635.
- Or take contingency (ii) as the primary design: build the index lazily at a job's first move off it. Then a move target such as O never frees an index in resolveAll (EngineJobs.swift:623-627).
- Either way, the merge gate is concentrationPublicationTurns, best of 3 ≤ c2Budget at a 1-minute load ≤ 10, measured with the index in place. Drop 'land the index first' from the interactions.
- A2 (C2): add k = 256 (followsPerTurn, /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineFollow.swift:11) to BenchSync.manyMovesTurns, keeping k = 1, 16 and 64.
- The setup expects one held follow turn that makes 256 owed one-id moves off H (count the moves per turn as T6 does).
- Pass bar: best of 3 ≤ c2Budget at load ≤ 10.
- If 256 misses, cap or coalesce the owed moves off one holder per turn. Each such cap is a new bound, with both of S3-R23 item 3's pins.
- A3 (G4/flake): T2 must not read `source.starts`.
- Assert the re-route order from the 8 new jobs' Job.epoch, which addInterest assigns at creation in re-route order (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineJobs.swift:137-147).
- Or use the engine's own admission record, admissionsForTests (EngineState.swift:77-82, appended at EngineDispatch.swift:730).
- With epochs, the test needs no 8-slot tuning.
- A4 (G4, oracle independence): IDTokens' equality and the recount must not share code with what they check.
- Remove IDTokens' custom `==`, or make it a symmetric set comparison.
- Build Job.recountTokens without IDTokens.init/add, for example as `[AssetID: Set<InterestToken>]`.
- Write I1 over a `tokens: Set<InterestToken>` projection (first ∪ others), plus a structural check that no entry's `others` contains its `first`.
- Keep the unit test's direct `count` steps. They are NB1's real kill; correct NB1's kill text to say so.
- A5 (G4, re-insertion): handle NB9 explicitly, both its kill and its fallback.
- Write T5 stage 1 first (P3). With I2 added, it should fail sweep-first on 8e1fb24.
- S3-R26 must say whether a sweep-first-only kill is enough here. The draft should record the visit-first half as unreachable by construction: the follow ends before the input, and mappedBack reaches the true arm only sweep-first, where it is a no-op.
- Alternatively, require a direct continueMove-level test that does not depend on the order.
- If T5 cannot be built this cycle, remove the re-insertion (S3-R16 1(e) and item 3). Keep I2, and record Q1 and variant Y as residual risks with the analysis' construction.
- A6 (G4): in T3, have the user waiter join the moved id before the prefetch group, so the waiter is the id's `first` holder; then release the waiter. This reaches IDTokens.remove's promote arm. Assert that the group's interest is re-routed by the later move, in both orders. Alternatively, release the group if it joined first.
- A7 (G3): the change to /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Tests/ZTronAssetSyncTests/Engine/EngineInterestCountsTests.swift:81-83 needs an explicit ruling.
- Either S3-R26 authorises the one-to-one change (old and new step recorded in the draft, with the reason: the operation is removed from production),
- or keep `setAssets`: release the old ids, then index the new ones, leave the step unchanged, and still move committed to subtractAssets.
- A8: in step 7, at /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineFollow.swift:902-923, `visitMoves` must keep `self.state.unfollowed.insert(transfer)` when the passed set is non-empty (:908-914), and before startMove. Alternatively it returns `passed` and follow inserts. Its doc must not call the helper pure.
- A9: replace the 'no answer reads them' sentence with the list of readers in R2. Record each in the draft as aligned with the fit path (S3-R16 item 2). Note as UNCONFIRMED the possible stale binding (EngineDispatch.swift:1049) and the 404 failure record (EngineFailures.swift:145) of an unheld moved id on 8e1fb24, which this change closes.
- A10 (C2, no new branch): step 10 already edits answerPresentMembers (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EnginePresence.swift:338-354), so drop its `job` copy there.
- First read the (token, held, lane, kind) rows from the table in a scoped read.
- Then call setInterest(nil) or subtractAssets, answerPresent, and `assets.subtract(present)`.
- This avoids the new O(N) copy of the index, and the existing O(N) copy of Job.assets at :353.
- A11 (G4 records):
- Name in the NB list the kills of removeAsset's and subtractAssets' release lines: the unit recount steps, plus engine I1 through a partial purge (withdrawPurged → subtractAssets) and any move.
- Record these as reached in production only by unit tests, or unobservable there, and unit-killed, on the f066083 InterestCounts precedent:
  - setInterest's (old?, new?) arm: no production caller replaces an interest once steps 9 and 10 land; the remaining callers are EngineJobs.swift:149, :163, :350, EngineDispatch.swift:1116, EngineMoves.swift:212 and EngineFailures.swift:298;
  - insertAsset's no-interest arm: unreachable, because of EngineJobs.swift:157-161;
  - keepInterests' release: its copy is never stored (EngineFailures.swift:872-879);
  - removeAllInterests' clear: removeJob always follows (EngineDispatch.swift:1261-1262, EngineJobs.swift:623-624).
- A12 (C2 inventory, S3-R25 item 3): add rows for the index's own per-id costs, each with a figure or an argument:
- setInterest(nil) and dropInterest of an n-id interest are now O(n) releases, where they were O(1). Example: a shared-content 10,000-member group released at its first member (EngineCommands.swift:404-409 → EngineJobs.swift:350), unmeasured.
- keepInterests' index copy (EngineFailures.swift:875).
- The index copy each live Job copy pays at its first removal: EngineFailures.swift:278-303, EngineCommands.swift:1008, EngineDispatch.swift:1101, EngineFollow.swift:352 and :615.
- Refresh the stale figures in R9.
- A13 (flake bar): run T2-T6 under the same iteration discipline as cycle 20's flake close: 30 iterations per LaneDropVisit argument on the simulator, with 0 failures, before the cycle's verifiers. This applies S3-R16 1(d) to this cycle's new tests.

## checked_claims

- CONFIRMED: the fit path makes the same calls in the same order. Today's move (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineFollow.swift:931-955) runs subtract, then the snapshot's tokens ascending × each token's moved ids ascending, each removeAsset then reroute, then the per-token removeInterest. Pairs sorted by (token, asset) reproduce that order.
- The per-pair emptiness check fires exactly where the per-token check does: stored interests are never empty between operations, and no re-route touches the holder.
- A retire can only happen at the last pair.
- CONFIRMED: the stubs are safe. reroute reads only kind and lane (EngineDispatch.swift:1147-1162), and a token's lane and kind are fixed.
- CONFIRMED: the bounded path keeps today's sequence.
- startMove's items (EngineMoves.swift:156-162) are, by I1, the same multiset as moveItems(of:).
- MoveProgress is a min-heap on (asset, token) (EngineMoves.swift:5-60), so the pop sequence does not depend on input order.
- continueMove's per-id restructure keeps the guards at :202-206, the removal at the id's first item (:195) and the end re-lane at :218-223.
- CONFIRMED by reading: the bounded-path orphan is real.
- dropInterest never touches Job.assets (EngineJobs.swift:346-366).
- startMove gives unheld ids no item, and :195 never removes them.
- So I5 (EngineCommands.swift:1750-1756) trips after the rest in both orders whenever moved > followIDsPerTurn.
- T4 should fail on 8e1fb24.
- CONFIRMED: the index funnel is complete.
- Job.interests is `private(set)`, written only by Job's mutators (EngineState.swift:689, :774-820).
- Job is built in production only at EngineJobs.swift:139.
- No test writes Job.assets or interests directly (grep).
- CONFIRMED: the oracle's existing injections leave Job.assets and interests alone (EngineOutcomeTests.swift:451-475). removeAllInterests also clears the index. So I1 and I2 add no message, and the exact `miscounted` expectation at :457 stays a single message.
- CONFIRMED: EngineInterestCountsTests.swift:78-83. The interest is empty before setAssets([a, b]), so insertAsset(a) and insertAsset(b) give the same ids. The step's operation still changes (R7).
- CONFIRMED: Set.intersection iterates the smaller operand. This settles one of the design's UNCONFIRMED cost items (continueInbound's ids). In _NativeSet.intersection, `if self.count > other.count { for element in other ...}`, plus a temporary bitset of self's bucket count (/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface:16789-16812).
- CONFIRMED: the copies that the design removes are real.
- continueInbound's `holder` binding is alive in both branches (EngineFollow.swift:1220-1230); step 8 removes it from both.
- follow's `job` binding is alive across startMove (EngineFollow.swift:902-915).
- CONFIRMED: the re-insertion fires only in the states the design names.
- Its true arm needs an interest in the id after the id's items have run. That is either a join after the snapshot (Q1, the at-once join through EngineJobs.swift:117 and :156-164) or a mapped-back rejoin through reroute, where addInterest has already inserted the id (EngineJobs.swift:156) and the re-insertion is a no-op.
- Visit-first never builds the Q1 state.
- The variant-Y T' half is closed: H's later visit under C_y sees A and moves T', as visit-first does.
- CONFIRMED: no new await and no liveness hole. Every exit still answers or re-routes by interests. A holder removed mid-loop makes the re-insertion read nil.
- CONFIRMED: no semantic conflict with RR-21 (/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/design-minimal.md steps 1-2, 6, 9, 15).
- `.reroutes` items are on no job, and the drain runs after followMoving.
- RR-21's committed and take-off rewrites use the same setInterest(nil)/subtractAssets substitution.
- The overlaps are textual only (P2): EngineMoves.swift, committed (EngineDispatch.swift:1100-1139), and the take-off's callers (EngineFollow.swift:352, :615).
- CONFIRMED: the cycle-20 figures from the logs under /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-probes-c20/.
- Commit window: best 10.16 and 10.21 (correct), 9.82 (reqs).
- MANY-MOVES k = 1/16/64: 8.22, 79.55, 304.79 ms, which is about 4.7 ms per move.
- userShared keep: 8.11-8.18 ms; supersede: 7.21-7.45 ms.
- divergence 7.17-7.22, inboundHolder 7.22-7.36, sharedApply 6.81-7.40, throttleExtension 8.12-8.13, handleRelease 5.27-5.67, shutdown 1.45-1.69 ms.
- CONFIRMED: followsPerTurn = 256 bounds the owed moves of one follow turn (EngineFollow.swift:11, :116), and inboundMovesNow = 64 bounds the apply's turn (:1172, :1180).
- CONFIRMED: the admissionsForTests seam exists (EngineState.swift:77-82; EngineDispatch.swift:730), for A3.
- CONFIRMED: the MoveRevalidation shapes run in both orders (EngineFollowBarrierMoveRevalidationTests.swift:201). The visit-first run lands the shape after the follow ended (:119, :148-149).
- CONFIRMED: progress is keyed per id: `.transfer(AssetID)` (SubscriberQueue.swift:15), retired only for the ids left at removeJob (EngineJobs.swift:443-445), and emitted for `job.assets.min()` (EngineDispatch.swift:905).
- CONFIRMED: answerPresentMembers removes the present ids from every interest that holds them before Job.assets.subtract (EnginePresence.swift:342-353), and takeOffMovedBefore does the same (EngineFollow.swift:557-566). So I2 holds there, as the design says.
- NOT FOUND: no answer difference from visit-first in either LaneDropVisit order, beyond the deliberate alignments (the unheld subtraction and the re-insertion). Both move sweep-first or bounded runs toward the fit path and visit-first.
- UNCONFIRMED (not run): every cost figure, T5's buildability, Q1 stage 2's answer difference, and the claim that no MoveRevalidation outcome changes.

## confidence

Medium. Every check above is by reading 8e1fb24, the cycle-20 logs and the SDK interface; nothing was built, tested or benchmarked. The call-order equivalence and the invariant arguments are high confidence. The C2 margins (the commit-window free, k = 256) and T5's buildability are low to medium.

## c2_concerns

- Commit window: already over c2Budget on 8e1fb24 (10.16 and 10.21 ms best; s3f-c20 correct #5, blocking).
- The eager index adds the free of O's 10,001-entry [AssetID: IDTokens] in the same turn: 16,384 buckets, about 512 KB, one key destroy and one empty-Set release per entry. My estimate is 50-150 µs; the design's is 40-90 µs.
- resolveAll's `job` copy keeps the index alive until the turn's end (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineJobs.swift:615-627). See A1.
- MANY-MOVES at the per-turn maximum is unpinned: 256 owed moves in one follow turn (EngineFollow.swift:11, :116). By the design's own per-move estimate it is about 6-11 ms. See A2.
- New O(n) work in single turns:
- setInterest(nil) and dropInterest now release n index entries for an n-id interest, where they were O(1). Example: a shared-content 10,000-member group released at its first member (EngineCommands.swift:404-409 → EngineJobs.swift:350, then retire's retireProgress loop). Estimated +0.6-1.2 ms; no BenchSync case covers it; UNCONFIRMED.
- RR-21's 10,000-token dropInterests and its commit setInterest(nil) calls add about 0.5-1 ms to that design's planned 2-4 ms turns.
- Job copies alive across interest removals now also copy the index once, O(N):
- answerPresentMembers (EnginePresence.swift:339; fixable in step 10, A10);
- committed (EngineDispatch.swift:1101, for RR-21);
- countFailedAttempt (EngineFailures.swift:278-303);
- withdrawPurged (EngineCommands.swift:1008);
- jobAtVerdict/keepInterests (EngineFailures.swift:875);
- the take-off's callers (EngineFollow.swift:352, :615; already in RR-21's failing 47-52 ms case).
- If contingency (ii) is taken, the O(N) build lands in the turn of the first move off a holder. On divergenceTurns (7.17-7.22 ms best), a 10,000-id build of about 0.6-1 ms leaves roughly 2 ms. Measure it.
- Per-job costs: each single-id job now allocates and frees a small index (one malloc and one free).
- Turns that create or free thousands of jobs are within margin by estimate: divergence makes about 512 new jobs per turn; shutdown frees 10,000 jobs, measured at 1.45-1.69 ms best.
- Every Job copy retains one more reference. On the 10,000-job walks (throttleExtension, 8.12 ms best) that is about +50-100 µs. UNCONFIRMED.

## g4_concerns

- NB9, the re-insertion: killed sweep-first only. Its true arm is unreached visit-first by construction, and the kill depends on T5, which nobody has built (A5).
- I1 must be independent of the code it checks. The recount must not reuse IDTokens.add, and IDTokens `==` must be symmetric (A4). Otherwise NB1's stated kill is not the real one; the real kill is the unit test's direct count steps.
- T3 must fix the join order, or NB3's engine kill takes the `others` arm instead of the promote arm (A6).
- T2 asserts the fake transport's `.started` order with 8 attempts in flight. That is S3-R25 item 4's flake class; use Job.epoch or admissionsForTests (A3).
- Some new branches are killed only by unit tests: NB5 (insertAsset's no-interest arm), NB7 (keepInterests' release on a copy never stored), NB8 (removeAllInterests' clear before removeJob), and setInterest's (old?, new?) arm, which is production-unreachable after steps 9 and 10. Record each as production-unobservable and unit-killed, so that a covdiff or mutation verifier does not report them as surviving engine mutants (A11).
- The NB list leaves out the new release lines in removeAsset and subtractAssets, which S3-R25 item 10's covdiff will flag. Name their kills (A11).
- The setAssets removal changes a passing test's operation (G3 as restated in S3-R16). It needs a ruling, or the fallback that keeps setAssets (A7).

## residual_risks

- Q1 stage 2: on 8e1fb24, sweep-first may give T' a different answer from visit-first. This is UNCONFIRMED, never probed; the analysis puts it at low to medium. The re-insertion closes it only if T5 holds.
- Variant Y's T1 half remains an open 1(a) candidate: the rest re-routes T1 under the current copy (listing nil) after its holder began publishing (/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine/EngineFollow.swift:832).
- On 8e1fb24, an unheld moved id left on a bounded holder may be bound by the holder's publication (EngineDispatch.swift:1049), or recorded in its 404 failure (EngineFailures.swift:145), at the old content. Whether this happens depends on the store's publish guard and the failure record's key (UNCONFIRMED). The change removes the path.
- Progress: moved ids leave Job.assets without retireProgress on both paths. This change extends that to unheld ids on the bounded path (EngineJobs.swift:443-445 retires only the ids left at removeJob). A trailing transferProgress keyed by the old min id (EngineDispatch.swift:905) may still flush. This matches the fit path, and it is not an answer.
- Empty binding (RR-20 family): a verifying holder whose moved ids were all unheld can now bind [] on the bounded path, as it already can on the fit path.
- Adjacent to this item, UNCONFIRMED: dropGroupMember copies Group.pending, a struct field ([AssetID: TransferID]), on every call (copy out, mutate, write back; EngineJobs.swift:594-599). That makes it O(pending) per id on reroute's T21 path (EngineDispatch.swift:1156), on answerPresent for groups (EnginePresence.swift:102) and on the purge withdrawals (EngineCommands.swift:1025, :1063). A turn of 512 drops from one 10,000-member group could exceed C2. No probe exists, and the operation is missing from the C2 inventory.
- Pre-existing and not made worse: an id held by many interests, for example 10,000 waiters, still moves whole in one turn under S3-R22 item 1's rule. move's cost for it is now O(h log h).
- The value of contingency (i) depends on whether swift_release on the empty-Set singleton takes the immortal fast path (UNCONFIRMED).
