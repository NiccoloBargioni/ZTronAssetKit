# Fidelity review of s3-r28-draft.md (S3-R28)

I am an independent reader (P4) and did not write the draft. This is a read-only check, against `9aa337c`
(`.worktrees/s3f`, clean). Nothing was built, run or measured (G2). "draft:N" is a line of `s3-r28-draft.md`. Sources: the
eleven decisions, `s3f-c22-issues.json`, f1, f2 and f3 with their reviews, S3-R27 (rulings :722-1276), S3-R16 (:150-172),
`docs/ORCHESTRATION.md:230-235`, and the fixer's cycle-22 section (`s3f.md:6902-7809`).

## Verdict: CORRECTED

Every decision is carried, and the writer flags each reading it had to make (notes 1, 3, 5, 6, 7 and 11). Two wrong
details misstate a binding review correction (Must fix 1 and 2). Once they are fixed, the text can go to the editor.

**Checked and right:**
- **Figures** match the findings and the logs: correct #1 and #2 (seeds, answers, start counts, 2/2 in
  `correct-probeC22TransferSpaceDrainJoin` and `…ApplyInRead.summary.log`); correct #3 (window, loads, 8/8, the race
  log's two outcomes, and the held-retry probe's "behind 4", shutDown 3/3); correct #4's six figures with loads, and
  sharedJob, userWaiters and ensures; reqs #1's pairs (`s3f.md:7792-7797`); correct #5's APM figures; reqs #3's mutants.
- **The header**, the commit count (44, `d5b2ab9..9aa337c`), `2abddd1` as the last `Sources` commit, `332b6cc` as e2-A1.6,
  "14 blocking, 7 in each lens", and the scratch paths (`s3f-probes-c22/`, `reqs/tools/`, `.build-s3f/c22/snap0`, `tools/`).
- **Code citations** at `9aa337c`: `EngineJobs.swift:289-297`, `:293`, `:327`, `:360-364`; `EngineFailures.swift:198-205`,
  `:566-568`, `:592-596`, `:858-859`, `:866-868`; `EngineDispatch.swift:740-743`, `:1259`, `:1298-1301`;
  `EngineState.swift:68`, `:867`; `EngineFollow.swift:392`, `:902`, `:1524-1525`, `:1976`, `:2017-2022`;
  `EngineCommands.swift:1001`, `:1004`, `:1009`, `:1016`, `:1065`, `:1884`; `EngineTimers.swift:110-112`;
  `ValidatedManifest.swift:15`, `:86-91`; SDK :8054-8060 (`_modify`); the probe file's `:251`, `:255-342`, `:303` and
  `:384-466`; the test lines (`…ReroutePinSpaceTests.swift:105-107`, `:160`, `:174`; `…SpaceReadTests.swift:35`, `:121`,
  `:189`; every DBT line in item 2; SharedMove `:354`; FollowBarrier `:1315`, `:1318`); `s3f.md:4385`, `:5526-5527`,
  `:7147-7149`, `:7151-7158`, `:7180-7182` and `:7758-7788`. `relane` is `metInItsAttempt`'s only caller (note 1 holds).
- **The review corrections** that bind: f1 must-fix 1 to 6 (W-HP, W-AWAY at both ends, W-DB, W-PD and T-F4 at step 0; the
  two causes; the stamp's lifetime and B11; (f) outside a visit); f2 must-fix 1 to 3; f3 must-fix 1 to 4; and the
  named should-fix items. e1-P1's four mutants (`s3f.md:7147-7149`) do map to B3's two, B2 and the publication end's
  write: "the end's count" is `stampsMinted` (`b83112c`: "record the count at a publication's end").

## Must fix

1. **C-2′ keeps a claim-held job; it does not retire it (draft:101).**
   - *The text:* "C-2′ retires a claim-held job whose (b) holds, with today's end state."
   - *The review* (f3 review must-fix 3 (i)): after C-2's step 1, C-2′ "moves the interest storages out whole to the
     freeing list, resets the counts, sets `heldLane = last` and writes `claimHeld`". Today's path keeps such a job for
     its claim (`settleRemoval`'s `claimHeld` arm, `EngineJobs.swift:427-431`), and
     `purgeThatEmptiesAJobKeepsItsEarlierRelane(claimed: true)` asserts it (`EnginePurgeWithdrawalTests.swift:102-104`:
     `held`, `heldLane == .bulk`).
   - *Failure:* a fixer who removes the job breaks the pending-claims shape's answers: the group's join, still in
     flight, finds no job.
   - *Correction:* "C-2′ empties a claim-held job whose (b) holds: after C-2's step 1 it moves the interest storages out
     whole to the freeing list, resets the counts, sets `heldLane = last` and writes `claimHeld`. The job stays, held by
     its claim, in today's end state."

2. **"A removal keeps today's count" drops must-fix 6's "in a visit" (draft:41).**
   - *The review:* "(f) applies only outside a visit… A removal **in a visit** uses (d) or (e), and otherwise today's
     count."
   - *The problem:* as written, the clause also covers the drain's replay of a removal. That replay is T-F9's
     withdrawal, which item 1 says the stamp fixes (draft:47). On `9aa337c` a replayed removal goes to the stamp branch
     (`EngineJobs.swift:293`), not to the count.
   - *Failure:* a fixer who dates every removal by the count leaves a replayed removal with an apply in the read
     re-queuing T. Visit-first met T in its attempt. No listed test has that shape.
   - *Correction:* "A removal made in a visit (`inFollowVisit` or `visitingAfterVerdict`, with `bringingInbound`
     included) keeps today's count. A replayed removal is dated by (f)."

## Should fix

1. **B3's kills (draft:56).** Keep f1's split. The forced-false mutant is killed by e1-P1's `pinSpaceRead` tests and
   T-F1a. The forced-true mutant is killed by T-F1b and `userJoinFromInside…` (`:174`). `pinSpaceRead` is a helper
   (`…ReroutePinSpaceTests.swift:56`); name its tests (`:147`, `:160`).
2. **Two route parts are only partly stated.**
   - C-5 (draft:108): add should-fix 5's other half: "otherwise the retired jobs are removed by key in a second pass".
   - C-4 (draft:103): add f3 §3.1's count: a job counts its purged ids with no Set and takes `.all`'s path when all are
     purged. §3.4's "C-4's count" kill depends on it.
3. **Step 7's records (draft:141-144).**
   - Name item 5's `followedLane` record (S3-R27 item 5). The fixer's status says it was not written
     (`s3f.md:6945`, `:7713-7714`), and it is in none of the four bullets.
   - Optionally add reqs #10's `s3f.md:7367` and `:5750-5755` (non-blocking).
4. **Citations.**
   - "None, in any cycle" is at `s3f.md:8214`; `:8213` is blank. The finding's off-by-one is carried at draft:142.
   - `metInItsAttempt`'s doc is at `EngineJobs.swift:280-288`, above the `:289-297` cited at draft:69.
5. **Label code reading.**
   - draft:47: "The stamp fixes correct #1 and T-F9" comes from the review's "What holds", which is code reading
     (UNCONFIRMED). Label it as the T-F7 clause after it is labelled.
   - draft:76: "It is red in every round" is true by construction, not measured. The verifier's `serve=true` arm printed
     ok(20 B) in 2/2 but asserted nothing.
6. **Two overstatements.**
   - draft:45: "The visit branch reads, in every state, the count it reads on `9aa337c`" is false for clause (b)'s joins
     (`continueInbound` sets `inFollowVisit` with `bringingInbound`, `EngineFollow.swift:1524-1525`). Write "in every
     state but clause (b)'s".
   - draft:66 says must-fix 1, 2, 3 and 5 bind "only through step 0's shapes". draft:36 already applies must-fix 2's
     two causes.
7. **The record of "why no scenario is lost" (draft:84, should-fix 9).** f2's reason, "never asserted", is the one f2
   review should-fix 4 corrects to "asserted only at random". Name should-fix 4, or state its correction there: cite
   `EngineFollowBarrierSharedMoveTests.swift:354`, or record that no test covers `EngineDispatch.swift:1078-1080`.
   Otherwise the bound record repeats a claim the review found inaccurate.
8. **The bound test's change (draft:52).** Have the draft record its old and new text (`attemptEnd?.stamped` → the
   record's stamp), as 12.2 required for rr21-T8b. f1 "must say" 12 asks for that record.
9. **B11's killer (draft:58).** f1's test for it needs "the first end's copy", which is item 1b's. Under the replay
   half, the clear's kill needs a second attempt that reads the first end's stale stamp (a replay) or stale count (a
   visit). Say so, so that the fixer does not wait for item 1b.
10. **C-3's placement "before `fourGroupJoins`' step-0 figure" (draft:102).** Step 0 measures `9aa337c`, where C-3 does
    not exist, so the placement cannot change that figure. It moves stage A's figures. Write "before stage A's
    figures".
11. **Note 12 is inaccurate (draft:189).** Cycle 22 did not take items 3's and 4's 'before' figures at the start of
    their steps. It planned to (`s3f.md:6917-6918`), but steps 5 and 6 never started, and "Their 'before' figures were
    not taken" (`s3f.md:7642-7643`). So no 'before' figure exists for either item.

## For the orchestrator

1. **The mapping (decision 7) against the findings file.**
   - All 14 blocking findings fit, except one part of correct #6. Its `:1001` (`isPurged`'s `.all` arm: 0 hits, text
     unchanged) is not in item 4, as note 14 says.
   - A possible route needs no new shape: f3 review must-fix 2's new `.all` test, built with the groups' joins waiting
     swept first, would reach `:1001` through `withdrawPurgedJoins` (`EngineCommands.swift:1016`), and could kill its
     mutant by value.
   - correct #2 maps to item 1, but its route is item 1b, so it stays open until then (draft:47 says so).
   - reqs #7 is closed by the cycle-23 verifiers' runs (item 6), not by the fixer.
2. **The fifth in-letter shape (note 7).** f3 review "must add" 1 names 40,000 one-member prefetch groups, four on each
   id. It is in-letter (k = 4, 12.1) and estimated at 8-16 ms after route C, so it may miss. Decision 3's "the
   in-letter shapes f3 names as ungated" can be read to include it. As drafted, it stays unmeasured. A ruling is needed
   either way.
3. **12.5.12's extension (note 11; draft:123)** covers the commits before route C's parts. It does not cover the steps
   4 to 7 commits after stage C. If `keptUnderThreeGroups` and `fourGroupJoins` miss as estimated (34-39 and 15-22 ms),
   the Benchmarks stage stays red at every later commit. Cycle 22 had the same state after e2-A2.5. Rule whether those
   commits may stay red, for the reported misses only.
4. **f3 review should-fix 3 is not named.** If C-2's read does not skip a job with nothing to withdraw, `userWaiters`
   and `ensures` (7.13 and 7.15 ms now) rise to about 7.5-9 ms (estimate). At or above 8.5 ms they start stages B and C,
   at the edge, and are not blocking. The per-stage measurement will show it. Naming should-fix 3 would settle C-2's
   read beforehand.
5. **Notes 1, 3, 5 and 6** carry the decisions faithfully as I read them:
   - the stamp's lifetime under must-fix 4, with the count kept at today's writer and lifetime;
   - "beyond clause (b)";
   - item 2 after the replay half;
   - option (i) inside C-2, once Must fix 1 corrects it.

   Of these, decision 5's order departs from a review: it omits f2 review "must add" 1's re-run of A-T-SD on f1's last
   commit, which item 1b could carry.
