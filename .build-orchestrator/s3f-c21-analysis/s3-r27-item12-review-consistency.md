# S3-R27 item 12: consistency review

- **Reviewed:** `.build-orchestrator/s3f-c21-analysis/s3-r27-item12-draft.md` (201 lines, cited `d:n`). I checked it against S3-R27's header and items 1–11 and against S3-R26 (`.build-orchestrator/s3-rulings-s3f.md`, cited `R:n`), S3-R16's bar, CLAUDE.md G1–G4, C1–C7 and P1, and the code at `.worktrees/s3f` `d5b2ab9`. This was a read-only check: nothing was built, tested or run.
- **Verdict: CORRECTED.** There are five must-fix items, and each comes with its correction. With them applied, item 12 is consistent with S3-R16 to S3-R27 and with CLAUDE.md. Three gaps are in decisions (D2 to D4) and need a ruling; they are under "For the orchestrator".

## Checked, no finding

- 12.4's mapping matches `s3f-c21-issues.json` for every finding it lists.
- **P1 and G1.** Every edit is in WP-F's `Sources/ZTronAssetSync/**`, its tests, or 11.6's BenchSync files. `ValidatedManifest.swift` (WP-A's) is not edited (d:154). ARCHITECTURE is only proposed (S3-R6). Nothing under `Scripts/` is touched.
- **The kills.**
  - Each kill is by an answer or a clause (d:50), and the serving rule (d:42) rules out a time-limit kill.
  - `enoentAfterCancelIsTheCancellation` (`EngineRaceTests.swift:82-123`) reaches the ENOENT re-queue arm (`EngineDispatch.swift:1274-1283`) with no follow. With the guard forced true, the barrier-down clause (`EngineCommands.swift:2240-2241`) fires, so that kill can be met.
- **12.1.**
  - It matches `docs/ORCHESTRATION.md:162-167`.
  - `commitTwoStalledSubscribersTurns` asserts no budget (`BenchSyncCycle21.swift:161-175`), so d:14's FAIL rule leaves no out-of-bar shape gated.
- **The purge cases.** Every gated case has A1, A2 and d:145's decision rule, except the `.scope` copy case (O3).

## Must fix

1. **Labels that collide** (d:22, d:66-70, d:114-139, d:166-171).
   - **Text:**
     - "Step 7 adds R1's kills and A1's and A2's kills, beside item 5's." (d:170);
     - "A1's parts … A2's parts if triggered" (d:168-169);
     - "P-1 and P-2" (d:68).
   - **Evidence:**
     - "R1" already has three meanings:
       - S3-R11's R1, which S3-R16 1(a) uses (R:152);
       - `integrate-rr21.md`'s R1, which S3-R26's Names rule keeps (R:422);
       - item 3's R1, which has its own kill (R:872-874).
     - "A1" and "A2" also have three:
       - d2's route (a) in item 3 (R:832, and "Before A2 and A5" at R:838);
       - d3's A1 and A2 in item 4 and item 10 step 6 (R:928, R:1011);
       - `integrate-c21.md`'s A1–A13 (R:423).
     - P-1 to P-3 are SPEC's benchmarks (`SPEC.md:296-298`), and d:14 cites P-13 beside them. `integrate-c21.md` has clauses P1–P3 (R:423).
     - 12.3 itself mixes e2's A1.n and A2.n with d2's A3, A5 and A7 (d:120, d:137, d:139).
     - Step 7 also holds item 5's kills, so its "R1" and "A1" can each be read three ways, and the draft's records will inherit that.
   - **Correction:** add a header bullet that follows S3-R26's Names rule:
     - "**Names.** e1's and e2's labels carry their analysis: e1-R1; the probes e1-PS, e1-P1, e1-P2, e1-P3 and e1-PR; e2-A1 (e2-A1.1 to e2-A1.7), e2-A2 (e2-A2.1 to e2-A2.6) and e2-B. T-E1 to T-E5 and T-A-SCOPE keep their names. Unprefixed R1, An and P-n keep their earlier meanings."
     - Use the prefixed names at least in 12.4 and in the draft's records.

2. **"Red" is not defined for a probe** (d:72-74).
   - **Text:** "A different answer from visit-first's is blocking." … "A red probe with no route given here (P-3, P-R) stays out of the suite, as scratch evidence, and is reported as blocking with its probe and its log."
   - **Evidence:**
     - P-3 has `#require(state == .queued)` (d:69). That `#require` stops the probe before any answer is compared. e1 calls a `.blocked` state there "the move's own finding" (`e1-pin-requeue.md:216`), not an answer.
     - P-1 asserts "X requested once" (d:68). S3-R26 item 7 records "one more request" with the same answer as a residual risk (R:579, R:587).
     - Such a probe is red while its answers equal visit-first's. d:74 then makes it blocking where S3-R16 item 1 does not, and d:73's "the smallest change that makes the answers equal" has nothing to change.
     - S3-R26 already defines this (R:584, R:642): a probe is blocking only if it breaks S3-R16 item 1 in either order.
   - **Correction:**
     - Before d:73: "A probe is red when it breaks S3-R16 item 1 in an order that reaches it: a different answer, a broken MUST or invariant, or a hang (S3-R26 items 7 and 11). Its other observations, such as a request count or a job's state, are recorded with it."
     - In d:69: "P-3 records the state at the move and at the replay, with no `#require`, and runs on to the answers. A `.blocked` state with visit-first's answers is recorded as the move's finding (e1 §3)."

3. **Step 1 takes "all of" 12.2, while steps 7 and 8 take parts of it** (d:160, d:170-171).
   - **Text:** "Step 1 also takes 12.2, all of it before item 6's `EngineFollow.swift` removal in step 2:"
   - **Evidence:**
     - 12.2 holds its kills (d:50-64) and its records (d:84-86), and its C2 re-measures are item 9's (d:83).
     - d:170 puts R1's kills in step 7, and d:171 puts the records in step 8.
     - "This item decides" (d:1) settles a difference with items 1–11, not one inside item 12. A verifier can therefore report R1's kills as missing before step 2.
   - **Correction:** "Step 1 also takes these parts of 12.2, all of them before item 6's `EngineFollow.swift` removal in step 2 (12.2's kills are in step 7; its records and item 9's re-measures are in step 8):"

4. **D6's first sentence still contradicts R1** (d:79).
   - **Text:** "`integrate-rr21.md`'s D6 (`:316-318`) and its residual (`:597`) lose the ENOENT re-queue … D6's last sentence … holds for the commit and supersede ends only".
   - **Evidence:**
     - D6 opens "A pin holds only while waitingTarget(transfer, epoch) holds." (`integrate-rr21.md:316`).
     - Under R1, the pin holds after an ENOENT re-queue, while `waitingTarget` returns nil for `.queued` (`EngineFollow.swift:1581-1582`).
     - D1–D12 are invariants that S3-R26 item 1 binds (R:437).
     - d:78 amends the same sentence in S3-R26 item 1 (R:441), and d:79 amends D6's other two sentences. Leaving this one unamended reads as deliberate, and the header's general precedence (R:728) does not undo that reading.
   - **Correction:** add to d:79: "D6's first sentence reads as S3-R26 item 1's, amended above."

5. **`purgeWhileOwedTurns` cannot be "committed red"** (d:103, d:110-111, d:167).
   - **Text:** "if it misses on `d5b2ab9`, it is committed red right before A1's first part, under item 10's red-first rules" (d:111); "the cases, committed red where they miss" (d:167).
   - **Evidence:**
     - The case is already in the tree at `d5b2ab9` (`BenchSyncReroutes.swift:72`; d:103 says "it exists").
     - Its 10.04 ms run is a miss, and a passing run does not cancel it (R:761).
     - Item 10's rule commits a case that a step adds (R:992-994), and d:110's "in the scratch copy" also fits only a new case.
     - As worded, the rule cannot be met for this case, so a verifier can report a red-first violation that no commit can avoid.
   - **Correction:** add after d:111: "`purgeWhileOwedTurns` is already in the tree. It is not committed again. Its `d5b2ab9` figures, from cycle 21 and from step 0, are its 'before' figures, and its miss stands until A1 or A2 closes it."

## Should fix

1. **The red cases** (d:111, d:167).
   - Say whether the missing cases go into one red commit, as d:161 does for the T-E tests (reqs #13's reading).
   - Say that they stay red across A1's and A2's part commits until a part closes them, as item 3's pins do across its sub-steps (R:834). Otherwise S3-R26 item 11's "Every other commit stays green" (R:639) reads against A1.2 to A1.7.
   - Key d:111 on the HEAD where step 4 starts, as item 10's third bullet does (R:994).
2. **Answer 8** (d:80). All three of answer 8's bullets name rr21-T8b's kill (R:714-716), and d:80 amends only the first. Say that every rr21-T8b there reads "T-E2, with the other killers the run shows".
3. **Answer 6.3** (d:77). Its first bullet says "rr21-T8 and rr21-T8b pin it" (R:681). d:77 takes rr21-T8b out of the class but keeps that bullet. Drop rr21-T8b from the bullet.
4. **The PIN-END invariants test** (d:28).
   - Name it as an exception to S3-R26 item 1's "Answer, MUST and invariant assertions never change" (R:462).
   - Say the change lands in R1's commit, where the value type changes (the writer's #6).
5. **Item 9** covers only "items 1 to 4" (R:986).
   - Say that it covers 12.2 and 12.3 too, with inventory rows for A2.2's counter and compaction, A2.3's freeing turn and A2.5's heap pass. 12.2's "no new row" (d:83) stands.
   - In d:171, say whose lines "their lines" are.
6. **Line numbers after step 1** (d:165). Only item 6's `EngineFollow.swift` lines are found again by content. Other citations move too:
   - a P-1 or P-2 fix at `EngineJobs.swift:307` moves item 1's c6 site (`:796-799`, R:810), and 12.3's `:395`, `:412` and `:483`;
   - a sibling map moves item 6's clause site (`EngineCommands.swift:2275`, R:970).

   Say that every later step finds a moved citation by its content. The header's re-cite rule (R:752) covers only the analyses.
7. **Kills with no step.**
   - A probe fix's kills (d:73, "with its branches killed") are not in d:170's list. Put them in step 7, with R1's.
   - The `keepsEntry` literal's row (d:63) names no killer. Say that a PIN-END test is added if p4's killers do not kill it 2/2 in each order.
8. **12.1's records and row 14.**
   - No step takes 12.1's records. Add them to step 8, together with the doc at `BenchSyncCycle21.swift:156-158`, which still says such a miss is reported "open, for the owner".
   - Item 2's row-14 sentence is replaced (R:826), so d:113's "recorded only" has no figure to record. Say "recorded only if measured (11.2)", and re-point the "item 2" in d:8 and d:10 (the writer's #9).
9. **Two case shapes** (d:98, d:105-106).
   - **The `.scope` case:** name its scope. A scope of all 10,000 ids puts the per-id copy lookup in the figure, while a scope of a few ids withdraws almost nothing (e2 review :71).
   - **The retry case:** its jobs must be held by interests the purge withdraws. Otherwise `removeJob`'s heap scan (`EngineJobs.swift:483`) is never reached.
   - **The user-waiter case:** e2 review must-fix 10 words it as "user waiters or ensures".
10. **Route B's must-fix items** (d:3, d:153).
    - e2 review must-fix 1–5, 11 and 12 are about B (`e2-purge-review.md:26-76`, `:124`, `:138`), and 12.3 does not authorise B.
    - Say that all seven bind only B's re-specification, so that a verifier does not hold the cycle-22 fixer to them. d:153 says so only for 11 and 12.
11. **A doc that A1.3 makes false.** `EngineCommands.swift:1053` says the owed arm drops interests "in (id, token) order, as `withdrawPurged` drops them". Add that doc comment to 12.3's records.
12. **The exclusivity list** (d:122) names "A1.2's bucket". A1.2 also changes the owed batch and the queue's `.join` events in place (d:116), and e2 review must-fix 8 is about A1.2 as a whole. Say that the rule covers every in-place access.
13. **Step 1's R1 commit** (d:162) names "T-E2 to T-E5". T-E3 and T-E4 are committed red first (d:161) if step 0 finds them red. Say "with the T-E tests that step 0 found green".

## For the orchestrator

1. **T-E2 is not in step 0** (D4; d:159). Step 1 commits "every T-E test that is red on `d5b2ab9`" first, but step 0 runs only T-E1, T-E3, T-E4 and T-E5. T-E2's status therefore rests on code reading (d:37). Add T-E2 to step 0.
2. **A1.4 and `notifyObservers`** (D3).
   - A1.4's one `settleRemoval` per job cuts the mid-turn `notifyObservers` calls (`EngineJobs.swift:406`). Each of those calls evaluates the tests' conditions (`EngineCommands.swift:1723-1724`).
   - Item 3's audit covers only the answer-site suites, and it runs in step 5, after step 4 (R:838). A1.4 therefore lands with no audit.
   - Suggestion: one audit of the purge suites' predicates before A1.4 (e2 review should-fix 5; the writer's #4).
3. **The `.scope` copy case** (D3; d:154). It is the only gated case with neither a route nor a blocking class.
   - Suppose `isPurged`'s copy (`ValidatedManifest.swift:78-83`, WP-A's) decides a miss. d:145 makes that miss blocking, while S3-R8 makes a fix in another work package's files non-blocking, as `other-wp:a:` (R:13).
   - Rule which applies.
4. **R1's write** (D2). I agree with the writer's #7: put the ENOENT arm's write inside `if self.transition(transfer, to: .queued)` (`EngineDispatch.swift:1280`). A write placed before it can leave a record that the "still at its end" clause (`EngineCommands.swift:2243-2245`) reports. I also agree with the writer's #2, #5 and #11.
5. **A probe that cannot be built** (D2). No rule covers P-R if its shape cannot be built after a real attempt: its removal edge is untraced, and it runs in `sweepFollowsFirst` only (d:70). S3-R26 item 7's B-T5 rule is a precedent (R:585-587): record the attempt and the residual risk.
