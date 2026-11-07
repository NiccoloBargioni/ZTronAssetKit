# Post-merge findings for the records (Stage 3, after the WP-F merge `e840b0e`)

Under the close ruling S3-R28 point 10 (rulings `s3-rulings-s3f.md:1685-`), findings from the post-merge steps follow point 8. A broken MUST, a hang or a new cause of the FAIL goes to the owner. A wrong record is fixed and marked "not independently verified". Anything else is recorded in ADR-057 and `RESIDUAL-RISKS.md`, and not fixed.

## P-13's independent verifier (checklist item 4): workflow `wf_19408ffa-9ba`, 7 Nov 00:24-00:45

The full output is in `p13-verify-wf_19408ffa-9ba.json`, and the run parser that the refuter lens used is `p13scan.py`.

- **Verdicts:** fidelity, measurement and refuter all gave PASS_WITH_NOTES, with 0 blocking findings. P-13 passes on its p99 on `e840b0e`, in the `--full` and in three quiet-load runs alone (`.build-orch/merge-P13-quiet.log`, at 1-minute loads 4.14 → 3.65).
- **Sorted (orchestrator, 00:47):** nothing goes to the owner. P-13 belongs to the accepted FAIL (close point 3), so a P-13 red is not a new cause. There is no MUST and no hang.

### Items for the records

**P1. No spare units** (all three lenses).
- The nearest-rank p99 (`BenchStorage.swift:591-598`) tolerates `n - ceil(0.99 n)` units over 5 ms: 4 for n < 500, 5 for 500 ≤ n ≤ 599, and 6 for n ≥ 600.
- Each of the four runs on `e840b0e` had exactly 5 over: 525, 528, 509 and 519 units (`benchmarks.log:160`, `merge-P13-quiet.log:12/30/48`).
- The p99 sample is itself a stalled unit, at 4.31-4.89 ms. p95 is about 0.99 ms, and the unit's on-CPU maximum is about 1.0 ms.
- → RESIDUAL-RISKS, VERIFICATION, ADR-057.

**P2. Expected failure rate** (measurement, refuter): about 30 % of runs on this deletion unit exceed the p99 tolerance, some at a quiet load.
- The deletion unit is `BlobUnits.swift`, unchanged since `de7e6a5` (9 Oct).
- Measurement lens: 17 of 53 recorded runs (32 %, Wilson 95 % 0.21-0.45); at typical n, 11 of 36. A Poisson fit to the mean of 4.56 over-budget units gives P(≥6) = 0.31.
- Refuter: 14 of 50; but none of 9 runs since s3b's reaper-queue change would fail, while 5 of those 9 sit exactly at the limit.
- Quiet-load failures:
  - `.build-orch/l3-bench.log:116`: 8 of 494 over, at a load of 1.95-2.56;
  - `s3f-probes-c20/reqs/logs/gates/bench.log:141`: 7 of 494 over, at 2.3-3.7;
  - `.worktrees/s3f/.build-s3f/c19/final/bench.log:140`: 9 of 507 over, at 5.24;
  - `.worktrees/s3f/.build-s3f/c22/gates/bench.log:141`: 5 of 478 over, against a tolerance of 4, at 2.6-5.6.
- Consequence: a later `--perf` or `--full` on this head may fail P-13 with no code change. That falls inside the accepted FAIL (close point 3).
- → RESIDUAL-RISKS, VERIFICATION, ADR-057.

**P3. ADR-050's P-13 records misstate the evidence** (wrong record → fixed by a dated amendment in ADR-057, marked "not independently verified" until its verifier checks it).
- `DECISIONS.md:349` gives option A's premise as "measured p99 ≈ 1 ms"; the p99 is now 4.3-4.9 ms, inside the stall tail.
- `DECISIONS.md:368`:
  - It says "every quiet run had 2-4 units over 5 ms out of 490-562". The runs on `e840b0e` had 5, 5, 5 and 5, and the cycle-20 run at a load of 3.6 had 7.
  - It says "a run passes with up to five stalled units"; that holds only for 500 ≤ n ≤ 599.
  - It expects failures only under "heavy load". It omits S3B-12's rating, "(A, marginal) ... p98 would be robust" (`docs/adr-drafts/s3b.md:378`, `:381-382`; `s3-hunt-result.json:384`; `s3-findings-s3b.json:276`).

**P4. The owner's words.** ADR-050 (`DECISIONS.md:368`) quotes the ruling as "P99". The owner's message (29 Oct 14:25 UTC) was "Do not set any budget stop. List P99". The orchestrator read that as option A, recorded the reading at ORCHESTRATION's Stage 3 section ("'List P99' read as the ruling; the owner can correct it"), and told the owner at 14:30 UTC. No correction was found. → ADR-057's amendment quotes the exact words and the reading.

**P5. Stale statements of the old maximum rule** (wrong records → fixed):
- `docs/ARCHITECTURE.md:836` (§12 row S2-27): "P-13 asserts the maximum unit duration (ADR-050; the owner rules on the proposal there)". It should read: the p99 of the deletion-unit durations (the owner's ruling of 2026-10-29, ADR-050 amendment, ADR-057).
- `Sources/ZTronAssetStorage/Blobs/BlobUnits.swift:155-156` (`///` on `BlobDeletionUnit.budget`): "P-13 bounds **every** batch between suspension points by `batch_ms_max`". It should say that P-13 judges the batches on their p99 (SPEC §6, `SPEC.md:308`).
- `BlobUnits.swift:160`: "about every 150 ms of sustained unlinking". S3B-12 found the stalls recur by count, not on a timer (`s3b.md:366-367`).
- `Tests/ZTronAssetKitBenchmarks/BenchStorage.swift:20-21` (`///`): "one `unlink` in about every 850-1,060 stalls ... for 5-11 ms". S3B-12 measured 7-13 stalls over 2 ms per 10,000 unlinks, with maxima of 4.4-6.6 ms (`s3b.md:362-363`); the 5.2-10.8 ms range is ADR-050's Stage 2 runs. This is a comment-only edit in `Tests/`, which needs the orchestrator's explicit permission in the docs round.

**P6. "Judged in the idle `--perf`"** is met in substance but not to the letter.
- The `--full`'s P-13 line prints no load. The nearest reading, about 2 minutes later, is `3.35 6.95 8.74` (`benchmarks.log:252`), and the stage ended at loads of 10-20.
- The three quiet runs of P-13 alone are the reference (`BenchStorage.swift:24-25`), with loads recorded.
- The quiet log names no commit: it is `e840b0e`, in `.worktrees/merge-check`, with scratch `.build-orch-merge-perf`, run by the `--perf` command filtered to `StorageBenchmarks/reclaim\(\)`. This is recorded in ORCHESTRATION's checklist item 4.
- → VERIFICATION.

**P7. Logging gap.** P-13 prints no load averages, unlike the C2 cases (S3-R23 item 1). It stays recorded, not fixed (close point 10). → VERIFICATION and RESIDUAL-RISKS.

**P8. Information for the owner, not a re-judgment.**
- The p99 now passes or fails on how many times APFS stalls an unlink in a run, not on the store's 1 ms unit bound.
- S3B-12 rated option A marginal and called a p98 robust; the owner ruled p99.
- Only the owner can change the statistic or the number. The bar stays as ruled.
