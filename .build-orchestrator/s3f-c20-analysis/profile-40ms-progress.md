# Profiling three C2 shapes: paused 2 Nov 14:19, not reviewed

## Status

- The owner asked "Profile them" on 2 Nov. This is analysis only: C2 stays 10 ms.
- Run `wf_6927a3a9-c76` has one profiler, then one reviewer. It was stopped at 14:19 at the owner's request ("Pause it and hand off a resume strat"), just before the profiler wrote its report.
- The reviewer never ran. **Everything below is the profiler's own output, not reviewed.**

## What is done

Everything is under `/Users/admin/Documents/ZTronAssetKit/.build-prof40/`:

- `src/`: a git archive of `8e1fb24`, plus the supersede probe and the profiler's temporary repetition and micro-timing tests. **Do not re-extract it:** rewriting the sources forces a full rebuild.
- `spm/`: the release build with `-enable-testing`, about 800 MB, built 13:26–13:32.
- `tools/`: the profiler's parsing scripts (`cat.py`, `detail.py` and others).
- `out/`, which holds:
  - the CPU Profiler traces (`s*cpu*.trace`) and their exports (`*.cpu.xml`);
  - the sample pickles (`*.pkl`, `*.turn.pkl`, `*.ann.pkl`);
  - the attribution for each shape, `attribution-shape{1,2,3}.txt`, including the top 15 self-time functions;
  - the micro-timing logs (`micro*.log`) and the baseline logs (`base*.log`);
  - `loads.txt`, the loads for every run.

## Measured shares inside the timed turn

CPU Profiler. The ms are implied at the baseline the profiler used.

| Category | Commit re-routes: 3,030 samples, 47.99 ms | Drain take-off: 3,466 samples, 45.67 ms | `supersede`: 1,500 samples, 41.09 ms |
|---|---|---|---|
| Transfer-id formatting | 20.6 % (9.9 ms) | 16.9 % (7.7 ms) | 15.9 % (6.5 ms) |
| Jobs-table access | 21.1 % (10.1 ms) | 26.8 % (12.3 ms) | 27.1 % (11.1 ms) |
| Sorting | 12.1 % (5.8 ms) | 5.7 % (2.6 ms) | 7.7 % (3.2 ms) |
| Other Set and Dictionary work | 16.1 % (7.7 ms) | 22.1 % (10.1 ms) | 16.5 % (6.8 ms) |
| Manifest lookups and entry copies | 7.4 % (3.5 ms) | 7.8 % (3.6 ms) | 9.0 % (3.7 ms) |
| retireProgress and removeJob | 1.2 % (0.6 ms) | 0 % | 1.4 % (0.6 ms) |
| Whole `EngineState` copy in `decisionNow` | 10.7 % (5.1 ms) | 11.0 % (5.0 ms) | 12.8 % (5.3 ms) |
| Everything else | 10.9 % (5.2 ms) | 9.6 % (4.4 ms) | 9.5 % (3.9 ms) |

## Micro-timings

Release build, on a loaded host, so the absolute values may be high.

| What | Time |
|---|---|
| `ManifestEntry.transferID` | about 300 ns per call |
| `ContentHash.hex` alone | 245 ns |
| `Dictionary<TransferID, Job>` lookup | 115–124 ns |
| Whole-Job copy, `if let job = jobs[key]` | 121 ns |
| In-place write, `jobs[key]?.field = v` | 194 ns |
| `TransferID.hashValue` | 52 ns |
| Format plus lookup | 456 ns |
| Sorting 10,000 AssetIDs | 3.07 ms (0.23 ms if already in order) |

## Baselines this run

The host was loaded, with 1-minute loads of 20–288. These figures are therefore not quiet by S3-R23.

| Shape | Best of 3, this run | Cycle 20 |
|---|---|---|
| `supersede` | 41.07 ms | 41.09 ms |
| Commit re-routes | 48.94 ms | 47.99–49.35 ms |
| Drain take-off | 54.65 ms (inflated by the load) | 45.67–49.08 ms |

## First reading of the analysis's claims

These use the profiler's numbers and are not reviewed.

- **C1 (formatting is 40–50 % of the turn): not supported.** The measured share is 16–21 %, at about 300 ns per format.
- **C2 (jobs-table access costs about 0.7–1.3 µs per id): consistent.** The measured share is 21–27 %, about 1.0–1.2 µs per id.
- **C3 (each 10,000-id sort costs about 3.3 ms): consistent,** at 3.07 ms.
- **New:** a whole-`EngineState` copy in `decisionNow` costs 11–13 % of each turn, 5.0–5.3 ms. The analysis did not name it.
- **No single cost dominates.**

## What is left

1. Re-take the three baselines at a 1-minute load of 10 or less, if the host allows it.
2. Finish steps 5–7 of the task:
   - the claim verdicts;
   - the savings of each fix family, from the measured shares;
   - for each shape, whether the branch-free fixes reach 32 ms or less.
3. Write `profile-40ms.md`.
4. Run the independent review.

`.build-orchestrator/tools/wpf-profile-40ms-resume.js` does all four.

## Resumed 4 Nov 12:54 (run wf_6927a3a9-c76, second start)

- The host was quiet (1-minute load 4.8–5.3). The three baselines were re-taken (`out/base4-*.log`: 49.08 / 44.92 /
  40.21 ms) and the micro-timings re-run three times (`out/micro3-*.log`). Nothing was rebuilt; no source changed.
- Steps 5–7 are done and `profile-40ms.md` is written beside this file. Still not reviewed.
- Left: step 4, the independent review.
