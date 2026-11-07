### S3-R28, the owner's close ruling (appended 2026-11-06 HH:MM): WP-F ends with option (e), a short close

At 16:32 the orchestrator gave the owner the priced options for ending WP-F sooner (`s3f-c22-analysis/end-sooner-options.md`: checked once independently, CORRECTED, then revised). The owner answered at about 16:40, choosing these options from the orchestrator's questions:
- **"(e) Short close"**, described as: "Merge what's on wp/s3f, add the long-purge log line, and run one short independent verification."
  - The orchestrator's message with the questions said: "The verification checks what (d) leaves unchecked: the fix for the flaky test, run 12's commits, and the records."
  - It also said: "Under (e), I'd record any new finding from the verification rather than fix it. Anything that breaks a MUST or hangs would come to you first."
- **"Accept the FAIL"**, described as: "The tests stay as written and red, and the misses are reported with their figures. G3 stays intact, and the six red cases become the to-do list for a re-open. Every later --full stays red until they're fixed."
- **"Yes, the whole class"**, described as: "A different answer between the two visit orders, caused by an event inside the disk-full window, is recorded, not fixed. Broken MUSTs, hangs and flaky tests there still block."

The orchestrator records the ruling as N31 (`s3f-c22-analysis/s3-r28-orchestrator-rulings.md`). It records as N32 the two independent checks of this text (`s3-r28-close-e-review-fidelity.md` and `s3-r28-close-e-review-consistency.md`, both CORRECTED, applied here).

This note is part of S3-R28, and it closes cycle 23's routing for WP-F.
- **Where it decides:** wherever it differs from S3-R16 to S3-R28 (including S3-R28's items 1 to 8, item 1c and its amendment, and run 12's order), from a specification or from an analysis.
- **What may follow it:** only two kinds of text, and each decides where it differs from this note:
  - the orchestrator's rulings on `PUT-BACK` commits (point 9);
  - the owner's answers on what points 3 and 8 take to the owner.
- **Where run 13 starts:** the orchestrator stopped run 12 at 16:41 at `9e9a500`, with a clean worktree, and run 13 continues from there.

1. **What ends now.** WP-F does no more fix work, except point 5's log line, point 6's mutant runs and point 8's corrections.
   - **Not taken:**
     - what is left of item 5's step 0: the 'before' figures in `.build-s3f/c23/bench0` (item 3's five and APM's probe), and S3-R27 item 4's cases, which were never written. The status list marks step 0 as closed by this note. Run 12's order point 3 (rulings:1679-1681) no longer applies;
     - item 5's steps 2 and 3 (item 3, route C);
     - item 3b, which is never appended;
     - item 1b and route Q;
     - item 5's steps 4 and 5 (S3-R27's steps 5 and 6: APM's answer turn and item 4's shapes);
     - what is left of item 5's step 6 (S3-R27's step 7): the survivors with no committed test (r2b, b22-no-run-owner), e1-R1's kill table, the default-tuning probe, and the three unreached lines (`EngineCommands.swift:1001`, `:1004`, `:1009`). The mutant runs for run 12's committed tests are point 6's.
   - **No production change except point 5's.** Item 1c's freeze stays: `metInItsAttempt` (`EngineJobs.swift:289-297`), `relane`'s guard (`:327`), `Job.transferSpaceEnd`, `AttemptEnd.stamped`, and how any join, visit or replay is dated.
   - **No new test except point 5's.** N7's five stay in their scratch copy (`.build-s3f/c23/bench0`), uncommitted. N25's precedent for a known miss applies: no code, test or bench.
   - **Run 12's seven commits stay** (`247e85b..9e9a500`, that is `29dfb12` to `9e9a500`). Point 6 records what each one closes.

2. **Known misses of the 10 ms limit, by the owner's ruling.** They are recorded and not routed, next to N25's three:
   - **The six gated purge misses** (correct #4, reqs #1): `oneGroup`, `oneMemberGroups`, `oneGroupScope`, `sharedJobFourGroups`, `fourGroups` and `retryJobs`. Each gets four sets of figures with their loads:
     - the draft's, after e2-A2.5 (`s3f.md:7611-7617` at `9aa337c`);
     - the step-8 gate run and its re-run (reqs #1: 17.82 to 62.56 ms at loads of 2.35 to 6.07; `:7726-7745` at `9aa337c`);
     - the verifier's run (correct #4);
     - point 7's `--full`.
   - **N7's five, by estimate** (`s3-r28-final.md:125-129`):
     - `keptUnderThreeGroups` 38-48 ms and `fourGroupJoins` 15-22 ms, today;
     - the other three are estimated only after route C, which is not taken, so they have no figure for today (`end-sooner-options.md` §3.0, R4).
   - **f3b-review §7's two variants and route A §9's third shape.** They are estimated only after route C and item 3b's merge, or after route C and route A's A-2, and have no figure for today (R4).
   - **APM's answer turn** (correct #5): 11.10 ms for groups, 13.93 ms for users, and 9.37 ms for one group, which is at the edge (`s3-r28-final.md:157`). Measured by probe in release with `-enable-testing`, in-actor, best of 3, at a 1-minute load of 9.85 to 8.65.
   - **Item 4's k = 2 and k = 4 shapes** (reqs #2; correct #9). They are recorded with these misses as unproven, not as a miss: unmeasured, and estimated at 9-10 ms at k ≥ 4, which is at the edge, not above it (`c21/d3-many-holders.md:25-26`, UNCONFIRMED).
   - **Each entry gives:**
     - its figure: measured with its loads, or an estimate with its base (today, or after route C). Where no figure exists for today, it says "no figure for today";
     - the route that would close it, with that route's hours from the analyses, or "not estimated" (APM, item 4);
     - the owner's re-open criterion: how often the misses happen in the field.
   - **f3c's open shapes (§8) are not known misses.** The options the owner chose from did not show them, so the owner has not ruled on them. Both are estimates, UNCONFIRMED:
     - **The heap scans.** `readmit` scans the heap once per failed candidate (`EngineReadmission.swift:165-167`), and so does `removeJob` outside a walk (`EngineJobs.swift:517-520`): 27-55 ms a turn with 5,000-10,000 `.retry` entries (`f3c-open-shapes.md:163-164`; its review :31). They are recorded as open, unmeasured and with no reviewed route (point 6), and the orchestrator reports them to the owner.
     - **The production `originID` cost.** In production, each gate read builds `originID` three times, and HTTP parses its URL each time (`HTTPRemoteSource.swift:116-118`). That adds 15-60 ms per 10,000 gate reads, at an unmeasured 0.5-2 µs a build, and the benches' fake hides it (`f3c-open-shapes.md:159-160`; its review :102). It goes under "Not verified" (point 6), because no bench figure includes it.

3. **The red gated cases, by the owner's ruling: the FAIL is accepted.**
   - **The six stay as written, and red.** G3 holds: no `withKnownIssue`, no `.disabled`, and no change to `allCases`, `c2Budget` or the Benchmarks tree.
   - **`verify.sh --full` on the final HEAD** is expected to end `VERIFY: FAIL (1 failed: benchmarks)`. That is WP-F's accepted end state when its only causes are the six and P-13 (WP-B's; S3-R26 item 10), each named from the benchmarks log (item 5's close).
   - **Every other stage of `--full` must run and pass on its own,** and the benchmarks stage must have no red case but the six and P-13.
     - A case that is red only at a 1-minute load above 10 follows rulings :763, with its loads. `commitTwoTokensTurns` (9.02 ms, reqs #11) is the case nearest to the limit.
     - Any other failure, found by the fixer or a verifier, is not the accepted end state. Unless point 8 corrects it as this note's own work, it is recorded, and the orchestrator takes it to the owner before the merge.
     - If the fixer finds such a failure at point 7, it is a stop under item 8's point 3.
   - **Commit messages.** Each names every case red at that commit, as item 5's "Red cases across the cycle" requires: the six, P-13 (WP-B's) and, on S1's red-first commit, S1's test.
   - **The /goal's Done is not met** (`PROMPT.md:96`: `VERIFY: PASS` with passing benchmarks). The owner set it aside for WP-F with this answer, and Stage 5's report says so.

4. **The ENOSPC class, by the owner's ruling: the whole class.** This replaces, in item 1c amended point 1, its lead ("Only correct #1 and #2 are exempt") and its bullets "What is exempt", "Outside the exemption" and "Every other answer difference". Its description of correct #1's and #2's shape stays.
   - **What is exempt** is the class in the owner's words: an answer that differs between the two visit orders, caused by an event inside an ENOSPC window (S3-R16 1(a)).
     - The window is item 1c's: from a transfer's or a publication's ENOSPC end to the return of `spaceFailed`'s free-space read (item 1c amended, point 6(b)).
     - N29's T20 test finds its members: "an answer that differs only because T20 (`EngineJobs.swift:360-364`) re-queues a job failed at an ENOSPC end in one order and not the other, before that job's space verdict, given at once or at the follow's end after spaceFailed's deferral (`EngineFailures.swift:573-582`)".
     - Where the two differ, the owner's words decide. A late-drain difference is exempt only when the event that causes it falls inside the window. Otherwise it follows point 8, and the orchestrator asks the owner in one line whether it joins the class.
   - **Its members:**
     - correct #1 and #2, measured;
     - suspected by code reading only (UNCONFIRMED), each a member only if a run shows the difference: W-AWAY, W-DB, W-JOIN-HOP at a publication's end, W-JOIN-HOP in the late drain (under the rule above), item 1's former step-0 shapes, and `f1c-review.md` §6's shapes.
   - **Such an answer** is recorded under "Known residual correctness risks (owner ruling 2026-11-06)" and is not reported as blocking. That includes a shape that a verifier newly finds.
   - **Not covered, and still blocking** (the owner's answer):
     - Inside the window: a broken MUST or invariant, a hang or a job that nothing advances, and a flaky test (S3-R16 1(b) to 1(d)). Point 8 takes each one to the owner before the merge.
     - 1(e) and 1(f) there, and every finding after the window, follow point 8 like any other finding.

5. **S1, the long-purge log line** (`end-sooner-options.md` §4).
   - **Where:** in `performPurge`'s first turn (`EngineCommands.swift:968-976`). That is the interval the benches record as the purge's first turn (`BenchSyncCycle22Purge.swift:11-12`, `:30`); their gate is the heartbeat (`:32`).
     - The first clock read and the counts come right after `self.state.commitTurnMarksForTests?(false)` (`:968`).
     - The second read and the line come right after `?(true)` (`:976`), before the `await` at `:978`.
     - Nothing new awaits or spawns, so no REENTRANCY row is added (C3).
   - **What it does:**
     - It reads `self.environment.time.monotonicNow()` at both points (as `EngineManifest.swift:140` does) and takes `seconds(since:)` (`Time.swift:40`).
     - The counts are `state.jobs.count` and `state.groups.count` as the turn begins, before the walk removes jobs (O(1), C2).
     - Above 10 ms, it writes one `.info` line on `.sync` through `self.log.log` (as `EngineJobs.swift:1217` does), with the milliseconds and the two counts.
   - **Limits:**
     - The line holds no ids, hashes, URLs, paths or keys.
     - No public API changes.
     - Nothing new runs on the main thread (C2).
     - The clock is the injected one (C4).
     - The threshold is one named constant, documented as C2's limit. The code and the constant stay in `Sources/ZTronAssetSync/`.
   - **Test** (G4, and S3-R2's rules):
     - **The S3-R2 rules:**
       - its display name starts with a SPEC ID such as `R-OBS-1`, since an unknown ID fails the trace gate (`Scripts/gates.py:129-140`);
       - `.timeLimit(.minutes(1))`;
       - `ManualTimeSource` only;
       - `@available(macOS 15.0, iOS 18.0, *)` on each `@Test`.
     - **How it drives the line:** through `readForTests` (`EngineRegressionCycle3Tests.swift:459`), the test sets `commitTurnMarksForTests` to a closure that calls `harness.time.advance(by:)` when told `true`. This is the seam the benches set (`BenchSyncCycle21.swift:898-900`). It then reads `harness.tap.lines`:
       - advanced 11 ms: exactly one line with S1's text, on `.sync` at `.info`, with its three fields;
       - advanced exactly 10 ms: no such line.
     - Every changed line of S1 is reached (S3-R25 item 10). WP-H's `ManualTimeSource` and `RecordingLogTap` are used as they are (P1).
   - **Record:** the line's text is a soft contract.
     - The draft records it as a decision, and ADR-057 carries it into `docs/DECISIONS.md` at the merge.
     - It names the use at a re-open: an app that adopts the kit reads the line through its own `LogSink` or `OSLogStore`.
     - Whether `.info` lines are kept for `OSLogStore` is not checked (C7, UNVERIFIED).
   - **Hours:** 1.5-3 h (estimate). Item 8's point 2(e) applies to S1 too: past 4.5 h, stop with a commit whose subject starts `PUT-BACK: close 5: `.

6. **The records, and the mutant runs** (S3-R27's step 8, as options (d) and (e) price it).
   - **The findings.** In the draft's cycle-23 status list, each of cycle 22's 21 findings (correct #1 to #10, reqs #1 to #11) gets its state at the final HEAD, with its figure, route and hours from the analyses. The state is one of:
     - closed, with its commit and evidence;
     - a known miss (N25, or point 2);
     - a known risk (point 4);
     - item 7's disposition (correct #8: WP-B's, S3-R26 item 10; correct #10: no action);
     - to be closed by point 8's verification (reqs #7). The orchestrator records the verification's result in ADR-057 (point 10), together with its result for row 3;
     - open, and recorded under this ruling.
   - **Run 12's work** (`247e85b..9e9a500`; its scratch files are in `.build-s3f/c23/`):
     - **The five kill tests:** `1b911a1`, `486ee2a`, `8b252f2`, `06880a8` and `9e9a500`, with the survivors each one names (b22-no-waiter-owner; p7 and r5; r8; vy; r2c).
       - Each needs its mutant runs: 2/2 in each order that reaches the branch, with logs (S3-R3). Run 12 made none.
       - Run 13 makes them with `tools/mut23s.py`, together with `p2-after-verdict-replay-rule`, and adds no test (0.5-1 h, estimate).
       - A test that kills nothing is recorded and not changed, and its survivor stays open.
     - **`64f276d`** (e1-P1's other side, S3-R28 item 4) and run 12's e1 runs (`mut-e1.txt`, with logs in `mut/`), recorded as those logs show them.
     - **reqs #8's guard** (`29dfb12`).
   - **What stays open:** the survivors and kills that point 1 does not take (correct #7, reqs #3), the default-tuning probe, and the three unreached lines (correct #6, reqs #4).
   - **Every record that S3-R28 item 4's "S3-R27's step 8 (step 7)" lists (rulings:1488-1493), and run 12's order point 2 (:1674-1678):**
     - reqs #6's "Authorised edits outside WP-F" (the eight bench files, 11.6 as amended), with `s3f.md:8214` and `:8237-8238` (at `9aa337c`) corrected, and the ARCHITECTURE §1.2 proposal;
     - the false 11.6 record (`s3f.md:6959` against `:8212-8214` at `9aa337c`; `:7010` against `:8564-8566` at `9e9a500`);
     - reqs #9's ownership record;
     - item 5's `followedLane` record, and reqs #10's stale records. These include the doc comment at `BenchSyncCycle21.swift:156-158`, which is a comment-only test edit;
     - item 9's rows, item 7's d5 pin, item 8's `releaseRerouteHolds` row, the "Proposed document changes" of cycles 21 to 23 (reqs #5), and the 12.x records (12.2's, 12.3's, 12.5.9's, 12.5.18's).
   - **N25's record, brought up to f3c's review:** case 2 at 12.9-23.3 ms and case 3 at about 21-34 ms. Both are estimates, after route C and item 3b's merge (`f3c-open-shapes-review.md:37`, `:59`). The draft still calls f3c's figures "unreviewed" (`s3f.md:8159-8160` at `9e9a500`). Add the swept-first backoff residual (f3c's review, its must-add 6).
   - **The sections** for point 2, with f3c's open shapes beside them, and for point 4.
   - **"Not verified":** everything this cycle could not run, which feeds `VERIFICATION.md`. That includes:
     - row 3's fix (`03c4e59`), until the verification confirms it;
     - f3c's production `originID` cost;
     - what the verification does not reach (point 8).
   - **Done** when every finding has a state and evidence, and the sections exist with citations.

7. **The close** (item 5's step 7, narrowed). On the final HEAD, run `verify.sh --quick`, then `--gates-only`, then `--full`. Quote each one's last line in the status list. Point 3 says which FAIL is the accepted end state.
   - **What is left of item 9** (rulings:984-988): only S3-R25 item 10 for S1's lines, and the margin list from the close's benchmarks log. Its inventory rows are in point 6.
   - **How the runs are made:**
     - `sim.lock` is held for the coverage runs.
     - `--full`'s benchmarks run at a 1-minute load of 10 or less when one occurs, with the loads recorded (item 6).
   - **Left to the verifiers:** the iOS Simulator suite and A-T-SD's 30 simulator iterations (item 2's evidence at the close) are in their heavy checks, and the status list says so.
   - **The commit that quotes the lines** changes only the draft.

8. **The verification, and what happens to its findings.**
   - **When it runs.** When the fixer's status list shows points 5 to 7 done, the two verifiers run once on that HEAD (item 6), lens 3's heavy checks first. Point 1's items stay open because the owner chose (e), and (e) includes this verification, so item 8's point 5 does not hold it back.
   - **What they check:**
     - row 3's fix (correct #3);
     - run 12's commits, with point 6's mutant runs;
     - S1;
     - every record, true against the code and the logs (G2);
     - in the heavy checks, the re-measures of cycle 22's "closes" (reqs #7). The same benchmarks run re-measures reqs #11's load-only cases.
   - **Which mutants they run.** "The mutants" in item 6's heavy checks are point 6's mutant runs, re-run as S3-R3 says. They are not the survivors that point 1 leaves open, nor row 23's re-check of the 11 survivors, which follows the merge.
   - **What they do not reach** goes under "Not verified".
   - **What they do not re-open:** point 2's known misses, point 4's known risks, and the work that point 1 does not take. They may report a new shape, which is judged as below.
   - **A new finding, as the owner chose:**
     - **A broken MUST or invariant** (S3-R16 1(b)), or **a hang or a job that nothing advances** (1(c)), anywhere, or **a flaky test inside an ENOSPC window** (1(d); point 4): the orchestrator takes it to the owner at once. The merge waits for the owner's ruling.
     - **A new cause of `--full`'s FAIL** (point 3): the same.
     - **A finding against this ruling's own work:**
       - A wrong record is fixed (G2), and the correction is recorded as not independently verified.
       - A defect in S1 is not fixed. S1's commits are reverted together with its test, `verify.sh --quick` runs on the result, and the revert is recorded as a re-open item.
     - **Row 3's fix found not to hold, or a flaky test outside the window** (1(d)): recorded, and the flake stays open.
     - **Anything else:** recorded as open in the draft, ADR-057 and `RESIDUAL-RISKS.md`, and not fixed.
   - **No second verification runs,** unless the owner rules one after a finding taken to them.

9. **Order and budget for run 13.**
   1. Point 5 (S1), on its own commits: the test red first, then the line.
   2. Point 6: the mutant runs for run 12's tests, then the records.
   3. Point 7 (the close).
   - **Budget** (estimates):
     - option (e)'s 4.5-9 fixer h (S1 1.5-3 h, the records 3-6 h), plus point 6's mutant runs (0.5-1 h) and point 7's runs (not estimated);
     - 13-33 points and 10-28 h of wall time for all of (e).
     - A step that runs past 1.5 times its upper end stops with a commit whose subject starts `PUT-BACK: close <point>: ` (item 8's point 2(e), extended).
   - **Item 6's re-read at each step stays,** so that the orchestrator can rule a `PUT-BACK`.
   - **If the weekly limit cuts the run,** the next run continues from HEAD in this order.
   - **Read narrowly:** this note, item 1c and its amendment, run 12's order, and the draft's cycle-23 section, with `end-sooner-options.md` §4 for S1. Open older text only where these cite it.

10. **After the verification: the orchestrator's steps.**
    - **The merge.** Once every finding taken to the owner is ruled, the orchestrator merges `wp/s3f` into `feature/asset-kit` with `--no-ff`. It then runs the post-convergence list (`end-sooner-options.md`, rows 19-27):
      - the tools-6.4 check and the phase-A gates;
      - TSan and `--perf` on an idle host;
      - P-13's verifier, on the p99;
      - the mutation re-check of the 11 survivors;
      - ADR-057, with the records of points 2, 4, 6 and 8;
      - the `s3-merged` tag;
      - removing the s3 worktrees and branches, only once they are pushed or archived (N25). `.build-orchestrator/` is never removed;
      - Stage 5;
      - the final archive snapshot, and the dossier's final version.
    - **Findings from these post-merge steps** follow point 8's rules. A broken MUST, a hang or a new cause of the FAIL goes to the owner. Anything else is recorded in ADR-057 and `RESIDUAL-RISKS.md`, and not fixed.
    - **Stage 5:**
      - its `--full` FAIL at benchmarks is the accepted end state (point 3), and its report says the owner set the /goal's Done aside;
      - nobody touches the owner's uncommitted `Package.swift`. The orchestrator asks the owner about it before Stage 5's `--full`.
