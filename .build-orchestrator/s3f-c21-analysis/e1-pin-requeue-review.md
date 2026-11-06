# Review: E1, the pin after an ENOENT re-queue (correct #1)

- **Reviewed:** `.build-orchestrator/s3f-c21-analysis/e1-pin-requeue.md` (356 lines), cited as "report :n".
- **Code:** `.worktrees/s3f`, HEAD `d5b2ab9` (clean); every line is at `d5b2ab9`. Sources are under
  `Sources/ZTronAssetSync/Engine/`, tests under `Tests/ZTronAssetSyncTests/Engine/`, unless a path says otherwise.
  "Rulings" is `.build-orchestrator/s3-rulings-s3f.md`; "draft" is the worktree's `docs/adr-drafts/s3f.md`.
- **What I ran:** nothing was built, tested or run. Claims are code reading unless they quote a log; any figure not
  quoted from a log is an estimate with its basis.
- **Process note:** before a context compaction in this session, a few read-only `grep`/`sed` commands ran with a `cd`
  into the worktree, against the task's rule. They changed nothing (`git -C … status --short` is empty); every later
  command used absolute paths or `git -C`.

## Verdict: CORRECTED

The core holds: the mechanism, the measured break, the rejection of the verifier's step 3, and R1's semantics. I found
no state where R1 answers differently from visit-first, breaks a SPEC MUST (SPEC.md:225-245) or an invariant, adds an
`await` (C3), or adds more than O(layers) of work per id (C2). It is not yet ready to rule on:
- the kill table leaves one R1 line with only a hang-mutant and one with no named killer, and swaps two rows (M1-M3);
- the record's form is left open without the duties each form brings (M4);
- the drafted ruling texts are ambiguous exactly where R1 and step 3 differ, and miss two amendments (M5, M7);
- the serving rule would turn kills into time limits (M6), and the step placement misreads item 10 (M8).

## Confirmed

- **Mechanism (§1).** The ENOENT arm re-queues X at the same epoch with no record (EngineDispatch.swift:1274-1283);
  `committed` is the record's only writer (:1133); `waitingTarget(_:epoch:)` returns nil for `.queued`
  (EngineFollow.swift:1581). So :806-808 returns nil and the caller follows the engine's copy. The table at report
  :43-48 matches `PROBE-C21C-PIN-ENOENT-404.log`:1-9.
- **Shapes.** Step 3's counterexamples (a) (T-E2) and (b), and T-E3 and T-E4, trace as stated for `d5b2ab9`, step 3
  and R1.
- **R1 equals visit-first** in every further state I traced: X blocked; X superseded or removed after the re-queue (the
  removal edge stays UNCONFIRMED, as §3 says); (X, e) in several layers (the jump passes them all); a second ENOENT
  pin, or a commit pin, after the jump.
- **The walk ends and cannot wrap.** A layer records X's end only while X is at it at that adoption, so the ENOENT's
  serial is past that layer and `next >= index + 1`: `index` strictly increases and `end.serial &- serial` cannot wrap
  within a barrier window. A stale key is never read later: X's next start takes a new epoch
  (EngineDispatch.swift:705-706).
- **Callers and clauses.** `followedLane`'s early-out (EngineFailures.swift:840) keeps its premise: R1's new targets
  are a queued X or a job at an end, never the downloading job at a 429, so d4 review's replacement text for :829-833
  stays true. The drain's join of the pair to the queued X enters `unfollowed` (`noteJoin`, EngineJobs.swift:209-213),
  so EngineCommands.swift:1831-1835 holds; the "still at its end" clause (:2243) holds for a re-queued X.
- **rr21-T8b (report :158-166).** The new :124 and serving X before W at :127 are right: under R1, W's job appears only
  at X's commit, and the old order waits for it.

## Must fix

**M1. R1's `index = next + 1` (report :125) has no kill, and its literal drop hangs.**
- Dropped, `index` stays at the pin's layer and `layers[index].outgoing` (EngineFollow.swift:813) maps the id back to
  X, so the walk re-enters that layer forever. A kill by a hang or a time limit does not count (rulings :952).
  Dropping the commit pin's :809 loops the same way; cycle 21 mutated it semantically instead, p4 and p5
  (`.build-s3f/c21/tools/mut-c4fix.py:23-24`), both killed (draft :6309-6310).
- R1 needs the same three semantic mutants (code reading):
  - `index = next` (step 3's copy): killed by T-E2 only (K1 lacks the ids). T-E3 and T-E4 walk K1 → W → K2, which
    lacks the pair: R1's `.notFound`.
  - `return nil` (today's answer): killed by T-E3 and T-E4 (K3's U). T-E2 gets K2's U either way.
  - no walk-on, `let at = next + 1; return at < layers.count ? layers[at].outgoing : nil` (p5's text): **no T-E test
    kills it.** T-E1 never reaches the line; in T-E2 `at == layers.count`, so it returns nil as R1 does; in T-E3 and
    T-E4 `layers[2].outgoing` is K2, which lacks the pair, R1's answer.
- **Add T-E5** (rr21-T8b's fixture, owe=true, both orders): after X's re-queue, K2 lists the pair at U (no job of U at
  an end) and K3 at Z. Visit-first: K2's visit moves the pair off the queued X onto U, K3's on to Z, so W1…W3 get Z's
  outcome. R1 and `d5b2ab9` (nil, then K3) answer Z, a green control; the mutant answers U's.

**M2. The write guard's "forced true" row (report :247) names no killer.**
- The mutant is answer-neutral: a stale `(X, e)` is never read, since X's next start takes a new epoch
  (EngineDispatch.swift:705-706). Only "the follow barrier is down with N commits kept" (EngineCommands.swift:2240-2241)
  sees it, after an ENOENT while no event waits.
- No test checks that, by code reading. The only barrier-down ENOENT test (`EngineRaceTests.swift:82-123`) never calls
  `invariantViolations()`; the ENOENTs of rr21-T8b and `EngineFollowBarrierWaitingTargetTests.swift` come behind the
  barrier, where `endWorldHistory` forgets the record (EngineFollow.swift:372) before any idle check. "The twin of
  committed's own guard" is no kill: p2's killers (draft :6306) see commits.
- The ruling must name the test: the D-13 test gains an `invariantViolations()` check after the fresh attempt (a
  strengthening, recorded in the draft; not a CDN test, so no `MIGRATION.md`), or a new barrier-down ENOENT test.
  Orders are moot without a follow; record that.

**M3. The two `next < layers.count` rows (report :249-250) are swapped.** Forced true always jumps: in T-E1
`next == layers.count`, so `index` passes the end and the engine's copy gives W, so T-E1 kills it, and T-E2 (already
`next < layers.count`) does not. Forced false always keeps: T-E1 is unchanged, and T-E2 gets K0's X, `.notFound`
instead of U. As written, each row survives the test it names.

**M4. The record's form is left open (report :136, :300) without its duties.**
- **Flag form** (`PinEnd` as the map's value): `committed`'s write (EngineDispatch.swift:1133) and the "ahead" clause
  (EngineCommands.swift:2247) change, and so does the cycle-21 test `invariantsReportCommitsKeptForOwedReroutes`,
  which writes and compares raw `UInt64`s (`EngineFollowBarrierReroutePinEndTests.swift:263, :267, :271, :277`).
  The report's step 4 names only rr21-T8b; these need old and new in the draft, as :5857-5862 did for the clause
  change. The clause messages say "commits kept" and would count re-queues; renaming them changes the exact messages
  that test expects (:264, :272, :278). And `committed`'s `keepsEntry: false` (equivalently `end.keepsEntry` forced
  true) is a new mutant, expected killed by p4's killers (draft :6309), unverified.
- **Sibling map:** its own clears (`endWorldHistory`, shutdown) and three clauses, each with a p6, p8 or p9-p11-style
  kill (draft :6311-6316). §5's "no new kill duty" under p7 (report :264-265) holds for the flag form only.
- The ruling should pick one; the flag form adds fewer branches.

**M5. Ruling item 2 (report :325-327) is ambiguous exactly where R1 and step 3 differ, and omits the walk-on.** "The
copy adopted at the first layer after the re-queue" reads naturally as that layer's `outgoing` copy, which is the copy
at the re-queue: step 3's answer, rejected at :90-99. The code (:122-125) takes `layers[next + 1].outgoing` or the
engine's copy (the copy that layer's apply adopted), then walks on; M1's no-walk-on mutant shows that changes answers.
The ruling text must state both.

**M6. The serving rule (report :255; ruling item 4, :331-332) is one-sided.** "T-E1's loop must not wait for W's job"
and "no request for W" are right for R1. But three of the mutants §4 kills with T-E1 (the write dropped, `keepsEntry`
dropped, the jump forced: M3) create and request W. Unless the test then serves W, W1…W3 never answer and the kill is a
time limit, which does not count (rulings :952). The probe serves W only `if run.wJobExists`
(`.build-orchestrator/s3f-probes-c21/VerifyC21CorrectPinENOENTProbes.swift:162-169`). The ruling must require that for
every content a mutant can request: W in T-E1; U in T-E3, T-E4 and T-E5.

**M7. The ruling texts to amend (report :140-145; ruling item 7) are incomplete.**
- The report names the root cause as answer 6.3's "the reference had re-routed the pair at that end" (:55-57). That is
  the second bullet (rulings :682), yet only the header and first bullet (:680-681) are listed. Left as is, :682 states
  the rejected step-3 semantics for an ENOENT re-queue, and a later verifier could judge R1's jump wrong against it.
- Answer 8 (rulings :713-716) names rr21-T8b as the pin caller's kill of the fold mutant, and so as item 5's Reached
  evidence in `followVisitedFirst`, where Shape A's state check does not run (draft :6565-6566, :6601-6602). Report
  :165-166 moves the kill to T-E2 without amending answer 8.
- The move may be unneeded: under the flag form, the fold makes the "still at its end" clause (EngineCommands.swift:2243)
  report R1's own record, and rr21-T8b checks invariants after every held turn
  (`EngineFollowBarrierRerouteRequeueTests.swift:115-118`). The run decides; the draft records the killing line per
  order.

**M8. The step placement (report :274-276; ruling item 1) inverts item 10's rule.** Step 1 takes the 1(a)-(d) findings
"that this ruling does not name"; "A named finding goes with its item" (rulings :1006), and item 11.8 applies that to
the correctness verifier's findings (:1047). An item 12 naming correct #1 is therefore excluded from step 1, and item 10
has no step for it. The ruling must place it explicitly, with R1's kills and the four probes, weighing that step-1 work
delays the C2 routes item 10 puts first because of the weekly limit (:1017).

## Should fix

- **S1.** The commit row's `d5b2ab9` cell (report :185), "same", is wrong for "the next target's own ENOENT": the walk
  from X's commit record reaches J's pin, J is queued after its ENOENT with no record, and :806-808 returns nil.
  That is correct #1's break one hop later; R1's branch covers it.
- **S2.** The row "≥1, X superseded" (:183) overstates: with exactly one apply since, today's nil is that visit's copy
  (the report's own row :181). The break needs two or more applies, as T-E4's K2 and K3.
- **S3.** Ruling item 3 (:329-330): by the report's own trace (:107-109), a walk-on keyed on X's state gives U's bytes
  in T-E4. Reject it, rather than calling it "acceptable only with T-E4 run first".
- **S4.** Ruling item 9 (:347-348), "needs only P-3's `#require(.queued)`": a probe kept as a test asserts visit-first's
  answers (rulings :673, G4). §3 names it: "the id rides X" (:215).
- **S5.** Citations: "answer 6.3's last bullet" (:139) is the third (rulings :683); the last (:684) is "record it as
  timing". "d4 §6" (:315) is d4 §4, which costs one pinEnd test at 3 h (`d4-survivors.md:518`), not 1-3 h.
- **S6.** The draft's "records go when the last batch is replayed whole" (draft :5823-5824) is the PIN-END step's
  history; the draft records the change itself at :5857-5862. Cross-reference it; don't call it wrong or rewrite it.
- **S7.** C2 (:285-288), estimates: the two worst cases use different bases. At the report's 0.19 µs a layer-step,
  512 ids × 2 steps is about 0.19 ms but 10,000 × 2 is about 3.8 ms, not 2 ms. With two layers R1 adds at most one step
  past the jump (`index` lands at the end): about 0.1 ms a drain turn and 1.9 ms for 10,000. Both are far under the
  8.5 ms edge. Name one consequence too: X's later commit now carries the kept ids and re-routes them at site 1, a
  shape `concentrationCommitRerouteTurns` already bounds, so no new row.
- **S8.** The estimate (:314-318) is below d4's own rates (two runs a mutant at 10-15 min a run,
  `d4-survivors.md:506-507`): §4's seven rows alone take 2.3-3.5 h of machine time, not "about 1 h", and about 11
  mutants after M1-M4 take about 3.7-5.5 h. T-E5 adds 1-3 h of writing. Revised: about 6-10 h of writing plus 3.7-5.5 h
  of runs for steps 1-3 and 5, plus 3-5 h for the probes.
- **S9.** Name the regression controls (only new tests at :303), run in both orders: rr21-T8b (changed), the PIN-END
  suite, FBJoinGapFailure (p1's killer, draft :6305), Shape A and probe (ii) in
  `EngineFollowBarrierWaitingTargetTests.swift` (ENOENTs while events wait, where R1 now writes), and the D-13 test.
- **S10.** R1's code (:115-128): `let next` takes the name `guard let next = incoming.entry(for:)` uses a few lines
  below (EngineFollow.swift:814); rename it (e.g. `after`). Put the write inside
  `if self.transition(transfer, to: .queued)` (EngineDispatch.swift:1280), so no record names an attempt left at its
  end.

## What the ruling must add

1. **R1, precisely.** While events wait, the ENOENT arm keeps (X, epoch) with `copySerial`, marked as a re-queue. At the
   pin, with no layer after that serial the walk returns the pin layer's outgoing copy; otherwise it takes the copy the
   first layer after the re-queue adopted (index `end.serial − serial + 1`, or the engine's copy) and walks on.
2. **The record's form and its duties** (M4).
3. **R1's kill list.** §4 with the `next < layers.count` rows corrected (M3), plus `index = next` (T-E2), `return nil`
   (T-E3, T-E4), no walk-on (new T-E5), and the write guard forced true (a named barrier-down ENOENT test that checks
   `invariantViolations()`). Each is killed 2/2 in each order that reaches it, after a green first run, by an answer or
   a clause, never by a hang or a time limit.
4. **Serving.** Every T-E test serves each content a mutant can request (W, U, Z), only if its job exists, and asserts
   which contents were requested.
5. **Amendments.** Answer 6.3's header, first and second bullets (rulings :680-682); RR-21's :441;
   `integrate-rr21.md`'s D6 (:316-318) and residual (:597), with its must_not (:586) lifted for this fix; answer 8
   (:713-716), naming the tests the run shows killing `i5-pin-fold` in each order (T-E2 at least).
6. **Item 12's place in item 10's order.** Recommended: at step 1, before item 6's EngineFollow.swift removal, T-E1
   committed failing first, then R1 with rr21-T8b's change, T-E2 and T-E5 (green) and T-E3 and T-E4 (red first if red
   on `d5b2ab9`); at step 7, R1's kills and P-S, P-1, P-2 and P-3. A probe showing a different answer is blocking.
7. **The class.** The nested ENOENT (a commit's next target, re-queued by an ENOENT) is in it, and R1's branch covers
   it. P-3, if kept as a test, asserts visit-first's answers.
8. **Budget, estimated.** About 6-10 h of writing plus 3.7-5.5 h of mutant runs for the fix, its tests, kills and
   records (d4 §4's rates), plus 3-5 h for the four probes.
