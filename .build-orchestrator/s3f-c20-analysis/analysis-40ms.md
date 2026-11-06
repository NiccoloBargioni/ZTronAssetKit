# If C2's ceiling were 40 ms — analysis only; the bar is still 10 ms

## Why this analysis exists

The owner asked on 2 Nov 2026: "describe the current bar. 100ms is too much, what about 40ms?"

They then clarified: "remember I didn't say to set to 40ms, bar is still 10ms. Just run analysis."

C2 stays 10 ms in the rulings and the run args. Nothing here is a ruling.

## The run

- Run `wf_72146a41-b2b`: read-only, on `8e1fb24`.
- 9 agents: 5 analysts, then 4 adversarial reviewers.
- Cost: 1.45 M subagent tokens over 17 minutes; the weekly meter went from 41 % to 42 %.
- Each agent's output is in `analysis-40ms/`, as `analyze-*.md` and `challenge-*.md`.
- **Every cost attribution below is INFERRED** from the code, the engine's own timing comments and the logged figures. Nothing was profiled.

## The inventory at a 40 ms ceiling

The target is 32 ms or less, to leave a margin so that figures do not flap around 40.

- **Measured over 32 ms at 10,000 ids:** only the five known shapes below.
- **Every other BenchSync C2 case:** 11.01 ms or less at a quiet load, across 31 benchmark functions. The highest are:
  - the C19C-USER-SHARED apply window, 10.46–11.01 ms;
  - `concentrationPublicationTurns` through the commit, 9.82–10.21 ms.
- **Unmeasured:** the commit's binding with one user waiter per id. INFERRED at 15–20 ms. A constant-factor fix exists if it is ever needed.

## The five shapes

Each row is the reviewer's verdict, after the challenge. Confidence is out of 100.

| Shape | Today (best of 3) | Verdict | Fix that splits no work | After the fix (INFERRED) | Cycles (reviewer) |
|---|---|---|---|---|---|
| Commit re-routes | 47.99–49.35 ms | Feasible without a split (60) | Format each transfer id once instead of 4 times. In `publishTerminal`, filter before sorting, with the same predicate as today. | 26–36 ms; 55–65 % chance of 32 ms or less in one cycle | about 2 (1–3) |
| Drain take-off | 45.67–49.08 ms | Uncertain (50) | The same family: 3 formats become 1, the job is resolved once, and the take-off works by intersection. | 24–35 ms on the bench shape; 55–60 % chance of 32 ms or less | 2–3 for the bench shape; 3–4 with other groupings |
| `supersede` | 41.09 ms | Uncertain (60) | The same family, plus an in-place `Job.join` with no new branch. | 28–33 ms on the group shape | 2–4; about 50 % chance that some variant still needs a split |
| `move` | 79.55 ms at 16 moves; 304.79 ms at 64 | Feasible (60, together with `deferBehindVerdict`) | Remove the per-move sort and the live Job copy (M1). The per-waiter grouping at many moves also needs the index (10–12 branches) or a per-turn memo (about 3 branches). | 4–6 ms at 64 moves on the group shape. The per-waiter grouping at 256 moves with M1 alone is estimated at 70–110 ms. | 1–2 for M1; 2–4 with the index |
| `deferBehindVerdict` | 35.78–37.91 ms quiet. The 39.55 ms run had 5- and 15-minute loads of 85 and 316. | Feasible | Smaller deferred events (an `indirect` enum), with 0 branches. | lower; unmeasured | 1 |

## Findings

1. **No measured shape needs splitting at 40 ms.** Each has a fix that adds no deferred state and adds almost no branches, so G4's drop-mutant load stays near zero. The fixes are expected to bring the shapes to about 25–36 ms.

2. **The biggest single cost is formatting the transfer id.** It is re-formatted 3–4 times per id. Each format is a hex encode with about 4–5 heap allocations.
   - It accounts for an INFERRED 40–50 % of the 41–49 ms turns.
   - Formatting once and passing the value down is a pure change, and it serves all three shapes.

3. **The main risk is the rule that 10,000 ids count however they are grouped (S3-R25 item 2), not the number.**
   - The reviewers expect the verifiers to build one-user-waiter-per-id, many-group and spread-destination variants.
   - They estimate those variants at 35–60 ms even after the fixes.
   - That leaves a 25–50 % chance that one of them needs batching or a split, which would restart the loop.

4. **At 10 ms, splitting is still unavoidable.** Even with every no-split fix applied, the three large shapes stay at about 19–35 ms. So 10 ms still needs RR-21's splitting.

5. **Errors the reviewers caught in the analysts' proposals:**
   - A stored `transferID` on `ManifestEntry` would go stale and could change answers, because its fields are `public var`.
   - A faster `ContentHash.hex` must stay byte-identical, because it also names the blob files and the fan-out directory. It is a model-type change, so it is NEEDS-HUMAN-REVIEW.
   - Hoisting `releasing.isEmpty` would add an unkillable mutant.
   - The analysts' `where` variant of `publishTerminal` adds an unkillable branch; the same-predicate filter variant does not.
   - `firstIndex` in the defer fix assumes one verdict event per (transfer, epoch). That is unproven.

## Forecast if the ceiling were 40 ms, under the current verifiers

- About 3–4 cycles, with a range of 2–5.
- About 20–40 h.
- About 45–60 weekly points, at about 15 points per cycle.

## Cheapest measurements that would firm this up

None of these changes the engine.

- A release micro-timing of `ManifestEntry.transferID`: 40,000 calls take seconds.
- One Time Profiler (`xctrace`) run each of `concentrationCommitRerouteTurns`, `movedBeforeDrainTurns` and the supersede probe, to split out the time spent in the hex formatting, the job-table lookups and the sorts.
- Test-only BenchSync variants in a scratch copy, for one user waiter per id and for 10,000 single-id groups.
