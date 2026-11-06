### S3-R28, order for run 12 (appended 2026-11-06 16:15): the work that does not depend on the C2 ruling comes first

Run 11 ended at its working budget at 16:12, at `247e85b` (5 commits; `verify.sh --quick` PASS on HEAD). The owner's ruling on the remaining C2 work is still pending: items 3 and 3b, S3-R27's steps 5 and 6 (items 3 and 4: correct #5 and reqs #2), and their 'before' figures. So run 12 takes the work that every option needs first. The orchestrator records this as N30.

1. **First, S3-R27 step 7's work outside the purge code** (item 4, item 5's step 6):
   - the e1-PS, e1-P1 and e1-P2 kills, and e1-R1's rewritten kill table, on the code as it stands (item 1c freezes that code);
   - the d4 review's survivors after step 2 (r2b, b22 ×2, p7, r5, r8, vy, r2c), with item 5's default-tuning probe;
   - reqs #8's guard.
2. **Then the records that no C2 route changes** (S3-R27 step 8):
   - reqs #6's "Authorised edits outside WP-F";
   - item 7's d5 pin;
   - item 8's `releaseRerouteHolds` row;
   - item 9's inventory rows for code that items 3 and 3b do not touch.
3. **At the start of every step, re-read the end of this file.**
   - When the owner's C2 ruling is appended, follow it from the next step.
   - If it has not been appended when 1 and 2 are done, go on as item 1c's amended point 5.3 says: take the C2 'before' figures in `.build-s3f/c23/bench0`, write S3-R27 item 4's k=2 and k=4 cases, then go on from step 2.
   - The three unreached purge lines (`EngineCommands.swift:1001`, `:1004`, `:1009`; reqs #4) wait for the C2 ruling, because route C may change them.
4. **Read narrowly, to save context.** Read S3-R28 (from line 1278 of this file to its end) and the draft's cycle-23 section. Open earlier rulings, or earlier sections of the draft, only where S3-R28 or the status list cites them.
