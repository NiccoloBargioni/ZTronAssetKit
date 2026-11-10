# Residual risks

Every risk accepted at the end of Stage 3: what it is, the ruling that accepted it, its evidence, its likely field
impact, what would show it, and what would re-open it. This document fixes nothing and changes no ruling. Where it
differs from ADR-057 (`docs/DECISIONS.md:563-699`) or from the rulings, they decide. It was written at Stage 5 on
`wp/s5docs` (base `d002758`), with no device and no build or test run of its own (G2). Stage 5's `--full` figures
are read from that run's logs (§0.4). It is not independently verified (`CLAUDE.md` P4).

## 0. How to read it

### 0.1 Conventions

- **Ids.** `RES-nn` are this document's (§15 maps every ledger item to one). `RR-n` are the follow barrier's residual
  risks (S3-R16). `S3-B-nnn` are the Stage 3 backlog's (`.build-orchestrator/s3-backlog.json`). `c23 #n` are point
  8's verification findings (N33). `N<n>` are the orchestrator's rulings (`s3-r28-orchestrator-rulings.md`).
  `rulings` is `.build-orchestrator/s3-rulings-s3f.md`. `s3f.md`, `s3b.md` and the like are `docs/adr-drafts/`.
  `P1` to `P8` are P-13's follow-up items (`.build-orchestrator/s3-post-merge/docs-followup-items.md`), as ADR-057
  cites them (`docs/DECISIONS.md:383`).
- **Heads.** "The merged head" is ADR-057's: s3f's merge, `e840b0e` (`docs/DECISIONS.md:564`). The records cite
  its `--full` logs under `.worktrees/merge-check/.verify-logs/`. They are now in
  `.build-orch/merge-verify-logs-e840b0e/` (`docs/ORCHESTRATION.md:579`), and `.worktrees/merge-check/.verify-logs/`
  holds Stage 5's run on `45df2e1`, the ADR-057 merge, tagged `s3-merged` (`docs/ORCHESTRATION.md:577`; §0.4).
- **Six fields per risk.**
  - **What**: the behaviour, and where it sits.
  - **Ruling**: the classification and the ruling. The owner's words are quoted where ADR-057 quotes them.
  - **Evidence**: figures with their source, file:line or the record. C2 figures carry their 1-minute loads. Every
    figure is this host's (an Apple M3, `docs/DECISIONS.md:582`) unless it says otherwise. An estimate never closes a
    case.
  - **Field**: likelihood and impact in an adopting app. This is this document's assessment, not a measurement. No
    field data exists: no app has adopted the kit (ADR-006, `docs/DECISIONS.md:39`; S3-B-120), and no device test has
    run (`docs/DEVICE-TEST-PLAN.md`).
  - **Noticed**: what would show it. That is a kit signal (§0.2), a device test of `docs/DEVICE-TEST-PLAN.md`, or a
    host run.
  - **Re-open**: the trigger, and the route that would close the risk with its hours. All hours are estimates.
- **C2's decision rule** (`rulings:756-765`; `docs/REOPEN-WP-F.md:131`).
  - The figure is the case's heartbeat, best of 3, against `c2Budget`, 10 ms (`BenchSync.swift:129`).
  - At or below 8.5 ms closes a case. 8.5 to 10 ms is "at the edge".
  - Above 10 ms at 1-minute loads of 10 or less is a miss.
  - A miss seen only above a load of 10 is re-run alone. A case with no run at 10 or less is "not measured at a quiet
    load" (`rulings:763`).
  - The bar covers 10,000 ids, at most 4 interests on one id, and one subscriber, which may be stalled (`rulings:1054`;
    S3-R27 12.1).
- **Code lines** are this branch's. `Sources/` differs from `e840b0e` only in `///` lines (`docs/DECISIONS.md:690`). A
  line taken from a record is marked with its commit.

### 0.2 What the kit shows in the field

- **S1, the long-purge line.**
  - The line is `long purge turn: <ms> ms, <jobs> jobs, <groups> groups`, at `.info` on `.sync`. It is written when a
    purge's first turn exceeds `turnTimeLimit`, 0.010 s (`EngineCommands.swift:964`, `:1006-1013`).
  - It is the only field signal for a C2 miss, and only for the purge's first turn.
  - An app sees it only if it collects `.info` lines: through its own `LogSink`, a `LogTap`
    (`AssetEnvironment.swift:33`, `EnvironmentSeams.swift:79`), or `OSLogStore`. Whether the unified log keeps
    `.info` lines for an `OSLogStore` read is UNVERIFIED (C7; DT-OBS-01; `docs/DECISIONS.md:612`, `:658`).
- **Answers and events.** A call's result, and `events` (`AssetEvent.swift:123-150`), such as `assetFailed` (`:141`).
- **Counts.**
  - `metrics()` (`Reports.swift:264`), with failures by `FailureClass` (`:170`).
  - `diagnosticReport()`'s engine counts (`DiagnosticReportBuilder.swift:116-143`).
  - The `failure <class> <hashed id>` line at `.error` (`EngineJobs.swift:1218`).
- **Nothing times any other turn.** No event, metric or log line times another actor turn. The signpost intervals
  (plan, transfer, verify, commit, gc and eviction; R-OBS-1) time operations, not turns, and show only in a profiler.
  A C2 miss outside the purge is visible only to a profiler on a device (`docs/DEVICE-TEST-PLAN.md` §9) or to the host
  benchmarks.

### 0.3 WP-F's re-open criterion

- The owner's criterion is "how often the misses happen in the field". The owner gave no threshold: "it is the
  owner's call" (`docs/REOPEN-WP-F.md:53`). There is also no collection plan (`docs/DECISIONS.md:625`).
- `docs/REOPEN-WP-F.md` is the resume dossier. This branch has version 1, written at `9aa337c` before the close. Its
  §3 figures are superseded by f3c's (RES-07), and its final version is the orchestrator's (`docs/DECISIONS.md:657`).
- Every WP-F entry below that says "the owner's criterion" means this criterion.

### 0.4 Stage 5's `--full`

- It ran in `.worktrees/merge-check`, detached at `45df2e1` with the committed manifest, from 04:38 to 06:02 on
  7 Nov (`docs/ORCHESTRATION.md:578`; `.build-orch/stage5-full.log:1`, `:132`). The run log gives the 1-minute
  load at the start, 4.11, and at the end, 7.77 (`:2`, `:131`). The TSan log prints no load.
- The benchmarks log (`.worktrees/merge-check/.verify-logs/benchmarks.log`) prints each run's 1-, 5- and
  15-minute loads on 61 case lines, from `:242` to `:449`. No other line prints a load: none before `:242` or after
  `:449`, and none at `:260`, `:263`, `:266`, `:269`, `:279` and `:281`. The Stage 5 loads below are read from it.
- Its code is the merged head's, doc comments aside. Between `e840b0e` and `45df2e1`, `Tests/`, `Scripts/` and
  `Package.swift` are unchanged, and every changed line in `Sources/` (18 files) is a `///` line (checked for this
  document with `git diff`; `docs/DECISIONS.md:690`).
- It ended `VERIFY: FAIL (1 failed: benchmarks)`, with `steps-failed=1` (`.build-orch/stage5-full.log:128-129`).
  Every other step passed (`:4-73`, `:116-127`), among them the three test runs, coverage at 96.93 % overall
  (`:60`) and TSan (`:64-73`).
- The benchmarks step ran 88 tests with 7 issues (`:112`): the six purge shapes at
  `BenchSyncCycle22Purge.swift:32` (RES-01) and P-13 at `BenchStorage.swift:253` (RES-02)
  (`.worktrees/merge-check/.verify-logs/benchmarks.log:129`, `:340-377`). Those are the accepted FAIL's only
  accepted causes, so the run ends in the accepted end state (`docs/DECISIONS.md:633`, `:635`, `:659`).
- Its figures are cited below wherever a risk's evidence or re-open names Stage 5. `docs/VERIFICATION.md` is the
  orchestrator's record of the run, and is not on this branch.

## 1. The accepted FAIL

### RES-01 · The six gated purge misses (R-CLN-6)

- **What.**
  - In six shapes of `purgeTurns(_:)`, the first turn of a purge over 10,000 ids holds the sync engine's actor for
    17.82-64.00 ms, against C2's 10 ms (`docs/DECISIONS.md:626`).
  - The shapes are `oneGroup`, `oneMemberGroups`, `oneGroupScope`, `sharedJobFourGroups`, `fourGroups` and
    `retryJobs`.
  - The test is "R-CLN-6: a purge's first turn over 10,000 ids holds the engine's actor at most C2's 10 ms"
    (`BenchSyncCycle22Purge.swift:15`, asserting at `:32`).
- **Ruling.**
  - These are known misses of C2's 10 ms limit (close ruling point 2), and the cause of the accepted FAIL (point 3).
  - The owner chose "Accept the FAIL", described as: "The tests stay as written and red, and the misses are reported
    with their figures. G3 stays intact, and the six red cases become the to-do list for a re-open. Every later --full
    stays red until they're fixed." (`docs/DECISIONS.md:633`).
  - ADR-057: "The /goal's Done is not met (`PROMPT.md:96`: `VERIFY: PASS` with passing benchmarks). The owner set it
    aside for WP-F with this answer, and Stage 5's report says so." (`:633`).
- **Evidence.** Best of 3 in ms, release with `-enable-testing` (`docs/DECISIONS.md:589`).

  | Shape | after e2-A2.5 (`2abddd1`) | step 8 gate run | its re-run | cycle-22 verifier | the close | `d88bdb1` verification | merged head |
  |---|---|---|---|---|---|---|---|
  | `oneGroup` | 36.14 | 35.71 | 35.98 | 36.91 | 36.54 | 36.45 | 35.87 |
  | `oneMemberGroups` | 37.17 | 37.11 | 37.38 | 38.17 | 37.18 | 37.61 | 38.35 |
  | `oneGroupScope` | 39.59 | 39.74 | 39.82 | 41.69 | 39.64 | 40.73 | 40.07 |
  | `sharedJobFourGroups` | 17.85 | 17.82 | 17.91 | 18.70 | 18.14 | 18.18 | 17.87 |
  | `fourGroups` | 61.09 | 62.21 | 62.56 | 64.00 | 62.02 | 62.39 | 61.64 |
  | `retryJobs` | 36.24 | 36.06 | 36.19 | 37.59 | 36.30 | 36.48 | 36.30 |

  - Loads: the first five sets ran at 2.35-9.09. The verification sampled every 10 s: median 8.39, range 2.61-35.72.
  - At the merged head, `oneGroupScope`, `sharedJobFourGroups` and `fourGroups` ran only above a load of 10, so they
    are "not measured at a quiet load" on that head. They are known misses either way, and were not re-run alone
    (`docs/DECISIONS.md:589`). Each set's loads are in `s3f.md:8632` onwards.
  - Passing shapes at the merged head: `sharedJob` 4.64 ms, `userWaiters` 6.97 ms, `ensures` 7.02 ms (`:589`).
  - Stage 5's `--full` (§0.4), best heartbeat of 3 in ms: `oneGroup` 35.80, `oneMemberGroups` 37.23,
    `oneGroupScope` 39.45, `sharedJobFourGroups` 18.65, `fourGroups` 62.29 and `retryJobs` 36.20, all inside the
    17.82-64.00 ms span above, at 1-minute loads of 2.45-3.12
    (`.worktrees/merge-check/.verify-logs/benchmarks.log:339-376`). So all six were measured at a quiet load, the
    three above included, on code that differs from the merged head's only in `///` lines (§0.4). Passing:
    `sharedJob` 4.64 (load 2.65), `userWaiters` 6.80 (2.60 → 2.55) and `ensures` 7.28 (2.55 → 16.27) (`:360`,
    `:383`, `:385`).
- **Field.**
  - Likelihood: it needs a purge (`AssetClient.purge(_:)`, `AssetClient.swift:324`) while the engine holds jobs or
    groups over about 10,000 ids. How often an app purges at that scale is unknown.
  - Impact: the engine's actor, and the cooperative-pool thread running it, are held for tens of ms on the host.
    Calls into the engine wait meanwhile. Nothing is lost or answered wrongly. A device's figure is unmeasured, and
    may be higher.
- **Noticed.**
  - Field: S1 (§0.2), the only signal.
  - Device: DT-PERF-02.
  - Host: every `--full` ends `VERIFY: FAIL (1 failed: benchmarks)`, and the benchmarks log names the six
    (`docs/DECISIONS.md:633`). Stage 5's did (§0.4).
- **Re-open.**
  - Trigger: the owner's criterion (§0.3). The six red cases are the re-open's to-do list (`docs/DECISIONS.md:633`).
  - Route: route C (`f3-purge-route.md`, stages A-C), 19-28 h, then item 3b's core, 17-26.5 h: 36-54.5 h together.
    Neither was taken (`:626`).
  - `docs/REOPEN-WP-F.md` §6 step 9 measures before any fix.

### RES-02 · P-13: the deletion units' p99 has no spare units

- **What.**
  - P-13 reclaims 10,000 blobs. It is judged on the nearest-rank p99 of the deletion units' durations against
    `batch_ms_max`, 5 ms, and on the total against `gc_total_s_max`, 2 s (`Scripts/quality-gates.json:112-116`;
    `BenchStorage.swift:243`, `:253`, `:591-598`).
  - A unit's budget is 1 ms of work (`BlobUnits.swift:163`).
  - One `unlink(2)` stalls in the kernel about once every 850-1,060 unlinks with the fan-out, and every 490-550 in a
    flat directory. The stalls recur by count, whatever the store controls (`docs/DECISIONS.md:621`).
- **Ruling.**
  - The owner's ruling, option A. The owner's words (29 Oct, 14:25 UTC) were
    "Do not set any budget stop. List P99". The orchestrator read them as option A, the deletion units' nearest-rank
    p99, recorded that reading and told the owner at 14:30 UTC; no correction was found (P4;
    `docs/DECISIONS.md:383`; `.build-orchestrator/s3-post-merge/docs-followup-items.md:39`). ADR-050's amendment
    gives the reading as "P99". `batch_ms_max` stays 5 ms, and `gc_total_s_max` stays 2 s (`docs/DECISIONS.md:380`).
  - It sits inside the accepted FAIL: "A P-13 red with no code change falls inside the accepted FAIL, not a new
    cause" (`:635`).
  - For the owner, information only, not a re-judgment (P8): P-13 "now passes or fails on how many times APFS stalls
    an unlink in a run, not on the store's 1 ms unit bound"; only the owner can change the statistic or the number,
    and "the bar stays as ruled" (`:635`).
- **Evidence.**
  - P1, no spare units.
    - The p99 tolerates n − ceil(0.99 n) units over 5 ms: 4 for 400 ≤ n < 500, 5 for 500-599, and 6 for 600-699.
    - Every run on `e840b0e` had exactly 5 over (525, 528, 509 and 519 units).
    - The p99 sample is itself a stalled unit, at 4.31-4.89 ms. p95 is about 0.99 ms, and the on-CPU maximum about
      1.0 ms (`docs/DECISIONS.md:635`).
  - P2, about 30 % of runs fail with no code change.
    - The measurement lens counted 17 of 53 recorded runs (Wilson 95 % 0.21-0.45). A Poisson fit at a mean of 4.56
      gives P(≥6) = 0.31.
    - The refuter counted 14 of 50. None of the 9 runs since s3b's reaper-queue change would fail, but 5 of those 9 sit
      at the limit.
    - Some failures came at a quiet load (`:635`).
  - P7: P-13 prints no load averages (`:635`).
  - Three quiet runs on `e840b0e` (loads 4.14 → 3.65): p99 4.89, 4.81 and 4.31 ms; maxima 10.51, 9.70 and 8.00 ms;
    totals 0.57-0.58 s (`:574`). The quiet-load p99 margin is 2-14 % (`:635`).
  - In the merged head's `--full` it passed: p99 4.80 ms, maximum 8.09 ms, 525 units (`:634`).
  - In Stage 5's `--full` (§0.4) it was red: p99 5.835917 ms against 5.0 ms, maximum 10.721417 ms, 525 units and
    0.588 s in all; p50 0.964792 ms, p95 0.997292 ms (`.worktrees/merge-check/.verify-logs/benchmarks.log:128-129`).
    7 units were over 5 ms (`benchmarks.log:128`), 2 more than the 5 the nearest-rank p99 tolerates at 525 units.
    The code is the merged head's, so it is a red with no code change, inside the accepted FAIL
    (`docs/DECISIONS.md:635`), and one more red run for P2.
  - Under the old maximum assertion it was red at the close on `450022b` (13.583 ms longest, 490 units) and on
    `d88bdb1` (9.87 ms, 507 units) (`:634`).
  - On `d66eb2f` (load 8.9 → 5.7): 0.598 s in 562 units; unit maximum 7.869 ms (p50 0.962, p95 0.993); on-CPU
    maximum 1.003 ms (`:585`).
  - The hunter, at load 12.9: 7-13 stalls over 2 ms per 10,000 unlinks, with maxima of 4.4-6.6 ms
    (`s3b.md:358-388`). The periodicity is host APFS evidence only (`docs/DECISIONS.md:671`).
- **Field.**
  - Likelihood: the stalls recur by count on the host's APFS. A device's APFS was not measured.
  - Impact: a unit occasionally holds its thread through a stalled unlink. The host maxima on record are 7.9-13.6 ms,
    of which about 1 ms is on CPU. A whole reclaim takes about 0.6 s of its 2 s. There is no correctness effect.
  - The visible cost is a red benchmark on about 30 % of host runs.
- **Noticed.**
  - Host: the benchmarks stage names P-13.
  - Device: DT-PERF-03.
  - Field: no signal times a unit.
- **Re-open.**
  - Only the owner can change the statistic or the number (P8).
  - A device figure from DT-PERF-03 is information for the owner, not a re-judgment (`docs/DEVICE-TEST-PLAN.md` §9).

## 2. Known misses of C2's 10 ms limit (owner ruling 2026-11-06)

They are recorded and not routed. No code, test or bench is added for them (N25's precedent;
`docs/DECISIONS.md:571`, `:625`). Every shape is at 10,000 ids, with at most 4 interests on an id, unless it says
otherwise.

Common fields for RES-03 to RES-07, so the entries do not repeat them:

- **Field.** As RES-01: each is a single engine turn longer than C2's limit at about 10,000 ids (a purge's first turn,
  or APM's answer turn). None loses data or changes an answer. How often an app meets these shapes is unknown.
- **Noticed.** S1 shows only a purge's first turn. APM's turn (RES-05) has no signal. No host bench times RES-03,
  RES-04, RES-06 or RES-07, so `--full` does not see them (`docs/REOPEN-WP-F.md:31`; `docs/DECISIONS.md:631`).
- **Re-open.** The owner's criterion (§0.3).

### RES-03 · N7's five, by estimate

- **What.** Five purge shapes. None is a committed case. They were written in the scratch copy `.build-s3f/c23/bench0`
  and never built or run (`docs/DECISIONS.md:571`, `:627`).
- **Ruling.** Known misses by estimate (close ruling point 2; `end-sooner-options.md` §3.0, R4). Point 1 keeps them
  in scratch (`docs/DECISIONS.md:571`).
- **Evidence.** All are estimates (`docs/DECISIONS.md:627`).

  | Shape | Today | After route C |
  |---|---|---|
  | `keptUnderThreeGroups` (a user waiter on each id, plus three prefetch groups) | 38-48 ms | 34-39 ms |
  | `fourGroupJoins` (40,000 joins waiting for the follow) | 15-22 ms | not given |
  | `mixedLaneGroups` | no figure | 24-33 ms |
  | `pendingClaimGroups` | no figure | 16-18 ms |
  | `oneMemberGroupsFourPerID` (40,000 one-member groups, four on each id) | no figure | 8-16 ms |

- **Field.** As §2. `keptUnderThreeGroups` is the costliest by estimate.
- **Noticed.** As §2: S1, for a purge's first turn.
- **Re-open.** The owner's criterion. Route: route C with item 3b, two of them only at its stage B or C, so the same
  36-54.5 h as RES-01 (`docs/DECISIONS.md:627`).

### RES-04 · f3b-review §7's two variants and route A §9's third shape

- **What.** Three purge shapes, with no figure for today.
  - `fourGroupJoins` over 40,000 one-member groups.
  - Three kept interests over one purged interest, with B-2 in place.
  - A prefetch waiter under three groups.
- **Ruling.** Known misses with no figure for today (close ruling point 2, R4; `docs/DECISIONS.md:628`).
- **Evidence.** All are estimates (`docs/DECISIONS.md:628`).
  - The first two: 3-11.5 ms and 4.5-8.9 ms after route C and item 3b's merge (`f3b-review.md:148-149`).
  - The prefetch waiter: 6-10 ms after route C and A-2, or 3-5.5 ms with A-3b (`f3b-route-a.md:173`).
- **Field.** As §2. Their tops sit at or just above the bar even after the routes.
- **Noticed.** As §2.
- **Re-open.** The owner's criterion. Route: as RES-03. A-2 adds 2.5-4 h on top of route C (`f3b-route-a.md` §10).

### RES-05 · APM's answer turn

- **What.** `answerPresentMembers`' answer turn (`EnginePresence.swift:345`) holds the engine's actor longer than C2
  allows when it answers groups or users present in the store (correct #5).
- **Ruling.** A known miss (close ruling point 2; `docs/DECISIONS.md:629`).
- **Evidence.** PROBE-C21-APM, a scratch probe rebuilt on `9aa337c`, in-actor, best of 3, at loads 9.85 → 8.65
  (`docs/DECISIONS.md:590`).
  - Groups: 11.10 ms, a miss.
  - Users: 13.93 ms, a miss.
  - One group: 9.37 ms, at the edge.
  - It is not a committed case.
- **Field.** As §2. The answer path runs whenever many waiters are answered from the store at once, so it is not tied
  to a purge.
- **Noticed.** No signal: S1 does not cover this turn, and no committed bench times it.
- **Re-open.** The owner's criterion. Route: d2's route (a) with B1 (S3-R27 item 3), not estimated. Cycle 22's lump
  for S3-R27 items 1 to 3 was 10-15 h (`docs/DECISIONS.md:629`).

### RES-06 · Item 4's k = 2 and k = 4 shapes (unproven, not a miss)

- **What.** Shapes where k holders share an id (reqs #2; correct #9). They are recorded beside the misses as unproven,
  not as a miss.
- **Ruling.** Close ruling point 2 (`docs/DECISIONS.md:630`).
- **Evidence.** Unmeasured. The estimate is 9-10 ms at k ≥ 4, at the edge, not above it
  (`c21/d3-many-holders.md:25-26`, UNCONFIRMED; `docs/DECISIONS.md:630`).
- **Field.** As §2, if the estimate holds. It may not be a miss at all.
- **Noticed.** As §2. No bench times it.
- **Re-open.** The owner's criterion. Route: A1, and A2 if taken (S3-R27 item 4), not estimated
  (`docs/DECISIONS.md:630`).

### RES-07 · N25's three

- **What.** Three purge shapes.
  1. Failed user jobs with `.retry` deadlines, under one to three prefetch groups.
  2. A bulk waiter under three prefetch groups.
  3. A prefetch group and a bulk group, under a third group's pending claim.
- **Ruling.** Known misses by the owner's ruling N25 (S3-R28 item 3). The owner's words: "leave these three cases out
  of cycle 23 and record them as known misses of the 10 ms limit. But, in a few months, we might re-open this package,
  depending on how frequently the misses are. So you keep all your analysis results and persist what's needed for a
  later resume" (`docs/DECISIONS.md:631`; `docs/REOPEN-WP-F.md:14-18`).
- **Evidence.** Estimates after route C and item 3b's merge, brought up to f3c's review (point 6;
  `f3c-open-shapes-review.md`, CORRECTED). None is measured, and no bench builds them (`docs/DECISIONS.md:631`).
  1. About 500 ms if the origin admits a user request. That is derived, and it is today's cost too:
     (571.12 − 36.24) ms / 10,000 ≈ 53 µs per heap scan, because T20's `heap.remove` scans the whole heap
     (`EngineJobs.swift:360-364`). Otherwise 9-18 ms. The refused form (breaker open) costs 11.9-22.5 ms after route C
     and 3b. In production both paths cost 15-60 ms more, from the `originID` builds (RES-09).
  2. 12.9-23.3 ms (it was 9-17 ms in `docs/REOPEN-WP-F.md:39`).
  3. About 21-34 ms (it was 10-20 ms in `docs/REOPEN-WP-F.md:43`). Skipping the re-queue breaks R-SYN-3.
- **Field.** As §2. Row 1 is the largest single-turn figure in this document: about half a second (derived), if the
  origin admits the user request. It needs many failed user jobs that wait on `.retry` deadlines when the purge comes.
- **Noticed.** As §2: S1, for a purge's first turn. This is the one signal that would show row 1's half second.
- **Re-open.** The owner's criterion.
  - Route: f3c's core, 12-18.5 h on top of route C and 3b. Its stage figures are in `s3f.md:8708` onwards.
  - For row 1, A-6 alone (`EngineTimers.swift:111`) reaches 11.5-18 ms, and an in-place re-admission 7-12 ms. Going
    lower needs table order, which needs a ruling (ledger s3f-close 16).
  - RR-25 (RES-14) is recorded with row 1.

## 3. OPEN, not known misses: f3c's two open shapes (NEEDS-HUMAN-REVIEW)

The options the owner chose from did not show these two, so the owner has not ruled on them. N32 took them to the
owner with the close, and no ruling is recorded. Both are estimates, UNCONFIRMED (`docs/DECISIONS.md:632`). They are
owner items (`:617`, `:699`). Neither is a known miss.

### RES-08 · The heap scans with many `.retry` entries

- **What.**
  - `readmit` scans the deadline heap once per failed candidate (`EngineReadmission.swift:165-167`).
  - So does `removeJob` outside a purge's walk (`EngineJobs.swift:517-520`).
- **Ruling.** OPEN, with no ruling (N32).
- **Evidence.**
  - 27-55 ms a turn with 5,000-10,000 `.retry` entries, at 512 a turn (`f3c-open-shapes.md:163-164`; its review :31).
    It is an estimate, unmeasured, with no reviewed route (`docs/DECISIONS.md:632`).
  - Two cases would measure it (f3c's review, "must add" 2): a satisfied edge over 10,000 jobs that failed transiently
    with `.retry` deadlines (T19), and a release of a 10,000-member group whose jobs are `.failed(.at)`.
  - No bench covers either: the breaker benches fail about five jobs (`BenchSync.swift:1735-1760`).
- **Field.** Likelihood: it needs thousands of transiently failed jobs at once, as after an outage at the origin or on
  the network, followed by a satisfied network edge or a group release. Impact: if the estimate holds, several turns
  of 27-55 ms each.
- **Noticed.** No signal. S1 does not cover these turns.
- **Re-open.** The owner's ruling on f3c's open shapes. The two cases above measure it first.

### RES-09 · The production `originID` cost (and OS-0)

- **What.** Each gate read builds `originID` three times, and HTTP parses its URL each time
  (`HTTPRemoteSource.swift:116-118`). The benches' fake returns a stored value, so no bench figure includes the cost
  (`docs/DECISIONS.md:632`, `:674`).
- **Ruling.** OPEN, with no ruling (N32). OS-0, caching `originID` (1-2 h), would need `RemoteSource.originID`'s doc
  (`RemoteSource.swift:90-91`) to state that the id is constant. That is a contract change. f3c's review (:102)
  offered "not verified" or OS-0, and the ruling chose "not verified" (`docs/DECISIONS.md:632`).
- **Evidence.** 15-60 ms per 10,000 gate reads, at an unmeasured 0.5-2 µs per build (`docs/DECISIONS.md:632`). It
  reaches `blockCleared` and the failed-user purge rows (`:674`), so RES-07 row 1 costs this much more.
- **Field.** Likelihood: it is paid on every gate read in production, so the larger turns that read gates 10,000 times
  are longer than any host figure shows. Impact: up to tens of ms more on those turns, by estimate.
- **Noticed.** No signal. Only a device profile of a turn with many gate reads would show it (`docs/DEVICE-TEST-PLAN.md`
  §9).
- **Re-open.** The owner's ruling on OS-0 and the contract change (`docs/DECISIONS.md:696`).

## 4. Known residual correctness risks (owner ruling 2026-11-06)

### RES-10 · The ENOSPC class

- **What.**
  - An answer differs between the two visit orders (visited first, swept first) because an event lands inside an
    ENOSPC window.
  - The window runs from a transfer's or a publication's ENOSPC end to the return of `spaceFailed`'s free-space read
    (`docs/DECISIONS.md:637`).
  - The window's places:
    - the transfer's ENOSPC end, `EngineFailures.swift:196-212`;
    - the publication's end, `EngineDispatch.swift:1259` and `:1298-1301`;
    - the read, `EngineFailures.swift:564-596`.
- **Ruling.** A known residual correctness risk, not blocking.
  - The owner chose "Yes, the whole class", described as: "A different answer between the two visit orders, caused by
    an event inside the disk-full window, is recorded, not fixed. Broken MUSTs, hangs and flaky tests there still
    block." Earlier, N28 (S3-R28 item 1c): "Agreed let's document it as known risk" (`docs/DECISIONS.md:636`).
  - What is exempt: the answer differences of S3-R16 1(a) whose cause falls inside the window (`:637`).
  - N29's T20 test finds its members. Where the test and the owner's words differ, the owner's words decide.
  - A late-drain difference is exempt only when its cause falls inside the window. Otherwise it follows point 8, and
    the orchestrator asks the owner in one line whether it joins the class (`:637`; `:656`).
- **Evidence.**
  - Correct #1, PROBE-C22C-TS-DRAIN-JOIN, seed 2_029_101.
    - Visited first, A, X and V get `failed(insufficientSpace(required: 100000, available: 31318659))`, with one start.
    - Swept first, they get `ok(100000 B)`, with two starts.
    - The control, seed 2_029_201, answers alike in both orders.
  - Correct #2, PROBE-C22C-APPLY-IN-READ, seed 2_029_301: visited first `available 31318658` with one start; swept
    first `ok`, with two starts.
  - Each was 2/2 on `9aa337c`, and again on `d88bdb1` (c23 #8) (`docs/DECISIONS.md:638`).
  - The probes cap retries at 1 (`maxAttemptsPerRun = 1`; the default user policy has 2, `SyncTuning.swift:44`) and
    script the second attempt to succeed (`:639`).
  - Suspected by code reading only, UNCONFIRMED: W-AWAY; W-DB; W-JOIN-HOP at a publication's end and in the late
    drain; item 1's former step-0 shapes; and `f1c-review.md` §6's shapes. Each is a member only if a run shows the
    difference, and a shape a verifier newly finds is included (`:638`).
- **Field.**
  - Likelihood: it needs a full disk during a transfer or a publication, and a second event (an apply, a join, a
    user request) inside the short window before the free-space read returns.
  - Impact: what the user sees (N29) is a request made before the end and replayed in the read. One order answers
    `insufficientSpace` after one start; the other serves the asset after a second start. Both answers are legal on a
    full disk. No MUST or invariant is known to break; one that did would still block.
- **Noticed.**
  - The user sees `insufficientSpace` (`assetFailed`; the ENOSPC `FailureClass`), which is also the correct answer on
    a full disk. The field cannot tell which order produced it.
  - Device: DT-STO-01 and DT-STO-02 exercise a full disk, not this window.
- **Re-open.**
  - Trigger: the owner's criterion (field frequency; `docs/DECISIONS.md:639`). A broken MUST or invariant, a hang or a
    job that nothing advances, or a flaky test inside the window still blocks, and goes to the owner before any merge
    (S3-R16 1(b) to 1(d); `:639`).
  - Why it is not fixed: four analyses were unsound (f1, f1b, f1c route A, f1c route B). Route Q, a 3-5 h independent
    check and then 44-67 h (`f1c-review.md` §3, §9), was not taken.
  - Q itself leaves open W-OBO, W-PEND-LATE's tail, the holder-state approximation (W-BACK-PUB, W-NEST), W-SUPER,
    `lastError`'s figures, and the out-of-class backlog (W-HOP-DEFERRED, W-PROMO, W-PEND-LATE's non-ENOSPC twin)
    (`:639`).
  - Item 1c's freeze stays: `metInItsAttempt` (`EngineJobs.swift:289-297`), `relane`'s guard (`:327`),
    `Job.transferSpaceEnd` and `AttemptEnd.stamped`. No code, test or early probe is added (`docs/DECISIONS.md:571`,
    `:639`).

## 5. N33's open items (point 8: recorded, not fixed)

### RES-11 · c23 #4: `s1-late-start` survives S1's test

- **What.** The mutant `s1-late-start` moves `turnBegan`'s clock read (`EngineCommands.swift:975`) to just after
  `withdrawPurged(request)` (`s3f.md:8203-8205`), and S1's test does not catch it. The ruling's test design moves the
  clock only at the `?(true)` mark, so the place of the first read is right by review only (`docs/DECISIONS.md:640`).
- **Ruling.** An open survivor (point 8, "anything else"; N33). S1's code matches point 5 and is not a defect, so it is
  not reverted (`:640`). `s1-groups-after` is equivalent, since the purge's first turn removes no group.
- **Evidence.** The test moves the clock once, at the first `ended == true` mark (`EngineLongPurgeTurnLogTests.swift`,
  tests at `:16` and `:23`; ledger s3f-close 19). The seam marks are at `EngineCommands.swift:973-977` and `:985-986`
  (`docs/DECISIONS.md:687`).
- **Field.** Likelihood: only if a later change moves the first read. Impact: S1 would then under-report a turn's
  milliseconds, and the owner's field signal (§0.3) would read low.
- **Noticed.** A code review of `performPurge`. No test catches it.
- **Re-open.** At a WP-F re-open, or at any change to S1: add a seam mark inside the walk (the verifier's route;
  `docs/DECISIONS.md:640`, `:657`).

### RES-12 · c23 #7: the harness's idle predicate misses an apply in the caller's task

- **What.** `isIdleSilent` (`EngineSupport.swift:106-109`) ignores an `applyAndFollow` running in the caller's own
  task. A test or probe that applies from its own task, and drives on `isIdleSilent` alone, can leave an apply pending
  without noticing. The harness's `settle()` drives on it alone (`EngineHarness.swift:440-443`).
- **Ruling.** Open (point 8; N33). It is a test-harness hang, not an engine hang (`docs/DECISIONS.md:640`).
  - The `///` correction waits for the orchestrator's ruling, because `EngineSupport.swift` is a contract file
    (`:696`).
  - The rule for test authors: a test or probe that applies from its own task must not drive on `isIdleSilent` alone
    (`:660`).
- **Evidence.**
  - PROBE-C23C-WALK2: 11 of 24 seeds hung past 900 s.
  - The stalled seeds 102, 112 and 116 had `applyTurnHeld` true, `applyQueue` 29-52, and a store sleeper 0.25 s
    ahead.
  - One 1 s clock advance ended every apply, and every end check then passed in 8/8 seeds (`docs/DECISIONS.md:640`).
  - ARCHITECTURE §7.8's Idle adds the environment census (`ManualTimeSource.pendingSleepers == 0`), which would have
    caught them; `isQuiet()` has it (`EngineHarness.swift:271-277`).
- **Field.** None proven: no production liveness defect is shown. The risk is to test results. A future test can pass
  or hang for the wrong reason.
- **Noticed.** A hung or vacuous test or probe that applies from its own task.
- **Re-open.** At a WP-F re-open, or before such a test is written: drive until `isIdleSilent && appliesInFlight == 0`.
  `appliesInFlight` is engine state (`EngineState.swift:260`), not in `EngineIntrospection`, so a fix may need an
  `EngineIntrospection` contract addition (`docs/DECISIONS.md:640`, `:657`).

## 6. The follow barrier's residual risks (RR-n)

The barrier guarantees the answers, MUSTs and invariants of a visit-first engine, but not its order, place, timing or
backoff (S3-R16; `docs/DECISIONS.md:613`). S3-R16 item 2 makes a difference from visit-first non-blocking when it lies
only in "start or dispatch order, queue place or ticket", in "when an answer arrives within the barrier and its drain",
or in "backoff or Retry-After lengths", "while item 1 holds" (`rulings:161-166`). Item 1 still blocks: a different
answer, a broken MUST or invariant, a hang, or a flaky test (`rulings:151-160`).

Common to RES-17 to RES-31, unless the entry says otherwise:

- **Field.** It arises only behind the barrier, while an apply's follow is owed. It changes order, place, timing or
  backoff, not the answer.
- **Noticed.** No wrong answer to see. At most a different start order, or one more request at the origin.
- **Re-open.** A run that shows an S3-R16 item 1 effect (a different answer, a broken MUST or invariant, a hang, a
  flaky test) is a blocking finding, not this risk. Otherwise a WP-F re-open (§0.3).

### RES-13 · RR-24: a shutdown inside the barrier answers `shutDown` to the drain's waiters

- **What.** A shutdown inside the barrier answers `shutDown` to every answer that waits for the drain.
  - Visited first, a T20 retry started at a follow's end can serve its joins before a shutdown.
  - Swept first, with the follow still owed, the same joins wait behind the verdict, and the shutdown answers them
    `shutDown`.
- **Ruling.** A non-blocking difference (S3-R16 item 2; S3-R28 item 2; `docs/DECISIONS.md:613`, `:641`).
- **Evidence.**
  - Probe f2-R1 (visited first, serve forced first): `ok(20 B)` ×11, 2/2 on `9aa337c`. Not committed.
  - A-T-SD's swept-first arm: `shutDown` ×11 with 4 joins behind O's verdict, 3/3 in
    PROBE-C22C-SHUTDOWN-HELD-RETRY. A-T-SD pins it since `03c4e59` (`docs/DECISIONS.md:641`;
    `EngineFollowBarrierDeferBucketTests.swift:767-775`).
  - It qualifies `EngineFollowBarrierTests.swift:1315` ("Shutdown has no visit-first counterpart"): the answers decided
    before a shutdown's first turn do have one, and they may differ in this way.
- **Field.** It needs a shutdown while a follow is owed and a retry is pending. Callers that wait then get `shutDown`
  rather than the asset. The client is going away at that point, so the impact is small.
- **Noticed.** Those calls end with `shutDown`, and `clientShutDown` follows (`AssetEvent.swift:150`).
- **Re-open.** A WP-F re-open (§0.3).

### RES-14 · RR-25: a purge swept first leaves a failed user job its backoff

- **What.**
  - Swept first, `withdrawPurgedJoins` takes the groups' joins before they reach the job (`EngineCommands.swift:1040`,
    before the job walk at `:1043`; `:1116`). The job is never re-laned, so it keeps `.failed(.at)` and its `.retry`
    at its epoch.
  - Visited first, the joins are on the job, and the purge's settle re-admits it (T20, `EngineJobs.swift:360-364`).
- **Ruling.** A residual backoff difference under S3-R16 item 2 (f3c §4; its review's "must add" 6), recorded with
  N25's row 1 (`docs/DECISIONS.md:631`, `:641`).
- **Evidence.** Not probed. T-OS1 (visited first) and T-OS1w (swept first, both drain timings) were not built (f3c
  §5; `docs/DECISIONS.md:641`, `:674`).
- **Field.** A failed user job then waits out its backoff instead of retrying at once after the purge. The user's next
  answer comes later by at most that backoff. No answer changes.
- **Noticed.** No signal (timing only).
- **Re-open.** A WP-F re-open, with RES-07 row 1. Build T-OS1 and T-OS1w first.

### RES-15 · RR-17: a wrong `notFound` under an admission race (for the owner)

- **What.** An admission that races an older apply omitting the id answers `notFound`, although the store lists the
  id (`s3f.md:4432`).
- **Ruling.** For the owner (S3-R21 item 3; `docs/DECISIONS.md:613`, `:641`, `:699`).
  - Pre-existing: both rules predate `s3-base`.
  - Outside the barrier class: visit-first gives the same answer.
  - Options: (a) defer the decision to the catch-up's follow, (b) record the ids joined unlisted. Neither was taken
    (`:641`).
- **Evidence.** PROBE-C17-ADMIT-DURING-APPLY, seed 1_618_202, failed 2/2. Not committed (`docs/DECISIONS.md:641`).
- **Field.** It needs a request for an id while an older apply that omits the id is applied. The impact is a wrong
  answer. This is the one RR whose answer is wrong in both orders: `notFound` for an asset the store lists. RR-24
  (RES-13) changes an answer only between orders, under a shutdown, and that is ruled a non-blocking difference.
- **Noticed.** `assetFailed` with `notFound` (`AssetEvent.swift:141`; `FailureClass.notFound`). In the field this
  cannot be told from a real 404.
- **Re-open.** The owner's choice of (a) or (b).

### RES-16 · RR-20: an empty binding after the wait books a commit (for the orchestrator and Stage 5)

- **What.** When the owed move takes a job's only id, the publication binds nothing, yet books a commit and an object
  success.
  - Its staged `.part` stays until staging GC (R-CLN-3).
  - The free-space estimate drops by its bytes until the next read (`docs/DECISIONS.md:641`; `s3f.md:4775`).
- **Ruling.** Non-blocking. It stays under Stage 5's residual risks (S3-R24 item 1). The fix is the orchestrator's
  decision, with Stage 5 (`docs/DECISIONS.md:656`, `:699`).
- **Evidence.** VERIFY-C18R-EMPTY-BINDING, 2/2. Both orders answer alike: W gets `integrityFailure`
  (`docs/DECISIONS.md:641`).
- **Field.** It needs an apply that moves a publishing job's only id away. The cost is the staged bytes until staging
  GC, and, until the next free-space read, a lower estimate. By this document's reading, admissions judged on that
  estimate see that much less room meanwhile.
- **Noticed.** `storageReport()`'s staging bytes, until staging GC runs.
- **Re-open.** The orchestrator's ruling on the proposed fix: discard the staged file, and retire the job without a
  commit. That changes publication bookkeeping (`docs/DECISIONS.md:641`).

### RES-17 · RR-7: the live gate's answer stands (PROBE-C9-THROTTLE, R-B, the offline join)

- **What.** The engine decides on the live gate and gives the SPEC answer, which can differ from what visit-first gave.
  - PROBE-C9-THROTTLE: `barrierAdmitsTheFollowsNewContentAsAtTheApply` (`EngineFollowBarrierWorldTests.swift:222`).
  - R-B: `barrierAdmitsARequestOnTheBreakerAtItsArrival` (`:369`).
  - The offline join: a join that waits while the network is offline, then succeeds at the barrier-end pump
    (`s3f.md:2962`, `:3239`).
- **Ruling.** "The MUST wins": non-blocking, recorded as a residual risk with its probe (S3-R17 items 1-2;
  `docs/DECISIONS.md:613`). For the offline join, S3-R17 needs no probe (ledger s3f-items 72).
- **Evidence.** The two tests above, run in both orders.
- **Field.** A request near a throttle or breaker change during a follow gets the live gate's answer. That is the SPEC
  answer (R-SYN-5), so nothing is lost.
- **Noticed.** As §6.
- **Re-open.** A change to S3-R17 or to R-SYN-5's reading.

### RES-18 · RR-8: a place given behind the barrier is admitted on the live gates

- **What.** A place given behind the barrier is admitted on the live gates (S3-R18 item 1). A throttle that ended
  during the barrier serves the place. A throttle set during it parks the place with the live wait (`s3f.md:3496`).
- **Ruling.** Non-blocking (S3-R18 item 1; S3-R17 item 2).
- **Evidence.** Only a live gate's change causes the difference. The two changed sweep-first assertions are its probes
  (ledger s3f-docs 101).
- **Field.** As §6.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-19 · RR-2: a space sweep's second judgement after the barrier

- **What.** The sweep's own follow-up judges the jobs still parked once the barrier is down. A parked job may be
  re-admitted earlier than visit-first would, if room arrived meanwhile (`s3f.md:2935`).
- **Ruling.** Unprobed, not blocking (S3-R19 item 4).
- **Evidence.** Not probed (`docs/DECISIONS.md:674`).
- **Field.** As §6. If anything, a job starts sooner.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-20 · RR-3: the places of a commit's re-routed joins

- **What.** The answers are the same. Which job starts first, or takes a freed slot, differs (`s3f.md:2941`).
- **Ruling.** S3-R16 item 2 (order and place).
- **Evidence.** The cycle-12 failing runs on `39d4376`'s sources: WorldTests `:464` (W started before N) and `:523` (R
  took the slot) (ledger s3f-docs 100).
- **Field.** As §6.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-21 · RR-4: the places of `.superseded` and of an ENOENT re-queue

- **What.** A `.superseded` job and a cancelled attempt's ENOENT re-queue each take their place at arrival
  (`s3f.md:2947`).
- **Ruling.** Unprobed, not blocking (S3-R19 item 4).
- **Evidence.** Not probed, and 0 barrier tests reach it (ledger s3f-docs 100; `docs/DECISIONS.md:674`).
- **Field.** As §6.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-22 · RR-5: withdrawals, releases, claims' ends and purges apply at arrival

- **What.** These apply at arrival. A purge also withdraws the joins waiting for the follow (PROBE-C13-PURGE-JOIN). A
  job retired and created again takes one more request for the same answer (`s3f.md:2950`, corrected in cycle 14).
- **Ruling.** S3-R16 item 2.
- **Evidence.** Probe R-F (`dc5e3c3`) (ledger s3f-docs 101).
- **Field.** As §6. At most one more request to the origin for content already being fetched.
- **Noticed.** As §6: one more request at the origin.
- **Re-open.** As §6.

### RES-23 · RR-9: a space sweep inside a drain replay runs a nested drain

- **What.** `checkRunSettled`'s `.read` sweep (`EngineRuns.swift:666-673`), then `advanceFollowForSpaceSweep`, then
  `drainEventsAfterFollow`, run a nested drain inside a drain replay (`s3f.md:3501`).
- **Ruling.** Recorded (S3-R18 item 3).
- **Evidence.** No test reaches it (ledger s3f-docs 101).
- **Field.** As §6. The nested path is unexercised, so a defect there would be unseen.
- **Noticed.** As §6.
- **Re-open.** As §6, or any change to the sweep or the drain.

### RES-24 · RR-10: a start's edge serial is the live one

- **What.** A start's edge serial is the live one, so only the timing of a re-queue differs (`s3f.md:3509`).
- **Ruling.** Unprobed, not blocking (S3-R19 item 4).
- **Evidence.** Not probed (`docs/DECISIONS.md:674`).
- **Field.** As §6.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-25 · RR-12: the move after a verdict runs at the verdict's place in the drain

- **What.** Events between the verdict and its move meet the ids already moved (`s3f.md:3773`; it stands, `:4071`).
- **Ruling.** S3-R16 item 2.
- **Evidence.** Not probed (`docs/DECISIONS.md:674`).
- **Field.** As §6.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-26 · RR-13: `jobAtVerdict` leaves out interests added before the verdict

- **What.** Interests that other visits or waiting joins add before the verdict are left out. That changes only the
  lane read for `retryLater` and an ENOSPC's room, among non-user interests only (`s3f.md:4072`).
- **Ruling.** S3-R16 item 2 (backoff and place).
- **Evidence.** Not probed (`docs/DECISIONS.md:674`).
- **Field.** As §6. Non-user interests only.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-27 · RR-15: order only, behind a waiting verdict

- **What.** A visit's join behind a waiting verdict is placed right behind it. Owed moves go in holders' creation
  order (`Job.epoch`) over the follow's turns (`s3f.md:4084`, rewritten at `:4408`).
- **Ruling.** S3-R16 item 2 (order only).
- **Evidence.** Not probed (`docs/DECISIONS.md:674`).
- **Field.** As §6.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-28 · RR-16, with RR-23: an interest brought onto a job visit-first had superseded

- **What.** A holder's interest is brought onto a job that a visit-first engine had already superseded. Visit-first
  makes one request more: tStarts 2 against 1 (`s3f.md:4412`). RR-23 is RR-16 followed by an apply that maps the id
  on (`s3f.md:4791`).
- **Ruling.** S3-R16 item 2. S3-R24 item 5 rules RR-23 a timing difference in RR-16's family.
- **Evidence.** PROBE-C17C-INBOUND-SUPERSEDED, seed 1_717_002, with its CONTROL, and the CONSISTENT variant, seed
  1_717_022 (ledger s3f-docs 103).
  - Swept first fails 6/6, with W `notFound` against 100,000 B served, only because the fake answers T's first request
    404 and its second 200.
  - CONSISTENT, with every request for T answered 404, passes both orders 3/3. CONTROL passes 6/6.
  - RR-23 is not probed, and needs a fourth manifest (`docs/DECISIONS.md:674`).
- **Field.** A start-count difference while the origin answers alike. It becomes an answer difference only if the
  origin answers two requests for one content differently, as a CDN mid-deploy might.
- **Noticed.** One more request at the origin. A different answer only with an inconsistent origin.
- **Re-open.** As §6; also an origin known to answer inconsistently.

### RES-29 · RR-19: a publication's wait widens the window for an apply before its bind

- **What.** A publication's wait widens the window in which an apply lands before its bind (`s3f.md:4769`).
- **Ruling.** A timing difference (S3-R16 item 2).
- **Evidence.** PROBE-C18C-PUBLICATION-WAIT-APPLY, seed 1_818_952, 4/4, and -HELD, 2/2. Swept first serves 48 B
  (`zStarts` 1). Visit-first serves 16 B, or 48 B too when the apply lands while O is held (ledger s3f-docs 104).
- **Field.** As §6. Either content is legal at that instant.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-30 · RR-21's residuals

- **What.** RR-21 was implemented in cycle 21 (S3-R26 item 1; S3-R27). Its residuals are timing classes only while the
  event lands between the two engines' answers (`s3f.md:6988`).
  1. A cancel or a release between the owing instant and a T21 or present pair's replay gives `.cancelled` (ruling 1).
  2. The global hold delays unrelated publications, and an apply during it can drop a held job's ids (ruling 2).
  3. A pin whose job committed, was superseded or was ENOENT-re-queued before the replay, narrowed by `PinEnd`
     (`5ad245d`, `b4eebb1`; `EngineState.swift:233`) (ruling 3).
  4. A purge's dropped bindings, an eviction or a quarantine in the window turns a present answer into a join
     (ruling 5).
  5. A heal of a T21 system item's asset in the window is forgotten. PROBE-RR21-HEAL-T21 breaks nothing.
  6. The broad idle guards keep every binding and the watcher while any event waits.
  7. Admissions and run settlement wait for every owed batch: about 20 drain turns at 10,000 ids.
  8. Each owed batch keeps its copy and layers alive (memory only).
- **Ruling.** S3-R24 item 5 (the timing class); S3-R26 item 1 (rulings 1-5); S3-R27 item 12.2
  (`docs/DECISIONS.md:613`: "RR-21 fixed except its residuals").
- **Evidence.**
  - `releaseRerouteHolds` (R12) has no figure (RES-39).
  - Item B's residuals (the per-job index from id to holders; ruling S3-R26 item 10; `s3f.md:5768-5783`; ledger
    s3f-docs 105), each with the draft's class, what would make it blocking, and its test:
    1. The earlier take-off: order and timing (S3-R16 item 2), blocking if a reader gives a different answer. B-T4
       and the reader check (`s3f.md:5740-5767`). §6's class.
    2. Q1's holder now binds A: one transport start fewer, the same answer. B-T5 pins one start in both orders.
       Not a risk: no answer changes.
    3. Variant Y's T1 half broke S3-R16 item 1 and is fixed (`2ae5a34`); its test runs in both orders. Not a risk.
    4. The index's memory and costs: about 0.5 MB a job of 10,000 ids, estimated and never measured
       (`s3f.md:5775`). A cost: blocking if a C2 case through them misses `c2Budget` at a 1-minute load of 10 or
       less (S3-R22 item 1). `indexOwnCosts` times the release, the copy and the freeing: 3.51, 4.06 and 0.78 ms
       on `82ba8a1` at loads 5.78 → 6.06 (`s3f.md:5705-5708`), and 3.26, 3.64 and 0.71 ms in Stage 5's run at
       load 3.34 (`.worktrees/merge-check/.verify-logs/benchmarks.log:316`). No figure gauges the memory.
    5. An id with many holders moves whole in one turn, O(h log h): RES-33 (PROBE-C21-HOLDERS, outside the bar).
    6. Pre-existing, and the same in both orders:
       - Moved ids leave `Job.assets` without `retireProgress`, as on the fit path (`s3f.md:5760-5762`, `:5782-5783`).
         The reader check found no different answer, stale binding or failure record (`:5764-5767`); the draft
         gives it no test and no blocking condition. By this document's reading of the code, not a run:
         `removeJob` retires only the progress keys of ids still on the job (`EngineJobs.swift:525-527`), and
         progress is offered for `job.assets.min()` on non-bulk lanes (`EngineDispatch.swift:913-915`). So a moved
         id whose progress was offered keeps its `lastEmitted` entry, any trailing emission with its flush, and any
         undelivered slot (`EngineEvents.swift:82-96`), until a later `removeJob` of a job holding it. The cost is
         a stale `transferProgress` for that id from its old job, and the entry kept.
       - An empty binding can occur on the bounded path: RR-20's family, RES-16.
- **Field.** As §6. Items 7 and 8 cost time and memory while owed batches drain. Item B's residual 4 costs about
  0.5 MB a job of 10,000 ids, by estimate; residual 6's progress gap can show a stale progress event.
- **Noticed.** As §6.
- **Re-open.** As §6.

### RES-31 · RR-22: the order bounded moves re-route in

- **What.** Bounded moves re-route by (id, token), where `move` goes by (token, id). A visit's rest moves in later turns
  (`s3f.md:4787`).
- **Ruling.** S3-R16 item 2 (order and place only).
- **Evidence.** The shared-move cases check both orders, and no answer depends on it (ledger s3f-docs 102).
- **Field.** As §6.
- **Noticed.** As §6.
- **Re-open.** As §6.

### Not residual: closed or removed RRs, and the accepted orders

| RR | State | Source |
|---|---|---|
| RR-1 | Closed in cycle 15; its remainder is not a residual (S3-R18 item 2) | `s3f.md:2924`, `:3235`; `docs/DECISIONS.md:613` |
| RR-6 | Removed in cycle 15: no place is stamped | `s3f.md:2957` |
| RR-11 | Closed in cycle 17 | `s3f.md:3768`, `:4068` |
| RR-14 | Proven, blocking, and fixed by `b9c0513` (S3-R21 item 4) | `s3f.md:4077`, `:4470` |
| RR-18 | Withdrawn in cycle 19 (S3-R22 item 2) | `s3f.md:4447` |

The accepted orders (S3-R26 item 10; ledger s3f-docs 107): newest-first joins behind a verdict; the table's order of
owed-answer resumes; item 5's order, place and ticket; RR-21's replay in (id, token) order; site 2's two orders
(PROBE-RR21-RESERVE-REJOIN); the bulk release of run claims (rr21-T18); and the take-off's land sort.

## 7. WP-F's other known risks

### RES-32 · The barrier's admission wait after a large follow

- **What.** After an apply changes about 10,000 members, the follow and its drain run in bounded turns (512 events a
  turn after the follow, `eventsAfterFollowPerTurn`, `EngineFollow.swift:173`). No place is admitted until the follow
  ends.
- **Ruling.** Accepted (S3-R11 item 4, R2; `docs/DECISIONS.md:641`).
- **Evidence.** The two figures measure different intervals (ledger s3f-items 74).
  - The ruling's figure, from D3 and the judges: 131-143 ms at 10,000 members, to the follow's end.
  - The draft's measurement: no admission for 141-149 ms after the release of a follow over 10,000 changed members
    with 10,000 waiting places (macOS release, load 7.5-8.9; `s3f.md:9477`).
  - Not measured on a device.
- **Field.** It needs a catalog change that moves about 10,000 members. A request that arrives then waits about 0.15 s
  on the host, and likely longer on a device, before it can start.
- **Noticed.** No signal. DT-PERF-05 (optional) measures it on a device.
- **Re-open.** A device figure that makes the wait visible to a user (DT-PERF-05), or a WP-F re-open.

### RES-33 · Shapes outside the C2 bar

- **What.** Two shapes the bar does not cover: more than 4 interests on one id, and a second stalled subscriber.
- **Ruling.** Outside the bar by the owner's ruling of 5 Nov (S3-R27 12.1). To "Should the 10 ms bar cover only 10,000
  assets with one subscriber?", the owner answered "Yes, keep it" (`rulings:1054`). They are recorded, neither gated
  nor blocking (`docs/DECISIONS.md:592`).
- **Evidence.**
  - More than 4 interests on one id: PROBE-C21-HOLDERS, 37.21-45.85 ms best of 3 (loads 6.92-8.33)
    (`docs/DECISIONS.md:592`; ledger s3f-docs 108).
  - Also outside, by the same ruling: its padded variants, the `manyHolders*` cases, row 14 (a purge over one id held
    by 10,000 groups, a d3 estimate, not measured), d3 §2(c) rows 1-8 with one hot id, and row 12 with k > 4 (ledger
    s3f-docs 108).
  - A second stalled subscriber (`commitTwoStalledSubscribersTurns`, "recorded, not gated"): 15.57 ms in cycle 21
    (load 7.44), 7.08 ms at the close, and 7.13 ms at the merged head (load 3.03-3.18) (`docs/DECISIONS.md:592`); in
    Stage 5's `--full`, 6.84 ms at load 3.30 (`.worktrees/merge-check/.verify-logs/benchmarks.log:329`). Its doc
    comment is `BenchSyncCycle21.swift:156-159`.
- **Field.** It needs an app that puts more than 4 interests on one id, such as several groups that hold the same
  asset, or two event subscribers that both stall. Such turns take about 40 ms on the host.
- **Noticed.** No field signal. The host benchmarks record the second-subscriber case, not gated.
- **Re-open.** The owner widening the bar. `docs/REOPEN-WP-F.md` §7 carries these shapes (`:139`).

### RES-34 · The margin list

- **What.** Four C2 cases sit above 8.5 ms at a quiet load.
- **Ruling.** "A known edge, not a regression" (`docs/DECISIONS.md:591`). A red at a load of 10 or less, in a later
  `--perf` or in Stage 5's `--full`, is a new cause and goes to the owner (`:641`, `:659`).
- **Evidence.** In ms (`docs/DECISIONS.md:591`).

  | Case | Cycle 22, the close, the verification | Merged head (all pass) | Stage 5's `--full` (all pass) |
  |---|---|---|---|
  | `commitTwoTokensTurns` | 9.02 (load 5.88); 8.95 (alone, 1.75-1.88); 9.27 (3.67) | 8.80 (load 14.35) | 8.71 (load 14.22 → 13.56) |
  | `userSharedApplyTurns(.keep)` | 9.04 (3.01-3.11); 8.50 | 8.28 (no load printed) | 8.27 (no load printed) |
  | `divergenceTurns` | 8.83; 8.35 | 7.60 (no load printed) | 7.60 (no load printed) |
  | `concentrationCommitRerouteTurns` | 8.71; 8.05 | 7.31 (load 3.28) | 7.39 (load 2.90) |

  - c23 #3 added the last three, with the reqs verifier's figures, not independently verified (`:591`).
  - The Stage 5 column is from `.worktrees/merge-check/.verify-logs/benchmarks.log:408`, `:281`, `:266` and `:248`
    (§0.4). `commitTwoTokensTurns` ran all three runs at 1-minute loads of 13.56-14.22, so its pass at 8.71 ms is
    not a quiet-load figure under the load rule (`rulings:759`, `:764`). At the merged head, too, all three ran at
    14.35. `concentrationCommitRerouteTurns` prints one load for the case. `:281` and `:266` print none. The merged
    head's loads are from `.build-orch/merge-verify-logs-e840b0e/benchmarks.log:418`, `:291`, `:276` and `:258`.
  - For `divergenceTurns` both right-hand columns give the larger of its two figures, "on to fresh contents". The
    other, "back to their own contents", was 7.53 in Stage 5's run and 7.50 at the merged head
    (`.build-orch/merge-verify-logs-e840b0e/benchmarks.log:276`).
  - This host's run-to-run spread reaches about 17 % (`:591`).
- **Field.** These turns already take 8-9.3 ms on the host. A slower device could put them over 10 ms; that is this
  document's inference, since no device figure exists.
- **Noticed.** Host benchmarks. On a device, the bench bundle (DT-PERF-01).
- **Re-open.** A red at a load of 10 or less goes to the owner (`docs/DECISIONS.md:659`).

### RES-35 · `userToBound`'s load sensitivity

- **What.** R-SYN-11 `userToBound` (`userMovedToBound`; `BenchSyncReroutePins.swift:52`, asserting at
  `BenchSyncReroutes.swift:126`) goes red on a loaded host.
- **Ruling.** A load-only figure under `rulings:763`, not a cause of the FAIL (`docs/DECISIONS.md:593`). A red at a
  load of 10 or less is a new cause, and goes to the owner (`:659`).
- **Evidence.** In ms (`docs/DECISIONS.md:593`; `docs/ORCHESTRATION.md:505-509`).
  - Merged head's `--full`: [13.84, 15.53, 13.24] at loads 14.35 → 10.54, every reading above 10.
  - Alone at 3.19 → 3.06: [4.37, 4.63, 4.63], longest held turn 1.23 ms (`.build-orch/merge-userToBound-rerun1.log`).
  - On `wp/s3f`: best 4.35 ([4.35, 12.41, 4.80]) at 10.74 → 8.26.
  - Stage 5's `--full`: passed, [4.63, 4.69, 4.64], longest held turn 1.36 ms, at loads 13.56 → 11.75, every run
    above 10 (`.worktrees/merge-check/.verify-logs/benchmarks.log:411-412`).
- **Field.** It holds about 4.4 ms at a quiet load, so no field risk is known. The risk is a red host run on a busy
  host.
- **Noticed.** Host benchmarks.
- **Re-open.** A red at a load of 10 or less.

### RES-36 · The default-tuning case (UNCONFIRMED)

- **What.** Whether item 5's `followedLane` difference arises under the default tuning. `followedLane`'s one caller
  is the throttled path (`EngineFailures.swift:349-352`; `docs/DECISIONS.md:684`).
- **Ruling.** Open (point 6, "What stays open"), UNCONFIRMED (`docs/DECISIONS.md:641`).
- **Evidence.**
  - With `shortInteractiveRetry`, a 30 s cap, a Retry-After of 60 s flips an answer.
  - The default `maxRetryAfter` is 3,600 s (`SyncTuning.swift:36`, `:45`).
  - Its probe was not run (`docs/DECISIONS.md:641`).
- **Field.** Unknown. With the test tuning, a Retry-After above the cap flips an answer. Whether any Retry-After does
  so under the default 3,600 s cap is the open question.
- **Noticed.** An answer that differs after a 429 with Retry-After during a follow. The field cannot tell.
- **Re-open.** Run the probe at a WP-F re-open (`docs/DECISIONS.md:657`). If it flips an answer, it is an S3-R16
  item 1 finding.

### RES-37 · The strict R-INT-5 path downloads before it refuses

- **What.** With `allowUnverifiedAssets = false`, a resolve of a checksum-less entry downloads the bytes, and the store
  then refuses them at publication (`AssetStore+Publish.swift:38`), with `integrityFailure`, not retried.
- **Ruling.** Observed behaviour (ARCHITECTURE §14). An engine-side refusal before the download is the orchestrator's
  decision, because it would change what a user resolve answers and when (`docs/DECISIONS.md:641`, `:656`).
- **Evidence.** The test "R-INT-5: with unverified assets disallowed a resolve of a checksum-less entry fails
  integrityFailure at publication and is not retried" (`EnginePublicationRefusalTests.swift`) pins today's behaviour
  (`docs/DECISIONS.md:656`).
- **Field.** Only for an app that disallows unverified assets and ships checksum-less entries. Each such resolve costs
  one wasted download, then `integrityFailure`.
- **Noticed.** `assetFailed` with `integrityFailure`, and `metrics()`' downloaded bytes and integrity failures.
- **Re-open.** The orchestrator's decision (`docs/DECISIONS.md:699`).

### RES-38 · WP-A's manifest parser under TSan, and the TSan guard margins

- **What.**
  - Under TSan, WP-A's parser costs about two thirds of S1-15's run test: 47-130 s for the 21 MB, 100,000-entry
    manifest.
  - 29 one-minute tests reached 50.3-55.0 % of their guard in pair2.
  - At loads 50-78, the paired bundles timed out 44 and 38 one-minute tests (ledger s3f-items 75).
- **Ruling.**
  - S3-R10: not a defect, since a release build decodes the manifest in well under a second. No WP-A change; the guard
    is 5 min (`EngineSync1LivenessTests.swift:185`).
  - S3-R12 items 2 and 4: non-blocking, and not raised (`docs/DECISIONS.md:615`, `:641`).
  - The TSan Sync bundle runs alone, or paired only at an S3-R12 rule-1 mean load of 30 or less (`:659`).
- **Evidence.** `s3f.md:9367`; `docs/DECISIONS.md:615`, `:659`. The list of 29 is in
  `.build-orchestrator/s3f-probes-c8/reqs/logs/pair2-1min-overhalf.txt`. In Stage 5's `--full`, the TSan step passed
  all 713 Sync tests in 1739.487 s (`.build-orch/stage5-full.log:67`), and S1-15's run test took 62.238 s of its
  5 min (`.worktrees/merge-check/.verify-logs/tsan.log:1967`). The log gives no load for the step (§0.4).
- **Field.** None: TSan builds only.
- **Noticed.** TSan time-outs in a host run on a busy host.
- **Re-open.** A TSan time-out at a mean load of 30 or less (S3-R12).

### RES-39 · WP-F's open mutants, unreached lines and unmeasured rows

- **What.**
  - Open mutants: r2b and b22-no-run-owner (never run); `ps-write-always`'s swept-first side (no kill);
    breakerReadLive (killed only by a time limit, which S3-R3 does not count); e1-R1's rewritten kill table and
    `i5-pin-fold`'s re-run (T-E2) (not run) (`docs/MUTATION-PROBES.md:202-206`; `docs/DECISIONS.md:684`).
    `s1-late-start` is RES-11.
  - Three unreached lines: `EngineCommands.swift:1025`, `:1028` and `:1033` (correct #6, reqs #4;
    `docs/DECISIONS.md:684`).
  - `releaseRerouteHolds` (R12) has no figure. The argument that would bound it by the jobs downloading is unfinished:
    paused jobs and the other start paths are not checked (`:674`).
  - The prune announcement at `maxEntries`, about 35 ms by estimate, is unmeasured (`:588`).
  - `waitingTarget`'s window is analysed, not reached by a test (`:674`).
- **Ruling.** Open, recorded, not blocking (point 6's records; `docs/DECISIONS.md:684`).
- **Evidence.** As cited above.
- **Field.** No direct effect. These are gaps in test strength: a regression in these branches would pass unseen.
- **Noticed.** Nothing in the field. A mutant run or a coverage report on the host.
- **Re-open.** A WP-F re-open (the dossier's final version lists them, `docs/DECISIONS.md:657`), or any change to these
  lines.

### RES-40 · S3-B-066: ENOSPC with a pending reclaim retries with no timed backoff

- **What.** ENOSPC with a pending reclaim waits `awaitingSpace` within the retry budget, with no timed backoff, so
  attempts can run back to back (S3-B-066).
- **Ruling.** An accepted deviation (L4-R26 (3)). Whether it churns needs a device test (`docs/DECISIONS.md:616`).
- **Evidence.** PROBE-C6R-1: 2 starts in 0.0 s (S3-B-066's backlog entry, `.build-orchestrator/s3-backlog.json`).
  F-27(c)'s backoff deadline was not taken.
- **Field.** On a full disk with a reclaim pending, attempts can repeat quickly until the retry budget runs out. The
  interactive policy allows 2 attempts a run (`SyncTuning.swift:44`).
- **Noticed.** DT-STO-02. In the field, `metrics()`' retries and the requests at the origin.
- **Re-open.** A device run that shows churn (DT-STO-02) re-opens F-27(c)'s backoff deadline.

### RES-41 · S3F-17's untested or unproven Sync windows

- **What.** Narrow interleavings in the Sync engine, recorded with no code (S3F-17, ADR-RECORD).

  | Item | What (backlog title, shortened) | Status at the merge (`docs/DECISIONS.md:616`) |
  |---|---|---|
  | S3-B-067 | A job that fits alone but not behind those admitted ahead stays parked until a later free-space read | Accepted |
  | S3-B-071 | Binding-ledger windows without a deterministic probe (mutants M-RESOLVEREG, M-JOIN) | Open, no seam; at most one job and one read |
  | S3-B-072 | A 404 job's waiters for an id bound during `recordFailure`'s await are answered `notFound` | Unproven |
  | S3-B-073 | A holder gained between `blobHolders` and the quarantine is neither announced nor healed | Unproven |
  | S3-B-075 | Space interleavings no test pins | No seam arms a deadline inside the read; four stay unpinned |
  | S3-B-076 | `joinGroup`'s branch for a copy that changes between two join batches | By construction, not produced |
  | S3-B-080 | Shutdown-time races | Hardened, not produced |
  | S3-B-083 | G-13's "no give-up after a running join's read" invariant | Argued, not tested |
  | S3-B-086 | L5K-R25's next-id fallback in the answer site | Recorded in ADR-055 and ARCHITECTURE §14 |
  | S3-B-087 | Engine and migration tests reach races by scheduling | Documented |

- **Ruling.** S3F-17 (`docs/DECISIONS.md:616`). S3-B-079 is RES-84; S3-B-066 is RES-40.
- **Evidence.** None reproduced. The titles are from `.build-orchestrator/s3-backlog.json`.
- **Field.** Each needs a narrow interleaving. S3-B-072 would be a wrong `notFound` if it were real. The others cost at
  most one job or one read, or are unproven.
- **Noticed.** No signal beyond the answer itself.
- **Re-open.** A reproduction, which turns the item into a finding with a failing test first (P3).

## 8. WP-B (storage core)

### RES-42 · The kill-then-power-loss crash test overruns its guard at extreme load

- **What.** "R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5"
  (`StoreCrashTests.swift:171`) overran its one-minute guard inside a full TSan Storage run at extreme load.
- **Ruling.** S3-R4. The condition for raising the guard (over half the limit under TSan at a load of about 30) is not
  met, so it stays at one minute (`docs/DECISIONS.md:621`; `s3b.md:205-239`).
- **Evidence.**
  - S3B-7 memoized the reopen per distinct surviving disk, with no pair, point, mode, slice or assertion cut.
  - TSan, the test alone: 6.295 s and 9.178 s after the memo (18.202 s and 11.138 s before).
  - In the verifier's full TSan Storage run at load 277 → 628, all 8 cases overran, with 62 follow-on `.cancelled`
    issues (`docs/DECISIONS.md:621`; ledger s3b 36).
  - In the same overloaded runs, WP-B's `IndexCommitStateSpaceTests` and WP-H's `start racing stop` also hit their
    limits (`s3c.md:689-700`).
- **Field.** None: a test robustness risk on overloaded hosts.
- **Noticed.** A time-out in a TSan host run.
- **Re-open.** A time-out at a load of about 30 or less (S3-R4).

### RES-43 · `killThenPowerLoss` keeps recording after its time limit

- **What.** WP-B's `killThenPowerLoss` catch records every error, `.cancelled` included, and its loop goes on
  (`StoreCrashTests.swift:113-116`).
- **Ruling.** Non-blocking, routed to WP-B (S3-R8). The fix: rethrow on `.cancelled` or when `Task.isCancelled`
  holds, or check cancellation per pair (`docs/DECISIONS.md:647`; ledger s3c 64).
- **Evidence.** 1,961, 2,118 and 350 `.cancelled` issues in three overloaded TSan runs: the correctness lens's
  (`s3c.md:87`, `:90-93`), then the draft's second and third, at 1-minute loads up to 602 and 465 (`:686-692`,
  `:695-700`).
- **Field.** None: it floods a failed run's log with follow-on issues.
- **Noticed.** Hundreds of `.cancelled` issues after a time-out.
- **Re-open.** WP-B's next round (`docs/DECISIONS.md:647`).

### RES-44 · S3B-13: user-initiated publications are quadratic

- **What.** The present table is shared copy-on-write with `SnapshotMirror.current`, so `refreshPresentEntry` copies
  the whole table on the actor at each user-initiated publication (`s3b.md:390-405`).
- **Ruling.** S3B-13 [ADR-RECORD], no fix. The bounded designs change the contract file `Snapshot/AssetSnapshot.swift`
  and the install path, which S3-R6 did not authorise. Deferred to Stage 5 with the owner's P-8 run
  (`docs/DECISIONS.md:621`, `:647`).
- **Evidence.** Release timings at 2,500, 5,000 and 10,000 publications (ledger s3b 37).
  - The hunter, at load 12 and rising: 1.32, 3.94 and 10.67 s (10k/5k ratio 2.71).
  - The confirmer, at load 64-70: 0.51, 1.72 and 4.92 s (ratio 2.86).
  - Bulk: 1.06, 2.16 and 2.32 s. A control sink that does not retain the snapshot: 0.42, 1.07 and 2.14 s (ratio
    2.00).
  - Each publication costs about 0.5-1 ms at 10,000 entries: inside C2, and no SPEC §6 budget applies.
- **Field.** It needs thousands of user-initiated downloads in one session over a large catalog. The total time grows
  with the square of the count; each turn stays inside C2.
- **Noticed.** DT-PERF-04 on a device. No field signal.
- **Re-open.** The owner's P-8 run, or a contract round that allows the bounded designs.

### RES-45 · S3-B-011: actor stretches at `maxEntries` (100,000)

- **What.** At 100,000 assets, several store operations hold the actor longer than 10 ms. C2 is judged at 10,000.
- **Ruling.** S3B-14 with S3-R5: C2 is judged at the reference scale of 10,000. The optional chunked `startGrace` was
  not done; it is left for Stage 5 (`docs/DECISIONS.md:621`, `:647`).
- **Evidence.** Release, `d66eb2f`, load 8.9 → 5.7, thread CPU, worst of runs (`docs/DECISIONS.md:621`; ledger s3b
  38).
  - WP-B: grace start over every doomed key 37.31 ms; the reaper queue's filter and sort 22.84 ms
    (`AssetStore+Reaper.swift:160`); `freeSpace()` 4.19 ms; the first present-table copy 3.33 ms; the first records
    copy under a live snapshot 9.34 ms.
  - WP-C: quota eviction of half 21.98 ms; `purge(.all)` 35.83 ms; `purge(.evictable)` 34.02 ms; orphan GC of
    100,000 orphans 18.43 ms.
  - At 10,000, every hold is under 3.2 ms, and every C2 assertion passed.
- **Field.** Only for catalogs near `maxEntries`. Such catalogs get store turns of 18-37 ms on the host.
- **Noticed.** No field signal (S1 covers the engine's purge only).
- **Re-open.** An app whose catalog approaches 100,000 entries, or a ruling that extends C2 beyond 10,000.

### RES-46 · OI-15: an evicted record whose content is live elsewhere is downloaded again

- **What.** One redundant download per evicted record whose new content is already live in another blob. It is never
  a correctness bug (probes ZP7-OI1b, ZP8-OI15) (`s3b.md:344-356`). `adoptKnownBlob` refuses `absent(.evicted)`
  (`AssetStore+Apply.swift:321`).
- **Ruling.** S3B-11: ruling R3 stands for apply and admit. The change request for WP-F, a WP-B package primitive
  `bindToLiveContent(_ id:) async throws -> AssetLocation?`, is pending the orchestrator (`docs/DECISIONS.md:605`).
- **Evidence.** The two probes. No figures.
- **Field.** Wasted bandwidth and disk churn after evictions, for content shared between records.
- **Noticed.** `metrics()`' downloaded bytes and asset requests.
- **Re-open.** The orchestrator's ruling on the CCR (`docs/DECISIONS.md:699`).

### RES-47 · OI-12: orphan GC on a busy store

- **What.** Orphan GC's reap window is per run, and it can close on every run on a busy store
  (`OrphanCollection.swift:106-109`). Orphans are then never collected (`s3b.md:334-342`).
- **Ruling.** S3B-10, recorded. The CCR for WP-C, a `StoreCoreState.reapedSince` ring and an internal
  `doomOrphans(_:learntBefore:)`, is pending (`docs/DECISIONS.md:605`).
- **Evidence.** None measured. Each occurrence is logged at `.info` (`docs/DECISIONS.md:605`).
- **Field.** Liveness only: orphaned bytes stay on disk while the store stays busy.
- **Noticed.** One `.info` log line per occurrence, if the app collects `.info` lines; and `storageReport()`.
- **Re-open.** The orchestrator's ruling on the CCR.

### RES-48 · Dooms WP-C counted are not taken back

- **What.** A doom that WP-C counted in `releasedBytes` is not taken back when a publication rescues it. That covers
  quota eviction, purge and quarantine, and a purged or corrupt doom that a verified publication replaces. A second
  eviction run that measured earlier can then stop short of its target by that blob's bytes, an R-CLN-4
  under-eviction (`s3b.md:561-565`).
- **Ruling.** S3-R8, other-wp:c, with the CCR from S3B-9 cycle 2: count through `countRelease(of:bytes:)`
  (`docs/DECISIONS.md:605`).
- **Evidence.** Not exercised; no figures. The direct adds are at `QuotaEviction.swift:326` and `:376`,
  `StorePurge.swift:148` and `:188`, and `IntegrityBookkeeping.swift:75`. `.replaced` takes nothing back
  (`AssetStore+References.swift:163-170`) (`docs/DECISIONS.md:605`).
- **Field.** An eviction can free up to one blob's bytes less than its target. The next eviction run corrects it.
- **Noticed.** `storageReport()` over its quota after an eviction, by a blob.
- **Re-open.** The orchestrator's ruling on the CCR.

### RES-49 · S3-B-015: `pendingReclaim` with no deadline (not reproduced)

- **What.** F-25 once saw a doomed key counted in `pendingReclaim` with no deadline scheduled (`s3b.md:423-433`).
- **Ruling.** S3B-14. The engine's fresh read stays (`docs/DECISIONS.md:621`, `:671`).
- **Evidence.** A probe, not committed, made the commit of an apply that prunes a 300-byte blob fail four ways (EIO on
  the index.tmp rename, ENOSPC on its write, EIO on the root sync, EIO on the file sync). `pendingReclaim` was 300,
  but `nextDeadline()` was never nil. The documented no-deadline states are: unavailable (B-15), degraded (S1-11),
  leased, and acknowledgement-blocked after an unacknowledged install (S1-13). F-25's single sighting fits the last
  (ledger s3b 42).
- **Field.** If real, reclaimable bytes would wait for the next commit or acknowledgement.
- **Noticed.** `storageReport()`'s pending reclaim staying up.
- **Re-open.** A reproduction.

### RES-50 · S3-B-016: reference gains copy the blob table in unoptimised builds

- **What.** Debug and TSan builds copy the whole blob table on each in-place reference gain; release builds do not
  (`s3b.md:434-439`).
- **Ruling.** S3B-14, pinned by the C2 benchmark (`docs/DECISIONS.md:621`).
- **Evidence.** In release, 1,000 in-place gains take 0.081 ms at 10,000 blobs and 0.103 ms at 100,000
  (`docs/DECISIONS.md:585`).
- **Field.** None in release builds.
- **Noticed.** Slow debug or TSan runs at large scale only.
- **Re-open.** A release figure that grows with the table.

### RES-51 · `reapScaling` under load

- **What.** The reaper benchmark's 40k/20k ratio alone is noise-prone under load (`s3b.md:160-186`).
- **Ruling.** S3-R5: a miss caused only by load is not blocking. The deterministic `reaperWorkListIsLinear` carries
  the guarantee (`docs/DECISIONS.md:585`, `:621`).
- **Evidence.** Times at 10,000 / 20,000 / 40,000 keys (`docs/DECISIONS.md:585`).
  - `s3-base`, one run, load 27.9 → 42.1: 0.911 / 2.033 / 2.966 s.
  - `d66eb2f`, load 8.9 → 5.7: 0.161 / 0.324 / 0.648 s, ratio 2.00.
  - The gates run on `a5edd1e`, load 49 → 8.7: ratio 2.007 against 2.5, and 40,000 against its control 1.036 against
    1.5. `s3-base`'s reaper spliced in fails both (3.018 and 3.131).
  - Its two bounds are local to the benchmark (`BenchStorage.swift:262-301`).
- **Field.** None.
- **Noticed.** A red benchmark on a loaded host.
- **Re-open.** A red at a quiet load, or a failing `reaperWorkListIsLinear`.

### RES-52 · `recordFailure` commits the whole index per call

- **What.** `AssetStore.recordFailure` commits the whole index once per call, so a burst of N 404s rewrites it N times.
- **Ruling.** Routed to WP-B (other-wp:b; `docs/DECISIONS.md:647`, `:654`).
- **Evidence.** About 5 ms per commit at 10,000 records in release (`docs/DECISIONS.md:654`).
- **Field.** A catalog published with many missing files (a burst of 404s) costs about 5 ms of store time and one
  index write per 404.
- **Noticed.** `metrics()`' `notFound` failures, alongside the store's commit work.
- **Re-open.** WP-B's next round.

## 9. WP-C (eviction, cleanup, legacy migration)

### RES-53 · The legacy kill-then-power-loss pairs under TSan

- **What.** The legacy pairs (`CrashPairTests.swift:40-45`, one-minute guard) can exceed the guard under TSan at high
  load.
- **Ruling.** S3-R4: load misses outside the envelope of about 30. No guard raised, nothing cut (G3)
  (`docs/DECISIONS.md:622`). Stage 5 runs `--full`'s TSan on a quiet host. If the pairs meet their guard at a load of
  at most about 30, raise it to three minutes with the measured durations, or raise `legacySlices`, keeping every pair
  (`:650`).
- **Evidence.**
  - The heaviest case, `.powerLossDropUnsynced` slice 0, has 143 pairs against 90.7 on average.
  - Overruns: at loads 18 → 180 and 100-296, and in 7 cases at loads up to 602.
  - Passing runs: 4.9-7.8 s per case at loads up to 12, and through a spike of 465 (`docs/DECISIONS.md:622`; ledger
    s3c 61).
  - Stage 5's `--full` TSan step passed all 500 Storage tests in 641.418 s (`.build-orch/stage5-full.log:68`).
    `legacyKillThenPowerLoss`'s 128 cases (2 modes × 64 slices, `CrashPairTests.swift:18`, `:44`), run in series,
    passed in 641.410 s, about 5.0 s a case (derived). The log gives no per-case duration
    (`.worktrees/merge-check/.verify-logs/tsan.log:5830`). The run's load is known only at its start and end, 4.11
    and 7.77, not during the step (§0.4).
- **Field.** None: TSan only.
- **Noticed.** TSan time-outs on a loaded host.
- **Re-open.** Stage 5's quiet-host TSan figures (`docs/DECISIONS.md:650`). Stage 5's run passed, but its log does
  not show the load during the TSan step. The step `:650` names is the orchestrator's.

### RES-54 · `purge(.evictable)`'s worst of three over one shared blob

- **What.** The worst run of three exceeded 10 ms for `purge(.evictable)` of one blob that every id shares. The
  asserted figure is the best of three (`BenchCleanup.swift:121-124`).
- **Ruling.** S3-R5: a miss caused only by load is not blocking (`docs/DECISIONS.md:622`).
- **Evidence.** 17.91525 ms in cycle 1 (best 3.559292 ms, load 7.95 → 15.12), 4.819208 ms in cycle 2, and 11.047209
  ms at the merged head (best 4.733625 ms) (`docs/DECISIONS.md:586`; `s3c.md:231-234`).
- **Field.** The best case holds the actor about 4.7 ms. A loaded device may see the worst case.
- **Noticed.** No field signal.
- **Re-open.** A best of three above 10 ms at a quiet load.

### RES-55 · `apply`'s hook takes a blob of 10,000 holders in one turn

- **What.** `apply`'s eviction hook still takes a blob of 10,000 holders in one turn (`ApplyPlan.swift:84-130`).
- **Ruling.** S3-R8: non-blocking, routed to WP-B. S3-R6 and S3-R7 gave no authorisation for WP-B's files
  (`docs/DECISIONS.md:622`, `:647`).
- **Evidence.** 15.4-16.6 ms of thread CPU for the eviction and 13.4 ms for the purge at Level 3. ADR-052 recorded
  16.2 ms, over 10 ms above about 6,000-6,500 holders. Not re-measured (`docs/DECISIONS.md:622`; ledger s3c 63).
- **Field.** It needs an apply that evicts or purges a blob shared by more than about 6,000 ids, such as one
  placeholder file referenced by most of a catalog. Such a turn holds the store's actor for about 16 ms.
- **Noticed.** No field signal.
- **Re-open.** WP-B's next round: a chunk cutter that splits a large blob's run across chunks, with a hook that
  accepts a continuing run (`docs/DECISIONS.md:647`).

### RES-56 · The synchronous dry run at 100,000 (OI-4)

- **What.** `evictionPlan(toFree:protecting:)` holds the actor while it plans.
- **Ruling.** S3C-11: within C2 at the reference scale. The async contract change (S3-B-026) was declined for Stage 3
  (`docs/DECISIONS.md:622`, `:649`).
- **Evidence.** At the merged head: 2.555833 ms (worst 2.628542) at 10,000 records, and 38.887042 ms (worst
  40.715375) at 100,000 (`docs/DECISIONS.md:586`).
- **Field.** Only for catalogs near 100,000 entries.
- **Noticed.** No field signal.
- **Re-open.** The contract change S3-B-026, an async `evictionPlan` (with WP-F; `docs/DECISIONS.md:649`).

### RES-57 · Phase 3 can stay undecided under continuous access stamps

- **What.** Legacy migration's phase 3 can end every call with `finished: false` while access stamps keep coming
  (`LegacyPhases.swift:537-538`, `legacyCheckPasses = 3`).
- **Ruling.** S3C-11, RE-S29 and ruling R9: the caller retries later (`docs/DECISIONS.md:622`).
- **Evidence.** At the merged head: 16,618, 16,648 and 17,943 stamps at 10,000 files, and 16,042 at 100,000, all
  unfinished (`docs/DECISIONS.md:586`).
- **Field.** An app that migrates from the prior art while it keeps reading assets may finish migration later.
- **Noticed.** `migrateLegacy`'s result, `finished: false`.
- **Re-open.** The contract change S3-B-027: a WP-B `CommitBookkeeping` field (`docs/DECISIONS.md:649`).

### RES-58 · A blob can end up split (Decision S3C-2)

- **What.** When a check fails between the turns of one blob of more records than a chunk (1,000), the records already
  taken stay evicted or purged, and the blob stays live with the rest (`docs/DECISIONS.md:606`).
- **Ruling.** Decision S3C-2, ratified (`docs/DECISIONS.md:606`).
- **Evidence.** By design. The split blob's records are downloaded again on demand and dedupe onto the live blob, with
  no new bytes on disk (`docs/DECISIONS.md:606`, `:622`).
- **Field.** Extra downloads for the split blob's evicted records, only after such a check fails.
- **Noticed.** `metrics()`' downloaded bytes.
- **Re-open.** A field report of repeated downloads for shared blobs.

### RES-59 · An across-turns turn costs O(ids left), unmeasured at `maxEntries`

- **What.** Each across-turns eviction or purge turn costs O(ids left), and the first turn checks every victim
  (`s3c.md:259-261`).
- **Ruling.** S3-R5: C2 is judged at 10,000; no ruling covers it beyond (`docs/DECISIONS.md:622`).
- **Evidence.** Unmeasured for one blob held by 100,000 ids. Its first turn would read about 10 times the records of
  the measured 4.3-4.7 ms case, so it could exceed 10 ms (derived; ledger s3c 68).
- **Field.** Only for a blob held by about 100,000 ids.
- **Noticed.** No field signal.
- **Re-open.** A measurement at `maxEntries`, or a ruling that extends C2.

### RES-60 · Mutants C, F and S are masked in WP-C's oracle, and F and S in its flows

- **What.** Of the runs on record, only WP-B's targeted tests kill C, F and S (`s3c.md:491-497`); in the crash hunter's run C also fails EvictionTests' R-SYN-11 case (`.build-orchestrator/s3-probes/crash/S3-CRAS-05-mutants-run.txt:63-67`).
  - C: masked in WP-C's oracle (oracle-C passed, `.build-s3c/mut/results.txt`); no flows run against C is on record
    (`.build-s3c/mut/run-mutants.sh:35`).
  - F and S: masked in both (oracle-F/S and flows-F/S passed).
- **Ruling.** S3C-6, which requires only Z (`docs/DECISIONS.md:622`).
- **Evidence.** The confirmer's runs. The oracle's step runner has no commit-fault injection (ledger s3c 69).
- **Field.** None directly: a regression of that kind would rest on WP-B's tests alone.
- **Noticed.** WP-B's targeted tests.
- **Re-open.** Commit faults inside the oracle's sequences (WP-C, not ruled; `docs/DECISIONS.md:649`).

### RES-61 · About 400 direct joins fall outside S3C-5

- **What.** About 400 direct `.task.value` and `.result` joins in `Tests/` fall outside S3C-5. A lost resume there
  would hang until the run's time limit, instead of failing at the poll (`s3c.md:324-325`).
- **Ruling.** S3C-5 covered `LegacyOnDemandRaceTests` only (`docs/DECISIONS.md:622`).
- **Evidence.** The draft's count, not recounted (ledger s3c 70).
- **Field.** None: test robustness.
- **Noticed.** A hung test run.
- **Re-open.** The test-practice rule: join through a handler that cancels the task (`docs/DECISIONS.md:651`).

## 10. WP-D (transport and background sessions)

### RES-62 · The FIFO test alone catches MG only some of the time

- **What.** `handleControlsInOrder` (`BackgroundInterleavingTests.swift:400`) catches MG, a `Task` per priority change
  inside the control task's loop, only in some runs.
- **Ruling.** The draft's decision, "not fully deterministic, by nature": a test cannot await a task that ordered
  delivery never starts. S3-R3 holds, since the suite kills the mutant (`docs/DECISIONS.md:623`; `s3d.md:205-219`).
- **Evidence.** 2 of 6 runs before `defc67e`. After it: 10 of 10 (load 1.3-10.7), 5 of 10 (load about 194), 6 of 6
  (3.3-20.8), 1 of 5 (129-394) and 4 of 5 (3.5-66.4). Whole-suite runs kill MG every time, through
  `replacedAttachWriteLandsLast`, `lateWriteAfterTheTerminal` and `rewriteLandsLast` (ledger s3d 39).
- **Field.** None directly. It is the strength of one test of priority-change order.
- **Noticed.** Whole-suite host runs.
- **Re-open.** A whole-suite run that misses MG.

### RES-63 · The OI-10 class outside Transport

- **What.** WP-F's `EngineLiveTransportTests` use loopback rigs with `requestTimeout: 10`
  (`EngineLiveTransportTests.swift:17-18`) and responses that stall until the test acts. A host that delays that
  action by more than 10 s turns the stall into `transient(.timedOut)`. Inside Transport, the three kept-short tests
  (10 s) and `connectionReuse` (50 s) can still time out under extreme load: a false failure, never a false pass.
- **Ruling.** S3-R8: other-wp:f, non-blocking (`docs/DECISIONS.md:623`). S3D-5 settles OI-10 for Transport (`:610`).
- **Evidence.** In OI-10, 191 of 500 transfers timed out at load 110-327. S3-B-055's two tests failed at loads up to
  468.9 (ledger s3d 40). WP-B's cycle 2 saw WP-D's loopback tests time out on the simulator under host load
  (`docs/DECISIONS.md:648`).
- **Field.** None: tests only.
- **Noticed.** Time-outs on a loaded host.
- **Re-open.** A time-out at a quiet load.

### RES-64 · Plain `await task.value` joins in new tests

- **What.** Several new tests join a task with a plain `await task.value`, which ignores cancellation:
  `BackgroundInterleavingTests` :359, :382, :551; `BackgroundCoordinatorTests` :655; `BackgroundControlTaskTests` :49,
  :101; `ForegroundBackendTests` :274. If a regression leaves such a task unfinished, the run is held past
  `.timeLimit`.
- **Ruling.** S3-R4 is not violated: it requires `.minutes(1)`. The draft's "the same cancellable way" holds for the
  control-task joins only; `staleRequestNeverSupersedes` joins `current` plainly (`docs/DECISIONS.md:623`).
- **Evidence.** Cycle 1's hang was stopped by hand at 9 min. With a handler that cancels the join, cycle 1's hanging
  mutant run ended on its own in 130 s (`docs/DECISIONS.md:651`; ledger s3d 41).
- **Field.** None: tests only.
- **Noticed.** A host run that does not end.
- **Re-open.** The test-practice rule: join through a handler that cancels the task (`docs/DECISIONS.md:651`).

### RES-65 · R-NET-3's run-time half stays undetected

- **What.** An app can attest `BackgroundTransferPolicy.enabled` without wiring the background-events hook. The tests
  cover the attestation half only (`CompositionTests.swift:39-46`). `hasHandler` exists
  (`BackgroundSupport.swift:838-841`), but nothing uses it to detect the missing hook at run time.
- **Ruling.** S3D-6 (record only) and L5-R5: an accepted deviation, device-only. CCR-G1 was declined
  (`docs/DECISIONS.md:623`; ledger s3d 42).
- **Evidence.** No device run.
- **Field.** It needs an app that attests the policy but does not forward the hook. The OS's background-events wake
  then reaches no handler. What happens to the finished transfers is what DT-BG-03 observes.
- **Noticed.** DT-BG-03. No field signal.
- **Re-open.** A detection that cannot misfire on an early finish (ledger s3d 42).

### RES-66 · D-17.5, D-17.6 and D-18.3 stay declined (S3-B-056)

- **What.**
  - D-17.5: a join does not apply the joining job's lane priority to the live task (`BackgroundSupport.swift:269-274`
    attaches without a priority write).
  - D-17.6: "without polling" is not proven inside the conditions test.
  - D-18.3: the failure of a direct start of an unbounded job is unchanged.
- **Ruling.** S3D-6 and S3-R8: pre-existing behaviour that a recorded decision accepts. S3D-1 keeps D-17.5's premise
  (`docs/DECISIONS.md:610`; ledger s3d 43).
- **Evidence.** By reading.
- **Field.** A user request that joins a running background download keeps the download's creation priority, so the
  OS may schedule it lower than the request would warrant. The cost is latency.
- **Noticed.** DT-BG-08 observes the priority writes that do happen.
- **Re-open.** A later contract round.

### RES-67 · The oldest-first argument inherits `unclaimedFinishes`

- **What.** `awaitBackgroundEvents()` returns at once when a finish arrived before anybody waited
  (`BackgroundSupport.swift:418-421`; counted at `:627-629`). A buffered earlier finish therefore satisfies the next
  wait without a new wake, and S3D-2's oldest-first argument inherits this.
- **Ruling.** S3-R8: pre-existing behaviour that a recorded ruling accepts (ADR-054). L5-R5 calls it "a race WP-D
  tolerates" (`docs/DECISIONS.md:623`).
- **Evidence.** By reading. The trigger is device-only (ledger s3d 44).
- **Field.** If UIKit delivers two background-events wakes close together, a completion handler can be called before
  its own wake's events are staged.
- **Noticed.** DT-BG-02, which also asks whether UIKit hands a second handler for one identifier while the first
  waits (`docs/DECISIONS.md:673`).
- **Re-open.** DT-BG-02 showing a second handler, or events handled after their completion was called.

### RES-68 · Stage 2's mutant ME survives (device-only)

- **What.** Mutant ME, in the live driver's `resumeData` use (`BackgroundSessionBackend.swift:58-60`), survives. The
  file is coverage-excluded and runs only on a device (S3-B-050; `docs/MUTATION-PROBES.md:230`).
- **Ruling.** Not verified, device-only (`docs/DECISIONS.md:673`).
- **Evidence.** `docs/MUTATION-PROBES.md` §6.3.
- **Field.** A regression in the live resume path would be unseen until a device run.
- **Noticed.** DT-BG-04.
- **Re-open.** DT-BG-04.

### Not open: WP-D's known misses closed in the cycles

| Known miss | Closed by | Source |
|---|---|---|
| Cycle 1's premise that two writes for one name overlap only for overlapping callers | failing test `c1395d3`, fix `a51f37f` | `docs/DECISIONS.md:623`; `s3d.md:127-161` |
| Cycle 2's surviving R1J (MI) and R1K | killed by `2528a8c` | `s3d.md:170-204` |
| Cycle 1's S2-19 test raced its own trigger | `22d1e78` | `s3d.md:332-352` |
| The unpinned `deinit` (MK); MG caught 2 of 6 in cycle 2; `exceedsByteSize` missing from S3D-5's list | `95bb342`; `defc67e`; cycle 3 | `s3d.md:17-23` |
| The lost cycle-1 verification report (process) | the close-out script retries a verifier that returns no result twice, and ends a cycle missing a lens | `docs/DECISIONS.md:569`; `s3d.md:9-15` |

## 11. WP-G (the facade)

### RES-69 · S3-B-094: a replaced root is used until a failure or a commit detects it

- **What.**
  - A replaced root that no commit has detected is used until a qualifying failure or a commit.
  - A root check whose stat fails records nothing.
  - `withAsset` can lease from a root that vanished after its read.
- **Ruling.** S3G-5: an accepted deviation under L5-R4 and L5-R20 (ADR-054; `docs/DECISIONS.md:603`, `:620`).
- **Evidence.** The cost is one `lstat` per qualifying failure, and none per success (`docs/DECISIONS.md:620`). The
  check sits at `AssetClient.swift:117` and `:126-127`, and `AssetStore.verifyRootNow()` (`AssetStore.swift:119`).
- **Field.** After the OS purges a `.caches` root or the root is replaced, reads can fail until the kit detects it.
- **Noticed.** DT-STO-04. In the field, the `store` category's root-check line (`docs/DEVICE-TEST-PLAN.md` §3.4).
- **Re-open.** DT-STO-04 showing a read served from a vanished root.

### RES-70 · K-11: `fetch` downloads an entry of another kind before refusing it

- **What.** `AssetFallbackChain.fetch` and the shim `resolveViaNetwork` download an entry of another kind at
  `.userInitiated`, which preempts prefetch, and store it before throwing `notFound` or returning nil
  (`FallbackChain.swift:135-144`). The prior art checked the kind before downloading.
- **Ruling.** S3G-4: S3-CONF-07 refuted as a defect (K-11, accepted by ADR-055). It is owner information: a candidate
  for a tag the orchestrator did not add (`docs/DECISIONS.md:603`, `:699`). The tag's wording disagrees between
  `docs/DECISIONS.md:246`, `:603` and `:699` (`docs/ORCHESTRATION.md:571`).
- **Evidence.** The hunter's probe failed 5 of 5 on `s3-base` (an `.mp4` of 300 bytes downloaded at `userInitiated`
  for an image request). The confirmer reproduced it 6 of 6 (ledger s3g 33). `fetch("clip", kind: .image)` downloads
  a whole `.mp4`, stores it and throws `notFound` (`docs/DECISIONS.md:603`).
- **Field.** It needs a catalog entry whose kind does not match the page. The confirmer called the impact small: one
  wasted user-priority download, which preempts prefetch meanwhile.
- **Noticed.** `metrics()`' downloaded bytes, and the `notFound` answer.
- **Re-open.** The orchestrator's decision on the tag candidate (`docs/DECISIONS.md:699`).

### RES-71 · S3-B-093: P-9 at 100,000 entries is unmeasured

- **What.** P-9's sliced release survey at 100,000 manifest entries was never written. The only P-9 case is the
  64-resolve heartbeat (`BenchKit.swift:283-284`).
- **Ruling.** S3G-5: optional, not done (`docs/DECISIONS.md:603`); ADR-057 records it as a known miss (`:620`);
  deferred since ADR-050 (`:374`).
- **Evidence.** The measured case: p99 19.667 ms over 870 heartbeat gaps, against a 50 ms budget
  (`docs/DECISIONS.md:584`).
- **Field.** Unknown at 100,000 entries.
- **Noticed.** Nothing until the case exists.
- **Re-open.** WP-G's later round (`docs/DECISIONS.md:645`).

### RES-72 · S3-B-095 and S3-B-097: untested or unproven facade interleavings

- **What.**
  - S3-B-095: the background-events hand-off, the diagnostic report's three reads, and a stream registration that
    overlaps the client's shutdown are untested interleavings.
  - S3-B-097: R-CAR-5's lost update was never reproduced.
- **Ruling.** S3G-5. By L5-R9, no seam point is added without a bug proven there. G-3's record-first order removes
  S3-B-097's window by construction (`docs/DECISIONS.md:603`).
- **Evidence.** None. Both rest on reading only (`docs/DECISIONS.md:670`).
- **Field.** Narrow interleavings at reopen and shutdown. Unknown.
- **Noticed.** No signal.
- **Re-open.** A reproduction.

### RES-73 · The event model's limits (a′) and (a″)

- **What.** Two measurement limits of the event continuity model.
- **Ruling.** S3G-2 and L5-R22 (2): limits of the model, not product promises (`docs/DECISIONS.md:603`, `:670`).
- **Evidence.**
  - 35 registrations over the 500 suite seeds owe the registration engine's `clientStarted` (27 created, 8
    starting).
  - 5,000 seeds took 20.2 s at a load of about 30. MT1 and MT2 fail 10 of 10, and MC00 is still caught 10 of 10
    (ledger s3g 36).
  - They were measured on `wp/s3g`, before WP-F's merge changed `SubscriberQueue.swift`, `EngineEvents.swift` and
    `EngineLifecycle.swift`, and were not re-run on the merged head (`docs/DECISIONS.md:670`).
- **Field.** The event stream promises what its documentation says. The model does not check beyond that.
- **Noticed.** No signal.
- **Re-open.** A change to the event stream, or a re-run on the merged head.

### RES-74 · `AssetClient.swift:142` stays schedule-dependent

- **What.** `perform`'s repetition after a retired engine (`AssetClient.swift:138-142`) is reached only by some
  schedules.
- **Ruling.** Recorded in ARCHITECTURE §14 (ADR-054; `docs/DECISIONS.md:620`).
- **Evidence.** Its count is 0 in s3g's run and in the merged head's `--full` profile (`docs/DECISIONS.md:620`).
- **Field.** An untested retry path after a reopen.
- **Noticed.** A coverage report.
- **Re-open.** A seam or a test that reaches it.

Not a risk: S3G-1's leftover. The walk is clamped, and `prefetchRadius` and `init(radius:)` stay unclamped by decision,
since after the clamp any value is safe. Before the fix, the median was 11.058 ms at radius 10,000,000, against P-8's
1.0 ms; after it, 0.007 ms (`docs/DECISIONS.md:584`, `:603`).

## 12. WP-A and WP-H (manifest, model and test support)

### RES-75 · `start racing stop` stays load-sensitive

- **What.** "Test support: start racing stop ends every start exactly once, with a port or stopped, and never hangs"
  (`LoopbackHTTPServerTests.swift:404`). Its 79,800 yields queue behind every other cooperative-pool job, so its
  duration grows with load (ledger s3ah 37).
- **Ruling.** S3AH-5 (S3-R4): the guard is `.minutes(3)` (`docs/DECISIONS.md:599`). ADR-055's L5K-R25: non-blocking
  when it passes at moderate load.
- **Evidence.** About 0.25 s alone; 12.5-13.0 s in whole-target debug runs; 30-44.8 s under TSan at loads of about
  3-21; over 64.8 s at load 168.9-223. Nothing shows that three minutes suffices at ADR-055's loads of 441-834
  (`docs/DECISIONS.md:619`).
- **Field.** None: test support.
- **Noticed.** A TSan time-out on a loaded host.
- **Re-open.** A time-out at moderate load.

### RES-76 · The linear-time check is still a CPU-time ratio

- **What.** The seeded fuzz test's linear-time check compares CPU-time samples (`ManifestFuzzTests.swift:276-294`). A
  sample on an efficiency core costs more than one on a performance core.
- **Ruling.** S3AH-4: OI-13 closed with the lowest of three samples per side. The 64x bound is not loosened, and a QoS
  pin was rejected (`docs/DECISIONS.md:598`, `:619`).
- **Evidence.** Measured ratios are about 31-34x against 64x, roughly 2x headroom. The original failure was about 66x
  (6.08 s against 5.86 s) (`docs/DECISIONS.md:619`; ledger s3ah 38).
- **Field.** None: test only.
- **Noticed.** A red test.
- **Re-open.** A failure with all three limit-side samples on slow cores.

### RES-77 · Paths that rely on empty or `.` segments, trailing slashes or backslashes

- **What.** The prior art fetched paths such as `a//b.png` through `appendingPathComponent`. Since D-6 the transport
  refuses such paths on every fetch (`failed(.nextRun)`; waiters answered `.serverUnavailable`), and since S3AH-1 the
  decoder quarantines them with a diagnostic (ledger s3ah 39).
- **Ruling.** Owner information, not a tag (`docs/DECISIONS.md:619`).
- **Evidence.** No valid shipped fixture has such a path: of the 195 `remotePath`s under `Tests/Fixtures`, only the
  two invalid fixtures contain empty segments (ledger s3ah 39).
- **Field.** Only a published manifest with such paths. Those assets would never load.
- **Noticed.** The decoder's diagnostic, and `.serverUnavailable` answers.
- **Re-open.** A published manifest with such paths: the owner's check.

### RES-78 · OI-8: the allocation tests read process-wide heap figures

- **What.** The allocation tests read process-wide heap figures, and rely on Array and Dictionary layout and on
  `malloc_size` of reused blocks.
- **Ruling.** Kept, no change (OI-8, ADR-052; S3AH-6; `docs/DECISIONS.md:619`).
- **Evidence.** Checked on macOS 27 and the iOS 27 simulator only (ledger s3ah 35). R-MAN-3's allocation bound on a
  device's allocator is unverified (S3-B-004; `docs/DECISIONS.md:644`, `:669`).
- **Field.** Unknown on a device's allocator.
- **Noticed.** DT-MEM-03.
- **Re-open.** A new OS or toolchain on which the tests fail, or a DT-MEM-03 figure over the bound.

### RES-79 · Entry-dense manifests over 2 MiB are rejected (S3-B-003)

- **What.** A manifest whose entry array exceeds 2 MiB at about 111 bytes per entry is rejected with
  `decodedSizeExceeded` by the 3.75x build-pass allocation bound (the survey pass's bound is 2.3x).
- **Ruling.** Accepted, no change (S3AH-6; ADR-049; `docs/DECISIONS.md:602`).
- **Evidence.** Realistic catalogs, at 250-350 bytes per entry, are unaffected (`docs/DECISIONS.md:602`).
- **Field.** Only catalogs of unusually short entries whose entry array exceeds 2 MiB.
- **Noticed.** The manifest fetch fails with `decodedSizeExceeded`.
- **Re-open.** A real catalog that hits it.

### RES-80 · The fakes' fidelity limits (S3-B-106)

- **What.** `FakeTransferBackend` retains every handle, so drop-to-cancel is observable only through
  `FakeRemoteSource` (`RecordingFakes.swift:717-721`). The conformance suite creates its symbolic-link fixture with
  `FileManager` inside the caller's root (`FileSystemConformance.swift:469-470`), an exception to ADR-038.
- **Ruling.** Accepted, no change (S3AH-6; ADR-049; `docs/DECISIONS.md:602`).
- **Evidence.** The types' own documentation.
- **Field.** None: test fidelity.
- **Noticed.** No signal.
- **Re-open.** A drop-to-cancel defect that only a real backend shows.

## 13. Across packages

### RES-81 · S3-B-009: `.live()` has no memory-pressure source

- **What.** `AssetEnvironment.live()` supplies no memory-pressure source (`memoryPressure` is optional, default nil;
  `AssetEnvironment.swift:28`, `:47`). On a device, a memory warning purges nothing unless the app supplies one.
- **Ruling.** Accepted, no change (ADR-056 assigns the device-plan note; `docs/DECISIONS.md:602`).
- **Evidence.** The code above. No device run.
- **Field.** An app that does not supply a UIKit source frees nothing on a memory warning, so R-CLN-11 does not act.
- **Noticed.** DT-MEM-01 and DT-MEM-02.
- **Re-open.** The adopting app's choice of source, or a DT-MEM-01 result the owner rejects.

### RES-82 · S3-B-117: the shims across a facade reopen are uncovered

- **What.** No shim test or `MIGRATION.md` passage describes the lookups' nil between the mirror reset and the
  replacement store's first install, or the coordinator's subscription across a reopen (S3-B-117).
- **Ruling.** None recorded in Stage 3. The backlog marks it open, with a test as its action
  (`.build-orchestrator/s3-backlog.json`).
- **Evidence.** The backlog's status: `docs/MIGRATION.md` has no passage on a reopen, and no compatibility test covers
  it.
- **Field.** During a reopen after `rootVanished`, the shims' lookups can return nil until the replacement store's
  first install. A carousel that reads them then would show a missing asset for that moment (this document's
  reading).
- **Noticed.** DT-STO-04 triggers the reopen; DT-MIG-02 runs the shims' live paths.
- **Re-open.** The owner's adoption, or a WP-K round.

### RES-83 · S3-B-108: the loopback server's LAN refusal is not probed

- **What.** The `::1` probe stands in for a LAN address, and assumes that `lo0` carries `::1`. A `getifaddrs` probe
  needs mutable pointers (C1).
- **Ruling.** Not verified (ADR-051); it stays as listed (`docs/DECISIONS.md:669`).
- **Evidence.** None.
- **Field.** None: the loopback server is test support.
- **Noticed.** No signal.
- **Re-open.** A C1-compliant way to list interfaces.

### RES-84 · S3-B-079: the model tests have no liveness phase

- **What.** The model tests have no liveness phase (ALARM-STUCK passes at its seed, F-34). Six F-40 site changes have
  no reachable difference and no test (F-41). The harness's priority floor no longer reproduces production's utility
  and default QoS gap (S3-B-079).
- **Ruling.** Documented in ARCHITECTURE §14, and open (`docs/DECISIONS.md:616`, `:660`).
- **Evidence.** The backlog entry.
- **Field.** None directly: a liveness defect in the gate model could pass the model tests.
- **Noticed.** No signal.
- **Re-open.** A later test round (`docs/DECISIONS.md:660`).

### RES-85 · Q-10 / S3-B-120: the adoption was never built

- **What.** The adoption inside ZTronCarouselCore was never built or tested, and Stage 4 was cancelled (S3-B-120;
  `docs/DEVICE-TEST-PLAN.md` §1).
- **Ruling.** ADR-006: "Adoption is a follow-up the owner performs" (`docs/DECISIONS.md:39`).
- **Evidence.** `MIGRATION.md` describes the adoption. Nothing outside this repository was written (S3-B-120).
- **Field.**
  - The shims' behaviour inside the real app is unverified.
  - S1's field signal works only if the app collects the kit's `.sync` `.info` lines. Until then, the owner's re-open
    criterion for WP-F has no data (`docs/DECISIONS.md:658`).
- **Noticed.** DT-KIT-01, DT-MIG-01 and DT-MIG-02, once the app is adopted.
- **Re-open.** The owner's adoption. Stage 4's decision on collecting S1's line falls to it, and an API that exposes a
  count (S2-S4) is a public change that needs human review (`docs/DECISIONS.md:658`).

### RES-86 · Device-only behaviour

- **What.** Everything only a device can show: background re-attachment, Apple-hosted packs, low storage, memory
  warnings, real networks, power and thermal states, device performance, `OSLogStore`'s retention, and the iOS 15
  floor.
- **Ruling.** Not verified (`docs/DECISIONS.md:668-674`).
- **Evidence.** The iOS Simulator suite on `e840b0e` passed 1,732/1,732 (`docs/DECISIONS.md:574`). No device run
  exists. `docs/DEVICE-TEST-PLAN.md` has 47 tests, none run.
- **Field.** Unknown until the plan runs.
- **Noticed.** `docs/DEVICE-TEST-PLAN.md`.
- **Re-open.** Any failing device test goes to the owner (`docs/DEVICE-TEST-PLAN.md` §1).

### RES-87 · Weak spots on killed mutants

- **What.** Gaps the discovery agents recorded on mutants that were killed (`docs/MUTATION-PROBES.md` §7).
  - M-S-17 (a residency boundary) was killed only by a Sync test. The storage test the agent proposed does not exist.
  - Mutants with one catcher each: M-S-03, M-S-09, M-S-15, M-S-25, M-N-01, M-N-25 and M-N-28.
  - M-S-05 was killed only incidentally. M-N-02 and M-N-08 were killed mostly by time limits.
  - M-N-11: the harness counts only the injected file-system seam's calls.
  - WP-G's mutants were not re-run on the merged head.
- **Ruling.** No Stage 3 ruling assigned them (`docs/MUTATION-PROBES.md` §7).
- **Evidence.** `docs/MUTATION-PROBES.md` §7.
- **Field.** None directly: a regression there rests on few tests.
- **Noticed.** No signal.
- **Re-open.** A later test round.

### RES-88 · S3-B-110: an answer can come before the readers' snapshot holds the asset (L5K-R24)

- **What.** Four answer sites can answer a user-initiated asker up to about two install intervals (0.2 s by default)
  before the readers' snapshot holds the asset: the commit path, `ensureAvailable`'s present members, the resolve's
  fast hit and joins answered from the ledger (`k.md:1402-1408`; `docs/DECISIONS.md:104`, `:511`). The location
  answered is valid at once. `lookup`, `existingLocalURL` and `hasAsset` see the asset at the next install, which the
  client has scheduled (`docs/MIGRATION.md:211-217`; `README.md:131-136`).
- **Ruling.** An accepted deviation under ADR-055 (the backlog's S3-B-110).
  - L5K-R24 scopes L5K-R21's guarantee (an answer only once the readers' snapshot holds the asset) to the funnel,
    `answeredFromStore`. The other sites keep ADR-016's lag, ruled non-blocking for Level 5 (`k.md:671-677`,
    `:1397-1419`; `docs/DECISIONS.md:104`).
  - L5K-R27 (3) sends it to the Stage 3 backlog: "Stage 3 holds the optional `installIfDue()`"
    (`docs/DECISIONS.md:509`, `:524`). Stage 3 did not take it: `Sources/` has no `installIfDue`, and ADR-057 does
    not name it.
- **Evidence.** Host probes on macOS 27, none pinned by a test (`docs/DECISIONS.md:511`; `k.md:1409-1415`).
  - K4-COMMITPROMO, WP-K's own cycle-4 probe: `unseenAtReturn=1` in 5 of 5 runs (`k.md:1726-1727`).
  - The cycle-4 verifiers' P21-COMMIT, outside migration: `result=success storeHasIt=true unseenAtReturn=1`, 4 of 4
    runs plus TSan.
  - Their P21-ENSURE-MIG, during migration: `unseenAfterEnsure=1`, and the fast hit's `unseenAfterResolve=1`, 4 of 4
    plus TSan.
  - No device run.
- **Field.** An app that uses the answered location, as README advises (`README.md:135-136`), is unaffected. One that
  reads `lookup` or the shims' lookups right after such an answer can miss the asset for up to about 0.2 s. A
  carousel that does would show a missing asset for that moment (this document's reading).
- **Noticed.** DT-PERF-06. In the field, `metrics()`'s `lookupMisses` counts such a miss with every other
  (`Reports.swift:280`).
- **Re-open.** A device test that shows the lag matters (DT-PERF-06). The route is the optional package
  `AssetStore.installIfDue()` with L5K-R21's answer-site check at those sites; it needs `EngineDispatch.swift`
  authorised (`docs/DECISIONS.md:524`).

## 14. ADR-057's Open items, at this writing

| Open item (`docs/DECISIONS.md`) | For | State |
|---|---|---|
| :692 comment-only edits: `CDNAssetResolver.swift:75-76`, `EventContinuityModelTests.swift:9-12`, `README.md:173-175` | WP-K, WP-G, the docs owner | Open |
| :693 `BenchStorage.swift:20-21`'s stall figures; `QuotaEviction.swift:65-69`'s R13 comment | the test owner (P5); WP-C | Open |
| :694 `docs/ORCHESTRATION.md:1090` and `:1154`, the stale WP-C TSan flake | the orchestrator | Open (`docs/ORCHESTRATION.md:576`) |
| :695 the 11 `// REENTRANCY: … (proposed)` citations | WP-F | Open |
| :696 the `isIdleSilent` and `originID` `///` candidates | the orchestrator's ruling | Open (RES-12, RES-09) |
| :697 `docs/REOPEN-WP-F.md`'s final version; the post-merge checklist | the orchestrator | Open: this branch has version 1 |
| :698 the Stage 5 documents | Stage 5 | `MUTATION-PROBES.md`, `DEVICE-TEST-PLAN.md` and this file exist on `wp/s5docs`. `VERIFICATION.md` does not yet; the orchestrator writes it, now that Stage 5's `--full` has ended (§0.4) |
| :699 for the owner: f3c's two open shapes, the uncommitted `Package.swift`, RR-17, P8 | the owner | f3c's shapes open (RES-08, RES-09). `Package.swift`: the owner answered "Yes, clean worktree", so Stage 5's `--full` ran in a clean worktree with the committed manifest (§0.4), and the edit is left alone (`docs/ORCHESTRATION.md:584`). RR-17 open (RES-15). P8 is information (RES-02) |
| :699 for the orchestrator: RR-20's fix, the strict R-INT-5 path, the CCRs (S3B-9 cycle 2, S3B-10, S3B-11), the K-11 tag candidate | the orchestrator | Open (RES-16, RES-37, RES-46 to RES-48, RES-70) |

The ADR-057 workflow's round-2 notes, kept out of its Open bullet, are recorded at `docs/ORCHESTRATION.md:571`: stale
line citations in `docs/ARCHITECTURE.md:978`, `ApplyPlan.swift:85-87`'s "one chunk" wording, and the K-11 tag
wording.

## 15. Index: the residual-risk ledger items

Source: the ADR-057 docs workflow's ledger readers (`.build-orchestrator/s3-post-merge/adr057-docs-journal.jsonl`,
results labelled `ledger:<draft>`). Of their 536 items (`docs/ORCHESTRATION.md:568`), these are the 87 of kind
`residual-risk`. The number is the item's 0-based index into its `ledger:<draft>` result's `items` array.

| Ledger | Items → entry |
|---|---|
| s3g | 32 → RES-69 · 33 → RES-70 · 34 → RES-71 · 35 → RES-72 · 36 → RES-73 · 37 → §11 (S3G-1, not a risk) · 38 → RES-74 |
| s3ah | 34 → RES-79 · 35 → RES-78 · 36 → RES-80 · 37 → RES-75 · 38 → RES-76 · 39 → RES-77 |
| s3b | 35 → RES-02 · 36 → RES-42 · 37 → RES-44 · 38 → RES-45 · 39 → RES-46 · 40 → RES-47 · 41 → RES-48 · 42 → RES-49 · 43 → RES-50 · 44 → RES-51 |
| s3c | 61 → RES-53 · 62 → RES-54 · 63 → RES-55 · 64 → RES-43 · 65 → RES-56 · 66 → RES-57 · 67 → RES-58 · 68 → RES-59 · 69 → RES-60 · 70 → RES-61 · 71 → RES-42, RES-75 |
| s3f-items | 66 → RES-10 · 67 → RES-01 · 68 → RES-03 to RES-06 · 69 → RES-07 · 70 → RES-33 · 71 → RES-13, RES-14 · 72 → RES-17 · 73 → §6 (classification by ruling) · 74 → RES-32 · 75 → RES-38 · 76 → RES-11, RES-12 |
| s3d | 39 → RES-62 · 40 → RES-63 · 41 → RES-64 · 42 → RES-65 · 43 → RES-66 · 44 → RES-67 · 45 to 49 → §10 (closed known misses) |
| s3f-close | 11 → RES-01 · 12 → RES-03 · 13 → RES-04 · 14 → RES-05 · 15 → RES-06 · 16 → RES-07 · 17 → RES-10 · 18 → RES-08 · 19 → RES-11 · 20 → RES-12 · 21 → RES-13 · 22 → RES-14 · 23 → RES-34 · 24 → RES-33 · 25 → RES-02 · 26 → RES-35 · 27 → RES-36 |
| s3f-docs | 100 → RES-19 to RES-21 · 101 → RES-17, RES-18, RES-22 to RES-24 · 102 → RES-25 to RES-27, RES-31 · 103 → RES-28 · 104 → RES-15, RES-16, RES-29 · 105 → RES-30 · 106 → RES-13, RES-14 · 107 → §6 (closed RRs, accepted orders) · 108 → RES-33 · 109 → RES-10 · 110 → RES-01 · 111 → RES-03 to RES-07 · 112 → RES-32 · 113 → RES-35 |

Entries without a ledger item: RES-09 (from `docs/DECISIONS.md:632`), RES-37 and RES-39 to RES-41 (`:616`, `:641`,
`:684`), RES-52 (`:654`), RES-68 (`:673`), RES-81 to RES-88 (`:602`, `:668-674`; the backlog; `docs/MUTATION-PROBES.md`
§7).
