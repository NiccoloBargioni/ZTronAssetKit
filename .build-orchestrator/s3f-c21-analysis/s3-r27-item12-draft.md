12. *The owner's ruling, and the cycle-21 correctness verifier's two new findings.* Where this item and items 1 to 11 differ, this item decides.
    - **Its analyses** are in `.build-orchestrator/s3f-c21-analysis/`: `e1-pin-requeue.md`, with its review `e1-pin-requeue-review.md` (12.2), and `e2-purge.md`, with `e2-purge-review.md` (12.3). The header's rules for reading the analyses apply to them. Below, "must add" n is a review's "What the ruling must add" n, and "must say" n is a report's "What the ruling must say" n.
    - **Names.** R1, A1, A2 and P-1 to P-3 already have meanings here: R1 is S3-R11's (S3-R16 1(a)), `integrate-rr21.md`'s and item 3's; item 3 has d2's A1 to A8, item 4 d3's A1 and A2, and `integrate-c21.md` steps A1 to A13; P-1 to P-3 are SPEC's benchmarks, beside P-13. So, in this item and in the draft's records, e1's and e2's labels carry their analysis: e1-R1; the probes e1-PS, e1-P1, e1-P2, e1-P3 and e1-PR; e2-A1 (e2-A1.1 to e2-A1.7), e2-A2 (e2-A2.1 to e2-A2.6) and e2-B. T-E1 to T-E5 and T-A-SCOPE keep their names. Unprefixed R1, An and P-n keep their earlier meanings.
    - **What in e1's and e2's reviews binds,** extending the header's rule: their must-fix items bind, as this item corrects them. Their should-fix items bind only where this item names them. A report's recommendation, and a review's "must add" items, bind only as this item carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.

    1. **The owner's ruling (5 Nov, 21:15).** To "Should the 10 ms bar cover only 10,000 assets with one subscriber?", the owner answered "Yes, keep it" (`docs/ORCHESTRATION.md`).
       - **The bar,** `c2Budget` at 10 ms, covers only the reference set: 10,000 ids however their interests are grouped, with at most 4 interests on one id as item 4 sizes it, and one subscriber, which may be stalled (S3-R26 answer 4).
       - **Outside the bar:**
         - every shape with more than 4 interests on one id. It includes item 4's list: PROBE-C21-HOLDERS and its padded variants, the `manyHolders*` cases, row 14 on one id (item 2), d3 §2(c) rows 1 to 8 with one hot id, and row 12 with k > 4;
         - a second subscriber (`commitTwoStalledSubscribersTurns`).
       - **Such shapes are recorded** with their figures and loads, as residual risks (S3-R16 item 2), where items 1, 2 and 4 say to measure them. They are neither gated nor blocking, and a verifier does not report them as blocking.
       - **What this changes:**
         - every "open, for the owner" in items 1, 2 and 4 now reads "outside the bar, by the owner's ruling of 5 Nov";
         - item 4's condition, that the orchestrator not rule the close-out converged before the owner answers, is met;
         - item 10 step 8's FAIL rule now names P-13 only: a FAIL whose only cause is P-13 (WP-B's; S3-R26 item 10) is reported as such.
       - **Named findings:**
         - correct #5 and reqs #6 (PROBE-C21-HOLDERS): 37.21 to 45.85 ms, best of 3, across the fixer's runs (1-minute loads 6.92 to 8.33), reqs #6's (4.60 to 4.74) and correct #5's (about 6.25). They go to 12.1, recorded and not blocking. Their in-letter part, k ≤ 4, stays with item 4, gated;
         - reqs #12 (two stalled subscribers): 15.57 ms, best of 3, at a 1-minute load of 7.44. It goes to 12.1, recorded.

    2. **Correct #1: the pin after an ENOENT re-queue.** Blocking (S3-R16 1(a)), confirmed by PROBE-C21C-PIN-ENOENT-404 and by e1 §1.
       - **The break** (`.build-orchestrator/s3f-probes-c21/PROBE-C21C-PIN-ENOENT-404.log`, 2/2 per case). rr21-T8b's shape, with X's fresh attempt failing with a 404. Visit-first answers W1…W3 `.failure(.notFound)` and never requests W's content. In three of the four cases (order × owe), W1…W3 get W's 20 bytes and W is requested. V2 gets `.notFound` and K 16 bytes in every case, and no invariant breaks.
       - **The mechanism** (e1 §1). The ENOENT arm (`EngineDispatch.swift:1274-1283`) re-queues X at the same epoch and keeps no record. `waitingTarget(_:epoch:)` returns nil for `.queued` (`EngineFollow.swift:1581-1582`), so the pin check returns nil (`:806-808`), and both callers, `rerouteListing` and `joinListing`, follow the engine's copy. Answer 6.3's premise, that the reference re-routed the pair at that end, is false for an ENOENT re-queue: visit-first's pair rode X's fresh attempt.
       - **Route: e1-R1** (e1 §2), as e1 review "must add" 1 states it. While events wait, the ENOENT arm keeps (X, epoch) with `copySerial`, marked as a re-queue. At the pin, with no layer after that serial, the walk returns the pin layer's outgoing copy. Otherwise it takes the copy that the first layer after the re-queue adopted (index `end.serial - serial + 1`, or the engine's copy), and walks on.
         - e1-R1 reads no job state. It reuses the record's clears (`endWorldHistory`, `EngineFollow.swift:372`; shutdown, `EngineShutdown.swift:130`) and its three clauses (`EngineCommands.swift:2239-2250`).
         - The verifier's fix step 3 (the entry handed to the copy at the re-queue) is rejected as written, and so is a walk-on keyed on X's state (e1 §2; the last row of e1 §4's kill table). The verifier's step 1 becomes T-E1, and its step 4 becomes rr21-T8b's change below.
       - **The record's form: a flag on `reroutePinCommits`' value** (e1 review must-fix 4, "must add" 2). Its duties:
         - `committed`'s write (`EngineDispatch.swift:1133`) records a commit (`keepsEntry: false`);
         - the "ahead" clause (`EngineCommands.swift:2247`) reads the value's serial;
         - `invariantsReportCommitsKeptForOwedReroutes` (`EngineFollowBarrierReroutePinEndTests.swift:263-278`) writes and compares raw `UInt64`s and expects the clauses' "commits kept" messages. It changes one to one, as exact as before, in e1-R1's commit, where the value's type changes, and the draft records the old and new text, the messages included if they are renamed. This item authorises that change, as an exception to S3-R26 item 1's "Answer, MUST and invariant assertions never change" (rulings :462);
         - the `keepsEntry` literal's mutant is killed (the table below).

         A sibling map is allowed only if the flag form cannot hold. It then needs its own clears and its own clauses, each with its kill, and the draft records the reason.
       - **The tests,** in `EngineFollowBarrierRerouteRequeueTests.swift`, from rr21-T8b's fixture, owing, in both orders, unless a row says otherwise (e1 §4; T-E5 is e1 review must-fix 1):

         | Test | Shape | Visit-first's answers | On `d5b2ab9` |
         |---|---|---|---|
         | T-E1 | the probe's, with `arguments: LaneDropVisit.allCases, [false, true]` (order × owe) | W1…W3 and V2 `.notFound`, K 16 bytes; after the replay X holds zz-a1…zz-a3 and zz-x; W never requested; no violation | red in 3 of 4 cases (the verifier's probe) |
         | T-E2 | K1 drops zz-a1…zz-a3 while X publishes; X's ENOENT; K2 lists them at U; X's fresh attempt fails with a 404 | W1…W3 U's bytes, V2 `.notFound` | green (code reading) |
         | T-E3 | K1 as in rr21-T8b; after the re-queue, K2 drops the pair and K3 lists it at U | W1…W3 `.notFound`; U never requested | red (code reading) |
         | T-E4 | T-E3, with K2 also mapping zz-x to Y, so that X is superseded | W1…W3 `.notFound`, V2 Y's bytes | red (code reading) |
         | T-E5 | after the re-queue, K2 lists the pair at U (no job of U at an end) and K3 at Z | W1…W3 Z's outcome | green (code reading) |

         - **Serving** (e1 review must-fix 6, "must add" 4). Every T-E test serves each content a mutant can request (W, U, Z), only if its job exists, and asserts which contents were requested. A mutant then fails on an answer, not on a time limit.
         - Each test is green in both orders on the fix before any kill counts.
       - **rr21-T8b changes one to one** (e1 "must say" 5; e1 §2, step 4). It lands in e1-R1's commit, since its old `:124` is red under e1-R1:
         - `:124` becomes `replayed.x == (ids + [xID]).sorted() && replayed.w.isEmpty`: X holds zz-a1…zz-a3 and zz-x, and W has no job;
         - the loop at `:127` delivers X before W, since W's job now appears only at X's commit;
         - its display and function names (`:25-26`) and its docs (`:8-23`) say that the pin holds. The answers at `:142` stay.

         The draft records old and new. No `MIGRATION.md` entry is needed: it is cycle 21's own test.
       - **The kills** (e1 review "must add" 3; e1 §4, corrected by must-fix 1 to 3). Each is 2/2 in each order that can reach its branch, after a green first run of the unmutated code in both orders. A kill is by an answer or a clause, never by a hang or a time limit (item 5).

         | Branch | Mutant | Killed by |
         |---|---|---|
         | the ENOENT arm's write | dropped | T-E1 |
         | the write's `!eventsAfterFollow.isEmpty` | forced true | `enoentAfterCancelIsTheCancellation` (`EngineRaceTests.swift:82-122`), strengthened with an `invariantViolations()` check after the fresh attempt and recorded, or a new barrier-down ENOENT test. Without a follow the orders are moot, and the draft says so (must-fix 2) |
         | `end.keepsEntry` | dropped (read as a commit) | T-E1 and T-E2 |
         | `next < layers.count` | forced true (always jump) | T-E1 |
         | `next < layers.count` | forced false (always keep) | T-E2 |
         | `index = next + 1` | `index = next` (the verifier's step 3) | T-E2 |
         | `index = next + 1` | `return nil` (`d5b2ab9`'s answer) | T-E3 and T-E4 |
         | the walk on, after the jump | no walk-on: the jump's copy is returned (p5's form) | T-E5 |
         | the record decides, not X's state | a walk-on keyed on X's state | T-E4 |
         | `committed`'s `keepsEntry` literal | read as a re-queue | killed; e1's review expects p4's killers (draft `:6309`) to kill it, unverified. If they do not kill it 2/2 in each order that reaches it, a PIN-END test that does is added |
         | `i5-pin-fold` (re-run) | `.queued` returns the job in `waitingTarget(_:epoch:)` | T-E2, moved from rr21-T8b. The run decides which tests kill it in each order, and the draft records the killing line per order |

       - **The probes** (e1 §3 and §7, step 4; e1-PR is added here). Each asserts visit-first's answers, and runs in every order that can reach it. e1 §3 gives the shapes:
         - **e1-PS:** X's own publication superseded, then a later apply: (i) K2, mapping the pair to U, adopted while J publishes, then J's terminal failure; (ii) K2 drops the pair and K3 re-lists it at U. Owing, both orders. Visit-first: (i) J's integrity failure, (ii) `.notFound`. Route if red: the commit-shaped record (`keepsEntry: false`) at the `.superseded` arm (`EngineDispatch.swift:1261-1268`);
         - **e1-P1 and e1-P2:** a T20 re-queue during an ENOSPC free-space read, from the drain's replay of a user join (e1-P1) and from `followAfterVerdict`'s joins (e1-P2). Both orders. Visit-first: for e1-P1, `insufficientSpace` for the pair and for V2, with X requested once; for e1-P2, X's ENOSPC verdict answers Y's id. Route if red: `relane`'s guard (`EngineJobs.swift:307`);
         - **e1-P3:** a park at the same epoch while the barrier holds: Shape A and rr21-T8b, with a conditions edge or a space sweep replayed between the re-queue and the move or the replay. Both orders. It records X's state at the move and at the replay, with no `#require`, and runs on to the answers. Visit-first: the id rides X. A `.blocked` state with visit-first's answers is recorded as the move's own finding: e1-R1 makes the state moot for the pin, but the move's `.queued` arm still depends on it (e1 §3). If kept as a test, it asserts visit-first's answers;
         - **e1-PR:** the untraced removal edge in e1 §3's table: X dropped by a removal replayed before the batch, with no apply since the re-queue. `sweepFollowsFirst` only. e1-R1 is expected to join a new job of X's content, so that the answers equal visit-first's (UNCONFIRMED).

         A different answer from visit-first's is blocking. A probe is red when it breaks S3-R16 item 1 in an order that reaches it: a different answer, a broken MUST or invariant, or a hang (S3-R26 items 7 and 11). Its other observations, such as a request count or a job's state, are recorded with it.
         - A red probe with a route given here is fixed in cycle 22: its failing test first, then the smallest change that makes the answers equal visit-first's, with its branches killed and the design recorded.
         - A red probe with no route given here (e1-P3, e1-PR) stays out of the suite, as scratch evidence, and is reported as blocking with its probe and its log.
         - A probe that holds is recorded with its result (S3-R26 item 11).
       - **Amendments** (e1 review "must add" 5). Visit-first re-routes only at a commit or a supersede, so an ENOENT re-queue keeps the pin:
         - S3-R26 answer 6.3: its header's class is now a pin whose job committed or was superseded, and the ENOENT re-queue and rr21-T8b leave it. Its first and second bullets hold for those two ends, and the first's "rr21-T8 and rr21-T8b pin it" reads "rr21-T8 pins it" (the commit pin, `integrate-rr21.md:403-406`). After an ENOENT re-queue the reference re-routed nothing at that end (D-13). With no apply since, the pair rides X's fresh attempt (T-E1, rr21-T8b). With one or more, the first visit after the re-queue moved it under the copy that visit's apply adopted, and later visits moved it on (T-E2 to T-E5);
         - S3-R26 item 1's "A pin holds only while `waitingTarget(transfer, epoch:)` holds" (rulings :441) now reads: a pin holds while `waitingTarget(transfer, epoch:)` holds, and, after an ENOENT re-queue at that epoch, until the first copy adopted after the re-queue;
         - `integrate-rr21.md`'s D6 (`:316-318`) and its residual (`:597`) lose the ENOENT re-queue, and its must_not on the `waitingTarget` window (`:586`) is lifted for this fix. D6's first sentence reads as S3-R26 item 1's, amended above. Its last sentence, "No new job of a former target is created from an old copy", holds for the commit and supersede ends only (e1 §2);
         - S3-R26 answer 8: the pin caller's kill of the fold mutant is T-E2's, with the other tests the run shows killing `i5-pin-fold` in each order. Every other rr21-T8b in answer 8, the "Reached" evidence of its second and third bullets included, reads "T-E2, with those tests".

         "There is no layer per commit" stands: a kept serial is no layer. The nested ENOENT, a commit's next target re-queued by its own ENOENT, is in the class, and e1-R1's branch covers it (e1 review "must add" 7).
       - **C2** (e1 "must say" 11). No new inventory row: `followLayers` stays O(layers) an id, and the ENOENT arm gains O(1). Item 9 re-measures `applyWhileOwedLayers`, `lane429WhileOwed` and `joinChainTurns`. e1-R1's added cost is estimated at 0.2 ms or less a drain turn.
       - **Records** (e1 "must say" 10):
         - the doc comments at `EngineFollow.swift:765-773` and `:1561`, whose "An owed re-route's pin keeps the end's own window" is now false; at `EngineState.swift:217-221`; and on the ENOENT arm (`EngineDispatch.swift:1275-1278`);
         - the draft at `s3f.md:5695-5700` (rr21-T8b); `:5821-5824` (the residual, and the wrong "The records go when the last batch is replayed whole": they go at `endWorldHistory` and at shutdown); `:6563-6566` and `:6601-6607` (the fold's kill, and the first UNCONFIRMED sibling, now confirmed and fixed); and `:6814-6816` (RR-21's ruling-3 residual).
       - **Fixer hours,** estimated (e1 review "must add" 8): about 6-10 h of writing and 3.7-5.5 h of mutant runs for the fix, its tests, kills and records, plus 3-5 h for the probes. A sibling's fix is not included.

    3. **Correct #2, with reqs #4: the purge's first turn.** Blocking (S3-R16 1(f)). `withdrawPurged` walks every waiting event and every job in one turn, the synchronous stretch after `ensureStarted()` (`EngineCommands.swift:968-976`). The figures are in the cases' table below (correct #2's probes in `.build-orchestrator/s3f-probes-c21/`; e2 §0, confirmed by e2's review).
       - **What it replaces:** item 2's paragraphs "The jobs' side has no figure" and "The jobs' side's route is branch-free", and item 11.3. Item 2's part (1) stands, as e2-A1.1. Its part (2) is no longer conditional: it lands in e2-A1.2.
       - **The contract** (e2 §1; e2 "must say" 2), recorded in the draft. Withdrawing every non-user interest in the purge's first turn is not a MUST (`SPEC.md:250`; `docs/ARCHITECTURE.md:300` binds only the engine's epoch). Withdrawing every waiting join, bucket join and owed item before any drain turn is binding (RR-5, PROBE-C13-PURGE-JOIN).
       - **The gated cases** (e2 review "must add" 3): eleven BenchSync cases at 10,000 ids, in 11.6's files. Each purges `.all` unless its row says otherwise.

         | Case | Today, best of 3 |
         |---|---|
         | (i) one prefetch group of 10,000 members, each id with its own content and job | 54.47 ms at a 1-minute load of 7.65, and 55.96 at 4.85 (PURGE-QUEUED) |
         | (ii) 10,000 one-member prefetch groups, each id with its own content and job | not measured |
         | (i) under a `.scope` purge | not measured |
         | the shared job at k = 1: one job of 10,000 ids | 12.20 ms at 7.65, and 12.03 at 4.85 |
         | the shared job at k = 4: four groups over its ids | estimated 43-48 ms (e2 review must-fix 10) |
         | the bucket joins: PURGE-JOINS' shape at 10,000 members | 13.04 ms with 9,216 joins behind the verdict, at 7.36 to 7.23 |
         | the queue joins: the same shape | 11.52 ms with 9,489 joins in the queue, at 7.23 to 6.88 |
         | `purgeWhileOwedTurns` (reqs #4; it exists), 10,000 owed items | 10.04 ms in the fixer's second gate run, at a 1-minute load of 4.88 (mean 5.23 over SyncBenchmarks; a miss); 9.57 to 9.83 in the verifiers' runs, at 3.39 to 7.14 |
         | k = 4 over 10,000 jobs: four prefetch groups | estimated 85-130 ms (e2 §2.4) |
         | 10,000 jobs waiting for a retry, each one that the purge removes (held only by interests it withdraws) | estimated 0.1-0.5 s: `removeJob` scans the heap once per job (`EngineJobs.swift:483`; e2 review must-fix 10) |
         | 10,000 jobs held only by user waiters | estimated 8-14 ms (e2 review must-fix 10) |

         For each case:
         - its figure is its heartbeat, best of 3, with loads, as "How a C2 figure is read" says, and the purge's synchronous turn is recorded beside it;
         - its 'before' figure is taken in step 0, in the scratch copy;
         - if it misses on `d5b2ab9`, it is committed red right before e2-A1's first part, under item 10's red-first rules.

         `purgeWhileOwedTurns` is already in the tree, so it is not committed again. Its cycle-21 figures (the table) and its step-0 figure are its 'before' figures. Its cycle-21 miss stands, and the decision rule below judges it after e2-A1 and after e2-A2.

         The purge over one id held by 10,000 groups (row 14) is outside the bar (12.1), and is recorded only.
       - **e2-A1 (e2 §3's A1.1 to A1.7), with e2 review's corrections.** Each part is its own commit.
         - e2-A1.1 (item 2's part (1)): `isPurged` reads the request before the copy lookup, in the walk, the joins and the owed arm (`EngineCommands.swift:993-1005`).
         - e2-A1.2: the owed batch (item 2's part (2)), the queue's `.join` events and each bucket are changed in place, with no copy of their items. A bucket takes one `joinsBehindVerdicts[key]` access, still newest first.
         - e2-A1.3: no sort of the dropped ids or of the removed items (`:1022`, `:1070`).
         - e2-A1.4: one jobs access per job, through a `Job` mutating method, then one `settleRemoval`. The method removes in ascending token order and returns the lanes before the first and before the last removal, as `takeOff` does (e2 review must-fix 6). Its test: a claim-held job whose `.bulk` interest is registered before its `.prefetch` interest (t1 < t2, as e2 review must-fix 6 builds it) ends with `heldLane == .prefetch`. The reversed-order mutant fails it 2/2 (e2 review "must add" 2).
         - e2-A1.5: the `.all` fast path, below.
         - e2-A1.6: A3 and A3′ (`Group.dropMember`) at `:1025`, `:1073` and `:1108`, with d2 review M1's pending check and item 3's C7 citations. Item 3's sub-step 4 then reuses them.
         - e2-A1.7: no `Job` copy in `settleRemoval` (`EngineJobs.swift:395`) or in `retire` (`:412`).
       - **Exclusivity** (e2 review must-fix 8, "must add" 1). Every step that works inside one access takes `applied` and the request into locals, marks and collects inside the access, and makes the other writes after it, in the same order, as item 1's exclusivity rule says. Every in-place access is such a step: e2-A1.2's owed batch, `.join` events and buckets, e2-A1.4's method and e2-A2.4's walk among them.
       - **The reversals** (e2 review "must add" 6). e2-A1.3 reverses `integrate-rr21.md` R15 (the owed arm's sort, `:239`) and S3-R26 answer 7's "the purge arm that removes items and sorts the removed subset".
       - **The order.** The draft records e2-A1's order arguments, corrected: the order across jobs (the sorted keys) and within a job (ascending tokens) is kept. Two things change: the order of the dropped ids and of the removed items, and, with e2-A1.4's one `settleRemoval` per job, the number of `notifyObservers` calls inside the turn (`EngineJobs.swift:406`; e2 §3, "Equality with today"). The purge never withdraws an `.ensure` interest, so no drop resumes anything (e2-A1.3; e2 review, "What holds").
       - **e2-A1's one branch, the `.all` fast path (e2-A1.5):** `withdrawn = interest.assets`, with no filter and no intersection. This item authorises it, amending item 2's and item 11.3's "branch-free" (e2 review must-fix 7).
         - Always taken: killed by T-A-SCOPE, 2/2 in each order that reaches it. T-A-SCOPE purges a `.scope` of one of two ids that share a content held by a prefetch group. The other member stays pending and keeps its interest (e2 §3).
         - Never taken: Equivalent, cost only (S3-R19 item 2).
       - **e2-A1's other kills** are e2 §3's table:
         - `isPurged`'s early read: drop-mutant Equivalent (item 2's part (1));
         - the method's whole arm: `purgeDropsGroupMembers` (`EngineRegressionRound2Tests.swift:282`); its partial arm: T-A-SCOPE;
         - the moved lane and kind conditions, b23's among them: re-run at their new lines (item 3's rule);
         - `Group.dropMember`'s nil line: item 3's M1.
       - **e2-A2 (e2 §3's A2.1 to A2.6),** authorised only if a purge case is above 8.5 ms after e2-A1. Each part is its own commit. With e2 review's corrections ("must add" 4):
         - e2-A2.1: `removeJob` touches an index only when it is not empty;
         - e2-A2.2: `storedCount` becomes a counter in `LaneQueues`, with a recount clause, and the queues are compacted once, after the walk;
         - e2-A2.3: the retired jobs are freed later. Either the freeing slice is pinned, with recorded slices and a drop-mutant that fails 2/2, as item 6 pins `settle`'s, or the freeing runs unsliced in one later turn, with its figure and a REENTRANCY row;
         - e2-A2.4, the table-order walk, comes only after the purge suites' order audit (item 3's A7 rule), in two passes, with the iOS SDK's `Swift.swiftinterface` cited (C7). Otherwise the key sort stays;
         - e2-A2.5: one heap pass for the retired jobs' `.retry` entries (`DeadlineHeap.swift:79-81`);
         - e2-A2.6 is dropped unless A5's audit (item 3) is done first.
       - **e2-A2's kills** are e2 §3's table, with e2 review's corrections:
         - the empty-index guards: drop-mutants Equivalent (S3-R19 item 2); each negation killed by its index's clause, which the fixer lists per index, adding one where an index has none;
         - the queue counter: each update's drop-mutant fails the recount clause;
         - e2-A2.3's freeing slice is not Equivalent (e2 review must-fix 9): it is pinned as above;
         - the heap pass: the retry case asserts that no `.retry` entry is left.
       - **The decision rule** is item 1's: at or below 8.5 ms closes a case; 8.5 to 10 ms is recorded "at the edge" and is not blocking; a miss is blocking. Measure every purge case after e2-A1, and after e2-A2. A miss after e2-A2, or after e2-A1 when e2-A2 is not triggered, is blocking with no route in cycle 22. Report it with its parts' figures and loads.
       - **Route e2-B, slices over owned follow-up turns (e2 §4), is not authorised in cycle 22** (e2 review "must add" 5). The fixer does not build it. The orchestrator will have e2-B re-specified with e2 review's corrections, and reviewed, for a later ruling:
         - visit on touch, claims included, with its cost counted in the touching turn;
         - member drops in the slices;
         - a bound on both the jobs and the pairs visited, with a job split by interest;
         - a mark per walk, and no "unmarked" clause;
         - shutdown and cancel behaviour stated against today's.

         e2 review must-fix 1 to 5, 11 and 12 are about e2-B. They are recorded for that re-specification, and bind the cycle-22 fixer only where 12.3 carries them.
       - **`isPurged` keeps its entry copy** (`ValidatedManifest.swift:78-83`). There is no edit to `ZTronAssetModel`, which is not WP-F's (P1). If a `.scope` figure shows that the copy decides a miss, report it with the figure.
       - **Records.** Propose (S3-R6) RE-S24's corrected text (`docs/ARCHITECTURE.md:456`; e2 §1.1): it puts the purged ids' job removals after the store's await, and the code makes them before it, in the purge's first turn. Every estimate stays labelled as one (G2).
       - **Fixer hours,** estimated (e2 §6): e2-A1 5-8 h, and e2-A2 6-10 h, with the cases and red commits included.

    4. **The order of work** (item 10), amended:
       - **Step 0** also runs T-E1, T-E3, T-E4 and T-E5 on `d5b2ab9`, recording each red or green, and takes the 'before' figures of 12.3's cases.
       - **Step 1** also takes these parts of 12.2, all of them before item 6's `EngineFollow.swift` removal in step 2 (e1-R1's kills are in step 7; 12.2's records, and item 9's re-measures, are in step 8):
         - every T-E test that is red on `d5b2ab9`, committed failing in one commit (item 10's red-first rules);
         - then e1-R1, with rr21-T8b's change, the PIN-END invariants test's change, and each T-E test not committed red in the previous commit;
         - then the probes e1-PS, e1-P1, e1-P2, e1-P3 and e1-PR. A red one with a route gets its failing commit, then its fix by 12.2's routes; one with none follows 12.2.

         e1-R1 moves `EngineFollow.swift`'s lines below `:820`, so item 6 finds `replayVerdict`'s lines by content (e1 §5). Any other citation of this ruling that a change in this item moves is found by its content too: for example, a fix at `relane`'s guard (`EngineJobs.swift:307`) moves item 1's c6 site and 12.3's `EngineJobs.swift` lines.
       - **Step 4** takes 12.3 with item 2:
         - the cases not yet in the tree, committed red where they miss;
         - e2-A1's parts, one commit each, then the figures of every purge case;
         - e2-A2's parts if triggered, one commit each, then the figures again.
       - **Step 7** adds e1-R1's kills and e2-A1's and e2-A2's kills, beside item 5's.
       - **Step 8** adds the records of 12.2 and 12.3. Item 9's check covers 12.2's and 12.3's lines.
       - **The named findings.** The draft's status list keeps this mapping:
         - correct #1 → 12.2;
         - correct #2 and reqs #4 → 12.3 with item 2;
         - correct #3 and reqs #2 → item 1;
         - correct #4 and reqs #5 → item 3;
         - correct #5, reqs #6 and reqs #12 → 12.1;
         - correct #6, reqs #7 and reqs #8 → items 5 and 6;
         - reqs #1 → 11.6, and reqs #3 → 11.7.
       - **Expect the weekly limit.** Item 10's paragraph stands. With item 12, cycle 22's fixer work is estimated at about 55-90 h, so a cut-off inside the cycle is likely. Commit every finished step when it is done.

## For the orchestrator (not part of the ruling)

Labels in this section are the decisions' (R1, A1, A2, B, P-S to P-R). The ruling's text now carries them as e1-R1, e2-A1, e2-A2, e2-B and e1-PS to e1-PR, under a Names bullet that follows S3-R26's (consistency must-fix 1). Items 1 to 11 are the drafter's, with the reviews' agreement or additions noted under them. Items 12 to 26 are the reviews' decision-level items, merged where both raise one point: "fidelity" is `s3-r27-item12-review-fidelity.md`, and "consistency" is `s3-r27-item12-review-consistency.md`.

1. **A citation in D2.** "e1 §2 and §7 point 3": e1 §7 point 3 is "The kills of §4". The rejection of a walk-on keyed on X's state is traced in e1 §2 (T-E4, `e1-pin-requeue.md:107-109`) and is the last row of e1 §4's kill table, so 12.2 cites those. e1's own "must say" 3 calls that walk-on "acceptable only with T-E4 run first"; e1 review should-fix 3 corrects it to a rejection, which is what 12.2 says.
2. **"The records go when the last batch is replayed whole"** (draft `:5823-5824`). 12.2 calls it wrong, as D2 decides. e1 review should-fix 6 reads it as the PIN-END step's history, with the change recorded at `:5857-5862`, and advises a cross-reference, not a rewrite. A fixer who rewrites it in place loses that step's record. Wording the record as "corrected by a cross-reference to `:5857-5862`" would satisfy both. Consistency agrees (its For the orchestrator 4).
3. **The mapping omits seven of the eight non-blocking findings** (reqs #12 is in it). Every listed mapping fits the findings file. Under the header's naming rule, five of the seven are named:
   - reqs #10 (the fold mutant at `EngineFollow.swift:1581-1582`; draft `:5072` and `:6560-6566`) by 12.2. Its proposed record, "rr21-T8b reaches the arm and kills the fold", may be false after R1, since 12.2 changes rr21-T8b and moves the kill to T-E2. Draft `:5072` ("The arm is Reached in cycle 21 (Shape A …)") is not in 12.2's records list;
   - reqs #11 (`s3f.md:4961`, `releaseRerouteHolds`) by item 8;
   - reqs #14 (`s3f.md:6655-6658`, the held-turn readers) by item 7;
   - correct #7 and reqs #15 (P-13) by item 10 step 8 and 12.1.

   reqs #9 (no cycle-21 "Proposed document changes") and reqs #13 (two red commits before one fix) are named by no item. 12.4's "in one commit" for the red T-E tests follows reqs #13's reading of the red-first rule.

   Fidelity should-fix 3 proposes adding `s3f.md:5072` to 12.2's records. That extends D2's records list, so the text leaves it here. reqs #10 also reports that Shape A no longer kills the fold since `58b278e`, and that rr21-T8b does.
4. **A1.4 and `notifyObservers`.** e2 review should-fix 5: one `settleRemoval` per job also cuts the `notifyObservers` calls inside the turn (`EngineJobs.swift:406`), so A1.4 would need item 3's mid-turn audit, as A2.6 does. D3 does not name it, so A1.4 lands with no audit. A test whose `awaitCondition` predicate holds only between two removals of one job would then wait for a later notification. I did not check whether any purge test has such a predicate.
   - Both reviews raise it (fidelity 5; consistency 2). The text now states the change (12.3, "The order"; fidelity should-fix 8) and still adds no audit.
   - Fidelity adds that "A5's audit (item 3)" is item 3's audit of the answer-site suites' predicates (rulings :838), not of the purge suites'. So A2.6's gate also rests on an audit that never looks at the purge's tests.
   - Consistency adds that item 3's audit runs in step 5, after step 4, and proposes one audit of the purge suites' predicates before A1.4.
5. **Item 10's list of deciding figures** (`s3-rulings-s3f.md:995`) still names item 2's in-place batch, which 12.3 makes unconditional, and does not name A2's trigger (a purge case above 8.5 ms after A1). The rule in "How a C2 figure is read" ("item 10's rule applies where no quiet load is reached") covers the trigger. A one-line amendment would make that explicit. Consistency agrees.
6. **The PIN-END invariants test.** S3-R26 item 1 says invariant assertions never change. 12.2 says that this item authorises the one-to-one change of `invariantsReportCommitsKeptForOwedReroutes`, which D2 decides, so that a verifier does not read the renamed messages against S3-R26 item 1. Now in the text (consistency should-fix 4): 12.2 names the change as an exception to S3-R26 item 1's rule (rulings :462) and puts it in R1's commit, and 12.4's step 1 lists it.
7. **R1's write placement.** e1 review should-fix 10 puts the ENOENT arm's write inside `if self.transition(transfer, to: .queued)` (`EngineDispatch.swift:1280`), "so no record names an attempt left at its end". It is not named, so it is advisory. A write placed before that `if` could, if the transition failed, leave a record for an attempt still at its end, and the "still at its end" clause would report it. Consistency agrees, and would put the write inside the `if` (its For the orchestrator 4).
8. **P-R is not costed.** e1 review "must add" 8's 3-5 h covers four probes. P-R is a fifth, in `sweepFollowsFirst` only.
9. **Row 14.** Once 12.3 replaces item 2's paragraph, no text asks the fixer to build the purge over one id held by 10,000 groups. Under 11.2 it is recorded only if it is measured. D1's "where items 1, 2 and 4 say to measure them" then points at nothing in item 2. Consistency should-fix 8 proposes "recorded only if measured (11.2)" for 12.3's row-14 sentence, and re-pointing the "(item 2)" in 12.1's list and the "items 1, 2 and 4" in its recording rule. Those are D1's and D3's words, so the text keeps them.
10. **12.4's step 1 and the probes.** D4 says each red probe gets "its failing commit and its fix by the routes in 12.2"; D2 keeps a red probe with no route (P-3, P-R) out of the suite. 12.4 words step 1 so that both hold: a red probe with a route is committed failing, then fixed; one with none follows 12.2.
11. **Item 2's per-part re-measure.** Item 2's route bullet ("After each part, re-measure `purgeWhileOwedTurns` and PROBE-C21-PURGE-PARTS") is not among the paragraphs 12.3 replaces, so it still binds A1.1 and A1.2. 12.3 measures every purge case after A1 and after A2. Both can hold; say so if the per-part figures are not wanted. Consistency agrees.
12. **Cycle 21's pin-record mutants under the flag form** (fidelity 1). In `.build-s3f/c21/tools/mut-c4fix.py`:
    - three anchors no longer occur: p3's `= self.state.copySerial` (`:22`), the `index = Int(committed &- serial)` of p4 and p5 (`:23-24`), and p10's `$0 > self.state.copySerial` (`:29`);
    - p1's, p2's and p2b's guard (`RECORD`, `:9`) would occur twice if R1's write copies `committed`'s guard, as e1 §2 proposes;
    - their filters (PIN, LAYER, INV, JOIN) include no T-E test.

    Renaming rr21-T8b also takes it out of the LAYER filters of `mut-c4fix.py`, `mut-c3.py`, `mut-c3fix.py` and `mut-pinend.py`, and out of `mut-i5.py`'s `T8B`. No decision says whether these are rewritten and re-run, as item 5 does for r6 and r8 (rulings :933-937). Fidelity did not check whether `mut21s.py` refuses a doubled anchor or mutates its first match.
13. **T-E2 is never run on `d5b2ab9`** (fidelity 2; consistency 1). D4's step 0 runs T-E1, T-E3, T-E4 and T-E5, so T-E2's "green" there rests on code reading only (e1 §4). If T-E2 is red on `d5b2ab9`, it lands with R1, with no red commit (S3-R26 item 11). Consistency proposes adding T-E2 to step 0.
14. **The probes' fixes have no step for their kills** (fidelity 3; consistency should-fix 7). D2 kills a probe fix's branches, but D4's step 7 names only R1's, A1's and A2's kills, and so does 12.4. P-S's route (the `.superseded` arm) and the route of P-1 and P-2 (`relane`'s guard, `EngineJobs.swift:307`) need a step. Consistency proposes step 7, with R1's.
15. **What makes a probe red** (fidelity 4; consistency must-fix 2, applied). D2 does not define a red probe. P-3's `#require(state == .queued)` (e1 §3) could fail while the answers equal visit-first's, and D2 would then report P-3, which has no route, as blocking. Yet S3-R16 item 1, and D2's own sentence ("A different answer from visit-first's is blocking"), make only a different answer, a broken MUST or invariant, or a hang blocking.
    - The text now keeps D2's sentence, defines a red probe as one that breaks S3-R16 item 1 in an order that reaches it (S3-R26 items 7 and 11), and has P-3 record X's state instead of requiring it.
    - So a `.blocked` state with visit-first's answers is recorded as the move's own finding (e1 §3), and a request count is recorded with its probe.
    - Fidelity read this as a question for a ruling. Confirm the definition, or rule otherwise.
16. **(i) under `.scope`: which ids** (fidelity 6; consistency should-fix 9). D3 does not say which ids the scope selects. e2's after-A1 estimate for this case, 35-45 ms (e2:195), implies all of them, through the filter path, so that the per-id copy lookup is in the figure. A scope that selects few ids withdraws almost nothing (`e2-purge-review.md:71`).
17. **The user-waiter case drops "or ensures"** (fidelity 7; consistency should-fix 9). e2 review must-fix 10 (`:121`) and "must add" 3 (`:185`) gate "10,000 jobs held only by user waiters or ensures". D3, and so the text, keeps only the user waiters.
18. **Red purge cases across A1's and A2's commits** (fidelity 8; consistency should-fix 1). S3-R26 item 11 says "Only that commit may be red" (rulings :639; it applies through S3-R27 item 10, :991). D3 commits each missing case red right before A1's first part. A1 has seven commits and A2 up to six more, so a case that A1.1 does not close stays red through the next parts' commits. This is reqs #13's reading of the rule, and it needs a ruling either way. Consistency also asks whether the missing cases go into one red commit, as 12.4's step 1 does for the T-E tests.
19. **Regression controls** (fidelity 9). e1 review should-fix 9 names them, in both orders: rr21-T8b as changed, the PIN-END suite, FBJoinGapFailure, Shape A and probe (ii), and the D-13 test. They guard R1's new write, which runs behind every ENOENT while events wait. No decision carries them, so they are advisory.
20. **`integrate-rr21.md`'s B17** (fidelity 10). Its "Reached: T5 (pin holds) and T8/T8b (pin left)" (`:971-972`) goes stale under R1, which keeps T8b's pin. D2's amendments to that file name only D6, its residual and its must_not.
21. **Answer 6.3's header predicate** (fidelity 11). The header still says such a pin "follows the copy at the replay" (rulings :680). PIN-END's fix already changed that for the commit end: the walk starts at the commit's copy and walks on (`s3f.md:5819-5822`). P-S's route, if it lands, changes it for the supersede end too. 12.2 re-scopes the class but keeps the predicate.
22. **The `.scope` copy case and S3-R8** (consistency 3). Suppose `isPurged`'s entry copy (`ValidatedManifest.swift:78-83`, WP-A's) decides a miss. 12.3's decision rule makes that miss blocking, while S3-R8 makes a finding whose fix lies in another work package's files non-blocking, as `other-wp:a:` (rulings :13). Rule which applies.
23. **A probe that cannot be built** (consistency 5). No rule covers P-R if its shape cannot be built after a real attempt: its removal edge is untraced, and it runs in `sweepFollowsFirst` only. S3-R26 item 7's B-T5 rule is a precedent (rulings :585-587): record the attempt and the residual risk.
24. **Item 9's inventory and 12.3's new operations** (consistency should-fix 5). Item 9's inventory covers "items 1 to 4" (rulings :986). No decision says whether it covers 12.3, with rows for A2.2's counter and compaction, A2.3's freeing turn and A2.5's heap pass (e2 §5 also names the walk and the retry shape). 12.2's "no new row" stands. The text says only that item 9's check covers 12.2's and 12.3's lines.
25. **12.1's records have no step** (consistency should-fix 8). The doc of `commitTwoStalledSubscribersTurns` (`BenchSyncCycle21.swift:156-158`) still says a miss there "is reported 'open, for the owner'", which 12.1 makes stale. Consistency proposes adding 12.1's records, with that doc, to step 8.
26. **A doc that A1.3 makes false** (consistency should-fix 11). `EngineCommands.swift:1053` says the owed arm drops interests "in (id, token) order, as `withdrawPurged` drops them". It is not among 12.3's records.
