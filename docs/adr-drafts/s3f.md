# Stage 3 close-out `s3f` — WP-F (sync engine), cycles 1 to 12

Branch `wp/s3f` from tag `s3-base`. Rulings: `.build-orchestrator/s3-rulings-s3f.md`; findings:
`.build-orchestrator/s3-findings-s3f.json`. WP-F's Stage 2 record is `docs/adr-drafts/f.md` (background only).

## Orchestrator rulings (close-out)

Each ruling below is recorded as given in the rulings file and applied in cycles 1 to 3. Cycle 2 applied them again to
the cycle-1 verifiers' findings (the section "Cycle 2" below), and cycle 3 to the cycle-2 verifiers' findings (the section
"Cycle 3"); no ruling changed, and no new ruling was issued, so S3F-13 is implemented rather than demoted. In cycle 3 the
rulings file was re-read: S3-R1 (the blocking finding first, its failing test committed on its own before the fix),
S3-R2 (the probes PROBE-W1 and PROBE-W4/W4b renamed into `EngineFollowTests`), S3-R3 (every mutant re-applied in place,
rebuilt, run and reverted), S3-R4 (the hang guards re-measured, below), S3-R5 (the fix keeps the follow's per-turn bound:
a queue head waiting for the follow is left in place, not followed by the pump), S3-R6 and S3-R7 (only WP-F's files and
this draft changed) and S3-R8 (P-13 stays `other-wp:b`). In cycle 4 the rulings file was re-read again (no ruling changed or
was added): S3-R1 (the blocking correctness finding's failing test `996ac21` committed before its fix `c8f01ca`), S3-R3
(the fix's two hooks each removed in place and shown to fail the new test), S3-R4 (every hang guard over half its limit
beside a second TSan process at a load at most about 30 raised to `.minutes(3)` with its measurements; the S1-15 run test,
which is neither model-based nor exhaustive, stays at `.minutes(3)` over half of it, and a ruling is requested below),
S3-R5 (the probe-chain benchmark passes C2 at 10,000 on a quiet host), S3-R6/S3-R7 (only WP-F's files and this draft) and
S3-R8 (P-13 and the store's per-404 index commit routed `other-wp:b`). In cycle 5 the rulings file was re-read again: no ruling changed
or was added, and at that time it held no ruling on the S1-15 run test's guard (requested in cycle 4), so that guard stayed
`.minutes(3)` (S3-R4 reserves `.minutes(5)` for model-based or exhaustive tests) and the request stood; S3-R1 (the
blocking correctness finding's failing test `04ae782` committed before its fix `e18d5aa`), S3-R3 (each branch's budget
removed in place and shown to fail the new test), S3-R5 (the fix bounds the sweep's follows per turn, pinned by a
structural test and a `c2Budget` benchmark), S3-R6/S3-R7 (only WP-F's files and this draft) and S3-R8 (P-13 and the
per-404 index commit stay `other-wp:b`). The statement that no ruling exists on that guard is no longer true: the
orchestrator added **S3-R10** to the rulings file on 2026-10-30 (the file was saved at 03:00:55, after cycle 5's last
commit `39dadd4` at 01:18:56), and cycle 6 applies it. In cycle 6 the rulings file was re-read: S3-R1 to S3-R9 are
unchanged and S3-R10 is new; applied: S3-R1 (the blocking correctness finding's failing test `48c8dfc` committed before
its fix `b94fd27`), S3-R2 (PROBE-C5-LANEDROP renamed into `EngineFollowTests`), S3-R3 (the fix's re-judgement and the
sweep's park bound each mutated in place and shown to fail a test), S3-R4/S3-R10 (S1-15's run test guard raised to
`.minutes(5)`, nothing cut, figures recorded; the other guards re-measured), S3-R5 (the re-judgement is O(1) per
re-queued job; the cycle-5 C2 benchmark re-run), S3-R6/S3-R7 (only WP-F's files and this draft) and S3-R8 (P-13, the
per-404 index commit and the Storage time-outs at load 100–540 reported `other-wp:`). In cycle 7 the rulings file was
re-read (unchanged since 03:00:55; S3-R10 is still the last ruling, and none answers the cycle-6 hang-guard margins):
applied: S3-R1 (the blocking correctness finding's failing test `69e209e` committed before its fix `22c7b89`), S3-R2
(PROBE-C6-LANEGAIN, PROBE-C6-READDROP and PROBE-C6-PARKFIGURES renamed into `EngineFollowTests`), S3-R3 (the cycle-6
survivors `skipNotFit` and `requeueNoAhead` re-applied in place and shown to fail the strengthened test), S3-R4 (every
one-minute Sync test over half its guard beside a second TSan process raised to `.minutes(3)` with its measurements,
nothing cut), S3-R5 (the fix adds one O(1) `spaceBlock` per parked job the sweep follows), S3-R6/S3-R7 (only WP-F's
files and this draft) and S3-R8 (P-13, the per-404 index commit and the Storage figures stay `other-wp:`). In cycle 8
the rulings file was re-read (unchanged since 03:00:55; S3-R10 is still the last ruling, and none answers the hang-guard
requests of cycles 7 and 8): applied: S3-R1 (the blocking correctness finding's failing tests `18e9448` committed before
its fix `1b771e8`), S3-R2 (PROBE-C7-RANK-ADMIT, -PARK, -PROMOTE and PROBE-C7R-GAIN-AHEAD committed as R-SYN-11 tests in
the new `EngineSweepOrderTests.swift`, an extension of `EngineSyncTests`), S3-R3 (four mutants of the fix and the
re-queue's `ahead` count re-applied in place and shown to fail a test), S3-R4 (the four new tests' guards sized from
paired measurements; the two margins over half at a paired load of about 30 referred to the orchestrator again, nothing
raised or cut), S3-R5 (the sweep's follows keep their `followsPerTurn` bound; the C2 benchmark re-run), S3-R6/S3-R7
(only WP-F's files and this draft) and S3-R8 (P-13 stays `other-wp:b`). In cycle 9 the rulings file was re-read: it now
ends with S3-R12 (09:50), S3-R11 (12:50) and S3-R13, recorded below and applied in cycle 9 ("Cycle 9" below); S3-R1 to
S3-R10 are unchanged. Applied: S3-R1 (S3-R11 item 6's tests `7626a07` committed failing at `40ecd95` before the design
`02d51a0`, and each amendment's failing test before its fix), S3-R2 (the design panel's and verifiers' probes committed
as R-SYN-11 / R-SYN-2 / R-SYN-3 tests in the new `EngineFollowBarrierTests.swift` and in `EngineSweepOrderTests.swift`,
waits adapted, assertions kept), S3-R4/S3-R12 (three guards raised one step with their figures; the new tests' guards
measured), S3-R5 (three new C2 benchmarks), S3-R6/S3-R7 (only WP-F's files and this draft; `Package.swift` untouched,
S3-R13 checked in an export) and S3-R8 (P-13 and the Storage benchmarks stay `other-wp:b`).

- **Orchestrator ruling (close-out) S3-R1, scope and order.** Blocking items first (failing test committed on its own,
  then the fix), then REQUIRED, then OPTIONAL; ADR-RECORD items get an entry here and no code; items not listed are out
  of scope. Applied: S3F-1 to S3F-5 first, each test commit before its fix commit.
- **Orchestrator ruling (close-out) S3-R2, probes.** Probes and mutant diffs are evidence to copy and adapt; committed
  tests follow SPEC 7.2 (requirement-ID display names, `.timeLimit` on anything that awaits, `ManualTimeSource`, no
  sleeps) and the iOS gating convention (ADR-051, `docs/adr-drafts/ios.md` item 2); probe suites are renamed into the
  owning suites; replays of a bug's old order are not committed. Applied: every new test is an extension of an owning
  suite (`EngineConditionsTests`, `EngineFailurePathTests`, `EngineEventsTests`, `EngineLaneTests`, `EngineSupportTests`,
  `EngineRecoveryTests`, `EngineGroupClaimTests`, `EngineIdleTests`, `EngineSyncTests`, `EngineRegressionTests`), every
  test that uses a Mutex-backed fake carries `@available(macOS 15.0, iOS 18.0, *)` on the `@Test` function.
- **Orchestrator ruling (close-out) S3-R3, mutation survivors.** Each surviving mutant assigned here has a test, and the
  mutant's diff was re-applied in a scratch copy (`.build-s3f/mut/src`, its own build path) to show the test fails; the
  failing lines are pasted under each item.
- **Orchestrator ruling (close-out) S3-R4, hang guards.** `.minutes(1)` by default; raised to `.minutes(3)` (or
  `.minutes(5)` for a model-based walk) only for a test measured above half its limit under TSan on a moderately loaded
  host, with the measurements recorded; never by cutting work; long loops check cancellation. Applied in S3F-2.
- **Orchestrator ruling (close-out) S3-R5, C2 at the reference scale.** A turn over 10 ms at 10,000 is fixed by bounding
  the work per turn or moving computation off the actor, pinned by a `c2Budget` benchmark in `BenchSync.swift` and, where
  possible, a structural unit test; a miss caused only by load is not blocking. Applied in S3F-4, S3F-5 and S3F-15.
- **Orchestrator ruling (close-out) S3-R6, shared files.** No public or package signature change; no edit of
  `Package.swift`, `Scripts/`, `SPEC.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/TRACEABILITY.md`,
  `docs/ORCHESTRATION.md`, `README.md`, `docs/MIGRATION.md` or any `*ContractTests.swift`; document changes are proposed
  below. Applied: none of those files changed (the backoff tests the mutation agent suggested for
  `SyncContractTests.swift` live in `EngineBoundaryTests.swift`).
- **Orchestrator ruling (close-out) S3-R7, parallel close-outs.** Only WP-F's files (ARCHITECTURE §1.2), nothing that
  depends on another work package's Stage 3 change. Applied: every changed file is under `Sources/ZTronAssetSync/**`,
  `Tests/ZTronAssetSyncTests/**`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` or this draft.
- **Orchestrator ruling (close-out) S3-R8, strict bar.** Findings in another work package's files are reported
  `other-wp:<wp>:`; pre-existing behaviour an ADR accepts is not a finding unless it breaks a MUST the record did not
  consider.
- **Orchestrator ruling (close-out) S3-R9, records.** This file: one entry per item, then "Authorised edits outside
  WP-F", "Proposed document changes" and "Not verified here".
- **Orchestrator ruling (close-out) S3-R10 — Orchestrator ruling (Stage 3), added 2026-10-30: S1-15's run test hang
  guard.** `R-SYN-3: a 100,000-entry plan never materialises more than the pipeline plus the lookahead as jobs`
  (`EngineSync1LivenessTests.swift`, `runMaterialisesAPipelineAtATime`) may take `.timeLimit(.minutes(5))`: its cost is
  the SPEC-mandated scale (S1-15's 100,000-entry catalog) decoded by WP-A's parser under TSan, not WP-F's own work
  (101.8–130.1 s beside a second TSan process at load 10–32, 34–43 % of 5 minutes; 47.5–72.3 s alone). Every entry,
  operation, assertion and cancellation check stays (G3), and the figures go in the test's doc comment and here. The
  parser's sanitizer cost is not a defect (a release build decodes the manifest in well under a second): it is recorded
  as a note for Stage 5's residual risks, with no WP-A change. Verifiers judge the guard by S3-R4's rule against 5
  minutes: blocking only if the test exceeds half of 5 minutes at a load of about 30 or less, or if the raise came with
  any cut to the test. Applied in cycle 6 (`daa2ba8`; "Cycle 6" below).
- **Orchestrator ruling (close-out) S3F-1 to S3F-17.** The per-item rulings are quoted at the head of each entry below.
- **Orchestrator ruling (close-out) S3-R12 — added 2026-10-30 09:50: hang-guard margins, how load is read, what is
  blocking, and the raises now.** Supersedes S3-R4's load reading for WP-F; S3-R4's steps and G3 stand. (1) The load of
  a TSan run is the mean of the 1-minute load average sampled every 5 s or less, from 60 s after the later bundle's start
  to the earlier bundle's end; the samples' mean, min and max go with every figure. (2) A margin is blocking only if a
  test times out in a run whose mean is 50 or less, or exceeds half its guard in a paired run whose mean is 30 or less;
  every other margin is recorded. (3) Raises now: `stalledSubscriberIsBounded` `.minutes(4)` → `.minutes(6)` (133.0–133.8
  s, 55.7 %); the R-SYN-14 migration-loop wait (`EngineLegacyMigrationTransferTests.swift:751`) `.minutes(3)` →
  `.minutes(5)` (89.0–90.2 s); the R-SYN-6 owed re-queue (`EngineRegressionCycle16Tests.swift:33`) `.minutes(3)` →
  `.minutes(5)` (88.9–91.0 s); S1-15's run test stays `.minutes(5)` (146.3–147.1 s, 49 %). Nothing is cut; figures in
  each test's comment and here. (4) The 29 one-minute tests at 50.3–55.0 % in the cycle-8 verifier's pair2
  (`.build-orchestrator/s3f-probes-c8/reqs/logs/pair2-1min-overhalf.txt`) are not raised: recorded as non-blocking.
  Applied in cycle 9 (`0f21af8`; "Cycle 9" below).
- **Orchestrator ruling (close-out) S3-R11 — added 2026-10-30 12:50 (owner go-ahead "Launch on D3"): the follow
  barrier, design D3 "root" with the judges' amendments.** A decision taken while a follow is owed must equal the
  decision taken when the follow visits first. (1) The rule, stated as an invariant and in the docs: while a follow is
  owed nothing is admitted and no space verdict is given (no pump start or space park, no space sweep judgement, no
  join's or promotion's re-check or fail-fast of a space-parked job, no ENOSPC verdict); space sweeps drive the follow
  (`advanceFollowForSpaceSweep`) and judge in a later turn; no second cursor; deferred events wait in arrival order and
  are replayed after the follow's last turn and its pump, at most 512 per turn, the run settling only after them; 1b771e8's
  pre-phase goes. (2) Amendments, each fixing a defect with a failing test first: (a) `.enqueue(TransferID, front:)`,
  replayed keeping `queuedAt`, and `reinstate` through the event list; (b) the "queued jobs wait in no queue" invariant
  exempts exactly the transfers with a pending place (a counted set equal to the events'), plus the rule that events
  wait only while a follow is owed, a drain is scheduled or one is in progress; (c) a failure of a job that still holds
  a moved id becomes `.attemptFailed`, the job leaving flight `.failed(.nextRun)` with no answer, the follow's own visit
  moving its ids in order and the drain replaying the verdict epoch-checked; (d) the pump barred on the barrier, not only
  on `followOwed`, the drain's last batch pumping; (e) a second apply inside an owed follow keeps `followOrder[followNext...]`
  in order and appends the newly unfollowed jobs sorted; (f) a `BenchSync` C2 benchmark of the follow's last turn plus
  the drain's first batch at 10,000. (3) R1: real-world ledger inputs (freed bytes of an ended transfer, free-space
  reads) apply on arrival (L4-R7 kept); D3's `.read` deferral is dropped; PROBE-D2-READ-ORDER, PROBE-D3-READ-PROMOTE and
  PROBE-J-UNRELATED-FREE are outside the class (committed as on-arrival tests or recorded); a difference caused only by
  such an input is non-blocking. (4) R2: `EngineFollowTests` :456 `between.steady == .downloading` becomes `.queued`;
  the admission wait during a multi-turn follow (131–143 ms at 10,000, macOS release) is a Stage 5 residual; §7.10
  "Follow barrier (F-28)" and the F-28 text "decided on the followed state" are proposed here. (5) R3: D3's one-to-one
  assertion replacements in `EngineFollowTests.swift`, and R2's, are authorised, each recorded one-to-one. (6) The tests
  committed failing first at `40ecd95` (the cycle-8 issues, D3's, D1's, D2's and the judges' probes, and new ones for
  (a) and (e)), both orders, duplicates merged. (7) C2: cycle 8's regression must be gone; VERIFY-C8-C2-MIXED and D3's
  drain probe become `BenchSync` benchmarks beside `reclaimDuringFollowTurns`, plus (f). (8) Hang guards: S3-R12.
  Applied in cycle 9 ("Cycle 9" below).
- **Orchestrator ruling (close-out) S3-R13 — added 2026-10-30 (owner requirement): tools 6.4 with 0 warnings.** The
  package builds and tests with 0 warnings when `Package.swift`'s first line is `// swift-tools-version: 6.4`; the
  committed manifest stays at 6.0 and the iOS 15.0 floor stays; nobody edits `Package.swift`; the fixer checks in an
  export (`git archive HEAD`, line 1 set to 6.4, `swift build --build-tests -Xswiftc -warnings-as-errors`, `grep -c
  'warning:'`). Applied in cycle 9 (figures under "Gate evidence (cycle 9)") and cycle 10 ("Gate evidence (cycle 10)").
- **Cycle 10: no new ruling.** The rulings file still ends with S3-R11 to S3-R13; cycle 10 applies S3-R11 item 3 and R1
  to the cycle-9 findings, S3-R12 to the TSan run and S3-R13 to the export ("Cycle 10" below).
- **Orchestrator ruling (close-out) S3-R14 — added 2026-10-30 17:55, before cycle 11: close the follow-barrier class by
  inventory, not one probe at a time.** (1) Before fixing, a table under "Cycle 11" lists every site in
  `Sources/ZTronAssetSync/Engine/` that takes a decision (admits, starts, parks, answers a user, fails fast, or reads a
  job's lane, rank or queue place to decide one), whether it can run while the barrier holds (`followOwed`, a scheduled
  drain, or a drain in progress), and how it waits (which event, replayed where) or why it is outside the class under
  S3-R11 item 3 (R1: only bytes freed by an ended transfer and free-space reads); verifiers check it against the code,
  and a missing site or a wrong row is blocking. (2) In the class, blocking, failing test first in both orders, then the
  fix: `answerThrottledUsers` during the barrier; `pauseIfRefused` and `paused`'s park on the pre-visit lane; `readmit`'s
  places and the no-Retry-After throttle delay on pre-visit ranks and lanes; the `.edge` events placed before the same
  edge's re-admissions; a visit re-lane of a job whose place waits; amendment (e) with an incomplete old pass (hold the
  unfollowed-but-not-owed jobs until the old scans end). The network edge and the origin's throttle signal still apply
  on arrival; the decisions taken from them about a job whose verdict waits are in the class. (3) A withdrawal that
  overtakes a deferred answer is in the class: the engine's interest removal and any transfer cancellation it causes
  wait in arrival order; the public layer may answer the cancelled caller at once (R-SYN-4, R-SYN-10); assert both, and
  that no transfer runs for nobody once the drain ends (R-CAR-4). (4) The `.relane` replay and `replayJoin`'s re-route
  (0 hits) each get a test that fails when the branch is removed, with the mutant shown failing. (5) The survivors
  `noDispatchOwedFlag` and `noFlagPump`: killed by a test, or recorded with a probe's output as equivalent. (6) Hang
  guards, C2, S3-R12 and S3-R13 unchanged; new tests in the serialized `EngineFollowBarrierTests` /
  `EngineFollowBarrierVerdictTests` suites. Applied in cycle 11 ("Cycle 11" below).
- **Orchestrator ruling (close-out) S3-R15 — added 2026-10-30 23:30, before cycle 12 (S3-R1 to S3-R14 still apply):
  one view of the world per decision instant.** A deferred decision, or a follow visit, read the non-ledger real-world
  inputs (origin throttles and their ends, the conditions, the network edge) as the drain left them, not as they stood
  at the decision's visit-first instant. Fix the root, not each probe:
  1. While the barrier holds, every replayed decision reads each non-ledger input as it stood at that event's arrival,
     and a follow's visit reads it as it stood at the apply. One mechanism for every replay and visit; `.conditions`
     and `.readmit`'s `withConditions` fold into it. Invariant: after the drain's last batch the history is empty, and
     the live state is what arrival-order application gives. R1's ledger inputs (bytes freed by an ended transfer,
     free-space reads) are unchanged.
  2. A 429 throttles its origin on arrival, with or without Retry-After, so readers that are not replays (the manifest
     fetch of unknown-id waiters, `ensureAvailable`, a pending run's start) see it at once. The backoff uses the lane
     the owed visits will leave the job, computed from the interests whose ids the copy still maps to this transfer,
     without performing the visit. `replayThrottle` only re-parks and answers. A lane that cannot be derived is shown
     with a probe and recorded, not guessed.
  3. In the class (blocking; failing test first in both orders, then the fix): R-A (PROBE-C11-COMMIT-PLACE: the
     publication or commit outcome of a job that holds a moved id waits as an event); R-C (the sweep's place among
     drained events); R-D (covered by item 1); PROBE-C9-THROTTLE (R2 accepts admission latency only, not a different
     answer); JOIN-THROTTLE-END, JOIN-THROTTLE-EXT, MANIFEST-THROTTLE, and THROTTLE-LANE read right after the 429.
  4. R-B: circuit-breaker decisions (opening, half-open probes, refusals) are in the class. Pure metric counters that no
     decision reads are outside it, listed in the inventory with that reason.
  5. R-E, the store-work stall, is a liveness defect independent of the barrier class until shown otherwise. Reproduce
     it and date it at `5203ccb`, `40ecd95` and `s3-base`. If its root is in WP-F's files: a failing test, then the fix;
     if in another work package's: `other-wp:<x>` with the evidence. `noDispatchOwedFlag` is observable, so its killing
     test is committed once the stall no longer blocks it, without shortening or weakening the scenario.
  6. Every replay branch that `6cc4d92` and cycle 12 add is reached by a test in the serialized barrier suites, in both
     orders, asserting the visit-first outcome, with a mutant dropping the branch failing 2/2, or it is removed with the
     reason. A branch counted as Fixed but reached by no test is blocking.
  7. Correct the inventory rows I12, I14, I26, I35 and the R-A rows; every row cites its test or probe, and the table
     stays current with every change.

  Applied in cycle 12 ("Cycle 12" below). **Not closed:** item 3's R-C, and under item 6 nine replay branches and
  three world-view reads that no test kills. Both are recorded there as open with their analysis.
- **Orchestrator ruling (close-out) S3-R16 — added 2026-10-31 (owner decision, 31 Oct: "Narrow the bar"): the
  follow-barrier class, the bar is observable correctness.** Cycles 5–12 did not converge on exact visit-first
  equivalence, and cycle 12's fix broke R-SYN-5 (R-I). It supersedes S3-R11 item 3's "Every other decision that differs
  is blocking" and the "in the class (blocking)" lists of S3-R14 items 2–3 and S3-R15 item 3 where they conflict;
  everything else in S3-R11 to S3-R15 stands, R1 included, and G3 holds except as item 4 allows.
  1. Blocking, in either `LaneDropVisit` order: (a) a different answer (success against an error, different content or
     bytes, a different error case; values inside one case and R1's on-arrival inputs excluded); (b) a broken SPEC MUST
     or invariant (`invariantViolations()`, `followBarrierViolations()`), named: R-SYN-5 (no request to an origin whose
     throttle or open breaker is live; a 429 throttles its origin on arrival; the `.undecided` outcome is blocking, the
     backoff's length is not), R-SYN-11 and space safety, R-SYN-4 and R-CAR-4; (c) liveness; (d) flakiness, this
     cycle's own tests included; (e) G4 for code that stays: every replay or deferral branch is reached by a test that
     kills its drop-mutant 2/2, or removed with the reason; (f) the gates (C2, hang guards, S3-R13, `verify.sh`).
  2. Non-blocking, recorded under "Residual risks (S3-R16)" with probe and figures: a difference only in start or
     dispatch order, queue place or ticket, when an answer arrives within the barrier and its drain, or backoff and
     Retry-After lengths (which lane's backoff applies included), while item 1 holds.
  3. Simplify where the narrowed bar allows: machinery that only makes order, place or timing equal may be removed,
     especially where it breaks item 1 (place stamps admitting on a past view, R-I). Admission and requests always read
     the live throttle, breaker and slots. Removal is preferred to new branches; each names the branches and tests it
     affects.
  4. A committed barrier test whose assertion is only about order, place or timing and which an item-3 removal breaks
     may be changed one to one to the narrowed property (answers equal visit-first's, MUSTs and invariants hold, the job
     ends where visit-first's ends), recorded with old and new assertion and reason. No test is deleted; no scenario or
     operation is lost; answer and MUST assertions are never changed.
  5. Cycle 12's findings: blocking — the hang of `barrierRetriesBehindTheOwedVisitsPlaces`, R-I (PROBE-C12-PLACE-SLOT),
     PROBE-C12-UNDECIDED-LANE, every surviving mutant and 0-hit branch, inventory rows wrong about an answer, a MUST or
     an invariant; probe first (blocking only if item 1 breaks) — a follow visit removing a verifying or committing job
     while the store publishes, the R-A integrity remainder, R-F and R-G; non-blocking — PROBE-C12R-FOLLOWED-LANE's
     backoff length, R-C unless a probe shows a different answer, uncited rows that are not wrong.

  Applied in cycle 13 ("Cycle 13" below). One conflict inside the ruling is put back to the orchestrator there: two
  committed answer assertions (PROBE-C9-THROTTLE, R-B) encode the admission on a past view that items 1(b) and 3
  remove.
- **Orchestrator ruling (close-out) S3-R17 — added 2026-10-31 12:45 (answers the cycle-13 fixer's put-back): when
  S3-R16 1(a) and 1(b) conflict, the MUST wins; live origin gates join R1.** PROBE-C9-THROTTLE
  (`barrierAdmitsTheFollowsNewContentAsAtTheApply`) and R-B (`barrierAdmitsARequestOnTheBreakerAtItsArrival`) can give
  the visit-first answer only by admitting on a past view, a request to an origin whose throttle or open breaker is
  live, which breaks R-SYN-5 (1(b)).
  1. *Rule.* A SPEC MUST is never broken to equal visit-first. Where they conflict, the engine decides on the live state
     and gives the correct SPEC answer for that state (`serverUnavailable(retryAfter:)` for a live throttle; a park and
     retry where the SPEC says so). The difference from visit-first is non-blocking and recorded as a residual risk
     (S3-R16 item 2) with its probe.
  2. *R1 widened to the live origin gates.* R1's real-world inputs also include the origin's throttle and its end, the
     circuit breaker's state, and network reachability or conditions, as the engine sees them when it decides. An answer
     difference caused only by such an input changing during the barrier is non-blocking, in either direction. This
     covers the suspected offline join (a residual risk; no probe needed). Conditions: the answer is the correct SPEC
     answer for the live state at the decision; every MUST and invariant holds; the replays that stay keep their
     arrival-instant reads where they exist, unless removing them is a simplification under S3-R16 item 3 (recorded).
  3. *G3.* The cycle-13 fixer's one-to-one changes of the two sweep-first answer assertions to the live gate's answer
     are authorised, as an exception to S3-R16 item 4. The visit-first assertions in both tests stay unchanged. No other
     answer assertion may change under this exception.
  4. *Verifiers.* Those two changes, and an answer difference covered by item 2, are not blocking. A broken MUST, a
     wrong SPEC answer for the live state, or an answer difference with any other cause is.

  Applied in cycle 14 ("Cycle 14" below): the two changes are confirmed, RR-7 is recorded as S3-R17 items 1 and 2
  describe it, and the stamp's breaker refusal is removed (item 2: the breaker is a live origin gate).
- **Orchestrator ruling (close-out) S3-R18 — added 2026-10-31 16:30 (cycle 14's verification and the cycle-14
  fixer's put-backs): place stamps go; a passed publication re-routes its moved ids at once.** The cycle-14 verifiers'
  five blocking items fall in three groups: the place stamp's slot view (PROBE-C14C-STAMP-AHEAD), the passed-publication
  mark (PROBE-C14C-MARK-TWO-APPLIES, PROBE-C14C-PASSED-LANE, PROBE-C14R-PASSED-LANE, PROBE-C14R-PASSED-FAIL), and G4 for
  `followedLane`'s new branches.
  1. *Place stamps are removed (S3-R16 item 3, S3-R17 item 2).* The barrier-end pump admits every place on the live
     throttle, breaker and slots, and on nothing else. The stamp's throttle refusal, `freeSlots`, and every branch, flag
     or invariant that exists only for them go; the draft names each removal and the branches and tests it affects. An
     answer difference this causes is caused only by a live origin gate changing during the barrier: non-blocking under
     S3-R17 item 2, recorded as a residual risk. *G3, an exception like S3-R17 item 3:* a sweep-first answer assertion
     that expects a stamp's past view may change one to one to the live gate's correct SPEC answer, the scenario, its
     operations and every visit-first assertion unchanged; the draft lists each change (test, old assertion, new
     assertion, this ruling). No other answer assertion changes.
  2. *A passed publication re-routes at once (S3-R16 1(a) and item 3).* The passed-publication answer differences are
     blocking, and RR-1's remainder is not a residual risk. Preferred fix: where `follow` passes a verifying or
     committing job whose publication began at or after the visit's apply, it re-routes the moved ids' interests to
     their new content at once, leaving the job's bytes, ledger entry and publication untouched. The `publishedAfterApply`
     mark, `followPassedPublication`, the parts of `followedForVerdict` that serve it, and `followedLane`'s skip of
     publishing jobs go. Fallback, only if a probe shows the re-route breaks a MUST or an invariant: per-pass id lists.
     The four cases the verifiers named (the 429 and the 404, each behind the barrier and after the drain) and the
     two-applies case are tests in both orders; whatever stays in `followedLane` is killed or removed (1(e)).
  3. *Put-backs.* The nested-drain re-entrancy change (cycle-13 finding 11) is accepted as non-blocking and recorded as
     a residual risk with its reason. `failureMoveBehindBarrier` is moot if item 2 removes the mover. RR-2 and RR-4 are
     probed if the cycle has room, otherwise left marked. Routing P-5, P-13 and P-9 to their benchmark owners is
     accepted.
  4. *Verifiers.* Judge by items 1 to 3. A request to a gated origin, a wrong SPEC answer for the live state, a liveness
     gap, or an answer difference with any cause other than a live origin gate changing during the barrier is reported.

  Applied in cycle 15 ("Cycle 15" below).
- **Orchestrator ruling (close-out) S3-R18a — amendment to S3-R18, added 2026-10-31 16:42 (before run 5's cycle-15
  fixer).** Cycle 15 starts again under S3-R18 in run 5.
  1. *Two applies.* Item 2's re-route must also be right when a later apply lands while the earlier apply's follow
     still owes the publishing job's visit: only the ids moved as of the apply the publication began after are
     re-routed; ids a later apply moved while the job already published are passed, as in visit-first. The case is a
     test in both orders, next to MARK-TWO-APPLIES.
  2. *Inputs.* `wip/s3f-c15a` (`5a87864`) holds the stopped fixer's unfinished tests, reused where they fit (its
     SlotTests fix-by-counting is ruled out by item 1; its scenario is the STAMP-AHEAD test). The findings are
     `.build-orchestrator/s3f-c14-issues.json`, the probes `.build-orchestrator/s3f-probes-c14/`.

  Applied in cycle 15 ("Cycle 15" below): the ids are recorded when the publication begins (`Job.rerouteOnPass`).
- **Orchestrator ruling (close-out) S3-R19 — added 2026-10-31 18:36 (cycle 15's put-backs; written while the cycle-15
  verifiers ran, before the cycle-16 fixer).**
  1. *A verdict that waits across a later apply* and *the publication failure's await window* (cycle 15, "Put to the
     orchestrator").
     - Probe first. Each is blocking only if a probe in both `LaneDropVisit` orders shows S3-R16 item 1 broken: a
       different answer, a broken MUST or invariant, or liveness.
     - If the probe shows it, prefer the smallest fix. For the first item, a verdict that arrived before a visit's apply
       leaves the job to the verdict, so that visit passes it. This is the comparison the fixer named, and it is
       allowed: it replaces the per-verdict `published` flag rather than adding a parallel mechanism.
     - If no probe shows it, record it as a residual risk with the probe and its result.
     - A cycle-15 verifier that has already probed either one decides it by this item.
  2. *`laneJobsWalkAlways`.* A mutant that changes only cost, not any decision, answer or state, is equivalent for G4
     (S3-R16 1(e)). No drain-turn seam is required.
     - The draft records the equivalence argument: the walk's result when the guard is false.
     - The guard's cost is covered by C2 (S3-R5). If the C2 margin for `followedLane` is not measured anywhere, record it
       as unmeasured in the draft; it is not blocking.
  3. *`spaceFailureEpochDropped`.* A defensive check that no path reaches is not left unkilled (1(e)). Do one of two
     things: remove it, with the reason in the draft; or turn the condition it guards into an `invariantViolations()`
     clause that a test exercises. If the check predates Stage 3 and lies outside the follow-barrier class, the third
     option is to record it as pre-existing and out of class; it is not blocking.
  4. *RR-2, RR-4 and RR-10 unprobed:* not blocking.

  Applied in cycle 16 ("Cycle 16" below): both items of 1 were probed by the cycle-15 verifiers and are fixed by the
  comparison item 1 names (`Job.attemptEnd`); 2's guard is now cost-only, and the decision it guarded is killed through
  a drain-turn seam; 3's check is reached (the verifiers' probe) and kept, with that probe as its test. Item 3's rule
  also settles three of cycle 16's own survivors: `followedLane`'s epoch filters are removed (cost-only, `e67f467`),
  `start`'s resets are checked by an `invariantViolations()` clause a test exercises (`e9960ef`), and the visit's
  supersede of a passed failed job is killed by a claim that would keep the job (`c161818`, `d3242d3`).
- **Orchestrator ruling (close-out) S3-R20 — added 2026-11-01 02:34 (the cycle-17 fixer's put-back on `bringInbound`'s
  C2 cost; written while the cycle-17 fixer ran, before its verifiers).**
  1. `bringInbound` makes all its moves in one turn, the attempt's end. The fixer's scratch release figure was about
     400 ms with 10,000 ids converging on one content, which breaks C2 (CLAUDE.md C2; S3-R5's budgets).
     - C2 is a standing order: the orchestrator cannot waive it; only the owner can, explicitly.
     - Until the owner does, the breach is blocking (S3-R16 item 1: a broken MUST, and the gates).
  2. Verifiers measure the breach with a BenchSync release case: 10,000 ids, held by other jobs, that the copy maps to
     one content whose attempt ends while the follow is owed. They report the best of 3 with the load and judge it by
     C2 and S3-R5; a scratch figure settles nothing either way.
  3. A fix keeps every turn within C2 and changes no answer (S3-R16 item 1). For example, the moves continue over
     bounded turns, as the owed follow's visits do, while the job's end and every later event wait, as events already
     wait while a follow is owed. The order, place and timing differences the fix makes are not blocking (S3-R16 item
     2). Its walk and its moves each get a BenchSync case.

  Applied in cycle 18 ("Cycle 18" below): the walk records the moves, and the follow's turns make them.
- **Orchestrator ruling (close-out) S3-R21 — added 2026-11-01 04:46 (the cycle-17 fixer's put-backs and cycle 17's
  verification; written while the cycle-18 fixer ran, before its verifiers).** The owner decided on 1 Nov at 02:39:
  "No, keep fixing". C2 is not waived.
  1. *The owed follow's own turns in the 10,000-member concentration shape.* Both cycle-17 verifiers measured the
     longest turn at 17.7 to 19.1 ms, at a load of about 5.
     - The shape is inside C2's reference set (S3-R5, S3F-5, S3-R20), so the breach is blocking. Option (c), ruling the
       shape outside C2, is not available.
     - The fix: join in place (option (b)), so each join is O(1) amortised with no live copy of a `Job` or
       `JobInterest`. Where a turn still exceeds C2, also bound the turns by the work done (option (a)).
     - Pinned by a BenchSync release case: best of 3, at most `SyncBenchmarks.c2Budget`.
  2. *`bringInbound`.* S3-R20 applies unchanged and is recorded in the draft (above). In-place joins may shrink the 408
     to 432 ms measured, but a figure over C2 at 10,000 still needs bounded turns (S3-R20 item 3).
  3. *PROBE-C17-ADMIT-DURING-APPLY.* An admission that races an older apply omitting the id is answered `notFound`.
     Visit-first gives the same answer, both rules predate s3-base, and no barrier is involved: outside the
     follow-barrier class and pre-existing, as in S3-R19 item 3, so not blocking and not fixed in this close-out. It is
     recorded under the residual risks with the probe, its seed, its figures and the two options, and marked for the
     owner in Stage 5's RESIDUAL-RISKS: it gives a wrong `notFound` under a race.
  4. *RR-14* is proven by both verifiers, so it is blocking (S3-R16 item 1(a)). Fix it as the verifiers describe, with
     the moves bounded under S3-R20.

  Applied in cycle 18 ("Cycle 18" below): in-place joins (item 1; the turns then measure within C2, and a bound on the
  stale entries a turn passes was added as margin), bounded moves (item 2), RR-17 (item 3) and RR-14's fix (item 4).
- **Orchestrator ruling (close-out) S3-R22 — added 2026-11-01 09:20 (cycle 18's verification and the cycle-18 fixer's
  put-backs; written after run 5 ended, before run 6).**
  1. *One visit or owed move that carries many ids in one turn.* VERIFY-C18R-SHARED-CONVERGENCE measured 54 to 56 ms in
     one turn on a quiet host: 10,000 prefetch members share one content, and a later apply maps them all to another.
     - The shape is inside C2's reference set, as S3-R21 item 1's concentration shape is, so the breach is blocking.
     - A visit's work and a move's work are bounded by the ids moved, continuing over the follow's turns as cycle 18's
       owed moves do.
     - The bound changes no answer (S3-R20 item 3), and a BenchSync release case pins it: best of 3, at most
       `SyncBenchmarks.c2Budget`.
  2. *RR-18* was analysed, not probed, so it is not blocking (as S3-R19 item 4 rules for unprobed residual risks). The
     cycle-18 requirements verifier read that the difference may not exist (`rerouteOnVisit` returns `nil` on a failed
     job with no verdict yet, for an apply after the publication ended). It is probed if a seam that holds
     `integrityFailed`'s store await is cheap; otherwise RR-18's text is corrected to that reading and left unprobed.
  3. *Simulator and coverage runs take turns.* Before an iOS Simulator suite or a coverage run, the lock
     `/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock` is taken with `mkdir`, waited for while it
     exists and removed right after the run; a lock older than 45 minutes is stale and may be removed. A load-caused miss
     stays non-blocking (S3-R5) and is re-run alone before it is reported.

  Applied in cycle 19 ("Cycle 19" below): moves bounded by ids (item 1), RR-18 corrected and withdrawn without a probe
  (item 2; no seam holds the await), and the lock taken around the coverage and simulator runs (item 3).
- **Orchestrator ruling (close-out) S3-R23 — added 2026-11-01 14:15 (the shared host; written before run 6, which
  starts at cycle 19).** The host is shared with other projects, whose iOS Simulator UI test runs held the load
  averages between 51 and 1,008 on 8 cores at 14:09 to 14:11 on 1 Nov, and may go on for hours. A timing figure taken
  under that load settles no C2 item either way.
  1. The three load averages (`sysctl -n vm.loadavg`) are recorded next to every timing figure: benchmarks, C2 cases
     and hang-guard times.
  2. A time-out or budget miss seen only at a 1-minute load above 50 is judged by S3-R12 and S3-R5, so it is not
     blocking by itself; it is re-run alone at the lowest load available, best of 3, and both figures are reported.
  3. A C2 fix that bounds a turn's work is pinned twice: by a deterministic test that a single turn stops at the bound
     (for example with a small injected bound), which holds at any load and which the bound's drop-mutant fails; and by
     the BenchSync release case of S3-R20 to S3-R22, best of 3, at a 1-minute load of 10 or less. If the load never falls
     that low during the run, the case is reported "not measured at a quiet load", with its figures and loads: neither
     confirmed nor blocking, and measured by the orchestrator at a quiet load before it rules the close-out converged.
  4. Another project's processes and simulators are never stopped, slowed or touched; only WP-F's own simulator is
     used, under S3-R22 item 3's lock.

  Applied in cycle 19 ("Cycle 19" below): loads beside every figure (item 1), the bound pinned by
  `EngineState.followIDsPerTurn` in the deterministic tests and by three BenchSync cases (item 3).
- **Orchestrator ruling (close-out) S3-R24 — added 2026-11-01 21:35 (the cycle-19 fixer's put-backs; written while
  the cycle-19 verifiers ran, before any cycle-20 fixer).** A cycle-19 verifier that read it before returning judged
  these items by it.
  1. *RR-20, an empty binding books a commit* (#14, VERIFY-C18R-EMPTY-BINDING): not blocking. The answers agree in
     both orders, and the extra commit count and object success are bookkeeping. The free-space estimate errs low,
     the safe side, until the next read, and staging GC (R-CLN-3) reclaims the staged file. It is recorded under the
     residual risks for Stage 5. It becomes blocking only if a probe shows the extra object success or the low estimate
     changing an answer through a breaker or space decision (S3-R16 1(a), S3-R17); the finding's fix then applies.
  2. *RR-21, work not bounded by ids in a turn* (#11). The commit's binding of a 10,001-id publication measured
     9.64 ms best at load 3.84, inside C2 by 0.36 ms: not blocking now. The next fix cycle pins it, extending
     `concentrationPublicationTurns` through the commit, best of 3, at most `c2Budget`. It measures the same way, at
     10,000 ids, the drain's `takeOffMovedBefore` and the commit's re-routes of the ids it does not bind. A miss at a
     1-minute load of 10 or less, best of 3, is blocking (S3-R22 item 1). The fix then bounds that work over the
     follow's turns or the store's units without changing an answer (S3-R20 item 3), with the two pins of S3-R23
     item 3.
  3. *Branches no test reaches* (the cycle-19 draft's "Not reached by a test (cycle 19)"): `findInbound`'s
     checksum-less lookups (`EngineFollow.swift:1049`, `:1095`), `waitingTarget`'s queued, blocked and downloading
     case, and `scheduleFollowFollowUp`'s unspawnable branch. G4 applies to code that stays (S3-R16 1(e)), so each is
     blocking until one of these holds:
     - **Reached**: a test reaches it in both `LaneDropVisit` orders and kills its drop-mutant 2/2. For the
       checksum-less lookups the pass path is tried first: a visit passes a publishing checksum-less target, its
       `rerouteOnPass` moves its own id off, and an apply maps the id back before the target's attempt ends.
     - **Removed**: the assumption it guarded becomes a `followBarrierViolations` clause a test exercises (S3-R19
       item 3), with the argument in the draft. For the checksum-less lookups, removal means a checksum-less target
       gets no inbound move and the holder's own visit moves the id.
     - **Equivalent**: it runs but changes no decision, answer or state (a release with nothing to release, for
       example; S3-R19 item 2), with the argument in the draft.
  4. *#6, `awaitInboundMoves` overwriting a wait*: accepted. The two invariants added to `followBarrierViolations`
     stand in for the unreachable overwrite (S3-R19 item 3).
  5. *RR-23, RR-16 followed by an apply that maps the id on*: a timing difference (S3-R16 item 2) in RR-16's family.
     Which content the caller gets depends on whether the later apply lands before the id's answer, and the
     sweep-first engine answers earlier because it makes no second request. It is recorded with RR-16; it is not
     blocking, and no probe is required. It becomes blocking only if a probe shows a different answer when the later
     apply lands after both engines' answers, or before both.

  Applied in cycle 20 ("Cycle 20" below): RR-20 stays a Stage 5 residual risk (item 1). RR-21 is measured (item 2):
  the commit window meets C2, and the commit's re-routes and the drain's take-off miss it, so both are blocking and
  open. The checksum-less lookups are Reached and the unspawnable branch is Removed; `waitingTarget`'s case is open
  (item 3). RR-23 is recorded with RR-16 (item 5).
- **Orchestrator ruling (close-out) S3-R25 — added 2026-11-01 23:35 (cycle 19's verification; written after the
  cycle-20 fixer's first start, which was stopped and started again so that it reads this).** Cycle 19 fixed every
  blocking item of cycle 18, and both verifiers confirmed it. They left 8 distinct blocking items (both lenses report
  the flake), listed with the non-blocking ones in `.build-orchestrator/s3f-c19-issues.json` ("correct #n" and "reqs
  #n" are the lenses' numbers); their probes and scripts are under `.build-orchestrator/s3f-probes-c19/`. The cycle-20
  verifiers judge by this ruling.
  1. *C2 in the drain* (correct #1, PROBE-C19C-DRAIN-BOUND, PROBE-C19C-DRAIN-C2; blocking, S3-R22 item 1).
     - One turn's id budget covers the whole drain batch. It is seeded with what the turn has left, the follow's last
       turn included, and what remains is passed to `followAfterVerdict` at both call sites. Once it is spent, the rest
       of the batch goes back to the head with a drain follow-up, as the `followMoving` branch does.
     - No answer changes (S3-R20 item 3).
     - The pins (S3-R23 item 3): the probe's shape as a test in both orders at `followIDsPerTurn` = 4, with three such
       verdicts, every turn within the bound, and the drop-mutant of the budget's subtraction failing it 2/2; and the
       16-slot shape (`correct/VerifyC19DrainBench.swift`) as a BenchSync release case, best of 3 at most `c2Budget`.
  2. *C2 per id: `Job.lane` and `dropInterest` cost O(interests of the job)* (correct #2; blocking).
     - C2's reference set (S3-R5, S3-R21 item 1, S3-R22 item 1) is 10,000 ids however their interests are grouped:
       one prefetch group, many groups, or one user waiter per id.
     - A cost that predates s3-base is not exempt: it is spent inside the follow's turns, and C2 is a standing order
       (S3-R20 item 1).
     - The fix is the verifier's: per-lane interest counts on `Job`, kept on every insert, removal and lane change, so
       `Job.lane` is O(1); and `dropInterest` in place, with no live copy of the job, as S3-R21 item 1 did for joins.
     - An `invariantViolations()` clause checks that the counts equal a recount from `interests`. The drop-mutant of
       each count update (insert, removal, lane change) fails a test 2/2.
     - Both shapes of `correct/VerifyC19UserBench.swift` (superseding, and one id kept) become BenchSync release
       cases, best of 3 at most `c2Budget`.
     - Then S3-R24 item 2's figures are measured, which run through the same interest code.
  3. *A C2 inventory before returning* (cycles 17, 18 and 19 each found one more per-id cost).
     - The draft lists every operation the follow's turns and the drain do per id or per event, with its cost in the
       turn's ids and in the job's interests: `continueMove`, `continueInbound`, `continueVisitRemainder`, the drain's
       replays, the commit's binding and re-routes, `takeOffMovedBefore`, `addInterest`, `removeInterest`,
       `dropInterest`, `relane`, `Job.lane`, and any other operation found.
     - Each one that is not O(1) amortised per id gets item 2's treatment or a BenchSync release figure at 10,000
       within `c2Budget`.
     - A missing or wrong row is blocking only if a probe shows a turn over `c2Budget` at a 1-minute load of 10 or
       less.
  4. *The flake in `barrierReadmitsBehindTheOwedVisitsPlaces`* (correct #3, reqs #6; blocking, S3-R16 1(d)). The two
     verifiers read two mechanisms, so the mechanism is settled before anything changes.
     - **Observe**: the engine's own admission order, with each queue ticket, inside the actor, on the simulator under
       `sim.lock`, in both orders, at least 30 iterations per argument.
     - **If the engine admits N ahead of every re-queued member each time**, the transport's `.started` records race
       after the store read (reqs #6). The test asserts the engine's admission order instead, with its tuning and
       scenario unchanged (one slot would lose the concurrent scenario, which G3 forbids), and the draft records the
       old and the new assertion.
     - **If the engine itself sometimes admits a member first**, the interleaving is made deterministic with the
       fakes' gates (no sleeps, C4) and the assertion kept. If the sweep-first order then differs from visit-first's,
       that is an order difference (S3-R16 item 2), recorded as a residual risk, with the assertion changed one to one
       (S3-R16 item 4).
     - **Sweep**: every test in `ZTronAssetSyncTests` that asserts the order of the fake transport's `.started`
       records where more than one attempt can be in flight gets the same change, each recorded in the draft.
     - **Close**: 30 iterations per argument on the simulator with 0 failures, and the Sync bundle under
       `--enable-code-coverage` 3 times.
  5. *The bound's pins* (reqs #1; blocking, S3-R23 item 3): the two shapes of
     `reqs/VerifyC19ReqsTurnTotalProbes.swift` as tests in both orders, each counting per turn the ids that leave all
     holders; `inboundSpentDrop` and `restSpentDrop` killed 2/2; those two and `continueMoveBudgetDrop` in the
     draft's mutant table.
  6. *`findInbound`'s checksum-less lookups* (reqs #2). PROBE-C19R-LEGACY-TARGET
     (`reqs/VerifyC19ReqsLegacyProbes.swift`) reaches them, and the recorded move differs under both mutants, so of
     S3-R24 item 3's options only "Reached" is left: the probe's shape as a test in both orders, with
     `byIdentifierTargetDrop` and `byIdentifierLookupDrop` killed 2/2.
  7. *`waitingTarget`'s queued, blocked and downloading case* (reqs #3) and *`scheduleFollowFollowUp`'s unspawnable
     branch* (reqs #4): S3-R24 item 3 unchanged.
     - For `waitingTarget`, the window the draft concedes is tried first: a publication's ENOENT re-queue behind the
       barrier (`enqueue`'s doc in `EngineJobs.swift`), with an owed move onto it and a lane decision that reads
       `carried()`.
     - The unspawnable branch is a liveness branch, so a shutdown, or a degrade, landing between the follow's turns is
       tried first. A test that reaches it asserts that every wait is released and shutdown completes, with a bounded
       check rather than a time limit, so that the drop-mutant fails rather than hangs. If no path reaches it, it is
       removed with a `followBarrierViolations` clause for the assumption, and the draft's argument covers all the
       state resets the branch makes.
  8. *`continueMove`'s re-validation and its end re-lane* (reqs #5: `EngineMoves.swift:203`, `:206`, `:222-223`;
     blocking, S3-R16 1(e)).
     - `:203` and `:206` are the per-interest guards that make a stale holder safe (item 9): they are reached, not
       removed. Possible shapes: a waiter that cancels between a bounded move's turns, or a token's interest, or its
       ids, taken off the holder between turns by an owed move or a later apply's walk.
     - `:222-223` is reached by an apply that maps an id back to a superseded holder's content mid-move, or removed
       with a `followBarrierViolations` clause.
     - Each reached line's drop-mutant is killed 2/2 in both orders.
  9. *A holder re-created between turns* (correct #4): not blocking. The draft records why item 8's per-interest guards
     make the stale items no-ops. No holder epoch is added, as it would add another branch under G4. It becomes
     blocking only if a probe shows a different answer, a broken MUST or invariant, or a hang.
  10. *The fixer's own check before it returns*, on the final HEAD, so that the next cycle does not find the fixer's
      own new branches.
      - `reqs/covdiff.py` over every line changed this cycle. Each zero-count changed line is reached with its
        drop-mutant killed 2/2, removed, or listed in the draft as structural (an Optional's empty case, a loop's
        exit; reqs #10) or as Equivalent, with the argument.
      - Drop-mutants (`reqs/mut.py`, `reqs/turnmut.py`) of every branch added this cycle and of every subtraction and
        comparison in a turn bound, each result in the draft's mutant table.
      - The verifiers' scripts are copied and adapted to the fixer's own scratch path, never run in place.
  11. *Non-blocking*:
      - RR-21 (reqs #7) falls under S3-R24 item 2, measured after item 2's change.
      - The draft's records (reqs #9): RR-23 moves under RR-16 (S3-R24 item 5), and RR-20 stays under the Stage 5
        residual risks.
      - The structural zero-hit lines (reqs #10) are noted in the draft as structural.
      - P-13 (correct #5, reqs #8) stays routed to WP-B.
      - The load-only miss of `throttleExtensionTurns` (correct #6) is covered by S3-R23 item 2.
      - `shutdownReleaseInboundWaitsDrop` is killed only by a hang, which is not blocking. If item 7's bounded check
        also kills it, that is recorded.

  Applied in cycle 20 ("Cycle 20" below): items 1, 2 and 4 to 6 are fixed or met as ruled, and item 8 is met with one
  drop-mutant Equivalent (`:203`'s). Item 3's inventory is written, with RR-21's two misses open and four rows without
  a figure. Under item 7 the branch is removed and `waitingTarget`'s case is open. Items 9 to 11 are recorded.

## Cycle 2: the cycle-1 verification findings

Every finding of the two cycle-1 lenses, with its disposition. Blocking ones first; each fix is detailed under its item.

| Lens | Finding | Disposition |
|---|---|---|
| reqs (blocking) | S3F-10 not applied: no behaviour test for any uncovered region | **Fixed**: tests for every region a seam reaches; the rest recorded with reasons (S3F-10 below) |
| reqs (blocking) | S3F-13 not applied: re-admission still quadratic, benchmark at 1,000 | **Fixed**: lazy re-admission from an ordered index, structural pin, `probeChainTurns` at 10,000 (S3F-13 below) |
| reqs (blocking) | S3F-14 partly done | **Fixed**: every remaining §12.3/§12.4 name written; R-SYN-15's join-before-close order has an engine-side check that M5 and M6 fail (S3F-14 below) |
| correct (blocking) | S3F-5 residual: the follow of an apply changing every member of a waiting 10,000-member group held the actor 111–145 ms | **Fixed**: the follow is bounded per turn (S3F-5 below) |
| reqs | S1-11's test hangs instead of failing under the strand mutant | **Fixed** (`ad98ac3`): `EngineHarness.value(of:)` forwards the time limit's cancellation to the awaited task; used at all 14 `withClock { await task.value }` sites. Strand mutant (`EngineDispatch.swift`, `guard let update = terminal else { return }`): `EngineSync1RegressionTests.swift:96:6: Time limit was exceeded: 60.000 seconds`, then `:114:9`, `:118:9`, `:119:9` recorded, `failed after 63.970 seconds with 4 issues` (it hung for over 31 minutes before). |
| reqs | S3F-4: no deterministic pin of settle's per-turn bound | **Fixed** (`243c6da`): settle records its slices (`EngineState.shutdownSlices`); `R-SYN-15: a shutdown over more waiters and jobs than one turn takes …` asserts every slice ≤ `shutdownStepsPerTurn`, their sum = 1,200, at least three. No-chunk mutant (`if steps == Int.max`): `EngineShutdownDrainTests.swift:52:9: … every turn of the settle takes at most shutdownStepsPerTurn steps: [1200]` and `:54:9` |
| reqs | S3F-15: `fireDue`'s use of the limit unpinned | **Fixed** (`243c6da`): `R-SYN-5: one alarm turn of the engine re-queues at most dueDeadlinesPerTurn retries that fell due together` (600 retries due at once, the alarm turn held and stepped). Mutant `popDue(at: now)`: `EngineBoundaryTests.swift:199:9: … one turn re-queued 600 retries` and `:200:9: … the rest wait for the next turn: 0` (lines 200 and 201 since the wait was made to end when no alarm is left, so the mutant fails at once instead of after the time limit) |
| reqs | P-4 missed at load (4 of 6 runs) | No change (planner untouched since `s3-base`); re-measured below; the orchestrator re-measures on a quiet host at the Stage 3 merge |
| correct | P-11 2.51 and the throttle extension under load | No change (dispatch untouched by this cycle); re-measured below |
| correct | S3F-13 still open | Same as the requirements finding (fixed) |
| correct | other-wp:b: P-13 unit max 6.83 ms | **other-wp:b:** not WP-F's file (`BenchStorage.swift`), not touched; routed to WP-B |

## Cycle 3: the cycle-2 verification findings

Every finding of the two cycle-2 lenses, with its disposition; the blocking one first (failing test `8b688ad` committed
on its own, fix `df5cfe3`). Mutants were applied in place on the committed tree, rebuilt in `.build-s3f`, run and reverted
(`git status` clean after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | Regression of the bounded follow: a waiter of a listed id answered `notFound` (PROBE-W4/W4b), and transfers of replaced content dispatched after the apply (PROBE-W1/W1b) | **Fixed** (below) |
| reqs | S3F-4: the settle's yield unpinned (deleting both yields survived) | **Fixed** (`6cd13e9`): an observer on the engine's actor, queued before the shutdown, reads the slices between its own yields and must see a count strictly between 0 and the last. Mutant `noyield` (both `await Task.yield()` deleted): `EngineShutdownDrainTests.swift:62:9: Expectation failed: seen.contains { $0 > 0 && $0 < slices.count }` |
| reqs | S3F-14: a close moved alone before the joins (close-only M5) survived | **Fixed** (`e58a34f`): `closeStore()` sets `closingStore` and closes in one step, and the R-SYN-15 test reads the store while the shutdown joins the task its bulk unit holds (it must still be open). Mutants on the new code: close-only M5 (`await self.store.close()` added before the join loop) → `EngineSync1HalvesTests.swift:223:9: Expectation failed: openWhileJoining`; M5 (`closeStore()` moved before the join loop) → `:222:9` (`record.tasksAtMark.allSatisfy { $0 == 0 }`) and `:223:9`; M6 (no join) → `:222:9` and `:223:9` |
| reqs | S3F-10: an uncommanded client cancel treated as the system's (retry with backoff) survived | **Fixed** (`dc964d7`): a condition observer records the job's states, counted attempts and retry deadlines; the test also checks `metrics.retries`. Mutant `r3cancel`: `EnginePublicationRefusalTests.swift:146:9: Expectation failed: after.retries == FailureCounts()`, `:154:9` (`!record.states.contains { $0.kind == .failed }`), `:155:9` (`record.attempts == 0`), `:156:9` (`record.retries == 0`) |
| reqs | S3F-10: the maintenance exit after orphan collection unpinned (eviction was a no-op) | **Fixed** (`758c22f`): new `R-SYN-16: maintenance whose time budget runs out during orphan collection evicts nothing from a store over its budget` (a store over a 64-byte budget whose assets left the retention scope; a maintenance with time to spare then evicts them, the control). Mutant `r5budget` (the check after `collectGarbage` disabled): `EngineMaintenanceStepTests.swift:136:9: Expectation failed: report.budgetExhausted && report.evictedBytes == 0`, `:138:9`, `:140:9` |
| reqs | S3F-10: the `assetFailed` refusal indistinguishable from `notFound` | **Fixed** (`dc964d7`): the test runs for a 404 record and an unreadable one (`integrityFailure`). Mutant `r2split` (`.assetFailed` moved into the `notFound` branch): `EnginePublicationRefusalTests.swift:91:9: … reason → .unreadable … Expectation failed: answer == .failure(expected)` |
| reqs | Records: cycle-1 proposals for §12.3/§12.4 and §14 contradicted cycle 2's | **Fixed**: removed; "Proposed document changes" now carries one set (cycle 2's texts) |
| reqs | Hang-guard margins of the cycle-2 tests under TSan (observation) | Re-measured under TSan in this cycle ("Gate evidence (cycle 3)"); no guard changed (see there) |
| reqs | `probeChainTurns` noisy at 10,000 (observation) | No change for WP-F; re-run in this cycle's benchmarks; the orchestrator re-runs it on a quiet host at the merge |
| correct | The alarm-turn test's TSan margin | Re-measured in this cycle's TSan run (below); S3-R4 applied to the measurement |
| correct | PROBE-W3: the parked order's rebuild at 9,994 jobs took 5.1–6.3 ms in one call | Recorded, no code: within C2 by itself; a turn that combines it with a join batch or a pump's parks is not benchmarked (§14 candidate below) |
| correct | other-wp:b: P-13 | **other-wp:b:** `BenchStorage.swift` is WP-B's; not touched; routed to WP-B |

### The blocking finding: replaced content acting before its follow visit — **Fixed**

*Finding:* since the bounded follow (`958348e`), an id whose content an apply changed keeps its interest on the job of
its replaced content until the follow visits that job, up to about 40 turns later at 10,000. (1) A failure of that job's
attempt in the window was delivered to every interest, so a listed id's waiter got `notFound` (F-20) and a prefetch
member was settled; (2) every pump between follow turns dispatched the replaced content's jobs, still queued ahead of the
new content's (PROBE-W1b: 44 of 48 starts after the apply at 3,000 members).

- **Failing tests first** (`8b688ad`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, the probes renamed into
  `EngineSyncTests`):
  - `R-CAR-2: a failure of an id's replaced content before its follow visit answers the id's waiter from its new content`
    (PROBE-W4 with the hold seam, 600 ids; arguments `notFound` (a 404), `serverErrorAtCap` (a 503 at an interactive cap
    of 1), `noSpace` (ENOSPC)). At `8b688ad`: `EngineFollowTests.swift:276:9: Expectation failed: (try? answer.get()) !=
    nil` with `failure(AssetError.notFound)`, `failure(AssetError.serverUnavailable(retryAfter: nil))` and
    `failure(AssetError.insufficientSpace(required: 5000, available: 0))`, and `:277:9` (the new content never fetched).
  - `R-SYN-2: a 404 for a prefetch member's replaced content before the follow's pass reached it moves the member to its
    new content` (PROBE-W4b's shape with the hold seam: `followFormatsPerTurn` + 64 members, the member listed last so
    the pass has not reached it). At `8b688ad`: `:324:9: Expectation failed: after.pending == [replacement.transferID]`
    (`[]`: the member was settled by the 404) and `:325:9`.
  - `R-SYN-2: no transfer of a replaced content starts after the apply while a bounded follow still owes its job`
    (PROBE-W1 with the hold seam, 700 members, two slots). At `8b688ad`: `:369:9: Expectation failed:
    startedBetween.isEmpty` (`2 transfers of replaced content started after the apply`), `:370:9`, `:377:9`.
- **Fix** (`df5cfe3`, then `2fb46be` and `776748a`, each after its own failing test). Two predicates in
  `EngineFollow.swift`, both false unless a follow is owed (one lookup and one formatted transfer per id of the job):
  `holdsMovedID(_:)`, the job holds an id the copy *lists* at another transfer; `awaitsFollow(_:)`, the job holds an id
  the copy does not map to its content (listed elsewhere or dropped). Either covers the jobs the follow owes a visit,
  those its pass has not reached, and any joined meanwhile for a replaced entry.
  - (1) Failures: `followBeforeActing(_:)` brings the follow's visit forward (the private `follow(_:)`, unchanged) where a
    job holding a moved id is about to answer its interests with a failure: `resolveAll` for `.failed` outcomes (the 404,
    auth, `rejected`, integrity, the 429 and backoff give-ups, every publication refusal), `countFailedAttempt` (an
    answer at the cap) and `spaceFailed` after its free-space read (the park's figures). The moved ids' interests follow
    their new content (T22); only the ids the copy still maps to the content get the failure; a pump is scheduled for the
    new jobs. A dropped id is not counted here: a waiter joined from the store's newer manifest (`EngineManifest.join`)
    holds an id the copy does not list yet, and the follow would end it `.notFound`; a dropped id's interest therefore
    gets the failure's own answer rather than the follow's `.notFound` (no rule forbids it; F-20 concerns listed ids).
  - (2) Dispatch: `dispatch(_:parkLimit:)` leaves a job that `awaitsFollow` at the head of its queue (`.waitsForFollow`)
    and the pump stops that queue for the turn; `hasQueuedUser()` does not count a user queue whose first ready entry
    awaits the follow, so such a job neither preempts a running transfer nor keeps the other lanes from a free slot;
    `pumpWaitsForFollow` makes every follow turn pump again and counts as a dispatch owed for a pending run behind the
    breaker (F-41). The pump does not follow the job itself: that would move up to a queue of jobs per pump and break
    the follow's per-turn bound (C2; `followIsBoundedPerTurn` pins 256 moves per turn and still passes). A job joined
    from the store's newer manifest waits too while a follow is owed, harmlessly (it starts when the follow ends).
  - New `invariantViolations()` rule: a pump waiting for a follow nothing owes. Shutdown resets the flag.
- **Found while fixing, each failing test first:**
  - `48d9d59` (failing) / `2fb46be` (fix): `R-SYN-2: a queued user job of an id the apply dropped does not start while
    the follow still owes its visit` (700 changed prefetch members, two user transfers in both slots, the dropped id's
    user job queued; a slot freed between follow turns). At `48d9d59`: `EngineFollowTests.swift:427:9: Expectation
    failed: !startedBetween.contains(dropped.transferID)` (`the dropped id's transfer was requested after the apply`),
    `:428:9`, `:435:9`: the first dispatch check counted only listed ids. After the follow the waiter is answered
    `.notFound` (T21).
  - `c0c0563` (failing) / `776748a` (fix): the same test with an unchanged two-member prefetch group: the freed slot
    goes to its member and nothing is preempted. At `c0c0563` (the per-round `userWaitsForFollow` flag of `2fb46be`):
    `EngineFollowTests.swift:437:9: Expectation failed: between.preemptions == preemptions` (7 against 0: once a
    prefetch member started, the next round's `hasQueuedUser()` counted the waiting job and preempted it, and so on).
    The test's earlier check of the internal `pumpWaitsForFollow` flag was dropped in that commit, with the reason: a
    later pump with every slot taken stalls no head, so the flag reads false while the job still waits (the job's
    `queued` state and the absent start are still asserted).
- **The ENOSPC case's scenario** changed in the first fix commit: on the 4 KiB volume of the first form the new content
  could not fit either (after the fix: `insufficientSpace(required: 16, available: 0)`), so the case now asks for 1 TiB
  on the default volume; the `noSpaceHook` mutant below shows it fails without the fix.
- **Mutants** (in place on `776748a`; filter `replacedContentFailure|noReplacedContentStarts|droppedUserJobWaitsForTheFollow`;
  lines under "Gate evidence (cycle 3)"): `noResolveAllHook`, `noCountHook`, `noSpaceHook`, `noDispatchStall`,
  `listedOnlyAtDispatch` (dispatch counting listed ids only), `owedVisitsOnly` (`holdsMovedID` also requiring
  `unfollowed.contains`, so a job the pass has not reached is missed), `userHeadCounted` (`hasQueuedUser` counting a
  head that awaits the follow). The whole fix removed is the failing commit `8b688ad` above. `.waitsForFollow`
  breaking only the `switch` (not the user queue's loop) livelocks the pump on the actor: the test hung and was killed
  after 30 minutes (a hang, so killed, but no time-limit line is printed).
  - **Surviving, recorded:** the `|| self.state.pumpWaitsForFollow` terms of `continueFollow`'s two pump conditions
    (`noFlagPump`: the whole Sync bundle, `✔ Test run with 403 tests in 52 suites passed`). A queue head waits for a
    job the follow owes a visit or whose entry its pass has not reached, and that visit moves it, so the turn pumps on
    `moved` already. The terms are a liveness net for a head the follow never visits (a job joined meanwhile for a
    replaced entry, or from the store's newer manifest); no seam orders one before the follow's last turn, and the
    invariant rule reports a flag left set once the follow ended (§14 candidate below).
- **C2:** the stall costs one queue head per lane and pump; the follow's per-turn bound is unchanged
  (`changedRefreshTurns` and `followIsBoundedPerTurn` re-run below).
- **REENTRANCY:** no new `await` in production code (the hooks are synchronous; `spaceFailed`'s existing f-4 comment
  now names the follow re-check after its read). Proposed amendment of row f-4 below.

## Cycle 4: the cycle-3 verification findings

Every finding of the two cycle-3 lenses, with its disposition; the blocking ones first. Mutants were applied in place on
the committed tree, rebuilt in `.build-s3f`, run and reverted (`git status` clean after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | A space sweep during an owed follow answers a listed id's waiter with its replaced content's `insufficientSpace` figures (PROBE-C3-SPACE) | **Fixed** (failing test `996ac21`, fix `c8f01ca`; below) |
| reqs (blocking) | S1-15's run test (`EngineSync1LivenessTests.swift:175`) timed out under TSan beside a second TSan process (194.17 s at load ~33) | **Setup made cheaper, phases measured; still over half of 3 min paired: orchestrator ruling requested** (below) |
| reqs (blocking) | `probeChainTurns` over its 3-minute limit on a quiet host | **Fixed** (`7a81bc9`, `07ca8cb`): chains take 1.1 s instead of 6 to 95 s; all 20 `SyncBenchmarks` pass at load 3 (below) |
| reqs | The S3-R4 record contradicted: the alarm-turn test over half its limit at load ≤ 30; shutdown drain and bounded follow at the threshold | **Fixed** (`2211585`): re-measured beside a second TSan process at load 16–26; all three over 30 s, raised to `.minutes(3)` with their measurements, and seven more over half their limit raised the same way (table below) |
| reqs | Surviving mutant `noDispatchOwedFlag` (`EngineRuns.swift:947`, `\|\| self.state.pumpWaitsForFollow` in `dispatchOwed`) unrecorded | **Recorded** (no test; reason below) and proposed for §14 |
| reqs | PROBE-W1 (cycle 2) now hangs: a lane dispatches nothing while its head waits for an owed follow | No change (expected behaviour, already in the proposed §7.10 text) |
| reqs | other-wp:b: P-13 | **other-wp:b:** `BenchStorage.swift` is WP-B's; not touched |
| correct | Hang-guard margins of the alarm-turn and the cycle-12 seeded release/re-join tests under TSan | **Fixed** (`2211585`): both `.minutes(3)` with the verifiers' and this cycle's measurements; the seeded loop calls `Task.checkCancellation()` per operation |
| correct | Load benchmarks: `probeChainTurns` over its limit, the throttle extension 10.66 ms best, P-11 2.94 at load 11–23 | `probeChainTurns` fixed (above); re-run at load 3: throttle extension [7.15, 7.81, 6.75] ms, P-11 3.43, every benchmark passing |
| correct | The `noFlagPump` survivor (`continueFollow`'s two `\|\| pumpWaitsForFollow` terms) unpinned (optional test) | Kept as recorded in cycle 3 (§14 candidate (a)); no test this cycle |
| correct | other-wp:b: P-13 | **other-wp:b:** as above |
| (found here) | other-wp:b: a 404 has the store commit its whole index before the engine goes on | **other-wp:b:** reported below; no WP-F change needed (the benchmark no longer measures it) |

### The blocking correctness finding: a space sweep during an owed follow — **Fixed**

*(Superseded in cycle 8: the sweep now follows every job it would judge before it orders them, and judges each once
at its post-follow place; the in-loop follow, re-judgement and re-queue this entry describes were removed in
`1b771e8`; see "Cycle 8".)*

*Finding:* `sweepSpaceParked` (the alarm's `.reclaimed` sweep after reaped bytes, `.settle`, a purge's reclaim) could
re-park the `awaitingSpace` job of a listed id's replaced content `insufficientSpace` while the bounded follow still owed
its visit, and `park` → `failFast` answered that id's waiter or ensure member with the replaced content's figures,
although the copy lists the id at content that fits (F-22, T22, R-CAR-2); the cycle-3 hooks covered `resolveAll`,
`countFailedAttempt` and `spaceFailed`, not this park.

- **Failing test first** (`996ac21`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, `extension
  EngineSyncTests`): `R-SYN-11: a space sweep during an owed follow moves a listed id's interest to its new content before
  it answers or re-queues the replaced content's job (R-CAR-2)`, arguments `SweptReplacedContent.waiterReparked`,
  `.ensureReparked` (an `ensureAvailable` member; its fetch-first finds the manifest unchanged) and `.waiterRequeued`.
  PROBE-C3-SPACE's shape with the hold seam: 4 MB of a pruned blob wait for the reclaim, the target's 5 MB user job is
  parked `awaitingSpace` against 4 MB of room, a forced sync moves the target to 16 bytes while 2,100 changed entries
  sort before it (the pass stops before its entry), the test sets the room the reclaim adds to (0.5 MB: re-park; 2 MB:
  re-queue), and the deletion grace ends. At `996ac21`: `EngineFollowTests.swift:573:9: Expectation failed:
  answered.fromNewContent` with `failure(ZTronAssetModel.AssetError.insufficientSpace(required: 5000000, available:
  4500000))` for `.waiterReparked` and `.ensureReparked`, and `:569:9: Expectation failed: !afterSweep.holds` (`the
  replaced content's job no longer holds the id after the sweep: Optional(ZTronAssetSync.JobState.queued)`) for
  `.waiterRequeued`.
- **Fix** (`c8f01ca`, `EngineJobs.swift` `sweepSpaceParked`, doc of `followBeforeActing` in `EngineFollow.swift`): the
  sweep calls `followBeforeActing(transfer)` just before it re-queues a candidate and just before it parks one
  `insufficientSpace`. A superseded job is skipped and counted against the same per-turn bound as the action it preceded
  (`readmissionsPerTurn` re-queues, `parksPerPump` parks), so the sweep stays bounded per turn (C2); a job that keeps
  some ids is read again before its figures (the moved interests may have lowered its lane; this entry reasoned that a
  lower lane can only shrink the room its figures read, so the verdict holds, which is wrong: the two volume readings
  are not ordered, and cycle 7 re-judges the job after its follow, under "Cycle 7"). A job left waiting (`awaitingSpace` with a wake expected) acts on nothing
  and is not followed. The verifier's prototype put the hook at the loop's head, which follows every candidate including
  the waiting ones, unbounded per turn at 10,000 parked jobs; this placement follows only the jobs the turn acts on.
- **Mutants** (in place on `c8f01ca`, filter `spaceSweepFollowsTheReplacedContent`):
  - `noSweepParkHook` (`guard let parked = self.state.jobs[transfer] else {`): `EngineFollowTests.swift:573:9: Expectation
    failed: answered.fromNewContent` for `.ensureReparked` and `.waiterReparked`; `✘ Test run with 1 test in 1 suite
    failed after 1.111 seconds with 2 issues.`
  - `noSweepRequeueHook` (`if false, self.followBeforeActing(transfer) {`): `EngineFollowTests.swift:569:9: Expectation
    failed: !afterSweep.holds` for `.waiterRequeued`; `✘ Test run with 1 test in 1 suite failed after 1.083 seconds with
    1 issue.`
- **REENTRANCY:** no new `await` (the hook is synchronous). **C2:** at most one follow per action the turn already
  bounds; `spaceParking`, `spaceReadmission` and the follow benchmarks re-run below. *(Corrected in cycle 5: that bound
  was not C2's. A follow costs about ten times the re-queue or park it precedes, so one turn could follow
  `readmissionsPerTurn + parksPerPump` = 1,024 jobs, 9.3 to 13 ms at 10,000 members, and none of those benchmarks owes a
  follow. The sweep now follows at most `followsPerTurn` jobs per turn: "Cycle 5" below.)*
- The test's payloads are repeated bytes (`2211585`), not generated megabytes, which took seconds under TSan: 12.2 s in
  the bundle at load 4–9, 24.7 s beside a second TSan process at load 12–32 (of 60 s).

### S1-15's run test under TSan — **setup cheaper; ruling requested**

*Finding:* `runMaterialisesAPipelineAtATime` (`.minutes(3)`) exceeded its limit beside a second TSan process; make the
setup cheaper without cutting entries or assertions, measure the phases, re-measure alone and paired at load ≤ ~30, and
ask for a ruling if it cannot stay under half of 3 minutes.

- **Phases** (TSan, the test's own steps timed in a scratch copy, never committed; `sample` profiles of the process):
  at load 5–12 the 100,000 entries' catalog 0.4–0.5 s, their encoding 4.0–4.4 s (a first hand-built encoder; one
  `JSONEncoder` call took 2.7–8.3 s on its own), then 30.1–36.3 s from the forced sync to the applied copy (56.2 s at
  load 11–18), of which the engine's decode of the 21 MB manifest (`ManifestDecoder.decode`: `ManifestParser.survey`
  and `parse`, WP-A's model code, instrumented byte by byte) took about two thirds of the samples, the plan (`PlanBuilder`,
  mostly formatting 100,000 transfer ids) about an eighth and the store's apply and index commit (WP-B) most of the rest;
  the shutdown's store close (another index commit) 2.2–2.8 s; the materialisation itself under 5 ms.
- **Cheaper** (`c745edc`): the wire bytes are encoded in eight slices at once and joined
  (`EngineFixture.manifestDataInSlices`, byte for byte `manifestData`'s output, which the test checks on a 100-entry
  prefix): 1.0–1.3 s against 2.7–8.3 s for one `JSONEncoder` call (a hand-built encoder was no faster under TSan:
  2.9–6.4 s as strings, 10.1–14.6 s as bytes). Entries, operations and assertions are unchanged. A store seeded with the manifest and
  a 304 run was tried and dropped: it removes the fetch-and-decode operation from the test (G3), and the store's next
  open read nothing back (the run planned an empty manifest).
- **Measured after** (TSan, `.build-s3f-tsan`, whole bundle run directly): alone (only it) 32.5 s at load 3.2–3.7 and
  46.1 s at load 11–18; in the bundle 60.6 s (load 3.7–8.6), 68.3 s (load 16–19), 99.0 s (load 13–30); beside a second
  TSan process 101.8 s twice (load 12–32) and 104.3–104.7 s (load 16–26); at load 59–464 193.3 s (reported passed:
  the limit is enforced coarsely). Over half of `.minutes(3)` at a load at most about 30 in every paired run.
- **Requested ruling (S1-15 guard):** S3-R4 reserves `.minutes(5)` for model-based or exhaustive tests; this one is
  neither, and its time is the decode of a 100,000-entry manifest it needs (S1-15's catalog size), in another work
  package's parser, under TSan. Requested: `.minutes(5)` for this test (paired 101.8–104.7 s, 34–35 % of 5 minutes), or
  another ruling the orchestrator prefers (for example routing the parser's sanitizer cost to WP-A, `other-wp:a`, which is
  not a defect: release decodes the same manifest in well under a second). Until a ruling, the guard stays `.minutes(3)`
  and the test's doc comment records the measurements.

### `probeChainTurns` — **Fixed**

*Finding:* WP-F's benchmark exceeded its 3-minute limit at load 4–9; make the chain cheaper without reducing the 10,000
members, the three runs or the 1,000 warm-up, then show it passing at load ≤ ~10.

- **Cause, measured** (`sample` of the release benchmark mid-chain): with 404 exits each exit had the store record the
  failure and commit its whole index before the engine went on (`AssetStore.recordFailure` → `persistBookkeeping` →
  `requireCommitted(.ordered)` → `IndexCommitUnit.run` → `IndexCodec.encode`, ADR-032), about 5 ms at 10,000 records on
  the store's actor, so 10,000 exits took 50 s or more per chain whatever the engine did. With 400 exits, chains still took
  6 to 88 s at load 3–14, with the process's threads idle most of the time: each of the 10,000 probes is a handful of hops
  between the engine's owned tasks (`.medium` follow-ups), which queued behind the `.high` heartbeat's pulses on the
  actor. Cycle 2's reading of the wall time (the fake source's round trip and the bench's polling) was wrong.
- **Fix** (`7a81bc9`, `07ca8cb`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` only): the exits are 400s, which also
  end a probe without a verdict (`breakerOutcome`: `.neutral`) and re-admit exactly as a 404 does, and write nothing to
  the store; the bench's O(n) polls on the actor are preceded by O(1) waits on the engine's own notifications
  (`SyncBench.originQuiet`); the chain's engine runs its owned tasks at the heartbeat's priority
  (`SyncBench.raiseOwnedTaskPriority`, the `ownedTaskPriorityFloor` seam the engine tests' harness uses, F-17). The engine's
  turns are the same; the measured figure (the heartbeat's longest wait) does not depend on a task's priority. Members,
  runs and warm-up unchanged.
- **Measured:** alone at load 3.5–3.6: totals [1.12, 1.17, 1.13] s and [1.11, 1.12, 1.11] s, waits [0.22, 5.69, 0.93] and
  [0.19, 0.19, 0.18] ms, `✔ Test run with 1 test in 2 suites passed after 4.038 seconds` and `3.932 seconds`. Whole
  `SyncBenchmarks` at load 2.95–3.42: `✔ Test run with 20 tests in 2 suites passed after 90.579 seconds`, chain totals
  [1.13, 1.16, 1.14] s, waits [0.54, 1.21, 0.32] ms. (Before the priority change, with 400 exits: `failed after 190.589
  seconds` at load 3–4, totals [87.9, 71.6, 22.3] s.)
- **other-wp:b (new):** a burst of 404s rewrites the store's whole index once per failure (`recordFailure` commits
  `.ordered` per call): at 10,000 records about 5 ms of CPU and an index-sized write per 404, so 10,000 missing assets
  rewrite the index 10,000 times. Not on the engine's actor (no C2 breach); a write-amplification question for WP-B
  (coalescing the failures of one burst into one commit would keep ADR-032's durability).

### Hang guards (S3-R4) — **Fixed**

Measured under TSan in the whole Sync bundle (`.build-s3f-tsan`, run directly): alone at load 16–19 and beside a second
TSan process (two bundles at once) at load 16–26, at `c8f01ca` plus this cycle's test edits; each raised guard's doc
comment carries its numbers. Re-measured on the final tree (`07ca8cb`): alone at load 3.7–8.6, paired at load 12–32.

| Test | alone | paired (load 16–26) | final tree: alone / paired (load 12–32) | guard |
|---|---|---|---|---|
| `R-SYN-5: one alarm turn of the engine re-queues at most dueDeadlinesPerTurn …` (`EngineBoundaryTests.swift`) | 33.8 s | 54.7–55.1 s | 23.3 / 47.5–47.8 s | **3 min** |
| `R-SYN-3: seeded random releases and re-joins …` (`EngineRegressionCycle12Tests.swift`) | 40.5 s | 67.0–67.4 s | 28.4 / 58.1–58.4 s | **3 min** |
| `R-SYN-15: a shutdown over more waiters and jobs than one turn takes …` (`EngineShutdownDrainTests.swift`) | 24.2 s | 40.3–42.9 s | 18.1 / 35.2–37.6 s | **3 min** |
| `R-SYN-2: an apply that moves more jobs than one turn takes …` (`EngineFollowTests.swift`) | 26.7 s | 41.2–41.4 s | 17.5 / 36.1–36.2 s | **3 min** |
| `R-SYN-5: when a 429 extends the throttle under more user-initiated waiters …` (`EngineRegressionCycle16Tests.swift`) | 26.5 s | 41.2–41.7 s | — | **3 min** |
| `R-SYN-6: one failing asset among 100 …` (`EngineSyncTests.swift`) | 24.6 s | 35.7–37.5 s | — | **3 min** |
| `R-SYN-2: a 404 for a prefetch member's replaced content …` (`EngineFollowTests.swift`) | 24.3 s | 37.0–37.2 s | — | **3 min** |
| `R-SYN-3: never more than maxConcurrentTransfers …` (`EngineLaneTests.swift`) | 22.3 s | 33.1–33.4 s | — | **3 min** |
| `R-SYN-5: a chain of half-open probes … re-admits one parked job per probe exit …` (`EngineProbeChainTests.swift`) | 22.3 s | 33.0–33.2 s | — | **3 min** |
| `R-SYN-6: with the default tuning, a run does not download …` (`EngineRegressionCycle3Tests.swift`) | 20.7 s | 30.5–30.9 s | — | **3 min** |
| `R-STO-13: during legacy migration a bulk sync … install-rate limiter …` (`EngineLegacyMigrationTransferTests.swift`) | 21.1 s | 30.5–30.6 s | — | **3 min** |

The cycle-16 throttle test also timed out (60 s) in both processes of a paired run at load 59–464 (a load miss, as the
cycle-3 verifier's run 1), which with 41 s paired at load ≤ 30 is why it is in the table. Every other test with a 1-minute
guard stayed at or under 30 s paired at load 16–26 (the space-sweep test 29.2 s with its old payloads, 24.7 s now). The
S3F-2 guards hold: `randomOperations` 66.1–79.2 s of 5 min, the four 3-minute ones 47.8–57.4 s.

### The `noDispatchOwedFlag` survivor — **recorded, no test**

Removing `|| self.state.pumpWaitsForFollow` from `dispatchOwed` (`EngineRuns.swift:947`) passes the Sync bundle (the
cycle-3 requirements verifier: `✔ Test run with 408 tests in 53 suites passed after 57.786 seconds`). The term keeps
F-41's order (the re-admitted jobs probe before a pending run's manifest fetch) when the job the breaker re-admitted for
its probe waits at its queue's head for an owed follow. It only matters while a pending run exists, and
`reconsiderPendingRun` requires `state.run == nil`, while no run settles as long as a follow is owed: so the follow must
come from an apply that is not a run's (`ensureAvailable`'s fetch-first apply, or a catch-up), the breaker must have
tripped and a run been refused after that apply, and the cooldown must end, all inside one bounded follow (about 40 turns
at 10,000). The hold seam makes that orderable, but the test was not written in this cycle (its size: an `ensureAvailable`
apply, a 5xx trip, a refused run and a cooldown's end around a held follow). Proposed §14 entry below, next to
`noFlagPump`.

## Cycle 5: the cycle-4 verification findings

Every finding of the two cycle-4 lenses, with its disposition; the blocking ones first. The rulings file was re-read and
holds no ruling on the S1-15 run test's guard. Each mutant was applied in place on the committed tree, rebuilt in
`.build-s3f` (release: `.build-s3f-perf`), run and reverted (`git diff --stat Sources/` empty after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | C2 regression from `c8f01ca`: `sweepSpaceParked` counted each follow as one re-queue or one park, so one sweep turn followed up to `readmissionsPerTurn + parksPerPump` = 1,024 jobs (PROBE-C4-SWEEP2-C2: 9.3 to 13 ms at 10,000) | **Fixed** (failing test `04ae782`, fix `e18d5aa`, C2 benchmark `8cc5940`, test cheaper `72b2ab2`; below) |
| reqs (blocking) | S1-15's run test (`EngineSync1LivenessTests.swift:179`, `.minutes(3)`) at 129.9 / 130.1 s beside a second TSan process at load 10.5–25.9 (72 %); the ruling requested in cycle 4 not issued | **Open: awaits the orchestrator's ruling.** Guard unchanged (S3-R4 gives `.minutes(5)` only to model-based or exhaustive tests; this one is neither); re-measured (below); the request stands with the verifiers' and this cycle's figures. *Ruled after cycle 5 (S3-R10) and applied in cycle 6 (`daa2ba8`)* |
| correct | The same test at 108.76 s alone in the TSan bundle at load 26–35 (60 %); ruling pending | As above |
| reqs | `SyncBenchmarks` misses on a loaded host (P-4 ratio, P-11, network edges, throttle extension), all five passing on the verifier's rerun at load 11–14 | No change (load only); the whole `SyncBenchmarks` re-run under "Gate evidence (cycle 5)" |
| reqs | Survivor `noDispatchOwedFlag` confirmed (`EngineRuns.swift:947`) | Kept as recorded in cycle 4 (§14 candidate (c)); no test this cycle |
| correct | Survivors `noDispatchOwedFlag` and `noFlagPump` carried over | Kept as recorded (§14 candidates (a) and (c)); no test this cycle |
| reqs | other-wp:b: P-13 and the per-404 index commit | **other-wp:b:** `BenchStorage.swift` and `AssetStore.recordFailure` are WP-B's; not touched |
| correct | other-wp:b: the per-404 index commit and P-13 | **other-wp:b:** as above |

### The blocking correctness finding: a space sweep's follows per turn — **Fixed**

*(Superseded in cycle 8: the sweep now follows every job it would judge before it orders them, and judges each once
at its post-follow place; the in-loop follow, re-judgement and re-queue this entry describes were removed in
`1b771e8`; see "Cycle 8".)*

*Finding:* cycle 4's fix (`c8f01ca`) followed a job just before the sweep re-queued or parked it and counted that
follow as the re-queue (`readmissionsPerTurn`, 512) or the park (`parksPerPump`, 512) it preceded. A follow (supersede,
re-route each interest, create the new content's job) costs about 10 to 12 µs, a re-queue about 1 µs and a park about
2 µs, which is why a follow turn visits `followsPerTurn` = 256 jobs. One `.reclaimed` sweep turn (the alarm's after
reaped bytes, `EngineTimers.swift:177`; also `.settle` and a purge's reclaim) could follow 1,024 jobs: the verifier's
PROBE-C4-SWEEP2-C2 measured heartbeat waits of 10.18–10.83 ms (one handle) and 13.62–14.05 ms (two handles) at 10,000
members, against 6.2–7.3 ms with no follow owed.

- **Failing test first** (`04ae782`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, `extension
  EngineSyncTests`): `R-SYN-11: one space sweep turn during an owed follow follows at most followsPerTurn jobs and leaves
  the rest to its follow-up sweep (C2)` (`spaceSweepFollowsAtMostOneTurnOfJobs`). Prefetch members alternating 400 and
  3,000 bytes wait `awaitingSpace` for a pruned 2,000-byte blob with 200 bytes of room; a forced sync changes every
  member's content and the follow's follow-ups are held after its first turn's 256 visits; the space sweep's follow-ups
  are held too (`holdSpaceSweepFollowUps()`); the deletion grace ends and the alarm's `.reclaimed` sweep re-queues the
  400-byte members and parks the 3,000-byte ones. The test counts the jobs that still hold a moved id
  (`holdsMovedID`) before and after that one turn, and requires exactly `followsPerTurn` follows, of both sizes, a held
  follow-up, and, after the holds end, every member's interest on its new content's job, no invariant violation and no
  replaced content requested. At `04ae782` (1,000 members): `EngineFollowTests.swift:672:9: Expectation failed:
  followed.small + followed.large == SyncEngine.followsPerTurn` / `one sweep turn followed 744 jobs (372 re-queued, 372
  parked), at most followsPerTurn = 256`; `✘ Test run with 1 test in 1 suite failed after 0.374 seconds with 1 issue.`
- **Fix** (`e18d5aa`, `EngineJobs.swift`): `sweepSpaceParked` counts every candidate that holds a moved id against its
  own budget of `followsPerTurn` per turn (`followFits(_:follows:)`), beside the re-queue and park bounds; once it is
  spent, the sweep schedules its follow-up (`scheduleSpaceSweepFollowUp`) and stops, as the other two bounds do. The
  verifier's prototype (`proto-sweep-follow-budget.diff`) did the same inline. A job that holds no moved id is not
  counted; a job left waiting acts on nothing and is not followed. The doc comment's C2 sentence is corrected (cycle 4's
  "the follow counts against the same per-turn bound as the action it precedes"), and so is the cycle-4 entry above.
- **Cheaper** (`72b2ab2`): the test runs over 600 members (344 owed after the follow's first turn, still more than one
  sweep turn may follow): 1.7 s alone under TSan with 1,000 members, 28.6 s in the TSan bundle at load 13–17; with
  600: 12.6 s in the bundle at load 3.7–4.7 and 19.2 / 21.3 s beside a second TSan process at load 4–14 (of 60 s).
- **Mutants and the pre-fix tree** (S3-R3; in place on `72b2ab2`'s tree, filter `spaceSweepFollowsAtMostOneTurnOfJobs`):
  - pre-fix (`EngineJobs.swift` as at `04ae782`): `EngineFollowTests.swift:672:9: Expectation failed: followed.small +
    followed.large == SyncEngine.followsPerTurn` / `one sweep turn followed 344 jobs (172 re-queued, 172 parked), at most
    followsPerTurn = 256`, and `:674:9: Expectation failed: after.followUpHeld`; `✘ Test run with 1 test in 1 suite
    failed after 0.237 seconds with 2 issues.`
  - `noRequeueFollowBudget` (`guard requeues < Self.readmissionsPerTurn else {`): `:672:9` with `one sweep turn followed
    344 jobs (172 re-queued, 172 parked)`, and `:674:9`; `failed after 0.247 seconds with 2 issues.` (At 1,000 members:
    `one sweep turn followed 513 jobs (257 re-queued, 256 parked)`.)
  - `noParkFollowBudget` (`guard parks < Self.parksPerPump else {`): `:672:9` with `one sweep turn followed 344 jobs (172
    re-queued, 172 parked)`, and `:674:9`; `failed after 0.239 seconds with 2 issues.` (At 1,000 members: `one sweep turn
    followed 512 jobs (256 re-queued, 256 parked)`.)
  - With the fix: `✔ Test run with 1 test in 1 suite passed after 0.241 seconds.`
- **C2 benchmark** (`8cc5940`, `BenchSync.swift`, S3-R5): `R-SYN-11: a reclaim of space during an owed follow under a
  10,000-member prefetch group, re-queueing and parking its members, holds the engine's actor at most C2's 10 ms per
  turn` (`reclaimDuringFollowTurns`; helper `SyncBench.reclaimDuringFollowWait`), the verifier's VerifyC4CorrectBench2
  in the heartbeat form, with one handle and with two over the same ids; the bench waits on an O(1) condition
  (`reclaimSwept`: the alarm's store work over, its read after the reclaim adopted, no sweep owed) and checks afterwards
  that no member still waits for space. Release, load 4.6–7.4: one handle [5.60, 6.02, 5.42] ms, two handles [6.62,
  6.47, 6.55] ms, `✔ Test run with 1 test in 2 suites passed after 7.390 seconds`. With `EngineJobs.swift` as at
  `04ae782` (release, load 6.4–11.7): one handle [13.83, 12.08, 13.23] ms, two handles [15.12, 14.52, 14.25] ms,
  `BenchSync.swift:504:17: Expectation failed: (runs.min() ?? .infinity) <= Self.c2Budget` twice, `✘ Test run with 1
  test in 2 suites failed after 7.910 seconds with 2 issues.`
- **REENTRANCY:** no new `await` (the budget is synchronous); no ledger row.

### S1-15's run test under TSan — **open in cycle 5; Fixed in cycle 6 (ruling S3-R10)**

*Cycle 6:* the orchestrator ruled after this cycle (S3-R10, 2026-10-30) and cycle 6 applied the ruling (`daa2ba8`,
`.minutes(5)`, nothing cut): see "Cycle 6". The text below is cycle 5's record.

*Findings (both lenses):* the test (`.minutes(3)`) stays over half its limit under TSan; the requirements verifier
measured 129.863 s and 130.143 s beside a second TSan process at load 10.5–25.9 (72 %) and 61.949 s alone at load 24–49;
the correctness verifier 108.76 s in the bundle alone at load 26–35 (60 %). Cycle 3's time-out (194 s at load ~33) had
the paired shape.

- **No change to the guard.** S3-R4 allows `.minutes(3)` for a test over half of `.minutes(1)`, and `.minutes(5)` only
  for a model-based or exhaustive enumeration; this test is neither, and the rulings file holds no ruling for it. Its
  100,000 entries, the fetch-and-decode, the plan, the apply and its assertions stay (G3).
- **No cheaper step left in WP-F that reaches the bar.** Cycle 4's phases: the engine's decode of the 21 MB manifest
  (WP-A's `ManifestDecoder`, `ManifestParser.survey` and `parse`) about two thirds of the samples, WP-F's plan
  (`PlanBuilder`, mostly formatting 100,000 transfer ids) about an eighth, the store's apply and index commit (WP-B) most
  of the rest; the wire bytes are already encoded in slices (`c745edc`). Removing the whole plan phase would still
  leave the verifier's paired figure above 110 s, over the alternative bar of 90 s paired at load about 30.
- **Measured this cycle** (TSan, `.build-s3f-tsan` at `72b2ab2`): alone in the bundle 72.27 s at load 13–17 (with the
  1,000-member sweep test; the bundle `passed after 72.273 seconds`) and 47.50 s at load 3.7–4.7 (`passed after 47.507
  seconds`); beside a second TSan process (`.build-s3f/run-direct.sh`, two bundles at once) 79.19 s and 79.49 s at load
  4.1–13.9 (44 % of 3 minutes; both bundles `passed after 79.189` / `79.503 seconds`). So the test is under half of 3
  minutes paired at load up to about 14 and over it paired at load 10.5–25.9 (the verifier), which the alternative bar
  (paired, load about 30) does not accept.
- **Requested ruling (unchanged, with these figures):** `.minutes(5)` for this test only (130.1 s paired at load ≤ 26 is
  43 % of 5 minutes), recorded with the measurements above and cycle 4's, as the DECISIONS L4-R8 precedent line; or the
  parser's sanitizer cost routed to WP-A (`other-wp:a`; not a defect: release decodes the manifest in well under a
  second). Until a ruling, the guard stays `.minutes(3)` and the doc comment carries the measurements (`007a2bb`).

### Load-only benchmark misses, survivors, `other-wp:b`

- **`SyncBenchmarks` on a loaded host:** the verifier's four misses (P-4 ratio 3.89, P-11 1.01, network edges best 10.18
  ms, throttle extension [85.4, 41.2, 107.1] ms) came at load 24–226 and passed on its rerun at load 11–14; nothing
  changed. The whole suite is re-run under "Gate evidence (cycle 5)".
- **`noDispatchOwedFlag` and `noFlagPump`:** recorded as in cycles 3 and 4 (reasons there), §14 candidates (a) and (c);
  the ordered hold-seam test the cycle-4 entry sketches is not written.
- **other-wp:b:** P-13 (`BenchStorage.swift:249`) and `AssetStore.recordFailure`'s whole-index commit per 404 (a burst
  of N 404s rewrites the index N times, about 5 ms each at 10,000 records): routed to WP-B, with the suggestion to
  coalesce one burst's failure records into one ordered commit; P-13 to be re-run on a quiet host.

## Cycle 6: the cycle-5 verification findings

Every finding of the two cycle-5 lenses, with its disposition; the blocking ones first. The rulings file was re-read: it
now holds S3-R10 (2026-10-30) on the S1-15 run test's guard. Each mutant was applied in place on the committed tree,
rebuilt in `.build-s3f`, run and reverted (`git diff --stat Sources/` empty after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | R-SYN-11, F-22: in a `.reclaimed` or `.settle` sweep during an owed follow, `sweepSpaceParked`'s re-queue branch judged a job on its pre-follow lane; a follow that kept a prefetch id lowered the lane, the job was re-queued anyway and its bytes counted `ahead`, so the next user job was parked `insufficientSpace` and its fail-fast answered its waiter with a shortage that did not exist (PROBE-C5-LANEDROP) | **Fixed** (failing test `48c8dfc`, fix `b94fd27`, the sweep's park bound pinned `7c8d737`; below) |
| reqs (blocking) | S3-R10 issued but not applied: S1-15's run test still `.minutes(3)`, its doc comment and this draft still say the ruling is pending; 94.8 / 95.6 s paired at load 8.8–20.8 (53 % of 3 minutes) | **Fixed** (`daa2ba8`: the trait alone, `.minutes(5)`; doc comment, this draft, the Stage 5 note; below) |
| correct | The same guard, non-blocking under S3-R10 (71.47 s alone at load 17.7–30.6) | As above |
| reqs | `reclaimDuringFollowTurns` missed C2 in one run at load 8.4→16.1 right after load 540, and passed in every other run | No change (load only, S3-R5); re-run under "Gate evidence (cycle 6)" |
| reqs | `spaceSweepFollowsAtMostOneTurnOfJobs` at 27.4 / 27.8 s paired at load 8.8–20.8 (46 % of 60 s), about 20 other `.minutes(1)` Sync tests at 46–50 % in the same run | Recorded (cycle 5's DECISIONS line now carries the paired figure); no test over half its guard, so none raised (S3-R4); re-measured below |
| reqs | other-wp:b / other-wp:h: Storage time-outs (`StoreCrashTests.swift:167`, `LoopbackHTTPServerTests.swift:400`) at load 100–540 | **other-wp:b / other-wp:h:** not WP-F's files, not touched; the Storage target passed in the verifier's rerun at load 6–11 and in this cycle's `--quick` (load 12.8 → 178) and simulator runs ("Gate evidence (cycle 6)") |
| reqs, correct | Survivors `noDispatchOwedFlag` and `noFlagPump` carried over | Kept as recorded (§14 candidates (a) and (c)); no test this cycle |
| reqs, correct | other-wp:b: P-13 and the per-404 index commit | **other-wp:b:** `BenchStorage.swift` and `AssetStore.recordFailure` are WP-B's; not touched |

### The blocking correctness finding: a space sweep re-queued a job on its pre-follow lane — **Fixed**

*(Superseded in cycle 8: the sweep now follows every job it would judge before it orders them, and judges each once
at its post-follow place; the in-loop follow, re-judgement and re-queue this entry describes were removed in
`1b771e8`; see "Cycle 8".)*

*Finding (correctness lens, PROBE-C5-LANEDROP):* content C (5 MB) is listed by A, which has a user waiter, and by B, a
prefetch group's member, so its job is user-lane. During an owed follow the reclaim's sweep found C's job fits A's user
lane, followed it (`followBeforeActing`: A moves to its new content, B stays, the job drops to prefetch), and re-queued it
with its 5 MB counted `ahead`; the next user job K (3 MB) was then judged against 6 − 5 = 1 MB, parked
`insufficientSpace`, and its fail-fast answered K's waiter `insufficientSpace(required: 3000000, available: 999000)`
with 6 MB free, while the gate parked C's job and C never took the room. The cycle-4 entry reasoned that a lane drop only
shrinks the room, which is why the park branch re-reads the job; the re-queue branch did not, and there a drop turns
"fits" into "does not fit". (That premise is wrong in the other direction too: the opportunistic reading may exceed the
important one, so in the park branch a drop can turn "does not fit" into "fits"; fixed in cycle 7, under "Cycle 7".) At `s3-base` the follow moved every job in the apply's turn, so the window did not exist.

- **Failing test first** (`48c8dfc`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, `extension
  EngineSyncTests`): `R-SYN-11: a space sweep judges a job again on the lane its follow leaves before it re-queues it, so
  a lane the follow lowered takes no room from the next waiter (F-22)` (`spaceSweepJudgesAFollowedJobOnItsNewLane`,
  arguments `LaneDropVisit.followVisitedFirst` (the control: the follow visits C's job before the reclaim) and
  `.sweepFollowsFirst`), the verifier's probe with its setup asserted (the follow owed or not, the job's lane and ids,
  both jobs `awaitingSpace`), the follow-owed state after the sweep, C's job prefetch-lane and not queued, no invariant
  violation, K's waiter answered from its 3 MB, A's from its 16-byte content, C never started, and the sync complete. In
  the control the follow's turns are awaited without the clock driver (they are owned tasks), so the 60 s grace cannot
  end early. At `48c8dfc`: `EngineFollowTests.swift:845:9: Expectation failed: (try? kResult.get())?.byteSize ==
  Int64(kBytes.count)` / `K's waiter is answered from its 3 MB, with 6 MB of room for user work:
  failure(ZTronAssetModel.AssetError.insufficientSpace(required: 3000000, available: 999000))` with `visit →
  .sweepFollowsFirst`; the control passed; `✘ Test run with 1 test in 1 suite failed after 0.448 seconds with 1 issue.`
- **Fix** (`b94fd27`, `EngineJobs.swift`, `sweepSpaceParked`): after `followBeforeActing` returns `false` the sweep
  re-reads the job and judges it again (`spaceBlock(job, ahead: ahead)`) before it re-queues it or counts it in `ahead`;
  a job that no longer fits falls through to the code of a job that never did, so it stays parked when it was parked
  `insufficientSpace`, is left waiting (`awaitingSpace` with a wake expected), or is parked `insufficientSpace` with its
  figures (F-22's convention) against `parksPerPump`, scheduling the follow-up sweep when that bound is spent; it is never
  added to `ahead` or `spaceAdmitted`. Its follow is done and not counted again (`followFits` counts only a job that holds
  a moved id). The verifier's prototype (`proto-lanedrop.diff`) handled the drop inline and lacked the park bound; the
  fall-through shares the wait, the figures and the bound with the park branch instead. The doc comment of
  `sweepSpaceParked` is corrected. With the fix: `✔ Test "R-SYN-11: a space sweep judges a job again …" with 2 test cases
  passed after 0.610 seconds`; the Sync bundle `✔ Test run with 407 tests in 52 suites passed after 20.813 seconds`.
- **Mutants** (S3-R3 style, in place on `b94fd27`, rebuilt with `-warnings-as-errors`, reverted):
  - `noLaneRejudge` (`verdict = self.spaceBlock(job, ahead: ahead)` → `verdict = nil`, the pre-fix behaviour):
    `EngineFollowTests.swift:845:9: Expectation failed: (try? kResult.get())?.byteSize == Int64(kBytes.count)` / `failure(…
    insufficientSpace(required: 3000000, available: 999000))`; `✘ Test run with 1 test in 1 suite failed after 0.358
    seconds with 1 issue.` (Deleting the line instead fails the build: `variable 'verdict' was never mutated`.)
  - `noParkBound` (`guard parks < Self.parksPerPump, self.followFits(job, follows: &follows) else {` → `guard
    self.followFits(job, follows: &follows) else {`): the whole Sync bundle passed (`✔ Test run with 407 tests in 52
    suites passed after 12.075 seconds`); only the release benchmark measured that bound. So `7c8d737` adds
    `R-SYN-11: one space sweep turn parks at most parksPerPump jobs and leaves the rest to its follow-up sweep (C2)`
    (`EngineRegressionCycle8Tests.spaceSweepParksAtMostOneTurnOfJobs`: 576 members wait for 300 reaped bytes, the purge
    path's `.reclaimed` sweep runs with its follow-ups held, its one turn re-queues the first member and parks exactly
    `parksPerPump`; then every other member ends parked and no invariant breaks). Against `noParkBound`:
    `EngineRegressionCycle8Tests.swift:306:9: Expectation failed: turn.parked == SyncEngine.parksPerPump` / `one sweep
    turn parked 575 jobs, at most parksPerPump = 512`, and `:307:9` / `(parked: 575, waiting: 0, followUpHeld: false)`;
    `✘ Test run with 2 tests in 2 suites failed after 0.511 seconds with 2 issues.` With the bound: `passed after 0.130
    seconds`. The lane-drop park goes through that same guard line.
- **C2 (S3-R5):** the re-judgement adds one dictionary read and the ledger's O(1) `spaceBlock` per re-queued job (at
  most `readmissionsPerTurn` per turn); `reclaimDuringFollowTurns` re-run under "Gate evidence (cycle 6)".
- **REENTRANCY:** no new `await` (synchronous); no ledger row.

### S1-15's run test under TSan — **Fixed (ruling S3-R10)**

- **`daa2ba8`** (`EngineSync1LivenessTests.swift`): the trait alone becomes `.timeLimit(.minutes(5))`; outside the doc
  comment the diff is that one line (`git diff 39dadd4 daa2ba8 -- …EngineSync1LivenessTests.swift`), so the 100,000
  entries, every operation, every assertion and the cancellation checks stay (G3). The doc comment's last sentence (the
  guard awaiting a ruling) is replaced by S3-R10 and its figures: 101.8–130.1 s beside a second TSan process at load
  10–32 (34–43 % of 5 minutes), 47.5–72.3 s alone, and the cycle-5 verifiers' 94.8 / 95.6 s paired at load 8.8–20.8
  and 66.1 s alone at load 14–24 (71.5 s alone at 18–31); its earlier "so the guard is `.minutes(3)`" now reads "became".
- **Measured this cycle** (TSan, `.build-s3f-tsan` at `daa2ba8`): alone in the bundle (04:41:08–04:42:28, load
  10.9–23.5) `✔ Test "R-SYN-3: a 100,000-entry plan …" passed after 49.787 seconds` (17 % of 5 minutes); beside a second
  TSan process (`.build-s3f/run-direct.sh`, two bundles at once; 05:15:31–05:16:59, load 6.1–25.6) 84.583 s and 84.821 s
  (28 % of 5 minutes; both bundles `passed after 84.589` / `84.829 seconds`). An earlier paired run (04:42:51–04:45:47)
  is not a moderate-load measurement: two other close-outs' verifiers started their test bundles during it and the load
  rose from 7.9 to 54.7 (above 30 from 04:44:01, about 70 s into the run); there the test took 175.718 s and 175.840 s
  (59 % of 5 minutes), both bundles passed, no ThreadSanitizer report. By S3-R10's rule (half of 5 minutes at a load of
  about 30 or less) the guard holds: no measurement at a load of about 30 or less reaches half of 5 minutes (the highest
  is 130.1 s, the ruling's own figure, at load 10–32).
- **Stage 5 residual-risk note (S3-R10):** under ThreadSanitizer, WP-A's manifest parser (`ManifestDecoder`,
  `ManifestParser.survey` and `parse`) takes about two thirds of this test's 47–130 s decoding S1-15's 21 MB,
  100,000-entry manifest. It is not a defect: a release build decodes that manifest in well under a second, and no WP-A
  change is made. The risk carried to Stage 5 is the test's wall time on a loaded CI host: the guard is 5 minutes, and a
  paired TSan run at load above about 30 has not been measured.

### Hang-guard margins, load-only misses and `other-wp`

- **`spaceSweepFollowsAtMostOneTurnOfJobs` (`.minutes(1)`):** the cycle-5 verifier measured 27.371 and 27.816 s beside a
  second TSan process at load 8.8–20.8 (46 % of 60 s), and about 20 other `.minutes(1)` Sync tests at 46–50 % in that run
  (the highest `R-STO-1: a cancelled, paused or failed foreground …` at 29.809 s); none over half its limit, so S3-R4
  raises none. This cycle, paired at load 6.1–25.6: 23.710 s and 23.661 s (39 %); the
  new tests of this cycle 22.540 / 22.243 s (lane drop) and 20.981 / 20.627 s (park bound); the highest `.minutes(1)`
  Sync test was `R-SYN-4: the transfer is cancelled only after the last of 100 callers cancels` at 26.770 s (45 %), and no
  Sync test exceeded half its guard (both bundles `passed after 84.6 seconds`). In the earlier paired run at load 7.9 →
  54.7 (other verifiers' bundles started during it; not moderate) every one of these took 50–77 % of its guard
  (`spaceSweepFollowsAtMostOneTurnOfJobs` 39.3 s, the two new tests 34–38 s, the 100-caller cancel test 46.4 s); all
  passed. Recorded rule: if a paired run at a load of about 30 or less takes this test over
  30 s, its guard is raised to `.minutes(3)` under S3-R4 with the measurements.
- **`reclaimDuringFollowTurns`:** the verifier's single miss (one handle [12.04, 12.07, 12.53] ms, two [13.03, 21.00,
  20.57] ms) came at load 8.4→16.1 straight after a period at load 540; its other runs passed (5.47–7.55 ms). Load only
  (S3-R5); re-run below.
- **other-wp:b / other-wp:h:** the Storage time-outs at load 100–540 (`StoreCrashTests.swift:167`, `R-STO-5: a process
  kill followed by a power loss …`; `LoopbackHTTPServerTests.swift:400`) are WP-B's and WP-H's files: if they return at a
  moderate load, the orchestrator routes them to those work packages.
- **Survivors and `other-wp:b`:** `noDispatchOwedFlag` and `noFlagPump` stay §14 candidates (a) and (c); P-13 and
  `AssetStore.recordFailure`'s per-404 index commit stay routed to WP-B (not re-run).

## Cycle 7: the cycle-6 verification findings

Every finding of the two cycle-6 lenses, with its disposition; the blocking ones first. The rulings file was re-read:
unchanged since 03:00:55 (S3-R10 is the last ruling; none rules on the hang-guard margins, so S3-R4 applies as written).
Each mutant was applied in place on the committed tree, rebuilt in `.build-s3f` with `-warnings-as-errors`, run and
reverted (`git diff --stat Sources/` empty after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | R-SYN-11, F-22: `sweepSpaceParked`'s park branch judged a job on its pre-follow lane and parked it after `followBeforeActing` without judging it again; a follow that lowered a user-lane job to prefetch moved it onto the opportunistic reading, which may exceed the important one, so a job that now fits was parked `insufficientSpace` and its kept waiter answered `insufficientSpace(required: 5000000, available: 10000003)` (PROBE-C6-LANEGAIN) | **Fixed** (failing test `69e209e`, fix `22c7b89`; below) |
| reqs (blocking) | S3-R4 / S3-R10, S3F-2 S3-STAB-03: 31 one-minute Sync tests over 30 s in a paired TSan run at a 1-minute load of 16.7–34.5 (up to 38.4 s, 64 %), `spaceSweepFollowsAtMostOneTurnOfJobs` at 37.0 s, which meets cycle 6's own recorded rule | **Fixed** (re-measured paired at load 20–35: 93 one-minute guards raised to `.minutes(3)` (`1602a8b`) and three model walks from `.minutes(3)` to `.minutes(5)` (`7499908`), each with its figures; one 4-minute SPEC-scale guard over half awaits a ruling; nothing cut; below) |
| reqs | Test strength: a re-judged job that no longer fits is not pinned to be parked in the sweep's turn (mutants `skipNotFit` and `requeueNoAhead` survived the Sync bundle) | **Fixed** (`18921e4`: C's job read in the sweep's own turn; both mutants fail 6/6 and 3/3; below) |
| reqs | Records: "Authorised edits outside WP-F" omitted cycle 6's files | **Fixed** (cycles 6 and 7 added to that paragraph) |
| correct | Test strength: the `.read` sweep's lane drop and the kept waiter's F-22 figures on the park fall-through had no committed test | **Fixed** (`2b6cd11`: PROBE-C6-READDROP and PROBE-C6-PARKFIGURES committed as R-SYN-11 tests; both fail against `noLaneRejudge`; below) |
| reqs | `SyncBenchmarks` spread at load 13–19 (`shutdownTurns`, `refreshUnderGroupTurns`), clean at load 8–10 | No change (load only, S3-R5); re-run under "Gate evidence (cycle 7)" |
| correct | S1-15's run test under TSan: 190.9 s at load 21–446 (not moderate), 88.3 s at load 6.6–37.6 | Recorded in the Stage 5 note below; no change (S3-R10) |
| reqs, correct | Survivors `noDispatchOwedFlag` and `noFlagPump` carried over | Kept as recorded (§14 candidates (a) and (c)); no test this cycle |
| reqs, correct | other-wp:b / other-wp:h: P-13, `AssetStore.recordFailure`'s per-404 index commit, the Storage time-outs | **other-wp:b / other-wp:h:** not WP-F's files, not touched |

### The blocking correctness finding: a space sweep parked a job its follow had moved onto a volume with room — **Fixed**

*(Superseded in cycle 8: the sweep now follows every job it would judge before it orders them, and judges each once
at its post-follow place; the in-loop follow, re-judgement and re-queue this entry describes were removed in
`1b771e8`; see "Cycle 8".)*

*Finding (correctness lens, PROBE-C6-LANEGAIN):* content C (5 MB) is wanted by A (a user waiter) and B (a prefetch
waiter), so its job is user-lane; it waits `awaitingSpace` with no room for user work, 6 MB for prefetch work (the
opportunistic reading is 6 MB larger than the important one) and 4 MB pending reclaim. During an owed follow the
reclaim's `.reclaimed` sweep judged C on A's user lane (4 MB of room: does not fit), reached the park branch, followed
the job (A left, B stayed: prefetch, 10 MB of room) and parked it `insufficientSpace` anyway; its fail-fast answered B's
waiter `insufficientSpace(required: 5000000, available: 10000003)`, which breaks `headroom`'s documented invariant that
`required` exceeds `available` whenever a job is parked. The cycle-4 entry's premise that a lane drop "can only shrink
the room" is wrong: neither the store (`AssetStore+Reads.swift`) nor the ledger orders the two readings, and
`largestRoom` already takes their larger. The same failure occurs on the code before cycle 6 (`39dadd4`); at
`s3-base` the follow moved every job in the apply's turn, so the window did not exist. Whether a device reports an
opportunistic reading above the important one is not verified (below).

- **Failing test first** (`69e209e`, `EngineFollowTests.swift`, `extension EngineSyncTests`): `R-SYN-11: a space sweep
  judges a job again on the lane its follow leaves before it parks it, so a lane whose volume has room re-queues it
  (F-22)` (`spaceSweepRequeuesAFollowedJobItsNewLaneFits`, arguments `LaneDropVisit.followVisitedFirst` (control) and
  `.sweepFollowsFirst`): the verifier's probe with its setup asserted (the follow owed or not, the job's lane and ids,
  the job `awaitingSpace`; after the reclaim, C fits the opportunistic room and not the important one), the follow-owed
  state after the sweep, C's job not parked and prefetch-lane (or done), no invariant violation, B's waiter answered
  from C's 5 MB, A's from its 16-byte content, C's transfer started, and the sync complete. At `69e209e`:
  `EngineFollowTests.swift:972:9: Expectation failed: (try? bResult.get())?.byteSize == Int64(cBytes.count)` / `B's
  prefetch waiter is answered from C's 5 MB, with 10 MB of room for prefetch work:
  failure(ZTronAssetModel.AssetError.insufficientSpace(required: 5000000, available: 10000003))` and `:974:9:
  Expectation failed: await harness.source.starts.map(\.id).contains(a.transferID)`, both with `visit →
  .sweepFollowsFirst`; the control passed; `✘ Test run with 1 test in 1 suite failed after 0.387 seconds with 2
  issues.`
- **Fix** (`22c7b89`, `EngineJobs.swift`, `sweepSpaceParked`), the verifier's option (B): after the park branch's
  `followBeforeActing` the re-read job is judged again (`spaceBlock(parked, ahead: ahead)`); a job that fits is
  re-queued as an admitted one is (to `.queued`, enqueued, its bytes added to `ahead`, recorded in `spaceAdmitted`)
  within `readmissionsPerTurn`, and when that bound is spent the sweep schedules its follow-up and stops, leaving the
  followed job for the follow-up turn (which re-queues it without a second follow: it no longer holds a moved id). The
  re-queue code of both branches is one helper, `requeueSwept(_:ahead:)`. A job without a follow is the same job, which
  did not fit, so the re-judgement changes nothing for it. Option (A) (clamp the opportunistic reading to the important
  one) changes ADR-025/S2-23's use of the readings and needs a ruling; not taken. The doc comment of `sweepSpaceParked`
  and the park branch's comment now say the readings are not ordered and the job is judged again either way; the
  cycle-4 and cycle-6 entries above carry a correction note. With the fix: `✔ Test "R-SYN-11: a space sweep judges a
  job again on the lane its follow leaves before it parks it, …" with 2 test cases passed after 0.605 seconds`; the
  Sync bundle `✔ Test run with 409 tests in 52 suites passed after 11.119 seconds`.
- **Mutants:** removing the re-judgement is the code at `69e209e`, which fails the new test as quoted above. Removing
  the new branch's `readmissionsPerTurn` guard is not pinned by a test: that branch only runs for a job the turn
  follows, so it is already bounded by `followsPerTurn` (256) per turn, and the total re-queues of one turn stay under
  `readmissionsPerTurn + followsPerTurn` even without it (recorded under "Not verified here").
- **Not changed (no false answer, delay only; recorded):** `checkRunSettled`'s `admittedBySpace`, the `.read` sweep (it
  takes only `insufficientSpace` jobs, which never reach the park branch) and the waiting branch (a job left waiting is
  not followed) still read a job on its pre-follow lane until its follow visit; each can delay such a job until the
  next sweep or read, none answers a waiter.
- **C2 (S3-R5):** one more O(1) `spaceBlock` per parked job the sweep follows (at most `followsPerTurn` per turn).
- **REENTRANCY:** no new `await` (synchronous); no ledger row.

### Hang guards (S3-R4) — **Fixed**

*Finding (requirements lens):* in two TSan Sync bundles run at once at `daa2ba8` (1-minute load 16.65 → 34.48 in the
first wave, then up to 40), 31 tests with a one-minute guard took over 30 s (up to 38.4 s, 64 %), among them this
close-out's `EngineFollowTests` tests at `:609`, `:744`, `:346`, `:394`, `:230`, `:488`,
`EngineRegressionCycle8Tests.swift:261`, `EngineProbeChainTests.swift:116` and `EngineGiveUpInvariantTests.swift:15`;
`spaceSweepFollowsAtMostOneTurnOfJobs` at 37.0 s met cycle 6's recorded rule. No ruling answers it, so S3-R4 applies.

*Re-measured* (TSan bundle `.build-s3f-tsan` at `2b6cd11`, the cycle's code and tests before the guard commit, run
directly with `.build-s3f/run-direct.sh`, 1-minute load sampled every 5 s):

- **Paired, not moderate** (06:15:39–06:18:59, load 50.4–77.6, other close-outs' verifiers building and testing): both
  bundles failed on time limits alone, `✘ Test run with 411 tests in 52 suites failed after 196.462 seconds with 145
  issues.` / `197.278 seconds with 119 issues.`: 44 and 38 one-minute tests exceeded 60 s; every other issue belongs to a
  test that also exceeded its limit (the cancelled waits' expectations), and no ThreadSanitizer report. S3-R4 does not
  judge a run above load about 30; it is recorded as the host's limit (below, Stage 5 note).
- **Paired, moderate** (06:28:23–06:30:54, load 20.1 → 34.9, 31–35 for its second half): `✔ Test run with 411 tests in
  52 suites passed after 148.824 seconds.` / `148.896 seconds.`, no ThreadSanitizer report. 93 of the 335 one-minute
  Sync tests took over 30 s in at least one bundle (up to 55.1 s, 92 %), all 31 of the verifier's list among them; the
  other 242 took at most 29.97 s.
- **Alone** (06:31:23–06:32:24, load 12.9–18.4): `✔ Test run with 411 tests in 52 suites passed after 58.364 seconds.`,
  no report; the longest one-minute test 20.4 s (34 %).

*Fix* (`1602a8b`): each of the 93 tests' guard becomes `.timeLimit(.minutes(3))` (S3-R4) and its doc comment carries its
alone and paired figures and loads (and the cycle-6 verifier's paired figure where it measured one). The diff is the trait
and doc lines only (`git diff 2b6cd11 1602a8b -- Tests | grep '^[-+]'` shows nothing else): no operation, seed, crash
point or assertion is cut (G3). The long loops already check `Task.isCancelled` (S3F-2). The tests are not made cheaper:
alone they take 13–20 s at load 13–18, and the paired figures move with the whole bundle (every test of the first wave
took about a third of the bundle's 149 s), so the margin is the bundle's contention under TSan, not a step of any one
test.

| Test (display name, file) | alone (load 13–18) | paired (load 20–35) | cycle-6 verifier paired (load 17–34) | guard |
|---|---|---|---|---|
| `R-SYN-4: the transfer is cancelled only after the last of 100 calle …` (`EngineSingleFlightTests.swift`) | 20.3 s | 50.7–55.1 s (92 %) | 37.8–37.9 s | **3 min** |
| `R-SYN-3: lane queues stay within twice their live entries while que …` (`EngineSafetyTests.swift`) | 20.4 s | 50.3–51.3 s (86 %) | 38.3–38.4 s | **3 min** |
| `R-SYN-5: the breaker's parked order follows a parked job's rank as …` (`EngineProbeChainTests.swift`) | 20.0 s | 48.7–49.9 s (83 %) | 37.2–37.4 s | **3 min** |
| `R-SYN-7: a Low Data Mode flap reported as two conditions elements n …` (`EngineRegressionCycle10Tests.swift`) | 20.1 s | 48.8–49.8 s (83 %) | — | **3 min** |
| `R-SYN-2: no transfer of a replaced content starts after the apply w …` (`EngineFollowTests.swift`) | 19.9 s | 48.3–49.5 s (82 %) | 36.3–37.0 s | **3 min** |
| `R-SYN-11: one space sweep turn during an owed follow follows at mos …` (`EngineFollowTests.swift`) | 19.9 s | 48.5–49.0 s (82 %) | 37.0–37.0 s | **3 min** |
| `R-SYN-2: a queued user job of an id the apply dropped does not star …` (`EngineFollowTests.swift`) | 20.0 s | 48.5–49.0 s (82 %) | 36.6–36.7 s | **3 min** |
| `R-SYN-5: prefetch probes that each end without a verdict start no r …` (`EngineRegressionCycle21Tests.swift`) | 19.7 s | 47.5–48.9 s (82 %) | 34.4–36.4 s | **3 min** |
| `R-SYN-5: a run whose transfers open the 5xx breaker ends blocked an …` (`EngineRunPathTests.swift`) | 19.4 s | 46.5–48.1 s (80 %) | 35.8–35.8 s | **3 min** |
| `R-SYN-6: a run whose claim a lane-wide park left that a conditions …` (`EngineRegressionCycle17Tests.swift`) | 19.3 s | 46.0–47.2 s (79 %) | 35.2–35.2 s | **3 min** |
| `R-CAR-2: a failure of an id's replaced content before its follow vi …` (`EngineFollowTests.swift`) | 19.3 s | 46.2–47.2 s (79 %) | 35.1–35.2 s | **3 min** |
| `R-SYN-11: the kept prefetch waiter of a job a space sweep parks aft …` (`EngineFollowTests.swift`) | 19.3 s | 45.7–47.2 s (79 %) | — | **3 min** |
| `R-SYN-6: a run whose claim parked for space a follow-up free-space …` (`EngineRegressionCycle17Tests.swift`) | 19.2 s | 45.7–47.1 s (79 %) | 34.7–35.1 s | **3 min** |
| `R-STO-13: during legacy migration a page a user resolves is in the …` (`EngineLegacyMigrationTransferTests.swift`) | 19.2 s | 45.5–47.0 s (78 %) | 34.7–34.7 s | **3 min** |
| `R-SYN-6: a run whose failed-whenOnline claim a network-edge re-admi …` (`EngineRegressionCycle17Tests.swift`) | 19.2 s | 45.7–47.0 s (78 %) | 34.7–35.1 s | **3 min** |
| `R-SYN-6: a run whose claim parked for space the owed follow-up swee …` (`EngineRegressionCycle17Tests.swift`) | 19.2 s | 45.4–47.0 s (78 %) | 34.6–35.0 s | **3 min** |
| `R-SYN-4: 100 callers on one asset with seeded random cancellations …` (`EngineSingleFlightTests.swift`) | 20.1 s | 43.5–47.0 s (78 %) | — | **3 min** |
| `R-SYN-11: a space sweep judges a job again on the lane its follow l …` (`EngineFollowTests.swift`) | 19.2 s | 45.7–47.0 s (78 %) | 35.0–35.1 s | **3 min** |
| `R-SYN-11: a space sweep during an owed follow moves a listed id's i …` (`EngineFollowTests.swift`) | 18.7 s | 44.4–46.2 s (77 %) | 34.7–35.2 s | **3 min** |
| `R-SYN-12: transfer progress published to subscribers never exceeds …` (`EngineEventsTests.swift`) | 18.8 s | 42.4–45.6 s (76 %) | 33.0–33.1 s | **3 min** |
| `R-SYN-3: members of a released handle that regain an interest keep …` (`EngineRegressionCycle11Tests.swift`) | 18.8 s | 44.2–45.5 s (76 %) | — | **3 min** |
| `R-SYN-11: a space sweep judges a job again on the lane its follow l …` (`EngineFollowTests.swift`) | 18.7 s | 44.2–45.5 s (76 %) | 35.0–35.1 s | **3 min** |
| `R-SYN-5: prefetch members that wait for a slot and each end without …` (`EngineRegressionCycle22Tests.swift`) | 18.7 s | 44.6–45.4 s (76 %) | 33.6–33.8 s | **3 min** |
| `R-STO-1: a cancelled, paused or failed foreground transfer leaves n …` (`EngineLiveTransportTests.swift`) | 19.1 s | 43.8–44.9 s (75 %) | 36.9–37.0 s | **3 min** |
| `R-SYN-13: when the network returns under more members parked offlin …` (`EngineRegressionCycle9Tests.swift`) | 18.5 s | 43.7–44.9 s (75 %) | — | **3 min** |
| `R-CAR-4: a join's give-up of more than releasesPerTurn claims retir …` (`EngineGroupClaimTests.swift`) | 18.5 s | 43.6–44.6 s (74 %) | 32.9–33.0 s | **3 min** |
| `R-CAR-4: invariantViolations reports a registered group in releasin …` (`EngineGiveUpInvariantTests.swift`) | 18.5 s | 43.7–44.6 s (74 %) | 33.0–33.1 s | **3 min** |
| `R-STO-11: a later launch that resumes an interrupted legacy migrati …` (`EngineLegacyMigrationTransferTests.swift`) | 18.5 s | 43.1–44.5 s (74 %) | 33.4–33.8 s | **3 min** |
| `R-CAR-4: a lane-wide park during a handle's release parks every oth …` (`EngineRegressionCycle10Tests.swift`) | 18.5 s | 43.1–44.4 s (74 %) | — | **3 min** |
| `R-SYN-11: one space sweep turn parks at most parksPerPump jobs and …` (`EngineRegressionCycle8Tests.swift`) | 18.4 s | 41.7–43.1 s (72 %) | 32.2–32.8 s | **3 min** |
| `R-SYN-11: once the store reclaimed what jobs waited for, every one …` (`EngineRegressionCycle8Tests.swift`) | 18.5 s | 42.2–43.0 s (72 %) | — | **3 min** |
| `R-SYN-11: when the network returns under more queued members than o …` (`EngineRegressionCycle8Tests.swift`) | 18.2 s | 41.7–42.7 s (71 %) | — | **3 min** |
| `R-STO-11: when legacy migration ends while the run that took the la …` (`EngineLegacyMigrationTransferTests.swift`) | 18.0 s | 40.3–42.7 s (71 %) | 29.8–30.5 s | **3 min** |
| `R-SYN-3: lane queues stay within twice their live entries after a r …` (`EngineRegressionCycle11Tests.swift`) | 17.9 s | 42.1–42.2 s (70 %) | — | **3 min** |
| `R-CAR-4: a member of a released handle that another interest wants …` (`EngineRegressionCycle10Tests.swift`) | 17.5 s | 41.0–42.1 s (70 %) | — | **3 min** |
| `R-CAR-4: releasing a prefetch handle of more members than one turn …` (`EngineRegressionCycle9Tests.swift`) | 17.0 s | 39.1–42.0 s (70 %) | — | **3 min** |
| `R-SYN-14: after a sync quiesces the engine owns zero timers and zer …` (`EngineIdleTests.swift`) | 17.3 s | 38.9–41.7 s (69 %) | 30.1–30.5 s | **3 min** |
| `R-SYN-11: when the volume gains room for more members parked for sp …` (`EngineRegressionCycle9Tests.swift`) | 17.0 s | 40.1–41.4 s (69 %) | — | **3 min** |
| `R-SYN-5: a retry that falls due in the alarm turn of the cooldown's …` (`EngineRegressionCycle22Tests.swift`) | 16.9 s | 40.1–41.2 s (69 %) | 30.7–30.8 s | **3 min** |
| `R-STO-11: an id of the same content that joins a job during the job …` (`EngineLegacyMigrationTransferTests.swift`) | 17.6 s | 39.4–41.1 s (68 %) | 30.1–30.6 s | **3 min** |
| `R-STO-13: the prior-art files a bulk sync's jobs adopt during legac …` (`EngineLegacyMigrationTransferTests.swift`) | 19.0 s | 39.1–40.9 s (68 %) | 29.8–30.1 s | **3 min** |
| `R-SYN-3: members of a released handle that regain a user-initiated …` (`EngineRejoinLaneTests.swift`) | 17.1 s | 39.4–40.8 s (68 %) | — | **3 min** |
| `R-NET-8: an invalid resume yields resumeRejected and the engine's n …` (`EngineLiveTransportTests.swift`) | 17.6 s | 40.0–40.8 s (68 %) | 32.7–33.1 s | **3 min** |
| `R-STO-11: an id of the same content that joins a job during the ans …` (`EngineLegacyMigrationTransferTests.swift`) | 17.5 s | 40.1–40.8 s (68 %) | 30.7–31.9 s | **3 min** |
| `R-SYN-7: a lane-wide policy park that stops at its turn's bound rea …` (`EngineRegressionCycle10Tests.swift`) | 16.8 s | 39.0–39.4 s (66 %) | — | **3 min** |
| `R-SYN-5: a half-open probe that ends without a verdict lets the nex …` (`EngineRegressionCycle20Tests.swift`) | 17.1 s | 39.0–39.4 s (66 %) | — | **3 min** |
| `R-SYN-15: no store mutation or commit happens after close returns` (`EngineIdleTests.swift`) | 16.1 s | 38.9–39.1 s (65 %) | — | **3 min** |
| `R-SYN-5: a run started while the breaker is open ends blocked witho …` (`EngineOutcomeTests.swift`) | 16.6 s | 38.2–39.0 s (65 %) | — | **3 min** |
| `R-STO-13: the prior-art files legacy migration's own batches adopt …` (`EngineLegacyMigrationTransferTests.swift`) | 16.1 s | 36.3–38.8 s (65 %) | — | **3 min** |
| `R-CAR-4: releasing a user-initiated handle of more members than one …` (`EngineRegressionCycle9Tests.swift`) | 16.5 s | 37.1–38.7 s (65 %) | — | **3 min** |
| `R-STO-13: a prefetch job promoted to the user-initiated lane while …` (`EngineLegacyMigrationTransferTests.swift`) | 16.3 s | 36.9–38.6 s (64 %) | — | **3 min** |
| `R-SYN-11: a free-space read's sweep judges a followed job again on …` (`EngineFollowTests.swift`) | 16.1 s | 37.7–38.5 s (64 %) | — | **3 min** |
| `R-STO-13: an older answer of the store's deadline that the engine a …` (`EngineLegacyMigrationTransferTests.swift`) | 16.2 s | 36.4–37.7 s (63 %) | — | **3 min** |
| `R-STO-11: a prefetch group joined during legacy migration adopts th …` (`EngineLegacyMigrationTransferTests.swift`) | 16.1 s | 36.2–37.5 s (63 %) | — | **3 min** |
| `R-STO-13: ensureAvailable that joins a prefetch job while the job's …` (`EngineLegacyMigrationTransferTests.swift`) | 15.9 s | 35.8–37.1 s (62 %) | — | **3 min** |
| `R-SYN-12: two committed applies are followed in the store's order, …` (`EngineRegressionCycle5Tests.swift`) | 16.0 s | 36.0–36.7 s (61 %) | — | **3 min** |
| `R-SYN-7: bulk pauses on Low Data Mode and resumes when it is turned …` (`EngineConditionsTests.swift`) | 16.0 s | 35.9–36.7 s (61 %) | — | **3 min** |
| `R-SYN-6: a run whose claim parked for space the ledger admits alone …` (`EngineRegressionCycle18Tests.swift`) | 16.0 s | 35.9–36.6 s (61 %) | — | **3 min** |
| `R-STO-13: a job of two ids promoted while its read of the second id …` (`EngineLegacyMigrationTransferTests.swift`) | 15.8 s | 35.0–36.6 s (61 %) | — | **3 min** |
| `R-SYN-10: an ensureAvailable whose members fail fast as they become …` (`EngineRegressionRound2Tests.swift`) | 15.9 s | 35.2–36.0 s (60 %) | — | **3 min** |
| `R-SYN-5: a half-open probe superseded by an apply frees the probe slot` (`EngineRegressionRound2Tests.swift`) | 15.9 s | 35.6–35.9 s (60 %) | — | **3 min** |
| `R-SYN-6: a run whose last working claim ends after a half-open prob …` (`EngineRegressionCycle20Tests.swift`) | 15.9 s | 35.1–35.8 s (60 %) | — | **3 min** |
| `R-SYN-6: an offline run ends blocked and a new run starts when the …` (`EngineRunPathTests.swift`) | 15.9 s | 35.5–35.8 s (60 %) | — | **3 min** |
| `R-STO-11: a run that starts while the launch run waits for legacy m …` (`EngineLegacyMigrationTransferTests.swift`) | 15.5 s | 29.2–35.4 s (59 %) | — | **3 min** |
| `R-CLN-8: reportUnreadable announces, forgets and heals every asset …` (`EngineRegressionCycle3Tests.swift`) | 15.9 s | 33.8–35.2 s (59 %) | — | **3 min** |
| `R-STO-13: the prior-art files a migration batch adopted reach the r …` (`EngineLegacyMigrationTransferTests.swift`) | 15.5 s | 33.9–35.2 s (59 %) | — | **3 min** |
| `R-CAR-5: the retention scope bounds bulk runs and evicts excluded e …` (`EngineStoreTests.swift`) | 15.8 s | 32.3–35.0 s (58 %) | — | **3 min** |
| `R-STO-13: a job of two ids schedules the trailing install of its fi …` (`EngineLegacyMigrationTransferTests.swift`) | 15.2 s | 32.3–35.0 s (58 %) | — | **3 min** |
| `R-SYN-12: a prune an apply wrote before it threw is announced when …` (`EngineRegressionCycle4Tests.swift`) | 15.7 s | 33.5–34.5 s (57 %) | — | **3 min** |
| `R-SYN-10: ensureAvailable whose member waits for space fetches it a …` (`EngineRegressionCycle6Tests.swift`) | 15.5 s | 33.1–33.9 s (57 %) | — | **3 min** |
| `R-STO-11: ensureAvailable during legacy migration adopts the prior- …` (`EngineLegacyMigrationTransferTests.swift`) | 13.4 s | 32.4–33.3 s (55 %) | — | **3 min** |
| `R-STO-11: when a job's adoption of the last claimed prior-art file …` (`EngineLegacyMigrationTransferTests.swift`) | 13.8 s | 30.9–32.6 s (54 %) | — | **3 min** |
| `R-SYN-12: a subscriber stalled across two runs receives the second …` (`EngineEventOrderTests.swift`) | 14.0 s | 31.2–32.5 s (54 %) | — | **3 min** |
| `R-SYN-10: availability counts present, missing, stale and failed wi …` (`EngineStoreTests.swift`) | 13.9 s | 30.7–32.3 s (54 %) | — | **3 min** |
| `R-SYN-5: a transfer that probes after the cooldown publishes the ha …` (`EngineOutcomeTests.swift`) | 13.9 s | 30.9–32.2 s (54 %) | — | **3 min** |
| `R-STO-11: an explicit sync during legacy migration adopts every pri …` (`EngineLegacyMigrationTransferTests.swift`) | 13.9 s | 30.4–32.2 s (54 %) | — | **3 min** |
| `R-SYN-11: a job waiting for space keeps waiting after a reclaim tha …` (`EngineRegressionCycle8Tests.swift`) | 13.9 s | 30.8–32.1 s (53 %) | — | **3 min** |
| `R-SYN-16: maintenance finds a corrupted blob, announces its quarant …` (`EngineRecoveryTests.swift`) | 13.9 s | 30.5–32.0 s (53 %) | — | **3 min** |
| `R-SYN-5: a half-open probe whose publication fails the store's hash …` (`EngineRegressionRound2Tests.swift`) | 13.8 s | 30.1–31.8 s (53 %) | — | **3 min** |
| `R-SYN-15: no foreground staging write lands after the store is closed` (`EngineLiveTransportTests.swift`) | 14.0 s | 30.5–31.8 s (53 %) | 28.3–33.6 s | **3 min** |
| `R-STO-11: ensureAvailable's adoption of a prior-art file the held m …` (`EngineLegacyMigrationTransferTests.swift`) | 13.2 s | 29.9–31.6 s (53 %) | — | **3 min** |
| `R-SYN-11: ensureAvailable whose member waits for bytes a purge recl …` (`EngineRegressionCycle6Tests.swift`) | 13.8 s | 31.2–31.3 s (52 %) | — | **3 min** |
| `R-SYN-15: shutdown joins every owned task before it begins closing …` (`EngineSync1HalvesTests.swift`) | 13.2 s | 29.3–31.2 s (52 %) | — | **3 min** |
| `R-STO-11: a job whose last group is released while its pre-transfer …` (`EngineLegacyMigrationTransferTests.swift`) | 13.3 s | 29.7–31.2 s (52 %) | — | **3 min** |
| `R-OBS-3: the diagnostics keep the last 32 errors` (`EngineRunPathTests.swift`) | 13.9 s | 29.7–31.2 s (52 %) | — | **3 min** |
| `R-SYN-5: a pending run that waits for a half-open breaker starts on …` (`EngineRegressionCycle21Tests.swift`) | 13.6 s | 30.0–31.1 s (52 %) | — | **3 min** |
| `R-SYN-12: after a run's apply throws past its in-memory writes, the …` (`EngineRegressionCloseOutTests.swift`) | 13.3 s | 29.4–30.9 s (51 %) | — | **3 min** |
| `R-SYN-16: maintenance stops at its time budget on ManualTimeSource …` (`EngineStoreTests.swift`) | 13.2 s | 29.1–30.5 s (51 %) | — | **3 min** |
| `R-SYN-8: reconcile is committed before the first transfer starts` (`EngineSyncTests.swift`) | 13.1 s | 29.2–30.2 s (50 %) | — | **3 min** |
| `R-SYN-5: a run that starts while the half-open breaker admits only …` (`EngineRegressionCycle22Tests.swift`) | 13.2 s | 29.2–30.2 s (50 %) | — | **3 min** |
| `R-SYN-11: with eviction not permitted a run that does not fit evict …` (`EngineStoreTests.swift`) | 13.5 s | 29.1–30.2 s (50 %) | — | **3 min** |
| `R-STO-11: a user-initiated prefetch group's adoption of a prior-art …` (`EngineLegacyMigrationTransferTests.swift`) | 12.9 s | 28.6–30.2 s (50 %) | — | **3 min** |
| `R-SYN-13: runs that keep failing offline while the path reads satis …` (`EngineRegressionTests.swift`) | 12.9 s | 28.6–30.2 s (50 %) | — | **3 min** |

*Longer guards in the same moderate paired run* (S3-R4 judges every guard, not only the one-minute ones):

- **Raised to `.minutes(5)` (`7499908`)**, model-based walks over half of 3 minutes: `R-SYN-6: seeded walks over clock
  moves, held alarm turns, probe outcomes, 429s and space events …` (`EngineGateModelTests.gateModel`) 115.2–116.8 s
  (65 %), `R-SYN-6: the seeded gate walks with one slot reserved for user-initiated work …` (`gateModelWithReservedSlot`)
  115.5–116.7 s (65 %), and `R-SYN-3: seeded random releases and re-joins of overlapping handles …`
  (`EngineRegressionCycle12Tests.randomReleasesAndRejoins`, an invariant check after every seeded operation) 98.1–99.5 s
  (55 %); alone 45.2, 45.2 and 37.4 s at load 13–18; re-check pair 76.4–77.5, 76.4–77.2 and 65.0–65.5 s at load 6–27.
  Both walks already check `Task.isCancelled` per step (`EngineGateModelTests.swift:451`, `EngineRegressionCycle12Tests.swift:185`).
  Traits and doc comments only.
- **Ruling requested (not raised): `R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and
  subject during a 10,000-asset sync`** (`EngineEventsTests.stalledSubscriberIsBounded`, `.minutes(4)`, the L4-R8 precedent
  S3-R4 names): 132.0–132.4 s beside a second TSan process at load 20–35 (55 % of 4 minutes), 92.2–92.6 s at load 6–27
  (38 %), 51.5 s alone at load 13–18. It is neither model-based nor an exhaustive enumeration, so S3-R4 gives no step
  above it; its cost is the SPEC-scale 10,000-asset sync, as S1-15's was for S3-R10. Proposed: `.minutes(5)` under an
  S3-R10-style ruling, nothing cut. Until then it stays `.minutes(4)`.
- Every other 3-minute guard stayed at or under 87.9 s (49 %) in that run; S1-15's run test 148.8–148.9 s of its
  5 minutes (S3-R10; below).

*Re-check on the final tree* (`.build-s3f-tsan` rebuilt at `1602a8b` by the TSan gate run, two bundles at once,
06:42:53–06:44:41, load 5.9–27.0): `✔ Test run with 411 tests in 52 suites passed after 105.129 seconds.` / `105.671
seconds.`, no ThreadSanitizer report; the longest one-minute test 20.0 s (33 %), no one-minute test over 30 s; the
longest 3-minute test 77.5 s (43 %); `stalledSubscriberIsBounded` 92.6 s (39 % of 4 minutes); S1-15's run test 105.7 s
(35 % of 5 minutes).

### Test strength: the re-judged job's park in the sweep's own turn, and the two optional probes — **Fixed**

- **`18921e4`** (`spaceSweepJudgesAFollowedJobOnItsNewLane`): C's job is now also read in the first turn whose condition
  check sees K leave its wait (the reclaim's sweep turn; a condition is evaluated in every turn that notifies, the
  technique of `EngineGateModelTests.Recorder` and `EngineRegressionCycle22Tests.RunStartWatch`), through a
  Mutex-backed `SweepTurnWatch`, and must be `.blocked(.insufficientSpace)` there in both arguments. A read after the
  turn could not pin it: under `skipNotFit` the store's settle read (`settleUnwakeableSpaceWaits`, spawned in the
  alarm's turn) parks the job a turn later, which is why the verifier's probe failed only 4 of 10 times. The verifier's
  suggested `holdSpaceSweepFollowUps` would not have held that path (it is not a follow-up sweep). HEAD: 5 of 5 runs
  passed (`✔ Test run with 1 test in 1 suite passed after 0.538` … `0.434 seconds`). Mutants (in place, reverted):
  - `skipNotFit` (`if verdict != nil { continue }` after the re-judgement): 6 of 6 runs fail, `visit →
    .sweepFollowsFirst at EngineFollowTests.swift:871:9: Expectation failed: watch.state == .blocked(.insufficientSpace)`
    / `… not left awaitingSpace with nothing pending and no wake: Optional(ZTronAssetSync.JobState.blocked(
    ZTronAssetModel.BlockReason.awaitingSpace))`; `✘ Test run with 1 test in 1 suite failed after 0.445 seconds with 1
    issue.`
  - `requeueNoAhead` (re-queued without being counted ahead): 3 of 3 runs fail at the same line with
    `Optional(ZTronAssetSync.JobState.queued)`.
- **`2b6cd11`**: the correctness lens's two optional probes as R-SYN-11 tests in `EngineFollowTests.swift`, arguments
  `LaneDropVisit.allCases`: `R-SYN-11: a free-space read's sweep judges a followed job again on its new lane, so a lane
  the follow lowered takes no room from the next parked job` (`readSweepJudgesAFollowedJobOnItsNewLane`, PROBE-C6-READDROP:
  the `.read` sweep with group interests only) and `R-SYN-11: the kept prefetch waiter of a job a space sweep parks after
  its follow gets its own lane's figures (F-22)` (`spaceSweepParksAFollowedJobWithItsNewLanesFigures`,
  PROBE-C6-PARKFIGURES: B's waiter gets `insufficientSpace(required: 5000000, available: 0)`, K's and A's waiters their
  assets). HEAD: 3 of 3 runs pass (`✔ Test run with 2 tests in 1 suite passed after 1.031 seconds`). Against
  `noLaneRejudge` (`verdict = nil` after the follow, the behaviour before cycle 6): `visit → .sweepFollowsFirst at
  EngineFollowTests.swift:1114:9: Expectation failed: after.k != .blocked(.insufficientSpace)` / `K (3 MB, user lane)
  is re-queued for the 6 MB of room user work has: Optional(…blocked(…insufficientSpace))`, and `:1215:9: Expectation
  failed: (try? kResult.get())?.byteSize == Int64(kBytes.count)` / `failure(…insufficientSpace(required: 3000000,
  available: 999000))`; `✘ Test run with 2 tests in 1 suite failed after 1.994 seconds with 2 issues.`

### S1-15's run test, benchmarks, survivors and `other-wp`

- **S1-15's run test (S3-R10):** the correctness lens measured 190.914 s (64 % of 5 minutes) while another agent's
  simulator run drove the 1-minute load from 21 to 446 (above 30 for most of the test, so S3-R10 does not judge it), and
  88.302 s (29 %) at load 6.6–37.6; both bundles passed with no ThreadSanitizer report. Added to the Stage 5 note:
  S1-15's run test took 148.812 and 148.869 s beside a second TSan process at load 20–35 in this cycle (just under
  half of 5 minutes, 150 s; it is the bundle's longest test and ended last) and 58.358 s alone at load 13–18; the
  correctness lens's 190.9 s at load 21–446 and 88.3 s at load 6.6–37.6; a
  paired TSan run at load 50–78 timed out 44 and 38 one-minute Sync tests (time limits only, every other issue a
  consequence), so on this 8-core host the Sync bundle's one-minute guards hold under TSan beside a second TSan process
  only up to a load of about 35; a CI host should run the TSan Sync bundle alone or at a load at most about 30.
- **`SyncBenchmarks`:** the requirements lens's spread at load 13–19 (`shutdownTurns` [31.85, 8.19, 17.43] ms,
  `refreshUnderGroupTurns` [18.82, 9.12, 2.83] ms) was gone at load 8–10 ([1.35–1.49] and [1.21–2.03] ms): load only
  (S3-R5). Re-run under "Gate evidence (cycle 7)".
- **Survivors:** `noDispatchOwedFlag` and `noFlagPump` stay §14 candidates (a) and (c) (not re-run).
- **other-wp:b / other-wp:h:** P-13 (`BenchStorage.swift:249`), `AssetStore.recordFailure`'s per-404 index commit,
  `StoreCrashTests.swift:167` and `LoopbackHTTPServerTests.swift:400` are WP-B's and WP-H's; not touched.

## Cycle 8: the cycle-7 verification findings

Every finding of the two cycle-7 lenses, with its disposition; the blocking ones first. The rulings file was re-read: it
is unchanged since 03:00:55 (S3-R10 is still its last ruling; none answers the hang-guard request of cycle 7 or the
verifiers' cycle-7 request), so S3-R4 and S3-R10 apply as written. Each mutant was applied in place on the committed
tree, rebuilt in `.build-s3f` with `-warnings-as-errors`, run twice and reverted (`cmp` against the saved file after each).

| Lens | Finding | Disposition |
|---|---|---|
| correct (blocking) | R-SYN-11, F-28: `sweepSpaceParked` sorted its candidates by their pre-follow `queueRank` and followed each job only as it reached it, so a follow that lowered a job to prefetch, or raised the parked job of a moved id's new content to user work, left it judged at a place the pump does not serve it from; a user waiter's fail-fast reported a shortage the room did not have (PROBE-C7-RANK-ADMIT, -PARK, -PROMOTE) | **Fixed** (failing tests `18e9448`, fix `1b771e8`; below) |
| reqs (blocking) | S3-R4 / S3-R10, S3F-2 S3-STAB-03: `stalledSubscriberIsBounded` (124.8–125.4 s, 52 % of 4 minutes) and S1-15's run test (166.9–167.1 s, 56 % of 5 minutes) over half their guards in a paired TSan run at a 1-minute load of 17.9–36.1 (mean 29.5), with the ruling requested in cycle 7 still outstanding | **Ruling requested again** (no ruling in the file; nothing raised, nothing cut; re-measured and the steps examined; below) |
| reqs | Test strength: the cycle-7 park-branch re-queue was not pinned to count the job ahead (mutant `gainNoAhead` survived) | **Fixed** (`4812937`: PROBE-C7R-GAIN-AHEAD committed; the branch itself is gone in `1b771e8`, and the same omission in the one re-queue left, `requeueNoAhead`, fails the new test in both visits; below) |
| correct | Test strength (recorded): the cycle-7 branch's `readmissionsPerTurn` guard had no test; re-check that every early `break` still schedules the follow-up sweep if the loop is restructured | **Resolved** (the branch is gone; each early exit re-checked, and the new bounded-follow exit pinned; below) |
| reqs, correct | Survivors `noDispatchOwedFlag` and `noFlagPump` carried over | Kept as recorded (§14 candidates (a) and (c)); no test this cycle |
| correct | `SyncBenchmarks` misses at load 12–27 after a 5-minute load above 130 (`shutdownTurns`, `refreshUnderGroupTurns`, `changedRefreshTurns`), clean at load 8.9–10.5 | No change (load only, S3-R5); re-run under "Gate evidence (cycle 8)" |
| reqs, correct | other-wp:b: P-13 (`BenchStorage.swift:249`), `AssetStore.recordFailure` | **other-wp:b:** not WP-F's files, not touched |

### The blocking correctness finding: a space sweep judged followed jobs at their pre-follow places — **Fixed**

*Finding (correctness lens, PROBE-C7-RANK-ADMIT, -PARK and -PROMOTE):* `sweepSpaceParked` built and sorted its
candidates once, by `queueRank` before any follow, then followed each job as it reached it (`followBeforeActing`). A
follow changes ranks two ways: the followed job loses the moved user interest and may drop to prefetch, and the parked
job of the moved id's new content gains it and may rise to user work. Either way the job was judged at its old place:
prefetch work was admitted, and counted `ahead`, before user work the pump serves first, and the next user job's
fail-fast answered its waiter with a shortage although the room existed for it. ADMIT (equal readings, just under 6 MB
after the reclaim): C (5 MB, user through A, prefetch through B) fitted as user work, was followed to prefetch, still
fitted and was re-queued ahead of K (3 MB, user), whose waiter got `insufficientSpace(required: 3000000, available:
999000)`. PARK (the cycle-7 park-branch re-queue; 4 MB important, 8 MB opportunistic): K's waiter got
`insufficientSpace(required: 3900000, available: 0)`. PROMOTE (C wanted only by A; A moved onto P's content; 6 MB):
P was judged at its prefetch place after R, and A's user waiter got `insufficientSpace(required: 3000000, available:
2500000)`. Followed first, each sweep serves the user job and parks the prefetch one. ADMIT fails the same way at
`e3a4c1a` (cycle 6's re-judgement read the new lane's volume, not its place); at `s3-base` the follow moved every job in
the apply's turn, so no window existed.

- **Failing tests first** (`18e9448`, new file `Tests/ZTronAssetSyncTests/Engine/EngineSweepOrderTests.swift`,
  `extension EngineSyncTests`, arguments `LaneDropVisit.allCases`, `.timeLimit(.minutes(1))`):
  - `R-SYN-11: a space sweep judges a job its follow lowers to prefetch at its prefetch place, so the user job behind it
    is admitted first (F-28)` (`spaceSweepAdmitsUserWorkBeforeAJobItsFollowLowers`, PROBE-C7-RANK-ADMIT);
  - `R-SYN-11: a space sweep's park branch judges a job its follow lowers to prefetch at its prefetch place, so the user
    job behind it is admitted first (F-28)` (`spaceSweepParkBranchAdmitsUserWorkBeforeAJobItsFollowLowers`,
    PROBE-C7-RANK-PARK); both share `sweepJudgesALoweredJobAtItsNewPlace`;
  - `R-SYN-11: a space sweep judges the parked job its follow raises to user work at its user place, before prefetch
    work (F-28)` (`spaceSweepJudgesAJobItsFollowRaisesAtItsUserPlace`, PROBE-C7-RANK-PROMOTE).

  Each asserts its setup per visit (the follow owed or not, the jobs' ranks and tickets, both parked `awaitingSpace`),
  no invariant violation after the sweep, the user waiter answered from its content, the prefetch waiter answered
  `insufficientSpace` with its own size against a smaller `available`, A's waiter from its new content, and the sync
  complete. At `18e9448` (the code of `7426fee`), 3 of 3 runs, every `.followVisitedFirst` case passing:
  `EngineSweepOrderTests.swift:161:9: Expectation failed: (try? kResult.get())?.byteSize == Int64(kBytes.count)` / `K's
  user waiter is answered from its content: failure(ZTronAssetModel.AssetError.insufficientSpace(required: 3000000,
  available: 999000))` (ADMIT) and `… insufficientSpace(required: 3900000, available: 0))` (PARK), with `:166:25` (B's
  waiter was served instead); `:270:9` / `A's user waiter, moved onto P, is answered from P's 3 MB:
  failure(…insufficientSpace(required: 3000000, available: 2500000))` and `:271:9`, `:275:25` (PROMOTE); all with
  `visit → .sweepFollowsFirst`; `✘ Test run with 3 tests in 1 suite failed after 0.513 seconds with 7 issues.`
- **Fix** (`1b771e8`, `EngineJobs.swift`, `sweepSpaceParked`; the verifier's "fully faithful alternative", not the
  side-order prototype): while a follow is owed, the sweep first follows, in its sorted order, every candidate that holds
  an id the follow has not moved (`followSweptHolders`, which calls `followBeforeActing`: the follow's visit brought
  forward), at most `followsPerTurn` per turn; when it followed any, it collects and sorts the candidates again
  (`spaceSweepCandidates`), and only then judges them (`judgeSpaceParked`), each once, as the follow left it. A turn
  that has more holders than `followsPerTurn` follows that many, judges nothing, and leaves the rest to its follow-up
  sweep, since a job not followed yet would be judged at a place it may not keep. After the pre-phase no candidate holds
  a moved id (a candidate is `.blocked`, so `follow` moves every moved id it holds, and an id rerouted to a job is one
  the copy maps to that job), so the judging loop has no follow left: the in-loop follow, the cycle-5 re-judgement after
  it, the cycle-7 park-branch re-queue and `followFits` are removed. The prototype's side order was not taken: by its
  author's own account a job a follow joins whose new place precedes the followed job's is still judged after jobs
  already judged. With the fix, 3 of 3 runs of the ten space-sweep tests: `✔ Test run with 10 tests in 1 suite passed
  after 1.847 seconds` (… `1.815`, `1.814 seconds`); the Sync bundle `✔ Test run with 415 tests in 52 suites passed after
  11.919 seconds.`
- **Mutants** (in place, two runs each, the ten space-sweep tests):
  - `noReorder` (after the follows, keep the pre-follow order): 2 of 2 runs fail ADMIT and PARK at
    `EngineSweepOrderTests.swift:161:9` and PROMOTE at `:270:9`, `:271:9` (`visit → .sweepFollowsFirst`); `✘ Test run
    with 10 tests in 1 suite failed after 1.877 seconds with 7 issues.`
  - `noPreFollow` (no pre-phase: candidates holding moved ids are judged unfollowed): 2 of 2 runs fail all 10 tests,
    among them `EngineFollowTests.swift:596:9` (`!afterSweep.holds`), `:600:9` (`answered.fromNewContent`),
    `:904:9`, `:905:9`, `:910:9`, `:1157:9`, `:701:9` to `:703:9`, `EngineSweepOrderTests.swift:161:9`, `:271:9`,
    `:374:9`, and a 180 s time limit at `EngineFollowTests.swift:1181:6`; `✘ Test run with 10 tests in 1 suite failed
    after 192.013 seconds with 28 issues.`
  - `boundedJudges` (a turn over `followsPerTurn` judges anyway): 2 of 2 runs fail
    `EngineFollowTests.swift:703:9: Expectation failed: after.waiting == after.owed.small + after.owed.large &&
    after.waiting > 0`; `✘ Test run with 10 tests in 1 suite failed after 1.836 seconds with 1 issue.` That assertion
    is new in `spaceSweepFollowsAtMostOneTurnOfJobs` (`1b771e8`): a turn that could not follow every member judges
    none, so every member it did not follow still waits `awaitingSpace`. The test's doc comment and two messages now
    describe the new turn (it follows `followsPerTurn` jobs of both sizes and judges none); its existing assertions are
    unchanged.
  - `requeueNoAhead` (`requeueSwept` without adding the job's bytes to `ahead`): below.
- **Every early exit re-checked** (the correctness lens's recorded item): the two bound exits of the judging loop
  (`readmissionsPerTurn`, `parksPerPump`) schedule the follow-up sweep as before; the new bounded-follow exit schedules
  it (pinned by `boundedJudges` above); the read's room exits (before and after the re-collection, and in the loop) do
  not, as before, since nothing more can change (a follow moves interests, not sizes, and `largestRoom` does not read a
  job's lane). The cycle-7 branch whose `readmissionsPerTurn` guard had no test no longer exists.
- **`holdsMovedID`** (`EngineFollow.swift`) compares the copy's entry with the job's own entry by key
  (`SyncEngine.sameTransfer`, as the follow's pass does) instead of formatting a transfer per id: the pre-phase checks
  every candidate while a follow is owed, and a formatted transfer costs about 0.75 µs in release (7.5 ms at 10,000).
  `Job.transfer` and `Job.entry` are `let`s set from one entry (`addInterest`), and `sameTransfer` is true exactly when
  the two entries' `transferID`s are equal (both checksums equal, or neither has one and the identifier and remote path
  are equal), so the result is the same.
- **C2 (S3-R5):** per sweep turn while a follow is owed: one `holdsMovedID` per candidate (a lookup and a key comparison
  per id), at most `followsPerTurn` follows (as before, now before the judging rather than inside it), and, when it
  followed any, one more collection and sort of the candidates; the judging loop is unchanged in its bounds and now has
  no follow in it. Re-measured with the `BenchSync` benchmark `reclaimDuringFollowTurns` (its doc comment updated) under
  "Gate evidence (cycle 8)".
- **REENTRANCY:** no new `await` (synchronous); no ledger row.
- **Not changed (recorded under "Not verified here"):** the pre-phase follows the jobs the sweep judges. A job that is
  not parked for space (queued behind the follow, or downloading) and holds a moved id whose new content is a parked
  job is moved by the follow's own visit, not by the sweep: the sweep judges that parked job with the interests it
  holds when the sweep runs, and the moved interest reaches it later through `addInterest` (`relane` re-queues it if its
  raised lane fits, `failFastJoiner` answers the joiner with the room at that moment otherwise), as a request made at
  that moment would be.

### Test strength: a followed job re-queued ahead of the next one — **Fixed**

*Finding (requirements lens, PROBE-C7R-GAIN-AHEAD):* the cycle-7 park-branch re-queue was not pinned to count the job
ahead or record it in `spaceAdmitted` (mutant `gainNoAhead` survived the Sync bundle). `1b771e8` removes that branch (a
job is judged once, after its follow); the one re-queue left is `requeueSwept`, which every admitted job takes.

- **Test** (`4812937`, `EngineSweepOrderTests.swift`, arguments `LaneDropVisit.allCases`, `.timeLimit(.minutes(1))`):
  `R-SYN-11: a space sweep counts a followed job it re-queues ahead of the next parked job, which is parked in the
  sweep's turn when the room left does not hold it (F-22)` (`spaceSweepCountsAFollowedJobAheadOfTheNextOne`): the
  verifier's probe with its setup asserted per visit, D's job read in the sweep's own turn (`SweepTurnWatch`) and
  required `nil` or `.blocked(.insufficientSpace)`, no invariant violation, B's waiter answered from C's 5 MB, A's from
  its 16 bytes, D's `insufficientSpace` with its 7 MB against a smaller `available`, D's content never started, and the
  sync complete. With the fix: passes in both visits (3 of 3 runs of the ten space-sweep tests above).
- **Mutant `requeueNoAhead`** (`requeueSwept` does not add the job's bytes to `ahead`; `gainNoAhead`'s omission on the
  only re-queue left): 2 of 2 runs fail in both visits, `EngineSweepOrderTests.swift:374:9: Expectation failed:
  watch.state == nil || watch.state == .blocked(.insufficientSpace)` (`visit → .sweepFollowsFirst` and
  `.followVisitedFirst`); `✘ Test run with 10 tests in 1 suite failed after 1.908 seconds with 2 issues.`

### Hang guards (S3-R4 / S3-R10) — **ruling requested again; nothing raised, nothing cut**

*Finding (requirements lens, blocking; the correctness lens's informational item is the same request):* in the
verifier's second paired TSan run at `7426fee` (07:25:30–07:28:19; 1-minute load 17.9 → 36.1, mean 29.5 over 34
samples, at most 31.3 for the first 91 s and 33.4–36.1 for the last 75 s), `R-SYN-12: a stalled subscriber's backlog
never exceeds one slot per progress key and subject during a 10,000-asset sync` (`EngineEventsTests.stalledSubscriberIsBounded`,
`.minutes(4)`) took 124.8 / 125.4 s (52.3 % of 4 minutes) and S1-15's `R-SYN-3: a 100,000-entry plan never materialises
more than the pipeline plus the lookahead as jobs` (`runMaterialisesAPipelineAtATime`, `.minutes(5)`, S3-R10) 166.9 /
167.1 s (55.7 % of 5 minutes); both bundles passed with no ThreadSanitizer report. Its other runs: paired at load
16.0–32.4, 111.0 s (46 %) and 118.9–119.0 s (40 %); paired at load 19.6–25.6, 80.2–80.7 s (34 %) and 89.1 s (30 %);
alone at load 18–25, 92.7 s and 109.7 s; neither test ever timed out. Every other guard stayed under half in all three
paired runs. The verifier asks the orchestrator for (a) an S3-R10-style ruling (`.minutes(5)` for
`stalledSubscriberIsBounded`, whose cost is the SPEC-scale 10,000-asset sync under TSan, and S3-R10 amended to accept
S1-15's run test at 167 s at load 18–36), or (b) a ruling that a paired run whose 1-minute load is above 30 for most of a
test's duration is not "about 30".

*Disposition:* the rulings file holds no ruling on either test's margin (unchanged since 03:00:55; S3-R10 is its last
ruling). S3-R4 gives a test that is neither model-based nor exhaustive no step above `.minutes(3)`, S3-R10 fixes S1-15's
guard at `.minutes(5)`, and G3 forbids cuts, so WP-F changes neither guard and requests the ruling again, in the
verifier's terms (a) or (b) ("Proposed document changes"). The one option S3-R4 leaves WP-F, making each step cheaper,
was examined and does not reach the margin:

- **Where `stalledSubscriberIsBounded`'s time goes** (TSan, the test alone, `.build-s3f/c8-profile.sh`: the test
  process sampled with `sample` for 15 s, 08:20:38–08:21:01, load 1.9–2.4; the test `passed after 20.214 seconds`;
  inclusive sample counts, outermost frame per path): under the engine's transfer tasks (`closure #1 in
  SyncEngine.start(_:probe:)`, 16,648 samples) the store's publication (`AssetStore.publish`, WP-B: placement,
  binding, index records and the file system calls it makes) takes 9,985 and the fake source's transfer 1,443; the
  shared test fake `FakeFileSystem.perform` 6,235 of them across both. The engine's own work is the remaining third:
  `committed` 2,474 and `pump` 2,415 (overlapping), `resolveAll` 1,382, and about 950 samples of whole-`EngineState`
  copies that a debug build makes when an engine extension reads `self.state.<field>` through the `package private(set)`
  property's getter (`slotCounts` in every pump, `followOwed`, `notifyConditions`). No WP-F step dominates: removing
  those copies would mean changing how every engine file reads its state for a debug-only cost of about 6 % of the
  test's busy samples, which would not bring 52 % under 50 % at the verifier's load; the rest is WP-B's store and the
  shared fakes.
- **S1-15's run test:** cycle 4's phases stand: about two thirds of it is WP-A's parser decoding the 21 MB manifest
  under TSan (S3-R10), and WP-F's plan share is mostly formatting 100,000 transfer ids into `PlannedFetch.transfer`, a
  stored `package` property that S3-R6 forbids changing.

*Re-measured at the cycle's code* (TSan, `.build-s3f-tsan` at `4812937`, bundles run directly with
`.build-s3f/c8-tsan.sh`, 1-minute load every 5 s; the host stayed at a load of 2 to 19 through this cycle's TSan runs,
so no paired run near a load of 30 was possible here):

| Run | Load (1 min) | Bundle | `stalledSubscriberIsBounded` (4 min) | S1-15 run test (5 min) |
|---|---|---|---|---|
| paired, 08:22:07–08:23:37 | 1.9 → 18.6 (mean 11.8) | `415 tests in 52 suites passed after 87.311 seconds.` / `87.915 seconds.` | 81.9 s (34 %) | 87.3–87.9 s (29 %) |
| alone in the bundle, 08:24:02–08:24:58 | 9.1–11.2 | `passed after 53.848 seconds` | 49.5 s (21 %) | 53.8 s (18 %) |
| the test only, 08:20:38–08:21:01 | 1.9–2.4 | — | 20.2 s (8 %) | — |

No ThreadSanitizer report and no time-limit line in any of them. In the paired run every one-minute test took at most
23.3 s (39 %) except this cycle's four new R-SYN-11 tests (33.8–35.4 s, 58–59 %; their guards are below), and the
R-SYN-11 space-sweep tests of the same setup (3-minute guards since cycle 7) 30.0–36.7 s (20 %).

### Hang guards of this cycle's new tests (S3-R4) — **sized from measurements**

The four new tests (`EngineSweepOrderTests.swift`) took 33.8–35.4 s beside a second TSan process at load 1.9–18.6
(58–59 % of 60 s) and 21.9–22.2 s alone in the bundle at load 9–11, as the tests of the same setup in
`EngineFollowTests` do (33.1–36.7 s in the same paired run). `1b21195` gives each `.timeLimit(.minutes(3))` with its
figures in its doc comment; the diff is traits and doc lines only (`git diff 4812937 1b21195 -- Tests | grep '^[-+]'`
shows nothing else). Nothing is cut (G3).

| Test (display name) | alone (load 9–11) | paired (load 1.9–18.6) | guard |
|---|---|---|---|
| `R-SYN-11: a space sweep judges a job its follow lowers to prefetch at its prefetch place, …` | 21.9 s | 34.4–35.4 s (59 %) | **3 min** |
| `R-SYN-11: a space sweep's park branch judges a job its follow lowers to prefetch at its prefetch place, …` | 22.1 s | 33.9–35.2 s (59 %) | **3 min** |
| `R-SYN-11: a space sweep judges the parked job its follow raises to user work at its user place, …` | 22.2 s | 34.4–34.8 s (58 %) | **3 min** |
| `R-SYN-11: a space sweep counts a followed job it re-queues ahead of the next parked job, …` | 22.2 s | 33.8–34.9 s (58 %) | **3 min** |

### Benchmarks, survivors and `other-wp`

- **`SyncBenchmarks`** (release, the full benchmark command; figures under "Gate evidence (cycle 8)"): every WP-F
  benchmark within its budget at load 2.4–4.9, the cycle-7 load-only misses (`shutdownTurns`,
  `refreshUnderGroupTurns`, `changedRefreshTurns`) among them; the reclaim during an owed follow, which now follows
  before it judges, [7.85, 5.28, 5.13] ms with one handle and [6.27, 6.06, 6.17] ms with two (cycle 7: [5.86, 6.19,
  7.17] and [6.63, 8.06, 10.96] ms).
- **Survivors:** `noDispatchOwedFlag` and `noFlagPump` stay §14 candidates (a) and (c) (not re-run).
- **other-wp:b:** P-13 failed again in this cycle's full benchmark run (`BenchStorage.swift:249:13: Expectation failed:
  longest <= batchBudget`, at load 2.4–4.9); `AssetStore.recordFailure`'s per-404 index commit. WP-B's files, not
  touched.

## Cycle 9: the cycle-8 verification findings, and S3-R11 to S3-R13

Every finding of the two cycle-8 lenses (`.build-orchestrator/s3f-c8-issues.json`), with its disposition; the blocking
ones first. The rulings file now ends with S3-R12 (09:50), S3-R11 (12:50) and S3-R13 (above); they answer issues 0, 1, 4
and 5. Work went in the ruled order: S3-R11 item 6's tests first, failing at `40ecd95` (`7626a07`); then the design
(`d-root/design.diff`, reviewed, with R1 to R3: `02d51a0`); then each amendment's failing test before its fix; then
S3-R12, item 7 / (f) and S3-R13.

| Lens | Finding | Disposition |
|---|---|---|
| reqs (blocking), issue 0 | R-SYN-11, F-28: the cycle-8 pre-phase followed only space-parked holders, so the parked job of a moved id whose holder was downloading or queued was judged at its pre-follow place (PROBE-C8R-INFLIGHT-PROMOTE) | **Fixed by the follow barrier** (S3-R11): `spaceSweepJudgesAJobRaisedFromAHolderInFlightAtItsUserPlace` (both visits; its sweep-first case failing at `40ecd95`, committed in `7626a07`), passing from `02d51a0`: no sweep judges while a follow is owed |
| reqs (blocking), issue 1 | S3-R4 / S3-R10: hang-guard margins under paired TSan with the ruling outstanding | **Fixed (S3-R12)** in `0f21af8`: three guards raised one step with their figures; S1-15 stays at five minutes; the 29 one-minute tests recorded as non-blocking (below) |
| correct (blocking), issue 4 | R-SYN-11, F-28: a holder of a dropped id judged at its pre-follow place and lane (PROBE-C8-DROPPED, -DROPPED-KEEP, -DROPPED-LANE) | **Fixed by the follow barrier**: `sweepJudgesADroppedHolderAtItsFollowedPlace` (three cases, both visits; each sweep-first case failing at `40ecd95`, committed in `7626a07`), passing from `02d51a0` |
| correct (blocking), issue 5 | C2: `1b771e8`'s pre-phase put a turn's follows, a `holdsMovedID` scan and a second collect-and-sort ahead of the judging (VERIFY-C8-C2-MIXED 10.0–12.0 ms best) | **Fixed**: the pre-phase is gone (`02d51a0`); a sweep turn either follows or judges. VERIFY-C8-C2-MIXED is committed as `reclaimDuringMixedFollowTurns` (`cecf5aa`), with an A/B against the design build at equal load (below) |
| correct, issue 6 | Holders that are not space-parked (informational) | **Closed by the barrier**: no space verdict while the follow is owed, so the sweep judges after every owed visit; issue 0's test pins the in-flight case, and `barrierGivesAFreedSlotToTheJobTheOwedVisitPromotes` and `barrierRechecksAJoinOnTheRoomTheOwedVisitFrees` the pump's and the join's |
| correct, issue 7 | Stability (informational) | Answered by S3-R12 |
| reqs / correct, issues 3 and 9 | Survivors `noDispatchOwedFlag` and `noFlagPump` | Kept as §14 candidates (a) and (c); not re-run (with the barrier, a pump barred while no event waits is repeated at the follow's end only through a visit that moved a job or this flag; see "Not verified here") |
| reqs / correct, issues 2 and 8 | `other-wp:b`: P-13 and the Storage benchmarks at high load | **other-wp:b**: WP-B's files, not touched; re-run in this cycle's benchmark command (figures under "Gate evidence (cycle 9)") |

### The follow barrier (S3-R11) — **Implemented**

*The rule (F-28).* While a follow is owed (`followBarrier`: `followOwed`, or events still waiting for the drain) nothing
is admitted and no space verdict is given: the pump starts and parks nothing (`EngineDispatch.pump`, barred on
`followBarrier || drainingAfterFollow`, amendment (d)); a space sweep runs one follow turn or one drain turn
(`advanceFollowForSpaceSweep`) and owes itself to a follow-up sweep that judges once the barrier is down; a join's
re-check of a job parked `insufficientSpace` (`.spaceJoin`), an ENOSPC verdict (`.spaceFailure`), a queue place
(`.enqueue(transfer, front:)`, `.reinstate`) and the failure verdict of a job that still holds a moved id
(`.attemptFailed`) wait in `eventsAfterFollow`, in arrival order. The follow's last turn pumps and then drains them, at
most `eventsAfterFollowPerTurn` (512) per turn, on the state every visit left; the drain's last batch checks the run and
pumps. The follow's own visits are not deferred (`inFollowVisit`), nor is the drain's replay (`drainingAfterFollow`).
`invariantViolations()` states it: a pump waiting for a follow that nothing owes, events waiting with no follow owed and
no drain scheduled or running, places counted differently from the events, a waiting verdict without its event or on a
job that is not failed. 1b771e8's pre-phase (`followSweptHolders`, the second collect-and-sort) is gone, and so are
`followBeforeActing` and `awaitsFollow`.

*Design review (`d-root/design.diff` applied to `40ecd95`, then changed in `02d51a0`):*
- R1: D3's `.read` event and `adoptFreeSpace` are dropped; `readFreeSpace` adopts on arrival again (L4-R7), and the
  RE-S06 notes (`EngineRuns.swift`, `EngineCommands.swift`), `readFreeSpace`'s doc and the f-4 REENTRANCY notes say so.
- `EngineState.eventsAfterFollow`'s doc named a `settleEventsAfterFollow` that does not exist: it names
  `drainEventsAfterFollow`.
- `drainFollowUp` re-reads the idle state (`reconcileIdle()`), as the follow's own follow-up does: the drain's last
  batch can end the barrier with nothing left to do.
- The drain follow-up's spawn carries its REENTRANCY note (proposed row RE-S45 below).
- `EngineFollow.swift`'s `import ZTronAssetStorage` (needed only for the dropped `.read`) is removed.
- The design's `EngineFollowTests.swift` edits were taken with R2 and R3 (below); its R1 read hunks were not.

*Amendments (S3-R11 item 2), each with its failing test first:*

| Amendment | Failing test (commit) | Fix | What changed |
|---|---|---|---|
| (a) front and age | `barrierKeepsAPausedTransfersFrontPlace` (`27ec8c3`; both visits) | `eafe0f5` | `.enqueue(transfer, front:)`; the drain replays `enqueue(front:askedBefore: true)`, which keeps `queuedAt` (bulk aging); `reinstate` waits behind the barrier as `enqueue` does (in `401a0d2`) |
| (b) the stranded-job invariant | `barrierGatesARequestOnTheRoomTheOwedVisitFrees` (`7626a07`; tripped the invariant at `02d51a0`) | `401a0d2` | `placesAfterFollow` counts each waiting `.enqueue`/`.reinstate` per transfer; the stranded check exempts exactly those; the counts must equal the events'; events wait only while a follow is owed, a drain is scheduled or one runs (from `j-break/d3-amendment-A1-invariant.diff`) |
| (c) failure order | `barrierReroutesAFailedHoldersInterestInTheFollowsOrder` (PROBE-J-FAIL-REROUTE) and `barrierCreatesAFailedHoldersNewContentInTheFollowsOrder` (PROBE-J-FAIL-TICKET), `7626a07` | `84c82ea` | `defersFailure`: a failure of a job holding a moved id (`resolveAll` with `.failed`; `retryLater`, so `countFailedAttempt`'s answers at the cap; `spaceFailed`, deferred as `.spaceFailure` and decided by `decideSpaceFailure`) leaves flight `.failed(.nextRun)` with no answer and its active attempt cleared; `.attemptFailed(transfer, epoch:, verdict:)`; the follow's own visit moves the ids in order; the drain replays the verdict epoch-checked (`replayVerdict`, `followedForVerdict`), skipping a superseded job; a join meanwhile leaves the job failed and the drain re-runs `relane` after a retry verdict |
| (d) a drain over several turns | `barrierAdmitsNothingBetweenDrainTurns` (`fd93332`) | `8257b77` | the pump is barred on `followBarrier || drainingAfterFollow`; the drain's last batch pumps |
| (e) second-apply order | `barrierKeepsTheOwedVisitsOrderAcrossASecondFollow` (`80afb87`; 300 owed visits, two applies) | `5221f9f` | `followApplied` keeps `followOrder[followNext...]` in its order and appends the newly unfollowed jobs, sorted |
| (f) C2 of the follow's end | — | `cecf5aa` | `followEndTurn`, below |

*Deviation from the ruling's wording (recorded, NEEDS-HUMAN-REVIEW not required: internal type):* the event is
`.attemptFailed(transfer, epoch:, verdict: AttemptVerdict)`, where `AttemptVerdict` is `.resolve(AssetError)` or
`.retry(TransferError, answer: AssetError?)`, rather than a flat `(error, answer)` pair: the two failure paths replay
different calls (`resolveAll` and `retryLater`).

*Ruling R1 (the class's boundary).* PROBE-D2-READ-ORDER (a read lands while the follow owes the visit that joins A to
P: visit-first, A's re-check reads the room before the read), PROBE-D3-READ-PROMOTE (a read and its sweep land while the
follow owes the visit that moves a user waiter onto a parked job) and PROBE-J-UNRELATED-FREE (X, not moved, fails while
the follow owes the visit that re-routes A onto P: visit-first, A's re-check still counts X's bytes) are outside the
class: each differs only by when a free-space read or an ended transfer's freed bytes arrive. They are recorded here, not
committed: committing them would pin the arrival-order outcomes, which R1 says may depend on when the input arrives. They
were not re-run on this branch.

*Ruling R2.* `droppedUserJobWaitsForTheFollow` (R-SYN-2, `EngineFollowTests.swift`) now expects the freed slot to wait
for the follow's end, and then the unchanged prefetch member to start (one-to-one entry 1 below). The admission wait of a
multi-turn follow, measured by `followDrainTurns` (macOS release, 10,000 changed members and 10,000 waiting places):
the drain ended 141.4–148.6 ms after the release at load 7.5–8.9 (the design and the judges: 131–143 ms to the follow's
end). A Stage 5 residual risk; not measured on a device.

*Ruling R3: one-to-one replacements in `EngineFollowTests.swift` (no assertion deleted, no operation or scenario lost).*

| # | Test | Old | New | Reason |
|---|---|---|---|---|
| 1 | `droppedUserJobWaitsForTheFollow` (R-SYN-2) | `#expect(between.steady == .downloading, "the freed slot went to the unchanged prefetch member…")` | `#expect(between.steady == .queued, …)`, then, after the follow, `#expect(starts contain unchanged[0])` | R2: no admission behind the barrier; the slot goes to the job after the follow |
| 2 | `spaceSweepFollowsTheReplacedContent` (R-SYN-11) | `owed: engine.followOwed`; `#expect(afterSweep.owed, …)` | `drove: !engine.followOwed && engine.state.followFollowUpWaiting`; `#expect(afterSweep.drove, …)` | the sweep now runs the owed follow to its end before it judges, so the follow is no longer owed after it; the new assertion checks that the sweep found the visit owed (the follow's own turn is still held) and ran it |
| 3 | `spaceSweepJudgesAFollowedJobOnItsNewLane` | `afterSweep.owed == (visit == .sweepFollowsFirst)` | `afterSweep.drove == (visit == .sweepFollowsFirst)` | as 2 |
| 4 | `spaceSweepRequeuesAFollowedJobItsNewLaneFits` | as 3 | as 3 | as 2 |
| 5 | `readSweepJudgesAFollowedJobOnItsNewLane` | `after.owed == (…)` | `after.drove == (…)` | as 2 |

Waits only (no assertion changed): `replacedContentFailureFollowsTheWaiter` waits for `nil`, `.blocked` or now `.failed`
(the verdict waits for the follow, amendment (c)); `replacedContentFailureFollowsTheMember` waits until the 404's verdict
waits (`verdictsAfterFollow`), then releases the held follow turns; `readSweepJudgesAFollowedJobOnItsNewLane` waits for
the read's follow-up sweep (`d8de247`: it judges in a later turn, and the read raced it under load in `--quick`);
`droppedUserJobWaitsForTheFollow` and `barrierKeepsAPausedTransfersFrontPlace` wait for the attempt's handle before they
read the source's starts (`d8de247`). This cycle's own `barrierDecidesAnENOSPCOnTheFollowedState` waits for an adopted
read at most the figure it measured, not equal to it (`f91f108`): visit-first, A's replacement and the settled run can
commit to the volume after the measurement, and in the first TSan run of the whole Sync bundle the exact figure never
came (its `.followVisitedFirst` case hit the 3-minute guard, the run failing after 192.9 s with that issue and the
U-waiter expectation after the cancelled wait; alone under TSan it had passed ×3 in 2.06–2.08 s before the change, and
the whole bundle passed after it). Its assertions are unchanged.

*Item 6: the probes as tests* (in `EngineFollowBarrierTests.swift`, new, an extension of `EngineSyncTests`, unless noted;
each in both orders through `LaneDropVisit.allCases` except `barrierAdmitsNothingBetweenDrainTurns`, which has one
order by construction):

| Probe(s) | Test |
|---|---|
| C8-DROPPED, -DROPPED-KEEP, -DROPPED-LANE | `EngineSweepOrderTests.sweepJudgesADroppedHolderAtItsFollowedPlace` (three cases) |
| C8R-INFLIGHT-PROMOTE | `EngineSweepOrderTests.spaceSweepJudgesAJobRaisedFromAHolderInFlightAtItsUserPlace` |
| D-PUMP-FREED, D3-PUMP-ABANDON, D2-GATE-ABANDON (one scenario) | `barrierGatesARequestOnTheRoomTheOwedVisitFrees` |
| D-JOIN-FREED, D3-JOIN-ABANDON (one scenario) | `barrierRechecksAJoinOnTheRoomTheOwedVisitFrees` |
| D3-PUMP-PROMOTE | `barrierGivesAFreedSlotToTheJobTheOwedVisitPromotes` |
| D2-PUMP-PROMOTE | `barrierGivesTheOnlySlotToTheJobTheOwedVisitPromotes` |
| D-PUMP-PROMOTE | `barrierGivesAFreedSlotToTheJobTheOwedVisitCreates` |
| D3-PUMP-STALLED-USER | `barrierGivesAFreedSlotToTheUserWorkBehindAnEndedHead` |
| D3-TICKET | `barrierQueuesARequestAfterTheJobTheOwedVisitCreates` |
| J-HELD-RETICKET | `barrierKeepsTheTicketOfAJobThatHoldsNoMovedID` (passes at `40ecd95`: a guard) |
| D2-INFLIGHT-ABANDON | `barrierSweepsWithoutTheBytesTheOwedVisitAbandons` |
| D2-JOIN-ABANDON | `barrierSweepsARequestMadeDuringTheOwedFollow` |
| D2-FOLLOW-ORDER | `barrierCreatesNewContentInTheFollowsOrder` |
| D-ENOSPC | `barrierDecidesAnENOSPCOnTheFollowedState` |
| J-FAIL-REROUTE / J-FAIL-TICKET | `barrierReroutesAFailedHoldersInterestInTheFollowsOrder` / `barrierCreatesAFailedHoldersNewContentInTheFollowsOrder` |
| D-REFOLLOW / D-SHUTDOWN | `barrierHoldsAcrossASecondFollow` / `barrierAnswersEveryWaiterAtShutdown` (the latter passes at `40ecd95`: a guard) |
| amendment (a) / (d) / (e) | `barrierKeepsAPausedTransfersFrontPlace` / `barrierAdmitsNothingBetweenDrainTurns` / `barrierKeepsTheOwedVisitsOrderAcrossASecondFollow` |

*Residuals, recorded for the verifiers and the orchestrator (not fixed in cycle 9; cycle 10 fixed the first two and
re-measured the last two, see "Cycle 10" and "Gate evidence (cycle 10)"):*
- **A join while a `.resolve` verdict waits** (open; a decision that differs by visit order, so blocking by R1's
  criterion unless ruled otherwise). A job that holds a moved id fails with a final answer during the owed follow; its
  verdict waits. A new interest that joins that job before the drain (same content) stays on it, and the drain's
  `resolveAll` answers it with the failure. Visit-first, the failure had removed the job, and the join created a new job,
  which would download again. The fix needs the join's own place: record the joiners in `VerdictAfterFollow`, answer only
  the interests the job held at the failure, then re-create the job for the joiners with a fresh epoch, the join's
  `queuedAt` and a place event at the join's arrival. A retry verdict with a user joiner has the same placement gap
  (`relane` runs at the verdict's place in the drain, not at the join's). No test yet.
- **The offline and throttle exits** of a job that holds a moved id (`.failed(.whenOnline)` with its fail-fast, a 429's
  throttle park and its fail-fast answers) are not deferred: S3-R11 (c) names `resolveAll`, `retryLater`,
  `countFailedAttempt` and `spaceFailed` only. Their fail-fast answers can reach an interest the owed visit would have
  moved. For the orchestrator: extend (c) to them, or record them as outside the class. No test.
- **C2 of the judging turns after a follow.** The mixed benchmark's longest turn is now a judging turn of the
  `.reclaimed` sweep's follow-ups (each collects about 9,500 candidates, sorts them and walks past those already judged
  before it parks `parksPerPump` more): 4.0–7.7 ms per turn, rising across the 20 turns, in one run of a scratch
  heartbeat probe, and up to 11.8 ms in its second run (load not
  sampled; the probe was not committed). It is the cycle-7/8 sweep's own cost, not the barrier's (the A/B below shows the
  design build at the same figures), and close to C2 on this host: the benchmark's best of three stayed under 10 ms at
  load up to about 14 except in one run at load 9.9–12.0 (below). A §14 candidate: keep the sorted order across
  follow-up sweeps.
- **One-minute guards beside the new tests** (S3-R12 (4)'s class, recorded). The 23 new tests' cases now share the Sync
  bundle's start with every one-minute test: in this cycle's single TSan run 34 of them took 51.6–59.1 % of their guard
  (cycle 8's single run: the longest 14.6 s), the bundle 86.5 s against 54.4 s. A paired run may cross S3-R12 (2)'s
  line; for the orchestrator: serialise the new tests in a suite of their own, or extend S3-R12 (4). Figures under
  "Gate evidence (cycle 9)".

### C2 (S3-R11 items 2(f) and 7, S3-R5) — **Done**

Three `BenchSync` benchmarks beside `reclaimDuringFollowTurns` (`cecf5aa`); `reclaimDuringFollowWait` takes a
`changeEvery` parameter, and its doc no longer describes the removed pre-phase:
- `reclaimDuringMixedFollowTurns` (VERIFY-C8-C2-MIXED: 1 member in 20 changed, one and two handles);
- `followDrainTurns` (D3's VERIFY-D3-DRAIN-C2: 10,000 changed members, 10,000 places waiting; prints the follow's end
  and the drain's end after the release, R2's figure);
- `followEndTurn` (amendment (f)): `2 × followsPerTurn` members of a 10,000-member group change, so with the follow-ups
  held the follow owes exactly one full turn of visits; the release's turn is timed inside the actor
  (`releaseHeldFollow`) and checked to be the combined one (256 visits owed, nothing owed after it, 512 events drained
  in it); it also ends the follow's pass over the replaced copy (20,000 entries, more than `followScansPerTurn`).

| Benchmark (release, 10,000) | Load (1-min) | Runs (ms) |
|---|---|---|
| `reclaimDuringFollowTurns`, 1 / 2 handles | 7.5–8.9 | [3.31, 3.40, 3.59] / [4.10, 4.27, 4.20] |
| `reclaimDuringMixedFollowTurns`, 1 / 2 handles | 7.5–8.9 | [7.33, 7.52, 7.05] / [7.78, 8.03, 8.03] |
| `followDrainTurns` | 7.5–8.9 | [3.62, 3.62, 4.05]; drain ended [141.5, 148.6, 141.4] ms after the release |
| `followEndTurn`: the combined turn / the heartbeat | 7.5–8.9 | [3.32, 3.12, 3.34] / [3.34, 3.13, 3.34] |

Earlier the same session, at load 9.9–12.0, the mixed benchmark measured [24.5, 11.2, 12.8] and [11.8, 16.5, 11.4] ms
and at load 4.8–5.4 [11.4, 11.2, 9.2] and [10.6, 11.3, 9.7] ms. To tell load from code, the identical probe
(`VerifyC8C2Probe.swift`) ran alternately against a release build of the design (`40ecd95` plus `design.diff`, in
`.build-s3f/design-full`) and this branch, at load 9.8–14.2:

| Build | 1 handle (ms) | 2 handles (ms) |
|---|---|---|
| design, run 1 | [8.33, 8.23, 8.56] | [9.45, 9.16, 8.99] |
| this branch, run 1 | [7.80, 7.94, 8.14] | [7.67, 8.83, 7.55] |
| design, run 2 | [8.41, 8.58, 8.74] | [8.95, 8.44, 8.73] |
| this branch, run 2 | [8.39, 8.84, 8.94] | [8.38, 7.73, 8.80] |

The amendments cost nothing measurable here; the design panel's 5.7–6.0 ms was at load about 3, and its base (`40ecd95`)
measured 9.9–11.3 ms at that load (`d-root/logs/c2-base-mixed-3.log`, `-4.log`). The regression is gone as far as D3
removed it.

### Hang guards (S3-R12, S3-R4) — **Fixed**

- Raised one step in `0f21af8`, with the figures in each test's comment: `stalledSubscriberIsBounded` `.minutes(4)` →
  `.minutes(6)` (133.0–133.8 s, 55.7 %); `migrationLoopWaitsForTheLastAdoption` (R-SYN-14) `.minutes(3)` → `.minutes(5)`
  (89.0–90.2 s); `runWaitsForOwedClaims` (R-SYN-6) `.minutes(3)` → `.minutes(5)` (88.9–91.0 s). S1-15's run test stays
  `.minutes(5)`. Nothing was cut.
- Not raised (S3-R12 item 4), non-blocking: the 29 one-minute tests at 50.3–55.0 % in the cycle-8 verifier's pair2
  (`.build-orchestrator/s3f-probes-c8/reqs/logs/pair2-1min-overhalf.txt`), all in the bundles' first 35 s. They are, by
  file and line (the share of the guard in brackets): `EngineRegressionCycle3Tests.swift:169` R-INT-3 (55.0 %) and `:83`
  R-SYN-6 (54.2 %); `EngineFollowTests.swift:142` R-SYN-2 (54.7 %); `EngineRegressionRound2Tests.swift:495` R-SYN-16
  (54.7 %); `EngineLegacyMigrationTransferTests.swift:1214` R-STO-13 (54.5 %) and `:797` R-STO-11 (52.7 %);
  `EngineSyncTests.swift:107` R-SYN-8 (54.5 %), `:133` R-SYN-9 (53.1 %) and `:20` R-NET-1 (50.8 %);
  `EngineRecoveryTests.swift:219` R-SYN-6 (54.4 %) and `:175` R-SYN-5 (52.5 %); `EngineRegressionCycle18Tests.swift:232`
  and `:302` R-SYN-6 (54.0 %, 54.0 %); `EngineConditionsTests.swift:167` R-SYN-5 (53.9 %);
  `EngineRegressionCycle6Tests.swift:209` R-SYN-11 (53.1 %); `EngineRegressionCycle7Tests.swift:69` R-SYN-11 (53.1 %);
  `EngineRegressionTests.swift:133` R-SYN-10 (52.8 %); `EngineRegressionCycle14Tests.swift:20` R-SYN-2 (52.5 %);
  `EngineRegressionCloseOutTests.swift:55` R-SYN-10 (52.4 %); `EngineRunPathTests.swift:88` R-MAN-2 (52.3 %);
  `EngineMaintenanceStepTests.swift:114` R-SYN-16 (52.0 %); `EngineSync1LivenessTests.swift:119` R-SYN-10 (51.8 %);
  `EngineRegressionCycle22Tests.swift:344` R-SYN-6 (51.8 %); `EngineCommandTests.swift:37` R-SYN-9 (51.6 %) and `:264`
  R-CLN-4 (51.6 %); `EngineIdleTests.swift:175` R-SYN-12 (51.5 %); `EngineRegressionCycle19Tests.swift:103` R-SYN-6
  (51.5 %); `EngineRegressionRound3Tests.swift:201` R-SYN-6 (50.3 %); `EngineStoreTests.swift:183` R-CLN-5 (50.3 %).
- The new tests (19 in `EngineFollowBarrierTests`, 4 in `EngineSweepOrderTests`) take `.minutes(3)`: they share
  `EngineSweepOrderTests`' setup (2,100 changed entries, two forced syncs over 32 MB volumes), measured at 33.8–35.4 s
  under TSan beside a second TSan process in cycle 8. This cycle's TSan figures are under "Gate evidence (cycle 9)".

### S3-R13 (tools 6.4, 0 warnings) — **Done**

`git archive` of the branch head into `.build-s3f/t64`, line 1 set to `// swift-tools-version: 6.4` there only:
`swift build --build-tests -Xswiftc -warnings-as-errors` and `swift build -c release` both complete with 0 `warning:`
lines (figures under "Gate evidence (cycle 9)"). `Package.swift` is not edited in the worktree.

## Cycle 10: the cycle-9 verification findings

Every finding of the two cycle-9 lenses (17 issues, the cycle-10 task's findings list), with its disposition; the
blocking ones first. No ruling was added after S3-R13: the cycle is judged under S3-R11 (item 3: a decision that
differs from visit-first is blocking unless it rests on a real-world ledger input, R1), S3-R12 and S3-R13, each recorded
above as an "Orchestrator ruling (close-out)". Work went in the ruled order: the suite change first (`ae4cc97`), every
probe as a failing test (`801f483`, `6f80827`), the ENOSPC test's strengthening with its mutant (`95a019c`), then one
fix per group of findings, each after its failing test (`69eec26`, `f858048`, `e195e2d`; `b97368a` then `25081cd`),
then the non-blocking test strength (`a206500`).

| Lens | Finding | Disposition |
|---|---|---|
| reqs 0, correct 6 (blocking) | A user request that joins a job whose final (`.resolve`) verdict waits for the follow is answered with that failure; visit-first it creates a new job and is served (PROBE-C9-JOIN-RESOLVE, PROBE-C9R-JOIN-RESOLVE) | **Fixed** in `f858048`: `barrierServesARequestMadeAfterAWaitingFinalFailure` (both visits; sweep-first failing at `6f80827`'s tests on `801f483`'s sources, `EngineFollowBarrierVerdictTests.swift:68`, `:69`) |
| correct 7 (blocking) | A join of a job whose retry verdict waits is re-queued at the verdict's place in the drain, not at its own arrival (PROBE-C9-JOIN-RETRY-PLACE) | **Fixed** in `f858048`: `barrierPlacesAJoinOfAWaitingRetryAtItsArrival` (failing at `:126`) |
| correct 8 (blocking) | The follow's own visit marked a job whose retry verdict waits as joined, so the retry skipped its backoff (PROBE-C9-SPURIOUS-JOIN) | **Fixed** in `f858048`: `barrierKeepsAWaitingRetrysBackoffThroughTheVisit` (failing at `:170`, `:172`) |
| correct 11 (blocking) | `.enqueue` and `.reinstate` events carried no epoch, so a job removed and re-created by the visit took the removed job's place (PROBE-C9-STALE-PLACE) | **Fixed** in `69eec26`: `barrierGivesNoPlaceOfARemovedJobToItsSuccessor` (failing at `:248`) and its control `barrierStartsNewContentsInTheFollowsOrder` (passes in both orders before and after: the stale event is the cause) |
| correct 9 (blocking) | An offline exit's fail-fast answered an interest the owed visit moves (PROBE-C9-OFFLINE) | **Fixed** in `e195e2d`: `barrierAnswersAnOfflineExitOnTheFollowedState` (failing at `:300`, `:303`) |
| correct 10 (blocking) | A 429's park answered an interest the owed visit moves (PROBE-C9-THROTTLE) | **Fixed** in `e195e2d`: `barrierAnswersAThrottleParkOnTheFollowedState` (failing at `:353`) |
| reqs 1 (blocking) | The same for an interest the visit moves onto present content (PROBE-C9R-THROTTLE-PRESENT) | **Fixed** in `e195e2d`: `barrierLetsTheFollowAnswerAThrottledHoldersMovedInterest` (failing at `:406`) |
| reqs 2 (blocking) | The mutant `enospcNoDefer` survived `barrierDecidesAnENOSPCOnTheFollowedState` | **Fixed** in `95a019c`: the test keeps D's visit owed past the read's own follow turn; the mutant fails it 2/2 (below) |
| reqs 3 (blocking) | TSan: 43 time-outs at an S3-R12 mean of 40.45 | **Fixed** in `ae4cc97`: the F-28 tests run in a `.serialized` suite of their own; a TSan bundle with no time-out under "Gate evidence (cycle 10)" |
| reqs 4 | The simulator suite and the benchmarks were not completed by the verifier | **Done** here: under "Gate evidence (cycle 10)", the C2 figures against S3-R5 |
| reqs 5, correct 13 | Draft records: residuals proposed for §14 although S3-R11 item 3 makes them blocking; the 29 one-minute tests cited by file; cycle 9 missing from "Authorised edits"; the §7.10 claim overstated | **Fixed** in this draft: the cycle-9 residuals are closed below (and removed from §14 (d)/(e)); the 29 tests are listed under "Hang guards" of cycle 9; cycles 9 and 10 are named under "Authorised edits"; the §7.10 text is restated (cycle 10's entry under "Proposed document changes") |
| correct 12 | Test strength: the ENOSPC deferral (1, 2), the `.reinstate` replay (3), the `<= shrunk` read wait (4) | (1, 2) as reqs 2. (3) **Fixed** in `a206500`: `barrierReinstatesAReleasedMemberWantedAgain`, with a test seam that holds a release part-way (below). (4) **Fixed** in `95a019c`: the test no longer waits for a free-space figure; it waits for E's verdict itself (`failed(.at)` on the followed state, `blocked` on the state before D's visit), so an unrelated read cannot end the wait |
| correct 14 | TSan under extreme load (mean 684.54) | **No code change** (the finding says so); the re-run at a low load is under "Gate evidence (cycle 10)" |
| correct 15 | P-13's wall-time miss | **other-wp:b**: WP-B's file, not touched; re-run in this cycle's benchmark command |
| correct 16 | Unproven: amendment (e) with an incomplete old pass | **Analysed, not probed** (below); recorded for the next verification |

### The fixes — **Fixed**

All seven failing tests are in `Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierVerdictTests.swift` (new, an
extension of the serialized `EngineFollowBarrierTests`), each in both orders, expecting the visit-first outcome. At
`6f80827`'s tests on `801f483`'s sources: `✘ Test run with 31 tests in 1 suite failed after 28.318 seconds with 10
issues.`, every issue in a `.sweepFollowsFirst` case (`.build-s3f/head-run.log`). After `69eec26`: 6 tests failing (9
issues); after `f858048`: 3 (4 issues); after `e195e2d`: `✔ Test run with 31 tests in 1 suite passed`.

- *Epochs on places* (`69eec26`). `EventAfterFollow.enqueue` and `.reinstate` carry the asking job's epoch; the drain
  counts the place taken (`notePlaceTaken`) and skips it when the job is gone or re-created.
- *Joins and re-lanes behind a waiting verdict* (`f858048`). While a job's failure verdict waits (`verdictsAfterFollow`),
  a join (`addInterest`) waits too, as a `.join` event at its arrival, registered by interest and asset in
  `joinsAfterVerdict` (the invariants exempt exactly those from "holds an interest", and check the registry against
  the events). The drain replays it after the verdict: to the job the verdict left, or to a new job of the content when
  the verdict ended the job, which is what a visit-first engine's request met; a waiter cancelled, a group released or a
  run ended meanwhile joins nothing (`stillWants`), and an id a later apply moved is re-routed (`reroute`). A re-lane of
  such a job other than the follow's own (an interest withdrawn) waits as `.relane`; the follow's own visit of a failed
  job is a no-op, as it was on the running attempt visit-first (it set `joined` before, which skipped the backoff). The
  verdict reads `followedForVerdict` before it clears its marker, so that visit's re-lane is the follow's. The `joined`
  flag and the verdict's lane are gone from `VerdictAfterFollow`.
- *The offline exit and the 429's park* (`e195e2d`). Both are attempt verdicts now (`AttemptVerdict.offline(requeue:)`,
  `.throttle(until:at:)`), deferred by `defersFailure` like the four of S3-R11 (c). What arrives from the world is read
  on arrival (R1): whether an edge passed during the attempt and whether the path is satisfied, and the origin's throttle
  (`state.throttles`, set at once; `throttleExtended` runs at once). The replay gives the exit the attempt's end gave:
  a fresh attempt, or `failed(.whenOnline)` with the offline fail-fast; or the park with fail-fast answers read at the
  429's instant (`failFast(at:)`, `park(answeredAt:)`), so a waiter's `retryAfter` is the one the 429 gave.
- *An edge that meets a waiting verdict* (`b97368a`, then `25081cd`; found while fixing the offline exit, which created
  it). A satisfied edge re-queues `failed(.whenOnline)` and transient-backoff jobs (T19); a job whose offline verdict
  waits is `failed(nextRun)` then, which no edge re-queues, and the verdict then left it waiting for an edge that had
  passed (R-SYN-13). The edge now appends an `.edge` event per waiting verdict (in the order the edge's re-admission
  reads jobs), and the drain re-queues the job if the verdict left it owed on an edge.
  `barrierRetriesAWaitingOfflineFailureOnAnEdgeItMet` fails at `e195e2d` in the sweep-first order (C stays
  `failed(.whenOnline)`, one start: `EngineFollowBarrierVerdictTests.swift:369`, `:371`) and passes from `25081cd`.

The throttle tests' setup changed once before the fix commits (`6f80827`, test only): in `801f483`'s version the other
holder N was admitted after the barrier, under the real 429's throttle, so its admission waited (R2) and its own park
answered A even with the fix. N now runs for a user waiter before the apply; the test still fails at the pre-fix
sources (`:353`).

*The ENOSPC test* (`95a019c`). The read the ENOSPC triggers runs a space sweep, and a sweep behind the barrier runs one
follow turn (`advanceFollowForSpaceSweep`); with 52 fillers that turn visited D before the verdict, so the deferral
was never needed. 300 prefetch members whose contents v3 also changes now come before D in the copies, so that turn
visits 256 of them and stops; the sweep-first setup checks that D is still running and unvisited. The mutant
`enospcNoDefer` (the deferral removed, in a copy under `.build-s3f/mut`): `✘ … with 2 test cases failed` in both runs
(`.build-s3f/mut-enospc-1.log`, `-2.log`), each in `.sweepFollowsFirst`, U answered `insufficientSpace(required:
1500000, available: 1000000)` (`EngineFollowBarrierTests.swift:1052` then) after the 180 s limit at `:999`; the visit-first
order cannot fail it (nothing waits). Fixed and pre-fix sources both pass it.

*The `.reinstate` replay* (`a206500`). Behind the barrier no pump runs, so no released member is set aside, and the
release's later withdrawal re-queues a member a user request joined: a drain that skipped the replay gave the same
outcome (a first version of the test, without the seam, passed under that mutant). The
test seam `holdReleaseFollowUps()` / `resumeReleaseFollowUps()` (`EngineCommands.swift`, beside the other follow-up
holds; no production path sets it) keeps the release part-way, so the member is set aside before the follow and stays
released-only through it. Under the mutant: `✘ … with 2 test cases failed`, `.sweepFollowsFirst`, the member `queued`
(`EngineFollowBarrierTests.swift:789`) and the invariant "1 queued jobs wait set aside for a release, but other
interests want them" (`:790`).

*Suite* (`ae4cc97`). `EngineFollowBarrierTests` is a `@Suite(.serialized)` of its own; the 19 barrier tests and the 4
cycle-9 sweep-order tests moved into it (unchanged; the latter call `EngineSyncTests`' helpers), and this cycle's 10
join it: 33 tests, 66 cases, one at a time.

### Amendment (e) with an incomplete old pass — **analysed, not probed**

`followApplied` builds the order `owed + (unfollowed − owed).sorted()` and appends the new pass's scan after the old
one. `unfollowed − owed` holds jobs no pass found: joined for an entry the copy does not name (`noteJoin`), passed while
verifying or committing, or left by an adoption. If the old pass is incomplete, its remaining finds are appended after
them; visit-first, the old follow ends with those finds, and only the next follow visits the others (first, sorted).
So the visit order differs by construction when both sets are non-empty, and the new contents' jobs are created in a
different order (R-SYN-3 places). No probe was built in this cycle. A fix would hold `unfollowed − owed` until the old
scans in `followScans` at the apply are exhausted (for example a list carried by the new `FollowScan` and appended when
it starts). For the next verification: the probe as the finding describes it.

### Residuals found while fixing — **open, for the orchestrator**

Each is a decision taken while a follow is owed that can differ from visit-first (S3-R11 item 3), none probed:
- `answerThrottledUsers` (a scheduled turn after a throttle extension) answers the user interests of throttle-parked
  jobs while the barrier holds, including an interest the owed visit moves off such a job.
- A policy pause: `pauseIfRefused` (on a conditions element) and `paused`'s park read the job's pre-visit lane; a visit
  that raises the lane (a moved user interest) would have kept it running or re-queued it.
- `readmit` orders the deferred places (`.enqueue`) by pre-visit ranks; the throttle's delay without a `Retry-After`
  reads the job's pre-visit lane.
- The `.edge` events are appended before the deferred re-admissions of the same edge, whatever their ranks.
- A follow visit that re-lanes a queued job whose place still waits gives it a place in the visit and again at the drain.
- A withdrawal (a waiter cancelled) that arrives during the barrier overtakes the deferred answer it would have followed
  visit-first; arguably a real-world input (R1).

### Hang guards (S3-R12) — **unchanged**

No guard was raised or cut. The 10 new tests take `.minutes(3)` like the suite's others (0.6–3.8 s each alone, debug). TSan
figures under "Gate evidence (cycle 10)".

## Cycle 11: ruling S3-R14 (the follow-barrier class closed by inventory)

Cycle 11 applies **S3-R14** (recorded above as an "Orchestrator ruling (close-out)") and the cycle-10 verifiers'
non-blocking items. Work went in the ruled order: the inventory (below) first; the failing tests of the class members,
both orders, committed on their own (`2280fda`, 9 tests; `3dcf543`, amendment (e)); one fix (`6cc4d92`); then the tests
for the unreached branch and the survivor (`3b1315a`, `32c7ffe`). Every new test is in the serialized
`EngineFollowBarrierTests` suite (extensions in `EngineFollowBarrierClassTests.swift`, `EngineFollowBarrierApplyTests.swift`
and `EngineFollowBarrierSurvivorTests.swift`), runs through `LaneDropVisit.allCases` and expects the visit-first outcome.

| S3-R14 item / finding | Disposition |
|---|---|
| 1. Inventory of the decision sites in `Engine/` | **Done**: the table under "The inventory", 39 rows (I1–I38 and I13b); the rows marked **open** are the residuals R-A to R-E, each with a ruling request |
| 2. `answerThrottledUsers` during the barrier | **Fixed** in `6cc4d92`: `.throttleAnswers` replayed at its arrival instant; `barrierAnswersAThrottleExtensionOnTheFollowedState` (failing at `EngineFollowBarrierClassTests.swift:352`) |
| 2. `pauseIfRefused` on the pre-visit lane | **Fixed** in `6cc4d92`: the conditions pass waits whole (`.conditions(snapshot, edge:)`); `barrierPausesOnTheFollowedLane` (failing at `:53`, `:64`) |
| 2. `paused`'s park on the pre-visit lane | **Fixed** in `6cc4d92`: `AttemptVerdict.pause(policy:blocks:)`; `barrierDecidesAPauseOnTheFollowedLane` (failing at `:135`) |
| 2. `readmit`'s places on pre-visit ranks | **Fixed** in `6cc4d92`: `.readmit(passes, conditions)` replayed on the followed ranks; `barrierPlacesAReadmissionAsTheFollowLeavesIt` (failing at `:550`). **Corrected in cycle 13:** since cycle 12 the event is `.readmit(Readmissions)`, replayed under its decision instant's view (`withReading`); its deferral is pinned by `barrierReadmitsBehindTheOwedVisitsPlaces`, mutant `readmitNow` killed 2/2 at `EngineFollowBarrierReplayTests.swift:92` ("Cycle 13", mutant table) |
| 2. The no-Retry-After throttle delay on the pre-visit lane | **Fixed** in `6cc4d92`: `replayThrottle` takes the backoff of the lane the visits left; `barrierThrottlesForTheFollowedLane` (failing at `:278`); the park's answer instant: `barrierAnswersAThrottleParkWithItsOwnWait` (failing at `:206`, `:213`) |
| 2. `.edge` events before the same edge's re-admissions | **Fixed** in `6cc4d92`: the `.edge` event is gone; the edge's owed set and re-admission are part of the replayed conditions pass; `barrierReadmitsAnEdgeInItsOwnOrder` (failing at `:615`) |
| 2. A visit re-lane of a job whose place waits | **Fixed** in `6cc4d92` for every path a request takes (a request's whole join waits, so the visit meets no request's waiting place): `barrierJoinsARequestToTheJobTheFollowCreates` (PROBE-C10-DOUBLE-PLACE, failing at `:486`). One non-request path is left (a publication's ENOENT re-queue, row I8): R-A. **Corrected in cycle 12:** that path waits as `.requeue` and the `.enqueue` event is removed ("Cycle 12") |
| 2. Amendment (e) with an incomplete old pass | **Fixed** in `6cc4d92`: `followCarried` holds the unfollowed-but-not-owed jobs until the older scans end; `barrierCarriesUnfollowedJobsBehindAnOwedPass` (failing at `3dcf543`, `EngineFollowBarrierApplyTests.swift:125`, `(f: Optional(5), v: Optional(4))`, 2/2) |
| 3. A withdrawal that overtakes a deferred answer | **Fixed** in `6cc4d92` (**corrected in cycle 13:** only a waiter's `.removal` still waits; `.release`, `.continueReleases`, `.purge`, `.endClaim`, `.endClaims` and `removeInterest`'s `.removal` apply on arrival since S3-R16 item 3, "Cycle 13", removals 4–7): the caller is answered at once, the removal waits (`.removal`, `.release`, `.continueReleases`, `.purge`); `barrierAppliesAWithdrawalAfterTheVerdictItFollowed` asserts R-SYN-4/R-SYN-10 (`:47`) and R-CAR-4 (`:65`) (failing at `:420`, `:422`, `:423`) |
| 4. The `.relane` replay (0 hits) | **Branch removed** (justified below); its role, the `return` in `relane`'s failed branch, is pinned: mutant `relaneNoDefer` killed 2/2 by 5 tests |
| 4. `replayJoin`'s re-route (0 hits) | **Test** `barrierReroutesAJoinALaterApplyMoved` (`3b1315a`); mutant `noReroute` killed 2/2 (`EngineFollowBarrierApplyTests.swift:186`) |
| 5. `noFlagPump` | **Killed**: `barrierFillsAFreedSlotInTheFollowsLastTurn` (`32c7ffe`), 2/2 (`EngineFollowBarrierSurvivorTests.swift:56`) |
| 5. `noDispatchOwedFlag` | **Not equivalent; no committed test** (R-E): the probe shows the run starting with M still parked under the mutant (`waiting` 1) and not without it (0), 2/2; the scenario then stalls in store work that also stalls on `2280fda`'s sources. Ruling requested |
| 6. Suites, guards, C2, S3-R12, S3-R13 | **Applied**: the new tests are `.minutes(3)` like the suite's; figures under "Gate evidence (cycle 11)" |
| Non-blocking: tests for the survivors `relaneNoDefer`, `throttleAtNow` | **Done**: both killed 2/2 (below) |
| Non-blocking: PROBE-C9-THROTTLE's R2 attribution | **Recorded with figures; ruling requested** (below) |
| Non-blocking: §7.10 text against R1 | **Fixed** in this draft ("Proposed document changes", cycle 11) |
| Non-blocking: P-13 | **other-wp:b** (WP-B's benchmark; not touched; re-run under "Gate evidence (cycle 11)") |
| Non-blocking: Transport simulator time-outs (21 at load 333–351 in the cycle-10 verifier's run) | **other-wp:h** (WP-H's tests; not touched; this cycle's simulator run under "Gate evidence (cycle 11)") |
| Non-blocking: TSan run-1 time-outs | **Recorded** (below): no change under S3-R12 (2) |

### The inventory (S3-R14 item 1)

**Corrected in cycle 12 (S3-R15 item 7):** rows I5, I6, I8, I12, I13b, I14, I18, I26, I35 and I36 below are
replaced by "The inventory, corrected" under "Cycle 12"; the other rows stand. **Corrected again in cycle 13 (S3-R16,
finding 6 of the cycle-12 verifiers):** the preamble below, I1's gate clause and rows I5, I6, I8, I12, I13b, I14, I17,
I18, I20, I21, I22, I25 and I30–I33 are replaced by "The inventory, corrected (cycle 13)" under "Cycle 13".

"Behind the barrier" means while `followBarrier` holds (`followOwed`, or events wait for the drain, a drain follow-up
scheduled or a drain batch in progress) and the site is reached from neither the follow's own visit
(`inFollowVisit`) nor the drain's replay (`drainingAfterFollow`): those two are the visit-first order itself (a visit's
decision, or an event applied at its arrival place on the followed state). `defersToFollow` is exactly that test. An
event replayed by the drain runs with `replayInstant` set to its arrival, so `decisionNow()` (a place's request time, a
backoff's start, a fail-fast's wait) counts from the arrival. Line numbers are those at `32c7ffe`, under
`Sources/ZTronAssetSync/Engine/`. R1 means S3-R14 item 1's R1 (bytes freed by an ended transfer and free-space reads);
"world input" means S3-R14 item 2's note (the network edge and the origin's throttle signal apply on arrival).

| # | Site | Decision | Behind the barrier? | How it waits (event → replay), or why it is outside the class |
|---|---|---|---|---|
| I1 | `EngineDispatch.pump` :89, with everything only it calls: `dispatch` :366, `parkLane` :395, `continueLaneParks` :422, `park` :469, `gate` :490, `spaceBlock` :577, `headroom` :595, `preemptForUser` :606, `start` :674, `ensureProbeCandidate` (from :174), `reconsiderPendingRun` (from :181) | admits, starts, parks, fails fast (`park` → `failFast`), preempts, gives the probe | yes, from every caller | Refused at once (`followBarrier \|\| drainingAfterFollow`): `pumpWaitsForFollow` is set and the ensure refill scheduled. Each follow turn pumps again on that flag (`continueFollow`, both exits; mutant `noFlagPump`), and the drain's last batch pumps on the followed state. `start` has no other caller; behind the barrier `park` is reached otherwise only from the replays (I10–I12) |
| I2 | `EngineRuns.materializeRun` :475 and `materializeEnsures`, run by `pump` before its check | a run's or an ensure's claims join jobs | yes | Each claim is an `addInterest` (I14): it waits as `.join` |
| I3 | `EngineDispatch.drive` :762, `onProgress` :885 | the transport's priority from the job's lane; progress publication | yes | Not a decision: a priority hint to the transport and an observer event (no admission, answer, park or place) |
| I4 | `EngineDispatch.finishAttempt` / `drained` :957 | routes an attempt's terminal | yes | Routes to I5, I8, I10–I13; its `pump()` is refused (I1) |
| I5 | `EngineDispatch.publish` :989 | `.verifying`; the store's urgency from the lane | yes | At once: the attempt's own end. The binding is the job's ids at publication; an id the apply moved is not bound by the store and is re-routed by I6. **Open (R-A)** |
| I6 | `EngineDispatch.committed` :1051 | answers the bound interests with success; re-routes the unbound ones | yes | The success answers at once (**open, R-A**); each re-route goes through `reroute` (I7), whose join waits as `.join` |
| I7 | `EngineDispatch.reroute` :1097 | answers from the store when it holds the id's current content (`answerPresent`), else joins | yes | The join waits (I14). The store answer reads the store's binding of the id's current entry, which the apply wrote, and no lane, rank, place or interest of a job |
| I8 | `EngineDispatch.publicationFailed` :1142 | retry, final answer, ENOSPC, re-queue, supersede | yes | `.fileSystem` → `retryLater` (`.retry`, I11); `.unknownAsset`, `.notPresent`, `.assetFailed`, `.unverifiedRejected`, `.locked`, `.purgeRaced`, `.storageUnavailable` → `resolveAll(.failed)` (`.resolve`, I19); ENOSPC → `spaceFailed` (I13). At once: `.superseded` (`.queued`, then `supersede`, whose joins wait) and ENOENT after a cancelled attempt (`.queued`, then `enqueue`, whose place waits as `.enqueue`). **Open (R-A)** for those two |
| I9 | `EngineDispatch.supersede` :1199 | re-routes every interest | yes | Through `reroute` (I7); its pump is refused |
| I10 | `EngineFailures.paused` :14 | re-queue at the front, or park on a policy block | yes | `defersFailure(.pause(policy:blocks:))` with the lane-wide blocks of the arrival; `replayVerdict` parks or re-queues on the lane the visits left (cycle 11). On arrival: `recordBreaker(.abandoned)` (R-B) |
| I11 | `EngineFailures.failed` :72, `requeue` :231, `retryLater` :244, `countFailedAttempt` :286 | final answer, retry, its backoff and caps, re-queue, the offline exit | yes | `defersFailure` (`.resolve`, `.retry`, `.requeue`, `.offline(requeue:)`), replayed by `replayVerdict` after the follow's own visit of the job (`followedForVerdict`). On arrival only world inputs (an edge passed during the attempt, the path satisfied) and the breaker outcome and failure metrics (R-B) |
| I12 | `EngineFailures.throttled` :344 | the origin's throttle; the park; its fail-fast answers | yes | On arrival: the throttle end from a Retry-After within the caps (world input) and `throttleExtended`. The park waits (`.throttle(facts)`): `replayThrottle` takes the backoff of the lane the visits left (cycle 11) and answers at the 429's instant (`answeredAt: facts.at`; mutant `throttleAtNow`) |
| I13 | `EngineFailures.spaceFailed` :557, `decideSpaceFailure` :576 | the ENOSPC verdict | yes | The free-space read applies on arrival (R1); the verdict waits (`.spaceFailure` → `decideSpaceFailure` after `followedForVerdict`) |
| I14 | `EngineJobs.addInterest` :108, from `performAwaitAsset`, `joinMember`, `readPresentLocation`, `EngineManifest.join`, `reroute`, `materializeRun`, ensures, `addSystemInterest` (heals) | joins a job or creates one; re-lanes; fails a joiner fast; gives a place | yes | `.join` (registered in `joinsAfterFollow`), replayed by `replayJoin`: skipped when nobody wants it any more (`stillWants`), re-routed when a later apply moved its id (`barrierReroutesAJoinALaterApplyMoved`, mutant `noReroute`) |
| I15 | `EngineJobs.failFastJoiner` :210 (and the `readmitOpenedOriginGates` it calls) | answers or re-admits for a joiner | no | Only from `addInterest`'s own path, which runs only in a visit or a replay |
| I16 | `EngineJobs.relane` :249 | re-place, re-prioritise, a policy pause on a lowered lane, a user re-queue of a failed job | no | Only from a visit (`visit` → interests moved) or a replay (`addInterest`, `dropInterest`). A failed job whose verdict waits is left alone (`return`: the follow's own visit met a running attempt visit-first; mutant `relaneNoDefer`) |
| I17 | `EngineJobs.removeInterest` :323, `dropInterest` :336, `retire` :365 | removes an interest; retires a job; stops its transfer | yes (withdrawals, releases, claims' ends) | `.removal` → `replayRemoval`. The caller is answered at once (I30) |
| I18 | `EngineJobs.enqueue` :466 | a queue place | yes | `.enqueue(transfer, epoch:, front:)`, given by the drain only to the job that asked. Behind the barrier only I8's ENOENT re-queue reaches it outside a visit or a replay; a visit that re-lanes that job gives a place and the drain gives another, the later standing (**open, R-A**) |
| I19 | `EngineJobs.resolve` :535, `resolveAll` :609, `failFast` :649 | answers | yes (`resolveAll` from I6, I8, I13b) | A failure of a running or failed job waits (`defersFailure(.resolve)`); I6's success answers are at once (R-A); `failFast` is reached only from `park` (I1, replays), the offline and throttle replays, `answerThrottledUsersNow` (I21), `failFastJoiner` (I15) and `failed`'s offline exit when it is not deferred |
| I13b | `EngineFailures.integrityFailed` :482, `sparePresent` :527 | `failed(untilEntryChanges)`; the members the store holds answered; the final answer | yes | The final answer waits (`.resolve`). At once: the transition and the store-held members' answers (`answerPresentMembers`). **Open (R-A)** |
| I20 | `EngineJobs.sweepSpaceParked` :754, `reconsiderSpaceBlocked` :729, `judgeSpaceParked` :792, `requeueSwept` :858 | space re-admission and park | yes (free-space reads, reclaimed bytes, the store's settle) | Advances the follow one turn or the drain one batch (`advanceFollowForSpaceSweep`) and judges in a follow-up sweep once the barrier is down. Its inputs are R1; its decisions come after every event the drain applies, not at the sweep's own arrival place among them (**open, R-C**) |
| I21 | `EngineFailures.answerThrottledUsers` :424 → `answerThrottledUsersNow` :438 | fail-fast answers to throttle-parked users | yes (a throttle extension's scheduled turn) | `.throttleAnswers`, replayed at its arrival instant (`decisionNow`) on the followed state (cycle 11) |
| I22 | `EngineReadmission.readmit` :112, from `applyConditionsToJobs`, `unblockOrigin`, `readmissionFollowUp` :262 | re-queues lane-parked, edge-owed and origin-owed jobs by rank | yes | `.readmit(passes, conditions)` with the arrival's lane-wide conditions, replayed on the followed ranks (cycle 11) |
| I23 | `EngineReadmission.unblockOrigin` :197, from `endThrottle` (OriginGate :120), the breaker's end (Timers :141), `breakerChanged` / `probeEndedWithoutVerdict` (Failures :680, :670) | re-admits the origin's parked jobs, or the probe's one | yes | `.unblock(kind)`. The throttle's end and the cooldown's end are the clock's |
| I24 | `EngineReadmission.readmitForProbe` :302 | picks the probe's job by rank | no | From `unblockOrigin` (waits, I23), `readmitOpenedOriginGates` (from I15, and from `checkRunSettled`, which returns behind the barrier) and `ensureProbeCandidate` (I1) |
| I25 | `EngineConditions.apply` :80 → `applyConditionsToJobs` :119 → `pauseIfRefused` (Dispatch :630), the edge's owed set, `readmit` | policy pauses of running transfers; the edge's re-admissions; lane re-admission | yes | `.conditions(snapshot, edge:)`: the whole pass is replayed at its arrival place with the arrival's conditions, so a verdict that arrived before is given before, and the edge re-admits in its own rank order (cycle 11; the `.edge` events are gone). On arrival: the conditions, the edge's serial and the pending run's edge flag (world inputs), and I26 |
| I26 | `EngineRuns.reconsiderPendingRun` :956, `fulfilPendingRun` :983, `considerPendingRun`, `pendingRunDeadlineFired` (Timers :215); `startRun` from `performSync` (Runs :39), `runStart` (Lifecycle :333) and `migrateLoop` (Runs :1046) | starts a run, or a pending one | yes (a `sync()` call, launch, breaker outcomes, the cooldown's end, conditions, the debounce, a run's end) | A run's start takes no job decision (its manifest probe reservation, F-42, and the `breakerChanged` it may cause read the breaker only, and the re-admission that follows waits as `.unblock`, I23): its claims join through I2 and wait, and nothing it needs is dispatched before the pump. Through the breaker gate it waits for an owed pump (`dispatchOwed`, whose `pumpWaitsForFollow` term is `noDispatchOwedFlag`'s; R-E). The conditions and throttle gates read no state a visit changes |
| I27 | `EngineRuns.checkRunSettled` :571, `settleRun` :719, `finishRun` :787 | settles a run; answers its caller | `checkRunSettled`: no; `finishRun` and a purge's `settleRun(.cancelled)` (Commands :996): yes | `checkRunSettled` returns while `followBarrier` holds; the follow's last turn and the drain's last batch check it. A run whose steps end before it transfers (a failed fetch, a breaker's or a throttle's refusal) and a purge's cancellation answer the run's caller at once from the run's own outcome (no job's lane, rank, place or interest); the claims' removals wait (`.removal`, I17), and `finishRun`'s pending-run check and pump are I26 and I1 |
| I28 | `EngineRuns.runSteps` :125 | the run's manifest, space, plan and apply | yes | No job decision: a free-space read (R1, then I20), the store's view, the plan, `applyAndFollow` |
| I29 | `EngineTimers.fireDue` :104, `retryDue` :194, `heal` :431 | a backoff's re-queue; ends of a throttle, a cooldown, a debounce; the store's due work; heals | yes (the alarm) | `.retry` → `.retryDue` → `retryDue` (cycle 11). The throttle and cooldown ends go through I23, a pump follow-up (refused) and I26; the store's work is followed by I20; a heal joins through I14 |
| I30 | `EngineCommands.withdraw` :176, `withdrawEntry` :1515 | answers a cancelled caller; removes its interest; may stop the transfer | yes | The caller at once (R-SYN-4, R-SYN-10); `.removal` → `replayRemoval`, or `.release(token, entry: true)` (item 3; R-CAR-4 asserted after the drain) |
| I31 | `EngineCommands.joinGroup` :262, `joinMember` :321, `endClaims` :525 | members join; claims end | yes | Joins through I14; `.endClaim`, `.endClaims` |
| I32 | `EngineCommands.performReleaseGroup` :360, `releaseFollowUp` :452, `resumeReleases` :473, `releaseEntryGroup` :1537 | a group's release and its removals | yes | The caller is answered at once; `.release(token, entry:)`, `.continueReleases` |
| I33 | `EngineCommands.performPurge` :986, `withdrawPurged` :1021 | a purge's withdrawals | yes | The store's purge and the stamp at once (a request to the store, no job state); the withdrawals wait (`.purge`) |
| I34 | `EngineCommands.performAwaitAsset` :26, `ensureTask` :648 | answers from the store; joins; an ensure's report | yes | A present asset is answered from the store's binding at once (no job state); a join goes through I14; `ensureTask` reads free space (R1, then I20) and the store |
| I35 | `EngineManifest.answerUnknownWaiters` :330, `join` :421 | answers waiters for ids the copy lacked; joins | yes | The manifest outcome answers at once (not found, the fetch's failure, a throttle's refusal read at the answer): no job state. A join goes through I14 |
| I36 | `EnginePresence.answerPresent` :96, `answeredFromStore` :197, `answerPresentMembers` :338 | answers from the store | yes | The store's binding of each id (the apply's), at once; the lane read sets only the snapshot install's urgency |
| I37 | `EngineCatchUp.manifestCaughtUp` :242 | releases jobs held for a manifest | yes | Keeps them held while a follow is owed; the follow's last turn releases them |
| I38 | `EngineShutdown.drainEverything` :50 | shutdown's answers | — | Shutdown answers every waiter `.shutDown` and drops the waiting events; no drain runs after it |

**Residuals (open, for the orchestrator; ruling requested on each).**

- **R-A, the publication and commit paths (I5, I6, I8's `.superseded` and cancelled-ENOENT branches, I13b, I18).** The
  follow passes a job that is verifying or committing (amendment (e) carries it), so both orders meet these outcomes on
  a job whose ids the follow did not move. They differ when the attempt's bytes complete behind the barrier while the
  job, still downloading, is owed a visit: visit-first, the visit re-routed the moved ids during the download (their
  joins took the visit's places) and the commit bound the rest; behind the barrier the commit binds the ids the store
  still maps to this content and re-routes the others at the commit, as joins the drain replays after the follow's
  visits. The answers are the same; the re-routed joins' places can differ. I8's two at-once re-queues and I13b's
  store-held answers are the same kind. Not probed. Options: run the job's visit before its publication's outcome
  (`followedForVerdict`, as the failure verdicts do), or rule the publication outcomes outside the class.
- **R-B, the breaker's and the metrics' bookkeeping on arrival (I10, I11, I23's callers).** `recordBreaker` and the
  failure counters record each transfer outcome when it arrives; the decisions that follow from the breaker's state
  (re-admissions, the pending run) wait (I23, I26). A transfer outcome is the origin's answer, the same in both orders.
  Proposed: outside the class as a world input, like the throttle signal.
- **R-C, the space sweep's place among the drained events (I20).** A sweep owed behind the barrier judges after the
  drain's last event. A visit-first engine judged at the sweep's arrival, so a space re-queue may take its place after
  an event that arrived later. Its inputs are R1. Not probed. Options: a `.spaceSweep` event in the drain, or rule the
  sweep's places R1.
- **R-D, a visit reads inputs that arrived after it was owed.** A visit behind the barrier runs on the state the
  arrivals left: the conditions (`pauseIfRefused` in a visit's re-lane), the throttle and the breaker, which apply on
  arrival. A visit-first engine visited before those arrivals. The deferred passes then replay with the arrival's
  conditions (I25), so the end state converges in the scenarios tested; no probe shows a lasting difference.
- **R-E, `noDispatchOwedFlag` and a stall.** Below.

### The fixes (`6cc4d92`) — **Fixed**

At `2280fda`'s tests on cycle 10's sources (plus the test seams), the 9 class tests failed in the sweep-first order
only: `✘ Test run with 9 tests in 1 suite failed after 5.225 seconds with 13 issues.` (`.build-s3f/logs/c11-failing-at-5203ccb.log`;
the lines in the table above). At `3dcf543`, amendment (e)'s test failed sweep-first in both runs at
`EngineFollowBarrierApplyTests.swift:125` (`.build-s3f/headcheck/run-1.log`, `-2.log`). After `6cc4d92` all pass.

- *Every request waits whole.* `addInterest` defers the whole join (`.join`, registered in `joinsAfterFollow`), not only
  its place; `removeInterest` defers `.removal`; a withdrawal answers its caller at once and defers the removal; a
  group's release and its follow-up turns, a purge's withdrawals and a claim's end are events. Because every request's
  place now comes from a replay, the cycle-10 `.spaceJoin` and `.reinstate` events are gone (`reinstate` is called
  from `addInterest`, which runs in a replay or a visit only).
- *Every engine-side pass waits whole.* A conditions element (`.conditions`, its lane-wide snapshot kept for the
  replay), a re-admission (`.readmit`), an origin's unblock (`.unblock`), a due retry (`.retryDue`) and a throttle's
  answer turn (`.throttleAnswers`). The network edge's owed set is part of the conditions pass, so the `.edge` event
  is gone.
- *Verdicts on the followed lane.* `AttemptVerdict.pause(policy:blocks:)` and `.requeue` join the deferred exits;
  `replayThrottle` reads the job's lane after the visits.
- *Replay instant.* The drain sets `replayInstant` to each event's arrival (`eventsArrivedAt`); `decisionNow()` reads it.
- *Amendment (e).* `followApplied` puts the jobs that are unfollowed but not owed by the new pass in `followCarried`;
  the new `FollowScan` takes them (`carried`) and appends them when it starts, after the older scans.
- *Why `.relane` is removed (item 4).* Behind the barrier a re-lane comes only from a visit or a replay: every request
  that re-lanes a job (a join, a withdrawal) is now an event of its own, applied in the drain after the verdict it
  followed. The only re-lane that can meet a failed job whose verdict waits is therefore the follow's own visit (or an
  event the drain applies before that verdict), which met a running attempt visit-first, where a re-lane only
  re-prioritised it. So `relane`'s failed branch returns for such a job; a deferred `.relane` had nothing left to wait
  for. The branch that replaced the event is pinned by the mutant `relaneNoDefer` (the `return` dropped), killed by 5
  tests (below).

### Unreached branches and survivors (items 4 and 5)

The mutants run on the committed tree at `32c7ffe` (`.build-s3f/mut/mutants.py`: each edit applied in place with a
count check, `swift build --build-tests --scratch-path .build-s3f`, the filter run twice, then reverted, and `git diff
--stat Sources/` printed empty after each; logs `.build-s3f/mut/<name>-run<n>.log`):

| Mutant | Edit | Filter | Runs |
|---|---|---|---|
| `noCarry` | `followApplied`: `followOrder = Array(owed) + others` instead of carrying `others` | `barrierCarriesUnfollowedJobsBehindAnOwedPass` | `✘ … 1 test … with 1 issue` ×2, `.sweepFollowsFirst`, `EngineFollowBarrierApplyTests.swift:125` |
| `noReroute` | `replayJoin`: `if false, join.listed, …` | `barrierReroutesAJoinALaterApplyMoved` | ×2, `.sweepFollowsFirst`, `:186` (`!held`: U still waits on the old content) |
| `noFlagPump` | `continueFollow`: both `if moved \|\| self.state.pumpWaitsForFollow` → `if moved` | `barrierFillsAFreedSlotInTheFollowsLastTurn` | ×2, `.sweepFollowsFirst`, `EngineFollowBarrierSurvivorTests.swift:56` (B still queued with the slot free) |
| `relaneNoDefer` | `relane`: the `return` after "(S3-R14 item 4)." dropped | `EngineFollowBarrier` (45 tests) | `✘ Test run with 45 tests in 1 suite failed … with 7 issues.` ×2: ClassTests `:135`, VerdictTests `:67`, `:170`, `:172`, `:306`, `:308`, `:365`, all `.sweepFollowsFirst` |
| `throttleAtNow` | `replayThrottle`: `answeredAt: nil, answerEnd: nil` | `EngineFollowBarrier` (45 tests) | `… with 1 issue.` ×2, `.sweepFollowsFirst`, ClassTests `:213` (`abs(retryAfter - 60) < 0.5`) |
| `noDispatchOwedFlag` | `dispatchOwed` without `\|\| self.state.pumpWaitsForFollow` | the probe (R-E) | the probe's `start?.waiting == 0` fails ×2 (`waiting` 1); see R-E |

`throttleAtNow` with `answeredAt: nil` alone (keeping `answerEnd`) is not a distinct mutant: the replay instant is the
429's arrival, so the park's own answer time equals `facts.at`; the end is what the assertion reads.

**R-E: `noDispatchOwedFlag` — not equivalent, no committed test (ruling requested).** The probe (kept, not committed:
`.build-s3f/probe/EngineFollowBarrierSurvivorTests+pendingRunProbe.swift`, an extension of the barrier suite): two
slots, a breaker that one 403 opens; H holds a prefetch download; X's 403 opens the breaker; a forced sync is refused
(a pending run on the breaker gate); M, a prefetch member, parks behind the breaker. v3 (applied through the engine's
`applyAndFollow`) drops zz-h and changes 2,100 fillers, so the follow owes H's visit. The cooldown ends while it is
owed: the re-admission waits (`.unblock`) and the alarm's pump follow-up is refused (`pumpWaitsForFollow`). The
follow then visits H and abandons its download, and `recordBreaker`'s reconsideration of the pending run reads the
breaker's gate: with the flag in `dispatchOwed` the run waits for that pump, M probes first and the run starts after
(F-41). A `RunStartWatch` records how many watched jobs still wait when the run starts:
`DBGW sightings=[(4, 0)]` (`.build-s3f/probe-ndof-clean.log`); under the mutant `DBGW sightings=[(4, 1)]` in both runs
(`.build-s3f/mut/noDispatchOwedFlag-run1.log`, `-run2.log`), and the probe's `start?.waiting == 0` expectation fails. So the mutant is observable. In both, the sweep-first case then stalls until its time limit: the run
(`run-4`, manifest read, no apply report) and the alarm's store work never end. The store reports `units=1`,
`commitsInFlight=true`, the engine `storeWorkRuns=1`; the process is idle (`sample`: the main run loop and one idle
worker); `swift-inspect dump-concurrency` lists no task suspended in the store or in `fireDue`. The same test against
`2280fda`'s sources (before this cycle's fix) stalls the same way (`.build-s3f/headcheck/run3.log`), and with the run's
manifest fetch failing (no store apply) it still stalls (`.build-s3f/dbg-run4.log`), so the stall is the store's
due-work commit after the follow's release, not the run, and not this cycle's change. Not diagnosed further. A test
that cannot end is not committed (G4 forbids an assertion-free substitute, and leaking the engine to skip its shutdown
would hide the stall). Requested: a ruling on committing the probe once the stall is diagnosed (its owner may be the
store or the test support), or on accepting the probe's output as item 5's evidence.

### PROBE-C9-THROTTLE's R2 attribution — **recorded; ruling requested**

The cycle-10 correctness probe, re-run here on `32c7ffe` (copied into the barrier suite as a scratch file, then deleted;
`.build-s3f/probe-c9-throttle-1.log`, `-2.log`), 2/2 identical. C (1 MB, zz-a and zz-b, one user waiter each) gets a 429
with `Retry-After` 60 s while the follow owes its visit; v3 moved zz-a to N (16 bytes). Visit-first: the visit created N
before the 429 and N started, so A is served from N (`byteSize: 16`) and B gets the throttle's answer. Sweep-first:
`afterFailure: (owed: true, c: (failed(nextRun), 2))`; the visit creates N after the 429, N's admission waits for the
barrier's end (R2's admission wait), by then the 429's throttle (applied on arrival, a world input) holds the origin
for 60 s, above the 2 s interactive wait, so N parks and A is answered `serverUnavailable(retryAfter: 60.0)`; B gets the
same answer in both orders. The difference comes from R2 (no admission behind the barrier) meeting a world input that
arrived during that wait; replaying N's admission at the visit's instant would mean admitting under a throttle the
engine has already applied. Proposed: R2's accepted admission wait. Ruling requested.

### Test changes (G3 one-to-one, S3-R11 R3)

In `6cc4d92`, each assertion kept and only what the wait reads changed:

- `barrierAdmitsNothingBetweenDrainTurns` (`EngineFollowBarrierTests.swift`): its two waits and its setup check count
  the requests' waiting joins (`joinsAfterFollow`) instead of their waiting places (`placesAfterFollow`): behind the
  barrier a request's whole join waits now. Same counts (513).
- `barrierQueuesARequestAfterTheJobTheOwedVisitCreates`, `barrierKeepsAPausedTransfersFrontPlace` (same file) and
  `barrierPlacesAJoinOfAWaitingRetryAtItsArrival` (`EngineFollowBarrierVerdictTests.swift:107`, R's wait): a wait for the
  request's job now also ends when its join waits (`FollowBarrier.joinWaits`), since behind the barrier no job exists
  until the drain.
- `barrierReinstatesAReleasedMemberWantedAgain`: the setup reads the member's waiting join (`joinWaits`) instead of a
  `.reinstate` event (gone); its doc comment says so. Its assertions are unchanged.
- `stalePlace(_:withK:)` (`barrierGivesNoPlaceOfARemovedJobToItsSuccessor` and its control): X′ and Z′ are scripted
  `[.hold, .stage]`, both are awaited `downloading`, and the order read is the engine's `active.startSequence` (X before
  Z) instead of the source's `starts`: two attempts started in one pump reach the source in the order their drivers'
  store reads end, which is not the engine's decision; with the cycle-11 drain both starts fall in one pump, and the
  source's order then varied between runs. The expectation (X first) is unchanged.

### TSan run-1 time-outs (cycle-10 verifier) — **recorded, no change**

The cycle-10 requirements lens paired its TSan run with the correctness lens's: S3-R12 rule-1 mean 421.31, 74
time-outs and 23 other issues, all in timed-out cases, 0 ThreadSanitizer reports; its run 2 (mean 392.95) passed and
run 3 alone (mean 5.98) passed with no test over half its guard. Under S3-R12 (2) a time-out is blocking only at a mean
of 50 or less, so run 1 is recorded, not acted on. This cycle's TSan run is under "Gate evidence (cycle 11)".

### Hang guards (S3-R12) — **unchanged**

No guard was raised or cut. The 12 new tests (9 + 2 + 1; Sync goes from 448 to 460) take `.minutes(3)` like the suite's others; their TSan figures are under "Gate evidence (cycle 11)".

## Cycle 12: ruling S3-R15 (one view of the world per decision instant)

Cycle 12 applies **S3-R15** (recorded above as an "Orchestrator ruling (close-out)") and the cycle-11 verifiers'
findings. The work went in this order:

1. The R-E test, committed on its own (`39d4376`).
2. The failing tests of the class members, both orders, committed on their own (`fc13762`, 8 tests). With one test
   changed (`barrierThrottlesForTheFollowedLane`, below), 9 tests fail sweep-first 2/2 on `39d4376`'s sources
   (`.build-s3f/c12/failing/run-{1,2}.log`: `✘ Test run with 9 tests in 1 suite failed … with 11 issues.`, at
   WorldTests `:56`, `:59`, `:128`, `:195`, `:257`, `:326`, `:382`, `:386`, `:464`, `:523` and ClassTests `:290`). The
   visit-first argument passes in both runs.
3. One fix (`2e22cf6`).
4. The tests for the replay branches that S3-R15 item 6 found unreached: `40d9711`, `30c2a39`, `f391316`, `3bd9766` and
   `dcee1cd`.

Every new test is in the serialized `EngineFollowBarrierTests` suite. They are extensions in
`EngineFollowBarrierWorldTests.swift`, `EngineFollowBarrierReplayTests.swift` and
`EngineFollowBarrierSurvivorTests.swift`. Each runs through `LaneDropVisit.allCases` and expects the visit-first
outcome.

**Not closed this cycle (blocking under S3-R15):**

- R-C (item 3).
- Nine replay branches and three world-view mechanisms that no test reaches with a killing assertion (item 6).

Both are under "Open after cycle 12" below, with their analysis. Neither is reported as Fixed.

| S3-R15 item / finding | Disposition |
|---|---|
| 1. One view of the world per decision instant | **Fixed** in `2e22cf6`: the mechanism under "The world history" below; invariant checked by `followBarrierViolations` |
| 2. A 429 throttles on arrival, on the followed lane | **Fixed** in `2e22cf6`: `throttled` sets the origin's throttle on arrival for the backoff of `followedLane(job)`; `replayThrottle` only re-parks and answers. `barrierThrottlesTheOriginWhenA429Arrives` (PROBE-C11-MANIFEST-THROTTLE). `barrierThrottlesForTheFollowedLane` now reads the throttle right after the 429 (THROTTLE-LANE at arrival) |
| 3. R-A (COMMIT-PLACE, COMMIT-REROUTE) | **Fixed** in `2e22cf6`: a publication by a job that holds a moved id is marked (`publishedOwingVisit`), and its commit waits as `.committed(CommitAfterFollow)` until the follow's visit of it. `.superseded` and the cancelled-attempt ENOENT exit wait as every exit does (`AttemptVerdict.supersede`, `.requeue`). Tests: `barrierPlacesACommitsMovedIDAtTheFollowsPlace`, `barrierGivesACommitsSlotToTheFollowsReroute` |
| 3. R-C, the sweep's place among drained events | **Open** (below): not implemented, no test |
| 3. R-D, visits reading post-arrival inputs | **Fixed** in `2e22cf6` (item 1: a visit reads the apply's view). Test: `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` |
| 3. PROBE-C9-THROTTLE | **Fixed** in `2e22cf6`: a visit's new content is admitted on the apply's view. Test: `barrierAdmitsTheFollowsNewContentAsAtTheApply` (A served from N, 16 bytes) |
| 3. JOIN-THROTTLE-END, JOIN-THROTTLE-EXT | **Fixed** in `2e22cf6`: a replayed join reads the throttle of its arrival. Tests: `barrierAnswersAJoinOnTheThrottleAtItsRequest`, `barrierAnswersAJoinWithTheExtensionAfterIt` |
| 3. MANIFEST-THROTTLE, THROTTLE-LANE | **Fixed** (item 2 above) |
| 4. R-B: breaker decisions in the class; metric counters outside | **Fixed** in `2e22cf6`: details below. Test: `barrierAdmitsARequestOnTheBreakerAtItsArrival`; the counters are listed below with their reason |
| 5. R-E: reproduce, date, commit the killing test | **Done**: "R-E" below. Test: `barrierHoldsAPendingRunBehindTheOwedPump` (`39d4376`); `noDispatchOwedFlag` killed 2/2 |
| 6. Every replay branch reached | **Partly; blocking items open**: 10 of the 19 branch mutants killed 2/2 (6 by this cycle's replay tests; `noDispatchOwedFlag` and `unblockNow` by the survivor tests, the R-E test among them; `committedNow` and `noPublishedVisit` by the class tests); 9 survive. Of the 10 world-view mutants, 6 are killed, 3 survive and `alarmAtPark` is equivalent (table below) |
| 7. Inventory corrections (I12, I14, I26, I35, R-A rows) | **Done**: "The inventory, corrected" below. Every row cites its test or probe; I36 (non-blocking) included |
| Non-blocking: `alarmAtPark` | **Equivalent** (below) |
| Non-blocking: I36 omits `EnginePresence.swift:285`'s retire | **Fixed** (corrected I36 below) |
| Non-blocking: §7.10 "every exit while the barrier holds" | **Fixed** ("Proposed document changes", cycle 12) |
| Non-blocking: rows for the cycle-10 JOIN-RETIRE, THROTTLE-EXTENDED, PAUSE-LANE, THROTTLE-LANE | **Added** (table below) |
| Non-blocking: R-B, R-C, R-D in the class; metric counters outside | **Applied** (items 3 and 4 above) |
| Non-blocking: P-13 | **other-wp:b** (WP-B's benchmark; not touched) |
| Non-blocking: the `.removal` system-interest suspicion | **Analysed, not probed**: R-G below |
| Non-blocking: replays read the drain's conditions | **Fixed by item 1**: `withReading` swaps in the arrival's conditions; mutant `readingConditionsLive` still survives (below) |
| Cycle 11's disposition row "2. A visit re-lane of a job whose place waits" (the verifier's `:1514`; it named the ENOENT re-queue as R-A and left it waiting as `.enqueue`) | **Corrected**: that row now points here. The ENOENT exit waits as `.requeue` like every exit, and the `.enqueue` event is removed ("The world history" below) |

**Superseded in cycle 13 (S3-R16 item 3):** the rows for item 3's R-A, PROBE-C9-THROTTLE and item 4's R-B describe
machinery that cycle 13 removed: the commit deferral (`publishedOwingVisit`, `.committed`), `.supersede`, the
ENOENT deferral, and the place stamp's admission. "Cycle 13", removals 1, 2, 3 and 10, and the conflict put back to the
orchestrator there, replace them.

R-B detail (`2e22cf6`):

- `recordBreaker` records each outcome in the live breaker. Under a reading it also records it in the reading's view
  (`changeReadingView`).
- Replays read `breakerRecorded()`.
- The gate of a place given during a replay reads the stamp's view (`placeStamps`).

The cycle-10 findings that cycle 11 fixed (`6cc4d92`):

| Cycle-10 finding | Disposition |
|---|---|
| PROBE-C10-JOIN-RETIRE | **Fixed** in `6cc4d92` (removals wait, `.removal`). Test: `barrierAppliesAWithdrawalAfterTheVerdictItFollowed` |
| PROBE-C10-THROTTLE-EXTENDED | **Fixed** in `6cc4d92` (the park answers at the 429's instant). Test: `barrierAnswersAThrottleParkWithItsOwnWait`; mutant `throttleAtNow` killed (cycle 11) |
| PROBE-C10-PAUSE-LANE | **Fixed** in `6cc4d92` (`AttemptVerdict.pause`). Tests: `barrierPausesOnTheFollowedLane`, `barrierDecidesAPauseOnTheFollowedLane`, and from this cycle `barrierParksAPolicyPauseWithItsPlace` (the park branch) |
| PROBE-C10-THROTTLE-LANE | **Fixed** in `6cc4d92`. Since cycle 12 the lane is decided at arrival (`followedLane`). Test: `barrierThrottlesForTheFollowedLane` (reads the throttle at arrival) |

### The world history (S3-R15 item 1)

Mechanism, in `EngineState` and `EngineFollow`:

- **Views.** `WorldView` holds the origin's throttle, its breaker, the conditions and `pausedForThermal`, and the
  network edge serial.
- **Recording.** `worldStamp()` appends a view when the live one differs from the last view, and returns
  `WorldStamp(at:, view:)`.
- **Per-event stamps.** Every deferred event gets the stamp of its arrival (`eventStamps`, kept in step with
  `eventsAfterFollow`).
- **Follow stamps.** An apply stamps the follow it owes (`followStamps`, for the scans it carries too).
- **Replays and visits.** The drain replays each event inside `withReading(stamp)`, and `continueFollow` visits inside
  `withReading` of the apply's stamp. `withReading` sets `state.reading` and swaps the conditions and
  `pausedForThermal` for the view's.
- **Who reads the view:**
  - `decisionNow()`: the reading's instant.
  - `throttleRecorded()` / `breakerRecorded()`: the view's throttle and breaker.
  - `originGate`, `throttleEnd(after:)`, `answerThrottledUsersNow`, `breakerAdmitsOnlyProbe` and `endThrottle`.
- **Changes during a reading.** A decision's own change to the throttle or the breaker (a visit's abandon, a throttle
  it finds ended) is written to a new view (`changeReadingView`), so later events that share the old view keep it.
- **Place stamps.** A place given under a reading records the stamp (`placeStamps`). The barrier-end pump's gate reads
  the throttle and breaker from that view. A `.probe` admission falls through to the live breaker (residual below).
- **Invariant**, checked by `followBarrierViolations`: every event has a stamp whose view exists. When the barrier is
  down, `worldHistory`, `followStamps`, `placeStamps` and `publishedOwingVisit` are empty (`endWorldHistory()`, after
  the drain's last batch and the barrier-end pump).

R1's ledger inputs are unchanged.

Removed:

- `throttlesReplayed`.
- `eventsArrivedAt` and `replayInstant`, replaced by the stamps.
- The per-event snapshots of `.conditions` and `.readmit` (their `withConditions` is folded into the views).
- The `.enqueue` event and `placesAfterFollow`. Their one producer was I8's cancelled-attempt ENOENT re-queue, which
  now waits as `.requeue` like every other exit, and a place given in a replay carries the replay's stamp. With no place
  waiting behind the barrier, cycle 11's case "a visit re-lane of a job whose place waits" cannot arise.

### A 429 on arrival (S3-R15 item 2)

`throttled`, behind the barrier, uses `followedLane(job)`: the lane of the interests whose ids the engine's copy still
maps to this transfer. That is the lane the owed visits leave, found by the visit's own rule without performing it.

- **With a lane:** the backoff (and a Retry-After within the caps) sets `throttles[origin] = max(current, until)` at
  once, counts the retry and calls `throttleExtended`. The decision `.until(until)` is recorded. When the backoff
  gives up, the decision is `.exhausted`.
- **Without a lane** (no interest keeps an id there): only a Retry-After within the caps throttles at once, and the
  decision is `.undecided`. `replayThrottle` decides it on the lane the visits leave, from the 429's instant.

`replayThrottle` then only parks the job and answers at the 429's instant.

The lane cannot always be derived: `followedLane` does not count an interest that another owed visit moves onto this
content. That is residual R-H below; not probed.

### R-E (S3-R15 item 5)

**Reproduction and dating.** The cycle-11 probe (`PROBE-C11R-RE-PENDING-RUN`, unchanged scenario) times out 2/2 at
`5203ccb` and 2/2 at `40ecd95`: `Time limit was exceeded: 60.000 seconds`, `DBGW sightings=[(4, 0)]`
(`.build-s3f/c12/re-date.out`, `re-5203ccb-run{1,2}.log`, `re-40ecd95-run{1,2}.log`). At `s3-base` the scenario cannot
be built: the base has no bounded follow, no `holdFollowFollowUps` seam and no barrier (and `.unblock` does not exist
at `5203ccb` either), so there is nothing to date there.

**Diagnosis: the stall is the probe's own wait, not a liveness defect.** Sweep-first, the cooldown's end defers its
re-admission (`.unblock(.circuitOpen)`), and the alarm's pump follow-up runs and is refused (`pumpWaitsForFollow`). The
breaker stays `.open` until a probe is admitted, and the pump that would admit one waits for the follow. The probe
waited for a state the barrier holds back by design, so its wait never ended. The store's `units=1`,
`commitsInFlight=true` was the run's own apply waiting behind the same follow; it was not a stall.

**The committed test.** `barrierHoldsAPendingRunBehindTheOwedPump` waits instead for the deferred
`.unblock(.circuitOpen)` with no pump follow-up scheduled and `pumpWaitsForFollow` set. The scenario is not shortened or
weakened: same tuning, same entries, same expectations. It passes on HEAD in both orders, and `noDispatchOwedFlag` fails
it 2/2 at `EngineFollowBarrierSurvivorTests.swift:150` (`start != nil && start?.waiting == 0`) in the suite run in the
table below; the probe copy fails the same assertion 2/2 at `VerifyREProbe.swift:114` (`.build-s3f/c12/mut-ndof.log`).
The root was the probe's wait, in WP-F's test, so nothing is owed to another work package.

### Replay branches and mutants (S3-R15 item 6)

Setup:

- `.build-s3f/c12/mut.py` copies `Sources/` and `Tests/` into `.build-s3f/mutsrc` and applies each edit with a count
  check.
- It builds in `.build-s3f/mutbuild`, runs the filter twice and reverts.
- After each mutant it prints "Sources differ from the worktree: none". The worktree is never edited.

Runs:

- The suite run (`.build-s3f/c12/mut-all.log`) is at `2e22cf6`, with filter
  `EngineFollowBarrierTests|probeSupersededFreesSlot` (55 tests); its line numbers are as at that commit. Every barrier-suite failure it shows is in the
  sweep-first argument (`LaneDropVisit.sweepFollowsFirst`); the visit-first argument passes under every mutant
  (`grep` of `.build-s3f/c12/mut/*-run*.log`). The one other failure is `probeSupersededFreesSlot`, which has no argument.
- The targeted runs (`MUT_SUFFIX=2`, `.build-s3f/c12/mut2/`) are on the commits that add each test.

| Mutant | Branch dropped | Suite (×2) | Killing test (×2) |
|---|---|---|---|
| `readmitNow` | `readmit`'s `.readmit` deferral | passed | `barrierReadmitsBehindTheOwedVisitsPlaces`, ReplayTests `:92` |
| `unblockNow` | `unblockOrigin`'s `.unblock` | **killed**: SurvivorTests `:140`, `:150` (and `:76` time limit) | — |
| `retryDueNow` | `fireDue`'s `.retryDue` | passed | `barrierRetriesBehindTheOwedVisitsPlaces`, ReplayTests `:169`, `:170` |
| `requeueReplayDropped` | the drain's `.requeue` case | passed | `barrierRequeuesACancelledAttemptBehindTheOwedVisitsPlaces`, ReplayTests `:227`, `:233` (and `:189` time limit) |
| `pauseParkDropped` | `.pause`'s policy park | passed | `barrierParksAPolicyPauseWithItsPlace`, ReplayTests `:307`, `:308` |
| `stillWantsAlways` | `replayJoin`'s `stillWants` return | passed | `barrierDropsTheJoinOfAnEndedRun`, ReplayTests `:362` |
| `committedNow` | `deferCommit` | **killed**: WorldTests `:464`, `:523` | — |
| `noPublishedVisit` | `follow`'s `publishedOwingVisit` visit | **killed**: WorldTests `:464`, `:523` | — |
| `noDispatchOwedFlag` | `dispatchOwed`'s `pumpWaitsForFollow` | **killed**: SurvivorTests `:150` | — |
| `timerUnblockDropped` | `fireDue`'s `.throttle` re-admission when no live throttle is left | passed | `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` (extended, below), WorldTests `:335` (and `:274` time limit) |
| `placeStampsIgnored` | the gate's stamp view | **killed**: WorldTests `:257`, `:326`, `:382`, `:386` | — |
| `noArrivalThrottle` | the 429's throttle on arrival | **killed**: ClassTests `:208`, `:285`, `:290` (and `:306` time limit) | — |
| `arrivalJobLane` | `followedLane` → the job's own lane | **killed**: ClassTests `:283`, `:288` | — |
| `throttleReadLive` | `throttleRecorded`'s view | **killed**: ClassTests `:213`, WorldTests `:195` | — |
| `visitsLive` | the visit's `withReading` | **killed**: WorldTests `:257`, `:326` | — |
| `viewBreakerOutcomeDropped` | `recordBreaker`'s view update | **killed**: `EngineRegressionRound2Tests.swift:387` | — |
| `removeInterestNow` | `removeInterest`'s `.removal` | passed | **none** (open) |
| `endClaimNow` | `joinMember`'s `.endClaim` | passed | **none** (open) |
| `endClaimsNow` | `endClaims`'s `.endClaims` | passed | **none** (open) |
| `releaseNow` | `performReleaseGroup`'s `.release(entry: false)` | passed | **none** (open) |
| `releaseEntryNow` | `releaseEntryGroup`'s `.release(entry: true)` | passed | **none** (open) |
| `continueReleasesNow` | `releaseFollowUp`'s `.continueReleases` | passed | **none** (open) |
| `purgeNow` | `performPurge`'s `.purge` | passed | **none** (open) |
| `supersedeNow` | `.superseded`'s `defersFailure(.supersede)` | passed | **none** (open) |
| `enoentNow` | the cancelled-attempt ENOENT `defersFailure(.requeue)` | passed | **none** (open; the `.requeue` replay it shares is killed above) |
| `breakerReadLive` | `breakerRecorded`'s view | passed | **none** (open) |
| `endThrottleLiveGuardDropped` | `endThrottle`'s live-end guard under a reading | passed | **none** (open) |
| `readingConditionsLive` | `withReading`'s conditions swap | passed | **none** (open) |
| `alarmAtPark` | `park`'s alarm at `max(live end, until)` → `until` | passed | **equivalent** (below) |

What the new tests show:

- The four enqueue-type replays (readmit, retryDue, requeue, pause park) all put the event's jobs behind the places
  the visits give, or keep the park's ticket. Each test reads which job a freed slot goes to, or which starts first.
- The stillWants test reads that no job is left for a run that a purge ended while its join waited.

**`alarmAtPark` is equivalent.** Under the mutant the park schedules `.throttle(origin)` at `until`, which may be
earlier than the live origin's end. When that alarm fires with a live throttle still running, `fireDue`'s `.throttle`
case re-schedules it at the live end (`guard until <= now else { schedule(.throttle(origin), at: until) }`, F-35). The
re-admission therefore happens at the same instant; the mutant only adds one alarm turn. With no live throttle, both
schedule at `until`.

### Open after cycle 12 (blocking under S3-R15; analysis, no fix)

**R-C, the sweep's place among drained events (item 3).** Not implemented. Behind the barrier, `sweepSpaceParked`
runs one follow (or drain) turn and owes itself to a follow-up sweep that judges after the drain. The design fix is
to queue a `.spaceSweep(sweep)` event at the sweep's arrival and judge it in the drain under its stamp. But the sweep's
own follow-up turns are what move a follow whose follow-ups are held. About thirty pre-existing sweep and barrier tests
(cycles 4–8, `LaneDropVisit.sweepFollowsFirst`: "the sweep runs the owed follow itself") depend on that. So the event
has to coexist with the advancing turns, and a second judgement by the follow-up sweep after the barrier must not
change a verdict. Not done at the end of this cycle rather than rushed. The failing test to write first: one slot; a
free-space read's sweep re-queues S while the follow is owed; then a request J arrives. Visit-first, S is queued
before J and takes the slot; today, J's join (drain) is queued before S's re-queue (the follow-up sweep).

**Nine replay branches with no killing test (item 6):**

- **`endClaimNow`, `endClaimsNow`, `releaseNow`, `releaseEntryNow`, `continueReleasesNow`, `purgeNow`.** These
  withdrawals change an outcome only against a deferred event of the same job. A claim's end applied before a waiting
  join can retire a job that only the claim kept, which visit-first the join would have kept. The test needs the
  group's join (an owned task after a store read) to run after the apply, and no seam holds it. Writing it showed a
  separate question: R-F below.
- **`removeInterestNow`.** `removeInterest`'s own deferral is reached only from a run's end behind the barrier
  (`finishRun` after a purge's cancel) and from `releaseSystemReattachments` at a run's plan. Waiter withdrawals defer
  in `withdraw`, which is not mutated. Analysis: R-G below.
- **`supersedeNow`, `enoentNow`.** The `.superseded` publication outcome (the store applied a newer manifest than the
  engine's copy) and the ENOENT exit of a cancelled attempt are reached by no barrier test. Both need a store-side race
  during an owed follow. The `.requeue` replay that `enoentNow`'s path feeds is killed above.

**Three world-view reads with no killing test (item 6):**

- **`breakerReadLive`.** The stamped gate reads the view directly, so `breakerRecorded` matters only in a replayed
  `originGate` or `breakerAdmitsOnlyProbe`. No scenario built.
- **`endThrottleLiveGuardDropped`.** Needs an `.unblock(.throttled)` replay that finds the throttle ended at its instant
  while a later 429 extended the live one.
- **`readingConditionsLive`.** Needs a replayed decision that reads the conditions before a later `.conditions` event
  in the same drain, for example a readmission turn under unrestricted conditions followed by an offline element.
  Visit-first, the turn re-queues; read live, it does not, and the tickets then differ.

**Residuals found this cycle (not probed):**

- **R-F, a group's claims at its registration.** `recordGroup` records the registration's claims at arrival, on the
  live job table. Behind the barrier, an earlier waiter withdrawal is still waiting (`.removal`). Visit-first, that
  withdrawal had retired the job before the registration, and no claim was taken on it. Here, the claim keeps the job
  through the drain. The difference is a transfer kept instead of cancelled and restarted.
- **R-G, a run's removals after a re-route.** `finishRun` behind the barrier defers `.removal(run.token, transfer)` for
  the transfers it knows at its end. A visit that re-routes the run's interest meanwhile, possible only with a
  catch-up apply during the run, would leave the interest on the new job. Visit-first, `run.held` named that job.
- **R-H, `followedLane`'s lane.** It omits interests that another owed visit moves onto this content (item 2's "if the
  lane cannot be derived").
- **R-I, place stamps and slots.** A place stamp assumes a slot was free at the stamp's instant. A `.probe` admission
  reads the live breaker. The breaker records each attempt outcome on arrival (R-B's world input).

### The inventory, corrected (S3-R15 item 7)

These rows replace cycle 11's I5, I6, I8, I12, I13b, I14, I18, I26, I35 and I36.

**I5 `EngineDispatch.publish`.** At once for a job that holds no moved id. A job that holds one is marked
`publishedOwingVisit`. The follow visits it while it is verifying or committing (`follow(_:publishing:)`), and its
commit waits (I6).

- Test: `barrierPlacesACommitsMovedIDAtTheFollowsPlace`.
- Mutant: `noPublishedVisit` killed.

**I6 `EngineDispatch.committed`.** A commit of a marked job waits as `.committed(CommitAfterFollow)` and is replayed by
`replayCommit` after the job's visit. Its re-routes take the follow's places, and its success answers come at the
replay.

- Tests: `barrierGivesACommitsSlotToTheFollowsReroute` (COMMIT-REROUTE), `barrierPlacesACommitsMovedIDAtTheFollowsPlace`
  (COMMIT-PLACE).
- Mutant: `committedNow` killed.

**I8 `EngineDispatch.publicationFailed`.**

- `.superseded` waits as `.supersede`.
- The cancelled-attempt ENOENT waits as `.requeue`.
- The rest are as in cycle 11 (`.retry`, `.resolve`, ENOSPC via I13).
- Tests: `barrierRequeuesACancelledAttemptBehindTheOwedVisitsPlaces` covers the shared `.requeue` replay.
  `supersedeNow` and `enoentNow` survive (open).

**I12 `EngineFailures.throttled`.** On arrival (world input, S3-R15 item 2):

- The origin is throttled with or without a Retry-After, for the backoff of `followedLane(job)`
  (`ThrottleDecision.until`, or `.exhausted`).
- With no followed lane, only a Retry-After within the caps throttles, and the decision is `.undecided`.

The park and its fail-fast answers wait (`.throttle(ThrottleFacts)`). `replayThrottle` re-parks and answers at the
429's instant.

- Tests: `barrierThrottlesTheOriginWhenA429Arrives` (MANIFEST-THROTTLE), `barrierThrottlesForTheFollowedLane` (lane at
  arrival), `barrierAnswersAThrottleParkWithItsOwnWait`.
- Mutants: `noArrivalThrottle`, `arrivalJobLane`, `throttleAtNow` killed.
- Residual: R-H.

**I13b `EngineFailures.integrityFailed`, `sparePresent`.** Unchanged from cycle 11. The final answer waits (`.resolve`);
the transition and the store-held members' answers are at once. **Open**: the part of R-A that `2e22cf6` did not
cover, since a publication's integrity failure is not deferred as a publication outcome. Not probed.

**I14 `EngineJobs.addInterest`.** As cycle 11 (`.join`, `replayJoin`, `stillWants`, re-route). In addition:

- The replayed join reads its arrival's view (throttle, breaker, conditions; `withReading`).
- The place it gives carries the stamp (`placeStamps`), which the barrier-end gate reads.
- Tests: `barrierAnswersAJoinOnTheThrottleAtItsRequest` (JOIN-THROTTLE-END), `barrierAnswersAJoinWithTheExtensionAfterIt`
  (JOIN-THROTTLE-EXT), `barrierAdmitsARequestOnTheBreakerAtItsArrival` (R-B), `barrierDropsTheJoinOfAnEndedRun`
  (`stillWants`), `barrierReroutesAJoinALaterApplyMoved`.
- Mutants: `placeStampsIgnored`, `stillWantsAlways` killed.
- Residual: R-F (claims at registration).

**I18 `EngineJobs.enqueue`.** No deferral: the `.enqueue` event is removed. Under a reading, the place records the
stamp. Every enqueue behind the barrier happens inside a visit or a replay. Tests: the enqueue-type replay tests above.

**I26 runs.** A run's start is not deferred. It reads the origin's breaker and throttle live, and since cycle 12 a 429
behind the barrier is in the throttle at once, so the start's manifest probe sees it. A pending run reconsidered from
`recordBreaker` waits for the pump owed behind the barrier (`dispatchOwed` includes `pumpWaitsForFollow`).

- Test: `barrierHoldsAPendingRunBehindTheOwedPump` (R-E).
- Mutants: `noDispatchOwedFlag`, `unblockNow` killed.

**I35 `EngineManifest.answerUnknownWaiters`, `join`.** The manifest outcome answers at once. Its throttle refusal reads
the live throttle, which since cycle 12 includes a 429 that arrived behind the barrier. A join goes through I14.

- Test: `barrierThrottlesTheOriginWhenA429Arrives` (PROBE-C11-MANIFEST-THROTTLE).
- Mutant: `noArrivalThrottle` killed.

**I36 `EnginePresence`.** As cycle 11. In addition, `answeredFromStore` retires a job left without interests at once
(`EnginePresence.swift:285`; the attempt never asked for bytes), outside the drain: it acts on the store's binding, the
apply's. Not probed.

**Metric counters outside the class (S3-R15 item 4).** No decision reads these:

- `metrics.failures`, `metrics.retries`, `metrics.resolveJoins`.
- `jobsCreated`.
- The failure log lines (`record`).

Breaker decisions are in the class (R-B in the table above).

### Test changes (G3 one-to-one, S3-R2)

- **`barrierThrottlesForTheFollowedLane`** (ClassTests). It now also reads the origin's throttle right after the 429,
  before the follow's release, and expects it to equal the background backoff (THROTTLE-LANE at arrival). Its other
  assertions are unchanged.
- **`barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply`** (WorldTests, this cycle's own test).
  - zz-u is also a member of the group.
  - The test now expects N to start for that member once the apply's throttle ended, so it reaches `fireDue`'s
    `.throttle` re-admission with no live throttle.
  - The original assertions are unchanged.
- **`barrierPlacesACommitsMovedIDAtTheFollowsPlace`, `barrierGivesACommitsSlotToTheFollowsReroute`** (`fc13762`). Their
  waits accept a job that is neither downloading nor verifying, because the commit now waits for the visit. The
  assertions are unchanged (S3-R2: probes adapted in waits only).
- **`BenchSync.swift`.** `placesWaiting` became `barrierLeftovers` (`joinsAfterFollow.count + worldHistory.count`),
  because `placesAfterFollow` is gone. Its budget assertion is unchanged.

No pre-existing CDN test is changed.

### Hang guards (S3-R12, S3-R4)

The new tests use `.minutes(3)`, like the suite's. Their TSan durations are under "Gate evidence (cycle 12)". No new
`await` is in an actor (`git diff 3a86b92..HEAD -- Sources | grep '^+.*REENTRANCY'` is empty), so no REENTRANCY row is
proposed.

## Cycle 13: ruling S3-R16 (the bar is observable correctness)

Cycle 13 applies **S3-R16** (recorded above as an "Orchestrator ruling (close-out)") to the cycle-12 verifiers' 19
findings (`.build-orchestrator/s3f-c12-issues.json`). The work went in this order:

1. `0962130`: the setup race of the hanging test (findings 1 and 13). Waits and script only.
2. `dd13e69`: the failing tests for R-I and PROBE-C12-UNDECIDED-LANE, in both orders, committed on their own. On
   `0962130`'s sources they fail sweep-first 2/2 (`.build-s3f/c13/failing-{1,2}.log`: `✘ Test run with 3 tests in 1
   suite failed … with 5 issues.`, at LiveGateTests `:64`, `:70`, `:123`, `:127` and `:130`). The visit-first
   argument passes.
3. `affe65e`: the fix. Admission reads the live gates, a 429 always throttles on arrival, and the item-3 removals
   below, with the item-4 test changes.
4. `8f459c3`: tests for the replay branches and world-view reads that stay (item 1(e)).
5. `15d15a5` and `dc5e3c3`: the "probe first" items of item 5, committed as tests. These are R-A's integrity
   remainder and R-F. Both give the same answers in both orders.
6. `f7c729a`: two doc comments that still described the place stamp as an admission view.
7. `d5985f8`, then `3e3ef0d`: R-C. Its probe shows a different answer, so under item 1(a) it is blocking. The failing
   test came first: sweep-first 2/2 at `d5985f8` (`.build-s3f/c13/rc-failing-{1,2}.log`: `✘ Test run with 1 test in
   1 suite failed … with 2 issues.`, at SweepTests `:73` and `:76`). The fix followed.
8. `128fda9`: removal 11, `replayThrottle`'s copies of its reading's instant and end. `throttleAtNow`, the mutant
   that drops them, survived (below).

Every new test is in the serialized `EngineFollowBarrierTests` suite. The tests are extensions in
`EngineFollowBarrierLiveGateTests.swift`, `EngineFollowBarrierReachTests.swift` and
`EngineFollowBarrierSweepTests.swift`. Each runs through `LaneDropVisit.allCases` with `.timeLimit(.minutes(3))`.

**Put back to the orchestrator: a conflict inside S3-R16 (not counted as Fixed).** Two committed tests assert, in the
sweep-first order, an answer that only an admission on a past view can give:

- PROBE-C9-THROTTLE: `barrierAdmitsTheFollowsNewContentAsAtTheApply`.
- R-B: `barrierAdmitsARequestOnTheBreakerAtItsArrival`.

In each, the visit-first answer is a success that comes from a request sent *before* a 429 or a 403 arrived. Behind
the barrier, the visit or the join that creates that request runs *after* the 429 or 403, so sending it would be a
request to an origin whose throttle or breaker is live. Item 1(b) forbids that request, and item 3 names this
admission (R-I) as the machinery to remove. Item 4, though, says answer assertions are never changed, and item 1(a)
makes a different answer blocking. In these two scenarios both cannot hold.

I followed items 1(b) and 3, and changed the two sweep-first answer assertions to the live gate's answer (records under
"Test changes" below). The orchestrator is asked to confirm this. The alternative is to name a mechanism that gives the
visit-first answer without the request: for example, not failing the moved id's user fast while the throttle or breaker
holds, which would make the answer a later success. That would contradict the interactive fail-fast of ARCHITECTURE
§7.6.

A third case of the same kind is suspected and not probed:

- A user request whose join waits while the network is offline.
- Visit-first, the request starts at once (offline admits the user lane), fails offline, and its caller is answered
  `.offline`.
- Behind the barrier, the join replays under its arrival's (offline) view, but the request is sent at the barrier-end
  pump. If the network has returned by then, a real request succeeds and the caller is served.

The difference comes from when the request is sent, against a network that is an on-arrival input (R1): the same shape
as the two cases above. It is not probed because the fake source's scripted outcome does not depend on the
conditions, so a probe needs a source double that fails while the conditions are offline.

| S3-R16 item / finding | Disposition |
|---|---|
| 1(a) Same answers | **Held except as put back above.** The new tests assert the visit-first answer in both orders. R-C's different answer is **Fixed** in `3e3ef0d` |
| 1(b) R-SYN-5 | **Fixed** in `affe65e`. Admission reads the live gates (R-I), and a 429 throttles on arrival, never `.undecided`. Tests: `barrierAdmitsAVisitsPlaceOnTheLiveThrottle`, `barrierThrottlesOnArrivalWhenTheVisitsMoveEveryID`, `barrierFailsA429BeyondTheCapsAsOnArrival` |
| 1(b) R-SYN-11 and space safety | **Held.** Finding 16's path is removed (removal 1 below), so a verifying or committing job keeps its ledger bytes until its outcome. R-C's room is judged at the sweep's place (`3e3ef0d`) |
| 1(c) Liveness | **Fixed**: the hang (findings 1 and 13) in `0962130`. No test hangs in the runs under "Gate evidence (cycle 13)" |
| 1(d) Flakiness | Runs under "Gate evidence (cycle 13)", including the 30-run loop of the formerly hanging test |
| 1(e) G4 for code that stays | **Done**: ten deferral branches (removals 1–7), `.undecided`, `endThrottle`'s guard, the stamp's admission and `replayThrottle`'s copied instant and end are removed (below). Every deferral, replay branch and world-view read that stays has a mutant killed 2/2 (table below; `joinNow`'s two runs are batch I's), except `alarmAtPark`, equivalent as in cycle 12. `breakerReadLive` is killed by a time limit only. **Corrected in cycle 14:** two branches had no killing test: the stamp's breaker refusal (EngineDispatch `:533`, 0 hits) is removed (S3-R17 item 2), and `followedForVerdict`'s visit (EngineFollow `:562`, 0 hits) is tested (`barrierAnswersAPassedJobsFailureAfterItsVisit`, mutant `verdictVisitDropped`; "Cycle 14") |
| 1(f) Gates | "Gate evidence (cycle 13)" |
| 2 Residual risks | "Residual risks (S3-R16)" below |
| 3 Simplify | "Removals" below, eleven items, each with the branches and tests it affects |
| 4 Test changes | "Test changes" below: five records |
| Finding 1, 13 (reqs, correct): `barrierRetriesBehindTheOwedVisitsPlaces` hangs | **Fixed** in `0962130`. R's first attempt holds until the first conditions reading is in, then gets its 500. So a late reading is no longer an edge that re-queues R into the only slot (PROBE-C12-RETRY-SETUP-RACE). Assertions unchanged |
| Finding 2 (reqs): R-H, the 429's lane | **Non-blocking under S3-R16 item 5** (the backoff length). Residual RR-1. The throttle itself is now always set on arrival |
| Finding 3 (reqs), 15 (correct): R-C not implemented | **Probed, then Fixed.** The probe shows a different answer (U `insufficientSpace` against served), so it is blocking under 1(a). Test `barrierGivesTheRoomToTheSweepsJobBeforeALaterRequest` (`d5985f8`), fix `3e3ef0d` |
| Finding 4 (reqs), 14 (correct): survivors and 0-hit branches | **Removed** (removals 2–9) or **tested** (`8f459c3`, `d5985f8`). Mutant table below |
| Finding 5 (reqs), 15 (correct): R-A's integrity remainder | **Probed, same answers**: `barrierAnswersAnIntegrityFailureAfterTheVisit` (`15d15a5`), 2/2 in both orders. `integrityFailed`'s answers go through `resolveAll`, whose `.resolve` verdict waits for the job's visit (`defersFailure`). So a moved id's user is served its new content and the other user gets `integrityFailure`, as visit-first. The R-A row is corrected below |
| Finding 6 (reqs): inventory rows wrong or uncited | **Corrected**: "The inventory, corrected (cycle 13)" below. That covers the rows this cycle changes; I21, I22 and I25 and the preamble for the stamp mechanism; and the cycle-11 `readmit` row, which now cites `barrierReadmitsBehindTheOwedVisitsPlaces` with `readmitNow` killed at ReplayTests `:92` |
| Finding 7 (reqs): `alarmAtPark` equivalence by reasoning only | **Re-run, survives as before** (batch B, `✔ Test run with 66 tests in 2 suites passed` ×2); **no probe output exists.** The equivalence is argued from `fireDue`'s `.throttle` re-schedule (cycle 12, unchanged): the alarm it moves earlier re-schedules itself at the live end, so the re-admission instant is the same |
| Finding 8 (reqs), 17 (correct): R-F, R-G, R-I | R-F **probed, same answers and requests** (`dc5e3c3`). R-G **removed** with `removeInterest`'s deferral (removal 4). R-I **Fixed** (1(b)) |
| Finding 9 (reqs), 19 (correct): P-13 | **other-wp:b** (WP-B's benchmark; not touched) |
| Finding 10 (reqs): shared `.verify-logs` | For the orchestrator. This cycle's own logs are under `.build-s3f/c13/` |
| Finding 11 (correct): R-I, PROBE-C12-PLACE-SLOT | **Fixed** in `affe65e`. Test `barrierAdmitsAVisitsPlaceOnTheLiveThrottle` (`dd13e69`) |
| Finding 12 (correct): PROBE-C12-UNDECIDED-LANE | **Fixed** in `affe65e`. Test `barrierThrottlesOnArrivalWhenTheVisitsMoveEveryID` (`dd13e69`) |
| Finding 16 (correct): a visit removes a verifying or committing job | **Removed path** (removal 1). `follow` leaves verifying and committing jobs to their outcome again (`unfollowed`), as before cycle 12, so their staged bytes stay in the ledger |
| Finding 18 (correct): R-E is the probe's own wait | No change |

### What `affe65e` changes

- **Admission on the live gates (R-I; items 1(b) and 3).**
  - In `gate`, a place's stamp now only refuses: a throttle in force, or a breaker rejection, at the stamp's instant.
    `dispatch`'s stamped park answers at that instant.
  - Every start then passes the live throttle, breaker, slot and space checks.
  - `originGate` reads `throttleEnded` from the live throttle. So `endThrottle` clears only a throttle that the clock
    has ended, and its live-end guard is gone.
- **A 429 always throttles on arrival (UNDECIDED-LANE; item 1(b)).**
  - Behind the barrier, `throttled` takes the backoff of `followedLane(job) ?? job.lane`.
  - `Backoff.delay` returns nil only for a `Retry-After` above `maxRetryAfter`. That gives `.exhausted`: nothing is
    throttled, and the replay fails the job for the next run with `serverUnavailable(retryAfter:)`, as visit-first.
  - `ThrottleDecision.undecided` is removed.

### Removals (S3-R16 item 3)

| # | Removed | Why it only made order, place or timing equal | Closes | Tests affected |
|---|---|---|---|---|
| 1 | The commit deferral: `publishedOwingVisit`, `deferCommit`, `EventAfterFollow.committed`, `CommitAfterFollow`, `replayCommit`, and the `publishing:` visit of verifying and committing jobs | `committed` binds only the ids the store maps to this content. It re-routes the others through `reroute`, whose joins wait as `.join`. So a moved id's user gets its new content in both orders. The deferral changed only which re-routed join met the freed slot first | Finding 16. `committedNow` and `noPublishedVisit` (killed in cycle 12) are moot | COMMIT-PLACE and COMMIT-REROUTE (records below) |
| 2 | `.superseded`'s deferral (`AttemptVerdict.supersede`) | `supersede` re-routes every interest, and the joins wait | `supersedeNow`; the 0-hit `.supersede` replay | none |
| 3 | The cancelled-attempt ENOENT deferral (`defersFailure(.requeue)` in `publicationFailed`) | A place ahead of the visits' places, admitted on the live gates. The `.requeue` verdict replay stays for the other exits (`requeueReplayDropped` killed) | `enoentNow` | none |
| 4 | `removeInterest`'s `.removal` (a run's end, a system re-attachment) | See the note below | `removeInterestNow`; R-G | none |
| 5 | `joinMember`'s `.endClaim`, `endClaims(of:)`'s `.endClaims` | See the note below | `endClaimNow`, `endClaimsNow`; the 0-hit replays | none |
| 6 | `performReleaseGroup`'s `.release(entry: false)`, `withdrawEntry`'s and `releaseEntryGroup`'s `.release(entry: true)`, `releaseFollowUp`'s `.continueReleases` | See the note below | `releaseNow`, `releaseEntryNow`, `continueReleasesNow`; the 0-hit `.release(entry: true)` and `.continueReleases` | none |
| 7 | `performPurge`'s `.purge` (`withdrawPurged` at once) | See the note below | `purgeNow` | none |
| 8 | `ThrottleDecision.undecided` | It left the origin unthrottled after a 429 (item 1(b) names it) | finding 12; the 0-hit `.undecided` | `barrierThrottlesOnArrivalWhenTheVisitsMoveEveryID` (new) |
| 9 | `endThrottle`'s live-end guard | `originGate` now reads the throttle's end live, so the guard cannot fire | `endThrottleLiveGuardDropped` | none |
| 10 | The stamp's admission (the gate admitting on a past view) | R-I: it broke R-SYN-5 | finding 11 | PROBE-C9-THROTTLE and R-B (records below, put back above) |
| 11 | `replayThrottle`'s `answeredAt: facts.at, answerEnd: end` and `ThrottleFacts.at` (`128fda9`) | Copies of the values the replay's reading gives (below the mutant table) | `throttleAtNow`, which survived 2/2 | none |

Removals 4–7 carry no answer. The caller of a withdrawal, a release or a purge was answered at once before them too
(R-SYN-4, R-SYN-10). Their deferral only ordered the removal against a waiting join or verdict of the same job.

Applied at once, a job that only the removed interest kept is retired and its transfer stopped. A waiting join that
would have kept it creates it again in the drain, which costs a second request. R-CAR-4 holds: no transfer runs for
nobody. This is residual RR-5.

A waiter's withdrawal (`withdraw`'s `.removal`) keeps its deferral. Its mutant `withdrawRemovalNow` is in the table
below.

### Test changes (G3 one-to-one, S3-R16 item 4)

- **`barrierRetriesBehindTheOwedVisitsPlaces`** (ReplayTests, `0962130`).
  - The change: R's script gains a leading `.hold`. The test waits, driving the clock, for the first conditions reading
    and R downloading, then releases R into its 500.
  - The reason: finding 1 asks for exactly this setup change, and "do not weaken the test".
  - Every assertion is unchanged.
- **`barrierAdmitsTheFollowsNewContentAsAtTheApply`** (WorldTests, PROBE-C9-THROTTLE, cycle 12). Put back above.
  - Display name: "R-SYN-11: … admitted on the throttle in force at the apply (F-28)" became "R-SYN-5: the new content
    an owed follow's visit queues starts only under the live throttle, not the apply's (F-28)".
  - Old assertion, both orders: `(try? aResult.get())?.byteSize == 16`.
  - New assertions, visit-first: unchanged.
  - New assertions, sweep-first: `atEnd.throttled && !nStarted` once the barrier is down (no request for N while the
    throttle is live), and A answered `.serverUnavailable`.
  - The wait for the barrier's end no longer drives the clock, so the throttle is still live when the test reads it.
  - Reason: item 3 (R-I).
- **`barrierAdmitsARequestOnTheBreakerAtItsArrival`** (WorldTests, R-B, cycle 12). Put back above.
  - Display name: "… is admitted on the breaker as it stood at the request" became "… starts only while the live
    breaker admits it".
  - Old assertions, both orders: `uState == .downloading` and U served.
  - New assertions, visit-first: unchanged.
  - New assertions, sweep-first: `!uStarted && uState != .downloading`, and U answered `.authRejected`.
  - Reason: item 3 (R-I).
- **`barrierPlacesACommitsMovedIDAtTheFollowsPlace`** (WorldTests, COMMIT-PLACE).
  - Old assertion: `nIndex != nil && wIndex != nil && nIndex! < wIndex!`.
  - New assertion: `nIndex != nil && wIndex != nil` (both start).
  - Reason: removal 1. Only the order of N's and W's starts differs (RR-3).
  - Answers are unchanged.
- **`barrierGivesACommitsSlotToTheFollowsReroute`** (WorldTests, COMMIT-REROUTE).
  - Old assertion: `after.n == .downloading && after.r == .queued`.
  - New assertion: `(after.n == .downloading && after.r == .queued) || (after.r == .downloading && after.n == .queued)`.
  - Reason: removal 1. Which of N and R takes the slot is RR-3.
  - Answers are unchanged.

No test is deleted, and no scenario or operation is lost. No pre-existing CDN test is changed.

### The replay branches and world-view reads that stay (item 1(e))

Setup:

- `.build-s3f/c13/mut.py` (adapted from cycle 12's) copies `Sources/` and `Tests/` into `.build-s3f/mutsrc{,2,3,4}`.
- It applies each edit there with a count check and builds in `.build-s3f/mutbuild{,2,3,4}`.
- It runs the filter twice, reverts, and diffs the copy's `Sources/` against the worktree. The worktree is never
  edited. A diff it prints names only a later commit of the worktree (batches A to C ran on `affe65e`'s sources, and
  `3e3ef0d` and `128fda9` came after them); "none" where the sources were the same.
- Filter: `EngineFollowBarrierTests|probeSupersededFreesSlot` for batches A and B, `EngineFollowBarrier|probeSupersededFreesSlot`
  for the others.

| Batch (log) | Sources | Tests | Mutants |
|---|---|---|---|
| A (`mut-a.log`, `mut/`) | `affe65e` | `8f459c3`, 66 | `exhaustedArrival` … `visitsLive` (ten) |
| B (`mut-b.log`, `mut2/`) | `affe65e` | `8f459c3`, 66 | `readmitNow` … `noDispatchOwedFlag` (ten) |
| C (`mut-c.log`, `mut3/`) | `affe65e` | `dc5e3c3`, 68 | `resolveNow` … `joinNow` (six); stopped during `joinNow`'s second run, the rest moved to E to G |
| D (`mut-d.log`, `mut4/`) | `3e3ef0d` | 69 | `spaceSweepNow`, `spaceSweepReplayDropped` |
| E, F, G (`mut-{e,f,g}.log`) | `3e3ef0d` | 69 | `throttleAtNow`, `noFlagPump`; `relaneNoDefer`, `noReroute`; `noCarry` |
| H (`mut-h.log`, `mut2/`) | `3e3ef0d` | 69 | `stampParkLive` (new: `dispatch`'s stamped park) |
| I (`mut-i.log`, `mut/`) | `128fda9` | 2 | `joinNow` again, filter `barrierDropsTheJoinOfAnEndedRun\|barrierServesARequestMadeAfterAWaitingFinalFailure` |

`joinNow`'s first full run took 1,743.8 s (`✘ Test run with 68 tests in 2 suites failed after 1743.815 seconds with
38 issues.`): 17 tests fail, several at their time limit, and the suite is serialized. Its second full run was stopped,
and batch I ran the two tests of the first run that fail in about a second, twice.

Line numbers are those of the tests at each batch's commit. Every failure in a test that runs in both orders is in the
sweep-first argument. The visit-first argument passes under every mutant: the 70 run logs under
`.build-s3f/c13/mut*/` hold 0 `followVisitedFirst at` lines. Two failing tests have no argument:
`probeSupersededFreesSlot` (`viewBreakerOutcomeDropped`) and `barrierAdmitsNothingBetweenDrainTurns` (`joinNow`).
The table is from `python3 .build-s3f/c13/mut-table.py` (`.build-s3f/c13/mut-table.out`), which reads every issue of
the full run logs.

| Mutant | Code dropped | Runs | Killed by (test, lines; `(t)` = its time limit) |
|---|---|---|---|
| **Deferrals that stay** | | | |
| `readmitNow` | `readmit`'s `.readmit` | B, 2/2 | ReplayTests `barrierReadmitsBehindTheOwedVisitsPlaces` `:92` |
| `unblockNow` | `unblockOrigin`'s `.unblock` | B, 2/2 | SurvivorTests `barrierHoldsAPendingRunBehindTheOwedPump` `:140`, `:150`, `:76` (t) |
| `retryDueNow` | `fireDue`'s `.retryDue` | A, 2/2 | ReplayTests `barrierRetriesBehindTheOwedVisitsPlaces` `:177`, `:178` |
| `conditionsNow` | `EngineConditions.apply`'s `.conditions(edge:)` | C, 2/2 | ClassTests `barrierPausesOnTheFollowedLane` `:53`, `:64`; `barrierReadmitsAnEdgeInItsOwnOrder` `:625`, `:577` (t); VerdictTests `barrierRetriesAWaitingOfflineFailureOnAnEdgeItMet` `:374`, `:376` |
| `joinNow` | `addInterest`'s `.join` | C, 1 full run; I, 2/2 | I: ReplayTests `barrierDropsTheJoinOfAnEndedRun` `:361`; VerdictTests `barrierServesARequestMadeAfterAWaitingFinalFailure` `:68`, `:69`. C: 17 tests, among them those two, `barrierReroutesAJoinALaterApplyMoved`, `barrierServesAGroupRegisteredAfterAWithdrawal`, `barrierAnswersAJoinOnTheThrottleAtItsRequest` and `barrierPlacesACommitsMovedIDAtTheFollowsPlace` |
| `withdrawRemovalNow` | `withdraw`'s `.removal` | C, 2/2 | ClassTests `barrierAppliesAWithdrawalAfterTheVerdictItFollowed` `:430`, `:432`, `:433` |
| `throttleAnswersNow` | `answerThrottledUsers`'s `.throttleAnswers` | C, 2/2 | ClassTests `barrierAnswersAThrottleExtensionOnTheFollowedState` `:362`; WorldTests `barrierAnswersAJoinWithTheExtensionAfterIt` `:197`, `:205`, `:143` (t) |
| `spaceFailureNow` | the ENOSPC verdict's deferral | C, 2/2 | `barrierDecidesAnENOSPCOnTheFollowedState` (`EngineFollowBarrierTests.swift`) `:1118`, `:1065` (t) |
| `resolveNow` | `resolveAll`'s `.resolve` (`defersFailure`) | C, 2/2 | ReachTests `barrierAnswersAnIntegrityFailureAfterTheVisit` `:210`, `:179` (t); VerdictTests `barrierServesARequestMadeAfterAWaitingFinalFailure` `:66`, `:68`, `:22` (t) (`:69` run 1 only); the suite's `finish` invariant check `:118` |
| `relaneNoDefer` | `relane`'s return for a job whose verdict waits (S3-R14 item 4) | F, 2/2 | ClassTests `barrierDecidesAPauseOnTheFollowedLane` `:135`, `barrierAnswersAThrottleParkWithItsOwnWait` `:213`; VerdictTests `barrierServesARequestMadeAfterAWaitingFinalFailure` `:67`, `barrierKeepsAWaitingRetrysBackoffThroughTheVisit` `:170`, `:172`, `barrierAnswersAnOfflineExitOnTheFollowedState` `:306`, `:308`, `barrierRetriesAWaitingOfflineFailureOnAnEdgeItMet` `:365` |
| `spaceSweepNow` | `sweepSpaceParked`'s `.spaceSweep` | D, 2/2 | SweepTests `barrierGivesTheRoomToTheSweepsJobBeforeALaterRequest` `:73`, `:76` |
| **Replay branches** | | | |
| `requeueReplayDropped` | the drain's `.requeue` case | B, 2/2 | ReplayTests `barrierRequeuesACancelledAttemptBehindTheOwedVisitsPlaces` `:235`, `:241`, `:197` (t) |
| `pauseParkDropped` | `.pause`'s policy park | B, 2/2 | ReplayTests `barrierParksAPolicyPauseWithItsPlace` `:315`, `:316` |
| `stillWantsAlways` | `replayJoin`'s `stillWants` return | B, 2/2 | ReplayTests `barrierDropsTheJoinOfAnEndedRun` `:370` |
| `noReroute` | `replayJoin`'s re-route of an id a later apply moved | F, 2/2 | ApplyTests `barrierReroutesAJoinALaterApplyMoved` `:186` |
| `offlineRequeueDropped` | `.offline(requeue: true)`'s fresh attempt | A, 2/2 | ReachTests `barrierRetriesAnOfflineFailureAfterAnEdge` `:121`, `:123` |
| `exhaustedReplayDropped` | `replayThrottle`'s `.exhausted` case | A, 2/2 | ReachTests `barrierFailsA429BeyondTheCapsAsOnArrival` `:77`, `:82` |
| `spaceSweepReplayDropped` | the drain's `.spaceSweep` case | D, 2/2 | SweepTests `barrierGivesTheRoomToTheSweepsJobBeforeALaterRequest` `:73`, `:76` |
| `throttleAtNow` | `replayThrottle`'s `answeredAt:` and `answerEnd:` | E, **passed** 2/2 | None: removed in `128fda9` (below) |
| **Readings and views** | | | |
| `visitsLive` | the visit's `withReading` | A, 2/2 | WorldTests `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` `:339` |
| `readingConditionsLive` | `withReading`'s conditions swap | A, 2/2 | ReachTests `barrierPausesOnTheConditionsOfItsElement` `:161` |
| `throttleReadLive` | `throttleRecorded`'s view | B, 2/2 | ClassTests `barrierAnswersAThrottleParkWithItsOwnWait` `:213`; WorldTests `barrierAnswersAJoinWithTheExtensionAfterIt` `:195` |
| `breakerReadLive` | `breakerRecorded`'s view | A, 2/2 | ReachTests `barrierAnswersAJoinOnTheBreakerAtItsRequest` `:178` (t) only: its sweep-first case does not end under the mutant, and no assertion is reached |
| `viewBreakerOutcomeDropped` | `recordBreaker`'s view update | B, 2/2 | `EngineRegressionRound2Tests.probeSupersededFreesSlot` `:387` (no argument) |
| `placeStampsIgnored` | `gate`'s refusal on a place's stamp | A, 2/2 | WorldTests `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` `:339` |
| `stampParkLive` | `dispatch`'s park at the stamp's instant | H, 2/2 | WorldTests `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` `:339` |
| `timerUnblockDropped` | `fireDue`'s `.throttle` re-admission when no live throttle is left | B, 2/2 | WorldTests `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` `:347`, `:286` (t) |
| `alarmAtPark` | `park`'s alarm at `max(live end, until)` → `until` | B, **passed** 2/2 | None: equivalent, as in cycle 12 (finding 7's row) |
| **A 429 on arrival** | | | |
| `noArrivalThrottle` | the throttle set on arrival | A, 2/2 | 8 tests: ClassTests `:208`, `:285`, `:290`, `:366`, `:306` (t); LiveGateTests `:63`, `:64`, `:70`, `:123`, `:127`, `:130`; WorldTests `:56`, `:59`, `:197`, `:205`, `:259`, `:268`, `:143` (t) |
| `arrivalJobLane` | `followedLane` → the job's own lane | A, 2/2 | ClassTests `barrierThrottlesForTheFollowedLane` `:283`, `:288` |
| `exhaustedArrival` | `.exhausted` → `.until(now)` | A, 2/2 | ReachTests `barrierFailsA429BeyondTheCapsAsOnArrival` `:77`, `:82` |
| **The follow's pump and order** | | | |
| `noDispatchOwedFlag` | `dispatchOwed`'s `pumpWaitsForFollow` | B, 2/2 | SurvivorTests `barrierHoldsAPendingRunBehindTheOwedPump` `:150` |
| `noFlagPump` | the follow's last-turn pump when `pumpWaitsForFollow` | E, 2/2 | SurvivorTests `barrierFillsAFreedSlotInTheFollowsLastTurn` `:56` |
| `noCarry` | the carry of unfollowed jobs (`followCarried`) | G, 2/2 | ApplyTests `barrierCarriesUnfollowedJobsBehindAnOwedPass` `:125` |

**`throttleAtNow` survived, and its code is removed (`128fda9`, item 3).** The drain replays a 429's verdict under the
event's reading (`drainEventsAfterFollow`), whose stamp `deferToFollow` takes in the 429's own turn, after the throttle
is set. So `decisionNow()` is the 429's instant and `throttleEnd` reads that instant's view. The `answeredAt: facts.at`
and `answerEnd: end` that `replayThrottle` passed to `park` were copies of those values: `failFast` computes
`throttleEnd(after: end) = end` from the same view. With the injected clock the instants are equal. On a live clock the
stamp is read microseconds after `facts.at`, in the same turn. The cycle-12 inventory's "`throttleAtNow` killed" was
cycle 11's result, before cycle 12's readings. `128fda9` removes the two arguments and `ThrottleFacts.at`. The
`EngineFollowBarrier|Throttle|throttle` tests pass after it (`✔ Test run with 78 tests in 8 suites passed after 48.351
seconds.`). The same filter also matched one benchmark, which ran in a debug build beside the mutant builds and failed
its 10 ms budget; the benchmarks' own run is under "Gate evidence (cycle 13)". `dispatch`'s own park at the stamp's
instant stays: it runs under no reading, and `stampParkLive` is killed.

### Residual risks (S3-R16)

These are differences from visit-first only in order, place, timing or backoff length, recorded for Stage 5's
`docs/RESIDUAL-RISKS.md`. Item 1 holds in each.

- **RR-1. Which lane's backoff a 429 behind the barrier throttles for** (R-H, finding 2; PROBE-C12R-FOLLOWED-LANE).
  **Corrected in cycle 14:** "only the length differs" was wrong: the lane also chooses the `.exhausted` cap, an
  answer (PROBE-C13-EXHAUST-LANE). `followedLane` now counts the moved interests and the waiting joins and
  withdrawals ("Cycle 14"); what is left of RR-1 is stated there.
  - The mechanism:
    - `followedLane(job)` counts the job's own interests whose ids stay with it.
    - When none stays, it falls back to the job's lane.
    - It does not count interests that another owed visit moves onto this content.
  - The verifiers' figures: visit-first throttles for 0.209572016 s (interactive first backoff); behind the barrier for
    0.838288067 s (background backoff).
  - The origin is throttled on arrival in both cases (R-SYN-5). Only the length differs.
- **RR-2. A space sweep's second judgement after the barrier.**
  - A sweep that arrives behind the barrier is judged at its place in the drain (`3e3ef0d`).
  - Its own follow-up turn, which keeps the follow moving, judges the jobs still parked once the barrier is down.
  - A visit-first engine made no such judgement then. A parked job may therefore be re-admitted earlier than
    visit-first, if room arrived meanwhile.
  - Not probed.
- **RR-3. The places of a commit's re-routed joins** (COMMIT-PLACE, COMMIT-REROUTE; removal 1).
  - Behind the barrier, the commit re-routes at its arrival and the joins wait. Visit-first, the visit re-routed first.
  - Which of the re-routed job and a later request starts first, or takes a freed slot, differs. The answers are the
    same.
  - Figures: the cycle-12 failing runs on `39d4376`'s sources, WorldTests `:464` (W started before N) and `:523` (R
    took the slot).
- **RR-4. The places of `.superseded` and of a cancelled attempt's ENOENT re-queue** (removals 2 and 3).
  - Each takes its place at arrival, ahead of the places the owed visits give.
  - Not probed: the verifiers found no barrier test that reaches either path (0 hits, cycle 12).
- **RR-5. Withdrawals, releases, claims' ends and purges applied at arrival** (removals 4–7). **Corrected in cycle
  14:** a purge's withdrawals missed the joins still waiting for the follow, a different answer
  (PROBE-C13-PURGE-JOIN); a purge now withdraws them too ("Cycle 14").
  - Where a join waiting in the drain would have kept a job that the removal retires, the job is stopped and created
    again: one more request, the same answer.
  - Probe of the nearby case R-F (`dc5e3c3`): a group registered after a waiting withdrawal takes 2 requests in both
    orders. A waiter's own withdrawal still waits (`.removal`).
- **RR-6. A refused stamped place answers at its stamp's instant.**
  - A place refused on its stamp's view answers its users with the wait read at that instant (`dispatch`), against the
    end of that view's throttle.
  - A later 429's extension shows in the live gate's own refusals instead.
  - Only values inside `serverUnavailable(retryAfter:)` differ.
- **RR-7. The answer and admission cases put back above:** PROBE-C9-THROTTLE, R-B, and the suspected offline join.
  Confirmed by S3-R17 items 1 to 3 (cycle 14): the live gate's answer stands, recorded here with its probes.

### The inventory, corrected (cycle 13)

These rows replace I1's gate clause, and rows I5, I6, I8, I12, I13b, I14, I17, I18, I20, I21, I22, I25 and I30–I33,
as they stood after cycle 12.

**Preamble (replaces cycle 11's).** "Behind the barrier" keeps its meaning (`defersToFollow`). An event the drain
replays runs under its decision instant (`withReading(stamp)`, cycle 12):

- `decisionNow()` is the event's arrival.
- `throttleRecorded()` and `breakerRecorded()` read the origin's throttle and breaker of that instant's view.
- The lane-wide conditions are that view's.
- A queue place it gives records the stamp (`placeStamps`), which the barrier-end gate reads only to refuse.

`replayInstant` and the cycle-11 `.readmit(passes, conditions)` and `.conditions(snapshot, edge:)` payloads no longer
exist. Line numbers are at `128fda9` (in these files the same as at `3e3ef0d`), under `Sources/ZTronAssetSync/Engine/`.

- **I1, `EngineDispatch.gate` :503, `dispatch` :366.** **Corrected in cycle 14** ("Cycle 14", the inventory rows):
  the stamp's breaker is no longer read, and a place is stamped only where a slot was free for its lane.
  - A place a visit or a replay gave is refused on its stamp's throttle or breaker, and answered at the stamp's instant.
  - Every start reads the live throttle, breaker, slots and space.
  - Tests: `barrierAdmitsAVisitsPlaceOnTheLiveThrottle`, `barrierAdmitsTheFollowsNewContentAsAtTheApply`,
    `barrierAdmitsARequestOnTheBreakerAtItsArrival`.
  - Mutants: `placeStampsIgnored` (the refusal) and `stampParkLive` (the park at the stamp's instant) killed.
- **I5, `EngineDispatch.publish` :1018.**
  - At once: the attempt's own end.
  - Test: `barrierPlacesACommitsMovedIDAtTheFollowsPlace` (answers).
- **I6, `EngineDispatch.committed` :1086.**
  - At once, also behind the barrier. The bound ids are answered with success. The unbound ids are re-routed, and their
    joins wait (`.join`).
  - Tests: COMMIT-PLACE and COMMIT-REROUTE (answers, both start). Residual RR-3.
- **I8, `EngineDispatch.publicationFailed` :1177.**
  - `.superseded` supersedes at once. Its joins wait.
  - The cancelled-attempt ENOENT re-queues at once, and is admitted on the live gates.
  - `.integrity` goes to I13b. `.fileSystem` goes to `.retry`. The final failures go to `.resolve` (I19). ENOSPC goes
    to I13.
  - Residual RR-4.
- **I12, `EngineFailures.throttled` :349.** **Corrected in cycle 14:** `followedLane` is the lane a visit-first
  engine's job had ("Cycle 14", the inventory rows).
  - On arrival, the origin is throttled for the backoff of `followedLane(job) ?? job.lane`, or the decision is
    `.exhausted` (a `Retry-After` above `maxRetryAfter`, nothing throttled).
  - The park and its answers wait (`.throttle(ThrottleFacts)`).
  - `replayThrottle` parks and answers under its reading (the 429's instant and view), or fails the job for the next
    run (`.exhausted`).
  - Tests: `barrierThrottlesTheOriginWhenA429Arrives`, `barrierThrottlesForTheFollowedLane`,
    `barrierThrottlesOnArrivalWhenTheVisitsMoveEveryID`, `barrierFailsA429BeyondTheCapsAsOnArrival`,
    `barrierAnswersAThrottleParkWithItsOwnWait`.
  - Mutants: `noArrivalThrottle`, `arrivalJobLane`, `exhaustedArrival`, `exhaustedReplayDropped` and `throttleReadLive`
    killed. The cycle-12 row's "`throttleAtNow` killed" was cycle 11's result. The mutant survives since cycle 12's
    readings, and its code is removed (removal 11).
  - Residual RR-1.
- **I13b, `EngineFailures.integrityFailed` :496.**
  - The transition, and the answers of the members the store holds at their current content, happen at once. Those are
    ids the copy maps to this content, the same in both orders.
  - The final answer waits (`resolveAll`'s `.resolve`), so a moved id's user is served after the job's visit.
  - Test: `barrierAnswersAnIntegrityFailureAfterTheVisit` (the R-A remainder, same answers). Mutant: `resolveNow`.
- **I14, `EngineJobs.addInterest` :108.** As cycle 12 (`.join`, `replayJoin` under its arrival's view), except that
  the place stamp only refuses (I1).
  - Tests: `barrierAnswersAJoinOnTheThrottleAtItsRequest`, `barrierAnswersAJoinWithTheExtensionAfterIt`,
    `barrierAnswersAJoinOnTheBreakerAtItsRequest` (the join's breaker read), `barrierDropsTheJoinOfAnEndedRun`,
    `barrierReroutesAJoinALaterApplyMoved`, `barrierServesAGroupRegisteredAfterAWithdrawal` (R-F).
  - Mutants: `joinNow`, `stillWantsAlways`, `noReroute`, `breakerReadLive`.
- **I17, `EngineJobs.removeInterest` :323.** Drops at once (`dropInterest`). A waiter's withdrawal still waits in
  `withdraw` (I30). Residual RR-5.
- **I18, `EngineJobs.enqueue` :462.**
  - No deferral. A place a visit or a replay gives records its stamp.
  - The cancelled-attempt ENOENT re-queue (I8) is the one place given at once behind the barrier.
- **I20, `EngineJobs.sweepSpaceParked` :757, `judgeSpaceSweep` :771.**
  - Behind the barrier, a sweep that arrives waits as `.spaceSweep(sweep)`, judged by the drain at its place.
  - Its turn still runs one follow or drain turn, and owes a follow-up sweep that judges once the barrier is down.
  - Test: `barrierGivesTheRoomToTheSweepsJobBeforeALaterRequest` (R-C).
  - Mutants: `spaceSweepNow`, `spaceSweepReplayDropped`. Residual RR-2.
- **I21, `EngineFailures.answerThrottledUsers` :437.**
  - `.throttleAnswers`, replayed under its stamp: answers at its arrival instant, against that view's throttle.
  - Test: `barrierAnswersAThrottleExtensionOnTheFollowedState`. Mutant: `throttleAnswersNow`.
- **I22, `EngineReadmission.readmit` :112.**
  - `.readmit(Readmissions)`, replayed under its stamp: the arrival's conditions, on the followed ranks.
  - Tests: `barrierReadmitsBehindTheOwedVisitsPlaces`, `barrierPlacesAReadmissionAsTheFollowLeavesIt`.
  - Mutant: `readmitNow` killed at ReplayTests `:92`.
- **I25, `EngineConditions.apply` :80 → `applyConditionsToJobs` :122.**
  - `.conditions(edge:)`, replayed under its stamp: the element's own conditions, not the drain's.
  - The element itself, its edge serial and the pending run's reading apply on arrival.
  - Tests: `barrierPausesOnTheFollowedLane`, `barrierPausesOnTheConditionsOfItsElement`.
  - Mutants: `conditionsNow`, `readingConditionsLive`.
- **I30, `EngineCommands.withdraw` :176.**
  - The caller is answered at once. A waiter's removal waits (`.removal` → `replayRemoval`).
  - `withdrawEntry` :1485 releases at once.
  - Test: `barrierAppliesAWithdrawalAfterTheVerdictItFollowed`. Mutant: `withdrawRemovalNow`.
- **I31, `EngineCommands.joinMember` :323, `endClaims` :507.** Joins go through I14. Claims end at once (removal 5).
- **I32, `EngineCommands.performReleaseGroup` :358, `releaseFollowUp` :442, `releaseEntryGroup` :1498.** At once
  (removal 6). Residual RR-5.
- **I33, `EngineCommands.performPurge` :963, `withdrawPurged` :991.** At once (removal 7). **Corrected in cycle 14:**
  the purge also withdraws the joins of the interests it removes that wait for the follow (`withdrawPurgedJoins`).

The other rows stand as cycle 11 and cycle 12 left them. Rows that cite no test but are not wrong (finding 6's list:
I2–I4, I7, I9–I11, I13, I15, I19, I23, I24, I27–I29, I34, I37, I38) are non-blocking under item 5. They are left as
they are.

### Hang guards (S3-R12, S3-R4)

- The new tests use `.minutes(3)`, as the suite's do. Their durations are under "Gate evidence (cycle 13)".
- No `await` was added in an actor. `git diff 3f10eaa..HEAD -- Sources | grep '^+.*await '` is empty, so no REENTRANCY
  row is proposed.

## Cycle 14: the cycle-13 verifiers' findings, and S3-R17

Cycle 14 applies **S3-R17** (recorded above as an "Orchestrator ruling (close-out)") and S3-R16 to the cycle-13
verifiers' 13 findings. The work went in this order:

1. `85636a1`: the failing tests, committed on their own, in the new `EngineFollowBarrierAnswerTests.swift` (the
   serialized `EngineFollowBarrierTests` suite; both `LaneDropVisit` orders; `.timeLimit(.minutes(3))`). On cycle 13's
   sources (`128fda9`; `314eedb` changed only this draft) eight of the nine fail sweep-first, 2/2
   (`.build-s3f/c14/failing-run{1,2}.log`: `✘ Test run with 9 tests in 1 suite failed after 5.702 seconds with 14
   issues.` and `✘ Test run with 9 tests in 1 suite failed after 5.688 seconds with 14 issues.`), at AnswerTests `:143`
   (finding 1), `:208`, `:209`, `:218` (finding 7), `:279`, `:280` (finding 8), `:331`, `:334`, `:380`, `:383`,
   `:438`, `:439` (finding 9), `:533` and `:545` (two cases found this cycle, below); line numbers at `85636a1`. Every
   visit-first case passes. `barrierAnswersAPassedJobsFailureAfterItsVisit` passes in both orders: it is finding 2's
   test for `followedForVerdict`'s visit, not a failing test.
2. `ecf396a`: a purge withdraws the waiting joins of the interests it removes (finding 7).
3. `4b3dcee`: a place is stamped only where a slot was free for its lane (finding 8); applies are counted, so a
   publication the follow passed is answered as a visit-first engine answered it (found this cycle).
4. `159d672`: the stamp's breaker refusal is removed, and a new invariant names breaker parks that nothing re-admits
   (finding 1, and finding 2's line 533 with it).
5. `2926422`: `followedLane` is the lane a visit-first engine's job had (finding 9).
6. `a716fde`: the breaker test checks that the invariant check names the stranded state.
7. `b075089`: tests for the first mutant batch's survivors, and one more case found while writing them.
   `barrierAnswersAPassedJobsRetryAsVisitedFirst` fails sweep-first 2/2 on `a716fde`'s sources
   (`.build-s3f/c14/t10-failing-{1,2}.log`: `✘ Test run with 1 test in 1 suite failed after 192.002 seconds with 2
   issues.` and `… after 192.004 seconds with 2 issues.`): the time limit at `:686`, and B answered `.cancelled` at
   `:742` (line numbers at `b075089`). B rode C's retry instead of moving to N. The other tests of that commit pass on
   those sources; each kills a mutant that survived batch 1 (table below).
8. `d2fad39`: a passed publication's ids move when it fails, not when it is answered.
9. This draft.

**Found this cycle (blocking under S3-R16 1(a), each with its failing run above):**

- **PROBE-C14-PASSED-AFTER** (`barrierAnswersAPassedJobsLaterFailureAsVisitedFirst`). C (the content of zz-a and
  zz-b, a user waiter each) begins to publish after v3's apply, which moves zz-b to N; behind the barrier the follow
  passes C while it verifies, and C's bytes fail after the drain. Visited first, B was moved onto N at the apply,
  while C downloaded, and was served N. On cycle 13's sources B got C's `integrityFailure`.
- **PROBE-C14-PASSED-AT-APPLY** (`barrierAnswersAJobPublishingAtTheApplyAsVisitedFirst`). C already verifies at the
  apply, so a visit-first follow passed it too, and its failure answered B `integrityFailure`. Cycle 13's
  `followedForVerdict` visited C before the deferred verdict and served B N.
- **PROBE-C14-PASSED-RETRY** (`barrierAnswersAPassedJobsRetryAsVisitedFirst`). As PROBE-C14-PASSED-AFTER, with a
  first failure the interactive policy retries (EIO on the verification read). `4b3dcee` moved the ids only at a final
  answer, so B rode C's retry. The same test applies v4 during C's second publication, which began before v4's apply:
  both orders' follows pass C, and zz-c's user gets C's failure (the mark a first publication's pass left must not
  carry over, mutant `passedMarkKept`).

| Finding | Disposition |
|---|---|
| 1 (reqs, blocking): PROBE-C13R-STAMP-BREAKER | **Fixed** in `159d672`, the preferred fix: `gate` reads only the stamp's throttle; the breaker is a live origin gate (S3-R17 item 2). Test `barrierStartsAVisitsPlaceOnceTheBreakerCloses` (since `b075089` with three slots, so a slot is free at the apply and N's place is stamped, as in the probe). Mutant `stampBreakerBack` (cycle 13's refusal restored) killed 2/2. The user-lane answer the removal could change, R-B (`barrierAdmitsARequestOnTheBreakerAtItsArrival`), is unchanged: the live breaker refuses U. New invariant `unwakeableBreakerParks`: "nothing will re-admit the N jobs the breaker parked while it is closed", shown to fire on the stranded state in the same test (`a716fde`; mutant `breakerInvariantDropped` killed 2/2) |
| 2 (reqs, blocking, G4) | Line 533: **removed** with finding 1. `followedForVerdict`'s visit (EngineFollow `:568` at `d2fad39`): **tested** by `barrierAnswersAPassedJobsFailureAfterItsVisit`; `verdictVisitDropped` killed 2/2 in batch 2. It survived batch 1, while `resolveAll` also moved the ids; since `d2fad39` the drain's visit is the only mover behind the barrier. Writing this test found the three PROBE-C14-PASSED cases, **fixed** in `4b3dcee` and `d2fad39`. The 1(e) row is corrected under "Cycle 13"; the mutant table is below |
| 3, 10 (reqs, correct): the conflict inside S3-R16 | **Ruled** by S3-R17. The two one-to-one changes of sweep-first answer assertions recorded under "Cycle 13", "Test changes" (PROBE-C9-THROTTLE, R-B) are confirmed as authorised by S3-R17 item 3. No other answer assertion changed this cycle. RR-7 is in the §7.10 and `RESIDUAL-RISKS.md` proposals ("Proposed document changes", cycle 14) |
| 4 (reqs): TSan figures | **Recorded** under "Gate evidence (cycle 14)" |
| 5 (reqs): probe RR-2 and RR-4 | **Not done** (non-blocking; the blocking items and their mutants came first). RR-2 and RR-4 stay "Not probed" |
| 6, 12, 13 (other-wp): P-5 and P-13 (`BenchStorage.swift`), P-9 (`BenchKit.swift`) | **Routed**: P-5 and P-13 to WP-B, P-9 to WP-G. Not touched. This cycle's benchmark run is under "Gate evidence (cycle 14)" |
| 7 (correct, blocking): PROBE-C13-PURGE-JOIN | **Fixed** in `ecf396a`, the verifier's second option. `withdrawPurged` also withdraws the waiting joins of the non-user interests the purge removes (`withdrawPurgedJoins`): the registry entry goes, a group drops the member (`dropGroupMember`), a heal is forgotten, and the event stays in the queue marked `withdrawn`, so the drain's batches and its end are those of the events that arrived. Tests `barrierPurgeWithdrawsAWaitingGroupJoin` and, for the system case, `barrierPurgeForgetsAWaitingHeal` (`b075089`). RR-5 and I33 corrected |
| 8 (correct, blocking): PROBE-C13-STAMP-NO-SLOT | **Fixed** in `4b3dcee`. A decision instant records the slots a pump then had for each lane class (`WorldStamp.freeSlots`, `freeSlots()`), and `enqueue` stamps a place only where its lane had one. The verifier's "less the places stamped ahead of it" is not needed: a place refused on the throttle takes no slot, so a visit-first pump tried every place while a slot was free. Tests `barrierGatesAPlaceWithoutASlotOnTheLiveThrottle` and `barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle` (the lane's slot, mutant `slotLaneBlind`); `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` still kills `placeStampsIgnored` and `stampParkLive` |
| 9 (correct, blocking): PROBE-C13-EXHAUST-LANE | **Fixed** in `2926422`: `followedLane` gives the visit's full rule and the drain's (below). Tests `barrierDecidesA429OnTheLaneAMovedInterestGives`, `barrierDecidesA429OnTheLaneAWaitingJoinGives`, `barrierDecidesA429OnTheLaneAWaitingWithdrawalLeaves`. RR-1 corrected; its remainder is below |
| 11 (correct): nested drain re-entrancy | **Not done** (non-blocking). The suggested change makes `sweepSpaceParked` judge at once inside the drain. No barrier test reaches `checkRunSettled`'s `.read` sweep from a replay (it needs a run's claim parked for space and admitted while the drain replays), so the change would be a branch without a killing test (S3-R16 1(e)), and a guard on `drainEventsAfterFollow` would be unreachable once the sweep judges at once. Put to the orchestrator with the verifier's suggested fix |

### What cycle 14 changes

Line numbers at `d2fad39`, under `Sources/ZTronAssetSync/Engine/`.

- **A place's stamp** (`EngineDispatch.gate` :548, `EngineJobs.enqueue` :471, `EngineDispatch.freeSlots` :82;
  findings 1 and 8).
  - A place given behind the barrier is refused only by its stamp's throttle.
  - It is stamped only where a visit-first pump then had a slot for its lane: a user job's slot within the user cap,
    other work's within the non-user and pipeline caps.
  - A user job's preemption of lower-lane work is not counted; such a place is read live (S3-R17 item 2).
  - `freeSlots()` is one pass over the jobs in flight (`slotCounts`), so a stamp stays O(in flight) (C2).
- **A purge's waiting joins** (`EngineCommands.withdrawPurgedJoins` :1049; finding 7).
  - One pass over the waiting events, only while joins wait (C2).
  - A withdrawn join is not counted by `followBarrierViolations`; the purge test checks the invariants while it waits.
- **The lane a 429 is decided on** (`EngineFailures.followedLane` :666; finding 9). While the barrier holds, the
  highest lane of:
  - the job's own interests, less those a waiting withdrawal removes (`.removal`), and, when the job is owed a visit,
    less those none of whose ids the copy still maps to its content;
  - the interests other jobs hold in ids the copy now maps to this content, which their owed visits move onto it (a
    job verifying or committing is passed by its visit, so its interests stay);
  - the waiting joins that join it at the drain, re-routed as `replayJoin` re-routes them.

  The held lane (or bulk) when no interest is left but ids stay; `nil` when the visit supersedes the job. Only
  whether the lane is user-initiated chooses the policy, so both walks stop there. The walk over the jobs runs only
  while a follow is owed (one copy lookup per id), the walk over the events only while events wait (C2).
- **Passed publications** (`PassedPublication`, `Job.publishingSince`, `Job.passedPublishing`,
  `EngineState.appliesFollowed`; `EngineFollow.follow` :671–:691, `followedForVerdict` :563,
  `followPassedPublication` :579, `EngineDispatch.publicationFailed` :1206).
  - Each followed apply is counted, and a publication records the count when it begins (`publish`).
  - A follow's visit that passes a verifying or committing job with moved ids marks it: `publishedAfterApply` when
    its publication began after that visit's apply (a visit-first engine visited it at the apply, while it downloaded,
    and moved those ids), else `publishingAtApply` (a visit-first engine passed it too). A mark once
    `publishedAfterApply` stays so through a later apply's pass, and a real move clears it.
  - Behind the barrier, the drain's visit before a deferred verdict moves the ids unless the job is
    `publishingAtApply` (`followedForVerdict`).
  - Outside it, a failed publication of a `publishedAfterApply` job moves them before its exit meets them, whatever
    the exit: an answer, a retry and its cap, a space verdict (`followPassedPublication`, which may move a job still
    verifying or committing, because its publication has ended: `follow(_:publicationEnded:)`).
- **Invariant `unwakeableBreakerParks`** (`EngineCommands` :2072): jobs parked `circuitOpen` behind a closed breaker
  with no breaker deadline, no owed re-queue (`originOwed`) and no waiting `.unblock(.circuitOpen)`.

No new `await` in an actor this cycle, so no new `// REENTRANCY:` comment and no ledger row. 0 unsafe escapes.

### Test changes

No pre-existing test changed, and no answer assertion changed. Two of this cycle's own tests changed before any
verification, in `b075089`:

- `barrierStartsAVisitsPlaceOnceTheBreakerCloses`: three slots instead of two. With two, every slot was busy at the
  apply, and since `4b3dcee` N's place is no longer stamped, so the test no longer reached the stamp's breaker
  refusal (`stampBreakerBack` survived batch 1).
- `barrierPurgeWithdrawsAWaitingGroupJoin`: one more assertion, the invariants while the withdrawn join waits
  (`withdrawnJoinRegistered` survived batch 1).

### The branches this cycle adds (item 1(e))

Setup, as cycle 13's: `.build-s3f/c14/mut.py` and `mutB.py` copy `Sources/` and `Tests/` into
`.build-s3f/mutsrc{,2,3,4}`, apply each edit there with a count check, build in `.build-s3f/mutbuild{,2,3,4}`, run
the filter `EngineFollowBarrier|probeSupersededFreesSlot` twice, revert, and diff the copy's `Sources/` against the
worktree (every revert printed "none"). The worktree is never edited. Definitions: `.build-s3f/c14/mutants-1.json`
and `mutants-2.json`.

| Batch (logs) | Sources and tests | Tests in the filter |
|---|---|---|
| 1 (`mut-{a,b,c,d}.log`, `mut{,2,3,4}/`) | `a716fde` | 78 |
| 2 (`mutB-{a,b,c,d}.log`, `mutB{,2,3,4}/`) | sources `d2fad39`, tests `b075089` | 81 |

Every failure is in the sweep-first argument except where "both" is written. Lines are AnswerTests' (the new
`EngineFollowBarrierAnswerTests.swift`) at each batch's commit; (t) is a time limit.

| Mutant | Branch | Batch, result | Killed by |
|---|---|---|---|
| **The stamp (findings 1, 8)** | | | |
| `stampBreakerBack` | cycle 13's breaker refusal restored in `gate` | 1 **passed** 2/2; 2, 2/2 | `barrierStartsAVisitsPlaceOnceTheBreakerCloses` `:154`, `:155` (N parked; the invariant names it). Batch 1 ran the two-slot version (Test changes) |
| `breakerInvariantDropped` | `unwakeableBreakerParks` returns nil | 1, 2/2 | the same test `:132`, both orders |
| `slotIgnored` | `enqueue` stamps without the slot check | 1, 2/2 | `barrierGatesAPlaceWithoutASlotOnTheLiveThrottle` `:289`, `:290` |
| `slotLaneBlind` | `FreeSlots.admit` reads the non-user slot for every lane | 1 **passed** 2/2; 2, 2/2 | `barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle` `:400` |
| `placeStampsIgnored` | `gate`'s refusal on the stamp's throttle | 1, 2/2 | WorldTests `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` `:339` |
| `stampParkLive` | `dispatch`'s park at the stamp's instant | 1, 2/2 | the same WorldTests line |
| **The purge (finding 7)** | | | |
| `purgeJoinsKept` | `withdrawPurged` without `withdrawPurgedJoins` | 1, 2/2 | `barrierPurgeWithdrawsAWaitingGroupJoin` `:218`, `:219`, `:228` |
| `purgeJoinMemberKept` | the join's `dropGroupMember` | 1, 2/2 | the same test `:218` |
| `purgeJoinHealKept` | the join's heal kept | 1 **passed** 2/2; 2, 2/2 | `barrierPurgeForgetsAWaitingHeal` `:276`, `:284` |
| `withdrawnJoinRegistered` | `followBarrierViolations` counts a withdrawn join | 1 **passed** 2/2; 2, 2/2 | `barrierPurgeWithdrawsAWaitingGroupJoin` `:212` (the invariants while the join waits) |
| **The 429's lane (finding 9)** | | | |
| `otherJobsWalkDropped` | `followedLane`'s walk over other jobs | 1, 2/2 | `barrierDecidesA429OnTheLaneAMovedInterestGives` `:341`, `:344` |
| `joinsWalkDropped` | `followedLane`'s walk over the waiting joins | 1, 2/2 | `barrierDecidesA429OnTheLaneAWaitingJoinGives` `:390`, `:393` |
| `withdrawalsIgnored` | `followedLane` without the waiting withdrawals | 1, 2/2 | `barrierDecidesA429OnTheLaneAWaitingWithdrawalLeaves` `:448`, `:449` |
| **Passed publications (finding 2, PROBE-C14-PASSED-\*)** | | | |
| `verdictVisitDropped` | `followedForVerdict`'s visit | 1 **passed** 2/2; 2, 2/2 | `barrierAnswersAPassedJobsFailureAfterItsVisit` `:651`. Batch 1 ran `4b3dcee`'s design, in which `resolveAll` moved the ids too |
| `passedAtApplyVisited` | the visit also for `publishingAtApply` | 1, 2/2; 2, 2/2 | `barrierAnswersAJobPublishingAtTheApplyAsVisitedFirst` `:555` (1), `:673` (2) |
| `publishedBoundary` | `publishingSince >= apply` → `>` | 1, 2/2; 2, 2/2 | batch 2: `:651`, `:661`, `:686` (t), `:742` |
| `appliesNotCounted` | `appliesFollowed` never counted | 1, 2/2; 2, 2/2 | batch 2: `:673` both orders, `:750`, `:757` visit-first |
| `passedMarkKept` | a real move keeps the mark | 1 **passed** 2/2; 2, 2/2 | `barrierAnswersAPassedJobsRetryAsVisitedFirst` `:750`, `:757` |
| `passedNotMoved`, `movedNoPump` | `4b3dcee`'s move in `resolveAll` and its pump | 1, 2/2 each | `:543`, and `:539` (t); that code was replaced in `d2fad39` |
| `failureMoveDropped` | `d2fad39`'s move at the failure | 2, 2/2 | `barrierAnswersAPassedJobsLaterFailureAsVisitedFirst` `:661`; `barrierAnswersAPassedJobsRetryAsVisitedFirst` `:686` (t), `:742` |
| `publicationEndedIgnored` | `follow` passes the job whose publication failed | 2, 2/2 | the same three |
| `failureMoveNoPump` | the pump after that move | 2, 2/2 | `:657` (t), `:661` |
| `failureMoveBehindBarrier` | the move at the failure also behind the barrier | 2, **passed** 2/2 | None: order only (below) |

**`failureMoveBehindBarrier` survives, and the branch stays.** Behind the barrier, a move at the failure gives the
moved id's re-routed join its place at the failure's arrival, where the drain's visit before the verdict gives it the
verdict's place (`followedForVerdict`); B is served N either way. The difference is one of order and place only
(S3-R16 item 2), the class PROBE-J-FAIL-REROUTE and PROBE-J-FAIL-TICKET found when a deferred verdict's visit still
ran at the failure (`defersFailure`'s doc). The condition keeps one mover behind the barrier, and
that mover is tested (`verdictVisitDropped`).

### Residual risks (cycle 14)

- **RR-1, what is left.** `followedLane` does not count the interests of a job that verifies or commits at the 429
  but downloaded at the apply (`publishedAfterApply`): a visit-first engine moved those onto the throttled job at the
  apply. A 429 then may be decided on a lower lane's policy. That changes an answer only through the `.exhausted` cap
  (a `Retry-After` between the caps), the PROBE-C13-EXHAUST-LANE shape. Not probed.
- **RR-7** is confirmed by S3-R17 (above).

### The inventory, corrected (cycle 14)

These rows replace I1's gate clause and rows I8, I12 and I33 as cycle 13 left them.

- **I1, `EngineDispatch.gate` :548, `dispatch` :384.**
  - A place a visit or a replay gave, at an instant a visit-first pump had a slot for its lane, is refused on its
    stamp's throttle and answered at the stamp's instant.
  - Every start reads the live throttle, breaker, slots and space.
  - Tests: `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply`, `barrierGatesAPlaceWithoutASlotOnTheLiveThrottle`,
    `barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle`, `barrierStartsAVisitsPlaceOnceTheBreakerCloses`.
  - Mutants: `placeStampsIgnored`, `stampParkLive`, `slotIgnored`, `slotLaneBlind`, `stampBreakerBack` killed.
- **I8, `EngineDispatch.publicationFailed` :1193.** As cycle 13, and: outside the barrier, a `publishedAfterApply`
  job's moved ids move before the failure's exit. Tests: `barrierAnswersAPassedJobsLaterFailureAsVisitedFirst`,
  `barrierAnswersAPassedJobsRetryAsVisitedFirst`. Mutants: `failureMoveDropped`, `publicationEndedIgnored`,
  `failureMoveNoPump` (table).
- **I12, `EngineFailures.throttled` :349.** As cycle 13, with `followedLane` as above. Tests: cycle 13's, and
  `barrierDecidesA429OnTheLane…` (three). Mutants: `otherJobsWalkDropped`, `joinsWalkDropped`, `withdrawalsIgnored`
  killed.
- **I33, `EngineCommands.performPurge`, `withdrawPurged` :992, `withdrawPurgedJoins` :1049.** At once, with the
  waiting joins. Tests: `barrierPurgeWithdrawsAWaitingGroupJoin`, `barrierPurgeForgetsAWaitingHeal`. Mutants:
  `purgeJoinsKept`, `purgeJoinMemberKept`, `purgeJoinHealKept`, `withdrawnJoinRegistered` killed.
- **New, `followedForVerdict` :563.** The drain's visit before a deferred verdict, skipped for a
  `publishingAtApply` job. Tests: `barrierAnswersAPassedJobsFailureAfterItsVisit`,
  `barrierAnswersAJobPublishingAtTheApplyAsVisitedFirst`. Mutants: `verdictVisitDropped`, `passedAtApplyVisited`,
  `publishedBoundary`, `appliesNotCounted`, `passedMarkKept` killed.

## Cycle 15: rulings S3-R18 and S3-R18a

Cycle 15 applies **S3-R18** and its amendment **S3-R18a**, both recorded above as an "Orchestrator ruling (close-out)",
to the cycle-14 verifiers' 14 findings (`.build-orchestrator/s3f-c14-issues.json`). The work went in this order:

1. `b461450`: the failing tests, committed on their own, in both `LaneDropVisit` orders, with `.timeLimit(.minutes(3))`,
   in the serialized `EngineFollowBarrierTests` suite. The new files are `EngineFollowBarrierSlotTests.swift`,
   `EngineFollowBarrierPublicationTests.swift` and `EngineFollowBarrierLaneTests.swift`.
   `EngineFollowBarrierAnswerTests.swift` gained the `tuning:` and `failBeforeVisit` parameters and finding 10's
   assertion. What fitted from `wip/s3f-c15a` (`5a87864`) was copied, file by file and hunk by hunk, never merged:
   SlotTests' STAMP-AHEAD scenario (its fix-by-counting left out, S3-R18a item 2), the passed-lane helper,
   `setUpHeldPublications`'s `tuning:` and `barrierDecidesA429OnTheOwnLaneOfAJobNothingKeeps`.
   - On cycle 14's sources (`388f744`), 12 tests fail sweep-first, 2/2 (`.build-s3f/c15/failing-run{1,2}.log`):
     `✘ Test run with 12 tests in 1 suite failed after 11.989 seconds with 17 issues.` and `✘ Test run with 12 tests in
     1 suite failed after 11.981 seconds with 17 issues.` Every visit-first case passes.
   - The failing lines (at `b461450`): SlotTests `:75` (STAMP-AHEAD); PublicationTests `:107` (six times, the
     `serverUnavailable` helper), `:125` (twice), `:138`, `:152`, `:162` (the four PASSED-LANE and PASSED-FAIL cases),
     `:272` (MARK-TWO-APPLIES), `:286` (S3-R18a item 1) and `:301` (a case found this cycle, below); LaneTests `:60`,
     `:61` (finding 9's fallback).
   - `barrierDecidesA429WithoutTheInterestAJobPublishingAtTheApplyKeeps` and
     `barrierDecidesA429WithoutAWaitingRequestThatDoesNotJoinIt` pass on those sources: they are G4 tests for branches
     that stay, not failing tests.
2. `0f32845`: the removals and the re-route (below). Barrier suite after it: `✔ Test run with 91 tests in 1 suite passed
   after 66.849 seconds.` (`.build-s3f/c15/barrier-3.log`); whole Sync bundle: `✔ Test run with 506 tests in 53 suites
   passed after 74.066 seconds.` (`.build-s3f/c15/sync-1.log`, before the last edit to `follow`, which drops a guard
   the code after it made redundant; the barrier run is after it).
3. `9673e2f`: tests for the first mutant round's survivors (G4, below).
4. This draft.

**Found this cycle (blocking under S3-R16 1(a), with its failing run above):** PublicationTests `:301`,
`barrierAnswersAPublicationFailedBeforeItsVisitAsPassed`. C verifies when v3 moves zz-b, and its bytes fail while the
follow is owed, before the turn that finds C. Visited first, the follow passed C at the apply, and the failure answered
both users `integrityFailure`. Cycle 14 met C failed, with its verdict waiting, and visited it as any failed job: B was
moved onto N and served N. The waiting verdict now says whether the attempt reached its publication
(`VerdictAfterFollow.published`), and such a job is passed (`passesOnVisit`).

| Finding | Disposition |
|---|---|
| 1 (correct, blocking): PROBE-C14C-MARK-TWO-APPLIES | **Fixed** in `0f32845` (S3-R18 item 2, S3-R18a item 1). The mark is gone. The ids are recorded when the publication begins (`Job.rerouteOnPass`). Tests: `barrierAnswersALaterApplysPassedIdWithThePublicationsFailure` (v4 after v3's follow) and `barrierAnswersAnIdALaterApplyMovedWhileTheVisitWasOwedWithThePublication` (v4 while v3's follow still owes C's visit, S3-R18a item 1) |
| 2 (correct, blocking): PROBE-C14C-PASSED-LANE | **Fixed** in `0f32845`. `followedLane` counts a passing job's interests in the ids it re-routes. Test: `barrierDecidesA429OnTheLaneAPublicationBegunAfterTheApplyGives` with W at the prefetch lane (the correctness verifier's probe) |
| 3 (correct, blocking): PROBE-C14C-STAMP-AHEAD | **Fixed by removal** (S3-R18 item 1). Place stamps are gone, and the barrier-end pump admits on the live throttle, breaker and slots. Test: `barrierWaitsForTheSlotAnEarlierPlaceTook`: K1 served 16 B and K2 served 20 B in both orders |
| 4 (correct): the merged profile's 0-hit line | **Recorded.** No Scripts/ edit (G1). Every G4 claim this cycle cites a drop-mutant run, not a profile count (table below). `breakerExclusionDropped` covers the line the verifier named (`unwakeableBreakerParks`' exclusion) |
| 5, 13 (correct, reqs): nested drain re-entrancy | **Accepted as non-blocking** (S3-R18 item 3). Recorded as RR-9 with its reason (below) |
| 6 (correct): C2 margins | **Recorded.** `worldStamp()` no longer calls `freeSlots()` per deferred event (removed). This cycle's benchmark figures and load are under "Gate evidence (cycle 15)" |
| 7, 14 (correct, reqs; other-wp:b): P-13 | **Routed** to WP-B (S3-R18 item 3). Not touched |
| 8 (reqs, blocking): PROBE-C14R-PASSED-LANE, PROBE-C14R-PASSED-FAIL | **Fixed** in `0f32845`: the visit re-routes at once the moved ids of a publication begun after the apply. Tests, both orders: `barrierDecidesA429OnTheLaneAPublicationBegunAfterTheApplyGives` (W a user's, the requirements verifier's probe), `barrierDecidesA429AfterTheDrainOnTheLaneAPublicationBegunAfterTheApplyGives`, `barrierAnswersA404WithTheIdAPublicationBegunAfterTheApplyMoved`, `barrierAnswersA404AfterTheDrainWithTheIdAPublicationBegunAfterTheApplyMoved` |
| 9 (reqs, blocking, G4): `followedLane`'s fallback and joins filters | **Fixed.** The fallback is simplified to the job's own lane, the finding's second option. A job no interest keeps was retired by a visit-first engine, so no 429 reached it. The bulk fallback throttled the origin where nothing should have been throttled. Test: `barrierDecidesA429OnTheOwnLaneOfAJobNothingKeeps`, failing on cycle 14's sources (LaneTests `:60`, `:61`). Joins filters: `barrierDecidesA429WithoutAWaitingRequestThatDoesNotJoinIt` (other content, a released group, a withdrawn waiter). Every branch that stays in `followedLane` has a mutant killed 2/2 except `laneJobsWalkAlways`, the walk's C2 guard (table and reason below) |
| 10 (reqs): the breaker invariant's exclusion | **Done** in `b461450`. `barrierStartsAVisitsPlaceOnceTheBreakerCloses` asserts, sweep-first, that `invariantViolations()` is empty while the close's `.unblock(.circuitOpen)` still waits with parked jobs. Mutant `breakerExclusionDropped` (table) |
| 11 (reqs): C2 of `followedLane`'s walk | **Recorded.** The verifier's figure: best 2.41–2.69 ms per call at 10,000 owed jobs (release, load 95–106); 13.3–16.8 ms in debug. This cycle adds, per job of the walk, `passesOnVisit` (a switch, and for a failed job one dictionary lookup) and, for a passing job only, one set lookup per id. No benchmark was added (the finding marks it optional) |
| 12 (reqs): RR-2 and RR-4 | **Not probed** (S3-R18 item 3: not blocking). The blocking items, G4 and the gates took the cycle |

### What cycle 15 removes (S3-R18 item 1)

Line numbers at `388f744` (cycle 14), under `Sources/ZTronAssetSync/Engine/`.

- **The stamp's throttle refusal** in `EngineDispatch.gate` (`:548`), which refused a place on the throttle of its
  decision instant's view.
  - Affected tests: WorldTests `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` and AnswerTests
    `barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle`, whose sweep-first answers change (Test changes, below).
  - Moot mutants: `placeStampsIgnored`. Cycle 14 already removed the stamp's breaker refusal, so `stampBreakerBack`
    is moot too.
- **`dispatch`'s stamped park** (`:391`), which parked a refused place at its stamp's instant against its view's
  throttle end. With it go `park(_:reason:answeredAt:answerEnd:)`'s two parameters and `failFast`'s `at:` and
  `answerEnd:`, which only that park passed; a replayed 429's park still reads its reading's instant and end
  (`decisionNow()`, `throttleEnd(after:)`). Moot mutant: `stampParkLive`. RR-6 goes with it.
- **The stamping in `enqueue`** (`:471`), and `EngineState.placeStamps` with its clears in `removeJob`,
  `endWorldHistory`, `scheduleDrainFollowUp` and shutdown, and its clause in `followBarrierViolations`. Moot mutant:
  `slotIgnored`.
- **`freeSlots()`** (`:82`), **`FreeSlots`** and **`WorldStamp.freeSlots`**. Moot mutant: `slotLaneBlind`. Finding 6's
  profiling target goes too.
- **`start`'s edge serial from the stamp's view** (`:768`). A start now records the live edge serial
  (`networkEdgeSerial`): the place starts on the live gates, so an edge before that start is not one its attempt
  missed. No test distinguished the two (no mutant existed); recorded as RR-10.

### What cycle 15 removes and adds (S3-R18 item 2, S3-R18a)

Removed:

- `PassedPublication`, `Job.passedPublishing`, `Job.publishingSince`, `EngineState.appliesFollowed` and
  `WorldStamp.apply`, which counted the followed applies.
- `followPassedPublication` and its call in `publicationFailed` (`:1206`).
- `followedForVerdict`, the drain's visit before a waiting verdict (`:563`).
- `follow(_:publicationEnded:)`'s parameter, `visit(_:at:)`'s nil-stamp path, and `holdsIDListedElsewhere`, which is
  folded back into `holdsMovedID`.
- In `followedLane`: the skip of verifying and committing jobs, the dead `followBarrier` guard (its only caller,
  `throttled`, reads it behind the barrier), the optional result and the held-lane-or-bulk fallback.
- Moot mutants, their code gone: `verdictVisitDropped`, `passedAtApplyVisited`, `publishedBoundary`,
  `appliesNotCounted`, `passedMarkKept`, `failureMoveDropped`, `publicationEndedIgnored`, `failureMoveNoPump` and
  `failureMoveBehindBarrier`. The last survived in cycle 14; S3-R18 item 3 makes it moot with the mover.

Added (line numbers at `0f32845`):

- **`Job.rerouteOnPass`** (`EngineState` `:618`). `publish` (`EngineDispatch` `:1018`) sets it when the publication
  begins. While a follow is owed, it is the ids the copy maps elsewhere: a visit-first engine visited the job at that
  follow's apply while it still downloaded, and moved them then. Otherwise it is empty: every visit has run, and an id
  the copy maps elsewhere is one a visit passed. `start` (`:731`) clears it to `nil`: a new attempt's publication is a
  new one.
- **`VerdictAfterFollow.published`** (`EngineFollow` `:398`): whether the failed attempt reached its publication
  (`rerouteOnPass != nil`, read when the verdict is deferred). The publication failure paths set the job `failed`
  before they defer, so the job's state cannot tell.
- **`passesOnVisit`** (`:622`). A visit passes a verifying or committing job, and a failed job whose waiting verdict is
  a publication's.
- **`follow`** (`:645`). For a job it passes, the visit re-routes at once the moved ids in `rerouteOnPass`, leaving the
  job's bytes, ledger entry and publication untouched. It passes the others; the job stays in `unfollowed` while any
  stays passed. A job it does not pass is followed as before.
- **`replayVerdict`** (`:423`). The drain gives the verdict to whatever the job still holds after the visits.
- **`followedLane`** (`EngineFailures` `:671`). A passing job's interests count only in the ids it re-routes, and the
  job's own lane is the fallback.

**The fallback (per-pass id lists) is not needed.** No probe shows the re-route breaking a MUST or an invariant:
- The commit binds only the ids the copy maps to the job (R-SYN-11). A re-routed id has left `assets`, so the commit
  never binds it.
- The bytes and the ledger entry stay with the publication, so the space accounting is unchanged.
- `invariantViolations()` is checked at the end of every barrier test. "A job holds an id the copy maps elsewhere
  and is not in `unfollowed`" holds: re-routed ids leave `assets`, and passed ids keep the job in `unfollowed`.
- A passing job whose ids all re-route keeps no asset. `retire` keeps a verifying or committing job until its
  publication ends, and its commit binds nothing.

### Test changes (S3-R18 item 1's G3 exception; S3-R16 item 4)

Two sweep-first answer assertions change one to one, as S3-R18 item 1 authorises. In each, the difference is caused
only by the origin's throttle ending during the barrier. The scenario, its operations and every visit-first
assertion are unchanged.

| Test | Old assertion (sweep-first) | New assertion (sweep-first) | Ruling |
|---|---|---|---|
| WorldTests `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply` | `uResult` is `.failure(.serverUnavailable(retryAfter: r))` with `abs(r - 10) < 0.5` (the apply's 10 s throttle, which ended during the barrier) | `(try? uResult.get())?.byteSize == 16`: U is served N, admitted on the live gates once the throttle had ended | S3-R18 item 1 |
| AnswerTests `barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle` | `kResult` is `.failure(.serverUnavailable)` (K refused on its arrival's throttle) | `(try? kResult.get())?.byteSize == 16`: K is served, admitted once the live throttle had ended | S3-R18 item 1 |

Display names follow the change. The first becomes "R-SYN-5: the new content an owed follow's visit queues is gated on
the live throttle, the apply's when visited first (F-28)" (it read "R-SYN-11: … gated on the throttle in force at the
apply, though it ended since"). The second becomes "… is gated on the live throttle, its arrival's when visited first
(F-28)". The comments after the first test's answers are corrected the same way.

Setup assertions of cycle 14's own tests read the removed mark, so they now read the state that replaces it. These
are not answer assertions:

- `passedPublication` (AnswerTests, sweep-first):
  - old: `passed.owed && passed.c == .verifying && passed.passed`, with `passed` meaning "in `unfollowed` and visited";
  - new: `… && passed.visited && rerouted`, where `rerouted` is `holdsB && unfollowed` when C published at the apply
    and `!holdsB && !unfollowed` when it began after.
- `barrierAnswersAPassedJobsRetryAsVisitedFirst`:
  - the setup assertion becomes `… && passed.visited && !passed.holdsB && !passed.unfollowed`;
  - `passedAgain` changes from `mark == .publishingAtApply` to `c == .verifying && holdsC && unfollowed`.

No other pre-existing assertion changed.

### Mutants (S3-R16 1(e))

Setup:
- `.build-s3f/c15/mut.py` (cycle 14's `mutB.py` with cycle-15 paths) copies `Sources/` and `Tests/` into
  `.build-s3f/mutsrc{,2,3,4}` and applies each edit there with a count check.
- It builds in `.build-s3f/mutbuild{,2,3,4}`, runs the filter `EngineFollowBarrier|probeSupersededFreesSlot` twice,
  reverts, and diffs the copy's `Sources/` against the worktree. Every revert printed "none".
- The worktree is never edited. Definitions: `.build-s3f/c15/mutants.json`.

| Round (logs) | Sources and tests | Tests in the filter |
|---|---|---|
| 1 (`mut-{a,b,c,d}.log`, `mut{,2,3,4}/`) | `0f32845` | 92 |
| 2 (`mut2-{b,c,d}.log`, `mut{2,3,4}/`) | sources `0f32845`, tests `9673e2f` | 97 |

Every failure is sweep-first except where "both" is written; (t) marks a time limit. Lines are each round's commit's.

| Mutant | Branch | Round, result | Killed by |
|---|---|---|---|
| **The re-route (S3-R18 item 2, S3-R18a)** | | | |
| `passNone` | `follow` re-routes every moved id of a passing job | 1, 2/2 | PublicationTests `:272`, `:286` (two applies), `:301` (both); AnswerTests `:708`, `:791`, `:798` (both); ApplyTests `:103`, `:125` |
| `passAll` | `follow` passes every moved id (no re-route) | 1, 2/2 | PublicationTests `:107`, `:138`, `:152`, `:162`; AnswerTests `:650`, `:686`, `:696`, `:721` (t), `:770`, `:781`; ReachTests `:210` |
| `passedNotUnfollowed` | a passed id leaves the job out of `unfollowed` | 1, 2/2 | AnswerTests `:650`, `:791` (both); ApplyTests `:103` |
| `publishRerouteNone` | `publish` records no ids | 1, 2/2 | as `passAll`, and PublicationTests `:125` |
| `publishOwedDropped` | `publish` records the moved ids also while no follow is owed | 1 **passed** 2/2; 2, 2/2 | RetryTests `:88`, `:96` (both; `barrierPassesAgainTheIdARetriedPublicationCarries`: zz-b re-routed at v4's visit, B served N) |
| `startClearDropped` | `start` keeps the last publication's ids | 1 **passed** 2/2; 2, 2/2 | RetryTests `:164`, `:170` (`barrierVisitsARetryThatFailsBeforeItsVisitAsADownload`: the verdict reads `published`, B gets the 404) |
| `passesFailedFalse` | a failed job is never passed | 1, 2/2 | PublicationTests `:301` (`barrierAnswersAPublicationFailedBeforeItsVisitAsPassed`) |
| `passesFailedTrue` | every failed job is passed | 1, 2/2 | ClassTests `:220`, `:430`–`:433`, `:626`; VerdictTests `:66`, `:305`, `:308`, `:364`, `:427`, `:480` |
| `spaceFailureEpochDropped` | the `.spaceFailure` replay without its epoch check | 1 **passed** 2/2 | None (below) |
| **`followedLane` (finding 9)** | | | |
| `laneCountsPassing` | a passing job's interests count in every id | 1, 2/2 | PublicationTests `:176`, `:177` (`…WithoutTheInterestAJobPublishingAtTheApplyKeeps`), `:107` |
| `laneSkipsPassing` | a passing job's interests never count | 1, 2/2 | PublicationTests `:125`, `:107` (`…OnTheLaneAPublicationBegunAfterTheApplyGives`) |
| `laneFallbackHeld` | cycle 14's fallback (held lane or bulk) | 1, 2/2 | LaneTests `:60`, `:61` (`barrierDecidesA429OnTheOwnLaneOfAJobNothingKeeps`) |
| `laneOwnWithdrawnIgnored` | own interests counted though their withdrawal waits | 1, 2/2 | AnswerTests `:588`, `:589` |
| `laneOwnVisitedIgnored` | own interests counted though none of their ids stays | 1, 2/2 | ClassTests `:283`, `:288` |
| `laneJobsWithdrawnIgnored` | other jobs' interests counted though their withdrawal waits | 1 **passed** 2/2; 2, 2/2 | LaneTests `:207`, `:208` (`barrierDecidesA429WithoutAMovedInterestWithdrawn`) |
| `laneJobsWalkAlways` | the walk over other jobs also while no follow is owed | 1 **passed** 2/2 | None (below) |
| `laneJoinTokenWithdrawnIgnored` | a waiting join counted though its owner's withdrawal waits | 1, 2/2 | LaneTests `:149`, `:150` (`withdrawnWaiter`) |
| `laneJoinWithdrawnFlagIgnored` | a join a purge withdrew still counted | 1 **passed** 2/2; 2, 2/2 | LaneTests `:140`, `:141` (`barrierDecidesA429WithoutAPurgedHealsJoin`) |
| `laneJoinTargetIgnored` | a waiting join for other content counted | 1, 2/2 | LaneTests `:149`, `:150` (`otherContent`); PublicationTests `:107` |
| `laneJoinListedTargetIgnored` | a waiting join read at its own entry, not the copy's | 1 **passed** 2/2; 2, 2/2 | LaneTests `:271` (`barrierDecidesA429OnTheLaneAJoinALaterApplyMovedGives`); PublicationTests `:107` (its `serverUnavailable` helper) |
| `laneJoinStillWantsIgnored` | a released group's join counted | 1, 2/2 | LaneTests `:149`, `:150` (`releasedGroup`) |
| **Finding 10** | | | |
| `breakerExclusionDropped` | `unwakeableBreakerParks` without its waiting-re-admission exclusion | 2, 2/2 | AnswerTests `:158` (`barrierStartsAVisitsPlaceOnceTheBreakerCloses`: `invariantViolations()` while the close's `.unblock` waits) |

Round 2's tests (`9673e2f`), each in both orders, each passing on `0f32845`'s sources:

- `barrierPassesAgainTheIdARetriedPublicationCarries` (RetryTests). v3's follow passes C, publishing, with zz-b. C's
  verification read fails (EIO) and C is retried. The retry's publication begins while no follow is owed, and v4's
  follow passes it with zz-b and zz-c. All three users get `integrityFailure`, as visited first.
- `barrierVisitsARetryThatFailsBeforeItsVisitAsADownload` (RetryTests). C's first publication fails (EIO) and C is
  retried. v3 moves zz-b while the retry downloads; the retry gets a 404 before the follow's turn that finds C. B is
  served N, A gets `notFound`. The test also asserts the waiting verdict's `published == false`.
- `barrierDecidesA429WithoutAMovedInterestWithdrawn` (LaneTests). Y's visit moves U onto C, and U withdraws before C's
  429. The origin is throttled for prefetch work and P is served by C's retry.
- `barrierDecidesA429WithoutAPurgedHealsJoin` (LaneTests). A heal's join of C's content waits, withdrawn by a purge,
  while C's only user withdraws. Nothing is throttled, and a later user request is served.
- `barrierDecidesA429OnTheLaneAJoinALaterApplyMovedGives` (LaneTests). A user's join waits with Y's entry, and v4,
  applied while v3's follow is still owed, moves the id onto C's content. C is user work at the 429: nothing is
  throttled, and P and U get `serverUnavailable`.

**Two survivors stay, with reasons.**

- **`laneJobsWalkAlways`.** The barrier holds with no follow owed only between two drain turns, when more than 512
  events wait. No test and no seam reaches a 429 there.
  - There, the only jobs the walk could add are jobs that hold an id an earlier visit passed and that no longer
    publish: a passed publication that failed and was retried.
  - A visit-first engine left that id on the job until the next follow, so it did not count its interest. The guard is
    the right program there, and the mutant is the wrong one.
  - The guard also keeps the walk, which is O(jobs) (finding 11), off the drain's turns.
  - Killing it needs a seam that holds a drain turn; one is proposed to the orchestrator (§14, below).
- **`spaceFailureEpochDropped`.** The epoch check predates this cycle: it was `followedForVerdict`'s first guard, and
  only the visit after it is removed.
  - A job's epoch changes only at `start`, and no start runs behind the barrier. A job removed meanwhile leaves
    `jobs[transfer]` `nil`, which `decideSpaceFailure` checks itself.
  - So the mutant differs only where a join replayed earlier in the same drain created a new job for the same
    transfer. That job is `queued`, and the mutant only writes its `lastError`. No test builds it.

### Residual risks (cycle 15)

- **RR-1 is closed.** `followedLane` now counts the interests a passing job's visit re-routes (cycle 14's remainder,
  PROBE-C14R-PASSED-LANE and PROBE-C14C-PASSED-LANE, fixed). No remainder is known.
- **RR-6 is removed.** No place is stamped, so no place answers at a stamp's instant.
- **RR-8. A place given behind the barrier is admitted on the live gates** (S3-R18 item 1, S3-R17 item 2).
  - Where the throttle a visit-first pump met at the apply ended during the barrier, the place starts and its users are
    served: the two changed sweep-first assertions are its probes.
  - Where a throttle set during the barrier is live, the place parks and is answered with the live wait.
  - Only a live origin gate changing during the barrier causes the difference, so it is non-blocking.
- **RR-9. A space sweep started inside a drain replay runs a nested drain** (cycle-13 finding 11; cycle-14 findings 5
  and 13; S3-R18 item 3).
  - Through `checkRunSettled`'s `.read` sweep, `advanceFollowForSpaceSweep` can call `drainEventsAfterFollow` while a
    drain replays.
  - No test reaches it: it needs a run's claim parked `insufficientSpace` that the ledger admits while the drain
    replays.
  - The suggested change, judging at once inside the drain, would be a branch with no killing test (S3-R16 1(e)).
  - Accepted as non-blocking by S3-R18 item 3.
- **RR-10. A start's edge serial is the live one** (removal 1).
  - A place given behind the barrier before a network edge that arrived during the barrier starts after that edge.
    Its attempt does not count the edge as one it missed, so a transient failure is not re-queued early on it.
  - Visited first, the attempt started before the edge, and that failure would have been re-queued on the edge.
  - Only the timing of a re-queue differs. Not probed.

### Put to the orchestrator (found while fixing; not changed this cycle)

These were found by analysis while writing the re-route. Neither was probed this cycle, and both predate it.

- **A verdict that waits across a later apply.**
  - Behind the barrier, a failure verdict deferred while v3's follow is owed is replayed after the visits of every
    later apply that lands before the drain (v4).
  - A visit-first engine answered that verdict before v4 existed.
  - Example: C downloads for A and B, a 404 arrives behind v3's barrier, then v4 moves zz-b. Visit-first, B was answered
    `notFound` with A. Behind the barrier, v4's visit meets C failed with a download's verdict (`published == false`),
    moves zz-b, and serves B its new content.
  - The same class covers a publication's verdict met by a later apply's visit. `published` is one flag per verdict,
    not per apply.
  - A fix would compare the verdict's arrival with the visit's apply: a verdict that arrived before the apply leaves the
    job to the verdict. That is new machinery that S3-R16 item 3 asks the orchestrator to weigh.
- **The publication failure's await window.**
  - `integrityFailed` sets the job `failed` and then awaits the store (`sparePresent`, `recordIntegrityFailure`). It
    defers its verdict only at `resolveAll`.
  - A follow turn that runs inside that window meets a failed job with no waiting verdict and visits it as a download:
    it moves the ids the copy maps elsewhere, though a visit-first engine that visited at that follow's apply, while the
    job published, passed them.
  - The window is the store's integrity record. Not probed.
- **A seam to hold a drain turn**, which would let a test kill `laneJobsWalkAlways` (above).

### The inventory, corrected (cycle 15)

These rows replace cycle 14's I1, I8, I12 and its "New, `followedForVerdict`" row. Line numbers at `0f32845`.

- **I1, `EngineDispatch.gate` `:490`, `dispatch`.**
  - Every place, a visit's and a drain replay's included, is admitted on the live throttle, breaker, slots and space.
  - A refused place parks and is answered at the decision instant (`decisionNow()`); a replayed 429's park reads its
    reading's instant and end.
  - Tests: `barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply`, `barrierGatesAPlaceWithoutASlotOnTheLiveThrottle`,
    `barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle`, `barrierStartsAVisitsPlaceOnceTheBreakerCloses`,
    `barrierWaitsForTheSlotAnEarlierPlaceTook`.
  - The stamp mutants are moot (their code is removed).
- **I8, `EngineDispatch.publicationFailed` `:1162`.**
  - Nothing moves at a publication's failure. The visit that passed the publication re-routed its ids in
    `rerouteOnPass`, and the publication's outcome answers the others.
  - Behind the barrier, its verdict waits with `published == true`, so a visit that meets the failed job passes it.
  - Tests: `barrierAnswersAPassedJobsFailureAfterItsVisit`, `barrierAnswersAPassedJobsLaterFailureAsVisitedFirst`,
    `barrierAnswersAJobPublishingAtTheApplyAsVisitedFirst`, `barrierAnswersAPassedJobsRetryAsVisitedFirst`,
    `barrierAnswersAPublicationFailedBeforeItsVisitAsPassed`, the two two-applies tests and the two RetryTests.
  - Mutants: the re-route rows of the table.
- **I12, `EngineFailures.throttled` `:349`, `followedLane` `:671`.**
  - Behind the barrier, a 429 is decided on the lane a visit-first engine's job had. That lane is the highest of:
    - its own interests, less those a waiting withdrawal removes, and, when the job is owed a visit, less those none of
      whose ids the copy still maps to it;
    - the interests other jobs' owed visits move onto it, counting a passing job's only in the ids it re-routes;
    - the waiting joins that join it at the drain.
  - The job's own lane when none counts.
  - Tests: cycle 13's and cycle 14's, the five 429 tests of PublicationTests, and LaneTests' six.
  - Mutants: the `followedLane` rows, `laneJobsWalkAlways` surviving with its reason.
- **New, `EngineFollow.follow` `:645`, `passesOnVisit` `:622`, `defersFailure` `:384`, `replayVerdict` `:423`.**
  - The visit passes a publishing job, or a failed one whose waiting verdict is a publication's.
  - It re-routes at once the ids in `rerouteOnPass` and passes the rest.
  - The drain gives a waiting verdict to what the job holds after the visits.
  - Tests and mutants: the re-route rows.

### Hang guards and re-entrancy

- The new tests use `.minutes(3)`, as the suite's do.
- No `await` was added in an actor: `git diff 388f744..HEAD -- Sources | grep '^+.*await '` is empty. So no
  `// REENTRANCY:` comment and no ledger row is proposed.
- 0 unsafe escapes (gate below).

## Cycle 16: the cycle-15 verifiers' findings, and S3-R19

Cycle 16 applies **S3-R19**, recorded above as an "Orchestrator ruling (close-out)", to the cycle-15 verifiers' findings
(the requirements lens's `reqs-1`…`reqs-5` and the correctness lens's `correct-1`…`correct-6`, with their non-blocking
notes). Both of S3-R19 item 1's put-backs had been probed by those verifiers in both `LaneDropVisit` orders, with a
different answer sweep-first, so both are blocking and fixed by the comparison item 1 names. The work went in this order:

1. `39e18d2`: eight failing tests, committed on their own, each in both orders with `.timeLimit(.minutes(3))`, in the
   serialized `EngineFollowBarrierTests` suite. New files: `EngineFollowBarrierStaleRerouteTests.swift`,
   `EngineFollowBarrierVerdictApplyTests.swift`, `EngineFollowBarrierWindowTests.swift`; PublicationTests gained one.
   - On cycle 15's sources (`e64cdba`) every one fails sweep-first only, on its answer assertion, and passes visit-first:
     `✘ Test run with 8 tests in 1 suite failed after 7.494 seconds with 9 issues.` (`.build-s3f/c16/fail-head2.log`:
     PublicationTests `:361`, StaleRerouteTests `:108`, `:118`, VerdictApplyTests `:140`, `:155`, `:168`, WindowTests
     `:168`, `:179`, and a setup expectation, ReachTests `:30`, of the ENOSPC test's first version), then, with the
     ENOSPC test's space-sweep follow-ups held, `✘ Test run with 3 tests in 1 suite failed after 2.951 seconds with 3
     issues.` (`fail-head3.log`: VerdictApplyTests `:141`, `:156`, `:169`, the version committed).
2. `abaeec1`: a ninth failing test (the same follow's later visit, below), on `e64cdba`'s sources with the tests of
   `abaeec1`: `✘ Test run with 3 tests in 1 suite failed after 3.432 seconds with 3 issues.` (`fail-head4.log`:
   StaleRerouteTests `:153`, `:165`, `:175`, sweep-first only).
3. `33b1976`: the fix (below). Barrier suites after it: `✔ Test run with 106 tests in 2 suites passed after 77.951
   seconds.` (`barrier4.log`); the Sync bundle: `✔ Test run with 520 tests in 53 suites passed after 86.417 seconds.`
   (`sync1.log`, load 2.98).
4. `f6ba277`: finding `reqs-5`/`correct-5`'s race in `barrierAnswersAPassedJobsRetryAsVisitedFirst`, and two stale doc
   comments.
5. `ef71ca9`: a drain-turn test seam and the LANE-WALK test (finding `reqs-3`).
6. `ea5595e`, `c3f675b`: G4 tests for the branches the fix adds (mutant rounds 1 and 2, below).
7. `e67f467`, `e9960ef`, `c161818`, `d3242d3`: the survivors of mutant rounds 1 and 2, settled under S3-R19 item 3
   (below).
   Barrier suites after `c161818`'s sources: `✔ Test run with 114 tests in 2 suites passed after 86.119 seconds.`
   (`barrier5.log`, load 2.32).
8. This draft.

### The findings

| Finding | Disposition |
|---|---|
| `reqs-1` (blocking): PROBE-C15R-REROUTE-STALE, seed 1_515_002 | **Fixed** in `33b1976`. The visit that uses a publication's re-route set spends it (`Job.rerouteOnPass` emptied, found moved ids or not). Test: `barrierLeavesAnIdMovedBackAndAwayToThePublication` (StaleRerouteTests `:150`) |
| `correct-4` (blocking): PROBE-C15C-STALE-REROUTE, seed 1_515_902 | **Fixed** in `33b1976`. When v4 maps the id back while the follow still owes the visit, the pass compares with the current copy and the visit never comes, so spending at the visit is not enough: the set belongs to the follow owed when it was recorded (`Job.rerouteFor`, `EngineState.followsEnded`) and is spent once that follow ends. Test: `barrierSpendsTheRerouteOfAVisitThatFindsNothingMoved` (`:162`); `barrierSpendsTheRerouteForTheSameFollowsLaterVisits` (`:172`, `abaeec1`) keeps the spending at the visit killable |
| `reqs-2`, `correct-3` (blocking): PROBE-C15R-VERDICT-LATER-APPLY, PROBE-C15C-VERDICT-ACROSS-APPLY (S3-R19 item 1, first put-back) | **Fixed** in `33b1976` by the comparison S3-R19 item 1 names, which replaces `VerdictAfterFollow.published` (below). Tests (VerdictApplyTests): a 404 (`:151`, seed 1_515_302), an ENOSPC that parks (`:162`), a timeout at the retry cap (`:179`); the drain's move after a verdict that leaves the job alive: a retry (`:192`) and an ENOSPC retry (`:202`); the lane it gives a 429 (VerdictLaneTests `:128`, four endings) |
| `correct-2` (blocking): PROBE-C15C-INTEGRITY-WINDOW, seed 1_516_302 (S3-R19 item 1, second put-back) | **Fixed** in `33b1976`: the publication's end is recorded in its own turn, before the bookkeeping that awaits the store (`recordPublicationEnd`). A visit inside the window, for an apply made while the job published, passes it; one for an apply made inside the window moves its moved ids. Tests: `barrierPassesAPublicationFailingInItsBookkeeping` (WindowTests `:165`) and `barrierMovesTheIdsOfAnApplyInsideAPublicationFailure` (`:176`, seed 1_616_302), which hold the window open on a stepped metadata executor |
| `correct-1` (blocking): PROBE-C15C-ENOSPC-PASSED | **Fixed** in `33b1976`: an ENOSPC's deferral is recorded on the job as an attempt's verdict is (`recordDeferredVerdict` in `spaceFailed`), so the visit meets a publication's ENOSPC as a publication's. Test: `barrierLeavesAPassedIdToAPublicationsSpaceRetry` (PublicationTests `:312`, seed 1_616_402) |
| `reqs-3` (blocking): PROBE-C15R-LANE-WALK, seed 1_516_202, `laneJobsWalkAlways` not equivalent | **Restructured** (the finding's second option; S3-R19 item 2). The guard now decides nothing: with it false the walk adds nothing (argument below), and `laneJobsWalkAlways` is equivalent, cost-only. The decision it carried is the inner check that an owed visit's ids count only while a follow is owed, killed by `barrierDecidesA429BetweenDrainTurnsOnItsJobsOwnInterests` (DrainLaneTests `:26`, seed 1_616_602) through a new drain-turn seam (`holdDrainFollowUps`), which S3-R19 item 2 does not require but the inner check needs to be killed (G4) |
| `reqs-4`, `correct-6` (blocking): PROBE-C15R-SPACE-EPOCH, seed 1_515_602, `spaceFailureEpochDropped` | **Kept and killed.** The check is reached: the drain's earlier join creates a new job for the same content, which the mutant parks `insufficientSpace`. It was added in `02d51a0`, after `s3-base`, in the follow-barrier class, so S3-R19 item 3's third option does not apply, and removing it changes the answer. The verifiers' probe is the test: `barrierGivesASpaceVerdictOnlyToTheJobThatFailed` (SpaceEpochTests `:22`). Cycle 15's row and survivor reason are corrected below |
| `reqs-5`, `correct-5` (blocking): `barrierAnswersAPassedJobsRetryAsVisitedFirst` flaky (PROBE-C15C-RETRY-FAULT-RACE) | **Fixed** in `f6ba277`. Sweep-first, the test installed its EIO fault for C's hash while N, admitted once the barrier dropped, could still publish; when N's hash read came first, N took the fault and B was never answered. The sweep branch now waits, driving the clock, for N's job to end before the fault. Six consecutive runs passed (`flaky{1…6}.log`); the TSan run is under "Gate evidence (cycle 16)" |
| `reqs` (non-blocking): PROBE-C15R-AWAIT-WINDOW's result | **Recorded** under "Residual risks (cycle 16)": the probe passed in both orders on `e64cdba`; the class it aimed at is `correct-2`'s, fixed |
| non-blocking: AnswerTests `:680` (`followedForVerdict`) and `:719` (`Job.passedPublishing`) | **Fixed** in `f6ba277`: the comments name the re-route at the visit and the resets at the retry's start |
| non-blocking: S3-R13 evidence | **Recorded**: the cycle-15 verifier's run (`Build complete! (49,82 s)`, 0 `warning:` lines) is quoted under "Gate evidence (cycle 16)", with this cycle's run |
| non-blocking: "LaneTests' six" | **Corrected** below: five `@Test` functions, one of them parameterized over `WaitingRequest` |
| non-blocking: `followedLane`'s C2 margin | **Recorded as unmeasured** (S3-R19 item 2), under "Residual risks (cycle 16)" |
| non-blocking: P-13 (`BenchStorage.swift:249`) | **Routed**, WP-B's (`other-wp:b`). Not touched |
| non-blocking: RR-2, RR-4, RR-10 | **Kept recorded**, not probed (S3-R19 item 4) |
| non-blocking: the `laneJoinTargetIgnored` and `laneJoinStillWantsIgnored` rows' citations | **Corrected** below |
| non-blocking: `laneJobsWalkAlways`'s reason | **Corrected** below, and the mutant is now equivalent |

### What cycle 16 changes (`33b1976`; S3-R19 item 1)

A visit-first engine's visit at an apply met the job as it stood at that apply: publishing, failed in its publication's
bookkeeping with no verdict yet, or as the verdict had left it. Behind the barrier the visit runs later, so it compares
the apply with the job's attempt end and verdict, counted in applies followed:

- **`EngineState.appliesFollowed`** counts the applies followed (`followApplied`, before any visit). **`Job.attemptEnd`**
  (`AttemptEnd`) holds `failedAfter`, the count when a publication ended in a failure (`recordPublicationEnd`, in
  `publicationFailed`'s own turn) or, for any other attempt, when its verdict deferred, and `deferredAfter`, the count
  when the exit verdict deferred (`recordDeferredVerdict`, in `defersFailure` and in `spaceFailed`'s deferral). Both are
  reset at an attempt's start. They replace cycle 15's `VerdictAfterFollow.published`.
- **`rerouteOnVisit`** replaces `passesOnVisit`. It returns what a passing visit re-routes, or `nil` to move every moved
  id:
  - publishing: the publication's set (`Job.rerouteOnPass`, as in cycle 15);
  - failed with its verdict waiting: the ids moved before the verdict arrived, re-routed; the rest left to the verdict;
  - failed in its publication's bookkeeping, no verdict yet: the publication's set while no apply was followed since
    the end (a visit for an apply made while it published), else `nil` (an apply made inside the window);
  - otherwise `nil`.
- **`recordDeferredVerdict`** sets the set a waiting verdict's visit re-routes: the ids the copy lists elsewhere while a
  follow is owed, which a visit-first engine moved before the verdict arrived, unless the attempt ended in its
  publication with no apply since, whose set stays the publication's.
- **The set is spent**: the visit that uses it empties it, found moved ids or not (`reqs-1`), and a set whose follow has
  ended (`Job.rerouteFor` against `EngineState.followsEnded`) counts as empty (`correct-4`).
- **After the verdict**, the drain moves from the job the verdict leaves the ids applies moved after it deferred
  (`endDeferral`, `followAfterVerdict`, after `giveVerdict` and after `decideSpaceFailure`), as the later apply's visit
  did for a visit-first engine. A job the verdict ended has nobody left to move.
- **A job not publishing whose every id moves is superseded**, re-routed ids included, as before for a failed download
  (its visit no longer goes through the "passing" branch alone).
- **`followedLane`** counts, of another job whose verdict waits with an apply followed since, the interests the drain
  moves after the verdict, less those the verdict answers (`movesAfterVerdict`, `verdictAnswers`). The walk runs while a
  follow is owed or a verdict waits; an owed visit's ids count only while a follow is owed.
- The `.spaceFailure` replay keeps its epoch check (`reqs-4`), now `guard let job …, job.epoch == epoch`.
- `e67f467` removes `followedLane`'s epoch filters on waiting verdicts: by content, the last verdict waiting is read.
  Mutant `laneVerdictEpochDrop` showed them cost-only (below).
- `e9960ef` adds an `invariantViolations()` clause: a job that downloads holds no `Job.attemptEnd` and no
  `Job.rerouteOnPass`, the two fields `start` resets.
- `ef71ca9` adds the test seam `holdDrainFollowUps()`/`releaseDrainFollowUps()` (`EngineState.drainFollowUpsHeld`,
  `drainFollowUpWaiting`), as the follow's own: no production path sets it.

### Test changes (G3 one-to-one; S3-R16 item 4)

- `barrierVisitsARetryThatFailsBeforeItsVisitAsADownload` (RetryTests), a cycle-15 test: the field it read is removed
  with `VerdictAfterFollow.published` (S3-R19 item 1). One assertion is replaced by the state that now says the same:
  - old: `#expect(unvisited.published == false, "the waiting verdict is a download's, not a publication's: …")`, reading
    `e.state.verdictsAfterFollow[a.transferID]?.published`;
  - new: `#expect(unvisited.reroute == [b.identifier], "the waiting verdict is a download's: its visit re-routes the id
    v3 moved before it, not a publication's: …")`, reading `e.state.jobs[a.transferID]?.rerouteOnPass`.
  - Its answer assertions are unchanged, and its doc comment names the new fields.
- `barrierAnswersAPassedJobsRetryAsVisitedFirst` (AnswerTests): no assertion changed. Sweep-first it waits for N's job
  to end before the fault (`reqs-5`); two doc comments of the file name the current mechanisms.
- Cycle 16's own tests changed before this draft: StaleRerouteTests' helper takes a `StaleRerouteV4` instead of a
  `Bool` (`abaeec1`); VerdictApplyTests' retry case gets a 404 at its retry, and its supersede case a re-queue instead
  of a retry (`c3f675b`), so that each decides on an answer (mutant round 1 showed both passing with the branch
  dropped).

### Mutants (S3-R16 1(e))

Setup: `.build-s3f/c16/mut.py` and `mut2.py` (cycle 15's runner) copy `Package.swift`, `Sources/` and `Tests/` into
`.build-s3f/mutsrc`, apply each edit with a count check, build in `.build-s3f/mutbuild`, run the mutant's filter twice,
revert, and diff the copy's `Sources/` against the worktree; every round printed `revert diff: none`. Round 1
(`mut/summary.log`) ran on `ea5595e`'s sources and tests without `f6ba277`'s AnswerTests change; round 2 (`mut2/`) on
`c3f675b`; round 3 (`mut3/`) on `c3f675b`, with the filter extended to the PublicationTests test rounds 1 and 2 left
out; round 4 (`mut4.py`, `mut4/summary.log`, `summary2.log`) re-syncs the copy first and ran on `c161818` and
`d3242d3`. Every failure is sweep-first. Lines are each round's tree's (round 1's VerdictApplyTests lines are
`ea5595e`'s).

| Mutant | Branch | Result | Killed by |
|---|---|---|---|
| `consumeDrop` | the visit does not spend the re-route set | 1: 2/2 | StaleRerouteTests `:175` |
| `followGenerationDrop` | a set whose follow ended still re-routes | 1: 2/2 | StaleRerouteTests `:165` |
| `failedNeverPasses` | a failed job is never passed | 1: 2/2 | PublicationTests `:361`; VerdictApplyTests `:141`, `:156`, `:169` |
| `inWindowCheckDrop` | a visit inside the window passes whatever apply it is for | 1: 2/2 | WindowTests `:179` |
| `verdictRerouteAlways` | a deferral recomputes the set also for a publication that ended with no apply since | 1, 2: **passed** 2/2 (filters without the test below); 3: 2/2 | PublicationTests `:301` |
| `verdictRerouteNever` | a deferral never records the ids moved before it | 1: 2/2 | RetryTests `:164`, `:170`; VerdictApplyTests `:222`, `:235` |
| `attemptDeferralRecordDrop` | `defersFailure` records nothing on the job | 2: 2/2 | RetryTests `:164`; VerdictApplyTests `:154`, `:182`, `:247` |
| `spaceDeferralRecordDrop` | `spaceFailed`'s deferral records nothing on the job | 1: 2/2 | VerdictApplyTests `:156` |
| `publicationEndDrop` | `publicationFailed` records no end | 1: 2/2 | PublicationTests `:361`; WindowTests `:168` |
| `startEndResetDrop` | `start` keeps the last attempt's end | 2: **passed** 2/2 (the barrier suites, 112 tests); 4: 2/2 | WindowTests `:217` (the `e9960ef` clause; `:228` since `05f94cc`) |
| `startRerouteResetDrop` | `start` keeps the last publication's re-route set | 4: 2/2 | WindowTests `:217` (`:228` since `05f94cc`) |
| `attemptInvariantDrop` | the `e9960ef` clause dropped | 4: **passed** 2/2 | Expected (below) |
| `followAfterVerdictDrop` | the drain moves nothing after a verdict | 1: **passed** 2/2 (B was served N through C's retry's commit); 2: 2/2 | VerdictApplyTests `:195`, `:205` |
| `attemptFollowAfterVerdictDrop` | as above, after an attempt's verdict only | 2: 2/2 | VerdictApplyTests `:195` |
| `spaceFollowAfterVerdictDrop` | as above, after an ENOSPC's verdict only | 2: 2/2 | VerdictApplyTests `:205` |
| `endDeferralKeepsEnd` | the drain keeps the end after the verdict | 2: 2/2 | VerdictApplyTests `:195`, `:205` |
| `movesAfterVerdictInclusive` | `>=` for `>`: a move after a verdict with no apply since | 1: 2/2 | PublicationTests `:361` |
| `supersedeFailedDrop` | a failed job whose ids are all re-routed is not superseded | 1, 2, 4 (`c161818`): **passed** 2/2; 4 (`d3242d3`): 2/2 | VerdictApplyTests `:316`; `:325` after the 3-minute limit (below) |
| `laneAfterVerdictDrop` | `followedLane` ignores the moves after a verdict | 1: 2/2 | VerdictLaneTests `:131` |
| `answersResolveFalse` | a resolution answers nobody | 1: 2/2 | VerdictLaneTests `:133` |
| `answersThrottleFalse` | a 429 beyond the caps answers nobody | 1: 2/2 | VerdictLaneTests `:133` |
| `answersRetryFalse` | a retry at the cap answers nobody | 1: 2/2 | VerdictLaneTests `:133` |
| `answersRetryOwnPolicy` | the cap read on the background policy for every lane | 2: 2/2 | VerdictLaneTests `:133` |
| `laneVisitOwedDrop` | an owed visit's ids counted with no follow owed | 1: 2/2 | DrainLaneTests `:115` |
| `laneVerdictEpochDrop` | a waiting verdict of an earlier epoch counted | 2: **passed** 2/2 (the barrier suites, 112 tests) | Cost-only; the filters are removed (`e67f467`, below) |
| `laneJobsWalkAlways` | the walk also with no follow owed and no verdict waiting | 1: **passed** 2/2 (the 13 `barrierDecidesA429` tests) | Equivalent (below) |
| `spaceFailureEpochDropped` | the `.spaceFailure` replay without its epoch check | 1: 2/2 | SpaceEpochTests `:71` |

**Survivors and equivalents.**

- **`laneJobsWalkAlways` is equivalent** (S3-R19 item 2: it changes cost only). With the guard false, no follow is owed
  and no verdict waits. For every other job the walk then computes `visit = []` (the inner check), so no asset counts by
  the visit term, and `after` is `nil` (no verdict in `verdicts`), so none counts by the verdict term: `raise` is never
  called and the lane is the job's own interests' and the joins'. The walk's result with the guard false is nothing. The
  decision cycle 15's guard carried is the inner check, killed (`laneVisitOwedDrop`).
- **`verdictRerouteAlways` is killed in round 3.** Rounds 1 and 2's filters left out
  `barrierAnswersAPublicationFailedBeforeItsVisitAsPassed` (PublicationTests `:298`), whose publication ends with no
  apply since and whose verdict then defers, the one case the comparison decides; with it, round 3 failed `:301` 2/2.
- **`laneVerdictEpochDrop` was cost-only; the filters are removed** (`e67f467`; S3-R19 item 3, first option, and
  item 2's measure). A verdict waits with its job's epoch then (`defersFailure`, and `spaceFailed` after its epoch
  check), and a job of the same content gets a higher epoch only after the earlier one left or its verdict was given
  (`start` and job creation take `lastEpoch + 1`; no start runs behind the barrier). So by content the last verdict
  waiting is the current job's own when it has one. A current job with none waiting has no deferral on it: only
  `recordDeferredVerdict` sets one, always with its event, and the drain's `endDeferral` and `start` clear it. Then
  `movesAfterVerdict` is false and an earlier job's verdict adds nothing. What the filters changed is the guard: with
  only an earlier job's verdict waiting and no follow owed, the walk now runs and adds nothing.
- **`startEndResetDrop` and `startRerouteResetDrop` are checked by an invariant** (`e9960ef`; S3-R19 item 3, second
  option). No decision reads a value either reset clears. A start runs only from `pump`, never while the barrier holds
  or the drain runs, and only `followApplied` raises the barrier again, counting an apply. So a later comparison with a
  kept `failedAfter` sees a later count (`recordDeferredVerdict`, `rerouteOnVisit`). A kept set is overwritten by the
  next publication or deferral, or not read while `attemptEnd` is `nil`. The clause says what the resets keep: a job
  that downloads holds neither field. `barrierRetriesAFailedPublicationWithNothingOfItsEnd` (WindowTests `:189`, `:195`
  since `05f94cc`) exercises it: C's publication fails with no follow owed, its verdict is given at once, and its retry
  downloads. Both mutants fail `:217` (`:228` since `05f94cc`) 2/2. `attemptInvariantDrop` passes as expected: the
  clause checks a condition the resets keep.
- **`supersedeFailedDrop` is killed through a claim** (`d3242d3`). Without the branch the visit re-routes every interest
  one by one, and the last one's removal retires the job (`dropInterest`), as `supersede` removed it. The exception is a
  pending claim on the job's content: `removeInterest` then keeps the job (`claimHeld`). Rounds 1 and 2 had no claim.
  `c161818`'s test claimed the content but ended C in a 404, whose verdict removes the job anyway (`resolveAll`), so it
  passed. `d3242d3` ends C in a re-queue instead. Under the mutant, C was kept for the claim and re-queued by its
  verdict (`:316`), and zz-g's request was not answered within the 3-minute limit (`:273`, then `:325`). Visited first,
  C was superseded at the apply.

### Residual risks (cycle 16)

- **RR-11. `verdictAnswers` counts three partial answers as none.** An offline exit's fail-fast (`failFast`), a retry
  whose `Retry-After` exceeds the lane's cap (`Backoff.delay` gives none, `retryLater` answers), and an ENOSPC's verdict
  (`decideSpaceFailure`'s fail-fast) answer some interests the drain would otherwise move. `followedLane` counts them, so
  a 429 that arrives meanwhile may take the user lane's policy where a visit-first engine's took the job's own. Not
  probed.
- **RR-12. The move after a verdict runs at the verdict's place in the drain.** A visit-first engine gave the verdict at
  its arrival and moved the ids at the later apply's visit; events that arrived between the two met the ids not yet
  moved, and their replay now meets them moved. Not probed.
- **PROBE-C15R-AWAIT-WINDOW (the requirements verifier's) passed in both orders on `e64cdba`**
  (`.build-orchestrator/s3f-probes-c15/reqs/logs/window-{1,2}.log`: `✔ Test "PROBE-C15R-AWAIT-WINDOW" with 2 test
  cases passed`). Its reading "in the window" showed the verdict already waiting (`VerdictAfterFollow(epoch: 4,
  published: true)`, no unit held): the bulk executor did not hold the integrity record, which runs on the metadata
  executor. The correctness verifier's probe held it there (`correct-2`), which is fixed and tested.
- **`followedLane`'s C2 margin is unmeasured for cycle 16's walk** (S3-R19 item 2). Cycle 15 recorded the verifier's
  figure for cycle 14's walk (best 2.41–2.69 ms per call at 10,000 owed jobs, release). Per job the walk now adds
  `rerouteOnVisit` (a switch and two comparisons), `movesAfterVerdict` (one comparison) and a dictionary lookup, and per
  interest asset with a verdict waiting one `verdictAnswers` (constant time); it also runs while a verdict waits with no
  follow owed. No `followedLane` benchmark at 10,000 exists; none was added.
- RR-2, RR-4 and RR-10 stay analysed, not probed (S3-R19 item 4). P-13 is WP-B's (`other-wp:b`).

### Corrections to cycle 15's text

- **I12's "LaneTests' six"**: LaneTests has five `@Test` functions; one of them,
  `barrierDecidesA429WithoutAWaitingRequestThatDoesNotJoinIt`, is parameterized over `WaitingRequest`.
- **The `laneJoinTargetIgnored` and `laneJoinStillWantsIgnored` rows** cite LaneTests `:149`, `:150`. At `e64cdba` and
  at this cycle's commits those are LaneTests `:359`, `:360` (the parameterized test's two expectations), with
  PublicationTests `:107` (the `serverUnavailable` helper's `Issue.record`) for both.
- **`spaceFailureEpochDropped`**: the mutant does not "only write its `lastError`". A join replayed earlier in the same
  drain creates a new job for the same content, `queued`; without the check `decideSpaceFailure` judges it on the stale
  figures and parks it `insufficientSpace`, so the new user is not served (the verifiers' probe, now SpaceEpochTests).
  The check came in `02d51a0`, after `s3-base`, not before Stage 3.
- **`laneJobsWalkAlways`**: the barrier holds with no follow owed between two drain turns not only when more than 512
  events wait but also when an event that ends a batch (`conditions`, `readmit`, `unblock`, `throttleAnswers`,
  `spaceSweep`) waits before the last; the verifier's probe used two conditions elements. In cycle 15's code the mutant
  changed an answer (PROBE-C15R-LANE-WALK); cycle 16's restructuring makes it equivalent (above).

### The inventory, corrected (cycle 16)

These rows replace cycle 15's I8, I12 and its "New, `EngineFollow.follow`" row. Line numbers at `d3242d3`.

- **I8, `EngineDispatch.publicationFailed`.** Records the publication's end in its own turn (`recordPublicationEnd`),
  before the bookkeeping that awaits the store; nothing moves at the failure. Tests: cycle 15's, the two WindowTests,
  `barrierAnswersAPublicationFailedBeforeItsVisitAsPassed`, `barrierLeavesAPassedIdToAPublicationsSpaceRetry`. Mutants:
  `publicationEndDrop`, `inWindowCheckDrop`, `verdictRerouteAlways`.
- **I12, `EngineFailures.throttled`, `followedLane`, `verdictAnswers`.** A 429 behind the barrier is decided on the
  highest lane of: its own interests (less a waiting withdrawal's, and, when owed a visit, less those whose ids all
  moved); the interests other jobs' owed visits move onto it (a passing job's only in its re-route set), while a follow
  is owed; the interests the drain moves onto it after another job's waiting verdict, less those the verdict answers;
  the waiting joins. The job's own lane when none counts. Tests: cycle 13's to 15's, the five 429 tests of
  PublicationTests, LaneTests' five, VerdictLaneTests (four endings), DrainLaneTests. Mutants: the `followedLane` rows.
- **New, `EngineFollow.follow`, `rerouteOnVisit`, `recordDeferredVerdict`, `replayVerdict`, `replay(.spaceFailure)`,
  `followAfterVerdict`.** The visit meets the job as a visit-first engine's visit at its apply met it (above); the drain
  moves after a verdict the ids later applies moved. Tests and mutants: the table's, with
  `barrierSupersedesAFailedJobAClaimWouldKeep` (VerdictApplyTests `:274`) for the supersede of a passed failed job.
- **New, `invariantViolations()` (`e9960ef`).** A job that downloads holds no attempt end and no re-route set, which
  `start` resets. Test: `barrierRetriesAFailedPublicationWithNothingOfItsEnd` (WindowTests `:189`, `:195` since
  `05f94cc`). Mutants: `startEndResetDrop`, `startRerouteResetDrop`.

### Hang guards and re-entrancy

- The new tests use `.minutes(3)`, as the suite's do.
- No `await` was added in an actor: `git diff e64cdba..HEAD -- Sources | grep -c '^+.*await '` prints 0. So no
  `// REENTRANCY:` comment and no ledger row is proposed.
- 0 unsafe escapes (gate below).

## Cycle 17: the cycle-16 verifiers' findings

Cycle 17 applies the rulings to the cycle-16 verifiers' findings. From the requirements lens: `reqs-1` (WindowTests'
flake), `reqs-2` (RR-11's retry), `reqs-3` (the proposed document changes), `reqs-4` (two survivors) and `reqs-5`
(P-13). From the correctness lens: `correct-1` (an id mapped back), `correct-2` (RR-11's retry lane), `correct-3` (a
park's fail-fast), `correct-4` (the intermediate hop), `correct-5` to `correct-8` (other work packages' flakes, P-13,
P-11) and `correct-9` (`followedLane`'s C2). The six blocking ones (`reqs-1`, `reqs-2`, `correct-1` to `correct-4`) are
fixed. The work went in this order:

1. `05f94cc`: `reqs-1`'s fix, exactly the verifier's PROBE-C16R-RETRY-END-FIXED: C's first attempt is held until the
   engine's first conditions reading. No assertion changed. Three runs of the test passed
   (`.build-s3f/c17/flake-{1,2,3}.log`: `✔ Test run with 1 test in 1 suite passed after 0.332 seconds.`, then `0.331`
   and `0.319`). A scratch copy of its steps in 24 concurrent copies (`SCRATCH-C17-RETRY-END-STRESS`, not committed)
   passed 72 of 72 over three runs (`stress-{1,2,3}.log`: `✔ Test "SCRATCH-C17-RETRY-END-STRESS" with 24 test cases
   passed after 1.956 seconds.`, then `2.125` and `1.994`).
2. `5414df3`: the failing tests, committed on their own, each in both orders with `.timeLimit(.minutes(3))`, in the
   serialized `EngineFollowBarrierTests` suite:
   - VerdictLaneTests gains four endings: `retryAfterBeyondCap` (PROBE-C16R-RR11-RETRY-AFTER, and the case of
     PROBE-C16C-RR11-RETRY-LANE), `throttleFailFast` (PROBE-C16C-THROTTLE-FAILFAST-LANE), and `offline` and
     `insufficientSpace`, the two unprobed partial answers both lenses named. Every ending also asserts J's own
     throttle end and the answers of B and P.
   - The new `EngineFollowBarrierHopTests.swift` holds PROBE-C16C-VERDICT-MAPPED-BACK at both visit times and
     PROBE-C16C-INTERMEDIATE-HOP and -SERVED.
   - On `05f94cc`'s sources: `✘ Test run with 3 tests in 1 suite failed after 12.896 seconds with 15 issues.`
     (`failing-old2.log`). Every issue is sweep-first. VerdictLaneTests fails at `:204`, `:206` and `:211` for
     `retryAfterBeyondCap`, `offline` and `insufficientSpace`, and at `:206` and `:211` for `throttleFailFast`. HopTests
     fails at `:93` (both visit times), `:195` (the 404) and `:198` (the publication). The lines are `5414df3`'s.
3. `5843c41`: the fix (below). The three tests after it: `✔ Test run with 3 tests in 1 suite passed after 12.945
   seconds.` (`fixed2.log`). The Sync bundle: `✔ Test run with 530 tests in 53 suites passed after 112.803 seconds.`
   (`sync-1.log`).
4. `6d272ee`: `EngineFollowBarrierVerdictAnswersTests.swift`, G4 tests for the branches mutant round 1 left alive:
   `✔ Test run with 2 tests in 1 suite passed after 0.002 seconds.` (`va1.log`).
5. `214dbe3`: G4 scenarios for the rest of round 1's survivors: the ENOSPC variants and the passed holder (HopTests),
   and `EngineFollowBarrierMovedBeforeTests.swift`. Result: `✔ Test run with 6 tests in 1 suite passed after 13.875
   seconds.` (`newtests1.log`).
6. `fd6c0d7`: the two order-only placements round 1 showed alive, removed (S3-R16 item 3, below).
7. `edb1104`: `correct-9`'s C2 benchmark (`inboundWalkTurns`). The Sync bundle on this tree: `✔ Test run with 536 tests
   in 53 suites passed after 120.440 seconds.` (`sync-2.log`).
8. `346a8cb`: `bringInbound`'s doc comment states the C2 cost found while measuring (put to the orchestrator, below).
9. `5011067`: `reqs-4`'s second survivor, `deferralFollowOwedDrop`, is not equivalent (below). A new test pins the
   condition it drops, and `recordDeferredVerdict`'s doc comment says why the condition is needed. On the unmutated
   tree the test passed 10 of 10 runs (`ul-rep{1..10}.log`) and 72 of 72 copies in three runs of a scratch 24-copy
   stress, 12 copies per order (`ul-stress{1,2,3}.log`: `✔ Test run with 1 test in 1 suite passed after 2.166
   seconds.`, then `2.172` and `2.249`; not committed).
10. This draft.

### The findings

| Finding | Disposition |
|---|---|
| `reqs-1` (blocking): `barrierRetriesAFailedPublicationWithNothingOfItsEnd` flaky (PROBE-C16R-RETRY-END-STRESS, -DIAG) | **Fixed** in `05f94cc` as the finding's fix says (PROBE-C16R-RETRY-END-FIXED). C's script is `[.hold, .stage, .hold, .stage]`, and the test waits, driving the clock, for the first conditions reading before it releases C's first attempt. The cause was the setup's race with the first reading, not a product defect: a satisfied first reading is an edge for C's transient failure, which re-queued C, and the retry's start reset the end. No assertion changed; the doc comment says why. The test is now at WindowTests `:195` and its invariant expectation at `:228` (corrections below). Evidence above; both reset mutants still fail `:228` 2/2 (round 2) |
| `reqs-2` (blocking): PROBE-C16R-RR11-RETRY-AFTER; `correct-2` (blocking): PROBE-C16C-RR11-RETRY-LANE, seed 1_617_002 | **Fixed** in `5843c41`. `verdictAnswers` reads a retry through `retryDelay`, which `retryLater` now calls too. A `Retry-After` beyond the cap of the lane the job keeps after the count answers every interest. Tests: VerdictLaneTests' `retryAfterBeyondCap` (the shared scenario's seed, 1_616_802), and VerdictAnswersTests' "503 after 120 s" cases. RR-11 is rewritten below |
| `correct-3` (blocking): PROBE-C16C-THROTTLE-FAILFAST-LANE, seed 1_617_102, with the unprobed offline and ENOSPC fail-fasts (also named in `reqs-2` and `correct-2`) | **Fixed** in `5843c41`. `failFast`'s rule for one interest is now `failFastError`, which `verdictAnswers` reads for a 429's park, an offline exit that waits for the next edge, and an ENOSPC that parks for lack of space (`spaceVerdict`, which `decideSpaceFailure` now calls too). Tests: VerdictLaneTests' `throttleFailFast`, `offline` and `insufficientSpace`; VerdictAnswersTests. `.offline(requeue: true)` and `.requeue` stay no answer. **One deviation:** not every pause is no answer. `giveVerdict` replays a policy pause as a park when the job is below the user lane and its lane has a lane-wide block (`park` runs `failFast`, `EngineDispatch.swift:480`). So an offline block answers the job's waiters and ensures; counting it as none would keep RR-11's error for that verdict. Any other pause (a preemption, a policy block, the user lane) answers nobody. Pinned by VerdictAnswersTests' five pause expectations |
| `correct-1` (blocking): PROBE-C16C-VERDICT-MAPPED-BACK, seed 1_616_902 | **Fixed** in `5843c41`, by the finding's second option. The ids a visit-first engine had moved off a job before its verdict arrived are kept as `AttemptEnd.movedBefore`. The drain takes any of them still on the job off before the verdict and re-routes them after it (`takeOffMovedBefore`, `rerouteMovedBefore`, in `replayVerdict` and `.spaceFailure`'s replay). A visit that moves an interest onto a job whose verdict waits joins it behind that verdict (`addInterest`, `deferBehindVerdict`). Tests: `barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits` (HopTests `:146`, both visit times) and its ENOSPC variant (`:158`, seed 1_617_602). **"Do the same for a publishing job's set":** examined, and not done. A visit-first engine's visit at the apply that maps an id back to a publishing job joins it to the publication, whose outcome then answers it. So `recordDeferredVerdict` keeps, of a publication that ended with no apply since, its set less the ids the copy maps back to the job; taking those off would change the answer. Pinned by `barrierAnswersAnIDMovedBackDuringAPublicationWithItsOutcome` (MovedBeforeTests `:88`, seed 1_617_902) |
| `correct-4` (blocking): PROBE-C16C-INTERMEDIATE-HOP, seed 1_617_202, and -SERVED, seed 1_617_302 | **Fixed** in `5843c41`, by the finding's first option. When an attempt ends while a follow is owed, `bringInbound` brings onto its job the interests other jobs hold in ids the copy maps to its content and whose owed visits would move them. The attempt ends when its publication begins (`publish`) or its exit verdict defers (`defersFailure`, `spaceFailed`). Tests: `barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent` (HopTests `:292`: the 404, the publication and, from `214dbe3`, the ENOSPC park, seed 1_617_702) and `barrierLeavesAPassedPublicationsInterestToItsOutcome` (`:374`, seed 1_617_802: a holder the visit passes keeps its interest). The finding's content-to-ids lookup was not built: `bringInbound` walks the jobs' ids once (`inboundWalkTurns`). "In follow order" was later dropped as order only (`fd6c0d7`). S3F-5's sentence is corrected in place. The moves' own C2 cost is put to the orchestrator below |
| `reqs-3` (non-blocking): no "Cycle 16 adds:" | **Done**: "Cycle 16 adds:" and "Cycle 17 adds:" under "Proposed document changes" |
| `reqs-4` (non-blocking): `followAfterVerdictEpochDrop`, `deferralFollowOwedDrop` | `followAfterVerdict`'s epoch clause is **removed** in `5843c41` (S3-R16 item 3), on the verifier's argument: no verdict starts or creates a job in its own turn, and `follow` finds no job once the verdict ended it. `recordDeferredVerdict`'s `self.followOwed ?` condition is **not equivalent**, contrary to the finding's analysis: with no follow owed a job can hold an id the copy does not list at all (a waiter admitted from a newer manifest while an apply is in flight), and the filter counts it. **Kept, and pinned** in `5011067` by `barrierLeavesAnAdmittedUnlistedIDToTheVerdictThatWaits`, which kills the mutant 2/2 (under "Survivors and equivalents") |
| `reqs-5`, `correct-7` (non-blocking): P-13 (`BenchStorage.swift:249`) | **Routed**, WP-B's (`other-wp:b`; ADR-050, S3B-12). Not touched. This cycle's figure is under "Gate evidence (cycle 17)" |
| `correct-5` (non-blocking): `LoopbackHTTPServerTests.swift:400` over its limit | **Recorded**, WP-H's (`other-wp:h`, S3AH-5). In the verifier's coverage run 1 it failed after 75.950 s against 1 minute, at a 1-minute load of 587 to 778 (run mean 308.32, max 781.98) under two concurrent simulator runs. It passed alone at load about 51 in 0.056 s, and in the clean re-run (459/459, load mean 8.74). This cycle's gate script runs one thing at a time, with no simulator run beside a macOS run |
| `correct-6` (non-blocking): `SizeAndResumeTests.swift:164` (`pauseKeepsThePartial`, R-NET-8) | **Routed** to WP-D (`other-wp:d`) as a wait that depends on load. It failed at a 1-minute load of about 450 to 560 in the verifier's simulator run and passed alone in 0.768 s |
| `correct-8` (non-blocking): P-11 (`BenchSync.swift:103`, `latencySpeedup`) | **Recorded** as a miss that depends on load. The verifier's figures: 2 misses in 8 runs, 2.95 in the full run and 2.71, 3.20, 3.22, 3.48, 3.42, 3.43, 3.49 alone, against a minimum of 3.0; the spread is in the concurrency-1 baseline (2.78 to 3.55 s), and concurrency 5 stays at 1.01 to 1.04 s. This cycle's figures are under "Gate evidence (cycle 17)". No code on this path changed in cycles 16 and 17. The optional best-of-n baseline is not taken: it would change how a benchmark measures, not WP-F's code |
| `correct-9` (non-blocking): `followedLane`'s C2 at 10,000 unmeasured | **Measured** in `edb1104` by `inboundWalkTurns`: a 429's `followedLane` with 10,000 owed jobs and a verdict waiting, and the attempt's end turn that walks every job (`bringInbound`, nothing moved). Figures are under "Gate evidence (cycle 17)" |

### What cycle 17 changes (`5843c41`, `fd6c0d7`, `5011067`)

- **Whom a waiting verdict answers** (`verdictAnswers`, `EngineFailures.swift:829`). Each verdict is read through the
  function its replay acts on, so the two cannot part:
  - a resolution and a 429 beyond the caps answer every interest;
  - a retry answers those whose lane's cap the attempt reaches (`reachesCap`, which `countFailedAttempt` reads). It
    answers every interest when its `Retry-After`, read against the clock now as `retryLater` reads it, exceeds the
    cap of the lane the job keeps (`retryDelay`, new, which `retryLater` calls);
  - a 429's park, an offline exit that waits for the next edge, and a policy pause that parks on a lane-wide block
    answer what the park's fail-fast answers (`failFastError`, new, which `failFast` calls). A throttle's wait is read
    at the verdict's decision instant;
  - an ENOSPC (`spaceVerdict`, new, which `decideSpaceFailure` calls) answers those at their cap when it retries or
    waits for the store's reclaim, and those the fail-fast answers when it parks for lack of space;
  - a re-queue, an edge's fresh attempt and any other pause answer nobody.
- **The job the verdict meets** (`jobAtVerdict`, `:807`). `followedLane` reads the answers on the job less the
  interests a waiting withdrawal removes and those all of whose ids leave it before the verdict
  (`AttemptEnd.movedBefore`). So the lane `retryLater` keeps and the ENOSPC's room are read as the replay meets them.
  The interests that other visits or waiting joins add before the verdict are not counted (RR-13).
- **Ids moved off a job before its verdict** (`AttemptEnd.movedBefore`, new). `recordDeferredVerdict` keeps the set it
  records for the visit, which no visit spends. The drain takes any of its ids still on the job off before the
  verdict and re-routes them after it (`takeOffMovedBefore`, `rerouteMovedBefore`). A job left with no interest is
  retired before the verdict, as a visit-first engine's visit retired it. `followedLane` counts their interests on the
  content they move to (`EngineFailures.swift:761`).
- **A publication's set**, when the publication ended with no apply since, keeps only the ids the copy lists
  elsewhere. Those an apply moved back to the job while it published joined the publication on a visit-first engine,
  whose outcome answers them.
- **A visit's join onto a job whose verdict waits** waits behind that verdict (`addInterest`, `EngineJobs.swift:117`;
  `deferBehindVerdict`, `EngineFollow.swift:865`). The drain joins it to the job the verdict leaves, or to a new job of
  the content.
- **An attempt's end brings the interests a visit-first engine had moved onto it** (`bringInbound`,
  `EngineFollow.swift:898`). It is called from `defersFailure` (`:415`), `spaceFailed` (`EngineFailures.swift:569`) and
  `publish` (`EngineDispatch.swift:1017`). It brings the interests other jobs hold in ids the copy maps to the job's
  content, when their owed visits would move them (`rerouteOnVisit`: of a holder the visit passes, only its re-route
  set). Each holder moves under its visit's decision instant, and the joins are made at once
  (`EngineState.bringingInbound`). The attempt's end is the last instant those interests are the job's own: its
  publication binds the ids it holds when it begins, and its verdict answers or keeps the interests it holds when it
  defers.
- **`relane`'s guard** for a failed job whose verdict waits reads `Job.attemptEnd?.deferredAfter` instead of
  `verdictsAfterFollow` (`EngineJobs.swift:280`). An ENOSPC's deferral records its end on the job but sets no
  `verdictsAfterFollow` entry, so `bringInbound`'s user join onto a job whose ENOSPC verdict waited re-queued it and
  skipped the verdict (`relaneGuardRevert`, below).
- **Removed** (S3-R16 item 3): `followAfterVerdict`'s epoch clause (`5843c41`, `reqs-4`); in `fd6c0d7`, the skip in
  `deferBehindVerdict` past the joins already waiting behind the verdict, and `bringInbound`'s follow order. Their
  drop-mutants survived, and both are order only (RR-15).
- `5011067` changes only `recordDeferredVerdict`'s doc comment: with no follow owed its set is empty, even of an id
  the copy does not list (under "Survivors and equivalents").
- No `await` was added, and no test seam. No contract or public signature changed.

### Tests added (display names)

All in the serialized `EngineFollowBarrierTests` suite, each with `.timeLimit(.minutes(3))`; the scenario tests run in
both `LaneDropVisit` orders and expect the visit-first outcome in both.

- `EngineFollowBarrierHopTests.swift` (`5414df3`, `214dbe3`):
  - "R-SYN-4: an id an apply maps back to a content whose verdict waits joins it after the verdict (F-28)"
    (`barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits`, `:146`; both visit times; seed 1_616_902);
  - "R-SYN-4: an id an apply maps back to a content whose ENOSPC verdict waits joins it after the verdict (F-28)"
    (`:158`; seed 1_617_602);
  - "R-SYN-4: an interest an apply moved onto a content gets the outcome of the attempt that ends there, though a
    later apply moves it on (F-28)" (`:292`; the 404, seed 1_617_202; the publication, 1_617_302; the ENOSPC park,
    1_617_702);
  - "R-SYN-4: an interest a passed publication holds keeps that publication's outcome when the content its id moved to
    ends an attempt (F-28)" (`:374`; seed 1_617_802).
- `EngineFollowBarrierMovedBeforeTests.swift` (`214dbe3`):
  - "R-INT-3: an id an apply moves back while a publication runs gets the publication's outcome when its verdict waits
    (F-28)" (`:88`; seed 1_617_902);
  - "R-SYN-5: a 429 counts the interest the drain takes off a waiting verdict's job and re-routes onto it (F-28)"
    (`:228`; seed 1_618_002).
- `EngineFollowBarrierVerdictAnswersTests.swift` (`6d272ee`; white-box, no order):
  - "R-SYN-5: a waiting verdict answers in the 429's lane exactly the interests its replay answers (F-28)"
    (`verdictAnswersMirrorTheReplays`, `:122`: 49 expectations, each verdict and interest against what its replay does);
  - "R-SYN-5: a waiting verdict meets its job without the interests that leave it before the drain gives it (F-28)"
    (`verdictMeetsTheJobTheDrainLeavesIt`, `:135`).
- VerdictLaneTests' "R-SYN-5: a 429 counts the interest a waiting verdict leaves to move after it, not one it answers
  (F-28)" (`:199`): four endings added (16 cases).
- `EngineFollowBarrierUnlistedTests.swift` (`5011067`):
  - "R-CAR-2: an id admitted from a newer manifest stays on its job through a verdict that waits for the drain
    (F-28)" (`barrierLeavesAnAdmittedUnlistedIDToTheVerdictThatWaits`, `:28`; seed 1_618_102).
- `BenchSync`: "R-SYN-5: an attempt's end and a 429 while an owed follow covers 10,000 jobs hold the engine's actor at
  most C2's 10 ms per turn" (`inboundWalkTurns`, `edb1104`).

### Test changes (G3 one-to-one; S3-R16 item 4)

- `barrierRetriesAFailedPublicationWithNothingOfItsEnd` (WindowTests), a cycle-16 test: its setup now gates the first
  conditions reading (`05f94cc`, `reqs-1`'s fix), and no assertion changed. The script `[.stage(cBytes), .hold,
  .stage(cBytes)]` became `[.hold, .stage(cBytes), .hold, .stage(cBytes)]`, with a wait for the first reading and a
  release of C's first attempt. The doc comment says why.
- `barrierDecidesA429OnTheLaneAWaitingVerdictLeaves` (VerdictLaneTests), a cycle-16 test, gains the four endings
  above. `verdictLane` now returns a `VerdictLaneOutcome` instead of a `Bool`. The two existing expectations keep their
  conditions and messages; they read `outcome.throttled` where they read `throttled`. Added for every ending: J's own
  throttle end (`throttledByJ`), B answered, and P's answer.
- Cycle 17's own tests changed before this draft (`214dbe3`). `mappedBack` takes an ending (the ENOSPC variant),
  `HopEnding` gains `insufficientSpace`, and one setup `#require` message reads "at its attempt's end" for "at its 404"
  (its condition is unchanged).

### Mutants (S3-R16 1(e))

Setup: `.build-s3f/c17/mut.py` and `mut2.py` (cycle 16's runner) copy `Package.swift`, `Sources/` and `Tests/` into
`.build-s3f/mutsrc` and apply each edit with a count check. They build in `.build-s3f/mutbuild` and run the mutant's
filter: twice when it fails, else the Sync bundle once (twice if that fails). Then they revert and diff the copy's
`Sources/` against the worktree; both rounds printed `revert diff: none`. Round 1 (`mut.out`, `mut/`) ran on `5843c41`'s
tree, round 2 (`mut2.out`, `mut2/`) on `edb1104`'s. Round 3 ran the one mutant `deferralFollowOwedDrop` the same way by
hand, with the same revert check, on `346a8cb`'s sources with the new test (`ul-mut-run{1,2}.log`). Every scenario
failure is sweep-first; VerdictAnswersTests have no order. Lines are each round's tree's.

| Mutant | Branch | Result | Killed by |
|---|---|---|---|
| `vaRetryAfterDrop` | a retry never answers by its `Retry-After` | 1: 2/2 | VerdictLaneTests `:204`, `:206`, `:211` (`retryAfterBeyondCap`) |
| `vaKeptLane` | the `Retry-After` cap read on the interest's lane, not the lane the job keeps | 1: **passed** (filter and bundle); 2: 2/2 | VerdictAnswersTests `:126` |
| `vaThrottleUntilDrop` | a 429's park answers nobody | 1: 2/2 | VerdictLaneTests `:206`, `:211` (`throttleFailFast`) |
| `vaOfflineDrop` | an offline exit answers nobody | 1: 2/2 | VerdictLaneTests `:204`, `:206`, `:211` (`offline`) |
| `vaOfflineRequeueDrop` | an edge's fresh attempt answers as a wait for the edge | 1: **passed**; 2: 2/2 | VerdictAnswersTests `:126` |
| `vaPauseDrop` | a pause answers nobody | 1: **passed**; 2: 2/2 | VerdictAnswersTests `:126` |
| `vaPausePolicyDrop` | a preemption pause answers as a policy pause | 1: **passed**; 2: 2/2 | VerdictAnswersTests `:126` |
| `vaPauseLaneDrop` | the pause's user-lane check dropped | 1, 2: **passed** (filter and bundle) | Equivalent (below) |
| `vaSpaceCapDrop` | an ENOSPC that retries or waits answers nobody at the cap | 1: **passed**; 2: 2/2 | VerdictAnswersTests `:126` |
| `vaSpaceInsufficientDrop` | an ENOSPC park answers nobody | 1: 2/2 | VerdictLaneTests `:204`, `:206`, `:211` (`insufficientSpace`) |
| `javWithdrawnDrop` | the verdict's job keeps a waiting withdrawal's interest | 1: **passed**; 2: 2/2 | VerdictAnswersTests `:164` |
| `javMovedBeforeDrop` | the verdict's job keeps the interests that leave before it | 1: **passed**; 2: 2/2 | VerdictAnswersTests `:163`, `:164` |
| `flMovedBeforeDrop` | `followedLane` ignores the ids the drain takes off before a verdict | 1: **passed**; 2: 2/2 | MovedBeforeTests `:230`; PublicationTests `:107` (the `expectServerUnavailable` helper) |
| `spaceBringInboundDrop` | `spaceFailed`'s deferral brings nothing | 1: **passed**; 2: 2/2 | HopTests `:30` (the `expectInsufficientSpace` helper, `insufficientSpace` ending) |
| `takeOffSpaceDrop` | the `.spaceFailure` replay takes nothing off | 1: **passed**; 2: 2/2 | HopTests `:161` |
| `takeOffVerdictDrop` | `replayVerdict` takes nothing off | 1: 2/2 | HopTests `:93` (after the verdict) |
| `deferBringInboundDrop` | `defersFailure` brings nothing | 1: 2/2 | HopTests `:195` (the 404) |
| `movedBeforeRecomputeDrop` | a deferral records no ids moved before it | 1: 2/2 | HopTests `:93` (after the verdict) |
| `movedBeforeKeptDrop` | a publication that ended with no apply since keeps no set | 1: filter passed; bundle 2/2 | ReachTests `:210` |
| `movedBeforeKeptNoIntersect` | the same publication keeps its whole set, ids moved back included | 1: **passed**; 2: 2/2 | MovedBeforeTests `:91` |
| `bringInboundVisitFilterDrop` | `bringInbound` brings a passed holder's other ids too | 1: **passed**; 2: 2/2 | HopTests `:378` |
| `deferBehindJoinSkipDrop` | `deferBehindVerdict` places the join before the joins already behind the verdict | 1: **passed** | Removed, order only (`fd6c0d7`) |
| `bringInboundOrderDrop` | `bringInbound` takes no holder in follow order | 1: **passed** | Removed, order only (`fd6c0d7`) |
| `publishBringInboundDrop` | `publish` brings nothing | 1: 2/2 | HopTests `:198` (the publication) |
| `rule3Drop` | a visit's join onto a job whose verdict waits joins at once | 1: 2/2 | HopTests `:93` (before the verdict) |
| `rule3BringingDrop` | `bringInbound`'s joins wait behind the verdict too | 1: 2/2 | HopTests `:195` (the 404) |
| `rule3InFollowVisitDrop` | every join onto such a job waits, outside a visit too | 1: filter passed; bundle 2/2 | AnswerTests `:537`; PublicationTests `:107`; VerdictLaneTests `:207` |
| `relaneGuardRevert` | `relane`'s guard reads `verdictsAfterFollow` again | 1: **passed**; 2: 2/2 | HopTests `:30` (`insufficientSpace` ending) |
| `startEndResetDrop` | `start` keeps the last attempt's end | 2: 2/2 | WindowTests `:228` |
| `startRerouteResetDrop` | `start` keeps the last publication's re-route set | 2: 2/2 | WindowTests `:228` |
| `attemptInvariantDrop` | the `e9960ef` clause dropped | 2: **passed** (filter and bundle) | Expected (cycle 16) |
| `deferralFollowOwedDrop` | a deferral with no follow owed records the ids the copy lists elsewhere or not at all | 3: 2/2 | UnlistedTests `:104`, `:110` |

**Survivors and equivalents.**

- **`vaPauseLaneDrop` is equivalent.** A pause's lane-wide blocks are built only for the prefetch and bulk lanes
  (`EngineFailures.swift:30`). For a job on the user lane `blocks.first(where:)` finds none, so the guard fails with or
  without the check. `giveVerdict`'s `.pause` case carries the same check, and `verdictAnswers` keeps it as the mirror
  of the replay's condition.
- **`attemptInvariantDrop`** passes, as in cycle 16: the clause checks a condition the resets keep.
- **`deferBehindJoinSkipDrop` and `bringInboundOrderDrop` are order only; the code is removed** (`fd6c0d7`, S3-R16
  item 3). The joins `deferBehindVerdict` places all join one content after the verdict, and `bringInbound`'s holders
  all join the one ending job. Their order changes the order of the joins and of any re-lane they cause, not an answer:
  the job is failed with its verdict waiting, or publishing, so no join is answered by a fail-fast or admitted before
  the drain, and the drain gives the verdict to all of them at once. The difference is RR-15.
- **`followAfterVerdictEpochDrop`** (`reqs-4`): the clause is removed in `5843c41`, not tested.
- **`deferralFollowOwedDrop`** (`reqs-4`: `recordDeferredVerdict` computes its set whether or not a follow is owed)
  **is not equivalent; a new test kills it** (`5011067`). This draft's first version argued equivalence as the
  verifier did, and missed a case: the filter counts an id the copy does not list at all, not only one it lists
  elsewhere, and with no follow owed a job can hold such an id.
  - **How.** A waiter for an id the copy does not list is admitted from the manifest its fetch returns
    (`EngineManifest.join`). While an `apply` is in flight `followStoreView` refuses the store's view, so the copy
    lists the id only once that apply is followed. Behind the barrier the join waits, and the drain makes it after the
    follow has ended, so no visit moves the id. If the job's attempt then ends while events still wait, its verdict
    defers with no follow owed.
  - **The difference.** The mutant records the id as moved before the verdict. The drain takes it off before the
    verdict and re-routes it after it, to a copy that does not list it: `notFound` for an id a newer manifest lists
    (R-CAR-2). Visited first, the 503's retry kept the waiter, and the job's second attempt served it.
  - **The test** builds exactly that (seed 1_618_102). With the mutant it fails sweep-first in 2 of 2 runs, at `:104`
    (`(xHoldsU: false, uWaits: false)`) and `:110` (`failure(ZTronAssetModel.AssetError.notFound)`). In one scratch
    24-copy stress run with the mutant, all 12 sweep-first copies failed at both lines and the 12 visit-first copies
    passed (`ul-mstress.log`).

### Residual risks (cycle 17)

- **RR-11, rewritten.** Cycle 16's RR-11 (three partial answers counted as none) is closed. `verdictAnswers` reads
  each verdict through its replay's own function (above), pinned by VerdictLaneTests' four endings and
  VerdictAnswersTests' 49 expectations. What remains of it is RR-13.
- **RR-12** stands as cycle 16 wrote it (not probed).
- **RR-13. `jobAtVerdict` leaves out the interests that other visits or waiting joins add before the verdict.** They
  change only the lane `retryLater`'s policy and an ENOSPC's room are read on, and only when none of the job's own
  interests is user-initiated. So they change whom the verdict answers among non-user interests only. Such an
  interest decides another job's 429 policy only when nothing else counts and that job's own lane is the user's. Not
  probed.
- **RR-14. An interest moved onto a publishing job's content by one apply and on by the next, while the publication
  runs, skips that publication's failure.** `bringInbound` runs when a publication begins and when its verdict defers,
  each against the copy at that moment. A visit-first engine's visit at the first apply joined the interest to the
  publication, the second apply's visit passed it, and the publication's failure answered it. Behind the barrier the
  owed visit compares with the second apply's copy and moves the interest to the third content. When the failure
  answers (an integrity failure at the cap, a park's fail-fast), that is an answer difference (S3-R16 1(a)) by
  analysis. Not probed; put to the orchestrator below.
- **RR-15. Order only (S3-R16 item 2).** A visit's join behind a waiting verdict is placed right behind the verdict,
  before every event that arrived after it (joins included). `bringInbound` takes its holders by transfer, not in
  follow order (`fd6c0d7`). A visit-first engine made those joins at each apply's instant, in follow order. Not probed.

### Put to the orchestrator (found while fixing; not changed this cycle)

1. **C2 in the concentration shape (S3-R5, S3-R16 1(f)).** When thousands of ids converge on one content in one apply
   while that content's attempt ends behind the barrier, `bringInbound` moves every holder in the attempt's end turn.
   - **The measurement.** A scratch release run (`.build-s3f/c17/conc/ScratchC17.swift.txt`, run in the mutation copy
     of `edb1104`'s tree; not committed; logs in `.build-s3f/c17/conc/`) used a 10,000-member prefetch group whose v3
     maps every member to O's content. The follow was held after its first turn, and O's 404 then deferred.
   - **The 404's turn** held the actor 396.73, 395.74 and 399.80 ms while it brought 9,744 holders onto O's job (`O ids
     257 -> 10001`). It took 8.02 ms at 1,000 members. The 1-minute load was 16 to 19.
   - **The same shape without the 404**, its follow stepped one turn at a time: 39 turns, with a longest turn of 17.67
     and 18.30 ms, a median of 9.71 and 9.88 ms, and first turns of 4.1 to 5.4 ms.
   - **The costs.** Each join copies the job's and the interest's id sets: `addInterest` mutates a copy of the `Job`,
     Stage 2's join, and the copy grows with the job. Each holder's move also supersedes it, about 16 µs a holder in
     the follow's first turns, while the job is small. So the follow's own turns, bounded at 256 visits, exceed C2 in
     this shape too (since S3F-5's bounded follow), and `bringInbound`'s turn is unbounded.
   - **The common shape** is within C2 (`inboundWalkTurns`, under "Gate evidence (cycle 17)").
   - **Options, none taken.** (a) Bound `bringInbound`: record the inbound ids and their target at the attempt's end,
     and move them in the follow's turns, before any other visit, to the recorded target. The publication would then
     have to bind recorded ids it does not yet hold, and `followedLane` would have to count them as the target's. (b)
     Join in place (`self.state.jobs[transfer]?…`, with no `Job` copy alive). That removes the copies, so the follow's
     turns would cost about what its first turns cost (an estimate). It leaves `bringInbound` at about 16 µs a holder
     (about 160 ms at 10,000, an estimate). (c) Rule the shape outside C2's reference set. Option (a) is new machinery
     of the kind S3-R16 warns about; option (b) alone does not meet C2 for `bringInbound`.
2. **RR-14** (above). A fix would bring the inbound ids onto each publishing job at each apply made while a follow is
   owed, under the outgoing copy. That costs another walk per apply (about 3.6 ms at 10,000, `inboundWalkTurns`' figure
   for one walk) and the same moves as item 1.

3. **An admission racing an apply that omits the id answers `notFound` (PROBE-C17-ADMIT-DURING-APPLY).** Found while
   writing `5011067`'s test; it predates s3-base and no barrier is involved.
   - **The case.** A waiter for an id the copy does not list is admitted from the manifest its fetch returns
     (`EngineManifest.join`). While an `apply` of an older manifest that omits the id is in flight, the engine refuses
     the store's view (`followStoreView`), so the job holds an id its copy does not list. That apply's follow then
     visits the job: `follow`'s filter counts the id as moved, and `reroute` answers the waiter `notFound`, since the
     copy does not list it. The store lists the id (the admission), and the catch-up the refused view owed adopts it
     just after.
   - **The probe** (`.build-s3f/c17/ScratchC17AdmitDuringApply.swift.txt`; run in the mutation copy, not committed;
     seed 1_618_202) failed 2 of 2 runs: `(xHoldsU: false, copyListsU: true), storeListsU: true; U:
     failure(ZTronAssetModel.AssetError.notFound)`. X's own waiter was served. A visit-first engine answers the same,
     so this is no sweep-first difference. Both rules predate s3-base: the visit's filter is s3-base's `followApplied`
     (`EngineRuns.swift:430`), and the refused view is `5a53605`.
   - **When.** The server adds the id between a run's fetch and the refetch, and the admission lands while that run's
     apply is in flight.
   - **Options, none taken.** (a) While a catch-up is owed (`catchUpAfterFailedApply`), a visit leaves an id the copy
     does not list, and the catch-up's follow decides it. (b) The admission records the ids it joined unlisted, and a
     visit moves only the ids the copy pruned. Either changes what a visit moves, outside the cycle-16 findings.

### Corrections to cycle 16's text

- **WindowTests' lines** moved with `05f94cc`. The cycle-16 rows and paragraphs cite `:189` (the test) and `:217`
  (its invariant expectation); since `05f94cc` those are `:195` and `:228`. Corrected in place, citing both.
- **RR-11** is replaced by cycle 17's (above).
- **The cycle-16 mutant table** has no row for the verifier's `followAfterVerdictEpochDrop` and
  `deferralFollowOwedDrop`. The first is under "Survivors and equivalents" above; the second has a row in cycle 17's
  table.
- **S3F-5's "two applies in a row are followed exactly"** is wrong. A visit owed for an earlier apply compares with the
  later apply's copy, so an id both applies move skips the first one's content (PROBE-C16C-INTERMEDIATE-HOP).
  Corrected in place.

### The inventory, corrected (cycle 17)

These rows replace cycle 16's I12 and its "New, `EngineFollow.follow`…" row, and add four. Line numbers are at
`5011067`.

- **I12, `EngineFailures.throttled`, `followedLane`, `verdictAnswers`, `jobAtVerdict`.** A 429 behind the barrier is
  decided on the highest lane of:
  - its own interests (less a waiting withdrawal's, and, when owed a visit, less those whose ids all moved);
  - the interests other jobs' owed visits move onto it (a passing job's only in its re-route set), while a follow is
    owed;
  - of a job whose verdict waits, the interests in ids its visits had moved off before the verdict
    (`AttemptEnd.movedBefore`);
  - the interests the drain moves onto it after another job's waiting verdict, less those the verdict's replay answers
    on the job it meets;
  - the waiting joins.

  The job's own lane when none counts. Tests: cycle 13's to 16's, VerdictLaneTests (eight endings), MovedBeforeTests'
  lane test, VerdictAnswersTests. Mutants: the `va*`, `jav*` and `flMovedBeforeDrop` rows, and cycle 16's
  `followedLane` rows.
- **`EngineFollow.follow`, `rerouteOnVisit`, `recordDeferredVerdict`, `replayVerdict`, `replay(.spaceFailure)`,
  `followAfterVerdict`** (cycle 16's row). Added: the deferral keeps `AttemptEnd.movedBefore`, and the drain takes
  those ids off before the verdict and re-routes them after it (`takeOffMovedBefore` `:500`, `rerouteMovedBefore`
  `:521`). Tests: cycle 16's, HopTests' mapped-back tests, MovedBeforeTests' publication test, UnlistedTests (no follow
  owed). Mutants: `takeOff*`, `movedBefore*`, `deferralFollowOwedDrop`.
- **New, `addInterest`'s join behind a waiting verdict, and `deferBehindVerdict`** (`EngineJobs.swift:117`,
  `EngineFollow.swift:865`). Test: `barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits` (its case before the verdict).
  Mutants: `rule3*`.
- **New, `bringInbound`** (`EngineFollow.swift:898`, called from `defersFailure`, `spaceFailed` and `publish`). Tests:
  `barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent` (three endings),
  `barrierLeavesAPassedPublicationsInterestToItsOutcome`. Mutants: `deferBringInboundDrop`, `spaceBringInboundDrop`,
  `publishBringInboundDrop`, `bringInboundVisitFilterDrop`. C2: `inboundWalkTurns`; the concentration shape is put to
  the orchestrator.
- **New, `relane`'s guard on `Job.attemptEnd`** (`EngineJobs.swift:280`). Test: the hop test's `insufficientSpace`
  ending. Mutant: `relaneGuardRevert`.
- **New, the shared predicates**: `retryDelay` (`EngineFailures.swift:643`, used by `retryLater`), `failFastError`
  (`EngineJobs.swift:665`, used by `failFast`), `spaceVerdict` (`EngineFailures.swift:620`, used by
  `decideSpaceFailure`) and `reachesCap` (`:634`, used by `countFailedAttempt` and `claimRetries`). Each replay and
  `verdictAnswers` read the same function. Tests: the replays' existing tests and VerdictAnswersTests.

### Hang guards and re-entrancy

- The new tests use `.minutes(3)`, as the suite's do.
- No `await` was added in an actor: `git diff d3242d3..5011067 -- Sources | grep -c '^+.*await '` prints 0. So no
  `// REENTRANCY:` comment and no ledger row is proposed.
- 0 unsafe escapes (gate below).

## Cycle 18: the cycle-17 verifiers' findings, and S3-R20 and S3-R21

Cycle 18 applies S3-R20 and S3-R21 to the cycle-17 verifiers' findings. From the requirements lens: `reqs-1` (a
`Retry-After` date read at the drain), `reqs-2` (RR-14), `reqs-3` (`bringInbound`'s C2), `reqs-4` (the follow's own
turns), `reqs-5` (`bringInbound`'s doc premise) and `reqs-6` (P-2, P-5, P-6, P-13). From the correctness lens:
`correct-1` (S3-R20 neither applied nor recorded), `correct-2` (the follow's own turns), `correct-3` (RR-14),
`correct-4` (the narrowed re-route's test) and `correct-5` (three drop-mutants). The nine blocking ones are fixed. The
work went in this order:

1. `d788d75`: the failing tests, committed on their own (P3), each scenario in both orders with
   `.timeLimit(.minutes(3))` in the serialized `EngineFollowBarrierTests` suite:
   - the new `EngineFollowBarrierPublicationHopTests.swift` holds both verifiers' RR-14 probes as one test with two
     shapes: PROBE-C17R-RR14-PUBLICATION-HOP (seed 1_717_002, a 16-byte publisher, `smallPublisher`) and
     PROBE-C17C-RR14-PUBLICATION-HOP (seed 1_717_302, a 100 kB publisher, `largePublisher`);
   - RetryTests gains PROBE-C17C-RETRY-AFTER-DATE (seed 1_717_102);
   - BenchSync gains the three concentration cases S3-R20 item 2 and S3-R21 item 1 ask for.

   On `e1cf3e5`'s sources: `✘ Test run with 2 tests in 1 suite failed after 2.886 seconds with 4 issues.`
   (`.build-s3f/c18/fail-first.log`). Every issue is sweep-first: PublicationHopTests `:118` (both shapes), RetryTests
   `:222` (B not answered `serverUnavailable(31)`: C's retry served it) and `:223` (two starts of C). The benchmarks,
   release, in a copy of `e1cf3e5`'s sources (`.build-s3f/c18/headbench.log`, 1-minute load 10.83): the 404's turn
   [393.91, 394.76, 394.21] ms, the publication's [403.53, 400.95, 405.38] ms, the follow's own turns [17.49, 17.56,
   17.50] ms (39 held turns, median 9.82 ms). Best of three: 393.91, 400.95 and 17.49 ms against C2's 10 ms.
2. `c4dda13`: `reqs-1`'s fix (below).
3. `2aa5a67`: the in-place join (S3-R21 item 1).
4. `b9c0513`: the moves over the follow's turns (S3-R20) and RR-14's fix (S3-R21 item 4).
5. `bfb1c70`, `f662510`, `165ccdd`: the tests `correct-4` and `correct-5` ask for, one commit each.
6. `deb5c9d`: the convergence test, the moves' answers at 400 holders in both orders.
7. `70e0801`: the benchmarks' final shape: the ending's own turn and the held turns timed apart, and the walk an apply
   makes for the publications in flight.
8. `640ac96`: `reqs-5`'s doc correction (a doc comment only).
9. `c0bbe09` and `4fb1375`: the tests the mutant pass asked for (under "Mutants"): `catchUpWalkDrop`,
   `inboundHolderWaitDrop` and `vaWallDrop` survived the Sync bundle in its first round (`70e0801`'s tree, whose code
   is `640ac96`'s). Tests only.
10. This draft.

The Sync bundle on `70e0801`'s sources before the gate runs: `✔ Test run with 541 tests in 53 suites passed after
123.145 seconds.` (`.build-s3f/c18/sync3.log`).

### The findings

| Finding | Disposition |
|---|---|
| `reqs-1` (blocking): PROBE-C17C-RETRY-AFTER-DATE, seed 1_717_102: a deferred retry reads its `Retry-After` date against the clock at the drain | **Fixed** in `c4dda13`, by the finding's first option. `retryLater` reads the wall clock before `defersFailure`, and the deferred verdict carries it (`AttemptVerdict.retry(_:answer:wall:)`, `EngineFollow.swift:1353`). The replay (`giveVerdict`) and `verdictAnswers` (`EngineFailures.swift:855`) read the date against it. Test: `barrierReadsARetryAfterDateAtItsArrival` (RetryTests `:184`; B gets `serverUnavailable`, C starts once). VerdictAnswersTests construct the verdict with `wall:` (below). Mutants: `retryAfterWallDrop`, and `vaWallDrop`, killed by VerdictLaneTests' `retryAfterDateLater` ending (`4fb1375`) |
| `reqs-2` (blocking): PROBE-C17C-RR14-PUBLICATION-HOP, seed 1_717_302; `correct-3` (blocking): PROBE-C17R-RR14-PUBLICATION-HOP, seed 1_717_002 | **Fixed** in `b9c0513`, by the findings' first option: at each apply made while a follow is owed, before the copy changes, `bringInboundOntoPublications` (`EngineFollow.swift:948`; called from `applied`, `EngineRuns.swift:368`, and `followStoreView`, `EngineCatchUp.swift:222`) records the moves the outgoing copy owes onto every job whose publication runs, with S3-R20's bound. **One deviation:** the reqs finding also names "the failed jobs whose verdict waits". They are left out: a visit-first engine gave that verdict when the attempt ended, before the apply, so its visit at the apply joined the interest after the verdict, which is what cycle 17's join behind a waiting verdict does (`addInterest`'s rule 3); brought onto the job, the verdict would answer it. Tests: `barrierGivesAnInterestMovedOntoAPublicationItsOutcome` (PublicationHopTests `:197`, both shapes), its catch-up variant (`:208`, `c0bbe09`), and the convergence test's `publicationApply` ending at 400 holders. C2: `publicationApplyTurns`. Mutants: `applyWalkDrop`, `catchUpWalkDrop`. An apply inside a failed publication's bookkeeping await is not covered (RR-18, below) |
| `reqs-3`, `correct-1` (blocking): `bringInbound` moves every holder in the attempt-end turn (S3-R20); S3-R20 not recorded | **Fixed** in `b9c0513`, as S3-R20 item 3's example says (below). S3-R20 and S3-R21 are recorded under "Orchestrator rulings (close-out)". The longest actor waits at 10,000 converging ids, best of three, fall from 393.91 ms (the 404) and 400.95 ms (the publication) to 6.23 and 5.45 ms (under "Gate evidence (cycle 18)"). Tests: the convergence test; cycle 17's hop tests unchanged. C2: `concentrationNotFoundTurns`, `concentrationPublicationTurns` (the moves), `inboundWalkTurns` (the walk). Mutants: the `inbound*` and `publishInboundWaitDrop` rows; `inboundHolderWaitDrop` is killed by PublicationHopTests' mapped-back test (`:221`, `c0bbe09`) |
| `reqs-4`, `correct-2` (blocking): the follow's own turns 17.7 to 19.1 ms in the concentration shape (S3-R21 item 1) | **Fixed** in `2aa5a67` by option (b): `addInterest` joins in the table, with no live copy of the `Job` or the `JobInterest` (`EngineJobs.swift:160`), so a join is O(1) amortised. The follow's held turns fall from 17.49 ms to 3.84 ms, best of three (under "Gate evidence (cycle 18)"), with no further bound (option (a) not needed). A turn that passes stale entries of the follow's order is also bounded (`followSkipsPerTurn`, below). C2: `concentrationFollowTurns` |
| `correct-4` (blocking): no test kills `rerouteOnPassKeepWhole` (PROBE-C17R-NARROWED-REROUTE, seed 1_717_102) | **Fixed** in `bfb1c70`: the probe is committed as `barrierAnswersAnIDMovedBackAndAwayAgainWithThePublicationsOutcome` (MovedBeforeTests `:103`, both orders), next to `publicationMappedBack`. The mutant fails it 2/2 at `:170` (table below) |
| `correct-5` (blocking): `vaStampDrop`, `bringInboundStampDrop` and `takeOffAssetsKeep` survive the Sync bundle | `vaStampDrop`: **killed** by VerdictLaneTests' new `throttleFailFastLater` ending (`165ccdd`), which advances the clock 9 s between O's verdict and v4, so a fail-fast read at the drain's instant instead of the verdict's stamp answers otherwise. `takeOffAssetsKeep`: **killed** by the mapped-back tests' event checks (`f662510`): C's 404 reports zz-a failed and not zz-b. `bringInboundStampDrop`: the code is **removed** (S3-R19 item 3); the moves read no world view (argument under "Mutants") |
| `reqs-5` (non-blocking): `bringInbound`'s doc premise; PROBE-C17C-INBOUND-SUPERSEDED (seed 1_717_002), its CONTROL and CONSISTENT (seed 1_717_022) | **Recorded** as RR-16 under "Residual risks (S3-R16; cycle 18)". The doc comment is **corrected** in `640ac96`: a holder's interest goes onto this job, or, when the job's own owed visit comes first and supersedes it, a visit-first engine gave it a fresh job of the content; the answers agree while the origin answers both requests alike, and the requests differ by one. The optional skip is not taken |
| `reqs-6` (non-blocking): StorageBenchmarks P-2, P-5, P-6, P-13 during a load spike | **Routed**, WP-B's (`other-wp:b`). No WP-F change. In this cycle's run P-13 failed again (unit max 5.36 ms against 5.0 ms; under "Gate evidence (cycle 18)") |

### What cycle 18 changes (`c4dda13`, `2aa5a67`, `b9c0513`, `640ac96`)

- **A `Retry-After` date is read at the response's arrival** (`retryLater`, `EngineFailures.swift:244`). The wall clock
  is read before the verdict may defer and travels with it (`AttemptVerdict.retry`'s `wall`). `giveVerdict` passes it
  back to `retryLater`, and `verdictAnswers` reads `retryDelay` against it. A date 31 s ahead at the arrival, read at
  the drain 5 s later, was 26 s ahead: within the 30 s cap that the visit-first answer exceeded.
- **A join writes into the table** (`addInterest`, `EngineJobs.swift:108`). The cycle-17 join mutated a copy of the
  `Job` and wrote it back, so each insertion copied the growing id sets of the job and the interest. The join now
  reads what it needs into constants, then inserts through `self.state.jobs[transfer]?`.
- **The moves an attempt's end owes are recorded, then made over the follow's turns** (S3-R20):
  - **The walk** (`findInbound`, `EngineFollow.swift:975`, and `foundInbound`, `:1010`) is cycle 17's pass over every
    job's ids, with one lookup in the copy each. It now records one move per holder and target
    (`EngineState.inboundMoves`; `InboundMove`, `EngineState.swift:613`): the target's transfer and epoch, the holder,
    the ids, and the copy the walk read. The moves are sorted by keys of plain integers (the holder's `Job.epoch`, the
    target's epoch, an index), so the sort moves no id set (the first sort, of tuples carrying the sets, cost about
    3.7 ms at 10,000 in a profile copy). `inboundOnto` counts the owed moves onto each target, once per walk. Ids an
    owed move already carries are not recorded again (`inboundPendingIDs`, `:1060`).
  - **The moves.** `bringInbound` (`:928`) makes the first `inboundMovesNow` (64) in the attempt's end turn
    (`makeInboundNow`, `:1090`). The follow's turns make the rest before any visit (`continueFollow`, `:111`;
    `continueInbound`, `:1113`). Moves and visits share a turn's `followsPerTurn` (256): a turn that leaves a move owed
    visits nothing, so no visit runs before a move it follows on a visit-first engine. A move re-checks its target
    (`inboundTargetWaits`, `:1146`: the same epoch, publishing, or failed with its end recorded) and moves the ids the
    holder still holds, under the copy that found them (`move(_:of:listing:)`, `:856`; `supersede` and `reroute` take
    the `listing`). A move onto a target that has ended is dropped; the holder's own visit then moves the ids.
  - **The barrier.** While a move is owed, the follow is owed (`followOwed` includes `inboundOwed`), so every later
    event waits as it waits for an owed visit, and the job's verdict waits in `verdictsAfterFollow` as before.
  - **The publication waits.** A publication binds its ids only once no move onto or off its job is owed
    (`inboundBlocks`, `:1076`; `publish`, `EngineDispatch.swift:1031`). It waits in `awaitInboundMoves` (`:1175`),
    resumed by the last such move (`inboundMade`, `:1162`) or by shutdown (`releaseInboundWaits`, `:1192`, from
    `drainEverything`). After the wait, `publish` re-checks the lifecycle and the job's epoch and state, and a job
    retired or replaced meanwhile gets the retired publication's exit, the file discarded. **REENTRANCY RE-S48
    (proposed)**, the one new `await` in the actor.
  - **The lane.** `followedLane` counts an owed move's ids on its target, whatever a later copy maps them to
    (`EngineFailures.swift:718`).
  - **The joins.** `noteJoin` compares a move's join with the engine's copy, also when the move reads a replaced copy:
    a job holding an id the copy maps elsewhere is in `unfollowed` (`invariantViolations()`). Comparing with the move's
    copy broke that invariant in a scratch run, so it was not kept.
- **RR-14** (S3-R21 item 4). At each apply made while a follow is owed, `bringInboundOntoPublications` walks for the
  jobs in flight that publish (verifying or committing), under the outgoing copy, before `adoptApplied`. It makes no
  move itself, and the apply leaves the follow's first turn to the follow-up turn the walk schedules
  (`EngineState.applyWalked`, `EngineFollow.swift:71`). With the follow's first turn (its moves) in the apply's turn
  too, that turn held the actor 9.38 to 9.57 ms at 10,000 (`publicationApplyTurns`, `.build-s3f/c18/bench4.log`, load
  5.35); deferred, 4.35 ms, and 6.02 ms with a move found for nearly every member (best of three, under "Gate evidence
  (cycle 18)").
- **Stale entries of the follow's order.** A turn passes at most `followSkipsPerTurn` (4,096) entries of jobs that
  left `unfollowed` before their visit (`EngineFollow.swift:158`). After the 404's drain removed 10,001 ids' jobs, the
  next turn passed about 9,500 such entries (about 2 ms in a profile copy). Cost only: a pass is not a visit.

### Tests added (display names)

All in the serialized `EngineFollowBarrierTests` suite, each with `.timeLimit(.minutes(3))`; the scenario tests run in
both `LaneDropVisit` orders and expect the visit-first outcome in both.

- `EngineFollowBarrierPublicationHopTests.swift` (`d788d75`): "R-INT-3: an interest an apply moves onto a publishing
  content gets the publication's outcome, though the next apply moves it on (F-28)"
  (`barrierGivesAnInterestMovedOntoAPublicationItsOutcome`, `:197` at `4fb1375`; seeds 1_717_002 and 1_717_302).
- PublicationHopTests (`c0bbe09`), both shapes:
  - "R-INT-3: an interest moved onto a publishing content gets the publication's outcome, though a catch-up follows the
    next manifest (F-28)" (`barrierGivesAnInterestMovedOntoAPublicationItsOutcomeThroughACatchUp`, `:208`). v4 is
    applied by the store and followed through `followStoreView` (`followStoreHeld`, `:68`), the catch-up's path after an
    `apply` that threw past its writes.
  - "R-INT-3: an interest moved onto a publishing content and mapped back gets the publication's outcome, not its old
    job's bytes (F-28)" (`barrierGivesAnInterestMappedBackOffAPublicationItsOutcome`, `:221`). v4 maps zz-x back to H's
    content; 72 prefetch holders created before H (`publicationHopAhead`, `:62`) also converge on P, so v4's walk owes
    their moves before H's, and H's attempt's end, which makes the first 64, leaves the move off H owed while H's bytes
    publish (the setup checks it, sweep-first). Five transfer slots, two reserved for user work, so H downloads beside
    P. Q, W and every holder ahead get P's integrity failure, as visited first.
- RetryTests (`d788d75`): "R-SYN-4: a Retry-After date is read at the response's arrival though its verdict waits for a
  follow (F-28)" (`barrierReadsARetryAfterDateAtItsArrival`, `:184`; seed 1_717_102).
- MovedBeforeTests (`bfb1c70`): "R-INT-3: an id an apply moves back while a publication runs gets the publication's
  outcome though a later apply moves it again (F-28)"
  (`barrierAnswersAnIDMovedBackAndAwayAgainWithThePublicationsOutcome`, `:103`; seed 1_717_102).
- `EngineFollowBarrierConvergenceTests.swift` (`deb5c9d`): "R-SYN-4: ids converging on one content while a follow is
  owed get its outcome, the moves made over the follow's turns (F-28)"
  (`barrierMovesConvergingIDsOverTheFollowsTurns`, `:164`; seed 1_818_002). 400 holders, whose ids v3 maps to O's
  content while the follow owes their visits, and four endings: O's 404 (everyone `notFound`), O's publication
  (everyone served 16 bytes), the 404 and then v4 mapping the holders to Z while the moves are owed (everyone
  `notFound`, Z never starts), and v4 while O's publication runs (O served, the holders served Z's 48 bytes, the moves
  onto the ended publication dropped). Sweep-first, the setup checks that the attempt's end made 64 moves and owes the
  rest, or that v4's apply owes one move per holder, and the follow's turns run one at a time.
- BenchSync (`d788d75`, `70e0801`): `concentrationNotFoundTurns`, `concentrationPublicationTurns`,
  `concentrationFollowTurns` and `publicationApplyTurns` (R-SYN-11), release only.

### Test changes (G3 one-to-one; S3-R16 item 4)

- `barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits` and `barrierJoinsAnIDMappedBackAfterTheSpaceVerdictThatWaits`
  (HopTests), cycle-17 tests: `mappedBack` subscribes to the engine's events before B's interest counts and returns
  them with the answers (`f662510`). Both tests keep their two expectations and add two: C's verdict reports zz-a failed
  and does not report zz-b. Nothing removed.
- `barrierDecidesA429OnTheLaneAWaitingVerdictLeaves` (VerdictLaneTests), a cycle-16 test, gains the endings
  `throttleFailFastLater` (`165ccdd`): `throttleFailFast`'s script, with the clock advanced 9 s before v4; and
  `retryAfterDateLater` (`4fb1375`): O's attempt held, then released with a 503 whose `Retry-After` is a date 31 s
  ahead of the clock, and the clock advanced 9 s before v4. Every existing ending and expectation is unchanged.
- `publicationHop` (this cycle's own, `d788d75`) gains `next:` (`c0bbe09`): its default, `.onward`, is the scenario
  `barrierGivesAnInterestMovedOntoAPublicationItsOutcome` ran before, with the same tuning, entries and expectations;
  it also returns the answers of the holders ahead (none unless `.back`).
- VerdictAnswersTests' four retry expectations construct `.retry(_, answer: nil, wall: wall)` (`c4dda13`), the new
  case's shape; their conditions and messages are unchanged.
- BenchSync's three concentration cases (`d788d75`, this cycle's own) are reshaped in `70e0801`: the ending's own turn
  is timed in a window of its own, the held turns after it, and the 404's case checks that the follow ends with every id
  answered. Their C2 expectation is unchanged.

### Mutants (S3-R16 1(e))

Setup: `.build-s3f/c18/mut.py` (cycle 17's runner, with this cycle's list) copies `Package.swift`, `Sources/` and
`Tests/` into `.build-s3f/mutsrc` and applies each edit with a count check. It builds in `.build-s3f/mutbuild` and runs
the mutant's filter: twice when it fails, else the Sync bundle once (twice if that fails). Then it reverts and diffs the
copy's `Sources/` against the worktree. `mut2.py`, `mut4.py` and `mut5.py` are the same runner over `.build-s3f/mutsrc2`
and `.build-s3f/mutbuild2`. Round 1 (`mut/`) ran on `70e0801`'s tree: `640ac96`, one doc comment in
`EngineFollow.swift`, was committed while it ran, and its final check printed that comment's diff. Its copy's
`Sources/` and `Tests/` equal a `git archive` of `70e0801` (`diff -rq`), so every mutant was reverted. Round 2
(`mut2/`) ran on `640ac96`'s sources with the first draft of `c0bbe09`'s tests, whose mapped-back case had no holders
ahead of H. Round 3 (`mut4/`) and round 4 (`mut5/`) ran on `4fb1375`'s tree (the copy's `Tests/` equal the worktree's).
Rounds 2 to 4 printed `sync diff: none` and `revert diff: none`. Every scenario failure is sweep-first. Lines are each
round's tree's: `70e0801`'s and `4fb1375`'s tests differ only in PublicationHopTests and VerdictLaneTests.

| Mutant | Branch | Result | Killed by |
|---|---|---|---|
| `rerouteOnPassKeepWhole` | a deferral after a pass keeps the job's whole `rerouteOnPass`, not its part moved away again | 1: 2/2 | MovedBeforeTests `:170` (`correct-4`'s probe) |
| `vaStampDrop` | `verdictAnswers` reads the drain's instant, not the verdict's stamp | 1: 2/2 (`:214`, `:219`); 4: 2/2 | VerdictLaneTests `:226`, `:231` (`throttleFailFastLater`) |
| `takeOffAssetsKeep` | a move leaves the moved ids among the holder's assets | 1: 2/2 | HopTests `:176` (C's 404 reports zz-b failed) |
| `inboundSharedBudgetDrop` | the visits get a turn's budget of their own after the moves | 1: 2/2 | ConvergenceTests `:179`, `:181` (`applyBetween`; `notFound` also ran into its time limit, `:163`) |
| `inboundListingDrop` | a move re-routes under the engine's copy, not the copy that found it | 1: 2/2 | ConvergenceTests `:179`, `:181` (`applyBetween`) |
| `inboundTargetWaitsDrop` | a move onto a target whose attempt has ended is made | 1: 2/2 | ConvergenceTests `:179` (`publicationApply`) |
| `publishInboundWaitDrop` | `publish` binds while moves onto or off its job are owed | 1: 2/2 | ConvergenceTests `:179` (`publication`; its setup's wait for the publication's wait ran into the time limit, `:163`) |
| `inboundHolderWaitDrop` | the publication waits for moves onto its job only, not off it | 1: **passed** (filter and bundle); 2: **passed** (filter and bundle); 3: 2/2 | PublicationHopTests `:224` (mapped back, both shapes) |
| `applyWalkDrop` | `applied` walks no publication | 1: 2/2 (`:118`); 3: 2/2 | PublicationHopTests `:200` (both shapes) |
| `catchUpWalkDrop` | `followStoreView` walks no publication | 1: **passed** (filter and bundle); 2: 2/2 (`:183`); 3: 2/2 | PublicationHopTests `:211` (through the catch-up, both shapes) |
| `retryAfterWallDrop` | `giveVerdict`'s retry reads the date against the clock at the drain | 1: 2/2 | RetryTests `:222`, `:223` |
| `vaWallDrop` | `verdictAnswers` reads the date against the clock when asked, not at the 503's arrival | 1: **passed** (filter and bundle); 3: 2/2 | VerdictLaneTests `:224`, `:226`, `:231` (`retryAfterDateLater`) |
| `bringInboundVisitFilterDrop` | the walk brings a holder's ids its visit would not move | 1: filter passed; bundle 2/2 | HopTests `:407` |
| `publishBringInboundDrop` | `publish` brings nothing | 1: 2/2 | HopTests `:330` (`published`); ConvergenceTests' setup `:121` (`publication`, which then ran into its time limit, `:163`) |
| `spaceBringInboundDrop` | `spaceFailed`'s deferral brings nothing | 1: 2/2 | HopTests `:30` (the `expectInsufficientSpace` helper, `insufficientSpace`) |
| `deferBringInboundDrop` | `defersFailure` brings nothing | 1: 2/2 | HopTests `:327` (`notFound`); ConvergenceTests' setup `:121` |
| `rule3BringingDrop` | the moves' joins wait behind the verdict too | 1: 2/2 | ConvergenceTests `:179`, `:181` (`notFound` also ran into its time limit, `:163`); HopTests `:30`, `:327` |
| `followSkipsPerTurnUnbounded` | a turn passes every stale entry of the follow's order | 3: **passed** (filter and bundle) | Cost only (below) |
| `applyWalkedDrop` | the apply's turn also runs the follow's first turn | 3: 2/2, setup checks only | ConvergenceTests `:130`, PublicationHopTests `:161`; cost only (below) |
| `bringInboundStampDrop` | the moves' joins read the holder's visit instant | — | **Removed** in `b9c0513` (below) |

Round 2 shows why the mapped-back case needs holders ahead: H's attempt's end runs `bringInbound`, which makes the first
`inboundMovesNow` owed moves (`makeInboundNow`), the move off H among them, so the publication never met a move off its
job still owed. With 72 holders created before H converging on P, v4's walk owes their moves first, and the move off H
is still owed when H publishes (the test's setup checks it). Unwaited, H's publication bound zz-x, which v4 maps to H's
content, and served W H's bytes; a visit-first engine had moved W onto P at v3's visit.

`bringInboundStampDrop` (`correct-5`): cycle 17's moves joined each interest under the holder's visit instant
(`withReading`), and the drop-mutant survived every bundle. The moves make no visit, so they read no decision instant:
a join onto a job at its attempt's end reads none. The reading was removed with the moves' rewrite in `b9c0513`
(S3-R19 item 3; `continueInbound`'s doc comment).

`followSkipsPerTurnUnbounded` and `applyWalkedDrop` change where a turn ends, not what the follow does. A pass over a
stale entry visits nothing. The follow's first turn makes the same moves and visits, in the same order, whether the
apply's turn or the follow-up turn runs it, and every event between the two waits behind the barrier. Both are cost
only (S3-R19 item 2). `applyWalkedDrop` fails only the two setup checks that read where the moves are owed when the
apply returns (`#require`, before any answer is read). No benchmark ran with either mutant. Before the deferral was
added, the apply's turn measured 9.38 to 9.57 ms (`bench4.log`, load 5.35), within C2's 10 ms by less than 0.7 ms;
without the bound, the turn after the 404's drain passed about 9,500 stale entries, about 2 ms in a profile copy. Both
are margin for C2; the figures with them are under "Gate evidence (cycle 18)".

### Residual risks (S3-R16; cycle 18)

For Stage 5's `docs/RESIDUAL-RISKS.md`, beside RR-1 to RR-15.

- **RR-14 is closed** by `b9c0513` (above), except the window in RR-18.
- **RR-15, rewritten (order only).** A visit's join behind a waiting verdict is placed right behind the verdict. The
  moves an attempt's end or an apply owes are made in the holders' creation order (`Job.epoch`), before any owed visit,
  over the follow's turns; a visit-first engine made them at each apply's instant, in follow order. A move onto a job
  whose attempt ended meanwhile is dropped, and the holder's own visit moves the ids. Not probed.
- **RR-16. A holder's interest brought onto a job that a visit-first engine had already superseded** (`reqs-5`;
  PROBE-C17C-INBOUND-SUPERSEDED, seed 1_717_002, its holder-first CONTROL and its CONSISTENT variant, seed 1_717_022,
  in `.build-orchestrator/s3f-probes-c17/correct/VerifyC17CorrectProbes.swift:450-479`). When the ending job's own owed
  visit comes before the holder's in follow order and moves every id it holds, a visit-first engine superseded the job
  and gave the holder's interest a fresh job of the content: one request more (tStarts 2 against 1). The verifier's
  results: INBOUND-SUPERSEDED fails sweep-first 6 of 6 (W `notFound` against 100,000 bytes served), only because the
  fake answers T's first request 404 and its second 200; CONSISTENT, with every request for T's content answered 404,
  passes both orders 3 of 3 (W `notFound`); CONTROL passes 6 of 6. A start-count difference while the server answers
  alike (S3-R16 item 2); an answer difference only when the origin answers two requests for one content differently.

  **RR-23, RR-16 followed by an apply that maps the id on**, is recorded here (ruling S3-R24 item 5; found while fixing
  cycle 19, first written under "Cycle 19", moved here in cycle 20). In RR-16's shape a visit-first engine superseded
  the ending job T at the apply, and its visit gave the holder's interest a fresh job of T's content (the second
  request); sweep-first, T's attempt's end brings the interest onto T (`bringInbound`). If T's publication binds the id
  and answers it before a later apply maps the id on to Z, while the visit-first engine's fresh job is still downloading
  at that apply, that engine's visit moves the id to Z: T's bytes against Z's outcome, with the origin answering alike.
  The difference follows RR-16's extra request and needs the later apply to land between T's answer and the fresh
  job's. A timing difference in RR-16's family (S3-R16 item 2): not blocking, and no probe is required; it becomes
  blocking only if a probe shows a different answer when the later apply lands after both engines' answers, or before
  both. Not probed: a probe needs PROBE-C17C-INBOUND-SUPERSEDED's setup and a fourth manifest.
- **RR-17. An admission racing an older apply that omits the id answers `notFound`** (S3-R21 item 3;
  PROBE-C17-ADMIT-DURING-APPLY, seed 1_618_202). **For the owner: it gives a wrong `notFound` under a race.** A waiter
  for an id the copy does not list is admitted from the manifest its fetch returns (`EngineManifest.join`). While an
  `apply` of an older manifest that omits the id is in flight, the engine refuses the store's view
  (`followStoreView`), so the job holds an id its copy does not list. That apply's follow then visits the job:
  `follow`'s filter counts the id as moved, and `reroute` answers the waiter `notFound`, since the copy does not list
  it; the store lists the id, and the catch-up the refused view owed adopts it just after. The probe
  (`.build-s3f/c17/ScratchC17AdmitDuringApply.swift.txt`, run in the mutation copy, not committed) failed 2 of 2 runs:
  `(xHoldsU: false, copyListsU: true), storeListsU: true; U: failure(ZTronAssetModel.AssetError.notFound)`; X's own
  waiter was served. Visit-first answers the same, and both rules predate s3-base (the visit's filter is s3-base's
  `followApplied`; the refused view is `5a53605`), so it is outside the follow-barrier class. When: the server adds the
  id between a run's fetch and the refetch, and the admission lands while that run's apply is in flight. Options,
  none taken: (a) while a catch-up is owed (`catchUpAfterFailedApply`), a visit leaves an id the copy does not list,
  and the catch-up's follow decides it; (b) the admission records the ids it joined unlisted, and a visit moves only
  the ids the copy pruned.
- **RR-18. An apply inside a failed publication's bookkeeping await** (found while fixing; analysis, not probed).
  **Corrected in cycle 19 (ruling S3-R22 item 2, the cycle-18 requirements verifier's reading): the difference this
  entry described does not exist, and the entry is withdrawn.** The cycle-18 text said a visit-first engine's failure
  answered the id. It did not: that engine's visit at the later apply, made inside the bookkeeping await, met the job
  `failed` with its end recorded, no verdict yet and an apply followed since the end (`appliesFollowed !=
  end.failedAfter`), so `rerouteOnVisit` returns `nil` and the visit moved the id off the job to the content the new
  copy names, "as met failed" (`recordPublicationEnd`'s doc). The verdict, given after the await, did not answer it.
  The sweep-first holder's visit moves the id to that content directly: the same answer. When the new copy still maps
  the id to the job's content, both orders answer it with the verdict: the verdict's deferral brings it onto the job
  (`bringInbound` under the new copy) while a follow is owed, and with none owed the holder's visit has joined it to the
  failed job before the verdict (no verdict waits, so `addInterest`'s rule 3 does not defer the join). No seam holds
  `integrityFailed`'s store await, so this reading is the code's and is not probed, as S3-R22 item 2 allows.

### Put to the orchestrator (found while fixing; not changed this cycle)

1. **RR-18** (above): blocking only if a probe shows it (S3-R16 item 1(a)). The walk's change is one clause; the
   test needs a seam that holds `integrityFailed`'s store await. Answered by ruling S3-R22 item 2; the entry is
   corrected and withdrawn in cycle 19 (above).

### Corrections to cycle 17's text

- **`bringInbound`'s doc comment** said every interest it brings is one a visit-first engine's visits had already moved
  onto the job. Not when the job's own owed visit comes first and supersedes it (RR-16). Corrected in `640ac96`.
- **RR-14** was "Not probed" in cycle 17: both verifiers probed it, and it is fixed (above).
- **RR-15**'s "`bringInbound` takes its holders by transfer" is replaced by the creation order (above).

### The inventory, corrected (cycle 18)

These rows replace cycle 17's `bringInbound` row and add four. Line numbers are at `640ac96` (sources; the tests'
at `4fb1375`).

- **`bringInbound`** (`EngineFollow.swift:928`; called from `defersFailure`, `spaceFailed` and `publish`), now a walk
  that records the moves (`findInbound` `:975`, `foundInbound` `:1010`) and makes the first 64. Tests: cycle 17's hop
  tests, the convergence test. Mutants: `deferBringInboundDrop`, `spaceBringInboundDrop`, `publishBringInboundDrop`,
  `bringInboundVisitFilterDrop`, `rule3BringingDrop`. C2: `inboundWalkTurns`, `concentrationNotFoundTurns`,
  `concentrationPublicationTurns`.
- **New, the owed moves** (`continueInbound` `:1113`, `inboundTargetWaits` `:1146`, `inboundMade` `:1162`,
  `continueFollow`'s shared budget `:111`). Test: the convergence test. Mutants: `inboundSharedBudgetDrop`,
  `inboundListingDrop`, `inboundTargetWaitsDrop`. C2: the concentration cases' held turns.
- **New, the publication's wait** (`inboundBlocks` `:1076`, `awaitInboundMoves` `:1175`, `publish`
  `EngineDispatch.swift:1031`, `releaseInboundWaits` `:1192`). Tests: the convergence test's `publication` ending (onto
  the job), PublicationHopTests' mapped-back test (`:221`, off it). Mutants: `publishInboundWaitDrop`,
  `inboundHolderWaitDrop`. RE-S48 (proposed).
- **New, the apply's walk** (`bringInboundOntoPublications` `:948`, `applyWalked` `:71`; called from `applied` and
  `followStoreView`). Tests: PublicationHopTests (`:197`; through the catch-up, `:208`), the convergence test's
  `publicationApply` ending. Mutants: `applyWalkDrop`, `catchUpWalkDrop`; `applyWalkedDrop` and
  `followSkipsPerTurnUnbounded` are cost only (under "Mutants"). C2: `publicationApplyTurns`.
- **New, the arrival's wall clock** (`retryLater` `EngineFailures.swift:244`, `verdictAnswers` `:855`,
  `AttemptVerdict.retry`'s `wall` `EngineFollow.swift:1353`). Tests: RetryTests `:184`, VerdictLaneTests'
  `retryAfterDateLater` (`:219`). Mutants: `retryAfterWallDrop`, `vaWallDrop`.

### Hang guards and re-entrancy

- The new tests use `.minutes(3)`, as the suite's do; the benchmarks `.minutes(5)` (`publicationApplyTurns` and the
  concentration cases run seven and four engines of 10,000 members).
- One `await` was added in an actor: `publish`'s `await self.awaitInboundMoves(transfer)`
  (`EngineDispatch.swift:1036`), with its `// REENTRANCY: RE-S48 (proposed)` comment; `awaitInboundMoves`'s own
  `withCheckedContinuation` carries the same row. Proposed row under "Proposed document changes", "Cycle 18 adds:".
- 0 unsafe escapes (gate below).

## Cycle 19: the cycle-18 verifiers' findings, and S3-R22 and S3-R23

Cycle 19 applies S3-R22 and S3-R23 (recorded under "Orchestrator rulings (close-out)") to the fifteen findings of the
cycle-18 verifiers (`.build-orchestrator/s3f-c18-issues.json`, numbered here in its order: #1 to #6 from the
correctness lens, #7 to #15 from the requirements lens). The five blocking ones (#1, #7, #8, #9, #10) are fixed. The
work went in this order:

1. `5dd145a`: the failing tests, committed on their own (P3): PROBE-C18C-PENDING-LANE as
   `barrierDecidesA429OnTheLaneAnOwedMoveLeavesAfterALaterApply` (the new `EngineFollowBarrierPendingLaneTests.swift`,
   both orders, seed 1_919_002, adapted from the probe's seed 1_818_902), which fails sweep-first on `4b1c3a6` (J's
   429 decided on the prefetch lane throttles the origin and starves A), and three BenchSync release cases for #7's
   shapes (five figures), which measured 50.6 to 83.0 ms best of 3 on `4b1c3a6` (the figures and loads are under
   "Gate evidence (cycle 19)").
2. `6dda008`: the moves bounded by ids (S3-R22 item 1; #7), the lane of an id an owed move carries (#1, #8), the
   removals and invariants S3-R19 item 3 asks for (#6, #10, #15), and the two doc corrections (#5, #12).
3. `951e19f`, then `869ffed`, `4d711f2`, `1b84c6e`, `82045be` and `b8ad024`: the tests the findings ask for, and one
   commit for each mutant that survived the tests before it (under "Mutants"); then `3cd80c7`, a bound on the drain
   test's loop over the follow's turns, which one mutant ran past the test's time limit (under "Mutants").
4. `0684845`: a bounded move no longer copies an interest's ids for each id it moves. That copy kept the three
   BenchSync cases for #7 over C2 at a quiet load in the gate run on `3cd80c7` (best 19.9 to 23.4 ms at a 1-minute load
   of 7.7 to 9.3; under "Gate evidence (cycle 19)").
5. This draft (RR-18 corrected and withdrawn, #13).

### The findings

| Finding | Disposition |
|---|---|
| #1 (blocking): PROBE-C18C-PENDING-LANE, seed 1_818_902: `followedLane` counted an id an owed move carries on the move's target whatever a later copy maps it to, so a 429 that arrives while the move is owed is decided on the wrong lane when the target's exit verdict waits and an apply was followed since | **Fixed** (`6dda008`), by the finding's option: an id an owed move carries counts by the rule of the move's job while that job is still at the attempt's end the move was found for (`waitingTarget`, `EngineFollow.swift:1239`): what its owed visit moves, the ids the drain takes off it before its verdict, and its waiting verdict when an apply was followed since (`movesAfterVerdict`, `verdictAnswers` at the verdict's stamp, on `jobAtVerdict`). A move whose job left that end is dropped, so its ids count by the holder's rule (`followedLane`, `EngineFailures.swift:721`). Tests: `barrierDecidesA429OnTheLaneAnOwedMoveLeavesAfterALaterApply` (the probe, O's timeout) and `barrierDecidesA429WithoutAnInterestTheOwedMovesVerdictAnswers` (O's 404, whose waiting verdict answers B: the interest leaves J's lane), each in three shapes |
| #2 (non-blocking): PROBE-C18C-PUBLICATION-WAIT-APPLY (seed 1_818_952) and -HELD | **Recorded** as RR-19 (below). No code change |
| #3 (non-blocking): `concentrationPublicationTurns` missed C2 only under load | **Quoted**: the cycle-18 verifier's low-load re-runs were [5.73, 6.93, 6.21] ms at load 8.9 to 9.4. This cycle's figures are under "Gate evidence (cycle 19)" |
| #4 (non-blocking): StorageBenchmarks P-13 | **Routed** `other-wp:b`, as in every cycle. No WP-F change |
| #5 (non-blocking): `findInbound`'s doc says the holders go in their jobs' creation order | **Corrected** in `6dda008`: `Job.epoch` is the job's creation or its last attempt's start (`EngineDispatch.swift:697`), then the targets' epochs |
| #6 (non-blocking): `awaitInboundMoves` overwrites a wait without a check; no invariant on `inboundOnto` or `inboundWaits` | **Two invariants added** to `followBarrierViolations` (below). The overwrite is unreachable and gets no check (S3-R19 item 3): a second publication of the same job needs `downloading` then `verifying` again, so an admission, which the barrier holds back while anything the wait waits for is owed; `verifying` to `verifying` is not a transition. The shutdown path's staged file is left as the existing `isRunning` return after `store.publish` leaves it |
| #7 (blocking): one visit, or one owed move, re-routes every id it carries in one turn (VERIFY-C18R-SHARED-CONVERGENCE, -SHARED-DIVERGENCE, -DIVERGENCE: 54 to 83 ms) | **Fixed** (`6dda008`) as the finding's items (1) to (4) say (S3-R22 item 1; "What cycle 19 changes"). Pinned twice (S3-R23 item 3): `barrierMovesASharedContentsIDsOverBoundedTurns` and `barrierDrainsTheEventsAfterAVisitsRest` count the ids each turn moves under a small injected bound (`EngineState.followIDsPerTurn` = 4), and the drop-mutant of the bound (`startChunkDrop`) and of the attempt's end's share (`inboundIDsNowFull`) fail them 2/2; the BenchSync cases `sharedApplyTurns`, `divergenceTurns` and `inboundHolderTurns` time the turns at 10,000 (under "Gate evidence (cycle 19)"). They met C2 only with `0684845`: on `3cd80c7` a copy of the interest's ids per moved id kept them at 19.9 to 23.4 ms best at a 1-minute load of 7.7 to 9.3 |
| #8 (blocking): `followedLane`'s owed-move clauses unpinned (`followedLanePendingHereDrop`, `followedLanePendingFilterDrop` survived) | **Fixed** with #1: the clauses are replaced by `carried`/`movesViaTarget`, and their four drop-mutants (`laneCarriedDrop`, `laneTargetVerdictDrop`, `laneHolderRule`, `laneOwnViaTargetDrop`) are each killed 2/2 (under "Mutants"; `laneOwnViaTargetDrop` by `4d711f2`'s third shape) |
| #9 (blocking): `foundInbound`'s pending guard and its two-target and same-target branches unpinned | **Fixed** by tests: `barrierMovesOneHoldersIDsOntoTwoPublications` (one holder, two ids onto each of two publications: the first-target insert, the other targets' append and slot insert, each drop-mutant killed 2/2) and the shared-move cases (ten ids of one holder onto one target). `findInboundPendingDrop` is killed 2/2 by `.convergenceApplies` (v4's walk while the owed move still carries members records no second move of them). The branches no test reaches are under "Not reached by a test (cycle 19)", with the reason |
| #10 (blocking): the publication's wait released by no test (`shutdownReleaseInboundWaitsDrop`, `inboundMadeHolderResumeDrop` survived) | **Fixed** by tests: `barrierShutsDownWhileAPublicationWaitsForOwedMoves` (a shutdown during the wait for an owed move and for a visit's rest; `shutdownReleaseInboundWaitsDrop` hangs it, 2/2) and `barrierBindsTheIDAPublicationKeepsOnceTheMoveOffItsJobIsMade` (a holder's publication resumed by the move off its job; `inboundMadeHolderResumeDrop` 2/2). (c), the retire or replacement during the wait: **removed** with the re-check (S3-R19 item 3; "Removals") |
| #11 (non-blocking): the concentration publication's commit turn unpinned (9.64 ms best at load 3.84) | **Recorded** as RR-21 (below); no BenchSync case added this cycle |
| #12 (non-blocking): `verdictAnswers`'s doc says a `Retry-After` is read against the clock now | **Corrected** in `6dda008`: against the wall clock at the failure's arrival |
| #13 (non-blocking): RR-18's premise | **Corrected and withdrawn** (S3-R22 item 2): RR-18's entry under "Residual risks (S3-R16; cycle 18)" is rewritten to the reading that a visit-first engine's later visit moved the id off the failed job, so the answers agree |
| #14 (non-blocking): VERIFY-C18R-EMPTY-BINDING: a publication left with no id after its wait commits nothing yet books a commit | **Recorded** as RR-20 (below): the answers agree in both orders; the bookkeeping differs until the next free-space read and staging GC |
| #15 (non-blocking): `addInterest`'s in-place join branches unreached | **Removed** (S3-R19 item 3): the "job vanished" guard by the restructure (the job is read and joined in one scope), and the in-place lane raise, which no path reaches, replaced by an invariant clause (below) |

### What cycle 19 changes (`6dda008`, `0684845`)

- **A visit moves at most a turn's ids, and its rest continues first in the follow's next turns** (S3-R22 item 1).
  `continueFollow` (`EngineFollow.swift:114`) gives each turn a `FollowBudget`: `followsPerTurn` visits and holders,
  and `SyncEngine.followIDsPerTurn` (512, `EngineMoves.swift:126`; the seam `EngineState.followIDsPerTurn`) ids. A
  visit that moves more ids than are left (`follow`, `EngineFollow.swift:890`, through `startMove`,
  `EngineMoves.swift:140`) moves that many and leaves the rest in `EngineState.followMoving` (a `VisitRemainder`: the
  holder, its moves left, the visit's decision instant, whether it is the drain's visit after a verdict, and whether
  it spends a passed job's re-route set). The next turns continue it before any visit (`continueVisitRemainder`,
  `:808`), after the owed moves: the moves stand for visits made before it (S3-R20 item 3), so the rest waits while one
  is owed, though a turn's `followsPerTurn` holders, not its ids, ended the moves. A turn whose ids are spent visits no
  job. `followOwed` includes the rest, so the barrier holds until its last id moved.
- **An owed move continues over turns too.** An `InboundMove` that carries more ids than are left keeps its moves in
  `InboundMove.progress` and ends the turn's moves; its holder counts once, at its first turn, and its target is
  re-read at every turn (`continueInbound`, `:1191`). An attempt's end or an apply's walk makes `inboundMovesNow` (64)
  holders and `inboundIDsNow` (half a turn's ids, 256) in its own turn.
- **How the ids are taken.** `MoveProgress` keeps the holder's interests in the ids it moves in a binary min-heap by
  (id, token), so a turn takes its next ones without sorting the whole set up front. An id is taken whole: all of its
  interests in one turn, so it leaves the job in one turn or stays (`continueMove`, `EngineMoves.swift:179`). Each
  interest is re-routed as `move` re-routes it (`reroute`, under the listing the move was found under; a visit's rest
  under the copy as it stands at the turn). An id that an apply made since maps to the job's content again rejoins the
  job through `reroute`, behind the job's exit verdict when that waits (`addInterest`'s rule 3), as that apply's visit
  on a visit-first engine moved it back (the first draft's keep clause is removed: "Removals").
- **A job whose every id leaves is superseded over the turns.** As `move` supersedes it: its running attempt is
  abandoned at the first turn (`recordBreaker(.abandoned)`; no 429, failure or bytes of it can arrive in the later
  turns), the job waits queued behind the barrier while its interests leave, and it is removed with its last one, or,
  an id having rejoined it, re-laned once from the lane it had when the move began.
- **The drain's visit after a verdict is bounded too.** `followAfterVerdict` (`:575`) visits within
  `followIDsPerTurn`. A visit that leaves a rest ends the drain's batch: the rest of the batch goes back to the head of
  `eventsAfterFollow`, in order, and a follow turn is scheduled (`drainEventsAfterFollow`, `:181`), since a visit-first
  engine made that visit at once, before the next event.
- **A publication waits for its visit's rest** as it waits for owed moves (`inboundBlocks`, `:1147`: the rest's
  holder blocks), and the rest's end resumes it (`continueVisitRemainder`). A visit-first engine's visit had moved
  those ids before the publication began.
- **The lane of an id an owed move carries** (#1): under the finding's table row.
- **Invariants** (S3-R19 item 3; #6): `followBarrierViolations` checks that each job's count of owed moves onto it
  (`inboundOnto`) equals the owed moves naming it, and that every registered wait (`inboundWaits`) has a verifying job
  that something still blocks, while the engine runs. `invariantViolations` checks that a token's interests carry its
  one lane (its group's `Group.lane` when it has a group). The `unfollowed` index invariant leaves out the rest's
  holder, which holds the ids it still moves and was visited already.
- **`awaitInboundMoves` notifies observers** when it registers (`:1272`): a mutation, after which the test seams'
  conditions re-evaluate (L4-R17). A publication whose attempt's end owed no move found nothing else to notify them.
- **No copy of an interest's ids per moved id** (`0684845`). `continueMove` read the holder's interest into a local
  before it removed the moved id from it, so the removal found the ids' storage shared and copied the whole set, once
  per id: a turn of 512 off one interest of 10,000 ids held the actor about 20 ms, which the gate run on `3cd80c7`
  measured. The move now reads the interest's lane and kind, all `reroute` reads, and removes the id in the table
  (`EngineMoves.swift:202`).

### Removals (S3-R19 item 3; S3-R16 1(e) and item 3)

| Removed | Why |
|---|---|
| `publish`'s re-check of the job's epoch and state after the wait (cycle 18, `EngineDispatch.swift:1041-1046`: a retired or replaced job, `recordBreaker(.abandoned)`, the staged file discarded) | No path reaches it. While a publication waits its job stays `verifying` at its epoch: `retire` returns early for a verifying or committing job, `move` and `startMove` supersede only a job that is not publishing, a re-admission needs the barrier down, and the wait lasts only while the barrier is up. The invariant above fails if a wait outlives that. The lifecycle check after the wait stays (`guard self.isRunning`) |
| `awaitInboundMoves`'s early return and the re-check inside the continuation | No path reaches them: the caller checks `inboundBlocks` in the same turn, and the body registers synchronously |
| `addInterest`'s "job vanished" guard | No path reaches it: the job is read and joined in one scope (`EngineJobs.swift:108`); nothing between can remove it |
| `addInterest`'s in-place lane raise of an interest already on the job (cycle 18, `EngineJobs.swift:163-165`) | No path reaches it: a token's lane is fixed when it registers (a waiter's, a group's `let lane`, `.bulk` for a run, `.userInitiated` for an ensure, a system interest's own token), and every join and re-route passes it on (`reroute`, `replayJoin`), so a second join of a token carries the lane it has. Now an `invariantViolations()` clause, which every test that checks the invariants exercises |
| The first draft's keep clause in `continueMove`: an id of a visit's rest that an apply made since maps back to the job's content stayed on it, without a re-route (`keepDrop`) | Its drop-mutant survived (round 1, on the draft's tree: its filter, then the Sync bundle, `✔ Test run with 551 tests in 53 suites passed after 528.853 seconds.`), so it went under S3-R16 1(e). Without it the id leaves and rejoins through `reroute`, which places it behind the job's waiting exit verdict (`addInterest`'s rule 3) as the apply's visit on a visit-first engine placed it; with the verdict not waiting, the join is a plain join onto the same job. The keep-less tree passed the cycle's barrier tests (14 tests, `targeted-nokeep.log`, 16:59:56–17:01:20) and is the tree every later round and gate ran on |

### Tests added (display names)

All in the serialized `EngineFollowBarrierTests` suite, each in both orders (`LaneDropVisit`) with the visit-first
answers expected in both, `.timeLimit(.minutes(3))`.

- `barrierDecidesA429OnTheLaneAnOwedMoveLeavesAfterALaterApply` (`5dd145a`; the new
  `EngineFollowBarrierPendingLaneTests.swift`, seed 1_919_002, adapted from the probe's 1_818_902): "R-SYN-5: a 429
  counts a user interest an owed move brings onto a job whose verdict waits, on the content a later apply moves it to
  (F-28)". Three shapes (`PendingLaneShape`): `owedTurn`, `publicationHeld` and, from `4d711f2`, `owedTurnFromJ` (zz-b
  starts on J's content, so O's attempt's end owes the move of B off J itself, and v4 maps zz-b back to J).
- `barrierMovesASharedContentsIDsOverBoundedTurns` (`951e19f`; the new `EngineFollowBarrierSharedMoveTests.swift`,
  seed 1_919_102, seven shapes): "R-SYN-6: a visit or an owed move of more ids than a follow turn moves makes them over
  the follow's turns, at most followIDsPerTurn a turn, with the visit-first answers (C2, F-28)". Ten members of one
  prefetch group share one content, `followIDsPerTurn` is 4. `convergence` and `divergence`: one visit moves them onto
  O's content or each onto its own; `convergenceEnds` and `divergencePublishes`: O's bytes arrive while the visit's rest
  is owed, so O's publication waits for the owed move or the rest; `convergenceApplies`: v4 lands while that move still
  carries members, and its walk records no second move of them; `attemptEnd`: O's 404 while H's visit is owed, so the
  attempt's end makes `inboundIDsNow` ids of one move of all ten; `convergenceBystander` (`1b84c6e`): zz-t, on a
  content v3 changes, is found after H in the turn H's visit leaves its rest, and is visited only once the rest is
  moved. Sweep-first each turn's moved ids are counted (all at most 4, one of 4), the attempt's end's share is 1 or 2,
  the end owes one move carrying every member still on H and names exactly those as carried (`inboundPendingIDs`,
  `1b84c6e`). Converging, H starts once and its attempt is cancelled once (`869ffed`), in the turn the move off it began
  (`b8ad024`).
- `barrierShutsDownWhileAPublicationWaitsForOwedMoves` (`951e19f`, seed 1_919_302, `convergenceEnds` and
  `divergencePublishes`): "R-SYN-11: shutdown while a publication waits for an owed move or a visit's rest completes and
  answers every waiter (F-28)".
- `barrierDrainsTheEventsAfterAVisitsRest` (`951e19f`, seed 1_919_202): "R-SYN-11: the drain's visit after a verdict
  that moves more ids than a turn moves makes them all before the next waiting event (C2, F-28)". C's timeout verdict
  waits, v4 maps ten members to N, and N's 404 waits behind C's: N's 404 answers every member, and N starts once.
  Sweep-first the follow's turns run one at a time and the members leave C at most 4 a turn, over at least three
  turns; from `3cd80c7` the loop over those turns fails after 16 of them, as the other follow-turn loops do.
- `barrierMovesOneHoldersIDsOntoTwoPublications` (`951e19f`; the new `EngineFollowBarrierTwoTargetsTests.swift`, seed
  1_919_402): "R-INT-3: ids one holder gives to two running publications get each its publication's outcome, one owed
  move per publication (F-28)".
- `barrierBindsTheIDAPublicationKeepsOnceTheMoveOffItsJobIsMade` (`951e19f`, PublicationHopTests, both shapes):
  "R-INT-3: a publication that waits for a move off its job binds the id it keeps once the move is made (F-28)".
- `barrierDecidesA429WithoutAnInterestTheOwedMovesVerdictAnswers` (`951e19f`, PendingLaneTests, three shapes):
  "R-SYN-5: a 429 leaves out a user interest an owed move brings onto a job whose waiting verdict answers it (F-28)".
- `barrierSpendsTheRerouteOfAVisitMadeOverTurns` (`951e19f`, StaleRerouteTests, seed 1_919_502): "R-INT-3: a visit
  re-routing more ids than a turn moves spends the re-route at its last, for the same follow's later visits (F-28)".
  zz-d moves with zz-b and a turn moves one id, so C's visit re-routes them over two turns, and spends the set at its
  last; v5's visit in the same follow passes C, and A, B and D get C's integrity failure.
- `barrierMakesTheOwedMovesBeforeAVisitsRest` (`82045be`; the new `EngineFollowBarrierRestOrderTests.swift`, seed
  1_919_602): "R-INT-3: a visit's rest waits for the moves a turn's holders leave owed, so the 404 that ended the moves'
  job answers every member with one request (F-28)". 330 holders of one id each, created before H, and H's 270
  members converge on O's content (`followIDsPerTurn` 260); O's 404 arrives while H's visit owes its rest, so the
  attempt's end owes a move per holder, H's last, after more than a turn's 256 holders. The rest waits for them: every
  member and holder gets the 404, and O starts once.

### Test changes (G3 one-to-one; S3-R16 item 4)

No pre-existing assertion is removed or weakened.

| Test or helper | Change |
|---|---|
| `publicationHop` (PublicationHopTests) | Returns V's answer as a fifth value (`nil` but for the new `.backKeeping`); with `.back` it also requires, once the follow ended, that no publication still waits (`inboundWaits` empty). The `.onward`, `.onwardCaughtUp` and `.back` scenarios, manifests and assertions are unchanged |
| `pendingLane` (PendingLaneTests, `5dd145a`) | Gains `ending:` (`.timeout` by default, the committed probe's ending; `.notFound` scripts O's 404) in `951e19f`, and the third shape `owedTurnFromJ` in `4d711f2` (zz-b's job is J's, and P's waiter is created after B's and the holders ahead); the `owedTurn` and `publicationHeld` scenarios and the probe's assertions are unchanged |
| `staleReroute` (StaleRerouteTests) | Gains `pair:` (`false` by default: no zz-d, no tail of entries, the seam untouched) and returns D's answer as a third value; the three cycle-16 tests ignore it, their scenarios and assertions unchanged |
| `sharedMove` and its test (SharedMoveTests, `951e19f`) | Assertions added after it was committed: H's cancellations once the follow ended (`869ffed`) and at the end of the first turn that moved a member off H (`b8ad024`), the carried ids right after O's attempt's end and the `convergenceBystander` shape (`1b84c6e`). Nothing was removed |
| `drainRemainder` (SharedMoveTests, `951e19f`) | Its sweep-first loop over the follow's turns fails after 16 turns (`3cd80c7`): the time limit's cancellation ends `runOneFollowTurn`'s wait for a scheduled turn but not the loop, which `drainRestReturnDrop` kept spinning. Unmutated, both cases pass (1.929 s, `fix/drain-bound-run.log`). Nothing was removed |

### Mutants (S3-R16 1(e))

Setup: `.build-s3f/c19/mut.py` (cycle 18's runner with this cycle's list) copies `Package.swift`, `Sources/` and
`Tests/` into `.build-s3f/mutsrc`, applies each edit with a count check, builds in `.build-s3f/mutbuild` and runs the
mutant's filter: twice when it fails, else the Sync bundle once (twice if that fails). Then it reverts and diffs the
copy's `Sources/` against the worktree. `mut2.py` is the same runner over `.build-s3f/mutsrc2` and
`.build-s3f/mutbuild2`. A mutant that survived a round was re-run against the test written for it in the worktree
(`.build-s3f/c19/w-mutant.sh`: the edit with a count check, a build in `.build-s3f`, the filter twice, the file
restored and rebuilt; logs in `wmut/`) or in the second copy (`copy2-check.sh`, also the filter once unmutated; logs
in `copy2/`), before the test was committed. The rounds:

- Round 1 (`mut-oldsrc/`, `mut2-oldsrc/`): the first draft's tree, with the keep clause.
- Round 2 (`mut-A2.log`, `mut-B2.log`, launched 17:08:54): `6dda008`'s `Sources/` (nothing in `Sources/` changed
  between the launch and that commit) with the first draft of `951e19f`'s tests.
- Round 3 (`mut-A3.log`, launched 17:37:22): `1b84c6e`'s tree.
- Round 4 (`mut-B3.log`, launched 17:53:29): `82045be`'s tree.
- Round 5 (`mut-A4.log`, launched 18:35:50): `3cd80c7`'s tree, for the three mutants round 3 left: its
  `drainRestReturnDrop` run spun past the drain test's time limit and was stopped by its PIDs after 14 minutes, with
  the driver stopped first, so neither a bundle run nor a `SURVIVED` line followed (noted in `mut-A3.log`).
- Round 6 (`mut-A5.log`, launched 20:05:34): `0684845`'s tree, for the five mutants of `EngineMoves.swift`, whose
  `continueMove` that commit changes.

Every round printed `sync diff: none`. Rounds 5 and 6 also printed `revert diff: none`. Round 4's revert diff showed
`EngineShutdown.swift` on the worktree's side: `w-hang.sh` had the shutdown mutant applied there from 17:53:59 until the
cut at 18:09:09, when its trap restored the file (`shutdownReleaseInboundWaitsDrop: restored`, `rebuild exit 0` by
18:09:32; noted in `mut-B3.log` at 17:58:10). No commit of this cycle touches that file; `b8ad024`, at 18:07:27, changed
only `EngineFollowBarrierSharedMoveTests.swift`. Rounds 2 and 3 were stopped before their revert diffs (`mut-A2.log` at
17:36:54, `mut-B2.log` at the hang and `mut-A3.log` at the spin below), and each later round re-synced its copy from the
worktree first. `Sources/` is `6dda008`'s in rounds 2 to 5 and `0684845`'s in round 6 (it changes only how
`continueMove` reads the interest it moves), and the later tests only add to the rounds' (no assertion was removed), so
every assertion a kill below names is in HEAD's tests unchanged; the runs themselves are the rounds' and the worktree
checks', not HEAD's. Lines are HEAD's (`.build-s3f/c19/killmap.py` finds each failed assertion by its text inside the
failing test in HEAD's file; `killmap.txt`). Every failure is sweep-first unless the row says otherwise.

| Mutant | Branch | Result | Killed by |
|---|---|---|---|
| `startChunkDrop` | `startMove` moves every id at once, whatever the turn has left (the bound dropped) | 1: 2/2; 2: 2/2; 6: 2/2 | SharedMoveTests `:328`, `:329` (each of round 2's five shapes), `:332` (`attemptEnd`), `:335` (`divergencePublishes`), `:338` (`attemptEnd`, `convergenceEnds`); in round 6 also `:342`, `:345` and ReachTests `:30` (`convergenceApplies`) |
| `inboundIDsNowFull` | an attempt's end or an apply's turn moves four turns' ids, not half of one | 1: 2/2; 2: 2/2; 6: 2/2 | SharedMoveTests `:328`, `:329`, `:332`, `:338` (`attemptEnd`, `convergenceEnds`); `convergenceEnds` also ran into its time limit (`:292`); in round 6 also `:229` and the time limit of `convergenceApplies` |
| `remainderDrop` | a visit's rest is dropped, not kept in `followMoving` | 1: 2/2; 2: 2/2 | SharedMoveTests `:308` (the members' answers) and `:310` (H starts twice), in both orders; `:327`, `:335`, `:338`; three cases ran into the time limit (`:292`) |
| `progressStoreDrop` | a begun owed move's moves left are not kept (`InboundMove.progress`) | 2: filter passed, bundle cut (no result); `1b84c6e`: 2/2 | SharedMoveTests `:342` (`attemptEnd`, `convergenceEnds`: the move names as carried members it has moved), `:229` (`convergenceApplies`' setup) |
| `visitIDsBudgetDrop` | a turn whose ids are spent still visits jobs | `1b84c6e`: 2/2 (not run in a round: the bystander shape was written for it, since a second visit that leaves a rest overwrites the first's) | SharedMoveTests `:310` (H starts twice, both orders), `:327` (`convergenceBystander`) |
| `restAfterInboundDrop` | a visit's rest continues while a move is owed | 3: filter passed, bundle cut (no result); `82045be`: 2/2 | RestOrderTests `:166` (O starts twice), `:172` (members leave H while its move is owed) |
| `supersedesDrop` | no bounded move supersedes its job | 3: **passed** (filter, and the bundle: `✔ Test run with 551 tests in 53 suites passed after 459.190 seconds.`); `b8ad024`: 2/2; 6: 2/2 | SharedMoveTests `:325` (each of the five converging shapes: H's attempt is not cancelled in the move's first turn) |
| `chunkAbandonDrop` | a bounded move that supersedes its job leaves the job's attempt running | 2: **passed** (filter, and the bundle: 551 tests, 459.590 s); `869ffed`: 2/2; 6: 2/2 | SharedMoveTests `:313` (H's attempt never cancelled, both orders); in round 6 also `:325` |
| `chunkEndRemoveDrop` | a superseded job is not removed after its last interest left | 2: 2/2; 6: 2/2 | SharedMoveTests `:310` (H starts twice, both orders) |
| `inboundBlocksRestDrop` | `inboundBlocks` leaves out the rest's holder: a publication binds while its visit's rest is owed | 3: 2/2 | SharedMoveTests, `divergencePublishes`: time limits (`:292`, and `:353` in the shutdown test), `:308`, `:328`, `:335`, `:360` (below) |
| `restEndResumeDrop` | the rest's end resumes no publication that waits for it | 3: 2/2 | SharedMoveTests `:244` (`divergencePublishes`: a publication still waits once the follow ended) |
| `drainRestBreakDrop` | the drain's batch goes on after a visit that leaves a rest | 3: 2/2 | SharedMoveTests `:501` (N's 404 does not answer the members), `:502` (N starts twice) |
| `drainRestReinsertDrop` | the rest of the drain's batch is dropped, not put back at the head of `eventsAfterFollow` | 3: 2/2 | SharedMoveTests `:499`, `:501` after the time limit (`:495`; below) |
| `drainRestReturnDrop` | the drain's end schedules no turn for the rest of a visit it made (it settles, pumps or schedules the next drain turn as if the follow had ended) | 3: spun past the time limit and was stopped after 14 minutes (no result); 5 (`3cd80c7`): 2/2 | SharedMoveTests `:495` (the time limit: no turn comes for the rest) and `:465` (the follow does not end within 16 turns) |
| `drainVisitIDsFull` | the drain's visit after a verdict moves every id at once, not a turn's (`followIDsPerTurn` replaced by `Int.max`) | 5: 2/2 | SharedMoveTests `:508` (the ten members leave C in one turn: `[10]`) |
| `restSpendDrop` | the end of a visit's rest does not spend the re-route the visit used (`rerouteOnPass` kept) | 5: 2/2 | StaleRerouteTests `:212`, `:213` (B's and D's waiters get bytes, not C's integrity failure) |
| `shutdownReleaseInboundWaitsDrop` | shutdown resumes no publication's wait | 2: hung (stopped after about 20 minutes); worktree: hung (the filter cut at 900 s; its test helper ran on, still without output, 32 minutes in all) | SharedMoveTests' shutdown test (`:353`): a hang (below) |
| `inboundMadeHolderResumeDrop` | the move off a holder resumes only its target's publication, not the holder's | 4: 2/2 | PublicationHopTests `:197` (both shapes: a publication still waits once the follow ended) |
| `findInboundPendingDrop` | the walk records again the ids an owed move carries | 1: **passed** (filter, and the bundle: 551 tests, 447.034 s); worktree, `951e19f`'s tests: 2/2 | SharedMoveTests `:345` (`convergenceApplies`: v4's walk records a second move of the carried members) |
| `firstInsertDrop` | a holder's second id onto its first target is left out of the move | 4: 2/2 | TwoTargetsTests `:153` (the ids' answers), `:154` (Z1 or Z2 started), `:159` (the moves recorded) |
| `othersSlotInsertDrop` | a second id onto another target is left out | 4: 2/2 | TwoTargetsTests `:153`, `:154`, `:159` |
| `othersAppendDrop` | an id onto a second target is left out | 4: 2/2 | TwoTargetsTests `:153`, `:154`, `:159` |
| `laneCarriedDrop` | `followedLane` reads no owed move's ids (`carried` always `nil`) | 2: 2/2 | PendingLaneTests `:229`, `:231`, `:232` (the 404 test, `owedTurn` and `publicationHeld`) |
| `laneTargetVerdictDrop` | an owed move's job counts by a rule without its waiting verdict | 2: 2/2 | PendingLaneTests `:211` (`Issue.record`), `:217`, `:218`, `:219` (the probe's test, `owedTurn` and `publicationHeld`) |
| `laneHolderRule` | another job's interest an owed move carries counts by its holder's rule, not by the move's job's | 2: 2/2 | PendingLaneTests `:229`, `:231`, `:232` (the 404 test, `owedTurn` and `publicationHeld`) |
| `laneOwnViaTargetDrop` | the job's own interest in an id an owed move carries counts here whatever the move's job's rule | 2: **passed** (filter, and the bundle: 551 tests, 617.352 s); `4d711f2`: 2/2 | PendingLaneTests `:229`, `:231`, `:232` (`owedTurnFromJ`) |
| `keepDrop` | an id of a visit's rest mapped back to the job's content is re-routed, not kept (the first draft's clause) | 1: **passed** (filter, and the bundle: 551 tests, 528.853 s) | **Removed** in `6dda008` ("Removals") |

`shutdownReleaseInboundWaitsDrop` is killed by a hang (S3-R16 1(c)): O's publication waits on a continuation that
only `releaseInboundWaits` resumes, so `engine.shutdown()` never returns, and the time limit's cancellation does not
reach it. Round 2's run printed nothing in about 20 minutes (17:33 to 17:53:17; the test's guard is 3 minutes, and its
four cases took 5.47 and 5.60 s in the Sync bundles of round 2's survivors); the runner and its test processes were
stopped by their PIDs. The second run (`w-hang.sh`, the same edit in the worktree, the filter cut at 900 s) also
printed nothing (`HUNG: no end after 900.0 s`, 17:54:09 to 18:09:09); its test helper had left the process group the
cut killed and was still running, still without output, when found at 18:25:56, and was stopped by its PID at 18:26:20
(32 minutes in all). As in cycle 3, a hang is a kill, with no time-limit line printed.

`inboundBlocksRestDrop` and `drainRestReinsertDrop` also run their tests into the time limit. Unblocked, O's
publication binds at once and never registers the wait the `divergencePublishes` setup waits for; the answers read
after the time limit's cancellation are wrong too. Without the batch put back, N's waiting 404 is dropped with the
drain's other events, so N's waiter and every member wait until the time limit cancels them (`cancelled`, `:499`,
`:501`). `drainRestReturnDrop` schedules no turn for the drain's rest, so `runOneFollowTurn` waits for one until the
time limit's cancellation; from `3cd80c7` the loop around it then fails at its bound (`:465`), and in round 3, before
the bound, the loop spun on after the cancellation (90 to 97 % of a core) until it was stopped.

### Not reached by a test (cycle 19)

- `findInbound`'s target without a checksum and listed entry without a checksum (`byIdentifier`,
  `EngineFollow.swift:1049` and `:1095`). A checksum-less content is keyed by its entry's id and path
  (`TransferID.Kind.legacy`), so the only id the walk can find for it is the target's own entry's id, held by another
  job. The target's job holds that id from its creation until a visit moves it off, which supersedes a job that is not
  publishing, and a visit passes a publishing job, so no path we found leaves the id on another job while the target
  runs; we have not proven there is none. No test builds such a state (every engine test's entries carry checksums,
  `EngineHarness.onDemand`), and the branch differs from the checksum branch only in the key (`sameTransfer` on the
  id's entry). Not tested this cycle.
- `waitingTarget`'s `queued`, `blocked` and `downloading` case: a move's target at the same epoch has its attempt's
  end recorded. A failed publication re-queued meanwhile takes a new epoch at its next start, so the case is reached
  only between that re-queue and that start, which the barrier holds back.
- `scheduleFollowFollowUp`'s unspawnable branch (`releaseInboundWaits`): `spawn` refuses a task only while shutting
  down or degraded, and the engine degrades only while starting, before any apply. During a shutdown, the moves a late
  apply's walk records are dropped in the same turn that records them, so no publication can wait on them.

### Residual risks (cycle 19)

- **RR-19. A publication's wait widens the window in which an apply lands before its bind** (#2;
  PROBE-C18C-PUBLICATION-WAIT-APPLY, seed 1_818_952, 4/4, and -HELD, 2/2). O's publication waits for 8 owed moves, and
  v4 maps zz-o to Z meanwhile: the store refuses zz-o and U follows to Z (48 bytes, `zStarts` 1). A visit-first engine
  serves 16 bytes with v4 after O's commit, and 48 bytes too when v4 lands while O's publication is held at its first
  store unit. Both engines' answers depend on whether the apply lands before the bind; the wait (now also for a
  visit's rest) only widens the window by the follow's move turns. A timing difference (S3-R16 item 2).
- **RR-20. An empty binding after the wait books a commit** (#14; VERIFY-C18R-EMPTY-BINDING, 2/2). When the owed move
  takes the job's only id, the publication then binds nothing yet counts a commit and an object success, its staged
  `.part` stays until staging GC (R-CLN-3), and the free-space estimate drops by its bytes until the next read. The
  answers agree in both orders (W gets `integrityFailure`). The fix the finding proposes (discard the staged file and
  retire the job without a commit) changes the publication path's bookkeeping, outside the answers this close-out
  pins; left for the orchestrator.
- **RR-21. Work not bounded by ids in a turn** (#11; analysis and the cycle-18 verifier's figures): the commit's
  binding of a 10,001-id publication (`committed`, then `resolveAll`/`publishTerminal`: 9.64 ms best at load 3.84, 11.8
  to 12.0 at load 6.7 to 7.0, VERIFY-C18R-CONC-COMMIT), the drain's take-off of a job's moved-before ids before its
  verdict (`takeOffMovedBefore`) and the commit's re-routes of the ids it does not bind. None has a BenchSync case.
  Measured in cycle 20 (S3-R24 item 2; under "Cycle 20", "Open" item 1): the commit window meets C2 (9.81 ms best),
  and the commit's re-routes (48.47 ms best) and the drain's take-off (45.51 ms best) miss it, so both are blocking.
- **RR-22. The order bounded moves re-route in** (order and place only, S3-R16 item 2): a bounded move re-routes by
  (id, token) where `move` goes by (token, id), and a visit's rest moves its ids in later turns than a visit-first
  engine's visit. The jobs the re-routes create are created, and queued, in that order; no answer depends on it, as
  the shared-move cases check in both orders.
- **RR-23. RR-16 followed by an apply that maps the id on** (found while fixing). Moved in cycle 20 under RR-16, in
  "Residual risks (S3-R16; cycle 18)", where its text now stands: ruling S3-R24 item 5 rules it a timing difference in
  RR-16's family, recorded with RR-16 (the cycle-19 requirements verifier's reqs #9).

### Put to the orchestrator (found while fixing; not changed this cycle)

1. **RR-23** (above): an answer difference by the reading of the code, not probed. If a probe shows it, it is blocking
   under S3-R16 1(a), and the fix belongs with RR-16's (the move onto a job that a visit-first engine had superseded).
   Answered by ruling S3-R24 item 5: a timing difference recorded with RR-16, with no probe required; moved there in
   cycle 20.

### Hang guards and re-entrancy

No new `await` in the engine's actor code; one is gone with the removed re-check (`staging?.discard` after the wait).
`awaitInboundMoves` keeps its `// REENTRANCY: RE-S48 (proposed)` comment, and `publish`'s wait re-checks the lifecycle
after it (`guard self.isRunning`). Every new test has `.timeLimit(.minutes(3))`; their times in the Sync bundle runs,
with the loads, are under "Gate evidence (cycle 19)". The time limit's cancellation ends `runOneFollowTurn`'s wait for
a scheduled turn but not a loop around it, so every loop over follow turns in the new tests is bounded by a
`#require` (the drain test's from `3cd80c7`, after `drainRestReturnDrop` spun past the limit without one).

## Cycle 20: the cycle-19 verifiers' findings, and S3-R24 and S3-R25

Cycle 20 applies S3-R24 and S3-R25 (recorded under "Orchestrator rulings (close-out)") to the sixteen findings of the
cycle-19 verifiers (`.build-orchestrator/s3f-c19-issues.json`, on `49a0493`; "correct #n" and "reqs #n" are the
lenses' numbers). Of the eight distinct blocking items, seven are fixed or met as ruled. `waitingTarget`'s case
(reqs #3) is **open**. S3-R24 item 2's measurement made two more items blocking, and both are **open**: the commit's
re-routes of the ids an apply moved away, and the drain's take-off of a job's moved-before ids, miss C2 at a quiet load
(RR-21, under "Open" below). The work went in this order:

1. `8cfc76e`: the failing tests, committed on their own (P3). The first is the drain's bound,
   `barrierBoundsTheDrainsVisitsAfterVerdictsByOneTurnsIDs` (the new `EngineFollowBarrierDrainBoundTests.swift`). It
   failed sweep-first on `49a0493` in both shapes (`.build-s3f/c20/fail-drain2.log`, the committed file): a turn moved
   more than `followIDsPerTurn` (`:191`), and after a rest the batch did not stop once the turn's ids were spent
   (`:196`). The other two are BenchSync's `drainVerdictTurns` and `userSharedApplyTurns`, the
   shapes of the verifier's `VerifyC19DrainBench.swift` and `VerifyC19UserBench.swift`.
2. `e39a076`: the drain case at the verifier's 16-slot shape, at 500 and 625 ids a job. On `49a0493` it measured
   40.79 ms best at 500 a job (load 2.84 to 3.01), and 4.60 ms at 625. The user-waiter shapes measured 32.89 ms best
   (supersede) and 70.82 ms best (keep), at load 10.05 to 11.64 (under "Gate evidence (cycle 20)").
3. `ddb0ba1`: the drain's visits after verdicts share one turn's ids (S3-R25 item 1; correct #1).
4. `f066083`: per-lane interest counts on `Job`, and `dropInterest` in place (item 2; correct #2).
5. `ca6df35`: the turn bound pinned across holders (item 5; reqs #1), and the checksum-less walk target reached (item
   6; reqs #2).
6. `429ace5`, then `bf1d4eb`: first a failing test for an admission whose store calls straddle shutdown's start, then
   its fix. The fix also removes the unspawnable branch, with a `followBarrierViolations` clause in its place (item 7;
   reqs #4).
7. `daa426d`: the flaking test asserts the engine's admission order (item 4; correct #3, reqs #6).
8. `431d397`: a case for the lane read of a verdict whose count caps a user interest (item 10: `keptCapDrop` survived
   mutant round 1).
9. `c2f9e31`: what lands between a bounded move's turns, in both orders (item 8; reqs #5).
10. `c03c0e8`: the commit window pinned, and the commit's and the drain's re-routes measured (S3-R24 item 2; reqs #7).
11. This draft.

### The findings

| Finding | Disposition |
|---|---|
| correct #1 (blocking): a drain batch gave each verdict whose job's ids an apply moved a whole turn's ids (`followAfterVerdict`), so one turn could move 512 ids per verdict (PROBE-C19C-DRAIN-BOUND; 16 slots: 40.79 ms best on `49a0493`) | **Fixed** (`ddb0ba1`) as S3-R25 item 1 says ("What cycle 20 changes"). Pinned twice (S3-R23 item 3). The deterministic pin is `barrierBoundsTheDrainsVisitsAfterVerdictsByOneTurnsIDs`: both orders × two shapes, `followIDsPerTurn` = 4, three verdicts of three ids, every turn within the bound. It fails on `49a0493`, and kills all six drain mutants 2/2, `drainSpentDrop` (the subtraction) among them. The timed pin is BenchSync `drainVerdictTurns` [500, 625]: 4.42 and 4.22 ms best on `ca6df35` (load 3.19 to 6.79). The gate run's figures are under "Gate evidence (cycle 20)" |
| correct #2 (blocking): `Job.lane` and `dropInterest` cost O(interests of the job) per id (PROBE-C19C-USER-SHARED-C2 and -TURNS: 32.89 and 70.82 ms best on `49a0493`) | **Fixed** (`f066083`) as item 2 says. `Job.interestCounts` holds counts per lane, plus the single-user count. `Job`'s mutators keep them on every insert, removal and lane change (`interests` is `private(set)`). `Job.lane` and `isSingleUser` read them in O(1). `dropInterest` changes the job in place. An `invariantViolations()` clause compares the counts with a recount. Every count update's drop-mutant is killed 2/2 ("Mutants"). BenchSync `userSharedApplyTurns` (supersede, keep): 7.42 and 8.64 ms best on `ca6df35` (load 3.19 to 6.79); the gate run's figures are under "Gate evidence (cycle 20)" |
| correct #3 and reqs #6 (blocking): `barrierReadmitsBehindTheOwedVisitsPlaces` flaked under coverage and on the simulator | **Fixed** (`daa426d`) by item 4's first branch. The engine's own admission order was observed first, with each admission's ticket and place, through the seam `EngineState.admissionsForTests` and a temporary print (not committed): 60 of 60 on the simulator (`897F9D8D…`, under `sim.lock`, 30 iterations per argument), and 60 of 60 twice under `--enable-code-coverage`, the second time with the drain's state at N's admission. The engine admitted N first every time, so it is the transport's `.started` records that race after each attempt's store read. The test now asserts the engine's order, with its tuning and scenario unchanged; the old and new assertions are under "Test changes". Of the 28 Sync tests that read the transport's starts, no other asserts their order with more than one attempt in flight (`starts_sweep.py`). The close (30 iterations per argument on the simulator, and the Sync bundle under `--enable-code-coverage` 3 times) is under "Gate evidence (cycle 20)" |
| correct #4 (non-blocking): a holder re-created between a bounded move's turns | **Recorded** (item 9) under "A holder re-created between turns" below. No holder epoch is added |
| correct #5 and reqs #8 (non-blocking): StorageBenchmarks P-13 | **Routed** `other-wp:b`, as in every cycle. No WP-F change |
| correct #6 (non-blocking): `throttleExtensionTurns` missed only under load | **Covered** by S3-R23 item 2. This cycle's figure and its loads are under "Gate evidence (cycle 20)" |
| reqs #1 (blocking): the turn bound across holders was not pinned (`inboundSpentDrop` and `restSpentDrop` survived) | **Met** (`ca6df35`) as item 5 says. `barrierBoundsAnOwedMovesTurnAcrossHolders` and `barrierBoundsARestsTurnAcrossHolders` (the new `EngineFollowBarrierTurnTotalTests.swift`) are the verifier's two shapes, run in both orders. Each counts, per turn, the ids that leave all holders. `inboundSpentDrop`, `restSpentDrop`, `visitSpentDrop` and `continueMoveBudgetDrop` are killed 2/2 |
| reqs #2 (blocking): `findInbound`'s checksum-less lookups were unreached | **Reached** (`ca6df35`) as item 6 says. `barrierWalksOntoAChecksumLessPublication` (the new `EngineFollowBarrierLegacyTargetTests.swift`) builds the probe's shape in both orders, with the owed follow-ups released before or after T's publication resumes. `byIdentifierTargetDrop` and `byIdentifierLookupDrop` are killed 2/2 |
| reqs #3 (blocking): `waitingTarget`'s `queued`, `blocked` and `downloading` case is unreached | **Open** (S3-R24 item 3): this cycle neither reaches it, nor removes it, nor shows it Equivalent. The analysis is under "Open" below |
| reqs #4 (blocking): `scheduleFollowFollowUp`'s unspawnable branch is unreached | **Removed** (`bf1d4eb`), after a failing test (`429ace5`). Trying a shutdown between a follow's turns found one path that started a follow after shutdown began: an unknown-id admission followed the store view it read after its awaits without re-reading the lifecycle. Before the fix (on `429ace5`), `admissionStraddlingShutdownFollowsNothing` (the new `EngineFollowShutdownTests.swift`) failed with 4 issues (`:55`, `:56`, `:57`, `:64`): a later generation announced, a follow started, the copy changed, and no clause. The admission now re-reads the lifecycle after its last await, before it follows the view. With the branch gone, `followBarrierViolations` reports a follow owed while the engine does not run, and the test exercises that clause. The argument over every reset the branch made is under "Removals" |
| reqs #5 (blocking): `continueMove`'s per-interest guards (`EngineMoves.swift:203`, `:206`) and its end re-lane (`:222-223`) were unreached | **Reached** (`c2f9e31`) as item 8 says. `barrierRereadsWhatLandsBetweenABoundedMovesTurns` (the new `EngineFollowBarrierMoveRevalidationTests.swift`) lands three changes between the turns of H's visit, in both orders: a group's release, a purge, and an apply that maps a member back. The drops of `:206` (`moveIDGoneDrop`) and `:222` (`supersedeRelaneDrop`) are killed 2/2. `:203` is reached: `moveInterestGoneReroute`, which re-routes the gone interest, is killed 2/2. Its plain drop, `moveInterestGoneDrop`, is Equivalent: with the token's interest gone, `:205`'s removal finds no interest, so the item is skipped either way (argument under "Mutants") |
| reqs #7 (non-blocking): RR-21, the commit window at 9.76 ms best | **Measured** (`c03c0e8`) as S3-R24 item 2 says. The commit window, 9.81 ms best (load 2.73 to 2.99), meets C2. Two figures miss it: the commit's re-routes of the 10,000 ids moved away, 48.47 ms best (same run), and the drain's take-off and re-route of 10,000 moved-before ids, 45.51 ms best (load 1.90 to 1.94). The gate run measured 9.86, 48.68 and 45.67 ms best, at load 2.21 to 5.59. Both misses are **blocking and open** (S3-R22 item 1; "Open" below) |
| reqs #9 (non-blocking): RR-23 recorded on its own; RR-20's place | **Corrected**. RR-23 moves under RR-16 (S3-R24 item 5), in "Residual risks (S3-R16; cycle 18)". RR-20 stays with the Stage 5 residual risks (item 1) |
| reqs #10 (non-blocking): `EngineMoves.swift:54` and `:87` at 0 hits | **Noted** as structural (S3-R25 item 11): an Optional API's empty case and a sift loop's exit, not decisions, replays or deferrals |

### What cycle 20 changes (`ddb0ba1`, `f066083`, `bf1d4eb`, `daa426d`)

- **The drain's visits after verdicts share one turn's ids** (item 1). `EngineState.drainIDsLeft` holds what the
  drain's turn has left. At the follow's end the drain runs in the follow's last turn, so that turn seeds it with what
  its visits left (`drainEventsAfterFollow(ids: budget.ids)`); a drain follow-up turn seeds it with a whole turn's
  (`followIDsPerTurn`). `followAfterVerdict` visits within what is left, and subtracts what it moved. When nothing is
  left, or a visit left a rest (`followMoving`, cycle 19), the rest of the batch goes back to the head of
  `eventsAfterFollow` with its stamps, in order, for the next drain turn. The events keep their order, so no answer
  changes (S3-R20 item 3).
- **A job's lane is read from per-lane interest counts** (item 2). `Job.interests` is `private(set)`, and only `Job`'s
  mutators change it: `setInterest`, `insertAsset`, `removeAsset`, `subtractAssets`, `setAssets`,
  `removeAllInterests` and `keepInterests`. `setInterest`, `removeAllInterests` and `keepInterests` keep
  `Job.interestCounts` (`InterestCounts`): bulk, prefetch, user-initiated, and the user-initiated interests that are
  not `.ensure`, which `isSingleUser` reads.
  - `Job.lane` is `interestCounts.highest ?? heldLane ?? .bulk`.
  - `dropInterest` changes the job in place, with no copy of it alive across the removal. A copy shares the storage of
    its interests, so the removal used to copy them whole.
  - A retry verdict's answer for each interest (`verdictAnswers` in `EngineFailures`) reads the lane `retryLater`
    reads: the job's, less the interests the count answers. That lane is now `interestCounts.highest {
    !reachesCap($0, attempts:) }`. Before, it walked the job's interests for each interest read, O(interests²) a
    verdict; the inventory found it (item 3).
  - The new invariant: each job's counts equal a recount of its interests.
- **No follow starts once the engine stops running** (item 7). The unknown-id admission (`EngineManifest`) now
  re-reads the lifecycle after `planningView()`, its last await. Once shutdown began it returns before
  `followStoreView` and `noteBound`; until now it re-read the lifecycle only after them. An apply's end and a catch-up
  already re-read it first. `scheduleFollowFollowUp` spawns its task without checking the result, and
  `followBarrierViolations` reports `a follow is owed while the engine is <lifecycle>`.
- **The seam `EngineState.admissionsForTests`** (item 4). It is `nil` by default. A test sets it to `[]` and reads each
  admission (`AttemptAdmission`: transfer, ticket, queue place, attempt) in the engine's order. No production path sets
  it.

### Removals (S3-R19 item 3; S3-R24 item 3)

- **`scheduleFollowFollowUp`'s unspawnable branch** (`bf1d4eb`). It ran when `spawn` refused the follow-up task, which
  `spawn` does only while the engine is shutting down or degraded. The branch reset `followFollowUpScheduled`,
  `followOrder` and `followNext`, `followScans`, `followCarried` and `pumpWaitsForFollow`, and called
  `releaseInboundWaits`, which drops `followMoving` and the owed moves and resumes the publications that waited. Why
  nothing is lost without it:
  - A follow starts only while the engine runs. An apply's end and a catch-up re-read the lifecycle before they
    follow, and since `bf1d4eb` so does the unknown-id admission, the one path that did not
    (`admissionStraddlingShutdownFollowsNothing`).
  - The engine degrades only while starting, before any apply, so no follow is owed then.
  - Shutdown's first turn and the drain after each task it joins (`drainEverything`) drop the job table and redo
    every reset but one: `followOrder`, `followNext`, `followScans`, `followCarried`, `pumpWaitsForFollow` and
    `releaseInboundWaits`.
  - The exception, `followFollowUpScheduled`, needs no reset. A follow-up already scheduled clears the flag, finds the
    engine shutting down and returns at once (`followFollowUp`), and while shutting down nothing new is spawned to wait
    on the flag.
  - `followBarrierViolations` checks the assumption (`!isRunning && followOwed`). The test forces it by setting
    `followOrder = [b]` on the shut-down engine, and reads the one violation.

  `scheduleDrainFollowUp` has an analogous `spawned == nil` branch (`EngineFollow.swift:390`), which this cycle does not
  change. It has 0 hits (under "Not reached and structural lines (cycle 20)").

### Tests added (display names)

- `8cfc76e`, the new `EngineFollowBarrierDrainBoundTests.swift`: "R-SYN-6: the drain's visits after the verdicts that
  waited move at most followIDsPerTurn ids a turn together, with the visit-first answers (C2, F-28)" (`LaneDropVisit`
  × `DrainBoundShape`: `verdicts`, `verdictsAfterARest`).
- `f066083`, the new `EngineInterestCountsTests.swift`: "R-SYN-3: a job's lane and single-user rank, read from its
  interest counts, follow every change to its interests"; "R-SYN-3: removing every interest of a job, or keeping some,
  leaves the counts of the interests it holds"; "R-SYN-5: the highest lane among the admitted ones is read from the
  counts".
- `ca6df35`, the new `EngineFollowBarrierTurnTotalTests.swift`: "R-SYN-6: the follow's turns that make owed moves off
  two holders each move at most followIDsPerTurn ids across both, with the visit-first answers (C2, F-28)"; "R-SYN-6:
  the follow's turns that end a visit's rest and visit further holders each move at most followIDsPerTurn ids across
  them, with the visit-first answers (C2, F-28)" (both over `LaneDropVisit`).
- `ca6df35`, the new `EngineFollowBarrierLegacyTargetTests.swift`: "R-SYN-6: an apply's walk moves an id onto a
  publishing checksum-less content's job, with the visit-first answers (F-28)" (`LaneDropVisit` × follow-ups released
  first or last).
- `429ace5`, the new `EngineFollowShutdownTests.swift`: "R-SYN-15: an unknown-id admission whose store calls straddle
  shutdown's start follows no store view and starts no follow (F-28)".
- `431d397`, in `EngineFollowBarrierVerdictAnswersTests.swift`: the case "503 after 120 s, U at its cap".
- `c2f9e31`, the new `EngineFollowBarrierMoveRevalidationTests.swift`: "R-SYN-6: what a release, a purge or an apply
  changes between a bounded move's turns is read again, with the visit-first outcome (F-28)" (`LaneDropVisit` ×
  `MoveRevalidationShape`: `groupReleased`, `memberPurged`, `mappedBack`).
- BenchSync (release, best of 3 against `c2Budget`, loads beside every figure):
  - `8cfc76e` and `e39a076`: "R-SYN-6: the drain's visits after 16 waiting verdicts that move their members off their
    jobs hold the engine's actor at most C2's 10 ms per turn" ([500, 625]).
  - `8cfc76e`: "R-SYN-6: an apply that moves 10,000 ids sharing one content, each with a user-initiated waiter, holds
    the engine's actor at most C2's 10 ms per turn" (`UserSharedShape`: supersede, keep).
  - `c03c0e8`: "R-SYN-11: the commit of a publication whose 10,000 converged ids an apply moved away re-routes them
    holding the engine's actor at most C2's 10 ms per turn", and "R-SYN-11: the drain's verdict on a job holding 10,000
    ids moved off it before the verdict and back holds the engine's actor at most C2's 10 ms per turn". These are the
    two that miss: they stay as they are and fail until RR-21 is fixed (G4: a pin that fails is the record).

### Test changes (G3 one-to-one; S3-R16 item 4)

1. `EngineFollowBarrierReplayTests.swift`, `barrierReadmitsBehindTheOwedVisitsPlaces` (`daa426d`; item 4).
   - Old: `#expect(started.first == n.transferID, "N, queued at P's visit, starts before the members the follow-up
     re-queues (visit-first): …")`.
   - New: `#expect(admitted.first?.transfer == n.transferID, "N, queued at P's visit, is admitted before the members
     the follow-up re-queues (visit-first): …")`, where `admitted` is the engine's admissions
     (`admissionsForTests = []` is set before the apply), plus `#expect(Set(admitted.map(\.transfer)) ==
     others.union([n.transferID]), …)`.
   - The assertion on the set of starts is unchanged, and so are the tuning, the scenario and the doc comment's
     premise. The comment now says why the order is the engine's.
2. `EngineFollowBarrierVerdictAnswersTests.swift` (`f066083`, `431d397`).
   - `job.interests[token] = interests[token]` (`:55`) becomes `job.setInterest(interests[token], for: token)`.
   - The three `job.interests[x] = JobInterest(…)` lines (`:154-156` on `49a0493`) become
     `job.setInterest(JobInterest(…), for: x)`, with the same values. The property is `private(set)` now, and the
     mutator keeps the counts.
   - The case "503 after 120 s, U at its cap" is added, so `#expect(cases.count == 49, …)` becomes `== 52`.
3. `EngineRegressionCycle16Tests.swift:472`: `job.interests[InterestToken(rawValue: 1)] = JobInterest(…)` becomes
   `job.setInterest(JobInterest(…), for: InterestToken(rawValue: 1))`, with the same interest.
4. `EngineSafetyTests.swift:134`: `state.jobs[…]?.interests.removeAll()` becomes
   `state.jobs[…]?.removeAllInterests()`.
5. `EngineOutcomeTests.swift`, `invariantOracle`: the orphaned case's `interests.removeAll()` becomes
   `removeAllInterests()`, and a `miscounted` expectation is added for the counts clause.
6. BenchSync's `concentrationPublicationTurns` (`c03c0e8`; S3-R24 item 2). The case now goes on through the commit:
   `concentrationTurns(.publication, label:)` becomes `concentrationTurns(.publication, commit: .bound, label:)`, and
   its display name says "begins and commits". The wait it checks spans both the publication's start and its commit,
   so the old check is kept and extended.

None of these removes or weakens an assertion. The mutator changes write the same interests through the API that
keeps their counts.

### Mutants (S3-R16 1(e); S3-R25 items 1, 2, 5 to 8 and 10)

The runner is `.build-s3f/c20/mut.py`. It works on a copy of `Sources` and `Tests` (`.build-s3f/mutsrc`) built in
`.build-s3f/mutbuild`, never in place. Each mutant runs its filter twice. A mutant that survives its filter also runs
the whole Sync bundle (`full1`, then `full2`). Every round ends with the copy reverted, and `diff -r` against the
worktree's `Sources` was empty. Round 1's diff showed one line, the admission record (`daa426d`): it was written in
the worktree while that round ran, after the copy had been made.

The loads, as the 1-minute average across each round: round 1, 27.98 down to 1.95; round 2, 17.64 to 9.62; round 3,
3.62 to 3.26; round 4, 13.57 to 2.79. These are kill or survive results, not timings.

| Mutant (round) | What it changes | Result | Killed at |
|---|---|---|---|
| `drainSpentDrop` (1) | `followAfterVerdict` leaves `drainIDsLeft` unspent | killed 2/2 | `EngineFollowBarrierDrainBoundTests.swift:191`, `:196` |
| `drainSeedFull` (1) | the follow's last turn seeds the drain with a whole turn | killed 2/2 | `:191`, `:196` |
| `drainSpentBreakDrop` (1) | the batch goes on with the ids spent | killed 2/2 | `:196` |
| `drainBoundLt` (1) | `<= 0` becomes `< 0` | killed 2/2 | `:196` |
| `drainVisitIDsFull` (1) | each verdict's visit gets `followIDsPerTurn` | killed 2/2 | `:191`, `:196` |
| `drainFollowUpSeedZero` (1) | a drain follow-up turn seeds 0 ids | killed 2/2 | `:196` |
| `countInsertDrop` (1) | an inserted interest is not counted | killed 2/2 | `EngineInterestCountsTests.swift:108`, `:115` |
| `countRemovalDrop` (1) | a removed interest is not uncounted | killed 2/2 | `EngineInterestCountsTests.swift:51`, `:52` |
| `countLaneChangeDrop` (1) | a replaced interest keeps the old count | killed 2/2 | `EngineInterestCountsTests.swift:51`, `:52` |
| `countInsertDropEngine` (1) | as `countInsertDrop`, against the engine suites | killed 2/2 | `EngineFollowTests.swift:1022`, `:1044` |
| `countRemovalDropEngine` (1) | as `countRemovalDrop`, against the engine suites | killed 2/2 | `EngineFollowTests.swift:1022`, `:1057` |
| `countRemoveAllDrop` (1) | `removeAllInterests` keeps the counts | killed 2/2 | `EngineInterestCountsTests.swift:117`, `:118` |
| `countKeepRecountDrop` (1) | `keepInterests` keeps the old counts | killed 2/2 | `EngineInterestCountsTests.swift:111`, `:112` |
| `countSingleUserDrop` (1) | the single-user count is not kept | killed 2/2 | `EngineInterestCountsTests.swift:108`, `:52` |
| `countsClauseDrop` (1) | the counts clause reports nothing | killed 2/2 | `EngineOutcomeTests.swift:457` |
| `keptCapDrop` (1) | the kept lane ignores the cap (`highest` alone) | **survived** filter and `full1` | — (round 2 below) |
| `dropHeldLaneDrop` (1) | `dropInterest` leaves `heldLane` unset | killed 2/2 | `EngineClaimRetryTests.swift:40`, `EngineGroupClaimTests.swift:341` |
| `inboundSpentDrop` (1) | `continueInbound` leaves the turn's ids unspent | killed 2/2 | `EngineFollowBarrierTurnTotalTests.swift:106` |
| `restSpentDrop` (1) | `continueVisitRemainder` leaves them unspent | killed 2/2 | `EngineFollowBarrierTurnTotalTests.swift:199`, `:200` |
| `visitSpentDrop` (1) | the visits leave them unspent | killed 2/2 | `:199`, `:200` |
| `continueMoveBudgetDrop` (1) | `continueMove` ignores its budget | killed 2/2 | `EngineFollowBarrierTurnTotalTests.swift:104`, `:106` |
| `byIdentifierTargetDrop` (1) | a checksum-less target is not keyed | killed 2/2 | `EngineFollowBarrierLegacyTargetTests.swift:70` |
| `byIdentifierLookupDrop` (1) | a checksum-less listed entry finds no target | killed 2/2 | `:70` |
| `keptCapDrop` (2, after `431d397`) | as in round 1 | killed 2/2 | `EngineFollowBarrierVerdictAnswersTests.swift:133` |
| `moveIDGoneDrop` (2) | `:205-206`: an interest without the id is re-routed anyway | killed 2/2 | `EngineFollowBarrierMoveRevalidationTests.swift:212` |
| `supersedeRelaneDrop` (2) | `:222`: no re-lane at the superseding move's end | killed 2/2 | `EngineFollowBarrierMoveRevalidationTests.swift:223` |
| `moveInterestGoneReroute` (2) | `:202-206`: a gone interest is re-routed on a stand-in interest | killed 2/2 | `EngineFollowBarrierMoveRevalidationTests.swift:213` |
| `moveInterestGoneDrop` (2) | `:202-203`: a gone interest gets a stand-in, then reaches `:205` | **survived** filter and `full1`: **Equivalent** | — |
| `admissionGuardDrop` (3) | the admission does not re-read the lifecycle | killed 2/2 | `EngineFollowShutdownTests.swift:55`, `:56`, `:57` |
| `admissionGuardBack` (3) | the re-read goes back after `followStoreView` (`49a0493`'s order) | killed 2/2 | `:55`, `:56`, `:57` |
| `followOwedClauseDrop` (3) | the follow-owed clause reports nothing | killed 2/2 | `EngineFollowShutdownTests.swift:64` |
| `highestUserDrop` (4) | `highest` skips the user lane | killed 2/2 | `EngineInterestCountsTests.swift:108`, `:112` |
| `highestPrefetchDrop` (4) | `highest` skips the prefetch lane | killed 2/2 | `EngineInterestCountsTests.swift:114`, `:133` |
| `highestBulkDrop` (4) | `highest` skips the bulk lane | killed 2/2 | `EngineInterestCountsTests.swift:130`, `:137` |
| `highestUserGe` (4) | `userInitiated > 0` becomes `>= 0` | killed 2/2 | `EngineInterestCountsTests.swift:114`, `:118` |
| `highestAdmitsDrop` (4) | the user lane is taken without `admits` | killed 2/2 | `EngineFollowBarrierVerdictAnswersTests.swift:133` |
| `countBulkDrop` (4) | the bulk count is not kept | killed 2/2 | `EngineInterestCountsTests.swift:130`, `:137` |
| `countPrefetchDrop` (4) | the prefetch count is not kept | killed 2/2 | `EngineInterestCountsTests.swift:114`, `:133` |
| `countUserDrop` (4) | the user-initiated count is not kept | killed 2/2 | `EngineInterestCountsTests.swift:108`, `:112` |
| `singleUserGe` (4) | `singleUser > 0` becomes `>= 0` | killed 2/2 | `EngineInterestCountsTests.swift:112`, `:118` |
| `laneHeldDrop` (4) | `Job.lane` ignores `heldLane` | killed 2/2 | `EngineGroupClaimTests.swift:341` |
| `admissionRecordDrop` (4) | the admission is not recorded | killed 2/2 | `EngineFollowBarrierReplayTests.swift:97`, `:98` |
| `purgeSubtractDrop` (4) | a purge leaves the withdrawn ids on the interest | survived its filter; killed by `full1` and `full2` | `EngineFollowBarrierMoveRevalidationTests.swift:212` |

That is 42 mutants: 40 killed 2/2 (`keptCapDrop` from round 2, `purgeSubtractDrop` by the whole bundle twice) and one
Equivalent (`moveInterestGoneDrop`).

- **`moveInterestGoneDrop` is Equivalent** (S3-R19 item 2). With the token's interest gone, the mutant reads a
  stand-in interest and goes on to `:205`. There `removeAsset(asset, for: token)` finds no interest under the token,
  returns `false`, and the item is skipped. That is exactly what `:203`'s `continue` does, so no decision, answer or
  state differs. `:203` is still reached: `moveInterestGoneReroute` drops both guards, re-routes the gone interest, and
  is killed 2/2 at `:213`. The two guards stay, as item 8 says, and `:205`'s removal is what decides once the
  interest is gone.

### The C2 inventory (S3-R25 item 3)

Every operation the follow's turns and the drain do per id or per event. "Ids" means the turn's ids, at most
`followIDsPerTurn` (512); N is a job's ids, I a job's interests, E the events waiting. The reference set is 10,000 ids,
however their interests are grouped (item 2). The figures are the gate run's (under "Gate evidence (cycle 20)") unless
a commit is named.

| Operation | Cost | Bound or figure | Status |
|---|---|---|---|
| The follow's passes over the copy (`continueFollow`'s scans) | at most 16,384 entries and 2,048 formats a turn (`followScansPerTurn`, `followFormatsPerTurn`) | bounded a turn; `concentrationNotFoundTurns` | met |
| A visit's filter of the job's ids the copy moved (`rerouteOnVisit`) | O(N) once a visit; ≤ 10,000 a turn over the visits | `sharedApplyTurns`, `divergenceTurns` | met |
| `startMove` building a move's items | O(moved ids) once a move | `sharedApplyTurns`, `inboundHolderTurns` | met |
| `continueMove`, `continueInbound` (its intersection at the move's first turn), `continueVisitRemainder` | O(log ids) a moved id; at most `followIDsPerTurn` ids and `followsPerTurn` holders a turn | the turn-total tests; `sharedApplyTurns`, `divergenceTurns`, `inboundHolderTurns` | met |
| `move` (a move that fits the turn's ids) | sorts each interest's whole ids: O(N log N) a holder, ≤ 10,000 ids a turn over the holders | no figure of its own (inside the shared cases' visits) | no figure: put to the orchestrator |
| The walk for the publications in flight (`findInbound`) | one pass over the jobs' ids, one lookup each | `inboundWalkTurns`, `concentrationNotFoundTurns` | met |
| `reroute`, `addInterest` (a join in place) | O(1) amortised an id | `concentrationFollowTurns`, `sharedApplyTurns` | met |
| `removeInterest`, `dropInterest`, `relane`, `Job.lane`, `isSingleUser` | O(1) an id (`f066083`) | `userSharedApplyTurns`: 7.18 ms best (supersede) and 8.01 (keep) | met |
| `deferBehindVerdict` (a visit's join behind a waiting verdict) | O(E) a call (a `lastIndex` scan and an insert) | no figure | no figure: put to the orchestrator |
| The drain's events (`drainEventsAfterFollow`) | at most `eventsAfterFollowPerTurn` (512) events a turn; their visits after verdicts share the turn's ids (`ddb0ba1`) | `drainVerdictTurns` [500, 625]: 4.13 and 4.08 ms best | met |
| A retry verdict's answer for each interest (`verdictAnswers`, the lane `retryLater` reads) | O(1) an interest, O(I) a verdict (`f066083`); O(I²) a verdict before | O(1) amortised an id | met |
| `followedLane` | O(I) a call | the 429 case of R-SYN-5, `concentrationNotFoundTurns` | met |
| `recordDeferredVerdict`'s and the publication start's `away` filters | O(N) once an event | inside `concentrationPublicationTurns` (the start) | met at the start; the verdict's has no figure |
| The commit's binding (`committed`, then `resolveAll`, `publishTerminal`) | O(N log N) once a commit | `concentrationPublicationTurns` through the commit: 9.86 ms best (9.81 at load 2.73 to 2.99 before `c03c0e8` was committed) | met, by 0.14 ms |
| The commit's re-routes of the ids an apply moved away (`committed`) | O(N) in one turn | `concentrationCommitRerouteTurns`: 48.68 ms best (48.47 before `c03c0e8` was committed) | **miss: blocking, open** |
| `replayVerdict`'s take-off and re-route of a job's moved-before ids (`takeOffMovedBefore`, `rerouteMovedBefore`; also the `.spaceFailure` replay) | O(N) in one turn | `movedBeforeDrainTurns`: 45.67 ms best (45.51 before `c03c0e8` was committed) | **miss: blocking, open** |
| `supersede` of a superseded publication (`publicationFailed`'s `.superseded`) | O(N) re-routes in one turn | no figure; outside the follow and the drain | no figure: put to the orchestrator |

### A holder re-created between turns (correct #4; S3-R25 item 9)

- **The case.** `continueMove` re-reads its holder by `TransferID`, which is derived from content. A job removed
  between two turns of its move and created again for the same content is found under the same key. The moves left
  (`MoveProgress`'s (id, token) items) then name the old job's interests.
- **Why the per-interest guards make the stale items no-ops.**
  - Tokens come from a counter (`EngineLifecycle`, `lastToken`), one per registration, so the re-created job holds an
    interest under an item's token only if that same registration's interest came back onto the content. An item
    whose token is not there is skipped at `:202-203`. One whose interest no longer holds the id is skipped at
    `:205-206`.
  - An item passes both guards only if the re-created holder holds that same interest in that same id. Then `reroute`
    moves it under the current copy, as the re-created job's own visit would. If the copy maps the id to this content
    again, `reroute` re-joins it here (`addInterest`), so the job keeps it.
  - Behind the barrier no join adds a new interest in an id of the rest: every join but the follow's own waits
    (`addInterest`'s `.join` events), and the drain that replays them waits until the rest is done (`followOwed`
    covers `followMoving`). So the interests in a rest's id are its items' tokens until the rest moves the id.
  - No holder epoch is added (S3-R25 item 9).
- **An observation, not probed.** `continueMove` removes the id from the holder's ids (`Job.assets`, `:195`) at the
  item's first interest, before the guards. The removal can matter in only one state: the holder holds the id under a
  token that is not among its items, and every item of the id is stale. That needs the same id on two jobs at once
  (a publishing job's id can be, as in the checksum-less test). It also needs that job's visit, under a later apply,
  to move the id's interest onto the re-created holder, and every item's interest to have left meanwhile. No path
  that builds this was found, and none was tried. It is put to the orchestrator with that shape.

### Not reached and structural lines (cycle 20)

The counts are from the gate run's coverage (`.build-s3f/c20/gates/cov.profdata`, every bundle but the benchmarks, on
`c03c0e8`).

- **This cycle's changed lines.** `.build-s3f/c20/covdiff20.py` is the verifier's `reqs/covdiff.py`, adapted to this
  scratch path and to `49a0493..HEAD`. Over every line changed in `Sources` it finds no zero-count line:
  `EngineCommands.swift` 12, `EngineDispatch.swift` 4, `EngineFailures.swift` 6, `EngineFollow.swift` 30,
  `EngineJobs.swift` 11, `EngineManifest.swift` 9, `EngineMoves.swift` 2, `EnginePresence.swift` 1 and
  `EngineState.swift` 175 changed lines, 0 at zero count in each (S3-R25 item 10).
- **Item 8's lines are reached.** `EngineMoves.swift:203` has 7 hits, `:206` has 1 and `:222` has 1; their mutants are
  under "Mutants".
- **Structural lines.** `EngineMoves.swift:54` (`MoveProgress.popFirst`'s `return nil`) and `:87` (the sift loop's
  exit) have 0 hits (reqs #10, S3-R25 item 11).
- **`waitingTarget`'s case is unreached.** `EngineFollow.swift:1261`, the `return nil` of `queued`, `blocked` and
  `downloading`, has 0 hits ("Open" item 2).
- **`scheduleDrainFollowUp`'s unspawnable branch is unreached.** `EngineFollow.swift:391-398` has 0 hits (its `if` at
  `:390` has 21). It is the analogue of the branch removed under "Removals". This cycle does not change it, and it is
  not on S3-R24 item 3's list; it is put to the orchestrator.

### Open (blocking; not fixed this cycle)

1. **RR-21's two misses** (S3-R24 item 2; S3-R22 item 1), at a quiet load, best of 3:
   - The commit's re-routes: `committed` re-routes, in one turn, every interest in an id the publication does not
     bind because an apply moved it away. That was 48.47 ms best for 10,000 ids, at a 1-minute load of 2.73 to 2.99.
   - The drain's take-off: `replayVerdict` takes a job's moved-before ids off before its verdict
     (`takeOffMovedBefore`) and re-routes them after it (`rerouteMovedBefore`), each in one turn. That was 45.51 ms
     best for 10,000 ids, at a 1-minute load of 1.90 to 1.94.
   - The gate run on `c03c0e8` measured 48.68 and 45.67 ms best, at a 1-minute load of 2.21 to 5.59 (under "Gate
     evidence (cycle 20)").

   The fix was not attempted this cycle. Both re-routes must keep the visit-first answers while they span turns
   (S3-R20 item 3), and the state they would leave between turns needs its own invariants. The proposed design, put
   to the orchestrator:
   - **Turn the owed re-routes into drain events.** A `.reroutes(batch)` event carries the (token, id) pairs and the
     copy that found them, and is queued where the re-routes are made now. Each drain turn spends at most
     `drainIDsLeft` of them.
   - **Keep a limbo index.** It records the interests taken off a job and not yet re-routed, so the invariants (a
     waiter's interest, a group's members, the run's claims) accept them while they are owed. `followedLane` counts
     them by the rule of the job they left, as it does for an owed move's ids.
   - **Hold a publication while re-routes are owed.** `inboundBlocks` makes a publication wait while re-routes onto
     or off its job are owed, as it does for the owed moves.
   - **Decide each re-route under its event's copy.** The decision T21 reads is made under the copy the event
     carries, and the join under the copy current at the re-route.
   - **Clear and seam them like the owed moves.** Shutdown drops them, and the seam `rerouteIDsPerTurn` lets a test
     count them per turn.
   - **Extend the same treatment to the O(N) `supersede` row** of the inventory.

   The pins would be S3-R23 item 3's two: a deterministic per-turn count with the bound's drop-mutant, and the two
   BenchSync cases above, best of 3, at most `c2Budget`.
2. **`waitingTarget`'s `queued`, `blocked` and `downloading` case** (reqs #3; S3-R24 item 3). Not reached by a test,
   not removed, and not shown Equivalent:
   - `downloading` at the move's epoch cannot happen. A move is recorded at its target's attempt end, and only a new
     attempt's start makes the job download again, and that start gives it a new epoch (`Job.epoch`).
   - `blocked` at the move's epoch comes only after the `queued` case below. A job leaves its attempt's end for
     `blocked` only through a park. The parks that act on a job at its attempt's end are verdicts, and they wait in
     the drain while a move is owed. A queued job's parks (the admission gate, a space sweep) need the `queued` case
     first.
   - `queued` at the move's epoch happens on one path: the ENOENT re-queue of a drained publication
     (`publicationFailed`, `.fileSystem(.notFound)` with `cancelledAttempt`). That re-queue also happens behind the
     barrier, and the job keeps its epoch until its next start, which the barrier holds back. In that window,
     `continueInbound` drops the move (`waitingTarget` is `nil`), and the holder's own visit later moves the id. On a
     visit-first engine, the id would already be on the target, so the difference is only the job the id waits on
     until the visit, and its place and ticket. By the reading of `followedLane`, the id counts by its holder's rule
     there (`carried` is `nil`), the rule its holder's visit moves it by, and the queued target has no verdict waiting
     to differ.

   This is a reading of the code. No test builds the window this cycle (a drained attempt's publication failing with
   ENOENT while a move onto its job is owed and the follow's turns are held), so it is neither Reached nor proven
   Equivalent: in `continueInbound` the case changes order and tickets, so it is not Equivalent under S3-R19 item 2's
   "no state" either. Put to the orchestrator: reach it with that shape (the fakes can fail a publication with ENOENT
   after a cancelled attempt's staging, as `EngineRaceTests` does) and kill its drop-mutant, or rule the
   order-and-ticket difference a residual risk (S3-R16 item 2).

### Residual risks (cycle 20)

- **RR-21** (rewritten): see "Open" item 1. The commit window itself meets C2, at 9.86 ms best in the gate run (9.81
  before). The commit's re-routes and the drain's take-off miss it, and both are blocking. RR-21 is a residual risk
  no longer; it stays listed until it is fixed.
- **RR-20** stays with the Stage 5 residual risks (S3-R24 item 1), as written under "Cycle 19".
- **RR-23** is recorded with RR-16 (S3-R24 item 5), under "Residual risks (S3-R16; cycle 18)".
- No new residual risk. `waitingTarget`'s window is open, not a residual risk, unless the orchestrator rules it one.

### Put to the orchestrator (found while fixing; not changed this cycle)

1. RR-21's design ("Open" item 1).
2. `waitingTarget`'s window ("Open" item 2).
3. The inventory rows with no figure: `move`'s sort of a holder's interests, `deferBehindVerdict`'s O(E) scan,
   `recordDeferredVerdict`'s filter, and `supersede` of a superseded publication. Each is not O(1) amortised per id
   and has no BenchSync case at 10,000 (S3-R25 item 3).
4. `continueMove`'s removal of the id from `Job.assets` before the per-interest guards ("A holder re-created between
   turns").
5. `scheduleDrainFollowUp`'s `spawned == nil` branch (`EngineFollow.swift:391-398`, 0 hits in the gate run's
   coverage), the analogue of the removed one: removal with a clause, as under "Removals", or a test that reaches it.

### Hang guards and re-entrancy

No new `await` in the engine's actor code. The admission's lifecycle re-read moved up to its last await, and its
`// REENTRANCY: RE-S37` comment says what is re-validated after it (the lifecycle, before the view is followed). Every
new test has `.timeLimit(.minutes(1))` (the shutdown test) or `.timeLimit(.minutes(3))`. Every loop over follow turns
is bounded by a `#require` (8 or 16 turns). The tests' times in the gate run's Sync bundle runs, with the loads, are
under "Gate evidence (cycle 20)". `shutdownReleaseInboundWaitsDrop` is still killed only by a hang. The new shutdown
test does not involve inbound waits, so it does not kill it either (S3-R25 item 11).

## Items

### S3F-1 [BLOCKING] S3-CONC-04 — a satisfied first conditions reading is an edge — **Fixed**

*Ruling:* a satisfied FIRST conditions reading counts as an edge for work that failed offline while no reading existed
(hunter's option 1 or 2); both probes become regression tests; propose the note beside PROBE-C9C-3's rule in §7.6.

- **Choice: option 1.** `apply` (`EngineConditions.swift`) now counts a satisfied reading with no previous reading as an
  edge (`previous.map { … } ?? true`). It covers both orders of the window: a failure that came before the first reading
  is re-queued by the edge's pass (`edgeOwed`), and a failure that arrives after it is retried at once by PROBE-C9C-3's
  rule, because the attempt recorded `networkEdgeSerial` before the reading bumped it. Option 2 (mark the job owed when
  it fails with `conditions == nil`) misses the second order. With nothing failed the edge re-queues nothing; a pending
  run waiting for an edge keeps the watcher (`hasWork`), so its first reading is never this one, and F-16's one-retry
  bound is unchanged (`offlineRunsWithoutEdge` is only reset by a first reading after an idle teardown, at most once per
  idle period: bounded, not polling).
- **Tests** (`Tests/ZTronAssetSyncTests/Engine/EngineFirstReadingTests.swift`, `extension EngineConditionsTests`; the
  probes' `GatedConditionsSource` lives there):
  - `R-SYN-13: an asset that failed offline before the engine's first conditions reading is retried once that reading shows a satisfied path` (the hunter's probe);
  - `R-SYN-13: an offline failure that arrives after the engine's first conditions reading showed a satisfied path is retried at once` (the second order);
  - `R-SYN-13: an unsatisfied first conditions reading retries nothing and the satisfied reading after it retries the asset once` (the confirmer's control).
- **Evidence.** Failing first (`c1cf975`) on `s3-base` code: `EngineFirstReadingTests.swift:158:9: Expectation failed:
  after != .failed(.whenOnline)` and `:186:9: Expectation failed: (try? answer.get()) != nil`; fix `a6457b8`; all three
  pass, Sync 354/354 at that commit.

### S3F-2 [BLOCKING] S3-STAB-03 — TSan hang guards — **Fixed (guards sized from measurements, steps made cheaper)**

*Ruling:* apply S3-R4 to `randomOperations` and the near misses; measure each under TSan alone and with a second TSan
process; make steps cheaper where possible; raise a guard only with measurements; the model loop checks
`Task.isCancelled` per operation.

- **Cheaper steps.** `EngineHarness.idleViolations()` returns in one engine hop (no store read) when the engine is not
  settled (it was three hops after each of the walk's 10,000 operations; the assertions are the same, read in the first
  hop). `R-CAR-4`'s join wait reads the job count before checking each member, O(1) per engine mutation instead of
  O(members): 14.8 s → 7.4 s beside the suite, 31.6–31.9 s → 16.9–17.0 s paired.
- **Cancellation.** The model walk checks `Task.isCancelled` before each operation; the two launch loops call
  `Task.checkCancellation()` per launch; the 2,000-round observation window stops at cancellation.
- **Measurements** (TSan build `.build-s3f-tsan`, whole `ZTronAssetSyncTests` bundle run directly, `.build-s3f/run-direct.sh`):

  | Test | alone in the suite, before → after | paired (2 TSan processes), before → after | guard |
  |---|---|---|---|
  | `R-SYN-2: 10,000 seeded random operations …` (`EngineModelTests.randomOperations`) | 29.8 → 29.5 s (8.0 s with only it) | 58.4/58.8 → 59.2/59.4 s | **5 min** |
  | `R-STO-11: ensureAvailable right after start, beside a legacy migration …` | 21.4 → 21.8 s | 44.9/45.2 → 49.0/49.6 s | **3 min** |
  | `R-STO-11: a user-initiated prefetch group joined right after start, …` | 22.4 → 22.8 s | 45.1/45.7 → 49.7/50.5 s | **3 min** |
  | `R-SYN-14: while a job's adoption holds the last claimed prior-art file …` | 18.2 → 16.3 s | 37.8/37.8 → 37.4/37.7 s | **3 min** |
  | `R-SYN-6: a run whose parked claim a re-admission turn still owes …` (`EngineRegressionCycle16Tests.swift:31`) | 18.2 → 16.4 s | 37.8/39.7 → 36.6/38.5 s | **3 min** |
  | `R-CAR-4: a join's give-up of more than releasesPerTurn claims …` (`EngineGroupClaimTests.swift:387`) | 14.8 → 7.4 s | 31.6/31.9 → 16.9/17.0 s | **1 min (kept)** |

  Loads: before, alone 14.7–28.1, paired 24.1–30.1; after, alone 19.8–27.2, paired 27.2–43.1. The paired run takes
  each raised test above half its limit (the ruling's condition); R-CAR-4 is now below half and keeps `.minutes(1)`.
- **Commit:** `0b76e30` (each raised guard's doc comment carries its measurements).
- **Cycles 4 to 8:** further guards sized from measurements (each cycle's "Hang guards" entry); in cycle 8 the margins of
  `stalledSubscriberIsBounded` and S1-15's run test at a paired load of about 30 are referred to the orchestrator
  (ruling requested; "Cycle 8").

### S3F-3 [BLOCKING] S3-CONF-03 — a run over an asset failed at the integrity cap — **Fixed (test)**

*Ruling:* the run must not end `.complete` and must not write the stamp; the dropping mutant must fail it.

- **Test** (`EngineRunIntegrityCapTests.swift`, `extension EngineFailurePathTests`): `R-SYN-6: a run over an asset failed
  at the integrity cap ends completeWithFailures with an integrity failure for it`; beyond the probe it asserts
  `failedCount == 1` and that the store's sync stamp is unchanged (`StorePlanningView.stamp`). Production unchanged.
- **Mutant (S3-R3)**, `S3-CONF-03.mutant.diff` in the scratch copy: `✘ … recorded an issue at
  EngineRunIntegrityCapTests.swift:40:25: Issue recorded` (the run ended `.complete`). Commit `0140b37`.

### S3F-4 [BLOCKING] S3-PERF-01 — shutdown at 10,000 — **Fixed**

*Ruling:* bound the teardown per turn (S3-R5), also on the rootVanished reopen path; `BenchSync` benchmark beside
`handleReleaseTurns`.

- **Fix** (`EngineShutdown.swift`, new; `EngineLifecycle.performShutdown`): (1) handles are cancelled over `inFlight`
  (only a downloading job has an attempt, and every downloading job is in flight), not over the job table sorted twice;
  (2) `drainEverything(with:)` moves every continuation table and catalog-sized table out of the state in O(1) per
  table (the small joiner tables are still answered at once); (3) `settle(_:with:)` answers the waiters and the groups and
  frees the job table at most `shutdownStepsPerTurn` (512) steps per turn, a `Task.yield()` between slices; the drain is
  a `consuming` parameter and each table is swapped out of it, so removals free entries instead of copying the table.
  The rootVanished reopen path calls the same `performShutdown`. New REENTRANCY row **RE-S43 (proposed)**.
- **Benchmark:** `R-SYN-15: shutting down under a 10,000-member prefetch group and 10,000 waiting resolves holds the
  engine's actor at most C2's 10 ms per turn and answers every waiter shutDown` (`BenchSync.shutdownTurns`, production
  dispatch executors). Before (`ef5c81a`, load 17.7–19.7): runs [33.77, 22.05, 28.16] ms, group alone [25.00, 20.87,
  26.39] ms, `BenchSync.swift:250:13: Expectation failed: (runs.min() ?? .infinity) <= Self.c2Budget`. After (`523f9b1`,
  load 21.1→12.4): runs [1.48, 1.36, 1.41] ms, 1,000: 0.20 ms, group alone [0.63, 0.62, 0.62] ms; the control
  `handleReleaseTurns` 4.10–4.84 ms in the same run.
- **Structural test:** `R-SYN-15: a shutdown over more waiters and jobs than one turn takes answers every waiter shutDown
  and leaves the engine owning nothing` (`EngineShutdownDrainTests.swift`): 600 waiters and jobs; the drain takes every
  waiter, job and group and leaves none in the state; every waiter is answered `shutDown` once; no owned task remains.
  Cycle 2 (`243c6da`): the same test now pins the bound itself through the settle's recorded slices
  (`EngineState.shutdownSlices`), which the cycle-1 verifier showed a no-chunk mutant survived (see "Cycle 2").

- **Cycle 3:** the settle's release of the actor between slices is pinned by an actor-side observer (`6cd13e9`; see
  "Cycle 3").

### S3F-5 [BLOCKING] S3-PERF-02 — an apply under a 10,000-member group — **Fixed**

*Ruling:* make the follow proportional to what the apply changed or chunk it; same for `finishRun`'s and
`releaseSystemReattachments`' full sorted walks; `BenchSync` benchmark.

- **Fix.** `followApplied(from previous:)` visits only (a) the jobs of the ids whose transfer differs between the
  previous copy and the new one (one pass over `previous`, a lookup and a checksum or remote-path comparison per id,
  `SyncEngine.sameTransfer`, a transfer formatted only for an id that moved), and (b) `EngineState.unfollowed`: jobs joined
  for an entry the copy did not name then (`addInterest` → `noteJoin`), jobs a follow skipped while verifying or
  committing, and every job after the launch adoption that no follow accompanies. A job that follows the previous copy
  can only have moved for an id whose transfer changed, and that id's job is the transfer the previous copy named, so the
  visit set is exact. `releaseSystemReattachments` walks `EngineState.systemHeld` (jobs a system interest joined);
  `finishRun` walks `RunState.held` (jobs the run's interest joined and has not left). Three new rows in
  `invariantViolations()` check the indexes against the job table after every model-test operation.
- **Benchmark:** `R-SYN-6: a sync that applies a new manifest under a 10,000-member prefetch group holds the engine's
  actor at most C2's 10 ms per turn` (`BenchSync.refreshUnderGroupTurns`). Before (`8a2ad40`, load 6.6→5.1): runs
  [17.04, 16.38, 16.88] ms, `BenchSync.swift:272:13: Expectation failed`. After (`26f87da`, load 12.4→8.4): runs [1.20,
  1.20, 1.29] ms.
- **Behaviour test:** `R-SYN-2: an apply moves only the jobs of the ids it changed and leaves every other waiting job as
  it was` (`EngineFollowTests.swift`): the changed member's interest follows its new content, the dropped member's job
  ends, the others keep their jobs, exactly one job is created, `unfollowed` is empty and every invariant holds; a
  second apply of the same manifest moves nothing.
- **Cycle 2: the residual (correctness lens, blocking).** Proportional was not bounded: an apply that changes the content of
  every member of a waiting 10,000-member prefetch group (a catalog re-encode under `AssetClient.prefetch`) superseded,
  re-routed and re-created 10,000 jobs in one turn. Failing benchmark first (`b4c215d`): `R-SYN-6: a sync whose manifest
  changes the content of every member of a waiting 10,000-member prefetch group holds the engine's actor at most C2's 10
  ms per turn` (`BenchSync.changedRefreshTurns`, production dispatch executors, the PROBE-V9 shape at 100 %), runs
  [110.53, 111.25, 133.49] ms at load 6.7→10.5, `BenchSync.swift:293:13` (P-9's 50 ms median) and `:294:13` failed.
- **Fix** (`958348e`, `Sources/ZTronAssetSync/Engine/EngineFollow.swift`, new; `followApplied` moved there from
  `EngineRuns.swift`): the pass over the replaced copy is itself bounded (`followScansPerTurn` 16,384 entries compared and
  `followFormatsPerTurn` 2,048 changed transfers formatted per turn: the pass alone over 10,000 changed entries took 7.5 to
  15.6 ms, and the sort 3.4 to 3.6 ms, in a release probe), and at most `followsPerTurn` (256) jobs are visited per turn;
  `supersede(_:settling: false)` lets a follow check the run and pump once per turn instead of once per job. The rest is
  owed to owned follow-up turns (`EngineState.followScans`, `followOrder`/`followNext`; `followFollowUp()`): a job waits
  in `unfollowed` from the pass's finding until its visit, which is that set's documented meaning, and a later apply's
  follow restarts the visits from `unfollowed` and queues its pass behind the owed ones (every pass compares with the
  copy as it stands when it runs; corrected in cycle 17: a visit owed for the earlier of two applies moves an id to the
  later apply's content, so an id both applies move skips the first one's content, PROBE-C16C-INTERMEDIATE-HOP, and
  `bringInbound` gives it that content's outcome when that content's attempt ends in between). While a follow is owed
  `checkRunSettled` does not settle (a claim may still move) and `manifestCaughtUp` keeps the jobs held for a catch-up
  held (the follow's last turn releases them). New `invariantViolations()` rules: a follow owed with no turn scheduled;
  an owed job missing from `unfollowed`; the `unfollowed` rule now accepts a job the owed pass has not reached (it
  follows the replaced copy). Shutdown drains the follow's state. **REENTRANCY RE-S44 (proposed)**, the follow-up's hop
  (row below).
- **Measured after** (release probe at load ~33): the follow's first turn 4.08 ms (was 111–145 ms in one turn); benchmark
  runs [6.47, 9.87, 10.43] ms at load ~32, then [3.68, 3.80, 3.76] ms at load 6–8 (14:51). Later runs are under "Gate
  evidence (cycle 2)".
- **Tests:** `R-SYN-2: an apply that moves more jobs than one turn takes follows them a bounded slice per turn with every
  invariant holding between turns` (2,148 changed members, the follow-up held and stepped one turn at a time with
  `holdFollowFollowUps()`: turn 1 stops its pass at 2,048 formats and moves 256 jobs, nine turns of at most 256 moves,
  every invariant holding and the run unsettled between turns, every member's interest on its new content at the end).
  Mutants: the visit bound removed → `EngineFollowTests.swift:111:9` (`first.moved == followsPerTurn`), `:112:9`,
  `:114:9`; `checkRunSettled`'s follow guard removed → `:117:17: Expectation failed: !turn.settled`. And `R-SYN-2: a job
  held for a manifest catch-up stays held until the follow that may move it has ended` (the catch-up and the held job are
  set up in one engine turn, the order a superseded publication and an apply in flight leave; jobs a release removes
  between two follow turns are skipped). Mutant (`manifestCaughtUp` without the follow guard) →
  `EngineFollowTests.swift:165:9: Expectation failed: first.held`.

- **Cycle 3: the bounded follow's regression** (the cycle-2 correctness lens, blocking): jobs of replaced content the
  follow had not visited yet answered moved ids with their failures and were dispatched between follow turns. Fixed
  with failing tests first; see "Cycle 3" above (`8b688ad`, `df5cfe3`, `48d9d59`, `2fb46be`, `c0c0563`, `776748a`).

### S3F-6 [REQUIRED] S3-CONC-03 — run progress order for a lagging subscriber — **Fixed**

- **Fix** (`SubscriberQueue.publish`): one run's `syncProgress` never replaces another run's undelivered progress in
  place; the next run's first progress takes a fresh slot at the tail, behind the previous `syncFinished` and its own
  `syncStarted`, and the superseded progress is dropped. The hunter's first suggestion (retire the run slot at
  `syncFinished`) was tried and rejected: it also dropped run 2's own progress before a lagging reader saw it, which the
  engine probe asserts is delivered. The existing `subscriberQueueOrder` expectation (same-run progress keeps its
  position) is unchanged; the type's doc now states the actual rule.
- **Tests** (`EngineEventOrderTests.swift`, `extension EngineEventsTests`): `R-SYN-12: a lagging subscriber receives a
  run's syncStarted before that run's syncProgress` (asserts `syncFinished(run1) < syncStarted(run2) <
  syncProgress(run2)`) and `R-SYN-12: a subscriber stalled across two runs receives the second run's syncStarted before
  its syncProgress`. Failing first `20e6bff` (`:32:13` and `:72:13`); fix `0c5e0c0`.

### S3F-7 [REQUIRED] S3-CONF-04 — **(a) Fixed (test); (b) recorded**

- (a) `R-SYN-7: at a critical thermal state user-initiated transfers are capped at interactiveConcurrencyAtCritical once
  the conditions are known` (`EngineGateConformanceTests.swift`). Mutant `S3-CONF-04.mutant.diff`: `✘ … at
  EngineGateConformanceTests.swift:70:9: Expectation failed: state.running == cap` and `:71:9: … starts.count == cap`.
- (b) **Recorded, no code (ruling: the documented design).** User-initiated work dispatched while the conditions are
  unknown (after the idle teardown) is not trimmed when a critical thermal reading then arrives; ADR-036's cap applies to
  dispatch decisions taken with the conditions known.

### S3F-8 [REQUIRED] S3-CONF-02 — **Fixed (test)**

`R-SYN-7: an Apple-tier catalog update check is refused on an expensive network the bulk policy forbids`. Mutant
`S3-CONF-02.mutant.diff`: `✘ … at EngineGateConformanceTests.swift:28:9: Expectation failed: request.allowsUpdateCheck == false`.

### S3F-9 [REQUIRED] S3-CONF-05 — **Fixed (test)**

`R-CAR-7: ensureAvailable while the auth breaker is open throws authRejected for a scope with missing assets`. Mutant
`S3-CONF-05.mutant.diff`: `✘ … at EngineGateConformanceTests.swift:100:9: Expectation failed: result == .failure(.authRejected(.confirmed))`.
Commit `3a602f6` (S3F-7a, S3F-8, S3F-9).

### S3F-10 [REQUIRED] S3-CONF-08 — uncovered Sync regions — **Fixed in cycle 2 (tests where a seam reaches; reasons for the rest)**

*Ruling:* a behaviour test through real APIs or a documented seam for each uncovered region the conformance hunter listed
in Sync, `other-wp:` for the Storage and Kit ones, §14 candidates for the rest. Cycle 1 wrote none (the cycle-1 verifiers'
blocking finding). Cycle 2 (`59e14fe`), every test in WP-F's suites, all passing on the current engine (none
showed a bug):

| Region (s3-base lines) | Test (display name) | Status |
|---|---|---|
| A publication the store refuses, `unverifiedRejected` (`EngineDispatch.swift:1112-1114`; R-INT-5, `allowUnverifiedAssets = false`) | `R-INT-5: with unverified assets disallowed a resolve of a checksum-less entry fails integrityFailure at publication and is not retried` | covered; the engine still downloads before the store refuses (the hunter's "decide whether a strict policy should refuse before downloading"): recorded as observed behaviour, a proposal for the orchestrator, not changed here (a pre-download refusal changes what a user resolve answers and when) |
| `unknownAsset` / `notPresent` (`:1109-1111`) | `R-CAR-2: a publication the store refuses as an unknown asset answers the waiter notFound and does not retry the transfer` (the store applies a manifest without the id behind the engine's copy while the transfer runs) | covered |
| `assetFailed` (`:1112-1114`) | `R-NET-6: a publication the store refuses because the asset's record failed meanwhile answers the waiter from that record` (`recordFailure(…, reason: .notFound)` behind the engine) | covered |
| An uncommanded `.cancelled(.byClient)` re-queue (`EngineFailures.swift:75-76`; §7.6 T7/T13) | `R-NET-6: a transfer cancelled by the client without the engine asking is re-queued at once and its next attempt delivers` | covered |
| The progress replay for a subscriber joining mid-run (`EngineEvents.swift:128-129`; R-SYN-12) | `R-SYN-12: a subscriber that joins a run in progress receives the run's syncStarted and then its latest syncProgress` | covered |
| Maintenance out of budget between steps (`EngineCommands.swift:1054-1056`, after orphan collection) | `R-SYN-16: maintenance whose time budget runs out during orphan collection stops before eviction and verification and reports the budget exhausted` (the sweep's bulk unit held, the clock passes the deadline) | covered |
| A maintenance step that throws `cancelled` (`:1081-1085`) | `R-SYN-16: a maintenance step cancelled by shutdown answers shutDown` | covered |
| A maintenance step that throws otherwise (`:1086-1092`) | `R-SYN-16: a maintenance step that throws fails the maintenance with the mapped error and the next one runs` (EIO on the staging listing) | covered |
| Source copies a source fails to release (`EngineRuns.swift:1034-1035`; R-CLN-10) | `R-CLN-10: source copies a source fails to release after a run are recorded for diagnostics` (`ReclaimFailingSource`) | covered |
| Maintenance out of budget after eviction (`EngineCommands.swift:1063-1065`, now `:1065-1067`) | — | **§14 candidate**: `evictIfNeeded`'s only executor unit is its free-space read on the metadata executor, which every earlier step also uses (staging and orphan listings, in an order WP-B owns), so no seam holds that unit without counting WP-B's units; the check is the same `expired()` as the tested exit after orphan collection |
| "Adoption report failed" (`EngineRuns.swift:1036-1037`, now `:1009`) | — | **§14 candidate**: `adoptionReport()` throws only while the store is not open or marked unavailable (`awaitOpen`, `checkWritable`); no fake path marks it unavailable between a run's last commit and this read without failing that commit first |
| The pending-run gate re-arming for conditions, breaker and throttle (`EngineRuns.swift:992-1004`, now `:963-976`, `pendingRunGate` → `.unarmed`) | — | **§14 candidate (defence in depth, as FULFIL and the F-39 re-check)**: `.unarmed` needs a pending run whose gate nothing will open; every path that sets or changes one arms it: a pending run is work, so the conditions watcher exists (`hasWork`, `ensureWatcher`); a breaker that rejects always has its cooldown or a probe's watchdog in the heap, or a probe whose outcome reconsiders (`scheduleBreakerDeadline` on every change); a throttle pending run's deadline is scheduled when it is set and moved by every extension (`throttleExtended(from:)`). `invariantViolations()`' `strandedPendingRun` names the state if it ever arises |
| Stale edge and origin re-admissions (`EngineReadmission.swift:128-129`, `:134`, `:141-142`, `:147`) | — | **already in §14** (level-4 merge: "the stale-entry branches of the re-admission turn"): `reindex` removes a job from `edgeOwed`/`originOwed` in the transition that leaves the owed state and `removeJob` does too, so the passes find no stale entry |
| An apply that adds an id over a detached record (`AssetStore+Apply.swift:206-210`) | — | **other-wp:b:** WP-B's file; the record kinds that stay detached are WP-B's to produce in a unit test |
| Kit: follower and group-registration races, `withAsset`'s "root vanished after every reopen" (`ClientLifecycle.swift:246-253`, `:508-515`, `AssetClient.swift:148-149`) | — | **other-wp:g:** WP-G's files (`AssetClient.swift:146-151` is already in §14) |

Cycle 2's own new code that no test runs (final coverage run, "Gate evidence (cycle 2)"), each a guard: the follow's
follow-up that cannot be spawned (shutting down) or finds nothing owed (`EngineFollow.swift`), a job visited that no
longer exists or did not move, the parked-order re-admission's illegal-transition `continue` and its no-breaker return
(`EngineReadmission.swift`), and `readmitOpenedOriginGates`' eager branch for a breaker that admits every transfer while
jobs stay parked (`EngineOriginGate.swift`: a closed breaker re-admits its parked jobs in the turn it closes, the rest owed
in `originOwed`, which the callers check first). Proposed for §14 below.

- **Cycle 3:** three of these tests were strengthened after the cycle-2 requirements lens's surviving mutants: the
  uncommanded cancel (states, attempts and retry deadlines observed), the refused failed record (a second, unreadable
  reason) and maintenance's exit after orphan collection (a store over budget); `dc964d7`, `758c22f`; see "Cycle 3".

### S3F-11 [REQUIRED] M-N-09, M-N-12, M-N-14, M-N-16, M-N-20, M-N-39 — **Fixed (tests)**

Tests (`EngineBoundaryTests.swift`, commit `1dcc21e`), each with its mutant's failing line from the scratch copy:

- M-N-09 — `R-SYN-3: a queued bulk job a prefetch request joins is promoted and starts before the bulk job queued ahead of it`: `EngineBoundaryTests.swift:42:9: Expectation failed: Array(result.starts.prefix(2)) == result.order`.
- M-N-12 — `R-SYN-3: a queued bulk job a user-initiated request joins is promoted and starts before the bulk job queued ahead of it`: `:50:9` (and `:42:9`), the same expectation.
- M-N-14 — `R-SYN-5: the backoff ceiling doubles with every attempt, so some key draws above the previous attempt's ceiling`: `:73:13: Expectation failed: largest > previous` (five attempts).
- M-N-16 — `R-SYN-5: a window whose 5xx share equals serverErrorRatio exactly opens the breaker`: `:94:9: Expectation failed: breaker.state == .open(cause: .serverErrors, until: now.adding(seconds: 30), trips: 1)`.
- M-N-20 — `R-SYN-5: a Retry-After equal to maxRetryAfter is honoured, one above it defers to the next run`: `:102:25: Expectation failed: Backoff.delay(attempt: 1, retryAfter: policy.maxRetryAfter, …)`.
- M-N-39 — `R-SYN-5: a later transfer 429 with a shorter Retry-After never shortens the origin's throttle`: `:137:9: Expectation failed: end == throttledAt.adding(seconds: 60)` and `:139:9`. Unlike the candidate, the two 429s are released in a fixed order from held attempts, so the test does not depend on scheduling.

### S3F-12 [REQUIRED] S3-B-064, S3-B-065, S3-B-081, S3-B-082 — **Fixed**

- **S3-B-064 (L4-R24(1)).** `startRun` puts the run in place, then reserves the manifest probe, then spawns. The
  start-turn test `R-SYN-5: a run that starts while the half-open breaker admits only a probe holds it for its manifest
  fetch from its start turn` now records, from its condition observer, `invariantViolations()`' half-started-run rule at
  every observation once the watched run's id was taken. Only that rule is asserted mid-turn: an observer inside a turn
  sees the other rules' transients (an alarm about to be re-armed, a job about to be queued), which the first, broader
  form showed. Failing first `dfd4c05`/`2a49552`: `EngineRegressionCycle22Tests.swift:292:9: Expectation failed:
  watch.violations.isEmpty ↳ … "run 2: the breaker's probe is held for a manifest fetch that is neither in flight nor
  about to begin"`; fix `e21472b`.
- **S3-B-065 (L4-R24(4)).** A job only released groups wanted that a new interest joins is reinstated at its place
  (`reinstate`) in the queue its lane now selects, whether the interest keeps the lane, changes it or comes from user
  work; `relane`'s re-queue at the back stays for jobs that waited in their queue all along. Test `R-SYN-3: members of a
  released handle that regain a user-initiated interest keep their queue positions instead of going to the back`
  (`EngineRejoinLaneTests.swift`, arguments `laneChange`, `userWork`): before the fix `↳ laneChange: dispatched ["later",
  "m0574", "m0520"], expected ["m0520", "m0547", "m0574"]` and the same for `userWork` (`14768f8`/`bb58b56`); fix `6bb4c1e`.
- **S3-B-081 (L5-R16).** `countFailedAttempt` keeps a job that only a pending claim kept when its attempt failed while
  the retry policy of its held lane (`Job.heldLane`) has attempts left (`claimRetries`), so it backs off instead of
  ending `failed(.nextRun)` with an `assetFailed`. Test `R-CAR-4: a job only a claim keeps backs off after a transient
  failure under its held lane's retry policy instead of failing at once` (`EngineClaimRetryTests.swift`): failing first
  `df20979` (`↳ the claim-only job backs off under the prefetch policy instead of ending: nil`); fix `002844b`. G-13's
  qualification "except on failure" (L5-R16) can be lifted for retryable failures.
- **S3-B-082 (L5-R22(4)).** `invariantViolations()` reports a registered group in `releasing` only while its `Release`
  holds members. Test `R-CAR-4: invariantViolations reports a registered group in releasing only while its release holds
  members, not a large give-up's leftover claims` (`EngineGiveUpInvariantTests.swift`, the E2 shape: a give-up of
  `releasesPerTurn` + 24 claims of a registered group, checked in the give-up's own turn; and a release holding members
  while registered is still reported). Failing first `435c58c` (`["group 5 is released and registered"]`); fix `3cf147d`.

### S3F-13 [REQUIRED] S3-B-063 — lazy re-admission for probe chains — **Fixed in cycle 2**

*Ruling:* L4-R22: lazy re-admission with an ordered index (O(log n) per probe exit) so a chain of half-open probes is no
longer quadratic in the parked jobs; pin it structurally (re-admission work per exit) and extend `BenchSync.swift:328`
to 10,000 parked members under C2. Cycle 1 deferred it; no ruling demoted it, so cycle 2 implements it.

- **Failing test first** (`ce021cb`): `R-SYN-5: a chain of half-open probes ending without a verdict re-admits one parked
  job per probe exit, in the pump's order, not every job the breaker parked` (`EngineProbeChainTests.swift`, `extension
  EngineFailurePathTests`): on `s3-base`'s eager re-admission `EngineProbeChainTests.swift:80:9: Expectation failed:
  seen.mostQueued <= 1 ↳ at most one member waits in the queue for the probe: 64`.
- **Fix** (`e575681`): `CircuitParkedOrder` (new, `Sources/ZTronAssetSync/Engine/CircuitParkedOrder.swift`), a binary
  min-heap of the breaker-parked jobs by (queue rank, queue ticket, transfer) with lazy deletion: a job's place is pushed
  when it enters `blocked(circuitOpen)` (`transition`) and when an interest joins it while parked (`addInterest`, its rank
  may rise); a stale place (the job left the park, was queued again, or ranks lower now) is dropped or re-pushed at its
  rank when it reaches the top; the order is emptied when nothing is parked and rebuilt in O(n) when stale places
  outnumber live ones (`noteCircuitParked`). A breaker that admits a parked job only as its probe (open past its cooldown,
  half-open without a probe or past a silent probe's watchdog: `breakerAdmitsOnlyProbe()`) re-admits only the first parked
  job (`readmitForProbe()`), in `unblockOrigin(.circuitOpen)` (cooldown end, watchdog, probe exit without a verdict) and in
  `readmitOpenedOriginGates` (which schedules a pump only when it re-queued one, so `checkRunSettled` cannot loop); it
  re-admits nothing while that candidate (`EngineState.probeCandidate`) still waits in the queue and no parked job ranks
  before it. A closed breaker still re-admits every parked job (bounded per turn, as before). The pump's end re-admits the
  next parked job when the candidate was parked for another gate or ended (`ensureProbeCandidate()`; `removeJob` of the
  candidate owes a pump); a joiner of a job that stays parked behind the candidate gets the park's fail-fast answer now
  (`failFastJoiner`), as the eager design gave it when the pump parked that job again behind the probe.
- **The invariants, redefined.** F-40's rule "no job stays parked against a gate that admits at `now`" becomes, for a
  breaker that admits only a probe, "a queued job that the pump serves no later than the parked one (queue rank at or
  before it) will take the probe" (the gate model's I3 oracle, `EngineGateModelTests.staleParks`), and the engine's own
  `invariantViolations()` gains two rules: every parked job has its place in the order, and parked jobs are never stranded
  (the breaker admits only a probe, nothing is queued, no re-queue, pump or due breaker deadline is owed). `checkRunSettled`
  still counts a parked claim under a gate that admits as working: the candidate's dispatch takes the probe, after which
  the gate rejects and the run settles blocked as before. Two cycle-20/21 regression tests waited for the claim to be
  **queued** after the cooldown's turn; they now wait for it to be queued or parked behind the probe (their assertions
  are unchanged; `EngineRegressionCycle20Tests.swift`, `EngineRegressionCycle21Tests.swift`).
- **Structural pin:** the chain test counts the re-admission work (`EngineState.circuitReadmissions`, jobs re-queued from
  `blocked(circuitOpen)`): over 60 parked members and 60 probe exits, exactly 60 re-admissions, never more than one member
  queued nor more than one queued and one downloading at any notification, the members probing in the pump's order.
  Eager mutant (the lazy branches disabled): `EngineProbeChainTests.swift:91:9: Expectation failed: readmitted == count -
  slots`, `:92:9`, `:93:9`. Missing pump-end hook: the seeded gate walks fail (`EngineGateModelTests.swift:503:29` and the
  walk test). Plus `R-SYN-5: the breaker's parked order follows a parked job's rank as interests join and leave and stays
  bounded` (70 joins compact the order to its bound; a user-initiated join raises a parked member's rank and its release
  lowers it again; the cooldown re-admits the first member in the pump's order, once). Mutant (rank check removed) →
  `EngineProbeChainTests.swift:147:9: … probing.probe == members[0].transferID`. And `R-SYN-5: the breaker's parked order
  always yields its smallest entry by rank, then ticket` (three seeds, against a sorted model).
- **Benchmark:** `probeChainTurns` now runs 10,000 parked members (warm-up 1,000): `R-SYN-5: a chain of half-open probes
  ending without a verdict over 10,000 prefetch members parked by the breaker holds the engine's actor at most C2's 10 ms
  per turn, and reports the chain's total time`. At load 6–8 (14:51): runs [5.26, 2.08, 2.77] ms, totals [20.2, 22.3,
  24.6] s (the quadratic design's estimate was about 161 s; the total is now dominated by each probe's attempt round trip
  through the fake source and the bench's polling at default priority against utility-priority engine tasks, about 2 ms
  per probe, not by re-admission work, which the structural test counts as one per exit). `cooldownEndTurns` 0.05–0.07
  ms (one re-admission instead of 512 per turn). Later runs under "Gate evidence (cycle 2)".

### S3F-14 [REQUIRED] S3-B-068, S3-B-069, S3-B-070 — §12 regression names — **Fixed (cycles 1 and 2)**

Every name ARCHITECTURE §12.3/§12.4 gives is written, in `extension EngineRegressionTests`; all pass on the current engine
(no test failed first, so no bug was found and no fix commit was needed beyond the R-SYN-15 mark below):

| Finding | Test (display name) | File, commit |
|---|---|---|
| S1-01 | `R-SYN-4: a job whose last interest left during verification is not retried after an integrity failure` | `EngineSync1LivenessTests.swift`, `b336bd9` |
| S1-01 | `R-SYN-2: a stale commit with no interests removes the job and frees its pipeline slot` | same |
| S1-07 | `R-SYN-7: a user resolve of a policy-blocked bulk asset starts at once and its demotion pauses it again` | `EngineSync1RegressionTests.swift`, `ee95eb8` (cycle 1) |
| S1-09 (replaced alarm) | `R-SYN-15: an alarm replaced while its turn waits never unregisters its successor, which fires every due deadline` | `EngineSync1HalvesTests.swift`, `b336bd9` |
| S1-09 (replaced watcher) | `R-SYN-14: a watcher replaced while its observation is still being set up never unregisters its successor and never observes` (`HoldingConditionsSource` holds both watchers in `conditions()`; the harness gained `conditionsWrapper:`) | same |
| S1-11 | `R-SYN-2: a transfer stream that ends without a terminal element fails the job instead of stranding it` | `EngineSync1RegressionTests.swift`, `ee95eb8`/`60eab9c` (cycle 1), hang guard `ad98ac3` |
| S1-12 | `R-SYN-10: ensureAvailable during a bulk sync never fails with storageUnavailable because of concurrent commits` (the member's publication held while the bulk run commits and moves the index generation) | `EngineSync1LivenessTests.swift`, `b336bd9` |
| S1-15 (run form) | `R-SYN-3: a 100,000-entry plan never materialises more than the pipeline plus the lookahead as jobs` (a condition observer samples the job count at every notification; hang guard 3 min, S3-R4 measurement below) | same, `942c633`, `a528809` |
| S2-01 (`ensureAvailable` form) | `R-SYN-10: ensureAvailable completes after a breaker recovers from an abandoned probe` | `EngineSync2RegressionTests.swift`, `b336bd9` |
| S2-09 | `R-SYN-11: committed bytes stay in the headroom ledger so the reserve is never crossed` | same |
| S2-10 | `R-SYN-3: a user-initiated job starts while bulk work fills the verify and commit pipeline` | same |
| R-SYN-15 join-before-close | `R-SYN-15: shutdown joins every owned task before it begins closing the store` | `EngineSync1HalvesTests.swift`, `b336bd9` |

- **R-SYN-15's engine-side assertion.** `performShutdown` now sets `EngineState.closingStore` and notifies observers right
  before `store.close()`; a condition observer records the owned-task count whenever it sees the mark. The level-4
  verifier's mutants M5 and M6 are not on file, so they are reconstructed from `f.md` F-20's description: M5 moves the
  close before the join loop, M6 removes the join loop. Both fail the new test while the existing `R-SYN-15: no store
  mutation or commit happens after close returns` still passes under them (the gap the backlog item named): M5
  `EngineSync1HalvesTests.swift:216:9: Expectation failed: record.tasksAtMark.allSatisfy { $0 == 0 } ↳ no owned task was
  registered when the close began: [1, 0, 0, 0]`; M6 the same line with `[3, 2, 1, 0, 0, 0]`.
- **Mutants of the other tests** (scratch, re-applied and reverted in place, each rebuilt): the alarm body without its
  token check → `EngineSync1HalvesTests.swift:100:29` (the successor is no longer the registered alarm); a stale watcher's
  exit that unregisters the current watcher → `:153:9`, `:154:9`, `:156:9` (the two token checks alone are not the
  defence: AsyncStream iteration ends on the replaced watcher's cancellation, so a mutant removing both still passes, and
  the test pins the unregistration instead); the ledger without `committedSinceRead` →
  `EngineSync2RegressionTests.swift:46:25` (b was admitted); an abandon that records no breaker outcome →
  `EngineSync2RegressionTests.swift:154:25` (the ensure did not complete).
- **S3-R4, the S1-15 run test.** 5.7–6.4 s in a debug build alone; under TSan in the whole Sync bundle at load 11–18 it
  took 59.93 s of its 60 s limit, so its guard is `.minutes(3)` (`a528809`); the 100,000-entry manifest's encode, decode,
  plan and apply are the cost, and the plan size is the test's subject (G3).

- **Cycle 3:** `closeStore()` marks and closes in one step, and the R-SYN-15 test reads the store while the shutdown joins
  (close-only M5 now fails it); `e58a34f`; see "Cycle 3".

### S3F-15 [REQUIRED] S3-B-077, S3-B-078 — C2 measurements at 10,000 — **Done; one fix**

- **Retries falling due together** — `R-SYN-5: retries of 10,000 prefetch members falling due together hold the engine's
  actor at most C2's 10 ms per turn` (`BenchSync.dueRetriesTurns`). Before (`cebb52b`): runs [64.38, 73.19, 81.34] ms
  (over P-9's 50 ms too). Cause: `DeadlineHeap.popDue` removed the first entry one at a time (quadratic in the entries
  due), and `fireDue` took every due deadline in one turn. Fix (`937d793`): `popDue(at:limit:)` finds the due prefix by
  binary search and removes it at once; `fireDue` takes at most `dueDeadlinesPerTurn` (512), the rest stay due and the
  re-armed alarm fires again at once. After: runs [1.32, 5.07, 1.48] ms at load 55→493 (the host was saturated by
  other work during the run). Structural test: `R-SYN-5: an alarm turn takes at most dueDeadlinesPerTurn due deadlines,
  in order, and none that is not due`.
- **Cycle 2** (`243c6da`): `fireDue`'s use of the limit is pinned through the engine: `R-SYN-5: one alarm turn of the
  engine re-queues at most dueDeadlinesPerTurn retries that fell due together` (see "Cycle 2" for its mutant).
- **The 10,000-id prune announcement** — `R-SYN-12: announcing a 10,000-id prune to a stalled subscriber holds the
  engine's actor at most C2's 10 ms per turn` (`BenchSync.pruneAnnouncementTurns`): runs [6.12, 6.69, 6.81] ms at load
  435→334; under C2 at the reference scale, no change. The ~35 ms estimate at `maxEntries` (100,000) is outside C2's
  reference scale and was not measured.
- **The first turn of each re-admission event** — measured by the existing benchmarks whose window contains that turn:
  `networkEdgeTurns` (edge), `cooldownEndTurns` (breaker), `spaceReadmissionTurns` (space), `throttleExtensionTurns`.
- **`registerGroup`'s de-duplication and sort** — inside `handleRejoinTurns`' measured window (a 10,000-id registration).
- **Shutdown** — S3F-4.

### S3F-16 [REQUIRED] S3-B-084, S3-B-085 — comments — **Fixed** (`50561da`)

`releasesPerTurn`'s doc now gives the re-measured cost (about 8–9 µs per removal; `handleReleaseTurns` 4.1–4.8 ms per
512-member turn, WP-G's probe 4.3–4.6 ms). The drive's REENTRANCY comment (f-11) names the lifecycle, epoch and attempt
re-checks before `remote.transfer` (L5K-R25) as well as after it.

### S3F-17 [ADR-RECORD] — statuses, no code

| Item | Status |
|---|---|
| S3-B-066 | Accepted deviation (L4-R26 (3)): ENOSPC with a pending reclaim waits `awaitingSpace` within the retry budget, no timed backoff; needs a device test to show churn. Unchanged. |
| S3-B-067 | Accepted (confirmed at merge): a job that fits alone but not behind those admitted ahead stays parked until the next free-space read. Unchanged. |
| S3-B-071 | Open, no seam: the binding-ledger windows (M-RESOLVEREG, M-JOIN) have no deterministic probe; they cost at most one job and one read. |
| S3-B-072 | Unproven suspicion by reading; no probe produced it. Unchanged. |
| S3-B-073 | Unproven residue (a holder gained between `blobHolders` and the quarantine). Unchanged. |
| S3-B-074 | Covered by the `takeApplyTurn` seam (f-13); the fix does not depend on task priorities. Unchanged. |
| S3-B-075 | No seam arms a deadline inside the read; the four space interleavings stay unpinned. |
| S3-B-076 | By construction, not produced (`joinGroup`'s copy change between two batches). Unchanged. |
| S3-B-079 | Documented in §14 (model tests' liveness phase, F-40 site diffs). Unchanged. |
| S3-B-080 | Shutdown-time races hardened, not produced. The S3F-4 drain keeps their guards (every registration answers while `shuttingDown`). |
| S3-B-083 | Argued, not tested: no running engine reaches G-13's give-up after a running join's read. S3F-12's E2-shape test now covers the invariant side of a large give-up. |
| S3-B-086 | Recorded in ADR-055 and §14; no seam reaches the second iteration. Unchanged. |
| S3-B-087 | Documented; no supported host has one cooperative thread. Unchanged. |

No real seam reaches any of them in this cycle, so no test was written. Cycle 2: unchanged (S3-B-063 aside, which is
S3F-13's; the R-SYN-15 order and S1-09's halves, part of S3-B-070, are S3F-14's).

## Authorised edits outside WP-F

None, in any cycle (cycle 4 changed `Sources/ZTronAssetSync/Engine/EngineJobs.swift`, `EngineFollow.swift`, tests under
`Tests/ZTronAssetSyncTests/Engine/`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` and this draft; cycle 5 changed
`Sources/ZTronAssetSync/Engine/EngineJobs.swift`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`,
`EngineSync1LivenessTests.swift` (a doc comment), `Tests/ZTronAssetKitBenchmarks/BenchSync.swift` and this draft; cycle 6
changed `Sources/ZTronAssetSync/Engine/EngineJobs.swift`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`,
`EngineRegressionCycle8Tests.swift`, `EngineSync1LivenessTests.swift` and this draft; cycle 7 changed
`Sources/ZTronAssetSync/Engine/EngineJobs.swift`, test files under `Tests/ZTronAssetSyncTests/Engine/` (listed under
"Cycle 7") and this draft; cycle 8 changed `Sources/ZTronAssetSync/Engine/EngineJobs.swift`, `EngineFollow.swift`,
`Tests/ZTronAssetSyncTests/Engine/EngineFollowTests.swift`, the new `EngineSweepOrderTests.swift`,
`Tests/ZTronAssetKitBenchmarks/BenchSync.swift` (a doc comment) and this draft; cycle 9 changed
`Sources/ZTronAssetSync/Engine/EngineCommands.swift`, `EngineDispatch.swift`, `EngineFailures.swift`, `EngineFollow.swift`,
`EngineJobs.swift`, `EngineRuns.swift`, `EngineShutdown.swift`, `EngineState.swift`,
`Tests/ZTronAssetKitBenchmarks/BenchSync.swift`, `Tests/ZTronAssetSyncTests/Engine/EngineEventsTests.swift`, the new
`EngineFollowBarrierTests.swift`, `EngineFollowTests.swift`, `EngineLegacyMigrationTransferTests.swift`,
`EngineRegressionCycle16Tests.swift`, `EngineSweepOrderTests.swift` and this draft; cycle 10 changed
`Sources/ZTronAssetSync/Engine/EngineCommands.swift`, `EngineConditions.swift`, `EngineDispatch.swift`,
`EngineFailures.swift`, `EngineFollow.swift`, `EngineJobs.swift`, `EngineShutdown.swift`, `EngineState.swift`,
`Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierTests.swift`, the new `EngineFollowBarrierVerdictTests.swift`,
`EngineSweepOrderTests.swift` and this draft; cycle 11 changed `Sources/ZTronAssetSync/Engine/EngineCommands.swift`,
`EngineConditions.swift`, `EngineDispatch.swift`, `EngineFailures.swift`, `EngineFollow.swift`, `EngineJobs.swift`,
`EngineOriginGate.swift`, `EnginePresence.swift`, `EngineReadmission.swift`, `EngineShutdown.swift`, `EngineState.swift`,
`EngineTimers.swift`, `Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierTests.swift`,
`EngineFollowBarrierVerdictTests.swift`, the new `EngineFollowBarrierClassTests.swift`, `EngineFollowBarrierApplyTests.swift`,
`EngineFollowBarrierSurvivorTests.swift` and this draft). Every changed file is WP-F's (ARCHITECTURE §1.2): `Sources/ZTronAssetSync/**`,
`Tests/ZTronAssetSyncTests/**`, `Tests/ZTronAssetKitBenchmarks/BenchSync.swift`, and this draft. No contract signature
changed (`followApplied(from:)` moved between WP-F files with its signature; `supersede(_:settling:)` gained a defaulted
internal parameter; in cycle 10 `park(_:reason:)` and `failFast(_:reason:only:)` gained defaulted internal parameters,
`answeredAt:` and `at:`, and the test seams `holdReleaseFollowUps()` / `resumeReleaseFollowUps()` are internal; in cycle
11 `park` and `failFast` gained a defaulted internal `answerEnd:`, `endClaim` lost `private`, `resumeReleases`,
`withdrawPurged`, `releaseEntryGroup` and `applyConditionsToJobs` are internal functions split out of their callers so
the drain can replay them, and the test seams `holdAttemptTerminals()` / `releaseAttemptTerminals()` are internal).

## Proposed document changes (for the orchestrator at the Stage 3 merge)

- **§7.6, the `offline(reason)` row, beside PROBE-C9C-3's rule:** "A satisfied first conditions reading (at launch or
  after the idle teardown set the conditions to `nil`) counts as a satisfied-path edge: user work is dispatched before
  any reading exists, so a job that failed offline before it is re-queued by it, and one failing after it is retried at
  once (Stage 3, S3-CONC-04)." The same clause in §7.1's `downloading → queued` row.
- **§7.9:** "A progress slot keeps its first undelivered position only for the same key and run: the next run's first
  `syncProgress` takes a fresh slot behind the previous run's `syncFinished` and its own `syncStarted`, and the
  superseded progress is dropped (Stage 3, S3-CONC-03)."
- **§7.10 (shutdown):** "Shutdown cancels the running attempts' handles over `inFlight`, drains every continuation and
  catalog-sized table out of the state, and answers and frees them at most `shutdownStepsPerTurn` (512) steps per turn
  (C2; Stage 3, S3-PERF-01)." And "The follow after an apply visits the jobs of the ids the copy's change moved plus
  `unfollowed`; a run's release of re-attachments visits `systemHeld`; its end visits `RunState.held` (S3-PERF-02)."
  And "An alarm turn takes at most `dueDeadlinesPerTurn` (512) due deadlines; the rest fire in the next turn (S3-B-077)."
- **§7.4 and DECISIONS F-30/F-31 (L4-R18) paragraph:** replace "A re-join that changes lane, or comes from user work,
  still goes to the back through `relane` (L4-R24(4), Stage 3)" with "A re-join is reinstated at its place in the queue
  its lane now selects, whatever lane the interest brings (Stage 3, S3-B-065)."
- **§7.2 / G-13 (L5-R16):** "A job only a pending claim keeps counts its failed attempts against the retry policy of the
  lane it held (Stage 3, S3-B-081)."
- **§10.2, new row:** `RE-S43 | shutdown: `settle(_:with:)`'s `Task.yield()` between slices, and `performShutdown`'s
  awaits of it | nothing: the drained continuations and tables belong to the call, and while the lifecycle is
  `shuttingDown` no new one is registered; the join loop drains again after each join`.
- **§12.3, §12.4 and §14:** one set of texts only, the cycle-2 items below (every §12.3/§12.4 regression test is
  written; S3-B-063 was done in Stage 3). Cycle 1's interim proposals for these sections are withdrawn (close-out
  cycle 3).
- **§1.2:** WP-F's new files: `Sources/ZTronAssetSync/Engine/EngineShutdown.swift`; tests
  `EngineFirstReadingTests.swift`, `EngineRunIntegrityCapTests.swift`, `EngineShutdownDrainTests.swift`,
  `EngineFollowTests.swift`, `EngineGateConformanceTests.swift`, `EngineBoundaryTests.swift`,
  `EngineEventOrderTests.swift`, `EngineRejoinLaneTests.swift`, `EngineClaimRetryTests.swift`,
  `EngineGiveUpInvariantTests.swift`, `EngineSync1RegressionTests.swift` (all under `Tests/ZTronAssetSyncTests/Engine/`).
- **DECISIONS (L4-R8 precedent):** the S3F-2 hang guards with their measurements (table above).

Cycle 2 adds:

- **§7.7 (circuit breaker), the "any other exit" sentence:** replace "re-admits in that turn every job the breaker parked (the
  first dispatched probes, the others park again)" with "re-admits the first job the breaker parked in the pump's order
  (`CircuitParkedOrder`, by queue rank then ticket; O(log n)), and so does a cooldown's end or a silent probe's watchdog;
  the others stay parked while that job waits in the queue to take the probe, and the pump's end re-admits the next when
  it was parked for another gate or ended; a joiner of a job left parked gets the park's fail-fast answer (Stage 3,
  S3-B-063, L4-R22). A closed breaker re-admits every parked job, `readmissionsPerTurn` per turn."
- **§7.10 settling and F-40 (§14 "the gate model"):** "A claim parked by a breaker that admits only a probe counts as
  working while a queued job ranked at or before it will take the probe (I3 for a probe-only breaker)."
- **§7.10, the follow:** "The follow after an apply compares the replaced copy with the copy at most
  `followScansPerTurn` (16,384) entries and `followFormatsPerTurn` (2,048) changed transfers per turn and visits at most
  `followsPerTurn` (256) jobs per turn; the rest is owed to owned follow-up turns; a job owed a visit is in `unfollowed`;
  no run settles and no job held for a catch-up is released while a follow is owed (Stage 3, S3F-5's residual)."
- **§7.10, shutdown (R-SYN-15):** "Shutdown marks `closingStore` after it joined every owned task and before it closes the
  store; the engine-side test of that order reads the mark."
- **§10.2, new row:** `RE-S44 | the follow's follow-up turn (`followFollowUp`, an owned task's hop) | the owed passes and
  the visit cursor (a newer apply's follow may have extended or restarted them), the copy as it stands (each pass compares
  with it), whether each job is still owed a visit (`unfollowed`, which `removeJob` leaves) and exists, and its state and
  ids`.
- **§11:** `R-SYN-5`'s probe-chain benchmark runs at 10,000 members; `R-SYN-6`'s new C2 benchmark of a refresh changing
  every member of a waiting 10,000-member group (`changedRefreshTurns`).
- **§12.3 / §12.4:** every regression test named there is written (cycle 2 table above); remove "not written at the
  level-4 merge" from S1-01, S1-07, S1-09, S1-11, S1-12, S1-15, S2-01, S2-09 and S2-10, and point S1-09's halves and
  R-SYN-15's order at the new names.
- **§14:** remove "R-SYN-15's join-before-close order has no engine-side assertion" (it has one); add the S3F-10 regions
  recorded above (maintenance's exit after eviction, the adoption-report failure, the pending-run gate's `.unarmed`
  re-arming, and cycle 2's new guards: the follow's unspawnable or empty follow-up, a visited job that no longer exists or
  did not move, `readmitForProbe`'s illegal-transition `continue` and no-breaker return, `readmitOpenedOriginGates`' eager
  branch for a closed breaker); note that the stale re-admission branches remain as already listed; the strict R-INT-5
  engine path (a checksum-less resolve under `allowUnverifiedAssets = false` downloads, then the store refuses) as an
  observed behaviour for the orchestrator's decision. Replace L4-R22's "Stage 3 hardening" text with "done in Stage 3
  (S3-B-063)".
- **§1.2:** WP-F's new files in cycle 2: `Sources/ZTronAssetSync/Engine/EngineFollow.swift`,
  `Sources/ZTronAssetSync/Engine/CircuitParkedOrder.swift`; tests `EngineProbeChainTests.swift`,
  `EngineSync1LivenessTests.swift`, `EngineSync1HalvesTests.swift`, `EngineSync2RegressionTests.swift`,
  `EnginePublicationRefusalTests.swift`, `EngineMaintenanceStepTests.swift`, `CircuitParkedOrderTests.swift` (all under
  `Tests/ZTronAssetSyncTests/Engine/`).
- **DECISIONS (L4-R8 precedent):** the S1-15 run test's hang guard (3 min; 59.93 s under TSan at load 11–18).

Cycle 3 adds:

- **§7.10, the follow (after cycle 2's sentence):** "While a follow is owed, a job holding an id the copy does not map
  to its content (listed elsewhere or dropped) is not dispatched: its queue's head stays in place, counts as no user
  work waiting for a slot (no preemption), and every follow turn pumps again (`pumpWaitsForFollow`). A job holding an id
  the copy lists at another transfer is followed before it answers its interests with a failure (`resolveAll`, an
  answer at the retry cap, the park after an ENOSPC), so the moved ids follow their new content (T22) and only the ids
  the copy still maps to it receive the failure (Stage 3, close-out cycle 3; F-20: never `.notFound` while the asset is
  listed)."
- **§7.10, shutdown (R-SYN-15), replacing cycle 2's sentence:** "Shutdown closes the store through `closeStore()`, which
  marks `closingStore` and closes in one step, after it joined every owned task; the engine-side test reads the mark and
  reads the store while the join waits (it must still be open)."
- **§10.2, row f-4 (proposed in WP-F's Stage 2 record), re-validation column:** add "and, after the free-space read, the
  follow: the ids an owed follow moved leave the job before its park answers them (`followBeforeActing`)".
- **§14:** (a) the liveness terms `|| pumpWaitsForFollow` of `continueFollow`'s pumps (a queue head the follow never
  visits; no join site produces one today; the invariant rule "a pump waits for a follow that nothing owes" reports a
  flag left set); (b) PROBE-W3: the breaker's parked-order rebuild at 9,994 parked jobs took 5.1–6.3 ms in one call,
  within C2 alone; a turn that combines it with a join batch or a pump's parks is not benchmarked.
- **DECISIONS / §11:** the R-SYN-2 and R-CAR-2 regression tests of this cycle (names under "Cycle 3"); no hang guard
  changed in cycle 3 (measurements under "Gate evidence (cycle 3)").

Cycle 4 adds:

- **§7.10, the follow (cycle 3's sentence):** replace "(`resolveAll`, an answer at the retry cap, the park after an
  ENOSPC)" with "(`resolveAll`, an answer at the retry cap, the park after an ENOSPC, and a space sweep's park or
  re-queue, each counted against that sweep's per-turn bound)".
- **§10.2:** no new row (no new `await`).
- **§11:** `R-SYN-5`'s probe-chain benchmark ends each probe with a 400 (a 404's store commit is not the re-admission's
  cost) and runs the engine's owned tasks at the heartbeat's priority; a 10,000-member chain takes about 1.1 s.
- **§14:** (c) the `|| pumpWaitsForFollow` term of `dispatchOwed` (F-41's order for a pending run behind a probe-only
  breaker while the probe candidate waits for an owed follow; reachable only through a follow of a non-run apply; the
  survivor `noDispatchOwedFlag`), next to (a).
- **For routing (`other-wp:b`, not a WP-F document change):** `AssetStore.recordFailure` commits the whole index once per
  call, so a burst of N 404s rewrites the index N times (about 5 ms each at 10,000 records in release).
- **DECISIONS (L4-R8 precedent):** the cycle-4 hang guards with their measurements (table under "Cycle 4"), and the
  orchestrator's ruling on the S1-15 run test's guard once given.

Cycle 5 adds:

- **§7.10, the follow (cycle 4's replacement text):** replace "and a space sweep's park or re-queue, each counted against
  that sweep's per-turn bound" with "and a space sweep's park or re-queue; a space sweep follows at most `followsPerTurn`
  (256) jobs per turn besides its `readmissionsPerTurn` re-queues and `parksPerPump` parks, and leaves the rest to its
  follow-up sweep (Stage 3 close-out cycle 5, PROBE-C4-SWEEP2-C2)".
- **§11:** `R-SYN-11`'s new C2 benchmark of a reclaim's space sweeps during an owed follow under a 10,000-member
  prefetch group, with one handle and with two (`reclaimDuringFollowTurns`); and the structural test
  `spaceSweepFollowsAtMostOneTurnOfJobs` (one sweep turn follows exactly `followsPerTurn` of 344 owed jobs).
- **§10.2:** no new row (no new `await`).
- **DECISIONS (L4-R8 precedent):** the S1-15 run test's guard, ruled after this cycle (S3-R10) and applied in cycle 6:
  see "Cycle 6 adds". The new cycle-5 test keeps `.minutes(1)` (19.2–21.3 s paired at load 4–14 here; 27.4–27.8 s
  paired at load 8.8–20.8 in the cycle-5 verification, 46 % of 60 s).
- **For routing (`other-wp:b`, unchanged from cycle 4):** `AssetStore.recordFailure`'s whole-index commit per 404, and
  P-13.

Cycle 6 adds:

- **§7.10, the follow (cycle 5's replacement text):** after "and leaves the rest to its follow-up sweep (Stage 3
  close-out cycle 5, PROBE-C4-SWEEP2-C2)" add "; a job a sweep follows before re-queuing it is judged again on the lane
  the follow left it, and one that no longer fits is treated as one that never did (left parked, left waiting, or parked
  within `parksPerPump`), never re-queued nor counted ahead of the jobs behind it (Stage 3 close-out cycle 6,
  PROBE-C5-LANEDROP)".
- **§11:** the R-SYN-11 regression test `spaceSweepJudgesAFollowedJobOnItsNewLane` (both visits) and the structural test
  `spaceSweepParksAtMostOneTurnOfJobs` (one sweep turn parks exactly `parksPerPump` of 575 jobs that do not fit).
- **§10.2:** no new row (no new `await`).
- **DECISIONS (L4-R8 precedent):** S1-15's run test guard (`EngineSync1LivenessTests.swift`,
  `runMaterialisesAPipelineAtATime`) is `.minutes(5)` by the orchestrator's ruling S3-R10: the SPEC-mandated scale
  (100,000 entries) decoded by WP-A's parser under TSan; 101.8–130.1 s beside a second TSan process at load 10–32 (34–43 %
  of 5 minutes), 47.5–72.3 s alone, and this cycle's figures under "Cycle 6"; nothing cut (G3).
- **Stage 5 residual risks:** WP-A's manifest parser under ThreadSanitizer costs about two thirds of S1-15's run test
  (47–130 s for the 21 MB, 100,000-entry manifest); not a defect (release decodes it in well under a second); no WP-A
  change; the guard is 5 minutes and a paired TSan run at load above about 30 is unmeasured.
- **For routing:** `other-wp:b` / `other-wp:h`, the Storage time-outs at load 100–540 (`StoreCrashTests.swift:167`,
  `LoopbackHTTPServerTests.swift:400`), only if they return at a moderate load; `other-wp:b` P-13 and the per-404 index
  commit, unchanged.

Cycle 7 adds:

- **§7.10, the follow (cycle 6's replacement text):** after "never re-queued nor counted ahead of the jobs behind it
  (Stage 3 close-out cycle 6, PROBE-C5-LANEDROP)" add "; and a job a sweep follows before parking it is judged again
  too, and one that fits on the lane the follow left it is re-queued within `readmissionsPerTurn`, never parked: the two
  volume readings are not ordered, so a lowered lane may read the larger room (Stage 3 close-out cycle 7,
  PROBE-C6-LANEGAIN)". **§7.6 / §7.10 (F-22):** wherever the text says or implies that a lane drop only shrinks a job's
  room, say instead that the important and opportunistic readings are unordered and a job's room is read on its current
  lane.
- **§11:** the R-SYN-11 regression tests `spaceSweepRequeuesAFollowedJobItsNewLaneFits`,
  `readSweepJudgesAFollowedJobOnItsNewLane` and `spaceSweepParksAFollowedJobWithItsNewLanesFigures` (both visits each),
  and the in-turn park check added to `spaceSweepJudgesAFollowedJobOnItsNewLane`.
- **§10.2:** no new row (no new `await`).
- **DECISIONS (L4-R8 precedent):** the cycle-7 hang guards: 93 one-minute Sync tests raised to `.minutes(3)` and three
  seeded model walks raised from `.minutes(3)` to `.minutes(5)`, each with its alone and paired TSan figures (table and
  list under "Cycle 7"); nothing cut (G3).
- **Ruling requested (S3-R10 style):** `EngineEventsTests.stalledSubscriberIsBounded` (`.minutes(4)`, a 10,000-asset
  sync) took 132.0–132.4 s beside a second TSan process at load 20–35 (55 % of 4 minutes); S3-R4 has no step above
  3 minutes for a test that is neither model-based nor exhaustive. Proposed: `.minutes(5)`, nothing cut.
- **Stage 5 residual risks:** S1-15's run test 148.8–148.9 s paired at load 20–35 (just under half of 5 minutes), 58.4 s
  alone; the correctness lens's 190.9 s at load 21–446 and 88.3 s at load 6.6–37.6. Under ThreadSanitizer the Sync
  bundle's guards hold beside a second TSan process only up to a load of about 35 on this 8-core host: at load 50–78 the
  paired bundles timed out 44 and 38 one-minute tests (time limits only). CI should run the TSan Sync bundle alone or at
  a load of at most about 30.
- **Not verified, for §14 or a device test:** whether a device reports an opportunistic free-space reading above the
  important one (the precondition of PROBE-C6-LANEGAIN); the store does not clamp them.

Cycle 8 adds:

- **§7.10, the follow (the cycle-4 to cycle-7 replacement texts):** replace every sentence about a space sweep following
  a job "before it re-queues or parks it", judging it "again" after its follow, and re-queuing a job the park branch's
  follow left room for, with: "A space sweep that runs while a follow is owed first follows every job it would judge
  that holds an id the follow has not moved, as the follow's visit would, at most `followsPerTurn` per turn (a turn
  with more left judges nothing and leaves them to its follow-up sweep); it then collects and orders the jobs as the
  follows left them and judges each once, at the place the pump would serve it from (Stage 3 close-out cycle 8,
  PROBE-C7-RANK-ADMIT, -PARK and -PROMOTE)." The facts the removed clauses recorded stay true and need no text of
  their own: a job's verdict and figures read its current lane's volume, and the two readings are not ordered.
- **§7.6, the `insufficientSpace` row:** after "Re-admissions follow the pump's order, each admitted against the room
  the jobs ahead leave (F-28)" add "; a sweep during an owed follow orders the jobs after the follows it performs, so a
  follow that lowers a job, or raises the job of a moved id's new content, moves it to its new place before any is
  judged (Stage 3 close-out cycle 8)".
- **§11:** the R-SYN-11 regression tests `spaceSweepAdmitsUserWorkBeforeAJobItsFollowLowers`,
  `spaceSweepParkBranchAdmitsUserWorkBeforeAJobItsFollowLowers`, `spaceSweepJudgesAJobItsFollowRaisesAtItsUserPlace`
  and `spaceSweepCountsAFollowedJobAheadOfTheNextOne` (both visits each), and the bounded-follow assertion added to
  `spaceSweepFollowsAtMostOneTurnOfJobs` (a turn that cannot follow every holder judges none).
- **§1.2:** WP-F's new test file `Tests/ZTronAssetSyncTests/Engine/EngineSweepOrderTests.swift`.
- **§10.2:** no new row (no new `await`).
- **DECISIONS (L4-R8 precedent):** the four new tests' guards (`.minutes(3)`; 33.8–35.4 s paired at load 1.9–18.6,
  21.9–22.2 s alone; table under "Cycle 8").
- **Ruling requested (repeated from cycle 7, with the cycle-7 verifier's framing):** either (a)
  `EngineEventsTests.stalledSubscriberIsBounded` may take `.timeLimit(.minutes(5))` (its cost is SPEC §6's
  10,000-asset sync, most of it the store's publication and the shared fakes under TSan: 124.8–125.4 s paired at load
  17.9–36.1, 132.0–132.4 s at load 20–35, 111.0 s at 16.0–32.4, 80.2–80.7 s at 19.6–25.6 and 81.9 s at 1.9–18.6; alone
  92.7 s at 18–25, 51.5 s at 13–18, 49.5 s at 9–11; nothing cut), and S3-R10 is amended to accept S1-15's run test at
  166.9–167.1 s paired at load 17.9–36.1 (56 % of 5 minutes; 148.8–148.9 s at load 20–35, 118.9–119.0 s at 16.0–32.4,
  89.1 s at 19.6–25.6, 87.3–87.9 s at 1.9–18.6); or (b) a paired run whose 1-minute load is above 30 for most of a
  test's duration is not "about 30" in S3-R4's sense. WP-F makes no change to either guard until a ruling.
- **Stage 5 residual risks:** add this cycle's figures to the note (the two tests above); the conclusion stands: the
  TSan Sync bundle's guards are sized for a paired run at load up to about 30 on this 8-core host, and CI should run it
  alone or at a load of at most about 30.

Cycle 9 adds (S3-R11 to S3-R13):

- **§7.10, a new paragraph "Follow barrier (F-28)"**, replacing every sentence the cycle-3 to cycle-8 entries above
  propose about a job, a failure or a space sweep following a job before it acts (cycle 3's "is followed before it
  answers its interests with a failure", the cycle-4 to cycle-8 sweep texts, cycle 8's "first follows every job it would
  judge"): "While a follow is owed, nothing is admitted and no space verdict is given: the pump starts and parks nothing;
  a space sweep runs one follow turn (or one drain turn) and judges in a follow-up sweep once the barrier is down; a
  join's re-check of a job parked `insufficientSpace`, an ENOSPC's verdict, a job's place in its queue (with its `front`
  and the time it was asked for) and the failure verdict of a job that still holds an id the follow moves wait in arrival
  order. The follow's last turn pumps and then applies them, at most 512 per turn, on the state every visit left; no pump
  runs during or between those turns, the last one checks the run and pumps, and no run settles before it. A failure
  that waits leaves its job `failed(nextRun)` with no answer; the follow's own visit moves the ids it moves, in its order,
  and the verdict is then given to the ids left, unless the job was superseded. A second apply keeps the visits still
  owed in their order and appends the newly unfollowed jobs. Free-space reads and the bytes an ended transfer frees apply
  when they arrive (L4-R7): they are real information, not an artefact of visit order (Stage 3 close-out cycle 9,
  S3-R11; design D3)."
- **DECISIONS, WP-F's F-28 record:** add "decided on the followed state": "Since Stage 3 close-out cycle 9 (S3-R11) every
  admission and space verdict is decided on the followed state: the follow barrier (§7.10) replaces the case-by-case
  follows of cycles 3 to 8, whose class (a decision taken while a follow is owed differing from the one taken when the
  follow visits first) each verification cycle extended."
- **§7.6, the `insufficientSpace` row:** replace cycle 8's addition ("; a sweep during an owed follow orders the jobs
  after the follows it performs, …") with "; no sweep judges while a follow is owed (F-28, §7.10's follow barrier)".
- **§7.2 (lane queues):** "A place that waits for the follow barrier keeps its `front` and its `queuedAt` (bulk aging);
  a paused transfer resumes at its lane's front either way (Stage 3 close-out cycle 9, amendment (a))."
- **§10.2, new row:** `RE-S45 | the follow barrier's drain follow-up (`drainFollowUp`, an owned task's hop) | the
  lifecycle; the waiting events and each job, epoch and interest they name (`drainEventsAfterFollow` re-validates every
  one: a job that ended or moved is skipped, a verdict is epoch-checked); a follow begun meanwhile holds them again until
  its own end drains them`.
- **§10.2, row f-4, re-validation column:** replace cycle 3's "the ids an owed follow moved leave the job before its park
  answers them (`followBeforeActing`)" with "behind the follow barrier the ENOSPC's verdict waits for the follow
  (`.spaceFailure`), whose visits move the ids it moves before the park answers the rest; the read itself is adopted on
  arrival (S3-R11 R1)".
- **§11:** R-SYN-11 / R-SYN-2 / R-SYN-3 regression tests of this cycle (the item-6 table under "Cycle 9"); the
  `BenchSync` C2 benchmarks `reclaimDuringMixedFollowTurns`, `followDrainTurns` and `followEndTurn`.
- **§1.2:** WP-F's new test file `Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierTests.swift`.
- **§14:** (a) and (c) stay (the `pumpWaitsForFollow` terms; with the barrier the flag is how a barred pump is repeated
  at the follow's end); add (d) the `.reclaimed` sweep's follow-up turns each collect and sort every parked candidate
  again (4.0–11.8 ms per turn at 10,000 in a scratch probe, load not sampled; keeping the order across follow-ups would
  bound them). (Cycle 9 also proposed two residuals here, a join while a verdict waits and the offline and throttle
  exits; cycle 10 fixed both, so they are withdrawn.)
- **DECISIONS (L4-R8 precedent):** S3-R12's raises with their figures (under "Cycle 9"); the new tests' guards
  (`.minutes(3)`, figures under "Gate evidence (cycle 9)").
- **Stage 5 residual risks:** the admission wait of a multi-turn follow (S3-R11 R2): no admission for 141–149 ms after
  the release of a follow over 10,000 changed members with 10,000 waiting places (macOS release, load 7.5–8.9; the
  design and the judges: 131–143 ms to the follow's end); not measured on a device. S3-R13: the package builds at
  tools 6.4 with 0 warnings in an export; the committed manifest stays at 6.0.

Cycle 10 adds:

- **§7.10, "Follow barrier (F-28)"**, replacing cycle 9's paragraph: "While a follow is owed, nothing is admitted and no
  space verdict is given: the pump starts and parks nothing; a space sweep runs one follow turn (or one drain turn) and
  judges in a follow-up sweep once the barrier is down. What a decision would read from the jobs waits, in arrival
  order: a join's re-check of a job parked `insufficientSpace`, an ENOSPC's verdict, a job's place in its queue (with
  its `front`, the time it was asked for and the asking job's epoch), and every exit of an attempt by a job that still
  holds an id the follow moves (a final answer, a retry, a count toward the caps, an ENOSPC, the offline exit and a
  429's park, each with its fail-fast answers); while such a verdict waits, a join to the job, a re-lane other than the
  follow's own and a satisfied network edge that meets it wait behind it. The follow's last turn pumps and then applies
  them, at most 512 per turn, on the state every visit left; no pump runs during or between those turns, the last one
  checks the run and pumps, and no run settles before it. A failure that waits leaves its job `failed(nextRun)` with no
  answer; the follow's own visit moves the ids it moves, in its order, and the verdict is then given to the ids left,
  unless the job was superseded. A second apply keeps the visits still owed in their order and appends the newly
  unfollowed jobs. What arrives from the world applies when it arrives: a free-space read and the bytes an ended
  transfer frees (L4-R7), whether a network edge passed during an attempt and whether the path is satisfied, and an
  origin's throttle (Stage 3 close-out cycles 9 and 10, S3-R11; design D3)." The claim is the list, not "every
  decision": the cycle-10 residuals ("Cycle 10", "Residuals found while fixing") await the orchestrator.
- **§10.2, row f-4:** unchanged from cycle 9's text. No new `await` in an actor this cycle (the new code is synchronous).
- **§11:** the cycle-10 tests (the table under "Cycle 10"), all in `EngineFollowBarrierTests` (serialized).
- **§1.2:** WP-F's new test file `Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrierVerdictTests.swift`.
- **§14:** nothing added; cycle 9's (d) and (e) are withdrawn (fixed). The amendment-(e) ordering question and the
  cycle-10 residuals are for the orchestrator, not proposed as accepted limitations.

Cycle 11 adds:

- **§7.10, "Follow barrier (F-28)"**, replacing cycle 10's paragraph (aligned with S3-R14's R1): "While a follow is owed,
  nothing is admitted and no space verdict is given: the pump starts, parks and answers nothing; a space sweep runs one
  follow turn (or one drain turn) and judges in a follow-up sweep once the barrier is down. Every input that is not a
  real-world ledger input waits, in arrival order, as an event the drain applies at its arrival instant on the state
  every visit left: a request's join (with its place, its re-check of a parked job and its fail-fast answer); an
  interest's removal (a cancelled caller is answered at once; the removal and any transfer it stops wait); a group's
  release and its later turns; a purge's withdrawals; a claim's end; a conditions element's pass (its policy pauses,
  its network edge's re-admissions and its lane re-admissions, under the conditions of its arrival); an origin's
  re-admission; a backoff's end; a throttle's answer turn; a job's place in its queue; and every exit of an attempt by
  a job that still holds an id the follow moves (a final answer, a retry, a count toward the caps, an ENOSPC, the
  offline exit, a 429's park, a pause's park or re-queue, a re-queue), each with its fail-fast answers. The follow's
  own visit moves the ids it moves, in its order, and a waiting verdict is then given to the ids left, unless the job
  was superseded. The follow's last turn pumps and then applies the events, at most 512 per turn; no pump runs during
  or between those turns, the last one checks the run and pumps, and no run settles before it. A second apply keeps
  the visits still owed in their order; the jobs it finds unfollowed but not owed are visited after the older passes
  end. Outside the class (R1): a free-space read and the bytes an ended transfer frees apply when they arrive (L4-R7).
  Applied on arrival as world inputs, with every decision about a job taken from them waiting: whether a network edge
  passed during an attempt, whether the path is satisfied, and an origin's throttle (Stage 3 close-out cycles 9 to 11,
  S3-R11, S3-R14; design D3)." The claim is the inventory (I1–I38, I13b), not more: the open residuals R-A to R-E
  ("Cycle 11") await the orchestrator.
- **§10.2:** a new row RE-S47 (proposed) for the attempt-terminal test seam's wait in `drive`
  (`awaitAttemptTerminalRelease`): the lifecycle is re-checked after it and `finishAttempt` re-validates the job's epoch;
  no production path sets the seam.
- **§11:** the cycle-11 tests (the table under "Cycle 11"), all in `EngineFollowBarrierTests` (serialized).
- **§1.2:** WP-F's new test files `EngineFollowBarrierClassTests.swift`, `EngineFollowBarrierApplyTests.swift` and
  `EngineFollowBarrierSurvivorTests.swift` under `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** nothing added; R-A to R-E and PROBE-C9-THROTTLE's attribution are for the orchestrator.

Cycle 12 adds:

- **§7.10, "Follow barrier (F-28)"**, replacing cycle 11's paragraph (S3-R15; the cycle-11 verifier's wording note
  applied: the exits wait whether or not the job holds a moved id, as `defersFailure`'s `exitDefers` does): "While a
  follow is owed, nothing is admitted and no space verdict is given: the pump starts, parks and answers nothing; a space
  sweep runs one follow turn (or one drain turn) and judges in a follow-up sweep once the barrier is down. Every input
  that is not a real-world ledger input waits, in arrival order, as an event the drain applies on the state every visit
  left: a request's join (with its place, its re-check of a parked job and its fail-fast answer); an interest's removal
  (a cancelled caller is answered at once; the removal and any transfer it stops wait); a group's release and its later
  turns; a purge's withdrawals; a claim's end; a conditions element's pass; an origin's re-admission; a backoff's end; a
  throttle's answer turn; and every exit of an attempt while the barrier holds (a final answer, a retry, a count toward
  the caps, an ENOSPC, the offline exit, a 429's park, a pause's park or re-queue, a re-queue, a supersede), each with
  its fail-fast answers. A publication or commit by a job that holds an id the follow moves waits for the follow's visit
  of that job, and its re-routed requests take the follow's places. Each waiting event reads the world as it stood at
  its arrival, and a follow's visit reads it as it stood at the apply: while the barrier holds, the origin's throttle
  and circuit breaker, the conditions and the thermal pause, and the network edge are kept as views, one per change,
  and a decision taken in a replay or a visit reads its own view (its instant, its throttle, its breaker, its
  conditions); a place given there keeps its view for the gate that admits it. The history is empty once the drain
  ends. A 429 throttles its origin on arrival, for the backoff of the lane the owed visits leave the job (the interests
  whose ids the engine's copy still maps to it), and its park and answers wait. The follow's own visit moves the ids it
  moves, in its order, and a waiting verdict is then given to the ids left, unless the job was superseded. The follow's
  last turn pumps and then applies the events, at most 512 per turn; no pump runs during or between those turns, the
  last one checks the run and pumps, and no run settles before it. A second apply keeps the visits still owed in their
  order; the jobs it finds unfollowed but not owed are visited after the older passes end. Outside the class (R1): a
  free-space read and the bytes an ended transfer frees apply when they arrive and are read live (L4-R7) (Stage 3
  close-out cycles 9 to 12, S3-R11, S3-R14, S3-R15; design D3)." The claim is the corrected inventory, not more: R-C,
  the nine replay branches and three world-view reads with no killing test, and the residuals R-F to R-I ("Cycle 12")
  await the orchestrator.
- **§10.2:** no new row. No new `await` in an actor this cycle.
- **§11:** the cycle-12 tests (`fc13762`, `39d4376`, and the replay tests `40d9711` to `dcee1cd`), all in
  `EngineFollowBarrierTests` (serialized).
- **§1.2:** WP-F's new test files `EngineFollowBarrierWorldTests.swift` and `EngineFollowBarrierReplayTests.swift` under
  `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** nothing added; the open items of cycle 12 are for the orchestrator.

Cycle 13 adds:

- **§7.10, "Follow barrier (F-28)"**, replacing cycle 12's paragraph (S3-R16): "While a follow is owed, nothing is
  admitted and no space verdict is given: the pump starts, parks and answers nothing; a space sweep waits as an event at
  its arrival place, runs one follow turn (or one drain turn), and owes a follow-up sweep that judges the jobs still
  parked once the barrier is down. Every input that is not a real-world ledger input and that decides an answer waits,
  in arrival order, as an event the drain applies on the state every visit left: a request's join (with its place, its
  re-check of a parked job and its fail-fast answer); a waiter's withdrawal (the caller is answered at once; the removal
  and any transfer it stops wait); a conditions element's pass; an origin's re-admission; a backoff's end; a throttle's
  answer turn; a space sweep's verdicts; and every exit of an attempt while the barrier holds (a final answer, a retry,
  a count toward the caps, an ENOSPC, the offline exit, a 429's park, a pause's park or re-queue, a re-queue), each with
  its fail-fast answers. Applied on arrival, because they decide no answer and differ from a visit-first engine only in
  order: a group's release and its later turns, a purge's withdrawals, a claim's end, a run's and a re-attachment's
  removals, a publication's commit (its unbound ids follow their content through joins that wait), a superseded
  publication and a cancelled attempt's ENOENT re-queue. Each waiting event reads the world as it stood at its arrival,
  and a follow's visit reads it as it stood at the apply: while the barrier holds, the origin's throttle and circuit
  breaker, the conditions and the thermal pause, and the network edge are kept as views, one per change, and a decision
  taken in a replay or a visit reads its own view. A place given there is refused by its view's throttle or breaker,
  and every start reads the live throttle, breaker, slots and space, so no request goes to an origin whose throttle or
  open breaker is live (R-SYN-5). A 429 throttles its origin on arrival, for the backoff of the lane the owed visits
  leave the job (its interests whose ids the engine's copy still maps to it), else of the job's own lane, unless its
  `Retry-After` exceeds `maxRetryAfter`; its park and answers wait. The follow's own visit moves the ids it moves, in its
  order, and a waiting verdict is then given to the ids left. The follow's last turn pumps and then applies the events,
  at most 512 per turn; no pump runs during or between those turns, the last one checks the run and pumps, and no run
  settles before it. A second apply keeps the visits still owed in their order; the jobs it finds unfollowed but not
  owed are visited after the older passes end. Outside the class (R1): a free-space read and the bytes an ended
  transfer frees apply when they arrive and are read live (L4-R7). The barrier guarantees the answers, the MUSTs and the
  invariants of a visit-first engine, not its order: the differences in order, place, timing and backoff length are
  the residual risks RR-1 to RR-6 of the WP-F draft (Stage 3 close-out cycles 9 to 13, S3-R11, S3-R14 to S3-R16; design
  D3)."
- **`docs/RESIDUAL-RISKS.md` (Stage 5):** RR-1 to RR-6 from "Cycle 13", "Residual risks (S3-R16)".
- **§10.2:** no new row. No new `await` in an actor this cycle.
- **§11:** the cycle-13 tests (`dd13e69`, `8f459c3`, `15d15a5`, `dc5e3c3`, `d5985f8`), all in `EngineFollowBarrierTests`
  (serialized).
- **§1.2:** WP-F's new test files `EngineFollowBarrierLiveGateTests.swift`, `EngineFollowBarrierReachTests.swift` and
  `EngineFollowBarrierSweepTests.swift` under `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** the conflict inside S3-R16 put back under "Cycle 13" (PROBE-C9-THROTTLE, R-B, the suspected offline join)
  is for the orchestrator.

Cycle 14 adds:

- **§7.10, "Follow barrier (F-28)"**, three changes to cycle 13's paragraph:
  - "A place given there is refused by its view's throttle or breaker" becomes "A place given there, at an instant a
    visit-first pump had a slot for its lane, is refused by its view's throttle (the breaker is read live, S3-R17)".
  - "for the backoff of the lane the owed visits leave the job (its interests whose ids the engine's copy still maps to
    it), else of the job's own lane" becomes "for the backoff of the lane a visit-first engine's job had: its own
    interests whose ids the copy still maps to it, less those a waiting withdrawal removes, the interests other jobs'
    owed visits move onto it, and the waiting joins that join it at the drain".
  - After "a purge's withdrawals", add "(with the joins of the interests it removes that wait for the follow)"; and after
    "a waiting verdict is then given to the ids left", add "A job the follow passed while it verified or committed is
    answered as a visit-first engine answered it: its moved ids move before its failure's exit when its publication
    began after the visit's apply, and keep its outcome when it began before".
  - "the residual risks RR-1 to RR-6" becomes "RR-1 to RR-7" (S3-R17).
- **`docs/RESIDUAL-RISKS.md` (Stage 5):** RR-1 to RR-7, RR-1 and RR-5 as corrected in cycle 14, and RR-7 as S3-R17
  confirms it.
- **§10.2:** no new row. No new `await` in an actor this cycle.
- **§11:** the cycle-14 tests (`85636a1`, `a716fde`, `b075089`), all in `EngineFollowBarrierTests` (serialized).
- **§1.2:** WP-F's new test file `EngineFollowBarrierAnswerTests.swift` under `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** finding 11 (nested drain re-entrancy) and the RR-1 remainder are for the orchestrator.

Cycle 15 adds:

- **§7.10, "Follow barrier (F-28)"**, changes to cycle 14's paragraph:
  - "A place given there, at an instant a visit-first pump had a slot for its lane, is refused by its view's throttle
    (the breaker is read live, S3-R17)" becomes "A place given there is admitted at the barrier-end pump on the live
    throttle, breaker, slots and space, like any other (S3-R18)".
  - "A job the follow passed while it verified or committed is answered as a visit-first engine answered it: its moved
    ids move before its failure's exit when its publication began after the visit's apply, and keep its outcome when it
    began before" becomes "A visit that meets a job publishing, or failed with its publication's verdict waiting, keeps
    the job's bytes and publication. It re-routes at once the moved ids the copy listed elsewhere when that publication
    began while a follow was owed (a visit-first engine visited the job at that apply, while it downloaded). It passes
    the others, which the publication's outcome answers (S3-R18, S3-R18a)".
  - In the 429 sentence, after "the interests other jobs' owed visits move onto it", add "(of a job the visit passes,
    only those in the ids it re-routes)", and "else of the job's own lane" stays.
  - "RR-1 to RR-7" becomes "RR-2 to RR-5 and RR-7 to RR-10" (RR-1 closed and RR-6 removed in cycle 15).
- **`docs/RESIDUAL-RISKS.md` (Stage 5):** RR-2 to RR-5 and RR-7 to RR-10, with RR-8 to RR-10 as written under
  "Cycle 15".
- **§10.2:** no new row. No new `await` in an actor this cycle.
- **§11:** the cycle-15 tests (`b461450`, `9673e2f`), all in `EngineFollowBarrierTests` (serialized).
- **§1.2:** WP-F's new test files `EngineFollowBarrierSlotTests.swift`, `EngineFollowBarrierPublicationTests.swift`,
  `EngineFollowBarrierLaneTests.swift` and `EngineFollowBarrierRetryTests.swift` under
  `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** three items found while fixing go to the orchestrator: a verdict that waits across a later apply, the
  publication failure's await window, and a drain-turn seam for `laneJobsWalkAlways` (all under "Cycle 15", "Put to the
  orchestrator").

Cycle 16 adds:

- **§7.10, "Follow barrier (F-28)"**, changes to cycle 15's paragraph:
  - "A visit that meets a job publishing, or failed with its publication's verdict waiting, keeps the job's bytes and
    publication. It re-routes at once the moved ids the copy listed elsewhere when that publication began while a
    follow was owed (a visit-first engine visited the job at that apply, while it downloaded). It passes the others,
    which the publication's outcome answers (S3-R18, S3-R18a)" becomes "A visit compares its apply with the job's
    attempt end and exit verdict, counted in applies followed, and meets the job as a visit-first engine's visit met it
    at that apply. A visit that meets a job publishing, failed in its publication's bookkeeping with no verdict yet for
    an apply made while it published, or failed with its verdict waiting keeps the job's bytes and publication. It
    re-routes at once the moved ids a visit-first engine had moved before the publication began or the verdict arrived
    (the visit spends that set, and so does the end of its follow). It passes the others, which the publication's
    outcome or the verdict answers. After the verdict, the drain moves from the job the verdict leaves the ids the
    applies followed since its deferral moved (S3-R18, S3-R18a, S3-R19)".
  - In the 429 sentence, after "(of a job the visit passes, only those in the ids it re-routes)", add "and, of another
    job whose verdict waits with an apply followed since, the interests the drain moves onto it after the verdict, less
    those the verdict answers".
  - "RR-2 to RR-5 and RR-7 to RR-10" becomes "RR-2 to RR-5 and RR-7 to RR-12".
- **`docs/RESIDUAL-RISKS.md` (Stage 5):** RR-11 and RR-12 as written under "Cycle 16", with RR-11 as cycle 17 rewrites
  it.
- **§10.2:** no new row. No new `await` in an actor this cycle.
- **§11:** the cycle-16 tests (`39e18d2`, `abaeec1`, `33b1976`, `f6ba277`, `ef71ca9`, `ea5595e`, `c3f675b`, `e9960ef`,
  `c161818`, `d3242d3`), all in `EngineFollowBarrierTests` (serialized).
- **§1.2:** WP-F's new test files `EngineFollowBarrierDrainLaneTests.swift`, `EngineFollowBarrierSpaceEpochTests.swift`,
  `EngineFollowBarrierStaleRerouteTests.swift`, `EngineFollowBarrierVerdictApplyTests.swift`,
  `EngineFollowBarrierVerdictLaneTests.swift` and `EngineFollowBarrierWindowTests.swift` under
  `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** the drain-turn test seam `holdDrainFollowUps()`/`releaseDrainFollowUps()` (`ef71ca9`), beside the follow's
  own; no production path sets it.

Cycle 17 adds:

- **§7.10, "Follow barrier (F-28)"**, changes to cycle 16's paragraph:
  - After "the ids the applies followed since its deferral moved", add "Before the verdict, the drain takes off the job
    the ids a visit-first engine's visits had moved off it before the verdict arrived and that are still on it (a later
    apply moved them back), and re-routes them after the verdict; a publication that ended with no apply since keeps
    only the ids the copy lists elsewhere. A visit's join onto a job whose verdict waits waits behind that verdict. An
    attempt's end (its publication's start, or its exit verdict's deferral) first brings onto its job the interests
    other jobs hold in ids the copy maps to its content and whose owed visits would move them".
  - In the 429 sentence, after "the interests other jobs' owed visits move onto it", add "the interests the drain takes
    off a waiting verdict's job and re-routes onto it"; and "less those the verdict answers" becomes "less those the
    verdict's replay answers on the job it meets (a `Retry-After` beyond the kept lane's cap, a park's fail-fast and an
    ENOSPC's verdict included)".
  - "RR-2 to RR-5 and RR-7 to RR-12" becomes "RR-2 to RR-5 and RR-7 to RR-15".
- **`docs/RESIDUAL-RISKS.md` (Stage 5):** RR-11 as rewritten, and RR-13 to RR-15, as written under "Cycle 17".
- **§10.2:** no new row. No new `await` in an actor this cycle.
- **§11:** the cycle-17 tests (`05f94cc`'s setup change, `5414df3`, `6d272ee`, `214dbe3`, `5011067`), all in
  `EngineFollowBarrierTests` (serialized), and `BenchSync.inboundWalkTurns` (`edb1104`) for C2.
- **§1.2:** WP-F's new test files `EngineFollowBarrierHopTests.swift`, `EngineFollowBarrierMovedBeforeTests.swift`,
  `EngineFollowBarrierUnlistedTests.swift` and `EngineFollowBarrierVerdictAnswersTests.swift` under
  `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** no new seam. Three items found while fixing go to the orchestrator: `bringInbound`'s C2 cost in the
  concentration shape, RR-14, and an admission that races an apply omitting its id (all under "Cycle 17", "Put to the
  orchestrator").

Cycle 18 adds:

- **§7.10, "Follow barrier (F-28)"**, changes to cycle 17's paragraph:
  - "An attempt's end (its publication's start, or its exit verdict's deferral) first brings onto its job the interests
    other jobs hold in ids the copy maps to its content and whose owed visits would move them" becomes "An attempt's
    end (its publication's start, or its exit verdict's deferral), and each apply made while a follow is owed for every
    job whose publication runs (under the outgoing copy, before it is replaced), record the moves of the interests other
    jobs hold in ids the copy maps to the job's content and whose owed visits would move them. The attempt's end makes
    the first 64; the follow's turns make the rest, before any visit and within its 256 a turn, each under the copy that
    found it; a move onto a job whose attempt has since ended is dropped, and the holder's visit moves the ids. While a
    move is owed the follow is owed, and a publication binds its ids only once no move onto or off its job is owed".
  - After the deferral sentence, add "A deferred retry reads its `Retry-After` date against the wall clock at the
    failure's arrival".
  - "RR-2 to RR-5 and RR-7 to RR-15" becomes "RR-2 to RR-5, RR-7 to RR-13 and RR-15 to RR-18" (RR-14 is closed).
- **§7.x, the follow's cost (S3F-5's text):** a join writes into the jobs table with no copy of the job alive, O(1)
  amortised, so a job that grows to 10,000 ids keeps a follow turn within C2.
- **`docs/RESIDUAL-RISKS.md` (Stage 5):** RR-15 as rewritten, and RR-16 to RR-18, as written under "Cycle 18". RR-17 is
  marked for the owner: it gives a wrong `notFound` under a race (S3-R21 item 3).
- **§10.2, new row:** `RE-S48 | `publish`'s wait for the moves owed onto or off its job (`awaitInboundMoves`) | the
  lifecycle, and the job at this epoch still verifying: a job retired or replaced meanwhile gets the retired
  publication's exit, the file discarded`.
- **§11:** the cycle-18 tests (`d788d75`, `bfb1c70`, `f662510`, `165ccdd`, `deb5c9d`, `c0bbe09`, `4fb1375`), all in
  `EngineFollowBarrierTests` (serialized), and BenchSync's `concentrationNotFoundTurns`,
  `concentrationPublicationTurns`, `concentrationFollowTurns` and `publicationApplyTurns` (`d788d75`, `70e0801`) for C2.
- **§1.2:** WP-F's new test files `EngineFollowBarrierConvergenceTests.swift` and
  `EngineFollowBarrierPublicationHopTests.swift` under `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** no new seam. RR-18 is put to the orchestrator (under "Cycle 18").

Cycle 19 adds:

- **§7.10, "Follow barrier (F-28)"**, changes to cycle 18's paragraph:
  - "The attempt's end makes the first 64; the follow's turns make the rest, before any visit and within its 256 a
    turn, each under the copy that found it;" becomes "The attempt's end makes the first 64, within half a turn's ids;
    the follow's turns make the rest, before any visit and within 256 holders and 512 ids a turn, each under the copy
    that found it, a move of more ids than the turn has left going on in the next;".
  - After "While a move is owed the follow is owed", add "A visit, the drain's visit after a verdict included, moves
    at most a turn's 512 ids. Its rest goes on first in the follow's next turns once no move is owed, and the follow
    stays owed until its last id moved; the events after the drain's visit wait for it. A visit that moves every id
    off a job that is not publishing supersedes the job in its first turn".
  - "and a publication binds its ids only once no move onto or off its job is owed" becomes "and a publication binds
    its ids only once no move onto or off its job, and no rest of a visit of its job, is owed".
  - In the 429 sentence, add "An id an owed move carries counts by the rule of the move's job while that job is still
    at the attempt's end the move was found for (what its owed visit moves, what the drain takes off it before its
    verdict, and its waiting verdict when an apply was followed since), and by its holder's rule once the move is
    dropped".
  - "RR-2 to RR-5, RR-7 to RR-13 and RR-15 to RR-18" becomes "RR-2 to RR-5, RR-7 to RR-13, RR-15 to RR-17 and RR-19
    to RR-23" (RR-18 is withdrawn).
- **`docs/RESIDUAL-RISKS.md` (Stage 5):** RR-18 withdrawn, its premise corrected (under "Residual risks (S3-R16; cycle
  18)"); RR-19 to RR-22 as written under "Cycle 19", and RR-23 with RR-16 (ruling S3-R24 item 5; moved in cycle
  20).
- **§10.2, RE-S48's row** becomes `RE-S48 | `publish`'s wait for the moves owed onto or off its job and for the rest
  of a visit of it (`awaitInboundMoves`) | the lifecycle; the job stays verifying at its epoch while it waits (an
  invariant checks it), so nothing else is re-read`. No new `await` in an actor this cycle.
- **§11:** the cycle-19 tests (`5dd145a`, `951e19f`, `869ffed`, `4d711f2`, `1b84c6e`, `82045be`, `b8ad024`,
  `3cd80c7`), all in `EngineFollowBarrierTests` (serialized), and BenchSync's `sharedApplyTurns`, `divergenceTurns`
  and `inboundHolderTurns` (`5dd145a`) for C2.
- **§1.2:** WP-F's new source file `EngineMoves.swift` under `Sources/ZTronAssetSync/Engine/`, and its new test files
  `EngineFollowBarrierPendingLaneTests.swift`, `EngineFollowBarrierRestOrderTests.swift`,
  `EngineFollowBarrierSharedMoveTests.swift` and `EngineFollowBarrierTwoTargetsTests.swift` under
  `Tests/ZTronAssetSyncTests/Engine/`.
- **§14:** the seam `EngineState.followIDsPerTurn` (`SyncEngine.followIDsPerTurn`, 512, by default), which the tests
  lower to count the ids each turn moves; no production path sets it.

Cycle 20 adds:

- **§7.10, "Follow barrier (F-28)"**, changes to cycle 19's paragraph:
  - After "the events after the drain's visit wait for it", add "The drain's visits after verdicts share the ids its
    turn has left (the follow's last turn's, or a whole turn's in a drain turn of its own); once they are spent, the
    rest of the batch waits, in order, for the next drain turn".
  - Add "A follow starts only while the engine runs: an apply's end, a catch-up and an unknown-id admission re-read
    the lifecycle before they follow, and an invariant checks that no follow is owed while the engine does not run".
  - The residual-risk list keeps RR-23, which is now recorded within RR-16's entry (ruling S3-R24 item 5).
- **§7.4, "Lanes, dispatch and promotion"**: add "A job's lane, the maximum over its interests, is read from per-lane
  counts that the job keeps on every change to its interests, so reading it is O(1) whatever the number of interests
  (C2)".
- **§10.2, RE-S37's row**: after "or the waiter still registered (admission)", add "; after the admission's view
  read, the lifecycle, before the view is followed (a view read once shutdown began is not followed)". No new `await`
  in an actor this cycle.
- **`docs/RESIDUAL-RISKS.md` (Stage 5):** RR-23 with RR-16 (ruling S3-R24 item 5), as written under "Residual risks
  (S3-R16; cycle 18)". RR-20 stays (S3-R24 item 1). RR-21 is rewritten as under "Cycle 20": the commit window meets
  C2, the commit's re-routes and the drain's take-off miss it, and both are blocking and open, so RR-21 goes into
  `RESIDUAL-RISKS.md` only if the orchestrator rules it a residual risk.
- **§11:** the cycle-20 tests (`8cfc76e`, `f066083`, `ca6df35`, `429ace5`, `431d397`, `c2f9e31`): all are in
  `EngineFollowBarrierTests` (serialized), except `EngineInterestCountsTests`. BenchSync adds `drainVerdictTurns`
  (`8cfc76e`, `e39a076`), `userSharedApplyTurns` (`8cfc76e`), and `concentrationCommitRerouteTurns` and
  `movedBeforeDrainTurns` (`c03c0e8`). `concentrationPublicationTurns` now goes through the commit (`c03c0e8`).
- **§1.2:** WP-F's new test files, under `Tests/ZTronAssetSyncTests/Engine/`:
  `EngineFollowBarrierDrainBoundTests.swift`, `EngineFollowBarrierLegacyTargetTests.swift`,
  `EngineFollowBarrierMoveRevalidationTests.swift`, `EngineFollowBarrierTurnTotalTests.swift`,
  `EngineFollowShutdownTests.swift` and `EngineInterestCountsTests.swift`. No new source file.
- **§14:** the seam `EngineState.admissionsForTests` (`nil` by default): a test sets it to `[]` and reads each
  admission (transfer, ticket, queue place, attempt) in the engine's order. No production path sets it.
  `Job.interestCounts` is settable inside the module, so the counts clause can be exercised. Only `Job`'s mutators
  change it in production code.

## Gate evidence (cycle 1)

All runs on this branch at `60eab9c`/HEAD (tests only changed after `60eab9c`: two `try` markers), scratch
`.build-s3f*`, on a shared host whose load swung from 20 to 630 during the runs (loads quoted per step).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (12:25, load 630→51): `VERIFY: PASS`; Transport 151,
  Sync 374, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. The first `--quick` (11:52)
  ended `VERIFY: FAIL (1 failed: tests)`: the new S1-11 test's first form read a `failed(.at)` state the jittered retry can
  skip (`EngineSync1RegressionTests.swift:116:9`); rewritten in `60eab9c` (S3F-14), no production change.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors`: `Build complete!
  (105,63 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug): `✔ Test run with 374 tests in 52 suites passed` after 11.04 s, 8.41 s, 8.34 s
  (load 48.6–77.0).
- **TSan once** (`.build-s3f-tsan`): `✔ Test run with 374 tests in 52 suites passed after 74.410 seconds` (load ~59);
  the S3F-2 tests took 13.1 s (R-CAR-4), 32.7 s (R-SYN-14), 32.8 s (R-SYN-6), 39.8 s and 40.8 s (R-STO-11), 55.3 s
  (R-SYN-2 model walk), each within its guard.
- **Coverage** (`--enable-code-coverage`, all targets passed): `COVERAGE target=ZTronAssetSync lines= 93.60% (8804/9406)
  min=90.0 OK`, overall 96.56 %, `COVERAGE: PASS`.
- **iOS:** `xcodebuild … -destination 'generic/platform=iOS' … OTHER_SWIFT_FLAGS='-warnings-as-errors'` exit 0. **iOS
  Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.29_12-30-58`):
  `result Passed, totalTestCount 1328, passedTests 1328, failedTests 0, skippedTests 0`. The first simulator run (12:07)
  failed to build: `EngineClaimRetryTests.swift:48:9: error: no calls to throwing functions occur within 'try' expression`
  under `-warnings-as-errors`; fixed with the second marker in the same pattern. Simulator shut down afterwards.
- **Mutants (S3-R3)**, scratch copy `.build-s3f/mut/src`: all ten killed (S3-CONF-02, -03, -04, -05; M-N-09, -12, -14,
  -16, -20, -39); failing lines under each item.
- **WP-F benchmarks** (`swift test -c release … --filter SyncBenchmarks`, 12:36–12:40, load 113→23): 18 of 19 passed:
  P-4 12.64 ms (ratio 2.12), P-7 4.09/1.80 MiB, P-11 speedup 3.22, P-14 0/0; the new C2 benchmarks shutdown 1.38–1.55 ms,
  refresh 1.21–1.26 ms, prune announcement 4.94–5.05 ms, due retries 0.87–0.96 ms; the existing C2 benchmarks 0.02–9.94
  ms best. `R-SYN-5: a 429 that extends the throttle under 10,000 user-initiated waiters …` missed (runs [38.71, 21.83,
  44.47] ms at load ~110–200) and passed alone right after at load 22–29 (runs [6.77, 7.54, 7.18] ms): a load miss.
  `R-SYN-5: a chain of half-open probes …` passed in the full run (best 2.19 ms) but failed once alone at load ~22–29
  (runs [16.02, 35.68, 81.45] ms); compared head to head with `s3-base` (release, same host, 12:47–12:49, load 305→91):
  base [33.30, 21.10, 44.89] ms (fail) then [6.39, 2.59, 3.06] ms (pass); HEAD [6.52, 4.13, 4.90] ms then [2.34, 8.63,
  394.13] ms (both pass); chain totals base 4.0–11.3 s, HEAD 5.1–10.9 s. A load miss on both trees, not a regression
  (S3F-13 still owes this benchmark's quadratic total).

## Gate evidence (cycle 2)

All runs on this branch at `a528809` (HEAD of the code; the draft's own commit changes this file only), scratch
`.build-s3f*`, on the shared 8-core host whose load swung from 4 to 200 during the runs (loads quoted per step).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (16:16–16:20, load 28→15): `VERIFY: PASS`; Transport
  151, Sync 399, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. (An earlier `--quick` at
  `eab2d5b`, 15:42–15:47, also `VERIFY: PASS`.)
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (15:47): `Build
  complete! (29,19 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug, load 31–36): `✔ Test run with 399 tests in 52 suites passed` after 19.83 s, 17.92 s,
  12.14 s. (Also ×3 at `eab2d5b`, load 8.6–16.8: 12.17 s, 13.37 s, 10.66 s.)
- **TSan once** (`.build-s3f-tsan`, 16:11–16:13, load 200→51): `✔ Test run with 399 tests in 52 suites passed after
  61.554 seconds`. The longest: the S1-15 run test 61.5 s (guard 3 min; it was 59.93 s of its former 60 s in the run at
  `eab2d5b`, 15:49–15:51, load 11–18, `✔ … 399 tests … passed after 59.931 seconds`), the stalled-subscriber test 49.1 s
  (guard 4 min), the gate walks 40.8 s and 40.6 s and the model walk 40.2 s (guards 5 min); every cycle-2 test under 20 s
  (the alarm-turn bound 18.7 s, the shutdown drain 13.7 s, the bounded follow 13.5 s at load 11–18).
- **Coverage** (`--enable-code-coverage`, all seven test targets passed, 16:04–16:11): `COVERAGE target=ZTronAssetSync
  lines= 94.04% (9187/9769) min=90.0 OK` (cycle 1: 93.60 %, 8804/9406), overall `96.68% (25695/26577)`, `COVERAGE:
  PASS`. (`ZTronAssetKit 97.63% (1441/1476)` against 97.83 % before: WP-G's schedule-dependent lines, §14; no Kit file
  changed.)
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (15:52). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.29_15-52-52-+0100.xcresult`, 15:52–15:58,
  load 20→143): `result Passed, totalTestCount 1353, passedTests 1353, failedTests 0, skippedTests 0` (`** TEST SUCCEEDED
  **`); the simulator is shut down.
- **Mutants (S3-R3 practice, scratch edits in place, each rebuilt and reverted; `git status` clean after each):** S1-11's
  strand, the settle without chunks, `fireDue` without its limit, the follow without its visit bound and without its
  settle guard, `manifestCaughtUp` without its follow guard, the eager breaker re-admission, the missing pump-end hook,
  the parked order without its rank check, M5, M6, the alarm without its token check, a stale watcher unregistering its
  successor, the ledger without committed bytes, an abandon without a breaker outcome: all killed (lines under each
  item and in "Cycle 2").
- **WP-F benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter
  SyncBenchmarks`, 15:59–16:04, load 53.7→5.1): `✔ Test run with 20 tests in 2 suites passed after 213.772 seconds`.
  P-4 11.53 ms (budget 20.0), ratio 2.05 (max 2.5); P-7 4.89 / 0.97 MiB; P-11 speedup 3.15 (min 3.0); P-14 0 timers, 0
  tasks; the stalled prune ratio 1.41. C2 (best of three, ms): the new `changedRefreshTurns` [3.73, 3.71, 3.75]; the
  probe chain at 10,000 [0.76, 0.73, 0.86], totals [40.3, 48.5, 44.1] s; cooldown end [0.07, 0.06, 0.07]; shutdown
  [1.75, 1.53, 1.37]; refresh under a group [1.22, 1.22, 1.27]; prune announcement [5.01, 5.00, 4.99]; due retries [0.86,
  0.86, 0.90]; releases 4.6–4.9; re-joins 4.9–5.1; space parking 4.1–4.2 and 3.1–3.6; space re-admission 4.4–4.6; network
  edges 1.1 and 4.5–4.6; throttle extension [14.39, 7.14, 17.22] (best 7.14, passing). The cycle-1 verifiers' load misses
  (P-4 at loads 13–189, P-11 2.51, the throttle extension's 20.6 ms best) did not recur at this load; P-4 and P-11 rest on
  code this close-out did not touch.

## Gate evidence (cycle 3)

All runs on this branch at `776748a` (the code's HEAD; the draft's commit changes this file only), scratch `.build-s3f*`,
on the shared 8-core host whose load swung from 4 to 360 during the cycle (loads quoted per step).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (19:08–19:12, load 5.4→10.9): `VERIFY: PASS`;
  Transport 151, Sync 404, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. (Also
  `VERIFY: PASS` at `758c22f`, 17:46–17:58, load ~100.)
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (19:14): `Build
  complete! (55,33 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug, 19:15–19:18, load 14–34): `✔ Test run with 404 tests in 52 suites passed after
  20.876 seconds`, `20.842 seconds`, `15.418 seconds`.
- **TSan once** (`.build-s3f-tsan`, 19:12–19:14, load 9.1→6.5): `✔ Test run with 404 tests in 52 suites passed after
  55.005 seconds`. Every test within its guard; this cycle's tests: the prefetch-member 404 test 15.3 s, the dropped-id
  user test 11.5 s, the W1 test 11.2 s, the parameterised waiter test 10.7 s (all three cases), the others under 9 s.
  **S3-R4 re-measurement** of the cycle-2 tests the verifiers flagged (60 s guards): the alarm turn 23.65 s (39 %), the
  shutdown drain 17.9 s, the bounded follow 17.1 s in this run; alone (18:12, load 141→75) 3.0 s, 2.0 s and 11.2 s; in a
  full TSan run at load 358→224 (18:07–18:11, `✔ … 403 tests … passed after 132.604 seconds`) 48.9 s, 35.6 s and 33.9 s,
  no time-out. At load at most about 30 each stays under half its limit, so by S3-R4 no guard changed; the 48.9 s at
  load 220–360 is recorded for the orchestrator's two-process re-measurement at the merge. A second TSan process beside
  this one was not run (the host's own load stood in for it).
- **Coverage** (`--enable-code-coverage`, all seven test targets passed, 19:18–19:21): `COVERAGE target=ZTronAssetSync
  lines= 94.01% (9242/9831) min=90.0 OK` (cycle 2: 94.04 %, 9187/9769), overall `96.67% (25751/26639)`, `COVERAGE: PASS`.
  Of this cycle's new Sync lines only two are unrun: the reset of `pumpWaitsForFollow` on the follow's unspawnable
  follow-up (shutting down; the branch was already unreached) and the new invariant rule's message.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (19:21). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.29_19-22-01-+0100.xcresult`, 19:22–19:27,
  load 6→105): `result Passed, totalTestCount 1358, passedTests 1358, failedTests 0, skippedTests 0` (`** TEST SUCCEEDED
  **`); the simulator is shut down.
- **WP-F benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter
  SyncBenchmarks`, 19:27–19:34, load 76→17): `✘ Test run with 20 tests in 2 suites failed after 226.391 seconds with 2
  issues`; 18 passed. P-4 13.03 ms (budget 20.0), ratio 2.08 (max 2.5); P-7 5.48 / 0.52 MiB; P-14 0 timers, 0 tasks; the
  stalled prune ratio 1.35. C2, runs in ms: refresh changing every member of a 10,000-member group [3.84, 3.87, 4.17]
  (the follow this cycle changed); refresh under a group [1.31, 1.38, 1.24]; shutdown [1.44, 1.55, 1.48]; due retries
  [0.91, 0.99, 0.99]; prune announcement [5.08, 4.93, 5.04]; releases 4.8–5.1; re-joins 5.1–5.5; space parking 4.3–5.0
  and 3.9–4.1; space re-admission 5.2–5.3; network edges 1.1–1.2 and 5.1–5.5; cooldown end 0.07–0.08; cancelled resolve
  0.02–0.03; throttle extension [12.42, 8.07, 8.20] (best 8.07, passing). The two issues, each compared head to head
  with `e91b9c7` (cycle 2's code, an archive built in `.build-s3f/perf-base`, run alternately on the same host):
  - P-11 speedup 2.98 (min 3.0) at load 76–150; alone right after (19:58–20:00, load 7.4→6.0): HEAD 3.18 and 3.20, base
    3.18 and 3.18, all passing. A load miss.
  - `probeChainTurns` exceeded its 3-minute limit (`BenchSync.swift:439:10: Time limit was exceeded: 180.000 seconds`):
    the chain's wall time, which is reported and not budgeted (a warm-up and three 10,000-member chains of about 60 s
    each on this host now; 40–48 s in cycle 2). HEAD alone first (19:34–19:37, load 11→29): totals [62.0, 86.9, 35.1] s,
    waits [63.60, 68.68, 115.11] ms (C2 and P-9 missed too). The base exceeds the limit the same way: base at load 26→6 totals [64.5, 63.6,
    59.1] s, waits [1.17, 72.77, 1.43] ms; HEAD right after at load 6→5 totals [64.2, 59.5, 61.3] s, waits [3.92, 11.16,
    4.21] ms; HEAD again at load 4.8→19 totals [62.4, 97.3, 24.8] s, waits [2.64, 37.42, 88.81] ms; the base again was
    stopped by the limit before it printed. The C2 waits are as noisy on both trees (one 72.8 ms run on the base, the
    verifier's 43 ms in cycle 2); best and median pass in the HEAD runs at load ≤ 6. A load and wall-time miss shared with
    the base, not a regression; the benchmark's own limit is the orchestrator's call at the merge (S3-R4 governs TSan
    test guards; this cycle did not change it).
- **Mutants of the fix** (in place on `776748a`, each rebuilt, run and reverted; filter
  `replacedContentFailure|noReplacedContentStarts|droppedUserJobWaitsForTheFollow`):
  - `noResolveAllHook`: `EngineFollowTests.swift:275:9: … argument failure → .notFound … Expectation failed: (try?
    answer.get()) != nil`, `:276:9`, `:323:9` (`after.pending == [replacement.transferID]`), `:324:9`.
  - `noCountHook`: `:275:9 … → .serverErrorAtCap`, `:276:9`.
  - `noSpaceHook`: `:275:9 … → .noSpace`, `:276:9`.
  - `noDispatchStall`: `:368:9: Expectation failed: startedBetween.isEmpty`, `:369:9`, `:376:9`, and `:433:9`
    (`!startedBetween.contains(dropped.transferID)`), `:434:9`, `:435:9`.
  - `listedOnlyAtDispatch`: `:433:9`, `:434:9`, `:435:9`, `:443:9`.
  - `owedVisitsOnly`: `:323:9`, `:324:9`.
  - `userHeadCounted`: `:435:9: Expectation failed: between.steady == .downloading`.
  - `noFlagPump` (both `|| pumpWaitsForFollow` terms removed): survives, recorded above (`✔ Test run with 403 tests in
    52 suites passed`, run at `758c22f`).
- **Mutants of the non-blocking items** (in place, each rebuilt, run and reverted): lines in the "Cycle 3" table; the
  M5, close-only M5 and M6 runs are on `e58a34f` (`closeStore()`).

## Gate evidence (cycle 4)

All runs on this branch at `07ca8cb` (the code's HEAD; the draft's commit changes this file only) unless a step names an
earlier commit, scratch `.build-s3f*`, on the shared 8-core host whose load swung from 3 to 464 during the cycle (loads
quoted per step).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (at `340a28b`, 22:59–23:03, load 17→7): `VERIFY:
  PASS`; Transport 151, Sync 405, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. (Also
  `VERIFY: PASS` at 22:10–22:15 on the tree before the guard and benchmark commits.)
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (22:09, sources as
  at `07ca8cb`): `Build complete! (27,92 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug, 22:30, load 36–51): `✔ Test run with 405 tests in 52 suites passed after 13.685
  seconds`, `14.199 seconds`, `13.518 seconds`.
- **TSan once** (`.build-s3f-tsan`, the whole bundle run directly, 22:47–22:48, load 3.7–8.6): `✔ Test run with 405
  tests in 52 suites passed after 60.633 seconds`; beside a second TSan process (22:48–22:50, load 12–32) both `✔ Test
  run with 405 tests in 52 suites passed after 101.795 seconds` / `101.806 seconds`, no time-limit line. Per-test
  durations in the tables under "Cycle 4".
- **Coverage** (`--enable-code-coverage`, all seven test targets passed, 22:31–22:34): `COVERAGE target=ZTronAssetSync
  lines= 94.03% (9254/9842) min=90.0 OK`, overall `96.68% (25765/26650)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (22:10, sources as at `07ca8cb`). **iOS Simulator tests**
  (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.29_22-50-34-+0100.xcresult`,
  22:50–22:57, load 27 at the start): `"result" : "Passed"`, `"totalTestCount" : 1359`, `"passedTests" : 1359`, `"failedTests" : 0`,
  `"skippedTests" : 0` (`** TEST SUCCEEDED **`); the simulator is shut down.
- **WP-F benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter
  SyncBenchmarks`, 22:44:57–22:46:27, load 2.95–3.42): `✔ Test run with 20 tests in 2 suites passed after 90.579
  seconds`. P-4 12.04 ms (budget 20.0), ratio 2.24 (max 2.5); P-7 4.89 / 0.31 MiB; P-11 speedup 3.43 (min 3.0); P-14 0
  timers, 0 tasks; the stalled prune ratio 1.43. C2, runs in ms: probe chain [0.54, 1.21, 0.32] (totals [1.13, 1.16,
  1.14] s); throttle extension [7.15, 7.81, 6.75]; refresh changing every member [3.67, 3.71, 3.65]; refresh under a
  group [1.23, 1.20, 1.21]; shutdown [1.36, 1.43, 1.39]; due retries [0.84, 0.85, 0.83]; prune announcement [5.00, 4.90,
  4.91]; releases 4.15–4.58 and 4.33–4.48; re-joins 4.57–4.72; space parking 4.02–4.51 and 2.72–3.13; space re-admission
  3.90–4.28; network edges 1.04–1.10 and 4.14–4.33; cooldown end 0.06–0.12; cancelled resolve 0.02. (At `2211585`,
  with the 400 exits but before the priority change, the same run at load 3–4 failed only in `probeChainTurns`: `BenchSync.swift:443:10: Time
  limit was exceeded: 180.000 seconds`, totals [87.9, 71.6, 22.3] s.)

## Gate evidence (cycle 5)

All runs on this branch at `72b2ab2` (the code's HEAD; the draft's commit changes this file only) unless a step names an
earlier commit, scratch `.build-s3f*`, on the shared 8-core host whose load swung from 3.7 to 94 during the cycle (loads
quoted per step, 1-minute averages).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (01:12–01:17, load 13.6→9.5): `VERIFY: PASS`;
  Transport 151, Sync 406, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. (Also `VERIFY:
  PASS` at `007a2bb`, 00:44–00:48.)
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (at `007a2bb`, whose
  sources are `72b2ab2`'s): `Build complete! (30,22 s)`, exit 0.
- **Gates** (sources as at `72b2ab2`): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public
  declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (debug, 01:17–01:18, load 9.5–14): `✔ Test run with 406 tests in 52 suites passed after
  12.605 seconds`, `11.676 seconds`, `11.426 seconds`. (At `007a2bb`, load 10–19: `11.617`, `11.548`, `11.509 seconds`.)
- **TSan once** (`swift test --skip-build --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, 00:55–00:57, load 3.7–4.7): `✔ Test run with 406 tests in 52 suites passed after 47.507
  seconds`; no ThreadSanitizer report, no time-limit line. Beside a second TSan process (`.build-s3f/run-direct.sh`,
  00:57–00:58, load 4.1–13.9): `✔ Test run with 406 tests in 52 suites passed after 79.189 seconds` / `79.503 seconds`.
  (At `007a2bb`, alone, load 13–17: `passed after 72.273 seconds`.) Per-test figures under "Cycle 5".
- **Coverage** (`--enable-code-coverage`, all seven test targets passed, 00:58–01:02): `COVERAGE target=ZTronAssetSync
  lines= 94.08% (9270/9853) min=90.0 OK`, overall `96.68% (25775/26661)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (01:02). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.30_01-02-31-+0100.xcresult`, 01:02–01:08,
  load 8 at the start, 82 at the end): `"result" : "Passed"`, `"totalTestCount" : 1360`, `"passedTests" : 1360`,
  `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED **`); the simulator is shut down.
- **WP-F benchmarks** (`swift test -c release --skip-build --scratch-path .build-s3f-perf --filter SyncBenchmarks` after
  `swift build -c release --build-tests --scratch-path .build-s3f-perf -Xswiftc -enable-testing`, 01:09:48–01:11:20, load
  13.4–18.5): `✘ Test run with 21 tests in 2 suites failed after 89.494 seconds with 1 issue`: 20 of 21 pass, the one
  miss is the throttle extension, best 13.15 ms ([13.15, 16.20, 13.60]), `BenchSync.swift:478:13`, a benchmark this cycle
  did not touch (no follow is owed and no job is parked for space in it, so the sweep's budget never runs). Re-run alone
  twice right after: load 13.6–17.7 [23.65, 16.20, 12.31] ms (miss), load 17.7–14.4 [13.51, 9.51, 6.51] ms, `✔ Test run
  with 1 test in 2 suites passed after 22.557 seconds`; cycle 4 measured [7.15, 7.81, 6.75] at load 3 and the cycle-4
  verifier a pass at load 11–14, so the miss is load only (S3-R5). The other figures: P-4 11.78 ms (budget 20.0), ratio
  2.03 (max 2.5); P-7 3.88 / 1.52 MiB; P-11 speedup 3.26 (min 3.0); P-14 0 timers, 0 tasks; the stalled prune ratio
  1.44. C2, runs in ms: the new reclaim during an owed follow [6.55, 6.33, 6.43] (one handle) and [7.06, 8.21, 7.30]
  (two handles); probe chain [1.45, 12.04, 9.14] (totals [1.85, 1.93, 1.93] s); refresh changing every member [4.02,
  3.77, 3.76]; refresh under a group [1.26, 1.25, 1.25]; shutdown [1.40, 6.07, 2.74]; due retries [0.84, 0.92, 0.92];
  prune announcement [4.98, 4.89, 4.90]; releases 4.75–5.26 and 4.39–5.27; re-joins 8.21–17.27 and 8.42–13.80; space
  parking 4.10–9.56 and 4.05–5.20; space re-admission 5.41–8.68; network edges 1.12–1.26 and 4.83–6.05; cooldown end
  0.00–0.28; cancelled resolve 0.00–0.14. The new benchmark alone at load 4.6–7.4: [5.60, 6.02, 5.42] and [6.62, 6.47,
  6.55] ms.

## Gate evidence (cycle 6)

All runs on this branch at `daa2ba8` (the code's HEAD; the draft's commit changes this file only), scratch
`.build-s3f*`, on the shared 8-core host, where other close-outs' verifiers drove the load from 6 to 571 during the cycle
(loads quoted per step, 1-minute averages).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (04:33:17–04:37:52, load 12.8 → 178): `VERIFY: PASS`;
  `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 408, Storage 459 (`passed after 73.124 seconds`), Model
  84, Kit 85, Compatibility 71, AppleHosted 104 tests passed.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (04:38–04:39, load
  143 → 94): `Build complete! (46,91 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  04:40–04:41, load 87 → 27): `✔ Test run with 408 tests in 52 suites passed after 15.033 seconds`, `12.214 seconds`,
  `11.380 seconds`.
- **TSan once** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, 04:41:08–04:42:28, load 10.9–23.5): `✔ Test run with 408 tests in 52 suites passed after
  49.793 seconds`; no `WARNING: ThreadSanitizer` line, no time-limit line. Beside a second TSan process
  (`.build-s3f/run-direct.sh`, 05:15:31–05:16:59, load 6.1–25.6): `passed after 84.589 seconds` / `84.829 seconds`,
  no report; the earlier paired run at load 7.9 → 54.7: `passed after 175.722 seconds` / `175.847 seconds`, no report.
  Per-test figures under "Cycle 6".
- **Coverage:** the `--quick` run above is `swift test --scratch-path .build-s3f --enable-code-coverage --skip
  Benchmarks` (every target passed); exported with `xcrun llvm-cov export -summary-only -instr-profile
  .build-s3f/out/Products/Debug/codecov/default.profdata` over the eight test binaries: `COVERAGE target=ZTronAssetSync
  lines= 93.96% (9271/9867) min=90.0 OK`, overall `96.65% (25782/26675)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exit 0 (04:46). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.30_04-46-59-+0100.xcresult`,
  04:46:52–04:53:33, load 46 → 571): `"result" : "Passed"`, `"totalTestCount" : 1362`, `"passedTests" : 1362`,
  `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED **`); the simulator is shut down.
- **WP-F benchmarks** (`swift test -c release --skip-build --scratch-path .build-s3f-perf --filter SyncBenchmarks` after
  `swift build -c release --build-tests --scratch-path .build-s3f-perf -Xswiftc -enable-testing`, 05:14:21–05:15:21, load
  7.4–11.8): `✔ Test run with 21 tests in 2 suites passed after 56.821 seconds`, every one within its budget. The reclaim
  during an owed follow [6.54, 6.61, 6.38] ms (one handle) and [7.26, 6.97, 6.76] ms (two handles); P-4 11.61 ms
  (budget 20.0), ratio 2.02 (max 2.5); P-7 3.97 / 1.53 MiB; P-11 speedup 3.25 (min 3.0); P-14 0 timers, 0 tasks; the
  stalled prune ratio 1.44; space parking [4.13, 4.39, 4.33] ms; space re-admission [4.64, 4.76, 4.76] ms; network edges
  1.13–1.15 and 4.47–4.56 ms; releases 4.88–5.14 and 4.90–5.22 ms; re-joins 5.09–5.49 and 5.06–5.67 ms; shutdown [1.54,
  1.44, 2.39] ms; refresh under a group 1.25–1.29 ms, changing every member 3.74–3.82 ms; prune announcement 5.07–5.08 ms;
  due retries 0.93–0.95 ms; cancelled resolve 0.02–0.05 ms; cooldown end 0.04–0.07 ms; probe chain longest wait 0.25 ms
  (totals 1.12–1.16 s); throttle extension [6.62, 6.91, 7.43] ms.

## Gate evidence (cycle 7)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host, where other close-outs' verifiers drove the
1-minute load from 5 to 510 during the cycle (loads quoted per step). The code (`Sources/`) is unchanged since `22c7b89`;
`1602a8b` and `7499908` change test traits and doc comments only. The final-tree runs are at `7499908` (the draft's
commit changes this file only).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** at `7499908` (06:58:04–07:01:28, load 5.5 → 8.0):
  `VERIFY: PASS`; `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 411 (`passed after 13.534 seconds`),
  Storage 459 (`70.308 seconds`), Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed. An earlier `--quick`
  at `1602a8b` (06:34:36–06:38:42, load 5.3 → 14.2) also ended `VERIFY: PASS`.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` at `1602a8b` (same
  `Sources/` as the final tree; 06:39, load 10.6): `Build complete! (27,36 s)`, exit 0.
- **Gates** (06:39, same `Sources/`): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** at `7499908` (`swift test --scratch-path .build-s3f --skip Benchmarks --filter
  ZTronAssetSyncTests`, 07:01:35–07:04:17, load 7.4 → 37): `✔ Test run with 411 tests in 52 suites passed after 23.056
  seconds.`, `29.993 seconds.`, `29.605 seconds.` (at `1602a8b`, load 7.7–12.2: `11.453`, `11.395`, `11.439 seconds`).
- **TSan once** at `7499908` (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, 07:04:17–07:06:55, load 153–210, another close-out's run): `✔ Test run with 411 tests in 52
  suites passed after 110.010 seconds.`; no `WARNING: ThreadSanitizer` line, no time-limit line. At `1602a8b`
  (06:41:03–06:42:45, load 6.6–10.4): `passed after 51.782 seconds`, no report, no time-limit line. Paired runs and
  per-test figures under "Cycle 7".
- **Coverage:** the final `--quick` run above runs the tests with `--enable-code-coverage`; exported with `xcrun llvm-cov
  export -summary-only -instr-profile .build-s3f/out/Products/Debug/codecov/default.profdata` over the seven
  non-benchmark test binaries: `COVERAGE target=ZTronAssetSync lines= 93.96% (9290/9887) min=90.0 OK`, overall `96.64%
  (25798/26695)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` at `7499908`, exit 0 (06:47). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0; `Test-ZTronAssetKit-2026.10.30_06-47-43-+0100.xcresult`,
  06:47:39–06:53:39, load 148 → 510 with another close-out's simulator run): `"result" : "Passed"`, `"totalTestCount" :
  1365`, `"passedTests" : 1365`, `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED **`); the simulator is
  shut down.
- **WP-F benchmarks** (`swift test -c release --skip-build --scratch-path .build-s3f-perf --filter SyncBenchmarks` after
  `swift build -c release --build-tests --scratch-path .build-s3f-perf -Xswiftc -enable-testing` at `7499908`,
  06:56:35–06:57:47, load 6.5–12.8): `✔ Test run with 21 tests in 2 suites passed after 69.195 seconds.`, every one
  within its budget. The reclaim during an owed follow [5.86, 6.19, 7.17] ms (one handle) and [6.63, 8.06, 10.96] ms
  (two handles; best 6.63 of the 10 ms budget); P-4 11.92 ms (budget 20.0), ratio 2.03 (max 2.5); P-7 5.14 / 0.69 MiB;
  P-11 speedup 3.21 (min 3.0); P-14 0 timers, 0 tasks; the stalled prune ratio 1.35; space parking [4.07, 4.29, 4.12] ms;
  space re-admission [4.61, 4.74, 5.18] ms; network edges 1.09–1.17 and 4.56 ms; releases 4.47–4.98 and 4.45–5.26 ms;
  re-joins 4.75–5.33 and 4.72–5.39 ms; shutdown [1.57, 1.46, 1.35] ms; refresh under a group 1.22–1.28 ms, changing
  every member 3.80–3.91 ms; prune announcement 5.00–5.12 ms; due retries 0.89–0.95 ms; cancelled resolve 0.02 ms;
  cooldown end 0.07–0.10 ms; probe chain longest wait 0.23 ms (totals about 1.1 s); throttle extension [6.59, 6.22,
  7.25] ms.
- **`git status`:** clean after the draft's commit; `docs/TRACEABILITY.md` untouched (no `--gates-only` or `--full`
  run).

## Gate evidence (cycle 8)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host (1-minute load 2 to 19 through the cycle's
test, TSan and benchmark runs; it reached 50.5 at the end of the simulator run). The code (`Sources/`) is final at `1b771e8`; `4812937` and `1b21195` add a test and change test traits and doc comments
only. The final-tree runs are at `1b21195` (the draft's commit changes this file only); `.build-s3f/verify-all.sh`
ran the first six steps in order (08:26–08:35).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (08:26–08:29, load 3.4 → 5.3): `VERIFY: PASS`;
  `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 415 (`passed after 12.658 seconds`), Storage 459
  (`62.830 seconds`), Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests passed.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (08:29, load 5.3):
  `Build complete! (27,53 s)`, exit 0.
- **Gates:** `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0
  fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  08:29–08:31, load 4.6–9.4): `✔ Test run with 415 tests in 52 suites passed after 12.108 seconds.`, `12.132 seconds.`,
  `12.114 seconds.`
- **TSan once** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, 08:31–08:32, load 7.5–10.2): `✔ Test run with 415 tests in 52 suites passed after 54.374
  seconds.`; no `WARNING: ThreadSanitizer` line, no time-limit line; no test over half its guard (the longest one-minute
  test 14.6 s; `stalledSubscriberIsBounded` 49.8 s, S1-15's run test 54.4 s). Paired and alone runs under "Cycle 8".
- **Coverage** (`swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks`, 08:32–08:35, every
  bundle passed; `xcrun llvm-cov export -summary-only -instr-profile .build-s3f/out/Products/Debug/codecov/default.profdata`
  over every test binary; `python3 Scripts/gates.py coverage --json .build-s3f/cov.json`): `COVERAGE target=ZTronAssetSync
  lines= 94.02% (9288/9879) min=90.0 OK`, overall `96.66% (25796/26687)`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, exit 0 (08:36:01–08:36:08, load 5.1; `EngineJobs.o` for `arm64`
  rebuilt at 08:36). **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iOS 27.0;
  `Test-ZTronAssetKit-2026.10.30_08-36-12-+0100.xcresult`, 08:36:08–08:39:16, load 4.8 → 50.5): `"result" : "Passed"`,
  `"totalTestCount" : 1369`, `"passedTests" : 1369`, `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED
  **`; 1,365 in cycle 7 plus this cycle's four); the simulator is shut down.
- **Benchmarks** (the full command, `swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing
  --filter Benchmarks`, after its build, at `4812937` (the same `Sources/` and `BenchSync.swift`), 08:13:12–08:18:54,
  load 2.4–4.9): `✘ Test run with 41 tests in 8 suites failed after 229.955 seconds with 1 issue.`, the issue P-13's
  (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, WP-B's, `other-wp:b`); `✔ Suite
  "SyncBenchmarks" passed after 96.124 seconds.`, every WP-F benchmark within its budget: the reclaim during an owed
  follow [7.85, 5.28, 5.13] ms (one handle) and [6.27, 6.06, 6.17] ms (two handles); P-4 11.40 ms (budget 20.0), ratio
  2.01 (max 2.5); P-7 0.83 / 0.13 MiB; P-11 speedup 3.76 (min 3.0); P-14 0 timers, 0 tasks; the stalled prune ratio
  1.41; space parking [4.03, 4.05, 4.02] ms, its ENOSPC read [3.29, 2.95, 2.63] ms; space re-admission [3.87, 4.04,
  3.74] ms; network edges [1.02, 1.02, 1.06] and [3.92, 4.60, 4.02] ms; releases [4.05, 4.12, 4.15] and [4.23, 4.19,
  4.31] ms; re-joins [4.61, 4.62, 4.56] and [4.60, 4.63, 4.64] ms; shutdown [1.47, 1.41, 1.43] ms; refresh under a
  group [1.26, 1.20, 1.20] ms, changing every member [3.74, 3.73, 3.95] ms; prune announcement [4.92, 4.97, 4.91] ms;
  due retries [0.90, 0.85, 0.84] ms; cancelled resolve 0.02 ms; cooldown end 0.06 ms; probe chain longest wait 0.19 ms
  (totals about 1.1 s); throttle extension [6.71, 6.61, 6.61] ms.
- **`git status`:** clean after the draft's commit; `docs/TRACEABILITY.md` untouched (no `--gates-only` or `--full`
  run).

## Gate evidence (cycle 9)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host. The code (`Sources/`) is final at `5221f9f`;
`0f21af8`, `cecf5aa`, `d8de247` and `f91f108` change tests and benchmarks only. The final-tree runs are at `f91f108`
(the draft's commit changes this file only); `.build-s3f/c9-final.sh` ran `--quick`, the coverage export, the Sync
bundle ×3 and the release build in that order (14:40:05–14:46:38).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (14:40:05–14:43:26, 1-minute load 3.8–18.7, mean
  12.9): `VERIFY: PASS`; `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 438 (`passed after 20.558
  seconds`), Storage 459 (`81.404 seconds`), Model 84 (`66.524 seconds`), Kit 85, Compatibility 71, AppleHosted 104
  tests passed. An earlier `--quick` at `d8de247` (14:10:54–14:16:47, load 23.3 → 27.9) also ended `VERIFY: PASS`; the
  one before it, at `cecf5aa` (ended 14:01), ended `VERIFY: FAIL (1 failed: tests)`: the follow tests' waits that
  `d8de247` fixes (the wait-only list under "Cycle 9").
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (14:46:09–14:46:38,
  load 15.2): `Build complete! (28,97 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md` and `docs --sources
  "$PWD/Sources"`, 14:38): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  14:43:26–14:46:08, after the rebuild without coverage; load 12.8–17.4 over the three runs): `✔ Test run with 438 tests
  in 52 suites passed after 24.447 seconds.`, `24.067 seconds.`, `21.970 seconds.`
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`). Run 1 at `d8de247` (14:19:05–14:22:56; S3-R12 load, from 60 s after the start, mean 19.34, min
  7.79, max 30.49 over 34 samples): `✘ Test run with 438 tests in 52 suites failed after 192.889 seconds with 2
  issues.`, both in `barrierDecidesAnENOSPCOnTheFollowedState`'s `.followVisitedFirst` case (the time limit, and the
  U-waiter expectation after the cancelled wait): a time-out at a mean of 50 or less, so blocking under S3-R12 (2). The
  cause was the test's wait for an exact free-space figure (the wait-only list under "Cycle 9"); fixed in `f91f108`. Run
  2 on the tree committed as `f91f108` (14:26:28–14:28:31; mean 9.68, min 7.53, max 11.27 over 13 samples): `✔ Test run
  with 438 tests in 52 suites passed after 86.452 seconds.`; no `WARNING: ThreadSanitizer` line, no time-limit line.
  Margins (a single run, so recorded under S3-R12 (2)): the 19 `EngineFollowBarrierTests` tests 48.4–60.7 s and the 8
  `EngineSweepOrderTests` ones 52.7–53.7 s, at most 33.7 % of `.minutes(3)`; `stalledSubscriberIsBounded` 86.4 s (24.0 %
  of six minutes); the R-SYN-14 migration-loop wait 67.8 s and the R-SYN-6 owed re-queue 69.3 s (22.6 % and 23.1 % of
  five); S1-15's run test 80.2 s (26.7 % of five). 34 one-minute tests passed at 51.6–59.1 % of their guard (30.96–35.46
  s; the longest `heldJobsWaitForTheFollow`, `failedHealIsForgotten`, `ensureAvailableApplyFollowsPrunes`, 35.4–35.5 s;
  the log has no start times, so when in the run they ran is not known), the class S3-R12 (4) records as non-blocking
  (29 at 50.3–55.0 % in the cycle-8 verifier's pair2); none was raised. In cycle 8's single run the longest one-minute
  test took 14.6 s and the bundle 54.4 s; the bundle now also runs the 23 new tests' cases (both visit orders, each two
  forced syncs over 2,100 changed entries and 32 MB volumes; 2.1 s alone under TSan), and the one-minute tests'
  completion order (ranks 265–300 of 438, before every F-28 test) fits all of them contending from the bundle's start. A
  paired run may put one-minute tests over half their guard (blocking under S3-R12 (2) at a mean of 30 or less). For the
  orchestrator: serialise the new tests in a suite of their own, or extend S3-R12 (4) to them; neither is done here.
- **Coverage** (from the final `--quick`'s profile: `xcrun llvm-cov export -summary-only -instr-profile
  .build-s3f/out/Products/Debug/codecov/default.profdata` over every test binary; `python3 Scripts/gates.py coverage
  --json .build-s3f/cov.json`): `COVERAGE target=ZTronAssetSync lines= 93.64% (9465/10108) min=90.0 OK`, overall `96.50%
  (25973/26916)`, `COVERAGE: PASS`.
- **S3-R13** (`.build-s3f/c9-t64.sh`, 14:52–14:54: `git archive` of `f91f108` into `.build-s3f/t64`, line 1 set to
  `// swift-tools-version: 6.4` there only; Apple Swift version 6.4 (swiftlang-6.4.0.34.1)): `swift build --build-tests
  --scratch-path ../t64-build -Xswiftc -warnings-as-errors` exit 0, `Build complete! (43,35 s)`, 0 `warning:` and 0
  `error:` lines; `swift build -c release --scratch-path ../t64-build` exit 0, `Build complete! (29,22 s)`, 0 `warning:`
  lines. The first export, at `cecf5aa`, measured `60,24 s` and `37,38 s` with the same 0 counts.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, exit 0 (14:46:45–14:46:55, load 9.3; `EngineFollow.o` for `arm64`
  rebuilt at 14:46:53). **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro, iOS
  27.0; `Test-ZTronAssetKit-2026.10.30_14-47-03-+0100.xcresult`, 14:46:55–14:52:23, load 9.1 → 64.5): `"result" :
  "Passed"`, `"totalTestCount" : 1392`, `"passedTests" : 1392`, `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST
  SUCCEEDED **`; 1,369 in cycle 8 plus this cycle's 23; the log's four `warning:` lines are
  `appintentsmetadataprocessor`'s "Metadata extraction skipped"); the simulator is shut down.
- **Benchmarks** (the full command, `swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing
  --filter Benchmarks`, after a release build of the tests, at `f91f108`; the tests ran 14:36:43–14:39:53, 1-minute load
  4.28–8.88, mean 5.71 over 38 samples every 5 s): `✘ Test run with 44 tests in 8 suites failed after 232.462 seconds
  with 1 issue.`, the issue P-13's (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, WP-B's,
  `other-wp:b`); `✔ Suite "SyncBenchmarks" passed after 67.939 seconds.`, every WP-F benchmark within its budget (best
  of three ≤ 10 ms, median ≤ 50 ms). This cycle's four: the reclaim during an owed follow [3.09, 3.30, 3.20] ms (one
  handle) and [4.35, 4.13, 4.28] ms (two); the mixed reclaim (1 member in 20 changed) [8.38, 9.03, 9.08] ms and [7.97,
  11.11, 7.89] ms; `followDrainTurns` [3.69, 3.72, 3.91] ms, the follow ended [142.0, 143.2, 145.1] ms and the drain
  [142.0, 143.7, 147.1] ms after the release; `followEndTurn` the combined turn [3.17, 3.17, 3.15] ms, the heartbeat
  [3.18, 3.18, 3.16] ms. The rest: P-4 13.50 ms (budget 20.0), ratio 2.11 (max 2.5); P-7 0.91 / 0.08 MiB; P-11 speedup
  3.16 (min 3.0); P-14 0 timers, 0 tasks; P-9 p99 13.0 ms (budget 50.0); the stalled prune ratio 1.36; space parking
  [5.63, 4.07, 6.26] ms, its ENOSPC read [4.24, 3.99, 4.24] ms; space re-admission [5.36, 5.34, 5.66] ms; network edges
  [1.11, 1.09, 1.09] and [5.37, 5.19, 5.13] ms; releases [4.85, 5.43, 5.43] and [5.44, 5.23, 5.26] ms; re-joins [5.55,
  5.03, 5.09] and [4.99, 5.60, 5.81] ms; shutdown [1.40, 1.57, 1.77] ms; refresh under a group [1.27, 1.33, 1.25] ms,
  changing every member [3.89, 3.70, 3.70] ms; prune announcement [4.96, 5.00, 5.10] ms; due retries [1.01, 1.14, 0.92]
  ms; cancelled resolve 0.02 ms; cooldown end [0.07, 0.16, 0.11] ms; probe chain [0.28, 16.17, 0.30] ms (totals about
  1.1 s; one run's 16.2 ms is over C2's 10 ms, the best and the median within the convention; cycle 8 measured 0.19 ms,
  so it is recorded for the verifiers); throttle extension [6.91, 7.14, 7.26] ms.
- **`git status`:** clean after the draft's commit; `docs/TRACEABILITY.md` untouched (no `--gates-only` or `--full`
  run).

## Gate evidence (cycle 10)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host, at `a206500` (the code and tests are final
there; the draft's commit changes this file only).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (16:45:15–16:51:02; 1-minute load read at 16:45,
  16:46, 16:47 and 16:50: 16.5, 24.2, 40.5, 13.4): `VERIFY: PASS`; `::: SUMMARY mode=--quick steps-failed=0`; Transport
  151, Sync 448 (`passed after 52.338 seconds`; 438 in cycle 9 plus this cycle's 10), Storage 459 (`111.852 seconds`),
  Model 84 (`76.120 seconds`), Kit 85, Compatibility 71, AppleHosted 104 tests passed.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (16:55:11–16:55:43,
  load 18.7): `Build complete! (31,21 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 16:55:43): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS
  public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  16:51:13–16:55:11, the first after the rebuild without coverage; load mean 18.96, min 9.58, max 27.78 over 48
  samples): `✔ Test run with 448 tests in 53 suites passed after 39.799 seconds.`, `58.524 seconds.`, `39.493 seconds.`
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 16:58:49–17:03:54; S3-R12 rule-1 load from 60 s after the start: mean 24.02, min 12.95,
  max 48.93 over 49 samples): `✔ Test run with 448 tests in 53 suites passed after 265.095 seconds.`; 0 `WARNING:
  ThreadSanitizer` lines, 0 `Time limit was exceeded` lines; `✔ Suite "Engine follow barrier (F-28)" passed after
  265.093 seconds.` (its 66 cases one at a time, so the suite spans the bundle). No test took more than half its guard:
  the 242 one-minute tests at most 18.95 s (31.6 %); the 3-minute tests of the barrier and sweep-order files 3.4–40.8 s
  (at most 22.7 %); the longest of all, the R-SYN-3 100,000-entry plan, 96.7 s, under half its guard. This is the run
  reqs issue 3 asked for: no time-out at a rule-1 mean of 50 or less (a single run, so S3-R12 2(ii) does not apply).
- **Coverage** (from `--quick`'s profile, `bash .build-s3f/c6-cov.sh`: `xcrun llvm-cov export -summary-only` over every
  test binary, then `python3 Scripts/gates.py coverage --json .build-s3f/cov.json`): `COVERAGE target=ZTronAssetSync
  lines= 93.70% (9624/10271) min=90.0 OK`, overall `96.46% (26121/27079)`, `COVERAGE: PASS`. The drain's replays,
  counted over the barrier suite alone (`swift test --enable-code-coverage --filter EngineFollowBarrierTests`, then
  `llvm-cov show` of `EngineFollow.swift`): `.spaceFailure`'s `decideSpaceFailure` 1 hit (0 in the cycle-9 verifier's
  count), `.spaceJoin` 1, `.enqueue` 519, `.reinstate` 1 (0 before), `.join` 2, `.edge` 1, the throttle park's replay 2;
  `.relane`'s replay and `replayJoin`'s re-route 0 (under "Not verified here").
- **S3-R13** (`.build-s3f/c10-t64.sh`, 17:12–17:15: `git archive` of `a206500` into `.build-s3f/t64`, line 1 set to `//
  swift-tools-version: 6.4` there only; Apple Swift version 6.4 (swiftlang-6.4.0.34.1)): `swift build --build-tests
  --scratch-path ../t64-build -Xswiftc -warnings-as-errors` exit 0, `Build complete! (115,74 s)`, 0 `warning:` and 0
  `error:` lines; `swift build -c release --scratch-path ../t64-build` exit 0, `Build complete! (72,55 s)`, 0 `warning:`
  lines. `Package.swift` is not edited in the worktree.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, exit 0, 0 `warning:` lines (17:04:24–17:04:44; `EngineFollow.o` and
  `EngineConditions.o` for `arm64` rebuilt at 17:04). **iOS Simulator tests** (simulator
  897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro, iOS 27.0; `Test-ZTronAssetKit-2026.10.30_17-04-52-+0100.xcresult`,
  17:04:44–17:11:51, load 33.7 at the start, up to 219 during the run from other work on the host): `"result" :
  "Passed"`, `"totalTestCount" : 1402`, `"passedTests" : 1402`, `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST
  SUCCEEDED **`; cycle 9's 1,392 plus this cycle's 10; the log's four `warning:` lines are
  `appintentsmetadataprocessor`'s "Metadata extraction skipped"); the simulator is shut down.
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`
  after a release build of the tests, 17:20:26–17:27:13; 1-minute load mean 11.65, min 3.94, max 25.00 over 82 samples):
  `✘ Test run with 44 tests in 8 suites failed after 225.387 seconds with 1 issue.`, the issue P-13's
  (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, unit max 10.29 ms against 5.0 ms, WP-B's,
  `other-wp:b`); `✔ Suite "SyncBenchmarks" passed after 71.407 seconds.`, every WP-F benchmark within S3-R5's budgets
  (best of three ≤ 10 ms, median ≤ 50 ms). The follow barrier's C2 figures (reqs issue 4): the reclaim during an owed
  follow [3.23, 3.39, 3.16] ms (one handle) and [4.40, 4.58, 4.46] ms (two); the mixed reclaim (1 member in 20 changed)
  [8.17, 7.15, 7.48] ms and [7.81, 8.13, 8.02] ms; `followDrainTurns` [4.05, 3.74, 3.80] ms, the follow ended [152.7,
  146.3, 148.1] ms and the drain [154.3, 148.2, 148.1] ms after the release (R2's admission wait); `followEndTurn` the
  combined turn [3.32, 3.96, 3.36] ms. The rest: space parking [4.80, 4.23, 10.91] ms, its ENOSPC read 4.36 ms; space
  re-admission [5.45, 5.62, 15.10] ms; network edges [1.19, 1.11, 1.20] and 5.01 ms best; releases [5.27, 5.46, 4.75]
  and [5.79, 5.25, 5.02] ms; re-joins [5.38, 5.30, 5.69] and [12.06, 5.77, 5.74] ms; shutdown [1.88, 1.58, 14.26] ms;
  refresh under a group [1.24, 1.31, 1.29] ms, changing every member [3.97, 3.69, 3.81] ms; prune announcement [5.12,
  5.04, 5.16] ms; due retries [1.99, 0.96, 1.06] ms; cancelled resolve 0.02 ms; cooldown end 0.07 ms; probe chain [0.34,
  0.77, 0.35] ms (totals about 1.16 s); throttle extension [7.60, 8.78, 10.25] ms; P-9 p99 13.4 ms (budget 50.0). The
  runs over 10 ms (one of three in five benchmarks) fit the convention (best and median within) and the host's load.
- **`git status`:** clean after the draft's commit; `docs/TRACEABILITY.md` untouched (no `--gates-only` or `--full`
  run).

## Gate evidence (cycle 11)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host, at `32c7ffe` (the code and tests are final
there; the draft's commit changes this file only), in sequence by `.build-s3f/c11-all.sh` (output `.build-s3f/c11-all.out`).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (21:43:50–21:48:47; 1-minute load 5.38 at the start,
  11.34 at the end): `VERIFY: PASS`; `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 460 (`passed after
  48.270 seconds`; cycle 10's 448 plus this cycle's 12), Storage 459 (`85.195 seconds`), Model 84 (`65.800 seconds`),
  Kit 85, Compatibility 71, AppleHosted 104 tests passed.
- **Coverage** (from `--quick`'s profile, `bash .build-s3f/c6-cov.sh`): `COVERAGE target=ZTronAssetSync lines= 93.11%
  (9831/10558) min=90.0 OK`, overall `96.25% (26341/27366)`, `COVERAGE: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  21:48:48–21:52:53, load 11.3–18.6): `✔ Test run with 460 tests in 53 suites passed after 52.762 seconds.`, `46.113
  seconds.`, `46.141 seconds.`
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (21:52:53–21:53:27):
  `Build complete! (33,24 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 21:53:27): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS
  public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 21:54:19–21:58:47; S3-R12 rule-1 load from 60 s after the start: mean 35.22, min 7.34,
  max 82.93 over 42 samples): `✔ Test run with 460 tests in 53 suites passed after 228.983 seconds.`; 0 `WARNING:
  ThreadSanitizer` lines, 0 `Time limit was exceeded` lines. Durations against guards
  (`.build-s3f/c11-tsan-durations.tsv`, the guard read from each `@Test`; 308 of the 379 reported names matched): none
  over half its guard; the largest fraction 31.1 % (`R-SYN-2: a job held for a manifest catch-up stays held until the
  follow…`, 18.69 s of 1 minute); the 220 one-minute tests at most 18.69 s; the 81 three-minute tests at most 50.67 s
  (28.2 %); the longest of all, the R-SYN-3 100,000-entry plan, 87.9 s of 5 minutes, and `stalledSubscriberIsBounded`
  84.4 s of 6 minutes.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, exit 0, 0 `warning:` lines (21:58:47–21:58:58; `EngineFollow.o` for
  `arm64` rebuilt in this run). **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro;
  `Test-ZTronAssetKit-2026.10.30_21-59-06-+0100.xcresult`, 21:58:58–22:06:24, load 8.8 at the start, up to 124 during
  the run from other work on the host): `"result" : "Passed"`, `"totalTestCount" : 1414`, `"passedTests" : 1414`,
  `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 10's 1,402 plus this cycle's 12; the log's
  four `warning:` lines are `appintentsmetadataprocessor`'s "Metadata extraction skipped"); the simulator is shut down
  (`simctl list`: `(Shutdown)`).
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`
  after a release build of the tests, 22:09:32–22:15:31; 1-minute load mean 7.83, min 3.91, max 16.39 over 72 samples):
  `✘ Test run with 44 tests in 8 suites failed after 213.960 seconds with 1 issue.`, the issue P-13's
  (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, unit max 7.52 ms against 5.0 ms, WP-B's,
  `other-wp:b`); `✔ Suite "SyncBenchmarks" passed after 71.140 seconds.`, every WP-F benchmark within S3-R5's budgets
  (best of three ≤ 10 ms, median ≤ 50 ms). The follow barrier's C2 figures: the reclaim during an owed follow [3.35,
  3.58, 3.28] ms (one handle) and [4.80, 4.17, 4.26] ms (two); the mixed reclaim (1 member in 20 changed) [7.21, 7.23,
  8.14] ms and [8.80, 8.01, 7.86] ms; the follow end and drain of 10,000 places [3.98, 3.76, 3.88] ms, the follow ended
  [135.2, 136.5, 137.4] ms and the drain [135.6, 137.2, 144.3] ms after the release (R2's admission wait); the follow's
  last turn plus the drain's first batch [3.61, 3.61, 3.45] ms. The rest: space parking [4.35, 4.18, 4.52] ms, its
  ENOSPC read 3.92 ms; space re-admission [5.43, 5.57, 5.54] ms; network edges [1.23, 1.17, 1.11] and [14.75, 5.02,
  5.47] ms; releases [5.50, 4.77, 4.97] and [5.39, 4.90, 5.69] ms; re-joins [5.14, 5.22, 5.61] and [5.23, 5.17, 5.20]
  ms; shutdown [151.62, 1.70, 1.48] ms; refresh under a group [1.27, 1.26, 1.22] ms, changing every member [3.85, 3.69,
  3.69] ms; prune announcement [4.91, 5.27, 5.31] ms; due retries [1.08, 1.32, 1.05] ms; cancelled resolve 0.03 ms;
  cooldown end 0.07 ms; probe chain 0.62 ms longest (totals about 1.1 s); throttle extension [7.01, 6.94, 7.78] ms; P-9
  p99 13.0 ms (budget 50.0). The two first runs over 10 ms (network edge back online, shutdown) fit the convention
  (best and median within).
- **S3-R13** (`.build-s3f/c11-t64.sh`, 22:15:31–22:17:05: `git archive` of `32c7ffe` into `.build-s3f/t64`, line 1 set
  to `// swift-tools-version: 6.4` there only; Apple Swift version 6.4 (swiftlang-6.4.0.34.1)): `swift build
  --build-tests --scratch-path ../t64-build -Xswiftc -warnings-as-errors` exit 0, `Build complete! (59,42 s)`, 0
  `warning:` and 0 `error:` lines; `swift build -c release --scratch-path ../t64-build` exit 0, `Build complete! (32,26
  s)`, 0 `warning:` lines. `Package.swift` is not edited in the worktree.
- **Mutants and probes:** under "Cycle 11" (`.build-s3f/mut/summary.txt`; each revert checked by an empty `git diff
  --stat Sources/`).
- **`git status`:** clean after the draft's commit; `docs/TRACEABILITY.md` untouched (no `--gates-only` or `--full`
  run).

## Gate evidence (cycle 12)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host, at `dcee1cd` (the code and tests are final
there; the draft's commit changes this file only), in sequence by `.build-s3f/c12-all.sh` (output `.build-s3f/c12-all.out`).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (01:52:39–01:56:40; 1-minute load 2.66 at the start,
  7.97 at the end): `VERIFY: PASS`; `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 474 (`passed after
  50.075 seconds`; cycle 11's 460 plus this cycle's 14), Storage 459 (`66.026 seconds`), Model 84 (`60.755 seconds`),
  Kit 85, Compatibility 71, AppleHosted 104 tests passed.
- **Coverage** (from `--quick`'s profile, `bash .build-s3f/c6-cov.sh`): `COVERAGE target=ZTronAssetSync lines= 93.33%
  (10069/10789) min=90.0 OK`, overall `96.31% (26578/27597)`, `COVERAGE: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  01:56:41–02:00:07, 1-minute load 7.3–19.0): `✔ Test run with 474 tests in 53 suites passed after 49.407 seconds.`,
  `48.578 seconds.`, `49.321 seconds.`
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (02:00:07–02:00:37):
  `Build complete! (29,54 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 02:00:37): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS
  public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 02:01:17–02:06:05; S3-R12 rule-1 load from 60 s after the start: mean 7.80, min 3.07,
  max 18.53 over 46 samples): `✔ Test run with 474 tests in 53 suites passed after 249.427 seconds.`; 0 `WARNING:
  ThreadSanitizer` lines, 0 `Time limit was exceeded` lines. Durations against guards (`python3
  .build-s3f/c12/durations.py .build-s3f/c12-tsan.log`, the guard read from each `@Test`; 418 of the 474 reported names
  have a guard): none over half its guard; the largest fraction 25.8 % (`R-SYN-2: a job held for a manifest catch-up
  stays held until the follow…`, 15.46 s of 1 minute); the 242 one-minute tests at most 15.46 s; the 168 three-minute
  tests at most 38.63 s (21.5 %); the 5-minute tests at most 62.44 s (the R-SYN-3 100,000-entry plan, 20.8 %);
  `stalledSubscriberIsBounded` 58.78 s of 6 minutes (16.3 %). This cycle's 14 tests all reported, the longest 6.43 s of
  3 minutes (3.6 %, the re-admission turn test).
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, exit 0, 0 `warning:` lines (02:06:05–02:06:14; `EngineFollow.o` for
  `arm64` rebuilt in this run, 02:06:13). **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone
  18 Pro; `Test-ZTronAssetKit-2026.10.31_02-06-20-+0100.xcresult`, 02:06:14–02:10:49, 1-minute load 2.97 at the start,
  24.34 at the end): `"result" : "Passed"`, `"totalTestCount" : 1428`, `"passedTests" : 1428`, `"failedTests" : 0`,
  `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 11's 1,414 plus this cycle's 14; the log's four `warning:` lines
  are `appintentsmetadataprocessor`'s "Metadata extraction skipped, no AppIntents.framework dependency found"). The
  simulator is shut down (`simctl shutdown` exit 0; `simctl list`: `(Shutdown)`).
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`
  after a release build of the tests, 02:13:22–02:19:14; 1-minute load mean 5.42, min 2.95, max 11.96 over 71 samples):
  `✘ Test run with 44 tests in 8 suites failed after 222.600 seconds with 1 issue.`, the issue P-13's
  (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, longest deletion unit 8.45 ms against
  5.0 ms; WP-B's, `other-wp:b`). `✔ Suite "SyncBenchmarks" passed after 86.552 seconds.`: every WP-F benchmark within
  S3-R5's budgets (best of three ≤ 10 ms, median ≤ 50 ms).
  - The follow barrier's C2 figures:
    - The reclaim during an owed follow: [3.94, 4.05, 3.97] ms (one handle) and [5.07, 4.99, 4.97] ms (two).
    - The mixed reclaim (1 member in 20 changed): [5.74, 6.17, 5.86] ms and [6.02, 6.01, 6.01] ms.
    - The follow end and drain of 10,000 places: [4.45, 4.69, 4.41] ms. The follow ended [162.3, 174.9, 162.3] ms and
      the drain [169.5, 179.5, 164.3] ms after the release (R2's admission wait; cycle 11: about 136 ms).
    - The follow's last turn plus the drain's first batch: [3.84, 3.89, 3.86] ms.
  - The rest:
    - Space parking [4.85, 4.01, 4.05] ms, its ENOSPC read [2.77, 2.67, 3.36] ms; space re-admission [4.59, 4.22, 4.21] ms.
    - Network edges [1.28, 1.28, 1.31] and [4.14, 4.07, 4.08] ms.
    - Releases [4.77, 4.33, 4.45] and [4.56, 4.55, 4.57] ms; re-joins [4.84, 4.76, 4.82] and [4.84, 4.81, 4.81] ms.
    - Shutdown [5.10, 1.61, 1.57] ms.
    - Refresh under a group [1.23, 1.21, 1.21] ms, changing every member [4.39, 4.39, 4.43] ms.
    - Prune announcement [4.88, 4.93, 4.93] ms; due retries [1.15, 1.14, 1.21] ms.
    - Cancelled resolve [0.03, 0.02, 0.03] ms; cooldown end [0.06, 0.07, 0.08] ms.
    - Probe chain [0.20, 0.23, 0.22] ms (totals about 1.13 s); throttle extension [6.68, 7.29, 7.02] ms.
    - P-9 p99 15.2 ms (budget 50.0); P-4 plan 10,000 11.4 ms (budget 20.0).
- **S3-R13** (`.build-s3f/c12-t64.sh`, 02:19:14–02:20:31: `git archive` of `dcee1cd` into `.build-s3f/t64`, line 1 set
  to `// swift-tools-version: 6.4` there only; Apple Swift version 6.4 (swiftlang-6.4.0.34.1)): `swift build
  --build-tests --scratch-path ../t64-build -Xswiftc -warnings-as-errors` exit 0, `Build complete! (45,63 s)`, 0
  `warning:` and 0 `error:` lines; `swift build -c release --scratch-path ../t64-build` exit 0, `Build complete! (29,09
  s)`, 0 `warning:` lines. `Package.swift` is not edited in the worktree.
- **Mutants and probes:** under "Cycle 12" (`.build-s3f/c12/mut-all.log`, `.build-s3f/c12/mut2/`; each revert checked
  by "Sources differ from the worktree: none").
- **`git status`:** clean after the draft's commit (`.build-s3f*` is untracked scratch); `docs/TRACEABILITY.md`
  untouched (no `--gates-only` or `--full` run).

## Gate evidence (cycle 13)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host, at `128fda9` (the code and tests are final
there; the draft's commit changes this file only), in sequence by `.build-s3f/c13-all.sh` (output
`.build-s3f/c13-all.out`), then the 30-run loops. The mutants ran before it, from 10:26 to 11:44 (under "Cycle 13"), up to four builds at once.

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (11:46:29–11:50:36; 1-minute load 2.36 at the start,
  8.75 at the end): `VERIFY: PASS`; `::: SUMMARY mode=--quick steps-failed=0`; Transport 151, Sync 483 (`passed after
  56.631 seconds`; cycle 12's 474 plus this cycle's 9), Storage 459 (`66.668 seconds`), Model 84 (`63.023 seconds`),
  Kit 85, Compatibility 71, AppleHosted 104 tests passed.
- **Coverage** (from `--quick`'s profile, `bash .build-s3f/c6-cov.sh`): `COVERAGE target=ZTronAssetSync lines= 93.97%
  (10002/10644) min=90.0 OK`, overall `96.57% (26510/27452)`, `COVERAGE: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  11:50:37–11:54:23; 1-minute load mean 12.26, min 6.79, max 21.83 over 45 samples): `✔ Test run with 483 tests in 53
  suites passed after 55.795 seconds.`, `55.252 seconds.`, `56.098 seconds.`
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (11:54:23–11:54:56):
  `Build complete! (31,79 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 11:54:56): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS
  public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 11:55:35–12:00:56; S3-R12 rule-1 load from 60 s after the start: mean 6.37, min 2.85,
  max 15.14 over 53 samples): `✔ Test run with 483 tests in 53 suites passed after 282.674 seconds.`; 0 `WARNING:
  ThreadSanitizer` lines, 0 `Time limit was exceeded` lines.
  - Durations against guards (`python3 .build-s3f/c13/durations.py .build-s3f/c13-tsan.log`, the guard read from each
    `@Test`; 427 of the 483 reported names have a guard): none over a third of its guard. The largest fraction is
    27.2 % (`R-INT-3: a present asset is never counted, quarantined or failed by a redundant transfer…`, 16.31 s of 1
    minute).
  - The 242 one-minute tests at most 16.31 s; the 177 three-minute tests at most 40.16 s (22.3 %); the 7 five-minute
    tests at most 65.69 s (the R-SYN-3 100,000-entry plan, 21.9 %); `stalledSubscriberIsBounded` 61.45 s of 6 minutes
    (17.1 %).
  - This cycle's 9 tests all reported, the longest 8.70 s of 3 minutes (4.8 %, the R-C test); the others 2.10–3.44 s.
    The formerly hanging `barrierRetriesBehindTheOwedVisitsPlaces`: 3.45 s.
- **The formerly hanging test, 30 runs ×2** (findings 1 and 13; `swift test --skip-build --scratch-path .build-s3f
  --filter barrierRetriesBehindTheOwedVisitsPlaces`, 6 at a time through `xargs -P 6`, both arguments each run):
  - `.build-s3f/c13-loop2.sh` (12:15:59–12:16:57; 1-minute load mean 11.49, min 6.32, max 20.87 over 12 samples): 30
    of 30 exit 0, `✔ Test run with 1 test in 1 suite passed` ×30, 0 issue lines; durations 0.618–0.694 s. 29 of the 30
    waited for SwiftPM's lock on the scratch path (`Another instance of SwiftPM … waiting`), so these ran one at a time
    (`.build-s3f/c13/loop-locked/`).
  - So the loop ran again with `--ignore-lock` (`.build-s3f/c13-loop3.sh`, 12:17:14–12:17:29; load mean 14.21, min
    12.78, max 15.38 over 4 samples): 30 of 30 exit 0, `✔ Test run with 1 test in 1 suite passed` ×30, 0 issue lines;
    durations 0.761–0.912 s; 25 of the 30 overlapped another run (`… but this will be ignored since --ignore-lock has
    been passed`) (`.build-s3f/c13/loop/`). The first `c13-all.sh` attempt at the loop did not run: BSD `xargs -I`
    refused the command line (`xargs: command line cannot be assembled, too long`).
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, exit 0, 0 `warning:` lines (12:00:57–12:01:06; `EngineFollow.o` for
  `arm64` rebuilt in this run, 12:01:05). **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone
  18 Pro; `Test-ZTronAssetKit-2026.10.31_12-01-13-+0100.xcresult`, 12:01:06–12:05:56, 1-minute load 3.04 at the start,
  29.97 at the end): `"result" : "Passed"`, `"totalTestCount" : 1437`, `"passedTests" : 1437`, `"failedTests" : 0`,
  `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 12's 1,428 plus this cycle's 9; the log's four `warning:` lines
  are `appintentsmetadataprocessor`'s "Metadata extraction skipped, no AppIntents.framework dependency found"). The
  simulator is shut down (`simctl shutdown` exit 0; `simctl list`: `(Shutdown)`).
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`
  after a release build of the tests, 12:08:39–12:14:28; 1-minute load mean 8.13, min 3.43, max 19.50 over 70 samples):
  `✘ Test run with 44 tests in 8 suites failed after 212.391 seconds with 1 issue.`, the issue P-13's
  (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, longest deletion unit 7.00 ms against
  5.0 ms; WP-B's, `other-wp:b`). `✔ Suite "SyncBenchmarks" passed after 72.189 seconds.`: every WP-F benchmark within
  S3-R5's budgets (best of three ≤ 10 ms, median ≤ 50 ms).
  - The follow barrier's C2 figures, with cycle 12's (load mean 5.42 then, 8.13 now):
    - The reclaim during an owed follow, which now also replays the sweep's event (`3e3ef0d`): [4.10, 4.17, 4.01] ms
      (one handle; cycle 12 [3.94, 4.05, 3.97]) and [5.12, 5.10, 5.63] ms (two; [5.07, 4.99, 4.97]).
    - The mixed reclaim (1 member in 20 changed): [7.03, 6.62, 6.70] ms ([5.74, 6.17, 5.86]) and [7.94, 7.97, 7.88] ms
      ([6.02, 6.01, 6.01]). The largest rise of the cycle. The load was higher, and since `3e3ef0d` the sweep is also
      judged at its place in the drain; the two are not measured apart. Best of three 6.62 and 7.88 ms, within the
      10 ms budget.
    - The follow end and drain of 10,000 places: [5.72, 5.56, 5.68] ms ([4.45, 4.69, 4.41]). The follow ended [199.6,
      200.8, 203.1] ms and the drain [199.6, 201.2, 203.6] ms after the release (cycle 12: about 162–175 ms).
    - The follow's last turn plus the drain's first batch: the turn [5.06, 5.16, 5.93] ms, the longest wait [6.13, 5.16,
      5.94] ms ([3.84, 3.89, 3.86]).
  - The rest:
    - Space parking [4.04, 4.13, 4.10] ms, its ENOSPC read [5.37, 3.48, 3.76] ms; space re-admission [5.29, 5.24, 4.85] ms.
    - Network edges [1.29, 1.31, 1.35] and [4.70, 4.83, 4.51] ms.
    - Releases [4.60, 5.13, 4.67] and [4.97, 4.89, 4.65] ms; re-joins [4.84, 5.06, 5.00] and [5.07, 5.06, 4.87] ms.
    - Shutdown [1.60, 3.22, 1.58] ms.
    - Refresh under a group [1.21, 1.21, 1.21] ms, changing every member [4.39, 4.41, 4.34] ms.
    - Prune announcement [4.84, 4.85, 4.88] ms; due retries [1.20, 1.22, 1.25] ms.
    - Cancelled resolve [0.03, 0.03, 0.03] ms; cooldown end [0.07, 0.07, 0.06] ms.
    - Probe chain [0.27, 0.29, 0.61] ms (totals about 1.15 s); throttle extension [7.40, 6.66, 6.96] ms.
    - P-9 p99 15.3 ms (budget 50.0); P-4 plan 10,000 11.8 ms (budget 20.0).
- **S3-R13** (`.build-s3f/c13-t64.sh`, 12:14:28–12:15:45: `git archive` of `128fda9` into `.build-s3f/t64`, line 1 set
  to `// swift-tools-version: 6.4` there only; Apple Swift version 6.4 (swiftlang-6.4.0.34.1)): `swift build
  --build-tests --scratch-path ../t64-build -Xswiftc -warnings-as-errors` exit 0, `Build complete! (45,14 s)`, 0
  `warning:` and 0 `error:` lines; `swift build -c release --scratch-path ../t64-build` exit 0, `Build complete! (30,04
  s)`, 0 `warning:` lines. `Package.swift` is not edited in the worktree.
- **Mutants and probes:** under "Cycle 13" (`.build-s3f/c13/mut-{a..i}.log`, `.build-s3f/c13/mut{,2,3,4}/`,
  `.build-s3f/c13/mut-table.out`). The failing runs of the cycle's two failing-test commits:
  `.build-s3f/c13/failing-{1,2}.log` and `.build-s3f/c13/rc-failing-{1,2}.log`.
- **`git status`:** clean after the draft's commit (`.build-s3f*` is untracked scratch); `docs/TRACEABILITY.md`
  untouched (no `--gates-only` or `--full` run).

## Gate evidence (cycle 14)

All runs on this branch, scratch `.build-s3f*`, on the shared 8-core host, at `d2fad39` (the code and tests are final
there, committed 14:19:20; the draft's commit changes this file only), one at a time. The mutants ran before them, under
"Cycle 14". Logs under `.build-s3f/c14/`.

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (14:45:46–14:49:58; 1-minute load 2.48 at the start,
  8.30 at the end; `quick.log`, `quick-load.txt`): `VERIFY: PASS`; `::: SUMMARY mode=--quick steps-failed=0`;
  Transport 151, Sync 495 (`passed after 65.547 seconds`; cycle 13's 483 plus this cycle's 12), Storage 459 (`64.866
  seconds`), Model 84 (`61.348 seconds`), Kit 85, Compatibility 71, AppleHosted 104 tests passed.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  14:50:07–14:54:20; 1-minute load 7.64, 7.62 and 5.35 before each run, 4.28 after the last; `sync-{1,2,3}.log`): `✔
  Test run with 495 tests in 53 suites passed after 64.755 seconds.`, `62.630 seconds.`, `62.531 seconds.`
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (14:23:23–14:24:02,
  `release.log`): `Build complete! (38,01 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 15:18:45, `gates.log`): `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 14:54:27–15:01:05, `tsan.log`; S3-R12 rule-1 load from 60 s after the start: mean 4.61,
  min 2.78, max 7.28 over 34 samples, `tsan-load.txt`): `✔ Test run with 495 tests in 53 suites passed after 323.071
  seconds.`; 0 `ThreadSanitizer` lines, 0 `Time limit` lines.
  - Durations against guards (`python3 .build-s3f/c13/durations.py .build-s3f/c14/tsan.log`; 439 of the 495 reported
    names have a guard): none over a third of its guard. The largest fraction is 24.4 % (`R-SYN-2: a job held for a
    manifest catch-up stays held until the follow that may move it has ended`, 14.65 s of 1 minute).
  - The 242 one-minute tests at most 14.65 s; the 189 three-minute tests at most 38.34 s (21.3 %, the R-SYN-5 alarm
    turn's `dueDeadlinesPerTurn` test); the 7 five-minute tests at most 63.64 s (21.2 %, the R-SYN-3 100,000-entry
    plan); the six-minute stalled-subscriber test 60.20 s (16.7 %).
  - This cycle's 12 tests all reported. The longest is `barrierStartsAVisitsPlaceOnceTheBreakerCloses`, 25.97 s of 3
    minutes (14.4 %; 5.19–5.58 s in the plain runs); the other 11 took 3.85–6.83 s (at most 3.8 %).
  - **Finding 4, the cycle-13 verifier's run, as that verifier reported it (not re-run here at its load):** 483 tests
    passed after 854.187 s with 0 ThreadSanitizer reports, at 1-minute load mean 25.26, min 14.49, max 33.4; the largest
    test took 44.10 s, 73.5 % of its guard, and 89 one-minute tests were over half their guard. The fixer's solo run of
    cycle 13 took 282.674 s at load mean 6.37 (largest 27.2 %); this cycle's, above, 323.071 s at 4.61 (largest
    24.4 %). Under S3-R12 the hang guards are judged at the rule-1 load; the verifier's figures came at about four to
    five times this cycle's, and no guard was exceeded in either run.
- **Coverage** (`TMPDIR=… swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks`,
  15:02:17–15:06:27, 1-minute load 1.90 at the start, 5.82 at the end, `cov-test.log`; every bundle passed, 151, 495,
  459, 84, 85, 71 and 104 tests; then `xcrun llvm-cov export -summary-only` of
  `.build-s3f/out/Products/Debug/codecov/default.profdata` over the 8 `.xctest` bundles into `.build-s3f/cov.json`, and
  `python3 Scripts/gates.py coverage --json .build-s3f/cov.json`, `cov-gate.log`): `COVERAGE target=ZTronAssetSync
  lines= 93.93% (10151/10807) min=90.0 OK`, overall `96.55% (26661/27615)`, `COVERAGE device-only-excluded lines=177
  share=0.64% max=3.0% OK`, `COVERAGE: PASS`.
- **iOS:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, exit 0, 0 `warning:` lines (14:24:11–14:24:17, `ios-build.log`).
  **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro, iOS 27.0;
  `Test-ZTronAssetKit-2026.10.31_15-06-54-+0100.xcresult`, 15:06:45–15:11:43, 1-minute load 4.75 at the start, 13.19
  at the end, the 5-minute 30.19; `.build-s3f/sim.log`, `sim-summary.json`): `"result" : "Passed"`, `"totalTestCount"
  : 1449`, `"passedTests" : 1449`, `"failedTests" : 0`, `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 13's 1,437
  plus this cycle's 12; the log's four `warning:` lines are `appintentsmetadataprocessor`'s "Metadata extraction
  skipped, no AppIntents.framework dependency found"). The simulator is shut down: `xcodebuild` left it so, the
  `simctl shutdown` that followed answered "Unable to shutdown device in current state: Shutdown", and `simctl list`
  shows `(Shutdown)`.
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`,
  15:11:54–15:17:34; 1-minute load 11.53 at the start (the 5-minute 29.27, just after the simulator run), 2.89 at the
  end; `bench.log`): `✘ Test run with 44 tests in 8 suites failed after 215.096 seconds with 1 issue.`, the issue P-13's
  (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, longest deletion unit 8.39 ms against
  5.0 ms; WP-B's, `other-wp:b`). `✔ Suite "SyncBenchmarks" passed after 75.245 seconds.`: every WP-F benchmark within
  S3-R5's budgets (best of three ≤ 10 ms, median ≤ 50 ms).
  - `SyncBenchmarks` re-run alone (`--filter SyncBenchmarks`, 15:19:33–15:20:51; 1-minute load mean 2.60, min 2.41, max
    2.97 over 8 samples; `bench2.log`, `bench2-load.txt`): `✔ Test run with 24 tests in 2 suites passed after 75.787
    seconds.` It was run for the throttle extension's first run below.
  - The follow barrier's C2 figures (the full run, then the re-run where given; cycle 13's in brackets):
    - The reclaim during an owed follow: [4.20, 4.12, 4.27] ms (one handle; [4.10, 4.17, 4.01]) and [5.10, 5.26, 5.15] ms
      (two; [5.12, 5.10, 5.63]).
    - The mixed reclaim (1 member in 20 changed): [7.02, 6.94, 7.34] ms, re-run [7.31, 7.19, 7.64] ([7.03, 6.62,
      6.70]); two handles [8.09, 8.03, 8.39] ms, re-run [8.75, 8.17, 8.23] ([7.94, 7.97, 7.88]). Best of three 6.94 and
      8.03 ms, within the 10 ms budget; the two-handle figure is 0.1–0.3 ms above cycle 13's. This cycle adds one pass
      over the jobs in flight per decision instant (`freeSlots()`, bounded by the slots, not the catalogue); the two are
      not measured apart.
    - The follow end and drain of 10,000 places: [5.90, 6.04, 5.64] ms ([5.72, 5.56, 5.68]). The follow ended [205.5,
      209.5, 204.2] ms and the drain [207.2, 209.5, 204.5] ms after the release (cycle 13: about 200–204 ms).
    - The follow's last turn plus the drain's first batch: the turn [5.18, 5.29, 5.16] ms, the longest wait [5.18, 5.30,
      5.17] ms ([6.13, 5.16, 5.94]).
  - The rest:
    - Space parking [6.71, 4.28, 4.11] ms, its ENOSPC read [3.36, 3.58, 3.36] ms; space re-admission [5.38, 5.15, 5.39] ms.
    - Network edges [1.52, 1.47, 1.50] and [4.85, 5.19, 5.52] ms.
    - Releases [4.81, 4.85, 4.99] and [4.89, 4.91, 5.03] ms; re-joins [5.47, 5.20, 5.05] and [5.15, 5.18, 5.14] ms.
    - Shutdown [1.54, 1.67, 1.61] ms.
    - Refresh under a group [1.20, 1.26, 1.29] ms, changing every member [4.44, 4.45, 4.42] ms.
    - Prune announcement [4.88, 4.92, 4.88] ms; due retries [1.19, 1.18, 1.16] ms.
    - Cancelled resolve [0.03, 0.03, 0.02] ms; cooldown end [0.07, 0.07, 0.08] ms.
    - Probe chain [0.63, 0.24, 0.28] ms (totals about 1.15 s).
    - Throttle extension [38.78, 6.99, 7.45] ms in the full run (its first run at the start's load, 11.53 with the
      5-minute 29.27; median 7.45 and best 6.99 within the budgets), [7.42, 7.53, 7.02] ms in the re-run at load 2.6
      (cycle 13 [7.40, 6.66, 6.96]). The re-run at low load gives cycle 13's figures, so the first run's 38.78 ms is
      read as the load's.
    - P-9 p99 12.6 ms (budget 50.0, `BenchKit.swift`, WP-G's); P-4 plan 10,000 11.6 ms (budget 20.0), ratio 2.14 (max 2.5).
- **Mutants and probes:** under "Cycle 14" (`.build-s3f/c14/mut-{a..d}.log`, `mutB-{a..d}.log`,
  `.build-s3f/c14/mutants-{1,2}.json`). The failing runs of the cycle's failing-test commits:
  `.build-s3f/c14/failing-run{1,2}.log` (`85636a1`) and `.build-s3f/c14/t10-failing-{1,2}.log` (`b075089`).
- **`git status`:** clean after the draft's commit (`.build-s3f*` is untracked scratch); `docs/TRACEABILITY.md`
  untouched (no `--gates-only` or `--full` run).

## Gate evidence (cycle 15)

All runs were made on this branch at `9673e2f`, the last code and test commit (17:38:27). The draft's commit changes
this file only. Scratch was `.build-s3f*` on the shared 8-core host, one run at a time, after the mutants (under
"Cycle 15"). Logs are under `.build-s3f/c15/`.

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (about 17:51–17:56:03; `quick.log`).
  - 1-minute load: 3.93 during the tests step, 3.45 at the end.
  - Result: `VERIFY: PASS`, `::: SUMMARY mode=--quick steps-failed=0`.
  - Tests passed: Transport 151, Sync 511 (`passed after 77.798 seconds`: cycle 14's 495, this cycle's 11 in `b461450`
    and 5 in `9673e2f`), Storage 459 (`61.332 seconds`), Model 84 (`59.722 seconds`), Kit 85, Compatibility 71,
    AppleHosted 104.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (ended 17:56:46,
  `release.log`): `Build complete! (28,95 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 17:56:46, `gates.log`):
  - `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`;
  - `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  17:56–18:01:44; `syncx-{1,2,3}.log`, `syncx-{1,2,3}.load`).
  - 1-minute load before each run: 3.45, 4.20 and 3.23; 2.93 after the last.
  - Results: `✔ Test run with 511 tests in 53 suites passed after 77.176 seconds.`, `… after 76.663 seconds.`,
    `… after 77.025 seconds.`
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 18:01:44–18:09:25, `tsan.log`).
  - Load (S3-R12 rule 1, from 60 s after the start): mean 2.93, min 1.79, max 5.60 over 39 samples (`tsan-load.txt`).
  - Result: `✔ Test run with 511 tests in 53 suites passed after 389.760 seconds.`; 0 `ThreadSanitizer` lines, 0
    `Time limit` lines.
  - Durations against guards (`python3 .build-s3f/c13/durations.py .build-s3f/c15/tsan.log`; 455 of the 511 reported
    names have a guard): none over a quarter of its guard.
    - Largest: 23.3 % (`R-SYN-2: a job held for a manifest catch-up stays held until the follow that may move it has
      ended`, 14.00 s of 1 minute).
    - The 242 one-minute tests at most 14.00 s; the 205 three-minute tests at most 35.54 s (19.7 %); the 7 five-minute
      tests at most 57.28 s (19.1 %); the six-minute stalled-subscriber test 54.70 s (15.2 %).
  - This cycle's 16 tests all reported, 2.26–10.16 s of 3 minutes (at most 5.6 %, the waiting-request lane test).
- **Coverage** (`swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks` with `TMPDIR`,
  `CLANG_MODULE_CACHE_PATH` and `LLVM_PROFILE_FILE` under `.build-s3f/tmp`, 18:09:48–18:14:13; `cov-test.log`).
  - 1-minute load 3.63 at the start, 5.65 at the end.
  - Every bundle passed: 151, 511, 459, 84, 85, 71 and 104 tests.
  - Then `xcrun llvm-cov export -summary-only` of `.build-s3f/out/Products/Debug/codecov/default.profdata` over the 8
    `.xctest` bundles into `.build-s3f/cov.json`, and `python3 Scripts/gates.py coverage --json .build-s3f/cov.json`
    (`cov-gate.log`).
  - Result: `COVERAGE target=ZTronAssetSync lines= 93.84% (10062/10723) min=90.0 OK`, overall `96.52% (26573/27531)`,
    `COVERAGE device-only-excluded lines=177 share=0.64% max=3.0% OK`, `COVERAGE: PASS`.
- **iOS build:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath
  .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` (ended 17:57:02, `ios-build.log`): exit 0,
  0 `warning:` and 0 `error:` lines. The products under `.build-s3f/xcode/Build/Products/Debug-iphoneos` are from this
  run.
- **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro, iOS 27.0;
  `Test-ZTronAssetKit-2026.10.31_18-14-37-+0100.xcresult`, 18:14:32–18:19:53; `.build-s3f/sim.log`, `sim-summary.json`).
  - 1-minute load 4.48 at the start, 14.36 at the end (the 5-minute 36.54).
  - Result: `"result" : "Passed"`, `"totalTestCount" : 1465`, `"passedTests" : 1465`, `"failedTests" : 0`,
    `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 14's 1,449 plus this cycle's 16).
  - The log's four `warning:` lines are `appintentsmetadataprocessor`'s "Metadata extraction skipped, no
    AppIntents.framework dependency found".
  - The simulator is shut down. `xcodebuild` left it so, the `simctl shutdown` that followed answered "Unable to
    shutdown device in current state: Shutdown", and `simctl list` shows `(Shutdown)`.
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`,
  18:21:24–18:27:32, started once the 1-minute load had fallen under 5 after the simulator run; load mean 3.61, min
  2.58, max 6.46 over 37 samples, `bench-load.txt`; `bench.log`).
  - Result: `✘ Test run with 44 tests in 8 suites failed after 250.932 seconds with 1 issue.` The issue is P-13's
    (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, unit max 8.86 ms against 5.0 ms; WP-B's,
    `other-wp:b`, routed).
  - `✔ Suite "SyncBenchmarks" passed after 116.752 seconds.`: every WP-F benchmark is within S3-R5's budgets (best of
    three ≤ 10 ms, median ≤ 50 ms).
  - The follow barrier's C2 figures (cycle 14's in brackets):
    - The reclaim during an owed follow: [4.27, 3.91, 3.87] ms with one handle ([4.20, 4.12, 4.27]) and [4.90, 4.97,
      4.98] ms with two ([5.10, 5.26, 5.15]).
    - The mixed reclaim (1 member in 20 changed): [6.26, 6.43, 6.33] ms ([7.02, 6.94, 7.34]); with two handles [7.89,
      7.54, 7.50] ms ([8.09, 8.03, 8.39]). Best of three is 6.26 and 7.50 ms. Finding 6's thin two-handle margin
      widened by about 0.5 ms; `worldStamp()` no longer runs `freeSlots()` per decision instant.
    - The follow end and drain of 10,000 places: [4.72, 4.79, 4.77] ms ([5.90, 6.04, 5.64]). The follow ended [191.1,
      194.8, 193.7] ms and the drain [191.1, 195.2, 193.7] ms after the release.
    - The follow's last turn plus the drain's first batch: the turn [4.69, 4.70, 4.66] ms, the longest wait [4.77,
      4.79, 4.75] ms.
    - Throttle extension: [6.58, 6.61, 6.54] ms ([38.78, 6.99, 7.45] in cycle 14's full run).
  - The rest:
    - Space parking [4.20, 4.04, 4.08] ms, its ENOSPC read best 3.20 ms; space re-admission [4.61, 4.15, 4.13] ms.
    - Network edges [1.31, 1.30, 1.30] and [4.22, 4.24, 4.30] ms.
    - Releases [4.49, 4.49, 4.39] and [4.58, 4.57, 4.61] ms; re-joins [4.83, 4.84, 4.79] and [5.14, 4.89, 4.76] ms.
    - Shutdown [1.57, 1.51, 1.50] ms.
    - Refresh under a group [1.20, 1.20, 1.20] ms, changing every member [4.27, 4.27, 4.29] ms.
    - Prune announcement [4.86, 4.80, 5.02] ms; due retries [1.13, 1.10, 1.13] ms.
    - Cancelled resolve 0.02 ms; cooldown end [0.06, 0.09, 0.06] ms; probe chain best 0.22 ms (totals about 1.13 s).
    - P-9 p99 15.2 ms (budget 50.0, `BenchKit.swift`, WP-G's); P-4 plan 10,000 11.3 ms (budget 20.0), ratio 2.07 (max
      2.5).
- **Mutants:** under "Cycle 15" (`.build-s3f/c15/mut-{a,b,c,d}.log`, `mut2-{b,c,d}.log`, `mutants.json`). The
  failing-test runs of `b461450` are `.build-s3f/c15/failing-run{1,2}.log`.
- **`git status`:** clean after the draft's commit (`.build-s3f*` is untracked scratch). `docs/TRACEABILITY.md` is
  untouched: no `--gates-only` or `--full` run was made.

## Gate evidence (cycle 16)

All runs were made on this branch at `d3242d3`, the last code and test commit (21:52:00). The draft's commit changes
this file only. Scratch was `.build-s3f*` on the shared 8-core host, one run at a time (`.build-s3f/c16/gates2.sh`, then
`final.sh`), after the mutants (under "Cycle 16"). Logs are under `.build-s3f/c16/final/`, with stage times and
1-minute loads in `times.txt`.

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (21:52:00–21:56:31; `quick.log`).
  - 1-minute load: 1.77 at the start, 4.68 at the end.
  - Result: `VERIFY: PASS`, `::: SUMMARY mode=--quick steps-failed=0`.
  - Tests passed: Transport 151, Sync 528 (`passed after 97.618 seconds`: cycle 15's 511 and this cycle's 17), Storage
    459 (`60.750 seconds`), Model 84 (`59.905 seconds`), Kit 85, Compatibility 71, AppleHosted 104.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (ended 21:57:01,
  `release.log`): `Build complete! (29,10 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 21:57:02, `gates.log`):
  - `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`;
  - `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  21:57:02–22:02:47; `syncx-{1,2,3}.log`).
  - 1-minute load before each run: 3.78, 3.86 and 3.52; 2.79 after the last.
  - Results: `✔ Test run with 528 tests in 53 suites passed after 97.316 seconds.`, `… after 97.158 seconds.`,
    `… after 97.127 seconds.`
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 22:02:47–22:12:12, `tsan.log`).
  - Load (S3-R12 rule 1, from 60 s after the start): mean 3.90, min 2.54, max 7.87 over 51 samples (`tsan-load.txt`).
  - Result: `✔ Test run with 528 tests in 53 suites passed after 490.731 seconds.`; 0 `ThreadSanitizer` lines, 0
    `Time limit` lines.
  - Durations against guards (`python3 .build-s3f/c13/durations.py .build-s3f/c16/final/tsan.log`; 472 of the 528
    reported names have a guard): none over a quarter of its guard.
    - Largest: 23.9 % (`R-SYN-16: a heal whose re-download fails ends, and the engine forgets it`, 14.36 s of 1
      minute).
    - The 242 one-minute tests at most 14.36 s; the 222 three-minute tests at most 35.19 s (19.5 %); the 7 five-minute
      tests at most 57.04 s (19.0 %); the six-minute stalled-subscriber test 54.45 s (15.1 %).
  - This cycle's 17 tests all reported (`.build-s3f/c16/newtests.txt`), 1.77–19.58 s of 3 minutes (at most 10.9 %,
    the waiting verdict's lane test over its eight cases).
- **Coverage** (`swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks` with `TMPDIR`,
  `CLANG_MODULE_CACHE_PATH` and `LLVM_PROFILE_FILE` under `.build-s3f/tmp`, 22:12:12–22:16:58; `cov-test.log`).
  - 1-minute load 2.67 at the start, 6.23 at the end.
  - Every bundle passed: 151, 528, 459, 84, 85, 71 and 104 tests.
  - Then `xcrun llvm-cov export -summary-only` of `.build-s3f/out/Products/Debug/codecov/default.profdata` over the
    `.xctest` bundles into `.build-s3f/cov.json`, and `python3 Scripts/gates.py coverage --json .build-s3f/cov.json`
    (`cov-gate.log`).
  - Result: `COVERAGE target=ZTronAssetSync lines= 93.99% (10214/10867) min=90.0 OK`, overall `96.57% (26727/27675)`,
    `COVERAGE device-only-excluded lines=177 share=0.64% max=3.0% OK`, `COVERAGE: PASS`.
- **iOS build:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath
  .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` (ended 22:17:08, `ios-build.log`): exit 0,
  0 `warning:` and 0 `error:` lines. Incremental: `EngineCommands.o` under `.build-s3f/xcode/Build/Intermediates.noindex`
  is newer than the run's start.
- **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro, iOS 27.0, booted by
  `simctl boot`; `Test-ZTronAssetKit-2026.10.31_22-17-18-+0100.xcresult`, 22:17:08–22:22:02; `.build-s3f/sim.log`,
  `sim-summary.json`).
  - 1-minute load 5.43 at the start, 10.96 at the end (the 5-minute 36.97).
  - Result: `"result" : "Passed"`, `"totalTestCount" : 1482`, `"passedTests" : 1482`, `"failedTests" : 0`,
    `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 15's 1,465 plus this cycle's 17).
  - The log's four `warning:` lines are `appintentsmetadataprocessor`'s "Metadata extraction skipped, no
    AppIntents.framework dependency found".
  - The simulator is shut down: `simctl shutdown` exit 0, and `simctl list devices` shows `(Shutdown)`
    (`sim-boot.log`).
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`,
  after a release prebuild, `Build complete! (151,58 s)`; 22:24:40–22:30:59; load mean 3.87, min 2.26, max 6.90 over
  38 samples, `bench-load.txt`; `bench.log`). Started without waiting for the load to fall after the simulator run:
  the 1-minute load was 6.25 at the start.
  - Result: `✘ Test run with 44 tests in 8 suites failed after 247.036 seconds with 1 issue.` The issue is P-13's
    (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, unit max 9.52 ms against 5.0 ms; WP-B's,
    `other-wp:b`, routed).
  - `✔ Suite "SyncBenchmarks" passed after 113.342 seconds.`: every WP-F benchmark is within S3-R5's budgets (best of
    three ≤ 10 ms, median ≤ 50 ms).
  - The follow barrier's C2 figures (cycle 15's in brackets):
    - The reclaim during an owed follow: [3.87, 3.88, 3.84] ms with one handle ([4.27, 3.91, 3.87]) and [4.92, 4.96,
      4.89] ms with two ([4.90, 4.97, 4.98]).
    - The mixed reclaim (1 member in 20 changed): [6.28, 6.16, 6.22] ms ([6.26, 6.43, 6.33]); with two handles [7.48,
      7.53, 7.47] ms ([7.89, 7.54, 7.50]).
    - The follow end and drain of 10,000 places: [4.91, 4.86, 4.90] ms ([4.72, 4.79, 4.77]).
    - The follow's last turn plus the drain's first batch: the turn [4.76, 4.81, 4.76] ms ([4.69, 4.70, 4.66]).
    - Throttle extension: [6.81, 6.60, 6.55] ms ([6.58, 6.61, 6.54]).
  - P-9 p99 15.1 ms (budget 50.0, WP-G's); P-4 plan 10,000 11.8 ms (budget 20.0), ratio 1.98 (max 2.5).
  - None of these runs `followedLane`'s walk at 10,000 jobs: its C2 stays unmeasured (under "Residual risks (cycle
    16)").
- **S3-R13** (`.build-s3f/c16/final.sh`, 22:30:59–22:32:25: `git archive` of `d3242d3` into the new folder
  `.build-s3f/t64-c16`, line 1 set to `// swift-tools-version: 6.4` there only; Apple Swift version 6.4
  (swiftlang-6.4.0.34.1)): `swift build --build-tests --scratch-path ../t64-c16-build -Xswiftc -warnings-as-errors`
  exit 0, `Build complete! (49,28 s)`, 0 `warning:` and 0 `error:` lines; `swift build -c release --scratch-path
  ../t64-c16-build` exit 0, `Build complete! (34,48 s)`, 0 `warning:` lines (`t64.txt`, `t64-debug.log`,
  `t64-release.log`). `Package.swift` is not edited in the worktree. The cycle-15 requirements verifier's run on
  `e64cdba` (the non-blocking note): `Build complete! (49,82 s)`, 0 `warning:` lines.
- **Mutants:** under "Cycle 16" (`.build-s3f/c16/mut/`, `mut2/`, `mut3/`, `mut4/`). The failing-test runs of
  `39e18d2` and `abaeec1` are `.build-s3f/c16/fail-head{2,3,4}.log`.
- **`git status`:** clean after the draft's commit (`.build-s3f*` is untracked scratch). `docs/TRACEABILITY.md` is
  untouched: no `--gates-only` or `--full` run was made.

## Gate evidence (cycle 17)

All runs were made on this branch at `5011067`, the last code and test commit (02:38:58). The draft's commit changes
this file only. Scratch was `.build-s3f*` on the shared 8-core host, one run at a time (`.build-s3f/c17/gates.sh`),
after the mutants (under "Cycle 17"). The only overlap: the scratch probe PROBE-C17-ADMIT-DURING-APPLY was built and run
twice in the mutation copy (`.build-s3f/mutsrc`, scratch `.build-s3f/mutbuild`) during the quick run, from about
02:40:39 to 02:41:04. Logs are under `.build-s3f/c17/final/`, with stage times and 1-minute loads in `times.txt`. A
first run on `346a8cb` was stopped during its TSan stage when `5011067` was added; its logs are in `final-346a8cb/` and
are not cited.

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (02:38:58–02:44:27; `quick.log`).
  - 1-minute load: 13.13 at the start, 9.44 at the end.
  - Result: `VERIFY: PASS`, `::: SUMMARY mode=--quick steps-failed=0`.
  - Tests passed: Transport 151, Sync 537 (`passed after 124.670 seconds`: cycle 16's 528 and this cycle's 9),
    Storage 459 (`67.324 seconds`), Model 84 (`61.325 seconds`), Kit 85, Compatibility 71, AppleHosted 104.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (ended 02:44:58,
  `release.log`): `Build complete! (30,49 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 02:44:58, `gates.log`):
  - `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`;
  - `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  02:44:58–02:51:49; `syncx-{1,2,3}.log`).
  - 1-minute load before each run: 7.46, 7.80 and 6.49; 5.26 after the last.
  - Results: `✔ Test run with 537 tests in 53 suites passed after 116.943 seconds.`, `… after 114.342 seconds.`,
    `… after 112.056 seconds.`
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 02:51:49–03:01:54, `tsan.log`).
  - Load (S3-R12 rule 1, from 60 s after the start): mean 5.00, min 3.53, max 10.57 over 55 samples (`tsan-load.txt`).
  - Result: `✔ Test run with 537 tests in 53 suites passed after 556.942 seconds.`; 0 `ThreadSanitizer` lines, 0
    `Time limit` lines.
  - Durations against guards (`python3 .build-s3f/c17/durations.py .build-s3f/c17/final/tsan.log`; 481 of the 537
    reported names have a guard): none over a quarter of its guard.
    - Largest: 24.3 % (`R-SYN-2: a job held for a manifest catch-up stays held until the follow that may move it has
      ended`, 14.60 s of 1 minute).
    - The 242 one-minute tests at most 14.60 s; the 231 three-minute tests at most 39.79 s (22.1 %, the waiting
      verdict's lane test `barrierDecidesA429OnTheLaneAWaitingVerdictLeaves` over its sixteen cases); the 7
      five-minute tests at most 59.83 s (19.9 %); the six-minute stalled-subscriber test 56.27 s (15.6 %).
  - This cycle's 11 new or changed tests all reported (`.build-s3f/c17/newtests.txt`), each with a three-minute guard:
    0.00–39.79 s (at most 22.1 %; the two at 0.00 s are the table tests of `verdictAnswers` and `jobAtVerdict`). The
    new `barrierLeavesAnAdmittedUnlistedIDToTheVerdictThatWaits` took 3.55 s over its two cases.
- **Coverage** (`swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks` with `TMPDIR`,
  `CLANG_MODULE_CACHE_PATH` and `LLVM_PROFILE_FILE` under `.build-s3f/tmp`, 03:01:54–03:06:44; `cov-test.log`).
  - 1-minute load 4.00 at the start, 7.33 at the end.
  - Every bundle passed: 151, 537, 459, 84, 85, 71 and 104 tests.
  - Then `xcrun llvm-cov export -summary-only` of `.build-s3f/out/Products/Debug/codecov/default.profdata` over the
    `.xctest` bundles into `.build-s3f/cov.json`, and `python3 Scripts/gates.py coverage --json .build-s3f/cov.json`
    (`cov-gate.log`).
  - Result: `COVERAGE target=ZTronAssetSync lines= 94.17% (10428/11074) min=90.0 OK`, overall `96.63% (26941/27882)`,
    `COVERAGE device-only-excluded lines=177 share=0.63% max=3.0% OK`, `COVERAGE: PASS`.
- **iOS build:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath
  .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` (ended 03:06:55, `ios-build.log`): exit 0,
  0 `warning:` and 0 `error:` lines. Incremental: `EngineFollow.o` under `.build-s3f/xcode/Build/Intermediates.noindex`
  was rebuilt at 03:06:54.
- **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro, iOS 27.0, booted by
  `simctl boot`; `Test-ZTronAssetKit-2026.11.01_03-07-05-+0100.xcresult`, 03:06:55–03:12:31; `.build-s3f/sim.log`,
  `sim-summary.json`).
  - 1-minute load 7.07 at the start, 22.25 at the end (the 5-minute 54.05).
  - Result: `"result" : "Passed"`, `"totalTestCount" : 1491`, `"passedTests" : 1491`, `"failedTests" : 0`,
    `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 16's 1,482 plus this cycle's 9).
  - The log's four `warning:` lines are `appintentsmetadataprocessor`'s "Metadata extraction skipped, no
    AppIntents.framework dependency found".
  - The simulator is shut down: `simctl shutdown` exit 0, and `simctl list devices` shows `(Shutdown)`
    (`sim-boot.log`).
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`,
  after a release prebuild, `Build complete! (105,13 s)`; 03:14:22–03:20:03; load mean 4.95, min 3.85, max 7.46 over
  35 samples, `bench-load.txt`; `bench.log`). The 1-minute load was 7.46 at the start (the 5-minute 38.84, after the
  simulator run).
  - Result: `✘ Test run with 45 tests in 8 suites failed after 204.383 seconds with 1 issue.` The issue is P-13's
    (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, unit max 5.525041 ms against 5.0 ms in
    509 units, unlink p99 0.057792 ms; WP-B's, `other-wp:b`, routed).
  - `✔ Suite "SyncBenchmarks" passed after 69.459 seconds.`: every WP-F benchmark is within S3-R5's budgets (best of
    three ≤ 10 ms, median ≤ 50 ms).
  - `inboundWalkTurns` (`correct-9`): the attempt's end turn that walks 10,000 owed jobs (`bringInbound`, nothing
    moved) [3.27, 3.18, 3.24] ms, and the 429's `followedLane` with a verdict waiting [2.41, 2.41, 2.49] ms.
  - The follow barrier's other C2 figures (cycle 16's in brackets):
    - The reclaim during an owed follow: [4.13, 3.99, 3.95] ms with one handle ([3.87, 3.88, 3.84]) and [5.07, 5.09,
      5.08] ms with two ([4.92, 4.96, 4.89]).
    - The mixed reclaim (1 member in 20 changed): [6.62, 7.23, 6.69] ms ([6.28, 6.16, 6.22]); with two handles [8.30,
      7.99, 7.98] ms ([7.48, 7.53, 7.47]).
    - The follow end and drain of 10,000 places: [4.94, 4.85, 4.92] ms ([4.91, 4.86, 4.90]).
    - The follow's last turn plus the drain's first batch: the turn [4.86, 4.94, 4.88] ms ([4.76, 4.81, 4.76]).
    - Throttle extension: [6.77, 6.85, 7.04] ms ([6.81, 6.60, 6.55]).
  - P-11 (`correct-8`): `speedup 3.4704757606074605 (min 3.0)`, concurrency 1 3.570 s and 5 1.029 s: no miss in this
    run. P-9 p99 15.111 ms (budget 50.0, WP-G's); P-4 plan 10,000 11.69 ms (budget 20.0), ratio 2.05 (max 2.5).
- **S3-R13** (`.build-s3f/c17/gates.sh`, 03:20:03–03:21:32: `git archive` of `5011067` into the new folder
  `.build-s3f/t64-c17`, line 1 set to `// swift-tools-version: 6.4` there only; Apple Swift version 6.4
  (swiftlang-6.4.0.34.1)): `swift build --build-tests --scratch-path ../t64-c17-build -Xswiftc -warnings-as-errors`
  exit 0, `Build complete! (52,08 s)`, 0 `warning:` and 0 `error:` lines; `swift build -c release --scratch-path
  ../t64-c17-build` exit 0, `Build complete! (35,02 s)`, 0 `warning:` lines (`t64.txt`, `t64-debug.log`,
  `t64-release.log`). `Package.swift` is not edited in the worktree.
- **Mutants:** under "Cycle 17" (`.build-s3f/c17/mut/`, `mut2/`, and `ul-mut-run{1,2}.log`). The failing-test run of
  `5414df3` is `.build-s3f/c17/failing-old2.log`.
- **`git status`:** clean after the draft's commit (`.build-s3f*` is untracked scratch). `docs/TRACEABILITY.md` is
  untouched: no `--gates-only` or `--full` run was made.

## Gate evidence (cycle 18)

All runs were made on this branch at `4fb1375`, the last code and test commit (07:01:57). The draft's commit changes
this file only. Scratch was `.build-s3f*` on the shared 8-core host, one gate at a time (`.build-s3f/c18/gates.sh`).
The mutant rounds overlapped the first stages: round 3 ran 07:01:08–07:12:38, round 1's last mutants until 07:16:26
and round 4 07:15:15–07:15:44, so the quick run and the three Sync runs shared the host with them. TSan, coverage,
the iOS build, the simulator run, the benchmarks and S3-R13 ran with no mutant. Logs are under
`.build-s3f/c18/final/`, with stage times and 1-minute loads in `times.txt`. A first run on `640ac96` was stopped during
its third Sync run when the mutant pass asked for `c0bbe09` and `4fb1375`; its logs are in `final-stopped/` and are not
cited.

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (07:02:24–07:08:13; `quick.log`).
  - 1-minute load: 5.42 at the start, 11.36 at the end.
  - Result: `VERIFY: PASS`, `::: SUMMARY mode=--quick steps-failed=0`.
  - Tests passed: Transport 151, Sync 543 (`passed after 139.848 seconds`: cycle 17's 537 and this cycle's 6),
    Storage 459 (`73.597 seconds`), Model 84 (`66.544 seconds`), Kit 85, Compatibility 71, AppleHosted 104.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (ended 07:08:44,
  `release.log`): `Build complete! (30,60 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 07:08:44, `gates.log`):
  - `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`;
  - `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  07:08:44–07:16:33; `syncx-{1,2,3}.log`).
  - 1-minute load before each run: 9.88, 6.81 and 4.92; 5.12 after the last.
  - Results: `✔ Test run with 543 tests in 53 suites passed after 133.436 seconds.`, `… after 129.838 seconds.`,
    `… after 129.627 seconds.`
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 07:16:33–07:28:20, `tsan.log`).
  - Load (S3-R12 rule 1, from 60 s after the start): mean 4.99, min 3.04, max 12.71 over 65 samples (`tsan-load.txt`).
  - Result: `✔ Test run with 543 tests in 53 suites passed after 630.540 seconds.`; 0 `ThreadSanitizer` lines, 0
    `Time limit` lines.
  - Durations against guards (`python3 .build-s3f/c18/durations.py .build-s3f/c18/final/tsan.log`; 487 of the 543
    reported names have a guard): none over half of its guard (S3-R12 rule 2).
    - Largest: 27.7 % (`R-SYN-5: a 429 counts the interest a waiting verdict leaves to move after it, not one it
      answers (F-28)`, 49.77 s of 3 minutes over its twenty cases; 39.79 s over sixteen in cycle 17). The limit holds
      each case of a parameterized test: in the mutant runs the time-limit issue names its case's arguments, and the
      convergence test ran 194–198 s in all against its 180 s limit. The whole test's figure bounds each case's.
    - The 242 one-minute tests at most 14.20 s (23.7 %, `R-SYN-2: a job held for a manifest catch-up stays held until
      the follow that may move it has ended`); the 237 three-minute tests at most 49.77 s (27.7 %); the 7 five-minute
      tests at most 59.10 s (19.7 %); the six-minute stalled-subscriber test 56.00 s (15.6 %).
  - This cycle's 10 new or changed tests all reported (`.build-s3f/c18/newtests.txt`), each with a three-minute guard:
    at most 49.77 s (27.7 %, the verdict-lane test above).
- **Coverage** (`swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks` with `TMPDIR`,
  `CLANG_MODULE_CACHE_PATH` and `LLVM_PROFILE_FILE` under `.build-s3f/tmp`, 07:28:20–07:33:28; `cov-test.log`).
  - 1-minute load 3.62 at the start, 6.63 at the end.
  - Every bundle passed: 151, 543, 459, 84, 85, 71 and 104 tests.
  - Then `xcrun llvm-cov export -summary-only` of `.build-s3f/out/Products/Debug/codecov/default.profdata` over the
    `.xctest` bundles into `.build-s3f/cov.json`, and `python3 Scripts/gates.py coverage --json .build-s3f/cov.json`
    (`cov-gate.log`).
  - Result: `COVERAGE target=ZTronAssetSync lines= 94.02% (10655/11333) min=90.0 OK`, overall `96.53% (27165/28141)`,
    `COVERAGE device-only-excluded lines=177 share=0.63% max=3.0% OK`, `COVERAGE: PASS`.
- **iOS build:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath
  .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` (ended 07:33:38, `ios-build.log`): exit 0,
  0 `warning:` and 0 `error:` lines. Incremental: `EngineFollow.o` under `.build-s3f/xcode/Build/Intermediates.noindex`
  was rebuilt at 07:33:37.
- **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro, iOS 27.0, booted by
  `simctl boot`; `Test-ZTronAssetKit-2026.11.01_07-33-47-+0100.xcresult`, 07:33:38–07:39:20; `.build-s3f/sim.log`,
  `sim-summary.json`).
  - 1-minute load 6.33 at the start, 15.04 at the end (the 5-minute 43.90).
  - Result: `"result" : "Passed"`, `"totalTestCount" : 1497`, `"passedTests" : 1497`, `"failedTests" : 0`,
    `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 17's 1,491 plus this cycle's 6).
  - The log's four `warning:` lines are `appintentsmetadataprocessor`'s "Metadata extraction skipped, no
    AppIntents.framework dependency found".
  - The simulator is shut down: `simctl shutdown` exit 0, and `simctl list devices` shows `(Shutdown)`
    (`sim-boot.log`).
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`,
  after a release prebuild, `Build complete! (101,80 s)`; 07:41:08–07:47:08; load mean 5.52, min 3.79, max 8.73 over
  37 samples, `bench-load.txt`; `bench.log`). The 1-minute load was 6.49 at the start (the 5-minute 32.45, after the
  simulator run).
  - Result: `✘ Test run with 49 tests in 8 suites failed after 221.269 seconds with 1 issue.` The issue is P-13's
    (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, unit max 5.364125 ms against 5.0 ms in
    503 units, unlink p99 0.061 ms; WP-B's, `other-wp:b`, routed as `reqs-6`).
  - `✔ Suite "SyncBenchmarks" passed after 87.031 seconds.`: every WP-F benchmark is within S3-R5's budgets (best of
    three ≤ 10 ms, median ≤ 50 ms).
  - This cycle's C2 figures at 10,000, longest actor wait per run, against `e1cf3e5`'s (`headbench.log`, load 10.83)
    in brackets:
    - `concentrationNotFoundTurns`, a 404 whose verdict waits: [6.27, 6.23, 6.32] ms, best 6.23 ([393.91, 394.76,
      394.21]); the 404's own turn 5.95 ms and the longest held turn after it 6.26 ms in the first run (40 held turns,
      median 1.68 ms); the 429's `followedLane` with the moves owed [2.71, 2.69, 2.66] ms.
    - `concentrationPublicationTurns`, a publication: [5.45, 5.56, 5.72] ms, best 5.45 ([403.53, 400.95, 405.38]); the
      longest held turn [3.84, 3.71, 3.74] ms (38 held turns in the first run, median 1.72 ms).
    - `concentrationFollowTurns`, the follow's own turns with no ending: [3.84, 3.94, 3.91] ms, best 3.84 ([17.49,
      17.56, 17.50]); 39 held turns in the first run, median 1.79 ms.
    - `publicationApplyTurns`: the walk an apply makes for the publications in flight, median of 21 calls [2.12, 2.14,
      2.13] ms; the apply's longest actor wait [4.35, 4.43, 4.67] ms, and [6.11, 6.02, 6.04] ms with a move found for
      nearly every member.
    - `inboundWalkTurns`: the 404's turn that walks 10,000 owed jobs [3.47, 3.41, 3.44] ms, and the 429's
      `followedLane` with a verdict waiting [2.40, 2.34, 2.34] ms.
  - The follow barrier's other C2 figures (cycle 17's in brackets):
    - The reclaim during an owed follow: [3.91, 3.92, 4.02] ms with one handle ([4.13, 3.99, 3.95]) and [5.20, 5.20,
      5.16] ms with two ([5.07, 5.09, 5.08]).
    - The mixed reclaim (1 member in 20 changed): [6.58, 6.60, 6.59] ms ([6.62, 7.23, 6.69]); with two handles [8.03,
      8.02, 8.02] ms ([8.30, 7.99, 7.98]).
    - The follow end and drain of 10,000 places: [5.00, 4.92, 5.02] ms ([4.94, 4.85, 4.92]).
    - The follow's last turn plus the drain's first batch: the turn [4.79, 4.86, 4.88] ms ([4.86, 4.94, 4.88]).
    - Throttle extension: [6.86, 6.77, 6.74] ms ([6.77, 6.85, 7.04]).
  - P-11: `speedup 3.4612088212982366 (min 3.0)`, concurrency 1 3.549 s and 5 1.025 s. P-9 p99 15.129 ms (budget
    50.0, WP-G's); P-4 plan 10,000 11.38 ms (budget 20.0), ratio 2.07 (max 2.5).
- **S3-R13** (`.build-s3f/c18/gates.sh`, 07:47:08–07:48:38: `git archive` of `4fb1375` into the new folder
  `.build-s3f/t64-c18`, line 1 set to `// swift-tools-version: 6.4` there only; Apple Swift version 6.4
  (swiftlang-6.4.0.34.1)): `swift build --build-tests --scratch-path ../t64-c18-build -Xswiftc -warnings-as-errors`
  exit 0, `Build complete! (52,15 s)`, 0 `warning:` and 0 `error:` lines; `swift build -c release --scratch-path
  ../t64-c18-build` exit 0, `Build complete! (35,38 s)`, 0 `warning:` lines (`t64.txt`, `t64-debug.log`,
  `t64-release.log`). `Package.swift` is not edited in the worktree.
- **Mutants:** under "Cycle 18" (`.build-s3f/c18/mut/`, `mut2/`, `mut4/`, `mut5/`). The failing-test run of
  `e1cf3e5`'s sources is `.build-s3f/c18/fail-first.log`.
- **`git status`:** clean after the draft's commit (`.build-s3f*` is untracked scratch). `docs/TRACEABILITY.md` is
  untouched: no `--gates-only` or `--full` run was made.

## Gate evidence (cycle 19)

All runs below were made on this branch at `0684845`, the last code and test commit (20:05:09), unless a run on
`3cd80c7` is named. The draft's commit changes this file only. Scratch was `.build-s3f*` on the shared 8-core host, one
gate at a time (`.build-s3f/c19/gates.sh`). The host's load came from other projects and ran from about 1,000 down to
3 over the cycle; S3-R23 item 1's three load averages are in `times.txt` beside every stage. Mutant round 6 ran
20:05:34–20:20:24 (its last log), so the quick run, the release build and the three Sync runs shared the host with it.
TSan, coverage, the iOS build, the simulator run, the benchmarks and S3-R13 ran with no mutant. Logs are under
`.build-s3f/c19/final/`.

Two earlier runs are kept:

- `final-b8ad024-stopped/` (`b8ad024`, from 18:10:23): stopped in its first Sync run when `drainRestReturnDrop` asked
  for `3cd80c7`. Not cited.
- `final-3cd80c7/` (`3cd80c7`, 18:35:50–19:58:51): a full run. Its benchmarks found the three cases for #7 over C2 at a
  quiet load, which `0684845` fixes. Only its benchmark and TSan figures are cited, with a re-run of one of its
  benchmark cases (below).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (20:05:34–20:11:35; `quick.log`).
  - 1-minute load: 4.59 at the start, 10.74 at the end.
  - Result: `VERIFY: PASS`, `::: SUMMARY mode=--quick steps-failed=0`.
  - Tests passed: Transport 151, Sync 552 (`passed after 170.723 seconds`: cycle 18's 543 and this cycle's 9),
    Storage 459 (`87.424 seconds`), Model 84 (`68.052 seconds`), Kit 85, Compatibility 71, AppleHosted 104.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (ended 20:12:08,
  `release.log`): `Build complete! (32,75 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 20:12:09, `gates.log`):
  - `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`;
  - `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  20:12:09–20:21:51; `syncx-{1,2,3}.log`).
  - 1-minute load before each run: 8.25, 5.68 and 3.62; 4.79 after the last.
  - Results: `✔ Test run with 552 tests in 53 suites passed after 165.453 seconds.`, `… after 159.371 seconds.`,
    `… after 164.249 seconds.`
  - This cycle's 15 new or changed tests (`.build-s3f/c19/newtests.txt`) took at most 7.03, 7.07 and 6.92 s of their
    3 minutes (3.9 %, the bounded-move test at `EngineFollowBarrierSharedMoveTests.swift:292`).
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 20:21:51–20:37:25, `tsan.log`).
  - Load (S3-R12 rule 1, from 60 s after the start; sampled every 10 s, as in cycle 18, where rule 1 asks for 5 s or
    less): mean 62.48, min 3.93, max 362.18 over 88 samples (`tsan-load.txt`). Another project's load rose from 4.13
    at 20:29:41 to 362.18 at 20:31:53, and was back to 4.94 at the end.
  - Result: `✔ Test run with 552 tests in 53 suites passed after 892.345 seconds.`; 0 `ThreadSanitizer` lines, 0
    `Time limit` lines.
  - Durations against guards (`python3 .build-s3f/c19/durations.py .build-s3f/c19/final/tsan.log`, which matches 496
    of the 552 reported names to their `.timeLimit`; the other 56 took at most 1.91 s, `unmatched.py`): none over half
    of its guard (S3-R12 rule 2; `overhalf.py` counts 0).
    - Largest: 31.2 % (`R-SYN-6: a visit or an owed move of more ids than a follow turn moves makes them over the
      follow's turns, at most followIDsPerTurn a turn, with the visit-first answers (C2, F-28)`, 56.11 s of 3 minutes
      over its fourteen cases), then 28.8 % (`R-SYN-5: a 429 counts the interest a waiting verdict leaves to move after
      it, not one it answers (F-28)`, 51.87 s).
    - The 242 one-minute tests took at most 16.39 s (27.3 %), the 246 three-minute tests at most 56.11 s (31.2 %), the
      7 five-minute tests at most 70.35 s (23.5 %), and the six-minute stalled-subscriber test 67.15 s (18.7 %).
  - This cycle's 15 new or changed tests all reported (`.build-s3f/c19/newtests.txt`), each with a three-minute guard:
    at most 56.11 s (31.2 %, the bounded-move test above).
  - The run on `3cd80c7` (19:06:55–19:27:46) passed too: `✔ Test run with 552 tests in 53 suites passed after
    1114.064 seconds.`, with 0 `ThreadSanitizer` and 0 `Time limit` lines.
    - Its rule-1 mean was 117.81 (min 8.18, max 291.05, 119 samples).
    - 52 one-minute tests took 50.1 to 54.3 % of their guard (30.08 to 32.59 s; `overhalf.py`). They are reported
      together, the 248th to the 300th of 552 reports with one three-minute test among them, beside tests that took
      29.95 to 33.34 s, so they ended together. The first minute's 1-minute loads were 261.38 to 432.52.
    - Non-blocking under rule 2: one bundle (not a paired run), a rule-1 mean of 117.81, and no time-out. Recorded with
      these figures, as S3-R12 item 4 recorded cycle 8's.
- **Coverage** (`swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks` with `TMPDIR`,
  `CLANG_MODULE_CACHE_PATH` and `LLVM_PROFILE_FILE` under `.build-s3f/tmp`, 20:37:25–20:43:54, under `sim.lock`;
  `cov-test.log`).
  - 1-minute load 4.94 at the start, 8.92 at the end.
  - Every bundle passed: 151, 552, 459, 84, 85, 71 and 104 tests.
  - Then `xcrun llvm-cov export -summary-only` of `.build-s3f/out/Products/Debug/codecov/default.profdata` over the
    `.xctest` bundles into `.build-s3f/cov.json`, and `python3 Scripts/gates.py coverage --json .build-s3f/cov.json`
    (`cov-gate.log`).
  - Result: `COVERAGE target=ZTronAssetSync lines= 94.23% (10967/11638) min=90.0 OK`, overall `96.59% (27477/28446)`,
    `COVERAGE device-only-excluded lines=177 share=0.62% max=3.0% OK`, `COVERAGE: PASS`.
- **iOS build:** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath
  .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` (ended 20:44:03, `ios-build.log`): exit 0,
  0 `warning:` and 0 `error:` lines. Incremental: `EngineMoves.o` under `.build-s3f/xcode/Build/Intermediates.noindex`
  was rebuilt at 20:44:03.
- **iOS Simulator tests** (simulator 897F9D8D-B10D-4D91-8E22-417A2B9D70AA, iPhone 18 Pro, iOS 27.0, booted by
  `simctl boot` under `sim.lock`; `Test-ZTronAssetKit-2026.11.01_20-44-13-+0100.xcresult`, 20:44:03–20:53:18;
  `.build-s3f/sim.log`, `sim-summary.json`).
  - 1-minute load 7.86 at the start, 266.50 at the end (another project's).
  - Result: `"result" : "Passed"`, `"totalTestCount" : 1506`, `"passedTests" : 1506`, `"failedTests" : 0`,
    `"skippedTests" : 0` (`** TEST SUCCEEDED **`; cycle 18's 1,497 plus this cycle's 9).
  - The log's four `warning:` lines are `appintentsmetadataprocessor`'s "Metadata extraction skipped, no
    AppIntents.framework dependency found".
  - The simulator is shut down: `simctl shutdown` exit 0, and `simctl list devices` shows `(Shutdown)`
    (`sim-boot.log`). `sim.lock` was removed at 20:53:22.
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks`,
  after a release prebuild; 20:53:25–21:01:15; `bench.log`, `bench-load.txt`).
  - When the suites ran: the test command's own build took `Build complete! (144,68 s)`, so the serialized suites ran
    from about 20:55:50. SyncBenchmarks, the fifth, ran from about 20:58:07 to 21:01:12.
  - Load: over SyncBenchmarks the three load averages went from { 6.28 99.45 115.35 } (20:58:15) to { 2.81 57.53
    94.98 } (21:01:06). The 1-minute load stayed at 10 or less throughout, a quiet load (S3-R23 item 3); the 5- and
    15-minute averages still held the other projects' earlier load. Over the whole command the 1-minute load was mean
    39.06, min 2.81, max 245.24 over 47 samples (`bench-load.txt`).
  - Result: `✘ Test run with 52 tests in 8 suites failed after 322.422 seconds with 1 issue.` The issue is P-13's
    (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, unit max 8.548 ms against 5.0 ms in 507
    units; WP-B's, `other-wp:b`, as in every cycle).
  - `✔ Suite "SyncBenchmarks" passed after 185.379 seconds.`: every WP-F benchmark is within S3-R5's budgets (best of
    three ≤ 10 ms, median ≤ 50 ms).
  - This cycle's C2 figures at 10,000 ids, longest actor wait per run, best of three. The three cases ran in
    SyncBenchmarks' last 11 s, between { 2.96 59.43 96.08 } (21:00:56) and { 2.81 57.53 94.98 } (21:01:06). Two earlier
    runs are in brackets:
    - first, the gate run on `3cd80c7`. Its SyncBenchmarks ran from about 19:55:18 to 19:57:16, these three cases in
      its last 16 s, between { 9.27 55.29 78.48 } (19:56:55), { 8.23 53.55 77.59 } and { 7.73 51.95 76.74 } (19:57:15):
      a quiet load;
    - second, `4b1c3a6`'s run (`headbench.log`, 15:10:23–15:10:49, from { 921.55 464.93 918.83 } to { 901.10 497.90
      917.64 }: not a quiet load).
  - The figures:
    - `sharedApplyTurns`, one visit of 10,000 members that share one content:
      - onto one other content: [6.80, 6.67, 6.75] ms, best 6.67 ([24.77, 28.62, 23.37], best 23.37; [117.09,
        105.33, 69.20], best 69.20);
      - each onto a content of its own: [7.18, 7.08, 7.17] ms, best 7.08 ([23.36, 23.91, 22.98], best 22.98; [83.03,
        120.31, 83.27], best 83.03).
    - `divergenceTurns`, 10,000 ids converged on one content and mapped away again:
      - back to their own contents: [7.11, 7.06, 7.00] ms, best 7.00 ([23.73, 23.21, 22.96], best 22.96; [125.22,
        58.84, 60.25], best 58.84);
      - on to fresh contents: [6.97, 7.07, 6.96] ms, best 6.96 ([35.85, 23.22, 24.09], best 23.22; [75.47, 56.46,
        59.99], best 56.46).
    - `inboundHolderTurns`, an attempt's end that brings the 10,000 ids one job holds onto its content: [7.25, 7.34,
      7.31] ms, best 7.25 ([19.93, 21.97, 20.23], best 19.93; [51.41, 54.18, 50.63], best 50.63). The longest held
      turn was [7.24, 7.34, 7.31] ms, of 20 held turns.
    - The same sources, before `0684845` was committed, in the worktree (`.build-s3f/c19/cow/bench1.log`,
      20:04:24–20:04:40, from { 6.76 23.18 53.33 } to { 6.80 22.39 52.52 }): best 6.92, 7.32, 7.25, 7.19 and 7.39 ms.
  - #3's `concentrationPublicationTurns`: [5.03, 5.17, 5.14] ms, best 5.03; the longest held turn [3.75, 3.78, 3.79]
    ms. The cycle-18 verifier's low-load re-runs were [5.73, 6.93, 6.21] ms at load 8.9 to 9.4.
  - The follow barrier's other C2 figures (cycle 18's in brackets):
    - `concentrationNotFoundTurns`: [6.24, 6.20, 6.21] ms, best 6.20 ([6.27, 6.23, 6.32]); the 429's `followedLane`
      with the moves owed [3.37, 3.39, 3.38] ms ([2.71, 2.69, 2.66]).
    - `concentrationFollowTurns`: [3.76, 3.66, 3.71] ms, best 3.66 ([3.84, 3.94, 3.91]).
    - `publicationApplyTurns`:
      - the walk's median of 21 calls: [2.11, 2.13, 2.09] ms ([2.12, 2.14, 2.13]);
      - the apply's longest wait: [3.94, 3.92, 3.90] ms ([4.35, 4.43, 4.67]);
      - the same with a move found for nearly every member: [5.92, 5.84, 5.78] ms ([6.11, 6.02, 6.04]).
    - `inboundWalkTurns`: the 404's turn that walks 10,000 owed jobs [3.27, 3.25, 3.26] ms ([3.47, 3.41, 3.44]); the
      429's `followedLane` with a verdict waiting [2.86, 2.83, 2.87] ms ([2.40, 2.34, 2.34]).
    - The reclaim during an owed follow: [3.80, 3.77, 3.74] ms with one handle ([3.91, 3.92, 4.02]) and [4.96, 4.89,
      4.91] ms with two ([5.20, 5.20, 5.16]).
    - The mixed reclaim (1 member in 20 changed): [6.25, 6.21, 6.26] ms ([6.58, 6.60, 6.59]); with two handles [7.58,
      8.19, 8.94] ms ([8.03, 8.02, 8.02]).
    - The follow end and drain of 10,000 places: [4.91, 4.88, 4.90] ms ([5.00, 4.92, 5.02]).
    - The follow's last turn plus the drain's first batch: the turn [4.78, 4.71, 4.78] ms ([4.79, 4.86, 4.88]).
    - Throttle extension: [6.77, 10.41, 6.90] ms ([6.86, 6.77, 6.74]).
  - P-11: `speedup 3.7198482390858603 (min 3.0)`, concurrency 1 3.812 s and 5 1.025 s. P-9 p99 15.085 ms (budget
    50.0, WP-G's). P-4 plan 10,000 12.04 ms (budget 20.0), ratio 2.08 (max 2.5).
  - The run on `3cd80c7` (`final-3cd80c7/bench.log`, load mean 83.35, min 7.62, max 286.49 over 59 samples):
    - Result: `✘ Test run with 52 tests in 8 suites failed after 273.396 seconds with 8 issues.`
    - The issues: P-13 and P-5 (WP-B's), the five figures of the three cases above, and the mixed reclaim with one
      handle ([11.88, 14.61, 12.64] ms).
    - The mixed reclaim is cycle 18's case, and `0684845` does not change its path: each member there has its own
      content, so each interest holds one id. In the gate run it ran from about 19:56:18 to 19:56:27, between { 9.94
      62.06 81.88 } (19:56:15) and { 9.40 60.23 81.00 } (19:56:25), the 1-minute load down from 16.99 a minute before.
    - `3cd80c7` re-run alone (`.build-s3f/c19/recheck/`: `git archive` into `src-3cd80c7`, a release build with
      `-enable-testing` in `perf-3cd80c7`, `Build complete! (212,81 s)`, then the case's filter with `--skip-build`)
      met C2 in each of three runs, with one handle and with two:
      - 21:23:30–21:23:42, from { 54.60 42.06 47.84 }, the build's own load: [6.41, 6.37, 6.30] and [7.39, 8.41,
        7.66] ms;
      - 21:23:42–21:23:52, to { 36.94 38.89 46.53 }: [6.58, 7.05, 6.30] and [7.62, 8.75, 7.51] ms;
      - 21:26:16–21:26:25, from { 5.91 25.22 39.82 } to { 5.31 24.46 39.38 }, a quiet load: [6.14, 6.12, 5.93] and
        [7.14, 7.53, 7.04] ms.
    - `0684845` re-run alone (`recheck/mixed.log`, 21:16:06–21:16:16, `Build complete! (0,63 s)`, from { 3.20 31.26
      54.95 } to { 3.09 30.31 54.34 }): [5.99, 5.86, 5.96] and [7.20, 7.10, 7.07] ms
      (`✔ Test run with 1 test in 2 suites passed after 7.231 seconds.`).
    - The gate run's miss did not recur on the same commit run alone, so it is read as the host's load in that minute,
      not as the commit's.
- **S3-R13** (`.build-s3f/c19/gates.sh`, 21:01:15–21:01:56; then the release build, 21:07:23–21:07:58):
  - Setup: `git archive` of `0684845` into `.build-s3f/t64-c19`, over the `3cd80c7` run's export. The two commits
    differ only in `EngineMoves.swift`, which compares equal to HEAD's there. Line 1 is set to
    `// swift-tools-version: 6.4` there only; Apple Swift version 6.4 (swiftlang-6.4.0.34.1).
  - `swift build --build-tests --scratch-path ../t64-c19-build -Xswiftc -warnings-as-errors`: exit 0,
    `Build complete! (40,01 s)`, 0 `warning:` and 0 `error:` lines.
  - `swift build -c release --scratch-path ../t64-c19-build`: exit 0, `Build complete! (34,13 s)`, 0 `warning:` lines.
  - Logs: `t64.txt`, `t64-debug.log`, `t64-release.log`. `Package.swift` is not edited in the worktree.
- **Mutants:** under "Cycle 19" (`.build-s3f/c19/mut/`, `mut-A2.log` to `mut-A5.log`, `mut-B2.log`, `mut-B3.log`,
  `wmut/`, `copy2/` and `killmap.txt`). The failing-test run of `4b1c3a6`'s sources is
  `.build-s3f/c19/fail-first.log` (`✘ Test run with 1 test in 1 suite failed after 4.749 seconds with 8 issues.`).
- **`git status`:** clean after the draft's commit (`.build-s3f*` is untracked scratch). `docs/TRACEABILITY.md` is
  untouched: no `--gates-only` or `--full` run was made.

## Gate evidence (cycle 20)

All runs below were made on this branch at `c03c0e8`, the last code and test commit (02:14:11). The tree was clean
when they started (`times.txt`: `start head c03c0e8 dirty 0`); only this draft was edited while they ran, and the
draft's commit changes this file only. Scratch was `.build-s3f*` on the shared 8-core host, one gate at a time
(`.build-s3f/c20/gates20.sh`, 02:27:58 to 03:32:37). No mutant ran during it; mutant round 4 had ended before it
started. S3-R23 item 1's three load averages are in `times.txt` beside every stage, and every 5 s in the coverage,
simulator and benchmark stages (`cov-load.txt`, `sim-load.txt`, `bench-load.txt`). Logs are under
`.build-s3f/c20/gates/`. Other projects' simulators (`b4-fade-*`, not WP-F's) raised the 1-minute load to 271.77 at
TSan's end; nothing of theirs was touched (S3-R23 item 4).

- **`SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick`** (02:27:58 to 02:34:46; `quick.log`).
  - 1-minute load: 3.99 at the start, 16.68 at the end.
  - Result: `VERIFY: PASS`, `::: SUMMARY mode=--quick steps-failed=0`, 0 `warning:` lines.
  - Tests passed: Transport 151, Sync 561 (`passed after 173.252 seconds`: cycle 19's 552 and this cycle's 9),
    Storage 459 (`86.893 seconds`), Model 84 (`73.196 seconds`), Kit 85, Compatibility 71, AppleHosted 104.
- **Release build** `swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors` (ended 02:35:24,
  `release.log`): `Build complete! (36,96 s)`, exit 0, 0 `warning:` lines.
- **Gates** (`python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md`, then `python3
  Scripts/gates.py docs --sources "$PWD/Sources"`, 02:35:24; `unsafe.log`, `docs.log`):
  - `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`;
  - `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- **ZTronAssetSyncTests ×3** (`swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests`,
  02:35:24 to 02:45:16; `sync{1,2,3}.log`).
  - 1-minute load at each run's end: 6.65, 3.55 and 3.08.
  - Results: `✔ Test run with 561 tests in 54 suites passed after 175.701 seconds.`, `… after 167.672 seconds.`,
    `… after 165.826 seconds.`
  - Durations against guards (`python3 .build-s3f/c20/guards.py`, which matches 502 of the 561 reported names to
    their `.timeLimit`; the other 59 took at most 0.67 s): none over half of its guard. The largest were 7.4 % (13.31
    s of 3 minutes), 6.2 % and 6.0 %.
  - This cycle's tests, at most: the drain bound 2.28 s, the checksum-less walk 3.00 s, the revalidation 3.23 s, the
    re-admission test 1.54 s, the two turn-total tests 0.92 and 0.98 s, the shutdown test 0.003 s (of 1 minute), and
    the three counts tests 0.57 s.
- **TSan** (`swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetSyncTests`, alone, 02:45:16 to 03:01:44; `tsan.log`).
  - Load: 3.08 at the start and 271.77 at the end, another project's. It was stamped at the start and the end only,
    not sampled during the run (S3-R12 rule 1 asks for 5 s or less; under "Not verified here").
  - Result: `✔ Test run with 561 tests in 54 suites passed after 907.020 seconds.`; 0 `ThreadSanitizer` lines, 0
    `Time limit` lines.
  - Durations against guards (`guards.py`, 502 matched; the other 59 took at most 1.71 s): none over half. The
    largest was 27.7 % (`R-SYN-5: a 429 counts the interest a waiting verdict leaves to move after it, not one it
    answers (F-28)`, 49.83 s of 3 minutes), then 24.3 % (14.60 s of 1 minute).
  - This cycle's tests took at most 14.34 s (the revalidation test, 8.0 % of 3 minutes).
- **iOS generic build** (`xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath
  .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`, ended 03:02:03, `ios.log`): exit 0; the
  only output line is the usual `IDERunDestination: Supported platforms for the buildables in the current scheme is
  empty.`
- **Coverage** under `sim.lock` (taken 03:02:03; `swift test --scratch-path .build-s3f --enable-code-coverage --skip
  Benchmarks`, 03:02:03 to 03:08:06; `cov.log`, `cov-gate.log`).
  - Load (`cov-load.txt`, every 5 s): mean 63.23, min 6.86, max 224.26 over 73 samples; another project's load fell
    from 224.26 at the start to 7.94 at the end.
  - Every bundle passed: Transport 151, Sync 561 (`passed after 165.759 seconds`), Storage 459, Model 84, Kit 85,
    Compatibility 71, AppleHosted 104.
  - `python3 Scripts/gates.py coverage --json .build-s3f/c20/gates/cov.json`:
    - `COVERAGE target=ZTronAssetSync           lines= 94.54% (11091/11732) min=90.0 OK`;
    - `COVERAGE overall lines=96.70% (27599/28540) min=80.0 OK`;
    - `COVERAGE device-only-excluded lines=177 share=0.62% max=3.0% OK` / `COVERAGE: PASS`;
    - the other targets: AppleHosted 99.68 %, Kit 97.83 %, Model 99.31 %, Storage 97.37 %, Transport 99.08 %.
  - The changed lines' counts (`covdiff20.py`) are under "Cycle 20", "Not reached and structural lines (cycle 20)": no
    zero-count changed line.
  - **The flake's close, coverage half** (S3-R25 item 4): the Sync bundle passed under `--enable-code-coverage` three
    times, under the same lock:
    - the run above;
    - `covsync2.log`: `✔ Test run with 561 tests in 54 suites passed after 170.130 seconds.`, at a 1-minute load of
      mean 5.47 over 34 samples (2.74 to 23.15; 39.80 at its end, 03:10:59);
    - `covsync3.log`: `… after 262.189 seconds.`, at mean 152.87 over 52 samples (39.80 to 271.44).
    - Their durations against guards were at most 5.8 % and 6.7 %. The lock was released at 03:15:25.
- **iOS Simulator** under `sim.lock` (taken 03:15:25, released 03:24:31), on WP-F's own simulator
  `897F9D8D-B10D-4D91-8E22-417A2B9D70AA` (iPhone 18 Pro, iOS 27.0), shut down afterwards: `xcrun simctl shutdown`
  found it already shut down (`Unable to shutdown device in current state: Shutdown`, exit 149), and `simctl list`
  shows it `(Shutdown)`.
  - `xcodebuild build-for-testing -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=897F9D8D…"
    -derivedDataPath .build-s3f/xcode-sim OTHER_SWIFT_FLAGS='-warnings-as-errors'`: `** TEST BUILD SUCCEEDED **`
    (03:15:25 to 03:16:38). The only `warning:` lines are four of `appintentsmetadataprocessor`'s `Metadata
    extraction skipped, no AppIntents.framework dependency found`, none from the compiler.
  - `xcodebuild test-without-building … -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never`, then
    `xcrun xcresulttool get test-results summary` (`sim.xcresult`, `sim-summary.json`): `** TEST EXECUTE SUCCEEDED
    **` (03:16:58 to 03:23:10); `result: Passed`, `totalTestCount: 1515`, `passedTests: 1515`, `failedTests: 0`,
    `skippedTests: 0` (cycle 19's 1,506 and this cycle's 9), on `iPhone 18 Pro`
    `897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, iOS 27.0.
  - **The flake's close, simulator half** (S3-R25 item 4): `-only-testing:"ZTronAssetSyncTests/
    EngineFollowBarrierTests/barrierReadmitsBehindTheOwedVisitsPlaces(_:)" -test-iterations 30`
    (`sim-rep30.xcresult`): `** TEST EXECUTE SUCCEEDED **` (03:23:20 to 03:24:27); `result: Passed`, the device's
    `passedTests: 60` and `failedTests: 0`: 30 iterations of each of the two arguments, 0 failures.
  - Load (`sim-load.txt`, every 5 s): the build at mean 175.42 (102.26 to 239.08), the suite at mean 155.46 (10.03 to
    445.26, other projects' simulators), the 30 iterations at mean 51.91 (8.94 to 79.99).
- **Benchmarks** (`swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter
  Benchmarks`, 03:24:31 to 03:32:37; `bench.log`, `bench-load.txt`).
  - When the suites ran: the test command's own build took `Build complete! (144,24 s)`, so the serialized suites ran
    from about 03:26:59. SyncBenchmarks, the fifth, ran from about 03:29:13 to 03:32:36.
  - Load: over SyncBenchmarks the three load averages went from { 2.21 36.61 69.39 } (03:29:13) to { 2.75 20.42
    55.61 } (03:32:34). The 1-minute load was mean 3.58, min 2.21, max 5.59 over 41 samples: a quiet load (S3-R23
    item 3). Over all the suites (03:26:59 to 03:32:37) it was mean 3.68, min 2.21, max 6.28 over 67 samples; over
    the build before them, mean 19.47 (6.56 to 45.37).
  - Result: `✘ Test run with 56 tests in 8 suites failed after 337.375 seconds with 3 issues.`
    - One is P-13's (`BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, unit max 8.380 ms
      against 5.0 ms in 491 units; WP-B's, `other-wp:b`, as in every cycle).
    - Two are RR-21's (`✘ Suite "SyncBenchmarks" failed after 203.265 seconds with 2 issues.`). Both cases fail until
      RR-21 is fixed (under "Cycle 20", "Open" item 1):
      - `concentrationCommitRerouteTurns` (`BenchSync.swift:722:13: Expectation failed: (waits.min() ?? .infinity)
        <= Self.c2Budget`): [48.68, 48.88, 49.27] ms, best 48.68, all of it the commit window; the longest held turn
        [3.77, 3.90, 3.71] ms. Each run committed, served and re-routed 10,000 ids. Before `c03c0e8` was committed
        it measured 48.47 ms best, at load 2.73 to 2.99.
      - `movedBeforeDrainTurns` (`BenchSync.swift:689:13`, the same expectation): [46.65, 46.82, 45.67] ms, best
        45.67; the longest held turn [46.64, 46.81, 45.67] ms. Each run moved 10,000 ids off the job before its
        verdict and re-routed 10,000 after it. Before `c03c0e8` was committed it measured 45.51 ms best, at load
        1.90 to 1.94.
    - Every other WP-F benchmark is within S3-R5's budgets (best of three ≤ 10 ms, median ≤ 50 ms).
  - This cycle's other C2 figures, longest actor wait per run, best of three. In brackets, the same cases on
    `49a0493`'s sources, before the fixes:
    - `drainVerdictTurns`, the drain's visits after 16 waiting verdicts (`ddb0ba1`):
      - 500 ids a job, 8,000 moved: [4.13, 7.46, 6.25] ms, best 4.13; the longest held turn best 4.12. ([41.17,
        41.80, 40.79] ms, best 40.79; `headbench2.log`, 23:55:10 to 23:55:15, at load 2.84 to 3.01.)
      - 625 ids a job, 10,000 moved: [4.10, 4.08, 4.12] ms, best 4.08 ([4.61, 5.08, 4.70] ms, best 4.61).
    - `userSharedApplyTurns`, an apply moving 10,000 ids that share one content, a user-initiated waiter each
      (`f066083`):
      - supersede: [7.22, 7.18, 7.19] ms, best 7.18 ([32.89, 33.05, 33.25] ms, best 32.89);
      - keep: [8.20, 8.12, 8.01] ms, best 8.01 ([71.56, 71.17, 70.82] ms, best 70.82).
      - The bracketed run is `headbench.log`, 23:52:41 to 23:52:56, at load 11.64 to 10.05: not a quiet load, but
        its figures are more than three and seven times C2's budget.
    - `concentrationPublicationTurns`, now through the commit (`c03c0e8`): [9.87, 9.99, 9.86] ms, best 9.86, all of
      it the commit window; the longest held turn [3.77, 3.71, 3.72] ms. It meets C2 by 0.14 ms. Before `c03c0e8`
      was committed it measured 9.81 ms best, at load 2.73 to 2.99.
  - The follow barrier's other C2 figures at 10,000 ids (cycle 19's gate run in brackets):
    - `sharedApplyTurns`: onto one other content [6.86, 6.82, 6.90] ms, best 6.82 ([6.80, 6.67, 6.75], best 6.67);
      each onto a content of its own [7.29, 7.28, 7.24] ms, best 7.24 ([7.18, 7.08, 7.17], best 7.08).
    - `divergenceTurns`: back to their own contents [7.03, 7.06, 7.11] ms, best 7.03 ([7.11, 7.06, 7.00], best
      7.00); on to fresh contents [7.11, 7.04, 7.14] ms, best 7.04 ([6.97, 7.07, 6.96], best 6.96).
    - `inboundHolderTurns`: [7.18, 7.24, 7.18] ms, best 7.18 ([7.25, 7.34, 7.31], best 7.25); the longest held turn
      [7.17, 7.24, 7.18] ms.
    - `concentrationNotFoundTurns`: [6.31, 6.24, 6.28] ms, best 6.24 ([6.24, 6.20, 6.21]); the 429's `followedLane`
      with the moves owed [3.51, 3.45, 3.46] ms ([3.37, 3.39, 3.38]).
    - `concentrationFollowTurns`, no ending: [3.64, 3.73, 3.75] ms, best 3.64 ([3.76, 3.66, 3.71]).
    - `publicationApplyTurns`:
      - the walk's median of 21 calls: [2.13, 2.10, 2.16] ms ([2.11, 2.13, 2.09]);
      - the apply's longest wait: [4.03, 4.02, 4.46] ms ([3.94, 3.92, 3.90]);
      - the same with a move found for nearly every member: [5.88, 5.95, 5.86] ms ([5.92, 5.84, 5.78]).
    - `inboundWalkTurns`: the 404's turn that walks 10,000 owed jobs [3.31, 3.43, 3.37] ms ([3.27, 3.25, 3.26]); the
      429's `followedLane` with a verdict waiting [2.74, 2.73, 2.79] ms ([2.86, 2.83, 2.87]).
    - The reclaim during an owed follow: [3.80, 3.79, 3.80] ms with one handle ([3.80, 3.77, 3.74]) and [4.90, 4.85,
      4.83] ms with two ([4.96, 4.89, 4.91]).
    - The mixed reclaim (1 member in 20 changed): [5.81, 6.12, 5.91] ms ([6.25, 6.21, 6.26]); with two handles [6.92,
      6.85, 7.29] ms ([7.58, 8.19, 8.94]).
    - The follow end and drain of 10,000 places: [4.93, 4.90, 4.86] ms ([4.91, 4.88, 4.90]).
    - The follow's last turn plus the drain's first batch: the turn [4.71, 4.67, 4.65] ms ([4.78, 4.71, 4.78]); the
      longest wait [4.96, 4.99, 4.94] ms.
    - Throttle extension (correct #6): [7.20, 7.79, 7.24] ms, best 7.20 ([6.77, 10.41, 6.90]), at the quiet load
      above.
  - The other R-SYN cases' longest actor waits, as the log reports them (space parking and re-admission, network
    edges, releases, a cancelled resolve, shutdown, refreshes, the prune announcement, retries, re-joins and the
    breaker's cases): 0.02 to 5.24 ms.
  - P-11: `speedup 3.6992047607935787 (min 3.0)`, concurrency 1 3.824 s and 5 1.034 s. P-9 p99 15.121 ms (budget
    50.0, WP-G's). P-4 plan 10,000 11.50 ms (budget 20.0), ratio 2.02 (max 2.5).

## Not verified here

- Device-only behaviour (NWPathMonitor's first callback timing behind S3-CONC-04, background URLSession, real packs,
  thermal and Low Power Mode).
- The ~35 ms prune announcement at `maxEntries` (outside C2's reference scale).
- Cycle 1 left S3F-10, S3F-13 and part of S3F-14 open; cycle 2 closed them (above). Still not reached by any test: the
  S3F-10 regions recorded above as §14 candidates, `other-wp:b` or `other-wp:g`.
- The level-4 verifier's mutants M5 and M6 are not on file: they are reconstructed from `f.md` F-20's description (close
  before the join; no join).
- Cycle 3: a catch-up waiter (joined from the store's newer manifest) whose job fails while a follow is owed is not
  followed (its id is unlisted, `holdsMovedID`); no test orders that case, and the `pumpWaitsForFollow` liveness terms
  survive their mutant (both recorded under "Cycle 3"). Cycle 4 ran the two-TSan-process re-measurement (tables under
  "Cycle 4").
- The probe chain's total wall time at 10,000 is reported, not budgeted; its scaling is pinned by the structural count of
  one re-admission per exit. Cycle 4 corrected the cause of its 20–95 s totals (the store's per-404 index commit and the
  owned tasks' priority below the heartbeat's, not the fake source or the polling); it is about 1.1 s now.
- Cycle 4: the S1-15 run test's guard (`.minutes(3)`, 101.8–104.7 s beside a second TSan process at load 12–32) awaited
  the orchestrator's ruling (given after cycle 5 as S3-R10 and applied in cycle 6); the `noDispatchOwedFlag` and `noFlagPump` liveness terms have no test (reasons under "Cycle
  4" and "Cycle 3"); the 404 path's engine turns are no longer part of the probe-chain benchmark (the 404 path's own C2
  is not benchmarked at 10,000; its turns are per job, with no catalogue-sized walk).
- Cycle 5: the S1-15 run test's guard still awaited the orchestrator's ruling (S3-R10, applied in cycle 6; it was under half of 3 minutes paired at
  load up to about 14, 79.2–79.5 s, and was over it paired at load 10.5–25.9 in the verifier's run, 129.9–130.1 s; no
  paired run at load about 30 was made here); the survivors `noDispatchOwedFlag` and `noFlagPump` still have no test;
  the sweep's follow budget is pinned at 10,000 by the benchmark on this host only (no device run); `other-wp:b` items
  not re-run (P-13, the per-404 index commit).
- Cycle 6: S1-15's run test is judged against 5 minutes (S3-R10); a paired TSan run at a load above about 30 took it to 175.7–175.8 s (59 %), which the
  ruling does not judge, and no paired run at a load of 26–30 was made here (the moderate one reached 25.6). The lane-drop fix is pinned by one two-member
  scenario (A and B on one content) and the sweep's park bound by a 576-member count; a lane drop in a `.settle` sweep
  or the purge path's `.reclaimed` one runs the same code but has no test of its own. The survivors `noDispatchOwedFlag` and `noFlagPump` still
  have no test; `other-wp:b` (P-13, the per-404 index commit) and `other-wp:b` / `other-wp:h` (the Storage time-outs at
  load 100–540) are not re-run here.
- Cycle 7: whether iOS reports `volumeAvailableCapacityForOpportunisticUsage` above
  `volumeAvailableCapacityForImportantUsage` on a device (the precondition of PROBE-C6-LANEGAIN; the fake file system
  sets it, the store does not clamp it). The new re-queue branch's `readmissionsPerTurn` guard has no test of its own
  (removing it leaves one turn bounded by `readmissionsPerTurn + followsPerTurn` re-queues, since only a followed job
  reaches it). `checkRunSettled`'s `admittedBySpace`, the `.read` sweep and the waiting branch still read a job on its
  pre-follow lane until its follow visit (a delay, never a false answer; no test). The hang guards are sized from paired
  runs on this 8-core host at load up to 35; at load 50–78 a paired TSan run times out about 40 one-minute tests, and
  `stalledSubscriberIsBounded` (4 minutes) is over half its limit at load 20–35 pending a ruling. The survivors
  `noDispatchOwedFlag` and `noFlagPump` still have no test; `other-wp:b` / `other-wp:h` items are not re-run here.
- Cycle 8: the sweep follows the jobs it judges (the space-parked ones). A job that is not parked for space (queued
  behind the follow, or downloading) and holds a moved id whose new content is a parked job is moved by the follow's own
  visit, not by the sweep, so the sweep judges that parked job with the interests it holds when the sweep runs; the
  moved interest reaches it later through `addInterest` (`relane` re-queues it if its raised lane fits,
  `failFastJoiner` answers the joiner with the room at that moment otherwise), as a request made at that moment would
  be. No test orders that case. `holdsMovedID`'s key comparison is argued equal to the formatted one from
  `ManifestEntry.transferID`'s definition and `Job`'s `let` fields (no differential test). The sweep's follow bound at
  10,000 is measured by the benchmark on this host only. The margins of `stalledSubscriberIsBounded` and S1-15's run
  test at a paired load of about 30 await the orchestrator's ruling; no paired run near a load of 30 was made here (the
  host stayed at 2–19). The survivors `noDispatchOwedFlag` and `noFlagPump` still have no test; `other-wp:b` items
  (P-13, failed again in this cycle's benchmark run; the per-404 index commit) are not WP-F's. Cycle 7's note that the
  `.read` sweep and the waiting branch read a job on its pre-follow lane no longer applies (both follow first now), and
  `checkRunSettled` returns while a follow is owed (`EngineRuns.swift:572`), so its `admittedBySpace` check never runs
  during one.
- Cycle 9: the follow barrier is pinned by the item-6 tests on this host's fakes; a device's timing is not exercised. The
  R1 boundary probes (PROBE-D2-READ-ORDER, -D3-READ-PROMOTE, -J-UNRELATED-FREE) were not re-run on this branch. Open
  members recorded under "Cycle 9" (§14 (d) and (e) proposed): a join while a `.resolve` verdict waits gets that verdict,
  a retry verdict's user joiner takes the verdict's place in the drain, and the offline and throttle exits are not
  deferred; none has a test. The admission wait of a multi-turn follow (141–149 ms at 10,000 in macOS release) was not
  measured on a device. The survivors `noDispatchOwedFlag` and `noFlagPump` were not re-run against the barrier (a pump
  barred while no event waits is repeated at the follow's end only through a visit that moved a job or the flag), and
  still have no test. The judging turns of the `.reclaimed` sweep's follow-ups (4.0–11.8 ms each at 10,000, measured by
  a scratch probe only) have no benchmark of their own; `reclaimDuringMixedFollowTurns` measures the longest. `other-wp:b`
  items are WP-B's.
- Cycle 10: cycle 9's open members (the joins while a verdict waits, the offline and throttle exits) are fixed with
  tests (above). Not probed: the residuals listed under "Cycle 10" ("Residuals found while fixing": the throttle
  extension's later answers, a policy pause, `readmit`'s pre-visit ranks, the `.edge` events' place among the same
  edge's re-admissions, a visit's re-lane of a job whose place waits, a withdrawal that overtakes a deferred answer) and
  amendment (e) with an incomplete old pass (analysed, not probed). The `.edge` replay is pinned by one scenario (an
  offline failure, then one edge); a transient failure's backoff met by an edge while its verdict waits runs the same
  replay with no test of its own. Two replay branches have no hit in the barrier suite: `.relane` (a withdrawal from a
  job whose verdict waits) and `replayJoin`'s re-route (a later apply that moved a waiting join's id). The survivors
  `noDispatchOwedFlag` and `noFlagPump` still have no test. The R1 boundary probes were not re-run. `other-wp:b` items
  are WP-B's.
- Cycle 11: the inventory's open rows (R-A to R-D, "Cycle 11") are analysed, not probed. `noDispatchOwedFlag` is shown
  observable by a probe, but the probe's scenario then stalls in the store's due-work commit (R-E, also on `2280fda`'s
  sources), not diagnosed; no test is committed for it. PROBE-C9-THROTTLE still differs sweep-first (R2's admission
  wait, ruling requested). The R1 boundary probes were not re-run. `other-wp:b` (P-13) and `other-wp:h` (Transport's
  simulator time-outs) are not WP-F's.
- Cycle 12: R-C (the sweep's place among drained events) is not implemented and has no test. Nine replay branches
  (`removal`, `endClaim`, `endClaims`, `release`, `release(entry: true)`, `continueReleases`, `purge`, the
  `.superseded` and the cancelled-attempt ENOENT deferrals) and three world-view reads (`breakerRecorded`'s view,
  `endThrottle`'s live-end guard under a reading, `withReading`'s conditions swap) survive their mutants: no test reaches
  them with a killing assertion. The part of R-A in I13b (an integrity failure's transition and store-held answers),
  R-F (a group's claims at its registration), R-G (a run's removals after a re-route), R-H (`followedLane` omits
  interests another owed visit moves onto the content) and R-I (place stamps assume a free slot; a `.probe` admission
  and the breaker's outcome recording read live) are analysed, not probed. R-E was dated at `5203ccb` and `40ecd95`
  only (the scenario cannot be built at `s3-base`). The R1 boundary probes were not re-run. `other-wp:b` (P-13) is not
  WP-F's.
- Cycle 13: the suspected offline-join answer difference (put back under "Cycle 13") is not probed: the fake source's
  scripted outcome ignores the conditions. RR-2 (a sweep's second judgement after the barrier), RR-4 (the `.superseded`
  and ENOENT places) and RR-5's retire-and-restart case are analysed, not probed. `alarmAtPark` stays equivalent by
  reasoning; no probe output exists. `breakerReadLive` is killed only by `barrierAnswersAJoinOnTheBreakerAtItsRequest`'s
  time limit (its sweep-first case does not end under the mutant), not by an assertion. The mutants of batches A to C
  ran on `affe65e`'s sources, before `3e3ef0d` added the `.spaceSweep` event and `128fda9` removed `replayThrottle`'s
  copies; batches D to H ran on `3e3ef0d` and batch I on `128fda9`. `joinNow`'s second full-suite run was stopped (its
  two runs that count are batch I's two-test runs). The R1 boundary probes were not re-run. `other-wp:b` (P-13) is not
  WP-F's.
- Cycle 14: RR-2 and RR-4 (finding 5) are still analysed, not probed. Finding 11 (a nested drain's `.read` sweep) is not
  changed and has no test: no barrier test reaches `checkRunSettled`'s sweep from a replay. RR-1's remainder (a
  `publishedAfterApply` job's interests not counted by `followedLane`) is not probed. `failureMoveBehindBarrier`
  survives as an order-only difference (under "Cycle 14"). A user job's preemption of lower-lane work is not counted in
  `freeSlots()` (S3-R17 item 2 accepts the live gates there); no test orders that case. The cycle-13 verifier's TSan
  figures (finding 4) are recorded as reported; no TSan run at their load (mean 25) was made here. The R1 boundary
  probes were not re-run. `other-wp:b` (P-13, P-5) and `other-wp:g` (P-9) are not WP-F's.
- Cycle 15: RR-2 and RR-4 (finding 12) are still analysed, not probed. RR-10 (a start's live edge serial) is not probed.
  The three items put to the orchestrator under "Cycle 15" (a verdict that waits across a later apply, the publication
  failure's await window, a drain-turn seam) are analysed, not probed. `laneJobsWalkAlways` and
  `spaceFailureEpochDropped` survive with the reasons given there. Finding 11's C2 figure is the verifier's; no
  `followedLane` benchmark at 10,000 was added. The R1 boundary probes were not re-run. `other-wp:b` (P-13) is not
  WP-F's.
- Cycle 16: RR-11 and RR-12 (under "Cycle 16") are analysed, not probed. RR-2, RR-4 and RR-10 stay unprobed (S3-R19
  item 4). `followedLane`'s C2 at 10,000 is unmeasured for cycle 16's walk (S3-R19 item 2). The cycle-15 verifiers'
  probes were adapted into tests (their seeds kept where named), not re-run as probes. The R1 boundary probes were not
  re-run. `other-wp:b` (P-13) is not WP-F's.
- Cycle 17: RR-12 to RR-15 (under "Cycle 17") are analysed, not probed; RR-14 is an answer difference by analysis, put
  to the orchestrator. RR-2, RR-4 and RR-10 stay unprobed (S3-R19 item 4). The concentration shape's C2 figures come
  from a scratch run in the mutation copy, not from a committed benchmark. PROBE-C17-ADMIT-DURING-APPLY ran as a
  scratch probe in the mutation copy (not committed), and nothing was changed for it (put to the orchestrator). The
  cycle-16 verifiers' probes were adapted into tests (their seeds kept), not re-run as probes. The R1 boundary probes
  were not re-run. `other-wp:b` (P-13), `other-wp:h` (`LoopbackHTTPServerTests.swift:400`) and `other-wp:d`
  (`SizeAndResumeTests.swift:164`) are not WP-F's.
- Cycle 18: RR-12, RR-13, RR-15 and RR-18 (under "Cycle 18") are analysed, not probed. RR-16's figures are the
  cycle-17 verifier's and RR-17's the cycle-17 scratch probe's; neither was re-run here. RR-2, RR-4 and RR-10 stay
  unprobed (S3-R19 item 4). The moves' and the follow's C2 is pinned by BenchSync on this host only (no device run).
  The cycle-17 verifiers' probes were adapted into tests (their seeds kept), not re-run as probes. The R1 boundary
  probes were not re-run. `other-wp:b` (P-2, P-5, P-6, P-13) is not WP-F's.
- Cycle 19: RR-22 and RR-23 (under "Cycle 19") are analysed, not probed; RR-23 is an answer difference by analysis,
  put to the orchestrator. RR-18's corrected reading, which withdraws it, is analysis too, not probed. RR-19 and RR-20
  rest on the cycle-18 verifiers' probes and RR-21's figures are the cycle-18 verifier's; none was re-run here. RR-2,
  RR-4 and RR-10 stay unprobed (S3-R19 item 4). The branches under "Not reached by a test (cycle 19)" have no test.
  `shutdownReleaseInboundWaitsDrop`'s kill is a hang, with no time-limit line printed, and `drainRestReturnDrop`'s
  round-3 run spun until it was stopped (round 5 killed it at the drain test's bound). The bounded moves' C2 is pinned
  by BenchSync on this host only (no device run). The mixed reclaim's miss in the `3cd80c7` gate run, at a 1-minute
  load of 9.4 to 9.9, is read as the host's from three re-runs of that commit alone; no code difference explains it
  (`0684845` leaves its path as `3cd80c7` had it). The cycle-18 verifiers' probes were adapted into tests (their seeds
  kept), not re-run as probes. The R1 boundary probes were not re-run. TSan's load was sampled every 10 s, where S3-R12
  rule 1 asks for 5 s or less. `other-wp:b` (P-13, and P-5 in the `3cd80c7` run) is not WP-F's.
- Cycle 20: RR-21's two misses are measured, not fixed. Their BenchSync cases fail, and the design under "Cycle 20",
  "Open" item 1, is not implemented. `waitingTarget`'s window is analysed, not reached by a test, and so is the item-9
  observation (the id's removal from `Job.assets` before the per-interest guards), which was not probed. Four rows of
  the C2 inventory have no BenchSync figure. `scheduleDrainFollowUp`'s unspawnable branch has no test. The flake's
  mechanism was observed with a temporary print, not committed. The observation runs were taken under other projects'
  load and are not timings. TSan's load was stamped at its start and end only, not sampled during the run (S3-R12
  rule 1 asks for 5 s or less). The cycle-19 verifiers' probes were adapted into tests (their shapes kept), not re-run
  as probes. The R1 boundary probes were not re-run. The C2 figures are this host's only (no device run).
  `other-wp:b` (P-13) is not WP-F's.
