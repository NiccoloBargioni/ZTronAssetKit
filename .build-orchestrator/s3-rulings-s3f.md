# Stage 3 orchestrator rulings — Stage 3 WP-F (sync engine) (close-out `s3f`)

Authoritative for this close-out (CLAUDE.md; PROMPT §4 Stage 3). The fixer records each ruling in `docs/adr-drafts/s3f.md` as "Orchestrator ruling (Stage 3)". Verifiers read this file too.

## General rulings (identical in every Stage 3 close-out)
- **S3-R1 Scope and order.** Fix this work package's BLOCKING items first (failing test committed on its own, then the fix; CLAUDE.md P3), then every REQUIRED item, then OPTIONAL items if the cycle has room. An ADR-RECORD item gets an entry in `docs/adr-drafts/s3f.md` (decision, evidence, reason) and no code. The findings file `/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-findings-s3f.json` holds, by id, the hunters' full findings with the independent confirmer's verdict, the surviving mutants, and the backlog items. An item not listed below is out of scope.
- **S3-R2 Probes.** The hunters' and confirmers' probes under `.build-orchestrator/s3-probes/<lens>/` and `.build-orchestrator/s3-probes/confirm-<lens>/`, and the mutant diffs under `.build-orchestrator/s3-mutants/<group>/`, are evidence you may copy and adapt (all under `/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/`, which is NOT inside your worktree; item texts below cite probes relative to its `s3-probes/` folder). A committed test follows SPEC 7.2: its display name starts with the requirement ID, `.timeLimit` on anything that awaits, `ManualTimeSource` only, no sleeps, and the iOS gating convention (ADR-051, `docs/adr-drafts/ios.md` item 2). Rename probe suites (`S3…Probe`) into the owning suites. Replays that encode a bug's old ordering are evidence only; do not commit them.
- **S3-R3 Mutation survivors.** For each surviving mutant assigned here, write the missing test, then re-apply the mutant's diff in a scratch copy and show the new test FAILS against it; paste that failing line into the draft. Verifiers re-check the same way.
- **S3-R4 Hang guards.** `.timeLimit` stays `.minutes(1)` by default (SPEC 7.2). A test whose measured duration under TSan on a moderately loaded host (load average at most about 30) exceeds half its limit may have its hang guard raised to `.minutes(3)`, or `.minutes(5)` for a model-based or exhaustive enumeration, following the precedents `EngineGateModelTests` and `stalledSubscriberIsBounded`; record each with the measured durations and load. Never cut a test's operations, seeds, crash points or assertions to make it faster (G3); making each step cheaper (incremental checks, less copying) is welcome. Long loops check `Task.isCancelled` so a timed-out test ends at once.
- **S3-R5 C2 at the reference scale.** A single actor turn over about 10 ms at 10,000 records is fixed by bounding the work per turn (owned follow-up turns, re-validation after each `await` with a `// REENTRANCY:` comment and a proposed ledger row) or by moving pure computation off the actor, never by hiding work from a measurement. Pin each with a C2 benchmark in this work package's benchmarks file (`Tests/ZTronAssetKitBenchmarks/`, the existing `c2Budget` convention of ADR-052 R4 and ADR-053; no literal P-n threshold) and, where a deterministic unit test can assert the bound structurally (turns, chunk sizes, operations per key), add that too. A benchmark miss on a loaded host whose only cause is load is not blocking (report load averages).
- **S3-R6 Shared files.** No public or package signature changes. No edit of `Package.swift`, `Scripts/`, `SPEC.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/TRACEABILITY.md`, `docs/ORCHESTRATION.md`, `README.md`, `docs/MIGRATION.md` or any `*ContractTests.swift`. Changes those documents need (ledger rows, §7.6 or §14 notes, §12 statuses) are PROPOSED in the draft; the orchestrator applies them at the Stage 3 merge. Contract files may change only where this file authorises it, bodies only.
- **S3-R7 Parallel close-outs.** Six close-outs run from tag `s3-base` in separate worktrees and merge afterwards in the order ah, b, c, d, f, g. Do not depend on another work package's Stage 3 change. Edit only this work package's files (ARCHITECTURE §1.2) plus the edits authorised below.
- **S3-R8 Strict bar (owner).** Verifiers keep the strict bar. A finding whose fix lies in ANOTHER work package's files is reported NON-blocking with its area prefixed `other-wp:<wp>:`; the orchestrator routes it. Pre-existing behaviour that a recorded ADR accepts is not a finding unless proven to violate a MUST in a way the record did not consider.
- **S3-R9 Records.** `docs/adr-drafts/s3f.md` is new: one entry per item below (id, disposition, tests added with display names, evidence), then "Authorised edits outside WP-F", "Proposed document changes" and "Not verified here". Your work package's Stage 2 record (`docs/adr-drafts/f.md`) is background; read it by section as needed.

## Items for this close-out

- **S3F-1 [BLOCKING] S3-CONC-04.** A satisfied FIRST conditions reading counts as an edge for work that failed offline while no reading existed (`EngineConditions.swift:97`, `EngineFailures.swift:84-90`; the hunter's option 1 or 2). Both probes become regression tests; propose the note beside PROBE-C9C-3's rule in ARCHITECTURE §7.6.
- **S3F-2 [BLOCKING] S3-STAB-03.** Apply S3-R4 to `EngineModelTests.randomOperations` (`:21`) and the near misses (`EngineLegacyMigrationTransferTests.swift:433`, `:453`, `:711`; `EngineRegressionCycle16Tests.swift:31`; `EngineGroupClaimTests.swift:387`): measure each under TSan (alone, and with a second TSan process running, as two verifiers do), make steps cheaper where possible, raise a guard only with measurements, and make the model loop check `Task.isCancelled` per operation.
- **S3F-3 [BLOCKING] S3-CONF-03.** Test a run over a record failed at the integrity cap (`EngineRuns.swift:471-473`, count 0): the run must not end `.complete` and must not write the sync stamp; the dropping mutant must fail it.
- **S3F-4 [BLOCKING] S3-PERF-01.** Engine shutdown holds the actor 17–22 ms at 10,000 (`EngineLifecycle.swift:470`, sorts at :493 and :580, `resumeEverything` :516-602), also on the mid-session rootVanished reopen path: bound it per turn (S3-R5; the hunter's three steps are a good start) and add a `BenchSync` C2 benchmark beside `handleReleaseTurns`.
- **S3F-5 [BLOCKING] S3-PERF-02.** Applying a manifest under a 10,000-member prefetch group holds the actor 17–19 ms (`followApplied`, `EngineRuns.swift:419`, about 10–12 ms with a 3.6 ms key sort): make the follow proportional to what the apply changed or chunk it; give the same treatment to `finishRun`'s (:823) and `releaseSystemReattachments`' (:489) full sorted walks; `BenchSync` C2 benchmark.
- **S3F-6 [REQUIRED] S3-CONC-03.** Event order for a lagging subscriber: run N's `syncFinished` precedes run N+1's `syncStarted` and `syncProgress` for every subscriber (`SubscriberQueue.publish` reuses an undelivered `.run` progress slot in place; `EngineEvents.swift:70-79` retires only `.transfer` slots). Both probes become tests.
- **S3F-7 [REQUIRED] S3-CONF-04.** (a) Test `interactiveConcurrencyAtCritical` (ADR-036; `EngineDispatch.swift:79`, count 0). (b) is the documented design: record only.
- **S3F-8 [REQUIRED] S3-CONF-02.** Test the Apple-tier catalog update check on an expensive network, not only under Low Data Mode (`EngineDispatch.swift:541`).
- **S3F-9 [REQUIRED] S3-CONF-05.** Test `ensureAvailable`'s mapping of an open auth breaker to `authRejected(.confirmed)` (`EngineCommands.swift:728`).
- **S3F-10 [REQUIRED] S3-CONF-08.** For each uncovered region the conformance hunter listed in Sync (and the Sync-owned ones among Storage/Kit, which are not yours: report those `other-wp:`), add a behaviour test through real APIs or a documented seam where reachable; record the rest as ARCHITECTURE §14 candidates.
- **S3F-11 [REQUIRED] M-N-09, M-N-12, M-N-14, M-N-16, M-N-20, M-N-39.** Tests that kill each surviving mutant (S3-R3), with the scenarios the mutation agent described: promotion of a queued job to prefetch and to the user lane (`EngineJobs.swift:187`), the backoff ceiling doubling per attempt, the breaker's ratio boundary (3 of 6 at 0.5 opens), `Retry-After` exactly at `maxRetryAfter`, and a later shorter 429 that must not shorten the origin throttle.
- **S3F-12 [REQUIRED] S3-B-064, S3-B-065, S3-B-081, S3-B-082.** The four proven backlog bugs, each failing test first: L4-R24(1) `reserveManifestProbe()` after `state.run = run` and before `spawn` (F-42), with an observer-side `invariantViolations()` assertion; L4-R24(4) a re-join that changes lane or comes from user work keeps its queue position as the lanes' rules say; L5-R16 a claim inherits the held lane's retry policy, so a claim-only job is not failed on its first failed attempt; L5-R22(4) `invariantViolations()` flags a large give-up's leftover claims only while its Release holds members or pending interests, plus the E2-shape test.
- **S3F-13 [REQUIRED] S3-B-063.** L4-R22: lazy re-admission with an ordered index (O(log n) per probe exit) so a chain of half-open probes is no longer quadratic in the parked jobs; pin it structurally (re-admission work per exit) and extend `BenchSync.swift:328` to 10,000 parked members under C2.
- **S3F-14 [REQUIRED] S3-B-068, S3-B-069, S3-B-070.** Write the §12 regression tests with the names ARCHITECTURE §12.3/§12.4 give: S1-01 (both), S1-07, S1-11, S1-12, S1-15's run form, S2-09, S2-10, S2-01's `ensureAvailable` form, S1-09's replaced-alarm and replaced-watcher halves, and an engine-side assertion of R-SYN-15's join-before-close order (mutants M5/M6 must fail it). A test that fails is a bug: commit it failing, then fix.
- **S3F-15 [REQUIRED] S3-B-077, S3-B-078.** Measure, as `BenchSync` C2 benchmarks at 10,000: the first turn of each re-admission event, `registerGroup`'s de-duplication and sort, retries falling due together in one `fireDue`, and the 10,000-id prune announcement. Any turn over 10 ms is fixed under S3-R5.
- **S3F-16 [REQUIRED] S3-B-084, S3-B-085.** Comment fixes: `releasesPerTurn`'s cost estimate (`EngineCommands.swift:363`, re-measure) and the REENTRANCY comment at `EngineDispatch.swift:743-744` (the lifecycle, epoch and attempt re-checks before `remote.transfer`).
- **S3F-17 [ADR-RECORD] S3-B-066, S3-B-067, S3-B-071, S3-B-072, S3-B-073, S3-B-074, S3-B-075, S3-B-076, S3-B-079, S3-B-080, S3-B-083, S3-B-086, S3-B-087.** Record the status of each (unproven or without a seam); write a test only where a real seam now reaches it.

## Orchestrator ruling added 2026-10-30 (answers the cycle-4 and cycle-5 request)

- **S3-R10 S1-15's run test hang guard.** `R-SYN-3: a 100,000-entry plan never materialises more than the pipeline plus the lookahead as jobs` (`EngineSync1LivenessTests.swift`, `runMaterialisesAPipelineAtATime`) may take `.timeLimit(.minutes(5))`. Its cost is the SPEC-mandated scale (S1-15's 100,000-entry catalog) decoded by WP-A's parser under TSan, not WP-F's own work: 101.8–130.1 s beside a second TSan process at load 10–32 (34–43 % of 5 minutes), 47.5–72.3 s alone. Keep every entry, operation and assertion (G3), keep the cancellation checks, and record the figures in the test's doc comment and in the draft. The parser's sanitizer cost is not a defect (a release build decodes the manifest in well under a second): record it in the draft as a note for Stage 5's residual risks; no WP-A change. Verifiers judge this guard by S3-R4's rule against 5 minutes: it is blocking only if the test exceeds half of 5 minutes at a load of about 30 or less, or if the raise came with any cut to the test.

## Orchestrator ruling added 2026-10-30 09:50 (answers the cycle-7 and cycle-8 hang-guard requests)

- **S3-R12 Hang-guard margins: how load is read, what is blocking, and the raises now.** Supersedes S3-R4's load reading for WP-F; S3-R4's steps and G3 stand.
  1. *Load reading.* The load of a TSan run (alone or paired) is the mean of the 1-minute load average sampled every 5 s or less, from 60 s after the later bundle's start to the earlier bundle's end (the steady state; the 1-minute average lags at a run's start, so per-test windows in the first minute are not read). Record the samples' mean, min and max with every figure.
  2. *Blocking.* A hang-guard margin is blocking only if (i) a test times out in a run whose rule-1 mean is 50 or less, or (ii) a test exceeds half its guard in a paired run (two TSan bundles at once) whose rule-1 mean is 30 or less. Every other margin is non-blocking and recorded with its figures.
  3. *Raises now* (cycle-8 verifier's pair1 and pair2 at 40ecd95, rule-1-like means 30.7 and 34.7: at the bar, so the long guards take one step to end the oscillation): `stalledSubscriberIsBounded` (`EngineEventsTests.swift`) `.minutes(4)` → `.minutes(6)` (133.0–133.8 s, 55.7 %); the R-SYN-14 migration-loop wait (`EngineLegacyMigrationTransferTests.swift:751`) `.minutes(3)` → `.minutes(5)` (89.0–90.2 s); the R-SYN-6 owed re-queue (`EngineRegressionCycle16Tests.swift:33`) `.minutes(3)` → `.minutes(5)` (88.9–91.0 s). S1-15's run test stays `.minutes(5)` (146.3–147.1 s, 49 %; S3-R10). Nothing is cut (G3); each raise records its figures in the test's doc comment and in the draft.
  4. *Not raised:* the 29 one-minute tests at 50.3–55.0 % in pair2 (`.build-orchestrator/s3f-probes-c8/reqs/logs/pair2-1min-overhalf.txt`). All ran in the bundles' first 35 s, when every suite starts at once under two TSan processes, and none came near its guard otherwise. Record the list and figures in the draft as non-blocking. They are raised under S3-R4 only on evidence that meets 2(ii).

## Orchestrator ruling added 2026-10-30 12:50 (answers cycle 8's sweep/follow class; owner go-ahead "Launch on D3")

- **S3-R11 The follow barrier: implement design D3 "root" with the judges' amendments.** Cycles 5–8 each found new members of one defect class: a decision taken while a follow is owed differs from the decision taken when the follow visits first. A design panel (`wf_8bbbb235-852`) prototyped three designs at `40ecd95` (this branch's head), and two independent judges scored them. Both chose D3: it is the only design whose answers match visit-first in all 29 cross-design probe tests in both orders. D1 fails TICKET, READ-PROMOTE and READ-ORDER; D2 fails 12. Materials, under `/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-design/`:
  - `d-root/design.diff`: the D3 prototype, sources plus its proposed `EngineFollowTests.swift` edits. It applies cleanly to `40ecd95` (`git apply`). Treat it as a reviewed starting point, not as finished code: it was built in debug only at moderate load.
  - `d-root/probes/`: `DesignD3Probes.swift`, `VerifyD3DrainC2.swift`, the cycle-7 and cycle-8 verifier probes, and `VerifyC8C2Probe.swift`. Logs are in `d-root/logs/`.
  - `d-defer/probes/VerifyDDeferProbes.swift`, `d-budget/probes/DesignBudgetProbes.swift`, `j-break/probes/JBreakProbes.swift`, and `j-c2live/probes/`: `VerifyJC2Probe.swift`, `VerifyJC2Design-root.swift`, `VerifyJLiveness.swift`, `VerifyJPileup.swift`.
  - `j-break/d3-amendment-A1-invariant.diff`: the invariant fix of item 2(b), prototyped and verified (415/415).
  1. *The rule (state it as an invariant in `invariantViolations()` and in the docs).* While a follow is owed (the barrier), nothing is admitted and no space verdict is given. That means none of these:
     - a start or a space park by the pump;
     - a space sweep's judgement;
     - a join's or a promotion's re-check or fail-fast of a space-parked job;
     - an ENOSPC verdict.

     Space sweeps drive the follow: they run the follow's own `continueFollow` (`advanceFollowForSpaceSweep`) and judge only in a later turn, once nothing is owed. Do not add D2's second cursor (`followBroughtForward`). Requests, re-queues and the other deferred events wait in arrival order. They are replayed after the follow's last turn and its pump, at most 512 per turn, and the run settles only after them. With the barrier in place, every decision equals the visit-first decision, and 1b771e8's pre-phase (`followSweptHolders`, `SweptFollow`, the second collect-and-sort) goes.
  2. *Amendments.* Each one that fixes a defect gets a failing test first (CLAUDE.md P3).
     - (a) *Front and age.* The event is `.enqueue(TransferID, front: Bool)`. The drain replays `enqueue(transfer, front: front)` and keeps `queuedAt`, so bulk aging is kept. `reinstate` (`EngineJobs.swift`, about :157 and :451) goes through the event list while the barrier holds. Test: a transfer whose pause completes during an owed follow resumes at its queue's front, as it does when the follow visits first.
     - (b) *The invariant "N queued jobs wait in no queue"* (`EngineCommands.swift` about :1844-1849). Exempt exactly the transfers with a pending `.enqueue`: keep a set, and assert it equals the events' transfers. Start from `j-break/d3-amendment-A1-invariant.diff`. Also add the rule that events wait only while a follow is owed, a drain is scheduled, or a drain is in progress. Without this, the probes PROBE-D-PUMP-FREED (:207) and PROBE-D2-GATE-ABANDON (:244) trip the invariant mid-follow.
     - (c) *Failure order.* PROBE-J-FAIL-REROUTE and PROBE-J-FAIL-TICKET in `JBreakProbes.swift` fail in all three designs.
       - While the barrier holds, `followBeforeActing` never visits a job out of the follow's order.
       - A failure of a job that still holds a moved id (`resolveAll` with `.failed`, `retryLater` or `countFailedAttempt`, `spaceFailed`) becomes an event `.attemptFailed(transfer, epoch, error, answer)`.
       - The job leaves flight as `.failed(.nextRun)`, with its active attempt cleared and no answer given.
       - The follow's own visit moves its moved ids in the follow's order.
       - The drain replays the verdict for the ids left, epoch-checked, and skips it when the job was superseded.
       - Do not simply drop `inFollowVisit` from `followBeforeActing`'s visit: that passes these probes only when the failing job comes later in `followOrder`, and it breaks the mirror case.
     - (d) *A drain over several turns.* The pump is barred on `followBarrier`, not only on `followOwed`, and the drain's last batch pumps.
     - (e) *SECOND-APPLY-REORDER* (shared by every design, not yet probed). On a second apply inside an owed follow, `followApplied` keeps `followOrder[followNext...]` in its order and appends the newly unfollowed jobs, sorted. The failing-first probe needs more than 256 owed visits and two applies.
     - (f) *C2 of the follow's end.* Add one `BenchSync` C2 benchmark (`c2Budget`) for the follow's last turn plus the drain's first batch at 10,000 members. That combined worst case is unmeasured.
  3. *Ruling R1: where the class ends (option a).* Real-world ledger inputs apply in the turn they arrive, as L4-R7 says, and D3's `.read` deferral is dropped. These inputs are bytes freed by a transfer that ended (completed, failed or cancelled) and free-space reads. A measurement or a freed byte is real information, not a visit-order artifact.
     - So PROBE-D2-READ-ORDER, PROBE-D3-READ-PROMOTE and PROBE-J-UNRELATED-FREE are outside the class. Their outcomes may depend on when the input arrives. Commit them as tests of the documented on-arrival behaviour, or record them in the draft.
     - Keep the RE-S06 notes (`EngineRuns.swift` about :175, `EngineCommands.swift` about :620), the `readFreeSpace` doc and the f-4 REENTRANCY notes true.
     - **Verifiers:** a difference between visit-first and event-first that is caused only by such an input is non-blocking. Every other decision that differs is blocking.
  4. *Ruling R2: the R-SYN-2 assertion.* At `EngineFollowTests.swift` about :456, `between.steady == .downloading` becomes `.queued`, and the slot goes to the job after the follow. This is the intended consequence of the barrier.
     - The admission wait during a multi-turn follow is accepted: 131–143 ms at 10,000 members in macOS release (D3 and judge figures). Record it in the draft with figures as a Stage 5 residual risk; it was not measured on a device.
     - Propose the ARCHITECTURE §7.10 paragraph "Follow barrier (F-28)" and the F-28 text "decided on the followed state" in the draft (S3-R6).
  5. *Ruling R3: the replaced assertions (G3).* The one-to-one assertion replacements in `EngineFollowTests.swift` that D3 makes are authorised, and so is R2's. Each gets a one-to-one entry in the draft: the old assertion, the new one, and the reason. No assertion is deleted, and no test loses an operation or a scenario.
  6. *Tests committed failing-first at `40ecd95`.* Put them in their owning suites with R-SYN-11 (or R-SYN-2 / R-SYN-3) display names, both orders through `LaneDropVisit.allCases`, and hang guards per S3-R4 and S3-R12. The set:
     - the cycle-8 issues: DROPPED, DROPPED-KEEP, DROPPED-LANE, C8R-INFLIGHT-PROMOTE;
     - D3's: PUMP-ABANDON, PUMP-PROMOTE, PUMP-STALLED-USER, JOIN-ABANDON, TICKET;
     - D1's: PUMP-PROMOTE, PUMP-FREED, JOIN-FREED, ENOSPC, REFOLLOW, SHUTDOWN;
     - D2's: FOLLOW-ORDER, INFLIGHT-ABANDON, JOIN-ABANDON, GATE-ABANDON, PUMP-PROMOTE;
     - the judges': FAIL-REROUTE, FAIL-TICKET, HELD-RETICKET;
     - new ones for items 2(a) and 2(e).

     The probes that already pass at `40ecd95` (the C7 ones, C8 RANK-*) are committed as regression tests. A probe written for another design's mechanics is adapted in its waits only, never in its assertions. Merge duplicates, keeping one test per distinct scenario.
  7. *C2.* Cycle 8's regression must be gone: VERIFY-C8-C2-MIXED measured 10.0–12.0 ms best at 10,000 with 1 member in 20 changed, against 6.7 ms at `7426fee`; D3 measured 5.7–6.0 ms. Commit VERIFY-C8-C2-MIXED and D3's drain probe as `BenchSync` C2 benchmarks beside `reclaimDuringFollowTurns`, plus item 2(f). S3-R5 applies.
  8. *Hang guards.* Cycle 8's issue 4 is answered by S3-R12; nothing more is raised.

- **S3-R13 Tools 6.4 with 0 warnings (owner requirement, 2026-10-30).** The package must build and test with 0 warnings when `Package.swift`'s first line is `// swift-tools-version: 6.4`. The committed manifest stays at 6.0, and the iOS 15.0 floor stays.
  - **Nobody edits `Package.swift` in the worktree.**
  - **Fixer:** check your change in an export, not in the worktree:
    - `git archive HEAD | tar -x -C <your scratch>/t64`;
    - set line 1 there to 6.4;
    - `swift build --build-tests --scratch-path <your scratch>/t64-build -Xswiftc -warnings-as-errors`;
    - `grep -c 'warning:'` on the log.
  - **The reqs verifier** runs the same check on the branch head, plus `swift build -c release`. Any `warning:` line, in sources, tests or the manifest, is blocking.

## Orchestrator ruling added 2026-10-30 17:55 (answers the cycle-10 fixer's open list; written while the cycle-10 verifiers run)

- **S3-R14 Close the follow-barrier class by inventory, not one probe at a time.** Cycles 9 and 10 each fixed every listed member, and each fixer then found more (cycle 10's draft, "Open, for the orchestrator"). To converge by cycle 12, cycle 11 does the following, in addition to the cycle-10 verifiers' issues (merge duplicates).
  1. *Inventory first.* Before fixing, list in the draft (a table under "Cycle 11") every site in `Sources/ZTronAssetSync/Engine/` that takes a decision: admits, starts, parks, answers a user, fails fast, or reads a job's lane, rank or queue place to decide one. For each, state whether it can run while the barrier holds (`followOwed`, a scheduled drain, or a drain in progress). If it can, state how it waits (which event, replayed where) or why it is outside the class under S3-R11 item 3 (R1: only bytes freed by an ended transfer and free-space reads). Verifiers check the table against the code; a site missing from it, or a wrong row, is blocking.
  2. *In the class (blocking; failing test first, both orders through `LaneDropVisit.allCases`, then the fix):* every item the cycle-10 fixer recorded:
     - `answerThrottledUsers` answering throttle-parked users during the barrier;
     - `pauseIfRefused` and `paused`'s park reading the pre-visit lane;
     - `readmit`'s deferred places and the no-Retry-After throttle delay using pre-visit ranks and lanes;
     - `.edge` events placed before the same edge's re-admissions;
     - a visit re-lane of a job whose queue place waits;
     - amendment (e) with an incomplete old pass (unfollowed-but-not-owed jobs placed ahead of the old pass's remaining finds): hold them until the old scans end, as the cycle-10 draft proposes.
     The network edge and the origin's throttle signal are real-world inputs that still apply on arrival (cycle 10's e195e2d), but the decisions taken from them about a job whose verdict waits are in the class.
  3. *A withdrawal that overtakes a deferred answer is in the class.* A withdrawal is a request, not a real-world ledger input, so by S3-R11 item 1 the engine's handling of it waits in arrival order behind the answer it would have followed under visit-first. R-SYN-4 and R-SYN-10 still hold: if the public layer answers a cancelled caller at once, keep that. What waits is only the engine's interest removal and any transfer cancellation it causes. Assert both, and assert that no transfer is left running for nobody (R-CAR-4) once the drain ends.
  4. *Unreached branches (G4).* The `.relane` drain replay and `replayJoin`'s re-route branch have 0 hits in the barrier suite. Each gets a test whose assertions fail when that branch is removed (show the mutant failing), through a test seam if needed, like a206500's `holdReleaseFollowUps()`.
  5. *Surviving mutants* `noDispatchOwedFlag` and `noFlagPump` (§14 (a)/(c)): kill each with a test, or record in the draft, with a probe's output, why it is equivalent (no observable difference). Verifiers re-run the mutant.
  6. Hang guards, C2, S3-R12 and S3-R13 apply unchanged. New tests go in the serialized `EngineFollowBarrierTests` / `EngineFollowBarrierVerdictTests` suites.

## Orchestrator ruling added 2026-10-30 23:30 (answers the cycle-11 fixer's ruling requests and the cycle-11 correctness verifier; written while the cycle-11 requirements verifier runs)

- **S3-R15 One view of the world per decision instant.** Cycle 11 closed the barrier's own decisions; what remains is one root cause: a deferred decision, or a follow visit, reads the non-ledger real-world inputs (origin throttles and their ends, conditions, the network edge) as the drain leaves them instead of as they stood at the decision's visit-first instant. Fix the root, not each probe.
  1. *The rule.* While the barrier holds, every replayed decision reads each non-ledger real-world input as it stood at that event's arrival instant, and a follow's visit reads it as it stood at the apply instant (the visit-first instant). Make it one mechanism for every replay and visit, not per input or per event kind. For example, while the barrier holds, record each change of a non-ledger input (throttle set, extend, end or clear; conditions; edge) with its instant, and have the gate, throttle and conditions reads consult that history while `replayInstant` (or the visit's instant) is set. `.conditions`/`.readmit`'s `withConditions` folds into it. State it as an invariant: after the drain's last batch, the history is empty and the live state is what arrival-order application gives. R1's ledger inputs (bytes freed by an ended transfer, free-space reads) are unchanged: they apply on arrival and everyone reads them live.
  2. *A 429 throttles its origin on arrival, as visit-first does,* with or without Retry-After. Readers that are not replays (the manifest fetch of unknown-id waiters, `ensureAvailable`, a pending run's start) then see it at once. When the backoff depends on the job's lane, use the lane the owed visits will leave it: compute it from the interests whose ids the copy still maps to this transfer, which is the visit's own rule, without performing the visit. `replayThrottle` only re-parks and answers. If the lane cannot be derived without the visit, show it with a probe and record it; do not guess.
  3. *In the class (blocking; failing test first in both orders, then the fix):*
     - R-A, proven by PROBE-C11-COMMIT-PLACE. The publication or commit outcome of a job that holds a moved id waits as an event, as the failure verdicts do (S3-R11 2(c)), so its re-routed joins take the follow's place.
     - R-C, the sweep's place among drained events.
     - R-D, visits reading post-arrival inputs (covered by item 1).
     - PROBE-C9-THROTTLE. R2 accepts admission latency only. A different answer (16 bytes served against `serverUnavailable(60)`) is in the class.
     - The verifier's JOIN-THROTTLE-END, JOIN-THROTTLE-EXT and MANIFEST-THROTTLE, and the cycle-10 THROTTLE-LANE read right after the 429.
  4. *R-B.* Circuit-breaker decisions (opening, half-open probes, refusals) are in the class. Pure metric counters that no decision reads are outside it; list them in the inventory with that reason.
  5. *R-E, the store-work stall* (`storeWorkRuns=1`, `commitsInFlight=true`, a 60 s time-out). It is treated as a liveness defect, independent of the barrier class, until shown otherwise.
     - Reproduce it and date it: run it at `5203ccb` and at `40ecd95`, and also at `s3-base` if it is there too.
     - If its root is in WP-F's files: add a failing test, then the fix.
     - If its root is in another work package's files: record it as `other-wp:<x>` with the probe, the reproduction count and the stuck state, and do not touch those files.
     - `noDispatchOwedFlag` is observable, so it is not equivalent. Its killing test is committed once the stall no longer blocks it. Do not shorten or weaken the scenario.
  6. *Every replay branch is reached (G4, S3-R14 item 4's standard).* For each deferral that 6cc4d92 and this cycle add, either:
     - add a test in the serialized barrier suites, in both orders, that asserts the visit-first outcome, and show that a mutant dropping the branch fails 2/2; or
     - remove the branch, if it is unreachable, with the reason in the draft.
     A branch that is counted as Fixed but reached by no test is blocking.
  7. *Inventory.* Correct I12, I14, I26, I35 and the R-A rows. Every row cites its test or probe. Keep the table current with every change in this cycle.

## Orchestrator ruling added 2026-10-31 (owner decision, 31 Oct: "Narrow the bar")

- **S3-R16 The follow-barrier class: the bar is observable correctness.** Eight cycles (5–12) did not converge on exact visit-first equivalence. Each fix added machinery in which new differences were found, and cycle 12's fix broke R-SYN-5 (R-I). The owner narrowed the bar.
  - **What this supersedes:**
    - S3-R11 item 3's sentence "Every other decision that differs is blocking";
    - the "in the class (blocking)" lists of S3-R14 items 2–3 and S3-R15 item 3, where they conflict with this ruling.
  - **What stands:** everything else in S3-R11 to S3-R15, R1 included. G3 holds: no test that passes today loses an operation, a scenario or an assertion, except as item 4 allows.
  1. *Blocking, in either `LaneDropVisit` order:*
     - (a) **A different answer.** A caller (a user request, `ensureAvailable`, a system or run interest) receives a different outcome from visit-first. That means success against an error, different content or bytes served, or a different error case. Values inside the same case (Retry-After seconds, `required`/`available` figures) do not count. R1's on-arrival inputs are excluded, as before.
     - (b) **A broken SPEC MUST, or a broken invariant (`invariantViolations()`, `followBarrierViolations()`), in either order.** Named cases:
       - R-SYN-5: no request goes to an origin whose throttle or open breaker is live. A 429, with or without Retry-After, throttles its origin on arrival, as visit-first does. The `.undecided` outcome that leaves the origin unthrottled is blocking. The backoff's length is not.
       - R-SYN-11 and space safety: the ledger never counts fewer bytes than are staged, verifying or publishing, and nothing is admitted against bytes not yet freed.
       - R-SYN-4 and R-CAR-4.
     - (c) **Liveness:** a hang, or a job left in a state that nothing advances.
     - (d) **Flakiness:** any test that fails in any run. S3-R12 reads the load. This covers this cycle's own new tests.
     - (e) **G4 for code that stays:** every replay or deferral branch is either reached by a test that kills its drop-mutant 2/2, or removed with the reason in the draft.
     - (f) **Gates:** C2 (S3-R5), the hang guards (S3-R12), S3-R13 (0 warnings at tools 6.4), and every `verify.sh` gate.
  2. *Non-blocking (recorded as a residual risk):* a difference from visit-first only in:
     - start or dispatch order, queue place or ticket;
     - when an answer arrives within the barrier and its drain;
     - backoff or Retry-After lengths, including which lane's backoff policy applies;

     while item 1 holds. The fixer records each one in the draft under "Residual risks (S3-R16)", with its probe and figures, for Stage 5's `docs/RESIDUAL-RISKS.md`. Verifiers report such differences as non-blocking.
  3. *Simplify where the narrowed bar allows.* Machinery that exists only to make order, place or timing equal may be removed, especially where it breaks item 1. One example is place stamps that let the barrier-end pump admit on a past view: R-I. Admission and requests always read the live throttle, breaker and slots. Prefer removal to new branches. Each removal names the branches and tests it affects, and the draft records it.
  4. *Tests (G3).* A committed barrier test whose assertion is only about order, place or timing, and which a removal under item 3 breaks, may be changed one to one, to assert the narrowed property instead. The narrowed property is: the answers equal visit-first's, the MUSTs and invariants hold, and the job ends where visit-first's ends. For each change, record in the draft the old assertion, the new one and the reason, as R3 did. No test is deleted, and no scenario or operation is lost. Answer and MUST assertions are never changed.
  5. *Cycle 12's findings under this bar* (`s3f-c12-issues.json`):
     - **Blocking:**
       - the hang of `barrierRetriesBehindTheOwedVisitsPlaces` (fix the setup race; gate the first conditions reading; do not weaken the test);
       - R-I, PROBE-C12-PLACE-SLOT (1(b));
       - PROBE-C12-UNDECIDED-LANE (1(b): the origin left unthrottled after a 429);
       - every surviving mutant and 0-hit branch (1(e): a test, or removal under item 3);
       - inventory rows that are wrong about an answer, a MUST or an invariant.
     - **Probe first; blocking only if item 1 is broken:**
       - the follow visit that removes a verifying or committing job while the store publishes (space safety, 1(b));
       - the R-A integrity-failure remainder (1(a): do the answers differ?);
       - R-F and R-G.
     - **Non-blocking, recorded per item 2:**
       - PROBE-C12R-FOLLOWED-LANE's backoff length;
       - R-C, the sweep's place, unless a probe shows a different answer;
       - inventory rows that are uncited but not wrong.

## Orchestrator ruling added 2026-10-31 12:45 (answers the cycle-13 fixer's put-back; written while the cycle-13 verifiers run)

- **S3-R17 When S3-R16 1(a) and 1(b) conflict, the MUST wins; live origin gates join R1.** The cycle-13 fixer reported a conflict inside S3-R16.
  - **The conflict.** PROBE-C9-THROTTLE (`barrierAdmitsTheFollowsNewContentAsAtTheApply`) and R-B (`barrierAdmitsARequestOnTheBreakerAtItsArrival`) can only give the visit-first answer by admitting on a past view, that is, by sending a request to an origin whose throttle or open breaker is live. That breaks R-SYN-5, which is 1(b). The two cannot both hold.
  1. *Rule.* A SPEC MUST is never broken to equal visit-first. Where they conflict, the engine decides on the live state and gives the correct SPEC answer for that state. Examples: `serverUnavailable(retryAfter:)` for a live throttle; a park and retry where the SPEC says so. The difference from visit-first is non-blocking and is recorded as a residual risk (S3-R16 item 2), with its probe.
  2. *R1 widened to the live origin gates.* R1's real-world inputs now also include the origin's throttle and its end, the circuit breaker's state, and network reachability or conditions, as the engine sees them when it decides. An answer difference caused only by such an input changing during the barrier is non-blocking, in either direction: an error at visit-first against a success behind the barrier, or the reverse.
     - This covers the suspected offline case: a join that waits while the network is offline, then succeeds at the barrier-end pump. Record it as a residual risk. No probe is needed.
     - The conditions are:
       - the answer is the correct SPEC answer for the live state at the decision;
       - every MUST and invariant holds;
       - the replays that stay keep their arrival-instant reads where they exist, unless removing them is a simplification under S3-R16 item 3 (record it).
  3. *G3.* The cycle-13 fixer's one-to-one changes of the two sweep-first answer assertions to the live gate's answer are authorised, as an exception to S3-R16 item 4. The visit-first assertions in both tests stay unchanged. The draft records the old assertion, the new one and this ruling. No other answer assertion may change under this exception.
  4. *Verifiers.* Do not report those two changes, or an answer difference covered by item 2, as blocking. Do report a broken MUST, a wrong SPEC answer for the live state, or an answer difference with any other cause.

## Orchestrator ruling added 2026-10-31 16:30 (cycle 14's verification and the cycle-14 fixer's put-backs; written while the cycle-15 fixer runs)

- **S3-R18 Place stamps go; a passed publication re-routes its moved ids at once.** Cycle 14 fixed every cycle-13 finding. Its verifiers found 5 blocking items in three groups: the place stamp's slot view (PROBE-C14C-STAMP-AHEAD), the passed-publication mark (PROBE-C14C-MARK-TWO-APPLIES, PROBE-C14C-PASSED-LANE, PROBE-C14R-PASSED-LANE, PROBE-C14R-PASSED-FAIL), and G4 for followedLane's new branches.
  1. *Remove place stamps (S3-R16 item 3, S3-R17 item 2).*
     - **Why.** STAMP-AHEAD shows the stamp is still a past view: it counts a slot free that a place ahead, started by a visit-first pump, would have taken. Counting places ahead adds the kind of machinery the narrowed bar exists to avoid.
     - **Rule.** The barrier-end pump admits every place on the live throttle, breaker and slots, and on nothing else.
     - **What goes.** Remove the stamps' place admission: the stamp's throttle refusal, `freeSlots`, and any branch, flag or invariant that exists only for them. The draft names each removal and the branches and tests it affects.
     - **Answers.** Any answer difference this causes is caused only by a live origin gate changing during the barrier. Under S3-R17 item 2 it is non-blocking and recorded as a residual risk.
     - **G3, an exception like S3-R17 item 3.** Some sweep-first answer assertions expect a stamp's past view; the first is in `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` (EngineFollowBarrierWorldTests.swift). Each may change one to one to the live gate's correct SPEC answer, provided the difference is caused only by a live origin gate changing during the barrier.
       - The scenario, its operations and every visit-first assertion stay unchanged.
       - The draft lists each change: test, old assertion, new assertion, this ruling.
       - Order-only assertions change under S3-R16 item 4. No other answer assertion changes.
  2. *A passed publication re-routes at once (S3-R16 1(a) and item 3).* The passed-publication answer differences are blocking; RR-1's remainder is not a residual risk.
     - **Preferred fix (the requirements verifier's simplification).** The case is `follow` passing a verifying or committing job whose publication began at or after this visit's apply. There, `follow` re-routes the interests of the moved ids to their new content at once, as `visit` does for a downloading job. It leaves the job's bytes, ledger entry and publication untouched.
     - **What goes.** Remove what only the deferred move needed: the `publishedAfterApply` mark, `followPassedPublication`, the parts of `followedForVerdict` that serve it, and followedLane's skip of publishing jobs. Their 0-hit branches go with them, which settles the G4 finding for those lines.
     - **Fallback.** Suppose the fixer shows, with a probe, that the re-route breaks a MUST (R-SYN-11 space safety, R-SYN-4) or an invariant. Then it records why in the draft and fixes the mark instead: per-pass id lists, as the correctness verifier proposed. Either way, the four cases the verifiers named are tests in both orders: the 429 and the 404, each behind the barrier and after the drain, plus the two-applies case. Whatever stays in followedLane is killed or removed (1(e)).
  3. *The cycle-14 fixer's put-backs.*
     - **Finding 11, the nested-drain re-entrancy change:** accepted as non-blocking; record it as a residual risk with the reason.
     - **`failureMoveBehindBarrier`:** moot if item 2 removes the mover. If the branch stays, its mutant is killed or the branch removed; "order only" is no reason to keep an unkilled branch (1(e)).
     - **RR-2 and RR-4 "Not probed":** not blocking. Probe them if the cycle has room, otherwise leave them marked.
     - **Routing P-5, P-13 and P-9 to their benchmark owners:** accepted.
  4. *Verifiers.* Judge by items 1–3. Do report:
     - a request to a gated origin;
     - a wrong SPEC answer for the live state;
     - a liveness gap;
     - an answer difference with any cause other than a live origin gate changing during the barrier.

## Orchestrator amendment added 2026-10-31 16:42 (to S3-R18; written before run 5's cycle-15 fixer starts)

- **S3-R18a.** The message of 16:31 started a second copy of the cycle-15 fixer instead of reaching the running one. The run was stopped at 16:41, and cycle 15 starts again under S3-R18 in run 5.
  1. *Two applies.* Item 2's re-route must also be right when a later apply lands while the earlier apply's follow still owes the publishing job's visit: re-route only the ids that were moved as of the apply the publication began after. Ids a later apply moved while the job was already publishing are passed, as in visit-first. One way to do this is to record the ids at publication start; it is in `.build-orchestrator/s3f-c15-handback-analysis.md`, which is unverified analysis to check, not a ruling. The fixer adds this case as a test in both orders, next to MARK-TWO-APPLIES.
  2. *Inputs.*
     - `wip/s3f-c15a` (`5a87864`) holds the stopped fixer's unfinished tests; reuse what fits. Its SlotTests fix-by-counting is ruled out by item 1, but its scenario is the STAMP-AHEAD test to add.
     - The findings are `.build-orchestrator/s3f-c14-issues.json`; the cycle-14 verifiers' probes are under `.build-orchestrator/s3f-probes-c14/`.

## Orchestrator ruling added 2026-10-31 18:36 (the cycle-15 fixer's put-backs; written while the cycle-15 verifiers run, before any cycle-16 fixer)

- **S3-R19 Cycle 15's put-backs.**
  1. *A verdict that waits across a later apply* and *the publication failure's await window* (draft, cycle 15, "Put to the orchestrator").
     - **Probe first.** Each is blocking only if a probe in both `LaneDropVisit` orders shows S3-R16 item 1 broken: a different answer, a broken MUST or invariant, or liveness.
     - **If the probe shows it, prefer the smallest fix.** For the first item, a verdict that arrived before a visit's apply leaves the job to the verdict, so that visit passes it. This is the comparison the fixer named, and it is allowed: it replaces the per-verdict `published` flag rather than adding a parallel mechanism.
     - **If no probe shows it,** record it as a residual risk with the probe and its result.
     - A cycle-15 verifier that has already probed either one decides it by this item.
  2. *`laneJobsWalkAlways`.* A mutant that changes only cost, not any decision, answer or state, is equivalent for G4 (S3-R16 1(e)). No drain-turn seam is required.
     - The draft records the equivalence argument: the walk's result when the guard is false.
     - The guard's cost is covered by C2 (S3-R5). If the C2 margin for `followedLane` is not measured anywhere, record it as unmeasured in the draft; it is not blocking.
  3. *`spaceFailureEpochDropped`.* A defensive check that no path reaches is not left unkilled (1(e)). Do one of two things:
     - remove it, with the reason in the draft;
     - turn the condition it guards into an `invariantViolations()` clause that a test exercises.
     
     If the check predates Stage 3 and lies outside the follow-barrier class, the third option is to record it as pre-existing and out of class; it is not blocking.
  4. *RR-2, RR-4 and RR-10 unprobed:* not blocking.

## Orchestrator ruling added 2026-11-01 02:34 (the cycle-17 fixer's put-back on `bringInbound`'s C2 cost; written while the cycle-17 fixer runs, before its verifiers start)

**S3-R20.**
1. `bringInbound` makes all its moves in one turn, the attempt's end turn. The fixer's scratch release measurement was about 400 ms with 10,000 ids converging on one content. That breaks C2 (CLAUDE.md C2; the budgets of S3-R5).
   - C2 is a standing order. The orchestrator cannot waive it; only the owner can, explicitly.
   - Until the owner does, the breach is blocking (S3-R16 item 1: a broken MUST, and the gates).
2. Verifiers: measure the breach with a BenchSync release case.
   - The case: 10,000 ids, held by other jobs, that the copy maps to one content whose attempt ends while the follow is owed.
   - Report best of 3 with the load, and judge it by C2 and S3-R5. A scratch figure does not settle it either way.
3. A fix must keep every turn within C2 and must not change an answer (S3-R16 item 1).
   - For example: continue the moves over bounded turns, as the owed follow's visits are, while the job's end and every later event wait, as events already wait while a follow is owed.
   - The order, place and timing differences the fix makes are not blocking (S3-R16 item 2). Its walk and its moves each get a BenchSync case.

## Orchestrator ruling added 2026-11-01 04:46 (the cycle-17 fixer's put-backs and cycle 17's verification; written while the cycle-18 fixer runs, before its verifiers start)

**S3-R21.** The owner decided on 1 Nov at 02:39: "No, keep fixing". C2 is not waived.
1. *The owed follow's own turns in the 10,000-member concentration shape.* Both cycle-17 verifiers measured the longest turn at 17.7 to 19.1 ms, at load about 5.
   - The shape is inside C2's reference set (S3-R5, S3F-5, S3-R20), so the breach is blocking. Option (c), ruling the shape outside C2, is not available.
   - The fix: join in place (option (b)), so each join is O(1) amortised with no live copy of a Job or JobInterest. Where a turn still exceeds C2, also bound the turns by the work done (option (a)).
   - Pin the result with a BenchSync release case: best of 3, at most `SyncBenchmarks.c2Budget`.
2. *`bringInbound`.* S3-R20 applies unchanged and must be recorded in the draft. In-place joins may shrink the measured 408 to 432 ms, but a figure over C2 at 10,000 still needs bounded turns (S3-R20 item 3).
3. *PROBE-C17-ADMIT-DURING-APPLY.* An admission that races an older apply omitting the id is answered `notFound`.
   - Visit-first gives the same answer, both rules predate s3-base, and no barrier is involved. It is outside the follow-barrier class and pre-existing, as in S3-R19 item 3, so it is not blocking and is not fixed in this close-out.
   - Record it under the draft's residual risks with the probe, its seed and figures, and the two options. Mark it for the owner in Stage 5's RESIDUAL-RISKS: it gives a wrong `notFound` under a race.
4. *RR-14* is now proven by both verifiers, so it is blocking (S3-R16 item 1(a)). Fix it as the verifiers describe, with the moves bounded under S3-R20.

## Orchestrator ruling added 2026-11-01 09:20 (cycle 18's verification and the cycle-18 fixer's put-backs; written after run 5 ended, before run 6)

**S3-R22.**
1. *A single visit or owed move that carries many ids in one turn.* The reqs verifier measured VERIFY-C18R-SHARED-CONVERGENCE: 10,000 prefetch members share one content, and a later apply maps them all to another, giving 54 to 56 ms in one turn on a quiet machine.
   - Like S3-R21 item 1's concentration shape, this shape is inside C2's reference set, so the breach is blocking.
   - Bound a visit's work and a move's work by the ids moved, continuing over the follow's turns as cycle 18's owed moves do.
   - The bounding must change no answer (S3-R20 item 3). Pin it with a BenchSync release case: best of 3, at most `SyncBenchmarks.c2Budget`.
2. *RR-18* (an apply inside a failed publication's bookkeeping await) was analysed, not probed.
   - As with S3-R19 item 4 for unprobed residual risks, it is not blocking.
   - The cycle-18 reqs verifier read that the difference may not exist: for an apply after the publication ended, `rerouteOnVisit` returns nil on a failed job with no verdict yet. Probe it if a seam that holds `integrityFailed`'s store await is cheap. Otherwise correct RR-18's text to that reading and leave it unprobed.
3. *Simulator and coverage runs take turns.* In cycle 16 the two verifiers' overlapping runs pushed the load to 782 and made other work packages' tests fail.
   - Before an iOS Simulator suite or a coverage run, take the lock: `mkdir /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock`. Wait while it exists, and remove it right after the run.
   - A lock older than 45 minutes is stale and may be removed.
   - A load-caused miss stays non-blocking (S3-R5), but re-run it alone before reporting.

## Orchestrator ruling added 2026-11-01 14:15 (the shared host; written before run 6, which starts at cycle 19)

**S3-R23.** The host is shared with other projects. At 14:09–14:11 on 1 Nov, their iOS Simulator UI test runs (other repositories, other simulators) held the load averages between 51 and 1,008 on 8 cores, and they may go on for hours. A timing figure taken under that load settles no C2 item either way.
1. Record the three load averages (`sysctl -n vm.loadavg`) next to every timing figure: benchmarks, C2 cases and hang-guard times.
2. A time-out or a budget miss seen only at a 1-minute load above 50 is judged by S3-R12 and S3-R5, so it is not blocking by itself. Re-run it alone at the lowest load you can get, best of 3, and report both figures.
3. A C2 fix that bounds a turn's work is pinned twice:
   - a deterministic test that a single turn stops at the bound (for example with a small injected bound). It holds at any load, and the drop-mutant of the bound must fail it;
   - the BenchSync release case of S3-R20 to S3-R22, best of 3, taken at a 1-minute load of 10 or less.
   - If the load never falls that low during your run, report the case as "not measured at a quiet load", with its figures and loads. It is then neither confirmed nor blocking. The orchestrator measures it at a quiet load before it rules the close-out converged.
4. Never stop, slow down or touch another project's processes or simulators. Use only your own simulator, and take the `sim.lock` of S3-R22 item 3.

## Orchestrator ruling added 2026-11-01 21:35 (the cycle-19 fixer's put-backs; written while the cycle-19 verifiers run, before any cycle-20 fixer)

**S3-R24.** A cycle-19 verifier that reads this before it returns judges these items by it.
1. *RR-20: an empty binding books a commit* (#14, VERIFY-C18R-EMPTY-BINDING). It is not blocking.
   - The answers agree in both orders, and the extra commit count and object success are bookkeeping.
   - The free-space estimate errs low, which is the safe side, until the next read.
   - Staging GC (R-CLN-3) reclaims the staged file.
   - Record it under the residual risks for Stage 5. It becomes blocking only if a probe shows that the extra object success or the low estimate changes an answer through a breaker or space decision (S3-R16 1(a), S3-R17). The finding's fix then applies.
2. *RR-21: work not bounded by ids in a turn* (#11).
   - The commit's binding of a 10,001-id publication measured 9.64 ms best at load 3.84. That is inside C2 by 0.36 ms, so it is not blocking now.
   - The next fix cycle pins it: extend `concentrationPublicationTurns` through the commit, best of 3, at most `c2Budget`.
   - It also measures, the same way at 10,000 ids, the drain's `takeOffMovedBefore` and the commit's re-routes of the ids it does not bind.
   - A miss at a 1-minute load of 10 or less, best of 3, is blocking (S3-R22 item 1). The fix then bounds that work over the follow's turns or the store's units without changing an answer (S3-R20 item 3), with the two pins of S3-R23 item 3.
3. *Branches no test reaches* (the draft's "Not reached by a test (cycle 19)"):
   - `findInbound`'s checksum-less lookups (`EngineFollow.swift:1049`, `:1095`);
   - `waitingTarget`'s queued, blocked and downloading case;
   - `scheduleFollowFollowUp`'s unspawnable branch.

   G4 applies to code that stays (S3-R16 1(e)), so each branch is blocking until one of these holds:
   - **Reached.** A test reaches it in both `LaneDropVisit` orders and kills its drop-mutant 2/2. For the checksum-less lookups, try the pass path first: a publishing checksum-less target is passed by a visit whose `rerouteOnPass` moves its own id off, and then an apply maps the id back before the target's attempt ends.
   - **Removed.** The branch is removed, the assumption it guarded becomes a `followBarrierViolations` clause that a test exercises (S3-R19 item 3), and the argument goes in the draft. For the checksum-less lookups, removal means a checksum-less target gets no inbound move, and the holder's own visit moves the id.
   - **Equivalent.** The branch runs but changes no decision, answer or state, for example a release with nothing to release. It is then equivalent by S3-R19 item 2, and the argument goes in the draft.
4. *#6: `awaitInboundMoves` overwriting a wait.* Accepted. The two invariants added to `followBarrierViolations` stand in for the unreachable overwrite (S3-R19 item 3).
5. *RR-23: RR-16 followed by an apply that maps the id on.* This is a timing difference (S3-R16 item 2), in RR-16's family.
   - Which content the caller gets depends on whether the later apply lands before the id's answer. The sweep-first engine answers earlier because it makes no second request.
   - Record it with RR-16. It is not blocking, and no probe is required.
   - It is blocking only if a probe shows a different answer when the later apply lands after both engines' answers, or before both.

## Orchestrator ruling added 2026-11-01 23:35 (cycle 19's verification; written after the cycle-20 fixer's first start, which was stopped and started again so that it reads this)

**S3-R25.** Cycle 19 fixed every blocking item of cycle 18, and both verifiers confirmed it. They left 8 distinct blocking items (both lenses report the flake). The items, with the non-blocking ones, are in `.build-orchestrator/s3f-c19-issues.json` ("correct #n" and "reqs #n" below are the lens's issue numbers). Their probes and scripts are under `.build-orchestrator/s3f-probes-c19/` (`correct/`, `reqs/`). The cycle-20 verifiers judge by this ruling.
1. *C2 in the drain* (correct #1, PROBE-C19C-DRAIN-BOUND, PROBE-C19C-DRAIN-C2). Blocking (S3-R22 item 1).
   - One turn's id budget covers the whole drain batch. Seed it with what the turn has left, the follow's last turn included. Pass what remains to `followAfterVerdict` at both call sites. When the budget is spent, put the rest of the batch back at the head and schedule a drain follow-up, as the `followMoving` branch does.
   - No answer changes (S3-R20 item 3).
   - Pins (S3-R23 item 3):
     - the probe's shape as a test in both orders at `followIDsPerTurn = 4`, with three such verdicts and every turn within the bound; the drop-mutant of the budget's subtraction fails it 2/2;
     - the 16-slot shape (`correct/VerifyC19DrainBench.swift`) as a BenchSync release case, best of 3 ≤ `c2Budget`.
2. *C2 per id: `Job.lane` and `dropInterest` cost O(interests of the job)* (correct #2). Blocking.
   - C2's reference set (S3-R5, S3-R21 item 1, S3-R22 item 1) is 10,000 ids however their interests are grouped: one prefetch group, many groups, or one user waiter per id. The 10,000-user-waiter shapes are inside it.
   - That the cost predates s3-base does not take it out. It is spent inside the follow's turns, and C2 is a standing order (S3-R20 item 1).
   - Fix as the verifier proposes:
     - per-lane interest counts on `Job`, kept on every insert, removal and lane change, so `Job.lane` is O(1);
     - `dropInterest` mutates in place, with no live copy of the Job, as S3-R21 item 1 did for joins.
   - Add an `invariantViolations()` clause: the counts equal a recount from `interests`. The drop-mutant of each count update (insert, removal, lane change) fails a test 2/2.
   - Pin both shapes of `correct/VerifyC19UserBench.swift` (superseding, and one id kept) as BenchSync release cases, best of 3 ≤ `c2Budget`.
   - Then measure S3-R24 item 2's figures (RR-21's commit window, `takeOffMovedBefore`, the commit's re-routes), which run through the same interest code.
3. *A C2 inventory before returning.* Cycles 17, 18 and 19 each found one more per-id cost.
   - List in the draft every operation the follow's turns and the drain do per id or per event, with its cost in the turn's ids and in the job's interests. The list includes `continueMove`, `continueInbound`, `continueVisitRemainder`, the drain's replays, the commit's binding and re-routes, `takeOffMovedBefore`, `addInterest`, `removeInterest`, `dropInterest`, `relane` and `Job.lane`, and any other operation found.
   - Each operation that is not O(1) amortised per id gets either item 2's treatment or a BenchSync release figure at 10,000 within `c2Budget`.
   - A missing or wrong row is blocking only if a probe shows a turn over `c2Budget` at a 1-minute load of 10 or less.
4. *The flake in `barrierReadmitsBehindTheOwedVisitsPlaces`* (correct #3, reqs #6). Blocking (S3-R16 1(d)). The two verifiers read two different mechanisms; settle which one it is before changing anything.
   - **Observe.** In the test, record the engine's own admission order (inside the actor, with each queue ticket). Repeat it on the simulator under `sim.lock`, in both orders, at least 30 iterations per argument.
   - **If the engine admits N ahead of every re-queued member each time,** the transport's `.started` records race after the store read (reqs #6).
     - Assert the engine's admission order instead.
     - Keep the test's tuning and scenario unchanged. Moving to one slot loses the concurrent scenario, which G3 forbids.
     - Record the old and the new assertion in the draft.
   - **If the engine itself sometimes admits a member first,** make the interleaving deterministic with the fakes' gates (no sleeps, C4) and keep the assertion.
     - If, with the interleaving fixed, the sweep-first order differs from visit-first's, that is an order difference (S3-R16 item 2).
     - Record it as a residual risk, and change the assertion one to one (S3-R16 item 4).
   - **Sweep.** Find every test in `ZTronAssetSyncTests` that asserts the order of the fake transport's `.started` records at a point where more than one attempt can be in flight. Give each the same observation change and record each in the draft.
   - **Close.** Run 30 iterations per argument on the simulator with 0 failures, and the Sync bundle under `--enable-code-coverage` 3 times.
5. *The bound's pins* (reqs #1). Blocking (S3-R23 item 3).
   - Commit the two shapes of `reqs/VerifyC19ReqsTurnTotalProbes.swift` as tests in both orders. Each counts, per turn, the ids that leave all holders.
   - Kill `inboundSpentDrop` and `restSpentDrop` 2/2.
   - Add those two and `continueMoveBudgetDrop` to the draft's mutant table.
6. *`findInbound`'s checksum-less lookups* (reqs #2). PROBE-C19R-LEGACY-TARGET (`reqs/VerifyC19ReqsLegacyProbes.swift`) reaches them, and the recorded move differs under both mutants. So of S3-R24 item 3's options, only "Reached" is left.
   - Commit the probe's shape as a test in both orders, as the verifier describes.
   - Kill `byIdentifierTargetDrop` and `byIdentifierLookupDrop` 2/2.
7. *`waitingTarget`'s queued, blocked and downloading case* (reqs #3) and *`scheduleFollowFollowUp`'s unspawnable branch* (reqs #4). S3-R24 item 3 applies unchanged.
   - **`waitingTarget`.** Try first the window the draft concedes: a publication's ENOENT re-queue behind the barrier (`enqueue`'s doc in `EngineJobs.swift`), with an owed move onto it and a lane decision that reads `carried()`.
   - **The unspawnable branch.** This is a liveness branch. Try first a shutdown, or a degrade, that lands between the follow's turns.
     - A test that reaches it asserts that every wait is released and shutdown completes.
     - It uses a bounded check, not a time limit, so the drop-mutant fails rather than hangs.
     - If no path reaches the branch, remove it with a `followBarrierViolations` clause for the assumption. The draft's argument covers all five state resets the branch makes.
8. *`continueMove`'s re-validation and its end re-lane* (reqs #5: `EngineMoves.swift:203`, `:206`, `:222-223`). Blocking (S3-R16 1(e)).
   - **`:203` and `:206`.** These are the per-interest guards that make a stale holder safe (item 9). Reach them; do not remove them. Possible shapes:
     - a waiter that cancels between a bounded move's turns;
     - a token's interest, or its ids, taken off the holder between turns by an owed move or a later apply's walk.
   - **`:222-223`.** Reach it with an apply that maps an id back to a superseded holder's content mid-move, or remove it with a `followBarrierViolations` clause.
   - Kill each reached line's drop-mutant 2/2 in both orders.
9. *A holder re-created between turns* (correct #4). Not blocking.
   - Record in the draft why item 8's per-interest guards make the stale items no-ops.
   - Do not add a holder epoch: it would add another branch under G4.
   - It becomes blocking only if a probe shows a different answer, a broken MUST or invariant, or a hang.
10. *The fixer's own check before it returns.* This stops the next cycle from finding the fixer's own new branches. On the final HEAD:
    - Run `reqs/covdiff.py` over every line changed this cycle. Each zero-count changed line is one of:
      - reached, with its drop-mutant killed 2/2;
      - removed;
      - listed in the draft as structural (an Optional's empty case, a loop's exit; reqs #10) or as Equivalent, with the argument.
    - Drop-mutate every branch added this cycle and every subtraction and comparison in a turn bound (`reqs/mut.py`, `reqs/turnmut.py`). Put each result in the draft's mutant table.
    - Copy the verifiers' scripts and adapt them to your own scratch path; do not run them in place.
11. *Non-blocking:*
    - RR-21 (reqs #7): S3-R24 item 2 applies, measured after item 2's change.
    - The draft's records (reqs #9): RR-23 moves under RR-16 (S3-R24 item 5), and RR-20 stays under the Stage 5 residual risks.
    - Structural zero-hit lines (reqs #10): note them in the draft as structural.
    - P-13 (correct #5, reqs #8) stays routed to WP-B.
    - The load-only miss of `throttleExtensionTurns` (correct #6) is covered by S3-R23 item 2.
    - `shutdownReleaseInboundWaitsDrop` is killed only by a hang. That is not blocking; if item 7's bounded check also kills it, record that.

## Orchestrator ruling added 2026-11-04 13:19 (cycle 20's verification and the cycle-20 fixer's put-backs; drafted 2 Nov, appended before run 7's cycle-21 fixer starts)

Run 6's first cycle-21 fixer was stopped at 05:30 on 2 Nov, one minute in, so that the fixer reads this ruling. The ruling was drafted on 2 Nov and reviewed twice (`s3f-c20-analysis/s3-r26-review-v1.md`, `s3-r26-review2.md`). The owner stopped Stage 3 on 2 Nov at 12:15 and asked for the next fix cycle on 4 Nov, so it is appended on 4 Nov, before run 7's cycle-21 fixer starts.

**S3-R26.** Cycle 20 fixed 7 of cycle 19's 8 distinct blocking items, and both verifiers confirmed it. `waitingTarget` (S3-R25 item 7) is the one item left open.

Where to find things:
- The verifiers left 8 distinct blocking items. They are in `.build-orchestrator/s3f-c20-issues.json`, with the non-blocking ones. "correct #n" and "reqs #n" below are each lens's issue numbers.
- Their probes, scripts and logs are in `.build-orchestrator/s3f-probes-c20/` (`correct/`, `reqs/`).
- The read-only analyses made for this ruling are in `.build-orchestrator/s3f-c20-analysis/`. **Two of them are the specifications to implement:**
  - `integrate-c21.md`: items A (the deferred joins), B (the move index) and C (the commit window), with their interactions with RR-21, an order of work and five open questions;
  - `integrate-rr21.md`: RR-21, in the same format.
- The rest is background:
  - the three RR-21 designs (`design-minimal.md`, `design-fixer.md`, `design-reuse.md`), the judge that rejected all three as written and proposed the synthesis `integrate-rr21.md` builds on (`judge-rr21.md`), and the three critiques of the minimal design (`critic-rr21-*.md`);
  - the designs and critiques behind items A–C (`design2-*.md`, `critic-defer-bucket.md`, `critic-move-index.md`, `critic-commit-window.md`);
  - the analysts' readings of `waitingTarget`, the drain branch, `continueMove` and the inventory rows (`analyse-g4-reach.md`, `analyse-state-cost.md`).

This ruling decides wherever those files differ from it. The cycle-21 verifiers judge by this ruling. Three rules apply to both specifications:
- **Names.** The two specifications reuse labels. In this ruling and in the draft's records:
  - `integrate-rr21.md`'s numbered labels carry `rr21-`: its tests (rr21-T1, rr21-T1-edge, rr21-T8b), its branches (rr21-B1 to rr21-B32) and its commit plan (rr21-C0 to rr21-C8). Its named tests (RR21-HOP, T-WATCH and the rest), R1–R19 and D1–D12 keep their names.
  - `integrate-c21.md`'s numbered tests carry their item's letter: A-T1, B-T5. Its steps A1–A13, B1–B13 and C0–C13, and its clauses K1–K4, I1–I3 and P1–P3, keep their names.
  - "C2" alone is the budget class (S3-R5). Item C's step is "step C2".
  - "P3" alone is CLAUDE.md P3: the failing test first, then the fix. Item C's progress-gate clauses are "clauses P1–P3".
- **Which specification wins.** `integrate-rr21.md`'s interactions_changed replaces `integrate-c21.md`'s interactions 1, 3, 7, 11, 13 and 18, which still describe `design-minimal.md`. Where they differ:
  - the replay returns `EventAfterFollow?`; there is no `rerouteTakenOff` and no `left`;
  - `withdrawPurgedJoins`' early return stays through step 3 (A8) and is removed at rr21-C3, not narrowed;
  - only the waiter and group clauses accept owed items; the run clause gets no acceptance;
  - drain turns spend `drainIDsLeft`; a site's own turn at sites 1 and 3 spends `inboundIDsNow`.
- **UNCONFIRMED claims.** Confirm each claim either specification marks UNCONFIRMED, in the code or by a probe.
  - Where one is false, use the simplest change that keeps that specification's invariants (K1–K4, I1–I3, clauses P1–P3, and RR-21's acceptances, new clauses and D1–D12), and record it.
  - List in the draft any claim left unconfirmed, with the reason.
  - A cost or time estimate is confirmed by its figure. A miss follows the route this ruling gives that figure (items 1, 3 and 4, answer 6.6). A miss with no route is blocking; report it with its figures.

1. *RR-21: the commit's re-routes, the drain's take-off, and `.superseded`'s re-routes* (reqs #1 and #2; correct #3 and #4). Blocking (S3-R24 item 2, S3-R22 item 1, S3-R25 item 3). All three re-route a job's whole interests in one turn. At 10,000 ids they take 47.99–49.34 ms, 47.03 ms and 41.09 ms, best of 3, at a 1-minute load of 10 or less.
   - **Implement `integrate-rr21.md`:** R1–R19, its invariants (the new clauses and D1–D12), its tests, its pins, its must_nots and its branches table (rr21-B1 to rr21-B32). In short:
     - Each site decides once, in its own turn, whether it owes.
       - If its work fits, it makes all its re-routes at once. At sites 1 and 3 the bound is `inboundIDsNow`. At the commit, the fit charge also counts the commit's own answers: `locations.count + items.count > inboundIDsNow`. Site 2's turn is a drain turn and spends `drainIDsLeft`.
       - If it owes, it makes none of its re-routes at once. It owes all of them as one `.reroutes(RerouteBatch)` event. The drain replays it at its queue position, at most `drainIDsLeft` distinct ids a drain turn, each id with all its tokens.
     - Each owed id is re-routed under the copy the reference engine would have used: `rerouteListing` walks the layers that `adoptApplied` records while a batch waits. A pin holds only while `waitingTarget(transfer, epoch:)` holds.
     - While any batch is owed (`reroutesWaiting > 0`), no publication binds (`inboundBlocks`) and no run settles (`checkRunSettled`). While any event waits, no binding is pruned and the watcher stays (`pruneBoundContent`, `hasWork`).
     - Site 2 decides before its verdict whether it owes. If it does not, it reserves its ids from `drainIDsLeft`; if it does, it zeroes `drainIDsLeft`, so the visit moves nothing in that turn.
   - **Rejected,** with the evidence in `judge-rr21.md` and `critic-rr21-answers.md`:
     - re-routing owed ids under the copy at the replay (`design-minimal.md`): it reopens RR-14 (refutation 1);
     - the publication hold as a fallback only: W1..W3's answers differ with no gate change during the barrier (refutation 2);
     - letting the site's own `reconcileIdle` prune owed pairs' bindings (refutation 3);
     - a pseudo-follow or any new source of `followOwed`, owed pairs on a holder job, and a hold per target;
     - a layer per commit, unless the probe of item 12's answer 6.3 breaks.
   - **Prerequisites.** RR-21 lands after item 4's Phase 1 (steps C3, C5, C10, C11), item 2 (A2–A11, so that item 6's branch is gone first) and item 3's B2–B5.
   - **The pins** (S3-R23 item 3: one deterministic test and one BenchSync case per bound):
     - the site's own turn at sites 1 and 3: rr21-T1-edge, rr21-T1-fit and rr21-T2-edge; `concentrationCommitRerouteTurns` and `supersededRerouteTurns`;
     - a drain turn: rr21-T1's and rr21-T3's per-turn id counts; `commitRerouteDivergentTurns` and `movedBeforeDrainTurns`;
     - site 2's own turn: RR21-VERDICT-ZERO and rr21-T3; `movedBeforeDrainWaitersTurns` and `movedBeforeAndAfterTurns`.

     The other BenchSync cases that `integrate-rr21.md` names, in its pins or its commit_plan, are item 9's inventory figures. Two of them are defined only in background files; build them from there: `supersededUserTurns` (`design-minimal.md:285`) and `groupDelistedFit` (`critic-commit-window.md:83`). Measure every one, O(1) rows included. A miss at a 1-minute load of 10 or less, best of 3, is blocking (S3-R16 1(f)); otherwise S3-R23 items 2 and 3 apply.
   - **Four holes are blocking fixes, whatever a probe shows:** the three that `critic-rr21-answers.md` found, and the mid-drain run settlement that `integrate-rr21.md` found. Each test runs red first as item 11 defines it for shapes that need the new code:
     - RR21-HOP and RR21-WINDOW-GATE, at sites 1 and 3. Site 2's targets cannot start or publish behind the barrier, so neither hole reaches site 2 (`critic-rr21-answers.md:103`). The draft cites that line in place of a site-2 test.
     - RR21-PRESENT-PRUNE, at all three sites.
     - RR21-RUN-MIDDRAIN, for the run that settles mid-drain.
   - **Existing tests that change path.** The fit charge, site 2's reservation and the idle guards can change the path of existing tests: the six low-budget suites, and the idle and ledger tests that `integrate-rr21.md`'s plan_gaps names.
     - Answer, MUST and invariant assertions never change (G3, S3-R16 item 4). A change there is a finding: fix the code, not the test.
     - An existing test whose path changes through `pruneBoundContent`'s or `hasWork`'s idle guard takes answer 6.5's narrow fallback first. This holds for the idle and ledger tests, the six suites and any other test.
     - If it still changes path, its assertions stay. Only the steps that reach them may change, for example releasing the owed drain turns before the idle assertion.
     - A low-budget suite whose turn count or order changes through the fit charge or the reservation may be updated one to one, to an expectation as exact as the old one. Each bound's drop-mutant must still fail it 2/2 (S3-R23 item 3, S3-R25 item 5).
     - Record each update in the draft: the old assertion, the new one and the cause. For an order change, also give its S3-R16 item 2 class.
     - This extends S3-R16 item 4 to these causes only.
   - **Residual risks:** `integrate-rr21.md`'s residual_risks, each in the class that file gives it, with the condition that would make it blocking. Where item 12's answer 6 differs, answer 6 decides. Record each in the draft with its test or probe.
     - Its order entries join item 10's accepted orders.
     - Its C2 entries (k tokens per id; the figures still open) are gates, not residual risks: a miss is blocking, as above.
     - "Memory only" is recorded without a class.
   - **`followedLane`'s walk over owed items** is an inventory row (item 9). If its figure misses at 10,000 non-user items, the per-batch lane summary that `integrate-rr21.md:886` names is its route: build it with its branches in the branches table, each killed 2/2 as answer 1 says, and give the summary its own row. A miss that stays is blocking (S3-R16 1(f)); report it with its figures.

2. *`deferBehindVerdict` costs O(E) a join* (reqs #3, correct #2). Blocking: S3-R25 item 3's row now has a probe, which shows 35.78–39.55 ms.
   - **Implement item A of `integrate-c21.md`:** A1–A13, the clauses K1–K4, its tests, its pins and its must_nots.
     - A join that a follow's visit defers behind a waiting exit verdict goes into a bucket keyed by that verdict's (transfer, epoch).
     - The drain places the bucket right behind its verdict, newest first, when it forms that verdict's batch.
     - Batches, their boundaries, the order, and the barrier state inside every replay stay as today.
   - **Rejected:** putting a verdict's joins back after its replay, which is `design2-defer-bucket.md`'s recommendation. It changes `followBarrier` inside the replay and adds a turn boundary (A6r).
   - **The pins:**
     - A-T1's per-turn assertion;
     - the BenchSync case `deferBehindVerdictTurns`, over {404, timeout} × {one prefetch group, one user waiter per id} at 10,000 ids.
   - **A11 and K4**, the removal of the branch for a refused spawn, are item 6.

3. *`move` re-sorts its holder once per move* (correct #1; reqs #6, at the edge). Blocking: 79.55 ms at 16 owed moves off one 10,000-id holder, and 304.79 ms at 64.
   - **Implement item B of `integrate-c21.md`:** B1–B13 and the clauses I1–I3, with its tests, its pins and its must_nots, except B8, I2 and B-T5, which are item 7.
     - `Job.tokensByID` maps each id to the interests that hold it. Every `Job` mutator keeps it in step, so a move reads its ids' holders in O(moved + holders).
     - No `Job` copy stays alive across the table's mutations in `move`, `startMove`, `follow`, `continueInbound` or `answerPresentMembers`.
   - **When:** B lands after item 4's Phase 1 and its first measurements, and before item 1, which needs B2–B5.
   - **The merge gate:** `concentrationPublicationTurns` with the index in place, best of 3 at most `c2Budget` at a 1-minute load of 10 or less (`critic-move-index.md` A1).
     - Check it at step 4 in every case, before B merges.
     - If it fails, build the index lazily, at a job's first move off it (contingency (ii) in `critic-move-index.md`), and re-measure.
     - B lands either way. `integrate-c21.md`'s "do not merge without the merge gate" means measured before the merge, not passed. A miss that stays with the lazy index is blocking (S3-R16 1(f)): report it to the orchestrator with its figures and loads, and go on with the other steps (item 4's "Some misses stay" rule). Phase 2 is not its remedy.
     - The gate decides the contingency, and the final figure is what the verifiers judge.
   - **The pins:**
     - `manyMovesTurns` at k = 1, 16, 64 and 256. 256 is the most moves one turn makes (`followsPerTurn`). If 256 held publications cannot be built, pin the largest k that can, and record why.
     - `partialMoveTurns`, with and without users.
   - **The index's own costs** are inventory rows, each with a figure:
     - the release in `dropInterest`, and in the `removeInterest` and `subtractAssets` calls of item 1's take-off and trims (item 1 has no `dropInterests`);
     - `keepInterests` on a copy;
     - the freeing at the commit.

4. *The commit turn's headroom* (correct #5; reqs #10). Blocking: a pinned case missed, at 10.16 ms best of 3 at a 1-minute load of 3.12 (S3-R24 item 2). The other lens measured 9.82 ms at the same load, so the case flaps.
   - **Implement Phase 1 of item C of `integrate-c21.md`:** C0–C11 and C13, the progress-gate clauses P1–P3, its tests, its pins and its must_nots. Its must_nots on Phase 2 bind step 6 too.
     - The commit stays one turn, with no added await (R-SYN-12, F-20, RE-S14).
   - **C1** lands only with item 1's rewrite of `committed`, in R4's form:
     - an id is moved away when `applied.entry(for:)?.transferID != transfer`;
     - for a deferred id, `if !refused, captured.contains(a) { refused = true }`, with `captured` lazy. This is R4's predicate in N3's guard form;
     - no `sameTransfer` conjunct is added.

     R4's mutants replace `integrate-c21.md`'s N3:
     - building `captured` eagerly, and dropping `!refused`, stay Equivalent (N3): setting `refused` twice changes nothing;
     - rr21-T3-captured kills "refused never set" (rr21-B3, rr21-B4);
     - build T-R1 and T-R2 from `design2-commit-window.md` N3. T-R1 kills "refused set for moved-away ids". T-R2 kills "refused set without `captured.contains`". Both run in both orders.
   - **Measure first,** right after Phase 1: `concentrationPublicationTurns`, `commitTurns(.waiters)` and `commitTurns(.waitersStalledSubscriber)`. Take both the heartbeat and the commit's own turn inside the actor, each best of 3, with its load.
   - **Phase 2 (C12)** defers only waiter and ensure answers, and only for a job with more than `answersPerTurn` (512) interests. It cannot cut `concentrationPublicationTurns`, `groupStalledSubscriber` or `manyGroups`, and it is never their remedy. It applies if any of these holds, each best of 3 at a 1-minute load of 10 or less:
     - after Phase 1, the in-actor `.waiters` commit turn is above 7.0 ms;
     - after Phase 1, the heartbeat of `.waiters` or `waitersStalledSubscriber` is above `c2Budget`;
     - at rr21-C3, `commitWaitersBoundTurns` or `commitRerouteWaitersTurns` is above `c2Budget`, in the commit's own turn or in its heartbeat.

     Phase 2 lands at step 6 in every case.
     - A `commitRerouteWaitersTurns` miss that stays with Phase 2 in place belongs to item 1. Report it with its figures.
     - A `groupStalledSubscriber` miss takes `SubscriberQueue.reserveCapacity` (`integrate-c21.md` C12).
     - Some misses stay (a miss is a figure above `c2Budget`; 7.0 ms is only a trigger): one that Phase 2 cannot cut, item 3's merge gate among them, or one that remains with Phase 2 or `reserveCapacity` in place. Such a miss is blocking (S3-R16 1(f)). Report it to the orchestrator with its figures and loads (`integrate-c21.md:375`), and go on with the other steps.
     - Record the figures that decided it, either way.
   - **After `committed`'s rewrite (rr21-C3),** re-measure `concentrationPublicationTurns` (the merge gate) and every `commitTurns` shape: the heartbeat and the in-actor turn, best of 3, with their loads (`integrate-rr21.md:862-863`). Check every Phase 2 trigger again on these figures ("after Phase 1" means at step 2 and here); a trigger that fires puts Phase 2 at step 6. A `groupStalledSubscriber` miss takes `reserveCapacity`, and a merge-gate miss takes item 3's lazy index if B landed with the eager one. Any other miss follows the "Some misses stay" rule.
   - **The order of resumes.**
     - `resolveAll` now resumes in the table's order (step C2). That is a residual risk (S3-R16 item 2).
     - If an existing test depends on the order of resumes, keep the sorted order there, measure its cost, and report it (G3).
   - **Terminal events stay ascending** (step C3; item 12's answer 2).
   - **Subscribers:** item 12's answer 4.

5. *`waitingTarget`'s queued, blocked and downloading case* (reqs #4, correct #6). Blocking (S3-R24 item 3, S3-R25 item 7).
   - **Only "Reached" is left.** `analyse-g4-reach.md` reads the case as reachable by two paths:
     - the ENOENT window that S3-R25 item 7 named;
     - a T20 re-queue (relane's failed arm) inside an ENOSPC's free-space read.

     The case changes where an id waits, the join order and the target's ticket. So it is not Equivalent, and it cannot be removed while a shape reaches it.
   - **The test.**
     - Commit Shape A (the ENOENT window) from that file as a test. Use Shape B (the T20 window) instead if A's drained publication does not compose with the walk.
     - Run it in both `LaneDropVisit` orders.
     - The window exists only in `sweepFollowsFirst`. In `followVisitedFirst` the move is made while the target verifies, and the same test is the answer reference.
     - Item 12's answer 1 says what "reached in both orders" means here. The test reaches `waitingTarget`'s `.queued, .blocked, .downloading` arm in `sweepFollowsFirst` (`EngineFollow.swift:1260-1261` at `8e1fb24`; re-cite it after step 5), and asserts visit-first's answers in both orders.
   - **The mutant.** Kill the fold mutant (`case .queued, .blocked, .downloading: return job`) 2/2. The test asserts the `sweepFollowsFirst` state after one follow turn: the id is still on its holder and not on the target, and no move onto the target is owed.
   - **Residual risk.** The order, place and ticket difference the case makes is a residual risk (S3-R16 item 2). Record it in the draft with the test's figures.
   - **Docs.** Correct three:
     - `enqueue`'s (`EngineJobs.swift:466-470`), which lists who gives places;
     - `Job.epoch`'s (`EngineState.swift:685-686`): only `start` and job creation bump it;
     - the draft's claim that only one path reaches `queued` (`s3f.md:4942-4949`).
   - **Probe two candidates while you build the shapes** (S3-R19 item 1). Run each probe in both orders. A probe that breaks S3-R16 item 1 in either order is blocking. Both windows exist only in `sweepFollowsFirst`, so a break there is enough. If one breaks, P3 applies: the failing test first, then the fix.
     - (i) *The T20 verdict skip.* Run Shape B with an interest at its cap (`interactiveRetry.maxAttemptsPerRun = 1`), or with a reclaim pending.
       - The question: does the barrier start one more attempt where visit-first answers with the ENOSPC figures? That would be a different answer and a request past the cap.
       - The fix belongs in relane's failed arm, not in `waitingTarget`. For example: no T20 re-queue while the attempt's end is recorded and the barrier is up, as for a deferred verdict. relane's comment (`EngineJobs.swift:286-295`) says cycle 17 meant to stop exactly this. It is not a fix of the `waitingTarget` window under `integrate-rr21.md`'s must_not.
       - Item 5's test lands before that fix. If the fix removes the test's only path, reach the case with Shape A, or through rr21-T8b's pin caller (item 12's answer 8). If no shape reaches it, remove the case with the reason (S3-R16 1(e)), and correct the line above that says it cannot be removed.
     - (ii) *The later-apply variant.* A later apply maps the id to U while T still publishes, and T's fresh attempt then fails terminally. If the answers differ, S3-R17 decides:
       - if a SPEC MUST says the id follows its current entry, the engine's answer that follows it stands, and the difference is a residual risk;
       - otherwise the difference is blocking. Fix it with the smallest change that makes the probe's answers equal visit-first's in both orders: commit the failing test first, then the fix. That fix may change the `waitingTarget` window: this lifts, for that fix only, the must_not at `integrate-rr21.md:586`. Every other must_not still binds; if the smallest fix would break one, report it to the orchestrator with the probe, and it stays blocking. If the fix removes item 5's test's only path, (i)'s fallback applies. Record the design, its tests and its branches (answer 1).

6. *`scheduleDrainFollowUp`'s unspawnable branch* (reqs #5, correct #7). Blocking (S3-R16 1(e)), as S3-R25 item 7 ruled its twin.
   - **Remove it:** A11 of `integrate-c21.md`. `analyse-g4-reach.md` shows the branch is unreachable. Remove it as `bf1d4eb` did for `scheduleFollowFollowUp`:
     - call `spawn` and drop its result (`spawn` is `@discardableResult`): drop `let spawned =` at `EngineFollow.swift:384`;
     - delete the `if spawned == nil { … }` block, `EngineFollow.swift:390-399`.
   - **The clause:** K4 of item A. It states the assumption: work waits for a follow or a drain only while the engine runs.
     - It reports `!isRunning && !eventsAfterFollow.isEmpty`. Item 1's owed events wait in `eventsAfterFollow` too.
     - K1 covers the buckets: a bucket needs a waiting verdict event.
     - Keep K4 separate from `bf1d4eb`'s clause, so that `EngineFollowShutdownTests`' exact expectation stays unchanged (G3).
   - **The test:** F-K4.
     - Force the state after shutdown with the `violations(after:)` helper, and expect exactly K4's message.
     - Add a control on a running engine with a drain scheduled.
     - K4's drop-mutant fails the test 2/2.
   - **The draft.** The argument covers all seven assignments the branch makes:
     - six data resets, which `drainEverything` makes;
     - the flag, which `drainFollowUp` clears itself.

     It cites `drainEverything` and `drainFollowUp`'s guard (`EngineFollow.swift:411`), never the removed branch.
   - **The caveat.** `notifyObservers` evaluates conditions between `EngineLifecycle.swift:490` and `:498`. Check that no test condition there calls `invariantViolations()`, and record that you checked.

7. *`continueMove` takes the id out of `Job.assets` before its guards* (put-back 4; reqs #9). Not blocking by itself (S3-R25 item 9).
   - **Why it matters.** As `analyse-state-cost.md` shows it, the Q1 state gives the same answer, at the cost of one more job and one more request. It does break I2 (every interest's ids lie in `Job.assets`), the clause that this item adds with B8.
   - **Implement B8 with I2 and B-T5, together** (item B's must_not). They belong to item 3's blocking work, and may be dropped only as the last bullet says:
     - keep the removal at `EngineMoves.swift:195`;
     - after an id's last item, put the id back into `Job.assets` if an interest still holds it.
   - **B-T5 fails first** in `sweepFollowsFirst` on `8e1fb24` (P3, as item 11 defines it).
   - **Probe Q1's stages 2 and 3** (variant Y) in both orders (S3-R19 item 1). Each probe is blocking only if it breaks S3-R16 item 1 in either order: a different answer, a broken MUST or invariant, or a hang. P3 then applies.
   - **If B-T5 cannot be built** after a real attempt, drop B8 and I2 together:
     - record the attempt;
     - record Q1 and variant Y as residual risks in RR-16's family: one more job and one more request for the same content.

8. *`recordDeferredVerdict`'s away filter* (reqs #8). Not blocking.
   - Give it its figure. Wrap `movedBeforeDrain`'s release of J in its own `SyncBench.longestWait` window, as `analyse-state-cost.md` describes.
   - Report it best of 3 against `c2Budget`. A miss at a 1-minute load of 10 or less is blocking (S3-R25 item 3); otherwise S3-R23 items 2 and 3 apply.

9. *The fixer's own check before it returns.* S3-R25 item 10 applies again, on the final HEAD, to every line and branch this cycle changes. Also:
   - **Inventory.** Add the new work to the C2 inventory. Every per-id, per-event or per-owed-item operation of items 1–4 is a row:
     - the bucket's placement at batch formation, and the purge's and `followedLane`'s walks over the buckets (item 2). K2's recount is a test oracle (only `invariantViolations()` calls it), so it is not a row;
     - the index's upkeep in every mutator, and its release and freeing (item 3);
     - the commit window's rows, C0 (item 4);
     - each RR-21 site's own turn: the collect pass and trims, the take-off, site 3's item build, the run-claim release, and the adopt turn's layer pass (item 1);
     - the owed re-routes' replay, and every walk over owed items (item 1).

     Each row gets its cost. It also gets a BenchSync figure at 10,000 ids in its worst grouping, unless it is O(1) amortised per id and no specification names a case for it (item 1 measures every case its specification names).
   - **Re-measure.** Re-measure every existing C2 case the cycle's code passes through, best of 3 at a quiet load, and list them with their loads. The cases include `userSharedApplyTurns`, `sharedApplyTurns`, the concentration cases, `drainVerdictTurns` and `throttleExtension`.
   - **Margin.** A case with a best of 3 above 8.5 ms is listed as "at the edge", with what would cut it. The commit window flapped between 9.82 and 10.16 ms at the same load. Prefer designs that leave margin. This is not a new gate: `c2Budget` stays the bar.

10. *Residual risks and the non-blocking items:*
    - **The publication window is closed, not accepted.** Item 1's global hold keeps every publication from binding while re-routes are owed. A publication that binds only the ids that have joined it is blocking: RR21-WINDOW-GATE shows a different answer with no gate change during the barrier. What stays is item 12's answer 6.2: the hold's delays are timing.
    - **Residual risks of items 2–4:** record `integrate-c21.md`'s residual_risks for A, B and C as item 1 records RR-21's: each with its class, the condition that would make it blocking, and its test or probe. Where this ruling places one (items 4 and 10), the ruling decides.
    - **Accepted orders** (S3-R16 item 2), each recorded in the draft:
      - the newest-first order of the joins behind one verdict (item 2);
      - the table's order of resumes in `resolveAll` (item 4);
      - item 5's order, place and ticket;
      - item 1's replay in (asset, token) order, and the places of jobs created at the replay;
      - item 1's two orders at site 2, with `PROBE-RR21-RESERVE-REJOIN` (item 12's answer 7);
      - item 1's bulk release of run claims, which can let a run materialise more fetches, with rr21-T18.
    - **Item B's earlier take-off** is order and timing (S3-R16 item 2). On the bounded path, unheld moved ids now leave the holder at the first turn, as they do on the fit path. For each reader that `integrate-c21.md` B's residual risks lists, confirm on the new code that it reads no stale binding or failure record. A reader that gives a different answer is blocking (S3-R16 1(a)). Record the readers and the check.
    - **reqs #7** (`EngineDispatch.swift:1118`, reached in some runs only) is not blocking by itself. The line that replaces it in item 1's rewrite of `committed` is a changed line, so item 9 applies to it. Reach it with a deterministic test (one token, with one bound id and one unbound id; `integrate-c21.md` interaction 8), and kill its drop-mutant 2/2. A zero count there is blocking.
    - **P-13** (correct #8, reqs #11) stays routed to WP-B.
    - RR-20 and RR-23 stay as S3-R24 and S3-R25 placed them.

11. *Order of work:* `integrate-c21.md`'s implementation order, steps 0–8, with these changes.
    - **Step 1** also holds, on `8e1fb24`:
      - the probes of item 12's answer 5 and of item 7's stages 2 and 3;
      - the first probe of the join gap, `PROBE-RR21-JOIN-GAP` in `sweepFollowsFirst` (item 12's answer 6.4);
      - item 8's figure.

      `deferBehindVerdictTurns` takes its 'before' figure in step 1 without the expectations that read `joinsBehindVerdicts`, which does not exist yet. Step 3 (A12) adds them, with the drained count that includes bucket joins.
    - **Step 5** is item 1. `integrate-rr21.md`'s commit_plan replaces `integrate-c21.md`'s step-5 text, which still names `design-minimal.md`'s steps:
      - rr21-C0 opens step 5, on the HEAD after steps 2–4. It runs `verify.sh --quick` and takes the 'before' figures of `concentrationCommitRerouteTurns` and `movedBeforeDrainTurns`, best of 3, with their loads;
      - rr21-C1 is the step-1 probe above;
      - rr21-C2, the types and the pure helpers, changes no behaviour;
      - rr21-C3 lands the readers before site 1, or with it; never an owing site before the acceptances and the clauses. It also runs `PROBE-RR21-HEAL-T21` and `PROBE-RR21-PIN-END` (item 12's answers 6.1 and 6.3). It then runs the low-budget, idle and ledger suites, and re-measures the commit and drain turns, `concentrationPublicationTurns` and every `commitTurns` shape (item 4);
      - rr21-C4 re-probes the join gap in both orders, as item 12's answer 6.4 says;
      - rr21-C5 is site 3, and runs `PROBE-RR21-PIN-END` again;
      - rr21-C6 is site 2, with the chunking if `movedBeforeDrainWaitersTurns` misses (item 12's answer 6.6). It runs `PROBE-RR21-RESERVE-REJOIN`;
      - rr21-C7 is the records; rr21-C8 is step 8.
    - **Step 6** is item 4's Phase 2, if any of item 4's triggers fired.
    - **Step 7** is item 5, with its two probes.
    - **Red first.**
      - A test whose shape exists on the code before its fix is committed failing, on its own, immediately before its fix (S3-R1, P3). This holds inside step 5 too. Only that commit may be red, and its message names the test. Every other commit stays green.
      - A test whose fix comes in a later step is run on `8e1fb24` in step 1, with its failing line recorded, and committed failing right before its fix.
      - Where the shape cannot exist before the fix (item 1's four holes), "red first" is a scratch copy, as S3-R3 does. Remove the guard (the publishing term in `ends`, the hold term, the prune guard, or `reroutesWaiting == 0` in `checkRunSettled`), run the test, and paste its failing line into the draft. Then commit the test with its guard. For these four, this replaces S3-R1's separate failing commit.
      - A probe that holds is recorded with its result and is not committed as a failing test. A probe that breaks S3-R16 item 1 becomes a failing test under the first rule.
    - **A deciding figure without a quiet load.** If a figure that decides Phase 2, site 2's chunking or item 3's merge gate cannot be taken at a 1-minute load of 10 or less, decide on the best of 3 at the lowest load you get. Record it as "not measured at a quiet load" (S3-R23 item 3), with its loads. The orchestrator re-measures it before close-out, and a different result reopens that decision.
    - **Commits.** Commit each step on its own, with its tests, so that a verifier can read the cycle step by step. Within step 5, commit each of rr21-C2 to rr21-C7 on its own.

12. *Answers to the specifications' open questions.*
    1. **A branch whose state arises only in `sweepFollowsFirst`** counts as reached in both orders when all three hold:
       - its test runs in both `LaneDropVisit` orders and asserts visit-first's answers in both;
       - the test reaches the branch in `sweepFollowsFirst`, and the branch's drop-mutant fails it 2/2 there;
       - the draft says, per branch, why `followVisitedFirst` cannot reach it, with a citation (for example `EngineFollowBarrierTests.swift:97-108`). Where the test can observe that state, a per-order `#require` that pins its absence in `followVisitedFirst` may stand in for the citation.

       This covers every branch whose state arises only in `sweepFollowsFirst`. The draft lists each one, with its citation or its `#require`. They include:
       - item A's bucket branches and B8's re-insertion;
       - item 5's case, and any branch that a fix of its probes adds;
       - item 1's site-2 branches (rr21-B6 to rr21-B9, RR21-VERDICT-ZERO) and, if built, the chunking's branches (answer 6.6);
       - rr21-B26, if RR21-RUN-MIDDRAIN cannot reach it in `followVisitedFirst`.

       For such a branch, "2/2 in each order" or "2 out of 2 times in both orders" in either specification means 2/2 in `sweepFollowsFirst`; one example is A-T1's pin. This amends S3-R24 item 3's "Reached", and S3-R25 item 7, for these branches. A branch that `followVisitedFirst` can reach keeps S3-R24 item 3 unchanged.
    2. **No:** terminal events stay ascending (step C3). The saving is one lookup per id. A run-to-run order would make every subscriber's sequence vary.
    3. **Yes,** as item 7 says.
    4. **The reference set has one subscriber, which may be stalled,** as the existing R-SYN-12 pin has (`BenchSync.swift:297-312`).
       - Measure the cost of a second subscriber once: `commitTurns(.waiters)` with two stalled subscribers. Record it with its figure and load.
       - This sets the reference set's subscriber count. It waives nothing (S3-R20 item 1).
       - If the two-subscriber case misses `c2Budget` at a load of 10 or less, report it as "open, for the owner", with the figure. Like S3-R23 item 3's "not measured at a quiet load", it is neither accepted nor blocking for this cycle. The orchestrator puts it to the owner before it rules the close-out converged.
    5. **Probe them,** in step 1 (S3-R19 item 1). The candidates are:
       - orphaned run claims at a verdict replayed with the barrier down;
       - `recordRunOutcome`'s `outstanding[T] = nil` (`EngineRuns.swift:519`), which wipes a claim a visit re-routed onto T;
       - variant Y's T1 half (item 7's stage 3). T1 is `analyse-state-cost.md`'s prefetch-group token, not a test;
       - `followAfterVerdict` joins at once onto a job whose own verdict waits later in the queue (`integrate-c21.md:157`).

       Each probe is a deterministic test in both orders that asserts visit-first's answers.
       - A probe that breaks S3-R16 item 1 is blocking, and P3 applies.
       - Otherwise the probe stays only if it asserts answers (G4), and the candidate is recorded with it as evidence.
    6. **`integrate-rr21.md`'s rulings 1–7** (the judge's open questions) are decided as it recommends, with one condition on every timing class below: it holds only while the event lands between the two engines' answers (S3-R24 item 5). A probe that shows a different answer with the event before both answers, or after both, is blocking.
       1. *A cancel or a release between the owing instant and the replay* of a T21 or present pair gives `.cancelled`. This is timing (S3-R16 item 2).
          - A heal scheduled meanwhile, which the T21 replay forgets, is the same class.
          - `PROBE-RR21-HEAL-T21` compares the healed system interest's outcome with visit-first's, in both orders. Run it with the heal between the owing instant and the replay, again with the heal before the site, and again after the replay.
          - It is blocking if the outcomes differ with the heal before both answers or after both, or if a SPEC MUST on heals breaks (S3-R16 1(b)).
       2. *The global hold's delays* are timing. So is an apply during the hold that drops a held job's ids. There is no hold per target.
       3. *A pin whose job committed, was superseded or was re-queued by ENOENT* (rr21-T8b) between the apply and the replay follows the copy at the replay. There is no layer per commit.
          - With no apply between that end and the replay, this equals the reference. rr21-T8 and rr21-T8b pin it.
          - With one, the reference had re-routed the pair at that end. If the pair's new target is publishing at the later apply, the reference passes the pair, as in RR-14, and that apply lands before both answers.
          - Probe that shape, `PROBE-RR21-PIN-END`, in both orders, after site 1 lands (rr21-C3) and again after site 3 lands (rr21-C5). A different answer is blocking (S3-R21 item 4). The fix then starts from the judge's "layer per commit" (`judge-rr21.md`, open questions): the smallest change that makes the probe's answers equal visit-first's, with its tests, clauses and branches, recorded.
          - If the probe holds, record it as timing, with the probe.
       4. *`replayJoin`'s RR-14-class gap* (`EngineFollow.swift:704-707`) is probed twice: in step 1 in `sweepFollowsFirst`, and at rr21-C4 in both orders.
          - The step-1 probe is evidence. If it breaks, record its failing line, and run it again at rr21-C4.
          - R18 needs R10, R11 and the layers, so it lands no earlier than rr21-C4.
          - If the rr21-C4 run breaks S3-R16 item 1 in either order, the gap is blocking (S3-R21 item 4). Commit the probe as a failing test on its own, then land R18 with RR21-HOP's join variant.
          - If the rr21-C4 run holds in both orders, the gap is a residual risk with both results as evidence, and no `.join` layer is built (G4).
       5. *Present is decided at the replay.*
          - Keeping owed pairs' bindings through the site's own `reconcileIdle` is a blocking fix (RR21-PRESENT-PRUNE).
          - Use the broad guard (`eventsAfterFollow` is not empty) and the `hasWork` disjunct. Fall back to `reroutesWaiting > 0` only if an existing test changes path through these two guards, and record why. Where it is taken, it replaces item 1's "While any event waits" sentence and `integrate-rr21.md:585` with D2's "while `reroutesWaiting > 0`"; record it.
          - A purge's `dropBindings`, an eviction or a quarantine between the owing instant and the replay is timing. So is the broad guard's later prune.
       6. *The figures that decide the contingencies:*
          - `movedBeforeDrainWaitersTurns`, all held and half held, decides site 2's chunking. If it misses, build the chunking as `judge-rr21.md`'s open questions sketch it: the take-off runs over drain turns before the verdict, and the verdict replays behind it in the same batch. Site 2 still decides before its verdict whether it owes. Add the chunking's branches to the branches table. Each gets a test that meets item 12's answer 1. Pin it twice (S3-R23 item 3), and record the design.
          - `commitRerouteWaitersTurns` (at least 511 joins behind the event) and `commitWaitersBoundTurns` are Phase 2 triggers (item 4).
          - A miss with 10,000 user waiters all bound belongs to item 4, not to a fourth RR-21 site.
       7. *A `.spaceFailure` verdict is identified by `VerdictKey`,* like `.attemptFailed`, whether or not `verdictsAfterFollow` holds it. It is live while `waitingTarget(t, epoch:)` holds.
    7. **`integrate-rr21.md`'s own nine questions are accepted as it recommends:**
       - the `reroutesWaiting` counter, with its clause;
       - the fit charge;
       - site 2's decision before its visit;
       - the `checkRunSettled` counter guard, a blocking fix, with RR21-RUN-MIDDRAIN red first as item 11 defines it;
       - the take-off's ascending sort of wholly held tokens;
       - the purge arm that removes items and sorts the removed subset;
       - `indirect`, unless the stride is unchanged without it;
       - an id taken whole;
       - the `.join` layers only after a broken probe.

       Two riders:
       - The reservation changes the order at or below the bound. That is the cycle-19 bounded-visit class. Run `PROBE-RR21-RESERVE-REJOIN` in both orders at rr21-C6 and record its results. It is blocking only if they break S3-R16 item 1 in either order.
       - Every sort that `integrate-rr21.md`'s must_not allows still needs its BenchSync figure.
    8. **`waitingTarget`'s two callers** (the judge's OQ8).
       - Item 5's test reaches the case through the `InboundMove` caller, and rr21-T8b reaches it through the pin caller. Both kill the fold mutant 2/2.
       - Item 5's test meets answer 1 only if no caller reaches the arm in `followVisitedFirst`. If rr21-T8b does, the arm keeps S3-R24 item 3 unchanged, and rr21-T8b's 2/2 kill in both orders makes it Reached, for item 5 too. Record which held. Otherwise item 5's "Reached" needs only item 5's test, and rr21-T8b belongs to item 1.
       - If item 5's fallback (probe (i) or (ii)) leaves item 5 with no test on the case, rr21-T8b's 2/2 kill of the fold mutant counts for item 5's "Reached" too. Record that in the draft.
    9. **Inventory rows outside RR-21** (the judge's OQ9) go with their owners:
       - `move`'s sort with item 3's `moveItems`;
       - `deferBehindVerdict` with item 2's A5;
       - `deliver`'s group copy with item 4's C5.

## Orchestrator ruling added 2026-11-05 20:00 (the cycle-21 fixer's put-backs; written while the cycle-21 verifiers run, before the cycle-22 fixer starts)

Run 8's cycle-21 fixer returned at 17:54. It reported six blocking items and three put-backs, all listed in the draft's "Open at the close (cycle 21; blocking, reported)". The cycle-21 verifiers judge by S3-R26. Cycle 22 runs as run 9, and its fixer and verifiers read this ruling.

**S3-R27.** Cycle 21 implemented S3-R26 (`8e1fb24..d5b2ab9`, 73 commits; the last code commit is `e599ae1`): items A, B and C, RR-21, and item 5 with its probes. Its close left six blocking items and three put-backs, and this ruling routes them.

**From cycle 22 on, S3-R27 is the cycle's ruling.** S3-R16 to S3-R26 still apply wherever S3-R27 does not change them. Where S3-R27 differs from an earlier ruling, from a specification or from an analysis, S3-R27 decides. The cycle-22 verifiers judge by S3-R16 to S3-R27.

Where to find things:
- **The cycle-21 verifiers' findings** are in run 9's findings file, `.build-orchestrator/s3f-c21-issues.json`. They are cited as "correct #n" and "reqs #n".
  - Fix them in S3-R1's order: blocking first.
  - A verifier finding is **named** by this ruling when it reports the same case, mutant or `path:line` (at `d5b2ab9`) as an item here.
    - The fixer records the mapping ("correct #n → item k") in the draft's cycle-22 status list.
    - A named finding is closed by its item's route and decision rule, even where the finding proposes another fix.
  - A blocking finding that this ruling does not name follows S3-R16 and the general rulings.
- **The read-only analyses made for this ruling**, in `.build-orchestrator/s3f-c21-analysis/`:
  - `d1-stalled-subscriber.md`, with its review `d1-stalled-subscriber-review.md` (item 1);
  - `d2-present-members.md`, with `d2-present-members-review.md` (item 3);
  - `d3-many-holders.md` (items 2 and 4);
  - `d4-survivors.md`, with `d4-survivors-review.md` (items 5 and 6);
  - `d5-held-readers.md` (item 7).

  How to read them:
  - Each review corrects its report. Where a review and its report differ, the review wins. Where either differs from this ruling, the ruling wins.
  - **What in a review binds.** A review's must-fix items bind, as this ruling corrects them. Its should-fix items bind only where this ruling names them, as this ruling corrects them:
    - d1 review: should-fix 2, 3, 4, 5, 7, 8 and 9, and should-fix 6 where c6 is taken;
    - d2 review: should-fix 2, 3, 4, 5, 7 and 8;
    - d4 review: should-fix 1 to 5.

    A review's "What the ruling must add", a report's recommendation, every other should-fix item and every "optional" in a report bind only as this ruling carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.
  - Their line numbers are at `d5b2ab9`; re-cite them after a change.
  - Their figures are estimates from code reading and the draft's measurements, not measurements. A measurement decides.
- **Cycle 21's scratch evidence:** the close's probes in `.worktrees/s3f/.build-s3f/c21/apm/` (`ProbeC21APM.swift`, `ProbeC21Holders.swift`), and the mutation tools in `.build-s3f/c21/tools/`. Do not delete `.build-s3f/c21/`.

**How a C2 figure is read in cycle 22.** This applies to every case in items 1 to 4 and 8, and to every case that item 9 re-measures.
- **The bar** is `c2Budget`, 10 ms (S3-R5). 8.5 ms is never a gate.
- **The figure** is the one the case asserts: for a BenchSync case, its heartbeat (longest wait), best of 3; for an in-actor pin (PIN-APM, PIN-APM-SPARE), its in-actor time, best of 3. Where both exist, the other is recorded beside it. A case that asserts both (for example `commitRerouteTurns`' heartbeat and held turns, `BenchSyncReroutes.swift:110-128`) misses when either misses.
- **The load** is the 1-minute load read just before the case's first timed run and just after its last. Both are recorded, with the three load averages (S3-R23 item 1). "At a load of 10 or less" means both readings are 10 or less.
- **A miss** is a best of 3 above `c2Budget` at a load of 10 or less, in any run of that case on the HEAD being judged: the fixer's gate run, a re-run alone, or a verifier's run.
  - A passing run does not cancel a miss.
  - A case that misses in one such run and passes in another is reported as a miss, with both figures. This follows S3-R26 item 4's commit window and cycle 21's `purgeWhileOwedTurns`.
- **A miss seen only at a load above 10** follows S3-R23 items 2 and 3. If no run reaches a load of 10 or less, the case is "not measured at a quiet load".
- **8.5 ms** is read on the same figure, under the same load rule. It decides only the routes this ruling makes conditional on it, and the margin list (item 9). Such a route is decided on the fixer's figure at the point the route names (item 10's rule applies where no quiet load is reached). A verifier's figure on the other side of 8.5 ms goes to the margin list and is not blocking.
- **No work is hidden from a measurement.** A case or pin times the whole of the work it names. What a pin leaves out of the turn is listed in the draft beside its figure.

1. *`commitTurns(.waitersStalledSubscriber)`* (open item 1). Blocking (S3-R16 1(f)): best of 3 was 10.31, 10.45 and 11.09 ms, each at a quiet load.
   - **Route: d1's route (a) with c3, in one step.** Take c1 (`removeJob`'s walk of the smaller side) only if `commitTurns(.waitersStalledSubscriber)`'s heartbeat, best of 3, is still above 8.5 ms after that step. The step's parts:
     - a1: one hash per terminal publish;
     - a2: one reservation per subscriber per batch;
     - a3: one publish path, `publishAll` and `broadcastAll`;
     - c3: `allBound` in `publishTerminal`.
   - **a2 has a guard** (d1 review M1). `publishAll` reserves `slots.count + n` only when `slots.count + n > 2 × slots.capacity`; otherwise it reserves nothing.
     - The guard's drop-mutant is Equivalent (S3-R19 item 2).
     - Never reserve `order` per commit.
     - This rules `reserveCapacity` for `waitersStalledSubscriber` as well (d1 review should-fix 5). S3-R26 item 4 ruled it for `groupStalledSubscriber` only.
   - **Exclusivity** (d1 review, should-fix 2):
     - `generation` is captured into a local before the access to `state.subscribers`;
     - the ids are filtered once, into an array (`announced`), before that access;
     - the events passed to `broadcastAll` may be a lazy `map` over that array (d1 §3, a3); no lazy `filter` is passed;
     - nothing inside the access reads `self.state`.
   - **Tests and kills** (S3-R16 1(e); d1 review, "The branches, and how each is killed"):

     | Branch | Kill |
     |---|---|
     | a1's compound `if` | T-A-1: both flips of `replaced`, and dropping `isProgress`, each 2/2 |
     | a2's reserve and its guard | Equivalent (S3-R19 item 2), with the argument in the draft |
     | `publishAll`'s hand-off `if let` | T-A-2, which asserts the hand-off directly, inside `withCheckedContinuation` (d1 review should-fix 9), 2/2 |
     | `coalesced ? 1 : 0` | T-A-3: a commit of 3 ids with one waiting and one stalled subscriber, 2/2 in both orders. One id is already live in the stalled queue before the commit (d1 review should-fix 3). It asserts d1 §3's four checks |
     | c3's `allBound` | Forced to `true`: killed by T-ORDER (`EngineCommitWindowTests.swift:18-79`), 2/2 in `sweepFollowsFirst`, under S3-R26 answer 1. The draft cites why `followVisitedFirst` cannot reach the state: its visit removed zz-o5 from `job.assets` before the commit (d1 review, Settled 3). Dropped ("always look up"): Equivalent |
     | c1's two arms, if taken | T-C1-1, with another job's `.transfer` key and a `.run` key in `lastEmitted`, and T-PG4, which already reaches the `lastEmitted` arm, each 2/2. The arm choice is Equivalent (d1 review should-fix 8) |

     If c1 is taken, it is an inventory row (item 9) with a BenchSync figure: many live progress keys and many job removals in one turn. If no such case can be built, the draft records why.
   - **A scratch probe first** (d1 §4 item 3, "Measure first"; the controls are d1 review, should-fix 7). Time 10,000 distinct terminal publishes into a fresh `SubscriberQueue` under four variants: today's `publish`, a1, a1 with a2, and `publishAll`. Also time the re-announcement shape, and ids over 15 bytes. Record the results: they are evidence, not a gate. The probe is part of item 10's step 0.
   - **Figures.** Take these on `d5b2ab9` (step 0), after the step, and after c1 if it is taken:
     - `commitTurns(.waiters)`, `(.waitersStalledSubscriber)`, `(.groupStalledSubscriber)` and `(.manyGroups)`;
     - `commitTwoStalledSubscribersTurns`.

     Each is best of 3, heartbeat and in-actor turn, with loads. In this item, "the per-step figures" means these figures together with the scratch probe's four variants.
   - **Two new cases, gated as C2.** Each is a committed BenchSync case that asserts `c2Budget`: gated, not only recorded as d1 review M1 and M3 have them. The gate is the heartbeat, best of 3; the in-actor turn is recorded. A miss is blocking (S3-R16 1(f)).
     - The re-announcement shape (d1 review M1): `waitersStalledSubscriber`, with the stalled queue already holding all 10,000 ids from an earlier commit.
     - The `.failed` arm (d1 review M3): 10,000 user waiters on one job that fails at `.userInitiated`, by a 404 that `resolveAll(.failed)` resolves, with one stalled subscriber. The arm keeps `job.assets.sorted()` (S3-R26 answer 2).
   - **Decision rule** (d1 review M2), on `commitTurns(.waitersStalledSubscriber)`'s heartbeat, best of 3:
     - At or below 8.5 ms closes item 1.
     - Between 8.5 and 10 ms is recorded "at the edge", with its loads. It is not blocking, and it does not start route (b).
     - Only a miss is blocking. Report it with the per-step figures.
     - The two new cases are judged on their own, as above.
     - This ruling does not authorise route (b), owing the terminal events past the commit's turn: it would reverse `integrate-c21.md:447`, and it needs a new ruling.
   - **The two-subscriber figure** stays "open, for the owner" (S3-R26 answer 4), whatever it measures. Re-measure `commitTwoStalledSubscribersTurns` after the step, and record it with its loads. It is neither accepted nor blocking in cycle 22, and a pass does not close it: the owner sizes the subscriber count.
   - **Optional margin: c6.** `guard !keys.isEmpty else { return }` at the top of `publishTerminal`, after its `lane` guard and the `keys` sort (`EngineJobs.swift:796-799`), before the filter, so that neither arm filters or broadcasts when no subscriber exists (d1 §3; d1 review should-fix 6). It is Equivalent. Add it only if `commitTurns(.manyGroups)` is above 8.5 ms after the step.
   - **Records** (d1 review should-fix 4):
     - propose (S3-R6) an ARCHITECTURE §4.3 note: c3 relies on WP-B's contract that the store's `locations` keys are a subset of the binding;
     - name that dependency in `publishTerminal`'s doc comment.

2. *`purgeWhileOwedTurns`* (open item 2). Blocking (S3-R24 item 2): 10.04 ms best in one gate run.
   - **Route: the fixer's own, in order, each part its own commit.** After each part, re-measure `purgeWhileOwedTurns` and PROBE-C21-PURGE-PARTS, best of 3, with loads.
     1. In `withdrawPurgedJoins`' owed-batch arm, read the purge's request before the copy lookup, so that a purge of `.all` makes no lookup. That saves about 1 ms. The early return's drop-mutant changes only cost: Equivalent (S3-R19 item 2; d4 §3.3). b23's kill tests purge a `.scope`, so they stay valid.
     2. Only if `purgeWhileOwedTurns` is still above 8.5 ms after (1): mutate the owed batch in place, with no copy of its items.
   - **Decision rule** (as item 1's):
     - at or below 8.5 ms closes the item;
     - 8.5 to 10 ms is recorded "at the edge", and is not blocking;
     - a miss is blocking, reported with the parts' figures.
   - **The jobs' side has no figure.** `withdrawPurged` with 10,000 one-member prefetch groups on one id is estimated at 17–33 ms, and the same O(pairs) holds for 10,000 one-member groups on 10,000 ids (d3 §2(c) row 14; UNCONFIRMED).
     - Add two BenchSync cases for a purge of `.all` over 10,000 distinct ids, each id with its own content and job: (i) one prefetch group of 10,000 members; (ii) 10,000 one-member prefetch groups.
     - Each case's figure is its heartbeat, best of 3, with loads, as "How a C2 figure is read" says; the purge's synchronous turn is recorded beside it. A miss is blocking (S3-R16 1(f)).
     - The same purge over one id held by 10,000 groups (row 14's shape) is outside the per-id dimension (item 4). It is measured once and recorded for the owner.
   - **The jobs' side's route is branch-free.** Use one `groups` access per member with no `Group` copy, and one jobs access per job.
     - Where it needs `Group.dropMember` (d2's A3 and A3′), item 2 lands A3 and A3′ in its own step, with d2 review M1's obligation for the pending check (item 3). Item 3 then reuses them.
     - A miss that stays is reported with its parts' figures, and it stays blocking.

3. *`answerPresentMembers`' answer turn* (open item 5, PROBE-C21-APM). Blocking (S3-R16 1(f)): 10.79, 12.76 and 14.17 ms best for the three shapes.
   - **Route: d2's route (a) and B1, as one step (item 10, step 5), corrected by d2's review.** Route (a) is A1, A2, A3 with A3′, A4, A5, A6a, A6b and A8.
   - **Sub-steps.** The step is committed in d2 review §4 item 3's sub-steps 1 to 11.
     - The behaviour-free factoring of `answerSite` and of `sparePresent`'s tail lands first. PIN-APM and PIN-APM-SPARE are then committed red, on their own (item 10's red-first rules).
     - If item 2 landed A3 and A3′, sub-step 4 reuses them.
     - PIN-APM's and PIN-APM-SPARE's figures are taken after sub-step 7 and at the end.
     - A7 and the group walks (sub-steps 9 and 10) run only under their own rules below.
   - **Audit first** (d2 review should-fix 3). Before A2 and A5, audit the `waitUntil` and `awaitCondition` predicates of the answer-site suites for a state that exists only mid-turn: a partial removal, or some waiters marked but not all. Record the audit. A5 moves `notifyObservers()` to the callers, with no "quiet" flag.
   - **M1, the zero-count guards.**
     - The single-waiter path, `answerWaiterFromStore`, stays byte-identical. The batched read exists only at `answerPresentMembers`.
     - The batched read discards its spawn result. Its doc comment gives the argument: `spawn` refuses only in `.shuttingDown`, `.shutDown` and `.degraded` (`EngineLifecycle.swift:52-56`); both callers checked `isRunning` earlier in this turn (`EnginePresence.swift:277`, `EngineFailures.swift:542`); and shutdown takes every waiter in the turn it begins. No refused arm is written.
     - A4's mark is written without a guard, `self.state.waiters[row.token]?.markFromStore(at: transfer)`, and the read is collected unconditionally. A missing waiter makes its read return at `readPresentLocation`'s existing guard (`EnginePresence.swift:151`, unchanged), so A4 adds no conditional.
     - `Group.dropMember`'s nil-on-mismatch line is either reached by a test that kills its drop-mutant 2/2, or recorded as structural, with an argument and a citation.
     - Every relocated line is listed with its count on the final HEAD.
   - **M2:** B1 takes the code shape the review gives.
   - **B1's task.** B1 uses one owned task per answer site, with no batch bound and no test seam (d2 review, should-fix 2): `// REENTRANCY: RE-S36` on the loop's await, RE-S21 on the spawn closure.
     - Its test puts five waiters at the site and holds the attempt, so that no other spawn happens in the answer turn.
     - It asserts that every waiter is answered `.success` with the store's location, that `invariantViolations()` is empty, and that `state.lastTaskKey` advances by exactly one across the answer turn.
     - The drop-mutant of the read loop's call is killed 2/2.
   - **M4:** A8 extends to `failed` (`EngineFailures.swift:73`): read `job.identity` and the assets argument into locals before the reads, so that no `Job` copy is bound across `sparePresent` (`:145`, `:153`, `:193`).
   - **Mutants.** Re-run the mutants of every condition the change moves, at their new lines (d2 review, should-fix 4). Each is killed 2/2 at its new line, or given a disposition under S3-R25 item 10.
   - **Shutdown with the batched read** (d2 review, should-fix 7). A cancelled read task still runs its remaining reads, so the shutdown's join waits longer. This is timing: record it as a residual risk (S3-R16 item 2). Add no `Task.isCancelled` branch.
   - **C7.** Cite A3′'s and A6a's `Dictionary` APIs in the iOS SDK's `Swift.swiftinterface` as well as the macOS one (d2 review §1).
   - **The pins** (M3). Each is best of 3 against `c2Budget`, with 8.5 ms recorded as the edge.
     - **PIN-APM** times `unaskedIDs` and the factored `answerSite` (`EnginePresence.swift:277-292`) together, inside the actor.
       - Before timing, it sets `active.handle = nil` through a recorded state seam.
       - After timing, it asserts that `answerSite` returned true and that the job is gone with its 10,000 interests. For users, every waiter is `fromStore`; for groups, every pending is empty.
       - A run in which an assertion fails is a failed case.
       - Its shapes: group, groups, users, ensure groups (with B2), and a run row (with R1). The groups and ensure-groups shapes keep their 10,000 groups registered through the timed tail, so that `materializeEnsures`' and `pruneBoundContent`'s walks are inside the figure (d2 review M5).
       - The turn also runs `drive`'s continuation: `taskEnded` on `true`, and the `interests` walk on `false` (`EngineDispatch.swift:812`). Neither is in the pin; the draft lists them beside its figure (d2 review should-fix 5).
     - **PIN-APM-SPARE** times `sparePresent`'s tail at the 404 end, where the assets argument is the job's own set, the worse end (d2 review M4).
       - The timed span is `EngineFailures.swift:541-552`, factored into an internal function the bench calls inside the actor, together with the caller's `pump` and `reconcileIdle`.
       - Shapes: group, groups and users.
       - After timing, it asserts that the job was removed and every interest answered. For users, every waiter is `fromStore`; for groups, every pending is empty. A run in which an assertion fails is a failed case.
       - A7 and the group walks apply to its groups and users shapes exactly as to PIN-APM's.
   - **B2:** owe the ensure resumes through `owedAnswers` when the rows exceed `answersPerTurn`, with T-B3 (d2). `dropGroupMember`'s `owing` parameter defaults to `false`, so that the reroute and purge callers keep their behaviour (d2 review should-fix 8).
   - **Pre-ruled classes** (M6):
     - **A7.** At the present-answer site, the rows may follow the job table's order instead of the token order.
       - This is an accepted order (S3-R16 item 2), in the class of S3-R26 item 10's order of resumes.
       - Apply it only if groups, ensure groups or users is above 8.5 ms after (a), B1 and B2, and only after an audit of the answer-site tests for order assertions.
       - A test that depends on the order keeps the sorted order there, and the case is reported (G3).
     - **R1 is part of the route.** It lands at sub-step 11. For a run row, make one progress offer with the final count, where the per-id answers made an immediate offer and a trailing one.
       - This ruling adds R1's difference, one progress offer where there were two, to S3-R16 item 2's non-blocking list, for this site only. It changes no answer and no terminal event, and it keeps R-SYN-12. It is recorded as a residual risk.
       - Its row-kind branch is reached by a run-row answer-site test that kills its drop-mutant 2/2.
       - PIN-APM's run-row shape is gated from that sub-step on.
   - **The group walks** (M5). This applies if groups or ensure groups stays above 8.5 ms after (a), B1, B2, and A7 where A7 applies.
     - First, cut the turn's two walks over every group without a branch: `materializeEnsures`' `compactMap` and `pruneBoundContent`'s `contains`. Read only the needed fields, with no `Group` copy.
     - Only if that is not enough, add an index of the ensure groups with fetches left, with a recount clause in `invariantViolations()`. Each update's drop-mutant is killed 2/2.
   - **A miss that stays** above `c2Budget` is blocking. Report it with the per-step figures. Route (c), a bounded answer over turns (d2 §2.4), is not authorised in cycle 22.
   - **The inventory** (item 9) names both callers' tails as rows, each with its pin: `answeredFromStore`'s (PIN-APM) and `sparePresent`'s (PIN-APM-SPARE) (d2 review §4 item 1).
   - **The integrity path's first turn** (d2 review, §4 item 2) is an inventory row. It runs two `job.assets.min()` walks, two 10,000-id sorts and 10,000 inserts (`EngineFailures.swift:77`, `:80`, `:193`, `:494`, `:535`), estimated at 6.5–7.5 ms (UNCONFIRMED).
     - Give it a BenchSync figure at 10,000 ids, best of 3, with loads.
     - A miss is blocking (S3-R25 item 3). Its route is not ruled here: report it with the figure.

4. *One id held by 10,000 interests* (open item 6, PROBE-C21-HOLDERS), and the per-id dimension.
   - **Scope: the per-id dimension, sized for cycle 22,** as S3-R26 answer 4 sized the subscribers.
     - S3-R25's reference set stays 10,000 ids, however their interests are grouped. For cycle 22, its per-id dimension is sized at up to 4 interests on one id. That covers one prefetch group, many groups, one user waiter per id, and any mix with at most 4 interests on every id.
     - More than 4 interests on one id, however many ids the shape has, is "open, for the owner". That includes:
       - PROBE-C21-HOLDERS (2 ids), and any variant padded with other ids;
       - d3 §2(c) rows 1 to 8 with one hot id;
       - row 12 with k > 4;
       - row 14 on one id (item 2);
       - d3's `manyHolders*` cases.
     - Such a shape is measured once and recorded with its figure and loads. For cycle 22 it is neither accepted nor blocking.
     - The owner has been asked to size the dimension, with d3 §3's sizing proposal. The orchestrator does not rule the close-out converged before the owner answers.
     - This is not S3-R20's or S3-R21's option (c). Those shapes had 10,000 ids, inside the letter. This ruling sizes a dimension that no ruling had sized, as answer 4 did, and waives nothing (S3-R20 item 1).
     - For shapes with more than 4 interests on one id, this replaces two conditions:
       - the condition the cycle-21 fixer recorded for `integrate-c21.md` item B's residual 5 under S3-R26 item 10 ("blocking if a case with h near 10,000 misses `c2Budget` at a quiet load", `s3f.md:5645-5646`);
       - `integrate-rr21.md`'s residual "One id with k tokens costs k re-routes in one id slot" (`:622-624`), as S3-R26 item 1 made it a gate ("a probe with very many tokens per id").

       For k ≤ 4 both stay gates: `commitTwoTokensTurns` and the cases below.
   - **The in-letter shapes.** The bounds count ids, and the cost counts (id, interest) pairs (d3 §2(c)). Commit BenchSync cases, named in the draft, at 10,000 ids with k interests on every id:
     - k = 2: a user waiter and a one-member prefetch group per id;
     - k = 4: four prefetch groups over the same ids (d3's `fourGroupsFollowTurns`).

     For each, take four figures, best of 3, with loads. Each is a BenchSync case's heartbeat, as "How a C2 figure is read" says, and the turn it names is recorded beside it:
     - a follow's visit with its moves and its rest;
     - the drain's replay of an owed batch at site 1;
     - the same at site 3;
     - site 2's verdict turn with its take-off (d3 §2(c) row 7).

     'Before' figures come from step 0. The deciding figures are taken in step 6, on the HEAD after step 5, and after A1 and A2 if they are taken. A miss is blocking (S3-R16 1(f)).
   - **If any of them misses,** its route is d3's pair counting, P1–P4, in one step with its pins:
     - PAIRS-T1 to T4, each killing its mutant 2/2;
     - the PAIRS-T5 probes of the split state, in both orders. They assert answers only, and PAIRS-T5 (i) also checks the run's report counts (d3 §4 item 1). A probe that breaks S3-R16 item 1 in either order is blocking, and P3 applies;
     - the BenchSync cases d3 names. The in-letter cases (`fourGroupsFollowTurns`, the k = 2 cases, and `commitTwoTokensTurns`, re-measured) are gated. `manyHoldersMoveTurns`, `manyHoldersOwedTurns`, `manyHoldersTakeOffTurns` and `manyHoldersCommitTurns` are recorded, not gated, as `commitTwoStalledSubscribersTurns` is; their figures go to the owner.

     That step reverses, for pairs:
     - S3-R26 answer 7's "an id taken whole";
     - `integrate-rr21.md`'s Own 8, R8, R9 and D8, and R7's step (3);
     - the doc comments of `followIDsPerTurn` (`EngineMoves.swift:228-235`) and `continueMove` (`:282-294`).

     S3-R22 item 1 and S3-R25 item 1 are then read as pairs, and `integrate-rr21.md`'s residual "One id with k tokens costs k re-routes in one id slot" is closed.

     It authorises one-to-one updates of the k ≥ 2 low-budget turn-count assertions, at least `drainReroutesAnOwedIDWithAllItsTokensInOneTurn` and `barrierBoundsOneIDMovesOffAHolderPerTurn`. S3-R26 item 1's rules for such updates apply. No answer, MUST or invariant assertion changes.
   - **If all pass,** pair counting is not built in cycle 22. Record the figures. PROBE-C21-HOLDERS's figures stay recorded for the owner.
     - This departs from d3's "implement (b) whatever the owner rules" (d3 §0, §3.3). Pair counting reverses S3-R26 answer 7 and four `integrate-rr21.md` rules, and adds a branch, five mutants and five probes. Under S3-R16 item 3 it is built only on a measured in-letter miss, or on the owner's sizing.
   - **Margin.** d3's branch-free A1 (hoist `decisionNow()` into the creation branch) and A2 (format the transfer id once) may be taken, with no new branch. If taken, they land at the start of step 6, each as its own commit, before item 4's deciding figures.

5. *The twelve survivors* (open item 3). Blocking (S3-R16 1(e)). Dispose of each as d4 says, corrected by its review.
   - **Remove** r7's `atEnd` (S3-R19 item 3): its only production caller runs for a downloading job, so `atEnd` is always false.
     - Delete `EngineFailures.swift:834` and the `!atEnd` conjunct at `:840`. Replace the comment at `:829-833` with d4 review's text ("What the ruling must add" 4).
     - Rewrite the mutant texts in `.build-s3f/c21/tools/mut-c4fix.py` after the removal (`:42-44`; all three match `!atEnd`). The original of each becomes `if join.chain != nil, !here(join.asset) {`:
       - r6's mutant becomes `if join.chain != nil {`;
       - r8's mutant becomes `if !here(join.asset) {`;
       - r7's entry is retired with its branch.
     - Re-run r6 2/2 in its LANE list, on the new code (G2). r8 is killed in step 7, on its rewritten text.
   - **Kill** these, with the tests d4 gives in §3.3–§3.11 and the review's corrections:
     - b23-no-lane and b23-no-kind: two new rr21-T13 arguments, `userGroup` and `prefetchWaiters`. Under `.prefetchWaiters`, also record W3's answer and the job set after the replay (d4 review should-fix 5);
     - f7-delisted-stays: in both orders, with an apply held in flight across the read (review M4). If, with the apply held in flight, the commit takes another path than T-R1's in `followVisitedFirst`, use the fallback. The draft names the line that differs, with the run's output. A shape that runs but does not separate the mutant is not this fallback: the mutant stays open, as below. Under the fallback, kill f7 in `sweepFollowsFirst`, and record the `followVisitedFirst` half as a residual risk (S3-R16 item 2). The hold for a manifest catch-up changes no answer;
     - b22-no-waiter-owner: with the answers in review M3;
     - p7 and r5: one pin-end test, in which J's answer is `.notFound` (review M2);
     - r8: kill it with a prefetch-lane waiter's answer and the throttle at arrival (review M1);
     - vy-owed-moves-too: with the follow-up turns held (review, should-fix 3);
     - r2c;
     - b22-no-run-owner: its state arises, so the test awaits `state.run == nil` (review, should-fix 2).
   - **r2b is open** (review M5): it is not Equivalent. Kill it 2/2 in `sweepFollowsFirst` under S3-R26 answer 1, or argue in the draft that no take-off item's entry can name a later verdict's content, citing every writer of `rerouteFor` and the take-off's ids (d4 review, "What the ruling must add" 1). It stays blocking until then. Keep the `made` cache.
   - **Every kill** is a deterministic test, run in both orders, that asserts visit-first's answers.
     - Each new test's first run on unmutated code is green, in both orders, before its kill counts (d4 review, "What the ruling must add" 5).
     - A branch whose state arises only in `sweepFollowsFirst` follows S3-R26 answer 1. b22-no-waiter-owner, r8, vy and r2b are such branches.
     - Where a test does not show the difference that d4 predicts, the mutant stays open. Report it with what the test showed.
     - Never weaken a test to make it pass (G3). A kill that comes from a hang or a time limit does not count.
   - **Record `followedLane`'s lane** in the draft. It decides only the 429's retry policy (d4 §1, confirmed by its review). Record the tuning under which a wrong lane changes an answer (`shortInteractiveRetry`: `.exhausted` against `.until`; the survivor tests use it).
   - **The default-tuning case** (d4 §1; §5 item 6, UNCONFIRMED). From the third attempt, a seeded background ceiling above `interactiveMaxWait` can make another user's request fail fast where the interactive end lets it wait.
     - It is ruled S3-R16 item 2, "which lane's backoff policy applies", under S3-R26 answer 6's condition: the class holds only while the 429 lands between the two engines' answers (S3-R24 item 5).
     - Probe it once, in step 7: a seeded 429 with no Retry-After, from the third attempt, with a second user request on another job of the same origin, in both orders.
     - A caller's answer that differs from visit-first's with the 429 before both engines' answers, or after both, is 1(a): blocking, and P3 applies.
     - Otherwise it is recorded as a residual risk, with the probe and its result.

6. *The four unreached places* (open item 4). Blocking (S3-R16 1(e), S3-R25 item 10).
   - **`EngineFailures.swift:861-862` and `:868-870`** belong to b22, under item 5.
   - **`EngineShutdown.swift:178-183`, `settle`'s slice.** Give T-A3 (`EngineOwedAnswersTests.swift:190`) a `count` argument of [10, 600], and replace its literal 10 with `count`, one to one, at all three places: the setup call's `count: 10`, the setup's `#require` (`owed.left == count - 4 * turns`) and the bytes check (G3: the expectations stay as exact).
     - `@Test` takes at most two argument collections (`Testing.swiftinterface`), and T-A3 already has two (`LaneDropVisit.allCases, [0, 1]`). So `turns` and `count` are passed as one collection of pairs, all four of them; every existing (visit, turns) case still runs at count 10.
     - At count 600 it asserts `shutdownSlices == [512, 88 - 4 × turns]`: [512, 88] at `turns: 0`, and [512, 84] at `turns: 1`.
     - The setup requires that no waiter or job is left to free before the shutdown (d4 review should-fix 4).
     - Every caller gets C's bytes.
     - The drop-mutant of the `if` gives one slice, [600 − 4 × turns], and must fail every count-600 case, 2/2.
   - **`EngineFollow.swift:883`, `replayVerdict`'s second guard.** Both halves are unreachable (d4 §2, confirmed by its review), so:
     - remove `:882-884`, and replace `:876`'s last sentence with d4 review's text ("What the ruling must add" 4);
     - add an epoch clause next to the unfailed one (`EngineCommands.swift:2275`): "jobs whose failure verdict waits for a follow are at another epoch";
     - add one test with `violations(after:)`, from the `sweepFollowsFirst` state of `barrierFailsA429BeyondTheCapsAsOnArrival`. It sets the job `.queued`, then bumps its epoch, and expects each clause in turn. It kills both clauses' drop-mutants 2/2.
     - The epoch clause is an invariant clause, not a replay or deferral branch. Its test runs in `sweepFollowsFirst` only, and S3-R24 item 3's both-orders rule does not apply to it.

7. *The held-turn readers* (put-back). d5 found no racy reader in the seven listed suites or in the rest of the Sync tests. It spot-checked the fixer's own Step-8 list and did not re-derive it; the draft records that limit.
   - Replace the draft's "not audited one by one … Put to the orchestrator" (`s3f.md:6653-6655` and `:9807-9808`) with d5's classification, suite by suite.
   - Add d5's pin at `EngineFollowBarrierWaitingTargetTests.swift:191-193`: `barrier` in `afterTurn`, and a `#require` that the move's turn is not the follow's last. Run it 2/2 in both orders.
   - **If the `#require` fails,** the reading is racy: a 1(d) finding. Hold the attempts' terminals around that one turn only (`holdAttemptTerminals()` before `runOneFollowTurn` at `:190`, released after `afterTurn`), as `takeOffTurns` does (d5, "What could go wrong"), and record it.
   - Do not hold attempt terminals globally.

8. *`releaseRerouteHolds`' inventory row* (put-back). Its row (`s3f.md:4961`) is O(P log P) for P publications. Give it one of these (S3-R26 item 9):
   - **The argument.** Cite from the code a bound on P (the publications that can wait while `reroutesWaiting > 0`) that does not grow with ids or interests. The row is then O(P log P) at that bound, and is recorded with the bound.
   - **A figure.** If no such bound is cited, give a BenchSync figure: the largest P the harness can hold behind owed re-routes at 10,000 ids, best of 3, with loads. A miss is blocking (S3-R25 item 3).

9. *The fixer's own check before it returns.* S3-R26 item 9 applies again, on the final HEAD:
   - S3-R25 item 10, for every line and branch changed in `d5b2ab9..HEAD`. The cycle-21 dispositions in "Not reached and structural lines (cycle 21)" stay listed, updated where this cycle changes them;
   - the inventory: every new per-id, per-pair, per-event or per-row operation of items 1 to 4 is a row with its cost. It also gets a figure, unless it is O(1) amortised and neither this ruling nor `integrate-c21.md` or `integrate-rr21.md` names a case for it. A case that only an analysis names (d1 to d5) needs a figure only if this ruling adopts it;
   - the re-measure of every C2 case the cycle's code passes through;
   - the margin list: every case above 8.5 ms, recorded "at the edge".

10. *Order of work.* Commit each step on its own.
    - **Red first.** S3-R26 item 11's red-first rules apply, with `d5b2ab9` in place of `8e1fb24`.
      - A BenchSync case or pin that misses on `d5b2ab9` is such a test: it is committed failing, on its own, right before its fix, as `b4c215d` was.
      - A case that passes on `d5b2ab9` lands with the step that adds it.
      - A case that misses on `d5b2ab9` but passes on the HEAD where its step starts (for example item 4's cases after steps 1 to 5) lands, green, with that step. Its `d5b2ab9` figure is recorded as its 'before' figure.
    - **A deciding figure without a quiet load.** S3-R26 item 11's rule applies to every figure that decides a route in this ruling: c1 and c6 (item 1), the in-place batch (item 2), A7 and the group walks (item 3), and pair counting (item 4).
      - Decide on the best of 3 at the lowest load you get.
      - Record it as "not measured at a quiet load", with its loads.
      - The orchestrator re-measures it before close-out, and a different result reopens that decision.
    - Keep the draft's cycle-22 status list current, with the named findings' mapping, so that a resumed fixer continues from the HEAD.

    0. Run `verify.sh --quick` on `d5b2ab9`.
       - In a scratch copy of `d5b2ab9`, build every case that items 1 to 4 add, and take its 'before' figure, best of 3, with loads.
       - A case that needs a seam gets it in the scratch copy only. The seam lands later as its own behaviour-free commit (item 3's sub-steps).
       - Item 4's `manyHolders*` cases take no 'before' figure unless pair counting is triggered.
       - Item 1's scratch probe is part of this step.
    1. The verifiers' blocking findings of class S3-R16 1(a) to 1(d) (an answer, a MUST or invariant, liveness, flakiness) that this ruling does not name, each failing test first. A named finding goes with its item.
    2. Item 6's removal and settle slice, and item 5's removal and its cheap kills, in d4 review's amended order, its steps 1 to 5: r7's removal with the mutant texts and r6's re-run; `replayVerdict`'s removal with its clause and test; b23; the settle slice; f7.
    3. Item 1.
    4. Item 2, including A3 and A3′ (`Group.dropMember`) if its jobs' side needs them.
    5. Item 3, in its sub-steps.
    6. Item 4: A1 and A2 if taken, then its deciding figures, then pair counting if they trigger it.
    7. Item 5's remaining kills, in d4 review's amended order, its steps 6 to 12: b22-no-waiter-owner, p7 with r5, r8, vy, r2c, b22-no-run-owner and r2b. Then item 5's default-tuning probe. Then the verifiers' other findings.
    8. Items 7 and 8, item 5's `followedLane` record and item 1's records. Then the close: item 9, and every gate on the final HEAD.
       - Run `verify.sh --full` and quote its last line.
       - A FAIL whose only causes are P-13 (WP-B's; S3-R26 item 10) and the cases this ruling leaves "open, for the owner" is reported as such. Each of its other stages also runs and passes on its own.

    **Expect the weekly limit.** This cycle may be cut off by the weekly usage limit. That is why the C2 routes come before the long survivor work. A cut-off leaves every finished step committed.

11. *Amendments, and the findings the cycle-21 requirements verifier adds.* Where this item and items 1 to 10 differ, this item decides.
    1. **Item 4: a k = 2 or k = 4 miss that pair counting cannot cut.**
       - Such a miss is in a turn that pair counting does not change. Examples: the commit's answers, or a verdict's answers, over 40,000 interests.
       - It is blocking, has no route in this ruling, and is reported with its figures and parts (S3-R26: "A miss with no route is blocking").
       - Pair counting is built only for a miss in a turn that it bounds.
    2. **Item 4: "measured once and recorded"** is a recording rule, not a duty to build shapes.
       - The fixer records the out-of-dimension figures it takes.
       - PROBE-C21-HOLDERS's cycle-21 figures stand.
       - The `manyHolders*` cases are built only if pair counting is triggered.
    3. **Item 2: the jobs' side.** The branch-free route applies only if case (i) or case (ii) misses.
    4. **Item 3: PIN-APM's span.**
       - Drive's continuation in the same turn (`taskEnded`, when `answerSite` returns true) is part of the answer turn.
       - PIN-APM times it together with `unaskedIDs` and `answerSite`. No part of the turn is left out of the timed span.
    5. **Item 3: B1's test** names the hold it uses: the attempt at its answer site with `active.handle == nil`, set through PIN-APM's state seam.
    6. **Ownership** (reqs, "ownership (lens part 2)").
       - These six files are authorised as WP-F's: `Tests/ZTronAssetKitBenchmarks/BenchSyncCycle21.swift`, `BenchSyncJoinChains.swift`, `BenchSyncReroutePins.swift`, `BenchSyncRerouteTakeOff.swift`, `BenchSyncReroutes.swift` and `BenchSyncWaitersBound.swift`. So is any new `Tests/ZTronAssetKitBenchmarks/BenchSync*.swift` file that this cycle adds.
       - Two conditions apply. Each file holds only `ZTronAssetKitBenchmarks.SyncBenchmarks` and `SyncBench` extensions. No file edits another work package's benchmark file.
       - No code is moved.
       - The draft lists the files under "Authorised edits outside WP-F", which corrects `s3f.md:7273-7274`. It also proposes the ARCHITECTURE §1.2 addition (S3-R6).
    7. **`commitTurns(.manyGroups)`** (reqs, "C2 flake at loads of 10 or less"). Blocking (S3-R16 1(f)).
       - The figures: best 10.27 and 10.96 ms in 2 of the verifier's 4 runs at loads of 10 or less, and 9.40 in the other two.
       - A case that flaps around `c2Budget` is a miss, as S3-R26 item 4 ruled for the commit window.
       - The route is branch-free first, in this order:
         - item 1's c3 and c1;
         - item 1's c6, at the top of `publishTerminal`;
         - item 3's group-walk cut, applied to the commit's turn: no `Group` copy in the walks of `materializeEnsures` and `pruneBoundContent`.
       - These land in steps 3 and 5 of item 10. Measure after each, best of 3 with loads. Item 1's decision rule and the C2 block decide.
       - A miss that stays is blocking, and is reported with the per-step figures. Owing the group deliveries across follow-ups needs a new ruling.
    8. **The correctness verifier's findings** reach the fixer through the findings file, and follow the "named finding" rule above.

12. *The owner's ruling, and the cycle-21 correctness verifier's two new findings.* Where this item and items 1 to 11 differ, this item decides.
    - **Its analyses** are in `.build-orchestrator/s3f-c21-analysis/`: `e1-pin-requeue.md`, with its review `e1-pin-requeue-review.md` (12.2), and `e2-purge.md`, with `e2-purge-review.md` (12.3). The header's rules for reading the analyses apply to them. Below, "must add" n is a review's "What the ruling must add" n, and "must say" n is a report's "What the ruling must say" n.
    - **Names.** R1, A1, A2 and P-1 to P-3 already have meanings here: R1 is S3-R11's (S3-R16 1(a)), `integrate-rr21.md`'s and item 3's; item 3 has d2's A1 to A8, item 4 d3's A1 and A2, and `integrate-c21.md` steps A1 to A13; P-1 to P-3 are SPEC's benchmarks, beside P-13. So, in this item and in the draft's records, e1's and e2's labels carry their analysis: e1-R1; the probes e1-PS, e1-P1, e1-P2, e1-P3 and e1-PR; e2-A1 (e2-A1.1 to e2-A1.7), e2-A2 (e2-A2.1 to e2-A2.6) and e2-B. T-E1 to T-E5 and T-A-SCOPE keep their names. Unprefixed R1, An and P-n keep their earlier meanings.
    - **What in e1's and e2's reviews binds,** extending the header's rule: their must-fix items bind, as this item corrects them. Their should-fix items bind only where this item names them. A report's recommendation, and a review's "must add" items, bind only as this item carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.

    1. **The owner's ruling (5 Nov, 21:15).** To "Should the 10 ms bar cover only 10,000 assets with one subscriber?", the owner answered "Yes, keep it" (`docs/ORCHESTRATION.md`).
       - **The bar,** `c2Budget` at 10 ms, covers only the reference set: 10,000 ids however their interests are grouped, with at most 4 interests on one id as item 4 sizes it, and one subscriber, which may be stalled (S3-R26 answer 4).
       - **Outside the bar:**
         - every shape with more than 4 interests on one id. It includes item 4's list: PROBE-C21-HOLDERS and its padded variants, the `manyHolders*` cases, row 14 on one id (item 2), d3 §2(c) rows 1 to 8 with one hot id, and row 12 with k > 4;
         - a second subscriber (`commitTwoStalledSubscribersTurns`).
       - **Such shapes are recorded** with their figures and loads, as residual risks (S3-R16 item 2), where items 1, 2 and 4 say to measure them. They are neither gated nor blocking, and a verifier does not report them as blocking.
       - **What this changes:**
         - every "open, for the owner" in items 1, 2 and 4 now reads "outside the bar, by the owner's ruling of 5 Nov";
         - item 4's condition, that the orchestrator not rule the close-out converged before the owner answers, is met;
         - item 10 step 8's FAIL rule now names P-13 only: a FAIL whose only cause is P-13 (WP-B's; S3-R26 item 10) is reported as such.
       - **Named findings:**
         - correct #5 and reqs #6 (PROBE-C21-HOLDERS): 37.21 to 45.85 ms, best of 3, across the fixer's runs (1-minute loads 6.92 to 8.33), reqs #6's (4.60 to 4.74) and correct #5's (about 6.25). They go to 12.1, recorded and not blocking. Their in-letter part, k ≤ 4, stays with item 4, gated;
         - reqs #12 (two stalled subscribers): 15.57 ms, best of 3, at a 1-minute load of 7.44. It goes to 12.1, recorded.

    2. **Correct #1: the pin after an ENOENT re-queue.** Blocking (S3-R16 1(a)), confirmed by PROBE-C21C-PIN-ENOENT-404 and by e1 §1.
       - **The break** (`.build-orchestrator/s3f-probes-c21/PROBE-C21C-PIN-ENOENT-404.log`, 2/2 per case). rr21-T8b's shape, with X's fresh attempt failing with a 404. Visit-first answers W1…W3 `.failure(.notFound)` and never requests W's content. In three of the four cases (order × owe), W1…W3 get W's 20 bytes and W is requested. V2 gets `.notFound` and K 16 bytes in every case, and no invariant breaks.
       - **The mechanism** (e1 §1). The ENOENT arm (`EngineDispatch.swift:1274-1283`) re-queues X at the same epoch and keeps no record. `waitingTarget(_:epoch:)` returns nil for `.queued` (`EngineFollow.swift:1581-1582`), so the pin check returns nil (`:806-808`), and both callers, `rerouteListing` and `joinListing`, follow the engine's copy. Answer 6.3's premise, that the reference re-routed the pair at that end, is false for an ENOENT re-queue: visit-first's pair rode X's fresh attempt.
       - **Route: e1-R1** (e1 §2), as e1 review "must add" 1 states it. While events wait, the ENOENT arm keeps (X, epoch) with `copySerial`, marked as a re-queue. At the pin, with no layer after that serial, the walk returns the pin layer's outgoing copy. Otherwise it takes the copy that the first layer after the re-queue adopted (index `end.serial - serial + 1`, or the engine's copy), and walks on.
         - e1-R1 reads no job state. It reuses the record's clears (`endWorldHistory`, `EngineFollow.swift:372`; shutdown, `EngineShutdown.swift:130`) and its three clauses (`EngineCommands.swift:2239-2250`).
         - The verifier's fix step 3 (the entry handed to the copy at the re-queue) is rejected as written, and so is a walk-on keyed on X's state (e1 §2; the last row of e1 §4's kill table). The verifier's step 1 becomes T-E1, and its step 4 becomes rr21-T8b's change below.
       - **The record's form: a flag on `reroutePinCommits`' value** (e1 review must-fix 4, "must add" 2). Its duties:
         - `committed`'s write (`EngineDispatch.swift:1133`) records a commit (`keepsEntry: false`);
         - the "ahead" clause (`EngineCommands.swift:2247`) reads the value's serial;
         - `invariantsReportCommitsKeptForOwedReroutes` (`EngineFollowBarrierReroutePinEndTests.swift:263-278`) writes and compares raw `UInt64`s and expects the clauses' "commits kept" messages. It changes one to one, as exact as before, in e1-R1's commit, where the value's type changes, and the draft records the old and new text, the messages included if they are renamed. This item authorises that change, as an exception to S3-R26 item 1's "Answer, MUST and invariant assertions never change" (rulings :462);
         - the `keepsEntry` literal's mutant is killed (the table below).

         A sibling map is allowed only if the flag form cannot hold. It then needs its own clears and its own clauses, each with its kill, and the draft records the reason.
       - **The tests,** in `EngineFollowBarrierRerouteRequeueTests.swift`, from rr21-T8b's fixture, owing, in both orders, unless a row says otherwise (e1 §4; T-E5 is e1 review must-fix 1):

         | Test | Shape | Visit-first's answers | On `d5b2ab9` |
         |---|---|---|---|
         | T-E1 | the probe's, with `arguments: LaneDropVisit.allCases, [false, true]` (order × owe) | W1…W3 and V2 `.notFound`, K 16 bytes; after the replay X holds zz-a1…zz-a3 and zz-x; W never requested; no violation | red in 3 of 4 cases (the verifier's probe) |
         | T-E2 | K1 drops zz-a1…zz-a3 while X publishes; X's ENOENT; K2 lists them at U; X's fresh attempt fails with a 404 | W1…W3 U's bytes, V2 `.notFound` | green (code reading) |
         | T-E3 | K1 as in rr21-T8b; after the re-queue, K2 drops the pair and K3 lists it at U | W1…W3 `.notFound`; U never requested | red (code reading) |
         | T-E4 | T-E3, with K2 also mapping zz-x to Y, so that X is superseded | W1…W3 `.notFound`, V2 Y's bytes | red (code reading) |
         | T-E5 | after the re-queue, K2 lists the pair at U (no job of U at an end) and K3 at Z | W1…W3 Z's outcome | green (code reading) |

         - **Serving** (e1 review must-fix 6, "must add" 4). Every T-E test serves each content a mutant can request (W, U, Z), only if its job exists, and asserts which contents were requested. A mutant then fails on an answer, not on a time limit.
         - Each test is green in both orders on the fix before any kill counts.
       - **rr21-T8b changes one to one** (e1 "must say" 5; e1 §2, step 4). It lands in e1-R1's commit, since its old `:124` is red under e1-R1:
         - `:124` becomes `replayed.x == (ids + [xID]).sorted() && replayed.w.isEmpty`: X holds zz-a1…zz-a3 and zz-x, and W has no job;
         - the loop at `:127` delivers X before W, since W's job now appears only at X's commit;
         - its display and function names (`:25-26`) and its docs (`:8-23`) say that the pin holds. The answers at `:142` stay.

         The draft records old and new. No `MIGRATION.md` entry is needed: it is cycle 21's own test.
       - **The kills** (e1 review "must add" 3; e1 §4, corrected by must-fix 1 to 3). Each is 2/2 in each order that can reach its branch, after a green first run of the unmutated code in both orders. A kill is by an answer or a clause, never by a hang or a time limit (item 5).

         | Branch | Mutant | Killed by |
         |---|---|---|
         | the ENOENT arm's write | dropped | T-E1 |
         | the write's `!eventsAfterFollow.isEmpty` | forced true | `enoentAfterCancelIsTheCancellation` (`EngineRaceTests.swift:82-122`), strengthened with an `invariantViolations()` check after the fresh attempt and recorded, or a new barrier-down ENOENT test. Without a follow the orders are moot, and the draft says so (must-fix 2) |
         | `end.keepsEntry` | dropped (read as a commit) | T-E1 and T-E2 |
         | `next < layers.count` | forced true (always jump) | T-E1 |
         | `next < layers.count` | forced false (always keep) | T-E2 |
         | `index = next + 1` | `index = next` (the verifier's step 3) | T-E2 |
         | `index = next + 1` | `return nil` (`d5b2ab9`'s answer) | T-E3 and T-E4 |
         | the walk on, after the jump | no walk-on: the jump's copy is returned (p5's form) | T-E5 |
         | the record decides, not X's state | a walk-on keyed on X's state | T-E4 |
         | `committed`'s `keepsEntry` literal | read as a re-queue | killed; e1's review expects p4's killers (draft `:6309`) to kill it, unverified. If they do not kill it 2/2 in each order that reaches it, a PIN-END test that does is added |
         | `i5-pin-fold` (re-run) | `.queued` returns the job in `waitingTarget(_:epoch:)` | T-E2, moved from rr21-T8b. The run decides which tests kill it in each order, and the draft records the killing line per order |

       - **The probes** (e1 §3 and §7, step 4; e1-PR is added here). Each asserts visit-first's answers, and runs in every order that can reach it. e1 §3 gives the shapes:
         - **e1-PS:** X's own publication superseded, then a later apply: (i) K2, mapping the pair to U, adopted while J publishes, then J's terminal failure; (ii) K2 drops the pair and K3 re-lists it at U. Owing, both orders. Visit-first: (i) J's integrity failure, (ii) `.notFound`. Route if red: the commit-shaped record (`keepsEntry: false`) at the `.superseded` arm (`EngineDispatch.swift:1261-1268`);
         - **e1-P1 and e1-P2:** a T20 re-queue during an ENOSPC free-space read, from the drain's replay of a user join (e1-P1) and from `followAfterVerdict`'s joins (e1-P2). Both orders. Visit-first: for e1-P1, `insufficientSpace` for the pair and for V2, with X requested once; for e1-P2, X's ENOSPC verdict answers Y's id. Route if red: `relane`'s guard (`EngineJobs.swift:307`);
         - **e1-P3:** a park at the same epoch while the barrier holds: Shape A and rr21-T8b, with a conditions edge or a space sweep replayed between the re-queue and the move or the replay. Both orders. It records X's state at the move and at the replay, with no `#require`, and runs on to the answers. Visit-first: the id rides X. A `.blocked` state with visit-first's answers is recorded as the move's own finding: e1-R1 makes the state moot for the pin, but the move's `.queued` arm still depends on it (e1 §3). If kept as a test, it asserts visit-first's answers;
         - **e1-PR:** the untraced removal edge in e1 §3's table: X dropped by a removal replayed before the batch, with no apply since the re-queue. `sweepFollowsFirst` only. e1-R1 is expected to join a new job of X's content, so that the answers equal visit-first's (UNCONFIRMED).

         A different answer from visit-first's is blocking. A probe is red when it breaks S3-R16 item 1 in an order that reaches it: a different answer, a broken MUST or invariant, or a hang (S3-R26 items 7 and 11). Its other observations, such as a request count or a job's state, are recorded with it.
         - A red probe with a route given here is fixed in cycle 22: its failing test first, then the smallest change that makes the answers equal visit-first's, with its branches killed and the design recorded.
         - A red probe with no route given here (e1-P3, e1-PR) stays out of the suite, as scratch evidence, and is reported as blocking with its probe and its log.
         - A probe that holds is recorded with its result (S3-R26 item 11).
       - **Amendments** (e1 review "must add" 5). Visit-first re-routes only at a commit or a supersede, so an ENOENT re-queue keeps the pin:
         - S3-R26 answer 6.3: its header's class is now a pin whose job committed or was superseded, and the ENOENT re-queue and rr21-T8b leave it. Its first and second bullets hold for those two ends, and the first's "rr21-T8 and rr21-T8b pin it" reads "rr21-T8 pins it" (the commit pin, `integrate-rr21.md:403-406`). After an ENOENT re-queue the reference re-routed nothing at that end (D-13). With no apply since, the pair rides X's fresh attempt (T-E1, rr21-T8b). With one or more, the first visit after the re-queue moved it under the copy that visit's apply adopted, and later visits moved it on (T-E2 to T-E5);
         - S3-R26 item 1's "A pin holds only while `waitingTarget(transfer, epoch:)` holds" (rulings :441) now reads: a pin holds while `waitingTarget(transfer, epoch:)` holds, and, after an ENOENT re-queue at that epoch, until the first copy adopted after the re-queue;
         - `integrate-rr21.md`'s D6 (`:316-318`) and its residual (`:597`) lose the ENOENT re-queue, and its must_not on the `waitingTarget` window (`:586`) is lifted for this fix. D6's first sentence reads as S3-R26 item 1's, amended above. Its last sentence, "No new job of a former target is created from an old copy", holds for the commit and supersede ends only (e1 §2);
         - S3-R26 answer 8: the pin caller's kill of the fold mutant is T-E2's, with the other tests the run shows killing `i5-pin-fold` in each order. Every other rr21-T8b in answer 8, the "Reached" evidence of its second and third bullets included, reads "T-E2, with those tests".

         "There is no layer per commit" stands: a kept serial is no layer. The nested ENOENT, a commit's next target re-queued by its own ENOENT, is in the class, and e1-R1's branch covers it (e1 review "must add" 7).
       - **C2** (e1 "must say" 11). No new inventory row: `followLayers` stays O(layers) an id, and the ENOENT arm gains O(1). Item 9 re-measures `applyWhileOwedLayers`, `lane429WhileOwed` and `joinChainTurns`. e1-R1's added cost is estimated at 0.2 ms or less a drain turn.
       - **Records** (e1 "must say" 10):
         - the doc comments at `EngineFollow.swift:765-773` and `:1561`, whose "An owed re-route's pin keeps the end's own window" is now false; at `EngineState.swift:217-221`; and on the ENOENT arm (`EngineDispatch.swift:1275-1278`);
         - the draft at `s3f.md:5695-5700` (rr21-T8b); `:5821-5824` (the residual, and the wrong "The records go when the last batch is replayed whole": they go at `endWorldHistory` and at shutdown); `:6563-6566` and `:6601-6607` (the fold's kill, and the first UNCONFIRMED sibling, now confirmed and fixed); and `:6814-6816` (RR-21's ruling-3 residual).
       - **Fixer hours,** estimated (e1 review "must add" 8): about 6-10 h of writing and 3.7-5.5 h of mutant runs for the fix, its tests, kills and records, plus 3-5 h for the probes. A sibling's fix is not included.

    3. **Correct #2, with reqs #4: the purge's first turn.** Blocking (S3-R16 1(f)). `withdrawPurged` walks every waiting event and every job in one turn, the synchronous stretch after `ensureStarted()` (`EngineCommands.swift:968-976`). The figures are in the cases' table below (correct #2's probes in `.build-orchestrator/s3f-probes-c21/`; e2 §0, confirmed by e2's review).
       - **What it replaces:** item 2's paragraphs "The jobs' side has no figure" and "The jobs' side's route is branch-free", and item 11.3. Item 2's part (1) stands, as e2-A1.1. Its part (2) is no longer conditional: it lands in e2-A1.2.
       - **The contract** (e2 §1; e2 "must say" 2), recorded in the draft. Withdrawing every non-user interest in the purge's first turn is not a MUST (`SPEC.md:250`; `docs/ARCHITECTURE.md:300` binds only the engine's epoch). Withdrawing every waiting join, bucket join and owed item before any drain turn is binding (RR-5, PROBE-C13-PURGE-JOIN).
       - **The gated cases** (e2 review "must add" 3): eleven BenchSync cases at 10,000 ids, in 11.6's files. Each purges `.all` unless its row says otherwise.

         | Case | Today, best of 3 |
         |---|---|
         | (i) one prefetch group of 10,000 members, each id with its own content and job | 54.47 ms at a 1-minute load of 7.65, and 55.96 at 4.85 (PURGE-QUEUED) |
         | (ii) 10,000 one-member prefetch groups, each id with its own content and job | not measured |
         | (i) under a `.scope` purge | not measured |
         | the shared job at k = 1: one job of 10,000 ids | 12.20 ms at 7.65, and 12.03 at 4.85 |
         | the shared job at k = 4: four groups over its ids | estimated 43-48 ms (e2 review must-fix 10) |
         | the bucket joins: PURGE-JOINS' shape at 10,000 members | 13.04 ms with 9,216 joins behind the verdict, at 7.36 to 7.23 |
         | the queue joins: the same shape | 11.52 ms with 9,489 joins in the queue, at 7.23 to 6.88 |
         | `purgeWhileOwedTurns` (reqs #4; it exists), 10,000 owed items | 10.04 ms in the fixer's second gate run, at a 1-minute load of 4.88 (mean 5.23 over SyncBenchmarks; a miss); 9.57 to 9.83 in the verifiers' runs, at 3.39 to 7.14 |
         | k = 4 over 10,000 jobs: four prefetch groups | estimated 85-130 ms (e2 §2.4) |
         | 10,000 jobs waiting for a retry, each one that the purge removes (held only by interests it withdraws) | estimated 0.1-0.5 s: `removeJob` scans the heap once per job (`EngineJobs.swift:483`; e2 review must-fix 10) |
         | 10,000 jobs held only by user waiters | estimated 8-14 ms (e2 review must-fix 10) |

         For each case:
         - its figure is its heartbeat, best of 3, with loads, as "How a C2 figure is read" says, and the purge's synchronous turn is recorded beside it;
         - its 'before' figure is taken in step 0, in the scratch copy;
         - if it misses on `d5b2ab9`, it is committed red right before e2-A1's first part, under item 10's red-first rules.

         `purgeWhileOwedTurns` is already in the tree, so it is not committed again. Its cycle-21 figures (the table) and its step-0 figure are its 'before' figures. Its cycle-21 miss stands, and the decision rule below judges it after e2-A1 and after e2-A2.

         The purge over one id held by 10,000 groups (row 14) is outside the bar (12.1), and is recorded only.
       - **e2-A1 (e2 §3's A1.1 to A1.7), with e2 review's corrections.** Each part is its own commit.
         - e2-A1.1 (item 2's part (1)): `isPurged` reads the request before the copy lookup, in the walk, the joins and the owed arm (`EngineCommands.swift:993-1005`).
         - e2-A1.2: the owed batch (item 2's part (2)), the queue's `.join` events and each bucket are changed in place, with no copy of their items. A bucket takes one `joinsBehindVerdicts[key]` access, still newest first.
         - e2-A1.3: no sort of the dropped ids or of the removed items (`:1022`, `:1070`).
         - e2-A1.4: one jobs access per job, through a `Job` mutating method, then one `settleRemoval`. The method removes in ascending token order and returns the lanes before the first and before the last removal, as `takeOff` does (e2 review must-fix 6). Its test: a claim-held job whose `.bulk` interest is registered before its `.prefetch` interest (t1 < t2, as e2 review must-fix 6 builds it) ends with `heldLane == .prefetch`. The reversed-order mutant fails it 2/2 (e2 review "must add" 2).
         - e2-A1.5: the `.all` fast path, below.
         - e2-A1.6: A3 and A3′ (`Group.dropMember`) at `:1025`, `:1073` and `:1108`, with d2 review M1's pending check and item 3's C7 citations. Item 3's sub-step 4 then reuses them.
         - e2-A1.7: no `Job` copy in `settleRemoval` (`EngineJobs.swift:395`) or in `retire` (`:412`).
       - **Exclusivity** (e2 review must-fix 8, "must add" 1). Every step that works inside one access takes `applied` and the request into locals, marks and collects inside the access, and makes the other writes after it, in the same order, as item 1's exclusivity rule says. Every in-place access is such a step: e2-A1.2's owed batch, `.join` events and buckets, e2-A1.4's method and e2-A2.4's walk among them.
       - **The reversals** (e2 review "must add" 6). e2-A1.3 reverses `integrate-rr21.md` R15 (the owed arm's sort, `:239`) and S3-R26 answer 7's "the purge arm that removes items and sorts the removed subset".
       - **The order.** The draft records e2-A1's order arguments, corrected: the order across jobs (the sorted keys) and within a job (ascending tokens) is kept. Two things change: the order of the dropped ids and of the removed items, and, with e2-A1.4's one `settleRemoval` per job, the number of `notifyObservers` calls inside the turn (`EngineJobs.swift:406`; e2 §3, "Equality with today"). The purge never withdraws an `.ensure` interest, so no drop resumes anything (e2-A1.3; e2 review, "What holds").
       - **e2-A1's one branch, the `.all` fast path (e2-A1.5):** `withdrawn = interest.assets`, with no filter and no intersection. This item authorises it, amending item 2's and item 11.3's "branch-free" (e2 review must-fix 7).
         - Always taken: killed by T-A-SCOPE, 2/2 in each order that reaches it. T-A-SCOPE purges a `.scope` of one of two ids that share a content held by a prefetch group. The other member stays pending and keeps its interest (e2 §3).
         - Never taken: Equivalent, cost only (S3-R19 item 2).
       - **e2-A1's other kills** are e2 §3's table:
         - `isPurged`'s early read: drop-mutant Equivalent (item 2's part (1));
         - the method's whole arm: `purgeDropsGroupMembers` (`EngineRegressionRound2Tests.swift:282`); its partial arm: T-A-SCOPE;
         - the moved lane and kind conditions, b23's among them: re-run at their new lines (item 3's rule);
         - `Group.dropMember`'s nil line: item 3's M1.
       - **e2-A2 (e2 §3's A2.1 to A2.6),** authorised only if a purge case is above 8.5 ms after e2-A1. Each part is its own commit. With e2 review's corrections ("must add" 4):
         - e2-A2.1: `removeJob` touches an index only when it is not empty;
         - e2-A2.2: `storedCount` becomes a counter in `LaneQueues`, with a recount clause, and the queues are compacted once, after the walk;
         - e2-A2.3: the retired jobs are freed later. Either the freeing slice is pinned, with recorded slices and a drop-mutant that fails 2/2, as item 6 pins `settle`'s, or the freeing runs unsliced in one later turn, with its figure and a REENTRANCY row;
         - e2-A2.4, the table-order walk, comes only after the purge suites' order audit (item 3's A7 rule), in two passes, with the iOS SDK's `Swift.swiftinterface` cited (C7). Otherwise the key sort stays;
         - e2-A2.5: one heap pass for the retired jobs' `.retry` entries (`DeadlineHeap.swift:79-81`);
         - e2-A2.6 is dropped unless A5's audit (item 3) is done first.
       - **e2-A2's kills** are e2 §3's table, with e2 review's corrections:
         - the empty-index guards: drop-mutants Equivalent (S3-R19 item 2); each negation killed by its index's clause, which the fixer lists per index, adding one where an index has none;
         - the queue counter: each update's drop-mutant fails the recount clause;
         - e2-A2.3's freeing slice is not Equivalent (e2 review must-fix 9): it is pinned as above;
         - the heap pass: the retry case asserts that no `.retry` entry is left.
       - **The decision rule** is item 1's: at or below 8.5 ms closes a case; 8.5 to 10 ms is recorded "at the edge" and is not blocking; a miss is blocking. Measure every purge case after e2-A1, and after e2-A2. A miss after e2-A2, or after e2-A1 when e2-A2 is not triggered, is blocking with no route in cycle 22. Report it with its parts' figures and loads.
       - **Route e2-B, slices over owned follow-up turns (e2 §4), is not authorised in cycle 22** (e2 review "must add" 5). The fixer does not build it. The orchestrator will have e2-B re-specified with e2 review's corrections, and reviewed, for a later ruling:
         - visit on touch, claims included, with its cost counted in the touching turn;
         - member drops in the slices;
         - a bound on both the jobs and the pairs visited, with a job split by interest;
         - a mark per walk, and no "unmarked" clause;
         - shutdown and cancel behaviour stated against today's.

         e2 review must-fix 1 to 5, 11 and 12 are about e2-B. They are recorded for that re-specification, and bind the cycle-22 fixer only where 12.3 carries them.
       - **`isPurged` keeps its entry copy** (`ValidatedManifest.swift:78-83`). There is no edit to `ZTronAssetModel`, which is not WP-F's (P1). If a `.scope` figure shows that the copy decides a miss, report it with the figure.
       - **Records.** Propose (S3-R6) RE-S24's corrected text (`docs/ARCHITECTURE.md:456`; e2 §1.1): it puts the purged ids' job removals after the store's await, and the code makes them before it, in the purge's first turn. Every estimate stays labelled as one (G2).
       - **Fixer hours,** estimated (e2 §6): e2-A1 5-8 h, and e2-A2 6-10 h, with the cases and red commits included.

    4. **The order of work** (item 10), amended:
       - **Step 0** also runs T-E1, T-E3, T-E4 and T-E5 on `d5b2ab9`, recording each red or green, and takes the 'before' figures of 12.3's cases.
       - **Step 1** also takes these parts of 12.2, all of them before item 6's `EngineFollow.swift` removal in step 2 (e1-R1's kills are in step 7; 12.2's records, and item 9's re-measures, are in step 8):
         - every T-E test that is red on `d5b2ab9`, committed failing in one commit (item 10's red-first rules);
         - then e1-R1, with rr21-T8b's change, the PIN-END invariants test's change, and each T-E test not committed red in the previous commit;
         - then the probes e1-PS, e1-P1, e1-P2, e1-P3 and e1-PR. A red one with a route gets its failing commit, then its fix by 12.2's routes; one with none follows 12.2.

         e1-R1 moves `EngineFollow.swift`'s lines below `:820`, so item 6 finds `replayVerdict`'s lines by content (e1 §5). Any other citation of this ruling that a change in this item moves is found by its content too: for example, a fix at `relane`'s guard (`EngineJobs.swift:307`) moves item 1's c6 site and 12.3's `EngineJobs.swift` lines.
       - **Step 4** takes 12.3 with item 2:
         - the cases not yet in the tree, committed red where they miss;
         - e2-A1's parts, one commit each, then the figures of every purge case;
         - e2-A2's parts if triggered, one commit each, then the figures again.
       - **Step 7** adds e1-R1's kills and e2-A1's and e2-A2's kills, beside item 5's.
       - **Step 8** adds the records of 12.2 and 12.3. Item 9's check covers 12.2's and 12.3's lines.
       - **The named findings.** The draft's status list keeps this mapping:
         - correct #1 → 12.2;
         - correct #2 and reqs #4 → 12.3 with item 2;
         - correct #3 and reqs #2 → item 1;
         - correct #4 and reqs #5 → item 3;
         - correct #5, reqs #6 and reqs #12 → 12.1;
         - correct #6, reqs #7 and reqs #8 → items 5 and 6;
         - reqs #1 → 11.6, and reqs #3 → 11.7.
       - **Expect the weekly limit.** Item 10's paragraph stands. With item 12, cycle 22's fixer work is estimated at about 55-90 h, so a cut-off inside the cycle is likely. Commit every finished step when it is done.
    5. **Settled points.** The writer, the two checkers and the editor of this item left these for the orchestrator. Where this sub-item and 12.1 to 12.4 differ, this sub-item decides.
       1. **A probe is blocking only when it breaks S3-R16 item 1:** an answer different from visit-first's, or a broken MUST or invariant. e1-P3 records X's state and asserts visit-first's answers. A `.blocked` state with visit-first's answers is recorded, and is not blocking.
       2. **A probe that cannot be built.** If e1-PR's shape, the removal edge in `sweepFollowsFirst` only, cannot be built after a real attempt, follow S3-R26 item 7's B-T5 rule. Record the attempt, why the shape cannot be built, and the residual risk beside e1's UNCONFIRMED claim. It is not blocking.
       3. **T-E2 joins step 0** with T-E1, T-E3, T-E4 and T-E5. Its result on `d5b2ab9` is measured, not read from the code.
       4. **The kills of a red probe's fix** land at step 7, beside e1-R1's. Those are the branches of the commit-shaped record at the `.superseded` arm and of `relane`'s guard (`EngineJobs.swift:307`).
       5. **e1-R1's ENOENT write** goes inside `if self.transition(transfer, to: .queued)` (`EngineDispatch.swift:1280`), so that a record exists only when the re-queue happened.
       6. **The cycle-21 mutants whose anchors or filters e1-R1 changes** are rewritten for e1-R1's code and re-run at step 7, as item 5 does for r6 and r8:
          - `mut-c4fix.py`'s p1, p2, p2b, p3, p4, p5 and p10;
          - the LAYER filters of `mut-c4fix`, `mut-c3`, `mut-c3fix` and `mut-pinend`;
          - `mut-i5`'s T8B.

          Their filters include the T-E tests and rr21-T8b's new name. Rewrite them in cycle 22's own copies under `.build-s3f/c22/tools/`, and leave `.build-s3f/c21/` unchanged. The draft records each old and new text and its result.
       7. **The regression controls** of e1 review should-fix 9 bind. They are rr21-T8b as changed, the PIN-END suite, `FBJoinGapFailure`, Shape A, probe (ii) and the D-13 test, each run green in both orders on e1-R1's commit.
       8. **Two more amendments** under 12.2, for the ENOENT re-queue end:
          - answer 6.3's header predicate, "follows the copy at the replay" (rulings :680);
          - `integrate-rr21.md`'s B17 entry, "T8/T8b (pin left)" (`:971-972`).

          For that end, the pin holds (e1-R1). Neither file is edited: this item decides.
       9. **12.2's records** add `s3f.md:5072` (reqs #10's record; fidelity should-fix 3). For `s3f.md:5823-5824`, add a cross-reference to `:5857-5862`, not a rewrite (e1 review should-fix 6).
       10. **The `.scope` case** selects every id of case (i), so that every id goes through `isPurged`'s filter path. A narrow scope is not a case.
       11. **The user-waiter case** has two variants, both gated: 10,000 jobs held only by user waiters, and 10,000 jobs held only by ensures (e2 review must-fix 10). They can be one BenchSync case with a parameter.
       12. **Red purge cases across the part commits.** The 12.3 cases that miss on `d5b2ab9` go in one red commit, right before e2-A1.1 (reqs #13's reading).
           - Only the Benchmarks stage may stay red through e2-A1's and e2-A2's part commits, and only for those cases, because those parts are their fix in steps. This amends S3-R26 item 11's "Only that commit may be red" for these cases only.
           - Each part commit's message names the cases still red, and every other stage is green at every commit.
           - A case still red after the last authorised part is a miss, under 12.3's decision rule.
       13. **Measuring between parts.** After each e2-A1 and e2-A2 part, re-measure `purgeWhileOwedTurns` and PROBE-C21-PURGE-PARTS, as item 2 says. After the last e2-A1 part, and after the last e2-A2 part, measure every 12.3 case, as 12.3's decision rule says.
       14. **The deciding-figure list** in item 10 now names e2-A2's 8.5 ms trigger (12.3) in place of item 2's in-place batch.
       15. **An audit before e2-A1.4.** e2-A1.4's single `settleRemoval` per job cuts the mid-turn `notifyObservers` calls (`EngineJobs.swift:406`; e2 review should-fix 5).
           - Before e2-A1.4, audit the purge suites' `waitUntil` and `awaitCondition` predicates for states that exist only mid-turn, as item 3's A5 audit does for the answer-site suites. Record the audit.
           - Where a predicate depends on such a state, keep a `notifyObservers` call there, and record it.
           - The same audit gates e2-A2.6.
       16. **The `.scope` copy and S3-R8.** A `.scope` miss counts as other-wp:a under S3-R8, and is not WP-F's blocking miss, only when two things are measured after e2-A1 and e2-A2:
           - the turn without `isPurged`'s entry copy is within `c2Budget`, for example in a scratch probe that reads the policy and tags in place;
           - the copy is the only remaining part above it.

           Otherwise the miss is WP-F's, and it is blocking. No file of ZTronAssetModel is edited (P1).
       17. **Item 9's inventory** gains rows, each with its figure, for any of these that land:
           - e2-A2.2's counter and the compaction;
           - e2-A2.3's freeing turn, or its later unsliced turn;
           - e2-A2.5's heap pass.
       18. **Two more records:**
           - 12.1's: the doc at `BenchSyncCycle21.swift:156-158` now says "outside the bar, by the owner's ruling of 5 Nov; recorded", at step 8;
           - 12.3's: the doc at `EngineCommands.swift:1053` ("in (id, token) order, as withdrawPurged drops them"), corrected where e2-A1.3 makes it false.
       19. **Row 14** (the purge over one id held by 10,000 groups) is outside the bar (12.1). It is not measured in cycle 22; its d3 estimate stays recorded.
       20. **e1-PR's cost** is not in e1 review's 3–5 h probe estimate. Add about 1 h (estimate).

## Orchestrator ruling added 2026-11-06 (cycle 22's verification; written before the cycle-23 fixer starts)

**S3-R28.** Cycle 22 implemented S3-R27 in part (`d5b2ab9..9aa337c`, 44 commits; the last production commit is `2abddd1`, e2-A2.5): steps 0 to 3, step 4's e2-A1.1 to A1.7 and e2-A2.5, e2's kills, and step 8's gates and re-measures (`s3f.md:6910-6947`). e2-A2.1 to A2.4 were not made (`s3f.md:6936-6937`). Its verifiers left 14 blocking findings, 7 in each lens, and S3-R27's steps 5 to 8 are unfinished. This ruling routes them, except correct #1 and #2: their route is item 1b, which the orchestrator appends later (item 1). Cycle 23 starts as run 10, and its fixer may take several runs (item 6).

**S3-R28 is cycle 23's ruling.** S3-R16 to S3-R27 apply wherever S3-R28 does not change them. Where S3-R28 differs from an earlier ruling, from a specification or from an analysis, S3-R28 decides. The cycle-23 verifiers judge by S3-R16 to S3-R28. Item 1b and item 3b, once appended (items 1 and 3), bind the cycle-23 verifiers for the work of every step that started after they were appended. The draft's status list records when each was taken (item 6). An appended item decides where it differs from items 1 to 8. Item 8, "Fail fast", binds the fixer and the verifiers from cycle 23 on, wherever an earlier ruling, or items 1 to 7, order the work otherwise.

Where to find things:
- **The cycle-22 verifiers' findings** are in `.build-orchestrator/s3f-c22-issues.json`, on `9aa337c`. They are cited as "correct #n" (`lenses.correct.issues[n-1]`) and "reqs #n" (`lenses.reqs.issues[n-1]`).
  - Fix them in S3-R1's order: blocking first.
  - A verifier finding is **named** by this ruling when it reports the same case, shape, mutant or `path:line` (at `9aa337c`) as an item here.
    - The fixer records the mapping ("correct #n → item k") in the draft's cycle-23 status list (item 7).
    - A named finding is closed by its item's route and decision rule, even where the finding proposes another fix.
  - A blocking finding that this ruling does not name follows S3-R16 and the general rulings.
- **The read-only analyses made for this ruling**, in `.build-orchestrator/s3f-c22-analysis/`:
  - `f1-enospc-windows.md`, with its review `f1-enospc-windows-review.md` (item 1). The review finds f1 UNSOUND as a whole, and its replay half sound. That second finding does not hold as stated (f1b review must-fix 2);
  - `f1b-join-rule.md`, with its review `f1b-join-rule-review.md` (item 1). The review finds f1b UNSOUND;
  - `f2-flake.md`, with `f2-flake-review.md` (item 2; CORRECTED);
  - `f3-purge-route.md`, with `f3-purge-route-review.md` (item 3; CORRECTED).

  How to read them (S3-R27's header rules, applied to f1, f1b, f2 and f3):
  - Each review corrects its report. Where a review and its report differ, the review wins. Where either differs from this ruling, the ruling wins.
  - **What in a review binds.** Its must-fix items bind, as this ruling corrects them. Its should-fix items bind only where this ruling names them, as this ruling corrects them:
    - f1 review: "The probe helpers" and "The REENTRANCY note" (its should-fix items are not numbered). Both concern item 1's route, so they bind only once item 1b takes them up;
    - f2 review: should-fix 1, 2, 3, 4, 6, 8 and 9;
    - f3 review: should-fix 1, 3, 4, 5, 6, 8 and 9.

    A review's "What the ruling must add", a report's recommendation, every other should-fix item and every "optional" bind only as this ruling carries them. Otherwise they are advisory, and a verifier does not report their absence as blocking.
  - Below, "must add" n is a review's "What the ruling must add" n, and "must say" n is a report's "What the ruling must say" n.
  - Their line numbers are at `9aa337c`; re-cite them after a change. Their figures not marked "measured" are estimates, from code reading and from the draft's and the verifiers' measurements. A measurement decides.
- **Names** (S3-R27 12's names rule still applies). R1 already means S3-R11's, `integrate-rr21.md`'s and S3-R27 item 3's, and B1 and B2 are S3-R27 item 3's too, which step 4 runs in this cycle. So, in this ruling and in the draft's records:
  - f1's branches are f1-B1 to f1-B13, and f2's R1 to R3 (its probe, its fix and its check) are f2-R1 to f2-R3;
  - f1's clauses keep their names, clause (a) to clause (g), and f3's conditions on C-2 are C-2 (a) to C-2 (d);
  - f1b's labels carry its name: its kills are f1b-K1 to f1b-K27 (`integrate-c21.md` has clauses K1 to K4, rulings :423), its R1 is f1b-R1, and its clauses are f1b's, for example f1b's (b), which is not f1's clause (b);
  - T-F1a to T-F10, T-F2c, T-F8c, T-B11, the W- shapes, AV-away, AV-off, C-1 to C-5 and stages A to C keep their names.
- **N-numbers** are the orchestrator's rulings behind this text (`s3f-c22-analysis/s3-r28-orchestrator-rulings.md`). N9 rules the re-lane of a kept `.queued` job (item 3). N21 holds the owner's ruling of about 13:30 on 6 Nov and the orchestrator's reading of it (item 1).
- **Cycle 22's scratch evidence:** the verifiers' probes, logs and tools in `.build-orchestrator/s3f-probes-c22/` (`VerifyC22CorrectProbes.swift`, `reqs/tools/`), and the fixer's `.worktrees/s3f/.build-s3f/c22/` (the scratch copy `snap0`, `tools/`). Do not delete them. Cycle 23's scratch files go under `.build-s3f/c23/`. Its rewritten mutants go in its own copies under `.build-s3f/c23/tools/`, and `.build-s3f/c22/` stays as cycle 22 left it, as 12.5.6 left `.build-s3f/c21/` (rulings :1243).

**How a C2 figure is read in cycle 23.** S3-R27's rule ("How a C2 figure is read in cycle 22") applies to every C2 case that cycle 23 measures. The bar is the owner's (S3-R27 12.1): `c2Budget`, 10 ms, over 10,000 ids however grouped, with at most 4 interests on one id and one subscriber, which may be stalled. 8.5 ms decides only the routes that name it, and the margin list (S3-R27 item 9; rulings :764).

1. *Correct #1 and #2: the ENOSPC windows.* Blocking (S3-R16 1(a)). Both are measured 2/2, red swept first (`s3f-probes-c22/correct-probeC22TransferSpaceDrainJoin.summary.log`, `correct-probeC22ApplyInRead.summary.log`).
   - **Correct #1** (PROBE-C22C-TS-DRAIN-JOIN, seed 2_029_101). A user request made before T's transfer ENOSPC is replayed inside the free-space read and meets no stamp (`EngineJobs.swift:293-294`), so T20 re-queues T (`:360-364`). Visit-first answers A, X and V `insufficientSpace` and starts T once. Swept first, all three get `ok(100000 B)` and T starts twice. With V made inside the read (seed 2_029_201), both orders give `ok` and 2 starts.
   - **Correct #2** (PROBE-C22C-APPLY-IN-READ, seed 2_029_301). v4, applied inside a publication's free-space read, makes the visit branch (`:290-291`) date v3's move after the end, so T20 re-queues T. Visit-first answers A and X `insufficientSpace` with one start; swept first, `ok` with two.
   - **The causes are two** (f1 §1, as review must-fix 2 corrects it): a re-lane dated by the wrong clock, and a re-queue that visit-first makes and the swept-first engine never makes before the verdict.
   - **Nothing in item 1 is ruled for the code now.** The fixer does not change `metInItsAttempt` (`EngineJobs.swift:289-297`), `Job.transferSpaceEnd` (`EngineState.swift:867`), `AttemptEnd.stamped` (`EngineFollow.swift:2017-2022`), `relane`'s dating (`EngineJobs.swift:327`), or the dating of any join or replay. f1's clause (b), which counts a join made while `bringingInbound` as met (f1 §3, step 2), is not ruled either.
     - **Why** (f1b review must-fix 2, W-JOIN-HOP; by code reading, UNCONFIRMED). In the shape, a replay reaches the failed job by a hop through a copy adopted since the end (`replayJoin`, `EngineFollow.swift:981`, through `followLayers`, `:800`). f1's clause (f) dates a replay by its stamp (`reading.serial <= stamped`), so it would date this one as met, wherever the stamp is written.
     - At a transfer's end, with the drain inside the read, `9aa337c` has no stamp, so the replay is not met and T20 re-queues the job, as visit-first does: the shape is green there today (`EngineJobs.swift:293-295`). f1's replay half, one stamp written at both ends with clause (f) for replays (f1 review "must add" 1), would turn it red. At a publication's end, and in the late drain at both ends, the shape is red on `9aa337c` already (f1b review must-fix 2, by code reading).
     - So the f1 review's "The replay half is sound" (its line 8) does not hold as stated. Its corrected form, "(f) for direct replays only; a hop onto J is dated by its chain" (f1b review "must add" 2), is a reviewer's proposal that no independent reader has checked (P4).
   - **Correct #1 and #2 stay blocking** (S3-R16 1(a)) until item 1b routes them. The draft's status list reports them with their logs.
   - **Step 0's shapes.** Run each one on `9aa337c`, in both orders, 2 rounds each, and record it as red or green (measured), with its log.
     - **Drain timings.** Run every shape in both drain timings. The helpers apply through `applyHeld` (`VerifyC22CorrectProbes.swift:285`, `:415`, `:443`), which, visited first, lets the follow end inside the apply (`EngineFollowBarrierReachTests.swift:25-27`). So only the swept-first runs have two timings:
       - the drain released inside the failed job's free-space read, as the cycle-22 probes do (`VerifyC22CorrectProbes.swift:320`, `:445`);
       - the "late drain", whose follow is released only after the read returns, so that the drain runs after the job's verdict defers (f1b review, line 8). No probe has run it.
     - **The shapes:**
       - f1's T-F1a to T-F10 and W-PR, with f1's T-F4 replaced by the corrected T-F4 below;
       - f1 §3's windows 8 to 10 (`f1-enospc-windows.md:200-207`): the deferred window's away-and-back, take-off re-routes onto a job in its window, and unlisted ids, each by the probe that f1 says settles it;
       - the f1 review's W-HP and W-AWAY, each at the transfer's end and at the publication's (must-fix 1 and 2), W-DB (must-fix 2) and W-PD (must-fix 3);
       - T-F4, built as f1 review must-fix 5 corrects it (v4's pass reaches zz-x while v4's copy stands, and visit-first's T20 comes at v4), and its lazy twin;
       - f1b §2's W-HP-d, W-DB-off, and W-BACK at both ends (`f1b-join-rule.md:116`, `:120`, `:121`), which f1b §3 runs at step 0 (`:125`);
       - f1b's new tests T-F2c, T-F8c, W-HP-d0, W-PD-back and T-B11 (f1b §3), and its open shapes W-HP-late, AV-away, W-ONOFF and the multi-change lazy shape (f1b §7). Add f1b §7's pending-move corners (i) to (iii) where they can be built. The f1b review argues that corner (iv) is unreachable (its should-fix "§7 (iv) is unreachable");
       - the f1b review's W-PD-back2 (must-fix 1), W-JOIN-HOP at both ends with its owed-re-route and take-off variants (must-fix 2; `f1b-join-rule-review.md:53-54`), W-JOIN-OFF and AV-off (must-fix 4), the shape that separates f1b-K19 (must-fix 8), and W-BACK-PUB, with U's publication held at v4 ("must add" 3 and 7).
     - **How.** Build the shapes from the verifiers' helpers (`VerifyC22CorrectProbes.swift:255-342`, `:384-466`). Each asserts visit-first's answers and the failed job's start count, and serves every content it requests (S3-R27 12.2's "Serving", rulings :1091).
     - **The reference is the measured visit-first run.** A shape's visit-first answer is the one its `.followVisitedFirst` run gives (`EngineFollowTests.swift:783`), not the analyses' prediction. A swept-first answer is red when it is none of visit-first's answers (N21's reading, below). Where the visit-first run misses an analysis's prediction, the draft records it, with its log, for f1c. It does not block.
     - **A shape that cannot be built** after a real attempt follows S3-R26 item 7's B-T5 rule, as S3-R27 12.5.2 applies it to e1-PR (rulings :585, :1234). The draft records the attempt, why the shape cannot be built, and the residual risk. The shape is not blocking.
     - **A visit-first answer that depends on timing.** Record each visit-first answer, with its inputs' order and the timing that selects it, for:
       - the multi-change lazy shape, W-BACK-PUB and pending-move corner (iii), by f1b §7 and "must say" 12, and by f1b review "must add" 7;
       - any other shape whose visit-first runs give more than one answer for the same inputs in the same order (N21).

       Swept first matches when it gives one of those visit-first answers for the same inputs in the same order (N21). This is a reading of "visit-first's answer" where visit-first has more than one, not a narrowing of the bar.
     - **Which red shapes block.** A shape is red in an order and drain timing when it fails there in either round.
       - A swept-first round fails when its answer is none of the visit-first answers recorded for the same inputs in the same order, when the failed job's start count differs from visit-first's, or when it breaks a MUST or invariant, or hangs.
       - A visited-first round fails only by a broken MUST or invariant, or by a hang. A missed prediction is recorded as "The reference is the measured visit-first run" says.
       - A red shape is blocking (S3-R16 1(a) to 1(c)) when it breaks S3-R16 item 1 there: an answer that is none of visit-first's, a broken MUST or invariant (`invariantViolations()`, `EngineCommands.swift:1773`, which the helpers record at `VerifyC22CorrectProbes.swift:338` and `:461`), or a hang (S3-R27 12.2, rulings :1121; 12.5.1, :1233).
       - A shape red only by the failed job's start count, with visit-first's answers, is recorded as red by its count. It is not blocking (S3-R16 item 2; S3-R26 item 7, rulings :587).
       - The multi-change lazy shape, W-BACK-PUB, pending-move corner (iii) and every other shape that "A visit-first answer that depends on timing" covers are classed as it says.
       - Each blocking shape is reported with its log, and item 1b rules what follows for each one.
     - **Probes and commits.** The shapes are probes, kept under `.build-s3f/c23/`. A red shape is committed as a failing test only right before item 1b's fix for it, or as a stop's evidence (item 8's point 3).
     - **The results** go to the draft's cycle-23 status list as one table. Each shape has three cells: visited first, swept first with the drain inside the read, and swept first with the late drain. Each cell gives red or green for each of the 2 rounds, with the log.
   - **Item 1b is item 1's whole route:** the replay half (amended for hops, if that holds), the join rule, the window's close (f1b §1, step 6), the stamp's clears, the tests, the kills, C2 and the records. The orchestrator appends it after three inputs, between fixer runs or between steps, and the fixer takes it as item 6 says:
     1. step 0's measured shape results (above);
     2. f1c, a re-analysis of f1b as its review corrects it, with its own review;
     3. the owner's ruling (N21, about 13:30): a join, request, removal or replay that meets a job during its ENOSPC end's free-space read gets visit-first's answer, including whether it counts as before or after the end; a different answer is blocking (S3-R16 1(a)).

     f1c runs now (N21). The orchestrator checks its predictions against step 0's measured table before item 1b's route binds.
     - **N21's check** (`s3f-c22-analysis/s3-r28-orchestrator-rulings.md:131`, `:170`). The orchestrator compares f1c's predicted reds and greens with that table. A contradiction is a stop under item 8's 2(c).
   - **Until item 1b is appended,** the f1 and f1b reviews' must-fix items bind only through step 0's shapes and drain timings, and f1 review must-fix 2 through the two causes as well. Every other part of f1, f1b and their reviews binds only as item 1b carries it.

2. *Correct #3: the flake in `shutdownClearsTheJoinsBehindAVerdict(.followVisitedFirst)`* (A-T-SD, `EngineFollowBarrierDeferBucketTests.swift:754-788`, "DBT" below). Blocking (S3-R16 1(d)): a test that fails in any run. Its cause is a test that races its own set-up (f2 §1; review should-fix 1). It is not 1(a).
   - **The failure.** The third of the verifier's three debug Sync runs (09:16:20-09:26:20; it ended at load averages 21.05, 95.01 and 81.74) failed at DBT:781 and :786: zz-o's waiter and every member got `.success(… byteSize: 20)` for `.failure(.shutDown)`. Run alone, the test passed 8/8. PROBE-C22C-SHUTDOWN-BUCKET-RACE gave both outcomes at a 1-minute load of 128-132 (`correct-probeC22ShutdownBucketRace.summary.log`).
   - **The mechanism** is f2 §1's, confirmed by its review. v4's visit re-queues O by T20 (`EngineJobs.swift:360-363`). With `holdRetry: false`, the retry can resolve before shutdown's first turn takes the waiters.
   - **Route: f2's, as its review corrects it:**
     1. **The probe first** (f2 §2, f2-R1). Visited first, with `holdRetry: false`, force the serve first (`driving([b.s.time], fence: engine) { awaitCondition { $0.state.jobs[b.o.transferID] == nil } }`), then shut down and assert DBT:781 and :786 unchanged. Its red does not depend on load, by construction. The fixer runs it, 2 rounds, and records it red with its log (G2). The verifier's `serve=true` arm printed ok(20 B) in 2/2 rounds but asserted nothing (f2 §2). Record O's state and request count after the set-up and after v4. It is not committed.
     2. **The fix**, on A-T-SD's commit, which also carries the set-up check (3); the doc fixes (4) may share it: `holdRetry: true` at DBT:763 (f2 corrects the finding's :762). DBT:777-786, the seed, the ending, the wanters, the count and the arguments stay as they are (G3).
     3. **The set-up check** (review must-fix 2). Visited first only, after DBT:765, one `readForTests` of O's state and `interests.count`, then `try #require` that they are `.downloading` and `count + 1`. It is an assertion, not an `awaitCondition`, and it sits in A-T-SD, not in `deferBucketApplyV4`, where A-T1's unheld retry (DBT:314) would race it.
     4. **The doc fixes** (review "must add" 3): DBT:94-95, worded conditionally (should-fix 3); DBT:533-535 and :756-758; DBT:611 and :681-682 (must-fix 1); and `s3f.md:5526-5527`. Afterwards, a grep of the Sync tests for "verdict's arrival" finds no claim that a retry starts there.
   - **The other tests f2 names** (§3), as its review confirms them. T-PURGE (DBT:542, held at :544) and T-FL (DBT:622, held at :640) already hold the retry, so only their doc lines change (above). A-T1 (DBT:312-337) and DBT:720-752 stay, for f2 §3's reasons. `EngineFollowBarrierSharedMoveTests.swift:354-372` and `EngineFollowBarrierTests.swift:1318` stay (G3), because neither races a served retry (should-fix 6). No other set-up changes.
   - **No other route:** no assertion that accepts either answer, no prefetch-lane substitute, no clock moves in the committed test (they fire O's backoff alarm and order nothing against the shutdown; should-fix 2), and the visited-first argument stays (f2 §2).
   - **The order.** Item 2 is step 1, on its own (item 5). Item 1 changes no code before item 1b, so T20 fires here as it does on `9aa337c` (`EngineJobs.swift:360-363`; f2 §1).
     - f2 review "must add" 1's re-run is carried this way. A-T-SD's set-up check runs in every Sync bundle, so every later commit re-checks T20, item 1b's included.
     - The draft's status list records A-T-SD green, in both orders, with its set-up check, on A-T-SD's commit (step 1), and on item 1b's last commit if item 1b is taken in cycle 23.
     - A failure there is a T20 regression: fix the code, not the test (review "must add" 1).
   - **Records:**
     - the set-up change, one to one: the old `holdRetry: false`, the new `true`, the cause (T20) and why no scenario is lost (should-fix 9). That record carries should-fix 4's correction: the "O verifying at the shutdown" interleaving was asserted only at random, not never. It cites a test that shuts down during a publication deterministically, such as `EngineFollowBarrierSharedMoveTests.swift:354`, whose swept-first arm requires `shutDown` (`:357-360`), or records that no test covers `EngineDispatch.swift:1078-1080`;
     - the residual (must-fix 3), under "Residual risks (S3-R16)", non-blocking (S3-R16 item 2): a shutdown inside the barrier answers `shutDown` to every answer that waits for the drain. Its probe is f2-R1 beside A-T-SD's swept-first arm (`shutDown` ×11, 4 joins behind, 3/3). f2-R1's figures are recorded, with the note that f2-R1 is not committed. The record qualifies `EngineFollowBarrierTests.swift:1315`.
   - **Evidence at the close** (review "must add" 5): f2-R1 red in the fixer's run (red by construction), with its log; A-T-SD green, with DBT:777-786 passing in both orders; the bundle runs, with their load samples. 30 iterations per argument, on the host and on the iOS Simulator under `sim.lock`, are run, as a regression check only (should-fix 8).
   - **Fixer hours** (estimate; review should-fix 7): 2-3 h on its own, or 1-1.5 h if the cycle's shared close runs cover its bundle runs.

3. *Correct #4 and reqs #1: the purge's six misses.* Blocking (S3-R16 1(f)). Best of 3, heartbeat:
   - correct #4, the verifier's full release Benchmarks run (09:33:14-09:46:39): `fourGroups` 64.00 ms (1-minute load 3.61 to 3.60), `oneGroupScope` 41.69 (3.76 to 3.61), `oneMemberGroups` 38.17 (4.99 to 3.76), `retryJobs` 37.59 (3.60 to 3.36), `oneGroup` 36.91 (4.12 to 4.99) and `sharedJobFourGroups` 18.70 (3.61);
   - reqs #1, the fixer's gate run and re-run at loads of 6.07 or less (`s3f.md:7791-7797`): 62.21 and 62.56, 39.74 and 39.82, 37.11 and 37.38, 36.06 and 36.19, 35.71 and 35.98, and 17.82 and 17.91 ms, in the same order;
   - `sharedJob` (4.76), `userWaiters` (7.13) and `ensures` (7.15 ms) pass (correct #4), and `purgeWhileOwedTurns` closes at 5.01 ms (`s3f.md:7797`).
   - **e2-A2.1 to A2.4 alone close none of the six** (f3 §2, estimate; its review finds this robust). e2's after-A2 estimate for case (i), `oneGroup`, 5-12 ms (e2:193), is superseded, and the draft records that (f3 "must say" 1).
   - **Route C, in one turn,** in stages A, B and C (f3 §3.1 and §5), as its review corrects it. Each part is its own commit. Every in-place access follows S3-R27 item 1's exclusivity rule: `applied`, the request and `claims` are taken into locals, and the other writes come after the access (f3 "must say" 2).
     - **Stage A:** e2-A2.1, A2.2 and A2.3, C-1 and C-4; then the id-level F-1 clause (`EngineCommands.swift:1884`) on its own, with every suite green; then 12.5.15's audit, extended to C-2's and C-3's mid-turn states; then C-2 and C-3. Estimated 5-12 ms for the five 10,000-job shapes, and about 1 ms for `sharedJobFourGroups` (f3 §5; review should-fix 2).
     - **Stage B:** the extended audit for C-5's mid-turn state (retired jobs stay in the table until the rebuild; f3 §3.3), then C-5, the rebuild in sorted order, with no order audit. Estimated 4-10.5 ms.
     - **Stage C:** e2-A2.4's table order, only after the purge suites' order audit (S3-R27 item 3's A7 rule), with the iOS SDK cited (C7). Estimated 2-7 ms.
   - **The parts, with the review's corrections:**
     - **C-1** replaces e2-A2.5's per-job collection with one pass keyed on the job table, and A2.5's kills are re-run (f3 "must say" 3). The stale-retry difference is heap and alarm only, not an answer (`EngineTimers.swift:110-112`), and it is recorded. C-1's epoch arm is killed on a built state with a stale `.retry` of a kept job, or dropped and classed Equivalent (should-fix 4).
     - **C-2's four conditions bind** (f3 "must say" 4). It reads the job through a `mutating` `Job` method on `values[i]` (`_modify`, SDK :8054-8060), not through the getter (should-fix 1). Its read also skips a job with nothing to withdraw, so that `userWaiters` and `ensures` keep today's cost; the per-stage measurement shows it (should-fix 3). The draft gives the argument for its window (should-fix 8). It stays a variant of `retire`'s funnel, for example `retire(at:whole:)` calling `removeJob(at:)`, or the draft proposes the ARCHITECTURE §7.1 amendment (S3-R6; must-fix 4). Each of C-2 (a) to (d) forced false is Equivalent (S3-R19 item 2).
     - **Must-fix 3's option (i) is part of C-2.** C-2 (b) applies only to a `.downloading` job. C-2′ empties a claim-held job whose C-2 (b) holds. After C-2's step 1 (the drops, the heals and the run's `held`), it moves the interest storages out whole to the freeing list, resets the counts, sets `heldLane = last` and writes `claimHeld`. The job stays, held by its claim, in today's end state (`settleRemoval`'s `claimHeld` arm, `EngineJobs.swift:427-431`). The skipped re-queue of a `.queued` job, a ticket and a place, is recorded under S3-R16 items 2 and 3. Option (ii)'s route, e2-B′, is not authorised.
     - **C-3** comes after the F-1 clause. A test that the clause turns red is a finding of its own: S3-R16 1(b) if its state is real, with no route in cycle 23, and the clause stays uncommitted. C-3 is then not made, and `fourGroups` depends on stage C (f3 §5). C-3's place in the turn, before or after `withdrawPurgedJoins` (`EngineCommands.swift:1016`), is fixed before C-3's commit, and stage A's figures are taken with C-3 in that place (should-fix 9). `fourGroupJoins`' step-0 figure is taken on `9aa337c`, which has no C-3.
     - **C-4** reads the applied copy in place, through `position(of:)` and `entries[i]` (public: `ValidatedManifest.swift:15`, `:86-91`). A job counts its purged ids with no Set, and takes `.all`'s path when all of them are purged (f3 §3.1); f3 §3.4's kill of "C-4's count" depends on it. C-4 edits no file outside WP-F (P1). It amends 12.3's "`isPurged` keeps its entry copy". S3-R27 12.5.16's rule for the `.scope` copy stands. After C-4 removes the entry copy, 12.5.16's two conditions cannot hold, so a `.scope` miss after C-4 is WP-F's (blocking under S3-R16 1(f)).
     - **C-5** (must-fix 1, "must add" 2; should-fix 5):
       - every removal the walk makes waits for the rebuild, or for the second pass below, through a walk mode of `removeJob`;
       - no key is inserted into or removed from `state.jobs` between the collection and the rebuild (or the second pass), and a debug-build check says so;
       - the order is the walk, the rebuild (or the second pass), the compaction, C-1's pass, then the final `notifyObservers` (`EngineCommands.swift:1065`), with both SDKs cited (C7);
       - the rebuild runs only when the retired share is large. Otherwise the retired jobs are removed by key in a second pass. The draft records the threshold and its mutants;
       - the rebuild moves the kept values, and no second reference to the table lives across the visits.
     - **The freeing** (e2-A2.3) runs in pinned slices of 512, not in one later turn (f3 "must say" 7). Its spawn gets a REENTRANCY row. Shutdown drains the list in its own slices (should-fix 6), pinned as S3-R27 item 6 pins `settle`'s: the slices recorded, and the slice's drop-mutant failing 2/2.
     - **The kills** are f3 §3.4's, corrected (must-fix 2; should-fix 4 and 5). Each is 2/2 in each order that reaches its branch, by value:
       - C-2 (c) forced true is reached only by `purgeRemovesInAscendingTokenOrder`;
       - C-3's group filter is killed by a new `.all` test, in both orders, with a `.prefetch` group, a `.userInitiated` prefetch group and an `ensureAvailable` group pending on distinct contents, asserting by value right after the purge (f3 review must-fix 2). A new model-test variant that purges `.all` also runs C-3 on random states, with the id-level F-1 clause checked afterwards. It is not a killer of record, since the model test registers groups only at `.prefetch` (`EngineModelTests.swift:87`). The existing model test stays (G3);
       - C-2′ forced false changes only cost (Equivalent, S3-R19 item 2). C-2′'s writes to the end state are killed by a test that reaches C-2′, a claim-held job whose C-2 (b) holds. By code reading, `purgeRemovesInAscendingTokenOrder` is one (`EnginePurgeWithdrawalTests.swift:83-91`), and `…EarlierRelane(claimed: true)` is not, since C-2 (b) fails there (must-fix 2). The run decides;
       - the narrowed C-2 (b)'s `.downloading` test is killed each way, or classed with its argument (S3-R19 item 2);
       - the rebuild filter's mutants are listed and killed.
   - **The in-letter shapes with no gated case** (S3-R27 12.1; f3 §3.6, review must-fix 3 and "must add" 1). Each becomes a BenchSync case, gated as 12.3 gates its cases: its heartbeat, best of 3, with loads, with the purge's synchronous turn beside it, and its 'before' figure from step 0. One that misses on `9aa337c` is committed red right before stage A's first part. A new file for them follows item 4's ownership rule. The five cases:
     - `keptUnderThreeGroups`: a user waiter on each of 10,000 ids plus three prefetch groups. Estimated 38-48 ms today, and 34-39 ms after route C.
     - `fourGroupJoins`: 40,000 joins waiting for the follow. Estimated 15-22 ms.
     - `mixedLaneGroups`, the mixed-lane shape: two prefetch groups over the same 10,000 ids, each id with its own content, the first registered at `.prefetch` and the second at `.bulk`. Estimated 24-33 ms after route C without option (i).
     - `pendingClaimGroups`, the pending-claims shape: two prefetch groups over the same 10,000 ids, the second registered just before the purge. Estimated 16-18 ms after route C without option (i).
     - `oneMemberGroupsFourPerID`: 40,000 one-member prefetch groups, four on each of 10,000 ids. Estimated 8-16 ms after route C (review "must add" 1).
   - **The re-lane of a kept `.queued` job** (review "must add" 6, answered yes). Under S3-R16 items 2 and 3, the purge may skip `settleRemoval`'s re-lane (`EngineJobs.swift:435`) of a kept `.queued` job whose lane the purge leaves unchanged. Today's `relane` re-enqueues every queued user job, even when its lane is unchanged (`:311-314`), and that changes only the job's place and ticket (`enqueue`, `:563-578`).
     - This holds while S3-R16 item 1 holds.
       - In the step that first skips the re-lane (a stage of route C, or item 3b's route), a probe runs before the commit that makes the skip. It must show, in both orders, that the answers and every job's start count equal visit-first's.
       - That commit's message and the draft cite its log, and the draft records the place difference under "Residual risks (S3-R16)".
       - If the probe shows a difference, the skip is not taken.
     - The `.failed` arm's re-admission stays.
   - **Item 3b,** a route in one turn for the purge cases that route C does not reach, is being analysed now (f3b, with its review). It covers `keptUnderThreeGroups`, `fourGroupJoins` and `oneMemberGroupsFourPerID`, plus `mixedLaneGroups` and `pendingClaimGroups` if option (i) leaves them above 8.5 ms after stage A, where option (i) lands.
     - After stage A, a case above 8.5 ms goes one of two ways. If stages B or C can move it (the stage trigger, below), it waits for them. Otherwise it is item 3b's.
     - The orchestrator appends it as "item 3b" between fixer runs, or between steps; the fixer takes it as item 6 says.
     - Until it is appended, those cases are measured and reported, not routed.
     - When item 3b is appended, it names:
       - its place in item 5's order;
       - the parts of route C it replaces or rewrites (C-3, and the sort at `EngineCommands.swift:1019`);
       - what happens to any of them already committed.

       Until item 3b is appended, the fixer follows route C as ruled.
     - f3b-route-a §9's three ungated in-letter shapes (`f3b-route-a.md:167`): item 3b says what cycle 23 does with each (N25, below).
   - **The owner's ruling of 6 Nov (N25): three purge shapes are known misses.** The owner said: "leave these three cases out of cycle 23 and record them as known misses of the 10 ms limit". They are the first three rows of `f3b-review.md` §7:
     1. failed user jobs with `.retry` deadlines, under one to three prefetch groups: about 500 ms if the origin admits a user request, 9-18 ms otherwise (derived, from `s3f.md:7584` and `:7617`);
     2. a bulk waiter under three prefetch groups: 9-17 ms (estimate);
     3. a prefetch group and a bulk group, under a third group's pending claim: 10-20 ms (estimate).
     - They are out of cycle 23. They are not blocking and not gated, and no code, test or bench is added for them. The verifiers do not report them as blocking.
     - The fixer records them in the draft, under "Known misses of C2's 10 ms limit (owner ruling 2026-11-06)". For each one the record gives:
       - its shape;
       - its figure, labelled "derived" or "estimate", with the derivation and its citations;
       - what would close it (`f3b-review.md` §7, and f3c's analysis with its review, `.build-orchestrator/s3f-c22-analysis/f3c-open-shapes.md` and `f3c-open-shapes-review.md`);
       - the owner's re-open criterion: how often the miss happens in the field.
     - §7's rows 4 and 5 stay measured, as variants of item 3b's cases. Every other C2 shape stays under S3-R27 12.1's bar.
   - **Item 3 waits for item 3b's check.** Option (i) (C-2′) and N9's skipped re-lane (the re-lane of a kept `.queued` job, above) are re-checked by item 3b, which may change them. If item 3b is not in the rulings file when step 2 would start, do steps 4 and 5 first, then step 2 once item 3b is appended (item 5).
     - **Why.** f3b's review (`f3b-review.md`) says that option (i)'s C-2′ breaks R-SYN-3 for a kept claim-held job (its A1 and must-fix 2). It also says that the skipped re-lane leaves `queuedAt` and `lastTicket` unchanged (`EngineJobs.swift:568`, `:570`), and that skipping `settleRemoval` drops its `notifyObservers` (`:437`; its B2 and must-fix 4).
   - **The decision rule** is S3-R27 item 1's: at or below 8.5 ms closes a case; 8.5 to 10 ms is recorded "at the edge" and is not blocking; a miss is blocking.
     - Measure every purge case after each stage: 12.3's twelve and the five above, best of 3, with loads.
       - S3-R27 12.5.13's re-measure of `purgeWhileOwedTurns` and PROBE-C21-PURGE-PARTS is taken after each part of route C, e2-A2.1 to A2.4 and C-1 to C-5 alike (rulings :1257).
       - The per-stage measure of every purge case replaces 12.5.13's "after the last e2-A2 part".
     - **The stage trigger names the cases each stage can move** (should-fix 7). Stages B and C change only the cost of retiring jobs from the job table (f3 §5). Stage C also drops the walk's key sort (`EngineCommands.swift:1019`; 2-3.5 ms, f3 §3.2, estimate), too little to close f3 §3.6's two cases.
       - So stage B runs only if a case that retires jobs in the purge's turn is above 8.5 ms after stage A. Stage C likewise runs if one is above 8.5 ms after stage B.
       - Stage C also runs when, after stage B (after stage A, if stage B did not run), a case that retires no job is above 8.5 ms by no more than 3.5 ms, since stage C's drop of the key sort may close it.
       - Any other case above 8.5 ms that retires no job triggers neither stage. By f3's estimates these are `keptUnderThreeGroups` and `fourGroupJoins`. Item 3b routes them.
       - The draft says, for each purge case, whether it retires jobs, from the case's set-up.
       - A trigger without a quiet load follows S3-R27 item 10's rule for deciding figures.
     - A miss after stage C, or after the last stage triggered, is blocking (S3-R27 item 1's rule). Report each miss with its parts' figures and loads.
       - For a case that item 3b covers (above), the route is item 3b. Until item 3b is appended, the draft's status list gives its route as "item 3b, not yet appended". Once item 3b exists, a miss after item 3b's route is blocking, with no route in cycle 23.
       - Every other miss, and a covered case's miss at the close if item 3b was never appended, has no route in cycle 23.
     - Red cases across route C's parts, and across every other cycle-23 commit, follow item 5's "Red cases across the cycle" (S3-R27 12.5.12, extended).
   - **e2-B′ is not authorised** (f3 §4). The fixer does not build it.
   - **Records** (f3 "must say" 12): item 9's rows for C-1's pass, C-3's pass, the rebuild and the freeing slices, in place of 12.5.17's rows for the parts they replace; RE-S24's text, as 12.3 says; 12.5.15's audit, extended to the walk (f3 §3.3) and to C-3's mid-turn state (should-fix 9), made before the parts it gates (stages A and B above).
   - **Fixer hours** (estimates, f3 §5): stage A 12-18 h, stage B 3-4 h and stage C 4-6 h, 19-28 h in all. Option (i) and the five new cases are not in them.

4. *S3-R27's unfinished work* (correct #5 to #7, reqs #2 to #6). S3-R27's routes and rules stand. In S3-R27's order:
   - **S3-R27's step 5 (cycle 23's step 4): item 3, the APM answer turn** (correct #5). PROBE-C21-APM, rebuilt on `9aa337c` and run in release with `-enable-testing`, in-actor, best of 3, at a 1-minute load of 9.85 to 8.65: group 9.37 ms (at the edge), groups 11.10 ms and users 13.93 ms (misses). A3 and A3′ landed in e2-A1.6 (`332b6cc`), so sub-step 4 reuses them.
   - **S3-R27's step 6 (step 5): item 4,** the k = 2 and k = 4 in-letter shapes, with A1 and A2 if taken (reqs #2). Correct #9 calls them unmeasured, so unproven.
   - **S3-R27's step 7 (step 6): the kills.**
     - Item 5's remaining kills, d4 review's steps 6 to 12: b22-no-waiter-owner, p7 with r5, r8, vy, r2c, b22-no-run-owner and r2b. b22's owner checks are now `EngineFailures.swift:858-859` and `:866-868`, still at 0 hits (correct #7).
     - The 429 probe: item 5's default-tuning probe.
     - e1-R1's rewritten mutants (12.5.6), with 12.2's kill table.
     - The kills of the e1-PS, e1-P1 and e1-P2 fixes (12.5.4) run here, on the code as it stands. e1-P1's four (`s3f.md:7147-7149`) are among them.
       - If item 1b has been appended by step 6 and rewrites a mutant's code, that mutant is rewritten for item 1b's code and run with item 1b's kills instead, as 12.5.6 does for e1-R1.
       - If item 1b rewrites the code after they ran, item 1b's kills re-run them for its code (12.5.6).
       - Until each is killed, it is blocking (S3-R16 1(e)), and the draft's status list reports it with its route.
     - Route C's mutant runs (item 3 above: f3 §3.4's kills, as corrected), and item 1b's if item 1b places them here. Their tests land with their parts.
     - What reqs #3 already ran is evidence, not kills of record. `v-e1r1-no-enoent-record`, `v-e1r1-kept-returns-nil` and `v-e1ps-no-supersede-record` failed 2/2. `v-e1p1-rule-false` failed its one run (12 issues), but in one test only by its 180 s time limit, which is no kill (S3-R27 item 5). That test, e1-P1's other side, gets an assertion on an answer, a start count or a clause that fails first. The specs are `s3f-probes-c22/reqs/tools/mutants22.py` and `mutants22b.py`.
     - Reqs #8's guard: `.timeLimit(.minutes(1))` on `publishAllMatchesOnePublishPerEvent(seed:)` (`Tests/ZTronAssetSyncTests/Engine/SubscriberQueueBatchTests.swift:95`), as `SPEC.md:331` asks. It is a guard only, so G3 holds. The draft records it.
   - **The three unreached lines** (correct #6, reqs #4): `EngineCommands.swift:1001`, `:1004` and `:1009`. They are the purge predicate's `return true` under `.all` (`:1000-1001`), and its answer for an id that the applied copy does not list, under `.evictable` and under `.scope` (`:1003-1005`, `:1008-1010`).
     - Each is reached by a test that kills, 2/2, its mutant that answers false (`return true` → `return false`), or it is removed with the reason recorded (S3-R16 1(e)). That mutant is the drop-mutant for all three: dropping the `return` leaves an empty `case` (`:1001`) or a `guard` body that falls through (`:1004`, `:1009`), and Swift rejects both.
     - For `:1001`, the expected reach is f3 review must-fix 2's new `.all` test (item 3), with the groups' joins waiting swept first, through `withdrawPurgedJoins` (`EngineCommands.swift:1016`).
       - Under `.all`, only `withdrawPurgedJoins` calls the predicate, because the jobs take the fast path (`EngineCommands.swift:1016`, `:1022`; `Job.withdrawPurged`'s `all`, `EngineState.swift:1131`). So `:1001` is reached swept first only.
       - Its kill is 2/2 in the order that reaches it, as S3-R27 item 6 ruled for the epoch clause (rulings :972). The record says that visited first cannot reach it, and why.
     - For `:1004` and `:1009`, the state is reqs #4's: a purge of `.scope` and one of `.evictable` while a job, a waiting join or an owed re-route holds a non-user interest in an id that an apply delisted while a follow is owed.
     - C-4 or C-3 may rewrite these arms. Then this applies at their new lines, in step 6.
   - **Ownership** (S3-R27 11.6; reqs #9). Any new `Tests/ZTronAssetKitBenchmarks/BenchSync*.swift` file that cycle 23 adds is authorised as WP-F's, under 11.6's terms. 11.6's first condition is amended to read: "Each file holds only `SyncBenchmarks` and `SyncBench` extensions and the helper types they use, declared in that file. No helper type's name collides with another work package's, and no file edits another work package's benchmark file."
   - **S3-R27's step 8 (step 7): every record still missing** (reqs #5 and #6):
     - reqs #6's 11.6 record. List under "Authorised edits outside WP-F" the eight bench files (`BenchSyncCycle21.swift`, `BenchSyncJoinChains.swift`, `BenchSyncReroutePins.swift`, `BenchSyncRerouteTakeOff.swift`, `BenchSyncReroutes.swift`, `BenchSyncWaitersBound.swift`, `BenchSyncCycle22.swift` and `BenchSyncCycle22Purge.swift`) and any that cycle 23 adds, each with its helper types, citing 11.6 as amended above. Correct `s3f.md:8214` (reqs #6 cites `:8213`, a blank line) and `:8237-8238`, add the ARCHITECTURE §1.2 proposal (S3-R6), and point row `:6959` at the record;
     - item 5's `followedLane` record (S3-R27 item 5), which cycle 22 did not write (`s3f.md:6945`, `:7713-7714`), and reqs #10's stale records, updated to cite 12.1 and e1-R1's change (`s3f.md:7367`, the doc comment at `Tests/ZTronAssetKitBenchmarks/BenchSyncCycle21.swift:156-158`, and rr21-T8b's at `s3f.md:5750-5755`);
     - item 9's rows, items 7 and 8, and the "Proposed document changes" of cycles 21 to 23 (reqs #5; cycle 21's reqs #9, #10, #11 and #14);
     - the 12.x records: 12.2's, 12.3's, 12.5.9's and 12.5.18's, found by content where their lines moved.
   - **Item 9** applies on the final HEAD, with `9aa337c` in place of `d5b2ab9`. The cycle-22 dispositions ("Not reached and structural lines (cycle 22)", `s3f.md:7758-7788`) stay listed, updated where cycle 23 changes them.

5. *Order of work.* Commit each step on its own. Red first: S3-R27 item 10's red-first rules apply, with `9aa337c` in place of `d5b2ab9`. A named finding goes with its item. A stop is committed as item 8 says: the evidence, red first, then a status-list commit whose subject starts `PUT-BACK: item <n>: `.
   0. Run `verify.sh --quick` on `9aa337c`. Then measure before any fix, in the order that item 8's point 1 sets. First run item 1's step-0 shapes on `9aa337c`, and commit their table to the draft's status list; the orchestrator checks f1c's predictions against it (item 1, N21). Next, in a scratch copy of `9aa337c` under `.build-s3f/c23/`, take the 'before' figures, best of 3 with loads, of item 3's five new cases, and commit their table. Then the rest, here: S3-R27 items 3's and 4's cases take theirs on such a scratch copy (item 8's point 1). The twelve purge cases' 'before' figures are cycle 22's (item 3).
   1. Item 2: f2-R1, then A-T-SD's change on its own commit.
   2. Item 3, stage A: the red cases' commit, then each part, with the extended audit before C-2 and C-3, then every purge case's figures.
   3. Item 3, stage B and then stage C, each only if item 3's stage trigger fires, each followed by every purge case's figures. Stage B's extended audit comes before C-5.
   4. S3-R27's step 5: its item 3 (item 4 above).
   5. S3-R27's step 6: its item 4.
   6. S3-R27's step 7: the kills, the three unreached lines and reqs #8's guard.
   7. S3-R27's step 8: the records, then the close.
   - **Item 1b and item 3b** are each taken at the first step that starts after it is appended (item 6).
     - Item 1b: its red shapes first, then its route, then item 8's early probe (point 6). Until the prober reports, the fixer goes on only as item 8's point 3 allows after a stop.
     - Item 3b: its red cases first, then its route, and then every purge case's figures. Its natural place is after route C's stages, but item 3b names its place when it is appended (item 3).
   - **Steps 4 and 5 may come before step 2.** If item 3b is not in the rulings file when step 2 would start, the fixer does steps 4 and 5 first, then step 2 once item 3b is appended (item 3).
   - **Red cases across the cycle** (S3-R27 12.5.12, extended). From `9aa337c` to the close, the Benchmarks stage may stay red for every case already committed red that is not yet closed, or that is reported as a miss.
     - A miss is reported when the draft's status list lists it with its figure, its loads, and the item that routes it, or "no route in cycle 23".
     - Each commit message names the cases that are red at that commit.
     - Every other stage is green at every commit, except in two cases:
       - S3-R26 item 11's red-first commits, which may also carry those cases;
       - a stop's red test (item 8's point 3), which may stay red from its evidence commit until the orchestrator's ruling on the stop is carried out. Each commit message names it while it is red.
   - **The close** (step 7): item 9 and every gate on the final HEAD. Run `verify.sh --full` and quote its last line. A FAIL whose only causes are P-13 (WP-B's; S3-R26 item 10) and the cases reported as misses under "Red cases across the cycle" is reported as such (12.1), with each cause named from the benchmarks log. The misses stay blocking. Each of its other stages also runs and passes on its own.

6. *The budget.*
   - A fixer run may end at its working budget, or when item 8 leaves it no work it may do: after a stop, or while item 8's early probe runs. The next run continues from HEAD. So commit every step when it is done, and keep the draft's cycle-23 status list current, with item 7's mapping.
   - **Appended items.** At the start of every step, the fixer re-reads the end of the rulings file for items appended since (item 1b, item 3b, and the orchestrator's rulings on `PUT-BACK` commits, item 8). It takes each one at the first step that starts after it is appended, and the draft's status list records when each was taken.
   - Every agent keeps its command output short: it sends the output to a log file and reads the summary lines back.
   - The verifiers run lens 3's heavy checks first (reqs #7): Sync ×3, TSan, the iOS generic build and the iOS Simulator suite, the benchmarks and the mutants. Then the rest.
     - `sim.lock` is held for the simulator and coverage runs, and the release benchmarks run in a window with a 1-minute load of 10 or less, when one occurs. Otherwise the C2 rule's "not measured at a quiet load" applies (rulings :763).
     - These runs also re-measure the cycle-22 "closes" figures that reqs #7 left unproven (cycle 21's reqs #2 to #4: `commitTurns(.waitersStalledSubscriber)`, `commitTurns(.manyGroups)` and `purgeWhileOwedTurns`).
   - **Fixer hours** (estimates):
     - step 0's shapes, about 13-26 h (derived): f1b's 4-6 h for its step 0 (f1b §8), the f1b review's 4-6 h for the late drain and its new shapes (its "must add" 8), 3-6 h for f1's windows 8 to 10, at the f1 review's 1-2 h for each new shape (`f1-enospc-windows-review.md:122`, which "must add" 8 also uses), and about 2-8 h at the same rate for W-JOIN-HOP's owed-re-route and take-off variants (N23 4);
     - item 2, 2-3 h; item 3, 19-28 h; item 3b, 17-26.5 h (`f3b-review.md` §6); e1-R1's kills, 3.7-5.5 h of mutant runs (12.2);
     - item 1b is not in them. The f1b review puts f1b's route, as it corrects it, at about 38-59 h, step 0 included (its "must add" 8), up from f1's 12-18 h (16-24 h by its review) and f1b's 22-33 h.

     A cut-off inside the cycle is likely.

7. *The named findings.* The draft's cycle-23 status list keeps this mapping:
   - correct #1 and #2 → item 1, routed by item 1b;
   - correct #3 → item 2;
   - correct #4 and reqs #1 → item 3;
   - correct #5 and reqs #2 → item 4 (S3-R27's steps 5 and 6);
   - correct #6 and #7, and reqs #3 and #4 → item 4 (S3-R27's step 7, and the three unreached lines, `:1001` included). Reqs #3's e1-P1 mutants run there too, or with item 1b's kills if item 1b has rewritten their code by step 6 (item 4's kills);
   - reqs #5 and #6 → item 4 (the records);
   - reqs #7 → item 6;
   - reqs #8, #9 and #10 (not blocking) → item 4 (step 6's guard, the ownership rule, and step 7's records);
   - correct #8 (not blocking) → item 5's close: P-13 is WP-B's (S3-R26 item 10), its FAIL is reported as such, and WP-F edits nothing for it;
   - correct #9 (not blocking) → item 4 (S3-R27's step 6, the in-letter shapes' figures);
   - correct #10 (not blocking) → no action: its two residuals stay as the draft records them;
   - reqs #11 (not blocking) → item 6 (the quiet-load runs), with `commitTwoTokensTurns` kept on the margin list.

8. *Fail fast.* The owner asked on 6 Nov: "can we adopt a fail-fast policy? If the cycle is bound to fail let's not wait the 100h" (`s3f-c22-analysis/s3-r28-orchestrator-rulings.md:136`). This item binds the fixer and the verifiers from cycle 23 on, wherever earlier rulings, items 1 to 7 included, order the work otherwise.
   1. **Measure first, riskiest first.** Step 0 (item 5) measures on `9aa337c`, before any fix, in this order:
      - item 1's shapes;
      - item 3's five new cases' 'before' figures;
      - the rest.

      Commit each group's table as soon as the group is measured, so that the orchestrator can check it against the analyses while the fixer goes on.

   2. **Stop conditions.** Check them at the end of every part and every measurement:
      - (a) a route's last part, or its last triggered stage, is in, and its case is still above 10 ms, or its shape is still red in a way that blocks (item 1's "Which red shapes block");
      - (b) after a stage, a case is above 10 ms by more than the upper end of what the later stages and parts save on that case (f3 §3.2, and item 3b's estimates for its parts), so they cannot close it;
      - (c) a measurement contradicts the analysis that a route rests on: a shape the analysis calls green is red on the route's base, or a figure is above its estimate's upper end. For a step-0 'before' figure, the fixer commits the table and goes on, and the orchestrator's check (point 1) decides whether it is a stop;
      - (d) a fix needs a change that no ruling authorises;
      - (e) a part, stage or step that items 2, 3, 3b or 6 estimate takes more than 1.5 times the upper end of its estimated fixer hours. The status list times each one, from its start to its last commit.

      A figure above 10 ms that was seen only at a 1-minute load above 10 stops nothing until the rule at rulings :763 decides it.

   3. **On a stop:**
      - The fixer commits the evidence (the red test or the figures, red first).
      - Then it commits a status-list update whose subject starts `PUT-BACK: item <n>: ` and says what stopped, in one line.
      - It goes on only with work that does not depend on the stopped item, and it does not start the stages or parts that the stop makes useless. If no such work is left, it returns.
      - For a stop that the orchestrator's check or the early prober finds, the orchestrator rules it and says what the fixer commits.

   4. **The orchestrator:**
      - It watches `wp/s3f`, the branch of `.worktrees/s3f`, for `PUT-BACK` commits and rules each one between steps. Item 6's re-read at each step picks the ruling up.
      - When a blocking item has no route that an independent review calls sound, it tells the owner at once, with the evidence and the options, instead of letting the cycle run on.

   5. **Verification runs when it can pass.**
      - When the fixer returns with a blocking item known to be open (a stop, an item with no route, a blocking miss), the orchestrator does not run the two verifiers on that HEAD. It rules the item, then relaunches the fixer in the same cycle.
      - The two verifiers run when the fixer's status list shows every blocking item closed by its own measurements and gates. Item 6 sets the order of their checks.

   6. **Early probing of a risky route.**
      - This applies to a class whose analyses an independent review has found unsound twice or more, as with the ENOSPC windows: the f1 and f1b reviews found both analyses UNSOUND (`f1-enospc-windows-review.md:8`, `f1b-join-rule-review.md:11`).
      - As soon as that class's route is committed (item 1b's), one independent correctness prober (P4) tries to break it with new shapes, in both orders, and swept first in both drain timings (item 1). Until it reports, the fixer goes on only as point 3 allows after a stop.
      - A red found then is a stop under 2(c).

   7. **Re-forecast at every wake-up,** in hours and weekly %. When the routed work cannot finish before the weekly limit, take blocking items first, then kills, then records.

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

### S3-R28, the owner's close ruling (appended 2026-11-06 17:12): WP-F ends with option (e), a short close

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
