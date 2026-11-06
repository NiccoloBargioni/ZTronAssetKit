### S3-R28 item 1c, amended (appended 2026-11-06 15:55): an independent check's corrections

An independent check of item 1c (`s3f-c22-analysis/s3-r28-item1c-review.md`, CORRECTED) found that it went beyond the owner's words and left gaps. This note amends item 1c, and decides where the two differ. The orchestrator records it as N29.

1. **Only correct #1 and #2 are exempt,** as N25 exempted only its three cases. This replaces item 1c's bullets "The window", "The class", "Its known members" and "Such an answer":
   - **What is exempt.** Correct #1's and #2's answers (S3-R16 1(a)) are recorded under the known risk, and are not reported as blocking.
   - **Correct #1's and #2's shape, by the line that decides it.**
     - The common cause: inside the window and swept first, T20 (`EngineJobs.swift:360-364`) re-queues the job, because `metInItsAttempt` returns false for an input that met the attempt on a visit-first engine. Visit-first gives the verdict's answers.
     - In correct #1, the drain replays an event that arrived before a transfer's end (a request, a withdrawal, a pinned batch or a chain), and the replay meets no stamp (`:293-294`).
     - In correct #2, an apply inside the end's read moves the count. So a follow's visit, owed since an apply before the end, is dated after the end (`:290-291`).
     - This holds at either end, because that line is the finding's own location (`failedAfter ?? transferSpaceEnd`).
     - A run that differs from the probes only in seeds, sizes, ids or fillers is the same finding.
   - **Outside the exemption:**
     - the second cause, a re-queue that visit-first makes and swept first never makes before the verdict (W-AWAY, W-DB);
     - any difference after the verdict defers (the late drain, W-JOIN-HOP);
     - a `metInItsAttempt` that returns true where visit-first re-queued.
   - **Every other answer difference** in or after an ENOSPC window is judged under S3-R16 1(a) as usual, and N21 stands there, with its reading of a visit-first answer that depends on timing. That includes a shape from item 1's former step-0 list, and one that a verifier newly finds.
     - Such a shape has no sound route, so the orchestrator takes it to the owner at once (item 8's point 4). The owner decides whether it joins the known risks.
     - The orchestrator has asked the owner whether the whole class should be known risks. Until the owner rules, this note holds.
2. **Not covered.** This replaces item 1c's "Not covered" bullet:
   - S3-R16 1(b) to 1(f) still block, inside the window and after it: a broken MUST or invariant, a hang or a job that nothing advances, a flaky test, a survivor or an unreached branch, and every gate.
   - Item 4's e1-PS, e1-P1 and e1-P2 kills run on the code as it stands (N23 point 3), and block until killed.
   - The exemption covers S3-R16 1(a)'s answers only.
3. **The user-visible effect,** in the record. This replaces the text after "in plain words.":
   - **Correct #1:** a user request is made while a download is in flight, and waits behind a map change's owed follow. It is replayed during the free-space read that follows the download's ENOSPC, and is counted as made after the failure.
   - **Correct #2:** a map change is applied during the free-space read that follows a publication's ENOSPC. It makes the owed move of an earlier map change onto the job count as made after the end.
   - **In both,** swept first re-queues the job (T20) where visit-first gives the ENOSPC verdict.
     - Swept first, the callers get `ok(100000 B)` after a second attempt: A, X and V in correct #1, and A and X in correct #2.
     - Visit-first answers them `failed(insufficientSpace(required: 100000, …))` after one attempt.
   - **What the probes do not cover:**
     - Both cap interactive retries at one attempt per run (`maxAttemptsPerRun = 1`, `VerifyC22CorrectProbes.swift:258`, `:387`; the default is 2, `SyncTuning.swift:44`).
     - Both script the second attempt to succeed.
     - Neither the default cap nor a second ENOSPC is probed.
4. **The archive.** This replaces "The analyses are kept on the pushed branch `archive/build-orchestrator`.":
   - The analyses stay under `.build-orchestrator/` and are never deleted (N25).
   - The archive branch takes a new local snapshot of them. Snapshots reach `origin` only with the owner's word (N25).
5. **Order for run 11.** Step 1 is in (`03c4e59`). The fixer's record commit `4b38eb4` follows item 1c as first written.
   1. Run `verify.sh --quick` on HEAD, and quote its last line in the status list. Step 1 changed only a test and the draft, so this run replaces step 0's run on `9aa337c`.
   2. On a commit of its own, amend the record to this note: correct #1 and #2 only, point 2's "Not covered", and point 3's effect. It may also name the reds suspected by code reading alone, labelled UNCONFIRMED and outside the known risk: W-AWAY and W-DB, W-JOIN-HOP at a publication's end and in the late drain, and `f1c-review.md` §6. The step is done when correct #1 and #2 each have the five fields, with citations, and the status list maps both → item 1c.
   3. Re-read the end of the rulings file for the owner's ruling on the remaining C2 work: items 3 and 3b, S3-R27's steps 5 and 6 (items 3 and 4: correct #5 and reqs #2), and step 0's 'before' figures for item 3's cases and for S3-R27's items 3 and 4.
      - If nothing has been appended, take those figures on a scratch copy of `9aa337c` (item 5).
      - Then go on from step 2, in item 5's order.
6. **Small facts:**
   - (a) `relane`'s guard (`EngineJobs.swift:327`) is frozen too, next to `metInItsAttempt`.
   - (b) The window's places: the transfer's end at `EngineFailures.swift:196-212`, the publication's end at `EngineDispatch.swift:1259` and `:1298-1301`, and the read at `EngineFailures.swift:564-596`.
   - (c) Item 6's hours: item 1b's 38-59 h was never in them.
   - (d) Item 4's kills: the e1-PS, e1-P1 and e1-P2 mutants run on the code as it stands.
