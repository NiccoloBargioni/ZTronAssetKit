### S3-R28 item 3b (appended 2026-11-06): the purge cases route C does not reach

**Item 3b** routes, in one turn, the purge cases that route C does not reach. By estimate it closes all five of item 3's new cases, two of them only at route C's stage B or C, and the three in-letter shapes it leaves open are known misses by the owner's ruling (N25; 3b.5). It is the f3b review's merged route: route B's structure, route A's A-1 in place of B-4, and route A's records, as the review corrects them. Where this item and items 1 to 8 differ, this item decides, except for the owner's ruling on those shapes, which item 3 carries and this item follows. It binds the fixer from the first step that starts after it is appended (item 6), and the cycle-23 verifiers for that work (the header).

Where to find things:
- **The analyses**, in `.build-orchestrator/s3f-c22-analysis/`: `f3b-route-a.md` and `f3b-route-b.md`, with their review `f3b-review.md`, which finds both routes CORRECTED. The header's rules for reading the analyses apply.
  - The review's "What the ruling must say" points 1 to 12 bind as written, except that N25 makes point 10's three shapes known misses (3b.5). Its must-fix items 1 to 8 bind as this item carries them.
  - Below, "point n", "must-fix n" and "§n" are the review's, and "A §n" and "B §n" the routes'. A-n and B-n are the routes' parts, M-0 to M-5 the merge's, and "f3r" is `f3-purge-route-review.md`.
  - The review's N-numbers are the orchestrator's notes behind this ruling. Its N6 and N9 are item 3's option (i) and re-lane paragraphs, N8 is item 3's stage trigger, N19 is items 5 and 6's rules for appended items, and N22 is item 8. N25 is the owner's ruling that three purge shapes are known misses, and item 3 carries it (rulings :1435).
- **Lines** are at `9aa337c`, and paths are under `Sources/ZTronAssetSync/Engine/` unless given in full. Every figure not marked measured or derived is an estimate (G2). A measurement decides.

1. *The merged route, inside route C's stages* (points 1 to 5 and 8). Each part is its own commit, with every suite green, under S3-R27 item 1's exclusivity rule: `applied`, the request and `claims` are read into locals, and every write outside the job comes after the job's access.
   - **M-0, in the id-level F-1 clause's commit** (stage A; point 2, must-fix 1). The token-lane clause (`EngineCommands.swift:1797-1807`) walks `state.jobs` only. A-1's removal of a token's whole row rests on the same property for joins and owed items (`EngineFollow.swift:981-985`).
     - `followBarrierViolations`' walk (`EngineCommands.swift:2225-2255`) and `owedRerouteViolations` (`:2156-2181`) check that each waiting join, bucket join and owed item of a group's token carries the group's `lane` and `kind`, and that any other token's carry the one lane its job interests carry.
     - A seam that defers a join at another lane kills the clause's drop-mutant 2/2 (S3-R19 item 3).
     - A suite test that the clause turns red is a finding (S3-R16 1(b) if its state is real) and a stop under item 8 2(c). A-1 is then not made, and C-3 stays as item 3 rules it.
   - **M-1 = A-1, as C-3's commit in stage A** (point 3). It rewrites C-3, and it fixes C-3's place in the turn, which item 3 leaves open. If item 3's F-1 rule stops C-3, A-1 goes with it. M-3, and M-4's class B, go with them: they wait for the orchestrator's ruling on that stop (item 8's point 3).
     - Under `.all`, before `withdrawPurgedJoins` (`EngineCommands.swift:1016`), one in-place pass over `groups` moves the `pending` of each `.prefetch` group below `.userInitiated` to e2-A2.3's freeing list, and the group's `joinsAfterFollow` row too when that map is not empty.
     - The joins walk is unchanged. Every join is still marked in the first turn (RR-5, rulings :1140), and a marked join whose row is gone stops at `withdrawJoinInterest`'s guard (`:1130-1132`). Under `.all` the job walk makes no drop.
   - **Stage A then ends as item 3 rules it,** with C-2′ read as 3b.4 says, and with its figures.
   - **M-2 = B-1.** `InterestCounts` (`EngineState.swift:1218-1280`) gains `prefetchWaiters` and `bulkWaiters`, and the recount clause (`EngineCommands.swift:1811-1814`) covers them.
   - **M-3 = B-2** (point 4, must-fix 3). A `Job` mutator, for `.all` only, withdraws a kept job whole: every interest below `.userInitiated` that is not a waiter's.
     - It rebuilds when the kept (token, id) pairs are no more than the purged pairs, and removes in place otherwise. Before the old table goes to the freeing list, each kept interest is moved out of it (one `removeValue(forKey:)`). A copy would share its id set with the freed storage, and its next change would copy the whole set.
     - The counts and `tokensByID` equal their recount. It returns the removed storage, the system ids, the run's flag, and the lanes before the first and the last removal (rulings :1169). It drops no member, because A-1 has emptied the prefetch groups' `pending`, or C-3 has when M-0 stops A-1.
     - The pair rule replaces A-2's one-kept rule, which left two in-letter shapes at 9-14 ms (§2 A2).
   - **M-4 = B-3** (point 5; must-fixes 2, 4 and 8). Two passes over the jobs, under `.all` only; other scopes keep route C's path. B's classification probe comes first: it times the classification over `userWaiters`' 10,000 jobs (B §2).
     - **Pass 1** runs in table order, in place, through `values[i]`'s `_modify`, with `startIndex` and `formIndex(after:)` and no retained `indices`. It inserts and removes no key (a debug check). It cites `Dictionary.Values` in both SDKs' `Swift.swiftinterface` (:8034-8060 in macOS 27.0 and iOS 27.0; C7).
     - It skips class A (nothing to withdraw, by M-2's counts). It runs B-2 with no settle for class B (kept, its lane unchanged, and not `.failed` at the user lane; 3b.3), and C-2′ for class B′ (emptied and claim-held, its two lanes equal; 3b.4). It collects the keys of class C: a retirement, a due re-lane, or a job `.failed` at the user lane.
     - **Pass 2** visits class C in sorted order: route C's C-2 or today's path, and, for a kept job, B-2 then today's settle.
     - M-4 replaces the key sort (`EngineCommands.swift:1019`) for classes A, B and B′, and amends rulings :1169, :1175 and :1188 for them, with no A7 audit. C-2′ moves into pass 1 (B §8.4).
   - **M-5 = B-5** (point 8). e2-A2.3's slices also take A-1's maps and B-2's storages. A slice frees at most 512 units or 16,384 entries, and a larger map is freed alone. They stay pinned, with their slices recorded, and shutdown drains the list in slices. This amends item 3's "slices of 512".
   - **Then every purge case is measured** (3b.6). Item 3's stage trigger reads these figures, not stage A's, and this replaces item 3's fork after stage A. C-5 takes pass 1 as its collection, and stage C keeps A7's audit.
   - **Not made:** A-5, A-3b, B-4, A-4, J-TRUE, B-L, B-G, B-J1 and e2-B′.
   - **Item 5's order.** This amends item 5's "natural place" for item 3b, after route C's stages. Step 2 is stage A, with M-0 and M-1 inside it, and its figures; then M-2 to M-5, and every purge case's figures. Step 3's stages follow from those.
   - **Parts already committed.** `9aa337c` has no part of route C, and step 2 waits for item 3b (item 3). If C-3, or a C-2′ that reads (b) narrowed, is committed when item 3b is taken, a new commit rewrites it as M-1 or 3b.4 says, and its kills re-run on the new code (12.5.6's rule). History is not rewritten.

2. *Tests, red first, and the kills* (point 9; must-fix 6).
   - **Red first.** T-B1 is committed red on J-B's ticket right before M-4, once P-N9 has passed on M-4's uncommitted code. If P-N9 shows a difference, the J-B row is not committed, and the stop follows (3b.6). T-B4 is committed red on its slices right before M-5. M-0's seam test lands with its clause. Every other assertion passes on `9aa337c` and pins today's answers (B §5). Each commit message names the cases red at it (item 5).
   - **The tests,** in both orders wherever a follow is owed, land with their parts. No committed test is changed (G3).
     - M-0: its seam test.
     - M-1: T-B3 and T-B3b (B §5 items 5 and 6), and f3r must-fix 2's `.all` model variant, extended with waiting joins, so that the F-1, joins and token-lane clauses are checked after A-1 on random states (A §5).
     - M-3: T-B2 (B §5 item 4), with a non-user waiter.
     - M-4: T-B1 (B §5 item 3), with J-Cc and J-Cf, and P-N9 (3b.3).
     - M-5: T-B4 (B §5 item 7).
   - **The kills** run at step 6, with route C's, each 2/2 in each order that reaches its branch. A `.scope` test is cited only for a branch it reaches. Each Equivalent is recorded with its reason (S3-R19 item 2).

     | Branch | Mutant | Killed by |
     |---|---|---|
     | M-0's clause | dropped | its seam test |
     | A-1's `.all` gate | forced true | T-A-SCOPE (`scopePurgeWithdrawsOnlyItsIDs`, `Tests/ZTronAssetSyncTests/Engine/EnginePurgeWithdrawalTests.swift:119`) and T-B3b |
     | A-1's lane filter; its row | dropped; removed for every token | T-B3's user-lane prefetch group and waiter (a prefetch group's lane is the caller's, `EngineCommands.swift:221`) |
     | A-1's `pending` take | dropped | f3r must-fix 2's `.all` test, and the model variant |
     | A-1's row; its kind filter | not removed; dropped | Equivalent: the per-join path removes the row, and an `.ensure` group is always user-lane (`EngineCommands.swift:737`) |
     | `EngineCommands.swift:1001` | `.all` answers false | T-B3, which asserts the flags and holds a system join, and any `.all` test that asserts the joins clause (`:2256`). After A-1, a test that asserts only the answers no longer kills it: this amends item 4's expected reach |
     | B-1's counts | an update dropped | the recount clause: T-B1's J-Cl, and the prefetch waiter of `purgeKeepsUserLaneAndWaiterInterests` (`EnginePurgeWithdrawalTests.swift:201`) |
     | B-2's lane and kind filters | dropped | T-B2's trimmed job (lane: its two user-lane groups would be withdrawn, failing its interests and its answers); T-B1's J-Cl and T-B2's non-user waiter (kind: a withdrawn bulk waiter would retire J-Cl, and T-B2's waiter would lose its interest) |
     | B-2's choice | rebuild or in place, forced | Equivalent: the same contents, with the order differences recorded (3b.8) |
     | class A | forced true; forced false | T-B1: J-B keeps its groups; Equivalent, cost only |
     | class B's lane test | forced true; forced false | T-B1's J-Cl and J-Cd; T-B1's J-B ticket |
     | class B's `.failed` test | forced true | T-B1's J-Cf |
     | class B′ | its lane test forced true; B′ forced false | T-B1's J-Cc; Equivalent, since pass 2 reaches the same end state |
     | pass 1's key rule | a class-C job retired in pass 1 | the debug check, and the stale index's trap (SDK :8054-8060; f3r must-fix 1) |
     | M-5's slices | dropped, or run in the turn | T-B4's recorded slices (rulings :1187) |

     Any other branch a part adds, B′'s `claims.isEmpty` skip among them, is killed 2/2 or classed with its reason (S3-R16 1(e)). B-2's lane killer corrects must-fix 6: after M-4, f3r must-fix 2's `.all` test never runs B-2, since two of its jobs are class A and the third retires in pass 2.

3. *The re-lane skip, restated* (point 6; must-fix 4). This replaces item 3's paragraph on the re-lane of a kept `.queued` job.
   - Under S3-R16 items 2 and 3, the purge may skip the whole settle (`settleRemoval`, `EngineJobs.swift:424-438`) of a kept job whose lane it leaves unchanged and that is not `.failed` at the user lane, while S3-R16 item 1 holds. The `.failed` arm's re-admission (`:359-365`) stays.
   - **What the skip changes** (§1, §3 B2). A `.queued` user job keeps its place, its ticket and `queuedAt` (`:568`, read only by bulk aging, `EngineDispatch.swift:335`), and `lastTicket` (`EngineJobs.swift:570`) does not advance. For every other class-B job the skipped re-lane is a no-op (`:304-374`). The draft records the ticket, the place, `queuedAt` and `lastTicket` under "Residual risks (S3-R16)".
   - **P-N9** runs before M-4's commit, on T-A1's set-up (A §5): jobs queued in the order a, b, c, with keys that sort c < b < a, and the one slot held. In both orders it asserts that the answers and each job's start count equal visit-first's, and it records the start order. M-4's commit message and the draft cite its log. If it shows a difference, the skip is not taken (3b.6).
   - **The notification.** One `notifyObservers` per class-B and class-B′ visit stays, as `settleRemoval` made it (`:437`), unless 12.5.15's extended audit records that no purge suite needs it. With no observer, a call costs two `isEmpty` checks (`EngineCommands.swift:1736-1754`).

4. *Option (i), corrected* (point 7; must-fixes 2 and 8). This amends item 3's option (i) paragraph.
   - Its narrowing of C-2 (b) to a `.downloading` job applies only where C-2 retires the job in the same step. C-2′ reads "whose C-2 (b) holds" unnarrowed: a claim-held job takes C-2′, in stage A's walk and as class B′ in pass 1, only when its lane before the first removal equals its lane before the last.
   - **Why** (§2 A1). Today a `.queued` job that loses a `.prefetch` interest, then a `.bulk` one, while a claim holds it, is re-queued into the bulk queue before the hold (`EngineCommands.swift:1051-1056`). Without that, its entry stays in the prefetch queue while its lane reads `.bulk`. The pump pops prefetch before bulk (`EngineDispatch.swift:337-340`), so the job starts ahead of every bulk job, and bulk aging never sees it (`:335`). That breaks R-SYN-3 (`SPEC.md:228`): blocking under S3-R16 1(b).
   - So a claim-held `.queued` or `.downloading` job whose lane falls takes today's pre-relane. T-B1's J-Cc pins it.
   - **B′'s inputs.** The lane before the last removal is read from the job's highest-token interest, in one scan of its interests (at most 4 in letter). The claim test is skipped when `claims` is empty.

5. *The open in-letter shapes are known misses* (N25; point 10 and must-fix 5, as N25 changes them). The first three rows of §7 are out of cycle 23, by the owner's ruling:
   1. failed user jobs with `.retry` deadlines, under one to three prefetch groups: about 500 ms if the origin admits a user request (`EngineJobs.swift:360`; derived, 53 µs a heap scan from `s3f.md:7584` and `:7617`), and 9-18 ms otherwise;
   2. a bulk waiter under three prefetch groups: 9-17 ms;
   3. a prefetch group and a bulk group, under a third group's pending claim: 10-20 ms.

   - **Not blocking, not gated.** No code, test or bench is added for them, and the verifiers do not report them as blocking. Every other shape stays under S3-R27 12.1's bar (rulings :887). T-B1's J-Cf, J-Cl and J-Cc stay, since they pin the answers of classes C and B′, not those shapes' cost.
   - **The record.** The draft records each one under "Known misses of C2's 10 ms limit (owner ruling 2026-11-06)", with:
     - its shape;
     - its figure, labelled "derived" or "estimate", with its derivation and citations;
     - what would close it (§7, and f3c with its review, 3b.7);
     - the owner's re-open criterion: how often the miss happens in the field.
   - **Route A §9's three shapes.** Its first two are shapes 1 and 2 above. Its third, a prefetch waiter under three groups, is class B: M-4 routes it, and A-3b is not made.
   - **The two variants** (§7 rows 4 and 5) are measured as variants of item 3b's cases, not gated: `fourGroupJoins` over 40,000 one-member groups (3-11.5 ms), and three kept interests over one purged interest, B-2 in place, as a variant of `keptUnderThreeGroups` (4.5-8.9 ms).
     - Their 'before' figures come in step 0, right after item 1's shapes and before item 3's five new cases (item 8's "riskiest first"), on a scratch copy of `9aa337c` under `.build-s3f/c23/`. This amends item 5's step 0 and item 8's order. If step 0 is done when item 3b is taken, they come first at item 3b's first step.
     - They are measured again with every purge case after M-5. There, a miss among them, or a figure above its estimate's upper end, is a stop under item 8 2(c), reported to the owner.
     - The draft lists them "in letter, not gated", with their figures.

6. *Judging, and the stops* (item 8; points 10 and 12). Item 8's stop conditions are checked at the end of every M-part and every measurement, and a stop follows item 8's 3 and 4.
   - **Judging.** Every purge case is judged after M-5, best of 3, with loads, or after the last stage that item 3's trigger fires for it. Item 3's decision rule applies, and a miss after item 3b's route is blocking, with no route in cycle 23 (item 3).
   - **2(b).** After stage A, M-2 to M-5 count as later parts, with the table below as their estimate.
   - **2(c)** reads the table below and the variants' figures (3b.5).
     - Each column is read only at the point it names. At stage A's figures, 2(c) reads item 3's estimates, and a case that only M-2 to M-5 move is checked there under 2(b) alone.
     - It also covers a test that M-0's clause turns red (3b.1), the classification probe above 1.5 ms (the table's pass-1 rows then do not hold), and a difference in P-N9 (3b.3).
   - **2(e)** reads 3b.9's hours for each part.

   | Case (§4, merged; estimates) | After M-5 (ms) | After stage B / C (ms) |
   |---|---|---|
   | `keptUnderThreeGroups`, joined / waiting | 2.6-6.2 / 1.6-5.5 | |
   | `fourGroupJoins`, bucket / queue / followed first | 1.9-6.0 / 2.7-7.6 / 0.5-2 | |
   | `pendingClaimGroups` | 2.0-6.0 | |
   | `mixedLaneGroups` | 5.4-12.4 | 4.3-8.5 / 2-5 |
   | `oneMemberGroupsFourPerID` | 6.1-13.6 | 5-10.5 / 2.9-7 |
   | `userWaiters`, `ensures` | 0.4-1.6 | |

7. *No item 3c* (N25). f3c's analysis and its review (`f3c-open-shapes.md`, `f3c-open-shapes-review.md`) are kept for a later re-open and are not appended. e2-B′ stays unauthorised.

8. *Records* (points 4, 5, 6 and 11; must-fixes 3, 4 and 7).
   - **Under "Residual risks (S3-R16)":** the skip's four (3b.3), with P-N9's log; and B-2's two, under S3-R16 item 2: the table's order, which `resolveAll`'s delivery reads (`EngineJobs.swift:730-737`), and `IDTokens.first`.
   - **Known misses** (N25): 3b.5's record, for ADR-057 and for Stage 5's `RESIDUAL-RISKS.md` and `VERIFICATION.md`.
   - **12.5.15's audit** is extended to pass 1 and to the callee argument, before M-4: pass 2's callees (`EngineFailures.swift:1026-1094`, `EngineReadmission.swift:197-217`) read a pass-1 job's lane and state, and pass 1 changes neither (§1). It also decides the notification (3b.3).
   - **Item 9's inventory** gains rows, each with its figure, for A-1's pass (in place of C-3's), B-2, pass 1 and the extended slices. The classification probe's figure is recorded with step 0's.
   - **REENTRANCY** (B §7). No await is added: RE-S26, RE-S25, RE-S21 and RE-S24 stand (`EngineCommands.swift:964`, `:977`, `:979`, `:1148`). The slices' spawn: "nothing — a slice reads only the freeing list, whose entries no live state references; it re-reads the list's count each slice". Shutdown's drain: "the lifecycle — the list is drained in slices before the store closes". No clock is read and no random number drawn (C4).
   - **Docs** (S3-R6). `docs/ARCHITECTURE.md:300`, `docs/design/sync.md:442` and `:966`, and the doc comments at `EngineCommands.swift:961-962` and `:991-993` say "user waiters re-queue". Propose for all five: "a kept job re-queues only when its lane changes, and a failed one is re-admitted".
   - **For the doc pass:** ARCHITECTURE §7.1's "Every interest removal … goes through `removeInterest`" (`docs/ARCHITECTURE.md:226`) already does not hold for the purge (B §8.5). Item 3b's parts need no §7.1 removal amendment: none removes a job outside `retire` (§1). Item 3's rule for C-2 and §7.1 stands.
   - **The status list** records when item 3b was taken (item 6) and, per purge case, its figures, its loads and whether it retires jobs (item 3).

9. *Fixer hours* (estimates, §6, at f3:336's 1-1.5 h a part). In brackets, 1.5 times each upper end, where item 8 2(e) stops the part (derived).
   - M-0, with the F-1 clause, 2.5-4 h [6]; M-1, with C-3's own, 2-3.5 h [5.25]; M-2 1-1.5 h [2.25]; M-3, with T-B2, 2.5-3.5 h [5.25]; M-4, with the probe, T-B1 and P-N9, 4.5-7 h [10.5]; M-5, with T-B4, 1.5-2.5 h [3.75].
   - M-0 shares its commit with the F-1 clause, and M-1 with C-3. So 2(e) times each with that route C part, at f3:336's 1-1.5 h a part (derived). Route C's 19-28 h already holds those two parts, so the core leaves them out.
   - The audit's extension, the inventory rows, the records and the docs proposal, 2-3 h. About 15 mutants in both orders at step 6, and the 17 purge cases and the two variants, best of 3, 3-4.5 h.
   - **The core is 17-26.5 h,** on top of route C's 19-28 h (f3:363), and item 6's list gains it. Routing 3b.5's three shapes is for a re-open, not cycle 23: §6 puts the parts alone at 3.5-5.5 h and 2-3 h, and f3c puts its core at 12-18.5 h (f3c §9; its review moves A7's audit into the core, not estimated).
