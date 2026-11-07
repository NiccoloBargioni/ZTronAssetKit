### S3-R28, the owner's close ruling (appended 2026-11-06 HH:MM): WP-F ends with option (e), a short close

At 16:33 the orchestrator gave the owner the priced options for ending WP-F sooner (`s3f-c22-analysis/end-sooner-options.md`: checked once independently, CORRECTED, then revised). The owner answered at about 16:40, choosing these options from the orchestrator's questions:
- **"(e) Short close"**, described as: "Merge what's on wp/s3f, add the long-purge log line, and run one short independent verification." The orchestrator's message with the question said: "Under (e), I'd record any new finding from the verification rather than fix it. Anything that breaks a MUST or hangs would come to you first."
- **"Accept the FAIL"**, described as: "The tests stay as written and red, and the misses are reported with their figures."
- **"Yes, the whole class"**, described as: "A different answer between the two visit orders, caused by an event inside the disk-full window, is recorded, not fixed. Broken MUSTs, hangs and flaky tests there still block."

The orchestrator records the ruling as N31 (`s3f-c22-analysis/s3-r28-orchestrator-rulings.md`). This note is WP-F's last ruling in cycle 23. Wherever it differs from S3-R28's items 1 to 8, item 1c and its amendment, or run 12's order, this note decides. The orchestrator stopped run 12 at 16:41 at `9e9a500`, with a clean worktree, and run 13 continues from there.

1. **What ends now.** WP-F does no more fix work, except point 5's log line and point 8's corrections.
   - **Not taken:**
     - item 5's steps 2 and 3 (item 3, route C);
     - item 3b, which is never appended;
     - item 1b and route Q;
     - item 5's steps 4 and 5 (S3-R27's steps 5 and 6: APM's answer turn and item 4's shapes);
     - what is left of item 5's step 6 (S3-R27's step 7): the kills and the default-tuning probe not yet committed, and the three unreached lines (`EngineCommands.swift:1001`, `:1004`, `:1009`).
   - **No production change except point 5's.** Item 1c's freeze stays: `metInItsAttempt` (`EngineJobs.swift:289-297`), `relane`'s guard (`:327`), `Job.transferSpaceEnd`, `AttemptEnd.stamped`, and how any join, visit or replay is dated.
   - **No new test except point 5's.** N7's five stay in their scratch copy (`.build-s3f/c23/bench0`), uncommitted, as N25's precedent says for a known miss: no code, test or bench.
   - **Run 12's seven commits** (`29dfb12..9e9a500`) stay. Point 6 records what each one closes.

2. **Known misses of the 10 ms limit, by the owner's ruling.** They are recorded and not routed, next to N25's three:
   - **The six gated purge misses** (correct #4, reqs #1): `oneGroup`, `oneMemberGroups`, `oneGroupScope`, `sharedJobFourGroups`, `fourGroups` and `retryJobs`. Each gets the draft's figures and loads after e2-A2.5 (`s3f.md:7611-7617` at `9aa337c`) and the verifier's (correct #4).
   - **N7's five, by estimate** (`s3-r28-final.md:125-129`).
   - **f3b-review §7's two variants and route A §9's third shape, by estimate** (`end-sooner-options.md` §3.0, R4).
   - **APM's answer turn** (correct #5), measured by probe: 11.10 ms for groups and 13.93 ms for users, and 9.37 ms for one group, at the edge (`s3-r28-final.md:157`).
   - **Item 4's k = 2 and k = 4 shapes** (reqs #2; correct #9). They are unmeasured: a turn at k ≥ 4 is estimated at 9-10 ms (`c21/d3-many-holders.md:25-26`, UNCONFIRMED).
   - **f3c's new shapes, by estimate and UNCONFIRMED:**
     - `readmit` scans the heap once per failed candidate (`EngineReadmission.swift:165-167`), and `removeJob` does so outside a walk (`EngineJobs.swift:517-520`): 27-55 ms a turn with 5,000-10,000 `.retry` entries;
     - in production, `originID` is parsed on every gate read (`HTTPRemoteSource.swift:116-118`): 15-60 ms more per 10,000 reads, which the benches' fake hides (`f3c-open-shapes.md`; its review).
   - **Each entry gives:**
     - its figure, measured with its loads, or an estimate;
     - the route that would close it, and that route's hours from the analyses;
     - the owner's re-open criterion: how often the misses happen in the field.

3. **The red gated cases, by the owner's ruling: the FAIL is accepted.**
   - **The six stay as written, and red.** G3 holds: no `withKnownIssue`, no `.disabled`, and no change to `allCases`, `c2Budget` or the Benchmarks tree.
   - **`verify.sh --full` on the final HEAD** is expected to end `VERIFY: FAIL (1 failed: benchmarks)`. That is WP-F's accepted end state when its only causes are the six and P-13 (WP-B's; S3-R26 item 10), each named from the benchmarks log (item 5's close).
   - **Every other stage of `--full`** runs and passes on its own. A failure in any other stage is a finding, handled under point 8.
   - Item 5's "Red cases across the cycle" still applies: each commit message names the six as red.

4. **The ENOSPC class, by the owner's ruling: the whole class.** This replaces the bullets "Outside the exemption" and "Every other answer difference" in item 1c amended, point 1.
   - **What is exempt** is every answer in the class that N29 defines by T20: "an answer that differs only because T20 (`EngineJobs.swift:360-364`) re-queues a job failed at an ENOSPC end in one order and not the other, before that job's space verdict, given at once or at the follow's end after spaceFailed's deferral (`EngineFailures.swift:573-582`)".
   - **Its known members:**
     - correct #1 and #2, measured;
     - by code reading only, and UNCONFIRMED: W-AWAY, W-DB, W-JOIN-HOP at a publication's end and in the late drain, item 1's former step-0 shapes, and `f1c-review.md` §6's shapes.
   - **Such an answer** (S3-R16 1(a)) is recorded under "Known residual correctness risks (owner ruling 2026-11-06)" and is not reported as blocking. That includes a shape that a verifier newly finds.
   - **Not covered:** S3-R16 1(b) to 1(f), inside the window or after it. Under this close they follow point 8.

5. **S1, the long-purge log line** (`end-sooner-options.md` §4).
   - **Where:** in `performPurge`'s first turn, between `self.state.commitTurnMarksForTests?(false)` and `?(true)` (`EngineCommands.swift:968`, `:976`). That is the interval the purge benches time.
   - **What it does:**
     - It reads the injected monotonic clock at both marks (`self.environment.time.monotonicNow()`, as `EngineManifest.swift:140` does) and takes `seconds(since:)` (`Time.swift:40`).
     - Above 10 ms, it writes one `.info` line on `.sync` through `self.log.log` (as `EngineJobs.swift:1217` does), with the milliseconds, the job count and the group count.
   - **Limits:**
     - The line holds no ids, hashes, URLs, paths or keys.
     - No public API changes.
     - Nothing new runs on the main thread (C2).
     - The clock is the injected one (C4).
     - The threshold is one named constant, documented as C2's limit.
   - **Test** (G4): through `logTap`, with a time source that the test advances and no sleeping:
     - a turn above 10 ms writes exactly one line, with its three fields;
     - a turn at or below 10 ms writes none.
   - **Record:** the line's text is a soft contract.
     - The draft records it as a decision, and ADR-057 carries it into `docs/DECISIONS.md` at the merge.
     - It names the use at a re-open: an app that adopts the kit reads the line through its own `LogSink` or `OSLogStore`.
     - Whether `.info` lines are kept for `OSLogStore` is not checked (C7, UNVERIFIED).
   - **Hours:** 1.5-3 h (estimate). Item 8's point 2(e) applies: past 4.5 h, stop with a `PUT-BACK`.

6. **The records** (S3-R27's step 8, as options (d) and (e) price it).
   - **The findings.** In the draft's cycle-23 status list, each of cycle 22's findings (correct #1 to #10, reqs #1 to #11) gets its state at the final HEAD, with its figure, route and hours from the analyses. The state is one of:
     - closed, with its commit and evidence;
     - a known miss (N25, or point 2);
     - a known risk (point 4);
     - open, and recorded under this ruling.
   - **Run 12's commits:**
     - for each kill test, the survivor it kills, with its mutant log;
     - reqs #8's guard (`29dfb12`).
   - **What is left open there:**
     - the survivors and kills not done (correct #7, reqs #3);
     - the default-tuning probe, if it was not run;
     - the three unreached lines (correct #6, reqs #4).
   - **The records that S3-R27's step 8 and run 12's order (point 2) list:**
     - reqs #5, #6 ("Authorised edits outside WP-F"), #9 and #10;
     - item 7's d5 pin;
     - item 8's `releaseRerouteHolds` row;
     - item 9's inventory rows;
     - the false 11.6 record (`s3f.md:6959` against `:8212`).
   - **The sections** for points 2 and 4.
   - **"Not verified":** everything this cycle could not run, which feeds `VERIFICATION.md`. Row 3's fix (`03c4e59`) stays there until the verification confirms it.
   - **Done** when every finding has a state and evidence, and the sections exist with citations.

7. **The close** (item 5's step 7, narrowed). On the final HEAD, run `verify.sh --quick`, then `--gates-only`, then `--full`. Quote each one's last line in the status list. Point 3 says which FAIL is the accepted end state.

8. **The verification, and what happens to its findings.**
   - **When it runs.** When the fixer's status list shows points 5 to 7 done, the two verifiers run once on that HEAD (item 6), lens 3's heavy checks first. Point 1 leaves the fixer no open blocking item, so item 8's point 5 allows the verification.
   - **What they check:**
     - row 3's fix (correct #3);
     - run 12's commits;
     - S1;
     - every record, true against the code and the logs (G2);
     - in the heavy checks, the re-measures of cycle 22's "closes" (reqs #7).
   - **What they do not re-open:** point 2's known misses, point 4's known risks, and point 1's work not taken. They may report a new shape; it is judged as below.
   - **A new finding, as the owner chose:**
     - **Against this ruling's own work** (S1 or a record): corrected before the merge. A wrong record is fixed (G2). S1 is fixed if the fix is small (1.5 h or less, estimate). Otherwise it is reverted, and the revert is recorded.
     - **A broken MUST or invariant** (S3-R16 1(b)), or **a hang or a job that nothing advances** (1(c)): the orchestrator takes it to the owner at once, before the merge.
     - **Row 3's fix found not to hold** (1(d)): recorded, and the flake stays open.
     - **Anything else:** recorded as open in the draft, ADR-057 and `RESIDUAL-RISKS.md`, and not fixed.
   - **No second verification runs,** unless the owner rules one after a 1(b) or 1(c) finding.

9. **Order and budget for run 13.**
   1. Point 5 (S1), on its own commits: the test red first, then the line.
   2. Point 6 (the records).
   3. Point 7 (the close).
   - Item 6's re-read at each step stays, so the orchestrator can rule a `PUT-BACK`.
   - If the weekly limit cuts the run, the next run continues from HEAD in this order.
   - **Read narrowly:** this note, item 1c and its amendment, run 12's order, and the draft's cycle-23 section, with `end-sooner-options.md` §4 for S1. Open older text only where these cite it.

10. **After the verification, the orchestrator's steps.**
    - It merges `wp/s3f` `--no-ff` into `feature/asset-kit` and runs the post-convergence list (`end-sooner-options.md`, rows 19-27):
      - the tools-6.4 check and the phase-A gates;
      - TSan and `--perf` on an idle host;
      - P-13's verifier, on the p99;
      - the mutation re-check;
      - ADR-057, with the records of points 2, 4 and 8;
      - the `s3-merged` tag;
      - Stage 5;
      - the final archive snapshot, and the dossier's final version.
    - Stage 5's `--full` FAIL at benchmarks is the accepted end state (point 3).
