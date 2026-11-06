# Review of S3-R28 item 1c (P4, read-only)

I checked `s3-r28-item1c.md` (rulings :1582-1616) against these sources:
- S3-R28 (:1278-1580) and S3-R16 (:146);
- N21 to N28;
- correct #1 and #2 (`s3f-c22-issues.json`), with their two summary logs and `VerifyC22CorrectProbes.swift`;
- the f1, f1b and f1c reviews;
- `.worktrees/s3f` at `9aa337c`.

Nothing was built or run. Line numbers are at `9aa337c`.

## Verdict: CORRECTED

The core of item 1c is right:
- correct #1 and #2 are not blocking;
- no code, no test and no early probe;
- the step-0 shapes and item 1b are withdrawn;
- the record goes under its own heading.

These all check out:
- `EngineJobs.swift:289-297` and `:360-364`;
- `EngineFailures.swift:196-212` and `:564-596`;
- N23 point 3;
- the four UNSOUND verdicts;
- `f1c-review.md` §3, §6 and §9 (44-67 h, plus 3-5 h for the check);
- the seeds and the logs.

There are seven corrections. Corrections 1 to 3 change what a verifier reports.

## Must fix (for the note after item 1c)

1. **The scope goes beyond the owner's ruling.** The owner accepted "record correct #1 and #2 as known correctness risks, the same way as the three 10 ms misses". N25 carried those three misses "for these three cases only", and "Any other C2 shape they find is reported under the bar as usual". Item 1c exempts a whole class instead. The class includes the step-0 shapes, which were never measured: run 10 stopped before them (N28), and f1 calls T-F3 and W-PR green on `9aa337c` (:1331). It also includes "a shape that a verifier newly finds". That overrides the owner's "Keep it blocking" (N21) for every other shape, without asking him. Rename the header "The class the ruling covers, "the ENOSPC windows":" to "What the ruling covers:". Replace the bullets "Its known members ..." and "Such an answer ..." with:
   > - **What is exempt:** correct #1 and #2 only, as N25 exempted its three cases. Their answers (S3-R16 1(a)) are recorded under the known risk and are not reported as blocking. Any other answer difference in or after an ENOSPC window is judged under S3-R16 1(a) as usual. N21 stands there, with its reading of a visit-first answer that depends on timing. This includes a shape from item 1's former step-0 list and one that a verifier newly finds. Such a shape has no sound route, so the orchestrator takes it to the owner at once (item 8's point 4), and the owner decides whether it joins the known risks.

2. **"The class" contradicts its own members, so two verifiers can disagree.** It names one cause, an event "dated against the window's end", and a window that closes when the read returns. Item 1 names two causes (:1320, from f1 review must-fix 2). Its step-0 list also runs every shape in the late drain, which comes after the verdict defers (:1329). Three shapes are members by the list but outside by the definition:
   - W-AWAY: swept first never re-lanes T;
   - W-DB: x joins T after `recordDeferredVerdict`;
   - W-JOIN-HOP in the late drain, red on `9aa337c` by code reading (:1323).

   Replace the bullet "The class is ..." with:
   > - **Correct #1's and #2's shape**, by the line that decides it. Inside the window, swept first, T20 (`EngineJobs.swift:360-364`) re-queues the job because `metInItsAttempt` returns false for an input that met the attempt on a visit-first engine, while visit-first gives the verdict's answers.
   >   - In correct #1, the drain replays an event that arrived before a transfer's end (a request, a withdrawal, a pinned batch or a chain), and the replay meets no stamp (`:293-294`).
   >   - In correct #2, an apply inside the end's reads moves the count, so a follow's visit owed since an apply before the end is dated after the end (`:290-291`). This holds at either end, because that line is the finding's own location (`failedAfter ?? transferSpaceEnd`).
   >
   > A run that differs from the probes only in seeds, sizes, ids or fillers is the same finding. Outside it:
   >   - the second cause, a re-queue that visit-first makes and swept first never makes before the verdict (W-AWAY, W-DB);
   >   - any difference after the verdict defers (the late drain, W-JOIN-HOP);
   >   - a `metInItsAttempt` that returns true where visit-first re-queued.

3. **S3-R16 1(e) and 1(f) leak in.** "Not covered" lists only 1(b) to 1(d), so a verifier can read a survivor in the window's code as exempt. Item 4, however, keeps the e1 kills blocking until they are killed. e1-P1's mutants sit in `metInItsAttempt`'s replay rule and in the end's stamp (`s3f.md:7147-7149`). Replace the "Not covered" bullet with:
   > - **Not covered:** S3-R16 1(b) to 1(f) still block, both inside the window and after it. That means a broken MUST or invariant, a hang or a job that nothing advances, a flaky test, a survivor or an unreached branch, and every gate. Item 4's e1-PS, e1-P1 and e1-P2 kills run on the code as it stands (N23 point 3) and block until killed. The exemption covers S3-R16 1(a)'s answers only.

4. **The user-visible effect is wrong for correct #1.** In correct #1, V is made before the end, while T's attempt is held, and it is replayed in the read. A request made during the read is the probe's control (seed 2_029_201): it gives `ok` with 2 starts in both orders, so there is no difference. The text also hides the answer itself. Replace the text after "in plain words." with:
   > Correct #1: a user request is made while a download is in flight, and it waits behind a map change's owed follow. It is replayed during the free-space read that follows the download's ENOSPC, and it is counted as made after the failure. Correct #2: a map change is applied during the free-space read that follows a publication's ENOSPC. It makes the owed move of an earlier map change onto the job count as made after the end. In both cases, swept first re-queues the job (T20) where visit-first gives the ENOSPC verdict. The callers get `ok(100000 B)` after a second attempt: A, X and V in correct #1, and A and X in correct #2. Visit-first answers them `failed(insufficientSpace(required: 100000, …))` after one attempt. Both probes cap interactive retries at one attempt per run (`maxAttemptsPerRun = 1`, `VerifyC22CorrectProbes.swift:258`, `:387`; the default is 2, `SyncTuning.swift:44`). Both script the second attempt to succeed. Neither the default cap nor a second ENOSPC is probed.

5. **The archive claim is wrong.** `archive/build-orchestrator`, both locally and on `origin`, is `765102c` from 14:39. Its `f1c-review.md` is a 6-line "in progress" stub. So route Q (§3), §6 and §9 are not on that branch, although the record cites them. Nor are S3-R28, item 1c, or N26 to N28: its rulings file stops at line 1276. Replace "The analyses are kept on the pushed branch `archive/build-orchestrator`." with:
   > The analyses stay under `.build-orchestrator/` and are never deleted (N25). The archive branch's copy (`765102c`) predates S3-R28 and f1c's review. They reach the branch at the next snapshot, and reach `origin` only with the owner's word (N25).

6. **Run 11's order leaves three questions open.**
   - **Where step 0's `verify.sh --quick` runs.** Run 10's run on `9aa337c` stopped in its tests step (`.build-s3f/c23/quick0.log`, N28). Run 11 committed step 1 without one (`03c4e59`, 15:44). No `verify.sh` has run since 15:32 (`.verify-logs/tests.log`).
   - **What follows step 1.** "Go on in S3-R28's order" can mean step 0 or step 2.
   - **When the record is written.** Item 8's point 7 takes records last, so a cut-off can drop the record.

   Replace "Order for run 11" with:
   > - **Order for run 11** (step 1 is in, as `03c4e59`):
   >   1. Run `verify.sh --quick` on HEAD, and quote its last line in the status list. Step 1 changed only a test, so this run replaces step 0's run on `9aa337c`.
   >   2. Write the record above, on a commit of its own. It is done when correct #1 and #2 each have the five fields, with citations, and the status list maps both → item 1c.
   >   3. Re-read the end of the rulings file for the owner's ruling on the remaining C2 work: items 3 and 3b, and step 0's 'before' figures for item 3's cases and for S3-R27's items 3 and 4. If nothing has been appended, take those figures on a scratch copy of `9aa337c` (item 5). Then go on from step 2, in item 5's order.

7. **Small facts.**
   - (a) After "`metInItsAttempt` (`EngineJobs.swift:289-297`)", insert ", `relane`'s guard (`:327`)". Item 1 freezes that guard too.
   - (b) Replace "(`EngineFailures.swift:196-212`, `:564-596`)" with "(the transfer's end, `EngineFailures.swift:196-212`; the publication's end, `EngineDispatch.swift:1259`, `:1298-1301`; the read, `EngineFailures.swift:564-596`)".
   - (c) Replace "and item 1b." in the hours bullet with "; item 1b's 38-59 h was never in them (:1526)."
   - (d) Replace "e1-P1's mutants run" with "the e1-PS, e1-P1 and e1-P2 mutants run", as N23 point 3 names all three.

## For the orchestrator

- **N28 over-reaches in the same way.** Its "and any answer in the class" needs the same correction. If you want the whole class exempt, ask the owner in one line first: "Should other answer differences in the ENOSPC windows that a verifier finds also be known risks, or come to you one by one?" Must-fix 1 holds until he answers.
- **If he says yes,** define the class by T20, not by dating, so that it covers both causes and the late drain: "an answer that differs only because T20 (`EngineJobs.swift:360-364`) re-queues a job failed at an ENOSPC end in one order and not the other, before that job's space verdict, given at once or at the follow's end after `spaceFailed`'s deferral (`EngineFailures.swift:573-582`)".
- **Timing of the note.** Run 11 committed step 1 at 15:44, and `.build-s3f/c23/draft/` changed at 15:49. Append the note before run 11's re-read. Otherwise it goes on under item 1c as written.
- **Archive.** Snapshot `.build-orchestrator/` into the local archive branch now (must-fix 5). Pushing it needs the owner's word.
- **Re-open dossier.** The next version of `docs/REOPEN-WP-F.md` should take must-fixes 1, 4 and 5.
- **Pending C2 decision.** The owner's decision should also name steps 4 and 5 (S3-R27 items 3 and 4: correct #5 and reqs #2), not only their 'before' figures.
- **Optional.** The record can name the reds suspected by code reading only: W-AWAY, W-DB, W-JOIN-HOP at a publication's end and in the late drain, and Q's §6. Label them UNCONFIRMED and outside the known risk, so that a re-open starts from them.
