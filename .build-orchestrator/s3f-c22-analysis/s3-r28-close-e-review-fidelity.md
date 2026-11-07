# S3-R28 close ruling (option e): fidelity check

Reviewer: independent of the text's author (P4). 6 Nov 2026, about 16:50-17:30 CET. Read-only. Nothing was built, run or tested. I read the code at `9aa337c`. `git diff 9aa337c 9e9a500 -- Sources` is empty, and run 12's seven commits touch only tests.
- Paths: `close-e` is `s3-r28-close-e.md`, `options` is `end-sooner-options.md`, `N-file` is `s3-r28-orchestrator-rulings.md` (all in this folder), and `rulings` is `.build-orchestrator/s3-rulings-s3f.md`. ORCH is `docs/ORCHESTRATION.md` at `2ca4aa6` (16:48).

## Verdict: CORRECTED
Most points carry out (e), "Accept the FAIL" and the class answer faithfully. Three points change the scope of what the owner chose:
- the class answer's flaky-test clause is dropped;
- the class is drawn by N29's T20 text, not by the owner's words;
- f3c's two shapes are called owner-ruled misses, but no option showed them to the owner.

I spot-checked 37 facts and citations. 35 hold and 2 are off, and one measurement lacks its loads (list at the end).

## The Q3 and (e) tension, and point 8
- **The two texts.** Q3's description says "Broken MUSTs, hangs and flaky tests there still block", where "there" is the disk-full window. The (e) message says new findings are recorded, and "Anything that breaks a MUST or hangs would come to you first".
- **MUSTs and hangs: the texts agree, and point 8 is faithful.** It takes 1(b) and 1(c) to the owner before the merge (`close-e:105`).
- **Flaky tests in the window: the texts disagree, and point 8 is not faithful.**
  - Point 4 sends 1(b) to 1(f) inside the window to point 8 (`close-e:47`).
  - Point 8 names 1(d) only for row 3's fix (`:106`), so a new flake in the window falls to "Anything else: recorded" (`:107`).
  - One could read "still block" as "not exempt, reported as blocking, and recorded", and point 8 would then match. But Q3 groups flaky tests with MUSTs and hangs, which (e) sends to the owner first, so the consistent reading sends all three.
  - The owner's answer for the window is specific, so it should win over the general message. Blocking is also the safer default (`CLAUDE.md:43`). See must fix 1.

## Must fix
1. **Flaky tests in the window still block** (`close-e:47`, `:105-108`).
   - Replace point 4's "Not covered" with: "**Not covered, and still blocking** (the owner's answer): inside the window, a broken MUST or invariant, a hang or a job that nothing advances, and a flaky test (S3-R16 1(b) to 1(d)). Point 8 takes each one to the owner before the merge. 1(e) and 1(f) there, and every finding after the window, follow point 8 like any other finding."
   - Replace point 8's 1(b)/1(c) and 1(d) bullets, and its last line, with:
     "- **A broken MUST or invariant** (S3-R16 1(b)) or **a hang or a job that nothing advances** (1(c)), anywhere, or **a flaky test inside an ENOSPC window** (1(d); point 4): the orchestrator takes it to the owner at once. The merge waits for the owner's ruling.
     - **Row 3's fix found not to hold, or a flaky test outside the window** (1(d)): recorded, and the flake stays open.
     - **No second verification runs,** unless the owner rules one after a finding taken to them."
2. **The class is the owner's words, not T20 alone** (`close-e:42-45`).
   - The owner saw "caused by an event inside the disk-full window".
   - N29 says its T20 text "covers both causes and the late drain" (`N-file:299`). The late drain runs after the read returns (`EngineFailures.swift:569`, `:573-580`), so it falls outside item 1c's window (rulings:1592, :1662).
   - By code reading (UNCONFIRMED), a window difference can also come from `rerouteOnVisit`'s count arms (`EngineFollow.swift:1164`, `:1169`; correct #2's location), which T20's text does not name.
   - Replace "What is exempt" and "Its known members" with:
     "- **What is exempt** is the class in the owner's words: an answer that differs between the two visit orders, caused by an event inside an ENOSPC window (S3-R16 1(a)). The window is item 1c's: from a transfer's or a publication's ENOSPC end to the return of `spaceFailed`'s free-space read (item 1c amended, point 6(b)). N29's T20 test finds its members: [the quote, as now]. Where the two differ, the owner's words decide. A late-drain difference is exempt only when the event that causes it falls inside the window. Otherwise it follows point 8, and the orchestrator asks the owner in one line whether it joins the class.
     - **Its members:** correct #1 and #2, measured. The following are suspected by code reading only (UNCONFIRMED), and each is a member only if a run shows the difference: W-AWAY, W-DB, W-JOIN-HOP at a publication's end, W-JOIN-HOP in the late drain (by the rule above), item 1's former step-0 shapes, and `f1c-review.md` §6's shapes."
3. **f3c's two shapes are not owner-ruled misses** (`close-e:27-29`).
   - No option shows them. `options` names only R5's extra 15-60 ms for N25's case 1 (`options:92`). §8.2 appears only in the options review's "For the orchestrator" (`end-sooner-options-review.md:93`).
   - f3c's review asks for §8.2 to be measured, with a miss going to the owner, and for §8.1 to be recorded "not verified" (`f3c-open-shapes-review.md:96-102`).
   - Calling them "by the owner's ruling" repeats the overreach that N29 corrected (`N-file:296-297`).
   - Replace the bullet with:
     "- **Not in the options the owner saw, so not known misses by the owner's ruling:** f3c's two shapes, by estimate and UNCONFIRMED. Each is recorded as open, unmeasured and with no reviewed route, beside this list and under "Not verified" (point 6):
       - `readmit` scans the heap once per failed candidate (`EngineReadmission.swift:165-167`), and `removeJob` does so outside a walk (`EngineJobs.swift:517-520`): 27-55 ms a turn with 5,000-10,000 `.retry` entries (`f3c-open-shapes.md:163-164`; its review :31);
       - in production, each gate read builds `originID` three times, and HTTP parses its URL each time (`HTTPRemoteSource.swift:116-118`): 15-60 ms more per 10,000 gate reads, at an unmeasured 0.5-2 µs a build, which the benches' fake hides (`f3c-open-shapes.md:159-160`; review :102).
       - The orchestrator tells the owner in one line that they were left out of the options."

## Should fix
1. **Point 8's reason for running the verification is false** (`close-e:95`). Point 1 leaves 1(e) items open (`:16`), and item 8's point 5 runs the verifiers only once every blocking item is closed (rulings:1573). Replace the sentence with: "Point 1's items stay open by the owner's choice of (e), which includes this verification, so item 8's point 5 does not hold it back."
2. **Fixing S1 after the verification** (`close-e:104`) goes past "record ... rather than fix it", and no check would see the fix (G2). Replace "S1 is fixed if the fix is small (1.5 h or less, estimate). Otherwise it is reverted, and the revert is recorded." with: "S1 is reverted with its test, `verify.sh --quick` runs on the result, and the revert is recorded as a re-open item."
3. **Keep the verification short** (`close-e:95-101`). Item 6's heavy checks run every mutant (rulings:1520). The d4 kills alone are 14 runs, 2.3-4 h (estimate, `options:24`), against (e)'s 1.3-3 h for a verification (`options:82`). Add to "What they check": "The mutants run are those that run 12's kill tests and S1's test claim to kill. The same benchmarks run re-measures reqs #11's load-only cases. What the verification does not reach goes under "Not verified"."
4. **APM's figures lack their loads** (`close-e:25`). After "measured by probe", add: "in release with `-enable-testing`, in-actor, best of 3, at a 1-minute load of 9.85 to 8.65".
5. **Estimates for a route that is not taken** (`close-e:23`, `:26`).
   - Replace the N7 bullet with: "N7's five, by estimate (`s3-r28-final.md:125-129`): `keptUnderThreeGroups` 38-48 ms and `fourGroupJoins` 15-22 ms today. The other three are estimated only after route C, which is not taken, so they have no figure for today (`options:88`, R4)."
   - Item 4: add "unproven, not a miss: its estimate is at the edge, not above the limit".
6. **The six's latest figures** (`close-e:22`). Add the step-8 gate run and its re-run, which are reqs #1's figures: 17.82 to 62.56 ms at loads of 2.35 to 6.07 (`s3f.md:7728-7734` at `9aa337c`).
7. **Other causes of a `--full` FAIL** (`close-e:37-38`). Add: "If `--full` fails for any other cause, the close report names it to the owner as outside the accepted end state. A gated case that is red only at a load above 10 follows rulings:763. `commitTwoTokensTurns` (9.02 ms, reqs #11) is the case nearest to turning red."
8. **Run 12's commit range** (`close-e:19`). `29dfb12..9e9a500` leaves out `29dfb12`, which makes 6 commits. Write `247e85b..9e9a500`.
9. **The header** (`close-e:1-8`).
   - Replace `HH:MM` when the text is appended.
   - Change 16:33 to 16:32 (ORCH:447).
   - Change "WP-F's last ruling" to "meant to be WP-F's last ruling".
   - Quote the end of Q2's description, from "G3 stays intact" to "Every later --full stays red until they're fixed". Point 10 rests on it.
   - Quote the (e) message's "The verification checks what (d) leaves unchecked: the fix for the flaky test, run 12's commits, and the records". Point 8 rests on it.
10. **S1's specification** (`close-e:50-53`, `:67`).
    - Add: "the job and group counts are read at the first mark, before the walk removes jobs". After the walk, most shapes count 0 jobs (`BenchSyncCycle22Purge.swift:26`), and `options` §4 says the counts tie a long turn to a shape (`options:191`).
    - Replace "That is the interval the purge benches time" with "That is the interval the benches record as the purge's first turn (`BenchSyncCycle22Purge.swift:11-12`, `:30`). Their gate is the heartbeat (`:32`)".
    - Replace "Item 8's point 2(e) applies" with "Item 8's point 2(e) applies to S1 too": 2(e) names only items 2, 3, 3b and 6 (rulings:1557).
11. **Records the text leaves out** (`close-e:82-87`). Add:
    - item 5's `followedLane` record and the 12.x records (rulings:1490, :1492);
    - N25's record, brought up to f3c's review: case 2 at 12.9-23.3 ms and case 3 at about 21-34 ms, both estimates (`f3c-open-shapes-review.md:37`, `:59`; its must-add 5; `options:91`). The draft still calls f3c's figures "unreviewed" (`s3f.md:8159-8160` at `9e9a500`);
    - the swept-first backoff residual (its must-add 6).

    Also, the false 11.6 record is `s3f.md:6959` against `:8212` at `9aa337c`, and `:7010` against `:8564` at `9e9a500`. Name the commit.
12. **Point 7's "narrowed"** (`close-e:92`) does not say what it drops. Add: "Of item 9 (rulings:984-988), only S3-R25 item 10 for S1's lines and the margin list from the close's benchmarks log remain. Its inventory rows are in point 6."
13. **Point 9 gives no budget** (`close-e:110`). Add: "Budget, from the owner's (e) (estimates): 4.5-9 fixer h (S1 1.5-3 h, the records 3-6 h), 13-33 points, and 10-28 h of wall time. A step that runs past 1.5 times its upper end stops with a `PUT-BACK`."
14. **Point 1's "Not taken"** (`close-e:11-16`). Add step 0's remaining 'before' figures and run 12's order point 3 (rulings:1679-1681), so that a fixer who reads narrowly does not take them.

## For the orchestrator
- N31 is not yet in `N-file`, which ends at N30 (:307). `close-e:8` and ORCH:448 already cite it.
- Tell the owner in one line about f3c's two shapes (must fix 3). Ask in one line about the late drain if you want it inside the class (must fix 2).
- The owner's uncommitted `Package.swift` change (tools 6.0 to 6.3) is still in the main worktree (`git status`). Stage 5's `--full` (point 10) would run on that tree (G2). Ask the owner, and never touch the file.
- Point 10 leaves out row 25's N25 condition: remove the s3 worktrees and branches only once they are pushed or archived, and never remove `.build-orchestrator/` (`options:39`; N25).
- Budget: 76 % at 16:31, with 24 points left (ORCH:446, measured). (e) costs 13-33 points (estimate), so it fits only in its lower part. Read `get_usage` before run 13.
- Run 12 was stopped in the middle of a mutant run: `.build-s3f/c23/mut-e1.txt` and `mut/` were last written at 16:41. Some kill tests may lack a complete mutant log, and point 6's records must say which ones.

## Spot checks (37)
- **They hold:**
  - code: `EngineCommands.swift:968`, `:976`, `:1001`, `:1004` and `:1009`; `EngineJobs.swift:289-297`, `:327`, `:360-364`, `:517-520` and `:1217`; `EngineReadmission.swift:165-167`; `EngineFailures.swift:573-582`; `HTTPRemoteSource.swift:116-118`; `EngineManifest.swift:140`; `Time.swift:40`; `.info` (`EnvironmentSeams.swift:40`); `logTap` (`AssetEnvironment.swift:33`); the FAIL line (`Scripts/verify.sh:169`);
  - draft: `s3f.md:7611-7617`, `:6959` and `:8212` at `9aa337c`;
  - analyses: `s3-r28-final.md:125-129` and `:157`; `d3-many-holders.md:25-26`; f3c :160 and :164; `options` R4, §4 and rows 19-27; N29's T20 text, word for word;
  - run 12: `03c4e59` and `29dfb12`; seven commits, a clean worktree and the 16:41 stop (ORCH:453); `bench0` exists; 1.5 × 3 h = 4.5 h.
- **They are off:** the commit range (should fix 8) and 16:33 (should fix 9). APM's figures hold, but they lack their loads (should fix 4).
