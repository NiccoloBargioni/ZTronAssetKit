### S3-R28 item 1c (appended 2026-11-06 15:33, before run 11): the ENOSPC windows are known residual correctness risks

**The owner's ruling.** At 15:28 the orchestrator reported that f1c's review found both of f1c's routes UNSOUND (N27). It offered two options: record correct #1 and #2 as known correctness risks, the same way as the three 10 ms misses, or check route Q first. The owner answered: "Agreed let's document it as known risk". The orchestrator records the ruling as N28 (`s3f-c22-analysis/s3-r28-orchestrator-rulings.md`). This item decides where it differs from items 1 to 8 (S3-R28's header).

- **What leaves cycle 23:**
  - Item 1's step-0 shapes and item 1b are withdrawn. Item 1b is never appended, and route Q (`f1c-review.md` §3) is not ruled.
  - Correct #1 and #2 are not blocking in cycle 23. They are known residual correctness risks, by the owner's ruling.
  - Nothing changes in the code for them. `metInItsAttempt` (`EngineJobs.swift:289-297`), `Job.transferSpaceEnd`, `AttemptEnd.stamped`, and how any join, visit or replay is dated, stay as they are on `9aa337c`.
  - No failing test is committed for them, and item 8's early probe (point 6) does not run.
- **The class the ruling covers, "the ENOSPC windows":**
  - **The window** runs from a transfer's or a publication's ENOSPC end to the return of `spaceFailed`'s free-space read (`EngineFailures.swift:196-212`, `:564-596`).
  - **The class** is an answer that differs between the two visit orders (`.followVisitedFirst` and `.sweepFollowsFirst`) only because an event inside that window is dated against the window's end.
  - **Its known members** are correct #1 (PROBE-C22C-TS-DRAIN-JOIN), correct #2 (PROBE-C22C-APPLY-IN-READ), and the shapes of item 1's step-0 list.
  - **Such an answer** (S3-R16 1(a)) is recorded under the known risk and is not reported as blocking. This includes a shape that a verifier newly finds in the class.
  - **Not covered:** a broken MUST or invariant, a hang, or a flaky test inside the window. S3-R16 1(b) to 1(d) still block there.
  - A start count or metric that differs (S3-R16 item 2) stays non-blocking, as before.
- **What changes elsewhere in S3-R28:**
  - **Step 0** (item 5) has no ENOSPC shapes. It runs `verify.sh --quick`, then item 3's five new cases' 'before' figures, then the rest, in item 8's point 1 order with item 1's group gone.
  - **Item 4's kills:** e1-P1's mutants run on the code as it stands (N23 point 3).
  - **Item 6's hours** lose step 0's shapes (13-26 h, derived) and item 1b.
  - **Item 7's mapping:** correct #1 and #2 → item 1c.
  - **Item 2** (the flake) is unchanged. Item 1 changes no code, so T20 fires as it does on `9aa337c`.
- **The record.** The fixer writes in the draft, under "Known residual correctness risks (owner ruling 2026-11-06)". For each of correct #1 and #2 it gives:
  - **The timeline,** with its probe, seed and log: the findings file `s3f-c22-issues.json` (correct #1 and #2), and the probes' logs under `.build-orchestrator/s3f-probes-c22/` (`correct-probeC22TransferSpaceDrainJoin.summary.log`, `correct-probeC22ApplyInRead.summary.log`, `VerifyC22CorrectProbes.swift`).
  - **The user-visible effect,** in plain words. A download's or a publication's ENOSPC end can overlap a user request or a map apply that arrives during the free-space read. Then the swept-first order re-queues the job (T20) where visit-first gives the `.insufficientSpace` verdict. In both probes the second attempt succeeds, so the app sees an extra attempt instead of the error.
  - **Why it is not fixed:** reviews found the class's analyses UNSOUND four times: f1, f1b, and f1c's routes A and B (`f1-enospc-windows-review.md`, `f1b-join-rule-review.md`, `f1c-review.md`).
  - **What would close it:**
    - route Q (`f1c-review.md` §3), after an independent check of 3-5 h, at 44-67 h (estimates);
    - with the shapes that Q leaves open (its §6).
  - **The owner's re-open criterion:** how often it happens in the field.

  The section feeds ADR-057, and Stage 5's `RESIDUAL-RISKS.md` and `VERIFICATION.md`. The analyses are kept on the pushed branch `archive/build-orchestrator`.
- **Order for run 11, which starts now:**
  1. Step 1 (item 2) first.
  2. Then re-read the end of the rulings file. The owner is deciding whether the remaining C2 work stays: items 3 and 3b, and step 0's 'before' figures for item 3's cases and for S3-R27's items 3 and 4. The orchestrator appends that ruling. If nothing has been appended by then, go on in S3-R28's order.
