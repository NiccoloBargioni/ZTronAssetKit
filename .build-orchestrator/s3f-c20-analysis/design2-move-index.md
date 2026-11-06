# design2:move-index

Read-only analysis for ruling S3-R26 (workflow wf_bc7908d4-1ad, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## item

S3-R26 / WP-F cycle 21: move's whole-holder sort (s3f-c20-issues correct #1 blocking, reqs #6 non-blocking). Covers EngineFollow.swift:931-955 move, EngineMoves.swift:140-226 startMove and continueMove, the removal at EngineMoves.swift:195, and takeOffMovedBefore at EngineFollow.swift:551-568. Read at 8e1fb24; nothing built or run.

## recommendation

Pick (a), built eagerly: a per-id token index on Job. It is `tokensByID: [AssetID: IDTokens]`, where IDTokens is one token plus a Set of the others (the Set is empty in the common one-holder case). It is kept inside Job's existing mutators beside interestCounts and recounted by a new invariant clause.

The changes:
- **No Job copy across the removals.** move, startMove, follow and continueInbound pass the TransferID.
- **move.** It builds its (token, id) pairs from the index for the moved ids only, then sorts just those pairs by (token, asset), which is today's order. Cost is O(p log p), where p is the moved ids times their holders, independent of the holder's size.
- **startMove.** It builds its heap items from the index in O(p). It also drops, at its first turn, the moved ids that no interest holds, the way move's own subtract does. This closes a latent bounded-path break of EngineCommands.swift:1752-1756.
- **continueMove.** It keeps today's removal at an id's first item (:195) and puts the id back after its last item when an interest still holds it. That costs O(1) per id. It closes Q1 and the hidden-T' half of variant Y.
- **Two new clauses.**
  - I1: the index equals its recount.
  - I2: every interest's ids are a subset of Job.assets.
- **Narrowing.** committed and answerPresentMembers narrow an interest with subtractAssets, and setAssets is removed.
- **takeOffMovedBefore** is left to RR-21, which should build its items and stubs from the index.

Rejected:
- (b) costs k × O(interests) per turn when the holder carries user waiters.
- (c) still needs (a) or (b) for PARTIAL-MOVE's single 500-id move, and it adds coalescing branches and changes the re-route order.

The one C2 risk is the commit window. concentrationPublicationTurns is 9.86 ms best, a 0.14 ms margin. Freeing O's 10,001-entry index inside resolveAll adds an estimated 40-90 µs. Measure that case first; contingencies are under risks.

## mechanism

- 1. EngineState.swift, before `struct Job` (:672): add `struct IDTokens: Equatable, Sendable`.
- Fields: `private(set) var first: InterestToken` and `private(set) var others: Set<InterestToken> = []`. `others` never contains `first`, and the empty literal does not allocate.
- `init(_ token: InterestToken)`.
- `mutating func add(_ token: InterestToken) { guard token != self.first else { return }; self.others.insert(token) }`. It is idempotent, because step 2's default-subscript insertion calls it on a fresh entry.
- `mutating func remove(_ token: InterestToken) -> Bool { guard token == self.first else { self.others.remove(token); return true }; guard let next = self.others.popFirst() else { return false }; self.first = next; return true }`. It returns false when no holder is left.
- `var count: Int { 1 + self.others.count }`, `func contains(_:)` and `func forEach(_:)`.
- `static func ==` compares as token sets: `lhs.count == rhs.count && rhs.contains(lhs.first) && lhs.others.allSatisfy(rhs.contains)`. Which token is `first` follows Set order, which is hash-seeded, and nothing reads it in order.
- 2. EngineState.swift Job, after interestCounts (:692): add `var tokensByID: [AssetID: IDTokens] = [:]`.
- Doc: the tokens of the interests that hold each id, kept with `interests` by every mutator below. move, startMove and continueMove read a moved id's interests from it in O(1). It is `var` like interestCounts so the invariant oracle can break it.
- Private helper `index(_ asset: AssetID, for token: InterestToken)`: `self.tokensByID[asset, default: IDTokens(token)].add(token)`, one hash, in place.
- Private helper `release(_ asset: AssetID, for token: InterestToken)`: `if self.tokensByID[asset]?.remove(token) == false { self.tokensByID[asset] = nil }`. Releasing a token that does not hold the id is a no-op.
- 3. EngineState.swift mutators.
- `setInterest` (:774-787) keeps its switch:
  - `(nil, added?)` indexes every id of added;
  - `(removed?, nil)` releases every id of removed;
  - `(old?, new?)` releases old's ids, then indexes new's. There is no diff branch, and no production path replaces an interest once steps 9 and 10 land.
- `insertAsset` (:790-792): `if self.interests[token]?.assets.insert(asset) != nil { self.index(asset, for: token) }`.
- `removeAsset` (:796-798): `guard self.interests[token]?.assets.remove(asset) != nil else { return false }; self.release(asset, for: token); return true`.
- `subtractAssets` (:801-803): `self.interests[token]?.assets.subtract(assets); for asset in assets { self.release(asset, for: token) }`. O(|assets|).
- `setAssets` (:806-808): remove it. Its only caller, committed :1118, moves to subtractAssets in step 9.
  - EngineInterestCountsTests.swift:81-83 replaces its step with `insertAsset(a)` and `insertAsset(b)`, which give the same ids. That test is a cycle-20 test, not a CDN test, so record the edit in the draft.
  - If no pre-existing test may change, keep setAssets instead as release-old, then index-new.
- `removeAllInterests` (:811-814): add `self.tokensByID = [:]`.
- `keepInterests` (:817-820): evaluate isIncluded once per interest and collect the dropped tokens. Release each dropped interest's ids, then filter and recount as today. This matters for jobAtVerdict's copy at EngineFailures.swift:875.
- New `func holdings(of assets: Set<AssetID>) -> [(token: InterestToken, asset: AssetID, interest: JobInterest)]`.
  - Body: `for asset in assets { self.tokensByID[asset]?.forEach { token in _ = self.interests[token].map { pairs.append((token, asset, JobInterest(lane: $0.lane, kind: $0.kind, assets: []))) } } }`, then `pairs.sort { ($0.token, $0.asset) < ($1.token, $1.asset) }`.
  - Optional chaining skips the ids no interest holds.
  - A token with no interest is structural under I1; there is no explicit else.
- New `func moveItems(of assets: Set<AssetID>) -> (items: [MoveItem], unheld: [AssetID])`.
  - Body: `for asset in assets { guard let tokens = self.tokensByID[asset] else { unheld.append(asset); continue }; tokens.forEach { items.append(MoveItem(asset: asset, token: $0)) } }`.
- New `static func recountTokens(_ interests: [InterestToken: JobInterest]) -> [AssetID: IDTokens]`, used by I1 and by the unit test.
- 4. EngineFollow.swift:931-955: change move to `func move(_ moved: Set<AssetID>, of transfer: TransferID, listing: ValidatedManifest? = nil) -> Bool`.
- Supersede branch, as at :933-942: `if let job = self.state.jobs[transfer], moved.count == job.assets.count, job.state != .verifying, job.state != .committing { ...abandon/recordBreaker as :934-940...; self.supersede(transfer, settling: false, listing: listing); return true }`. The copy lives only in the branch that supersedes. That branch changes no id set in place: supersede assigns new empty containers.
- `let pairs = self.state.jobs[transfer]?.holdings(of: moved) ?? []`. This is a temporary read; no copy is kept.
- `self.state.jobs[transfer]?.assets.subtract(moved)`, ids no interest holds included, as :944 does.
- `for pair in pairs { _ = self.state.jobs[transfer]?.removeAsset(pair.asset, for: pair.token); self.reroute(pair.token, interest: pair.interest, asset: pair.asset, from: transfer, listing: listing); if self.state.jobs[transfer]?.interests[pair.token]?.assets.isEmpty == true { self.removeInterest(pair.token, from: transfer) } }`. An interest empties only at its token's last pair, so removeInterest runs exactly where today's per-token check at :950-952 runs.
- `return !moved.isEmpty`.
- The sorts at :945-946 and the walk over every interest of the snapshot go.
- 5. EngineMoves.swift:140-166: change startMove to `func startMove(_ moved: Set<AssetID>, of transfer: TransferID, listing: ValidatedManifest?, budget: Int)`.
- The fit guard (:141-143) calls `self.move(moved, of: transfer, listing: listing)`.
- `let (supersedes, lane) = self.state.jobs[transfer].map { (moved.count == $0.assets.count && $0.state != .verifying && $0.state != .committing, $0.lane) } ?? (false, .bulk)`.
- :146-155 read the job's state and active attempt from the table: `self.state.jobs[transfer]?.state == .downloading` and `if let active = self.state.jobs[transfer]?.active`.
- :156-162 become `let built = self.state.jobs[transfer]?.moveItems(of: moved) ?? ([], [])`, then `self.state.jobs[transfer]?.assets.subtract(built.unheld)`. Moved ids that no interest holds leave now, as move's subtract (:944) takes them in the fit case. Today they get no item, so :195 never removes them.
- `var progress = MoveProgress(built.items, supersedes: supersedes, lane: lane)`. The heapify is unchanged, so items pop in the same (asset, token) sequence.
- Update the doc at :134-139.
- 6. EngineMoves.swift:179-226 continueMove: restructure the loop per id and keep every guard.
```
while let asset = progress.first?.asset {
    guard spent < budget else { break }
    spent += 1
    self.state.jobs[holder]?.assets.remove(asset)
    while let item = progress.first, item.asset == asset {
        _ = progress.popFirst()
        // :202-216, unchanged
    }
    if self.state.jobs[holder]?.tokensByID[asset] != nil {
        self.state.jobs[holder]?.assets.insert(asset)
    }
}
```
- The guard is :190-192. The removal is :195, unchanged: still at the id's first item.
- The inner loop's body is :202-216 unchanged: the stub guard, the removeAsset guard, reroute, and an empty interest goes through setInterest(nil) or removeInterest.
- The re-insertion lands after the id's last item. Comment it: an interest that joined the job after the visit began still holds the id, so the id stays the job's (Q1).
- :218-223 are unchanged. `current` (:186) goes.
- Cost: one index read per id, plus one insertion only in the Q1 state.
- Why remove first and put back at the end, rather than remove only at the end: an id stays out of Job.assets while its items run, as today. So a retire at a non-last item, when the holder's last interest leaves, runs removeJob's retireProgress loop (EngineJobs.swift:443-445) without that id, exactly as today.
- Update the doc at :168-178.
- 7. EngineFollow.swift:902-923 follow: replace the `job` binding at :903-907 with a private helper `visitMoves(of transfer: TransferID) -> (moved: Set<AssetID>, reroute: Set<AssetID>?)?`.
- The helper reads the job, calls rerouteOnVisit (pure, :860-877) and the moved filter of :907, and returns both sets.
- :915 calls `self.startMove(moved, of: transfer, listing: nil, budget: budget)`.
- No copy is alive while the move changes the job, even in debug builds, where a local's lifetime can run to the end of its scope.
- 8. EngineFollow.swift:1220-1229 continueInbound.
- `if self.waitingTarget(move) != nil, self.state.jobs[move.holder] != nil {`.
- In the else branch at :1226-1227: `let ids = self.state.jobs[move.holder]?.assets.intersection(move.ids) ?? []`, then `self.startMove(ids, of: move.holder, listing: move.copy, budget: budget.ids)`.
- Why: the `holder` copy alive across startMove made every owed move copy, at its first removal, the holder's Job.assets, interest sets and interests table, and it would now copy the index too. For 64 owed moves off H that is 64 whole copies of a 10,000-id holder.
- 9. EngineDispatch.swift:1113-1119 committed: replace with `if unbound.count == interest.assets.count { setInterest(nil, for: token) } else { subtractAssets(unbound, for: token) }`.
- This gives the same ids as setAssets(bound), and the index work is O(|unbound|).
- RR-21's design-minimal step 6 makes the same substitution; whichever lands second keeps it.
- `job` is still alive across the loop. With unbound ids present, the index is copied once (O(N)); RR-21's rewrite should collect first and mutate after.
- 10. EnginePresence.swift:347-348 answerPresentMembers: replace with `if held.count == interest.assets.count { setInterest(nil, for: token) } else { subtractAssets(held, for: token) }`.
- This leaves the same interests as `JobInterest(lane:kind:assets: left)`, and the index work is O(|held|).
- 11. EngineCommands.swift invariantViolations, inside the per-job loop right after the counts clause (:1727-1732): add clauses I1 and I2. Their predicates are under invariants.
- 12. takeOffMovedBefore (EngineFollow.swift:551-568): no change in this item; RR-21's step 9 rewrites it.
- The structure serves that rewrite:
  - `moveItems(of: held)` gives the heap items in O(|held| × holders), with no walk of interests that hold none of the ids.
  - Counting items per token decides which interests are wholly held (count == interests[token].assets.count, so dropInterests) and which are partly held (subtractAssets of their held ids).
  - Stubs come from interests[token].
  - The take-off should take the TransferID. Its callers at :352 and :615 pass a Job copy, which would now also copy the index once.
- The index does not remove the ordering cost. A (token, asset) order needs the held pairs sorted: O(|held| log |held|), about 5 ms at 10,000 with AssetID's UTF8View `<`, which is today's :559 cost.
- RR-21's MoveProgress heap, popping in (asset, token) order across turns, is what removes that sort.
- 13. Tests.
- (a) New unit suite EngineIDTokensTests in EngineInterestCountsTests' pattern: a `record` that checks `job.tokensByID == Job.recountTokens(job.interests)` after every step.
- (b) Engine tests T2-T6 (shapes under new_branches), each in both LaneDropVisit orders, with invariantViolations() checked after every held turn.
- (c) T7, oracle injections for I1 and I2.
- (d) BenchSync release cases, ported from the cycle-20 probes:
  - `manyMovesTurns`, from VerifyC20CorrectProbes.manyMoves (:305-441): k = 1, 16 and 64 at 10,000 members, a 1,000-member warm-up, best of 3 ≤ c2Budget. Setup expectations: violations empty and publishing == moves == owedOffH.
  - `partialMoveTurns`, from VerifyC20ReqsC2Probes.partialMove (:142-197): users false and true, 10,000 members, 500 moved. Expect onO == 501 and onH == 9,500, best of 3 ≤ c2Budget.
  - Run them at a 1-minute load ≤ 10 together with every existing SyncBenchmarks case, concentrationPublicationTurns first.
- 14. Record the change in docs/adr-drafts/s3f.md, cycle 21:
- the decision;
- the C2 inventory row for move (:4846) with measured figures;
- the latent orphan finding;
- Q1's resolution and variant Y's open half.
It is not NEEDS-HUMAN-REVIEW: the index lives in memory only and adds no public API.

## invariants

- I1, new clause (EngineCommands.swift, after :1732): for every job in state.jobs, `job.tokensByID == Job.recountTokens(job.interests)`.
- The recount indexes every (token, asset) with asset in interests[token].assets.
- IDTokens `==` compares token sets including counts, so a duplicated token or a token with no interest fails.
- Message, for the smallest id that differs: `job \(transfer) indexes \(asset) as held by \(indexed tokens' sorted rawValues), which \(recounted tokens' sorted rawValues) hold`.
- I2, new clause, same place: for every job and every (token, interest), `interest.assets.isSubset(of: job.assets)`.
- Message, for the smallest token, then the smallest id: `interest \(token.rawValue) in \(transfer) holds \(asset), which is not among the job's ids`.
- Given I1, it is the same as `tokensByID.keys ⊆ job.assets`. It is written over interests so that a broken index cannot hide it.
- States that trip it: only the Q1 state and variant Y's hidden T', which continueMove's re-insertion now prevents. Every other removal from Job.assets also removes the ids from the interests in the same call: move :944, takeOffMovedBefore :557, answerPresentMembers :353.
- Existing tests that could trip it: none.
  - No test writes Job.assets: the grep finds only PurgeTests.swift:369, an unrelated init.
  - The unit tests that build Jobs outside the table are never checked: EngineInterestCountsTests (its ids are outside Job.assets), EngineFollowBarrierVerdictAnswersTests.swift:43-58 and :150-166, EngineRegressionCycle16Tests.swift:465-473.
  - The oracle's existing injections (EngineOutcomeTests.swift:452-475) leave Job.assets alone. removeAllInterests clears the index, so `orphaned` gains no message, and the exact `miscounted == [...]` at :457 stays a single message.
- I3, structural, checked by the unit test: IDTokens never lists a token twice, because add's guard keeps `first` out of `others`. I1's count-sensitive equality catches a duplicate.
- I4, documented, not a clause: nothing reads an id's tokens in stored order. Which token is first follows Set order, which is hash-seeded per process. holdings sorts its pairs, moveItems' items are heapified, and the re-insertion reads presence only.
- I5, existing clause, now also held by the bounded path: EngineCommands.swift:1752-1756, a job outside unfollowed holds no id the copy maps elsewhere. startMove now drops unheld moved ids, as move does.
- I6, existing, relied on: the token-lane clause (:1718-1726) and kinds fixed at registration. A token's lane and kind never change, so stubs read at a move's start equal per-pair reads. The counts recount (:1727-1732) is unchanged and sits beside I1; the counts and the index change in the same mutators.

## answer_equality_argument

**move, fit path.** Today the state changes in this order:
- assets.subtract(moved);
- then, for each snapshot token in ascending order and each of its moved ids in ascending order, removeAsset followed by reroute;
- then removeInterest when the interest emptied.

The new move makes the same calls in the same order, for six reasons:
1. **Same pairs.** By I1, the index at the move's start lists exactly the (token, id) pairs that the snapshot's interests hold among the moved ids. Nothing changes the holder between the caller's read and the move: rerouteOnVisit and the moved filter are pure, and continueInbound reads and calls at once.
2. **Same order.** The pairs are sorted by (token, asset), which is the nested order of :945-946.
3. **Same stubs.** reroute reads only the interest's kind and lane (EngineDispatch.swift:1147-1189). The stubs carry the table's lane and kind, and those are fixed per token (I6).
4. **No re-route touches the holder.** Every moved id maps elsewhere under the move's listing: follow's filter at :907, or an owed move's copy. So addInterest, answerPresent, failFastJoiner and reroute's T21 branch act on other jobs, waiters, groups, the run and heals, never on the holder's interests. Today's loop also re-routes regardless of what removeAsset returns, and so does the new one.
5. **Same removal point.** An interest empties only at its token's last pair. The per-pair emptiness check therefore removes it where the per-token check did, before the next token's pairs. A retire there happens only after the last remaining interest goes, as today.
6. **Same supersede.** The supersede branch reads the same three fields at the same point.

**startMove, bounded path.** The items are the same multiset of (asset, token) as the walk at :156-162 (by I1), so the heap pops the same sequence. The supersede decision and the abandonment read the same fields from the table.

**What deliberately changes:**
- **Unheld moved ids leave Job.assets at the first turn.** The fit path's subtract takes them, and so does a visit-first engine's visit, which calls move whole. Today's bounded path keeps them, because they have no items, and I5 trips once the rest ends. No interest holds them, so no answer reads them. The holder's binding loses ids that the reference binding does not have either.
- **continueMove puts an id back in Job.assets** only when, after the id's items, an interest still holds it. That interest joined after the visit began (Q1 step 6: makeInboundNow's at-once join during publish's bringInbound). A visit-first engine never reaches that state: R finished inside C_v's follow, and X's visit at C_w joined T' and T1 onto H, re-inserting A (EngineJobs.swift:156), so H bound {A, D}. With the re-insertion, sweep-first also binds A, and T' is served by H's commit instead of a fresh job of h. The bytes are the same, and there is one transport start fewer. That moves the outcome toward the reference and is in S3-R16's timing/request class. Q1 stage 2 (C_z, then a retry that returns 404 or hits the cap) now finds A on H, so C_z's visit moves T' as visit-first does.
- **committed and answerPresentMembers** produce the same interests, through subtractAssets.

Only these moves and the re-insertion read the index, and none of them reads its stored order (I4), so no other decision changes.

**Variant Y:** the re-insertion keeps A on H for T', as visit-first does. R's re-route of T1 under C_y after H began publishing (EngineFollow.swift:832, listing nil) is untouched. That half is still the analysis' separate, UNCONFIRMED 1(a) candidate.

## c2_argument

All figures below are estimates from this cost model; none was measured (UNCONFIRMED).

**Cost model.**
- AssetID's `<` walks UTF8Views (`lexicographicallyPrecedes`), about 30-40 ns per comparison.
- So today's sort of a 10,000-id interest (EngineFollow.swift:946) is about 4-5 ms. That matches cycle 20's ~4.7 ms per 1-id owed move: MANY-MOVES k=1/16/64 measured 8.22, 79.55 and 304.79 ms.
- An index operation is one hash of the id plus a probe, about 40-100 ns.

**The two pins:**
- **MANY-MOVES.** Each owed 1-id move becomes one index read, one pair, removeAsset and reroute, about 10-30 µs, with no copy of H. k=64 ≈ 3.5 ms (k=1 minus its sort) + 64 × ~0.02 ms ≈ 4-6 ms.
- **PARTIAL-MOVE users=false** (8.44-8.48 ms today): the 10,000-id sort and the CoW copies go; a 500-pair sort (~0.2 ms) comes in. ≈ 4-5 ms.
- **PARTIAL-MOVE users=true** (9.29-9.50 ms today): the sort of 10,000 interests, 10,000 one-id sorts, the per-token table reads and the copies go (~2.5-3.5 ms). The 500 re-routes stay. ≈ 6-7 ms.

**Maintenance costs added by the index:**
- +40-100 ns per join and per removal. At most 512 ids per follow turn, so +30-60 µs per turn.
- A new job's first entry allocates a small table: +50-100 ns per job, about +25-50 µs per 512 jobs created.
- A table growing to 10,000 ids rehashes once at 6,144 entries: about +0.3 ms in that one turn, as Job.assets already does.
- Removing an n-id interest costs n releases: about +0.5 ms at 10,000. No measured case does this in a tight turn.
- Freeing a full 10,000-entry index costs about 40-90 µs.
- Job gains one reference, so each Job copy costs two more atomics.

**Bounded first turns** (sharedApply 6.82/7.24, divergence 7.03/7.04, inboundHolder 7.18, userShared supersede/keep 7.18/8.01 ms):
- The item build reads the index instead of walking interests, at the same order of cost.
- Dropping the follow and continueInbound copies saves the CoW of the holder's Job.assets, interests table and interest sets, about 0.2-0.5 ms.
- Later turns add 30-110 µs; divergence, with its new jobs, is the top of that range.
- Every one of these stays at least 1.5 ms under C2.

**Commit window** (concentrationPublicationTurns: 9.86 ms best in the gate run; 9.81 earlier in cycle 20 and 9.64 in cycle 19):
- committed's all-bound loop does no index work.
- resolveAll's removeAllInterests and the job's removal free O's 10,001-entry index: +40-90 µs on a 0.14 ms margin.
- This is the one case that may cross C2. Measure it first: best of 3 at a 1-minute load ≤ 10.

**Other cases:**

| Case | Today (best) | Index effect |
|---|---|---|
| concentrationNotFound | 6.24 ms | +0.05-0.1 ms (freeing O's index at the 404) |
| concentrationFollow; held publication turns | 3.64 ms; 3.77 ms | +0.05 ms per turn, +0.3 ms once at the resize |
| handleRelease | 4.1-4.8 ms | +20 µs per turn (one release per member job) |
| publicationApply | ≤ 5.95 ms | no index work |
| throttleExtension | 7.20 ms | no index work found |
| shutdown | ≤ 5.24 ms | +0.3-0.5 ms (10,000 small tables freed) |
| reclaim | 5.81-7.29 ms | ≤ +0.3 ms (withdrawPurged's Job copy now also copies the index once per job with purged ids) |

RR-21's two failing cases (48.68 and 45.67 ms) remain RR-21's. The index adds about 0.5-0.9 ms of releases to their removal paths, which fits inside RR-21's planned turns of about 2-4 ms.

The change adds no await, actor hop, unsafe construct or Sendable exception. Every new type is a value type with Sendable members.

## new_branches

- NB1 IDTokens.add, `guard token != first` (the idempotent first).
- Test: EngineIDTokensTests.tokensFollowEveryChange (unit). Steps: an insert creates an entry of count 1; insertAsset of an id the token already holds keeps count 1; a second token gives count 2. Every engine test's I1 check also covers it.
- Mutant: drop the guard (`others.insert(first)`).
- Kill: every singly held id then counts 2. The unit recount fails 2/2, and every engine test's invariantViolations() fails in both orders.
- NB2 IDTokens.remove, the `token != first` arm (remove from `others`).
- Test: unit step 'remove the second holder'.
- Mutant: return true without removing.
- Kill: the token stays indexed; the unit recount and the engine I1 fail 2/2.
- NB3 IDTokens.remove, the promote arm (`others.popFirst()` becomes `first`).
- Tests: unit step 'remove the first holder while another holds the id'. Engine T3: one moved id held by a prefetch group and a user waiter, the waiter released first, then the move.
- Mutant: return false, or skip the promotion.
- Kill: the entry is deleted while the other token still holds the id. I1 fails, and in T3 the move's pairs miss the group, so its member is never re-routed and I2 trips. 2/2 in both orders.
- NB4 IDTokens.remove's sole-holder arm (return false) and Job.release's entry deletion.
- Test: unit step 'remove the sole holder' (the entry is gone). Any engine move also covers it.
- Mutant: keep the entry (return true, or drop the deletion).
- Kill: a stale entry fails I1 in the unit test and in every engine test that moves or releases, 2/2. The stale entry would also make continueMove re-insert moved ids, which trips I5.
- NB5 insertAsset indexes only when the token has an interest.
- Test: unit step 'insertAsset for a token with no interest leaves the index unchanged'.
- Mutant: always index.
- Kill: the unit recount fails 2/2. In the engine, addInterest calls insertAsset only for an existing interest (EngineJobs.swift:158-161), so only the unit test can kill this mutant.
- NB6 setInterest's index loops, in all three arms.
- Tests: unit steps for insert, remove, and a replacement with different ids ({a} to {b}). The cycle-20 counts steps replace with the same ids, which would hide a dropped release. The engine I1 check also covers it.
- Mutants: drop the insert loop, the remove loop, or either half of the replacement.
- Kill: missing or stale entries fail the recount 2/2.
- NB7 keepInterests releases the ids of the interests it drops.
- Test: unit, in wholeSetChangesRecount's style. The kept copy's index equals its recount, and the original job's index is unchanged.
- Mutant: drop the release.
- Kill: the copy lists dropped tokens; the unit test fails 2/2. jobAtVerdict's copy is never stored back, so the engine oracle cannot kill this one.
- NB8 removeAllInterests clears the index.
- Test: unit step 'after removeAllInterests the index is empty'.
- Mutant: drop the clear.
- Kill: the unit test fails 2/2. In the engine the job is removed right after, so the oracle cannot see it.
- NB9 continueMove's re-insertion at an id's end (`if tokensByID[asset] != nil { assets.insert(asset) }`).
- Test T5, in EngineFollowBarrierMoveRevalidationTests' style, run in both orders. Setup: followIDsPerTurn = 4; runOneFollowTurn, holdPublication and applyHeld; ids B1..B7, D and A = 'zz-z'; the analysis' Q1 steps 1-8.
  - Assert after R's last turn: H.assets ⊇ {A, D}, equal to visit-first.
  - Assert T' is answered with h's bytes, and h's transport starts == 1 in both orders (today: 2 sweep-first, 1 visit-first).
  - Assert invariantViolations(), I2 included, is empty after every turn.
  - Optional stage 2: apply C_z mapping A to z, then H's retry returns 404; assert T' gets z's bytes in both orders.
- Mutant: drop the re-insertion.
- Kill: I2 trips at R's last turn and h starts twice, so the test fails 2/2 in sweep-first. Visit-first never builds the state, by construction, so the kill happens in the sweep-first order.
- NB10 moveItems' unheld arm, plus startMove's `assets.subtract(built.unheld)`.
- Test T4, run in both orders. Setup: followIDsPerTurn = 4. H holds w for waiter W and o1..o6 for prefetch group G; G is released while H downloads, which leaves o1..o6 unheld (EngineJobs.swift:346-366). v3 maps o1..o6 to another content.
  - Assert after the follow: invariantViolations() is empty, and H.assets == [w] in both orders.
  - Assert the result equals a fit-path run with 3 unheld ids.
- The test is predicted to fail on 8e1fb24 (failing test first, P3).
- Mutant: drop the subtract, or the `unheld.append`.
- Kill: EngineCommands.swift:1752-1756 trips after the follow in both orders, 2/2.
- NB11 holdings' sort by (token, asset).
- Test T2, run in both orders. Setup: 8 user waiters t1 < ... < t8 on 8 members of H, named so that their id order is the reverse of their token order, plus a 9th member that stays, so H is not superseded. v3 maps the 8 to 8 new contents. The fit move re-routes them; with at least 8 transfer slots, source.starts lists the 8 new contents in token order.
- This pins today's order; it passes on 8e1fb24.
- Mutants:
  - Drop the sort: pairs come in hash order. The test fails unless the random order matches, probability 1/8!, so effectively 2/2.
  - Sort by (asset, token) instead: the start order reverses; fails 2/2 deterministically.
- NB12 holdings uses every token of an id: `first` and `others`.
- Test T3, run in both orders. A moved id is held by a prefetch group and a user waiter, in a fit move and, at followIDsPerTurn = 4, in a bounded move. Both interests are re-routed and answered with the new content's bytes.
- Mutant: use `first` only.
- Kill: one interest stays on H holding an id that is not in Job.assets, so I2 trips, and that interest is never answered with the new content. 2/2.
- NB13 Clauses I1 and I2.
- Test T7, the oracle (EngineOutcomeTests.invariantOracle style).
  - I1: inject `$0.jobs[transfer]?.tokensByID[AssetID("held")] = nil`; expect exactly the recount message.
  - I2: inject `$0.jobs[transfer]?.assets.remove(AssetID("held"))`; expect the subset message, checked with contains, because indexViolations might also report.
- Mutant: drop either clause.
- Kill: that injection's expectation fails 2/2.
- Per-turn pin, no new branch (requested): T6, at followIDsPerTurn = 4, in both orders.
- Setup: setUpHeldPublications with 8 user waiters whose publications are held at their first store unit, and H a prefetch group of 40 members sharing one content. v3 maps H's first 8 members onto the 8 contents, giving 8 owed one-id moves off H.
- Asserts:
  - the apply's own turn moves at most inboundIDsNow = 2 of them, and every held follow turn at most 4 (membersLeft on H before and after each runOneFollowTurn);
  - at the end every content holds its member and waiter, and H holds 32;
  - answers are equal across the two orders;
  - invariants are clean after every turn.
- Mutant: drop `budget.ids -= made.spent` at EngineFollow.swift:1231. All 8 moves then happen in the first turn, so the per-turn assertion fails 2/2 in both orders.
- Not new branches, but rewritten expressions:
- committed's `unbound.count == interest.assets.count` and answerPresentMembers' `held.count == interest.assets.count` restate today's `bound.isEmpty` and `left.isEmpty`. The existing commit and present-member tests cover them.
- continueMove's inner `while let item = progress.first, item.asset == asset` restates the `asset != current` partition. If `item.asset == asset` is dropped, one budget slot would carry several ids, and EngineFollowBarrierTurnTotalTests' per-turn bound fails.

## interactions

- RR-21, commit site (design-minimal.md step 6).
- Its unsorted pass builds MoveItems for the unbound ids. It then calls setInterest(nil) for wholly unbound interests and subtractAssets for partly unbound ones; this item's step 9 makes the same substitution.
- The index releases each removed id: about +0.5 ms for the 10,000 ids in concentrationCommitRerouteTurns.
- RR-21 must not hold committed's `job` copy across those calls, or the index is copied once (O(N)): collect first and mutate after, or re-read the table per token.
- The index does not make the commit's unbound search cheaper; it is O(ids) either way.
- RR-21, `.superseded` site (step 8). supersedePublication builds its items from the interests and then calls removeAllInterests, which clears the index in O(1) and frees it. There is nothing to coordinate. The supersede kept for move's call (EngineDispatch.swift:1256-1279) is unchanged.
- RR-21, drain take-off (step 9).
- The index serves takeOffMovedBefore's rewrite: `moveItems(of: held)` gives the items and per-token counts (wholly held tokens go to dropInterests, partly held ones to subtractAssets), with stubs from interests[token], in O(|held| × holders) and no walk of interests that hold none of the ids.
- RR-21's heap removes the sort that the index cannot.
- The take-off should take the TransferID. Its callers at EngineFollow.swift:352 and :615 pass a Job copy, which would now copy the index too.
- RR-21, the events themselves.
- The `.reroutes(OwedReroutes)` events hold ids that are on no job: those ids are subtracted from Job.assets and released from the index before the event is owed, so I1 and I2 hold.
- followedLane, the purge and RR-21's own nil-stub clause scan the events and never the index.
- continueReroutes' joins go through addInterest, which indexes the ids on their targets.
- Merge order. Both items edit committed (EngineDispatch.swift:1109-1135) and the take-off's callers. Land the index first so that RR-21's dropInterests and stubs read it, or land both in one commit series. A conflict there is an ownership signal (P2).
- S3-R25 item 2 (InterestCounts, f066083): same mutator funnel, same precedent. I1 sits beside the counts clause. The oracle's exact `miscounted` expectation (EngineOutcomeTests.swift:457) stays a single message.
- S3-R25 item 8 (continueMove's guards at :203, :206 and :222 are reached): kept verbatim inside the per-id loop.
- The new re-insertion is a fourth point.
- EngineFollowBarrierMoveRevalidationTests' shapes should not change, by reading:
  - the release and purge shapes leave the ids no holder, so nothing is re-inserted;
  - the mappedBack shape's id is rejoined by the rest's own re-route, so the insertion is a no-op.
  This is not confirmed by a run.
- S3-R25 item 9 (no holder epoch): a holder re-created between or within turns has its own index. The re-insertion and the guards read the current job, which matches how the guards already behave.
- follow barrier readers of Job.assets: publish's binding (EngineDispatch.swift:1049, after inboundBlocks), recordDeferredVerdict's away filter (:514), the walk (:1099), followedLane (EngineFailures.swift:777) and withdrawPurged (EngineCommands.swift:1011). After the re-insertion they all see A on H while T' holds it, as on a visit-first engine. Unheld moved ids no longer linger on a holder after a bounded move.
- jobAtVerdict (EngineFailures.swift:872-879), read only from followedLane (:748). keepInterests on its copy releases the dropped interests' ids, which copies the index once (O(N)), only when the verdict waits after a followed apply and an interest is dropped. That is off the measured tight paths. The 429 followedLane figures, 3.45 and 2.74 ms, leave room.
- Other places that hold a Job copy across interest removals now copy the index too, once per call: countFailedAttempt (EngineFailures.swift:278-303), answerPresentMembers (EnginePresence.swift:339), withdrawPurged (EngineCommands.swift:1008) and committed (EngineDispatch.swift:1101). The cost is O(ids of that job). The only measured case near one of them is the reclaim cases (withdrawPurged), with ≥ 2.7 ms of margin.

## risks

- 1. Commit-window margin. concentrationPublicationTurns is at 9.86 ms best, 0.14 ms under C2. Freeing O's 10,001-entry index inside resolveAll adds an estimated 40-90 µs, so the best of 3 may cross 10 ms. Contingencies, in order:
- (i) Make `others` a `Set<InterestToken>?`, nil while one token holds the id. That skips the release of the empty-set singleton for each freed entry, about -30-50 µs. add then needs a nil-to-`[token]` arm, which the unit test's second-holder step kills.
- (ii) Build the index lazily, at a job's first move off it, so a move target such as O never has one and its commit frees nothing.
  - The first move off a holder then costs O(N), about 0.6-1 ms at 10,000. Every other figure stays under C2 by estimate.
  - It adds a built/not-built state, and its 'already built' check has an equivalent drop-mutant (a G4 note).
- (iii) Find an offset in the same turn, outside this item: publishTerminal sorts 10,001 ids with the UTF8View `<` (EngineJobs.swift:635), about 4-5 ms by the same cost model.
- 2. Memory: about +0.5 MB for a job of 10,000 ids, at 32 B per bucket.
- 3. Drift. `tokensByID` is `var` so the oracle can break it, as interestCounts is. A future write outside Job's mutators would drift silently in production. I1 in every engine test is the guard.
- 4. More copies. Job copies alive across interest removals now also copy the index once each (see interactions). No measured case is known to put one on a 10,000-id job in a tight turn (UNCONFIRMED).
- 5. Debug builds can extend a local's lifetime to the end of its scope, so a read binding could still cause CoW there. visitMoves and the temporary-only reads in move and startMove keep release builds free of copies; debug only pays in time.
- 6. Mutant kills.
- The order pin's drop-sort mutant is killed with probability 1 - 1/8!; the (asset, token) mutant is killed deterministically.
- The re-insertion's mutant is killed in sweep-first only, because visit-first never builds the Q1 state.
- 7. Non-blocking request and timing changes (S3-R16):
- the Q1 holder binds A, one transport start fewer;
- unheld moved ids leave a bounded holder at its first turn. A bounded supersede's final removeJob therefore no longer calls retireProgress for them, matching how the bounded path already removes held ids at their turn. The fit-path supersede still retires every id.
- 8. An id held by very many interests (for example 10,000 waiters on one id) still moves whole in one turn: S3-R22 item 1's rule, pre-existing. It is now O(holders log holders) in move.
- 9. The two new clauses cost O(ids) per invariant check. Engine suites that check after every held turn get slower; test-duration guards ran at most 5.8-6.7 % in cycle 20.

## unconfirmed

- Every timing figure above is a cost-model estimate; no build or benchmark was run: MANY-MOVES k=64 ≈ 4-6 ms, PARTIAL-MOVE ≈ 4-5 and 6-7 ms, the commit window +40-90 µs, +30-110 µs per bounded turn.
- The bounded-path orphan break. EngineMoves.swift:156-163 builds no item for a moved id that no interest holds, and :195 never removes it, so after the rest EngineCommands.swift:1752-1756 trips. This is from reading; T4 is predicted to fail on 8e1fb24.
- Whether a store with a lagging manifest binds an unheld id, or Q1's hidden id, to the holder's old content at its publication, which would be a stale answer. Not traced.
- Whether the analysis' Q1 steps 1-8 can be built as a test as written, and whether its stage 2 prediction holds (sweep-first fails today, passes with the re-insertion).
- Variant Y's T1 half (EngineFollow.swift:832, listing nil, after H began publishing) is not closed by this design. It remains a separate 1(a) candidate.
- Whether swift_release on the empty-set singleton takes the immortal fast path. This affects risk 1's figure.
- Whether any tight case removes a 10,000-id interest through countFailedAttempt, answerPresentMembers or withdrawPurged while a Job copy is alive.
- Whether a progress subscriber observes that unheld moved ids no longer reach retireProgress at a bounded supersede's end (EngineJobs.swift:443-445).
- Whether EngineFollowBarrierTurnTotalTests' pattern exposes per-turn counts in both LaneDropVisit orders for T6's shape.
- That EngineFollowBarrierMoveRevalidationTests' outcomes do not change with the re-insertion (from reading).
- Whether T7's I2 injection also trips a clause in indexViolations (EngineCommands.swift:1901-1995). Use a contains-based expectation.
- That Set.intersection iterates the smaller operand (continueInbound's ids). This affects cost only.

## events_between_turns

- An at-once join onto the rest's holder in an owed id: makeInboundNow during publish's bringInbound (Q1 step 6), the follow's own inbound moves, or the drain's visit after a verdict. addInterest indexes the new token. The rest's snapshot items do not include it, so it stays, as on a visit-first engine. At the id's turn, the re-insertion keeps the id in Job.assets.
- A group release (dropInterest) of a token in an item: the index releases its ids, and the item is skipped by the guard at :202-203. With no other holder, the id is removed at its first item and not re-inserted, as today.
- A purge withdrawal (withdrawPurged, then subtractAssets): the index is released and the item is skipped by the guard at :205-206. Job.assets keeps the id until its turn, which then removes it with no holder left, as today.
- An apply (C_w, C_y): the rest re-routes under the copy as it stands at each turn (listing nil, :832), unchanged. A re-route that maps back joins the holder through addInterest, which inserts the id and indexes the token, so the re-insertion is a no-op.
- The holder's publication starts (verifying): its binding waits for the rest through inboundBlocks, unchanged. Thanks to the re-insertion, it now binds ids that a newly joined interest holds.
- The holder is removed (retire, supersede, resolve): continueMove's first guard ends the moves, and the index dies with the job.
- The holder is re-created as a new job of the same transfer: the rest continues on the new job. The guards and the re-insertion read that job's own interests and index.
- User joins behind the barrier are deferred (joinsAfterFollow) until the drain, so they never land between a rest's turns.
- Owed inbound moves onto or off the holder: continueInbound runs first in each turn. Its startMove and move work through the TransferID and the index, with no copy of the holder.

## rejected_alternatives

- (b) Filtered iteration over the interests that hold a moved id: the filter walks every interest, O(I) per move. With 10,000 user waiters that is about 0.3-0.6 ms per move, so 16-30 or more owed moves in one turn exceed C2, and budget.holders allows 256. It fails 'every grouping'.
- (c) Coalescing the owed moves off one holder in continueInbound.
- Each move has its own target and copy, so one move call cannot serve them all.
- One sort per turn still costs about 5 ms at 10,000 ids.
- PARTIAL-MOVE's single 500-id visit move is untouched.
- It needs an InboundMove regrouping and new budget branches, and it changes the cross-target re-route order and T20 places.
- Per-id holder counts only (the analysis' option for :195): fixes the removal, but move still needs each moved id's tokens. That means an O(I) walk whenever the job has many interests.
- A Set<InterestToken> per indexed id: one allocation per id, about +50-80 ns per join and a larger free. That is slower in the commit window than one token plus an empty Set.
- Moving :195 below the guards ('the first live item removes it'): ids whose items are all stale (a group released mid-rest) would stay as orphans and trip :1752. It also leaves variant Y unchanged, as the analysis found.
- Removing the id only at its end, with no remove-then-re-insert: during the id's items the id would still be in Job.assets. A retire at a non-last item would then run removeJob's retireProgress for an id whose interests have moved (EngineJobs.swift:443-445).
- Re-deriving a rest's items from the live index at each id's turn: it would move a T' that joined between turns. On a visit-first engine that T' joined after the visit finished and stays.
- Unifying move with continueMove, with an infinite budget: move's (token, asset) re-route order would become (asset, token).
- Re-reading lane and kind per pair inside move: it adds a guard that is unreachable inside one call. Reading the stubs once at the start is equivalent, because lanes and kinds are fixed per token (I6).
- A work counter as a deterministic pin of 'independent of holder size': new state with no behavioural meaning. The BenchSync release cases pin C2 instead.
- An index outside Job, as an EngineState side table: every mutator call site would have to update two structures. Job's mutators already funnel every interest change, as the InterestCounts precedent (f066083) shows.
- A lazy index as the primary design: the first move off a holder becomes O(N), and its 'already built' check has an equivalent mutant. It is kept only as risk 1's contingency.

## size_estimate

**Production:** about +150 / -45 lines.
- EngineState.swift: +85 / -5. Adds IDTokens, tokensByID, the index and release helpers, the mutator updates, holdings, moveItems and recountTokens. Removes setAssets.
- EngineFollow.swift: +25 / -20. Changes move, adds visitMoves, changes continueInbound.
- EngineMoves.swift: +20 / -15. Changes startMove and continueMove's per-id loop.
- EngineDispatch.swift: ±4.
- EnginePresence.swift: ±4.
- EngineCommands.swift: +18 (I1 and I2).

**Tests:** about +600-750 lines.
- EngineIDTokensTests: about 150.
- T2-T6, reusing the helpers in EngineFollowBarrier*Tests: about 350-450.
- T7 in the oracle: about +8.
- BenchSync manyMovesTurns and partialMoveTurns, ported from the cycle-20 probes: about +120-160.
- EngineInterestCountsTests: ±2 if setAssets goes.

**Effort:** one fixer cycle. A release SyncBenchmarks run of about 4 minutes at load ≤ 10, with the commit window checked first, gates the merge.
