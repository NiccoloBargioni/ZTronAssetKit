# F3b review: routes A and B for the purge cases route C does not reach (independent reader, P4)

Read-only, at `9aa337c` (`.worktrees/s3f`). Nothing was built, run or measured for this review, and I wrote neither route.
- *Measured* figures cite the draft (`docs/adr-drafts/s3f.md`, "s3f:"). Every other figure is an *estimate*, with its basis beside it (G2).
- Paths are under `Sources/ZTronAssetSync/Engine/` unless given in full. "Rulings :n" is `.build-orchestrator/s3-rulings-s3f.md`; N6-N22 are in `s3-r28-orchestrator-rulings.md`; "f3" and "f3r" are `f3-purge-route.md` and its review; "A §n" and "B §n" are the two routes.
- SDK lines: the macOS 27.0 and iOS 27.0 `Swift.swiftinterface` (arm64e), read this session. `Dictionary.Values`' `formIndex(after:)` and `subscript(position:)` `_modify` are at :8034-8060 in both.
- Process: some early read-only shell commands of this review ran after a `cd` into `.worktrees/s3f` subdirectories, against the task's rule. They only read files and wrote nothing; every later command used `git -C` or absolute paths.

## 0. Verdicts

- **Route A: CORRECTED.** A-1 and A-3 give today's answers in both orders (§1). Two parts are wrong:
  - A-2's one-kept-interest rule leaves in-letter kept shapes at 9-14 ms, and A does not list them (A2).
  - A-5 narrows (b) for a job that a claim *keeps*, which breaks R-SYN-3 (A1).

  Its records are the better ones: `queuedAt`, the docs that say "user waiters re-queue", and three ungated shapes, one of them at about 0.5 s.
- **Route B: CORRECTED.** B-1 to B-5 give today's answers, and B′ keeps (b) unnarrowed. But B reads "none of the five" as covering the bar, and it misses the ungated shapes, `queuedAt`, the docs, and two records that its rebuild needs (§3).
- **Both:** A-1's and B-4's removal of a token's whole registry row rests on a token-lane property. `invariantViolations` checks that property only for job interests (must-fix 1).
- **Chosen: a merge.** It takes route B's structure (B-1, B-2, B-3 with B′, B-5), route A's A-1 in place of B-4, and route A's records, corrected as §5 says. By estimate it closes N7's five cases, two of them only at route C's stage C, as both routes say. Three in-letter shapes stay open, with estimates that reach well above 10 ms (§7).

## 1. What holds (checked against the code)

- **The settle skip is exact apart from N9.** A kept job whose lane the purge leaves unchanged reaches `relane` only through `settleRemoval` (`EngineJobs.swift:424-438`). There a `.queued` user job is re-queued (`:312`). A `.downloading` job returns on equal lanes, a `.blocked` one needs `after > before`, a non-user `.failed` job is untouched, and a verifying or committing job is a no-op (`:304-374`). Both routes keep the `.failed` user arm (`:360-365`) on today's path, as N9 requires.
- **The queue kind cannot change.** `queueKind` reads the lane and `isSingleUser` (`:535-544`), and no user-lane interest is ever withdrawn (`EngineState.swift:1135`).
- **Under `.all`, removing a prefetch group's whole registry row reaches today's end state** (given must-fix 1's property).
  - The joins clause is an equality, last writer wins (`EngineCommands.swift:2219-2224`, `:2256`). A row and its event are written in one synchronous stretch (`EngineJobs.swift:131-133`, `EngineFollow.swift:1288-1290`).
  - Every join is still marked in the first turn (`EngineFollow.swift:1832-1845`), so RR-5 (rulings :1140) and the bench's `liveAfter == 0` (`Tests/ZTronAssetKitBenchmarks/BenchSyncCycle22Purge.swift:44`) hold. A marked join whose row is gone stops at `withdrawJoinInterest`'s guard (`EngineCommands.swift:1130-1132`).
- **Emptying `pending` first makes every later drop a no-op.** `Group.dropMember` resumes only an `.ensure` group (`EngineState.swift:1381-1391`), `kind` and `lane` are `let` (`:1339-1341`), and no drop touches the claims (`EngineJobs.swift:695-700`).
- **A rebuild with one kept interest equals the in-place removal,** `IDTokens` included, since each id then has one holder. With more kept interests, only `IDTokens.first` and the table's iteration order differ (B3).
- **Pass 1 needs no order audit.** Its visits retire, re-queue and abandon nothing. The sorted visits' callees (`EngineFailures.swift:1026-1094`, `EngineReadmission.swift:197-217`) read a pass-1 job's lane and state, and pass 1 changes neither. A finds one interleaving, inside N9's class: a later retirement unblocks a pass-1 job, which today's later visit re-queued a second time.
- **The skip makes the two orders agree** (A §4). When the joins wait for the follow, the jobs hold only waiters, so today re-queues nothing in that order either (`EngineCommands.swift:1040-1042`).
- **No await is added, no clock is read, and no job leaves outside `retire`** (§7.1). The quoted figures (s3f:7584, :7617-7621, :7728-7738), the ruling lines and B's SDK lines are correct.

## 2. Route A, traced

- **A1 (A-5; must-fix 2).** A-5's "(b) holds as option (i) narrows it" carries f3r's narrowing over to a job that is kept. Option (i)'s reason, "re-queues an entry that the same step retires" (f3r must-fix 3(i)), holds only where C-2 retires the job.
  - **The shape.** A `.queued` job loses a `.prefetch` interest, then a `.bulk` one, while a claim holds it. Today re-queues it into the bulk queue before the hold (`EngineCommands.swift:1051-1056`). A-5 leaves its entry in the prefetch queue while its lane reads `.bulk`.
  - **The result.** The gate reads the job's own lane (`EngineDispatch.swift:505`), but the pump pops by queue kind, prefetch before bulk (`:337-340`, `:350-358`). So the bulk-lane job starts ahead of every bulk job and of the prefetch jobs queued behind it, and bulk aging never sees it (`:335`). That breaks R-SYN-3's lanes (`SPEC.md:228`): blocking under S3-R16 1(b), not a place difference.
  - No invariant sees it: `EngineCommands.swift:2139-2147` asks only that a valid entry waits in some queue. B's J-Cc fails on it.
- **A2 (A-2's rule; must-fix 3).** "Only when exactly one interest is kept" sends a job with two kept interests to today's per-interest removal. A lists neither of these shapes:
  - a user waiter and a prefetch waiter under two groups, about 11-14 ms (two removals at f3r's 0.6-0.7 µs each without the drop, plus the pass);
  - a shared job with a user-lane group, a waiter and two groups, about 9-10 ms (20,000 pair releases at about 0.45 µs each, derived from sharedJobFourGroups' 17.82, s3f:7732).

  A's reason is the table order that delivery reads (`EngineJobs.swift:737`), but that order is already an accepted one (`:730`, S3-R16 item 2). B-2's pair rule closes both shapes.
- **A3.** Running A-3 under every scope puts the pass on `oneGroupScope`, which has no job it can skip. A's "+0.1-0.3 ms" is below the pass's own 0.3-0.8 ms (B §3). The pass should run under `.all` only.
- **A4 (kills).** `purgeDropsGroupMembers` (`EngineRegressionRound2Tests.swift:295`), `purgeTakesItsRetiredJobsRetryDeadlinesOut` (`EnginePurgeWithdrawalTests.swift:141`) and A-5's killers (`:83`, `:99`) all purge `.scope`, so none reaches an `.all`-only branch. A-1's "pending take dropped" mutant is then killed only by f3r must-fix 2's `.all` test and the model variant. T-A2 names no non-user waiter, so the kind arm of the kept filter has no stated killer.
- **A5.** A-3's pass cites no SDK lines and says nothing about a retained `indices`, which per f3r should-fix 5 makes the first `_modify` copy the table. B-3 has both.
- **A6.** A's answers table marks `fourGroupJoins`' joined order "(not reached)". In fact, followed first, O keeps its waiter and loses 40,000 pairs (B §4): today's per-pair path, about 17 ms by sharedJobFourGroups' 17.82 (s3f:7732). A-2 does rebuild O, so only the record is wrong.
- **A7 (process).** A §0 records four commands run with the shell inside the worktree, against its rules. It says they wrote nothing.

## 3. Route B, traced

- **B1 (must-fix 5).** B §10's "none of the five stays above 8.5 ms" is true of N7's cases only. The bar is "any mix with at most 4 interests on every id" (rulings :887), and class C keeps three in-letter shapes whose estimates reach above 10 ms (§7), the failed-user one at about 0.5 s (A §9, derived). B names none of them.
- **B2 (must-fix 4).** B's N9 record names the ticket and the place. The skipped `enqueue` also leaves `queuedAt` (`EngineJobs.swift:568`, read only by bulk aging, `EngineDispatch.swift:335`) and `lastTicket` (`:570`) unchanged. Class B also drops `settleRemoval`'s `notifyObservers` (`EngineJobs.swift:437`), which N9 does not cover.
- **B3 (must-fix 3).** A rebuild that keeps two or more interests also changes the order `resolveAll` delivers in (`EngineJobs.swift:737`), not only `IDTokens.first`. And a kept interest that is copied, not moved, shares its id set with the storage on the freeing list, so the next change to it copies the whole set (f3r should-fix 5's point; 0.3-1 ms at 10,000 ids, estimate).
- **B4 (must-fix 8).** B′ leaves two inputs unsaid.
  - Its "lane before the last removal" is the lane of the job's highest-token interest, since the removals run in token order (`EngineState.swift:1135`). Finding it needs a scan of the job's interests; B-1's counts give only the lane before the first removal.
  - Its claim test runs for every emptied job, so the retiring cases pay a `ClaimKey` lookup in pass 1 and another in pass 2, unless the test is skipped when `claims` is empty.
- **B5 (must-fix 7).** B has no docs record. ARCHITECTURE.md:300, sync.md:442 and :966, and the doc comments at `EngineCommands.swift:961-962` and `:991-993` all say "user waiters re-queue", which N9 makes false.
- **B6 (kills; must-fix 6).** B-2's kept filter has no row in the kill table. Its `.all` killers are f3r must-fix 2's test for the lane, and T-B1's J-Cl for the kind (a withdrawn bulk waiter would retire J-Cl).
- **B7 (cost).** For `oneMemberGroupsFourPerID`, B adds "+30,000 count-0 drops". Under `.all` the job walk makes no drop (C-3's rule; B-2 "drops no member"), so B's figure is 0.6-1.1 ms high (estimate).
- **What B has and A lacks:** the waiter counts and B′ in the core, with (b) unnarrowed; pass 1 under `.all` only, with SDK lines and the `indices` rule; a slice cap by entries; J-Cc and J-Cf; and `fourGroupJoins`' followed-first order.

## 4. Costs, re-derived (ms; all estimates)

- **S** is the measured `userWaiters` (6.82 at s3f:7618; 6.83 at :7735). f3 §1 splits it into a 2-3.5 ms sort and 0.4-0.5 µs per job.
- **Per job:** a pass-1 visit costs 0.03-0.08 µs (S less the hash, the allocation and the misses; B-3's probe checks it), a one-kept rebuild 0.2-0.43 µs (f3r "must add" 6), and C-2′'s claim arm 0.15-0.41 µs.
- **Per join,** once its row is gone: 0.04-0.09 µs in a bucket and 0.06-0.13 µs in the queue. Today's 0.28-0.46 µs fits 4.99 ms at 9,216 joins (s3f:7737), with 0.8-2.4 ms of other work.

| Case | A | B | Re-derived (merge) | Basis |
|---|---|---|---|---|
| keptUnderThreeGroups, joined | 3-6 | 3.1-6.2 | 2.6-6.2 | 10,000 × (pass + rebuild + append), plus 0.1-0.8 fixed; no sort |
| keptUnderThreeGroups, waiting | 1.8-5 | (not given) | 1.6-5.5 | 30,000 joins + 10,000 class-A visits + fixed |
| fourGroupJoins, bucket / queue | 2-5 / 2.7-7 | 2.4-5.8 | 1.9-6.0 / 2.7-7.6 | 40,000 joins, plus 0.3-2.4 (B's rest, from the measured 4.99) |
| fourGroupJoins, followed first | "(not reached)" | rebuilt | 0.5-2 | one rebuild; its 40,000 pairs are freed later (B-5) |
| pendingClaimGroups | 2-4.6 (with A-5) | 3.0-6.0 | 2.0-6.0 | 10,000 × (pass + claim arm + append) + fixed. Sorted, without B′: 6.6-12.9 (B's figure; A's 4.6-9.8 leaves out the sorted read) |
| mixedLaneGroups, stage A / B / C | 5-10.5 / 4.5-8.5 / 2-5 | 5.4-12.4 / 4.3-8.1 / 2.1-4.3 | 5.4-12.4 / 4.3-8.5 / 2-5 | route C with option (i) at k = 2, plus pass 1 at stage A |
| oneMemberGroupsFourPerID, stage A / B / C | 6-12.5 / 5-10.5 / 3-7 | 6.8-14.7 / 5.7-11 / 3.5-7.2 | 6.1-13.6 / 5-10.5 / 2.9-7 | f3r's 8-16, less C-3's 2.6-5.0, plus A-1's 0.4-1.2 and the pass; B's figure less B7 |
| userWaiters, ensures | 0.4-1.1 | 0.6-1.6 | 0.4-1.6 | class A only |

The two routes agree within their spreads. A's figures are lower where A leaves out the sorted read (f3r should-fix 2) or the pass.

## 5. Must fix (for the chosen route)

1. **The token-lane clause must cover waiting joins, bucket joins and owed items.**
   - **Evidence.** `EngineCommands.swift:1797-1807` loops over `state.jobs` only, though its comment says that every join and re-route passes the lane on. A join takes the lane and kind its caller passes (`EngineJobs.swift:127-133`, `:140`). `owedRerouteViolations` (`EngineCommands.swift:2156-2181`) checks an owed item's owner and place, not its lane or kind.
   - **Why it matters.** A-1 removes a prefetch group's whole row. A join in that row at a user lane, or of another kind, would then join nothing at the drain (`EngineFollow.swift:981-985`), and the answer would differ. f3r's "What holds" cites :1800-1807 for joins and owed items too, but the clause does not check them.
   - **Correction.** In the id-level F-1 clause's commit, `followBarrierViolations`' walk (`:2225-2255`) and `owedRerouteViolations` check that each waiting join, bucket join and owed item of a group's token carries the group's `lane` and `kind`, and that any other token's carry the one lane its job interests carry.
   - **Test.** A seam that defers a join at another lane kills the clause's drop-mutant 2/2 (S3-R19 item 3). A red test is a finding, and A-1 is then not made.
2. **B′, not A-5.**
   - A claim-held job takes C-2′ only when its lane before the first removal equals its lane before the last.
   - Option (i)'s narrowing of (b) applies only where C-2 retires the job in the same step. That also settles how route C's C-2′ reads "whose (b) holds" (N6).
   - A claim-held `.queued` or `.downloading` job whose lane falls takes today's pre-relane (`EngineCommands.swift:1051-1056`). J-Cc pins it.
3. **B-2.**
   - Keep the rule: rebuild when the kept pairs are no more than the purged pairs, and remove in place otherwise.
   - Before the old table goes to the freeing list, move each kept interest out of it (one `removeValue(forKey:)`, one token hash).
   - Record two differences under S3-R16 item 2: the table's order, which `resolveAll`'s delivery reads (`EngineJobs.swift:730-737`), and `IDTokens.first`.
4. **N9's record and the notification.**
   - The record names the ticket, the place, `queuedAt` and `lastTicket`.
   - P-N9 uses T-A1's set-up: jobs queued in the order a, b, c, with keys that sort c < b < a, and the one slot held. In both orders it asserts the answers and each job's start count (N9), and it records the start order.
   - One `notifyObservers` per class-B and class-B′ visit stays, as `settleRemoval` made it, unless 12.5.15's extended audit records that no purge suite needs it. With no observer, a call costs two `isEmpty` checks (`EngineCommands.swift:1736-1754`).
5. **Coverage.** The draft lists §7's open shapes with their figures, marked "in letter, not gated" until the ruling gates them.
6. **The kill table.**
   - **B-2's lane and kind filters:** f3r must-fix 2's `.all` test, and T-B1's J-Cl.
   - **A-1's mutants:**
     - the `.all` gate: T-A-SCOPE and T-B3b;
     - the lane filter, and the row removed for every token: T-B3's user-lane prefetch group and waiter (a prefetch group's lane is the caller's, `EngineCommands.swift:221`);
     - pending take dropped: must-fix 2's test and the model variant;
     - the row not removed, and the kind filter: Equivalent, recorded (an `.ensure` group is always user-lane, `:737`).
   - **N14's `:1001` mutant** (`.all` answers false). After A-1 the drain finds no row for a group's join, so a test that asserts only the answers no longer kills it. T-B3 kills it (it asserts the flags and holds a system join), and so does any `.all` test that asserts the invariants (the joins clause, `:2256`).
   - **The new clause's mutant:** item 1's seam test. A `.scope` test is cited only for a branch it reaches, and T-B2 keeps a non-user waiter.
7. **Docs.** Propose under S3-R6 the text "a kept job re-queues only when its lane changes, and a failed one is re-admitted" for ARCHITECTURE.md:300, sync.md:442 and :966, and the two doc comments. Record for the doc pass that §7.1's "Every interest removal … goes through `removeInterest`" already does not hold for the purge (B §8.5).
8. **B′'s inputs.** The lane before the last removal is read from the job's highest-token interest, in one scan of its interests (at most 4 in letter). The claim test is skipped when `claims` is empty.

## 6. The chosen route, in order (fixer hours are estimates, at f3:336's rate)

Each part is its own commit, with every suite green, under item 1's exclusivity rule: `applied`, the request and `claims` are read into locals, and every write outside the job comes after the job's access.

The order puts item 3b inside route C's stages, not in N19's "natural place" after them. A-1 replaces C-3 rather than following it, C-5 takes pass 1 as its collection, and N8's triggers then read figures that include pass 1.

1. **M-0, with route C's id-level F-1 clause** (1.5-2.5 h): must-fix 1's clause and its seam test. §7's shapes get 'before' figures on a scratch copy of `9aa337c` (N12), in step 0 after item 3's five cases (N22 item 1), or at item 3b's first step if step 0 is done.
2. **M-1 = A-1, as C-3's commit in stage A** (1-2 h beyond C-3's own).
   - Under `.all`, before `withdrawPurgedJoins` (`EngineCommands.swift:1016`), one in-place pass over `groups` moves the `pending` of each `.prefetch` group below `.userInitiated` to A2.3's freeing list, and its row too when `joinsAfterFollow` is not empty.
   - The joins walk is unchanged, and under `.all` the job walk makes no drop. B-4 is not made.
3. **Route C's stage A ends as ruled,** with C-2′ read as must-fix 2 says.
4. **M-2 = B-1** (1-1.5 h): `prefetchWaiters` and `bulkWaiters` join `InterestCounts`, and the recount clause covers them.
5. **M-3 = B-2** (2.5-3.5 h, with T-B2): a `Job` mutator for `.all` only, corrected by must-fix 3.
6. **M-4 = B-3** (4.5-7 h, with the probe, T-B1 and P-N9), corrected by must-fixes 2, 4 and 8.
   - B's classification probe comes first. Above 1.5 ms, §4's pass-1 rows do not hold.
   - Pass 1 handles classes A, B and B′. Pass 2 visits class C in sorted order: route C's C-2 or C-2′, or, for a kept job, B-2 and today's settle.
7. **M-5 = B-5** (1.5-2.5 h, with T-B4).
   - A2.3's slices also take A-1's maps and B-2's storages. Each slice frees at most 512 units or 16,384 entries, and a larger map is freed alone.
   - Shutdown drains the list in slices. The REENTRANCY rows are B §7's.
8. **Then every purge case is measured,** and N8's triggers decide stages B and C. C-5 takes pass 1 as its collection, and stage C keeps A7's audit.

**Other work:** the audit's extension, the inventory rows, the N9 and §7 records and the docs proposal, 2-3 h; about 15 mutants in both orders (step 6, N13) and the 17 cases with §7's shapes, best of 3, 3-4.5 h.

**Hours.** The core is 17-26.5 h, not counting route C's 19-28 h (f3:363). Routing §7's shapes would add 3.5-5.5 h (A-6 with an in-place re-admission) and 2-3 h (an in-place re-queue).

**It closes, by estimate:** `keptUnderThreeGroups` in both orders; `fourGroupJoins` in both containers and followed first; `pendingClaimGroups`; `mixedLaneGroups` at stage B (its top at the edge) or at stage C; `oneMemberGroupsFourPerID` at stage C; and A2's two-kept and shared-kept shapes. **It leaves open:** §7's rows.

## 7. What it leaves open (in letter, ungated; estimates)

| Shape | After route C and the merge (ms) | What would close it |
|---|---|---|
| Failed user jobs with `.retry` deadlines, under one to three prefetch groups | About 500 if the origin admits a user request (`EngineJobs.swift:360`); 9-18 otherwise, on the sorted path | A-6 brings it to 11.5-18 (A §9): C-1's pass also takes a `.retry` whose job is not `.failed(.at)`, which its firing ignores (`EngineTimers.swift:111`). An in-place re-admission brings it to 7-12. Going lower needs table order, which needs a ruling |
| A bulk waiter under three prefetch groups (the lane falls) | 9-17 (A: 9-14.5) | An in-place re-queue: 7-11.5. Table-order re-queues after an A7-type audit: 4.5-8 (A §9) |
| A prefetch group and a bulk group, under a third group's pending claim | 10-20 | As in the row above. Skipping that re-queue breaks R-SYN-3 (must-fix 2) |
| `fourGroupJoins` over 40,000 one-member groups | 3-11.5 (A-1's pass over 40,000 groups, plus the joins) | Measure it as a variant |
| Three kept interests over one purged interest (B-2 in place) | 4.5-8.9 | Measure it as a variant of `keptUnderThreeGroups` |

- **The failed-user figure is derived:** (571.12 − 36.24) ms / 10,000 ≈ 53 µs per heap scan (s3f:7584, :7617), as in A §9. It is today's cost too; item 3b does not add it. Whether the origin admits the request depends on the breaker, and the timeouts in `retryJobs` (`BenchSyncCycle22Purge.swift:201-204`) leave the jobs `.failed(.at)`.
- **None of these shapes needs e2-B′.** Each can be closed within one turn, by an in-place re-admission or re-queue, then by table order after an A7-type audit. None of these is authorised.

## What the ruling must say

1. **Item 3b is §6's merge, placed inside route C's stages** (amending N19's "natural place"). M-1 (A-1) is C-3's commit in stage A, M-2 to M-5 follow stage A, and N8's triggers read the figures after M-5. A-5, A-3b, B-4, A-4, J-TRUE, B-L, B-G, B-J1 and e2-B′ are not made.
2. **M-0 comes first.** Together with the id-level F-1 clause, the token-lane clause covers waiting joins, bucket joins and owed items: a group token's lane and kind, and any other token's single lane. It has a seam test. A red test is a finding, and A-1 is then not made.
3. **A-1 runs under `.all`, before `withdrawPurgedJoins`.** Each `.prefetch` group below `.userInitiated` gives its `pending` and its row to the freeing list. Every join is still marked in the first turn (RR-5), and the job walk makes no drop.
4. **B-2 rebuilds when the kept pairs are no more than the purged pairs,** moving each kept interest out, and removes in place otherwise. The counts and the index equal their recount. The table's delivery order and `IDTokens.first` are recorded under S3-R16 item 2.
5. **Pass 1 runs under `.all`, in table order, for classes A, B and B′.**
   - This amends rulings :1169, :1175 and :1188 for those classes, with no A7 audit. 12.5.15's audit is extended to pass 1 and to the callee argument.
   - Pass 1 inserts and removes no key (a debug check), keeps no `indices`, and cites both SDKs. The probe runs first. Class C stays sorted.
6. **N9 is restated.** The purge may skip the whole settle of a kept job whose lane it leaves unchanged and that is not `.failed` at the user lane, while item 1b holds (N9, N20).
   - The record names the ticket, the place, `queuedAt` and `lastTicket`.
   - P-N9 asserts the answers and the start counts in both orders. One `notifyObservers` per visit stays, unless the audit says otherwise.
7. **B′ requires the lane before the first removal to equal the lane before the last.** Option (i)'s narrowing applies only where C-2 retires the job. A claim-held job whose lane falls takes today's re-lane (R-SYN-3).
8. **B-5's slices free at most 512 units or 16,384 entries,** and a larger map is freed alone. They include A-1's maps and B-2's storages, are pinned with their slices recorded, and are drained in slices at shutdown, with their REENTRANCY rows.
9. **Tests:**
   - T-B1 (with J-Cc and J-Cf), T-B2 (with a non-user waiter), T-B3 and T-B3b in both orders, T-B4, P-N9, the clause's seam test, and the `.all` model variant with waiting joins;
   - §5's kill table, including N14's `:1001` row, 2/2 in each order that reaches each branch;
   - no committed test is changed (G3).
10. **§7's first three shapes are gated as cases, with their 'before' figures taken first** (N22 item 1). The three variants are measured. No route for them is authorised.
    - A shape that cannot come under 10 ms by §7's estimate is a stop under N22 2(b) at once: the failed-user shape, if its origin admits users. The orchestrator takes it to the owner with the evidence and §7's options (N22 item 4).
    - The others are judged after item 3b's last part.
11. **Docs:** must-fix 7's S3-R6 proposal for ARCHITECTURE.md:300, sync.md:442 and :966 and the two doc comments, and the §7.1 note for the doc pass. There is no §7.1 removal amendment.
12. **Every purge case is judged after item 3b's last part,** best of 3, with loads. Every figure here is an estimate. N22 2(c) reads §4's merged column and §7's figures, and N22 2(e) reads §6's hours for each part. The core is 17-26.5 h.
